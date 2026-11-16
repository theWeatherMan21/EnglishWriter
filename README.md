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
| M4 设置 / 文档 / 开源骨架 | 已交付 | LICENSE、README、CI、`out/parity.md` |
| 真机（TextEdit / Mail / Chromium） | **未验收** | 缺一个真实靶子窗口，见 `out/parity.md` |

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

## 自测

```bash
./build/英文写作助手 --selftest --lt      # 门控 / 护栏 / diff 契约 / 本地引擎
./build/英文写作助手 --selftest --m3      # 接受 / 撤销 / 忽略 / 词典 / 合并去重 / 卡片离线渲染
./build/英文写作助手 --demo-selfcheck     # 行内几何断言（真 NSTextView + AX 交叉校验）
bash scripts/ci-test.sh                  # CI 用的那套（不依赖本地引擎）
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
