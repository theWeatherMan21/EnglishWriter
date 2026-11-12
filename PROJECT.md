# 英文写作助手（EnglishWriter）· PROJECT.md

> 卡号 t_b02227ec · 本文件第一节 = 卡面 v2 全文（与看板评论 297 逐字同文），其余为交付证据与审批记录。
> 北极星：写英文时中文输入零干扰、航运术语零误报、不卡；需要改的时候点一下就出建议。

---

> 口径：本节 = 卡面 v2 全文（与看板评论 297 逐字同文）。工人上下文 `hermes kanban edit` 被内核拒，卡面正文字段待主线改；验收以本节为准。

---

### 北极星
在 Mail / Word / Slack 里写英文时：中文输入零干扰、航运术语零误报、不卡；需要改的时候点一下就出建议。

### 背景（Grammarly v1.209.0 符号级勘察实证）
引擎在服务端（客户端只有 23 个 `AlertPname` 标签）→ 能力复刻不了；**无语言检测**；文本替换走 pasteboard 补丁管道 + 串行锁（`"Another Pasteboard action is in progress..."`）→ Mail 打中文与输入法抢剪贴板 = 卡顿（Blocked apps 止血已交付）。故本 App 第一原则：**不常驻、不轮询、不监听键盘**，只在被触发那一刻读一次 AX。

### v0.1 范围
1. 常驻菜单栏 App（Swift），无 Dock 图标、无主窗口
2. **唯一主入口 = 菜单栏菜单项「改选中文本」**；全局热键延到 v0.1.1（可配、默认避开系统组合）
   - 面板用 `NSPanel(.nonactivatingPanel, .borderless)` + `becomesKeyOnlyIfNeeded`，保证 Mail 仍持前台
   - 选区预取：`NSWorkspace.didActivateApplicationNotification` 记「最后一个非本 App 的前台 pid」，触发时对那个 pid 读 `kAXFocusedUIElement`（**不装 AXObserver、不起 Timer**）
3. 焦点/选区读取复用 `axprobe/axfocus.swift` 的 AX 层（4 个坑的解法）
4. **语言门控**：选中文本 CJK 码点占比 > 40% → 直接返回，不取全文、不发请求（请求计数 = 0）
5. 卡片：原句 / 建议 / 一句原因
6. 点「应用」→ 替换选中文本（先试 `AXSelectedText` settable 写入，不可写退 pasteboard ⌘V）
7. **撤销兜底**：替换前存原文快照 + pid + range，菜单栏「撤销上次替换」一键还原。`⌘Z` 只记录、不作判据
8. 设置：base URL / API key / model **三项全手填、零预设默认值**，存 UserDefaults，下次请求即用新值

### LLM 契约（钉死）
- 一次一条整段重写，非逐条 diff
- 输出 `{"original":"…","suggestion":"…","reason":"<一句中文>"}`
- 输入 > 2000 字符 → 拒绝、不发请求、提示「选中太长（N>2000），请分段」
- 超时 15s
- 三失败态各一行文案：非200 = `接口返回 HTTP <code>：<body 前120字>`；解析失败 = `模型没按 JSON 回，原文未改动`；网络断 = `15 秒没回话，检查网络或 base URL`
- `POST {base}/chat/completions`，`Bearer <key>`，`temperature=0`

### 术语硬闸（代码拦截，非提示词叮嘱）
- 词表：FCL LCL BL B/L ETD ETA ATA ATD SO SI VGM CY CFS THC POD POL HBL MBL D/O C/O IMO HS DG TEU FEU DAP CIF FOB CFR（实现另含 DDP EXW MSDS PO PI CI PL）
- **（D3 修正版，覆盖原「忽略大小写」口径）** 术语 token 按**原样形态（含大小写）**比对，任一处变化即丢：`FCL→fcl`、`ETD→Etd`、`SO→S/O` 全丢
- **（D3 修正版）** 「无改动」判定 = `collapseWhitespace(original) == collapseWhitespace(suggestion)`（大小写敏感）；`i→I`、`china→China` 属正常修正，必须放行
- 短词（≤2 字符，如 SO/PO）只在非全小写形态下算术语，避免把普通词 `so` 当术语

### 不做
全局热键（v0.1.1）· 行内下划线（原生渲染层改不了）· 自动扫描（= 把干扰源请回来）· 中文语法检查 · 改 Grammarly 本体

### 前置探针（开工第一步 30 分钟，结果写进卡）
1. Mail 正文区 `AXSelectedText` 可读？settable？
2. `nonactivatingPanel` 打开时 Mail 仍持前台、选区仍可读？
3. 只能走 pasteboard 时，单次使用输入法候选框是否不闪断（录屏）
**Mail 写入不可行 → 退「建议 + 一键复制」，改卡后按降级版继续（仍满足北极星）**

### DoD（每条可判定）
- [ ] 零干扰三件：① `grep -nE 'Timer|AXObserverCreate|CGEventTapCreate' Sources/*.swift` 命中 0；② 空闲 5 分钟 `ps -o %cpu=` 每 10s 采 30 次均值 < 0.5%；③ 打中文 60 秒录屏（候选框不闪断）
- [ ] 出建议：Mail 含 3 处语法错的英文 → 触发 → 卡片给出 原句/建议/原因，逐条修掉那 3 处
- [ ] 写回：点应用文本正确替换；菜单栏「撤销上次替换」实测还原（⌘Z 只记录）
- [ ] 语言门控：选中中文触发 → 不弹卡片、请求计数 = 0（诊断面板截图）
- [ ] 无选区/空选区：不崩、提示「先选中要检查的文字」
- [ ] 术语硬闸：`./selftest --glossary` 跑 `fixtures/glossary.json` ≥20 条 → 零条建议触碰术语 token；`--live` 打真接口同样零命中
- [ ] 设置即时生效：改 base URL / model 后下一请求即用新值（诊断日志打印实际 endpoint + model）
- [ ] 失败态三条：`./selftest --faults` 注入 非200/解析失败/超时 → 三条专属文案

### 验收方式
爹地两分钟：英文邮件（3 处错）→ 选中 → 菜单栏触发 → 看卡片 → 应用 → 看文本；中文段触发一次（应完全无反应）；打中文 60 秒确认不卡。
**需爹地动手一次**：系统设置 → 隐私与安全性 → 辅助功能 → 勾 `英文写作助手`（授最终产物，axfocus 授权不继承；App 内有按钮直达该面板）。

### 依赖
- AX：授最终产物 `/Applications/Selfmade/英文写作助手.app`（`com.wanyi.englishwriter`，用本机 `SOALedger Dev` 稳定证书签名 → 重编译不丢授权）
- LLM：爹地设置面板手填三项（独立 App 读不到 Hermes 凭据池，「凭据在池里」此条已删）


---

## 交付证据（2026-11-12 实测，逐条可复跑）

| 项 | 命令 | 结果 |
|---|---|---|
| 语言门控 + 术语硬闸 | `./selftest --cjk --glossary` | PASS 32 / FAIL 0（术语夹具 22 条，含 D3 回归 g15/g16/g19/g20） |
| 失败态三条 | `./selftest --faults` | PASS 7 / FAIL 0（真实本地服务：HTTP 500 映射 + 真超时映射） |
| 真接口 | `./selftest --live`（deepseek-chat） | 22 条有改动 22、未改动 0、**术语被触碰 0** |
| 零干扰纪律 | `grep -cE 'Timer\.scheduledTimer|AXObserverCreate|CGEventTapCreate|CGEvent\.tapCreate' Sources/*.swift` | 0 |
| 空闲 CPU | `./scripts/idle-cpu-sample.sh <pid>` | pid=9940（装机版二进制）30 次 / 5 分钟，**均值 0.000%** |
| 装机 | `ditto build/英文写作助手.app /Applications/Selfmade/` | `codesign --verify --strict` OK；`Identifier=com.wanyi.englishwriter`、`Authority=SOALedger Dev` |
| 签名稳定性 | `codesign -d -r-` | `designated => identifier "com.wanyi.englishwriter" and certificate leaf = H"3b9839fd…84"` |
| 无头探针 | `EW_PROBE_EXIT=1 英文写作助手` | 实跑 `exit=3`（未授权），JSON 落 `~/Library/Application Support/EnglishWriter/probe-result.json` |
| 私有仓 | — | https://github.com/theWeatherMan21/EnglishWriter （private），远端 HEAD `0059a32` |

## 审批记录

- **2026-11-12 16:10 知澜复审一：退回改。** Q1=改（v0.1 只做菜单栏入口，热键延 v0.1.1 可配）、Q2=同意（不做行内下划线）。必改 5 项：入口实现 / LLM 契约 / DoD 可判定化+补语言门控·无选区·术语夹具 / 依赖两条口径 / 前置探针 30 分钟。
- **2026-11-12 16:20 知澜复审二：退回 + delta 4 条，改完直接开干不必再提审。** D1 先出探针壳并装最终路径（授权对象必须真实存在）；D2 探针第 3 项走剪贴板、不占第二次打扰；D3 术语闸两个真 bug（大小写）；D4 PROJECT.md 在盘 / 命令口径 / 采样脚本路径 / 推私有远端。
- **2026-11-12 16:44 探针壳核验通过**（知澜逐项核：.app 在盘、bundle id、签名要求、菜单项、EW_PROBE_EXIT 分支、JSON、三组 selftest、夹具 expect、pgrep -x、HEAD=remote、private）。

## 下一步（等爹地授权后）

1. 爹地点「跑探针」→ 结果落 probe-result.json → 我据此定「AX 写回」还是「建议 + 一键复制」降级版
2. Mail 端到端：出建议 / 写回 / 撤销上次替换 / 语言门控 / 无选区
3. 60 秒打中文录屏 + 爹地两分钟验收

