#requires -Version 5.1
<#
.SYNOPSIS
Installs the HUD renderer and hook handlers (and optionally the signal bridge) into a Copilot home.
Every file is backed up first with a hash manifest that Uninstall-Hud.ps1 uses for rollback.
Legacy defaults never rewrite settings.json or an active hook config.
.PARAMETER CopilotHome
Target home. Defaults to %USERPROFILE%\.copilot.
.PARAMETER IncludeBridge
Also copy the experimental hud-signal-bridge extension into <home>\extensions.
.PARAMETER SetEnvironment
With -IncludeBridge, set the user variables COPILOT_HUD_SIGNAL_BRIDGE=1 and COPILOT_HOME. Only allowed for the default home.
.PARAMETER EnableGitSync
With -IncludeBridge, install the separate background-fetch opt-in. Existing options are preserved.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CopilotHome = $(if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else {
        Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.copilot'
    }),
    [switch]$IncludeBridge,
    [switch]$SetEnvironment,
    [switch]$EnableGitSync,
    [switch]$ConfigureStatusLine,
    [switch]$EnableBridge,
    [switch]$EnableHooks,
    [switch]$ReplaceStatusLine
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$windows = [IO.Path]::DirectorySeparatorChar -eq '\'
if (($windows -and $CopilotHome -notmatch '^[A-Za-z]:[\\/]') -or
    (-not $windows -and (-not $CopilotHome.StartsWith('/') -or $CopilotHome.StartsWith('//')))) {
    throw 'Copilot home must be an absolute local path.'
}
$defaultHome = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.copilot'
$CopilotHome = [IO.Path]::GetFullPath($CopilotHome)
. (Join-Path $PSScriptRoot 'Hud-Paths.ps1')
Assert-HudTargetPath $CopilotHome $CopilotHome
$comparison = if ($windows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$isDefaultHome = $CopilotHome.TrimEnd([IO.Path]::DirectorySeparatorChar).Equals(
    [IO.Path]::GetFullPath($defaultHome).TrimEnd([IO.Path]::DirectorySeparatorChar), $comparison)

if ($SetEnvironment -and -not $IncludeBridge) { throw '-SetEnvironment requires -IncludeBridge.' }
if ($EnableGitSync -and -not $IncludeBridge) { throw '-EnableGitSync requires -IncludeBridge.' }
if ($SetEnvironment -and -not $isDefaultHome) { throw '-SetEnvironment is only allowed for the default Copilot home.' }
if ($SetEnvironment -and -not $windows) { throw '-SetEnvironment is Windows-only; use -EnableBridge for portable opt-in.' }
if ($EnableBridge -and (-not $IncludeBridge -or -not $ConfigureStatusLine)) {
    throw '-EnableBridge requires -IncludeBridge and -ConfigureStatusLine.'
}
if ($ReplaceStatusLine -and -not $ConfigureStatusLine) { throw '-ReplaceStatusLine requires -ConfigureStatusLine.' }
if (($ConfigureStatusLine -or $EnableHooks) -and $PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Configuration and hook activation require PowerShell 7. Run this command with pwsh.'
}
if (-not $windows -and -not $IsMacOS) { throw 'The installer supports Windows and macOS.' }

$bridgeSource = Join-Path $repo '.github\extensions\hud-signal-bridge'
$targets = [System.Collections.Generic.List[object]]::new()
function Add-Target([string]$Source, [string]$Relative, [switch]$OnlyIfMissing, [AllowNull()][string]$Content) {
    $targets.Add([pscustomobject]@{
        Source = $Source; Relative = $Relative; OnlyIfMissing = [bool]$OnlyIfMissing
        Content = $Content; Generated = $PSBoundParameters.ContainsKey('Content')
    })
}
Add-Target (Join-Path $repo 'statusline\statusline.ps1') 'statusline\statusline.ps1'
$wrapper = if ($windows) { 'statusline.cmd' } else { 'statusline.sh' }
Add-Target (Join-Path (Join-Path $repo 'statusline') $wrapper) (Join-Path 'statusline' $wrapper) -OnlyIfMissing
Add-Target (Join-Path $repo 'hooks\state-hook.ps1') 'hooks\state-hook.ps1'
Add-Target (Join-Path $repo 'hooks\state-hook.sh') 'hooks\state-hook.sh'
$activeHookConfig = Join-Path $CopilotHome 'hooks\session-state-hooks.json'
$hadActiveHookConfig = Test-Path -LiteralPath $activeHookConfig -PathType Leaf
if ($EnableHooks -and -not $WhatIfPreference) {
    . (Join-Path $PSScriptRoot 'Test-HudHooks.ps1')
    Test-HudHookHandlers -RepositoryRoot $repo
}
if ($EnableHooks -and -not $hadActiveHookConfig) {
    Add-Target (Join-Path $repo 'hooks\session-state-hooks.json') 'hooks\session-state-hooks.json' -OnlyIfMissing
} else {
    Add-Target (Join-Path $repo 'hooks\session-state-hooks.json') 'hooks\session-state-hooks.json.disabled' -OnlyIfMissing
}
if ($IncludeBridge) {
    foreach ($name in 'extension.mjs', 'configuration.mjs', 'quota.mjs', 'git-sync.mjs',
        'git-fetch.ps1', 'git-fetch.sh', 'state-machine.mjs', 'state-store.mjs') {
        Add-Target (Join-Path $bridgeSource $name) "extensions\hud-signal-bridge\$name"
    }
    if ($EnableGitSync) {
        Add-Target (Join-Path $repo 'statusline\git-sync.json') 'hud-git-sync.json' -OnlyIfMissing
    }
    if ($EnableBridge) {
        Add-Target (Join-Path $repo 'statusline\signal-bridge.json') 'hud-signal-bridge.json' -OnlyIfMissing
    }
}

$settingsPath = Join-Path $CopilotHome 'settings.json'
$expected = Join-Path (Join-Path $CopilotHome 'statusline') $wrapper
$command = if ($windows) { '"' + $expected + '"' } else { "bash '" + $expected.Replace("'", "'\''") + "'" }
foreach ($t in $targets) {
    $dest = Join-Path $CopilotHome $t.Relative
    Assert-HudTargetPath $CopilotHome $dest
    if (Test-Path -LiteralPath $dest -PathType Container) {
        throw "HUD target must be a file, not a directory: $($t.Relative)"
    }
}
if ($ConfigureStatusLine) {
    Assert-HudTargetPath $CopilotHome $settingsPath
    if (Test-Path -LiteralPath $settingsPath -PathType Container) { throw 'Settings must be a file, not a directory.' }
    . (Join-Path $PSScriptRoot 'Hud-Configuration.ps1')
    $content = New-HudSettingsContent -Path $settingsPath -Command $command `
        -EnableBridge:$EnableBridge -ReplaceStatusLine:$ReplaceStatusLine
    Add-Target -Relative 'settings.json' -Content $content
}
foreach ($t in $targets) {
    if (-not $t.Generated -and -not (Test-Path -LiteralPath $t.Source -PathType Leaf)) {
        throw "Missing repo file: $($t.Source)"
    }
}
if ((Test-Path -LiteralPath $CopilotHome) -and -not (Test-Path -LiteralPath $CopilotHome -PathType Container)) {
    throw 'Copilot home must be a directory.'
}
if (-not $ConfigureStatusLine -and -not (Test-Path -LiteralPath $CopilotHome -PathType Container)) {
    throw "Copilot home not found: $CopilotHome"
}

$stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$backup = Join-Path $CopilotHome "backups\hud-install-$stamp"
Assert-HudTargetPath $CopilotHome $backup
$entries = [System.Collections.Generic.List[object]]::new()

foreach ($t in $targets) {
    $dest = Join-Path $CopilotHome $t.Relative
    $existed = Test-Path -LiteralPath $dest -PathType Leaf
    $hasActiveConfig = ($t.Relative -like '*session-state-hooks.json.disabled') -and (Test-Path -LiteralPath $activeHookConfig)
    $hashBefore = if ($existed) { (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash } else { $null }
    $skip = ($t.OnlyIfMissing -and $existed) -or $hasActiveConfig
    $hashSource = if ($t.Generated) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($t.Content))).Replace('-', '') }
        finally { $sha.Dispose() }
    } else { (Get-FileHash -LiteralPath $t.Source -Algorithm SHA256).Hash }
    $entries.Add([pscustomobject]@{
        relative = $t.Relative; existed = $existed; sha256Before = $hashBefore
        sha256Installed = $(if ($skip) { $hashBefore } else { $hashSource }); skipped = $skip
    })
}

if ($PSCmdlet.ShouldProcess($CopilotHome, 'Back up and install HUD files')) {
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($e in $entries) {
        if ($e.existed) {
            $copy = Join-Path $backup $e.relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $copy) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $CopilotHome $e.relative) -Destination $copy -Force
        }
    }
    $envBefore = [ordered]@{ COPILOT_HUD_SIGNAL_BRIDGE = $null; COPILOT_HOME = $null }
    if ($SetEnvironment) {
        foreach ($k in @($envBefore.Keys)) { $envBefore[$k] = [Environment]::GetEnvironmentVariable($k, 'User') }
    }
    $manifest = [ordered]@{
        version = 1; createdAt = (Get-Date).ToString('s'); copilotHome = $CopilotHome
        includeBridge = [bool]$IncludeBridge; setEnvironment = [bool]$SetEnvironment
        environmentBefore = $envBefore; files = $entries
    }
    if ($ConfigureStatusLine) {
        $manifest['configuration'] = @{ command = $command; enabledExperimental = [bool]$EnableBridge }
    }
    ($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding UTF8

    foreach ($t in $targets) {
        $e = $entries | Where-Object { $_.relative -eq $t.Relative }
        if ($e.skipped) { continue }
        $dest = Join-Path $CopilotHome $t.Relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        if ($t.Generated) {
            [IO.File]::WriteAllText($dest, $t.Content, (New-Object Text.UTF8Encoding $false))
        } else {
            [IO.File]::WriteAllBytes($dest, [IO.File]::ReadAllBytes($t.Source))
            if ($windows) { Unblock-File -LiteralPath $dest -ErrorAction Stop }
        }
        if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $e.sha256Installed) {
            throw "Verification failed for $($t.Relative); run Uninstall-Hud.ps1 -BackupPath '$backup'."
        }
    }
    if ($SetEnvironment) {
        [Environment]::SetEnvironmentVariable('COPILOT_HUD_SIGNAL_BRIDGE', '1', 'User')
        [Environment]::SetEnvironmentVariable('COPILOT_HOME', $CopilotHome, 'User')
    }
} else {
    'Preview only: no installation or configuration changes were made.'
    return
}

'Installed: {0} files ({1} skipped as already present). Backup: {2}' -f
    @($entries | Where-Object { -not $_.skipped }).Count, @($entries | Where-Object { $_.skipped }).Count, $backup
$hasStatusLine = $false
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $s = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $hasStatusLine = ($null -ne $s.statusLine) -and ([string]$s.statusLine.command -match 'statusline\.(cmd|sh)')
    } catch { }
}
if (-not $hasStatusLine) {
    "Next: add this to settings.json yourself (not modified): statusLine = {type: command, command: $expected, refreshInterval: 5}"
}
if ($hadActiveHookConfig) {
    'Hooks: existing session-state-hooks.json left unchanged.'
} elseif (Test-Path -LiteralPath $activeHookConfig) {
    'Hooks: new session-state-hooks.json enabled after silent fail-open validation.'
} else {
    'Hooks: installed as session-state-hooks.json.disabled; validate the handlers, then rename it to enable.'
}
if ($IncludeBridge -and -not $SetEnvironment -and -not $EnableBridge) {
    'Bridge files copied. It stays idle until COPILOT_HUD_SIGNAL_BRIDGE=1 and COPILOT_HOME are set (see README or use -SetEnvironment).'
}
if ($EnableBridge) { 'Bridge: installed opt-in configured; existing preferences and explicit environment overrides are preserved.' }
if ($EnableHooks) { 'Hooks: an existing active configuration is preserved; absent hooks are enabled only after silent fail-open probes pass.' }
'Restart Copilot from a new terminal tab to pick up the changes. Rollback: scripts\Uninstall-Hud.ps1 -BackupPath "{0}"' -f $backup
