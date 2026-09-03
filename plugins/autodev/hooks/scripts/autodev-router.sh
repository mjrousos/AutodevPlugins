#!/usr/bin/env bash
# Hook router for the autodev plugin (Linux / macOS).
#
# The plugin ships two independent enforcement trackers:
#
#   autodev-gates.sh   - the planning review-gate state machine (architecture, security, privacy).
#   autodev-stages.sh  - the implementation stage state machine (tasking, milestones, reviews).
#
# Both are still driven by the same four hook events, but only one of them owns any given event.
# This router is the single command referenced by hooks.json; it decides which tracker (if any)
# the event belongs to and forwards the untouched payload to exactly that tracker, passing its
# JSON result straight back to the CLI. An event that belongs to neither tracker returns the
# standard empty hook result.
#
# Routing rules:
#   subagentStart / subagentStop      by the sub-agent's name: a review-gate agent goes to gates,
#                                     an implementation-stage agent goes to stages.
#   preToolUse (task)                 by the target agent_type, using the same name-based rule, so
#                                     ordering enforcement reaches the tracker that owns the target.
#   preToolUse (ask_user) / agentStop by the router's session-keyed workflow marker, with the
#                                     trackers' session-keyed state as a compatibility fallback.
#
# The router owns cross-workflow discrimination; the two trackers stay focused on their own state
# machines and never learn about each other. It never inspects or rewrites a tracker's decision.
#
# SAFETY: preToolUse command hooks are fail-closed - any non-zero exit or crash denies the tool
# call. This router therefore never uses `set -e`, always prints valid JSON, and always exits 0.
# If jq is unavailable it degrades to a no-op, exactly as the trackers do.

EVENT_NAME="${1:-}"

emit_empty() { printf '{}\n'; exit 0; }

# Any unexpected exit path still produces valid JSON.
trap 'printf "{}\n" 2>/dev/null; exit 0' ERR

command -v jq >/dev/null 2>&1 || emit_empty

RAW_INPUT="$(cat 2>/dev/null)"
[ -n "$RAW_INPUT" ] || emit_empty
printf '%s' "$RAW_INPUT" | jq -e . >/dev/null 2>&1 || emit_empty

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)" || emit_empty
GATES_SCRIPT="$SCRIPT_DIR/autodev-gates.sh"
STAGES_SCRIPT="$SCRIPT_DIR/autodev-stages.sh"

json_get() { printf '%s' "$RAW_INPUT" | jq -r "$1 // \"\"" 2>/dev/null; }

# The task tool carries its target under .toolArgs, which may arrive as a JSON string or an object.
get_task_agent_type() {
  printf '%s' "$RAW_INPUT" \
    | jq -r '(.toolArgs // "") | if type == "string" then (fromjson? // {}) else . end
             | .agent_type // ""' 2>/dev/null
}

# agentName / agent_type arrive namespaced, e.g. "autodev:autodev-security-review". Bare names are
# also accepted because the CLI is not guaranteed to namespace them, but a different namespace must
# never be captured.
classify_agent() {
  local name
  name="$(printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$name" in
    autodev-architecture-review | autodev-security-review | autodev-privacy-review | \
      autodev:autodev-architecture-review | autodev:autodev-security-review | \
      autodev:autodev-privacy-review)
      printf 'gates' ;;
    autodev-tasking | autodev-implementation | autodev-code-review | autodev-code-fix | \
      autodev-code-security-review | autodev-code-privacy-review | \
      autodev:autodev-tasking | autodev:autodev-implementation | \
      autodev:autodev-code-review | autodev:autodev-code-fix | \
      autodev:autodev-code-security-review | autodev:autodev-code-privacy-review)
      printf 'stages' ;;
    *)
      printf '' ;;
  esac
}

# The router records its own session-keyed workflow marker before dispatching a lifecycle or task
# event. Tracker state is a compatibility fallback for sessions that began before the marker
# existed. Workspace mirrors are deliberately not consulted here: they are shared across sessions
# and remain solely the trackers' recovery mechanism.
COPILOT_HOME_DIR="${COPILOT_HOME:-$HOME/.copilot}"
SESSION_ID="$(json_get '.sessionId')"
SAFE_SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$SAFE_SESSION_ID" ] || SAFE_SESSION_ID="unknown-session"

GATE_STATE="$COPILOT_HOME_DIR/autodev/gates/$SAFE_SESSION_ID.json"
STAGE_STATE="$COPILOT_HOME_DIR/autodev/stages/$SAFE_SESSION_ID.json"
ROUTE_DIR="$COPILOT_HOME_DIR/autodev/routes"
ROUTE_PATH="$ROUTE_DIR/$SAFE_SESSION_ID"

# Record before invoking the tracker so agentStop is still routed correctly if the tracker has to
# recover missing state from its workspace mirror.
remember_route() {
  local workflow="$1" temp
  [ -n "$SESSION_ID" ] || return
  mkdir -p "$ROUTE_DIR" 2>/dev/null || return
  temp="$ROUTE_PATH.tmp.$$"
  printf '%s\n' "$workflow" > "$temp" 2>/dev/null || return
  mv -f "$temp" "$ROUTE_PATH" 2>/dev/null || rm -f "$temp"
}

# agentStop and ask_user belong to the workflow most recently dispatched for this session.
route_by_session() {
  local remembered
  [ -n "$SESSION_ID" ] || return
  if [ -f "$ROUTE_PATH" ]; then
    remembered="$(sed -n '1p' "$ROUTE_PATH" 2>/dev/null)"
    case "$remembered" in
      gates | stages) printf '%s' "$remembered"; return ;;
    esac
  fi
  if [ -f "$GATE_STATE" ] && [ -f "$STAGE_STATE" ]; then
    # Match PowerShell's deterministic tie behavior: equal timestamps route to gates.
    if [ "$STAGE_STATE" -nt "$GATE_STATE" ]; then printf 'stages'; else printf 'gates'; fi
  elif [ -f "$GATE_STATE" ]; then
    printf 'gates'
  elif [ -f "$STAGE_STATE" ]; then
    printf 'stages'
  fi
}

# Forward the untouched payload to the chosen tracker and pass its result back verbatim. If the
# tracker somehow produces nothing, fall back to the empty result so the hook contract holds.
dispatch() {
  local script="$1" out
  [ -f "$script" ] || emit_empty
  out="$(printf '%s' "$RAW_INPUT" | bash "$script" "$EVENT_NAME" 2>/dev/null)"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    printf '{}\n'
  fi
  exit 0
}

TARGET=""
case "$EVENT_NAME" in
  subagentStart | subagentStop)
    TARGET="$(classify_agent "$(json_get '.agentName')")"
    ;;
  preToolUse)
    case "$(printf '%s' "$(json_get '.toolName')" | tr 'A-Z' 'a-z')" in
      task)
        TARGET="$(classify_agent "$(get_task_agent_type)")"
        ;;
      ask_user | askuserquestion)
        TARGET="$(route_by_session)"
        ;;
      *)
        TARGET="" ;;
    esac
    ;;
  agentStop)
    TARGET="$(route_by_session)"
    ;;
  *)
    TARGET="" ;;
esac

case "$TARGET" in
  gates) remember_route gates; dispatch "$GATES_SCRIPT" ;;
  stages) remember_route stages; dispatch "$STAGES_SCRIPT" ;;
  *) emit_empty ;;
esac

emit_empty
