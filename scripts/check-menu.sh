#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MENU_CHECK_TMP="$(mktemp -d)"
trap 'rm -rf "$MENU_CHECK_TMP"' EXIT
MENU_CHECK_SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
SWIFT_OPTIONS=(-sdk "$MENU_CHECK_SDK" -module-cache-path "$MENU_CHECK_TMP/cache" -I "$ROOT/Sources/CSQLite" -I "$ROOT/Sources/CUnicode")

swiftc "${SWIFT_OPTIONS[@]}" -parse-as-library -whole-module-optimization \
  -emit-module -emit-object -module-name HistoryViewCore \
  -emit-module-path "$MENU_CHECK_TMP/HistoryViewCore.swiftmodule" \
  "$ROOT"/Sources/HistoryViewCore/*.swift -o "$MENU_CHECK_TMP/HistoryViewCore.o"
SWIFT_OPTIONS+=(-I "$MENU_CHECK_TMP")

# The actual controllers run against in-memory replies. Do not execute the app's
# entry point: it launches the installed Agent and can access real user state.
awk '/^@main$/ { exit } { print }' "$ROOT/Sources/SafariSyncMenu/SafariSyncMenuApp.swift" > "$MENU_CHECK_TMP/MenuDelegate.swift"
swiftc "${SWIFT_OPTIONS[@]}" -parse-as-library -whole-module-optimization \
  -emit-module -emit-object -module-name SafariSyncCore \
  -emit-module-path "$MENU_CHECK_TMP/SafariSyncCore.swiftmodule" \
  "$ROOT"/Sources/SafariSyncCore/*.swift -o "$MENU_CHECK_TMP/SafariSyncCore.o"
swiftc "${SWIFT_OPTIONS[@]}" -parse-as-library -I "$MENU_CHECK_TMP" \
  "$MENU_CHECK_TMP/HistoryViewCore.o" "$MENU_CHECK_TMP/SafariSyncCore.o" "$MENU_CHECK_TMP/MenuDelegate.swift" \
  "$ROOT/Sources/SafariSyncMenu/SetupCoordinator.swift" \
  "$ROOT/Sources/SafariSyncMenu/CollectionSettings.swift" \
  "$ROOT/Sources/SafariSyncMenu/LoginItemRegistration.swift" \
  "$ROOT/Sources/SafariSyncMenu/SyncStatusWindow.swift" \
  "$ROOT/Sources/SafariSyncMenu/CloudDiagnosticsWindow.swift" \
  "$ROOT/tests/menu_presentation.swift" -o "$MENU_CHECK_TMP/MenuPresentationTests"
"$MENU_CHECK_TMP/MenuPresentationTests"
