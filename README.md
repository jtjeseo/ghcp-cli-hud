# Copilot CLI HUD

A compact terminal HUD for GitHub Copilot CLI: Git branch and optional sync arrows, context and quota gauges, daily/session usage, tokens, line changes, and tool/agent activity.

**Windows-first pilot.** macOS is implemented but unverified; an intermittent Windows session-start fixture failure remains unexplained. See [verification limits](docs/reference.md#known-verification-limits).

## Quick start

Clone this repository or extract its ZIP, then open a terminal in its root. Use your own Copilot sign-in; share this repo, **not your `.copilot` folder**.

| Requirement | Windows | macOS (provisional) |
|---|---|---|
| Copilot CLI | 1.0.89+ | 1.0.89+ |
| Renderer and setup | Built-in Windows PowerShell 5.1+; PowerShell 7 optional | PowerShell 7 (`brew install --cask powershell`) |
| Hooks | Built-in Windows PowerShell 5.1 | Bash and `jq` (`brew install jq`) |
| Optional Git sync | Git 2.31+; Windows 10/Server 2016+ | Git 2.31+ and `jq` |

**Windows display:** [Windows Terminal](https://learn.microsoft.com/en-us/windows/terminal/install) is recommended for Unicode icons and colors. It is a separate app, not PowerShell: installing PowerShell 7 does not install it. Open **Windows Terminal** from Start and choose Windows PowerShell or PowerShell 7 from its profile menu. Classic Command Prompt/PowerShell windows may show missing glyphs or limited colors.

**Windows**, from PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Setup-Hud.ps1
```

**macOS**, from Terminal:

```bash
pwsh -NoProfile -File ./scripts/Setup-Hud.ps1
```

Restart Copilot CLI afterward. Quota appears after a model call; recent AIU needs a complete checkpoint interval. Agent counts depend on the lifecycle events your CLI emits.

Setup backs up touched files, preserves unrelated settings, and installs the renderer plus an experimental signal/quota bridge. Absent hooks are activated only after silent fail-open probes pass; existing active hooks and enabled/disabled preferences are kept. **Git fetching is off by default.**

No credentials are copied, permissions granted, shell profiles changed, or plugins installed. `Bypass` is process-scoped, not a stored policy change; restrictive organization policy is not bypassed. Review downloaded code before running it.

### Options

Append flags to either setup command:

| Flag | Purpose |
|---|---|
| `-CheckOnly` | Check prerequisites without installing |
| `-WhatIf` | Preview without writing |
| `-EnableGitSync` | Opt into periodic upstream fetching; never pulls or pushes |
| `-Basic` | Omit bridge installation; does not disable an existing bridge |
| `-SkipHooks` | Leave absent hooks disabled; keep existing active hooks |
| `-ReplaceStatusLine` | Explicitly replace another configured statusline |
| `-CopilotHome <absolute path>` | Choose a home; default respects `COPILOT_HOME`, then your user home |

## Update, undo, and recovery

**Update:** rerun the same setup command and restart CLI. Existing quota caches, daily accounting and session state are preserved.

**Undo:** close CLI and run the `Uninstall-Hud.ps1` command printed by setup. It uses that installation's backup and preserves later unrelated settings edits. `-WhatIf` previews undo; `-Force` can discard later edits.

**Disable:** set `enabled` to `false` in `<CopilotHome>/hud-signal-bridge.json` and restart CLI, or in `hud-git-sync.json` to stop only fetching. A nonempty `COPILOT_HUD_SIGNAL_BRIDGE` environment override takes precedence.

**Hooks blocking tools?** From an **external shell**, rename `<CopilotHome>/hooks/session-state-hooks.json` to `session-state-hooks.json.disabled`, then restart CLI. If Windows policy prevents hook validation, use `-SkipHooks` rather than changing organization policy.

## More detail

- [Display, quota accounting, Git sync, and bridge behavior](docs/reference.md#what-it-displays)
- [Legacy/manual installation and updates](docs/reference.md#default-install-for-every-session)
- [Local checks, including Git Bash](docs/reference.md#local-synthetic-checks)
- [Isolated launch and operator diagnostics](docs/reference.md#repo-scoped-isolated-hud-launch)
- [Data and privacy](docs/reference.md#data-and-privacy)
