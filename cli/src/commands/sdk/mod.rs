//! `rs-harbor sdk` — realize and publish macOS SDK archives.
//!
//! `realize` validates and resolves an SDK archive into a concrete store
//! path. `publish-macos` does the same and then pushes the resulting store
//! path to Attic.

use clap::Subcommand;

pub mod publish_macos;
pub mod realize;

pub use publish_macos::PublishMacosArgs;
pub use realize::RealizeArgs;

#[derive(Subcommand, Debug)]
pub enum SdkCommand {
    /// Realize a macOS SDK archive into a validated store path.
    Realize(RealizeArgs),
    /// Realize and publish a macOS SDK archive to Attic.
    PublishMacos(PublishMacosArgs),
}

pub fn run(cmd: SdkCommand) -> anyhow::Result<()> {
    match cmd {
        SdkCommand::Realize(args) => realize::run(args),
        SdkCommand::PublishMacos(args) => publish_macos::run(args),
    }
}
