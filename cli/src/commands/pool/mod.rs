#[cfg(test)]
mod tests;

use anyhow::{Context, Result};
use clap::Subcommand;
use rmcp::schemars;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    fs,
    io::{BufRead, BufReader, Write},
    os::unix::{
        fs::{MetadataExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime},
};

#[derive(Subcommand)]
pub enum PoolCommand {
    /// Collect observations without changing build behavior.
    Serve {
        #[arg(long, required = true)]
        observe: bool,
        #[arg(long, default_value_t = 5, value_parser = clap::value_parser!(u64).range(1..))]
        interval: u64,
    },
    /// Show the latest snapshot.
    Status {
        #[arg(long)]
        cwd: Option<String>,
        #[arg(long)]
        build_dir: Option<String>,
        #[arg(long)]
        json: bool,
    },
}

pub fn run(command: PoolCommand) -> Result<()> {
    match command {
        PoolCommand::Serve {
            observe: _,
            interval,
        } => serve(interval),
        PoolCommand::Status {
            cwd,
            build_dir,
            json,
        } => {
            let status = request(cwd, build_dir)?;
            if json {
                println!("{}", serde_json::to_string(&status)?);
            } else {
                println!(
                    "Build pool observation: {}",
                    status["timestamp"].as_str().unwrap_or("pending")
                );
                println!("Host: {}", status["host"]);
                println!("CPU and RSS by class: {}", status["classes"]);
                println!("Build directories: {}", status["build_dirs"]);
                for process in status["processes"].as_array().into_iter().flatten() {
                    println!("{process}");
                }
            }
            Ok(())
        }
    }
}

fn request(cwd: Option<String>, build_dir: Option<String>) -> Result<Value> {
    let mut stream = UnixStream::connect(socket_path()?)
        .context("build pool daemon unavailable; start `harbor-rs pool serve --observe`")?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    writeln!(stream, "{}", json!({"cwd": cwd, "build_dir": build_dir}))?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    Ok(serde_json::from_str(&line)?)
}

#[derive(Clone)]
struct PoolMcp;

#[derive(serde::Deserialize, schemars::JsonSchema)]
struct StatusArgs {
    /// Restrict cargo observations to this working directory.
    cwd: Option<String>,
    /// Restrict cargo observations to this build directory.
    build_dir: Option<String>,
}

#[rmcp::tool_router(server_handler)]
impl PoolMcp {
    #[rmcp::tool(
        description = "Check build activity before a heavy build in a shared checkout. Never sleep-poll; cargo's lock already waits. Returns the latest observation, optionally filtered by cwd or build_dir."
    )]
    async fn build_status(
        &self,
        rmcp::handler::server::wrapper::Parameters(args): rmcp::handler::server::wrapper::Parameters<StatusArgs>,
    ) -> std::result::Result<String, String> {
        tokio::task::spawn_blocking(move || {
            request(args.cwd, args.build_dir).and_then(|v| Ok(serde_json::to_string(&v)?))
        })
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| format!("{e:#}"))
    }
}

pub fn mcp() -> Result<()> {
    use rmcp::ServiceExt;
    tokio::runtime::Runtime::new()?.block_on(async {
        PoolMcp
            .serve(rmcp::transport::stdio())
            .await?
            .waiting()
            .await?;
        Ok(())
    })
}

fn socket_path() -> Result<PathBuf> {
    Ok(
        PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").context("XDG_RUNTIME_DIR is not set")?)
            .join("harbor-rs/pool.sock"),
    )
}

fn state_path() -> Result<PathBuf> {
    let base = match std::env::var_os("XDG_STATE_HOME") {
        Some(path) if !path.is_empty() => PathBuf::from(path),
        _ => {
            PathBuf::from(std::env::var_os("HOME").context("HOME is not set")?).join(".local/state")
        }
    };
    Ok(base.join("harbor-rs/pool"))
}

fn serve(interval: u64) -> Result<()> {
    let socket = socket_path()?;
    let parent = socket.parent().context("socket has no parent")?;
    fs::create_dir_all(parent)?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    if socket.exists() {
        if UnixStream::connect(&socket).is_ok() {
            anyhow::bail!("pool daemon already running");
        }
        let metadata = fs::symlink_metadata(&socket)?;
        use std::os::unix::fs::FileTypeExt;
        anyhow::ensure!(
            metadata.file_type().is_socket(),
            "refusing to remove non-socket {}",
            socket.display()
        );
        fs::remove_file(&socket)?;
    }
    let listener = UnixListener::bind(&socket)?;
    fs::set_permissions(&socket, fs::Permissions::from_mode(0o600))?;
    let state = state_path()?;
    fs::create_dir_all(&state)?;
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700))?;
    let uid = fs::metadata("/proc/self")?.uid();
    // /proc reports times in USER_HZ, which Linux fixes at 100 on every
    // architecture. Spawning `getconf` would fail under a systemd unit's PATH.
    let ticks = 100.0;
    let snapshot = Arc::new(Mutex::new(json!({"error": "first observation pending"})));
    let shared = Arc::clone(&snapshot);
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let shared = Arc::clone(&shared);
            std::thread::spawn(move || {
                let _ = handle_connection(stream, &shared);
            });
        }
    });
    let mut previous = HashMap::new();
    let mut previous_nix = None;
    loop {
        let value = scan(uid, ticks, &mut previous, &mut previous_nix)?;
        *snapshot
            .lock()
            .map_err(|_| anyhow::anyhow!("snapshot lock poisoned"))? = value.clone();
        let date = chrono::Utc::now().format("%Y-%m-%d");
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(state.join(format!("observe-{date}.jsonl")))?;
        // The socket serves every process. The log keeps cargo entries and the
        // aggregates, which is what the gates need: a full snapshot is ~15 KB a tick.
        let mut logged = value;
        if let Some(processes) = logged.get_mut("processes").and_then(Value::as_array_mut) {
            processes.retain(|p| p["class"] == "cargo");
        }
        writeln!(file, "{logged}")?;
        cleanup(&state);
        std::thread::sleep(Duration::from_secs(interval));
    }
}

fn cleanup(dir: &Path) {
    // ponytail: ~95 MB/day at 10 s; 8 days covers the observe week. Sample or
    // compress if observation outlives it.
    let cutoff = SystemTime::now().checked_sub(Duration::from_secs(8 * 86400));
    if let (Ok(entries), Some(cutoff)) = (fs::read_dir(dir), cutoff) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with("observe-")
                && name.ends_with(".jsonl")
                && entry
                    .metadata()
                    .and_then(|m| m.modified())
                    .is_ok_and(|m| m < cutoff)
            {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
}

fn handle_connection(mut stream: UnixStream, shared: &Mutex<Value>) -> Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let mut input = String::new();
    use std::io::Read;
    BufReader::new(stream.try_clone()?)
        .take(8192)
        .read_line(&mut input)?;
    let filter: Value = serde_json::from_str(&input)?;
    let mut snapshot = shared
        .lock()
        .map_err(|_| anyhow::anyhow!("snapshot lock poisoned"))?
        .clone();
    let filtered = ["cwd", "build_dir"]
        .iter()
        .any(|key| filter.get(key).and_then(Value::as_str).is_some());
    if let Some(processes) = snapshot.get_mut("processes").and_then(Value::as_array_mut) {
        processes.retain(|p| {
            ["cwd", "build_dir"].iter().all(|key| {
                filter
                    .get(key)
                    .and_then(Value::as_str)
                    .is_none_or(|v| p.get(key).and_then(Value::as_str) == Some(v))
            })
        });
    }
    if filtered {
        let pids: Vec<u64> = snapshot["processes"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|p| p["pid"].as_u64())
            .collect();
        if let Some(dirs) = snapshot
            .get_mut("build_dirs")
            .and_then(Value::as_object_mut)
        {
            dirs.retain(|_, dir| {
                if let Some(groups) = dir["identical_argv_groups"].as_array_mut() {
                    for group in groups.iter_mut() {
                        if let Some(p) = group.as_array_mut() {
                            p.retain(|pid| pid.as_u64().is_some_and(|pid| pids.contains(&pid)));
                        }
                    }
                    groups.retain(|group| group.as_array().is_some_and(|g| g.len() > 1));
                }
                true
            });
        }
        let counts: BTreeMap<String, usize> = snapshot["processes"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|p| p["build_dir"].as_str())
            .fold(BTreeMap::new(), |mut map, dir| {
                *map.entry(dir.to_owned()).or_default() += 1;
                map
            });
        if let Some(dirs) = snapshot
            .get_mut("build_dirs")
            .and_then(Value::as_object_mut)
        {
            dirs.retain(|dir, value| {
                if let Some(count) = counts.get(dir) {
                    value["cargo_count"] = json!(count);
                    true
                } else {
                    false
                }
            });
        }
    }
    writeln!(stream, "{snapshot}")?;
    Ok(())
}

fn interesting(comm: &str) -> bool {
    matches!(
        comm,
        "cargo"
            | "rustc"
            | "rust-analyzer"
            | "sccache"
            | "mold"
            | "ld"
            | "ld.lld"
            | "ld.mold"
            | "cc"
            | "gcc"
            | "clang"
    ) || comm.contains('-')
        || comm.len() == 15
}

fn read_key_values(path: &str) -> BTreeMap<String, u64> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            let key = parts.next()?.trim_end_matches(':');
            Some((key.to_owned(), parts.next()?.parse().ok()?))
        })
        .collect()
}

fn pressure(path: &str) -> Value {
    let mut out = serde_json::Map::new();
    for line in fs::read_to_string(path).unwrap_or_default().lines() {
        let mut parts = line.split_whitespace();
        if let Some(kind) = parts.next() {
            let mut values = serde_json::Map::new();
            for item in parts {
                if let Some((key, value)) = item.split_once('=') {
                    if matches!(key, "avg10" | "avg60") {
                        if let Ok(value) = value.parse::<f64>() {
                            values.insert(key.into(), json!(value));
                        }
                    }
                }
            }
            out.insert(kind.into(), Value::Object(values));
        }
    }
    Value::Object(out)
}

fn scan(
    uid: u32,
    ticks: f64,
    previous: &mut HashMap<u32, (u64, u64)>,
    previous_nix: &mut Option<u64>,
) -> Result<Value> {
    let mut processes = Vec::new();
    let mut samples = HashMap::new();
    let mut groups: BTreeMap<String, Vec<(u32, Vec<u8>)>> = BTreeMap::new();
    let mut classes: BTreeMap<String, (f64, u64)> = BTreeMap::new();
    let mem = read_key_values("/proc/meminfo");
    let boot = read_key_values("/proc/stat")
        .get("btime")
        .copied()
        .unwrap_or(0);
    for entry in fs::read_dir("/proc")?.flatten() {
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<u32>() else {
            continue;
        };
        let path = entry.path();
        let Ok(comm) = fs::read_to_string(path.join("comm")) else {
            continue;
        };
        let comm = comm.trim();
        if !interesting(comm) || !fs::metadata(&path).is_ok_and(|m| m.uid() == uid) {
            continue;
        }
        let Ok(stat) = fs::read_to_string(path.join("stat")) else {
            continue;
        };
        let Some((_, tail)) = stat.rsplit_once(") ") else {
            continue;
        };
        let fields: Vec<_> = tail.split_whitespace().collect();
        if fields.len() < 22 {
            continue;
        }
        let (Ok(ppid), Ok(user), Ok(system), Ok(start), Ok(rss_pages)) = (
            fields[1].parse::<u32>(),
            fields[11].parse::<u64>(),
            fields[12].parse::<u64>(),
            fields[19].parse::<u64>(),
            fields[21].parse::<u64>(),
        ) else {
            continue;
        };
        let parent = fs::read_to_string(format!("/proc/{ppid}/comm")).unwrap_or_default();
        let exe = fs::read_link(path.join("exe")).ok();
        let Some(class) = classify(comm, exe.as_ref().and_then(|p| p.to_str()), parent.trim())
        else {
            continue;
        };
        let total = user.saturating_add(system);
        let delta = previous
            .get(&pid)
            .filter(|(old_start, _)| *old_start == start)
            .map_or(0, |(_, old)| total.saturating_sub(*old));
        samples.insert(pid, (start, total));
        let cpu = delta as f64 / ticks;
        // Linux exposes RSS in pages; use VmRSS in kB to avoid assuming a page size.
        let rss = read_key_values(&format!("/proc/{pid}/status"))
            .get("VmRSS")
            .copied()
            .unwrap_or(rss_pages.saturating_mul(4))
            .saturating_mul(1024);
        let aggregate = classes.entry(class.into()).or_default();
        aggregate.0 += cpu;
        aggregate.1 += rss;
        let mut item =
            json!({"pid": pid, "ppid": ppid, "class": class, "cpu_seconds": cpu, "rss": rss});
        if class == "cargo" {
            let cwd = fs::read_link(path.join("cwd"))
                .ok()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            let dir = build_dir(&path.join("fd")).unwrap_or_else(|| cwd.clone());
            let argv = fs::read(path.join("cmdline")).unwrap_or_default();
            groups
                .entry(dir.clone())
                .or_default()
                .push((pid, argv.clone()));
            let display = String::from_utf8_lossy(&argv).replace('\0', " ");
            let truncated: String = display.trim_end().chars().take(512).collect();
            let parent_class = match parent.trim() {
                "rust-analyzer" => "rust-analyzer",
                "bash" | "zsh" | "nu" | "fish" | "sh" => "shell",
                _ => "other",
            };
            item["parent_class"] = json!(parent_class);
            item["cwd"] = json!(cwd);
            item["build_dir"] = json!(dir);
            item["argv"] = json!(truncated);
            item["started"] = json!(boot as f64 + start as f64 / ticks);
        }
        processes.push(item);
    }
    *previous = samples;
    let children: HashMap<u32, usize> = processes
        .iter()
        .filter(|p| p["class"] == "rustc" || p["class"] == "sccache")
        .fold(HashMap::new(), |mut map, p| {
            *map.entry(p["ppid"].as_u64().unwrap_or(0) as u32)
                .or_default() += 1;
            map
        });
    for p in &mut processes {
        if p["class"] == "cargo" {
            p["children"] = json!(
                children
                    .get(&(p["pid"].as_u64().unwrap_or(0) as u32))
                    .copied()
                    .unwrap_or(0)
            );
        }
    }
    let dirs: BTreeMap<_, _> = groups.iter().map(|(dir, cargos)| (dir, json!({"cargo_count": cargos.len(), "identical_argv_groups": identical_groups(cargos)}))).collect();
    let by_class: BTreeMap<_, _> = classes
        .iter()
        .map(|(class, (cpu, rss))| (class, json!({"cpu_seconds": cpu, "rss": rss})))
        .collect();
    let nix = read_key_values("/sys/fs/cgroup/system.slice/nix-daemon.service/cpu.stat")
        .get("usage_usec")
        .copied();
    let nix_delta = nix
        .zip(*previous_nix)
        .map(|(now, old)| now.saturating_sub(old) as f64 / 1_000_000.0);
    *previous_nix = nix;
    Ok(
        json!({"timestamp": chrono::Utc::now().to_rfc3339(), "host": {"mem_available": mem.get("MemAvailable").map(|v| v * 1024), "swap_free": mem.get("SwapFree").map(|v| v * 1024), "psi": {"cpu": pressure("/proc/pressure/cpu"), "memory": pressure("/proc/pressure/memory")}, "nix_daemon_cpu_seconds": nix_delta}, "classes": by_class, "build_dirs": dirs, "processes": processes}),
    )
}

fn classify(comm: &str, exe: Option<&str>, parent: &str) -> Option<&'static str> {
    match comm {
        "cargo" => Some("cargo"),
        "rustc" => Some("rustc"),
        "rust-analyzer" => Some("rust-analyzer"),
        "sccache" => Some("sccache"),
        "mold" | "ld" | "ld.lld" | "ld.mold" => Some("linker"),
        "cc" | "gcc" | "clang" if parent == "rustc" => Some("linker"),
        _ => {
            let exe = Path::new(exe?);
            let name = exe.file_name()?.to_str()?;
            let (_, hash) = name.rsplit_once('-')?;
            (hash.len() == 16
                && hash.bytes().all(|b| b.is_ascii_hexdigit())
                && exe.parent()?.file_name()? == "deps")
                .then_some("test")
        }
    }
}

fn build_dir(fd: &Path) -> Option<String> {
    std::fs::read_dir(fd).ok()?.flatten().find_map(|entry| {
        let path = std::fs::read_link(entry.path()).ok()?;
        matches!(
            path.file_name()?.to_str()?,
            ".cargo-build-lock" | ".cargo-lock"
        )
        .then(|| path.parent()?.to_str().map(str::to_owned))?
    })
}

fn identical_groups(cargos: &[(u32, Vec<u8>)]) -> Vec<Vec<u32>> {
    let mut groups = BTreeMap::<&[u8], Vec<u32>>::new();
    for (pid, argv) in cargos {
        groups.entry(argv).or_default().push(*pid);
    }
    groups
        .into_values()
        .filter(|group| group.len() > 1)
        .collect()
}
