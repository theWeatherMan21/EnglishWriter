# 英文写作助手（EnglishWriter）· PROJECT.md

> 卡号 t_b02227ec（现标题：《Grammarly 同款开源写作助手》）
> 北极星：Mac 上任意 App 的英文输入框里像 Grammarly 一样用——常驻、边写边查、错误处画线、悬停出卡片一键改。唯一差别：开源（MIT）。
> 口径来源：爹地 2026-11-16 原话「我的需求首先是做一个 grammarly 一样的插件出来…你就理解为一模一样，除了本项目为开源项目」。v0.1 的「不常驻/不轮询/只在被点那一刻读一次」全部作废。

---

## 1. 现状（2026-11-19 18:00 实测，逐项都是命令输出）

| 项 | 实测值 |
|---|---|
| HEAD | `22c6499`（本节随每次交付更新） |
| 一条命令 | `bash scripts/ci-test.sh` → EXIT=0（编译 + 自测 + 规则 + Mail 块 + WebUI + 隐私 74 + 改写 9 + 接受闭环 11 + 点击几何 7 + deep 100% + 视觉基线 + 崩溃防线 + 阈值防线 + 扩展 E2E） |
| 自检 | `--selftest` 45 / `--selftest --style` 64 / `--ui` 61 / `--privacy` 74（全 FAIL 0） |
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
- 语言门控：CJK 占比 > `LanguageGate.cjkGate`（**0.30，全局唯一来源**；DocScan / Engine / MailProbe / LocalAPI 全部引用它，CI 有 grep 硬拦重复副本）→ 零请求。
- 只查「你正在写的」：可编辑输入框、网页里的可编辑控件、**写信窗口的正文区**（判据：该 AXWebArea 所在窗口里存在可编辑控件）。阅读别人的邮件（`[reading]`）默认不查，`EnginePrefs.checkReading` 可开。
- Web 正文只查看得见的块（`WebText.visibleBlocks`），单轮 ≤ 40 块、≤ 8000 字，**合并成一次** `/v2/check`，match 按偏移映射回块（`BlockBatch`）；上一轮没跑完只记 `skip-busy` 并合并补跑。
- 去重键 = 「块号 + 原文小写」（跨段同词各报一次；同一块内重复只留一条）。
- `skip-readonly` **不清线**：线的存活只由「宿主切换」与 TTL 决定。

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


---

## 5. 与 Grammarly 的差距（2026-11-23 实测口径）

| 能力 | 状态 | 证据 / 判据 |
|---|---|---|
| 行内下划线（四类） | 已有 | `--demo-selfcheck`、Mail `render item>0 rect>0` |
| 点击出卡片 → 接受/忽略/词典 | 部分 | 离屏闭环 `--acceptflow` 11/0；**真机 click-hit 仍缺** |
| 改写三档（简洁/正式/清晰） | 已有（后端+UI 入口） | `--live-rewrite` 5 句×3 轮 5/5 · ~4.2s；扩展「候选 3 条」 |
| 语气检测 + 调整 | 后端已有，UI 未验 | `--live-tone` |
| 侧栏全文报告 | 已有骨架 | `--sidebar-snapshot`；实时刷新 `syncSidebarIfOpen` |
| 总体评分四维 | 已有 | `--selftest --score` |
| 个人词典管理界面 | 存储有，界面薄 | 设置面板内「个人词典」列表（仅增删，无导入导出） |
| 浏览器覆盖 | Chrome/Edge/Brave/Chromium/Firefox = 扩展；**Safari = App 自己画**，.appex 外壳已可构建（`scripts/safari-appex.sh`，READY + 临时签名），启用需在 Safari 设置里勾选 | `browserBundleIDs` + `safari-appex.sh` 6 条自验 |
| 原生 App 覆盖 | TextEdit / Mail / Telegram 启用；Word/Pages/Outlook/WPS/Slack 未适配 | `PROJECT.md` 适配表 9 条 |
| 性能护栏 | 已有 | 单轮 1 次请求、在飞 ≤2、java 空闲 0% |

**唯一硬缺口**：真机「点线 → 卡片 → 接受 → 文字变」这一段从未在真机跑通（所有相关断言都是离屏的）。

## 6. 日志级别口径（2026-11-23 改正）

**症状**：`~/Library/Logs/EnglishWriter/app.log` 一天 20,820 行 `ERROR`，真故障 0 行 —— `skip-readonly / attach-el / web-poll / accept-write` 这些「带说明的正常路径」全被记成 ERROR，自检 cron 每轮假警。

**根因**：`main.swift` 的 `onCheck` 判据是「`err != "-"` 就算引擎失败」。但 `CheckEvent.err` 是**说明文字**（`skip-readonly→"readonly"`、`accept-write→"→ 新文本 栈=1"`），不是错误标志。

**现在**：判据搬到 `Sources/CheckLogLevel.swift`（纯函数）：只有 `failureKinds`（`accept-fail` / 预留 `draft-backup-fail`）记 ERROR，其余一律 INFO。断言 `--selftest --log` 20 条（含 `skip-*` 全族反向判据）。

**自检同步改**（`~/.hermes/selfcheck/projects.json`，过 `selfcheck-add.py` 闸门）：`normal` 改为任意 `INFO|DEBUG <tag>`，`glob` 只认 `app.log`、`window_min=30`（归档文件留档复盘，不参与值班）。改之前 18:00 前后的历史误报行已归档到 `~/Library/Logs/EnglishWriter/archive/app.log-pre-logclass-fix-20261123-1955`（未删，grep 可用）。

**证据**：`build/ci-selftest --selftest` 306/0；`scripts/ci-test.sh` 全部通过；装机 19:35（sha `67b815b1…`），重启后 app.log 只有 INFO boot/m3/ax 行；`selfcheck-run.py` → `EnglishWriter 正常`。

## 7. 真机写回：字符计数定位跑通（2026-11-24）

**结论**：Mail 写信窗里「只改那一个词」的路径通了，格式与签名图片零改动。

真机验收（最小化窗口、前台 Finder、连跑 3 次 3/3）：

```
focus-return 细节 front=true 目标窗="New Message" 焦点窗="New Message" 同窗=true
复制概况：AX=210字（不含图片文件名）⌘C=275字（含图片文件名）
keyboard-word 定位：块=1+38 词偏移=8 长度=4 全文320字
keyboard-word 字符级选中 "send"（期望 "send"）
keyboard-type 校验：逐字一致=true 读回275字 期望275字 图片=3
write-layer=keyboard-charcount "send"→"sent"（逐字键入，未动剪贴板/整篇）
accept(itemID: 0) → ok
```

**做法**：`⌘↑` 文首 → `→` × absOffset（AX 块偏移算出）→ `⇧→` × len（字符级，无歧义，不依赖 ⌥→ 的词边界）
→ `⌘C` 读回必须逐字等于原文（不符 ±1 微调最多 4 次）→ 逐字键入替换词
→ `⌘A⌘C` 读回与期望**逐字**比对（不是比长度；`send→sent` 同长度必须靠逐字）→ 图片节点数不变。

**死路留档（别再走）**：词级 `⇧⌥→ / ⌥← / ⌘F`（WKWebView 无可复制选区，6 轮全败）；
富文本整篇 `⌘A⌘C RTF → 改词 → ⌘A⌘V`（粘贴后签名图片 3→0，已自动回滚）；纯文本整篇（格式拍平，爹地否）。

**P0 安全闸（同日事故后加）**：
- `returnFocusToBody` 先 raise 目标窗口，再 `activate([.activateIgnoringOtherApps])`（**去掉 `.activateAllWindows`**，它会把 Mail 所有窗口抬前面、焦点落到爹地正在看的那封）
- 按键前核对 `kAXFocusedWindow` 必须 CFEqual 目标窗口，不等 → 一个字都不按
- `⌘C` 字数 > AX 字数 ×3 → 判焦点跑偏，放弃
- 块文本在整篇里找不到 / 目标词不在块里 → 必须留日志（旧的裸 `return` 表现为「点了没反应也没提示」）

## 8. 性能：AX 卡顿根因与改法（2026-11-24，sample 实证）

**症状**：主线程 1750 样本里 1731 个卡在 `AXUIElementCopyAttributeValue` → `mach_msg`；单轮 `axTotal=1502ms`。

**两个根因**（都不是「调大超时」能救的）：
1. `AXUIElementSetMessagingTimeout` 对部分调用**不生效**（实测 `AXFocusedUIElement` 花了 1493ms，元素超时设 200ms）；
2. 一轮里 `AXChildren` 被调 **1808 次**（多趟遍历重复走同一批节点，Mail 的 WebArea 255 节点）。

**改法**：
- AX 调用放专用串行队列（`axWorkerQueue`），主线程只等**有上限**的时间（标量 80ms / 文本 150ms / AXChildren 250ms），
  等不到记 `abandon attr=NAME` 并放弃本轮；
- 轮内 `AXChildren` 缓存（同一元素一轮只跨进程取一次）；
- 按属性分级超时（AXChildren 500ms / 文本 200ms / 标量 80ms）+ 单轮预算 1500ms；
- `slow attr` 阈值 100ms → 300ms（150–250ms 是 AXChildren 正常值，之前刷满 40 条假警）。

**实测**：`axTotal` 1502ms → **0–6ms**；`AXChildren` 1808 次/1490ms → **111–156 次/1ms**；主线程 sample 无 AX 帧。

**仍已知**：AX 调用逻辑上还在主线程发起（靠有界等待兜住），彻底搬出需要把 `checkNowCore` 读取段拆成无 UI 依赖的 worker ——
非必要不做，先看真实使用两天的表现。

## 9. 语言门控 vs 过滤：日志口径（2026-11-24 改正）

`skip-lang`（原来打「中文块 N · 0 请求」）与「引擎回传后全被过滤」是两件事，混在一起会误判成「整轮被门控拦了」：

- 引擎回传 N 条但全被过滤（全大写缩写 / 去重）→ `filtered-all`：「引擎回传 2 条 → 缩写/去重过滤后 0 条（跳过中文块 1）」
- 真有请求发不出去（全中文块 / 无英文块）→ `skip-lang`

**已知引擎边界**：LanguageTool 对 `I send this to your email,` 在 `level=picky` 下 **0 条**（`send→sent` 需要时间状语类上下文才报）。
所以「这一封没画线」不等于漏检 —— 先 `curl /v2/check` 复核原文，再判我们的链路。

## 10. Mail 看线链：八版复盘与方向修正（2026-11-25）

### 10.1 一句话结论

Mail 写信窗「读出正文 → 送检 → 画线」这条链，**从未在真机上通过一次**。
11-25 一天改到第八版，每修一层露出下一层；最终指向的不是某一行代码，而是**方法本身错了**：
我们逐节点遍历 AX 树（255 个叶子、每节点 2–3 次跨进程调用）在规格上就不该做。

### 10.2 八版链条（每层断点 + 形态）

| 版本 | 修的点 | 下一层暴露的问题 |
|---|---|---|
| `54915d4` | specTTL 3s→8s、composeBody 选窗、skip-readonly 分因 | 选了写窗但从不触发检查 |
| `52f500b` | 挂 AXObserver 即查一次；锁定期间不许只读元素顶掉 target | 有正文但被 reading-window 判死 |
| `7712b26` | 单次 nil 不解锁；隐式锁定；web-poll 补查 | no-editable-region 又拦一道 |
| `36f5dfb` | 五道门合并成 Mail 单通道 fastpath | fastpath 之后无 blocks= |
| `bf1f3ca`/`f052180` | 可见块=0 兜底；blocks deadline 2.5s；窗口帧兜底 | 依然 0 块 |
| `ad93275` | abandon 不丢结果（回填）；标量 80ms→300ms | App 0% CPU 躺平 |
| `0c67d02` | frame 读不到不许当「不在窗口内」；fastpath 复用预读块 | fastpath 一条都没进 |
| `80c13c9`/`6a66d46` | 入口留痕；启动对齐前台 App；轮询 Mail 先问写窗；poll-skip 留痕 | 入口终于可见，但链仍不通 |

### 10.3 三类反复出现的 bug 形态（写进规范的）

1. **同一份数据被读两遍**：composeBody 读一遍（宽预算）、checkWeb 再读一遍（紧预算），
   谁先超时谁否决。→ 规范：**读过一次就传值，不许二次遍历**。
2. **超时当失败、失败就丢弃**：`abandon attr` 丢结果、`blocks` 撞 deadline 返回空数组且零日志。
   → 规范：**超时只能降级或回填，不许丢结果；任何提前 return 必须有日志**。
3. **静默门控**：locked / loginwindow / 可见块=0 / 焦点读不到，全是一行不打的 return。
   → 规范：**每个 guard 早退都要留一行，带判定量**（poll-skip / no-blocks / poll-nil 即此产物）。

### 10.4 方向修正：AXTextMarker（2026-11-25 晚）

WKWebView（Mail 正文）的 `kAXValue` 为空，正文是 AXStaticText 叶子；macOS 没有批量取子树的 AX API。
WebKit 为此给了专用通道：

```
AXTextMarkerRangeForUIElement            属性 → range
AXUIElementCopyParameterizedAttributeValue(webArea, "AXStringForTextMarkerRange", range, &out)   → 整篇纯文本
AXUIElementCopyParameterizedAttributeValue(webArea, "AXBoundsForTextMarkerRange", range, &out)   → 一段的屏幕矩形
AXSelectedTextMarkerRange                属性 → 设选区（写回用）
```

**本机实测（macOS 27.3）**：`dlsym("AXStringForTextMarkerRange") = 0x0`（C 小程序独立复核），
该函数已不是导出符号 → **必须走参数化属性**，不能照抄开源项目的函数式调用。

探针：`--axmarker-probe`（只读/不建窗/不激活/不敲键）会打印含 Marker 的参数化属性名，
再打 `axmarker-read len=… ms=… 预览=…`。

**状态：等一次真机跑**。验证时屏幕锁着（`SKIP screen-locked`，Mail 有 5 个窗口但 AX 树只剩骨架），
按既有口径锁屏结论不作数。解锁后跑一条命令即可定方向。

### 10.5 下一步（严格顺序，不许跳）

1. 解锁后跑 `--axmarker-probe`：拿到 len / ms / Marker 属性名列表
2. 只有 (1) 通过，才把「读正文 / 算位置 / 设选区」整条换成 marker；主链一次换完，不再逐门修
3. 判据：`axmarker-read len=232` → `引擎回传 items=1` → `underline-draw n=1`
4. 连续三次真机都有线，才对爹地说「看线可用了」

## 11 · AXTextMarker 通道（11-25 真机打通）

**一句话**：Mail 正文不走 AX 树遍历，走 WebKit 的 marker 参数化属性；一次调用拿全文，一次调用拿矩形。

### 11.1 真机证据（13:54:11，Mail 写窗 win=New Message）
```
axmarker-read   textLen=251
m3              blocks=1 送检块=1 批次字符=253 预览=⏎He go to the office yesterday.
m3              引擎回传 items=4 → 映射后 4（缩写过滤后 1）
render          items=1 rects=1
underline-draw  n=1 ttl=8s [grammar@115,424,18,16]
```
同窗口 marker 探针：`bounds office = (174,424,37,16)` —— 与 115,424 相邻，位置自洽。

### 11.2 本机 API 形态（macOS 27.3，实测）
| 需要 | 本机可用形态 | 不可用 |
|---|---|---|
| 全文 | 参数化 `AXTextMarkerRangeForUIElement`（参数=元素）+ 参数化 `AXStringForTextMarkerRange` | 函数符号 `AXStringForTextMarkerRange`（dlsym 0x0） |
| 首尾 | 普通属性 `AXStartTextMarker` / `AXEndTextMarker` | — |
| 拼 range | 参数化 `AXTextMarkerRangeForTextMarkers`（[start,end]） | — |
| 位置 | 参数化 `AXBoundsForTextMarkerRange` | — |
| 按字符定位 | 参数化 `AXTextMarkerForIndex`（index→marker） | — |

WebArea 暴露 36 个含 Marker 的参数化属性；**`AXTextMarkerRangeForUIElement` 不是普通属性**（第一版按属性取，取不到 → SKIP）。

### 11.3 代码落点
- `MailProbe.composeBody`：`AXMarker.fullText` 取正文（0ms），marker 失败才退回 `WebText.blocks`；2 秒缓存（attach/轮询/fastpath 三路并发抓 AX 时否则互相拖死：实测 AXChildren 1347ms×2115）。
- `checkWeb(trusted)`：marker 全文当一个块（偏移天然全局）。
- `applyWeb`：单块 + 元素是 WebArea → `AXMarker.rects`。
- 语言门控：marker 单块逐行判定，非英文行等长空格遮蔽（偏移不变）——解开「送检块=0 跳过中文=1」假门。
- 调试旋钮 `EW_FORCE_PID=<pid>`：把检查目标钉到某 pid，不动前台即可验证；不设时行为不变。

### 11.4 已知边界（11-25 实测）
- **窗口在后台时 `AXBoundsForTextMarkerRange` 返回空** → `items=1 rects=0`：前台 Mail → rects=1（14:33:22）；同一文本后台 → rects=0（14:31:58）。不是代码分支差异，是系统对遮挡窗口不给几何。**结论：线只在宿主 App 前台时可见；切走后不画（后台不抢画、也不清别人的线）。**
- 前端引擎偶发 8.5s（14:33:32 elapsed=8516ms），非 AX 侧，单列观察。
- 旧块遍历路径保留为 fallback（旧系统 / 非 WebArea）。
