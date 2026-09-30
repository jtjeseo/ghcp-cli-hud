param(
    [switch]$Worker,
    [string]$WorkerHome,
    [string]$WorkerId,
    [double]$WorkerAic
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Hud-FixtureHelpers.ps1')
$renderer = Join-Path (Split-Path -Parent $PSScriptRoot) 'statusline\statusline.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($renderer, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Renderer did not parse.' }
$names = @(
    'Get-FirstValue', 'ConvertTo-NullableNumber', 'Test-HudSignalInteger',
    'Write-QuotaEstimateWarning', 'Test-LegacyQuotaEstimateRecord',
    'Test-QuotaEstimateLedger', 'Read-QuotaEstimateRecord', 'Get-QuotaAccountEstimate',
    'Write-QuotaEstimateRecord', 'Merge-QuotaPendingEstimates',
    'Test-QuotaPendingEstimateRecord', 'Write-QuotaPendingEstimate',
    'Test-QuotaEstimateCheckpointAhead',
    'Remove-ExpiredQuotaPendingEstimates',
    'Get-QuotaDayBaseline', 'Get-QuotaDayBaselineCore'
)
foreach ($definition in $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    if ($definition.Name -in $names) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
function Estimate {
    param(
        [string]$CopilotHome, [string]$Id, [AllowNull()][object]$Aic,
        [double]$Plan = 1000, [double]$Stamp = 1000,
        [string]$Period = '2026-10-01', [double]$Limit = 35000,
        [DateTime]$Date = [DateTime]::Today
    )
    $payload = @{ session_id = $Id }
    if ($null -ne $Aic) { $payload.ai_used = @{ total_nano_aiu = [long]([double]$Aic * 1e9) } }
    Get-QuotaAccountEstimate -CopilotHome $CopilotHome -Payload $payload -Used $Plan `
        -Entitlement $Limit -Period $Period -SnapshotAt $Stamp -Today $Date
}
if ($Worker) {
    Estimate -CopilotHome $WorkerHome -Id $WorkerId -Aic $WorkerAic | ConvertTo-Json -Compress
    exit 0
}
function Assert-Shared([bool]$Ok, [string]$Message) { if (-not $Ok) { throw $Message } }
function Check([object]$Result, [double]$Amount, [bool]$Complete = $true) {
    Assert-Shared ([math]::Abs($Result.Amount - $Amount) -lt 0.000001) `
        "Wrong shared amount: expected $Amount, got $($Result.Amount)"
    Assert-Shared ($Result.Complete -eq $Complete) 'Wrong shared estimate completeness.'
}
function Start-Worker([string]$CopilotHome, [string]$Id, [double]$Aic) {
    $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    Set-HudProcessArguments $psi @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Worker',
        '-WorkerHome', $CopilotHome, '-WorkerId', $Id, '-WorkerAic',
        $Aic.ToString([Globalization.CultureInfo]::InvariantCulture))
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    return [Diagnostics.Process]::Start($psi)
}
function Finish-Worker([Diagnostics.Process]$Process) {
    try {
        if (-not $Process.WaitForExit(10000)) {
            Stop-Process -Id $Process.Id -Force
            throw 'Shared estimate worker timed out.'
        }
        $output = $Process.StandardOutput.ReadToEnd()
        $stderr = $Process.StandardError.ReadToEnd()
        Assert-Shared ($Process.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($stderr)) `
            'Shared estimate worker failed or emitted stderr.'
        return ($output | ConvertFrom-Json)
    } finally { $Process.Dispose() }
}
$home_ = Join-Path ([IO.Path]::GetTempPath()) ('hud-quota-shared-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($home_)
try {
    $state = Join-Path $home_ 'state'
    $path = Join-Path $state 'hud-quota-estimates.json'
    Check (Estimate $home_ 'a' 100) 0
    Check (Estimate $home_ 'b' 200) 0
    Check (Estimate $home_ 'a' 110) 10
    Check (Estimate $home_ 'b' 207) 17
    Check (Estimate $home_ 'a' 110) 17
    Check (Estimate $home_ 'b' $null) 17
    Check (Estimate $home_ 'c' 900) 17
    Check (Estimate $home_ 'a' 105) 17
    Check (Estimate $home_ 'a' 110) 17
    Check (Estimate $home_ 'a' 112) 19
    Check (Estimate $home_ 'b' 210 -Plan 1070 -Stamp 2000) 0
    $ledger = Read-QuotaEstimateRecord $path
    Assert-Shared ($ledger.sessions.Count -eq 1 -and $ledger.sessions.Contains('b')) `
        'Plan movement did not retire all previous session contributions.'
    $before = (Get-FileHash $path).Hash
    $stale = Estimate $home_ 'a' 113 -Plan 1000 -Stamp 1000
    Check $stale 0 $false
    Assert-Shared (-not $stale.Accepted -and (Get-FileHash $path).Hash -ceq $before) `
        'An older quota snapshot rewound the shared checkpoint.'
    $hold = [IO.File]::Open("$path.lock", [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $stale = Estimate $home_ 'a' 113 -Plan 1000 -Stamp 1000
        Check $stale 0 $false
        Assert-Shared (-not $stale.Accepted) 'A contended render accepted an older plan checkpoint.'
    } finally { $hold.Dispose() }
    Check (Estimate $home_ 'a' 113 -Plan 1070 -Stamp 2000) 0
    Check (Estimate $home_ 'a' 115 -Plan 1070 -Stamp 2000) 2
    Check (Estimate $home_ 'b' 214 -Plan 1070 -Stamp 2000) 6
    Check (Estimate $home_ 'b' 215 -Plan 1000 -Stamp 3000) 0
    Check (Estimate $home_ 'a' 116 -Plan 1000 -Stamp 3000) 0
    $oldEpoch = $ledger.epoch
    $dateText = [DateTime]::Today.ToString('yyyy-MM-dd')
    [IO.File]::WriteAllText((Join-Path $state "hud-quota-pending-$dateText-a.json"),
        (@{ version = 1; epoch = $oldEpoch; nano = 900000000000 } | ConvertTo-Json -Compress))
    Check (Estimate $home_ 'b' 217 -Plan 1000 -Stamp 3000) 2
    Check (Estimate $home_ 'b' 218 -Stamp 4000 -Period '2026-11-01') 0
    Check (Estimate $home_ 'b' 219 -Stamp 4000 -Period '2026-11-01') 1
    Check (Estimate $home_ 'b' 220 -Stamp 5000 -Period '2026-11-01' -Limit 70000) 0
    Check (Estimate $home_ 'b' 221 -Stamp 5000 -Period '2026-11-01' -Limit 70000) 1
    $tomorrow = [DateTime]::Today.AddDays(1)
    Check (Estimate $home_ 'b' 222 -Stamp 5000 -Period '2026-11-01' -Limit 70000 -Date $tomorrow) 0
    Check (Estimate $home_ 'b' 224 -Stamp 5000 -Period '2026-11-01' -Limit 70000 -Date $tomorrow) 2
    $before = (Get-FileHash $path).Hash
    $olderDay = Estimate $home_ 'b' 225 -Stamp 5000 -Period '2026-11-01' -Limit 70000
    Check $olderDay 0 $false
    Assert-Shared (-not $olderDay.Accepted -and (Get-FileHash $path).Hash -ceq $before) `
        'A delayed render rewound the local day checkpoint.'
    $hold = [IO.File]::Open("$path.lock", [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $olderDay = Estimate $home_ 'b' 225 -Stamp 5000 -Period '2026-11-01' -Limit 70000
        Assert-Shared (-not $olderDay.Accepted) 'A contended render accepted an older day checkpoint.'
    } finally { $hold.Dispose() }

    Remove-Item -LiteralPath $path
    $legacyPath = Join-Path $state 'hud-quota-est-a.json'
    [IO.File]::WriteAllText($legacyPath, '{"plan":1000,"aic":100}')
    Check (Estimate $home_ 'a' 106.86) 6.86
    Assert-Shared ([IO.File]::ReadAllText($legacyPath) -ceq '{"plan":1000,"aic":100}') `
        'Legacy migration modified rollback state.'
    Check (Estimate $home_ 'b' 200) 6.86
    Check (Estimate $home_ 'a' 110 -Plan 1070 -Stamp 2000) 0
    Check (Estimate $home_ 'a' 112 -Plan 1000 -Stamp 3000) 0
    Remove-Item -LiteralPath $path
    [IO.File]::SetLastWriteTime($legacyPath, [DateTime]::Today.AddDays(-1))
    Check (Estimate $home_ 'a' 120) 0

    $hold = [IO.File]::Open("$path.lock", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Check (Estimate $home_ 'a' 125) 5 $false
        Assert-Shared ($clock.ElapsedMilliseconds -lt 1000) 'A contended estimate waited on the render path.'
        Check (Estimate $home_ 'a' 123) 5 $false
        $child = Start-Worker $home_ 'a' 125
        Check (Finish-Worker $child) 5 $false
    } finally { $hold.Dispose() }
    Check (Estimate $home_ 'observer' $null) 5
    Check (Estimate $home_ 'a' 125) 5
    Check (Estimate $home_ 'b' 200) 5
    $first = Start-Worker $home_ 'a' 130
    $second = Start-Worker $home_ 'b' 207
    [void](Finish-Worker $first)
    [void](Finish-Worker $second)
    Check (Estimate $home_ 'a' 130) 17
    Check (Estimate $home_ 'b' 207) 17
    Check (Estimate $home_ 'a' 130) 17
    Assert-Shared ((Read-QuotaEstimateRecord $path).sessions.Count -eq 2) 'Concurrent updates lost a terminal.'
    $before = (Get-FileHash $path).Hash
    $hold = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Check (Estimate $home_ 'a' 131) 0 $false } finally { $hold.Dispose() }
    Assert-Shared ((Get-FileHash $path).Hash -ceq $before) 'A locked ledger was destroyed.'
    Check (Estimate $home_ 'a' 131) 18
    Assert-Shared (@(Get-ChildItem $state -Filter 'hud-quota-estimates.json.*.tmp').Count -eq 0) `
        'A failed replacement left a temporary file.'
    [IO.File]::WriteAllText($path, '{bad')
    Check (Estimate $home_ 'a' 132) 0 $false
    Check (Estimate $home_ 'a' 133) 1 $false
    Check (Estimate $home_ 'a' 134) 2 $false
    Check (Estimate $home_ 'a' 135 -Plan 1070 -Stamp 2000) 0
    [IO.File]::WriteAllText($path, ('x' * 65537))
    Check (Estimate $home_ 'a' 136 -Plan 1070 -Stamp 2000) 0 $false
    Assert-Shared ((Get-Item $path).Length -le 65536) 'Recovery did not restore the ledger size bound.'
    Check (Estimate $home_ 'a' 137 -Plan 1140 -Stamp 3000) 0
    $ledger = Read-QuotaEstimateRecord $path
    $ledger.sessions = @{}
    foreach ($index in 1..64) { $ledger.sessions["bounded-$index"] = @{ aic = 0; latestAic = 1 } }
    [IO.File]::WriteAllText($path, ($ledger | ConvertTo-Json -Depth 5 -Compress))
    Check (Estimate $home_ 'overflow' 100 -Plan 1140 -Stamp 3000) 64 $false
    Assert-Shared ((Read-QuotaEstimateRecord $path).sessions.Count -eq 64) 'The participant cap was exceeded.'
    Check (Estimate $home_ 'overflow' 101 -Plan 1210 -Stamp 4000) 0
    $bad = Get-QuotaAccountEstimate -CopilotHome $home_ `
        -Payload @{ session_id = '..\unsafe'; ai_used = @{ total_nano_aiu = 1 } } `
        -Used 1210 -Entitlement 35000 -Period '2026-10-01' -SnapshotAt 4000
    Check $bad 0 $false
    $warning = [IO.File]::ReadAllText((Join-Path $state 'hud-quota-estimate-warning.log'))
    Assert-Shared ($warning -ceq 'state-unavailable') 'Diagnostic marker exposed input instead of a fixed category.'
    Remove-Item -LiteralPath $path
    [void][IO.Directory]::CreateDirectory($path)
    Check (Estimate $home_ 'a' 140) 0 $false
    Remove-Item -LiteralPath $path

    $mailHome = Join-Path $home_ 'mailbox-case'
    Check (Estimate $mailHome 'a' 100) 0
    Check (Estimate $mailHome 'b' 200) 0
    Check (Estimate $mailHome 'a' 110) 10
    $mailState = Join-Path $mailHome 'state'
    $dateText = [DateTime]::Today.ToString('yyyy-MM-dd')
    $pendingPath = Join-Path $mailState "hud-quota-pending-$dateText-a.json"
    [IO.File]::WriteAllText($pendingPath, '{bad')
    Check (Estimate $mailHome 'b' 200) 10 $false
    Check (Estimate $mailHome 'b' 201 -Plan 1070 -Stamp 2000) 0
    Check (Estimate $mailHome 'a' 112 -Plan 1070 -Stamp 2000) 0
    Check (Estimate $mailHome 'a' 113 -Plan 1070 -Stamp 2000) 1
    $pendingLock = [IO.File]::Open("$pendingPath.lock", [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Check (Estimate $mailHome 'a' 114 -Plan 1070 -Stamp 2000) 2 $false
        Assert-Shared ($clock.ElapsedMilliseconds -lt 1000) 'A contended inbox waited on the render path.'
    } finally { $pendingLock.Dispose() }
    Check (Estimate $mailHome 'b' 201 -Plan 1070 -Stamp 2000) 2
    $oldDate = [DateTime]::Today.AddDays(-4).ToString('yyyy-MM-dd')
    $oldPending = Join-Path $mailState "hud-quota-pending-$oldDate-old-session.json"
    $unrelated = Join-Path $mailState 'unrelated.json'
    [IO.File]::WriteAllText($oldPending, '{}')
    [IO.File]::WriteAllText("$oldPending.lock", '')
    [IO.File]::WriteAllText($unrelated, 'keep')
    Check (Estimate $mailHome 'a' 114 -Plan 1070 -Stamp 2000) 2
    Assert-Shared (-not [IO.File]::Exists($oldPending) -and -not [IO.File]::Exists("$oldPending.lock") -and
        [IO.File]::ReadAllText($unrelated) -ceq 'keep') 'Mailbox cleanup affected unrelated state.'

    $baseline = Get-QuotaDayBaseline -CopilotHome $home_ -Used 1000 -Budget 500
    Assert-Shared ($baseline.startUsed -eq 1000 -and $baseline.budget -eq 500) 'Daily baseline was not captured.'
    $dayLock = [IO.File]::Open((Join-Path $state 'hud-quota-day.json.lock'),
        [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $blocked = Get-QuotaDayBaseline -CopilotHome $home_ -Used 1070 -Budget 999
        Assert-Shared ($blocked.startUsed -eq 1000 -and $blocked.budget -eq 500) `
            'A contended daily baseline lost the existing fixed budget.'
    } finally { $dayLock.Dispose() }
    'SharedQuotaPass=True; two-terminals=consistent; repeated/regressed-samples=deduplicated'
    'Reconciliation=plan-move,reset-return-to-old-count,older-snapshot-rejected,period,entitlement,local-day'
    'Storage=atomic,64-sessions,64KiB,non-waiting-contention,durable-inboxes,closed-terminal-drain,explicit-partial-recovery,legacy-migration'
} finally {
    Remove-Item -LiteralPath $home_ -Recurse -Force
}
