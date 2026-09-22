import Carbon
import RegionBlurCore

final class GlobalHotKeyRegistrar: @unchecked Sendable {
    private static let signature: OSType = 0x52424C52 // RBLR
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private let onShortcut: (AppShortcut) -> Void

    init(onShortcut: @escaping (AppShortcut) -> Void) {
        self.onShortcut = onShortcut
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let registrar = Unmanaged<GlobalHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
                return registrar.receive(event)
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    @discardableResult
    func register(_ configuration: ShortcutConfiguration) -> [AppShortcut] {
        unregisterAll()
        var failures: [AppShortcut] = []
        for command in AppShortcut.allCases {
            guard let binding = configuration.binding(for: command) else { continue }
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: Self.signature, id: command.hotKeyIdentifier)
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                carbonModifiers(binding.modifiers),
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                hotKeys.append(reference)
            } else {
                failures.append(command)
            }
        }
        return failures
    }

    private func unregisterAll() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
    }

    private func receive(_ event: EventRef) -> OSStatus {
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
        guard status == noErr,
              identifier.signature == Self.signature,
              let command = AppShortcut(hotKeyIdentifier: identifier.id) else { return OSStatus(eventNotHandledErr) }
        onShortcut(command)
        return noErr
    }

    private func carbonModifiers(_ modifiers: ShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
