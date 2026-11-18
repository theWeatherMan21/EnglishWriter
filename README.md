# EnglishWriter · 英文写作助手

A Grammarly-style, **local-first** writing assistant for macOS. It lives in the menu bar,
watches the text field you are typing in, underlines mistakes inline, and offers a hover
card to accept / ignore / undo. The only deliberate difference from Grammarly: **this is open
source (MIT)** and your text does not leave the machine unless you configure a model endpoint
yourself.

一个 Grammarly 同款的开源 macOS 写作助手：常驻菜单栏、边写边查、错误处画线、悬停卡片一键
改。默认全程本地（LanguageTool 本地引擎），不配置模型接口就不出网。

---

## 状态（诚实版，别当宣传）

| 里程碑 | 状态 | 证据 |
|---|---|---|
| M1 行内下划线渲染 | 已交付（真机待复核） | `--demo-selfcheck` PASS，5 处错误 → 5 个矩形；`out/m1-snapshot.png` |
| M2 输入即检查（AXObserver + 800ms 去抖） | 代码就绪（真机待复核） | `--selftest --lt` PASS 56/0；真机需靶子窗口 |
| M3 悬停卡片 + 接受/撤销/忽略/词典 | 已交付（真机待复核） | `--selftest --m3` PASS 60/0；`out/m3-card.png` |
| M4 设置面板（三件套 / 引擎地址 / 方言 / App 排除 / 词典） | 已交付（UI 点击留给人验） | `bash scripts/settings-selftest.sh` PASS；证据 `qa/evidence/settings-selftest.json` |
| M4 设置 / 文档 / 开源骨架 | 已交付 | LICENSE、README、CI、`out/parity.md` |
| 浏览器扩展（Chromium） | **已验证**（headless 真扩展） | `bash scripts/ext-real-probe.sh` PASS；textarea 与 contenteditable 各 3 条命中 / 3 个矩形，接受与撤销读回一致；证据 `qa/evidence/ext-real-probe.json` |
| 真机（TextEdit / Mail / Chromium） | TextEdit **已验**；Mail 待真人打字 | 见 `out/parity.md`；Mail 用 `--passive` 被动取证（不上屏） |

**别看表格就当能用**：离线自测全绿；真机上的“边打字边出现下划线”这一步还没拿到证据。

## 要求

- macOS 13+
- Xcode Command Line Tools（`swiftc` 编译，无需 Xcode 工程）
- 可选：本地 [LanguageTool](https://languagetool.org/)（`scripts/languagetool-up.sh` 会自动拉起）
- 辅助功能授权（System Settings → Privacy & Security → Accessibility）

## 构建

```bash
bash scripts/build.sh                 # 产物 build/英文写作助手.app
open build/英文写作助手.app            # 常驻菜单栏；首次需授辅助功能权限
```

默认用本机证书 `SOALedger Dev` 签名（重编译不丢 TCC 授权）。换证书：
`SIGN_ID="Apple Development: …" bash scripts/build.sh`。

## 安装

```bash
bash scripts/build.sh                                   # 产出 build/英文写作助手.app
mkdir -p /Applications/Selfmade
cp -R build/英文写作助手.app /Applications/Selfmade/
open /Applications/Selfmade/英文写作助手.app            # 菜单栏出现铅笔图标，无 Dock 图标、无主窗口
```

首次运行只需要做一件事：**系统设置 → 隐私与安全性 → 辅助功能 → 勾上「英文写作助手」**。
TCC 不允许程序代勾；勾完 App 会自行重连（不用重装）。用同一个证书重编译不会丢这条授权；
换证书或改 bundle id 就必须重新勾。

升级：覆盖 `/Applications/Selfmade/英文写作助手.app` 后重开即可，设置在
`~/Library/Preferences/com.wanyi.englishwriter.plist`，不随 App 覆盖丢失。

## 填模型接口三件套（可选，默认不联网）

菜单栏铅笔图标 → **设置…** → 「模型接口」三格，全部手填，**没有任何预设默认值**：

| 字段 | 填什么 | 例子 |
|---|---|---|
| Base URL | OpenAI 兼容的 `/v1` 根地址 | `https://api.example.com/v1` |
| API Key | 只存本机 UserDefaults | `sk-…` |
| Model | 请求体里的 `model` 字段 | `gpt-4o-mini` |

保存即生效（输入时就地保存）。校验落库：

```bash
defaults read com.wanyi.englishwriter llm.baseURL
defaults read com.wanyi.englishwriter llm.model
```

同一面板里还能改：**引擎地址**（LanguageTool，留空=本机 `127.0.0.1:8081`）、**方言**
（en-GB / en-US / en-AU / en-CA / en-NZ，决定拼写口径）、**App 排除**（填 bundle id 或应用名，
命中的 App 一个请求都不发）、**个人词典**（加进去的词一律不报）。

不填三件套也能用：本地 LanguageTool 在线时永远优先走它，文本不出本机。

## 本地 LanguageTool 启动

```bash
bash scripts/languagetool-up.sh          # 幂等：已在跑直接返回 0
curl -s http://127.0.0.1:8081/v2/languages | head -c 200   # 应返回 JSON 语言列表
```

- App 每次启动会静默调一次这个脚本；没装就安静回落到上面填的模型接口（不弹窗、不报错）。
- 安装目录口径：`~/Library/Application Support/EnglishWriter/lt/`
  （`jdk-*/Contents/Home/bin/java` + `LanguageTool-*/languagetool-server.jar`），日志 `lt/lt.log`。
- 换端口：`EW_LT_PORT=8082 bash scripts/languagetool-up.sh`，同时把设置面板里的「引擎地址」
  改成 `http://127.0.0.1:8082`。
- 内存默认 `-Xmx1g`；句子级请求，热态 15–30ms。

## 自测

```bash
./build/英文写作助手 --selftest --lt      # 门控 / 护栏 / diff 契约 / 本地引擎
./build/英文写作助手 --selftest --m3      # 接受 / 撤销 / 忽略 / 词典 / 合并去重 / 卡片离线渲染
./build/英文写作助手 --selftest --settings # 设置持久化（defaults 冷读）/ 词典过滤 / App 排除
./build/英文写作助手 --demo-selfcheck     # 行内几何断言（真 NSTextView + AX 交叉校验）
bash scripts/ci-test.sh                  # CI 用的那套（不依赖本地引擎）
bash scripts/settings-selftest.sh         # 设置面板验收 → qa/evidence/settings-selftest.json
bash scripts/passive-selfcheck.sh         # --passive 仪器自证（零写回/零上屏/日志七字段）
bash scripts/ext-real-probe.sh            # 真扩展端到端（headless，含 contenteditable 矩形）
```

## 真机验收工具（不需要截屏）

```bash
# A 层：AXValue 直写正文 → checkNow → 读 overlay.specs（不激活/不新建窗口/不敲键/不截屏）
open -a build/英文写作助手.app --args --axcheck out/

# B 层：只监听，真人在 TextEdit 里敲，看 AXObserver 与去抖是否触发
open -a build/英文写作助手.app --args --axwatch out/ --seconds 120
```

结果落 `out/axcheck-status.json` / `out/axwatch-status.json`。`--realshot`（CGEvent 敲键那套）
在 `textSet=false` 时以退出码 9 收尾并标注「无效验收」——文本没进输入框时，零下划线不算结论。

## 它是怎么工作的

1. **输入感知**（`Sources/Inline.swift`）：每个进程一个 `AXObserver`，监听焦点元素变化与文本变化，
   800ms 去抖，只检查光标所在句，同句 hash 去重。
2. **引擎**（`Sources/LocalEngine.swift` / `Sources/Diff.swift`）：本地 LanguageTool 优先（毫秒级、不出网），
   否则走用户自填的 OpenAI 兼容接口，出口统一成 `[DiffItem]`（一条错 = 一条 edit）。
3. **护栏**：术语 / 箱号 / 港口码 / 长数字 / 金额 / 邮箱 / 链接 / 签名块内的建议一律丢弃；中文占比 > 0.40 完全不介入。
4. **渲染**（`Sources/Underline.swift`）：`AXBoundsForRange` 取矩形，长 range 拆分按行取并集，
   透明非激活浮层只画线不收事件。颜色 × 形状双编码（色盲友好）。
5. **合并去重**（`DiffSanitize.consolidate`）：同段重复只留一条；重叠按 拼写 > 语法 > 清晰度 > 风格 收敛；
   输出恒升序、两两不重叠。

## 延迟与能力边界（别抱错期望）

| 通道 | 实测延迟 | 能干什么 |
|---|---|---|
| 拼写（系统词典，常开） | ~16ms | 实时划线 |
| 本地规则（清晰度/风格） | <5ms | 实时划线 |
| LanguageTool 语法（可选，默认关） | 20–60ms 热态 / 1.8s 冷启 | 实时划线 |
| 模型逐条 diff | 5.5–44s（按句长/模型波动） | 近实时划线不成立，作辅助 |
| 模型改写 / 语气 | 5–25s（按模型波动） | 选中段落手动触发 |

改写慢不是实现问题，是模型（deepseek-flash / v4-pro 都带推理链）。要更快就换非推理模型。

## 接模型接口的坑（必须知道）

- **opencode.ai/zen 端点必须带 `x-opencode-session` 头**（任意稳定字符串）。不带直接 `MissingSessionID`，
  一个模型都调不到。本项目会自动生成并存一个 `ew-<uuid>` 到 UserDefaults 后自动带上。
- `thinking:{"type":"disabled"}` 该端点**不认**，会回 `invalid_request_error`；要关推理用 `reasoning_effort:"none"`。
- 测过的模型里 `deepseek-v4.1-flash` 是当前验收基线；换模型必须重跑 A/B，不许搬数
  `deepseek-flash` 同条件 2.3–2.5s（更快但长句改写质量略粗）；`deepseek-v4-pro` 46.5s（别用）。

## 隐私

- 默认只用本机 LanguageTool：文本不出本机。
- 只有你自己在设置里填了模型接口（baseURL / key / model）才会把**当前句**发给那个接口。
- 不发遥测、不记账。

## 许可

MIT，见 [LICENSE](LICENSE)。

## 浏览器扩展（Chrome / Edge）

Grammarly 在浏览器里走扩展而不是辅助功能接口；本项目的 Chrome 支持同样是一个 MV3 扩展，
见 [`extension/README.md`](extension/README.md)。它通过本机 `http://127.0.0.1:17817` 调 App 的检查接口
（token 鉴权、只绑回环），取文本与矩形全部走 DOM，接受/撤销直接改 DOM。

## 被动观察（真机取证，不上屏）

```bash
open -a 英文写作助手.app --args --passive ~/dev/EnglishWriter/qa/evidence/passive.jsonl --seconds 600
```

只读：不写宿主、不敲键、不截屏、不 activate 任何 App、下划线全程不上屏、不弹卡片、不建窗口；日志只记元信息
（ts / pid / app / role / textLen / 句长 / 命中数 / rects / 耗时 / 错误），**正文一个字都不落盘**。
用来在 Mail / Notes 这类真实宿主里取证「真人打字会不会触发」。

仪器本身也要能自证（免得「我说我没写」）：

```bash
bash scripts/passive-selfcheck.sh
# PASS 正控·写回计数器是活的 / 只读·写回计数为 0 / 只读·窗口上屏计数为 0 / 日志·七字段齐全
# 证据：qa/evidence/passive-selfcheck.json
```

## 手动核对（两分钟，补最后两条真人证据）

`docs/manual-check.md`。只有两件事必须真人做：在原生 App 里真敲英文看划线、在 Mail 里真敲英文看划线。
其余全部可自动化复跑（`scripts/ext-real-probe.sh`、`scripts/ext-logic-probe.sh`、`scripts/ci-test.sh`、`scripts/release.sh`）。
