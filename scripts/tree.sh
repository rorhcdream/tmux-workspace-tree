#!/usr/bin/env bash
# Workspace task tree in an fzf popup. Rows = tasks (dir under <root>/tasks) plus
# any other tmux window (shown with its cwd). Preview = per-task worktree git
# stats (or window info) + live pane tail.
#
# choose-tree-style keys, plus what choose-tree can't do:
#   0-9 / alt-a..z         jump straight to that row (labels shown dimmed at left)
#   enter / ctrl-j (jump)  switch to task's window (ctrl-j = overlay number/letter labels)
#   tab                    mark (multi-select)
#   ctrl-x                 clean marked task(s): sends "clean up task: ..." to the
#                          base work window (window 0's Claude at ~/work) and jumps there
#   ctrl-o                 cycle sort: activity | name | dirty
#   ctrl-u/ctrl-d          scroll list;  ctrl-b/ctrl-f  scroll preview
#   type                   fuzzy filter
# ponytail: fzf popup over a bespoke TUI. dirty-sort git-walks every task on that
#           reload — fine at tens of tasks; cache if it ever crawls.
set -uo pipefail

ROOT="$(tmux show-option -gqv @workspace_tree_root)"; ROOT="${ROOT:-$HOME/work}"
# Fallback target for the workspace-root window if none is found at cwd==$ROOT
# (see root_window). The root window is normally auto-detected by its cwd.
WORK_WIN="$(tmux show-option -gqv @workspace_tree_work_window)"; WORK_WIN="${WORK_WIN:-0}"
TASKS="$ROOT/tasks"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
STATE="${TMPDIR:-/tmp}/wstree.sort"
SHOWALL="${TMPDIR:-/tmp}/wstree.showall"
LABELS="${TMPDIR:-/tmp}/wstree.labels"   # jump label -> row position map (see label())
HIDE_DAYS="$(tmux show-option -gqv @workspace_tree_hide_days)"; HIDE_DAYS="${HIDE_DAYS:-14}"
# tmux-claude-status appends this recency marker to some icons ("✅ •"), making
# those cells wider than bare ones. We keep it but reserve a fixed slot (below).
MARK="$(tmux show-option -gqv @claude_status_recent_marker)"; MARK="${MARK:-•}"
# The status plugin's icons, used to group tasks (finished on top, then running).
I_DONE="$(tmux show-option -gqv @claude_status_done)"; I_DONE="${I_DONE:-✅}"
I_WORK="$(tmux show-option -gqv @claude_status_working)"; I_WORK="${I_WORK:-🤖}"
I_WAIT="$(tmux show-option -gqv @claude_status_waiting)"; I_WAIT="${I_WAIT:-💬}"
# Blank placeholder for no-agent-icon rows: 2 spaces, matching emoji width so
# names stay column-aligned whether or not a row has an icon. (Same for live and
# stale rows — the distinction is no longer drawn with a dot.)
DOT_LIVE='  '
DOT_STALE='  '

# task sub-order from the (bare) status icon: finished first, then waiting, then
# running, then no icon. Within each, list_tasks sorts by the status timestamp.
subprio_of() {
  case "$1" in
    "$I_DONE") echo 0 ;;
    "$I_WAIT") echo 1 ;;
    "$I_WORK") echo 2 ;;
    *)         echo 3 ;;
  esac
}

worktrees() { local d="$1" w; for w in "$d"*/; do [ -e "$w/.git" ] && basename "$w"; done; }
# true if the task dir has any file modified within HIDE_DAYS days
recent_enough() { [ -n "$(find "$1" -maxdepth 3 -type f -mtime "-$HIDE_DAYS" -print -quit 2>/dev/null)" ]; }
dirty_count() { # total dirty files across a task's worktrees
  local d="$1" w n=0
  for w in "$d"*/; do
    [ -e "$w/.git" ] || continue
    n=$(( n + $(git -C "$w" status --porcelain 2>/dev/null | grep -c . || true) ))
  done
  echo "$n"
}

# dim, right-aligned 2-wide tmux window index (blank slot if the row has no window)
idxcol() { if [ -n "$1" ]; then printf '\033[38;5;240m%2s\033[0m' "$1"; else printf '  '; fi; }
# ~-abbreviate a home path (bash's ${v/#$HOME/~} is unreliable, so strip the prefix)
tilde() { case "$1" in "$HOME") printf '~' ;; "$HOME"/*) printf '~%s' "${1#$HOME}" ;; *) printf '%s' "$1" ;; esac; }

# emit: <prio>\t<subprio>\t<sortts>\t<dirty-or-0>\t<name>\t<display>
# prio groups rows: 0 = workspace-root window (cwd == $ROOT, e.g. the ~/work Claude
# session), 1 = other non-task windows (on top), 2 = separator line, 3 = tasks.
# subprio sub-orders tasks (finished, waiting, running, none). sortts is the key
# list_tasks sorts each group by: for tasks the status timestamp (stable), else
# window_activity.
# (cwd, not window index: renumber-windows shifts indices, so index 0 is unreliable.)
rows() {
  local mode="$1" showall ntask=0 nwin=0
  showall="$(cat "$SHOWALL" 2>/dev/null || echo 0)"
  declare -A ACT STAT CWD IDX TS
  local -a WNAMES=()
  # @claude_status / @claude_status_ts are often empty; a bare tab-IFS read would
  # collapse those empties and shift fields, so emit '-'/'0' sentinels for them.
  while IFS=$'\t' read -r idx name act cwd stat ts; do
    [ "$stat" = "-" ] && stat=""
    IDX["$name"]="$idx"; ACT["$name"]="$act"; STAT["$name"]="$stat"; CWD["$name"]="$cwd"; TS["$name"]="$ts"
    WNAMES+=("$name")
  done < <(tmux list-windows -a -F '#{window_index}	#{window_name}	#{window_activity}	#{pane_current_path}	#{?@claude_status,#{@claude_status},-}	#{?@claude_status_ts,#{@claude_status_ts},0}' 2>/dev/null)
  local d t act live repos dc path idx prio sp sts bare
  # ── Task rows: dirs under $TASKS (with per-worktree info) ──
  for d in "$TASKS"/*/; do
    [ -d "$d" ] || continue
    t="$(basename "$d")"
    # Hide abandoned tasks: no window AND untouched > HIDE_DAYS (ctrl-a shows all)
    if [ -z "${ACT[$t]:-}" ] && [ "$showall" != 1 ] && ! recent_enough "$d"; then continue; fi
    act="${ACT[$t]:-0}"; idx="${IDX[$t]:-}"
    bare="${STAT[$t]:-}"; bare="${bare% $MARK}"   # bare status icon (no recency "•")
    # live window -> its @claude_status icon (or a faint dot if no agent icon);
    # no window -> dimmer faint dot (stale).
    if [ -n "${ACT[$t]:-}" ]; then live="${STAT[$t]:-}"; [ -z "$live" ] && live="$DOT_LIVE"; else live="$DOT_STALE"; fi
    live="${live% $MARK}"   # drop the recency "•"; the tree already sorts by recency
    sp="$(subprio_of "$bare")"
    sts="${TS[$t]:-0}"; [ "$sts" = 0 ] && sts="$act"   # fall back to activity if no status ts
    mapfile -t repos < <(worktrees "$d")
    dc=0; [ "$mode" = dirty ] && dc="$(dirty_count "$d")"
    # tasks live under $ROOT/tasks, never at $ROOT itself -> always prio 3
    printf '3\t%s\t%s\t%s\t%s\t%s %s %-40s %s\n' \
      "$sp" "$sts" "$dc" "$t" "$(idxcol "$idx")" "$live" "$t" "${repos[*]:-—}"
    ntask=$((ntask + 1))
  done
  # ── Plain window rows: any tmux window that isn't a task dir (pinned on top) ──
  local name
  for name in ${WNAMES[@]+"${WNAMES[@]}"}; do
    [ -d "$TASKS/$name" ] && continue        # already shown as a task row
    idx="${IDX[$name]:-}"
    live="${STAT[$name]:-}"; [ -z "$live" ] && live="$DOT_LIVE"
    live="${live% $MARK}"   # drop the recency "•"
    prio=1; [ "${CWD[$name]:-}" = "$ROOT" ] && prio=0
    path="$(tilde "${CWD[$name]:-}")"
    # non-task windows: order by tmux window index (stable). window_activity churns
    # for a window whose cwd is a .claude dir (constant writes) -> it kept reshuffling
    # every refresh. Negate the index so the shared -k3,3rn sort yields index ascending.
    printf '%s\t0\t%s\t0\t%s\t%s %s %-40s %s\n' \
      "$prio" "$(( 0 - ${idx:-0} ))" "$name" "$(idxcol "$idx")" "$live" "$name" "$path"
    nwin=$((nwin + 1))
  done
  # ── Separator between the window group and the task group (only if both exist).
  # Empty name field -> accept/preview/clean all treat it as a no-op row.
  if [ "$ntask" -gt 0 ] && [ "$nwin" -gt 0 ]; then
    printf '2\t0\t0\t0\t\t\033[38;5;240m%s\033[0m\n' "$(printf '%*s' 50 '' | tr ' ' '─')"
  fi
}

# Prepend a dim choose-tree-style jump label to the display field. Input is
# prio(1) name(2) display(3); output is name(1) display(2) (prio dropped).
#
# Two label pools so the ranges read cleanly by group:
#   windows (prio 0/1) -> 0-9, then a-z if there are more than ten
#   tasks   (prio 3)   -> always start at 'a'; if windows already spilled into
#                         letters, continue after the last window letter
#   separator (prio 2) -> no label, and does NOT consume a slot
# Because labels no longer align with row positions, each labeled row's fzf
# position is recorded in the map file $LABELS_TMP (label \t row); the jump keys
# resolve through it at keypress time via --jump (an fzf transform bind). The
# caller writes to a temp path and atomically mv's it into place (see list_tasks)
# so a keypress during the 2s reload never reads a half-written map.
label() {
  awk -v M="${LABELS_TMP:-$LABELS}" '
    BEGIN{FS=OFS="\t"; L="0123456789abcdefghijklmnopqrstuvwxyz"; w=0; t=0; printf "" > M}
    {
      prio=$1; name=$2
      if(prio==2){ disp="  " $3 }              # separator: blank slot, no label
      else {
        if(prio<=1){ idx=w; w++ }              # window: 0-9 then a-z
        else { start=(w>10?w:10); idx=start+t; t++ }  # task: from a, or after window letters
        c=(idx<length(L))?substr(L,idx+1,1):" "
        if(c!=" ") print c, NR > M
        disp=sprintf("\033[38;5;240m%s\033[0m %s", c, $3)
      }
      print name, disp
    }'
}

# Resolve a jump label to fzf actions using the map written by label().
# No match (unused label / stale map) -> empty output = fzf no-op.
jump_to() { awk -F'\t' -v c="$1" '$1==c{printf "pos(%d)+accept", $2; exit}' "$LABELS" 2>/dev/null; }

list_tasks() {
  # Fields: prio(1) subprio(2) sortts(3) dirty(4) name(5) display(6+).
  # prio first keeps groups (root / non-task / separator / tasks) pinned. Default (activity)
  # mode also honors subprio (finished, then running) and sorts each subgroup by
  # the status timestamp desc — stable, unlike churning window_activity. name/dirty
  # modes ignore subprio for a straight alphabetical / dirtiest-first view.
  local mode; mode="$(cat "$STATE" 2>/dev/null || echo activity)"
  # cut -f1,5-: keep prio(1) + name(5) display(6) -> label() sees prio,name,display.
  # label() writes the jump map to $LABELS_TMP; we mv it onto $LABELS atomically so
  # a concurrent --jump (transform on a keypress) never reads a half-written file.
  local LABELS_TMP="$LABELS.$$"; export LABELS_TMP
  case "$mode" in
    name)  rows name     | sort -t$'\t' -k1,1n -k5,5             | cut -f1,5- | label ;;
    dirty) rows dirty    | sort -t$'\t' -k1,1n -k4,4rn           | cut -f1,5- | label ;;
    *)     rows activity | sort -t$'\t' -k1,1n -k2,2n -k3,3rn    | cut -f1,5- | label ;;
  esac
  mv -f "$LABELS_TMP" "$LABELS" 2>/dev/null || true
}

next_sort() {
  local cur; cur="$(cat "$STATE" 2>/dev/null || echo activity)"
  case "$cur" in activity) echo name ;; name) echo dirty ;; *) echo activity ;; esac >"$STATE"
}

toggle_all() {
  local cur; cur="$(cat "$SHOWALL" 2>/dev/null || echo 0)"
  [ "$cur" = 1 ] && echo 0 >"$SHOWALL" || echo 1 >"$SHOWALL"
}

show_help() {
  printf '\e[2J\e[H'   # clear screen: `execute` reuses the terminal, else re-opens stack
  local B=$'\e[1m' D=$'\e[2m' C=$'\e[36m' M=$'\e[35m' R=$'\e[0m'
  local W=54 bar
  bar="$(printf '%*s' $((W-2)) '' | tr ' ' '─')"
  sec() { printf '\n  %s%s%s\n' "$B$M" "$1" "$R"; }
  row() { printf '    %s%-15s%s %s%s%s\n' "$C" "$1" "$R" "$D" "$2" "$R"; }
  printf '%s╭─ %sworkspace-tree%s %s─╮%s\n' "$D" "$B" "$R$D" "${bar:16}" "$R"
  sec NAVIGATE
  row 'j / k'          'move down / up'
  row 'g / G'          'top / bottom'
  row '0-9  M-a…z'     'jump to that row (labels shown at left)'
  row 'ctrl-j'         'jump by label (overlay)'
  row 'ctrl-u/ctrl-d'  'move 5 rows up / down'
  row 'ctrl-b/ctrl-f'  'scroll preview'
  sec ACT
  row 'enter'          'switch to that window'
  row 'tab'            'mark (multi-select)'
  row 'ctrl-x'         'clean marked task(s) — popup stays open'
  sec VIEW
  row 'ctrl-o'         'cycle sort: activity / name / dirty'
  row 'ctrl-a'         "toggle hidden tasks (no window, >${HIDE_DAYS}d)"
  row '/'              'show search bar + filter'
  row 'ctrl-c'         'quit'
  printf '\n%s  ⟳ list auto-refreshes every 2s%s\n' "$D" "$R"
  printf '%s╰─%s─╯%s\n' "$D" "$bar" "$R"
  printf '  %spress any key to close%s ' "$D" "$R"
  read -rsn1 _
}

preview() {
  [ -n "${1:-}" ] || return 0   # separator row (empty name): nothing to show
  local t="$1" d="$TASKS/$1" w repo br ab ahead behind dirty act
  act="$(tmux list-windows -a -F '#{window_name}	#{window_activity}' 2>/dev/null \
        | awk -F'\t' -v t="$t" '$1==t{print $2}')"
  # Plain (non-task) window: no worktrees to walk — just header + pane capture.
  if [ ! -d "$d" ]; then
    echo "window: $t"
    [ -n "$act" ] && echo "last active $(date -r "$act" '+%m-%d %H:%M' 2>/dev/null)"
    echo
    printf '%*s\n' "${FZF_PREVIEW_COLUMNS:-80}" '' | tr ' ' '─'
    tmux capture-pane -ep -t "$t" 2>/dev/null
    return
  fi
  echo "task: $t   [sort: $(cat "$STATE" 2>/dev/null || echo activity)]"
  if [ -n "$act" ]; then echo "window: live, last active $(date -r "$act" '+%m-%d %H:%M' 2>/dev/null)"
  else echo "window: none (stale)"; fi
  echo
  for w in "$d"/*/; do
    [ -e "$w/.git" ] || continue
    repo="$(basename "$w")"
    br="$(git -C "$w" symbolic-ref --short HEAD 2>/dev/null || echo '?')"
    ab="$(git -C "$w" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || echo '')"
    behind="${ab%%	*}"; ahead="${ab##*	}"
    dirty="$(git -C "$w" status --porcelain 2>/dev/null | grep -c . || true)"
    printf '├─ %-16s [%s]  ↑%s ↓%s  ~%s dirty\n' \
      "$repo" "$br" "${ahead:-0}" "${behind:-0}" "${dirty:-0}"
  done
  if [ -n "$act" ]; then
    echo
    # full-width divider (fzf exports FZF_PREVIEW_COLUMNS to the preview process)
    printf '%*s\n' "${FZF_PREVIEW_COLUMNS:-80}" '' | tr ' ' '─'
    # -e keeps colors; nowrap preview truncates long lines like choose-tree does.
    tmux capture-pane -ep -t "$t" 2>/dev/null
  fi
}

# The workspace-root window (the ~/work Claude session running task-start/clean).
# Found by cwd == $ROOT so it's stable under renumber-windows; falls back to the
# configured index if no window sits exactly at $ROOT.
root_window() {
  local id
  id="$(tmux list-windows -a -F '#{pane_current_path}	#{window_id}' 2>/dev/null \
        | awk -F'\t' -v r="$ROOT" '$1==r{print $2; exit}')"
  printf '%s' "${id:-$WORK_WIN}"
}

# Fire the /task-clean slash command in the workspace-root window (one per marked
# task) in the background — the popup stays open, focus stays put.
clean_tasks() {
  [ "$#" -eq 0 ] && return
  local t tgt; tgt="$(root_window)"
  for t in "$@"; do
    [ -n "$t" ] || continue     # skip a marked separator row
    tmux send-keys -t "$tgt" "/task-clean $t" Enter
  done
}

# Preview-pane confirmation shown right after ctrl-x (send-keys is silent + keeps
# the popup open, so without this there's no sign it fired). Clears on next focus.
cleaned_msg() {
  local t
  printf '\n  \033[32m🧹 launched /task-clean\033[0m in the work window for:\n\n'
  for t in "$@"; do [ -n "$t" ] && printf '     • %s\n' "$t"; done
  printf '\n  \033[2m(these rows disappear on the next refresh)\033[0m\n'
}

case "${1:-}" in
  --list)     list_tasks ;;
  --jump)     jump_to "$2" ;;
  --preview)  preview "$2" ;;
  --nextsort) next_sort ;;
  --toggleall) toggle_all ;;
  --help)     show_help ;;
  --clean)    shift; clean_tasks "$@" ;;
  --cleaned)  shift; cleaned_msg "$@" ;;
  *)
    echo activity >"$STATE"; echo 0 >"$SHOWALL"
    # choose-tree-style always-visible jump keys: digits 0-9 (windows) and alt-a..z
    # (tasks; letters spill over from windows if there are >10 of them) -> that row.
    # Each key resolves its row through the $LABELS map at keypress time (transform),
    # so the separator consumes no slot and tasks start at 'a'. The map is rewritten
    # atomically on each reload, so a mid-reload press can't read a partial map; an
    # unused label (e.g. a digit past the last window) is a plain no-op.
    jump=()
    for k in 0 1 2 3 4 5 6 7 8 9; do jump+=(--bind "$k:transform(bash '$SELF' --jump $k)"); done
    for k in {a..z}; do jump+=(--bind "alt-$k:transform(bash '$SELF' --jump $k)"); done
    # Start with the cursor on the row for the window we were on (field 1 = name).
    listing="$(list_tasks)"
    cur="$(tmux display-message -p '#{window_name}' 2>/dev/null || true)"
    start_pos="$(printf '%s\n' "$listing" | awk -F'\t' -v c="$cur" '$1==c{print NR; exit}')"
    out="$(printf '%s\n' "$listing" | fzf \
      "${jump[@]}" \
      --sync --bind "start:pos(${start_pos:-1})+preview(bash '$SELF' --preview {1})" \
      --track \
      --layout=reverse-list \
      --ansi --multi --delimiter='\t' --with-nth=2 --no-hscroll \
      --no-input \
      --jump-labels='123456789abcdefghijklmnopqrstuvwxyz' \
      --header '?: help' \
      --preview-window 'right,60%,nowrap' \
      --bind "focus:preview(bash '$SELF' --preview {1})" \
      --bind 'j:down,k:up,g:first,G:last' \
      --bind '/:show-input+enable-search+clear-query' \
      --bind 'enter:accept' \
      --bind 'ctrl-j:jump-accept' \
      --bind 'tab:toggle+down' \
      --bind 'ctrl-u:up+up+up+up+up' --bind 'ctrl-d:down+down+down+down+down' \
      --bind 'ctrl-b:preview-half-page-up' --bind 'ctrl-f:preview-half-page-down' \
      --bind "?:execute(bash '$SELF' --help)" \
      --bind "ctrl-o:execute-silent(bash '$SELF' --nextsort)" \
      --bind "ctrl-a:execute-silent(bash '$SELF' --toggleall)" \
      --bind "ctrl-x:execute-silent(bash '$SELF' --clean {+1})+preview(bash '$SELF' --cleaned {+1})+clear-selection" \
      --bind "load:reload(sleep 2; bash '$SELF' --list)" \
    )" || exit 0
    # ^ auto-refresh: 'load' re-fires after each reload, so this is a single
    #   self-sustaining 2s loop (window/icon changes appear without reopening).
    #   ponytail: ctrl-o/ctrl-a only flip state; the next tick (<=2s) shows it,
    #   which keeps ONE reload chain (a manual reload would spawn a parallel one).
    #   Heavy only in dirty-sort mode, which git-walks every task each tick.
    task="${out%%$'\t'*}"
    if [ -n "$task" ]; then
      # Resolve the name to a window-id and select by that. A bare name is an
      # unreliable `select-window -t` target: a leading dot (.claude), a purely
      # numeric name, or an fnmatch collision can silently resolve to the wrong
      # (or current) window, so enter looks like it does nothing. Exact-match the
      # name here, then target the unambiguous @id. (A stale task with no window
      # yields no id -> no switch, which is correct.)
      wid="$(tmux list-windows -a -F '#{window_name}	#{window_id}' 2>/dev/null \
             | awk -F'\t' -v n="$task" '$1==n{print $2; exit}')"
      [ -n "$wid" ] && tmux select-window -t "$wid"
    fi
    ;;
esac
