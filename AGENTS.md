# AGENTS.md

This repository is a WezTerm session layer. It replaces the archived
MLFlexer/resurrect.wezterm plugin and stores window and tab layout, pane
working directories, tab titles, and pane identity for per-pane shell history.
It never stores or replays screen text. `wezterm.lua` is the entry point: it
builds the config and registers gui-startup handlers, and it stays free of
timers and disk writes because WezTerm evaluates a config more than once per
process.

`lib\config.lua` owns static options. `lib\keys.lua` owns the key table and its
callbacks. `lib\state.lua` owns schema version 1, one JSON file per instance
under the state directory, atomic replace, staleness, newest-file selection,
pruning, and the fingerprint. `lib\layout.lua` owns the split planner, replay,
restore, and the post-restore self-check. `lib\save.lua` owns the debounced
change detector and the explicit save key. `lib\log.lua` owns structured log
lines and rotation.
`tests\run.ps1` is the only test runner. `tests\harness\unit.lua` runs the
headless suite, `tests\unit` holds its specs, `tests\scenarios` holds real-GUI
scenarios, and `tests\fixtures` holds captured layouts. `shell\` is for the
PowerShell PSReadLine history hook. `docs\` is for architecture and rollback
notes. `plans\` holds design notes and `plans\.gitignore` keeps it out of the
repository.

Run the headless suite with `pwsh -NoProfile -File tests\run.ps1 -Unit` and the
real-GUI suite with `pwsh -NoProfile -File tests\run.ps1 -Integration`. Pass
the switches explicitly; with neither switch the runner defaults to the unit
suite. A passing run prints one PASS line per suite or scenario and exits 0.

Geometry is always in cells, and every pane rectangle is tab-relative from its
tab's top-left corner. Pass `--config-file` before the subcommand, for example
`wezterm.exe --config-file <file> show-keys`, because WezTerm reads options in
order. `show-keys` exits 0 even when the config fails to load, so assert that
the custom keys appear instead of trusting the exit code. The Lua sandbox has
no `debug` library and does not put the config directory on `package.path`;
derive the root from `wezterm.config_dir`, as `wezterm.lua` does.

The state directory, normally `%APPDATA%\wezterm-session-layer`, holds one JSON
file per live instance under `sessions\`, and `WEZTERM_SESSION_STATE_DIR`
overrides it. An instance writes only its own file, and restore takes the
valid file with the newest `saved_at`. Never kill a wezterm process this
worker did not start: kill only pids that appeared after the launch and that
the launch created.

Make one commit per verified step, scoped to that step's files and area. Stage
explicit paths one at a time; `git add -A` and `git add .` are banned. Commit
only when the covering check is green, and never commit while the suite is red
for a reason outside your area. Use `<type>(<area>): <summary>` with type
`feat`, `fix`, `test`, `docs`, or `chore`, and area `entry`, `state`, `layout`,
`save`, `history`, `proof`, `docs`, `repo`, `selfcheck`, or `log`. `selfcheck`
covers the runtime layout verification inside `lib\layout.lua`. `log` covers
the structured logger in `lib\log.lua`. No commit mixes areas. Editor temp
files, test reports, and state directories never enter a commit.
