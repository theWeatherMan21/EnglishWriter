# EnglishWriter · 英文写作助手

> Grammarly 的开源替代，跑在 macOS 本机：常驻菜单栏，你在任意 App 里打英文，它在错处直接画线，鼠标停一下弹卡片，一键改掉。默认全程本地，不填任何接口就不出网。

[![CI](https://github.com/theWeatherMan21/EnglishWriter/actions/workflows/ci.yml/badge.svg)](https://github.com/theWeatherMan21/EnglishWriter/actions/workflows/ci.yml)

**English**: A Grammarly-style, local-first writing assistant for macOS. Inline underlines in any app, hover card to accept / ignore / undo, powered by a local LanguageTool (or any OpenAI-compatible endpoint you configure yourself). MIT licensed, no telemetry, no bundled keys.

---

## 能力（对齐 Grammarly 的八条）

| # | 能力 | 实现 |
|---|---|---|
| 1 | 常驻后台，任意 App 文本框可用 | 菜单栏常驻（`LSUIElement`，无 Dock 图标），每个进程一个 `AXObserver`；Mail / Notes / Word / Pages / 浏览器等原生文本框都走辅助功能接口 |
| 2 | 行内下划线，分色分形态 | 透明非激活浮层（`ignoresMouseEvents`）压在原文上：拼写波浪、语法实线、清晰度点线、风格虚线，颜色 + 形态双编码（色盲友好） |
| 3 | 输入即检查，不需要点菜单 | 焦点/文本变化 → 800ms 去抖 → 只检查光标所在句，同句 hash 不重复请求 |
| 4 | 悬停下划线 → 卡片 | 全局 `mouseMoved` 监听，停留 200ms 出卡片：类别色标 / 原句 / 建议 / 一句中文理由 |
| 5 | 卡片内一键接受 / 忽略 | 接受只替换该条 range（`applyEdits(only:)`），不动其他文字；忽略分「本次」（内存）与「永久」（落盘规则） |
| 6 | 撤销 | 接受后内存快照出栈还原，菜单另有「撤销上次替换」 |
| 7 | 个人词典 / 忽略规则 | 加进词典的词一律不报；忽略规则按原文匹配；两条引擎通道（本地 / 远端）共用同一套过滤 |
| 8 | 设置面板 | 模型三件套手填（base URL / API key / model，**零预设默认值**）+ 引擎地址 / 方言 / App 排除 |

浏览器里另有一个 MV3 扩展（Chrome / Edge），见 [`extension/README.md`](extension/README.md)：DOM 取文本与矩形，接受/撤销直接改 DOM，检查走本机 App 的 `127.0.0.1:17817` 接口（token 鉴权、只绑回环）。

## 状态（诚实版）

| 里程碑 | 状态 |
|---|---|
| M1 行内下划线渲染 | 已交付：`--demo-selfcheck` PASS（5 处错误 → 5 个矩形，位置断言全过） |
| M2 输入即检查 | 已交付：AXObserver + 800ms 去抖；`--selftest --lt` 在线探活 + 误报护栏全过 |
| M3 卡片 / 接受 / 撤销 / 忽略 / 词典 | 已交付：`--selftest --m3` PASS、`--m3-drive` 离线全链 PASS、`--m3-monitors` 真系统鼠标事件取证 PASS |
| M4 设置面板 / 词典 / App 排除 | 已交付：`--selftest --settings` PASS（含 URLProtocol 打桩证明空配置 0 请求） |
| 浏览器扩展 | 已交付：headless 真扩展端到端（textarea 与 contenteditable 各 3 命中 / 3 矩形） |

所有断言都能在你自己机器上复跑，命令见「自测」一节。CI 跑的是不依赖本地引擎的那批。

## 要求

- macOS 13+
- Xcode Command Line Tools（`swiftc` 编译，不需要 Xcode 工程）
- 可选：本地 [LanguageTool](https://languagetool.org/)（`scripts/languagetool-up.sh` 会自动拉起）
- 辅助功能授权（系统设置 → 隐私与安全性 → 辅助功能）

## 安装（用 Release 里的 .app）

1. 到 [Releases](https://github.com/theWeatherMan21/EnglishWriter/releases) 下载最新的 `EnglishWriter-<版本>-macos.zip`。
2. 解压，把 `英文写作助手.app` 拖进 `/Applications`。
3. 双击打开。**首次会被 Gatekeeper 拦**（本项目没有 Apple 开发者 ID / 公证），在「系统设置 → 隐私与安全性」点「仍要打开」，或先执行
   `xattr -dr com.apple.quarantine /Applications/英文写作助手.app`。
4. 系统设置 → 隐私与安全性 → **辅助功能** → 勾上「英文写作助手」。TCC 不允许程序代勾；勾完 App 自己重连，不用重装。

菜单栏出现铅笔图标就没有主窗口、没有 Dock 图标，这是正常的（常驻 App）。

### 签名与「重编译不丢授权」

| 来源 | 签名 | 后果 |
|---|---|---|
| 你本地 `bash scripts/build.sh` | 默认用你机器上的证书，`SIGN_ID="SOALedger Dev"`（可用 `SIGN_ID="Apple Development: …"` 覆盖） | 同一证书重编译，**TCC 授权不丢**；换证书或改 bundle id 必须重新勾 |
| GitHub Release 产物 | CI 上 ad-hoc 签名（`codesign -s -`），未公证 | 每次构建的签名标识会变，**升级后可能要在辅助功能里重新勾一次** |

想要「重编译不丢授权」就用固定证书自己编译；想要开箱即用就下 Release，升级后补勾一次。

设置存在 `~/Library/Preferences/com.wanyi.englishwriter.plist`，覆盖 App 不会丢。

## 填模型接口（可选，默认不联网）

菜单栏铅笔 → **设置…** → 「模型接口」三格，**全部手填，本项目不含任何内置 key、不含任何预设地址**：

| 字段 | 填什么 | 例子 |
|---|---|---|
| Base URL | OpenAI 兼容的 `/v1` 根地址 | `https://api.example.com/v1` |
| API Key | 只存本机 UserDefaults | `sk-…` |
| Model | 请求体里的 `model` 字段 | `gpt-4o-mini` |

三格任一为空 = 远端通道不启用（`--selftest --settings` 里有 URLProtocol 打桩断言：空配置下 diff / engine / rewrite 三条通道发起 **0** 次网络请求）。

同一面板还能改：**引擎地址**（留空 = `http://127.0.0.1:8081`）、**方言**（en-GB 默认，可选 en-US / en-AU / en-CA / en-NZ，决定拼写口径）、**App 排除**（填 bundle id 或应用名，命中的 App 一个请求都不发）、**个人词典**。

## 本地引擎（LanguageTool）

```bash
bash scripts/languagetool-up.sh          # 幂等：已在跑直接返回 0
curl -s http://127.0.0.1:8081/v2/languages | head -c 120   # 应返回 JSON 语言列表
```

- 端口 `8081`，请求口径 `language=en-GB` + `level=picky`；App 启动后约 **12 秒**引擎就绪，之后热态句子级检查 15–30ms。
- App 每次启动会静默调一次这个脚本；没装就安静回落到你填的模型接口（不弹窗、不报错）。
- 安装目录口径：`~/Library/Application Support/EnglishWriter/lt/`（`jdk-*/Contents/Home/bin/java` + `LanguageTool-*/languagetool-server.jar`），日志 `lt/lt.log`。
- 换端口：`EW_LT_PORT=8082 bash scripts/languagetool-up.sh`，同时把设置面板「引擎地址」改成 `http://127.0.0.1:8082`。
- 内存默认 `-Xmx256m`（更大堆在 192m 实测会 OOM）。

不装 LanguageTool 也能用：拼写走 macOS 自带 `NSSpellChecker`（零进程），清晰度/风格走本地规则，语法检查需要 LanguageTool 或你自填的模型接口。

## 隐私

- 默认只用本机 LanguageTool + 系统拼写词典：**文本不出本机**。
- 只有你自己在设置里填齐了三件套，才会把**当前这一句**发给你填的那个接口。
- 不发遥测、不记账、不写正文到日志。检查日志只有元信息（app、role、文本长度、命中数、耗时），单文件超 5MB 自动轮转。

## 已知限制（别抱错期望）

- **中文只做门控不做语法检查**：中文占比 > 0.40 的句子直接不介入（零请求），没有中文语法检查、没有中译英改写。
- **不做 AI 生成检测**：没有任何「这段是不是 AI 写的」能力，也不打算做。
- **不改 Grammarly 本体**：这是独立实现，不注入、不 hook、不逆向 Grammarly；两者可以同时装。
- **不替用户写**：改写/语气是选中段落手动触发，不是自动重写你的整段。
- 远端模型通道的延迟由模型决定（推理模型 5–45s），别指望它跟本地引擎一样即时。
- App 排除、个人词典、忽略规则都只在本机生效，不跨设备同步。

## 构建与自测

```bash
bash scripts/build.sh            # 产物 build/英文写作助手.app
open build/英文写作助手.app       # 常驻菜单栏；首次需授辅助功能权限
```

```bash
swiftc -O -swift-version 5 Sources/*.swift -o build/英文写作助手 \
  -framework AppKit -framework SwiftUI -framework ApplicationServices -framework NaturalLanguage

./build/英文写作助手 --selftest             # 门控 / 护栏 / diff 契约
./build/英文写作助手 --selftest --m3        # 接受 / 撤销 / 忽略 / 词典 / 合并去重 / 卡片离线渲染
./build/英文写作助手 --selftest --settings  # 设置持久化 / 零预设 / 空配置零请求 / 排除闸门
./build/英文写作助手 --selftest --lt        # 依赖本地 LanguageTool（先起引擎）
./build/英文写作助手 --demo-selfcheck       # 行内几何断言（真 NSTextView + AX 交叉校验）
bash scripts/ci-test.sh                     # CI 跑的那套（不依赖本地引擎）
```

自测在系统拼写词典未就绪的机器上（干净系统、CI runner）会把四条拼写断言标 `SKIP` 并写明原因，不计入失败——那几条在本机复跑才算数。

## 它是怎么工作的

1. **输入感知**（`Sources/Inline.swift`）：每进程一个 `AXObserver`，监听焦点与文本变化，800ms 去抖，只查光标所在句。
2. **引擎**（`Sources/SpellCheck.swift` / `LocalEngine.swift` / `Diff.swift`）：系统拼写 → 本地规则 → LanguageTool → 用户自填的 OpenAI 兼容接口，出口统一成 `[DiffItem]`（一条错 = 一条 edit）。
3. **误报护栏**：术语 / 箱号 / 港口码 / 长数字 / 金额 / 邮箱 / 链接 / 签名块内的建议一律丢弃；非英文单词在已安装的其他语言词典里成立时也丢弃。
4. **渲染**（`Sources/Underline.swift`）：`AXBoundsForRange` 取矩形，长 range 按行拆分取并集，透明非激活浮层只画线不收事件。
5. **合并去重**（`DiffSanitize.consolidate`）：同段重复只留一条；重叠按 拼写 > 语法 > 清晰度 > 风格 收敛，输出恒升序、两两不重叠。

## 许可

MIT，见 [LICENSE](LICENSE)。

## 维护者文档

真机验收工具、TCC/Mail 的坑、探针用法、排障顺序都在 [`docs/maintainer-notes.md`](docs/maintainer-notes.md)。
