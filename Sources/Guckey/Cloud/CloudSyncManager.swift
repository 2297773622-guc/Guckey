import Foundation

// MARK: - 云端数据表客户端（Guckey 侧：只读）

/// 只做「拉全量 → 转成 CloudSong」，不写、不建字段。
/// 写入由 Guckey Control 负责，两边职责分开，主程序不需要写权限。
final class CloudTableClient {

    struct APIError: LocalizedError {
        var http: Int
        var code: Int
        var message: String

        var isPermission: Bool { code == 99991672 || code == 99991673 || http == 403 }

        var errorDescription: String? {
            isPermission
                ? "权限不足（code \(code)）：\(message)"
                : "\(message)（code \(code)）"
        }
    }

    enum Field {
        static let title = "歌名"
        static let artist = "歌手"
        static let key = "调"
        static let root = "音级"
        static let scale = "调式"
        static let updatedAt = "更新时间"
    }

    private let config: CloudConfig
    private let api = "https://open.feishu.cn/open-apis"
    private var token: String?
    private var tokenExpiry: Date = .distantPast
    private var appToken: String = ""
    private var tableID: String = ""

    init(config: CloudConfig) {
        self.config = config
        self.tableID = config.tableID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: token

    private func tenantToken() async throws -> String {
        if let token, Date() < tokenExpiry { return token }
        let (data, http) = try await send(path: "/auth/v3/tenant_access_token/internal",
                                          method: "POST",
                                          body: ["app_id": config.appID.trimmingCharacters(in: .whitespacesAndNewlines),
                                                 "app_secret": config.appSecret.trimmingCharacters(in: .whitespacesAndNewlines)],
                                          authorized: false)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (obj["code"] as? Int) ?? -1
        guard code == 0, let value = obj["tenant_access_token"] as? String else {
            throw APIError(http: http, code: code, message: (obj["msg"] as? String) ?? "获取 tenant_access_token 失败")
        }
        token = value
        tokenExpiry = Date().addingTimeInterval(TimeInterval(max(((obj["expire"] as? Int) ?? 7200) - 300, 60)))
        return value
    }

    // MARK: 链接

    private func resolveAppToken() async throws -> String {
        if !appToken.isEmpty { return appToken }
        let raw = config.link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw APIError(http: 0, code: -1, message: "还没填表格链接") }
        if !raw.contains("/") { appToken = raw; return appToken }

        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
            throw APIError(http: 0, code: -1, message: "链接格式不对")
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else {
            throw APIError(http: 0, code: -1, message: "链接里没有 app_token")
        }
        if parts[0] == "base" {
            appToken = parts[1]
            return appToken
        }
        if parts[0] == "wiki" {
            let (data, http) = try await send(path: "/wiki/v2/spaces/get_node",
                                              method: "GET",
                                              query: [URLQueryItem(name: "token", value: parts[1]),
                                                      URLQueryItem(name: "obj_type", value: "wiki")],
                                              authorized: true)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let code = (obj["code"] as? Int) ?? -1
            guard code == 0 else {
                throw APIError(http: http, code: code,
                               message: ((obj["msg"] as? String) ?? "解析知识库节点失败")
                                   + "（需要 wiki:wiki:readonly 权限，或把表格移到「我的空间」用 /base/ 链接）")
            }
            let node = (obj["data"] as? [String: Any])?["node"] as? [String: Any] ?? [:]
            guard let objToken = node["obj_token"] as? String else {
                throw APIError(http: http, code: code, message: "知识库节点里没有 obj_token")
            }
            appToken = objToken
            return appToken
        }
        throw APIError(http: 0, code: -1, message: "链接不是数据表（应为 /base/ 或 /wiki/）")
    }

    private func resolveTableID() async throws -> String {
        if !tableID.isEmpty { return tableID }
        let app = try await resolveAppToken()
        let (data, http) = try await send(path: "/bitable/v1/apps/\(app)/tables",
                                          method: "GET",
                                          query: [URLQueryItem(name: "page_size", value: "100")],
                                          authorized: true)
        let obj = try decode(data, http: http)
        let items = ((obj["data"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        guard let first = items.first?["table_id"] as? String else {
            throw APIError(http: http, code: -1, message: "这张数据表里没有数据表")
        }
        tableID = first
        return tableID
    }

    // MARK: 读

    /// 全量拉取。曲库是几百条量级，一次 500 行，通常 1 个请求就够。
    func fetchAll() async throws -> [CloudSong] {
        let app = try await resolveAppToken()
        let table = try await resolveTableID()
        var songs: [CloudSong] = []
        var pageToken: String?

        repeat {
            var query = [URLQueryItem(name: "page_size", value: "500")]
            if let pageToken { query.append(URLQueryItem(name: "page_token", value: pageToken)) }
            let (data, http) = try await send(path: "/bitable/v1/apps/\(app)/tables/\(table)/records/search",
                                              method: "POST", query: query, body: [:], authorized: true)
            let obj = try decode(data, http: http)
            let payload = obj["data"] as? [String: Any] ?? [:]
            for item in (payload["items"] as? [[String: Any]]) ?? [] {
                guard let recordID = item["record_id"] as? String else { continue }
                let fields = (item["fields"] as? [String: Any]) ?? [:]
                let title = Self.text(fields[Field.title])
                let artist = Self.text(fields[Field.artist])
                guard !title.isEmpty else { continue }

                // 「调」优先；数字列只在文字为空时兜底
                let root = Self.int(fields[Field.root])
                let keyText = Self.text(fields[Field.key])
                let scaleText = Self.text(fields[Field.scale])
                guard let signature = Self.signature(root: root, keyText: keyText, scaleText: scaleText) else {
                    continue
                }

                let songKey = SongIdentityNormalizer.key(title: title, artist: artist)
                songs.append(CloudSong(id: recordID,
                                       songName: title,
                                       artist: artist,
                                       key: signature,
                                       updatedAt: Self.millisString(fields[Field.updatedAt]),
                                       songKey: songKey))
            }
            pageToken = (payload["has_more"] as? Bool) == true ? (payload["page_token"] as? String) : nil
        } while pageToken != nil

        return songs
    }

    func count() async throws -> Int {
        let app = try await resolveAppToken()
        let table = try await resolveTableID()
        let (data, http) = try await send(path: "/bitable/v1/apps/\(app)/tables/\(table)/records/search",
                                          method: "POST",
                                          query: [URLQueryItem(name: "page_size", value: "1")],
                                          body: [:], authorized: true)
        let obj = try decode(data, http: http)
        let payload = obj["data"] as? [String: Any] ?? [:]
        return (payload["total"] as? Int) ?? 0
    }

    // MARK: 底层

    private func send(path: String,
                      method: String,
                      query: [URLQueryItem] = [],
                      body: [String: Any]? = nil,
                      authorized: Bool) async throws -> (Data, Int) {
        guard var components = URLComponents(string: api + path) else {
            throw APIError(http: 0, code: -1, message: "URL 构造失败")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw APIError(http: 0, code: -1, message: "URL 构造失败")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if authorized {
            request.setValue("Bearer \(try await tenantToken())", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
        } catch let error as URLError {
            let hint: String
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed: hint = "域名解析失败"
            case .timedOut: hint = "请求超时（20s）"
            default: hint = error.localizedDescription
            }
            throw APIError(http: -1, code: error.errorCode, message: hint)
        }
    }

    private func decode(_ data: Data, http: Int) throws -> [String: Any] {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (obj["code"] as? Int) ?? -1
        guard code == 0, (200..<300).contains(http) else {
            throw APIError(http: http, code: code, message: (obj["msg"] as? String) ?? "接口返回异常")
        }
        return obj
    }

    // MARK: 解析

    static func text(_ value: Any?) -> String {
        switch value {
        case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let arr as [[String: Any]]:
            return arr.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        case let dict as [String: Any]:
            return (dict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        default: return ""
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let i as Int: return i
        case let d as Double: return Int(d.rounded())
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func millisString(_ value: Any?) -> String {
        guard let n = int(value) else { return "" }
        return String(n > 1_000_000_000_000 ? n : n * 1000)
    }

    /// 以「调」这一列的文字为准（`G` / `A♯` / `B♭` 都认）。
    ///
    /// 「调」优先是硬约束：用户只会在云端里改看得懂的「调」。
    /// 早期并存过「音级」数字列，程序读数字列导致「改了等于没改」，那一列已废弃，
    /// 这里保留数字兜底只为兼容个别老表。
    static func signature(root: Int?, keyText: String, scaleText: String) -> KeySignature? {
        if let parsed = KeySignature.parse(root: keyText, scale: scaleText) {
            return parsed
        }
        guard let root, (0..<12).contains(root), let pc = PitchClass(rawValue: root) else {
            return nil
        }
        return KeySignature(root: pc, mode: KeyMode.parse(scaleText) ?? .major)
    }

    static func describe(_ error: Error) -> String {
        if let api = error as? APIError {
            var text = api.errorDescription ?? api.message
            if api.isPermission {
                text += "\n   → 到「权限管理」开通 bitable:app，并重新创建版本发布。"
            }
            return text
        }
        return error.localizedDescription
    }
}

// MARK: - 同步管理

/// 第二级（云端）的数据源：云端数据表。
///
/// 云端没有 `updated_at > cursor` 这种增量过滤，所以每次都拉全量
/// （几百条、一次 500 行），再整体覆盖本地缓存。
/// 这样还顺带解决了「云端删掉的歌在本地缓存里赖着不走」的问题。
final class CloudSyncManager {

    private let db: KeyDatabase
    private let settings = SettingsStore.shared

    var onStateChange: ((SyncState) -> Void)?
    var onProgress: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var config: CloudConfig

    /// 上一次同步还没结束就再点「全量刷新」，直接忽略。
    /// 用锁而不是裸 Bool：sync 在后台任务里跑，`isSyncing` 以前是跨线程读写的。
    private let syncLock = NSLock()
    private var syncingFlag = false
    var isSyncing: Bool {
        syncLock.lock(); defer { syncLock.unlock() }
        return syncingFlag
    }

    private func beginSync() -> Bool {
        syncLock.lock(); defer { syncLock.unlock() }
        if syncingFlag { return false }
        syncingFlag = true
        return true
    }

    private func endSync() {
        syncLock.lock()
        syncingFlag = false
        syncLock.unlock()
    }

    init(db: KeyDatabase = .shared) {
        self.db = db
        self.config = settings.cloudConfig
    }

    func updateConfig(_ newValue: CloudConfig) {
        config = newValue
        settings.cloudConfig = newValue
    }

    var state: SyncState {
        var s = db.syncState()
        if s.cachedCount == 0 { s.cachedCount = db.cloudCount() }
        return s
    }

    // MARK: 同步

    func sync(force: Bool = false) async {
        guard beginSync() else { return }
        publishProgress("准备同步…")
        defer { endSync() }

        guard !config.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let message = "还没配置云端曲库"
            db.saveSyncState(lastUpdatedAt: nil, lastError: message)
            publishProgress("")
            onStateChange?(state)
            return
        }

        publishProgress("正在读取云端曲库…")
        do {
            let client = CloudTableClient(config: config)
            let songs = try await client.fetchAll()
            let written = db.upsertCloud(songs)
            // 云端删掉的歌，本地缓存也要跟着消失，否则会一直命中旧调性
            let pruned = db.pruneCloud(keeping: Set(songs.map(\.id)))
            db.saveSyncState(lastUpdatedAt: nil, lastError: nil)
            let tail = pruned > 0 ? "，清理 \(pruned) 条已删除" : ""
            publishProgress("同步完成：云端 \(songs.count) 条，本地更新 \(written) 条\(tail)")
            onStateChange?(state)
        } catch {
            let message = CloudTableClient.describe(error)
            db.saveSyncState(lastUpdatedAt: nil, lastError: message)
            publishProgress("")
            onError?("云端同步失败：\(message)")
            onStateChange?(state)
        }
    }

    /// 管理页「测试连接」。
    func testConnection() async -> String {
        guard !config.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "❌ 还没填表格链接"
        }
        do {
            let client = CloudTableClient(config: config)
            let count = try await client.count()
            var lines = ["✅ 云端曲库：连接正常，可读 \(count) 条"]
            if count == 0 {
                lines.append("   表是空的 —— 配置没问题，用 Guckey Control 把本地记录导进来即可。")
            } else {
                lines.append("   去「从云端同步 → 全量刷新」，把这 \(count) 条缓存到本地。")
            }
            return lines.joined(separator: "\n")
        } catch {
            return "❌ 云端曲库：\(CloudTableClient.describe(error))"
        }
    }

    private func publishProgress(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(text)
        }
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
