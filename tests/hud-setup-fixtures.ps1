$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Hud-FixtureHelpers.ps1')
$repo = Split-Path -Parent $PSScriptRoot
$setup = Join-Path $repo 'scripts\Setup-Hud.ps1'
$install = Join-Path $repo 'scripts\Install-Hud.ps1'
$undo = Join-Path $repo 'scripts\Uninstall-Hud.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('hud-setup-' + [guid]::NewGuid().ToString('N'))
$windows = [IO.Path]::DirectorySeparatorChar -eq '\'
$home_ = Join-Path $root "teammate's home"
$bin = Join-Path $root 'bin'
$pathBefore = $env:PATH
function Assert-Setup([bool]$Ok, [string]$Message) { if (-not $Ok) { throw $Message } }
function Write-SetupText([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function Backup-From([string]$Output, [string]$TargetHome = $home_) {
    $name = ([regex]::Match($Output, 'Backup: ([^\r\n]+)')).Groups[1].Value.Trim()
    if ([IO.Path]::IsPathRooted($name)) { return $name }
    return (Join-Path (Join-Path $TargetHome 'backups') $name)
}
function Render-Setup([string]$Command) {
    $program = if ($windows) { $env:ComSpec } else { '/bin/bash' }
    $info = [Diagnostics.ProcessStartInfo]::new($program)
    if ($windows) { $info.Arguments = '/d /s /c "' + $Command + '"' }
    else { [void]$info.ArgumentList.Add('-c'); [void]$info.ArgumentList.Add($Command) }
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    [void]$info.Environment.Remove('COPILOT_HOME')
    [void]$info.Environment.Remove('COPILOT_HUD_SIGNAL_BRIDGE')
    $info.Environment['NO_COLOR'] = '1'
    if ($windows -and $PSVersionTable.PSVersion.Major -eq 5) {
        $info.Environment['PATH'] = Join-Path $env:SystemRoot 'System32'
    }
    $p = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        $p.StandardInput.Write('{"session_id":"handoff-fixture","terminal_width":120,"context_window":{"last_call_input_tokens":1000,"context_window_size":200000}}')
        $p.StandardInput.Close()
        if (-not $p.WaitForExit(10000)) { Stop-HudProcessTree $p; throw 'Installed statusline timed out.' }
        $text = $stdout.GetAwaiter().GetResult()
        Assert-Setup ($p.ExitCode -eq 0 -and $stderr.GetAwaiter().GetResult().Length -eq 0) 'Installed command failed.'
        Assert-Setup ($text -match 'Working' -and $text -match 'recent \+2.00 AIU') `
            'Installed wrapper did not resolve its home and config-only signal opt-in.'
    } finally { $p.Dispose() }
}
try {
    $fakeCli = Join-Path $bin $(if ($windows) { 'copilot.cmd' } else { 'copilot' })
    $source = if ($windows) { "@echo off`r`nif not `"%~1`"==`"--version`" exit /b 1`r`necho 1.0.89`r`n" }
        else { "#!/usr/bin/env bash`n[[ `"`$1`" == --version ]] || exit 1`nprintf '1.0.89\n'`n" }
    Write-SetupText $fakeCli $source
    if (-not $windows) { & chmod u+x $fakeCli; if ($LASTEXITCODE -ne 0) { throw 'Could not prepare CLI version stub.' } }
    $env:PATH = $bin + [IO.Path]::PathSeparator + $pathBefore
    & $setup -CopilotHome $home_ -CheckOnly -EnableGitSync | Out-Null
    Assert-Setup (-not [IO.Directory]::Exists($home_)) 'Preflight created a home.'
    Write-SetupText $fakeCli $source.Replace('1.0.89', '1.0.88')
    $refused = $false
    try { & $setup -CopilotHome $home_ -CheckOnly | Out-Null } catch { $refused = $true }
    Assert-Setup ($refused -and -not [IO.Directory]::Exists($home_)) 'Unsupported CLI version was accepted or changed files.'
    Write-SetupText $fakeCli $source
    & $setup -CopilotHome $home_ -WhatIf | Out-Null
    Assert-Setup (-not [IO.Directory]::Exists($home_)) 'Preview created a home.'

    $out = & $setup -CopilotHome $home_ -EnableGitSync | Out-String
    Assert-Setup ($out -notmatch 'Existing active hooks were kept') 'Fresh setup reported nonexistent prior hooks.'
    $backup = Backup-From $out
    Assert-Setup ([IO.File]::Exists((Join-Path $backup 'manifest.json'))) 'Setup omitted its backup.'
    $settingsPath = Join-Path $home_ 'settings.json'
    $settings = ConvertFrom-HudJson ([IO.File]::ReadAllText($settingsPath))
    Assert-Setup ($settings.experimental -eq $true -and $settings.statusLine.type -eq 'command') 'Setup did not configure the bridge and statusline.'
    Assert-Setup ([IO.File]::Exists((Join-Path $home_ 'hud-signal-bridge.json'))) 'Portable bridge opt-in missing.'
    $activeHooks = Join-Path $home_ 'hooks\session-state-hooks.json'
    Assert-Setup ([IO.File]::Exists($activeHooks)) 'Validated hooks were not enabled.'
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $signalPath = Join-Path $home_ 'state\hud-signal-bridge\hud-signal-handoff-fixture.json'
    Write-SetupText $signalPath (@{
        version=1; sessionId='handoff-fixture'; updatedAtMs=$now; phase='working'; phaseAtMs=$now
        recentIncreaseNanoAiu=2000000000; recentAtMs=$now; activeSubagentCount=0
    } | ConvertTo-Json -Compress)
    Render-Setup $settings.statusLine.command
    $settings['newPreference'] = @{ keep = $true }
    Write-SetupText $settingsPath ($settings | ConvertTo-Json -Depth 8)
    & $undo -BackupPath $backup | Out-Null
    $restored = ConvertFrom-HudJson ([IO.File]::ReadAllText($settingsPath))
    Assert-Setup ($restored.newPreference.keep -eq $true -and -not $restored.Contains('statusLine') -and
        -not $restored.Contains('experimental')) 'Undo lost later preferences or retained HUD-owned settings.'
    Assert-Setup (-not [IO.File]::Exists($activeHooks)) 'Undo retained installer-created active hooks.'
    Assert-Setup ([IO.File]::Exists($signalPath)) 'Undo deleted runtime state.'

    Write-SetupText $settingsPath '{"theme":"dark","stamp":"2026-09-30T00:00:00Z","amount":9007199254740993,"custom":{"values":[null,false,1.25]},"statusLine":{"type":"command","command":"other-hud","refreshInterval":9}}'
    $before = (Get-FileHash -LiteralPath $settingsPath).Hash
    $refused = $false
    try { & $install -CopilotHome $home_ -ConfigureStatusLine 2>&1 | Out-Null } catch { $refused = $true }
    Assert-Setup ($refused -and (Get-FileHash -LiteralPath $settingsPath).Hash -eq $before) 'Another statusline was overwritten without explicit consent.'
    $out = & $install -CopilotHome $home_ -ConfigureStatusLine -ReplaceStatusLine | Out-String
    $backup = Backup-From $out
    $doc = [CopilotHud.JsonValue]::Parse([IO.File]::ReadAllText($settingsPath))
    Assert-Setup ($doc.Get('stamp').Kind -eq 'string') 'A date-like string changed type.'
    Assert-Setup ($doc.Get('amount').Raw -ceq '9007199254740993') 'An unrelated number lost precision.'
    Assert-Setup ($doc.Get('theme').Text -ceq 'dark') 'An unrelated preference changed.'
    Assert-Setup ($doc.Get('statusLine').Get('refreshInterval').Raw -ceq '9') 'Existing refresh preference was lost.'
    & $undo -BackupPath $backup | Out-Null
    Assert-Setup ((Get-FileHash -LiteralPath $settingsPath).Hash -eq $before) 'Unchanged configured settings were not restored byte-for-byte.'

    Write-SetupText $activeHooks '{"version":1,"hooks":{"sessionStart":[{"type":"command","bash":"existing-hook"}]}}'
    $hookHash = (Get-FileHash -LiteralPath $activeHooks).Hash
    $out = & $install -CopilotHome $home_ -ConfigureStatusLine -ReplaceStatusLine -EnableHooks | Out-String
    $backup = Backup-From $out
    Assert-Setup ((Get-FileHash -LiteralPath $activeHooks).Hash -eq $hookHash) 'Existing active hooks were rewritten.'
    & $undo -BackupPath $backup | Out-Null

    Remove-Item -LiteralPath $activeHooks
    $out = & $install -CopilotHome $home_ -ConfigureStatusLine -ReplaceStatusLine -EnableHooks | Out-String
    $backup = Backup-From $out
    $hooks = ConvertFrom-HudJson ([IO.File]::ReadAllText($activeHooks))
    $hooks['addedPreference'] = 'keep'
    Write-SetupText $activeHooks ($hooks | ConvertTo-Json -Depth 12)
    & $undo -BackupPath $backup | Out-Null
    Assert-Setup ([IO.File]::Exists((Join-Path $home_ 'hooks\state-hook.ps1')) -and
        [IO.File]::Exists((Join-Path $home_ 'hooks\state-hook.sh'))) 'Edited active hooks lost their referenced handlers.'
    if ($windows) {
        $wrapperPath = Join-Path $home_ 'statusline\statusline.cmd'
        $legacyWrapper = @'
@echo off
setlocal
if not defined COPILOT_HOME for %%I in ("%~dp0..") do set "COPILOT_HOME=%%~fI"
chcp 65001 >nul
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0statusline.ps1"
exit /b %ERRORLEVEL%
'@
        Write-SetupText $wrapperPath ($legacyWrapper.Replace("`n", "`r`n") + "`r`n")
        $legacyHash = (Get-FileHash -LiteralPath $wrapperPath).Hash
        $out = & $install -CopilotHome $home_ -ConfigureStatusLine -ReplaceStatusLine | Out-String
        $backup = Backup-From $out
        Assert-Setup ((Get-FileHash -LiteralPath $wrapperPath).Hash -eq
            (Get-FileHash -LiteralPath (Join-Path $repo 'statusline\statusline.cmd')).Hash) 'Stock wrapper was not upgraded.'
        & $undo -BackupPath $backup | Out-Null
        Assert-Setup ((Get-FileHash -LiteralPath $wrapperPath).Hash -eq $legacyHash) 'Stock wrapper upgrade did not roll back exactly.'
    }
    . (Join-Path $repo 'scripts\Hud-Configuration.ps1')
    foreach ($invalid in '[]', '{bad', '{"a":1,"a":2}', (' ' * 1048577)) {
        $invalidPath = Join-Path $root 'invalid-settings.json'
        Write-SetupText $invalidPath $invalid
        $refused = $false
        try { New-HudSettingsContent -Path $invalidPath -Command 'fixture' | Out-Null } catch { $refused = $true }
        Assert-Setup $refused 'Invalid, duplicate, or oversized settings were accepted.'
    }
    $basicHome = Join-Path $root 'basic home'
    $out = & $setup -CopilotHome $basicHome -Basic -SkipHooks | Out-String
    $basicBackup = Backup-From $out $basicHome
    Assert-Setup (-not [IO.Directory]::Exists((Join-Path $basicHome 'extensions\hud-signal-bridge')) -and
        -not [IO.File]::Exists((Join-Path $basicHome 'hooks\session-state-hooks.json'))) 'Basic/SkipHooks enabled optional components.'
    $emptyBridge = Join-Path $basicHome 'extensions\hud-signal-bridge'
    [void][IO.Directory]::CreateDirectory($emptyBridge)
    & $undo -BackupPath $basicBackup -WhatIf | Out-Null
    Assert-Setup ([IO.File]::Exists((Join-Path $basicHome 'settings.json')) -and
        [IO.Directory]::Exists($emptyBridge)) 'Undo preview removed settings or directories.'
    & $undo -BackupPath $basicBackup | Out-Null
    Assert-Setup (-not [IO.File]::Exists((Join-Path $basicHome 'settings.json'))) 'Undo did not remove unedited new settings.'
    Write-SetupText (Join-Path $basicHome 'hud-signal-bridge.json') '{"version":1,"enabled":false}'
    $out = & $setup -CopilotHome $basicHome -SkipHooks | Out-String
    $basicBackup = Backup-From $out $basicHome
    $preference = [IO.File]::ReadAllText((Join-Path $basicHome 'hud-signal-bridge.json')) | ConvertFrom-Json
    Assert-Setup (-not $preference.enabled) 'Setup overwrote an existing disabled bridge preference.'
    & $undo -BackupPath $basicBackup | Out-Null

    $linkedHome = Join-Path $root 'linked home'
    $protected = Join-Path $root 'protected'
    [void][IO.Directory]::CreateDirectory($linkedHome)
    Write-SetupText (Join-Path $protected 'statusline.ps1') 'protected fixture'
    $link = Join-Path $linkedHome 'statusline'
    $linkType = if ($windows) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $linkType -Path $link -Target $protected | Out-Null
    try {
        $refused = $false
        try { & $install -CopilotHome $linkedHome -ConfigureStatusLine 2>&1 | Out-Null } catch { $refused = $true }
        Assert-Setup ($refused -and [IO.File]::ReadAllText((Join-Path $protected 'statusline.ps1')) -ceq
            'protected fixture' -and -not [IO.Directory]::Exists((Join-Path $linkedHome 'backups'))) 'A linked target directory was modified.'
    } finally { [IO.Directory]::Delete($link) }

    'TeammateSetupPass=True; preflight/preview=no changes; fresh setup=validated active hooks,config-only bridge,quoted paths'
    'Settings=unknown keys,date strings,large numbers,refresh preserved; collisions=explicit replacement; undo=later edits retained'
    'Hooks=existing config preserved; edited active config retains handlers; runtime state=untouched'
    'Safety=invalid/duplicate/oversized settings and linked directories refused; Basic/SkipHooks and disabled preferences preserved'
} finally {
    $env:PATH = $pathBefore
    if ([IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
