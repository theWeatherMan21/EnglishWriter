# 英文写作助手（EnglishWriter）· PROJECT.md

> 建卡：t_b02227ec · 北极星一句话：写英文时中文输入零干扰、航运术语零误报、不卡；需要改的时候点一下就出建议。
> 卡面修订全文与本文件同文（工人上下文里 `hermes kanban edit` 被内核拒，改卡面正文只能在主线上做，故两处都放）。

## 北极星

在 Mail / Word / Slack 里写英文时：中文输入零干扰、航运术语零误报、不卡；需要改的时候点一下就出建议。

## 背景（Grammarly v1.209.0 符号级勘察实证）

引擎在服务端（客户端只有 23 个 `AlertPname` 标签）→ 能力复刻不了；**无语言检测**；文本替换走 pasteboard 补丁管道 + 串行锁（`"Another Pasteboard action is in progress..."`）→ Mail 打中文与输入法抢剪贴板 = 卡顿（Blocked apps 止血已交付爹地）。
故本 App 第一原则：**不常驻、不轮询、不监听键盘**，只在被触发那一刻读一次 AX。

## v0.1 范围

1. 常驻菜单栏 App（Swift），无 Dock 图标、无主窗口
2. **唯一主入口 = 菜单栏菜单项「改选中文本」**；全局热键延到 v0.1.1（可配、默认避开系统组合）
   - 面板 `NSPanel(.nonactivatingPanel, .borderless)` + `becomesKeyOnlyIfNeeded`，保证 Mail 仍持前台
   - 选区预取：`NSWorkspace.didActivateApplicationNotification` 记「最后一个非本 App 的前台 pid」，触发时对那个 pid 读 `kAXFocusedUIElement`（**不装 AXObserver、不起 Timer**）
3. 焦点/选区读取复用 `~/Documents/grammarly-re-study/axprobe/axfocus.swift` 的 AX 层（4 个坑的解法）
4. **语言门控**：选中文本 CJK 码点占比 > 40% → 直接返回，不取全文、不发请求（请求计数 = 0）
5. 卡片：原句 / 建议 / 一句原因
6. 点「应用」→ 替换选中文本（先试 `AXSelectedText` settable 写入，不可写退 pasteboard ⌘V）
7. **撤销兜底**：替换前存原文快照 + pid + range，菜单栏「撤销上次替换」一键还原。`⌘Z` 只记录、不作判据
8. 设置：base URL / API key / model **三项全手填、零预设默认值**，存 UserDefaults，下次请求即用新值

## LLM 契约（钉死）

- 一次一条整段重写，非逐条 diff
- 输出 `{"original":"…","suggestion":"…","reason":"<一句中文>"}`
- 输入 > 2000 字符 → 拒绝、不发请求、提示「选中太长（N>2000），请分段」
- 超时 15s
- 三失败态各一行文案：非200 = `接口返回 HTTP <code>：<body 前120字>`；解析失败 = `模型没按 JSON 回，原文未改动`；网络断 = `15 秒没回话，检查网络或 base URL`
- `POST {base}/chat/completions`，`Bearer <key>`，`temperature=0`

## 术语硬闸（代码拦截，非提示词叮嘱）

- 词表：FCL LCL BL B/L ETD ETA ATA ATD SO SI VGM CY CFS THC POD POL HBL MBL D/O C/O IMO HS DG TEU FEU DAP CIF FOB CFR DDP EXW MSDS PO PI CI PL
- ① 无改动（原文与建议仅差空白）→ 丢建议
- ② 术语 token **原样形态（含大小写）**任何一处变化 → 丢建议（`FCL→fcl` 也丢）
- 短词（≤2 字符，如 SO/PO）只在小写以外的形态下算术语，避免把普通词 `so` 当术语

## 不做

全局热键（v0.1.1）· 行内下划线（原生渲染层改不了）· 自动扫描（= 把干扰源请回来）· 中文语法检查 · 改 Grammarly 本体

## 前置探针（结果落 `~/Library/Application Support/EnglishWriter/probe-result.json`）

1. Mail 正文区 `AXSelectedText` 可读？settable？
2. `nonactivatingPanel` 打开时 Mail 仍持前台、选区仍可读？
3. 只能走 pasteboard 时，单次使用输入法候选框是否不闪断（录屏）
**Mail 写入不可行 → 退「建议 + 一键复制」，改卡后按降级版继续**

## DoD（命令口径固定，逐字可复跑）

- [ ] 零干扰三件：① `grep -cE 'Timer\.scheduledTimer|AXObserverCreate|CGEventTapCreate|CGEvent\.tapCreate' Sources/*.swift` = 0；② `./scripts/idle-cpu-sample.sh <pid>`（30 次 / 5 分钟）均值 < 0.5%，落 `out/idle-cpu.txt`；③ 打中文 60 秒录屏（候选框不闪断）
- [ ] 出建议：Mail 含 3 处语法错的英文 → 菜单栏触发 → 卡片给出 原句/建议/原因，逐条修掉那 3 处
- [ ] 写回：点应用文本正确替换；菜单栏「撤销上次替换」实测还原（`⌘Z` 只记录）
- [ ] 语言门控：选中中文触发 → 不弹卡片、请求计数 = 0（设置页诊断截图）
- [ ] 无选区/空选区：不崩、提示「先选中要检查的文字」
- [ ] 术语硬闸：`./selftest --glossary` 跑 `fixtures/glossary.json` 22 条 → 全绿；`./selftest --live` 打真接口 → 术语被触碰 0 条
- [ ] 设置即时生效：改 base URL / model 后下一请求即用新值（诊断打印实际 endpoint + model）
- [ ] 失败态三条：`./selftest --faults` 注入 非200 / 解析失败 / 超时 → 三条专属文案

## 验收方式

爹地两分钟：英文邮件（3 处错）→ 选中 → 菜单栏触发 → 看卡片 → 应用 → 看文本；中文段触发一次（应完全无反应）；打中文 60 秒确认不卡。
**需爹地动手一次**：系统设置 → 隐私与安全性 → 辅助功能 → 勾 `英文写作助手`（授最终产物；axfocus 的授权不继承）。

## 依赖

- AX：授 `/Applications/Selfmade/英文写作助手.app`（`com.wanyi.englishwriter`，用 `SOALedger Dev` 稳定证书签名 → 重编译不丢授权，只打扰爹地一次）
- LLM：爹地设置面板手填三项（独立 App 读不到 Hermes 凭据池）

## 审批记录

**知澜 2026-11-12 16:10 复审一：退回改，未通过。** Q1=改（v0.1 只做菜单栏入口，热键延 v0.1.1 可配）、Q2=同意（不做行内下划线）。必改 5 项：入口实现 / LLM 契约 / DoD 可判定化 + 补语言门控·无选区·术语夹具 / 依赖两条口径 / 前置探针 30 分钟。

**知澜 2026-11-12 16:20 复审二：退回 + delta（4 条，改完直接开干，不用再提审）。**
- D1 顺序错：探针不等完整 App，先出「探针壳」并装到最终路径，再挂 blocked 让他授权（否则他点空）。
- D2 探针第 3 项不占第二次打扰：剪贴板路径不需要 AX，跟授权后那 30 秒顺手做完。
- D3 术语闸两个真 bug（已修，见 `Sources/Engine.swift`）：① 两侧 lowercased 再比 → `FCL→fcl` 判 pass；② 「无改动」用 lower 比较 → `i→I`、`china→China` 被当没改动丢掉。
- D4 PROJECT.md 不在盘 / 命令口径不统一 / 空闲采样脚本固定路径 / 提审前推私有远端。

## 交付证据（本轮）

- 构建：`./scripts/build.sh` → `Identifier=com.wanyi.englishwriter`、`Authority=SOALedger Dev`
- `./selftest --cjk --glossary`：PASS 32 / FAIL 0（22 条术语夹具，含 D3 两个回归用例 g15/g16/g19/g20）
- `./selftest --faults`：PASS 7 / FAIL 0（含真实本地服务的 500 映射与真超时映射）
- `./selftest --live`（deepseek-chat）：22/22 条给出真实改动，**术语被触碰 0 条**
- 纪律 grep：Timer/AXObserver/CGEventTap API 命中 0
- 空闲 CPU：见 `out/idle-cpu.txt`

## 下一步（等爹地授权后）

1. 爹地点「跑探针」→ 结果落 JSON → 我据此定「写回」还是「建议+复制」降级
2. Mail 端到端：出建议 / 写回 / 撤销 / 语言门控 / 无选区
3. 60 秒打中文录屏 + 提交验收
