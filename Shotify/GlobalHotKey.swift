//
//  GlobalHotKey.swift
//  Shotify
//

import AppKit
import Carbon.HIToolbox

/// System-wide hotkey backed by Carbon's RegisterEventHotKey.
/// Unlike NSEvent global monitors, this needs no Accessibility permission.
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandlerRef: EventHandlerRef?
    private static var nextID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: A virtual key code (e.g. `kVK_ANSI_9`).
    ///   - modifiers: Carbon modifier flags (e.g. `cmdKey | shiftKey`).
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installEventHandlerIfNeeded()

        id = Self.nextID
        Self.nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x5348_4F54), id: id) // 'SHOT'
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            print("📸 Shotify: Failed to register hotkey (status \(status))")
            return nil
        }
        Self.handlers[id] = action
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        Self.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            // Carbon delivers hotkey events on the main thread
            MainActor.assumeIsolated {
                GlobalHotKey.handlers[hotKeyID.id]?()
            }
            return noErr
        }, 1, &eventType, nil, &eventHandlerRef)
    }
}
