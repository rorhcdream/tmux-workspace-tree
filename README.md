# tmux-workspace-tree

fzf popup tree of your multi-repo-workspace tasks. Each task is a dir under
`<root>/tasks/` and (usually) a tmux window of the same name. Every other tmux
window is also listed, shown with its current directory — so this doubles as a
plain window switcher.

- **j/k** — move down/up; **g/G** — top/bottom (nav-first: the search bar is hidden)
- **0-9 / M-a…z** — jump straight to that row (labels are shown dimmed at the left, like choose-tree). Digits label the non-task windows, letters label the tasks (letters spill over if there are more than ten windows); the separator gets no label
- **/** — reveal the search bar and fuzzy-filter (j/k/g/G and the jump keys stay bound)
- **enter** / **ctrl-j** — switch to that window (ctrl-j shows an overlay of jump labels)
  and acknowledge its agent status, so a done icon clears on the next status refresh
  even when the popup prevented the normal window-entry hook from recording the visit
- **ctrl-r** — toggle a **🟡** revisit-later mark on the focused window.
  The dot replaces the agent icon while marked, using the same column.
  It persists after closing the tree and clears when you enter that window, through
  the tree or normal tmux navigation. This is separate from Tab's cleanup selection;
  tasks without a live window cannot be marked. Marks appear on the next refresh
  (within 2 seconds).
- **tab** — mark (multi-select)
- **ctrl-x** — clean marked task(s): detects Codex or Claude in the workspace-root
  window, then sends `$task-clean <name>` or `/task-clean <name>` respectively (one per
  marked task); the popup stays open and focus stays put, and the preview shows a brief
  confirmation (the cleaned rows vanish on the next refresh)
- **ctrl-o** — cycle sort: activity → name → dirty
- **ctrl-a** — toggle hidden tasks (by default, tasks with no window and untouched
  for more than `@workspace_tree_hide_days` days are hidden)
- **?** — help (full keymap; shown at the bottom of the popup)
- **ctrl-u/ctrl-d** — scroll list; **ctrl-b/ctrl-f** — scroll preview
- **preview** — per-worktree branch, ahead/behind, dirty count (or window cwd/info for
  non-task windows), plus a colored pane capture (`nowrap` so long lines truncate)
- **order** — the workspace-root window (cwd == `@workspace_tree_root`, i.e. the `~/work`
  agent session) is pinned first, then all other non-task windows (in ascending
  window-number order), then tasks. Tasks are
  sub-grouped **finished → 🟡 revisit later → waiting → running**. Marked tasks
  are ordered by window index, even if their underlying agent status changes.
  Finished and waiting rows are ordered by
  the status timestamp (`@agent_status_ts` — finish time, or when the prompt appeared),
  newest first. **Running rows are ordered by tmux window index**, so they hold a fixed
  position: their timestamp is the current turn's trigger time and is restamped on every
  new turn, which otherwise reshuffles the group (and its jump labels) under the cursor.
  Tasks without an icon come last, sorted by the newer of tmux window activity
  and `@agent_status_ts`, newest first. Terminal output from Codex or any other
  program counts, including redraws;
  without agent-status hooks this measures terminal activity rather than turn completion.
  (`name`/`dirty` modes ignore this sub-grouping.) A dim `───` separator row divides
  the window group from the task group (shown only when both exist; it's a no-op if
  selected).
- **while open** — the popup publishes a reference-counted tmux marker
  (`@agent_status_popup_count`) so the companion agent-status plugin doesn't treat the
  covered pane as viewed and prematurely clear a newly completed status
- each row shows, left to right: the jump label, the original tmux **window number**
  (dim), the `@agent_status` icon (or revisit-later dot), the name, and the repos
  (tasks) or `~`-abbreviated
  cwd (windows)
- the icon is `🤖`/`💬`/`✅`; a row with no agent icon is left blank (no placeholder
  dot). (The status bar's recency `•` marker is stripped here, since the list is
  already recency-sorted.) The icons and status timestamps come from
  [tmux-agent-status](https://github.com/rorhcdream/tmux-agent-status) — install it
  alongside this plugin to get the per-agent grouping and icons; without it, rows
  simply show no icon and tasks sort by window activity.
- **on open** the cursor starts on the row for the window you were in

## Requirements

- **bash 4+** — uses associative arrays and `mapfile`; macOS ships bash 3.2, so
  `brew install bash` if you run the system one
- **tmux 3.2+**, **fzf**, and **git** on `PATH` — 3.2 is where format number
  operators (`#{e|+:…}`) landed; the popup's reference counter needs them

## Install

Clone the repo, then point tmux at its entry script:

```sh
git clone https://github.com/rorhcdream/tmux-workspace-tree ~/.tmux/plugins/tmux-workspace-tree
```

```tmux
# ~/.tmux.conf — adjust the path if you cloned elsewhere
run-shell '~/.tmux/plugins/tmux-workspace-tree/workspace-tree.tmux'
```

Reload tmux, then `prefix + w`.

## Uninstall

Remove the `run-shell` line from `~/.tmux.conf`. To drop the key binding from the
running server without restarting:

```sh
bash ~/.tmux/plugins/tmux-workspace-tree/workspace-tree.tmux stop
```

Stopping also removes this plugin's window-entry hooks. Revisit marks are stored
as window-local tmux options (`@workspace_tree_unread`) and disappear with the
window or tmux server.

The only files written are a few small scratch files (sort mode, the show-all
toggle, and the jump-label map) under a private per-user dir
`$TMPDIR/wstree-<uid>/`, so there's nothing else to clean up.

## Options

```tmux
set -g @workspace_tree_key         w      # trigger key (default w)
set -g @workspace_tree_root        ~/work # workspace root (tasks live in <root>/tasks)
set -g @workspace_tree_work_window 0      # fallback work-window index (see below)
set -g @workspace_tree_hide_days   14     # hide no-window tasks untouched > N days (ctrl-a shows all)
```

`ctrl-x` doesn't run `task-clean` itself. It detects the client running in the
**workspace-root window**, then sends `$task-clean <name>` to Codex or
`/task-clean <name>` to Claude (one per marked task) in the background. The popup stays
open. That window is found by its cwd
(`== @workspace_tree_root`), so it's stable under `renumber-windows`; if no window sits at
that path, it falls back to the `@workspace_tree_work_window` index.

> **Note:** `ctrl-x` is specific to the Claude/Codex `task-start`/`task-clean` workflow.
> If you don't use that, just ignore it — with no tasks marked it does nothing. The rest
> of the popup (window/task switching, sorting, preview) works without it.
