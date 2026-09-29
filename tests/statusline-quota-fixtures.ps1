$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'statusline\statusline.ps1'
$home_ = Join-Path ([IO.Path]::GetTempPath()) ("hud-quota-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $home_ | Out-Null
function Assert-Quota($ok, $msg) { if (-not $ok) { throw $msg } }
function Render([bool]$NoColor, [AllowNull()][string]$Payload = $null) {
    if ($null -eq $Payload) {
        $Payload = '{"session_id":"quota-fixture","context_window":{"context_window_size":200000,"total_input_tokens":10,"total_output_tokens":5}}'
    }
    $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($a in @('-NoProfile', '-File', $script)) { [void]$psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.Environment['COPILOT_HOME'] = $home_
    $psi.Environment['TERM'] = 'xterm-256color'
    if ($NoColor) { $psi.Environment['NO_COLOR'] = '1' } else { [void]$psi.Environment.Remove('NO_COLOR') }
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($Payload); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    Assert-Quota ($p.ExitCode -eq 0) "statusline exited nonzero ($($p.ExitCode)); stderr: $err; stdout: $out"
    Assert-Quota ([string]::IsNullOrWhiteSpace($err)) "statusline emitted stderr: $err"
    Assert-Quota ($out -notmatch '(?i)\b(?:error|exception|failed)\b') "statusline emitted stdout error: $out"
    return $out
}
function Write-Quota([double]$Used, [double]$AgeMs, [int]$Days, [string]$Raw) {
    $now = [DateTimeOffset]::UtcNow
    $body = if ($Raw) { $Raw } else {
        $reset = $now.AddDays($Days).ToString('o')
        '{"updatedAt":' + ($now.ToUnixTimeMilliseconds() - $AgeMs) + ',"quotas":[{"id":"a","unlimited":true,"used":0,"entitlement":-1,"resetDate":"' + $reset + '"},{"id":"b","unlimited":false,"used":' + $Used + ',"entitlement":100,"resetDate":"' + $reset + '"}]}'
    }
    [IO.File]::WriteAllText((Join-Path $home_ 'hud-quota.json'), $body)
}
function Write-SessionQuota([double]$Used) {
    $now = [DateTimeOffset]::UtcNow
    $bridgeDir = Join-Path (Join-Path $home_ 'state') 'hud-signal-bridge'
    New-Item -ItemType Directory -Path $bridgeDir -Force | Out-Null
    $body = [ordered]@{
        updatedAt = $now.ToUnixTimeMilliseconds() + 5000
        quotas = @(
            [ordered]@{
                id = 'p'
                unlimited = $false
                used = $Used
                entitlement = 35000
                resetDate = $now.AddDays(3).ToString('o')
                overage = 0
            }
        )
    } | ConvertTo-Json -Depth 4 -Compress
    [IO.File]::WriteAllText((Join-Path $bridgeDir 'hud-quota.json'), $body)
}
try {
    Assert-Quota ((Render $false) -notmatch 'Quota') 'quota shown with no file'
    $expected = @{ 50 = '38;5;45'; 80 = '38;5;226'; 95 = '38;5;196' }
    foreach ($pct in 50, 80, 95) {
        Write-Quota $pct 0 3
        $ansi = Render $false
        Assert-Quota ($ansi -match "$($expected[$pct])m[^\r\n]*$pct%") "threshold color wrong at $pct%"
        $plain = Render $true
        Assert-Quota ($plain -match "Quota \S+ $pct% · $pct/100 · (?:● on pace|▲\+\d+%|▼-\d+%)(?: · ⚡[\d.]+k?(?:/workday|/[\d.]+k? today))? · [34]d left") "plain quota text wrong at $pct%"
        Assert-Quota ($plain -notmatch "`e") 'NO_COLOR emitted escapes'
    }
    Remove-Item -LiteralPath (Join-Path $home_ 'state') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Quota 40 700000 3
    $stalePlain = Render $true
    Assert-Quota ($stalePlain -match 'Quota \S+ 40% \(11m ago\)') "stale quota was not shown with its age: $stalePlain"
    Assert-Quota (-not (Test-Path -LiteralPath (Join-Path (Join-Path $home_ 'state') 'hud-quota-day.json'))) 'stale quota wrote a day baseline'
    Write-Quota 40 (3 * 3600000) 3
    Assert-Quota ((Render $true) -match 'Quota \S+ 40% \(3h ago\)') 'hour-old quota age was wrong'
    Write-Quota 40 (3 * 86400000) 3
    Assert-Quota ((Render $true) -match 'Quota \S+ 40% \(3d ago\)') 'day-old quota age was wrong'
    Write-Quota 40 (8 * 86400000) 3
    Assert-Quota ((Render $true) -notmatch 'Quota') 'week-old quota file was shown'
    Write-Quota 40 700000 -2
    Assert-Quota ((Render $true) -notmatch 'Quota') 'stale quota from a finished period was shown'
    Write-Quota 40 0 3
    Assert-Quota ((Render $true) -notmatch 'ago\)') 'fresh quota was tagged with an age'
    Write-Quota 0 0 0 '{not json'
    Assert-Quota ((Render $true) -notmatch 'Quota') 'malformed quota file was shown'
    Write-Quota 0 0 0 '{"updatedAt":1,"quotas":null}'
    Assert-Quota ((Render $true) -notmatch 'Quota') 'null quotas were shown'
    Remove-Item -LiteralPath (Join-Path $home_ 'state') -Recurse -Force -ErrorAction SilentlyContinue
    $bridgeDir = Join-Path (Join-Path $home_ 'state') 'hud-signal-bridge'
    New-Item -ItemType Directory -Path $bridgeDir -Force | Out-Null
    $today = [DateTime]::Today.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    [IO.File]::WriteAllText((Join-Path (Join-Path $home_ 'state') 'hud-quota-day.json'),
        '{"date":"' + $today + '","startUsed":40,"budget":20}')
    Write-Quota 10 0 3
    $bridgeBody = [IO.File]::ReadAllText((Join-Path $home_ 'hud-quota.json')).Replace('"used":10,', '"used":55,')
    $bridgeBody = $bridgeBody -replace '"updatedAt":\d+', ('"updatedAt":' + ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 1000))
    [IO.File]::WriteAllText((Join-Path $bridgeDir 'hud-quota.json'), $bridgeBody)
    $plain = Render $true
    Assert-Quota ($plain -match 'Quota \S+ 55% · 55/100') 'fresher bridge quota file was not preferred'
    Assert-Quota ($plain -match '⚡15/20 today') 'daily meter did not measure spend against the fixed day budget'
    $ansi = Render $false
    Assert-Quota ($ansi -match "38;5;226m15") 'daily meter was not yellow at 75% of budget'
    $bridgeBody = $bridgeBody.Replace('"used":55,', '"used":65,')
    [IO.File]::WriteAllText((Join-Path $bridgeDir 'hud-quota.json'), $bridgeBody)
    Assert-Quota ((Render $false) -match "38;5;196m25") 'daily meter was not red over budget'
    $bridgeBody = $bridgeBody.Replace('"used":65,', '"used":5,')
    [IO.File]::WriteAllText((Join-Path $bridgeDir 'hud-quota.json'), $bridgeBody)
    Assert-Quota ((Render $true) -match '⚡0/[\d.]+ today') 'daily meter did not re-baseline after a quota reset'

    $stateDir = Join-Path $home_ 'state'
    $today = [DateTime]::Today.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    [IO.File]::WriteAllText((Join-Path $stateDir 'hud-quota-day.json'),
        '{"date":"' + $today + '","startUsed":1000,"budget":100}')

    Write-SessionQuota 1070
    $plain = Render $true '{"session_id":"s1","ai_used":{"total_nano_aiu":200000000000}}'
    Assert-Quota ($plain -match '⚡70/100 today' -and $plain -notmatch '⚡~') 'first session render was not based only on the plan counter'
    Assert-Quota ($plain -notmatch "`e") 'NO_COLOR emitted escapes for initial session estimate'

    Write-SessionQuota 1070
    $plain = Render $true '{"session_id":"s1","ai_used":{"total_nano_aiu":206860000000}}'
    Assert-Quota ($plain -match '⚡~76/100 today') 'session estimate did not include 6.86 AIU'
    Assert-Quota ($plain -notmatch "`e") 'NO_COLOR emitted escapes for growing session estimate'

    Write-SessionQuota 1070
    $plain = Render $true '{"session_id":"s1","ai_used":{"total_nano_aiu":215310000000}}'
    Assert-Quota ($plain -match '⚡~85/100 today') 'session estimate did not include 15.31 AIU'

    Write-SessionQuota 1140
    $plain = Render $true '{"session_id":"s1","ai_used":{"total_nano_aiu":220000000000}}'
    Assert-Quota ($plain -match '⚡140/100 today' -and $plain -notmatch '⚡~') 'session estimate did not reset when the plan counter moved'

    Write-SessionQuota 1140
    $plain = Render $true '{"session_id":"s1","ai_used":{"total_nano_aiu":225000000000}}'
    Assert-Quota ($plain -match '⚡~145/100 today') 'session estimate did not restart after the plan counter moved'

    $plain = Render $true '{"session_id":"s1"}'
    Assert-Quota ($plain -match '⚡140/100 today' -and $plain -notmatch '⚡~') 'payload without ai_used added a session estimate'

    $s1EstimatePath = Join-Path $stateDir 'hud-quota-est-s1.json'
    $s2EstimatePath = Join-Path $stateDir 'hud-quota-est-s2.json'
    Write-SessionQuota 1140
    $plain = Render $true '{"session_id":"s2","ai_used":{"total_nano_aiu":260000000000}}'
    Assert-Quota ($plain -match '⚡140/100 today' -and $plain -notmatch '⚡~') 'a new session reused another session estimate'
    Assert-Quota ((Test-Path -LiteralPath $s1EstimatePath -PathType Leaf) -and
        (Test-Path -LiteralPath $s2EstimatePath -PathType Leaf)) 'session estimate files were not kept separate'
    $s1Estimate = [IO.File]::ReadAllText($s1EstimatePath) | ConvertFrom-Json
    $s2Estimate = [IO.File]::ReadAllText($s2EstimatePath) | ConvertFrom-Json
    Assert-Quota ([double]$s1Estimate.plan -eq 1140 -and [double]$s1Estimate.aic -eq 220) 's1 estimate file was changed by s2'
    Assert-Quota ([double]$s2Estimate.plan -eq 1140 -and [double]$s2Estimate.aic -eq 260) 's2 estimate file did not store its own baseline'

    Write-SessionQuota 1140
    $plain = Render $true '{"session_id":"s1","ai_used":{"total_nano_aiu":210000000000}}'
    Assert-Quota ($plain -match '⚡140/100 today' -and $plain -notmatch '⚡~') 'a decreasing session counter produced an estimate'
    $s1Estimate = [IO.File]::ReadAllText($s1EstimatePath) | ConvertFrom-Json
    Assert-Quota ([double]$s1Estimate.plan -eq 1140 -and [double]$s1Estimate.aic -eq 210) 'decreasing session counter was not re-baselined'
    Write-SessionQuota 1140
    $plain = Render $true '{"session_id":"s1","ai_used":{"total_nano_aiu":212000000000}}'
    Assert-Quota ($plain -match '⚡~142/100 today') 'session estimate did not grow from the decreased counter baseline'

    $s3EstimatePath = Join-Path $stateDir 'hud-quota-est-s3.json'
    [IO.File]::WriteAllText($s3EstimatePath, '{bad')
    Write-SessionQuota 1140
    $plain = Render $true '{"session_id":"s3","ai_used":{"total_nano_aiu":300000000000}}'
    Assert-Quota ($plain -match '⚡140/100 today' -and $plain -notmatch '⚡~') 'malformed session estimate file did not recover cleanly'
    Assert-Quota ($plain -notmatch "`e") 'NO_COLOR emitted escapes while recovering a malformed estimate file'
    $s3Estimate = [IO.File]::ReadAllText($s3EstimatePath) | ConvertFrom-Json
    Assert-Quota ([double]$s3Estimate.plan -eq 1140 -and [double]$s3Estimate.aic -eq 300) 'malformed session estimate file was not re-baselined'

    'SessionEstimate=plan-move-reset,growth,no-ai,sessions-isolated,counter-decrease-rebaseline,malformed-recovery,NO_COLOR,no-errors'
    'DayMeter=bridge-preferred,fixed-budget,yellow,red,reset-rebaseline'
    'Quota=hidden-when-missing/week-old/past-period/malformed/null; stale=aged-tag,read-only-baseline; thresholds=cyan,yellow,red; NO_COLOR=plain'
} finally {
    Remove-Item -LiteralPath $home_ -Recurse -Force -ErrorAction SilentlyContinue
}
