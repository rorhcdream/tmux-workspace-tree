#!/usr/bin/env bash
# Bind one or more keys to open the workspace task tree in a popup.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# @workspace_tree_key may list several keys (space-separated), e.g. 'C-w w'.
KEYS="$(tmux show-option -gqv @workspace_tree_key)"; KEYS="${KEYS:-w}"

# Teardown: `workspace-tree.tmux stop` — remove the key binding(s).
if [ "${1:-}" = "stop" ] || [ "${1:-}" = "uninstall" ]; then
  for k in $KEYS; do tmux unbind-key "$k" 2>/dev/null || true; done
  exit 0
fi

for k in $KEYS; do
  tmux bind-key "$k" display-popup -E -w 100% -h 100% "bash '$DIR/scripts/tree.sh'"
done
