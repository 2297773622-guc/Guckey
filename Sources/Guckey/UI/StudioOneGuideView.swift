import SwiftUI

// MARK: - Studio One 配置指南

struct StudioOneGuideView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                chainCard
                stepCard
                keyCard
                failCard
            }
            .padding(.bottom, 16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Studio One 配置指南").font(.title2.bold())
            Text("按下面 7 步配一次，之后换歌自动跟随。")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var chainCard: some View {
        GroupBox(label: Label("数据链路", systemImage: "point.3.connected.trianglepath.dotted")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    chip("Guckey", .teal)
                    arrow
                    chip("虚拟 MIDI 源\n\(appState.mapping.virtualSourceName)", .cyan)
                    arrow
                    chip("Studio One\n外部设备", .blue)
                    arrow
                    chip("宏旋钮\nRoot / Scale", .indigo)
                    arrow
                    chip("修音插件\nKey / Scale", .purple)
                }
            }
            .padding(6)
        }
    }

    private var stepCard: some View {
        GroupBox(label: Label("一次性配置（约 3 分钟）", systemImage: "list.number")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.cyan)
                            .frame(width: 20, alignment: .leading)
                        Text(step)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(6)
        }
    }

    private var steps: [String] {
        [
            "确认 Guckey 已在「设置 → 虚拟 MIDI 源」创建端点（默认 \(appState.mapping.virtualSourceName)）。",
            "Studio One → 选项 → 外部设备 → 添加… → 新建键盘：名称填 Guckey，接收自选 \(appState.mapping.virtualSourceName)，**MIDI 通道只勾 1**（Guckey 默认单通道发送）。",
            "打开宏控制面板（宏控制视图）。右键 Knob → 分配 / Control Link → MIDI 学习，然后在本工具「宏控制」页点「扫动 CC#\(appState.mapping.macro.rootCC)」，让 Knob 学到 Root。",
            "新建一个空 Knob，添加目标 = 修音插件的 Scale 参数，同样学习 CC#\(appState.mapping.macro.scaleCC)。",
            "对插件的 Key / Scale 参数上的映射确认一次：宏旋钮 → 添加目标 → 选择插件与参数。之后旋钮数值变化会直接改插件。",
            "强度：再建一个 Knob，添加目标 = Speed / Retune，学习 CC#\(appState.mapping.intensity.ccNumber)（本工具「宏控制」页有「扫动强度 CC」按钮）。",
            "在「宏控制」页逐一核对 12 个音级与 Major / Minor 的 CC 值；对不上时用 ± 微调（会写进映射表，重启不丢）。"
        ]
    }

    private var keyCard: some View {
        GroupBox(label: Label("当前 CC 编号", systemImage: "number")) {
            VStack(alignment: .leading, spacing: 4) {
                row("Root", "CC#\(appState.mapping.macro.rootCC)", "12 档，现在 \(appState.currentKey.displayName) → \(appState.rootCCValue)")
                row("Scale", "CC#\(appState.mapping.macro.scaleCC)", "\(scaleLabel)，Major=\(appState.mapping.macro.majorValue) / Minor=\(appState.mapping.macro.minorValue)")
                row("强度", "CC#\(appState.mapping.intensity.ccNumber)", "\(Int(appState.intensity))% → \(KeyMIDIMapper.intensityCCValue(percent: appState.intensity, mapping: appState.mapping))")
                row("通道", appState.broadcastAllChannels ? "1–16 广播" : "\(appState.mapping.macro.channel)", "单通道优先；只有确认收不到时才打开广播")
            }
            .padding(6)
        }
    }

    private var failCard: some View {
        GroupBox(label: Label("常见失败点", systemImage: "exclamationmark.triangle")) {
            VStack(alignment: .leading, spacing: 6) {
                bullet("MIDI 学习里出现 16 个重复旋钮 → 关掉「16 通道广播」（默认已关）。")
                bullet("通道 1 收不到 → 到「MIDI 映射」临时打开「16 通道广播」，确认后再关掉。")
                bullet("旋钮学不到 → 先点本工具「扫动 CC」，再在宿主里点 MIDI 学习，顺序不能反。")
                bullet("宏旋钮能学到但插件不动 → 「添加目标」还没做，或目标选错了参数。")
                bullet("Key 对但 Scale 不对 → 「宏控制」里选对修音插件，再点一次「重算」。")
                bullet("Studio One 的宏旋钮在「外部设备」未注册时收不到 CC → 回到第 2 步检查 Receive From。")
            }
            .padding(6)
        }
    }

    // MARK: 组件

    private var scaleLabel: String {
        if let preset = TuningPluginPreset.find(appState.mapping.macro.plugin) {
            return "\(preset.name) \(preset.scaleCount) 项"
        }
        return "\(appState.mapping.macro.scaleSteps) 项等分"
    }

    private func row(_ title: String, _ value: String, _ note: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 46, alignment: .leading)
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 110, alignment: .leading)
            Text(note).font(.caption2).foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").font(.caption).foregroundColor(.orange)
            Text(text).font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.4), lineWidth: 1))
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 9))
            .foregroundColor(.secondary)
    }
}
