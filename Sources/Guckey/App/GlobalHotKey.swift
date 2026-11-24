import AppKit
import Carbon.HIToolbox

// MARK: - 全局快捷键 ⌥⌘K

/// 用 Carbon RegisterEventHotKey 实现真正的全局快捷键（无需输入监控权限即可抢占组合键）。
/// Carbon HotKey API 虽被标记 deprecated，但至今在 macOS 15 / Apple Silicon 上仍是
/// 唯一无需辅助功能授权即可稳定工作的系统级方案，Apple 未提供现代替代 API。
///
/// 若注册失败（例如组合键被系统占用），退化为 NSEvent 全局监听，
/// 此时需要用户在「输入监控 / 辅助功能」里授权，UI 会给出提示。
final class GlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var monitor: Any?
    private var callback: (() -> Void)?

    /// 'VTAK'
    private let signature = OSType(0x5654_414B)

    func register(keyCode: UInt32 = UInt32(kVK_ANSI_K),
                  modifiers: UInt32 = UInt32(cmdKey | optionKey),
                  handler: @escaping () -> Void) {
        callback = handler

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let upp: EventHandlerUPP = { _, event, data -> OSStatus in
            guard let data else { return noErr }
            let target = Unmanaged<GlobalHotKey>.fromOpaque(data).takeUnretainedValue()
            // 校验 HotKeyID，避免把别的快捷键事件误当成自己的
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            if status == noErr && hotKeyID.signature == target.signature {
                DispatchQueue.main.async { target.callback?() }
            }
            return noErr
        }

        let installStatus = InstallEventHandler(GetApplicationEventTarget(), upp, 1,
                                                &spec, userData, &eventHandlerRef)
        guard installStatus == noErr else { return fallbackGlobalMonitor(keyCode: keyCode,
                                                                         modifiers: modifiers) }

        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                                 GetApplicationEventTarget(), 0, &hotKeyRef)
        if registerStatus != noErr {
            fallbackGlobalMonitor(keyCode: keyCode, modifiers: modifiers)
        }
    }

    private func fallbackGlobalMonitor(keyCode: UInt32, modifiers: UInt32) {
        // 兜底：需要「输入监控」权限，且不会抢占其他 App 已注册的同组合键。
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard UInt32(event.keyCode) == keyCode else { return }
            let wanted = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
            if event.modifierFlags.intersection([.command, .option]) == wanted.intersection([.command, .option]) {
                DispatchQueue.main.async { self?.callback?() }
            }
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        if let monitor { NSEvent.removeMonitor(monitor) }
        hotKeyRef = nil
        eventHandlerRef = nil
        monitor = nil
        callback = nil
    }

    deinit { unregister() }
}
