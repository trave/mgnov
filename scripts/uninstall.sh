#!/bin/bash
# Stops the agent, removes the LaunchAgent and app, restores the system key settings.
set -uo pipefail
LABEL="dev.trave.mgnov"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DST="$HOME/Applications/Mgnov.app"
STATE="$HOME/Library/Application Support/mgnov"
BACKUP="$STATE/system-settings-backup.json"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x mgnov 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$APP_DST"
/usr/bin/hidutil property --set '{"UserKeyMapping":[]}' >/dev/null 2>&1 || true

if [ -f "$BACKUP" ]; then
  fn_prev=$(python3 -c "import json; print(json.load(open('$BACKUP'))['AppleFnUsageType'])")
  hk_prev=$(python3 -c "import json; print(json.load(open('$BACKUP'))['hotkey60enabled'])")
  if [ "$fn_prev" = "unset" ]; then defaults delete com.apple.HIToolbox AppleFnUsageType 2>/dev/null || true; else defaults write com.apple.HIToolbox AppleFnUsageType -int "$fn_prev"; fi
  if [ "$hk_prev" != "false" ]; then
    defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 60 '{ enabled = 1; value = { parameters = (32, 49, 1048576); type = standard; }; }'
  fi
  /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u 2>/dev/null || true
  rm -f "$BACKUP"
  echo "→ system key settings restored"
fi
echo "→ mgnov removed (config and reports kept in $STATE). Remove Mgnov from Accessibility in System Settings if you like."
