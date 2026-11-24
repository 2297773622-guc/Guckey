import Foundation

// MARK: - 基调输出策略（单一方案：宏控制 CC）

protocol KeyOutputStrategy: AnyObject {
    /// 检测到新基调 / 用户手动更正时调用。值没变化时不重复发送。
    func apply(key: KeySignature, mapping: MIDIMapping)
    /// 心跳：仅当缓存与目标不一致时补发，正常情况下是空操作。
    func refresh()
    /// 断开 / 暂停 / 退出时调用：清空「上次已发送」缓存，下次一定重发。
    func panic()
}

/// 宏控制 CC 的两种角色。
enum MacroCCRole: String, CaseIterable, Identifiable {
    case root, scale
    var id: String { rawValue }
    var label: String { self == .root ? "Root / 基调" : "Scale / 调式" }
}

/// 把基调编码成两条 CC，驱动 Studio One 宏控制器的两个旋钮。
///
/// 链路：本工具 → CC（虚拟 MIDI 源）→ 外部设备 → 宏旋钮 →「添加目标」→ 插件 Key/Scale。
/// 因此插件本身不必接收 MIDI，Key/Scale 也不必是 automation 参数——
/// 宏旋钮是宿主参数，Learn 得到的就是它。
///
/// 噪声控制：只在值变化时发送（换调才发），同值连发用于对抗链路丢包。
final class MacroCCStrategy: KeyOutputStrategy {

    private let midi: MIDIController
    private let log: (String) -> Void

    private var lastKey: KeySignature?
    private var lastMapping: MIDIMapping?
    private var lastRootSent: Int?
    private var lastScaleSent: Int?

    /// 向全部 16 个通道广播，规避外部设备 / 宏控制的通道过滤。
    var broadcastAllChannels = true

    init(midi: MIDIController, log: @escaping (String) -> Void) {
        self.midi = midi
        self.log = log
    }

    func apply(key: KeySignature, mapping: MIDIMapping) {
        lastKey = key
        lastMapping = mapping
        transmit(key: key, mapping: mapping)
    }

    func refresh() {
        guard let key = lastKey, let mapping = lastMapping else { return }
        transmit(key: key, mapping: mapping)
    }

    /// 强制重发：清掉缓存后立刻再发一次（改完映射、DAW 重连时用）。
    func resend(key: KeySignature, mapping: MIDIMapping) {
        lastKey = key
        lastMapping = mapping
        lastRootSent = nil
        lastScaleSent = nil
        transmit(key: key, mapping: mapping)
    }

    func panic() {
        // CC 没有「按住的音符」，不存在卡音；清缓存即可。
        lastRootSent = nil
        lastScaleSent = nil
        lastKey = nil
        lastMapping = nil
    }

    /// 校准用：发一条原始 CC，不改变当前基调缓存（找不到正确档位时逐步微调）。
    func sendRaw(role: MacroCCRole, value: Int, mapping: MIDIMapping) {
        let cfg = mapping.macro
        midi.sendCC(number: role == .root ? cfg.rootCC : cfg.scaleCC,
                    value: MIDIController.clamp(value, 0, 127),
                    channel: channel(for: cfg))
    }

    // MARK: 内部

    private func channel(for cfg: MacroControlConfig) -> Int {
        // 默认单通道：广播会让 MIDI 学习里出现 16 个重复旋钮，只在备选开关打开时才广播。
        if broadcastAllChannels { return 0 }
        return MIDIController.clamp(cfg.channel, 1, 16)
    }

    private func transmit(key: KeySignature, mapping: MIDIMapping) {
        let cfg = mapping.macro
        let ch = channel(for: cfg)
        let rootValue = KeyMIDIMapper.macroRootValue(for: key, config: cfg)
        let scaleValue = KeyMIDIMapper.macroScaleValue(for: key, config: cfg)

        var changed: [String] = []
        if lastRootSent != rootValue {
            emit(number: cfg.rootCC, value: rootValue, channel: ch, cfg: cfg)
            lastRootSent = rootValue
            changed.append("Root CC#\(cfg.rootCC)=\(rootValue)")
        }
        if cfg.sendScale, lastScaleSent != scaleValue {
            emit(number: cfg.scaleCC, value: scaleValue, channel: ch, cfg: cfg)
            lastScaleSent = scaleValue
            changed.append("Scale CC#\(cfg.scaleCC)=\(scaleValue)")
        }
        guard !changed.isEmpty else { return }
        let target = cfg.sendScale ? key.displayName : "\(key.root.symbol)"
        log("宏控制 → \(target)：\(changed.joined(separator: " / "))")
    }

    private func emit(number: Int, value: Int, channel: Int, cfg: MacroControlConfig) {
        midi.sendCC(number: number, value: value, channel: channel)
        let repeats = max(1, cfg.repeatCount)
        guard repeats > 1 else { return }
        let gap = max(5, cfg.repeatGapMs)
        for index in 1..<repeats {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(gap * index) / 1000.0) { [weak self] in
                self?.midi.sendCC(number: number, value: value, channel: channel)
            }
        }
    }
}

// MARK: - 电音强度（0-100% → CC）

/// 强度独立走一条 CC，与宏控制无关。
/// 反向语义参数（如 Retune Speed）在 IntensityMapping 层反转。
final class IntensityOutputController {
    private let midi: MIDIController

    init(midi: MIDIController) { self.midi = midi }

    /// 与宏控制一致：默认单通道，只有备选开关打开才广播 16 通道。
    func channel(mapping: MIDIMapping, broadcast: Bool) -> Int {
        broadcast ? 0 : MIDIController.clamp(mapping.intensity.channel, 1, 16)
    }

    func apply(percent: Double, mapping: MIDIMapping, broadcastAllChannels: Bool = false) {
        let value = KeyMIDIMapper.intensityCCValue(percent: percent, mapping: mapping)
        send(rawValue: value, mapping: mapping, broadcastAllChannels: broadcastAllChannels)
    }

    /// 直接发一个指定值（Learn 时扫动用，不改变强度状态）。
    func send(rawValue: Int, mapping: MIDIMapping, broadcastAllChannels: Bool = false) {
        midi.sendCC(number: mapping.intensity.ccNumber,
                    value: MIDIController.clamp(rawValue, 0, 127),
                    channel: channel(mapping: mapping, broadcast: broadcastAllChannels))
    }
}
