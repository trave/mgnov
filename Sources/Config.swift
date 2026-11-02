import Foundation
import CoreGraphics

/// The key combination that switches layouts. Flags are CGEventFlags bits (cmd 1<<20, opt 1<<19, ctrl 1<<18, shift 1<<17).
struct Hotkey: Codable, Equatable, Hashable {
    var keyCode: Int
    var flags: UInt64

    static let ctrl: UInt64 = 1 << 18, opt: UInt64 = 1 << 19, shift: UInt64 = 1 << 17, cmd: UInt64 = 1 << 20
    static let modifierMask = ctrl | opt | shift | cmd
    static let ctrlSpace = Hotkey(keyCode: 49, flags: ctrl)
    static let ctrlOptSpace = Hotkey(keyCode: 49, flags: ctrl | opt)

    /// A system hotkey that switches input sources (System Settings → Keyboard → Keyboard Shortcuts → Input Sources).
    struct System {
        let id: Int, name: String, hotkey: Hotkey, enabled: Bool
    }

    /// macOS's two input-source hotkeys, 60 "Select the previous input source" and 61 "Select next source in
    /// Input menu", as currently configured (a missing entry means the factory default, enabled).
    static func systemHotkeys() -> [System] {
        let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any] ?? [:]
        let defaults: [(Int, String, Hotkey)] = [(60, "Select the previous input source", .ctrlSpace), (61, "Select next source in Input menu", .ctrlOptSpace)]
        return defaults.map { id, name, def in
            guard let h = all[String(id)] as? [String: Any] else { return System(id: id, name: name, hotkey: def, enabled: true) }
            let enabled = (h["enabled"] as? Bool) ?? true
            if let v = h["value"] as? [String: Any], let p = v["parameters"] as? [Int], p.count == 3, p[1] >= 0 {
                return System(id: id, name: name, hotkey: Hotkey(keyCode: p[1], flags: UInt64(p[2]) & modifierMask), enabled: enabled)
            }
            return System(id: id, name: name, hotkey: def, enabled: enabled)
        }
    }

    /// The enabled system input-source hotkeys (what the user presses today). Never empty: if the user
    /// disabled both, Ctrl+Space.
    static func fromSystem() -> [Hotkey] {
        var seen = Set<Hotkey>()
        let hks = systemHotkeys().filter { $0.enabled }.map { $0.hotkey }.filter { seen.insert($0).inserted }
        return hks.isEmpty ? [.ctrlSpace] : hks
    }

    // MARK: text form

    /// US-ANSI virtual key codes by name.
    static let keyCodes: [String: Int] = [
        "space": 49, "return": 36, "enter": 36, "tab": 48, "esc": 53, "escape": 53, "delete": 51, "backspace": 51,
        "capslock": 57, "section": 10, "§": 10, "grave": 50, "`": 50,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39,
        "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    ]
    static let keyNames: [Int: String] = {
        var m: [Int: String] = [:]
        for (n, c) in keyCodes { m[c] = n }
        for (n, c) in [("Space", 49), ("Return", 36), ("Tab", 48), ("Esc", 53), ("Delete", 51), ("CapsLock", 57), ("Section", 10), ("Grave", 50)] { m[c] = n }
        return m
    }()

    /// "⌃⌥Space", "ctrl+alt+space", "cmd-shift-f1", "⌘ Space" … → Hotkey. nil if the key is unknown.
    static func parse(_ raw: String) -> Hotkey? {
        var flags: UInt64 = 0
        var s = raw.trimmingCharacters(in: .whitespaces)
        for (sym, bit) in [("⌃", ctrl), ("⌥", opt), ("⇧", shift), ("⌘", cmd), ("^", ctrl)] where s.contains(sym) {
            flags |= bit; s = s.replacingOccurrences(of: sym, with: " ")
        }
        var key: String? = nil
        for tok in s.split(whereSeparator: { $0 == "+" || $0 == " " }).map({ String($0).lowercased() }) where !tok.isEmpty {
            switch tok {
            case "ctrl", "control": flags |= ctrl
            case "opt", "option", "alt": flags |= opt
            case "shift": flags |= shift
            case "cmd", "command", "meta", "win", "super": flags |= cmd
            default: key = tok
            }
        }
        // "ctrl-alt-space": a dash is a separator unless it is the key itself
        if let k = key, k.count > 1, k.contains("-"), keyCodes[k] == nil {
            let parts = k.split(separator: "-").map(String.init)
            return parse(parts.joined(separator: "+") + (flags == 0 ? "" : " ") + describeFlags(flags))
        }
        guard let k = key, let code = keyCodes[k] else { return nil }
        return Hotkey(keyCode: code, flags: flags)
    }

    static func describeFlags(_ f: UInt64) -> String {
        (f & ctrl != 0 ? "⌃" : "") + (f & opt != 0 ? "⌥" : "") + (f & shift != 0 ? "⇧" : "") + (f & cmd != 0 ? "⌘" : "")
    }
    var description: String {
        Hotkey.describeFlags(flags) + (Hotkey.keyNames[keyCode].map { $0.count == 1 ? $0.uppercased() : $0 } ?? "key\(keyCode)")
    }
    /// Key codes of the modifier keys that make up `flags` (for synthetic presses).
    var modifierKeyCodes: [CGKeyCode] {
        var k: [CGKeyCode] = []
        if flags & Hotkey.ctrl != 0 { k.append(59) }
        if flags & Hotkey.opt != 0 { k.append(58) }
        if flags & Hotkey.shift != 0 { k.append(56) }
        if flags & Hotkey.cmd != 0 { k.append(55) }
        return k
    }
}

struct Config: Codable {
    struct Triggers: Codable {
        var hotkey = true
        /// Off by default: a Globe tap is also handled by macOS until `scripts/install.sh` sets
        /// "Press 🌐 key to" = Do Nothing, and two handlers mean two switches.
        var globe = false
        var capsLock = false
        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            hotkey = try c.decodeIfPresent(Bool.self, forKey: .hotkey) ?? true
            globe = try c.decodeIfPresent(Bool.self, forKey: .globe) ?? false
            capsLock = try c.decodeIfPresent(Bool.self, forKey: .capsLock) ?? false
        }
    }
    var triggers = Triggers()
    /// The switch keys. Empty = whatever macOS has under "Select the previous input source" and
    /// "Select next source in Input menu". In the file: a string ("⌃⌥Space", "ctrl+alt+space"), a list
    /// of strings, or {"keyCode": 49, "flags": 786432}.
    var hotkeys: [Hotkey] = []
    /// Input source IDs to cycle through. Empty = every enabled keyboard source, in system order.
    var cycle: [String] = []
    /// After a switch, keystrokes arriving within this window are re-translated to the new layout.
    /// (The system-wide "source changed" notification was measured at 93 ms median, 192 ms p95 after the switch.)
    var retranslateWindowMs = 500
    /// If the system reverts the source within this window after our switch, re-apply it.
    var watchdogMs = 700
    /// A Globe press shorter than this, with no other key, counts as a tap.
    var globeTapWindowMs = 500

    enum CodingKeys: String, CodingKey { case triggers, hotkey, cycle, retranslateWindowMs, watchdogMs, globeTapWindowMs }

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        triggers = try c.decodeIfPresent(Triggers.self, forKey: .triggers) ?? Triggers()
        hotkeys = Config.decodeHotkeys(c)
        cycle = try c.decodeIfPresent([String].self, forKey: .cycle) ?? []
        retranslateWindowMs = try c.decodeIfPresent(Int.self, forKey: .retranslateWindowMs) ?? 500
        watchdogMs = try c.decodeIfPresent(Int.self, forKey: .watchdogMs) ?? 700
        globeTapWindowMs = try c.decodeIfPresent(Int.self, forKey: .globeTapWindowMs) ?? 500
    }
    private static func decodeHotkeys(_ c: KeyedDecodingContainer<CodingKeys>) -> [Hotkey] {
        if let s = try? c.decodeIfPresent(String.self, forKey: .hotkey) {
            if s.lowercased() == "system" || s.isEmpty { return [] }
            guard let h = Hotkey.parse(s) else { Log.warn("config: cannot parse hotkey \"\(s)\", using the system hotkeys"); return [] }
            return [h]
        }
        if let a = try? c.decodeIfPresent([String].self, forKey: .hotkey) {
            return a.compactMap { s in let h = Hotkey.parse(s); if h == nil { Log.warn("config: cannot parse hotkey \"\(s)\", skipped") }; return h }
        }
        if let h = try? c.decodeIfPresent(Hotkey.self, forKey: .hotkey) { return [h] }
        if let a = try? c.decodeIfPresent([Hotkey].self, forKey: .hotkey) { return a }
        return []
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(triggers, forKey: .triggers)
        if hotkeys.count == 1 { try c.encode(hotkeys[0].description, forKey: .hotkey) }
        else if !hotkeys.isEmpty { try c.encode(hotkeys.map { $0.description }, forKey: .hotkey) }
        try c.encode(cycle, forKey: .cycle)
        try c.encode(retranslateWindowMs, forKey: .retranslateWindowMs)
        try c.encode(watchdogMs, forKey: .watchdogMs)
        try c.encode(globeTapWindowMs, forKey: .globeTapWindowMs)
    }

    /// The keys the agent reacts to: the configured ones, else the enabled system input-source hotkeys.
    var effectiveHotkeys: [Hotkey] { hotkeys.isEmpty ? Hotkey.fromSystem() : hotkeys }

    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/mgnov")
    }
    static var file: URL { dir.appendingPathComponent("config.json") }
    static var socketPath: String { dir.appendingPathComponent("ctl.sock").path }
    static var logFile: URL { dir.appendingPathComponent("mgnov.log") }

    static func load() -> Config {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(Config.self, from: d) { return c }
        let c = Config()
        c.save()
        return c
    }
    func save() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: Config.file)
    }
}
