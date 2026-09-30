function Test-HudHookHandlers {
    param([string]$RepositoryRoot)
    . (Join-Path $PSScriptRoot 'Hud-Process.ps1')
    $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('hud-hook-check-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($sandbox)
    $windows = [IO.Path]::DirectorySeparatorChar -eq '\'
    $program = if ($windows) { (Get-Command powershell.exe -ErrorAction Stop).Source } else { '/bin/bash' }
    $name = if ($windows) { 'state-hook.ps1' } else { 'state-hook.sh' }
    $handler = Join-Path $sandbox $name
    $source = Join-Path (Join-Path $RepositoryRoot 'hooks') $name
    [IO.File]::WriteAllBytes($handler, [IO.File]::ReadAllBytes($source))
    $sessionId = 'hud-handoff-' + [guid]::NewGuid().ToString('N')
    $probes = @(
        @{ Event='sessionStart'; Payload=(@{sessionId=$sessionId; timestamp=0; cwd=''} | ConvertTo-Json -Compress) },
        @{ Event='preToolUse'; Payload=(@{sessionId=$sessionId; toolName='view'; toolArgs=@{path='probe.txt'}} | ConvertTo-Json -Compress) },
        @{ Event='preToolUse'; Payload='{malformed' },
        @{ Event='preToolUse'; Payload='' },
        @{ Event='preToolUse'; Payload=(@{sessionId=$sessionId; toolName='unexpected'; toolArgs=$null} | ConvertTo-Json -Compress) }
    )
    try {
        for ($index = 0; $index -lt $probes.Count; $index++) {
            $probe = $probes[$index]
            $info = [Diagnostics.ProcessStartInfo]::new($program)
            $arguments = if ($windows) { @('-NoProfile', '-NonInteractive', '-File', $handler, '-Event', $probe.Event) }
                else { @($handler, $probe.Event) }
            Set-HudProcessArguments $info $arguments
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardInput = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $info.Environment['COPILOT_HOME'] = $sandbox
            $info.Environment['COPILOT_RAW_PAYLOAD_CAPTURE'] = '0'
            if ($windows) { [void]$info.Environment.Remove('PSExecutionPolicyPreference') }
            $process = [Diagnostics.Process]::Start($info)
            try {
                $output = $process.StandardOutput.ReadToEndAsync()
                $errors = $process.StandardError.ReadToEndAsync()
                $process.StandardInput.Write($probe.Payload)
                $process.StandardInput.Close()
                if (-not $process.WaitForExit(5000)) {
                    Stop-HudProcessTree $process
                    throw 'Hook validation timed out; no hook configuration was enabled.'
                }
                if ($process.ExitCode -ne 0 -or $output.GetAwaiter().GetResult().Length -gt 0 -or
                    $errors.GetAwaiter().GetResult().Length -gt 0) {
                    throw 'Hook validation was not silent and fail-open. Check native script policy, or use -SkipHooks; no hooks were enabled.'
                }
                if ($index -le 1) {
                    $state = Join-Path $sandbox "state\hud-state-$sessionId.json"
                    if (-not [IO.File]::Exists($state)) { throw 'Hook validation produced no valid telemetry.' }
                    $record = [IO.File]::ReadAllText($state) | ConvertFrom-Json
                    if ($record.sessionId -cne $sessionId -or @($record.activeTools).Count -ne $index) {
                        throw 'Hook validation produced unexpected telemetry.'
                    }
                }
            } finally { $process.Dispose() }
        }
    } finally {
        if ([IO.Directory]::Exists($sandbox)) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
    }
}
