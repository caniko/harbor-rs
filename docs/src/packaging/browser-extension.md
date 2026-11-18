# Firefox and Floorp extensions

`harbor-rs.lib.mkBrowserExtension` accepts `pkgs`, `pname`, `version`, `src` (a directory containing `manifest.json`) and `extensionId`. It validates the manifest version and Gecko ID and produces `share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/<extensionId>.xpi` (also exposed as `xpi`).

`harbor-rs.lib.mkNativeMessagingHost` accepts `pkgs`, `name`, `description`, an absolute `program` string, and a non-empty list of `allowedExtensions`. It writes `lib/mozilla/native-messaging-hosts/<name>.json`.

For example, in a Home Manager module (both settings must target the same browser):

```nix
let
  extension = harbor-rs.lib.mkBrowserExtension {
    inherit pkgs;
    pname = "example";
    version = "1.0";
    src = ./extension;
    extensionId = "example@example.org";
  };
  host = harbor-rs.lib.mkNativeMessagingHost {
    inherit pkgs;
    name = "org.example.host";
    description = "Example host";
    program = "${examplePackage}/bin/example-host";
    allowedExtensions = ["example@example.org"];
  };
in {
  programs.floorp.profiles.default.extensions.packages = [extension];
  programs.floorp.nativeMessagingHosts = [host];
}
```

Signing and AMO publication remain consumer-owned: release Firefox only installs signed add-ons, so use `programs.firefox` with a signed `.xpi`, or a browser that permits unsigned ones.
