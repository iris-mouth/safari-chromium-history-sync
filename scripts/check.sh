#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node --check "$ROOT/background.js"
node --check "$ROOT/service_worker.js"
node --check "$ROOT/popup.js"
node --check "$ROOT/options.js"

python3 - "$ROOT/safari_sync.py" <<'PY'
import ast
import sys

with open(sys.argv[1]) as f:
    ast.parse(f.read())
PY

echo "checks passed"
