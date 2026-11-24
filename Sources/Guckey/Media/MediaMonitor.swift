import Foundation
import AppKit
import CoreGraphics

// MARK: - MediaRemote 私有框架桥接

/// `MediaRemote.framework` 是系统自带的私有框架（控制中心「正在播放」用的就是它）。
/// 通过 dlopen + dlsym 读取 `MRMediaRemoteGetNowPlayingInfo`，不链接、不依赖头文件，
/// 取不到（系统限制 / 未来版本移除）时由上层自动降级到 AppleScript 与窗口标题。
final class MediaRemoteBridge {

    typealias GetNowPlayingInfoFn = @convention(c) (DispatchQueue, @convention(block) (CFDictionary?) -> Void) -> Void
    typealias IsPlayingFn = @convention(c) (DispatchQueue, @convention(block) (Bool) -> Void) -> Void

    private var handle: UnsafeMutableRawPointer?
    private let getInfo: GetNowPlayingInfoFn?
    private let getIsPlaying: IsPlayingFn?
    private let queue = DispatchQueue(label: "guckey.mediaremote", qos: .utility)

    /// MediaRemote 是否可用（框架能加载且符号存在）。
    let isAvailable: Bool

    init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        let h = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
        handle = h
        if let h, let sym = dlsym(h, "MRMediaRemoteGetNowPlayingInfo") {
            getInfo = unsafeBitCast(sym, to: GetNowPlayingInfoFn.self)
        } else {
            getInfo = nil
        }
        if let h, let sym = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            getIsPlaying = unsafeBitCast(sym, to: IsPlayingFn.self)
        } else {
            getIsPlaying = nil
        }
        isAvailable = (getInfo != nil)
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    struct Track {
        var title: String
        var artist: String
        var isPlaying: Bool
    }

    /// 异步读取当前「正在播放」信息，回调固定回主线程。
    ///
    /// ⚠️ 踩过的坑（两次崩溃都出在这里）：把 Swift 闭包字面量直接传给 C 函数时，
    /// 编译器按 **@noescape** 处理，而 MediaRemote 是 dispatch_async 之后才调用它 ——
    /// Debug 构建会直接崩「non-escaping closure has escaped」。
    /// 正确做法：把 block 存在**类的存储属性**里（天然是 escaping block），再传给 C 函数。
    func fetch(_ completion: @escaping (Track?) -> Void) {
        guard let getInfo else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let callback = NowPlayingCallback { info in
            guard let info else { completion(nil); return }
            let dict = info as NSDictionary
            let title = (dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String) ?? ""
            let artist = (dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
            let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double) ?? 1.0
            if title.isEmpty && artist.isEmpty {
                completion(nil)
            } else {
                completion(Track(title: title, artist: artist, isPlaying: rate > 0.001))
            }
        }
        liveCallbacks.append(callback)
        if liveCallbacks.count > 8 { liveCallbacks.removeFirst(liveCallbacks.count - 8) }

        queue.async { [weak self] in
            getInfo(DispatchQueue.main, callback.block)
            // 系统在无「正在播放」时可能永不回调：兜底超时，避免轮询卡死
            self?.queue.asyncAfter(deadline: .now() + 0.6) {
                callback.fireOnce(nil)
            }
        }
    }

    /// 保活：block 由 C 侧 dispatch 持有，本地也留一个强引用，防止提前释放。
    private var liveCallbacks: [NowPlayingCallback] = []
}

/// 持有 MediaRemote 的 Objective-C block，并保证「真实回调」与「超时兜底」只生效一次。
private final class NowPlayingCallback {
    let block: @convention(block) (CFDictionary?) -> Void

    init(_ body: @escaping (CFDictionary?) -> Void) {
        let once = OnceFlag()
        block = { info in
            guard once.consume() else { return }
            body(info)
        }
    }

    func fireOnce(_ info: CFDictionary?) {
        block(info)
    }
}

private final class OnceFlag {
    private var fired = false
    private let lock = NSLock()

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: - 系统媒体监听

/// 实时获取当前播放的「歌手 + 歌名」，归一化后产出 `SongIdentity`。
///
/// 三条取数路径，按可靠性降级：
/// 1. MediaRemote（覆盖 QQ 音乐 / 网易云 / Spotify / Apple Music / 浏览器）
/// 2. AppleScript（Music / Spotify 的 player state，MediaRemote 被限制时最稳）
/// 3. 播放器窗口标题（最后兜底，解析质量最差）
final class MediaMonitor {

    /// 当前曲目变化时回调（主线程）。nil = 当前没有可识别的歌曲。
    var onChange: ((SongIdentity?) -> Void)?

    private(set) var current: SongIdentity?
    private(set) var lastSource: String = "未启动"

    private let bridge = MediaRemoteBridge()
    private var timer: Timer?
    private var pollInterval: TimeInterval = 2.0
    private var inFlight = false
    private var lastEmittedKey: String = ""
    private var started = false

    var isMediaRemoteAvailable: Bool { bridge.isAvailable }

    func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = 0.4
        poll()
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
    }

    /// 切歌 / 用户点「立即刷新」时调用，绕过下一轮定时。
    func refreshNow() { poll() }

    // MARK: 轮询

    private func poll() {
        guard !inFlight else { return }
        inFlight = true

        if bridge.isAvailable {
            bridge.fetch { [weak self] track in
                guard let self else { return }
                if let track, !track.title.isEmpty {
                    self.lastSource = "MediaRemote"
                    self.emit(title: track.title, artist: track.artist, isPlaying: track.isPlaying)
                    self.inFlight = false
                    return
                }
                self.fallbackAfterMediaRemoteMiss()
            }
        } else {
            fallbackAfterMediaRemoteMiss()
        }
    }

    private func fallbackAfterMediaRemoteMiss() {
        if let apple = Self.appleScriptNowPlaying() {
            lastSource = "AppleScript"
            emit(title: apple.title, artist: apple.artist, isPlaying: apple.isPlaying)
            inFlight = false
            return
        }
        if let window = Self.windowTitleNowPlaying() {
            lastSource = "窗口标题"
            emit(title: window.title, artist: window.artist, isPlaying: true)
        } else {
            lastSource = bridge.isAvailable ? "MediaRemote（无曲目）" : "不可用"
            emit(title: "", artist: "", isPlaying: false)
        }
        inFlight = false
    }

    /// 只有归一化键变化时才回调，避免每 2 秒刷一次 UI / 触发静默期。
    private func emit(title: String, artist: String, isPlaying: Bool) {
        guard !title.isEmpty || !artist.isEmpty else {
            if current != nil {
                current = nil
                lastEmittedKey = ""
                onChange?(nil)
            }
            return
        }
        let identity = SongIdentity(rawTitle: title, rawArtist: artist,
                                    sourceBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        guard identity.hasUsableMetadata else { return }
        if identity.storageKey == lastEmittedKey { return }
        lastEmittedKey = identity.storageKey
        current = identity
        onChange?(identity)
    }

    // MARK: AppleScript 兜底

    private static func appleScriptNowPlaying() -> (title: String, artist: String, isPlaying: Bool)? {
        // Music.app
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Music" }),
           running.isFinishedLaunching {
            let src = """
            tell application "Music"
                if player state is playing then
                    set t to name of current track
                    set a to artist of current track
                    return t & "\\n" & a
                end if
            end tell
            """
            if let out = runAppleScript(src), !out.isEmpty {
                let parts = out.components(separatedBy: "\n")
                return (parts.first ?? "", parts.count > 1 ? parts[1] : "", true)
            }
        }

        // Spotify
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) {
            let src = """
            tell application "Spotify"
                if player state is playing then
                    set t to name of current track
                    set a to artist of current track
                    return t & "\\n" & a
                end if
            end tell
            """
            if let out = runAppleScript(src), !out.isEmpty {
                let parts = out.components(separatedBy: "\n")
                return (parts.first ?? "", parts.count > 1 ? parts[1] : "", true)
            }
        }
        return nil
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    // MARK: 窗口标题兜底

    private static let playerHints = [
        "qqmusic", "qq音乐", "kugou", "酷狗", "netease", "cloudmusic", "网易云",
        "spotify", "applemusic", "music", "karaoke", "kg.qq"
    ]

    private static func windowTitleNowPlaying() -> (title: String, artist: String)? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var best: String?
        for window in info {
            let owner = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            let title = window[kCGWindowName as String] as? String ?? ""
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0, title.count >= 2, !owner.isEmpty else { continue }
            guard playerHints.contains(where: { owner.contains($0) }) else { continue }
            if best == nil || title.contains(" - ") { best = title }
        }
        guard let best, !best.isEmpty else { return nil }
        let parsed = SongIdentityNormalizer.parseRawTitle(best)
        return (parsed.title, parsed.artist)
    }
}
