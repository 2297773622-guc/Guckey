import Foundation
import SwiftUI
import Combine

// MARK: - 单一状态源

/// 悬浮窗与主窗口共用**同一个实例**。
///
/// 数据流：`MediaMonitor`（系统正在播放）→ `KeyDecisionEngine`（手动 > 云端 > AI）
/// → `MacroCCStrategy`（两条 CC）→ Studio One 外部设备 → 宏旋钮 → 插件 Key / Scale。
/// 电音强度是独立的一条 CC。
final class AppState: ObservableObject, KeyDetectorDelegate {

    // MARK: 基调
    @Published var currentKey: KeySignature = .default
    @Published var keySource: KeySource?
    @Published var confidence: Double = 0
    @Published var status: SyncStatus = .detecting
    @Published var song: SongIdentity?
    @Published var isDetectionPaused = false
    /// AI 正在实时分析（未锁定 / 等待迟滞切换）→ 悬浮窗画脉冲圈。
    @Published var isAnalyzing = false
    @Published var stabilizerSnapshot: KeyStabilizer.Snapshot = .idle
    @Published var decisionDetail: String = ""
    @Published var decisionLog: String = ""
    @Published var cloudMatch: CloudMatch?
    @Published var detectionMode: DetectionMode {
        didSet {
            settings.detectionMode = detectionMode
            detector?.setMode(detectionMode)
        }
    }

    // MARK: 云端
    @Published var cloudConfig: CloudConfig
    @Published var syncState: SyncState = .empty
    @Published var syncProgress: String = ""
    @Published var cloudSearchResults: [CloudSong] = []
    @Published var cloudSearchQuery: String = ""

    // MARK: 稳定化
    @Published var stabilizerConfig: StabilizerConfig

    // MARK: 本地缓存浏览
    @Published var manualRecords: [ManualKeyRecord] = []
    @Published var autoRecords: [AutoKeyRecord] = []
    @Published var manualCount: Int = 0
    @Published var autoCount: Int = 0

    // MARK: 控制
    @Published var intensity: Double {
        didSet {
            settings.intensity = intensity
            sendIntensity()
        }
    }
    @Published var mapping: MIDIMapping
    /// 备选：向全部 16 个通道广播。默认关闭——广播会让 MIDI 学习里冒出 16 个重复旋钮。
    @Published var broadcastAllChannels: Bool {
        didSet {
            settings.broadcastAllChannels = broadcastAllChannels
            macroStrategy.broadcastAllChannels = broadcastAllChannels
        }
    }

    // MARK: 窗口外观
    @Published var isAlwaysOnTop: Bool {
        didSet {
            settings.alwaysOnTop = isAlwaysOnTop
            WindowCoordinator.shared.applyFloatingAppearance()
        }
    }
    @Published var opacity: Double {
        didSet {
            settings.opacity = opacity
            WindowCoordinator.shared.applyFloatingAppearance()
        }
    }
    @Published var isFloatingVisible = true {
        didSet { settings.floatingVisible = isFloatingVisible }
    }
    @Published var demoMode: Bool {
        didSet {
            settings.demoMode = demoMode
            rebuildDetector()
        }
    }

    // MARK: 辅助信息
    @Published var midiLog: [String] = []
    @Published var lastMessage: String?
    @Published var lastCalibrationValue: String?
    @Published var mediaSourceLabel: String = "未启动"

    let midi = MIDIController()
    private let settings = SettingsStore.shared
    private let db = KeyDatabase.shared
    private let mediaMonitor = MediaMonitor()
    private let decisionEngine: KeyDecisionEngine
    private let syncManager: CloudSyncManager

    private var detector: (any KeyDetectorProtocol)?
    private var heartbeat: Timer?
    private var sweepTimer: Timer?
    private var uiTimer: Timer?
    private var lastIntensitySend = Date.distantPast

    private lazy var macroStrategy = MacroCCStrategy(midi: midi) { [weak self] message in self?.log(message) }
    private lazy var intensityController = IntensityOutputController(midi: midi)

    init() {
        mapping = SettingsStore.shared.mapping
        detectionMode = SettingsStore.shared.detectionMode
        intensity = SettingsStore.shared.intensity
        isAlwaysOnTop = SettingsStore.shared.alwaysOnTop
        opacity = SettingsStore.shared.opacity
        isFloatingVisible = SettingsStore.shared.floatingVisible
        demoMode = SettingsStore.shared.demoMode
        broadcastAllChannels = SettingsStore.shared.broadcastAllChannels
        cloudConfig = SettingsStore.shared.cloudConfig
        stabilizerConfig = SettingsStore.shared.stabilizerConfig

        let stabilizer = KeyStabilizer(config: SettingsStore.shared.stabilizerConfig)
        decisionEngine = KeyDecisionEngine(db: KeyDatabase.shared, stabilizer: stabilizer)
        syncManager = CloudSyncManager(db: KeyDatabase.shared)
        syncState = syncManager.state
    }

    // MARK: 生命周期

    /// 只做「不碰硬件」的准备工作，让首帧尽快画出来。
    ///
    /// 以前 MIDI 端点、MediaRemote、音频采集全在这里同步启动，
    /// 其中 `AVAudioEngine.start()` 会同步问 coreaudiod 要设备 ——
    /// 默认输入设备异常时主线程被卡住，Dock 上就是一颗彩虹圈。
    /// 现在重活全部推到首帧之后（`startSubsystems`）。
    func bootstrap() {
        wireDecisionEngine()
        wireSyncManager()
        refreshLocalStores()
        log("Guckey 就绪：三级基调决策 + 宏控制 CC（Root #\(mapping.macro.rootCC) / Scale #\(mapping.macro.scaleCC)，通道 \(broadcastAllChannels ? "1–16 广播" : "\(mapping.macro.channel)")")

        // 0.12s ≈ 首帧 + 一次事件循环，用户已经能看到窗口再动手。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.startSubsystems()
        }
    }

    /// 音频 / MIDI / 媒体监听的真实启动。**不在**启动瞬间阻塞主线程。
    private func startSubsystems() {
        let begin = ProcessInfo.processInfo.systemUptime

        midi.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .connected:
                    if self.status == .midiError { self.status = .synced }
                case .failed, .idle:
                    self.status = .midiError
                }
            }
        }
        midi.onEvent = { [weak self] message in
            DispatchQueue.main.async { self?.log(message) }
        }

        macroStrategy.broadcastAllChannels = broadcastAllChannels
        midi.start(sourceName: mapping.virtualSourceName)

        mediaMonitor.onChange = { [weak self] identity in
            DispatchQueue.main.async { self?.handleMediaChange(identity) }
        }
        mediaMonitor.start()
        mediaSourceLabel = mediaMonitor.isMediaRemoteAvailable ? "MediaRemote" : "降级（AppleScript / 窗口标题）"

        rebuildDetector()
        reapplyKey()
        sendIntensity(force: true)
        startHeartbeat()
        startUITimer()

        let cost = (ProcessInfo.processInfo.systemUptime - begin) * 1000
        log(String(format: "子系统已启动：MIDI / 媒体监听 / 音频采集，耗时 %.0f ms", cost))

        // 云端同步也放到最后：它要联网 + 写库，绝不能和首帧抢主线程。
        if cloudConfig.autoSyncOnLaunch {
            Task { await syncNow() }
        }
    }

    func shutdown() {
        heartbeat?.invalidate(); heartbeat = nil
        sweepTimer?.invalidate(); sweepTimer = nil
        uiTimer?.invalidate(); uiTimer = nil
        mediaMonitor.stop()
        detector?.stopDetection()
        macroStrategy.panic()
        midi.stop()
    }

    private func wireDecisionEngine() {
        decisionEngine.onResult = { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async { self.apply(result) }
        }
        decisionEngine.onStateChange = { [weak self] snapshot in
            guard let self else { return }
            self.stabilizerSnapshot = snapshot.stabilizer
            self.decisionLog = snapshot.lastDecisionLog
            self.cloudMatch = snapshot.cloudMatch
            // AI 已锁定后应该常亮；只有「还没锁定」或「正在迟滞等待切换」才脉冲。
            self.isAnalyzing = snapshot.lockedSource == nil && snapshot.stabilizer.isAnalyzing
        }
        decisionEngine.onLog = { [weak self] message in self?.log(message) }
        decisionEngine.applyStabilizerConfig(stabilizerConfig)
    }

    private func wireSyncManager() {
        // 同步在后台线程跑，回调一律切回主线程再改 @Published。
        // 之前 onStateChange 是后台直接赋值 —— SwiftUI 在后台线程收到变更会插一次
        // 非法 layout 事务，主线程正巧在布局时就会互相等，表现同样是彩虹圈。
        syncManager.onProgress = { [weak self] text in self?.onMain { $0.syncProgress = text } }
        syncManager.onStateChange = { [weak self] state in self?.onMain { $0.syncState = state } }
        syncManager.onError = { [weak self] message in
            self?.onMain { state in
                state.lastMessage = message
                state.log("⚠️ \(message)")
            }
        }
    }

    /// 保证 @Published 只在主线程改；已经在主线程就直接执行，避免多余的一跳。
    private func onMain(_ work: @escaping (AppState) -> Void) {
        if Thread.isMainThread {
            work(self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                work(self)
            }
        }
    }

    private func rebuildDetector() {
        detector?.stopDetection()
        let newDetector: any KeyDetectorProtocol
        if demoMode {
            newDetector = SimulatedKeyDetector()
        } else {
            newDetector = KeyDetectionEngine(initialMode: detectionMode)
        }
        detector = newDetector
        newDetector.delegate = self
        newDetector.setMode(detectionMode)
        newDetector.startDetection()
        status = midi.isReady ? .detecting : .midiError
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        // 值没变时 refresh() 是空操作，仅用于「DAW 中途重连 / 宏面板重新打开」的兜底重申。
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, !self.isDetectionPaused else { return }
            self.macroStrategy.refresh()
        }
    }

    /// 让「AI 分析中」的脉冲与静默倒计时持续刷新。
    private func startUITimer() {
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.decisionEngine.refresh()
            self.mediaSourceLabel = self.mediaMonitor.lastSource
        }
    }

    // MARK: 媒体 → 决策

    private func handleMediaChange(_ identity: SongIdentity?) {
        // 演示模式下由 SimulatedKeyDetector 提供曲目，避免被真实的「无播放」覆盖
        guard !demoMode else { return }
        song = identity
        decisionEngine.handleTrack(identity)
        if identity == nil {
            isAnalyzing = false
            if keySource == nil { status = .detecting }
        }
    }

    // MARK: 三级决策结果 → MIDI

    private func apply(_ result: KeyResult) {
        currentKey = result.key
        keySource = result.source
        confidence = result.confidence
        decisionDetail = result.detail ?? result.source.explanation
        guard midi.isReady else {
            status = .midiError
            return
        }
        macroStrategy.apply(key: result.key, mapping: mapping)
        status = .synced
        if result.source == .manual {
            log("已锁定手动基调：\(result.key.displayName)")
        }
    }

    // MARK: 基调同步

    /// 保存映射表：持久化 + 用新映射立刻重发。
    func commitMapping() {
        settings.mapping = mapping
        objectWillChange.send()
        reapplyKey()
        sendIntensity(force: true)
        log("映射已保存：Root CC#\(mapping.macro.rootCC) / Scale CC#\(mapping.macro.scaleCC)")
    }

    /// 强制把当前基调重发一遍（不受「值未变化」抑制）。
    func reapplyKey() {
        guard midi.isReady, !isDetectionPaused else { return }
        macroStrategy.resend(key: currentKey, mapping: mapping)
        status = .synced
    }

    /// 手动更正统一入口：写 SQLite（第一级）+ 立即同步。
    func manuallyCorrect(to key: KeySignature) {
        let identity = song ?? decisionEngine.snapshot.track
        if identity == nil || identity?.hasUsableMetadata == false {
            lastMessage = "当前未识别到歌曲信息，本次更正只对本次播放生效（不会写入本地库）"
        }
        decisionEngine.manualCorrect(to: key)
        currentKey = key
        keySource = .manual
        confidence = 1.0
        refreshLocalStores()
    }

    func clearManualRecord(_ record: ManualKeyRecord) {
        db.removeManual(songKey: record.songKey)
        refreshLocalStores()
        if song?.storageKey == record.songKey {
            decisionEngine.relevelAfterManualRemoval()
        }
    }

    // MARK: 云端

    func syncNow(force: Bool = false) async {
        await syncManager.sync(force: force)
        await MainActor.run {
            syncState = syncManager.state
            refreshLocalStores()
        }
    }

    func testCloudConnection() async -> String {
        let report = await syncManager.testConnection()
        await MainActor.run {
            syncState = syncManager.state
            refreshLocalStores()
        }
        return report
    }

    func updateCloudConfig(_ config: CloudConfig) {
        cloudConfig = config
        settings.cloudConfig = config
        syncManager.updateConfig(config)
    }

    /// 用户改过的那部分（不含内置值），给「高级设置」显示。
    var cloudOverrides: CloudConfig { settings.cloudOverrides }

    /// 保存用户的改动；留空 = 继续用内置值。
    func updateCloudOverrides(_ overrides: CloudConfig) {
        settings.cloudOverrides = overrides
        let effective = settings.cloudConfig
        cloudConfig = effective
        syncManager.updateConfig(effective)
    }

    func clearCloudCache() {
        db.clearCloudCache()
        refreshLocalStores()
        syncState = db.syncState()
        log("已清空云端缓存（手动记录与 AI 缓存保留）")
    }

    func clearAutoCache() {
        db.clearAutoCache()
        refreshLocalStores()
        log("已清空 AI 自动缓存（手动记录与云端缓存保留）")
    }

    func searchCloud(_ query: String) {
        cloudSearchQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空关键词不再「列出全部」——进页面就是几十行，反而不像搜索。
        cloudSearchResults = trimmed.isEmpty ? [] : db.searchCloud(trimmed, limit: 120)
    }

    /// 只有真输入了关键词才给结果。
    var hasCloudQuery: Bool {
        !cloudSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func cloudPreview() -> [CloudSong] {
        hasCloudQuery ? cloudSearchResults : []
    }

    // MARK: 稳定化

    func updateStabilizerConfig(_ config: StabilizerConfig) {
        stabilizerConfig = config
        settings.stabilizerConfig = config
        decisionEngine.applyStabilizerConfig(config)
        if let engine = detector as? KeyDetectionEngine {
            engine.bandLowHz = config.bandLowHz
            engine.bandHighHz = config.bandHighHz
        }
        stabilizerSnapshot = decisionEngine.snapshot.stabilizer
    }

    func resetStabilizerConfig() {
        updateStabilizerConfig(.default)
        log("稳定化参数已恢复默认")
    }

    // MARK: 宏控制校准

    /// 统一的宏映射改写入口：就地修改 + 立即落盘 + 重发当前基调。
    func updateMacro(resend: Bool = true, _ transform: (inout MacroControlConfig) -> Void) {
        transform(&mapping.macro)
        settings.mapping = mapping
        objectWillChange.send()
        if resend { macroStrategy.resend(key: currentKey, mapping: mapping) }
    }

    var rootCCValue: Int { KeyMIDIMapper.macroRootValue(for: currentKey, config: mapping.macro) }
    var scaleCCValue: Int { KeyMIDIMapper.macroScaleValue(for: currentKey, config: mapping.macro) }

    /// 手动改档位数即「自定义布局」：Major 取第 2 段、Minor 取第 3 段。
    func setScaleSteps(_ steps: Int) {
        let count = max(2, steps)
        updateMacro { cfg in
            cfg.plugin = ""
            cfg.scaleSteps = count
            cfg.majorValue = KeyMIDIMapper.majorScaleValue(steps: count,
                                                           low: cfg.scaleLow,
                                                           high: cfg.scaleHigh)
            cfg.minorValue = KeyMIDIMapper.minorScaleValue(steps: count,
                                                            low: cfg.scaleLow,
                                                            high: cfg.scaleHigh)
        }
        lastCalibrationValue = "调式总数 \(count) → Major=\(mapping.macro.majorValue) / Minor=\(mapping.macro.minorValue)"
    }

    /// 选修音插件：档位数与 Major / Minor 落点按该插件的调式列表一次性填好。
    func selectTuningPlugin(_ plugin: TuningPluginPreset?) {
        guard let plugin else {
            updateMacro(resend: false) { $0.plugin = "" }
            lastCalibrationValue = "自定义调式列表"
            return
        }
        applyTuningPlugin(plugin)
    }

    private func applyTuningPlugin(_ plugin: TuningPluginPreset) {
        updateMacro { cfg in
            cfg.plugin = plugin.id
            cfg.scaleSteps = plugin.scaleCount
            cfg.majorValue = KeyMIDIMapper.scaleValue(steps: plugin.scaleCount,
                                                       index: plugin.majorIndex - 1,
                                                       low: cfg.scaleLow,
                                                       high: cfg.scaleHigh)
            cfg.minorValue = KeyMIDIMapper.scaleValue(steps: plugin.scaleCount,
                                                       index: plugin.minorIndex - 1,
                                                       low: cfg.scaleLow,
                                                       high: cfg.scaleHigh)
        }
        lastCalibrationValue = "\(plugin.name)：\(plugin.scaleCount) 个调式 · Major 第 \(plugin.majorIndex) 项 / Minor 第 \(plugin.minorIndex) 项"
    }

    /// 改了低档 / 高档之后重算：有插件就按插件落点，否则按默认第 2 / 第 3 段。
    func recalcScaleValues() {
        if let preset = TuningPluginPreset.find(mapping.macro.plugin) {
            applyTuningPlugin(preset)
        } else {
            setScaleSteps(mapping.macro.scaleSteps)
        }
    }

    func rootValue(for root: PitchClass) -> Int {
        KeyMIDIMapper.macroRootValue(for: KeySignature(root: root, mode: currentKey.mode),
                                     config: mapping.macro)
    }

    /// 逐音级微调：把某个音级固定到具体 CC 值（写进 rootOverrides 并立即落盘）。
    func adjustRoot(_ root: PitchClass, delta: Int) {
        let current = rootValue(for: root)
        let next = MIDIController.clamp(current + delta, 0, 127)
        mapping.macro.setOverride(next, for: root)
        settings.mapping = mapping
        objectWillChange.send()
        macroStrategy.sendRaw(role: .root, value: next, mapping: mapping)
        lastCalibrationValue = "\(root.symbol) → CC#\(mapping.macro.rootCC) = \(next)"
        if currentKey.root == root {
            macroStrategy.resend(key: currentKey, mapping: mapping)
        }
    }

    func clearRootOverride(_ root: PitchClass) {
        mapping.macro.setOverride(nil, for: root)
        settings.mapping = mapping
        objectWillChange.send()
        lastCalibrationValue = "\(root.symbol) 已恢复公式换算（\(rootValue(for: root))）"
    }

    func clearAllRootOverrides() {
        mapping.macro.rootOverrides.removeAll()
        settings.mapping = mapping
        objectWillChange.send()
        lastCalibrationValue = "已清除全部音级校准"
    }

    /// Scale 微调：Major / Minor 两个值直接加减。
    func adjustScale(major: Bool, delta: Int) {
        var cfg = mapping.macro
        if major {
            cfg.majorValue = MIDIController.clamp(cfg.majorValue + delta, 0, 127)
        } else {
            cfg.minorValue = MIDIController.clamp(cfg.minorValue + delta, 0, 127)
        }
        mapping.macro = cfg
        settings.mapping = mapping
        objectWillChange.send()
        let value = major ? cfg.majorValue : cfg.minorValue
        macroStrategy.sendRaw(role: .scale, value: value, mapping: mapping)
        lastCalibrationValue = "\(major ? "Major" : "Minor") → CC#\(cfg.scaleCC) = \(value)"
        if (currentKey.mode == .major) == major {
            macroStrategy.resend(key: currentKey, mapping: mapping)
        }
    }

    /// 测试扫动：确认宏旋钮到底有没有被这条 CC 驱动。
    /// 扫完自动回到当前基调的值，不会把插件留在错误档位上。
    func sweep(role: MacroCCRole) {
        sweepTimer?.invalidate()
        let cfg = mapping.macro
        let number = role == .root ? cfg.rootCC : cfg.scaleCC
        var values = stride(from: 0, through: 127, by: 16).map { $0 }
        if values.last != 127 { values.append(127) }
        var index = 0
        lastCalibrationValue = "扫动 CC#\(number)…"
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if index >= values.count {
                timer.invalidate()
                self.sweepTimer = nil
                self.macroStrategy.resend(key: self.currentKey, mapping: self.mapping)
                self.lastCalibrationValue = "扫动结束，已回到 \(self.currentKey.displayName)"
                return
            }
            self.macroStrategy.sendRaw(role: role, value: values[index], mapping: self.mapping)
            index += 1
        }
    }

    // MARK: 强度（0-100% → CC）

    func sendIntensity(force: Bool = false) {
        guard midi.isReady else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastIntensitySend) > 0.05 else { return }
        lastIntensitySend = now
        intensityController.apply(percent: intensity, mapping: mapping,
                                  broadcastAllChannels: broadcastAllChannels)
    }

    /// 强度 CC 的 Learn 扫动：让宿主一定能看到这条 CC，扫完回到当前强度值。
    func sweepIntensity() {
        guard midi.isReady else { return }
        sweepTimer?.invalidate()
        let values = [0, 24, 48, 72, 96, 127]
        var index = 0
        lastCalibrationValue = "扫动 强度 CC#\(mapping.intensity.ccNumber)…"
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if index >= values.count {
                timer.invalidate()
                self.sweepTimer = nil
                self.lastIntensitySend = .distantPast
                self.sendIntensity(force: true)
                self.lastCalibrationValue = "强度 CC 扫动结束，已回到 \(Int(self.intensity))%"
                return
            }
            self.intensityController.send(rawValue: values[index],
                                          mapping: self.mapping,
                                          broadcastAllChannels: self.broadcastAllChannels)
            index += 1
        }
    }

    // MARK: 检测控制

    func togglePause() {
        isDetectionPaused.toggle()
        if isDetectionPaused {
            detector?.pauseDetection()
            macroStrategy.panic()
            status = .paused
        } else {
            detector?.resumeDetection()
            status = .detecting
            mediaMonitor.refreshNow()
            decisionEngine.handleTrack(song)
            reapplyKey()
        }
    }

    func cycleDetectionMode() {
        let all = DetectionMode.allCases
        let next = all[((all.firstIndex(of: detectionMode) ?? 0) + 1) % all.count]
        detectionMode = next
        status = .detecting
        log("检测模式切换为 \(next.label)")
    }

    func setDetectionMode(_ mode: DetectionMode) { detectionMode = mode }

    func refreshMedia() {
        mediaMonitor.refreshNow()
        log("已请求刷新系统媒体信息（来源：\(mediaMonitor.lastSource)）")
    }

    // MARK: 窗口 / 视图动作

    func toggleFloating() { WindowCoordinator.shared.toggleFloating() }
    func showMainWindow() { WindowCoordinator.shared.showMainWindow() }

    func refreshLocalStores() {
        manualRecords = db.allManual()
        autoRecords = db.allAuto()
        manualCount = manualRecords.count
        autoCount = autoRecords.count
        syncState = db.syncState()
    }

    /// 修改虚拟源名称后重建端点（DAW 里需要重新选择该输入）。
    func updateVirtualSourceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != mapping.virtualSourceName else { return }
        mapping.virtualSourceName = trimmed
        settings.mapping = mapping
        midi.stop()
        midi.start(sourceName: trimmed)
        reapplyKey()
        sendIntensity(force: true)
        log("虚拟 MIDI 源已重建：\(trimmed)（请在 DAW 中重新选择该输入）")
    }

    func log(_ message: String) {
        let line = "[\(Self.timeString())] \(message)"
        if Thread.isMainThread {
            appendLog(line)
        } else {
            DispatchQueue.main.async { [weak self] in self?.appendLog(line) }
        }
    }

    private func appendLog(_ line: String) {
        midiLog.insert(line, at: 0)
        if midiLog.count > 160 { midiLog.removeLast(midiLog.count - 160) }
    }

    private static func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: - KeyDetectorDelegate（引擎保证主线程回调）

    func keyDetector(_ detector: any KeyDetectorProtocol, didProduce result: KeyResult) {
        guard !isDetectionPaused else { return }
        decisionEngine.ingestAI(result.key, confidence: result.confidence)
    }

    func keyDetector(_ detector: any KeyDetectorProtocol, didUpdateIdentity song: SongIdentity) {
        // 演示模式：由模拟检测器提供曲目
        guard demoMode else { return }
        self.song = song
        decisionEngine.handleTrack(song)
    }

    func keyDetector(_ detector: any KeyDetectorProtocol, didChangeState state: DetectorState) {
        switch state {
        case .running:
            if status != .synced { status = .detecting }
        case .paused:
            status = .paused
        case .failed:
            status = .detecting
        case .idle, .starting:
            break
        }
    }

    func keyDetector(_ detector: any KeyDetectorProtocol, didFail message: String) {
        lastMessage = message
        log(message)
    }
}
