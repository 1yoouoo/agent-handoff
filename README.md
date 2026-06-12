# agent-handoff

Pick a local AI coding agent session and continue it in another agent.

Currently supports raw transcript handoff between Claude Code and Codex.

This is not native session import. It copies the selected raw transcript and asks the target agent to continue from it.

## Usage

```sh
agent-handoff
```

The picker opens scoped to your current directory (climbing up until it finds sessions). Each row shows when the session was last active, which agent it belongs to, its folder relative to the current scope, and the session title.

- `←` widens the scope to the parent folder.
- `→` narrows the scope to the highlighted session's folder.
- `↑` / `↓` browse, typing searches, `Enter` picks a session.
- Then pick the agent that should continue from that transcript.

The target agent is launched with a plain `claude` or `codex` command. To add flags, override it:

```sh
export AGENT_HANDOFF_CLAUDE_CMD="claude --model sonnet"
export AGENT_HANDOFF_CODEX_CMD="codex --full-auto"
```

## Requirements

- `bash`
- `jq`
- `fzf` is optional. Without it, `agent-handoff` falls back to numbered prompts.
