function Read-HudSettingsDocument {
    param([AllowNull()][string]$Path)
    $text = '{}'
    if ($Path -and [IO.File]::Exists($Path)) {
        if ((Get-Item -LiteralPath $Path).Length -gt 1048576) { throw 'Settings exceed the safe setup size limit.' }
        $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
    }
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 256
    $document = [Text.Json.JsonDocument]::Parse($text, $options)
    if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
        $document.Dispose()
        throw 'Settings must be a JSON object.'
    }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($property in $document.RootElement.EnumerateObject()) {
        if (-not $names.Add($property.Name)) {
            $document.Dispose()
            throw 'Settings contain duplicate top-level keys.'
        }
    }
    return $document
}

function Get-HudSettingsCommand {
    param([Text.Json.JsonElement]$Root)
    $status = [Text.Json.JsonElement]::new()
    $command = [Text.Json.JsonElement]::new()
    if ($Root.TryGetProperty('statusLine', [ref]$status) -and
        $status.ValueKind -eq [Text.Json.JsonValueKind]::Object -and
        $status.TryGetProperty('command', [ref]$command) -and
        $command.ValueKind -eq [Text.Json.JsonValueKind]::String) { return $command.GetString() }
    return $null
}

function Write-HudSettingsStatusLine {
    param([Text.Json.Utf8JsonWriter]$Writer, [Text.Json.JsonElement]$Root, [string]$Command)
    $old = [Text.Json.JsonElement]::new()
    $hasOld = $Root.TryGetProperty('statusLine', [ref]$old) -and
        $old.ValueKind -eq [Text.Json.JsonValueKind]::Object
    $Writer.WriteStartObject()
    $hasRefresh = $false
    if ($hasOld) {
        foreach ($property in $old.EnumerateObject()) {
            if ($property.Name -cin @('type', 'command')) { continue }
            if ($property.Name -ceq 'refreshInterval') { $hasRefresh = $true }
            $property.WriteTo($Writer)
        }
    }
    $Writer.WriteString('type', 'command')
    $Writer.WriteString('command', $Command)
    if (-not $hasRefresh) { $Writer.WriteNumber('refreshInterval', [int]5) }
    $Writer.WriteEndObject()
}

function New-HudSettingsContent {
    param([string]$Path, [string]$Command, [switch]$EnableBridge, [switch]$ReplaceStatusLine)
    $document = Read-HudSettingsDocument $Path
    $buffer = [IO.MemoryStream]::new()
    $options = [Text.Json.JsonWriterOptions]::new()
    $options.Indented = $true
    $writer = [Text.Json.Utf8JsonWriter]::new($buffer, $options)
    try {
        $root = $document.RootElement
        $old = [Text.Json.JsonElement]::new()
        if ($root.TryGetProperty('statusLine', [ref]$old) -and
            $old.ValueKind -ne [Text.Json.JsonValueKind]::Null -and -not $ReplaceStatusLine) {
            $current = Get-HudSettingsCommand $root
            $matches = $current -ceq $Command
            if ([IO.Path]::DirectorySeparatorChar -eq '\' -and $current) {
                $matches = [Environment]::ExpandEnvironmentVariables($current).Trim('"') -ieq $Command.Trim('"')
            }
            if (-not $matches) { throw 'Another statusline is configured. Use -ReplaceStatusLine only if you want to replace it.' }
        }
        $writer.WriteStartObject()
        $hasStatus = $false
        $hasExperimental = $false
        foreach ($property in $root.EnumerateObject()) {
            $writer.WritePropertyName($property.Name)
            if ($property.Name -ceq 'statusLine') {
                Write-HudSettingsStatusLine $writer $root $Command
                $hasStatus = $true
            } elseif ($property.Name -ceq 'experimental' -and $EnableBridge) {
                $writer.WriteBooleanValue($true)
                $hasExperimental = $true
            } else { $property.Value.WriteTo($writer) }
        }
        if (-not $hasStatus) {
            $writer.WritePropertyName('statusLine')
            Write-HudSettingsStatusLine $writer $root $Command
        }
        if ($EnableBridge -and -not $hasExperimental) { $writer.WriteBoolean('experimental', $true) }
        $writer.WriteEndObject()
        $writer.Flush()
        return [Text.Encoding]::UTF8.GetString($buffer.ToArray())
    } finally {
        $writer.Dispose()
        $buffer.Dispose()
        $document.Dispose()
    }
}

function Get-HudRestoredSettings {
    param([string]$Path, [AllowNull()][string]$OriginalPath, [string]$Command, [bool]$EnabledExperimental)
    $current = Read-HudSettingsDocument $Path
    $original = Read-HudSettingsDocument $OriginalPath
    $buffer = [IO.MemoryStream]::new()
    $options = [Text.Json.JsonWriterOptions]::new()
    $options.Indented = $true
    $writer = [Text.Json.Utf8JsonWriter]::new($buffer, $options)
    try {
        $restoreStatus = (Get-HudSettingsCommand $current.RootElement) -ceq $Command
        $experimental = [Text.Json.JsonElement]::new()
        $restoreExperimental = $EnabledExperimental -and
            $current.RootElement.TryGetProperty('experimental', [ref]$experimental) -and
            $experimental.ValueKind -eq [Text.Json.JsonValueKind]::True
        $writer.WriteStartObject()
        $count = 0
        foreach ($property in $current.RootElement.EnumerateObject()) {
            if (($property.Name -ceq 'statusLine' -and $restoreStatus) -or
                ($property.Name -ceq 'experimental' -and $restoreExperimental)) {
                $before = [Text.Json.JsonElement]::new()
                if ($original.RootElement.TryGetProperty($property.Name, [ref]$before)) {
                    $writer.WritePropertyName($property.Name)
                    $before.WriteTo($writer)
                    $count++
                }
            } else {
                $property.WriteTo($writer)
                $count++
            }
        }
        $writer.WriteEndObject()
        $writer.Flush()
        return [pscustomobject]@{
            Changed = $restoreStatus -or $restoreExperimental
            Text = [Text.Encoding]::UTF8.GetString($buffer.ToArray())
            Empty = $count -eq 0
        }
    } finally {
        $writer.Dispose()
        $buffer.Dispose()
        $original.Dispose()
        $current.Dispose()
    }
}
