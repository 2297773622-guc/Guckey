import Foundation
import Accelerate

// MARK: - YIN 基频估计（f0）

/// 经典 YIN：差分函数 → 累积均值归一化差分 (CMND) → 绝对阈值 + 抛物线插值。
/// 用于两个目的：① 判断当前帧是否「有明确音高」，避免纯噪声帧污染色度；
/// ② 给对应 pitch class 加权，提高短时间窗内调性收敛速度。
enum YINPitchEstimator {

    static func estimate(_ samples: [Float], sampleRate: Double, threshold: Float = 0.15) -> Double? {
        let half = samples.count / 2
        guard half > 64 else { return nil }

        var cmnd = [Float](repeating: 1, count: half)
        var running: Float = 0

        for tau in 1..<half {
            var sum: Float = 0
            for i in 0..<half {
                let d = samples[i] - samples[i + tau]
                sum += d * d
            }
            running += sum
            cmnd[tau] = running > 1e-9 ? sum * Float(tau) / running : 1
        }

        let minTau = max(2, Int(sampleRate / 1100.0))
        let maxTau = min(half - 1, Int(sampleRate / 60.0))
        guard minTau < maxTau else { return nil }

        var bestTau = -1
        for tau in minTau..<maxTau where cmnd[tau] < threshold {
            var t = tau
            while t + 1 < maxTau && cmnd[t + 1] < cmnd[t] { t += 1 }
            bestTau = t
            break
        }

        if bestTau < 0 {
            // 没过阈值就取全局最小（清唱 / 混音里常见）
            var best: Float = .greatestFiniteMagnitude
            for tau in minTau..<maxTau where cmnd[tau] < best {
                best = cmnd[tau]
                bestTau = tau
            }
            guard best < 0.35 else { return nil }  // 无明确音高
        }

        let y0 = cmnd[max(1, bestTau - 1)]
        let y1 = cmnd[bestTau]
        let y2 = cmnd[min(half - 1, bestTau + 1)]
        let denom = y0 - 2 * y1 + y2
        let shift = denom != 0 ? 0.5 * (y0 - y2) / denom : 0
        let refined = Double(bestTau) + Double(min(max(shift, -0.5), 0.5))
        guard refined > 0 else { return nil }
        return sampleRate / refined
    }
}

// MARK: - FFT 色度（12 维 pitch class 能量）

/// 4096 点 Hann 窗 + vDSP 实数 FFT → 谐波加权的 12 维色度向量。
/// 只依赖 Accelerate，不需要引入 aubio / Essentia 二进制。
///
/// 带通：默认只统计 **60–500 Hz** 以内的谐波（和弦根音 / 贝斯），
/// 在频域直接跳过带外 bin，等效于一个陡峭的带通滤波器，
/// 不引入时域 IIR 的相位延迟与瞬态拖尾。
final class FFTChromaAnalyzer {

    private let fftSize = 4096
    private let half = 2048
    private let log2n: vDSP_Length = 12
    private let fftSetup: FFTSetup?
    private var window = [Float](repeating: 0, count: 4096)

    /// 动态范围压缩指数：色度能量开方，避免低频大能量独占。
    var compressionExponent: Double = 0.5

    init?() {
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        fftSetup = setup
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func chroma(frame: [Float],
                sampleRate: Double,
                bandLow: Double = 60,
                bandHigh: Double = 500) -> [Double] {
        var input = [Float](repeating: 0, count: fftSize)
        let count = min(frame.count, fftSize)
        for i in 0..<count { input[i] = frame[i] }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        guard let fftSetup else { return [Double](repeating: 0, count: 12) }

        real.withUnsafeMutableBufferPointer { rb in
            imag.withUnsafeMutableBufferPointer { ib in
                var split = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                windowed.withUnsafeBufferPointer { wb in
                    wb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cpx in
                        vDSP_ctoz(cpx, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                magnitudes.withUnsafeMutableBufferPointer { mb in
                    vDSP_zvmags(&split, 1, mb.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        var chroma = [Double](repeating: 0, count: 12)
        let binHz = sampleRate / Double(fftSize)
        let low = max(20, min(bandLow, bandHigh - 10))
        let high = max(low + 10, bandHigh)

        // MIDI 24(C1) ... 96(C7)，每个音符累加 1~4 次谐波的局部峰值能量；
        // 只累计落在带通范围内的谐波。
        for midi in 24...96 {
            let pc = midi % 12
            let f0 = 440.0 * pow(2.0, Double(midi - 69) / 12.0)
            var energy: Double = 0
            for harmonic in 1...4 {
                let freq = f0 * Double(harmonic)
                guard freq >= low, freq <= high else { continue }
                let center = Int((freq / binHz).rounded())
                guard center > 0, center < half else { continue }
                var peak: Float = 0
                for bin in max(1, center - 1)...min(half - 1, center + 1) {
                    peak = max(peak, magnitudes[bin])
                }
                energy += Double(peak) / Double(harmonic)
            }
            chroma[pc] += energy
        }

        // 动态范围压缩（避免低频能量独占）+ L1 归一化
        for i in 0..<12 { chroma[i] = pow(max(0, chroma[i]), compressionExponent) }
        let sum = chroma.reduce(0, +)
        if sum > 0 { for i in 0..<12 { chroma[i] /= sum } }
        return chroma
    }
}

// MARK: - Krumhansl–Schmuckler 调性剖面匹配

enum KeyProfileMatcher {

    private static let major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    struct Match {
        let key: KeySignature
        let score: Double
        let runnerUp: Double
        /// 与次优调的差值，可用于日志排查。
        let margin: Double
        /// 0...1，等于皮尔逊相关系数；稳定化模块据此做「< 0.7 丢弃」过滤。
        let confidence: Double
    }

    static func bestKey(chroma: [Double]) -> Match? {
        var scored: [(KeySignature, Double)] = []
        for root in 0..<12 {
            for mode in KeyMode.allCases {
                let profile = mode == .major ? major : minor
                let rotated = rotate(profile, by: root)
                let score = pearson(chroma, rotated)
                scored.append((KeySignature(root: PitchClass(rawValue: root)!, mode: mode), score))
            }
        }
        scored.sort { $0.1 > $1.1 }
        guard let best = scored.first else { return nil }
        let runnerUp = scored.count > 1 ? scored[1].1 : best.1
        let margin = max(0, best.1 - runnerUp)
        // 置信度直接用皮尔逊相关系数本身：稳定化模块的「< 0.7 丢弃」判断的正是这个量，
        // 不要在这里做二次包装，否则阈值语义会被扭曲。
        let confidence = min(1.0, max(0.0, best.1))
        return Match(key: best.0, score: best.1, runnerUp: runnerUp,
                     margin: margin, confidence: confidence)
    }

    private static func rotate(_ profile: [Double], by root: Int) -> [Double] {
        // profile[0] 对应主音；把主音旋转到 root 位置
        (0..<12).map { profile[($0 - root + 12) % 12] }
    }

    private static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let meanA = a.reduce(0, +) / Double(a.count)
        let meanB = b.reduce(0, +) / Double(b.count)
        var num = 0.0, denA = 0.0, denB = 0.0
        for i in 0..<a.count {
            let da = a[i] - meanA, db = b[i] - meanB
            num += da * db
            denA += da * da
            denB += db * db
        }
        guard denA > 0, denB > 0 else { return 0 }
        return num / sqrt(denA * denB)
    }
}
