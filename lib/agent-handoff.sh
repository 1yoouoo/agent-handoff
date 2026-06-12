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

# A change token that moves whenever the file changes, even within the same
# mtime second: "mtime.size". Used as the cache key so a /rename (which appends
# a custom-title record, growing the file) always invalidates a stale title.
agent_handoff_stamps() {
  stat -f '%m.%z' "$@" 2>/dev/null || stat -c '%Y.%s' "$@" 2>/dev/null
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

    local stamps=() line
    while IFS= read -r line; do stamps+=("$line"); done < <(agent_handoff_stamps "${files[@]}")

    local i
    for i in "${!files[@]}"; do
      printf '%s\t%s\t%s\t%s\t%s\n' "$cwd" "claude" "Claude Code" "${files[i]}" "${stamps[i]:-0}"
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

  local cwds=() stamps=() line
  while IFS= read -r line; do cwds+=("$line"); done < <(
    for f in "${files[@]}"; do
      line=""
      IFS= read -r line < "$f" || true
      printf '%s\n' "$line"
    done | jq -Rr '(fromjson? | objects | .payload.cwd?) // ""' 2>/dev/null
  )
  while IFS= read -r line; do stamps+=("$line"); done < <(agent_handoff_stamps "${files[@]}")

  # Codex stores /rename names in session_index.jsonl, not in the rollout file,
  # so a rename leaves the rollout's mtime/size untouched. Fold that index's
  # mtime into every Codex stamp: when someone renames a thread the index
  # changes, every Codex stamp shifts, and stale titles get re-extracted.
  local index_mtime
  index_mtime="$(agent_handoff_mtimes "$(agent_handoff_codex_home)/session_index.jsonl" 2>/dev/null || true)"
  [[ -n "$index_mtime" ]] || index_mtime=0

  local i
  for i in "${!files[@]}"; do
    [[ -n "${cwds[i]:-}" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "${cwds[i]}" "codex" "Codex" "${files[i]}" "${stamps[i]:-0}-${index_mtime}"
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
        mt=int($5)            # $5 is a change stamp ("mtime.size[-idx]")
        if (!(cwd in seen)) {
          order[++n]=cwd
          latest[cwd]=mt
        }
        seen[cwd]=1
        if ($2 == "claude") claude[cwd]++
        if ($2 == "codex") codex[cwd]++
        if (mt > latest[cwd]) latest[cwd]=mt
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

# A name the user set with /rename, if any. Claude stores it inline as a
# custom-title record; Codex keeps it in session_index.jsonl keyed by id.
agent_handoff_custom_title() {
  local agent="$1" file="$2"

  case "$agent" in
    claude)
      tail -n 400 "$file" 2>/dev/null |
        jq -Rr 'fromjson? | objects | select(.type == "custom-title") | .customTitle // empty' 2>/dev/null |
        awk 'NF { last = $0 } END { if (last != "") print last }'
      ;;
    codex)
      local index id
      index="$(agent_handoff_codex_home)/session_index.jsonl"
      [[ -f "$index" ]] || return 0
      id="$(agent_handoff_codex_session_id "$file")"
      [[ -n "$id" ]] || return 0
      jq -Rr --arg id "$id" '
        fromjson? | objects | select(.id == $id)
        | .thread_name // empty | select(. != "")
      ' "$index" 2>/dev/null | tail -n 1
      ;;
  esac
}

# Resolves a session's title. A /rename name wins; otherwise the latest user
# message, then an agent-specific fallback. The whole result is cached, keyed
# by the file's change stamp (mtime.size), so a rename — which appends a
# custom-title record and grows the file — invalidates the cached title.
agent_handoff_session_title() {
  local agent="$1" file="$2" title=""

  # A user-set name (/rename) always wins.
  title="$(agent_handoff_custom_title "$agent" "$file")"
  if [[ -n "$title" ]]; then
    title="${title//$'\t'/ }"
    printf '%s\n' "${title:0:60}"
    return
  fi

  # A user line is noise when it's an injected/system message rather than
  # something the person typed (context blocks, caveats, image/command markers,
  # interrupt notices, the handoff prompt).
  local noise='(
    startswith("<") or startswith("Caveat:") or startswith("# AGENTS.md")
    or startswith("[Image") or startswith("[Request interrupted")
    or startswith("[Image #") or test(" raw session transcript is available at:")
  )'

  case "$agent" in
    claude)
      # Prefer the most recent thing the user actually said.
      title="$(tail -n 400 "$file" 2>/dev/null |
        jq -Rr "
          fromjson? | objects | select(.type == \"user\") | .message.content?
          | if type == \"string\" then .
            elif type == \"array\" then (.[]? | select(.type? == \"text\") | .text?)
            else empty end
          | select(type == \"string\")
          | select($noise | not)
          | split(\"\n\")[0]
        " 2>/dev/null |
        awk 'NF { last = $0 } END { if (last != "") print last }')"
      # Fall back to Claude's own session title, then the first user message.
      if [[ -z "$title" ]]; then
        title="$(tail -n 400 "$file" 2>/dev/null |
          jq -Rr 'fromjson? | objects | select(.type == "ai-title") | .title // empty' 2>/dev/null |
          tail -n 1)"
      fi
      ;;
    codex)
      title="$(tail -n 400 "$file" 2>/dev/null |
        jq -Rr "
          fromjson? | objects | select(.type == \"response_item\")
          | .payload | objects | select(.type == \"message\" and .role == \"user\")
          | .content[]? | select(.type? == \"input_text\") | .text?
          | select(type == \"string\")
          | select($noise | not)
          | split(\"\n\")[0]
        " 2>/dev/null |
        awk 'NF { last = $0 } END { if (last != "") print last }')"
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

# Ensure titles for the given sessions are in the cache, extracting (slowly)
# only the ones that are missing. Reads "agent<TAB>file<TAB>stamp" lines, where
# stamp is "mtime.size" — so any change to the file (including a /rename that
# appends a custom-title record) is a cache miss and re-extracts the title.
# Cache membership is resolved in a single awk pass, so a fully-warm cache
# costs one awk run rather than one per session.
agent_handoff_fill_title_cache() {
  local cache="$1"
  mkdir -p "$(dirname "$cache")"
  touch "$cache"

  local agent file stamp title
  while IFS=$'\t' read -r agent file stamp title; do
    [[ -n "$file" ]] || continue
    title="$(agent_handoff_session_title "$agent" "$file")"
    printf '%s\t%s\t%s\n' "$file" "$stamp" "$title" >> "$cache"
  done < <(
    awk -F '\t' -v cache="$cache" '
      BEGIN { while ((getline l < cache) > 0) { split(l, a, "\t"); seen[a[1] SUBSEP a[2]] = 1 } }
      $2 != "" && !((($2) SUBSEP ($3)) in seen)
    '
  )
}

# Session line: display \t cwd \t agent_id \t agent_label \t file \t title
# Lists sessions whose project is at or below the scope directory.
#
# Renders the whole scope in a single awk pass: relative time is computed from
# a single "now", and titles are joined from the on-disk cache. Only sessions
# missing from the cache trigger a (subprocess) title extraction beforehand.
agent_handoff_sessions_display() {
  local index="$1" scope="$2"
  local cache now
  cache="$(agent_handoff_home)/cache/titles.tsv"
  now="$(date +%s)"

  # Fill cache misses first (no-op when every title is already cached).
  printf '%s\n' "$index" |
    awk -F '\t' -v s="$scope" -v p="${scope%/}/" '
      $1 == s || index($1, p) == 1 { print $2 "\t" $4 "\t" $5 }' |
    agent_handoff_fill_title_cache "$cache"

  # Single pass: load cache, then format each in-scope session row.
  printf '%s\n' "$index" |
    awk -F '\t' -v s="$scope" -v p="${scope%/}/" -v now="$now" -v cache="$cache" '
      BEGIN {
        while ((getline line < cache) > 0) {
          nf = split(line, a, "\t")
          if (nf >= 3) title[a[1] SUBSEP a[2]] = a[3]
        }
      }
      $1 != s && index($1, p) != 1 { next }
      {
        pcwd = $1; agent_id = $2; agent_label = $3; file = $4; stamp = $5
        t = title[file SUBSEP stamp]
        if (t == "") t = file

        mtime = int(stamp)          # stamp is "mtime.size"; relative time uses mtime
        d = now - mtime
        if (stamp !~ /^[0-9]/) rel = "?"
        else if (d < 60)    rel = "now"
        else if (d < 3600)  rel = int(d/60) "m ago"
        else if (d < 86400) rel = int(d/3600) "h ago"
        else                rel = int(d/86400) "d ago"

        if (pcwd == s) folder = "\xc2\xb7"            # middot
        else { folder = pcwd; sub("^" p, "", folder) }
        folder = substr(folder, 1, 24)

        printf "\033[33m%-8s\033[0m  \033[2m%-11s\033[0m  \033[2m%-24s\033[0m  %s\t%s\t%s\t%s\t%s\t%s\n",
          rel, agent_label, folder, t, pcwd, agent_id, agent_label, file, t
      }'
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

  # transform-header (used to repaint the header on reload) needs fzf >= 0.36;
  # older versions fall back to the redraw loop.
  local fzf_minor
  fzf_minor="$(fzf --version 2>/dev/null | sed -E 's/^[0-9]+\.([0-9]+).*/\1/')"
  if [[ ! "$fzf_minor" =~ ^[0-9]+$ ]] || (( fzf_minor < 36 )); then
    agent_handoff_browse_redraw "$index"
    return
  fi

  # Share state with the fzf-spawned renderer/navigator through a temp dir.
  local state
  state="$(mktemp -d)"
  printf '%s\n' "$index" > "$state/index"
  agent_handoff_initial_scope "$index" > "$state/scope"

  local title_line=$'\033[1;36mHand off a previous session\033[0m'

  # left/right rewrite the scope file (via __nav) then reload the list and
  # repaint the header; fzf itself never exits, so the frame stays put.
  local self="$AGENT_HANDOFF_ROOT/bin/agent-handoff"
  local reload="reload(AGENT_HANDOFF_STATE=$state $self __render)"
  local rehead="transform-header(AGENT_HANDOFF_STATE=$state $self __header)"
  local sel
  sel="$(AGENT_HANDOFF_STATE="$state" "$self" __render |
    fzf --ansi --prompt='Type to search: ' --layout=reverse --header-first \
      --header="$(AGENT_HANDOFF_STATE="$state" "$self" __header)" \
      --delimiter=$'\t' --with-nth=1 \
      --bind "left:execute-silent(AGENT_HANDOFF_STATE=$state $self __nav up)+$reload+$rehead" \
      --bind "right:execute-silent(AGENT_HANDOFF_STATE=$state $self __nav down {2})+$reload+$rehead")" || {
    rm -rf "$state"
    return 1
  }
  rm -rf "$state"
  [[ -n "$sel" ]] || return 1
  printf '%s\n' "$sel"
}

# Climb from the current directory until sessions exist in scope.
agent_handoff_initial_scope() {
  local index="$1" scope="$PWD"
  while [[ "$scope" != "/" ]]; do
    if printf '%s\n' "$index" |
      awk -F '\t' -v s="$scope" -v p="${scope%/}/" '$1 == s || index($1, p) == 1 { found = 1; exit } END { exit !found }'; then
      break
    fi
    scope="$(dirname "$scope")"
  done
  printf '%s\n' "$scope"
}

agent_handoff_scope_can_down() {
  local index="$1" scope="$2"
  printf '%s\n' "$index" |
    awk -F '\t' -v s="$scope" -v p="${scope%/}/" 'index($1, p) == 1 && $1 != s { found = 1; exit } END { exit !found }'
}

# __render: print the session list for the scope recorded in the state dir.
agent_handoff_render() {
  local state="$AGENT_HANDOFF_STATE" index scope
  index="$(cat "$state/index")"
  scope="$(cat "$state/scope")"
  agent_handoff_sessions_display "$index" "$scope"
}

# __header: print the (fixed-height) header for the current scope.
agent_handoff_render_header() {
  local state="$AGENT_HANDOFF_STATE" index scope
  index="$(cat "$state/index")"
  scope="$(cat "$state/scope")"

  local can_up=1 can_down=0
  [[ "$scope" == "/" ]] && can_up=0
  agent_handoff_scope_can_down "$index" "$scope" && can_down=1

  local help="enter hand off   esc exit"
  [[ "$can_up" == 1 ]] && help="$help   ← up folder"
  [[ "$can_down" == 1 ]] && help="$help   → into folder"
  help="$help   ↑/↓ browse"

  printf '\033[1;36mHand off a previous session\033[0m\n'
  printf 'Folder: \033[35m%s\033[0m\n' "${scope/#$HOME/~}"
  printf '\033[2m%s\033[0m\n' "$help"
}

# __nav up|down [target]: move the scope up to the parent or down into a child.
agent_handoff_nav() {
  local state="$AGENT_HANDOFF_STATE" dir="$1" target="${2:-}"
  local index scope
  index="$(cat "$state/index")"
  scope="$(cat "$state/scope")"

  case "$dir" in
    up)
      [[ "$scope" == "/" ]] || scope="$(dirname "$scope")"
      ;;
    down)
      if [[ -n "$target" && "$target" != "$scope" ]] &&
        printf '%s\n' "$index" | awk -F '\t' -v t="$target" '$1 == t || index($1, t"/") == 1 { f=1; exit } END { exit !f }'; then
        scope="$target"
      fi
      ;;
  esac
  printf '%s\n' "$scope" > "$state/scope"
}

# Pre-reload redraw loop for fzf versions without reload/transform bindings.
agent_handoff_browse_redraw() {
  local index="$1"
  local header_first="--header-first"
  fzf --help 2>&1 | grep -q -- '--header-first' || header_first=""

  local scope
  scope="$(agent_handoff_initial_scope "$index")"
  local title_line=$'\033[1;36mHand off a previous session\033[0m'

  local lines out key query sel target scope_line can_up can_down expect query=""
  while :; do
    lines="$(agent_handoff_spinner 'Loading sessions...' agent_handoff_sessions_display "$index" "$scope")"
    if printf '%s\n' "$lines" |
      awk -F '\t' -v s="$scope" '$2 != s && $2 != "" { found = 1; exit } END { exit !found }'; then
      can_down=1
    else
      can_down=0
    fi
    [[ "$scope" == "/" ]] && can_up=0 || can_up=1

    expect=""
    [[ "$can_up" == 1 ]] && expect="left"
    [[ "$can_down" == 1 ]] && expect="${expect:+$expect,}right"

    local help="enter hand off   esc exit"
    [[ "$can_up" == 1 ]] && help="$help   ← up folder"
    [[ "$can_down" == 1 ]] && help="$help   → into folder"
    help="$help   ↑/↓ browse"
    local help_line=$'\033[2m'"$help"$'\033[0m'
    scope_line="Folder: "$'\033[35m'"${scope/#$HOME/~}"$'\033[0m'

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
    __render)
      agent_handoff_render
      return
      ;;
    __header)
      agent_handoff_render_header
      return
      ;;
    __nav)
      shift
      agent_handoff_nav "$@"
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
