# P7B_LATENCY_GAPS.md —— `P7B_LATENCY.md` 两个缺口的归因 + 补测方案

> 2026-09-30 · 只读调查 (未改任何 RTL / 既有笔记 / 未烧板 / 未跑仿真综合 / 未动 git)。
> 主材料 `_proj_10g/notes/P7B_LATENCY.md`；本文只回答它留下的两个缺口，**不复制它的数字**。
> 标记沿用其口径: **【读得】**=有原始读数 · **【读RTL】**=逐行读 RTL 得到 · **【推算】**=由已证事实算出 · **【未核实】**=没证据。
> ⚠️ 缺口一我**独立重算过**读数 (自己解 `run{1,2,3}_stdout.txt` 的 6×128 位探针, 不是照抄报告):
> **94 个样本里 `evt_d / dp_d_r / evt_d2 / evt_cf` 恒 0** (报告说 64 个 —— 数量口径不同, 结论一致)。

---

## 0. 结论速览 (先给判词)

| # | 问题 | 判词 |
|---|---|---|
| **缺口一** | `(d)` tap 恒不触发 | **归因 = 激励, 不是接线**。tap 接得对、线接得到位 (四条证据), 但**当时的激励 (IPv6 ICMPv6) 在 RTL 上结构性不可能满足触发条件**。**不需要改 RTL** —— 缺的是**一个真 IPv4/UDP 帧** |
| 缺口一 · 要什么 | 触发所需的激励 | 对端机往板子发**一个** UDP 报文到 `192.168.100.2:8081`。但该帧必须是**从 SFP 口 (enp1s0f1np1) 出去**的 —— 而该口**没有 IPv4 地址** (只有 `fe80::…` /64) ⇒ **对端机 root 是硬前置**, 且**只加地址不够** (还要一条 `/32` 路由, 见 §1.6) |
| **缺口二** | fast path → app 队列 未测 | 链路已查清: `rx_classify.fast → tcp_rx → pay_* → tcp_echo(8K×73b 帧 FIFO) → axis_pipe(1 拍) → app_rx_*`。**终点信号** = `tcp_echo` 里帧末字写进 FIFO 那一拍 (现成计数器 `stat_tlast_wr`)。要测**必须加探针 (改 RTL) + 重建**, 且**必须先过闸 4** (否则 10G 上没有可用的 TCP 通路)。**不需要对端机配合接线**, 但**同样需要 root** (TCP 会话要求对端 SFP 口拥有 IPv4 地址) |
| 合计口径 | 已量到的段能不能覆盖全程? | **不能。**固定流水全覆盖 (a→b→c→e), 但 **(cf)→app 队列 零读数**、**(c)→(d) 零读数**、**L_PCS 零读数** (后两条 `P7B_LATENCY.md` §7 的 U1/U4/U5 已登记) |

---

## 1. 缺口一: `(d)` 那个 app tap 恒不触发

### 1.1 现象 (独立复核)

- `evt_d = 0`、`dp_d_r = 0` 于**全部 94 个样本** (3 轮 stdout + 1 轮副本; 我的解码脚本逐样本打印, 见文末 §4 复现命令)。
- 旁证同时为 0: `evt_d2 = 0`(app UDP RX 口 SOP)、`evt_cf = 0`(fast 支)。
- 非零的 5 个 tap 一切正常: `evt_a = evt_b = evt_vs = evt_c = evt_e = evt_e2` 逐样本相等 (配对判据成立)。

### 1.2 这个 tap 挂在哪根线上 (file:line)

| 环节 | 位置 |
|---|---|
| 探针输入端口 | `board/wrapper_p4.v:3800` `wire lat_dp_evt_d = u_udp_split.uf_commit_word;` |
| 接到本体 | `board/wrapper_p4.v:3824` `.dp_evt_d (lat_dp_evt_d)` → `_proj_10g/p7b_lat/rtl/p7b_lat_top.v:136`(端口) / `:290`(锁存) |
| 读出字 | `p7b_lat_top.v:79` `W10 = {evt_d[15:0], cal_evt[15:0]}` → `flat`(`:531`) → `lat_pi2`(放 `:522` 的 6 段拼装里) |
| 被 tap 的源 | `rtl/udp_split.v:491` `wire uf_commit_word = u_end && !u_uncrc && !u_abort_r && !uf_full;` |

**`uf_commit_word` 在本设计里是"有功能消费者"的活网**，不是观测专用的死线：
`rtl/udp_split.v:500-504` (`u_commit_evt → desc_wr` = 描述符 FIFO 写口) 与 `:516` (`uf_roll_req` 含 `u_commit_no`)
⇒ 它**决定了描述符队列入队与否**。这一条很关键：它排除了"这根本来就被优化掉"的可能 (见 §1.5)。

### 1.3 触发条件 (逐条, 全在 `(c)` 之后那一层)

`uf_commit_word` 的 4 个合取项:

| 项 | 条件 | 出处 |
|---|---|---|
| `u_end` | `u_m_v && u_m_l`：**UDP 支**的载荷末字被接受 | `rtl/udp_split.v:481-482` |
| `!u_uncrc` | FCS 好且无 rx_er | `:483` |
| `!u_abort_r` | 本帧没被"FIFO 满吞字"作废 | `:478/:484` |
| `!uf_full` | 帧缓冲 (512 字) 未满 | `:464-471` |

而 `u_m_v` 来自 `u_udp_rx.m_axis_tvalid` (`:432-441`)，**`udp_rx` 只在"匹配门"全过时才吐载荷**：

| 门 | 条件 | 出处 |
|---|---|---|
| 以太类型 | `w1[31:16] == 16'h0800` (**IPv4**) 且 `w1[15:8] == 8'h45` | `rtl/udp_rx.v:186` |
| L4 协议 | `w2[7:0] == 8'h11` (**UDP**) | `:187` |
| IP 校验和 | `fold16x(...) == 16'hFFFF` | `:177-178` |
| 目的 IP | `{w3_r[15:0], tdata[63:48]} == cfg_dst_ip` = **`32'hC0A86402` = 192.168.100.2** | `:180-181`; `board/wrapper_p4.v:2254` |
| 目的端口 | `cfg_port_any(=0)` 或 `dst_port ∈ {0x1F91=8081, 0xFFFF, 0xFFFF, 0xFFFF}` | `:182-185`; `wrapper_p4.v:2219/2256-2258` |
| UDP 长度 | `>= 8` | `:184` |
| 排除 | `dst/src port == 8080` 被 `EXCL_PORT` 反相排除 (留给 HLS udp_echo) | `udp_split.v:416-426` |

⇒ **`(d)` 只能被"目的 IP = 192.168.100.2 的 IPv4/UDP 帧"触发**。IPv6 一票否决 (在 `hdr_ok1` 就出局，连 `ip_match` 都到不了)。

### 1.4 当时实际跑的激励 —— 逐条比对 ⇒ **结构性不可能**

激励定义在 `_proj_10g/p7b_lat/scripts/probe_lat.tcl:348-356`:

```tcl
proc stim_ping6 {peer iface len} {
    ...
    exec ssh ... a@192.168.0.38 "ping6 -c 1 -W 2 -i 1 -s $n ff02::1%enp1s0f1np1"
}
```

三种帧长 (`len = 100/158/1514` 由 `-s N` 调出) **全是同一个东西：ICMPv6 echo，目的 = 全节点组播 `ff02::1`**。比对:

| 触发条件要求 | ping6 帧实际 | 判定 |
|---|---|---|
| IPv4 (`0x0800` + `0x45`) | **IPv6 (`0x86DD`)** | ❌ 在 `udp_rx.v:186` 出局 |
| 目的 IP = 192.168.100.2 | `ff02::1` (且 IPv6) | ❌ |
| proto = 17 (UDP) | 58 (ICMPv6) | ❌ `udp_rx.v:187` |

⇒ **激励根本不可能触发它**，这不是"概率小"，是**结构性**：`u_m_v` 恒 0 ⇒ `u_end` 恒 0 ⇒ `uf_commit_word` 恒 0 ⇒ `evt_d` 恒 0。**64/94 个样本全 0 正是这个的必然结果。**

**并且这一条可以推广到"整条 10G 链路"**：`(d)` 需要的 IPv4 帧在整个链路上**不可能存在** ——
本次调查实测 (只读 ssh 查询, 未改任何配置):

```
$ ssh a@192.168.0.38 "ip -4 addr show; ip -6 addr show dev enp1s0f1np1"
  enp3s0 : inet 192.168.100.1/24      ← P6e 那条 1G 直连 (P7b 构建里 RGMII 前端整体不存在)
  enp1s0f1np1 (SFP 口, 就是接板子 J8 的那根): **只有** inet6 fe80::3dc:7cad:d0b1:8db0/64
```

对端 SFP 口**没有 IPv4 地址** ⇒ 内核不会从该口发出任何 IPv4 帧 (无源地址/无路由) ⇒ **4 轮取数期间链路上不可能有 IPv4 帧**。
⚠️ 严格措辞: 上面这条是**现在**的读数; "取数当时也如此"靠 `P7B_LATENCY.md §2.5` 的"本次施工没有 root (`sudo` 要密码, raw socket 被拒)"支撑 —— **加地址/加路由/raw 注入三条路都要 root**。
若要把这一条也做成实锤, 缺一个**当时的**旁证 (对端地址的历史/审计)。⚠️ 但它只影响"有没有**环境** IPv4 帧"这半边; 归因的**主句**是 §1.4 的 RTL 结构性排除 —— **我们自己发的 `ping6` 恒为 IPv6, 与对端地址状态无关**; 若当时真混进过 IPv4 帧而 `evt_d` 仍为 0, 那才会反过来指向接线 (那正是 §3 要的正对照要回答的问题)。

**旁证 (同一现象的第二处、由不同信号给出)**:
`(cf)` fast 支 = `f_tvalid && f_tready && f_tuser`，而 `rx_classify` 的 fast 判据是
`f_ipv4 && proto==6`(`rtl/rx_classify.v:99-107`，`dec_w2` 非 TCP 定案 SLOW) ⇒ **IPv6 帧也永远走不到 fast 支**。
⇒ **恒 0 的三个 tap `{cf, d, d2}` 恰好就是"要求 IPv4"的那三个**，五个与 IPv4 无关的 tap 全部正常 —— 这个集合是 IPv6 激励**预测出来的**，不是事后解释。

### 1.5 ⭐ "这根线有没有真的接到位" —— 专项检查 (证据 + 判别力自评)

工程纪律: *未连接的输入会被综合钳 0, 与"该路径从未触发"在读数上不可区分*。逐条给证据与**它的判别力边界**:

| # | 证据 | 能区分什么 | 判别力边界 |
|---|---|---|---|
| **E1** | **源级接线成立**: `wrapper_p4.v:3800` 是**层次化引用** (`u_udp_split.uf_commit_word`)。层次名解析不了 ⇒ `xvlog`/`synth` **硬报错**；而本构建**出了位流** ⇒ 该层次网**必须存在** | 排除"名字写错/网不存在" | 不能排除"下游被优化成 0" |
| **E2** | **进程级证据**: `p7b_lat_build_stdout.txt` 全篇**只有 1 条** `[Synth 8-3848] … does not have driver`，且它是**已知的**故意悬空网 `pcs_ch0_unused58` (`wrapper_p4.v:337`) ⇒ **(a) 日志确实会报无驱动网 (正对照成立)，(b) `lat_dp_evt_d`/`dp_evt_d` 不在其中 ⇒ 它有驱动** | 排除"探针输入悬空 ⇒ 钳 0" | 若驱动是**常量**, 也满足"有驱动" —— 由 E3 补上 |
| **E3** | **E2 的常量口子被 E2' 堵住**: 被 tap 的 `uf_commit_word` **有功能消费者** (§1.2: 它写描述符 FIFO、参与回卷判决) ⇒ 不可能是常量网。合成器**无法**把它折成 0 (是否匹配取决于运行期数据) | 排除"常量钳位" | 不排除"综合把这一支判定不可达"—— 但同样取决于不可静态证明的输入 |
| **E4** | **网表级痕迹**: `.ltx` (`vivado_prj/p7b_lat_prj.runs/impl_1/wrapper_p4.ltx`) 里**逐引脚**记录了探针接到哪根网。覆盖 `(d)` 锁存的那几段 (`probe_in1[0:127]` = 单根网 `u_lat/lat_pi1`; `probe_in2[0:114]` = `u_lat/lat_pi2_1`) **不是 `<const0>`**；而**源里写成 `0` 的字段** (`flags[15:8]`、`W14` 的两个 `6'd0`、`W17` 的 `28'd0`) 全都在同一张表里被**逐位切成 `<const0>_1…48`** ⇒ **工具的分裂行为有正对照**，`(d)` 那几位不在常量里 | 排除"整根探针被钳 0" | ⚠️ **不能**区分"寄存器被恒定输入钉住"(实测: DRP 关掉时 `ro_drp_to` 也是真网名却恒 0) ⇒ **它证明的是"网在", 不是"会翻"** |

**⇒ 综合判断**: 四条证据都指向"接线到位、网表里活着"，**且没有一条证据支持"钳 0"**；但**"接没接到位"这件事本身无法只靠构建产物做成实锤** (E2'/E4 都有边界)。真正能一锤定音的**只能是一次正对照**：

> **用同一个位流、同一个探针，喂一个满足 §1.3 的帧 ⇒ `evt_d` 必须 0→1**。
> 这一条没做之前，严格措辞是"**接线无异常征象 + 激励结构性不匹配**"，不是"接线已证清白"。

⭐ **但有一条跨构建的旁证** (值得给权重): 同一个 `rtl/udp_split.v` 模块在 **1G 构建**上被另一个 IPv4/UDP 报文触发过 —— P6e 的"教学包"实测 **`W10 收帧 = 1`** (`P6E_OBS.md:331` 节), 即**app UDP 帧确实被收下并提交**。⇒ "缺的是 IPv4 帧"这个机理**在姊妹构建上跑通过**。

### 1.6 修法 (要什么激励 / 具体到命令) —— **一行 RTL 都不用改**

**① 前置 (需要 root, 一次性, 请用户或管理员做)**:

```bash
# 板上 cfg_dst_ip 是编译期常量 32'hC0A86402 = 192.168.100.2 ⇒ 对端必须在同网段
sudo ip addr add 192.168.100.9/24 dev enp1s0f1np1
# ⚠️ 只加地址**不够** —— 对端 enp3s0 已经有 192.168.100.0/24 (P6e 那条 1G 链路),
#    同前缀两条路由 ⇒ 去 192.168.100.2 的包会走 enp3s0。必须压一条 /32:
sudo ip route add 192.168.100.2/32 dev enp1s0f1np1
# 若板子在 10G 链路上不回 ARP (慢路径 HLS 的 ARP 未在 10G 前段验证过), 再加一条静态邻居:
sudo ip neigh replace 192.168.100.2 lladdr <board_mac> dev enp1s0f1np1 nud permanent
```
(⚠️ 该端口上**不能**用 192.168.100.2 以外的冲突处理；也别把 192.168.100.2 分给自己。)

**② 激励 (root 之后全部免权, 现成脚本)**:

```bash
# 对端机 (Linux) 上, 一个 UDP 报文到 8081 即可。脚本在**本仓** p6b_accept_final/srv_p6b_final_teach.py
#   (P6e 验收时用过; 它在对端机上跑, 没在对端就在本机 scp 过去), 无需 root:
scp p6b_accept_final/srv_p6b_final_teach.py a@192.168.0.38:/tmp/     # 本机执行
ssh a@192.168.0.38 "python3 /tmp/srv_p6b_final_teach.py --board 192.168.100.2 --port 8081 --hold 5"
# 它的三条已实测要点 (bind 8081 抑制 ICMP 洪水 / 载荷 = 图案前缀 100B / 目标 = 板子 app 端口) 见该文件头
```
⚠️ **别用 ICMP (`ping`)**: ICMP 不是 UDP，进不了 app 队列 (§1.3)；`ping` 只能证明链路活着。
**预期**: 该帧在 `u_udp_rx` 判 `matched` ⇒ `meta_valid` 在 w5 拍脉冲 ⇒ `udp_split` 判为 app 帧并从 HLS 路**撤回** ⇒ 帧尾 `uf_commit_word` 拉高一次 ⇒ **`evt_d` 0→1**（`evt_d2` 稍后也会 0→1，但要等播放器把帧摆到 app 口、且 app 消费者 `tready=1`）。**零 RTL 改动、零重建。**

**③ 如果 root 拿不到**: 不要为此改 RTL 造"假激励"。两条替代路，各有代价 (见 §3 建议 4):
(a) 重出一个"**1G 前端 + 探针**"位流 (对端 `enp3s0` 已有 192.168.100.1/24, **免 root**), 测 `(c)→(d)` 与 fast 支 —— `rx_classify` 之后的段在两个构建里是**同一批模块、同一个 dp_clk 156.25MHz**，DP 拍数可直接平移；(b) 板内自环 J7↔J8 + 自写 TX 发生器 —— 要动线 + 一次构建, 且**仍要自己造 IPv4/UDP 帧**, 不值。

---

## 2. 缺口二: fast path → app 队列 的延迟

### 2.1 这一段在 RTL 里是什么 (逐级, file:line)

**APP_MODE + P7B_10G 构建的快速通路 (全部在 `dp_clk` 156.25MHz 域, 每级 II=1)**:

```
rx_classify.m_fast_*  →  tcp_rx  →  pay_*  →  tcp_echo (store-and-forward)  →  eco_*  →  axis_pipe(1拍)  →  eco2_* = app_rx_*
rtl/rx_classify.v        rtl/tcp_rx.v        rtl/tcp_echo.v                  board/wrapper_p4.v:1851  :1886  :1073-1079
```

| 级 | 模块 / 位置 | 段内拍数 | 依据 |
|---|---|---|---|
| ① fast 路由判决 | `rtl/rx_classify.v:99-107` `dec_w2/dec_w5`；路由队列 `:124-149`，**出字门 `rd_ok = !w_empty && !rq_empty` (`:138`) ⇒ 判决拍之前一个字都出不去** | TCP 帧要**等到 w5** (5 字) 才定案 | **【读RTL】** |
| ② TCP 头解析 | `rtl/tcp_rx.v:167` FSM；`hdr_ok1/2` 在 `:257/:259`；`meta_valid`/`S_PAY` 在 `wcnt==6` (`:365/:371/:675`) | **SOP→载荷首字 ≈ 7 拍 (w0..w6)** | **【读RTL】** |
| ③ 载荷逐字发射 | `m_axis_tvalid=emit_v` (`:387`)，`emit_v<=1` (`:652`)，合成尾拍 (`:711`) | **1 字/拍** (帧内 N 字 = N 拍) | **【读RTL】** |
| ④ 应用帧 FIFO (=\⭐「app 队列」) | `rtl/tcp_echo.v:93` `frame_fifo #(.W(73),.D(8192),.AW(13))` = **64KB**；每拍写入 `accept`；帧末拍计数器 `:125` `if (accept && s_axis_tlast) stat_tlast_wr++` | 帧到齐即写满, **不额外加帧长** | **【读RTL】** |
| ⑤ 帧判定 | `:130` `fend && has_data && !pend → pend<=1`；`:133` `judged = pend && accept && tlast`；`:141-144` 坏帧 `rback` 回卷；`:149-153` `fq` 记账 | 判定拍 = **帧末字那一拍** (fend 由 `tcp_rx` 提前 1 拍给出) | **【读RTL】** |
| ⑥ 起播 | `:156-158` `S_IDLE → S_FWD (fq!=0)`；`:81` `m_axis_tvalid=(state==S_FWD)&&!fifo_empty` | **+1~2 拍** | **【读RTL】** |
| ⑦ 1 拍寄存器 | `board/wrapper_p4.v:1886-1895` `axis_pipe #(.W(77))` | **1 拍** | **【读RTL】** |
| ⑧ app 口 | `wrapper_p4.v:1073-1079` `app_rx_* = eco2_*`；消费者 = `app_pattern` RX 校验器 (`:1170-1201`) | 消费者 `rx_tready=(rxs==0)` (`rtl/app_pattern.v:280`)，一拍装、逐字节比 (`:524-542`) ⇒ **≈0.89 B/拍**, 10G 下是瓶颈 | **【读RTL】** |

**固定开销 (与帧长无关)** ≈ ①的 5 拍(与慢支的 w2 差 **+3 拍**) + ②7 拍 + ⑥~2 拍 + ⑦1 拍 ≈ **13~15 拍 ≈ 83~96 ns**，**外加**帧内 N 字 × 6.4 ns。
⚠️ **以上是【读RTL】推算, 不是读数** —— 级数**必须实测** (这正是要加探针的原因)。可核对的**预测**: 慢支 `(b)→(c)` 是 4 DP 拍，TCP 分支因 `dec_w5` 多等 3 字 ⇒ `(b)→(cf)` 应当是 **≈7 DP 拍**；测出来若差得远, 说明模型错。

### 2.2 终点「app 队列」的确切信号 (两个候选, 分列)

| 候选 | 信号 (file:line) | 语义 | 建议 |
|---|---|---|---|
| **A. 队列备好 (推荐)** | `rtl/tcp_echo.v:125` 的 `accept && s_axis_tlast` (现成计数器 `stat_tlast_wr`) | **整帧已完整写进 64KB 应用帧 FIFO = "完全入队、准备交给应用层"** (用户口径的终点) | ⭐ **主判据**。它是"本帧末 beat 进 FIFO"**唯一的**一拍, 且**不受 app 消费者快慢影响** |
| B. app 口可见 | `app_rx_tvalid && app_rx_tready && app_rx_tlast` (`wrapper_p4.v:1075`) | 末字**被 app 消费者收下** | 次判据。⚠️ 会**把 demo 校验器的吞吐算进延迟** (`app_pattern` ≈0.89 B/拍 ⇒ 100B 帧 ≈ +112 拍 ≈ 720 ns 的假延迟) —— 报数时必须写清是 A 还是 B |

### 2.3 两个方案

**方案 M (最小改动版: 只加**一个**时间戳探针)**

- **改哪**: ① `_proj_10g/p7b_lat/rtl/p7b_lat_top.v` 加一个 DP 域事件输入 + 一拍锁存 (`dp_f2_r`/`evt_f2`, 抄 `:290-291` 的 `dp_evt_d2` 写法即可)；② `board/wrapper_p4.v:3800` 旁边加一根线 = 候选 A 的 `u_tcp_echo.stat_tlast_wr` 增量拍 (或直接引 `u_tcp_echo` 内部 `accept && s_axis_tlast`)；③ 读出**复用已死的 W15/W16 两个字** (DRP 关掉时 `W14-W17` 恒 0, `p7b_lat_top.v:83-86`) ⇒ **VIO 位宽不变, 不用重生成 IP, `.ltx` 宽度不变** (但网名会变 ⇒ 需重跑 `scripts/gen_pinmap.py`, 并按 §9 的纪律取数)。
- **代价**: 1 次构建 (~45 min) + 1 次烧板 + 重取数。判据现成 (可直接套 `mut_sel` 变异法: 给新段加 N 拍 ⇒ 读数必须恰涨 N 拍, `P7B_LATENCY.md §6` 的模板)。
- **前置**: 见 §2.4 的"激励前置" —— **必须能起一条 TCP 连接**。

**方案 F (完整版: 端到端 app 可见)**

- 在 M 的基础上再加: 候选 B 的 tap (`app_rx_*` 末字被收下)、以及 UDP 侧的 `app_udp_rx_tlast`；两路激励 (IPv4/UDP + TCP) 各跑一遍, 把"队列备好"与"app 口可见"**两个终点分别报数** (不要合成一个数)。
- **代价**: 同 M 的构建 + **更长的板级流程** (两条链路场景 + 更严的样本配对判据: 现在要 10 个 tap 计数全等)。
- **前置**: M 的全部 + **闸 4 通过** (否则 10G 上没有可分发的 TCP 连接) + 对端 root。

### 2.4 缺口清单: 已量到的段加起来能覆盖全程吗? —— **不能**

| 段 | RTL 位置 | 有无读数 |
|---|---|---|
| 帧首 bit 出对端 SFP → PCS 输出 XGMII `/S/` | GT/PCS 内部 (CDR/解串/gearbox/弹性缓冲) | ❌ **零** (`L_PCS`, §7 U1) |
| **(a)** `/S/` → MAC RX SOP | `mac_rx_10g` + `u_rxcdc` | ✅ 4 FE 拍 = 25.60 ns |
| **(b)** → `vlan_strip` SOP | `rtl/vlan_strip` + `u_rxcdc` | ✅ 含在 (b)→(c) 里 |
| **(b)** → `rx_classify` **slow** SOP | `rtl/rx_classify.v` | ✅ 4 DP 拍 = 25.58 ns (**含 ±26 ns 跨域偏置**, U2) |
| **fast 支 (cf) 的 SOP** | 同上, `dec_w5` 路径 | ⚠️ **恒 0** (IPv6 激励), **无读数** (预测 ≈7 DP 拍, 见 §2.1) |
| **(c)** → 慢路径适配器入口 SOP/TLAST | `udp_split` 透传口 `srx_*` | ✅ 7 DP 拍 = 44.80 ns + N 字 × 6.4 ns |
| **(c)** → **app UDP 队列 (d)** | `udp_split.uf_commit_word` | ❌ **恒 0** (缺口一) |
| **fast 支 → app TCP 队列** | `tcp_rx`/`tcp_echo` | ❌ **零读数 (本缺口)** |
| app 口可见 (UDP/TCP) | `app_udp_rx_*` / `app_rx_*` | ❌ 恒 0 / 零读数 |

**结论**: 已量到的 `(a)→(b)→(c)→(e)` **只覆盖慢支的固定流水 (95.98 ns)**。用户问的"(B) 整帧交付"终点是**慢路径适配器入口**；**TCP fast path 到 app 队列这一段完全没有读数**，而且它的固定开销比慢支**多 ~3 拍** (`dec_w5` vs `dec_w2`)，**不能拿慢支的数字代替**。

---

## 3. 给主线的下一步建议

**值得做 (按性价比排序)**

1. ⭐ **先要一条 root 前置** (§1.6 ①的两条命令)。它**同时**解两个缺口的前置: `(d)` 当场可测 (**零构建**, 用现役延迟位流即可), fast path 也才有激励可能。**这是本报告最便宜的一步。**
2. ⭐ **闸 4 先行** (已是主线主目标)。fast path 的任何延迟读数都建立在"TCP 能连上"之上；闸 4 不过 ⇒ 方案 M/F 都没有激励。**顺序不能倒。**
3. **fast path 探针 = 方案 M**: 用现成死字 `W15/W16`、不动 VIO 位宽、套 `mut_sel` 变异法。**只有当用户确实要 TCP 口径的延迟数字时才做** —— 一次 45 min 构建 + 一次烧板。
4. **`(c)→(d)` 与 `(d2)` 用 §1.6 ② 的一个教学包直接量**, **不要**重建位流去"补探针": 这两个 tap 已经在了, 缺的只是激励。

**不值得做**

- **为 `(d)` 改 RTL 或加合成激励** (假激励测的是激励自己, 不是通路)。
- **为"尺寸可控的激励"去把线接回 J7↔J8 自环**: `ping6 -s N` 已能给出任意尺寸的帧 (§P7B_LATENCY §8 结论仍成立), 而自环**仍要自己造 IPv4/UDP 帧**, 白加一次构建。
- **重出一个 1G+探针位流** 来测 `(d)`：只有在**确认 root 彻底拿不到**时才考虑 (它免 root, 但要多一次构建 + RTL 改 `ifdef`, 且拿不到 (a)(b) 段的 10G 语义)。
- **用方案 B (app 口可见) 当主判据**: demo 校验器 ≈0.89 B/拍, 10G 下会把消费者瓶颈报成协议栈延迟。

**还差什么证据才能定案 (如实登记)**

| 待定案项 | 差什么 |
|---|---|
| `(d)` **接线**完全清白 | 一次**正对照**: 同一位流 + 一个 IPv4/UDP 帧 ⇒ `evt_d` 0→1 (§1.5)。现有 4 条证据都只到"无异常征象" |
| fast path 固定开销 13~15 拍 | 方案 M 的实测 (§2.1 的读RTL 推算) |
| `(b)→(cf)` 是否真比 `(b)→(c)` 多 3 拍 | 同一次方案 M 取数 (fast 支 SOP 探针) |
| 10G 链路上板子是否回 ARP (决定 §1.6 ② 命令能否直接跑通) | 一次 ARP 观测 (`tcpdump -e -n arp`) —— 免权 |
| `L_PCS` (U1) | 与本次两个缺口**无关**, 仍需 `ADD_GT_CNTRL_STS_PORTS=1` 那条路 (P7B_LATENCY §1.5) |

---

## 4. 复现我这次的检查 (全部只读, 不起重负载)

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g

# ① 独立解码四轮 stdout 的 6×128 位探针 (事件计数/时间戳), 不依赖 analyze_lat.py
C:/Users/zhxue/anaconda3/python.exe -c "
import re,glob
for f in sorted(glob.glob('_proj_10g/p7b_lat/board_scratch/run*_stdout.txt')):
    cur={}
    for line in open(f,encoding='utf-8',errors='replace'):
        m=re.match(r'LAT_HEX (\S+) (pi\d) ([0-9A-Fa-f]+)',line.strip())
        if m: cur[m.group(2)]=m.group(3).zfill(32)
        if m and m.group(2)=='pi5':
            pi=[cur.get('pi%d'%i,'0'*32) for i in range(6)]
            H=lambda i:int(pi[i],16); W=lambda i,w:(H(i)>>(32*w))&0xffffffff
            print(m.group(1),'evt_d=',W(2,2)>>16,'evt_d2=',W(3,1)&0xffff,'evt_cf=',W(2,1)&0xffff)
"

# ② 探针网表: 哪些位被工具切成 <const0> (正对照), 哪些是真网
C:/Users/zhxue/anaconda3/python.exe -c "
import json;d=json.load(open('vivado_prj/p7b_lat_prj.runs/impl_1/wrapper_p4.ltx',encoding='utf-8'))
c=[x for x in d['ltx_root']['ltx_data'][0]['debug_cores'] if x.get('type')=='VIO_V2'][0]
for p in c['pins']:
    if p['name'].startswith('probe_in'):
        print(p['name'],p['leftIndex'],p['rightIndex'],[n['name'] for n in p.get('nets',[])][:4])
"

# ③ 构建日志里的无驱动网 (正对照: 应只有 pcs_ch0_unused58 一条)
grep -o "Synth 8-3848\] Net [^ ]*" _proj_10g/p7b_lat/p7b_lat_build_stdout.txt | sort | uniq -c
```

⚠️ 本轮**没有**打开 routed DCP (`open_checkpoint` 属重负载, 且当时另有 Vivado 构建在跑) ⇒ "`u_lat/dp_d_r` 寄存器是否真在网表里"这一条我只到 `.ltx` 碎片这一级 (§1.5 E4)。若将来需要更硬的一刀, 在**不与他人抢 CPU** 时跑一次
`get_nets -hier -filter {NAME =~ "*u_lat/dp_d_r*"} u_lat/evt_d_reg*` 即可 —— 但**正对照 (§3) 比它更有判别力**, 优先做那个。
