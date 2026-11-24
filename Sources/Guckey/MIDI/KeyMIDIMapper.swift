import Foundation

// MARK: - 基调 → 宏控制 CC 的纯函数映射层

/// 把「detected KeySignature」翻译成 Studio One 宏旋钮能理解的两条 CC。
///
/// 宏旋钮在宿主里是一个 0...127 的连续控制，它再映射到插件的离散参数
/// （Key 是 12 档：C…B；Scale 是「不定长列表」：Chromatic、Major、Minor……）。
/// 宿主对离散参数的取整规则是 `index = round(value / 127 × (steps - 1))`，
/// 因此把每一档送在该区间的正中就能稳定命中，不会串到相邻档。
///
/// 纯函数、无副作用，方便单元测试：换插件、换旋钮行程只改这里。
enum KeyMIDIMapper {

    /// 把第 index 档（0 起）铺到 `low...high` 行程的正中。
    static func steppedValue(index: Int, steps: Int, low: Int, high: Int) -> Int {
        let n = max(1, steps)
        let clampedIndex = MIDIController.clamp(index, 0, n - 1)
        guard n > 1 else { return MIDIController.clamp(low, 0, 127) }
        let t = Double(clampedIndex) / Double(n - 1)
        let raw = Double(low) + (Double(high) - Double(low)) * t
        return MIDIController.clamp(Int(raw.rounded()), 0, 127)
    }

    /// 音级在 Root 旋钮行程上的档位索引。
    /// `rootSteps == 12` 时就是音级本身；其他档位数（例如旋钮直接拖 24 档列表）等比压缩。
    static func macroRootIndex(for root: PitchClass, config: MacroControlConfig) -> Int {
        let steps = max(1, config.rootSteps)
        guard steps > 1 else { return 0 }
        let scaled = Double(root.rawValue) * Double(steps - 1) / 11.0
        return MIDIController.clamp(Int(scaled.rounded()), 0, steps - 1)
    }

    /// 根音对应的 CC 值。逐音级校准覆盖优先于公式。
    static func macroRootValue(for key: KeySignature, config: MacroControlConfig) -> Int {
        if let override = config.override(for: key.root) {
            return MIDIController.clamp(override, 0, 127)
        }
        return steppedValue(index: macroRootIndex(for: key.root, config: config),
                            steps: config.rootSteps,
                            low: config.rootLow,
                            high: config.rootHigh)
    }

    /// Scale 列表第 N 段（index 0 起）的 CC 值。插件的 Major / Minor 位置不同，由调用方给下标。
    static func scaleValue(steps: Int, index: Int, low: Int, high: Int) -> Int {
        steppedValue(index: index, steps: steps, low: low, high: high)
    }

    /// 默认布局：第 2 段（下标 1）= Major。
    static func majorScaleValue(steps: Int, low: Int, high: Int) -> Int {
        scaleValue(steps: steps, index: 1, low: low, high: high)
    }

    /// 默认布局：第 3 段（下标 2）= Minor。
    static func minorScaleValue(steps: Int, low: Int, high: Int) -> Int {
        scaleValue(steps: steps, index: 2, low: low, high: high)
    }

    /// 调式对应的 CC 值（用配置里存下的 Major / Minor 值，允许手工微调）。
    static func macroScaleValue(for key: KeySignature, config: MacroControlConfig) -> Int {
        MIDIController.clamp(key.mode == .major ? config.majorValue : config.minorValue, 0, 127)
    }

    /// 强度百分比 → CC 值。
    static func intensityCCValue(percent: Double, mapping: MIDIMapping) -> Int {
        Int(mapping.intensity.ccValue(for: percent))
    }
}
