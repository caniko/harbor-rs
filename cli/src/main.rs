use clap::{Parser, Subcommand};

mod commands;

#[derive(Parser)]
#[command(
    name = "rs-harbor",
    version,
    about = "rs-harbor build helpers",
    propagate_version = true
)]
struct Cli {
    #[command(subcommand)]
    command: TopCommand,
}

#[derive(Subcommand)]
enum TopCommand {
    /// Stage cargo build outputs for release distribution.
    Stage {
        #[command(subcommand)]
        command: StageCommand,
    },
}

#[derive(Subcommand)]
enum StageCommand {
    /// Stage per-arch and universal macOS Mach-O outputs with dSYMs.
    Macos(commands::stage_macos::StageMacosArgs),
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    match cli.command {
        TopCommand::Stage { command } => match command {
            StageCommand::Macos(args) => commands::stage_macos::run(args),
        },
    }
}
