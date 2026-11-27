//! `harbor-rs audit` — check that release-staged binaries only depend on
//! libraries available in the target deployment environment.
//!
//! Three flavours match the three native binary formats: `elf` (Linux,
//! e.g. Steam Runtime sniper), `pe` (Windows), `macho` (macOS).

use clap::Subcommand;

pub(crate) mod common;
pub(crate) mod elf;
pub(crate) mod macho;
pub(crate) mod pe;

#[derive(Subcommand, Debug)]
pub(crate) enum AuditCommand {
    /// Audit ELF executables/shared objects for forbidden RPATHs and
    /// disallowed `DT_NEEDED` entries (Linux / Steam Runtime).
    Elf(elf::AuditElfArgs),
    /// Audit PE executables for disallowed imported DLLs and forbidden
    /// embedded path strings (Windows).
    Pe(pe::AuditPeArgs),
    /// Audit Mach-O binaries for disallowed dylib dependencies (macOS).
    Macho(macho::AuditMachoArgs),
}

pub(crate) fn run(cmd: &AuditCommand) -> anyhow::Result<()> {
    match cmd {
        AuditCommand::Elf(args) => elf::run(args),
        AuditCommand::Pe(args) => pe::run(args),
        AuditCommand::Macho(args) => macho::run(args),
    }
}
