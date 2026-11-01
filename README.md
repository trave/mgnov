# mgnov

Instant, race-free keyboard layout switching for macOS. *mgnov* is short for «мгновенно».

Recent macOS versions switch the input source late (on key release, after a HUD), through a
helper process that the system keeps killing and relaunching, and with a race that sometimes
flips the switch back. The visible result: you press the switch key, type, and the first letters
come out in the old layout, or nothing switches at all. The analysis with measurements is in
[docs/ROOT-CAUSE.md](docs/ROOT-CAUSE.md).

mgnov is a small resident agent that:

- switches on **key down** of your input-source hotkey (whatever macOS has under "Select the previous input source": ⌘Space, ⌃Space, …) or Caps Lock, and on a clean Globe tap, with no HUD;
- for 300 ms after each switch re-translates every keystroke with the **new** layout and puts
  the characters on the event, so letters that race the switch still come out right;
- re-applies the switch if macOS reverts it within 700 ms;
- is kept alive by launchd, so there is never a cold start;
- measures itself: `mgnov stats`, `mgnov measure`, `mgnov selftest`.

Requirements: macOS 14+, Xcode Command Line Tools. Keyboard layouts (ABC, Russian, …) are
the target; CJK input methods are switched but not re-translated.

## Build and try (no install)

```bash
make cert      # once: a self-signed signing identity so the Accessibility grant survives rebuilds
make run       # builds build/Mgnov.app and launches it; macOS shows the Accessibility prompt
```

Grant **Accessibility** to `Mgnov.app` in System Settings → Privacy & Security (and Input
Monitoring if asked). The agent installs its event tap as soon as it is trusted. Then:

```bash
build/mgnov status
```

Until you run `scripts/install.sh`, macOS still handles the keys too, so you get two switches
per press. Use the development run for measurements, then install.

## Measure before/after

```bash
build/mgnov measure  --mode mgnov  --trials 5   # synthetic hotkey presses handled by mgnov
build/mgnov selftest --mode mgnov  --trials 10  # type "qwerty" right after a switch into a real text view; wrong letters should be 0
build/mgnov measure  --mode system --trials 5   # baseline attempt: on macOS 26.5 the system switcher ignores synthetic presses (see docs)
```

`measure` posts Ctrl+Space with different hold times and release timings and watches the
selected source at 0.5 ms resolution. `selftest` opens a small text view, switches, types,
and counts letters in the wrong layout. Both save JSON reports to
`~/Library/Application Support/mgnov/`. Do not touch the keyboard while they run.

## Install

```bash
make install
```

Copies the app to `~/Applications`, loads a `KeepAlive` LaunchAgent, sets "Press 🌐 key to" to
Do Nothing and disables the Ctrl+Space system hotkey (previous values are backed up and
restored by `make uninstall`).

## CLI

```
mgnov status | stats | sources | switch [ID] | enable|disable TRIGGER | measure | selftest | log | quit
```

Triggers: `hotkey` (default on; the key is read from the system hotkey, override with `"hotkey": {"keyCode": 49, "flags": 1048576}` in the config), `globe` (default on), `capsLock` (off; remaps Caps Lock to
F18 through `hidutil` while the agent runs). Config: `~/Library/Application Support/mgnov/config.json`.

The CLI needs no permissions. Only the agent (`Mgnov.app`) holds Accessibility; the CLI talks
to it over a local Unix socket.

## How it works

One binary. Run as `agent` it opens an active session-level `CGEventTap` placed at the head
of the chain, so it sees the trigger before the system hotkey handler does and swallows it.
The switch is a direct `TISSelectInputSource`. For the re-translation window it uses
`UCKeyTranslate` with the target layout's `uchr` data and `CGEventKeyboardSetUnicodeString`.
A `DistributedNotificationCenter` observer for `kTISNotifySelectedKeyboardInputSourceChanged`
feeds the latency stats and the revert watchdog.

## License

MIT
