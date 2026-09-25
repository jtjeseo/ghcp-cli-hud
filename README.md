# Copilot CLI HUD

User-level Windows statusline and optional activity-tracking hooks for GitHub Copilot CLI.

## What it displays

- Line 1: repository branch when available, context gauge and used/limit, and session runtime.
- Line 2: session AIC total, token rate, cumulative input/output/cache totals, and line changes.
- Line 3: active agents/tools and at most one recent outcome; omitted when there is no useful activity.

The AIC value is a session total read from `ai_used.formatted`. The available hook events do not identify a reliable parent-turn boundary, so this statusline does not display a per-turn AIC delta. Input and cache totals are not additive.

## Files

- `statusline\statusline.cmd`: Windows wrapper; launches the PowerShell renderer.
- `statusline\statusline.ps1`: renderer. The branch lookup is local; Git is needed to show a branch.
- `hooks\state-hook.ps1` and `hooks\state-hook.sh`: fail-open per-session activity tracking.
- `hooks\session-state-hooks.json`: user hook event configuration for tool, session, error, and subagent activity.

The hook configuration uses per-user paths and can be installed under another Windows user's profile. Runtime state is created locally under `.copilot\state`; do not copy state from another machine.

## Requirements

- GitHub Copilot CLI with the hook events used by this configuration. This setup was validated with CLI 1.0.88; verify event support before enabling hooks on other versions.
- PowerShell 7 (`pwsh`) on `PATH` for the Windows statusline wrapper and PowerShell hook handler.
- Bash and `jq` are needed only if the CLI invokes the Bash hook handler.

## Windows installation

1. Close Copilot CLI. Back up any existing target files individually; do not replace the target user's entire settings file.
2. Copy `statusline\statusline.ps1` and `statusline\statusline.cmd` into `%USERPROFILE%\.copilot\statusline`.
3. Copy `hooks\state-hook.ps1` and `hooks\state-hook.sh` into `%USERPROFILE%\.copilot\hooks`.
4. Initially copy `hooks\session-state-hooks.json` as `%USERPROFILE%\.copilot\hooks\session-state-hooks.json.disabled`. Parse it as JSON and validate the handlers before enabling the config. If an older active hook config exists, back it up and disable it before replacing hook handlers.
5. Merge the following `statusLine` object into the target user's existing `%USERPROFILE%\.copilot\settings.json`, preserving all other settings:

   ```json
   "statusLine": {
     "type": "command",
     "command": "%USERPROFILE%\\.copilot\\statusline\\statusline.cmd",
     "refreshInterval": 5
   }
   ```

6. After validation, rename `session-state-hooks.json.disabled` to `session-state-hooks.json`, then restart Copilot CLI.

`config.json` is CLI-managed. User preferences belong in `settings.json`. This repository intentionally does not contain either file.

## Validation and recovery

From PowerShell, confirm the statusline runtime and hook JSON:

```powershell
Get-Command pwsh
$base = Join-Path $env:USERPROFILE '.copilot'
Get-Content (Join-Path $base 'hooks\session-state-hooks.json.disabled') -Raw |
  ConvertFrom-Json | Out-Null
```

Parse the PowerShell files with `System.Management.Automation.Language.Parser`. If using the Bash handler, run `bash -n` on `state-hook.sh` and confirm `jq` is available.

Telemetry hooks must always fail open: internal errors, malformed input, missing dependencies, and state-write failures must not deny or delay a tool call; handlers must exit `0` and emit no stdout/stderr on error.

If a hook ever blocks CLI tools, use an external PowerShell session to disable it, then restart Copilot CLI:

```powershell
Rename-Item -LiteralPath (Join-Path $HOME '.copilot\hooks\session-state-hooks.json') `
  -NewName 'session-state-hooks.json.disabled'
```

## Data and privacy

Do not commit user `settings.json`, CLI-managed `config.json`, raw payload captures, `.copilot\state`, logs, tokens, or credentials. Raw diagnostic payload capture is off by default; leave it off unless temporarily investigating a schema change, and never share captured payloads.
