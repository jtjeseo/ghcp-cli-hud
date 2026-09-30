function Set-HudProcessArguments {
    param([Diagnostics.ProcessStartInfo]$Info, [string[]]$Arguments)
    if ($null -ne $Info.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $Arguments) { [void]$Info.ArgumentList.Add($argument) }
    } else {
        $quoted = foreach ($argument in $Arguments) {
            $escaped = [regex]::Replace($argument, '(\\*)"', '$1$1\"')
            $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
            '"' + $escaped + '"'
        }
        $Info.Arguments = $quoted -join ' '
    }
}

function Stop-HudProcessTree {
    param([Diagnostics.Process]$Process)
    if ($Process.HasExited) { return }
    if ($PSVersionTable.PSVersion.Major -ge 7) { $Process.Kill($true) }
    else {
        & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $Process.Id /T /F 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -and -not $Process.HasExited) { throw 'Could not terminate the HUD validation process tree.' }
    }
    if (-not $Process.WaitForExit(1000)) { throw 'HUD validation process did not terminate.' }
}
