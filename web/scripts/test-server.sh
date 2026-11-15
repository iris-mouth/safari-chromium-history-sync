#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${HISTORY_WEB_TEST_DIR:?Playwright must provide an isolated fixture directory}"
python3 "$ROOT/web/scripts/browser-fixture.py" "$HISTORY_WEB_TEST_DIR/history.sqlite"
exec "${HISTORY_TEST_VIEWER_BINARY:-$ROOT/.build/debug/SafariSyncViewer}" --database "$HISTORY_WEB_TEST_DIR/history.sqlite" --assets "$ROOT/web/dist" --owner owner@example.test --port 18766
