# Claude Code config

chezmoi manages this directory from `dot_claude/` in my dotfiles. Edit the source there, not the files here.
`settings.json` is built from `.chezmoitemplates/claude/settings.json` on every apply, keeping the keys Claude writes
itself (model, theme, plugins). jq does the merge and keeps the file's key order, so it has to be on `PATH` or in
mise before the apply; the container installs it in `post-create.sh`.

## Host and container

On a host, Claude runs in the sandbox with the guards below. In a container (chezmoi's `.container`) there is no
sandbox: Claude runs in auto mode, the `remote` patterns are denied, and an `autoMode` block tells the classifier the
container is disposable, so Claude installs tools there without asking. The classifier's default blocks on remote,
destructive, and exfiltrating actions still apply. I run remote destructive commands myself. `claude auto-mode config` prints the rules in effect.

## Launch modes (host)

- `claude`: auto mode; sandboxed Bash runs without prompts except `ask` patterns (reads anywhere except `~/.ssh`, `~/.aws`, `~/.gnupg`; writes only in cwd + allowed roots). MCP tools other than context7 and web fetches still prompt. Because of the read block, git over SSH and AWS CLI auth don't work from Claude's Bash.
- `claude --settings ~/.claude/profiles/strict.json`: same, plus no reads outside cwd (shell and file tools).

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

## Bash deny/ask rules

Patterns live in `.chezmoidata/claude.yaml` in my dotfiles; `chezmoi apply` turns each into `Bash(X)` plus
`rtk X` / `rtk * X` variants:

| List | Host | Container |
| --- | --- | --- |
| `deny`: local damage (sudo, disks, `git reset --hard`) | deny | classifier |
| `remote`: external and irreversible (force push, cloud deletes, publishing) | deny | deny |
| `ask`: PR merges and global installs | ask | classifier |

`rm -rf` is not on the host `deny` list: it works inside the project, and outside it the sandbox's write boundary fails
it with `Read-only file system`. The exception is the paths the sandbox can write to anyway (`sandbox.filesystem.allowWrite`
and `~/.agents/skills`): a delete there runs sandboxed and is auto-allowed, reviewed only in sessions with server-side
classifier review.

Sandbox `allowWrite` paths that tools add on a machine (terminal-browser) are kept, so a path dropped from the template
stays on machines that already have it until I delete it there.

Non-Bash rules such as `Read(~/.ssh/**)` sit in the settings template; a `Read` deny also blocks sandboxed Bash from
reading the path.

## Plugins and MCP servers

chezmoi links `skills` to `~/.agents/skills` (cloned from `mgajewskik/skills`).

`.chezmoiscripts/run_onchange_after_plugins_claude.sh.tmpl` runs on every machine, host and container, when its
lists change. It does three things:

- registers both marketplaces with `claude plugin marketplace add`. Declaring them in `settings.json` does not fetch
  them, and installs fail with "not found in marketplace" until they are fetched;
- installs each plugin the template's `enabledPlugins` turns on;
- sets the user MCP servers in `~/.claude.json` (context7). For a browser, Claude uses agent-browser from mise.

To add a plugin, I add it to the template's `enabledPlugins`. To add or change an MCP server, I edit that script.
`claude plugin disable` keeps a plugin off on one machine. The language servers must be on `PATH`: nvim's mason
installs them, the npm-based ones (bash, typescript) with node from mise, and ty comes from mise.

MCP servers run outside the Bash sandbox and the Edit/Write hook.
