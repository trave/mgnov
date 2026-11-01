import Foundation
import CoreGraphics

/// The key combination that switches layouts. Flags are CGEventFlags bits (cmd 1<<20, opt 1<<19, ctrl 1<<18, shift 1<<17).
struct Hotkey: Codable, Equatable {
    var keyCode: Int
    var flags: UInt64

    static let ctrlSpace = Hotkey(keyCode: 49, flags: 1 << 18)

    /// What macOS has under "Select the previous input source" (symbolic hotkey 60), or Ctrl+Space.
    static func fromSystem() -> Hotkey {
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any],
              let h = all["60"] as? [String: Any], let v = h["value"] as? [String: Any],
              let p = v["parameters"] as? [Int], p.count == 3 else { return .ctrlSpace }
        let mask: UInt64 = (1 << 20) | (1 << 19) | (1 << 18) | (1 << 17)
        return Hotkey(keyCode: p[1], flags: UInt64(p[2]) & mask)
    }

    var description: String {
        var s = ""
        if flags & (1 << 18) != 0 { s += "⌃" }
        if flags & (1 << 19) != 0 { s += "⌥" }
        if flags & (1 << 17) != 0 { s += "⇧" }
        if flags & (1 << 20) != 0 { s += "⌘" }
        let names: [Int: String] = [49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 57: "CapsLock", 51: "Delete"]
        return s + (names[keyCode] ?? "key\(keyCode)")
    }
    /// Key codes of the modifier keys that make up `flags` (for synthetic presses).
    var modifierKeyCodes: [CGKeyCode] {
        var k: [CGKeyCode] = []
        if flags & (1 << 18) != 0 { k.append(59) }
        if flags & (1 << 19) != 0 { k.append(58) }
        if flags & (1 << 17) != 0 { k.append(56) }
        if flags & (1 << 20) != 0 { k.append(55) }
        return k
    }
}

struct Config: Codable {
    struct Triggers: Codable {
        var hotkey = true
        var globe = true
        var capsLock = false
        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            hotkey = try c.decodeIfPresent(Bool.self, forKey: .hotkey) ?? true
            globe = try c.decodeIfPresent(Bool.self, forKey: .globe) ?? true
            capsLock = try c.decodeIfPresent(Bool.self, forKey: .capsLock) ?? false
        }
    }
    var triggers = Triggers()
    /// The switch key. nil = whatever macOS has under "Select the previous input source".
    var hotkey: Hotkey? = nil
    /// Input source IDs to cycle through. Empty = every enabled keyboard source, in system order.
    var cycle: [String] = []
    /// After a switch, keystrokes arriving within this window are re-translated to the new layout.
    var retranslateWindowMs = 300
    /// If the system reverts the source within this window after our switch, re-apply it.
    var watchdogMs = 700
    /// A Globe press shorter than this, with no other key, counts as a tap.
    var globeTapWindowMs = 500

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        triggers = try c.decodeIfPresent(Triggers.self, forKey: .triggers) ?? Triggers()
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        cycle = try c.decodeIfPresent([String].self, forKey: .cycle) ?? []
        retranslateWindowMs = try c.decodeIfPresent(Int.self, forKey: .retranslateWindowMs) ?? 300
        watchdogMs = try c.decodeIfPresent(Int.self, forKey: .watchdogMs) ?? 700
        globeTapWindowMs = try c.decodeIfPresent(Int.self, forKey: .globeTapWindowMs) ?? 500
    }

    var effectiveHotkey: Hotkey { hotkey ?? Hotkey.fromSystem() }

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
