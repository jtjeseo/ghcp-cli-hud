$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$renderer = Join-Path $repo 'statusline\statusline.ps1'
$root = Join-Path $env:TEMP ('hud-git-render-' + [guid]::NewGuid().ToString('N'))
$home_ = Join-Path $root 'home'
$workspace = Join-Path $root 'workspace'
$gitDirectory = Join-Path $workspace '.git'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($renderer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Renderer did not parse.' }
foreach ($definition in $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    if ($definition.Name -in @('Get-GitSyncHash', 'Get-GitDirectoryKey')) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}
function Assert-Git([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Write-Json([string]$Path, [object]$Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 4 -Compress))
}
function Render([int]$Width = 120, [bool]$NoColor = $true, [string]$Cwd = $workspace) {
    $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($argument in @('-NoProfile', '-File', $renderer)) { [void]$info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $info.Environment['COPILOT_HOME'] = $home_
    $info.Environment['TERM'] = 'xterm-256color'
    # A render must not invoke Git or start a network updater.
    $info.Environment['PATH'] = ''
    if ($NoColor) { $info.Environment['NO_COLOR'] = '1' }
    else { [void]$info.Environment.Remove('NO_COLOR') }
    $payload = @{
        cwd = $Cwd; terminal_width = $Width
        context_window = @{ last_call_input_tokens = 45000; context_window_size = 200000 }
    } | ConvertTo-Json -Compress
    $process = [Diagnostics.Process]::Start($info)
    try {
        $process.StandardInput.Write($payload)
        $process.StandardInput.Close()
        $output = $process.StandardOutput.ReadToEnd()
        $errorText = $process.StandardError.ReadToEnd()
        [void]$process.WaitForExit(10000)
        Assert-Git ($process.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($errorText)) `
            'Git renderer failed or emitted stderr.'
        $plain = [regex]::Replace($output, '\x1B\[[0-?]*[ -/]*[@-~]', '')
        Assert-Git (@($plain -split "`r?`n" | Where-Object { $_.Length -gt $Width }).Count -eq 0) `
            "Git renderer wrapped at width $Width."
        if ($NoColor) { Assert-Git (-not $output.Contains([string][char]27)) 'NO_COLOR emitted escapes.' }
        return $output
    } finally { $process.Dispose() }
}
function Snapshot([double]$Ahead = 0, [double]$Behind = 0) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    return @{
        version = 1; repositoryKey = $key; branchKey = Get-GitSyncHash 'main'
        updatedAt = $now; status = 'ok'; ahead = $Ahead; behind = $Behind
        fetchedAt = $now; fetchStatus = 'ok'
    }
}
try {
    [void][IO.Directory]::CreateDirectory($gitDirectory)
    $state = Join-Path (Join-Path $home_ 'state') 'hud-git-sync'
    [void][IO.Directory]::CreateDirectory($state)
    [IO.File]::WriteAllText((Join-Path $gitDirectory 'HEAD'), "ref: refs/heads/main`n")
    $key = Get-GitDirectoryKey $gitDirectory
    $nodeKey = & node --input-type=module -e `
        'import {gitDirectoryKey} from "./.github/extensions/hud-signal-bridge/git-sync.mjs"; process.stdout.write(gitDirectoryKey(process.argv[1]));' `
        $gitDirectory
    Assert-Git ($LASTEXITCODE -eq 0 -and $nodeKey -ceq $key) 'Node/PowerShell worktree keys do not match.'
    $optionsPath = Join-Path $home_ 'hud-git-sync.json'
    $snapshotPath = Join-Path $state "hud-git-$key.json"
    Assert-Git ((Render) -match '⎇ main' -and (Render) -notmatch 'sync') 'Absent opt-in changed branch-only behavior.'
    Write-Json $optionsPath @{ version = 1; enabled = $false }
    Write-Json $snapshotPath (Snapshot 2 3)
    Assert-Git ((Render) -notmatch '↓|↑|sync') 'Disabled opt-in consumed cached arrows.'
    Write-Json $optionsPath @{ version = 1; enabled = $true }
    foreach ($counts in @(@(0, 0), @(2, 0), @(0, 3), @(2, 3))) {
        Write-Json $snapshotPath (Snapshot $counts[0] $counts[1])
        foreach ($width in 80, 120, 160) {
            foreach ($noColor in $true, $false) {
                $output = Render $width $noColor
                $plain = [regex]::Replace($output, '\x1B\[[0-?]*[ -/]*[@-~]', '')
                Assert-Git ($plain -match '⎇ main') 'Unicode branch marker disappeared.'
                Assert-Git (($plain -match '↑2') -eq ($counts[0] -gt 0)) 'Outgoing count is wrong.'
                Assert-Git (($plain -match '↓3') -eq ($counts[1] -gt 0)) 'Incoming count is wrong.'
                Assert-Git ($plain -notmatch '↑0|↓0') 'Zero sync counts were displayed.'
            }
        }
    }
    Write-Json $snapshotPath (Snapshot 2 3)
    $ansi = Render 120 $false
    Assert-Git ($ansi -match '38;5;244m⎇') 'Branch icon is not dim.'
    Assert-Git ($ansi -match '38;5;226m↓3') 'Diverged incoming count is not yellow.'
    Write-Json $snapshotPath (Snapshot 0 3)
    Assert-Git ((Render 120 $false) -match '38;5;45m↓3') 'Incoming-only count is not cyan.'
    $data = Snapshot 2 3
    $data.fetchedAt -= 12 * 60000
    $data.fetchStatus = 'unavailable'
    Write-Json $snapshotPath $data
    $plain = Render
    Assert-Git ($plain -match '↓3 ↑2 \(fetch unavailable\) \(12m ago\)') `
        'Failed fetch discarded known counts or last-success age.'
    $data = Snapshot
    $data.updatedAt -= 3 * 60000
    $data.fetchedAt = $data.updatedAt
    Write-Json $snapshotPath $data
    Assert-Git ((Render) -match '\(3m ago\)') 'Stopped updater falsely showed fresh zero counts.'
    foreach ($status in 'no-upstream', 'unborn', 'unavailable') {
        $data = Snapshot
        $data.status = $status; $data.ahead = $null; $data.behind = $null
        $data.fetchedAt = $null; $data.fetchStatus = 'not-needed'
        Write-Json $snapshotPath $data
        $expected = switch ($status) { 'no-upstream' { 'no upstream' }; 'unborn' { 'no commits' }; default { 'sync unavailable' } }
        Assert-Git ((Render) -match [regex]::Escape($expected)) "Wrong state label for $status."
    }
    $data = Snapshot 999 999
    $data.branchKey = Get-GitSyncHash 'other-branch'
    Write-Json $snapshotPath $data
    Assert-Git ((Render) -match 'sync pending' -and (Render) -notmatch '999') 'Foreign branch counts leaked.'
    $data = Snapshot 999 999
    $data.repositoryKey = 'a' * 64
    Write-Json $snapshotPath $data
    Assert-Git ((Render) -match 'sync pending' -and (Render) -notmatch '999') 'Foreign repository counts leaked.'
    foreach ($raw in '{bad', ('x' * 4097)) {
        [IO.File]::WriteAllText($snapshotPath, $raw)
        Assert-Git ((Render) -match 'sync unavailable') 'Malformed cache appeared synchronized.'
    }
    $data = Snapshot
    $data.updatedAt += 60000
    Write-Json $snapshotPath $data
    Assert-Git ((Render) -match 'sync unavailable') 'Future-dated cache appeared synchronized.'
    [IO.File]::WriteAllText((Join-Path $gitDirectory 'HEAD'), ('a' * 40))
    Assert-Git ((Render) -match '⎇ detached' -and (Render) -notmatch '↓|↑') 'Detached HEAD showed sync arrows.'
    [IO.File]::WriteAllText((Join-Path $gitDirectory 'HEAD'), "ref: refs/heads/detached`n")
    $data = Snapshot 2 3
    $data.branchKey = Get-GitSyncHash 'detached'
    Write-Json $snapshotPath $data
    Assert-Git ((Render) -match '⎇ detached ↓3 ↑2') 'A branch named detached was mistaken for detached HEAD.'
    [IO.File]::WriteAllText((Join-Path $gitDirectory 'HEAD'), "ref: refs/heads/main`n")
    Write-Json $snapshotPath (Snapshot 2 3)
    $before = (Get-FileHash -LiteralPath $snapshotPath).Hash
    [void](Render)
    Assert-Git ((Get-FileHash -LiteralPath $snapshotPath).Hash -ceq $before) 'Renderer wrote the Git cache.'
    [void](Render 40)
    $noRepo = Join-Path $root 'no-repository'
    [void][IO.Directory]::CreateDirectory($noRepo)
    Assert-Git ((Render 120 $true $noRepo) -notmatch '⎇|↓|↑') 'Non-repository inherited process-cwd branch.'
    $warningPath = Join-Path (Join-Path $home_ 'state') 'hud-git-sync-warning.log'
    Assert-Git ([IO.File]::ReadAllText($warningPath) -ceq 'state-unavailable') 'Git diagnostics exposed raw data.'
    'GitRendererPass=True; icon=dim-Unicode; ahead/behind/diverged/zero=correct'
    'Widths=80,120,160; ANSI/NO_COLOR=passed; narrow=whole-segment-drop; renderer=read-only,no-Git-PATH'
    'States=no-upstream,unborn,detached,failed-fetch,stale,foreign-cache,malformed,future,non-repository'
} finally {
    if ([IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
