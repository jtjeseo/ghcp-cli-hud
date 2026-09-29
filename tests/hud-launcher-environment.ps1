$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\Invoke-ScopedProcessEnvironment.ps1')

$tokenNames = @(
    'COPILOT_GITHUB_TOKEN',
    'GITHUB_COPILOT_GITHUB_TOKEN',
    'GITHUB_COPILOT_AGENT_GITHUB_TOKEN',
    'GH_ENTERPRISE_TOKEN',
    'GITHUB_ENTERPRISE_TOKEN',
    'GH_TOKEN',
    'GITHUB_TOKEN',
    'COPILOT_TOKEN'
)
$names = @(
    'COPILOT_HOME',
    'COPILOT_HUD_SIGNAL_BRIDGE',
    'COPILOT_HUD_SIGNAL_DIAGNOSTICS',
    'COPILOT_HUD_AIC_VALIDATION',
    'COPILOT_RAW_PAYLOAD_CAPTURE',
    'GH_CONFIG_DIR'
) + $tokenNames
$original = @{}
foreach ($name in $names) {
    $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, "original-$name", 'Process')
}

function Assert-EnvironmentRestored {
    param([System.Collections.IDictionary]$Expected)

    foreach ($name in $names) {
        if ([Environment]::GetEnvironmentVariable($name, 'Process') -cne $Expected[$name]) {
            throw "Environment variable $name was not restored."
        }
    }
}

function Assert-ChildCopilotHome {
    param([string]$Expected)

    $tokenProbe = @'
$tokenNames = @(
    'COPILOT_GITHUB_TOKEN',
    'GITHUB_COPILOT_GITHUB_TOKEN',
    'GITHUB_COPILOT_AGENT_GITHUB_TOKEN',
    'GH_ENTERPRISE_TOKEN',
    'GITHUB_ENTERPRISE_TOKEN',
    'GH_TOKEN',
    'GITHUB_TOKEN',
    'COPILOT_TOKEN'
)
$leaked = @($tokenNames | Where-Object {
    $null -ne [Environment]::GetEnvironmentVariable($_, 'Process')
}).Count -gt 0
if ($leaked) {
    [Console]::Write('token-isolation-failed')
} else {
    [Console]::Write([Environment]::GetEnvironmentVariable('COPILOT_HOME', 'Process'))
}
'@
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new(
        (Get-Command powershell.exe -ErrorAction Stop).Source
    )
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $encodedProbe = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($tokenProbe)
    )
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' +
        $encodedProbe

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    try {
        if (-not $process.WaitForExit(5000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw 'The isolated observer environment fixture timed out.'
        }
        $childHome = $process.StandardOutput.ReadToEnd()
        $childError = $process.StandardError.ReadToEnd()
        if ($process.ExitCode -ne 0 -or
            $childHome.Trim() -cne $Expected -or
            -not [string]::IsNullOrEmpty($childError)) {
            throw 'The child observer did not inherit the isolated environment.'
        }
    } finally {
        $process.Dispose()
    }
}

$scopedEnvironment = @{
    COPILOT_HOME = 'isolated-home'
    COPILOT_HUD_SIGNAL_BRIDGE = '1'
    COPILOT_HUD_SIGNAL_DIAGNOSTICS = '0'
    COPILOT_HUD_AIC_VALIDATION = '1'
    COPILOT_RAW_PAYLOAD_CAPTURE = '0'
    GH_CONFIG_DIR = 'isolated-gh-config'
    COPILOT_GITHUB_TOKEN = $null
    GITHUB_COPILOT_GITHUB_TOKEN = $null
    GITHUB_COPILOT_AGENT_GITHUB_TOKEN = $null
    GH_ENTERPRISE_TOKEN = $null
    GITHUB_ENTERPRISE_TOKEN = $null
    GH_TOKEN = $null
    GITHUB_TOKEN = $null
    COPILOT_TOKEN = $null
}
$fixtureOriginal = @{}
foreach ($name in $names) {
    $fixtureOriginal[$name] = "original-$name"
}

try {
    $mainLauncher = [System.IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot '..\scripts\Start-OptInHud.ps1')
    )
    foreach ($name in @('GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')) {
        if (-not $mainLauncher.Contains($name + ' = $null')) {
            throw "The repo launcher does not clear $name."
        }
    }
    $diagnosticLauncher = [System.IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot 'diagnostic-kit\launch-test.ps1')
    )
    foreach ($name in @('GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')) {
        if (-not $diagnosticLauncher.Contains("'" + $name + "'")) {
            throw "The disposable diagnostic launcher does not clear $name."
        }
    }

    $result = Invoke-ScopedProcessEnvironment -Environment $scopedEnvironment -Action {
        foreach ($name in $names) {
            if ([Environment]::GetEnvironmentVariable($name, 'Process') -cne $scopedEnvironment[$name]) {
                throw "Scoped value for $name was not applied."
            }
        }
        Assert-ChildCopilotHome -Expected $scopedEnvironment.COPILOT_HOME
        'normal-exit'
    }
    if ($result -cne 'normal-exit') {
        throw 'The scoped action result was not returned.'
    }
    Assert-EnvironmentRestored -Expected $fixtureOriginal

    $caughtFixtureFailure = $false
    try {
        Invoke-ScopedProcessEnvironment -Environment $scopedEnvironment -Action {
            foreach ($name in $names) {
                if ([Environment]::GetEnvironmentVariable($name, 'Process') -cne $scopedEnvironment[$name]) {
                    throw "Scoped value for $name was not applied."
                }
            }
            throw 'fixture failure'
        } | Out-Null
    } catch {
        $caughtFixtureFailure = $_.Exception.Message -ceq 'fixture failure'
    }
    if (-not $caughtFixtureFailure) {
        throw 'The scoped action failure was not propagated.'
    }
    Assert-EnvironmentRestored -Expected $fixtureOriginal
    'EnvironmentRestoration=normal-exit-and-failure-passed'
} finally {
    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process')
    }
}
