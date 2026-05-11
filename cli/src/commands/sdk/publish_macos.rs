//! `rs-harbor sdk publish-macos` — realize a macOS SDK archive and push the
//! resulting store path to Attic.

use std::path::PathBuf;

use anyhow::Result;
use clap::Args;

#[derive(Args, Debug)]
pub struct PublishMacosArgs {
    /// SDK archive path produced by the host-local Apple SDK download.
    #[arg(long)]
    pub archive: PathBuf,

    /// macOS SDK version to realize, such as `26.1`.
    #[arg(long)]
    pub version: String,

    /// Attic server URL, e.g. `https://attic.example.org`.
    #[arg(long)]
    pub attic_server: String,

    /// Attic cache name to push the realized store path into.
    #[arg(long)]
    pub cache: String,

    /// Path to the Attic token file.
    #[arg(long)]
    pub token_file: PathBuf,
}

pub fn run(
    PublishMacosArgs {
        archive,
        version,
        attic_server,
        cache,
        token_file,
    }: PublishMacosArgs,
) -> Result<()> {
    let realized = harbor_sdk::publish_macos_sdk(harbor_sdk::PublishOpts {
        archive,
        version,
        attic_server,
        cache_name: cache,
        token_file,
    })?;
    print_commit_block(&realized.store_path, &realized.version);
    Ok(())
}

fn print_commit_block(store_path: &std::path::Path, version: &str) {
    println!("Commit this in host configuration:");
    println!("```nix");
    println!("programs.rsHarbor.macosSdk.sdkVersion = \"{version}\";");
    println!(
        "programs.rsHarbor.macosSdk.storePath = \"{}\";",
        store_path.display()
    );
    println!("```");
}
