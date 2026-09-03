#!/usr/bin/env bash
# Gate tracker for the autodev-plan plugin (Linux / macOS).
#
# Invoked by hooks.json for four hook events. Reads the hook payload as JSON on stdin and
# writes exactly one JSON object to stdout.
#
#   subagentStart - record that a review gate was invoked; increment its attempt counter.
#   subagentStop  - parse the reviewer's verdict, record it, log the reviewer's full feedback,
#                   and append a tracker footer to the response the orchestrator receives.
#   agentStop     - block the orchestrator from ending its turn while gates are outstanding.
#   preToolUse    - deny ask_user while gating, so the gate phase stays autonomous, and deny
#                   further reviewer invocations once the attempt budget is spent.
#
# All three artifacts are written into '<session cwd>/.autodev/' so a developer can watch a run
# in progress and read the reviews afterwards, next to the plan the gates are reviewing.
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
MAX_ATTEMPTS=10
# Kept below the CLI's own 8-block runaway guard so we surrender first.
MAX_BLOCKS=5
# Absolute ceiling across all gates and all re-gate passes. Because a re-gate resets a gate's
# per-pass budget, this is what makes an unbounded re-gate cascade impossible. Must stay above
# (number of gates * MAX_ATTEMPTS), or it would fire before a single pass could spend the
# per-gate budget and would silently become the real limit.
MAX_TOTAL_INVOCATIONS=40
# Defensive ceiling on the finding count exported as autodev.issues. A pathological or malicious
# reviewer response must not turn into an absurd metric value.
MAX_FINDINGS=500

count_findings() {
  # Counts the findings a reviewer reported, from the '### [severity] title' heading every reviewer
  # agent is required to emit. This is what autodev.issues carries, so a dashboard can answer "how
  # many problems were found" rather than only "how many gates came back dirty" -- the latter is
  # already answered by counting autodev.verdict = ISSUES.
  #
  # Counted for every verdict, not just ISSUES: a PASS that still raised nits genuinely found them.
  #
  # The heading is matched rather than the severity word alone, so prose mentioning "[minor]"
  # mid-sentence cannot inflate the count. A deeper '####' heading is excluded naturally: the
  # character after '###' must be whitespace or '['. The literal template line
  # '### [blocker|major|minor|nit] <title>' does not match either, so echoing the template is not
  # counted.
  local n
  # grep exits 1 when nothing matches, which under the ERR trap must not surface: '|| n=0'.
  n="$(printf '%s\n' "${1:-}" | tr -d '\r' \
    | grep -ciE '^ {0,3}###[[:space:]]*\[(blocker|major|minor|nit)\]' 2>/dev/null)" || n=0
  n="$(printf '%s' "$n" | tr -cd '0-9')"
  [ -n "$n" ] || n=0
  if [ "$n" -gt "$MAX_FINDINGS" ] 2>/dev/null; then n="$MAX_FINDINGS"; fi
  printf '%s' "$n"
}

json_get() { printf '%s' "$RAW_INPUT" | jq -r "$1 // \"\"" 2>/dev/null; }

# Numeric payload field, defaulting to 0. Kept separate from json_get because --argjson rejects
# an empty string, which would abort the whole span document.
json_get_num() {
  local v
  v="$(printf '%s' "$RAW_INPUT" | jq -r "$1 // 0" 2>/dev/null)"
  case "$v" in
    '' | *[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

SESSION_ID="$(json_get '.sessionId')"
SESSION_CWD="$(json_get '.cwd')"

# Enforcement state lives at '<COPILOT_HOME>/autodev-plan/gates/<sessionId>.json', outside the
# workspace and keyed by session. That matters for two reasons: concurrent sessions in one
# repository must not clobber each other's attempt counters, and the orchestrator is allowed to
# edit files in the workspace, so state it could rewrite would not be enforcement at all.
#
# A mirror of that state, the audit trail and the reviewer feedback log are written into
# '<session cwd>/.autodev/' so a developer can watch a run in progress and read the reviews
# afterwards. Audit and feedback are records only. The state mirror is read only as an
# exact-session recovery checkpoint when authoritative state is missing or corrupt; normal
# enforcement always prefers the external state.
#
# Paths are resolved here but nothing is created; see ensure_dir. The hook runs on every matching
# event in every session, and creating directories eagerly would litter an empty '.autodev' into
# any repository where an unrelated session happened to call the task tool.
COPILOT_HOME_DIR="${COPILOT_HOME:-$HOME/.copilot}"
STATE_DIR="$COPILOT_HOME_DIR/autodev-plan/gates"

if [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
  VIEW_DIR="$SESSION_CWD/.autodev"
else
  VIEW_DIR="$STATE_DIR"
fi

# Called only once a real review gate has been identified, so directories appear exactly when the
# workflow starts using them.
ensure_dir() { [ -d "$1" ] || mkdir -p "$1" 2>/dev/null; }

# Defend against path traversal via a hostile session id.
SAFE_SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$SAFE_SESSION_ID" ] || SAFE_SESSION_ID="unknown-session"

STATE_PATH="$STATE_DIR/$SAFE_SESSION_ID.json"
MIRROR_PATH="$VIEW_DIR/gate-status.json"
AUDIT_PATH="$VIEW_DIR/gate-audit.md"
FEEDBACK_PATH="$VIEW_DIR/feedback-log.md"

default_state() {
  jq -n --arg sid "$SAFE_SESSION_ID" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
  sessionId: $sid, createdAt: $now, updatedAt: $now, blocks: 0, totalInvocations: 0,
    architectureAttempts: 0, architectureVerdict: "pending",
    securityAttempts: 0,     securityVerdict: "pending",
    privacyAttempts: 0,      privacyVerdict: "pending"
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
    def verdict_ok($key):
      (has($key) | not)
      or (.[$key] | type == "string" and
          (. == "pending" or . == "running" or . == "PASS" or . == "ISSUES"));
    counter_ok("blocks")
    and counter_ok("totalInvocations")
    and counter_ok("architectureAttempts")
    and counter_ok("securityAttempts")
    and counter_ok("privacyAttempts")
    and verdict_ok("architectureVerdict")
    and verdict_ok("securityVerdict")
    and verdict_ok("privacyVerdict")
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
  # The workspace copy is also a recovery checkpoint. If the authoritative directory is
  # deleted mid-run, restore an exact session-id match rather than treating the next reviewer
  # as the first gate and erasing the prior audit and feedback.
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

state_num() { printf '%s' "$1" | jq -r ".$2 // 0" 2>/dev/null; }
state_str() { printf '%s' "$1" | jq -r ".$2 // \"pending\"" 2>/dev/null; }

# Directory this script lives in, so the telemetry emitter beside it can be found regardless of
# the hook's working directory. Resolved with parameter expansion rather than 'dirname' so it
# still works on a minimal PATH -- 'cd' and 'pwd' are builtins, 'dirname' is not. The
# '|| SCRIPT_DIR=' keeps a failure here off the ERR trap.
SCRIPT_SELF="${BASH_SOURCE[0]}"
SCRIPT_SELF_DIR="${SCRIPT_SELF%/*}"
# No slash at all means the script was invoked by bare name, so it lives in the current directory.
# Written as if/fi rather than '&&' because a false test at top level would fire the ERR trap.
if [ "$SCRIPT_SELF_DIR" = "$SCRIPT_SELF" ]; then SCRIPT_SELF_DIR="."; fi
SCRIPT_DIR="$(cd "$SCRIPT_SELF_DIR" >/dev/null 2>&1 && pwd)" || SCRIPT_DIR=""

telemetry_enabled() {
  # Cheap early-out for the overwhelming majority of users, who never opt in to hook telemetry.
  # Deliberately free of subprocesses: trimming is pure parameter expansion and the truthy match
  # uses bracket classes, so no 'tr' is spawned on every hook event just to decide not to emit.
  # Bracket classes rather than '${v,,}', which needs bash 4 and would break the macOS bash 3.2
  # this also has to run on.
  #
  # Keyed off AUTODEV_OTEL_* rather than Copilot's own OTEL_* variables because Copilot CLI
  # scrubs every 'OTEL_'/'COPILOT_OTEL_' prefixed variable from a command hook's environment, so
  # the latter are never visible here. COPILOT_OTEL_ENABLED remains a fallback for hosts that do
  # not scrub. Trimming and case handling must stay identical to telemetry_enabled() in
  # autodev-otel.sh: a gate stricter than the emitter silently drops spans, and one that is looser
  # spawns an emitter process that only exits again.
  local value

  # Tri-state: set-and-falsy is an explicit OFF that outranks every other signal. Whitespace is
  # stripped wholesale rather than trimmed, exactly as is_truthy() in autodev-otel.sh does with
  # 'tr -d', so the gate and the emitter can never disagree about a value.
  value="${AUTODEV_OTEL_ENABLED:-}"
  value="${value//[[:space:]]/}"
  case "$value" in
    '') ;;
    1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss] | [Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac

  # Written as if/fi rather than '&&': a false test at statement level would fire the ERR trap.
  for value in "${AUTODEV_OTEL_TRACES_ENDPOINT:-}" "${AUTODEV_OTEL_ENDPOINT:-}"; do
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [ -n "$value" ]; then return 0; fi
  done

  value="${COPILOT_OTEL_ENABLED:-}"
  value="${value//[[:space:]]/}"
  case "$value" in
    1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss] | [Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}

send_otel_span() {
  # Runs the OTLP emitter as an ISOLATED CHILD PROCESS with stdin closed and both output streams
  # discarded. This is a safety requirement, not a style preference: this script installs an ERR
  # trap that prints '{}' and exits, so a non-zero return from curl running in this process would
  # destroy the tracker footer the gate depends on. The trailing '|| :' below is what keeps a
  # failing child off that trap; do not remove it.
  local request="$1" emitter tmp
  telemetry_enabled || return 0
  [ -n "$SCRIPT_DIR" ] || return 0
  emitter="$SCRIPT_DIR/autodev-otel.sh"
  [ -f "$emitter" ] || return 0
  tmp="$(mktemp 2>/dev/null)" || return 0
  printf '%s' "$request" > "$tmp" 2>/dev/null || :
  bash "$emitter" "$tmp" >/dev/null 2>&1 </dev/null || :
  rm -f "$tmp" 2>/dev/null || :
  return 0
}

add_audit_row() {
  local gate="$1" attempt="$2" action="$3" verdict="$4" session_marker
  session_marker="Session: \`$SAFE_SESSION_ID\`"
  if [ ! -f "$AUDIT_PATH" ]; then
    {
      printf '# autodev-plan review gate audit\n\n'
      printf '%s\n' "$session_marker"
      printf 'Started: %s\n\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
      printf 'Every row below was written by a hook observing a real sub-agent lifecycle event.\n'
      printf 'The orchestrator does not write this file and is instructed not to edit it, but it\n'
      printf 'lives in your workspace, so treat it as a record rather than as proof.\n\n'
      printf '| Time (UTC) | Gate | Attempt | Event | Verdict |\n'
      printf '| --- | --- | --- | --- | --- |\n'
    } > "$AUDIT_PATH" 2>/dev/null
  elif ! grep -Fqx "$session_marker" "$AUDIT_PATH" 2>/dev/null; then
    {
      printf '\n---\n\n'
      printf '%s\n' "$session_marker"
      printf 'Started: %s\n\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
      printf '| Time (UTC) | Gate | Attempt | Event | Verdict |\n'
      printf '| --- | --- | --- | --- | --- |\n'
    } >> "$AUDIT_PATH" 2>/dev/null
  fi
  printf '| %s | %s | %s | %s | %s |\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%S')" "$gate" "$attempt" "$action" "$verdict" \
    >> "$AUDIT_PATH" 2>/dev/null
  # Auditability must never control enforcement. A missing/read-only workspace still gets the
  # block or deny response derived from authoritative state.
  return 0
}

add_feedback_entry() {
  local gate="$1" attempt="$2" verdict="$3" response="$4" session_marker
  session_marker="Session: \`$SAFE_SESSION_ID\`"
  if [ ! -f "$FEEDBACK_PATH" ]; then
    {
      printf '# autodev-plan reviewer feedback log\n\n'
      printf '%s\n' "$session_marker"
      printf 'Started: %s\n\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
      printf "Each entry is the reviewer sub-agent's verbatim response, captured by a hook as the\n"
      printf 'sub-agent finished. The orchestrator does not write this file and is instructed not\n'
      printf 'to edit it, so it records what the reviewers actually said rather than what the\n'
      printf 'orchestrator chose to relay. It lives in your workspace and is not read back by the\n'
      printf 'gate tracker, so editing it changes nothing except this record.\n'
    } > "$FEEDBACK_PATH" 2>/dev/null
  elif ! grep -Fqx "$session_marker" "$FEEDBACK_PATH" 2>/dev/null; then
    {
      printf '\n---\n\n'
      printf '%s\n' "$session_marker"
      printf 'Started: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    } >> "$FEEDBACK_PATH" 2>/dev/null
  fi
  [ -n "$response" ] || response='_(the reviewer returned no content)_'
  {
    printf '\n---\n\n'
    # Level 1: reviewers use '##' and '###' for their own sections, so an entry header at the
    # same level would be indistinguishable from the content it introduces.
    printf '# %s - attempt %s - %s\n\n' "$gate" "$attempt" "$verdict"
    printf '_%s_\n\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    printf '%s\n' "$response"
  } >> "$FEEDBACK_PATH" 2>/dev/null
  # The reviewer response and gate verdict must still reach the orchestrator even when the
  # workspace log cannot be written.
  return 0
}

# toolArgs arrives as a JSON *string* rather than an object, so it needs a second parse.
get_task_agent_type() {
  printf '%s' "$RAW_INPUT" \
    | jq -r '(.toolArgs // "") | if type == "string" then (fromjson? // {}) else . end
             | .agent_type // ""' 2>/dev/null
}

# agentName arrives namespaced, e.g. "autodev:autodev-privacy-review". The match is
# anchored and pinned to this plugin's namespace, because a suffix match would also capture
# another installed plugin's "other:autodev-privacy-review" and let it mutate this run's
# counters. An unnamespaced name is still accepted so the tracker keeps working if agents are
# ever loaded without a namespace; only a *different* namespace is rejected.
resolve_gate() {
  local name
  name="$(printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$name" in
    autodev-architecture-review|autodev:autodev-architecture-review) printf 'architecture' ;;
    autodev-security-review|autodev:autodev-security-review)         printf 'security' ;;
    autodev-privacy-review|autodev:autodev-privacy-review)           printf 'privacy' ;;
    *)                                                                 printf '' ;;
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
# and a fence occupying a line by itself; anything unexpected falls through to ISSUES.
read_verdict() {
  local last
  last="$(printf '%s\n' "$1" \
    | tr -d '\r' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' \
    | grep -vE '^`{3,}[A-Za-z0-9]*$' \
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

# Fast path. agentStop fires at the end of every turn and preToolUse on every ask_user or task
# call, in every session in every repository the plugin is installed in. Neither event can
# enforce anything until subagentStart has created state, and read_state below costs several jq
# invocations even when there is nothing to read. The condition is exactly the one both of those
# branches apply again further down, so this only settles the case earlier and more cheaply.
case "$EVENT_NAME" in
  agentStop | preToolUse)
    [ -f "$STATE_PATH" ] || [ -f "$MIRROR_PATH" ] || emit_empty
    ;;
esac

STATE="$(read_state)"

case "$EVENT_NAME" in

  subagentStart)
    GATE="$(resolve_gate "$(json_get '.agentName')")"
    [ -n "$GATE" ] || emit_empty
    ensure_dir "$STATE_DIR" || true
    ensure_dir "$VIEW_DIR" || true
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
    ensure_dir "$STATE_DIR" || true
    ensure_dir "$VIEW_DIR" || true

    RESPONSE="$(json_get '.response')"
    VERDICT="$(read_verdict "$RESPONSE")"

    ATTEMPTS="$(state_num "$STATE" "${GATE}Attempts")"
    TOTAL_INVOCATIONS="$(state_num "$STATE" 'totalInvocations')"
    # subagentStart was missed somehow; still count this attempt.
    if [ "$ATTEMPTS" -lt 1 ] 2>/dev/null; then ATTEMPTS=1; fi
    # Recover the session total ONLY when nothing at all has been counted yet. A per-gate attempt
    # counter cannot answer "was my start missed": subagentStart zeroes the later gates' counters,
    # so a security stop arriving after an architecture re-gate would see zero and count itself a
    # second time, prematurely exhausting the session ceiling and forcing an escalation. Keying
    # off the session total instead can only ever under-count, which for a runaway guard is the
    # harmless direction, while still keeping a completed invocation from exporting zero.
    if [ "$TOTAL_INVOCATIONS" -lt 1 ] 2>/dev/null; then TOTAL_INVOCATIONS=1; fi
    STATE="$(printf '%s' "$STATE" | jq --argjson a "$ATTEMPTS" --arg v "$VERDICT" \
      --argjson t "$TOTAL_INVOCATIONS" \
      ".${GATE}Attempts = \$a | .${GATE}Verdict = \$v | .totalInvocations = \$t")"
    write_state "$STATE"
    add_audit_row "$GATE" "$ATTEMPTS" "completed" "$VERDICT"
    # Capture the review itself, not just that it happened, so the findings survive the session
    # and a developer can see what each gate actually objected to.
    add_feedback_entry "$GATE" "$ATTEMPTS" "$VERDICT" "$RESPONSE"

    PHASE="$(get_phase "$STATE")"
    STATUS_LINE="$(get_gate_status_line "$STATE")"

    if [ "$PHASE" = "complete" ]; then
      NEXT_ACTION="Next required action: all three gates have passed. Proceed to WRAPUP.
Audit trail: $AUDIT_PATH
Reviewer feedback log: $FEEDBACK_PATH"
    elif [ "$PHASE" = "escalated" ]; then
      if [ "$(state_num "$STATE" 'totalInvocations')" -ge "$MAX_TOTAL_INVOCATIONS" ] 2>/dev/null; then
        NEXT_ACTION="Next required action: the review gates have used all $MAX_TOTAL_INVOCATIONS permitted reviewer invocations for this session without reaching a clean state. Stop looping and escalate to the user now, per your escalation protocol. ask_user is permitted again, and further reviewer invocations are now refused.
Audit trail: $AUDIT_PATH
Reviewer feedback log: $FEEDBACK_PATH"
      else
        NEXT_ACTION="Next required action: the $(get_stuck_gates "$STATE") gate(s) reached the $MAX_ATTEMPTS-attempt limit without passing. Stop looping and escalate to the user now, per your escalation protocol. ask_user is permitted again, and further reviewer invocations are now refused. This session can no longer reach a clean 'all gates passed' state; say so plainly at wrap-up.
Audit trail: $AUDIT_PATH
Reviewer feedback log: $FEEDBACK_PATH"
      fi
    elif [ "$VERDICT" = "PASS" ]; then
      NEXT_GATE="$(get_next_gate "$STATE")"
      NEXT_ACTION="Next required action: the $GATE gate is closed. Invoke autodev:autodev-$NEXT_GATE-review next."
    else
      REMAINING=$(( MAX_ATTEMPTS - ATTEMPTS ))
      NEXT_ACTION="Next required action: revise the plan file to address the findings above, then re-invoke autodev:autodev-$GATE-review. $REMAINING attempt(s) remain before escalation."
    fi

    FOOTER="
---
[autodev-plan gate tracker]
Gate: $GATE | Attempt $ATTEMPTS of $MAX_ATTEMPTS | Recorded verdict: $VERDICT
Gate status: $STATUS_LINE
$NEXT_ACTION"

    # Telemetry last, after every piece of enforcement state is durable. The raw session id is
    # used deliberately: SAFE_SESSION_ID exists only to build a safe filename, and exporting it
    # would break the join against Copilot's own spans for any session id containing a character
    # the sanitizer rewrites.
    send_otel_span "$(jq -cn \
      --arg span "autodev.gate $GATE" \
      --arg sid "$SESSION_ID" \
      --arg agentName "$(json_get '.agentName')" \
      --arg agentId "$(json_get '.agentId')" \
      --arg unitValue "$GATE" \
      --arg verdict "$VERDICT" \
      --argjson attempt "$ATTEMPTS" \
      --argjson total "$(state_num "$STATE" 'totalInvocations')" \
      --argjson timeMs "$(json_get_num '.timestamp')" \
      --argjson issues "$(count_findings "$RESPONSE")" \
      --arg traceparent "$(json_get '.traceparent')" \
      --arg tracestate "$(json_get '.tracestate')" \
      '{spanName: $span, sessionId: $sid, agentName: $agentName, agentId: $agentId,
        plugin: "autodev-plan", unitKey: "autodev.gate", unitValue: $unitValue,
        verdict: $verdict, attempt: $attempt, totalInvocations: $total,
        timeMs: $timeMs, issues: $issues,
        traceparent: $traceparent, tracestate: $tracestate}' 2>/dev/null)" || :

    jq -cn --arg r "$RESPONSE
$FOOTER" '{modifiedResponse: $r}'
    exit 0
    ;;

  agentStop)
    [ -f "$STATE_PATH" ] || [ -f "$MIRROR_PATH" ] || emit_empty
    [ "$(get_phase "$STATE")" = "gating" ] || emit_empty
    # The authoritative directory may be what was deleted. Recreate it before persisting the
    # recovered block counter; write_state still updates the mirror if this is impossible.
    ensure_dir "$STATE_DIR" || true
    ensure_dir "$VIEW_DIR" || true

    BLOCKS="$(state_num "$STATE" 'blocks')"
    # Give up rather than fight the CLI's own runaway guard.
    [ "$BLOCKS" -ge "$MAX_BLOCKS" ] 2>/dev/null && emit_empty

    STATE="$(printf '%s' "$STATE" | jq --argjson b "$(( BLOCKS + 1 ))" '.blocks = $b')"
    write_state "$STATE"

    NEXT_GATE="$(get_next_gate "$STATE")"
    STATUS_LINE="$(get_gate_status_line "$STATE")"
    ATTEMPTS="$(state_num "$STATE" "${NEXT_GATE}Attempts")"

    REASON="You stopped while autodev-plan review gates are still outstanding. Gate status: $STATUS_LINE. Do not end your turn and do not ask the user anything. Continue the workflow now by invoking the $NEXT_GATE gate via the task tool with agent_type 'autodev:autodev-$NEXT_GATE-review'"
    if [ "$ATTEMPTS" -gt 0 ] 2>/dev/null; then
      REASON="$REASON, after first revising the plan file to address that reviewer's outstanding findings"
    fi
    REASON="$REASON."

    add_audit_row "$NEXT_GATE" "$ATTEMPTS" "premature-stop-blocked" "-"
    jq -cn --arg r "$REASON" '{decision: "block", reason: $r}'
    exit 0
    ;;

  preToolUse)
    # hooks.json restricts this hook to ask_user and task via a matcher, but do not rely on that
    # alone: without this check a broadened or missing matcher would deny *every* tool while
    # gating, including the tools the orchestrator needs to revise the plan, deadlocking it
    # against the agentStop block.
    TOOL_NAME="$(json_get '.toolName')"
    # Lower-cased to match the PowerShell implementation's case-insensitive comparison.
    case "$(printf '%s' "$TOOL_NAME" | tr 'A-Z' 'a-z')" in
      ask_user | askuserquestion | task) ;;
      *) emit_empty ;;
    esac

    [ -f "$STATE_PATH" ] || [ -f "$MIRROR_PATH" ] || emit_empty
    PHASE="$(get_phase "$STATE")"

    if [ "$(printf '%s' "$TOOL_NAME" | tr 'A-Z' 'a-z')" = "task" ]; then
      # Everything else in this plugin only *asks* the orchestrator to stop looping once a gate
      # is out of attempts. This is the part that actually stops it: once the budget is spent,
      # refuse to start another reviewer. Without it an orchestrator that ignores the escalation
      # instruction can keep re-invoking a gate past its cap, which is exactly what the cap
      # exists to prevent.
      [ "$PHASE" = "escalated" ] || emit_empty

      TARGET_GATE="$(resolve_gate "$(get_task_agent_type)")"
      [ -n "$TARGET_GATE" ] || emit_empty

      STUCK="$(get_stuck_gates "$STATE")"
      if [ -n "$STUCK" ]; then
        LIMIT_REASON="the $STUCK gate(s) have used all $MAX_ATTEMPTS permitted attempts"
      else
        LIMIT_REASON="this session has used all $MAX_TOTAL_INVOCATIONS permitted reviewer invocations"
      fi
      REASON="The autodev-plan review gates are out of budget: $LIMIT_REASON. Further reviewer invocations are refused, so re-running the $TARGET_GATE gate cannot succeed. Stop looping and escalate to the user now, per your escalation protocol: say which gate is stuck, summarise its outstanding findings, point at the plan file and the feedback log, and state plainly that this session did not reach a clean 'all gates passed' state. ask_user is available again."

      jq -cn --arg r "$REASON" '{permissionDecision: "deny", permissionDecisionReason: $r}'
      exit 0
    fi

    [ "$PHASE" = "gating" ] || emit_empty

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
