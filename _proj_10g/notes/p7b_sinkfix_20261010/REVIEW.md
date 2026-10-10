# REVIEW.md —— `p7b_tcp_sink.cpp` SO_RCVBUF 落点修复的**对抗审查**（2026-10-10）

> **审查者**：对抗审查 agent（TL 派的）。**独立成形** —— 未读、未猜另一验证 agent 的任何产出（它尚未落盘）。
> **边界**：只读 `_proj_pcie/p7b_biz/p7b_tcp_sink.cpp`（工作树，未改）、`p7b_io.h`、交付报告与自检件、全仓消费者；
> 零板卡 / 零 Vivado / 零 xsim / 零 ssh 对端。本文件是本次审查**唯一**写入的文件。
> **审查时点**：2026-10-10 19:27–19:45（本机 Windows / Git Bash）。
> **现核基线**：`git diff --numstat HEAD`（全仓）= **只有这一件**：`63 2 _proj_pcie/p7b_biz/p7b_tcp_sink.cpp`（19:40 取）。
> **口径纪律**（本文件遵守）：**不写 PASS/FAIL 裁定**；不下"时序已解决"；不把"未观测到"写成"不存在"；
> 【事实】= 我本轮逐字核过的；【推断】= 有机制依据但未现核；【未证】= 没核到、并说明为什么。
> ⭐ 固定句照守：**凡核到与派单/报告描述不符的，逐一如实列出**（见 §F），不迁就。

---

## 0. 结论速览（每条一句话；细节在对应节）

| 攻击点 | 结论 |
|---|---|
| **A. "旧臂 = 逐字复现"** | **基本成立、需一处降级**。socket 级调用序列 + 失败路径 + `errno/*why` + 返回值语义**逐条相同**（含"失败时不设 SO_RCVBUF"这一边角）；**唯一微差** = 末尾 setsockopt 相对两处 `now_s()`/`first_conn_at` 的位置，后果 = 旧臂的 `conn_ms` 字段现在**含一次 setsockopt 系统调用**（首窗语义不受影响）。"两臂只差 setsockopt 位置"**成立**。 |
| **B. 缺陷论断（结构性、非竞态）** | **成立**（对 SYN 那一半是**源码级硬结论**，且比报告的说法更强/更一般）。报告的**加强版措辞**里"握手完成 ACK 也带默认大窗"这一子断言 = **未证**（唯一直接读数在 Windows 演示里反而读到 255 小窗）。 |
| **C-1. TL 批注（默认 8 MiB 下两臂首窗也不同）** | **成立**（"默认构型下修复无影响"被推翻）；本仓有**实测锚**支撑旧臂首窗 = 64240；"修复臂 = 65535"是**内核机制推断、未在 Linux 现核**（判法成本≈0，下轮可做）。 |
| **C-2. 下游解析器** | **未发现被打坏的消费者**（319 个含 SINK_ 字样的文件；全部锚定正则/前缀 grep，无按行号/列位者；新行仓内 0 消费）。⭐ 另用**两件真实 run 档**核过 `head -3`/`tail -6` 摘录窗口 ⇒ **内容逐条不变**。 |
| **C-3. 其它外溢** | 除首窗外只有一条可测差异（`conn_ms`）；`--maxbytes`/STALL/`bad_conns`/退出码/`SINK_SUM` 字段**逐字未动**（diff 现核）。正控场景（2920/1460 造 stall）与**全部历史读数**现在都必须显式带开关。 |
| **D. 自检门 `gate_sinkfix.py`** | **有牙但覆盖面窄**：作者 7 对照 + 正件我全部**原样复现**（逐字相同）；但我自造 **7 个"应当红"突变里 4 个全绿**（RC=0, violations=0）—— 其中 2 个直接打掉交付件的两条核心承诺（① 旧臂不再是旧行为 ② 修复被静默禁用）。⇒ 门是**token/结构检查器**，不能读成"修复在位/旧臂保真"。 |
| **E. 代码级** | **未发现 UB / 未初始化 / 泄漏 / include 前提缺失**（4 个头逐个符号核过）。建连仍在**双线程 spawn 之前**，`--no-thread` 与双线程共用同一调用点。 |
| 报告"本机无工具链" | **我去证伪了，没证成**：`/c/msys64/mingw64/bin/g++.exe` 存在且 `--version` 能跑，但平凡文件 **RC=1、零输出、无产物**（与报告逐字一致）；`sys/socket.h` 全盘 0 命中；WSL 无发行版。⇒ 报告 §4-1 属实。 |

---

## A. "旧臂 = 逐字复现"这条**归因干净性**声明

### A.0 逐行对比（现核）

被比对的两段（`p7b_io.h:87-118` 与工作树 `:223-241`）：

```
p7b_io.h:105-118   p7b_io_connect_to()           工作树 :223-241  sink_connect_rcvbuf()
  socket / fd<0 -> *why=errno; return -1           socket / fd<0 -> *why=errno; return -1        ✅ 逐字
  sockaddr_in a{} / sin_family / htons(uint16)     sockaddr_in a{} / sin_family / htons(uint16)  ✅ 逐字
  inet_pton!=1 -> *why=EINVAL; close; return -1    inet_pton!=1 -> *why=EINVAL; close; return -1  ✅ 逐字
  p7b_io_set_nonblock(fd)                          p7b_io_set_nonblock(fd)                       ✅ 逐字（都在 connect 之前）
  ---（无）---                                      if(!rcvbuf_after_connect) setsockopt(...)      ← 新臂新增
  connect_nb(fd, sa, sizeof(a), secs*1000, why)    connect_nb(fd, sa, sizeof(a), secs*1000, why)  ✅ 逐字（含 secs*1000）
  失败 -> close(fd); return -1                      失败 -> close(fd); return -1                  ✅ 逐字
  ---（无）---                                      if(rcvbuf_after_connect) setsockopt(...)        ← 旧臂新增（= HEAD :306 的位置）
  return fd                                        return fd                                      ✅ 逐字
```

【事实】调用点唯一（`grep -n sink_connect_rcvbuf` = `:223` 定义 + `:359` 调用，无第三处）；HEAD 那条
`int fd = p7b_io_connect_to(host, port, 5, &why);` 的四个实参在新调用点**逐个对应**
（`host, port, 5, rcvbuf, rcvbuf_after_connect, &why`），`secs=5 ⇒ 5000 ms` 与 HEAD 同值。
【事实】`p7b_io_connect_to` 在本文件**活跃引用 = 0**（`:203/:216/:221` 三处全是注释；`gate_sinkfix.py` 的去注释视图正是为此）。

### A.1 逐项判决（派单点名的六项）

| 子项 | 结论 |
|---|---|
| `secs*1000` 单位/溢出 | 【事实】**同源同值**（两处都是 `int secs` → `secs*1000`，实参都是 5）。溢出是**两版共有**的性质，非本刀引入。 |
| `set_nonblock` 相对 `connect` 的先后 | 【事实】**两版都在 connect 之前**且都**不再切回**（无清 O_NONBLOCK 路径）。 |
| 失败路径的 `close()` | 【事实】**相同**：socket 失败无 fd；`inet_pton` 失败 close；`connect_nb` 失败 close。 |
| 失败路径**是否设了 SO_RCVBUF** | 【事实】**旧臂不设**（在 `connect_nb` 失败分支直接 return −1，跳过末尾 setsockopt）—— 与 HEAD 一致（HEAD 在 `fd<0` 时 `continue`，`:306` 永不执行）。✅ 这一条我专门查了，**没有**"失败时多设一次"的语义差。 |
| `errno` / `*why` 取值 | 【事实】三条失败路径逐一对应（socket→`errno`；`inet_pton`→`EINVAL`；`connect_nb`→其内部 `ETIMEDOUT`/`errno`/`SO_ERROR` 原值）。`p7b_io_connect_nb` 的**每条** return −1 路径都写了 `*why`（`:90/:95/:96/:99/:100`），故 `*why` **不会**未初始化。 |
| 返回值语义 | 【事实】成功 fd / 失败 −1，逐条相同。 |

### A.2 ⭐ 我找到的**唯一**实质微差（降级点）

【事实】HEAD 里 setsockopt 的**文本位置**在三件事**之后**：`double t1 = p7b_io_now_s();`、`if (fd < 0){...}`、
`if (c == 0) first_conn_at = t1;`。新助手把（旧臂的）setsockopt 移到 `connect_nb` 返回**之后、helper 返回之前**
⇒ 它现在位于上述三者**之前**。

- **对首窗：无影响**（两臂的 setsockopt 都在"connect 已完成"之后 / "connect 未发起"之前各自就位）。
- **可测后果**：`SINK_CONN` 的 `conn_ms=%.3f`（= `(t1−t0)*1e3`，`:452`）在**旧臂**下现在**含一次
  `setsockopt` 系统调用**（HEAD 不含）。量级 ≈1 µs 级，对 `conn_ms` 的历史读数（0.08–0.2 ms 量级）是 1% 以下的位移。
- **推荐措辞**（不是错，是口径）：「逐字复现」→「**首窗语义逐条相同；已知一处非 socket 级微差（`conn_ms` 含一次
  setsockopt），已量化**」。派单里点名的"找**任何**语义差"这一问我给出的答案就是这一条 —— 只有这一条。

### A.3 交界面的其它两条现核（我在 diff 之外顺手核的）

- 【事实】**单一 fcntl 契约未被破坏**（`p7b_io.h:64` 的 grep 判据）：新代码**没有**直接 `fcntl`，走 `p7b_io_set_nonblock`
  （该 .cpp 里 `fcntl` 字样只出现在既有注释 `:18/:19`）。⚠️ 但那个 grep 判据本身有**注释假阳性**：
  `grep -ln F_SETFL *.cpp *.h` 命中 `p7b_tcp_sink.cpp`/`p7b_tcp_src.cpp`/`p7b_udp_src.cpp`/`p7b_io.h`
  四件（前三件是注释里提到旧实现）—— **先于本刀存在**，只登记。
- 【事实】**调用点在双线程 spawn 之前**（`:359` 建连 vs `:387-388` `pthread_create`），且该调用点在
  `if (threaded)` **之外** ⇒ 双线程与 `--no-thread` **两路径共用同一落点**，不存在"一条路径改了、另一条没改"。

---

## B. 缺陷论断本身：`connect_to` 返回时握手已跑完 ⇒ 到 `:306` 已晚 ⇒ 结构性

**结论：成立**（并且我认为它比报告写的更强 —— 见 B.2）。逐条回源码：

### B.1 三条路径全部满足"SYN 必先于 setsockopt"

【事实】`p7b_io_connect_nb`（`p7b_io.h:87-102`）三条出口：

| 路径 | 源码 | 握手状态 |
|---|---|---|
| `connect()` 返回 0（同步成功） | `if (r < 0) {...}` 两支都跳过 | 握手在 `connect()` **内部**完成 |
| `connect()` 返回 EINPROGRESS | `poll(POLLOUT, timeout)` → `getsockopt(SO_ERROR)` | poll 报可写且 `SO_ERROR==0` ⇒ 已 ESTABLISHED |
| 失败 | 三处 `*why` + `return -1` | 不返回 fd ⇒ 调用者 `continue` |

⇒ 【事实】**无论哪条路径，`setsockopt(SO_RCVBUF)` 都发生在 SYN 发出之后**。派生结论：
**"结构性"这一定性不需要 `poll` 语义**（报告把它挂在 poll 上）—— 只要有 `connect()` 先被调用这一件事就够。
这个更强的形式同时覆盖了报告的例外口子（回环 `connect()` 同步返回 0：`_proj_10g/notes/p7b_affinity/f9_loopback_check.sh`
里 sink 就是连 `127.0.0.1`，走的正是这一支）。

### B.2 ⚠️ 报告的**加强版措辞**里有一条是**未证**的

报告 §1.1/§2.1/§6-① 逐字写：「SYN **与握手完成 ACK** 都已经在线上，各自带的是尚未设过的默认 rcvbuf 算出的窗」。

- 【事实】SYN 那一半 = 硬结论（B.1）。
- 【未证 / 反证性读数】"握手完成 ACK 也带默认大窗"：机制上（Linux 在 SYN-ACK 处理路径上完成握手并立刻回 ACK）
  是**合理推断**，但**本仓没有任何直接见证**；而唯一的相关直接读数在**反面**：交付件 §3.3 的 Windows 演示里，
  旧臂（ARM B）**首个客户端 ACK 的 win = 255**（小窗），不是大窗。它可能只是"抓到的不是握手 ACK"，
  但**该演示本身分不出这件事**（打印里没有时间序/seq 上下文）⇒ 这条子断言按**未证**读。
- **影响面**：如果只按 SYN 论证，结论**不减小**：初突发由 `min(cwnd, rwnd)` 授权，Linux 初始 `cwnd = 10×MSS = 14,600 B`
  **本身就大于** 2920 B 的目标缓冲 ⇒ 大 SYN 窗足以让初突发越过小缓冲。⇒ **主线不受影响，副线请降级成推断**。

### B.3 一处措辞要钉死（与既存件的矛盾）

【事实】`_proj_10g/notes/P7B_PERSIST_DESIGN.md:382`（P-C 行）对同一件事写的是「…⇒ 线上先 64240 再塌 |
**有关**…| 定位轮：`rcvbuf=1460` 档 **7/7 stall**；`2920` 档 **5/6** ⇒ **含竞态成分**」。
而报告 §1.1/§6-① 写「**结构性**触发，**不存在**"把手速调快就能躲开"」。
两者**不矛盾**（前者说的是 stall 的**复现率**，后者说的是**落点**），但**同一句话"不是竞态"很容易被下游读成
"stall 是确定性的"**。建议 TL 在台账里把这两层分开写：「落点=结构性 / stall 复现率=5-of-6、7-of-7，仍含随机成分」。

---

## C. 默认值翻面的外溢影响

### C.1 TL 批注（"即便 `--rcvbuf` 取默认 8 MiB，两臂首窗也不同"）—— **独立核：成立**

我按三条证据分开给：

1. 【事实·结构性】两臂在 `connect()` **之前** socket 的接收缓冲**不同**：旧臂 = 内核默认；修复臂 = `rcvbuf` 经内核夹取后的值。
   ⇒ 「默认构型下修复无影响」这句话**不成立**（这一层不需要任何内核细节）。
2. 【事实·本仓实测锚】旧臂的默认首窗 = **64240** 是**实测值**，锚点在仓内：
   `_proj_10g/notes/p7b_board_stagea/head_P0_r1.txt:2`
   → `t= 0.000000 P->B 52414->8080 len= 0 seq=… ack=… win= 64240 S`（同轮的
   `p7b_board_stagea/ss_STG_P0_R1.log:2` 显示该 socket `skmem:(r0,rb131072,…)` ⇒ 默认缓冲 131072）。
   ⇒ 报告注释里的"实测 64240"**可追溯**（初判"仓内无出处"是我查漏，已订正为有锚）。
3. 【推断·内核机制，未现核】修复臂（`--rcvbuf` 默认 8 MiB）：Linux 会把 SO_RCVBUF 夹到 `2×rmem_max`，
   其 `tcp_win_from_space` 后仍 ≫ 65535 ⇒ **SYN win 被 16 位字段顶到 65535** ≠ 64240 ⇒ 两臂首窗**确实不同**。
   ⚠️ **最后一步（顶到 65535）我无法在本机执行**（对端被本轮的硬边界冻结）⇒ 标【推断】。
   **判法（下轮，成本≈0）**：对端 `sysctl net.core.rmem_max net.core.rmem_default net.ipv4.tcp_rmem` +
   两臂各抓 **1 个 SYN** 看 `tcp.window_size_value` 是否一为大窗一为 64240。
   ⭐ 顺带：**`rmem_max > 65535` 几乎是确定的**（默认 212992）⇒ 结论方向稳；但"65535"这个具体值可以只当量级。

⇒ **对 TL 批注的裁定建议**：**采纳**，并把措辞从"两臂首窗也不同"细化为「**两臂首窗不同（旧臂 64240 有实测锚；
修复臂 ≥ 旧臂、推断 65535）**」—— 因为"不同"的**方向**（修复臂更大或至少不同）在机制上稳，**具体数值待一次抓包**。

### C.2 其它"因落点变化而与历史读数不可比"的项（我另找的，除 TL 已点的那两条之外）

| # | 项 | 现核 |
|---|---|---|
| ① | **`--maxbytes` / `STALL` 判定 / `bad_conns` / 退出码 / `SINK_SUM` 各字段** | 【事实】**逐字未动**：diff 的 8 个 hunk 里只有 5 处是"行为"（新助手、flag 声明、flag 解析、见证行、调用点），其余是注释/帮助文本；`return (bad_conns == 0 && fail_conns == 0 && tot_bytes > 0) ? 0 : 1;` 未动。 |
| ② | **`conn_ms`** | 【事实】差异存在（§A.2）：旧臂 now 含一次 setsockopt ⇒ 与 HEAD 同配置的历史 `conn_ms` **不再逐字可比**（量级 1% 以下，但**严格说不可比**）。这是本刀**除首窗外的第二条**口径位移。 |
| ③ | **`--help` 文本** | 【事实】多了一行 usage + 3 行说明。唯一按 `--help` 文本取值的消费者是 `_proj_pcie/p7b_biz/aff_selftest.sh`（F3：`--help | head -1 | grep -oE 'PIN_CPU=…PIN_TUPLE_ORDER=…'`）—— 它取的是 `p7b_pin_cpu` 在**参数解析之前**打的第 1 行，本刀**不碰**该行 ⇒ **不受影响**（已读该脚本确认）。 |
| ④ | **正控场景（`rcvbuf=2920` 5/6 stall、`1460` 7/7 stall）** | 【事实】那两档是**旧落点**读数；默认翻面后**不带开关就跑不出旧行为**。TL 已立纪律（"凡与历史读数 A/B 必须显式带开关"）⇒ 我**同意**，并补一句：连**长流档**（`R1A` 等 `--rcvbuf 8388608` 的历史读数）也应按"首窗不同"当作**跨口径**处理 —— 「稳态缓冲相同⇒无影响」是**推断**，**未测**。 |
| ⑤ | **`p7b_tcp_sink_rate`（同族第二实例，未修）** | 【事实】我逐行核过 `_proj_10g/notes/p7b_board_stagec/p7b_tcp_sink_rate.cpp:127/:136`（`connect_to` 后 `setsockopt(SO_RCVBUF)`）—— 报告 §6-③ 的行号与形态**逐字对上**。它作为 A/B 的另一只手时**同样带这个触发变量**。 |
| ⑥ | **`p7b_rate2_bench.cpp:291-294`** | 【事实】同上核过（`accept()` 之后才对 `rfd` 设 `SO_RCVBUF`，listener 从未设）。**顺带**：该文件在**连接方**（`sfd`）是 `setsockopt(SO_SNDBUF)` **在 `connect` 之前**（`:285-288`）—— 同一个文件里"发送侧知道要前置、接收侧不知道"，可作为本缺陷形态的一处旁证（只登记，不下结论）。 |

### C.3 下游接口普查（派单点名的全仓 grep）

【事实】范围与结果：
- 含 `SINK_SUM|SINK_LIMITS|SINK_CHECK|SINK_CONN|SINK_RCVBUF_ORDER` 的文件 **319 个**（绝大部分是历史 raw 档）。
- **全部**解析器都是**锚定**口径，逐条点名核过：
  `^SINK_SUM` / `^SINK_LIMITS` / `^SINK_CONN`（`p7b_a7_board_20261010/analyze.py:89-98`、`p7b_buildE_*`、
  `p7b_buildF_board_*`、`p7b_window_side_20261010/analyze.py:99`、`p7b_gap9_tx_board_20261010/analyze.py:79-88`）；
  `re.search(r"SINK_SUM (.*)")`（`p7b_board_stagec/an_runs.py:48`、`p7b_retxfix/an_runs.py:48`）；
  `SINK_SUM conns=1 fail_conns=0 bytes=(\d+)` 与 `SINK_CONN 0 OK bytes=… first_mismatch=`（`p7b_longsend_board/ls_analyze.py:63,66`、`ls_summary.py:26`）；
  `ln.startswith("SINK_CONN 0 ")`（`p7b_buildF_board2_20261010/mktable.py:23`、`mktable2.py:20`）；
  `grep -E '^SINK_SUM|^SINK_CONN' "$RAW" | head -6`（各 `run_arm*.sh`、`run_mw.sh:86`）。
- **没有**任何消费者按**行号 / 列位 / `sed -n Np`** 解析 sink stdout；**没有** `grep -c SINK_` 类计数判据。
- `SINK_RCVBUF_ORDER`：仓内 0 消费（只有生产者自己）⇒ 【事实】**新行只新增，未改名、未改序**（`SINK_CHECK`→`SINK_LIMITS`→`SINK_RCVBUF_ORDER`→`SINK_CONN*`）。
- ⭐ **摘录窗口（这是我另找的一条真风险，已核实为无害）**：采集脚本（`lf_dl*.sh`、`stc_dl.sh`、`old_stc_dl.sh`）
  把 sink stdout **只以 `head -3` + `tail -6` + `grep SINK_SUM` 三块摘录**进 run 档 ⇒ 新行会**移动窗口边界**。
  我用**两件真实档**（`p7b_buildF_board2_20261010/runs/R1A.txt`、`p7b_microwin_20261010/runs/MW1.txt`，
  两者 sink stdout 都是 **9 行**：`PIN_RULE → SINK_CHECK → SINK_LIMITS → PIN_THREAD×2 → SINK_CONN… → SINK_SUM → SINK_DONE → PIN_GETCPU_END`）
  按插入一行后重算窗口：
  - `head -3` = `[PIN_RULE, SINK_CHECK, SINK_LIMITS]` —— **插入前后逐条相同**（新行落在第 4 行，**恒在 head-3 之外**，
    因为亲和见证行恒在 `SINK_CHECK` 之前 —— `p7b_affinity.h:999` 的启动行、含 `--no-pin` 的 `UNPINNED=1` 形态）；
  - `tail -6` 插入后 = `[PIN_THREAD work, PIN_THREAD io, SINK_CONN…, SINK_SUM, SINK_DONE, PIN_GETCPU_END]` ——
    与插入前**内容逐条相同**（只是整体下移一行）。
  ⇒ 【事实】两个窗口**都不受损**，`SINK_CONN 0` 仍在（`mktable.py` 的 `startswith("SINK_CONN 0 ")` 与
  `ls_analyze.py` 的 `SINK_CONN 0 OK …` 都不受影响）。
  ⚠️ **边界条件（登记，防未来踩）**：这条"落在窗口之外"的良性质依赖**header 恒为 3 行且首行恒是 PIN 见证行**；
  若哪次改动把 `SINK_CHECK`/`SINK_LIMITS` 挪走或再加一行 header，新行就会挤进 head-3、把首个 `SINK_CONN` 挤出去
  （`mktable*.py` 会拿到空串）。⇒ 建议：把这条写进 sink 的"新字段一律追加行尾"惯例那一行旁边。

**未证**：我没有**实跑**这些解析器（它们吃历史档，本刀还没部署/没产物）—— 上面是**源码级**核。

---

## D. 自检门 `gate_sinkfix.py` **有没有瞎**

### D.0 先复现作者的结论（我独立重跑，非采信）

```
$ python gate_sinkfix.py ../../../_proj_pcie/p7b_biz/p7b_tcp_sink.cpp
... 10 条全 OK；GATE_SINKFIX checks=10 ok=10 violations=0；RC=0          ← 与 gate_positive.txt 逐字相同
$ python run_gate_controls.py
P RC=0 / N0 fired=C1..C10 / M1 fired=C2 / M2 fired=C9 / M3 fired=C6,C7,C8 / M4 fired=C3,C4,C5 / M5 fired=C2
GATE_CONTROLS cases=7 mismatch=0；RC=0                                   ← 与 gate_controls.txt 逐字相同
```
（注：本机 `python` 不在 PATH，须用 `/c/Users/zhxue/anaconda3/python.exe` —— 交付报告没写这个前提，我踩了一次；
登记给下游照抄用。）

### D.1 ⭐ 我自己造的 **7 个"应当红"突变**：**4 个全绿（门的盲区）**

突变件全部生成在 `%TEMP%`（`sinkfix_adv*/`），**未碰任何仓内文件**：

| 突变 | 生成逻辑（对工作树现件） | 语义 | 门的结果 |
|---|---|---|---|
| **A_unguard_before** | 把 `if (!rcvbuf_after_connect)\n setsockopt(…)` 换成 `if (!rcvbuf_after_connect)\n ;\n setsockopt(…);`（**变成无条件、在 connect 之前**） | 默认臂仍对，但**旧臂也变成"在前设"** ⇒ `--rcvbuf-after-connect` **不再是旧行为**；而见证行照样打 `after_connect_LEGACY`（**见证说谎**） | **RC=0，无 VIOLATION（全绿）** ❌ |
| **C_fix_disabled_if0** | `if (!rcvbuf_after_connect) { if (0) setsockopt(…); }` | **修复被静默禁用**（默认臂 = 旧行为），token/文本次序/计数**全都没变** | **RC=0（全绿）** ❌ |
| **B2_witness_const_ternDEAD** | printf 的取值换成常量 `"before_connect"`，同时把三元字面量留在 `if (0) {…}` 死码里 | **见证恒报修复臂**（旧臂也报 before_connect）；C7 要的那个字面量仍在 | **RC=0（全绿）** ❌ |
| **F_forces_fixed_arm** | 调用点前插一行 `rcvbuf_after_connect = false;` | `--rcvbuf-after-connect` 被接住但**永不生效**（旧臂静默变修复臂） | **RC=0（全绿）** ❌ |
| D_empty_branch（派单①） | 分支体换空（只留第二个 setsockopt） | 修复消失 | RC=1，fired=**C2,C3** ✅ |
| E_witness_strings_swapped（派单③） | 三元里两个臂名**互换** | 见证语义翻面 | RC=1，fired=**C7** ✅ |
| B1_witness_const_ternDEL | printf 打常量 + 三元字面量**删除** | 同上但字面量没了 | RC=1，fired=**C7,C8** ✅ |

**盲区的共同形状（一句话）**：门检查的是 **token 的存在、位置次序与行数**，**不检查"哪个条件守哪个调用、以及它是否真的会执行"**。
- 突变 A/C 都保留了 `if (!rcvbuf_after_connect)` 字样（喂 C2 的 `gb`）、保留了 `setsockopt` 字样在 `gb` 与 `cn` 之间
  （喂 C2 的 `s1`）、保留了恰好 2 行 `setsockopt(…SO_RCVBUF…)` 且在函数体内（喂 C3）⇒ **C2/C3 的"次序+计数"全部满足，而语义已翻/已死**。
  ⭐ 对照：作者的 **M1（guard 对调）** 会被 C2 抓住 —— 因为它**动了 guard 文本**；我的 A 保留 guard 文本 ⇒ 从 C2 底下走过去。
  ⇒ **C2 的盲区 = "文本次序"代替"条件语义"**。
- 突变 B2/F：C6/C7/C8/C9/C10 全是**字面量存在性**检查（`in src`），没有一条把"打印出来的值"与"实际驱动 syscall 的值"
  绑在一起。B2 甚至不需要 F：**C7 与 printf 可以各自独立存在**。
  ⇒ **见证类判据（C6–C8）的盲区 = 无法区分"这段三元存在于文件里"与"它被打印了 / 它与生效路径同源"**。
  ⭐ 这与本工程自己的纪律冲突（"见证行必须与**生效值**同源"、#"注入过 ≠ 测到了"）—— 建议 TL 把这条写成同族。

**我给这三条盲区的定位**（避免误伤）：门的**声明作用域**是"源码结构里那条修复是否真的在位"（其头注释自述），
所以严格说 A/C/F 属于"作用域边界外"。**但**：交付报告 §4(a) 把 10/10 + 7 对照写成「**这是本机能跑到的最强判据**（源码层）」，
而一个读者读到 10/10 时的自然理解是"修复在位、旧臂保真" —— **A/C 两件正是打破这两条理解的输入**。
⇒ 要么在报告/台账里明确写「本门**不判**：修复是否真的会执行、旧臂是否保真、见证打印值是否与生效值同源」，
要么补 2–3 条能抓住 A/C 的判据（例如：要求 `if (!rcvbuf_after_connect)` 的**下一个语句就是**该 setsockopt 且无嵌套条件；
要求 printf 的实参**逐字等于**那个三元；要求调用点实参逐字等于 C4 的串 **且**该串之外无对 flag 的再赋值）。

### D.2 `run_gate_controls.py` 的 M4「真回退」生成逻辑（派单点名）

【事实】生成逻辑逐字如下（`run_gate_controls.py:59-65`）：

```python
def mutant_true_revert(s):
    t = s.replace("int fd = sink_connect_rcvbuf(host, port, 5, rcvbuf, rcvbuf_after_connect, &why);",
                  "int fd = p7b_io_connect_to(host, port, 5, &why);", 1)          # ① 调用点换回
    t = t.replace("        if (c == 0) first_conn_at = t1;",
                  "        if (c == 0) first_conn_at = t1;\n"
                  "        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));", 1)   # ② 旧点位恢复
    return t
```

**判决：降级（标签过度）**。
1. 它是**行为回退**（跑起来的 syscall 次序 = HEAD）—— 这一层属实 ✅。
2. 但它**不是"真回退"**：helper 仍留、见证仍留 ⇒ 它同时制造了"**第 3 处 setsockopt**"（被 **C3** 抓住）
   与"**`--rcvbuf-after-connect` 已无效果却仍打 after_connect_LEGACY**"（见证说谎）。
   真回退 = **N0**（`git show HEAD:` 全文）—— 作者已有 N0，所以覆盖不缺；**缺的是"只撤行为、不留痕"那一型的对照**。
3. ⇒ 建议：把 M4 改名「**行为回退 + helper 残留**」，或补一个「调用点回退、helper 删除、见证行删除、main 恢复 `:306`」
   的**最小行为回退**突变（那才是"把修复撤了"的干净形态，且它应当**只**被 C4/C5 抓住）。

### D.3 门自身的两个实现细节（我读出来的，供加固）

- 【事实】`extract_fn_body` 用 `src.find("\n}\n")` 截函数体 ⇒ 依赖"函数体内**没有独占一行的 `}`**"。
  当前成立（体内全是一行式 `{ … }`）。⚠️ 若有人把某分支写成多行块，C2/C3 的"体内"判定会**提前截断**（可能假红/假绿）。
- 【事实】去注释是**行内 `//` 截断**（`ln.split("//")[0]`）。我**独立复算**过"本文件的 `//` 是否都在注释里"
  （逐行数 `//` 之前的未转义引号个数，奇数 = 疑似串内）⇒ **0 行命中**，与门作者的自述一致 ✅。
  ⚠️ 但这是**文件级不变式**，不是门判据：将来在 printf 里写 `"a//b"` 会让该行**后半被吃掉**（例如把 `SO_RCVBUF` 吃掉 ⇒ C3 假红）。
  登记为既存脆性。

---

## E. 代码级核（类型 / 未初始化 / 泄漏 / include 前提 / 线程位置）

| 项 | 结论 |
|---|---|
| include 前提（4 个头） | 【事实】**逐个符号核过**：`P7bPat`/`p7b_check_mode_parse`/`p7b_check_mode_name`/`p7b_pattern_selftest`/`p7b_pattern_equiv_selftest` 在 `p7b_pattern.h`；`p7b_pin_cpu`/`p7baff_g_want_pair`/`p7baff_g_pair_active`/`p7baff_g_pair_cpu`/`p7baff_pin_self_thread`/`p7baff_work_freq_tick`/`p7baff_work_freq_khz` 在 `p7b_affinity.h`；`P7bSpscRing` 在 `p7b_spsc.h`；`p7b_io_*` 全套在 `p7b_io.h`。新代码**没有**引入新的外部符号（只用 `<sys/socket.h>` 的 `setsockopt/SOL_SOCKET/SO_RCVBUF`、`<arpa/inet.h>` 的 `inet_pton`、`<cerrno>` 的 `EINVAL`、`<unistd.h>` 的 `close` —— 全部已由既有 include 提供）。 |
| 未初始化 | 【事实】`struct sockaddr_in a{}` 值初始化（与 HEAD 逐字相同）；`rcvbuf_after_connect` 有初值 `= false`；`*why` 在所有失败路径必被写（§A.1）。 |
| 资源泄漏 | 【事实】三条失败路径都 `close(fd)`；成功路径 fd 由 main 在 `:437` 统一 `close(fd)`。**无新增泄漏**。 |
| 类型 / 溢出 | 【事实】`rcvbuf` 是 `int`（`atoi`），`setsockopt` 收 `&rcvbuf` + `sizeof(rcvbuf)`，与 HEAD 逐字一致；`htons((uint16_t)port)` 同 HEAD；`secs*1000` 与 HEAD 同源（§A.1）。 |
| UB / 编译期风险 | 【事实】未发现。`bool` 是 C++ 关键字；helper 是 `static`（无链接问题）、定义在 `main` 之前；`setsockopt` 返回值被忽略 —— **与 HEAD 同款**，且部署编译行 `g++ -O3 -pthread`（`BUILD.md §2`）**无 `-Werror`** ⇒ 不构成编译阻断。 |
| 建连相对线程 spawn | 【事实】**在 spawn 之前**（`:359` vs `:387-388`）；且该行在 `if (threaded)` 之外 ⇒ **双线程与 `--no-thread` 两路径落点一致**（派单要求的"两路径都要核" ⇒ 已核，两路径是同一个调用点）。 |
| 近拷贝的漂移风险 | 【推断】`p7b_io.h` 那条 `p7b_io_connect_to` 之后若被修改/修缺陷，本 .cpp **不会跟随**（无编译期强制）。报告已如实声明"留给 TL 裁定" ⇒ 我同意，登记为**残余风险**（不是缺陷）。 |

---

## F. 与派单/报告描述**不符**或需订正之处（逐条）

1. **派单说"新助手在 `--rcvbuf-after-connect` 臂下是否真的与旧路径一模一样（含失败路径）"** —— 【事实】socket 级**一样**；
   但有 **1 处非 socket 级微差**（§A.2：末尾 setsockopt 相对 `now_s()`/`first_conn_at` 的位置 ⇒ `conn_ms` 口径位移）。
   ⇒ "逐字复现"应降级为"首窗语义逐条相同 + 一处已量化的 `conn_ms` 微差"。
2. **报告 §1.1/§2.1/§6-① 的"握手完成 ACK 也带默认大窗"** —— 【未证】（唯一直接读数在 Windows 演示里是 255 小窗）⇒ 降级为推断。
3. **报告 §3.3 的演示口径** —— 【事实】演示**不是**在 sink 上做的（Python 合成 client/server），
   而派单 §2(B) 明写的判据是「**本机回环上跑一对 sink/src**，看**首个 ACK 的 win**」。
   交付件对"做不到"给了理由与上板判法（符合派单的兜底句），但**替代演示覆盖不到被点名的观测**（首个 ACK 在旧臂读到的是 255 ≠ 大窗）。
   ⇒ 这一格写「**派单判据未达成、已按兜底条款换成机制演示**」更准确。
4. **报告 §2.2 "函数体 17 行"** —— 【事实】我数出来函数体 = **16 行**（`:225-240`；含末行 `}` 是 17）。无实质影响，仅供逐字核对。
5. **报告 §6-② 的 BUILD.md 失配归因** —— 【事实】**我独立复现了归因**：
   `git show e20b5bf:…/p7b_tcp_sink.cpp | md5sum` = `0574eca85cdb9060ac461e0270a365ee`（= `BUILD.md:128` 表值）；
   `git show aaf17dc:… | md5sum` = `5b6d757b17ed9b49db77c34494319264`（= HEAD）。⇒ 失配**先于本刀**、且"**从 e20b5bf→aaf17dc 改了未回填**"属实 ✅。
6. **报告 §6-⑥（tshark 布尔渲染为 `True/False`）** —— 【事实】该现象在 `win_loopback_run.log` 里可见（`wscale=-`、`_b()` 归一化）；
   我只复核了脚本里有归一化函数与其注释，**未复跑 tshark**（本机没有第二台机器做对照）。登记为【未证·低危】。
7. **报告的"实测 64240"** —— 我先判"仓内无出处"，**现核已找到锚**（`p7b_board_stagea/head_P0_r1.txt:2` + `ss_STG_P0_R1.log:2` 的 `rb131072`）⇒ **撤回我的初判，报告在此处属实**。
8. **环境观察（非本刀产物）**：审查过程中观察到工作树有**并发写者** —— 开头 `git status` 里
   ` M _proj_10g/notes/p7b_biz_tcpreg/tcpreg_program_stdout.txt` 在 12 分钟后自行消失（应为对端那支 agent 的动作）。
   至 19:40 为止，**全仓 tracked 改动只有本 .cpp 一件**（`63 +/−2`）⇒ 本刀的归因未被污染；
   但请 TL 知道：**此刻仓库里有别人在写**。

---

## G. TL 需要裁定的问题（我需要你拍板的格子）

1. **"逐字复现"的措辞**：接受我 §A.2 的降级（"首窗语义逐条相同 + 一处 `conn_ms` 微差"），还是要求把 setsockopt 挪回
   `if (c==0) first_conn_at` 之后以做到**文本级**逐字？（后者要把 flag 一路传回来、且会**破坏** C3 的"只在 helper 内"形状）
   —— 我建议**接受降级**（收益 0，代价是门与结构都变复杂）。
2. **"握手完成 ACK 也带大窗"这条子断言**：要保留为推断（我的建议），还是要**实证**？
   实证法 = 下轮对端 tcpdump 同时抓两臂的**握手 ACK**（不是只抓 SYN），看第一个 ACK 的 win 是大窗还是小窗。
3. **门要不要加固**：我给了 4 个全绿突变（A/C/B2/F）。是否授权**补 2–3 条判据**（并各配对照）把 A/C 纳入？
   还是**接受"门只判结构"并在报告里明确写清它不判什么**（我倾向后者 + 至少补一条"C7 必须与 printf 实参同源"，
   因为它成本最低、且直击本工程"见证必须与生效值同源"的纪律）。⛔ **无论选哪条，请明示"10/10 OK"该被读成什么**。
4. **默认值翻面的两条口径纪律**（我建议写进台账）：
   (a) 凡与历史读数 A/B **一律显式带 `--rcvbuf-after-connect`**（TL 已立，我复核同意）；
   (b) **补一句**："即便 `--rcvbuf 8 MiB`，两臂首窗也不同（旧臂 64240 有实测锚；修复臂推断 65535）" ——
   并把"修复臂 = 65535"标为**待一次抓包**的推断，**不许**写成实测。
5. **`SINK_RCVBUF_ORDER` 落点**：它现在夹在 `SINK_LIMITS` 与首个 `SINK_CONN` 之间。我核过 `head -3`/`tail -6` 两个采集窗口**内容不变**
   （真实档 9 行组成推算）。要不要**顺手**把它挪到 `SINK_DONE` 之前（= 更不可能碰任何窗口）？—— 我建议**不动**（动了要重跑门），
   但把"C.3 的边界条件"写进 sink 的行尾约定注释。
6. **同族未修件的处置**：`p7b_tcp_sink_rate.cpp`（`:127/:136`）是**已归档轮次的产物源**；TL 已判"暂不同刀"。
   我要确认的是：**那件参与过的历史读数是否有需要"作废/加注"的**（例如 Stage C 的 `--nocheck` 台架帽对照臂）——
   这属**证据审计**，不在我的可写范围。
7. **两个 agent 的产出如何合流**：我这份只报"本机可判"的部分（源码/结构/接口）；另一支（对端编译 + 回环真判据）落地后，
   建议在台账里把「结构性判据」与「行为判据」**分列**，不要把两边的绿灯合并成一个结论。

---

## 附：本次审查用到的命令与原始输出（可复算）

```bash
# 改动归属（19:40）
git -C /d/repo/XCKU5PMini/udp_hls_10g diff --numstat HEAD        # -> 63  2  _proj_pcie/p7b_biz/p7b_tcp_sink.cpp（唯一一件）
md5sum _proj_pcie/p7b_biz/p7b_tcp_sink.cpp                       # -> 8d02ef6426d4ef6ad5fd2c514965c1e8（与报告一致）
git show HEAD:_proj_pcie/p7b_biz/p7b_tcp_sink.cpp | md5sum       # -> 5b6d757b17ed9b49db77c34494319264（与报告一致）
grep -n "p7b_io_connect_to" _proj_pcie/p7b_biz/p7b_tcp_sink.cpp  # -> 只有 :203/:216/:221 三处注释（活跃引用 0）

# 门：正件 + 作者 7 对照（逐字复现报告 §3.1/§3.2）
/c/Users/zhxue/anaconda3/python.exe gate_sinkfix.py ../../../_proj_pcie/p7b_biz/p7b_tcp_sink.cpp   # RC=0, 10/10
/c/Users/zhxue/anaconda3/python.exe run_gate_controls.py                                          # RC=0, mismatch=0

# 我自造的 7 个突变（临时目录，未碰仓内文件）
/c/Users/zhxue/anaconda3/python.exe %TEMP%/sinkfix_mut.py    # A RC=0 / C RC=0 / D RC=1(C2,C3) / E RC=1(C7)
/c/Users/zhxue/anaconda3/python.exe %TEMP%/sinkfix_mut2.py   # B1 RC=1(C7,C8)
/c/Users/zhxue/anaconda3/python.exe %TEMP%/sinkfix_mut3.py   # B2 RC=0 / F RC=0

# 工具链（独立证伪"本机无编译"失败）
/c/msys64/mingw64/bin/g++.exe --version                      # -> g++.exe (Rev5, ...) 16.1.0（能起）
/c/msys64/mingw64/bin/g++.exe -o t.exe t.c; echo $?          # -> RC=1，零输出，无产物（与报告一致）
find /c/msys64 -name socket.h -path "*sys*"                  # -> 0 命中
```

**（本文件不含任何 PASS/FAIL 裁定；`p7b_io.h` 与 `.cpp` 我只读未改；上述突变件全部在 `%TEMP%`。）**
