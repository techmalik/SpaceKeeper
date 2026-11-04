import Cocoa
import Carbon.HIToolbox

/// Global hotkeys through Carbon's RegisterEventHotKey (needs no extra permission).
final class HotKeys {
    static let shared = HotKeys()
    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false

    func register(keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
        installIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x534B4859), id: id)
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
            handlers[id] = handler
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
