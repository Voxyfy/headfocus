import Carbon
import Foundation

/// Küresel klavye kısayolları. Carbon'un RegisterEventHotKey'i erişilebilirlik
/// izni istemiyor; NSEvent'in küresel izleyicisi istiyordu.
final class HotKeys {
    struct Key {
        let id: UInt32
        let code: UInt32
        let modifiers: UInt32
        let label: String
    }

    static let focus = Key(id: 1, code: 3, modifiers: UInt32(controlKey | optionKey), label: "⌃⌥F")     // F
    static let blur = Key(id: 2, code: 11, modifiers: UInt32(controlKey | optionKey), label: "⌃⌥B")     // B
    static let recenter = Key(id: 3, code: 15, modifiers: UInt32(controlKey | optionKey), label: "⌃⌥R") // R
    static let stats = Key(id: 4, code: 1, modifiers: UInt32(controlKey | optionKey), label: "⌃⌥S")     // S

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            me.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    func register(_ key: Key, handler: @escaping () -> Void) {
        handlers[key.id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4846_4B53), id: key.id) // 'HFKS'
        RegisterEventHotKey(key.code, key.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    func unregisterAll() {
        refs.forEach { if let r = $0 { UnregisterEventHotKey(r) } }
        refs = []
        handlers = [:]
    }
}
