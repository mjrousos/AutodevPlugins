#!/usr/bin/env bash
# Tests for the autodev-implement stage tracker (autodev-stages.sh).
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
# Usage:  bash tests/stages.tests.sh
#         bash tests/stages.tests.sh --sequential     one process, grouped by section
#         bash tests/stages.tests.sh --workers 4      override the worker count
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
STAGE_SCRIPT="$(cd "$TESTS_DIR/.." && pwd)/hooks/scripts/autodev-stages.sh"

# Must match the constants in autodev-stages.sh.
MAX_REVIEW_ATTEMPTS=10
MAX_WORKER_ATTEMPTS=5
MAX_BLOCKS=5
TOTAL_INVOCATIONS_BASE=120
TOTAL_INVOCATIONS_PER_MILESTONE=30

# The session ceiling scales with the milestone count, so a large plan cannot be stranded
# half-implemented by a fixed limit.
max_total() { # [milestones]
  local m="${1:-1}"
  [ "$m" -ge 1 ] 2>/dev/null || m=1
  printf '%s' "$(( TOTAL_INVOCATIONS_BASE + TOTAL_INVOCATIONS_PER_MILESTONE * m ))"
}

PASSED=0
FAILED=0
CURRENT_ERROR=""

if [ ! -f "$STAGE_SCRIPT" ]; then
  echo "Cannot find stage script at $STAGE_SCRIPT" >&2
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
  OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/autodev-stage-shards-XXXXXX")"
  echo
  echo "autodev-implement stage tracker tests (bash), $WORKERS workers"
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

COPILOT_HOME="$(mktemp -d "${TMPDIR:-/tmp}/autodev-stage-tests-XXXXXX")"
export COPILOT_HOME
WORKDIRS="$COPILOT_HOME/work"
mkdir -p "$WORKDIRS"
trap 'rm -rf "$COPILOT_HOME"' EXIT

# Must be unique per call without relying on parent state: this runs inside $( ), which is a
# subshell, so any counter incremented here would be discarded and every test would share one
# session id (and therefore one accumulating state file).
new_session_id() {
  printf 't%s_%s_%s' "$$" "$(date +%s%N 2>/dev/null || date +%s)" "$RANDOM"
}

hook() { # event json
  # A malformed payload makes the hook fail open, so a test that expects '{}' would pass for
  # entirely the wrong reason. Emit an obviously-wrong marker instead so the assertion fails
  # loudly and names the cause.
  printf '%s' "$2" | jq -e . >/dev/null 2>&1 || { printf 'MALFORMED-TEST-PAYLOAD'; return 1; }
  printf '%s\n' "$2" | bash "$STAGE_SCRIPT" "$1"
}

# The tracker keys its files off the session working directory, so give every session its own.
session_cwd() { # sid
  local d="$WORKDIRS/$1"
  mkdir -p "$d" 2>/dev/null
  printf '%s' "$d"
}

state_path() { printf '%s/autodev-implement/stages/%s.json' "$COPILOT_HOME" "$1"; }
view_path()  { printf '%s/.autodev/%s' "$(session_cwd "$1")" "$2"; }

# Writes a todo list in the documented format. The tracker parses milestone headings from it to
# learn how many milestones exist.
set_todo_list() { # sid count [status]
  local sid="$1" count="$2" status="${3:-complete}" dir i
  dir="$(session_cwd "$sid")/.autodev"
  mkdir -p "$dir"
  {
    printf '# Implementation todos\n\n'
    i=1
    while [ "$i" -le "$count" ]; do
      printf '## Milestone %s - milestone %s\n' "$i" "$i"
      printf '**Status:** %s\n\n' "$status"
      i=$((i + 1))
    done
  } > "$dir/todos.md"
}

start_agent() { # sid agent
  hook subagentStart "$(jq -cn --arg s "$1" --arg a "$2" --arg c "$(session_cwd "$1")" \
    '{sessionId:$s, cwd:$c, agentName:("autodev-implement:autodev-" + $a)}')" > /dev/null
}

stop_agent() { # sid agent response
  hook subagentStop "$(jq -cn --arg s "$1" --arg a "$2" --arg r "$3" --arg c "$(session_cwd "$1")" \
    '{sessionId:$s, cwd:$c, agentName:("autodev-implement:autodev-" + $a), response:$r}')"
}

round() { # sid agent verdict -> footer text
  start_agent "$1" "$2"
  stop_agent "$1" "$2" "Body text.

AUTODEV-VERDICT: $3" | jq -r '.modifiedResponse // ""'
}

agent_stop() { # sid
  hook agentStop "$(jq -cn --arg s "$1" --arg c "$(session_cwd "$1")" \
    '{sessionId:$s, cwd:$c, stopReason:"end_turn"}')"
}

tool_check() { # sid toolName
  hook preToolUse "$(jq -cn --arg s "$1" --arg c "$(session_cwd "$1")" --arg t "$2" \
    '{sessionId:$s, cwd:$c, toolName:$t}')"
}

task_check() { # sid agent-type
  # Build the nested JSON in a variable first. macOS ships bash 3.2, whose $( ) parser
  # mishandles parentheses inside an embedded single-quoted program, which silently produced a
  # malformed payload -- and a malformed payload is fail-open, so the assertion that mattered
  # (a deny) turned into a pass-through.
  local cwd args
  cwd="$(session_cwd "$1")"
  args="$(jq -cn --arg a "$2" '{agent_type:$a, prompt:"go"}')"
  hook preToolUse "$(jq -cn --arg s "$1" --arg c "$cwd" --arg t "$args" \
    '{sessionId:$s, cwd:$c, toolName:"task", toolArgs:$t}')"
}

agent_task_check() { # sid agent
  task_check "$1" "autodev-implement:autodev-$2"
}

fail() { CURRENT_ERROR="$1"; return 1; }

assert_equal() { # expected actual because
  [ "$1" = "$2" ] || fail "expected '$1' but got '$2'. ${3:-}"
}

assert_match() { # pattern actual because
  printf '%s' "$2" | grep -qE "$1" || fail "expected match for '$1' but got '$2'. ${3:-}"
}

assert_no_match() { # pattern actual because
  # Must not end with an unconditional `return 0`: `grep && fail` would set CURRENT_ERROR but
  # the function would still report success, and every assertion using it would be vacuous.
  if printf '%s' "$2" | grep -qE "$1"; then
    CURRENT_ERROR="expected NO match for '$1' but got '$2'. ${3:-}"
    return 1
  fi
  return 0
}

# Seeds the enforcement state directly. Used only where reaching a state through real rounds
# would cost dozens of process spawns and the accumulation itself is not what is under test; the
# tests that DO cover accumulation (the review attempt boundary, and two sessions counting
# independently) still drive every round through the hook.
seed_state() { # sid  jq-assignment-expression
  local sid="$1" expr="${2:-.}" path
  path="$(state_path "$sid")"
  mkdir -p "$(dirname "$path")"
  jq -n --arg sid "$sid" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
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
  }' | jq "$expr" > "$path"
}

# The state of a run parked in a named stage, with one milestone that has already closed unless
# the stage says otherwise.
stage_expr() { # stage
  local base='.taskingAttempts=1 | .taskingVerdict="DONE" | .milestoneCount=1 | .currentMilestone=1 | .totalInvocations=1'
  local closed='.completedMilestones=1 | .currentMilestone=2'
  case "$1" in
    tasking)
      printf '%s' '.taskingAttempts=1 | .taskingVerdict="BLOCKED" | .milestoneCount=1 | .currentMilestone=1 | .totalInvocations=1'
      ;;
    milestones)
      printf '%s | .implementAttempts=1 | .implementVerdict="DONE"' "$base"
      ;;
    user-review)
      printf '%s | %s' "$base" "$closed"
      ;;
    security)
      # The user checkpoint has been satisfied; without userReviewReached the security review
      # would still be refused and every assertion below it would test the wrong thing.
      printf '%s | %s | .userReviewReached=1 | .securityAttempts=1 | .securityVerdict="ISSUES"' "$base" "$closed"
      ;;
    privacy)
      printf '%s | %s | .userReviewReached=1 | .securityAttempts=1 | .securityVerdict="PASS" | .privacyAttempts=1 | .privacyVerdict="ISSUES"' "$base" "$closed"
      ;;
    complete)
      printf '%s | %s | .userReviewReached=1 | .securityAttempts=1 | .securityVerdict="PASS" | .privacyAttempts=1 | .privacyVerdict="PASS"' "$base" "$closed"
      ;;
    escalated)
      printf '%s | %s | .userReviewReached=1 | .securityAttempts=%s | .securityVerdict="ISSUES"' "$base" "$closed" "$MAX_REVIEW_ATTEMPTS"
      ;;
  esac
}

seed_stage() { # sid stage [extra-jq]
  seed_state "$1" "$(stage_expr "$2") ${3:-}"
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

echo
echo "autodev-implement stage tracker tests (bash)"
echo "script: $STAGE_SCRIPT"

# ---------------------------------------------------------------------------------------------
section 'Verdict parsing (must read only the final meaningful line)'
# ---------------------------------------------------------------------------------------------

VC_BODY=""
VC_EXPECT=""

t_review_verdict() {
  local sid footer
  sid="$(new_session_id)"
  set_todo_list "$sid" 2
  round "$sid" 'tasking' 'DONE' > /dev/null
  round "$sid" 'implementation' 'DONE' > /dev/null
  start_agent "$sid" 'code-review'
  footer="$(stop_agent "$sid" 'code-review' "$VC_BODY" | jq -r '.modifiedResponse // ""')"
  assert_match "Recorded verdict: $VC_EXPECT" "$footer"
}

review_verdict_case() { # name body expect
  VC_BODY="$2"
  VC_EXPECT="$3"
  run_test "review verdict: $1" t_review_verdict
}

review_verdict_case 'clean PASS' $'Summary.\n\nAUTODEV-VERDICT: PASS' 'PASS'
review_verdict_case 'clean ISSUES' $'Findings.\n\nAUTODEV-VERDICT: ISSUES' 'ISSUES'
review_verdict_case 'trailing blank lines' $'AUTODEV-VERDICT: PASS\n\n\n' 'PASS'
review_verdict_case 'wrapped in a code fence' $'text\n```\nAUTODEV-VERDICT: PASS\n```' 'PASS'
review_verdict_case 'bold markdown' $'text\n\n**AUTODEV-VERDICT: PASS**' 'PASS'
review_verdict_case 'trailing period' $'text\n\nAUTODEV-VERDICT: PASS.' 'PASS'
review_verdict_case 'indented verdict line' $'text\n\n    AUTODEV-VERDICT: PASS' 'PASS'
# A reviewer that reaches for the worker vocabulary means something unambiguous, so it is
# translated rather than charged an attempt for a wording mistake.
review_verdict_case 'reviewer saying DONE is read as PASS' $'text\n\nAUTODEV-VERDICT: DONE' 'PASS'
review_verdict_case 'reviewer saying BLOCKED is read as ISSUES' $'text\n\nAUTODEV-VERDICT: BLOCKED' 'ISSUES'
# The reviewer templates show the verdict as a placeholder. If a model ever copies it literally
# that must fail safe rather than read as a pass.
review_verdict_case 'literal template placeholder is not a pass' $'Summary.\n\nAUTODEV-VERDICT: <PASS or ISSUES>' 'ISSUES'
# The important negatives: a verdict mentioned in prose must never count as the verdict.
review_verdict_case 'mid-body PASS with no final verdict' $'I would say AUTODEV-VERDICT: PASS if fixed.\n\n### blocker Missing authz' 'ISSUES'
review_verdict_case 'mid-body PASS then final ISSUES' $'AUTODEV-VERDICT: PASS maybe\n\nAUTODEV-VERDICT: ISSUES' 'ISSUES'
review_verdict_case 'commentary after the verdict' $'AUTODEV-VERDICT: PASS\nBut actually I am unsure.' 'ISSUES'
review_verdict_case 'no verdict at all' 'I forgot to include one.' 'ISSUES'
review_verdict_case 'empty response' '' 'ISSUES'

t_worker_verdict() {
  local sid footer
  sid="$(new_session_id)"
  set_todo_list "$sid" 1
  start_agent "$sid" 'tasking'
  footer="$(stop_agent "$sid" 'tasking' "$VC_BODY" | jq -r '.modifiedResponse // ""')"
  assert_match "Recorded verdict: $VC_EXPECT" "$footer"
}

worker_verdict_case() { # name body expect
  VC_BODY="$2"
  VC_EXPECT="$3"
  run_test "worker verdict: $1" t_worker_verdict
}

worker_verdict_case 'clean DONE' $'Summary.\n\nAUTODEV-VERDICT: DONE' 'DONE'
worker_verdict_case 'clean BLOCKED' $'Summary.\n\nAUTODEV-VERDICT: BLOCKED' 'BLOCKED'
worker_verdict_case 'worker saying PASS is read as DONE' $'text\n\nAUTODEV-VERDICT: PASS' 'DONE'
worker_verdict_case 'worker saying ISSUES is read as BLOCKED' $'text\n\nAUTODEV-VERDICT: ISSUES' 'BLOCKED'
worker_verdict_case 'no verdict is not DONE' 'I wrote the file, honestly.' 'BLOCKED'
worker_verdict_case 'empty response is not DONE' '' 'BLOCKED'
worker_verdict_case 'commentary after the verdict' $'AUTODEV-VERDICT: DONE\nActually there is more to do.' 'BLOCKED'

# ---------------------------------------------------------------------------------------------
section 'Fail-safes (a hook must never deny a tool call or crash)'
# ---------------------------------------------------------------------------------------------

t_agentstop_no_state() { assert_equal '{}' "$(agent_stop "$(new_session_id)")"; }
run_test 'agentStop with no state returns empty' t_agentstop_no_state

t_askuser_no_state() { assert_equal '{}' "$(tool_check "$(new_session_id)" 'ask_user')"; }
run_test 'ask_user with no state is permitted' t_askuser_no_state

t_task_no_state() {
  assert_equal '{}' "$(agent_task_check "$(new_session_id)" 'code-security-review')"
}
run_test 'task with no state is permitted' t_task_no_state

UNTRACKED_AGENT=""
t_untracked_agent() {
  local sid
  sid="$(new_session_id)"
  assert_equal '{}' "$(hook subagentStart "$(jq -cn --arg s "$sid" --arg a "$UNTRACKED_AGENT" \
    --arg c "$(session_cwd "$sid")" '{sessionId:$s, cwd:$c, agentName:$a}')")"
}
for agent in explore general-purpose security-review code-review task autodev-implement:autodev-implement; do
  UNTRACKED_AGENT="$agent"
  run_test "untracked sub-agent '$agent' is ignored" t_untracked_agent
done

# Both plugins can be installed at once and both watch subagentStart. Neither tracker may
# capture the other's reviewers, or a planning run would spend an implementation budget.
PLAN_AGENT=""
t_plan_agent_ignored() {
  local sid
  sid="$(new_session_id)"
  assert_equal '{}' "$(hook subagentStart "$(jq -cn --arg s "$sid" --arg a "$PLAN_AGENT" \
    --arg c "$(session_cwd "$sid")" '{sessionId:$s, cwd:$c, agentName:$a}')")" || return 1
  [ ! -f "$(state_path "$sid")" ] || fail 'the plan reviewer created implementation state'
}
for agent in autodev-plan:autodev-architecture-review autodev-plan:autodev-security-review autodev-plan:autodev-privacy-review; do
  PLAN_AGENT="$agent"
  run_test "autodev-plan reviewer '$agent' is not captured" t_plan_agent_ignored
done

t_code_review_prefix() {
  local sid footer
  sid="$(new_session_id)"
  seed_stage "$sid" 'security'
  footer="$(round "$sid" 'code-security-review' 'PASS')"
  assert_match 'Stage: code-security-review' "$footer" || return 1
  assert_match 'security=PASS' "$footer"
}
run_test 'code-review does not swallow code-security-review' t_code_review_prefix

# Plugin agents are namespaced, so a suffix match would also capture another installed plugin's
# identically named agent and let it mutate this run's counters.
FOREIGN_AGENT=""
t_foreign_namespace_ignored() {
  local sid
  sid="$(new_session_id)"
  assert_equal '{}' "$(hook subagentStart "$(jq -cn --arg s "$sid" --arg a "$FOREIGN_AGENT" \
    --arg c "$(session_cwd "$sid")" '{sessionId:$s, cwd:$c, agentName:$a}')")" || return 1
  [ ! -f "$(state_path "$sid")" ] || fail 'the foreign agent created implementation state'
}
for agent in other-plugin:autodev-code-review other:autodev-tasking somewhere:autodev-code-security-review; do
  FOREIGN_AGENT="$agent"
  run_test "an agent from another namespace ('$agent') is not captured" t_foreign_namespace_ignored
done

t_foreign_namespace_task_allowed() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" 'milestones'
  assert_equal '{}' "$(task_check "$sid" 'other-plugin:autodev-code-security-review')"
}
run_test 'a task call to a same-named agent in another namespace is never refused' t_foreign_namespace_task_allowed

t_unnamespaced_agent_tracked() {
  # Only a *different* namespace is rejected; a bare name keeps working.
  local sid
  sid="$(new_session_id)"
  set_todo_list "$sid" 1
  hook subagentStart "$(jq -cn --arg s "$sid" --arg c "$(session_cwd "$sid")" \
    '{sessionId:$s, cwd:$c, agentName:"autodev-tasking"}')" > /dev/null
  [ -f "$(state_path "$sid")" ] || fail 'an unnamespaced sub-agent was not tracked'
}
run_test 'an unnamespaced sub-agent name is still tracked' t_unnamespaced_agent_tracked

t_garbage_stdin() {
  # Capture the hook's exit status immediately: checking $? after an assertion would report the
  # assertion helper's status, and a hook that printed '{}' but exited non-zero would slip
  # through -- which is the exact fail-closed regression this case exists to catch.
  local out status
  out="$(printf 'not json at all' | bash "$STAGE_SCRIPT" preToolUse)"
  status=$?
  assert_equal '{}' "$out" || return 1
  assert_equal 0 "$status" 'the hook must exit 0'
}
run_test 'garbage stdin returns empty JSON and exits 0' t_garbage_stdin

t_empty_stdin() {
  local out status
  out="$(printf '' | bash "$STAGE_SCRIPT" preToolUse)"
  status=$?
  assert_equal '{}' "$out" || return 1
  assert_equal 0 "$status" 'the hook must exit 0'
}
run_test 'empty stdin returns empty JSON and exits 0' t_empty_stdin

t_unknown_event() {
  # preToolUse is fail-closed on a non-zero exit, so an unknown event must still emit '{}'.
  local out status
  out="$(printf '{"sessionId":"x"}' | bash "$STAGE_SCRIPT" bogusEvent)"
  status=$?
  assert_equal '{}' "$out" || return 1
  assert_equal 0 "$status" 'the hook must exit 0'
}
run_test 'an unknown event name fails open instead of denying the tool call' t_unknown_event

t_missing_event() {
  local out status
  out="$(printf '{"sessionId":"x"}' | bash "$STAGE_SCRIPT")"
  status=$?
  assert_equal '{}' "$out" || return 1
  assert_equal 0 "$status" 'the hook must exit 0'
}
run_test 'a missing event name fails open' t_missing_event

t_corrupt_state() {
  local sid path
  sid="$(new_session_id)"
  path="$(state_path "$sid")"
  mkdir -p "$(dirname "$path")"
  printf '{ this is not json' > "$path"
  assert_equal '{}' "$(tool_check "$sid" 'ask_user')" || return 1
  assert_equal '{}' "$(agent_stop "$sid")"
}
run_test 'corrupt state file does not deny ask_user or block stopping' t_corrupt_state

t_unowned_state() {
  local sid path
  sid="$(new_session_id)"
  path="$(state_path "$sid")"
  mkdir -p "$(dirname "$path")"
  printf '{"taskingAttempts":1,"taskingVerdict":"running"}' > "$path"
  assert_equal '{}' "$(tool_check "$sid" 'ask_user')"
}
run_test 'a state file with no owner is never adopted' t_unowned_state

t_foreign_state() {
  local sid other
  sid="$(new_session_id)"
  other="$(new_session_id)"
  seed_state "$other" '.taskingAttempts=1 | .taskingVerdict="running"'
  mkdir -p "$(dirname "$(state_path "$sid")")"
  mv "$(state_path "$other")" "$(state_path "$sid")"
  assert_equal '{}' "$(tool_check "$sid" 'ask_user')"
}
run_test 'state belonging to another session is never adopted' t_foreign_state

t_negative_counter() {
  local sid path
  sid="$(new_session_id)"
  path="$(state_path "$sid")"
  mkdir -p "$(dirname "$path")"
  jq -n --arg s "$sid" '{sessionId:$s, taskingAttempts:-4, taskingVerdict:"running"}' > "$path"
  assert_equal '{}' "$(tool_check "$sid" 'ask_user')"
}
run_test 'a negative counter is rejected as corrupt' t_negative_counter

t_mirror_recovery() {
  local sid
  sid="$(new_session_id)"
  set_todo_list "$sid" 1
  start_agent "$sid" 'tasking'
  # Corrupt only the authoritative copy; the workspace mirror must restore the run.
  printf '{ not json' > "$(state_path "$sid")"
  assert_match '"permissionDecision":"deny"' "$(tool_check "$sid" 'ask_user')"
}
run_test 'a corrupt authoritative file falls back to the valid mirror' t_mirror_recovery

t_partial_state() {
  local sid path
  sid="$(new_session_id)"
  path="$(state_path "$sid")"
  mkdir -p "$(dirname "$path")"
  jq -n --arg s "$sid" '{sessionId:$s, taskingAttempts:1, taskingVerdict:"running"}' > "$path"
  assert_match 'autonomous phase \(tasking\)' "$(tool_check "$sid" 'ask_user')"
}
run_test 'partial legacy state receives missing defaults' t_partial_state

t_hostile_session_id() {
  local cwd
  cwd="$(session_cwd 'hostile')"
  hook subagentStart "$(jq -cn --arg c "$cwd" \
    '{sessionId:"../../escaped", cwd:$c, agentName:"autodev-implement:autodev-tasking"}')" > /dev/null
  [ ! -f "$COPILOT_HOME/../escaped.json" ] || fail 'state escaped the sandbox'
  [ -f "$(state_path '.._.._escaped')" ] || fail 'the sanitized state file was not written'
}
run_test 'a hostile session id cannot escape the state directory' t_hostile_session_id

# ---------------------------------------------------------------------------------------------
section 'The stage machine'
# ---------------------------------------------------------------------------------------------

t_fresh_session() {
  local sid out
  sid="$(new_session_id)"
  start_agent "$sid" 'tasking'
  out="$(agent_stop "$sid")"
  assert_match '"decision":"block"' "$out" || return 1
  assert_match 'autodev-tasking' "$out"
}
run_test 'a fresh session starts in tasking and names the tasking agent' t_fresh_session

t_tasking_done() {
  local sid footer
  sid="$(new_session_id)"
  set_todo_list "$sid" 3
  footer="$(round "$sid" 'tasking' 'DONE')"
  assert_match 'Todo list parsed: 3 milestone\(s\)' "$footer" || return 1
  assert_match 'milestones=0/3 done' "$footer" || return 1
  assert_match 'autodev-implementation for milestone 1' "$footer"
}
run_test 'tasking DONE moves to the first milestone and reports the parsed count' t_tasking_done

t_todo_no_headings() {
  local sid footer dir
  sid="$(new_session_id)"
  dir="$(session_cwd "$sid")/.autodev"
  mkdir -p "$dir"
  printf '# Todos\n\nJust some prose.\n' > "$dir/todos.md"
  footer="$(round "$sid" 'tasking' 'DONE')"
  assert_match "does not contain '## Milestone <n>' headings" "$footer" || return 1
  assert_match 'milestones=0/unknown done' "$footer"
}
run_test 'a todo list with no milestone headings warns and degrades' t_todo_no_headings

t_todo_numbering_gap() {
  # Milestones 1 and 3 counted naively would look like two milestones, and the run would go
  # hunting for a milestone 2 that does not exist while never building milestone 3.
  local sid footer dir
  sid="$(new_session_id)"
  dir="$(session_cwd "$sid")/.autodev"
  mkdir -p "$dir"
  printf '## Milestone 1 - a\n**Status:** not-started\n\n## Milestone 3 - c\n**Status:** not-started\n' > "$dir/todos.md"
  footer="$(round "$sid" 'tasking' 'DONE')"
  assert_match 'numbered consecutively from 1' "$footer" || return 1
  assert_match 'milestones=0/unknown done' "$footer"
}
run_test 'a gap in the milestone numbering is rejected rather than miscounted' t_todo_numbering_gap

t_todo_duplicate_number() {
  local sid footer dir
  sid="$(new_session_id)"
  dir="$(session_cwd "$sid")/.autodev"
  mkdir -p "$dir"
  printf '## Milestone 1 - a\n**Status:** not-started\n\n## Milestone 1 - b\n**Status:** not-started\n' > "$dir/todos.md"
  footer="$(round "$sid" 'tasking' 'DONE')"
  assert_match 'milestones=0/unknown done' "$footer"
}
run_test 'a duplicated milestone number is rejected' t_todo_duplicate_number

t_todo_cannot_shrink() {
  # The todo list is in a directory the orchestrator may write to, so it must not be able to end
  # the run early by deleting the milestones it has not done yet.
  local sid footer
  sid="$(new_session_id)"
  set_todo_list "$sid" 3
  round "$sid" 'tasking' 'DONE' > /dev/null
  set_todo_list "$sid" 1
  footer="$(round "$sid" 'implementation' 'DONE')"
  assert_match 'milestones=0/3 done' "$footer"
}
run_test 'a shrinking todo list cannot retire milestones that were never built' t_todo_cannot_shrink

t_milestone_closes_on_pass() {
  local sid issues pass
  sid="$(new_session_id)"
  set_todo_list "$sid" 2
  round "$sid" 'tasking' 'DONE' > /dev/null
  round "$sid" 'implementation' 'DONE' > /dev/null
  issues="$(round "$sid" 'code-review' 'ISSUES')"
  assert_match 'milestones=0/2 done' "$issues" || return 1
  assert_match 'autodev-code-fix' "$issues" || return 1
  pass="$(round "$sid" 'code-review' 'PASS')"
  assert_match 'milestones=1/2 done' "$pass" || return 1
  assert_match 'autodev-implementation for milestone 2' "$pass"
}
run_test 'a milestone closes only when its code review passes' t_milestone_closes_on_pass

t_last_milestone_to_user_review() {
  local sid footer
  sid="$(new_session_id)"
  set_todo_list "$sid" 1
  round "$sid" 'tasking' 'DONE' > /dev/null
  round "$sid" 'implementation' 'DONE' > /dev/null
  footer="$(round "$sid" 'code-review' 'PASS')"
  assert_match 'hand the code back for review' "$footer" || return 1
  assert_match 'Audit trail:' "$footer"
}
run_test 'the last milestone closing moves to the user review checkpoint' t_last_milestone_to_user_review

t_security_then_privacy() {
  local sid sec priv
  sid="$(new_session_id)"
  seed_stage "$sid" 'user-review' '| .userReviewReached=1'
  sec="$(round "$sid" 'code-security-review' 'PASS')"
  assert_match 'autodev-code-privacy-review' "$sec" || return 1
  priv="$(round "$sid" 'code-privacy-review' 'PASS')"
  assert_match 'Proceed to WRAPUP' "$priv"
}
run_test 'security passing moves to privacy, privacy passing completes the run' t_security_then_privacy

# ---------------------------------------------------------------------------------------------
section 'The USER-REVIEW checkpoint is actually enforced'
# ---------------------------------------------------------------------------------------------

t_security_locked_until_handoff() {
  local sid out
  sid="$(new_session_id)"
  seed_stage "$sid" 'user-review'
  out="$(agent_task_check "$sid" 'code-security-review')"
  assert_match '"permissionDecision":"deny"' "$out" || return 1
  assert_match 'has not been given the code to review yet' "$out"
}
run_test 'the security review is refused until the code has been handed to the user' t_security_locked_until_handoff

t_stop_records_handoff() {
  # Closing the last milestone and starting the security review in the same turn would skip the
  # user entirely, so the stop itself is what satisfies the checkpoint.
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" 'user-review'
  assert_equal '{}' "$(agent_stop "$sid")" || return 1
  assert_equal '{}' "$(agent_task_check "$sid" 'code-security-review')"
}
run_test 'ending the turn at the checkpoint records the handoff and unlocks security' t_stop_records_handoff

t_askuser_records_handoff() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" 'user-review'
  assert_equal '{}' "$(tool_check "$sid" 'ask_user')" || return 1
  assert_equal '{}' "$(agent_task_check "$sid" 'code-security-review')"
}
run_test 'asking the user at the checkpoint also records the handoff' t_askuser_records_handoff

t_handoff_audited() {
  local sid audit
  sid="$(new_session_id)"
  seed_stage "$sid" 'user-review'
  agent_stop "$sid" > /dev/null
  audit="$(cat "$(view_path "$sid" 'implement-gate-audit.md')")"
  assert_match 'handed to user' "$audit"
}
run_test 'the handoff is recorded in the audit trail' t_handoff_audited

t_user_fix_returns_to_checkpoint() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" 'user-review'
  agent_stop "$sid" > /dev/null
  round "$sid" 'code-fix' 'DONE' > /dev/null
  assert_match '"permissionDecision":"deny"' "$(agent_task_check "$sid" 'code-security-review')" \
    'the user must approve the fixed code too'
}
run_test 'fixing user-reported issues sends the run back to the checkpoint' t_user_fix_returns_to_checkpoint

t_fix_after_complete_resequences() {
  # The fix changed code that both reviews already judged, so their verdicts are stale.
  local sid footer
  sid="$(new_session_id)"
  seed_stage "$sid" 'complete'
  footer="$(round "$sid" 'code-fix' 'DONE')"
  assert_match 'security=pending' "$footer" || return 1
  assert_match 'privacy=pending' "$footer" || return 1
  assert_match 'autodev-code-security-review' "$footer" || return 1
  assert_no_match 'hand the code back for review' "$footer" 'the user already approved this code'
}
run_test 'a fix after the final reviews passed resequences back to security' t_fix_after_complete_resequences

t_fix_during_privacy_restarts_security() {
  # Security must re-run because the code changed, but the privacy loop keeps its spent budget:
  # refunding it would make the loop unbounded.
  local sid footer
  sid="$(new_session_id)"
  seed_stage "$sid" 'privacy' '| .privacyAttempts=4'
  footer="$(round "$sid" 'code-fix' 'DONE')"
  assert_match 'security=pending\(0/' "$footer" || return 1
  assert_match "privacy=ISSUES\(4/$MAX_REVIEW_ATTEMPTS\)" "$footer" || return 1
  assert_match 'autodev-code-security-review' "$footer"
}
run_test 'a fix during the privacy loop restarts security without refunding privacy rounds' t_fix_during_privacy_restarts_security

t_fix_during_security_keeps_budget() {
  local sid footer
  sid="$(new_session_id)"
  seed_stage "$sid" 'security' '| .securityAttempts=6'
  footer="$(round "$sid" 'code-fix' 'DONE')"
  assert_match "security=ISSUES\(6/$MAX_REVIEW_ATTEMPTS\)" "$footer"
}
run_test 'a fix during the security loop does not refund its rounds' t_fix_during_security_keeps_budget

t_security_rerun_invalidates_privacy() {
  local sid footer
  sid="$(new_session_id)"
  seed_stage "$sid" 'complete'
  footer="$(round "$sid" 'code-security-review' 'PASS')"
  assert_match 'privacy=pending' "$footer" || return 1
  assert_match 'autodev-code-privacy-review' "$footer"
}
run_test 'a security re-review invalidates a privacy verdict for the older code' t_security_rerun_invalidates_privacy

t_status_warning() {
  local sid footer
  sid="$(new_session_id)"
  set_todo_list "$sid" 1 'in-progress'
  round "$sid" 'tasking' 'DONE' > /dev/null
  footer="$(round "$sid" 'implementation' 'DONE')"
  assert_match "still reads '\*\*Status:\*\* in-progress'" "$footer"
}
run_test 'an implementation DONE against an unfinished milestone status warns' t_status_warning

t_fix_does_not_consume_review() {
  local sid footer
  sid="$(new_session_id)"
  set_todo_list "$sid" 1
  round "$sid" 'tasking' 'DONE' > /dev/null
  round "$sid" 'implementation' 'DONE' > /dev/null
  round "$sid" 'code-review' 'ISSUES' > /dev/null
  footer="$(round "$sid" 'code-fix' 'DONE')"
  assert_match "review=ISSUES\(1/$MAX_REVIEW_ATTEMPTS\)" "$footer"
}
run_test 'a fix agent invocation does not consume a review attempt' t_fix_does_not_consume_review

t_stale_review_cannot_close_milestone() {
  # Ordering denies this call, but the tracker must not depend on that alone: a PASS about code
  # that did not exist yet would otherwise close the milestone the instant the implementation
  # agent finished, and the delivered code would never be reviewed.
  local sid footer
  sid="$(new_session_id)"
  set_todo_list "$sid" 1
  round "$sid" 'tasking' 'DONE' > /dev/null
  round "$sid" 'code-review' 'PASS' > /dev/null
  footer="$(round "$sid" 'implementation' 'DONE')"
  assert_match 'milestones=0/1 done' "$footer" || return 1
  assert_match 'review=pending\(0/' "$footer" || return 1
  assert_match 'autodev-code-review for milestone 1' "$footer"
}
run_test 'a review recorded before implementation cannot close the milestone' t_stale_review_cannot_close_milestone

t_review_before_implementation_denied() {
  local sid out
  sid="$(new_session_id)"
  seed_stage "$sid" 'milestones' '| .implementVerdict="pending" | .implementAttempts=0'
  out="$(agent_task_check "$sid" 'code-review')"
  assert_match '"permissionDecision":"deny"' "$out" || return 1
  assert_match 'has not been implemented yet' "$out"
}
run_test 'reviewing a milestone before it is implemented is refused' t_review_before_implementation_denied

t_implementation_invalidates_final_reviews() {
  # Those reviews judge the whole implementation, so a verdict predating new code is stale. A
  # stale PASS would let the run skip the USER-REVIEW checkpoint and the final reviews.
  local sid footer
  sid="$(new_session_id)"
  set_todo_list "$sid" 2
  seed_state "$sid" '.taskingAttempts=1 | .taskingVerdict="DONE" | .milestoneCount=2 | .currentMilestone=2 | .completedMilestones=1 | .securityAttempts=1 | .securityVerdict="PASS" | .privacyAttempts=1 | .privacyVerdict="PASS" | .totalInvocations=5'
  footer="$(round "$sid" 'implementation' 'DONE')"
  assert_match 'security=pending' "$footer" || return 1
  assert_match 'privacy=pending' "$footer"
}
run_test 'implementing new code invalidates an earlier security and privacy pass' t_implementation_invalidates_final_reviews

t_early_security_pass_cannot_skip_user_review() {
  local sid footer
  sid="$(new_session_id)"
  set_todo_list "$sid" 1
  round "$sid" 'code-security-review' 'PASS' > /dev/null
  round "$sid" 'tasking' 'DONE' > /dev/null
  round "$sid" 'implementation' 'DONE' > /dev/null
  footer="$(round "$sid" 'code-review' 'PASS')"
  assert_match 'security=pending' "$footer" || return 1
  assert_match 'hand the code back for review' "$footer"
}
run_test 'a security pass recorded before tasking cannot skip the user review checkpoint' t_early_security_pass_cannot_skip_user_review

# ---------------------------------------------------------------------------------------------
section 'Blocking a premature stop'
# ---------------------------------------------------------------------------------------------

STAGE_UNDER_TEST=""

t_stop_blocked() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" "$STAGE_UNDER_TEST"
  assert_match '"decision":"block"' "$(agent_stop "$sid")"
}
for stage in tasking milestones security privacy; do
  STAGE_UNDER_TEST="$stage"
  run_test "agentStop is blocked during the autonomous '$stage' stage" t_stop_blocked
done

t_stop_permitted() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" "$STAGE_UNDER_TEST"
  assert_equal '{}' "$(agent_stop "$sid")"
}
for stage in user-review complete escalated; do
  STAGE_UNDER_TEST="$stage"
  run_test "agentStop is permitted at '$stage'" t_stop_permitted
done

t_block_names_next_agent() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" 'milestones'
  assert_match 'autodev-implement:autodev-code-review for milestone 1' "$(agent_stop "$sid")"
}
run_test 'the block reason names the exact next sub-agent' t_block_names_next_agent

t_block_ceiling() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" 'milestones' "| .blocks=$MAX_BLOCKS"
  assert_equal '{}' "$(agent_stop "$sid")"
}
run_test 'the tracker surrenders after the block ceiling' t_block_ceiling

t_progress_forgives_blocks() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" 'milestones' "| .blocks=$((MAX_BLOCKS - 1))"
  round "$sid" 'code-review' 'ISSUES' > /dev/null
  assert_match '"decision":"block"' "$(agent_stop "$sid")"
}
run_test 'real progress forgives earlier blocked stops' t_progress_forgives_blocks

# ---------------------------------------------------------------------------------------------
section 'ask_user is denied only while the run is autonomous'
# ---------------------------------------------------------------------------------------------

t_askuser_denied() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" "$STAGE_UNDER_TEST"
  assert_match '"permissionDecision":"deny"' "$(tool_check "$sid" 'ask_user')"
}
for stage in tasking milestones security privacy; do
  STAGE_UNDER_TEST="$stage"
  run_test "ask_user is denied during '$stage'" t_askuser_denied
done

t_askuser_permitted() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" "$STAGE_UNDER_TEST"
  assert_equal '{}' "$(tool_check "$sid" 'ask_user')"
}
for stage in user-review complete escalated; do
  STAGE_UNDER_TEST="$stage"
  run_test "ask_user is permitted at '$stage'" t_askuser_permitted
done

t_askuserquestion_denied() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" 'milestones'
  assert_match '"permissionDecision":"deny"' "$(tool_check "$sid" 'AskUserQuestion')"
}
run_test 'AskUserQuestion is denied the same way as ask_user' t_askuserquestion_denied

t_unrelated_tool_allowed() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" 'milestones'
  assert_equal '{}' "$(tool_check "$sid" 'edit')"
}
run_test 'an unrelated tool is never denied while the run is autonomous' t_unrelated_tool_allowed

# ---------------------------------------------------------------------------------------------
section 'Out-of-order sub-agent invocations are refused'
# ---------------------------------------------------------------------------------------------

ORDER_STAGE=""
ORDER_AGENT=""
ORDER_EXPECT=""

t_ordering() {
  local sid out
  sid="$(new_session_id)"
  seed_stage "$sid" "$ORDER_STAGE"
  out="$(agent_task_check "$sid" "$ORDER_AGENT")"
  if [ "$ORDER_EXPECT" = "allow" ]; then
    assert_equal '{}' "$out"
  else
    assert_match '"permissionDecision":"deny"' "$out"
  fi
}

ordering_case() { # stage agent expect
  ORDER_STAGE="$1"
  ORDER_AGENT="$2"
  ORDER_EXPECT="$3"
  run_test "ordering: $2 during $1 is ${3}ed" t_ordering
}

ordering_case tasking      implementation        deny
ordering_case tasking      code-security-review  deny
ordering_case tasking      tasking               allow
ordering_case tasking      code-fix              allow
ordering_case milestones   code-security-review  deny
ordering_case milestones   code-privacy-review   deny
ordering_case milestones   code-review           allow
ordering_case milestones   code-fix              allow
ordering_case milestones   implementation        allow
ordering_case user-review  code-security-review  deny
ordering_case user-review  code-fix              allow
ordering_case user-review  code-privacy-review   deny
ordering_case user-review  code-review           deny
ordering_case user-review  implementation        deny
ordering_case security     code-security-review  allow
ordering_case security     code-fix              allow
ordering_case security     code-privacy-review   deny
ordering_case privacy      code-privacy-review   allow
ordering_case privacy      code-fix              allow
ordering_case privacy      code-security-review  deny
ordering_case complete     code-fix              allow
ordering_case complete     code-security-review  allow

t_next_milestone_blocked_by_review() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" 'milestones' '| .reviewAttempts=1 | .reviewVerdict="ISSUES"'
  assert_match '"permissionDecision":"deny"' "$(agent_task_check "$sid" 'implementation')"
}
run_test 'starting the next milestone is refused while the current review is unresolved' t_next_milestone_blocked_by_review

t_other_plugin_task_allowed() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" 'milestones'
  assert_equal '{}' "$(task_check "$sid" 'autodev-plan:autodev-security-review')"
}
run_test 'a task call to an agent from another plugin is never refused' t_other_plugin_task_allowed

t_builtin_task_allowed() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" 'milestones'
  assert_equal '{}' "$(task_check "$sid" 'explore')"
}
run_test 'a task call to a built-in agent is never refused' t_builtin_task_allowed

t_retasking_denied_after_progress() {
  # Re-tasking rewrites the milestone list; a shorter one would retire milestones that were
  # never built.
  local sid out
  sid="$(new_session_id)"
  seed_stage "$sid" 'milestones'
  out="$(agent_task_check "$sid" 'tasking')"
  assert_match '"permissionDecision":"deny"' "$out" || return 1
  assert_match 'milestone work has already started' "$out"
}
run_test 're-tasking is refused once milestone work has started' t_retasking_denied_after_progress

t_retasking_allowed_before_progress() {
  local sid
  sid="$(new_session_id)"
  seed_stage "$sid" 'milestones' '| .implementVerdict="pending" | .implementAttempts=0 | .reviewAttempts=0 | .completedMilestones=0'
  assert_equal '{}' "$(agent_task_check "$sid" 'tasking')"
}
run_test 're-tasking is still allowed before any milestone work has started' t_retasking_allowed_before_progress

# ---------------------------------------------------------------------------------------------
section 'Attempt caps'
# ---------------------------------------------------------------------------------------------

t_review_cap_proceeds() {
  local sid footer
  sid="$(new_session_id)"
  set_todo_list "$sid" 2
  seed_state "$sid" ".taskingAttempts=1 | .taskingVerdict=\"DONE\" | .milestoneCount=2 | .currentMilestone=1 | .implementAttempts=1 | .implementVerdict=\"DONE\" | .reviewAttempts=$((MAX_REVIEW_ATTEMPTS - 1)) | .reviewVerdict=\"ISSUES\" | .totalInvocations=12"
  footer="$(round "$sid" 'code-review' 'ISSUES')"
  assert_match "used all $MAX_REVIEW_ATTEMPTS code review rounds" "$footer" || return 1
  assert_match 'milestones=1/2 done' "$footer" || return 1
  assert_match 'autodev-implementation for milestone 2' "$footer" || return 1
  assert_no_match 'escalate to the user' "$footer" 'code review proceeds rather than escalating'
}
run_test 'a code review at its cap closes the milestone and moves on' t_review_cap_proceeds

t_review_below_cap_loops() {
  local sid footer
  sid="$(new_session_id)"
  set_todo_list "$sid" 2
  seed_state "$sid" ".taskingAttempts=1 | .taskingVerdict=\"DONE\" | .milestoneCount=2 | .currentMilestone=1 | .implementAttempts=1 | .implementVerdict=\"DONE\" | .reviewAttempts=$((MAX_REVIEW_ATTEMPTS - 2)) | .reviewVerdict=\"ISSUES\" | .totalInvocations=11"
  footer="$(round "$sid" 'code-review' 'ISSUES')"
  assert_match 'milestones=0/2 done' "$footer" || return 1
  assert_match 'autodev-code-fix' "$footer"
}
run_test 'one round below the cap still loops rather than closing the milestone' t_review_below_cap_loops

t_security_cap_escalates() {
  local sid footer
  sid="$(new_session_id)"
  seed_stage "$sid" 'security' "| .securityAttempts=$((MAX_REVIEW_ATTEMPTS - 1)) | .totalInvocations=15"
  footer="$(round "$sid" 'code-security-review' 'ISSUES')"
  assert_match 'escalate to the user' "$footer" || return 1
  assert_match "security review used all $MAX_REVIEW_ATTEMPTS permitted rounds" "$footer"
}
run_test 'the security review escalates at its cap instead of proceeding' t_security_cap_escalates

t_privacy_cap_escalates() {
  local sid footer
  sid="$(new_session_id)"
  seed_stage "$sid" 'privacy' "| .privacyAttempts=$((MAX_REVIEW_ATTEMPTS - 1)) | .totalInvocations=20"
  footer="$(round "$sid" 'code-privacy-review' 'ISSUES')"
  assert_match 'escalate to the user' "$footer" || return 1
  assert_match "privacy review used all $MAX_REVIEW_ATTEMPTS permitted rounds" "$footer"
}
run_test 'the privacy review escalates at its cap' t_privacy_cap_escalates

t_tasking_cap_escalates() {
  local sid footer
  sid="$(new_session_id)"
  seed_state "$sid" ".taskingAttempts=$((MAX_WORKER_ATTEMPTS - 1)) | .taskingVerdict=\"BLOCKED\" | .totalInvocations=4"
  footer="$(round "$sid" 'tasking' 'BLOCKED')"
  assert_match 'escalate to the user' "$footer" || return 1
  assert_match "tasking stage used all $MAX_WORKER_ATTEMPTS permitted attempts" "$footer"
}
run_test 'a tasking agent that keeps failing escalates at the worker cap' t_tasking_cap_escalates

t_implementation_cap_escalates() {
  local sid footer
  sid="$(new_session_id)"
  set_todo_list "$sid" 1
  seed_state "$sid" ".taskingAttempts=1 | .taskingVerdict=\"DONE\" | .milestoneCount=1 | .currentMilestone=1 | .implementAttempts=$((MAX_WORKER_ATTEMPTS - 1)) | .implementVerdict=\"BLOCKED\" | .totalInvocations=6"
  footer="$(round "$sid" 'implementation' 'BLOCKED')"
  assert_match 'escalate to the user' "$footer" || return 1
  assert_match 'permitted implementation attempts' "$footer"
}
run_test 'an implementation agent that keeps failing escalates at the worker cap' t_implementation_cap_escalates

t_total_ceiling() {
  local sid footer ceiling
  sid="$(new_session_id)"
  ceiling="$(max_total 1)"
  seed_stage "$sid" 'milestones' "| .totalInvocations=$((ceiling - 1))"
  footer="$(round "$sid" 'code-review' 'ISSUES')"
  assert_match "all $ceiling permitted sub-agent invocations" "$footer"
}
run_test 'the session-wide invocation ceiling escalates' t_total_ceiling

t_ceiling_scales() {
  # A fixed ceiling would cut a long run off before its milestones could spend their own
  # budgets, leaving the plan half-implemented -- the one outcome this workflow forbids.
  local sid footer worst
  sid="$(new_session_id)"
  set_todo_list "$sid" 8
  worst=$(( 1 + 8 * (1 + 2 * MAX_REVIEW_ATTEMPTS) + 2 * (2 * MAX_REVIEW_ATTEMPTS) ))
  seed_state "$sid" ".taskingAttempts=1 | .taskingVerdict=\"DONE\" | .milestoneCount=8 | .currentMilestone=1 | .implementAttempts=1 | .implementVerdict=\"DONE\" | .totalInvocations=$worst"
  footer="$(round "$sid" 'code-review' 'ISSUES')"
  assert_no_match 'permitted sub-agent invocations' "$footer" 'the ceiling fired inside a legitimate run'
}
run_test 'the invocation ceiling scales so a large plan is never stranded' t_ceiling_scales

t_escalated_refuses_everything() {
  local sid agent
  sid="$(new_session_id)"
  seed_stage "$sid" 'escalated'
  for agent in tasking implementation code-review code-fix code-security-review code-privacy-review; do
    assert_match '"permissionDecision":"deny"' "$(agent_task_check "$sid" "$agent")" "agent $agent" || return 1
  done
}
run_test 'every sub-agent invocation is refused once escalated' t_escalated_refuses_everything

t_security_rerun_fresh_budget() {
  local sid footer
  sid="$(new_session_id)"
  seed_stage "$sid" 'complete' '| .securityAttempts=7'
  footer="$(round "$sid" 'code-security-review' 'PASS')"
  assert_match "security=PASS\(1/$MAX_REVIEW_ATTEMPTS\)" "$footer"
}
run_test 'a re-run security review after a pass starts a fresh budget' t_security_rerun_fresh_budget

t_sessions_independent() {
  local a b footer_a footer_b sid
  a="$(new_session_id)"
  b="$(new_session_id)"
  for sid in "$a" "$b"; do
    set_todo_list "$sid" 1
    round "$sid" 'tasking' 'DONE' > /dev/null
    round "$sid" 'implementation' 'DONE' > /dev/null
  done
  round "$a" 'code-review' 'ISSUES' > /dev/null
  round "$a" 'code-review' 'ISSUES' > /dev/null
  footer_a="$(round "$a" 'code-review' 'ISSUES')"
  footer_b="$(round "$b" 'code-review' 'ISSUES')"
  assert_match 'Attempt 3' "$footer_a" || return 1
  assert_match 'Attempt 1' "$footer_b"
}
run_test 'two sessions count their attempts independently' t_sessions_independent

# ---------------------------------------------------------------------------------------------
section 'Workspace artifacts'
# ---------------------------------------------------------------------------------------------

t_no_stray_autodev_dir() {
  local sid
  sid="$(new_session_id)"
  hook subagentStart "$(jq -cn --arg s "$sid" --arg c "$(session_cwd "$sid")" \
    '{sessionId:$s, cwd:$c, agentName:"explore"}')" > /dev/null
  [ ! -d "$(session_cwd "$sid")/.autodev" ] || fail 'an unrelated session created .autodev'
}
run_test 'an unrelated session never creates a .autodev directory' t_no_stray_autodev_dir

t_audit_rows() {
  local sid audit
  sid="$(new_session_id)"
  set_todo_list "$sid" 1
  round "$sid" 'tasking' 'DONE' > /dev/null
  round "$sid" 'implementation' 'DONE' > /dev/null
  audit="$(cat "$(view_path "$sid" 'implement-gate-audit.md')")"
  assert_match '\| tasking \| - \| 1 \| invoked \| - \|' "$audit" || return 1
  assert_match '\| implementation \| 1 \| 1 \| completed \| DONE \|' "$audit"
}
run_test 'the audit trail records both lifecycle events with the milestone' t_audit_rows

t_audit_milestone_close() {
  local sid audit
  sid="$(new_session_id)"
  set_todo_list "$sid" 1
  round "$sid" 'tasking' 'DONE' > /dev/null
  round "$sid" 'implementation' 'DONE' > /dev/null
  round "$sid" 'code-review' 'PASS' > /dev/null
  audit="$(cat "$(view_path "$sid" 'implement-gate-audit.md')")"
  assert_match 'milestone-closed \(passed\)' "$audit"
}
run_test 'closing a milestone is recorded in the audit trail' t_audit_milestone_close

t_feedback_verbatim() {
  local sid log
  sid="$(new_session_id)"
  set_todo_list "$sid" 1
  start_agent "$sid" 'tasking'
  stop_agent "$sid" 'tasking' "A distinctive finding about caching.

AUTODEV-VERDICT: DONE" > /dev/null
  log="$(cat "$(view_path "$sid" 'implement-feedback-log.md')")"
  assert_match 'A distinctive finding about caching' "$log"
}
run_test 'the feedback log captures the response verbatim' t_feedback_verbatim

t_non_ascii() {
  local sid footer
  sid="$(new_session_id)"
  set_todo_list "$sid" 1
  start_agent "$sid" 'tasking'
  footer="$(stop_agent "$sid" 'tasking' "Use an en dash – and a curly quote ’ here.

AUTODEV-VERDICT: DONE" | jq -r '.modifiedResponse // ""')"
  assert_match 'en dash – and a curly quote ’' "$footer"
}
run_test 'a non-ASCII response survives the round trip' t_non_ascii

t_mirror_written() {
  local sid mirror
  sid="$(new_session_id)"
  set_todo_list "$sid" 1
  round "$sid" 'tasking' 'DONE' > /dev/null
  mirror="$(cat "$(view_path "$sid" 'implement-status.json')")"
  assert_equal "$sid" "$(printf '%s' "$mirror" | jq -r '.sessionId')" || return 1
  assert_equal 'DONE' "$(printf '%s' "$mirror" | jq -r '.taskingVerdict')"
}
run_test 'the state mirror is written next to the todo list' t_mirror_written

t_no_workspace() {
  local sid
  sid="$(new_session_id)"
  # No cwd at all: the view directory falls back to the state directory, and enforcement must
  # still work.
  hook subagentStart "$(jq -cn --arg s "$sid" \
    '{sessionId:$s, cwd:"", agentName:"autodev-implement:autodev-tasking"}')" > /dev/null
  assert_match '"decision":"block"' \
    "$(hook agentStop "$(jq -cn --arg s "$sid" '{sessionId:$s, cwd:"", stopReason:"end_turn"}')")"
}
run_test 'the tracker still enforces when there is no workspace to write to' t_no_workspace

# ---------------------------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------------------------

echo
if [ "$SHARD" -ge 0 ]; then
  # The dispatcher parses this line; it must be the only RESULT line a worker prints.
  echo "RESULT $PASSED $FAILED"
  exit 0
fi
if [ "$FAILED" -gt 0 ]; then
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi
echo "$PASSED passed, 0 failed"
exit 0
