import Foundation

// MARK: - 调性模型

/// 12 个音级。rawValue 即 pitch class（C = 0 ... B = 11）。
enum PitchClass: Int, Codable, CaseIterable, Identifiable, Hashable {
    case C = 0, CSharp, D, DSharp, E, F, FSharp, G, GSharp, A, ASharp, B

    var id: Int { rawValue }

    /// 悬浮窗大字显示用的音名（英文，符合音乐软件习惯）。
    var symbol: String {
        ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"][rawValue]
    }

    /// 日志 / 数据库里用的平坦化音名。
    var ascii: String {
        ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"][rawValue]
    }

    /// 云端库 / 预设里可能出现的各种写法 → pitch class。
    static func parse(_ raw: String) -> PitchClass? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")
            .replacingOccurrences(of: "＃", with: "#")
        let table: [String: PitchClass] = [
            "c": .C, "c#": .CSharp, "db": .CSharp,
            "d": .D, "d#": .DSharp, "eb": .DSharp,
            "e": .E, "fb": .E, "e#": .F,
            "f": .F, "f#": .FSharp, "gb": .FSharp,
            "g": .G, "g#": .GSharp, "ab": .GSharp,
            "a": .A, "a#": .ASharp, "bb": .ASharp,
            "b": .B, "cb": .B
        ]
        if let hit = table[s] { return hit }
        // 纯数字（0...11）也接受，方便 SQLite / 表格直接存 int
        if let n = Int(s), (0..<12).contains(n) { return PitchClass(rawValue: n) }
        return nil
    }
}

enum KeyMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case major = "Major"
    case minor = "Minor"

    var id: String { rawValue }
    var chinese: String { self == .major ? "大调" : "小调" }

    /// 相对根音的半音音级集合 —— 大调 / 自然小调。
    /// 用于检测侧的色度模板匹配，不作为 MIDI 输出依据。
    var scaleIntervals: [Int] {
        switch self {
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        }
    }

    /// 云端 / 插件里可能出现的大小调写法。
    static func parse(_ raw: String) -> KeyMode? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("maj") || s == "大调" || s == "0" { return .major }
        if s.hasPrefix("min") || s.hasPrefix("nat") || s == "小调" || s == "1" { return .minor }
        return nil
    }
}

struct KeySignature: Codable, Hashable, Identifiable, CustomStringConvertible {
    var root: PitchClass
    var mode: KeyMode

    var id: String { "\(root.ascii)_\(mode.rawValue)" }
    /// 例："A Minor"
    var displayName: String { "\(root.symbol) \(mode.rawValue)" }
    var description: String { displayName }
    var chineseName: String { "\(root.symbol) \(mode.chinese)" }

    /// 该调的全部可用音级（pitch class）。
    var scalePitchClasses: [Int] {
        mode.scaleIntervals.map { (root.rawValue + $0) % 12 }
    }

    static let all: [KeySignature] = PitchClass.allCases.flatMap { root in
        KeyMode.allCases.map { KeySignature(root: root, mode: $0) }
    }

    static let `default` = KeySignature(root: .A, mode: .minor)

    /// 兼容云端脏数据：root 可以是 "A" / "a#" / 9 / "A Minor"，scale 可以是 "major" / 1 / "Minor"。
    static func parse(root: String?, scale: String?) -> KeySignature? {
        var rootRaw = (root ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var modeRaw = (scale ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // "A Minor" 这种把调式塞进 root 的写法
        if modeRaw.isEmpty, let space = rootRaw.firstIndex(of: " ") {
            modeRaw = String(rootRaw[rootRaw.index(after: space)...])
            rootRaw = String(rootRaw[..<space])
        }
        guard let pc = PitchClass.parse(rootRaw) else { return nil }
        // 缺调式时按大调处理（云端表里 scale 允许为空）
        let mode = KeyMode.parse(modeRaw) ?? .major
        return KeySignature(root: pc, mode: mode)
    }
}

// MARK: - 基调来源

/// 三级决策的结果来源。UI 用不同颜色标识：绿=手动、蓝=云端、黄=AI。
enum KeySource: String, Codable, CaseIterable, Identifiable {
    case manual
    case cloud
    case ai

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "手动"
        case .cloud: return "云端"
        case .ai: return "AI"
        }
    }

    var shortLabel: String {
        switch self {
        case .manual: return "MANUAL"
        case .cloud: return "CLOUD"
        case .ai: return "AI"
        }
    }

    var systemImage: String {
        switch self {
        case .manual: return "hand.point.up.left.fill"
        case .cloud: return "cloud.fill"
        case .ai: return "waveform"
        }
    }

    /// 0 = 最高优先级。用于断言「手动 > 云端 > AI」。
    var priority: Int {
        switch self {
        case .manual: return 0
        case .cloud: return 1
        case .ai: return 2
        }
    }

    var explanation: String {
        switch self {
        case .manual: return "本地手动记录命中，基调已锁定，不再接受云端 / AI 的波动"
        case .cloud: return "命中云端曲库缓存，已锁定"
        case .ai: return "前两级未命中，由实时音频分析给出（已过稳定化）"
        }
    }
}

// MARK: - 歌曲标识（归一化）

/// 歌曲标识：`歌手_歌名` 归一化之后的字符串。
///
/// 本版本已**放弃音频指纹**：所有匹配都基于归一化后的 `[歌手]_[歌名]`，
/// 这样手动记录、云端曲库、AI 自动缓存三张表共用同一个主键。
struct SongIdentity: Codable, Hashable, Identifiable {
    /// 归一化后的歌名（已剥离「伴奏 / Live / Remix」等干扰词）。
    var title: String
    /// 归一化后的歌手。
    var artist: String
    var sourceBundleID: String?
    /// 原始标题（用于界面展示与排查）。
    var rawTitle: String?

    var id: String { storageKey }

    init(title: String, artist: String, sourceBundleID: String? = nil, rawTitle: String? = nil) {
        self.title = title
        self.artist = artist
        self.sourceBundleID = sourceBundleID
        self.rawTitle = rawTitle
    }

    /// 从系统媒体信息构造，内部完成归一化。
    init(rawTitle: String, rawArtist: String, sourceBundleID: String? = nil) {
        let normalized = SongIdentityNormalizer.normalize(title: rawTitle, artist: rawArtist)
        self.title = normalized.title
        self.artist = normalized.artist
        self.sourceBundleID = sourceBundleID
        self.rawTitle = rawTitle
    }

    /// 三级缓存表的主键。例：`周杰伦_晴天`
    var storageKey: String { SongIdentityNormalizer.key(title: title, artist: artist) }

    /// 反向键（`歌名_歌手`）。
    /// 媒体信息只有标题、无法确定「歌名 - 歌手」还是「歌手 - 歌名」时，
    /// 命中查询会同时试正反两种顺序，避免仅仅因为拆分顺序不同就匹配不上。
    var alternateStorageKey: String { SongIdentityNormalizer.key(title: artist, artist: title) }

    var displayName: String {
        if title.isEmpty && artist.isEmpty { return "未识别到歌曲 / 音源" }
        if artist.isEmpty { return title }
        if title.isEmpty { return artist }
        return "\(title) — \(artist)"
    }

    var hasUsableMetadata: Bool { !title.isEmpty || !artist.isEmpty }
}

// MARK: - 检测结果与状态

enum DetectionMode: String, Codable, CaseIterable, Identifiable {
    case liveAI   // 模式 A：AI 智能基调（麦克风 / 线路输入实时分析）
    case player   // 模式 B：伴奏播放器（ScreenCaptureKit 系统音频 / BlackHole）

    var id: String { rawValue }
    var label: String {
        switch self {
        case .liveAI: return "AI 实时输入"
        case .player: return "伴奏播放器"
        }
    }
}

struct KeyResult: Codable {
    var key: KeySignature
    var confidence: Double       // 0...1
    var timestamp: Date
    var source: KeySource
    /// 三级决策的文字说明（命中方式 / 匹配距离 / 稳定化统计）。
    var detail: String?

    init(key: KeySignature,
         confidence: Double,
         timestamp: Date = Date(),
         source: KeySource,
         detail: String? = nil) {
        self.key = key
        self.confidence = confidence
        self.timestamp = timestamp
        self.source = source
        self.detail = detail
    }
}

/// 悬浮窗状态灯：检测中（黄）/ 已同步（绿）/ MIDI 未连接或异常（红）/ 已暂停（灰）。
enum SyncStatus: String, Identifiable {
    case detecting, synced, midiError, paused
    var id: String { rawValue }
    var label: String {
        switch self {
        case .detecting: return "检测中"
        case .synced: return "已同步"
        case .midiError: return "MIDI 异常"
        case .paused: return "已暂停"
        }
    }
}

enum DetectorState: String {
    case idle, starting, running, paused, failed
}

// MARK: - 本地缓存表记录

/// 第一级：手动更正记录。**永远不被云端同步覆盖**。
struct ManualKeyRecord: Codable, Identifiable, Equatable {
    var songKey: String
    var title: String
    var artist: String
    var key: KeySignature
    var updatedAt: Date

    var id: String { songKey }
}

/// 第二级：云端数据表曲库的本地缓存行。
struct CloudSong: Codable, Identifiable, Equatable {
    var id: String
    var songName: String
    var artist: String
    var key: KeySignature
    /// 原样保留云端 `updated_at` 字符串，用于增量拉取的 gt 过滤。
    var updatedAt: String
    /// 归一化后的查询键（写入时算好，避免每次查询重算）。
    var songKey: String
}

/// 第三级：AI 稳定结果的自动缓存。不覆盖手动 / 云端。
struct AutoKeyRecord: Codable, Identifiable, Equatable {
    var songKey: String
    var title: String
    var artist: String
    var key: KeySignature
    var hits: Int
    var updatedAt: Date

    var id: String { songKey }
}

/// 云端匹配结果（精准 / 模糊）。
struct CloudMatch: Equatable {
    enum Kind: String { case exact, fuzzy }
    var song: CloudSong
    var kind: Kind
    /// 模糊匹配时是编辑距离；精准匹配为 0。
    var distance: Int

    var detail: String {
        kind == .exact ? "云端精准匹配" : "云端模糊匹配（编辑距离 \(distance)）"
    }
}

/// 增量同步状态（持久化在 SQLite 的 sync_state 表）。
struct SyncState: Equatable {
    var lastUpdatedAt: String?
    var lastSyncAt: Date?
    var cachedCount: Int
    var lastError: String?

    static let empty = SyncState(lastUpdatedAt: nil, lastSyncAt: nil, cachedCount: 0, lastError: nil)
}

/// 内置的云端曲库连接。
///
/// 连接参数**不写进源码**。仓库里只有 `Resources/CloudConfig.example.json` 占位模板，
/// 真实凭据放在本地文件里（查找顺序见 `candidateURLs()`），不会进版本库：
///
///   1. App 包内 `Contents/Resources/CloudConfig.json`（打包分发用）
///   2. `~/Library/Application Support/Guckey/CloudConfig.json`（`swift build` 直接跑用）
///
/// 两个都找不到时全部留空 —— App 照常启动，只是云端库显示「未配置」，
/// 用户可以在「云端库 → 高级设置」里手动填自己的应用。
enum BuiltinCloud {
    static let appID = config.appID ?? ""
    static let appSecret = config.appSecret ?? ""
    static let link = config.link ?? ""
    static let tableID = config.tableID ?? ""

    private struct Payload: Decodable {
        var appID: String?
        var appSecret: String?
        var link: String?
        var tableID: String?
    }

    private static let config = load()

    private static func load() -> Payload {
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data) else { continue }
            return payload
        }
        return Payload()
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        if let resource = Bundle.main.resourceURL {
            urls.append(resource.appendingPathComponent("CloudConfig.json"))
        }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first {
            urls.append(support.appendingPathComponent("Guckey/CloudConfig.json"))
        }
        return urls
    }
}

/// 云端数据表连接配置。
///
/// 主程序只需要读权限：一个应用 + 一张表，加一条链接就够了。
struct CloudConfig: Codable, Equatable {
    /// 云端开放平台「凭证与基础信息」里的 App ID。
    var appID: String = BuiltinCloud.appID
    /// 同一个页面里的 App Secret。
    var appSecret: String = BuiltinCloud.appSecret
    /// 数据表链接，`/base/…` 与 `/wiki/…` 都认。
    var link: String = BuiltinCloud.link
    /// 要读的数据表；留空则用第一张。
    var tableID: String = BuiltinCloud.tableID
    /// App 启动时自动同步一次。
    var autoSyncOnLaunch: Bool = true

    var isReady: Bool {
        !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 空字段回落到内置值，保证老配置（或误清空）也能直接用。
    func normalized() -> CloudConfig {
        var value = self
        if value.appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.appID = BuiltinCloud.appID }
        if value.appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.appSecret = BuiltinCloud.appSecret }
        if value.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.link = BuiltinCloud.link }
        if value.tableID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.tableID = BuiltinCloud.tableID }
        return value
    }

    /// 只留「用户真正改过」的部分：与内置值相同的字段一律清空。
    /// 高级设置展开时用这份数据，免得把内部地址又抄到界面上。
    func strippingBuiltin() -> CloudConfig {
        var value = self
        if value.appID.trimmingCharacters(in: .whitespacesAndNewlines) == BuiltinCloud.appID { value.appID = "" }
        if value.appSecret.trimmingCharacters(in: .whitespacesAndNewlines) == BuiltinCloud.appSecret { value.appSecret = "" }
        if value.link.trimmingCharacters(in: .whitespacesAndNewlines) == BuiltinCloud.link { value.link = "" }
        if value.tableID.trimmingCharacters(in: .whitespacesAndNewlines) == BuiltinCloud.tableID { value.tableID = "" }
        return value
    }

    /// 全空：展开高级设置时的初始草稿。
    static let blank = CloudConfig(appID: "", appSecret: "", link: "", tableID: "", autoSyncOnLaunch: true)
}

// MARK: - AI 稳定化参数

/// 第三级（AI）专用的稳定化配置，全部可在「稳定化」页调整。
struct StabilizerConfig: Codable, Equatable {
    /// 滑动窗口长度（秒）。
    var windowSeconds: Double = 10
    /// 某调性在窗口内的占比阈值，超过才输出。
    var dominanceRatio: Double = 0.6
    /// 单帧置信度下限（Krumhansl 相关系数低于此值直接丢弃）。
    var minConfidence: Double = 0.7
    /// 首次锁定所需的最少样本数：防止窗口刚有 2–3 帧就抢锁（占比容易虚高）。
    var minSamplesForLock: Int = 6
    /// 迟滞：新调性必须连续保持的秒数。
    var switchHoldSeconds: Double = 3
    /// 迟滞：新调性置信度要比当前调性高出多少（相对比例）才允许切换。
    var switchConfidenceMargin: Double = 0.15
    /// 切歌后的静默期，不发送 MIDI CC。
    var startupSilenceSeconds: Double = 6
    /// 分析频段（带通），聚焦和弦与贝斯。
    var bandLowHz: Double = 60
    var bandHighHz: Double = 500

    static let `default` = StabilizerConfig()
}

// MARK: - MIDI 映射模型

/// 基调输出固定为「宏控制 CC」。
///
/// 为什么是宏控制：Studio One 7 的插入效果器收不到 MIDI（真机实测），但
/// **宏旋钮是宿主参数**，能用 Control Link / MIDI 学习绑到外部控制器的 CC 上；
/// 宏旋钮再通过「添加目标」映射到插件的 Key / Scale 参数。
/// 于是链路是：本工具 → CC → 外部设备 → 宏旋钮 → 插件参数，
/// 插件本身不需要接收 MIDI，也不需要把 Key/Scale 暴露成 automation 参数。
/// 修音插件的「调式」参数差异。
///
/// 每个插件的 Scale 下拉都是一个固定长度的列表，Major / Minor 落在第几项各不相同，
/// 所以选插件比让用户数「调式参数总数」省事得多。
struct TuningPluginPreset: Identifiable, Hashable {
    let id: String
    let name: String
    /// 调式列表的总条目数（= MacroControlConfig.scaleSteps）。
    let scaleCount: Int
    /// Major 在列表里的位置，1 起。
    let majorIndex: Int
    /// Minor 在列表里的位置，1 起。
    let minorIndex: Int

    static let all: [TuningPluginPreset] = [
        TuningPluginPreset(id: "autotunepro", name: "Auto-Tune Pro",
                           scaleCount: 29, majorIndex: 1, minorIndex: 2),
        TuningPluginPreset(id: "autotuneadvanced", name: "Auto-Tune Advanced",
                           scaleCount: 15, majorIndex: 2, minorIndex: 3),
        TuningPluginPreset(id: "autotune2026", name: "Auto-Tune (2026)",
                           scaleCount: 15, majorIndex: 2, minorIndex: 3),
        TuningPluginPreset(id: "wavestune", name: "Waves Tune Realtime",
                           scaleCount: 44, majorIndex: 3, minorIndex: 4),
        TuningPluginPreset(id: "toplinevocaltune", name: "Topline Vocal Tune",
                           scaleCount: 10, majorIndex: 2, minorIndex: 3)
    ]

    /// 早期版本把 id 存成了短名 "topline"，改名后旧配置仍要能解析出来，
    /// 否则老用户重启后插件选择会掉回「自定义」。
    private static let legacyIDs: [String: String] = ["topline": "toplinevocaltune"]

    static func find(_ id: String?) -> TuningPluginPreset? {
        guard let id, !id.isEmpty else { return nil }
        let resolved = legacyIDs[id] ?? id
        return all.first { $0.id == resolved }
    }
}

struct MacroControlConfig: Codable, Equatable {
    /// 只在单通道发送（默认 1）——广播 16 通道会让 MIDI 学习里冒出 16 个重复旋钮。
    /// 只有宿主确实按通道过滤、单通道收不到时，才打开 `broadcastAllChannels` 备选。
    var channel: Int = 1
    var rootCC: Int = 20
    var scaleCC: Int = 22
    /// 宏旋钮行程两端：第一档 / 最后一档对应的 CC 值。低 > 高 即为反向。
    var rootLow: Int = 0
    var rootHigh: Int = 127
    /// 宏旋钮在插件参数上跨过的档位数。Auto-Tune / WavesTune 的 Key 都是 12 档。
    var rootSteps: Int = 12
    var sendScale: Bool = true
    /// 当前选的修音插件（TuningPluginPreset.id）；空串 = 自定义档位数。
    var plugin: String = ""
    /// Scale 是「不定长列表」：Chromatic、Major、Minor…… 条目数随插件而异。
    /// 这里记总条目数，0…127 被等分成这么多档。
    var scaleSteps: Int = 3
    var scaleLow: Int = 0
    var scaleHigh: Int = 127
    var majorValue: Int = 64
    var minorValue: Int = 127
    /// 12 音级的逐项校准覆盖（键为音级 rawValue 的字符串，保证 JSON 里是对象）。
    var rootOverrides: [String: Int] = [:]
    /// 每条 CC 连发次数：个别宿主 / 控制链路对「同值 CC」不响应，连发提高命中率。
    var repeatCount: Int = 2
    var repeatGapMs: Int = 25

    func override(for root: PitchClass) -> Int? { rootOverrides[String(root.rawValue)] }

    mutating func setOverride(_ value: Int?, for root: PitchClass) {
        let key = String(root.rawValue)
        if let value {
            rootOverrides[key] = MIDIController.clamp(value, 0, 127)
        } else {
            rootOverrides.removeValue(forKey: key)
        }
    }
}

extension MacroControlConfig {
    enum CodingKeys: String, CodingKey {
        case channel, rootCC, scaleCC, rootLow, rootHigh, rootSteps, sendScale
        case plugin
        case scaleSteps, scaleLow, scaleHigh, majorValue, minorValue
        case rootOverrides, repeatCount, repeatGapMs
    }

    /// 宽容解码：旧版本 JSON 里没有 scaleSteps / scaleLow / scaleHigh，
    /// 不能让一个缺字段把整份映射（含用户辛苦校准的音级）打回默认。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? 1
        rootCC = try c.decodeIfPresent(Int.self, forKey: .rootCC) ?? 20
        scaleCC = try c.decodeIfPresent(Int.self, forKey: .scaleCC) ?? 22
        rootLow = try c.decodeIfPresent(Int.self, forKey: .rootLow) ?? 0
        rootHigh = try c.decodeIfPresent(Int.self, forKey: .rootHigh) ?? 127
        rootSteps = try c.decodeIfPresent(Int.self, forKey: .rootSteps) ?? 12
        sendScale = try c.decodeIfPresent(Bool.self, forKey: .sendScale) ?? true
        plugin = try c.decodeIfPresent(String.self, forKey: .plugin) ?? ""
        scaleSteps = try c.decodeIfPresent(Int.self, forKey: .scaleSteps) ?? 3
        scaleLow = try c.decodeIfPresent(Int.self, forKey: .scaleLow) ?? 0
        scaleHigh = try c.decodeIfPresent(Int.self, forKey: .scaleHigh) ?? 127
        majorValue = try c.decodeIfPresent(Int.self, forKey: .majorValue) ?? 64
        minorValue = try c.decodeIfPresent(Int.self, forKey: .minorValue) ?? 127
        rootOverrides = try c.decodeIfPresent([String: Int].self, forKey: .rootOverrides) ?? [:]
        repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 2
        repeatGapMs = try c.decodeIfPresent(Int.self, forKey: .repeatGapMs) ?? 25
    }
}

/// 强度（电音大小）0-100% → 0-127 的映射。
/// 「0% 对应 CC 值 X，100% 对应 CC 值 Y」由用户设定；
/// 对 Retune Speed 这类反向语义参数，在映射层用 invert 或直接把 X > Y 处理掉，
/// 不让反转逻辑散落到 UI / MIDI 层。
struct IntensityMapping: Codable, Equatable {
    var ccNumber: Int = 24
    var channel: Int = 1
    var zeroPercentValue: Int = 0
    var hundredPercentValue: Int = 127
    var invert: Bool = false

    func ccValue(for percent: Double) -> Int {
        let p = min(max(percent, 0), 100) / 100.0
        var low = Double(zeroPercentValue)
        var high = Double(hundredPercentValue)
        if invert { swap(&low, &high) }
        let raw = low + (high - low) * p
        return Int(min(max(raw.rounded(), 0), 127))
    }
}

struct MIDIMapping: Codable, Equatable {
    /// 基调主路径：两条 CC 驱动宏控制器的 Root / Scale 旋钮。
    var macro = MacroControlConfig()
    /// 强度（电音大小）独立一条 CC，与宏控制无关。
    var intensity = IntensityMapping()
    var virtualSourceName: String = "Guckey"

    static let `default` = MIDIMapping()
}

extension MIDIMapping {
    enum CodingKeys: String, CodingKey {
        case macro, intensity, virtualSourceName
    }

    /// 宽容解码：旧版本持久化的 JSON 里没有 `macro` 键，不能因此整份映射失效。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        macro = try container.decodeIfPresent(MacroControlConfig.self, forKey: .macro)
            ?? MacroControlConfig()
        intensity = try container.decodeIfPresent(IntensityMapping.self, forKey: .intensity)
            ?? IntensityMapping()
        virtualSourceName = try container.decodeIfPresent(String.self, forKey: .virtualSourceName)
            ?? "Guckey"
    }
}
