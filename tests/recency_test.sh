#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/workspace-tree-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
export TEST_ROOT="$TEST_DIR/root" TEST_WINDOWS="$TEST_DIR/windows"
export TMPDIR="$TEST_DIR" PATH="$TEST_DIR/bin:$PATH"
mkdir -p "$TEST_DIR/bin" "$TEST_ROOT/tasks/alpha" "$TEST_ROOT/tasks/beta" "$TEST_ROOT/tasks/gamma"
cat >"$TEST_DIR/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  show-option) [ "$3" != @workspace_tree_root ] || printf '%s\n' "$TEST_ROOT" ;;
  list-windows)
    # The tree must remain scoped to the current session.
    [ "${2:-}" != -a ] || exit 1
    cat "$TEST_WINDOWS"
    ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/tmux"

snapshot() {
  # idx, name, terminal output, cwd, status, agent timestamp, id, mark, visit, pin
  printf '1\talpha\t%s\t/example\t-\t0\t@1\t0\t1700000000100\t%s\n' "$1" "${6:-0}"
  printf '2\tbeta\t1700000000\t/example\t-\t0\t@2\t0\t1700000000200\t%s\n' "${5:-0}"
  printf '3\tgamma\t1700000000\t/example\t%s\t%s\t@3\t0\t%s\n' "$2" "$3" "$4"
}
assert_order() {
  local actual
  actual="$(bash "$ROOT_DIR/scripts/tree.sh" --list | cut -f1 | paste -sd, -)"
  [ "$actual" = "$1" ] || {
    printf 'not ok - %s (expected %s, got %s)\n' "$2" "$1" "$actual" >&2
    exit 1
  }
}

snapshot 1700000000 - 0 0 >"$TEST_WINDOWS"
assert_order beta,alpha,gamma 'visits within one second retain recency order'
snapshot 1900000000 - 0 0 >"$TEST_WINDOWS"
assert_order beta,alpha,gamma 'background terminal output must not reorder tasks'
snapshot 1900000000 - 0 1700000000300 >"$TEST_WINDOWS"
assert_order gamma,beta,alpha 'visiting a task moves it above older visits'
snapshot 1900000000 - 1700000001000 0 >"$TEST_WINDOWS"
assert_order gamma,beta,alpha 'an agent boundary contributes to recency'
snapshot 1900000000 - 1700000001 0 >"$TEST_WINDOWS"
assert_order gamma,beta,alpha 'second and millisecond agent timestamps agree'
snapshot 1900000000 '✅' 1600000000 0 >"$TEST_WINDOWS"
assert_order gamma,beta,alpha 'finished tasks keep their priority group'
snapshot 1900000000 '✅' 1800000000000 0 1 >"$TEST_WINDOWS"
assert_order beta,gamma,alpha 'pinned tasks precede finished tasks'
bash "$ROOT_DIR/scripts/tree.sh" --list | grep -q '📌'
snapshot 1900000000 '✅' 1800000000000 0 1 1 >"$TEST_WINDOWS"
assert_order alpha,beta,gamma 'pinned tasks keep window-number order in activity mode'
snapshot 1900000000 '✅' 1800000000000 0 1 >"$TEST_WINDOWS"
bash "$ROOT_DIR/scripts/tree.sh" --nextsort
assert_order beta,alpha,gamma 'pins precede other tasks in name sort'
bash "$ROOT_DIR/scripts/tree.sh" --nextsort
assert_order beta,gamma,alpha 'pins precede other tasks in dirty sort'
bash "$ROOT_DIR/scripts/tree.sh" --nextsort
printf '1\talpha\t1900000000\t/example\t-\t0\t@1\t0\t0\n' >"$TEST_WINDOWS"
printf '2\tbeta\t2000000000\t/example\t-\t0\t@2\t0\t0\n' >>"$TEST_WINDOWS"
# Keep these recent enough to remain visible despite having no live window.
touch "$TEST_ROOT/tasks/gamma/note"
mkdir "$TEST_ROOT/tasks/aardvark"
touch "$TEST_ROOT/tasks/aardvark/note"
assert_order alpha,beta,aardvark,gamma 'stale tasks follow live tasks without visit history'
bash "$ROOT_DIR/scripts/tree.sh" --nextsort
assert_order alpha,beta,aardvark,gamma 'name sort keeps stale tasks after live tasks'
bash "$ROOT_DIR/scripts/tree.sh" --nextsort
assert_order alpha,beta,aardvark,gamma 'dirty sort keeps stale tasks after live tasks'
printf 'ok - task recency follows visits and agent events, independent of terminal output\n'
