import SwiftUI

// MARK: - MIDI 输出映射

/// 单一方案：基调用两条 CC 驱动宏控制器的 Root / Scale 旋钮；强度用一条 CC。
/// 编辑 draft 副本，点「保存映射」才写入共享 AppState 并持久化。
struct MappingEditorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var draft: MIDIMapping = .default

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("MIDI 输出映射").font(.title2.bold())
                    Text("基调 → Root / Scale 两条 CC → Studio One 宏控制器的两个旋钮；强度 → 独立一条 CC。")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    macroSection
                    intensitySection
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }

            Divider().padding(.vertical, 8)
            HStack {
                Text("修改后需保存才会生效")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("重置为默认") { draft = .default }
                Button("保存映射") {
                    appState.mapping = draft
                    appState.commitMapping()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { draft = appState.mapping }
    }

    // MARK: 宏控制

    private var macroSection: some View {
        GroupBox(label: Label("基调 → 宏控制旋钮", systemImage: "dial.min")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    Stepper("Root CC 编号 \(draft.macro.rootCC)", value: $draft.macro.rootCC, in: 0...127)
                    Stepper("Scale CC 编号 \(draft.macro.scaleCC)", value: $draft.macro.scaleCC, in: 0...127)
                    Stepper("旋钮通道 \(draft.macro.channel)", value: $draft.macro.channel, in: 1...16)
                }

                Toggle("16 通道广播（备选；打开后 MIDI 学习会看到 16 个重复旋钮）",
                       isOn: Binding(
                        get: { appState.broadcastAllChannels },
                        set: { appState.broadcastAllChannels = $0 }
                       ))

                HStack(spacing: 18) {
                    Stepper("低档 CC \(draft.macro.rootLow)", value: $draft.macro.rootLow, in: 0...127)
                    Stepper("高档 CC \(draft.macro.rootHigh)", value: $draft.macro.rootHigh, in: 0...127)
                    Stepper("档位数 \(draft.macro.rootSteps)", value: $draft.macro.rootSteps, in: 2...24)
                }

                Toggle("同时发送 Scale（关掉则只驱动 Root 旋钮）", isOn: $draft.macro.sendScale)

                HStack(spacing: 18) {
                    Stepper("调式参数总数 \(draft.macro.scaleSteps)", value: Binding(
                        get: { draft.macro.scaleSteps },
                        set: { count in
                            draft.macro.scaleSteps = count
                            draft.macro.majorValue = KeyMIDIMapper.majorScaleValue(
                                steps: count, low: draft.macro.scaleLow, high: draft.macro.scaleHigh)
                            draft.macro.minorValue = KeyMIDIMapper.minorScaleValue(
                                steps: count, low: draft.macro.scaleLow, high: draft.macro.scaleHigh)
                        }
                    ), in: 3...40)
                    Stepper("Scale 低档 \(draft.macro.scaleLow)", value: $draft.macro.scaleLow, in: 0...127)
                    Stepper("Scale 高档 \(draft.macro.scaleHigh)", value: $draft.macro.scaleHigh, in: 0...127)
                }

                HStack(spacing: 18) {
                    Stepper("Major CC \(draft.macro.majorValue)", value: $draft.macro.majorValue, in: 0...127)
                    Stepper("Minor CC \(draft.macro.minorValue)", value: $draft.macro.minorValue, in: 0...127)
                }
                .disabled(!draft.macro.sendScale)

                HStack(spacing: 18) {
                    Stepper("每条连发 \(draft.macro.repeatCount) 次", value: $draft.macro.repeatCount, in: 1...5)
                    Stepper("间隔 \(draft.macro.repeatGapMs) ms", value: $draft.macro.repeatGapMs, in: 5...200)
                }

                Text("档位数 = 宏旋钮在插件参数上跨过的档位（Auto-Tune / WavesTune 的 Key 都是 12）。调式参数总数填插件 Scale 列表的实际条目数，CC 行程按它等分，Major / Minor 自动取第 2 / 第 3 段，个别档位对不上再到「宏控制」页用 ± 微调。")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .padding(8)
        }
    }

    // MARK: 强度 CC

    private var intensitySection: some View {
        GroupBox(label: Label("电音强度 0-100% → CC 0-127", systemImage: "slider.horizontal.below.rectangle")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    Stepper("CC 编号 \(draft.intensity.ccNumber)", value: $draft.intensity.ccNumber, in: 0...127)
                    Stepper("通道 \(draft.intensity.channel)", value: $draft.intensity.channel, in: 1...16)
                }
                HStack(spacing: 18) {
                    Stepper("0% 对应值 \(draft.intensity.zeroPercentValue)",
                            value: $draft.intensity.zeroPercentValue, in: 0...127)
                    Stepper("100% 对应值 \(draft.intensity.hundredPercentValue)",
                            value: $draft.intensity.hundredPercentValue, in: 0...127)
                }
                Toggle("反转映射", isOn: $draft.intensity.invert)

                Text("当前 \(Int(appState.intensity))% → CC#\(draft.intensity.ccNumber) = \(draft.intensity.ccValue(for: appState.intensity))。同理，把它 Learn 到宏面板的一个旋钮上，再把该旋钮「添加目标」到 Retune Speed 之类的参数。")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .padding(8)
        }
    }
}
