#!/usr/bin/env bash
# Tests for the autodev-plan gate tracker (autodev-gates.sh).
#
# Runs the hook script as a separate process for every case, exactly as the CLI does, feeding
# the hook payload on stdin and asserting on the single JSON object it writes to stdout.
#
# Tests run against an isolated COPILOT_HOME, and each test gets its own temporary working
# directory, so real session state is never touched. The tracker writes its developer-facing
# artifacts into '<cwd>/.autodev/', so a per-test cwd is what keeps tests isolated.
#
# Every assertion costs a process spawn, so by default the suite shards itself across parallel
# workers. Use --sequential for readable, grouped output when diagnosing a failure.
#
# Usage:  bash tests/gates.tests.sh
#         bash tests/gates.tests.sh --sequential     one process, grouped by section
#         bash tests/gates.tests.sh --workers 4      override the worker count
# Exit code is 0 when every test passes, 1 otherwise.

SHARD=-1
SHARD_COUNT=1
WORKERS=0
SEQUENTIAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --shard) SHARD="$2"; shift 2 ;;
    --of) SHARD_COUNT="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --sequential) SEQUENTIAL=1; shift ;;
    *) shift ;;
  esac
done

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

# ---------------------------------------------------------------------------------------------
# Dispatcher: fan the cases out across worker processes and aggregate.
# ---------------------------------------------------------------------------------------------
if [ "$SHARD" -lt 0 ] && [ "$SEQUENTIAL" -eq 0 ]; then
  if [ "$WORKERS" -le 0 ]; then
    WORKERS="$( (nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4) )"
    [ "$WORKERS" -gt 8 ] 2>/dev/null && WORKERS=8
    [ "$WORKERS" -ge 1 ] 2>/dev/null || WORKERS=4
  fi
  OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/autodev-gate-shards-XXXXXX")"
  echo
  echo "autodev-plan gate tracker tests (bash), $WORKERS workers"
  echo "Use --sequential for output grouped by section."
  START_TS=$(date +%s)
  i=0
  while [ "$i" -lt "$WORKERS" ]; do
    bash "${BASH_SOURCE[0]}" --shard "$i" --of "$WORKERS" > "$OUT_DIR/shard-$i.log" 2>&1 &
    i=$((i + 1))
  done
  wait
  TOTAL_PASSED=0
  TOTAL_FAILED=0
  MISSING=""
  i=0
  while [ "$i" -lt "$WORKERS" ]; do
    log="$OUT_DIR/shard-$i.log"
    SAW_RESULT=0
    if [ -f "$log" ]; then
      while IFS= read -r line; do
        case "$line" in
          RESULT\ *)
            SAW_RESULT=1
            set -- $line
            TOTAL_PASSED=$((TOTAL_PASSED + $2))
            TOTAL_FAILED=$((TOTAL_FAILED + $3))
            ;;
          *) printf '%s\n' "$line" ;;
        esac
      done < "$log"
    fi
    # A worker that dies before printing its tally takes its whole share of the cases with it.
    # Without this the run would report only the surviving shards' results and pass.
    [ "$SAW_RESULT" -eq 1 ] || MISSING="$MISSING $i"
    i=$((i + 1))
  done
  rm -rf "$OUT_DIR"
  ELAPSED=$(( $(date +%s) - START_TS ))
  echo
  if [ -n "$MISSING" ]; then
    for s in $MISSING; do
      echo "  worker shard $s produced no result summary (crashed or was killed); its cases did not run"
    done
    echo "$TOTAL_PASSED passed, $TOTAL_FAILED failed, worker(s)$MISSING did not report  (${ELAPSED}s)"
    exit 1
  fi
  if [ "$TOTAL_FAILED" -gt 0 ]; then
    echo "$TOTAL_PASSED passed, $TOTAL_FAILED failed  (${ELAPSED}s)"
    exit 1
  fi
  if [ "$TOTAL_PASSED" -eq 0 ]; then
    echo "no tests ran - the workers produced no results (${ELAPSED}s)"
    exit 1
  fi
  echo "$TOTAL_PASSED passed, 0 failed  (${ELAPSED}s)"
  exit 0
fi

COPILOT_HOME="$(mktemp -d "${TMPDIR:-/tmp}/autodev-gate-tests-XXXXXX")"
export COPILOT_HOME
GATES_DIR="$COPILOT_HOME/autodev-plan/gates"
WORKDIRS="$COPILOT_HOME/work"
mkdir -p "$WORKDIRS"
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
  # A malformed payload makes the hook fail open, so a test that expects '{}' would pass for
  # entirely the wrong reason. Emit an obviously-wrong marker instead so the assertion fails
  # loudly and names the cause.
  printf '%s' "$2" | jq -e . >/dev/null 2>&1 || { printf 'MALFORMED-TEST-PAYLOAD'; return 1; }
  printf '%s\n' "$2" | bash "$GATE_SCRIPT" "$1"
}

# The tracker keys its files off the session working directory, so give every session its own.
session_cwd() { # sid
  local d="$WORKDIRS/$1"
  mkdir -p "$d" 2>/dev/null
  printf '%s' "$d"
}

state_path()    { printf '%s/autodev-plan/gates/%s.json' "$COPILOT_HOME" "$1"; }
mirror_path()   { printf '%s/.autodev/gate-status.json' "$(session_cwd "$1")"; }
audit_path()    { printf '%s/.autodev/gate-audit.md' "$(session_cwd "$1")"; }
feedback_path() { printf '%s/.autodev/feedback-log.md' "$(session_cwd "$1")"; }

start_gate() { # sid gate
  hook subagentStart "$(jq -cn --arg s "$1" --arg g "$2" --arg c "$(session_cwd "$1")" \
    '{sessionId:$s, cwd:$c, agentName:("autodev-plan:autodev-" + $g + "-review")}')" > /dev/null
}

stop_gate() { # sid gate response
  hook subagentStop "$(jq -cn --arg s "$1" --arg g "$2" --arg r "$3" --arg c "$(session_cwd "$1")" \
    '{sessionId:$s, cwd:$c, agentName:("autodev-plan:autodev-" + $g + "-review"), response:$r}')"
}

round() { # sid gate verdict -> footer text
  start_gate "$1" "$2"
  stop_gate "$1" "$2" "Body text.

AUTODEV-VERDICT: $3" | jq -r '.modifiedResponse // ""'
}

agent_stop() { # sid
  hook agentStop "$(jq -cn --arg s "$1" --arg c "$(session_cwd "$1")" \
    '{sessionId:$s, cwd:$c, stopReason:"end_turn"}')"
}

ask_user() { # sid
  hook preToolUse "$(jq -cn --arg s "$1" --arg c "$(session_cwd "$1")" \
    '{sessionId:$s, cwd:$c, toolName:"ask_user"}')"
}

reviewer_task() { # sid gate
  # Build the nested JSON in a variable first. macOS ships bash 3.2, whose $( ) parser
  # mishandles parentheses inside an embedded single-quoted program, which silently produced a
  # malformed payload -- and a malformed payload is fail-open, so the assertion that mattered
  # (a deny) turned into a pass-through.
  local cwd args
  cwd="$(session_cwd "$1")"
  args="$(jq -cn --arg a "autodev-plan:autodev-$2-review" '{agent_type:$a, prompt:"review"}')"
  hook preToolUse "$(jq -cn --arg s "$1" --arg c "$cwd" --arg t "$args" \
    '{sessionId:$s, cwd:$c, toolName:"task", toolArgs:$t}')"
}

fail() { CURRENT_ERROR="$1"; return 1; }

assert_equal() { # expected actual because
  [ "$1" = "$2" ] || fail "expected '$1' but got '$2'. ${3:-}"
}

assert_match() { # pattern actual because
  printf '%s' "$2" | grep -qE "$1" || fail "expected match for '$1' but got '$2'. ${3:-}"
}

CASE_INDEX=-1

run_test() { # name function
  # Round-robin the cases across workers. Every worker walks the whole file, so this stays a
  # plain linear script and no test needs to know it is being sharded.
  CASE_INDEX=$((CASE_INDEX + 1))
  if [ "$SHARD_COUNT" -gt 1 ] && [ $((CASE_INDEX % SHARD_COUNT)) -ne "$SHARD" ]; then
    return
  fi
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

section() {
  # Section headers only make sense in a single ordered run; across workers they would repeat.
  [ "$SHARD_COUNT" -le 1 ] || return 0
  echo
  echo "$1"
}

# Seeds the enforcement state directly. Used only where reaching a state through real rounds
# would cost dozens of process spawns and the accumulation itself is not what is under test; the
# tests that DO cover accumulation (the 9-vs-10 attempt boundary, and two sessions counting
# independently) still drive every round through the hook.
seed_state() { # sid  jq-assignment-expression
  local sid="$1" expr="${2:-.}" path
  path="$(state_path "$sid")"
  mkdir -p "$(dirname "$path")"
  jq -n --arg sid "$sid" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
    sessionId: $sid, createdAt: $now, updatedAt: $now, blocks: 0, totalInvocations: 0,
    architectureAttempts: 0, architectureVerdict: "pending",
    securityAttempts: 0,     securityVerdict: "pending",
    privacyAttempts: 0,      privacyVerdict: "pending"
  }' | jq "$expr" > "$path"
}

# The common setup: one gate has spent its entire budget without passing.
seed_stuck_gate() { # sid [gate]
  local gate="${2:-architecture}"
  seed_state "$1" ".${gate}Attempts = 10 | .${gate}Verdict = \"ISSUES\" | .totalInvocations = 10"
}

section "autodev-plan gate tracker tests (bash)"
[ "$SHARD_COUNT" -le 1 ] && echo "script: $GATE_SCRIPT"

# --------------------------------------------------------------------------------------------
section "Verdict parsing (must read only the final meaningful line)"
# --------------------------------------------------------------------------------------------

FENCE='```'
# name|expected|response  (the response may contain literal \n which is expanded below)
VERDICT_CASES=(
  "clean PASS|PASS|Summary.\n\nAUTODEV-VERDICT: PASS"
  "clean ISSUES|ISSUES|Findings.\n\nAUTODEV-VERDICT: ISSUES"
  "trailing blank lines|PASS|AUTODEV-VERDICT: PASS\n\n\n"
  "wrapped in a code fence|PASS|text\n$FENCE\nAUTODEV-VERDICT: PASS\n$FENCE"
  "fence and verdict share a line|PASS|text\n${FENCE}AUTODEV-VERDICT: PASS${FENCE}"
  "bold markdown|PASS|text\n\n**AUTODEV-VERDICT: PASS**"
  "trailing period|PASS|text\n\nAUTODEV-VERDICT: PASS."
  "indented verdict line|PASS|text\n\n    AUTODEV-VERDICT: PASS"
  # The reviewer templates show the verdict as a placeholder. If a model ever copies it
  # literally that must fail safe rather than read as a pass.
  "literal template placeholder is not a pass|ISSUES|Summary.\n\nAUTODEV-VERDICT: <PASS or ISSUES>"
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
section "Fail-safes (a hook must never deny a tool call or crash)"
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
  local sid statep
  sid="$(new_session_id)"
  statep="$(state_path "$sid")"
  mkdir -p "$(dirname "$statep")"
  echo '{{{ not json' > "$statep"
  assert_equal '{}' "$(ask_user "$sid")" || return 1
  assert_equal '{}' "$(agent_stop "$sid")"
}
run_test "corrupt state file does not deny ask_user or block stopping" t_corrupt_state

t_no_owner_state_not_adopted() {
  # preToolUse is fail-closed, so a hand-edited or truncated file must not be able to deny tools
  # in a session it has nothing to do with.
  local sid statep
  sid="$(new_session_id)"
  statep="$(state_path "$sid")"
  mkdir -p "$(dirname "$statep")"
  echo '{"totalInvocations":30,"architectureAttempts":10,"architectureVerdict":"ISSUES","securityVerdict":"pending","privacyVerdict":"pending"}' > "$statep"
  assert_equal '{}' "$(reviewer_task "$sid" architecture)" || return 1
  assert_equal '{}' "$(ask_user "$sid")" || return 1
  assert_equal '{}' "$(agent_stop "$sid")"
}
run_test "a state file with no owner is never adopted" t_no_owner_state_not_adopted

t_state_file_is_snapshotted_once() {
  # The workspace mirror is shared by sessions. Validation, owner checking and merging must all
  # use one captured value, not reopen a path another session can atomically replace.
  local body reads
  body="$(sed -n '/^read_state_file()/,/^}/p' "$GATE_SCRIPT")"
  assert_match 'snapshot="\$\(cat "\$path"' "$body" || return 1
  reads="$(printf '%s' "$body" | grep -c 'cat "\$path"')"
  assert_equal 1 "$reads" 'read_state_file must open the checkpoint exactly once' || return 1
  if printf '%s' "$body" | grep -qE 'jq .*\\"\$path\\"'; then
    fail 'read_state_file reopens the checkpoint with jq instead of using the snapshot'
    return 1
  fi
}
run_test "state recovery validates and merges one captured snapshot" t_state_file_is_snapshotted_once

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
  local safe
  safe="$(session_cwd "hostile-id-cwd")"
  hook subagentStart "$(jq -cn --arg c "$safe" \
    '{sessionId:"../../evil", cwd:$c, agentName:"autodev-plan:autodev-security-review"}')" > /dev/null
  [ ! -f "$COPILOT_HOME/evil.json" ] || fail 'state file was written outside the state directory' || return 1
  [ ! -f "$COPILOT_HOME/evil.md" ] || fail 'audit trail was written outside the state directory'
}
run_test "a hostile session id cannot escape the state directory" t_path_traversal

# --------------------------------------------------------------------------------------------
section "Enforcement"
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

for TOOL in view edit create task bash powershell grep glob; do
  # Defense in depth. hooks.json scopes this hook to ask_user and task, but if that matcher
  # were ever broadened the orchestrator would be denied the tools it needs to revise the plan
  # and invoke the next gate, and would then deadlock against the agentStop block. 'task' must
  # stay allowed while a gate still has attempts left.
  # shellcheck disable=SC2317
  t_other_tool_allowed() {
    local sid out
    sid="$(new_session_id)"
    round "$sid" architecture ISSUES > /dev/null
    out="$(hook preToolUse "$(jq -cn --arg s "$sid" --arg t "$TOOL" --arg c "$(session_cwd "$sid")" \
      '{sessionId:$s, cwd:$c, toolName:$t}')")"
    assert_equal '{}' "$out"
  }
  run_test "'$TOOL' is NOT denied while gating" t_other_tool_allowed
done

t_reviewer_allowed_with_budget() {
  local sid
  sid="$(new_session_id)"
  round "$sid" architecture ISSUES > /dev/null
  assert_equal '{}' "$(reviewer_task "$sid" architecture)"
}
run_test "invoking a reviewer is permitted while the gate still has attempts left" t_reviewer_allowed_with_budget

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
section "Loop bounds"
# --------------------------------------------------------------------------------------------

t_escalate_after_budget() {
  local sid i
  sid="$(new_session_id)"
  for i in $(seq 1 10); do round "$sid" architecture ISSUES > /dev/null; done
  assert_equal '{}' "$(agent_stop "$sid")" 'escalation must release the stop block' || return 1
  assert_equal '{}' "$(ask_user "$sid")" 'escalation must re-permit ask_user'
}
run_test "a gate escalates after 10 failed attempts and unlocks the human" t_escalate_after_budget

t_no_escalate_one_short() {
  # Guards the off-by-one directly: 9 failures must still be a live gate.
  local sid i
  sid="$(new_session_id)"
  for i in $(seq 1 9); do round "$sid" architecture ISSUES > /dev/null; done
  assert_equal 'block' "$(agent_stop "$sid" | jq -r '.decision // ""')" \
    'the gate still has an attempt left, so stopping must still be blocked'
}
run_test "a gate does NOT escalate one attempt short of the budget" t_no_escalate_one_short

t_escalation_names_stuck() {
  local sid footer
  sid="$(new_session_id)"
  seed_stuck_gate "$sid"
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
  assert_match 'Attempt 1 of 10' "$footer" 'a re-gate must not inherit the previous pass count'
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
  # Seeded one invocation short of the ceiling, so the next real round must trip it. This pins
  # the boundary exactly, where looping until the message appeared only proved it happened
  # eventually -- and cost forty round trips to do it.
  local sid footer
  sid="$(new_session_id)"
  seed_state "$sid" '.totalInvocations = 39
    | .architectureAttempts = 1 | .architectureVerdict = "PASS"
    | .securityAttempts = 1     | .securityVerdict = "PASS"
    | .privacyAttempts = 1      | .privacyVerdict = "PASS"'
  footer="$(round "$sid" architecture PASS)"
  assert_match 'permitted reviewer invocations' "$footer"
}
run_test "the session-wide invocation ceiling escalates a runaway cascade" t_total_ceiling

t_ceiling_not_early() {
  local sid footer
  sid="$(new_session_id)"
  seed_state "$sid" '.totalInvocations = 38
    | .architectureAttempts = 1 | .architectureVerdict = "PASS"
    | .securityAttempts = 1     | .securityVerdict = "PASS"
    | .privacyAttempts = 1      | .privacyVerdict = "PASS"'
  footer="$(round "$sid" architecture PASS)"
  case "$footer" in
    *"permitted reviewer invocations"*) fail 'the ceiling fired at 39 invocations'; return 1 ;;
  esac
}
run_test "the session-wide ceiling does not fire one invocation early" t_ceiling_not_early

t_ceiling_leaves_room() {
  # If the ceiling were at or below (gates * per-gate budget) it would silently become the real
  # limit and the per-gate budget would never be reachable on the last gate.
  local sid footer
  sid="$(new_session_id)"
  seed_state "$sid" '.totalInvocations = 22
    | .architectureAttempts = 11 | .architectureVerdict = "PASS"
    | .securityAttempts = 11     | .securityVerdict = "PASS"'
  footer="$(round "$sid" privacy ISSUES)"
  assert_match 'Attempt 1 of 10' "$footer" || return 1
  assert_match '9 attempt\(s\) remain' "$footer" 'the last gate must still get a full budget'
}
run_test "the session-wide ceiling leaves room for every gate to spend its budget" t_ceiling_leaves_room

# --------------------------------------------------------------------------------------------
section "Budget exhaustion actually stops the loop"
# --------------------------------------------------------------------------------------------

t_refuse_after_budget() {
  # The footer only *asks* the orchestrator to stop. This is what makes the cap real: an
  # orchestrator that ignores the escalation instruction still cannot start an 11th review.
  local sid out
  sid="$(new_session_id)"
  seed_stuck_gate "$sid"
  out="$(reviewer_task "$sid" architecture)"
  assert_equal 'deny' "$(printf '%s' "$out" | jq -r '.permissionDecision // ""')" || return 1
  assert_match 'out of budget' "$(printf '%s' "$out" | jq -r '.permissionDecisionReason // ""')" || return 1
  assert_match 'architecture' "$(printf '%s' "$out" | jq -r '.permissionDecisionReason // ""')"
}
run_test "once a gate is out of attempts, re-invoking any reviewer is refused" t_refuse_after_budget

t_allowed_one_short_of_cap() {
  # Guards the boundary from the other side: the deny must not start a round early.
  local sid
  sid="$(new_session_id)"
  seed_state "$sid" '.architectureAttempts = 9 | .architectureVerdict = "ISSUES" | .totalInvocations = 9'
  assert_equal '{}' "$(reviewer_task "$sid" architecture)"
}
run_test "a reviewer is still permitted one attempt short of the cap" t_allowed_one_short_of_cap

t_refuse_other_gate_too() {
  # Skipping ahead to the next gate would produce a plan that never cleared architecture.
  local sid
  sid="$(new_session_id)"
  seed_stuck_gate "$sid"
  assert_equal 'deny' "$(reviewer_task "$sid" security | jq -r '.permissionDecision // ""')"
}
run_test "a stuck gate also blocks moving on to a different reviewer" t_refuse_other_gate_too

t_refusal_scoped_to_reviewers() {
  # The orchestrator may still need explore or general-purpose agents to write up the
  # escalation, so only reviewer invocations are refused.
  local sid agent out args cwd
  sid="$(new_session_id)"
  cwd="$(session_cwd "$sid")"
  seed_stuck_gate "$sid"
  for agent in explore general-purpose code-review security-review; do
    args="$(jq -cn --arg a "$agent" '{agent_type:$a, prompt:"go"}')"
    out="$(hook preToolUse "$(jq -cn --arg s "$sid" --arg c "$cwd" --arg t "$args" \
      '{sessionId:$s, cwd:$c, toolName:"task", toolArgs:$t}')")"
    assert_equal '{}' "$out" "'$agent' must still be allowed" || return 1
  done
}
run_test "the refusal does not spill over onto non-reviewer sub-agents" t_refusal_scoped_to_reviewers

t_malformed_task_args() {
  local sid bad out cwd
  sid="$(new_session_id)"
  cwd="$(session_cwd "$sid")"
  seed_stuck_gate "$sid"
  for bad in '' 'not json at all' '{"no_agent_type":1}' '[]'; do
    out="$(hook preToolUse "$(jq -cn --arg s "$sid" --arg a "$bad" --arg c "$cwd" \
      '{sessionId:$s, cwd:$c, toolName:"task", toolArgs:$a}')")"
    assert_equal '{}' "$out" "toolArgs '$bad' must fail open" || return 1
  done
}
run_test "malformed task arguments never deny the tool call" t_malformed_task_args

t_refuse_at_session_ceiling() {
  local sid
  sid="$(new_session_id)"
  seed_state "$sid" '.totalInvocations = 40
    | .architectureAttempts = 1 | .architectureVerdict = "PASS"
    | .securityAttempts = 1     | .securityVerdict = "PASS"
    | .privacyAttempts = 1      | .privacyVerdict = "ISSUES"'
  assert_match 'permitted reviewer invocations' \
    "$(reviewer_task "$sid" privacy | jq -r '.permissionDecisionReason // ""')"
}
run_test "reviewers are refused once the session-wide ceiling is reached" t_refuse_at_session_ceiling

# --------------------------------------------------------------------------------------------
section "Re-gate invalidation"
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
section "Audit trail"
# --------------------------------------------------------------------------------------------

t_audit_rows() {
  local sid audit rows
  sid="$(new_session_id)"
  round "$sid" architecture ISSUES > /dev/null
  round "$sid" architecture PASS > /dev/null
  audit="$(audit_path "$sid")"
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
  count="$(find "$(dirname "$(state_path "$sid")")" -name '*.tmp' 2>/dev/null | wc -l | tr -d ' ')"
  assert_equal 0 "$count" 'temp files must be renamed away or cleaned up'
}
run_test "state writes leave no orphaned temp files" t_no_temp_files

# --------------------------------------------------------------------------------------------
section "Developer-visible artifacts under .autodev/"
# --------------------------------------------------------------------------------------------

t_artifacts_reachable() {
  local sid p
  sid="$(new_session_id)"
  round "$sid" architecture ISSUES > /dev/null
  for p in "$(state_path "$sid")" "$(mirror_path "$sid")" "$(audit_path "$sid")" "$(feedback_path "$sid")"; do
    [ -f "$p" ] || fail "expected $p to exist" || return 1
  done
}
run_test "state, mirror, audit trail and feedback log are all reachable" t_artifacts_reachable

t_state_outside_workspace() {
  # The orchestrator may edit workspace files while gating, so anything it could rewrite is not
  # the normal enforcement source. Only the view/recovery checkpoint belongs in .autodev.
  local sid cwd
  sid="$(new_session_id)"
  cwd="$(session_cwd "$sid")"
  round "$sid" architecture ISSUES > /dev/null
  case "$(state_path "$sid")" in
    "$cwd"*) fail 'enforcement state must not live inside the workspace'; return 1 ;;
  esac
  assert_equal 1 "$(jq -r '.architectureAttempts' "$(mirror_path "$sid")")" \
    'the mirror must reflect the real state' || return 1
  assert_equal 'ISSUES' "$(jq -r '.architectureVerdict' "$(mirror_path "$sid")")"
}
run_test "enforcement state lives outside the workspace, the mirror inside it" t_state_outside_workspace

t_mirror_tampering_ignored() {
  local sid
  sid="$(new_session_id)"
  round "$sid" architecture ISSUES > /dev/null
  echo '{"sessionId":"x","architectureVerdict":"PASS","securityVerdict":"PASS","privacyVerdict":"PASS","architectureAttempts":1,"securityAttempts":1,"privacyAttempts":1,"totalInvocations":3,"blocks":0}' \
    > "$(mirror_path "$sid")"
  assert_equal 'block' "$(agent_stop "$sid" | jq -r '.decision // ""')" \
    'rewriting the mirror must not release the gate'
}
run_test "tampering with the mirror does not weaken a gate" t_mirror_tampering_ignored

t_authoritative_loss_recovers() {
  # Regression: deleting COPILOT_HOME/autodev-plan mid-session made the next reviewer look like
  # the first gate. subagentStart then erased both logs and demanded architecture again.
  local sid audit_before feedback_before recovered audit_after feedback_after
  sid="$(new_session_id)"
  round "$sid" architecture PASS > /dev/null
  audit_before="$(cat "$(audit_path "$sid")")"
  feedback_before="$(cat "$(feedback_path "$sid")")"

  # Delete the whole tracker tree, matching the real incident -- not just the JSON file.
  rm -rf "$COPILOT_HOME/autodev-plan"
  assert_equal 'deny' "$(ask_user "$sid" | jq -r '.permissionDecision // ""')" \
    'gating must remain active during recovery' || return 1
  start_gate "$sid" security

  recovered="$(cat "$(state_path "$sid")")"
  assert_equal 'PASS' "$(printf '%s' "$recovered" | jq -r '.architectureVerdict')" \
    'the prior gate must survive recovery' || return 1
  assert_equal 1 "$(printf '%s' "$recovered" | jq -r '.architectureAttempts')" || return 1
  assert_equal 'running' "$(printf '%s' "$recovered" | jq -r '.securityVerdict')" \
    'the workflow must advance to security' || return 1
  assert_equal 1 "$(printf '%s' "$recovered" | jq -r '.securityAttempts')" || return 1
  assert_equal 2 "$(printf '%s' "$recovered" | jq -r '.totalInvocations')" || return 1

  audit_after="$(cat "$(audit_path "$sid")")"
  feedback_after="$(cat "$(feedback_path "$sid")")"
  assert_match 'architecture \| 1 \| completed \| PASS' "$audit_after" || return 1
  assert_match 'security \| 1 \| invoked \| -' "$audit_after" || return 1
  case "$audit_after" in
    "$audit_before"*) ;;
    *) fail 'the prior audit rows were erased instead of preserved'; return 1 ;;
  esac
  assert_equal "$feedback_before" "$feedback_after" \
    'starting security must preserve architecture feedback'
}
run_test "losing authoritative state between reviewers recovers from the mirror" t_authoritative_loss_recovers

t_agentstop_recovers() {
  local sid out i decisions=""
  sid="$(new_session_id)"
  round "$sid" architecture PASS > /dev/null
  rm -rf "$COPILOT_HOME/autodev-plan"

  for i in 1 2 3 4 5 6; do
    out="$(agent_stop "$sid")"
    if [ "$(printf '%s' "$out" | jq -r '.decision // ""')" = "block" ]; then
      assert_match 'autodev-plan:autodev-security-review' \
        "$(printf '%s' "$out" | jq -r '.reason // ""')" || return 1
      decisions="${decisions}1"
    else
      decisions="${decisions}0"
    fi
  done
  assert_equal '111110' "$decisions" \
    'recovery must preserve the five-block surrender guard' || return 1
  [ -f "$(state_path "$sid")" ] ||
    fail 'agentStop did not restore authoritative state from the mirror'
}
run_test "agentStop recovers a missing authoritative state before enforcing" t_agentstop_recovers

t_agentstop_without_view_dir() {
  local sid view_dir out
  sid="$(new_session_id)"
  round "$sid" architecture PASS > /dev/null
  view_dir="$(dirname "$(mirror_path "$sid")")"
  rm -rf "$view_dir"
  # Make recreation impossible: .autodev is a file, not a directory.
  printf 'occupied' > "$view_dir"

  out="$(agent_stop "$sid")"
  assert_equal 'block' "$(printf '%s' "$out" | jq -r '.decision // ""')" \
    'an unavailable audit log must not swallow enforcement' || return 1
  assert_match 'autodev-plan:autodev-security-review' \
    "$(printf '%s' "$out" | jq -r '.reason // ""')"
}
run_test "agentStop does not depend on the workspace audit directory" t_agentstop_without_view_dir

t_agentstop_when_state_dir_cannot_be_recreated() {
  local sid i out decisions="" state_root
  sid="$(new_session_id)"
  round "$sid" architecture PASS > /dev/null
  state_root="$COPILOT_HOME/autodev-plan"
  rm -rf "$state_root"
  printf 'occupied' > "$state_root"

  for i in 1 2 3 4 5 6; do
    out="$(agent_stop "$sid")"
    if [ "$(printf '%s' "$out" | jq -r '.decision // ""')" = "block" ]; then
      decisions="${decisions}1"
    else
      decisions="${decisions}0"
    fi
  done
  # Restore the worker's shared COPILOT_HOME before any later test in this shard runs.
  rm -f "$state_root"
  assert_equal '111110' "$decisions" \
    'the mirror must carry the block counter when external writes fail' || return 1
  assert_equal 5 "$(jq -r '.blocks' "$(mirror_path "$sid")")"
}
run_test "agentStop persists its counter to the mirror when external state cannot be recreated" t_agentstop_when_state_dir_cannot_be_recreated

t_other_session_mirror_not_recovered() {
  local shared first second state
  shared="$(session_cwd "$(new_session_id)")"
  first="$(new_session_id)"
  hook subagentStart "$(jq -cn --arg s "$first" --arg c "$shared" \
    '{sessionId:$s, cwd:$c, agentName:"autodev-plan:autodev-architecture-review"}')" > /dev/null
  hook subagentStop "$(jq -cn --arg s "$first" --arg c "$shared" \
    '{sessionId:$s, cwd:$c, agentName:"autodev-plan:autodev-architecture-review",
      response:"ok\n\nAUTODEV-VERDICT: PASS"}')" > /dev/null

  second="$(new_session_id)"
  hook subagentStart "$(jq -cn --arg s "$second" --arg c "$shared" \
    '{sessionId:$s, cwd:$c, agentName:"autodev-plan:autodev-architecture-review"}')" > /dev/null
  state="$(cat "$(state_path "$second")")"
  assert_equal 'running' "$(printf '%s' "$state" | jq -r '.architectureVerdict')" || return 1
  assert_equal 1 "$(printf '%s' "$state" | jq -r '.architectureAttempts')" \
    'a new session must start from attempt 1' || return 1
  assert_equal 1 "$(printf '%s' "$state" | jq -r '.totalInvocations')" \
    'a new session must not inherit the old invocation count'
}
run_test "a mirror from another session is never used for recovery" t_other_session_mirror_not_recovered

t_two_sessions_independent() {
  # This is what makes the caps real. If sessions shared one state file they would reset each
  # other and no gate would ever reach its limit. Every round here goes through the hook,
  # because real interleaved accumulation is exactly what is under test.
  local shared a b i sid
  shared="$(session_cwd "$(new_session_id)")"
  a="$(new_session_id)"
  b="$(new_session_id)"
  for i in 1 2 3; do
    for sid in "$a" "$b"; do
      hook subagentStart "$(jq -cn --arg s "$sid" --arg c "$shared" \
        '{sessionId:$s, cwd:$c, agentName:"autodev-plan:autodev-architecture-review"}')" > /dev/null
      hook subagentStop "$(jq -cn --arg s "$sid" --arg c "$shared" \
        '{sessionId:$s, cwd:$c, agentName:"autodev-plan:autodev-architecture-review",
          response:"finding\n\nAUTODEV-VERDICT: ISSUES"}')" > /dev/null
    done
  done
  for sid in "$a" "$b"; do
    assert_equal 3 "$(jq -r '.architectureAttempts' "$(state_path "$sid")")" \
      "session $sid lost attempts to the other session" || return 1
  done
  # Take one session to its cap; the other must keep its own budget.
  seed_state "$a" '.architectureAttempts = 9 | .architectureVerdict = "ISSUES" | .totalInvocations = 9'
  hook subagentStart "$(jq -cn --arg s "$a" --arg c "$shared" \
    '{sessionId:$s, cwd:$c, agentName:"autodev-plan:autodev-architecture-review"}')" > /dev/null
  hook subagentStop "$(jq -cn --arg s "$a" --arg c "$shared" \
    '{sessionId:$s, cwd:$c, agentName:"autodev-plan:autodev-architecture-review",
      response:"finding\n\nAUTODEV-VERDICT: ISSUES"}')" > /dev/null

  assert_equal 'deny' "$(hook preToolUse "$(jq -cn --arg s "$a" --arg c "$shared" \
    '{sessionId:$s, cwd:$c, toolName:"task",
      toolArgs:"{\"agent_type\":\"autodev-plan:autodev-architecture-review\"}"}')" | jq -r '.permissionDecision // ""')" \
    'the session at its cap must be refused' || return 1
  assert_equal '{}' "$(hook preToolUse "$(jq -cn --arg s "$b" --arg c "$shared" \
    '{sessionId:$s, cwd:$c, toolName:"task",
      toolArgs:"{\"agent_type\":\"autodev-plan:autodev-architecture-review\"}"}')")" \
    'the other session must keep its own budget'
}
run_test "two sessions in one directory keep independent attempt counters" t_two_sessions_independent

t_reset_once_per_session() {
  local sid i rows entries
  sid="$(new_session_id)"
  for i in 1 2 3; do round "$sid" architecture ISSUES > /dev/null; done
  rows="$(grep -cE '^\| [0-9]{4}-' "$(audit_path "$sid")")"
  assert_equal 6 "$rows" 'three rounds must leave six rows, not one' || return 1
  entries="$(grep -cE '^# [a-z]+ - attempt ' "$(feedback_path "$sid")")"
  assert_equal 3 "$entries" 'three rounds must leave three feedback entries'
}
run_test "the audit and feedback logs accumulate every invocation in a session" t_reset_once_per_session

t_empty_logs_self_heal() {
  local sid audit feedback
  sid="$(new_session_id)"
  audit="$(audit_path "$sid")"
  feedback="$(feedback_path "$sid")"
  mkdir -p "$(dirname "$audit")"
  : > "$audit"
  : > "$feedback"

  round "$sid" architecture ISSUES > /dev/null

  grep -Fqx "Session: \`$sid\`" "$audit" || return 1
  grep -q 'architecture | 1 | invoked | -' "$audit" || return 1
  grep -q 'architecture | 1 | completed | ISSUES' "$audit" || return 1
  grep -Fqx "Session: \`$sid\`" "$feedback" || return 1
  grep -q '^# architecture - attempt 1 - ISSUES$' "$feedback"
}
run_test "zero-byte Markdown logs self-heal without disabling tracking" t_empty_logs_self_heal

t_feedback_verbatim() {
  local sid log
  sid="$(new_session_id)"
  start_gate "$sid" architecture
  stop_gate "$sid" architecture "### blocker Unbounded retry loop
The worker never gives up.

AUTODEV-VERDICT: ISSUES" > /dev/null
  log="$(cat "$(feedback_path "$sid")")"
  assert_match 'blocker Unbounded retry loop' "$log" 'the reviewer findings must be preserved' || return 1
  assert_match 'The worker never gives up\.' "$log" || return 1
  assert_match '^# architecture - attempt 1 - ISSUES$' "$log" \
    'entries must be labelled with gate, attempt and verdict'
}
run_test "the feedback log records each reviewer response verbatim" t_feedback_verbatim

t_feedback_accumulates() {
  local sid log needle
  sid="$(new_session_id)"
  start_gate "$sid" architecture
  stop_gate "$sid" architecture "First round finding.

AUTODEV-VERDICT: ISSUES" > /dev/null
  start_gate "$sid" architecture
  stop_gate "$sid" architecture "Now resolved.

AUTODEV-VERDICT: PASS" > /dev/null
  start_gate "$sid" security
  stop_gate "$sid" security "Secrets in logs.

AUTODEV-VERDICT: ISSUES" > /dev/null
  log="$(cat "$(feedback_path "$sid")")"
  for needle in 'First round finding' 'Now resolved' 'Secrets in logs'; do
    assert_match "$needle" "$log" "the log must keep every round, missing '$needle'" || return 1
  done
  assert_match '^# security - attempt 1 - ISSUES$' "$log"
}
run_test "the feedback log accumulates every attempt of every gate" t_feedback_accumulates

t_footer_points_at_logs() {
  local sid gate footer
  sid="$(new_session_id)"
  for gate in architecture security; do round "$sid" "$gate" PASS > /dev/null; done
  footer="$(round "$sid" privacy PASS)"
  assert_match 'feedback-log\.md' "$footer" || return 1
  assert_match 'gate-audit\.md' "$footer"
}
run_test "the footer points the orchestrator at the feedback log when gating finishes" t_footer_points_at_logs

t_new_session_preserves_logs() {
  # State is per session, but human-readable history is append-only across sessions.
  local shared first second gate rows entries audit_before feedback_before audit_after feedback_after
  shared="$(session_cwd "$(new_session_id)")"
  first="$(new_session_id)"
  for gate in architecture security privacy; do
    hook subagentStart "$(jq -cn --arg s "$first" --arg c "$shared" --arg g "$gate" \
      '{sessionId:$s, cwd:$c, agentName:("autodev-plan:autodev-" + $g + "-review")}')" > /dev/null
    hook subagentStop "$(jq -cn --arg s "$first" --arg c "$shared" --arg g "$gate" \
      '{sessionId:$s, cwd:$c, agentName:("autodev-plan:autodev-" + $g + "-review"),
        response:"ok\n\nAUTODEV-VERDICT: PASS"}')" > /dev/null
  done
  audit_before="$(cat "$shared/.autodev/gate-audit.md")"
  feedback_before="$(cat "$shared/.autodev/feedback-log.md")"

  second="$(new_session_id)"
  # Before the new session runs anything, its gates must read as untouched.
  assert_equal '{}' "$(hook agentStop "$(jq -cn --arg s "$second" --arg c "$shared" \
    '{sessionId:$s, cwd:$c, stopReason:"end_turn"}')")" 'an idle session must not be blocked' || return 1

  hook subagentStart "$(jq -cn --arg s "$second" --arg c "$shared" \
    '{sessionId:$s, cwd:$c, agentName:"autodev-plan:autodev-architecture-review"}')" > /dev/null
  hook subagentStop "$(jq -cn --arg s "$second" --arg c "$shared" \
    '{sessionId:$s, cwd:$c, agentName:"autodev-plan:autodev-architecture-review",
      response:"ok\n\nAUTODEV-VERDICT: PASS"}')" > /dev/null

  audit_after="$(cat "$shared/.autodev/gate-audit.md")"
  feedback_after="$(cat "$shared/.autodev/feedback-log.md")"
  rows="$(printf '%s' "$audit_after" | grep -cE '^\| [0-9]{4}-')"
  assert_equal 8 "$rows" 'six prior lifecycle rows and two new rows must all remain' || return 1
  entries="$(printf '%s' "$feedback_after" | grep -cE '^# [a-z]+ - attempt ')"
  assert_equal 4 "$entries" 'all reviewer responses from both sessions must remain' || return 1
  case "$audit_after" in "$audit_before"*) ;; *) fail 'the prior audit session was erased'; return 1 ;; esac
  case "$feedback_after" in "$feedback_before"*) ;; *) fail 'the prior feedback session was erased'; return 1 ;; esac
  grep -Fqx "Session: \`$first\`" "$shared/.autodev/gate-audit.md" || return 1
  grep -Fqx "Session: \`$second\`" "$shared/.autodev/gate-audit.md" || return 1
  grep -Fqx "Session: \`$first\`" "$shared/.autodev/feedback-log.md" || return 1
  grep -Fqx "Session: \`$second\`" "$shared/.autodev/feedback-log.md" || return 1

  assert_equal 'block' "$(hook agentStop "$(jq -cn --arg s "$second" --arg c "$shared" \
    '{sessionId:$s, cwd:$c, stopReason:"end_turn"}')" | jq -r '.decision // ""')" \
    "the old session's security and privacy passes must not carry over"
}
run_test "a new session gets fresh state but preserves previous Markdown logs" t_new_session_preserves_logs

t_feedback_timestamp() {
  local sid log
  sid="$(new_session_id)"
  round "$sid" architecture ISSUES > /dev/null
  log="$(cat "$(feedback_path "$sid")")"
  assert_match '_[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC_' "$log" \
    'each entry needs a timestamp, not an empty marker'
}
run_test "the feedback log stamps each entry with a readable timestamp" t_feedback_timestamp

t_non_ascii_round_trip() {
  # Reviewers routinely emit en dashes and curly quotes. These must survive into both the
  # feedback log and the footer handed back to the orchestrator.
  local sid out footer log
  sid="$(new_session_id)"
  start_gate "$sid" architecture
  out="$(stop_gate "$sid" architecture "Rows 4–6 use the client’s token.

AUTODEV-VERDICT: ISSUES")"
  footer="$(printf '%s' "$out" | jq -r '.modifiedResponse // ""')"
  assert_match '4–6' "$footer" 'the footer must preserve the reviewer text verbatim' || return 1
  log="$(cat "$(feedback_path "$sid")")"
  assert_match '4–6' "$log" 'the feedback log must preserve the reviewer text verbatim' || return 1
  assert_match 'client’s' "$log"
}
run_test "non-ASCII reviewer text survives the round trip" t_non_ascii_round_trip

t_no_stray_autodev_dir() {
  # The hooks fire in every session once the plugin is installed. Creating the state directory
  # eagerly would litter an empty '.autodev' into any repo where someone merely used the task
  # tool. It must appear only when a real review gate starts.
  local sid cwd
  sid="$(new_session_id)"
  cwd="$(session_cwd "$sid")"
  hook preToolUse "$(jq -cn --arg s "$sid" --arg c "$cwd" \
    '{sessionId:$s, cwd:$c, toolName:"task", toolArgs:"{\"agent_type\":\"explore\"}"}')" > /dev/null
  hook preToolUse "$(jq -cn --arg s "$sid" --arg c "$cwd" '{sessionId:$s, cwd:$c, toolName:"ask_user"}')" > /dev/null
  hook subagentStart "$(jq -cn --arg s "$sid" --arg c "$cwd" '{sessionId:$s, cwd:$c, agentName:"explore"}')" > /dev/null
  hook subagentStop "$(jq -cn --arg s "$sid" --arg c "$cwd" \
    '{sessionId:$s, cwd:$c, agentName:"explore", response:"done"}')" > /dev/null
  hook agentStop "$(jq -cn --arg s "$sid" --arg c "$cwd" '{sessionId:$s, cwd:$c, stopReason:"end_turn"}')" > /dev/null
  [ ! -d "$cwd/.autodev" ] || fail '.autodev was created by a session that never ran a review gate' || return 1

  # ...but a real gate does create it.
  start_gate "$sid" architecture
  [ -d "$cwd/.autodev" ] || fail '.autodev was not created when a review gate started'
}
run_test "unrelated tool calls and sub-agents do not create a .autodev directory" t_no_stray_autodev_dir

# --------------------------------------------------------------------------------------------
section "Hook wiring (hooks.json is what connects all of the above to the CLI)"
# --------------------------------------------------------------------------------------------

PLUGIN_ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
HOOKS_JSON="$PLUGIN_ROOT_DIR/hooks.json"

# The CLI anchors a matcher as ^(?:PATTERN)$ against the full value. grep -E is POSIX ERE and
# does not understand the (?: ... ) non-capturing group syntax, so normalize it to a plain group
# before matching. Without this every comparison silently fails, which would make the
# "ignores unrelated sub-agents" assertions pass for the wrong reason.
matches() { # pattern value
  local ere="${1//(\?:/(}"
  printf '%s' "$2" | grep -qE "^(${ere})$"
}

hooks_q() { jq -r "$1" "$HOOKS_JSON" 2>/dev/null; }

t_hooks_events() {
  local evt
  assert_equal 1 "$(hooks_q '.version')" || return 1
  for evt in subagentStart subagentStop agentStop preToolUse; do
    [ "$(hooks_q ".hooks | has(\"$evt\")")" = "true" ] || fail "missing hook event '$evt'" || return 1
  done
}
run_test "hooks.json declares all four hook events" t_hooks_events

t_hooks_both_shells() {
  local missing
  missing="$(hooks_q '[.hooks | to_entries[] | .key as $k | .value[] | select((.bash | not) or (.powershell | not)) | $k] | join(", ")')"
  [ -z "$missing" ] || fail "entries missing a bash or powershell command: $missing"
}
run_test "every hook entry supplies both bash and powershell commands" t_hooks_both_shells

t_hooks_dispatch() {
  local bad
  # Each entry must invoke the matching script and pass its own event name.
  bad="$(hooks_q '[.hooks | to_entries[] | .key as $k | .value[]
    | select((.bash | test("autodev-gates\\.sh\" " + $k + "$") | not)
          or (.powershell | test("autodev-gates\\.ps1\" " + $k + "$") | not)
          or (.bash | test("\\$\\{PLUGIN_ROOT\\}") | not)
          or (.powershell | test("\\$\\{PLUGIN_ROOT\\}") | not))
    | $k] | join(", ")')"
  [ -z "$bad" ] || fail "wrong script, event name or missing \${PLUGIN_ROOT}: $bad"
}
run_test "every hook entry dispatches its own event name to the right script" t_hooks_dispatch

t_hooks_no_pwsh() {
  # pwsh (PowerShell 7) is a separate install, so relying on it would add a prerequisite the
  # plugin documents as unnecessary.
  local bad
  bad="$(hooks_q '[.hooks | to_entries[] | .key as $k | .value[] | select(.powershell | test("(^|[ \"])pwsh([ \"]|$)")) | $k] | join(", ")')"
  [ -z "$bad" ] || fail "entries using pwsh: $bad"
}
run_test "hook entries invoke powershell.exe rather than pwsh" t_hooks_no_pwsh

t_hooks_scripts_exist() {
  local rel
  for rel in hooks/scripts/autodev-gates.ps1 hooks/scripts/autodev-gates.sh; do
    [ -f "$PLUGIN_ROOT_DIR/$rel" ] || fail "hooks.json references a missing file: $rel" || return 1
  done
}
run_test "every script referenced by hooks.json exists" t_hooks_scripts_exist

t_matcher_catches_reviewers() {
  local pattern gate name
  pattern="$(hooks_q '.hooks.subagentStart[0].matcher // ""')"
  [ -n "$pattern" ] || fail 'subagentStart has no matcher; it would fire for every sub-agent' || return 1
  for gate in architecture security privacy; do
    # The CLI passes the fully namespaced agent name.
    name="autodev-plan:autodev-$gate-review"
    matches "$pattern" "$name" || fail "matcher does not match '$name'" || return 1
  done
}
run_test "the subagentStart matcher catches all three reviewer agents" t_matcher_catches_reviewers

t_matcher_ignores_others() {
  local pattern name
  pattern="$(hooks_q '.hooks.subagentStart[0].matcher // ""')"
  # Note 'security-review' is a CLI built-in and must not be mistaken for our gate.
  for name in explore general-purpose task code-review security-review rubber-duck research; do
    if matches "$pattern" "$name"; then fail "matcher wrongly matches the unrelated agent '$name'"; return 1; fi
  done
}
run_test "the subagentStart matcher ignores unrelated sub-agents" t_matcher_ignores_others

t_pretooluse_matcher_scope() {
  local pattern tool
  pattern="$(hooks_q '.hooks.preToolUse[0].matcher // ""')"
  [ -n "$pattern" ] || fail 'preToolUse has no matcher; it would fire for every tool call' || return 1
  # 'task' must reach the hook so budget exhaustion can refuse further reviewer runs.
  for tool in ask_user task; do
    matches "$pattern" "$tool" || fail "matcher does not match '$tool'" || return 1
  done
  for tool in view edit create bash powershell grep glob web_fetch; do
    if matches "$pattern" "$tool"; then fail "matcher wrongly matches '$tool'"; return 1; fi
  done
}
run_test "the preToolUse matcher covers ask_user and task, and nothing else" t_pretooluse_matcher_scope

t_subagentstop_no_matcher() {
  # The script filters on agentName in-process instead; if a matcher were added here the
  # tracker would silently stop seeing verdicts.
  local m
  m="$(hooks_q '.hooks.subagentStop[0].matcher // ""')"
  [ -z "$m" ] || fail 'subagentStop declares a matcher, which the CLI does not honor for that event'
}
run_test "subagentStop has no matcher, since the CLI does not support one there" t_subagentstop_no_matcher

t_hooks_timeouts() {
  # A command hook that times out is fail-open, so an unset timeout risks a hung session.
  local bad
  bad="$(hooks_q '[.hooks | to_entries[] | .key as $k | .value[] | select(.timeoutSec | not) | $k] | join(", ")')"
  [ -z "$bad" ] || fail "entries without timeoutSec: $bad"
}
run_test "every hook entry sets a timeout" t_hooks_timeouts

# --------------------------------------------------------------------------------------------

if [ "$SHARD" -ge 0 ]; then
  # Machine-readable tally for the dispatcher; it prints the human summary.
  printf 'RESULT %s %s\n' "$PASSED" "$FAILED"
  [ "$FAILED" -gt 0 ] && exit 1
  exit 0
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi
echo "$PASSED passed, 0 failed"
exit 0
