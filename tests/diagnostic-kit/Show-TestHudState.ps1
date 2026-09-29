[CmdletBinding()]
param(
    [switch]$WaitForAttached,
    [switch]$Watch,
    [switch]$Diagnostics,
    [ValidateRange(1, 120)][int]$TimeoutSeconds = 30,
    [ValidateRange(1, 10)][int]$IntervalSeconds = 1
)

$ErrorActionPreference = 'Stop'
$expectedPrefix = 'copilot-hud-transition-diagnostic-'
$kitRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$kitName = [System.IO.Path]::GetFileName($kitRoot)
$kitParent = [System.IO.Directory]::GetParent($kitRoot)
$tempRoot = [System.IO.Path]::GetFullPath($env:TEMP)
if (-not $kitName.StartsWith(
        $expectedPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or
    $null -eq $kitParent -or
    -not [System.IO.Path]::GetFullPath($kitParent.FullName).Equals(
        $tempRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'This inspector is restricted to a disposable kit directly under TEMP.'
}
$kitRootInfo = Get-Item -LiteralPath $kitRoot -Force -ErrorAction Stop
if (($kitRootInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The disposable kit root must not be a reparse point.'
}

$selectedModes = 0
foreach ($selected in @($WaitForAttached, $Watch, $Diagnostics)) {
    if ($selected) {
        $selectedModes += 1
    }
}
if ($selectedModes -gt 1) {
    throw 'Choose only one of -WaitForAttached, -Watch, or -Diagnostics.'
}

$copilotHome = Join-Path $kitRoot 'copilot-home'
$stateDirectory = Join-Path $copilotHome 'state'
$bridgeDirectory = Join-Path $stateDirectory 'hud-signal-bridge'
$diagnosticDirectory = Join-Path $stateDirectory 'hud-signal-diagnostics'
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$copilotHomeInfo = Get-Item -LiteralPath $copilotHome -Force -ErrorAction Stop
if (($copilotHomeInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The disposable COPILOT_HOME must not be a reparse point.'
}
$resolvedTempRoot = [System.IO.Path]::GetFullPath(
    (Resolve-Path -LiteralPath $tempRoot -ErrorAction Stop).Path
).TrimEnd('\') + '\'
$resolvedCopilotHome = [System.IO.Path]::GetFullPath(
    (Resolve-Path -LiteralPath $copilotHome -ErrorAction Stop).Path
).TrimEnd('\') + '\'
$normalHome = [System.IO.Path]::GetFullPath(
    (Join-Path $env:USERPROFILE '.copilot')
)
$resolvedNormalHome = if (Test-Path -LiteralPath $normalHome -PathType Container) {
    [System.IO.Path]::GetFullPath(
        (Resolve-Path -LiteralPath $normalHome -ErrorAction Stop).Path
    ).TrimEnd('\') + '\'
} else {
    [System.IO.Path]::GetFullPath($normalHome).TrimEnd('\') + '\'
}
if (-not $resolvedCopilotHome.StartsWith(
        $resolvedTempRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or
    $resolvedCopilotHome.StartsWith(
        $resolvedNormalHome,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'The disposable COPILOT_HOME must resolve beneath TEMP and outside the normal user home.'
}
$diagnosticReasons = @(
    'matched-start',
    'matching-terminal',
    'unmatched-terminal',
    'ambiguous-identity',
    'session-idle-open-agent',
    'lifecycle-lease-expiry',
    'resume-reset',
    'ambiguous-event-order',
    'ambiguous-event',
    'ambiguous-checkpoint',
    'root-turn-boundary',
    'permission-boundary',
    'interruption',
    'tracking-capacity',
    'confirmed-zero-expiry',
    'observer-reset'
)
$toolDiagnosticReasons = @(
    'tool-start-missing-event-id',
    'tool-start-interval-absent',
    'tool-start-root-turn-closed',
    'tool-start-missing-call-id',
    'tool-start-active-limit',
    'tool-start-duplicate-call-id',
    'tool-progress-missing-event-id',
    'tool-progress-interval-absent',
    'tool-progress-missing-call-id',
    'tool-progress-unmatched-call-id',
    'tool-complete-missing-event-id',
    'tool-complete-interval-absent',
    'tool-complete-missing-call-id',
    'tool-complete-unmatched-call-id'
)

function Read-BoundedJson {
    param([string]$Path, [int]$MaximumBytes)

    $stream = $null
    try {
        $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Reparse points are not accepted.'
        }
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        $length = $stream.Length
        if ($length -le 0 -or $length -gt $MaximumBytes) {
            throw 'Snapshot is outside its configured size bound.'
        }
        $bytes = New-Object byte[] ([int]$length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) {
                throw 'Snapshot changed during the bounded read.'
            }
            $offset += $read
        }
    } catch {
        throw 'Unable to read a bounded sanitized snapshot.'
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    try {
        $text = $utf8Strict.GetString($bytes)
        $value = ConvertFrom-Json -InputObject $text -ErrorAction Stop
        return [pscustomobject]@{
            Value = $value
            Length = $length
        }
    } catch {
        throw 'A bounded sanitized snapshot is malformed.'
    }
}

function Test-NonnegativeInteger {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [bool] -or $Value -isnot [ValueType]) {
        return $false
    }
    $number = [double]$Value
    return -not [double]::IsNaN($number) -and
        -not [double]::IsInfinity($number) -and
        $number -ge 0 -and
        $number -le 9007199254740991 -and
        $number -eq [math]::Truncate($number)
}

function Test-Count {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $true
    }
    return (Test-NonnegativeInteger $Value) -and [long]$Value -le 16
}

function Get-BridgeSnapshot {
    $bridgeFiles = @()
    if ([System.IO.Directory]::Exists($bridgeDirectory)) {
        $bridgeDirectoryInfo = Get-Item -LiteralPath $bridgeDirectory -Force
        if (($bridgeDirectoryInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Bridge state directory is not a local directory.'
        }
        $bridgeFiles = @(Get-ChildItem -LiteralPath $bridgeDirectory -File `
            -Filter 'hud-signal-*.json' -ErrorAction Stop)
    }
    if ($bridgeFiles.Count -gt 1) {
        throw 'More than one bridge session file exists; refusing to choose a session.'
    }
    if ($bridgeFiles.Count -eq 0) {
        return [pscustomobject]@{
            Exists = $false
            JoinObserved = $false
            FreshForRender = $false
            Bridge = 'absent'
            Agents = 'unknown'
            Phase = 'unknown'
            SessionId = $null
        }
    }

    $readResult = Read-BoundedJson -Path $bridgeFiles[0].FullName -MaximumBytes 4096
    $state = $readResult.Value
    $required = @(
        'version',
        'sessionId',
        'updatedAtMs',
        'phase',
        'phaseAtMs',
        'recentIncreaseNanoAiu',
        'recentAtMs',
        'activeSubagentCount'
    )
    $properties = @($state.PSObject.Properties.Name)
    if ($properties.Count -ne $required.Count -or
        @($properties | Where-Object { $_ -cnotin $required }).Count -gt 0 -or
        @($required | Where-Object { $_ -cnotin $properties }).Count -gt 0 -or
        -not (Test-NonnegativeInteger $state.version) -or
        [long]$state.version -ne 1 -or
        $state.sessionId -isnot [string] -or
        $state.sessionId -notmatch '^[A-Za-z0-9_-]{1,128}$' -or
        -not (Test-NonnegativeInteger $state.updatedAtMs) -or
        -not (Test-Count $state.activeSubagentCount)) {
        throw 'Bridge state has an unexpected sanitized schema.'
    }
    if ($null -ne $state.phase -and
        ($state.phase -isnot [string] -or
            $state.phase -cnotin @('working', 'running_tool', 'complete', 'idle') -or
            -not (Test-NonnegativeInteger $state.phaseAtMs))) {
        throw 'Bridge phase fields are invalid.'
    }
    if ($null -eq $state.phase -and $null -ne $state.phaseAtMs) {
        throw 'Bridge phase fields are invalid.'
    }
    if ($null -ne $state.recentIncreaseNanoAiu) {
        if (-not (Test-NonnegativeInteger $state.recentIncreaseNanoAiu) -or
            -not (Test-NonnegativeInteger $state.recentAtMs)) {
            throw 'Bridge checkpoint fields are invalid.'
        }
    } elseif ($null -ne $state.recentAtMs) {
        throw 'Bridge checkpoint fields are invalid.'
    }

    $filenameMatch = [regex]::Match(
        $bridgeFiles[0].Name,
        '^hud-signal-(?<id>[A-Za-z0-9_-]{1,128})\.json$'
    )
    if (-not $filenameMatch.Success -or
        $state.sessionId -cne $filenameMatch.Groups['id'].Value) {
        throw 'Bridge identity does not match its filename.'
    }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if (($null -ne $state.phaseAtMs -and [double]$state.phaseAtMs -gt $now + 5000) -or
        ($null -ne $state.recentAtMs -and [double]$state.recentAtMs -gt $now + 5000)) {
        throw 'Bridge timestamps are invalid.'
    }
    $ageMs = $now - [double]$state.updatedAtMs
    $fresh = $ageMs -ge -5000 -and $ageMs -le 20000
    $diagnosticPath = Join-Path $diagnosticDirectory (
        'hud-subagent-count-changes-{0}.json' -f $state.sessionId
    )
    $diagnosticStatus = if ([System.IO.File]::Exists($diagnosticPath)) {
        'present'
    } else {
        'absent'
    }

    return [pscustomobject]@{
        Exists = $true
        JoinObserved = $true
        FreshForRender = $fresh
        Bridge = if ($fresh) { 'fresh' } else { 'stale' }
        Agents = if (-not $fresh -or $null -eq $state.activeSubagentCount) {
            'unknown'
        } else {
            [string][long]$state.activeSubagentCount
        }
        Phase = if (-not $fresh -or $null -eq $state.phase) {
            'unknown'
        } else {
            [string]$state.phase
        }
        Diagnostic = $diagnosticStatus
        SessionId = [string]$state.sessionId
    }
}

function Get-DiagnosticRecords {
    param([string]$SessionId)

    if ([System.IO.Directory]::Exists($diagnosticDirectory)) {
        $directoryInfo = Get-Item -LiteralPath $diagnosticDirectory -Force
        if (($directoryInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Diagnostic state directory is not a local directory.'
        }
    }
    $diagnosticPath = Join-Path $diagnosticDirectory (
        'hud-subagent-count-changes-{0}.json' -f $SessionId
    )
    if (-not [System.IO.File]::Exists($diagnosticPath)) {
        return @()
    }
    $readResult = Read-BoundedJson -Path $diagnosticPath -MaximumBytes 4096
    $records = @($readResult.Value)
    if ($records.Count -gt 32) {
        throw 'Diagnostic record count exceeds its configured bound.'
    }
    $safeRecords = @()
    foreach ($record in $records) {
        $properties = @($record.PSObject.Properties.Name)
        $isToolDiagnostic = $record.reason -cin $toolDiagnosticReasons
        $required = @('atMs', 'reason', 'previousCount', 'nextCount')
        if ($isToolDiagnostic) {
            $required += @('rootInterval', 'caller', 'parentCorrelation')
        }
        $countsValid = if ($isToolDiagnostic) {
            $record.previousCount -ceq $record.nextCount
        } else {
            $record.previousCount -cne $record.nextCount
        }
        if ($properties.Count -ne $required.Count -or
            @($properties | Where-Object { $_ -cnotin $required }).Count -gt 0 -or
            @($required | Where-Object { $_ -cnotin $properties }).Count -gt 0 -or
            -not (Test-NonnegativeInteger $record.atMs) -or
            $record.reason -isnot [string] -or
            ($record.reason -cnotin $diagnosticReasons -and -not $isToolDiagnostic) -or
            -not (Test-Count $record.previousCount) -or
            -not (Test-Count $record.nextCount) -or
            -not $countsValid) {
            throw 'Diagnostic records have an unexpected sanitized schema.'
        }
        $safeRecord = [ordered]@{
            atMs = [long]$record.atMs
            reason = [string]$record.reason
            previousCount = $record.previousCount
            nextCount = $record.nextCount
        }
        if ($isToolDiagnostic) {
            if ($record.rootInterval -cnotin @('absent', 'open', 'closed') -or
                $record.caller -cnotin @('root', 'subagent', 'unknown') -or
                $record.parentCorrelation -cnotin @('matched', 'missing', 'unmatched')) {
                throw 'Tool diagnostic context is invalid.'
            }
            $safeRecord.rootInterval = [string]$record.rootInterval
            $safeRecord.caller = [string]$record.caller
            $safeRecord.parentCorrelation = [string]$record.parentCorrelation
        }
        $safeRecords += [pscustomobject]$safeRecord
    }
    return $safeRecords
}

function Write-MonitorSnapshot {
    $snapshot = Get-BridgeSnapshot
    $diagnosticStatus = if ($snapshot.Exists) {
        $snapshot.Diagnostic
    } else {
        'absent'
    }
    Write-Host ('[{0}] JoinObserved={1} FreshForRender={2} Bridge={3} Agents={4} Phase={5} Diagnostic={6}' -f `
        [DateTimeOffset]::UtcNow.ToString('HH:mm:ss'),
        $snapshot.JoinObserved,
        $snapshot.FreshForRender,
        $snapshot.Bridge,
        $snapshot.Agents,
        $snapshot.Phase,
        $diagnosticStatus)
    return $snapshot
}

if ($Diagnostics) {
    $bridge = Get-BridgeSnapshot
    if (-not $bridge.JoinObserved) {
        throw 'No valid attached bridge snapshot is available.'
    }
    $records = Get-DiagnosticRecords -SessionId $bridge.SessionId
    $records
    return
}

if ($WaitForAttached) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $snapshot = Write-MonitorSnapshot
        if ($snapshot.JoinObserved) {
            return
        }
        Start-Sleep -Seconds $IntervalSeconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'No valid post-join bridge snapshot appeared; do not prompt.'
}

if ($Watch) {
    while ($true) {
        $null = Write-MonitorSnapshot
        Start-Sleep -Seconds $IntervalSeconds
    }
}

$null = Write-MonitorSnapshot
