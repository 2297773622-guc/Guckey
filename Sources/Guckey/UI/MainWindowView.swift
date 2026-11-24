import SwiftUI

// MARK: - 基调来源配色（悬浮窗与主窗口共用）

enum KeySourceStyle {
    static func color(_ source: KeySource?) -> Color {
        switch source {
        case .manual: return Color(red: 0.30, green: 0.86, blue: 0.46)   // 绿
        case .cloud: return Color(red: 0.36, green: 0.64, blue: 1.00)    // 蓝
        case .ai: return Color(red: 1.00, green: 0.78, blue: 0.24)       // 黄
        case nil: return Color.gray
        }
    }

    static func label(_ source: KeySource?) -> String {
        source?.label ?? "未定"
    }
}

// MARK: - 主窗口

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            OverviewTab()
                .tabItem { Label("概览", systemImage: "waveform.and.magnifyingglass") }
            CloudLibraryView()
                .tabItem { Label("云端库", systemImage: "cloud") }
            MacroControlView()
                .tabItem { Label("宏控制", systemImage: "dial.min") }
            MappingEditorView()
                .tabItem { Label("MIDI 映射", systemImage: "slider.horizontal.3") }
            StudioOneGuideView()
                .tabItem { Label("指南", systemImage: "book") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .padding(14)
        .frame(minWidth: 880, minHeight: 600)
    }
}

// MARK: - 概览

private struct OverviewTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Guckey · 基调遥控")
                        .font(.title2.bold())
                    Text("手动记录 → 云端曲库 → AI 实时分析；结果通过 MIDI 驱动修音插件。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    keyCard
                    sourceCard
                    controlCard
                }
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            logPanel
                .frame(width: 290)
        }
    }

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前基调").font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 10) {
                        KeyPickerButton(fontSize: 34)
                        SourceBadge(source: appState.keySource, analyzing: appState.isAnalyzing)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(appState.status.label).font(.caption)
                    }
                    Text("置信度 \(Int(appState.confidence * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            ProgressView(value: min(1, max(0, appState.confidence)), total: 1)
                .accentColor(KeySourceStyle.color(appState.keySource))

            HStack(spacing: 6) {
                Image(systemName: "music.note").foregroundColor(.secondary)
                Text(appState.song?.displayName ?? "未识别到歌曲 / 音源")
                    .font(.caption).lineLimit(1)
                Spacer()
                Text("点击基调可手动更正")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.045)))
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("三级决策").font(.headline)

            ForEach(KeySource.allCases) { source in
                HStack(spacing: 8) {
                    Circle()
                        .fill(KeySourceStyle.color(source))
                        .frame(width: 8, height: 8)
                        .opacity(appState.keySource == source ? 1 : 0.25)
                    Text("\(source.priority + 1). \(source.label)")
                        .font(.caption.weight(appState.keySource == source ? .semibold : .regular))
                        .frame(width: 76, alignment: .leading)
                    Text(source.explanation)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }

            Text(appState.decisionLog)
                .font(.caption2.monospaced())
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !appState.decisionDetail.isEmpty {
                Text(appState.decisionDetail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text("媒体来源：\(appState.mediaSourceLabel)")
                    .font(.caption2).foregroundColor(.secondary)
                Button("刷新媒体信息") { appState.refreshMedia() }
                    .font(.caption2)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.045)))
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("电音强度").font(.headline)
                Spacer()
                Text("\(Int(appState.intensity))%  →  CC#\(appState.mapping.intensity.ccNumber) = \(KeyMIDIMapper.intensityCCValue(percent: appState.intensity, mapping: appState.mapping))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: $appState.intensity, in: 0...100)

            HStack(spacing: 10) {
                Picker("检测模式", selection: Binding(
                    get: { appState.detectionMode },
                    set: { appState.setDetectionMode($0) }
                )) {
                    ForEach(DetectionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button(appState.isDetectionPaused ? "恢复检测" : "暂停检测") {
                    appState.togglePause()
                }
                Button("显示 / 隐藏悬浮窗") { appState.toggleFloating() }
                Button("重申基调") { appState.reapplyKey() }
            }
            .font(.caption)

            if let message = appState.lastMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.045)))
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MIDI 事件 / 日志").font(.headline)
                Spacer()
                Button("清空") { appState.midiLog.removeAll() }
                    .font(.caption)
                    .buttonStyle(.plain)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(appState.midiLog, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(line.contains("⚠️") ? .orange : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.22)))
        }
    }

    private var statusColor: Color {
        switch appState.status {
        case .detecting: return .yellow
        case .synced: return .green
        case .midiError: return .red
        case .paused: return .gray
        }
    }
}

// MARK: - 来源徽标（带 AI 脉冲）

struct SourceBadge: View {
    let source: KeySource?
    let analyzing: Bool

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                if analyzing {
                    Circle()
                        .stroke(KeySourceStyle.color(source).opacity(0.6), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                        .scaleEffect(pulse ? 1.8 : 0.6)
                        .opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
                }
                Circle()
                    .fill(KeySourceStyle.color(source))
                    .frame(width: 7, height: 7)
            }
            .frame(width: 16, height: 16)
            .onAppear { pulse = true }
            .onChange(of: analyzing) { newValue in pulse = newValue }

            Text(analyzing && source == .ai ? "AI 分析中" : KeySourceStyle.label(source))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(KeySourceStyle.color(source))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(KeySourceStyle.color(source).opacity(0.14)))
    }
}
