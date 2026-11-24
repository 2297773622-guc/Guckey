import Foundation

// MARK: - 歌名 / 歌手归一化

/// 把系统媒体信息清洗成统一查询键 `[歌手]_[歌名]`。
///
/// 需要处理的实际脏数据（QQ 音乐 / 酷狗 / 网易云 / Spotify / 浏览器标签页）：
/// - `晴天 - 周杰伦 - QQ音乐`、`周杰伦 - 晴天 (伴奏)`、`晴天【Live】`
/// - `Shape of You (feat. ...) - Remix`、`起风了（高音质）`
/// - 全角括号、全角空格、零宽字符、多余标点
///
/// 规则：**只保留中日韩文字与字母数字**，其余一律丢弃，最后小写化。
/// 这样 `A-Lin` 与 `A Lin`、`周杰伦` 与 `周杰伦 ` 都会得到同一个键。
enum SongIdentityNormalizer {

    // MARK: 公开入口

    /// 生成归一化标识。歌手 / 歌名任一为空时也能用（键退化为单个字段）。
    static func normalize(title: String, artist: String) -> (title: String, artist: String) {
        let cleanedTitle = cleanTitle(title)
        let cleanedArtist = cleanArtist(artist)
        return (cleanedTitle, cleanedArtist)
    }

    /// 主键：`歌手_歌名`（全小写、无空格、无标点）。
    static func key(title: String, artist: String) -> String {
        let t = cleanTitle(title)
        let a = cleanArtist(artist)
        switch (a.isEmpty, t.isEmpty) {
        case (false, false): return "\(a)_\(t)"
        case (false, true): return a
        default: return t
        }
    }

    /// 直接从原始标题推断（`歌手 - 歌名` / `歌名 - 歌手` 两种都见过）。
    static func identity(fromRawTitle raw: String, bundleID: String? = nil) -> SongIdentity {
        let parsed = parseRawTitle(raw)
        return SongIdentity(rawTitle: parsed.title, rawArtist: parsed.artist, sourceBundleID: bundleID)
    }

    // MARK: 清洗

    /// 干扰词：只要括号内出现这些词，整个括号段被丢弃。
    private static let noiseKeywords: [String] = [
        "伴奏", "纯音乐", "无人声", "消音", "off vocal", "offvocal", "instrumental", "inst.",
        "live", "现场", "演唱会", "remix", "mix", "dj", "cover", "翻唱", "翻自",
        "高音质", "无损", "hq", "sq", "hi-res", "hires", "320k", "128k", "flac",
        "片段", "试听", "铃声", "剪辑", "加速", "降速", "升调", "降调", "女声版", "男声版",
        "demo", "acoustic", "unplugged", "karaoke", "ktv", "合唱版", "对唱版", "重制", "remaster"
    ]

    /// 尾部常见的平台后缀，直接砍掉（不带括号的情况）。
    private static let trailingNoise: [String] = [
        "- qq音乐", "- QQ音乐", "- 酷狗音乐", "- 网易云音乐", "- spotify", "- apple music",
        "- youtube", "- bilibili", "- 哔哩哔哩", "| qq音乐", "| 酷狗音乐"
    ]

    static func cleanTitle(_ raw: String) -> String {
        let pre = preprocess(raw)
        // 中文语境里《》包住的就是歌名本身：「A-Lin 的《给我一个理由忘记》」
        if let inner = bookTitleContent(pre), !inner.isEmpty {
            return compact(stripTrailingNoise(inner))
        }
        var s = pre
        s = stripBracketedNoise(s)
        s = stripTrailingNoise(s)
        s = stripCommonSuffix(s)
        return compact(s)
    }

    static func cleanArtist(_ raw: String) -> String {
        var s = preprocess(raw)
        s = stripBracketedNoise(s)
        s = stripTrailingNoise(s)
        // 多歌手：`周杰伦/费玉清`、`A & B`、`A、B` 统一取第一位，避免键不一致
        for separator in ["/", "、", "&", "，", ","] {
            if let range = s.range(of: separator) {
                let head = String(s[..<range.lowerBound])
                if !compact(head).isEmpty { s = head }
                break
            }
        }
        return compact(s)
    }

    /// 归一化后只保留文字 / 字母 / 数字。
    static func compact(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in raw.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.value < 0x10000 {
                // alphanumerics 覆盖中日韩与拉丁字母数字
                out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: 内部步骤

    /// 全角 → 半角、统一括号、去掉零宽字符与重复空白。
    private static func preprocess(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        s = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        s = s.replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "［", with: "[")
            .replacingOccurrences(of: "］", with: "]")
            .replacingOccurrences(of: "【", with: "[")
            .replacingOccurrences(of: "】", with: "]")
            .replacingOccurrences(of: "《", with: "\u{2039}")
            .replacingOccurrences(of: "》", with: "\u{203A}")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "　", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 去掉带干扰词的括号段；括号内是干净内容（如 `(Live)` 是噪声，`(2003)` 是年份）则保留。
    private static func stripBracketedNoise(_ input: String) -> String {
        var s = input
        let pairs: [(open: Character, close: Character)] = [("(", ")"), ("[", "]"), ("\u{2039}", "\u{203A}")]
        for pair in pairs {
            var result = ""
            var depth = 0
            var buffer = ""
            for ch in s {
                if ch == pair.open {
                    depth += 1
                    if depth == 1 { buffer = ""; continue }
                }
                if ch == pair.close, depth > 0 {
                    depth -= 1
                    if depth == 0 {
                        if !isNoise(buffer) && !buffer.isEmpty {
                            result += " " + buffer + " "
                        }
                        continue
                    }
                }
                if depth > 0 { buffer.append(ch) } else { result.append(ch) }
            }
            // 未闭合的括号：保守保留剩余内容
            if depth > 0 { result += buffer }
            s = result
        }
        return s
    }

    /// 取《…》里的内容（已在这一步之前转成 ‹…›）。
    private static func bookTitleContent(_ input: String) -> String? {
        guard let open = input.firstIndex(of: "\u{2039}"),
              let close = input[open...].firstIndex(of: "\u{203A}"),
              open < close else { return nil }
        return String(input[input.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
    }

    private static func isNoise(_ segment: String) -> Bool {
        let lower = segment.lowercased()
        return noiseKeywords.contains { lower.contains($0) }
    }

    private static func stripTrailingNoise(_ input: String) -> String {
        var s = input
        for suffix in trailingNoise {
            if s.lowercased().hasSuffix(suffix.lowercased()) {
                s = String(s.dropLast(suffix.count))
            }
        }
        return s
    }

    /// `歌名 - Remix` 这类没有括号的尾巴。
    private static func stripCommonSuffix(_ input: String) -> String {
        var s = input
        let separators = [" - ", " – ", "- "]
        for sep in separators {
            guard let range = s.range(of: sep, options: .backwards) else { continue }
            let tail = String(s[range.upperBound...])
            if isNoise(tail) {
                s = String(s[..<range.lowerBound])
            }
            break
        }
        return s
    }

    /// 拆 `歌手 - 歌名` / `歌名 - 歌手`。优先按已知平台名剔除，再按词序猜。
    static func parseRawTitle(_ raw: String) -> (title: String, artist: String) {
        let s = preprocess(raw)
        let parts = s.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 去掉纯平台名片段
        let cleaned = parts.filter { !isPlatformName($0) }
        guard !cleaned.isEmpty else { return (s, "") }

        if cleaned.count >= 2 {
            // 常见：「歌名 - 歌手」；QQ 音乐是「歌手 - 歌名」。
            // 无法区分时按「第一段是歌名」处理，手动更正会修正错误记录。
            let a = cleaned[0]
            let b = cleaned[1]
            if looksLikeArtist(a) && !looksLikeArtist(b) {
                return (b, a)
            }
            return (a, b)
        }
        return (cleaned[0], "")
    }

    private static func isPlatformName(_ s: String) -> Bool {
        let lower = s.lowercased()
        return ["qq音乐", "qqmusic", "酷狗", "kugou", "网易云", "cloudmusic",
                "spotify", "apple music", "音乐", "music", "youtube", "bilibili"].contains {
            lower == $0 || lower.hasSuffix($0)
        }
    }

    /// 歌手名常见特征：含 `feat`/`&`，或是很短的**纯拉丁**别名。
    /// 注意不能把「周杰伦」「晴天」这种 2–3 个汉字的短名判成歌手，
    /// 否则「周杰伦 - 晴天」会被拆成 title=周杰伦 / artist=晴天。
    private static func looksLikeArtist(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.contains("feat") || lower.contains("&") { return true }
        let isASCII = s.unicodeScalars.allSatisfy { $0.isASCII }
        guard isASCII else { return false }
        let letters = s.filter { $0.isLetter }
        return letters.count <= 3 && s.count <= 6
    }

    // MARK: 模糊匹配

    /// Levenshtein 编辑距离（滚动数组，O(min(n,m)) 空间）。
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a)
        let y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    /// 模糊匹配容差：短名允许 1–2 个字符差异，长名按比例放宽。
    static func fuzzyTolerance(for length: Int) -> Int {
        if length <= 4 { return 1 }
        if length <= 12 { return 2 }
        return max(2, length / 6)
    }
}
