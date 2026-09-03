#!/usr/bin/env bash
# Syncs the canonical OTLP emitter into every plugin that uses it.
#
# Plugins install as independent directories, so a shared repository-level folder would not ship
# with either plugin: each one needs its own physical copy of the emitter. Maintaining those
# copies by hand invites drift, so autodev holds the single canonical source and this script
# would propagate it to additional plugins if any are added. In the consolidated layout there are
# currently no target copies; CI still runs --check to verify the canonical emitter files exist and
# remain readable.
#
# Usage:
#   scripts/sync-otel-emitter.sh          copy the canonical files into every target (no-op today)
#   scripts/sync-otel-emitter.sh --check  verify canonical files exist and target copies match

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

SOURCE_DIR="$REPO_ROOT/plugins/autodev/hooks/scripts"
# Reserved for future plugin-specific emitter copies. Left empty in the consolidated two-plugin
# layout, where autodev is both source and destination.
TARGET_DIRS=()
FILES=("autodev-otel.ps1" "autodev-otel.sh")

status=0
target_count="${#TARGET_DIRS[@]}"

for file in "${FILES[@]}"; do
  source_path="$SOURCE_DIR/$file"
  if [ ! -f "$source_path" ]; then
    echo "FAIL canonical file missing: $source_path" >&2
    status=1
    continue
  fi
  if [ "$target_count" -eq 0 ]; then
    if [ "$MODE" = "--check" ]; then
      echo "ok   $source_path (canonical; no target copies configured)"
    fi
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
