#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/workspace-tree-actions.XXXXXX")"
export TEST_TMUX="$(command -v tmux)" TEST_TMUX_SOCKET="$TEST_DIR/tmux.sock"
cleanup() {
  "$TEST_TMUX" -S "$TEST_TMUX_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/root/tasks/alpha" "$TEST_DIR/root/tasks/beta" \
  "$TEST_DIR/root/tasks/task with spaces"
cat >"$TEST_DIR/bin/tmux" <<'WRAPPER'
#!/usr/bin/env bash
exec "$TEST_TMUX" -S "$TEST_TMUX_SOCKET" "$@"
WRAPPER
chmod +x "$TEST_DIR/bin/tmux"
export PATH="$TEST_DIR/bin:$PATH" TMPDIR="$TEST_DIR"
unset TMUX TMUX_PANE

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
tree() { bash "$ROOT_DIR/scripts/tree.sh" "$@"; }
tmux -f /dev/null new-session -d -s fixture -n alpha -c "$TEST_DIR/root/tasks/alpha" 'sleep 60'
alpha="$(tmux display-message -p '#{window_id}')"
beta="$(tmux new-window -d -P -F '#{window_id}' -t fixture -n beta -c "$TEST_DIR/root/tasks/beta" 'sleep 60')"
tmux set-option -g @workspace_tree_root "$TEST_DIR/root"
bash "$ROOT_DIR/workspace-tree.tmux"

tree --toggle-pin beta "$beta"
[ "$(tmux show-option -wqv -t "$beta" @workspace_tree_pinned)" = 1 ] || fail 'pin toggle'
tmux set-option -w -t "$beta" @workspace_tree_unread 1
tmux select-window -t "$beta"
for _wait in {1..30}; do
  [ -n "$(tmux show-option -wqv -t "$beta" @workspace_tree_unread)" ] || break
  sleep 0.1
done
[ -z "$(tmux show-option -wqv -t "$beta" @workspace_tree_unread)" ] || fail 'entry must clear yellow mark'
[ "$(tmux show-option -wqv -t "$beta" @workspace_tree_pinned)" = 1 ] || fail 'entry must preserve pin'
listing="$(tree --list)"
[ "$(printf '%s\n' "$listing" | head -1 | cut -f1)" = beta ] || fail 'pin must be first'
tree --toggle-pin beta "$beta"
[ -z "$(tmux show-option -wqv -t "$beta" @workspace_tree_pinned)" ] || fail 'unpin toggle'
tree --toggle-pin '' ''
tree --toggle-pin missing "$alpha"
[ -z "$(tmux show-option -wqv -t "$alpha" @workspace_tree_pinned)" ] || fail 'invalid task must not pin'

tree --create-window 'task with spaces' ''
count="$(tmux list-windows -F '#{window_id}' | wc -l | tr -d ' ')"
[ "$count" = 3 ] || fail 'create exactly one task window'
created="$(tmux list-windows -F '#{window_name}	#{pane_current_path}' | awk -F'\t' '$1=="task with spaces" {print $2}')"
expected="$(cd "$TEST_DIR/root/tasks/task with spaces" && pwd -P)"
[ -n "$created" ] && [ "$(cd "$created" && pwd -P)" = "$expected" ] || fail 'new window must use task directory'
[ "$(tmux display-message -p '#{window_id}')" = "$beta" ] || fail 'creation must keep focus'
tree --create-window 'task with spaces' ''
tree --create-window beta "$beta"
tree --create-window missing ''
tree --create-window '' ''
after="$(tmux list-windows -F '#{window_id}' | wc -l | tr -d ' ')"
[ "$after" = "$count" ] || fail 'existing or invalid tasks must not create duplicates'
printf 'ok - pins survive visits; missing task windows can be created without duplicates or focus changes\n'
