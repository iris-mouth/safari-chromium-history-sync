#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Safari Chromium History Sync.app"
AGENT_APP="$ROOT/dist/SafariSyncAgent.app"
LEGACY_APP="$ROOT/dist/Safari History Sync.app"
PKG="$ROOT/dist/Safari-Chromium-History-Sync.pkg"
IDENTITY="${CODESIGN_IDENTITY:--}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"
PACKAGE_IDENTIFIER="com.local.safari-history-sync.pkg"

if [[ -n "${NOTARY_PROFILE:-}" && ( "$IDENTITY" == "-" || -z "$INSTALLER_IDENTITY" ) ]]; then
  printf '%s\n' 'NOTARY_PROFILE requires CODESIGN_IDENTITY and INSTALLER_IDENTITY.' >&2
  exit 64
fi

PAYLOAD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/safari-sync-package.XXXXXX")"
cleanup() {
  rm -rf "$PAYLOAD_ROOT"
}
trap cleanup EXIT

if [[ -z "${SDKROOT:-}" \
  && "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" \
  && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
for product in SafariSyncMenu SafariSyncBridge SafariSyncAgent; do
  swift build --disable-sandbox --package-path "$ROOT" -c release --product "$product"
done
rm -rf "$APP" "$AGENT_APP" "$LEGACY_APP" "$PKG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ChromiumExtension" "$AGENT_APP/Contents/MacOS"
cp "$ROOT/.build/release/SafariSyncMenu" "$APP/Contents/MacOS/"
cp "$ROOT/.build/release/SafariSyncBridge" "$APP/Contents/MacOS/"
cp "$ROOT/.build/release/SafariSyncAgent" "$AGENT_APP/Contents/MacOS/"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Packaging/Agent-Info.plist" "$AGENT_APP/Contents/Info.plist"
cp "$ROOT/manifest.json" "$ROOT/service_worker.js" "$APP/Contents/Resources/ChromiumExtension/"
mkdir -p "$APP/Contents/Resources/ChromiumExtension/extension"
for source in protocol.js sync_controller.js chrome_generation_store.js worker.js visit_resolution.js; do
  cp "$ROOT/extension/$source" "$APP/Contents/Resources/ChromiumExtension/extension/"
done

SIGN_OPTIONS=(--force --options runtime --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then SIGN_OPTIONS+=(--timestamp); fi
codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/MacOS/SafariSyncBridge"
codesign "${SIGN_OPTIONS[@]}" "$AGENT_APP"
codesign "${SIGN_OPTIONS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$AGENT_APP"
codesign --verify --deep --strict --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
mkdir -p "$PAYLOAD_ROOT/Applications"
COPYFILE_DISABLE=1 cp -R -X "$APP" "$PAYLOAD_ROOT/Applications/"
COPYFILE_DISABLE=1 cp -R -X "$AGENT_APP" "$PAYLOAD_ROOT/Applications/"
find "$PAYLOAD_ROOT" -depth -name '._*' -delete
codesign --verify --deep --strict --verbose=2 "$PAYLOAD_ROOT/Applications/SafariSyncAgent.app"
codesign --verify --deep --strict --verbose=2 "$PAYLOAD_ROOT/Applications/Safari Chromium History Sync.app"

PKGBUILD_OPTIONS=(
  --root "$PAYLOAD_ROOT"
  --identifier "$PACKAGE_IDENTIFIER"
  --version "$VERSION"
  --install-location /
)
if [[ -n "$INSTALLER_IDENTITY" ]]; then
  PKGBUILD_OPTIONS+=(--sign "$INSTALLER_IDENTITY" --timestamp)
fi
COPYFILE_DISABLE=1 pkgbuild "${PKGBUILD_OPTIONS[@]}" "$PKG"
while IFS= read -r payload_path; do
  case "$payload_path" in
    # pkgbuild may encode the Applications directory's extended attributes as
    # an AppleDouble companion. It still represents metadata for that one root.
    .|./Applications|./._Applications|./Applications/*) ;;
    *) printf 'Unexpected PKG payload path: %s\n' "$payload_path" >&2; exit 65 ;;
  esac
done < <(pkgutil --payload-files "$PKG")
if [[ -n "$INSTALLER_IDENTITY" ]]; then
  pkgutil --check-signature "$PKG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi

printf 'Built %s\n' "$APP"
printf 'Built %s\n' "$AGENT_APP"
printf 'Built %s\n' "$PKG"
