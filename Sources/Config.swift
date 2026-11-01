import Foundation

struct Config: Codable {
    struct Triggers: Codable {
        var ctrlSpace = true
        var globe = true
        var capsLock = false
        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            ctrlSpace = try c.decodeIfPresent(Bool.self, forKey: .ctrlSpace) ?? true
            globe = try c.decodeIfPresent(Bool.self, forKey: .globe) ?? true
            capsLock = try c.decodeIfPresent(Bool.self, forKey: .capsLock) ?? false
        }
    }
    var triggers = Triggers()
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
        cycle = try c.decodeIfPresent([String].self, forKey: .cycle) ?? []
        retranslateWindowMs = try c.decodeIfPresent(Int.self, forKey: .retranslateWindowMs) ?? 300
        watchdogMs = try c.decodeIfPresent(Int.self, forKey: .watchdogMs) ?? 700
        globeTapWindowMs = try c.decodeIfPresent(Int.self, forKey: .globeTapWindowMs) ?? 500
    }

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
