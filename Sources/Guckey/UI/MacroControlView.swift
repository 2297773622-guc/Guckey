import SwiftUI

// MARK: - 宏控制输出（单一方案）

/// 链路：检测基调 → 两条 CC → Studio One 外部设备 → 宏控制器旋钮 →「添加目标」→ 插件 Key / Scale。
/// 宏旋钮是宿主参数，所以能 MIDI Learn；插件不必接收 MIDI，Key/Scale 也不必是 automation 参数。
struct MacroControlView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                outputCard
                setupCard
                calibrationCard
                actionRow
                logCard
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("宏控制输出").font(.title2.bold())
            Text("基调 → 两条 CC → Studio One 宏旋钮 → 插件 Key / Scale。")
                .font(.caption).foregroundColor(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(appState.currentKey.displayName)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(appState.status == .midiError ? .red : .green)
                        .frame(width: 8, height: 8)
                    Text(appState.status.label).font(.caption)
                    Text("置信度 \(Int(appState.confidence * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: 正在发送的值

    private var outputCard: some View {
        GroupBox(label: Label("正在发送", systemImage: "dial.min")) {
            HStack(spacing: 12) {
                valueTile(title: "Root",
                          value: appState.rootCCValue,
                          detail: "CC#\(appState.mapping.macro.rootCC) · \(appState.currentKey.root.symbol)")
                if appState.mapping.macro.sendScale {
                    valueTile(title: "Scale",
                              value: appState.scaleCCValue,
                              detail: "CC#\(appState.mapping.macro.scaleCC) · \(appState.currentKey.mode.chinese)")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("通道").font(.caption2).foregroundColor(.secondary)
                    Text(appState.broadcastAllChannels ? "1–16 广播" : "\(appState.mapping.macro.channel)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                    if let note = appState.lastCalibrationValue {
                        Text(note).font(.caption2).foregroundColor(.cyan)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("强度 CC#\(appState.mapping.intensity.ccNumber)")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("\(KeyMIDIMapper.intensityCCValue(percent: appState.intensity, mapping: appState.mapping))")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                    Text("\(Int(appState.intensity))%")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(10)
        }
    }

    private func valueTile(title: String, value: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text("\(value)")
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
            Text(detail).font(.caption2).foregroundColor(.secondary)
        }
        .frame(width: 132, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    // MARK: 配置步骤

    private var setupCard: some View {
        GroupBox(label: Label("Studio One 侧一次性配置", systemImage: "checklist")) {
            VStack(alignment: .leading, spacing: 6) {
                step(1, "插件挂好后，打开插件顶部的「宏控制」（Macro Control）面板。")
                step(2, "选中 Knob 1 → 上面板「添加目标」→ 参数树里选插件的 Key；Knob 2 → 添加目标 → Scale。")
                step(3, "选项 → 外部设备 → 添加「新建键盘」，接收自 = \(appState.mapping.virtualSourceName)，MIDI 通道只勾 1。")
                step(4, "右键 Knob 1 → Control Link / MIDI 学习，然后点下面「扫动 CC#\(appState.mapping.macro.rootCC)」，让宿主学到这条 CC；Knob 2 同理学 CC#\(appState.mapping.macro.scaleCC)。")
                step(5, "换一首歌，或点「重申当前基调」，插件里的 Key / Scale 应自动跟着变。")
            }
            .padding(10)
        }
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index).")
                .font(.caption.monospacedDigit())
                .foregroundColor(.cyan)
                .frame(width: 18, alignment: .leading)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 校准

    private var calibrationCard: some View {
        GroupBox(label: Label("校准（换插件或档位数不同时才需要动）", systemImage: "slider.horizontal.3")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    stepperField("Root CC", value: macroBinding(\.rootCC), range: 0...127)
                    stepperField("Scale CC", value: macroBinding(\.scaleCC), range: 0...127)
                    stepperField("通道", value: macroBinding(\.channel), range: 1...16)
                    stepperField("档位数", value: macroBinding(\.rootSteps), range: 2...24)
                }

                HStack(spacing: 16) {
                    stepperField("低档 CC", value: macroBinding(\.rootLow), range: 0...127)
                    stepperField("高档 CC", value: macroBinding(\.rootHigh), range: 0...127)
                    Toggle("同时发 Scale", isOn: macroBinding(\.sendScale))
                        .font(.caption)
                    Toggle("16 通道广播（备选）", isOn: Binding(
                        get: { appState.broadcastAllChannels },
                        set: { appState.broadcastAllChannels = $0 }
                    ))
                    .font(.caption)
                }

                Divider()

                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("修音插件").font(.caption2).foregroundColor(.secondary)
                        Picker("", selection: pluginBinding) {
                            Text("自定义").tag("")
                            ForEach(TuningPluginPreset.all) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }

                    if TuningPluginPreset.find(appState.mapping.macro.plugin) == nil {
                        stepperField("调式总数", value: scaleStepsBinding, range: 3...40)
                    }

                    stepperField("Scale 低档", value: scaleLowBinding, range: 0...127)
                    stepperField("Scale 高档", value: scaleHighBinding, range: 0...127)
                    Button("重算") { appState.recalcScaleValues() }
                        .font(.caption)
                    Spacer()
                }

                Divider()

                Text("音级微调：对着插件界面把每档拨到正确音名，改过的优先于公式。")
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(PitchClass.allCases) { pc in
                        rootCell(pc)
                    }
                }

                HStack(spacing: 12) {
                    Text("Scale 档位").font(.caption2).foregroundColor(.secondary)
                    scaleAdjustRow(title: "Major", isMajor: true,
                                   value: appState.mapping.macro.majorValue)
                    scaleAdjustRow(title: "Minor", isMajor: false,
                                   value: appState.mapping.macro.minorValue)
                    Spacer()
                    Button("清除全部音级校准") { appState.clearAllRootOverrides() }
                        .font(.caption)
                }
            }
            .padding(10)
        }
    }

    private func rootCell(_ pc: PitchClass) -> some View {
        let overridden = appState.mapping.macro.override(for: pc) != nil
        return VStack(spacing: 2) {
            Text(pc.ascii)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(overridden ? .orange : .secondary)
            HStack(spacing: 2) {
                Button("−") { appState.adjustRoot(pc, delta: -1) }
                    .buttonStyle(.borderless)
                Text("\(appState.rootValue(for: pc))")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minWidth: 24)
                Button("＋") { appState.adjustRoot(pc, delta: 1) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(Color.white.opacity(overridden ? 0.09 : 0.04)))
        .help(overridden ? "已手动校准；右键可恢复公式换算" : "公式换算值")
        .contextMenu {
            if overridden {
                Button("恢复公式换算") { appState.clearRootOverride(pc) }
            }
        }
    }

    private func scaleAdjustRow(title: String, isMajor: Bool, value: Int) -> some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 11, design: .monospaced))
            Button("−") { appState.adjustScale(major: isMajor, delta: -1) }
                .buttonStyle(.borderless)
            Text("\(value)")
                .font(.system(size: 11, design: .monospaced))
                .frame(minWidth: 24)
            Button("＋") { appState.adjustScale(major: isMajor, delta: 1) }
                .buttonStyle(.borderless)
        }
    }

    private func stepperField(_ title: String, value: Binding<Int>, range: ClosedRange<Int> = 0...127) -> some View {
        Stepper(value: value, in: range) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption2).foregroundColor(.secondary)
                Text("\(value.wrappedValue)")
                    .font(.system(size: 12, design: .monospaced))
            }
        }
        .font(.caption)
        .frame(minWidth: 96, alignment: .leading)
    }

    private func macroBinding<T>(_ keyPath: WritableKeyPath<MacroControlConfig, T>) -> Binding<T> {
        Binding(
            get: { appState.mapping.macro[keyPath: keyPath] },
            set: { newValue in appState.updateMacro { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// 改总数要连带重算 Major / Minor 的落点。
    private var scaleStepsBinding: Binding<Int> {
        Binding(
            get: { appState.mapping.macro.scaleSteps },
            set: { appState.setScaleSteps($0) }
        )
    }

    private var scaleLowBinding: Binding<Int> {
        Binding(
            get: { appState.mapping.macro.scaleLow },
            set: { value in
                appState.updateMacro(resend: false) { $0.scaleLow = value }
                appState.recalcScaleValues()
            }
        )
    }

    private var scaleHighBinding: Binding<Int> {
        Binding(
            get: { appState.mapping.macro.scaleHigh },
            set: { value in
                appState.updateMacro(resend: false) { $0.scaleHigh = value }
                appState.recalcScaleValues()
            }
        )
    }

    /// 插件下拉：选中即按该插件的调式列表重排 Major / Minor 落点。
    private var pluginBinding: Binding<String> {
        Binding(
            get: { appState.mapping.macro.plugin },
            set: { appState.selectTuningPlugin(TuningPluginPreset.find($0)) }
        )
    }

    // MARK: 动作

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("重申当前基调") { appState.reapplyKey() }
                    .buttonStyle(.borderedProminent)
                Button("扫动 CC#\(appState.mapping.macro.rootCC)") { appState.sweep(role: .root) }
                Button("扫动 CC#\(appState.mapping.macro.scaleCC)") { appState.sweep(role: .scale) }
                Button(appState.isDetectionPaused ? "恢复检测" : "暂停检测") { appState.togglePause() }
                Spacer()
            }
            HStack(spacing: 10) {
                Button("扫动强度 CC#\(appState.mapping.intensity.ccNumber)（用于 Learn）") {
                    appState.sweepIntensity()
                }
            }
        }
        .font(.caption)
    }

    // MARK: 日志

    private var logCard: some View {
        GroupBox(label: Label("最近发送", systemImage: "list.bullet.rectangle")) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(appState.midiLog.prefix(10), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(line.contains("⚠️") ? .orange : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
            .frame(height: 110)
        }
    }
}
