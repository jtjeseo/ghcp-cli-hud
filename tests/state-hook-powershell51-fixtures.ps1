$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Run this fixture with Windows PowerShell 5.1.'
}

function Assert-Fixture {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) { throw $Message }
}

function Invoke-HookFixture {
    param([string]$Event, [string]$Payload)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($powershellPath)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -File "' +
        $hookPath + '" -Event ' + $Event
    $startInfo.EnvironmentVariables['COPILOT_HOME'] = $testHome
    $startInfo.EnvironmentVariables['COPILOT_RAW_PAYLOAD_CAPTURE'] = '0'

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    try {
        $process.StandardInput.Write($Payload)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(15000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw 'A hook fixture timed out.'
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        return [pscustomobject]@{
            Event = $Event
            ExitCode = $process.ExitCode
            Stdout = $stdout
            Stderr = $stderr
        }
    } finally {
        $process.Dispose()
    }
}

function Assert-HookSucceeded {
    param([object]$Result)

    if ($Result.ExitCode -ne 0) {
        $errorId = [regex]::Match(
            $Result.Stderr,
            '(?m)FullyQualifiedErrorId\s*:\s*([^\r\n]+)'
        ).Groups[1].Value
        'HookFailureDiagnostic=event={0};exit={1};errorId={2};stdoutChars={3};stderrChars={4}' -f `
            $Result.Event, $Result.ExitCode, $errorId,
            $Result.Stdout.Length, $Result.Stderr.Length
    }
    Assert-Fixture ($Result.ExitCode -eq 0) `
        "Valid hook event $($Result.Event) returned nonzero."
    Assert-Fixture ([string]::IsNullOrEmpty($Result.Stdout)) `
        'A valid hook event wrote to stdout.'
    Assert-Fixture ([string]::IsNullOrEmpty($Result.Stderr)) `
        'A valid hook event wrote to stderr.'
}

function Read-HookState {
    param([string]$Path)

    return ConvertFrom-Json -InputObject (
        [System.IO.File]::ReadAllText($Path)
    ) -ErrorAction Stop
}

$powershellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
$hookPath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\hooks\state-hook.ps1')
)
$testHome = Join-Path $env:TEMP (
    'copilot-hook-ps51-' + [guid]::NewGuid().ToString('N')
)
$sessionId = 'hook-fixture-' + [guid]::NewGuid().ToString('N')
$otherSessionId = 'other-fixture-session'
$stateDirectory = Join-Path $testHome 'state'
$statePath = Join-Path $stateDirectory "hud-state-$sessionId.json"
$framePath = Join-Path $stateDirectory "statusline-animation-$sessionId.frame"
$failurePath = Join-Path $stateDirectory 'hud-hook-failure.log'
$otherStatePath = Join-Path $stateDirectory "hud-state-$otherSessionId.json"
$otherFramePath = Join-Path $stateDirectory "statusline-animation-$otherSessionId.frame"
$bridgeDirectory = Join-Path $stateDirectory 'hud-signal-bridge'
$aicDirectory = Join-Path $stateDirectory 'hud-aic-validation'
$bridgePath = Join-Path $bridgeDirectory "hud-signal-$sessionId.json"
$aicPath = Join-Path $aicDirectory 'validation.json'
$aicLockPath = Join-Path $aicDirectory 'validation.lock'
$sentinel = 'HOOK-PAYLOAD-DO-NOT-LOG'

try {
    New-Item -ItemType Directory -Path @(
        $stateDirectory,
        $bridgeDirectory,
        $aicDirectory
    ) -Force | Out-Null

    $now = [DateTimeOffset]::UtcNow.ToString('o')
    $sessionStart = [ordered]@{
        sessionId = $sessionId
        timestamp = $now
        cwd = ''
        source = 'fixture'
    }
    $result = Invoke-HookFixture -Event 'sessionStart' -Payload (
        ConvertTo-Json -InputObject $sessionStart -Compress
    )
    Assert-HookSucceeded $result
    Assert-Fixture ([System.IO.File]::Exists($statePath)) `
        'sessionStart did not create hook state.'

    [System.IO.File]::WriteAllText($otherStatePath, '{"keep":true}')
    [System.IO.File]::WriteAllText($otherFramePath, 'keep')
    [System.IO.File]::WriteAllText($bridgePath, '{"keep":true}')
    [System.IO.File]::WriteAllText($aicPath, '{"keep":true}')
    [System.IO.File]::WriteAllText($aicLockPath, '')

    $toolPayload = [ordered]@{
        sessionId = $sessionId
        timestamp = $now
        toolName = 'powershell'
        toolArgs = [ordered]@{ path = 'fixture.txt' }
    }
    $result = Invoke-HookFixture -Event 'preToolUse' -Payload (
        ConvertTo-Json -InputObject $toolPayload -Depth 4 -Compress
    )
    Assert-HookSucceeded $result
    $state = Read-HookState -Path $statePath
    $activeToolCount = @($state.activeTools).Count
    if ($activeToolCount -ne 1) {
        $failureMarker = if ([System.IO.File]::Exists($failurePath)) {
            [System.IO.File]::ReadAllText($failurePath).Trim()
        } else {
            'absent'
        }
        'PreToolUseDiagnostic=activeCount={0};failureMarker={1}' -f `
            $activeToolCount, $failureMarker
    }
    Assert-Fixture ($activeToolCount -eq 1) `
        'preToolUse did not persist an active tool.'

    $result = Invoke-HookFixture -Event 'postToolUse' -Payload (
        ConvertTo-Json -InputObject $toolPayload -Depth 4 -Compress
    )
    Assert-HookSucceeded $result
    $state = Read-HookState -Path $statePath
    Assert-Fixture (@($state.activeTools).Count -eq 0 -and
        @($state.recentTools).Count -eq 1) `
        'postToolUse did not read and replace stored state.'

    $result = Invoke-HookFixture -Event 'preToolUse' -Payload (
        ConvertTo-Json -InputObject $toolPayload -Depth 4 -Compress
    )
    Assert-HookSucceeded $result
    $result = Invoke-HookFixture -Event 'postToolUseFailure' -Payload (
        ConvertTo-Json -InputObject $toolPayload -Depth 4 -Compress
    )
    Assert-HookSucceeded $result
    $state = Read-HookState -Path $statePath
    Assert-Fixture (@($state.recentTools | Where-Object {
        $_.status -eq 'failed'
    }).Count -eq 1) 'postToolUseFailure did not persist a failed outcome.'

    $errorPayload = [ordered]@{
        sessionId = $sessionId
        timestamp = $now
        errorContext = 'tool_execution'
        recoverable = $true
    }
    $result = Invoke-HookFixture -Event 'errorOccurred' -Payload (
        ConvertTo-Json -InputObject $errorPayload -Compress
    )
    Assert-HookSucceeded $result
    $state = Read-HookState -Path $statePath
    Assert-Fixture ($state.lastError.context -eq 'tool_execution') `
        'errorOccurred did not persist its allowlisted context.'

    $subagentPayload = [ordered]@{
        sessionId = $sessionId
        timestamp = $now
        agentName = 'fixture-agent'
        agentId = 'fixture-agent-id'
        stopReason = 'end_turn'
    }
    $result = Invoke-HookFixture -Event 'subagentStart' -Payload (
        ConvertTo-Json -InputObject $subagentPayload -Compress
    )
    Assert-HookSucceeded $result
    $result = Invoke-HookFixture -Event 'subagentStop' -Payload (
        ConvertTo-Json -InputObject $subagentPayload -Compress
    )
    Assert-HookSucceeded $result
    $state = Read-HookState -Path $statePath
    Assert-Fixture (@($state.activeSubagents).Count -eq 0 -and
        $state.lastSubagent.status -eq 'complete') `
        'Subagent hooks did not read and replace stored state.'
    $temporaryWrites = @(
        Get-ChildItem -LiteralPath $stateDirectory -File -Filter '*.tmp'
    )
    $replacementBackups = @(
        Get-ChildItem -LiteralPath $stateDirectory -File -Filter '*.bak'
    )
    Assert-Fixture ($temporaryWrites.Count -eq 0 -and
        $replacementBackups.Count -eq 0) `
        'Successful state replacement left a temporary or backup file.'

    [System.IO.File]::WriteAllText($framePath, 'remove')
    $malformedPayload = '{"sessionId":"' + $sessionId +
        '","value":"' + $sentinel + '"'
    $result = Invoke-HookFixture -Event 'sessionEnd' -Payload $malformedPayload
    Assert-Fixture ($result.ExitCode -eq 0) `
        'Malformed hook input returned nonzero.'
    Assert-Fixture ([string]::IsNullOrEmpty($result.Stdout) -and
        [string]::IsNullOrEmpty($result.Stderr)) `
        'Malformed hook input reached the hook host output streams.'
    Assert-Fixture ([System.IO.File]::Exists($statePath) -and
        [System.IO.File]::Exists($framePath)) `
        'Malformed hook input performed partial session cleanup.'
    Assert-Fixture ([System.IO.File]::Exists($failurePath)) `
        'Malformed hook input was not reported by the sanitized marker.'
    $failureText = [System.IO.File]::ReadAllText($failurePath)
    Assert-Fixture ($failureText.Trim() -ceq 'hook-state-failure' -and
        $failureText -notmatch [regex]::Escape($sentinel) -and
        $failureText.Length -le 64) `
        'The hook failure marker was not bounded and sanitized.'

    $lockedState = [System.IO.FileStream]::new(
        $statePath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::None
    )
    try {
        $lockedPayload = [ordered]@{
            sessionId = $sessionId
            timestamp = $now
            cwd = $sentinel
            reason = 'exit'
        }
        $result = Invoke-HookFixture -Event 'sessionEnd' -Payload (
            ConvertTo-Json -InputObject $lockedPayload -Compress
        )
        Assert-Fixture ($result.ExitCode -eq 0 -and
            [string]::IsNullOrEmpty($result.Stdout) -and
            [string]::IsNullOrEmpty($result.Stderr)) `
            'A cleanup failure reached the hook host or returned nonzero.'
        Assert-Fixture ([System.IO.File]::Exists($statePath) -and
            [System.IO.File]::Exists($framePath)) `
            'A locked cleanup partially removed session files.'
        $failureText = [System.IO.File]::ReadAllText($failurePath)
        Assert-Fixture ($failureText.Trim() -ceq 'hook-state-failure' -and
            $failureText -notmatch [regex]::Escape($sentinel) -and
            $failureText.Length -le 64) `
            'A cleanup failure was not reported as a sanitized marker.'
    } finally {
        $lockedState.Dispose()
    }

    $sessionEnd = [ordered]@{
        sessionId = $sessionId
        timestamp = $now
        cwd = ''
        reason = 'exit'
    }
    $result = Invoke-HookFixture -Event 'sessionEnd' -Payload (
        ConvertTo-Json -InputObject $sessionEnd -Compress
    )
    Assert-HookSucceeded $result
    Assert-Fixture (-not [System.IO.File]::Exists($statePath) -and
        -not [System.IO.File]::Exists($framePath)) `
        'sessionEnd did not remove the matching hook state and animation frame.'
    Assert-Fixture ([System.IO.File]::Exists($otherStatePath) -and
        [System.IO.File]::Exists($otherFramePath)) `
        'sessionEnd removed another session''s hook state.'
    Assert-Fixture ([System.IO.File]::Exists($bridgePath) -and
        [System.IO.File]::Exists($aicPath) -and
        [System.IO.File]::Exists($aicLockPath)) `
        'sessionEnd removed bridge or AIC validation state.'
    Assert-Fixture (-not [System.IO.File]::Exists($failurePath)) `
        'A successful sessionEnd did not clear the failure marker.'

    'PowerShell51HookFixtures=passed;Events=sessionStart,preToolUse,postToolUse,postToolUseFailure,errorOccurred,subagentStart,subagentStop,sessionEnd;Failure=reported-sanitized-fail-open;UnrelatedState=preserved'
} finally {
    if (Test-Path -LiteralPath $testHome) {
        Remove-Item -LiteralPath $testHome -Recurse -Force
    }
}
