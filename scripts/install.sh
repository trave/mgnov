#!/bin/bash
# Installs Mgnov.app to ~/Applications, registers a KeepAlive LaunchAgent, and hands the
# trigger keys over from macOS to mgnov (backing up the previous values).
set -euo pipefail
cd "$(dirname "$0")/.."
APP_SRC="build/Mgnov.app"
APP_DST="$HOME/Applications/Mgnov.app"
LABEL="dev.trave.mgnov"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/Library/Application Support/mgnov"
BACKUP="$STATE/system-settings-backup.json"
CONFIG="$STATE/config.json"
UID_="$(id -u)"

[ -d "$APP_SRC" ] || { echo "build first: make"; exit 1; }
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$STATE"

echo "→ installing $APP_DST"
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
pkill -x mgnov 2>/dev/null || true
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

# --- back up and hand over the trigger keys --------------------------------------------
globe_on=$(python3 -c "import json,sys; c=json.load(open('$CONFIG')) if __import__('os').path.exists('$CONFIG') else {}; print(int(c.get('triggers',{}).get('globe',True)))" 2>/dev/null || echo 1)
ctrl_on=$(python3 -c "import json,sys; c=json.load(open('$CONFIG')) if __import__('os').path.exists('$CONFIG') else {}; print(int(c.get('triggers',{}).get('ctrlSpace',True)))" 2>/dev/null || echo 1)

if [ ! -f "$BACKUP" ]; then
  fn_prev=$(defaults read com.apple.HIToolbox AppleFnUsageType 2>/dev/null || echo "unset")
  hk60_prev=$(/usr/libexec/PlistBuddy -c "Print :AppleSymbolicHotKeys:60:enabled" ~/Library/Preferences/com.apple.symbolichotkeys.plist 2>/dev/null || echo "unset")
  printf '{"AppleFnUsageType": "%s", "hotkey60enabled": "%s"}\n' "$fn_prev" "$hk60_prev" > "$BACKUP"
  echo "→ previous system settings saved to $BACKUP"
fi

if [ "$globe_on" = "1" ]; then
  echo "→ 'Press 🌐 key to' = Do Nothing (mgnov handles the Globe tap itself)"
  defaults write com.apple.HIToolbox AppleFnUsageType -int 0
fi
if [ "$ctrl_on" = "1" ]; then
  echo "→ disabling system hotkey 60 (Select previous input source, Ctrl+Space)"
  defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 60 '{ enabled = 0; value = { parameters = (32, 49, 1048576); type = standard; }; }'
fi
/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u 2>/dev/null || true

# --- LaunchAgent ------------------------------------------------------------------------
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP_DST/Contents/MacOS/mgnov</string><string>agent</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$STATE/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$STATE/launchd.err.log</string>
</dict></plist>
PL
launchctl bootstrap "gui/$UID_" "$PLIST"
echo "→ LaunchAgent $LABEL loaded (KeepAlive: it is never idle-killed, unlike TextInputSwitcher)"

sleep 1
echo
echo "Now grant permissions ONCE to Mgnov.app (not to Terminal, not to Claude):"
echo "  System Settings → Privacy & Security → Accessibility → + → $APP_DST"
echo "  (if macOS also asks for Input Monitoring, add it there too)"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
echo
echo "Then check:  $APP_DST/Contents/MacOS/mgnov status"
