# Host build observations

The build pool observes current-user build processes and host pressure. It does
not limit, coordinate, or alter builds.

Enable the NixOS user service with:

```nix
{
  imports = [harbor-rs.nixosModules.buildPool];
  programs.harborRs.buildPool = {
    enable = true;
    interval = 10; # seconds
    # package = harbor-rs.packages.${pkgs.system}.harbor-rs;
  };
}
```

Or start it manually with `harbor-rs pool serve --observe --interval 10`.
Read the latest snapshot with `harbor-rs pool status` or
`harbor-rs pool status --json`; `--cwd PATH` and `--build-dir PATH` filter
the process and build-directory lists. The host and class totals remain
host-wide. Observations are retained for 8 days in
`$XDG_STATE_HOME/harbor-rs/pool/` (default `~/.local/state`).

Run `harbor-rs mcp` as a stdio MCP server and call `build_status` with
optional `cwd` and `build_dir` strings. Check before a heavy build in a shared
checkout; do not sleep-poll. Snapshots contain command lines and local paths;
the user socket is private, and the log directory should be protected as
sensitive data.
