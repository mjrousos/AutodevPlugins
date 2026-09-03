#!/usr/bin/env bash
# Tests for the autodev hook router (autodev-router.sh).
#
# The router is the single command hooks.json wires every event to. Its only job is to decide
# which enforcement tracker (the planning gate tracker or the implementation stage tracker) owns
# an event, forward the payload to exactly that one, and pass an unrelated event through as the
# empty result. These tests exercise that decision in isolation: the real trackers are replaced
# with stubs that simply announce which one was invoked, so the routing logic is verified without
# depending on either tracker's behaviour.
#
# Usage: bash tests/router.tests.sh

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER="$TESTS_DIR/../hooks/scripts/autodev-router.sh"

if [ ! -f "$ROUTER" ]; then
  echo "Cannot find router at $ROUTER" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

PASSED=0
FAILED=0

# An isolated Copilot home so the router's per-session state lookups see only what each test sets
# up, and never a real workflow running on the machine.
COPILOT_HOME="$(mktemp -d "${TMPDIR:-/tmp}/autodev-router-tests-XXXXXX")"
export COPILOT_HOME
GATES_DIR="$COPILOT_HOME/autodev/gates"
STAGES_DIR="$COPILOT_HOME/autodev/stages"
trap 'rm -rf "$COPILOT_HOME" "$SANDBOX"' EXIT

# A sandbox holding a copy of the router beside stub trackers. The router resolves its trackers
# relative to its own location, so a copy next to the stubs makes it call them instead of the real
# ones. Each stub prints a marker naming itself and echoing the event it received.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/autodev-router-sandbox-XXXXXX")"
cp "$ROUTER" "$SANDBOX/autodev-router.sh"
cat > "$SANDBOX/autodev-gates.sh" <<'STUB'
#!/usr/bin/env bash
printf '{"routed":"gates","event":"%s"}\n' "${1:-}"
STUB
cat > "$SANDBOX/autodev-stages.sh" <<'STUB'
#!/usr/bin/env bash
printf '{"routed":"stages","event":"%s"}\n' "${1:-}"
STUB
STUB_ROUTER="$SANDBOX/autodev-router.sh"

reset_state() { rm -rf "$COPILOT_HOME/autodev"; }

# Runs the stubbed router for one event and prints its (trimmed) stdout.
route() {
  printf '%s' "$2" | bash "$STUB_ROUTER" "$1" 2>/dev/null
}

pass() { echo "  PASS  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL  $1: ${2:-}"; FAILED=$((FAILED + 1)); }

assert_routed() {
  # $1 test name, $2 expected tracker (gates|stages), $3 actual output
  if printf '%s' "$3" | grep -q "\"routed\":\"$2\""; then
    pass "$1"
  else
    fail "$1" "expected routing to '$2' but got: $3"
  fi
}

assert_empty() {
  # $1 test name, $2 actual output
  local trimmed
  trimmed="$(printf '%s' "$2" | tr -d ' \t\r\n')"
  if [ "$trimmed" = "{}" ]; then
    pass "$1"
  else
    fail "$1" "expected the empty result {} but got: $2"
  fi
}

# --- lifecycle events route by the sub-agent's name -----------------------------------------

reset_state
assert_routed "a plan review agent's subagentStart routes to the gate tracker" gates \
  "$(route subagentStart '{"sessionId":"s","cwd":"","agentName":"autodev:autodev-architecture-review"}')"

reset_state
assert_routed "a plan review agent's subagentStop routes to the gate tracker" gates \
  "$(route subagentStop '{"sessionId":"s","cwd":"","agentName":"autodev:autodev-security-review"}')"

reset_state
assert_routed "an implementation agent's subagentStart routes to the stage tracker" stages \
  "$(route subagentStart '{"sessionId":"s","cwd":"","agentName":"autodev:autodev-tasking"}')"

reset_state
assert_routed "an implementation agent's subagentStop routes to the stage tracker" stages \
  "$(route subagentStop '{"sessionId":"s","cwd":"","agentName":"autodev:autodev-code-review"}')"

# A bare (un-namespaced) name still routes, since the CLI is not guaranteed to namespace it.
reset_state
assert_routed "a bare agent name still routes to the right tracker" stages \
  "$(route subagentStart '{"sessionId":"s","cwd":"","agentName":"autodev-implementation"}')"

# The gate 'security-review' must not be confused with the stage 'code-security-review'.
reset_state
assert_routed "code-security-review routes to stages, not gates" stages \
  "$(route subagentStart '{"sessionId":"s","cwd":"","agentName":"autodev:autodev-code-security-review"}')"

reset_state
assert_empty "a foreign namespace cannot capture a plan agent name" \
  "$(route subagentStart '{"sessionId":"s","cwd":"","agentName":"other-plugin:autodev-security-review"}')"

reset_state
assert_empty "a foreign namespace cannot capture an implementation agent name" \
  "$(route subagentStart '{"sessionId":"s","cwd":"","agentName":"other-plugin:autodev-code-review"}')"

# --- task pre-tool-use routes by the target agent -------------------------------------------

reset_state
assert_routed "a task targeting a review gate routes to the gate tracker" gates \
  "$(route preToolUse '{"sessionId":"s","cwd":"","toolName":"task","toolArgs":"{\"agent_type\":\"autodev:autodev-privacy-review\"}"}')"

reset_state
assert_routed "a task targeting an implementation stage routes to the stage tracker" stages \
  "$(route preToolUse '{"sessionId":"s","cwd":"","toolName":"task","toolArgs":"{\"agent_type\":\"autodev:autodev-code-fix\"}"}')"

reset_state
assert_empty "a task targeting an unrelated agent is not routed" \
  "$(route preToolUse '{"sessionId":"s","cwd":"","toolName":"task","toolArgs":"{\"agent_type\":\"explore\"}"}')"

reset_state
assert_empty "a task targeting a foreign autodev-like agent is not routed" \
  "$(route preToolUse '{"sessionId":"s","cwd":"","toolName":"task","toolArgs":"{\"agent_type\":\"other-plugin:autodev-code-fix\"}"}')"

# --- agentStop and ask_user route by the active session's workflow --------------------------

reset_state
mkdir -p "$GATES_DIR"
printf '{}' > "$GATES_DIR/gonly.json"
assert_routed "agentStop with only gate state routes to the gate tracker" gates \
  "$(route agentStop '{"sessionId":"gonly","cwd":""}')"

reset_state
mkdir -p "$STAGES_DIR"
printf '{}' > "$STAGES_DIR/sonly.json"
assert_routed "agentStop with only stage state routes to the stage tracker" stages \
  "$(route agentStop '{"sessionId":"sonly","cwd":""}')"

reset_state
mkdir -p "$GATES_DIR"
printf '{}' > "$GATES_DIR/ionly.json"
assert_routed "ask_user with only gate state routes to the gate tracker" gates \
  "$(route preToolUse '{"sessionId":"ionly","cwd":"","toolName":"ask_user"}')"

reset_state
mkdir -p "$STAGES_DIR"
printf '{}' > "$STAGES_DIR/aonly.json"
assert_routed "ask_user with only stage state routes to the stage tracker" stages \
  "$(route preToolUse '{"sessionId":"aonly","cwd":"","toolName":"ask_user"}')"

# When both workflows have state, the most recently written one is the live workflow.
reset_state
mkdir -p "$GATES_DIR" "$STAGES_DIR"
printf '{}' > "$STAGES_DIR/both.json"
sleep 1
printf '{}' > "$GATES_DIR/both.json"
assert_routed "agentStop routes to the more recently active workflow (gate newer)" gates \
  "$(route agentStop '{"sessionId":"both","cwd":""}')"

reset_state
mkdir -p "$GATES_DIR" "$STAGES_DIR"
printf '{}' > "$GATES_DIR/both.json"
sleep 1
printf '{}' > "$STAGES_DIR/both.json"
assert_routed "agentStop routes to the more recently active workflow (stage newer)" stages \
  "$(route agentStop '{"sessionId":"both","cwd":""}')"

reset_state
mkdir -p "$GATES_DIR" "$STAGES_DIR"
printf '{}' > "$GATES_DIR/tied.json"
printf '{}' > "$STAGES_DIR/tied.json"
touch -r "$GATES_DIR/tied.json" "$STAGES_DIR/tied.json"
assert_routed "equal tracker timestamps deterministically route to gates" gates \
  "$(route agentStop '{"sessionId":"tied","cwd":""}')"

reset_state
route subagentStart '{"sessionId":"remembered","cwd":"","agentName":"autodev:autodev-security-review"}' >/dev/null
rm -rf "$GATES_DIR" "$STAGES_DIR"
assert_routed "the session route survives missing tracker state for mirror recovery" gates \
  "$(route agentStop '{"sessionId":"remembered","cwd":""}')"

reset_state
route subagentStart '{"sessionId":"plan-session","cwd":"","agentName":"autodev:autodev-security-review"}' >/dev/null
route subagentStart '{"sessionId":"implementation-session","cwd":"","agentName":"autodev:autodev-code-review"}' >/dev/null
assert_routed "session-keyed routes do not interfere with each other" gates \
  "$(route agentStop '{"sessionId":"plan-session","cwd":""}')"

# --- events that belong to neither tracker return the empty result --------------------------

reset_state
assert_empty "an unrelated sub-agent is ignored" \
  "$(route subagentStart '{"sessionId":"s","cwd":"","agentName":"explore"}')"

reset_state
assert_empty "an unrelated tool is ignored" \
  "$(route preToolUse '{"sessionId":"s","cwd":"","toolName":"glob"}')"

reset_state
assert_empty "agentStop with no active workflow is ignored" \
  "$(route agentStop '{"sessionId":"nostate","cwd":""}')"

reset_state
assert_empty "ask_user with no active workflow is ignored" \
  "$(route preToolUse '{"sessionId":"nostate","cwd":"","toolName":"ask_user"}')"

# --- fail-safe: malformed input never produces anything but the empty result ----------------

reset_state
assert_empty "invalid JSON is a no-op" "$(route preToolUse 'this is not json')"
assert_empty "empty input is a no-op" "$(route agentStop '')"
assert_empty "an unknown event is a no-op" \
  "$(route somethingElse '{"sessionId":"s","cwd":"","agentName":"autodev:autodev-tasking"}')"

echo ""
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
