# tmux-workspace-tree

fzf popup tree of your multi-repo-workspace tasks. Each task is a dir under
`<root>/tasks/` and (usually) a tmux window of the same name. Every other tmux
window is also listed, shown with its current directory — so this doubles as a
plain window switcher.

- **j/k** — move down/up; **g/G** — top/bottom (nav-first: the search bar is hidden)
- **0-9 / M-a…z** — jump straight to that row (labels are shown dimmed at the left, like choose-tree). Digits label the non-task windows, letters label the tasks (letters spill over if there are more than ten windows); the separator gets no label
- **/** — reveal the search bar and fuzzy-filter (j/k/g/G and the jump keys stay bound)
- **enter** / **ctrl-j** — switch to that window (ctrl-j shows an overlay of jump labels)
- **tab** — mark (multi-select)
- **ctrl-x** — clean marked task(s): sends `/task-clean <name>` (one per marked task)
  to the workspace-root window in the background; the popup stays open and focus stays put,
  and the preview shows a brief confirmation (the cleaned rows vanish on the next refresh)
- **ctrl-o** — cycle sort: activity → name → dirty
- **ctrl-a** — toggle hidden tasks (by default, tasks with no window and untouched
  for more than `@workspace_tree_hide_days` days are hidden)
- **?** — help (full keymap; shown at the bottom of the popup)
- **ctrl-u/ctrl-d** — scroll list; **ctrl-b/ctrl-f** — scroll preview
- **preview** — per-worktree branch, ahead/behind, dirty count (or window cwd/info for
  non-task windows), plus a colored pane capture (`nowrap` so long lines truncate)
- **order** — the workspace-root window (cwd == `@workspace_tree_root`, i.e. the `~/work`
  Claude session) is pinned first, then all other non-task windows (ordered by tmux window
  index — stable, so a busy `.claude` window no longer reshuffles), then tasks. Tasks are
  sub-grouped **finished → waiting → running**, each ordered by the status timestamp
  (`@agent_status_ts`: finish time for done, trigger time for running). That timestamp is
  stable, so running tasks don't reshuffle the way a `window_activity` sort would.
  (`name`/`dirty` sort modes ignore the sub-grouping.) A dim `───` separator row
  divides the window group from the task group (shown only when both exist; it's a
  no-op if selected).
- each row shows, left to right: the jump label, the original tmux **window number**
  (dim), the `@agent_status` icon, the name, and the repos (tasks) or `~`-abbreviated
  cwd (windows)
- the icon is `🤖`/`💬`/`✅`; a row with no agent icon is left blank (no placeholder
  dot). (The status bar's recency `•` marker is stripped here, since the list is
  already recency-sorted.)
- **on open** the cursor starts on the row for the window you were in

## Requirements

- **bash 4+** — uses associative arrays and `mapfile`; macOS ships bash 3.2, so
  `brew install bash` if you run the system one
- **tmux 3.0+**, **fzf**, and **git** on `PATH`

## Install

```tmux
# ~/.tmux.conf
run-shell '~/personal/tmux-workspace-tree/workspace-tree.tmux'
```

Reload tmux, then `prefix + w`.

## Uninstall

Remove the `run-shell` line from `~/.tmux.conf`. To drop the key binding from the
running server without restarting:

```sh
bash ~/personal/tmux-workspace-tree/workspace-tree.tmux stop
```

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

`ctrl-x` doesn't run `task-clean` itself — it sends `/task-clean <name>` (one per marked
task) to the **workspace-root window** in the background (the popup stays open), matching
the workflow of running task-start/task-clean from the `~/work` Claude session. That
window is found by its cwd
(`== @workspace_tree_root`), so it's stable under `renumber-windows`; if no window sits at
that path, it falls back to the `@workspace_tree_work_window` index.

> **Note:** `ctrl-x` is specific to a `task-start`/`task-clean` slash-command workflow.
> If you don't use that, just ignore it — with no tasks marked it does nothing. The rest
> of the popup (window/task switching, sorting, preview) works without it.
