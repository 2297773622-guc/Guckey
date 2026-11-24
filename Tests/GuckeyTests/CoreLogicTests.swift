import XCTest
@testable import Guckey

final class CoreLogicTests: XCTestCase {

    // MARK: 强度映射

    func testIntensityMappingEndpointsAndInversion() {
        var mapping = IntensityMapping(zeroPercentValue: 10,
                                       hundredPercentValue: 110,
                                       invert: false)
        XCTAssertEqual(mapping.ccValue(for: 0), 10)
        XCTAssertEqual(mapping.ccValue(for: 100), 110)
        XCTAssertEqual(mapping.ccValue(for: 50), 60)
        mapping.invert = true
        XCTAssertEqual(mapping.ccValue(for: 0), 110)
        XCTAssertEqual(mapping.ccValue(for: 100), 10)
        // 越界百分比应被钳制
        XCTAssertEqual(mapping.ccValue(for: -20), 110)
        XCTAssertEqual(mapping.ccValue(for: 500), 10)
    }

    func testReverseParameterMappingViaEndpoints() {
        // Retune Speed 这类反向语义：0% → 127，100% → 0，无需 invert 标志
        let mapping = IntensityMapping(zeroPercentValue: 127,
                                       hundredPercentValue: 0,
                                       invert: false)
        XCTAssertEqual(mapping.ccValue(for: 0), 127)
        XCTAssertEqual(mapping.ccValue(for: 100), 0)
    }

    // MARK: DSP

    func testYINDetectsA4() {
        let sampleRate = 12_000.0
        let frequency = 440.0
        let count = 1024
        let samples = (0..<count).map { i -> Float in
            Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
        guard let f0 = YINPitchEstimator.estimate(samples, sampleRate: sampleRate) else {
            return XCTFail("YIN 未能估计出基频")
        }
        XCTAssertEqual(f0, frequency, accuracy: 8.0)
    }

    func testKeyProfileMatchesSyntheticCMajorChroma() {
        // 构造 C 大调音阶占优的色度向量
        var chroma = [Double](repeating: 0.05, count: 12)
        for pc in KeySignature(root: .C, mode: .major).scalePitchClasses {
            chroma[pc] += 0.25
        }
        chroma[0] += 0.15   // 主音更突出
        guard let match = KeyProfileMatcher.bestKey(chroma: chroma) else {
            return XCTFail("未产生调性匹配")
        }
        XCTAssertEqual(match.key.root, .C)
        XCTAssertEqual(match.key.mode, .major)
        // 置信度即皮尔逊相关系数，干净色度应显著大于 0.7
        XCTAssertGreaterThan(match.confidence, 0.7)
    }

    func testBandPassChromaIgnoresOutOfBandEnergy() {
        guard let analyzer = FFTChromaAnalyzer() else { return XCTFail("FFT 初始化失败") }
        let rate = 44_100.0
        let count = 4096
        // 1 kHz 正弦：落在默认 60–500 Hz 带通之外 → 色度应当是平的（每级 1/12），没有明显峰
        let samples = (0..<count).map { i -> Float in
            Float(sin(2.0 * Double.pi * 1000.0 * Double(i) / rate))
        }
        let chroma = analyzer.chroma(frame: samples, sampleRate: rate, bandLow: 60, bandHigh: 500)
        XCTAssertLessThan(chroma.max() ?? 1, 0.2, "带外能量不应形成明显色度峰")

        // 220 Hz（A3）在带内，应把能量集中在 A 这个音级
        let inBand = (0..<count).map { i -> Float in
            Float(sin(2.0 * Double.pi * 220.0 * Double(i) / rate))
        }
        let chroma2 = analyzer.chroma(frame: inBand, sampleRate: rate, bandLow: 60, bandHigh: 500)
        let peak = chroma2.enumerated().max { $0.element < $1.element }?.offset
        XCTAssertEqual(peak, PitchClass.A.rawValue)
    }

    // MARK: 歌曲标识归一化

    func testNormalizerStripsNoiseSuffixes() {
        let variants = [
            ("晴天 (伴奏)", "周杰伦"),
            ("晴天【Live】", "周杰伦"),
            ("晴天 - Remix", "周杰伦"),
            ("晴天（高音质）", "周杰伦"),
            ("晴天", "周杰伦")
        ]
        let keys = Set(variants.map { SongIdentityNormalizer.key(title: $0.0, artist: $0.1) })
        XCTAssertEqual(keys.count, 1, "干扰词必须被剥离到同一个键：\(keys)")
        XCTAssertEqual(keys.first, "周杰伦_晴天")
    }

    func testNormalizerHandlesFullWidthAndPunctuation() {
        let a = SongIdentityNormalizer.key(title: "Ａ-Lin 的《给我一个理由忘记》", artist: "A-Lin")
        let b = SongIdentityNormalizer.key(title: "给我一个理由忘记", artist: "alin")
        XCTAssertEqual(a, b)
    }

    func testNormalizerDropsPlatformSuffixAndMultipleArtists() {
        let identity = SongIdentityNormalizer.identity(fromRawTitle: "晴天 - 周杰伦 - QQ音乐")
        XCTAssertEqual(identity.storageKey, "周杰伦_晴天")
        let multi = SongIdentityNormalizer.key(title: "因为爱情", artist: "陈奕迅/王菲")
        XCTAssertEqual(multi, "陈奕迅_因为爱情")
    }

    /// 窗口标题无法确定「歌名 - 歌手」还是「歌手 - 歌名」，反向键必须能兜住。
    func testAlternateKeyCoversSwappedOrder() {
        let identity = SongIdentityNormalizer.identity(fromRawTitle: "周杰伦 - 晴天")
        XCTAssertEqual(identity.storageKey, "晴天_周杰伦")
        XCTAssertEqual(identity.alternateStorageKey, "周杰伦_晴天")
    }

    func testLevenshteinAndTolerance() {
        XCTAssertEqual(SongIdentityNormalizer.levenshtein("abc", "abc"), 0)
        XCTAssertEqual(SongIdentityNormalizer.levenshtein("abc", "abd"), 1)
        XCTAssertEqual(SongIdentityNormalizer.levenshtein("", "abc"), 3)
        XCTAssertEqual(SongIdentityNormalizer.fuzzyTolerance(for: 3), 1)
        XCTAssertEqual(SongIdentityNormalizer.fuzzyTolerance(for: 10), 2)
        XCTAssertGreaterThanOrEqual(SongIdentityNormalizer.fuzzyTolerance(for: 30), 2)
    }

    func testKeySignatureParsing() {
        XCTAssertEqual(KeySignature.parse(root: "A", scale: "minor")?.displayName, "A Minor")
        XCTAssertEqual(KeySignature.parse(root: "a#", scale: "Major")?.root, .ASharp)
        XCTAssertEqual(KeySignature.parse(root: "9", scale: "0")?.displayName, "A Major")
        XCTAssertEqual(KeySignature.parse(root: "A Minor", scale: nil)?.mode, .minor)
        XCTAssertNil(KeySignature.parse(root: "H", scale: "major"))
    }
}
