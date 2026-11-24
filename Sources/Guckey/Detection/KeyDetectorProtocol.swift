import Foundation

// MARK: - 基调检测协议

/// 检测引擎与 UI / AppState 之间的唯一契约。
/// 换成 aubio / Essentia / CREPE / 外部 fpcalc 服务时，只要实现本协议即可，
/// 上层（悬浮窗、MIDI 输出、记忆库）完全不用改。
///
/// 约定：所有 delegate 回调都在主线程触发，AppState 不需要再做线程跳转。
protocol KeyDetectorProtocol: AnyObject {
    var delegate: (any KeyDetectorDelegate)? { get set }
    var state: DetectorState { get }
    var mode: DetectionMode { get }

    func startDetection()
    func stopDetection()
    func pauseDetection()
    func resumeDetection()
    func setMode(_ mode: DetectionMode)
}

protocol KeyDetectorDelegate: AnyObject {
    func keyDetector(_ detector: any KeyDetectorProtocol, didProduce result: KeyResult)
    func keyDetector(_ detector: any KeyDetectorProtocol, didUpdateIdentity song: SongIdentity)
    func keyDetector(_ detector: any KeyDetectorProtocol, didChangeState state: DetectorState)
    func keyDetector(_ detector: any KeyDetectorProtocol, didFail message: String)
}

extension KeyDetectorDelegate {
    func keyDetector(_ detector: any KeyDetectorProtocol, didUpdateIdentity song: SongIdentity) {}
    func keyDetector(_ detector: any KeyDetectorProtocol, didChangeState state: DetectorState) {}
    func keyDetector(_ detector: any KeyDetectorProtocol, didFail message: String) {}
}
