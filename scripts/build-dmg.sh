#!/bin/zsh

set -euo pipefail
setopt null_glob

usage() {
  cat <<'EOF'
Usage:
  scripts/build-dmg.sh [options]

Optional:
  --app PATH                    Existing .app bundle path (default: dist/QuotaBar.app)
  --output-dir PATH             Output directory (default: dist)
  --bundle-name VALUE           App bundle name without extension (default: QuotaBar)
  --volicon PATH                Optional .icns file for the DMG volume icon
  -h, --help                    Show this help text

Examples:
  scripts/build-dmg.sh
  scripts/build-dmg.sh --app dist/QuotaBar.app
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

APP_PATH="dist/QuotaBar.app"
OUTPUT_DIR="dist"
BUNDLE_NAME="QuotaBar"
VOLICON_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --bundle-name)
      BUNDLE_NAME="$2"
      shift 2
      ;;
    --volicon)
      VOLICON_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_command ditto
require_command create-dmg

APP_OUTPUT_DIR="$OUTPUT_DIR/$BUNDLE_NAME"
APP_OUTPUT_PATH="$APP_OUTPUT_DIR/$BUNDLE_NAME.app"
DMG_PATH="$OUTPUT_DIR/$BUNDLE_NAME.dmg"

mkdir -p "$OUTPUT_DIR"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  echo "Export a notarized .app into dist first, or pass --app /path/to/QuotaBar.app" >&2
  exit 1
fi

if [[ -z "$VOLICON_PATH" ]]; then
  for candidate in ./*.icns ./*Icon*.icns ./*icon*.icns; do
    if [[ -f "$candidate" ]]; then
      VOLICON_PATH="${candidate#./}"
      break
    fi
  done
fi

echo "==> Preparing exported app bundle"
rm -rf "$APP_OUTPUT_DIR"
mkdir -p "$APP_OUTPUT_DIR"
ditto "$APP_PATH" "$APP_OUTPUT_PATH"

echo "==> Creating DMG with create-dmg"
rm -f "$DMG_PATH"
create_dmg_args=(
  --volname "$BUNDLE_NAME"
  --window-pos 200 120
  --window-size 640 420
  --icon-size 128
  --icon "$BUNDLE_NAME.app" 170 200
  --hide-extension "$BUNDLE_NAME.app"
  --app-drop-link 470 200
)

if [[ -n "$VOLICON_PATH" ]]; then
  create_dmg_args+=(--volicon "$VOLICON_PATH")
fi

create-dmg \
  "${create_dmg_args[@]}" \
  "$DMG_PATH" \
  "$APP_OUTPUT_DIR"

echo
echo "Artifacts:"
echo "  App: $APP_OUTPUT_PATH"
echo "  DMG: $DMG_PATH"
