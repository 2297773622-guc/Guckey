import AppKit

// MARK: - 悬浮窗 NSPanel 子类

/// 常驻屏幕顶层、跨 Space、全屏可覆盖、无标题栏、可拖拽背景移动。
/// 只承载 SwiftUI 视图（NSHostingView），不含任何检测 / MIDI 业务逻辑。
final class FloatingPanel: NSPanel {

    override var canBecomeKey: Bool { true }     // 允许 Menu / 输入框获得键盘焦点
    override var canBecomeMain: Bool { false }   // 不抢主窗口身份

    init(width: CGFloat, height: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        level = .floating
        // 跨 Space + 全屏辅助：唱歌 / 直播时即使 DAW 全屏也能看到基调
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // 拖动由宿主（NSWindow）原生负责：在面板空白处按住即可移动。
        // 旋钮用独立 NSView 接管 mouseDown（不调用 super），事件不会冒泡到这里，
        // 所以拨旋钮只改数值，不会把整个悬浮窗拖走。
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        animationBehavior = .utilityWindow
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)   // Esc 收起悬浮窗
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            orderOut(nil)
            return
        }
        super.keyDown(with: event)
    }
}
