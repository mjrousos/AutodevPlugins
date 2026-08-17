#!/usr/bin/env bash
# Syncs the canonical OTLP emitter into every plugin that uses it.
#
# Plugins install as independent directories, so a shared repository-level folder would not ship
# with either plugin: each one needs its own physical copy of the emitter. Maintaining those
# copies by hand invites drift, so autodev-plan holds the single canonical source and this script
# propagates it. CI runs this in --check mode and fails on any diff.
#
# Usage:
#   scripts/sync-otel-emitter.sh          copy the canonical files into every target
#   scripts/sync-otel-emitter.sh --check  verify the copies match, changing nothing (exit 1 if not)

set -u

MODE="${1:-copy}"

case "$MODE" in
  copy | --check) ;;
  *)
    # Falling through to copy mode on an unrecognized argument would be dangerous: a typo such as
    # '--chek' in CI would silently overwrite the target copies and exit 0, so drift would stop
    # being detected without anyone noticing.
    echo "FAIL unknown argument: $MODE" >&2
    echo "usage: scripts/sync-otel-emitter.sh [--check]" >&2
    exit 2
    ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)" || {
  echo "FAIL cannot resolve repository root" >&2
  exit 1
}

SOURCE_DIR="$REPO_ROOT/plugins/autodev-plan/hooks/scripts"
# Arrays, expanded quoted below. A checkout path containing a space would otherwise be split by
# word splitting into several bogus target directories, and both copy and --check would then
# operate on paths that do not exist.
TARGET_DIRS=("$REPO_ROOT/plugins/autodev-implement/hooks/scripts")
FILES=("autodev-otel.ps1" "autodev-otel.sh")

status=0

for file in "${FILES[@]}"; do
  source_path="$SOURCE_DIR/$file"
  if [ ! -f "$source_path" ]; then
    echo "FAIL canonical file missing: $source_path" >&2
    status=1
    continue
  fi
  for target_dir in "${TARGET_DIRS[@]}"; do
    target_path="$target_dir/$file"
    if [ "$MODE" = "--check" ]; then
      if cmp -s "$source_path" "$target_path"; then
        echo "ok   $target_path"
      else
        echo "FAIL $target_path differs from $source_path" >&2
        echo "     run scripts/sync-otel-emitter.sh to update it" >&2
        status=1
      fi
    else
      mkdir -p "$target_dir" || { status=1; continue; }
      cp "$source_path" "$target_path" || { status=1; continue; }
      echo "copied $file -> $target_dir"
    fi
  done
done

exit $status
