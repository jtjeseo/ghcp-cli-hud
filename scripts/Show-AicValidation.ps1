[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CopilotHome
)

$ErrorActionPreference = 'Stop'
$maximumBytes = 4096
$aicReasons = @(
    'baseline-accepted',
    'valid',
    'missing-baseline',
    'ambiguous-baseline',
    'missing-final-checkpoint',
    'counter-reset',
    'interruption',
    'resume-reset',
    'overlapping-turns',
    'overlapping-tools',
    'incomplete-turns',
    'checkpoint-before-turn-end',
    'ambiguous-checkpoint',
    'ambiguous-event-order',
    'ambiguous-event',
    'permission-boundary',
    'tool-correlation',
    'unverified-subagent-attribution',
    'observer-reset'
)
$orderKeys = @(
    'bridgeSessionMatched',
    'baselineBeforeInterval',
    'rootTurnsStarted',
    'rootTurnsEnded',
    'rootTurnCountCapped',
    'rootTurnsClosed',
    'finalCheckpointAccepted',
    'finalCheckpointAfterTurnEnd',
    'idleAfterFinalCheckpoint',
    'toolCallsClosed',
    'overlapObserved',
    'interruptionObserved',
    'resetObserved',
    'counterResetObserved',
    'unverifiedSubagentActivity'
)

function Assert-NoReparsePoint {
    param([string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        throw 'A required validation path is missing or unreadable.'
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The validation path must not be a reparse point.'
    }
}

function Read-BoundedJson {
    param([string]$Path)

    $stream = $null
    try {
        Assert-NoReparsePoint -Path $Path
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        $length = $stream.Length
        if ($length -le 0 -or $length -gt $maximumBytes) {
            throw 'The derived state is outside its configured size bound.'
        }
        $bytes = New-Object byte[] ([int]$length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) {
                throw 'The derived state changed during the bounded read.'
            }
            $offset += $read
        }
    } catch {
        throw 'Unable to read bounded derived state.'
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    try {
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        return ConvertFrom-Json -InputObject $text -ErrorAction Stop
    } catch {
        throw 'The bounded derived state is malformed.'
    }
}

function Test-SafeInteger {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [bool] -or $Value -isnot [ValueType]) {
        return $false
    }
    $number = [double]$Value
    return -not [double]::IsNaN($number) -and
        -not [double]::IsInfinity($number) -and
        [math]::Abs($number) -le 9007199254740991 -and
        $number -eq [math]::Truncate($number)
}

function Test-NonnegativeInteger {
    param([AllowNull()][object]$Value)

    return (Test-SafeInteger $Value) -and [double]$Value -ge 0
}

function Format-NanoAiu {
    param([long]$Value)

    $aiu = [double]$Value / 1000000000.0
    $formatted = $aiu.ToString(
        '0.00',
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    if ($aiu -gt 0 -and $formatted -ceq '0.00') {
        $formatted = $aiu.ToString(
            '0.#########',
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
    return 'recent +' + $formatted + ' AIU'
}

if (-not [System.IO.Path]::IsPathRooted($CopilotHome)) {
    throw 'COPILOT_HOME must be an absolute disposable path.'
}
try {
    $homeInfo = Get-Item -LiteralPath $CopilotHome -Force -ErrorAction Stop
} catch {
    throw 'COPILOT_HOME is missing or unreadable.'
}
if (-not $homeInfo.PSIsContainer) {
    throw 'COPILOT_HOME must be a directory.'
}
Assert-NoReparsePoint -Path $CopilotHome
$homeName = [System.IO.Path]::GetFileName(
    [System.IO.Path]::GetFullPath($CopilotHome).TrimEnd('\')
)
if (-not $homeName.StartsWith(
        'copilot-hud-session-',
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'The inspector accepts only a fresh opt-in launcher home.'
}
try {
    $tempRoot = [System.IO.Path]::GetFullPath(
        (Resolve-Path -LiteralPath $env:TEMP -ErrorAction Stop).Path
    ).TrimEnd('\') + '\'
    $resolvedHome = [System.IO.Path]::GetFullPath(
        (Resolve-Path -LiteralPath $CopilotHome -ErrorAction Stop).Path
    ).TrimEnd('\') + '\'
} catch {
    throw 'The validation home could not be resolved beneath TEMP.'
}
$normalHome = [System.IO.Path]::GetFullPath(
    (Join-Path $env:USERPROFILE '.copilot')
)
if (Test-Path -LiteralPath $normalHome -PathType Container) {
    $normalHome = [System.IO.Path]::GetFullPath(
        (Resolve-Path -LiteralPath $normalHome -ErrorAction Stop).Path
    ).TrimEnd('\') + '\'
} else {
    $normalHome = $normalHome.TrimEnd('\') + '\'
}
if (-not $resolvedHome.StartsWith(
        $tempRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or
    $resolvedHome.StartsWith(
        $normalHome,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'The validation home must be beneath TEMP and outside the normal user home.'
}

$bridgeDirectory = Join-Path $CopilotHome 'state\hud-signal-bridge'
try {
    $bridgeDirectoryInfo = Get-Item -LiteralPath $bridgeDirectory -Force -ErrorAction Stop
} catch {
    throw 'A matching bridge snapshot is unavailable.'
}
Assert-NoReparsePoint -Path $bridgeDirectory
if (-not $bridgeDirectoryInfo.PSIsContainer) {
    throw 'Bridge state is not a local directory.'
}
try {
    $bridgeFiles = @(
        Get-ChildItem -LiteralPath $bridgeDirectory -File `
            -Filter 'hud-signal-*.json' -ErrorAction Stop
    )
} catch {
    throw 'A matching bridge snapshot is unavailable.'
}
if ($bridgeFiles.Count -ne 1) {
    throw 'A single bridge session is required for this validation.'
}
$bridgeNameMatch = [regex]::Match(
    $bridgeFiles[0].Name,
    '^hud-signal-(?<id>[A-Za-z0-9_-]{1,128})\.json$'
)
if (-not $bridgeNameMatch.Success) {
    throw 'The bridge snapshot filename is invalid.'
}
$bridge = Read-BoundedJson -Path $bridgeFiles[0].FullName
$bridgeKeys = @($bridge.PSObject.Properties.Name)
$requiredBridgeKeys = @(
    'version',
    'sessionId',
    'updatedAtMs',
    'phase',
    'phaseAtMs',
    'recentIncreaseNanoAiu',
    'recentAtMs',
    'activeSubagentCount'
)
$allowedBridgeKeys = $requiredBridgeKeys + @('recentSuppressedReason')
if (@($bridgeKeys | Where-Object { $_ -cnotin $allowedBridgeKeys }).Count -gt 0 -or
    @($requiredBridgeKeys | Where-Object { $_ -cnotin $bridgeKeys }).Count -gt 0 -or
    $bridge.version -ne 1 -or
    $bridge.sessionId -isnot [string] -or
    $bridge.sessionId -notmatch '^[A-Za-z0-9_-]{1,128}$' -or
    $bridge.sessionId -cne $bridgeNameMatch.Groups['id'].Value -or
    -not (Test-NonnegativeInteger $bridge.updatedAtMs) -or
    -not (Test-NonnegativeInteger $bridge.activeSubagentCount) -and
        $null -ne $bridge.activeSubagentCount -or
    ($null -ne $bridge.activeSubagentCount -and
        [long]$bridge.activeSubagentCount -gt 16) -or
    ($null -ne $bridge.phase -and
        ($bridge.phase -cnotin @('working', 'running_tool', 'complete', 'idle') -or
            -not (Test-NonnegativeInteger $bridge.phaseAtMs))) -or
    ($null -eq $bridge.phase -and $null -ne $bridge.phaseAtMs) -or
    ($null -ne $bridge.recentIncreaseNanoAiu -and
        (-not (Test-NonnegativeInteger $bridge.recentIncreaseNanoAiu) -or
            -not (Test-NonnegativeInteger $bridge.recentAtMs) -or
            $null -ne $bridge.recentSuppressedReason -or
            [double]$bridge.recentAtMs -gt
                [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 5000)) -or
    ($null -ne $bridge.recentSuppressedReason -and
        ($bridge.recentSuppressedReason -isnot [string] -or
            $bridge.recentSuppressedReason -cnotin @('overlap', 'incomplete',
                'early-usage', 'no-baseline', 'no-usage', 'subagent', 'reset',
                'interrupted', 'ambiguous') -or
            -not (Test-NonnegativeInteger $bridge.recentAtMs) -or
            [double]$bridge.recentAtMs -gt
                [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 5000)) -or
    ($null -eq $bridge.recentIncreaseNanoAiu -and
        $null -eq $bridge.recentSuppressedReason -and
        $null -ne $bridge.recentAtMs)) {
    throw 'The bridge snapshot does not match its bounded schema.'
}

$validationPath = Join-Path $CopilotHome 'state\hud-aic-validation\validation.json'
$validationDirectory = Split-Path -Parent $validationPath
$lockPath = Join-Path $validationDirectory 'validation.lock'
try {
    $validationFileInfo = Get-Item -LiteralPath $validationPath -Force -ErrorAction Stop
    $lockInfo = Get-Item -LiteralPath $lockPath -Force -ErrorAction Stop
} catch {
    throw 'AIC validation state or its single-session lock is missing.'
}
Assert-NoReparsePoint -Path $validationPath
Assert-NoReparsePoint -Path $lockPath
$validation = Read-BoundedJson -Path $validationPath
$validationKeys = @($validation.PSObject.Properties.Name)
$requiredValidationKeys = @(
    'version',
    'validity',
    'reason',
    'baselineNanoAiu',
    'finalCheckpointNanoAiu',
    'computedDifferenceNanoAiu',
    'displayedIncreaseNanoAiu',
    'eventOrder'
)
if ($validationKeys.Count -ne $requiredValidationKeys.Count -or
    @($requiredValidationKeys | Where-Object { $_ -cnotin $validationKeys }).Count -gt 0 -or
    $validation.version -ne 1 -or
    $validation.validity -cnotin @('pending', 'valid', 'suppressed') -or
    $validation.reason -cnotin $aicReasons) {
    throw 'The AIC validation record does not match its bounded schema.'
}
$eventOrderKeys = @($validation.eventOrder.PSObject.Properties.Name)
if ($eventOrderKeys.Count -ne $orderKeys.Count -or
    @($orderKeys | Where-Object { $_ -cnotin $eventOrderKeys }).Count -gt 0) {
    throw 'The AIC event-order record has an unexpected shape.'
}
foreach ($key in $orderKeys) {
    if ($key -in @('rootTurnsStarted', 'rootTurnsEnded')) {
        if (-not (Test-NonnegativeInteger $validation.eventOrder.$key) -or
            [long]$validation.eventOrder.$key -gt 32) {
            throw 'An AIC root-turn count is outside its bound.'
        }
    } elseif ($validation.eventOrder.$key -isnot [bool]) {
        throw 'An AIC event-order indicator is invalid.'
    }
}
foreach ($key in @('baselineNanoAiu', 'finalCheckpointNanoAiu', 'displayedIncreaseNanoAiu')) {
    $value = $validation.$key
    if ($null -ne $value -and -not (Test-NonnegativeInteger $value)) {
        throw 'An AIC total is outside its numeric bound.'
    }
}
if ($null -ne $validation.computedDifferenceNanoAiu -and
    -not (Test-SafeInteger $validation.computedDifferenceNanoAiu)) {
    throw 'The AIC checkpoint difference is outside its numeric bound.'
}
$expectedDifference = if ($null -ne $validation.baselineNanoAiu -and
    $null -ne $validation.finalCheckpointNanoAiu) {
    [double]$validation.finalCheckpointNanoAiu -
        [double]$validation.baselineNanoAiu
} else {
    $null
}
if ($validation.computedDifferenceNanoAiu -cne $expectedDifference) {
    throw 'The computed AIC difference does not equal the checkpoint totals.'
}
if ($validation.validity -ceq 'pending') {
    if ($validation.reason -cne 'baseline-accepted' -or
        $null -eq $validation.baselineNanoAiu -or
        $null -ne $validation.finalCheckpointNanoAiu -or
        $null -ne $validation.computedDifferenceNanoAiu -or
        $null -ne $validation.displayedIncreaseNanoAiu -or
        -not $validation.eventOrder.baselineBeforeInterval) {
        throw 'A pending AIC record is not an accepted baseline.'
    }
} elseif ($validation.validity -ceq 'valid') {
    $order = $validation.eventOrder
    if ($validation.reason -cne 'valid' -or
        $null -eq $validation.baselineNanoAiu -or
        $null -eq $validation.finalCheckpointNanoAiu -or
        $null -eq $validation.displayedIncreaseNanoAiu -or
        $validation.displayedIncreaseNanoAiu -cne $validation.computedDifferenceNanoAiu -or
        $validation.computedDifferenceNanoAiu -lt 0 -or
        -not $order.bridgeSessionMatched -or
        -not $order.baselineBeforeInterval -or
        $order.rootTurnsStarted -lt 1 -or
        $order.rootTurnsStarted -cne $order.rootTurnsEnded -or
        $order.rootTurnCountCapped -or
        -not $order.rootTurnsClosed -or
        -not $order.finalCheckpointAccepted -or
        -not $order.finalCheckpointAfterTurnEnd -or
        -not $order.idleAfterFinalCheckpoint -or
        -not $order.toolCallsClosed -or
        $order.overlapObserved -or
        $order.interruptionObserved -or
        $order.resetObserved -or
        $order.counterResetObserved -or
        $order.unverifiedSubagentActivity) {
        throw 'The AIC interval is not an unambiguous displayable interval.'
    }
} elseif ($validation.reason -cin @('valid', 'baseline-accepted') -or
    $null -ne $validation.displayedIncreaseNanoAiu) {
    throw 'A suppressed AIC interval cannot have a displayed increase.'
}

$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$snapshotAgeMs = $now - [double]$bridge.updatedAtMs
$bridgeFresh = $snapshotAgeMs -ge -5000 -and $snapshotAgeMs -le 20000
$recentAt = $bridge.recentAtMs
$recentFresh = $null -ne $recentAt -and
    [double]$recentAt -le $now + 5000 -and
    $now - [double]$recentAt -le 120000
$matchesBridge = $null -ne $bridge.recentIncreaseNanoAiu -and
    $null -ne $validation.displayedIncreaseNanoAiu -and
    $bridge.recentIncreaseNanoAiu -ceq
        $validation.displayedIncreaseNanoAiu
$bridgeCreatedAt = [DateTimeOffset]$bridgeFiles[0].CreationTimeUtc
$lockCreatedAt = [DateTimeOffset]$lockInfo.CreationTimeUtc
$validationWrittenAt = [DateTimeOffset]$validationFileInfo.LastWriteTimeUtc
$bridgeCreatedAtMs = $bridgeCreatedAt.ToUnixTimeMilliseconds()
$lockCreatedAtMs = $lockCreatedAt.ToUnixTimeMilliseconds()
$validationWrittenAtMs = $validationWrittenAt.ToUnixTimeMilliseconds()
$sameHomeLaunch = [math]::Abs(
    [double]$bridgeCreatedAtMs - [double]$lockCreatedAtMs
) -le 300000
$validationFollowsRecentValue = $validation.validity -cne 'valid' -or
    ($null -ne $recentAt -and
        $validationWrittenAtMs + 5000 -ge [double]$recentAt)
$sameSessionVerified = $validation.eventOrder.bridgeSessionMatched -and
    $bridgeNameMatch.Success -and
    $bridge.sessionId -ceq $bridgeNameMatch.Groups['id'].Value -and
    $sameHomeLaunch -and
    $validationFollowsRecentValue

'sameSession=' + $(if ($sameSessionVerified) { 'verified' } else { 'unverified' })
'validity=' + $validation.validity
'reason=' + $validation.reason
'baselineNanoAiu=' + $(if ($null -eq $validation.baselineNanoAiu) { 'null' } else { [string]$validation.baselineNanoAiu })
'finalCheckpointNanoAiu=' + $(if ($null -eq $validation.finalCheckpointNanoAiu) { 'null' } else { [string]$validation.finalCheckpointNanoAiu })
'computedDifferenceNanoAiu=' + $(if ($null -eq $validation.computedDifferenceNanoAiu) { 'null' } else { [string]$validation.computedDifferenceNanoAiu })
'displayedIncreaseNanoAiu=' + $(if ($null -eq $validation.displayedIncreaseNanoAiu) { 'null' } else { [string]$validation.displayedIncreaseNanoAiu })
'expectedHudText=' + $(if ($null -eq $validation.displayedIncreaseNanoAiu) { 'absent' } else { Format-NanoAiu -Value ([long]$validation.displayedIncreaseNanoAiu) })
'matchesBridgeRecentValue=' + [string]$matchesBridge
'bridgeFreshForRenderer=' + [string]$bridgeFresh
'recentValueWithinRetention=' + [string]$recentFresh
'eventOrder=' + (($orderKeys | ForEach-Object {
    $_ + '=' + [string]$validation.eventOrder.$_
}) -join ';')
