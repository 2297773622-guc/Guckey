import Foundation

// MARK: - 双路基调检测引擎

/// 模式 A（liveAI）：麦克风 / 线路输入 → YIN + FFT 色度 → 调性
/// 模式 B（player）：ScreenCaptureKit 系统音频（13+，失败自动降级 BlackHole）→ 同一 DSP 链
///
/// **职责边界**：本引擎只负责「把音频变成逐帧的调性估计（含置信度）」，
/// 不做防抖、不做迟滞、不做静默期 —— 那些全部由 `KeyStabilizer` + `KeyDecisionEngine` 负责。
/// 这样阈值语义只有一处，UI 上的稳定化面板才有意义。
///
/// 本类只做分析：捕获到的 PCM 不会被写出、回放或送入任何音频输出链路。
final class KeyDetectionEngine: KeyDetectorProtocol {

    weak var delegate: (any KeyDetectorDelegate)?

    private let stateLock = NSLock()
    private var _state: DetectorState = .idle
    private var _mode: DetectionMode

    var state: DetectorState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    var mode: DetectionMode {
        stateLock.lock(); defer { stateLock.unlock() }
        return _mode
    }

    /// 平滑窗口：把最近这段时间的色度平均后再匹配，抑制单帧噪声。
    var smoothingWindow: TimeInterval = 1.5
    /// 分析频段（带通），由稳定化面板控制。
    var bandLowHz: Double = 60
    var bandHighHz: Double = 500

    private let fftSize = 4096
    private let hop = 2048

    private let analysisQueue = DispatchQueue(label: "guckey.analysis", qos: .userInitiated)
    private let chromaAnalyzer: FFTChromaAnalyzer?

    private struct Frame {
        let vector: [Double]
        let time: Date
    }

    private var frames: [Frame] = []
    private var pending: [Float] = []
    private var frameCounter = 0
    private var capture: AudioCapturing?
    private var didFallback = false

    init(initialMode: DetectionMode = .player) {
        _mode = initialMode
        chromaAnalyzer = FFTChromaAnalyzer()
    }

    // MARK: KeyDetectorProtocol

    func startDetection() {
        stopDetection()
        setState(.starting)
        frames.removeAll()
        pending.removeAll()
        frameCounter = 0
        didFallback = false
        attachCapture(for: _mode)
        setState(.running)
    }

    func stopDetection() {
        capture?.stop()
        capture = nil
        setState(.idle)
    }

    func pauseDetection() {
        capture?.stop()
        setState(.paused)
    }

    func resumeDetection() {
        startDetection()
    }

    func setMode(_ mode: DetectionMode) {
        stateLock.lock()
        let changed = _mode != mode
        _mode = mode
        stateLock.unlock()
        if changed { startDetection() }
    }

    // MARK: 捕获器装配

    private func attachCapture(for mode: DetectionMode, forceSystemInput: Bool = false) {
        capture?.stop()

        let source: AudioCapturing
        switch mode {
        case .liveAI:
            source = MicrophoneCapture()
        case .player:
            if forceSystemInput {
                source = SystemInputCapture()
            } else if #available(macOS 13.0, *) {
                source = ScreenCaptureKitCapture()
            } else {
                // macOS 12 及以下：没有 ScreenCaptureKit 音频，直接用虚拟声卡
                source = SystemInputCapture()
            }
        }

        capture = source
        source.onSamples = { [weak self] samples, rate in
            self?.consume(samples, rate: rate)
        }
        source.onError = { [weak self] message in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.keyDetector(self, didFail: message)
                if mode == .player, !self.didFallback {
                    self.didFallback = true
                    self.attachCapture(for: .player, forceSystemInput: true)
                    self.delegate?.keyDetector(self,
                        didFail: "已自动降级为虚拟声卡输入：请把 BlackHole 设为系统默认输入设备")
                }
            }
        }
        source.start()
    }

    // MARK: 分帧

    private func consume(_ samples: [Float], rate: Double) {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.pending.append(contentsOf: samples)
            while self.pending.count >= self.fftSize {
                let frame = Array(self.pending.prefix(self.fftSize))
                self.pending.removeFirst(self.hop)
                self.process(frame: frame, rate: rate)
            }
            if self.pending.count > self.fftSize * 8 {
                self.pending.removeFirst(self.pending.count - self.fftSize * 2)
            }
        }
    }

    private func process(frame: [Float], rate: Double) {
        var energy: Float = 0
        for s in frame { energy += s * s }
        let rms = sqrt(energy / Float(frame.count))
        guard rms > 0.0008 else { return }   // 静音门限：不把噪声算进调性

        guard let chromaAnalyzer else { return }
        var vector = chromaAnalyzer.chroma(frame: frame,
                                           sampleRate: rate,
                                           bandLow: bandLowHz,
                                           bandHigh: bandHighHz)

        // YIN 抽稀到 ~12 kHz 再估计 f0，给对应音级加权，加速收敛
        let step = 4
        var decimated: [Float] = []
        decimated.reserveCapacity(frame.count / step)
        var i = 0
        while i < frame.count {
            decimated.append(frame[i])
            i += step
        }
        if let f0 = YINPitchEstimator.estimate(decimated, sampleRate: rate / Double(step)), f0 > 0 {
            let midi = 69.0 + 12.0 * log2(f0 / 440.0)
            let pc = ((Int(midi.rounded()) % 12) + 12) % 12
            vector = vector.map { $0 * 0.9 }
            vector[pc] += 0.1
        }
        let total = vector.reduce(0, +)
        if total > 0 { vector = vector.map { $0 / total } }

        let now = Date()
        frames.append(Frame(vector: vector, time: now))
        let cutoff = now.addingTimeInterval(-max(2.0, smoothingWindow * 2))
        if let idx = frames.firstIndex(where: { $0.time > cutoff }), idx > 0 {
            frames.removeFirst(idx)
        }

        frameCounter += 1
        if frameCounter % 5 == 0 { evaluate(at: now) }   // ≈ 每 0.43s @48k
    }

    // MARK: 逐帧输出

    private func evaluate(at now: Date) {
        let recent = frames.filter { now.timeIntervalSince($0.time) <= smoothingWindow }
        guard recent.count >= 3 else { return }

        var average = [Double](repeating: 0, count: 12)
        for f in recent { for i in 0..<12 { average[i] += f.vector[i] } }
        let n = Double(recent.count)
        average = average.map { $0 / n }

        guard let match = KeyProfileMatcher.bestKey(chroma: average) else { return }
        // 这里不做任何阈值判断：置信度 = 相关系数，交给稳定化模块过滤。
        let result = KeyResult(key: match.key,
                               confidence: match.confidence,
                               timestamp: now,
                               source: .ai,
                               detail: String(format: "r=%.2f Δ=%.2f", match.score, match.margin))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.keyDetector(self, didProduce: result)
        }
    }

    private func setState(_ newState: DetectorState) {
        stateLock.lock()
        _state = newState
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.keyDetector(self, didChangeState: newState)
        }
    }
}

// MARK: - 演示 / 预览用检测器（不访问音频硬件）

/// UI 调试、SwiftUI Preview、无权限环境下的演示模式。
/// 走完整的「媒体信息 → 三级决策 → 稳定化」链路，只是数据是假的。
final class SimulatedKeyDetector: KeyDetectorProtocol {
    weak var delegate: (any KeyDetectorDelegate)?
    private(set) var state: DetectorState = .idle
    private(set) var mode: DetectionMode = .player
    private var timer: Timer?
    private let samples: [KeySignature] = [
        .init(root: .A, mode: .minor),
        .init(root: .D, mode: .minor),
        .init(root: .C, mode: .major)
    ]
    private var index = 0

    func startDetection() {
        stopDetection()
        state = .running
        delegate?.keyDetector(self, didChangeState: .running)
        // 先给一个曲目，让决策引擎走「无手动 / 无云端 → AI」路径
        delegate?.keyDetector(self, didUpdateIdentity:
            SongIdentity(rawTitle: "晴天 (Live)", rawArtist: "周杰伦"))
        // 每 8 帧换一次调：既能触发「窗口占比 > 60% 锁定」，
        // 又能在换调时演示迟滞（需要保持 3 秒才切换）。
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let key = self.samples[(self.index / 8) % self.samples.count]
            self.index += 1
            let result = KeyResult(key: key, confidence: 0.82,
                                   timestamp: Date(), source: .ai, detail: "演示")
            self.delegate?.keyDetector(self, didProduce: result)
        }
    }

    func stopDetection() {
        timer?.invalidate()
        timer = nil
        state = .idle
        delegate?.keyDetector(self, didChangeState: .idle)
    }

    func pauseDetection() {
        timer?.invalidate()
        timer = nil
        state = .paused
        delegate?.keyDetector(self, didChangeState: .paused)
    }

    func resumeDetection() { startDetection() }

    func setMode(_ mode: DetectionMode) { self.mode = mode }
}
