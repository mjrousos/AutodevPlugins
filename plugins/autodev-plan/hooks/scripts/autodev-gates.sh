#!/usr/bin/env bash
# Gate tracker for the autodev-plan plugin (Linux / macOS).
#
# Invoked by hooks.json for four hook events. Reads the hook payload as JSON on stdin and
# writes exactly one JSON object to stdout.
#
#   subagentStart - record that a review gate was invoked; increment its attempt counter.
#   subagentStop  - parse the reviewer's verdict, record it, and append a tracker footer to
#                   the response the orchestrator receives.
#   agentStop     - block the orchestrator from ending its turn while gates are outstanding.
#   preToolUse    - deny ask_user while gating, so the gate phase stays autonomous.
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

GATE_ORDER="architecture security privacy"
# Per gate, per pass. A gate that is re-run after previously passing starts a fresh budget.
MAX_ATTEMPTS=5
# Kept below the CLI's own 8-block runaway guard so we surrender first.
MAX_BLOCKS=5
# Absolute ceiling across all gates and all re-gate passes. Because a re-gate resets a gate's
# per-pass budget, this is what makes an unbounded re-gate cascade impossible.
MAX_TOTAL_INVOCATIONS=20

COPILOT_HOME_DIR="${COPILOT_HOME:-$HOME/.copilot}"
STATE_DIR="$COPILOT_HOME_DIR/autodev-plan/gates"
mkdir -p "$STATE_DIR" 2>/dev/null || emit_empty

json_get() { printf '%s' "$RAW_INPUT" | jq -r "$1 // \"\"" 2>/dev/null; }

SESSION_ID="$(json_get '.sessionId')"
# Defend against path traversal via a hostile session id.
SAFE_SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$SAFE_SESSION_ID" ] || SAFE_SESSION_ID="unknown-session"

STATE_PATH="$STATE_DIR/$SAFE_SESSION_ID.json"
AUDIT_PATH="$STATE_DIR/$SAFE_SESSION_ID.md"

default_state() {
  jq -n --arg sid "$SAFE_SESSION_ID" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
  sessionId: $sid, createdAt: $now, updatedAt: $now, blocks: 0, totalInvocations: 0,
    architectureAttempts: 0, architectureVerdict: "pending",
    securityAttempts: 0,     securityVerdict: "pending",
    privacyAttempts: 0,      privacyVerdict: "pending"
  }'
}

read_state() {
  if [ -f "$STATE_PATH" ] && jq -e . "$STATE_PATH" >/dev/null 2>&1; then
    # Merge over defaults so a partial or older state file still yields every field.
    jq -s '.[0] * .[1]' <(default_state) "$STATE_PATH" 2>/dev/null || default_state
  else
    # Missing or corrupt state is treated as absent. Never fatal.
    default_state
  fi
}

write_state() {
  # Write then rename, so a concurrent reader never observes a half-written file. A torn read
  # would be treated as absent state, which would silently switch enforcement off. The temp
  # name includes the PID so two concurrent writers cannot clobber each other's temp file.
  local tmp="$STATE_PATH.$$.tmp"
  printf '%s' "$1" \
    | jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.updatedAt = $now' \
    > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATE_PATH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
}

state_num() { printf '%s' "$1" | jq -r ".$2 // 0" 2>/dev/null; }
state_str() { printf '%s' "$1" | jq -r ".$2 // \"pending\"" 2>/dev/null; }

add_audit_row() {
  local gate="$1" attempt="$2" action="$3" verdict="$4"
  if [ ! -f "$AUDIT_PATH" ]; then
    {
      printf '# autodev-plan review gate audit\n\n'
      printf 'Session: `%s`\n' "$SAFE_SESSION_ID"
      printf 'Started: %s\n\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
      printf 'Every row below was written by a hook observing a real sub-agent lifecycle event.\n'
      printf 'The orchestrator cannot write to this file.\n\n'
      printf '| Time (UTC) | Gate | Attempt | Event | Verdict |\n'
      printf '| --- | --- | --- | --- | --- |\n'
    } > "$AUDIT_PATH" 2>/dev/null
  fi
  printf '| %s | %s | %s | %s | %s |\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%S')" "$gate" "$attempt" "$action" "$verdict" \
    >> "$AUDIT_PATH" 2>/dev/null
}

# agentName arrives namespaced, e.g. "autodev-plan:autodev-privacy-review".
resolve_gate() {
  case "$1" in
    *autodev-architecture-review) printf 'architecture' ;;
    *autodev-security-review)     printf 'security' ;;
    *autodev-privacy-review)      printf 'privacy' ;;
    *)                            printf '' ;;
  esac
}

get_phase() {
  local state="$1" started=0 all_passed=1 escalated=0 gate attempts verdict
  for gate in $GATE_ORDER; do
    attempts="$(state_num "$state" "${gate}Attempts")"
    verdict="$(state_str "$state" "${gate}Verdict")"
    [ "$attempts" -gt 0 ] 2>/dev/null && started=1
    if [ "$verdict" != "PASS" ]; then
      all_passed=0
      [ "$attempts" -ge "$MAX_ATTEMPTS" ] 2>/dev/null && escalated=1
    fi
  done
  if [ "$started" -eq 0 ]; then printf 'idle'; return; fi
  if [ "$all_passed" -eq 1 ]; then printf 'complete'; return; fi
  if [ "$escalated" -eq 1 ]; then printf 'escalated'; return; fi
  if [ "$(state_num "$state" 'totalInvocations')" -ge "$MAX_TOTAL_INVOCATIONS" ] 2>/dev/null; then
    printf 'escalated'; return
  fi
  printf 'gating'
}

get_next_gate() {
  local state="$1" gate
  for gate in $GATE_ORDER; do
    [ "$(state_str "$state" "${gate}Verdict")" != "PASS" ] && { printf '%s' "$gate"; return; }
  done
  printf ''
}

get_gate_status_line() {
  local state="$1" out="" gate attempts verdict
  for gate in $GATE_ORDER; do
    attempts="$(state_num "$state" "${gate}Attempts")"
    verdict="$(state_str "$state" "${gate}Verdict")"
    [ -n "$out" ] && out="$out, "
    if [ "$attempts" -eq 0 ] 2>/dev/null; then
      out="$out$gate=not-yet-run"
    else
      out="$out$gate=$verdict($attempts/$MAX_ATTEMPTS)"
    fi
  done
  printf '%s' "$out"
}

# The contract requires the verdict on the FINAL line. Scanning the whole body would let a
# reviewer that merely mentions a verdict mid-sentence ("I would say AUTODEV-VERDICT: PASS if X
# were fixed") be recorded as a pass. Judge only the last meaningful line, ignoring blank lines
# and a trailing code fence; anything unexpected falls through to ISSUES.
read_verdict() {
  local last
  last="$(printf '%s\n' "$1" \
    | tr -d '\r' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' \
    | grep -v '^```' \
    | tail -n 1)"
  if printf '%s' "$last" \
    | grep -qiE '^[*`>_-]*[[:space:]]*AUTODEV-VERDICT:[[:space:]]*PASS[*`.[:space:]]*$'; then
    printf 'PASS'
  else
    printf 'ISSUES'
  fi
}

get_stuck_gates() {
  local state="$1" out="" gate
  for gate in $GATE_ORDER; do
    if [ "$(state_str "$state" "${gate}Verdict")" != "PASS" ] &&
      [ "$(state_num "$state" "${gate}Attempts")" -ge "$MAX_ATTEMPTS" ] 2>/dev/null; then
      [ -n "$out" ] && out="$out, "
      out="$out$gate"
    fi
  done
  printf '%s' "$out"
}

STATE="$(read_state)"

case "$EVENT_NAME" in

  subagentStart)
    GATE="$(resolve_gate "$(json_get '.agentName')")"
    [ -n "$GATE" ] || emit_empty
    if [ "$(state_str "$STATE" "${GATE}Verdict")" = "PASS" ]; then
      # This gate already passed, so this is a re-gate after a material change.
      # Start a fresh per-pass budget rather than charging it the old pass's attempts.
      ATTEMPTS=1
    else
      ATTEMPTS=$(( $(state_num "$STATE" "${GATE}Attempts") + 1 ))
    fi
    TOTAL=$(( $(state_num "$STATE" 'totalInvocations') + 1 ))
    # Any later gate's verdict described an older version of the plan, so it is now stale.
    # Invalidating them keeps the tracker in step with the orchestrator's rule of re-running
    # every gate from the first one affected onward, and stops a re-gate from reaching
    # "complete" while downstream gates hold verdicts for a plan that changed.
    STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPTS" --argjson t "$TOTAL" \
      ".${GATE}Attempts = \$a | .${GATE}Verdict = \"running\" | .totalInvocations = \$t | .blocks = 0")"
    SEEN_CURRENT=0
    for LATER in $GATE_ORDER; do
      if [ "$SEEN_CURRENT" -eq 1 ]; then
        STATE="$(printf '%s' "$STATE" | jq ".${LATER}Verdict = \"pending\" | .${LATER}Attempts = 0")"
      fi
      [ "$LATER" = "$GATE" ] && SEEN_CURRENT=1
    done
    write_state "$STATE"
    add_audit_row "$GATE" "$ATTEMPTS" "invoked" "-"
    emit_empty
    ;;

  subagentStop)
    # subagentStop does not support a matcher, so filter here.
    GATE="$(resolve_gate "$(json_get '.agentName')")"
    [ -n "$GATE" ] || emit_empty

    RESPONSE="$(json_get '.response')"
    VERDICT="$(read_verdict "$RESPONSE")"

    ATTEMPTS="$(state_num "$STATE" "${GATE}Attempts")"
    # subagentStart was missed somehow; still count this attempt.
    [ "$ATTEMPTS" -lt 1 ] 2>/dev/null && ATTEMPTS=1
    STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPTS" --arg v "$VERDICT" \
      ".${GATE}Attempts = \$a | .${GATE}Verdict = \$v")"
    write_state "$STATE"
    add_audit_row "$GATE" "$ATTEMPTS" "completed" "$VERDICT"

    PHASE="$(get_phase "$STATE")"
    STATUS_LINE="$(get_gate_status_line "$STATE")"

    if [ "$PHASE" = "complete" ]; then
      NEXT_ACTION="Next required action: all three gates have passed. Proceed to WRAPUP.
Audit trail: $AUDIT_PATH"
    elif [ "$PHASE" = "escalated" ]; then
      if [ "$(state_num "$STATE" 'totalInvocations')" -ge "$MAX_TOTAL_INVOCATIONS" ] 2>/dev/null; then
        NEXT_ACTION="Next required action: the review gates have used all $MAX_TOTAL_INVOCATIONS permitted reviewer invocations for this session without reaching a clean state. Stop looping and escalate to the user now, per your escalation protocol. ask_user is permitted again.
Audit trail: $AUDIT_PATH"
      else
        NEXT_ACTION="Next required action: the $(get_stuck_gates "$STATE") gate(s) reached the $MAX_ATTEMPTS-attempt limit without passing. Stop looping and escalate to the user now, per your escalation protocol. ask_user is permitted again. This session can no longer reach a clean 'all gates passed' state; say so plainly at wrap-up.
Audit trail: $AUDIT_PATH"
      fi
    elif [ "$VERDICT" = "PASS" ]; then
      NEXT_GATE="$(get_next_gate "$STATE")"
      NEXT_ACTION="Next required action: the $GATE gate is closed. Invoke autodev-plan:autodev-$NEXT_GATE-review next."
    else
      REMAINING=$(( MAX_ATTEMPTS - ATTEMPTS ))
      NEXT_ACTION="Next required action: revise the plan file to address the findings above, then re-invoke autodev-plan:autodev-$GATE-review. $REMAINING attempt(s) remain before escalation."
    fi

    FOOTER="
---
[autodev-plan gate tracker]
Gate: $GATE | Attempt $ATTEMPTS of $MAX_ATTEMPTS | Recorded verdict: $VERDICT
Gate status: $STATUS_LINE
$NEXT_ACTION"

    jq -cn --arg r "$RESPONSE
$FOOTER" '{modifiedResponse: $r}'
    exit 0
    ;;

  agentStop)
    [ -f "$STATE_PATH" ] || emit_empty
    [ "$(get_phase "$STATE")" = "gating" ] || emit_empty

    BLOCKS="$(state_num "$STATE" 'blocks')"
    # Give up rather than fight the CLI's own runaway guard.
    [ "$BLOCKS" -ge "$MAX_BLOCKS" ] 2>/dev/null && emit_empty

    STATE="$(printf '%s' "$STATE" | jq --argjson b "$(( BLOCKS + 1 ))" '.blocks = $b')"
    write_state "$STATE"

    NEXT_GATE="$(get_next_gate "$STATE")"
    STATUS_LINE="$(get_gate_status_line "$STATE")"
    ATTEMPTS="$(state_num "$STATE" "${NEXT_GATE}Attempts")"

    REASON="You stopped while autodev-plan review gates are still outstanding. Gate status: $STATUS_LINE. Do not end your turn and do not ask the user anything. Continue the workflow now by invoking the $NEXT_GATE gate via the task tool with agent_type 'autodev-plan:autodev-$NEXT_GATE-review'"
    if [ "$ATTEMPTS" -gt 0 ] 2>/dev/null; then
      REASON="$REASON, after first revising the plan file to address that reviewer's outstanding findings"
    fi
    REASON="$REASON."

    add_audit_row "$NEXT_GATE" "$ATTEMPTS" "premature-stop-blocked" "-"
    jq -cn --arg r "$REASON" '{decision: "block", reason: $r}'
    exit 0
    ;;

  preToolUse)
    [ -f "$STATE_PATH" ] || emit_empty
    [ "$(get_phase "$STATE")" = "gating" ] || emit_empty

    NEXT_GATE="$(get_next_gate "$STATE")"
    REASON="The autodev-plan review gates run without human interaction. The $NEXT_GATE gate is still outstanding, so ask_user is unavailable. Resolve reviewer feedback yourself using your best engineering judgement and record the decision in the plan's 'Review notes' section. If you truly cannot proceed, keep looping until the gate reaches its attempt limit, at which point escalation to the user is unlocked automatically."

    jq -cn --arg r "$REASON" '{permissionDecision: "deny", permissionDecisionReason: $r}'
    exit 0
    ;;

  *)
    emit_empty
    ;;
esac

emit_empty
