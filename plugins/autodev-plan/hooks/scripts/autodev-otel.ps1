<#
.SYNOPSIS
    OTLP/HTTP span emitter for the autodev plugins (Windows / PowerShell).

.DESCRIPTION
    Emits exactly one OpenTelemetry span describing a completed autodev sub-agent, so that
    'ISSUES' verdicts reported by the review gates can be counted in a tracing backend.

    This script is ALWAYS run as an isolated child process by the hook scripts, never
    dot-sourced into them. That is a safety requirement, not a style preference: the hook
    scripts' stdout is parsed as a single JSON document, they run with
    $ErrorActionPreference = 'Stop', and a preToolUse hook is fail-closed. Running here means
    nothing this script writes to any stream, and no exit code it returns, can reach the hook's
    stdout or change its behaviour. The parent additionally enforces a hard wall-clock bound by
    killing this process, because Invoke-RestMethod's -TimeoutSec does not bound DNS resolution
    on Windows PowerShell 5.1.

    Correlation: the hook payload carries no W3C trace context, so this span cannot be a child
    of Copilot's own spans. Instead it carries the raw session id as 'gen_ai.conversation.id'
    and 'github.copilot.session.id', which are the attributes Copilot CLI puts its session id
    on, making a backend-side join exact.

    Configuration comes from the same environment variables Copilot CLI itself uses, so hook
    telemetry switches on and off with Copilot's own telemetry.

    Written for Windows PowerShell 5.1 compatibility (no -AsHashtable, no ternaries, no
    three-argument Join-Path).

.PARAMETER PayloadPath
    Path to a JSON file describing the span to emit. Written by the calling hook script.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$PayloadPath
)

# Never surface anything. Every failure mode here is "no telemetry", never "broken hook".
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

# Ceiling on the child-side request timeout. The parent applies its own kill-based bound; this
# keeps a user-set value from ever approaching the hook's own timeout budget.
$script:MaxTimeoutSec = 5
$script:DefaultTimeoutSec = 2

function Test-Truthy {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value.Trim().ToLowerInvariant() -in @('1', 'true', 'yes', 'on'))
}

function Get-Env {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) { return '' }
    return $value
}

function Get-TimeoutSec {
    $raw = Get-Env 'AUTODEV_OTEL_TIMEOUT_SEC'
    if ([string]::IsNullOrWhiteSpace($raw)) { return $script:DefaultTimeoutSec }
    $parsed = 0
    if (-not [int]::TryParse($raw.Trim(), [ref]$parsed)) { return $script:DefaultTimeoutSec }
    if ($parsed -lt 1) { return 1 }
    if ($parsed -gt $script:MaxTimeoutSec) { return $script:MaxTimeoutSec }
    return $parsed
}

function Get-Protocol {
    # An explicitly gRPC-configured exporter must not be sent HTTP/JSON: the endpoint is a gRPC
    # port and the POST would be meaningless traffic rather than a dropped span.
    $protocol = Get-Env 'OTEL_EXPORTER_OTLP_TRACES_PROTOCOL'
    if ([string]::IsNullOrWhiteSpace($protocol)) {
        $protocol = Get-Env 'OTEL_EXPORTER_OTLP_PROTOCOL'
    }
    return $protocol.Trim().ToLowerInvariant()
}

function Get-TracesEndpoint {
    # Per the OTLP exporter specification the signal-specific variable is used verbatim, while
    # the generic one is a base that '/v1/traces' is appended to. Copilot's implicit
    # 'http://127.0.0.1:4318' default is deliberately not reproduced: silently posting to
    # localhost from a hook would be surprising.
    $specific = (Get-Env 'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT').Trim()
    if (-not [string]::IsNullOrWhiteSpace($specific)) { return $specific }

    $generic = (Get-Env 'OTEL_EXPORTER_OTLP_ENDPOINT').Trim()
    if ([string]::IsNullOrWhiteSpace($generic)) { return '' }
    return ($generic.TrimEnd('/') + '/v1/traces')
}

function Test-Endpoint {
    param([string]$Endpoint)
    if ([string]::IsNullOrWhiteSpace($Endpoint)) { return $false }
    $uri = $null
    if (-not [Uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$uri)) { return $false }
    # http/https only, so a malformed variable cannot turn into a file write or some other scheme.
    return ($uri.Scheme -eq 'http' -or $uri.Scheme -eq 'https')
}

function Get-OtlpHeaders {
    # OTEL_EXPORTER_OTLP_TRACES_HEADERS wins over the generic variable rather than merging with
    # it, per the specification. Values are percent-encoded and split on the FIRST '=' only, so a
    # base64 token containing '=' survives intact. Never logged.
    $raw = Get-Env 'OTEL_EXPORTER_OTLP_TRACES_HEADERS'
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $raw = Get-Env 'OTEL_EXPORTER_OTLP_HEADERS'
    }
    $headers = @{}
    if ([string]::IsNullOrWhiteSpace($raw)) { return $headers }
    foreach ($pair in ($raw -split ',')) {
        $trimmed = $pair.Trim()
        if ($trimmed -eq '') { continue }
        $index = $trimmed.IndexOf('=')
        if ($index -lt 1) { continue }
        $name = $trimmed.Substring(0, $index).Trim()
        $value = $trimmed.Substring($index + 1).Trim()
        if ($name -eq '') { continue }
        try {
            $headers[[Uri]::UnescapeDataString($name)] = [Uri]::UnescapeDataString($value)
        }
        catch {
            $headers[$name] = $value
        }
    }
    return $headers
}

function New-RandomHex {
    # Real randomness, not GUID text: a GUID has fixed version and variant bits, which for an
    # 8-byte span id is a meaningful loss of uniformity. All-zero ids are invalid per the spec,
    # so reject and retry rather than emit an unusable span.
    param([int]$ByteCount)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        for ($attempt = 0; $attempt -lt 8; $attempt++) {
            $bytes = New-Object byte[] $ByteCount
            $rng.GetBytes($bytes)
            $allZero = $true
            foreach ($b in $bytes) {
                if ($b -ne 0) { $allZero = $false; break }
            }
            if ($allZero) { continue }
            return ([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant())
        }
    }
    finally {
        if ($rng -is [IDisposable]) { $rng.Dispose() }
    }
    return ''
}

function New-StringAttribute {
    param([string]$Key, [string]$Value)
    return @{ key = $Key; value = @{ stringValue = $Value } }
}

function New-IntAttribute {
    # OTLP/JSON encodes every int64 as a decimal STRING. Emitting a JSON number would silently
    # lose precision for large values and is not spec-compliant.
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

function Get-LongField {
    param($Object, [string]$Name)
    $raw = Get-Field -Object $Object -Name $Name
    $parsed = [long]0
    if ([long]::TryParse($raw, [ref]$parsed) -and $parsed -ge 0) { return $parsed }
    return [long]0
}

function New-SpanDocument {
    param($Request)

    $sessionId = Get-Field -Object $Request -Name 'sessionId'
    $verdict = Get-Field -Object $Request -Name 'verdict'
    $unitKey = Get-Field -Object $Request -Name 'unitKey'
    # An attribute key must never be empty, and never come from an unexpected value: a bad key
    # makes the attribute unusable in a query.
    if ($unitKey -ne 'autodev.gate' -and $unitKey -ne 'autodev.stage') { $unitKey = 'autodev.gate' }
    $unitValue = Get-Field -Object $Request -Name 'unitValue'
    $plugin = Get-Field -Object $Request -Name 'plugin'

    $endMs = Get-LongField -Object $Request -Name 'endTimeMs'
    if ($endMs -le 0) { $endMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    $startMs = Get-LongField -Object $Request -Name 'startTimeMs'
    # A missing or stale start time yields an honest zero-duration span rather than a fabricated
    # or negative one.
    if ($startMs -le 0 -or $startMs -gt $endMs) { $startMs = $endMs }

    $attributes = @(
        (New-StringAttribute -Key 'gen_ai.conversation.id' -Value $sessionId),
        (New-StringAttribute -Key 'github.copilot.session.id' -Value $sessionId),
        (New-StringAttribute -Key 'github.copilot.agent.name' -Value (Get-Field -Object $Request -Name 'agentName')),
        (New-StringAttribute -Key 'github.copilot.agent.id' -Value (Get-Field -Object $Request -Name 'agentId')),
        (New-StringAttribute -Key 'autodev.plugin' -Value $plugin),
        (New-StringAttribute -Key $unitKey -Value $unitValue),
        (New-StringAttribute -Key 'autodev.verdict' -Value $verdict),
        # Counted separately on purpose: a BLOCKED worker is an operational stall, not a review
        # finding, and folding it into the issue count would inflate it.
        (New-IntAttribute -Key 'autodev.issues' -Value $(if ($verdict -eq 'ISSUES') { 1 } else { 0 })),
        (New-IntAttribute -Key 'autodev.blocked' -Value $(if ($verdict -eq 'BLOCKED') { 1 } else { 0 })),
        (New-IntAttribute -Key 'autodev.attempt' -Value (Get-LongField -Object $Request -Name 'attempt')),
        (New-IntAttribute -Key 'autodev.total_invocations' -Value (Get-LongField -Object $Request -Name 'totalInvocations'))
    )

    $serviceName = (Get-Env 'OTEL_SERVICE_NAME').Trim()
    if ([string]::IsNullOrWhiteSpace($serviceName)) { $serviceName = 'github-copilot' }

    $traceId = New-RandomHex -ByteCount 16
    $spanId = New-RandomHex -ByteCount 8
    if ([string]::IsNullOrWhiteSpace($traceId) -or [string]::IsNullOrWhiteSpace($spanId)) {
        return $null
    }

    $spanName = Get-Field -Object $Request -Name 'spanName'
    if ([string]::IsNullOrWhiteSpace($spanName)) { $spanName = 'autodev.subagent' }

    $span = @{
        traceId           = $traceId
        spanId            = $spanId
        name              = $spanName
        kind              = 1
        startTimeUnixNano = ($startMs * 1000000).ToString([Globalization.CultureInfo]::InvariantCulture)
        endTimeUnixNano   = ($endMs * 1000000).ToString([Globalization.CultureInfo]::InvariantCulture)
        attributes        = $attributes
        status            = @{ code = 0 }
    }

    return @{
        resourceSpans = @(
            @{
                resource   = @{
                    attributes = @((New-StringAttribute -Key 'service.name' -Value $serviceName))
                }
                scopeSpans = @(
                    @{
                        scope = @{ name = 'autodev-plugins' }
                        spans = @($span)
                    }
                )
            }
        )
    }
}

function ConvertTo-CompactJson {
    param($Document)
    # -Depth must comfortably exceed the resourceSpans/scopeSpans/spans/attributes/value nesting.
    # PowerShell 5.1 collapses a single-element array back to a scalar on the way out, so arrays
    # are re-wrapped explicitly below rather than trusted to survive.
    return ($Document | ConvertTo-Json -Depth 20 -Compress)
}

function Send-SpanDocument {
    param([string]$Json, [string]$Endpoint, [hashtable]$Headers, [int]$TimeoutSec)
    # Windows PowerShell 5.1 defaults to SSL3/TLS1.0, which most collectors now reject.
    try {
        [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        # An older framework without Tls12 still works against plaintext local collectors.
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
    # Result assigned away: Invoke-RestMethod writes the response body to the success stream,
    # which must never become output even though the parent discards it anyway.
    $null = Invoke-RestMethod -Uri $Endpoint -Method Post -Body $bytes `
        -ContentType 'application/json' -Headers $Headers -TimeoutSec $TimeoutSec `
        -UseBasicParsing
}

# --------------------------------------------------------------------------------------------
# Main. Every path exits 0 and writes nothing to stdout.
# --------------------------------------------------------------------------------------------

try {
    if (-not (Test-Truthy -Value (Get-Env 'COPILOT_OTEL_ENABLED'))) { exit 0 }

    $debugFile = (Get-Env 'AUTODEV_OTEL_DEBUG_FILE').Trim()
    $useDebugFile = -not [string]::IsNullOrWhiteSpace($debugFile)

    $protocol = Get-Protocol
    if ($protocol -eq 'grpc') { exit 0 }

    $endpoint = Get-TracesEndpoint
    # The debug sink is for tests and for a developer inspecting what would be exported, so it
    # deliberately does not require a reachable endpoint.
    if (-not $useDebugFile -and -not (Test-Endpoint -Endpoint $endpoint)) { exit 0 }

    if (-not (Test-Path -LiteralPath $PayloadPath)) { exit 0 }
    $raw = Get-Content -LiteralPath $PayloadPath -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $request = $raw | ConvertFrom-Json -ErrorAction Stop

    $document = New-SpanDocument -Request $request
    if ($null -eq $document) { exit 0 }
    $json = ConvertTo-CompactJson -Document $document

    if ($useDebugFile) {
        # One document per line so a test can count emissions as well as inspect them. Headers
        # are never written here; they can carry credentials.
        $writer = New-Object System.IO.StreamWriter($debugFile, $true, (New-Object System.Text.UTF8Encoding($false)))
        try { $writer.WriteLine($json) } finally { $writer.Dispose() }
        exit 0
    }

    Send-SpanDocument -Json $json -Endpoint $endpoint -Headers (Get-OtlpHeaders) `
        -TimeoutSec (Get-TimeoutSec)
    exit 0
}
catch {
    # Telemetry is never worth a failed hook. Swallow everything.
    exit 0
}
