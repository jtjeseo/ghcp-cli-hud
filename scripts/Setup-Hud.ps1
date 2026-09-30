#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CopilotHome = $(if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else {
        Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.copilot'
    }),
    [switch]$Basic,
    [switch]$EnableGitSync,
    [switch]$SkipHooks,
    [switch]$ReplaceStatusLine,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
$windows = [IO.Path]::DirectorySeparatorChar -eq '\'
if (-not $windows -and -not $IsMacOS) { throw 'Setup supports Windows and macOS.' }
if ($Basic -and $EnableGitSync) { throw '-EnableGitSync requires the full bridge; omit -Basic.' }

function Test-SetupApplication {
    param([string]$Name, [version]$Minimum)
    $application = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $application) { throw "Missing prerequisite: $Name. Install it and restart your terminal." }
    $text = & $application.Source --version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $text -notmatch '\b(\d+\.\d+\.\d+)\b') {
        throw "Could not check the $Name version."
    }
    $version = [version]$Matches[1]
    if ($version -lt $Minimum) { throw "$Name $Minimum or newer is required." }
    "$Name $version available"
}

'PowerShell ' + $PSVersionTable.PSVersion.ToString() + ' available'
Test-SetupApplication -Name copilot -Minimum '1.0.89'
if ($EnableGitSync) { Test-SetupApplication -Name git -Minimum '2.31.0' }
if (-not $windows -and (-not $SkipHooks -or $EnableGitSync)) {
    if ($null -eq (Get-Command jq -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'Missing prerequisite: jq. On macOS, install it with brew install jq.'
    }
    'jq available'
}
if ($windows) {
    foreach ($scope in 'MachinePolicy', 'UserPolicy') {
        if ((Get-ExecutionPolicy -Scope $scope) -in @('AllSigned', 'Restricted')) {
            throw 'Organization policy restricts unsigned scripts. Do not change that policy; this unsigned HUD cannot be configured here.'
        }
    }
}
if ($CheckOnly) {
    'Prerequisites passed. No files, settings, hooks, environment variables, or plugins were changed.'
    return
}

$arguments = @{
    CopilotHome = $CopilotHome
    ConfigureStatusLine = $true
    IncludeBridge = -not $Basic
    EnableBridge = -not $Basic
    EnableGitSync = [bool]$EnableGitSync
    EnableHooks = -not $SkipHooks
    ReplaceStatusLine = [bool]$ReplaceStatusLine
    WhatIf = [bool]$WhatIfPreference
}
$output = & (Join-Path $PSScriptRoot 'Install-Hud.ps1') @arguments | Out-String
if ($WhatIfPreference) {
    'Preview passed. No installation or configuration changes were made.'
    return
}
$backup = ([regex]::Match($output, 'Backup: (.+)')).Groups[1].Value.Trim()
if (-not $backup) { throw 'Installation did not provide a rollback backup.' }
'HUD setup complete. Restart Copilot CLI to load the settings and hooks.'
'Backup: ' + (Split-Path -Leaf $backup)
if (-not $Basic) { 'Bridge opt-in installed; existing preferences and environment overrides are retained. No shell profiles or user variables were changed.' }
if ($EnableGitSync) { 'Git sync preference installed; existing enabled/disabled choices are preserved.' }
if ($output -match 'Hooks: existing session-state-hooks.json left unchanged') {
    'Existing active hooks were kept. If they are not HUD hooks, tool labels require manual hook integration.'
}
'Undo: pwsh -NoProfile -File "' + (Join-Path $PSScriptRoot 'Uninstall-Hud.ps1') +
    '" -BackupPath "' + $backup + '"'
