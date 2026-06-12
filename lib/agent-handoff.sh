#!/usr/bin/env bash

agent_handoff_home() {
  printf '%s\n' "${AGENT_HANDOFF_HOME:-$HOME/.agent-handoff}"
}

agent_handoff_claude_home() {
  printf '%s\n' "${AGENT_HANDOFF_CLAUDE_HOME:-$HOME/.claude}"
}

agent_handoff_codex_home() {
  printf '%s\n' "${AGENT_HANDOFF_CODEX_HOME:-$HOME/.codex}"
}

agent_handoff_mtime_label() {
  stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1" 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M'
}

agent_handoff_mtimes() {
  stat -f '%m' "$@" 2>/dev/null || stat -c '%Y' "$@" 2>/dev/null
}

agent_handoff_project_key() {
  local cwd="$1"
  cwd="${cwd%/}"
  cwd="${cwd//\//-}"
  cwd="${cwd//[^A-Za-z0-9._-]/_}"
  printf '%s\n' "$cwd"
}

agent_handoff_requirements() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'agent-handoff requires jq.\n' >&2
    exit 1
  fi
}

agent_handoff_spinner() {
  local msg="$1"
  shift

  if [[ ! -t 2 ]]; then
    "$@"
    return
  fi

  local tmp rc=0
  tmp="$(mktemp)"
  "$@" > "$tmp" &
  local pid=$!
  local frames='|/-\' i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s %s' "${frames:i % 4:1}" "$msg" >&2
    i=$((i + 1))
    sleep 0.1
  done
  wait "$pid" || rc=$?
  printf '\r\033[K' >&2
  cat "$tmp"
  rm -f "$tmp"
  return "$rc"
}

# Index record: cwd \t agent_id \t agent_label \t file \t mtime
# Only the first/last lines of each transcript are read here; titles are
# extracted lazily per project in agent_handoff_sessions_display.

agent_handoff_claude_dir_cwd() {
  local dir="$1" file cwd
  for file in "$dir"/*.jsonl; do
    [[ -f "$file" ]] || continue
    cwd="$(head -n 25 "$file" 2>/dev/null |
      jq -Rr 'fromjson? | objects | .cwd? // empty' 2>/dev/null |
      awk 'NF { print; exit }')"
    if [[ -n "$cwd" ]]; then
      printf '%s\n' "$cwd"
      return
    fi
  done

  local project_key
  project_key="$(basename "$dir")"
  printf '%s\n' "${project_key//-/\/}"
}

agent_handoff_scan_claude() {
  local base dir cwd file
  base="$(agent_handoff_claude_home)/projects"
  [[ -d "$base" ]] || return 0

  for dir in "$base"/*; do
    [[ -d "$dir" ]] || continue
    local files=()
    for file in "$dir"/*.jsonl; do
      [[ -f "$file" ]] && files+=("$file")
    done
    (( ${#files[@]} > 0 )) || continue

    cwd="$(agent_handoff_claude_dir_cwd "$dir")"
    [[ -n "$cwd" ]] || continue

    local mtimes=() line
    while IFS= read -r line; do mtimes+=("$line"); done < <(agent_handoff_mtimes "${files[@]}")

    local i
    for i in "${!files[@]}"; do
      printf '%s\t%s\t%s\t%s\t%s\n' "$cwd" "claude" "Claude Code" "${files[i]}" "${mtimes[i]:-0}"
    done
  done
}

agent_handoff_scan_codex() {
  local base
  base="$(agent_handoff_codex_home)/sessions"
  [[ -d "$base" ]] || return 0

  local files=() f
  while IFS= read -r -d '' f; do files+=("$f"); done \
    < <(find "$base" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null)
  (( ${#files[@]} > 0 )) || return 0

  local cwds=() mtimes=() line
  while IFS= read -r line; do cwds+=("$line"); done < <(
    for f in "${files[@]}"; do
      line=""
      IFS= read -r line < "$f" || true
      printf '%s\n' "$line"
    done | jq -Rr '(fromjson? | objects | .payload.cwd?) // ""' 2>/dev/null
  )
  while IFS= read -r line; do mtimes+=("$line"); done < <(agent_handoff_mtimes "${files[@]}")

  local i
  for i in "${!files[@]}"; do
    [[ -n "${cwds[i]:-}" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "${cwds[i]}" "codex" "Codex" "${files[i]}" "${mtimes[i]:-0}"
  done
}

agent_handoff_scan_sessions() {
  {
    agent_handoff_scan_claude
    agent_handoff_scan_codex
  } | sort -t $'\t' -k5,5rn
}

agent_handoff_list_projects() {
  agent_handoff_scan_sessions |
    awk -F '\t' '
      {
        cwd=$1
        if (!(cwd in seen)) {
          order[++n]=cwd
          latest[cwd]=$5
        }
        seen[cwd]=1
        if ($2 == "claude") claude[cwd]++
        if ($2 == "codex") codex[cwd]++
        if ($5 > latest[cwd]) latest[cwd]=$5
      }
      END {
        for (i=1; i<=n; i++) {
          cwd=order[i]
          printf "%s\tclaude=%d\tcodex=%d\tlatest=%s\n", cwd, claude[cwd]+0, codex[cwd]+0, latest[cwd]
        }
      }
    '
}

agent_handoff_codex_session_id() {
  head -n 1 "$1" 2>/dev/null |
    jq -Rr '(fromjson? | objects | .payload.id?) // empty' 2>/dev/null
}

agent_handoff_session_title() {
  local agent="$1" file="$2" title=""

  case "$agent" in
    claude)
      title="$(tail -n 200 "$file" 2>/dev/null |
        jq -Rr 'fromjson? | objects | select(.type == "ai-title") | .title // empty' 2>/dev/null |
        tail -n 1)"
      if [[ -z "$title" ]]; then
        title="$(head -n 100 "$file" 2>/dev/null |
          jq -Rr '
            fromjson? | objects | select(.type == "user") | .message.content?
            | if type == "string" then .
              elif type == "array" then (.[]? | select(.type? == "text") | .text?)
              else empty end
            | select(type == "string")
            | select((startswith("<") or startswith("Caveat:")) | not)
            | split("\n")[0]
          ' 2>/dev/null |
          awk 'NF { print; exit }')"
      fi
      ;;
    codex)
      title="$(head -n 50 "$file" 2>/dev/null |
        jq -Rr '
          fromjson? | objects | select(.type == "response_item")
          | .payload | objects | select(.type == "message" and .role == "user")
          | .content[]? | select(.type? == "input_text") | .text?
          | select(type == "string")
          | select((startswith("<") or startswith("# AGENTS.md")) | not)
          | split("\n")[0]
        ' 2>/dev/null |
        awk 'NF { print; exit }')"
      [[ -n "$title" ]] || title="$(agent_handoff_codex_session_id "$file")"
      ;;
  esac

  [[ -n "$title" ]] || title="$(basename "$file" .jsonl)"
  title="${title//$'\t'/ }"
  printf '%s\n' "${title:0:60}"
}

agent_handoff_reltime() {
  local mtime="$1" now diff
  [[ "$mtime" =~ ^[0-9]+$ ]] || { printf '?\n'; return; }
  now="$(date +%s)"
  diff=$((now - mtime))
  if (( diff < 60 )); then
    printf 'now\n'
  elif (( diff < 3600 )); then
    printf '%dm ago\n' $((diff / 60))
  elif (( diff < 86400 )); then
    printf '%dh ago\n' $((diff / 3600))
  else
    printf '%dd ago\n' $((diff / 86400))
  fi
}

agent_handoff_session_title_cached() {
  local agent="$1" file="$2" mtime="$3"
  local cache title
  cache="$(agent_handoff_home)/cache/titles.tsv"

  if [[ -f "$cache" ]]; then
    title="$(awk -F '\t' -v f="$file" -v m="$mtime" '$1 == f && $2 == m { print $3; exit }' "$cache")"
    if [[ -n "$title" ]]; then
      printf '%s\n' "$title"
      return
    fi
  fi

  title="$(agent_handoff_session_title "$agent" "$file")"
  mkdir -p "$(dirname "$cache")"
  printf '%s\t%s\t%s\n' "$file" "$mtime" "$title" >> "$cache"
  printf '%s\n' "$title"
}

# Session line: display \t cwd \t agent_id \t agent_label \t file \t title
# Lists sessions whose project is at or below the scope directory.
agent_handoff_sessions_display() {
  local index="$1" scope="$2"
  printf '%s\n' "$index" |
    awk -F '\t' -v s="$scope" -v p="${scope%/}/" '$1 == s || index($1, p) == 1' |
    while IFS=$'\t' read -r pcwd agent_id agent_label file mtime; do
      local title rel folder
      title="$(agent_handoff_session_title_cached "$agent_id" "$file" "$mtime")"
      rel="$(agent_handoff_reltime "$mtime")"
      if [[ "$pcwd" == "$scope" ]]; then
        folder="·"
      else
        folder="${pcwd#"${scope%/}/"}"
      fi
      folder="${folder:0:24}"
      printf -v folder '%s%*s' "$folder" $((24 - ${#folder})) ''
      printf '\033[33m%-8s\033[0m  \033[2m%-11s\033[0m  \033[2m%s\033[0m  %s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rel" "$agent_label" "$folder" "$title" \
        "$pcwd" "$agent_id" "$agent_label" "$file" "$title"
    done
}

# Offer to install fzf on the spot; returns 0 once fzf is available.
agent_handoff_offer_fzf() {
  [[ -t 0 && -t 2 ]] || return 1

  local pm=""
  if command -v brew >/dev/null 2>&1; then
    pm="brew install"
  elif command -v apt-get >/dev/null 2>&1; then
    pm="sudo apt-get install -y"
  elif command -v dnf >/dev/null 2>&1; then
    pm="sudo dnf install -y"
  elif command -v pacman >/dev/null 2>&1; then
    pm="sudo pacman -S --noconfirm"
  fi
  [[ -n "$pm" ]] || return 1

  printf 'fzf not found — it powers the interactive browser.\nInstall with "%s fzf"? [Y/n] ' "$pm" >&2
  local answer
  read -r answer || return 1
  case "$answer" in
    '' | [yY] | [yY][eE][sS]) ;;
    *) return 1 ;;
  esac

  printf 'Installing fzf...\n' >&2
  if $pm fzf >/dev/null; then
    hash -r
    command -v fzf >/dev/null 2>&1
  else
    return 1
  fi
}

agent_handoff_pick_from_lines() {
  local prompt="$1"
  local env_name="$2"
  local lines="$3"
  local selection count choice

  if [[ -n "$env_name" && -n "${!env_name:-}" ]]; then
    choice="${!env_name}"
    printf '%s\n' "$lines" | sed -n "${choice}p"
    return
  fi

  if command -v fzf >/dev/null 2>&1; then
    selection="$(printf '%s\n' "$lines" |
      fzf --prompt="$prompt> " --height=40% --layout=reverse --delimiter=$'\t' --with-nth=1)" || return 1
    printf '%s\n' "$selection"
    return
  fi

  count="$(printf '%s\n' "$lines" | sed '/^$/d' | wc -l | tr -d ' ')"
  local i=1 line
  while IFS= read -r line; do
    printf '%2d) %s\n' "$i" "${line%%$'\t'*}" >&2
    i=$((i + 1))
  done <<<"$lines"
  printf 'Select number: ' >&2
  read -r choice
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )) || return 1
  printf '%s\n' "$lines" | sed -n "${choice}p"
}

agent_handoff_browse() {
  local index="$1"
  local projects=() line
  while IFS= read -r line; do projects+=("$line"); done \
    < <(printf '%s\n' "$index" | awk -F '\t' '!seen[$1]++ { print $1 }')
  local n=${#projects[@]}

  if [[ -n "${AGENT_HANDOFF_PICK_PROJECT:-}" ]]; then
    local pick="$AGENT_HANDOFF_PICK_PROJECT"
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= n )) || return 1
    agent_handoff_pick_from_lines "Session" "AGENT_HANDOFF_PICK_SESSION" \
      "$(agent_handoff_sessions_display "$index" "${projects[pick - 1]}")"
    return
  fi

  if ! command -v fzf >/dev/null 2>&1 && ! agent_handoff_offer_fzf; then
    printf 'Using numbered prompts. Install fzf for the interactive browser.\n' >&2
    local cwd
    cwd="$(agent_handoff_pick_from_lines "Project" "" "$(printf '%s\n' "${projects[@]}")")" || return 1
    agent_handoff_pick_from_lines "Session" "" \
      "$(agent_handoff_spinner 'Loading sessions...' agent_handoff_sessions_display "$index" "$cwd")"
    return
  fi

  # --header-first needs fzf >= 0.31; degrade gracefully on older versions.
  local header_first="--header-first"
  fzf --help 2>&1 | grep -q -- '--header-first' || header_first=""

  # Start at the current directory, climbing up until sessions exist in scope.
  local scope="$PWD"
  while [[ "$scope" != "/" ]]; do
    if printf '%s\n' "$index" |
      awk -F '\t' -v s="$scope" -v p="${scope%/}/" '$1 == s || index($1, p) == 1 { found = 1; exit } END { exit !found }'; then
      break
    fi
    scope="$(dirname "$scope")"
  done

  local title_line=$'\033[1;36mHand off a previous session\033[0m'

  local lines out key query sel target scope_line can_up can_down expect query=""
  while :; do
    lines="$(agent_handoff_spinner 'Loading sessions...' agent_handoff_sessions_display "$index" "$scope")"

    # A child folder exists when some session's cwd sits strictly below scope.
    if printf '%s\n' "$lines" |
      awk -F '\t' -v s="$scope" '$2 != s && $2 != "" { found = 1; exit } END { exit !found }'; then
      can_down=1
    else
      can_down=0
    fi
    [[ "$scope" == "/" ]] && can_up=0 || can_up=1

    # Only bind the arrows that actually do something, so a dead-end key is inert.
    expect=""
    [[ "$can_up" == 1 ]] && expect="left"
    [[ "$can_down" == 1 ]] && expect="${expect:+$expect,}right"

    local help="enter hand off   esc exit"
    [[ "$can_up" == 1 ]] && help="$help   ← up folder"
    [[ "$can_down" == 1 ]] && help="$help   → into folder"
    help="$help   ↑/↓ browse"
    local help_line=$'\033[2m'"$help"$'\033[0m'

    scope_line="Folder: "$'\033[35m'"${scope/#$HOME/~}"$'\033[0m'

    # With --print-query the first output line is the query. --expect adds a
    # key line before the selection; without it, the selection follows directly.
    # shellcheck disable=SC2086
    out="$(printf '%s\n' "$lines" |
      fzf --ansi --prompt='Type to search: ' --layout=reverse $header_first \
        --header="$title_line
$scope_line
$help_line" \
        --query="$query" --print-query \
        --delimiter=$'\t' --with-nth=1 --expect="${expect:-ctrl-z}")" || return 1
    query="$(printf '%s\n' "$out" | sed -n '1p')"
    key="$(printf '%s\n' "$out" | sed -n '2p')"
    sel="$(printf '%s\n' "$out" | sed -n '3p')"
    case "$key" in
      left)
        [[ "$scope" == "/" ]] || { scope="$(dirname "$scope")"; query=""; }
        ;;
      right)
        target="$(printf '%s\n' "$sel" | awk -F '\t' '{print $2}')"
        if [[ -n "$target" && "$target" != "$scope" ]]; then
          scope="$target"
          query=""
        fi
        ;;
      *)
        [[ -n "$sel" ]] || return 1
        printf '%s\n' "$sel"
        return 0
        ;;
    esac
  done
}

agent_handoff_pick_target() {
  local selected
  local targets=$'Codex\tcodex\nClaude Code\tclaude'

  if [[ -n "${AGENT_HANDOFF_PICK_TARGET:-}" ]]; then
    case "$AGENT_HANDOFF_PICK_TARGET" in
      codex) printf 'Codex\tcodex\n'; return ;;
      claude) printf 'Claude Code\tclaude\n'; return ;;
    esac
  fi

  selected="$(agent_handoff_pick_from_lines "Target agent" "AGENT_HANDOFF_PICK_TARGET_INDEX" "$targets")" || return 1
  printf '%s\n' "$selected"
}

agent_handoff_target_command() {
  case "$1" in
    codex)
      printf '%s\n' "${AGENT_HANDOFF_CODEX_CMD:-codex}"
      ;;
    claude)
      printf '%s\n' "${AGENT_HANDOFF_CLAUDE_CMD:-claude}"
      ;;
    *)
      printf 'Unknown target agent: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

agent_handoff_target_command_source() {
  local env_name
  case "$1" in
    codex) env_name="AGENT_HANDOFF_CODEX_CMD" ;;
    claude) env_name="AGENT_HANDOFF_CLAUDE_CMD" ;;
    *) return 1 ;;
  esac

  if [[ -n "${!env_name:-}" ]]; then
    printf 'from %s\n' "$env_name"
  else
    printf 'default · override with %s\n' "$env_name"
  fi
}

agent_handoff_confirm() {
  [[ "${AGENT_HANDOFF_ASSUME_YES:-}" == "1" ]] && return 0

  # Without a terminal there is no key to read; fall back to a yes/no line.
  if [[ ! -t 0 ]]; then
    printf 'Continue? [Y/n] '
    local answer
    read -r answer
    case "$answer" in
      '' | [yY] | [yY][eE][sS]) return 0 ;;
      *) return 1 ;;
    esac
  fi

  printf '\033[2mPress Enter to continue · Esc to cancel\033[0m '
  local key
  while IFS= read -rsn1 key; do
    case "$key" in
      '') printf '\n'; return 0 ;;        # Enter
      $'\e') printf '\033[2m cancelled\033[0m\n'; return 1 ;;  # Esc
    esac
  done
  return 1
}

agent_handoff_copy_raw() {
  local source_file="$1"
  local source_agent="$2"
  local target_agent="$3"
  local project="$4"
  local dir target

  dir="$(agent_handoff_home)/handoffs/$(agent_handoff_project_key "$project")"
  mkdir -p "$dir"
  target="$dir/$(date '+%Y%m%d-%H%M%S')-$source_agent-to-$target_agent.jsonl"
  cp "$source_file" "$target"
  printf '%s\n' "$target"
}

agent_handoff_prompt() {
  local source_label="$1"
  local handoff_file="$2"
  local project="$3"
  cat <<EOF
$source_label raw session transcript is available at:
$handoff_file

Original cwd:
$project

Treat that JSONL file as the source transcript for the previous session. Read it directly, preserve the user intent and relevant tool results, then continue the work from the latest unresolved point. This is a raw cross-agent handoff, not native session import.
EOF
}

agent_handoff_run_target() {
  local target_agent="$1"
  local target_cmd="$2"
  local prompt="$3"

  if [[ "${AGENT_HANDOFF_DRY_RUN:-}" == "1" ]]; then
    printf 'Dry run command: %s\n' "$target_cmd"
    return 0
  fi

  local bin
  bin="${target_cmd%% *}"
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf 'Target command not found for %s: %s\n' "$target_agent" "$bin" >&2
    return 1
  fi

  # shellcheck disable=SC2086
  $target_cmd "$prompt"
}

agent_handoff_usage() {
  cat <<'EOF'
agent-handoff — pick a Claude Code or Codex session and continue it in another agent.

Usage:
  agent-handoff            Browse sessions and hand one off
  agent-handoff update     Update agent-handoff to the latest version
  agent-handoff version    Print the installed version
  agent-handoff help       Show this help

In the browser:
  ↑/↓     browse sessions
  ←/→     parent / child folder
  type    search
  enter   pick this session
  esc     quit

After picking a session, choose the target agent, then press enter
to launch it (esc to cancel).
EOF
}

# The code checkout to update against, preferring the actually-running
# script (AGENT_HANDOFF_ROOT, set by bin/agent-handoff) over the data dir.
agent_handoff_code_dir() {
  printf '%s\n' "${AGENT_HANDOFF_INSTALL_DIR:-${AGENT_HANDOFF_ROOT:-$HOME/.agent-handoff}}"
}

agent_handoff_version() {
  local dir
  dir="$(agent_handoff_code_dir)"
  if [[ -d "$dir/.git" ]] && command -v git >/dev/null 2>&1; then
    git -C "$dir" describe --tags --always --dirty 2>/dev/null ||
      git -C "$dir" rev-parse --short HEAD 2>/dev/null ||
      printf 'unknown\n'
  else
    printf 'unknown\n'
  fi
}

agent_handoff_update() {
  local dir
  dir="$(agent_handoff_code_dir)"

  if ! command -v git >/dev/null 2>&1; then
    printf 'git is required to update agent-handoff.\n' >&2
    return 1
  fi
  if [[ ! -d "$dir/.git" ]]; then
    printf 'agent-handoff is not a git checkout at %s; cannot self-update.\n' "$dir" >&2
    printf 'Reinstall: curl -fsSL https://raw.githubusercontent.com/1yoouoo/agent-handoff/main/install.sh | sh\n' >&2
    return 1
  fi

  local before after
  before="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
  printf 'Updating agent-handoff in %s...\n' "$dir"
  if ! git -C "$dir" pull --ff-only; then
    printf 'Update failed. If you have local changes, resolve them and retry.\n' >&2
    return 1
  fi
  after="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"

  if [[ "$before" == "$after" ]]; then
    printf 'Already up to date (%s).\n' "$(agent_handoff_version)"
  else
    printf 'Updated to %s.\n' "$(agent_handoff_version)"
  fi
}

agent_handoff_main() {
  case "${1:-}" in
    __test_list_projects)
      agent_handoff_requirements
      agent_handoff_list_projects
      return
      ;;
    update | --update | upgrade)
      agent_handoff_update
      return
      ;;
    version | --version | -v)
      agent_handoff_version
      return
      ;;
    help | --help | -h)
      agent_handoff_usage
      return
      ;;
  esac

  agent_handoff_requirements

  if (( $# > 0 )); then
    printf 'Unknown argument: %s\n\n' "$1" >&2
    agent_handoff_usage >&2
    return 2
  fi

  local index
  index="$(agent_handoff_spinner 'Scanning sessions...' agent_handoff_scan_sessions)"
  [[ -n "$index" ]] || {
    printf 'No Claude Code or Codex sessions found.\n' >&2
    return 1
  }

  local session_line target_line
  session_line="$(agent_handoff_browse "$index")" || return 1
  target_line="$(agent_handoff_pick_target)" || return 1

  local project source_agent source_label source_file title target_label target_agent
  project="$(printf '%s\n' "$session_line" | awk -F '\t' '{print $2}')"
  source_agent="$(printf '%s\n' "$session_line" | awk -F '\t' '{print $3}')"
  source_label="$(printf '%s\n' "$session_line" | awk -F '\t' '{print $4}')"
  source_file="$(printf '%s\n' "$session_line" | awk -F '\t' '{print $5}')"
  title="$(printf '%s\n' "$session_line" | awk -F '\t' '{print $6}')"
  target_label="$(printf '%s\n' "$target_line" | awk -F '\t' '{print $1}')"
  target_agent="$(printf '%s\n' "$target_line" | awk -F '\t' '{print $2}')"

  local handoff_file target_cmd prompt
  handoff_file="$(agent_handoff_copy_raw "$source_file" "$source_agent" "$target_agent" "$project")"
  target_cmd="$(agent_handoff_target_command "$target_agent")"
  prompt="$(agent_handoff_prompt "$source_label" "$handoff_file" "$project")"

  printf '\nSelected:\n'
  printf '  Project: %s\n' "$project"
  printf '  Session: %s — %s\n' "$source_label" "$title"
  printf '  Target:  %s\n' "$target_label"
  printf '  Handoff: %s\n' "$handoff_file"
  printf '  Command: %s  (%s)\n' "$target_cmd" "$(agent_handoff_target_command_source "$target_agent")"
  printf '\n'

  agent_handoff_confirm || return 1
  agent_handoff_run_target "$target_agent" "$target_cmd" "$prompt"
}
