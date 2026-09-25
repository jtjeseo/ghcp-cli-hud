#!/usr/bin/env bash
# Temporary schema diagnostics only: set COPILOT_RAW_PAYLOAD_CAPTURE=1 for one run.
# Unset it afterward; captures are retained until manually removed.
exec >/dev/null 2>&1
set +e
set +u
set -o pipefail
umask 077
trap 'exit 0' HUP INT TERM

main() {

event="${1:-}"
case "$event" in
  sessionStart|sessionEnd|preToolUse|postToolUse|postToolUseFailure|errorOccurred|subagentStart|subagentStop) ;;
  *) return 0 ;;
esac

copilot_home="${COPILOT_HOME:-$HOME/.copilot}"
state_dir="$copilot_home/state"
prune_stale_files() {
  find "$state_dir" -type f \
    \( -name 'hud-state-*' -o -name '*.frame' \) \
    -mmin +1440 -print0 2>/dev/null |
    while IFS= read -r -d '' path; do rm -f "$path" 2>/dev/null || true; done
  find "$state_dir" -type d -name 'hud-state-*.json.lock' -empty -mmin +1440 -print0 2>/dev/null |
    while IFS= read -r -d '' path; do rmdir "$path" 2>/dev/null || true; done
}

if ! mkdir -p "$state_dir" 2>/dev/null; then return 0; fi
if [[ "$event" == "sessionStart" ]]; then prune_stale_files; fi
if ! command -v jq >/dev/null 2>&1; then return 0; fi

raw_tmp=""
lock_dir=""
lock_acquired=0
cleanup() {
  if [[ -n "$raw_tmp" && -f "$raw_tmp" ]]; then rm -f "$raw_tmp"; fi
  if (( lock_acquired )) && [[ -n "$lock_dir" ]]; then rmdir "$lock_dir" 2>/dev/null || true; fi
}
trap cleanup EXIT

payload="$(cat 2>/dev/null)" || return 0
if [[ -z "$payload" ]]; then return 0; fi

session_id="$(
  jq -er '[
      .sessionId
    ] | map(select(type == "string" and length > 0)) | .[0] // empty' <<<"$payload" 2>/dev/null
)"
if [[ ! "$session_id" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
  return 0
fi

if [[ "${COPILOT_RAW_PAYLOAD_CAPTURE:-}" == "1" ]]; then
  raw_file="$state_dir/raw-$event-$session_id.json"
  if [[ ! -e "$raw_file" ]]; then
    raw_tmp="$(mktemp "$state_dir/.raw-$event-$session_id.XXXXXX" 2>/dev/null)" || raw_tmp=""
    if [[ -n "$raw_tmp" ]]; then
      if printf '%s' "$payload" > "$raw_tmp" 2>/dev/null; then
        mv -n "$raw_tmp" "$raw_file" 2>/dev/null || true
      fi
      rm -f "$raw_tmp" 2>/dev/null || true
      raw_tmp=""
    fi
  fi
fi

state_file="$state_dir/hud-state-$session_id.json"
lock_dir="$state_file.lock"

file_mtime() {
  local value
  value="$(stat -c %Y -- "$1" 2>/dev/null)" || value="$(stat -f %m "$1" 2>/dev/null)" || return 1
  printf '%s' "$value"
}

if [[ -d "$lock_dir" ]]; then
  now_seconds="$(date +%s 2>/dev/null || printf '0')"
  lock_mtime="$(file_mtime "$lock_dir" 2>/dev/null || printf '0')"
  if [[ "$now_seconds" =~ ^[0-9]+$ && "$lock_mtime" =~ ^[0-9]+$ ]] &&
     (( now_seconds - lock_mtime > 120 )); then
    rmdir "$lock_dir" 2>/dev/null || true
  fi
fi

if ! mkdir "$lock_dir" 2>/dev/null; then return 0; fi
lock_acquired=1
now_ms="$(( $(date +%s 2>/dev/null || printf '0') * 1000 ))"
new_state() {
  jq -cn --arg sid "$session_id" --argjson now "$now_ms" \
    '{sessionId:$sid,createdAtMs:$now,updatedAtMs:$now,activeTools:[],recentTools:[],lastTool:null,lastError:null,activeSubagents:[],lastSubagent:null}'
}

if [[ "$event" == "sessionEnd" ]]; then
  rm -f "$state_file" "$state_dir/statusline-animation-$session_id.frame"
  prune_stale_files
  return 0
fi

if [[ "$event" == "sessionStart" || ! -s "$state_file" ]]; then
  state="$(new_state 2>/dev/null)"
else
  state="$(jq -ce --arg sid "$session_id" 'select(type == "object" and .sessionId == $sid)' "$state_file" 2>/dev/null)" || state=""
  if [[ -z "$state" ]]; then
    state="$(new_state 2>/dev/null)"
  fi
fi
if [[ -z "$state" ]]; then return 0; fi

state="$(jq -c --argjson now "$now_ms" '
  .activeTools = [
    (.activeTools | if type == "array" then . else [] end)[]
    | select(
        (.startedAtMs | type) == "number" and
        .startedAtMs <= $now and
        ($now - .startedAtMs) <= 300000
      )
  ]
' <<<"$state" 2>/dev/null)"
if [[ -z "$state" ]]; then return 0; fi

tool_name="$(
  printf '%s' "$payload" |
    jq -r 'if (.toolName | type) == "string" then .toolName else empty end' 2>/dev/null
)"
tool_lower="$(printf '%s' "$tool_name" | tr '[:upper:]' '[:lower:]')"
category=""
case "$tool_lower" in
  bash|powershell) category="shell" ;;
  create|edit|str_replace_editor|apply_patch) category="edit" ;;
  view) category="read" ;;
  glob|grep|rg) category="search" ;;
  web_fetch|web_search) category="web" ;;
  task) category="agent" ;;
  ask_user) category="prompt" ;;
  mcp__*) category="tool" ;;
esac
tool_display=""
if [[ -n "$category" ]]; then
  if [[ "$category" == "tool" ]]; then
    tool_display="tool"
  else
    tool_display="$tool_lower"
  fi
fi
tool_target="$(
  printf '%s' "$payload" |
    jq -r 'if ((.toolArgs | type) == "object" and (.toolArgs.path | type) == "string") then .toolArgs.path else empty end' 2>/dev/null
)"
tool_target="$(printf '%s' "$tool_target" | tr '\r\n\t' ' ')"
tool_target="${tool_target:0:256}"
tool_target_lower="$(printf '%s' "$tool_target" | tr '[:upper:]' '[:lower:]')"
if [[ "$tool_target_lower" =~ https?:// ]] ||
   [[ "$tool_target_lower" =~ [a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,} ]] ||
   [[ "$tool_target_lower" =~ (token|secret|password|api_key|authorization|bearer)[[:space:]]*[:=] ]] ||
   [[ "$tool_target" =~ ^[A-Fa-f0-9-]{32,}$ ]] ||
   [[ "$tool_target" =~ ^[0-9]{6,}$ ]]; then
  tool_target=""
fi

case "$event" in
  preToolUse)
    if [[ -n "$category" ]]; then
      state="$(jq -c --arg cat "$category" --arg toolName "$tool_display" --arg target "$tool_target" --argjson now "$now_ms" '
        .activeTools = (.activeTools // []) |
        . as $s |
        ($s.activeTools | map(select(.category == $cat))) as $same |
        ($same | length) as $count |
        ($same | any((.toolName // "") == "")) as $hasUnkeyed |
        ($same | any(.toolName == $toolName and $toolName != "")) as $hasDuplicateId |
        ($count > 0 and ($toolName == "" or $hasUnkeyed or $hasDuplicateId)) as $ambiguous |
        $s |
        .activeTools = (
          .activeTools
          | map(if $ambiguous and .category == $cat then .timingReliable = false else . end)
          + [{
              category:$cat,
              toolName:(if $toolName == "" then null else $toolName end),
              target:(if $target == "" then null else $target end),
              startedAtMs:$now,
              timingReliable:($ambiguous | not)
            }]
        ) |
        .updatedAtMs=$now
      ' <<<"$state" 2>/dev/null)"
    fi
    ;;
  postToolUse|postToolUseFailure)
    if [[ -n "$category" ]]; then
      state="$(jq -c --arg cat "$category" --arg toolName "$tool_display" --arg target "$tool_target" --arg event "$event" --argjson now "$now_ms" '
        .activeTools = (.activeTools // []) |
        . as $s |
        ($s.activeTools | to_entries | map(select(.value.category == $cat))) as $matches |
        ($matches | map(select(.value.toolName == $toolName and $toolName != "") | .key) | .[0]) as $idIndex |
        ($matches | map(.key) | .[0]) as $firstIndex |
        ($matches | length) as $count |
        (if $idIndex != null then $idIndex
         elif $count == 1 then $firstIndex
         elif $count > 1 then $firstIndex
         else null end) as $idx |
        ($idIndex == null and $count > 1) as $ambiguous |
        if $idx == null then $s
        else
          ($s.activeTools[$idx]) as $item |
          ($s
            | .activeTools = (
                .activeTools
                | to_entries
                | map(select(.key != $idx) | .value
                  | if $ambiguous and .category == $cat then .timingReliable = false else . end)
              )
            | .lastTool = {
                category: $cat,
                toolName: (if ($item.toolName // "") != "" then $item.toolName elif $toolName != "" then $toolName else null end),
                target: (if ($item.target // "") != "" then $item.target elif $target != "" then $target else null end),
                status: (if $event == "postToolUseFailure" then "failed" else "complete" end),
                durationMs: (
                  if ($ambiguous | not) and ($item.timingReliable // true)
                  then ([$now - ($item.startedAtMs // $now), 0] | max)
                  else null end
                ),
                completedAtMs: $now
              })
        end |
        .updatedAtMs = $now
      ' <<<"$state" 2>/dev/null)"
    fi
    ;;
  errorOccurred)
    error_context="$(
      printf '%s' "$payload" |
        jq -r '[
          (.errorContext // null),
          (.error_context // null)
        ] | map(select(type == "string" and length > 0)) | .[0] // "unknown"' 2>/dev/null
    )"
    case "$error_context" in
      model_call|tool_execution|system|user_input) ;;
      *) error_context="unknown" ;;
    esac
    recoverable="$(
      printf '%s' "$payload" |
        jq -r 'if (.recoverable | type) == "boolean" then (.recoverable | tostring) else "null" end' 2>/dev/null
    )"
    state="$(jq -c --arg context "$error_context" --arg recoverable "$recoverable" --argjson now "$now_ms" '
      .lastError = {
        context: $context,
        recoverable: (
          if $recoverable == "true" then true
          elif $recoverable == "false" then false
          else null end
        ),
        occurredAtMs: $now
      } |
      .updatedAtMs = $now
    ' <<<"$state" 2>/dev/null)"
    ;;
  subagentStart)
    agent_key="$(
      printf '%s' "$payload" |
        jq -r 'if (.agentName | type) == "string" and .agentName != "" then .agentName else "__unknown__" end' 2>/dev/null |
        tr '[:upper:]' '[:lower:]'
    )"
    agent_key="${agent_key:0:200}"
    agent_id="$(
      printf '%s' "$payload" |
        jq -r 'if (.agentId | type) == "string" then .agentId else empty end' 2>/dev/null |
        tr '[:upper:]' '[:lower:]'
    )"
    agent_id="${agent_id:0:200}"
    [[ -n "$agent_id" ]] && agent_id="id:$agent_id"
    state="$(jq -c --arg key "$agent_key" --arg agentId "$agent_id" --argjson now "$now_ms" '
      .activeSubagents = (.activeSubagents // []) |
      . as $s |
      ($s.activeSubagents | map(select(.matchKey == $key))) as $same |
      ($same | length) as $count |
      ($same | any(.agentKey == null or .agentKey == $agentId)) as $identityConflict |
      ($count > 0 and ($agentId == "" or $identityConflict)) as $ambiguous |
      $s |
      .activeSubagents = (
        .activeSubagents
        | map(if $ambiguous and .matchKey == $key then .timingReliable = false else . end)
        + [{
            matchKey: $key,
            agentKey: (if $agentId == "" then null else $agentId end),
            startedAtMs: $now,
            timingReliable: ($ambiguous | not)
          }]
      ) |
      .updatedAtMs = $now
    ' <<<"$state" 2>/dev/null)"
    ;;
  subagentStop)
    agent_key="$(
      printf '%s' "$payload" |
        jq -r 'if (.agentName | type) == "string" and .agentName != "" then .agentName else "__unknown__" end' 2>/dev/null |
        tr '[:upper:]' '[:lower:]'
    )"
    agent_key="${agent_key:0:200}"
    agent_id="$(
      printf '%s' "$payload" |
        jq -r 'if (.agentId | type) == "string" then .agentId else empty end' 2>/dev/null |
        tr '[:upper:]' '[:lower:]'
    )"
    agent_id="${agent_id:0:200}"
    [[ -n "$agent_id" ]] && agent_id="id:$agent_id"
    agent_outcome="$(
      printf '%s' "$payload" |
        jq -r '
          if .stopReason == "end_turn" then "complete"
          else "unknown" end
        ' 2>/dev/null
    )"
    [[ "$agent_outcome" == "failed" || "$agent_outcome" == "complete" ]] || agent_outcome="unknown"
    state="$(jq -c --arg key "$agent_key" --arg agentId "$agent_id" --arg outcome "$agent_outcome" --argjson now "$now_ms" '
      .activeSubagents = (.activeSubagents // []) |
      . as $s |
      ($s.activeSubagents | to_entries | map(select(.value.agentKey == $agentId and $agentId != ""))) as $idMatches |
      ($s.activeSubagents | to_entries | map(select(.value.matchKey == $key))) as $nameMatches |
      ($idMatches | length) as $idCount |
      ($nameMatches | length) as $nameCount |
      ($s.activeSubagents | length) as $total |
      (if $idCount == 1 then $idMatches[0].key
       elif $nameCount > 0 then $nameMatches[0].key
       elif $total == 1 then 0
       else null end) as $idx |
      ($nameCount > 1 and $idCount != 1) as $ambiguous |
      if $idx == null then $s
      else
        ($s.activeSubagents[$idx]) as $item |
        ($s
          | .activeSubagents = (
              .activeSubagents
              | to_entries
              | map(select(.key != $idx) | .value
                | if $ambiguous and .matchKey == $key then .timingReliable = false else . end)
            )
          | .lastSubagent = {
              matchKey: $item.matchKey,
              status: $outcome,
              durationMs: (
                if ($ambiguous | not) and ($item.timingReliable // true)
                then ([$now - ($item.startedAtMs // $now), 0] | max)
                else null end
              ),
              completedAtMs: $now
            })
      end |
      .updatedAtMs = $now
    ' <<<"$state" 2>/dev/null)"
    ;;
  sessionStart)
    ;;
esac

if [[ ( "$event" == "postToolUse" || "$event" == "postToolUseFailure" ) && -n "$category" ]]; then
  state="$(jq -c --arg cat "$category" --arg toolName "$tool_display" --arg target "$tool_target" --arg event "$event" --argjson now "$now_ms" '
    . as $s |
    ($s.lastTool // {}) as $last |
    ($s.recentTools | if type == "array" then . else [] end) as $history |
    $s |
    .recentTools = (
      [
        $history[]
        | select(
            type == "object" and
            (.completedAtMs | type) == "number" and
            .completedAtMs <= $now and
            ($now - .completedAtMs) <= 120000
          )
      ] + [{
        category: $cat,
        toolName: (
          if $last.completedAtMs == $now and $last.category == $cat and ($last.toolName // "") != "" then $last.toolName
          elif $toolName != "" then $toolName
          else null end
        ),
        target: (
          if $last.completedAtMs == $now and $last.category == $cat and ($last.target // "") != "" then $last.target
          elif $target != "" then $target
          else null end
        ),
        status: (if $event == "postToolUseFailure" then "failed" else "complete" end),
        completedAtMs: $now
      }] | .[-64:]
    ) |
    .updatedAtMs = $now
  ' <<<"$state" 2>/dev/null)"
fi

if [[ -z "$state" ]]; then
  return 0
fi

temporary_file="$state_file.$$.$RANDOM.tmp"
if ! printf '%s\n' "$state" > "$temporary_file" ||
   ! mv -f "$temporary_file" "$state_file"; then
  rm -f "$temporary_file"
  return 0
fi

return 0
}

main "$@" || true
exit 0
