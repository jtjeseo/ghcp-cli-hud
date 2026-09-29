# Temporary schema diagnostics only: set COPILOT_RAW_PAYLOAD_CAPTURE=1 for one run.
# Unset it afterward; captures are retained until manually removed.
$script:HookFailureDirectory = $null
$script:HookFailureDetected = $false

function Write-HookFailureMarker {
    param([AllowNull()][string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory)) { return }
    try {
        [void][System.IO.Directory]::CreateDirectory($Directory)
        $path = Join-Path $Directory 'hud-hook-failure.log'
        [System.IO.File]::WriteAllText(
            $path,
            "hook-state-failure$([Environment]::NewLine)",
            [System.Text.UTF8Encoding]::new($false)
        )
    } catch {
    }
}

function Clear-HookFailureMarker {
    param([AllowNull()][string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory)) { return }
    try {
        $path = Join-Path $Directory 'hud-hook-failure.log'
        if ([System.IO.File]::Exists($path)) {
            [System.IO.File]::Delete($path)
        }
    } catch {
    }
}

function ConvertTo-HudHashtable {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Collections.IDictionary]) {
        $converted = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $converted[[string]$key] = ConvertTo-HudHashtable -Value $Value[$key]
        }
        return $converted
    }

    if ($Value -is [pscustomobject]) {
        $converted = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $converted[$property.Name] = ConvertTo-HudHashtable -Value $property.Value
        }
        return $converted
    }

    if ($Value -is [array]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            [void]$items.Add((ConvertTo-HudHashtable -Value $item))
        }
        $converted = $items.ToArray()
        return ,$converted
    }

    return $Value
}

try {
    [Console]::SetOut([System.IO.TextWriter]::Null)
    [Console]::SetError([System.IO.TextWriter]::Null)
    $ErrorActionPreference = 'Stop'
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = $utf8
    $mutex = $null
    $mutexAcquired = $false
    $Event = $null
    $scriptArguments = @($args)
    for ($index = 0; $index -lt $scriptArguments.Count; $index++) {
        $argument = $scriptArguments[$index]
        if ($argument -isnot [string]) { continue }
        if ($argument -match '^[/-]Event[:=](.*)$') {
            if ($Matches[1].Length -gt 0) { $Event = $Matches[1] }
            break
        }
        if ($argument -ieq '-Event' -or $argument -ieq '/Event') {
            if ($index + 1 -lt $scriptArguments.Count) {
                $nextArgument = $scriptArguments[$index + 1]
                if ($nextArgument -is [string] -and $nextArgument -notmatch '^[-/]') {
                    $Event = $nextArgument
                }
            }
            break
        }
        if ($argument -notmatch '^[-/]') {
            $Event = $argument
            break
        }
    }

    function Get-FirstPayloadValue {
    param([object]$Payload, [string[]]$Paths)

    foreach ($path in $Paths) {
        $current = $Payload
        $found = $true
        foreach ($part in $path.Split('.')) {
            if ($null -eq $current) {
                $found = $false
                break
            }
            if ($current -is [System.Collections.IDictionary]) {
                if ($current.Contains($part)) {
                    $current = $current[$part]
                } else {
                    $found = $false
                    break
                }
            } else {
                $property = $current.PSObject.Properties[$part]
                if ($null -ne $property) {
                    $current = $property.Value
                } else {
                    $found = $false
                    break
                }
            }
        }
        if ($found -and $null -ne $current -and
            -not ($current -is [string] -and [string]::IsNullOrWhiteSpace($current))) {
            return $current
        }
    }
    return $null
}

    function New-HudState {
    param([string]$SessionId, [long]$Now)
    return [ordered]@{
        sessionId = $SessionId
        createdAtMs = $Now
        updatedAtMs = $Now
        activeTools = @()
        recentTools = @()
        lastTool = $null
        lastError = $null
        activeSubagents = @()
        lastSubagent = $null
    }
}

    function ConvertTo-ToolCategory {
    param([AllowNull()][string]$ToolName)

    if ([string]::IsNullOrWhiteSpace($ToolName)) { return $null }
    switch -Regex ($ToolName.ToLowerInvariant()) {
        '^(bash|powershell)$' { return 'shell' }
        '^(create|edit|str_replace_editor|apply_patch)$' { return 'edit' }
        '^(view)$' { return 'read' }
        '^(glob|grep|rg)$' { return 'search' }
        '^(web_fetch|web_search)$' { return 'web' }
        '^(task)$' { return 'agent' }
        '^(ask_user)$' { return 'prompt' }
        '^mcp__.+$' { return 'tool' }
        default { return $null }
    }
}

    function ConvertTo-SafeToolName {
    param([AllowNull()][object]$ToolName)

    if ($ToolName -isnot [string]) { return $null }
    $name = $ToolName.Trim().ToLowerInvariant()
    if ($name -match '^mcp__.+$') { return 'tool' }
    if ($name -match '^(bash|powershell|create|edit|str_replace_editor|apply_patch|view|glob|grep|rg|web_fetch|web_search|task|ask_user)$') {
        return $name
    }
    return $null
}

    function Get-SafeToolTarget {
    param([object]$Payload)

    $value = Get-FirstPayloadValue -Payload $Payload -Paths @('toolArgs.path')
    if ($value -isnot [string]) { return $null }
    $text = [regex]::Replace($value, '[\p{C}\p{Zl}\p{Zp}]', ' ')
    $text = [regex]::Replace($text, '\s+', ' ').Trim()
    if ($text.Length -gt 256) { $text = $text.Substring(0, 256) }
    if ([string]::IsNullOrWhiteSpace($text) -or
        $text -match '(?i)(https?://|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|(token|secret|password|api[_ -]?key|authorization|bearer)\s*[:=])' -or
        $text -match '^[A-Fa-f0-9-]{32,}$' -or $text -match '^\d{6,}$') {
        return $null
    }
    return $text
}

    function ConvertTo-MatchKey {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '__unknown__' }
    $text = [regex]::Replace(([string]$Value).ToLowerInvariant(), '[\p{C}]', '')
    if ($text.Length -gt 200) { $text = $text.Substring(0, 200) }
    if ([string]::IsNullOrWhiteSpace($text)) { return '__unknown__' }
    return $text
}

    function Save-FirstRawPayload {
    param([string]$Directory, [string]$HookEvent, [string]$SessionId, [string]$Raw)

    $path = Join-Path $Directory "raw-$HookEvent-$SessionId.json"
    if ([System.IO.File]::Exists($path)) { return }
    $temporaryPath = Join-Path $Directory ".raw-$HookEvent-$SessionId.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Raw, $utf8)
        try {
            [System.IO.File]::Move($temporaryPath, $path)
        } catch [System.IO.IOException] {
            if (-not [System.IO.File]::Exists($path)) { throw }
        }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

    function Remove-StaleFiles {
    param([string]$Directory)

    $cutoff = [DateTime]::UtcNow.AddHours(-24)
    foreach ($pattern in @('hud-state-*', '*.frame')) {
        foreach ($file in Get-ChildItem -LiteralPath $Directory -Force -File -Filter $pattern -ErrorAction Stop) {
            if ($file.LastWriteTimeUtc -lt $cutoff) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            }
        }
    }
}

    function Write-HudState {
    param([string]$Path, [object]$State)

    $temporaryPath = "$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    $backupPath = $null
    try {
        $json = ConvertTo-Json -InputObject $State -Depth 12 -Compress
        [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8)
        if ([System.IO.File]::Exists($Path)) {
            $backupPath = "$Path.$PID.$([guid]::NewGuid().ToString('N')).bak"
            [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
            if ([System.IO.File]::Exists($backupPath)) {
                [System.IO.File]::Delete($backupPath)
            }
            $backupPath = $null
        } else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
        if ($null -ne $backupPath -and [System.IO.File]::Exists($backupPath)) {
            [System.IO.File]::Delete($backupPath)
        }
    }
    }

    try {
    $eventName = if ($Event -is [string]) { $Event } else { '' }
    if ($eventName -notin @(
        'sessionStart', 'sessionEnd', 'preToolUse', 'postToolUse',
        'postToolUseFailure', 'errorOccurred', 'subagentStart', 'subagentStop'
    )) { throw 'Unknown hook event.' }
    $Event = $eventName

    $copilotHome = if (-not [string]::IsNullOrWhiteSpace($env:COPILOT_HOME)) {
        $env:COPILOT_HOME
    } else {
        Join-Path $env:USERPROFILE '.copilot'
    }
    $stateDirectory = Join-Path $copilotHome 'state'
    $script:HookFailureDirectory = $stateDirectory
    [void][System.IO.Directory]::CreateDirectory($stateDirectory)

    $raw = [Console]::In.ReadToEnd()
    $payloadObject = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    $payload = ConvertTo-HudHashtable -Value $payloadObject
    if ($payload -isnot [System.Collections.IDictionary]) { throw 'Hook payload is not an object.' }

    $sessionId = Get-FirstPayloadValue -Payload $payload -Paths @('sessionId')
    if ($null -eq $sessionId) { throw 'Hook payload has no session identifier.' }
    $sessionId = [string]$sessionId
    if ($sessionId -notmatch '^[A-Za-z0-9_-]{1,128}$') { throw 'Hook payload session identifier is not a safe filename.' }

    if ([Environment]::GetEnvironmentVariable('COPILOT_RAW_PAYLOAD_CAPTURE') -ceq '1') {
        try {
            Save-FirstRawPayload -Directory $stateDirectory -HookEvent $Event -SessionId $sessionId -Raw $raw
        } catch {
        }
    }

    $mutexName = "Local\CopilotHudState-$sessionId"
    $mutex = [System.Threading.Mutex]::new($false, $mutexName)
    try {
        $mutexAcquired = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $mutexAcquired = $true
    }
    if (-not $mutexAcquired) { throw 'Timed out waiting for the per-session state lock.' }

    $statePath = Join-Path $stateDirectory "hud-state-$sessionId.json"
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    if ($Event -eq 'sessionEnd') {
        if ([System.IO.File]::Exists($statePath)) { [System.IO.File]::Delete($statePath) }
        $animationPath = Join-Path $stateDirectory "statusline-animation-$sessionId.frame"
        if ([System.IO.File]::Exists($animationPath)) { [System.IO.File]::Delete($animationPath) }
        Remove-StaleFiles -Directory $stateDirectory
        Clear-HookFailureMarker -Directory $stateDirectory
        exit 0
    }

    if ($Event -eq 'sessionStart' -or -not [System.IO.File]::Exists($statePath)) {
        $state = New-HudState -SessionId $sessionId -Now $now
    } else {
        try {
            $storedStateObject = ConvertFrom-Json -InputObject (
                Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop
            ) -ErrorAction Stop
            $state = ConvertTo-HudHashtable -Value $storedStateObject
            if ($state -isnot [System.Collections.IDictionary] -or
                [string]$state['sessionId'] -cne $sessionId) {
                throw 'Stored session state did not match the current session.'
            }
        } catch {
            $script:HookFailureDetected = $true
            Write-HookFailureMarker -Directory $stateDirectory
            $state = New-HudState -SessionId $sessionId -Now $now
        }
    }

    $activeTools = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($state['activeTools'])) {
        if ($item -isnot [System.Collections.IDictionary] -and $item -isnot [pscustomobject]) {
            continue
        }
        $startedAt = 0.0
        if ([double]::TryParse([string]$item['startedAtMs'], [ref]$startedAt) -and
            $startedAt -le $now -and $now - $startedAt -le 300000) {
            [void]$activeTools.Add($item)
        }
    }
    $state['activeTools'] = $activeTools.ToArray()

    switch ($Event) {
        'preToolUse' {
            $toolName = Get-FirstPayloadValue -Payload $payload -Paths @('toolName')
            $category = ConvertTo-ToolCategory -ToolName ([string]$toolName)
            if ($null -ne $category) {
                $displayToolName = ConvertTo-SafeToolName -ToolName $toolName
                $toolTarget = Get-SafeToolTarget -Payload $payload
                $tools = [System.Collections.Generic.List[object]]::new()
                foreach ($item in @($state['activeTools'])) {
                    if ($null -ne $item) { [void]$tools.Add($item) }
                }
                $sameCategory = @($tools | Where-Object { [string]$_['category'] -ceq $category })
                $hasUnkeyedMatch = @($sameCategory | Where-Object {
                    [string]::IsNullOrWhiteSpace([string]$_['toolName'])
                }).Count -gt 0
                $hasDuplicateIdentity = -not [string]::IsNullOrWhiteSpace([string]$displayToolName) -and
                    @($sameCategory | Where-Object { [string]$_['toolName'] -ceq $displayToolName }).Count -gt 0
                $timingReliable = $true
                if ($sameCategory.Count -gt 0 -and
                    ([string]::IsNullOrWhiteSpace([string]$displayToolName) -or
                        $hasUnkeyedMatch -or $hasDuplicateIdentity)) {
                    foreach ($item in $sameCategory) { $item['timingReliable'] = $false }
                    $timingReliable = $false
                }
                [void]$tools.Add([ordered]@{
                    category = $category
                    toolName = $displayToolName
                    target = $toolTarget
                    startedAtMs = $now
                    timingReliable = $timingReliable
                })
                $state['activeTools'] = $tools.ToArray()
            }
        }
        { $_ -in @('postToolUse', 'postToolUseFailure') } {
            $toolName = Get-FirstPayloadValue -Payload $payload -Paths @('toolName')
            $category = ConvertTo-ToolCategory -ToolName ([string]$toolName)
            if ($null -ne $category) {
                $displayToolName = ConvertTo-SafeToolName -ToolName $toolName
                $toolTarget = Get-SafeToolTarget -Payload $payload
                $originalTools = @($state['activeTools'] | Where-Object { $null -ne $_ })
                $categoryIndexes = [System.Collections.Generic.List[int]]::new()
                $identityIndex = -1
                for ($index = 0; $index -lt $originalTools.Count; $index++) {
                    $item = $originalTools[$index]
                    if ([string]$item['category'] -ceq $category) {
                        [void]$categoryIndexes.Add($index)
                        if (-not [string]::IsNullOrWhiteSpace([string]$displayToolName) -and
                            [string]$item['toolName'] -ceq $displayToolName) {
                            $identityIndex = $index
                        }
                    }
                }
                $selectedIndex = -1
                $ambiguous = $false
                if ($identityIndex -ge 0) {
                    $selectedIndex = $identityIndex
                } elseif ($categoryIndexes.Count -eq 1) {
                    $selectedIndex = $categoryIndexes[0]
                } elseif ($categoryIndexes.Count -gt 1) {
                    $selectedIndex = $categoryIndexes[0]
                    $ambiguous = $true
                }

                if ($selectedIndex -ge 0) {
                    $matched = $originalTools[$selectedIndex]
                    $tools = [System.Collections.Generic.List[object]]::new()
                    for ($index = 0; $index -lt $originalTools.Count; $index++) {
                        if ($index -eq $selectedIndex) { continue }
                        $item = $originalTools[$index]
                        if ($ambiguous -and [string]$item['category'] -ceq $category) {
                            $item['timingReliable'] = $false
                        }
                        [void]$tools.Add($item)
                    }
                    $state['activeTools'] = $tools.ToArray()
                    $duration = if (-not $ambiguous -and $matched['timingReliable'] -ne $false) {
                        [math]::Max(0, $now - [double]$matched['startedAtMs'])
                    } else {
                        $null
                    }
                    $lastToolName = if (-not [string]::IsNullOrWhiteSpace([string]$matched['toolName'])) {
                        [string]$matched['toolName']
                    } else {
                        $displayToolName
                    }
                    $lastToolTarget = if (-not [string]::IsNullOrWhiteSpace([string]$matched['target'])) {
                        [string]$matched['target']
                    } else {
                        $toolTarget
                    }
                    $state['lastTool'] = [ordered]@{
                        category = $category
                        toolName = $lastToolName
                        target = $lastToolTarget
                        status = if ($Event -eq 'postToolUseFailure') { 'failed' } else { 'complete' }
                        durationMs = $duration
                        completedAtMs = $now
                    }
                }
            }
        }
        'errorOccurred' {
            $errorContext = Get-FirstPayloadValue -Payload $payload -Paths @(
                'errorContext', 'error_context'
            )
            $allowedContexts = @('model_call', 'tool_execution', 'system', 'user_input')
            $safeContext = if ([string]$errorContext -in $allowedContexts) {
                [string]$errorContext
            } else {
                'unknown'
            }
            $recoverable = Get-FirstPayloadValue -Payload $payload -Paths @('recoverable')
            if ($recoverable -isnot [bool]) { $recoverable = $null }
            $state['lastError'] = [ordered]@{
                context = $safeContext
                recoverable = $recoverable
                occurredAtMs = $now
            }
        }
        'subagentStart' {
            $agentName = Get-FirstPayloadValue -Payload $payload -Paths @('agentName')
            $agentId = Get-FirstPayloadValue -Payload $payload -Paths @('agentId')
            $matchKey = ConvertTo-MatchKey $agentName
            $agentKey = if ($null -ne $agentId) { ConvertTo-MatchKey "id:$agentId" } else { $null }
            $agents = [System.Collections.Generic.List[object]]::new()
            foreach ($item in @($state['activeSubagents'])) {
                if ($null -ne $item) { [void]$agents.Add($item) }
            }
            $sameNameAgents = @($agents | Where-Object { [string]$_['matchKey'] -ceq $matchKey })
            $hasUnkeyedMatch = @($sameNameAgents | Where-Object { $null -eq $_['agentKey'] }).Count -gt 0
            $timingReliable = $true
            if ($sameNameAgents.Count -gt 0 -and ($null -eq $agentKey -or $hasUnkeyedMatch)) {
                foreach ($item in $sameNameAgents) { $item['timingReliable'] = $false }
                $timingReliable = $false
            }
            [void]$agents.Add([ordered]@{
                matchKey = $matchKey
                agentKey = $agentKey
                startedAtMs = $now
                timingReliable = $timingReliable
            })
            $state['activeSubagents'] = $agents.ToArray()
        }
        'subagentStop' {
            $agentName = Get-FirstPayloadValue -Payload $payload -Paths @('agentName')
            $agentId = Get-FirstPayloadValue -Payload $payload -Paths @('agentId')
            $matchKey = ConvertTo-MatchKey $agentName
            $agentKey = if ($null -ne $agentId) { ConvertTo-MatchKey "id:$agentId" } else { $null }
            $originalAgents = @($state['activeSubagents'] | Where-Object { $null -ne $_ })
            $idIndexes = [System.Collections.Generic.List[int]]::new()
            $nameIndexes = [System.Collections.Generic.List[int]]::new()
            for ($index = 0; $index -lt $originalAgents.Count; $index++) {
                $item = $originalAgents[$index]
                if ($null -ne $agentKey -and [string]$item['agentKey'] -ceq $agentKey) {
                    [void]$idIndexes.Add($index)
                }
                if ([string]$item['matchKey'] -ceq $matchKey) {
                    [void]$nameIndexes.Add($index)
                }
            }
            $selectedIndex = -1
            $ambiguous = $false
            if ($idIndexes.Count -eq 1) {
                $selectedIndex = $idIndexes[0]
            } elseif ($nameIndexes.Count -eq 1) {
                $selectedIndex = $nameIndexes[0]
            } elseif ($nameIndexes.Count -gt 1) {
                $selectedIndex = $nameIndexes[0]
                $ambiguous = $true
            } elseif ($originalAgents.Count -eq 1) {
                $selectedIndex = 0
            }
            if ($selectedIndex -ge 0) {
                $matched = $originalAgents[$selectedIndex]
                $agents = [System.Collections.Generic.List[object]]::new()
                for ($index = 0; $index -lt $originalAgents.Count; $index++) {
                    if ($index -eq $selectedIndex) { continue }
                    $item = $originalAgents[$index]
                    if ($ambiguous -and [string]$item['matchKey'] -ceq $matchKey) {
                        $item['timingReliable'] = $false
                    }
                    [void]$agents.Add($item)
                }
                $state['activeSubagents'] = $agents.ToArray()
                $duration = if (-not $ambiguous -and $matched['timingReliable'] -ne $false) {
                    [math]::Max(0, $now - [double]$matched['startedAtMs'])
                } else {
                    $null
                }
                $agentOutcome = 'unknown'
                $stopReason = Get-FirstPayloadValue -Payload $payload -Paths @('stopReason')
                if ($stopReason -is [string] -and $stopReason -ceq 'end_turn') {
                    $agentOutcome = 'complete'
                }
                $state['lastSubagent'] = [ordered]@{
                    matchKey = [string]$matched['matchKey']
                    status = $agentOutcome
                    durationMs = $duration
                    completedAtMs = $now
                }
            }
        }
    }

    if ($Event -in @('postToolUse', 'postToolUseFailure') -and $null -ne $category) {
        $historyToolName = $displayToolName
        $historyTarget = $toolTarget
        $lastTool = $state['lastTool']
        if (($lastTool -is [System.Collections.IDictionary] -or $lastTool -is [pscustomobject]) -and
            [double]$lastTool['completedAtMs'] -eq $now -and
            [string]$lastTool['category'] -ceq $category) {
            if (-not [string]::IsNullOrWhiteSpace([string]$lastTool['toolName'])) {
                $historyToolName = [string]$lastTool['toolName']
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$lastTool['target'])) {
                $historyTarget = [string]$lastTool['target']
            }
        }
        $recentTools = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @($state['recentTools'])) {
            if ($null -eq $item) { continue }
            $completedAt = 0.0
            if ([double]::TryParse([string]$item['completedAtMs'], [ref]$completedAt) -and
                $completedAt -le $now -and $now - $completedAt -le 120000) {
                [void]$recentTools.Add($item)
            }
        }
        [void]$recentTools.Add([ordered]@{
            category = $category
            toolName = $historyToolName
            target = $historyTarget
            status = if ($Event -eq 'postToolUseFailure') { 'failed' } else { 'complete' }
            completedAtMs = $now
        })
        while ($recentTools.Count -gt 64) { $recentTools.RemoveAt(0) }
        $state['recentTools'] = $recentTools.ToArray()
    }

    $state['updatedAtMs'] = $now
    Write-HudState -Path $statePath -State $state
    if ($Event -eq 'sessionStart') { Remove-StaleFiles -Directory $stateDirectory }
    if (-not $script:HookFailureDetected) {
        Clear-HookFailureMarker -Directory $stateDirectory
    }
} catch {
    Write-HookFailureMarker -Directory $script:HookFailureDirectory
} finally {
    if ($null -ne $mutex) {
        if ($mutexAcquired) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        try {
            $mutex.Dispose()
        } catch {
        }
    }
}
} catch {
}

exit 0
