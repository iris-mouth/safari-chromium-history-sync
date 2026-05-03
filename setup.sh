#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_NAME="com.local.safari_bookmark_sync"

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
echo "=== Safari Bookmark Sync Setup ==="
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
echo "  3. Click 'Load unpacked' → select: $SCRIPT_DIR"
echo "     (If already loaded, remove it first, then re-add)"
echo "  4. Copy the Extension ID shown under the extension name"
echo "     It looks like: abcdefghijklmnopqrstuvwxyz123456"
echo ""
read -rp "Paste your Extension ID here: " EXT_ID

EXT_ID="$(echo "$EXT_ID" | tr -d '[:space:]')"
if [[ -z "$EXT_ID" ]]; then
  echo "Error: Extension ID cannot be empty."
  exit 1
fi

if [[ ${#EXT_ID} -ne 32 ]]; then
  echo "Warning: Extension ID looks wrong (expected 32 chars, got ${#EXT_ID}). Continuing anyway."
fi

# Write the native messaging host manifest to every browser dir that exists
# (creates the dir if its parent — the browser app data — exists)
INSTALLED_COUNT=0
for HOST_DIR in "${HOST_DIRS[@]}"; do
  PARENT="$(dirname "$HOST_DIR")"
  if [[ ! -d "$PARENT" ]]; then
    continue  # Browser not installed
  fi
  mkdir -p "$HOST_DIR"
  cat > "$HOST_DIR/$HOST_NAME.json" <<EOF
{
  "name": "$HOST_NAME",
  "description": "Syncs Chrome bookmarks to Safari",
  "path": "$SCRIPT_DIR/run.sh",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
EOF
  echo "Installed: $HOST_DIR/$HOST_NAME.json"
  INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
done

echo ""
echo "Installed in $INSTALLED_COUNT browser(s)."
echo ""
echo "Step 2: Reload the extension"
echo "  Go to chrome://extensions and click the reload icon on 'Safari Bookmark Sync'"
echo ""
echo "Done! Bookmarks you add in your Chromium browser will now sync to Safari automatically."
echo "A backup of Bookmarks.plist is saved as Bookmarks.plist.bak before each write."
echo "Sync activity is logged to: $SCRIPT_DIR/sync.log"
