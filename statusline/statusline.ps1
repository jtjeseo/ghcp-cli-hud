# Temporary schema diagnostics only: set COPILOT_RAW_PAYLOAD_CAPTURE=1 for one run.
# Unset it afterward; captures are retained until manually removed.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$script:IsWindowsPlatform = [IO.Path]::DirectorySeparatorChar -eq '\'

function Get-HudHome {
    if (-not [string]::IsNullOrWhiteSpace($env:COPILOT_HOME)) { return $env:COPILOT_HOME }
    $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if (-not [string]::IsNullOrWhiteSpace($profile)) { return (Join-Path $profile '.copilot') }
    return $null
}

function Test-HudLocalPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($script:IsWindowsPlatform) { return $Path -match '^[A-Za-z]:[\\/]' }
    return $Path.StartsWith('/', [StringComparison]::Ordinal) -and
        -not $Path.StartsWith('//', [StringComparison]::Ordinal)
}

function Test-HudBridgeEnabled {
    param([string]$CopilotHome)
    $value = [Environment]::GetEnvironmentVariable('COPILOT_HUD_SIGNAL_BRIDGE')
    if (-not [string]::IsNullOrEmpty($value)) { return $value -ceq '1' }
    $path = Join-Path $CopilotHome 'hud-signal-bridge.json'
    if (-not [IO.File]::Exists($path)) { return $false }
    try {
        $options = Read-QuotaEstimateRecord -Path $path -MaxBytes 256
        if ($options -isnot [Collections.IDictionary] -or $options.Count -ne 2 -or
            -not $options.Contains('version') -or -not $options.Contains('enabled') -or
            -not (Test-HudSignalInteger $options.version) -or $options.version -ne 1 -or
            $options.enabled -isnot [bool]) { throw 'Invalid bridge options' }
        return $options.enabled
    } catch {
        try {
            [IO.File]::WriteAllText((Join-Path $CopilotHome 'hud-bridge-warning.log'), 'invalid-options')
        } catch {}
        return $false
    }
}

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

    $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile).Replace('/', '\').TrimEnd('\')
    $separator = if ($script:IsWindowsPlatform) { '\' } else { '/' }
    if (-not [string]::IsNullOrWhiteSpace($profile)) {
        if ($normalized.Equals($profile, [StringComparison]::OrdinalIgnoreCase)) { return '~' }
        if ($normalized.StartsWith($profile + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $normalized.Substring($profile.Length).TrimStart('\')
            $relativeParts = @($relative -split '\\' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($relativeParts.Count -gt 2) { $relativeParts = @($relativeParts | Select-Object -Last 2) }
            $safeRelative = ConvertTo-SafeText -Value ([string]::Join($separator, [string[]]$relativeParts)) -MaximumLength 48
            if ($safeRelative) { return '~' + $separator + $safeRelative }
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
    $safeLabel = ConvertTo-SafeText -Value ([string]::Join($separator, [string[]]$parts)) -MaximumLength 48
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
        if (-not (Test-HudLocalPath $gitDirectory)) { return $null }
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

function Get-LocalGitContext {
    param([AllowNull()][string]$Path)

    if (-not (Test-HudLocalPath $Path)) {
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
                    return [pscustomobject]@{
                        Branch = 'detached'; GitDirectory = $gitDirectory; IsDetached = $true
                    }
                } else {
                    return $null
                }

                $branch = ConvertTo-SafeText -Value $branch -MaximumLength 1024
                if (-not $branch -or
                    $branch -match '(?i)(https?://|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|(token|secret|password|api[_ -]?key|authorization|bearer)\s*[:=])' -or
                    $branch -match '^[A-Fa-f0-9-]{32,}$') {
                    return $null
                }
                return [pscustomobject]@{
                    Branch = $branch; GitDirectory = $gitDirectory; IsDetached = $false
                }
            }
            $directory = $directory.Parent
        }
    } catch {
        return $null
    }
    return $null
}

function Get-LocalGitBranch {
    param([AllowNull()][string]$Path)
    $context = Get-LocalGitContext -Path $Path
    if ($null -ne $context) { return $context.Branch }
    return $null
}

function Get-GitSyncHash {
    param([string]$Value)
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($hash.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($Value)
        )).Replace('-', '').ToLowerInvariant()
    } finally { $hash.Dispose() }
}

function Get-GitDirectoryKey {
    param([string]$Path)
    $normalized = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($script:IsWindowsPlatform) {
        $normalized = [regex]::Replace($normalized, '[A-Z]', [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $match.Value.ToLowerInvariant()
        })
    }
    return (Get-GitSyncHash $normalized)
}

function Write-GitSyncWarning {
    param([string]$CopilotHome)
    try {
        [IO.File]::WriteAllText(
            (Join-Path (Join-Path $CopilotHome 'state') 'hud-git-sync-warning.log'),
            'state-unavailable'
        )
    } catch {}
}

function Get-GitSyncSegment {
    param([AllowNull()][object]$GitContext)
    if ($null -eq $GitContext -or $GitContext.IsDetached) { return $null }
    $copilotHome = Get-HudHome
    if (-not $copilotHome) { return $null }
    $optionsPath = Join-Path $copilotHome 'hud-git-sync.json'
    if (-not [IO.File]::Exists($optionsPath)) { return $null }
    try {
        $options = Read-QuotaEstimateRecord -Path $optionsPath -MaxBytes 256
        if ($options -isnot [Collections.IDictionary] -or $options.Count -ne 2 -or
            -not $options.Contains('version') -or -not $options.Contains('enabled') -or
            -not (Test-HudSignalInteger $options.version) -or $options.version -ne 1 -or
            $options.enabled -isnot [bool]) { throw 'Invalid Git sync options' }
        if (-not $options.enabled) { return $null }
        $key = Get-GitDirectoryKey $GitContext.GitDirectory
        $path = Join-Path (Join-Path (Join-Path $copilotHome 'state') 'hud-git-sync') "hud-git-$key.json"
        if (-not [IO.File]::Exists($path)) {
            $age = ([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($optionsPath)).TotalSeconds
            $label = if ($age -gt 60) { 'sync unavailable' } else { 'sync pending' }
            return $script:Dim + $label + $script:Reset
        }
        $data = Read-QuotaEstimateRecord -Path $path -MaxBytes 4096
        $keys = @('version', 'repositoryKey', 'branchKey', 'updatedAt', 'status',
            'ahead', 'behind', 'fetchedAt', 'fetchStatus')
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        if ($data -isnot [Collections.IDictionary] -or $data.Count -ne $keys.Count -or
            @($keys | Where-Object { -not $data.Contains($_) }).Count -gt 0 -or
            -not (Test-HudSignalInteger $data.version) -or $data.version -ne 1 -or
            $data.repositoryKey -isnot [string] -or $data.repositoryKey -cnotmatch '^[a-f0-9]{64}$' -or
            $data.branchKey -isnot [string] -or $data.branchKey -cnotmatch '^[a-f0-9]{64}$' -or
            -not (Test-HudSignalInteger $data.updatedAt) -or $data.updatedAt -gt $now + 5000 -or
            $data.status -cnotin @('ok', 'no-upstream', 'unborn', 'detached', 'unavailable') -or
            $data.fetchStatus -cnotin @('ok', 'local', 'pending', 'unavailable', 'not-needed') -or
            ($null -ne $data.fetchedAt -and
                (-not (Test-HudSignalInteger $data.fetchedAt) -or
                    $data.fetchedAt -gt $data.updatedAt + 5000)) -or
            ($data.status -ceq 'ok' -and
                (-not (Test-HudSignalInteger $data.ahead) -or -not (Test-HudSignalInteger $data.behind))) -or
            ($data.status -cne 'ok' -and ($null -ne $data.ahead -or $null -ne $data.behind))) {
            throw 'Invalid Git sync snapshot'
        }
        if ($data.repositoryKey -cne $key -or
            $data.branchKey -cne (Get-GitSyncHash $GitContext.Branch) -or
            $data.status -ceq 'detached') {
            return $script:Dim + 'sync pending' + $script:Reset
        }
        $parts = [Collections.Generic.List[string]]::new()
        if ($data.status -ceq 'ok') {
            $diverged = $data.ahead -gt 0 -and $data.behind -gt 0
            if ($data.behind -gt 0) {
                $color = if ($diverged) { $script:Bright + $script:Colors.yellow } else { $script:Colors.cyan }
                $parts.Add($color + '↓' + (Format-Count $data.behind) + $script:Reset)
            }
            if ($data.ahead -gt 0) {
                $parts.Add($script:Colors.yellow + '↑' + (Format-Count $data.ahead) + $script:Reset)
            }
            if ($data.fetchStatus -ceq 'unavailable') {
                $parts.Add($script:Dim + '(fetch unavailable)' + $script:Reset)
            } elseif ($data.fetchStatus -ceq 'pending') {
                $parts.Add($script:Dim + '(fetch pending)' + $script:Reset)
            }
        } else {
            $label = switch -CaseSensitive ($data.status) {
                'no-upstream' { 'no upstream' }
                'unborn' { 'no commits' }
                default { 'sync unavailable' }
            }
            $parts.Add($script:Dim + $label + $script:Reset)
        }
        $dataAge = [math]::Max(0.0, $now - [double]$data.updatedAt)
        $fetchAge = if ($null -ne $data.fetchedAt) {
            [math]::Max(0.0, $now - [double]$data.fetchedAt)
        } else { 0.0 }
        $age = if ($dataAge -gt 60000) { [math]::Max($dataAge, $fetchAge) }
            elseif ($fetchAge -gt 600000) { $fetchAge } else { 0.0 }
        if ($age -gt 0) {
            $minutes = [math]::Floor($age / 60000)
            $text = if ($minutes -lt 60) { "${minutes}m" } else { "$([math]::Floor($minutes / 60))h" }
            $parts.Add($script:Dim + "($text ago)" + $script:Reset)
        }
        if ($parts.Count -gt 0) { return [string]::Join(' ', $parts) }
        return $null
    } catch {
        Write-GitSyncWarning -CopilotHome $copilotHome
        return $script:Dim + 'sync unavailable' + $script:Reset
    }
}

function Get-BranchSegment {
    param([object]$Payload, [AllowNull()][object]$GitContext)

    # Resolve only from the statusline payload cwd, never the process working directory.
    $cwd = Get-FirstValue -InputObject $Payload -Paths @('cwd')
    if ($cwd -isnot [string]) { return $null }
    if ($null -eq $GitContext) { $GitContext = Get-LocalGitContext -Path $cwd }
    $branch = if ($null -ne $GitContext) { $GitContext.Branch } else { $null }
    if (-not $branch) { return $null }
    $displayBranch = $branch
    if ($displayBranch.Length -gt $script:BranchDisplayWidth) {
        $displayBranch = $displayBranch.Substring(
            0,
            $script:BranchDisplayWidth - 3
        ) + '...'
    }
    return $script:Dim + '⎇' + $script:Reset + ' ' +
        $script:Colors.yellow + $displayBranch + $script:Reset
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
    param([AllowNull()][object]$Payload)

    $copilotHome = Get-HudHome
    if (-not $copilotHome) { return $null }
    # Prefer our bridge's own capture; fall back to the marketplace copilot-hud file.
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $data = $null
    foreach ($path in @(
        (Join-Path (Join-Path (Join-Path $copilotHome 'state') 'hud-signal-bridge') 'hud-quota.json'),
        (Join-Path $copilotHome 'hud-quota.json')
    )) {
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            if ((Get-Item -LiteralPath $path).Length -gt 65536) { continue }
            $candidate = [IO.File]::ReadAllText($path) | ConvertFrom-Json
            if (-not (Test-HudSignalInteger $candidate.updatedAt) -or
                [double]$candidate.updatedAt -gt $nowMs + 5000 -or
                ($nowMs - [double]$candidate.updatedAt) -gt 604800000) { continue }
            if ($null -eq $data -or [double]$candidate.updatedAt -gt [double]$data.updatedAt) {
                $data = $candidate
            }
        } catch {}
    }
    if ($null -eq $data) { return $null }
    # Quota only refreshes on model calls, so idle sessions keep the last value
    # (tagged with its age) instead of hiding it; stale data never moves the day baseline.
    $ageMs = [math]::Max(0.0, $nowMs - [double]$data.updatedAt)
    $stale = $ageMs -gt 600000
    $quota = @($data.quotas) | Where-Object {
        $_.unlimited -eq $false -and [double]$_.entitlement -gt 0
    } | Sort-Object { [double]$_.entitlement } -Descending | Select-Object -First 1
    if ($null -eq $quota) { return $null }

    $used = if ($quota.used -is [ValueType]) { ConvertTo-NullableNumber $quota.used } else { $null }
    $entitlement = if ($quota.entitlement -is [ValueType]) {
        ConvertTo-NullableNumber $quota.entitlement
    } else { $null }
    if ($null -eq $used -or $null -eq $entitlement) {
        Write-QuotaEstimateWarning -CopilotHome $copilotHome -Reason 'state-unavailable'
        return $null
    }
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
    if ($stale -and $null -eq $days) { return $null }
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
    $todayUsed = $null
    $todayBudget = $null
    $todayEstimated = $false
    $accountEstimate = [pscustomobject]@{ Amount = 0.0; Complete = $false; Accepted = $false }
    try {
        $period = if ($reset -ne [DateTimeOffset]::MinValue) {
            $reset.UtcDateTime.ToString('yyyy-MM-dd')
        } else { '' }
        $accountEstimate = Get-QuotaAccountEstimate -CopilotHome $copilotHome `
            -Payload $Payload -Used $used -Entitlement $entitlement -Period $period `
            -SnapshotAt ([double]$data.updatedAt)
    } catch { Write-QuotaEstimateWarning -CopilotHome $copilotHome -Reason 'state-unavailable' }
    try {
        $baseline = Get-QuotaDayBaseline -CopilotHome $copilotHome -Used $used -Budget $perDay `
            -ReadOnly:($stale -or $accountEstimate.Accepted -eq $false)
        if ($null -ne $baseline) {
            $todayUsed = [math]::Max(0.0, $used - [double]$baseline.startUsed) + $accountEstimate.Amount
            $todayEstimated = $accountEstimate.Amount -gt 0
            if ($null -ne $baseline.budget -and [double]$baseline.budget -gt 0) {
                $todayBudget = [double]$baseline.budget
            }
        }
    } catch { Write-QuotaEstimateWarning -CopilotHome $copilotHome -Reason 'state-unavailable' }
    return [pscustomobject]@{
        Used = $used
        Entitlement = $entitlement
        Percentage = $percentage
        Days = $days
        PaceDelta = $delta
        PerWorkday = $perDay
        TodayUsed = $todayUsed
        TodayBudget = $todayBudget
        TodayEstimated = $todayEstimated
        TodayEstimateComplete = $accountEstimate.Complete
        Stale = $stale
        AgeMs = $ageMs
    }
}

function Write-QuotaEstimateWarning {
    param(
        [string]$CopilotHome,
        [ValidateSet('state-unavailable', 'state-rebased', 'rollup-incomplete', 'capacity', 'cleanup-unavailable')]
        [string]$Reason
    )
    try {
        $path = Join-Path (Join-Path $CopilotHome 'state') 'hud-quota-estimate-warning.log'
        [IO.File]::WriteAllText($path, $Reason)
    } catch {}
}

function Test-LegacyQuotaEstimateRecord {
    param([AllowNull()][object]$Record)

    return $Record -is [Collections.IDictionary] -and $Record.Count -eq 2 -and
        $Record.Contains('plan') -and $Record.Contains('aic') -and
        $Record.plan -is [ValueType] -and $Record.aic -is [ValueType] -and
        $null -ne (ConvertTo-NullableNumber $Record.plan) -and
        $null -ne (ConvertTo-NullableNumber $Record.aic)
}

function Test-QuotaEstimateLedger {
    param([AllowNull()][object]$Record)

    if ($Record -isnot [Collections.IDictionary]) { return $false }
    $keys = @('version', 'date', 'plan', 'period', 'entitlement', 'quotaAt', 'epoch', 'sessions', 'complete')
    if ($Record.Count -ne $keys.Count -or
        @($keys | Where-Object { -not $Record.Contains($_) }).Count -gt 0 -or
        -not (Test-HudSignalInteger $Record.version) -or $Record.version -ne 2 -or
        $Record.date -isnot [string] -or $Record.date -cnotmatch '^\d{4}-\d{2}-\d{2}$' -or
        $Record.period -isnot [string] -or
        $Record.period -cnotmatch '^(?:\d{4}-\d{2}-\d{2})?$' -or
        $Record.complete -isnot [bool] -or
        $Record.epoch -isnot [string] -or $Record.epoch -cnotmatch '^[a-f0-9]{32}$' -or
        -not (Test-HudSignalInteger $Record.quotaAt) -or
        $Record.sessions -isnot [Collections.IDictionary] -or
        $Record.sessions.Count -gt 64) { return $false }
    $parsedDate = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($Record.date, 'yyyy-MM-dd',
        [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None,
        [ref]$parsedDate) -or
        ($Record.period -and -not [DateTime]::TryParseExact($Record.period, 'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None,
            [ref]$parsedDate))) { return $false }
    foreach ($key in @('plan', 'entitlement')) {
        if ($Record[$key] -isnot [ValueType] -or
            $null -eq (ConvertTo-NullableNumber $Record[$key])) { return $false }
    }
    if ($Record.entitlement -le 0) { return $false }
    foreach ($id in $Record.sessions.Keys) {
        $entry = $Record.sessions[$id]
        if ($id -isnot [string] -or $id -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
            $entry -isnot [Collections.IDictionary] -or $entry.Count -ne 2 -or
            -not $entry.Contains('aic') -or -not $entry.Contains('latestAic') -or
            $entry.aic -isnot [ValueType] -or $entry.latestAic -isnot [ValueType] -or
            $null -eq (ConvertTo-NullableNumber $entry.aic) -or
            $null -eq (ConvertTo-NullableNumber $entry.latestAic) -or
            $entry.aic -gt $entry.latestAic -or $entry.latestAic -gt 9007199.254740991) {
            return $false
        }
    }
    return $true
}

function Write-QuotaEstimateRecord {
    param([string]$Path, [object]$Record, [long]$MaxBytes)

    if ([IO.Directory]::Exists($Path)) {
        throw [IO.IOException]::new('Quota estimate destination is not a file')
    }
    $json = $Record | ConvertTo-Json -Depth 5 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $MaxBytes) {
        throw [IO.InvalidDataException]::new('Quota estimate record is oversized')
    }
    $temporary = "$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $json)
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Test-QuotaPendingEstimateRecord {
    param([AllowNull()][object]$Record)

    return $Record -is [Collections.IDictionary] -and $Record.Count -eq 3 -and
        $Record.Contains('version') -and $Record.Contains('epoch') -and $Record.Contains('nano') -and
        (Test-HudSignalInteger $Record.version) -and $Record.version -eq 1 -and
        $Record.epoch -is [string] -and $Record.epoch -cmatch '^[a-f0-9]{32}$' -and
        (Test-HudSignalInteger $Record.nano)
}

function Write-QuotaPendingEstimate {
    param([string]$Path, [string]$Epoch, [double]$Nano, [switch]$Reset)

    $lock = $null
    try {
        $lock = [IO.File]::Open("$Path.lock", [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        if (-not $Reset -and [IO.File]::Exists($Path)) {
            $previous = Read-QuotaEstimateRecord -Path $Path -MaxBytes 1024
            if (-not (Test-QuotaPendingEstimateRecord $previous)) {
                throw [IO.InvalidDataException]::new('Invalid pending quota estimate')
            }
            if ($previous.epoch -ceq $Epoch) {
                $Nano = [math]::Max($Nano, [double]$previous.nano)
            }
        }
        Write-QuotaEstimateRecord -Path $Path -MaxBytes 1024 `
            -Record ([ordered]@{ version = 1; epoch = $Epoch; nano = $Nano })
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

function Merge-QuotaPendingEstimates {
    param([string]$CopilotHome, [Collections.IDictionary]$Ledger)

    $directory = Join-Path $CopilotHome 'state'
    foreach ($id in $Ledger.sessions.Keys) {
        $pendingPath = Join-Path $directory "hud-quota-pending-$($Ledger.date)-$id.json"
        if (-not [IO.File]::Exists($pendingPath)) { continue }
        try {
            $pending = Read-QuotaEstimateRecord -Path $pendingPath -MaxBytes 1024
            if (-not (Test-QuotaPendingEstimateRecord $pending)) {
                throw [IO.InvalidDataException]::new('Invalid pending quota estimate')
            }
            if ($pending.epoch -ceq $Ledger.epoch) {
                $entry = $Ledger.sessions[$id]
                $entry.latestAic = [math]::Max([double]$entry.latestAic, [double]$pending.nano / 1e9)
            }
        } catch {
            $Ledger.complete = $false
            Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'rollup-incomplete'
        }
    }
}

function Remove-ExpiredQuotaPendingEstimates {
    param([string]$CopilotHome, [DateTime]$Today)

    $directory = Join-Path $CopilotHome 'state'
    $cutoff = $Today.AddDays(-2).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    try {
        $expired = @(Get-ChildItem -LiteralPath $directory -Filter 'hud-quota-pending-*.json*' -File `
            -ErrorAction Stop | Where-Object {
                $_.Name -cmatch '^hud-quota-pending-(\d{4}-\d{2}-\d{2})-[A-Za-z0-9_-]{1,128}\.json(?:\.lock|\.\d+\.[a-f0-9]{32}\.tmp)?$' -and
                $Matches[1] -clt $cutoff
            } | Select-Object -First 32)
        foreach ($file in $expired) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop }
    } catch { Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'cleanup-unavailable' }
}

function Read-QuotaEstimateRecord {
    param([string]$Path, [long]$MaxBytes = 65536)

    $stream = $null
    try {
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $length = $stream.Length
        if ($length -le 0 -or $length -gt $MaxBytes) {
            throw [IO.InvalidDataException]::new('Invalid quota estimate size')
        }
        $bytes = [byte[]]::new([int]$length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw [IO.InvalidDataException]::new('Incomplete quota estimate read') }
            $offset += $read
        }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF)
        return ($text | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Test-QuotaEstimateCheckpointAhead {
    param(
        [Collections.IDictionary]$Record, [string]$Date, [double]$Used,
        [string]$Period, [double]$Entitlement, [double]$SnapshotAt
    )

    return $Record.date -cgt $Date -or
        (($Record.plan -ne $Used -or $Record.period -cne $Period -or
            $Record.entitlement -ne $Entitlement) -and $SnapshotAt -lt $Record.quotaAt)
}

# All terminals reconcile the same ledger. A plan movement clears pending estimates
# instead of guessing which sessions were billed; closed sessions remain included.
function Get-QuotaAccountEstimate {
    param(
        [string]$CopilotHome, [AllowNull()][object]$Payload, [double]$Used,
        [double]$Entitlement, [string]$Period, [double]$SnapshotAt,
        [DateTime]$Today = [DateTime]::Today
    )

    $date = $Today.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $directory = Join-Path $CopilotHome 'state'
    $path = Join-Path $directory 'hud-quota-estimates.json'
    $complete = $true
    if ($null -eq (ConvertTo-NullableNumber $Used) -or
        $null -eq (ConvertTo-NullableNumber $Entitlement) -or $Entitlement -le 0 -or
        -not (Test-HudSignalInteger $SnapshotAt)) {
        Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'state-unavailable'
        return [pscustomobject]@{ Amount = 0.0; Complete = $false; Accepted = $false }
    }
    $sessionId = Get-FirstValue -InputObject $Payload -Paths @('session_id')
    $nano = Get-FirstValue -InputObject $Payload -Paths @('ai_used.total_nano_aiu')
    $canObserve = $null -ne $nano -and $sessionId -is [string] -and
        $sessionId -cmatch '^[A-Za-z0-9_-]{1,128}$' -and (Test-HudSignalInteger $nano)
    if ($null -ne $nano -and -not $canObserve) {
        $complete = $false
        Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'state-unavailable'
    }

    if ($canObserve -and [IO.File]::Exists($path)) {
        try {
            $checkpoint = Read-QuotaEstimateRecord -Path $path
            if ((Test-QuotaEstimateLedger $checkpoint) -and $checkpoint.date -ceq $date -and
                $checkpoint.plan -eq $Used -and $checkpoint.period -ceq $Period -and
                $checkpoint.entitlement -eq $Entitlement -and $checkpoint.sessions.Contains($sessionId)) {
                $pendingPath = Join-Path $directory "hud-quota-pending-$date-$sessionId.json"
                Write-QuotaPendingEstimate -Path $pendingPath -Epoch $checkpoint.epoch -Nano $nano
            }
        } catch {
            $complete = $false
            Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'state-unavailable'
        }
    }
    $lock = $null
    $record = $null
    try {
        [void][IO.Directory]::CreateDirectory($directory)
        # No retry or wait on the render path; an exclusive handle dies with its process.
        $lock = [IO.File]::Open("$path.lock", [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        if ([IO.Directory]::Exists($path)) {
            throw [IO.IOException]::new('Quota estimate destination is not a file')
        }
        $initial = -not [IO.File]::Exists($path)
        if (-not $initial) {
            try {
                $record = Read-QuotaEstimateRecord -Path $path
                if (-not (Test-QuotaEstimateLedger $record)) {
                    throw [IO.InvalidDataException]::new('Invalid quota estimate ledger')
                }
            } catch {
                $record = $null
                $complete = $false
                Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'state-rebased'
            }
        }
        if ($null -ne $record -and (Test-QuotaEstimateCheckpointAhead -Record $record `
            -Date $date -Used $Used -Period $Period -Entitlement $Entitlement -SnapshotAt $SnapshotAt)) {
            Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'rollup-incomplete'
            return [pscustomobject]@{ Amount = 0.0; Complete = $false; Accepted = $false }
        }
        if ($null -eq $record -or $record.date -cne $date -or $record.plan -ne $Used -or
            $record.period -cne $Period -or $record.entitlement -ne $Entitlement) {
            $record = [ordered]@{
                version = 2; date = $date; plan = $Used; period = $Period
                entitlement = $Entitlement; quotaAt = $SnapshotAt
                epoch = [guid]::NewGuid().ToString('N')
                sessions = @{}; complete = $complete
            }
        }
        $record.quotaAt = [math]::Max([double]$record.quotaAt, $SnapshotAt)
        if ($canObserve) {
            $aic = [double]$nano / 1000000000.0
            if ($record.sessions.Contains($sessionId)) {
                $entry = $record.sessions[$sessionId]
                # Ignore regressed samples rather than counting the same growth twice.
                $entry.latestAic = [math]::Max([double]$entry.latestAic, $aic)
            } elseif ($record.sessions.Count -lt 64) {
                $entry = [ordered]@{ aic = $aic; latestAic = $aic }
                $legacyPath = Join-Path $directory "hud-quota-est-$sessionId.json"
                if ($initial -and [IO.File]::Exists($legacyPath)) {
                    try {
                        $legacy = Read-QuotaEstimateRecord -Path $legacyPath -MaxBytes 2048
                        if (-not (Test-LegacyQuotaEstimateRecord $legacy)) {
                            throw [IO.InvalidDataException]::new('Invalid legacy quota estimate')
                        }
                        if ($legacy.plan -eq $Used -and $legacy.aic -le $aic -and
                            [IO.File]::GetLastWriteTime($legacyPath).Date -eq $Today.Date) {
                            $entry.aic = [double]$legacy.aic
                        }
                    } catch {
                        $record.complete = $false
                        Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'state-rebased'
                    }
                }
                $record.sessions[$sessionId] = $entry
                try {
                    $pendingPath = Join-Path $directory "hud-quota-pending-$date-$sessionId.json"
                    Write-QuotaPendingEstimate -Path $pendingPath -Epoch $record.epoch -Nano $nano -Reset
                } catch {
                    $complete = $false
                    Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'state-unavailable'
                }
            } else {
                $record.complete = $false
                Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'capacity'
            }
        }
        Merge-QuotaPendingEstimates -CopilotHome $CopilotHome -Ledger $record
        if (-not $initial -or $null -ne $nano) {
            Write-QuotaEstimateRecord -Path $path -Record $record -MaxBytes 65536
            Remove-ExpiredQuotaPendingEstimates -CopilotHome $CopilotHome -Today $Today
        }
    } catch {
        $complete = $false
        Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'state-unavailable'
        $record = $null
        if ([IO.File]::Exists($path)) {
            try {
                $cached = Read-QuotaEstimateRecord -Path $path
                if (Test-QuotaEstimateLedger $cached) {
                    if (Test-QuotaEstimateCheckpointAhead -Record $cached -Date $date `
                        -Used $Used -Period $Period -Entitlement $Entitlement -SnapshotAt $SnapshotAt) {
                        return [pscustomobject]@{ Amount = 0.0; Complete = $false; Accepted = $false }
                    }
                    $record = $cached
                    Merge-QuotaPendingEstimates -CopilotHome $CopilotHome -Ledger $record
                }
            } catch { Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'rollup-incomplete' }
        }
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
    }
    $amount = 0.0
    if ($null -ne $record -and $record.date -ceq $date -and $record.plan -eq $Used -and
        $record.period -ceq $Period -and $record.entitlement -eq $Entitlement) {
        foreach ($entry in $record.sessions.Values) {
            $amount += [double]$entry.latestAic - [double]$entry.aic
        }
        $complete = $complete -and $record.complete
    } else {
        $complete = $false
    }
    return [pscustomobject]@{ Amount = $amount; Complete = $complete; Accepted = ($null -ne $record) }
}

# Account-wide daily baseline: usage and budget captured at the first render of
# each local day, so today's spend is measured against a budget fixed at day start.
function Get-QuotaDayBaseline {
    param([string]$CopilotHome, [double]$Used, [AllowNull()][object]$Budget, [switch]$ReadOnly)

    if ($ReadOnly) {
        return (Get-QuotaDayBaselineCore -CopilotHome $CopilotHome -Used $Used -Budget $Budget -ReadOnly)
    }
    $lock = $null
    try {
        $directory = Join-Path $CopilotHome 'state'
        [void][IO.Directory]::CreateDirectory($directory)
        $lock = [IO.File]::Open((Join-Path $directory 'hud-quota-day.json.lock'),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        return (Get-QuotaDayBaselineCore -CopilotHome $CopilotHome -Used $Used -Budget $Budget)
    } catch [IO.IOException] {
        Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'state-unavailable'
        return (Get-QuotaDayBaselineCore -CopilotHome $CopilotHome -Used $Used -Budget $Budget -ReadOnly)
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

function Get-QuotaDayBaselineCore {
    param([string]$CopilotHome, [double]$Used, [AllowNull()][object]$Budget, [switch]$ReadOnly)

    $directory = Join-Path $CopilotHome 'state'
    $path = Join-Path $directory 'hud-quota-day.json'
    if ([IO.Directory]::Exists($path)) {
        throw [IO.IOException]::new('Daily quota baseline destination is not a file')
    }
    $today = [DateTime]::Today.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $existing = $null
    try {
        if ([IO.File]::Exists($path)) {
            $existing = Read-QuotaEstimateRecord -Path $path -MaxBytes 4096
            if ($existing.startUsed -isnot [ValueType] -or
                $null -eq (ConvertTo-NullableNumber $existing.startUsed) -or
                $existing.date -isnot [string] -or
                $existing.date -cnotmatch '^\d{4}-\d{2}-\d{2}$' -or
                ($null -ne $existing.budget -and
                    ($existing.budget -isnot [ValueType] -or
                        $null -eq (ConvertTo-NullableNumber $existing.budget)))) {
                throw [IO.InvalidDataException]::new('Invalid daily quota baseline')
            }
        }
    } catch {
        Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'state-unavailable'
        throw
    }
    if ($ReadOnly) {
        if ($null -ne $existing -and [string]$existing.date -ceq $today -and
            $existing.startUsed -is [ValueType]) {
            return $existing
        }
        return $null
    }
    if ($null -ne $existing -and [string]$existing.date -ceq $today -and
        $existing.startUsed -is [ValueType] -and [double]$existing.startUsed -le $Used) {
        return $existing
    }

    $record = [pscustomobject]@{
        date = $today
        startUsed = $Used
        budget = if ($null -ne $Budget) { [math]::Round([double]$Budget, 2) } else { $null }
    }
    try {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }
        $temporary = "$path.$PID.tmp"
        [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json -Compress))
        Move-Item -LiteralPath $temporary -Destination $path -Force
    } catch {
        Remove-Item -LiteralPath "$path.$PID.tmp" -Force -ErrorAction SilentlyContinue
        Write-QuotaEstimateWarning -CopilotHome $CopilotHome -Reason 'state-unavailable'
        throw
    }
    return $record
}

function Get-QuotaSegment {
    param([AllowNull()][object]$QuotaData)

    if ($null -eq $QuotaData) { return $null }
    $color = Get-ThresholdColor -Percentage $QuotaData.Percentage
    $rounded = [int][math]::Floor($QuotaData.Percentage)
    $age = ''
    if ($QuotaData.Stale) {
        $minutes = [math]::Floor([double]$QuotaData.AgeMs / 60000)
        $ageText = if ($minutes -lt 60) { "${minutes}m" }
            elseif ($minutes -lt 2880) { "$([math]::Floor($minutes / 60))h" }
            else { "$([math]::Floor($minutes / 1440))d" }
        $age = ' ' + $script:Dim + "($ageText ago)" + $script:Reset
    }
    return $script:Dim + 'Quota' + $script:Reset + ' ' +
        (Get-GaugeBar -Percentage $QuotaData.Percentage -Width 8 -Floor) + ' ' +
        $script:Bright + $color + "$rounded%" + $script:Reset + $age
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
    $budget = $null
    if ($null -ne $QuotaData.TodayUsed -and $null -ne $QuotaData.TodayBudget) {
        $spent = $QuotaData.TodayUsed
        $limit = $QuotaData.TodayBudget
        $ratio = 100.0 * $spent / $limit
        $spentColor = if ($ratio -ge 100) {
            $script:Bright + $script:Colors.red
        } elseif ($ratio -ge 75 -or $QuotaData.TodayEstimateComplete -eq $false) {
            $script:Bright + $script:Colors.yellow
        } else {
            $script:Dim
        }
        $approx = if ($QuotaData.TodayEstimated) { '~' } else { '' }
        $unknown = if ($QuotaData.TodayEstimateComplete -eq $false) { '+?' } else { '' }
        $budget = '⚡' + $spentColor + $approx + (Format-Count ([math]::Floor($spent))) + $unknown + $script:Reset +
            $script:Dim + '/' + (Format-Count ([math]::Floor($limit))) + ' today' + $script:Reset
    } elseif ($null -ne $QuotaData.PerWorkday) {
        $budget = '⚡' + $script:Dim + (Format-Count ([math]::Floor($QuotaData.PerWorkday))) + '/workday' + $script:Reset
    }
    if ($null -ne $budget) {
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
    if ($null -eq $delta) {
        $reason = $SignalState['recentSuppressedReason']
        if ($reason -is [string] -and $reason -cmatch '^[a-z-]{1,16}$') {
            return $placeholder + ' ' + $script:Dim + "($($reason -replace '-', ' '))" + $script:Reset
        }
        return $placeholder
    }
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

        $copilotHome = Get-HudHome
        if (-not $copilotHome) { return $null }
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
        $copilotHome = Get-HudHome
        if (-not $copilotHome -or -not (Test-HudBridgeEnabled $copilotHome)) { return $null }
        $sessionId = Get-FirstValue -InputObject $Payload -Paths @('session_id')
        if ($sessionId -isnot [string] -or
            $sessionId -notmatch '^[A-Za-z0-9_-]{1,128}$' -or
            -not (Test-HudLocalPath $copilotHome)) {
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
        $allowedProperties = $requiredProperties + @('activeSubagentCount', 'recentSuppressedReason')
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
        $suppressedReason = $null
        if ($stateKeys -ccontains 'recentSuppressedReason') {
            $suppressedReason = $state['recentSuppressedReason']
        }
        if ($null -ne $recentDelta) {
            if (-not (Test-HudSignalInteger $recentDelta) -or
                -not (Test-HudSignalInteger $recentAt) -or
                $null -ne $suppressedReason -or
                [double]$recentAt -gt $now + 5000) {
                return $null
            }
            if ($now - [double]$recentAt -gt 120000) {
                $recentDelta = $null
                $recentAt = $null
            }
        } elseif ($null -ne $suppressedReason) {
            if ($suppressedReason -isnot [string] -or
                $suppressedReason -cnotin @('overlap', 'incomplete', 'early-usage',
                    'no-baseline', 'no-usage', 'subagent', 'reset', 'interrupted', 'ambiguous') -or
                -not (Test-HudSignalInteger $recentAt) -or
                [double]$recentAt -gt $now + 5000) {
                return $null
            }
            if ($now - [double]$recentAt -gt 120000) {
                $suppressedReason = $null
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
            recentSuppressedReason = $suppressedReason
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

        $copilotHome = Get-HudHome
        if (-not $copilotHome) { return }
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

        $copilotHome = Get-HudHome
        if (-not $copilotHome) { return $fallback }
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
            if ($segment.Key -ceq 'branch-sync' -and
                $overflowLines.Contains([string]$segment.Line)) {
                $Segments.RemoveAt($index)
                $removed = $true
                break
            }
        }
        if ($removed) { continue }
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

$quotaData = try { Get-QuotaData -Payload $payload } catch { $null }
$quotaSegment = Invoke-StatusSegment { Get-QuotaSegment $quotaData }
$gitContext = try { Get-LocalGitContext -Path ([string]$payload.cwd) } catch { $null }
$segments = [System.Collections.Generic.List[object]]::new()

foreach ($segment in @(
    [pscustomobject]@{
        Key = 'branch'; Group = 'branch'; Line = 'location'
        Value = (Invoke-StatusSegment { Get-BranchSegment -Payload $payload -GitContext $gitContext })
    },
    [pscustomobject]@{
        Key = 'branch-sync'; Group = 'branch'; Line = 'location'
        SeparatorBefore = ' '
        Value = (Invoke-StatusSegment { Get-GitSyncSegment -GitContext $gitContext })
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
