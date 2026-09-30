$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$install = Join-Path $repo 'scripts\Install-Hud.ps1'
$uninstall = Join-Path $repo 'scripts\Uninstall-Hud.ps1'
$root = Join-Path $env:TEMP ('hud-install-fixture-' + [guid]::NewGuid().ToString('N'))
$h = Join-Path $root 'home'
$results = [System.Collections.Generic.List[string]]::new()

function Assert-Fixture([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

try {
    Write-Text "$h\statusline\statusline.ps1" 'old renderer'
    Write-Text "$h\statusline\statusline.cmd" 'old wrapper'
    Write-Text "$h\hooks\state-hook.ps1" 'old hook'
    Write-Text "$h\hooks\session-state-hooks.json" '{"hooks":{}}'
    Write-Text "$h\settings.json" '{"experimental":true,"custom":1}'
    Write-Text "$h\state\hud-state-other.json" '{"keep":true}'
    $before = @{}
    foreach ($p in 'settings.json', 'hooks\session-state-hooks.json', 'statusline\statusline.cmd', 'state\hud-state-other.json') { $before[$p] = Hash "$h\$p" }
    $oldRenderer = Hash "$h\statusline\statusline.ps1"

    $out = & $install -CopilotHome $h -IncludeBridge -EnableGitSync 2>&1 | Out-String
    $backup = ([regex]::Match($out, 'Backup: (.+)')).Groups[1].Value.Trim()
    Assert-Fixture (Test-Path "$backup\manifest.json") 'manifest written'
    Assert-Fixture ((Hash "$h\statusline\statusline.ps1") -eq (Hash "$repo\statusline\statusline.ps1")) 'renderer installed'
    Assert-Fixture ((Hash "$h\hooks\state-hook.ps1") -eq (Hash "$repo\hooks\state-hook.ps1")) 'hook installed'
    foreach ($n in 'extension.mjs', 'quota.mjs', 'git-sync.mjs', 'git-fetch.ps1', 'state-machine.mjs', 'state-store.mjs') {
        Assert-Fixture ((Hash "$h\extensions\hud-signal-bridge\$n") -eq (Hash "$repo\.github\extensions\hud-signal-bridge\$n")) "bridge $n installed"
    }
    Assert-Fixture ((Hash "$h\hud-git-sync.json") -eq (Hash "$repo\statusline\git-sync.json")) 'Git sync explicitly opted in'
    foreach ($p in $before.Keys) { Assert-Fixture ((Hash "$h\$p") -eq $before[$p]) "$p unchanged" }
    Assert-Fixture (-not (Test-Path "$h\hooks\session-state-hooks.json.disabled")) 'no .disabled copy when hook config is active'
    Assert-Fixture ((Hash "$backup\statusline\statusline.ps1") -eq $oldRenderer) 'old renderer backed up'
    $results.Add('install: files installed and verified; settings, active hook config, wrapper and unrelated state unchanged; backup + manifest written')

    $envUser = [Environment]::GetEnvironmentVariable('COPILOT_HUD_SIGNAL_BRIDGE', 'User')
    $refused = $false
    try { & $install -CopilotHome $h -SetEnvironment 2>&1 | Out-Null } catch { $refused = $true }
    Assert-Fixture $refused '-SetEnvironment refused without -IncludeBridge / non-default home'
    Assert-Fixture ([Environment]::GetEnvironmentVariable('COPILOT_HUD_SIGNAL_BRIDGE', 'User') -eq $envUser) 'user environment untouched'
    $results.Add('environment: -SetEnvironment refused for a non-default home; user variables untouched')

    Write-Text "$h\extensions\hud-signal-bridge\extra.txt" 'x'
    Start-Sleep -Seconds 1
    $out2 = & $install -CopilotHome $h -IncludeBridge -WhatIf 2>&1 | Out-String
    Assert-Fixture (@(Get-ChildItem "$h\backups").Count -eq 1) '-WhatIf creates no backup'
    Remove-Item "$h\extensions\hud-signal-bridge\extra.txt"
    $results.Add('whatif: no backup or file change')

    Write-Text "$h\statusline\statusline.ps1" 'edited after install'
    $u1 = & $uninstall -BackupPath $backup 2>&1 | Out-String
    Assert-Fixture ($u1 -match 'Kept \(changed since install\): statusline\\statusline.ps1') 'post-install edit preserved'
    Assert-Fixture ((Get-Content "$h\statusline\statusline.ps1" -Raw) -eq 'edited after install') 'edited renderer untouched'
    $results.Add('rollback: file edited after install is kept, not overwritten')

    Copy-Item "$repo\statusline\statusline.ps1" "$h\statusline\statusline.ps1" -Force
    $u2 = & $uninstall -BackupPath $backup 2>&1 | Out-String
    Assert-Fixture ((Hash "$h\statusline\statusline.ps1") -eq $oldRenderer) 'old renderer restored'
    Assert-Fixture (-not (Test-Path "$h\extensions\hud-signal-bridge")) 'bridge files removed'
    Assert-Fixture (-not (Test-Path "$h\hud-git-sync.json")) 'installer-created Git opt-in removed on rollback'
    Assert-Fixture (-not (Test-Path "$h\hooks\state-hook.sh") -or (Hash "$h\hooks\state-hook.sh") -ne (Hash "$repo\hooks\state-hook.sh")) 'created hook.sh removed'
    Assert-Fixture ((Get-Content "$h\hooks\state-hook.ps1" -Raw) -eq 'old hook') 'old hook restored'
    foreach ($p in $before.Keys) { Assert-Fixture ((Hash "$h\$p") -eq $before[$p]) "$p preserved after rollback" }
    $results.Add('rollback: previous files restored by hash, installer-created files removed, unrelated files preserved')

    Write-Text "$h\hud-git-sync.json" '{"version":1,"enabled":false}'
    $optionsBefore = Hash "$h\hud-git-sync.json"
    Start-Sleep -Seconds 1
    $optIn = & $install -CopilotHome $h -IncludeBridge -EnableGitSync 2>&1 | Out-String
    Assert-Fixture ((Hash "$h\hud-git-sync.json") -ceq $optionsBefore) 'existing Git opt-in preferences overwritten'
    $optInBackup = ([regex]::Match($optIn, 'Backup: (.+)')).Groups[1].Value.Trim()
    & $uninstall -BackupPath $optInBackup | Out-Null
    Assert-Fixture ((Hash "$h\hud-git-sync.json") -ceq $optionsBefore) 'rollback removed existing Git opt-in preferences'
    Remove-Item -LiteralPath "$h\hud-git-sync.json"
    $results.Add('git-sync: explicit opt-in installed; existing preferences preserved; created opt-in rolled back')

    Remove-Item "$h\hooks\session-state-hooks.json" -Force
    $out3 = & $install -CopilotHome $h 2>&1 | Out-String
    Assert-Fixture (Test-Path "$h\hooks\session-state-hooks.json.disabled") 'hook config installed disabled when absent'
    Assert-Fixture (-not (Test-Path "$h\hooks\session-state-hooks.json")) 'hook config not auto-enabled'
    Assert-Fixture (-not (Test-Path "$h\extensions\hud-signal-bridge")) 'bridge not installed without -IncludeBridge'
    Assert-Fixture (-not (Test-Path "$h\hud-git-sync.json")) 'Git sync not implicitly enabled'
    $results.Add('defaults: absent hook config installed as .disabled only; bridge only with -IncludeBridge')

    'HudInstallScriptsPass=True'
    $results
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
