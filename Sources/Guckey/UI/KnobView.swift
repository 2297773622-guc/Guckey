import SwiftUI
import AppKit

// MARK: - 电音强度旋钮（悬浮窗第一优先级控件）

/// 三种交互都能调 0-100%：
/// - 鼠标滚轮：向上 / 向前滚增大，向下减小；
/// - 拖动：向右 / 向上增大，向左 / 向下减小；
/// - 数值直接绑定共享 AppState.intensity，didSet 负责映射成 CC 发出去。
///
/// 鼠标事件由内嵌的 NSView 全权处理：既拿到 scrollWheel，又阻止拖动冒泡到窗口，
/// 所以拨这个旋钮绝不会把整个悬浮窗拖走。
struct KnobView: View {
    @Binding var value: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 7)

            Circle()
                .stroke(
                    AngularGradient(gradient: Gradient(colors: [
                        Color(red: 0.36, green: 0.85, blue: 0.95),
                        Color(red: 0.55, green: 0.45, blue: 0.98),
                        Color(red: 0.36, green: 0.85, blue: 0.95)
                    ]), center: .center),
                    lineWidth: 7
                )
                .opacity(0.95)

            // 指针：-135° → +135°
            Capsule()
                .fill(Color.white)
                .frame(width: 3, height: 13)
                .offset(y: -24)
                .rotationEffect(.degrees(-135 + 270 * value / 100))

            VStack(spacing: 0) {
                Text("\(Int(value))")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(4)
        .contentShape(Circle())
        .overlay(
            KnobInteractionLayer { delta in
                value = min(max(value + delta, 0), 100)
            }
        )
        .help("滚轮或拖动调节电音强度（向右 / 向上增大）")
        .accessibilityLabel("电音强度")
        .accessibilityValue("\(Int(value))%")
    }
}

// MARK: - 滚轮 / 拖动 事件层

private struct KnobInteractionLayer: NSViewRepresentable {
    let onDelta: (Double) -> Void

    func makeNSView(context: Context) -> KnobTrackingView {
        let view = KnobTrackingView()
        view.onDelta = onDelta
        return view
    }

    func updateNSView(_ nsView: KnobTrackingView, context: Context) {
        nsView.onDelta = onDelta
    }
}

/// 只负责把滚轮 / 拖动换算成「百分比增量」，不参与绘制。
final class KnobTrackingView: NSView {

    var onDelta: ((Double) -> Void)?
    private var lastPoint: NSPoint?

    /// 每像素拖动对应的百分比：70pt 的旋钮拖 ~140pt 走完 0-100%。
    private let dragSensitivity: Double = 0.7
    /// 滚轮灵敏度：精确滚动（触控板）小步，普通滚轮按行放大。
    private let preciseScrollSensitivity: Double = 1.6
    private let lineScrollSensitivity: Double = 4.0

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// 关键：NSView 默认允许「拖动本视图即移动窗口」，
    /// 这会让面板的 background drag 抢走旋钮的拖动（表现为拨旋钮把窗口拖走）。
    override var mouseDownCanMoveWindow: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        var deltaY = event.scrollingDeltaY
        // 系统「自然滚动」会反转方向，这里归一化成「向上滚 = 增大」。
        if event.isDirectionInvertedFromDevice { deltaY = -deltaY }
        let scale = event.hasPreciseScrollingDeltas ? preciseScrollSensitivity : lineScrollSensitivity
        guard deltaY != 0 else { return }
        onDelta?(Double(deltaY) * scale)
    }

    override func mouseDown(with event: NSEvent) {
        // 不调用 super：避免点击 / 拖动冒泡到窗口拖动。
        lastPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        lastPoint = point
        // AppKit 坐标 y 向上，所以 (dx + dy) 就是「向右 / 向上增大」。
        let delta = Double((point.x - last.x) + (point.y - last.y))
        guard delta != 0 else { return }
        onDelta?(delta * dragSensitivity)
    }

    override func mouseUp(with event: NSEvent) {
        lastPoint = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
