import Foundation
import SQLite3

// MARK: - SQLite 本地缓存

/// 三张表 + 一张同步状态表：
/// - `manual_keys`：第一级，用户手动更正。**同步永不覆盖**。
/// - `cloud_keys`：第二级，从云端数据表同步下来的本地副本。
/// - `auto_keys`：第三级，AI 稳定结果的自动缓存（不覆盖前两级）。
/// - `sync_state`：增量同步游标（last_updated_at）。
///
/// 用系统自带的 libsqlite3（`import SQLite3`），不引入 GRDB；
/// 所有访问走同一条串行队列，对外接口都是同步的（毫秒级）。
final class KeyDatabase {

    static let shared = KeyDatabase()

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "guckey.sqlite")
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private(set) var lastError: String?
    private(set) var fileURL: URL?

    private init() {
        open(at: nil)
        migrate()
    }

    /// 测试用：把数据库放到临时目录，避免污染真实用户数据。
    init(directory: URL) {
        open(at: directory)
        migrate()
    }

    // MARK: 打开 / 建表

    private func open(at directory: URL?) {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            dir = base.appendingPathComponent("Guckey", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("guckey.sqlite")
        fileURL = url
        if sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            lastError = String(cString: sqlite3_errmsg(handle))
            NSLog("[Guckey] SQLite 打开失败：\(lastError ?? "-")")
        }
    }

    private func migrate() {
        // 默认没有 busy handler：别的实例正握着写锁时直接返回 SQLITE_BUSY，
        // 而 `BEGIN IMMEDIATE` 的返回值没人看，于是「同步成功但一条没写进去」。
        // 给 2 秒兜底，正常情况感觉不到，撞车时也不会静默失败。
        if let handle { sqlite3_busy_timeout(handle, 2000) }
        execute("PRAGMA journal_mode=WAL;")
        execute("PRAGMA synchronous=NORMAL;")
        execute("""
        CREATE TABLE IF NOT EXISTS manual_keys (
            song_key   TEXT PRIMARY KEY,
            title      TEXT NOT NULL DEFAULT '',
            artist     TEXT NOT NULL DEFAULT '',
            key_root   INTEGER NOT NULL,
            scale      TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS cloud_keys (
            id         TEXT PRIMARY KEY,
            song_key   TEXT NOT NULL,
            song_name  TEXT NOT NULL DEFAULT '',
            artist     TEXT NOT NULL DEFAULT '',
            key_root   INTEGER,
            scale      TEXT,
            updated_at TEXT NOT NULL DEFAULT ''
        );
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_cloud_song_key ON cloud_keys(song_key);")
        execute("""
        CREATE TABLE IF NOT EXISTS auto_keys (
            song_key   TEXT PRIMARY KEY,
            title      TEXT NOT NULL DEFAULT '',
            artist     TEXT NOT NULL DEFAULT '',
            key_root   INTEGER NOT NULL,
            scale      TEXT NOT NULL,
            hits       INTEGER NOT NULL DEFAULT 1,
            updated_at REAL NOT NULL
        );
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS sync_state (
            id              INTEGER PRIMARY KEY CHECK (id = 1),
            last_updated_at TEXT,
            last_sync_at    REAL,
            cached_count    INTEGER NOT NULL DEFAULT 0,
            last_error      TEXT
        );
        """)
        execute("INSERT OR IGNORE INTO sync_state (id, cached_count) VALUES (1, 0);")
    }

    // MARK: 低层封装

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let handle else { return false }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            if let err {
                lastError = String(cString: err)
                sqlite3_free(err)
            }
            return false
        }
        return true
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let handle else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            lastError = String(cString: sqlite3_errmsg(handle))
            return nil
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, index, Int64(value))
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }

    private func text(_ stmt: OpaquePointer?, _ column: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, column) else { return "" }
        return String(cString: c)
    }

    // MARK: 第一级：手动记录

    func saveManual(_ identity: SongIdentity, key: KeySignature) -> ManualKeyRecord {
        queue.sync {
            let record = ManualKeyRecord(songKey: identity.storageKey,
                                         title: identity.title,
                                         artist: identity.artist,
                                         key: key,
                                         updatedAt: Date())
            let sql = """
            INSERT INTO manual_keys (song_key, title, artist, key_root, scale, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(song_key) DO UPDATE SET
                title=excluded.title, artist=excluded.artist,
                key_root=excluded.key_root, scale=excluded.scale,
                updated_at=excluded.updated_at;
            """
            if let stmt = prepare(sql) {
                bind(stmt, 1, record.songKey)
                bind(stmt, 2, record.title)
                bind(stmt, 3, record.artist)
                bind(stmt, 4, record.key.root.rawValue)
                bind(stmt, 5, record.key.mode.rawValue)
                bind(stmt, 6, record.updatedAt.timeIntervalSince1970)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    lastError = String(cString: sqlite3_errmsg(handle))
                }
                sqlite3_finalize(stmt)
            }
            return record
        }
    }

    func manual(for songKey: String) -> ManualKeyRecord? {
        queue.sync {
            let sql = "SELECT song_key, title, artist, key_root, scale, updated_at FROM manual_keys WHERE song_key = ? LIMIT 1;"
            guard let stmt = prepare(sql) else { return nil }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, songKey)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return rowToManual(stmt)
        }
    }

    func allManual() -> [ManualKeyRecord] {
        queue.sync {
            let sql = "SELECT song_key, title, artist, key_root, scale, updated_at FROM manual_keys ORDER BY updated_at DESC;"
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [ManualKeyRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(rowToManual(stmt)) }
            return out
        }
    }

    func removeManual(songKey: String) {
        queue.sync {
            guard let stmt = prepare("DELETE FROM manual_keys WHERE song_key = ?;") else { return }
            bind(stmt, 1, songKey)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func manualCount() -> Int {
        queue.sync { count("manual_keys") }
    }

    private func rowToManual(_ stmt: OpaquePointer?) -> ManualKeyRecord {
        let root = PitchClass(rawValue: Int(sqlite3_column_int64(stmt, 3))) ?? .A
        let mode = KeyMode(rawValue: text(stmt, 4)) ?? .major
        return ManualKeyRecord(songKey: text(stmt, 0),
                               title: text(stmt, 1),
                               artist: text(stmt, 2),
                               key: KeySignature(root: root, mode: mode),
                               updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)))
    }

    // MARK: 第二级：云端缓存

    /// 增量写入（按 id upsert）。
    @discardableResult
    func upsertCloud(_ songs: [CloudSong]) -> Int {
        guard !songs.isEmpty else { return 0 }
        return queue.sync {
            execute("BEGIN IMMEDIATE;")
            let sql = """
            INSERT INTO cloud_keys (id, song_key, song_name, artist, key_root, scale, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                song_key=excluded.song_key, song_name=excluded.song_name,
                artist=excluded.artist, key_root=excluded.key_root,
                scale=excluded.scale, updated_at=excluded.updated_at;
            """
            var written = 0
            for song in songs {
                guard let stmt = prepare(sql) else { continue }
                bind(stmt, 1, song.id)
                bind(stmt, 2, song.songKey)
                bind(stmt, 3, song.songName)
                bind(stmt, 4, song.artist)
                bind(stmt, 5, song.key.root.rawValue)
                bind(stmt, 6, song.key.mode.rawValue)
                bind(stmt, 7, song.updatedAt)
                if sqlite3_step(stmt) == SQLITE_DONE { written += 1 }
                sqlite3_finalize(stmt)
            }
            execute("COMMIT;")
            return written
        }
    }

    /// 全量同步后清理云端已经删掉的记录。
    ///
    /// 云端那边没有增量游标，每次都是全量拉；如果只 upsert 不清理，
    /// 你在表格里删掉的歌会一直留在本地缓存里，继续命中旧调性。
    @discardableResult
    func pruneCloud(keeping ids: Set<String>) -> Int {
        queue.sync {
            var stale: [String] = []
            if let stmt = prepare("SELECT id FROM cloud_keys;") {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = text(stmt, 0)
                    if !ids.contains(id) { stale.append(id) }
                }
                sqlite3_finalize(stmt)
            }
            guard !stale.isEmpty else { return 0 }

            execute("BEGIN IMMEDIATE;")
            var removed = 0
            let sql = "DELETE FROM cloud_keys WHERE id = ?;"
            for id in stale {
                guard let stmt = prepare(sql) else { continue }
                bind(stmt, 1, id)
                if sqlite3_step(stmt) == SQLITE_DONE { removed += 1 }
                sqlite3_finalize(stmt)
            }
            execute("COMMIT;")
            return removed
        }
    }

    /// 精准匹配 → 模糊匹配，全部在本地完成，不发网络请求。
    /// 先试 `歌手_歌名`，再试反向键（应对窗口标题里歌名 / 歌手顺序颠倒）。
    func matchCloud(_ identity: SongIdentity) -> CloudMatch? {
        let key = identity.storageKey
        if let exact = cloud(songKey: key) {
            return CloudMatch(song: exact, kind: .exact, distance: 0)
        }
        let alt = identity.alternateStorageKey
        if alt != key, let reversed = cloud(songKey: alt) {
            return CloudMatch(song: reversed, kind: .exact, distance: 0)
        }
        return fuzzyCloud(songKey: key, alternate: alt,
                          title: identity.title, artist: identity.artist)
    }

    func cloud(songKey: String) -> CloudSong? {
        queue.sync {
            let sql = """
            SELECT id, song_key, song_name, artist, key_root, scale, updated_at
            FROM cloud_keys WHERE song_key = ? LIMIT 1;
            """
            guard let stmt = prepare(sql) else { return nil }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, songKey)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return rowToCloud(stmt)
        }
    }

    /// 编辑距离模糊匹配。候选集限制在缓存内，几万行也只是毫秒级。
    func fuzzyCloud(songKey: String, alternate: String? = nil,
                    title: String, artist: String) -> CloudMatch? {
        let keys = [songKey, alternate].compactMap { $0 }.filter { !$0.isEmpty }
        return queue.sync {
            let sql = """
            SELECT id, song_key, song_name, artist, key_root, scale, updated_at
            FROM cloud_keys LIMIT 50000;
            """
            guard let stmt = prepare(sql) else { return nil }
            defer { sqlite3_finalize(stmt) }
            var best: (CloudSong, Int)?
            while sqlite3_step(stmt) == SQLITE_ROW {
                let song = rowToCloud(stmt)
                guard !song.songKey.isEmpty else { continue }
                var distance = Int.max
                for candidate in keys {
                    let d = SongIdentityNormalizer.levenshtein(candidate, song.songKey)
                    let tolerance = SongIdentityNormalizer.fuzzyTolerance(for: candidate.count)
                    if d <= tolerance { distance = min(distance, d) }
                }
                guard distance != Int.max else { continue }
                if best == nil || distance < best!.1 {
                    best = (song, distance)
                }
            }
            guard let best else { return nil }
            return CloudMatch(song: best.0, kind: .fuzzy, distance: best.1)
        }
    }

    func allCloud(limit: Int = 500) -> [CloudSong] {
        queue.sync {
            let sql = """
            SELECT id, song_key, song_name, artist, key_root, scale, updated_at
            FROM cloud_keys ORDER BY song_name COLLATE NOCASE LIMIT \(max(1, limit));
            """
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [CloudSong] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(rowToCloud(stmt)) }
            return out
        }
    }

    /// 云端库里本地搜索（管理页用）。
    func searchCloud(_ query: String, limit: Int = 100) -> [CloudSong] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allCloud(limit: limit) }
        let normalized = SongIdentityNormalizer.compact(q)
        return queue.sync {
            let sql = """
            SELECT id, song_key, song_name, artist, key_root, scale, updated_at
            FROM cloud_keys
            WHERE song_name LIKE ?1 OR artist LIKE ?1 OR song_key LIKE ?2
            ORDER BY song_name COLLATE NOCASE LIMIT \(max(1, limit));
            """
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, "%\(q)%")
            bind(stmt, 2, "%\(normalized)%")
            var out: [CloudSong] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(rowToCloud(stmt)) }
            return out
        }
    }

    func cloudCount() -> Int {
        queue.sync { count("cloud_keys") }
    }

    private func rowToCloud(_ stmt: OpaquePointer?) -> CloudSong {
        let root = PitchClass(rawValue: Int(sqlite3_column_int64(stmt, 4))) ?? .A
        let mode = KeyMode(rawValue: text(stmt, 5)) ?? .major
        return CloudSong(id: text(stmt, 0),
                         songName: text(stmt, 2),
                         artist: text(stmt, 3),
                         key: KeySignature(root: root, mode: mode),
                         updatedAt: text(stmt, 6),
                         songKey: text(stmt, 1))
    }

    // MARK: 第三级：AI 自动缓存

    func saveAuto(_ identity: SongIdentity, key: KeySignature) {
        queue.sync {
            let sql = """
            INSERT INTO auto_keys (song_key, title, artist, key_root, scale, hits, updated_at)
            VALUES (?, ?, ?, ?, ?, 1, ?)
            ON CONFLICT(song_key) DO UPDATE SET
                title=excluded.title, artist=excluded.artist,
                key_root=excluded.key_root, scale=excluded.scale,
                hits=auto_keys.hits + 1, updated_at=excluded.updated_at;
            """
            guard let stmt = prepare(sql) else { return }
            bind(stmt, 1, identity.storageKey)
            bind(stmt, 2, identity.title)
            bind(stmt, 3, identity.artist)
            bind(stmt, 4, key.root.rawValue)
            bind(stmt, 5, key.mode.rawValue)
            bind(stmt, 6, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func auto(for songKey: String) -> AutoKeyRecord? {
        queue.sync {
            let sql = "SELECT song_key, title, artist, key_root, scale, hits, updated_at FROM auto_keys WHERE song_key = ? LIMIT 1;"
            guard let stmt = prepare(sql) else { return nil }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, songKey)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return rowToAuto(stmt)
        }
    }

    func allAuto() -> [AutoKeyRecord] {
        queue.sync {
            let sql = "SELECT song_key, title, artist, key_root, scale, hits, updated_at FROM auto_keys ORDER BY updated_at DESC;"
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [AutoKeyRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(rowToAuto(stmt)) }
            return out
        }
    }

    func autoCount() -> Int {
        queue.sync { count("auto_keys") }
    }

    private func rowToAuto(_ stmt: OpaquePointer?) -> AutoKeyRecord {
        let root = PitchClass(rawValue: Int(sqlite3_column_int64(stmt, 3))) ?? .A
        let mode = KeyMode(rawValue: text(stmt, 4)) ?? .major
        return AutoKeyRecord(songKey: text(stmt, 0),
                             title: text(stmt, 1),
                             artist: text(stmt, 2),
                             key: KeySignature(root: root, mode: mode),
                             hits: Int(sqlite3_column_int64(stmt, 5)),
                             updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)))
    }

    // MARK: 同步状态

    func syncState() -> SyncState {
        queue.sync {
            let sql = "SELECT last_updated_at, last_sync_at, cached_count, last_error FROM sync_state WHERE id = 1;"
            guard let stmt = prepare(sql) else { return .empty }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return .empty }
            let lastUpdated = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : text(stmt, 0)
            let lastSync = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let count = Int(sqlite3_column_int64(stmt, 2))
            let error = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : text(stmt, 3)
            return SyncState(lastUpdatedAt: lastUpdated, lastSyncAt: lastSync,
                             cachedCount: count, lastError: error)
        }
    }

    func saveSyncState(lastUpdatedAt: String?, lastError: String?) {
        queue.sync {
            let sql = """
            UPDATE sync_state SET
                last_updated_at = COALESCE(?, last_updated_at),
                last_sync_at = ?,
                cached_count = (SELECT COUNT(*) FROM cloud_keys),
                last_error = ?
            WHERE id = 1;
            """
            guard let stmt = prepare(sql) else { return }
            if let lastUpdatedAt {
                bind(stmt, 1, lastUpdatedAt)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            bind(stmt, 2, Date().timeIntervalSince1970)
            if let lastError {
                bind(stmt, 3, lastError)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// 清空云端缓存（保留手动记录与 AI 缓存）。
    func clearCloudCache() {
        queue.sync {
            _ = execute("DELETE FROM cloud_keys;")
            _ = execute("UPDATE sync_state SET last_updated_at = NULL, cached_count = 0 WHERE id = 1;")
        }
    }

    /// 清空 AI 自动缓存（保留手动记录与云端缓存）。
    func clearAutoCache() {
        queue.sync {
            _ = execute("DELETE FROM auto_keys;")
        }
    }

    // MARK: 工具

    private func count(_ table: String) -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM \(table);") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
