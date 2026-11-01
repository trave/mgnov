import Cocoa
import Carbon

struct SwitchRecord: Codable {
    var at: Double            // unix time
    var trigger: String
    var from: String
    var to: String
    var selectMs: Double      // time spent inside TISSelectInputSource
    var notifyMs: Double?     // trigger -> system-wide "source changed" notification
    var protectedKeys: Int    // keystrokes re-translated to the new layout inside the window
    var revertCaught: Bool
}

/// The resident part: an active session event tap that switches on the trigger key itself,
/// re-translates keystrokes that race the switch, and re-applies a switch the system reverts.
final class Agent: NSObject {
    var config: Config
    private var tap: CFMachPort?
    private(set) var tapInstalled = false
    private(set) var suspended = false
    /// Runtime overrides (the measurement modes use them). Values: "ctrlSpace", "globe", "capsLock".
    var disabledTriggers = Set<String>()
    let startedAt = Date()

    // pending switch — main thread only
    private var pendingID = ""
    private var pendingSource: TISInputSource?
    private var pendingTranslator: KeyTranslator?
    private var pendingTriggerAt = 0.0
    private var pendingUntil = 0.0
    private var watchdogUntil = 0.0
    private var watchdogFired = false
    private var swallowSpaceUp = false

    // Globe (fn) tap detection
    private var fnDown = false, fnDownAt = 0.0, fnAlone = false

    // stats
    private(set) var records: [SwitchRecord] = []
    private(set) var switches = 0, protectedKeys = 0, revertsCaught = 0, tapReenables = 0
    private var capsRemapped = false

    init(config: Config) { self.config = config; super.init() }

    func start() {
        if !AXIsProcessTrusted() {
            Log.warn("not trusted for Accessibility yet; asking macOS to show the prompt")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(sourceChanged(_:)),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        installTapWhenPossible()
        applyCapsLockRemap()
    }

    func shutdown() {
        removeCapsLockRemap()
        Log.info("agent stopping")
    }

    // MARK: tap

    private func installTapWhenPossible() {
        if installTap() { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installTapWhenPossible() }
    }

    private func installTap() -> Bool {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask: CGEventMask = types.reduce(0) { $0 | (1 << $1.rawValue) }
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, info in
            Unmanaged<Agent>.fromOpaque(info!).takeUnretainedValue().handle(type: type, event: event)
        }, userInfo: info) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapInstalled = true
        Log.info("event tap installed (trusted)")
        return true
    }

    /// Baseline measurements turn the tap off entirely so macOS handles the keys exactly as without mgnov.
    func setTapEnabled(_ on: Bool) {
        guard let tap = tap else { return }
        suspended = !on
        CGEvent.tapEnable(tap: tap, enable: on)
        Log.info(on ? "tap resumed" : "tap suspended for a baseline measurement")
    }

    func triggerOn(_ name: String) -> Bool {
        if disabledTriggers.contains(name) { return false }
        switch name {
        case "ctrlSpace": return config.triggers.ctrlSpace
        case "globe": return config.triggers.globe
        case "capsLock": return config.triggers.capsLock
        default: return false
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if suspended { return pass }          // we turned it off on purpose; leave it off
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            tapReenables += 1
            Log.warn("tap disabled by system (\(type.rawValue)); re-enabled")
            return pass
        }
        if suspended { return pass }
        let t = Clock.now()
        let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let mods = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])

        switch type {
        case .flagsChanged:
            if kc == 63 {                                   // fn / Globe
                let down = flags.contains(.maskSecondaryFn)
                if down { fnDown = true; fnDownAt = t; fnAlone = true }
                else if fnDown {
                    fnDown = false
                    if fnAlone, (t - fnDownAt) * 1000 < Double(config.globeTapWindowMs), triggerOn("globe") {
                        doSwitch(trigger: "globe", at: t)
                    }
                }
            } else if fnDown { fnAlone = false }
            return pass

        case .keyDown:
            if fnDown { fnAlone = false }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if kc == 49, mods == [.maskControl], triggerOn("ctrlSpace") {
                if !isRepeat { doSwitch(trigger: "ctrlSpace", at: t) }
                swallowSpaceUp = true
                return nil                                   // the system hotkey never sees it
            }
            if kc == 79, triggerOn("capsLock") {             // Caps Lock, remapped by us to F18
                if !isRepeat { doSwitch(trigger: "capsLock", at: t) }
                return nil
            }
            retranslate(event, keyCode: kc, flags: flags, mods: mods, keyDown: true, at: t)
            return pass

        case .keyUp:
            if kc == 49, swallowSpaceUp { swallowSpaceUp = false; return nil }
            if kc == 79, triggerOn("capsLock") { return nil }
            retranslate(event, keyCode: kc, flags: flags, mods: mods, keyDown: false, at: t)
            return pass

        default:
            if fnDown { fnAlone = false }
            return pass
        }
    }

    // MARK: switching

    func cycleIDs() -> [String] {
        let enabled = InputSources.enabledKeyboardSources().map { $0.id }
        let c = config.cycle.filter { enabled.contains($0) }
        return c.count >= 2 ? c : enabled
    }

    func nextID(after id: String) -> String? {
        let c = cycleIDs()
        guard c.count >= 2 else { return nil }
        let i = c.firstIndex(of: id) ?? -1
        return c[(i + 1) % c.count]
    }

    @discardableResult
    func doSwitch(trigger: String, at t: Double, to explicit: String? = nil) -> String? {
        let fromID = InputSources.currentID()
        guard let targetID = explicit ?? nextID(after: fromID) else { Log.warn("need at least two enabled sources"); return nil }
        guard let target = InputSources.enabledKeyboardSources().first(where: { $0.id == targetID }) else {
            Log.warn("unknown source \(targetID)"); return nil
        }
        let t0 = Clock.now()
        let ok = InputSources.select(target.tis)
        let t1 = Clock.now()
        pendingID = target.id
        pendingSource = target.tis
        pendingTranslator = target.isLayout ? KeyTranslator(target.tis) : nil
        pendingTriggerAt = t
        pendingUntil = t1 + Double(config.retranslateWindowMs) / 1000
        watchdogUntil = t1 + Double(config.watchdogMs) / 1000
        watchdogFired = false
        switches += 1
        records.append(SwitchRecord(at: Date().timeIntervalSince1970, trigger: trigger, from: fromID, to: target.id,
                                    selectMs: (t1 - t0) * 1000, notifyMs: nil, protectedKeys: 0, revertCaught: false))
        if records.count > 500 { records.removeFirst(records.count - 500) }
        Log.info(String(format: "switch [%@] %@ -> %@  select=%.2f ms%@", trigger, short(fromID), short(target.id), (t1 - t0) * 1000, ok ? "" : "  (TISSelectInputSource FAILED)"))
        return target.id
    }

    /// Keystrokes that arrive right after a switch may still be translated by the app with the old
    /// layout (the app learns about the switch asynchronously). Translate them ourselves with the
    /// new layout and put the characters on the event, so whatever the app's state is, the right
    /// letters come out.
    private func retranslate(_ event: CGEvent, keyCode: UInt16, flags: CGEventFlags, mods: CGEventFlags, keyDown: Bool, at t: Double) {
        guard t < pendingUntil, let tr = pendingTranslator else { return }
        if mods.contains(.maskCommand) || mods.contains(.maskControl) { return }   // shortcuts, not text
        guard let s = tr.translate(keyCode: keyCode, flags: flags, keyDown: keyDown),
              s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return }
        var units = Array(s.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        if keyDown {
            protectedKeys += 1
            if !records.isEmpty { records[records.count - 1].protectedKeys += 1 }
        }
    }

    @objc private func sourceChanged(_ n: Notification) {
        let t = Clock.now()
        let id = InputSources.currentID()
        guard !pendingID.isEmpty else { return }
        if id == pendingID {
            if var r = records.last, r.notifyMs == nil, r.to == id {
                r.notifyMs = (t - pendingTriggerAt) * 1000
                records[records.count - 1] = r
            }
        } else if t < watchdogUntil, !watchdogFired, let src = pendingSource {
            // Something (the system hotkey race, a stale helper) flipped it back. Re-apply.
            watchdogFired = true
            revertsCaught += 1
            if !records.isEmpty { records[records.count - 1].revertCaught = true }
            Log.warn(String(format: "source reverted to %@ %.0f ms after our switch; re-applying %@", short(id), (t - pendingTriggerAt) * 1000, short(pendingID)))
            InputSources.select(src)
        }
    }

    // MARK: Caps Lock remap (only when that trigger is on)

    private func hidutil(_ mapping: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = ["property", "--set", "{\"UserKeyMapping\":\(mapping)}"]
        try? p.run(); p.waitUntilExit()
    }
    private func applyCapsLockRemap() {
        guard config.triggers.capsLock else { return }
        hidutil("[{\"HIDKeyboardModifierMappingSrc\":0x700000039,\"HIDKeyboardModifierMappingDst\":0x70000006D}]")
        capsRemapped = true
        Log.info("Caps Lock remapped to F18 for the capsLock trigger")
    }
    private func removeCapsLockRemap() {
        guard capsRemapped else { return }
        hidutil("[]")
        capsRemapped = false
    }

    // MARK: reports

    func systemWarnings() -> [String] {
        var w: [String] = []
        if !tapInstalled { w.append("Event tap not installed: grant Accessibility to Mgnov.app (System Settings → Privacy & Security → Accessibility).") }
        let fnUsage = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        if triggerOn("globe"), fnUsage != 0 {
            w.append("Globe key is still handled by macOS too (AppleFnUsageType=\(fnUsage.map(String.init) ?? "default")). Set 'Press 🌐 key to' = Do Nothing, or run scripts/install.sh.")
        }
        if let hk = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any],
           let h60 = hk["60"] as? [String: Any], let en = h60["enabled"] as? Bool, en, triggerOn("ctrlSpace") {
            w.append("System hotkey 60 (Select previous input source, Ctrl+Space) is still enabled; mgnov swallows the keys first, but disable it to be safe (scripts/install.sh does).")
        }
        if cycleIDs().count < 2 { w.append("Fewer than two enabled keyboard input sources; nothing to switch between.") }
        return w
    }

    /// Measurement helper: force a trigger on for the duration of a run.
    func forceTrigger(_ name: String, _ on: Bool) {
        if on { disabledTriggers.remove(name) }
        switch name {
        case "globe": config.triggers.globe = on
        case "ctrlSpace": config.triggers.ctrlSpace = on
        default: break
        }
    }

    func status() -> [String: Any] {
        let sources = InputSources.enabledKeyboardSources()
        let cur = InputSources.currentID()
        return [
            "version": mgnovVersion, "pid": Int(getpid()),
            "bundle": Bundle.main.bundleIdentifier ?? "none",
            "trusted": AXIsProcessTrusted(), "tapInstalled": tapInstalled,
            "uptimeSec": Int(Date().timeIntervalSince(startedAt)),
            "triggers": ["ctrlSpace": triggerOn("ctrlSpace"), "globe": triggerOn("globe"), "capsLock": triggerOn("capsLock")],
            "config": ["retranslateWindowMs": config.retranslateWindowMs, "watchdogMs": config.watchdogMs, "globeTapWindowMs": config.globeTapWindowMs, "cycle": cycleIDs(), "file": Config.file.path],
            "current": cur,
            "sources": sources.map { ["id": $0.id, "name": $0.name, "layout": $0.isLayout, "current": $0.id == cur] },
            "counters": ["switches": switches, "protectedKeys": protectedKeys, "revertsCaught": revertsCaught, "tapReenables": tapReenables],
            "warnings": systemWarnings(),
        ]
    }

    func stats(last n: Int) -> [String: Any] {
        let recent = records.suffix(n).map { r -> [String: Any] in
            var d: [String: Any] = ["at": r.at, "trigger": r.trigger, "from": short(r.from), "to": short(r.to),
                                    "selectMs": num(r.selectMs, 2), "protectedKeys": r.protectedKeys, "revertCaught": r.revertCaught]
            if let nm = r.notifyMs { d["notifyMs"] = num(nm) }
            return d
        }
        let notify = records.compactMap { $0.notifyMs }
        let sel = records.map { $0.selectMs }
        func agg(_ a: [Double]) -> [String: Any] {
            guard !a.isEmpty else { return ["n": 0] }
            let s = a.sorted()
            return ["n": a.count, "min": num(s.first!), "median": num(s[s.count / 2]), "p95": num(s[min(s.count - 1, Int(Double(s.count) * 0.95))]), "max": num(s.last!)]
        }
        return ["switches": switches, "protectedKeys": protectedKeys, "revertsCaught": revertsCaught, "tapReenables": tapReenables,
                "selectMs": agg(sel), "notifyMs": agg(notify), "recent": recent]
    }
}
