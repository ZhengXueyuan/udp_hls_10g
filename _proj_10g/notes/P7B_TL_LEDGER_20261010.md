# TL 台账（2026-10-10 构建 F 轮）—— **compact 前的续接点**

> **为什么有这份文件**：本轮的**结论与证据已全部落盘并入库**，但"**在飞的两支派单内容**"与"**未落盘的队列/待写条目**"只活在对话里。
> 本件是 compact 后的**续接点**：读它 + 下面的"落盘地图"即可无损接管。
> ⚠️ 本件是**台账**，不是判据；引用结论请回原始件。

---

## §1 时点状态

| 项 | 值 |
|---|---|
| HEAD / `origin/master` | **`bc75919`**（两边一致，工作树齐平；**本轮 7 笔已全部推送**） |
| 本轮提交 | `34fb68b`（构建 F 实现）· `70d5d59`（板级+审查+定位+读侧加固）· `fa52438`（文档订正+知识库）· `faee172`（五行修复+矩阵登记+别名门）· `c9763ed`（工具债+mdio）· `bc75919`（微窗 stall 定位） |
| 板上现役 | **构建 F**（`ID_BID 0x0000001A` · 70 字 · 未实现 `0x138`）· `0x08 = 0` · `carrier = 1` · 无残留进程 |
| 对端 | sysctl 未动（`Adaptive RX: off / rx-usecs 0`）· `/tmp/p7b_biz/` 与 `/tmp/p7b_board2/` 工具 md5 逐字未变 |
| 工作树未提交（3 项，全为**刻意**） | `_proj_10g/notes/p7b_build_archive/20261010_091536/`（`.gitignore` 挡）· `sim/aliasgate/_selftest/`（自检工件，可删/可 ignore）· `_tmp_*.py` × 11（**既有裁定不提交**） |
| 推送配方 | ⚠️ 本轮两次 `HTTP 502` —— **真因 = 服务端瞬时**（重试即过）；另**一次真的是体积**（`http.postBuffer` 默认 1 MB 装不下大提交）⇒ **重试 + `-c http.postBuffer=524288000`** |

---

## §2 ⭐ 在飞的两支（**compact 后要按这个验收它们的交付**）

### (A) `persist` 设计件 —— 写 `_proj_10g/notes/P7B_PERSIST_DESIGN.md`（唯一新文件）
**任务**：为「**发送侧 persist / 零窗探询**」出 implementation-ready 设计件（①机制选型 ②探询段精确形式 ③退避与上限 ④**与第二把锁的关系** ⑤**观测量/判据/门** ⑥**板级怎么测** ⑦回退与逐位退化 ⑧代价与风险 ⑨未定）。
**我要求它必须回答的三条关键**：
1. **④ 安全关键**：`blocked`/`epoch`（`rtl/tcp_tx_frame.v:509/:522/:940-943`）是 RETXFIX 轮为 **dup-ACK 自持重放环**加的防护，而探询**不是** dup-ACK 触发的 ⇒ 探询**会不会被 `blocked` 挡住 / 怎么绕过而不把环放回来**，并给**可判定的判据**（**不许退回环的根修 `ack_seen`**）。
2. **⑤ 优先复用既有字**（如 `W55 = stat_retx`）—— **能不加新字就不加**（加字要走整条读侧同步，本工程**连翻三轮**）；门要能**演示"改之前会红"**。
3. **⑥ 板级零窗造法必须与台架开关无关**（台架那格一修，旧的"按需 stall"就没了）⇒ 候选 = 定位轮已实测的**对端 raw 注入 `win=0`**（`_tools/stall_probe.py`）。
**要它选型**：纯 persist 定时器 vs「让 RTO 在窗口 0 时不卸膛」（`rtl/tcp_tx_frame.v:1018` 的 else 分支）⇒ **明确回答"要不要动 `:1018`"**。
**验收要点**：⛔ 不许改 RTL/不许跑 xsim/不许 Vivado/不许上板（本轮纯设计）；**核到与我描述不符就如实说**。

### (B) 台架 sink 时序修复 —— 写 `_pcie/p7b_biz/p7b_tcp_sink.cpp` + `_proj_10g/notes/p7b_sinkfix_20261010/`
**任务**：`p7b_tcp_sink.cpp` 约 `:306` 在 **`connect()` 之后**才设 `SO_RCVBUF` ⇒ 线上先通告 64240 再塌到小窗 ⇒ **板的初突发已获对端授权**发出 ⇒ 小缓冲被冲掉。这是微窗 stall 的**触发**（已实测，非推断）。
**我要求的两条关键**：
1. ⭐ **必须留开关逐字复现旧行为**（旧行为是 persist 修复的**正控场景**，且**历史读数全在旧行为下取**）⇒ 给开关形式 + 默认值（**待 TL/用户裁定**）+ **见证行**（照惯例：缺见证按"未测"读）。
2. **给出可判定的"改对了"判据**：本机回环上跑一对 sink/src，看**首个 ACK 的 win 字段**是不是一开始就是目标值（做不到就说明为什么 + 给上板判法）。
**验收要点**：⛔ 只许写那个 `.cpp`（要动别的先报告）；⛔ 不部署到对端；⛔ 零构建零板。

---

## §3 队列（**按优先级**，compact 后照此推进）

1. ⭐ **实现 `persist`**（RTL，需构建）—— 本轮唯一**产品级功能缺口**。顺序 = 设计件 → **对抗审查** → 实施（单一主题，**不许捆绑**，否则不可归因）→ 门 + 负对照 → 一次构建 → 板级 A/B。
   ⚠️ 构建前先看时序余量：全局 `WNS +0.111`（`async_default` Recovery）/ **DP setup `+0.281`**。
2. ⭐ **台架 sink 修复**（在飞，零构建）。
3. **附带发现（未修）**：**`snd_wnd` 写入无守卫** —— `rtl/tcp_rx.v:509` `pend_wnd <= s_axis_tcrs || pend_wnd;`（**任何 FCS-OK 的 TCP 帧都写**）对比 `:508` `pend_una` 有 `ack_adv_l` 守卫 ⇒ **陈旧/乱序 ACK 的 `win` 会覆盖当前窗口**（"最后一个 ACK 说了算"）。
4. **`board/run_lint_p6e.bat` 加别名门那一行**（`call "%~dp0..\..\sim\aliasgate\run_aliasgate.bat" || exit /b 1`）—— **那正是编坏分支的入口**（上一轮被写边界挡住）。
5. **行号订正**：`wrapper_p4.v:2771-2775` → **`2773-2777`**（凡引用处：`CLAUDE.md` 置顶块 · `P7B_OPEN_ITEMS.md` · 板级一轮 `REPORT.md` · `P7B_BUILDG_RFC_SEQ_DESIGN.md`）。
6. `sim/p7b_stagec_tx/mut/` 的 **14 个已入库陈旧变异件**（低危；消费门每次先重生成）⇒ 清或重生成。
7. `rtl/app_pattern.v:33` 注释里还留着旧数 **71**（`P7B_LONGSEND_DESIGN.md:102` 是它的逐字引文，改注释要同时改引文）。
8. `sim/aliasgate/_selftest/` ⇒ 加 ignore 或删。
9. **Build G 设计件 v2 修订**（审查推翻 8 条 / 降级 8 条 / **行号勘误 6 处**）：`p7b_buildG_review_20261010/FINDINGS.md`。
10. **微窗家族未定位项**：丢帧出口逐帧见证（需 tracepoint）· **FIN 在 stall 态不被 ACK**（4 pcap 一致，板一个包都不回）· 相位失配 6/13 跑的**因果**· `blocked/epoch` 不可观测 · 触发变量仍是**候选级** · `DelayedACKLost` 漏采。
11. `analyze.py` 的"三角核**右腿**"是假牙（`ΔW66 ≤ ΔW64` 合法可被 `ΔH` 违反）⇒ 删或改口径。
12. 归档 `wrapper_p4_routed.dcp` 进 `p7b_buildF_build/F/`（下次 `create_project -force` 即毁）。
13. `vivado_prj/*/imports/board/wrapper_p4.v` **四份仍带反向别名**（含 `p7b_ku5p_prj` 那份"GUI 重编陷阱"）。

---

## §4 待写 / 待办的**文档与知识条目**（未落盘）

1. ⭐ **知识库再补一条**（**本轮已提议但未写**）：
   **「量的对象 ≠ 结论的对象」** —— 本轮我把**工作树里**的 pcap 体积（448 MB）当成**提交里**的体积，据此断言"我把两个 234 MB 的 pcap 提交了"，**实际 `git check-ignore` 命中 `.gitignore:425 *.pcap`，提交增量只有 1.9 MB**，502 是**服务端瞬时错误**（重试即过）。
   ⇒ **规则**：任何"**提交里**有没有 X / 多大 / 变没变"的断言，**必须量 `git cat-file`/`git diff-tree`/`ls-tree` 出来的对象**，**不许量工作树**。
   ⇒ 归属：与 **#47**（判据字段的单位/语义必须回源码核）同族；⚠️ **#89 只压住了"转述二手数字"，压不住"量错对象"**。
   ⚠️ 这也是本会话**第三次**同类错（① `MUTFAIL` 标记当缺陷 → #84 ② `--stat` 改动量当新增行数 → #89 ③ 工作树体积当提交体积 → 本条）。
2. 文档面把 queue §3-5..§3-8 逐条落进 `P7B_OPEN_ITEMS.md` / 相关件（**行号订正**优先，它会让下游改错地方）。
3. `P7B_OPEN_ITEMS.md` 目前**尚未**收录：微窗 stall 家族（判定 + 未定位项）· `snd_wnd` 无守卫 · 别名门与 `#19` 结项 · mdio 两潜伏项结项 · 两个新门（`sim/aliasgate/` · 矩阵第 17 门）。

---

## §5 落盘地图（compact 后从这里索引，**都在盘上且已入库**）

| 件 | 内容 |
|---|---|
| `_proj_10g/notes/p7b_buildF_board_20261010/REPORT.md` | 板级一轮：**`L` 首次直读** + `W67` 分裂 + 退化族（**含 TL 的恒等式批注**） |
| `_proj_10g/notes/p7b_buildF_board2_20261010/REPORT.md` | 板级二轮：`L` 独立分母（`TcpOutSegs`）+ 深压档三档 + **微窗 stall 家族首现** |
| `_proj_10g/notes/p7b_microwin_20261010/REPORT.md` | ⭐ **微窗 stall 定位**：判定 (c) 缺 persist · RTL 正身 `:1008-1018` · 反向双臂 · 6 处订正 |
| `_proj_10g/notes/p7b_buildF_review_20261010/FINDINGS.md` | 构建 F 对抗审查（**量纲订正 µs/事件** · W68 的牙 · 源冻结 9/9） |
| `_proj_10g/notes/p7b_buildG_review_20261010/FINDINGS.md` | Build G 审查（推翻 8 / 降级 8 / **行号勘误 6**） |
| `_proj_10g/notes/P7B_BUILDG_RFC_SEQ_DESIGN.md` | Build G 设计件（776 行；**待 v2**） |
| `_proj_10g/notes/p7b_p5wrapper_diag_20261010/REPORT.md` | `#8` 定位：五行反向别名 = **真缺陷** · 引入点 `f08fc6a` · 三门同根因 · 板配置实测清白 |
| `_proj_10g/notes/p7b_aliasgate_20261010/REPORT.md` | 五行修复 + `#19` 矩阵 16→17 + **别名方向常驻门**（假阳性 0）+ 工具面三条 |
| `_proj_10g/notes/p7b_readside_harden_20261010/REPORT.md` + `FULL_TABLE.tsv` | 读侧加固：穷举 771 条/149 文件 · **三条断言** · 负对照 4 条全红 |
| `_proj_10g/notes/p7b_tool_debt_20261010/REPORT.md` | 变异器地雷**纯核实**（0713a13 已修）+ mdio 两潜伏项改造（2×2 判据） |
| `_proj_10g/notes/P7B_OPEN_ITEMS.md` | ⭐ 用户的**未解决项汇总表**（本轮订正 13 格 + 新增 6） |
| `~/.claude/fpga_net_dev.md` §六 **#84–#89** | 本轮新知识：标记≠行为 · 既存红养 11 天 · 恒等式新形态 · 表尾第三次 · 回卷展开数两次 · 转述二手数字 |
| `udp_hls_10g/CLAUDE.md` 置顶块 · `PORT_NOTES.md:5932` | 构建 F 里程碑（下一步读这两处） |

---

## §6 纪律提醒（compact 后仍生效，逐条照办）

- ⛔ **绝不写板载 QSPI**；只走 JTAG 易失烧录；**只烧归档件**；**每次测量前必重烧 + 现核 sha256 ↔ 板侧 BID**。
- ⛔ **构建期间绝不得从被构建的工程烧位流**；⛔ 构建只走 `board/run_build_p7b_ku5p.bat`。
- ⛔ **绝不修改 `D:\repo\perfv`**；⛔ **密码不落盘**；⛔ **绝不改 license 文件**。
- git：**身份用 `-c` 指定、绝不改 config**；**绝不 `git add -A`**（显式清单）；**显式 refspec 推送并核对**；提交信息末尾带 `Co-Authored-By: Claude Code <noreply@anthropic.com>`。
- 并发 agent：**文件所有权必须互斥**；每里程碑**必开审查 agent + 测试 agent**；**提交由 TL 统一做**。
- 派单模板**固定句**（本轮两次靠它挡回上游的错）：**「核到与我的描述不符就如实说，别迁就」**。
- 引用纪律：`LF_GEOM_OK NW=63` 是**硬编码字面量**（不作证据）· `W69` 是**事件锁存**（不作窗口主判据，用 pcap 的 `win`）· `P ≡ 156.25e6/fps` 是**恒等式**（不是线占空）· 凡两时刻差值一律 **mod 2³² 且记 raw + k**。
- **板上无 UART**；判活看 BAR；可达性判据用 TCP 不用 `ping` 退出码。
- 每支 agent：**中文**；不许下 PASS/FAIL 裁定；不许写"时序已解决"；**不许把"未观测到"写成"不存在"**。
