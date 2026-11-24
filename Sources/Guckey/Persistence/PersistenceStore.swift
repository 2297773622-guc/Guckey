import Foundation
import AppKit

// MARK: - 设置持久化（UserDefaults + JSON）

/// 集中保存：MIDI 映射表、悬浮窗外观、检测模式、云端配置、稳定化参数。
/// 手动基调记录 / 云端缓存 / AI 缓存都不在这里 —— 它们在 SQLite（`KeyDatabase`）。
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Key {
        // 下面的 `vta.` 前缀是 App 改名前（VocalTune Assistant）留下的键名。
        // 键名一旦改动，老用户已校准的 MIDI 映射、悬浮窗位置会全部回到默认值，
        // 所以这里只保留不加迁移 —— 见名知意的部分由常量名承担，不影响功能。
        static let mapping = "vta.mapping.json"
        static let frame = "vta.floating.frame"
        static let alwaysOnTop = "vta.floating.alwaysOnTop"
        static let opacity = "vta.floating.opacity"
        static let floatingVisible = "vta.floating.visible"
        static let detectionMode = "vta.detection.mode"
        static let intensity = "vta.intensity"
        static let demoMode = "vta.detector.demo"
        static let broadcastAllChannels = "vta.midi.broadcastAllChannels"
        static let schemaVersion = "vta.schema.version"
        /// 存储键是历史遗留名字，**不要改** —— 改了等于把用户已保存的连接配置丢弃一次。
        static let cloudConfig = "guckey.feishu.json"
        /// 1.2.0 之前云端配置存在这个键名下（名字沿用更早的 Supabase 方案），
        /// 启动时搬到 `cloudConfig` 后删除，避免出现两处配置。
        static let legacyCloudConfig = "guckey.supabase.json"
        static let stabilizer = "guckey.stabilizer.json"
        static let cloudTable = "guckey.cloud.table"
    }

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // v6：改名 Guckey + 三级基调决策。Scale 与 12 音级校准保持原样，
        // 只把虚拟 MIDI 默认源名改成 Guckey（旧名会让 DAW 里出现一个多余端点）。
        let schema = defaults.integer(forKey: Key.schemaVersion)
        if schema < 6 {
            if let data = defaults.data(forKey: Key.mapping),
               var mapping = try? decoder.decode(MIDIMapping.self, from: data) {
                if mapping.virtualSourceName == "VocalTune Assistant" {
                    mapping.virtualSourceName = "Guckey"
                }
                if let encoded = try? encoder.encode(mapping) {
                    defaults.set(encoded, forKey: Key.mapping)
                }
            } else if defaults.data(forKey: Key.mapping) == nil,
                      let data = try? encoder.encode(MIDIMapping.default) {
                defaults.set(data, forKey: Key.mapping)
            }
            defaults.set(6, forKey: Key.schemaVersion)
        }

        // 云端配置的历史键名迁移（旧值原样搬过来，用户不用重填 App ID / Secret）。
        if defaults.data(forKey: Key.cloudConfig) == nil,
           let legacy = defaults.data(forKey: Key.legacyCloudConfig) {
            defaults.set(legacy, forKey: Key.cloudConfig)
            defaults.removeObject(forKey: Key.legacyCloudConfig)
        }
    }

    var mapping: MIDIMapping {
        get {
            guard let data = defaults.data(forKey: Key.mapping),
                  let value = try? decoder.decode(MIDIMapping.self, from: data) else {
                return .default
            }
            return value
        }
        set {
            guard let data = try? encoder.encode(newValue) else { return }
            defaults.set(data, forKey: Key.mapping)
        }
    }

    var floatingFrame: NSRect? {
        get {
            guard let s = defaults.string(forKey: Key.frame) else { return nil }
            return NSRectFromString(s)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.frame)
                return
            }
            defaults.set(NSStringFromRect(newValue), forKey: Key.frame)
        }
    }

    /// 读布尔：命令行 `-key YES` 注入的是 NSString，`as? Bool` 会失败，
    /// 这里统一用 NSString.boolValue 兜住，「YES/1/true」都算真。
    private func boolValue(for key: String, default fallback: Bool) -> Bool {
        switch defaults.object(forKey: key) {
        case let number as NSNumber: return number.boolValue
        case let string as NSString: return string.boolValue
        case let string as String: return (string as NSString).boolValue
        default: return fallback
        }
    }

    var alwaysOnTop: Bool {
        get { boolValue(for: Key.alwaysOnTop, default: true) }
        set { defaults.set(newValue, forKey: Key.alwaysOnTop) }
    }

    var opacity: Double {
        get {
            let v = defaults.object(forKey: Key.opacity) as? Double ?? 0.94
            return min(max(v, 0.35), 1.0)
        }
        set { defaults.set(min(max(newValue, 0.35), 1.0), forKey: Key.opacity) }
    }

    var floatingVisible: Bool {
        get { boolValue(for: Key.floatingVisible, default: true) }
        set { defaults.set(newValue, forKey: Key.floatingVisible) }
    }

    var detectionMode: DetectionMode {
        get {
            DetectionMode(rawValue: defaults.string(forKey: Key.detectionMode) ?? "") ?? .player
        }
        set { defaults.set(newValue.rawValue, forKey: Key.detectionMode) }
    }

    var intensity: Double {
        get { defaults.object(forKey: Key.intensity) as? Double ?? 65 }
        set { defaults.set(min(max(newValue, 0), 100), forKey: Key.intensity) }
    }

    /// 演示模式：用 SimulatedKeyDetector 代替真实音频捕获，便于无权限环境调试 UI。
    var demoMode: Bool {
        get { boolValue(for: Key.demoMode, default: false) }
        set { defaults.set(newValue, forKey: Key.demoMode) }
    }

    var broadcastAllChannels: Bool {
        get { boolValue(for: Key.broadcastAllChannels, default: false) }
        set { defaults.set(newValue, forKey: Key.broadcastAllChannels) }
    }

    // MARK: 云端

    /// 实际生效的配置：空字段自动补内置值。同步逻辑只用这一份。
    var cloudConfig: CloudConfig {
        get {
            guard let data = defaults.data(forKey: Key.cloudConfig),
                  let value = try? decoder.decode(CloudConfig.self, from: data) else {
                return CloudConfig()
            }
            // 空字段回落内置值：用户不需要知道这些参数，也不该因为清空而失联。
            return value.normalized()
        }
        set {
            guard let data = try? encoder.encode(newValue) else { return }
            defaults.set(data, forKey: Key.cloudConfig)
        }
    }

    /// 只有用户改过的那部分配置（与内置值相同的字段为空）。
    /// 「高级设置」展开时用它 —— 内置地址不该反过来显示给用户。
    var cloudOverrides: CloudConfig {
        get {
            guard let data = defaults.data(forKey: Key.cloudConfig),
                  let value = try? decoder.decode(CloudConfig.self, from: data) else {
                return .blank
            }
            return value.strippingBuiltin()
        }
        set {
            guard let data = try? encoder.encode(newValue.strippingBuiltin()) else { return }
            defaults.set(data, forKey: Key.cloudConfig)
        }
    }

    /// 上次探测成功的表名（避免每次同步都重新猜）。
    var resolvedCloudTable: String? {
        get { defaults.string(forKey: Key.cloudTable) }
        set { defaults.set(newValue, forKey: Key.cloudTable) }
    }

    // MARK: 稳定化

    var stabilizerConfig: StabilizerConfig {
        get {
            guard let data = defaults.data(forKey: Key.stabilizer),
                  let value = try? decoder.decode(StabilizerConfig.self, from: data) else {
                return .default
            }
            return value
        }
        set {
            guard let data = try? encoder.encode(newValue) else { return }
            defaults.set(data, forKey: Key.stabilizer)
        }
    }
}
