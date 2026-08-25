import AppKit
import Carbon.HIToolbox

/// The shortcut that summons the recall panel. A small fixed set instead of a
/// half-finished shortcut recorder.
enum RecallShortcut: String, CaseIterable, Identifiable {
    case off
    case optionSpace
    case commandOptionSpace
    case controlOptionSpace

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Off"
        case .optionSpace: "⌥Space"
        case .commandOptionSpace: "⌘⌥Space"
        case .controlOptionSpace: "⌃⌥Space"
        }
    }

    var carbonModifiers: UInt32? {
        switch self {
        case .off: nil
        case .optionSpace: UInt32(optionKey)
        case .commandOptionSpace: UInt32(cmdKey | optionKey)
        case .controlOptionSpace: UInt32(controlKey | optionKey)
        }
    }

    var keyCode: UInt32 { UInt32(kVK_Space) }

    static let defaultsKey = "recallShortcut"
}

private let mnemosHotKeySignature = OSType(0x4D_4E_4D_53) // 'MNMS'

extension Notification.Name {
    static let mnemosRecallHotKey = Notification.Name("dev.mnemos.recallHotKey")
}

/// Registers the recall shortcut with Carbon, which is still the supported way
/// to get a system-wide hot key without extra entitlements.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private init() {}

    func apply(_ shortcut: RecallShortcut) {
        unregister()
        guard let modifiers = shortcut.carbonModifiers else { return }
        installHandlerIfNeeded()

        var identifier = EventHotKeyID(signature: mnemosHotKeySignature, id: 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        _ = identifier
        if status == noErr {
            hotKeyRef = reference
        } else {
            NSLog("Mnemos: unable to register the recall shortcut (\(status))")
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr, identifier.signature == mnemosHotKeySignature else { return noErr }
                NotificationCenter.default.post(name: .mnemosRecallHotKey, object: nil)
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }
}
