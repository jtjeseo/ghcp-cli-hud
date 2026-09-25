# Copilot CLI HUD

User-level Windows statusline and optional activity-tracking hooks for GitHub Copilot CLI.

## What it displays

- Line 1: repository branch when available, context gauge and used/limit, and session runtime.
- Line 2: session AIC total, token rate, cumulative input/output/cache totals, and line changes.
- Line 3: active agents/tools and at most one recent outcome; omitted when there is no useful activity.

The AIC value is the session total read from `ai_used.formatted`. The default HUD does not show a delta. An experimental, project-scoped bridge can opt in to a `recent +… AIU` checkpoint increase after a complete busy/idle interval; it is not labeled as a prompt or turn cost. Input and cache totals are not additive.

## Files

- `statusline\statusline.cmd`: Windows wrapper; launches the PowerShell renderer.
- `statusline\statusline.ps1`: renderer. The branch lookup is local; Git is needed to show a branch.
- `hooks\state-hook.ps1` and `hooks\state-hook.sh`: fail-open per-session activity tracking.
- `hooks\session-state-hooks.json`: user hook event configuration for tool, session, error, and subagent activity.
- `.github\extensions\hud-signal-bridge`: experimental project-scoped signal bridge. It is inert unless explicitly opted in.
- `tests\hud-signal-state-machine.test.mjs`, `tests\hud-signal-state-store.test.mjs`, and `tests\statusline-signal-fixtures.ps1`: local synthetic fixtures; none launches Copilot.

The hook configuration uses per-user paths and can be installed under another Windows user's profile. Runtime state is created locally under `.copilot\state`; do not copy state from another machine.

## Requirements

- GitHub Copilot CLI with the hook events used by this configuration. This setup was validated with CLI 1.0.88; verify event support before enabling hooks on other versions.
- PowerShell 7 (`pwsh`) on `PATH` for the Windows statusline wrapper and PowerShell hook handler.
- Bash and `jq` are needed only if the CLI invokes the Bash hook handler.
- Node.js is needed to run the local bridge fixtures. The CLI supplies the SDK when it runs a project extension.

## Opt-in signal prototype

The bridge is not installed under `%USERPROFILE%\.copilot\extensions` and does not alter hook or statusline settings. It runs only when this project extension is discovered and `COPILOT_HUD_SIGNAL_BRIDGE=1` is set. It also requires an explicitly set `COPILOT_HOME`; the extension will not fall back to the normal user home.

The renderer reads the bridge file only when the same opt-in variable is `1`, the session ID matches, and the bounded state is valid and fresh. The file is written under `%COPILOT_HOME%\state\hud-signal-bridge\hud-signal-<sessionId>.json`, atomically replaced, limited to 4 KiB, and contains only its version, session ID, timestamps, a neutral phase, and the most recent checkpoint difference. Active state is heartbeated every 5 seconds and ignored if more than 20 seconds stale; the complete phase lasts 10 seconds and a recent difference lasts 2 minutes. The directory retains at most 64 state files and prunes files older than 24 hours at extension startup. On Windows it inherits the `COPILOT_HOME` directory ACL; restrictive Unix mode bits are requested where supported. No event logs, prompts, responses, intent/progress text, tool names, arguments/results, transcripts, or per-call usage are written. The renderer performs no network or GitHub/API calls.

The AIC difference is computed only from a valid prior numeric checkpoint followed by idle, a non-overlapping interval of sequential root-turn starts/ends, a later numeric checkpoint, and a subsequent `session.idle`. Sequential internal turns in the same busy interval are grouped without using `turnId` as an identity. Per-call usage is ignored. The first complete interval after startup establishes a baseline and shows no difference. Missing or out-of-order boundaries, overlaps, interruption, resume/context clear, counter decrease, malformed state, or any unverified subagent event suppresses the value; subagent suppression lasts until a session resume or context clear resets the machine. The display label is `recent +… AIU`; it does not claim a unique prompt or turn cost.

The bridge phase labels are `◐ Working`, `◐ Running tool`, and a brief `✓ Complete`; idle has no line-3 label. Hook-based active tool/agent activity takes precedence, preventing a duplicate phase claim. If the bridge is disabled, absent, stale, or malformed, the existing hook ticker remains the fallback. Subagent/Fleet detail continues to use the existing hook-based view; the bridge does not invent agent counts or lifecycle states.

Run the local synthetic checks from the repository root:

```powershell
node --test .\tests\hud-signal-state-machine.test.mjs .\tests\hud-signal-state-store.test.mjs
pwsh -NoProfile -File .\tests\statusline-signal-fixtures.ps1
```

These fixtures cover checkpoint/idle grouping, duplicate turn IDs, resets, overlap, interruption, resume/context clear, subagent suppression, atomic state replacement, stale/absent/malformed state, rendering widths, ANSI/`NO_COLOR`, and hook fallback. They do not enable the extension or launch a live CLI session.

The bounded operator kit is assembled separately in a disposable Git workspace. Its launcher uses a fresh `COPILOT_HOME`, isolated `GH_CONFIG_DIR`, clears inherited token variables for the child process, and sets the opt-in only for that test process. The kit has a `Configure-TestStatusline.ps1` script that can create a minimal `settings.json` only inside its disposable home; it is not run during preparation and requires an explicit switch. Do not copy the project extension to a user-wide extension directory or an application repository.

After separately approving the disposable settings file and live run, verify the extension is **Running** under **Project** with `/env` before prompting. Use at most one tool-free baseline request followed by one bounded read-only request that runs `Start-Sleep -Seconds 7; Get-Content -LiteralPath .\phase-probe.txt`. Stop if sign-in, trust, or tool permission is requested. If the single target interval does not produce the phase/checkpoint signals, call it inconclusive rather than repeating the prompt. Fleet/subagent validation is a separate test gate.

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
