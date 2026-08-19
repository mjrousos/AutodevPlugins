# Sample: an OpenTelemetry span from a Copilot CLI hook

A minimal, installable Copilot CLI plugin whose only job is to show how a **hook** can emit an
**OpenTelemetry span**. Two scripts (one PowerShell, one bash), about 300 lines each including the
comments that explain them, and no dependencies beyond `curl` and `jq` on Unix.

It is meant to be read more often than it is run.

## What this does

Every time a sub-agent finishes, Copilot CLI fires the `subagentStop` hook. This plugin's hook
reads the event, builds a single-span OTLP/JSON document, POSTs it to an OTLP/HTTP collector, and
prints `{}` — "no modification" — back to the CLI.

The span it produces:

```jsonc
{
  "traceId": "8e2f...c1", "spanId": "3ab9...7f",
  "name": "copilot.subagent explore",
  "kind": 1,
  "startTimeUnixNano": "1787085014326000000",   // note: a STRING, and equal to the end time
  "endTimeUnixNano":   "1787085014326000000",
  "attributes": [
    { "key": "gen_ai.conversation.id",          "value": { "stringValue": "9015d9cf-..." } },
    { "key": "github.copilot.session.id",       "value": { "stringValue": "9015d9cf-..." } },
    { "key": "github.copilot.agent.name",       "value": { "stringValue": "explore" } },
    { "key": "github.copilot.agent.id",         "value": { "stringValue": "94fadcc2-..." } },
    { "key": "github.copilot.agent.type",       "value": { "stringValue": "explore" } },
    { "key": "copilot.hook.event",              "value": { "stringValue": "subagentStop" } },
    { "key": "copilot.subagent.stop_reason",    "value": { "stringValue": "end_turn" } },
    { "key": "copilot.subagent.response_chars", "value": { "intValue": "4" } }
  ],
  "status": { "code": 0 }
}
```

The span has zero duration on purpose: it marks the *instant* a sub-agent finished. See
[Adapting it](#adapting-it) for how to turn that into a real duration.

## Quick start

You do not need a collector to see it work — write the span to a file instead:

```powershell
$env:HOOK_OTEL_ENABLED = '1'
$env:HOOK_OTEL_DEBUG_FILE = "$env:TEMP\spans.jsonl"
'{"sessionId":"s1","timestamp":1787085014326,"agentId":"a1","agentType":"explore","agentName":"explore","response":"DONE","stopReason":"end_turn"}' |
  powershell -NoProfile -File hooks/scripts/hook-otel.ps1     # prints: {}
Get-Content $env:TEMP\spans.jsonl
```

To run it for real, start any OTLP/HTTP collector on `localhost:4318`, install the plugin, set one
variable, and use the CLI:

```
copilot plugin install mjrousos/AutodevPlugins:samples/hook-otel-span
```

```bash
export HOOK_OTEL_ENABLED=1      # must be set BEFORE launching the CLI
copilot
```

## How it works

Three steps, and one rule.

1. **The hook receives JSON on stdin.** Copilot runs the command in `hooks.json` as a child
   process and writes the event payload to its standard input.
2. **The script builds an OTLP/JSON document.** A `resourceSpans → scopeSpans → spans` envelope
   containing exactly one span, with attributes taken from the payload.
3. **It POSTs that document to `<endpoint>/v1/traces`** with `Content-Type: application/json`.

The rule: **stdout belongs to the CLI.** Copilot parses a hook's stdout as a single JSON document,
and for `subagentStop` an empty object means "no modification". So the telemetry path never writes
to stdout, never fails loudly, and the script prints `{}` and exits `0` on every path — including
when it is misconfigured, when the collector is down, and when the payload is malformed. A sample
that lets telemetry break a hook would be teaching a bug.

## The `subagentStop` payload

Captured verbatim from Copilot CLI 1.0.81:

```json
{
  "sessionId": "9015d9cf-44dc-43e9-adce-aab58ece167d",
  "timestamp": 1787085014326,
  "cwd": "C:\\src\\mjrousos\\AutodevPlugins",
  "transcriptPath": "C:\\Users\\...\\session-state\\<id>\\events.jsonl",
  "agentId": "94fadcc2-eb6b-48d3-ae5b-970e89fc3b7d",
  "agentType": "explore",
  "agentName": "explore",
  "response": "DONE",
  "stopReason": "end_turn"
}
```

- `timestamp` is **Unix epoch milliseconds** (OTLP wants nanoseconds — multiply by 1,000,000).
- There is **no `traceparent`** and no telemetry configuration in the payload. A hook cannot
  discover the CLI's own exporter settings by any route, so it must be configured independently.
- `response` is the sub-agent's full text. This sample exports its *length* and never its content.

## Configuration

All variables are read from two namespaces, resolved **one namespace at a time**: everything
`HOOK_OTEL_*` first, then the standard `OTEL_*` variables. That ordering matters — see the note
below the table.

| Setting | Variables, in precedence order | Default |
|---|---|---|
| Enable | `HOOK_OTEL_ENABLED` → `HOOK_OTEL_ENDPOINT` being set → `COPILOT_OTEL_ENABLED` | off |
| Endpoint | `HOOK_OTEL_TRACES_ENDPOINT` → `HOOK_OTEL_ENDPOINT` → `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` → `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318/v1/traces` |
| Headers | `HOOK_OTEL_HEADERS` → `OTEL_EXPORTER_OTLP_TRACES_HEADERS` → `OTEL_EXPORTER_OTLP_HEADERS` | none |
| Protocol | `HOOK_OTEL_PROTOCOL` → `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL` → `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/json` |
| Service name | `HOOK_OTEL_SERVICE_NAME` → `OTEL_SERVICE_NAME` | `github-copilot` |
| Timeout (s) | `HOOK_OTEL_TIMEOUT_SEC` | `2`, clamped to 1–5 |
| Debug sink | `HOOK_OTEL_DEBUG_FILE` | none |

Notes:

- **`HOOK_OTEL_ENABLED` is tri-state.** Unset — or set to a blank value, which Windows cannot
  distinguish from unset — means "consult the other signals". Set to a falsy value such as `0`
  or `false` it is an explicit **off** that outranks everything, so you can silence hook
  telemetry without disturbing your endpoint or Copilot's own exporter. Truthy values are `1`,
  `true`, `yes`, `on`.
- **Endpoint precedence is per namespace, not per specificity.** If it were "most specific name
  wins", an inherited `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` would outrank an explicitly set
  `HOOK_OTEL_ENDPOINT` and silently ship your spans — and any auth headers configured alongside
  them — to the wrong collector.
- **The signal-specific variable is used verbatim; the generic one is a base.** `/v1/traces` is
  appended only to `*_ENDPOINT`, per the OTLP specification.
- **`HOOK_OTEL_HEADERS`** is comma-separated `key=value`, percent-decoded, split on the **first**
  `=` so base64 tokens survive. Headers are passed to `curl` through a `mktemp` config file, never
  on the command line, because argv is world-readable through `/proc/<pid>/cmdline`. Neither
  script follows HTTP redirects, so a collector answering `3xx` cannot have the headers — and any
  token in them — replayed at an origin of its choosing.
- **`protocol=grpc` disables the export.** A shell script cannot speak gRPC, and the configured
  port would be a gRPC port, so posting JSON at it would be meaningless traffic rather than a
  dropped span. This guard matters *more* here than in a plugin with its own variables, precisely
  because this sample honours your standard `OTEL_*` settings.
- **`protocol=http/protobuf` is *not* refused — these scripts always send JSON.** Building
  protobuf from a shell script is not practical, and the OTLP specification makes JSON support
  optional for a receiver, so a strictly protobuf-only backend is entitled to reject the body.
  In practice the OpenTelemetry Collector accepts both on the same port, so refusing to export
  would break the common case to guard against the rare one. The cost of that choice is that
  against a protobuf-only receiver the spans are dropped at the far end and the scripts cannot
  tell, because they discard transport errors by design. If you see no spans, set
  `HOOK_OTEL_DEBUG_FILE` to confirm they are being produced, then check whether your endpoint
  accepts `Content-Type: application/json`.
- **`HOOK_OTEL_DEBUG_FILE` is a sink, not a switch.** It appends the document that *would* have
  been posted, one per line, and on its own it does not enable telemetry.

<!-- REVISIT WHEN CLI SCRUB IS FIXED -->
## ⚠️ Known issue: `OTEL_*` variables are stripped from hooks

**Applies to Copilot CLI ≤ 1.0.81 (measured 2026-02).** Hooks run as child processes and inherit
the environment normally — with one exception: the CLI removes **every variable whose name begins
with `OTEL_` or `COPILOT_OTEL_`** before spawning them.

| Set when launching the CLI | Seen by the hook |
|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | *unset* |
| `OTEL_ZZZ_CUSTOM` (an invented name) | *unset* |
| `COPILOT_OTEL_ENABLED` | *unset* |
| `COPILOT_OTEL_ZZZ_CUSTOM` (an invented name) | *unset* |
| `COPILOT_ZZZ_CUSTOM` | passed through |
| `MY_OTEL_ENDPOINT` | passed through |
| `HOOK_OTEL_ANYTHING` | passed through |

It is a **prefix** rule, not an allowlist of known OpenTelemetry variables — invented names are
stripped too — and it matches only at the start of the name, which is why `MY_OTEL_ENDPOINT`
survives.

That is the entire reason the `HOOK_OTEL_*` namespace exists. **This is expected to be fixed in a
future CLI release**, after which the standard `OTEL_*` variables will start working here with no
change to these scripts — the fallback layer is already in place — and this section becomes a
historical note.

Until then: **set `HOOK_OTEL_ENABLED=1`.** Note also that hook commands do not perform general
environment expansion — `${COPILOT_OTEL_ENABLED}` in a `hooks.json` command string expands to
empty, since `${PLUGIN_ROOT}` substitution is path-scoped — so there is no way to smuggle the
value back in.

## What this sample omits for clarity

Everything below is present in the production emitter at
[`plugins/autodev-plan/hooks/scripts/autodev-otel.ps1`](../../plugins/autodev-plan/hooks/scripts/autodev-otel.ps1)
and its `.sh` twin, if you want the hardened version.

| Omitted | Why it is safe to leave out of a sample |
|---|---|
| **An isolated child process for the HTTP call** | The production hook spawns the emitter as a separate process with its streams redirected and a parent-side kill timeout. This sample does the POST in the hook process, which is far easier to follow. See the trade-off below. |
| **A hook-side enablement gate** | The production hook re-implements the enable/disable decision so it can skip spawning a process when telemetry is off. Two copies of one decision caused real divergence bugs; here the decision lives in exactly one place. |
| **An all-zero trace/span id retry loop** | Twelve lines guarding a 2⁻⁶⁴ event. |
| **Automated tests** | Replaced by the manual recipe below. |

**The trade-off of the in-process call.** On Windows PowerShell 5.1, `Invoke-RestMethod
-TimeoutSec` does not bound DNS resolution, so a pathological remote endpoint can block the hook
until the CLI's own `timeoutSec` fires. Against the default `localhost` collector this is not a
practical concern. And the failure mode is benign: a hook that is killed on timeout simply
produces no output, which the CLI treats as "no modification" — the same thing `{}` means. The
failure mode is latency, not corruption. The scripts keep building and sending in separate
functions so you can see exactly where the process boundary would go.

## Privacy

**Exported:** the session id, the sub-agent's id, name and type, the stop reason, the event name,
and the **character count** of the sub-agent's response. Plus, *if* the payload ever carries W3C
trace context (it does not today — see [Adapting it](#adapting-it)), the `traceparent`'s trace id,
parent span id and trace flags, and the `tracestate` verbatim. `tracestate` is vendor-supplied
key–value data, so if you adopt it in an environment where that string could carry something
sensitive, drop it — it is one line in each script and nothing else depends on it.

**Never exported:** the `response` text itself, the `cwd`, and the `transcriptPath`. Model output,
file paths and repository names are the things a customer is most likely to be unable to send to a
third-party backend, so they never reach the wire. The raw payload is unavoidably in the hook
process's memory — it arrived on stdin — but in the bash script the response length is computed
inside `jq` so the text is never even extracted into a variable of its own.

`copilot.subagent.response_chars` is a deliberate demonstration: it shows how to derive a useful
numeric signal from model output while keeping the output itself off the wire. If even a length is
too much for your environment, delete that one attribute — nothing else depends on it.

## Verifying it works

**A. Fastest loop — no CLI, no collector.** Pipe a payload straight in and inspect the document
that would have been sent (this is the [Quick start](#quick-start) snippet). In bash:

```bash
export HOOK_OTEL_ENABLED=1
export HOOK_OTEL_DEBUG_FILE=/tmp/spans.jsonl
printf '%s' '{"sessionId":"s1","timestamp":1787085014326,"agentId":"a1","agentType":"explore","agentName":"explore","response":"DONE","stopReason":"end_turn"}' |
  bash hooks/scripts/hook-otel.sh
jq . /tmp/spans.jsonl
```

Check by eye:

- the hook printed exactly `{}`;
- the document has exactly one span;
- `startTimeUnixNano` equals `endTimeUnixNano` and both are **strings**;
- `copilot.subagent.response_chars` is `{"intValue":"4"}` — a string, not the number `4`;
- no attribute contains `DONE` as content.

**B. Cross-check the two implementations.** Run A in PowerShell and in bash with the same payload;
the two documents should differ only in the random trace and span ids. (One documented exception:
`response_chars` counts UTF-16 code units in PowerShell and Unicode code points in `jq`, so the
two disagree by one per non-BMP character such as an emoji.)

**C. Against a real collector.** Start any OTLP/HTTP receiver on `:4318` (the .NET Aspire
dashboard is convenient; `docker run -p 4318:4318 otel/opentelemetry-collector` also works), unset
`HOOK_OTEL_DEBUG_FILE`, keep `HOOK_OTEL_ENABLED=1`, and re-run A. The span should arrive.

**D. End-to-end through the CLI.** Install the plugin, then — in a **new** terminal, so the
variable is inherited and the newly installed hook scripts are picked up:

```
copilot -p "Use the task tool to launch one explore subagent that reports DONE. Then reply OK." --allow-all-tools
```

A `copilot.subagent explore` span should appear, with `gen_ai.conversation.id` matching the
session id.

**E. Negative checks.** Each of these should produce no span, and a hook that still prints `{}`:

- nothing configured at all;
- `HOOK_OTEL_ENABLED=false` *with* `HOOK_OTEL_ENDPOINT` set — explicit off wins;
- `HOOK_OTEL_PROTOCOL=grpc`;
- the endpoint pointed at a closed port — the hook still prints `{}` and does not hang noticeably.

## Adapting it

**Other hook events.** Add another entry to `hooks.json` and set `copilot.hook.event` accordingly.
Each event has its own payload shape, so re-check which fields exist before reading them; the
"read one field, default to empty" helpers in both scripts are written to make that cheap.

**Measuring real duration.** Pair `subagentStart` with `subagentStop`: record the start time keyed
by `agentId` in a file under the session state directory, then read and delete it in the stop hook
and use the two timestamps as `startTimeUnixNano` and `endTimeUnixNano`. `plugins/autodev-plan`
does exactly this kind of cross-invocation bookkeeping if you want a worked example — note that it
brings real complexity, which is why this sample emits an instant instead.

**Deriving attributes from agent output.** `copilot.subagent.response_chars` is the pattern:
compute a number from the response and export the number. Counting matched headings, extracted
verdicts, or mentioned file counts all work the same way and keep the text itself off the wire.

**Span naming.** This sample uses `copilot.subagent <agentName>`, which is idiomatic for traces. If
you forward span names into a metrics pipeline, prefer a constant `copilot.subagent` and rely on
the `github.copilot.agent.name` attribute instead — dynamic agent names would otherwise produce
unbounded name cardinality. It is a one-line change in each script.

**Trace context.** Both scripts already parse a `traceparent` from the payload and become a proper
child span when they find one, including `tracestate` and the W3C trace flags. The CLI does not
send one today (see above), so that code is dormant — but it is the correct behaviour the moment
it does, and it shows what proper parenting looks like.
