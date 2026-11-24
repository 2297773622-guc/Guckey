import Foundation
import AVFoundation

// MARK: - 音频捕获协议（只进不出）

/// 所有捕获器只负责「把 PCM 交给分析器」。
/// 这里没有 AVAudioEngine 的输出节点连接、没有 AVAudioUnit 实例化、没有插件加载，
/// 也没有任何监听输出：音频数据单向流入 DSP，绝不进入渲染 / 回放链路。
protocol AudioCapturing: AnyObject {
    /// (单声道 Float 采样, 采样率)
    var onSamples: (([Float], Double) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start()
    func stop()
}

// MARK: - PCM 转换

enum AudioBufferConverter {
    static func monoFloat(_ buffer: AVAudioPCMBuffer) -> ([Float], Double)? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)

        if let floatData = buffer.floatChannelData {
            for c in 0..<channels {
                let ch = floatData[c]
                for i in 0..<frames { mono[i] += ch[i] }
            }
        } else if let int16Data = buffer.int16ChannelData {
            for c in 0..<channels {
                let ch = int16Data[c]
                for i in 0..<frames { mono[i] += Float(ch[i]) / 32768.0 }
            }
        } else if let int32Data = buffer.int32ChannelData {
            for c in 0..<channels {
                let ch = int32Data[c]
                for i in 0..<frames { mono[i] += Float(ch[i]) / 2_147_483_648.0 }
            }
        } else {
            return nil
        }

        let scale = 1.0 / Float(max(1, channels))
        for i in 0..<frames { mono[i] *= scale }
        return (mono, buffer.format.sampleRate)
    }
}

// MARK: - 模式 A：麦克风 / 线路输入

/// 使用 AVAudioEngine 的 inputNode 做采集。
/// 注意：这是系统输入节点，**不是** AVAudioUnit 插件；
/// 我们不连接 mainMixerNode / outputNode，因此不产生任何声音输出。
/// 真机运行需在 Info.plist 配置 NSMicrophoneUsageDescription 并授权「麦克风」。
class MicrophoneCapture: AudioCapturing {

    var onSamples: (([Float], Double) -> Void)?
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let sourceLabel: String

    /// **所有** AVAudioEngine 操作都排到这条串行队列上。
    ///
    /// `engine.inputNode` / `prepare()` / `start()` 都会同步问 coreaudiod 要设备，
    /// 默认输入设备被占用（BlackHole 未启动、蓝牙耳机切换中）时能卡住好几秒。
    /// 以前这些都在主线程上跑，于是启动时「有概率彩虹圈」——
    /// 概率取决于当时默认输入设备的状态。现在主线程只负责投递任务。
    private let engineQueue = DispatchQueue(label: "guckey.audio.mic", qos: .userInitiated)
    /// 只在 engineQueue 上读写。
    private var isRunning = false
    private var tapInstalled = false

    init(sourceLabel: String = "麦克风输入") { self.sourceLabel = sourceLabel }

    func start() {
        engineQueue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        engineQueue.async { [weak self] in self?.stopOnQueue() }
    }

    // MARK: 串行队列内部

    private func startOnQueue() {
        guard !isRunning else { return }

        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onError?("\(sourceLabel)：无法获取输入格式（请检查音频输入设备与麦克风权限）")
            return
        }

        if !tapInstalled {
            node.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self, let (samples, rate) = AudioBufferConverter.monoFloat(buffer) else { return }
                self.onSamples?(samples, rate)
            }
            tapInstalled = true
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            onError?("\(sourceLabel) 启动失败：\(error.localizedDescription)")
        }
    }

    private func stopOnQueue() {
        isRunning = false
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }
}

// MARK: - 模式 B 低版本兜底：虚拟声卡（BlackHole / Loopback）作为系统默认输入

/// macOS 12 及以下没有 ScreenCaptureKit 音频捕获时的替代方案：
/// 用户在「系统设置 → 声音 → 输入」把 BlackHole 2ch 设为默认输入，
/// 播放器输出路由到 BlackHole，本捕获器读取默认输入即可。
/// 复用与麦克风相同的采集代码，只是语义不同（不选择设备、不修改系统设置）。
final class SystemInputCapture: MicrophoneCapture {
    init() {
        super.init(sourceLabel: "系统输入（BlackHole / 虚拟声卡）")
    }
}
