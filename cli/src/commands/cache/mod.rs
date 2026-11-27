//! `harbor-rs cache` - Attic cache helpers.

use clap::Subcommand;

pub(crate) mod push;
pub(crate) mod token;

#[derive(Subcommand, Debug)]
pub(crate) enum CacheCommand {
    /// Push a store path into a named cache.
    Push(push::PushArgs),
    /// Token management for cache access.
    Token {
        #[command(subcommand)]
        command: token::TokenCommand,
    },
}

pub(crate) fn run(cmd: &CacheCommand) -> anyhow::Result<()> {
    match cmd {
        CacheCommand::Push(args) => push::run(args),
        CacheCommand::Token { command } => token::run(command),
    }
}
