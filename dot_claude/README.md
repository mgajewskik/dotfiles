# Claude Code config

chezmoi manages this directory from `dot_claude/` in my dotfiles. Edit the source there, not the files here.
`settings.json` is built from `.chezmoitemplates/claude/settings.json` on every apply, keeping the keys Claude writes
itself (model, theme, plugins). jq does the merge and keeps the file's key order, so it has to be on `PATH` or in
mise before the apply; the container installs it in `post-create.sh`.

On a host Claude runs in the Bash sandbox; in a container it runs without one, in auto mode. The Bash rules live in
`.chezmoidata/claude.yaml`. `claude auto-mode config` prints the rules in effect.

## Launch modes (host)

- `claude`: auto mode. git over SSH and AWS CLI auth don't work from Claude's Bash; I run those myself.
- `claude --settings ~/.claude/profiles/strict.json`: same, plus no reads outside cwd.

Shell alias and launch guard (add to `~/.zshrc`):

```sh
alias claude-strict='claude --settings ~/.claude/profiles/strict.json'

# While any sandboxed Bash command runs, the sandbox leaves an empty
# ~/.claude/.config.json mount point. Claude Code reads that path as its legacy
# global config instead of ~/.claude.json: it either refuses to start ("JSON
# Parse error: Unexpected EOF") or saves a fresh config there, which then
# shadows ~/.claude.json. Remove it (or move it aside if non-empty) at launch.
claude() {
    local legacy="$HOME/.claude/.config.json"
    if [[ -f $legacy && ! -L $legacy && -f $HOME/.claude.json ]]; then
        if [[ -s $legacy ]]; then
            mv -- "$legacy" "$legacy.stray.$(date +%s)"
        else
            rm -f -- "$legacy"
        fi
    fi
    command claude "$@"
}
```

## Plugins and MCP servers

chezmoi links `skills` to `~/.agents/skills` (cloned from `mgajewskik/skills`).

`.chezmoiscripts/run_onchange_after_plugins_claude.sh.tmpl` runs on every machine, host and container, when its
lists change. It registers both marketplaces, installs each plugin the template's `enabledPlugins` turns on, and sets
the user MCP servers in `~/.claude.json` (context7). For a browser, Claude uses agent-browser from mise.

To add a plugin, I add it to the template's `enabledPlugins`. To add or change an MCP server, I edit that script.
`claude plugin disable` keeps a plugin off on one machine. The language servers must be on `PATH`: nvim's mason
installs them, the npm-based ones (bash, typescript) with node from mise, and ty comes from mise.
