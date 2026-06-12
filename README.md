# agent-handoff

> Pick a local AI coding agent session and let another agent continue it.

Currently supports raw transcript handoff between Claude Code and Codex.

This is not native session import — it copies the selected session's raw transcript (JSONL) and launches the target agent with a prompt asking it to read the file and continue from the latest unresolved point.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/1yoouoo/agent-handoff/main/install.sh | sh
```

This clones the repo to `~/.agent-handoff` and adds its `bin` directory to your shell profile (zsh, bash, and fish are detected automatically). If `jq` or `fzf` is missing, the installer offers to install them with your package manager (brew, apt, dnf, or pacman). Restart your shell afterwards.

Manual install:

```sh
git clone https://github.com/1yoouoo/agent-handoff.git ~/.agent-handoff
export PATH="$HOME/.agent-handoff/bin:$PATH"   # add to your shell profile
```

## Usage

```sh
agent-handoff
```

A session browser opens scoped to your current directory (climbing up until it finds sessions). Each row shows when the session was last active, which agent it belongs to, its folder relative to the current scope, and the session title.

| Key | Action |
|---|---|
| `←` | Widen the scope to the parent folder |
| `→` | Narrow the scope to the highlighted session's folder |
| `↑` `↓` | Browse sessions |
| Type | Search |
| `Enter` | Pick a session |
| `Esc` | Exit |

After picking a session, choose the agent that should continue it. A summary is shown, and on confirmation the target agent launches.

### Other commands

```sh
agent-handoff update     # pull the latest version
agent-handoff version    # print the installed version
agent-handoff help       # show usage
```

## How it works

1. Scans session transcripts in `~/.claude/projects` and `~/.codex/sessions`. Only the first and last lines of each file are read, and titles are cached on disk, so scanning stays fast.
2. Copies the selected transcript to `~/.agent-handoff/handoffs/<project>/` — the original is never touched.
3. Launches the target agent in the current directory with a handoff prompt pointing at the copy.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `AGENT_HANDOFF_CLAUDE_CMD` | `claude` | Command used to launch Claude Code |
| `AGENT_HANDOFF_CODEX_CMD` | `codex` | Command used to launch Codex |
| `AGENT_HANDOFF_HOME` | `~/.agent-handoff` | Where handoff copies and caches are stored |
| `AGENT_HANDOFF_CLAUDE_HOME` | `~/.claude` | Claude Code data directory |
| `AGENT_HANDOFF_CODEX_HOME` | `~/.codex` | Codex data directory |

Override the launch commands to add flags, e.g. `export AGENT_HANDOFF_CLAUDE_CMD="claude --model sonnet"`.

## Requirements

- `bash`, `jq`
- `fzf` — optional; falls back to numbered prompts without it
- `git` — install only

The installer offers to install `jq` and `fzf` for you if they are missing.

## License

MIT
