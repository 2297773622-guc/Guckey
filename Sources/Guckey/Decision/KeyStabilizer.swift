import Foundation

// MARK: - AI 基调稳定化

/// 第三级（AI）输出的「防抖 + 迟滞 + 静默」三件套。
///
/// 1. **置信度过滤**：单帧 Krumhansl 相关系数 < `minConfidence` 直接丢弃。
/// 2. **滑动窗口防抖**：维护 `windowSeconds` 秒窗口，某调性占比 > `dominanceRatio` 才输出。
/// 3. **迟滞锁**：新调性必须连续保持 `switchHoldSeconds` 秒，且置信度比当前调性高出
///    `switchConfidenceMargin` 才切换，避免副歌前后反复横跳。
/// 4. **启动静默**：切歌后 `startupSilenceSeconds` 秒内不产出任何结果（上层即不发 CC）。
final class KeyStabilizer {

    struct Observation {
        let key: KeySignature
        let confidence: Double
        let at: Date
    }

    struct Snapshot {
        var windowSeconds: Double
        var sampleCount: Int
        var dominantKey: KeySignature?
        var dominantRatio: Double
        var dominantConfidence: Double
        var lockedKey: KeySignature?
        var pendingKey: KeySignature?
        var pendingSeconds: Double
        var silenceRemaining: Double
        /// 处于「实时分析中」：未锁定，或正在等待迟滞切换。
        var isAnalyzing: Bool
        /// 窗口内各调的占比（调试面板用）。
        var distribution: [(key: KeySignature, ratio: Double)]

        static let idle = Snapshot(windowSeconds: 10, sampleCount: 0, dominantKey: nil,
                                   dominantRatio: 0, dominantConfidence: 0, lockedKey: nil,
                                   pendingKey: nil, pendingSeconds: 0, silenceRemaining: 0,
                                   isAnalyzing: false, distribution: [])
    }

    enum Output {
        /// 不产出（静默期 / 置信度不足 / 还不到阈值）
        case none
        /// 已锁定或已切换到一个稳定调性
        case accepted(KeySignature, confidence: Double, ratio: Double)
    }

    var config: StabilizerConfig

    private var window: [Observation] = []
    private var lockedKey: KeySignature?
    private var lockedConfidence: Double = 0
    private var pendingKey: KeySignature?
    private var pendingSince: Date?
    private var silenceUntil: Date?
    private var lastSnapshot: Snapshot = .idle

    init(config: StabilizerConfig = .default) {
        self.config = config
    }

    // MARK: 外部控制

    /// 切歌 / 换源时调用：清空窗口、解锁，并进入静默期。
    func armSilence(seconds: Double? = nil, now: Date = Date()) {
        window.removeAll()
        lockedKey = nil
        lockedConfidence = 0
        pendingKey = nil
        pendingSince = nil
        silenceUntil = now.addingTimeInterval(seconds ?? config.startupSilenceSeconds)
        lastSnapshot = .idle
        lastSnapshot.silenceRemaining = max(0, silenceUntil!.timeIntervalSince(now))
        lastSnapshot.windowSeconds = config.windowSeconds
    }

    /// 仅解锁，不进入静默（用于手动 / 云端接管后重新交给 AI）。
    func unlock() {
        lockedKey = nil
        lockedConfidence = 0
        pendingKey = nil
        pendingSince = nil
    }

    func applyConfig(_ newValue: StabilizerConfig) {
        config = newValue
    }

    var silenceRemaining: Double {
        guard let silenceUntil else { return 0 }
        return max(0, silenceUntil.timeIntervalSinceNow)
    }

    // MARK: 推入一帧

    func push(key: KeySignature, confidence: Double, now: Date = Date()) -> Output {
        if let silenceUntil, now < silenceUntil {
            lastSnapshot = makeSnapshot(now: now)
            return .none
        }
        guard confidence >= config.minConfidence else {
            lastSnapshot = makeSnapshot(now: now)
            return .none
        }

        window.append(Observation(key: key, confidence: confidence, at: now))
        prune(now: now)
        guard !window.isEmpty else {
            lastSnapshot = makeSnapshot(now: now)
            return .none
        }

        let stats = statistics()
        guard let dominant = stats.dominant else {
            lastSnapshot = makeSnapshot(now: now)
            return .none
        }

        // 还没锁定：达到占比阈值就直接接受
        if lockedKey == nil {
            guard stats.ratio >= config.dominanceRatio,
                  stats.count >= max(3, config.minSamplesForLock) else {
                lastSnapshot = makeSnapshot(now: now)
                return .none
            }
            lockedKey = dominant
            lockedConfidence = stats.confidence
            pendingKey = nil
            pendingSince = nil
            lastSnapshot = makeSnapshot(now: now)
            return .accepted(dominant, confidence: stats.confidence, ratio: stats.ratio)
        }

        // 与当前锁定一致：只更新置信度，不重复输出
        if dominant == lockedKey {
            lockedConfidence = stats.confidence
            pendingKey = nil
            pendingSince = nil
            lastSnapshot = makeSnapshot(now: now)
            return .none
        }

        // 出现新调性：进入迟滞计时
        if pendingKey != dominant {
            pendingKey = dominant
            pendingSince = now
            lastSnapshot = makeSnapshot(now: now)
            return .none
        }
        guard let pendingSince else { return .none }
        let held = now.timeIntervalSince(pendingSince)
        // 「高出 15%」按剩余余量折算：required = locked + margin × (1 - locked)。
        // 直接用 locked × 1.15 会在 locked=0.9 时要求 >1.0，变成永远切不过去。
        let needed = lockedConfidence + config.switchConfidenceMargin * (1 - lockedConfidence)
        guard held >= config.switchHoldSeconds,
              stats.ratio >= config.dominanceRatio,
              stats.confidence >= needed else {
            lastSnapshot = makeSnapshot(now: now)
            return .none
        }

        lockedKey = dominant
        lockedConfidence = stats.confidence
        pendingKey = nil
        self.pendingSince = nil
        lastSnapshot = makeSnapshot(now: now)
        return .accepted(dominant, confidence: stats.confidence, ratio: stats.ratio)
    }

    // MARK: 内部

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-config.windowSeconds)
        if let idx = window.firstIndex(where: { $0.at >= cutoff }), idx > 0 {
            window.removeFirst(idx)
        } else if window.first.map({ $0.at < cutoff }) == true {
            window.removeAll()
        }
    }

    private struct Stats {
        var dominant: KeySignature?
        var ratio: Double
        var confidence: Double
        var count: Int
        var distribution: [(key: KeySignature, ratio: Double)]
    }

    private func statistics() -> Stats {
        var counts: [KeySignature: Int] = [:]
        var confidences: [KeySignature: Double] = [:]
        for item in window {
            counts[item.key, default: 0] += 1
            confidences[item.key, default: 0] += item.confidence
        }
        let total = Double(max(1, window.count))
        let sorted = counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.id < rhs.key.id : lhs.value > rhs.value
        }
        guard let top = sorted.first else {
            return Stats(dominant: nil, ratio: 0, confidence: 0, count: window.count, distribution: [])
        }
        let avg = (confidences[top.key] ?? 0) / Double(top.value)
        let distribution = sorted.map { (key: $0.key, ratio: Double($0.value) / total) }
        return Stats(dominant: top.key,
                     ratio: Double(top.value) / total,
                     confidence: avg,
                     count: window.count,
                     distribution: distribution.map { (key: $0.key, ratio: $0.ratio) })
    }

    private func makeSnapshot(now: Date) -> Snapshot {
        let stats = statistics()
        return Snapshot(windowSeconds: config.windowSeconds,
                        sampleCount: window.count,
                        dominantKey: stats.dominant,
                        dominantRatio: stats.ratio,
                        dominantConfidence: stats.confidence,
                        lockedKey: lockedKey,
                        pendingKey: pendingKey,
                        pendingSeconds: pendingSince.map { now.timeIntervalSince($0) } ?? 0,
                        silenceRemaining: silenceUntil.map { max(0, $0.timeIntervalSince(now)) } ?? 0,
                        isAnalyzing: lockedKey == nil || pendingSince != nil,
                        distribution: stats.distribution.prefix(4).map { (key: $0.key, ratio: $0.ratio) })
    }

    var snapshot: Snapshot { makeSnapshot(now: Date()) }
}
