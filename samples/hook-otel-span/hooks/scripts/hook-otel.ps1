<#
.SYNOPSIS
    Sample: emit one OpenTelemetry span from a Copilot CLI 'subagentStop' hook (Windows).

.DESCRIPTION
    This is a teaching sample, not production code. It does three things:

      1. reads the hook payload as JSON from stdin,
      2. turns it into an OTLP/JSON trace document,
      3. POSTs that document to an OTLP/HTTP collector,

    and then prints exactly '{}' on stdout, which is how a 'subagentStop' hook says
    "no modification".

    THE STDOUT CONTRACT IS THE WHOLE GAME. Copilot CLI parses a hook's stdout as a single JSON
    document. Anything the telemetry path writes there -- a warning, a response body, a stack
    trace -- corrupts it. So every function below is silent, every failure is swallowed, and the
    script exits 0 on every path.

    Written for Windows PowerShell 5.1: no -AsHashtable, no ternaries, no three-argument
    Join-Path.

    Compared with the production emitter in plugins/autodev/hooks/scripts/autodev-otel.ps1,
    this sample deliberately does the HTTP call in the hook process instead of in an isolated,
    kill-bounded child process. See "What this sample omits" in README.md.
#>

# Nothing here is ever worth a failed hook, so failures are made loud internally (so the single
# catch at the bottom sees them) and silent externally.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

# Copilot CLI's own implicit OTLP/HTTP default. Matching it means a user running a local
# collector needs no endpoint configuration at all.
$script:DefaultEndpoint = 'http://localhost:4318'
$script:ScopeName = 'copilot-hook-otel-sample'
$script:DefaultTimeoutSec = 2
$script:MaxTimeoutSec = 5

# --------------------------------------------------------------------------------------------
# Configuration
#
# Two namespaces, always resolved one at a time: HOOK_OTEL_* first, then the standard OTEL_*
# variables. The standard ones are the real interface; HOOK_OTEL_* exists because Copilot CLI
# <= 1.0.81 strips every variable whose name starts with 'OTEL_' or 'COPILOT_OTEL_' from a
# hook's environment. See the "Known issue" section of README.md.
# --------------------------------------------------------------------------------------------

function Get-Env {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) { return '' }
    return $value.Trim()
}

function Get-EnvFirst {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $value = Get-Env $name
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return ''
}

function Test-Truthy {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return @('1', 'true', 'yes', 'on') -contains $Value.ToLowerInvariant()
}

function Test-TelemetryEnabled {
    # HOOK_OTEL_ENABLED is tri-state on purpose: set-and-falsy is an explicit OFF that outranks
    # everything else, so telemetry can be silenced without unsetting an endpoint.
    $explicit = Get-Env 'HOOK_OTEL_ENABLED'
    if (-not [string]::IsNullOrWhiteSpace($explicit)) { return (Test-Truthy $explicit) }

    # Configuring an endpoint for this hook is itself an opt-in. Requiring a second variable
    # alongside it would be a trap that fails silently.
    if (-not [string]::IsNullOrWhiteSpace((Get-EnvFirst @('HOOK_OTEL_TRACES_ENDPOINT', 'HOOK_OTEL_ENDPOINT')))) {
        return $true
    }

    # Copilot's own switch. Invisible on a CLI that scrubs it; correct everywhere else.
    return (Test-Truthy (Get-Env 'COPILOT_OTEL_ENABLED'))
}

function Get-TracesEndpoint {
    # Returns the traces URL together with the namespace it came from ('hook', 'standard' or
    # 'default'). The two travel together because headers are resolved from the SAME namespace.
    #
    # Namespace by namespace, NOT "most specific name from either namespace". Otherwise an
    # inherited OTEL_EXPORTER_OTLP_TRACES_ENDPOINT would outrank an explicitly set
    # HOOK_OTEL_ENDPOINT and silently send spans -- and any auth headers -- elsewhere.
    foreach ($pair in @(
            @{ Namespace = 'hook'; Specific = 'HOOK_OTEL_TRACES_ENDPOINT'; Generic = 'HOOK_OTEL_ENDPOINT' },
            @{ Namespace = 'standard'; Specific = 'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT'; Generic = 'OTEL_EXPORTER_OTLP_ENDPOINT' })) {
        # The signal-specific variable is used verbatim; the generic one is a base to append to.
        $specific = Get-Env $pair.Specific
        if (-not [string]::IsNullOrWhiteSpace($specific)) {
            return @{ Endpoint = $specific; Namespace = $pair.Namespace }
        }
        $generic = Get-Env $pair.Generic
        if (-not [string]::IsNullOrWhiteSpace($generic)) {
            return @{ Endpoint = ($generic.TrimEnd('/') + '/v1/traces'); Namespace = $pair.Namespace }
        }
    }
    return @{ Endpoint = ($script:DefaultEndpoint.TrimEnd('/') + '/v1/traces'); Namespace = 'default' }
}

function Test-Endpoint {
    param([string]$Endpoint)
    $uri = $null
    if (-not [Uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$uri)) { return $false }
    # http/https only, so a malformed variable cannot turn into a file write.
    return ($uri.Scheme -eq 'http' -or $uri.Scheme -eq 'https')
}

function Get-OtlpHeaders {
    # Comma-separated key=value, percent-decoded, split on the FIRST '=' so a base64 token
    # containing '=' survives. Never logged: these routinely carry bearer tokens.
    #
    # Headers come from the SAME namespace the endpoint was resolved from. Falling back across
    # namespaces would hand an inherited collector's credentials to a different collector the
    # moment someone set HOOK_OTEL_ENDPOINT alone -- and setting HOOK_OTEL_HEADERS to a blank
    # value could not prevent it, because Get-EnvFirst skips blanks. Only when nothing
    # configured an endpoint at all ('default') do both namespaces describe the same implicit
    # localhost collector, so there the full chain is safe.
    param([string]$Namespace)
    if ($Namespace -eq 'hook') {
        $raw = Get-EnvFirst @('HOOK_OTEL_HEADERS')
    }
    elseif ($Namespace -eq 'standard') {
        $raw = Get-EnvFirst @('OTEL_EXPORTER_OTLP_TRACES_HEADERS', 'OTEL_EXPORTER_OTLP_HEADERS')
    }
    else {
        $raw = Get-EnvFirst @(
            'HOOK_OTEL_HEADERS',
            'OTEL_EXPORTER_OTLP_TRACES_HEADERS',
            'OTEL_EXPORTER_OTLP_HEADERS')
    }
    $headers = @{}
    if ([string]::IsNullOrWhiteSpace($raw)) { return $headers }
    foreach ($pair in ($raw -split ',')) {
        $trimmed = $pair.Trim()
        $index = $trimmed.IndexOf('=')
        if ($index -lt 1) { continue }
        $name = $trimmed.Substring(0, $index).Trim()
        $value = $trimmed.Substring($index + 1).Trim()
        if ($name -eq '') { continue }
        try { $headers[[Uri]::UnescapeDataString($name)] = [Uri]::UnescapeDataString($value) }
        catch { $headers[$name] = $value }
    }
    return $headers
}

function Get-TimeoutSec {
    $raw = Get-Env 'HOOK_OTEL_TIMEOUT_SEC'
    $parsed = 0
    if (-not [int]::TryParse($raw, [ref]$parsed)) { return $script:DefaultTimeoutSec }
    if ($parsed -lt 1) { return 1 }
    if ($parsed -gt $script:MaxTimeoutSec) { return $script:MaxTimeoutSec }
    return $parsed
}

# --------------------------------------------------------------------------------------------
# Building the span
# --------------------------------------------------------------------------------------------

function New-RandomHex {
    # Real randomness, not GUID text: a GUID has fixed version and variant bits, which for an
    # 8-byte span id is a meaningful loss of uniformity.
    param([int]$ByteCount)
    $bytes = New-Object byte[] $ByteCount
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant())
}

function New-StringAttribute {
    param([string]$Key, [string]$Value)
    return @{ key = $Key; value = @{ stringValue = $Value } }
}

function New-IntAttribute {
    # OTLP/JSON encodes every int64 as a decimal STRING. A bare JSON number is not spec
    # compliant and silently loses precision for large values. This trips up nearly everyone.
    param([string]$Key, [long]$Value)
    return @{ key = $Key; value = @{ intValue = $Value.ToString([Globalization.CultureInfo]::InvariantCulture) } }
}

function Get-Field {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return '' }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return '' }
    return [string]$prop.Value
}

function Get-TraceParent {
    <#
        Forward-looking: Copilot CLI 1.0.81 does NOT put trace context in the hook payload, so
        this never fires today. It is kept because it is the correct answer the moment the CLI
        does supply it -- the span then becomes a child of Copilot's own sub-agent span instead
        of a root that correlates only by session id.

        Format is version-traceid-parentid-flags. Later versions may append fields, so only the
        first four are read, per the W3C specification.
    #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $parts = $Value.Trim().ToLowerInvariant() -split '-'
    if ($parts.Count -lt 4) { return $null }
    $version = $parts[0]; $traceId = $parts[1]; $spanId = $parts[2]; $flags = $parts[3]
    if ($version -notmatch '^[0-9a-f]{2}$' -or $version -eq 'ff') { return $null }  # 'ff' is reserved
    if ($version -eq '00' -and $parts.Count -ne 4) { return $null }
    if ($traceId -notmatch '^[0-9a-f]{32}$' -or $traceId -match '^0+$') { return $null }
    if ($spanId -notmatch '^[0-9a-f]{16}$' -or $spanId -match '^0+$') { return $null }
    if ($flags -notmatch '^[0-9a-f]{2}$') { return $null }
    return @{ TraceId = $traceId; SpanId = $spanId; Flags = $flags }
}

function New-SpanDocument {
    param($Payload)

    $sessionId = Get-Field $Payload 'sessionId'
    $agentName = Get-Field $Payload 'agentName'

    # The payload timestamp is Unix epoch MILLISECONDS.
    $timeMs = [long]0
    if (-not [long]::TryParse((Get-Field $Payload 'timestamp'), [ref]$timeMs) -or $timeMs -le 0) {
        $timeMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
    # A zero-length span: it marks the INSTANT the sub-agent finished. Measuring a real duration
    # would mean pairing this with 'subagentStart' and persisting state between two separate hook
    # invocations -- see "Adapting it" in README.md.
    $timeNano = ($timeMs * 1000000).ToString([Globalization.CultureInfo]::InvariantCulture)

    # 'response' is the sub-agent's full text. Its LENGTH is a useful signal; its CONTENT never
    # goes on the wire. The same reasoning excludes 'cwd' and 'transcriptPath' entirely.
    # (.NET counts UTF-16 code units here while jq counts code points, so the two scripts
    # disagree by one per non-BMP character, e.g. an emoji. Immaterial as a rough size signal.)
    $responseChars = (Get-Field $Payload 'response').Length

    $attributes = @(
        # The two attributes Copilot CLI puts its own session id on, so hook spans can be joined
        # to the CLI's spans by query even without shared trace context.
        (New-StringAttribute 'gen_ai.conversation.id' $sessionId),
        (New-StringAttribute 'github.copilot.session.id' $sessionId),
        (New-StringAttribute 'github.copilot.agent.name' $agentName),
        (New-StringAttribute 'github.copilot.agent.id' (Get-Field $Payload 'agentId')),
        (New-StringAttribute 'github.copilot.agent.type' (Get-Field $Payload 'agentType')),
        (New-StringAttribute 'copilot.hook.event' 'subagentStop'),
        (New-StringAttribute 'copilot.subagent.stop_reason' (Get-Field $Payload 'stopReason')),
        (New-IntAttribute 'copilot.subagent.response_chars' $responseChars)
    )

    $serviceName = Get-EnvFirst @('HOOK_OTEL_SERVICE_NAME', 'OTEL_SERVICE_NAME')
    if ([string]::IsNullOrWhiteSpace($serviceName)) { $serviceName = 'github-copilot' }

    $spanName = 'copilot.subagent'
    if (-not [string]::IsNullOrWhiteSpace($agentName)) { $spanName = "copilot.subagent $agentName" }

    $span = @{
        traceId           = ''
        spanId            = (New-RandomHex 8)
        name              = $spanName
        kind              = 1   # INTERNAL
        startTimeUnixNano = $timeNano
        endTimeUnixNano   = $timeNano
        attributes        = $attributes
        status            = @{ code = 0 }
    }

    $parent = Get-TraceParent (Get-Field $Payload 'traceparent')
    if ($null -eq $parent) {
        # No context to inherit, so this is a root span that correlates by session id.
        $span['traceId'] = New-RandomHex 16
    }
    else {
        $span['traceId'] = $parent.TraceId
        $span['parentSpanId'] = $parent.SpanId
        $traceState = Get-Field $Payload 'tracestate'
        if (-not [string]::IsNullOrWhiteSpace($traceState)) { $span['traceState'] = $traceState }
        # OTLP carries the W3C trace-flags in the low 8 bits of span.flags. Dropping them would
        # export a child of a sampled parent as unsampled. Bits 8 and 9 mark is_remote as
        # present and true -- the parent belongs to the CLI, not to this process.
        $span['flags'] = [Convert]::ToInt32($parent.Flags, 16) -bor 0x300
    }

    # Wrap every array in @( ) explicitly: PowerShell 5.1 unwraps a single-element array on the
    # way into ConvertTo-Json, which would emit an object where OTLP requires a list.
    return @{
        resourceSpans = @(
            @{
                resource   = @{ attributes = @((New-StringAttribute 'service.name' $serviceName)) }
                scopeSpans = @(
                    @{
                        scope = @{ name = $script:ScopeName }
                        spans = @($span)
                    }
                )
            }
        )
    }
}

# --------------------------------------------------------------------------------------------
# Sending it
#
# This is where the process boundary would go if you wanted the hardened version: the production
# emitter runs everything below in a separate process it can kill on a wall-clock deadline.
# --------------------------------------------------------------------------------------------

function Send-SpanDocument {
    param([string]$Json, [string]$Endpoint, [hashtable]$Headers, [int]$TimeoutSec)
    try {
        # Windows PowerShell 5.1 defaults to SSL3/TLS1.0, which modern collectors reject.
        [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        # An older framework without TLS 1.2 still works against a plaintext local collector.
    }
    # Assigned to $null because Invoke-RestMethod writes the response body to the success
    # stream, and the success stream is this hook's stdout.
    #
    # -MaximumRedirection 0 because these headers can carry a bearer token: PowerShell replays
    # them on a redirect, so a collector answering 3xx with someone else's origin would be
    # handed the credential. curl is not given -L below for the same reason. A redirect makes
    # this throw, which the caller swallows -- correct, since a dropped span beats a leaked token.
    $null = Invoke-RestMethod -Uri $Endpoint -Method Post `
        -Body ([Text.Encoding]::UTF8.GetBytes($Json)) `
        -ContentType 'application/json' -Headers $Headers -TimeoutSec $TimeoutSec `
        -MaximumRedirection 0 -UseBasicParsing
}

function Publish-HookSpan {
    param([string]$RawPayload)

    if (-not (Test-TelemetryEnabled)) { return }

    # An explicitly gRPC-configured exporter must not be sent HTTP/JSON: a shell script cannot
    # speak gRPC, and the configured port is a gRPC port, so the POST would be junk traffic.
    # This matters here precisely BECAUSE the sample honours the user's standard OTEL_* settings.
    $protocol = (Get-EnvFirst @(
            'HOOK_OTEL_PROTOCOL',
            'OTEL_EXPORTER_OTLP_TRACES_PROTOCOL',
            'OTEL_EXPORTER_OTLP_PROTOCOL')).ToLowerInvariant()
    if ($protocol -eq 'grpc') { return }

    if ([string]::IsNullOrWhiteSpace($RawPayload)) { return }
    $payload = $RawPayload | ConvertFrom-Json

    $json = New-SpanDocument $payload | ConvertTo-Json -Depth 20 -Compress

    # A sink, not a switch: it never enables telemetry on its own, it only diverts it. Handy for
    # seeing exactly what would be exported without running a collector.
    $debugFile = Get-Env 'HOOK_OTEL_DEBUG_FILE'
    if (-not [string]::IsNullOrWhiteSpace($debugFile)) {
        # One document per line. Headers are never written here; they can carry credentials.
        $writer = New-Object System.IO.StreamWriter($debugFile, $true, (New-Object System.Text.UTF8Encoding($false)))
        try { $writer.WriteLine($json) } finally { $writer.Dispose() }
        return
    }

    $resolved = Get-TracesEndpoint
    if (-not (Test-Endpoint $resolved.Endpoint)) { return }
    Send-SpanDocument -Json $json -Endpoint $resolved.Endpoint `
        -Headers (Get-OtlpHeaders -Namespace $resolved.Namespace) -TimeoutSec (Get-TimeoutSec)
}

# --------------------------------------------------------------------------------------------
# Main. Reads the payload from stdin, prints '{}' to stdout, and always exits 0.
# --------------------------------------------------------------------------------------------

try {
    # Decoded as UTF-8 explicitly. [Console]::In uses the console input encoding, which on
    # Windows PowerShell 5.1 is the OEM code page, so a payload containing any non-ASCII
    # character would arrive as mojibake and be exported that way.
    $stdin = New-Object System.IO.StreamReader(
        [Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
    try { $raw = $stdin.ReadToEnd() } finally { $stdin.Dispose() }
    Publish-HookSpan -RawPayload $raw
}
catch {
    # Telemetry is never worth a failed hook. Swallow everything.
}

# The only thing this script is allowed to write to stdout: "no modification".
Write-Output '{}'
exit 0
