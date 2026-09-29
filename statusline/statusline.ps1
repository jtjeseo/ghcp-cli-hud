# Temporary schema diagnostics only: set COPILOT_RAW_PAYLOAD_CAPTURE=1 for one run.
# Unset it afterward; captures are retained until manually removed.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$script:Escape = [char]27
$script:AnsiEnabled = $false
$script:Ansi256Enabled = $false
$term = [string]$env:TERM
$terminalHint = -not [string]::IsNullOrWhiteSpace($term) -and $term -notmatch '^(?i:dumb)$'
$windowsTerminalHint = -not [string]::IsNullOrWhiteSpace($env:WT_SESSION)
$conEmuHint = [string]$env:ConEmuANSI -match '^(?i:on|1|true)$'
$ansiHint = $terminalHint -or $windowsTerminalHint -or $conEmuHint -or
    -not [string]::IsNullOrWhiteSpace($env:ANSICON) -or
    [string]$env:TERM_PROGRAM -match '^(?i:vscode|windows_terminal|hyper)$'
$noColor = [Environment]::GetEnvironmentVariable('NO_COLOR')
if ($ansiHint -and [string]::IsNullOrEmpty($noColor) -and $term -notmatch '^(?i:dumb)$') {
    $script:AnsiEnabled = $true
}
$script:Ansi256Enabled = $script:AnsiEnabled -and (
    $windowsTerminalHint -or $conEmuHint -or
    $term -match '(?i)(256color|truecolor|24bit)' -or
    [string]$env:TERM_PROGRAM -match '^(?i:vscode|windows_terminal|hyper)$'
)

function Get-StatusColor {
    param([int]$PaletteIndex, [int]$FallbackCode)

    if (-not $script:AnsiEnabled) { return '' }
    if ($script:Ansi256Enabled) {
        return ([string]$script:Escape + '[38;5;' + $PaletteIndex.ToString() + 'm')
    }
    return ([string]$script:Escape + '[' + $FallbackCode.ToString() + 'm')
}

$script:Reset = if ($script:AnsiEnabled) { [string]$script:Escape + '[0m' } else { '' }
$script:Dim = if ($script:Ansi256Enabled) {
    Get-StatusColor -PaletteIndex 244 -FallbackCode 90
} elseif ($script:AnsiEnabled) {
    [string]$script:Escape + '[2m'
} else {
    ''
}
$script:Bright = if ($script:AnsiEnabled) { [string]$script:Escape + '[1m' } else { '' }
$script:Colors = @{
    cyan = Get-StatusColor -PaletteIndex 45 -FallbackCode 36
    yellow = Get-StatusColor -PaletteIndex 226 -FallbackCode 33
    red = Get-StatusColor -PaletteIndex 196 -FallbackCode 31
    green = Get-StatusColor -PaletteIndex 46 -FallbackCode 32
    mutedGreen = Get-StatusColor -PaletteIndex 108 -FallbackCode 32
    mutedRed = Get-StatusColor -PaletteIndex 131 -FallbackCode 31
    white = Get-StatusColor -PaletteIndex 15 -FallbackCode 37
}
$script:FilledGaugeChar = '█'
$script:EmptyGaugeChar = '░'
$script:SegmentSeparator = '  '
$script:UseStaticRunningGlyph = $true
$script:BranchDisplayWidth = 24
$script:CompactGroupSeparatorLines = @{}
$script:GroupSeparator = if ($script:AnsiEnabled) {
    ' ' + $script:Dim + '│' + $script:Reset + ' '
} else {
    ' │ '
}
$script:CompactGroupSeparator = ' '

function Get-ThresholdColor {
    param([double]$Percentage)

    if ($Percentage -ge 90) { return $script:Colors.red }
    if ($Percentage -ge 75) { return $script:Colors.yellow }
    return $script:Colors.cyan
}

function Get-GaugeBar {
    param([double]$Percentage, [int]$Width = 10, [switch]$Floor)

    $clamped = [math]::Min(100.0, [math]::Max(0.0, $Percentage))
    $filled = if ($Floor) {
        [int][math]::Floor($clamped * $Width / 100.0)
    } else {
        [int][math]::Round($clamped * $Width / 100.0, [MidpointRounding]::AwayFromZero)
    }
    $filled = [math]::Min($Width, [math]::Max(0, $filled))
    $empty = $Width - $filled
    $color = Get-ThresholdColor -Percentage $Percentage
    $filledPart = if ($filled -gt 0) { $script:FilledGaugeChar * $filled } else { '' }
    $emptyPart = if ($empty -gt 0) { $script:EmptyGaugeChar * $empty } else { '' }
    return $color + $script:Bright + $filledPart + $script:Reset +
        $script:Dim + $emptyPart + $script:Reset
}

function Format-LabeledValue {
    param([string]$Label, [string]$Value, [string]$ValueColor)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return $script:Dim + $Label + $script:Reset + ' ' +
        $script:Bright + $ValueColor + $Value + $script:Reset
}

function Get-FirstValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string[]]$Paths
    )

    foreach ($path in $Paths) {
        $current = $InputObject
        $found = $true
        foreach ($part in $path.Split('.')) {
            if ($null -eq $current) {
                $found = $false
                break
            }

            if ($current -is [System.Collections.IDictionary]) {
                if ($current.Contains($part)) {
                    $current = $current[$part]
                } else {
                    $found = $false
                    break
                }
            } else {
                $property = $current.PSObject.Properties[$part]
                if ($null -ne $property) {
                    $current = $property.Value
                } else {
                    $found = $false
                    break
                }
            }
        }

        if ($found -and $null -ne $current) {
            if ($current -is [string] -and [string]::IsNullOrWhiteSpace($current)) { continue }
            return $current
        }
    }

    return $null
}

function ConvertTo-NullableNumber {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    $number = 0.0
    $parsed = [double]::TryParse(
        [string]$Value,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    )
    if ($parsed -and [double]::IsFinite($number) -and $number -ge 0) { return $number }
    return $null
}

function Get-FirstNumber {
    param([object]$InputObject, [string[]]$Paths)
    return (ConvertTo-NullableNumber (Get-FirstValue -InputObject $InputObject -Paths $Paths))
}

function Get-ActiveActivityEntries {
    param(
        [AllowNull()][object]$State,
        [Parameter(Mandatory)][ValidateSet('tool', 'agent')][string]$Kind,
        [Parameter(Mandatory)][double]$Now
    )

    if ($State -isnot [System.Collections.IDictionary]) { return }
    $propertyName = if ($Kind -ceq 'tool') { 'activeTools' } else { 'activeSubagents' }
    $entries = $State[$propertyName]
    if ($entries -isnot [System.Collections.IEnumerable] -or
        $entries -is [string] -or $entries -is [System.Collections.IDictionary]) {
        return
    }

    $validEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        if ($entry -isnot [System.Collections.IDictionary] -and $entry -isnot [pscustomobject]) {
            continue
        }
        $startedAt = ConvertTo-NullableNumber -Value (Get-FirstValue `
            -InputObject $entry -Paths @('startedAtMs'))
        $timingReliable = Get-FirstValue -InputObject $entry -Paths @('timingReliable')
        if ($null -eq $startedAt -or $startedAt -gt $Now -or $timingReliable -isnot [bool]) {
            continue
        }

        if ($Kind -ceq 'tool') {
            $category = Get-FirstValue -InputObject $entry -Paths @('category')
            if ($category -isnot [string] -or
                $category -cnotin @('shell', 'edit', 'read', 'search', 'web', 'agent', 'prompt', 'tool') -or
                $Now - $startedAt -gt 300000) {
                continue
            }
        } else {
            $matchKey = Get-FirstValue -InputObject $entry -Paths @('matchKey')
            if ($matchKey -isnot [string] -or
                [string]::IsNullOrWhiteSpace($matchKey) -or
                $Now - $startedAt -gt 300000) {
                continue
            }
        }
        [void]$validEntries.Add($entry)
    }
    return $validEntries.ToArray()
}

function Format-Count {
    param([double]$Value)

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value -ge 1000000) {
        return ([math]::Round($Value / 1000000, 1)).ToString('0.#', $culture) + 'M'
    }
    if ($Value -ge 1000) {
        return ([math]::Round($Value / 1000, 1)).ToString('0.#', $culture) + 'k'
    }
    return ([math]::Round($Value)).ToString('0', $culture)
}

function Format-AicValue {
    param([double]$Value)

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value -ge 1000000) {
        return ([math]::Round($Value / 1000000, 2)).ToString('0.##', $culture) + 'M'
    }
    if ($Value -ge 1000) {
        return ([math]::Round($Value / 1000, 2)).ToString('0.##', $culture) + 'k'
    }
    if ([math]::Truncate($Value) -eq $Value) {
        return ([math]::Round($Value, 1)).ToString('0.0', $culture)
    }
    return ([math]::Round($Value, 2)).ToString('0.##', $culture)
}

function Format-Duration {
    param([double]$Milliseconds)

    $seconds = [long][math]::Max(0, [math]::Floor($Milliseconds / 1000))
    if ($seconds -ge 3600) {
        return ('{0}h{1:00}m' -f [math]::Floor($seconds / 3600), [math]::Floor(($seconds % 3600) / 60))
    }
    if ($seconds -ge 60) {
        return ('{0}m' -f [math]::Floor($seconds / 60))
    }
    return "${seconds}s"
}

function Format-SessionRuntime {
    param([double]$Milliseconds)

    $totalMinutes = [long][math]::Floor([math]::Max(0, $Milliseconds) / 60000)
    if ($totalMinutes -ge 1440) {
        $days = [long][math]::Floor($totalMinutes / 1440)
        $hours = [long][math]::Floor(($totalMinutes % 1440) / 60)
        return ('{0}d{1}h' -f $days, $hours)
    }
    if ($totalMinutes -ge 60) {
        $hours = [long][math]::Floor($totalMinutes / 60)
        $minutes = $totalMinutes % 60
        return ('{0}h{1}m' -f $hours, $minutes)
    }
    return ('{0}m' -f $totalMinutes)
}

function ConvertTo-SafeText {
    param([AllowNull()][object]$Value, [int]$MaximumLength = 64)

    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $text = [regex]::Replace($text, "`e\[[0-?]*[ -/]*[@-~]", '')
    $text = [regex]::Replace($text, '[\p{C}\p{Zl}\p{Zp}]+', ' ')
    $text = [regex]::Replace($text, '\s+', ' ').Trim()
    if ($text.Length -gt $MaximumLength) { $text = $text.Substring(0, $MaximumLength) }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function ConvertTo-ProjectLabel {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $normalized = $Path.Trim().Replace('/', '\').TrimEnd('\')
    if ($normalized -match '^[a-z][a-z0-9+.-]*://') { return $null }

    $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile).TrimEnd('\')
    if (-not [string]::IsNullOrWhiteSpace($profile)) {
        if ($normalized.Equals($profile, [StringComparison]::OrdinalIgnoreCase)) { return '~' }
        if ($normalized.StartsWith($profile + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $normalized.Substring($profile.Length).TrimStart('\')
            $relativeParts = @($relative -split '\\' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($relativeParts.Count -gt 2) { $relativeParts = @($relativeParts | Select-Object -Last 2) }
            $safeRelative = ConvertTo-SafeText -Value ([string]::Join('\', [string[]]$relativeParts)) -MaximumLength 48
            if ($safeRelative) { return '~\' + $safeRelative }
            return '~'
        }
    }

    $isUnc = $normalized.StartsWith('\\', [StringComparison]::Ordinal)
    $parts = @($normalized -split '\\' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (-not $isUnc -and $parts.Count -gt 0 -and $parts[0] -match '^[A-Za-z]:$') {
        $parts = @($parts | Select-Object -Skip 1)
    }
    if ($isUnc) {
        if ($parts.Count -eq 0) { return $null }
        return (ConvertTo-SafeText -Value ([string]$parts[-1]) -MaximumLength 48)
    }

    if ($parts.Count -ge 2 -and $parts[0] -match '^(?i:Users|home)$') {
        $parts = @($parts | Select-Object -Skip 2)
    }
    $privateNames = @($env:USERNAME, (Split-Path -Path $profile -Leaf)) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $parts = @($parts | Where-Object { $privateNames -notcontains $_ })
    if ($parts.Count -gt 2) { $parts = @($parts | Select-Object -Last 2) }
    if ($parts.Count -eq 0) { return 'cwd' }
    $safeLabel = ConvertTo-SafeText -Value ([string]::Join('\', [string[]]$parts)) -MaximumLength 48
    if ($safeLabel) { return $safeLabel }
    return 'cwd'
}

function Get-ProjectSegment {
    param([object]$Payload)

    $path = Get-FirstValue -InputObject $Payload -Paths @(
        'cwd', 'workspace.current_dir', 'workspace.currentDir',
        'working_directory', 'workingDirectory', 'project.cwd', 'session.cwd'
    )
    if ($null -eq $path) {
        try { $path = (Get-Location).Path } catch { return $null }
    }
    $label = ConvertTo-ProjectLabel -Path ([string]$path)
    if ($label) {
        return (Format-LabeledValue -Label 'cwd' -Value $label -ValueColor $script:Colors.white)
    }
    return $null
}

function Get-GitDirectoryFromMarker {
    param([string]$MarkerPath, [string]$RepositoryRoot)

    try {
        $markerAttributes = [System.IO.File]::GetAttributes($MarkerPath)
        if (($markerAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $null
        }
        if ([System.IO.Directory]::Exists($MarkerPath)) {
            return [System.IO.Path]::GetFullPath($MarkerPath)
        }
        if (-not [System.IO.File]::Exists($MarkerPath)) { return $null }
        $markerInfo = [System.IO.FileInfo]::new($MarkerPath)
        if ($markerInfo.Length -gt 1024) { return $null }
        $markerText = [System.IO.File]::ReadAllText(
            $MarkerPath,
            [System.Text.UTF8Encoding]::new($false)
        ).Trim()
        if ($markerText -notmatch '^gitdir:\s*(.+)$') { return $null }

        $gitDirectory = $Matches[1].Trim()
        if ([string]::IsNullOrWhiteSpace($gitDirectory)) { return $null }
        if (-not [System.IO.Path]::IsPathRooted($gitDirectory)) {
            $gitDirectory = Join-Path $RepositoryRoot $gitDirectory
        }
        $gitDirectory = [System.IO.Path]::GetFullPath($gitDirectory)
        $driveRoot = [System.IO.Path]::GetPathRoot($gitDirectory)
        if ($driveRoot -notmatch '^[A-Za-z]:\\') { return $null }
        $gitAttributes = [System.IO.File]::GetAttributes($gitDirectory)
        if (($gitAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $null
        }
        $drive = [System.IO.DriveInfo]::new($driveRoot)
        if ($drive.DriveType -notin @(
            [System.IO.DriveType]::Fixed,
            [System.IO.DriveType]::Removable,
            [System.IO.DriveType]::Ram
        ) -or -not [System.IO.Directory]::Exists($gitDirectory)) {
            return $null
        }
        return $gitDirectory
    } catch {
        return $null
    }
}

function Get-LocalGitBranch {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') {
        return $null
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $driveRoot = [System.IO.Path]::GetPathRoot($fullPath)
        $drive = [System.IO.DriveInfo]::new($driveRoot)
        if ($drive.DriveType -notin @(
            [System.IO.DriveType]::Fixed,
            [System.IO.DriveType]::Removable,
            [System.IO.DriveType]::Ram
        ) -or -not [System.IO.Directory]::Exists($fullPath)) {
            return $null
        }

        $directory = [System.IO.DirectoryInfo]::new($fullPath)
        for ($depth = 0; $null -ne $directory -and $depth -lt 64; $depth++) {
            if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $null
            }
            $markerPath = Join-Path $directory.FullName '.git'
            if ([System.IO.Directory]::Exists($markerPath) -or
                [System.IO.File]::Exists($markerPath)) {
                $gitDirectory = Get-GitDirectoryFromMarker `
                    -MarkerPath $markerPath -RepositoryRoot $directory.FullName
                if (-not $gitDirectory) { return $null }

                $headPath = Join-Path $gitDirectory 'HEAD'
                if (-not [System.IO.File]::Exists($headPath)) { return $null }
                $headAttributes = [System.IO.File]::GetAttributes($headPath)
                if (($headAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    return $null
                }
                $headInfo = [System.IO.FileInfo]::new($headPath)
                if ($headInfo.Length -gt 1024) { return $null }
                $head = [System.IO.File]::ReadAllText(
                    $headPath,
                    [System.Text.UTF8Encoding]::new($false)
                ).Trim()

                if ($head -match '^ref:\s+refs/heads/(.+)$') {
                    $branch = $Matches[1]
                } elseif ($head -match '^(?:[A-Fa-f0-9]{40}|[A-Fa-f0-9]{64})$') {
                    return 'detached'
                } else {
                    return $null
                }

                $branch = ConvertTo-SafeText -Value $branch -MaximumLength 1024
                if (-not $branch -or
                    $branch -match '(?i)(https?://|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|(token|secret|password|api[_ -]?key|authorization|bearer)\s*[:=])' -or
                    $branch -match '^[A-Fa-f0-9-]{32,}$') {
                    return $null
                }
                return $branch
            }
            $directory = $directory.Parent
        }
    } catch {
        return $null
    }
    return $null
}

function Get-BranchSegment {
    param([object]$Payload)

    # Resolve only from the statusline payload cwd, never the process working directory.
    $cwd = Get-FirstValue -InputObject $Payload -Paths @('cwd')
    if ($cwd -isnot [string]) { return $null }
    $branch = Get-LocalGitBranch -Path $cwd
    if (-not $branch) { return $null }
    $displayBranch = $branch
    if ($displayBranch.Length -gt $script:BranchDisplayWidth) {
        $displayBranch = $displayBranch.Substring(
            0,
            $script:BranchDisplayWidth - 3
        ) + '...'
    }
    return $script:Colors.yellow + $displayBranch + $script:Reset
}

function Format-ContextInputCount {
    param([double]$Value)

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value -ge 1000000) {
        return ([math]::Round($Value / 1000000, 1)).ToString('0.#', $culture) + 'M'
    }
    if ($Value -ge 1000) {
        return ([math]::Round($Value / 1000, 1)).ToString('0.0', $culture) + 'k'
    }
    return (Format-Count $Value)
}

function Get-ContextSegmentData {
    param([object]$Payload, [int]$GaugeWidth = 8)

    $lastInput = Get-FirstNumber -InputObject $Payload -Paths @(
        'context_window.last_call_input_tokens'
    )
    if ($null -eq $lastInput) { return $null }

    $windowSize = Get-FirstNumber -InputObject $Payload -Paths @(
        'context_window.context_window_size'
    )
    $percentage = $null
    if ($null -ne $windowSize -and $windowSize -gt 0) {
        $percentage = Get-FirstNumber -InputObject $Payload -Paths @(
            'context_window.used_percentage'
        )
        if ($null -eq $percentage) {
            $percentage = 100.0 * $lastInput / $windowSize
        }
        $percentage = [math]::Min(100.0, [math]::Max(0.0, $percentage))
    }

    return [pscustomobject]@{
        LastInput = $lastInput
        WindowSize = $windowSize
        Percentage = $percentage
        GaugeWidth = $GaugeWidth
    }
}

function Get-ContextGaugeSegment {
    param([AllowNull()][object]$ContextData)

    if ($null -eq $ContextData) { return $null }
    if ($null -eq $ContextData.WindowSize -or $ContextData.WindowSize -le 0) {
        return (Format-LabeledValue -Label 'Ctx' `
            -Value "in $(Format-Count $ContextData.LastInput)" `
            -ValueColor $script:Colors.white)
    }
    return $script:Dim + 'Ctx' + $script:Reset + ' ' +
        (Get-GaugeBar -Percentage $ContextData.Percentage -Width $ContextData.GaugeWidth)
}

function Get-ContextAbsoluteSegment {
    param([AllowNull()][object]$ContextData)

    if ($null -eq $ContextData -or
        $null -eq $ContextData.WindowSize -or $ContextData.WindowSize -le 0) {
        return $null
    }
    return (Format-ContextInputCount $ContextData.LastInput) + '/' +
        (Format-Count $ContextData.WindowSize)
}

function Get-ContextPercentageSegment {
    param([AllowNull()][object]$ContextData)

    if ($null -eq $ContextData -or $null -eq $ContextData.Percentage) { return $null }
    $roundedPercentage = [int][math]::Round(
        $ContextData.Percentage,
        0,
        [MidpointRounding]::AwayFromZero
    )
    $color = Get-ThresholdColor -Percentage $ContextData.Percentage
    return $script:Bright + $color + "$roundedPercentage%" + $script:Reset
}

function Get-TokenSegment {
    param([object]$Payload)

    $inputTokens = Get-FirstNumber -InputObject $Payload -Paths @(
        'context_window.total_input_tokens'
    )
    $outputTokens = Get-FirstNumber -InputObject $Payload -Paths @(
        'context_window.total_output_tokens'
    )
    $cacheRead = Get-FirstNumber -InputObject $Payload -Paths @(
        'context_window.total_cache_read_tokens'
    )
    $cacheWrite = Get-FirstNumber -InputObject $Payload -Paths @(
        'context_window.total_cache_write_tokens'
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $inputTokens) {
        [void]$parts.Add($script:Dim + 'I ' + $script:Reset +
            $script:Dim + (Format-Count $inputTokens) + $script:Reset)
    }
    if ($null -ne $outputTokens) {
        [void]$parts.Add($script:Dim + 'O ' + $script:Reset +
            $script:Dim + (Format-Count $outputTokens) + $script:Reset)
    }
    if ($null -ne $cacheRead -or $null -ne $cacheWrite) {
        $cached = ($cacheRead ?? 0) + ($cacheWrite ?? 0)
        [void]$parts.Add($script:Dim + 'C ' + $script:Reset +
            $script:Dim + (Format-Count $cached) + $script:Reset)
    }
    if ($parts.Count -eq 0) { return $null }
    return [string]::Join($script:Dim + ' · ' + $script:Reset, $parts)
}

function Get-QuotaData {
    $copilotHome = if (-not [string]::IsNullOrWhiteSpace($env:COPILOT_HOME)) {
        $env:COPILOT_HOME
    } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Join-Path $env:USERPROFILE '.copilot'
    } else {
        return $null
    }
    $path = Join-Path $copilotHome 'hud-quota.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    if ((Get-Item -LiteralPath $path).Length -gt 65536) { return $null }
    $data = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($null -eq $data.updatedAt -or ($nowMs - [double]$data.updatedAt) -gt 600000) {
        return $null
    }
    $quota = @($data.quotas) | Where-Object {
        $_.unlimited -eq $false -and [double]$_.entitlement -gt 0
    } | Sort-Object { [double]$_.entitlement } -Descending | Select-Object -First 1
    if ($null -eq $quota) { return $null }

    $used = [double]$quota.used
    $entitlement = [double]$quota.entitlement
    $days = $null
    $reset = [DateTimeOffset]::MinValue
    $resetText = if ($quota.resetDate -is [datetime]) {
        $quota.resetDate.ToUniversalTime().ToString('o')
    } else { [string]$quota.resetDate }
    if ([DateTimeOffset]::TryParse($resetText, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$reset)) {
        $d = [int][math]::Ceiling(($reset - [DateTimeOffset]::UtcNow).TotalDays)
        if ($d -ge 0) { $days = $d }
    }
    $percentage = [math]::Min(100.0, [math]::Max(0.0, 100.0 * $used / $entitlement))
    $delta = $null
    $perDay = $null
    if ($null -ne $days) {
        $end = $reset.UtcDateTime.Date
        $start = $end.AddMonths(-1)
        $today = [DateTime]::Today
        $elapsed = 0
        $remaining = 0
        for ($day = $start; $day -lt $end; $day = $day.AddDays(1)) {
            if ($day.DayOfWeek -eq [DayOfWeek]::Saturday -or
                $day.DayOfWeek -eq [DayOfWeek]::Sunday) { continue }
            if ($day -lt $today) { $elapsed++ } else { $remaining++ }
        }
        $total = $elapsed + $remaining
        if ($total -gt 0) {
            $delta = $percentage - (100.0 * $elapsed / $total)
        }
        if ($remaining -gt 0 -and $used -lt $entitlement) {
            $perDay = ($entitlement - $used) / $remaining
        }
    }
    return [pscustomobject]@{
        Used = $used
        Entitlement = $entitlement
        Percentage = $percentage
        Days = $days
        PaceDelta = $delta
        PerWorkday = $perDay
    }
}

function Get-QuotaSegment {
    param([AllowNull()][object]$QuotaData)

    if ($null -eq $QuotaData) { return $null }
    $color = Get-ThresholdColor -Percentage $QuotaData.Percentage
    $rounded = [int][math]::Floor($QuotaData.Percentage)
    return $script:Dim + 'Quota' + $script:Reset + ' ' +
        (Get-GaugeBar -Percentage $QuotaData.Percentage -Width 8 -Floor) + ' ' +
        $script:Bright + $color + "$rounded%" + $script:Reset
}

function Get-QuotaDetailSegment {
    param([AllowNull()][object]$QuotaData)

    if ($null -eq $QuotaData) { return $null }
    return $script:Dim + (Format-Count $QuotaData.Used) + '/' +
        (Format-Count $QuotaData.Entitlement) + $script:Reset
}

function Get-QuotaPaceSegment {
    param([AllowNull()][object]$QuotaData)

    if ($null -eq $QuotaData) { return $null }
    $text = ''
    if ($null -ne $QuotaData.PaceDelta) {
        $points = [int][math]::Round($QuotaData.PaceDelta, 0, [MidpointRounding]::AwayFromZero)
        if ($points -gt 5) {
            $color = if ($points -gt 15) { $script:Colors.red } else { $script:Colors.yellow }
            $text = $script:Bright + $color + "▲+$points%" + $script:Reset
        } elseif ($points -lt -5) {
            $text = $script:Colors.cyan + "▼$points%" + $script:Reset
        } else {
            $text = $script:Dim + '● on pace' + $script:Reset
        }
    }
    if ($null -ne $QuotaData.PerWorkday) {
        $budget = '⚡' + $script:Dim + (Format-Count ([math]::Floor($QuotaData.PerWorkday))) + '/workday' + $script:Reset
        $text = if ($text) { $text + $script:Dim + ' · ' + $script:Reset + $budget } else { $budget }
    }
    if ($text) { return $text }
    return $null
}

function Get-QuotaDaysSegment {
    param([AllowNull()][object]$QuotaData)

    if ($null -eq $QuotaData -or $null -eq $QuotaData.Days) { return $null }
    $dayText = if ($QuotaData.Days -eq 0) { '<1d left' } else { "$($QuotaData.Days)d left" }
    return $script:Dim + $dayText + $script:Reset
}
function Get-RateSegment {
    param([object]$Payload)

    $rate = Get-FirstNumber -InputObject $Payload -Paths @(
        'tokens_per_second', 'tokensPerSecond', 'metrics.tokens_per_second',
        'metrics.tokensPerSecond', 'usage.tokens_per_second',
        'cost.tokens_per_second', 'cost.tokensPerSecond',
        'performance.tokens_per_second', 'performance.tokensPerSecond',
        'usage.tokensPerSecond'
    )
    if ($null -eq $rate) {
        $lastOutput = Get-FirstNumber -InputObject $Payload -Paths @(
            'context_window.last_call_output_tokens', 'contextWindow.lastCallOutputTokens',
            'last_call_output_tokens', 'lastCallOutputTokens'
        )
        $lastDuration = Get-FirstNumber -InputObject $Payload -Paths @(
            'cost.last_call_api_duration_ms', 'cost.last_call_duration_ms',
            'cost.last_call_total_duration_ms', 'last_call.duration_ms',
            'cost.lastCallApiDurationMs', 'cost.lastCallDurationMs',
            'cost.lastCallTotalDurationMs', 'lastCall.durationMs',
            'metrics.last_call_duration_ms', 'metrics.lastCallDurationMs'
        )
        if ($null -ne $lastOutput -and $null -ne $lastDuration -and $lastDuration -gt 0) {
            $rate = 1000.0 * $lastOutput / $lastDuration
        }
    }
    if ($null -eq $rate) {
        $totalOutput = Get-FirstNumber -InputObject $Payload -Paths @(
            'context_window.total_output_tokens', 'contextWindow.totalOutputTokens',
            'total_output_tokens', 'totalOutputTokens'
        )
        $apiDuration = Get-FirstNumber -InputObject $Payload -Paths @(
            'cost.total_api_duration_ms', 'cost.totalApiDurationMs',
            'api_duration_ms', 'apiDurationMs'
        )
        if ($null -ne $totalOutput -and $null -ne $apiDuration -and $apiDuration -gt 0) {
            $rate = 1000.0 * $totalOutput / $apiDuration
        }
    }
    if ($null -eq $rate) { return $null }

    $formatted = ([math]::Round($rate, 1)).ToString('0.#', [System.Globalization.CultureInfo]::InvariantCulture)
    return $script:Bright + $script:Colors.cyan + $formatted + $script:Reset +
        ' ' + $script:Dim + 'tok/s' + $script:Reset
}

function Get-AicSegment {
    param([object]$Payload)

    $aic = Get-FirstNumber -InputObject $Payload -Paths @('ai_used.formatted')
    if ($null -eq $aic) { return $null }
    return (Format-LabeledValue -Label 'AIC' -Value (Format-AicValue $aic) `
        -ValueColor $script:Colors.white)
}

function Get-RecentAicSegment {
    param([AllowNull()][object]$SignalState)

    if ($SignalState -isnot [System.Collections.IDictionary]) { return $null }
    $delta = $SignalState['recentIncreaseNanoAiu']
    $recordedAt = ConvertTo-NullableNumber -Value $SignalState['recentAtMs']
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $placeholder = Format-LabeledValue -Label 'recent' -Value ([string][char]0x2014) `
        -ValueColor $script:Dim
    if ($null -eq $delta) { return $placeholder }
    if ($delta -is [bool] -or $delta -isnot [ValueType] -or
        $null -eq $recordedAt -or $delta -lt 0 -or
        [double]$delta -gt 9007199254740991 -or
        [double]$delta -ne [math]::Truncate([double]$delta) -or
        $recordedAt -gt $now + 5000) {
        return $null
    }
    if ($now - $recordedAt -gt 120000) { return $placeholder }

    $aiu = [double]$delta / 1000000000.0
    $formatted = $aiu.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
    if ($aiu -gt 0 -and $formatted -eq '0.00') {
        $formatted = $aiu.ToString('0.#########', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return (Format-LabeledValue -Label 'recent' -Value ('+' + $formatted + ' AIU') `
        -ValueColor $script:Colors.green)
}

function Get-PremiumRequestsSegment {
    param([object]$Payload)

    $premium = Get-FirstNumber -InputObject $Payload -Paths @(
        'cost.total_premium_requests', 'cost.totalPremiumRequests',
        'total_premium_requests', 'totalPremiumRequests'
    )
    if ($null -eq $premium) { return $null }
    return (Format-LabeledValue -Label 'premium req' -Value (Format-Count $premium) `
        -ValueColor $script:Colors.yellow)
}

function Get-LinesSegment {
    param([object]$Payload)

    $added = Get-FirstNumber -InputObject $Payload -Paths @(
        'cost.total_lines_added', 'cost.totalLinesAdded', 'total_lines_added', 'totalLinesAdded'
    )
    $removed = Get-FirstNumber -InputObject $Payload -Paths @(
        'cost.total_lines_removed', 'cost.totalLinesRemoved', 'total_lines_removed', 'totalLinesRemoved'
    )
    if ($null -eq $added -and $null -eq $removed) { return $null }
    if ($null -eq $added) { $added = 0 }
    if ($null -eq $removed) { $removed = 0 }
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $addedText = if ($added -ge 1000) {
        ([math]::Ceiling($added / 100) / 10).ToString('0.#', $culture) + 'k'
    } else {
        ([math]::Round($added)).ToString('0', $culture)
    }
    $removedText = if ($removed -ge 1000) {
        ([math]::Ceiling($removed / 100) / 10).ToString('0.#', $culture) + 'k'
    } else {
        ([math]::Round($removed)).ToString('0', $culture)
    }
    return $script:Colors.mutedGreen + '+' + $addedText + $script:Reset +
        $script:Dim + '/' + $script:Reset +
        $script:Colors.mutedRed + '-' + $removedText + $script:Reset
}

function Get-SessionState {
    param([object]$Payload)

    try {
        $sessionId = Get-FirstValue -InputObject $Payload -Paths @('session_id')
        if ($null -eq $sessionId) { return $null }
        $sessionId = [string]$sessionId
        if ($sessionId -notmatch '^[A-Za-z0-9_-]{1,128}$') { return $null }

        $copilotHome = if (-not [string]::IsNullOrWhiteSpace($env:COPILOT_HOME)) {
            $env:COPILOT_HOME
        } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            Join-Path $env:USERPROFILE '.copilot'
        } else {
            return $null
        }
        $statePath = Join-Path (Join-Path $copilotHome 'state') "hud-state-$sessionId.json"
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }

        $state = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($state -is [System.Collections.IDictionary] -and
            [string]$state['sessionId'] -ceq $sessionId) {
            return $state
        }
    } catch {
        return $null
    }
    return $null
}

function Test-HudSignalInteger {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [bool] -or $Value -isnot [ValueType]) {
        return $false
    }
    $number = ConvertTo-NullableNumber -Value $Value
    return $null -ne $number -and $number -ge 0 -and
        $number -le 9007199254740991 -and
        $number -eq [math]::Truncate($number)
}

function Get-HudSignalState {
    param([object]$Payload)

    $stream = $null
    try {
        if ([Environment]::GetEnvironmentVariable('COPILOT_HUD_SIGNAL_BRIDGE') -cne '1') {
            return $null
        }
        $sessionId = Get-FirstValue -InputObject $Payload -Paths @('session_id')
        $copilotHome = [Environment]::GetEnvironmentVariable('COPILOT_HOME')
        if ($sessionId -isnot [string] -or
            $sessionId -notmatch '^[A-Za-z0-9_-]{1,128}$' -or
            [string]::IsNullOrWhiteSpace($copilotHome) -or
            $copilotHome -notmatch '^[A-Za-z]:[\\/]') {
            return $null
        }

        $stateBase = Join-Path $copilotHome 'state'
        $stateDirectory = Join-Path $stateBase 'hud-signal-bridge'
        foreach ($directory in @($stateBase, $stateDirectory)) {
            if (-not [System.IO.Directory]::Exists($directory)) { return $null }
            $directoryAttributes = [System.IO.File]::GetAttributes($directory)
            if (($directoryAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $null
            }
        }
        $statePath = Join-Path $stateDirectory "hud-signal-$sessionId.json"
        if (-not [System.IO.File]::Exists($statePath)) { return $null }
        $attributes = [System.IO.File]::GetAttributes($statePath)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $null
        }

        $stream = [System.IO.FileStream]::new(
            $statePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        $length = $stream.Length
        if ($length -le 0 -or $length -gt 4096) { return $null }
        $bytes = [byte[]]::new([int]$length)
        $offset = 0
        while ($offset -lt $length) {
            $read = $stream.Read($bytes, $offset, [int]($length - $offset))
            if ($read -le 0) { return $null }
            $offset += $read
        }
        $stream.Dispose()
        $stream = $null

        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $state = ConvertFrom-Json -InputObject $text -AsHashtable -ErrorAction Stop
        $requiredProperties = @(
            'version', 'sessionId', 'updatedAtMs', 'phase', 'phaseAtMs',
            'recentIncreaseNanoAiu', 'recentAtMs'
        )
        $allowedProperties = $requiredProperties + @('activeSubagentCount')
        if ($state -isnot [System.Collections.IDictionary]) { return $null }
        $stateKeys = @($state.Keys)
        if (@($requiredProperties | Where-Object { $_ -cnotin $stateKeys }).Count -gt 0 -or
            @($stateKeys | Where-Object { $_ -cnotin $allowedProperties }).Count -gt 0 -or
            -not (Test-HudSignalInteger $state['version']) -or
            [long]$state['version'] -ne 1 -or
            $state['sessionId'] -isnot [string] -or
            $state['sessionId'] -cne $sessionId -or
            -not (Test-HudSignalInteger $state['updatedAtMs'])) {
            return $null
        }

        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $updatedAt = [double]$state['updatedAtMs']
        if ($updatedAt -gt $now + 5000 -or $now - $updatedAt -gt 20000) {
            return $null
        }

        $phase = $state['phase']
        $phaseAt = $state['phaseAtMs']
        if ($null -ne $phase) {
            if ($phase -isnot [string] -or
                $phase -cnotin @('working', 'running_tool', 'complete', 'idle') -or
                -not (Test-HudSignalInteger $phaseAt) -or
                [double]$phaseAt -gt $now + 5000) {
                return $null
            }
            if ($phase -ceq 'complete' -and $now - [double]$phaseAt -gt 10000) {
                $phase = $null
                $phaseAt = $null
            }
        } elseif ($null -ne $phaseAt) {
            return $null
        }

        $recentDelta = $state['recentIncreaseNanoAiu']
        $recentAt = $state['recentAtMs']
        if ($null -ne $recentDelta) {
            if (-not (Test-HudSignalInteger $recentDelta) -or
                -not (Test-HudSignalInteger $recentAt) -or
                [double]$recentAt -gt $now + 5000) {
                return $null
            }
            if ($now - [double]$recentAt -gt 120000) {
                $recentDelta = $null
                $recentAt = $null
            }
        } elseif ($null -ne $recentAt) {
            return $null
        }

        $activeSubagentCount = $null
        if ($stateKeys -ccontains 'activeSubagentCount') {
            $activeSubagentCount = $state['activeSubagentCount']
            if ($null -ne $activeSubagentCount -and
                (-not (Test-HudSignalInteger $activeSubagentCount) -or
                    [long]$activeSubagentCount -gt 16)) {
                return $null
            }
        }

        return [ordered]@{
            phase = $phase
            phaseAtMs = $phaseAt
            recentIncreaseNanoAiu = $recentDelta
            recentAtMs = $recentAt
            activeSubagentCount = $activeSubagentCount
        }
    } catch {
        return $null
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-HudPhaseSegment {
    param([AllowNull()][object]$SignalState)

    if ($SignalState -isnot [System.Collections.IDictionary]) { return $null }
    switch ([string]$SignalState['phase']) {
        'working' {
            $glyph = $script:Bright + $script:Colors.yellow + '◐' + $script:Reset
            $label = 'Working'
        }
        'running_tool' {
            $glyph = $script:Bright + $script:Colors.yellow + '◐' + $script:Reset
            $label = 'Running tool'
        }
        'complete' {
            $glyph = $script:Bright + $script:Colors.green + '✓' + $script:Reset
            $label = 'Assistant turn complete'
        }
        default { return $null }
    }
    return $glyph + ' ' + $script:Bright + $script:Colors.white + $label + $script:Reset
}

function Get-HudSubagentSegment {
    param([AllowNull()][object]$SignalState)

    if ($SignalState -isnot [System.Collections.IDictionary]) { return $null }
    $count = ConvertTo-NullableNumber -Value $SignalState['activeSubagentCount']
    if ($null -eq $count -or $count -lt 1 -or $count -gt 16 -or
        $count -ne [math]::Truncate($count)) {
        return $null
    }
    $label = if ($count -eq 1) { '1 subagent' } else { "$([long]$count) subagents" }
    $glyph = $script:Bright + $script:Colors.yellow + '◐' + $script:Reset
    return $glyph + ' ' + $script:Bright + $script:Colors.white + $label + $script:Reset
}

function Save-FirstStatuslinePayload {
    param([AllowNull()][string]$Raw, [object]$Payload)

    $temporaryPath = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Raw) -or
            $Payload -isnot [System.Collections.IDictionary]) {
            return
        }
        $sessionId = Get-FirstValue -InputObject $Payload -Paths @('session_id')
        if ($sessionId -isnot [string] -or $sessionId -notmatch '^[A-Za-z0-9_-]{1,128}$') {
            return
        }

        $copilotHome = if (-not [string]::IsNullOrWhiteSpace($env:COPILOT_HOME)) {
            $env:COPILOT_HOME
        } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            Join-Path $env:USERPROFILE '.copilot'
        } else {
            return
        }
        $stateDirectory = Join-Path $copilotHome 'state'
        [void][System.IO.Directory]::CreateDirectory($stateDirectory)
        $path = Join-Path $stateDirectory "raw-statusline-$sessionId.json"
        if ([System.IO.File]::Exists($path)) { return }

        $temporaryPath = Join-Path $stateDirectory (
            ".raw-statusline-$sessionId.$PID.$([guid]::NewGuid().ToString('N')).tmp"
        )
        [System.IO.File]::WriteAllText($temporaryPath, $Raw, $utf8)
        try {
            [System.IO.File]::Move($temporaryPath, $path)
        } catch [System.IO.IOException] {
            if (-not [System.IO.File]::Exists($path)) { throw }
        }
    } catch {
    } finally {
        if ($null -ne $temporaryPath -and [System.IO.File]::Exists($temporaryPath)) {
            try { [System.IO.File]::Delete($temporaryPath) } catch {}
        }
    }
}

function Get-RuntimeSegment {
    param([AllowNull()][object]$State)

    if ($State -isnot [System.Collections.IDictionary]) { return $null }
    $startedAt = ConvertTo-NullableNumber -Value $State['createdAtMs']
    if ($null -eq $startedAt) { return $null }
    $elapsed = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $startedAt
    if ($elapsed -lt 0 -or $elapsed -gt 31536000000) { return $null }
    $duration = Format-SessionRuntime $elapsed
    if ($duration -notmatch '^\d') { return $null }
    return $script:Bright + $script:Colors.white + $duration + $script:Reset
}

function Get-SpinnerGlyph {
    param([object]$Payload, [AllowNull()][object]$State)

    if ($script:UseStaticRunningGlyph) { return '◐' }
    $frames = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
    $fallback = '◐'
    $stream = $null
    try {
        $sessionId = Get-FirstValue -InputObject $Payload -Paths @('session_id')
        if ($null -eq $sessionId -and $State -is [System.Collections.IDictionary]) {
            $sessionId = $State['sessionId']
        }
        $sessionId = [string]$sessionId
        if ($sessionId -notmatch '^[A-Za-z0-9_-]{1,128}$') { return $fallback }

        $copilotHome = if (-not [string]::IsNullOrWhiteSpace($env:COPILOT_HOME)) {
            $env:COPILOT_HOME
        } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            Join-Path $env:USERPROFILE '.copilot'
        } else {
            return $fallback
        }
        $stateDirectory = Join-Path $copilotHome 'state'
        if (-not [System.IO.Directory]::Exists($stateDirectory)) { return $fallback }
        $framePath = Join-Path $stateDirectory "statusline-animation-$sessionId.frame"
        $stream = [System.IO.FileStream]::new(
            $framePath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $buffer = [byte[]]::new(16)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $text = if ($read -gt 0) {
            [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read).Trim()
        } else {
            ''
        }
        $frame = 0
        if ([int]::TryParse($text, [ref]$frame) -and $frame -ge 0 -and $frame -lt $frames.Length) {
            $nextFrame = ($frame + 1) % $frames.Length
        } else {
            $frame = 0
            $nextFrame = 1
        }
        $nextBytes = [System.Text.Encoding]::ASCII.GetBytes([string]$nextFrame)
        $stream.SetLength(0)
        $stream.Position = 0
        $stream.Write($nextBytes, 0, $nextBytes.Length)
        $stream.Flush()
        return $frames[$frame]
    } catch {
        return $fallback
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function ConvertTo-ActivityToolName {
    param([AllowNull()][object]$Tool)

    $value = Get-FirstValue -InputObject $Tool -Paths @('toolName')
    $name = ConvertTo-SafeText -Value $value -MaximumLength 128
    if ($name -and $name.Length -le 24 -and
        $name -match '^[\p{L}][\p{L}\p{N}_.-]{0,23}$' -and
        $name -notmatch '(?i)(https?://|token|secret|password|api[_ -]?key)') {
        return $name
    }

    $category = Get-FirstValue -InputObject $Tool -Paths @('category')
    $name = ConvertTo-SafeText -Value $category -MaximumLength 128
    if ($name -and $name.Length -le 24 -and
        $name -match '^[\p{L}][\p{L}\p{N}_.-]{0,23}$' -and
        $name -notmatch '(?i)(https?://|token|secret|password|api[_ -]?key)') {
        return $name
    }
    return 'tool'
}

function ConvertTo-ActivityTarget {
    param([AllowNull()][object]$Value)

    $text = ConvertTo-SafeText -Value $Value -MaximumLength 256
    if (-not $text) { return $null }
    if ($text -match '(?i)https?://') { return 'remote' }
    if ($text -match '(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}') { return $null }
    if ($text -match '(?i)(token|secret|password|api[_ -]?key|authorization|bearer)\s*[:=]') {
        return $null
    }

    if ($text.Contains('\') -or $text.Contains('/') -or $text -match '^[A-Za-z]:') {
        $label = ConvertTo-ProjectLabel -Path $text
        if (-not $label) { return $null }
        $parts = @($label -split '\\' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($parts.Count -gt 2) { $parts = @($parts | Select-Object -Last 2) }
        $label = [string]::Join('\', [string[]]$parts)
        if ($label.Length -gt 24 -and $parts.Count -gt 0) { $label = [string]$parts[-1] }
        if ($label.Length -gt 24) { return $null }
        return $label
    }

    if ($text -match '^[A-Fa-f0-9-]{32,}$' -or $text -match '^\d{6,}$') { return $null }
    if ($text -notmatch '^[\p{L}\p{N}_.-]{1,24}$') { return $null }
    if ($text -match '(?i)^[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.(?:com|net|org|io|dev|app|internal|local|corp|lan|localhost)$') {
        return 'remote'
    }
    $privateNames = @($env:USERNAME, (Split-Path -Path ([Environment]::GetFolderPath(
        [Environment+SpecialFolder]::UserProfile
    )) -Leaf)) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($privateNames -contains $text) { return $null }
    return $text
}

function Get-ActivityTarget {
    param([AllowNull()][object]$Tool, [object]$Payload)

    $value = Get-FirstValue -InputObject $Tool -Paths @('target')
    if ($null -eq $value) { $value = Get-FirstValue -InputObject $Payload -Paths @('toolArgs.path') }
    if ($null -eq $value) { return 'target' }
    $target = ConvertTo-ActivityTarget -Value $value
    if ($target) { return $target }
    return 'target'
}

function Get-AgentLabel {
    param([AllowNull()][object]$Agent)

    $value = Get-FirstValue -InputObject $Agent -Paths @('matchKey')
    $label = ConvertTo-SafeText -Value $value -MaximumLength 20
    if (-not $label -or $label -eq '__unknown__' -or
        $label -match '(?i)(https?://|token|secret|password|api[_ -]?key)' -or
        $label -match '^[A-Fa-f0-9-]{32,}$' -or
        $label -match '(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' -or
        $label -match '(?i)[A-Z0-9-]+\.(?:com|net|org|io|dev|app|internal|local|corp|lan|localhost)$') {
        return $null
    }
    return $label
}

function Get-ActivitySegment {
    param([object]$Payload, [AllowNull()][object]$State)

    try {
        if ($State -isnot [System.Collections.IDictionary]) { return $null }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $activeTools = @(Get-ActiveActivityEntries -State $State -Kind tool -Now $now)
        if ($activeTools.Count -gt 0) {
            $groups = [System.Collections.Generic.List[object]]::new()
            foreach ($tool in $activeTools) {
                $name = ConvertTo-ActivityToolName -Tool $tool
                $target = Get-ActivityTarget -Tool $tool -Payload $Payload
                $key = $name + '|' + $target.ToLowerInvariant()
                $group = $null
                foreach ($candidate in $groups) {
                    if ($candidate.key -ceq $key) {
                        $group = $candidate
                        break
                    }
                }
                if ($null -eq $group) {
                    [void]$groups.Add([pscustomobject]@{
                        key = $key
                        name = $name
                        target = $target
                        count = 1
                        startedAtMs = $tool['startedAtMs']
                        timingReliable = ($tool['timingReliable'] -ne $false)
                    })
                } else {
                    $group.count++
                }
            }

            $first = $groups[0]
            $elapsedText = ''
            $startedAt = ConvertTo-NullableNumber -Value $first.startedAtMs
            if ($first.timingReliable -and $null -ne $startedAt) {
                $elapsedText = ' ' + (Format-Duration ([math]::Max(0, $now - $startedAt)))
            }
            if ($elapsedText) { $elapsedText = $script:Dim + $elapsedText + $script:Reset }
            $repeatText = if ($first.count -gt 1) {
                $script:Bright + $script:Colors.cyan + " x$($first.count)" + $script:Reset
            } else {
                ''
            }
            $otherText = if ($groups.Count -gt 1) {
                $script:Dim + " +$($groups.Count - 1)" + $script:Reset
            } else {
                ''
            }
            $runningText = $script:Dim + ' running' + $script:Reset
            $glyph = $script:Bright + $script:Colors.cyan + '◐' + $script:Reset
            return $script:Dim + 'activity' + $script:Reset + ' ' + $glyph + ' ' +
                $script:Bright + $script:Colors.white + $first.name + $script:Reset + ' -> ' +
                $script:Dim + $first.target + $script:Reset + $elapsedText +
                $repeatText + $otherText + $runningText
        }

        $lastTool = $State['lastTool']
        if ($lastTool -is [System.Collections.IDictionary]) {
            $completedAt = ConvertTo-NullableNumber -Value $lastTool['completedAtMs']
            $status = [string]$lastTool['status']
            $category = Get-FirstValue -InputObject $lastTool -Paths @('category')
            if ($status -cnotin @('complete', 'failed') -or
                $category -isnot [string] -or
                $category -cnotin @('shell', 'edit', 'read', 'search', 'web', 'agent', 'prompt', 'tool')) {
                return $null
            }
            if ($null -ne $completedAt -and $now -ge $completedAt -and $now - $completedAt -le 30000) {
                $name = ConvertTo-ActivityToolName -Tool $lastTool
                $target = Get-ActivityTarget -Tool $lastTool -Payload $Payload
                $durationText = ''
                $duration = ConvertTo-NullableNumber -Value $lastTool['durationMs']
                if ($null -ne $duration) { $durationText = ' ' + (Format-Duration $duration) }
                if ($durationText) { $durationText = $script:Dim + $durationText + $script:Reset }
                $glyph = if ($status -ceq 'failed') {
                    $script:Bright + $script:Colors.red + '✗' + $script:Reset
                } else {
                    $script:Bright + $script:Colors.green + '✓' + $script:Reset
                }
                $completeText = if ($status -ceq 'failed') {
                    $script:Dim + ' failed' + $script:Reset
                } else {
                    $script:Dim + ' complete' + $script:Reset
                }
                return $script:Dim + 'activity' + $script:Reset + ' ' + $glyph + ' ' +
                    $script:Bright + $script:Colors.white + $name + $script:Reset + ' -> ' +
                    $script:Dim + $target + $script:Reset + $durationText + $completeText
            }
        }
    } catch {
        return $null
    }
    return $null
}

function Get-AgentSegment {
    param([AllowNull()][object]$State)

    try {
        if ($State -isnot [System.Collections.IDictionary]) { return $null }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $activeAgents = @(Get-ActiveActivityEntries -State $State -Kind agent -Now $now)
        if ($activeAgents.Count -gt 0) {
            $label = Get-AgentLabel -Agent $activeAgents[0]
            $elapsedText = ''
            $reliableStarts = @($activeAgents | Where-Object {
                $_['timingReliable'] -ne $false -and $null -ne $_['startedAtMs']
            } | ForEach-Object {
                ConvertTo-NullableNumber -Value $_['startedAtMs']
            } | Where-Object { $null -ne $_ })
            if ($reliableStarts.Count -gt 0) {
                $elapsedText = ' ' + (Format-Duration ([math]::Max(0, $now - [double](($reliableStarts | Measure-Object -Minimum).Minimum))))
                $elapsedText = $script:Dim + $elapsedText + $script:Reset
            }
            $agentLabel = $script:Dim + 'agent' + $script:Reset
            $agentName = if ($label) {
                ' ' + $script:Bright + $script:Colors.white + $label + $script:Reset
            } else {
                ''
            }
            $repeatText = if ($activeAgents.Count -gt 1) {
                $script:Bright + $script:Colors.cyan + " x$($activeAgents.Count)" + $script:Reset
            } else {
                ''
            }
            $runningText = $script:Dim + ' running' + $script:Reset
            $glyph = $script:Bright + $script:Colors.cyan + '◐' + $script:Reset
            return $glyph + ' ' + $agentLabel + $agentName + $repeatText + $elapsedText + $runningText
        }

        $lastAgent = $State['lastSubagent']
        if ($lastAgent -is [System.Collections.IDictionary]) {
            $completedAt = ConvertTo-NullableNumber -Value $lastAgent['completedAtMs']
            $status = [string]$lastAgent['status']
            $matchKey = Get-FirstValue -InputObject $lastAgent -Paths @('matchKey')
            if ($status -cin @('complete', 'failed', 'unknown') -and
                $matchKey -is [string] -and -not [string]::IsNullOrWhiteSpace($matchKey) -and
                $null -ne $completedAt -and $now -ge $completedAt -and $now - $completedAt -le 60000) {
                $label = Get-AgentLabel -Agent $lastAgent
                $durationText = ''
                $duration = ConvertTo-NullableNumber -Value $lastAgent['durationMs']
                if ($null -ne $duration) { $durationText = ' ' + (Format-Duration $duration) }
                if ($durationText) { $durationText = $script:Dim + $durationText + $script:Reset }
                $agentLabel = $script:Dim + 'agent' + $script:Reset
                $agentName = if ($label) {
                    ' ' + $script:Bright + $script:Colors.white + $label + $script:Reset
                } else {
                    ''
                }
                if ($status -eq 'failed') {
                    $glyph = $script:Bright + $script:Colors.red + '✗' + $script:Reset
                } elseif ($status -eq 'complete') {
                    $glyph = $script:Dim + '•' + $script:Reset
                } else {
                    $glyph = $script:Dim + [string][char]0x2022 + $script:Reset
                }
                $outcomeText = if ($status -eq 'complete') {
                    $script:Dim + ' ended' + $script:Reset
                } elseif ($status -eq 'failed') {
                    $script:Dim + ' failed' + $script:Reset
                } else {
                    $script:Dim + ' ended' + $script:Reset
                }
                return $glyph + ' ' + $agentLabel + $agentName + $durationText + $outcomeText
            }
        }
    } catch {
        return $null
    }
    return $null
}

function Get-CompactActivityCategory {
    param([AllowNull()][object]$Activity)

    $category = Get-FirstValue -InputObject $Activity -Paths @('category')
    $label = ConvertTo-SafeText -Value $category -MaximumLength 16
    if ($label -and $label -match '^(?i:shell|edit|read|search|web|agent|prompt|tool)$') {
        if ($label -ieq 'shell') {
            $toolName = Get-FirstValue -InputObject $Activity -Paths @('toolName')
            if ([string]$toolName -match '^(?i:bash|powershell)$') {
                return ([string]$toolName).ToLowerInvariant()
            }
        }
        if ($label -ieq 'agent') {
            $toolName = Get-FirstValue -InputObject $Activity -Paths @('toolName')
            if ([string]$toolName -match '^(?i:task)$') { return 'task' }
        }
        return $label.ToLowerInvariant()
    }
    return (ConvertTo-ActivityToolName -Tool $Activity)
}

function Get-CompactActivitySegment {
    param(
        [object]$Payload,
        [AllowNull()][object]$State,
        [int]$Width = 120,
        [int]$TerminalWidth = 120,
        [string]$SpinnerGlyph = '◐',
        [int]$MaximumItems = 4,
        [ValidateSet('all', 'active', 'history')][string]$Mode = 'all',
        [switch]$SuppressAgentHistory
    )

    try {
        if ($State -isnot [System.Collections.IDictionary]) { return $null }
        $MaximumItems = [math]::Max(0, [math]::Min(4, $MaximumItems))
        if ($Mode -ceq 'history') {
            $MaximumItems = [math]::Min(1, $MaximumItems)
        }
        if ($MaximumItems -eq 0) { return $null }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $activeToolItems = @()
        if ($Mode -cne 'history') {
            $activeToolItems = @(Get-ActiveActivityEntries -State $State -Kind tool -Now $now)
        }
        $activeGroups = [System.Collections.Generic.List[object]]::new()
        foreach ($tool in $activeToolItems) {
            $label = Get-CompactActivityCategory -Activity $tool
            $group = $null
            foreach ($candidate in $activeGroups) {
                if ($candidate.label -ceq $label) {
                    $group = $candidate
                    break
                }
            }
            if ($null -eq $group) {
                [void]$activeGroups.Add([pscustomobject]@{
                    label = $label
                    count = 1
                    startedAtMs = $tool['startedAtMs']
                    timingReliable = ($tool['timingReliable'] -ne $false)
                    target = $tool
                })
            } else {
                $group.count++
                if ($tool['timingReliable'] -eq $false) {
                    $group.timingReliable = $false
                }
                $startedAt = ConvertTo-NullableNumber -Value $tool['startedAtMs']
                $groupStartedAt = ConvertTo-NullableNumber -Value $group.startedAtMs
                if ($null -ne $startedAt -and
                    ($null -eq $groupStartedAt -or $startedAt -lt $groupStartedAt)) {
                    $group.startedAtMs = $startedAt
                }
            }
        }

        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($group in @($activeGroups | Select-Object -First $MaximumItems)) {
            $labelText = $script:Bright + $script:Colors.white + $group.label + $script:Reset
            $repeatText = if ($group.count -gt 1) { " x$($group.count)" } else { '' }
            $targetText = ''
            if ($TerminalWidth -ge 120 -and $group.count -eq 1) {
                $targetValue = Get-FirstValue -InputObject $group.target -Paths @('target')
                $target = ConvertTo-ActivityTarget -Value $targetValue
                if ($target -and $target -notin @('workspace', 'target')) {
                    $targetText = ' ' + $script:Dim + $target + $script:Reset
                }
            }
            $elapsedText = ''
            $startedAt = ConvertTo-NullableNumber -Value $group.startedAtMs
            if ($group.timingReliable -and $null -ne $startedAt) {
                $elapsedText = ' ' + $script:Dim +
                    (Format-Duration ([math]::Max(0, $now - $startedAt))) + $script:Reset
            }
            [void]$items.Add([pscustomobject]@{
                kind = 'activeTool'
                text = $SpinnerGlyph + ' ' + $labelText + $targetText + $repeatText + $elapsedText
                compactText = $SpinnerGlyph + ' ' + $labelText + $repeatText + $elapsedText
                minimalText = $SpinnerGlyph + ' ' + $labelText + $repeatText
            })
        }

        $recentGroups = [System.Collections.Generic.List[object]]::new()
        $recentTools = @()
        if ($Mode -cne 'active') {
            $recentTools = @($State['recentTools'] | Where-Object {
                $_ -is [System.Collections.IDictionary] -or $_ -is [pscustomobject]
            })
            if ($SuppressAgentHistory) {
                $recentTools = @($recentTools | Where-Object {
                    (Get-FirstValue -InputObject $_ -Paths @('category')) -cne 'agent'
                })
            }
        }
        if ($Mode -cne 'active' -and $recentTools.Count -eq 0 -and
            ($State['lastTool'] -is [System.Collections.IDictionary] -or
                $State['lastTool'] -is [pscustomobject])) {
            $lastTool = $State['lastTool']
            $lastToolCategory = Get-FirstValue -InputObject $lastTool -Paths @('category')
            $completedAt = ConvertTo-NullableNumber -Value $lastTool['completedAtMs']
            if ((-not $SuppressAgentHistory -or $lastToolCategory -cne 'agent') -and
                $null -ne $completedAt -and $now -ge $completedAt -and
                $now - $completedAt -le 120000) {
                $recentTools = @($lastTool)
            }
        }

        foreach ($tool in $recentTools) {
            $completedAt = ConvertTo-NullableNumber -Value $tool['completedAtMs']
            if ($null -eq $completedAt -or $now -lt $completedAt -or $now - $completedAt -gt 120000) {
                continue
            }
            $toolStatus = [string]$tool['status']
            $category = Get-FirstValue -InputObject $tool -Paths @('category')
            if ($toolStatus -cnotin @('complete', 'failed') -or
                $category -isnot [string] -or
                $category -cnotin @('shell', 'edit', 'read', 'search', 'web', 'agent', 'prompt', 'tool')) {
                continue
            }
            $label = Get-CompactActivityCategory -Activity $tool
            $status = $toolStatus
            $key = $status + '|tool|' + $label
            $group = $null
            foreach ($candidate in $recentGroups) {
                if ($candidate.key -ceq $key) {
                    $group = $candidate
                    break
                }
            }
            if ($null -eq $group) {
                [void]$recentGroups.Add([pscustomobject]@{
                    key = $key
                    label = $label
                    status = $status
                    count = 1
                    completedAtMs = $completedAt
                    durationMs = $null
                })
            } else {
                $group.count++
                if ($completedAt -gt $group.completedAtMs) {
                    $group.completedAtMs = $completedAt
                }
            }
        }

        $lastAgent = if ($Mode -cne 'active' -and -not $SuppressAgentHistory) {
            $State['lastSubagent']
        } else {
            $null
        }
        if ($lastAgent -is [System.Collections.IDictionary] -or $lastAgent -is [pscustomobject]) {
            $completedAt = ConvertTo-NullableNumber -Value $lastAgent['completedAtMs']
            $agentStatus = [string]$lastAgent['status']
            $agentMatchKey = Get-FirstValue -InputObject $lastAgent -Paths @('matchKey')
            if ($agentStatus -cin @('complete', 'failed', 'unknown') -and
                $agentMatchKey -is [string] -and -not [string]::IsNullOrWhiteSpace($agentMatchKey) -and
                $null -ne $completedAt -and $now -ge $completedAt -and $now - $completedAt -le 120000) {
                $label = Get-AgentLabel -Agent $lastAgent
                if (-not $label) { $label = 'agent' }
                $status = switch ($agentStatus) {
                    'complete' { 'ended' }
                    'failed' { 'failed' }
                    default { 'unknown' }
                }
                [void]$recentGroups.Add([pscustomobject]@{
                    key = 'agent|' + $label + '|' + $completedAt
                    label = $label
                    status = $status
                    count = 1
                    completedAtMs = $completedAt
                    durationMs = (ConvertTo-NullableNumber -Value $lastAgent['durationMs'])
                })
            }
        }

        $selectedOutcomes = @(
            $recentGroups |
                Sort-Object -Property @(
                    @{ Expression = { $_.status -ceq 'failed' }; Descending = $true }
                    @{ Expression = { $_.completedAtMs }; Descending = $true }
                ) |
                Select-Object -First 1
        )
        foreach ($group in $selectedOutcomes) {
            if ($items.Count -ge $MaximumItems) { break }
            $glyph = switch ($group.status) {
                'failed' { $script:Bright + $script:Colors.red + '✗' + $script:Reset }
                'ended' { $script:Dim + '•' + $script:Reset }
                default { $script:Dim + [string][char]0x2022 + $script:Reset }
            }
            $outcomeText = switch ($group.status) {
                'ended' { $script:Dim + ' ended' + $script:Reset }
                'failed' { $script:Dim + ' failed' + $script:Reset }
                default { $script:Dim + ' ended' + $script:Reset }
            }
            $repeatText = if ($group.count -gt 1) { " x$($group.count)" } else { '' }
            $durationText = if ($null -ne $group.durationMs) {
                ' ' + $script:Dim + (Format-Duration $group.durationMs) + $script:Reset
            } else {
                ''
            }
            [void]$items.Add([pscustomobject]@{
                kind = 'history'
                text = $glyph + ' ' + $script:Bright + $script:Colors.white +
                    $group.label + $script:Reset + $outcomeText + $repeatText + $durationText
            })
        }

        if ($items.Count -eq 0) { return $null }
        while ($items.Count -gt 0) {
            $text = [string]::Join('  ', [string[]]@($items | ForEach-Object { $_.text }))
            if ((Get-VisibleTextLength $text) -le $Width) { return $text }
            $removeIndex = -1
            for ($index = $items.Count - 1; $index -ge 0; $index--) {
                if ($items[$index].kind -eq 'history') {
                    $removeIndex = $index
                    break
                }
            }
            if ($removeIndex -ge 0) {
                $items.RemoveAt($removeIndex)
                continue
            }

            $compactIndex = -1
            for ($index = $items.Count - 1; $index -ge 0; $index--) {
                if ($items[$index].kind -eq 'activeTool' -and
                    $items[$index].text -cne $items[$index].compactText) {
                    $compactIndex = $index
                    break
                }
            }
            if ($compactIndex -ge 0) {
                $items[$compactIndex].text = $items[$compactIndex].compactText
                continue
            }

            $minimalIndex = -1
            for ($index = $items.Count - 1; $index -ge 0; $index--) {
                if ($items[$index].kind -eq 'activeTool' -and
                    $items[$index].text -cne $items[$index].minimalText) {
                    $minimalIndex = $index
                    break
                }
            }
            if ($minimalIndex -ge 0) {
                $items[$minimalIndex].text = $items[$minimalIndex].minimalText
                continue
            }

            if ($items.Count -gt 1) {
                $items.RemoveAt($items.Count - 1)
                continue
            }
            return $null
        }
    } catch {
        return $null
    }
    return $null
}

function Get-CompactAgentSegment {
    param([AllowNull()][object]$State, [string]$SpinnerGlyph = '◐')

    try {
        if ($State -isnot [System.Collections.IDictionary]) { return $null }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $activeAgents = @(Get-ActiveActivityEntries -State $State -Kind agent -Now $now)
        if ($activeAgents.Count -gt 0) {
            $label = Get-AgentLabel -Agent $activeAgents[0]
            if (-not $label) { $label = 'agent' }
            $starts = @($activeAgents | Where-Object {
                $_['timingReliable'] -ne $false -and $null -ne $_['startedAtMs']
            } | ForEach-Object {
                ConvertTo-NullableNumber -Value $_['startedAtMs']
            } | Where-Object { $null -ne $_ })
            $elapsedText = ''
            if ($starts.Count -gt 0) {
                $startedAt = [double](($starts | Measure-Object -Minimum).Minimum)
                $elapsedText = ' ' + $script:Dim +
                    (Format-Duration ([math]::Max(0, $now - $startedAt))) + $script:Reset
            }
            $repeatText = if ($activeAgents.Count -gt 1) { " x$($activeAgents.Count)" } else { '' }
            $glyph = if ($SpinnerGlyph.Length -eq 1) { $SpinnerGlyph } else { '◐' }
            return $glyph + ' ' + $script:Bright + $script:Colors.white +
                $label + $script:Reset + $repeatText + $elapsedText
        }
    } catch {
        return $null
    }
    return $null
}

function Invoke-StatusSegment {
    param([scriptblock]$Builder)
    try {
        $value = & $Builder
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    } catch {
        return $null
    }
    return $null
}

function Get-StatusLineText {
    param(
        [System.Collections.Generic.List[object]]$Segments,
        [string]$LineName
    )

    $builder = [System.Text.StringBuilder]::new()
    $hasSegment = $false
    $previousGroup = $null
    foreach ($segment in $Segments) {
        if ($segment.Line -ceq $LineName) {
            if ($hasSegment) {
                $separatorOverride = $segment.PSObject.Properties['SeparatorBefore']
                $separator = if ($null -ne $separatorOverride) {
                    [string]$separatorOverride.Value
                } elseif ([string]$segment.Group -ceq $previousGroup) {
                    $script:SegmentSeparator
                } elseif ($script:CompactGroupSeparatorLines.ContainsKey($LineName)) {
                    $script:CompactGroupSeparator
                } else {
                    $script:GroupSeparator
                }
                [void]$builder.Append($separator)
            }
            [void]$builder.Append([string]$segment.Value)
            $hasSegment = $true
            $previousGroup = [string]$segment.Group
        }
    }
    return $builder.ToString()
}

function Get-VisibleTextLength {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return 0 }
    $plain = [regex]::Replace($Text, '\x1B\[[0-?]*[ -/]*[@-~]', '')
    return $plain.Length
}

function Get-TerminalWidth {
    param([AllowNull()][object]$Payload)

    $payloadWidth = Get-FirstNumber -InputObject $Payload -Paths @(
        'terminal_width', 'terminalWidth', 'terminal.columns', 'terminal.width',
        'terminal_size.width', 'terminalSize.width'
    )
    if ($null -ne $payloadWidth -and $payloadWidth -ge 1 -and $payloadWidth -le 1000) {
        return [int]$payloadWidth
    }

    foreach ($candidate in @($env:COPILOT_STATUSLINE_WIDTH, $env:COLUMNS)) {
        $number = 0
        if ([int]::TryParse(
            [string]$candidate,
            [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$number
        ) -and $number -ge 1 -and $number -le 1000) {
            return $number
        }
    }

    try {
        $width = [Console]::WindowWidth
        if ($width -ge 1 -and $width -le 1000) { return $width }
    } catch {}
    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        if ($width -ge 1 -and $width -le 1000) { return $width }
    } catch {}
    return 120
}

function Remove-OverflowSegments {
    param(
        [System.Collections.Generic.List[object]]$Segments,
        [int]$Width
    )

    $lineNames = @('location', 'usage', 'activity')
    $preCompactDropOrderByLine = @{
        usage = @('lines', 'tokens')
        activity = @('history')
    }
    $postCompactDropOrderByLine = @{
        location = @('ctx-absolute', 'quota-detail', 'quota-pace', 'quota-days')
        usage = @('recent-aic')
        activity = @('history', 'agents', 'activity', 'phase')
    }
    $script:CompactGroupSeparatorLines = @{}
    while ($true) {
        $overflowLines = [System.Collections.Generic.List[string]]::new()
        foreach ($lineName in $lineNames) {
            $lineText = Get-StatusLineText -Segments $Segments -LineName $lineName
            if ((Get-VisibleTextLength $lineText) -gt $Width) {
                [void]$overflowLines.Add($lineName)
            }
        }
        if ($overflowLines.Count -eq 0) { break }

        $removed = $false
        for ($index = $Segments.Count - 1; $index -ge 0; $index--) {
            $segment = $Segments[$index]
            if ($segment.Key -ceq 'branch' -and
                $overflowLines.Contains([string]$segment.Line)) {
                $Segments.RemoveAt($index)
                $removed = $true
                break
            }
        }
        if ($removed) { continue }

        foreach ($lineName in $overflowLines) {
            foreach ($key in $preCompactDropOrderByLine[$lineName]) {
                for ($index = 0; $index -lt $Segments.Count; $index++) {
                    $segment = $Segments[$index]
                    if ($segment.Key -ceq $key -and
                        $segment.Line -ceq $lineName) {
                        $Segments.RemoveAt($index)
                        $removed = $true
                        break
                    }
                }
                if ($removed) { break }
            }
            if ($removed) { break }
        }
        if ($removed) { continue }

        $compacted = $false
        foreach ($lineName in $overflowLines) {
            if (-not $script:CompactGroupSeparatorLines.ContainsKey($lineName)) {
                $script:CompactGroupSeparatorLines[$lineName] = $true
                $compacted = $true
            }
        }
        if ($compacted) { continue }

        foreach ($lineName in $overflowLines) {
            foreach ($key in $postCompactDropOrderByLine[$lineName]) {
                for ($index = 0; $index -lt $Segments.Count; $index++) {
                    $segment = $Segments[$index]
                    if ($segment.Key -ceq $key -and
                        $segment.Line -ceq $lineName) {
                        $Segments.RemoveAt($index)
                        $removed = $true
                        break
                    }
                }
                if ($removed) { break }
            }
            if ($removed) { break }
        }
        if (-not $removed) { break }
    }
}

$payload = @{}
try {
    $rawInput = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($rawInput)) {
        $parsed = ConvertFrom-Json -InputObject $rawInput -AsHashtable -ErrorAction Stop
        if ($parsed -is [System.Collections.IDictionary]) { $payload = $parsed }
    }
} catch {
    $payload = @{}
}
if ([Environment]::GetEnvironmentVariable('COPILOT_RAW_PAYLOAD_CAPTURE') -ceq '1') {
    try { Save-FirstStatuslinePayload -Raw $rawInput -Payload $payload } catch {}
}

$sessionState = $null
try { $sessionState = Get-SessionState -Payload $payload } catch { $sessionState = $null }
$signalState = $null
try { $signalState = Get-HudSignalState -Payload $payload } catch { $signalState = $null }

$terminalWidth = Get-TerminalWidth -Payload $payload
$script:ContextGaugeWidth = if ($terminalWidth -lt 60) { 5 } else { 8 }
$contextData = $null
try {
    $contextData = Get-ContextSegmentData -Payload $payload -GaugeWidth $script:ContextGaugeWidth
} catch {
    $contextData = $null
}
$spinnerGlyph = '◐'
if ($sessionState -is [System.Collections.IDictionary]) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $activeToolCount = @(Get-ActiveActivityEntries -State $sessionState -Kind tool -Now $now).Count
    $activeAgentCount = @(Get-ActiveActivityEntries -State $sessionState -Kind agent -Now $now).Count
    if ($activeToolCount -gt 0 -or $activeAgentCount -gt 0) {
        $spinnerGlyph = Get-SpinnerGlyph -Payload $payload -State $sessionState
    }
}

$bridgeSubagentSegment = Invoke-StatusSegment {
    Get-HudSubagentSegment -SignalState $signalState
}
$bridgeSubagentCountKnown = $false
if ($signalState -is [System.Collections.IDictionary]) {
    $bridgeSubagentCountKnown = $null -ne $signalState['activeSubagentCount']
}
$activeAgentSegment = if ($bridgeSubagentCountKnown) {
    $bridgeSubagentSegment
} else {
    Invoke-StatusSegment {
        Get-CompactAgentSegment $sessionState $spinnerGlyph
    }
}
$activeAgentSlots = if ($null -ne $activeAgentSegment) { 1 } else { 0 }
$activeToolGroups = @()
try {
    if ($sessionState -is [System.Collections.IDictionary]) {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $activeToolGroups = @(
            Get-ActiveActivityEntries -State $sessionState -Kind tool -Now $now |
                ForEach-Object { Get-CompactActivityCategory -Activity $_ } |
                Sort-Object -Unique
        )
    }
} catch {
    $activeToolGroups = @()
}
$activityItemLimit = [math]::Max(0, [math]::Min(4, $activeToolGroups.Count))
$agentTextWidth = Get-VisibleTextLength ([string]$activeAgentSegment)
$activitySegment = Invoke-StatusSegment {
    Get-CompactActivitySegment -Payload $payload -State $sessionState `
        -Width $terminalWidth -TerminalWidth $terminalWidth `
        -SpinnerGlyph $spinnerGlyph -MaximumItems $activityItemLimit -Mode active
}
$activitySlots = if ($null -ne $activitySegment) {
    [math]::Min($activityItemLimit, $activeToolGroups.Count)
} else {
    0
}
$historyItemLimit = [math]::Max(0, 4 - $activeAgentSlots - $activitySlots)
$activeLineWidth = $agentTextWidth
if ($null -ne $activitySegment) {
    if ($activeAgentSlots -gt 0) {
        $activeLineWidth += Get-VisibleTextLength $script:SegmentSeparator
    }
    $activeLineWidth += Get-VisibleTextLength $activitySegment
}
$historySeparatorWidth = if ($activeLineWidth -gt 0) {
    Get-VisibleTextLength $script:GroupSeparator
} else {
    0
}
$historyWidth = [math]::Max(
    0,
    $terminalWidth - $activeLineWidth - $historySeparatorWidth
)
$historySegment = Invoke-StatusSegment {
    Get-CompactActivitySegment -Payload $payload -State $sessionState `
        -Width $historyWidth -TerminalWidth $terminalWidth `
        -SpinnerGlyph $spinnerGlyph -MaximumItems $historyItemLimit -Mode history `
    -SuppressAgentHistory:$bridgeSubagentCountKnown
}

$phaseSegment = $null
if ($activeAgentSlots -eq 0 -and $activeToolGroups.Count -eq 0) {
    $phaseCandidate = Invoke-StatusSegment {
        Get-HudPhaseSegment -SignalState $signalState
    }
    if ($null -ne $phaseCandidate) {
        $phaseName = [string]$signalState['phase']
        if ($phaseName -in @('working', 'running_tool') -or
            $null -eq $historySegment) {
            $phaseSegment = $phaseCandidate
            if ($phaseName -in @('working', 'running_tool')) {
                $historySegment = $null
            }
        }
    }
}

$quotaData = try { Get-QuotaData } catch { $null }
$quotaSegment = Invoke-StatusSegment { Get-QuotaSegment $quotaData }
$segments = [System.Collections.Generic.List[object]]::new()

foreach ($segment in @(
    [pscustomobject]@{
        Key = 'branch'; Group = 'branch'; Line = 'location'
        Value = (Invoke-StatusSegment { Get-BranchSegment $payload })
    },
    [pscustomobject]@{
        Key = 'ctx'; Group = 'context'; Line = 'location'
        Value = (Invoke-StatusSegment {
            Get-ContextGaugeSegment -ContextData $contextData
        })
    },
    [pscustomobject]@{
        Key = 'ctx-absolute'; Group = 'context'; Line = 'location'
        SeparatorBefore = ' '
        Value = (Invoke-StatusSegment {
            Get-ContextAbsoluteSegment -ContextData $contextData
        })
    },
    [pscustomobject]@{
        Key = 'ctx-percentage'; Group = 'context'; Line = 'location'
        SeparatorBefore = ' '
        Value = (Invoke-StatusSegment {
            Get-ContextPercentageSegment -ContextData $contextData
        })
    },
    [pscustomobject]@{
        Key = 'quota'; Group = 'quota'; Line = 'location'
        Value = $quotaSegment
    },
    [pscustomobject]@{
        Key = 'quota-detail'; Group = 'quota'; Line = 'location'
        SeparatorBefore = $script:Dim + ' · ' + $script:Reset
        Value = (Invoke-StatusSegment { Get-QuotaDetailSegment $quotaData })
    },
    [pscustomobject]@{
        Key = 'quota-pace'; Group = 'quota'; Line = 'location'
        SeparatorBefore = $script:Dim + ' · ' + $script:Reset
        Value = (Invoke-StatusSegment { Get-QuotaPaceSegment $quotaData })
    },
    [pscustomobject]@{
        Key = 'quota-days'; Group = 'quota'; Line = 'location'
        SeparatorBefore = $script:Dim + ' · ' + $script:Reset
        Value = (Invoke-StatusSegment { Get-QuotaDaysSegment $quotaData })
    },
    [pscustomobject]@{
        Key = 'runtime'; Group = 'runtime'; Line = 'location'
        Value = (Invoke-StatusSegment { Get-RuntimeSegment $sessionState })
    },
    [pscustomobject]@{
        Key = 'aic'; Group = 'aic-rate'; Line = 'usage'
        Value = (Invoke-StatusSegment { Get-AicSegment $payload })
    },
    [pscustomobject]@{
        Key = 'recent-aic'; Group = 'aic-rate'; Line = 'usage'
        Value = (Invoke-StatusSegment { Get-RecentAicSegment $signalState })
    },
    [pscustomobject]@{
        Key = 'rate'; Group = 'aic-rate'; Line = 'usage'
        Value = (Invoke-StatusSegment { Get-RateSegment $payload })
    },
    [pscustomobject]@{
        Key = 'tokens'; Group = 'tokens'; Line = 'usage'
        Value = (Invoke-StatusSegment { Get-TokenSegment $payload })
    },
    [pscustomobject]@{
        Key = 'lines'; Group = 'lines'; Line = 'usage'
        Value = (Invoke-StatusSegment { Get-LinesSegment $payload })
    },
    [pscustomobject]@{
        Key = 'agents'; Group = 'active'; Line = 'activity'
        Value = $activeAgentSegment
    },
    [pscustomobject]@{
        Key = 'activity'; Group = 'active'; Line = 'activity'
        Value = $activitySegment
    },
    [pscustomobject]@{
        Key = 'phase'; Group = 'active'; Line = 'activity'
        Value = $phaseSegment
    },
    [pscustomobject]@{
        Key = 'history'; Group = 'history'; Line = 'activity'
        Value = $historySegment
    }
)) {
    if ($null -ne $segment.Value) { [void]$segments.Add($segment) }
}

Remove-OverflowSegments -Segments $segments -Width $terminalWidth
foreach ($lineName in @('location', 'usage', 'activity')) {
    $line = Get-StatusLineText -Segments $segments -LineName $lineName
    if (-not [string]::IsNullOrWhiteSpace($line)) { [Console]::Out.WriteLine($line) }
}
