#!/usr/bin/env bash
set -euo pipefail
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
for program in jq git pwsh; do
  command -v "$program" >/dev/null || { printf 'Missing prerequisite: %s\n' "$program" >&2; exit 1; }
done
root="$(mktemp -d "${TMPDIR:-/tmp}/hud-bash-fixture.XXXXXX")"
root="$(CDPATH= cd -- "$root" && pwd)"
cleanup() {
  local file pid
  if [[ -n "${helper:-}" ]]; then
    kill -TERM "$helper" 2>/dev/null || true
    wait "$helper" 2>/dev/null || true
  fi
  if [[ -n "${owner:-}" ]]; then
    kill -TERM "$owner" 2>/dev/null || true
    wait "$owner" 2>/dev/null || true
  fi
  for file in "$root/leader.pid" "$root/child.pid"; do
    if [[ -s "$file" ]]; then
      pid="$(cat "$file")"
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then kill -KILL "$pid" 2>/dev/null || true; fi
    fi
  done
  case "$root" in */hud-bash-fixture.*) rm -rf -- "$root" ;; esac
}
trap cleanup EXIT
home="$root/a teammate's home"
mkdir -p "$home/state" "$root/bin"
export COPILOT_RAW_PAYLOAD_CAPTURE=0
hook="$repo/hooks/state-hook.sh"
fetch="$repo/.github/extensions/hud-signal-bridge/git-fetch.sh"
shell_host="${BASH:-/bin/bash}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    export HUD_BASH_TEST_JQ="$(command -v jq)"
    export HUD_BASH_TEST_PWSH="$(command -v pwsh)"
    cat > "$root/bin/jq" <<'EOF'
#!/usr/bin/env bash
args=()
for argument in "$@"; do
  if [[ "$argument" == /* && -e "$argument" ]]; then
    argument="$(cygpath -w "$argument")"
  fi
  args+=("$argument")
done
MSYS2_ARG_CONV_EXCL='*' exec "$HUD_BASH_TEST_JQ" -b "${args[@]}"
EOF
    cat > "$root/bin/pwsh" <<'EOF'
#!/usr/bin/env bash
args=()
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-File" ]]; then argument="$(cygpath -w "$argument")"; fi
  args+=("$argument")
  previous="$argument"
done
if [[ -n "${COPILOT_HOME:-}" ]]; then export COPILOT_HOME="$(cygpath -w "$COPILOT_HOME")"; fi
MSYS2_ARG_CONV_EXCL='*' exec "$HUD_BASH_TEST_PWSH" "${args[@]}"
EOF
    chmod +x "$root/bin/jq" "$root/bin/pwsh"
    export PATH="$root/bin:$PATH"
    printf 'Environment=Git Bash/MSYS; native jq/Powershell path and output adapters enabled\n'
    ;;
  *) printf 'Environment=native POSIX\n' ;;
esac

assert_json() { jq -e "$2" "$1" >/dev/null || { printf 'Assertion failed: %s\n' "$3" >&2; exit 1; }; }
silent_hook() {
  local label="$1" event="$2" payload="$3" status=0
  printf '%s' "$payload" | COPILOT_HOME="$home" "$shell_host" "$hook" "$event" \
    > "$root/hook.out" 2> "$root/hook.err" || status=$?
  [[ "$status" == 0 && ! -s "$root/hook.out" && ! -s "$root/hook.err" ]] ||
    { printf 'Hook failed: %s\n' "$label" >&2; exit 1; }
  printf 'Hook=%s; exit=0; stdout=empty; stderr=empty\n' "$label"
}
state="$home/state/hud-state-bash-fixture.json"
session='{"sessionId":"bash-fixture","cwd":"","reason":"fixture"}'
tool='{"sessionId":"bash-fixture","toolName":"view","toolArgs":{"path":"fixture.txt"}}'
agent='{"sessionId":"bash-fixture","agentName":"fixture-agent","agentId":"fixture-agent-id","stopReason":"end_turn"}'
silent_hook session-start sessionStart "$session"
assert_json "$state" '.sessionId == "bash-fixture" and (.activeTools | length) == 0' 'session state missing'
silent_hook valid preToolUse "$tool"
assert_json "$state" '(.activeTools | length) == 1 and .activeTools[0].toolName == "view"' 'valid tool was not recorded'
silent_hook malformed preToolUse '{malformed'
silent_hook empty preToolUse ''
silent_hook unexpected-tool preToolUse '{"sessionId":"bash-fixture","toolName":"unexpected","toolArgs":null}'
silent_hook tool-complete postToolUse "$tool"
assert_json "$state" '(.activeTools | length) == 0 and .lastTool.status == "complete"' 'tool completion missing'
silent_hook failing-tool-start preToolUse "$tool"
silent_hook tool-failure postToolUseFailure "$tool"
assert_json "$state" '.lastTool.status == "failed" and .recentTools[-1].status == "failed"' 'failed outcome missing'
silent_hook error errorOccurred '{"sessionId":"bash-fixture","errorContext":"tool_execution","recoverable":true}'
assert_json "$state" '.lastError.context == "tool_execution" and .lastError.recoverable == true' 'error context missing'
silent_hook agent-start subagentStart "$agent"
assert_json "$state" '(.activeSubagents | length) == 1' 'agent start missing'
silent_hook agent-stop subagentStop "$agent"
assert_json "$state" '(.activeSubagents | length) == 0 and .lastSubagent != null' 'agent stop missing'

cp "$state" "$root/before-lock.json"
mkdir "$state.lock"
silent_hook locked-state preToolUse "$tool"
cmp -s "$state" "$root/before-lock.json" || { printf 'Locked state changed\n' >&2; exit 1; }
rmdir "$state.lock"
export HUD_BASH_TEST_STAT="$(command -v stat)"
if "$HUD_BASH_TEST_STAT" -c %Y "$home" >/dev/null 2>&1; then
  mkdir "$root/bsd-stat"
  cat > "$root/bsd-stat/stat" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-f" && "$2" == "%m" ]] || exit 1
exec "$HUD_BASH_TEST_STAT" -c %Y -- "$3"
EOF
  chmod +x "$root/bsd-stat/stat"
  mkdir "$state.lock"
  touch -t 200001010000 "$state.lock"
  PATH="$root/bsd-stat:$PATH" silent_hook bsd-stat-fallback preToolUse "$tool"
  assert_json "$state" '(.activeTools | length) == 1' 'BSD-stat fallback did not reclaim stale lock'
  silent_hook bsd-fallback-complete postToolUse "$tool"
fi
mkdir "$root/no-jq"
ln -s "$(command -v mkdir)" "$root/no-jq/mkdir"
PATH="$root/no-jq" silent_hook missing-jq preToolUse "$tool"
printf 'keep' > "$home/state/hud-state-foreign.json"
printf 'remove' > "$home/state/statusline-animation-bash-fixture.frame"
silent_hook session-end sessionEnd "$session"
[[ ! -e "$state" && ! -e "$home/state/statusline-animation-bash-fixture.frame" &&
  -f "$home/state/hud-state-foreign.json" ]] || { printf 'Session cleanup isolation failed\n' >&2; exit 1; }

mkdir -p "$home/statusline" "$home/state/hud-signal-bridge"
cp "$repo/statusline/statusline.sh" "$repo/statusline/statusline.ps1" "$home/statusline/"
printf '{"version":1,"enabled":true}' > "$home/hud-signal-bridge.json"
for width in 80 120 160; do
  now="$(jq -nr 'now * 1000 | floor')"
  jq -cn --argjson now "$now" '{version:1,sessionId:"bash-fixture",updatedAtMs:$now,
    phase:"working",phaseAtMs:$now,recentIncreaseNanoAiu:2000000000,recentAtMs:$now,
    activeSubagentCount:0}' > "$home/state/hud-signal-bridge/hud-signal-bash-fixture.json"
  printf '{"session_id":"bash-fixture","terminal_width":%s,"context_window":{"last_call_input_tokens":100000,"context_window_size":200000}}\n' "$width" |
    env -u COPILOT_HOME -u COPILOT_HUD_SIGNAL_BRIDGE NO_COLOR=1 \
      "$shell_host" "$home/statusline/statusline.sh" > "$root/render.out" 2> "$root/render.err"
  [[ ! -s "$root/render.err" ]] && grep -q 'Working' "$root/render.out" &&
    grep -q 'recent +2.00 AIU' "$root/render.out" &&
    grep -q '█' "$root/render.out" || { printf 'Installed Bash wrapper failed at %s columns\n' "$width" >&2; exit 1; }
  printf 'Wrapper=%s columns; UTF-8 gauge=present; inferred-home/config-only bridge=passed\n' "$width"
done

fixture_git() {
  git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name='HUD Fixture' \
    -c user.email=hud-fixture@example.invalid "$@"
}
fixture_git init --quiet --bare --initial-branch=main "$root/origin"
fixture_git init --quiet --initial-branch=main "$root/work"
printf 'baseline' > "$root/work/file.txt"
fixture_git -C "$root/work" add file.txt
fixture_git -C "$root/work" commit --quiet -m baseline
fixture_git -C "$root/work" remote add origin "$root/origin"
fixture_git -C "$root/work" push --quiet --set-upstream origin main
fixture_git -C "$root/work" fetch --quiet origin
fixture_git clone --quiet "$root/origin" "$root/peer"
printf 'incoming' >> "$root/peer/file.txt"
fixture_git -C "$root/peer" commit --quiet -am incoming
fixture_git -C "$root/peer" push --quiet origin main
head_before="$(fixture_git -C "$root/work" rev-parse HEAD)"
cp "$root/work/.git/index" "$root/index.before"
cp "$root/work/.git/FETCH_HEAD" "$root/fetch-head.before"
cp "$root/work/file.txt" "$root/worktree.before"
options="$root/options.json"
printf '{"version":1,"enabled":true}' > "$options"
run_fetch() {
  local deadline="$1" expected="$2" status=0
  "$shell_host" "$fetch" "$root/work" origin '+refs/heads/main:refs/remotes/origin/main' \
    "$options" "$$" "$deadline" > "$root/fetch.out" 2> "$root/fetch.err" || status=$?
  [[ "$status" == 0 && ! -s "$root/fetch.err" ]] || { printf 'Fetch helper host failed\n' >&2; exit 1; }
  jq -e --arg reason "$expected" 'type == "object" and keys == ["reason"] and .reason == $reason' \
    "$root/fetch.out" >/dev/null || { printf 'Unexpected fetch result; expected=%s\n' "$expected" >&2; exit 1; }
}
run_fetch "$(jq -nr 'now * 1000 + 15000 | floor')" ok
[[ "$(fixture_git -C "$root/work" rev-list --count HEAD..origin/main)" == 1 &&
  "$(fixture_git -C "$root/work" rev-parse HEAD)" == "$head_before" ]] &&
  cmp -s "$root/work/.git/index" "$root/index.before" &&
  cmp -s "$root/work/.git/FETCH_HEAD" "$root/fetch-head.before" &&
  cmp -s "$root/work/file.txt" "$root/worktree.before" || { printf 'Fetch modified working state\n' >&2; exit 1; }
printf 'Fetch=real local upstream; incoming=1; HEAD/index/worktree/FETCH_HEAD=unchanged\n'
for invalid in '{"version":1,"enabled":false}' '{malformed' \
  '{"version":1,"enabled":true}{"version":1,"enabled":true}' \
  '{"version":1,"enabled":true,"extra":0}'; do
  printf '%s' "$invalid" > "$options"
  run_fetch "$(jq -nr 'now * 1000 + 15000 | floor')" unavailable
done
printf '{"version":1,"enabled":true}' > "$options"
run_fetch 1 timeout
printf 'Fetch guards=disabled/malformed/multiple objects/extra keys/expired deadline passed\n'

mkdir "$root/stalled-git"
export HUD_BASH_TEST_LEADER="$root/leader.pid" HUD_BASH_TEST_CHILD="$root/child.pid"
cat > "$root/stalled-git/git" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$$" > "$HUD_BASH_TEST_LEADER"
sleep 60 &
child="$!"
printf '%s' "$child" > "$HUD_BASH_TEST_CHILD"
trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 0' TERM INT HUP
wait "$child"
EOF
chmod +x "$root/stalled-git/git"
processes_stopped() {
  [[ -s "$HUD_BASH_TEST_LEADER" && -s "$HUD_BASH_TEST_CHILD" ]] ||
    { printf 'Simulated transport did not start\n' >&2; exit 1; }
  local pid
  for file in "$HUD_BASH_TEST_LEADER" "$HUD_BASH_TEST_CHILD"; do
    pid="$(cat "$file")"
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      printf 'Simulated process remained alive\n' >&2
      exit 1
    fi
  done
  rm -f "$HUD_BASH_TEST_LEADER" "$HUD_BASH_TEST_CHILD"
}
PATH="$root/stalled-git:$PATH" run_fetch "$(jq -nr 'now * 1000 + 3500 | floor')" timeout
processes_stopped
PATH="$root/stalled-git:$PATH" "$shell_host" "$fetch" "$root/work" origin \
  '+refs/heads/main:refs/remotes/origin/main' "$options" "$$" \
  "$(jq -nr 'now * 1000 + 15000 | floor')" > "$root/fetch.out" 2> "$root/fetch.err" &
helper="$!"
for ((attempt=0; attempt<100; attempt++)); do
  [[ -s "$HUD_BASH_TEST_CHILD" ]] && break
  sleep 0.05
done
printf '{"version":1,"enabled":false}' > "$options"
wait "$helper"
helper=""
assert_json "$root/fetch.out" '.reason == "stopped"' 'disabled fetch did not stop'
[[ ! -s "$root/fetch.err" ]] || { printf 'Disabled fetch wrote stderr\n' >&2; exit 1; }
processes_stopped
printf '{"version":1,"enabled":true}' > "$options"
sleep 60 &
owner="$!"
PATH="$root/stalled-git:$PATH" "$shell_host" "$fetch" "$root/work" origin \
  '+refs/heads/main:refs/remotes/origin/main' "$options" "$owner" \
  "$(jq -nr 'now * 1000 + 15000 | floor')" > "$root/fetch.out" 2> "$root/fetch.err" &
helper="$!"
for ((attempt=0; attempt<100; attempt++)); do
  [[ -s "$HUD_BASH_TEST_CHILD" ]] && break
  sleep 0.05
done
kill -TERM "$owner"
wait "$owner" 2>/dev/null || true
owner=""
wait "$helper"
helper=""
assert_json "$root/fetch.out" '.reason == "stopped"' 'owner exit did not stop fetch'
[[ ! -s "$root/fetch.err" ]] || { printf 'Owner-exit fetch wrote stderr\n' >&2; exit 1; }
processes_stopped
printf 'Process groups=timeout, disable and owner exit killed simulated shell transport plus child\n'
printf 'BashFixturesPass=True; native macOS SDK/setup/filesystem/native-Git containment still require a Mac\n'
