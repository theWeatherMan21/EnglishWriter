# 英文写作助手（EnglishWriter）· PROJECT.md

> 卡号 t_b02227ec（现标题：《Grammarly 同款开源写作助手》）
> 北极星：Mac 上任意 App 的英文输入框里像 Grammarly 一样用——常驻、边写边查、错误处画线、悬停出卡片一键改。唯一差别：开源（MIT）。
> 口径来源：爹地 2026-11-16 原话「我的需求首先是做一个 grammarly 一样的插件出来…你就理解为一模一样，除了本项目为开源项目」。v0.1 的「不常驻/不轮询/只在被点那一刻读一次」全部作废。

---

## 1. 现状（2026-11-16）

| 里程碑 | 状态 | 证据 |
|---|---|---|
| M1 行内下划线渲染器 | **已交付（待真机复核）** | `--demo-selfcheck` → PASS，5 处错误 5 个矩形；快照 `out/m1-snapshot.png` |
| M2 输入即检查 | **真机已验（TextEdit）** | `--axcheck --spawn --notify` 3/3：AXObserver 自发触发 → 800ms 去抖 → rects=3（62/49/147ms）；`--selftest --lt` 56/0 |
| M3 悬停卡片 + 接受/忽略/撤销 + 词典 | **已交付（待真机复核）** | `--selftest --m3` → **PASS 53/0**；卡片离线渲染 `out/m3-card.png`（320×147）；commit `2a30293` |
| M3.3 三类命中合并去重 | **已交付** | `--selftest --m3` 合并不变量 PASS（重复/重叠/相接/越界/升序/端到端） |
| M4 #8 设置面板 | **已交付（UI 手点留给爹地）** | `bash scripts/settings-selftest.sh` → PASS 10 项：零预设、独立进程 `defaults read` 冷读六项一致、词典过滤 1→0、App 排除命中/不误伤。证据 `qa/evidence/settings-selftest.json` |
| M4 Chromium contenteditable 矩形 | **已打通（扩展侧）** | `bash scripts/ext-real-probe.sh` → PASS：`#ce` 真焦点、3 命中 / 3 矩形（rect_source=`range`）、强制兜底 `child-union` 也出矩形、接受/撤销读回一致；证据 `qa/evidence/ext-real-probe.json` |
| `--passive` 仪器自证 | **R1** | `bash scripts/passive-selfcheck.sh` → 9/9 PASS（正控活 + 只读写回 0 + 上屏 0 + 日志七字段）；证据 `qa/evidence/passive-selfcheck.json` |
| M4 开源发布 | 等爹地点头 | README 补完安装/三件套/LanguageTool 三段；CI 远端已真跑绿（run 见 `out/parity.md` #15）；public 化不动 |

唯一阻塞：A 层真机验收需要一个真实靶子窗口（爹地红线禁止我们弹窗），要他开一个 TextEdit 空白文档放那儿。
工具已就绪：`--axcheck`（AXValue 直写正文 → checkNow → 读 overlay.specs，不激活/不敲键/不截屏，下划线只算不上屏，合成图走离屏位图）。
纪律：`--realshot`（B 层，CGEvent 敲键）在 `textSet=false` 时一律以退出码 9 收尾，标注「无效验收」——不得拿它当 M2 结论。

---

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

## 6. 下一批（M3）

1. 悬停命中：全局 `mouseMoved` 监听 + `UnderlineOverlay.currentRects()` 命中测试（覆盖窗口不收事件）。
2. 卡片改逐条：类别 / 原句 / 建议 / 一句中文理由 / 接受 · 忽略。
3. 接受 → `applyEdits(items, to:, only:)` 逐条写回；撤销 → 原文快照还原；忽略 → 本会话黑名单。
