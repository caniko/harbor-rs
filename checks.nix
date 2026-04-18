{
  self,
  pkgs,
  system,
  toolchain,
  cross,
}: let
  isLinux = builtins.match ".*-linux" system != null;
in {
  # mkToolchain returns expected attributes
  mkToolchain-shape = let
    t = self.lib.mkToolchain {inherit pkgs;};
  in
    assert t ? rustToolchain;
    assert t ? craneLib;
    assert t ? crossTargets;
    assert builtins.isList t.crossTargets;
    assert builtins.length t.crossTargets > 0;
    pkgs.runCommand "check-mkToolchain-shape" {} "touch $out";

  # stable channel works
  mkToolchain-stable = let
    t = self.lib.mkToolchain {
      inherit pkgs;
      channel = "stable";
    };
  in
    assert t ? rustToolchain;
    assert t ? craneLib;
    pkgs.runCommand "check-mkToolchain-stable" {} "touch $out";

  # mkCross returns expected attributes
  mkCross-shape = let
    c = self.lib.mkCross {
      inherit pkgs system;
      enableOsxcross = false;
    };
  in
    assert c ? mingwCC;
    assert c ? mingwBinutils;
    assert c ? winpthreads;
    assert c ? windowsEnv;
    assert c ? osxcrossToolchain;
    assert c ? osxcrossRustHelpers;
    assert builtins.isAttrs c.windowsEnv;
    assert c.windowsEnv ? CC_x86_64_pc_windows_gnu;
    assert c.windowsEnv ? CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER;
    pkgs.runCommand "check-mkCross-shape" {} "touch $out";

  # osxcross disabled returns nulls
  mkCross-osxcross-disabled = let
    c = self.lib.mkCross {
      inherit pkgs system;
      enableOsxcross = false;
    };
  in
    assert c.osxcrossToolchain == null;
    assert c.osxcrossRustHelpers == null;
    pkgs.runCommand "check-mkCross-osxcross-disabled" {} "touch $out";

  # Pure evaluation should not enable osxcross unless MACOS_SDK is visible.
  mkCross-osxcross-default-disabled-without-sdk = let
    c = self.lib.mkCross {inherit pkgs system;};
  in
    assert builtins.getEnv "MACOS_SDK" == "";
    assert c.osxcrossToolchain == null;
    assert c.osxcrossRustHelpers == null;
    pkgs.runCommand "check-mkCross-osxcross-default-disabled-without-sdk" {} "touch $out";

  # mkDevShells returns expected shell variants
  mkDevShells-shape = let
    s = self.lib.mkDevShells {
      inherit pkgs cross;
      inherit (toolchain) craneLib;
    };
  in
    assert s ? default;
    assert s ? windows;
    assert s ? macos;
    assert s ? cross;
    pkgs.runCommand "check-mkDevShells-shape" {} "touch $out";

  # mkDevShells accepts pkg-config dependency inputs
  mkDevShells-pkg-config-deps = let
    s = self.lib.mkDevShells {
      inherit pkgs cross;
      inherit (toolchain) craneLib;
      pkgConfigDeps = with pkgs; [
        wayland
        libxkbcommon
      ];
    };
  in
    assert s ? default;
    pkgs.runCommand "check-mkDevShells-pkg-config-deps" {} "touch $out";

  # mkCargoConfig returns expected attributes
  mkCargoConfig-shape = let
    c = self.lib.mkCargoConfig {inherit pkgs;};
  in
    assert c ? configText;
    assert c ? configPath;
    assert builtins.isString c.configText;
    pkgs.runCommand "check-mkCargoConfig-shape" {} "touch $out";

  # mkCargoConfig stable disables nightly features by default
  mkCargoConfig-stable = let
    c = self.lib.mkCargoConfig {
      inherit pkgs;
      channel = "stable";
    };
  in
    assert !(pkgs.lib.hasInfix "cranelift" c.configText);
    assert !(pkgs.lib.hasInfix "share-generics" c.configText);
    assert !(pkgs.lib.hasInfix "threads" c.configText);
    pkgs.runCommand "check-mkCargoConfig-stable" {} "touch $out";

  # mkCargoConfig nightly includes expected optimizations
  mkCargoConfig-nightly = let
    c = self.lib.mkCargoConfig {
      inherit pkgs;
      channel = "nightly";
    };
  in
    assert pkgs.lib.hasInfix "cranelift" c.configText;
    assert pkgs.lib.hasInfix "share-generics" c.configText;
    assert pkgs.lib.hasInfix "mold" c.configText;
    assert pkgs.lib.hasInfix "threads" c.configText;
    pkgs.runCommand "check-mkCargoConfig-nightly" {} "touch $out";

  # mkCargoConfig respects enableMold = false
  mkCargoConfig-no-mold = let
    c = self.lib.mkCargoConfig {
      inherit pkgs;
      enableMold = false;
    };
  in
    assert !(pkgs.lib.hasInfix "mold" c.configText);
    pkgs.runCommand "check-mkCargoConfig-no-mold" {} "touch $out";

  # Windows GNU should not force lld through the MinGW GCC wrapper
  mkCargoConfig-no-windows-gnu-lld = let
    c = self.lib.mkCargoConfig {inherit pkgs;};
  in
    assert !(pkgs.lib.hasInfix "link-arg=-fuse-ld=lld" c.configText);
    pkgs.runCommand "check-mkCargoConfig-no-windows-gnu-lld" {} "touch $out";

  # mkCargoConfig respects enableParallelFrontend = false
  mkCargoConfig-no-parallel-frontend = let
    c = self.lib.mkCargoConfig {
      inherit pkgs;
      enableParallelFrontend = false;
    };
  in
    assert !(pkgs.lib.hasInfix "threads" c.configText);
    pkgs.runCommand "check-mkCargoConfig-no-parallel-frontend" {} "touch $out";

  # mkAdapter returns expected attributes
  mkAdapter-shape = let
    a = self.lib.mkAdapter {
      attic = {endpoint = "https://cache.example.com"; cache = "main";};
    };
  in
    assert a ? _type;
    assert a._type == "harbor-adapter";
    assert a ? _version;
    assert a._version == 1;
    assert a ? attic;
    assert a.attic ? endpoint;
    assert a.attic ? cache;
    assert a.attic ? tokenEnvVar;
    assert a.attic.tokenEnvVar == "ATTIC_TOKEN";
    assert a.attic ? serverName;
    assert a.attic.serverName == "harbor";
    pkgs.runCommand "check-mkAdapter-shape" {} "touch $out";

  # mkAdapter preserves custom tokenEnvVar
  mkAdapter-custom-token = let
    a = self.lib.mkAdapter {
      attic = {endpoint = "https://cache.example.com"; cache = "main"; tokenEnvVar = "MY_TOKEN";};
    };
  in
    assert a.attic.tokenEnvVar == "MY_TOKEN";
    pkgs.runCommand "check-mkAdapter-custom-token" {} "touch $out";

  # isHarborAdapter accepts valid adapters
  isHarborAdapter-valid = let
    a = self.lib.mkAdapter {
      attic = {endpoint = "https://x.com"; cache = "c";};
    };
  in
    assert self.lib.isHarborAdapter a;
    pkgs.runCommand "check-isHarborAdapter-valid" {} "touch $out";

  # isHarborAdapter rejects invalid values
  isHarborAdapter-invalid =
    assert !(self.lib.isHarborAdapter {});
    assert !(self.lib.isHarborAdapter {_type = "wrong";});
    assert !(self.lib.isHarborAdapter "string");
    assert !(self.lib.isHarborAdapter 42);
    pkgs.runCommand "check-isHarborAdapter-invalid" {} "touch $out";

  # mkAtticPush returns a valid app attrset
  mkAtticPush-shape = let
    adapter = self.lib.mkAdapter {
      attic = {endpoint = "https://x.com"; cache = "c";};
    };
    app = self.lib.mkAtticPush {
      inherit pkgs adapter;
      paths = [pkgs.hello];
    };
  in
    assert app ? type;
    assert app.type == "app";
    assert app ? program;
    assert builtins.isString app.program;
    pkgs.runCommand "check-mkAtticPush-shape" {} "touch $out";

  # Validation logic works correctly
  validation-helpers = let
    dateRegex = "[0-9]{4}-[0-9]{2}-[0-9]{2}";
  in
    assert builtins.match dateRegex "2025-12-01" != null;
    assert builtins.match dateRegex "yesterday" == null;
    assert builtins.match dateRegex "25-12-01" == null;
    assert builtins.elem "nightly" ["nightly" "stable"];
    assert builtins.elem "stable" ["nightly" "stable"];
    assert !(builtins.elem "beta" ["nightly" "stable"]);
    pkgs.runCommand "check-validation-helpers" {} "touch $out";
}
// pkgs.lib.optionalAttrs isLinux {
  # mkFlatpakManifest returns expected attributes
  mkFlatpakManifest-shape = let
    m = self.lib.mkFlatpakManifest {
      inherit pkgs;
      appId = "com.example.TestApp";
      pname = "test-app";
      desktopFile = "[Desktop Entry]\nType=Application\nName=Test\nExec=test-app";
    };
  in
    assert m ? manifestText;
    assert m ? manifestPath;
    assert builtins.isString m.manifestText;
    assert pkgs.lib.hasInfix "com.example.TestApp" m.manifestText;
    assert pkgs.lib.hasInfix "test-app" m.manifestText;
    assert pkgs.lib.hasInfix "org.freedesktop.Platform" m.manifestText;
    assert pkgs.lib.hasInfix "24.08" m.manifestText;
    pkgs.runCommand "check-mkFlatpakManifest-shape" {} "touch $out";

  # mkFlatpakManifest respects custom runtime
  mkFlatpakManifest-custom-runtime = let
    m = self.lib.mkFlatpakManifest {
      inherit pkgs;
      appId = "org.test.App";
      pname = "myapp";
      desktopFile = "[Desktop Entry]\nType=Application\nName=Test\nExec=myapp";
      runtime = "org.gnome.Platform";
      runtimeVersion = "46";
      sdk = "org.gnome.Sdk";
    };
  in
    assert pkgs.lib.hasInfix "org.gnome.Platform" m.manifestText;
    assert pkgs.lib.hasInfix "46" m.manifestText;
    assert pkgs.lib.hasInfix "org.gnome.Sdk" m.manifestText;
    pkgs.runCommand "check-mkFlatpakManifest-custom-runtime" {} "touch $out";

  # mkFlatpakManifest respects custom finishArgs
  mkFlatpakManifest-finish-args = let
    m = self.lib.mkFlatpakManifest {
      inherit pkgs;
      appId = "org.test.App2";
      pname = "myapp2";
      desktopFile = "[Desktop Entry]\nType=Application\nName=Test\nExec=myapp2";
      finishArgs = ["--share=network" "--socket=x11"];
    };
  in
    assert pkgs.lib.hasInfix "share=network" m.manifestText;
    assert pkgs.lib.hasInfix "socket=x11" m.manifestText;
    pkgs.runCommand "check-mkFlatpakManifest-finish-args" {} "touch $out";
}
