#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
VERSION="${1:-0.1.0}"
BUILD_NUMBER="${2:-1}"
ARCHITECTURE="$(uname -m)"
RELEASE_DIR="$PROJECT_DIR/build/release"
APP_DIR="$PROJECT_DIR/build/OpenPlan.app"
DMG_NAME="OpenPlan-$VERSION-macOS-$ARCHITECTURE.dmg"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
BACKGROUND_PATH="$RELEASE_DIR/dmg-background.png"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openplan-release.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
  rm -f "$BACKGROUND_PATH"
}
trap cleanup EXIT

for command in create-dmg rsvg-convert; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command" >&2
    echo "Install release tooling with: brew install create-dmg librsvg" >&2
    exit 1
  fi
done

mkdir -p "$RELEASE_DIR"

OPENPLAN_VERSION="$VERSION" \
  OPENPLAN_BUILD_NUMBER="$BUILD_NUMBER" \
  "$PROJECT_DIR/scripts/bundle.sh" release

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
ditto "$APP_DIR" "$STAGING_DIR/OpenPlan.app"

rsvg-convert \
  -w 660 \
  -h 400 \
  "$PROJECT_DIR/assets/installer/dmg-background.svg" \
  -o "$BACKGROUND_PATH"

rm -f "$DMG_PATH" "$CHECKSUM_PATH"

create-dmg \
  --volname "OpenPlan $VERSION" \
  --volicon "$APP_DIR/Contents/Resources/AppIcon.icns" \
  --background "$BACKGROUND_PATH" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --text-size 13 \
  --icon-size 112 \
  --icon "OpenPlan.app" 170 192 \
  --hide-extension "OpenPlan.app" \
  --app-drop-link 490 192 \
  --format UDZO \
  --no-internet-enable \
  "$DMG_PATH" \
  "$STAGING_DIR"

(
  cd "$RELEASE_DIR"
  shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
)

echo "$DMG_PATH"
echo "$CHECKSUM_PATH"
