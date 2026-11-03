// Unit tests for the parts that need no permissions: hotkey parsing and config decoding.
// Run with `make test`.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "ok  " : "FAIL") \(what)")
    if !ok { failures += 1 }
}

// MARK: Hotkey.parse
let parses: [(String, Int, UInt64)] = [
    ("⌃⌥Space", 49, Hotkey.ctrl | Hotkey.opt), ("⌘Space", 49, Hotkey.cmd), ("cmd+space", 49, Hotkey.cmd),
    ("ctrl+alt+space", 49, Hotkey.ctrl | Hotkey.opt), ("ctrl-shift-f1", 122, Hotkey.ctrl | Hotkey.shift),
    ("⌘ Space", 49, Hotkey.cmd), ("Control+Option+Shift+Return", 36, Hotkey.ctrl | Hotkey.opt | Hotkey.shift),
    ("^space", 49, Hotkey.ctrl), ("⌥-", 27, Hotkey.opt), ("ctrl+-", 27, Hotkey.ctrl), ("⌃⇧`", 50, Hotkey.ctrl | Hotkey.shift),
    ("cmd+shift+a", 0, Hotkey.cmd | Hotkey.shift), ("f18", 79, 0), ("CapsLock", 57, 0),
]
for (s, kc, fl) in parses {
    let h = Hotkey.parse(s)
    check(h?.keyCode == kc && h?.flags == fl, "parse \"\(s)\" -> \(h?.description ?? "nil")")
    check(h.flatMap { Hotkey.parse($0.description) } == h, "round-trip \"\(h?.description ?? "nil")\"")
}
for bad in ["", "ctrl", "ctrl+foo", "🌐"] { check(Hotkey.parse(bad) == nil, "rejects \"\(bad)\"") }
check(Hotkey(keyCode: 122, flags: Hotkey.ctrl | Hotkey.shift).description == "⌃⇧F1", "F-keys print upper-case")
check(Hotkey(keyCode: 999, flags: 0).description == "key999", "unknown key code prints key<code>")

// MARK: system hotkeys (whatever this Mac has; only the shape is checked)
let sys = Hotkey.systemHotkeys()
check(sys.map { $0.id } == [60, 61], "systemHotkeys reports 60 and 61")
check(!Hotkey.fromSystem().isEmpty, "fromSystem is never empty")

// MARK: Config decoding
func decode(_ json: String) -> Config? { try? JSONDecoder().decode(Config.self, from: Data(json.utf8)) }
check(decode("{}")?.hotkeys == [], "empty config follows the system hotkeys")
check(decode("{}")?.triggers.globe == false, "globe is off by default")
check(decode("{}")?.triggers.hotkey == true, "hotkey trigger is on by default")
check(decode(#"{"hotkey": "ctrl+alt+space"}"#)?.hotkeys == [.ctrlOptSpace], "hotkey as a string")
check(decode(#"{"hotkey": ["⌘Space", "⌃⌥Space"]}"#)?.hotkeys == [Hotkey(keyCode: 49, flags: Hotkey.cmd), .ctrlOptSpace], "hotkey as a list")
check(decode(#"{"hotkey": {"keyCode": 49, "flags": 1048576}}"#)?.hotkeys == [Hotkey(keyCode: 49, flags: Hotkey.cmd)], "hotkey as the old object form")
check(decode(#"{"hotkey": "system"}"#)?.hotkeys == [], "\"system\" means follow macOS")
check(decode(#"{"hotkey": "nonsense"}"#)?.hotkeys == [], "unparseable hotkey falls back to the system hotkeys")
check(decode(#"{"triggers": {"capsLock": true}, "retranslateWindowMs": 300}"#).map { $0.triggers.capsLock && $0.retranslateWindowMs == 300 && $0.watchdogMs == 700 } == true, "partial config keeps defaults")
if var c = decode("{}") {
    c.hotkeys = [.ctrlOptSpace]
    let out = String(data: try! JSONEncoder().encode(c), encoding: .utf8)!
    check(out.contains("\"hotkey\":\"⌃⌥Space\""), "a single hotkey is saved as a string")
    check(decode(out)?.hotkeys == [.ctrlOptSpace], "saved config decodes back")
}

print(failures == 0 ? "all tests passed" : "\(failures) test(s) FAILED")
exit(failures == 0 ? 0 : 1)
