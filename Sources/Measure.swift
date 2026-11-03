import Cocoa
import Carbon

/// Synthetic keyboard events. Only the agent (which holds the permissions) runs these.
enum Synth {
    static func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
    static let source = CGEventSource(stateID: .hidSystemState)
    static func key(_ kc: CGKeyCode, down: Bool, flags: CGEventFlags = []) -> CGEvent? {
        let e = CGEvent(keyboardEventSource: source, virtualKey: kc, keyDown: down)
        e?.flags = flags
        return e
    }
    /// Tap the Globe (fn) key. Returns the monotonic times of key down and key up.
    static func globe(holdMs: Int) -> (down: Double, up: Double) {
        let tDown = Clock.now()
        post(key(63, down: true, flags: .maskSecondaryFn))
        usleep(UInt32(max(holdMs, 1)) * 1000)
        let tUp = Clock.now()
        post(key(63, down: false, flags: []))
        return (tDown, tUp)
    }
    static func trigger(_ name: String, hotkey: Hotkey, holdMs: Int, gapMs: Int, keyUpFirst: Bool) -> (down: Double, up: Double) {
        name == "globe" ? globe(holdMs: holdMs) : press(hotkey, holdMs: holdMs, gapMs: gapMs, keyUpFirst: keyUpFirst)
    }
    /// Press the hotkey (modifiers, then the key). Returns the monotonic times of the key's down and up.
    static func press(_ hk: Hotkey, holdMs: Int, gapMs: Int, keyUpFirst: Bool) -> (down: Double, up: Double) {
        let flags = CGEventFlags(rawValue: hk.flags)
        let kc = CGKeyCode(hk.keyCode)
        for m in hk.modifierKeyCodes { post(key(m, down: true, flags: flags)); usleep(5_000) }
        usleep(5_000)
        let tDown = Clock.now()
        post(key(kc, down: true, flags: flags))
        usleep(UInt32(max(holdMs, 1)) * 1000)
        var tUp = 0.0
        if keyUpFirst {
            tUp = Clock.now(); post(key(kc, down: false, flags: flags))
            if gapMs > 0 { usleep(UInt32(gapMs) * 1000) }
            for m in hk.modifierKeyCodes.reversed() { post(key(m, down: false)) }
        } else {
            for m in hk.modifierKeyCodes.reversed() { post(key(m, down: false)) }
            if gapMs > 0 { usleep(UInt32(gapMs) * 1000) }
            tUp = Clock.now(); post(key(kc, down: false))
        }
        return (tDown, tUp)
    }
}

/// Polls the selected input source every millisecond and records every change.
/// Polling runs on the main thread: Text Input Sources is not thread-safe (HIToolbox aborts
/// when TISSelectInputSource and TISCopyCurrentKeyboardInputSource overlap on two threads).
final class SourceMonitor {
    private var changes: [(Double, String)] = []
    private let lock = NSLock()
    private var last = ""
    private var timer: DispatchSourceTimer?
    init() {
        onMain {
            last = InputSources.currentID()
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(200))
            t.setEventHandler { [self] in
                let id = InputSources.currentID()
                if id != last { lock.lock(); changes.append((Clock.now(), id)); lock.unlock(); last = id }
            }
            t.resume()
            timer = t
        }
    }
    func reset() { onMain { last = InputSources.currentID() }; lock.lock(); changes = []; lock.unlock() }
    func snapshot() -> [(Double, String)] { lock.lock(); defer { lock.unlock() }; return changes }
    func finish() { onMain { timer?.cancel(); timer = nil } }
}

func currentIDOnMain() -> String { onMain { InputSources.currentID() } }

func agg(_ a: [Double]) -> [String: Any] {
    guard !a.isEmpty else { return ["n": 0] }
    return ["n": a.count, "min": num(a.min()!), "avg": num(a.reduce(0, +) / Double(a.count)), "max": num(a.max()!)]
}

func restoreSource(_ id: String) {
    onMain { if InputSources.currentID() != id, let s = InputSources.find(id) { InputSources.select(s) } }
}

/// Reproduces the FB24297598 experiment: the hotkey with various hold times and release timings.
/// mode "system": mgnov's hotkey trigger is turned off so the macOS hotkey handles the keys.
/// mode "mgnov": mgnov handles them.
enum Measure {
    struct Cond { let hold: Int; let gap: Int; let keyUpFirst: Bool }
    static let conditions = [
        Cond(hold: 40, gap: 0, keyUpFirst: true), Cond(hold: 80, gap: 0, keyUpFirst: true),
        Cond(hold: 150, gap: 0, keyUpFirst: true), Cond(hold: 300, gap: 0, keyUpFirst: true),
        Cond(hold: 80, gap: 30, keyUpFirst: true), Cond(hold: 80, gap: 30, keyUpFirst: false),
    ]
    static let globeConditions = [Cond(hold: 40, gap: 0, keyUpFirst: true), Cond(hold: 80, gap: 0, keyUpFirst: true),
                                  Cond(hold: 150, gap: 0, keyUpFirst: true), Cond(hold: 300, gap: 0, keyUpFirst: true)]

    static func run(agent: Agent, mode: String, trigger: String, trials: Int) -> [String: Any] {
        let systemMode = mode == "system"
        let globeWas = onMain { agent.config.triggers.globe }
        onMain { agent.setTapEnabled(!systemMode); if !systemMode && trigger == "globe" { agent.forceTrigger("globe", true) } }
        defer { onMain { agent.setTapEnabled(true); agent.forceTrigger("globe", globeWas) } }
        let original = currentIDOnMain()
        let hk = onMain { agent.hotkey }
        let mon = SourceMonitor(); defer { mon.finish() }
        var out: [[String: Any]] = []
        let conds = trigger == "globe" ? globeConditions : conditions
        for c in conds {
            var persisted = 0, reverted = 0, none = 0
            var latDown: [Double] = [], latUp: [Double] = [], revertAfter: [Double] = []
            for _ in 0..<trials {
                mon.reset()
                let before = currentIDOnMain()
                let t = Synth.trigger(trigger, hotkey: hk, holdMs: c.hold, gapMs: c.gap, keyUpFirst: c.keyUpFirst)
                usleep(1_200_000)
                let ch = mon.snapshot()
                let after = currentIDOnMain()
                if ch.isEmpty { none += 1 }
                else if after == before { reverted += 1; if ch.count >= 2 { revertAfter.append((ch[1].0 - ch[0].0) * 1000) } }
                else { persisted += 1; latDown.append((ch[0].0 - t.down) * 1000); latUp.append((ch[0].0 - t.up) * 1000) }
            }
            out.append(["holdMs": c.hold, "releaseGapMs": c.gap, "releaseOrder": c.keyUpFirst ? "key-up first" : "modifier-up first",
                        "trials": trials, "persisted": persisted, "reverted": reverted, "noResponse": none,
                        "latencyFromKeyDownMs": agg(latDown), "latencyFromKeyUpMs": agg(latUp), "revertAfterMs": agg(revertAfter)])
        }
        restoreSource(original)
        return ["mode": mode, "trigger": trigger == "globe" ? "globe" : hk.description, "trials": trials, "startSource": original, "conditions": out,
                "handledBy": systemMode ? "macOS hotkey (mgnov tap suspended)" : "mgnov"]
    }
}

/// End-to-end proof: a real text view receives real (synthetic, HID-level) keystrokes right
/// after a switch. Counts letters that came out in the wrong layout.
final class SelfTestWindow {
    let window: NSWindow
    let text: NSTextView
    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "mgnov self-test — do not touch the keyboard"
        window.level = .floating
        window.center()
        text = NSTextView(frame: NSRect(x: 10, y: 10, width: 440, height: 100))
        text.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        window.contentView?.addSubview(text)
    }
    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(text)
    }
    func close() { window.orderOut(nil) }
}

enum SelfTest {
    static let keys: [CGKeyCode] = [12, 13, 14, 15, 17, 16]   // q w e r t y

    static func run(agent: Agent, mode: String, trigger: String, trials: Int, typeGapMs: Int) -> [String: Any] {
        let systemMode = mode == "system"
        let globeWas = onMain { agent.config.triggers.globe }
        onMain { agent.setTapEnabled(!systemMode); if !systemMode && trigger == "globe" { agent.forceTrigger("globe", true) } }
        defer { onMain { agent.setTapEnabled(true); agent.forceTrigger("globe", globeWas) } }
        let original = currentIDOnMain()
        let hk = onMain { agent.hotkey }
        let win = onMain { SelfTestWindow() }
        onMain { win.show() }
        usleep(600_000)

        // focus probe: does the text view receive our keystrokes at all?
        Synth.post(Synth.key(0, down: true)); usleep(8_000); Synth.post(Synth.key(0, down: false)); usleep(300_000)
        let probe = onMain { win.text.string }
        guard !probe.isEmpty else {
            onMain { win.close() }
            return ["ok": false, "error": "self-test window did not receive keystrokes (focus or permissions problem)"]
        }

        var results: [[String: Any]] = []
        var wrongTotal = 0, charsTotal = 0, noSwitch = 0
        for i in 0..<trials {
            onMain { win.text.string = "" }
            let before = currentIDOnMain()
            guard let expected: String = onMain({
                guard let targetID = agent.nextID(after: before),
                      let target = InputSources.enabledKeyboardSources().first(where: { $0.id == targetID }),
                      let tr = KeyTranslator(target.tis) else { return nil }
                return keys.compactMap { tr.translate(keyCode: UInt16($0), flags: [], keyDown: true) }.joined()
            }) else { continue }
            _ = Synth.trigger(trigger, hotkey: hk, holdMs: 40, gapMs: 0, keyUpFirst: true)
            if typeGapMs > 0 { usleep(UInt32(typeGapMs) * 1000) }
            for k in keys {
                Synth.post(Synth.key(k, down: true)); usleep(6_000)
                Synth.post(Synth.key(k, down: false)); usleep(6_000)
            }
            usleep(600_000)
            let got = onMain { win.text.string }
            let after = currentIDOnMain()
            if after == before { noSwitch += 1 }
            let wrong = zip(got, expected).filter { $0 != $1 }.count + abs(got.count - expected.count)
            wrongTotal += wrong; charsTotal += expected.count
            results.append(["trial": i + 1, "from": short(before), "to": short(after), "switched": after != before,
                            "expected": expected, "got": got, "wrongChars": wrong])
        }
        onMain { win.close() }
        restoreSource(original)
        return ["mode": mode, "trigger": trigger == "globe" ? "globe" : hk.description, "trials": trials, "typeGapMs": typeGapMs, "wrongChars": wrongTotal, "chars": charsTotal,
                "noSwitch": noSwitch, "results": results, "handledBy": systemMode ? "macOS hotkey (mgnov tap suspended)" : "mgnov"]
    }
}
