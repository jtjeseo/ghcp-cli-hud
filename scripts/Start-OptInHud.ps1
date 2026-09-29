[CmdletBinding()]
param(
    [switch]$PreflightOnly,
    [switch]$AicValidation
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-ScopedProcessEnvironment.ps1')

$repoRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..')
)
$currentDirectory = [System.IO.Path]::GetFullPath((Get-Location).Path)
if (-not [string]::Equals(
        $currentDirectory.TrimEnd('\'),
        $repoRoot.TrimEnd('\'),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Run this launcher from the ghcp-cli-hud repository root.'
}

$git = Get-Command git -ErrorAction Stop
$reportedRoot = & $git.Source -C $repoRoot rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or
    -not [string]::Equals(
        [System.IO.Path]::GetFullPath($reportedRoot.Trim()).TrimEnd('\'),
        $repoRoot.TrimEnd('\'),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'The current directory is not the expected Git repository root.'
}

$extensionDirectory = Join-Path $repoRoot '.github\extensions'
$projectExtensions = @(
    Get-ChildItem -LiteralPath $extensionDirectory -Directory -ErrorAction Stop |
        ForEach-Object { $_.Name }
)
if ($projectExtensions.Count -ne 1 -or
    $projectExtensions[0] -cne 'hud-signal-bridge') {
    throw 'Only the project-scoped hud-signal-bridge extension may be present.'
}
$projectHooksDirectory = Join-Path $repoRoot '.github\hooks'
if (Test-Path -LiteralPath $projectHooksDirectory -PathType Container) {
    throw 'This launcher refuses additional repository-level hooks.'
}

$requiredFiles = @(
    (Join-Path $extensionDirectory 'hud-signal-bridge\extension.mjs'),
    (Join-Path $extensionDirectory 'hud-signal-bridge\state-machine.mjs'),
    (Join-Path $extensionDirectory 'hud-signal-bridge\state-store.mjs'),
    (Join-Path $repoRoot 'statusline\statusline.cmd'),
    (Join-Path $repoRoot 'statusline\statusline.ps1'),
    (Join-Path $repoRoot 'hooks\session-state-hooks.json'),
    (Join-Path $repoRoot 'hooks\state-hook.ps1'),
    (Join-Path $repoRoot 'hooks\state-hook.sh')
)
if ($AicValidation) {
    $requiredFiles += Join-Path $PSScriptRoot 'Wait-AicValidation.ps1'
}
foreach ($path in $requiredFiles) {
    if (-not [System.IO.File]::Exists($path)) {
        throw 'A required project bridge, renderer, or hook file is missing.'
    }
}
$null = Get-Command pwsh -ErrorAction Stop

$expectedEvents = @(
    'sessionStart',
    'sessionEnd',
    'preToolUse',
    'postToolUse',
    'postToolUseFailure',
    'errorOccurred',
    'subagentStart',
    'subagentStop'
)
$sourceHookPath = Join-Path $repoRoot 'hooks\session-state-hooks.json'
try {
    $sourceHooks = ConvertFrom-Json -InputObject (
        [System.IO.File]::ReadAllText($sourceHookPath, [System.Text.Encoding]::UTF8)
    ) -ErrorAction Stop
} catch {
    throw 'The repository hook configuration is not valid JSON.'
}
$sourceEvents = @($sourceHooks.hooks.PSObject.Properties.Name)
if ($sourceHooks.version -ne 1 -or
    $sourceEvents.Count -ne $expectedEvents.Count -or
    @($expectedEvents | Where-Object { $_ -notin $sourceEvents }).Count -gt 0) {
    throw 'The repository hook configuration has an unexpected event set.'
}
foreach ($eventName in $expectedEvents) {
    $entries = @($sourceHooks.hooks.PSObject.Properties[$eventName].Value)
    if ($entries.Count -ne 1 -or
        $entries[0].type -cne 'command' -or
        $entries[0].bash -isnot [string] -or
        $entries[0].powershell -isnot [string]) {
        throw 'Every configured hook must have one Bash and one PowerShell command.'
    }
    if (-not $entries[0].bash.Contains(
            '${COPILOT_HOME:-$HOME/.copilot}/hooks/state-hook.sh'
        ) -or
        -not $entries[0].powershell.Contains('$env:COPILOT_HOME') -or
        -not $entries[0].powershell.Contains(
            'Join-Path $copilotHome ''hooks\state-hook.ps1'''
        ) -or
        -not $entries[0].bash.EndsWith(
            " $eventName",
            [System.StringComparison]::Ordinal
        ) -or
        -not $entries[0].powershell.EndsWith(
            "-Event $eventName",
            [System.StringComparison]::Ordinal
        )) {
        throw 'A hook command does not resolve through COPILOT_HOME to its handler.'
    }
}

$tempRoot = [System.IO.Path]::GetFullPath(
    (Resolve-Path -LiteralPath $env:TEMP -ErrorAction Stop).Path
)
$normalHome = [System.IO.Path]::GetFullPath(
    (Join-Path $env:USERPROFILE '.copilot')
)
if (Test-Path -LiteralPath $normalHome -PathType Container) {
    $normalHome = [System.IO.Path]::GetFullPath(
        (Resolve-Path -LiteralPath $normalHome -ErrorAction Stop).Path
    )
}
$copilotHome = Join-Path $tempRoot (
    'copilot-hud-session-' + [guid]::NewGuid().ToString('N')
)
$copilotHomeFull = [System.IO.Path]::GetFullPath($copilotHome)
$tempPrefix = $tempRoot.TrimEnd('\') + '\'
$normalPrefix = $normalHome.TrimEnd('\') + '\'
if ($copilotHomeFull -notmatch '^[A-Za-z]:\\' -or
    -not $copilotHomeFull.StartsWith(
        $tempPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or
    ($copilotHomeFull + '\').StartsWith(
        $normalPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'The isolated COPILOT_HOME must be beneath TEMP and outside the normal user home.'
}
if (Test-Path -LiteralPath $copilotHome) {
    throw 'The generated COPILOT_HOME already exists; refusing to reuse it.'
}

New-Item -ItemType Directory -Path $copilotHome -ErrorAction Stop | Out-Null
$copilotHomeInfo = Get-Item -LiteralPath $copilotHome -Force
if (($copilotHomeInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The isolated COPILOT_HOME must not be a reparse point.'
}
$hookDirectory = Join-Path $copilotHome 'hooks'
$ghConfigDirectory = Join-Path $copilotHome 'gh-cli-config'
New-Item -ItemType Directory -Path $hookDirectory, $ghConfigDirectory -ErrorAction Stop |
    Out-Null
foreach ($path in @($hookDirectory, $ghConfigDirectory)) {
    $directoryInfo = Get-Item -LiteralPath $path -Force
    if (($directoryInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'A generated configuration directory must not be a reparse point.'
    }
}

$hookDestination = Join-Path $hookDirectory 'session-state-hooks.json'
$powerShellHookDestination = Join-Path $hookDirectory 'state-hook.ps1'
$bashHookDestination = Join-Path $hookDirectory 'state-hook.sh'
Copy-Item -LiteralPath $sourceHookPath -Destination $hookDestination
Copy-Item -LiteralPath (Join-Path $repoRoot 'hooks\state-hook.ps1') `
    -Destination $powerShellHookDestination
Copy-Item -LiteralPath (Join-Path $repoRoot 'hooks\state-hook.sh') `
    -Destination $bashHookDestination

foreach ($pair in @(
    [pscustomobject]@{
        Source = $sourceHookPath
        Destination = $hookDestination
    },
    [pscustomobject]@{
        Source = (Join-Path $repoRoot 'hooks\state-hook.ps1')
        Destination = $powerShellHookDestination
    },
    [pscustomobject]@{
        Source = (Join-Path $repoRoot 'hooks\state-hook.sh')
        Destination = $bashHookDestination
    }
)) {
    $sourceHash = (Get-FileHash -LiteralPath $pair.Source -Algorithm SHA256).Hash
    $copyHash = (Get-FileHash -LiteralPath $pair.Destination -Algorithm SHA256).Hash
    if ($sourceHash -cne $copyHash) {
        throw 'A copied hook file did not match its repository source.'
    }
}

$statuslineCommand = [System.IO.Path]::GetFullPath(
    (Join-Path $repoRoot 'statusline\statusline.cmd')
)
$settings = [ordered]@{
    statusLine = [ordered]@{
        type = 'command'
        command = $statuslineCommand
        refreshInterval = 5
    }
}
$settingsPath = Join-Path $copilotHome 'settings.json'
[System.IO.File]::WriteAllText(
    $settingsPath,
    (ConvertTo-Json -InputObject $settings -Depth 4),
    [System.Text.UTF8Encoding]::new($false)
)
$settingsInfo = Get-Item -LiteralPath $settingsPath -Force
if (($settingsInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The isolated settings file must not be a reparse point.'
}
$isolatedSettings = ConvertFrom-Json -InputObject (
    [System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8)
) -ErrorAction Stop
if (@($isolatedSettings.PSObject.Properties.Name).Count -ne 1 -or
    $isolatedSettings.statusLine.command -cne $statuslineCommand -or
    $isolatedSettings.statusLine.refreshInterval -ne 5 -or
    -not [System.IO.File]::Exists($isolatedSettings.statusLine.command)) {
    throw 'The isolated home must configure only the repository statusline command.'
}
$homeEntryNames = @(
    Get-ChildItem -LiteralPath $copilotHome -Force |
        ForEach-Object { $_.Name } |
        Sort-Object
)
$expectedHomeEntryNames = @('gh-cli-config', 'hooks', 'settings.json')
if ($homeEntryNames.Count -ne $expectedHomeEntryNames.Count -or
    @($expectedHomeEntryNames | Where-Object { $_ -notin $homeEntryNames }).Count -gt 0) {
    throw 'The isolated home must contain only the launcher settings, hooks, and empty GH config.'
}
if (@(Get-ChildItem -LiteralPath $ghConfigDirectory -Force).Count -ne 0) {
    throw 'The isolated GitHub CLI configuration directory must start empty.'
}

if ($PreflightOnly) {
    $preflightTemplate = 'Preflight passed: hooks={0}; PowerShell handler={1}; ' +
        'Bash handler={2}; statusline=pwsh; COPILOT_HOME=fresh; ' +
        'AICValidation={3}; AICObserver={4}; Copilot=not launched.'
    $preflightMessage = $preflightTemplate -f $expectedEvents.Count,
        [System.IO.File]::Exists($powerShellHookDestination),
        [System.IO.File]::Exists($bashHookDestination),
        [bool]$AicValidation,
        ([bool]$AicValidation -and
            [System.IO.File]::Exists(
                (Join-Path $PSScriptRoot 'Wait-AicValidation.ps1')
            ))
    Write-Host $preflightMessage
    return
}

$copilot = Get-Command copilot -ErrorAction Stop
$aicValidationOptIn = if ($AicValidation) { '1' } else { '0' }
$scopedEnvironment = @{
    COPILOT_HOME = $copilotHome
    GH_CONFIG_DIR = $ghConfigDirectory
    COPILOT_HUD_SIGNAL_BRIDGE = '1'
    COPILOT_HUD_SIGNAL_DIAGNOSTICS = '0'
    COPILOT_HUD_AIC_VALIDATION = $aicValidationOptIn
    COPILOT_RAW_PAYLOAD_CAPTURE = '0'
    COPILOT_PROVIDERS_CONFIG = $null
    COPILOT_CUSTOM_INSTRUCTIONS_DIRS = $null
    COPILOT_GITHUB_TOKEN = $null
    GITHUB_COPILOT_GITHUB_TOKEN = $null
    GITHUB_COPILOT_AGENT_GITHUB_TOKEN = $null
    GH_ENTERPRISE_TOKEN = $null
    GITHUB_ENTERPRISE_TOKEN = $null
    GH_TOKEN = $null
    GITHUB_TOKEN = $null
    COPILOT_TOKEN = $null
}
Invoke-ScopedProcessEnvironment -Environment $scopedEnvironment -Action {
    Push-Location -LiteralPath $repoRoot
    try {
        if ($AicValidation) {
            $observerScript = Join-Path $PSScriptRoot 'Wait-AicValidation.ps1'
            $observerHost = Get-Command powershell.exe -ErrorAction Stop
            $observerArguments = '-NoLogo -NoProfile -NoExit -File "' +
                $observerScript + '"'
            $null = Start-Process -FilePath $observerHost.Source `
                -ArgumentList $observerArguments -WindowStyle Normal
        }
        & $copilot.Source --experimental
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "Copilot exited with code $exitCode."
        }
    } finally {
        Pop-Location
    }
}
Write-Host 'HUD process exited; scoped environment restored. The temporary home was retained.'
