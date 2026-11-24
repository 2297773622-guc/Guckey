import SwiftUI

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var sourceNameDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("设置").font(.title2.bold())

                GroupBox(label: Label("悬浮窗", systemImage: "macwindow.on.rectangle")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("常驻屏幕顶层", isOn: Binding(
                            get: { appState.isAlwaysOnTop },
                            set: { appState.isAlwaysOnTop = $0 }
                        ))
                        Toggle("显示悬浮窗", isOn: Binding(
                            get: { appState.isFloatingVisible },
                            set: { newValue in
                                if newValue != appState.isFloatingVisible { appState.toggleFloating() }
                            }
                        ))
                        HStack {
                            Text("透明度").frame(width: 70, alignment: .leading)
                            Slider(value: Binding(
                                get: { appState.opacity },
                                set: { appState.opacity = $0 }
                            ), in: 0.35...1.0)
                            Text("\(Int(appState.opacity * 100))%")
                                .font(.caption.monospacedDigit())
                                .frame(width: 42)
                        }
                        Text("⌥⌘K 显示 / 隐藏；拖拽背景移动，位置自动保存，跨 Space 与全屏可见。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(8)
                }

                GroupBox(label: Label("检测", systemImage: "waveform")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("检测模式", selection: Binding(
                            get: { appState.detectionMode },
                            set: { appState.setDetectionMode($0) }
                        )) {
                            ForEach(DetectionMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Toggle("演示模式（模拟检测，无权限时调试 UI）", isOn: Binding(
                            get: { appState.demoMode },
                            set: { appState.demoMode = $0 }
                        ))
                        Text("AI 实时输入需「麦克风」权限；伴奏播放器优先 ScreenCaptureKit 系统音频（需「屏幕录制」权限），失败自动降级 BlackHole。")
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                }

                GroupBox(label: Label("AI 分析调参", systemImage: "waveform.badge.magnifyingglass")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("一般不用动。AI 抢锁太快、切歌乱跳时才需要调。")
                            .font(.caption2).foregroundColor(.secondary)
                        DisclosureGroup("展开参数") {
                            StabilizerView(embedded: true)
                                .padding(.top, 8)
                        }
                        .font(.caption)
                    }
                    .padding(8)
                }

                GroupBox(label: Label("虚拟 MIDI 源", systemImage: "cable.connector")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("虚拟源名称", text: $sourceNameDraft)
                                .textFieldStyle(.roundedBorder)
                            Button("应用并重建") { appState.updateVirtualSourceName(sourceNameDraft) }
                        }
                        Text("在 Studio One「选项 → 外部设备 → 添加新建键盘」里把「接收自」选为「\(appState.mapping.virtualSourceName)」、通道勾 1，再把这套 CC 学到宏控制旋钮上。")
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("立即重申基调与强度") {
                            appState.reapplyKey()
                            appState.sendIntensity(force: true)
                        }
                    }
                    .padding(8)
                }
            }
            .padding(.horizontal, 4)
        }
        .onAppear { sourceNameDraft = appState.mapping.virtualSourceName }
    }
}
