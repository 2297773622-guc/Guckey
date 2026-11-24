import SwiftUI
import AppKit

// MARK: - 联系支持

/// 一个轻量的联系方式窗口：微信 + 邮箱，点一下复制。
/// 图标用代码画（圆角渐变底 + 白色符号），与 App 内的图标风格保持一致。
struct SupportView: View {
    var onClose: () -> Void

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 10) {
                ContactCard(icon: "message.fill",
                            colors: [Color(red: 0.20, green: 0.80, blue: 0.42),
                                     Color(red: 0.03, green: 0.62, blue: 0.33)],
                            title: "微信",
                            value: "YX-CJ_6120",
                            hint: "加好友时备注一下「Guckey」")
                ContactCard(icon: "envelope.fill",
                            colors: [Color(red: 0.36, green: 0.64, blue: 1.00),
                                     Color(red: 0.20, green: 0.40, blue: 0.92)],
                            title: "邮箱",
                            value: "2297773622@qq.com",
                            hint: "崩溃日志、截图、需求都可以发这里")
            }
            .padding(16)
            Divider()
            footer
        }
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("联系支持").font(.system(size: 16, weight: .semibold))
                Text("遇到问题、想提需求，或者只是想聊聊，都可以找我。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(version.isEmpty ? "反馈时附上截图会更快定位。" : "反馈时附上版本号会更快定位：Guckey \(version)")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Button("关闭") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - 单个联系方式

private struct ContactCard: View {
    let icon: String
    let colors: [Color]
    let title: String
    let value: String
    let hint: String

    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.85))
            }

            Spacer(minLength: 0)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.2)) { copied = false }
                }
            } label: {
                Label(copied ? "已复制" : "复制",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(copied ? .green : nil)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}
