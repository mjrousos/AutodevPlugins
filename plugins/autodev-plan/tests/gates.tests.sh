#!/usr/bin/env bash
# Tests for the autodev-plan gate tracker (autodev-gates.sh).
#
# Runs the hook script as a separate process for every case, exactly as the CLI does, feeding
# the hook payload on stdin and asserting on the single JSON object it writes to stdout.
#
# Tests run against an isolated COPILOT_HOME so real session state is never touched.
#
# Usage:  bash tests/gates.tests.sh
# Exit code is 0 when every test passes, 1 otherwise.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_SCRIPT="$(cd "$TESTS_DIR/.." && pwd)/hooks/scripts/autodev-gates.sh"

PASSED=0
FAILED=0
CURRENT_ERROR=""

if [ ! -f "$GATE_SCRIPT" ]; then
  echo "Cannot find gate script at $GATE_SCRIPT" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to run these tests (the hook itself degrades to a no-op without it)" >&2
  exit 1
fi

COPILOT_HOME="$(mktemp -d "${TMPDIR:-/tmp}/autodev-gate-tests-XXXXXX")"
export COPILOT_HOME
GATES_DIR="$COPILOT_HOME/autodev-plan/gates"
trap 'rm -rf "$COPILOT_HOME"' EXIT

SESSION_SEQ=0
# Must be unique per call without relying on parent state: this runs inside $( ), which is a
# subshell, so any counter incremented here would be discarded and every test would share one
# session id (and therefore one accumulating state file).
new_session_id() {
  SESSION_SEQ=$((SESSION_SEQ + 1))
  printf 't%s_%s_%s' "$$" "$(date +%s%N 2>/dev/null || date +%s)" "$RANDOM"
}

hook() { # event json
  printf '%s\n' "$2" | bash "$GATE_SCRIPT" "$1"
}

start_gate() { # sid gate
  hook subagentStart "$(jq -cn --arg s "$1" --arg g "$2" \
    '{sessionId:$s, agentName:("autodev-plan:autodev-" + $g + "-review")}')" > /dev/null
}

stop_gate() { # sid gate response
  hook subagentStop "$(jq -cn --arg s "$1" --arg g "$2" --arg r "$3" \
    '{sessionId:$s, agentName:("autodev-plan:autodev-" + $g + "-review"), response:$r}')"
}

round() { # sid gate verdict -> footer text
  start_gate "$1" "$2"
  stop_gate "$1" "$2" "Body text.

AUTODEV-VERDICT: $3" | jq -r '.modifiedResponse // ""'
}

agent_stop() { # sid
  hook agentStop "$(jq -cn --arg s "$1" '{sessionId:$s, stopReason:"end_turn"}')"
}

ask_user() { # sid
  hook preToolUse "$(jq -cn --arg s "$1" '{sessionId:$s, toolName:"ask_user"}')"
}

fail() { CURRENT_ERROR="$1"; return 1; }

assert_equal() { # expected actual because
  [ "$1" = "$2" ] || fail "expected '$1' but got '$2'. ${3:-}"
}

assert_match() { # pattern actual because
  printf '%s' "$2" | grep -qE "$1" || fail "expected match for '$1' but got '$2'. ${3:-}"
}

run_test() { # name function
  CURRENT_ERROR=""
  if "$2" 2>/dev/null; then
    PASSED=$((PASSED + 1))
    printf '  PASS  %s\n' "$1"
  else
    FAILED=$((FAILED + 1))
    printf '  FAIL  %s\n' "$1"
    [ -n "$CURRENT_ERROR" ] && printf '        %s\n' "$CURRENT_ERROR"
  fi
}

echo
echo "autodev-plan gate tracker tests (bash)"
echo "script: $GATE_SCRIPT"

# --------------------------------------------------------------------------------------------
echo
echo "Verdict parsing (must read only the final meaningful line)"
# --------------------------------------------------------------------------------------------

FENCE='```'
# name|expected|response  (the response may contain literal \n which is expanded below)
VERDICT_CASES=(
  "clean PASS|PASS|Summary.\n\nAUTODEV-VERDICT: PASS"
  "clean ISSUES|ISSUES|Findings.\n\nAUTODEV-VERDICT: ISSUES"
  "trailing blank lines|PASS|AUTODEV-VERDICT: PASS\n\n\n"
  "wrapped in a code fence|PASS|text\n$FENCE\nAUTODEV-VERDICT: PASS\n$FENCE"
  "bold markdown|PASS|text\n\n**AUTODEV-VERDICT: PASS**"
  "trailing period|PASS|text\n\nAUTODEV-VERDICT: PASS."
  "mid-body PASS with no final verdict|ISSUES|I would say AUTODEV-VERDICT: PASS if fixed.\n\n### blocker Missing authz"
  "mid-body PASS then final ISSUES|ISSUES|AUTODEV-VERDICT: PASS maybe\n\nAUTODEV-VERDICT: ISSUES"
  "commentary after the verdict|ISSUES|AUTODEV-VERDICT: PASS\nBut actually I am unsure."
  "no verdict at all|ISSUES|I forgot to include one."
  "empty response|ISSUES|"
)

for CASE in "${VERDICT_CASES[@]}"; do
  CASE_NAME="${CASE%%|*}"
  REST="${CASE#*|}"
  CASE_EXPECT="${REST%%|*}"
  CASE_BODY="$(printf '%b' "${REST#*|}")"
  # shellcheck disable=SC2317
  verdict_test() {
    local sid footer
    sid="$(new_session_id)"
    start_gate "$sid" architecture
    footer="$(stop_gate "$sid" architecture "$CASE_BODY" | jq -r '.modifiedResponse // ""')"
    assert_match "Recorded verdict: $CASE_EXPECT" "$footer"
  }
  run_test "verdict: $CASE_NAME" verdict_test
done

# --------------------------------------------------------------------------------------------
echo
echo "Fail-safes (a hook must never deny a tool call or crash)"
# --------------------------------------------------------------------------------------------

t_stop_no_state() { assert_equal '{}' "$(agent_stop "$(new_session_id)")"; }
run_test "agentStop with no state returns empty" t_stop_no_state

t_ask_no_state() { assert_equal '{}' "$(ask_user "$(new_session_id)")"; }
run_test "ask_user with no state is permitted" t_ask_no_state

for AGENT in explore general-purpose security-review code-review task; do
  # shellcheck disable=SC2317
  t_non_reviewer() {
    local out
    out="$(hook subagentStart "$(jq -cn --arg s "$(new_session_id)" --arg a "$AGENT" \
      '{sessionId:$s, agentName:$a}')")"
    assert_equal '{}' "$out"
  }
  run_test "non-reviewer sub-agent '$AGENT' is ignored" t_non_reviewer
done

t_corrupt_state() {
  local sid
  sid="$(new_session_id)"
  mkdir -p "$GATES_DIR"
  echo '{{{ not json' > "$GATES_DIR/$sid.json"
  assert_equal '{}' "$(ask_user "$sid")" || return 1
  assert_equal '{}' "$(agent_stop "$sid")"
}
run_test "corrupt state file does not deny ask_user or block stopping" t_corrupt_state

t_garbage_stdin() {
  local out code
  out="$(printf 'this is not json\n' | bash "$GATE_SCRIPT" preToolUse)"
  code=$?
  assert_equal 0 "$code" 'hook must exit 0' || return 1
  assert_equal '{}' "$out"
}
run_test "garbage stdin returns empty JSON and exits 0" t_garbage_stdin

t_empty_stdin() {
  local out code
  out="$(printf '' | bash "$GATE_SCRIPT" preToolUse)"
  code=$?
  assert_equal 0 "$code" 'hook must exit 0' || return 1
  assert_equal '{}' "$out"
}
run_test "empty stdin returns empty JSON and exits 0" t_empty_stdin

t_no_jq() {
  # Without jq the hook must degrade to a no-op rather than denying the tool call.
  local out code
  out="$(PATH=/nonexistent /bin/bash "$GATE_SCRIPT" preToolUse < /dev/null 2>/dev/null)"
  code=$?
  assert_equal 0 "$code" 'hook must exit 0 when jq is missing' || return 1
  assert_equal '{}' "$out"
}
run_test "missing jq degrades to a no-op instead of denying" t_no_jq

t_path_traversal() {
  hook subagentStart '{"sessionId":"../../evil","agentName":"autodev-plan:autodev-security-review"}' > /dev/null
  [ ! -f "$COPILOT_HOME/evil.json" ] || fail 'state file was written outside the gates directory'
}
run_test "a hostile session id cannot escape the gates directory" t_path_traversal

# --------------------------------------------------------------------------------------------
echo
echo "Enforcement"
# --------------------------------------------------------------------------------------------

t_block_while_outstanding() {
  local sid out
  sid="$(new_session_id)"
  round "$sid" architecture ISSUES > /dev/null
  out="$(agent_stop "$sid")"
  assert_equal 'block' "$(printf '%s' "$out" | jq -r '.decision // ""')" || return 1
  assert_match 'autodev-plan:autodev-architecture-review' "$(printf '%s' "$out" | jq -r '.reason // ""')"
}
run_test "agentStop is blocked while a gate is outstanding" t_block_while_outstanding

t_deny_ask_user() {
  local sid
  sid="$(new_session_id)"
  round "$sid" architecture ISSUES > /dev/null
  assert_equal 'deny' "$(ask_user "$sid" | jq -r '.permissionDecision // ""')"
}
run_test "ask_user is denied while gating" t_deny_ask_user

t_names_next_gate() {
  local sid
  sid="$(new_session_id)"
  round "$sid" architecture PASS > /dev/null
  assert_match 'autodev-plan:autodev-security-review' "$(agent_stop "$sid" | jq -r '.reason // ""')"
}
run_test "agentStop names the next gate once one passes" t_names_next_gate

t_all_pass_releases() {
  local sid gate
  sid="$(new_session_id)"
  for gate in architecture security privacy; do round "$sid" "$gate" PASS > /dev/null; done
  assert_equal '{}' "$(agent_stop "$sid")" || return 1
  assert_equal '{}' "$(ask_user "$sid")"
}
run_test "all gates passing releases the block and permits ask_user" t_all_pass_releases

# --------------------------------------------------------------------------------------------
echo
echo "Loop bounds"
# --------------------------------------------------------------------------------------------

t_escalate_after_5() {
  local sid i
  sid="$(new_session_id)"
  for i in 1 2 3 4 5; do round "$sid" architecture ISSUES > /dev/null; done
  assert_equal '{}' "$(agent_stop "$sid")" 'escalation must release the stop block' || return 1
  assert_equal '{}' "$(ask_user "$sid")" 'escalation must re-permit ask_user'
}
run_test "a gate escalates after 5 failed attempts and unlocks the human" t_escalate_after_5

t_escalation_names_stuck() {
  local sid i footer
  sid="$(new_session_id)"
  for i in 1 2 3 4 5; do round "$sid" architecture ISSUES > /dev/null; done
  # A different gate reports next; the footer must still point at architecture.
  footer="$(round "$sid" security ISSUES)"
  assert_match 'architecture gate' "$footer"
}
run_test "escalation names the gate that is actually stuck" t_escalation_names_stuck

t_regate_resets_budget() {
  local sid i footer
  sid="$(new_session_id)"
  for i in 1 2 3; do round "$sid" architecture ISSUES > /dev/null; done
  round "$sid" architecture PASS > /dev/null
  footer="$(round "$sid" architecture ISSUES)"
  assert_match 'Attempt 1 of 5' "$footer" 'a re-gate must not inherit the previous pass count'
}
run_test "re-gating a passed gate starts a fresh attempt budget" t_regate_resets_budget

t_block_guard() {
  local sid i decisions=""
  sid="$(new_session_id)"
  round "$sid" architecture ISSUES > /dev/null
  for i in 1 2 3 4 5 6 7; do
    if [ "$(agent_stop "$sid" | jq -r '.decision // ""')" = "block" ]; then
      decisions="${decisions}1"
    else
      decisions="${decisions}0"
    fi
  done
  assert_equal '1111100' "$decisions" 'expected 5 blocks then release'
}
run_test "the block counter stops fighting the CLI runaway guard" t_block_guard

t_total_ceiling() {
  local sid i gate footer
  sid="$(new_session_id)"
  for i in $(seq 1 10); do
    for gate in architecture security privacy; do
      footer="$(round "$sid" "$gate" PASS)"
      case "$footer" in *"permitted reviewer invocations"*) return 0 ;; esac
    done
  done
  fail 'cascade never hit the 20-invocation ceiling'
}
run_test "the session-wide invocation ceiling escalates a runaway cascade" t_total_ceiling

# --------------------------------------------------------------------------------------------
echo
echo "Re-gate invalidation"
# --------------------------------------------------------------------------------------------

t_regate_invalidates_downstream() {
  local sid gate out
  sid="$(new_session_id)"
  for gate in architecture security privacy; do round "$sid" "$gate" PASS > /dev/null; done
  assert_equal '{}' "$(agent_stop "$sid")" 'should be complete before the re-gate' || return 1

  # A material change re-runs architecture. The security and privacy verdicts described the
  # older plan, so they must not still count as passed.
  round "$sid" architecture PASS > /dev/null
  out="$(agent_stop "$sid")"
  assert_equal 'block' "$(printf '%s' "$out" | jq -r '.decision // ""')" \
    'stale downstream passes must not satisfy the tracker' || return 1
  assert_match 'autodev-plan:autodev-security-review' "$(printf '%s' "$out" | jq -r '.reason // ""')"
}
run_test "re-gating an earlier gate invalidates the later ones" t_regate_invalidates_downstream

# --------------------------------------------------------------------------------------------
echo
echo "Audit trail"
# --------------------------------------------------------------------------------------------

t_audit_rows() {
  local sid audit rows
  sid="$(new_session_id)"
  round "$sid" architecture ISSUES > /dev/null
  round "$sid" architecture PASS > /dev/null
  audit="$GATES_DIR/$sid.md"
  [ -f "$audit" ] || fail "no audit trail at $audit" || return 1
  rows="$(grep -cE '^\| [0-9]{4}-' "$audit")"
  assert_equal 4 "$rows" 'expected two invoked rows and two completed rows' || return 1
  grep -q 'completed | ISSUES' "$audit" || fail 'missing the ISSUES row' || return 1
  grep -q 'completed | PASS' "$audit" || fail 'missing the PASS row'
}
run_test "every reviewer invocation is recorded" t_audit_rows

t_no_temp_files() {
  local sid count
  sid="$(new_session_id)"
  round "$sid" architecture PASS > /dev/null
  count="$(find "$GATES_DIR" -name '*.tmp' 2>/dev/null | wc -l | tr -d ' ')"
  assert_equal 0 "$count" 'temp files must be renamed away or cleaned up'
}
run_test "state writes leave no orphaned temp files" t_no_temp_files

# --------------------------------------------------------------------------------------------

echo
if [ "$FAILED" -gt 0 ]; then
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi
echo "$PASSED passed, 0 failed"
exit 0
