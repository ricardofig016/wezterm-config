[CmdletBinding()]
param(
    # Headless logic suite. Runs by default when no switch is given.
    [switch]$Unit = $true,
    # Headless shell-history suite (tests\shell\run.ps1).
    [switch]$Shell,
    # Real-GUI integration suite against wezterm-gui.exe.
    [switch]$Integration,
    # Unit plus shell plus integration.
    [switch]$All,
    # Parallel integration scenarios. Each one already owns an isolated state
    # directory, so the pool is safe; pid ownership is per launch.
    [int]$Jobs = 4
)

# An explicit switch selects the suites for that invocation, so -Unit,
# -Shell, -Integration and any combination do what they say. -All selects all
# three. With no switch at all the historical default still runs the unit suite
# only.
#
# -Integration never looks at the window: every scenario writes its own JSON
# report from inside the app, the runner reads that file, and the runner exits
# non-zero on a failed scenario, a timeout, a missing report, or a stray
# wezterm-gui process that this run created.
$ErrorActionPreference = 'Stop'

$testsDir = $PSScriptRoot

$unitBound = $PSBoundParameters.ContainsKey('Unit')
$shellBound = $PSBoundParameters.ContainsKey('Shell')
$integrationBound = $PSBoundParameters.ContainsKey('Integration')
$allBound = $PSBoundParameters.ContainsKey('All')
if ($allBound -and [bool]$All) {
    $runUnit = $true
    $runShell = $true
    $runIntegration = $true
} elseif (-not $unitBound -and -not $shellBound -and -not $integrationBound) {
    $runUnit = $true
    $runShell = $false
    $runIntegration = $false
} else {
    $runUnit = $unitBound -and [bool]$Unit
    $runShell = $shellBound -and [bool]$Shell
    $runIntegration = $integrationBound -and [bool]$Integration
}
if (-not $runUnit -and -not $runShell -and -not $runIntegration) {
    Write-Output 'FAIL unit: no suite selected'
    exit 1
}

if ($Jobs -lt 1) {
    $Jobs = 1
} elseif ($Jobs -gt 16) {
    $Jobs = 16
}

# Child runner processes are part of one logical run: they never take the lock
# and never spawn another pool of suites.
$isRunnerChild = $env:WEZTERM_SESSION_RUNNER_CHILD -eq '1'
$script:runTimer = [System.Diagnostics.Stopwatch]::StartNew()

$script:suiteExit = 1
$script:scenarioPassed = $false

# ---------------------------------------------------------------------------
# Unit suite: headless harness with a per-run report under %TEMP%.
# ---------------------------------------------------------------------------
function Invoke-UnitSuite {
    $harness = Join-Path $testsDir 'harness\unit.lua'

    $wezterm = Get-Command wezterm.exe -ErrorAction SilentlyContinue
    if (-not $wezterm) {
        Write-Output 'FAIL unit: wezterm.exe was not found on PATH'
        $script:suiteExit = 1
        return
    }

    # Every invocation gets its own report under %TEMP%. The harness writes to
    # exactly the path passed here, so two runs can never read each other's
    # verdict and the repository accumulates no report files.
    $unitReportDir = Join-Path $env:TEMP ('wezterm-session-unit-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $unitReportDir -Force | Out-Null
    $report = Join-Path $unitReportDir '.report.json'
    $savedReport = $env:WEZTERM_SESSION_UNIT_REPORT
    $unitTimer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        if (Test-Path -LiteralPath $report) {
            Remove-Item -LiteralPath $report -Force
        }
        $env:WEZTERM_SESSION_UNIT_REPORT = $report

        $showKeysExit = $null
        try {
            & $wezterm.Source --config-file $harness show-keys --lua 2>&1 | Out-Null
            $showKeysExit = $LASTEXITCODE
        } catch {
            $showKeysExit = "launch error: $($_.Exception.Message)"
        }

        # show-keys exits 0 even when the config fails to load, so its exit code
        # is diagnostic only. A missing report is a failure.
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
    } finally {
        $env:WEZTERM_SESSION_UNIT_REPORT = $savedReport
        Remove-Item -LiteralPath $unitReportDir -Recurse -Force -ErrorAction SilentlyContinue
        $unitTimer.Stop()
        Write-Output ("TIME unit: {0:N1}s" -f $unitTimer.Elapsed.TotalSeconds)
    }
}

# ---------------------------------------------------------------------------
# Shell suite: tests\shell\run.ps1, a headless history-hook proof.
# ---------------------------------------------------------------------------
function Invoke-ShellSuite {
    $script:suiteExit = 1
    $shellTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $shellRunner = Join-Path $testsDir 'shell\run.ps1'
    if (-not (Test-Path -LiteralPath $shellRunner -PathType Leaf)) {
        Write-Output "FAIL shell: tests\shell\run.ps1 not found at $shellRunner"
        $shellTimer.Stop()
        Write-Output ("TIME shell: {0:N1}s" -f $shellTimer.Elapsed.TotalSeconds)
        return
    }

    $pwsh = (Get-Process -Id $PID).Path
    try {
        $lines = @(& $pwsh -NoProfile -NoLogo -NonInteractive -File $shellRunner 2>&1 |
            ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    } catch {
        Write-Output "FAIL shell: could not run $shellRunner : $($_.Exception.Message)"
        $shellTimer.Stop()
        Write-Output ("TIME shell: {0:N1}s" -f $shellTimer.Elapsed.TotalSeconds)
        return
    }

    $sawSummary = $false
    foreach ($line in $lines) {
        if ($line -match '^(PASS|FAIL) shell:') {
            $sawSummary = $true
        }
        Write-Output $line
    }
    if (-not $sawSummary) {
        if ($code -eq 0) {
            Write-Output 'PASS shell: 0 cases'
        } else {
            Write-Output "FAIL shell: tests\shell\run.ps1 exited $code"
        }
    }
    $script:suiteExit = if ($code -eq 0) { 0 } else { 1 }
    $shellTimer.Stop()
    Write-Output ("TIME shell: {0:N1}s" -f $shellTimer.Elapsed.TotalSeconds)
}

# ---------------------------------------------------------------------------
# Integration suite: real GUI, isolated state, in-app JSON report.
# ---------------------------------------------------------------------------
# Every process descending from the launched GUI, so a child wezterm-gui pid can
# be attributed to this launch instead of being mistaken for another scenario's
# window.
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

# Owning a pid is per launch: the started wezterm-gui plus its live
# wezterm-gui descendants. There is deliberately no before/after snapshot, so
# two scenarios running in parallel can never claim each other's processes.
function Get-OwnedGuiPids {
    param([int]$StartedPid)

    $owned = @()
    if ($null -eq (Get-Process -Id $StartedPid -ErrorAction SilentlyContinue)) {
        return $owned
    }
    $owned += $StartedPid
    foreach ($descendant in @(Get-WeztermGuiDescendants -RootPid $StartedPid)) {
        $process = Get-Process -Id $descendant -ErrorAction SilentlyContinue
        if ($null -ne $process -and $process.ProcessName -eq 'wezterm-gui') {
            $owned += $descendant
        }
    }
    return @($owned | Sort-Object -Unique)
}

# Kill only the exact pids this launch owns, then confirm they are gone.
function Stop-OwnedGuiProcesses {
    param([int[]]$Pids)

    foreach ($processId in $Pids) {
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

            # Ownership is computed from the started pid and its descendants
            # while the launch is still alive. A .owned-pids declaration is
            # accepted only for a pid already in that set, so a scenario can
            # never make this launch kill another scenario's process.
            $owned = @(Get-OwnedGuiPids -StartedPid $started.Id)
            $startedAlive = $null -ne (Get-Process -Id $started.Id -ErrorAction SilentlyContinue)

            $ownedPidsPath = Join-Path $scenarioDir '.owned-pids'
            if (Test-Path -LiteralPath $ownedPidsPath) {
                foreach ($raw in @(Get-Content -LiteralPath $ownedPidsPath -ErrorAction SilentlyContinue)) {
                    $declaredPid = 0
                    if ([int]::TryParse(([string]$raw).Trim(), [ref]$declaredPid)) {
                        if ($declaredPid -gt 0 -and $owned -notcontains $declaredPid) {
                            # A scenario that already killed its peer leaves a
                            # dead pid here; that is fine. A live pid that is
                            # not a descendant is not this launch's to kill.
                            if ($null -ne (Get-Process -Id $declaredPid -ErrorAction SilentlyContinue)) {
                                $failureReason = Join-FailureReason $failureReason (
                                    "scenario declared pid $declaredPid, but it is not a descendant of this launch")
                            }
                        }
                    }
                }
            }

            if (-not $startedAlive -and $null -eq $failureReason) {
                $failureReason = "process $($started.Id) exited before the runner killed it"
            }

            $stopped = Stop-OwnedGuiProcesses -Pids $owned
            $aliveAfter = @($stopped.Alive)
            if ($aliveAfter.Count -gt 0) {
                $failureReason = Join-FailureReason $failureReason 'left stray process(es) after kill: ' + ($aliveAfter -join ',')
            }
            $processOk = $startedAlive -and $aliveAfter.Count -eq 0
        }
    } finally {
        # A crash between launch and the normal kill must not leave a GUI behind.
        if ($null -ne $started -and -not $processOk) {
            $ownedNow = @(Get-OwnedGuiPids -StartedPid $started.Id)
            if ($ownedNow.Count -gt 0) {
                $null = Stop-OwnedGuiProcesses -Pids $ownedNow
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

    # Scenarios assert on the structured log themselves; printing its tail here
    # makes a red run diagnosable without opening the artifacts by hand.
    $logPath = Join-Path $stateDir 'session.log'
    if (Test-Path -LiteralPath $logPath) {
        $logLines = @(Get-Content -LiteralPath $logPath -Tail 15 -ErrorAction SilentlyContinue)
        if ($logLines.Count -gt 0) {
            Write-Output '  session.log (tail):'
            foreach ($line in $logLines) {
                Write-Output ('    ' + $line)
            }
        }
    }
    $script:scenarioPassed = $false
}

function Invoke-IntegrationSuite {
    $script:suiteExit = 1
    $suiteTimer = [System.Diagnostics.Stopwatch]::StartNew()

    # -All passes -Jobs to this child through the environment.
    $requestedJobs = 0
    if ([int]::TryParse([string]$env:WEZTERM_SESSION_RUNNER_JOBS, [ref]$requestedJobs) `
            -and $requestedJobs -ge 1) {
        $Jobs = [Math]::Min($requestedJobs, 16)
    }

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

    # Child mode: one scenario, launched by the parallel parent.
    $childScenario = $env:WEZTERM_SESSION_RUNNER_SCENARIO
    if (-not [string]::IsNullOrEmpty($childScenario)) {
        $runRoot = $env:WEZTERM_SESSION_RUNNER_RUNROOT
        if ([string]::IsNullOrEmpty($runRoot)) {
            $runRoot = Split-Path -Parent $childScenario
        }
        $name = [System.IO.Path]::GetFileNameWithoutExtension($childScenario)
        Invoke-IntegrationScenario -Name $name -ScenarioFile $childScenario `
            -RunRoot $runRoot -TimeoutSeconds 40 -GuiPath $guiPath
        $script:suiteExit = if ($script:scenarioPassed) { 0 } else { 1 }
        return
    }

    $runRoot = Join-Path $env:TEMP ('wezterm-session-layer-it-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

    # Test-only timing knobs. The production defaults stay covered by the unit
    # suites; the scenario children and their GUI processes inherit these.
    $timing = [ordered]@{
        WEZTERM_SESSION_SELFCHECK_SETTLE_MS = '2500'
        WEZTERM_SESSION_SAVE_DEBOUNCE_MS    = '400'
        WEZTERM_SESSION_SAVE_TICK_MS        = '150'
    }
    $savedTiming = @{}
    foreach ($key in $timing.Keys) {
        $savedTiming[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $timing[$key], 'Process')
    }
    $savedChild = $env:WEZTERM_SESSION_RUNNER_CHILD
    $savedScenario = $env:WEZTERM_SESSION_RUNNER_SCENARIO
    $savedRunRoot = $env:WEZTERM_SESSION_RUNNER_RUNROOT
    $savedChildJobs = $env:WEZTERM_SESSION_RUNNER_JOBS

    $pwshPath = (Get-Process -Id $PID).Path
    $pending = New-Object System.Collections.Generic.Queue[object]
    foreach ($file in $scenarioFiles) {
        $pending.Enqueue($file)
    }
    $running = @()
    $failed = 0
    $failedNames = @()

    try {
        while ($pending.Count -gt 0 -or $running.Count -gt 0) {
            while ($running.Count -lt $Jobs -and $pending.Count -gt 0) {
                $file = $pending.Dequeue()
                $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                $outPath = Join-Path $runRoot ("$name.stdout.log")
                $errPath = Join-Path $runRoot ("$name.stderr.log")

                $env:WEZTERM_SESSION_RUNNER_CHILD = '1'
                $env:WEZTERM_SESSION_RUNNER_SCENARIO = $file.FullName
                $env:WEZTERM_SESSION_RUNNER_RUNROOT = $runRoot
                $env:WEZTERM_SESSION_RUNNER_JOBS = [string]$Jobs

                try {
                    $process = Start-Process -FilePath $pwshPath `
                        -ArgumentList @('-NoProfile', '-File', $PSCommandPath, '-Integration') `
                        -PassThru `
                        -RedirectStandardOutput $outPath `
                        -RedirectStandardError $errPath
                    $running += [pscustomobject]@{
                        Process = $process
                        Name = $name
                        Out = $outPath
                        Err = $errPath
                        Timer = [System.Diagnostics.Stopwatch]::StartNew()
                    }
                } catch {
                    Write-Output ("FAIL {0}: could not start a scenario runner: {1}" -f `
                            $name, $_.Exception.Message)
                    $failed++
                    $failedNames += $name
                }
            }

            $finished = @()
            while ($finished.Count -eq 0 -and $running.Count -gt 0) {
                $finished = @($running | Where-Object { $_.Process.HasExited })
                if ($finished.Count -eq 0) {
                    Start-Sleep -Milliseconds 150
                }
            }

            foreach ($item in $finished) {
                $item.Timer.Stop()
                foreach ($line in @(Get-Content -LiteralPath $item.Out -ErrorAction SilentlyContinue)) {
                    Write-Output ([string]$line)
                }
                $errText = Get-Content -LiteralPath $item.Err -Raw -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($errText)) {
                    foreach ($line in ($errText -split '\r?\n')) {
                        if ($line -ne '') {
                            Write-Output ('  stderr: ' + $line)
                        }
                    }
                }
                if ($item.Process.ExitCode -ne 0) {
                    $failed++
                    $failedNames += $item.Name
                }
                Write-Output ("TIME {0}: {1:N1}s" -f $item.Name, $item.Timer.Elapsed.TotalSeconds)
                $running = @($running | Where-Object { $_.Process.Id -ne $item.Process.Id })
            }
        }
    } finally {
        foreach ($key in $timing.Keys) {
            [Environment]::SetEnvironmentVariable($key, $savedTiming[$key], 'Process')
        }
        $env:WEZTERM_SESSION_RUNNER_CHILD = $savedChild
        $env:WEZTERM_SESSION_RUNNER_SCENARIO = $savedScenario
        $env:WEZTERM_SESSION_RUNNER_RUNROOT = $savedRunRoot
        $env:WEZTERM_SESSION_RUNNER_JOBS = $savedChildJobs
        if ($failed -eq 0 -and (Test-Path -LiteralPath $runRoot)) {
            Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $suiteTimer.Stop()
    if ($failed -gt 0) {
        Write-Output ("FAIL integration: {0} of {1} scenario(s) failed ({2}); artifacts kept at {3}" -f `
                $failed, $scenarioFiles.Count, ($failedNames -join ','), $runRoot)
        Write-Output ("TIME integration: {0:N1}s" -f $suiteTimer.Elapsed.TotalSeconds)
        $script:suiteExit = 1
        return
    }
    Write-Output ("TIME integration: {0:N1}s" -f $suiteTimer.Elapsed.TotalSeconds)
    $script:suiteExit = 0
}

# ---------------------------------------------------------------------------
# Concurrent-run guard: one runner per repository.
#
# The lock is keyed to the resolved repository path and kept under %TEMP%. A
# second run that finds a live owner refuses with the owner's pid, start time
# and suite selection instead of interleaving; a lock whose owner pid is gone is
# stale and removed.
#
# The damaged-lock branches (empty or truncated JSON, live or dead owner) are
# verified manually with hand-written lock files. There is no automated test for
# them; do not assume coverage from the unit or integration suites.
# ---------------------------------------------------------------------------
$repoRoot = Split-Path -Parent $testsDir
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $repoHash = [System.BitConverter]::ToString($sha.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($repoRoot.ToLowerInvariant()))).Replace('-', '')
} finally {
    $sha.Dispose()
}
$runLockPath = Join-Path $env:TEMP ('wezterm-session-run-' + $repoHash.Substring(0, 16) + '.lock')
$selection = @()
if ($runUnit) { $selection += 'unit' }
if ($runShell) { $selection += 'shell' }
if ($runIntegration) { $selection += 'integration' }
$selectionText = $selection -join '+'

function Read-LockText {
    param([string]$Path)

    $stream = $null
    $reader = $null
    try {
        # FileShare.ReadWrite lets this read coexist with the owner's open write
        # handle. The owner keeps FileShare.Read, so no second run can write.
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream)
        return $reader.ReadToEnd()
    } catch {
        return $null
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        } elseif ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Acquire-RunLock {
    param([string]$Path, [string]$Repo, [string]$Suites)

    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        if (Test-Path -LiteralPath $Path) {
            $existingText = Read-LockText -Path $Path
            if ($null -eq $existingText) {
                return [pscustomobject]@{
                    Stream = $null
                    Message = "run lock $Path exists but cannot be read; another run may be starting. Delete it if it is stale."
                }
            }

            $existing = $null
            $parsedFile = $false
            if (-not [string]::IsNullOrWhiteSpace($existingText)) {
                try {
                    $existing = $existingText | ConvertFrom-Json -ErrorAction Stop
                    $parsedFile = $true
                } catch {
                    $parsedFile = $false
                }
            }

            $otherPid = 0
            $alive = $false
            if ($parsedFile) {
                $parsed = [int]::TryParse([string]$existing.pid, [ref]$otherPid)
                if ($parsed) {
                    $other = Get-Process -Id $otherPid -ErrorAction SilentlyContinue
                    if ($null -ne $other -and @('pwsh', 'powershell') -contains $other.ProcessName) {
                        $alive = $true
                    }
                }
            } else {
                # Empty or damaged: salvage a pid from the raw text. A live owner
                # still wins and is named; otherwise the lock is stale. This runs
                # under ErrorActionPreference Stop, so parsing must never throw
                # out of the runner.
                $match = [regex]::Match([string]$existingText, '"pid"\s*:\s*(\d+)')
                if ($match.Success) {
                    $otherPid = [int]$match.Groups[1].Value
                    $other = Get-Process -Id $otherPid -ErrorAction SilentlyContinue
                    if ($null -ne $other -and @('pwsh', 'powershell') -contains $other.ProcessName) {
                        return [pscustomobject]@{
                            Stream = $null
                            Message = ("run lock {0} is damaged but its owner pid {1} is alive; refusing to interleave" -f `
                                    $Path, $otherPid)
                        }
                    }
                }
            }

            if ($alive) {
                return [pscustomobject]@{
                    Stream = $null
                    Message = ("another test run is active (pid {0}, started {1}, suites {2}); refusing to interleave" -f `
                            $otherPid, [string]$existing.started_at, [string]$existing.suites)
                }
            }

            # Re-read immediately before removing, so a lock another run just
            # created is not deleted on the strength of an older read.
            $again = $null
            $againText = Read-LockText -Path $Path
            if ($null -ne $againText) {
                try {
                    $again = $againText | ConvertFrom-Json
                } catch {
                    $again = $null
                }
            }
            if ($null -ne $again -and [string]$again.pid -ne [string]$existing.pid) {
                continue
            }
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }

        $stream = $null
        try {
            # FileShare.Read lets a second run read the owner's metadata so it
            # can name the active run in its refusal. CreateNew still guarantees
            # only one creator, and holding the handle keeps the lock alive.
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        } catch {
            Start-Sleep -Milliseconds 100
            continue
        }

        $info = [pscustomobject]@{
            pid = $PID
            started_at = (Get-Date).ToString('o')
            repo = $Repo
            suites = $Suites
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($info | ConvertTo-Json -Compress))
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        return [pscustomobject]@{ Stream = $stream; Message = $null; Info = $info }
    }

    return [pscustomobject]@{
        Stream = $null
        Message = "could not acquire the run lock at $Path after several attempts"
    }
}

function Release-RunLock {
    param([string]$Path, $Stream)

    if ($null -ne $Stream) {
        $Stream.Dispose()
    }
    $info = $null
    $text = Read-LockText -Path $Path
    if ($null -ne $text) {
        try {
            $info = $text | ConvertFrom-Json
        } catch {
            $info = $null
        }
    }
    if ($null -eq $info) {
        return
    }
    $ownerPid = 0
    if ([int]::TryParse([string]$info.pid, [ref]$ownerPid) -and $ownerPid -eq $PID) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

# -All starts the three suites as child runners and waits for all of them, so
# the long integration half hides the unit and shell halves instead of adding
# to them. Children never take the run lock.
function Invoke-AllSuites {
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $pwshPath = (Get-Process -Id $PID).Path
    $tempDir = Join-Path $env:TEMP ('wezterm-session-all-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $savedChild = $env:WEZTERM_SESSION_RUNNER_CHILD
    $savedJobs = $env:WEZTERM_SESSION_RUNNER_JOBS
    $env:WEZTERM_SESSION_RUNNER_CHILD = '1'
    $env:WEZTERM_SESSION_RUNNER_JOBS = [string]$Jobs

    $suites = @(
        [pscustomobject]@{ Name = 'unit'; Switch = '-Unit' },
        [pscustomobject]@{ Name = 'shell'; Switch = '-Shell' },
        [pscustomobject]@{ Name = 'integration'; Switch = '-Integration' }
    )
    $runs = @()

    try {
        foreach ($suite in $suites) {
            $outPath = Join-Path $tempDir ($suite.Name + '.stdout.log')
            $errPath = Join-Path $tempDir ($suite.Name + '.stderr.log')
            $process = Start-Process -FilePath $pwshPath `
                -ArgumentList @('-NoProfile', '-File', $PSCommandPath, $suite.Switch) `
                -PassThru `
                -RedirectStandardOutput $outPath `
                -RedirectStandardError $errPath
            $runs += [pscustomobject]@{
                Name = $suite.Name
                Process = $process
                Out = $outPath
                Err = $errPath
                Timer = [System.Diagnostics.Stopwatch]::StartNew()
            }
        }

        foreach ($run in $runs) {
            $run.Process.WaitForExit()
            $run.Timer.Stop()
        }

        $failed = $false
        foreach ($run in $runs) {
            $outText = @(Get-Content -LiteralPath $run.Out -ErrorAction SilentlyContinue)
            foreach ($line in $outText) {
                Write-Output ([string]$line)
            }
            $errText = Get-Content -LiteralPath $run.Err -Raw -ErrorAction SilentlyContinue
            if (-not [string]::IsNullOrWhiteSpace($errText)) {
                foreach ($line in ($errText -split '\r?\n')) {
                    if ($line -ne '') {
                        Write-Output ('  stderr: ' + $line)
                    }
                }
            }
            Write-Output ("TIME {0}: {1:N1}s" -f $run.Name, $run.Timer.Elapsed.TotalSeconds)
            if ($run.Process.ExitCode -ne 0) {
                $failed = $true
            }
        }
        $script:allFailed = $failed
    } finally {
        $env:WEZTERM_SESSION_RUNNER_CHILD = $savedChild
        $env:WEZTERM_SESSION_RUNNER_JOBS = $savedJobs
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$lock = $null
if (-not $isRunnerChild) {
    $lock = Acquire-RunLock -Path $runLockPath -Repo $repoRoot -Suites $selectionText
    if ($null -eq $lock.Stream) {
        Write-Output ('FAIL proof: ' + $lock.Message)
        exit 1
    }
}
$script:runLock = $lock

try {
    if ($allBound -and [bool]$All) {
        $script:allFailed = $false
        Invoke-AllSuites
        if ($script:allFailed) {
            exit 1
        }
        exit 0
    }

    $failedSuites = $false
    if ($runUnit) {
        Invoke-UnitSuite
        if ($script:suiteExit -ne 0) {
            $failedSuites = $true
        }
    }
    if ($runShell) {
        Invoke-ShellSuite
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
} finally {
    if ($null -ne $script:runLock) {
        Release-RunLock -Path $runLockPath -Stream $script:runLock.Stream
    }
    $script:runTimer.Stop()
    if (-not $isRunnerChild) {
        Write-Output ("TIME total: {0:N1}s" -f $script:runTimer.Elapsed.TotalSeconds)
    }
}
