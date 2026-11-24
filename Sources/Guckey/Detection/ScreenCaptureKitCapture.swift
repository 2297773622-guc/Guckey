import Foundation
import AVFoundation
import CoreMedia
import CoreAudioTypes
import ScreenCaptureKit

// MARK: - 模式 B 主路径：ScreenCaptureKit 系统音频捕获（macOS 13+）

/// 截取系统播放音频流做实时基调分析，不依赖任何特定播放器
/// （QQ 音乐 / 酷狗 / 网易云 / 全民 K 歌 / 浏览器 / DAW 都适用）。
///
/// 只订阅 `.audio` 输出，不处理视频帧；不产生任何音频输出。
/// 首次使用系统会弹出「屏幕录制」授权，用户需在系统设置里允许本 App。
@available(macOS 13.0, *)
final class ScreenCaptureKitCapture: NSObject, AudioCapturing, SCStreamOutput, SCStreamDelegate {

    var onSamples: (([Float], Double) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private let handlerQueue = DispatchQueue(label: "vta.screencapture.audio", qos: .userInitiated)
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true

        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                 onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    throw CaptureError.noDisplay
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                // 音频捕获仍需要一个极小的视频尺寸，避免驱动分配整屏帧缓冲
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
                config.showsCursor = false

                let newStream = SCStream(filter: filter, configuration: config, delegate: self)
                try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: handlerQueue)
                try await newStream.startCapture()
                self.stream = newStream
            } catch {
                self.isRunning = false
                let message = "ScreenCaptureKit 启动失败：\(error.localizedDescription)。"
                    + "请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许本 App；"
                    + "或切换到 BlackHole 虚拟声卡捕获。"
                self.onError?(message)
            }
        }
    }

    func stop() {
        isRunning = false
        let current = stream
        stream = nil
        current?.stopCapture { _ in }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, isRunning else { return }
        guard let (samples, rate) = extractMono(sampleBuffer) else { return }
        onSamples?(samples, rate)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        onError?("系统音频流中断：\(error.localizedDescription)")
    }

    // MARK: CMSampleBuffer → 单声道 Float

    private func extractMono(_ sampleBuffer: CMSampleBuffer) -> ([Float], Double)? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        let sampleRate = asbd.mSampleRate
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let bytesPerSample = max(1, Int(asbd.mBitsPerChannel / 8))
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bufferCount = isNonInterleaved ? channels : 1

        // AudioBufferList 变长：1 个 AudioBuffer 内联，其余紧随其后
        let listSize = MemoryLayout<AudioBufferList>.size
            + max(0, bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize,
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }

        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        var retained: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retained
        )
        guard status == noErr else { return nil }
        // Swift 下 CMBlockBuffer 由 ARC 自动管理（CFRelease 已不可用）。
        // 这里显式延长生命周期，确保读取 mData 期间底层内存不被回收。
        defer { withExtendedLifetime(retained) { } }

        let bufferOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) ?? MemoryLayout<UInt32>.size
        let buffers = UnsafeRawPointer(abl)
            .advanced(by: bufferOffset)
            .assumingMemoryBound(to: AudioBuffer.self)
        let count = Int(abl.pointee.mNumberBuffers)
        guard count > 0 else { return nil }

        let frames = Int(buffers[0].mDataByteSize) / (bytesPerSample * (isNonInterleaved ? 1 : channels))
        guard frames > 0 else { return nil }

        var mono = [Float](repeating: 0, count: frames)
        var contributor = 0

        for b in 0..<min(count, bufferCount) {
            guard let data = buffers[b].mData else { continue }
            contributor += isNonInterleaved ? 1 : channels
            if isFloat && bytesPerSample == 4 {
                let p = data.assumingMemoryBound(to: Float.self)
                if isNonInterleaved {
                    for i in 0..<frames { mono[i] += p[i] }
                } else {
                    for i in 0..<frames { mono[i] += p[i * channels + b] }
                }
            } else if !isFloat && bytesPerSample == 2 {
                let p = data.assumingMemoryBound(to: Int16.self)
                if isNonInterleaved {
                    for i in 0..<frames { mono[i] += Float(p[i]) / 32768.0 }
                } else {
                    for i in 0..<frames { mono[i] += Float(p[i * channels + b]) / 32768.0 }
                }
            } else {
                return nil   // 其他格式（24bit 等）：交由上层报错降级
            }
        }

        let scale = 1.0 / Float(max(1, contributor))
        for i in 0..<frames { mono[i] *= scale }
        return (mono, sampleRate)
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "未找到可用的显示器" }
    }
}
