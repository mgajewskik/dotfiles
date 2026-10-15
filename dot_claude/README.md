# Claude Code config

chezmoi manages this directory from `dot_claude/` in my dotfiles. Edit the source there, not the files here.
`settings.json` is built from `.chezmoitemplates/claude/settings.json` on every apply, keeping the keys Claude writes
itself (model, theme, plugins).

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

## One-time setup (run in a normal terminal; ~/.claude.json and plugins/ are outside the sandbox)

chezmoi already links `skills` to `~/.agents/skills` (cloned from `mgajewskik/skills`).

```sh
# MCP servers (user scope, stored in ~/.claude.json)
claude mcp add -s user --transport http context7 https://mcp.context7.com/mcp
claude mcp add -s user chrome-devtools -- npx -y chrome-devtools-mcp@1.10.1 --autoConnect

# LSP plugins (binaries must be on PATH)
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin install gopls-lsp@claude-plugins-official
claude plugin install rust-analyzer-lsp@claude-plugins-official
claude plugin install lua-lsp@claude-plugins-official
claude plugin marketplace add ~/.claude/local-plugins
claude plugin install terraform-lsp@personal
```

MCP servers run outside the Bash sandbox and the Edit/Write hook (e.g. chrome-devtools can save screenshots anywhere).

chrome-devtools `--autoConnect` attaches to your running Chrome: enable it once at `chrome://inspect/#remote-debugging`.
