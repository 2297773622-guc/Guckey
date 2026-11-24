// swift-tools-version: 5.9
//
//  Guckey —— 独立 macOS App（不是插件、不是插件宿主）
//  仅做：① 三级基调决策（手动 > 云端曲库 > AI 实时分析）
//        ② 通过虚拟 MIDI 遥控 DAW 内已运行的 Auto-Tune / WavesTune 宏控制旋钮
//  不加载 VST3 / AU / AAX，不实例化 AVAudioUnit 插件，不参与音频渲染链路。
//
//  构建：swift build -c release
//  运行：.build/release/Guckey
//  打包：./Scripts/package_dmg.sh

import PackageDescription

let package = Package(
    name: "Guckey",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Guckey", targets: ["Guckey"])
    ],
    targets: [
        .executableTarget(
            name: "Guckey",
            path: "Sources/Guckey",
            // 全部使用系统框架 + Accelerate 自研 DSP，不引入 aubio / Essentia 二进制依赖；
            // 本地缓存放 SQLite（系统 libsqlite3），云端走飞书多维表格（open.feishu.cn）。
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // 附属工具已移除；本仓库只保留 Guckey 主程序。
        .testTarget(
            name: "GuckeyTests",
            dependencies: ["Guckey"],
            path: "Tests/GuckeyTests"
        )
    ]
)
