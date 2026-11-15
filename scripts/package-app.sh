#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Safari Chromium History Sync.app"
AGENT_APP="$APP/Contents/Helpers/Safari Chromium History Sync Agent.app"
LEGACY_APP="$ROOT/dist/Safari History Sync.app"
PKG="$ROOT/dist/Safari-Chromium-History-Sync.pkg"
PACKAGE_IDENTIFIER="io.github.irismouth.safari-chromium-history-sync.pkg"

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
npm --prefix "$ROOT/web" run build
for product in SafariSyncMenu SafariSyncBridge SafariSyncAgent SafariSyncViewer; do
  swift build --disable-sandbox --package-path "$ROOT" -c release --product "$product"
done
rm -rf "$APP" "$AGENT_APP" "$LEGACY_APP" "$PKG"
VIEWER_APP="$APP/Contents/Helpers/Safari Chromium History Sync Viewer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ChromiumExtension" "$AGENT_APP/Contents/MacOS" "$AGENT_APP/Contents/Resources" "$VIEWER_APP/Contents/MacOS" "$VIEWER_APP/Contents/Resources/Web"
go build -trimpath -o "$APP/Contents/Helpers/HistoryGateway" "$ROOT/gateway/main.go"
cp "$ROOT/.build/release/SafariSyncViewer" "$VIEWER_APP/Contents/MacOS/"
cp "$ROOT/Packaging/Viewer-Info.plist" "$VIEWER_APP/Contents/Info.plist"
cp -R "$ROOT/web/dist/". "$VIEWER_APP/Contents/Resources/Web/"
cp "$ROOT/.build/release/SafariSyncMenu" "$APP/Contents/MacOS/"
cp "$ROOT/.build/release/SafariSyncBridge" "$APP/Contents/MacOS/"
cp "$ROOT/.build/release/SafariSyncAgent" "$AGENT_APP/Contents/MacOS/"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Packaging/Agent-Info.plist" "$AGENT_APP/Contents/Info.plist"
cp -R "$ROOT/Packaging/en.lproj" "$ROOT/Packaging/ja.lproj" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
mkdir -p "$AGENT_APP/Contents/Resources/ja.lproj"
cp "$ROOT/Packaging/ja.lproj/InfoPlist.strings" "$AGENT_APP/Contents/Resources/ja.lproj/"
cp "$ROOT/LICENSE" "$AGENT_APP/Contents/Resources/LICENSE"
cp "$ROOT/manifest.json" "$ROOT/service_worker.js" "$APP/Contents/Resources/ChromiumExtension/"
cp -R "$ROOT/_locales" "$APP/Contents/Resources/ChromiumExtension/"
mkdir -p "$APP/Contents/Resources/ChromiumExtension/extension"
for source in protocol.js sync_controller.js chrome_generation_store.js worker.js visit_resolution.js; do
  cp "$ROOT/extension/$source" "$APP/Contents/Resources/ChromiumExtension/extension/"
done

SIGN_OPTIONS=(--force --options runtime --sign -)
codesign "${SIGN_OPTIONS[@]}" --entitlements "$ROOT/Packaging/Viewer.entitlements" "$VIEWER_APP"
codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/Helpers/HistoryGateway"
codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/MacOS/SafariSyncBridge"
codesign "${SIGN_OPTIONS[@]}" --entitlements "$ROOT/Packaging/Agent.entitlements" "$AGENT_APP"
codesign "${SIGN_OPTIONS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$AGENT_APP"
codesign --verify --deep --strict --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
mkdir -p "$PAYLOAD_ROOT/Applications"
COPYFILE_DISABLE=1 cp -R -X "$APP" "$PAYLOAD_ROOT/Applications/"

find "$PAYLOAD_ROOT" -depth -name '._*' -delete

codesign --verify --deep --strict --verbose=2 "$PAYLOAD_ROOT/Applications/Safari Chromium History Sync.app"

COMPONENTS="$(mktemp "$PAYLOAD_ROOT/../history-components.XXXXXX")"
pkgbuild --analyze --root "$PAYLOAD_ROOT" "$COMPONENTS"
python3 - "$COMPONENTS" <<'PYCOMP'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    components = plistlib.load(f)
def pin(items):
    for item in items:
        item["BundleIsRelocatable"] = False
        pin(item.get("ChildBundles", []))
pin(components)
with open(path, "wb") as f:
    plistlib.dump(components, f)
PYCOMP
PKGBUILD_OPTIONS=(
  --component-plist "$COMPONENTS"
  --scripts "$ROOT/Packaging/Installer"
  --root "$PAYLOAD_ROOT"
  --identifier "$PACKAGE_IDENTIFIER"
  --version "$VERSION"
  --install-location /
)
COPYFILE_DISABLE=1 pkgbuild "${PKGBUILD_OPTIONS[@]}" "$PKG"
rm -f "$COMPONENTS"
while IFS= read -r payload_path; do
  case "$payload_path" in
    # macOS 27 pkgbuild exposes protected provenance xattrs as AppleDouble
    # companions here; pkgutil --expand-full restores them as xattrs, not files.
    .|./Applications|./._Applications|\
    './Applications/Safari Chromium History Sync.app'|\
    './Applications/._Safari Chromium History Sync.app'|\
    './Applications/Safari Chromium History Sync.app/'*) ;;
    *) printf 'Unexpected PKG payload path: %s\n' "$payload_path" >&2; exit 65 ;;
  esac
done < <(pkgutil --payload-files "$PKG")
printf 'Built %s\n' "$APP"
printf 'Built %s\n' "$AGENT_APP"
printf 'Built %s\n' "$PKG"
