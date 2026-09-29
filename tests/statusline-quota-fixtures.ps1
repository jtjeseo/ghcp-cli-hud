$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'statusline\statusline.ps1'
$home_ = Join-Path ([IO.Path]::GetTempPath()) ("hud-quota-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $home_ | Out-Null
function Assert-Quota($ok, $msg) { if (-not $ok) { throw $msg } }
function Render([bool]$NoColor) {
    $payload = '{"session_id":"quota-fixture","context_window":{"context_window_size":200000,"total_input_tokens":10,"total_output_tokens":5}}'
    $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($a in @('-NoProfile', '-File', $script)) { [void]$psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.Environment['COPILOT_HOME'] = $home_
    $psi.Environment['TERM'] = 'xterm-256color'
    if ($NoColor) { $psi.Environment['NO_COLOR'] = '1' } else { [void]$psi.Environment.Remove('NO_COLOR') }
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($payload); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    Assert-Quota ($p.ExitCode -eq 0) 'statusline exited nonzero'
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
try {
    Assert-Quota ((Render $false) -notmatch 'Quota') 'quota shown with no file'
    $expected = @{ 50 = '38;5;45'; 80 = '38;5;226'; 95 = '38;5;196' }
    foreach ($pct in 50, 80, 95) {
        Write-Quota $pct 0 3
        $ansi = Render $false
        Assert-Quota ($ansi -match "$($expected[$pct])m[^\r\n]*$pct%") "threshold color wrong at $pct%"
        $plain = Render $true
        Assert-Quota ($plain -match "Quota \S+ $pct% · $pct/100 · (?:● on pace|▲\+\d+%|▼-\d+%)(?: · ⚡[\d.]+k?/workday)? · [34]d left") "plain quota text wrong at $pct%"
        Assert-Quota ($plain -notmatch "`e") 'NO_COLOR emitted escapes'
    }
    Write-Quota 40 700000 3
    Assert-Quota ((Render $true) -notmatch 'Quota') 'stale quota file was shown'
    Write-Quota 0 0 0 '{not json'
    Assert-Quota ((Render $true) -notmatch 'Quota') 'malformed quota file was shown'
    Write-Quota 0 0 0 '{"updatedAt":1,"quotas":null}'
    Assert-Quota ((Render $true) -notmatch 'Quota') 'null quotas were shown'
    'Quota=hidden-when-missing/stale/malformed/null; thresholds=cyan,yellow,red; NO_COLOR=plain'
} finally {
    Remove-Item -LiteralPath $home_ -Recurse -Force -ErrorAction SilentlyContinue
}
