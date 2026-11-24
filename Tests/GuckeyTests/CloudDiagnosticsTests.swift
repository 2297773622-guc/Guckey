import XCTest
@testable import Guckey

// MARK: - 云端配置与错误文案

/// 云端这条链路最容易踩的三个坑，各自锁一个用例：
/// ① 权限没开 / 没发布版本（99991672）；
/// ② 应用没被加进表格（接口成功但 0 条）；
/// ③ 配置没填全就点同步。
final class CloudDiagnosticsTests: XCTestCase {

    func testPermissionErrorTellsWhichScope() {
        let error = CloudTableClient.APIError(http: 403,
                                               code: 99991672,
                                               message: "Access denied")
        let text = CloudTableClient.describe(error)
        XCTAssertTrue(text.contains("bitable:app"), "要给出具体权限名，实际：\(text)")
    }

    func testTransportErrorIsHumanReadable() {
        let error = CloudTableClient.APIError(http: -1, code: -1003, message: "域名解析失败")
        let text = CloudTableClient.describe(error)
        XCTAssertTrue(text.contains("域名解析失败"), "实际：\(text)")
        XCTAssertFalse(text.contains("NSURLErrorDomain"), "不该把裸错误域抛给用户：\(text)")
    }

    /// 三要素缺一不可；空字段由 normalized() 用内置值兜底。
    ///
    /// 注意：内置值来自仓库外的本地 `CloudConfig.json`，源码里是空的，
    /// 所以这里显式构造一份配置，只锁「判定逻辑」本身；内置兜底仅在
    /// 开发者机器上配了凭据时才验证。
    func testConfigReadinessRequiresAllThree() {
        let base = CloudConfig(appID: "cli_test",
                                appSecret: "secret",
                                link: "https://example.com/base/abc",
                                tableID: "tbl")
        XCTAssertTrue(base.isReady)

        var config = base
        config.link = ""
        XCTAssertFalse(config.isReady, "缺表格链接不算配好")

        config = base
        config.appSecret = "   "
        XCTAssertFalse(config.isReady, "空白 Secret 不算")
        XCTAssertEqual(config.appSecret.trimmingCharacters(in: .whitespacesAndNewlines), "")

        // 只有开发者本机配了内置凭据时，normalized() 才有兜底可验。
        guard !BuiltinCloud.link.isEmpty else { return }
        var broken = base
        broken.link = ""
        XCTAssertTrue(broken.normalized().isReady, "normalized() 要把空链接补回内置值")
        broken = base
        broken.appSecret = "   "
        XCTAssertTrue(broken.normalized().isReady, "空白 Secret 也由 normalized() 兜住")
    }

    // 注：不在这里做真实网络探测。XCTest 在发现用例时就把所有实例创建好，
    // 一个 80 秒的联网用例会把其它用例的 `Date()` 基准拖老（KeyStabilizer 的静默期用例就吃过这个亏）。
}
