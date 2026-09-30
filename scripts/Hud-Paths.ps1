function Assert-HudTargetPath {
    param([string]$HomePath, [string]$TargetPath)
    $home_ = [IO.Path]::GetFullPath($HomePath)
    if ($home_ -ne [IO.Path]::GetPathRoot($home_)) {
        $home_ = $home_.TrimEnd([IO.Path]::DirectorySeparatorChar)
    }
    $target = [IO.Path]::GetFullPath($TargetPath)
    $comparison = if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        [StringComparison]::OrdinalIgnoreCase
    } else { [StringComparison]::Ordinal }
    if (-not $target.Equals($home_, $comparison) -and
        -not $target.StartsWith($home_.TrimEnd([IO.Path]::DirectorySeparatorChar) +
            [IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw 'A HUD target must remain inside its recorded Copilot home.'
    }
    while ($target.Length -ge $home_.Length) {
        $item = $null
        try { $item = Get-Item -LiteralPath $target -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] { }
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Symlinked HUD homes, target files, and target directories are not automatically modified.'
        }
        if ($target.Equals($home_, $comparison)) { break }
        $target = Split-Path -Parent $target
    }
}
