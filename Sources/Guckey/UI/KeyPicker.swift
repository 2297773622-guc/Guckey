import SwiftUI

// MARK: - 基调选择器（悬浮窗与主窗口共用）

/// 用 `Button + popover` 而不是 `Menu`：
/// macOS 的 `Menu` 会自己塞一个系统箭头，位置随布局漂移（实测会在标题左侧冒出一个奇怪的箭头）。
/// 自己画箭头 + 24 格网格，位置确定，选调也更快。
struct KeyPickerButton: View {
    @EnvironmentObject private var appState: AppState

    var fontSize: CGFloat = 27
    var showsChevron = true
    var onPicked: (() -> Void)?

    @State private var isPresented = false

    private var color: Color { KeySourceStyle.color(appState.keySource) }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(appState.currentKey.displayName)
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: max(9, fontSize * 0.4), weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help("手动更正基调（写入本地 SQLite，最高优先）")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            KeyGridPicker { key in
                appState.manuallyCorrect(to: key)
                isPresented = false
                onPicked?()
            }
            .padding(10)
            .preferredColorScheme(.dark)
        }
    }
}

/// 24 个大小调网格。当前调高亮。
struct KeyGridPicker: View {
    @EnvironmentObject private var appState: AppState
    var onPick: (KeySignature) -> Void

    private let columns = Array(repeating: GridItem(.fixed(56), spacing: 6), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手动更正基调")
                .font(.caption).foregroundColor(.secondary)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(PitchClass.allCases) { pc in
                    Button { onPick(KeySignature(root: pc, mode: .major)) } label: {
                        cell(pc, mode: .major)
                    }
                    .buttonStyle(.plain)
                    Button { onPick(KeySignature(root: pc, mode: .minor)) } label: {
                        cell(pc, mode: .minor)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("选择后写入本地 SQLite（第一级），这首歌不再受云端 / AI 波动影响。")
                .font(.caption2).foregroundColor(.secondary)
                .frame(maxWidth: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 388)
    }

    private func cell(_ pc: PitchClass, mode: KeyMode) -> some View {
        let key = KeySignature(root: pc, mode: mode)
        let selected = appState.currentKey == key
        return VStack(spacing: 0) {
            Text(pc.symbol).font(.system(size: 12, weight: .semibold))
            Text(mode == .major ? "Maj" : "Min")
                .font(.system(size: 8)).foregroundColor(.secondary)
        }
        .frame(width: 56, height: 30)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? KeySourceStyle.color(appState.keySource).opacity(0.22)
                           : Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(selected ? KeySourceStyle.color(appState.keySource).opacity(0.7)
                             : Color.white.opacity(0.08), lineWidth: 1))
    }
}
