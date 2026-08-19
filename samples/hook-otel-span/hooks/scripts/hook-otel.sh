#!/usr/bin/env bash
# Sample: emit one OpenTelemetry span from a Copilot CLI 'subagentStop' hook (Linux / macOS).
#
# This is a teaching sample, not production code. It does three things:
#
#   1. reads the hook payload as JSON from stdin,
#   2. turns it into an OTLP/JSON trace document,
#   3. POSTs that document to an OTLP/HTTP collector,
#
# and then prints exactly '{}' on stdout, which is how a 'subagentStop' hook says
# "no modification".
#
# THE STDOUT CONTRACT IS THE WHOLE GAME. Copilot CLI parses a hook's stdout as a single JSON
# document. Anything the telemetry path writes there -- a curl progress bar, a jq parse error,
# a shell diagnostic -- corrupts it. So every command below is redirected or guarded, every
# failure returns 0, and '{}' is printed exactly once, last.
#
# Written for bash 3.2 (the version macOS ships): no ${var,,}, no associative arrays.
# Requires jq, and curl for the network path. Either being absent degrades to "no telemetry".
#
# Compared with the production emitter in plugins/autodev-plan/hooks/scripts/autodev-otel.sh,
# this sample deliberately does the HTTP call in the hook process instead of in an isolated,
# kill-bounded child process. See "What this sample omits" in README.md.
#
# Deliberately NOT 'set -e': in a script whose only job is to be harmless, an unexpected
# non-zero return must be ignorable, not fatal.

# Copilot CLI's own implicit OTLP/HTTP default. Matching it means a user running a local
# collector needs no endpoint configuration at all.
DEFAULT_ENDPOINT='http://localhost:4318'
SCOPE_NAME='copilot-hook-otel-sample'
DEFAULT_TIMEOUT_SEC=2
MAX_TIMEOUT_SEC=5

# ----------------------------------------------------------------------------------------------
# Configuration
#
# Two namespaces, always resolved one at a time: HOOK_OTEL_* first, then the standard OTEL_*
# variables. The standard ones are the real interface; HOOK_OTEL_* exists because Copilot CLI
# <= 1.0.81 strips every variable whose name starts with 'OTEL_' or 'COPILOT_OTEL_' from a
# hook's environment. See the "Known issue" section of README.md.
# ----------------------------------------------------------------------------------------------

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

is_truthy() {
  # bash 3.2 has no ${var,,}, so lowercase with tr.
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

env_first() {
  # First non-blank value from a precedence-ordered list of variable NAMES.
  local name value
  for name in "$@"; do
    # Indirect expansion, so an unset name is not an error under 'set -u' in a caller.
    value="$(trim "${!name:-}")"
    if [ -n "$value" ]; then printf '%s' "$value"; return 0; fi
  done
  return 0
}

telemetry_enabled() {
  # HOOK_OTEL_ENABLED is tri-state on purpose: set-and-falsy is an explicit OFF that outranks
  # everything else, so telemetry can be silenced without unsetting an endpoint.
  local explicit
  explicit="$(trim "${HOOK_OTEL_ENABLED:-}")"
  if [ -n "$explicit" ]; then
    is_truthy "$explicit"
    return $?
  fi

  # Configuring an endpoint for this hook is itself an opt-in. Requiring a second variable
  # alongside it would be a trap that fails silently.
  if [ -n "$(env_first HOOK_OTEL_TRACES_ENDPOINT HOOK_OTEL_ENDPOINT)" ]; then return 0; fi

  # Copilot's own switch. Invisible on a CLI that scrubs it; correct everywhere else.
  is_truthy "${COPILOT_OTEL_ENABLED:-}"
}

resolve_endpoint() {
  # Namespace by namespace, NOT "most specific name from either namespace". Otherwise an
  # inherited OTEL_EXPORTER_OTLP_TRACES_ENDPOINT would outrank an explicitly set
  # HOOK_OTEL_ENDPOINT and silently send spans -- and any auth headers -- elsewhere.
  #
  # Within a namespace the OTLP rule applies: the signal-specific variable is used verbatim,
  # the generic one is a base that '/v1/traces' is appended to.
  local value
  value="$(env_first HOOK_OTEL_TRACES_ENDPOINT)"
  if [ -n "$value" ]; then printf '%s' "$value"; return; fi
  value="$(env_first HOOK_OTEL_ENDPOINT)"
  if [ -n "$value" ]; then printf '%s/v1/traces' "${value%/}"; return; fi

  value="$(env_first OTEL_EXPORTER_OTLP_TRACES_ENDPOINT)"
  if [ -n "$value" ]; then printf '%s' "$value"; return; fi
  value="$(env_first OTEL_EXPORTER_OTLP_ENDPOINT)"
  if [ -n "$value" ]; then printf '%s/v1/traces' "${value%/}"; return; fi

  printf '%s/v1/traces' "${DEFAULT_ENDPOINT%/}"
}

# http/https only, so a malformed variable cannot turn into some other scheme.
endpoint_ok() {
  case "${1:-}" in
    http://?* | https://?*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_protocol() {
  env_first HOOK_OTEL_PROTOCOL OTEL_EXPORTER_OTLP_TRACES_PROTOCOL OTEL_EXPORTER_OTLP_PROTOCOL |
    tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

resolve_timeout() {
  local raw
  raw="$(trim "${HOOK_OTEL_TIMEOUT_SEC:-}")"
  case "$raw" in
    '' | *[!0-9]*) printf '%s' "$DEFAULT_TIMEOUT_SEC"; return ;;
  esac
  if [ "$raw" -lt 1 ] 2>/dev/null; then printf '1'; return; fi
  if [ "$raw" -gt "$MAX_TIMEOUT_SEC" ] 2>/dev/null; then printf '%s' "$MAX_TIMEOUT_SEC"; return; fi
  printf '%s' "$raw"
}

percent_decode() {
  # Escape backslashes first so a literal one in a header value is not reinterpreted by %b.
  local s="${1:-}"
  s="${s//\\/\\\\}"
  printf '%b' "${s//%/\\x}"
}

collect_headers() {
  # Emits one 'name: value' pair per line. Comma-separated key=value, percent-decoded, split on
  # the FIRST '=' so a base64 token containing '=' survives. Never logged: OTLP headers
  # routinely carry bearer tokens.
  local raw pair name value
  raw="$(env_first HOOK_OTEL_HEADERS OTEL_EXPORTER_OTLP_TRACES_HEADERS OTEL_EXPORTER_OTLP_HEADERS)"
  [ -n "$raw" ] || return 0
  local IFS=','
  for pair in $raw; do
    pair="$(trim "$pair")"
    case "$pair" in
      =*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    name="$(trim "${pair%%=*}")"
    value="$(trim "${pair#*=}")"
    [ -n "$name" ] || continue
    printf '%s: %s\n' "$(percent_decode "$name")" "$(percent_decode "$value")"
  done
}

curl_config_escape() {
  # curl's config file parser understands backslash escapes inside a quoted value, so both the
  # backslash and the quote have to be escaped, or a crafted header value could terminate the
  # quoted string early.
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# ----------------------------------------------------------------------------------------------
# Building the span
# ----------------------------------------------------------------------------------------------

random_hex() {
  # Real randomness, not a reformatted UUID: a UUID has fixed version and variant bits, which
  # for an 8-byte span id is a meaningful loss of uniformity.
  local bytes="$1" hex=''
  if [ -r /dev/urandom ]; then
    hex="$(head -c "$bytes" /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
  fi
  if [ -z "$hex" ] && command -v openssl >/dev/null 2>&1; then
    hex="$(openssl rand -hex "$bytes" 2>/dev/null | tr -d ' \n')"
  fi
  [ "${#hex}" -eq $((bytes * 2)) ] || return 1
  printf '%s' "$hex"
}

digits_or_zero() {
  case "${1:-}" in
    '' | *[!0-9]*) printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}

hex_only() { printf '%s' "${1:-}" | tr -cd '0-9a-f'; }

parse_traceparent() {
  # Forward-looking: Copilot CLI 1.0.81 does NOT put trace context in the hook payload, so this
  # never fires today. It is kept because it is the correct answer the moment the CLI does
  # supply it -- the span then becomes a child of Copilot's own sub-agent span instead of a root
  # that correlates only by session id.
  #
  # Format is version-traceid-parentid-flags. Later versions may append fields, so only the
  # first four are read, per the W3C specification.
  TP_TRACE_ID=''
  TP_SPAN_ID=''
  TP_FLAGS=''
  local raw="${1:-}" version tid pid flags rest
  [ -n "$raw" ] || return 0
  raw="$(printf '%s' "$raw" | tr 'A-Z' 'a-z')"
  case "$raw" in *-) return 0 ;; esac
  IFS='-' read -r version tid pid flags rest <<EOF
$raw
EOF
  [ "${#version}" -eq 2 ] && [ "$(hex_only "$version")" = "$version" ] || return 0
  [ "$version" != "ff" ] || return 0  # 'ff' is reserved as invalid
  if [ "$version" = "00" ] && [ -n "$rest" ]; then return 0; fi
  [ "${#tid}" -eq 32 ] && [ "$(hex_only "$tid")" = "$tid" ] || return 0
  [ "${#pid}" -eq 16 ] && [ "$(hex_only "$pid")" = "$pid" ] || return 0
  [ "${#flags}" -eq 2 ] && [ "$(hex_only "$flags")" = "$flags" ] || return 0
  case "$tid" in *[!0]*) ;; *) return 0 ;; esac
  case "$pid" in *[!0]*) ;; *) return 0 ;; esac
  TP_TRACE_ID="$tid"
  TP_SPAN_ID="$pid"
  TP_FLAGS="$flags"
  return 0
}

build_document() {
  # One jq invocation reads every field, newline separated in a fixed order. Reading them one at
  # a time would spawn a jq process per field inside a hook with a small time budget.
  #
  # Note what is NOT read out: 'response', 'cwd' and 'transcriptPath'. The raw payload is of
  # course still in memory -- it arrived on stdin -- but jq computes the response LENGTH so the
  # text is never extracted into a variable of its own, and nothing but the length can reach the
  # document below.
  local payload="$1"
  local -a fields=()
  local line
  while IFS= read -r line; do
    fields[${#fields[@]}]="$line"
  done < <(printf '%s' "$payload" | jq -r '
      [ .sessionId, .agentName, .agentId, .agentType, .stopReason, .timestamp,
        .traceparent, .tracestate, ((.response // "") | tostring | length) ]
      | map(if . == null then "" else (. | tostring) end)
      | .[]' 2>/dev/null | tr -d '\r')
  [ "${#fields[@]}" -eq 9 ] || return 1

  local session_id="${fields[0]}" agent_name="${fields[1]}" agent_id="${fields[2]}"
  local agent_type="${fields[3]}" stop_reason="${fields[4]}" time_ms="${fields[5]}"
  local traceparent="${fields[6]}" tracestate="${fields[7]}" response_chars="${fields[8]}"

  # The payload timestamp is Unix epoch MILLISECONDS.
  time_ms="$(digits_or_zero "$time_ms")"
  if [ "$time_ms" = "0" ]; then
    time_ms="$(date -u +%s 2>/dev/null)000"
    time_ms="$(digits_or_zero "$time_ms")"
  fi
  # A zero-length span: it marks the INSTANT the sub-agent finished. Appending '000000' converts
  # milliseconds to nanoseconds without 64-bit shell arithmetic, and keeps the value a decimal
  # STRING -- which is exactly how OTLP/JSON encodes every int64. A bare JSON number is not spec
  # compliant and silently loses precision. This trips up nearly everyone.
  local time_ns="${time_ms}000000"
  response_chars="$(digits_or_zero "$response_chars")"

  local service_name span_name trace_id span_id parent_span_id span_trace_state span_flags
  service_name="$(env_first HOOK_OTEL_SERVICE_NAME OTEL_SERVICE_NAME)"
  [ -n "$service_name" ] || service_name='github-copilot'

  span_name='copilot.subagent'
  [ -z "$agent_name" ] || span_name="copilot.subagent $agent_name"

  span_id="$(random_hex 8)" || return 1
  parse_traceparent "$traceparent"
  if [ -n "$TP_TRACE_ID" ]; then
    trace_id="$TP_TRACE_ID"
    parent_span_id="$TP_SPAN_ID"
    span_trace_state="$tracestate"
    # OTLP carries the W3C trace-flags in the low 8 bits of span.flags. Dropping them would
    # export a child of a sampled parent as unsampled. Bits 8 and 9 (768) mark is_remote as
    # present and true -- the parent belongs to the CLI, not to this process.
    span_flags=$((16#$TP_FLAGS | 768))
  else
    # No context to inherit, so this is a root span that correlates by session id.
    trace_id="$(random_hex 16)" || return 1
    parent_span_id=''
    span_trace_state=''
    span_flags=0
  fi

  # Built with a single jq -n so every value is escaped by construction rather than by hand.
  jq -cn \
    --arg service "$service_name" \
    --arg scope "$SCOPE_NAME" \
    --arg traceId "$trace_id" \
    --arg spanId "$span_id" \
    --arg parentSpanId "$parent_span_id" \
    --arg traceState "$span_trace_state" \
    --argjson spanFlags "$span_flags" \
    --arg name "$span_name" \
    --arg timeNs "$time_ns" \
    --arg sessionId "$session_id" \
    --arg agentName "$agent_name" \
    --arg agentId "$agent_id" \
    --arg agentType "$agent_type" \
    --arg stopReason "$stop_reason" \
    --arg responseChars "$response_chars" \
    '{
      resourceSpans: [{
        resource: {
          attributes: [{ key: "service.name", value: { stringValue: $service } }]
        },
        scopeSpans: [{
          scope: { name: $scope },
          spans: [
            ({
              traceId: $traceId,
              spanId: $spanId,
              name: $name,
              kind: 1,
              startTimeUnixNano: $timeNs,
              endTimeUnixNano: $timeNs,
              attributes: [
                { key: "gen_ai.conversation.id",           value: { stringValue: $sessionId } },
                { key: "github.copilot.session.id",        value: { stringValue: $sessionId } },
                { key: "github.copilot.agent.name",        value: { stringValue: $agentName } },
                { key: "github.copilot.agent.id",          value: { stringValue: $agentId } },
                { key: "github.copilot.agent.type",        value: { stringValue: $agentType } },
                { key: "copilot.hook.event",               value: { stringValue: "subagentStop" } },
                { key: "copilot.subagent.stop_reason",     value: { stringValue: $stopReason } },
                { key: "copilot.subagent.response_chars",  value: { intValue: $responseChars } }
              ],
              status: { code: 0 }
            }
            + (if $parentSpanId == "" then {} else { parentSpanId: $parentSpanId } end)
            + (if $traceState == "" then {} else { traceState: $traceState } end)
            + (if $spanFlags == 0 then {} else { flags: $spanFlags } end))
          ]
        }]
      }]
    }' 2>/dev/null
}

# ----------------------------------------------------------------------------------------------
# Sending it
#
# This is where the process boundary would go if you wanted the hardened version: the production
# emitter runs everything below in a separate process it can kill on a wall-clock deadline.
# ----------------------------------------------------------------------------------------------

send_document() {
  local document="$1" endpoint="$2" timeout_sec config header_line
  timeout_sec="$(resolve_timeout)"

  # The endpoint and headers go in a curl config file rather than on the command line. OTLP
  # headers routinely carry a bearer token, and argv is world readable on Linux through
  # /proc/<pid>/cmdline, so any local process could read the credential while the request is in
  # flight. mktemp creates the file 0600, and it is removed immediately after the request.
  config="$(mktemp 2>/dev/null)" || return 0
  {
    printf 'url = "%s"\n' "$(curl_config_escape "$endpoint")"
    printf 'header = "Content-Type: application/json"\n'
    while IFS= read -r header_line; do
      [ -n "$header_line" ] || continue
      printf 'header = "%s"\n' "$(curl_config_escape "$header_line")"
    done <<EOF
$(collect_headers)
EOF
  } > "$config" 2>/dev/null

  # -sS silences the progress meter, -o /dev/null discards the response body, and --max-time is
  # a hard bound on the whole exchange. Everything is redirected: nothing may reach stdout.
  # Note the absence of -L: these headers can carry a bearer token, and following a redirect
  # would replay them at whatever origin the collector named.
  printf '%s' "$document" | curl -sS -o /dev/null \
    --max-time "$timeout_sec" --connect-timeout "$timeout_sec" \
    -X POST --data-binary @- -K "$config" >/dev/null 2>&1

  rm -f "$config" 2>/dev/null
  return 0
}

emit_span() {
  local payload="$1" document debug_file endpoint

  telemetry_enabled || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$payload" ] || return 0

  # An explicitly gRPC-configured exporter must not be sent HTTP/JSON: a shell script cannot
  # speak gRPC, and the configured port is a gRPC port, so the POST would be junk traffic.
  # This matters here precisely BECAUSE the sample honours the user's standard OTEL_* settings.
  [ "$(resolve_protocol)" = "grpc" ] && return 0

  document="$(build_document "$payload")" || return 0
  [ -n "$document" ] || return 0

  # A sink, not a switch: it never enables telemetry on its own, it only diverts it. Handy for
  # seeing exactly what would be exported without running a collector.
  debug_file="$(trim "${HOOK_OTEL_DEBUG_FILE:-}")"
  if [ -n "$debug_file" ]; then
    # One document per line. Headers are never written here; they can carry credentials.
    printf '%s\n' "$document" >> "$debug_file" 2>/dev/null
    return 0
  fi

  endpoint="$(resolve_endpoint)"
  endpoint_ok "$endpoint" || return 0
  command -v curl >/dev/null 2>&1 || return 0
  send_document "$document" "$endpoint"
  return 0
}

# ----------------------------------------------------------------------------------------------
# Main. Reads the payload from stdin, prints '{}' to stdout, and always exits 0.
# ----------------------------------------------------------------------------------------------

main() {
  local payload
  payload="$(cat 2>/dev/null)"
  emit_span "$payload" >/dev/null 2>&1

  # The only thing this script is allowed to write to stdout: "no modification".
  printf '{}'
}

main
exit 0
