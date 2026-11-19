# 英文写作助手（EnglishWriter）· PROJECT.md

> 卡号 t_b02227ec（现标题：《Grammarly 同款开源写作助手》）
> 北极星：Mac 上任意 App 的英文输入框里像 Grammarly 一样用——常驻、边写边查、错误处画线、悬停出卡片一键改。唯一差别：开源（MIT）。
> 口径来源：爹地 2026-11-16 原话「我的需求首先是做一个 grammarly 一样的插件出来…你就理解为一模一样，除了本项目为开源项目」。v0.1 的「不常驻/不轮询/只在被点那一刻读一次」全部作废。

---

## 1. 现状（2026-11-19 18:00 实测，逐项都是命令输出）

| 项 | 实测值 |
|---|---|
| HEAD | 见 `git log -1`（本节随每次交付更新） |
| 自检 | `--selftest` → **PASS 191 / FAIL 0**（含侧栏摆位 6 条 / 适配表 9 条 / 隐私 / 命中 / 坐标） |
| 装机 | `/Applications/Selfmade/英文写作助手.app`，二进制 18:00:39，sha256 `aada87ac23509dd3`，`SOALedger Dev` 签名，install-check SYNC |
| 侧栏 | `--sidebar-snapshot` → `qa/evidence/sidebar-panel.png`（360×620）与 `sidebar-panel-full.png`（360×955 整栏） |
| 适配表 | 9 条：TextEdit / Mail / Telegram 启用；Word / Notes / Outlook / WPS / Pages / Slack 关闭并写明「未探明」 |

### 里程碑

| 里程碑 | 状态 | 证据 |
|---|---|---|
| M1 行内下划线渲染器 | 已交付 | `--demo-selfcheck` PASS；`out/m1-snapshot.png` |
| M2 输入即检查 | 已交付（TextEdit 真机） | `--axcheck` 3/3；`--selftest --lt` |
| M3 悬停卡片 + 接受/忽略/撤销 | 已交付 | `--selftest --m3`、`--m3-drive` 16/0、`--m3-monitors` |
| M4 设置面板 + 词典/忽略 | 已交付 | `bash scripts/settings-selftest.sh` |
| M4 开源发布 | 仓库 public + MIT + Release v0.3.1 | `https://github.com/theWeatherMan21/EnglishWriter` |
| **P1 侧栏（产品层）** | **已交付** | 点球开栏 / 跟球同侧 / 高度自适应 / 实时刷新；`qa/evidence/sidebar-panel*.png` |
| **P2 评分四维** | **已交付** | `--selftest --score`；侧栏顶部大分数 + 四维条 |

### P1 侧栏口径（2026-11-19 落地，替代「只有线+球+单条卡片」）

- 入口：**点浮动球**开/收侧栏（不再是「跳到下一条」）；0 条也开，显示「没有更多建议」+ 评分。
- 摆位：`SidebarPlacement.resolve` 纯函数 —— 球在右半屏 → 栏在球左侧；球在左半屏 → 栏在球右侧；永不越屏。6 条断言在 `--selftest --ui`。
- 尺寸：宽 360pt；高度按内容自适应，上限 70% 屏高（`EW.naturalHeight()` 回报真实内容高度）。
- 内容：Overall 圆环（弧长按 SVG 真实 r 计算）+ 四维分数各带一句说明 + 分组列表（类别图标：圆/方/菱形 × 红/蓝/紫双编码）+ 每条「原文删除线 → 绿色建议 + 一句中文理由 + 忽略/接受」+ 底部语气。
- 筛选：「重要建议（无 style）/ 全部建议」两段式；「全部接受」放列表头，不与筛选混排。
- 实时：侧栏开着时每次新检查结果都推进去（`syncSidebarIfOpen`），不是打开那一刻的定格。


## 2. 代码结构（1490 → 2100+ 行）

| 文件 | 职责 |
|---|---|
| `Sources/Geometry.swift` | 坐标口径唯一入口：Quartz(左上原点) ↔ AppKit(左下原点)、多屏、并集、夹取 |
| `Sources/Underline.swift` | 行内下划线：`UnderlineKind`(拼写/语法/清晰度/风格 × 颜色/形态)、`UnderlinePainter`(唯一画线实现)、`UnderlineCanvas`、`UnderlineOverlay`(透明 NSPanel，ignoresMouseEvents，overlayWindow 层级) |
| `Sources/Diff.swift` | 逐条 diff 契约：`DiffItem`、`DiffParse`(围栏/裸数组/多键名容错)、`DiffSanitize`(越界丢弃/偏移修复/重叠丢弃)、`applyEdits`、提示词 v2、`InlineEngine`(OpenAI 兼容)、`MockDiff` |
| `Sources/Inline.swift` | 常驻输入感知：`AXInline`(全文/选区/`AXBoundsForRange` 多行拆矩形/叶节点下钻)、`Sentence`(按句切)、`InlineController`(每 pid 一个 AXObserver + 800ms 去抖 + hash 去重 + 引擎路由 + 渲染) |
| `Sources/LocalEngine.swift` | 本地 LanguageTool 客户端 + `SpanGuard`(术语/单据号/编码/签名块护栏) |
| `Sources/Demo.swift` | M1 自测台：真 NSTextView + Mock diff + 断言 + 离线合成快照 + AX 交叉校验（待授权后可跑） |
| `Sources/AXTarget.swift` | 焦点元素/选区/写回四层降级/撤销快照（v0.1 起沿用） |
| `Sources/Engine.swift` | 语言门控、术语硬闸、v0.1 整段契约与失败态文案（selftest 仍在用） |
| `Sources/UI.swift` | 菜单栏面板、设置窗口、`CardPanel`(nonactivating)、诊断计数 |
| `Sources/SelfTest.swift` | 无头自检：门控 / 硬闸 / 失败态 / diff 契约 / 本地引擎 |

---

## 3. 技术口径（钉死）

### 3.1 行内下划线
- `AXBoundsForRange` 取矩形；返回零尺寸（Chromium wrapper）时下钻叶节点，用字符偏移重新匹配。
- 长 range 按 2–6 字符切片，按 `midY` 分组（容差 `max(4, h*0.6)`）→ 每行取并集 = Grammarly 的 HighlightRects。
- 覆盖窗口：`[.borderless, .nonactivatingPanel]`、`backgroundColor = .clear`、`isOpaque = false`、`ignoresMouseEvents = true`、`level = CGWindowLevelForKey(.overlayWindow)`、`collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary, .transient]`。
- 线画在 `rect.maxY - 1`；波浪 amp 1.3 / period 5；拼写=红波浪、语法=红直线、清晰度=蓝细线、风格=紫虚线。

### 3.2 输入感知（取代 v0.1 的"不监听"）
- 每个 pid 一个 `AXObserver`；app 级 `AXFocusedUIElementChanged`，元素级 `AXValueChanged` / `AXSelectedTextChanged`。
- 去抖 800ms（DispatchWorkItem），同一 pid 同一句 hash 不重复请求，无轮询 Timer。
- 只检查光标所在句（`Sentence.around`）；句子结束符 `. ! ? \n 。！？`。
- 语言门控：CJK 占比 > 0.40 → 零请求。

### 3.3 引擎（双通道，同一 `[DiffItem]` 出口）
- **本地 LanguageTool**（`http://127.0.0.1:8081`，en-GB，picky）优先：热态 15–27ms。App 启动时调 `scripts/languagetool-up.sh` 静默拉起。
- **OpenAI 兼容**（爹地自填三件套）兜底：`{"edits":[{start,length,original,replacement,type,reason}]}`，UTF-16 偏移。
- 护栏：术语 / 箱号 / 港口码 / 长数字 / 金额 / 邮箱 / 链接区间内的建议一律丢；签名块之后不检查。

### 3.4 写回四层降级
AX text operation → 设选区 + `AXSelectedText` → `kAXValue` 整体写 → 剪贴板 ⌘V（用完恢复剪贴板）。

---

## 4. 验收证据（可复跑）

```
$ ./build/英文写作助手 --selftest --lt
=== 汇总：PASS 56 / FAIL 0 ===
  LT·探活 在线
  LT·有错句#1  3 条 1686ms（冷启）：There is many reasons→There are many reasons | sent→send | immediatly→immediately
  LT·有错句#2  1 条 27ms
  LT·有错句#3  2 条 17ms
  LT·干净句#1..#5  全部 0 条误报（含合成箱号形态样例 / CNTAO / CNSHTA / 长数字 / demurrage 等；真单号不进仓库）
  LT·签名块不检查

$ ./build/英文写作助手 --demo-selfcheck
  5 条 edit → 5 个矩形 → RESULT: PASS

$ ./build/英文写作助手 --demo --snapshot out/m1-snapshot.png
  SNAPSHOT: out/m1-snapshot.png   （五处下划线压在对应词组下方，拼写处波浪）
```

---

## 5. 需要爹地动手（仅一件）

系统设置 → 隐私与安全性 → 辅助功能 → 勾「英文写作助手」。
（`/Applications/Selfmade/英文写作助手.app`，`com.wanyi.englishwriter`，SOALedger Dev 签名 → 重编译不丢授权。）

TCC 无法程序代勾；勾完我自行重启并出真机截图（Mail + TextEdit）。

---

## 6. M3 链路 · 交付说明（2026-11-19 收口）

**一句话**：鼠标停在划线上 200ms（或单击划线）→ 出卡片（类别色标 / 原句 / 建议 / 一句中文理由 / 接受·忽略）→ 接受只改这一条 → 菜单「撤销上次替换」用快照还原 → 忽略按文本 hash 过滤，后续检查不再返回。

实现口径（唯一入口，别处不许复制逻辑）：

| 环节 | 落点 | 关键约束 |
|---|---|---|
| 命中 | `HoverCoordinator.start()` 挂 `.mouseMoved` + `.leftMouseDown` 两个全局监听；`M3Flow.hit()`（±3/±6 容错） | 覆盖窗口 `ignoresMouseEvents=true`，命中判定只能走监听，不靠窗口事件 |
| 停留 | 200ms `dwellDelay`；鼠标进卡片区域算「还在悬停」 | 移开 → 关卡片，取消未到期的弹卡 |
| 卡片 | `CardWeb`（`.nonactivatingPanel` + `canBecomeKey=false`）；内容由 `CardWeb.payload()` 唯一构造 | 跟矩形下方 4pt，下方放不下翻上方、左右夹进该屏可见区（`CardPlacement.resolve`） |
| 接受 | `InlineController.accept(itemID:)` → `M3Flow.accept(items:only:in:stack:)` → `applyEdits(only:)` | 只替换该条 range；`range` 处原文对不上就拒写 |
| 写回 | `docFor(itemID:)` 选文档视图：Web 块 `WebText.replace` / AX 元素 `layeredWrite`（AXSelectedText → 剪贴板 ⌘V 兜底，用完恢复剪贴板） | 读不回正文的输入框（Chromium）不比文本，只信写回返回值 |
| 撤销 | `M3UndoStack`（快照 + pid + range + 文档句柄），菜单「撤销上次替换」→ `undoLastAccept()` → `M3Flow.undo(stack:)` | range 回写失败或文本被再改过 → 用接受前快照整段回写 |
| 忽略 | `IgnoreStore`（`ignore.rules` + `ignore.hashes`），忽略指纹 `IgnoreStore.hash()` | AX 与 Web 两条检查通道都在出条目时过滤 |

离线自证（命令都在仓根跑，输出见 `out/`）：

```bash
./build/英文写作助手 --selftest                    # PASS 191 / FAIL 0（含侧栏摆位 6 条 / 适配表 9 条）
./build/英文写作助手 --sidebar-snapshot out/sidebar.png        # 侧栏离屏快照（与上屏共用一份 payload）
EW_SIDEBAR_FULL=1 ./build/英文写作助手 --sidebar-snapshot out/sidebar-full.png  # 整栏高度
./build/英文写作助手 --ax-elements                 # 只读探测各宿主输入元素 → qa/evidence/ax-elements.json
./build/英文写作助手 --selftest --m3               # PASS 173 / FAIL 0（含 M3·链路驱动 / 卡片结构 / 悬停监听）
./build/英文写作助手 --m3-drive out/m3-drive.log  # 16/0，行级：命中坐标 → 卡片 frame → 接受 → 撤销 → 忽略
./build/英文写作助手 --m3-monitors                 # 全局 mouseMoved 真收到系统合成事件（不建窗口）
./build/英文写作助手 --demo-selfcheck              # M1 不退化
./build/英文写作助手 --selftest --lt               # M2 不退化（需 8081 在线）
```

---

## 7. M4 设置面板 · 交付说明（2026-11-19）

**一句话**：模型三件套 / 引擎地址 / 方言 / App 排除 / 个人词典 / 忽略规则全部在 App 内配完，改完即时生效（模型三件套下一次请求生效）。

### UserDefaults 结构与键名（域固定 `com.wanyi.englishwriter`）

| key | 类型 | 空值语义 | 说明 |
|---|---|---|---|
| `llm.baseURL` | String | **空 = 远端通道不启用**（零预设，绝不回退内置地址） | 手填，如 `https://host/v1`（OpenAI 兼容，`/chat/completions` 自动拼） |
| `llm.apiKey` | String | 空 = 不启用 | 只存本机；拼进 `Authorization: Bearer` |
| `llm.model` | String | 空 = 不启用 | 请求体 `model` 字段 |
| `lt.baseURL` | String | 空 = `http://127.0.0.1:8081` | 本地 LanguageTool 地址；留空不落盘默认值，随时可换成别人的 LT |
| `lt.enabled` | Bool | false = 不起 JVM | 本地 LT 开关（LT 常驻约 370MB） |
| `lt.language` | String | 空 = `en-GB` | 可选 `en-US`/`en-AU`/`en-CA`/`en-NZ`，也可手填 |
| `exclude.apps` | [String] | 空 = 不排除任何 App | 填 bundle id 或应用名（忽略大小写）；命中 = 不挂 AXObserver、不检查、不画线 |
| `dict.words` | [String] | 空 = 没有预设词 | 个人词典；本地 LT 与远端 diff **两条通道都过滤**（按命中区间判，不靠字符串相等） |
| `ignore.rules` | [[String]] | 空 = 没有规则 | 永久忽略，元素是 `[原词, 建议]` 二元组；**本次忽略只在内存，绝不写这个键** |

三件套「空 = 不启用」的证明不是注释，是断言：`--selftest --settings` 用 URLProtocol 打桩计数，
空配置下 `InlineEngine.review` / `Engine.review` / `Rewrite.suggest` 三条通道全部 `notConfigured` 且计数 **0**；
同一打桩在配置齐全时必须发出 **1** 次（正控，防计数器变死代码）。

### 热生效边界

| 配置 | 何时生效 | 机制 |
|---|---|---|
| 引擎地址 / 方言 | 下一次检查 | 每次检查现读 `EnginePrefs.ltBaseURL()` / `EnginePrefs.language()`，无缓存 |
| 个人词典 / 忽略规则 | 下一次检查 | `PersonalFilter` 每次现读 `DictStore.words` / `IgnoreStore` |
| App 排除 | 下一次焦点切换 / 检查 | `excludeGate` 在挂 observer 与检查两个入口都判 |
| 模型三件套 | 下一次请求 | `checkNow` 内 `SettingsStore.load()` |

### 忽略的两种语义

- **本次忽略**（卡片「本次忽略」）：只进内存，本次运行内不再提示；重启 App 恢复提示。
- **不再提示**（卡片「不再提示」= 永久）：写 `ignore.rules`，跨重启有效；设置面板「清空永久」可整体撤销。

### 复跑命令

```bash
bash scripts/settings-selftest.sh        # 断言 + 静态不变量 + 面板截图，一条命令
./build/英文写作助手 --selftest --settings   # 只跑断言（PASS 140 / FAIL 0）
./build/英文写作助手 --settings-snapshot out/settings-panel.png   # 只出面板图（隔离域，不碰真实配置）
```

面板截图为离屏合成（窗口坐标 -6000, -6000，不 orderFront、不 screencapture），固定浅色外观。
