function Invoke-ScopedProcessEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $names = @($Environment.Keys)
    $saved = @{}
    foreach ($name in $names) {
        if ($name -isnot [string] -or $name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw 'A scoped environment variable name is invalid.'
        }
        $value = $Environment[$name]
        if ($null -ne $value -and $value -isnot [string]) {
            throw 'Scoped environment values must be strings or null.'
        }
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        foreach ($name in $names) {
            [Environment]::SetEnvironmentVariable(
                $name,
                $Environment[$name],
                'Process'
            )
        }
        & $Action
    } finally {
        foreach ($name in $names) {
            [Environment]::SetEnvironmentVariable(
                $name,
                $saved[$name],
                'Process'
            )
        }
    }
}
