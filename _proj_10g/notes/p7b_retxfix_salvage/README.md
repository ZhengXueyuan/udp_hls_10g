# p7b_retxfix_salvage —— `udp_hls_10g_fix` 工作树的**保全件**

**为什么有这一份**：`udp_hls_10g_fix`（另一 session 的工作树，与主树同源）于 **2026-10-09 被删除**。
删前审计结论：
- 该树 **`HEAD = 92cbeee` 是 `origin/master` 的祖先** ⇒ **没有任何 origin 缺少的提交**，无需合并；
- **已跟踪文件零改动** ⇒ 无未提交内容；
- ⛔ **但它的位流与取证不在 git 里**（`*.bit`/`*.dcp`/`*.pcap` 按既定策略排除）⇒ **删除会丢唯一副本**。

## 内容

| 目录 | 内容 | 为什么留 |
|---|---|---|
| `bits/` | **7 个只在该树存在的位流**（各 15,431,261 B） | 其中 **`8c8b6126…` = r6-fix = 板子当前生产设计**，是重烧的唯一副本；其余 6 个是 RETXFIX 轮的 A/B 负对照臂（`P7B_RETXFIX.md` §5 有账）。**重建每个约需一次完整 Vivado 实现**，且 r2–r4 对应的 RTL 中间态**未入库** ⇒ 那些位流是该状态的唯一记录 |
| `peer_notes/` | 原树 `_proj_10g/notes/p7b_retxfix/` 全部（181 MB：pcap/tsv/日志） | 该轮的原始取证 |
| `build_reports/` | 原树 `p7b_build_archive/` 的 `*.rpt`/`*.txt`/`*.log`（84 MB） | 逐次构建的时序/利用率/DRC 报告 = 证据 |
| `burn_r6fix.bat` | 原树唯一未跟踪文件 | 烧录脚本（⚠️ **按原样保全、未改** —— 其内部三条路径（`TCPREG_BIT` / `-source` 的 tcl / `-log`）**仍指已删的 `udp_hls_10g_fix` 树 ⇒ 直接跑会白跑**；**现役烧法** = 设 `TCPREG_BIT` 指向 `bits\8c8b6126__wrapper_p4.bit` 后走**主树**的 `udp_hls_10g\_proj_10g\notes\p7b_biz_tcpreg\run_program_tcpreg.bat`（自定位 + 读 `TCPREG_BIT` 环境变量；判据 = `End of startup status: HIGH`）） |
| `SHA256SUMS.txt` | 以上全部 | 索引 |

**未保全（已弃）**：`vivado_prj/` 与 `p7b_build_archive/` 下的 `*.dcp`（834 MB）与工程缓存 —— **可重建**（重新综合/实现即可），不构成唯一副本。

## 位流对照

| sha256 前 8 | 角色 |
|---|---|
| `8c8b6126` | **r6-fix（L-A `ack_seen` 数据启动门）= BID `0x11`，板子当前生产设计** —— **新 session 重烧用这条路径：`D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_retxfix_salvage\bits\8c8b6126__wrapper_p4.bit`**（sha256 全值 `8c8b6126f82c2c45acee1a1c308332e561677cac5cfb27b87d74d03463d5baf5`） |
| `112328da` | r6 首版（BID `0x10`，板上死锁 ⇒ 保留为鲁棒性回归件） |
| `39afd127` | r5（RTO 100→20 ms，BID `0xF`） |
| `dfd9ec27` | r4 |
| `4e114594` | r3 |
| `48e9a729` | r2 |
| `0a46645f` | retxfix 早期件 |

⚠️ 本目录**不入库**（`*.bit` 被全局规则排除，与既定策略一致）；**入库的只有 `README.md` 与 `SHA256SUMS.txt`**（证据索引）。

---

⛔ **2026-10-09 订正（显式登记、不静默改）**：本 README 同日两处更新 ——
① **`burn_r6fix.bat` 行**：加"其内部三条路径仍指已删的 `udp_hls_10g_fix` 树 ⇒ **直接跑会白跑**；现役烧法"；
② **位流对照表 `8c8b6126` 行**：加**新 session 重烧用的完整路径**（含 sha256 全值）。
⚠️ **本 README 自身在 `SHA256SUMS.txt` 里的那一行已随之同步**（`e179b678…` → 见清单首行）；
其余 **279 个件（含全部 7 个位流、`peer_notes/`、`build_reports/`）一条未动** —— `sha256sum -c SHA256SUMS.txt` = **280/280 OK**。
