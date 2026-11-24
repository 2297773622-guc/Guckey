# Guckey

> macOS 上的「三级基调决策 + 虚拟 MIDI 遥控」工具。
> 检测当前播放歌曲的基调，编码成两条 MIDI CC，驱动 Studio One 宏控制器旋钮，再由宏旋钮写进修音插件的 Key / Scale。

独立 App，不加载 VST3 / AU / AAX，不实例化 `AVAudioUnit`，**不参与音频渲染链路**。

> 本仓库包含 Guckey 主程序，以及 `docs/` 下的产品页面（GitHub Pages 发布源）。云端曲库的写入工具与服务端凭据不在其中。

---

## 1. 核心逻辑：三级基调决策

```
媒体信息（MediaRemote / AppleScript / 窗口标题）
        │  SongIdentityNormalizer → [歌手]_[歌名]
        ▼
┌───────────────────────────────────────────────────────┐
│ ① 手动更正   SQLite(manual_keys) — 最高优先，命中即锁定 │
│ ② 云端曲库   SQLite(cloud_keys)  — 精准 → Levenshtein  │
│ ③ AI 实时    音频 → 稳定化 → 输出（含 AI 自动缓存）    │
└───────────────────────────────────────────────────────┘
        │  KeyResult(source: manual / cloud / ai)
        ▼
MIDI CC（Root #20 / Scale #22 / 强度 #24）
        ▼
Studio One 外部设备 → 宏旋钮 → 插件 Key / Scale
```

**生效规则**

| 级别 | 命中后 | 是否发 CC |
|---|---|---|
| ① 手动 | 强制锁定，无视云端与 AI | 只发一次锁定的值，不再随 AI 波动 |
| ② 云端 | 锁定（精准优先，失败再模糊） | 同上 |
| ③ AI | 必须通过稳定化模块 | 稳定后才发；切歌后静默 6 秒 |

`KeyDecisionEngine` 一旦 `lockedSource != nil`，`ingestAI()` 会直接丢弃所有 AI 结果——这是「不再向 Studio One 发送波动基调 CC」的实现点。

### AI 稳定化（仅第三级）

| 参数 | 默认 | 作用 |
|---|---|---|
| 置信度下限 | 0.70 | Krumhansl 相关系数低于此值的单帧直接丢弃 |
| 滑动窗口 | 10 s | 窗口内某调占比 > 60% 才允许输出 |
| 首次锁定最少样本 | 6 | 防止 2–3 帧就抢锁（占比虚高） |
| 迟滞保持时长 | 3 s | 新调性连续保持这么久才允许切换 |
| 迟滞置信度优势 | 0.15 | 需高出 `locked + 0.15 × (1 − locked)`（按剩余余量折算，保证可达） |
| 启动静默 | 6 s | 切歌后这段时间不发 CC |
| 分析频段 | 60–500 Hz | 频域带通，聚焦和弦与贝斯 |

### 其他实现细节

- **放弃音频指纹**：所有匹配都基于归一化后的 `[歌手]_[歌名]`，三张表共用一个主键。
- **归一化**：剥掉 `(伴奏)`、`【Live】`、`- Remix`、`（高音质）`、平台后缀（`- QQ音乐`），全角转半角，只保留文字与字母数字；`《…》` 里的内容视为歌名本身。
- **反向键**：窗口标题无法判断「歌名 - 歌手」还是「歌手 - 歌名」时，命中查询会同时试 `歌手_歌名` 与 `歌名_歌手`。
- **模糊匹配**：Levenshtein 编辑距离，容差随长度放宽（≤4 字容 1，≤12 字容 2，更长按 1/6）。

---

## 2. 项目结构

```
Guckey/
├── .gitignore                        # 排除 .build / dist / CloudConfig.json
├── Package.swift                     # SwiftPM，链接 libsqlite3
├── Resources/
│   ├── Info.plist                    # 名称 / 版本 / 权限说明
│   ├── AppIcon.icns                  # 手绘源图（1024 → 840 内容 + 92 留白）
│   └── CloudConfig.example.json      # 云端连接参数模板（真实凭据不入库）
├── Scripts/
│   └── package_dmg.sh                # 通用二进制 + 签名 + DMG
├── Sources/Guckey/
│   ├── App/
│   │   ├── AppDelegate.swift         # 纯 AppKit 生命周期、菜单、状态栏、关于面板
│   │   ├── WindowCoordinator.swift   # 主窗口 + 悬浮窗，共用同一个 AppState
│   │   ├── FloatingPanel.swift       # 无边框常驻 NSPanel
│   │   ├── FloatingPanelController.swift # 顶边锚定的悬停展开、位置持久化
│   │   └── GlobalHotKey.swift        # ⌥⌘K
│   ├── Media/
│   │   ├── MediaMonitor.swift        # MediaRemote 桥接 + AppleScript + 窗口标题降级
│   │   └── SongIdentityNormalizer.swift # [歌手]_[歌名] 归一化 + Levenshtein
│   ├── Storage/
│   │   └── KeyDatabase.swift         # SQLite：manual_keys / cloud_keys / auto_keys / sync_state
│   ├── Cloud/
│   │   └── CloudSyncManager.swift    # 云端数据表全量同步（只读）+ 连接自检
│   ├── Decision/
│   │   ├── KeyDecisionEngine.swift   # 手动 > 云端 > AI 的三级查询与事件流
│   │   └── KeyStabilizer.swift       # 置信度过滤 / 滑动窗口 / 迟滞 / 静默
│   ├── Detection/
│   │   ├── KeyDetectionEngine.swift  # 逐帧调性估计（不做防抖）
│   │   ├── KeyDetectorProtocol.swift # 检测器抽象（真实 / 演示两套实现）
│   │   ├── DSP.swift                 # YIN + FFT 色度（60–500 Hz 带通）+ Krumhansl
│   │   ├── AudioCapture.swift        # 麦克风 / 虚拟声卡
│   │   └── ScreenCaptureKitCapture.swift # 系统音频（macOS 13+）
│   ├── MIDI/
│   │   ├── MIDIController.swift      # 虚拟 MIDI 源（CoreMIDI）
│   │   ├── KeyMIDIMapper.swift       # 基调 → CC 值（含 12 档等分与逐级校准）
│   │   └── OutputStrategies.swift    # MacroCCStrategy / IntensityOutputController
│   ├── Persistence/PersistenceStore.swift # UserDefaults 配置 + schema 迁移
│   ├── Models/
│   │   ├── Models.swift              # SongIdentity / KeyResult / KeySource / 映射模型
│   │   └── AppState.swift            # 单一状态源
│   └── UI/
│       ├── MainWindowView.swift      # 7 个 Tab + 来源色标 + AI 脉冲
│       ├── FloatingView.swift        # 悬浮窗（上方固定、下方展开）
│       ├── KeyPicker.swift           # 24 调网格选择器
│       ├── KnobView.swift            # 滚轮 / 拖动的强度旋钮
│       ├── CloudLibraryView.swift    # 同步状态 + 连接测试 + 本地搜索 + 三张表浏览
│       ├── StabilizerView.swift      # 稳定化参数 + 实时状态
│       ├── MacroControlView.swift    # 宏控制校准（12 音级 ± 微调 / 扫动）
│       ├── MappingEditorView.swift   # CC 编号与连发设置
│       ├── StudioOneGuideView.swift  # 链路图 + 分步配置 + 失败点
│       ├── SettingsView.swift        # 悬浮窗 / 检测 / 虚拟源
│       └── SupportView.swift         # 支持信息
└── Tests/GuckeyTests/
    ├── CoreLogicTests.swift          # 归一化 / 带通 / 调性剖面 / Levenshtein
    ├── DecisionTests.swift           # 稳定化 / SQLite / 三级优先 / 云端数据表字段解析
    ├── CloudDiagnosticsTests.swift   # 权限错误码 / 配置完整性
    └── MacroControlTests.swift       # CC 等分、12 档位、旧 JSON 兼容
```

---

## 3. 云端曲库

> 云端曲库是**只读**的：Guckey 启动时全量拉一次，之后所有查询都走本地 SQLite，切歌不发任何网络请求。
> 写入（新增 / 修正曲目）由另一个内部工具负责，不在本仓库。

### 表结构

一张数据表，7 个字段。程序按字段名读取，列顺序不影响。

| 字段 | 类型 | 说明 |
|---|---|---|
| 歌名 | 多行文本（主字段） | |
| 歌手 | 多行文本 | 空串表示未知 |
| 调 | 多行文本 | **唯一真相源**：`G` / `A♯` / `B♭`，改这一列就生效 |
| 调式 | 单选 | `Major` / `Minor` |
| 来源 | 单选 | 手动 / AI / 云端（云端库列表显示的就是它） |
| 命中次数 | 数字 | AI 累计检测到几次 |
| 更新时间 | 日期 | 毫秒时间戳 |

> ⚠️ **不要给「调」再加一个数字列**。早期版本并存过「音级」(0–11) 数字列，程序读数字、
> 用户改文本，结果「改了等于没改」，排查了很久。现在「调」是唯一真相源；
> 老表里若还留着「音级」列，程序只提示、不自动删（怕动到用户数据），可以手动删掉。

### 连接参数（本地文件，不入库）

连接参数不写进源码。仓库里只有占位模板 `Resources/CloudConfig.example.json`；
真实凭据放在本地文件，`BuiltinCloud` 按这个顺序查找：

1. App 包内 `Contents/Resources/CloudConfig.json`（打包分发用）
2. `~/Library/Application Support/Guckey/CloudConfig.json`（`swift build` 直接跑用）

```bash
mkdir -p ~/Library/Application\ Support/Guckey
cp Resources/CloudConfig.example.json ~/Library/Application\ Support/Guckey/CloudConfig.json
chmod 600 ~/Library/Application\ Support/Guckey/CloudConfig.json
# 然后填入 appID / appSecret / link / tableID
```

两个文件都找不到时全部留空 —— App 正常启动，只是云端库显示「未配置」，
也可以在「云端库 → 高级设置」里直接填（存 UserDefaults，优先于本地文件），改乱了点「恢复内置」。

> 换一张表 / 换一个应用时才需要动这些（有云端库管理权限的人操作）：
>
> 1. 一个能访问这张表的应用（应用 ID + 应用密钥）；
> 2. 该应用已被添加为这张表的协作者 —— 否则接口返回成功但 `items` 是空的；
> 3. 把应用 ID / 密钥 / 表格链接 / 数据表 ID 填进本地 `CloudConfig.json`（或「高级设置」）。
>
> 第 2 步最容易漏。漏了不会报错，看起来像「数据没导进去」，其实是应用根本没被授权访问这张表。

### 同步策略

- **全量拉取**：云端接口不提供 `updated_at > cursor` 这类增量过滤。曲库是几百条量级，
  一次 500 行、通常 1 个请求就够，所以每次同步都整体覆盖本地缓存；
- **顺带清理**：不在本次结果里的 `record_id` 会被 `pruneCloud` 删掉 ——
  你在表里删了一首歌，本地缓存不会继续拿旧调性去命中；
- 查询仍然只读本地 SQLite，切歌不发任何网络请求。

**在云端表里改完之后**：Guckey 不会实时监听，需要点一次「云端库 → 全量刷新」，或重启 Guckey（启动时会自动拉一次）。
另外本地「手动记录」（`manual_keys`）优先级仍然高于云端 —— 如果某首歌你曾在 Guckey 里手动确认过基调，
云端改它不会生效，得先在「设置」里清掉那条手动记录。

---

## 4. MIDI CC 输出

| 用途 | 默认 CC | 说明 |
|---|---|---|
| Root / 基调 | `CC#20` | 12 档等分到低/高档之间，档位取区间正中；逐音级可覆盖 |
| Scale / 调式 | `CC#22` | 按插件调式列表等分，Major / Minor 落在各自那一项 |
| 电音强度 | `CC#24` | 0–100% → 0–127，可反转；独立于宏控制 |

调式列表按「修音插件」自动匹配（计算方式始终是等分取第 N 项，预设只负责填好档位数与落点）：

| 插件 | 调式总数 | Major | Minor |
|---|---|---|---|
| Auto-Tune Pro | 29 | 第 1 项 | 第 2 项 |
| Auto-Tune Advanced | 15 | 第 2 项 | 第 3 项 |
| Auto-Tune (2026) | 15 | 第 2 项 | 第 3 项 |
| Waves Tune Realtime | 44 | 第 3 项 | 第 4 项 |
| topline | 10 | 第 2 项 | 第 3 项 |

不在列表里的插件选「自定义」，手动填总数（默认按第 2 / 第 3 段）。

- 默认**单通道（1）**发送；只有确认宿主按通道过滤收不到时，才在「MIDI 映射」打开 16 通道广播（广播会让 MIDI 学习里冒出 16 个重复旋钮）。
- 每条 CC 默认连发 2 次（间隔 25 ms），对「同值 CC 不响应」的链路更稳。
- 心跳每 2 秒一次，值未变化时是空操作。

### Studio One 配置（一次性）

1. Guckey 已创建虚拟源 `Guckey`（设置页可改名）。
2. Studio One → 选项 → 外部设备 → 添加 → 新建键盘：名称 `Guckey`，接收自 `Guckey`，**MIDI 通道只勾 1**（默认单通道发送）。
3. 宏控制面板里对旋钮做 MIDI 学习，同时点 Guckey「扫动 CC#20」。
4. 新建空旋钮 → 添加目标 = 插件的 Scale 参数 → 学 `CC#22`。
5. 对插件 Key / Scale 确认一次「添加目标」映射。
6. 强度：空旋钮 → 添加目标 = Speed/Retune → 学 `CC#24`。
7. 用「宏控制」页的 ± 微调校正 12 个音级与 Major/Minor。

> 为什么绕开插件直连：Studio One 7 的**插入效果器收不到 MIDI**（真机实测）；宏旋钮是宿主参数，能被外部控制器学习，所以链路走 `CC → 外部设备 → 宏旋钮 → 插件参数`。

---

## 5. 构建 / 运行 / 打包

```bash
swift build --disable-sandbox                 # Debug
swift test  --disable-sandbox                 # 53 项单元测试
./Scripts/package_dmg.sh                      # 通用二进制 + 签名 + DMG
open "../Guckey-<version>.dmg"
```

- `--disable-sandbox`：SwiftPM 生成 manifest 时偶发 `sandbox_apply` 失败，与本工程代码无关。
- 打包脚本从 `Resources/Info.plist` 读版本号，产出 `Guckey-<version>.dmg`（universal，已 ad-hoc / 开发证书签名）。

### 调试

```bash
.build/debug/Guckey -vta.detector.demo YES   # 演示模式：假曲目 + 假检测，走完整三级链路
```

---

## 6. 权限

| 权限 | 何时需要 |
|---|---|
| 屏幕录制 | 模式 B（ScreenCaptureKit 系统音频）首次运行 |
| 麦克风 | 模式 A（麦克风 / 线路输入） |
| 自动化（Apple Events） | MediaRemote 被系统限制时，从 Music / Spotify 读取曲目 |

音频只进 DSP，不录制、不上传、不进入输出链路。

---

## 7. 已知限制

- **MediaRemote 是私有框架**，通过 `dlopen` 使用；系统收紧时自动降级到 AppleScript 与窗口标题。
  （踩坑记录：block 必须存成类的存储属性，否则 Debug 构建会崩 `non-escaping closure has escaped`。）
- **窗口标题兜底**无法确定歌手/歌名顺序，靠反向键与模糊匹配兜住，个别歌曲可能匹配不到，用一次手动更正即可永久修正。
- 云端只读：Guckey 启动时全量拉一次，云端表里的改动要点「云端库 → 全量刷新」才生效；
  本地 `manual_keys` 优先级高于云端，被手动确认过的歌要清掉那条记录才会跟随云端。
- Studio One 宏旋钮映射需手动配置一次；本工具只能验证 CC 有没有被驱动（扫动 + 校准面板），无法代劳宿主的映射对话框。
- AI 检测用的是自研 DSP（Accelerate），未引入 Essentia / aubio 二进制；纯音乐、强打击乐、无贝斯的编曲置信度会偏低，此时提高「窗口长度」或降低「置信度下限」。

---

开发者：顾初 · Copyright © 2026 顾初. All rights reserved.
