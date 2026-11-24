import AppKit
import SwiftUI

// MARK: - 窗口协调器

/// 统一管理主窗口（NSWindow）与悬浮窗（NSPanel）。
/// 两者注入同一个 AppState 实例，杜绝悬浮窗内另起一套状态。
final class WindowCoordinator {

    static let shared = WindowCoordinator()

    private var floatingController: FloatingPanelController?
    private var mainWindow: NSWindow?
    private weak var appState: AppState?

    private init() {}

    func setup(appState: AppState) {
        self.appState = appState
        floatingController = FloatingPanelController(appState: appState)
        createMainWindowIfNeeded()
        applyFloatingAppearance()
        if appState.isFloatingVisible {
            floatingController?.show()
        } else {
            floatingController?.hide()
        }
    }

    func toggleFloating() {
        guard let appState, let floatingController else { return }
        appState.isFloatingVisible.toggle()
        if appState.isFloatingVisible {
            floatingController.show()
        } else {
            floatingController.hide()
        }
        applyFloatingAppearance()
    }

    func applyFloatingAppearance() {
        guard let appState else { return }
        floatingController?.applyAppearance(alwaysOnTop: appState.isAlwaysOnTop,
                                            opacity: appState.opacity)
    }

    func showMainWindow(activate: Bool = true) {
        createMainWindowIfNeeded()
        if activate { NSApp.activate(ignoringOtherApps: true) }
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func createMainWindowIfNeeded() {
        guard mainWindow == nil, let appState else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Guckey · 控制台"
        window.minSize = NSSize(width: 720, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: MainWindowView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .frame(minWidth: 720, minHeight: 520)
        )
        mainWindow = window
    }
}
