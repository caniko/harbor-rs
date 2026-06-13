//! `rs-harbor sdk realize` — realize a macOS SDK archive and print the
//! host-configuration trailer for the resulting store path.

use std::path::PathBuf;

use anyhow::Result;
use clap::Args;

#[derive(Args, Debug)]
// `--version` is a real SDK-version argument here, not a version flag; drop
// clap's auto-generated `--version` so the two don't collide.
#[command(disable_version_flag = true)]
pub struct RealizeArgs {
    /// SDK archive path produced by the host-local Apple SDK download.
    #[arg(long)]
    pub archive: PathBuf,

    /// macOS SDK version to realize, such as `26.1`.
    #[arg(long)]
    pub version: String,

    /// Register a Nix GC root at this link pointing to the realized store
    /// path, so it survives `nix-collect-garbage`. Created with
    /// `nix-store --add-root --indirect` (no elevated privileges required).
    #[arg(long)]
    pub gc_root: Option<PathBuf>,
}

pub fn run(
    RealizeArgs {
        archive,
        version,
        gc_root,
    }: RealizeArgs,
) -> Result<()> {
    let realized = harbor_sdk::realize_macos_sdk(&archive, &version)?;
    if let Some(link) = &gc_root {
        harbor_sdk::create_gc_root(&realized.store_path, link)?;
    }
    print_commit_block(
        &realized.store_path,
        &realized.version,
        &realized.recursive_hash,
    );
    Ok(())
}

fn print_commit_block(store_path: &std::path::Path, version: &str, recursive_hash: &str) {
    print!(
        "{}",
        render_commit_block(store_path, version, recursive_hash)
    );
}

fn render_commit_block(
    store_path: &std::path::Path,
    version: &str,
    recursive_hash: &str,
) -> String {
    format!(
        "Commit this in host configuration:\n\
         ```nix\n\
         programs.rsHarbor.macosSdk.sdkVersion = \"{version}\";\n\
         programs.rsHarbor.macosSdk.storePath = \"{}\";\n\
         programs.rsHarbor.macosSdk.outputHash = \"{recursive_hash}\";\n\
         ```\n",
        store_path.display()
    )
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    #[test]
    fn commit_block_includes_output_hash() {
        let block = super::render_commit_block(
            Path::new("/nix/store/example-macosx-sdk-26.1"),
            "26.1",
            "sha256-example",
        );

        assert!(block.contains("programs.rsHarbor.macosSdk.sdkVersion = \"26.1\";"));
        assert!(block.contains(
            "programs.rsHarbor.macosSdk.storePath = \"/nix/store/example-macosx-sdk-26.1\";"
        ));
        assert!(block.contains("programs.rsHarbor.macosSdk.outputHash = \"sha256-example\";"));
    }
}
