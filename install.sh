#!/usr/bin/env sh
set -eu

repo_url="https://github.com/1yoouoo/agent-handoff.git"
install_dir="${AGENT_HANDOFF_INSTALL_DIR:-$HOME/.agent-handoff}"

if command -v git >/dev/null 2>&1; then
  if [ -d "$install_dir/.git" ]; then
    git -C "$install_dir" pull --ff-only
  else
    git clone "$repo_url" "$install_dir"
  fi
else
  echo "git is required to install agent-handoff" >&2
  exit 1
fi

cat <<EOF
agent-handoff installed to:
  $install_dir

Add this to your shell profile:
  export PATH="\$HOME/.agent-handoff/bin:\$PATH"
EOF
