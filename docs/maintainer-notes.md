# 维护者笔记（不是给用户看的）

真机验收、探针、踩过的坑。用户文档见 [README](../README.md)。

## 真机验收工具（不需要截屏）

```bash
# A 层：AXValue 直写正文 → checkNow → 读 overlay.specs（不激活/不新建窗口/不敲键/不截屏）
open -a build/英文写作助手.app --args --axcheck out/

# B 层：只监听，真人在 TextEdit 里敲，看 AXObserver 与去抖是否触发
open -a build/英文写作助手.app --args --axwatch out/ --seconds 120
```

结果落 `out/axcheck-status.json` / `out/axwatch-status.json`。`--realshot`（CGEvent 敲键那套）
在 `textSet=false` 时以退出码 9 收尾并标注「无效验收」——文本没进输入框时，零下划线不算结论。

## 被动观察（真机取证，不上屏）

```bash
open -a 英文写作助手.app --args --passive $PWD/qa/evidence/passive.jsonl --seconds 600
```

只读：不写宿主、不敲键、不截屏、不 activate 任何 App、下划线全程不上屏、不弹卡片、不建窗口；
日志只记元信息（ts / pid / app / role / textLen / 句长 / 命中数 / rects / 耗时 / 错误），**正文一个字都不落盘**。

仪器本身也要能自证：

```bash
bash scripts/passive-selfcheck.sh
# PASS 正控·写回计数器是活的 / 只读·写回计数为 0 / 只读·窗口上屏计数为 0 / 日志·七字段齐全
```

## 手动核对（两分钟）

`docs/manual-check.md`。只有两件事必须真人做：在原生 App 里真敲英文看划线、在 Mail 里真敲英文看划线。
其余全部可自动化复跑（`scripts/ext-real-probe.sh`、`scripts/ext-logic-probe.sh`、`scripts/ci-test.sh`、`scripts/release.sh`）。

## 踩过的坑（别再踩第二次）

- **Mail 的 bundle id 是小写 `com.apple.mail`**。按 `com.apple.Mail` 找进程会一直找不到。
- **探针模式必须在 stdout 上 `setvbuf(...,_IONBF,0)` 并跑完 `exit()`**：管道里 stdout 是块缓冲，
  进程不退出日志全丢，看起来像「探针没跑」。
- **Mail 窗口的 `AXWebArea` 是整个文档**（含列表几千行），屏幕外块的 `AXBoundsForRange`
  返回滚动空间坐标（y 上千），按全文档扫会误判「矩形越界」→ 必须按窗口 bounds 只查可见块。
- **命中 0 要能区分三种原因**：可见文本是中文（按设计跳过）/ 英文但本身无误 / 链路坏了。
  探针分开输出中文块数、英文字数、命中数，别用一个 0 糊过去。
- **系统拼写词典可能不存在**：`NSSpellChecker.checkSpelling` 在词典未就绪时对任何词都返回
  `NSNotFound`（语义 = 「这个词是对的」）。不探测就会让整条拼写通道静默变成 0 命中，
  CI runner / 干净系统上就是这样。`SpellCheck.dictionaryUsable(language:)` 用「正确词不报 +
  乱码必报」两条判据探测；自测在不可用时标 SKIP 而不是 PASS。
- **常驻检查日志**：`~/Library/Application Support/EnglishWriter/check-log.jsonl`
  每次 attach / skip-cjk / no-text / check / render 落一行（app、role、文本长度、命中数、矩形数、耗时、错误）。
  用户报「打了没反应」时先读它——能看出是没挂上元素、读到 0 字、还是中文被跳过。单文件超 5MB 轮转。

## 排障：App 看起来「卡住、点什么都没反应」

第一件事不是猜，是**枚举它的 AX 窗口**：

```
osascript -e 'tell application "System Events" to tell process "英文写作助手" to get {name, count of windows}'
```

- 正常：0 个窗口（菜单栏常驻 App，不开窗时就是 0），或 1 个「试用」窗口
- **异常：只剩 `AXSystemDialog`、没有 `AXWindow`** → 主窗口已被系统对话框吞掉或已销毁，
  浮动球还在飘但所有点击都落空。修不如重启：`kill` 后重新 `open -a`。
- 读不到任何窗口且 `pgrep` 为空 → 进程已退，重启即可。

判断「点了没反应」的顺序：

1. `pgrep -f "Selfmade/英文写作助手"` —— 进程在不在
2. AX 窗口枚举 —— 主窗口还在不在
3. `tail check-log.jsonl` —— 有没有 `demo-check` / `click-hit` / `click-miss`，
   以及 miss 的 `rectCount` 是 0（本来没有线）还是 >0（坐标换算问题）

## 发版

```bash
bash scripts/release.sh 0.3.0     # 自测 → 重编（版本号进 Info.plist）→ zip + sha256
git tag v0.3.0 && git push origin v0.3.0   # tag 触发 .github/workflows/release.yml
```

CI 的 Release 产物用 ad-hoc 签名（runner 上没有本机证书）。用固定证书自编的本地包
`SIGN_ID="SOALedger Dev"`，重编译不丢 TCC 授权；两者差异见 README「签名」一节。

## 探针必须用**装机版**二进制跑（TCC 只授权给那一个路径）

`./build/英文写作助手 --probe-mail` 读 Mail 会得到「窗口=0」，而装机版同样命令得到「窗口=2」。
原因不是代码：辅助功能（TCC）授权是按**二进制路径**给的，只有 `/Applications/Selfmade/英文写作助手.app` 那份被授权过。
`build/` 下重新编译出来的产物是另一个路径 → 无权限 → AX 窗口数恒为 0。

判据：探针输出第一行若是 `窗口=0` 而 System Events 报 N>0，先换装机版二进制重跑，别改代码。

正确用法：
```sh
"/Applications/Selfmade/英文写作助手.app/Contents/MacOS/英文写作助手" --probe-mail --all-visible --out qa/evidence/mail-probe.json
```

## AX 读不到别家窗口时，先看「屏幕是不是黑的」

11-19 18:4x 实测：TextEdit 有 2 个文档、Mail 有窗口，但 `AXWindows` 里塞的是 **AXApplication 占位元素**
（role=AXApplication、children 全是菜单栏），`AXWindows = 0` 也出现过；同一台机器 17:2x 还能正常读到
`staticText=16000 / blocks=410`。`AXIsProcessTrusted = true`，权限没问题。

规律：**屏幕休眠/锁屏/长时间无交互后，其他 App 的 AX 树会退化成骨架**。
所以：

- 看到 `AXWindows` 全是 AXApplication、或 `窗口数=0`，先敲一下键/动鼠标让屏幕醒，再重跑探针
- 别在这一刻改选择逻辑——代码是好的，是系统没给数据
- `--axcheck --spawn` / `--axaccept --spawn` 失败时，先看这条再怀疑代码

## 浏览器检查的延迟：2.8–7.5 秒（模型侧波动），不是前端 bug

`/v1/check` 走模型时单句 2.6–6.6s，同一条文本连测会看到 2.8s 与 7.5s 两个数——
波动在模型这一侧，本地接口（mode:"local"）始终 ~40ms。

试过「先本地即时再模型覆盖」两段式：服务端 `mode:"local"` 正常（curl 39ms 返回），
但扩展里快速段没有生效（首条线仍在 ~2.8s 才出现），已回退成一次完整请求，
代码里留了注释。要做渐进式渲染，需要先解决「内容脚本里那次 fetch 为什么没画」。

### 已解：扩展两段式检查为什么一开始不生效

试过在 `runCheck` 里先发 `{mode:"local"}`（服务端 39ms 返回本地结果），再发完整请求覆盖。
实测：**快速段既没有画出线，也没有在 `__EW_DEBUG.notes` 里留下 'fast status=' 记录**，
说明那次 await 根本没执行到 —— 而 `notes` 里有 'no token' / 'token updated'，
证明内容脚本本身在跑、token 也拿到了。

所以下一步不是换方案，而是在 `runCheck` 每个 early-return 前打 note（text 长度、scope、
token 状态），定位它到底从哪一行返回的。查清之前不要把两段式再加回去。

**结论（11-19 深夜实测）**：原因不是 fetch 不通，而是 `runCheck` 里所有早退分支都没有留痕，
导致「看着像没执行」。真正的修法两条：

1. 在 `__EW_DEBUG.notes` 里给关键节点打时间戳，确认 `fast t=… n=…` 在 run 开始后 ~35ms 就返回
2. 顺手加了「同一时刻只跑一个检查」+「过期结果丢弃」（`runSeq`）：
   打字期间连续触发会把模型请求排队，最后一个结果才画，体感像 8–12 秒

实测：`fast` 段在 run 开始后 35ms 就拿到本地结果并画线；模型结果 2.7s 后覆盖。

## 无头测试里的「出线慢」大多是后台定时器节流

`--headless=new` 的页面会被 Chrome 当后台页，`setTimeout` 被钳到 1000ms，
于是「停笔 150ms 出线」在测试里量出来是 600–1260ms。同一份代码在真前台标签页是 237ms 中位。

`scripts/chrome-testing-up.sh` 已加：
`--disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows`

判据：量「停笔→出线」必须带这三个 flag，否则测的是节流不是代码。

## 永远不要让模型算 offset（11-19，用一轮 rewrite 的血换来的）

改写功能最初让模型返回 `{"start","length","original","replacement"}`。实测 3 轮里 1 轮出现
`provideus`、`usus` 这种碎片：模型的 start/length 边界经常错 1–2 个字符，
而且它自己看不出错。表象是「双空格」「重复词」，实际全是 span 错位的副作用。

正解：**让模型只给结果，位置本地算。**
- 提示词只要 `{"label","note","text"}`，text = 改写后的完整段落
- 本地用 `WordDiff`（词级 LCS）把整句反推成逐条 edit
- 原文字串由本地切词产生，天然合法，不可能越界或拼出碎片

同一原则适用于任何「模型指出位置」的场景（diff 建议、标注、高亮、截图定位）。
附带两个坑：
1. `WordDiff` 的纯插入（advise us the → advise us of the）如果产出 `length = 0` 的 edit，
   会被下游 sanitize 丢掉，往返后等于原文。改成「把下一个原词替换成 新词+原词」。
   守住它的断言：`--rewrite-selftest` 的 `worddiff: 往返一致`。
2. 验收脚本要能自己读设置（`SettingsStore.load()` 回落），不要逼人事先拼三个 env 变量。

## 验收账本：哪些能离屏证明，哪些只能真机（11-19 夜，解锁后照这张表点）

一句话：**离屏能证的都证了；剩下两条必须有人在真 App 里点几下，脚本替代不了。**

### A. 离屏可证（`bash scripts/ci-test.sh` 一条命令，EXIT=0 才算过）

| 能力 | 命令 | 现有断言 |
|---|---|---|
| 门控 / 护栏 / diff 契约 / M3 卡片 | `--selftest --m3 --settings` | 45 |
| 本地规则清晰度/风格 + 语法兜底 | `--selftest --style` | 64 |
| Mail 块路径（离屏同构） | `--mail-selftest` | 6 |
| WebView 侧栏 / 卡片 UI | `--webui` | 16 |
| 隐私 / 锁屏门控 / attach 发射点 | `--privacy` | 74 |
| 改写纯函数（含 WordDiff 往返 / 越界 span） | `--rewrite-selftest` | 9 |
| 接受→撤销→词典（含原生读回不符判失败） | `--acceptflow` | 11 |
| 点击几何（dy/dx/最近一条/空表） | `--clickdiag` | 7 |
| 业务英文质量 | `--quality --deep` | 召回 100%（10/10）、正确句零误报 8 句 |
| 真模型改写 5 句 × 3 轮 | `EW_WITH_LIVE=1` + `--live-rewrite` | 5/5 · 5/5 · ~4.2s |
| 视觉基线（改 CSS 必看） | `--pngdiff` vs `qa/baseline/` | 阈值 0.1%，超了留差异图 |
| 浏览器扩展端到端 | `scripts/ci-ext.sh`（headless） | 点线弹卡 / 键盘 / contenteditable |

### B. 只有真机能证（锁屏期间一律不算证据）

1. **原生行内下划线 + 点线弹卡**：`check-log.jsonl` 里要看到 `click-hit`。
   判据：`grep -c click-hit` 增长，且那条日志 `owner=<App>(pid)` 与前台一致。
2. **Mail 写信窗写回**：接受后正文真的变了、撤销回原文。
   判据：`render ... itemCount>0 && rectCount>0` 出现在 `[compose]` 窗口记录里。

### C. 解锁后的三步验收（爹地自己点，30 秒）

1. 打开 TextEdit 写一句 `We was late because there is many problems with the booking.`
   → 应出现下划线；点线 → 弹出卡片 → 点「接受」→ 句子变 `We were late…`
2. Mail 新建邮件，粘同一句 → 同样出线、接受后正文变化
3. 切到 Safari 里任意英文输入框（扩展）→ 出线、点线弹卡
   三条都顺 = 真机闭环成立；任一条没反应，把 `~/Library/Application Support/EnglishWriter/check-log.jsonl` 最后 50 行发我，日志里 `owner/front/nearest/path` 会直接指向原因。

### D. 已知不做（不是缺口）

- Chrome 商店安装路径：还没打算发布，等真要上架再验。
- 锁屏期间的点击/写回样本：环境限制，不计入质量结论。
