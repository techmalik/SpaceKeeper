import Cocoa
import Carbon.HIToolbox

/// A key plus Carbon modifier flags (cmdKey | optionKey | controlKey | shiftKey).
struct Shortcut: Equatable, Hashable {
    var keyCode: Int
    var modifiers: Int

    static let ctrlOptCmd = cmdKey | optionKey | controlKey

    /// "keyCode:modifiers" as stored in UserDefaults.
    var stored: String { "\(keyCode):\(modifiers)" }
    init(keyCode: Int, modifiers: Int) { self.keyCode = keyCode; self.modifiers = modifiers }
    init?(stored: String) {
        let parts = stored.split(separator: ":")
        guard parts.count == 2, let k = Int(parts[0]), let m = Int(parts[1]), (0...0xFFFF).contains(k) else { return nil }
        keyCode = k; modifiers = m & (cmdKey | optionKey | controlKey | shiftKey)
    }

    init(event: NSEvent) {
        keyCode = Int(event.keyCode)
        var m = 0
        let f = event.modifierFlags
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.control) { m |= controlKey }
        if f.contains(.shift) { m |= shiftKey }
        modifiers = m
    }

    /// A global shortcut needs ⌘, ⌥ or ⌃ (Shift alone would steal ordinary typing), unless it is a function key.
    var isAcceptable: Bool {
        modifiers & (cmdKey | optionKey | controlKey) != 0 || Self.functionKeys.contains(keyCode)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { f.insert(.control) }
        if modifiers & optionKey != 0 { f.insert(.option) }
        if modifiers & shiftKey != 0 { f.insert(.shift) }
        if modifiers & cmdKey != 0 { f.insert(.command) }
        return f
    }

    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// What NSMenuItem.keyEquivalent needs to show this shortcut (nil if it can't be shown).
    var menuKeyEquivalent: String? {
        if let special = Self.menuSpecials[keyCode] { return String(UnicodeScalar(UInt32(special))!) }
        let name = Self.translate(keyCode)
        return name.count == 1 ? name.lowercased() : nil
    }

    private static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
                                                 kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
                                                 kVK_F18, kVK_F19, kVK_F20]
    private static let names: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
    private static let menuSpecials: [Int: Int] = [
        kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
        kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey, kVK_Space: 0x20,
    ]

    static func keyName(_ code: Int) -> String {
        if let n = names[code] { return n }
        let t = translate(code)
        return t.isEmpty ? "Key \(code)" : t.uppercased()
    }

    /// The character the key types on the current keyboard layout, without modifiers.
    static func translate(_ code: Int) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        guard status == noErr, len > 0 else { return "" }
        return String(utf16CodeUnits: chars, count: len).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Everything a global shortcut can do, with its default.
struct HotKeyAction: Identifiable, Hashable {
    let id: String
    let title: String
    let group: String
    let defaultShortcut: Shortcut?

    static let all: [HotKeyAction] = {
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let m = Shortcut.ctrlOptCmd
        var a: [HotKeyAction] = []
        a.append(HotKeyAction(id: "switcher", title: "Show desktop switcher", group: "General",
                              defaultShortcut: Shortcut(keyCode: kVK_Space, modifiers: m)))
        for (i, k) in digits.enumerated() {
            a.append(HotKeyAction(id: "send.\(i + 1)", title: "Send window to Desktop \(i + 1)", group: "Front window",
                                  defaultShortcut: Shortcut(keyCode: k, modifiers: m)))
        }
        a.append(HotKeyAction(id: "send.prev", title: "Send window to previous desktop", group: "Front window",
                              defaultShortcut: Shortcut(keyCode: kVK_LeftArrow, modifiers: m)))
        a.append(HotKeyAction(id: "send.next", title: "Send window to next desktop", group: "Front window",
                              defaultShortcut: Shortcut(keyCode: kVK_RightArrow, modifiers: m)))
        a.append(HotKeyAction(id: "send.display", title: "Send window to next display", group: "Front window",
                              defaultShortcut: Shortcut(keyCode: kVK_DownArrow, modifiers: m)))
        for (i, k) in digits.enumerated() {
            a.append(HotKeyAction(id: "sendApp.\(i + 1)", title: "Send app's windows to Desktop \(i + 1)", group: "All of the app's windows",
                                  defaultShortcut: Shortcut(keyCode: k, modifiers: m | shiftKey)))
        }
        a.append(HotKeyAction(id: "sendApp.prev", title: "Send app's windows to previous desktop", group: "All of the app's windows",
                              defaultShortcut: Shortcut(keyCode: kVK_LeftArrow, modifiers: m | shiftKey)))
        a.append(HotKeyAction(id: "sendApp.next", title: "Send app's windows to next desktop", group: "All of the app's windows",
                              defaultShortcut: Shortcut(keyCode: kVK_RightArrow, modifiers: m | shiftKey)))
        return a
    }()

    static func find(_ id: String) -> HotKeyAction? { all.first { $0.id == id } }
}

enum HotKeyBindings {
    /// The shortcut in effect for an action (nil = none).
    static func shortcut(for action: HotKeyAction, stored: [String: String] = Prefs.hotkeys) -> Shortcut? {
        guard let s = stored[action.id] else { return action.defaultShortcut }
        return s.isEmpty ? nil : Shortcut(stored: s)
    }

    static func shortcut(forID id: String) -> Shortcut? { HotKeyAction.find(id).flatMap { shortcut(for: $0) } }

    static func set(_ shortcut: Shortcut?, for action: HotKeyAction) {
        var all = Prefs.hotkeys
        if shortcut == action.defaultShortcut { all.removeValue(forKey: action.id) }
        else { all[action.id] = shortcut?.stored ?? "" }
        // Assigning a shortcut takes it away from any other action that had it.
        if let shortcut {
            for other in HotKeyAction.all where other.id != action.id && self.shortcut(for: other, stored: all) == shortcut {
                all[other.id] = ""
            }
        }
        Prefs.hotkeys = all
    }

    static func resetAll() { Prefs.hotkeys = [:] }

    /// Action ids that share a shortcut with another action.
    static func duplicates(stored: [String: String]) -> Set<String> {
        var seen: [Shortcut: String] = [:]
        var dup = Set<String>()
        for a in HotKeyAction.all {
            guard let s = shortcut(for: a, stored: stored) else { continue }
            if let first = seen[s] { dup.insert(first); dup.insert(a.id) } else { seen[s] = a.id }
        }
        return dup
    }
}

/// Global hotkeys through Carbon's RegisterEventHotKey (needs no extra permission).
final class HotKeys {
    static let shared = HotKeys()
    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false
    /// Action ids whose shortcut macOS refused (already taken by another app or the system).
    private(set) var unavailable: Set<String> = []

    @discardableResult
    func register(keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x534B4859), id: id)
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
            handlers[id] = handler
            return true
        }
        return false
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    /// Register every action's current shortcut.
    func registerActions(_ perform: @escaping (String) -> Void) {
        unregisterAll()
        unavailable = []
        for action in HotKeyAction.all {
            guard let s = HotKeyBindings.shortcut(for: action) else { continue }
            if !register(keyCode: s.keyCode, modifiers: s.modifiers, { perform(action.id) }) { unavailable.insert(action.id) }
        }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKeys.shared.handlers[hk.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
