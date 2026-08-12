#!/usr/bin/env bash
# Stage tracker for the autodev-implement plugin (Linux / macOS).
#
# Invoked by hooks.json for four hook events. Reads the hook payload as JSON on stdin and
# writes exactly one JSON object to stdout.
#
#   subagentStart - record that an implementation stage was invoked; increment its attempt
#                   counter; refresh the milestone count from the todo list.
#   subagentStop  - parse the sub-agent's verdict, record it, advance the milestone machine,
#                   log the sub-agent's full response, and append a tracker footer to the
#                   response the orchestrator receives.
#   agentStop     - block the orchestrator from ending its turn mid-run. The USER-REVIEW
#                   checkpoint is deliberately exempt: waiting for the human is the point.
#   preToolUse    - deny ask_user during autonomous phases, deny out-of-order sub-agent
#                   invocations, and deny further invocations once a budget is spent.
#
# Enforcement state lives outside the workspace, keyed by session. A mirror of it, the audit
# trail and the feedback log are written into '<session cwd>/.autodev/' so a developer can watch
# a run in progress and read the reviews afterwards, next to the plan and todo list.
#
# Milestone *structure* (how many milestones exist) is read from '.autodev/todos.md', which is
# the only place it can come from. Milestone *progress* is driven entirely by this script's
# out-of-workspace counters, so editing the todo list cannot skip a review.
#
# SAFETY: preToolUse command hooks are fail-closed - any non-zero exit or crash denies the
# tool call. A bug here would permanently break ask_user, so this script never uses `set -e`,
# always prints valid JSON, and always exits 0.
#
# Requires jq. If jq is unavailable the script degrades to a no-op rather than failing, which
# disables enforcement but never breaks the session.

EVENT_NAME="${1:-}"

emit_empty() { printf '{}\n'; exit 0; }

# Any unexpected exit path still produces valid JSON.
trap 'printf "{}\n" 2>/dev/null; exit 0' ERR

command -v jq >/dev/null 2>&1 || emit_empty

RAW_INPUT="$(cat 2>/dev/null)"
[ -n "$RAW_INPUT" ] || emit_empty
printf '%s' "$RAW_INPUT" | jq -e . >/dev/null 2>&1 || emit_empty

# Review loops (code review per milestone, security, privacy). Per pass.
MAX_REVIEW_ATTEMPTS=10
# Worker retries (tasking, implementation of one milestone). Per pass.
MAX_WORKER_ATTEMPTS=5
# Kept below the CLI's own 8-block runaway guard so we surrender first.
MAX_BLOCKS=5
# Absolute ceiling across every stage, as a base plus a per-milestone allowance. It must stay
# above what a legitimate run can spend, or it would fire before the per-stage budgets could and
# would silently become the real limit -- which would strand a large plan half-implemented, and
# leaving work undone is the one outcome this workflow exists to prevent. The per-milestone
# worst case is 1 implementation + MAX_REVIEW_ATTEMPTS reviews + MAX_REVIEW_ATTEMPTS fixes = 21,
# and the fixed overhead is tasking plus the security and privacy loops = 41.
TOTAL_INVOCATIONS_BASE=120
TOTAL_INVOCATIONS_PER_MILESTONE=30

json_get() { printf '%s' "$RAW_INPUT" | jq -r "$1 // \"\"" 2>/dev/null; }

SESSION_ID="$(json_get '.sessionId')"
SESSION_CWD="$(json_get '.cwd')"

COPILOT_HOME_DIR="${COPILOT_HOME:-$HOME/.copilot}"
STATE_DIR="$COPILOT_HOME_DIR/autodev-implement/stages"

if [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
  VIEW_DIR="$SESSION_CWD/.autodev"
else
  VIEW_DIR="$STATE_DIR"
fi

# Called only once a real autodev-implement sub-agent has been identified, so directories appear
# exactly when the workflow starts using them. Creating them eagerly would litter an empty
# '.autodev' into any repository where an unrelated session happened to call the task tool.
ensure_dir() { [ -d "$1" ] || mkdir -p "$1" 2>/dev/null; }

# Defend against path traversal via a hostile session id.
SAFE_SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$SAFE_SESSION_ID" ] || SAFE_SESSION_ID="unknown-session"

STATE_PATH="$STATE_DIR/$SAFE_SESSION_ID.json"
MIRROR_PATH="$VIEW_DIR/implement-status.json"
AUDIT_PATH="$VIEW_DIR/implement-gate-audit.md"
FEEDBACK_PATH="$VIEW_DIR/implement-feedback-log.md"
TODO_PATH="$VIEW_DIR/todos.md"

default_state() {
  jq -n --arg sid "$SAFE_SESSION_ID" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
    sessionId: $sid, createdAt: $now, updatedAt: $now,
    blocks: 0, totalInvocations: 0,
    taskingAttempts: 0, taskingVerdict: "pending",
    milestoneCount: 0, currentMilestone: 0, completedMilestones: 0,
    implementAttempts: 0, implementVerdict: "pending",
    reviewAttempts: 0, reviewVerdict: "pending",
    fixInvocations: 0, userReviewReached: 0,
    securityAttempts: 0, securityVerdict: "pending",
    privacyAttempts: 0, privacyVerdict: "pending",
    cappedMilestones: ""
  }'
}

read_state_file() {
  local path="$1" snapshot owner
  [ -f "$path" ] || return 1
  # Capture one immutable snapshot. Reopening the shared workspace mirror for validation,
  # ownership and merge would let another session atomically replace it between those reads.
  snapshot="$(cat "$path" 2>/dev/null)" || return 1
  [ -n "$snapshot" ] || return 1
  printf '%s' "$snapshot" | jq -e . >/dev/null 2>&1 || return 1
  owner="$(printf '%s' "$snapshot" | jq -r '.sessionId // ""' 2>/dev/null)"
  [ "$owner" = "$SAFE_SESSION_ID" ] || return 1
  # Reject semantic corruption before it reaches shell arithmetic. Missing fields are allowed
  # for legacy state and are supplied by default_state; present counters must be non-negative
  # integers (JSON numbers or legacy numeric strings), and verdicts must be known values.
  printf '%s' "$snapshot" | jq -e '
    def nonnegint:
      (type == "number"
       and . >= 0 and . <= 2147483647 and floor == .
       and (tostring | test("^[0-9]+$")))
      or (type == "string"
          and test("^[0-9]+$")
          and (tonumber <= 2147483647));
    def counter_ok($key): (has($key) | not) or (.[$key] | nonnegint);
    def worker_ok($key):
      (has($key) | not)
      or (.[$key] | type == "string" and
          (. == "pending" or . == "running" or . == "DONE" or . == "BLOCKED"));
    def review_ok($key):
      (has($key) | not)
      or (.[$key] | type == "string" and
          (. == "pending" or . == "running" or . == "PASS" or . == "ISSUES"));
    counter_ok("blocks")
    and counter_ok("totalInvocations")
    and counter_ok("taskingAttempts")
    and counter_ok("milestoneCount")
    and counter_ok("currentMilestone")
    and counter_ok("completedMilestones")
    and counter_ok("implementAttempts")
    and counter_ok("reviewAttempts")
    and counter_ok("fixInvocations")
    and counter_ok("userReviewReached")
    and counter_ok("securityAttempts")
    and counter_ok("privacyAttempts")
    and worker_ok("taskingVerdict")
    and worker_ok("implementVerdict")
    and review_ok("reviewVerdict")
    and review_ok("securityVerdict")
    and review_ok("privacyVerdict")
  ' >/dev/null 2>&1 || return 1
  # Merge over defaults so a partial or older state file still yields every field.
  jq -s '.[0] * .[1]' <(default_state) <(printf '%s' "$snapshot") 2>/dev/null
}

read_state() {
  local recovered
  if recovered="$(read_state_file "$STATE_PATH")"; then
    printf '%s' "$recovered"
    return
  fi
  # The workspace copy is also a recovery checkpoint. If the authoritative directory is deleted
  # mid-run, restore an exact session-id match rather than treating the next sub-agent as the
  # start of a new run and erasing the prior audit and feedback.
  if [ "$MIRROR_PATH" != "$STATE_PATH" ] && recovered="$(read_state_file "$MIRROR_PATH")"; then
    printf '%s' "$recovered"
    return
  fi
  default_state
}

write_state() {
  # Write then rename, so a concurrent reader never observes a half-written file. A torn read
  # would be treated as absent state, which would silently switch enforcement off. The temp
  # name includes the PID so two concurrent writers cannot clobber each other's temp file.
  local tmp="$STATE_PATH.$$.tmp" serialized
  serialized="$(printf '%s' "$1" \
    | jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.updatedAt = $now' 2>/dev/null)" ||
    serialized="$1"
  printf '%s' "$serialized" > "$tmp" 2>/dev/null &&
    mv -f "$tmp" "$STATE_PATH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  # Human-facing copy and recovery checkpoint. Normal enforcement always reads the authoritative
  # path first; this is consulted only when that file is missing or corrupt. It must be atomic
  # too -- a torn checkpoint is indistinguishable from no recovery state.
  if [ "$MIRROR_PATH" != "$STATE_PATH" ]; then
    local mirror_tmp="$MIRROR_PATH.$$.tmp"
    printf '%s' "$serialized" > "$mirror_tmp" 2>/dev/null &&
      mv -f "$mirror_tmp" "$MIRROR_PATH" 2>/dev/null
    rm -f "$mirror_tmp" 2>/dev/null
  fi
  return 0
}

state_num() {
  local v
  v="$(printf '%s' "$1" | jq -r ".$2 // 0" 2>/dev/null)"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *)           printf '%s' "$v" ;;
  esac
}
state_str() { printf '%s' "$1" | jq -r ".$2 // \"pending\"" 2>/dev/null; }
state_text() { printf '%s' "$1" | jq -r ".$2 // \"\"" 2>/dev/null; }

add_audit_row() {
  local stage="$1" milestone="$2" attempt="$3" action="$4" verdict="$5" session_marker
  session_marker="Session: \`$SAFE_SESSION_ID\`"
  if [ ! -f "$AUDIT_PATH" ]; then
    {
      printf '# autodev-implement stage audit\n\n'
      printf '%s\n' "$session_marker"
      printf 'Started: %s\n\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
      printf 'Every row below was written by a hook observing a real sub-agent lifecycle event.\n'
      printf 'The orchestrator does not write this file and is instructed not to edit it, but it\n'
      printf 'lives in your workspace, so treat it as a record rather than as proof.\n\n'
      printf '| Time (UTC) | Stage | Milestone | Attempt | Event | Verdict |\n'
      printf '| --- | --- | --- | --- | --- | --- |\n'
    } > "$AUDIT_PATH" 2>/dev/null
  elif ! grep -Fqx "$session_marker" "$AUDIT_PATH" 2>/dev/null; then
    {
      printf '\n---\n\n'
      printf '%s\n' "$session_marker"
      printf 'Started: %s\n\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
      printf '| Time (UTC) | Stage | Milestone | Attempt | Event | Verdict |\n'
      printf '| --- | --- | --- | --- | --- | --- |\n'
    } >> "$AUDIT_PATH" 2>/dev/null
  fi
  printf '| %s | %s | %s | %s | %s | %s |\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%S')" "$stage" "$milestone" "$attempt" "$action" "$verdict" \
    >> "$AUDIT_PATH" 2>/dev/null
  # Auditability must never control enforcement. A missing/read-only workspace still gets the
  # block or deny response derived from authoritative state.
  return 0
}

add_feedback_entry() {
  local stage="$1" milestone="$2" attempt="$3" verdict="$4" response="$5" session_marker label
  session_marker="Session: \`$SAFE_SESSION_ID\`"
  if [ ! -f "$FEEDBACK_PATH" ]; then
    {
      printf '# autodev-implement sub-agent feedback log\n\n'
      printf '%s\n' "$session_marker"
      printf 'Started: %s\n\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
      printf "Each entry is a sub-agent's verbatim response, captured by a hook as the sub-agent\n"
      printf 'finished. The orchestrator does not write this file and is instructed not to edit it,\n'
      printf 'so it records what the sub-agents actually said rather than what the orchestrator\n'
      printf 'chose to relay. It lives in your workspace and is not read back by the stage\n'
      printf 'tracker, so editing it changes nothing except this record.\n'
    } > "$FEEDBACK_PATH" 2>/dev/null
  elif ! grep -Fqx "$session_marker" "$FEEDBACK_PATH" 2>/dev/null; then
    {
      printf '\n---\n\n'
      printf '%s\n' "$session_marker"
      printf 'Started: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    } >> "$FEEDBACK_PATH" 2>/dev/null
  fi
  [ -n "$response" ] || response='_(the sub-agent returned no content)_'
  label="$stage"
  if [ -n "$milestone" ] && [ "$milestone" != "-" ]; then
    label="$stage (milestone $milestone)"
  fi
  {
    printf '\n---\n\n'
    # Level 1: sub-agents use '##' and '###' for their own sections, so an entry header at the
    # same level would be indistinguishable from the content it introduces.
    printf '# %s - attempt %s - %s\n\n' "$label" "$attempt" "$verdict"
    printf '_%s_\n\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    printf '%s\n' "$response"
  } >> "$FEEDBACK_PATH" 2>/dev/null
  # The sub-agent response and verdict must still reach the orchestrator even when the workspace
  # log cannot be written.
  return 0
}

# toolArgs arrives as a JSON *string* rather than an object, so it needs a second parse.
get_task_agent_type() {
  printf '%s' "$RAW_INPUT" \
    | jq -r '(.toolArgs // "") | if type == "string" then (fromjson? // {}) else . end
             | .agent_type // ""' 2>/dev/null
}

# agentName arrives namespaced, e.g. "autodev-implement:autodev-code-review". The match is
# anchored and pinned to this plugin's namespace, because a suffix match would also capture
# another installed plugin's "other:autodev-code-review" and let it mutate this run's counters.
# An unnamespaced name is still accepted so the tracker keeps working if the agents are ever
# loaded without a namespace; only a *different* namespace is rejected.
#
# Matching on the full trailing name is also what keeps 'code-review' from swallowing
# 'code-security-review', and what keeps this plugin from capturing autodev-plan's
# 'autodev-security-review'.
resolve_agent() {
  local name
  name="$(printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$name" in
    autodev-tasking|autodev-implement:autodev-tasking)
      printf 'tasking' ;;
    autodev-implementation|autodev-implement:autodev-implementation)
      printf 'implementation' ;;
    autodev-code-review|autodev-implement:autodev-code-review)
      printf 'code-review' ;;
    autodev-code-fix|autodev-implement:autodev-code-fix)
      printf 'code-fix' ;;
    autodev-code-security-review|autodev-implement:autodev-code-security-review)
      printf 'code-security-review' ;;
    autodev-code-privacy-review|autodev-implement:autodev-code-privacy-review)
      printf 'code-privacy-review' ;;
    *)
      printf '' ;;
  esac
}

# 'review' agents return PASS/ISSUES; 'worker' agents return DONE/BLOCKED.
get_agent_kind() {
  case "$1" in
    code-review|code-security-review|code-privacy-review) printf 'review' ;;
    *)                                                    printf 'worker' ;;
  esac
}

# Milestone structure can only come from the todo list; there is nowhere else it exists.
# Progress does not: it is tracked in this script's own counters, so editing the file cannot
# skip a review. A count of 0 means "unknown" and degrades enforcement gracefully.
#
# The headings must number exactly 1..N with no gaps and no duplicates. That is the format the
# tasking agent is required to produce, and anything else cannot be walked safely: a list
# holding milestones 1 and 3 would otherwise be counted as two, and the run would go looking for
# a milestone 2 that does not exist while never implementing milestone 3.
get_milestone_count() {
  local count
  [ -f "$TODO_PATH" ] || { printf '0'; return; }
  count="$(awk '
    /^##[[:space:]]+Milestone[[:space:]]+[0-9]+/ { seen[$3 + 0] = 1; n++ }
    END {
      if (n == 0) { print 0; exit }
      # Every number from 1..n must be present. That rejects duplicates too: two headings
      # numbered 1 make n = 2, and 2 is then missing. Deliberately avoids length(array), which
      # older BSD awk (shipped on macOS) does not support.
      for (i = 1; i <= n; i++) { if (!(i in seen)) { print 0; exit } }
      print n
    }
  ' "$TODO_PATH" 2>/dev/null)"
  case "$count" in
    ''|*[!0-9]*) printf '0' ;;
    *)           printf '%s' "$count" ;;
  esac
}

# Reads the '**Status:**' line belonging to one milestone, used only to warn when an
# implementation sub-agent finished without marking its milestone complete.
get_milestone_status() {
  local target="$1"
  [ -f "$TODO_PATH" ] || { printf ''; return; }
  [ "$target" -ge 1 ] 2>/dev/null || { printf ''; return; }
  awk -v target="$target" '
    /^##[[:space:]]+Milestone[[:space:]]+[0-9]+/ {
      n = $3 + 0
      inTarget = (n == target)
      next
    }
    inTarget && /^[[:space:]]*\*\*Status:\*\*/ {
      line = $0
      sub(/^[[:space:]]*\*\*Status:\*\*[[:space:]]*/, "", line)
      sub(/[[:space:]]*$/, "", line)
      print tolower(line)
      exit
    }
  ' "$TODO_PATH" 2>/dev/null
}

# When the todo list is missing or unparseable the count is unknown, and the tracker must not
# deadlock waiting for a milestone it cannot see. Degrade to "at least one, and at least as many
# as have already closed", which keeps ordering enforcement without inventing work.
get_effective_milestone_count() {
  local state="$1" count completed
  count="$(state_num "$state" 'milestoneCount')"
  [ "$count" -gt 0 ] 2>/dev/null && { printf '%s' "$count"; return; }
  completed="$(state_num "$state" 'completedMilestones')"
  [ "$completed" -gt 0 ] 2>/dev/null && { printf '%s' "$completed"; return; }
  printf '1'
}

get_max_total_invocations() {
  printf '%s' "$(( TOTAL_INVOCATIONS_BASE + TOTAL_INVOCATIONS_PER_MILESTONE * $(get_effective_milestone_count "$1") ))"
}

# The security and privacy reviews judge the implementation as a whole, so any verdict they hold
# describes the code as it stood when they ran. Tasking or implementation work makes that
# verdict stale, and a stale PASS is worse than no verdict at all: it would let the run skip
# straight past the USER-REVIEW checkpoint and the final reviews.
#
# Rewrites the global STATE.
reset_downstream_verdicts() {
  STATE="$(printf '%s' "$STATE" | jq \
    '.securityVerdict = "pending" | .securityAttempts = 0
     | .privacyVerdict = "pending" | .privacyAttempts = 0')"
}

# A fix applied once the milestones are closed changes code that the whole-implementation
# reviews have already judged, so any PASS they hold is stale and the sequence has to restart at
# the security review. Only a PASS is cleared: a loop that is still in progress keeps its
# attempt budget, or a fix mid-loop would hand it an unlimited number of rounds.
#
# Rewrites the global STATE.
reset_final_verdicts_after_fix() {
  if [ "$(state_str "$STATE" 'securityVerdict')" = "PASS" ]; then
    STATE="$(printf '%s' "$STATE" | jq '.securityVerdict = "pending" | .securityAttempts = 0')"
  fi
  if [ "$(state_str "$STATE" 'privacyVerdict')" = "PASS" ]; then
    STATE="$(printf '%s' "$STATE" | jq '.privacyVerdict = "pending" | .privacyAttempts = 0')"
  fi
}

# Closes the current milestone when its review loop has ended, either because the reviewer
# passed it or because the loop spent its budget. Code review is the one loop that proceeds on
# exhaustion instead of escalating - the outstanding findings are recorded and the run moves on -
# so both outcomes advance.
#
# Reads and rewrites the global STATE, and sets the global ADVANCE_REASON to the reason it
# advanced ('' when it did not). It must not communicate through stdout: command substitution
# would run it in a subshell and the STATE rewrite would be discarded.
# Idempotent: after advancing, implementVerdict is no longer DONE, so a second call is a no-op.
advance_milestone() {
  local reason='' review_verdict review_attempts closed capped
  ADVANCE_REASON=''
  [ "$(state_str "$STATE" 'taskingVerdict')" = "DONE" ] || return 0
  [ "$(state_str "$STATE" 'implementVerdict')" = "DONE" ] || return 0

  review_verdict="$(state_str "$STATE" 'reviewVerdict')"
  review_attempts="$(state_num "$STATE" 'reviewAttempts')"
  if [ "$review_verdict" = "PASS" ]; then
    reason='passed'
  elif [ "$review_verdict" = "ISSUES" ] && [ "$review_attempts" -ge "$MAX_REVIEW_ATTEMPTS" ] 2>/dev/null; then
    reason='capped'
  else
    return 0
  fi

  closed="$(state_num "$STATE" 'currentMilestone')"
  [ "$closed" -ge 1 ] 2>/dev/null || closed=1
  capped="$(state_text "$STATE" 'cappedMilestones')"
  if [ "$reason" = "capped" ]; then
    if [ -z "$capped" ]; then capped="$closed"; else capped="$capped,$closed"; fi
  fi
  STATE="$(printf '%s' "$STATE" | jq \
    --argjson completed "$(( $(state_num "$STATE" 'completedMilestones') + 1 ))" \
    --argjson current "$(( closed + 1 ))" \
    --arg capped "$capped" '
      .completedMilestones = $completed
      | .currentMilestone = $current
      | .implementAttempts = 0 | .implementVerdict = "pending"
      | .reviewAttempts = 0 | .reviewVerdict = "pending"
      | .cappedMilestones = $capped')"
  ADVANCE_REASON="$reason"
  return 0
}

# The single source of truth for "where is this run". Derived from the counters rather than
# stored, so a partially written state file can never leave the machine in a stage its counters
# do not support.
get_stage() {
  local state="$1" total
  [ "$(state_num "$state" 'taskingAttempts')" -eq 0 ] 2>/dev/null && { printf 'idle'; return; }
  [ "$(state_num "$state" 'totalInvocations')" -ge "$(get_max_total_invocations "$state")" ] 2>/dev/null &&
    { printf 'escalated'; return; }

  if [ "$(state_str "$state" 'taskingVerdict')" != "DONE" ]; then
    [ "$(state_num "$state" 'taskingAttempts')" -ge "$MAX_WORKER_ATTEMPTS" ] 2>/dev/null &&
      { printf 'escalated'; return; }
    printf 'tasking'
    return
  fi

  total="$(get_effective_milestone_count "$state")"
  if [ "$(state_num "$state" 'completedMilestones')" -lt "$total" ] 2>/dev/null; then
    if [ "$(state_str "$state" 'implementVerdict')" != "DONE" ] &&
      [ "$(state_num "$state" 'implementAttempts')" -ge "$MAX_WORKER_ATTEMPTS" ] 2>/dev/null; then
      printf 'escalated'
      return
    fi
    printf 'milestones'
    return
  fi

  if [ "$(state_str "$state" 'securityVerdict')" != "PASS" ]; then
    # Every milestone is closed and no final review has started: this is the interactive
    # checkpoint. The stage covers the whole window in which the user holds the code, so the
    # orchestrator may keep stopping while it waits for them. What actually gates the security
    # review is userReviewReached, checked in preToolUse.
    [ "$(state_num "$state" 'securityAttempts')" -eq 0 ] 2>/dev/null && { printf 'user-review'; return; }
    [ "$(state_num "$state" 'securityAttempts')" -ge "$MAX_REVIEW_ATTEMPTS" ] 2>/dev/null &&
      { printf 'escalated'; return; }
    printf 'security'
    return
  fi

  if [ "$(state_str "$state" 'privacyVerdict')" != "PASS" ]; then
    [ "$(state_num "$state" 'privacyAttempts')" -ge "$MAX_REVIEW_ATTEMPTS" ] 2>/dev/null &&
      { printf 'escalated'; return; }
    printf 'privacy'
    return
  fi

  printf 'complete'
}

is_autonomous_stage() {
  case "$1" in
    tasking|milestones|security|privacy) return 0 ;;
    *)                                   return 1 ;;
  esac
}

get_escalation_reason() {
  local state="$1" ceiling
  ceiling="$(get_max_total_invocations "$state")"
  if [ "$(state_num "$state" 'totalInvocations')" -ge "$ceiling" ] 2>/dev/null; then
    printf 'this session has used all %s permitted sub-agent invocations' "$ceiling"
    return
  fi
  if [ "$(state_str "$state" 'taskingVerdict')" != "DONE" ] &&
    [ "$(state_num "$state" 'taskingAttempts')" -ge "$MAX_WORKER_ATTEMPTS" ] 2>/dev/null; then
    printf 'the tasking stage used all %s permitted attempts without producing a usable todo list' "$MAX_WORKER_ATTEMPTS"
    return
  fi
  if [ "$(state_str "$state" 'implementVerdict')" != "DONE" ] &&
    [ "$(state_num "$state" 'implementAttempts')" -ge "$MAX_WORKER_ATTEMPTS" ] 2>/dev/null; then
    printf 'milestone %s used all %s permitted implementation attempts without completing' \
      "$(state_num "$state" 'currentMilestone')" "$MAX_WORKER_ATTEMPTS"
    return
  fi
  if [ "$(state_str "$state" 'securityVerdict')" != "PASS" ] &&
    [ "$(state_num "$state" 'securityAttempts')" -ge "$MAX_REVIEW_ATTEMPTS" ] 2>/dev/null; then
    printf 'the security review used all %s permitted rounds without passing' "$MAX_REVIEW_ATTEMPTS"
    return
  fi
  if [ "$(state_str "$state" 'privacyVerdict')" != "PASS" ] &&
    [ "$(state_num "$state" 'privacyAttempts')" -ge "$MAX_REVIEW_ATTEMPTS" ] 2>/dev/null; then
    printf 'the privacy review used all %s permitted rounds without passing' "$MAX_REVIEW_ATTEMPTS"
    return
  fi
  printf 'a stage exhausted its attempt budget'
}

get_status_line() {
  local state="$1" total total_text
  total="$(state_num "$state" 'milestoneCount')"
  if [ "$total" -gt 0 ] 2>/dev/null; then total_text="$total"; else total_text="unknown"; fi
  printf 'tasking=%s(%s/%s), milestones=%s/%s done, current=milestone %s implement=%s(%s/%s) review=%s(%s/%s), security=%s(%s/%s), privacy=%s(%s/%s)' \
    "$(state_str "$state" 'taskingVerdict')" "$(state_num "$state" 'taskingAttempts')" "$MAX_WORKER_ATTEMPTS" \
    "$(state_num "$state" 'completedMilestones')" "$total_text" \
    "$(state_num "$state" 'currentMilestone')" \
    "$(state_str "$state" 'implementVerdict')" "$(state_num "$state" 'implementAttempts')" "$MAX_WORKER_ATTEMPTS" \
    "$(state_str "$state" 'reviewVerdict')" "$(state_num "$state" 'reviewAttempts')" "$MAX_REVIEW_ATTEMPTS" \
    "$(state_str "$state" 'securityVerdict')" "$(state_num "$state" 'securityAttempts')" "$MAX_REVIEW_ATTEMPTS" \
    "$(state_str "$state" 'privacyVerdict')" "$(state_num "$state" 'privacyAttempts')" "$MAX_REVIEW_ATTEMPTS"
}

# One sentence naming the exact next sub-agent to invoke. Used by both the subagentStop footer
# and the agentStop block reason, so the orchestrator is told the same thing whether it asked or
# tried to stop.
get_next_action() {
  local state="$1" stage="$2" m remaining
  case "$stage" in
    idle)
      printf 'Invoke autodev-implement:autodev-tasking to break the plan into milestones.'
      ;;
    tasking)
      if [ "$(state_str "$state" 'taskingVerdict')" = "BLOCKED" ]; then
        printf 'Re-invoke autodev-implement:autodev-tasking with the context it said it was missing.'
      else
        printf 'Invoke autodev-implement:autodev-tasking to break the plan into milestones.'
      fi
      ;;
    milestones)
      m="$(state_num "$state" 'currentMilestone')"
      [ "$m" -ge 1 ] 2>/dev/null || m=1
      if [ "$(state_str "$state" 'implementVerdict')" != "DONE" ]; then
        if [ "$(state_str "$state" 'implementVerdict')" = "BLOCKED" ]; then
          printf 'Re-invoke autodev-implement:autodev-implementation for milestone %s with the context it said it was missing.' "$m"
        else
          printf 'Invoke autodev-implement:autodev-implementation for milestone %s.' "$m"
        fi
      elif [ "$(state_str "$state" 'reviewVerdict')" = "ISSUES" ]; then
        remaining=$(( MAX_REVIEW_ATTEMPTS - $(state_num "$state" 'reviewAttempts') ))
        printf 'Invoke autodev-implement:autodev-code-fix with the findings above verbatim, then re-invoke autodev-implement:autodev-code-review for milestone %s. %s round(s) remain before the findings are recorded as unresolved and the run moves on.' "$m" "$remaining"
      else
        printf 'Invoke autodev-implement:autodev-code-review for milestone %s.' "$m"
      fi
      ;;
    user-review)
      if [ "$(state_num "$state" 'userReviewReached')" -eq 0 ] 2>/dev/null; then
        printf 'Every milestone is closed. Report to the user, state what you built, and hand the code back for review - end your turn or ask them directly. The security review stays locked until you do.'
      else
        printf 'The user has the code. When they tell you to proceed, invoke autodev-implement:autodev-code-security-review. If they report issues, invoke autodev-implement:autodev-code-fix and hand the result back to them again.'
      fi
      ;;
    security)
      if [ "$(state_str "$state" 'securityVerdict')" = "ISSUES" ]; then
        remaining=$(( MAX_REVIEW_ATTEMPTS - $(state_num "$state" 'securityAttempts') ))
        printf 'Invoke autodev-implement:autodev-code-fix with the findings above verbatim, then re-invoke autodev-implement:autodev-code-security-review. %s round(s) remain before escalation.' "$remaining"
      else
        printf 'Invoke autodev-implement:autodev-code-security-review.'
      fi
      ;;
    privacy)
      if [ "$(state_str "$state" 'privacyVerdict')" = "ISSUES" ]; then
        remaining=$(( MAX_REVIEW_ATTEMPTS - $(state_num "$state" 'privacyAttempts') ))
        printf 'Invoke autodev-implement:autodev-code-fix with the findings above verbatim, then re-invoke autodev-implement:autodev-code-privacy-review. %s round(s) remain before escalation.' "$remaining"
      else
        printf 'Invoke autodev-implement:autodev-code-privacy-review.'
      fi
      ;;
    complete)
      printf 'The implementation is complete and every review has passed. Proceed to WRAPUP.'
      ;;
    escalated)
      printf 'Stop looping and escalate to the user now, per your escalation protocol: %s. ask_user is permitted again, and further sub-agent invocations are refused. This session can no longer reach a clean state; say so plainly at wrap-up.' \
        "$(get_escalation_reason "$state")"
      ;;
    *)
      printf 'Continue the workflow.'
      ;;
  esac
}

# The contract requires the verdict on the FINAL line. Scanning the whole body would let a
# sub-agent that merely mentions a verdict mid-sentence ("I would say AUTODEV-VERDICT: PASS if X
# were fixed") be recorded as a pass. Judge only the last meaningful line, ignoring blank lines
# and a fence occupying a line by itself; anything unexpected falls through to the fallback.
#
# A sub-agent that reaches for the other vocabulary (a worker saying PASS, a reviewer saying
# DONE) means something unambiguous, so translate rather than burn an attempt on a wording
# mistake.
read_verdict() {
  local response="$1" kind="$2" last raw fallback
  if [ "$kind" = "review" ]; then fallback='ISSUES'; else fallback='BLOCKED'; fi
  [ -n "$response" ] || { printf '%s' "$fallback"; return; }
  last="$(printf '%s\n' "$response" \
    | tr -d '\r' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' \
    | grep -vE '^`{3,}[A-Za-z0-9]*$' \
    | tail -n 1)"
  raw="$(printf '%s' "$last" \
    | grep -oiE '^[*`>_-]*[[:space:]]*AUTODEV-VERDICT:[[:space:]]*(PASS|ISSUES|DONE|BLOCKED)[*`.[:space:]]*$' \
    | grep -oiE '(PASS|ISSUES|DONE|BLOCKED)[*`.[:space:]]*$' \
    | tr -d '*`. \t' \
    | tr '[:lower:]' '[:upper:]')"
  [ -n "$raw" ] || { printf '%s' "$fallback"; return; }
  if [ "$kind" = "review" ]; then
    case "$raw" in
      DONE)    printf 'PASS' ;;
      BLOCKED) printf 'ISSUES' ;;
      *)       printf '%s' "$raw" ;;
    esac
  else
    case "$raw" in
      PASS)   printf 'DONE' ;;
      ISSUES) printf 'BLOCKED' ;;
      *)      printf '%s' "$raw" ;;
    esac
  fi
}

STATE="$(read_state)"

case "$EVENT_NAME" in

  subagentStart)
    AGENT="$(resolve_agent "$(json_get '.agentName')")"
    [ -n "$AGENT" ] || emit_empty
    ensure_dir "$STATE_DIR" || true
    ensure_dir "$VIEW_DIR" || true
    advance_milestone

    # Learn the milestone structure from the todo list. Only the tasking agent may change a
    # count that is already known: once implementation has begun, letting a later edit shrink
    # the count would retire milestones that were never built, and the todo list lives in a
    # directory the orchestrator is allowed to write to.
    PARSED_COUNT="$(get_milestone_count)"
    if [ "$PARSED_COUNT" -gt 0 ] 2>/dev/null &&
      { [ "$AGENT" = "tasking" ] || [ "$(state_num "$STATE" 'milestoneCount')" -eq 0 ]; }; then
      STATE="$(printf '%s' "$STATE" | jq --argjson c "$PARSED_COUNT" '.milestoneCount = $c')"
    fi

    MILESTONE_LABEL='-'
    case "$AGENT" in
      tasking)
        if [ "$(state_str "$STATE" 'taskingVerdict')" = "DONE" ]; then
          # Re-tasking after the todo list was already accepted starts a fresh budget rather
          # than charging it the previous pass's attempts.
          ATTEMPT=1
        else
          ATTEMPT=$(( $(state_num "$STATE" 'taskingAttempts') + 1 ))
        fi
        STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPT" \
          '.taskingAttempts = $a | .taskingVerdict = "running"')"
        # Nothing has been implemented yet against this todo list, so any security or privacy
        # verdict on the books belongs to a different body of code.
        reset_downstream_verdicts
        ;;
      implementation)
        [ "$(state_num "$STATE" 'currentMilestone')" -ge 1 ] 2>/dev/null ||
          STATE="$(printf '%s' "$STATE" | jq '.currentMilestone = 1')"
        ATTEMPT=$(( $(state_num "$STATE" 'implementAttempts') + 1 ))
        # Any review verdict for this milestone describes the code as it stood before this run.
        # Keeping a PASS here would let freshly written code close the milestone without ever
        # being reviewed.
        STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPT" \
          '.implementAttempts = $a | .implementVerdict = "running"
           | .reviewAttempts = 0 | .reviewVerdict = "pending"')"
        reset_downstream_verdicts
        MILESTONE_LABEL="$(state_num "$STATE" 'currentMilestone')"
        ;;
      code-review)
        [ "$(state_num "$STATE" 'currentMilestone')" -ge 1 ] 2>/dev/null ||
          STATE="$(printf '%s' "$STATE" | jq '.currentMilestone = 1')"
        ATTEMPT=$(( $(state_num "$STATE" 'reviewAttempts') + 1 ))
        STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPT" \
          '.reviewAttempts = $a | .reviewVerdict = "running"')"
        MILESTONE_LABEL="$(state_num "$STATE" 'currentMilestone')"
        ;;
      code-fix)
        ATTEMPT=$(( $(state_num "$STATE" 'fixInvocations') + 1 ))
        STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPT" '.fixInvocations = $a')"
        if [ "$(state_num "$STATE" 'currentMilestone')" -ge 1 ] 2>/dev/null &&
          [ "$(state_num "$STATE" 'completedMilestones')" -lt "$(get_effective_milestone_count "$STATE")" ] 2>/dev/null; then
          MILESTONE_LABEL="$(state_num "$STATE" 'currentMilestone')"
        else
          # Past the milestone phase, so this fix changes code the security and privacy reviews
          # have already judged.
          if [ "$(get_stage "$STATE")" = "user-review" ]; then
            # The user asked for this change, so they get to look again before the final
            # reviews run.
            STATE="$(printf '%s' "$STATE" | jq '.userReviewReached = 0')"
          fi
          reset_final_verdicts_after_fix
        fi
        ;;
      code-security-review)
        if [ "$(state_str "$STATE" 'securityVerdict')" = "PASS" ]; then
          ATTEMPT=1
        else
          ATTEMPT=$(( $(state_num "$STATE" 'securityAttempts') + 1 ))
        fi
        # A security re-review describes a newer state of the code, so any privacy verdict
        # recorded against the older code is stale.
        STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPT" \
          '.securityAttempts = $a | .securityVerdict = "running"
           | .privacyVerdict = "pending" | .privacyAttempts = 0')"
        ;;
      code-privacy-review)
        if [ "$(state_str "$STATE" 'privacyVerdict')" = "PASS" ]; then
          ATTEMPT=1
        else
          ATTEMPT=$(( $(state_num "$STATE" 'privacyAttempts') + 1 ))
        fi
        STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPT" \
          '.privacyAttempts = $a | .privacyVerdict = "running"')"
        ;;
    esac

    # Real progress was made, so forgive any earlier blocked stops.
    STATE="$(printf '%s' "$STATE" | jq \
      --argjson t "$(( $(state_num "$STATE" 'totalInvocations') + 1 ))" \
      '.totalInvocations = $t | .blocks = 0')"
    write_state "$STATE"
    add_audit_row "$AGENT" "$MILESTONE_LABEL" "$ATTEMPT" "invoked" "-"
    emit_empty
    ;;

  subagentStop)
    # subagentStop does not support a matcher, so filter here.
    AGENT="$(resolve_agent "$(json_get '.agentName')")"
    [ -n "$AGENT" ] || emit_empty
    ensure_dir "$STATE_DIR" || true
    ensure_dir "$VIEW_DIR" || true

    RESPONSE="$(json_get '.response')"
    KIND="$(get_agent_kind "$AGENT")"
    VERDICT="$(read_verdict "$RESPONSE" "$KIND")"

    MILESTONE_LABEL='-'
    EXTRA_NOTES=''
    add_note() { if [ -z "$EXTRA_NOTES" ]; then EXTRA_NOTES="$1"; else EXTRA_NOTES="$EXTRA_NOTES
$1"; fi; }

    case "$AGENT" in
      tasking)
        ATTEMPT="$(state_num "$STATE" 'taskingAttempts')"
        [ "$ATTEMPT" -lt 1 ] 2>/dev/null && ATTEMPT=1
        STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPT" --arg v "$VERDICT" \
          '.taskingAttempts = $a | .taskingVerdict = $v')"
        if [ "$VERDICT" = "DONE" ]; then
          [ "$(state_num "$STATE" 'currentMilestone')" -ge 1 ] 2>/dev/null ||
            STATE="$(printf '%s' "$STATE" | jq '.currentMilestone = 1')"
          PARSED_COUNT="$(get_milestone_count)"
          if [ "$PARSED_COUNT" -gt 0 ] 2>/dev/null; then
            STATE="$(printf '%s' "$STATE" | jq --argjson c "$PARSED_COUNT" '.milestoneCount = $c')"
            add_note "Todo list parsed: $PARSED_COUNT milestone(s)."
          else
            add_note "WARNING: $TODO_PATH does not contain '## Milestone <n>' headings numbered consecutively from 1. The tracker cannot count milestones, so milestone enforcement is degraded. Re-invoke the tasking agent and require the documented todo list format."
          fi
        fi
        ;;
      implementation)
        ATTEMPT="$(state_num "$STATE" 'implementAttempts')"
        [ "$ATTEMPT" -lt 1 ] 2>/dev/null && ATTEMPT=1
        STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPT" --arg v "$VERDICT" \
          '.implementAttempts = $a | .implementVerdict = $v')"
        MILESTONE_LABEL="$(state_num "$STATE" 'currentMilestone')"
        if [ "$VERDICT" = "DONE" ]; then
          MILESTONE_STATUS="$(get_milestone_status "$MILESTONE_LABEL")"
          if [ -n "$MILESTONE_STATUS" ] && [ "$MILESTONE_STATUS" != "complete" ]; then
            add_note "WARNING: milestone $MILESTONE_LABEL still reads '**Status:** $MILESTONE_STATUS' in the todo list even though the implementation agent reported DONE. Verify the milestone is genuinely finished before reviewing it."
          fi
        fi
        ;;
      code-review)
        ATTEMPT="$(state_num "$STATE" 'reviewAttempts')"
        [ "$ATTEMPT" -lt 1 ] 2>/dev/null && ATTEMPT=1
        STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPT" --arg v "$VERDICT" \
          '.reviewAttempts = $a | .reviewVerdict = $v')"
        MILESTONE_LABEL="$(state_num "$STATE" 'currentMilestone')"
        ;;
      code-fix)
        ATTEMPT="$(state_num "$STATE" 'fixInvocations')"
        [ "$ATTEMPT" -lt 1 ] 2>/dev/null && ATTEMPT=1
        STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPT" '.fixInvocations = $a')"
        if [ "$(state_num "$STATE" 'completedMilestones')" -lt "$(get_effective_milestone_count "$STATE")" ] 2>/dev/null; then
          MILESTONE_LABEL="$(state_num "$STATE" 'currentMilestone')"
        fi
        if [ "$VERDICT" = "BLOCKED" ]; then
          add_note 'The fix agent reported BLOCKED. Resolve what it says it needs and re-invoke it; the outstanding findings still stand.'
        fi
        ;;
      code-security-review)
        ATTEMPT="$(state_num "$STATE" 'securityAttempts')"
        [ "$ATTEMPT" -lt 1 ] 2>/dev/null && ATTEMPT=1
        STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPT" --arg v "$VERDICT" \
          '.securityAttempts = $a | .securityVerdict = $v')"
        ;;
      code-privacy-review)
        ATTEMPT="$(state_num "$STATE" 'privacyAttempts')"
        [ "$ATTEMPT" -lt 1 ] 2>/dev/null && ATTEMPT=1
        STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPT" --arg v "$VERDICT" \
          '.privacyAttempts = $a | .privacyVerdict = $v')"
        ;;
    esac

    CLOSED_MILESTONE="$(state_num "$STATE" 'currentMilestone')"
    advance_milestone
    ADVANCED="$ADVANCE_REASON"
    write_state "$STATE"

    add_audit_row "$AGENT" "$MILESTONE_LABEL" "$ATTEMPT" "completed" "$VERDICT"
    if [ -n "$ADVANCED" ]; then
      add_audit_row "milestone" "$CLOSED_MILESTONE" "$ATTEMPT" "milestone-closed ($ADVANCED)" "$VERDICT"
      if [ "$ADVANCED" = "capped" ]; then
        add_note "Milestone $CLOSED_MILESTONE used all $MAX_REVIEW_ATTEMPTS code review rounds without passing. Record the outstanding findings verbatim in that milestone's 'Review notes' section in the todo list, then continue. Report them to the user at wrap-up."
      fi
    fi
    # Capture the response itself, not just that it happened, so the findings survive the session
    # and a developer can see what each stage actually said.
    add_feedback_entry "$AGENT" "$MILESTONE_LABEL" "$ATTEMPT" "$VERDICT" "$RESPONSE"

    STAGE="$(get_stage "$STATE")"
    STATUS_LINE="$(get_status_line "$STATE")"

    FOOTER="
---
[autodev-implement stage tracker]
Stage: $AGENT | Attempt $ATTEMPT | Recorded verdict: $VERDICT
Run status: $STATUS_LINE"
    if [ -n "$EXTRA_NOTES" ]; then
      FOOTER="$FOOTER
$EXTRA_NOTES"
    fi
    FOOTER="$FOOTER
Next required action: $(get_next_action "$STATE" "$STAGE")"
    case "$STAGE" in
      complete|escalated|user-review)
        FOOTER="$FOOTER
Audit trail: $AUDIT_PATH
Feedback log: $FEEDBACK_PATH"
        ;;
    esac

    jq -cn --arg r "$RESPONSE
$FOOTER" '{modifiedResponse: $r}' 2>/dev/null || emit_empty
    exit 0
    ;;

  agentStop)
    if [ ! -f "$STATE_PATH" ] && [ ! -f "$MIRROR_PATH" ]; then emit_empty; fi
    advance_milestone
    STAGE="$(get_stage "$STATE")"
    if [ "$STAGE" = "user-review" ]; then
      # 'user-review' is deliberately not blocked: stopping to let the human review the code is
      # the whole point of that checkpoint. Record that the pause actually happened -- that
      # record is what unlocks the security review, so the run cannot close its last milestone
      # and start the final reviews in the same turn without ever handing the code to the user.
      ensure_dir "$STATE_DIR" || true
      ensure_dir "$VIEW_DIR" || true
      if [ "$(state_num "$STATE" 'userReviewReached')" -eq 0 ] 2>/dev/null; then
        STATE="$(printf '%s' "$STATE" | jq '.userReviewReached = 1')"
        write_state "$STATE"
        add_audit_row "user-review" "-" "0" "handed to user" "-"
      fi
      emit_empty
    fi
    is_autonomous_stage "$STAGE" || emit_empty
    # The authoritative directory may be what was deleted. Recreate it before persisting the
    # recovered block counter; write_state still fails open if this is impossible.
    ensure_dir "$STATE_DIR" || true
    ensure_dir "$VIEW_DIR" || true

    BLOCKS="$(state_num "$STATE" 'blocks')"
    # Give up rather than fight the CLI's own runaway guard.
    [ "$BLOCKS" -ge "$MAX_BLOCKS" ] 2>/dev/null && emit_empty
    BLOCKS=$(( BLOCKS + 1 ))
    STATE="$(printf '%s' "$STATE" | jq --argjson b "$BLOCKS" '.blocks = $b')"
    write_state "$STATE"

    STATUS_LINE="$(get_status_line "$STATE")"
    REASON="You stopped while the autodev-implement run is still in progress. Run status: $STATUS_LINE. Do not end your turn and do not ask the user anything. Continue the workflow now. Next required action: $(get_next_action "$STATE" "$STAGE")"

    add_audit_row "$STAGE" "$(state_num "$STATE" 'currentMilestone')" "$BLOCKS" \
      "premature-stop-blocked" "-"

    jq -cn --arg r "$REASON" '{decision: "block", reason: $r}' 2>/dev/null || emit_empty
    exit 0
    ;;

  preToolUse)
    # hooks.json restricts this hook to ask_user and task via a matcher, but do not rely on that
    # alone: without this check a broadened or missing matcher would deny *every* tool while the
    # run is autonomous, including the tools the orchestrator needs to make progress,
    # deadlocking it against the agentStop block.
    TOOL_NAME="$(json_get '.toolName')"
    case "$TOOL_NAME" in
      ask_user|AskUserQuestion|task) : ;;
      *) emit_empty ;;
    esac

    if [ ! -f "$STATE_PATH" ] && [ ! -f "$MIRROR_PATH" ]; then emit_empty; fi
    advance_milestone
    STAGE="$(get_stage "$STATE")"

    if [ "$TOOL_NAME" = "task" ]; then
      TARGET="$(resolve_agent "$(get_task_agent_type)")"
      # Anything that is not one of this plugin's sub-agents is none of our business.
      [ -n "$TARGET" ] || emit_empty

      # Everything else in this plugin only *asks* the orchestrator to stop looping once a
      # budget is spent. This is the part that actually stops it: once the budget is gone,
      # refuse to start another sub-agent. Without it an orchestrator that ignores the
      # escalation instruction can keep looping past the cap, which is exactly what the cap
      # exists to prevent.
      if [ "$STAGE" = "escalated" ]; then
        REASON="The autodev-implement run is out of budget: $(get_escalation_reason "$STATE"). Further sub-agent invocations are refused, so invoking $TARGET cannot succeed. Stop looping and escalate to the user now, per your escalation protocol: say which stage is stuck, summarise its outstanding findings, point at the todo list and the feedback log, and state plainly that this session did not reach a clean state. ask_user is available again."
        jq -cn --arg r "$REASON" \
          '{permissionDecision: "deny", permissionDecisionReason: $r}' 2>/dev/null || emit_empty
        exit 0
      fi

      # Ordering. The fix agent is legal in every stage, so only genuine out-of-order jumps are
      # refused. Over-denying here would deadlock the orchestrator against the agentStop block,
      # so every denial below leaves at least one way forward.
      DENY_REASON=''
      if [ "$TARGET" != "code-fix" ]; then
        case "$STAGE" in
          tasking)
            if [ "$TARGET" != "tasking" ]; then
              DENY_REASON="the tasking stage has not produced a usable todo list yet"
            fi
            ;;
          milestones)
            if [ "$TARGET" = "code-security-review" ] || [ "$TARGET" = "code-privacy-review" ]; then
              REMAINING=$(( $(get_effective_milestone_count "$STATE") - $(state_num "$STATE" 'completedMilestones') ))
              DENY_REASON="$REMAINING milestone(s) are still unimplemented, and the security and privacy reviews run only once the whole implementation is finished"
            elif [ "$TARGET" = "tasking" ] &&
              { [ "$(state_num "$STATE" 'completedMilestones')" -gt 0 ] 2>/dev/null ||
                [ "$(state_num "$STATE" 'implementAttempts')" -gt 0 ] 2>/dev/null ||
                [ "$(state_num "$STATE" 'reviewAttempts')" -gt 0 ] 2>/dev/null; }; then
              # Re-tasking rewrites the milestone list, and a shorter list would retire
              # milestones that were never built. It is only safe before any milestone work has
              # started.
              DENY_REASON="milestone work has already started, and re-tasking now would rewrite the milestone list underneath it"
            elif [ "$TARGET" = "code-review" ] &&
              [ "$(state_str "$STATE" 'implementVerdict')" != "DONE" ]; then
              # Reviewing before the milestone is built would record a verdict about code that
              # does not exist yet, and that verdict would then close the milestone the moment
              # implementation finished.
              DENY_REASON="milestone $(state_num "$STATE" 'currentMilestone') has not been implemented yet, so there is nothing to review"
            elif [ "$TARGET" = "implementation" ] &&
              [ "$(state_num "$STATE" 'reviewAttempts')" -gt 0 ] 2>/dev/null &&
              [ "$(state_str "$STATE" 'reviewVerdict')" != "PASS" ]; then
              DENY_REASON="milestone $(state_num "$STATE" 'currentMilestone') has outstanding code review findings, and the next milestone cannot start until its review loop has ended"
            fi
            ;;
          user-review)
            if [ "$TARGET" = "code-security-review" ]; then
              # The checkpoint is satisfied only once the orchestrator has actually handed the
              # code back -- by ending its turn or by asking the user. Without this the final
              # milestone could close and the security review start in the same turn, and the
              # user would never get to look at anything.
              if [ "$(state_num "$STATE" 'userReviewReached')" -eq 0 ] 2>/dev/null; then
                DENY_REASON="the user has not been given the code to review yet. End your turn, or ask the user to review, and run the security review once they tell you to proceed"
              fi
            elif [ "$TARGET" = "code-privacy-review" ]; then
              DENY_REASON="the security review runs before the privacy review"
            else
              DENY_REASON="every milestone is closed and the run is waiting for the user to review the code"
            fi
            ;;
          security)
            if [ "$TARGET" != "code-security-review" ]; then
              DENY_REASON="the security review is outstanding and runs before anything else"
            fi
            ;;
          privacy)
            if [ "$TARGET" != "code-privacy-review" ]; then
              DENY_REASON="the privacy review is outstanding and runs before anything else"
            fi
            ;;
        esac
      fi

      if [ -n "$DENY_REASON" ]; then
        REASON="Out of order: invoking $TARGET is not the next step because $DENY_REASON. Next required action: $(get_next_action "$STATE" "$STAGE")"
        jq -cn --arg r "$REASON" \
          '{permissionDecision: "deny", permissionDecisionReason: $r}' 2>/dev/null || emit_empty
        exit 0
      fi

      emit_empty
    fi

    # ask_user. Permitted at the USER-REVIEW checkpoint, once a stage has escalated, before the
    # run starts, and after it completes. Denied in between.
    if [ "$STAGE" = "user-review" ]; then
      # Asking the user to review the code is the handoff, so it satisfies the checkpoint just
      # as ending the turn does.
      ensure_dir "$STATE_DIR" || true
      ensure_dir "$VIEW_DIR" || true
      if [ "$(state_num "$STATE" 'userReviewReached')" -eq 0 ] 2>/dev/null; then
        STATE="$(printf '%s' "$STATE" | jq '.userReviewReached = 1')"
        write_state "$STATE"
        add_audit_row "user-review" "-" "0" "handed to user" "-"
      fi
      emit_empty
    fi
    is_autonomous_stage "$STAGE" || emit_empty

    REASON="The autodev-implement run is in an autonomous phase ($STAGE), which proceeds without human interaction, so ask_user is unavailable. Resolve the question yourself using the plan and your best engineering judgement, and record the decision in the todo list. The user is consulted at the USER-REVIEW checkpoint once every milestone is closed. If you truly cannot proceed, keep working until the current stage reaches its attempt limit, at which point escalation to the user is unlocked automatically. Next required action: $(get_next_action "$STATE" "$STAGE")"

    jq -cn --arg r "$REASON" \
      '{permissionDecision: "deny", permissionDecisionReason: $r}' 2>/dev/null || emit_empty
    exit 0
    ;;
esac

emit_empty
