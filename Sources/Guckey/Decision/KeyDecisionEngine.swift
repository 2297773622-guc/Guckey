import Foundation

// MARK: - 三级基调决策引擎

/// 严格按优先级决定当前基调：
///
/// ```
/// 1. 手动更正   （SQLite manual_keys，最高优先，命中后锁定）
/// 2. 云端云端曲库（本地 SQLite 缓存，精准 → Levenshtein 模糊，命中后锁定）
/// 3. AI 实时分析（音频流 → 稳定化 → 输出）
///    └─ 3.5 AI 自动缓存（同一首歌上次算出的稳定结果，秒出）
/// ```
///
/// 关键约束：
/// - 一级 / 二级命中后 `lockedSource != nil`，此后 AI 结果一律丢弃，
///   保证不会向 Studio One 发送任何波动的基调 CC。
/// - 切歌时重置静默计时，静默期内不产出结果。
/// - AI 结果稳定后才写入 `auto_keys`，且永远不覆盖 manual / cloud。
final class KeyDecisionEngine {

    struct Snapshot {
        var track: SongIdentity?
        var result: KeyResult?
        var lockedSource: KeySource?
        var cloudMatch: CloudMatch?
        var stabilizer: KeyStabilizer.Snapshot
        var lastDecisionLog: String
    }

    // MARK: 回调（全部在主线程）

    var onResult: ((KeyResult) -> Void)?
    var onStateChange: ((Snapshot) -> Void)?
    var onLog: ((String) -> Void)?

    // MARK: 依赖

    private let db: KeyDatabase
    private(set) var stabilizer: KeyStabilizer

    // MARK: 状态

    private(set) var track: SongIdentity?
    private(set) var current: KeyResult?
    private(set) var lockedSource: KeySource?
    private(set) var cloudMatch: CloudMatch?
    private var lastDecisionLog = "等待媒体信息…"

    init(db: KeyDatabase = .shared, stabilizer: KeyStabilizer = KeyStabilizer()) {
        self.db = db
        self.stabilizer = stabilizer
    }

    var snapshot: Snapshot {
        Snapshot(track: track,
                 result: current,
                 lockedSource: lockedSource,
                 cloudMatch: cloudMatch,
                 stabilizer: stabilizer.snapshot,
                 lastDecisionLog: lastDecisionLog)
    }

    var isLocked: Bool { lockedSource != nil }

    func applyStabilizerConfig(_ config: StabilizerConfig) {
        stabilizer.applyConfig(config)
        notify()
    }

    // MARK: 切歌

    /// 媒体信息变化。nil = 当前没有歌曲（停止播放 / 关闭播放器）。
    func handleTrack(_ identity: SongIdentity?) {
        track = identity
        cloudMatch = nil
        current = nil
        lockedSource = nil
        stabilizer.armSilence()

        guard let identity else {
            lastDecisionLog = "没有可识别的歌曲：AI 只在有曲目信息时才会锁定基调"
            notify()
            return
        }

        // 第一级：手动
        if let manual = db.manual(for: identity.storageKey) {
            let result = KeyResult(key: manual.key, confidence: 1.0, source: .manual,
                                   detail: "本地手动记录 · \(identity.storageKey)")
            lock(result, source: .manual)
            lastDecisionLog = "① 手动命中：\(identity.displayName) → \(manual.key.displayName)"
            emit(result)
            return
        }

        // 第二级：云端缓存
        if let match = db.matchCloud(identity) {
            cloudMatch = match
            let result = KeyResult(key: match.song.key,
                                   confidence: match.kind == .exact ? 1.0 : 0.85,
                                   source: .cloud,
                                   detail: "\(match.detail) · \(match.song.songName) - \(match.song.artist)")
            lock(result, source: .cloud)
            lastDecisionLog = "② 云端命中（\(match.kind.rawValue)）：\(identity.displayName) → \(match.song.key.displayName)"
            emit(result)
            return
        }

        // 第三级备选：AI 自动缓存（同一首歌之前算过）
        if let cached = db.auto(for: identity.storageKey) {
            let result = KeyResult(key: cached.key, confidence: 0.9, source: .ai,
                                   detail: "AI 自动缓存（命中 \(cached.hits) 次）")
            current = result
            lastDecisionLog = "③ AI 缓存：\(identity.displayName) → \(cached.key.displayName)"
            emit(result)
            // 缓存值同样先锁定，避免静默期一过又被实时结果推翻
            return
        }

        // 第三级：实时 AI
        lastDecisionLog = "③ 前两级未命中，启动 AI 实时分析（静默 \(Int(stabilizer.config.startupSilenceSeconds)) 秒）"
        notify()
    }

    // MARK: AI 输入

    /// 检测引擎每产出一帧原始结果就调用一次。
    /// 返回 true 表示该结果被采纳（用于 UI 提示）。
    @discardableResult
    func ingestAI(_ key: KeySignature, confidence: Double, now: Date = Date()) -> Bool {
        // 一 / 二级已锁定：直接丢弃，杜绝基调 CC 抖动
        if lockedSource != nil { return false }

        switch stabilizer.push(key: key, confidence: confidence, now: now) {
        case .none:
            notify()
            return false
        case let .accepted(stableKey, stableConfidence, ratio):
            let result = KeyResult(key: stableKey,
                                   confidence: stableConfidence,
                                   source: .ai,
                                   detail: String(format: "AI 稳定输出｜窗口占比 %.0f%%｜置信度 %.0f%%",
                                                  ratio * 100, stableConfidence * 100))
            current = result
            lastDecisionLog = "③ AI 锁定：\(stableKey.displayName)（占比 \(Int(ratio * 100))%）"
            if let track, track.hasUsableMetadata {
                db.saveAuto(track, key: stableKey)
            }
            emit(result)
            return true
        }
    }

    // MARK: 手动更正

    /// 第一级入口：写 SQLite 并立即锁定。
    func manualCorrect(to key: KeySignature) {
        guard let track, track.hasUsableMetadata else {
            let result = KeyResult(key: key, confidence: 1.0, source: .manual,
                                   detail: "未识别到歌曲标识，本次更正不写库")
            current = result
            lock(result, source: .manual)
            lastDecisionLog = "手动更正（临时）：\(key.displayName)（没有歌曲信息，未写库）"
            emit(result)
            return
        }
        let record = db.saveManual(track, key: key)
        let result = KeyResult(key: record.key, confidence: 1.0, source: .manual,
                               detail: "已写入本地 SQLite · \(record.songKey)")
        current = result
        lock(result, source: .manual)
        lastDecisionLog = "手动更正并写库：\(track.displayName) → \(key.displayName)"
        emit(result)
    }

    /// 删除手动记录后重新走一遍三级查询。
    func relevelAfterManualRemoval() {
        let identity = track
        handleTrack(nil)
        handleTrack(identity)
    }

    func refresh() { notify() }

    // MARK: 内部

    private func lock(_ result: KeyResult, source: KeySource) {
        lockedSource = source
        stabilizer.unlock()
    }

    private func emit(_ result: KeyResult) {
        onResult?(result)
        notify()
    }

    private func notify() {
        onStateChange?(snapshot)
    }
}
