use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow};
use serde::Serialize;

/// A single command to run as part of a [`run_pipeline`] step.
///
/// The command inherits the caller's environment, then applies `env_add` and
/// `env_remove`; removals win, matching `std::process::Command::env_remove`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandSpec {
    pub label: String,
    pub program: String,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub env_add: Vec<(String, String)>,
    pub env_remove: Vec<String>,
    /// When true, stdout/stderr are captured into `CommandResult` instead of
    /// inherited.
    pub capture: bool,
    /// When capturing, also tee stdout/stderr to the caller's console.
    pub live_output: bool,
    /// Kill the command when it exceeds this duration.
    pub timeout: Option<Duration>,
}

impl CommandSpec {
    #[must_use]
    pub fn new(label: impl Into<String>, program: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            program: program.into(),
            args: Vec::new(),
            cwd: None,
            env_add: Vec::new(),
            env_remove: Vec::new(),
            capture: false,
            live_output: false,
            timeout: None,
        }
    }

    #[must_use]
    pub fn arg(mut self, arg: impl Into<String>) -> Self {
        self.args.push(arg.into());
        self
    }

    #[must_use]
    pub fn args(mut self, args: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.args.extend(args.into_iter().map(Into::into));
        self
    }

    #[must_use]
    pub fn cwd(mut self, cwd: impl Into<PathBuf>) -> Self {
        self.cwd = Some(cwd.into());
        self
    }

    #[must_use]
    pub fn env(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.env_add.push((key.into(), value.into()));
        self
    }

    #[must_use]
    pub fn env_remove(mut self, key: impl Into<String>) -> Self {
        self.env_remove.push(key.into());
        self
    }

    #[must_use]
    pub fn capture(mut self) -> Self {
        self.capture = true;
        self
    }

    #[must_use]
    pub fn live_output(mut self) -> Self {
        self.live_output = true;
        self
    }

    #[must_use]
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = Some(timeout);
        self
    }
}

/// An ordered set of commands with optional best-effort cleanup steps.
///
/// Cleanup runs in reverse registration order even when a main step fails.
/// `keep_going` is deliberately opt-in: normal CI remains fail-fast, while
/// local diagnostic runs can collect more than one failure.
#[derive(Debug, Clone, Default)]
pub struct PipelinePlan {
    steps: Vec<CommandSpec>,
    cleanup: Vec<CommandSpec>,
    keep_going: bool,
}

impl PipelinePlan {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn step(mut self, spec: CommandSpec) -> Self {
        self.steps.push(spec);
        self
    }

    #[must_use]
    pub fn cleanup(mut self, spec: CommandSpec) -> Self {
        self.cleanup.push(spec);
        self
    }

    #[must_use]
    pub fn keep_going(mut self, enabled: bool) -> Self {
        self.keep_going = enabled;
        self
    }

    #[must_use]
    pub fn steps(&self) -> &[CommandSpec] {
        &self.steps
    }

    #[must_use]
    pub fn cleanup_steps(&self) -> &[CommandSpec] {
        &self.cleanup
    }

    /// Execute the plan and return a machine-readable report on success.
    pub fn run(&self) -> Result<PipelineReport> {
        let (report, error) = self.run_with_report();
        match error {
            Some(error) => Err(error),
            None => Ok(report),
        }
    }

    /// Execute the plan while retaining its report when a step fails.
    pub fn run_with_report(&self) -> (PipelineReport, Option<anyhow::Error>) {
        let started = Instant::now();
        let (results, error) = execute_steps(&self.steps, &self.cleanup, self.keep_going);
        (
            PipelineReport::from_results(results, started.elapsed()),
            error,
        )
    }
}

/// Outcome of one [`CommandSpec`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandResult {
    pub label: String,
    pub success: bool,
    pub elapsed: Duration,
    /// Empty unless the step captured output.
    pub stdout: String,
    /// Empty unless the step captured output.
    pub stderr: String,
}

/// Serializable summary of a completed pipeline.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PipelineReport {
    pub success: bool,
    pub elapsed_ms: u128,
    pub steps: Vec<PipelineStepReport>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PipelineStepReport {
    pub label: String,
    pub success: bool,
    pub elapsed_ms: u128,
    pub stdout: String,
    pub stderr: String,
}

impl PipelineReport {
    fn from_results(results: Vec<CommandResult>, elapsed: Duration) -> Self {
        let success = results.iter().all(|result| result.success);
        Self {
            success,
            elapsed_ms: elapsed.as_millis(),
            steps: results
                .into_iter()
                .map(|result| PipelineStepReport {
                    label: result.label,
                    success: result.success,
                    elapsed_ms: result.elapsed.as_millis(),
                    stdout: result.stdout,
                    stderr: result.stderr,
                })
                .collect(),
        }
    }
}

pub fn write_report(path: impl AsRef<Path>, report: &PipelineReport) -> Result<()> {
    let path = path.as_ref();
    let bytes = serde_json::to_vec_pretty(report).context("serializing pipeline report")?;
    fs::write(path, bytes).with_context(|| format!("writing pipeline report {}", path.display()))
}

/// Run steps in order, failing fast on the first non-zero exit.
///
/// A failing captured step surfaces its stdout/stderr in the error message.
pub fn run_pipeline(steps: &[CommandSpec]) -> Result<Vec<CommandResult>> {
    let (results, error) = execute_steps(steps, &[], false);
    match error {
        Some(error) => Err(error),
        None => Ok(results),
    }
}

fn execute_steps(
    steps: &[CommandSpec],
    cleanup: &[CommandSpec],
    keep_going: bool,
) -> (Vec<CommandResult>, Option<anyhow::Error>) {
    let mut results = Vec::with_capacity(steps.len() + cleanup.len());
    let mut first_error = None;

    for spec in steps {
        match run_step(spec) {
            Ok(result) => {
                let failed = !result.success;
                if failed && first_error.is_none() {
                    first_error = Some(step_error(spec, &result));
                }
                results.push(result);
                if failed && !keep_going {
                    break;
                }
            }
            Err(error) => {
                if first_error.is_none() {
                    first_error = Some(anyhow!(error.to_string()));
                }
                results.push(spawn_failure(spec, &error));
                if !keep_going {
                    break;
                }
            }
        }
    }

    for spec in cleanup.iter().rev() {
        match run_step(spec) {
            Ok(result) => {
                if !result.success && first_error.is_none() {
                    first_error = Some(step_error(spec, &result));
                }
                results.push(result);
            }
            Err(error) => {
                if first_error.is_none() {
                    first_error = Some(anyhow!(error.to_string()));
                }
                results.push(spawn_failure(spec, &error));
            }
        }
    }

    (results, first_error)
}

fn spawn_failure(spec: &CommandSpec, error: &anyhow::Error) -> CommandResult {
    CommandResult {
        label: spec.label.clone(),
        success: false,
        elapsed: Duration::ZERO,
        stdout: String::new(),
        stderr: error.to_string(),
    }
}

fn step_error(spec: &CommandSpec, result: &CommandResult) -> anyhow::Error {
    let mut message = format!("{} failed after {:?}", result.label, result.elapsed);
    if spec.capture {
        if !result.stdout.is_empty() {
            message.push_str("\nstdout:\n");
            message.push_str(&result.stdout);
        }
        if !result.stderr.is_empty() {
            message.push_str("\nstderr:\n");
            message.push_str(&result.stderr);
        }
    }
    anyhow!(message)
}

/// Run one step without failing on its exit status; inspect
/// [`CommandResult::success`] yourself.
pub fn run_step(spec: &CommandSpec) -> Result<CommandResult> {
    let mut command = Command::new(&spec.program);
    command.args(&spec.args);
    if let Some(cwd) = &spec.cwd {
        command.current_dir(cwd);
    }
    for (key, value) in &spec.env_add {
        command.env(key, value);
    }
    for key in &spec.env_remove {
        command.env_remove(key);
    }

    let command_line = format!("{} {}", spec.program, spec.args.join(" "));
    tracing::debug!("running step {}: {command_line}", spec.label);

    let start = Instant::now();
    let (success, stdout, stderr) = if spec.capture {
        let output = if spec.timeout.is_none() && !spec.live_output {
            let output = command
                .output()
                .with_context(|| format!("running {command_line}"))?;
            (output.status, output.stdout, output.stderr)
        } else {
            collect_output(&mut command, spec.timeout, spec.live_output)
                .with_context(|| format!("running {command_line}"))?
        };
        (
            output.0.success(),
            String::from_utf8_lossy(&output.1).into_owned(),
            String::from_utf8_lossy(&output.2).into_owned(),
        )
    } else {
        let status = if let Some(timeout) = spec.timeout {
            let mut child = command
                .spawn()
                .with_context(|| format!("running {command_line}"))?;
            let (status, timed_out) = wait_with_timeout(&mut child, timeout)?;
            if timed_out {
                return Ok(CommandResult {
                    label: spec.label.clone(),
                    success: false,
                    elapsed: start.elapsed(),
                    stdout: String::new(),
                    stderr: format!("timed out after {timeout:?}"),
                });
            }
            status
        } else {
            command
                .status()
                .with_context(|| format!("running {command_line}"))?
        };
        (status.success(), String::new(), String::new())
    };
    let elapsed = start.elapsed();

    Ok(CommandResult {
        label: spec.label.clone(),
        success,
        elapsed,
        stdout,
        stderr,
    })
}

fn collect_output(
    command: &mut Command,
    timeout: Option<Duration>,
    live_output: bool,
) -> Result<(ExitStatus, Vec<u8>, Vec<u8>)> {
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("spawning captured command")?;
    let stdout = child.stdout.take().context("capturing stdout")?;
    let stderr = child.stderr.take().context("capturing stderr")?;
    let stdout_thread = thread::spawn(move || read_pipe(stdout, live_output, false));
    let stderr_thread = thread::spawn(move || read_pipe(stderr, live_output, true));
    let (status, timed_out) = if let Some(timeout) = timeout {
        wait_with_timeout(&mut child, timeout)?
    } else {
        (child.wait().context("waiting for command")?, false)
    };
    let stdout = stdout_thread
        .join()
        .map_err(|_| anyhow!("stdout reader thread panicked"))?;
    let mut stderr = stderr_thread
        .join()
        .map_err(|_| anyhow!("stderr reader thread panicked"))?;
    if timed_out {
        stderr.extend_from_slice(format!("timed out after {timeout:?}\n").as_bytes());
    }
    Ok((status, stdout, stderr))
}

fn read_pipe<R: Read>(mut reader: R, live_output: bool, is_stderr: bool) -> Vec<u8> {
    let mut output = Vec::new();
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(size) => {
                output.extend_from_slice(&buffer[..size]);
                if live_output {
                    let writer: &mut dyn Write = if is_stderr {
                        &mut io::stderr()
                    } else {
                        &mut io::stdout()
                    };
                    let _ = writer.write_all(&buffer[..size]);
                    let _ = writer.flush();
                }
            }
        }
    }
    output
}

fn wait_with_timeout(child: &mut Child, timeout: Duration) -> Result<(ExitStatus, bool)> {
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait().context("waiting for command")? {
            return Ok((status, false));
        }
        if started.elapsed() >= timeout {
            child.kill().context("stopping timed-out command")?;
            return Ok((child.wait().context("waiting for timed-out command")?, true));
        }
        thread::sleep(Duration::from_millis(50));
    }
}
