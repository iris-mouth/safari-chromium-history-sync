#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_NAME="com.local.safari_bookmark_sync"
BOOKMARKS_PATH="${SAFARI_BOOKMARKS_PATH:-$HOME/Library/Safari/Bookmarks.plist}"
HISTORY_PATH="${SAFARI_HISTORY_PATH:-$HOME/Library/Safari/History.db}"
STATE_DIR="${SAFARI_SYNC_STATE_DIR:-$HOME/Library/Application Support/Safari Sync}"

HOST_DIRS=(
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
  "$HOME/Library/Application Support/Google/Chrome Beta/NativeMessagingHosts"
  "$HOME/Library/Application Support/Google/Chrome Canary/NativeMessagingHosts"
  "$HOME/Library/Application Support/Chromium/NativeMessagingHosts"
  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
  "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
  "$HOME/Library/Application Support/Arc/User Data/NativeMessagingHosts"
  "$HOME/Library/Application Support/net.imput.helium/NativeMessagingHosts"
)

FAILURES=0
WARNINGS=0

ok() {
  printf "OK   %s\n" "$1"
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  printf "WARN %s\n" "$1"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf "FAIL %s\n" "$1"
}

json_key() {
  python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(data.get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null
}

json_allowed_origins() {
  python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1])).get("allowed_origins") or []))' "$1" 2>/dev/null
}

echo "Safari Sync Doctor"
echo ""

if command -v python3 >/dev/null 2>&1; then
  ok "python3 found: $(command -v python3)"
else
  fail "python3 not found"
fi

if command -v plutil >/dev/null 2>&1; then
  ok "plutil found"
else
  fail "plutil not found"
fi

if command -v sqlite3 >/dev/null 2>&1; then
  ok "sqlite3 found"
else
  fail "sqlite3 not found"
fi

if [[ -x "$SCRIPT_DIR/safari_sync.py" ]]; then
  ok "safari_sync.py is executable"
else
  fail "safari_sync.py is not executable"
fi

if [[ -x "$SCRIPT_DIR/run.sh" ]]; then
  ok "run.sh is executable"
else
  fail "run.sh is not executable"
fi

if [[ -r "$BOOKMARKS_PATH" ]]; then
  ok "Safari bookmarks are readable"
  if plutil -lint "$BOOKMARKS_PATH" >/dev/null 2>&1; then
    ok "Safari bookmarks plist is valid"
  else
    fail "Safari bookmarks plist failed plutil validation"
  fi
else
  fail "Safari bookmarks are not readable: $BOOKMARKS_PATH"
fi

if [[ -r "$HISTORY_PATH" ]]; then
  ok "Safari history is readable"
  if sqlite3 "$HISTORY_PATH" 'PRAGMA quick_check;' >/dev/null 2>&1; then
    ok "Safari history database opens"
  else
    fail "Safari history database did not open cleanly"
  fi
else
  fail "Safari history is not readable: $HISTORY_PATH"
fi

if [[ -d "$STATE_DIR" || ! -e "$STATE_DIR" ]]; then
  if mkdir -p "$STATE_DIR" >/dev/null 2>&1 && [[ -w "$STATE_DIR" ]]; then
    ok "runtime directory is writable: $STATE_DIR"
  else
    fail "runtime directory is not writable: $STATE_DIR"
  fi
else
  fail "runtime path exists but is not a directory: $STATE_DIR"
fi

if [[ -d "$SCRIPT_DIR/__pycache__" ]]; then
  warn "__pycache__ exists in the extension root; Chromium may reject the unpacked extension"
else
  ok "no __pycache__ in extension root"
fi

if command -v node >/dev/null 2>&1; then
  for script_name in background.js service_worker.js; do
    if node --check "$SCRIPT_DIR/$script_name" >/dev/null 2>&1; then
      ok "$script_name passes node syntax check"
    else
      fail "$script_name failed node syntax check"
    fi
  done
else
  warn "node not found; skipped JavaScript syntax checks"
fi

FOUND_MANIFESTS=0
for host_dir in "${HOST_DIRS[@]}"; do
  manifest="$host_dir/$HOST_NAME.json"
  if [[ ! -f "$manifest" ]]; then
    continue
  fi
  FOUND_MANIFESTS=$((FOUND_MANIFESTS + 1))
  ok "native manifest found: $manifest"

  host_path="$(json_key "$manifest" "path")"
  if [[ "$host_path" == "$SCRIPT_DIR/run.sh" ]]; then
    ok "manifest path matches this checkout"
  else
    warn "manifest path points to '$host_path'"
  fi

  origin_count=0
  while IFS= read -r allowed_origin; do
    [[ -z "$allowed_origin" ]] && continue
    origin_count=$((origin_count + 1))
    if [[ "$allowed_origin" =~ ^chrome-extension://[a-p]{32}/$ ]]; then
      ok "allowed origin looks like an extension ID: $allowed_origin"
    else
      warn "allowed origin does not look like a Chromium extension ID: $allowed_origin"
    fi
  done < <(json_allowed_origins "$manifest")
  if [[ "$origin_count" -eq 0 ]]; then
    warn "manifest has no allowed_origins"
  fi
done

if [[ "$FOUND_MANIFESTS" -eq 0 ]]; then
  fail "no native messaging manifest found; run ./setup.sh"
fi

echo ""
if [[ "$FAILURES" -gt 0 ]]; then
  echo "Doctor found $FAILURES failure(s) and $WARNINGS warning(s)."
  exit 1
fi

echo "Doctor found no failures and $WARNINGS warning(s)."
