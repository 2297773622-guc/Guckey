import AppKit
import SwiftUI

// MARK: - App 入口（纯 AppKit 生命周期 + SwiftUI 视图）

/// 采用 AppDelegate 而不是 SwiftUI WindowGroup，是为了对 NSPanel 的
/// level / collectionBehavior / 位置与尺寸拥有完全控制权。
/// 主窗口与悬浮窗都是 NSHostingView，共用 appState 一个实例。
@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// NSApplication.delegate 是 assign（非 strong），必须自己持有强引用，
    /// 否则 delegate 会在 run() 之前就被释放。
    private static var retainedDelegate: AppDelegate?

    /// ⚠️ 关键点：SwiftPM 可执行目标用 -parse-as-library 编译，
    /// 编译器为 @main 合成的入口 **不会** 把本类挂成 NSApplication 的 delegate，
    /// applicationDidFinishLaunching 永远不会被调用（进程活着但零窗口）。
    /// 因此这里显式实现 main()：创建 NSApp → 挂 delegate → run()。
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    private let appState = AppState()
    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private var supportWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
        WindowCoordinator.shared.setup(appState: appState)
        WindowCoordinator.shared.showMainWindow(activate: true)
        setupStatusItem()
        setupHotKey()
        appState.bootstrap()
    }

    /// 关掉主窗口不退出 App —— 悬浮窗是常驻工具，主窗口只是控制台。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
        appState.shutdown()
    }

    // MARK: 菜单栏

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = appMenu.addItem(withTitle: "关于 Guckey",
                                    action: #selector(showAboutPanel(_:)),
                                    keyEquivalent: "")
        about.target = self
        let support = appMenu.addItem(withTitle: "联系支持…",
                                      action: #selector(showSupport(_:)),
                                      keyEquivalent: "")
        support.target = self
        appMenu.addItem(NSMenuItem.separator())
        let quit = appMenu.addItem(withTitle: "退出 Guckey",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q")
        quit.target = NSApp
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        let toggle = windowMenu.addItem(withTitle: "显示 / 隐藏悬浮窗  ⌥⌘K",
                                        action: #selector(toggleFloating(_:)),
                                        keyEquivalent: "")
        toggle.target = self
        let openMain = windowMenu.addItem(withTitle: "打开控制台",
                                          action: #selector(openMainWindow(_:)),
                                          keyEquivalent: "")
        openMain.target = self
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = Self.statusBarIcon()
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.toolTip = "Guckey · 基调遥控"

        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: "显示 / 隐藏悬浮窗",
                                  action: #selector(toggleFloating(_:)),
                                  keyEquivalent: "")
        toggle.target = self
        let openMain = menu.addItem(withTitle: "打开控制台",
                                    action: #selector(openMainWindow(_:)),
                                    keyEquivalent: "")
        openMain.target = self
        menu.addItem(NSMenuItem.separator())
        let quit = menu.addItem(withTitle: "退出",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "")
        quit.target = NSApp
        statusItem?.menu = menu
    }

    /// 菜单栏图标：字母 G（圆体）。
    ///
    /// 用 template 图（单色 + alpha）而不是彩色图 —— 系统会按菜单栏明暗自动着色，
    /// 深浅色模式下都不会出现"一块突兀的彩块"。
    /// 手写体（Snell / Bradley Hand）在 18pt 下笔画会粘连，所以用系统圆体：
    /// 干净、和菜单栏其他符号同一套骨架。
    private static func statusBarIcon() -> NSImage {
        let pointSize = NSSize(width: 20, height: 18)
        let image = NSImage(size: pointSize)

        // 先给 2x 再给 1x：Retina 上优先用高分辨率那张，缩小时更细腻。
        for scale in [CGFloat(2), CGFloat(1)] {
            let pixels = NSSize(width: pointSize.width * scale, height: pointSize.height * scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: Int(pixels.width),
                                             pixelsHigh: Int(pixels.height),
                                             bitsPerSample: 8,
                                             samplesPerPixel: 4,
                                             hasAlpha: true,
                                             isPlanar: false,
                                             colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0,
                                             bitsPerPixel: 0) else { continue }
            rep.size = pointSize

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: pixels).fill()

            let base = NSFont.systemFont(ofSize: 16 * scale, weight: .bold)
            let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,
                              size: 16 * scale) ?? base
            let text = "G" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let textSize = text.size(withAttributes: attributes)
            // 字母的基线视觉上偏低，整体提 0.5pt 才在菜单栏里居中。
            let origin = NSPoint(x: (pixels.width - textSize.width) / 2,
                                 y: (pixels.height - textSize.height) / 2 + 0.5 * scale)
            text.draw(at: origin, withAttributes: attributes)

            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }

        image.isTemplate = true
        return image
    }

    private func setupHotKey() {
        let key = GlobalHotKey()
        key.register { [weak self] in
            guard self != nil else { return }
            WindowCoordinator.shared.toggleFloating()
        }
        hotKey = key
    }

    @objc private func toggleFloating(_ sender: Any?) {
        WindowCoordinator.shared.toggleFloating()
    }

    // MARK: 关于

    /// 标准「关于」面板 + 自定义 credits：明确写出开发者与 copyright。
    /// 版本号来自 Info.plist（CFBundleShortVersionString / CFBundleVersion）。
    @objc private func showAboutPanel(_ sender: Any?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 3

        // copyright 由 Info.plist 的 NSHumanReadableCopyright 提供（面板底部那行），
        // 这里只放开发者和一句话说明，避免重复出现同一行版权。
        let credits = NSMutableAttributedString(
            string: "开发者：顾初",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )
        credits.append(NSAttributedString(
            string: "\n\n三级基调决策（手动 → 云端曲库 → AI 实时分析），\n通过虚拟 MIDI 源驱动修音插件。",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph
            ]
        ))

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Guckey",
            .credits: credits
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 联系支持

    @objc private func showSupport(_ sender: Any?) {
        if let window = supportWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SupportView { [weak self] in self?.supportWindow?.close() }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "联系支持"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        supportWindow = window
    }

    @objc private func openMainWindow(_ sender: Any?) {
        WindowCoordinator.shared.showMainWindow()
    }
}
