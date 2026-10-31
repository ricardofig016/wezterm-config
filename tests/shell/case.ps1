[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory)]
    [string]$Case
)

# One controlled shell for tests\shell\run.ps1. The runner sets the environment
# before launching this process: a temporary USERPROFILE/APPDATA so PSReadLine's
# global history file is never the real one, plus the WEZTERM_* variables for
# the case under test.
$ErrorActionPreference = 'Stop'

. (Join-Path (Join-Path $RepoRoot 'shell') 'history.ps1')

# A real shell has PSReadLine loaded by the time it asks for the first prompt.
# Importing here also makes the type literal below resolvable in the no-key
# case, where the hook correctly does nothing.
Import-Module PSReadLine -ErrorAction Stop

# PSReadLine reads its history file in DelayedOneTimeInitialize, which
# PSConsoleReadLine.ReadLine calls on the first prompt. -NonInteractive has no
# prompt, so invoke that same private step. This is test-only: the hook uses
# only public PSReadLine commands.
$psrl = [Microsoft.PowerShell.PSConsoleReadLine]
$flags = [System.Reflection.BindingFlags]
$singleton = $psrl.GetField('_singleton', $flags::NonPublic -bor $flags::Static).GetValue($null)
if ($null -eq $singleton) {
    throw 'PSReadLine did not create its singleton'
}
$initialize = $psrl.GetMethod('DelayedOneTimeInitialize', $flags::NonPublic -bor $flags::Instance)
if ($null -eq $initialize) {
    throw 'PSReadLine has no DelayedOneTimeInitialize method'
}
$initialize.Invoke($singleton, @()) | Out-Null

$option = Get-PSReadLineOption
$items = @([Microsoft.PowerShell.PSConsoleReadLine]::GetHistoryItems() |
    ForEach-Object { $_.CommandLine })
$promptText = prompt

$historyDir = Split-Path -Parent $option.HistorySavePath

[pscustomobject]@{
    Case = $Case
    HistorySavePath = $option.HistorySavePath
    HistoryDirectory = $historyDir
    HistoryDirectoryExists = Test-Path -LiteralPath $historyDir -PathType Container
    Items = $items
    Prompt = $promptText
} | ConvertTo-Json -Compress -Depth 4
