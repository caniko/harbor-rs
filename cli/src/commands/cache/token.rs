use clap::Subcommand;

pub(crate) mod issue;

#[derive(Subcommand, Debug)]
pub(crate) enum TokenCommand {
    /// Issue a fresh Attic token for a project.
    Issue(issue::TokenIssueArgs),
}

pub(crate) fn run(cmd: &TokenCommand) -> anyhow::Result<()> {
    match cmd {
        TokenCommand::Issue(args) => issue::run(args),
    }
}
