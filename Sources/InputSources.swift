import Carbon
import Foundation

struct SourceInfo {
    let id: String
    let name: String
    let isLayout: Bool      // a plain keyboard layout (has uchr data) as opposed to an input method
    let tis: TISInputSource
}

enum InputSources {
    static func prop(_ s: TISInputSource, _ key: CFString) -> String? {
        guard let p = TISGetInputSourceProperty(s, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
    static func current() -> TISInputSource { TISCopyCurrentKeyboardInputSource().takeRetainedValue() }
    static func currentID() -> String { prop(current(), kTISPropertyInputSourceID) ?? "?" }

    /// Enabled, selectable keyboard input sources in the system's menu order.
    static func enabledKeyboardSources() -> [SourceInfo] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceIsEnabled: true,
            kTISPropertyInputSourceIsSelectCapable: true,
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as String,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap { s in
            guard let id = prop(s, kTISPropertyInputSourceID) else { return nil }
            let type = prop(s, kTISPropertyInputSourceType) ?? ""
            return SourceInfo(id: id, name: prop(s, kTISPropertyLocalizedName) ?? id,
                              isLayout: type == (kTISTypeKeyboardLayout as String), tis: s)
        }
    }
    static func find(_ id: String) -> TISInputSource? { enabledKeyboardSources().first { $0.id == id }?.tis }
    @discardableResult static func select(_ s: TISInputSource) -> Bool { TISSelectInputSource(s) == noErr }
}

/// Translates key codes to characters with a specific keyboard layout, independent of the
/// layout the focused app currently has. Used to fix keystrokes that race a switch.
final class KeyTranslator {
    private let data: CFData
    private let layout: UnsafePointer<UCKeyboardLayout>
    private let kbdType = UInt32(LMGetKbdType())

    init?(_ s: TISInputSource) {
        guard let p = TISGetInputSourceProperty(s, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        data = Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue()
        layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
    }

    func translate(keyCode: UInt16, flags: CGEventFlags, keyDown: Bool) -> String? {
        // Carbon modifier bits as UCKeyTranslate wants them: (EventModifiers >> 8) & 0xFF
        var mods: UInt32 = 0
        if flags.contains(.maskCommand)    { mods |= 1 }
        if flags.contains(.maskShift)      { mods |= 2 }
        if flags.contains(.maskAlphaShift) { mods |= 4 }
        if flags.contains(.maskAlternate)  { mods |= 8 }
        if flags.contains(.maskControl)    { mods |= 16 }
        var dead: UInt32 = 0
        var len = 0
        var chars = [UniChar](repeating: 0, count: 8)
        let action = UInt16(keyDown ? kUCKeyActionDown : kUCKeyActionUp)
        let err = UCKeyTranslate(layout, keyCode, action, mods, kbdType,
                                 UInt32(1 << kUCKeyTranslateNoDeadKeysBit), &dead, 8, &len, &chars)
        guard err == noErr, len > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: len)
    }
}
