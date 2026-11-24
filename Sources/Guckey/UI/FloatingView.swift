import SwiftUI

// MARK: - 悬浮窗尺寸约定（控制器与视图共用，避免两处硬编码漂移）

enum FloatingMetrics {
    static let width: CGFloat = 328
    /// 未展开时的固定高度：内容一像素都不动。
    static let compactHeight: CGFloat = 150
    /// 悬停时在**下方**追加的高度（够放：歌曲行 + 置信度条 + 决策说明 + 强度 + Root/Scale）。
    static let expandedExtra: CGFloat = 126
    static var expandedHeight: CGFloat { compactHeight + expandedExtra }
}

// MARK: - 悬浮窗内容

/// ⚠️ 本视图是纯渲染层：不持有 KeyDetector、不持有 MIDIController、不缓存基调。
/// 所有状态与动作都来自共享的 AppState（与主窗口同一实例）。
struct FloatingView: View {

    @EnvironmentObject private var appState: AppState
    /// 悬停展开时通知 NSPanel 调整高度（保持顶边锚定）。
    var onHeightChange: ((Bool) -> Void)?

    @State private var isHovering = false
    @State private var pulse = false

    private var sourceColor: Color { KeySourceStyle.color(appState.keySource) }

    var body: some View {
        VStack(spacing: 0) {
            compactSection
                .frame(width: FloatingMetrics.width,
                       height: FloatingMetrics.compactHeight,
                       alignment: .top)

            if isHovering {
                expandedSection
                    .frame(width: FloatingMetrics.width,
                           height: FloatingMetrics.expandedExtra,
                           alignment: .top)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .frame(width: FloatingMetrics.width, alignment: .top)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering in
            guard hovering != isHovering else { return }
            // 不包 withAnimation：布局动画会让上面的内容跟着位移，这里只要窗口向下长高。
            isHovering = hovering
            onHeightChange?(hovering)
        }
        .onAppear { pulse = true }
    }

    // MARK: 背景

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.09, green: 0.10, blue: 0.13).opacity(0.82))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(sourceColor.opacity(appState.isAnalyzing ? 0.45 : 0.30), lineWidth: 1)
        }
    }

    // MARK: 固定区（永远不动）

    private var compactSection: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        sourceIndicator
                        Text(sourceLabelText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(sourceColor)
                        Text("·").font(.system(size: 9)).foregroundColor(.secondary)
                        Text(appState.status.label)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    keyMenu
                    Text(appState.song?.title.isEmpty == false
                         ? (appState.song?.displayName ?? "")
                         : "未识别到歌曲信息")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 200, alignment: .leading)
                }
                Spacer(minLength: 2)
                VStack(spacing: 2) {
                    KnobView(value: $appState.intensity)
                        .frame(width: 70, height: 70)
                    Text("电音")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Divider().opacity(0.18)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            miniControlBar
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 8)

            Spacer(minLength: 0)
        }
    }

    // MARK: 悬停展开区（只在下方新增）

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().opacity(0.18)

            HStack(spacing: 6) {
                Image(systemName: "music.note").font(.system(size: 10))
                Text(appState.song?.displayName ?? "未识别到歌曲 / 音源")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text("置信度 \(Int(appState.confidence * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            ProgressView(value: min(1, max(0, appState.confidence)), total: 1)
                .accentColor(sourceColor)
                .frame(height: 4)

            Text(decisionLine)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 8) {
                Text("强度").font(.system(size: 10)).foregroundColor(.secondary)
                Slider(value: $appState.intensity, in: 0...100)
                Text("\(Int(appState.intensity))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                Text("Root").font(.system(size: 9)).foregroundColor(.secondary)
                Text("\(appState.rootCCValue)").font(.system(size: 9, design: .monospaced))
                Text("· Scale").font(.system(size: 9)).foregroundColor(.secondary)
                Text("\(appState.scaleCCValue)").font(.system(size: 9, design: .monospaced))
                Spacer()
                Text("CC#\(appState.mapping.macro.rootCC)/#\(appState.mapping.macro.scaleCC)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var decisionLine: String {
        if let source = appState.keySource {
            return "\(source.label) · \(source.explanation)"
        }
        if appState.stabilizerSnapshot.silenceRemaining > 0 {
            return "切歌静默中 \(String(format: "%.1f", appState.stabilizerSnapshot.silenceRemaining))s"
        }
        return appState.decisionLog.isEmpty ? "等待决策…" : appState.decisionLog
    }

    private var sourceLabelText: String {
        if appState.isAnalyzing { return "AI 分析中" }
        return appState.keySource?.label ?? "待定"
    }

    // MARK: 基调显示（点击弹出 24 调网格）

    private var keyMenu: some View {
        KeyPickerButton(fontSize: 27)
    }

    /// 来源指示灯：手动=绿、云端=蓝、AI=黄；AI 分析中带一圈脉冲。
    private var sourceIndicator: some View {
        ZStack {
            if appState.isAnalyzing {
                Circle()
                    .stroke(sourceColor.opacity(0.75), lineWidth: 1.2)
                    .frame(width: 9, height: 9)
                    .scaleEffect(pulse ? 2.1 : 0.7)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(sourceColor)
                .frame(width: 8, height: 8)
                .shadow(color: sourceColor.opacity(0.8), radius: 4)
        }
        .frame(width: 14, height: 14)
    }

    // MARK: 迷你控制条

    private var miniControlBar: some View {
        HStack(spacing: 6) {
            iconButton(appState.isDetectionPaused ? "play.fill" : "pause.fill",
                       help: appState.isDetectionPaused ? "恢复检测" : "暂停检测") {
                appState.togglePause()
            }
            iconButton("waveform", help: "切换检测模式：\(appState.detectionMode.label)") {
                appState.cycleDetectionMode()
            }
            iconButton("arrow.up.left.and.arrow.down.right", help: "展开主窗口") {
                appState.showMainWindow()
            }
            Spacer()
            Text(appState.keySource?.shortLabel ?? "WAIT")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(sourceColor)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(sourceColor.opacity(0.16)))
                .help("来源：\(sourceLabelText)")
            iconButton("xmark", help: "隐藏悬浮窗（⌥⌘K 再显示）") {
                appState.toggleFloating()
            }
        }
        .buttonStyle(.borderless)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
        }
        .help(help)
    }
}
