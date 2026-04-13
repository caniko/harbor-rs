# mkToolchain :: { pkgs, channel?, date?, extensions?, crossTargets? }
#             -> { rustToolchain, craneLib, crossTargets }
#
# Build a Rust toolchain + craneLib for a given pkgs set.
{crane}: {
  pkgs,
  channel ? "nightly",
  date ? "latest",
  extensions ? ["rust-src" "rustfmt" "rustc-codegen-cranelift-preview"],
  crossTargets ? [
    "x86_64-unknown-linux-gnu"
    "x86_64-pc-windows-gnu"
    "x86_64-apple-darwin"
    "aarch64-apple-darwin"
  ],
}:
  assert pkgs.lib.assertMsg (pkgs ? rust-bin)
    "rs-harbor: mkToolchain requires pkgs with rust-overlay applied (pkgs.rust-bin must exist)";
  assert pkgs.lib.assertMsg (builtins.elem channel ["nightly" "stable"])
    "rs-harbor: mkToolchain 'channel' must be \"nightly\" or \"stable\", got \"${channel}\"";
  assert pkgs.lib.assertMsg (date == "latest" || builtins.match "[0-9]{4}-[0-9]{2}-[0-9]{2}" date != null)
    "rs-harbor: mkToolchain 'date' must be \"latest\" or a YYYY-MM-DD string, got \"${date}\"";
  let
    channelSet =
      if channel == "nightly"
      then pkgs.rust-bin.nightly
      else pkgs.rust-bin.stable;
    dateSet =
      if date == "latest"
      then channelSet.latest
      else channelSet.${date};
    rustToolchain = dateSet.default.override {
      inherit extensions;
      targets = crossTargets;
    };
    craneLib = (crane.mkLib pkgs).overrideToolchain (_p: rustToolchain);
  in {
    inherit rustToolchain craneLib crossTargets;
  }
