#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/dist/Safari Chromium History Sync.app"
AGENT_APP="$ROOT/dist/SafariSyncAgent.app"
HOST="com.local.safari_history_sync.json"
FAILURES=0

if [[ ! -d "$APP" && -d "/Applications/Safari Chromium History Sync.app" ]]; then
  APP="/Applications/Safari Chromium History Sync.app"
  AGENT_APP="/Applications/SafariSyncAgent.app"
fi

ok() { printf 'OK   %s\n' "$1"; }
fail() { FAILURES=$((FAILURES + 1)); printf 'FAIL %s\n' "$1"; }

printf '%s\n\n' 'Safari Chromium History Sync Doctor'

if [[ "$(sw_vers -productVersion)" == "26.6.2" && "$(sw_vers -buildVersion)" == "25G83" ]]; then
  ok 'qualified macOS 26.6.2 (25G83)'
else
  fail 'macOS build is not in the qualification matrix'
fi

SAFARI_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/Safari.app/Contents/Info.plist 2>/dev/null)"
if [[ "$SAFARI_BUILD" == "21624.5.1.11.3" ]]; then
  ok "qualified Safari build $SAFARI_BUILD"
else
  fail "Safari build is not qualified: $SAFARI_BUILD"
fi

if [[ -d "$APP" ]] && codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  ok 'Menu app bundle signature verifies'
else
  fail 'built and signed Menu app bundle not found'
fi

if [[ -d "$AGENT_APP" ]] && codesign --verify --deep --strict "$AGENT_APP" >/dev/null 2>&1; then
  ok 'Agent app bundle signature verifies'
else
  fail 'built and signed Agent app bundle not found'
fi

for binary in SafariSyncMenu SafariSyncBridge; do
  if [[ -x "$APP/Contents/MacOS/$binary" ]]; then ok "$binary present"; else fail "$binary missing"; fi
done
if [[ -x "$AGENT_APP/Contents/MacOS/SafariSyncAgent" ]]; then
  ok 'SafariSyncAgent present'
else
  fail 'SafariSyncAgent missing'
fi

FOUND=0
for host_dir in \
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts" \
  "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"; do
  if [[ -f "$host_dir/$HOST" ]]; then
    FOUND=$((FOUND + 1))
    ok "native manifest: $host_dir/$HOST"
  fi
done
if [[ $FOUND -eq 0 ]]; then fail 'no Chrome Stable or Edge Stable native manifest'; fi

if pgrep -x SafariSyncAgent >/dev/null 2>&1; then
  ok 'FDA Agent is running'
else
  fail 'FDA Agent is not running'
fi

printf '\n%d failure(s)\n' "$FAILURES"
if [[ $FAILURES -gt 0 ]]; then exit 1; fi
