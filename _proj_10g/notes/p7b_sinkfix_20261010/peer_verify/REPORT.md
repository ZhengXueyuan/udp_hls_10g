# peer_verify —— `p7b_tcp_sink` sinkfix（SO_RCVBUF 落点）在真 Linux 栈上的编译与首窗通告判据

> **落盘说明（TL）**：本件由 **TL 代 agent 落盘** —— agent 侧 harness 拒写 `.md`（本工程当日第三次同故障），其最终回复给的即以下全文，**正文未改一字**。TL 的核查与追加批注见文末。

> 角色：测试/验证 agent。**零板卡 / 零 Vivado**：全程只走 `tools/peer_ssh.py` → 对端 `192.168.0.38`。
> ⛔ 不下 PASS/FAIL 裁定；不写"已收口"；"未观测到"一律不写作"不存在"。
> 工作台：对端**新建** scratch `/tmp/sinkfix_verify/`；**未改** `/tmp/p7b_biz/`（收尾 md5 逐字复核）。
> ⭐ 固定句（派单要求）：**核到与我的描述不符就如实说、不迁就** —— 本轮确有两处不符，见 §6.1。

## 0. 摘要（事实，≤25 行）

1. **编译过了**：`g++ -O3 -pthread -o p7b_tcp_sink p7b_tcp_sink.cpp`（BUILD.md §2 配方）⇒ **RC=0，stdout/stderr 全空（零 warning）**；产物 **169,392 B**，md5 `6d9b14f24725fa326ffe5b169f77e30f`；`--selftest` ⇒ `SELFTEST p7b_tcp_sink: OK`。
2. **对端可达**：user `a`（key 免密），内核 **7.0.0-38-generic**；g++ 13.3.0 / tcpdump 4.99.4 / python3 / ss 全在。sudo 需密码 ⇒ 抓包脚本整体 `--sudo`（root），**sink 与服务端用 `runuser` 降权到 user a**。
3. 上传 **5 源件 + 3 脚本**，**双侧 md5 逐件一致**；`p7b_tcp_sink.cpp` = `8d02ef6426d4ef6ad5fd2c514965c1e8`（与派单值一致）。
4. 旧件→新件 diff = **+63/−2 行**（61 实质 + 2 空行；删 2 行 = 旧 `p7b_io_connect_to` 调用 + 旧 `setsockopt`）⇒ 与派单描述的 "+63/−2" **逐数吻合**；4 个头文件与现役**逐字相同** ⇒ **唯一变化的输入 = 那个 .cpp**。
5. **首窗判据（判然有别 ✅）**：两臂同二进制只差一开关，lo 回环、同一会话紧挨着跑：**臂 A（默认=修复后）SYN.win = `2920`**（客户端 `wscale 0`；后续 2920/2916）；**臂 B（`--rcvbuf-after-connect`=旧行为）SYN.win = `65495`**（客户端 `wscale 10`）。
6. **独立见证（`ss -tinme`）**：两臂客户端 `skmem rb` **都是 5840**（=2920×2，落点都落了），但对端 `snd_wnd` = **2916**（修复臂） vs **65536**（旧臂）⇒ ⭐ **决定线上窗口的是"落点"，不是缓冲值**。
7. ⛔ **与派单期望不符 1**："旧臂…之后才塌到小量级" —— **本次未观察到任何塌**：旧臂 +0.5 s ACK 与 FIN 上窗仍 raw 64 ×2¹⁰ = **65536 B**（`ss snd_wnd:65536` 独立复核）；对照臂（事后设 **204800**）也**没**落到窗口 ⇒ 事后设值**两个方向**都没反映到通告窗。
8. ⛔ **与派单期望不符 2（取证陷阱）**：**首轮** pcap 只写进 3/6 个包（FIN 未落盘；tcpdump 自报 `12 received by filter / 3 captured / 0 dropped`）。判据不受影响（SYN/ACK 都在），但"抓了 6 个包"是假象；kill 前等待 0.4 s→3 s 后收尾包正常落盘（8/8）。
9. 见证行 `SINK_RCVBUF_ORDER RCVBUF_ORDER=before_connect|after_connect_LEGACY rcvbuf=2920` **两臂都在**。
10. `--help | head -40`：新开关在 usage 里；**新见证行是独立新增行**，`SINK_CHECK`/`SINK_LIMITS` 的**文本与相对顺序一字未动**（文本层+运行期双证）。
11. 口径补一条：本构型（服务端**零载荷**）`mism_bytes=0`、`checked_bytes=0` ⇒ 派单说的"必然失配"在指定两臂里**不存在**（失配只出现在我加的补充探针里）。
12. 收尾核验：`/tmp/p7b_biz/` 5 件 md5 测前测后**逐字相同**；两臂 pcap 本地 sha256 与对端记录**逐字相同**；三份 raw stdout 的本轮独有 nonce 全命中；本地落地件 mtime 均=本会话时刻。

## 1. 步骤 1：上传 + 编译（原始输出）

### 1.1 上传（8 件，扁平目录）
5 源件：`p7b_tcp_sink.cpp` / `p7b_io.h` / `p7b_pattern.h` / `p7b_affinity.h` / `p7b_spsc.h`；3 脚本：`mini_server.py` / `run_ab.sh` / `parse_pcap_tcp.py`。

双侧 md5（逐件一致）：
```
8d02ef6426d4ef6ad5fd2c514965c1e8  p7b_tcp_sink.cpp    <- 与派单一致
62b1257d69c40f24bfa9a799593073b7  p7b_io.h
b2f2e9627bac53bf3b4ab2b565afe872  p7b_pattern.h
b03222792d20443138515ba2804b0d87  p7b_affinity.h
3132db495c29ab85b7f6a5617803644f  p7b_spsc.h
8563e17456255ff1f51ad71a7c76da88  mini_server.py
e3d3aa7ec8b04fec0655398a204ffc76  run_ab.sh
198a61039c732901c871c0560c55942b  parse_pcap_tcp.py
```
diff 统计（`diff_deployed_vs_sinkfix.txt`）：`added_total=63 (空行 2, 非空 61)` / `removed_total=2` / 8 hunks；`SINK_CHECK`、`SINK_LIMITS` 两行旧 265/271 → 新 318/324，**文本逐字相同**（现役 .cpp 仅行号移位）。

### 1.2 编译（`compile_recipe.log` 全文）
```
=== recipe compile 2026-10-10T19:36:32+08:00 g++ (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 ===
CMD: g++ -O3 -pthread -o p7b_tcp_sink p7b_tcp_sink.cpp
COMPILE_RC=0
```
冒烟：`SELFTEST p7b_tcp_sink: OK`（RC=0；绑核门通过 `PIN_CPU=5`、`PIN_PAIR_REQ=want`）。

## 2. 步骤 2：首窗判据（派单设计的纯握手 A/B）

环境（同脚本内现取）：`7.0.0-38-generic`；`tcp_rmem = 4096 131072 33554432`；`rmem_default = 212992`；`rmem_max = 4194304`；`tcp_window_scaling=1`、`tcp_adv_win_scale=1`、`tcp_moderate_rcvbuf=1`。

两臂（同二进制，服务端 = `mini_server.py`，`127.0.0.1:39017`，accept 后只 sleep 8 s 不放数据；`tcpdump -i lo -nn -s 0 -U -w ... "tcp port 39017"`，跑完 `kill -INT`）。

**臂 A（默认=修复后）全 3 包文本：**
```
19:37:01.178612 127.0.0.1.38160 > 127.0.0.1.39017: Flags [S], seq 1608151521, win 2920,
   options [mss 65495,sackOK,TS val 3774867524 ecr 0,nop,wscale 0], length 0
19:37:01.178622 127.0.0.1.39017 > 127.0.0.1.38160: Flags [S.], seq 244565698, ack 1608151522,
   win 65483, options [mss 65495,sackOK,TS val 2559028260 ecr 3774867524,nop,wscale 10], length 0
19:37:01.178631 127.0.0.1.38160 > 127.0.0.1.39017: Flags [.], seq 1, ack 1, win 2920,
   options [nop,nop,TS val 3774867524 ecr 2559028260], length 0
```
裸字段：`PKT1 SYN win_raw=2920 wscale=0` · `PKT2 SYN-ACK win_raw=65483 wscale=10（服务端自己的窗，非本判据对象）` · `PKT3 ACK win_raw=2920`。`PCAP_A_SHA256=26fc652aef0776c8a99fe05dd3a76d2a951d0a147f1eef0b48f533874aa0bb46`

**臂 B（`--rcvbuf-after-connect`=旧行为）全 3 包文本：**
```
19:37:09.835740 127.0.0.1.54984 > 127.0.0.1.39017: Flags [S], seq 1223112301, win 65495,
   options [mss 65495,sackOK,TS val 1462985245 ecr 0,nop,wscale 10], length 0
19:37:09.835750 127.0.0.1.39017 > 127.0.0.1.54984: Flags [S.], seq 1247173578, ack 1223112302,
   win 65483, options [mss 65495,sackOK,TS val 1420268313 ecr 1462985245,nop,wscale 10], length 0
19:37:09.835758 127.0.0.1.54984 > 127.0.0.1.39017: Flags [.], seq 1, ack 1, win 64, options [nop,nop,...], length 0
```
裸字段：`PKT1 SYN win_raw=65495 wscale=10` · `PKT3 ACK win_raw=64`。`PCAP_B_SHA256=efb594e6ffb55c2e1b1f949ded4ab910d1abc4a1260f092eb547c78bed7056b8`

见证行（两臂 stdout 第 4 行）：
```
SINK_RCVBUF_ORDER RCVBUF_ORDER=before_connect rcvbuf=2920
SINK_RCVBUF_ORDER RCVBUF_ORDER=after_connect_LEGACY rcvbuf=2920
```
（行序 = `PIN_RULE=...` → `SINK_CHECK check=seq` → `SINK_LIMITS ...` → **新增** `SINK_RCVBUF_ORDER ...`。）
两臂自报：`bytes=0 / checked_bytes=0 / mism_bytes=0 / clean_conns=1`；⚠️ **`SINK_RC=1` 不是故障**（源码 :475 `return (bad_conns==0 && fail_conns==0 && tot_bytes>0) ? 0 : 1`，零载荷必然 RC=1）。

## 3. 补充探针（**非派单指定**，为回答两个遗留问题）

`probe_collapse.sh`（服务端 **+0.5 s 发 4 字节** ⇒ 客户端 ACK 携带 setsockopt **之后**的通告窗）与 `probe_control.sh`（加 `ss -tinme` 见证 + 204800 对照臂）。

裸字段（4 包以后，完整 8 包见 pcap）：
```
A2 (before_connect , 2920): SYN 2920  | ACK 2920 | [srv PSH 4B] | ACK 2916 | FIN(srv) | FIN(cli) 2916
B2 (after_connect  , 2920): SYN 65495 | ACK 64   | [srv PSH 4B] | ACK 64   | FIN(srv) | FIN(cli) 64
C3 (after_connect  , 204800): SYN 65495 | ACK 64 | [srv PSH 4B] | ACK 64   | FIN(srv) | FIN(cli) 64
```
`ss -tinme` 抽样（+1.2 s，连接存活中；**独立于 tcpdump**）：
```
A3 客户端: skmem:(r0,rb5840,...)   wscale:10,0   | 服务端: snd_wnd:2916
B3 客户端: skmem:(r0,rb5840,...)   wscale:10,10  | 服务端: snd_wnd:65536
C3 客户端: skmem:(r0,rb409600,...) wscale:10,10  | 服务端: snd_wnd:65536
```
⇒ 缓冲落位（5840/5840/409600）与线上窗口（2916/65536/65536）**解耦**，解耦变量 = 落点。

包计数（回答"FIN 去哪了"）：
```
首轮 (kill 前 0.4 s): 3 captured / 12 received by filter / 0 dropped   <- 6 唯一包只写进 3
补充轮 (kill 前 3.0 s): 8 captured / 16 received by filter / 0 dropped  <- 8/8 落盘（含 FIN 三连）
```
（首轮臂 B 记 14 received = 7 唯一包，比臂 A 多 1 个；**那 1 包从未落盘、内容不可考**，登记为未解释。）

## 4. 步骤 3：`--help` 与见证行健壮性

`help_head.txt` 关键行：usage 第 3 行含 `[--rcvbuf-after-connect] [--check seq|lane8]` ✅；usage 明细含新开关的说明行（含 "默认 = connect **之前**设 [修复后]" 与 "两臂见证行 = SINK_RCVBUF_ORDER = ..."）。"没塞进既有解析接口"双证：文本层（两行逐字相同、diff 无 `-` 行触及）+ 运行期（行序见 §2）。

## 5. 【事实】/【推断】分离

**【事实】** F1 编译 RC=0/零 warning/`--selftest` OK。F2 两臂 SYN 窗 2920 vs 65495，判然有别。F3 同 rcvbuf 两臂 `rb` 都 5840，但 `snd_wnd` = 2916 vs 65536。F4 旧臂 raw 64 出现在 3rd ACK/数据 ACK/FIN（+0.5 s 之后仍未变小）；64×2¹⁰=65536 的解释**有独立 oracle**（同一时刻服务端内核 `snd_wnd:65536`），不是我的换算假设。F5 对照臂（204800）线上窗仍 65536。F6 首轮 3/12，长尾轮 8/16；两臂 pcap 本地 sha256=对端记录。F7 `/tmp/p7b_biz/` 5 件 md5 测前测后逐字相同。

**【推断，未读内核源码】** I1 修复臂 2920 的来历：×2=5840（`rb` 实测）÷2（adv_win_scale=1）=2920，恰等于请求值。I2 旧臂默认大窗的来历：新 socket `sk_rcvbuf` = `tcp_rmem[1]`=131072（由"折半=65536"反推）⇒ 窗 = min(65535,65536)=65535 → 按 MSS 65495 量化 = 65495。I3 旧臂"不塌"的机制候选：① 内核**不缩已通告的窗**（RFC 1122）+ ② 窗口增长受 `rcv_ssthresh`/`window_clamp`（建连时定死、需数据流才放行）——两者都能解释 F4 **与** F5，**本测量不能区分**。I4 历史台架数 **64240** 与本次 **65495** 同源（同为 `min(65535,space)` 的 MSS 量化值：64240=44×1460；65495=1×65495 loopback）⇒ 量级结论可迁移，**绝对数字是 loopback 专属**（全程 lo，MSS 65495）。

## 6. 如实回答派单的 5 个问题

**① 编译过了吗？** 过了（RC=0、零 warning、md5 `6d9b14f2…`、`--selftest` OK）。未另跑 `-Wall`（配方编译已零输出；派单只要求"有 warning 就记"）。
**② 对端可达吗？** 可达。一处差异如实登记：sudo 需密码 ⇒ tcpdump 以 **root** 跑，**sink/服务端 `runuser` 降权到 user a（uid 1000）**（与常规台架身份一致）；**未**触发绑核硬门（`PIN_CPU=5`/pair io=4,work=7），**没有**用 `--no-pin`。
**③ 两臂 SYN.win 各是多少？** 修复臂 **2920**（raw；wscale 0 ⇒ 有效亦 2920）；旧臂 **65495**（raw；wscale 10）。旧臂后续包 raw **64** ⇒ 有效 **65536**（对端 `snd_wnd:65536` 复核）。量级口径只在"几千 vs 六万多"，不把"=2920"当普遍结论（本次是 ×2/÷2 抵消的巧合）。
**④ 判然有别吗？** **是**：SYN 窗 2920 vs 65495，且"对端被授权发多少" = `snd_wnd` 2916 vs 65536。
**⑤ 有没有"看起来做了但其实是空跑"？** 两处，都抓到并留判据：(a) **首次上传全部失败** —— Git Bash 的 MSYS 路径转换把远端参数 `/tmp/...` 改写成 Windows 路径（`FileNotFoundError`），响亮失败后加 `MSYS_NO_PATHCONV=1` 重传并双侧 md5 复核；(b) **首轮 pcap 少了收尾包**（`3 captured / 12 received`）—— 命令执行了、判据对象也真抓到，但"6 个包"是假象，靠 tcpdump 自报计数发现并做长尾对照轮复现。**规程含义：`kill` 结束的抓包不能只看"文件在"，要核 `captured == received/2`（lo 双计数）**。其余所有件均过"本轮独有 nonce + mtime（19:41–19:42）"判据。

### 6.1 ⭐ 与派单/源码描述不符之处
1. **"旧臂…之后才塌到小量级"未再现**（F4/F5）：本栈上旧臂窗**全程 65536**，且缩/涨两个方向都未见事后设值落到窗口。⛔ 只能说"**本次未观测到塌**"，不能写"不存在塌"（未测：更长时间 / 有真实数据流 / 非 loopback 三种工况）。⇒ 对接下来的板级判读：本刀价值集中于**首个通告**；若要复现"微窗 stall"，**不能依赖"事后会塌"**，要靠 **SYN 就小**（修复臂形态）。
2. **"图案校验会必然失配"**：指定两臂服务端零载荷 ⇒ `mism_bytes=0`，**不存在失配**；该句只在"服务端发数据"构型成立（我放进补充探针里，那里确实失配，与判据无关）。
3. **`/tmp/p7b_biz/p7b_tcp_sink.cpp` 已 ≠ BUILD.md §3 输入指纹**（现役 `5b6d757b…` vs BUILD.md 记 `0574eca8…`，现役 mtime `2026-10-09 23:38:57`）⇒ 部署件在 BUILD.md 之后又被更新过；我的 diff 基准 = **现役件**。
4. **现役二进制 `c6b624205d64f1f4bd723d8fd5cc6414` ≠ BUILD.md §3 的 md5**（字节数同为 169,392）⇒ 与第 3 条同源；**只认 md5、不认字节数**。
5. 首轮臂 B 的 `received=14` 多出 1 个唯一包，**从未落盘、不可考** ⇒ 登记为未解释。

## 7. 边界与收尾核验
零板卡（未连 hw_server/未烧录/未启 Vivado）；仓库只读（未 git 操作、未改被跟踪文件、只新建 `peer_verify/`）；`/tmp/p7b_biz/` 测前测后 5 件 md5 逐字相同（见 §0-12 / §5-F7）；`PEER_PW` 只做命令前缀（`--sudo`），**未**写入任何文件/脚本/报告。

## 8. 原始件清单

| 文件 | 内容 |
|---|---|
| `mini_server.py` / `run_ab.sh` / `parse_pcap_tcp.py` / `probe_collapse.sh` / `probe_control.sh` | 脚本 |
| `compile_recipe.log` / `selftest.out` / `help_head.txt` / `help_err.txt` / `diff_deployed_vs_sinkfix.txt` | 编译、冒烟、help、全 diff |
| `arm_A.out` `.err` / `arm_B.out` `.err` | 两臂 stdout/stderr（含见证行） |
| `arm_A.pcap` / `arm_B.pcap` | 派单两臂原始抓包（sha256 见 §2） |
| `tcpdump_A.log` / `tcpdump_B.log` / `server_A.log` / `server_B.log` | tcpdump 自报计数（`captured` vs `received` 证据）、服务端日志 |
| `pc_A2.out` `.pcap` / `pc_B2.out` `.pcap` | 补充探针（发 4 B + 长尾） |
| `p2_A3.out` `.pcap` / `p2_B3.out` `.pcap` / `p2_C3.out` `.pcap` | 对照臂三件（含 204800） |
| `run_ab_raw_stdout.txt` / `probe_collapse_raw_stdout.txt` / `probe_control_raw_stdout.txt` | 三轮**全量 raw stdout**（sysctl/内核/见证/全部 tcpdump 文本/裸解析/`ss -tinme` 原文） |

---

## TL 核查批注（TL 追加，**非交付件原文**）

**核查时点**：2026-10-10，HEAD = `4614f17` + 本轮 3 笔（`363b211`/`ed9fe88`/`61cc107`）。

### A. 事实核查（TL 独立现核）

| # | 断言 | TL 现核 |
|---|---|---|
| 1 | 编译 RC=0、零 warning | ✅ `compile_recipe.log` 逐字（`COMPILE_RC=0`） |
| 2 | 两臂见证行在位 | ✅ `arm_A.out`/`arm_B.out` 各含 `SINK_RCVBUF_ORDER`（两臂取值不同） |
| 3 | `rb` 两臂都落位、线上窗解耦 | ✅ `probe_control_raw_stdout.txt` 原文：客户端 `rb5840`（两臂）而 `rcv_space:2920`（修复臂）vs `rcv_space:65495`（旧臂/对照臂） |
| 4 | 取证件齐、mtime = 本次 | ✅ 37 件、mtime 19:35–19:42 |
| 5 | 本刀唯一变化输入 = 那个 .cpp | ✅ diff 显示 4 个头逐字相同 |

### B. ⭐⭐ 一条 TL 级**机制推断**（本件 §6.1-1 未点透的那一层）

本件观察到"旧臂窗**不塌**"，并把它归为"本测量不能区分的两个候选机制"。TL 补一条**第三个、更简单**的解释，**标为推断、待测**：

> **通告窗 ≤ 实际空闲接收缓冲**。探针只有 4 B 载荷 ⇒ 5840 B 的缓冲**从未被填**⇒ 窗**结构上无从塌起**。
> 真构型（板持续突发 ~33 帧 × 1460 B ≈ 48 KB）会**把 5840 B 的缓冲填满** ⇒ 窗**必须**关到 0。
> ⇒ **"塌"不是靠某种内核主动收缩，而是靠"缓冲被填满"这个物理事实**；本探针的零载荷构型**观测不到它**。
> ⚠️ 这条与 §3 的 C3 对照臂（204800 也没落到窗口）**相容**：C3 的缓冲同样没被填 ⇒ 同样看不见。
> **可判定法**（成本低）：走同一台架，服务端**持续灌 ≥4×rcvbuf 的字节**、客户端不读 ⇒ 看窗是否关到 0；两臂都做。

### C. 裁定

1. **编译缺口 = 已关**：这份 .cpp 现在**编译过、零 warning、`--selftest` 过**。
2. **首窗判据 = 已达成**（派单点名的观测量，真 Linux 栈）：修复臂 `SYN.win = 2920`（小）vs 旧臂 `65495`（大）—— **判然有别**，且由 `ss -tinme` 独立复核。
3. **⛔ 不开新的**：本件**未**证明"微窗 stall 的复现路径"已被保住（见 §B）；也**未**跑过板级。⇒ **结构性判据（`REPORT.md`/`REVIEW.md`）与行为判据（本件）分列，不许合并成一个结论**。
4. **`--rcvbuf-after-connect` = 正控场景**这条纪律**继续有效**，并**加强**：凡要复现历史小窗构型，**必须显式带该开关**。
5. **第三、四次独立复现的 BUILD.md 指纹失配**（本件 §6.1-3/4：部署源码 + 部署二进制双失配）⇒ 与 TL 先前的归属（`e20b5bf` 写入 → `aaf17dc` 未回填）**同源**，待下次构建整表刷新。
