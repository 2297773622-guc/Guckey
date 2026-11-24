import Foundation
import CoreMIDI

// MARK: - Core MIDI 虚拟源

/// 创建「Guckey」虚拟 MIDI 源。
/// DAW 中把这个源作为 Auto-Tune / WavesTune 所在轨道的 MIDI 输入即可。
///
/// 关键实现点：虚拟源对外发事件必须用 `MIDIReceived(source, packetList)`，
/// 而不是 MIDISend(port, destination, ...)。后者是往别的端点写，
/// 虚拟源用前者才会让「订阅该虚拟源」的 DAW 收到 Note On / CC。
///
/// 本类只做 MIDI 事件输出，不加载任何 VST3 / AU / AAX 插件，
/// 不创建 AVAudioUnit，不接入任何音频渲染链路。
final class MIDIController {

    enum State {
        case idle
        case connected
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var isReady = false

    /// 状态变化（驱动悬浮窗红灯 / 绿灯）。
    var onStateChange: ((State) -> Void)?
    /// 事件日志（主窗口调试面板用）。
    var onEvent: ((String) -> Void)?

    private var client: MIDIClientRef = 0
    private var outputPort: MIDIPortRef = 0
    private var virtualSource: MIDIEndpointRef = 0

    // 所有公开方法约定在主线程调用（AppState ↔ SwiftUI 均在主线程）。
    func start(sourceName: String) {
        guard !isReady else { return }

        var status = MIDIClientCreateWithBlock("Guckey MIDI Client" as CFString, &client) { _ in }
        guard status == noErr else { return fail("MIDIClientCreateWithBlock 失败: \(status)") }

        status = MIDIOutputPortCreate(client, "Guckey MIDI Out" as CFString, &outputPort)
        guard status == noErr else { return fail("MIDIOutputPortCreate 失败: \(status)") }

        // 注：Core MIDI 里创建虚拟源的真实符号是 MIDISourceCreateWithProtocol
        // （旧名 MIDISourceCreate，macOS 11+ 推荐带协议版本）。
        // 需求文档里常见的 "MIDICreateVirtualSource" 并非 SDK 中的函数，这里用真实 API。
        status = MIDISourceCreateWithProtocol(client, sourceName as CFString,
                                              MIDIProtocolID._1_0, &virtualSource)
        guard status == noErr else { return fail("MIDISourceCreateWithProtocol 失败: \(status)") }

        isReady = true
        state = .connected
        onStateChange?(.connected)
        onEvent?("虚拟 MIDI 源已创建：\(sourceName)")
    }

    func stop() {
        guard isReady else { return }
        sendAllNotesOff(channel: 0)
        if virtualSource != 0 { MIDIEndpointDispose(virtualSource); virtualSource = 0 }
        if outputPort != 0 { MIDIPortDispose(outputPort); outputPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        isReady = false
        state = .idle
        onStateChange?(.idle)
    }

    private func fail(_ message: String) {
        state = .failed(message)
        onStateChange?(.failed(message))
        onEvent?("⚠️ \(message)")
    }

    // MARK: 事件构造

    /// 发送一条短 MIDI 消息（3 字节以内：Note On/Off、CC、Program Change 等）。
    func send(_ bytes: [UInt8]) {
        guard isReady, !bytes.isEmpty else {
            if !isReady { onEvent?("⚠️ MIDI 未就绪，事件被丢弃") }
            return
        }

        var packetList = MIDIPacketList()
        let firstPacket = MIDIPacketListInit(&packetList)
        let timestamp = mach_absolute_time()
        let listSize = MemoryLayout<MIDIPacketList>.size
        let payload = Array(bytes.prefix(64))

        payload.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = MIDIPacketListAdd(&packetList, listSize, firstPacket, timestamp,
                                  payload.count, base)
        }

        let status = MIDIReceived(virtualSource, &packetList)
        if status != noErr {
            onEvent?("⚠️ MIDIReceived 失败: \(status)")
            state = .failed("发送失败 (\(status))")
            onStateChange?(state)
        }
        // 不逐条记录：全通道广播时每个音阶音符会产生 16 条事件，刷屏且无信息量。
        // 策略层会记一条汇总（调性 + 按住的音符集合），错误仍通过 onEvent 上报。
    }

    /// channel = 0 时向全部 16 个 MIDI 通道广播。
    /// Studio One 的 External Devices / 乐器轨常按通道过滤，广播可排除通道不匹配问题。
    func sendNoteOn(note: UInt8, velocity: UInt8, channel: Int) {
        for ch in Self.channels(channel) {
            send([0x90 | ch, min(note, 127), min(velocity, 127)])
        }
    }

    func sendNoteOff(note: UInt8, channel: Int) {
        for ch in Self.channels(channel) {
            send([0x80 | ch, min(note, 127), 0])
        }
    }

    func sendCC(number: Int, value: Int, channel: Int) {
        for ch in Self.channels(channel) {
            send([0xB0 | ch,
                  UInt8(Self.clamp(number, 0, 127)),
                  UInt8(Self.clamp(value, 0, 127))])
        }
    }

    private static func channels(_ channel: Int) -> [UInt8] {
        if channel == 0 { return (1...16).map { UInt8($0 - 1) } }
        return [UInt8(clamp(channel - 1, 0, 15))]
    }

    /// 列出系统当前所有 MIDI 源，供「宿主配置向导」自检虚拟端口是否已存在。
    func availableSources() -> [String] {
        let count = MIDIGetNumberOfSources()
        guard count > 0 else { return [] }
        return (0..<count).compactMap { index -> String? in
            let endpoint = MIDIGetSource(index)
            var name: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name) == noErr,
                  let unmanaged = name else { return nil }
            return unmanaged.takeRetainedValue() as String
        }
    }

    /// channel = 0 表示向全部 16 通道广播 All Notes Off（panic）。
    func sendAllNotesOff(channel: Int) {
        if channel == 0 {
            for ch in 1...16 { sendCC(number: 123, value: 0, channel: ch) }
        } else {
            sendCC(number: 123, value: 0, channel: channel)
        }
    }

    // MARK: 工具

    static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }

    private static func describe(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 3 else { return "MIDI \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))" }
        let type = bytes[0] & 0xF0
        let ch = Int(bytes[0] & 0x0F) + 1
        switch type {
        case 0x90: return "Note On   ch\(ch) note=\(bytes[1]) vel=\(bytes[2])"
        case 0x80: return "Note Off  ch\(ch) note=\(bytes[1])"
        case 0xB0: return "CC        ch\(ch) #\(bytes[1]) = \(bytes[2])"
        default:   return "MIDI \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))"
        }
    }
}
