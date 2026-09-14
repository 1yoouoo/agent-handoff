#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: expected to contain '$needle'"
}

assert_file_exists() {
  local file="$1"
  local label="$2"
  [[ -f "$file" ]] || fail "$label: missing file $file"
}

make_fixture() {
  local tmp="$1"
  local project="$tmp/work/demo"
  local claude_project_key="${project//\//-}"
  local claude_dir="$tmp/claude/projects/$claude_project_key"
  local codex_dir="$tmp/codex/sessions/2026/06/12"

  mkdir -p "$project" "$claude_dir" "$codex_dir"

  cat > "$claude_dir/claude-session.jsonl" <<EOF
{"type":"ai-title","sessionId":"claude-1","title":"Claude fixture title"}
{"type":"user","sessionId":"claude-1","cwd":"$project","message":{"role":"user","content":"Please fix the UI"}}
{"type":"assistant","sessionId":"claude-1","cwd":"$project","message":{"role":"assistant","content":"I changed the UI"}}
{"type":"user","sessionId":"claude-1","cwd":"$project","message":{"role":"user","content":"Now add a test"}}
EOF

  cat > "$codex_dir/rollout-codex-session.jsonl" <<EOF
{"type":"session_meta","timestamp":"2026-06-12T00:00:00.000Z","payload":{"id":"codex-1","cwd":"$project"}}
{"type":"response_item","timestamp":"2026-06-12T00:00:01.000Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Please continue"}]}}
{"type":"response_item","timestamp":"2026-06-12T00:00:02.000Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Continuing"}]}}
EOF

  # Deterministic ordering: claude session is the most recent.
  touch -t 202606121200 "$codex_dir/rollout-codex-session.jsonl"
  touch -t 202606121201 "$claude_dir/claude-session.jsonl"

  printf '%s\n' "$project"
}

test_lists_projects_from_both_agents() {
  local tmp project output
  tmp="$(mktemp -d)"
  project="$(make_fixture "$tmp")"

  output="$(
    AGENT_HANDOFF_HOME="$tmp/out" \
    AGENT_HANDOFF_CLAUDE_HOME="$tmp/claude" \
    AGENT_HANDOFF_CODEX_HOME="$tmp/codex" \
    "$ROOT_DIR/bin/agent-handoff" __test_list_projects
  )"

  assert_contains "$output" "$project" "project list"
  assert_contains "$output" "claude=1" "project list"
  assert_contains "$output" "codex=1" "project list"
  pass "lists projects from Claude and Codex stores"
}

test_creates_raw_handoff_and_dry_runs_target() {
  local tmp project output handoff_file
  tmp="$(mktemp -d)"
  project="$(make_fixture "$tmp")"

  output="$(
    AGENT_HANDOFF_HOME="$tmp/out" \
    AGENT_HANDOFF_CLAUDE_HOME="$tmp/claude" \
    AGENT_HANDOFF_CODEX_HOME="$tmp/codex" \
    AGENT_HANDOFF_PICK_PROJECT=1 \
    AGENT_HANDOFF_PICK_SESSION=1 \
    AGENT_HANDOFF_PICK_TARGET=codex \
    AGENT_HANDOFF_ASSUME_YES=1 \
    AGENT_HANDOFF_DRY_RUN=1 \
    "$ROOT_DIR/bin/agent-handoff"
  )"

  assert_contains "$output" "Session: Claude Code" "dry run output"
  assert_contains "$output" "Now add a test" "dry run output"
  assert_contains "$output" "Target:  Codex" "dry run output"
  assert_contains "$output" "Command: codex" "dry run output"
  assert_contains "$output" "override with AGENT_HANDOFF_CODEX_CMD" "dry run output"

  handoff_file="$(printf '%s\n' "$output" | awk -F': ' '/Handoff:/ {print $2}' | tail -n 1)"
  assert_file_exists "$handoff_file" "handoff copy"
  cmp "$tmp/claude/projects/${project//\//-}/claude-session.jsonl" "$handoff_file" >/dev/null ||
    fail "handoff copy: raw transcript differs"
  pass "creates raw handoff and dry-runs selected target"
}

test_codex_session_uses_first_user_message_as_title() {
  local tmp project output
  tmp="$(mktemp -d)"
  project="$(make_fixture "$tmp")"

  output="$(
    AGENT_HANDOFF_HOME="$tmp/out" \
    AGENT_HANDOFF_CLAUDE_HOME="$tmp/claude" \
    AGENT_HANDOFF_CODEX_HOME="$tmp/codex" \
    AGENT_HANDOFF_PICK_PROJECT=1 \
    AGENT_HANDOFF_PICK_SESSION=2 \
    AGENT_HANDOFF_PICK_TARGET=claude \
    AGENT_HANDOFF_ASSUME_YES=1 \
    AGENT_HANDOFF_DRY_RUN=1 \
    "$ROOT_DIR/bin/agent-handoff"
  )"

  assert_contains "$output" "Session: Codex" "codex session output"
  assert_contains "$output" "Please continue" "codex session output"
  assert_contains "$output" "Command: claude" "codex session output"
  pass "codex session title comes from the latest user message"
}

test_claude_title_falls_back_to_ai_title() {
  local tmp project claude_dir output
  tmp="$(mktemp -d)"
  project="$tmp/work/notes"
  claude_dir="$tmp/claude/projects/${project//\//-}"
  mkdir -p "$project" "$claude_dir" "$tmp/codex/sessions"

  # A session with no genuine user message — only an ai-title and noise.
  cat > "$claude_dir/s.jsonl" <<EOF
{"type":"ai-title","sessionId":"a","title":"Summarized title"}
{"type":"user","sessionId":"a","cwd":"$project","message":{"role":"user","content":"<command-name>/init</command-name>"}}
EOF

  output="$(
    AGENT_HANDOFF_HOME="$tmp/out" \
    AGENT_HANDOFF_CLAUDE_HOME="$tmp/claude" \
    AGENT_HANDOFF_CODEX_HOME="$tmp/codex" \
    AGENT_HANDOFF_PICK_PROJECT=1 \
    AGENT_HANDOFF_PICK_SESSION=1 \
    AGENT_HANDOFF_PICK_TARGET=codex \
    AGENT_HANDOFF_ASSUME_YES=1 \
    AGENT_HANDOFF_DRY_RUN=1 \
    "$ROOT_DIR/bin/agent-handoff"
  )"

  assert_contains "$output" "Summarized title" "ai-title fallback"
  pass "claude title falls back to ai-title when no real user message"
}

test_rename_title_takes_priority() {
  local tmp project claude_dir codex_dir output

  # Claude: a custom-title (set via /rename) overrides the latest message.
  tmp="$(mktemp -d)"
  project="$tmp/work/app"
  claude_dir="$tmp/claude/projects/${project//\//-}"
  mkdir -p "$project" "$claude_dir" "$tmp/codex/sessions"
  cat > "$claude_dir/s.jsonl" <<EOF
{"type":"user","sessionId":"a","cwd":"$project","message":{"role":"user","content":"first message"}}
{"type":"custom-title","sessionId":"a","customTitle":"My renamed session"}
{"type":"user","sessionId":"a","cwd":"$project","message":{"role":"user","content":"a later message"}}
EOF
  output="$(
    AGENT_HANDOFF_HOME="$tmp/out" AGENT_HANDOFF_CLAUDE_HOME="$tmp/claude" \
    AGENT_HANDOFF_CODEX_HOME="$tmp/codex" AGENT_HANDOFF_PICK_PROJECT=1 \
    AGENT_HANDOFF_PICK_SESSION=1 AGENT_HANDOFF_PICK_TARGET=codex \
    AGENT_HANDOFF_ASSUME_YES=1 AGENT_HANDOFF_DRY_RUN=1 \
    "$ROOT_DIR/bin/agent-handoff"
  )"
  assert_contains "$output" "My renamed session" "claude custom-title priority"

  # Codex: thread_name from session_index.jsonl overrides the message.
  tmp="$(mktemp -d)"
  project="$tmp/work/cdx"
  codex_dir="$tmp/codex/sessions/2026/06/12"
  mkdir -p "$project" "$codex_dir" "$tmp/claude/projects"
  cat > "$codex_dir/rollout-x.jsonl" <<EOF
{"type":"session_meta","payload":{"id":"cdx-9","cwd":"$project"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"some message"}]}}
EOF
  printf '%s\n' '{"id":"cdx-9","thread_name":"Codex renamed thread","updated_at":"x"}' \
    > "$tmp/codex/session_index.jsonl"
  output="$(
    AGENT_HANDOFF_HOME="$tmp/out" AGENT_HANDOFF_CLAUDE_HOME="$tmp/claude" \
    AGENT_HANDOFF_CODEX_HOME="$tmp/codex" AGENT_HANDOFF_PICK_PROJECT=1 \
    AGENT_HANDOFF_PICK_SESSION=1 AGENT_HANDOFF_PICK_TARGET=claude \
    AGENT_HANDOFF_ASSUME_YES=1 AGENT_HANDOFF_DRY_RUN=1 \
    "$ROOT_DIR/bin/agent-handoff"
  )"
  assert_contains "$output" "Codex renamed thread" "codex thread_name priority"
  pass "rename (custom-title / thread_name) takes priority"
}

test_handoff_keeps_latest_30_messages() {
  local tmp agent count source_file handoff_file first expected actual i mode
  tmp="$(mktemp -d)"

  for agent in claude codex; do
    for count in 0 29 30 31 35; do
      source_file="$tmp/$agent-$count.jsonl"
      jq -cn --arg agent "$agent" --argjson count "$count" '
        {type: "session_meta", payload: {id: "fixture", cwd: "/work/demo"}},
        (range(1; $count + 1) as $i |
          (if $i % 2 == 1 then "user" else "assistant" end) as $role |
          if $agent == "claude" then
            {type: $role, fixture_message: $i, message: {content:
              (if $role == "user" then "message \($i)"
               else [{type: "text", text: "message \($i)"}] end)}},
            {type: "assistant", fixture_tool: $i, message: {content: [{type: "tool_use", id: "call-\($i)", name: "Read", input: {}}]}},
            {type: "user", fixture_tool: $i, message: {content: [{type: "tool_result", tool_use_id: "call-\($i)", content: "result"}]}}
          else
            {type: "response_item", fixture_message: $i, payload: {type: "message", role: $role, content:
              [{type: (if $role == "user" then "input_text" else "output_text" end), text: "message \($i)"}]}},
            {type: "response_item", fixture_tool: $i, payload: {type: "function_call", call_id: "call-\($i)", name: "exec_command", arguments: "{}"}},
            {type: "response_item", fixture_tool: $i, payload: {type: "function_call_output", call_id: "call-\($i)", output: "result"}}
          end)
      ' > "$source_file"
      chmod 600 "$source_file"
      cp "$source_file" "$tmp/original.jsonl"

      handoff_file="$(
        source "$ROOT_DIR/lib/agent-handoff.sh"
        umask 022
        AGENT_HANDOFF_HOME="$tmp/out/$agent/$count" \
          agent_handoff_copy_raw "$source_file" "$agent" codex /work/demo
      )"
      first=1
      (( count <= 30 )) || first=$((count - 29))
      expected="$(for ((i=first; i<=count; i++)); do printf '%s\n' "$i"; done)"
      actual="$(jq -r 'select(has("fixture_message")) | .fixture_message' "$handoff_file")"
      [[ "$actual" == "$expected" ]] || fail "$agent/$count: expected latest 30 messages"
      actual="$(jq -r 'select(has("fixture_tool")) | .fixture_tool' "$handoff_file")"
      expected="$(for ((i=first; i<=count; i++)); do printf '%s\n%s\n' "$i" "$i"; done)"
      [[ "$actual" == "$expected" ]] || fail "$agent/$count: tool calls and results were lost"

      if (( count <= 30 )); then
        cmp "$source_file" "$handoff_file" >/dev/null || fail "$agent/$count: short transcript changed"
      elif [[ "$agent" == codex ]]; then
        [[ "$(head -n 1 "$handoff_file")" == "$(head -n 1 "$source_file")" ]] || fail "codex: session metadata was lost"
      fi
      mode="$(stat -f '%Lp' "$handoff_file" 2>/dev/null || stat -c '%a' "$handoff_file")"
      [[ "$mode" == 600 ]] || fail "$agent/$count: handoff permissions should be 600, got $mode"
      cmp "$source_file" "$tmp/original.jsonl" >/dev/null || fail "$agent/$count: original transcript changed"
    done
  done
  rm -rf "$tmp"
  pass "handoffs keep the latest 30 messages and their tool records for both agents"
}

test_handoff_uses_snapshot_when_source_grows() {
  local tmp count source_file handoff_file actual expected i first
  tmp="$(mktemp -d)"
  for count in 30 31; do
    source_file="$tmp/source-$count.jsonl"
    jq -cn --argjson count "$count" '
      {type: "session_meta", payload: {id: "fixture", cwd: "/work/demo"}},
      (range(1; $count + 1) as $i |
        {type: "response_item", fixture_message: $i, payload: {type: "message", role: "user",
          content: [{type: "input_text", text: "message \($i)"}]}})
    ' > "$source_file"
    handoff_file="$(
      source "$ROOT_DIR/lib/agent-handoff.sh"
      # Simulate an active agent appending after the cutoff scan completes.
      jq() {
        command jq "$@"
        printf '%s\n' '{"type":"response_item","fixture_message":999,"payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"new message"}]}}' >> "$source_file"
      }
      AGENT_HANDOFF_HOME="$tmp/out/$count" \
        agent_handoff_copy_raw "$source_file" codex claude /work/demo
    )"
    first=$((count - 29))
    expected="$(for ((i=first; i<=count; i++)); do printf '%s\n' "$i"; done)"
    actual="$(jq -r 'select(has("fixture_message")) | .fixture_message' "$handoff_file")"
    [[ "$actual" == "$expected" ]] || fail "$count: source append changed the 30-message snapshot"
    [[ "$(jq -r 'select(has("fixture_message")) | .fixture_message' "$source_file" | tail -n 1)" == 999 ]] ||
      fail "source append fixture did not run"
  done
  rm -rf "$tmp"
  pass "handoffs retain a stable snapshot when the source grows"
}

test_install_adds_path_to_zsh_profile_once() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/home"

  HOME="$tmp/home" SHELL=/bin/zsh ZDOTDIR="" \
  AGENT_HANDOFF_REPO_URL="$ROOT_DIR" \
    sh "$ROOT_DIR/install.sh" >/dev/null 2>&1

  assert_file_exists "$tmp/home/.agent-handoff/bin/agent-handoff" "install clone"
  assert_contains "$(cat "$tmp/home/.zshrc")" '.agent-handoff/bin' "zshrc path line"

  HOME="$tmp/home" SHELL=/bin/zsh ZDOTDIR="" \
  AGENT_HANDOFF_REPO_URL="$ROOT_DIR" \
    sh "$ROOT_DIR/install.sh" >/dev/null 2>&1

  [[ "$(grep -c 'agent-handoff/bin' "$tmp/home/.zshrc")" == "1" ]] ||
    fail "install: PATH line duplicated on reinstall"
  pass "install adds PATH to .zshrc exactly once"
}

test_confirm_accepts_yes_and_rejects_no() {
  local tmp project output
  tmp="$(mktemp -d)"
  project="$(make_fixture "$tmp")"

  output="$(
    printf 'yes\n' |
    AGENT_HANDOFF_HOME="$tmp/out" \
    AGENT_HANDOFF_CLAUDE_HOME="$tmp/claude" \
    AGENT_HANDOFF_CODEX_HOME="$tmp/codex" \
    AGENT_HANDOFF_PICK_PROJECT=1 \
    AGENT_HANDOFF_PICK_SESSION=1 \
    AGENT_HANDOFF_PICK_TARGET=codex \
    AGENT_HANDOFF_DRY_RUN=1 \
    "$ROOT_DIR/bin/agent-handoff"
  )"
  assert_contains "$output" "Dry run command" "confirm yes"

  if printf 'no\n' |
    AGENT_HANDOFF_HOME="$tmp/out" \
    AGENT_HANDOFF_CLAUDE_HOME="$tmp/claude" \
    AGENT_HANDOFF_CODEX_HOME="$tmp/codex" \
    AGENT_HANDOFF_PICK_PROJECT=1 \
    AGENT_HANDOFF_PICK_SESSION=1 \
    AGENT_HANDOFF_PICK_TARGET=codex \
    AGENT_HANDOFF_DRY_RUN=1 \
    "$ROOT_DIR/bin/agent-handoff" >/dev/null 2>&1; then
    fail "confirm no: expected non-zero exit"
  fi
  pass "confirm accepts yes and rejects no"
}

test_help_and_version_and_update() {
  local output

  output="$("$ROOT_DIR/bin/agent-handoff" help)"
  assert_contains "$output" "agent-handoff update" "help output"

  output="$("$ROOT_DIR/bin/agent-handoff" badarg 2>&1 || true)"
  assert_contains "$output" "Unknown argument" "unknown arg"

  # version/update on a non-git install dir degrade gracefully.
  local tmp
  tmp="$(mktemp -d)"
  output="$(AGENT_HANDOFF_INSTALL_DIR="$tmp" "$ROOT_DIR/bin/agent-handoff" version)"
  assert_contains "$output" "unknown" "version without git checkout"

  output="$(AGENT_HANDOFF_INSTALL_DIR="$tmp" "$ROOT_DIR/bin/agent-handoff" update 2>&1 || true)"
  assert_contains "$output" "cannot self-update" "update without git checkout"
  pass "help, version, and update behave"
}

test_lists_projects_from_both_agents
test_creates_raw_handoff_and_dry_runs_target
test_codex_session_uses_first_user_message_as_title
test_claude_title_falls_back_to_ai_title
test_rename_title_takes_priority
test_handoff_keeps_latest_30_messages
test_handoff_uses_snapshot_when_source_grows
test_install_adds_path_to_zsh_profile_once
test_confirm_accepts_yes_and_rejects_no
test_help_and_version_and_update
