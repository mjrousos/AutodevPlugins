#!/usr/bin/env bash
# Installs the autodev-factory extension where the Copilot CLI will actually find it.
#
# Copilot CLI discovers extensions in exactly two places: '<git root>/.github/extensions/' and the
# user's Copilot home ('~/.copilot/extensions/'). Whether an installed plugin can contribute one
# depends on the CLI version, so this script exists to make the outcome certain either way: it
# copies the extension into one of the two directories the CLI is guaranteed to scan.
#
# Usage:
#   plugins/autodev-factory/install.sh              install for the current user (~/.copilot/extensions)
#   plugins/autodev-factory/install.sh --project    install into this repository (.github/extensions)
#   plugins/autodev-factory/install.sh --uninstall  remove a user-scope install
#
# After installing, run /extensions in the CLI (or restart it) and the `autodev-factory` factory becomes
# available to run_factory.

set -u

MODE="user"
case "${1:-}" in
  "" | --user) MODE="user" ;;
  --project) MODE="project" ;;
  --uninstall) MODE="uninstall" ;;
  *)
    echo "FAIL unknown argument: $1" >&2
    echo "usage: plugins/autodev-factory/install.sh [--user | --project | --uninstall]" >&2
    exit 2
    ;;
esac

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/extensions/autodev-factory" >/dev/null 2>&1 && pwd)" || {
  echo "FAIL cannot locate the extension source directory" >&2
  exit 1
}

for required in extension.mjs prompts.generated.mjs; do
  if [ ! -f "$SOURCE_DIR/$required" ]; then
    echo "FAIL $SOURCE_DIR/$required is missing" >&2
    echo "     run scripts/sync-autodev-prompts.sh to generate the prompt bundle" >&2
    exit 1
  fi
done

copilot_home="${COPILOT_HOME:-$HOME/.copilot}"

if [ "$MODE" = "project" ]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "FAIL --project requires the working directory to be inside a git repository" >&2
    exit 1
  }
  TARGET_PARENT="$repo_root/.github/extensions"
else
  TARGET_PARENT="$copilot_home/extensions"
fi
TARGET_DIR="$TARGET_PARENT/autodev-factory"
LEGACY_DIR="$TARGET_PARENT/autodev"

remove_legacy_install() {
  [ -d "$LEGACY_DIR" ] || return
  if [ -f "$LEGACY_DIR/extension.mjs" ] &&
    [ -f "$LEGACY_DIR/prompts.generated.mjs" ] &&
    grep -Fq 'name: "autodev"' "$LEGACY_DIR/extension.mjs"; then
    rm -rf "$LEGACY_DIR" || {
      echo "FAIL cannot remove legacy autodev factory at $LEGACY_DIR" >&2
      exit 1
    }
    echo "removed legacy autodev factory -> $LEGACY_DIR"
  else
    echo "warning: $LEGACY_DIR exists but is not a recognized legacy autodev factory; leaving it unchanged" >&2
  fi
}

if [ "$MODE" = "uninstall" ]; then
  if [ -d "$TARGET_DIR" ]; then
    rm -rf "$TARGET_DIR" || {
      echo "FAIL cannot remove $TARGET_DIR" >&2
      exit 1
    }
    echo "removed $TARGET_DIR"
  else
    echo "nothing to remove at $TARGET_DIR"
  fi
  remove_legacy_install
  exit 0
fi

remove_legacy_install
mkdir -p "$TARGET_DIR" || {
  echo "FAIL cannot create $TARGET_DIR" >&2
  exit 1
}

# Copied file by file rather than as a directory so a stale file left by an older version is
# overwritten without silently inheriting anything else that happens to be sitting in the target.
for file in extension.mjs prompts.generated.mjs; do
  cp "$SOURCE_DIR/$file" "$TARGET_DIR/$file" || {
    echo "FAIL cannot write $TARGET_DIR/$file" >&2
    exit 1
  }
done

echo "installed autodev-factory extension -> $TARGET_DIR"
echo "run /extensions in Copilot CLI (or restart it), then invoke the 'autodev-factory' factory."
