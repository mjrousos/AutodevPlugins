#!/usr/bin/env bash
# Generates the autodev factory's prompt bundle from the canonical agent definitions.
#
# The `autodev` factory cannot delegate to the plugin agents the way the `autodev-plan` and
# `autodev-implement` orchestrators do: a factory spawns subagents through `ctx.agent(prompt)`,
# which has no `agent_type`, so a factory subagent only ever sees the built-in agents. The
# reviewer and worker instructions therefore have to travel *in the prompt*.
#
# Rather than fork ten large instruction documents, this script lifts each agent's body straight
# out of its canonical `.agent.md` and emits a single generated ES module the extension imports.
# The model recorded in each agent's frontmatter comes along with it, so a factory subagent runs
# on the same model the plugin agent would have. CI runs this in --check mode and fails on drift,
# which is what keeps the factory honest when someone edits a reviewer.
#
# Usage:
#   scripts/sync-autodev-prompts.sh          regenerate the bundle
#   scripts/sync-autodev-prompts.sh --check  verify the bundle is current, changing nothing

set -u

MODE="${1:-generate}"

case "$MODE" in
  generate | --check) ;;
  *)
    # Falling through to generate mode on an unrecognized argument would be dangerous: a typo
    # such as '--chek' in CI would silently rewrite the bundle and exit 0, so drift would stop
    # being detected without anyone noticing.
    echo "FAIL unknown argument: $MODE" >&2
    echo "usage: scripts/sync-autodev-prompts.sh [--check]" >&2
    exit 2
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL jq is required" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)" || {
  echo "FAIL cannot resolve repository root" >&2
  exit 1
}

OUTPUT_REL="plugins/autodev/extensions/autodev/prompts.generated.mjs"
OUTPUT_PATH="$REPO_ROOT/$OUTPUT_REL"

# The agents the factory impersonates, in workflow order. Every one of these is a worker or a
# reviewer; the two orchestrator agents are deliberately absent, because orchestration is exactly
# the part the factory replaces with code.
SOURCE_FILES=(
  "plugins/autodev-plan/agents/autodev-architecture-review.agent.md"
  "plugins/autodev-plan/agents/autodev-security-review.agent.md"
  "plugins/autodev-plan/agents/autodev-privacy-review.agent.md"
  "plugins/autodev-implement/agents/autodev-tasking.agent.md"
  "plugins/autodev-implement/agents/autodev-implementation.agent.md"
  "plugins/autodev-implement/agents/autodev-code-review.agent.md"
  "plugins/autodev-implement/agents/autodev-code-fix.agent.md"
  "plugins/autodev-implement/agents/autodev-code-security-review.agent.md"
  "plugins/autodev-implement/agents/autodev-code-privacy-review.agent.md"
)

# The plan document structure lives in the planning orchestrator rather than in an agent of its
# own, because in the plugin workflow the orchestrator writes the plan itself. The factory
# delegates drafting to a subagent, so it needs the template as a standalone string.
PLAN_TEMPLATE_SOURCE="plugins/autodev-plan/agents/autodev-plan.agent.md"
PLAN_TEMPLATE_HEADING="## Plan document"

WORK_DIR="$(mktemp -d)" || {
  echo "FAIL cannot create temporary directory" >&2
  exit 1
}
trap 'rm -rf "$WORK_DIR"' EXIT

# Every reader strips CR. The repository only pins LF for '*.sh', so a Windows checkout hands us
# CRLF markdown; without this the bundle generated on Windows would differ byte-for-byte from the
# one generated in CI and --check would fail for everybody.
strip_cr() {
  tr -d '\r' < "$1"
}

frontmatter_value() {
  # $1 = file, $2 = key. Reads only the leading '---' fenced frontmatter block.
  strip_cr "$1" | awk -v key="$2" '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { exit }
    inside {
      prefix = key ":"
      if (index($0, prefix) == 1) {
        value = substr($0, length(prefix) + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", value)
        gsub(/^"|"$/, "", value)
        print value
        exit
      }
    }
  '
}

agent_body() {
  # Everything after the frontmatter block, with leading blank lines removed.
  strip_cr "$1" | awk '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { inside = 0; started = 1; next }
    started {
      if (!emitted && $0 ~ /^[ \t]*$/) next
      emitted = 1
      print
    }
    !inside && !started && NR == 1 { print }
  '
}

fenced_block_after_heading() {
  # $1 = file, $2 = heading. Emits the first fenced code block following that heading.
  strip_cr "$1" | awk -v heading="$2" '
    $0 == heading { seen = 1; next }
    seen && !inblock && /^```/ { inblock = 1; next }
    inblock && /^```/ { exit }
    inblock { print }
  '
}

status=0
entries_file="$WORK_DIR/entries.jsonl"
: > "$entries_file"

for rel in "${SOURCE_FILES[@]}"; do
  source_path="$REPO_ROOT/$rel"
  if [ ! -f "$source_path" ]; then
    echo "FAIL canonical agent missing: $rel" >&2
    status=1
    continue
  fi

  name="$(frontmatter_value "$source_path" "name")"
  model="$(frontmatter_value "$source_path" "model")"
  description="$(frontmatter_value "$source_path" "description")"

  if [ -z "$name" ]; then
    echo "FAIL $rel has no 'name' in its frontmatter" >&2
    status=1
    continue
  fi

  body_file="$WORK_DIR/$name.body"
  agent_body "$source_path" > "$body_file"
  if [ ! -s "$body_file" ]; then
    echo "FAIL $rel has an empty body" >&2
    status=1
    continue
  fi

  jq -n -c \
    --arg name "$name" \
    --arg model "$model" \
    --arg description "$description" \
    --arg source "$rel" \
    --rawfile body "$body_file" \
    '{key: $name, value: {name: $name, model: $model, description: $description, source: $source, body: $body}}' \
    >> "$entries_file" || {
    echo "FAIL could not encode $rel" >&2
    status=1
  }
done

plan_template_path="$REPO_ROOT/$PLAN_TEMPLATE_SOURCE"
plan_template_file="$WORK_DIR/plan-template.md"
if [ ! -f "$plan_template_path" ]; then
  echo "FAIL canonical planning orchestrator missing: $PLAN_TEMPLATE_SOURCE" >&2
  status=1
  : > "$plan_template_file"
else
  fenced_block_after_heading "$plan_template_path" "$PLAN_TEMPLATE_HEADING" > "$plan_template_file"
  if [ ! -s "$plan_template_file" ]; then
    echo "FAIL no fenced template found under '$PLAN_TEMPLATE_HEADING' in $PLAN_TEMPLATE_SOURCE" >&2
    status=1
  fi
fi

if [ "$status" -ne 0 ]; then
  echo "FAIL refusing to write a partial bundle" >&2
  exit "$status"
fi

prompts_json="$WORK_DIR/prompts.json"
jq -s 'from_entries' "$entries_file" > "$prompts_json" || {
  echo "FAIL could not assemble the prompt bundle" >&2
  exit 1
}

sources_json="$WORK_DIR/sources.json"
printf '%s\n' "${SOURCE_FILES[@]}" "$PLAN_TEMPLATE_SOURCE" | jq -R . | jq -s . > "$sources_json" || {
  echo "FAIL could not assemble the source list" >&2
  exit 1
}

generated="$WORK_DIR/prompts.generated.mjs"
{
  echo "// Generated by scripts/sync-autodev-prompts.sh — do not edit by hand."
  echo "//"
  echo "// Each entry is the body of a canonical '.agent.md' from autodev-plan or autodev-implement,"
  echo "// together with the model its frontmatter declares. The autodev factory spawns subagents"
  echo "// through ctx.agent(prompt), which takes no agent_type, so these instructions have to be"
  echo "// carried in the prompt itself. Edit the source agent and re-run the script instead."
  echo ""
  printf 'export const PROMPTS = Object.freeze('
  cat "$prompts_json"
  echo ");"
  echo ""
  printf 'export const PLAN_TEMPLATE = '
  jq -R -s . < "$plan_template_file"
  echo ";"
  echo ""
  printf 'export const GENERATED_FROM = Object.freeze('
  cat "$sources_json"
  echo ");"
} > "$generated"

if [ "$MODE" = "--check" ]; then
  if [ ! -f "$OUTPUT_PATH" ]; then
    echo "FAIL $OUTPUT_REL is missing" >&2
    echo "     run scripts/sync-autodev-prompts.sh to create it" >&2
    exit 1
  fi
  # The committed file is compared with CR stripped so a Windows checkout that materializes it
  # as CRLF does not read as drift.
  committed="$WORK_DIR/committed.mjs"
  strip_cr "$OUTPUT_PATH" > "$committed"
  if cmp -s "$generated" "$committed"; then
    echo "ok   $OUTPUT_REL"
    exit 0
  fi
  echo "FAIL $OUTPUT_REL is out of date with the canonical agent definitions" >&2
  echo "     run scripts/sync-autodev-prompts.sh to update it" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")" || {
  echo "FAIL cannot create $(dirname "$OUTPUT_REL")" >&2
  exit 1
}
cp "$generated" "$OUTPUT_PATH" || {
  echo "FAIL cannot write $OUTPUT_REL" >&2
  exit 1
}
echo "generated $OUTPUT_REL from ${#SOURCE_FILES[@]} agents"
