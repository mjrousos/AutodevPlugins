<#
.SYNOPSIS
    Gate tracker for the merged autodev plugin (Windows / PowerShell).

.DESCRIPTION
    Invoked by hooks.json for four hook events. Reads the hook payload as JSON on stdin and
    writes exactly one JSON object to stdout.

    Responsibilities:
      * subagentStart - record that a review gate was invoked; increment its attempt counter.
      * subagentStop  - parse the reviewer's verdict, record it, log the reviewer's full
                        feedback, and append a tracker footer to the response the orchestrator
                        receives.
      * agentStop     - block the orchestrator from ending its turn while gates are outstanding.
      * preToolUse    - deny ask_user while gating, so the gate phase stays autonomous, and deny
                        further reviewer invocations once the attempt budget is spent.

    Enforcement state lives at '<COPILOT_HOME>/autodev/gates/<sessionId>.json', outside the
    workspace and keyed by session. That matters for two reasons: concurrent sessions in one
    repository must not clobber each other's attempt counters, and the orchestrator is allowed to
    edit files in the workspace, so state it could rewrite would not be enforcement at all.

    A mirror of that state, the audit trail and the reviewer feedback log are written into
    '<session cwd>/.autodev/' so a developer can watch a run in progress and read the reviews
    afterwards, next to the plan the gates are reviewing. Audit and feedback are records only.
    The state mirror is read only as an exact-session recovery checkpoint when authoritative
    state is missing or corrupt; normal enforcement always prefers the external state.

    SAFETY: preToolUse command hooks are fail-closed - any non-zero exit or crash denies the
    tool call. A bug here would permanently break ask_user for the user, so every path is
    wrapped and this script always emits valid JSON and always exits 0.

    Written for Windows PowerShell 5.1 compatibility (no -AsHashtable, no ternaries, no
    three-argument Join-Path).
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('subagentStart', 'subagentStop', 'agentStop', 'preToolUse')]
    [string]$EventName
)

$ErrorActionPreference = 'Stop'

# Gate evaluation order. Also the order the orchestrator must run them in.
$script:GateOrder = @('architecture', 'security', 'privacy')
# Per gate, per pass. A gate that is re-run after previously passing starts a fresh budget.
$script:MaxAttempts = 10
# Kept below the CLI's own 8-block runaway guard so we surrender first.
$script:MaxBlocks = 5
# Absolute ceiling across all gates and all re-gate passes. Because a re-gate resets a gate's
# per-pass budget, this is what makes an unbounded re-gate cascade impossible. Must stay above
# GateOrder.Count * MaxAttempts, or it would fire before a single pass could spend the per-gate
# budget and would silently become the real limit.
$script:MaxTotalInvocations = 40
# Defensive ceiling on the finding count exported as autodev.issues. A pathological or malicious
# reviewer response must not turn into an absurd metric value.
$script:MaxFindings = 500
# Hard ceiling on how long the telemetry child process may run before the parent kills it. Sits
# well below the hook's own 20 second timeout so a hung collector can never cost the gate its
# tracker footer, but high enough to absorb PowerShell process startup on a loaded machine --
# at 6s, spans were silently dropped whenever several agents ran concurrently.
$script:OtelParentTimeoutMs = 12000

function Get-StateDirectory {
    # Enforcement state stays outside the workspace, keyed by session id. Two sessions running
    # in the same repository must not share a state file, and the orchestrator must not be able
    # to edit its way past a gate.
    #
    # This resolves a path but deliberately does NOT create anything; see Confirm-Directory.
    $home_ = $env:COPILOT_HOME
    if ([string]::IsNullOrWhiteSpace($home_)) {
        $profileDir = $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($profileDir)) { $profileDir = $HOME }
        $home_ = Join-Path $profileDir '.copilot'
    }
    return (Join-Path (Join-Path $home_ 'autodev') 'gates')
}

function Get-ViewDirectory {
    # Where the developer-facing artifacts go: '.autodev' beside the plan the gates are
    # reviewing. Returns an empty string when there is no usable working directory, in which
    # case the caller falls back to the state directory.
    param([string]$Cwd)
    if (-not [string]::IsNullOrWhiteSpace($Cwd) -and (Test-Path -LiteralPath $Cwd -PathType Container)) {
        return (Join-Path $Cwd '.autodev')
    }
    return ''
}

function Confirm-Directory {
    # Called only once a real review gate has been identified, so directories appear exactly
    # when the workflow starts using them. Creating them on every hook event would litter an
    # empty '.autodev' into any repository where an unrelated session called the task tool.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (Test-Path -LiteralPath $Path) { return $true }
    try {
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Get-SafeSessionId {
    param([string]$SessionId)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return 'unknown-session' }
    # Defend against path traversal via a hostile session id.
    return ($SessionId -replace '[^A-Za-z0-9._-]', '_')
}

function New-DefaultState {
    param([string]$SessionId)
    $state = @{
        sessionId        = $SessionId
        createdAt        = (Get-Date).ToUniversalTime().ToString('o')
        updatedAt        = (Get-Date).ToUniversalTime().ToString('o')
        blocks           = 0
        totalInvocations = 0
    }
    foreach ($gate in $script:GateOrder) {
        $state["${gate}Attempts"] = 0
        $state["${gate}Verdict"] = 'pending'
    }
    return $state
}

function Read-State {
    param([string]$Path, [string]$RecoveryPath, [string]$SessionId)
    # The out-of-workspace file is authoritative. The workspace copy is also a recovery
    # checkpoint: if the authoritative directory is deleted mid-run, the next reviewer must
    # restore the same session rather than look like a new session and erase the audit trail.
    # An exact session-id match prevents a previous run in this workspace from being adopted.
    $candidates = @($Path)
    if (-not [string]::IsNullOrWhiteSpace($RecoveryPath) -and $RecoveryPath -ne $Path) {
        $candidates += $RecoveryPath
    }
    foreach ($candidate in $candidates) {
        # Start clean for every candidate. A corrupt authoritative file must not partially
        # mutate defaults that are then reused while processing the recovery checkpoint.
        $state = New-DefaultState -SessionId $SessionId
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $raw = Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            $ownerProp = $parsed.PSObject.Properties['sessionId']
            if ($null -eq $ownerProp -or [string]$ownerProp.Value -ne $SessionId) { continue }

            $numericKeys = @('blocks', 'totalInvocations')
            foreach ($gate in $script:GateOrder) { $numericKeys += "${gate}Attempts" }
            foreach ($key in $numericKeys) {
                $prop = $parsed.PSObject.Properties[$key]
                if ($null -eq $prop -or $null -eq $prop.Value) { continue }
                $normalized = 0
                $rendered = [Convert]::ToString(
                    $prop.Value,
                    [Globalization.CultureInfo]::InvariantCulture)
                if ($rendered -notmatch '^[0-9]+$' -or
                    -not [int]::TryParse($rendered, [ref]$normalized) -or
                    $normalized -lt 0) {
                    throw "Invalid state counter '$key'."
                }
                $state[$key] = $normalized
            }

            foreach ($gate in $script:GateOrder) {
                $key = "${gate}Verdict"
                $prop = $parsed.PSObject.Properties[$key]
                if ($null -eq $prop -or $null -eq $prop.Value) { continue }
                $verdict = [string]$prop.Value
                if ($verdict -notin @('pending', 'running', 'PASS', 'ISSUES')) {
                    throw "Invalid state verdict '$key'."
                }
                $state[$key] = $verdict
            }

            foreach ($key in @('createdAt', 'updatedAt')) {
                $prop = $parsed.PSObject.Properties[$key]
                if ($null -ne $prop -and $null -ne $prop.Value) {
                    $state[$key] = [string]$prop.Value
                }
            }
            return $state
        }
        catch {
            # Syntax, merge and normalization failures corrupt only this candidate. Try the
            # exact-session recovery checkpoint before treating state as absent.
            continue
        }
    }

    return (New-DefaultState -SessionId $SessionId)
}

function Write-State {
    param([hashtable]$State, [string]$Path, [string]$MirrorPath)
    $State['updatedAt'] = (Get-Date).ToUniversalTime().ToString('o')
    $json = $State | ConvertTo-Json -Depth 5
    # Write then rename, so a concurrent reader never observes a half-written file. A torn read
    # would be treated as absent state, which would silently switch enforcement off.
    $tmp = "$Path.$PID.tmp"
    try {
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
    catch {
        # Do not let a persistence failure swallow an enforcement decision. The mirror write
        # below may still preserve the updated state, and the hook can still return its block or
        # deny response.
    }
    finally {
        # If the rename failed (for example a transient lock) the temp file would otherwise be
        # orphaned in the gates directory, so clean it up unconditionally.
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    # Human-facing copy and recovery checkpoint. Normal enforcement always reads the
    # authoritative path first; this is consulted only when that file is missing or corrupt.
    # It must be atomic too -- a torn checkpoint is indistinguishable from no recovery state.
    if (-not [string]::IsNullOrWhiteSpace($MirrorPath)) {
        $mirrorTmp = "$MirrorPath.$PID.tmp"
        try {
            Set-Content -LiteralPath $mirrorTmp -Value $json -Encoding UTF8 -ErrorAction Stop
            Move-Item -LiteralPath $mirrorTmp -Destination $MirrorPath -Force -ErrorAction Stop
        }
        catch { }
        finally {
            if (Test-Path -LiteralPath $mirrorTmp) {
                Remove-Item -LiteralPath $mirrorTmp -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Add-AuditRow {
    param(
        [string]$Path,
        [string]$SessionId,
        [string]$Gate,
        [int]$Attempt,
        [string]$Action,
        [string]$Verdict
    )
    try {
        $sessionMarker = "Session: ``$SessionId``"
        if (-not (Test-Path -LiteralPath $Path)) {
            $header = @(
                '# autodev review gate audit',
                '',
                $sessionMarker,
                "Started: $((Get-Date).ToUniversalTime().ToString('u'))",
                '',
                'Every row below was written by a hook observing a real sub-agent lifecycle event.',
                'The orchestrator does not write this file and is instructed not to edit it, but it',
                'lives in your workspace, so treat it as a record rather than as proof.',
                '',
                '| Time (UTC) | Gate | Attempt | Event | Verdict |',
                '| --- | --- | --- | --- | --- |'
            )
            Set-Content -LiteralPath $Path -Value ($header -join [Environment]::NewLine) -Encoding UTF8
        }
        else {
            # Windows PowerShell returns $null for a zero-byte file. Coerce it to an empty
            # string so a manually cleared or interrupted file self-heals with a new section.
            $existing = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            if ($null -eq $existing) { $existing = '' }
            if (-not $existing.Contains($sessionMarker)) {
                $sessionHeader = @(
                    '',
                    '---',
                    '',
                    $sessionMarker,
                    "Started: $((Get-Date).ToUniversalTime().ToString('u'))",
                    '',
                    '| Time (UTC) | Gate | Attempt | Event | Verdict |',
                    '| --- | --- | --- | --- | --- |'
                )
                Add-Content -LiteralPath $Path -Value ($sessionHeader -join [Environment]::NewLine) -Encoding UTF8
            }
        }
        $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $Path -Value "| $ts | $Gate | $Attempt | $Action | $Verdict |" -Encoding UTF8
    }
    catch {
        # Auditability must never control enforcement. A missing/read-only workspace still gets
        # the block or deny response derived from authoritative state.
    }
}

function Add-FeedbackEntry {
    param(
        [string]$Path,
        [string]$SessionId,
        [string]$Gate,
        [int]$Attempt,
        [string]$Verdict,
        [string]$Response
    )
    try {
        $sessionMarker = "Session: ``$SessionId``"
        if (-not (Test-Path -LiteralPath $Path)) {
            $header = @(
                '# autodev reviewer feedback log',
                '',
                $sessionMarker,
                "Started: $((Get-Date).ToUniversalTime().ToString('u'))",
                '',
                'Each entry is the reviewer sub-agent''s verbatim response, captured by a hook as the',
                'sub-agent finished. The orchestrator does not write this file and is instructed not',
                'to edit it, so it records what the reviewers actually said rather than what the',
                'orchestrator chose to relay. It lives in your workspace and is not read back by the',
                'gate tracker, so editing it changes nothing except this record.'
            )
            Set-Content -LiteralPath $Path -Value ($header -join [Environment]::NewLine) -Encoding UTF8
        }
        else {
            $existing = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            if ($null -eq $existing) { $existing = '' }
            if (-not $existing.Contains($sessionMarker)) {
                $sessionHeader = @(
                    '',
                    '---',
                    '',
                    $sessionMarker,
                    "Started: $((Get-Date).ToUniversalTime().ToString('u'))"
                )
                Add-Content -LiteralPath $Path -Value ($sessionHeader -join [Environment]::NewLine) -Encoding UTF8
            }
        }
        $ts = (Get-Date).ToUniversalTime().ToString('u')
        if ([string]::IsNullOrWhiteSpace($Response)) { $Response = '_(the reviewer returned no content)_' }
        $entry = @(
            '',
            '---',
            '',
            # Level 1: reviewers use '##' and '###' for their own sections, so an entry header at
            # the same level would be indistinguishable from the content it introduces.
            "# $Gate - attempt $Attempt - $Verdict",
            '',
            # Braces are required: "$ts_" would be parsed as a variable named 'ts_'.
            "_${ts}_",
            '',
            $Response.TrimEnd()
        )
        Add-Content -LiteralPath $Path -Value ($entry -join [Environment]::NewLine) -Encoding UTF8
    }
    catch {
        # The reviewer response and gate verdict must still reach the orchestrator even when the
        # workspace log cannot be written.
    }
}

function Resolve-Gate {
    param([string]$AgentName)
    if ([string]::IsNullOrWhiteSpace($AgentName)) { return $null }
    # agentName arrives namespaced, e.g. "autodev:autodev-privacy-review".
    if ($AgentName -match '^\s*(?:autodev:)?autodev-(architecture|security|privacy)-review\s*$') {
        return $Matches[1]
    }
    return $null
}

function Get-TaskAgentType {
    param($ToolArgs)
    # toolArgs arrives as a JSON *string* rather than an object, so it needs a second parse.
    if ($null -eq $ToolArgs) { return '' }
    try {
        if ($ToolArgs -is [string]) {
            if ([string]::IsNullOrWhiteSpace($ToolArgs)) { return '' }
            $parsed = $ToolArgs | ConvertFrom-Json -ErrorAction Stop
        }
        else {
            $parsed = $ToolArgs
        }
        $prop = $parsed.PSObject.Properties['agent_type']
        if ($null -eq $prop) { return '' }
        return [string]$prop.Value
    }
    catch {
        return ''
    }
}

function Get-Phase {
    param([hashtable]$State)
    $started = $false
    $allPassed = $true
    $escalated = $false
    foreach ($gate in $script:GateOrder) {
        $attempts = [int]$State["${gate}Attempts"]
        $verdict = [string]$State["${gate}Verdict"]
        if ($attempts -gt 0) { $started = $true }
        if ($verdict -ne 'PASS') {
            $allPassed = $false
            if ($attempts -ge $script:MaxAttempts) { $escalated = $true }
        }
    }
    if (-not $started) { return 'idle' }
    if ($allPassed) { return 'complete' }
    if ($escalated) { return 'escalated' }
    if ([int]$State['totalInvocations'] -ge $script:MaxTotalInvocations) { return 'escalated' }
    return 'gating'
}

function Get-StuckGates {
    param([hashtable]$State)
    $stuck = @()
    foreach ($gate in $script:GateOrder) {
        if ([string]$State["${gate}Verdict"] -ne 'PASS' -and
            [int]$State["${gate}Attempts"] -ge $script:MaxAttempts) {
            $stuck += $gate
        }
    }
    return $stuck
}

function Get-NextGate {
    param([hashtable]$State)
    foreach ($gate in $script:GateOrder) {
        if ([string]$State["${gate}Verdict"] -ne 'PASS') { return $gate }
    }
    return $null
}

function Get-GateStatusLine {
    param([hashtable]$State)
    $parts = @()
    foreach ($gate in $script:GateOrder) {
        $verdict = [string]$State["${gate}Verdict"]
        $attempts = [int]$State["${gate}Attempts"]
        if ($attempts -eq 0) {
            $parts += "$gate=not-yet-run"
        }
        else {
            $parts += "$gate=$verdict($attempts/$script:MaxAttempts)"
        }
    }
    return ($parts -join ', ')
}

function Measure-ReviewFindings {
    <#
        Counts the findings a reviewer reported, from the '### [severity] title' heading every
        reviewer agent is required to emit. This is what autodev.issues carries, so a dashboard can
        answer "how many problems were found" rather than only "how many gates came back dirty" --
        the latter is already answered by counting autodev.verdict = ISSUES.

        Counted for every verdict, not just ISSUES: a PASS that still raised nits genuinely found
        those, and reporting them is more honest than discarding them.

        The heading is matched rather than the severity word alone so that prose mentioning
        "[minor]" mid-sentence cannot inflate the count. Three '#' exactly: a deeper heading is not
        a finding, and is excluded naturally because the character after '###' must be whitespace
        or '['. The literal template line '### [blocker|major|minor|nit] <title>' does not match
        either, so a reviewer that echoes the template is not counted.
    #>
    param([string]$Response)
    if ([string]::IsNullOrWhiteSpace($Response)) { return 0 }
    $pattern = '(?im)^[ ]{0,3}#{3}[ \t]*\[(?:blocker|major|minor|nit)\]'
    $count = ([regex]::Matches($Response, $pattern)).Count
    # Defensive ceiling: a pathological response must not turn into an absurd metric value.
    if ($count -gt $script:MaxFindings) { return $script:MaxFindings }
    return $count
}

function Read-VerdictFromResponse {
    param([string]$Response)
    if ([string]::IsNullOrWhiteSpace($Response)) { return 'ISSUES' }
    # The contract requires the verdict on the FINAL line. Scanning the whole body would let a
    # reviewer that merely mentions a verdict mid-sentence ("I would say AUTODEV-VERDICT: PASS
    # if X were fixed") be recorded as a pass. Walk backwards to the last meaningful line and
    # judge only that; anything unexpected falls through to ISSUES.
    $lines = $Response -split "`r?`n"
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i].Trim()
        if ($line -eq '') { continue }
        # Tolerate a trailing code fence wrapped around the verdict.
        if ($line -match '^`{3,}[A-Za-z0-9]*$') { continue }
        # Tolerate markdown emphasis, blockquote markers and trailing punctuation.
        if ($line -match '^[\s*`>_-]*AUTODEV-VERDICT:\s*(PASS|ISSUES)[\s*`.]*$') {
            return $Matches[1].ToUpperInvariant()
        }
        return 'ISSUES'
    }
    return 'ISSUES'
}

function Read-StandardInput {
    # [Console]::In decodes using the console's active code page, which mangles any non-ASCII
    # character in a reviewer's response (an en dash arrives as three Latin-1 characters). The
    # payload is always UTF-8, so decode it as UTF-8 explicitly.
    try {
        $stdin = [Console]::OpenStandardInput()
        $reader = New-Object System.IO.StreamReader($stdin, (New-Object System.Text.UTF8Encoding($false)))
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    catch {
        return [Console]::In.ReadToEnd()
    }
}

function Write-JsonResult {
    param([hashtable]$Result)
    if ($null -eq $Result) { $Result = @{} }
    # Must be exactly one JSON object on stdout; -Compress keeps it on a single line.
    Write-Output ($Result | ConvertTo-Json -Depth 5 -Compress)
}

function Read-JsonStringField {
    <#
        Reads one top-level string field out of the raw payload without ConvertFrom-Json, for the
        fast path only. Returns $null when the field is missing, is not a plain JSON string, or
        uses an escape this deliberately minimal decoder does not implement -- every one of those
        answers sends the caller to the real parser rather than letting it guess.
    #>
    param([string]$Raw, [string]$Name)
    $match = [regex]::Match($Raw, '"' + [regex]::Escape($Name) + '"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if (-not $match.Success) { return $null }
    $value = $match.Groups[1].Value
    if ($value.IndexOf([char]0x5C) -lt 0) { return $value }

    # Windows paths arrive as '\\', so escapes cannot simply be rejected. This validates and
    # decodes in one left-to-right pass, which is also what makes it correct: a scan for
    # "backslash not followed by an allowed character" would misread the second half of every
    # '\\' pair and reject real paths. Deliberately a hand-rolled loop rather than a regex
    # MatchEvaluator -- compiling a script block into a delegate costs more on this path than
    # everything it was added to save.
    $decoded = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $value.Length) {
        $ch = $value[$i]
        if ($ch -ne [char]0x5C) {
            $null = $decoded.Append($ch)
            $i++
            continue
        }
        $i++
        if ($i -ge $value.Length) { return $null }
        $escaped = $value[$i]
        # Only the escapes a path or a session id realistically carries. Anything else, \n and
        # \uXXXX included, is left to the real parser.
        if ($escaped -ne [char]0x5C -and $escaped -ne '/' -and $escaped -ne '"') { return $null }
        $null = $decoded.Append($escaped)
        $i++
    }
    return $decoded.ToString()
}

function Test-EnforcementStateAbsent {
    <#
        True only when neither the authoritative state file nor its workspace mirror exists,
        which is the whole question agentStop and preToolUse ask before concluding they have
        nothing to enforce. False whenever that cannot be established cheaply and with
        certainty, which sends the caller down the fully parsed path.

        This is an optimization, never a second copy of the enforcement rules: every branch it
        can take ends in the same '{}' the parsed path would have produced.
    #>
    param([string]$RawInput)
    try {
        # A payload that is absent or unparseable already ends in '{}' below.
        if ([string]::IsNullOrWhiteSpace($RawInput)) { return $true }

        # Only the top-level object is scanned. A nested value could carry its own "sessionId"
        # or "cwd" key -- toolArgs is an arbitrary object -- and trusting one would name the
        # wrong state file, which on this path means wrongly concluding there is nothing to
        # enforce. Everything the CLI puts here comes before any nested value, so stopping at
        # the first one costs nothing real and removes the ambiguity entirely.
        $open = $RawInput.IndexOf('{')
        if ($open -lt 0) { return $false }
        $nested = $RawInput.IndexOfAny([char[]]@('{', '['), $open + 1)
        if ($nested -ge 0) { $scope = $RawInput.Substring($open, $nested - $open) }
        else { $scope = $RawInput.Substring($open) }

        $sessionId = Read-JsonStringField -Raw $scope -Name 'sessionId'
        if ($null -eq $sessionId) {
            # Not a plain string in the top-level scope. That covers a genuinely absent key, a
            # non-string value that ConvertFrom-Json would still stringify, and a key that was
            # cut off with the nested values -- so only treat it as absent when the key appears
            # nowhere in the payload at all. Anything else is left to the real parser, because
            # checking the wrong file here means walking past a live gate.
            if ($RawInput -match '"sessionId"') { return $false }
            $sessionId = ''
        }
        if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = 'unknown-session' }
        else { $sessionId = $sessionId -replace '[^A-Za-z0-9._-]', '_' }

        # Mirrors Get-StateDirectory, using [IO.Path] because Join-Path's first call costs more
        # in provider warm-up than everything else on this path put together.
        $copilotHome = $env:COPILOT_HOME
        if ([string]::IsNullOrWhiteSpace($copilotHome)) {
            $profileDir = $env:USERPROFILE
            if ([string]::IsNullOrWhiteSpace($profileDir)) { $profileDir = $HOME }
            if ([string]::IsNullOrWhiteSpace($profileDir)) { return $false }
            $copilotHome = [IO.Path]::Combine($profileDir, '.copilot')
        }
        $stateDir = [IO.Path]::Combine([IO.Path]::Combine($copilotHome, 'autodev'), 'gates')
        if ([IO.File]::Exists([IO.Path]::Combine($stateDir, "$sessionId.json"))) { return $false }

        # The mirror is an exact-session recovery checkpoint, so its absence has to be
        # established too -- in the one location Get-ViewDirectory would have chosen. Testing
        # both candidates instead looks safer and is not: the state-directory fallback is shared
        # by every session, so a single leftover mirror there would switch this fast path off
        # permanently for the whole machine.
        $cwd = Read-JsonStringField -Raw $scope -Name 'cwd'
        if ($null -eq $cwd) {
            if ($RawInput -match '"cwd"') { return $false }
            $cwd = ''
        }
        if ([string]::IsNullOrWhiteSpace($cwd)) {
            $viewDir = $stateDir
        }
        elseif ([IO.Directory]::Exists($cwd)) {
            $viewDir = [IO.Path]::Combine($cwd, '.autodev')
        }
        else {
            # Get-ViewDirectory decides this with Test-Path, which does not agree with
            # [IO.Directory]::Exists on every exotic path. Too rare to be worth a guess.
            return $false
        }
        return (-not [IO.File]::Exists([IO.Path]::Combine($viewDir, 'gate-status.json')))
    }
    catch {
        # Including any malformed path that made [IO.Path] throw.
        return $false
    }
}

function Test-TelemetryEnabled {
    <#
        Cheap early-out for the overwhelming majority of users, who never opt in to hook
        telemetry. This is the entire cost of the telemetry feature for them: no state is kept for
        it, so nothing else in the hook does telemetry work either.

        Keyed off AUTODEV_OTEL_* rather than Copilot's own OTEL_* variables because Copilot CLI
        scrubs every 'OTEL_'/'COPILOT_OTEL_' prefixed variable from a command hook's environment,
        so the latter are never visible here. COPILOT_OTEL_ENABLED remains a fallback for hosts
        that do not scrub. Must stay in step with Test-TelemetryEnabled in autodev-otel.ps1.
    #>
    $truthy = @('1', 'true', 'yes', 'on')

    # Tri-state: set-and-falsy is an explicit OFF that outranks every other signal.
    $explicit = [Environment]::GetEnvironmentVariable('AUTODEV_OTEL_ENABLED')
    if (-not [string]::IsNullOrWhiteSpace($explicit)) {
        return ($explicit.Trim().ToLowerInvariant() -in $truthy)
    }

    foreach ($name in @('AUTODEV_OTEL_TRACES_ENDPOINT', 'AUTODEV_OTEL_ENDPOINT')) {
        $endpoint = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($endpoint)) { return $true }
    }

    $value = [Environment]::GetEnvironmentVariable('COPILOT_OTEL_ENABLED')
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }
    return ($value.Trim().ToLowerInvariant() -in $truthy)
}

function Get-PowerShellPath {
    foreach ($candidate in @('powershell.exe', 'pwsh.exe')) {
        $path = Join-Path $PSHOME $candidate
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return 'powershell.exe'
}

function Send-OtelSpan {
    <#
        Runs the OTLP emitter as an ISOLATED CHILD PROCESS with both output streams redirected
        and discarded. This is a safety requirement, not a style preference: this script's stdout
        is parsed as a single JSON document and it runs under $ErrorActionPreference = 'Stop', so
        an in-process Invoke-RestMethod could put a response body on the success stream or turn a
        transport warning into a terminating error. Neither can happen across a process boundary.

        The parent also enforces a hard wall-clock bound by killing the child, because
        Invoke-RestMethod's -TimeoutSec does not bound DNS resolution on Windows PowerShell 5.1
        and this hook shares a 20 second budget.

        Telemetry failure is never worth a failed hook, so every path returns quietly.
    #>
    param([hashtable]$Request)
    try {
        if (-not (Test-TelemetryEnabled)) { return }
        $emitter = Join-Path $PSScriptRoot 'autodev-otel.ps1'
        if (-not (Test-Path -LiteralPath $emitter)) { return }

        $payloadPath = Join-Path ([IO.Path]::GetTempPath()) ("autodev-otel-$PID-$([guid]::NewGuid().ToString('N')).json")
        Set-Content -LiteralPath $payloadPath -Encoding UTF8 `
            -Value ($Request | ConvertTo-Json -Depth 5 -Compress)
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = Get-PowerShellPath
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $emitter +
            '" -PayloadPath "' + $payloadPath + '"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardInput = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            if ($null -eq $proc) { return }
            try {
                $proc.StandardInput.Close()
                # Drain both pipes so a child that unexpectedly wrote a lot could not block on a
                # full buffer and burn the whole timeout.
                $null = $proc.StandardOutput.ReadToEndAsync()
                $null = $proc.StandardError.ReadToEndAsync()
                if (-not $proc.WaitForExit($script:OtelParentTimeoutMs)) {
                    try { $proc.Kill() } catch { }
                }
            }
            finally {
                $proc.Dispose()
            }
        }
        finally {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # No telemetry, unchanged hook.
    }
}

# --------------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------------

try {
    $rawInput = Read-StandardInput

    # Fast path. agentStop fires at the end of every turn and preToolUse on every ask_user or
    # task call, in every session in every repository the plugin is installed in, and the CLI
    # pays a fresh PowerShell process for each one. Neither event can enforce anything until
    # subagentStart has created state, so the "no workflow running" answer is settled here using
    # only .NET calls: ConvertFrom-Json, Join-Path and Test-Path below each cost more in
    # first-use warm-up than this entire branch. Anything it cannot settle with certainty falls
    # through and is answered by the code that follows, which stays the only implementation of
    # the enforcement rules.
    if ($EventName -eq 'agentStop' -or $EventName -eq 'preToolUse') {
        if (Test-EnforcementStateAbsent -RawInput $rawInput) {
            [Console]::Out.WriteLine('{}')
            exit 0
        }
    }

    $payload = $null
    if (-not [string]::IsNullOrWhiteSpace($rawInput)) {
        $payload = $rawInput | ConvertFrom-Json
    }
    if ($null -eq $payload) { Write-JsonResult @{}; exit 0 }

    $sessionId = Get-SafeSessionId -SessionId ([string]$payload.sessionId)
    $stateDir = Get-StateDirectory
    $statePath = Join-Path $stateDir "$sessionId.json"
    # Developer-facing artifacts go next to the plan when there is a workspace to put them in.
    $viewDir = Get-ViewDirectory -Cwd ([string]$payload.cwd)
    if ([string]::IsNullOrWhiteSpace($viewDir)) { $viewDir = $stateDir }
    $mirrorPath = Join-Path $viewDir 'gate-status.json'
    $auditPath = Join-Path $viewDir 'gate-audit.md'
    $feedbackPath = Join-Path $viewDir 'feedback-log.md'

    switch ($EventName) {

        'subagentStart' {
            $gate = Resolve-Gate -AgentName ([string]$payload.agentName)
            if ($null -eq $gate) { Write-JsonResult @{}; exit 0 }
            Confirm-Directory -Path $stateDir | Out-Null
            Confirm-Directory -Path $viewDir | Out-Null

            $state = Read-State -Path $statePath -RecoveryPath $mirrorPath -SessionId $sessionId
            if ([string]$state["${gate}Verdict"] -eq 'PASS') {
                # This gate already passed, so this is a re-gate after a material change.
                # Start a fresh per-pass budget rather than charging it the old pass's attempts.
                $state["${gate}Attempts"] = 1
            }
            else {
                $state["${gate}Attempts"] = [int]$state["${gate}Attempts"] + 1
            }
            $state["${gate}Verdict"] = 'running'
            # Any later gate's verdict described an older version of the plan, so it is now
            # stale. Invalidating them keeps the tracker in step with the orchestrator's rule of
            # re-running every gate from the first one affected onward, and stops a re-gate from
            # reaching "complete" while downstream gates hold verdicts for a plan that changed.
            $gateIndex = [array]::IndexOf($script:GateOrder, $gate)
            for ($i = $gateIndex + 1; $i -lt $script:GateOrder.Count; $i++) {
                $later = $script:GateOrder[$i]
                $state["${later}Verdict"] = 'pending'
                $state["${later}Attempts"] = 0
            }
            $state['totalInvocations'] = [int]$state['totalInvocations'] + 1
            # Real progress was made, so forgive any earlier blocked stops.
            $state['blocks'] = 0
            Write-State -State $state -Path $statePath -MirrorPath $mirrorPath
            Add-AuditRow -Path $auditPath -SessionId $sessionId -Gate $gate `
                -Attempt ([int]$state["${gate}Attempts"]) -Action 'invoked' -Verdict '-'

            Write-JsonResult @{}
            exit 0
        }

        'subagentStop' {
            # subagentStop does not support a matcher, so filter here.
            $gate = Resolve-Gate -AgentName ([string]$payload.agentName)
            if ($null -eq $gate) { Write-JsonResult @{}; exit 0 }
            Confirm-Directory -Path $stateDir | Out-Null
            Confirm-Directory -Path $viewDir | Out-Null

            $response = [string]$payload.response
            $verdict = Read-VerdictFromResponse -Response $response

            $state = Read-State -Path $statePath -RecoveryPath $mirrorPath -SessionId $sessionId
            if ([int]$state["${gate}Attempts"] -lt 1) {
                # subagentStart was missed somehow; still count this attempt.
                $state["${gate}Attempts"] = 1
            }
            # Recover the session total ONLY when nothing at all has been counted yet. A per-gate
            # attempt counter cannot answer "was my start missed": subagentStart zeroes the later
            # gates' counters, so a security stop arriving after an architecture re-gate would see
            # zero and count itself a second time, prematurely exhausting the session ceiling and
            # forcing an escalation. Keying off the session total instead can only ever under-
            # count, which for a runaway guard is the harmless direction, while still keeping a
            # completed invocation from exporting a total of zero.
            if ([int]$state['totalInvocations'] -lt 1) { $state['totalInvocations'] = 1 }
            $state["${gate}Verdict"] = $verdict
            Write-State -State $state -Path $statePath -MirrorPath $mirrorPath

            $attempt = [int]$state["${gate}Attempts"]
            Add-AuditRow -Path $auditPath -SessionId $sessionId -Gate $gate `
                -Attempt $attempt -Action 'completed' -Verdict $verdict
            # Capture the review itself, not just that it happened, so the findings survive the
            # session and a developer can see what each gate actually objected to.
            Add-FeedbackEntry -Path $feedbackPath -SessionId $sessionId -Gate $gate `
                -Attempt $attempt -Verdict $verdict -Response $response

            $phase = Get-Phase -State $state
            $statusLine = Get-GateStatusLine -State $state

            $footerLines = @(
                '',
                '---',
                '[autodev gate tracker]',
                "Gate: $gate | Attempt $attempt of $script:MaxAttempts | Recorded verdict: $verdict",
                "Gate status: $statusLine"
            )

            if ($phase -eq 'complete') {
                $footerLines += "Next required action: all three gates have passed. Proceed to WRAPUP."
                $footerLines += "Audit trail: $auditPath"
                $footerLines += "Reviewer feedback log: $feedbackPath"
            }
            elseif ($phase -eq 'escalated') {
                if ([int]$state['totalInvocations'] -ge $script:MaxTotalInvocations) {
                    $footerLines += "Next required action: the review gates have used all $script:MaxTotalInvocations permitted reviewer invocations for this session without reaching a clean state. Stop looping and escalate to the user now, per your escalation protocol. ask_user is permitted again, and further reviewer invocations are now refused."
                }
                else {
                    # Name the gate that is actually stuck, which is not necessarily the gate
                    # that just reported.
                    $stuck = Get-StuckGates -State $state
                    $stuckList = $stuck -join ', '
                    $footerLines += "Next required action: the $stuckList gate(s) reached the $script:MaxAttempts-attempt limit without passing. Stop looping and escalate to the user now, per your escalation protocol. ask_user is permitted again, and further reviewer invocations are now refused. This session can no longer reach a clean 'all gates passed' state; say so plainly at wrap-up."
                }
                $footerLines += "Audit trail: $auditPath"
                $footerLines += "Reviewer feedback log: $feedbackPath"
            }
            elseif ($verdict -eq 'PASS') {
                $nextGate = Get-NextGate -State $state
                $footerLines += "Next required action: the $gate gate is closed. Invoke autodev:autodev-$nextGate-review next."
            }
            else {
                $remaining = $script:MaxAttempts - $attempt
                $footerLines += "Next required action: revise the plan file to address the findings above, then re-invoke autodev:autodev-$gate-review. $remaining attempt(s) remain before escalation."
            }

            $footer = $footerLines -join [Environment]::NewLine
            # Telemetry last, after every piece of enforcement state is durable. The raw session
            # id is used deliberately: the sanitized form exists only to build a safe filename,
            # and exporting it would break the join against Copilot's own spans for any session
            # id containing a character the sanitizer rewrites.
            Send-OtelSpan -Request @{
                spanName         = "autodev.gate $gate"
                sessionId        = [string]$payload.sessionId
                agentName        = [string]$payload.agentName
                agentId          = [string]$payload.agentId
                plugin           = 'autodev'
                unitKey          = 'autodev.gate'
                unitValue        = $gate
                verdict          = $verdict
                attempt          = $attempt
                totalInvocations = [int]$state['totalInvocations']
                # Passed through raw, NOT cast to [long] here. This hashtable is built before
                # Send-OtelSpan is entered, so it is outside its protective try/catch: a
                # non-numeric timestamp would throw under $ErrorActionPreference = 'Stop' and the
                # outer catch would emit '{}' instead of the tracker footer -- even with
                # telemetry disabled. The emitter validates it safely with Get-LongField.
                timeMs           = $payload.timestamp
                # The reviewer's own finding count, so autodev.issues measures problems found
                # rather than merely that this gate came back dirty.
                issues           = (Measure-ReviewFindings -Response $response)
                # Absent today, but forwarded so the span parents itself under Copilot's own
                # sub-agent span the moment the CLI starts supplying trace context.
                traceparent      = [string]$payload.traceparent
                tracestate       = [string]$payload.tracestate
            }
            Write-JsonResult @{ modifiedResponse = ($response + [Environment]::NewLine + $footer) }
            exit 0
        }

        'agentStop' {
            if (-not (Test-Path -LiteralPath $statePath) -and
                -not (Test-Path -LiteralPath $mirrorPath)) {
                Write-JsonResult @{}
                exit 0
            }
            $state = Read-State -Path $statePath -RecoveryPath $mirrorPath -SessionId $sessionId
            $phase = Get-Phase -State $state
            if ($phase -ne 'gating') { Write-JsonResult @{}; exit 0 }
            # The authoritative directory may be what was deleted. Recreate it before persisting
            # the recovered block counter; Write-State still fails open if this is impossible.
            Confirm-Directory -Path $stateDir | Out-Null
            Confirm-Directory -Path $viewDir | Out-Null

            $blocks = [int]$state['blocks']
            if ($blocks -ge $script:MaxBlocks) {
                # Give up rather than fight the CLI's own runaway guard.
                Write-JsonResult @{}
                exit 0
            }
            $state['blocks'] = $blocks + 1
            Write-State -State $state -Path $statePath -MirrorPath $mirrorPath

            $nextGate = Get-NextGate -State $state
            $statusLine = Get-GateStatusLine -State $state
            $attempts = [int]$state["${nextGate}Attempts"]

            $reason = "You stopped while autodev-plan review gates are still outstanding. " +
            "Gate status: $statusLine. " +
            "Do not end your turn and do not ask the user anything. " +
            "Continue the workflow now by invoking the $nextGate gate via the task tool with " +
            "agent_type 'autodev:autodev-$nextGate-review'"

            if ($attempts -gt 0) {
                $reason += ", after first revising the plan file to address that reviewer's outstanding findings"
            }
            $reason += '.'

            Add-AuditRow -Path $auditPath -SessionId $sessionId -Gate $nextGate `
                -Attempt $attempts -Action 'premature-stop-blocked' -Verdict '-'

            Write-JsonResult @{ decision = 'block'; reason = $reason }
            exit 0
        }

        'preToolUse' {
            # hooks.json restricts this hook to ask_user and task via a matcher, but do not rely
            # on that alone: without this check a broadened or missing matcher would deny
            # *every* tool while gating, including the tools the orchestrator needs to revise
            # the plan, deadlocking it against the agentStop block.
            $toolName = [string]$payload.toolName
            if ($toolName -notmatch '^(?:ask_user|AskUserQuestion|task)$') { Write-JsonResult @{}; exit 0 }

            if (-not (Test-Path -LiteralPath $statePath) -and
                -not (Test-Path -LiteralPath $mirrorPath)) {
                Write-JsonResult @{}
                exit 0
            }
            $state = Read-State -Path $statePath -RecoveryPath $mirrorPath -SessionId $sessionId
            $phase = Get-Phase -State $state

            if ($toolName -eq 'task') {
                # Everything else in this plugin only *asks* the orchestrator to stop looping
                # once a gate is out of attempts. This is the part that actually stops it: once
                # the budget is spent, refuse to start another reviewer. Without it an
                # orchestrator that ignores the escalation instruction can keep re-invoking a
                # gate past its cap, which is exactly what the cap exists to prevent.
                if ($phase -ne 'escalated') { Write-JsonResult @{}; exit 0 }

                $targetGate = Resolve-Gate -AgentName (Get-TaskAgentType -ToolArgs $payload.toolArgs)
                if ($null -eq $targetGate) { Write-JsonResult @{}; exit 0 }

                $stuck = @(Get-StuckGates -State $state)
                if ($stuck.Count -gt 0) {
                    $limitReason = "the $($stuck -join ', ') gate(s) have used all $script:MaxAttempts permitted attempts"
                }
                else {
                    $limitReason = "this session has used all $script:MaxTotalInvocations permitted reviewer invocations"
                }
                $reason = "The autodev-plan review gates are out of budget: $limitReason. " +
                "Further reviewer invocations are refused, so re-running the $targetGate gate " +
                "cannot succeed. Stop looping and escalate to the user now, per your escalation " +
                "protocol: say which gate is stuck, summarise its outstanding findings, point at " +
                "the plan file and the feedback log, and state plainly that this session did not " +
                "reach a clean 'all gates passed' state. ask_user is available again."

                Write-JsonResult @{ permissionDecision = 'deny'; permissionDecisionReason = $reason }
                exit 0
            }

            if ($phase -ne 'gating') { Write-JsonResult @{}; exit 0 }

            $nextGate = Get-NextGate -State $state
            $reason = "The autodev-plan review gates run without human interaction. " +
            "The $nextGate gate is still outstanding, so ask_user is unavailable. " +
            "Resolve reviewer feedback yourself using your best engineering judgement and record " +
            "the decision in the plan's 'Review notes' section. If you truly cannot proceed, keep " +
            "looping until the gate reaches its attempt limit, at which point escalation to the " +
            "user is unlocked automatically."

            Write-JsonResult @{ permissionDecision = 'deny'; permissionDecisionReason = $reason }
            exit 0
        }
    }

    Write-JsonResult @{}
    exit 0
}
catch {
    # Fail open. preToolUse is fail-closed on a non-zero exit, so never let an internal
    # error here deny a tool call or block a turn.
    try { Write-JsonResult @{} } catch { Write-Output '{}' }
    exit 0
}
