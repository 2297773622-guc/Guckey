import SwiftUI

// MARK: - 云端曲库 / 本地缓存

struct CloudLibraryView: View {
    @EnvironmentObject private var appState: AppState

    @State private var syncReport: String?
    @State private var isTesting = false
    @State private var appIDDraft = ""
    @State private var secretDraft = ""
    @State private var linkDraft = ""
    @State private var tableDraft = ""
    @State private var query = ""
    @State private var didLoad = false

    /// 云端时间是毫秒时间戳字符串，直接显示会是一串数字；这里统一成「11-17 15:38」。
    private static let cloudFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static func cloudTime(_ raw: String) -> String {
        guard let value = Double(raw), value > 0 else { return "—" }
        let seconds = value > 1_000_000_000_000 ? value / 1000 : value
        return cloudFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                connectionCard
                syncCard
                searchCard
                manualCard
                autoCard
            }
            .padding(.bottom, 16)
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            appIDDraft = appState.cloudOverrides.appID
            secretDraft = appState.cloudOverrides.appSecret
            linkDraft = appState.cloudOverrides.link
            tableDraft = appState.cloudOverrides.tableID
            appState.refreshLocalStores()
            appState.searchCloud("")
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("云端曲库").font(.title2.bold())
                Text("启动时自动同步；切歌只查本地，不联网。")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("缓存 \(appState.syncState.cachedCount) 条").font(.caption.monospacedDigit())
                if let last = appState.syncState.lastSyncAt {
                    Text("上次同步 \(Self.dateFormatter.string(from: last))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: 连接（内置，默认收起）

    private var connectionCard: some View {
        GroupBox(label: Label("云端数据库", systemImage: "tablecells")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(connected ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(connected ? "已连接" : "未同步")
                        .font(.caption)
                    if let last = appState.syncState.lastSyncAt {
                        Text("· \(Self.dateFormatter.string(from: last))")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(isTesting ? "测试中…" : "测试连接") {
                        isTesting = true
                        Task {
                            let report = await appState.testCloudConnection()
                            await MainActor.run {
                                syncReport = report
                                isTesting = false
                            }
                        }
                    }
                    .font(.caption)
                    .disabled(isTesting)
                }

                if let error = appState.syncState.lastError {
                    Text(error)
                        .font(.caption2).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let syncReport {
                    Text(syncReport)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 地址是内置的，正常不需要改；只显示用户改过的项，空着就是内置值。
                DisclosureGroup("高级设置") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("只显示你改过的项，空着就用内置值。")
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)

                        HStack(spacing: 6) {
                            Text("App ID").font(.caption2).foregroundColor(.secondary)
                                .frame(width: 56, alignment: .leading)
                            TextField("内置", text: $appIDDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10, design: .monospaced))
                        }
                        HStack(spacing: 6) {
                            Text("Secret").font(.caption2).foregroundColor(.secondary)
                                .frame(width: 56, alignment: .leading)
                            SecureField("内置", text: $secretDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10, design: .monospaced))
                        }
                        HStack(spacing: 6) {
                            Text("表格").font(.caption2).foregroundColor(.secondary)
                                .frame(width: 56, alignment: .leading)
                            TextField("内置", text: $linkDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10, design: .monospaced))
                        }
                        HStack(spacing: 6) {
                            Text("数据表").font(.caption2).foregroundColor(.secondary)
                                .frame(width: 56, alignment: .leading)
                            TextField("内置", text: $tableDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                                .font(.system(size: 10, design: .monospaced))
                            Spacer()
                        }
                        HStack {
                            Button("保存") { saveOverrides() }
                            Button("恢复内置") { clearOverrides() }
                            Spacer()
                        }
                        .font(.caption)
                    }
                    .padding(.top, 6)
                }
                .font(.caption2)
            }
            .padding(6)
        }
    }

    private var connected: Bool {
        appState.syncState.lastError == nil && appState.syncState.lastSyncAt != nil
    }

    private func saveOverrides() {
        var overrides = CloudConfig.blank
        overrides.appID = appIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        overrides.appSecret = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        overrides.link = linkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        overrides.tableID = tableDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.updateCloudOverrides(overrides)
        syncReport = "已保存"
    }

    /// 清空所有覆盖项 = 回到内置地址。
    private func clearOverrides() {
        appIDDraft = ""
        secretDraft = ""
        linkDraft = ""
        tableDraft = ""
        appState.updateCloudOverrides(.blank)
        syncReport = "已恢复内置地址"
    }

    // MARK: 同步

    private var syncCard: some View {
        GroupBox(label: Label("同步", systemImage: "arrow.triangle.2.circlepath")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("全量刷新") {
                        Task { await appState.syncNow(force: true) }
                    }
                    Button("清空云端缓存") { appState.clearCloudCache() }
                    Spacer()
                    if !appState.syncProgress.isEmpty {
                        Text(appState.syncProgress)
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .font(.caption)

                Text("在云端改过调性或来源，点「全量刷新」才会同步过来。")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(6)
        }
    }

    // MARK: 搜索测试

    private var searchCard: some View {
        GroupBox(label: Label("曲库搜索", systemImage: "magnifyingglass")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("输入歌名或歌手，例如：晴天 / 周杰伦", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { appState.searchCloud(query) }
                    Button("搜索") { appState.searchCloud(query) }
                    if appState.hasCloudQuery {
                        Button("清空") {
                            query = ""
                            appState.searchCloud("")
                        }
                    }
                }
                .font(.caption)

                if !appState.hasCloudQuery {
                    // 没搜索就什么都不列 —— 一进页面铺满几十行反而看不清重点
                    Text("输入关键词后回车。本地缓存 \(appState.syncState.cachedCount) 条。")
                        .font(.caption2).foregroundColor(.secondary)
                } else if appState.cloudPreview().isEmpty {
                    Text("没有匹配「\(appState.cloudSearchQuery)」的曲目。")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    let rows = appState.cloudPreview()
                    VStack(spacing: 0) {
                        HStack {
                            Text("歌名").frame(maxWidth: .infinity, alignment: .leading)
                            Text("歌手").frame(width: 130, alignment: .leading)
                            Text("基调").frame(width: 80, alignment: .leading)
                            Text("更新时间").frame(width: 130, alignment: .leading)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                        Divider()
                        ForEach(rows.prefix(60)) { song in
                            HStack {
                                Text(song.songName).frame(maxWidth: .infinity, alignment: .leading)
                                Text(song.artist).frame(width: 130, alignment: .leading)
                                Text(song.key.displayName)
                                    .foregroundColor(KeySourceStyle.color(.cloud))
                                    .frame(width: 80, alignment: .leading)
                                Text(Self.cloudTime(song.updatedAt))
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(width: 130, alignment: .leading)
                            }
                            .font(.caption)
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: 手动记录

    private var manualCard: some View {
        GroupBox(label: Label("手动记录（最高优先）", systemImage: "hand.point.up.left.fill")) {
            VStack(alignment: .leading, spacing: 6) {
                if appState.manualRecords.isEmpty {
                    Text("暂无。在悬浮窗点「手动更正基调」即会记录。")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    ForEach(appState.manualRecords.prefix(40)) { record in
                        HStack(spacing: 8) {
                            Text(record.title.isEmpty ? record.songKey : record.title)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(record.artist).font(.caption2).foregroundColor(.secondary)
                                .frame(width: 120, alignment: .leading)
                            Text(record.key.displayName)
                                .font(.caption.weight(.medium))
                                .foregroundColor(KeySourceStyle.color(.manual))
                                .frame(width: 80, alignment: .leading)
                            Button("删除") { appState.clearManualRecord(record) }
                                .font(.caption2)
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                Text("共 \(appState.manualCount) 条")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(6)
        }
    }

    // MARK: AI 缓存

    private var autoCard: some View {
        GroupBox(label: Label("AI 自动缓存（最低优先）", systemImage: "waveform")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("AI 稳定输出后自动记录，下次同一首歌秒出。")
                        .font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Button("清空") { appState.clearAutoCache() }
                        .font(.caption2)
                        .buttonStyle(.link)
                        .disabled(appState.autoCount == 0)
                }
                if appState.autoRecords.isEmpty {
                    Text("暂无记录。")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    ForEach(appState.autoRecords.prefix(20)) { record in
                        HStack(spacing: 8) {
                            Text(record.title.isEmpty ? record.songKey : record.title)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(record.artist).font(.caption2).foregroundColor(.secondary)
                                .frame(width: 120, alignment: .leading)
                            Text(record.key.displayName)
                                .font(.caption.weight(.medium))
                                .foregroundColor(KeySourceStyle.color(.ai))
                                .frame(width: 80, alignment: .leading)
                            Text("×\(record.hits)")
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 40, alignment: .leading)
                        }
                        .padding(.vertical, 2)
                    }
                }
                Text("共 \(appState.autoCount) 条")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(6)
        }
    }
}
