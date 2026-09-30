#!/usr/bin/env bash
exec 2>/dev/null
set +e
set +u
umask 077
git_pid=""
reason="unavailable"

cleanup() {
  if [[ -n "$git_pid" ]]; then
    kill -TERM -- "-$git_pid" 2>/dev/null
    for ((step=0; step<20; step++)); do
      kill -0 -- "-$git_pid" 2>/dev/null || break
      sleep 0.05
    done
    kill -KILL -- "-$git_pid" 2>/dev/null
    wait "$git_pid" 2>/dev/null
    git_pid=""
  fi
}
trap cleanup EXIT
trap 'reason="stopped"; cleanup; printf "{\"reason\":\"%s\"}" "$reason"; exit 0' HUP INT TERM

enabled() {
  [[ -f "$options" ]] || return 1
  local size
  size="$(wc -c < "$options")" || return 1
  (( size > 0 && size <= 256 )) || return 1
  jq -se 'length == 1 and (.[0] | type == "object" and
    (keys | sort) == ["enabled","version"] and .version == 1 and
    (.enabled | type) == "boolean" and .enabled)' "$options" >/dev/null
}
now_ms() { jq -nr 'now * 1000 | floor'; }
main() {
  [[ "$#" -eq 6 ]] || return 0
  local repository="$1" remote="$2" refspec="$3" owner="$5" deadline="$6" now code
  options="$4"
  [[ "$owner" =~ ^[1-9][0-9]*$ && "$deadline" =~ ^[0-9]{1,16}$ ]] || return 0
  [[ "$remote" =~ ^[A-Za-z0-9_][A-Za-z0-9_./-]{0,127}$ ]] || return 0
  [[ "$refspec" =~ ^\+refs/heads/[^:[:space:]]+:refs/remotes/[^:[:space:]]+$ ]] || return 0
  command -v jq >/dev/null && command -v git >/dev/null || return 0
  enabled && kill -0 "$owner" 2>/dev/null || return 0
  now="$(now_ms)" || return 0
  [[ "$now" =~ ^[0-9]+$ ]] || return 0
  (( deadline > now )) || { reason="timeout"; return 0; }
  (( deadline > now + 15000 )) && deadline=$((now + 15000))
  export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS="" SSH_ASKPASS=""
  export GIT_SSH_COMMAND="ssh -oBatchMode=yes -oConnectTimeout=10" GIT_SSH_VARIANT=ssh
  # Job control gives this native transport tree its own bounded process group.
  set -m
  git -C "$repository" -c credential.interactive=false -c core.hooksPath=/dev/null \
    -c core.fsmonitor=false -c gc.auto=0 -c maintenance.auto=false \
    -c protocol.ext.allow=never -c http.lowSpeedLimit=1 -c http.lowSpeedTime=10 \
    fetch --quiet --no-tags --no-recurse-submodules --no-auto-maintenance \
    --no-write-fetch-head -- "$remote" "$refspec" </dev/null >/dev/null 2>&1 &
  git_pid="$!"
  reason="failed"
  while kill -0 "$git_pid" 2>/dev/null; do
    now="$(now_ms)" || { reason="unavailable"; break; }
    [[ "$now" =~ ^[0-9]+$ ]] || { reason="unavailable"; break; }
    (( now < deadline )) || { reason="timeout"; break; }
    enabled && kill -0 "$owner" 2>/dev/null || { reason="stopped"; break; }
    sleep 0.25
  done
  if [[ "$reason" == "failed" ]]; then
    wait "$git_pid"
    code="$?"
    (( code == 0 )) && reason="ok"
  fi
  cleanup
}
main "$@"
printf '{"reason":"%s"}' "$reason"
exit 0
