#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_NAME="com.local.safari_bookmark_sync"
STATE_DIR="${SAFARI_SYNC_STATE_DIR:-$HOME/Library/Application Support/Safari Sync}"

# Install to all Chromium-family browsers found on this system
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

# Make scripts executable
chmod +x "$SCRIPT_DIR/safari_sync.py" "$SCRIPT_DIR/run.sh"

# Show current state
echo ""
echo "=== Safari Sync Setup ==="
echo ""

CURRENT_ID=""
for d in "${HOST_DIRS[@]}"; do
  m="$d/$HOST_NAME.json"
  if [[ -f "$m" ]]; then
    CURRENT_ID=$(python3 -c "import json; d=json.load(open('$m')); print(d['allowed_origins'][0].split('//')[1].rstrip('/'))" 2>/dev/null || true)
    [[ -n "$CURRENT_ID" ]] && echo "Existing manifest at: $d (ID: $CURRENT_ID)"
  fi
done

echo ""
echo "Step 1: Load (or reload) the extension in your Chromium browser"
echo "  1. Open chrome://extensions"
echo "  2. Enable 'Developer mode' (top right toggle)"
echo "  3. Click 'Load unpacked' and select: $SCRIPT_DIR"
echo "     (If already loaded, click the reload button after setup)"
echo "  4. Copy the Extension ID shown under the extension name"
echo "     It looks like: abcdefghijklmnopqrstuvwxyz123456"
echo ""
echo "If you load this extension in multiple Chromium browsers and they show"
echo "different extension IDs, paste all IDs separated by spaces or commas."
echo ""
read -rp "Paste your Extension ID(s) here: " EXT_ID_INPUT

IFS=$' \t\n,' read -r -a EXT_IDS <<< "$EXT_ID_INPUT"
CLEAN_IDS=()
for EXT_ID in "${EXT_IDS[@]}"; do
  EXT_ID="$(echo "$EXT_ID" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  [[ -z "$EXT_ID" ]] && continue
  CLEAN_IDS+=("$EXT_ID")
done

if [[ ${#CLEAN_IDS[@]} -eq 0 ]]; then
  echo "Error: at least one Extension ID is required."
  exit 1
fi

for EXT_ID in "${CLEAN_IDS[@]}"; do
  if [[ ! "$EXT_ID" =~ ^[a-p]{32}$ ]]; then
    echo "Warning: '$EXT_ID' does not look like a Chromium extension ID."
  fi
done

# Write the native messaging host manifest to every browser dir that exists
# (creates the dir if its parent, the browser app data directory, exists)
INSTALLED_COUNT=0
for HOST_DIR in "${HOST_DIRS[@]}"; do
  PARENT="$(dirname "$HOST_DIR")"
  if [[ ! -d "$PARENT" ]]; then
    continue  # Browser not installed
  fi
  mkdir -p "$HOST_DIR"
  python3 - "$HOST_DIR/$HOST_NAME.json" "$HOST_NAME" "$SCRIPT_DIR/run.sh" "${CLEAN_IDS[@]}" <<'PY'
import json
import sys

path, host_name, run_path, *extension_ids = sys.argv[1:]
manifest = {
    "name": host_name,
    "description": "Sync Safari bookmarks and history with Chromium browsers",
    "path": run_path,
    "type": "stdio",
    "allowed_origins": [
        f"chrome-extension://{extension_id}/" for extension_id in extension_ids
    ],
}
with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
  echo "Installed: $HOST_DIR/$HOST_NAME.json"
  INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
done

echo ""
echo "Installed in $INSTALLED_COUNT browser(s)."
echo ""
echo "Step 2: Reload the extension"
echo "  Go to chrome://extensions and click the reload icon on 'Safari Sync'"
echo ""
echo "Done! Bookmarks and history from your Chromium browser will now sync to Safari automatically."
echo "Runtime state, logs, and Safari bookmark backups are stored in:"
echo "  $STATE_DIR"
