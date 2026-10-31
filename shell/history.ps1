# Per-pane PSReadLine history and the OSC 7 prompt hook.
#
# Dot-source this file from $PROFILE. Restored panes carry
# WEZTERM_SESSION_HISTORY_KEY (the saved pane id); panes created by hand carry
# only WEZTERM_PANE. Either selects
#   <state dir>\history\<key>.txt
# where <state dir> is WEZTERM_SESSION_STATE_DIR when set, otherwise
# %APPDATA%\wezterm-session-layer. A shell outside WezTerm has neither
# variable, so its PSReadLine global history file is left alone.
#
# PSReadLine 2.4.5 reads the history file during the delayed initialization it
# performs on the first prompt, after the profile has run. Setting the save
# path here is therefore enough for a fresh shell, which is what a restart
# starts. In a live session that has already loaded history, setting the path
# changes where new commands are saved but leaves the loaded items in memory:
# Remove-Module followed by Import-Module was measured not to reload them, and
# PSReadLine exposes no public reload.

# The prompt function is unchanged from the profile it replaces: it emits the
# OSC 7 current-directory sequence that per-pane cwd restore reads, then prints
# the traditional "PS <path>> " prompt.
function prompt {
    $p = $executionContext.SessionState.Path.CurrentLocation
    $osc7 = ""
    if ($p.Provider.Name -eq "FileSystem") {
        $ansi = [char]27
        $path = $p.ProviderPath -replace "\\", "/"
        $osc7 = "$ansi]7;file://${env:COMPUTERNAME}/${path}$ansi\"
    }
    "${osc7}PS $p$('>' * ($nestedPromptLevel + 1)) "
}

try {
    # A scriptblock keeps the helper variables out of the caller's scope.
    & {
        $key = $env:WEZTERM_SESSION_HISTORY_KEY
        if ([string]::IsNullOrWhiteSpace($key) -or $key -notmatch '^[0-9]+$') {
            $key = $env:WEZTERM_PANE
        }
        if ([string]::IsNullOrWhiteSpace($key) -or $key -notmatch '^[0-9]+$') {
            return
        }

        $stateDir = $env:WEZTERM_SESSION_STATE_DIR
        if ([string]::IsNullOrWhiteSpace($stateDir)) {
            $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
            if ([string]::IsNullOrWhiteSpace($appData)) {
                $appData = $env:APPDATA
            }
            if ([string]::IsNullOrWhiteSpace($appData)) {
                return
            }
            $stateDir = Join-Path $appData 'wezterm-session-layer'
        }

        $historyDir = Join-Path $stateDir 'history'
        $historyPath = Join-Path $historyDir ($key + '.txt')

        # PSReadLine creates this on save too, but doing it here means a restored
        # pane gets a usable path even before its first command is saved.
        # New-Item -Force can report success without creating anything when a
        # file blocks the path, so verify before pointing PSReadLine at it.
        New-Item -ItemType Directory -Force -Path $historyDir -ErrorAction Stop | Out-Null
        if (-not (Test-Path -LiteralPath $historyDir -PathType Container)) {
            return
        }

        Import-Module PSReadLine -ErrorAction Stop
        Set-PSReadLineOption -HistorySavePath $historyPath -ErrorAction Stop
    }
} catch {
    # History setup must never stop a shell from starting. On any failure the
    # shell keeps PSReadLine's default global history instead.
}
