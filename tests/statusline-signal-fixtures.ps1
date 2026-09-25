$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$statuslinePath = Join-Path $repositoryRoot 'statusline\statusline.ps1'
$pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
$testRoot = Join-Path $env:TEMP (
    'copilot-hud-statusline-fixtures-' + [guid]::NewGuid().ToString('N')
)
$copilotHome = Join-Path $testRoot 'copilot-home'
$stateDirectory = Join-Path $copilotHome 'state'
$signalDirectory = Join-Path $stateDirectory 'hud-signal-bridge'
$sessionId = 'fixture-session'
$hookStatePath = Join-Path $stateDirectory "hud-state-$sessionId.json"
$signalStatePath = Join-Path $signalDirectory "hud-signal-$sessionId.json"
$atomicSessionId = 'atomic-fixture'
$atomicSignalStatePath = Join-Path $signalDirectory "hud-signal-$atomicSessionId.json"
$atomicReadyPath = Join-Path $testRoot 'atomic-writer.ready'
$atomicDonePath = Join-Path $testRoot 'atomic-writer.done'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Assert-Fixture {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-FixturePayload {
    param([int]$Width)

    return [ordered]@{
        session_id = $sessionId
        cwd = $repositoryRoot
        terminal_width = $Width
        ai_used = @{ formatted = 239.2625 }
        tokens_per_second = 88.4
        context_window = @{
            last_call_input_tokens = 45000
            context_window_size = 200000
            used_percentage = 22.5
            total_input_tokens = 100000
            total_output_tokens = 8000
            total_cache_read_tokens = 2000
            total_cache_write_tokens = 200
        }
        cost = @{
            total_premium_requests = 3
            total_lines_added = 120
            total_lines_removed = 15
        }
    }
}

function Get-FixtureHookState {
    param([bool]$WithActiveTool, [long]$Now)

    $activeTools = @()
    if ($WithActiveTool) {
        $activeTools = @([ordered]@{
            category = 'shell'
            toolName = 'powershell'
            target = 'phase-probe.txt'
            startedAtMs = $Now - 7000
            timingReliable = $true
        })
    }
    return [ordered]@{
        sessionId = $sessionId
        createdAtMs = $Now - 3600000
        updatedAtMs = $Now
        activeTools = $activeTools
        recentTools = @()
        lastTool = $null
        lastError = $null
        activeSubagents = @()
        lastSubagent = $null
    }
}

function Get-FixtureSignalState {
    param(
        [string]$Phase,
        [AllowNull()][object]$RecentDelta = 39907500,
        [long]$Now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    )

    $phaseAt = if ($null -ne $Phase) { $Now - 1000 } else { $null }
    $recentAt = if ($null -ne $RecentDelta) { $Now - 1000 } else { $null }
    return [ordered]@{
        version = 1
        sessionId = $sessionId
        updatedAtMs = $Now
        phase = $Phase
        phaseAtMs = $phaseAt
        recentIncreaseNanoAiu = $RecentDelta
        recentAtMs = $recentAt
    }
}

function Write-FixtureJson {
    param([string]$Path, [object]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 8 -Compress
    [System.IO.File]::WriteAllText($Path, $json, $utf8)
}

function Invoke-StatuslineFixture {
    param(
        [int]$Width,
        [bool]$NoColor,
        [string]$BridgeEnabled = '1',
        [AllowNull()][object]$HookState,
        [AllowNull()][object]$SignalState,
        [ValidateSet('normal', 'malformed', 'oversize')][string]$SignalFile = 'normal'
    )

    if ($null -eq $HookState) {
        if ([System.IO.File]::Exists($hookStatePath)) {
            [System.IO.File]::Delete($hookStatePath)
        }
    } else {
        Write-FixtureJson -Path $hookStatePath -Value $HookState
    }

    if ($null -eq $SignalState) {
        if ([System.IO.File]::Exists($signalStatePath)) {
            [System.IO.File]::Delete($signalStatePath)
        }
    } elseif ($SignalFile -eq 'malformed') {
        [System.IO.File]::WriteAllText($signalStatePath, '{"version":1', $utf8)
    } elseif ($SignalFile -eq 'oversize') {
        [System.IO.File]::WriteAllText($signalStatePath, ('x' * 5000), $utf8)
    } else {
        Write-FixtureJson -Path $signalStatePath -Value $SignalState
    }

    $payloadJson = ConvertTo-Json -InputObject (Get-FixturePayload -Width $Width) `
        -Depth 8 -Compress
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($pwshPath)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.ArgumentList.Add('-NoProfile')
    $startInfo.ArgumentList.Add('-File')
    $startInfo.ArgumentList.Add($statuslinePath)
    $startInfo.Environment['COPILOT_HOME'] = $copilotHome
    $startInfo.Environment['COPILOT_HUD_SIGNAL_BRIDGE'] = $BridgeEnabled
    $startInfo.Environment['COPILOT_RAW_PAYLOAD_CAPTURE'] = '0'
    $startInfo.Environment['COPILOT_STATUSLINE_WIDTH'] = [string]$Width
    $startInfo.Environment['COLUMNS'] = [string]$Width
    $startInfo.Environment['TERM'] = if ($NoColor) { 'dumb' } else { 'xterm-256color' }
    foreach ($name in @('NO_COLOR', 'WT_SESSION', 'ConEmuANSI', 'ANSICON', 'TERM_PROGRAM')) {
        [void]$startInfo.Environment.Remove($name)
    }
    if ($NoColor) {
        $startInfo.Environment['NO_COLOR'] = '1'
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $process.StandardInput.Write($payloadJson)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $process.Dispose()
    Assert-Fixture ($exitCode -eq 0) "Statusline exited with code $exitCode."
    Assert-Fixture ([string]::IsNullOrEmpty($stderr)) 'Statusline emitted stderr.'
    return $stdout
}

function Get-OutputLines {
    param([string]$Text)
    return @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrEmpty($_) })
}

function Get-VisibleLength {
    param([string]$Text)
    return ([regex]::Replace($Text, '\x1B\[[0-?]*[ -/]*[@-~]', '')).Length
}

function Get-PlainText {
    param([string]$Text)
    return [regex]::Replace($Text, '\x1B\[[0-?]*[ -/]*[@-~]', '')
}

function Test-AtomicSignalSnapshots {
    $storePath = Join-Path $repositoryRoot '.github\extensions\hud-signal-bridge\state-store.mjs'
    $nodeScript = @'
import { pathToFileURL } from "node:url";
import { writeFile } from "node:fs/promises";
const { createSignalStateStore } = await import(pathToFileURL(process.argv[1]));
const [home, sessionId, readyPath, donePath] = process.argv.slice(2);
const store = await createSignalStateStore(home, sessionId);
const now = Date.now();
await store.write({
  version: 1, sessionId, updatedAtMs: now, phase: "working",
  phaseAtMs: now, recentIncreaseNanoAiu: null, recentAtMs: null
});
await writeFile(readyPath, "ready", { encoding: "utf8", mode: 0o600 });
for (let index = 0; index < 40; index += 1) {
  await store.write({
    version: 1, sessionId, updatedAtMs: now + index + 1, phase: "working",
    phaseAtMs: now, recentIncreaseNanoAiu: index + 1, recentAtMs: now
  });
  await new Promise(resolve => setTimeout(resolve, 3));
}
await writeFile(donePath, "done", { encoding: "utf8", mode: 0o600 });
'@
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new(
        (Get-Command node -ErrorAction Stop).Source
    )
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add('--input-type=module')
    $startInfo.ArgumentList.Add('-e')
    $startInfo.ArgumentList.Add($nodeScript)
    $startInfo.ArgumentList.Add($storePath)
    $startInfo.ArgumentList.Add($copilotHome)
    $startInfo.ArgumentList.Add($atomicSessionId)
    $startInfo.ArgumentList.Add($atomicReadyPath)
    $startInfo.ArgumentList.Add($atomicDonePath)

    $writer = [System.Diagnostics.Process]::new()
    $writer.StartInfo = $startInfo
    [void]$writer.Start()
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not [System.IO.File]::Exists($atomicReadyPath) -and
        [DateTime]::UtcNow -lt $deadline) {
        if ($writer.HasExited) {
            $stderr = $writer.StandardError.ReadToEnd()
            throw "Atomic fixture writer exited early: $stderr"
        }
        Start-Sleep -Milliseconds 10
    }
    Assert-Fixture ([System.IO.File]::Exists($atomicReadyPath)) `
        'Atomic fixture writer did not create its initial state.'

    $readCount = 0
    while (-not [System.IO.File]::Exists($atomicDonePath)) {
        if ($writer.HasExited) {
            $stderr = $writer.StandardError.ReadToEnd()
            throw "Atomic fixture writer exited during updates: $stderr"
        }
        $stream = $null
        try {
            $stream = [System.IO.FileStream]::new(
                $atomicSignalStatePath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
            )
            $length = $stream.Length
            Assert-Fixture ($length -gt 0 -and $length -le 4096) `
                'Atomic state exceeded its read bound.'
            $bytes = [byte[]]::new([int]$length)
            $offset = 0
            while ($offset -lt $length) {
                $read = $stream.Read($bytes, $offset, [int]($length - $offset))
                Assert-Fixture ($read -gt 0) 'Atomic state snapshot ended unexpectedly.'
                $offset += $read
            }
            $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            $state = ConvertFrom-Json -InputObject $text -AsHashtable -ErrorAction Stop
            Assert-Fixture ($state.sessionId -ceq $atomicSessionId) `
                'Atomic state crossed session boundaries.'
            Assert-Fixture ($state.recentIncreaseNanoAiu -is [ValueType]) `
                'Atomic state did not contain a numeric derived value.'
            $readCount++
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
        Start-Sleep -Milliseconds 1
    }

    Assert-Fixture ($writer.WaitForExit(5000)) 'Atomic fixture writer timed out.'
    $stderr = $writer.StandardError.ReadToEnd()
    $exitCode = $writer.ExitCode
    $writer.Dispose()
    Assert-Fixture ($exitCode -eq 0 -and [string]::IsNullOrEmpty($stderr)) `
        'Atomic fixture writer failed.'
    Assert-Fixture ($readCount -gt 0) 'No concurrent shared reads were observed.'
    'ConcurrentSharedReads={0}; AtomicReplacements=40' -f $readCount
}

New-Item -ItemType Directory -Path $signalDirectory -Force | Out-Null
$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

try {
    foreach ($width in @(80, 120, 160)) {
        foreach ($noColor in @($false, $true)) {
            $state = Get-FixtureSignalState -Phase 'running_tool' -Now $now
            $output = Invoke-StatuslineFixture -Width $width -NoColor $noColor `
                -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
                -SignalState $state
            $lines = @(Get-OutputLines $output)
            Assert-Fixture ($lines.Count -eq 3) "Expected three lines at width $width (NO_COLOR=$noColor)."
            foreach ($line in $lines) {
                Assert-Fixture ((Get-VisibleLength $line) -le $width) `
                    "A rendered line exceeded width $width."
            }
            $plainLines = @($lines | ForEach-Object { Get-PlainText $_ })
            Assert-Fixture ($plainLines[1] -match 'AIC 239\.26') `
                "Session AIC total was not preserved at width $width (NO_COLOR=$noColor)."
            Assert-Fixture ($plainLines[1] -match '88\.4 tok/s') `
                "Token rate was not preserved at width $width (NO_COLOR=$noColor)."
            $recentVisible = $plainLines[1] -match 'recent \+0\.04 AIU'
            if ($width -ge 120) {
                Assert-Fixture $recentVisible `
                    "Recent AIC label missing at width $width (NO_COLOR=$noColor)."
            }
            Assert-Fixture ($plainLines[2] -match 'Running tool') `
                "Running-tool phase missing at width $width (NO_COLOR=$noColor)."
            '{0} columns; NO_COLOR={1}; recentDeltaVisible={2}' -f $width,$noColor,$recentVisible
            if ($noColor) {
                Assert-Fixture ($output -notmatch "`e") 'NO_COLOR output contained ANSI escapes.'
            } else {
                Assert-Fixture ($output -match "`e\[[0-9;]*m") 'ANSI output contained no color sequences.'
                Assert-Fixture ($lines[2] -match "`e\[38;5;226m◐") 'Active phase glyph was not yellow.'
            }
        }
    }

    foreach ($width in @(80, 120, 160)) {
        $idleOutput = Invoke-StatuslineFixture -Width $width -NoColor $true `
            -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
            -SignalState (Get-FixtureSignalState -Phase 'idle' -Now $now)
        $phaseOutput = Invoke-StatuslineFixture -Width $width -NoColor $true `
            -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
            -SignalState (Get-FixtureSignalState -Phase 'running_tool' -Now $now)
        $idleLines = @(Get-OutputLines $idleOutput)
        $phaseLines = @(Get-OutputLines $phaseOutput)
        Assert-Fixture ($idleLines.Count -eq 2) "Idle HUD did not render exactly two lines at width $width."
        Assert-Fixture ($phaseLines.Count -eq 3) "Active phase did not render a third line at width $width."
        Assert-Fixture ($idleLines[0] -ceq $phaseLines[0]) 'Activity shifted line 1.'
        Assert-Fixture ($idleLines[1] -ceq $phaseLines[1]) 'Activity shifted line 2.'
    }

    $activeHook = Get-FixtureHookState -WithActiveTool $true -Now $now
    $signalPhase = Get-FixtureSignalState -Phase 'running_tool' -Now $now
    $hookFallback = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -BridgeEnabled '0' -HookState $activeHook -SignalState $signalPhase
    $hookLines = @(Get-OutputLines $hookFallback)
    Assert-Fixture ($hookLines.Count -eq 3 -and $hookLines[2] -match 'powershell') `
        'Disabled bridge did not preserve the hook activity fallback.'
    Assert-Fixture ($hookLines[2] -notmatch 'Running tool') `
        'Disabled bridge rendered a phase signal.'
    Assert-Fixture ($hookLines[1] -notmatch 'recent \+') `
        'Disabled bridge rendered a recent AIC increase.'

    $noExtension = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -BridgeEnabled '1' -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
        -SignalState $null
    Assert-Fixture (@(Get-OutputLines $noExtension).Count -eq 2) `
        'Missing extension state changed the idle HUD.'

    $working = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
        -SignalState (Get-FixtureSignalState -Phase 'working' -Now $now)
    $workingLines = @(Get-OutputLines $working)
    Assert-Fixture ($workingLines.Count -eq 3 -and $workingLines[2] -match '◐ Working') `
        'Working phase was not rendered from turn lifecycle state.'

    $agentHook = Get-FixtureHookState -WithActiveTool $false -Now $now
    $agentHook.activeSubagents = @([ordered]@{
        matchKey = 'analysis'
        agentKey = $null
        startedAtMs = $now - 7000
        timingReliable = $true
    })
    $agentFallback = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $agentHook -SignalState $signalPhase
    $agentLines = @(Get-OutputLines $agentFallback)
    Assert-Fixture ($agentLines.Count -eq 3 -and $agentLines[2] -match 'analysis') `
        'Hook-based agent display was not preserved.'
    Assert-Fixture ($agentLines[2] -notmatch 'Running tool') `
        'Bridge phase duplicated hook-based agent activity.'

    $hookOutcome = Get-FixtureHookState -WithActiveTool $false -Now $now
    $hookOutcome.lastTool = [ordered]@{
        category = 'read'
        toolName = 'view'
        target = 'phase-probe.txt'
        status = 'complete'
        durationMs = 12
        completedAtMs = $now - 1000
    }
    $completeWithHookOutcome = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $hookOutcome `
        -SignalState (Get-FixtureSignalState -Phase 'complete' -Now $now)
    $hookOutcomeLines = @(Get-OutputLines $completeWithHookOutcome)
    Assert-Fixture ($hookOutcomeLines.Count -eq 3 -and $hookOutcomeLines[2] -match 'read') `
        'Recent hook outcome was not preserved.'
    Assert-Fixture ($hookOutcomeLines[2] -notmatch '✓ Complete') `
        'Bridge completion duplicated the recent hook outcome.'

    foreach ($fileMode in @('malformed', 'oversize')) {
        $fallback = Invoke-StatuslineFixture -Width 120 -NoColor $true `
            -HookState $activeHook -SignalState $signalPhase -SignalFile $fileMode
        $fallbackLines = @(Get-OutputLines $fallback)
        Assert-Fixture ($fallbackLines.Count -eq 3 -and $fallbackLines[2] -match 'powershell') `
            "$fileMode signal state did not fall back to hook activity."
        Assert-Fixture ($fallbackLines[2] -notmatch 'Running tool') `
            "$fileMode signal state rendered a phase."
        Assert-Fixture ($fallbackLines[1] -notmatch 'recent \+') `
            "$fileMode signal state rendered a recent AIC increase."
    }

    $staleState = Get-FixtureSignalState -Phase 'running_tool' -Now ($now - 60000)
    $staleFallback = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $activeHook -SignalState $staleState
    $staleLines = @(Get-OutputLines $staleFallback)
    Assert-Fixture ($staleLines.Count -eq 3 -and $staleLines[2] -match 'powershell') `
        'Stale state did not preserve hook activity.'
    Assert-Fixture ($staleLines[2] -notmatch 'Running tool') `
        'Stale phase was rendered.'
    Assert-Fixture ($staleLines[1] -notmatch 'recent \+') `
        'Stale AIC increase was rendered.'

    $duplicateSuppressed = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $activeHook -SignalState $signalPhase
    $duplicateLines = @(Get-OutputLines $duplicateSuppressed)
    Assert-Fixture ($duplicateLines[2] -match 'powershell') `
        'Hook-based tool ticker disappeared when both sources were active.'
    Assert-Fixture ($duplicateLines[2] -notmatch 'Running tool') `
        'Bridge phase duplicated active hook tool activity.'

    $completionNow = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $complete = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $completionNow) `
        -SignalState (Get-FixtureSignalState -Phase 'complete' -Now $completionNow)
    $completeLines = @(Get-OutputLines $complete)
    Assert-Fixture ($completeLines.Count -eq 3 -and $completeLines[2] -match '✓ Complete') `
        "A fresh completed phase was not displayed: $($completeLines -join ' | ')"

    Test-AtomicSignalSnapshots
    'StatuslineSignalFixturesPass=True'
    'Widths=80,120,160; ANSI/NO_COLOR=passed'
    'IdleLines=2; ActiveLines=3; HookFallback=passed'
    'AbsentDisabledStaleMalformedOversize=passed'
} finally {
    foreach ($path in @(
        $hookStatePath,
        $signalStatePath,
        $atomicSignalStatePath,
        $atomicReadyPath,
        $atomicDonePath
    )) {
        if ([System.IO.File]::Exists($path)) {
            [System.IO.File]::Delete($path)
        }
    }
    foreach ($directory in @($signalDirectory, $stateDirectory, $copilotHome, $testRoot)) {
        if ([System.IO.Directory]::Exists($directory)) {
            if (@(Get-ChildItem -LiteralPath $directory -Force).Count -ne 0) {
                throw 'Fixture cleanup found unexpected files; leaving the directory intact.'
            }
            [System.IO.Directory]::Delete($directory)
        }
    }
}
