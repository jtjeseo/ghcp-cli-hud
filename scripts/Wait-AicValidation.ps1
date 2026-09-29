$ErrorActionPreference = 'Stop'
$copilotHome = [Environment]::GetEnvironmentVariable('COPILOT_HOME', 'Process')
if ([string]::IsNullOrWhiteSpace($copilotHome)) {
    Write-Host 'AICObserver=home-unavailable;inconclusive'
    return
}

try {
    $homeInfo = Get-Item -LiteralPath $copilotHome -Force -ErrorAction Stop
    $resolvedHome = [System.IO.Path]::GetFullPath(
        (Resolve-Path -LiteralPath $copilotHome -ErrorAction Stop).Path
    ).TrimEnd('\') + '\'
    $tempRoot = [System.IO.Path]::GetFullPath(
        (Resolve-Path -LiteralPath $env:TEMP -ErrorAction Stop).Path
    ).TrimEnd('\') + '\'
    $normalHome = [System.IO.Path]::GetFullPath(
        (Join-Path $env:USERPROFILE '.copilot')
    ).TrimEnd('\') + '\'
    if (Test-Path -LiteralPath $normalHome -PathType Container) {
        $normalHome = [System.IO.Path]::GetFullPath(
            (Resolve-Path -LiteralPath $normalHome -ErrorAction Stop).Path
        ).TrimEnd('\') + '\'
    }
    $homeName = [System.IO.Path]::GetFileName($resolvedHome.TrimEnd('\'))
    if (-not $homeInfo.PSIsContainer -or
        ($homeInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not $homeName.StartsWith(
            'copilot-hud-session-',
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not $resolvedHome.StartsWith(
            $tempRoot,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        $resolvedHome.StartsWith(
            $normalHome,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Observer home is not disposable.'
    }
} catch {
    Write-Host 'AICObserver=home-unavailable;inconclusive'
    return
}

$stateDirectory = Join-Path $copilotHome 'state'
$validationDirectory = Join-Path $stateDirectory 'hud-aic-validation'
$validationPath = Join-Path $validationDirectory 'validation.json'
$observerStartedAtUtc = [DateTime]::UtcNow

function Get-BoundedValidationSnapshot {
    $stream = $null
    $hash = $null
    try {
        $stateInfo = Get-Item -LiteralPath $stateDirectory -Force `
            -ErrorAction Stop
        $directoryInfo = Get-Item -LiteralPath $validationDirectory -Force `
            -ErrorAction Stop
        $fileInfo = Get-Item -LiteralPath $validationPath -Force `
            -ErrorAction Stop
        if (-not $stateInfo.PSIsContainer -or
            -not $directoryInfo.PSIsContainer -or
            $fileInfo.PSIsContainer -or
            (($stateInfo.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0) -or
            (($directoryInfo.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0) -or
            (($fileInfo.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0) -or
            $fileInfo.Length -le 0 -or $fileInfo.Length -gt 4096) {
            return $null
        }

        $stream = [System.IO.File]::Open(
            $validationPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        if ($stream.Length -le 0 -or $stream.Length -gt 4096) {
            return $null
        }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) {
                return $null
            }
            $offset += $read
        }
        $stream.Dispose()
        $stream = $null

        $afterInfo = Get-Item -LiteralPath $validationPath -Force `
            -ErrorAction Stop
        if (($afterInfo.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $afterInfo.Length -ne $bytes.Length -or
            $afterInfo.LastWriteTimeUtc.Ticks -ne
                $fileInfo.LastWriteTimeUtc.Ticks) {
            return $null
        }

        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $record = ConvertFrom-Json -InputObject $text -ErrorAction Stop
        $hash = [System.Security.Cryptography.SHA256]::Create()
        $fingerprint = [System.BitConverter]::ToString(
            $hash.ComputeHash($bytes)
        )
        return [pscustomobject]@{
            Record = $record
            LastWriteTimeUtc = $afterInfo.LastWriteTimeUtc
            Fingerprint = $fingerprint
        }
    } catch {
        return $null
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if ($null -ne $hash) {
            $hash.Dispose()
        }
    }
}

function Wait-ForFinalValidation {
    param($LaterThanUtc = $null)

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        $snapshot = Get-BoundedValidationSnapshot
        if ($null -ne $snapshot -and
            $snapshot.Record.validity -in @('valid', 'suppressed') -and
            ($null -eq $LaterThanUtc -or
                $snapshot.LastWriteTimeUtc -gt $LaterThanUtc)) {
            return $snapshot
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Invoke-AicInspector {
    param([Parameter(Mandatory)][object]$ExpectedSnapshot)

    $failedResult = [pscustomobject]@{
        Succeeded = $false
        Stable = $false
        Lines = @()
        Snapshot = $null
    }
    $before = Get-BoundedValidationSnapshot
    if ($null -eq $before -or
        $before.Fingerprint -cne $ExpectedSnapshot.Fingerprint) {
        return $failedResult
    }

    try {
        $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
        $inspectorPath = Join-Path $PSScriptRoot 'Show-AicValidation.ps1'
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new($pwshPath)
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Arguments = '-NoLogo -NoProfile -File "' + $inspectorPath +
            '" -CopilotHome "' + $copilotHome + '"'

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        [void]$process.Start()
        try {
            if (-not $process.WaitForExit(15000)) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                return $failedResult
            }
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $exitCode = $process.ExitCode
        } finally {
            $process.Dispose()
        }

        $after = Get-BoundedValidationSnapshot
        $stable = $null -ne $after -and
            $before.Fingerprint -ceq $after.Fingerprint -and
            $before.LastWriteTimeUtc.Ticks -eq
                $after.LastWriteTimeUtc.Ticks
        $lines = @($stdout -split "`r?`n" | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        })
        return [pscustomobject]@{
            Succeeded = $exitCode -eq 0 -and
                [string]::IsNullOrEmpty($stderr)
            Stable = $stable
            Lines = $lines
            Snapshot = $after
        }
    } catch {
        return $failedResult
    }
}

function Get-InspectorValue {
    param(
        [string[]]$Lines,
        [Parameter(Mandatory)][string]$Name
    )

    $prefix = $Name + '='
    $matches = @($Lines | Where-Object {
        $_.StartsWith($prefix, [System.StringComparison]::Ordinal)
    })
    if ($matches.Count -ne 1) {
        return $null
    }
    return $matches[0].Substring($prefix.Length)
}

function Test-NonnegativeInteger {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [bool] -or
        $Value -isnot [ValueType]) {
        return $false
    }
    $number = [double]$Value
    return -not [double]::IsNaN($number) -and
        -not [double]::IsInfinity($number) -and
        $number -ge 0 -and
        $number -le 9007199254740991 -and
        $number -eq [math]::Truncate($number)
}

function Test-CleanClosedBoundary {
    param([Parameter(Mandatory)][object]$Record)

    $order = $Record.eventOrder
    return $order.bridgeSessionMatched -eq $true -and
        $order.rootTurnsStarted -eq 1 -and
        $order.rootTurnsEnded -eq 1 -and
        $order.rootTurnCountCapped -eq $false -and
        $order.rootTurnsClosed -eq $true -and
        $order.toolCallsClosed -eq $true -and
        $order.finalCheckpointAfterTurnEnd -eq $true -and
        $order.idleAfterFinalCheckpoint -eq $true -and
        $order.overlapObserved -eq $false -and
        $order.interruptionObserved -eq $false -and
        $order.resetObserved -eq $false -and
        $order.counterResetObserved -eq $false -and
        $order.unverifiedSubagentActivity -eq $false
}

function Test-BaselineReady {
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][object]$Inspection
    )

    if (-not $Inspection.Succeeded -or -not $Inspection.Stable -or
        (Get-InspectorValue $Inspection.Lines 'sameSession') -cne 'verified' -or
        -not (Test-NonnegativeInteger $Snapshot.Record.finalCheckpointNanoAiu) -or
        -not (Test-CleanClosedBoundary $Snapshot.Record)) {
        return $false
    }

    $record = $Snapshot.Record
    if ($record.validity -ceq 'valid' -and
        $record.reason -ceq 'valid') {
        return $record.eventOrder.baselineBeforeInterval -eq $true -and
            $record.eventOrder.finalCheckpointAccepted -eq $true -and
            (Test-NonnegativeInteger $record.baselineNanoAiu)
    }

    return $record.validity -ceq 'suppressed' -and
        $record.reason -ceq 'missing-baseline' -and
        $null -eq $record.baselineNanoAiu -and
        $null -eq $record.computedDifferenceNanoAiu -and
        $null -eq $record.displayedIncreaseNanoAiu -and
        $record.eventOrder.baselineBeforeInterval -eq $false -and
        $record.eventOrder.finalCheckpointAccepted -eq $false
}

function Test-AicCheckAccepted {
    param(
        [Parameter(Mandatory)][object]$Inspection,
        [Parameter(Mandatory)][double]$BaselineNanoAiu
    )

    if (-not $Inspection.Succeeded -or -not $Inspection.Stable) {
        return $false
    }
    $record = $Inspection.Snapshot.Record
    $order = $record.eventOrder
    $difference = [double]$record.finalCheckpointNanoAiu -
        [double]$record.baselineNanoAiu
    $expectedHudText = Get-InspectorValue $Inspection.Lines 'expectedHudText'
    return (Get-InspectorValue $Inspection.Lines 'sameSession') -ceq 'verified' -and
        (Get-InspectorValue $Inspection.Lines 'validity') -ceq 'valid' -and
        (Get-InspectorValue $Inspection.Lines 'reason') -ceq 'valid' -and
        $record.validity -ceq 'valid' -and
        $record.reason -ceq 'valid' -and
        (Test-NonnegativeInteger $record.baselineNanoAiu) -and
        [double]$record.baselineNanoAiu -eq $BaselineNanoAiu -and
        (Test-NonnegativeInteger $record.finalCheckpointNanoAiu) -and
        (Test-NonnegativeInteger $record.displayedIncreaseNanoAiu) -and
        $record.computedDifferenceNanoAiu -eq $difference -and
        $record.displayedIncreaseNanoAiu -eq $difference -and
        (Get-InspectorValue $Inspection.Lines 'matchesBridgeRecentValue') -ceq 'True' -and
        (Get-InspectorValue $Inspection.Lines 'bridgeFreshForRenderer') -ceq 'True' -and
        (Get-InspectorValue $Inspection.Lines 'recentValueWithinRetention') -ceq 'True' -and
        $expectedHudText -match '^recent \+\S+ AIU$' -and
        $order.bridgeSessionMatched -eq $true -and
        $order.baselineBeforeInterval -eq $true -and
        $order.rootTurnsStarted -ge 1 -and
        $order.rootTurnsStarted -eq $order.rootTurnsEnded -and
        $order.rootTurnCountCapped -eq $false -and
        $order.rootTurnsClosed -eq $true -and
        $order.finalCheckpointAccepted -eq $true -and
        $order.finalCheckpointAfterTurnEnd -eq $true -and
        $order.idleAfterFinalCheckpoint -eq $true -and
        $order.toolCallsClosed -eq $true -and
        $order.overlapObserved -eq $false -and
        $order.interruptionObserved -eq $false -and
        $order.resetObserved -eq $false -and
        $order.counterResetObserved -eq $false -and
        $order.unverifiedSubagentActivity -eq $false
}

function Write-InspectorLines {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        Write-Host $line
    }
}

Write-Host 'AIC observer ready. After AIC-BASELINE completes, press Enter to verify its checkpoint boundary.'
[void][Console]::In.ReadLine()

$baselineSnapshot = Wait-ForFinalValidation `
    -LaterThanUtc $observerStartedAtUtc
if ($null -eq $baselineSnapshot) {
    Write-Host 'Stop; baseline not established.'
    return
}
$baselineInspection = Invoke-AicInspector `
    -ExpectedSnapshot $baselineSnapshot
if (-not (Test-BaselineReady `
        -Snapshot $baselineSnapshot `
        -Inspection $baselineInspection)) {
    Write-Host 'Stop; baseline not established.'
    return
}

Write-InspectorLines -Lines $baselineInspection.Lines
$baselineNanoAiu = [double]$baselineSnapshot.Record.finalCheckpointNanoAiu
$baselineText = $baselineNanoAiu.ToString(
    '0',
    [System.Globalization.CultureInfo]::InvariantCulture
)
Write-Host ('Baseline checkpoint B=' + $baselineText)
Write-Host 'Baseline ready; AIC-CHECK may be sent.'
Write-Host 'After AIC-CHECK completes and its HUD capture is ready, press Enter to validate the new interval.'
[void][Console]::In.ReadLine()

$checkSnapshot = Wait-ForFinalValidation `
    -LaterThanUtc $baselineInspection.Snapshot.LastWriteTimeUtc
if ($null -eq $checkSnapshot) {
    Write-Host 'Stop; no new final AIC-CHECK record was observed; inconclusive.'
    return
}
$checkInspection = Invoke-AicInspector -ExpectedSnapshot $checkSnapshot
if (-not $checkInspection.Succeeded -or -not $checkInspection.Stable) {
    Write-Host 'Stop; AIC-CHECK inspection was inconclusive.'
    return
}

Write-InspectorLines -Lines $checkInspection.Lines
if (Test-AicCheckAccepted `
        -Inspection $checkInspection `
        -BaselineNanoAiu $baselineNanoAiu) {
    Write-Host ('AIC comparison checks=verified; baseline B=' + $baselineText)
} else {
    Write-Host 'Stop; AIC-CHECK did not satisfy the baseline or acceptance checks; inconclusive.'
}
