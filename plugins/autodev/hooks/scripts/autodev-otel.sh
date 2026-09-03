#!/usr/bin/env bash
# OTLP/HTTP span emitter for the autodev plugins (Linux / macOS).
#
# Emits exactly one OpenTelemetry span describing a completed autodev sub-agent, so that
# 'ISSUES' verdicts reported by the review gates can be counted in a tracing backend.
#
# This script is ALWAYS run as an isolated child process by the hook scripts, never sourced
# into them. That is a safety requirement, not a style preference. The hook scripts install
# `trap '... printf "{}"; exit 0' ERR`, so a non-zero return from curl inside the hook process
# would print '{}' and exit, destroying the tracker footer the gate depends on. Running here,
# invoked with `>/dev/null 2>&1 </dev/null || :`, means neither this script's output nor its
# exit code can reach the hook.
#
# Correlation: when the hook payload supplies W3C trace context, this span is emitted as a child
# of Copilot's own sub-agent span -- it adopts that trace id and sets 'parentSpanId', so the
# verdict lands directly on the sub-agent's trace. Copilot CLI does not send trace context to
# command hooks yet; until it does the span is its own root and correlates by attribute instead,
# carrying the raw session id as 'gen_ai.conversation.id' and 'github.copilot.session.id', which
# are the attributes Copilot CLI puts its session id on. Either way nothing here has to change
# when the CLI starts sending the header.
#
# The span deliberately marks an instant rather than a duration: it records WHEN a verdict was
# reached, while how long the sub-agent ran belongs to Copilot's own span, which measures that
# in-process instead of across two separate hook invocations.
#
# Configuration comes from AUTODEV_OTEL_* variables rather than Copilot's own OTEL_* ones,
# because Copilot CLI SCRUBS its telemetry configuration out of the environment it gives to
# command hooks. Measured against CLI 1.0.81: a hook process sees no variable whose name begins
# with 'OTEL_' or 'COPILOT_OTEL_', while every other variable -- including 'AUTODEV_OTEL_*' -- is
# inherited normally. Reading COPILOT_OTEL_ENABLED here therefore meant the emitter could never
# run under the CLI at all, no matter how the user had configured Copilot's own exporter. The
# OTEL_* variables are still honoured as a fallback, for hosts that do not scrub them.
#
# Requires jq (already required by the hook scripts) and, for the network path, curl. Either
# being absent degrades to "no telemetry", never to a failure.
#
# Usage: autodev-otel.sh <payload-json-file>

PAYLOAD_PATH="${1:-}"

# Ceiling on the request timeout. The parent applies its own bound; this keeps a user-set value
# from ever approaching the hook's own timeout budget.
MAX_TIMEOUT_SEC=5
DEFAULT_TIMEOUT_SEC=2

# Copilot CLI's own implicit OTLP/HTTP default. Reproduced so that a user who enabled hook
# telemetry, pointed Copilot at a local collector the default way, and set no endpoint of their
# own still gets spans. This is only ever reached once telemetry has been explicitly enabled, so
# it cannot surprise anyone who has not opted in.
DEFAULT_ENDPOINT='http://localhost:4318'

# Every exit path is a success: telemetry is never worth a failed hook.
die_ok() { exit 0; }

is_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

trim() {
  # Pure parameter expansion: this runs on every configuration read, and spawning sed for each
  # one is needless process churn in a hook that shares a 20 second budget.
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

resolve_timeout() {
  local raw
  raw="$(trim "${AUTODEV_OTEL_TIMEOUT_SEC:-}")"
  case "$raw" in
    '' | *[!0-9]*) printf '%s' "$DEFAULT_TIMEOUT_SEC"; return ;;
  esac
  if [ "$raw" -lt 1 ] 2>/dev/null; then printf '1'; return; fi
  if [ "$raw" -gt "$MAX_TIMEOUT_SEC" ] 2>/dev/null; then printf '%s' "$MAX_TIMEOUT_SEC"; return; fi
  printf '%s' "$raw"
}

env_first() {
  # First non-blank value from a precedence-ordered list of variable names. The AUTODEV_OTEL_*
  # name always comes first: it is the only one that survives Copilot's environment scrub, so a
  # user who sets both must get theirs rather than a stale inherited one.
  local name value
  for name in "$@"; do
    # Indirect expansion, so the caller passes names rather than values and an unset one is not
    # an error under 'set -u'.
    value="$(trim "${!name:-}")"
    if [ -n "$value" ]; then printf '%s' "$value"; return 0; fi
  done
  return 0
}

telemetry_enabled() {
  # Hook telemetry is opt-in, and opting in has to be possible from inside a hook, so it keys off
  # variables Copilot CLI does not strip.
  #
  # AUTODEV_OTEL_ENABLED is tri-state on purpose: set-and-falsy is an explicit OFF that outranks
  # every other signal, so a user can silence hook telemetry without disturbing Copilot's own
  # exporter or unsetting their endpoint.
  local explicit
  explicit="$(trim "${AUTODEV_OTEL_ENABLED:-}")"
  if [ -n "$explicit" ]; then
    if is_truthy "$explicit"; then return 0; fi
    return 1
  fi

  # Configuring an endpoint for this emitter is itself an opt-in; requiring a second variable
  # alongside it would be a trap that fails silently, which is how this feature shipped broken.
  # Written as if/fi rather than '&&': a false test at statement level would fire the ERR trap in
  # any caller that installs one.
  if [ -n "$(env_first AUTODEV_OTEL_TRACES_ENDPOINT AUTODEV_OTEL_ENDPOINT)" ]; then return 0; fi

  # Fallback for any host that does NOT scrub Copilot's telemetry variables, where following
  # Copilot's own switch is the least surprising behaviour.
  is_truthy "${COPILOT_OTEL_ENABLED:-}"
}

resolve_protocol() {
  env_first AUTODEV_OTEL_PROTOCOL OTEL_EXPORTER_OTLP_TRACES_PROTOCOL OTEL_EXPORTER_OTLP_PROTOCOL |
    tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

resolve_endpoint() {
  # Resolved one namespace at a time, AUTODEV_OTEL_* first. Within a namespace the OTLP rule
  # applies -- the signal-specific variable is used verbatim, while the generic one is a base that
  # '/v1/traces' is appended to -- but a legacy OTEL_* value never outranks an AUTODEV_OTEL_* one,
  # however specific it is. Mixing the two would let an inherited OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
  # silently redirect spans away from the endpoint the user configured for this emitter, and take
  # the AUTODEV_OTEL_HEADERS credentials with them.
  #
  # Copilot's implicit 'http://localhost:4318' default is reproduced as a last resort, because a
  # hook cannot see the endpoint Copilot itself resolved and most users never set one.
  local specific generic
  specific="$(env_first AUTODEV_OTEL_TRACES_ENDPOINT)"
  if [ -n "$specific" ]; then printf '%s' "$specific"; return; fi
  generic="$(env_first AUTODEV_OTEL_ENDPOINT)"
  if [ -n "$generic" ]; then printf '%s/v1/traces' "${generic%/}"; return; fi

  specific="$(env_first OTEL_EXPORTER_OTLP_TRACES_ENDPOINT)"
  if [ -n "$specific" ]; then printf '%s' "$specific"; return; fi
  generic="$(env_first OTEL_EXPORTER_OTLP_ENDPOINT)"
  if [ -n "$generic" ]; then printf '%s/v1/traces' "${generic%/}"; return; fi

  printf '%s/v1/traces' "${DEFAULT_ENDPOINT%/}"
}

# http/https only, so a malformed variable cannot turn into some other scheme.
endpoint_ok() {
  case "${1:-}" in
    http://?* | https://?*) return 0 ;;
    *) return 1 ;;
  esac
}

percent_decode() {
  # Escape backslashes first so a literal one in a header value is not reinterpreted by %b.
  local s="${1:-}"
  s="${s//\\/\\\\}"
  printf '%b' "${s//%/\\x}"
}

# Emits one '-H name: value' pair per line, NUL-free, for the caller to read into an array.
# AUTODEV_OTEL_HEADERS wins over the OTLP variables, and the traces-specific OTLP variable over
# the generic one, rather than merging with them, per the specification. Values are split on the
# FIRST '=' only, so a base64 token containing '=' survives intact. Never logged.
collect_headers() {
  local raw pair name value
  raw="$(env_first AUTODEV_OTEL_HEADERS OTEL_EXPORTER_OTLP_TRACES_HEADERS OTEL_EXPORTER_OTLP_HEADERS)"
  [ -n "$raw" ] || return 0
  local IFS=','
  for pair in $raw; do
    pair="$(trim "$pair")"
    [ -n "$pair" ] || continue
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

random_hex() {
  # Real randomness, not a reformatted UUID: a UUID has fixed version and variant bits, which for
  # an 8-byte span id is a meaningful loss of uniformity. All-zero ids are invalid per the spec,
  # so reject and retry rather than emit an unusable span.
  local bytes="$1" hex attempt=0
  while [ "$attempt" -lt 8 ]; do
    attempt=$((attempt + 1))
    hex=''
    if [ -r /dev/urandom ]; then
      hex="$(head -c "$bytes" /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
    fi
    if [ -z "$hex" ] && command -v openssl >/dev/null 2>&1; then
      hex="$(openssl rand -hex "$bytes" 2>/dev/null | tr -d ' \n')"
    fi
    [ "${#hex}" -eq $((bytes * 2)) ] || continue
    case "$hex" in
      *[!0]*) printf '%s' "$hex"; return 0 ;;
    esac
  done
  return 1
}

digits_or_zero() {
  case "${1:-}" in
    '' | *[!0-9]*) printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}

hex_only() { printf '%s' "${1:-}" | tr -cd '0-9a-f'; }

# Parses a W3C traceparent into TRACE_PARENT_TRACE_ID / TRACE_PARENT_SPAN_ID, leaving both empty
# unless the header is well formed. When Copilot supplies one, our span becomes a child of the
# sub-agent span the CLI already records, which is a far better correlation than any attribute we
# could invent -- and it means the parent, not us, is responsible for timing.
#
# Format is version-traceid-parentid-flags. Later versions may append fields, so only the first
# four are read and the rest ignored, per the specification.
parse_traceparent() {
  TRACE_PARENT_TRACE_ID=''
  TRACE_PARENT_SPAN_ID=''
  TRACE_PARENT_FLAGS=''
  local raw="${1:-}" version tid pid flags rest
  [ -n "$raw" ] || return 0
  # The spec requires lowercase hex, but normalise rather than reject a non-compliant producer.
  raw="$(printf '%s' "$raw" | tr 'A-Z' 'a-z')"
  # A trailing delimiter leaves an empty final field, which no version permits.
  case "$raw" in *-) return 0 ;; esac
  IFS='-' read -r version tid pid flags rest <<EOF
$raw
EOF
  # 'ff' is reserved as invalid by the specification.
  [ "${#version}" -eq 2 ] && [ "$(hex_only "$version")" = "$version" ] || return 0
  [ "$version" != "ff" ] || return 0
  [ "${#tid}" -eq 32 ] && [ "$(hex_only "$tid")" = "$tid" ] || return 0
  [ "${#pid}" -eq 16 ] && [ "$(hex_only "$pid")" = "$pid" ] || return 0
  # trace-flags is required, so a three-field header is malformed rather than "flags omitted".
  [ "${#flags}" -eq 2 ] && [ "$(hex_only "$flags")" = "$flags" ] || return 0
  # Version 00 is exactly four fields. Later versions may append, and are parsed by reading the
  # first four and ignoring the rest, which is what the specification asks future parsers to do.
  if [ "$version" = "00" ] && [ -n "$rest" ]; then return 0; fi
  # An all-zero id is invalid and must not be treated as a usable parent.
  case "$tid" in *[!0]*) ;; *) return 0 ;; esac
  case "$pid" in *[!0]*) ;; *) return 0 ;; esac
  TRACE_PARENT_TRACE_ID="$tid"
  TRACE_PARENT_SPAN_ID="$pid"
  TRACE_PARENT_FLAGS="$flags"
  return 0
}

curl_config_escape() {
  # curl's config file parser understands backslash escapes inside a quoted value, so both the
  # backslash and the quote have to be escaped or a crafted header value could terminate the
  # quoted string early.
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

main() {
  telemetry_enabled || die_ok
  command -v jq >/dev/null 2>&1 || die_ok
  [ -n "$PAYLOAD_PATH" ] && [ -f "$PAYLOAD_PATH" ] || die_ok

  # An explicitly gRPC-configured exporter must not be sent HTTP/JSON: the endpoint is a gRPC
  # port and the POST would be meaningless traffic rather than a dropped span.
  [ "$(resolve_protocol)" = "grpc" ] && die_ok

  local debug_file endpoint
  debug_file="$(trim "${AUTODEV_OTEL_DEBUG_FILE:-}")"
  endpoint="$(resolve_endpoint)"
  # The debug sink is for tests and for a developer inspecting what would be exported, so it
  # deliberately does not require a reachable endpoint.
  if [ -z "$debug_file" ]; then
    endpoint_ok "$endpoint" || die_ok
    command -v curl >/dev/null 2>&1 || die_ok
  fi

  local request
  request="$(cat "$PAYLOAD_PATH" 2>/dev/null)" || die_ok
  [ -n "$request" ] || die_ok
  printf '%s' "$request" | jq -e . >/dev/null 2>&1 || die_ok

  # One jq invocation for every field, newline separated in a fixed order. Reading them one at a
  # time would spawn a dozen jq processes inside a hook that shares a 20 second budget.
  #
  # Read line by line into an indexed array rather than with `IFS=$'\n' read -r -d ''`. Newline
  # is IFS whitespace, so `read` collapses a run of them into one delimiter: a single empty
  # field (an absent agentId, say) would silently shift every later value left, putting the
  # attempt count in autodev.verdict and reporting autodev.issues=0 for an ISSUES verdict. A
  # `while IFS= read -r` loop preserves empty lines exactly.
  local -a fields=()
  local line
  while IFS= read -r line; do
    fields[${#fields[@]}]="$line"
  done < <(printf '%s' "$request" | jq -r '
      [ .spanName, .sessionId, .agentName, .agentId, .plugin, .unitKey, .unitValue, .verdict,
        .attempt, .totalInvocations, .timeMs, .traceparent, .tracestate, .issues ]
      | map(if . == null then "" else (. | tostring) end)
      | .[]' 2>/dev/null | tr -d '\r')

  local span_name session_id agent_name agent_id plugin unit_key unit_value verdict
  local attempt total time_ms traceparent tracestate issue_count
  span_name="${fields[0]:-}"
  session_id="${fields[1]:-}"
  agent_name="${fields[2]:-}"
  agent_id="${fields[3]:-}"
  plugin="${fields[4]:-}"
  unit_key="${fields[5]:-}"
  unit_value="${fields[6]:-}"
  verdict="${fields[7]:-}"
  attempt="${fields[8]:-}"
  total="${fields[9]:-}"
  time_ms="${fields[10]:-}"
  traceparent="${fields[11]:-}"
  tracestate="${fields[12]:-}"
  issue_count="${fields[13]:-}"

  # A key must never be empty or the attribute would be unusable, and never attacker-chosen.
  case "$unit_key" in
    autodev.gate | autodev.stage) ;;
    *) unit_key='autodev.gate' ;;
  esac
  [ -n "$span_name" ] || span_name='autodev.subagent'

  attempt="$(digits_or_zero "$attempt")"
  total="$(digits_or_zero "$total")"
  time_ms="$(digits_or_zero "$time_ms")"
  if [ "$time_ms" = "0" ]; then
    # The hook payload carries its own timestamp; this is only for a malformed one.
    time_ms="$(date -u +%s 2>/dev/null)000"
    time_ms="$(digits_or_zero "$time_ms")"
  fi
  # This span marks the instant a verdict was recorded, so it is deliberately zero length: the
  # sub-agent's duration belongs to Copilot's own span, which measures it from inside the process.
  # Concatenating '000000' converts milliseconds to nanoseconds without 64-bit shell arithmetic,
  # and keeps the value a decimal string, which is how OTLP/JSON encodes every int64.
  local time_ns="${time_ms}000000"

  # autodev.issues is the number of findings the reviewer actually reported, counted by the hook
  # from the mandated '### [severity] title' headings. An ISSUES verdict must never report zero:
  # a reviewer that deviates from the heading format would otherwise look clean in a dashboard,
  # turning a formatting slip into a silently missing finding. "Did this gate come back dirty" is
  # answered by autodev.verdict, so no separate flag is needed.
  local issues=0 blocked=0
  issues="$(digits_or_zero "$issue_count")"
  if [ "$verdict" = "ISSUES" ] && [ "$issues" -lt 1 ] 2>/dev/null; then issues=1; fi
  [ "$verdict" = "BLOCKED" ] && blocked=1

  local service_name trace_id span_id parent_span_id span_trace_state span_flags
  # env_first, not a bare OTEL_SERVICE_NAME read: that name is scrubbed from a hook's environment
  # by Copilot CLI, so honouring it alone silently ignored the documented
  # AUTODEV_OTEL_SERVICE_NAME and stamped every span with the default instead.
  service_name="$(env_first AUTODEV_OTEL_SERVICE_NAME OTEL_SERVICE_NAME)"
  [ -n "$service_name" ] || service_name='github-copilot'

  parse_traceparent "$traceparent"
  if [ -n "$TRACE_PARENT_TRACE_ID" ]; then
    # Join Copilot's trace directly.
    trace_id="$TRACE_PARENT_TRACE_ID"
    parent_span_id="$TRACE_PARENT_SPAN_ID"
    span_trace_state="$tracestate"
    # Carry the parent's sampling decision. OTLP puts the W3C trace flags in the low 8 bits of
    # span.flags, and an omitted field reads as 0, so a span inheriting a sampled '01' parent
    # would otherwise be exported as unsampled and dropped by a tail sampler. Bits 8 and 9 mark
    # is_remote as present and true, which it is: the parent span belongs to the CLI process.
    span_flags=$(( 16#$TRACE_PARENT_FLAGS | 768 ))
  else
    # No usable context, so this span is its own root and correlates by session id instead.
    trace_id="$(random_hex 16)" || die_ok
    parent_span_id=''
    span_trace_state=''
    # No inherited context, so no flags to report.
    span_flags=0
  fi
  span_id="$(random_hex 8)" || die_ok

  local document
  document="$(jq -cn \
    --arg service "$service_name" \
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
    --arg plugin "$plugin" \
    --arg unitKey "$unit_key" \
    --arg unitValue "$unit_value" \
    --arg verdict "$verdict" \
    --arg issues "$issues" \
    --arg blocked "$blocked" \
    --arg attempt "$attempt" \
    --arg total "$total" \
    '{
      resourceSpans: [{
        resource: {
          attributes: [{ key: "service.name", value: { stringValue: $service } }]
        },
        scopeSpans: [{
          scope: { name: "autodev-plugins" },
          spans: [
            ({
              traceId: $traceId,
              spanId: $spanId,
              name: $name,
              kind: 1,
              startTimeUnixNano: $timeNs,
              endTimeUnixNano: $timeNs,
              attributes: [
                { key: "gen_ai.conversation.id",    value: { stringValue: $sessionId } },
                { key: "github.copilot.session.id", value: { stringValue: $sessionId } },
                { key: "github.copilot.agent.name", value: { stringValue: $agentName } },
                { key: "github.copilot.agent.id",   value: { stringValue: $agentId } },
                { key: "autodev.plugin",            value: { stringValue: $plugin } },
                { key: $unitKey,                    value: { stringValue: $unitValue } },
                { key: "autodev.verdict",           value: { stringValue: $verdict } },
                { key: "autodev.issues",            value: { intValue: $issues } },
                { key: "autodev.blocked",           value: { intValue: $blocked } },
                { key: "autodev.attempt",           value: { intValue: $attempt } },
                { key: "autodev.total_invocations", value: { intValue: $total } }
              ],
              status: { code: 0 }
            }
            + (if $parentSpanId == "" then {} else { parentSpanId: $parentSpanId } end)
            + (if $traceState == "" then {} else { traceState: $traceState } end)
            + (if $spanFlags == 0 then {} else { flags: $spanFlags } end))
          ]
        }]
      }]
    }' 2>/dev/null)" || die_ok
  [ -n "$document" ] || die_ok

  if [ -n "$debug_file" ]; then
    # One document per line so a test can count emissions as well as inspect them. Headers are
    # never written here; they can carry credentials.
    printf '%s\n' "$document" >> "$debug_file" 2>/dev/null
    die_ok
  fi

  local timeout_sec config header_line
  timeout_sec="$(resolve_timeout)"

  # Headers and the endpoint go in a curl config file rather than on the command line. OTLP
  # headers routinely carry a bearer token, and argv is world readable on Linux through
  # /proc/<pid>/cmdline, so any local process could read the credential while the request is in
  # flight. mktemp creates the file 0600, and it is removed immediately after the request.
  config="$(mktemp 2>/dev/null)" || die_ok
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

  # -o /dev/null discards the response body; --max-time is a hard bound on the whole exchange.
  printf '%s' "$document" | curl -sS -o /dev/null \
    --max-time "$timeout_sec" --connect-timeout "$timeout_sec" \
    -X POST --data-binary @- -K "$config" >/dev/null 2>&1

  rm -f "$config" 2>/dev/null || :

  die_ok
}

main
exit 0
