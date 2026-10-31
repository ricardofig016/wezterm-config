[CmdletBinding()]
param()

# Headless proof of the shell half of step 6: given the environment variables
# WezTerm and restore set, does PSReadLine end up with exactly one pane's
# history file? Each case runs in a fresh pwsh under a temporary
# USERPROFILE/APPDATA, so the real global history file is never read or
# written. Run with:
#
#   pwsh -NoProfile -File tests\shell\run.ps1
#
# Exit code is 0 only when every case passes. No files are left in the tree.

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$caseScript = Join-Path $PSScriptRoot 'case.ps1'
$pwsh = (Get-Process -Id $PID).Path
if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) {
    Write-Output "FAIL shell: pwsh executable not found at $pwsh"
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'shell\history.ps1') -PathType Leaf)) {
    Write-Output "FAIL shell: shell\history.ps1 not found under $repoRoot"
    exit 1
}

$cases = @(
    [pscustomobject]@{
        Name = 'restored-key'
        HistoryKey = '4101'
        Pane = '9001'
        UseStateEnv = $false
        SeedHistory = $true
        PaneItems = @('pane-4101-one', 'pane-4101-two')
        ExpectedItems = @('pane-4101-one', 'pane-4101-two')
        ExpectHistoryDir = $true
    },
    [pscustomobject]@{
        Name = 'pane-fallback'
        HistoryKey = $null
        Pane = '4102'
        UseStateEnv = $true
        SeedHistory = $true
        PaneItems = @('pane-4102-one', 'pane-4102-two')
        ExpectedItems = @('pane-4102-one', 'pane-4102-two')
        ExpectHistoryDir = $true
    },
    [pscustomobject]@{
        Name = 'no-key'
        HistoryKey = $null
        Pane = $null
        UseStateEnv = $true
        SeedHistory = $false
        PaneItems = @()
        ExpectedItems = @('global-one', 'global-two')
        ExpectHistoryDir = $false
    },
    [pscustomobject]@{
        # The hook must create <state dir>\history even before the pane has a
        # saved command. No pane file is seeded for this case.
        Name = 'creates-directory'
        HistoryKey = '4103'
        Pane = $null
        UseStateEnv = $true
        SeedHistory = $false
        PaneItems = @()
        ExpectedItems = @()
        ExpectHistoryDir = $true
    }
)

$savedEnv = @{}
foreach ($name in @('APPDATA', 'USERPROFILE', 'HOME', 'WEZTERM_SESSION_HISTORY_KEY', 'WEZTERM_PANE', 'WEZTERM_SESSION_STATE_DIR')) {
    $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$script:failures = 0

function Restore-TestEnvironment {
    foreach ($name in $savedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process')
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-HistoryCase {
    param([pscustomobject]$Case)

    $root = Join-Path $env:TEMP ('wezterm-history-shell-' + [guid]::NewGuid().ToString('N'))
    try {
        $appdata = Join-Path $root 'appdata'
        $homeDir = Join-Path $root 'home'
        $stateDir = Join-Path $root 'state'
        $globalDir = Join-Path $appdata 'Microsoft\Windows\PowerShell\PSReadLine'
        New-Item -ItemType Directory -Force -Path $globalDir, $homeDir | Out-Null

        $globalPath = Join-Path $globalDir 'ConsoleHost_history.txt'
        Set-Content -LiteralPath $globalPath -Value @('global-one', 'global-two')

        $defaultStateDir = Join-Path $appdata 'wezterm-session-layer'
        $expectedHistoryDir = if ($Case.UseStateEnv) {
            Join-Path $stateDir 'history'
        } else {
            Join-Path $defaultStateDir 'history'
        }
        $expectedPath = if ($Case.HistoryKey) {
            Join-Path $expectedHistoryDir ($Case.HistoryKey + '.txt')
        } elseif ($Case.Pane) {
            Join-Path $expectedHistoryDir ($Case.Pane + '.txt')
        } else {
            $globalPath
        }

        if ($Case.SeedHistory) {
            New-Item -ItemType Directory -Force -Path $expectedHistoryDir | Out-Null
            Set-Content -LiteralPath $expectedPath -Value $Case.PaneItems
        }

        $env:APPDATA = $appdata
        $env:USERPROFILE = $homeDir
        $env:HOME = $homeDir
        if ($Case.UseStateEnv) {
            $env:WEZTERM_SESSION_STATE_DIR = $stateDir
        } else {
            Remove-Item Env:WEZTERM_SESSION_STATE_DIR -ErrorAction SilentlyContinue
        }
        if ($Case.HistoryKey) {
            $env:WEZTERM_SESSION_HISTORY_KEY = $Case.HistoryKey
        } else {
            Remove-Item Env:WEZTERM_SESSION_HISTORY_KEY -ErrorAction SilentlyContinue
        }
        if ($Case.Pane) {
            $env:WEZTERM_PANE = $Case.Pane
        } else {
            Remove-Item Env:WEZTERM_PANE -ErrorAction SilentlyContinue
        }

        $raw = & $pwsh -NoProfile -NoLogo -NonInteractive -File $caseScript -RepoRoot $repoRoot -Case $Case.Name 2>&1
        $exitCode = $LASTEXITCODE
        $text = (@($raw) | ForEach-Object { [string]$_ }) -join "`n"
        if ($exitCode -ne 0) {
            throw "child exited $exitCode; output: $($text -replace '\r?\n', ' | ')"
        }

        $result = $text | ConvertFrom-Json
        if ($null -eq $result) {
            throw 'child produced no JSON result'
        }

        Assert-True ($result.HistorySavePath -eq $expectedPath) `
            "HistorySavePath was '$($result.HistorySavePath)', expected '$expectedPath'"

        $actualItems = @($result.Items)
        Assert-True ($actualItems.Count -eq $Case.ExpectedItems.Count) `
            "got $($actualItems.Count) history item(s), expected $($Case.ExpectedItems.Count): [$($actualItems -join ' | ')]"
        for ($i = 0; $i -lt $Case.ExpectedItems.Count; $i++) {
            Assert-True ($actualItems[$i] -eq $Case.ExpectedItems[$i]) `
                "history item $i was '$($actualItems[$i])', expected '$($Case.ExpectedItems[$i])'"
        }

        $globalAfter = @(Get-Content -LiteralPath $globalPath)
        Assert-True ($globalAfter.Count -eq 2 -and $globalAfter[0] -eq 'global-one' -and $globalAfter[1] -eq 'global-two') `
            "global history file changed: [$($globalAfter -join ' | ')]"

        if ($Case.ExpectHistoryDir) {
            Assert-True ($result.HistoryDirectoryExists -eq $true) `
                "history directory '$($result.HistoryDirectory)' was not created"
            Assert-True (Test-Path -LiteralPath $expectedHistoryDir -PathType Container) `
                "history directory '$expectedHistoryDir' is missing after the child exited"
        }

        $esc = [char]27
        Assert-True ($result.Prompt -like "*$esc]7;file://*") `
            'prompt did not emit the OSC 7 sequence'
        Assert-True ($result.Prompt -match 'PS .*>' ) `
            "prompt did not keep the 'PS <path>>' shape: '$($result.Prompt)'"

        Write-Output ("PASS {0}: path={1}; items=[{2}]; global unchanged" -f `
                $Case.Name, $result.HistorySavePath, ($actualItems -join ' | '))
    } catch {
        $script:failures++
        Write-Output ("FAIL {0}: {1}" -f $Case.Name, $_.Exception.Message)
    } finally {
        Restore-TestEnvironment
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    foreach ($case in $cases) {
        Invoke-HistoryCase -Case $case
    }
} finally {
    Restore-TestEnvironment
}

if ($script:failures -gt 0) {
    Write-Output ("FAIL shell: {0} of {1} case(s) failed" -f $script:failures, $cases.Count)
    exit 1
}
Write-Output ("PASS shell: {0} cases" -f $cases.Count)
exit 0
