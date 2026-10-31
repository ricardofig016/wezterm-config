# Rolling back

Two backups cover the two halves of the change: the PowerShell profile and the
WezTerm config. Rolling back means putting both back and deleting the state
directory.

## The backups

The profile backup is
`C:\Users\rfigueiredo\Documents\PowerShell\Microsoft.PowerShell_profile.ps1.bak-20261031-133232`.
It holds the profile from before the session layer: a `prompt` function that
emits the OSC 7 current-directory sequence and prints `PS <path>>`, and nothing
else. Restoring it stops the dot-source of `shell\history.ps1`, so PSReadLine
keeps its global history file and per-pane history is off.

The config backup is created by step 13 at
`C:\Users\rfigueiredo\.wezterm.lua.pre-session-layer.bak`, before the loader is
written. It holds the old config as it was, including its
`plugin.require("https://github.com/MLFlexer/resurrect.wezterm")` line and the
old autosave and `gui-startup` handlers. It does not exist until step 13 runs.

Step 14 keeps a dated copy at
`C:\Users\rfigueiredo\.wezterm.lua.pre-session-layer.2026-10-31.bak`. The two
files are identical (same SHA256), and step 14 removes neither one. Use the
dated copy as the rollback source after step 14.

## The loader that replaces the config

Step 13 replaces `C:\Users\rfigueiredo\.wezterm.lua` with three statements:

```lua
local root = "C:/Users/rfigueiredo/Desktop/personal/projects/wezterm-config"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
return dofile(root .. "/wezterm.lua")
```

The old config comes back with one line:

```powershell
Copy-Item 'C:\Users\rfigueiredo\.wezterm.lua.pre-session-layer.2026-10-31.bak' 'C:\Users\rfigueiredo\.wezterm.lua' -Force
```

## Return to the archived plugin setup

Use this when the new layer is abandoned, not when a single save is bad. A bad
save is fixed by deleting the state directory, which leaves the layer
installed.

1. Close every WezTerm window, so no save detector rewrites state after the
   cleanup.
2. Copy the config backup over `C:\Users\rfigueiredo\.wezterm.lua` with the one
   line above.
3. Copy the profile backup over
   `C:\Users\rfigueiredo\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`:

   ```powershell
   Copy-Item 'C:\Users\rfigueiredo\Documents\PowerShell\Microsoft.PowerShell_profile.ps1.bak-20261031-133232' 'C:\Users\rfigueiredo\Documents\PowerShell\Microsoft.PowerShell_profile.ps1' -Force
   ```

4. Delete the state directory as shown below.
5. After step 14, restoring the dated copy also requires the plugin again. Step
   14 removes the resurrect plugin directory under
   `C:\Users\rfigueiredo\AppData\Roaming\wezterm\plugins`, but the old config
   still has its `plugin.require` line, and WezTerm re-clones a required plugin
   on demand. The first old-config launch needs network access and may take
   longer while the plugin is fetched.

The old config does not need this repository. It loads the archived plugin
itself, re-cloning it from GitHub when the cache is missing, so the repository
can stay on disk or be removed once the backups are restored.

## The state directory

The default is
`C:\Users\rfigueiredo\AppData\Roaming\wezterm-session-layer`, and
`WEZTERM_SESSION_STATE_DIR` overrides it. It holds `sessions\<instance id>.json`
for live instances, `history\<pane id>.txt` for per-pane PSReadLine history, and
`session.log` with one rotated backup, `session.log.1`.

Close WezTerm first, then delete the whole directory:

```powershell
Remove-Item -Recurse -Force "$env:APPDATA\wezterm-session-layer"
```

This forgets every saved layout and every per-pane history file. It does not
touch the config, the profile, or the archived plugin's own state. To forget
one instance only, delete
`%APPDATA%\wezterm-session-layer\sessions\<instance id>.json` instead.
