. (Join-Path $PSScriptRoot 'Hud-Json.ps1')

function Read-HudSettingsDocument {
    param([AllowNull()][string]$Path)
    $text = '{}'
    if ($Path -and [IO.File]::Exists($Path)) {
        if ((Get-Item -LiteralPath $Path).Length -gt 1048576) { throw 'Settings exceed the safe setup size limit.' }
        $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
    }
    $root = [CopilotHud.JsonValue]::Parse($text)
    if ($root.Kind -ne 'object') { throw 'Settings must be a JSON object.' }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($property in $root.Properties) {
        if (-not $names.Add($property.Name)) { throw 'Settings contain duplicate top-level keys.' }
    }
    return $root
}

function Get-HudSettingsCommand {
    param([CopilotHud.JsonValue]$Root)
    $status = $Root.Get('statusLine')
    if ($null -ne $status -and $status.Kind -eq 'object') {
        $command = $status.Get('command')
        if ($null -ne $command -and $command.Kind -eq 'string') { return $command.Text }
    }
    return $null
}

function Format-HudJsonProperty {
    param([string]$Name, [string]$Raw)
    return (($Name | ConvertTo-Json -Compress) + ': ' + $Raw)
}

function Format-HudJsonObject {
    param([Collections.Generic.List[string]]$Properties)
    return ("{`n  " + [string]::Join(",`n  ", $Properties.ToArray()) + "`n}")
}

function Write-HudSettingsStatusLine {
    param([CopilotHud.JsonValue]$Root, [string]$Command)
    $properties = [Collections.Generic.List[string]]::new()
    $old = $Root.Get('statusLine')
    $hasRefresh = $false
    if ($null -ne $old -and $old.Kind -eq 'object') {
        foreach ($property in $old.Properties) {
            if ($property.Name -cin @('type', 'command')) { continue }
            if ($property.Name -ceq 'refreshInterval') { $hasRefresh = $true }
            $properties.Add((Format-HudJsonProperty $property.Name $property.Value.Raw))
        }
    }
    $properties.Add('"type": "command"')
    $properties.Add((Format-HudJsonProperty 'command' ($Command | ConvertTo-Json -Compress)))
    if (-not $hasRefresh) { $properties.Add('"refreshInterval": 5') }
    return Format-HudJsonObject $properties
}

function New-HudSettingsContent {
    param([string]$Path, [string]$Command, [switch]$EnableBridge, [switch]$ReplaceStatusLine)
    $root = Read-HudSettingsDocument $Path
    $old = $root.Get('statusLine')
    if ($null -ne $old -and $old.Kind -ne 'null' -and -not $ReplaceStatusLine) {
        $current = Get-HudSettingsCommand $root
        $matches = $current -ceq $Command
        if ([IO.Path]::DirectorySeparatorChar -eq '\' -and $current) {
            $matches = [Environment]::ExpandEnvironmentVariables($current).Trim('"') -ieq $Command.Trim('"')
        }
        if (-not $matches) { throw 'Another statusline is configured. Use -ReplaceStatusLine only if you want to replace it.' }
    }
    $properties = [Collections.Generic.List[string]]::new()
    $hasStatus = $false
    $hasExperimental = $false
    foreach ($property in $root.Properties) {
        $raw = $property.Value.Raw
        if ($property.Name -ceq 'statusLine') {
            $raw = Write-HudSettingsStatusLine $root $Command
            $hasStatus = $true
        } elseif ($property.Name -ceq 'experimental' -and $EnableBridge) {
            $raw = 'true'
            $hasExperimental = $true
        }
        $properties.Add((Format-HudJsonProperty $property.Name $raw))
    }
    if (-not $hasStatus) {
        $properties.Add((Format-HudJsonProperty 'statusLine' (Write-HudSettingsStatusLine $root $Command)))
    }
    if ($EnableBridge -and -not $hasExperimental) { $properties.Add('"experimental": true') }
    return Format-HudJsonObject $properties
}

function Get-HudRestoredSettings {
    param([string]$Path, [AllowNull()][string]$OriginalPath, [string]$Command, [bool]$EnabledExperimental)
    $current = Read-HudSettingsDocument $Path
    $original = Read-HudSettingsDocument $OriginalPath
    $restoreStatus = (Get-HudSettingsCommand $current) -ceq $Command
    $experimental = $current.Get('experimental')
    $restoreExperimental = $EnabledExperimental -and $null -ne $experimental -and $experimental.Kind -eq 'true'
    $properties = [Collections.Generic.List[string]]::new()
    foreach ($property in $current.Properties) {
        $value = $property.Value
        if (($property.Name -ceq 'statusLine' -and $restoreStatus) -or
            ($property.Name -ceq 'experimental' -and $restoreExperimental)) {
            $value = $original.Get($property.Name)
        }
        if ($null -ne $value) { $properties.Add((Format-HudJsonProperty $property.Name $value.Raw)) }
    }
    return [pscustomobject]@{
        Changed = $restoreStatus -or $restoreExperimental
        Text = Format-HudJsonObject $properties
        Empty = $properties.Count -eq 0
    }
}
