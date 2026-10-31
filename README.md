# WezTerm session layer

This repository owns the WezTerm session layer. It saves the window cell size,
each tab's pane layout and title, each pane's working directory, and pane
identity for per-pane shell history, then rebuilds them on the next launch. It
replaces MLFlexer/resurrect.wezterm, which is archived and stores a session as
screen text plus a split tree guessed from pane ratios. This layer stores cell
rectangles and a divider-aware split tree, and it never saves or replays screen
text.

`wezterm.lua` is the entry. It assembles static options from `lib\config.lua`
and keys from `lib\keys.lua`, then registers two gui-startup handlers.
`lib\layout.lua` reads the newest valid state and restores it, and
`lib\save.lua` starts a one-second change detector that writes two seconds
after the window fingerprint settles. `lib\state.lua` owns schema version 1,
one JSON file per instance under `<state dir>\sessions\`, atomic replace,
staleness and newest-file selection. `shell\history.ps1` points PSReadLine at
`<state dir>\history\<pane id>.txt`. `lib\log.lua` writes structured lines to
`<state dir>\session.log`.

## Install

The working config until cutover is `C:\Users\rfigueiredo\.wezterm.lua`, which
still loads the archived plugin. Development runs this repository's entry with
`--config-file` and leaves that file alone.

Cutover is step 13. It backs up the old config to
`C:\Users\rfigueiredo\.wezterm.lua.pre-session-layer.bak` and replaces
`C:\Users\rfigueiredo\.wezterm.lua` with this three-statement loader:

```lua
local root = "C:/Users/rfigueiredo/Desktop/personal/projects/wezterm-config"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
return dofile(root .. "/wezterm.lua")
```

The loader puts the repository on `package.path` and evaluates the entry, so
`require("lib.config")` and the other modules resolve from the repository.
WezTerm reads `~/.wezterm.lua` at startup. Until step 13 runs, the loader is a
target, not a fact.

The shell half is already installed.
`C:\Users\rfigueiredo\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`
dot-sources `shell\history.ps1`. A restored pane carries
`WEZTERM_SESSION_HISTORY_KEY` equal to its saved pane id and gets
`<state dir>\history\<saved pane id>.txt`. A pane created by hand falls back to
`WEZTERM_PANE`. A shell outside WezTerm keeps the global history file.

## Test

Run all three suites with one command:

    pwsh -NoProfile -File tests\run.ps1 -All

The unit suite runs `tests\harness\unit.lua` through `wezterm.exe --config-file
... show-keys`, needs no window, and covers the state schema, the planner and
restore, the save detector, fault injection and 30 seeded property tests. The
shell suite runs four PSReadLine history cases in fresh pwsh processes. The
integration suite launches `wezterm-gui.exe` for each scenario with an isolated
state directory under `%TEMP%`, reads each scenario's JSON report, kills only
the process ids it started, and fails on a missing report, a timeout or a stray
process. A passing run prints one PASS line per suite or scenario and exits 0.

## Reset the session

Close WezTerm first, then delete the state directory to forget every saved
layout and every per-pane history file:

    Remove-Item -Recurse -Force "$env:APPDATA\wezterm-session-layer"

To forget one instance only, delete
`%APPDATA%\wezterm-session-layer\sessions\<instance id>.json`. Restore reads
the valid file with the newest `saved_at` across the folder, so the other
instances are untouched. `WEZTERM_SESSION_STATE_DIR` moves the whole state
directory.

## Roll back

The profile backup is
`C:\Users\rfigueiredo\Documents\PowerShell\Microsoft.PowerShell_profile.ps1.bak-20261031-133232`.
Restoring it returns the original prompt and stops loading the per-pane history
hook. The config backup that step 13 creates is
`C:\Users\rfigueiredo\.wezterm.lua.pre-session-layer.bak`; it holds the archived
plugin config. To roll back, copy both backups into place and delete the state
directory. `docs\rollback.md` has the commands and the order to run them.
