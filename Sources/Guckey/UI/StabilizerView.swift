import SwiftUI

// MARK: - AI 分析调参

/// 默认嵌在「设置 → AI 分析调参」里（`embedded = true`，不带标题与滚动容器）。
struct StabilizerView: View {
    var embedded: Bool = false

    @EnvironmentObject private var appState: AppState
    @State private var draft = StabilizerConfig.default
    @State private var didLoad = false

    var body: some View {
        if embedded {
            content
        } else {
            ScrollView {
                content
                    .padding(.bottom, 16)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: embedded ? 12 : 16) {
            if !embedded { header }
            liveCard
            windowCard
            hysteresisCard
            bandCard
            footer
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            draft = appState.stabilizerConfig
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AI 分析调参").font(.title2.bold())
            Text("只影响 AI 实时分析这一级；手动和云端命中后直接锁定，不走这里。")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var liveCard: some View {
        let snap = appState.stabilizerSnapshot
        return GroupBox(label: Label("实时状态", systemImage: "dot.radiowaves.left.and.right")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    metric("窗口样本", "\(snap.sampleCount)")
                    metric("主导调", snap.dominantKey?.displayName ?? "—")
                    metric("占比", String(format: "%.0f%%", snap.dominantRatio * 100))
                    metric("置信度", String(format: "%.2f", snap.dominantConfidence))
                    metric("静默剩余", String(format: "%.1fs", snap.silenceRemaining))
                    Spacer()
                }
                if let pending = snap.pendingKey {
                    Text("迟滞计时：\(pending.displayName) 已保持 \(String(format: "%.1f", snap.pendingSeconds))s / \(String(format: "%.0f", draft.switchHoldSeconds))s")
                        .font(.caption2).foregroundColor(KeySourceStyle.color(.ai))
                }
                if !snap.distribution.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(Array(snap.distribution.enumerated()), id: \.offset) { _, item in
                            HStack(spacing: 3) {
                                Text(item.key.displayName).font(.caption2)
                                Text(String(format: "%.0f%%", item.ratio * 100))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding(6)
        }
    }

    private var windowCard: some View {
        GroupBox(label: Label("滑动窗口防抖", systemImage: "square.stack.3d.up")) {
            VStack(alignment: .leading, spacing: 10) {
                sliderRow("窗口长度", value: $draft.windowSeconds, range: 4...30, step: 1, unit: "s",
                          note: "维护最近 N 秒的逐帧调性，窗口越长越稳但越迟钝")
                sliderRow("占比阈值", value: $draft.dominanceRatio, range: 0.3...0.95, step: 0.05, unit: "",
                          note: "某调性在窗口内占比超过此值才允许输出（默认 60%）")
                sliderRow("置信度下限", value: $draft.minConfidence, range: 0.3...0.95, step: 0.05, unit: "",
                          note: "Krumhansl 相关系数低于此值的单帧直接丢弃（默认 0.70）")
                HStack(spacing: 8) {
                    Text("首次锁定的最少样本数").font(.caption)
                    Spacer()
                    Stepper("\(draft.minSamplesForLock)", value: $draft.minSamplesForLock, in: 3...30)
                        .font(.caption.monospacedDigit())
                }
                Text("样本太少时占比容易虚高（2 帧里 2 帧同调就是 100%），默认 6 帧。")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(6)
        }
    }

    private var hysteresisCard: some View {
        GroupBox(label: Label("迟滞锁与启动静默", systemImage: "lock.rotation")) {
            VStack(alignment: .leading, spacing: 10) {
                sliderRow("保持时长", value: $draft.switchHoldSeconds, range: 1...10, step: 0.5, unit: "s",
                          note: "新调性必须连续保持这么久才允许切换（默认 3s）")
                sliderRow("置信度优势", value: $draft.switchConfidenceMargin, range: 0...0.5, step: 0.01, unit: "",
                          note: "新调性置信度需高出当前调性这个比例（默认 0.15 = 15%）")
                sliderRow("启动静默", value: $draft.startupSilenceSeconds, range: 0...15, step: 1, unit: "s",
                          note: "切歌后这段时间内不发送任何基调 CC（默认 6s）")
            }
            .padding(6)
        }
    }

    private var bandCard: some View {
        GroupBox(label: Label("分析频段（带通）", systemImage: "waveform.path.ecg")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下限 \(Int(draft.bandLowHz)) Hz").font(.caption)
                        Slider(value: $draft.bandLowHz, in: 30...200, step: 5)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("上限 \(Int(draft.bandHighHz)) Hz").font(.caption)
                        Slider(value: $draft.bandHighHz, in: 200...2000, step: 10)
                    }
                }
                Text("频域带通：只统计带内谐波，聚焦和弦与贝斯（默认 60–500 Hz）。下限过低会被底鼓干扰，上限过高会被人声颤音干扰。")
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("应用") { appState.updateStabilizerConfig(draft) }
                .buttonStyle(.borderedProminent)
            Button("恢复默认") {
                appState.resetStabilizerConfig()
                draft = .default
            }
            Spacer()
            Text("改动只影响第三级；调完立刻生效，无需重启。")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: 组件

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double, unit: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(unit.isEmpty && step < 1
                     ? String(format: "%.2f", value.wrappedValue)
                     : "\(Int(value.wrappedValue))\(unit)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range, step: step)
            Text(note).font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
