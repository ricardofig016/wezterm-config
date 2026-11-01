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
`lib\layout.lua` reads the pinned layout first, then the newest valid session,
and restores it. `lib\save.lua` starts a one-second change detector that
writes two seconds after the window fingerprint settles. `lib\state.lua` owns
schema version 1, one JSON file per instance under `<state dir>\sessions\`, an
optional pin at `<state dir>\pinned.json`, atomic replace, session staleness
and newest-file selection. `shell\history.ps1` points PSReadLine at
`<state dir>\history\<pane id>.txt`. `lib\log.lua` writes structured lines to
`<state dir>\session.log`.

## Install

The cutover happened at step 13. `C:\Users\rfigueiredo\.wezterm.lua` is the
three-statement loader:

```lua
local repo = "C:/Users/rfigueiredo/Desktop/personal/projects/wezterm-config"
package.path = repo .. "/?.lua;" .. repo .. "/?/init.lua;" .. package.path
return dofile(repo .. "/wezterm.lua")
```

The loader puts the repository on `package.path` and evaluates the entry, so
`require("lib.config")` and the other modules resolve from the repository.
WezTerm reads `~/.wezterm.lua` at startup, and a cold launch through the loader
restored the saved layout. The rollback section below and `docs\rollback.md`
name the pre-cutover config and its backups.

The shell half is installed.
`C:\Users\rfigueiredo\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`
dot-sources `shell\history.ps1`. A restored pane carries
`WEZTERM_SESSION_HISTORY_KEY` equal to its saved pane id and gets
`<state dir>\history\<saved pane id>.txt`. A pane created by hand falls back to
`WEZTERM_PANE`. A shell outside WezTerm keeps the global history file.

## Usage

`Alt+P` pins the current layout and `Alt+Shift+P` unpins it. Restore brings
back the pinned layout ahead of any session file, and a pin never expires on
its own. A pin is a snapshot: after you rearrange panes deliberately, press
`Alt+P` again, or restore keeps bringing back the old arrangement. `Alt+P`
shows ` pinned HH:MM:SS ` in the status area; `Alt+Shift+P` shows ` unpinned `
or ` nothing pinned `. Unpinning returns restore to the newest session file.

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
layout, the pinned layout and every per-pane history file:

    Remove-Item -Recurse -Force "$env:APPDATA\wezterm-session-layer"

To forget one instance only, delete
`%APPDATA%\wezterm-session-layer\sessions\<instance id>.json`. That removes the
instance's session file, but if a pin exists it still wins restore; delete
`%APPDATA%\wezterm-session-layer\pinned.json` or press `Alt+Shift+P` to forget
the pin. Without a pin, restore reads the valid session file with the newest
`saved_at`. `WEZTERM_SESSION_STATE_DIR` moves the whole state directory.

## Roll back

The profile backup is
`C:\Users\rfigueiredo\Documents\PowerShell\Microsoft.PowerShell_profile.ps1.bak-20261031-133232`.
Restoring it returns the original prompt and stops loading the per-pane history
hook. The config backup that step 13 creates is
`C:\Users\rfigueiredo\.wezterm.lua.pre-session-layer.bak`; it holds the archived
plugin config. To roll back, copy both backups into place and delete the state
directory. Deleting it also removes `pinned.json`, so the rollback clears the
pin too. `docs\rollback.md` has the commands and the order to run them.
