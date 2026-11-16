# EnglishWriter 浏览器扩展（Chrome / Edge，MV3）

Grammarly 在浏览器里靠的是扩展，不是辅助功能接口。这个目录就是那一层。

## 为什么必须走扩展

实测（`qa/evidence/chrome-probe.json`）：Chromium 网页输入框的 `AXValue` 属性显示可写，但
`AXValue` 和 `AXSelectedText` 写回**全部失败**，`contenteditable` 连 `AXBoundsForRange` 都拿不到。
纯 AX 在 Chrome 里做不出「一键接受」。扩展直接操作 DOM，这条路才通。

## 安装（一次性）

Chrome 156 起已移除 `--load-extension` 命令行装载（实测扩展 id 直接打不开），只能手动装：

1. 地址栏打开 `chrome://extensions`
2. 右上角打开「开发者模式」
3. 点「加载已解压的扩展程序」，选这个 `extension/` 目录
4. 打开扩展的「选项」，把本机 token 粘进去：

```
~/Library/Application Support/EnglishWriter/api-token.txt
```

token 由 App 首次启动生成，扩展不预置任何默认值。

## 它做什么

- 覆盖 `textarea` / `input[type=text]` / `contenteditable`，输入停顿 800ms 后检查光标所在句
- 文本与矩形全部来自 DOM（`Range.getClientRects`），不依赖宿主应用
- 下划线画在 shadow DOM 的绝对定位覆盖层里，不污染页面样式
- 悬停出卡片：接受 / 忽略此类 / 关闭
- 接受 = 真的改 DOM；撤销 = 还原原文
- 引擎走后端 App 的 `http://127.0.0.1:17817/v1/check`（复用 LanguageTool + 术语护栏 + 中文门控）

## 验收证据（无截图）

```bash
# 前提：App 在跑；起一个本地静态页 + 装了扩展的 Chrome（见 qa/chrome-ext-probe/）
open -a 英文写作助手.app
python3 qa/chrome-ext-probe/logic-probe.py     # 逻辑层端到端（不依赖扩展装载）
```

`logic-probe.py` 实测结果（`qa/chrome-ext-probe/logic-probe-report.json`）：

| 字段 | edits | rects | 接受后 | 撤销后 |
|---|---|---|---|---|
| textarea | 3 | 3 | `immediately` | 回到 `immediatly` |
| contenteditable | 3 | 3 | `immediately` | 回到 `immediatly` |

## 已知边界

- Chrome 156 不认命令行装载 → 自动化只能验「逻辑」，真扩展要手动装一次
- 中文占比 > 0.40 由 App 侧门控直接跳过（和原生同一口径）
- token 存在 `chrome.storage.local`，明文；这是本机回环通信，不是云凭据
