//  Hotkey.swift — ⌥⌘G from anywhere.
//
//  Carbon's RegisterEventHotKey, which needs no accessibility or input-monitoring
//  permission (unlike an event tap) and is what every Mac launcher uses.

import AppKit
import Carbon.HIToolbox

final class Hotkey {
    static let shared = Hotkey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    func register(_ action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            Unmanaged<Hotkey>.fromOpaque(ctx).takeUnretainedValue().action?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x47424C4E) /* GBLN */, id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil; handler = nil
    }
}
