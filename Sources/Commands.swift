import Foundation

/// Agent-side dispatch of control requests. Long-running ones (measure, selftest) run on the
/// control thread so the event tap on the main run loop keeps working.
enum Commands {
    static func handle(_ req: [String: Any], agent: Agent) -> [String: Any] {
        let cmd = req["cmd"] as? String ?? ""
        func int(_ k: String, _ d: Int) -> Int { (req[k] as? Int) ?? d }
        func str(_ k: String, _ d: String) -> String { (req[k] as? String) ?? d }
        switch cmd {
        case "status": return onMain { agent.status() }
        case "stats": return onMain { agent.stats(last: int("last", 15)) }
        case "sources":
            return onMain {
                let cur = InputSources.currentID()
                return ["current": cur, "sources": InputSources.enabledKeyboardSources().map { ["id": $0.id, "name": $0.name, "layout": $0.isLayout, "current": $0.id == cur] }]
            }
        case "switch":
            let to = onMain { agent.doSwitch(trigger: "cli", at: Clock.now(), to: req["id"] as? String) }
            return ["switched": to != nil, "current": onMain { InputSources.currentID() }]
        case "measure": return Measure.run(agent: agent, mode: str("mode", "mgnov"), trigger: str("trigger", "hotkey"), trials: int("trials", 5))
        case "selftest": return SelfTest.run(agent: agent, mode: str("mode", "mgnov"), trigger: str("trigger", "hotkey"), trials: int("trials", 10), typeGapMs: int("gap", 0))
        case "log": return ["lines": Log.recent(int("last", 50))]
        case "set":
            let name = str("trigger", ""); let on = (req["enabled"] as? Bool) ?? true
            return onMain {
                switch name {
                case "hotkey": agent.config.triggers.hotkey = on
                case "globe": agent.config.triggers.globe = on
                case "capsLock": agent.config.triggers.capsLock = on
                default: return ["ok": false, "error": "unknown trigger \(name)"]
                }
                agent.config.save()
                if name == "capsLock" { on ? agent.applyCapsLockRemap() : agent.removeCapsLockRemap() }
                return ["triggers": ["hotkey": agent.triggerOn("hotkey"), "globe": agent.triggerOn("globe"), "capsLock": agent.triggerOn("capsLock")]]
            }
        case "hotkey":
            let value = str("value", "").trimmingCharacters(in: .whitespaces)
            return onMain {
                if value.lowercased() == "system" {
                    agent.config.hotkeys = []
                } else {
                    var hks: [Hotkey] = []
                    for part in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        guard let h = Hotkey.parse(part) else { return ["ok": false, "error": "cannot parse \"\(part)\"; examples: ⌃⌥Space, cmd+space, ctrl+shift+f1, system"] }
                        hks.append(h)
                    }
                    if hks.isEmpty { return ["ok": false, "error": "no key given"] }
                    agent.config.hotkeys = hks
                }
                agent.config.save()
                agent.applyHotkeys()
                return ["hotkey": agent.hotkeys.map { $0.description }.joined(separator: ", "), "source": agent.config.hotkeys.isEmpty ? "system" : "config"]
            }
        case "quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { agent.shutdown(); exit(0) }
            return ["bye": true]
        default: return ["ok": false, "error": "unknown command \(cmd)"]
        }
    }
}
