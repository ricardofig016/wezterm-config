[CmdletBinding()]
param(
    # Headless logic suite. Runs by default when no switch is given.
    [switch]$Unit = $true,
    # Real-GUI integration suite against wezterm-gui.exe.
    [switch]$Integration
)

# An explicit switch selects the suites for that invocation, so -Unit,
# -Integration and "-Unit -Integration" all do what they say. With neither
# switch the historical default still runs the unit suite only.
#
# -Integration never looks at the window: every scenario writes its own JSON
# report from inside the app, the runner reads that file, and the runner exits
# non-zero on a failed scenario, a timeout, a missing report, or a stray
# wezterm-gui process that this run created.
$ErrorActionPreference = 'Stop'

$testsDir = $PSScriptRoot

$unitBound = $PSBoundParameters.ContainsKey('Unit')
$integrationBound = $PSBoundParameters.ContainsKey('Integration')
if (-not $unitBound -and -not $integrationBound) {
    $runUnit = $true
    $runIntegration = $false
} else {
    $runUnit = $unitBound -and [bool]$Unit
    $runIntegration = $integrationBound -and [bool]$Integration
}
if (-not $runUnit -and -not $runIntegration) {
    Write-Output 'FAIL unit: no suite selected'
    exit 1
}

$script:suiteExit = 1
$script:scenarioPassed = $false

# ---------------------------------------------------------------------------
# Unit suite: unchanged headless harness (tests\harness\unit.lua).
# ---------------------------------------------------------------------------
function Invoke-UnitSuite {
    $harness = Join-Path $testsDir 'harness\unit.lua'
    $report = Join-Path $testsDir '.report.json'

    $wezterm = Get-Command wezterm.exe -ErrorAction SilentlyContinue
    if (-not $wezterm) {
        Write-Output 'FAIL unit: wezterm.exe was not found on PATH'
        $script:suiteExit = 1
        return
    }

    # The report is the only pass signal. Remove any old one first so a failed
    # config load can never inherit a stale green result.
    if (Test-Path -LiteralPath $report) {
        Remove-Item -LiteralPath $report -Force
    }

    $showKeysExit = $null
    try {
        & $wezterm.Source --config-file $harness show-keys --lua 2>&1 | Out-Null
        $showKeysExit = $LASTEXITCODE
    } catch {
        $showKeysExit = "launch error: $($_.Exception.Message)"
    }

    # show-keys exits 0 even when the config fails to load, so its exit code is
    # diagnostic only. A missing report is a failure.
    if (-not (Test-Path -LiteralPath $report)) {
        Write-Output "FAIL unit: no report at $report (show-keys exit: $showKeysExit)"
        $script:suiteExit = 1
        return
    }

    try {
        $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    } catch {
        Write-Output "FAIL unit: report is not valid JSON: $($_.Exception.Message)"
        $script:suiteExit = 1
        return
    }

    $failures = @($result.failures)
    $failed = [int]$result.failed
    $passed = [int]$result.passed

    foreach ($failure in $failures) {
        $spec = if ($failure.spec) { [string]$failure.spec } else { '<unknown spec>' }
        $test = if ($failure.test) { [string]$failure.test } else { '<unknown test>' }
        $message = if ($failure.message) { [string]$failure.message } else { '<no message>' }
        $message = $message -replace '\r?\n', ' '
        Write-Output ("FAIL {0} :: {1} :: {2}" -f $spec, $test, $message)
    }

    if ($result.ok -eq $true -and $failed -eq 0 -and $failures.Count -eq 0) {
        Write-Output ("PASS unit: {0} passed, 0 failed" -f $passed)
        $script:suiteExit = 0
        return
    }

    if ($failures.Count -eq 0) {
        Write-Output ("FAIL unit: report ok={0}, failed={1}" -f $result.ok, $failed)
    }
    Write-Output ("FAIL unit: {0} passed, {1} failed" -f $passed, $failed)
    $script:suiteExit = 1
}

# ---------------------------------------------------------------------------
# Integration suite: real GUI, isolated state, in-app JSON report.
# ---------------------------------------------------------------------------
function Get-WeztermGuiPids {
    @(Get-Process -Name 'wezterm-gui' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Id)
}

# Every process descending from the launched GUI, so a child wezterm-gui pid can
# be attributed to this run instead of being mistaken for the user's window.
function Get-WeztermGuiDescendants {
    param([int]$RootPid)

    $childrenByParent = @{}
    foreach ($process in @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue -Property ProcessId, ParentProcessId)) {
        $parent = [int]$process.ParentProcessId
        if (-not $childrenByParent.ContainsKey($parent)) {
            $childrenByParent[$parent] = New-Object System.Collections.Generic.List[int]
        }
        $childrenByParent[$parent].Add([int]$process.ProcessId)
    }

    $seen = @{}
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootPid)
    $descendants = New-Object System.Collections.Generic.List[int]
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $childrenByParent.ContainsKey($current)) {
            continue
        }
        foreach ($child in $childrenByParent[$current]) {
            if ($seen.ContainsKey($child)) {
                continue
            }
            $seen[$child] = $true
            $descendants.Add($child)
            $queue.Enqueue($child)
        }
    }
    return , $descendants.ToArray()
}

# Record the wezterm-gui pids before the launch, then report which new pids are
# owned by this launch: the started pid itself plus its descendants. A new pid
# that is neither (for example the user opening a terminal during the run) is
# left alone and never killed.
function Get-CreatedGuiPids {
    param(
        [int[]]$Before,
        [int]$StartedPid
    )

    $after = @(Get-WeztermGuiPids)
    $new = @($after | Where-Object { $Before -notcontains $_ })
    $startedAlive = $null -ne (Get-Process -Id $StartedPid -ErrorAction SilentlyContinue)
    $descendants = @()
    if ($startedAlive) {
        $descendants = @(Get-WeztermGuiDescendants -RootPid $StartedPid)
    }
    $owned = @($new | Where-Object { $_ -eq $StartedPid -or $descendants -contains $_ })
    if ($startedAlive -and $owned -notcontains $StartedPid) {
        $owned = @($owned + $StartedPid)
    }

    [pscustomobject]@{
        New = $new
        Owned = $owned
        StartedAlive = $startedAlive
    }
}

# Kill only by exact pid, only pids absent from the before snapshot. Returns any
# owned pid that is still alive afterwards, which the caller reports as stray.
function Stop-OwnedGuiProcesses {
    param(
        [int[]]$Pids,
        [int[]]$Preexisting
    )

    foreach ($processId in $Pids) {
        if ($Preexisting -contains $processId) {
            continue
        }
        if ($null -eq (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
            continue
        }
        try {
            Stop-Process -Id $processId -Force -ErrorAction Stop
        } catch {
            # It may have exited between the check and the kill; the wait below
            # decides whether anything is actually left behind.
        }
    }

    $deadline = (Get-Date).AddSeconds(5)
    do {
        $alive = @($Pids | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
        if ($alive.Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)

    if ($alive.Count -gt 0) {
        foreach ($processId in $alive) {
            if ($Preexisting -contains $processId) {
                continue
            }
            try {
                Stop-Process -Id $processId -Force -ErrorAction Stop
            } catch {
            }
        }
        Start-Sleep -Milliseconds 300
        $alive = @($Pids | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
    }

    [pscustomobject]@{
        Alive = $alive
    }
}

function Join-FailureReason {
    param([string]$Current, [string]$Addition)
    if ([string]::IsNullOrEmpty($Current)) {
        return $Addition
    }
    return "$Current; $Addition"
}

# Parse and validate one scenario report. The token ties the file to this
# launch and the pid ties it to the exact process the runner started, so a
# stale or foreign report can never be read as a pass.
function Read-ScenarioReport {
    param(
        [string]$Path,
        [string]$Token,
        [int]$StartedPid
    )

    $outcome = [pscustomobject]@{
        Parsed = $false
        Error = $null
        Ok = $false
        Checks = @()
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        $outcome.Error = "report is unreadable: $($_.Exception.Message)"
        return $outcome
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $outcome.Error = 'report is empty'
        return $outcome
    }
    try {
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $outcome.Error = "report is not valid JSON: $($_.Exception.Message)"
        return $outcome
    }
    if ($null -eq $data -or $data -isnot [pscustomobject]) {
        $outcome.Error = 'report is not a JSON object'
        return $outcome
    }

    $names = @($data.PSObject.Properties.Name)
    if ($names -notcontains 'ok' -or $data.ok -isnot [bool]) {
        $outcome.Error = 'report has no boolean "ok" field'
        return $outcome
    }
    if ($names -notcontains 'checks') {
        $outcome.Error = 'report has no "checks" array'
        return $outcome
    }
    if ($names -notcontains 'token') {
        $outcome.Error = 'report has no "token", so it cannot be tied to this launch'
        return $outcome
    }
    if ([string]$data.token -ne $Token) {
        $outcome.Error = "report token does not match this launch (got '$($data.token)')"
        return $outcome
    }
    if ($names -notcontains 'pid') {
        $outcome.Error = 'report has no "pid", so it cannot be tied to this process'
        return $outcome
    }
    $reportedPid = 0
    try {
        $reportedPid = [int]$data.pid
    } catch {
        $outcome.Error = 'report "pid" is not an integer'
        return $outcome
    }
    if ($reportedPid -ne $StartedPid) {
        $outcome.Error = "report pid $reportedPid is not the launched pid $StartedPid"
        return $outcome
    }

    $checks = @()
    foreach ($entry in @($data.checks)) {
        if ($null -eq $entry) {
            $outcome.Error = 'report contains a null check'
            return $outcome
        }
        $entryNames = @($entry.PSObject.Properties.Name)
        if ($entryNames -notcontains 'name' -or $entryNames -notcontains 'ok') {
            $outcome.Error = 'a report check is missing "name" or "ok"'
            return $outcome
        }
        if ($entry.ok -isnot [bool]) {
            $outcome.Error = "report check '$($entry.name)' has a non-boolean ok field"
            return $outcome
        }
        $detail = ''
        if ($entryNames -contains 'detail' -and $null -ne $entry.detail) {
            $detail = [string]$entry.detail
        }
        $checks += [pscustomobject]@{
            Name = [string]$entry.name
            Ok = [bool]$entry.ok
            Detail = $detail
        }
    }

    $outcome.Parsed = $true
    $outcome.Ok = [bool]$data.ok
    $outcome.Checks = $checks
    return $outcome
}

# Launch one scenario, wait for its report under a hard timeout, kill only the
# pids this launch created, and print exactly one PASS or FAIL line for it.
function Invoke-IntegrationScenario {
    param(
        [string]$Name,
        [string]$ScenarioFile,
        [string]$RunRoot,
        [int]$TimeoutSeconds,
        [string]$GuiPath
    )

    $script:scenarioPassed = $false

    $scenarioDir = Join-Path $RunRoot $Name
    $stateDir = Join-Path $scenarioDir 'state'
    $reportPath = Join-Path $scenarioDir '.report.json'
    $stdoutPath = Join-Path $scenarioDir 'gui.stdout.log'
    $stderrPath = Join-Path $scenarioDir 'gui.stderr.log'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

    $token = [guid]::NewGuid().ToString('N')
    $before = @(Get-WeztermGuiPids)
    $started = $null
    $owned = @()
    $reportOutcome = $null
    $failureReason = $null
    $processOk = $false

    $savedState = $env:WEZTERM_SESSION_STATE_DIR
    $savedReport = $env:WEZTERM_SESSION_TEST_REPORT
    $savedToken = $env:WEZTERM_SESSION_TEST_TOKEN

    try {
        $env:WEZTERM_SESSION_STATE_DIR = $stateDir
        $env:WEZTERM_SESSION_TEST_REPORT = $reportPath
        $env:WEZTERM_SESSION_TEST_TOKEN = $token

        try {
            $started = Start-Process -FilePath $GuiPath `
                -ArgumentList @('--config-file', ('"' + $ScenarioFile + '"')) `
                -PassThru `
                -RedirectStandardOutput $stdoutPath `
                -RedirectStandardError $stderrPath
        } catch {
            $failureReason = "launch failed: $($_.Exception.Message)"
        }

        if ($null -ne $started) {
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            $lastReportError = $null
            while ((Get-Date) -lt $deadline) {
                if (Test-Path -LiteralPath $reportPath) {
                    $reportOutcome = Read-ScenarioReport -Path $reportPath -Token $token -StartedPid $started.Id
                    if ($reportOutcome.Parsed) {
                        break
                    }
                    $lastReportError = $reportOutcome.Error
                }
                if ($null -eq (Get-Process -Id $started.Id -ErrorAction SilentlyContinue)) {
                    if ($null -eq $failureReason) {
                        if ($null -ne $reportOutcome -and -not $reportOutcome.Parsed) {
                            $failureReason = "process $($started.Id) exited; report could not be used: $($reportOutcome.Error)"
                        } else {
                            $failureReason = "process $($started.Id) exited before writing a report"
                        }
                    }
                    break
                }
                Start-Sleep -Milliseconds 100
            }

            if ($null -eq $failureReason -and ($null -eq $reportOutcome -or -not $reportOutcome.Parsed)) {
                if ($null -ne $reportOutcome) {
                    $failureReason = "report could not be used: $($reportOutcome.Error)"
                } else {
                    $failureReason = "timed out after ${TimeoutSeconds}s waiting for $reportPath"
                    if ($lastReportError) {
                        $failureReason = Join-FailureReason $failureReason "last report error: $lastReportError"
                    }
                }
            }

            # Snapshot while the GUI may still be alive so extra gui pids can be
            # attributed to this launch before anything is killed.
            $created = Get-CreatedGuiPids -Before $before -StartedPid $started.Id
            $owned = @($created.Owned)
            if (-not $created.StartedAlive -and $null -eq $failureReason) {
                $failureReason = "process $($started.Id) exited before the runner killed it"
            }

            $stopped = Stop-OwnedGuiProcesses -Pids $owned -Preexisting $before
            $aliveAfter = @($stopped.Alive)
            if ($aliveAfter.Count -gt 0) {
                $failureReason = Join-FailureReason $failureReason 'left stray process(es) after kill: ' + ($aliveAfter -join ',')
            }
            $processOk = $created.StartedAlive -and $aliveAfter.Count -eq 0
        }
    } finally {
        # A crash between launch and the normal kill must not leave a GUI behind.
        if ($null -ne $started -and -not $processOk) {
            $createdNow = Get-CreatedGuiPids -Before $before -StartedPid $started.Id
            if (@($createdNow.Owned).Count -gt 0) {
                $null = Stop-OwnedGuiProcesses -Pids @($createdNow.Owned) -Preexisting $before
            }
        }
        $env:WEZTERM_SESSION_STATE_DIR = $savedState
        $env:WEZTERM_SESSION_TEST_REPORT = $savedReport
        $env:WEZTERM_SESSION_TEST_TOKEN = $savedToken
    }

    $failingChecks = @()
    if ($null -ne $reportOutcome -and $reportOutcome.Parsed) {
        if (@($reportOutcome.Checks).Count -eq 0) {
            $failureReason = Join-FailureReason $failureReason 'report contains no checks'
        }
        $failingChecks = @($reportOutcome.Checks | Where-Object { $_.Ok -ne $true })
        if (-not $reportOutcome.Ok) {
            $failureReason = Join-FailureReason $failureReason 'report ok=false'
        }
        if ($failingChecks.Count -gt 0) {
            $failureReason = Join-FailureReason $failureReason (
                '{0} of {1} check(s) failed' -f $failingChecks.Count, @($reportOutcome.Checks).Count)
        }
    } elseif ($null -eq $failureReason) {
        $failureReason = 'no usable report'
    }

    $passed = $processOk -and $null -eq $failureReason -and $null -ne $reportOutcome `
        -and $reportOutcome.Parsed -and $reportOutcome.Ok -and $failingChecks.Count -eq 0

    if ($passed) {
        Write-Output ('PASS {0}: {1} checks, process {2} killed and confirmed gone' -f `
                $Name, @($reportOutcome.Checks).Count, $started.Id)
        Remove-Item -LiteralPath $scenarioDir -Recurse -Force -ErrorAction SilentlyContinue
        $script:scenarioPassed = $true
        return
    }

    if ([string]::IsNullOrEmpty($failureReason)) {
        $failureReason = 'unknown failure'
    }
    Write-Output ('FAIL {0}: {1} (artifacts: {2})' -f $Name, $failureReason, $scenarioDir)
    foreach ($check in $failingChecks) {
        $detail = ($check.Detail -replace '\r?\n', ' ')
        Write-Output ('  check {0} :: {1}' -f $check.Name, $detail)
    }
    $script:scenarioPassed = $false
}

function Invoke-IntegrationSuite {
    $script:suiteExit = 1

    $guiPath = 'C:\Program Files\WezTerm\wezterm-gui.exe'
    if (-not (Test-Path -LiteralPath $guiPath -PathType Leaf)) {
        Write-Output "FAIL integration: wezterm-gui.exe not found at $guiPath"
        return
    }

    $scenariosDir = Join-Path $testsDir 'scenarios'
    if (-not (Test-Path -LiteralPath $scenariosDir -PathType Container)) {
        Write-Output "FAIL integration: scenarios directory not found at $scenariosDir"
        return
    }

    $scenarioFiles = @(Get-ChildItem -LiteralPath $scenariosDir -Filter '*.lua' -File -ErrorAction Stop |
        Sort-Object Name)
    if ($scenarioFiles.Count -eq 0) {
        Write-Output "FAIL integration: no scenario files in $scenariosDir"
        return
    }

    $runRoot = Join-Path $env:TEMP ('wezterm-session-layer-it-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

    $timeoutSeconds = 25
    $failed = 0
    try {
        foreach ($scenarioFile in $scenarioFiles) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($scenarioFile.Name)
            Invoke-IntegrationScenario -Name $name -ScenarioFile $scenarioFile.FullName `
                -RunRoot $runRoot -TimeoutSeconds $timeoutSeconds -GuiPath $guiPath
            if (-not $script:scenarioPassed) {
                $failed++
            }
        }
    } finally {
        if ($failed -eq 0 -and (Test-Path -LiteralPath $runRoot)) {
            Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($failed -gt 0) {
        Write-Output ("FAIL integration: {0} of {1} scenario(s) failed; artifacts kept at {2}" -f `
                $failed, $scenarioFiles.Count, $runRoot)
        $script:suiteExit = 1
        return
    }
    $script:suiteExit = 0
}

$failedSuites = $false
if ($runUnit) {
    Invoke-UnitSuite
    if ($script:suiteExit -ne 0) {
        $failedSuites = $true
    }
}
if ($runIntegration) {
    Invoke-IntegrationSuite
    if ($script:suiteExit -ne 0) {
        $failedSuites = $true
    }
}

if ($failedSuites) {
    exit 1
}
exit 0
