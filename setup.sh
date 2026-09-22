#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$ROOT/dist/Safari Chromium History Sync.app"
AGENT_APP_PATH="$ROOT/dist/SafariSyncAgent.app"
CHROME_ID=""
EDGE_ID=""
HOST_NAME="com.local.safari_history_sync"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="$2"
      AGENT_APP_PATH="$(dirname "$2")/SafariSyncAgent.app"
      shift 2
      ;;
    --chrome-id) CHROME_ID="$2"; shift 2 ;;
    --edge-id) EDGE_ID="$2"; shift 2 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 64 ;;
  esac
done

BRIDGE="$APP_PATH/Contents/MacOS/SafariSyncBridge"
if [[ ! -x "$BRIDGE" ]]; then
  printf 'Bridge not found: %s\nRun scripts/package-app.sh first.\n' "$BRIDGE" >&2
  exit 66
fi
if [[ ! -x "$AGENT_APP_PATH/Contents/MacOS/SafariSyncAgent" ]]; then
  printf 'Agent not found beside the Menu app: %s\n' "$AGENT_APP_PATH" >&2
  exit 66
fi

install_manifest() {
  local extension_id="$1"
  local host_dir="$2"
  if [[ -z "$extension_id" ]]; then return; fi
  if [[ ! "$extension_id" =~ ^[a-p]{32}$ ]]; then
    printf 'Invalid extension ID: %s\n' "$extension_id" >&2
    exit 64
  fi
  local parent
  parent="$(dirname "$host_dir")"
  if [[ ! -d "$parent" ]]; then return; fi
  mkdir -p "$host_dir"
  local escaped_bridge="${BRIDGE//\\/\\\\}"
  escaped_bridge="${escaped_bridge//\"/\\\"}"
  /usr/bin/printf '{\n  "name": "%s",\n  "description": "Safari history sync bridge",\n  "path": "%s",\n  "type": "stdio",\n  "allowed_origins": ["chrome-extension://%s/"]\n}\n' \
    "$HOST_NAME" "$escaped_bridge" "$extension_id" > "$host_dir/$HOST_NAME.json"
  printf 'Installed %s\n' "$host_dir/$HOST_NAME.json"
}

install_manifest "$CHROME_ID" "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
install_manifest "$EDGE_ID" "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"

if [[ -z "$CHROME_ID" && -z "$EDGE_ID" ]]; then
  printf 'Pass --chrome-id, --edge-id, or both.\n' >&2
  exit 64
fi

printf '%s\n' 'Open Safari Chromium History Sync, choose Enable Agent, then grant Full Disk Access only to the sibling SafariSyncAgent.app.'
