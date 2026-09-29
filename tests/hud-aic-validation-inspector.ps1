$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$inspectorPath = Join-Path $repositoryRoot 'scripts\Show-AicValidation.ps1'
$observerPath = Join-Path $repositoryRoot 'scripts\Wait-AicValidation.ps1'
$powershellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
$copilotHomeFixture = Join-Path $env:TEMP (
    'copilot-hud-session-aic-inspector-' + [guid]::NewGuid().ToString('N')
)
$bridgeDirectory = Join-Path $copilotHomeFixture 'state\hud-signal-bridge'
$validationDirectory = Join-Path $copilotHomeFixture 'state\hud-aic-validation'
$lockPath = Join-Path $validationDirectory 'validation.lock'
$fixtureSessionId = 'aic-inspector-fixture'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Write-FixtureJson {
    param([string]$Path, [object]$Value)

    [System.IO.File]::WriteAllText(
        $Path,
        (ConvertTo-Json -InputObject $Value -Depth 8 -Compress),
        $utf8
    )
}

function Invoke-FixtureInspector {
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(
            & $powershellPath -NoProfile -File $inspectorPath `
                -CopilotHome $copilotHomeFixture 2>&1
        )
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = $output -join "`n"
    }
}

function Start-FixtureObserver {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($powershellPath)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = '-NoLogo -NoProfile -File "' + $observerPath + '"'
    $startInfo.EnvironmentVariables['COPILOT_HOME'] = $copilotHomeFixture

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    return $process
}

function Read-FixtureObserverUntilMarker {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string[]]$Markers,
        [int]$TimeoutSeconds = 15
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $readTask = $Process.StandardOutput.ReadLineAsync()
        while (-not $readTask.IsCompleted -and
            [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        if (-not $readTask.IsCompleted) {
            break
        }
        $line = $readTask.Result
        if ($null -eq $line) {
            break
        }
        $lines.Add($line)
        if ($line -cin $Markers) {
            return [pscustomobject]@{
                Matched = $line
                Lines = @($lines.ToArray())
            }
        }
    }
    return [pscustomobject]@{
        Matched = $null
        Lines = @($lines.ToArray())
    }
}

function Complete-FixtureObserver {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [string[]]$PriorLines = @()
    )

    try {
        if (-not $Process.WaitForExit(15000)) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            throw 'The isolated AIC observer fixture timed out.'
        }
        $tail = $Process.StandardOutput.ReadToEnd()
        $stderr = $Process.StandardError.ReadToEnd()
        $tailLines = @($tail -split "`r?`n" | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        })
        return [pscustomobject]@{
            ExitCode = $Process.ExitCode
            Text = (@($PriorLines) + $tailLines) -join "`n"
            Stderr = $stderr
        }
    } finally {
        $Process.Dispose()
    }
}

function New-FixtureBaselineRecord {
    param(
        [int]$RootTurns = 1,
        [long]$CheckpointNanoAiu = 7000000000
    )

    return [ordered]@{
        version = 1
        validity = 'suppressed'
        reason = 'missing-baseline'
        baselineNanoAiu = $null
        finalCheckpointNanoAiu = $CheckpointNanoAiu
        computedDifferenceNanoAiu = $null
        displayedIncreaseNanoAiu = $null
        eventOrder = [ordered]@{
            bridgeSessionMatched = $true
            baselineBeforeInterval = $false
            rootTurnsStarted = $RootTurns
            rootTurnsEnded = $RootTurns
            rootTurnCountCapped = $false
            rootTurnsClosed = $true
            finalCheckpointAccepted = $false
            finalCheckpointAfterTurnEnd = $true
            idleAfterFinalCheckpoint = $true
            toolCallsClosed = $true
            overlapObserved = $false
            interruptionObserved = $false
            resetObserved = $false
            counterResetObserved = $false
            unverifiedSubagentActivity = $false
        }
    }
}

function New-FixtureCheckRecord {
    param(
        [long]$BaselineNanoAiu = 7000000000,
        [long]$FinalCheckpointNanoAiu = 13390000000
    )

    $difference = $FinalCheckpointNanoAiu - $BaselineNanoAiu
    return [ordered]@{
        version = 1
        validity = 'valid'
        reason = 'valid'
        baselineNanoAiu = $BaselineNanoAiu
        finalCheckpointNanoAiu = $FinalCheckpointNanoAiu
        computedDifferenceNanoAiu = $difference
        displayedIncreaseNanoAiu = $difference
        eventOrder = $validOrder
    }
}

function Set-FixtureBridgeRecent {
    param([AllowNull()][object]$RecentIncreaseNanoAiu)

    $time = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $bridge.updatedAtMs = $time
    $bridge.phaseAtMs = $time
    $bridge.recentIncreaseNanoAiu = $RecentIncreaseNanoAiu
    $bridge.recentSuppressedReason = $null
    $bridge.recentAtMs = if ($null -eq $RecentIncreaseNanoAiu) {
        $null
    } else {
        $time
    }
    Write-FixtureJson -Path $bridgePath -Value $bridge
}

function Start-FixtureObserverAtBaseline {
    param([Parameter(Mandatory)][object]$BaselineRecord)

    [System.IO.File]::SetLastWriteTimeUtc(
        $validationPath,
        [DateTime]::UtcNow.AddMinutes(-1)
    )
    Set-FixtureBridgeRecent -RecentIncreaseNanoAiu $null
    $process = Start-FixtureObserver
    $ready = Read-FixtureObserverUntilMarker -Process $process -Markers @(
        'AIC observer ready. After AIC-BASELINE completes, press Enter to verify its checkpoint boundary.'
    )
    if ($null -eq $ready.Matched) {
        $null = Complete-FixtureObserver -Process $process `
            -PriorLines $ready.Lines
        throw 'The isolated AIC observer did not reach its first gate.'
    }
    Write-FixtureJson -Path $validationPath -Value $BaselineRecord
    $process.StandardInput.WriteLine()
    $process.StandardInput.Flush()
    return [pscustomobject]@{
        Process = $process
        PriorLines = $ready.Lines
    }
}

function Assert-Fixture {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

try {
    New-Item -ItemType Directory -Path $bridgeDirectory, $validationDirectory `
        -Force | Out-Null
    [System.IO.File]::WriteAllText($lockPath, '', $utf8)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $bridgePath = Join-Path $bridgeDirectory (
        'hud-signal-{0}.json' -f $fixtureSessionId
    )
    $validationPath = Join-Path $validationDirectory 'validation.json'
    $bridge = [ordered]@{
        version = 1
        sessionId = $fixtureSessionId
        updatedAtMs = $now
        phase = 'complete'
        phaseAtMs = $now
        recentIncreaseNanoAiu = 6390000000
        recentAtMs = $now
        recentSuppressedReason = $null
        activeSubagentCount = 0
    }
    $validOrder = [ordered]@{
        bridgeSessionMatched = $true
        baselineBeforeInterval = $true
        rootTurnsStarted = 1
        rootTurnsEnded = 1
        rootTurnCountCapped = $false
        rootTurnsClosed = $true
        finalCheckpointAccepted = $true
        finalCheckpointAfterTurnEnd = $true
        idleAfterFinalCheckpoint = $true
        toolCallsClosed = $true
        overlapObserved = $false
        interruptionObserved = $false
        resetObserved = $false
        counterResetObserved = $false
        unverifiedSubagentActivity = $false
    }
    $validation = [ordered]@{
        version = 1
        validity = 'valid'
        reason = 'valid'
        baselineNanoAiu = 1000000000
        finalCheckpointNanoAiu = 7390000000
        computedDifferenceNanoAiu = 6390000000
        displayedIncreaseNanoAiu = 6390000000
        eventOrder = $validOrder
    }
    Write-FixtureJson -Path $bridgePath -Value $bridge
    Write-FixtureJson -Path $validationPath -Value $validation

    $validOutput = Invoke-FixtureInspector
    Assert-Fixture ($validOutput.ExitCode -eq 0) `
        'The inspector rejected a valid matching-session AIC record.'
    foreach ($expected in @(
        'sameSession=verified',
        'validity=valid',
        'reason=valid',
        'baselineNanoAiu=1000000000',
        'finalCheckpointNanoAiu=7390000000',
        'computedDifferenceNanoAiu=6390000000',
        'displayedIncreaseNanoAiu=6390000000',
        'expectedHudText=recent +6.39 AIU',
        'matchesBridgeRecentValue=True',
        'bridgeFreshForRenderer=True',
        'recentValueWithinRetention=True'
    )) {
        Assert-Fixture ($validOutput.Text.Contains($expected)) `
            'The inspector omitted a required sanitized AIC value.'
    }
    Assert-Fixture (-not $validOutput.Text.Contains($fixtureSessionId)) `
        'The inspector printed a session identifier.'
    Assert-Fixture (-not $validOutput.Text.Contains($copilotHomeFixture)) `
        'The inspector printed a COPILOT_HOME path.'

    $legacyBridge = [ordered]@{}
    foreach ($key in $bridge.Keys) {
        if ($key -cne 'recentSuppressedReason') { $legacyBridge[$key] = $bridge[$key] }
    }
    Write-FixtureJson -Path $bridgePath -Value $legacyBridge
    Assert-Fixture ((Invoke-FixtureInspector).ExitCode -eq 0) `
        'The inspector rejected a legacy bridge snapshot.'
    $bridge.recentSuppressedReason = 'overlap'
    Write-FixtureJson -Path $bridgePath -Value $bridge
    Assert-Fixture ((Invoke-FixtureInspector).ExitCode -ne 0) `
        'The inspector accepted both a delta and a suppression reason.'
    $bridge.recentSuppressedReason = $null
    Write-FixtureJson -Path $bridgePath -Value $bridge

    $validation.eventOrder.rootTurnCountCapped = $true
    Write-FixtureJson -Path $validationPath -Value $validation
    $cappedOutput = Invoke-FixtureInspector
    Assert-Fixture ($cappedOutput.ExitCode -ne 0) `
        'The inspector accepted an event-order record with capped root turns.'
    $validation.eventOrder.rootTurnCountCapped = $false
    Write-FixtureJson -Path $validationPath -Value $validation

    $bridge.recentIncreaseNanoAiu = $null
    $bridge.recentAtMs = $now
    $bridge.recentSuppressedReason = 'interrupted'
    $validation.validity = 'suppressed'
    $validation.reason = 'interruption'
    $validation.baselineNanoAiu = 100
    $validation.finalCheckpointNanoAiu = 120
    $validation.computedDifferenceNanoAiu = 20
    $validation.displayedIncreaseNanoAiu = $null
    $validation.eventOrder = [ordered]@{
        bridgeSessionMatched = $true
        baselineBeforeInterval = $true
        rootTurnsStarted = 1
        rootTurnsEnded = 1
        rootTurnCountCapped = $false
        rootTurnsClosed = $true
        finalCheckpointAccepted = $false
        finalCheckpointAfterTurnEnd = $true
        idleAfterFinalCheckpoint = $true
        toolCallsClosed = $true
        overlapObserved = $false
        interruptionObserved = $true
        resetObserved = $false
        counterResetObserved = $false
        unverifiedSubagentActivity = $false
    }
    Write-FixtureJson -Path $bridgePath -Value $bridge
    Write-FixtureJson -Path $validationPath -Value $validation
    $suppressedOutput = Invoke-FixtureInspector
    Assert-Fixture ($suppressedOutput.ExitCode -eq 0) `
        'The inspector rejected a valid suppressed AIC record.'
    Assert-Fixture ($suppressedOutput.Text.Contains('validity=suppressed')) `
        'The inspector did not identify a suppressed interval.'
    Assert-Fixture ($suppressedOutput.Text.Contains('reason=interruption')) `
        'The inspector did not report the categorical suppression reason.'
    Assert-Fixture ($suppressedOutput.Text.Contains('expectedHudText=absent')) `
        'The inspector displayed a suppressed AIC increase.'
    Assert-Fixture ($suppressedOutput.Text.Contains('displayedIncreaseNanoAiu=null')) `
        'The suppressed interval retained a displayable increase.'
    Assert-Fixture ($suppressedOutput.Text.Contains('matchesBridgeRecentValue=False')) `
        'Two null recent values were incorrectly treated as a match.'

    $bridge.recentSuppressedReason = 'unapproved-text'
    Write-FixtureJson -Path $bridgePath -Value $bridge
    Assert-Fixture ((Invoke-FixtureInspector).ExitCode -ne 0) `
        'The inspector accepted an unapproved suppression reason.'
    $bridge.recentSuppressedReason = 'interrupted'
    $bridge.recentAtMs = $null
    Write-FixtureJson -Path $bridgePath -Value $bridge
    Assert-Fixture ((Invoke-FixtureInspector).ExitCode -ne 0) `
        'The inspector accepted a suppression reason without a timestamp.'
    $bridge.recentSuppressedReason = $null
    Write-FixtureJson -Path $bridgePath -Value $bridge

    $baselineRecord = New-FixtureBaselineRecord
    $observer = Start-FixtureObserverAtBaseline -BaselineRecord $baselineRecord
    $baselineGate = Read-FixtureObserverUntilMarker `
        -Process $observer.Process `
        -Markers @(
            'Baseline ready; AIC-CHECK may be sent.',
            'Stop; baseline not established.'
        )
    Assert-Fixture ($baselineGate.Matched -ceq
        'Baseline ready; AIC-CHECK may be sent.') `
        'The observer did not accept a clean first-interval checkpoint.'
    Assert-Fixture (($baselineGate.Lines -join "`n").Contains(
        'Baseline checkpoint B=7000000000'
    )) 'The observer did not show the accepted numeric baseline.'
    Assert-Fixture (($baselineGate.Lines -join "`n").Contains(
        'sameSession=verified'
    )) 'The baseline gate did not verify the matching session.'
    Assert-Fixture (($baselineGate.Lines -join "`n").Contains(
        'matchesBridgeRecentValue=False'
    )) 'The baseline gate treated two null recent values as a match.'

    $baselineWriteUtc = [System.IO.File]::GetLastWriteTimeUtc($validationPath)
    $pendingValidation = [ordered]@{
        version = 1
        validity = 'pending'
        reason = 'baseline-accepted'
        baselineNanoAiu = 7000000000
        finalCheckpointNanoAiu = $null
        computedDifferenceNanoAiu = $null
        displayedIncreaseNanoAiu = $null
        eventOrder = [ordered]@{
            bridgeSessionMatched = $true
            baselineBeforeInterval = $true
            rootTurnsStarted = 0
            rootTurnsEnded = 0
            rootTurnCountCapped = $false
            rootTurnsClosed = $false
            finalCheckpointAccepted = $false
            finalCheckpointAfterTurnEnd = $false
            idleAfterFinalCheckpoint = $false
            toolCallsClosed = $true
            overlapObserved = $false
            interruptionObserved = $false
            resetObserved = $false
            counterResetObserved = $false
            unverifiedSubagentActivity = $false
        }
    }
    Write-FixtureJson -Path $validationPath -Value $pendingValidation
    Set-FixtureBridgeRecent -RecentIncreaseNanoAiu 6390000000
    Start-Sleep -Milliseconds 300
    $finalValidation = New-FixtureCheckRecord
    Write-FixtureJson -Path $validationPath -Value $finalValidation
    [System.IO.File]::SetLastWriteTimeUtc(
        $validationPath,
        $baselineWriteUtc.AddSeconds(1)
    )
    $observer.Process.StandardInput.WriteLine()
    $observer.Process.StandardInput.Close()
    $stageOnePriorLines = @($observer.PriorLines) + @($baselineGate.Lines)
    $twoStageOutput = Complete-FixtureObserver `
        -Process $observer.Process `
        -PriorLines $stageOnePriorLines
    Assert-Fixture ($twoStageOutput.ExitCode -eq 0 -and
        [string]::IsNullOrEmpty($twoStageOutput.Stderr)) `
        'The observer did not complete both AIC validation stages cleanly.'
    foreach ($expected in @(
        'Baseline checkpoint B=7000000000',
        'Baseline ready; AIC-CHECK may be sent.',
        'sameSession=verified',
        'baselineNanoAiu=7000000000',
        'computedDifferenceNanoAiu=6390000000',
        'displayedIncreaseNanoAiu=6390000000',
        'expectedHudText=recent +6.39 AIU',
        'matchesBridgeRecentValue=True',
        'bridgeFreshForRenderer=True',
        'recentValueWithinRetention=True',
        'AIC comparison checks=verified; baseline B=7000000000'
    )) {
        Assert-Fixture ($twoStageOutput.Text.Contains($expected)) `
            'The two-stage observer omitted a required sanitized acceptance value.'
    }
    Assert-Fixture (-not $twoStageOutput.Text.Contains($fixtureSessionId) -and
        -not $twoStageOutput.Text.Contains($copilotHomeFixture)) `
        'The two-stage observer printed an identifier or home path.'

    $groupedObserver = Start-FixtureObserverAtBaseline `
        -BaselineRecord (New-FixtureBaselineRecord -RootTurns 2)
    $groupedGate = Read-FixtureObserverUntilMarker `
        -Process $groupedObserver.Process `
        -Markers @(
            'Baseline ready; AIC-CHECK may be sent.',
            'Stop; baseline not established.'
        )
    $groupedOutput = Complete-FixtureObserver `
        -Process $groupedObserver.Process `
        -PriorLines (@($groupedObserver.PriorLines) + @($groupedGate.Lines))
    Assert-Fixture ($groupedGate.Matched -ceq
        'Stop; baseline not established.') `
        'The observer accepted the prior grouped two-turn missing-baseline case.'
    Assert-Fixture (-not $groupedOutput.Text.Contains(
        'Baseline ready; AIC-CHECK may be sent.'
    ) -and -not $groupedOutput.Text.Contains('AIC-CHECK may be sent')) `
        'The failed baseline gate advertised the next prompt.'

    $mismatchObserver = Start-FixtureObserverAtBaseline `
        -BaselineRecord (New-FixtureBaselineRecord)
    $mismatchGate = Read-FixtureObserverUntilMarker `
        -Process $mismatchObserver.Process `
        -Markers @(
            'Baseline ready; AIC-CHECK may be sent.',
            'Stop; baseline not established.'
        )
    Assert-Fixture ($mismatchGate.Matched -ceq
        'Baseline ready; AIC-CHECK may be sent.') `
        'The baseline-mismatch fixture did not pass stage one.'
    $mismatchBaselineWriteUtc = [System.IO.File]::GetLastWriteTimeUtc(
        $validationPath
    )
    Set-FixtureBridgeRecent -RecentIncreaseNanoAiu 6390000000
    $mismatchedCheck = New-FixtureCheckRecord `
        -BaselineNanoAiu 7000000001 `
        -FinalCheckpointNanoAiu 13390000001
    Write-FixtureJson -Path $validationPath -Value $mismatchedCheck
    [System.IO.File]::SetLastWriteTimeUtc(
        $validationPath,
        $mismatchBaselineWriteUtc.AddSeconds(1)
    )
    $mismatchObserver.Process.StandardInput.WriteLine()
    $mismatchObserver.Process.StandardInput.Close()
    $mismatchOutput = Complete-FixtureObserver `
        -Process $mismatchObserver.Process `
        -PriorLines (@($mismatchObserver.PriorLines) + @($mismatchGate.Lines))
    Assert-Fixture ($mismatchOutput.Text.Contains(
        'Stop; AIC-CHECK did not satisfy the baseline or acceptance checks; inconclusive.'
    ) -and -not $mismatchOutput.Text.Contains('AIC comparison checks=verified')) `
        'The observer accepted a new record whose baseline differed from B.'

    $noNewRecordObserver = Start-FixtureObserverAtBaseline `
        -BaselineRecord (New-FixtureBaselineRecord)
    $noNewRecordGate = Read-FixtureObserverUntilMarker `
        -Process $noNewRecordObserver.Process `
        -Markers @(
            'Baseline ready; AIC-CHECK may be sent.',
            'Stop; baseline not established.'
        )
    Assert-Fixture ($noNewRecordGate.Matched -ceq
        'Baseline ready; AIC-CHECK may be sent.') `
        'The no-new-record fixture did not pass stage one.'
    $noNewRecordObserver.Process.StandardInput.WriteLine()
    $noNewRecordObserver.Process.StandardInput.Close()
    $noNewRecordOutput = Complete-FixtureObserver `
        -Process $noNewRecordObserver.Process `
        -PriorLines (@($noNewRecordObserver.PriorLines) + @($noNewRecordGate.Lines))
    Assert-Fixture ($noNewRecordOutput.Text.Contains(
        'Stop; no new final AIC-CHECK record was observed; inconclusive.'
    )) 'The observer accepted the unchanged baseline record as a new check.'

    $secondSessionPath = Join-Path $bridgeDirectory 'hud-signal-other-session.json'
    Write-FixtureJson -Path $secondSessionPath -Value ([ordered]@{
        version = 1
        sessionId = 'other-fixture-session'
        updatedAtMs = $now
        phase = $null
        phaseAtMs = $null
        recentIncreaseNanoAiu = $null
        recentAtMs = $null
        activeSubagentCount = $null
    })
    $ambiguousOutput = Invoke-FixtureInspector
    Assert-Fixture ($ambiguousOutput.ExitCode -ne 0) `
        'The inspector selected among multiple bridge sessions.'

    'AicValidationTwoStagePass=True; baselineBoundary=verified; groupedTurns=stopped; newBaselinePair=verified; nullMatch=refused'
} finally {
    if (Test-Path -LiteralPath $copilotHomeFixture -PathType Container) {
        Remove-Item -LiteralPath $copilotHomeFixture -Recurse -Force
    }
}
