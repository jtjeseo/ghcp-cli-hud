[CmdletBinding()]
param([switch]$PreflightOnly)

$ErrorActionPreference = 'Stop'
$expectedPrefix = 'copilot-hud-transition-diagnostic-'
$kitRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$kitName = [System.IO.Path]::GetFileName($kitRoot)
$kitParent = [System.IO.Directory]::GetParent($kitRoot)
$tempRoot = [System.IO.Path]::GetFullPath($env:TEMP)
$workspace = Join-Path $kitRoot 'workspace'
$copilotHome = Join-Path $kitRoot 'copilot-home'
$ghConfig = Join-Path $kitRoot 'gh-cli-config'
$settingsPath = Join-Path $copilotHome 'settings.json'

function Assert-NoReparsePoint {
    param([string]$Path, [string]$Description)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description must not be a reparse point."
    }
}

function Assert-UnbornGitHead {
    param([string]$Workspace)

    $git = Get-Command git -ErrorAction Stop
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $git.Source
    $startInfo.Arguments = '-C "{0}" rev-parse --verify HEAD' -f $Workspace
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Could not start Git to verify the disposable root.'
        }
        $null = $process.StandardOutput.ReadToEnd()
        $null = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }
    if ($exitCode -eq 0) {
        throw 'The disposable Git root already has a commit.'
    }
    if ($exitCode -ne 128) {
        throw 'Could not verify that the disposable Git root is unborn.'
    }
}

if (-not $kitName.StartsWith(
        $expectedPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or
    $null -eq $kitParent -or
    -not [System.IO.Path]::GetFullPath($kitParent.FullName).Equals(
        $tempRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'This launcher is restricted to a direct disposable kit under TEMP.'
}
Assert-NoReparsePoint -Path $kitRoot -Description 'The disposable kit root'

$normalHome = [System.IO.Path]::GetFullPath(
    (Join-Path $env:USERPROFILE '.copilot')
)
if ([System.IO.Path]::GetFullPath($copilotHome).Equals(
        $normalHome,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Refusing to use the normal user COPILOT_HOME.'
}

foreach ($path in @($workspace, $copilotHome, $ghConfig, $settingsPath)) {
    Assert-NoReparsePoint -Path $path -Description 'Disposable launcher input'
}
$resolvedTempRoot = [System.IO.Path]::GetFullPath(
    (Resolve-Path -LiteralPath $tempRoot -ErrorAction Stop).Path
).TrimEnd('\') + '\'
$resolvedCopilotHome = [System.IO.Path]::GetFullPath(
    (Resolve-Path -LiteralPath $copilotHome -ErrorAction Stop).Path
).TrimEnd('\') + '\'
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
    )) {
    throw 'COPILOT_HOME must resolve beneath TEMP.'
}
if ($resolvedCopilotHome.StartsWith(
        $resolvedNormalHome,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'COPILOT_HOME must not be inside the normal user home.'
}

$repositoryRoot = & git -C $workspace rev-parse --show-toplevel 2>$null
$reportedRoot = if ($LASTEXITCODE -eq 0) {
    [System.IO.Path]::GetFullPath($repositoryRoot.Trim()).Replace('/', '\').TrimEnd('\')
} else {
    ''
}
$expectedRoot = [System.IO.Path]::GetFullPath($workspace).Replace('/', '\').TrimEnd('\')
if ($LASTEXITCODE -ne 0 -or
    -not [string]::Equals(
        $reportedRoot,
        $expectedRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'The workspace is not the expected disposable Git root.'
}
$remotes = @(& git -C $workspace remote 2>$null)
if ($LASTEXITCODE -ne 0 -or $remotes.Count -ne 0) {
    throw 'The disposable Git root must have no remotes.'
}
Assert-UnbornGitHead -Workspace $workspace

foreach ($requiredFile in @(
    (Join-Path $workspace '.github\extensions\hud-signal-bridge\extension.mjs'),
    (Join-Path $workspace '.github\extensions\hud-signal-bridge\state-machine.mjs'),
    (Join-Path $workspace '.github\extensions\hud-signal-bridge\state-store.mjs'),
    (Join-Path $workspace 'statusline\statusline.cmd'),
    (Join-Path $workspace 'statusline\statusline.ps1')
)) {
    if (-not [System.IO.File]::Exists($requiredFile)) {
        throw 'A required project-scoped bridge or statusline file is missing.'
    }
}
if (-not [System.IO.Directory]::Exists($copilotHome) -or
    -not [System.IO.File]::Exists($settingsPath) -or
    [System.IO.Directory]::Exists((Join-Path $copilotHome 'state')) -or
    [System.IO.Directory]::Exists((Join-Path $copilotHome 'logs')) -or
    [System.IO.Directory]::Exists((Join-Path $copilotHome 'observer-logs'))) {
    throw 'The isolated COPILOT_HOME is missing settings or is no longer fresh.'
}
$homeEntries = @(Get-ChildItem -LiteralPath $copilotHome -Force)
if ($homeEntries.Count -ne 1 -or $homeEntries[0].Name -cne 'settings.json') {
    throw 'COPILOT_HOME contains unexpected state, logs, credentials, or config.'
}
if (@(Get-ChildItem -LiteralPath $copilotHome -Recurse -File -Filter '*.jsonl').Count -gt 0 -or
    @(Get-ChildItem -LiteralPath $copilotHome -Recurse -File -Filter 'raw-*.json').Count -gt 0) {
    throw 'COPILOT_HOME contains an unexpected event or raw-payload file.'
}
if (-not [System.IO.Directory]::Exists($ghConfig) -or
    @(Get-ChildItem -LiteralPath $ghConfig -Force).Count -ne 0) {
    throw 'The isolated GitHub CLI config directory is not empty.'
}

try {
    $settings = ConvertFrom-Json -InputObject (
        [System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8)
    ) -ErrorAction Stop
} catch {
    throw 'The isolated statusline settings are not valid JSON.'
}
$expectedCommand = [System.IO.Path]::GetFullPath(
    (Join-Path $workspace 'statusline\statusline.cmd')
)
if (@($settings.PSObject.Properties.Name).Count -ne 1 -or
    $settings.statusLine.type -cne 'command' -or
    $settings.statusLine.command -cne $expectedCommand -or
    [int]$settings.statusLine.refreshInterval -ne 5) {
    throw 'Settings must contain only the disposable workspace statusline.'
}
$null = Get-Command pwsh -ErrorAction Stop

if ($PreflightOnly) {
    'Disposable preflight passed. COPILOT_HOME is fresh; Copilot was not launched.'
    return
}

$environmentNames = @(
    'COPILOT_HOME',
    'COPILOT_HUD_SIGNAL_BRIDGE',
    'COPILOT_HUD_SIGNAL_DIAGNOSTICS',
    'COPILOT_RAW_PAYLOAD_CAPTURE',
    'GH_CONFIG_DIR'
)
$tokenNames = @(
    'COPILOT_GITHUB_TOKEN',
    'GITHUB_COPILOT_GITHUB_TOKEN',
    'GITHUB_COPILOT_AGENT_GITHUB_TOKEN',
    'GH_ENTERPRISE_TOKEN',
    'GITHUB_ENTERPRISE_TOKEN',
    'GH_TOKEN',
    'GITHUB_TOKEN',
    'COPILOT_TOKEN'
)
$savedEnvironment = @{}
foreach ($name in $environmentNames) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$savedTokens = @{}
foreach ($name in $tokenNames) {
    $savedTokens[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$locationPushed = $false

try {
    foreach ($name in $tokenNames) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    [Environment]::SetEnvironmentVariable('COPILOT_HOME', $copilotHome, 'Process')
    [Environment]::SetEnvironmentVariable('COPILOT_HUD_SIGNAL_BRIDGE', '1', 'Process')
    [Environment]::SetEnvironmentVariable('COPILOT_HUD_SIGNAL_DIAGNOSTICS', '1', 'Process')
    [Environment]::SetEnvironmentVariable('COPILOT_RAW_PAYLOAD_CAPTURE', '0', 'Process')
    [Environment]::SetEnvironmentVariable('GH_CONFIG_DIR', $ghConfig, 'Process')

    Push-Location -LiteralPath $workspace
    $locationPushed = $true
    $copilot = Get-Command copilot -ErrorAction Stop
    & $copilot.Source --experimental
    if ($LASTEXITCODE -ne 0) {
        throw "Copilot exited with code $LASTEXITCODE."
    }
} finally {
    if ($locationPushed) {
        Pop-Location
    }
    foreach ($name in $tokenNames) {
        [Environment]::SetEnvironmentVariable($name, $savedTokens[$name], 'Process')
    }
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable(
            $name,
            $savedEnvironment[$name],
            'Process'
        )
    }
}
