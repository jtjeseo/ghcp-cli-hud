# Copilot CLI HUD

User-level statusline and optional activity-tracking hooks for GitHub Copilot CLI on Windows and macOS. Share this repository, not your `.copilot` folder: teammates keep their own sign-in, preferences, quota and session state.

**Windows-first pilot:** intended for a small teammate rollout, not a fully verified cross-platform release. macOS support is implemented but remains provisional.

## Teammate quick start

Clone this repository or download and extract its ZIP, then open a terminal in its root. Use your own existing Copilot CLI sign-in. Setup does not sign you in, change permissions, copy credentials, modify shell profiles, or install plugins.

| Prerequisite | Windows | macOS |
|---|---|---|
| Copilot CLI | 1.0.89 or newer | 1.0.89 or newer |
| PowerShell | PowerShell 7 (`pwsh`) on `PATH` | PowerShell 7 (`brew install --cask powershell`) |
| Hook interpreter | Built-in Windows PowerShell 5.1 | Built-in Bash plus `jq` (`brew install jq`) |
| Optional Git sync | Git 2.31+; Windows 10/Server 2016+ | Git 2.31+ and `jq` |

**Windows** — from PowerShell:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Setup-Hud.ps1
```

`Bypass` applies only to this setup process, not your stored execution policy. Setup refuses restrictive organization policy and probes hooks without a process-policy override before activation. Review downloaded code before running it.

If native Windows PowerShell cannot run the hooks under your current policy, setup stops before installing them. Use `-SkipHooks` for a bridge-only activity display rather than changing organization policy; it does not disable hooks that are already active.

**macOS** — from Terminal:

```bash
pwsh -NoProfile -File ./scripts/Setup-Hud.ps1
```

**macOS native execution is not yet verified.** The implementation and native Windows/macOS CI matrix are included; Mac readiness requires a successful native runner and a live CLI restart check.

**Known Windows verification caveat:** the existing Windows PowerShell 5.1 session-start fixture intermittently missed telemetry in two local runs. Later standalone and sequential compatibility runs passed, but the cause is not established. The hook subprocesses exited silently with code 0 rather than blocking tools; the fixture correctly failed because missing activity data is not proof of a successful hook write. A successful teammate installation and live restart are still needed before calling the handoff dependable.

The first native CI attempt was blocked before either runner started by a GitHub billing/spending-limit restriction. No native runner results are claimed; local Git Bash checks do not substitute for native macOS verification.

Setup backs up touched files, preserves unrelated settings, configures the statusline, installs the optional experimental signal/quota bridge with a local opt-in, and enables absent hooks **only after silent fail-open probes pass**. It does not enable network fetching by default. It refuses to replace another statusline unless you choose `-ReplaceStatusLine`; an existing active hook configuration is kept, not automatically merged. Existing wrappers and enabled/disabled bridge/Git preferences are preserved.

Restart Copilot CLI afterward. The bridge's quota cache fills after a model call; a blank quota segment initially is normal. Recent AIU needs a complete checkpoint interval. Agent counts depend on actual matching SDK lifecycle events and can legitimately be absent. A live restart is still needed to establish real hook firing and payload schemas; synthetic probes cannot establish those.

Useful flags on either platform:

| Flag | Effect |
|---|---|
| `-CheckOnly` | Check prerequisites without installing anything |
| `-WhatIf` | Preview target/configuration changes without writing |
| `-EnableGitSync` | Explicitly opt into periodic, non-interactive upstream fetching |
| `-Basic` | Omit bridge installation; does not disable an already-installed bridge |
| `-SkipHooks` | Do not activate absent hooks; keep an existing active configuration |
| `-ReplaceStatusLine` | Explicitly replace another configured statusline |
| `-CopilotHome <absolute path>` | Use a custom home; otherwise respect `COPILOT_HOME`, then the normal user home |

**Update:** rerun the same setup command and restart CLI for bridge changes. Quota caches, daily accounting and session state are never copied from this checkout or reset. Use the most recent printed backup to undo that update; undo is per installation, not an untracked full wipe.

**Undo:** close CLI and run the exact `Uninstall-Hud.ps1` command printed by setup. It restores prior files/settings, preserves later unrelated settings edits and runtime state, and retains handlers if you edited an installer-created active hook configuration. `-WhatIf` previews undo; `-Force` overrides changed-file protection and can discard later edits.

**Disable only the bridge:** set `enabled` to `false` in `<CopilotHome>/hud-signal-bridge.json`, then restart CLI. Disable only fetching in `hud-git-sync.json`. A nonempty `COPILOT_HUD_SIGNAL_BRIDGE` environment override takes precedence (`1` enables; other values disable). User-installed extensions infer their installation home; project-discovered extensions still need explicit environment opt-in and home.

**Hook recovery:** if hooks ever block tools, use an **external shell** to rename `<CopilotHome>/hooks/session-state-hooks.json` to `session-state-hooks.json.disabled`, then restart CLI. Do not try to recover through the blocked session.

## What it displays

- Line 1: `⎇` and the repository branch when available, optional incoming/outgoing commit counts, context gauge and used/limit, quota, and session runtime.
- Line 2: session AIC total, token rate, cumulative input/output/cache totals, and line changes.
- Line 3: active agents/tools and at most one recent outcome; omitted when there is no useful activity.

The AIC value is the session total read from `ai_used.formatted`. The default HUD does not show a delta. An experimental bridge (project-scoped, or user-wide per "Default install for every session") can opt in to a `recent +… AIU` checkpoint increase after a complete busy/idle interval; it is not labeled as a prompt or turn cost. While the bridge is fresh but has no recent interval (none yet, suppressed, or expired after 2 minutes), a dim `recent —` shows in its place; when the bridge suppressed the last interval it adds a short allowlisted reason, e.g. `recent — (overlap)` (also: `incomplete`, `early usage`, `no baseline`, `no usage`, `subagent`, `reset`, `interrupted`, `ambiguous`). It is absent when no bridge state is present. Input and cache totals are not additive. Token totals (`I(total)`, `O`, `C`) and line changes use a muted palette (ANSI 256: gray 244, added 108, removed 131), identically for zero and populated values; `NO_COLOR` disables all color. Only the renderer and hooks are needed for this default HUD; the bridge is an optional add-on.

**Quota segment:** the `hud-signal-bridge` extension records the quota figures from each `assistant.usage` event into `~\.copilot\state\hud-signal-bridge\hud-quota.json`. The renderer reads that file, or the marketplace `copilot-hud` extension's `~\.copilot\hud-quota.json`, whichever is fresher (no network, no token). It shows `Quota ███████░ 91% · 32k/35k · ● on pace · ⚡820/1.4k today · 2d left` on line 1 beside the context gauge, with an 8-block bar that only fills at 100% (cyan <75%, yellow >=75%, red >=90%). Pace: assuming a Monday-Friday work week, the segment compares usage with the share of the billing period's workdays already passed (`▲+N%` ahead, `▼-N%` behind, `● on pace` within 5 points). Daily meter: at the first render of each local day the renderer stores that day's starting usage and budget (remaining allowance ÷ remaining workdays) in `~\.copilot\state\hud-quota-day.json`; `⚡spent/budget today` turns yellow at 75% and red at 100% of that budget, and re-baselines if usage drops (quota reset). Between delayed plan-counter updates it adds the shared estimate described below, marked with `~`, e.g. `⚡~435/1.3k today`. Usage before tracking begins is not reconstructed, and holidays are not modeled. Days left come from `resetDate`. The detail, pace and days-left drop first on narrow windows. The quota figures only refresh on model calls, so after 10 minutes without one the segment keeps the last value tagged with its age, e.g. `91% (3h ago)`; stale data never writes the daily baseline. The segment is hidden when no valid quota file newer than 7 days is present, or when stale data belongs to a finished billing period. Fixtures: `tests\statusline-quota-fixtures.ps1`.

### Shared daily estimate

Terminals using this renderer and the same `COPILOT_HOME` now share `state\hud-quota-estimates.json`. Each session ID has its own baseline and highest observed `ai_used.total_nano_aiu` total inside that ledger. The pending estimate is the sum of their observed growth, so switching terminals or closing one does not remove its contribution. A render without AIC data still displays the saved rollup. Activity, tool and agent state remain separately session-scoped; only quota accounting is shared. Use a separate home for each account. Other homes or machines are not included until their usage reaches the account's confirmed quota counter.

Reconciliation is deliberately conservative: any confirmed plan-counter movement clears **all** pending estimates, rather than subtracting the posted amount and assuming we know which sessions were billed. A period/entitlement change or local-day rollover also starts a new estimate checkpoint. Older quota snapshots cannot rewind that checkpoint. Repeated or regressed AIC samples never count the same growth twice; a genuine session-counter reset can therefore undercount until a new day or plan checkpoint establishes a fresh baseline. Plan updates can make the displayed estimate dip. AIU growth is only a proxy for pending quota usage, not an exact conversion to billable plan units.

Tracking starts at each terminal's first successful observation at the current checkpoint; unseen prior usage is not invented. On the first upgrade render, the current terminal's valid same-day legacy `hud-quota-est-<session>.json` baseline is carried over when its plan count matches. Legacy files are left untouched for rollback; other terminals register on their next render.

The ledger is capped at 64 sessions and 64 KiB, atomically replaced under an exclusive local file handle with **no lock wait or network call** on the render path. Registered sessions also publish bounded, atomic `state\hud-quota-pending-<date>-<session>.json` inboxes, tagged with the ledger's checkpoint generation. Inbox updates use non-waiting locks and retain their highest sample. A renderer folds in all matching inboxes, so a successfully published update survives shared-ledger contention or closing its terminal and can be saved by another; old-generation inboxes cannot revive reconciled usage. A merge reads at most 64 inboxes of 1 KiB each, and up to 32 dated inbox/lock/temporary files older than two days are pruned per update. The fixed daily baseline also has a non-waiting write lock. Contention or incomplete/corrupt accounting shows `+?`, e.g. `⚡~147+?/100 today`, instead of pretending the known amount is complete; an incomplete estimate gets attention coloring. Corruption or capacity loss remains marked until the next checkpoint; transient contention can recover on a later render. A fixed, sanitized category is written to `state\hud-quota-estimate-warning.log` when possible; no payloads, identifiers, credentials or error paths are logged. Fixtures: `tests\statusline-quota-shared-fixtures.ps1`.

### Git branch synchronization

The branch marker is a dim Unicode `⎇`; no Nerd Font is required. Optional sync information sits beside it:

```text
⎇ main                  zero incoming/outgoing counts are hidden
⎇ main ↓3               three incoming commits
⎇ main ↑2               two outgoing commits
⎇ main ↓3 ↑2            diverged from the configured upstream
⎇ main ↓3 ↑2 (12m ago)  cached information is aging
```

Incoming-only counts are cyan; outgoing counts are yellow, with extra yellow emphasis for divergence. Arrows describe commits relative to the branch's configured upstream, not instructions to automatically pull or push. Uncommitted changes are not included. Sync details drop before the branch under width pressure, and the branch still yields to context/quota if necessary.

To see it in action, start from a synchronized branch and make one local commit: `⎇ main ↑1` should appear after the next local check (about 15 seconds). Push that commit and the arrow disappears after the following check.

**Explicit opt-in:** for an already opted-in bridge, run `.\scripts\Install-Hud.ps1 -IncludeBridge -EnableGitSync`, then reload extensions or restart the CLI. This installs `%COPILOT_HOME%\hud-git-sync.json` with `{"version":1,"enabled":true}` only if that file is absent; existing options are preserved. Set `enabled` to `false` to disable background fetch and hide sync details, without disabling the signal/quota bridge. Settings and active hook configuration are not rewritten. The ordinary installer and disposable launcher do not enable Git sync.

The bridge uses the SDK's verified local-session working directory, not the extension process's cwd or a subagent's directory. It checks local counts about every 15 seconds and attempts a non-interactive fetch of the configured upstream branch about every five minutes. Linked worktrees have separate caches, while terminals share per-upstream fetch schedules and an exclusive repository-wide fetch lease. Contention does not wait; orphaned leases can be reclaimed after two minutes. Failed fetches back off to 10, 20, then at most 30 minutes, retaining the last successful fetch timestamp.

The renderer **never runs Git or performs network calls**: branch discovery reads local Git metadata, and sync reads a bounded atomic cache. No upstream shows `no upstream`; an unborn branch shows `no commits`; detached HEAD shows `⎇ detached` without arrows. Missing state shows `sync pending`, becoming `sync unavailable` after an initialization grace period. Invalid state never implies synchronization. Failed fetches show `(fetch unavailable)` alongside any counts still computable from local refs. Cached count data older than one minute, or successful fetch information older than ten minutes, gets an age label; counts can be briefly behind local changes until the next background check.

Fetches never pull, push, merge, checkout, stage, or modify the working tree. The helper disables Git hooks, automatic maintenance, tag fetching and submodule recursion, updates only the upstream remote-tracking ref, and does not rewrite `FETCH_HEAD`. Authentication is non-interactive; HTTPS credential helpers must already work unattended, and SSH uses OpenSSH batch mode. Fetch attempts have a 15-second deadline including helper startup, with up to one additional second for cleanup, and stop if the owning extension exits or the opt-in is disabled. Windows native descendants are contained in a cleanup job from process creation; timeout or helper termination closes the whole job. The macOS helper uses a dedicated process group with bounded TERM/KILL cleanup; native verification is pending. Custom broker-activated or process-group-escaping helpers are outside ordinary descendant containment. A failure does not interrupt the CLI or renderer.

Derived records live under `state\hud-git-sync`, each at most 4 KiB. Repository/worktree, branch and upstream identities are hashed; raw paths, remote URLs, hostnames, account identifiers and Git error text are not stored or displayed. Up to 32 obsolete records/temporary files are removed per update; records older than seven days or beyond the newest 128 are eligible. Warnings use fixed categories; renderer storage errors write only `state-unavailable` to `state\hud-git-sync-warning.log`. Fixtures: `tests\hud-git-sync.test.mjs` and `tests\statusline-git-fixtures.ps1`.

## Files

- `statusline\statusline.cmd`: Windows wrapper; launches the PowerShell renderer.
- `statusline\statusline.sh`: macOS wrapper for the same PowerShell renderer; neither wrapper requires executable file bits.
- `statusline\statusline.ps1`: renderer. Branch lookup is filesystem-only; Git is needed by the optional background sync updater.
- `statusline\git-sync.json`: installer template for the separate Git-sync opt-in.
- `statusline\signal-bridge.json`: installer template for the local bridge opt-in.
- `scripts\Setup-Hud.ps1`: portable prerequisite checks, backed-up settings integration and safe hook activation.
- `scripts\Install-Hud.ps1` and `scripts\Uninstall-Hud.ps1`: explicit installation options and manifest-based rollback.
- `hooks\state-hook.ps1` and `hooks\state-hook.sh`: fail-open per-session activity tracking. PowerShell hook failures remain silent to the CLI and write only a fixed, bounded marker to `state\hud-hook-failure.log` when possible.
- `hooks\session-state-hooks.json`: user hook event configuration for tool, session, error, and subagent activity.
- `.github\extensions\hud-signal-bridge`: experimental project-scoped signal bridge. It is inert unless explicitly opted in.
- `tests\hud-signal-reliability.test.mjs`, `tests\hud-signal-state-machine.test.mjs`, `tests\hud-signal-state-store.test.mjs`, `tests\hud-git-sync.test.mjs`, `tests\state-hook-powershell51-fixtures.ps1`, `tests\hud-aic-validation-inspector.ps1`, and `tests\statusline-*-fixtures.ps1`: local synthetic fixtures; none launches Copilot.

The hook configuration uses per-user paths on Windows and macOS. Runtime state is created locally under the selected home's `state` directory; do not copy state from another machine.

## Requirements

- GitHub Copilot CLI 1.0.89 or newer for teammate setup. The earlier hook configuration was validated against 1.0.88; real firing on a new installation still needs a restart.
- Full setup enables `"experimental": true` in settings for the bridge; project-only development can use `copilot --experimental`.
- PowerShell 7 (`pwsh`) on `PATH` for either statusline wrapper. The Windows hook handler supports Windows PowerShell 5.1 and PowerShell 7.
- Bash and `jq` are needed for macOS hooks; `jq` is also required for macOS Git sync.
- Node.js is needed to run the local bridge fixtures. The CLI supplies the SDK when it runs a project extension.
- Git 2.31 or newer on `PATH` is needed only for Git synchronization; PowerShell 7 runs its bounded fetch helper on Windows 10 / Windows Server 2016 or newer.

## Opt-in signal prototype

Checking out this repository does not automatically install the bridge or alter hook or statusline settings. A user-installed bridge can infer its home and uses `hud-signal-bridge.json` when there is no nonempty `COPILOT_HUD_SIGNAL_BRIDGE` override. Project discovery alone never enables it: a project extension still requires `COPILOT_HUD_SIGNAL_BRIDGE=1` and an explicitly set absolute `COPILOT_HOME`.

The renderer reads the bridge file only when the local preference or environment override enables it, the session ID matches, and the bounded state is valid and fresh. The file is written under `%COPILOT_HOME%\state\hud-signal-bridge\hud-signal-<sessionId>.json`, atomically replaced, limited to 4 KiB, and contains only its version, session ID, timestamps, a neutral phase, the most recent checkpoint difference or an allowlisted suppression code, and an optional active-subagent count capped at 16. Agent and tool-call IDs are held in memory only. Attached state is heartbeated every 5 seconds, including idle periods without a recent value, and ignored if more than 20 seconds stale. The assistant-turn-complete phase lasts 10 seconds; a recent difference or suppression reason lasts 2 minutes, then becomes `recent —` without hiding the segment or fabricating activity. Freshness timestamps never move backward. The CLI stops the extension on exit or replaces it when the foreground session changes; if the observer stops or writes continue failing, the old snapshot becomes stale and the renderer uses matching-session hook activity. A write failure resets attribution in memory before a subsequent heartbeat can retry. A lifecycle-confirmed positive agent count is demoted to unknown after 5 minutes without a matching terminal; a confirmed zero is kept authoritative for 5 minutes, then becomes unknown. Hook activity entries also expire after 5 minutes. The directory retains at most 64 state files and prunes files older than 24 hours at extension startup. On Windows it inherits the `COPILOT_HOME` directory ACL; restrictive Unix mode bits are requested where supported. By default, no event logs, prompts, responses, intent/progress text, tool names, arguments/results, transcripts, or per-call usage are written; the separate disposable diagnostic below writes only bounded count-change summaries. The renderer performs no network or GitHub/API calls.

The AIC difference is computed only from a valid prior numeric checkpoint followed by idle, a non-overlapping interval of sequential root-turn starts/ends, a later numeric checkpoint, and a subsequent `session.idle`. Sequential internal turns in the same busy interval are grouped without using `turnId` as an identity. Parallel root tools are allowed when distinct call IDs have matching starts and completions entirely inside an open root turn; concurrency alone is not an attribution overlap. The phase remains `Running tool` until the last active call completes. Tools crossing a root-turn boundary, unfinished calls, duplicate starts or unmatched progress/completions remain ambiguous. Per-call usage is ignored. The first complete interval after startup establishes a baseline and shows no difference. Missing or out-of-order boundaries, overlapping root turns, interruption, resume/context clear, counter decrease, malformed state, or any unverified subagent event suppresses the value. Explicit subagent attribution on a tool event also suppresses usage even without a lifecycle event; subagent suppression lasts until a session resume or context clear resets the machine. Missing root event IDs, malformed checkpoints, permission boundaries, and tool-call correlation failures suppress AIC attribution without clearing otherwise matched subagent identities. The display label is `recent +… AIU`; it does not claim a unique prompt or turn cost.

The bridge phase labels are `◐ Working`, `◐ Running tool`, and a brief `✓ Assistant turn complete`; idle has no line-3 phase label. The completion label describes the root assistant turn, not subagent success. The optional bridge label `◐ N subagents` is emitted only while matched `subagent.started` and terminal lifecycle events (`subagent.completed` or `subagent.failed`) support the count; each pair must agree on both the agent ID and spawning tool-call ID. A parent tool completion does not clear an agent, and a terminal event makes no task-success claim. Missing or mismatched IDs, duplicate starts, an open agent at session idle, or other ambiguous lifecycle data make the count unknown; an unclosed lifecycle is also demoted to unknown after the 5-minute lease. Resume/context clear resets prior tracking, while stale bridge state is rejected by the renderer. A fresh numeric bridge count is authoritative: positive counts replace hook-based agent displays, and confirmed zero suppresses hook-agent claims. Hook tools remain available alongside the count when width permits; the spawning `task` tool is labeled `task`, not `agent`. At width pressure, active tool activity outranks the agent count; completed-tool history is removed first and the count is dropped before active tool segments. A null, absent, malformed, disabled, or stale bridge falls back only to hook state matching the statusline session ID; those hook activity entries are also age-bounded. A hook subagent terminal is displayed as `ended` (or `failed` when explicitly reported), never as success based solely on `end_turn`. When the hook cannot tell how a subagent ended, it shows the same neutral `ended` label with a dim bullet; there is no `?`/`stopped` wording.

## Default install for every session

Use **Teammate quick start** above for Windows or macOS. The following lower-level/manual path remains for existing Windows installations. Nothing is installed in application repositories.

**Legacy file-only install.** From the repo root in Windows PowerShell 5.1 or pwsh:

```powershell
.\scripts\Install-Hud.ps1 -WhatIf                          # preview
.\scripts\Install-Hud.ps1 -IncludeBridge -SetEnvironment   # renderer, hooks, optional bridge + user variables
.\scripts\Install-Hud.ps1 -IncludeBridge -EnableGitSync    # separately opt in an existing bridge to background fetch
.\scripts\Uninstall-Hud.ps1 -BackupPath <backup folder printed by the installer> -RestoreEnvironment
```
With these legacy flags, the installer backs up every file it touches to `.copilot\backups\hud-install-<stamp>` with a SHA-256 manifest, verifies each copy, never rewrites `settings.json` or an existing `session-state-hooks.json` (it prints the `statusLine` snippet if missing, and installs an absent hook config only as `.disabled`), and leaves an existing `statusline.cmd` alone. Rollback restores files by hash, removes files the installer created, and keeps any file you edited afterward unless `-Force`. Existing quota caches, the fixed daily baseline and shared accounting state are not overwritten by installation or rollback. Then restart Copilot from a new Windows Terminal tab. The manual steps follow.

1. **Renderer and hooks** — follow "Windows installation" or "Updating an existing installation". This alone gives the muted default HUD; when bridge state is absent, stale, or invalid the HUD falls back to hook-derived activity.
2. **Bridge (optional, experimental)** — GitHub documents `%USERPROFILE%\.copilot\extensions\<name>\extension.mjs` as loading in all sessions when `"experimental": true` is set in `settings.json`. Copy all six modules (`extension.mjs`, `configuration.mjs`, `quota.mjs`, `git-sync.mjs`, `state-machine.mjs`, and `state-store.mjs`) plus `git-fetch.ps1` and `git-fetch.sh` from `.github\extensions\hud-signal-bridge` into `%USERPROFILE%\.copilot\extensions\hud-signal-bridge`, then set two user environment variables (new terminals only):

   ```powershell
   [Environment]::SetEnvironmentVariable('COPILOT_HUD_SIGNAL_BRIDGE', '1', 'User')
   [Environment]::SetEnvironmentVariable('COPILOT_HOME', "$env:USERPROFILE\.copilot", 'User')
   ```

   This legacy path uses an explicit `COPILOT_HOME`; the value above is the CLI's default location. Diagnostics, raw capture, and AIC validation stay off unless their own variables are set (leave them unset). With neither an environment opt-in nor an enabled local preference, the extension attaches idle with no listeners, so `/env` shows it Running instead of timing out, and it writes nothing. Normal bridge output is one bounded activity snapshot per session plus the shared `hud-quota.json` cache under `.copilot\state\hud-signal-bridge`. Git-sync caches and fetches require the additional opt-in described above.
3. **Verify** in a new terminal: run `copilot`, check `/env` shows `hud-signal-bridge` Running (from your user extensions, not Project), and confirm line 2 keeps the muted `I/O/C` and `+/-` colors. After a reply, the HUD may show `recent +… AIU` (an interval increase, never a prompt price) and `✓ Assistant turn complete`; agent counts appear only while subagents run.
4. **Rollback** — close Copilot CLI, delete `%USERPROFILE%\.copilot\extensions\hud-signal-bridge`, clear both variables with `SetEnvironmentVariable(name, $null, 'User')`, and restore backed-up renderer/hook files. For this environment-only legacy path, clearing `COPILOT_HUD_SIGNAL_BRIDGE` disables the bridge; if you also ran teammate setup, disable its local preference as described above.

Already-running sessions and terminals opened before the variables were set keep their old environment; restart them. Extensions are experimental and run with your privileges; keep only trusted code there.

## Repo-scoped isolated HUD launch

The launcher is limited to this Git repository and one project extension. It requires Windows PowerShell 5.1 to stage and launch, plus `pwsh` for the statusline wrapper. From the repository root, dot-source the launcher so `$copilotHome` remains available in the launching shell for inspection:

Use this only for controlled non-production verification of this `ghcp-cli-hud` tooling repository. The launcher refuses other repository roots; this is not a production deployment and does not install the extension in user-wide discovery.

Run this disposable launcher in **Windows PowerShell 5.1**, not PowerShell 7.6. The existing environment-isolation fixture passes in 5.1 but fails in 7.6, where null environment assignments leave empty strings; the launcher's isolation code is unchanged. The renderer and Git-fetch helper still require PowerShell 7.

```powershell
. .\scripts\Start-OptInHud.ps1
```

To validate the staged configuration without starting Copilot:

```powershell
. .\scripts\Start-OptInHud.ps1 -PreflightOnly
```

Each invocation creates a new home beneath `%TEMP%` and an empty `GH_CONFIG_DIR` inside it. The temporary `settings.json` contains only the repository's `statusline\statusline.cmd` and a 5-second refresh. The launcher copies `session-state-hooks.json`, `state-hook.ps1`, and `state-hook.sh` into that home's `hooks` directory and verifies that every hook command resolves through `COPILOT_HOME` to those copied files. GitHub CLI [configuration-directory documentation](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference) says `COPILOT_HOME` relocates the CLI configuration directory; its [hook documentation](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks) places user hooks under `%COPILOT_HOME%\hooks` and says hook configuration changes load at CLI startup. No normal settings, hooks, installed statusline, extensions, permission config, credentials, or tokens are copied or edited.

The child process sets `COPILOT_HUD_SIGNAL_BRIDGE=1`, `COPILOT_HUD_SIGNAL_DIAGNOSTICS=0`, `COPILOT_HUD_AIC_VALIDATION=0` by default, and `COPILOT_RAW_PAYLOAD_CAPTURE=0`. Passing `-AicValidation` opts only that child into the bounded AIC validator described below. The launcher also uses the isolated `GH_CONFIG_DIR`, clears inherited token and external provider/instruction-path variables, and starts `copilot --experimental` from this repository root. It does not pass `--allow-all` or preapprove permissions. If sign-in, trust, or permission approval is requested, stop rather than granting it. The fresh home has no saved Copilot credentials, so sign-in may be required; no credentials are copied.

The launcher refuses to run outside this repo, if any project extension besides `hud-signal-bridge` or any repository-level hooks are present, or if the temporary home is not fresh and local to `%TEMP%`. The hook configuration's PowerShell command uses `$env:COPILOT_HOME` and `Join-Path` for `hooks\state-hook.ps1`; its Bash command uses `${COPILOT_HOME:-$HOME/.copilot}` for `hooks/state-hook.sh`. Since the child receives `COPILOT_HOME`, both references resolve to the copied handlers rather than the normal user hooks. On Windows the CLI selects the PowerShell key; the Bash key is retained for schema consistency.

In the CLI, `/env` showing `hud-signal-bridge` **Running** under **Project** proves discovery, not attachment. The extension subscribes only after its joined session ID matches the process `SESSION_ID`. Verify attachment from the one fresh bridge snapshot under this launcher's exact `$copilotHome`: the ID in the filename must match the JSON `sessionId`, and the snapshot must be fresh. Do not print the ID, choose the newest among multiple session files, or combine sessions. The renderer reads only the snapshot whose ID matches its input `session_id`; a fresh matching phase or bridge agent count in the HUD confirms that the renderer consumed the bridge state. Tool labels alone may come from hooks and do not prove bridge attachment.

**Rollback:** type `/exit` in Copilot CLI. The launcher's `finally` block restores every environment variable in the launching PowerShell process, and the temporary home is deliberately retained for inspection in `$copilotHome`. Normal sessions remain unchanged and continue using the current user-level HUD. Remove the temporary home only after preserving any evidence and only by its exact `$copilotHome` path.

## Disposable Fleet transition diagnostics

The optional Fleet diagnostic is separate from the bridge snapshot and is off unless `COPILOT_HUD_SIGNAL_DIAGNOSTICS=1` is explicitly set for a disposable test process. It also requires an already-created `COPILOT_HOME` whose resolved path is beneath the operating-system temporary directory and is not the normal `%USERPROFILE%\.copilot`. If that guard fails or the diagnostic store cannot be written, the diagnostic is skipped or disabled with a sanitized warning; the bridge remains active. It never changes the renderer input or statusline behavior.

When enabled, the extension writes per-session records under `%COPILOT_HOME%\state\hud-signal-diagnostics\hud-subagent-count-changes-<sessionId>.json`. Count transitions contain exactly `atMs`, `reason`, `previousCount`, and `nextCount`; `null` means unknown, while `0` is a confirmed zero. Tool/AIC correlation failures are recorded even when the agent count is unchanged, with the same four fields plus only `rootInterval` (`absent`, `open`, `closed`), `caller` (`root`, `subagent`, `unknown`), and `parentCorrelation` (`matched`, `missing`, `unmatched`). Their fixed reasons name the tool event and failed check, such as `tool-start-root-turn-closed` or `tool-complete-unmatched-call-id`. Actual IDs are never recorded. Tool/AIC correlation failures make the AIC interval ambiguous but do not by themselves invalidate matched agent lifecycle state; unmatched or ambiguous agent lifecycle IDs, session idle with open agents, expiry, interruption, and resets remain conservative. The session ID is used only to keep the file session-scoped and does not appear in its records. No event, agent or tool-call identity, display name, task text, paths, arguments, results, prompt, or transcript is retained. Writes are atomic; each file is limited to 32 records and 4 KiB, at most 64 session files are retained, and files older than 24 hours are pruned when diagnostics start. The normal derived-state snapshot schema remains unchanged.

For one disposable diagnostic run, set `COPILOT_HUD_SIGNAL_DIAGNOSTICS=1` alongside the existing bridge opt-in only in the child process launched from a fresh temporary `COPILOT_HOME`. Do not set it in normal user settings or a user-wide extension. Read only the diagnostic file whose session ID matches the attached bridge snapshot; never select the newest file or combine sessions.

The Windows PowerShell 5.1 launcher and sanitized inspector sources are in `tests\diagnostic-kit`. They are intended for a freshly staged kit directly under `%TEMP%`; the launcher preflight does not start Copilot, and the inspector never prints session IDs. Do not point either script at the normal user home or an application repository.

## Disposable AIC checkpoint validation

The AIC validator is a separate diagnostic opt-in: pass `-AicValidation` to `scripts\Start-OptInHud.ps1`. It is enabled only in that child process and only when the bridge confirms its CLI session matches `SESSION_ID` and the temporary home is beneath `%TEMP%`, outside the normal user home. It takes an exclusive, empty lock in the fresh home so a second session cannot overwrite the record. Use one fresh launcher home for one CLI session; do not reuse it.

The validator writes one atomic record to `%COPILOT_HOME%\state\hud-aic-validation\validation.json`, with no session ID in the filename or contents. The record is replaced at each accepted baseline, completed interval, or relevant suppression, and is capped at 4 KiB. It contains only checkpoint totals, their signed difference, the exact increase supplied to the unchanged HUD snapshot, bounded root-turn counts, event-order/suppression booleans, a categorical validity, and a fixed reason. It never reads or stores prompt/response text, raw events, per-call usage, tool or agent identities, paths, credentials, or session history. It does not change the normal bridge snapshot schema or renderer output. If validation storage fails, the bridge and HUD continue; the operator check is inconclusive.

For one AIC-only operator check, start from this repository root in Windows PowerShell and set the terminal wide enough for the line-2 segment (at least 120 columns; 160 recommended):

```powershell
. .\scripts\Start-OptInHud.ps1 -AicValidation
```

The observer is a two-stage gate. First send only `Reply with exactly AIC-BASELINE. Do not use tools or subagents.` After that response completes, leave the CLI open, switch to the observer window, and press Enter. It waits up to 5 seconds for a final record newer than the observer start, then validates it against the bounded bridge snapshot. Continue only if it prints a numeric `Baseline checkpoint B=...` followed by exactly `Baseline ready; AIC-CHECK may be sent.` A first-interval `suppressed / missing-baseline` result is allowed only when it has a numeric final checkpoint, exactly one closed root turn, closed tools, a checkpoint after turn end, idle after that checkpoint, and no overlap, interruption, reset, counter reset, or unverified subagent activity. A valid first interval may also establish B. Multiple root turns are conservatively rejected because the bounded record cannot distinguish internal turns from two user prompts grouped together. If the observer prints `Stop; baseline not established.`, do not send AIC-CHECK and do not repeat AIC-BASELINE to force a pass.

Only after the baseline-ready message, send `Reply with exactly AIC-CHECK. Do not use tools or subagents.` Capture the HUD screenshot showing its line-2 recent value and line-3 completion. Keep the CLI open, switch back to the observer, and press Enter. It requires a new final record written after the baseline record, with `baselineNanoAiu` equal to B and the same verified session. Acceptance additionally requires `validity=valid`, matching non-null checkpoint arithmetic and HUD text, `matchesBridgeRecentValue=True`, fresh bridge state, a recent value within retention, closed root turns and tools, a final checkpoint after turn end, idle after that checkpoint, and no overlap, interruption, reset, counter reset, or unverified subagent activity. Compare the printed `expectedHudText` to the screenshot yourself; the inspector does not read the screen. If either stage stops or is inconclusive, do not repeat either prompt to force a pass.

The observer inherits the exact `COPILOT_HOME` from this launcher invocation; it does not search `%TEMP%` or print the home path. The inspector reads only the bounded bridge snapshot and AIC validation record in that home, rejects multiple bridge sessions, and never prints identifiers or paths. The extension has no session-end cleanup handler; the bridge snapshot and AIC validation record are separate from hook state. The copied `sessionEnd` hook removes its matching `hud-state-<sessionId>.json` and animation frame, and prunes only hook state/frames older than 24 hours; it does not remove bridge or AIC files. A hook failure writes only the fixed `hook-state-failure` marker to `state\hud-hook-failure.log` when possible; the hook still exits 0 and emits no stdout/stderr. The bridge's 5-second heartbeat updates the snapshot while attached, including idle after the recent value expires. Checking before `/exit` preserves renderer freshness, but a displayed difference must still be inspected within its 2-minute retention. After inspection, type `/exit` in the CLI and `exit` in the observer window; the launching shell environment is restored and the temporary home is retained.

## Local synthetic checks

Run the portable synthetic checks from the repository root in PowerShell 7 (the same relative paths work on both platforms):

```powershell
$files = @((Get-ChildItem -LiteralPath .\tests -Filter '*.test.mjs').FullName)
node --test @files
pwsh -NoProfile -File .\tests\statusline-signal-fixtures.ps1
pwsh -NoProfile -File .\tests\statusline-git-fixtures.ps1
pwsh -NoProfile -File .\tests\statusline-quota-fixtures.ps1
pwsh -NoProfile -File .\tests\statusline-quota-shared-fixtures.ps1
pwsh -NoProfile -File .\tests\hud-install-scripts.ps1
pwsh -NoProfile -File .\tests\hud-setup-fixtures.ps1
```

Windows-only compatibility checks:

```powershell
powershell.exe -NoProfile -File .\tests\hud-launcher-environment.ps1
powershell.exe -NoProfile -File .\tests\hud-aic-validation-inspector.ps1
powershell.exe -NoProfile -File .\tests\state-hook-powershell51-fixtures.ps1
```

`.github/workflows/hud-checks.yml` runs these on native Windows and macOS runners without authenticated CLI sessions or user-state artifacts. Setup fixtures use a version-only CLI stub, disposable homes and actual installed renderer commands; they check config-only bridge activation, quoted paths, hook probes, settings preservation, refusal/replacement and surgical rollback.

**Local Bash checks:** from the repository root in Git Bash (Windows) or Terminal (macOS):

```bash
bash ./tests/hud-bash-fixtures.sh
```

The suite needs `git`, `jq` and `pwsh`, and uses only disposable directories and local repositories. It exercises all Bash hook events, silent fail-open handling for valid/malformed/empty/unexpected input, locked state, missing jq, session cleanup isolation, the renderer wrapper at 80/120/160 columns, a real local fetch without changing HEAD/index/worktree/FETCH_HEAD, strict fetch options, and timeout/disable/owner-exit cleanup of a simulated shell transport and child.

Git Bash uses test-only adapters for Windows-native jq binary output and Windows path conversion, including names with spaces/apostrophes; production scripts are unchanged. A GNU-stat-backed shim exercises the BSD-stat fallback where GNU stat is installed. These are useful Bash logic checks, **not native macOS certification**: Git Bash is Bash/MSYS on Windows, not macOS's Bash 3.2, filesystem, PowerShell runtime, SDK environment or native Git process tree. CI's Mac step explicitly uses `/bin/bash`; a native Mac run and live CLI restart are still required.

These fixtures cover checkpoint/idle grouping, valid AIC arithmetic, multiple internal turns, missing baselines, counter resets, interruption, resume, overlap, unverified subagent attribution, recent-value expiry, AIU rounding, the two-stage baseline/check observer gate (including grouped-turn rejection, fresh-record enforcement, matching baseline B, and null-value mismatch), one-record validation retention, Windows PowerShell 5.1 hook payload/state conversion and cleanup, unrelated-session preservation, fail-open sanitized hook errors, 2→1→0 matched terminals, a five-minute missing-terminal lease, confirmed-zero expiry, sanitized reason records for every active-count transition category, diagnostic retention and session isolation, parent-tool completion before agent completion, stale/absent/malformed state, matching-session-only hook fallback, terminal labels that do not imply success, rendering widths, ANSI/`NO_COLOR`, and Fleet-count precedence alongside hook tools/history without duplicate agent claims. Reliability regressions include clean parallel root tools, tools crossing root-turn boundaries, idle heartbeats, and explicit subagent attribution. Quota fixtures cover cached thresholds and age labels, concurrent cross-terminal totals, durable inboxes, high-water deduplication, conservative reconciliation, delayed checkpoint rejection, legacy migration, bounded cleanup, and visible partial accounting after contention or corruption. Installer fixtures cover backups, hash verification, preserved settings/state, and rollback. They do not enable the extension or launch a live CLI session; fixture success does not replace a live HUD check.

The bounded operator kit is assembled separately in an unborn disposable Git workspace. Its launcher uses a fresh `COPILOT_HOME`, isolated `GH_CONFIG_DIR`, clears inherited token variables for the child process, and sets the opt-in only for that test process. Its settings are created only inside that disposable home. The kit is a live-test harness, not the installation or activation path for the personal tooling checkout.

After separately approving the disposable settings file and live run, verify the extension is **Running** under **Project** with `/env` before prompting. For the AIC/phase check, use at most one tool-free baseline request followed by one bounded read-only request that runs `Start-Sleep -Seconds 7; Get-Content -LiteralPath .\phase-probe.txt`. Stop if sign-in, trust, or tool permission is requested. If the single target interval does not produce the phase/checkpoint signals, call it inconclusive rather than repeating the prompt.

Fleet validation is a separate isolated gate. Use one fresh disposable Git workspace and temporary `COPILOT_HOME`; launch two bounded read-only subagents concurrently, one waiting 25 seconds and one 65 seconds before returning. Record the sanitized bridge count and the HUD independently at 2, 1, and confirmed 0 or unknown, and compare lines 1 and 2 across captures. A transition too brief to capture is unverified; do not send another prompt to force it. Stop if sign-in, trust, or tool permission is requested.

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

### Updating an existing installation

The renderer and hook handlers are plain files, so an update needs no settings change when `statusLine.command` already points at the installed `statusline.cmd`. Hook handlers are read on each event; the renderer runs on every refresh, so a new session or the next refresh picks it up.

For a backed-up update including an already opted-in user-wide bridge, run `.\scripts\Install-Hud.ps1 -IncludeBridge` without `-SetEnvironment`. Renderer-only changes apply on the next HUD refresh; changed bridge modules require an extension reload or CLI restart. Do not delete the daily baseline or accounting state to update the renderer.

```powershell
$base = Join-Path $env:USERPROFILE '.copilot'
$backup = Join-Path $base ('backups\hud-install-' + (Get-Date -Format yyyyMMdd-HHmmss))
New-Item -ItemType Directory -Path "$backup\statusline", "$backup\hooks" -Force | Out-Null
Copy-Item "$base\statusline\statusline.*" "$backup\statusline\"
Copy-Item "$base\hooks\state-hook.ps1" "$backup\hooks\"
Copy-Item "$base\hooks\state-hook.sh" "$backup\hooks\"
Copy-Item .\statusline\statusline.ps1 "$base\statusline\" -Force
Copy-Item .\hooks\state-hook.ps1 "$base\hooks\" -Force
Copy-Item .\hooks\state-hook.sh "$base\hooks\" -Force
```

Rollback: close Copilot CLI and copy the backed-up files over the installed ones. Verify in a fresh session that line 2 ends with muted `I … · O … · C … │ +…/-…` and that the bridge labels (`recent +… AIU`, `N subagents`) are absent unless you deliberately opted in through project discovery or the user-wide installation.

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
