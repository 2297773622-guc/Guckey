import XCTest
@testable import Guckey

/// 单一方案回归：基调 → Root / Scale 两条 CC → 宏控制旋钮。
final class MacroControlTests: XCTestCase {

    private func config() -> MacroControlConfig { MacroControlConfig() }

    // MARK: 档位换算

    func testDefaultTravelHitsBothEnds() {
        let cfg = config()
        XCTAssertEqual(KeyMIDIMapper.macroRootValue(for: KeySignature(root: .C, mode: .major), config: cfg), 0)
        XCTAssertEqual(KeyMIDIMapper.macroRootValue(for: KeySignature(root: .B, mode: .major), config: cfg), 127)
    }

    func testTwelveRootsMapToTwelveDistinctValues() {
        let cfg = config()
        let values = PitchClass.allCases.map {
            KeyMIDIMapper.macroRootValue(for: KeySignature(root: $0, mode: .major), config: cfg)
        }
        XCTAssertEqual(Set(values).count, 12, "12 个音级必须落在 12 个不同 CC 值上：\(values)")
        XCTAssertEqual(values, values.sorted(), "音级越高 CC 值必须越大")
        XCTAssertTrue(values.allSatisfy { (0...127).contains($0) })
    }

    func testStepCountChangesQuantization() {
        var cfg = config()
        cfg.rootSteps = 24
        // 24 档时 12 个音级落在偶数档，步长更细
        XCTAssertEqual(KeyMIDIMapper.macroRootIndex(for: .C, config: cfg), 0)
        XCTAssertEqual(KeyMIDIMapper.macroRootIndex(for: .B, config: cfg), 23)
        XCTAssertEqual(KeyMIDIMapper.macroRootIndex(for: .FSharp, config: cfg), 13)
        var single = config()
        single.rootSteps = 2
        XCTAssertEqual(KeyMIDIMapper.macroRootValue(for: KeySignature(root: .C, mode: .major), config: single), 0)
        XCTAssertEqual(KeyMIDIMapper.macroRootValue(for: KeySignature(root: .B, mode: .major), config: single), 127)
        var one = config()
        one.rootSteps = 1
        XCTAssertEqual(KeyMIDIMapper.macroRootValue(for: KeySignature(root: .G, mode: .major), config: one),
                       one.rootLow)
    }

    func testReversedTravel() {
        var cfg = config()
        cfg.rootLow = 127
        cfg.rootHigh = 0
        XCTAssertEqual(KeyMIDIMapper.macroRootValue(for: KeySignature(root: .C, mode: .major), config: cfg), 127)
        XCTAssertEqual(KeyMIDIMapper.macroRootValue(for: KeySignature(root: .B, mode: .major), config: cfg), 0)
    }

    func testCustomTravelRange() {
        var cfg = config()
        cfg.rootLow = 20
        cfg.rootHigh = 100
        let values = PitchClass.allCases.map {
            KeyMIDIMapper.macroRootValue(for: KeySignature(root: $0, mode: .major), config: cfg)
        }
        XCTAssertEqual(values.first, 20)
        XCTAssertEqual(values.last, 100)
        XCTAssertTrue(values.allSatisfy { (20...100).contains($0) })
    }

    func testOverrideBeatsFormula() {
        var cfg = config()
        cfg.setOverride(64, for: .A)
        XCTAssertEqual(KeyMIDIMapper.macroRootValue(for: KeySignature(root: .A, mode: .minor), config: cfg), 64)
        // 其他音级不受影响
        XCTAssertEqual(KeyMIDIMapper.macroRootValue(for: KeySignature(root: .C, mode: .major), config: cfg), 0)
        cfg.setOverride(nil, for: .A)
        XCTAssertEqual(KeyMIDIMapper.macroRootValue(for: KeySignature(root: .A, mode: .minor), config: cfg),
                       KeyMIDIMapper.macroRootValue(for: KeySignature(root: .A, mode: .major), config: cfg))
    }

    func testOverrideIsClamped() {
        var cfg = config()
        cfg.setOverride(999, for: .D)
        XCTAssertEqual(cfg.override(for: .D), 127)
        cfg.setOverride(-5, for: .E)
        XCTAssertEqual(cfg.override(for: .E), 0)
    }

    // MARK: Scale

    func testScaleValuesFollowMode() {
        let cfg = config()
        XCTAssertEqual(KeyMIDIMapper.macroScaleValue(for: KeySignature(root: .A, mode: .major), config: cfg), 64)
        XCTAssertEqual(KeyMIDIMapper.macroScaleValue(for: KeySignature(root: .A, mode: .minor), config: cfg), 127)

        var custom = config()
        custom.majorValue = 12
        custom.minorValue = 30
        XCTAssertEqual(KeyMIDIMapper.macroScaleValue(for: KeySignature(root: .D, mode: .major), config: custom), 12)
        XCTAssertEqual(KeyMIDIMapper.macroScaleValue(for: KeySignature(root: .D, mode: .minor), config: custom), 30)
    }

    /// 调式列表长度不固定：任意条目数下，第 2 / 3 段都必须能反向取整回 1 / 2。
    func testScaleSteppingRoundTripsForAnyListLength() {
        for steps in 3...40 {
            let major = KeyMIDIMapper.majorScaleValue(steps: steps, low: 0, high: 127)
            let minor = KeyMIDIMapper.minorScaleValue(steps: steps, low: 0, high: 127)
            XCTAssertEqual(roundTrip(major, steps: steps), 1, "steps=\(steps) major=\(major)")
            XCTAssertEqual(roundTrip(minor, steps: steps), 2, "steps=\(steps) minor=\(minor)")
            XCTAssertLessThan(major, minor)
        }
    }

    func testScaleSteppingKnownValues() {
        // 3 段：Chromatic / Major / Minor
        XCTAssertEqual(KeyMIDIMapper.majorScaleValue(steps: 3, low: 0, high: 127), 64)
        XCTAssertEqual(KeyMIDIMapper.minorScaleValue(steps: 3, low: 0, high: 127), 127)
        // 12 段
        XCTAssertEqual(KeyMIDIMapper.majorScaleValue(steps: 12, low: 0, high: 127), 12)
        XCTAssertEqual(KeyMIDIMapper.minorScaleValue(steps: 12, low: 0, high: 127), 23)
        // 列表过短时索引被钳制，不会越界
        XCTAssertEqual(KeyMIDIMapper.minorScaleValue(steps: 2, low: 0, high: 127), 127)
    }

    /// 用 Studio One 的离散参数取整规则反推档位：index = round(value / 127 × (steps - 1))
    private func roundTrip(_ value: Int, steps: Int) -> Int {
        Int((Double(value) / 127.0 * Double(steps - 1)).rounded())
    }

    /// 同一个根音换大小调，只有 Scale 那条 CC 变化，Root 不变。
    func testModeChangeOnlyMovesScale() {
        let cfg = config()
        let major = KeySignature(root: .A, mode: .major)
        let minor = KeySignature(root: .A, mode: .minor)
        XCTAssertEqual(KeyMIDIMapper.macroRootValue(for: major, config: cfg),
                       KeyMIDIMapper.macroRootValue(for: minor, config: cfg))
        XCTAssertNotEqual(KeyMIDIMapper.macroScaleValue(for: major, config: cfg),
                          KeyMIDIMapper.macroScaleValue(for: minor, config: cfg))
    }

    // MARK: 持久化兼容

    func testDefaultMappingIsMacroConfig() {
        let mapping = MIDIMapping.default
        XCTAssertEqual(mapping.macro.rootCC, 20)
        XCTAssertEqual(mapping.macro.scaleCC, 22)
        XCTAssertEqual(mapping.macro.rootSteps, 12)
        XCTAssertEqual(mapping.macro.channel, 1, "默认单通道发送，避免 MIDI 学习里出现 16 个重复旋钮")
        XCTAssertEqual(mapping.macro.scaleSteps, 3)
        XCTAssertTrue(mapping.macro.sendScale)
        XCTAssertEqual(mapping.intensity.ccNumber, 24)
        XCTAssertEqual(mapping.intensity.channel, 1)
    }

    func testLegacyJSONWithoutMacroStillDecodes() throws {
        // 旧版本持久化里只有 intensity / virtualSourceName，没有 macro 键
        let json = """
        {"virtualSourceName":"Guckey","intensity":{"ccNumber":30,"channel":2,"zeroPercentValue":0,"hundredPercentValue":127,"invert":false}}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let mapping = try JSONDecoder().decode(MIDIMapping.self, from: data)
        XCTAssertEqual(mapping.intensity.ccNumber, 30)
        XCTAssertEqual(mapping.macro.rootSteps, 12, "缺失的宏配置必须回落到默认值")
    }

    func testMappingRoundTrip() throws {
        var mapping = MIDIMapping.default
        mapping.macro.setOverride(77, for: .FSharp)
        mapping.macro.repeatCount = 3
        let data = try JSONEncoder().encode(mapping)
        let decoded = try JSONDecoder().decode(MIDIMapping.self, from: data)
        XCTAssertEqual(decoded, mapping)
    }

    /// 1.0.0 的旧文件有 macro，但没有 scaleSteps / scaleLow / scaleHigh：
    /// 解码不能失败，且用户校准过的音级必须还在（升级不能把映射打回默认）。
    func testLegacyMacroWithoutScaleStepsKeepsCalibration() throws {
        let json = """
        {"macro":{"channel":1,"rootCC":20,"scaleCC":22,"rootLow":0,"rootHigh":127,
        "rootSteps":12,"sendScale":true,"majorValue":0,"minorValue":127,
        "rootOverrides":{"9":104},"repeatCount":2,"repeatGapMs":25},
        "intensity":{"ccNumber":24,"channel":1,"zeroPercentValue":0,"hundredPercentValue":127,"invert":false},
        "virtualSourceName":"Guckey"}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let mapping = try JSONDecoder().decode(MIDIMapping.self, from: data)
        XCTAssertEqual(mapping.macro.scaleSteps, 3, "缺失的新字段回落到 3 段")
        XCTAssertEqual(mapping.macro.override(for: .A), 104, "音级校准必须保留")
        XCTAssertEqual(mapping.macro.rootCC, 20)
    }

    // MARK: 修音插件预设

    /// 预设只是把「档位数 + Major/Minor 落在第几项」填好，数值按厂商列表核对。
    func testPluginPresetsMatchManuals() throws {
        XCTAssertEqual(TuningPluginPreset.all.count, 5)

        let pro = try XCTUnwrap(TuningPluginPreset.find("autotunepro"))
        XCTAssertEqual(pro.scaleCount, 29)
        XCTAssertEqual(pro.majorIndex, 1)
        XCTAssertEqual(pro.minorIndex, 2)

        let advanced = try XCTUnwrap(TuningPluginPreset.find("autotuneadvanced"))
        XCTAssertEqual(advanced.scaleCount, 15)
        XCTAssertEqual(advanced.majorIndex, 2)
        XCTAssertEqual(advanced.minorIndex, 3)

        let year2026 = try XCTUnwrap(TuningPluginPreset.find("autotune2026"))
        XCTAssertEqual(year2026.scaleCount, 15)

        let waves = try XCTUnwrap(TuningPluginPreset.find("wavestune"))
        XCTAssertEqual(waves.scaleCount, 44)
        XCTAssertEqual(waves.majorIndex, 3)
        XCTAssertEqual(waves.minorIndex, 4)

        let toplineVocalTune = try XCTUnwrap(TuningPluginPreset.find("toplinevocaltune"))
        XCTAssertEqual(toplineVocalTune.scaleCount, 10)
        XCTAssertEqual(toplineVocalTune.majorIndex, 2)
        XCTAssertEqual(toplineVocalTune.minorIndex, 3)
        XCTAssertEqual(TuningPluginPreset.find("topline")?.id, "toplinevocaltune",
                       "旧配置里的短名仍要能解析到同一个预设")

        XCTAssertNil(TuningPluginPreset.find(""), "空串代表自定义")
        XCTAssertNil(TuningPluginPreset.find(nil))
        XCTAssertNil(TuningPluginPreset.find("unknown-plugin"), "未知 id 回落到自定义")
    }

    /// 落点仍然是「等分后取第 N 段」——预设没有改公式，只是换了入参。
    func testPresetValuesUseSameEvenDivision() {
        // 29 项：第 1 项 = 0，第 2 项 = round(127 / 28) = 5
        XCTAssertEqual(KeyMIDIMapper.scaleValue(steps: 29, index: 0, low: 0, high: 127), 0)
        XCTAssertEqual(KeyMIDIMapper.scaleValue(steps: 29, index: 1, low: 0, high: 127), 5)

        // 44 项：第 3 项（index 2）= round(127 × 2 / 43) = 6
        XCTAssertEqual(KeyMIDIMapper.scaleValue(steps: 44, index: 2, low: 0, high: 127), 6)

        // 默认 3 段的旧行为不变
        XCTAssertEqual(KeyMIDIMapper.majorScaleValue(steps: 3, low: 0, high: 127), 64)
        XCTAssertEqual(KeyMIDIMapper.minorScaleValue(steps: 3, low: 0, high: 127), 127)

        // 行程反向时同样成立
        XCTAssertEqual(KeyMIDIMapper.scaleValue(steps: 3, index: 1, low: 127, high: 0), 64)
    }
}
