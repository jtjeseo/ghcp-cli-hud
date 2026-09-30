#requires -Version 5.1
<#
.SYNOPSIS
Installs the HUD renderer and hook handlers (and optionally the signal bridge) into a Copilot home.
Every file is backed up first with a hash manifest that Uninstall-Hud.ps1 uses for rollback.
settings.json and the hook config are never rewritten.
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
    [string]$CopilotHome = (Join-Path $env:USERPROFILE '.copilot'),
    [switch]$IncludeBridge,
    [switch]$SetEnvironment,
    [switch]$EnableGitSync
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$defaultHome = Join-Path $env:USERPROFILE '.copilot'
$isDefaultHome = ([IO.Path]::GetFullPath($CopilotHome).TrimEnd('\') -ieq [IO.Path]::GetFullPath($defaultHome).TrimEnd('\'))

if ($SetEnvironment -and -not $IncludeBridge) { throw '-SetEnvironment requires -IncludeBridge.' }
if ($EnableGitSync -and -not $IncludeBridge) { throw '-EnableGitSync requires -IncludeBridge.' }
if ($SetEnvironment -and -not $isDefaultHome) { throw '-SetEnvironment is only allowed for the default Copilot home.' }

$bridgeSource = Join-Path $repo '.github\extensions\hud-signal-bridge'
$targets = [System.Collections.Generic.List[object]]::new()
function Add-Target([string]$Source, [string]$Relative, [switch]$OnlyIfMissing) {
    $targets.Add([pscustomobject]@{ Source = $Source; Relative = $Relative; OnlyIfMissing = [bool]$OnlyIfMissing })
}
Add-Target (Join-Path $repo 'statusline\statusline.ps1') 'statusline\statusline.ps1'
Add-Target (Join-Path $repo 'statusline\statusline.cmd') 'statusline\statusline.cmd' -OnlyIfMissing
Add-Target (Join-Path $repo 'hooks\state-hook.ps1') 'hooks\state-hook.ps1'
Add-Target (Join-Path $repo 'hooks\state-hook.sh') 'hooks\state-hook.sh'
Add-Target (Join-Path $repo 'hooks\session-state-hooks.json') 'hooks\session-state-hooks.json.disabled' -OnlyIfMissing
if ($IncludeBridge) {
    foreach ($name in 'extension.mjs', 'quota.mjs', 'git-sync.mjs', 'git-fetch.ps1', 'state-machine.mjs', 'state-store.mjs') {
        Add-Target (Join-Path $bridgeSource $name) "extensions\hud-signal-bridge\$name"
    }
    if ($EnableGitSync) {
        Add-Target (Join-Path $repo 'statusline\git-sync.json') 'hud-git-sync.json' -OnlyIfMissing
    }
}

foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t.Source -PathType Leaf)) { throw "Missing repo file: $($t.Source)" }
}
if (-not (Test-Path -LiteralPath $CopilotHome -PathType Container)) { throw "Copilot home not found: $CopilotHome" }

$activeHookConfig = Join-Path $CopilotHome 'hooks\session-state-hooks.json'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $CopilotHome "backups\hud-install-$stamp"
$entries = [System.Collections.Generic.List[object]]::new()

foreach ($t in $targets) {
    $dest = Join-Path $CopilotHome $t.Relative
    $existed = Test-Path -LiteralPath $dest -PathType Leaf
    $hasActiveConfig = ($t.Relative -like '*session-state-hooks.json.disabled') -and (Test-Path -LiteralPath $activeHookConfig)
    $hashBefore = if ($existed) { (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash } else { $null }
    $skip = ($t.OnlyIfMissing -and $existed) -or $hasActiveConfig
    $hashSource = (Get-FileHash -LiteralPath $t.Source -Algorithm SHA256).Hash
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
    ($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding UTF8

    foreach ($t in $targets) {
        $e = $entries | Where-Object { $_.relative -eq $t.Relative }
        if ($e.skipped) { continue }
        $dest = Join-Path $CopilotHome $t.Relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        Copy-Item -LiteralPath $t.Source -Destination $dest -Force
        if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $e.sha256Installed) {
            throw "Verification failed for $($t.Relative); run Uninstall-Hud.ps1 -BackupPath '$backup'."
        }
    }
    if ($SetEnvironment) {
        [Environment]::SetEnvironmentVariable('COPILOT_HUD_SIGNAL_BRIDGE', '1', 'User')
        [Environment]::SetEnvironmentVariable('COPILOT_HOME', $CopilotHome, 'User')
    }
}

'Installed: {0} files ({1} skipped as already present). Backup: {2}' -f
    @($entries | Where-Object { -not $_.skipped }).Count, @($entries | Where-Object { $_.skipped }).Count, $backup
$settingsPath = Join-Path $CopilotHome 'settings.json'
$expected = Join-Path $CopilotHome 'statusline\statusline.cmd'
$hasStatusLine = $false
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $s = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $hasStatusLine = ($null -ne $s.statusLine) -and ([string]$s.statusLine.command -match 'statusline\.cmd')
    } catch { }
}
if (-not $hasStatusLine) {
    "Next: add this to settings.json yourself (not modified): statusLine = {type: command, command: $expected, refreshInterval: 5}"
}
if (Test-Path -LiteralPath $activeHookConfig) {
    'Hooks: existing session-state-hooks.json left unchanged.'
} else {
    'Hooks: installed as session-state-hooks.json.disabled; validate the handlers, then rename it to enable.'
}
if ($IncludeBridge -and -not $SetEnvironment) {
    'Bridge files copied. It stays idle until COPILOT_HUD_SIGNAL_BRIDGE=1 and COPILOT_HOME are set (see README or use -SetEnvironment).'
}
'Restart Copilot from a new Windows Terminal tab to pick up the changes. Rollback: scripts\Uninstall-Hud.ps1 -BackupPath "{0}"' -f $backup
