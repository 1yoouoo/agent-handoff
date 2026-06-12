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
  assert_contains "$output" "Claude fixture title" "dry run output"
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
  pass "codex session title comes from first user message"
}

test_lists_projects_from_both_agents
test_creates_raw_handoff_and_dry_runs_target
test_codex_session_uses_first_user_message_as_title
