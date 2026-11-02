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

KEEP_KEYS=0; [ "${1:-}" = "--keep-system-keys" ] && KEEP_KEYS=1
[ -d "$APP_SRC" ] || { echo "build first: make"; exit 1; }
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$STATE"

echo "→ installing $APP_DST"
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
pkill -x mgnov 2>/dev/null || true
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

# --- back up and hand over the trigger keys --------------------------------------------
globe_on=$(python3 -c "import json,sys; c=json.load(open('$CONFIG')) if __import__('os').path.exists('$CONFIG') else {}; print(int(c.get('triggers',{}).get('globe',False)))" 2>/dev/null || echo 0)
hotkey_on=$(python3 -c "import json,sys; c=json.load(open('$CONFIG')) if __import__('os').path.exists('$CONFIG') else {}; print(int(c.get('triggers',{}).get('hotkey',True)))" 2>/dev/null || echo 1)
HK=~/Library/Preferences/com.apple.symbolichotkeys.plist
# macOS has two input-source hotkeys: 60 "Select the previous input source" (default ⌃Space) and
# 61 "Select next source in Input menu" (default ⌃⌥Space). mgnov handles every enabled one.
hk_get() { /usr/libexec/PlistBuddy -c "Print :AppleSymbolicHotKeys:$1:$2" "$HK" 2>/dev/null || echo "$3"; }
hk_def() { case "$1:$2" in 60:2) echo 262144;; 61:2) echo 786432;; *:0) echo 32;; *:1) echo 49;; esac; }  # factory parameters

if [ "$KEEP_KEYS" = "1" ]; then
  echo "→ system key settings left untouched (--keep-system-keys)"
elif [ ! -f "$BACKUP" ]; then
  fn_prev=$(defaults read com.apple.HIToolbox AppleFnUsageType 2>/dev/null || echo "unset")
  json="{\"AppleFnUsageType\": \"$fn_prev\""
  for id in 60 61; do
    en=$(hk_get $id enabled unset)
    p0=$(hk_get $id value:parameters:0 $(hk_def $id 0)); p1=$(hk_get $id value:parameters:1 $(hk_def $id 1)); p2=$(hk_get $id value:parameters:2 $(hk_def $id 2))
    json="$json, \"hotkey${id}enabled\": \"$en\", \"hotkey${id}params\": [$p0, $p1, $p2]"
  done
  echo "$json}" > "$BACKUP"
  echo "→ previous system settings saved to $BACKUP"
fi

if [ "$KEEP_KEYS" = "0" ] && [ "$globe_on" = "1" ]; then
  echo "→ 'Press 🌐 key to' = Do Nothing (mgnov handles the Globe tap itself)"
  defaults write com.apple.HIToolbox AppleFnUsageType -int 0
fi
if [ "$KEEP_KEYS" = "0" ] && [ "$hotkey_on" = "1" ]; then
  for id in 60 61; do
    [ "$(hk_get $id enabled true)" = "false" ] && continue
    p0=$(hk_get $id value:parameters:0 $(hk_def $id 0)); p1=$(hk_get $id value:parameters:1 $(hk_def $id 1)); p2=$(hk_get $id value:parameters:2 $(hk_def $id 2))
    echo "→ disabling system hotkey $id (parameters $p0,$p1,$p2 kept; mgnov handles the key now)"
    defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add $id "{ enabled = 0; value = { parameters = ($p0, $p1, $p2); type = standard; }; }"
  done
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

sleep 1.5
if "$APP_DST/Contents/MacOS/mgnov" status 2>/dev/null | grep -q 'event tap: 1'; then
  echo "→ agent is running and trusted"
else
  echo
  echo "Now grant permissions ONCE to Mgnov.app (not to Terminal, not to Claude):"
  echo "  System Settings → Privacy & Security → Accessibility → + → $APP_DST"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
fi
echo "Check any time:  $APP_DST/Contents/MacOS/mgnov status"
