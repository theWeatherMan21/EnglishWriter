# 12 小时自动化推进流水

时间 | 轮次结论 | 下一轮要验什么
---|---|---
2026-11-19 18:57 | 工作区 6 个文件未提交（新增 ScreenLock.swift + 改 main/AXCheck/KeyWinProbe/MailProbe），编译进行中；git 0 未推送。--kpi 画线率 Safari 99.1%(115/112)/Mail 100%/QQ 100%/TextEdit 100%，点击 KPI FAIL 0.0%（同 App 有线仅 1 次）。--privacy 命令未接入口（main.swift 只认 --selftest），落到常驻模式被单实例锁 exit 0，验收跑不出数。--mail-selftest PASS 6/FAIL 0。最后 click-hit 08:02:05Z，2h52m 无命中，之后 168 次 check 全空；10:09Z 起前台恒为 loginwindow（屏幕已锁），37 次 check 全 items=0 系骨架 AX 假阴性。 | 装新版后重跑 --privacy 是否出汇总行；屏幕解锁后 Safari/Mail 真实点击是否产生 click-hit；TextEdit 那条 27px 竖直偏差的 miss 是否复现（diag 加 dx/dy 后才能定性）
2026-11-19 19:45 | 上轮三条全部落地并推送：HEAD dba1a4a（origin/main 齐平，0 未推送，工作区 3 文件修改中=扩展证据+Inline）。--privacy 入口已修，PASS 66/FAIL 0/SKIP 0；--mail-selftest PASS 6/FAIL 0（There is many reasons / immediatly）；--kpi PASS，Safari 99.1%(115/112)、Mail/QQ/TextEdit/ShipScheduleHub/Hermes 100%，点击样本仅 1 次不判定。HoverCard:458 已带 dx/dy/item，Inline:889 skip-readonly 已带真实 role+readonly/editable-but-unreadable 分类。锁屏门控生效：19:32 装新版后至今零 attach-app（此前 2 分钟一条 loginwindow）。扩展线 8 提交：两段式两次回退后 dba1a4a 宣称生效，chrome-click/keyboard 证据实锤点击→卡片→接受→⌘Z 撤销闭环（19:43/19:44）。仍无新 click-hit（最后一次 16:02:05 CST，3h43m）；屏幕自 18:09 锁着，18:07 那两条 click-miss 早于新包，dx/dy 未被执行过一次；35ms/2.7s 只有 maintainer-notes 自述无落盘证据。 | 装新版后：① --clickdiag 离屏断言能跑 PASS；② 解锁后 Safari/Mail 是否出 click-hit、18:32 TextEdit 27px 偏移能否定性；③ chrome-twostage.json 的 snapA/snapB 时间戳与 dropped=false；④ --privacy 锁屏门控断言
2026-11-19 20:32 | 上轮三条全部落地（cbf221d）：--clickdiag PASS 6/FAIL 0（dy=27/dx=10/dx=7 三条几何断言+最近线+空表）；--privacy 66→71 FAIL 0，新增 5 条 lock 断言（锁屏/未启用无效pid/loginwindow → 不轮询）全绿；qa/evidence/chrome-twostage.json 落盘 snapA 121ms 1 条线 / snapB 3707ms 3 条线 / dropped=0 duplicates=0，A⊆B 成立，两段式有硬证据。之后她转了 4 个改写提交：20d6a37 即时线改页内规则(300–530ms)、3b18ffa 候选硬过滤+去重(中位237ms)、b6bc132 整批空时严规则重试一次、804a179 边界空格按相邻字符判定(不再 provideus)。HEAD 804a179，0 未推送，工作区仅 Rewrite.swift +8（span 硬校验，注释标我提的）。--kpi PASS：Safari 99.1%(115/112)、Mail/QQ/TextEdit/ShipScheduleHub/Hermes 100%，点击样本仍 1 次不判定。--mail-selftest PASS 6/FAIL 0。最后 click-hit 16:02:05 CST，4h30m 无命中；CGSSessionScreenIsLocked=YES，这一段不能当证据。新发现：锁屏期间仍 emit attach-app loginwindow（20:23:34），Inline.swift:736 在 744 的 isLocked 判断之前无条件 emit，启动/激活路径绕过门控。 | ① 解锁后重跑 --kpi 盯第一条 click-hit 与 18:07 那两条 QQ miss 的 dx/dy；② 新增 --rewrite-selftest 汇总行是否 PASS≥8/FAIL 0；③ 锁屏下 attach-app 是否归零（同一轮 --privacy 里要能断言）

2026-11-19 21:24 | 上轮两条全部落地：`--rewrite-selftest` 新增 PASS 9/FAIL 0（边界空格/错位 span/双空格/去重/label 兜底/应用顺序/空候选/无双空格 + worddiff 往返 3/3）；锁屏 attach 门控下沉到真实发射点 Inline.swift:737（emit 之前 guard shouldAttach），`--privacy` 71→74 PASS 0 FAIL（新增「锁屏不发 / loginwindow 不发 / 未锁正常 App 发」三条），实测 12:23:34Z 之后 attach-app loginwindow **0 条**、锁屏期间 attach-app 总数为 0。另 --acceptflow PASS 11/0、--clickdiag 6→7 PASS/0、--quality 100%（10/10）8 句零误报、--quality --deep 100%（10/10）均 3363ms/句（上限 8000）、--kpi PASS：Safari 99.1%(115/113/112)、Mail/QQ/TextEdit/ShipScheduleHub/Hermes 100%，点击仍样本 1 次不判定。日志 5422 行全部可解析（O_APPEND+flock 生效）。HEAD 18555a6，0 未推送，但工作区 8 文件在改（Rewrite.swift 越界 span 防崩 +8、SelfTest 锁屏记 SKIP 不记 FAIL、ci-test.sh 串 6 组断言）未提交；install-check **STALE**：repo build 21:20 比装机 21:13 新（两版 privacy/rewrite 数字一致）。最后 click-hit 仍是 16:02:05 CST（5h22m），屏幕自 18:09 锁着，这一段不能当应用质量证据。 | ① 解锁后重跑 --kpi 抓第一条 click-hit 与 QQ 那三条 click-miss 的 dx/dy（nearest=nan rect=[0,0,0,0]，owner=QQ front=Telegram Lite/WindowManager，新包后尚未复现）；② 工作区 8 文件 commit+push，装机版跟上 build 消 STALE；③ 断言仍只测 ScreenLock.shouldAttach 纯函数，「真发射点」目前靠 0 条 loginwindow 的日志事实兜着——解锁后需复验一次正常 App 仍能发 attach-app（别把门关死）

## 给爹地的明早一页（2026-11-19 22:40 收尾时写）

**能用了没？** 能，但还差你亲手点三下才算数。

**已经硬证明的（离屏，可复跑，一条命令 `bash scripts/ci-test.sh` → EXIT=0）**
- 拼写/语法/清晰度/风格四类建议在跑；业务英文召回 100%（10/10），8 句正确句零误报
- 改写：真模型 5 句 × 3 轮全绿（5/5 有候选、5/5 不重复、平均 ~4.2s，上限 8s）
- 写回闭环：接受 → 正文变 → 撤销回原文 → 越界拒绝 → 原生读回不符判失败（11 条断言）
- 忽略词典：会话级与词典级两套语义分开验（原文+建议成对命中，不会连带屏蔽别的建议）
- 浏览器扩展：点线弹卡 / 五个按钮 / 键盘 →←Esc / contenteditable / 接受写回（headless 真 Chrome）
- 视觉基线：设置面板与浮动球两张基线图入库，CSS 一改超 0.1% 就出差异图

**这一夜修掉的真 bug（都是「看起来没事、用起来出事」那类）**
1. 模型返回越界 offset（start=9999）→ `character(at:)` 抛 NSRangeException，**整个 App 崩溃**
2. 改写让模型算 offset → 拼出 `provideus` / `usus` 碎片；改成「模型只给整句，diff 本地算」
3. 写回「返回成功但正文没变」被当成成功 → 现在原生宿主读回不符一律判失败
4. 日志里 2 行坏 JSON（常驻实例与探针并发写打断）→ O_APPEND + flock
5. 模型把 FCL / demurrage 这类业务词当错改掉 → 术语保护区间
6. 锁屏期间仍写 `attach-app loginwindow` → 门控下沉到真实发射点

**只有你能验的三条（我在锁屏环境里无法替代）**
1. TextEdit 里写 `We was late because there is many problems with the booking.` → 出线 → 点线 → 接受 → 变 `We were…`
2. Mail 新建邮件粘同一句 → 出线 → 接受 → 正文真的变
3. **来回切 5 次 App（TextEdit / Mail / Safari），App 图标不能消失**
   —— 这一条以前没有任何断言能覆盖：崩溃报告里有 8 份是「切 App 时 App 直接退出」
   （`MainActor.assumeIsolated`，已在 d8a302a 修掉，CI 现在硬拦这类写法），但只有人切才能最终确认。
   任一条没反应：把 `~/Library/Application Support/EnglishWriter/check-log.jsonl` 最后 50 行发我，
   日志里 `owner / front / nearest / path` 会直接指向原因；App 若消失，崩溃报告在
   `~/Library/Logs/DiagnosticReports/`（我按 `.ips` 直接读，不用你描述）。

**没做的（不是缺口）**：Chrome 商店安装路径（还没打算发布）、锁屏期间的点击样本（环境限制，不算质量结论）。
