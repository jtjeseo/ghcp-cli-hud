$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$statuslinePath = Join-Path $repositoryRoot 'statusline\statusline.ps1'
$pwshPath = if ($env:HUD_TEST_POWERSHELL) { $env:HUD_TEST_POWERSHELL } else { (Get-Command pwsh -ErrorAction Stop).Source }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'copilot-hud-statusline-fixtures-' + [guid]::NewGuid().ToString('N')
)
$copilotHome = Join-Path $testRoot 'copilot-home'
$stateDirectory = Join-Path $copilotHome 'state'
$signalDirectory = Join-Path $stateDirectory 'hud-signal-bridge'
$sessionId = 'fixture-session'
$hookStatePath = Join-Path $stateDirectory "hud-state-$sessionId.json"
$foreignSessionId = 'foreign-fixture-session'
$foreignHookStatePath = Join-Path $stateDirectory "hud-state-$foreignSessionId.json"
$signalStatePath = Join-Path $signalDirectory "hud-signal-$sessionId.json"
$foreignSignalStatePath = Join-Path $signalDirectory "hud-signal-$foreignSessionId.json"
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
    param([int]$Width, [switch]$ZeroUsage)

    $payload = [ordered]@{
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
    if ($ZeroUsage) {
        foreach ($name in @(
            'total_input_tokens', 'total_output_tokens',
            'total_cache_read_tokens', 'total_cache_write_tokens'
        )) {
            $payload.context_window[$name] = 0
        }
        $payload.cost.total_lines_added = 0
        $payload.cost.total_lines_removed = 0
    }
    return $payload
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
        [AllowNull()][object]$Phase,
        [AllowNull()][object]$RecentDelta = 39907500,
        [long]$Now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(),
        [AllowNull()][object]$ActiveSubagentCount = $null
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
        activeSubagentCount = $ActiveSubagentCount
    }
}

function Write-FixtureJson {
    param([string]$Path, [object]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 8 -Compress
    [System.IO.File]::WriteAllText($Path, $json, $utf8)
}

function Refresh-FixtureTimestamps {
    param(
        [AllowNull()][object]$Value,
        [long]$From,
        [long]$To
    )

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $current = $Value[$key]
            if ($key -ceq 'updatedAtMs') {
                $Value[$key] = $To
            } elseif ($key -ceq 'createdAtMs') {
                continue
            } elseif ($key -match 'AtMs$' -and
                $current -is [ValueType] -and $current -isnot [bool]) {
                $Value[$key] = [long]$current + ($To - $From)
            } else {
                Refresh-FixtureTimestamps -Value $current -From $From -To $To
            }
        }
    } elseif ($Value -is [System.Collections.IList]) {
        foreach ($item in $Value) {
            Refresh-FixtureTimestamps -Value $item -From $From -To $To
        }
    }
}

function Invoke-StatuslineFixture {
    param(
        [int]$Width,
        [bool]$NoColor,
        [string]$BridgeEnabled = '1',
        [AllowNull()][object]$HookState,
        [AllowNull()][object]$SignalState,
        [ValidateSet('normal', 'malformed', 'oversize')][string]$SignalFile = 'normal',
        [switch]$PreserveSignalTimestamp,
        [switch]$PreserveHookTimestamp,
        [switch]$ZeroUsage
    )

    $fixtureNow = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if (-not $PreserveHookTimestamp -and
        $HookState -is [System.Collections.IDictionary] -and
        $HookState['updatedAtMs'] -is [ValueType]) {
        Refresh-FixtureTimestamps -Value $HookState `
            -From ([long]$HookState['updatedAtMs']) -To $fixtureNow
    }
    if (-not $PreserveSignalTimestamp -and
        $SignalState -is [System.Collections.IDictionary] -and
        $SignalState['updatedAtMs'] -is [ValueType]) {
        Refresh-FixtureTimestamps -Value $SignalState `
            -From ([long]$SignalState['updatedAtMs']) -To $fixtureNow
    }

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

    $payloadJson = ConvertTo-Json -InputObject (Get-FixturePayload -Width $Width -ZeroUsage:$ZeroUsage) `
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
    $startInfo.ArgumentList.Add('-ExecutionPolicy')
    $startInfo.ArgumentList.Add('Bypass')
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
  phaseAtMs: now, recentIncreaseNanoAiu: null, recentAtMs: null,
  recentSuppressedReason: null, activeSubagentCount: null
});
await writeFile(readyPath, "ready", { encoding: "utf8", mode: 0o600 });
for (let index = 0; index < 40; index += 1) {
  await store.write({
    version: 1, sessionId, updatedAtMs: now + index + 1, phase: "working",
    phaseAtMs: now, recentIncreaseNanoAiu: index + 1, recentAtMs: now,
    recentSuppressedReason: null, activeSubagentCount: null
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
    'ConcurrentSharedReads={0}; SnapshotUpdateWrites=40; InitialSnapshotWrite=1' -f $readCount
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

    $mutedPalette = @(
        @{
            Name = 'zero'
            ZeroUsage = $true
            Expected = "`e[38;5;244mI `e[0m`e[38;5;244m0`e[0m`e[38;5;244m · `e[0m`e[38;5;244mO `e[0m`e[38;5;244m0`e[0m`e[38;5;244m · `e[0m`e[38;5;244mC `e[0m`e[38;5;244m0`e[0m `e[38;5;244m│`e[0m `e[38;5;108m+0`e[0m`e[38;5;244m/`e[0m`e[38;5;131m-0`e[0m"
            PlainTail = 'I 0 · O 0 · C 0 │ +0/-0'
        },
        @{
            Name = 'populated'
            ZeroUsage = $false
            Expected = "`e[38;5;244mI `e[0m`e[38;5;244m100k`e[0m`e[38;5;244m · `e[0m`e[38;5;244mO `e[0m`e[38;5;244m8k`e[0m`e[38;5;244m · `e[0m`e[38;5;244mC `e[0m`e[38;5;244m2.2k`e[0m `e[38;5;244m│`e[0m `e[38;5;108m+120`e[0m`e[38;5;244m/`e[0m`e[38;5;131m-15`e[0m"
            PlainTail = 'I 100k · O 8k · C 2.2k │ +120/-15'
        }
    )
    foreach ($case in $mutedPalette) {
        foreach ($width in @(80, 120, 160)) {
            $paletteState = Get-FixtureSignalState -Phase $null -RecentDelta $null -Now $now
            $ansi = Invoke-StatuslineFixture -Width $width -NoColor $false `
                -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
                -SignalState $paletteState -ZeroUsage:$case.ZeroUsage
            $plain = Invoke-StatuslineFixture -Width $width -NoColor $true `
                -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
                -SignalState $paletteState -ZeroUsage:$case.ZeroUsage
            $ansiLines = @(Get-OutputLines $ansi)
            $plainLines = @(Get-OutputLines $plain)
            Assert-Fixture ($ansiLines.Count -eq $plainLines.Count -and $ansiLines.Count -ge 2) `
                "Muted-palette line count changed ($($case.Name), width $width)."
            Assert-Fixture ($ansiLines[1].EndsWith($case.Expected, [System.StringComparison]::Ordinal)) `
                "Muted I/O/C or changeset palette mismatch ($($case.Name), width $width)."
            $mutedSegment = $case.Expected
            Assert-Fixture ($mutedSegment -notmatch "`e\[1m" -and
                $mutedSegment -notmatch '38;5;(15|46|196)m') `
                'Expected muted palette contains a former bold/bright code.'
            $renderedSegment = $ansiLines[1].Substring(
                $ansiLines[1].Length - $case.Expected.Length)
            Assert-Fixture ($renderedSegment -notmatch "`e\[1m" -and
                $renderedSegment -notmatch '38;5;(15|46|196)m') `
                "Former bold/bright I/O/C or changeset code rendered ($($case.Name), width $width)."
            Assert-Fixture ($plain -notmatch "`e") `
                "NO_COLOR palette output contained ANSI escapes ($($case.Name), width $width)."
            Assert-Fixture ($plainLines[1].EndsWith($case.PlainTail, [System.StringComparison]::Ordinal)) `
                "NO_COLOR I/O/C or changeset text changed ($($case.Name), width $width)."
            Assert-Fixture ((Get-PlainText $ansiLines[1]) -ceq $plainLines[1]) `
                "ANSI and NO_COLOR line-2 text diverged ($($case.Name), width $width)."
            Assert-Fixture ((Get-VisibleLength $ansiLines[1]) -le $width) `
                "Muted-palette line 2 exceeded width $width ($($case.Name))."
        }
    }
    'MutedPalette=zero,populated; Widths=80,120,160; I/O/C+separators=244; added=108; removed=131; FormerBoldBright=absent; NO_COLOR=unchanged'

    $roundingCases = @(
        [pscustomobject]@{
            NanoAiu = 6384999999
            Expected = 'recent +6.38 AIU'
        },
        [pscustomobject]@{
            NanoAiu = 6385000000
            Expected = 'recent +6.39 AIU'
        },
        [pscustomobject]@{
            NanoAiu = 1
            Expected = 'recent +0.000000001 AIU'
        }
    )
    foreach ($width in @(120, 160)) {
        foreach ($noColor in @($false, $true)) {
            foreach ($roundingCase in $roundingCases) {
                $roundingState = Get-FixtureSignalState -Phase $null `
                    -RecentDelta $roundingCase.NanoAiu -Now $now
                $roundingOutput = Invoke-StatuslineFixture -Width $width `
                    -NoColor $noColor `
                    -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
                    -SignalState $roundingState
                $roundingLines = @(Get-OutputLines $roundingOutput)
                $roundingPlain = @(
                    $roundingLines | ForEach-Object { Get-PlainText $_ }
                )
                Assert-Fixture ($roundingPlain[1] -match [regex]::Escape($roundingCase.Expected)) `
                    "AIU rounding mismatch at width $width (NO_COLOR=$noColor)."
                if ($noColor) {
                    Assert-Fixture ($roundingOutput -notmatch "`e") `
                        'NO_COLOR rounding output contained ANSI escapes.'
                } else {
                    Assert-Fixture ($roundingOutput -match "`e\[[0-9;]*m") `
                        'Colored rounding output contained no ANSI escapes.'
                }
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
        $noSignalOutput = Invoke-StatuslineFixture -Width $width -NoColor $true `
            -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
            -SignalState (Get-FixtureSignalState -Phase $null -RecentDelta $null -Now $now)
        $agentOutput = Invoke-StatuslineFixture -Width $width -NoColor $true `
            -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
            -SignalState (Get-FixtureSignalState -Phase $null -RecentDelta $null `
                -Now $now -ActiveSubagentCount 2)
        $singleAgentOutput = Invoke-StatuslineFixture -Width $width -NoColor $true `
            -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
            -SignalState (Get-FixtureSignalState -Phase $null -RecentDelta $null `
                -Now $now -ActiveSubagentCount 1)
        $idleLines = @(Get-OutputLines $idleOutput)
        $phaseLines = @(Get-OutputLines $phaseOutput)
        $noSignalLines = @(Get-OutputLines $noSignalOutput)
        $agentLines = @(Get-OutputLines $agentOutput)
        $singleAgentLines = @(Get-OutputLines $singleAgentOutput)
        Assert-Fixture ($idleLines.Count -eq 2) "Idle HUD did not render exactly two lines at width $width."
        Assert-Fixture ($phaseLines.Count -eq 3) "Active phase did not render a third line at width $width."
        Assert-Fixture ($noSignalLines.Count -eq 2) `
            "HUD without phase, recent delta, or Fleet signals did not render two lines at width $width."
        Assert-Fixture ($agentLines.Count -eq 3) `
            "Fleet count did not render a third line at width ${width}: $($agentLines -join ' | ')"
        Assert-Fixture ($singleAgentLines.Count -eq 3 -and
            (Get-PlainText $singleAgentLines[2]) -match '◐ 1 subagent') `
            "Single-agent count did not render at width $width."
        Assert-Fixture ((Get-VisibleLength $singleAgentLines[2]) -le $width) `
            "Single-agent activity exceeded width $width."
        Assert-Fixture ($idleLines[0] -ceq $phaseLines[0]) 'Activity shifted line 1.'
        Assert-Fixture ($idleLines[1] -ceq $phaseLines[1]) 'Activity shifted line 2.'
        Assert-Fixture ($noSignalLines[0] -ceq $agentLines[0]) 'Fleet count shifted line 1.'
        Assert-Fixture ($noSignalLines[1] -ceq $agentLines[1]) 'Fleet count shifted line 2.'
        Assert-Fixture ($noSignalLines[0] -ceq $singleAgentLines[0]) 'Single-agent count shifted line 1.'
        Assert-Fixture ($noSignalLines[1] -ceq $singleAgentLines[1]) 'Single-agent count shifted line 2.'
        Assert-Fixture ((Get-PlainText $agentLines[2]) -match '◐ 2 subagents') `
            "Active Fleet count missing at width $width."
        Assert-Fixture ((Get-VisibleLength $agentLines[2]) -le $width) `
            "Fleet activity line exceeded width $width."
        Assert-Fixture ($agentOutput -notmatch "`e") `
            "NO_COLOR Fleet output contained ANSI escapes at width $width."
    }

    $narrowFleet = Invoke-StatuslineFixture -Width 24 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $true -Now $now) `
        -SignalState (Get-FixtureSignalState -Phase $null -RecentDelta $null `
            -Now $now -ActiveSubagentCount 2)
    $narrowFleetLines = @(Get-OutputLines $narrowFleet)
    Assert-Fixture ($narrowFleetLines.Count -eq 3 -and
        $narrowFleetLines[2] -match 'powershell' -and
        $narrowFleetLines[2] -notmatch 'subagents') `
        'Active tool activity did not retain its priority over a bridge agent count at narrow width.'
    Assert-Fixture ((Get-VisibleLength $narrowFleetLines[2]) -le 24) `
        'Narrow activity overflow was not degraded by dropping a whole segment.'

    $foreignSignal = Get-FixtureSignalState -Phase $null -RecentDelta $null `
        -Now $now -ActiveSubagentCount 2
    $foreignSignal.sessionId = $foreignSessionId
    Write-FixtureJson -Path $foreignSignalStatePath -Value $foreignSignal
    $currentSessionSignal = Get-FixtureSignalState -Phase $null -RecentDelta $null `
        -Now ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -ActiveSubagentCount 1
    $currentSessionRender = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
        -SignalState $currentSessionSignal
    $currentSessionLines = @(Get-OutputLines $currentSessionRender)
    Assert-Fixture ($currentSessionLines.Count -eq 3 -and
        $currentSessionLines[2] -match '1 subagent' -and
        $currentSessionLines[2] -notmatch '2 subagents') `
        'Concurrent session bridge files were combined or selected by recency.'
    [System.IO.File]::Delete($foreignSignalStatePath)

    $coloredFleet = Invoke-StatuslineFixture -Width 120 -NoColor $false `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
        -SignalState (Get-FixtureSignalState -Phase $null -RecentDelta $null `
            -Now $now -ActiveSubagentCount 2)
    $coloredFleetLines = @(Get-OutputLines $coloredFleet)
    Assert-Fixture ($coloredFleetLines[2] -match "`e\[38;5;226m◐") `
        'Fleet activity glyph was not yellow.'

    $activeHook = Get-FixtureHookState -WithActiveTool $true -Now $now
    $signalPhase = Get-FixtureSignalState -Phase 'running_tool' -Now $now
    $signalFleet = Get-FixtureSignalState -Phase $null -RecentDelta $null `
        -Now $now -ActiveSubagentCount 2
    $hookFallback = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -BridgeEnabled '0' -HookState $activeHook -SignalState $signalFleet
    $hookLines = @(Get-OutputLines $hookFallback)
    Assert-Fixture ($hookLines.Count -eq 3 -and $hookLines[2] -match 'powershell') `
        'Disabled bridge did not preserve the hook activity fallback.'
    Assert-Fixture ($hookLines[2] -notmatch 'subagents') `
        'Disabled bridge rendered a Fleet count.'
    Assert-Fixture ($hookLines[1] -notmatch 'recent \+') `
        'Disabled bridge rendered a recent AIC increase.'

    foreach ($mixedWidth in @(80, 120, 160)) {
        $mixedNow = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $agentAndToolHook = Get-FixtureHookState -WithActiveTool $true -Now $mixedNow
        $agentAndToolHook.activeSubagents = @([ordered]@{
            matchKey = 'analysis'
            agentKey = $null
            startedAtMs = $mixedNow - 7000
            timingReliable = $true
        })
        $mixedFleetState = Get-FixtureSignalState -Phase $null -RecentDelta $null `
            -Now $mixedNow -ActiveSubagentCount 2
        $unknownFleetState = Get-FixtureSignalState -Phase $null -RecentDelta $null `
            -Now $mixedNow -ActiveSubagentCount $null
        $fleetWithActiveTool = Invoke-StatuslineFixture -Width $mixedWidth -NoColor $true `
            -HookState $agentAndToolHook -SignalState $mixedFleetState
        $hookBaseline = Invoke-StatuslineFixture -Width $mixedWidth -NoColor $true `
            -HookState $agentAndToolHook -SignalState $unknownFleetState
        $fleetWithActiveToolLines = @(Get-OutputLines $fleetWithActiveTool)
        $hookBaselineLines = @(Get-OutputLines $hookBaseline)
        Assert-Fixture ($fleetWithActiveToolLines.Count -eq 3 -and
            $fleetWithActiveToolLines[2] -match '2 subagents' -and
            $fleetWithActiveToolLines[2] -match 'powershell') `
            "Fresh Fleet count hid useful hook tool information at width $mixedWidth."
        Assert-Fixture ($fleetWithActiveToolLines[2] -notmatch 'analysis') `
            'The hook agent was duplicated alongside the aggregate Fleet count.'
        Assert-Fixture ($fleetWithActiveToolLines[0] -ceq $hookBaselineLines[0] -and
            $fleetWithActiveToolLines[1] -ceq $hookBaselineLines[1]) `
            "Fleet precedence changed HUD lines 1/2 at width $mixedWidth."
        Assert-Fixture ((Get-VisibleLength $fleetWithActiveToolLines[2]) -le $mixedWidth) `
            "Mixed Fleet activity exceeded width $mixedWidth."
        foreach ($fleetState in @($mixedFleetState, $unknownFleetState)) {
            $coloredActivity = Invoke-StatuslineFixture -Width $mixedWidth -NoColor $false `
                -HookState $agentAndToolHook -SignalState $fleetState
            $coloredLines = @(Get-OutputLines $coloredActivity)
            $yellowGlyphs = [regex]::Matches($coloredLines[2], "`e\[38;5;226m◐`e\[0m")
            Assert-Fixture ($yellowGlyphs.Count -eq 2) `
                "Both tool and agent glyphs must be yellow regardless of telemetry source at width $mixedWidth."
            Assert-Fixture ($coloredLines[2] -match "`e\[38;5;15mpowershell`e\[0m" -and
                $coloredLines[2] -match "`e\[38;5;15m(?:analysis|2 subagents)`e\[0m") `
                'Active tool and agent labels must stay white.'
            Assert-Fixture ((Get-VisibleLength $coloredLines[2]) -le $mixedWidth) `
                "Color styling changed activity width at $mixedWidth."
        }
        Assert-Fixture ($fleetWithActiveTool -notmatch "`e" -and $hookBaseline -notmatch "`e") `
            'NO_COLOR active tool/agent output contained ANSI escapes.'
    }

    $agentDispatchHook = Get-FixtureHookState -WithActiveTool $false -Now $now
    $agentDispatchHook.activeTools = @([ordered]@{
        category = 'agent'
        toolName = 'task'
        target = 'workspace'
        startedAtMs = $now - 7000
        timingReliable = $true
    })
    $fleetWithDispatchTool = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $agentDispatchHook -SignalState $signalFleet
    $fleetWithDispatchLines = @(Get-OutputLines $fleetWithDispatchTool)
    Assert-Fixture ($fleetWithDispatchLines[2] -match '2 subagents' -and
        $fleetWithDispatchLines[2] -match 'task' -and
        $fleetWithDispatchLines[2] -notmatch 'agent running') `
        'The spawning task tool was obscured by or confused with the Fleet count.'

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
        -HookState $agentHook -SignalState $signalFleet
    $agentLines = @(Get-OutputLines $agentFallback)
    Assert-Fixture ($agentLines.Count -eq 3 -and $agentLines[2] -match '2 subagents') `
        'A fresh bridge count was hidden by hook-based agent activity.'
    Assert-Fixture ($agentLines[2] -notmatch 'analysis') `
        'Hook-based agent activity was duplicated alongside the bridge count.'

    $recentAgentHook = Get-FixtureHookState -WithActiveTool $false -Now $now
    $recentAgentHook.lastSubagent = [ordered]@{
        matchKey = 'analysis'
        status = 'complete'
        completedAtMs = $now - 1000
        durationMs = 4000
    }
    $recentAgentFallback = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $recentAgentHook -SignalState $signalFleet
    $recentAgentLines = @(Get-OutputLines $recentAgentFallback)
    Assert-Fixture ($recentAgentLines.Count -eq 3 -and $recentAgentLines[2] -match '2 subagents') `
        'A fresh bridge count was hidden by recent hook agent history.'
    Assert-Fixture ($recentAgentLines[2] -notmatch 'analysis') `
        'Recent hook agent history was duplicated alongside the bridge count.'

    $zeroWithRecentHookAgent = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $recentAgentHook `
        -SignalState (Get-FixtureSignalState -Phase $null -RecentDelta $null `
            -Now $now -ActiveSubagentCount 0)
    $zeroWithRecentHookLines = @(Get-OutputLines $zeroWithRecentHookAgent)
    Assert-Fixture ($zeroWithRecentHookLines.Count -eq 2 -and
        ($zeroWithRecentHookLines -join ' ') -notmatch 'analysis|ended|complete') `
        'Confirmed zero did not suppress recent hook-agent history.'

    $unknownFleetWithAgent = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $agentHook `
        -SignalState (Get-FixtureSignalState -Phase $null -RecentDelta $null `
            -Now $now -ActiveSubagentCount $null)
    $unknownFleetAgentLines = @(Get-OutputLines $unknownFleetWithAgent)
    Assert-Fixture ($unknownFleetAgentLines.Count -eq 3 -and
        $unknownFleetAgentLines[2] -match 'analysis' -and
        $unknownFleetAgentLines[2] -notmatch 'subagents') `
        'An unknown bridge count did not fall back to the hook agent display.'

    $unknownFleet = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
        -SignalState (Get-FixtureSignalState -Phase $null -RecentDelta $null `
            -Now $now -ActiveSubagentCount $null)
    Assert-Fixture (@(Get-OutputLines $unknownFleet).Count -eq 2) `
        'Unknown subagent state made an active/completed claim.'

    $zeroFleet = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
        -SignalState (Get-FixtureSignalState -Phase $null -RecentDelta $null `
            -Now $now -ActiveSubagentCount 0)
    Assert-Fixture (@(Get-OutputLines $zeroFleet).Count -eq 2) `
        'A zero subagent count rendered an active or complete claim.'

    $zeroWithHookAgent = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $agentHook `
        -SignalState (Get-FixtureSignalState -Phase $null -RecentDelta $null `
            -Now $now -ActiveSubagentCount 0)
    $zeroWithHookAgentLines = @(Get-OutputLines $zeroWithHookAgent)
    Assert-Fixture ($zeroWithHookAgentLines.Count -eq 2 -and
        $zeroWithHookAgentLines[2] -notmatch 'analysis|subagents') `
        'A fresh confirmed zero did not suppress stale hook-agent claims.'

    $expiredHookAgent = Get-FixtureHookState -WithActiveTool $false -Now $now
    $expiredHookAgent.activeSubagents = @([ordered]@{
        matchKey = 'expired-agent'
        agentKey = $null
        startedAtMs = $now - 300001
        timingReliable = $true
    })
    $expiredHookFallback = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -BridgeEnabled '0' -HookState $expiredHookAgent -SignalState $signalFleet `
        -PreserveHookTimestamp
    Assert-Fixture (@(Get-OutputLines $expiredHookFallback).Count -eq 2) `
        'An expired hook-agent lifecycle remained visible indefinitely.'

    $invalidFleet = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $now) `
        -SignalState (Get-FixtureSignalState -Phase $null -RecentDelta $null `
            -Now $now -ActiveSubagentCount 17)
    Assert-Fixture (@(Get-OutputLines $invalidFleet).Count -eq 2) `
        'An out-of-range subagent count was rendered.'

    $negativeCountFallback = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $agentHook -SignalState (Get-FixtureSignalState `
            -Phase $null -RecentDelta $null -Now $now -ActiveSubagentCount -1)
    $negativeCountLines = @(Get-OutputLines $negativeCountFallback)
    Assert-Fixture ($negativeCountLines.Count -eq 3 -and
        $negativeCountLines[2] -match 'analysis' -and
        $negativeCountLines[2] -notmatch 'subagents') `
        'A negative bridge count suppressed matching hook fallback.'

    $negativePhase = Get-FixtureSignalState -Phase 'working' -Now $now `
        -ActiveSubagentCount 2
    $negativePhase.phaseAtMs = -1
    $negativePhaseFallback = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $agentHook -SignalState $negativePhase -PreserveSignalTimestamp
    $negativePhaseLines = @(Get-OutputLines $negativePhaseFallback)
    Assert-Fixture ($negativePhaseLines.Count -eq 3 -and
        $negativePhaseLines[2] -match 'analysis' -and
        $negativePhaseLines[2] -notmatch 'subagents|Working') `
        'A negative bridge phase timestamp rendered or suppressed hook fallback.'

    $disabledWithHookAgent = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -BridgeEnabled '0' -HookState $agentHook -SignalState $signalFleet
    $disabledHookLines = @(Get-OutputLines $disabledWithHookAgent)
    Assert-Fixture ($disabledHookLines.Count -eq 3 -and $disabledHookLines[2] -match 'analysis') `
        'Hook agent fallback was not preserved when the bridge was absent.'
    Assert-Fixture ($disabledHookLines[2] -notmatch 'subagents') `
        'Disabled bridge rendered a Fleet count over hook activity.'

    $foreignHook = Get-FixtureHookState -WithActiveTool $false -Now $now
    $foreignHook.sessionId = $foreignSessionId
    $foreignHook.activeSubagents = @([ordered]@{
        matchKey = 'foreign-agent-marker'
        agentKey = $null
        startedAtMs = $now - 7000
        timingReliable = $true
    })
    Write-FixtureJson -Path $foreignHookStatePath -Value $foreignHook
    $foreignOnlyFallback = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -BridgeEnabled '0' -HookState $null -SignalState $null
    $foreignOnlyLines = @(Get-OutputLines $foreignOnlyFallback)
    Assert-Fixture ($foreignOnlyLines.Count -eq 2 -and
        ($foreignOnlyLines -join ' ') -notmatch 'foreign-agent-marker|subagents') `
        'Hook fallback read activity from another session.'
    [System.IO.File]::Delete($foreignHookStatePath)

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

    $endedHookAgent = Get-FixtureHookState -WithActiveTool $false -Now $now
    $endedHookAgent.lastSubagent = [ordered]@{
        matchKey = 'analysis'
        status = 'complete'
        completedAtMs = $now - 1000
        durationMs = 4000
    }
    $endedHookOutput = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -BridgeEnabled '0' -HookState $endedHookAgent -SignalState $null
    $endedHookLines = @(Get-OutputLines $endedHookOutput)
    Assert-Fixture ($endedHookLines.Count -eq 3 -and
        $endedHookLines[2] -match 'analysis ended' -and
        $endedHookLines[2] -notmatch '✓|complete') `
        'A subagent terminal was rendered as a success claim.'

    $fleetWithHookOutcome = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $hookOutcome -SignalState $signalFleet
    $fleetWithHookOutcomeLines = @(Get-OutputLines $fleetWithHookOutcome)
    Assert-Fixture ($fleetWithHookOutcomeLines.Count -eq 3 -and
        $fleetWithHookOutcomeLines[2] -match '2 subagents' -and
        $fleetWithHookOutcomeLines[2] -match 'read') `
        "Recent completed-tool history masked a fresh Fleet count: $($fleetWithHookOutcomeLines -join ' | ')"

    $hookAgentToolOutcome = Get-FixtureHookState -WithActiveTool $false -Now $now
    $hookAgentToolOutcome.lastTool = [ordered]@{
        category = 'agent'
        toolName = 'task'
        target = 'agent work'
        status = 'complete'
        durationMs = 4000
        completedAtMs = $now - 1000
    }
    $fleetWithAgentToolHistory = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $hookAgentToolOutcome -SignalState $signalFleet
    $fleetWithAgentToolLines = @(Get-OutputLines $fleetWithAgentToolHistory)
    Assert-Fixture ($fleetWithAgentToolLines.Count -eq 3 -and
        $fleetWithAgentToolLines[2] -match '2 subagents') `
        'Agent tool history masked a fresh Fleet count.'
    Assert-Fixture ($fleetWithAgentToolLines[2] -notmatch '✓ agent') `
        'Agent tool history duplicated the lifecycle-confirmed Fleet count.'

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

    $staleState = Get-FixtureSignalState -Phase $null -RecentDelta $null `
        -Now ($now - 60000) -ActiveSubagentCount 2
    $staleState.phase = 'complete'
    $staleState.phaseAtMs = $now - 60000
    $staleFallback = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $activeHook -SignalState $staleState -PreserveSignalTimestamp
    $staleLines = @(Get-OutputLines $staleFallback)
    Assert-Fixture ($staleLines.Count -eq 3 -and $staleLines[2] -match 'powershell') `
        'Stale state did not preserve hook activity.'
    Assert-Fixture ($staleLines[2] -notmatch 'Running tool') `
        'Stale phase was rendered.'
    Assert-Fixture ($staleLines[2] -notmatch 'subagents') `
        'Stale Fleet count was rendered.'
    Assert-Fixture ($staleLines[2] -notmatch 'Assistant turn complete') `
        'Stale root-turn completion was rendered.'
    Assert-Fixture ($staleLines[1] -notmatch 'recent \+') `
        'Stale AIC increase was rendered.'

    $duplicateSuppressed = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState $activeHook -SignalState $signalFleet
    $duplicateLines = @(Get-OutputLines $duplicateSuppressed)
    Assert-Fixture ($duplicateLines[2] -match 'powershell' -and
        $duplicateLines[2] -match '2 subagents') `
        'Bridge Fleet count did not coexist with active hook tool activity.'
    Assert-Fixture ($duplicateLines[2] -notmatch 'analysis') `
        'Bridge Fleet count duplicated hook-based agent activity.'

    $completionNow = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $complete = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $completionNow) `
        -SignalState (Get-FixtureSignalState -Phase 'complete' -Now $completionNow)
    $completeLines = @(Get-OutputLines $complete)
    Assert-Fixture ($completeLines.Count -eq 3 -and
        $completeLines[2] -match '✓ Assistant turn complete') `
        "A fresh completed phase was not displayed: $($completeLines -join ' | ')"

    $placeholderNow = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $placeholder = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $placeholderNow) `
        -SignalState (Get-FixtureSignalState -Phase $null -RecentDelta $null -Now $placeholderNow)
    $placeholderLines = @(Get-OutputLines $placeholder)
    Assert-Fixture ($placeholderLines[1] -match "recent $([char]0x2014)") `
        "A fresh bridge without a recent interval did not show the placeholder: $($placeholderLines -join ' | ')"
    Assert-Fixture ($placeholderLines[1] -notmatch 'recent \+') 'Placeholder claimed an increase.'
    $noBridge = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $placeholderNow) -SignalState $null
    Assert-Fixture ((@(Get-OutputLines $noBridge))[1] -notmatch 'recent') `
        'Placeholder appeared without a bridge snapshot.'
    $staleNoRecent = Get-FixtureSignalState -Phase $null -RecentDelta $null -Now ($placeholderNow - 60000)
    $staleOut = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $placeholderNow) `
        -SignalState $staleNoRecent -PreserveSignalTimestamp
    Assert-Fixture ((@(Get-OutputLines $staleOut))[1] -notmatch 'recent') `
        'Placeholder appeared for a stale bridge snapshot.'

    $reliabilityProbe = @'
import { pathToFileURL } from "node:url";
const { createSignalMachine } = await import(pathToFileURL(process.argv[1]));
const sessionId = process.argv[2];
const now = Date.now();
let eventId = 0;
function sample(start, parallel) {
    const machine = createSignalMachine(sessionId, start);
    const send = (type, offset, data = {}) => machine.observe({
        id: `reliability-${++eventId}`, type,
        timestamp: new Date(start + offset).toISOString(), data
    });
    send("session.usage_checkpoint", 1, { totalNanoAiu: 100_000_000_000 });
    send("session.idle", 2);
    send("assistant.turn_start", 3);
    if (parallel) {
        send("tool.execution_start", 4, { toolCallId: "first" });
        send("tool.execution_start", 5, { toolCallId: "second" });
        send("tool.execution_complete", 6, { toolCallId: "second" });
        send("tool.execution_complete", 7, { toolCallId: "first" });
    } else {
        send("assistant.turn_start", 4);
    }
    send("assistant.turn_end", 8);
    send("session.usage_checkpoint", 9, { totalNanoAiu: 106_000_000_000 });
    send("session.idle", 10);
    return machine;
}
const parallel = sample(now - 20, true);
const expired = sample(now - 130_020, true);
expired.heartbeat(now);
const suppressed = sample(now - 130_020, false);
suppressed.heartbeat(now);
const idle = createSignalMachine(sessionId, now - 300_000);
idle.heartbeat(now);
console.log(JSON.stringify({
    parallel: parallel.snapshot(), expired: expired.snapshot(),
    suppressed: suppressed.snapshot(), idle: idle.snapshot()
}));
'@
    $machinePath = Join-Path $repositoryRoot '.github\extensions\hud-signal-bridge\state-machine.mjs'
    $reliabilityJson = & node --input-type=module -e $reliabilityProbe $machinePath $sessionId
    Assert-Fixture ($LASTEXITCODE -eq 0) 'Bridge reliability probe did not complete.'
    $reliabilityStates = ($reliabilityJson -join "`n") | ConvertFrom-Json -AsHashtable
    foreach ($width in @(80, 120, 160)) {
        foreach ($case in @('parallel', 'expired', 'suppressed', 'idle')) {
            $reliabilityOut = Invoke-StatuslineFixture -Width $width -NoColor $true `
                -HookState (Get-FixtureHookState -WithActiveTool $false -Now $placeholderNow) `
                -SignalState $reliabilityStates[$case]
            $reliabilityLines = @(Get-OutputLines $reliabilityOut)
            if ($case -ceq 'parallel') {
                Assert-Fixture ($reliabilityLines[1] -match 'recent \+6\.00 AIU') `
                    "Clean parallel-tool increase was not rendered at width ${width}: $reliabilityOut"
            } else {
                Assert-Fixture ($reliabilityLines[1] -match "recent $([char]0x2014)" -and
                    $reliabilityLines[1] -notmatch 'recent \+|\(overlap\)') `
                    "Idle/expired state lost its neutral placeholder at width ${width}: $reliabilityOut"
                Assert-Fixture ($reliabilityLines.Count -eq 2) `
                    "Idle/expired state fabricated an activity line at width ${width}: $reliabilityOut"
            }
            Assert-Fixture (@($reliabilityLines | Where-Object { $_.Length -gt $width }).Count -eq 0) `
                "Reliability state exceeded width ${width}: $reliabilityOut"
        }
    }

    $suppressed = Get-FixtureSignalState -Phase $null -RecentDelta $null -Now $placeholderNow
    $suppressed['recentAtMs'] = $placeholderNow - 1000
    $suppressed['recentSuppressedReason'] = 'overlap'
    $suppressedOut = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $placeholderNow) `
        -SignalState $suppressed
    Assert-Fixture ((@(Get-OutputLines $suppressedOut))[1] -match "recent $([char]0x2014) \(overlap\)") `
        "Suppression reason was not shown: $suppressedOut"
    $suppressed['recentSuppressedReason'] = 'early-usage'
    $suppressedOut = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $placeholderNow) `
        -SignalState $suppressed
    Assert-Fixture ((@(Get-OutputLines $suppressedOut))[1] -match "recent $([char]0x2014) \(early usage\)") `
        "Hyphenated suppression reason was not humanized: $suppressedOut"
    $suppressed['recentSuppressedReason'] = 'secret-token'
    $suppressedOut = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $placeholderNow) `
        -SignalState $suppressed
    Assert-Fixture ((@(Get-OutputLines $suppressedOut))[1] -notmatch 'recent|secret') `
        'An unapproved suppression reason was rendered.'
    $suppressed['recentSuppressedReason'] = 'overlap'
    $suppressed['recentAtMs'] = $placeholderNow - 130000
    $suppressedOut = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $placeholderNow) `
        -SignalState $suppressed -PreserveSignalTimestamp
    $expiredLine = (@(Get-OutputLines $suppressedOut))[1]
    Assert-Fixture ($expiredLine -match "recent $([char]0x2014)" -and $expiredLine -notmatch 'overlap') `
        "Expired suppression reason was still shown: $suppressedOut"
    $suppressed['recentIncreaseNanoAiu'] = 5
    $suppressed['recentAtMs'] = $placeholderNow - 1000
    $suppressedOut = Invoke-StatuslineFixture -Width 120 -NoColor $true `
        -HookState (Get-FixtureHookState -WithActiveTool $false -Now $placeholderNow) `
        -SignalState $suppressed
    Assert-Fixture ((@(Get-OutputLines $suppressedOut))[1] -notmatch 'recent') `
        'A snapshot with both an increase and a suppression reason was accepted.'

    $unknownHook = Get-FixtureHookState -WithActiveTool $false -Now $placeholderNow
    $unknownHook.lastSubagent = [ordered]@{
        matchKey = 'unknown-outcome'; status = 'unknown'; durationMs = 3000
        completedAtMs = $placeholderNow - 1000
    }
    $unknownOut = Invoke-StatuslineFixture -Width 120 -NoColor $true -BridgeEnabled '0' `
        -HookState $unknownHook -SignalState $null
    $unknownText = (@(Get-OutputLines $unknownOut)) -join ' | '
    Assert-Fixture ($unknownText -match 'ended' -and $unknownText -notmatch 'stopped' -and
        $unknownText -notmatch '\? ') `
        "Unknown subagent outcome did not use the neutral ended label: $unknownText"

    Test-AtomicSignalSnapshots
    'StatuslineSignalFixturesPass=True'
    'Widths=80,120,160; ANSI/NO_COLOR=passed'
    'ActiveGlyphs=yellow-for-bridge-and-hook-tools/agents; labels=white; NO_COLOR=unchanged'
    'RecentPlaceholder=fresh-bridge-only; UnknownOutcome=neutral-ended'
    'RecentReliability=parallel-tools:+6.00-AIU; idle/expired-value/expired-reason:neutral-placeholder; Widths=80,120,160'
    'FleetCounts=1/2,confirmed-zero,unknown,5-minute hook lease,matching-session fallback,concurrent-session isolation'
    'TerminalLabel=ended-not-success; RootPhase=assistant-turn-complete'
    'IdleLines=2; ActiveLines=3; HookFallback=passed'
    'AbsentDisabledStaleMalformedOversize=passed'
} finally {
    foreach ($path in @(
        $hookStatePath,
        $foreignHookStatePath,
        $signalStatePath,
        $foreignSignalStatePath,
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
