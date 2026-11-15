{pkgs}:
# The user daemon is one sccache server shared by every build of a user for
# hours. Stock sccache SIGKILLs a rustc whose client disconnected, and the
# jobserver tokens that rustc borrowed never come back; once the pool is empty
# no compile can start and every client hangs (mozilla/sccache#2874). The patch
# moves new work to a fresh pool when a compiler sharing the jobserver dies by
# a signal or is cancelled. Drop it once nixpkgs ships an sccache with the fix.
pkgs.sccache.overrideAttrs (old:
    assert pkgs.lib.assertMsg (builtins.elem old.version ["0.18.0" "0.19.0"])
    "harbor-rs: rebase patches/sccache-jobserver-replace-leaked-pool.patch onto sccache ${old.version}, or drop it if upstream fixed mozilla/sccache#2874"; {
      patches = (old.patches or []) ++ [./../patches/sccache-jobserver-replace-leaked-pool.patch];
    })
