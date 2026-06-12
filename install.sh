#!/usr/bin/env sh
set -eu

repo_url="${AGENT_HANDOFF_REPO_URL:-https://github.com/1yoouoo/agent-handoff.git}"
install_dir="${AGENT_HANDOFF_INSTALL_DIR:-$HOME/.agent-handoff}"
bin_dir="$install_dir/bin"

if [ -t 1 ]; then
  bold="$(printf '\033[1m')"
  dim="$(printf '\033[2m')"
  cyan="$(printf '\033[36m')"
  green="$(printf '\033[32m')"
  yellow="$(printf '\033[33m')"
  reset="$(printf '\033[0m')"
else
  bold="" dim="" cyan="" green="" yellow="" reset=""
fi

ok()   { printf '  %s✓%s %s\n' "$green" "$reset" "$1"; }
warn() { printf '  %s!%s %s\n' "$yellow" "$reset" "$1"; }

pretty() {
  case "$1" in
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    "$HOME") printf '~' ;;
    *) printf '%s' "$1" ;;
  esac
}

printf '\n%sagent-handoff%s %sinstaller%s\n\n' "$bold$cyan" "$reset" "$dim" "$reset"

if ! command -v git >/dev/null 2>&1; then
  warn "git is required to install agent-handoff" >&2
  exit 1
fi

if [ -d "$install_dir/.git" ]; then
  git -C "$install_dir" pull --ff-only -q
  ok "Updated $(pretty "$install_dir")"
else
  git clone -q "$repo_url" "$install_dir"
  ok "Cloned to $(pretty "$install_dir")"
fi

missing=""
command -v jq >/dev/null 2>&1 || missing="$missing jq"
command -v fzf >/dev/null 2>&1 || missing="$missing fzf"

if [ -z "$missing" ]; then
  ok "Dependencies ready ${dim}(jq, fzf)${reset}"
else
  pm=""
  if command -v brew >/dev/null 2>&1; then
    pm="brew install"
  elif command -v apt-get >/dev/null 2>&1; then
    pm="sudo apt-get install -y"
  elif command -v dnf >/dev/null 2>&1; then
    pm="sudo dnf install -y"
  elif command -v pacman >/dev/null 2>&1; then
    pm="sudo pacman -S --noconfirm"
  fi

  # Download a pinned official release binary into bin_dir (already on PATH).
  download_tool() {
    dl_os="$(uname -s)"
    dl_arch="$(uname -m)"
    case "$dl_arch" in
      arm64 | aarch64) dl_arch="arm64" ;;
      x86_64 | amd64) dl_arch="amd64" ;;
      *) return 1 ;;
    esac
    case "$1" in
      fzf)
        case "$dl_os" in
          Darwin) dl_os="darwin" ;;
          Linux) dl_os="linux" ;;
          *) return 1 ;;
        esac
        dl_tmp="$(mktemp -d)"
        if curl -fsSL "https://github.com/junegunn/fzf/releases/download/v0.73.1/fzf-0.73.1-${dl_os}_${dl_arch}.tar.gz" -o "$dl_tmp/fzf.tar.gz" &&
          tar -xzf "$dl_tmp/fzf.tar.gz" -C "$dl_tmp"; then
          mv "$dl_tmp/fzf" "$bin_dir/fzf"
          chmod +x "$bin_dir/fzf"
          rm -rf "$dl_tmp"
          return 0
        fi
        rm -rf "$dl_tmp"
        return 1
        ;;
      jq)
        case "$dl_os" in
          Darwin) dl_os="macos" ;;
          Linux) dl_os="linux" ;;
          *) return 1 ;;
        esac
        if curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-${dl_os}-${dl_arch}" -o "$bin_dir/jq"; then
          chmod +x "$bin_dir/jq"
          return 0
        fi
        rm -f "$bin_dir/jq"
        return 1
        ;;
    esac
    return 1
  }

  installed=0
  if [ -n "$pm" ]; then
    # Ask on the terminal directly so this works under `curl | sh`.
    if { printf '  %s?%s Missing:%s%s%s — install with "%s%s"? [Y/n] ' \
        "$yellow" "$reset" "$bold" "$missing" "$reset" "$pm" "$missing" > /dev/tty; } 2>/dev/null &&
      read -r answer < /dev/tty 2>/dev/null; then
      case "$answer" in
        '' | [yY] | [yY][eE][sS])
          printf '  %s… Installing%s%s\n' "$dim" "$missing" "$reset"
          if $pm$missing >/dev/null; then
            installed=1
            ok "Installed$missing"
          fi
          ;;
      esac
    fi
  elif command -v curl >/dev/null 2>&1; then
    if { printf '  %s?%s Missing:%s%s%s — no package manager found. Download official binaries to %s? [Y/n] ' \
        "$yellow" "$reset" "$bold" "$missing" "$reset" "$(pretty "$bin_dir")" > /dev/tty; } 2>/dev/null &&
      read -r answer < /dev/tty 2>/dev/null; then
      case "$answer" in
        '' | [yY] | [yY][eE][sS])
          installed=1
          for tool in $missing; do
            printf '  %s… Downloading %s%s\n' "$dim" "$tool" "$reset"
            if download_tool "$tool"; then
              ok "Downloaded $tool"
            else
              installed=0
              warn "Failed to download $tool"
            fi
          done
          ;;
      esac
    fi
  fi

  if [ "$installed" -ne 1 ]; then
    warn "Missing dependencies:$missing"
    printf '    %sjq is required; fzf powers the interactive browser.%s\n' "$dim" "$reset"
    printf '    %sInstall with e.g.: brew install%s%s\n' "$dim" "$missing" "$reset"
  fi
fi

# Reference $HOME in the profile line when installing to the default location.
if [ "$install_dir" = "$HOME/.agent-handoff" ]; then
  path_line='export PATH="$HOME/.agent-handoff/bin:$PATH"'
else
  path_line="export PATH=\"$bin_dir:\$PATH\""
fi

shell_name="$(basename "${SHELL:-}")"
profile=""
line="$path_line"
case "$shell_name" in
  zsh)
    profile="${ZDOTDIR:-$HOME}/.zshrc"
    ;;
  bash)
    if [ "$(uname)" = "Darwin" ]; then
      profile="$HOME/.bash_profile"
    else
      profile="$HOME/.bashrc"
    fi
    ;;
  fish)
    profile="$HOME/.config/fish/config.fish"
    line="fish_add_path \"$bin_dir\""
    ;;
esac

if [ -z "$profile" ]; then
  warn "Could not detect your shell profile. Add this line to it manually:"
  printf '    %s%s%s\n' "$bold" "$path_line" "$reset"
else
  mkdir -p "$(dirname "$profile")"
  touch "$profile"

  if grep -qsF "$bin_dir" "$profile" || grep -qsF '.agent-handoff/bin' "$profile"; then
    ok "PATH already configured in $(pretty "$profile")"
  else
    printf '\n# agent-handoff\n%s\n' "$line" >> "$profile"
    ok "Added PATH to $(pretty "$profile")"
  fi
fi

printf '\n  %sDone!%s Restart your shell, then run %s%sagent-handoff%s\n\n' \
  "$green$bold" "$reset" "$bold" "$cyan" "$reset"
