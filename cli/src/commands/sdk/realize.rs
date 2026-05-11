//! `rs-harbor sdk realize` — realize a macOS SDK archive and print the
//! host-configuration trailer for the resulting store path.

use std::path::PathBuf;

use anyhow::Result;
use clap::Args;

#[derive(Args, Debug)]
pub struct RealizeArgs {
    /// SDK archive path produced by the host-local Apple SDK download.
    #[arg(long)]
    pub archive: PathBuf,

    /// macOS SDK version to realize, such as `26.1`.
    #[arg(long)]
    pub version: String,
}

pub fn run(RealizeArgs { archive, version }: RealizeArgs) -> Result<()> {
    let realized = harbor_sdk::realize_macos_sdk(&archive, &version)?;
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
