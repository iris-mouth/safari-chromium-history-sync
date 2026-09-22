#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Safari History Sync.app"
AGENT_APP="$ROOT/dist/SafariSyncAgent.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ -z "${SDKROOT:-}" \
  && "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" \
  && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swift build --package-path "$ROOT" -c release
rm -rf "$APP" "$AGENT_APP"
mkdir -p "$APP/Contents/MacOS" "$AGENT_APP/Contents/MacOS"
cp "$ROOT/.build/release/SafariSyncMenu" "$APP/Contents/MacOS/"
cp "$ROOT/.build/release/SafariSyncBridge" "$APP/Contents/MacOS/"
cp "$ROOT/.build/release/SafariSyncAgent" "$AGENT_APP/Contents/MacOS/"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Packaging/Agent-Info.plist" "$AGENT_APP/Contents/Info.plist"

SIGN_OPTIONS=(--force --options runtime --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then SIGN_OPTIONS+=(--timestamp); fi
codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/MacOS/SafariSyncBridge"
codesign "${SIGN_OPTIONS[@]}" "$AGENT_APP"
codesign "${SIGN_OPTIONS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$AGENT_APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP" "$ROOT/dist/Safari-History-Sync.zip"
  xcrun notarytool submit "$ROOT/dist/Safari-History-Sync.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  ditto -c -k --keepParent "$AGENT_APP" "$ROOT/dist/SafariSyncAgent.zip"
  xcrun notarytool submit "$ROOT/dist/SafariSyncAgent.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$AGENT_APP"
fi

printf 'Built %s\n' "$APP"
printf 'Built %s\n' "$AGENT_APP"
