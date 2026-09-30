$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Hud-Configuration.ps1')
function Assert-Json([bool]$Ok, [string]$Message) { if (-not $Ok) { throw $Message } }
$root = Join-Path ([IO.Path]::GetTempPath()) ('hud-json-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    $valid = @(
        '{}', '[]', 'null', 'true', 'false', '0', '-0', '1.2500', '1e+999',
        '"escaped\\\"\b\f\n\r\t\/\u0041"', '{"nested":{"x":1,"x":2},"a":[null,{},[]]}',
        ('[' * 256 + '0' + ']' * 256)
    )
    $invalid = @(
        '', ' ', '{bad', '{', '[', '{"a":1,}', '[1,]', '[,1]', '00', '-01', '+1', '.1',
        '1.', '1e', '1e+', '1e--2', 'NaN', 'Infinity', 'True', 'nul', 'true false',
        '"\x00"', '"\uZZZZ"', '"unterminated', ('"' + [char]1 + '"'),
        '{"a" 1}', '{"a":}', '{}x', '/*comment*/{}', ('[' * 257 + '0' + ']' * 257)
    )
    foreach ($text in $valid) { [void][CopilotHud.JsonValue]::Parse($text) }
    foreach ($text in $invalid) {
        $refused = $false
        try { [void][CopilotHud.JsonValue]::Parse($text) } catch { $refused = $true }
        Assert-Json $refused 'Malformed JSON was accepted.'
    }
    $path = Join-Path $root 'settings.json'
    $text = '{"stamp":"2026-09-30T00:00:00Z","huge":9007199254740993,"precise":0.123456789012345678901234567890,"exp":1.20e+999,"unknown":{"escaped":"\u0041","values":[null,false,{},[]]},"Case":1,"case":2}'
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
    $before = [CopilotHud.JsonValue]::Parse($text)
    $after = [CopilotHud.JsonValue]::Parse((New-HudSettingsContent -Path $path -Command 'a "quoted" command' -EnableBridge))
    foreach ($property in $before.Properties) {
        Assert-Json ($after.Get($property.Name).Raw -ceq $property.Value.Raw) 'An unowned JSON value changed.'
    }
    Assert-Json ((Get-HudSettingsCommand $after) -ceq 'a "quoted" command') 'Command quoting changed.'
    foreach ($text in '{"a":1,"a":2}', '{"a":1,"\u0061":2}', ('{"x":' + '[' * 256 + '0' + ']' * 256 + '}')) {
        [IO.File]::WriteAllText($path, $text)
        $refused = $false
        try { Read-HudSettingsDocument $path | Out-Null } catch { $refused = $true }
        Assert-Json $refused 'Duplicate settings keys or excess nesting were accepted.'
    }
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $random = [Random]::new(51)
        $alphabet = @('{', '}', '[', ']', '"', '\', ':', ',', '0', '1', '-', '.', 'e', '+', ' ', 'x')
        $seed = '{"name":"value","n":-1.2e+3,"a":[true,null,false,{}]}'
        $options = [Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 256
        foreach ($iteration in 1..600) {
            $index = $random.Next($seed.Length)
            $text = $seed.Substring(0, $index) + $alphabet[$random.Next($alphabet.Count)] + $seed.Substring($index + 1)
            $ours = $true; $reference = $true
            try { [void][CopilotHud.JsonValue]::Parse($text) } catch { $ours = $false }
            try { $document = [Text.Json.JsonDocument]::Parse($text, $options); $document.Dispose() } catch { $reference = $false }
            Assert-Json ($ours -eq $reference) 'JSON grammar differs from System.Text.Json.'
        }
        'JsonDifferentialPass=True; deterministic mutations=600'
    }
    'LosslessJsonPass=True; strict grammar/depth/escaped duplicate keys; raw dates/numbers/nested values/case preserved'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
