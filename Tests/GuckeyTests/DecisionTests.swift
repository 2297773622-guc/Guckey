import XCTest
@testable import Guckey

// MARK: - 稳定化

final class KeyStabilizerTests: XCTestCase {

    private var base = Date()

    private func config() -> StabilizerConfig {
        var c = StabilizerConfig.default
        c.windowSeconds = 10
        c.dominanceRatio = 0.6
        c.minConfidence = 0.7
        c.switchHoldSeconds = 3
        c.switchConfidenceMargin = 0.15
        c.startupSilenceSeconds = 6
        return c
    }

    func testSilenceWindowBlocksOutput() {
        let s = KeyStabilizer(config: config())
        s.armSilence(now: base)
        for i in 0..<10 {
            let out = s.push(key: .init(root: .C, mode: .major), confidence: 0.95,
                             now: base.addingTimeInterval(Double(i) * 0.5))
            if case .accepted = out { return XCTFail("静默期内不应输出") }
        }
        XCTAssertGreaterThan(s.silenceRemaining, 0)
    }

    func testLowConfidenceIsDropped() {
        let s = KeyStabilizer(config: config())
        s.armSilence(seconds: 0, now: base)
        let out = s.push(key: .init(root: .C, mode: .major), confidence: 0.5, now: base)
        if case .accepted = out { XCTFail("相关系数 0.5 低于 0.7 应丢弃") }
        XCTAssertEqual(s.snapshot.sampleCount, 0)
    }

    func testDominantRatioGatesFirstLock() {
        let s = KeyStabilizer(config: config())
        s.armSilence(seconds: 0, now: base)
        var accepted: KeySignature?
        // 一半 C major，一半 A minor → 任何一方都到不了 60%
        for i in 0..<12 {
            let key = i % 2 == 0 ? KeySignature(root: .C, mode: .major)
                                 : KeySignature(root: .A, mode: .minor)
            if case let .accepted(k, _, _) = s.push(key: key, confidence: 0.9,
                                                    now: base.addingTimeInterval(Double(i))) {
                accepted = k
            }
        }
        XCTAssertNil(accepted, "占比不足时不应锁定")

        for i in 12..<20 {
            if case let .accepted(k, _, _) = s.push(key: .init(root: .C, mode: .major),
                                                    confidence: 0.9,
                                                    now: base.addingTimeInterval(Double(i))) {
                accepted = k
                break
            }
        }
        XCTAssertEqual(accepted?.displayName, "C Major")
    }

    func testHysteresisRequiresHoldAndMargin() {
        let s = KeyStabilizer(config: config())
        s.armSilence(seconds: 0, now: base)
        var t = 0.0
        // 先用 C major 锁定（首次锁定需要 minSamplesForLock=6 帧）
        for _ in 0..<6 {
            _ = s.push(key: .init(root: .C, mode: .major), confidence: 0.9, now: base.addingTimeInterval(t))
            t += 1
        }
        XCTAssertEqual(s.snapshot.lockedKey?.displayName, "C Major")

        // 切成 G major 但置信度只高一点点：即使保持超过 3 秒也不该切
        var switched: KeySignature?
        for _ in 0..<5 {
            if case let .accepted(k, _, _) = s.push(key: .init(root: .G, mode: .major),
                                                   confidence: 0.91,
                                                   now: base.addingTimeInterval(t)) {
                switched = k
                break
            }
            t += 1
        }
        XCTAssertNil(switched, "置信度优势不足 15% 时不应切换")
        XCTAssertEqual(s.snapshot.lockedKey?.displayName, "C Major")

        // 置信度显著更高 + 保持 3 秒 → 允许切换
        var didSwitch = false
        for _ in 0..<6 {
            if case .accepted = s.push(key: .init(root: .G, mode: .major),
                                       confidence: 0.99,
                                       now: base.addingTimeInterval(t)) {
                didSwitch = true
                break
            }
            t += 1
        }
        XCTAssertTrue(didSwitch)
        XCTAssertEqual(s.snapshot.lockedKey?.displayName, "G Major")
    }

    func testSnapshotExposesPendingHold() {
        let s = KeyStabilizer(config: config())
        s.armSilence(seconds: 0, now: base)
        var t = 0.0
        for _ in 0..<6 {
            _ = s.push(key: .init(root: .C, mode: .major), confidence: 0.9, now: base.addingTimeInterval(t))
            t += 1
        }
        // 需要让 D 成为窗口内的多数（但占比仍不到 60%），才会进入迟滞计时
        for _ in 0..<7 {
            _ = s.push(key: .init(root: .D, mode: .minor), confidence: 1.0, now: base.addingTimeInterval(t))
            t += 1
        }
        let snap = s.snapshot
        XCTAssertEqual(snap.pendingKey?.displayName, "D Minor")
        XCTAssertTrue(snap.isAnalyzing)
    }
}

// MARK: - SQLite 缓存

final class KeyDatabaseTests: XCTestCase {

    private var directory: URL!
    private var db: KeyDatabase!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("guckey-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = KeyDatabase(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testManualRoundTripAndUpsert() {
        let identity = SongIdentity(rawTitle: "晴天 (Live)", rawArtist: "周杰伦")
        XCTAssertEqual(identity.storageKey, "周杰伦_晴天")

        _ = db.saveManual(identity, key: .init(root: .B, mode: .major))
        XCTAssertEqual(db.manual(for: identity.storageKey)?.key.displayName, "B Major")

        // 同一首歌再次手动更正应覆盖而不是新增
        _ = db.saveManual(identity, key: .init(root: .C, mode: .minor))
        XCTAssertEqual(db.manualCount(), 1)
        XCTAssertEqual(db.manual(for: identity.storageKey)?.key.displayName, "C Minor")
    }

    func testCloudExactAndFuzzyMatch() {
        let song = CloudSong(id: "1", songName: "晴天", artist: "周杰伦",
                             key: .init(root: .G, mode: .major),
                             updatedAt: "2026-01-01T00:00:00", songKey: "周杰伦_晴天")
        _ = db.upsertCloud([song])

        let exact = db.matchCloud(SongIdentity(rawTitle: "晴天", rawArtist: "周杰伦"))
        XCTAssertEqual(exact?.kind, .exact)
        XCTAssertEqual(exact?.song.key.displayName, "G Major")

        // 少一个字符 → 走模糊（编辑距离 1，容差 2）
        let fuzzy = db.matchCloud(SongIdentity(rawTitle: "晴夭", rawArtist: "周杰伦"))
        XCTAssertEqual(fuzzy?.kind, .fuzzy)
        XCTAssertEqual(fuzzy?.distance, 1)
        XCTAssertNil(db.matchCloud(SongIdentity(rawTitle: "完全不相干", rawArtist: "某某")))
    }

    func testCloudUpsertIsIncrementalById() {
        let a = CloudSong(id: "1", songName: "A", artist: "X", key: .init(root: .C, mode: .major),
                          updatedAt: "2026-01-01T00:00:00", songKey: "x_a")
        let a2 = CloudSong(id: "1", songName: "A", artist: "X", key: .init(root: .D, mode: .minor),
                           updatedAt: "2026-02-01T00:00:00", songKey: "x_a")
        _ = db.upsertCloud([a])
        _ = db.upsertCloud([a2])
        XCTAssertEqual(db.cloudCount(), 1)
        XCTAssertEqual(db.cloud(songKey: "x_a")?.key.displayName, "D Minor")
    }

    func testAutoCacheDoesNotTouchManualOrCloud() {
        let identity = SongIdentity(rawTitle: "七里香", rawArtist: "周杰伦")
        db.saveAuto(identity, key: .init(root: .E, mode: .major))
        XCTAssertEqual(db.auto(for: identity.storageKey)?.key.displayName, "E Major")
        XCTAssertNil(db.manual(for: identity.storageKey), "AI 缓存不能写进手动表")
        XCTAssertNil(db.cloud(songKey: identity.storageKey), "AI 缓存不能写进云端表")
        // 再存一次命中的 hits 增加
        db.saveAuto(identity, key: .init(root: .E, mode: .major))
        XCTAssertEqual(db.auto(for: identity.storageKey)?.hits, 2)
    }

    func testClearCloudKeepsManual() {
        let identity = SongIdentity(rawTitle: "稻香", rawArtist: "周杰伦")
        _ = db.saveManual(identity, key: .init(root: .A, mode: .minor))
        _ = db.upsertCloud([CloudSong(id: "9", songName: "稻香", artist: "周杰伦",
                                      key: .init(root: .A, mode: .major),
                                      updatedAt: "2026-01-01", songKey: identity.storageKey)])
        db.clearCloudCache()
        XCTAssertEqual(db.cloudCount(), 0)
        XCTAssertEqual(db.manualCount(), 1)
    }

    func testSyncStatePersists() {
        db.saveSyncState(lastUpdatedAt: "2026-03-01T12:00:00", lastError: nil)
        XCTAssertEqual(db.syncState().lastUpdatedAt, "2026-03-01T12:00:00")
        db.saveSyncState(lastUpdatedAt: nil, lastError: "boom")
        XCTAssertEqual(db.syncState().lastUpdatedAt, "2026-03-01T12:00:00", "空游标不能清掉已有游标")
        XCTAssertEqual(db.syncState().lastError, "boom")
    }
}

// MARK: - 三级决策

final class KeyDecisionEngineTests: XCTestCase {

    private var directory: URL!
    private var db: KeyDatabase!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("guckey-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = KeyDatabase(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEngine() -> KeyDecisionEngine {
        var config = StabilizerConfig.default
        config.startupSilenceSeconds = 0
        config.minConfidence = 0.7
        let engine = KeyDecisionEngine(db: db, stabilizer: KeyStabilizer(config: config))
        return engine
    }

    func testManualBeatsCloudAndAI() {
        let identity = SongIdentity(rawTitle: "晴天", rawArtist: "周杰伦")
        _ = db.saveManual(identity, key: .init(root: .B, mode: .major))
        _ = db.upsertCloud([CloudSong(id: "1", songName: "晴天", artist: "周杰伦",
                                      key: .init(root: .G, mode: .major),
                                      updatedAt: "2026-01-01", songKey: identity.storageKey)])

        let engine = makeEngine()
        var results: [KeyResult] = []
        engine.onResult = { results.append($0) }
        engine.handleTrack(identity)

        XCTAssertEqual(results.first?.source, .manual)
        XCTAssertEqual(results.first?.key.displayName, "B Major")

        // 一级锁定后，AI 结果必须被完全忽略
        for i in 0..<20 {
            let accepted = engine.ingestAI(.init(root: .D, mode: .minor), confidence: 1.0,
                                           now: Date().addingTimeInterval(Double(i) * 0.5))
            XCTAssertFalse(accepted)
        }
        XCTAssertEqual(results.count, 1, "锁定后不应再产生新结果（避免基调 CC 抖动）")
        XCTAssertTrue(engine.isLocked)
    }

    func testCloudBeatsAIWhenNoManual() {
        let identity = SongIdentity(rawTitle: "起风了", rawArtist: "买辣椒也用券")
        _ = db.upsertCloud([CloudSong(id: "2", songName: "起风了", artist: "买辣椒也用券",
                                      key: .init(root: .D, mode: .major),
                                      updatedAt: "2026-01-01", songKey: identity.storageKey)])
        let engine = makeEngine()
        var results: [KeyResult] = []
        engine.onResult = { results.append($0) }
        engine.handleTrack(identity)

        XCTAssertEqual(results.first?.source, .cloud)
        XCTAssertEqual(results.first?.key.displayName, "D Major")
        XCTAssertFalse(engine.ingestAI(.init(root: .A, mode: .minor), confidence: 1.0))
    }

    func testAIFallbackWhenNoCache() {
        let identity = SongIdentity(rawTitle: "某首新歌", rawArtist: "某歌手")
        let engine = makeEngine()
        var results: [KeyResult] = []
        engine.onResult = { results.append($0) }
        engine.handleTrack(identity)
        XCTAssertTrue(results.isEmpty, "前两级未命中时不立即给结果")

        var now = Date()
        var didLock = false
        for _ in 0..<8 {
            now = now.addingTimeInterval(0.5)
            if engine.ingestAI(.init(root: .F, mode: .minor), confidence: 0.9, now: now) {
                didLock = true
                break
            }
        }
        XCTAssertTrue(didLock)
        XCTAssertEqual(results.last?.source, .ai)
        XCTAssertEqual(results.last?.key.displayName, "F Minor")
        // 稳定结果要沉淀进 auto_keys，下次秒出
        XCTAssertEqual(db.auto(for: identity.storageKey)?.key.displayName, "F Minor")
    }

    func testAutoCacheServedWithoutReanalysis() {
        let identity = SongIdentity(rawTitle: "老歌", rawArtist: "老歌手")
        db.saveAuto(identity, key: .init(root: .A, mode: .major))
        let engine = makeEngine()
        var results: [KeyResult] = []
        engine.onResult = { results.append($0) }
        engine.handleTrack(identity)
        XCTAssertEqual(results.first?.key.displayName, "A Major")
        XCTAssertEqual(results.first?.source, .ai)
        XCTAssertTrue((results.first?.detail ?? "").contains("缓存"))
    }

    func testManualCorrectionWritesToDatabase() {
        let identity = SongIdentity(rawTitle: "演员", rawArtist: "薛之谦")
        let engine = makeEngine()
        var results: [KeyResult] = []
        engine.onResult = { results.append($0) }
        engine.handleTrack(identity)
        engine.manualCorrect(to: .init(root: .C, mode: .major))

        XCTAssertEqual(db.manual(for: identity.storageKey)?.key.displayName, "C Major")
        XCTAssertEqual(results.last?.source, .manual)
    }
}

// MARK: - 云端数据表解析

final class CloudParsingTests: XCTestCase {

    /// 数据表的文本字段回的是 `[{"text": "...", "type": "text"}]`，
    /// 不是裸字符串 —— 这里锁住两种形态都能读。
    func testTextReadsBothShapes() {
        let arrayShape: Any = [["text": "晴天", "type": "text"]]
        XCTAssertEqual(CloudTableClient.text(arrayShape), "晴天")
        XCTAssertEqual(CloudTableClient.text("晴天"), "晴天")
        XCTAssertEqual(CloudTableClient.text(nil), "")
    }

    /// 「调」文字优先。
    ///
    /// 这是踩过的坑：表里「调」和「音级」两列并存时，用户在云端只改看得懂的「调」，
    /// 而程序读数字列 —— 改了等于没改。现在两列冲突时以「调」为准。
    func testSignaturePrefersKeyTextWhenColumnsDisagree() {
        let signature = CloudTableClient.signature(root: 11, keyText: "D", scaleText: "Major")
        XCTAssertEqual(signature?.root, .D, "两列冲突时必须信「调」")
        XCTAssertEqual(signature?.mode, .major)
    }

    /// 「调」被清空时，退回数字列兜底，别让整条记录读不出来。
    func testSignatureFallsBackToNumericColumn() {
        let signature = CloudTableClient.signature(root: 7, keyText: "", scaleText: "Major")
        XCTAssertEqual(signature?.root, .G)
    }

    /// 降号写法也要认（用户在云端里可能手打 B♭）。
    func testSignatureParsesFlatNotation() {
        let signature = CloudTableClient.signature(root: nil, keyText: "B♭", scaleText: "Minor")
        XCTAssertEqual(signature?.root, .ASharp)
        XCTAssertEqual(signature?.mode, .minor)
    }

    func testSignatureReturnsNilWithoutAnyKey() {
        XCTAssertNil(CloudTableClient.signature(root: nil, keyText: "", scaleText: ""))
    }

    func testMillisStringNormalizes() {
        XCTAssertEqual(CloudTableClient.millisString(1_700_000_000_000), "1700000000000")
        XCTAssertEqual(CloudTableClient.millisString(1_700_000_000), "1700000000000", "秒级要补成毫秒")
        XCTAssertEqual(CloudTableClient.millisString(nil), "")
    }
}
