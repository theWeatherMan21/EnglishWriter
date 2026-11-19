# 12 小时自动化推进流水

时间 | 轮次结论 | 下一轮要验什么
---|---|---
2026-11-19 18:57 | 工作区 6 个文件未提交（新增 ScreenLock.swift + 改 main/AXCheck/KeyWinProbe/MailProbe），编译进行中；git 0 未推送。--kpi 画线率 Safari 99.1%(115/112)/Mail 100%/QQ 100%/TextEdit 100%，点击 KPI FAIL 0.0%（同 App 有线仅 1 次）。--privacy 命令未接入口（main.swift 只认 --selftest），落到常驻模式被单实例锁 exit 0，验收跑不出数。--mail-selftest PASS 6/FAIL 0。最后 click-hit 08:02:05Z，2h52m 无命中，之后 168 次 check 全空；10:09Z 起前台恒为 loginwindow（屏幕已锁），37 次 check 全 items=0 系骨架 AX 假阴性。 | 装新版后重跑 --privacy 是否出汇总行；屏幕解锁后 Safari/Mail 真实点击是否产生 click-hit；TextEdit 那条 27px 竖直偏差的 miss 是否复现（diag 加 dx/dy 后才能定性）
