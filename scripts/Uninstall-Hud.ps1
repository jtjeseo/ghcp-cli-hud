#requires -Version 5.1
<#
.SYNOPSIS
Rolls back an Install-Hud.ps1 run from its backup manifest. Files that existed are restored;
files the installer created are removed. Files changed after the install (hash mismatch) are left
in place unless -Force is given.
.PARAMETER BackupPath
Backup folder printed by Install-Hud.ps1 (contains manifest.json).
.PARAMETER RestoreEnvironment
Restore the user COPILOT_HUD_SIGNAL_BRIDGE / COPILOT_HOME values recorded before install (only if the install set them).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$BackupPath,
    [switch]$RestoreEnvironment,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $BackupPath 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "No manifest.json in $BackupPath" }
$m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$home_ = [string]$m.copilotHome
if (-not (Test-Path -LiteralPath $home_ -PathType Container)) { throw "Recorded Copilot home not found: $home_" }

$restored = 0; $removed = 0; $kept = 0
foreach ($e in @($m.files)) {
    $dest = Join-Path $home_ $e.relative
    if ($e.skipped) { continue }
    $present = Test-Path -LiteralPath $dest -PathType Leaf
    if ($present -and -not $Force) {
        $now = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
        if ($now -ne $e.sha256Installed) { "Kept (changed since install): $($e.relative)"; $kept++; continue }
    }
    if ($e.existed) {
        $src = Join-Path $BackupPath $e.relative
        if (-not (Test-Path -LiteralPath $src)) { throw "Backup copy missing for $($e.relative)" }
        if ($PSCmdlet.ShouldProcess($e.relative, 'Restore')) {
            Copy-Item -LiteralPath $src -Destination $dest -Force
            if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $e.sha256Before) { throw "Restore verification failed: $($e.relative)" }
            $restored++
        }
    } elseif ($present) {
        if ($PSCmdlet.ShouldProcess($e.relative, 'Remove')) { Remove-Item -LiteralPath $dest -Force; $removed++ }
    }
}
$bridgeDir = Join-Path $home_ 'extensions\hud-signal-bridge'
if ((Test-Path -LiteralPath $bridgeDir) -and @(Get-ChildItem -LiteralPath $bridgeDir -Force).Count -eq 0) {
    Remove-Item -LiteralPath $bridgeDir -Force
}
if ($RestoreEnvironment -and $m.setEnvironment) {
    foreach ($k in 'COPILOT_HUD_SIGNAL_BRIDGE', 'COPILOT_HOME') {
        if ($PSCmdlet.ShouldProcess($k, 'Restore user variable')) {
            [Environment]::SetEnvironmentVariable($k, $m.environmentBefore.$k, 'User')
        }
    }
}
'Rollback done: {0} restored, {1} removed, {2} kept. Restart Copilot from a new terminal tab.' -f $restored, $removed, $kept
