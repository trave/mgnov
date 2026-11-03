# Why layout switching on macOS lags, drops letters, or does not switch

Facts measured on a MacBook with macOS 26.5 (25F71), a Bluetooth Magic Keyboard, and two
keyboard layouts (ABC, Russian), on 2026-11-01, plus what other people have found.
Three independent causes stack on top of each other.

## 1. The switcher is an on-demand helper that macOS keeps killing

The Globe key and the input-source hotkeys are not handled in the app you type in. They go
through `TextInputSwitcher.app`, a separate helper that launchd starts on demand and whose
LaunchAgent declares `EnablePressuredExit = true`. The kernel's jetsam idle-exit kills it
after a few minutes of not switching.

```
$ launchctl print gui/$UID/com.apple.TextInputSwitcher | grep -E 'runs|last exit'
	runs = 1348
	last exit reason = JETSAM_REASON_MEMORY_IDLE_EXIT
$ uptime
17:36  up 173 days
$ launchctl print gui/$UID/com.apple.TextInputMenuAgent | grep runs
	runs = 1
```

1348 cold starts in 173 days is about 8 a day. Every one of them is a key press that went
into launching an AppKit application instead of switching the layout. The author of
globe-switch counted 53 relaunches in three days with 10 GB of memory free, so this is not a
memory-pressure situation; it is the idle-exit policy.

## 2. The switch is committed on key *release*, after the HUD

Since Sonoma, holding the trigger shows a picker HUD, so the handler has to wait for key-up
to know whether you meant a tap or a hold. The input source changes only on release, after
the HUD/indicator animation. Someone measured this on macOS 27.0.1 and ruled out key repeat
and the cursor indicator as the cause. The cursor-side language indicator
(`CursorUIViewService`) adds its own wait: since Sonoma the change lands only once that
bubble is gone (`TSMLanguageIndicatorEnabled` hides it).

A fast typist releases the trigger and hits the next letter within 50–100 ms. The app
learns about the switch asynchronously (a TSM message), so the first letters are translated
with the old layout. That is the "first letters in the old layout" symptom.

## 3. A race in the hotkey handler reverts the switch (FB24297598)

Reported on macOS 26.5.2 with a synthetic-event reproducer: when Ctrl and Space are released
at the same instant, the handler switches and then switches *back* 100–500 ms later.

| Space held | release | persisted | reverted |
|---|---|---|---|
| 60 ms | simultaneous | 7 | 8 |
| 150 ms | simultaneous | 1 | 14 |
| 300 ms | simultaneous | 2 | 12 |
| 60–300 ms | 20 ms apart (either order) | 60 | 0 |

A week of real typing by the same author showed 6–13 % of all switches immediately
reverted. Calling `TISSelectInputSource` directly never reverted (0/25), so the defect is in
the hotkey path, not in the input-source machinery. That is the "sometimes it does not
switch at all" symptom.

## Why the popular advice does not help

Caps Lock, swapping Ctrl+Space with Ctrl+Opt+Space, disabling Quick Note, hiding the
indicator: each removes at most one of the three causes, and anything that still goes
through `TextInputSwitcher` keeps the cold starts and the commit-on-release.

## What mgnov does about each

| cause | mgnov |
|---|---|
| on-demand helper, idle-killed | its own resident agent with `KeepAlive` in launchd; the system handler is set to Do Nothing |
| commit on key release + HUD | switches on key **down** (the hotkey, Caps Lock) inside the event tap, no HUD; Globe switches on release of a clean tap because a modifier can only be recognised as a tap on release |
| letters typed before the app catches up | for 500 ms after a switch every keystroke is translated with the new layout (`UCKeyTranslate`) and the characters are written onto the event, so the app types the right letters whatever state it is in |
| the switch is reverted by a race | a 700 ms watchdog re-applies the switch if the selected source flips back |

## Measured with mgnov in place

mgnov records every switch: the time spent in `TISSelectInputSource` and the delay until the
system-wide "selected input source changed" notification, with the frontmost app. 48 hours of
normal use on the same Mac (1–3 November 2026, ⌘Space, two layouts), version 0.1.0:

| | |
|---|---|
| switches | 586 |
| keystrokes re-translated inside the 500 ms window | 951 |
| `TISSelectInputSource` | median 11.7 ms, p95 46.5 ms, max 105 ms |
| notification after the key press | median 81 ms, p95 183 ms, max 317 ms |
| notification later than 250 ms | 6 (1 %) |
| no notification within 1 s | 0 |
| switch reverted by the system and re-applied | 0 |
| event tap disabled by macOS and re-enabled | 3 |

The notification delay is what an app would otherwise wait for before translating keys with the
new layout, and 951 keystrokes in 586 switches arrived inside that window: without the
re-translation they would have come out in the old layout. The slow cases are spread over apps in
proportion to their share of switches (Claude Desktop 4 of 357, iTerm2 1 of 81, Firefox 1 of 19);
no app stands out. The self-test (`mgnov selftest`, typing "qwerty" 6 ms per key right after
the switch) produced 0 wrong letters in 60.

The baseline (macOS handling the same key with mgnov's tap suspended) could not be measured on
macOS 26.5: the system switcher ignores synthetic ⌘Space, ⌃Space and Globe events posted with
`CGEvent` (0 switches in 70 presses), so the comparison rests on the published measurements above
and on the user-visible result.

## Sources

- Control+Space switch reverts on simultaneous release, FB24297598 — https://developer.apple.com/forums/thread/841799
- globe-switch README (TextInputSwitcher idle-killed, 53 relaunches in 3 days) — https://github.com/dmytro-yemelianov/globe-switch
- Cmd+Space commits only on key release (macOS 27.0.1) — https://github.com/jiunbae/settings/pull/84
- The cursor language indicator and `TSMLanguageIndicatorEnabled` — https://chimit.me/posts/macos-input-source-switch-lag/
- Ctrl+Space vs Ctrl+Opt+Space delay — https://amureki.me/notes/2025-03-07-fast-input-switch-macos/
- macism: 150 ms wait on Tahoe before CJK IMEs take over — https://github.com/laishulu/macism
- Apple Community: Ctrl+Space fails intermittently on macOS 26 — https://discussions.apple.com/thread/256254361
