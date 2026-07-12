# mkDioxusPackage

`mkDioxusPackage` builds a Dioxus web distribution through the pinned Rust
toolchain and Dioxus CLI. It keeps generic WASM/Cargo plumbing in rs-harbor;
projects supply their filtered source, lockfile, and git-vendor policy.

```nix
let
  wasm = rs-harbor.lib.mkWasmToolchain { inherit pkgs; };
in
rs-harbor.lib.mkDioxusPackage {
  inherit pkgs src cargoLock;
  pname = "my-dioxus-web";
  craneLib = wasm.craneLib;
  rustToolchain = wasm.rustToolchain;
  package = "my-dioxus-app";
  cargoVendorDir = vendorCargoDir;
  wasmBindgenCli = wasmBindgenPkgs."wasm-bindgen-cli_0_2_126";
  installSubdir = "share/my-dioxus-web";
}
```

The helper runs `dx --frozen bundle --platform web --release`, uses crane's
generated Cargo vendor configuration and offline mode, supplies clang, mold,
esbuild, and the selected WASM toolchain, installs Dioxus' `public` contents
under `installSubdir`, and emits the normalized package-test artifact builder.

`wasmSplit` is opt-in. Dioxus 0.7.9's route splitter can panic in walrus for
some applications, so enable it only after a bundle test proves the pinned
feature graph. Binaryen's empty `-O0` request is translated to the
semantics-preserving `--strip-debug` pass by default; callers can replace
`wasmOptPackage` or `wasmOptArgs` for a compatible Dioxus/Binaryen pair.

`cargoArgs` are appended after the output arguments and Cargo's `--`
separator, so project-specific Cargo flags do not change the Dioxus command.
