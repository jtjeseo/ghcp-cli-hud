#requires -Version 5.1
$ErrorActionPreference = 'Stop'
if ([IO.Path]::DirectorySeparatorChar -ne '\') { throw 'This fixture requires Windows.' }
. (Join-Path $PSScriptRoot 'Hud-FixtureHelpers.ps1')
$engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$renderer = Join-Path (Split-Path -Parent $PSScriptRoot) 'statusline\statusline.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ("hud-native51-" + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
function Assert-Native([bool]$Ok, [string]$Message) { if (-not $Ok) { throw $Message } }
function Render-Native([string]$Payload) {
    $info = [Diagnostics.ProcessStartInfo]::new($engine)
    Set-HudProcessArguments $info @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $renderer)
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $info.Environment['COPILOT_HOME'] = $root
    $info.Environment['PATH'] = ''
    $info.Environment['TERM'] = 'xterm-256color'
    [void]$info.Environment.Remove('NO_COLOR')
    $process = [Diagnostics.Process]::Start($info)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($Payload)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(10000)) { Stop-HudProcessTree $process; throw 'Native renderer timed out.' }
        $text = $output.GetAwaiter().GetResult()
        $errorText = $errors.GetAwaiter().GetResult()
        Assert-Native ($process.ExitCode -eq 0 -and $errorText.Length -eq 0) ("Native renderer failed: exit=" + $process.ExitCode + "; stderr=" + $errorText)
        return $text
    } finally { $process.Dispose() }
}
try {
    $colors = @{ 50 = 45; 80 = 226; 95 = 196 }
    foreach ($width in 80, 120, 160) {
        foreach ($percent in 50, 80, 95) {
            $payload = @{
                session_id = 'native51-fixture'; terminal_width = $width
                model = @{ display_name = 'fixture-model' }
                context_window = @{
                    last_call_input_tokens = $percent * 2000; context_window_size = 200000
                    total_input_tokens = 100000; total_output_tokens = 8000
                    total_cache_read_tokens = 2000; total_cache_write_tokens = 200
                }
            } | ConvertTo-Json -Depth 4 -Compress
            $text = Render-Native $payload
            $plain = [regex]::Replace($text, '\x1B\[[0-?]*[ -/]*[@-~]', '')
            Assert-Native ($text.Contains([string][char]0x2588) -and
                ($percent -eq 95 -or $text.Contains([string][char]0x2591))) 'Unicode gauge was corrupted.'
            Assert-Native ($text -match ("38;5;" + $colors[$percent] + 'm[^\r\n]*' + $percent + '%')) 'Context threshold color is wrong.'
            Assert-Native (@($plain -split "`r?`n" | Where-Object { $_.Length -gt $width }).Count -eq 0) 'Native HUD exceeded its width.'
            Assert-Native ($plain -match 'C 2.2k') 'Native cache sum changed.'
        }
    }
    foreach ($payload in '{}', 'null', '{"model":null,"context_window":null}', '{bad', '') {
        $text = Render-Native $payload
        Assert-Native ($text -notmatch '(?i)exception|failed|error') 'Missing or malformed payload leaked an error.'
    }
    $dictionary = ConvertFrom-HudJson '{"Array":[null,[],[1,2]],"Case":1,"case":2}'
    Assert-Native ($dictionary.Count -eq 3 -and $dictionary['Case'] -eq 1 -and $dictionary['case'] -eq 2) 'JSON key case was lost.'
    Assert-Native ($dictionary.Array.Count -eq 3 -and $null -eq $dictionary.Array[0] -and
        $dictionary.Array[1].Count -eq 0 -and $dictionary.Array[2].Count -eq 2) 'JSON arrays were flattened.'
    'NativePowerShell51Pass=True; pwsh absent from child PATH; widths=80,120,160; ctx=50/80/95; Unicode/cache/null/malformed preserved'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
