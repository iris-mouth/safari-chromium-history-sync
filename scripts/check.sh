#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_TMP="$(mktemp -d)"
trap 'rm -rf "$CHECK_TMP"' EXIT

if [[ -z "${SDKROOT:-}" \
  && "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" \
  && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
export CLANG_MODULE_CACHE_PATH="$CHECK_TMP/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CHECK_TMP/swift-cache"

node --check "$ROOT/service_worker.js"
node --check "$ROOT/extension/protocol.js"
node --check "$ROOT/extension/sync_controller.js"
node --check "$ROOT/extension/chrome_generation_store.js"
node --check "$ROOT/extension/worker.js"
node --check "$ROOT/popup.js"
npm --prefix "$ROOT" test
swift run --disable-sandbox --package-path "$ROOT" --scratch-path "$CHECK_TMP/build" SafariSyncCoreIntegrationTests

echo "checks passed"
