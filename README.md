# mgnov

Instant, race-free keyboard layout switching for macOS. *mgnov* is short for «мгновенно».

Recent macOS versions switch the input source late (on key release, after the HUD), through a
helper process that the system keeps killing and relaunching, and with a race that sometimes
flips the switch back. The visible result: you press the switch key, start typing, and the first
letters come out in the old layout, or nothing switches at all. The analysis with measurements
is in [docs/ROOT-CAUSE.md](docs/ROOT-CAUSE.md).

mgnov is a small resident agent that:

- switches on **key down** of your input-source hotkey, with no HUD. It uses whatever macOS has
  under *Select the previous input source* and *Select next source in Input menu*
  (⌘Space, ⌃Space, ⌃⌥Space, …), or a key you set yourself;
- for 500 ms after each switch re-translates every keystroke with the **new** layout, so letters
  that race the switch still come out right;
- re-applies the switch if macOS reverts it within 700 ms;
- is kept alive by launchd, so there is never a cold start;
- records every switch (latency, the app in front, slow cases) for `mgnov stats`.

**Status: beta.** Tested on one Mac (Apple Silicon, macOS 26.5) with two layouts.
Requirements: macOS 14+, Xcode Command Line Tools (`xcode-select --install`). Keyboard layouts
(ABC, Russian, …) are the target; CJK input methods are switched but not re-translated.

## Beta testers: setup in 5 minutes

Nothing here needs `sudo`. Only `Mgnov.app` gets Accessibility; the CLI and your terminal get no
permissions.

**1. Build and sign.**

```bash
git clone https://github.com/trave/mgnov.git ~/work/mgnov && cd ~/work/mgnov
make cert      # once. Creates a self-signed signing identity "mgnov-dev" in your login keychain
make           # builds build/Mgnov.app
```

`make cert` asks for your login password twice: a macOS dialog when trusting the certificate,
then in the terminal to let `codesign` use the key. The identity exists so that the Accessibility
grant survives rebuilds (an ad-hoc signature changes with every build and macOS forgets the grant).

**2. Install the agent (keeps your system shortcuts).**

```bash
make install ARGS=--keep-system-keys
```

This copies the app to `~/Applications/Mgnov.app`, loads a `KeepAlive` LaunchAgent
(`dev.trave.mgnov`) and starts it. System Settings opens on the Accessibility pane: add
**Mgnov.app** from `~/Applications` and switch it on. That is the only permission. The agent
installs its event tap within 2 s of being trusted.

With `--keep-system-keys` macOS still has your shortcut too, but mgnov sits ahead of it in the
event chain and swallows the keys, so macOS never sees them. `make install` without the flag
also hands the keys over for good (disables the system input-source hotkeys and sets *Press 🌐
key to* = Do Nothing, with a backup that `make uninstall` restores). Not needed for the beta.

**3. Check.**

```bash
~/Applications/Mgnov.app/Contents/MacOS/mgnov status
```

Expect `accessibility trusted: 1   event tap: 1` and your shortcut on the `switch keys:` line.
Put the CLI on your PATH if you like: `ln -s ~/Applications/Mgnov.app/Contents/MacOS/mgnov ~/bin/mgnov`.

**4. Use the Mac as usual.** When switching feels slow or wrong, note the time and the app, and
send the output of:

```bash
mgnov stats          # latency, per-app table with SLOW / no-notification incidents, recent switches
mgnov log --last 40  # the agent's log around the incident
```

Uninstall at any time: `make uninstall` (removes the app, the LaunchAgent and the Caps Lock remap;
your config and reports stay in `~/Library/Application Support/mgnov`). Then remove Mgnov from the
Accessibility list in System Settings.

### If your shortcut is different

By default mgnov follows macOS: every **enabled** shortcut under System Settings → Keyboard →
Keyboard Shortcuts → Input Sources is a switch key. `mgnov status` lists them. To set the key
yourself:

```bash
mgnov hotkey "⌃⌥Space"          # or: cmd+space, ctrl+shift+f1, "⌘Space, ⌃⌥Space" (several)
mgnov hotkey system             # back to following macOS
```

Modifiers: ⌃/ctrl, ⌥/opt/alt, ⇧/shift, ⌘/cmd. Keys: space, return, tab, esc, delete, f1–f20,
letters, digits, punctuation. The setting lives in `config.json` as `"hotkey": "⌃⌥Space"`.

Not supported yet: switching with **Caps Lock** through the system option *Use Caps Lock to switch
to and from ABC* (mgnov has its own Caps Lock trigger, off by default, that remaps the key with
`hidutil`: `mgnov enable capsLock`, then restart the agent), and the **🌐 Globe** key unless you
hand it over with the full `make install` (then `mgnov enable globe`).

With three or more layouts mgnov cycles through all of them in system order, while macOS's
*previous input source* toggles between the last two. `"cycle": ["com.apple.keylayout.ABC",
"com.apple.keylayout.Russian"]` in the config limits the cycle (IDs from `mgnov sources`).

## Development run (no install)

```bash
make run             # builds, signs, launches build/Mgnov.app; Accessibility prompt on first run
build/mgnov status
```

Only one agent at a time: `make run` stops the installed one, `make install` stops the dev one.

### Measurements

```bash
build/mgnov measure  --mode mgnov  --trials 5   # synthetic hotkey presses handled by mgnov
build/mgnov selftest --mode mgnov  --trials 10  # type "qwerty" right after a switch into a real text view; wrong letters should be 0
build/mgnov measure  --mode system --trials 5   # baseline attempt: on macOS 26.5 the system switcher ignores synthetic presses (see docs)
```

`measure` posts the hotkey with different hold times and release timings and watches the selected
source at 1 ms resolution. `selftest` opens a small text view, switches, types, and counts letters
in the wrong layout. Both save JSON reports to `~/Library/Application Support/mgnov/`. Do not touch
the keyboard while they run.

## CLI

```
mgnov status | stats | sources | switch [ID] | hotkey [KEYS|system] | enable|disable TRIGGER | measure | selftest | log | quit
```

Triggers: `hotkey` (on), `globe` (off), `capsLock` (off). Config:
`~/Library/Application Support/mgnov/config.json`; the agent reads it at start, `mgnov hotkey` and
`enable`/`disable` write it.

The CLI needs no permissions. Only the agent (`Mgnov.app`) holds Accessibility; the CLI talks to
it over a local Unix socket.

## How it works

One binary. Run as `agent` it opens an active session-level `CGEventTap` placed at the head of
the chain, so it sees the trigger before the system hotkey handler does and swallows it. The
switch is a direct `TISSelectInputSource`. For the re-translation window it uses `UCKeyTranslate`
with the target layout's `uchr` data and `CGEventKeyboardSetUnicodeString`. A
`DistributedNotificationCenter` observer for `kTISNotifySelectedKeyboardInputSourceChanged` feeds
the latency stats and the revert watchdog.

## License

MIT
