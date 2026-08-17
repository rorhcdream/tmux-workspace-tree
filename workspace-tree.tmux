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

# tmux has no public popup-active format or lifecycle hook. Maintain a global
# reference count around its blocking display-popup command so companion status
# plugins know the underlying pane is covered and has not actually been seen.
# A count (rather than a boolean) remains correct with multiple attached clients.
POPUP_COUNT_UP='#{e|+:#{?@agent_status_popup_count,#{@agent_status_popup_count},0},1}'
POPUP_COUNT_DOWN='#{e|-:#{?@agent_status_popup_count,#{@agent_status_popup_count},1},1}'
for k in $KEYS; do
  # Pass one command-list string to bind-key. Shell-level `\;` arguments would
  # split this tmux invocation itself and store only the first command.
  tmux bind-key "$k" \
    "set-option -Fg @agent_status_popup_count '$POPUP_COUNT_UP' ; display-popup -E -w 100% -h 100% \"bash '$DIR/scripts/tree.sh'\" ; set-option -Fg @agent_status_popup_count '$POPUP_COUNT_DOWN'"
done
