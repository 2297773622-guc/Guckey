import AppKit
import SwiftUI

// MARK: - 悬浮窗控制器（位置持久化 / 外观 / 悬停展开）

final class FloatingPanelController: NSObject, NSWindowDelegate {

    private let panel: FloatingPanel
    private let appState: AppState
    private let width: CGFloat = FloatingMetrics.width
    private let compactHeight: CGFloat = FloatingMetrics.compactHeight
    /// 展开时在下方追加的高度：原有内容固定不动，只向下长出新区域。
    private let expandedExtra: CGFloat = FloatingMetrics.expandedExtra
    private var currentHeight: CGFloat

    init(appState: AppState) {
        self.appState = appState
        self.panel = FloatingPanel(width: FloatingMetrics.width, height: FloatingMetrics.compactHeight)
        self.currentHeight = FloatingMetrics.compactHeight
        super.init()

        let root = FloatingView { [weak self] expanded in
            self?.resize(expanded: expanded)
        }
        .environmentObject(appState)
        .preferredColorScheme(.dark)

        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // 只钉住上边：内容永远贴窗口顶部，窗口向下变高时上面的部分不会重新居中或上移。
        hosting.setContentHuggingPriority(.required, for: .vertical)
        hosting.setContentCompressionResistancePriority(.required, for: .vertical)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: compactHeight))
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        panel.contentView = container
        panel.delegate = self
        panel.setContentSize(NSSize(width: width, height: compactHeight))
        restoreOrSetDefaultFrame()
    }

    // MARK: 显隐

    func show() {
        applyAppearance(alwaysOnTop: appState.isAlwaysOnTop, opacity: appState.opacity)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    var isVisible: Bool { panel.isVisible }

    // MARK: 外观

    func applyAppearance(alwaysOnTop: Bool, opacity: Double) {
        panel.level = alwaysOnTop ? .floating : .normal
        panel.alphaValue = CGFloat(opacity)
    }

    /// 鼠标悬停时在**下方**追加歌曲名 / 置信度 / 精度滑块。
    /// 顶边锚定 + 不播放位移动画：原有内容一个像素都不动，只是窗口向下变高。
    private func resize(expanded: Bool) {
        let target = expanded ? compactHeight + expandedExtra : compactHeight
        guard abs(target - currentHeight) > 1 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.origin.y = top - target
        frame.size.height = target
        currentHeight = target
        panel.setFrame(frame, display: true, animate: false)
    }

    // MARK: 位置持久化

    private func restoreOrSetDefaultFrame() {
        if let saved = SettingsStore.shared.floatingFrame,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            var frame = saved
            frame.size.width = width
            frame.size.height = currentHeight
            panel.setFrame(frame, display: false)
            return
        }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.maxX - width - 24,
                             y: visible.maxY - currentHeight - 24)
        panel.setFrameOrigin(origin)
    }

    func windowDidMove(_ notification: Notification) { schedulePersist() }
    func windowDidResize(_ notification: Notification) { schedulePersist() }

    private func schedulePersist() {
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                               selector: #selector(persistFrame),
                                               object: nil)
        perform(#selector(persistFrame), with: nil, afterDelay: 0.4)
    }

    @objc private func persistFrame() {
        // 只存**折叠态**的 frame：否则悬停时保存了 276 高度，
        // 下次启动会以一个「展开」的框恢复，看起来像悬浮窗莫名其妙变高、上移。
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: width, height: compactHeight)
        frame.origin.y = top - compactHeight
        SettingsStore.shared.floatingFrame = frame
    }
}
