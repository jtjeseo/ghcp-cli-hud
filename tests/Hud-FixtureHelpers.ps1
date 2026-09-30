. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Hud-Process.ps1')
$rendererSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'statusline\statusline.ps1'
$fixtureTokens = $null
$fixtureErrors = $null
$fixtureAst = [Management.Automation.Language.Parser]::ParseFile($rendererSource, [ref]$fixtureTokens, [ref]$fixtureErrors)
if ($fixtureErrors.Count -gt 0) { throw 'Renderer did not parse.' }
foreach ($definition in $fixtureAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    if ($definition.Name -in @('ConvertFrom-HudJson', 'ConvertTo-HudJsonDictionary')) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}
