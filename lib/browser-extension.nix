{
  mkBrowserExtension = {
    pkgs,
    pname,
    version,
    src,
    extensionId,
  }: let
    manifestPath = src + "/manifest.json";
    manifest = builtins.fromJSON (builtins.readFile manifestPath);
    xpiPath = "share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/${extensionId}.xpi";
    package =
      pkgs.runCommand "${pname}-${version}" {
        nativeBuildInputs = [pkgs.jq pkgs.zip];
        passthru = {
          rsHarbor = {
            helper = "mkBrowserExtension";
            inherit extensionId;
          };
          xpi = "${package}/${xpiPath}";
        };
        meta.platforms = pkgs.lib.platforms.all;
      } ''
        test -f ${pkgs.lib.escapeShellArg "${src}/manifest.json"} || { echo 'mkBrowserExtension: manifest.json is missing' >&2; exit 1; }
        jq -es --arg version ${pkgs.lib.escapeShellArg version} --arg id ${pkgs.lib.escapeShellArg extensionId} \
          'length == 1 and .[0].version == $version and .[0].browser_specific_settings.gecko.id == $id' ${pkgs.lib.escapeShellArg "${src}/manifest.json"} >/dev/null \
          || { echo 'mkBrowserExtension: manifest version or gecko id does not match' >&2; exit 1; }
        cp -R ${pkgs.lib.escapeShellArg "${src}"} source
        test -z "$(find source -type l)" || { echo 'mkBrowserExtension: src must not contain symlinks' >&2; exit 1; }
        chmod -R u+w source
        cd source
        export TZ=UTC
        find . -exec touch -h -d @315532800 {} +
        xpi="$out"/${pkgs.lib.escapeShellArg xpiPath}
        mkdir -p "$(dirname "$xpi")"
        find . -type f -printf '%P\n' | LC_ALL=C sort | zip -X -q "$xpi" -@
      '';
  in
    assert builtins.isString extensionId && builtins.match "[^/\n]+" extensionId != null && extensionId != "." && extensionId != ".." || throw "mkBrowserExtension: extensionId must be a non-empty filename";
    assert !builtins.isPath src || builtins.pathExists manifestPath || throw "mkBrowserExtension: manifest.json is missing";
    assert !builtins.isPath src || (manifest.version or null) == version || throw "mkBrowserExtension: manifest version does not match version";
    assert !builtins.isPath src || (manifest.browser_specific_settings.gecko.id or null) == extensionId || throw "mkBrowserExtension: manifest gecko id does not match extensionId"; package;

  mkNativeMessagingHost = {
    pkgs,
    name,
    description,
    program,
    allowedExtensions,
  }:
    assert builtins.isString name && builtins.match "[a-z0-9_]+(\\.[a-z0-9_]+)*" name != null || throw "mkNativeMessagingHost: invalid name";
    assert builtins.isList allowedExtensions && allowedExtensions != [] && builtins.all builtins.isString allowedExtensions || throw "mkNativeMessagingHost: allowedExtensions must be a non-empty list of strings";
    assert builtins.isString program && pkgs.lib.hasPrefix "/" program || throw "mkNativeMessagingHost: program must be an absolute path string";
      (pkgs.writeTextDir "lib/mozilla/native-messaging-hosts/${name}.json" (builtins.toJSON {
        inherit name description;
        path = program;
        type = "stdio";
        allowed_extensions = allowedExtensions;
      })).overrideAttrs (_: {
        passthru.rsHarbor = {
          helper = "mkNativeMessagingHost";
          inherit name;
        };
      });
}
