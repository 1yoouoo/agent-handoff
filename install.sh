#!/usr/bin/env sh
set -eu

repo_url="${AGENT_HANDOFF_REPO_URL:-https://github.com/1yoouoo/agent-handoff.git}"
install_dir="${AGENT_HANDOFF_INSTALL_DIR:-$HOME/.agent-handoff}"
bin_dir="$install_dir/bin"

if ! command -v git >/dev/null 2>&1; then
  echo "git is required to install agent-handoff" >&2
  exit 1
fi

if [ -d "$install_dir/.git" ]; then
  git -C "$install_dir" pull --ff-only
else
  git clone "$repo_url" "$install_dir"
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
  cat <<EOF
agent-handoff installed to:
  $install_dir

Could not detect your shell profile. Add this to it manually:
  $path_line
EOF
  exit 0
fi

mkdir -p "$(dirname "$profile")"
touch "$profile"

if grep -qsF "$bin_dir" "$profile" || grep -qsF '.agent-handoff/bin' "$profile"; then
  cat <<EOF
agent-handoff installed to:
  $install_dir

$profile already puts it on your PATH.
EOF
else
  printf '\n# agent-handoff\n%s\n' "$line" >> "$profile"
  cat <<EOF
agent-handoff installed to:
  $install_dir

Added to $profile:
  $line

Restart your shell (or source the profile) to use agent-handoff.
EOF
fi
