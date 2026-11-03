import Cocoa

let usage = """
mgnov \(mgnovVersion) — instant, race-free keyboard layout switching for macOS

  mgnov agent                      run the resident agent (normally started by launchd / the app bundle)
  mgnov status                     agent state, sources, effective triggers, warnings
  mgnov stats [--last N] [--json]  switch latency stats, per-app table, recent switches
  mgnov sources                    enabled keyboard input sources
  mgnov switch [ID]                switch to the next source (or to ID)
  mgnov enable|disable TRIGGER     TRIGGER = hotkey | globe | capsLock  (saved to config)
  mgnov hotkey [KEYS|system]       show or set the switch key(s): "⌃⌥Space", "cmd+space", "ctrl+shift+f1",
                                   several separated by commas; "system" = follow macOS's input-source hotkeys
  mgnov measure [--mode system|mgnov] [--trigger hotkey|globe] [--trials N]
                                   timing experiment with synthetic key presses (default: mgnov, hotkey, 5)
  mgnov selftest [--mode system|mgnov] [--trigger hotkey|globe] [--trials N] [--gap MS]
                                   type right after a switch into a real text view; count wrong letters
  mgnov log [--last N]             recent agent log lines
  mgnov config                     print the config file path
  mgnov version                    print the version
  mgnov quit                       stop the agent

The CLI needs no permissions: it talks to the agent over a local socket.
"""

var args = Array(CommandLine.arguments.dropFirst())
let fromBundle = Bundle.main.bundleIdentifier == "dev.trave.mgnov"
let cmd = args.first ?? (fromBundle ? "agent" : "help")
if !args.isEmpty { args.removeFirst() }

func opt(_ name: String, _ def: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return def
}
func optInt(_ name: String, _ def: Int) -> Int { Int(opt(name, "")) ?? def }
func positional() -> String? { args.first(where: { !$0.hasPrefix("--") && Int($0) == nil }) }

func runAgent() -> Never {
    let config = Config.load()
    Log.setup(file: Config.logFile)
    Log.info("mgnov \(mgnovVersion) agent starting, pid \(getpid()), bundle \(Bundle.main.bundleIdentifier ?? "none"), config \(Config.file.path)")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let agent = Agent(config: config)
    agent.start()
    guard let server = ControlServer(path: Config.socketPath, handler: { Commands.handle($0, agent: agent) }) else {
        Log.error("cannot listen on \(Config.socketPath)"); exit(1)
    }
    withExtendedLifetime(server) {
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let sources = [SIGTERM, SIGINT].map { s -> DispatchSourceSignal in
            let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
            src.setEventHandler { agent.shutdown(); exit(0) }
            src.resume()
            return src
        }
        withExtendedLifetime(sources) { app.run() }
    }
    exit(0)
}

/// Small JSON pretty-printer: JSONSerialization prints 80.4 as 80.400000000000006.
func pretty(_ obj: Any, _ indent: String = "") -> String {
    let pad = indent + "  "
    switch obj {
    case let d as [String: Any]:
        if d.isEmpty { return "{}" }
        return "{\n" + d.keys.sorted().map { "\(pad)\"\($0)\" : \(pretty(d[$0]!, pad))" }.joined(separator: ",\n") + "\n\(indent)}"
    case let a as [Any]:
        if a.isEmpty { return "[]" }
        return "[\n" + a.map { "\(pad)\(pretty($0, pad))" }.joined(separator: ",\n") + "\n\(indent)]"
    case let s as String:
        let esc = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(esc)\""
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        let x = n.doubleValue
        if x == x.rounded(), abs(x) < 1e15 { return String(Int64(x)) }
        var t = String(format: "%.3f", x)
        while t.hasSuffix("0") { t.removeLast() }
        return t
    default: return "null"
    }
}

func saveReport(_ kind: String, _ obj: [String: Any]) {
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
    let url = Config.dir.appendingPathComponent("\(kind)-\(obj["mode"] as? String ?? "x")-\(obj["trigger"] as? String ?? "")-\(f.string(from: Date())).json")
    try? pretty(obj).data(using: .utf8)?.write(to: url)
    print("report saved: \(url.path)")
}

func request(_ req: [String: Any]) -> [String: Any] {
    guard let r = ControlClient.send(req, path: Config.socketPath) else {
        print("mgnov agent is not running (no socket at \(Config.socketPath)).\nStart it with `make run` (development) or `scripts/install.sh` (launchd).")
        exit(1)
    }
    if let ok = r["ok"] as? Bool, !ok { print("error: \(r["error"] ?? "unknown")"); exit(1) }
    return r
}

func printStatus(_ s: [String: Any]) {
    print("mgnov \(s["version"] ?? "") pid \(s["pid"] ?? "") bundle \(s["bundle"] ?? "")  uptime \(s["uptimeSec"] ?? 0)s")
    print("accessibility trusted: \(s["trusted"] ?? false)   event tap: \(s["tapInstalled"] ?? false)")
    print("switch keys: \(s["hotkey"] ?? "?")  (\(s["hotkeySource"] ?? "?"))")
    if let sh = s["systemHotkeys"] as? [[String: Any]] {
        print("macOS input-source hotkeys: " + sh.map { "\($0["key"] ?? "") \(($0["enabled"] as? Bool) == true ? "on" : "off")" }.joined(separator: ", "))
    }
    if let t = s["triggers"] as? [String: Bool] { print("triggers: " + t.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value ? "on" : "off")" }.joined(separator: "  ")) }
    if let c = s["config"] as? [String: Any] { print("window: retranslate \(c["retranslateWindowMs"] ?? "")ms, watchdog \(c["watchdogMs"] ?? "")ms, globe tap \(c["globeTapWindowMs"] ?? "")ms   config: \(c["file"] ?? "")") }
    if let src = s["sources"] as? [[String: Any]] {
        print("sources:")
        for x in src { print("  \(x["current"] as? Bool == true ? "*" : " ") \(x["id"] ?? "")  (\(x["name"] ?? ""))\(x["layout"] as? Bool == true ? "" : "  [input method]")") }
    }
    if let c = s["counters"] as? [String: Any] { print("counters: switches \(c["switches"] ?? 0), protected keys \(c["protectedKeys"] ?? 0), reverts caught \(c["revertsCaught"] ?? 0), tap re-enables \(c["tapReenables"] ?? 0)") }
    if let w = s["warnings"] as? [String], !w.isEmpty { print("warnings:"); w.forEach { print("  ! \($0)") } }
}

func pad(_ s: Any, _ w: Int) -> String { let t = "\(s)"; return t.count >= w ? t : t + String(repeating: " ", count: w - t.count) }

func printMeasure(_ r: [String: Any]) {
    print("\(r["trigger"] ?? "") experiment — handled by: \(r["handledBy"] ?? "")   trials per condition: \(r["trials"] ?? "")")
    let widths = [7, 6, 15, 10, 9, 5, 27, 27]
    func row(_ cols: [Any]) -> String { zip(cols, widths).map { pad($0.0, $0.1) }.joined(separator: " ") + " \(cols.last!)" }
    print(row(["hold", "gap", "release order", "persisted", "reverted", "none", "lat. from key-down (ms)", "lat. from key-up (ms)", "revert after (ms)"]))
    func f(_ x: Any?) -> String { String(format: "%.1f", (x as? NSNumber)?.doubleValue ?? 0) }
    func a(_ x: Any?) -> String { guard let d = x as? [String: Any], (d["n"] as? Int ?? 0) > 0 else { return "-" }; return "min \(f(d["min"])) avg \(f(d["avg"])) max \(f(d["max"]))" }
    for c in r["conditions"] as? [[String: Any]] ?? [] {
        print(row(["\(c["holdMs"]!)ms", "\(c["releaseGapMs"]!)ms", c["releaseOrder"]!, c["persisted"]!, c["reverted"]!, c["noResponse"]!, a(c["latencyFromKeyDownMs"]), a(c["latencyFromKeyUpMs"]), a(c["revertAfterMs"])]))
    }
}

func printSelfTest(_ r: [String: Any]) {
    print("self-test (\(r["trigger"] ?? "")) — handled by: \(r["handledBy"] ?? "")   trials: \(r["trials"] ?? "")   typing started \(r["typeGapMs"] ?? 0) ms after the switch")
    for t in r["results"] as? [[String: Any]] ?? [] {
        print(String(format: "  #%-3@ %@ -> %@  expected %@  got %@  wrong %@%@", "\(t["trial"]!)", "\(t["from"]!)", "\(t["to"]!)", "\(t["expected"]!)", "\(t["got"]!)", "\(t["wrongChars"]!)", (t["switched"] as? Bool == false) ? "  (NO SWITCH)" : ""))
    }
    print("TOTAL: \(r["wrongChars"] ?? 0) wrong of \(r["chars"] ?? 0) letters; \(r["noSwitch"] ?? 0) trials did not switch")
}

switch cmd {
case "agent": runAgent()
case "help", "-h", "--help": print(usage)
case "version": print(mgnovVersion)
case "config": print(Config.file.path)
case "status": printStatus(request(["cmd": "status"]))
case "stats":
    let r = request(["cmd": "stats", "last": optInt("--last", 15)])
    func f(_ x: Any?) -> String { String(format: "%.1f", (x as? NSNumber)?.doubleValue ?? 0) }
    let n = r["notifyMs"] as? [String: Any] ?? [:], s = r["selectMs"] as? [String: Any] ?? [:]
    print("uptime \(r["uptimeSec"] ?? 0)s   switches \(r["switches"] ?? 0) (\(r["recorded"] ?? 0) recorded)   protected keys \(r["protectedKeys"] ?? 0)   reverts caught \(r["revertsCaught"] ?? 0)   slow (>\(Int(slowMs)) ms) \(r["slowSwitches"] ?? 0)   no notification \(r["noNotify"] ?? 0)")
    print("select: median \(f(s["median"])) p95 \(f(s["p95"])) max \(f(s["max"])) ms    notification after key: median \(f(n["median"])) p95 \(f(n["p95"])) max \(f(n["max"])) ms")
    if let apps = r["byApp"] as? [String: [String: Any]], !apps.isEmpty {
        print(pad("app", 36) + " " + pad("switches", 9) + pad("slow", 6) + pad("none", 6) + pad("reverts", 9) + pad("notify med", 11) + "notify max")
        for (app, d) in apps.sorted(by: { ($0.value["switches"] as? Int ?? 0) > ($1.value["switches"] as? Int ?? 0) }) {
            print(pad(app, 36) + " " + pad(d["switches"] ?? 0, 9) + pad(d["slow"] ?? 0, 6) + pad(d["noNotify"] ?? 0, 6) + pad(d["reverts"] ?? 0, 9) + pad(f(d["notifyMedianMs"]), 11) + f(d["notifyMaxMs"]))
        }
    }
    if args.contains("--json") { print(pretty(r)) }
    else if let rec = r["recent"] as? [[String: Any]], !rec.isEmpty {
        print("recent:")
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        for x in rec { print("  \(df.string(from: Date(timeIntervalSince1970: (x["at"] as? Double) ?? 0)))  \(pad(x["from"] ?? "", 8))-> \(pad(x["to"] ?? "", 8)) notify \(x["notifyMs"].map { f($0) } ?? "-   ") ms  keys \(x["protectedKeys"] ?? 0)  \(x["app"] ?? "")\((x["slow"] as? Bool == true) ? "  SLOW" : "")\((x["revertCaught"] as? Bool == true) ? "  REVERT" : "")") }
    }
case "sources":
    let r = request(["cmd": "sources"])
    for x in r["sources"] as? [[String: Any]] ?? [] { print("\(x["current"] as? Bool == true ? "*" : " ") \(x["id"] ?? "")  (\(x["name"] ?? ""))") }
case "switch":
    var req: [String: Any] = ["cmd": "switch"]; if let id = positional() { req["id"] = id }
    print("current: \(request(req)["current"] ?? "")")
case "enable", "disable":
    guard let t = positional() else { print("trigger name required: hotkey | globe | capsLock"); exit(1) }
    print(pretty(request(["cmd": "set", "trigger": t, "enabled": cmd == "enable"])))
case "hotkey":
    if let v = positional() { print(pretty(request(["cmd": "hotkey", "value": v]))) }
    else { let s = request(["cmd": "status"]); print("switch keys: \(s["hotkey"] ?? "?")  (\(s["hotkeySource"] ?? "?"))") }
case "measure":
    let r = request(["cmd": "measure", "mode": opt("--mode", "mgnov"), "trigger": opt("--trigger", "hotkey"), "trials": optInt("--trials", 5)])
    printMeasure(r); saveReport("measure", r)
case "selftest":
    let r = request(["cmd": "selftest", "mode": opt("--mode", "mgnov"), "trigger": opt("--trigger", "hotkey"), "trials": optInt("--trials", 10), "gap": optInt("--gap", 0)])
    printSelfTest(r); saveReport("selftest", r)
case "log": (request(["cmd": "log", "last": optInt("--last", 50)])["lines"] as? [String] ?? []).forEach { print($0) }
case "quit": _ = request(["cmd": "quit"]); print("agent asked to quit")
default: print("unknown command: \(cmd)\n"); print(usage); exit(1)
}
