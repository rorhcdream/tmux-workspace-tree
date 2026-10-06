#!/usr/bin/env bash
# Workspace task tree in an fzf popup. Rows = tasks (dir under <root>/tasks) plus
# any other tmux window (shown with its cwd). Preview = per-task worktree git
# stats (or window info) + live pane tail.
#
# choose-tree-style keys, plus what choose-tree can't do:
#   0-9 / alt-a..z         jump straight to that row (labels shown dimmed at left)
#   enter / ctrl-j (jump)  switch to task's window (ctrl-j = overlay number/letter labels)
#   ctrl-r                 toggle revisit-later mark on the focused window
#   tab                    mark (multi-select)
#   ctrl-x                 clean marked task(s): sends the client-appropriate
#                          task-clean command to the workspace-root agent window
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
# Per-user state dir. It MUST be a real, owner-only directory we actually own:
# on a shared host another user could pre-create the predictable path (or plant
# a symlink there) and redirect our writes. mkdir alone isn't enough — it
# succeeds on an existing attacker-owned dir — so we validate owner + type and,
# if anything looks off, fall back to a freshly created private dir for this run
# (state won't persist across popups then, but it's never attacker-controlled).
WSDIR="${TMPDIR:-/tmp}/wstree-$(id -u)"
mkdir -p "$WSDIR" 2>/dev/null
# BSD/macOS uses -f for a format string; GNU/Linux uses -c.  GNU stat also
# accepts -f, but interprets it as "file system status" and can return a
# successful non-owner value, so probing BSD syntax first is not portable.
case "$(uname -s)" in
  Darwin|*BSD) _owner="$(stat -f '%u' "$WSDIR" 2>/dev/null)" ;;
  *)           _owner="$(stat -c '%u' "$WSDIR" 2>/dev/null)" ;;
esac
if [ -L "$WSDIR" ] || [ ! -d "$WSDIR" ] || [ "$_owner" != "$(id -u)" ]; then
  WSDIR="$(mktemp -d "${TMPDIR:-/tmp}/wstree.XXXXXX")" || exit 1
fi
chmod 700 "$WSDIR" 2>/dev/null || true
STATE="$WSDIR/sort"
SHOWALL="$WSDIR/showall"
LABELS="$WSDIR/labels"   # jump label -> row position map (see label())
HIDE_DAYS="$(tmux show-option -gqv @workspace_tree_hide_days)"; HIDE_DAYS="${HIDE_DAYS:-14}"
# tmux-agent-status appends this recency marker to some icons ("✅ •"), making
# those cells wider than bare ones. We keep it but reserve a fixed slot (below).
MARK="$(tmux show-option -gqv @agent_status_recent_marker)"; MARK="${MARK:-•}"
# The status plugin's icons, used to group tasks (finished on top, then running).
I_DONE="$(tmux show-option -gqv @agent_status_done)"; I_DONE="${I_DONE:-✅}"
I_WORK="$(tmux show-option -gqv @agent_status_working)"; I_WORK="${I_WORK:-🤖}"
I_WAIT="$(tmux show-option -gqv @agent_status_waiting)"; I_WAIT="${I_WAIT:-💬}"
# Blank placeholder for no-agent-icon rows: 2 spaces, matching emoji width so
# names stay column-aligned whether or not a row has an icon. (Same for live and
# stale rows — the distinction is no longer drawn with a dot.)
DOT_LIVE='  '
DOT_STALE='  '

# Task order: finished, revisit later, waiting, running, then no icon.
# Marked and running tasks hold a fixed position by window index (see rows()).
subprio_of() {
  if [ "${2:-0}" = 1 ]; then echo 1; return; fi
  case "$1" in
    "$I_DONE") echo 0 ;;
    "$I_WAIT") echo 2 ;;
    "$I_WORK") echo 3 ;;
    *)         echo 4 ;;
  esac
}

worktrees() { local d="$1" w; for w in "$d"*/; do [ -e "$w/.git" ] && basename "$w"; done; }
# true if the task dir has any file modified within HIDE_DAYS days
recent_enough() { [ -n "$(find "$1" -maxdepth 3 -type f -mtime "-$HIDE_DAYS" -print -quit 2>/dev/null)" ]; }
# tmux clocks use epoch seconds; tmux-agent-status uses epoch milliseconds.
# Sorting requires a common unit so the source does not outweigh actual recency.
epoch_seconds() { local n="${1:-0}"; [ "$n" -gt 9999999999 ] 2>/dev/null && n=$(( n / 1000 )); printf '%s' "$n"; }
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
# The revisit mark takes priority in the two-cell agent icon slot.
unread_icon() { printf '🟡'; }
# ~-abbreviate a home path (bash's ${v/#$HOME/~} is unreliable, so strip the prefix)
tilde() { case "$1" in "$HOME") printf '~' ;; "$HOME"/*) printf '~%s' "${1#$HOME}" ;; *) printf '%s' "$1" ;; esac; }
# Fixed-width name cell: pad short names, ellipsis-truncate long ones (…), so the
# repos/path column always aligns and never collides with a long name. Names are
# ASCII, so char count == display width. NAME_W is tunable.
NAME_W=30
namecol() {
  if [ "${#1}" -gt "$NAME_W" ]; then printf '%s…' "${1:0:$((NAME_W-1))}"
  else printf '%-*s' "$NAME_W" "$1"; fi
}

# emit: <prio>\t<subprio>\t<sortts>\t<dirty-or-0>\t<name>\t<targetid>\t<display>
# prio groups rows: 0 = workspace-root window (cwd == $ROOT, e.g. the ~/work Claude
# session), 1 = other non-task windows (on top), 2 = separator line, 3 = tasks.
# subprio sub-orders tasks (finished, revisit later, waiting, running, none). sortts is the key
# list_tasks sorts each group by: the status timestamp for finished/waiting tasks,
# and the negated window index for running tasks and for non-task windows.
# targetid is the tmux @window-id enter/jump switches to — unique
# even when two windows share a name (name alone is ambiguous).
# (cwd, not window index: renumber-windows shifts indices, so index 0 is unreliable.)
rows() {
  local mode="$1" showall ntask=0 nwin=0
  showall="$(cat "$SHOWALL" 2>/dev/null || echo 0)"
  declare -A ACT STAT CWD IDX TS WID UNREAD
  local -a WINLINES=()
  # @agent_status / @agent_status_ts are often empty; a bare tab-IFS read would
  # collapse those empties and shift fields, so emit '-'/'0' sentinels for them.
  # We stash each raw line (sentinels intact) in WINLINES and iterate THAT for the
  # window rows below — the name-keyed arrays collapse duplicate names (two windows
  # named "server" would share one entry), but each raw line is distinct.
  while IFS=$'\t' read -r idx name act cwd stat ts wid unread; do
    WINLINES+=("$idx"$'\t'"$name"$'\t'"$act"$'\t'"$cwd"$'\t'"$stat"$'\t'"$ts"$'\t'"$wid"$'\t'"$unread")
    [ "$stat" = "-" ] && stat=""
    IDX["$name"]="$idx"; ACT["$name"]="$act"; STAT["$name"]="$stat"; CWD["$name"]="$cwd"; TS["$name"]="$ts"; WID["$name"]="$wid"; UNREAD["$name"]="$unread"
  done < <(tmux list-windows -a -F '#{window_index}	#{window_name}	#{window_activity}	#{pane_current_path}	#{?@agent_status,#{@agent_status},-}	#{?@agent_status_ts,#{@agent_status_ts},0}	#{window_id}	#{?@workspace_tree_unread,#{@workspace_tree_unread},0}' 2>/dev/null)
  local d t act live repos dc path idx prio sp sts bare wid cwd stat ts name
  # ── Task rows: dirs under $TASKS (with per-worktree info) ──
  for d in "$TASKS"/*/; do
    [ -d "$d" ] || continue
    t="$(basename "$d")"
    # Hide abandoned tasks: no window AND untouched > HIDE_DAYS (ctrl-a shows all)
    if [ -z "${ACT[$t]:-}" ] && [ "$showall" != 1 ] && ! recent_enough "$d"; then continue; fi
    act="${ACT[$t]:-0}"; idx="${IDX[$t]:-}"
    bare="${STAT[$t]:-}"; bare="${bare% $MARK}"   # bare status icon (no recency "•")
    # live window -> its @agent_status icon (or a faint dot if no agent icon);
    # no window -> dimmer faint dot (stale).
    if [ -n "${ACT[$t]:-}" ]; then live="${STAT[$t]:-}"; [ -z "$live" ] && live="$DOT_LIVE"; else live="$DOT_STALE"; fi
    live="${live% $MARK}"   # drop the recency "•"; the tree already sorts by recency
    [ "${UNREAD[$t]:-0}" = 1 ] && live="$(unread_icon)"
    sp="$(subprio_of "$bare" "${UNREAD[$t]:-0}")"
    sts="$(epoch_seconds "${TS[$t]:-0}")"
    [ "$sts" = 0 ] && sts="$act" # fall back to pane activity if no agent timestamp
    # Running tasks order by window index, NOT by the status timestamp: that
    # timestamp is the current turn's trigger time, and an agent restamps it on
    # every new turn (codex on each task_started), so a timestamp sort reshuffles
    # the running group while you are looking at it — and the jump labels move
    # with the rows. Finished/waiting keep timestamp order: there it only moves on
    # a real transition, and "most recently finished" is the point of the group.
    # Negate the index so the shared -k3,3rn sort yields ascending index, exactly
    # like the non-task window rows below.
    # Marked tasks also stay in index order while their agent status changes.
    case "$sp" in 1|3) sts=$(( 0 - ${idx:-0} )) ;; esac
    mapfile -t repos < <(worktrees "$d")
    dc=0; [ "$mode" = dirty ] && dc="$(dirty_count "$d")"
    # tasks live under $ROOT/tasks, never at $ROOT itself -> always prio 3.
    # targetid = the task's live window id (empty if stale -> enter is a no-op).
    printf '3\t%s\t%s\t%s\t%s\t%s\t%s %s %s \033[38;5;245m%s\033[0m\n' \
      "$sp" "$sts" "$dc" "$t" "${WID[$t]:-}" "$(idxcol "$idx")" "$live" "$(namecol "$t")" "${repos[*]:-—}"
    ntask=$((ntask + 1))
  done
  # ── Plain window rows: any tmux window that isn't a task dir (pinned on top) ──
  # Iterate the raw per-window lines (not the name-keyed arrays) so two windows with
  # the same name each get their own row, index, and id instead of collapsing to one.
  local wline act2
  for wline in ${WINLINES[@]+"${WINLINES[@]}"}; do
    IFS=$'\t' read -r idx name act2 cwd stat ts wid unread <<< "$wline"
    [ -d "$TASKS/$name" ] && continue        # already shown as a task row
    [ "$stat" = "-" ] && stat=""
    live="$stat"; [ -z "$live" ] && live="$DOT_LIVE"
    live="${live% $MARK}"   # drop the recency "•"
    [ "$unread" = 1 ] && live="$(unread_icon)"
    prio=1; [ "$cwd" = "$ROOT" ] && prio=0
    path="$(tilde "$cwd")"
    # non-task windows: order by tmux window index (stable). window_activity churns
    # for a window whose cwd is a .claude dir (constant writes) -> it kept reshuffling
    # every refresh. Negate the index so the shared -k3,3rn sort yields index ascending.
    printf '%s\t0\t%s\t0\t%s\t%s\t%s %s %s \033[38;5;245m%s\033[0m\n' \
      "$prio" "$(( 0 - ${idx:-0} ))" "$name" "$wid" "$(idxcol "$idx")" "$live" "$(namecol "$name")" "$path"
    nwin=$((nwin + 1))
  done
  # ── Separator between the window group and the task group (only if both exist).
  # Empty name field -> accept/preview/clean all treat it as a no-op row. Labeled
  # "── tasks ──…" so the group boundary reads at a glance.
  if [ "$ntask" -gt 0 ] && [ "$nwin" -gt 0 ]; then
    # empty name (f5) + empty targetid (f6) -> not selectable / no-op on enter
    printf '2\t0\t0\t0\t\t\t\033[38;5;240m── tasks %s\033[0m\n' "$(printf '%*s' 40 '' | tr ' ' '─')"
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
      prio=$1; name=$2; tgt=$3
      if(prio==2){ disp="  " $4 }              # separator: blank slot, no label
      else {
        if(prio<=1){ idx=w; w++ }              # window: 0-9 then a-z
        else { start=(w>10?w:10); idx=start+t; t++ }  # task: from a, or after window letters
        c=(idx<length(L))?substr(L,idx+1,1):" "
        if(c!=" ") print c, NR > M
        disp=sprintf("\033[38;5;240m%s\033[0m %s", c, $4)
      }
      print name, tgt, disp
    }'
}

# Resolve a jump label to fzf actions using the map written by label().
# No match (unused label / stale map) -> empty output = fzf no-op.
jump_to() { awk -F'\t' -v c="$1" '$1==c{printf "pos(%d)+accept", $2; exit}' "$LABELS" 2>/dev/null; }

list_tasks() {
  # Fields: prio(1) subprio(2) sortts(3) dirty(4) name(5) display(6+).
  # prio first keeps groups (root / non-task / separator / tasks) pinned. Default (activity)
  # mode also honors subprio (finished, revisit later, waiting, running); finished
  # and waiting sort by status timestamp desc, while marked and running tasks keep a
  # fixed position by window index. name/dirty modes ignore subprio for a straight
  # alphabetical / dirtiest-first view.
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

toggle_unread() {
  local id="${1:-}" current
  # Separators and tasks without a live window have no target.
  [ -n "$id" ] || return 0
  current="$(tmux show-option -wqv -t "$id" @workspace_tree_unread 2>/dev/null)" || return 0
  if [ "$current" = 1 ]; then
    tmux set-option -wu -t "$id" @workspace_tree_unread
  else
    tmux set-option -w -t "$id" @workspace_tree_unread 1
  fi
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
  row 'ctrl-r'         'toggle 🟡 revisit later (clears on entry)'
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

# Format an epoch as a date, portably: tmux uses seconds while tmux-agent-status
# publishes milliseconds. Normalize the latter before calling BSD or GNU date.
fmtdate() {
  local epoch; epoch="$(epoch_seconds "$1")"
  date -r "$epoch" "$2" 2>/dev/null || date -d "@$epoch" "$2" 2>/dev/null
}

preview() {
  [ -n "${1:-}" ] || return 0   # separator row (empty name): nothing to show
  local t="$1" id="${2:-}" d="$TASKS/$1" w repo br ab ahead behind dirty act status_act activity
  # Prefer the unique window id for the live-window lookups (name is ambiguous when
  # two windows share it); fall back to name-match only when no id was passed.
  if [ -n "$id" ]; then
    activity="$(tmux display-message -p -t "$id" \
      '#{window_activity}	#{?@agent_status_ts,#{@agent_status_ts},0}' 2>/dev/null)"
  else
    activity="$(tmux list-windows -a \
      -F '#{window_name}	#{window_activity}	#{?@agent_status_ts,#{@agent_status_ts},0}' 2>/dev/null \
      | awk -F'\t' -v t="$t" '$1==t{print $2 "\t" $3; exit}')"
  fi
  IFS=$'\t' read -r act status_act <<< "$activity"
  # Plain (non-task) window: no worktrees to walk — just header + pane capture.
  if [ ! -d "$d" ]; then
    echo "window: $t"
    [ -n "$act" ] && echo "last output $(fmtdate "$act" '+%m-%d %H:%M')"
    echo
    printf '%*s\n' "${FZF_PREVIEW_COLUMNS:-80}" '' | tr ' ' '─'
    tmux capture-pane -ep -t "${id:-$t}" 2>/dev/null
    return
  fi
  echo "task: $t   [sort: $(cat "$STATE" 2>/dev/null || echo activity)]"
  if [ -n "$act" ]; then
    echo "window: live"
    if [ "${status_act:-0}" -gt 0 ] 2>/dev/null; then
      echo "agent activity $(fmtdate "$status_act" '+%m-%d %H:%M:%S')"
      echo "last output    $(fmtdate "$act" '+%m-%d %H:%M')"
    else
      echo "agent activity unavailable (sorting falls back to last output)"
      echo "last output    $(fmtdate "$act" '+%m-%d %H:%M')"
    fi
  else
    echo "window: none (stale)"
  fi
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
    tmux capture-pane -ep -t "${id:-$t}" 2>/dev/null
  fi
}

# The workspace-root window (the Claude or Codex session running task-start/clean).
# Found by cwd == $ROOT so it's stable under renumber-windows; falls back to the
# configured index if no window sits exactly at $ROOT.
root_window() {
  local id
  id="$(tmux list-windows -a -F '#{pane_current_path}	#{window_id}' 2>/dev/null \
        | awk -F'\t' -v r="$ROOT" '$1==r{print $2; exit}')"
  printf '%s' "${id:-$WORK_WIN}"
}

# Identify the agent below the target pane's shell. tmux's pane_current_command is
# enough for native binaries, but npm-launched Codex reports "node" (or
# "MainThread") instead. In that case, walk the process table below pane_pid and
# choose the closest recognizable agent executable.
pane_agent() {
  local tgt="$1" current pane_pid detected
  current="$(tmux display-message -p -t "$tgt" '#{pane_current_command}' 2>/dev/null)"
  case "${current##*/}" in
    codex*) printf 'codex'; return ;;
    claude*) printf 'claude'; return ;;
  esac

  pane_pid="$(tmux display-message -p -t "$tgt" '#{pane_pid}' 2>/dev/null)"
  [ -n "$pane_pid" ] || return
  detected="$(ps -Ao pid=,ppid=,comm=,args= 2>/dev/null | awk -v root="$pane_pid" '
    function depth(pid, cur, n) {
      cur=pid
      for(n=0; n<100 && cur; n++) {
        if(cur==root) return n
        cur=parent[cur]
      }
      return -1
    }
    function base(s) { sub(/^.*\//, "", s); return tolower(s) }
    function kind(name, args, fields, n, i, seen, b) {
      b=base(name)
      if(b ~ /^codex/) return "codex"
      if(b ~ /^claude/) return "claude"
      if(b!="node" && b!="mainthread") return ""
      n=split(args, fields, /[[:space:]]+/)
      for(i=1; i<=n && seen<2; i++) {
        if(fields[i]=="") continue
        seen++
        b=base(fields[i])
        if(b=="codex") return "codex"
        if(b=="claude") return "claude"
      }
      return ""
    }
    {
      pid=$1; parent[pid]=$2; name[pid]=$3
      $1=$2=$3=""; command[pid]=$0
    }
    END {
      best=101; found=""
      for(pid in parent) {
        d=depth(pid)
        if(d<0 || d>=best) continue
        k=kind(name[pid], command[pid])
        if(k!="") { best=d; found=k }
      }
      printf "%s", found
    }')"
  printf '%s' "$detected"
}

# Claude exposes task-clean as a slash command; Codex exposes it as a $ skill.
# Keep the established Claude syntax as the fallback for an unrecognized wrapper.
task_clean_prefix() {
  case "$(pane_agent "$1")" in
    codex) printf '$task-clean' ;;
    *)     printf '/task-clean' ;;
  esac
}

# Fire the client-appropriate task-clean command in the workspace-root window
# (one per marked task) in the background — the popup stays open, focus stays put.
clean_tasks() {
  [ "$#" -eq 0 ] && return
  local t tgt prefix command
  tgt="$(root_window)"
  # Leave copy-mode first. A pane in copy-mode consumes the pasted command as key
  # presses instead of text, and with mode-keys vi the leading "/" of "/task-clean"
  # is the search key: tmux opens its "(search down)" command-prompt. That prompt is
  # a CLIENT OVERLAY, and a client holds only one — so tmux tears down our popup to
  # show it. The tree vanishes, the command never reaches the agent, and the rest of
  # the string is typed into a search box. pane_in_mode reports the window's active
  # pane — the same pane send-keys targets — so `-X cancel` fires only when there is
  # actually a mode to leave.
  if [ "$(tmux display-message -p -t "$tgt" '#{pane_in_mode}' 2>/dev/null)" = 1 ]; then
    tmux send-keys -t "$tgt" -X cancel 2>/dev/null || true
  fi
  prefix="$(task_clean_prefix "$tgt")"
  for t in "$@"; do
    [ -n "$t" ] || continue     # skip a marked separator row
    printf -v command '%s %s' "$prefix" "$t"
    tmux send-keys -t "$tgt" -l -- "$command"
    # Let Codex consume the pasted command before submitting it. Sending the text
    # and Enter together can leave the command sitting unsubmitted in the prompt.
    sleep 0.1
    tmux send-keys -t "$tgt" Enter
  done
}

# Preview-pane confirmation shown right after ctrl-x (send-keys is silent + keeps
# the popup open, so without this there's no sign it fired). Clears on next focus.
cleaned_msg() {
  local t prefix
  prefix="$(task_clean_prefix "$(root_window)")"
  printf '\n  \033[32m🧹 launched %s\033[0m in the work window for:\n\n' "$prefix"
  for t in "$@"; do [ -n "$t" ] && printf '     • %s\n' "$t"; done
  printf '\n  \033[2m(these rows disappear on the next refresh)\033[0m\n'
}

case "${1:-}" in
  --list)     list_tasks ;;
  --jump)     jump_to "$2" ;;
  --preview)  preview "$2" "${3:-}" ;;
  --nextsort) next_sort ;;
  --toggleall) toggle_all ;;
  --toggle-unread) toggle_unread "${2:-}" ;;
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
    # Start with the cursor on the row for the window we were on. Match by window id
    # (field 2), not name (field 1) — names aren't unique, ids are. Fields per row:
    # 1=name  2=targetid(@id)  3=display.
    listing="$(list_tasks)"
    cur="$(tmux display-message -p '#{window_id}' 2>/dev/null || true)"
    start_pos="$(printf '%s\n' "$listing" | awk -F'\t' -v c="$cur" '$2==c{print NR; exit}')"
    # Avoid fzf's global --track on reload. The identity fields stay stable, but
    # rendered rows do not: removing a window shifts jump labels and may renumber
    # tmux indexes. Tracking the whole changing line can move focus/viewport and
    # make a correctly sorted surviving task appear to have jumped elsewhere.
    out="$(printf '%s\n' "$listing" | fzf \
      "${jump[@]}" \
      --sync --bind "start:pos(${start_pos:-1})+preview(bash '$SELF' --preview {1} {2})" \
      --layout=reverse-list \
      --ansi --multi --delimiter='\t' --with-nth=3 --no-hscroll \
      --no-input \
      --jump-labels='123456789abcdefghijklmnopqrstuvwxyz' \
      --header '?: help' \
      --preview-window 'right,60%,nowrap' \
      --bind "focus:preview(bash '$SELF' --preview {1} {2})" \
      --bind 'j:down,k:up,g:first,G:last' \
      --bind '/:show-input+enable-search+clear-query' \
      --bind 'enter:accept' \
      --bind 'ctrl-j:jump-accept' \
      --bind 'tab:toggle+down' \
      --bind "ctrl-r:execute-silent(bash '$SELF' --toggle-unread {2})" \
      --bind 'ctrl-u:up+up+up+up+up' --bind 'ctrl-d:down+down+down+down+down' \
      --bind 'ctrl-b:preview-half-page-up' --bind 'ctrl-f:preview-half-page-down' \
      --bind "?:execute(bash '$SELF' --help)" \
      --bind "ctrl-o:execute-silent(bash '$SELF' --nextsort)" \
      --bind "ctrl-a:execute-silent(bash '$SELF' --toggleall)" \
      --bind "ctrl-x:execute-silent(bash '$SELF' --clean {+1})+preview(bash '$SELF' --cleaned {+1})+clear-selection" \
      --bind "load:refresh-preview+reload(sleep 2; bash '$SELF' --list)" \
    )" || exit 0
    # ^ auto-refresh: 'load' re-fires after each reload, so this refreshes the
    #   focused preview and starts the next iteration of one self-sustaining 2s
    #   loop (window/icon changes appear without reopening).
    #   ponytail: ctrl-o/ctrl-a only flip state; the next tick (<=2s) shows it,
    #   which keeps ONE reload chain (a manual reload would spawn a parallel one).
    #   Heavy only in dirty-sort mode, which git-walks every task each tick.
    # Switch by the row's targetid (field 2 = @window-id), which is unique and
    # unambiguous — a bare name is an unreliable `select-window -t` target (a leading
    # dot like .claude, a numeric name, an fnmatch collision, or a duplicate name all
    # mis-resolve). Empty targetid (separator, or a stale task with no window) -> no
    # switch, which is correct.
    target="$(printf '%s\n' "$out" | cut -f2)"
    if [ -n "$target" ] && tmux select-window -t "$target"; then
      # Also clear explicitly: an already-open tree may predate hook installation,
      # and selecting the current window need not trigger a window-change hook.
      tmux set-option -wu -t "$target" @workspace_tree_unread
    fi
    ;;
esac
