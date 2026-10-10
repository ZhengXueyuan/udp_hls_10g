#!/bin/bash
#=============================================================================
# p7b_gate4_accept.sh — **P7b 闸 4 板级验收** (板侧 **63** 字 + NIC 侧网关判据)
#
# 为什么新写一个 (而不是只改 p6e_snap_check.sh):
#   ① 闸 4 的几何是 **63 字** (0x20..0x118, 未实现 = **0x11C**) —— P7B-WU 二轮从 61 字扩来
#      (旧的 61 字几何 = 0x20..0x110 / 未实现 0x114 / BID 8, 读旧位流时必须显式覆盖:
#       `SNAP_WORDS=61 EXPECT_BID=0x00000008 UNIMPL_ADDR=0x114`;
#       更旧的 51 字几何 = 0x20..0xE8 / 未实现 0xEC ⇒ `SNAP_WORDS=51 EXPECT_BID=0x00000007`);
#      ⛔ 2026-10-07 Stage C BID 同步轮: 上面这句保留 (几何确实**仍是 63 字 / 未实现 0x11C**) —— 变的是**身份**:
#         `BUILD_ID_V` 9 → **10** (`10 = P7b Stage C`, 源码 `board/wrapper_p4.v`)。
#         ⇒ 默认 `EXPECT_BID` 已改 **0x0000000A**; 读 **P7B-WU 二轮 / Build 2 位流**
#         (`1ccbd9cd84292d1a10973a1442f71ca2187e66834be5e09d7eeb22b42c6cdd07`) 需显式
#         `EXPECT_BID=0x00000009` (几何参数不用动: 仍 63 字 / 0x11C)。
#      ⛔ 2026-10-10 订正 (构建 C 门同步轮): 上面整段 (含标题里的 "63 字") **已过时** ——
#         现役 = **66 字 / 未实现 0x128 / BID 0x18** (构建 D; ⛔ 原句 = 65 字 / 0x124 / BID 17 = 构建 C)
#         (源码 `board/wrapper_p4.v`: `SNAP_NW_P6E = 66` /
#         `BUILD_ID_V = 32'h00000017`; 新增 W63/W64 = `app_pattern` 两个停滞计数)。
#         原句保留 (它们描述的是 P7B-WU 二轮 / Stage C 那两代)。读旧位流一律**同时**覆盖几何与身份:
#         Stage C 63 字 = `SNAP_WORDS=63 EXPECT_BID=0x0000000A`; WU 二轮 / Build 2 = `SNAP_WORDS=63 EXPECT_BID=0x00000009`。
#      p6e_snap_check.sh 是 36 字口径
#      ⭐ **P7B-BIZ 的 6 个新字** (RTL 真值源 = `board/wrapper_p4.v` 的 `snap_dout_all`,
#         装配项逐条带槽号注释; 全是 dp 域寄存器输出, 与 W39/W45..W50 同一束):
#         `W51` = `app_pattern.stat_tx_bytes`   (TCP 演示 app **下行**载荷字节)
#         `W52` = `app_pattern.stat_tx_frames`  (TCP 下行载荷帧数; 几何账)
#         `W53` = `app_pattern.stat_rx_bytes`   (TCP 演示 app **上行**载荷字节) → 判据 J13
#         `W54` = `app_pattern.stat_mismatch`   (**上行载荷逐字节**失配, 增量必须 = 0) → J12
#         `W55` = `tcp_tx_frame.stat_retx`      (重传/RTO 回卷次数, 增量必须 = 0) → J14 / `F5b`
#         `W56` = `app_udp_pattern.stat_tx_ovf` (TX 字 FIFO 拒写; 静默丢字类回归的守卫)
#         `W57` = `tcp_tx_frame.o_retx_hi`     (回卷重放上界; **只在 W58=1 时有效**)
#         `W58` = `tcp_tx_frame.o_retx_active` (重传会话进行中, 低 1 位)
#         `W59` = `slow_tx_adp.stat_fifo_ovf`  (u_wf 拒写; 恒 0 = 无静默丢失)
#         `W60` = `slow_rx_adp.stat_fifo_ovf`  (o_ovf 拒写; 恒 0 = 无静默丢失)
#         ⚠️ 非 `APP_MODE` 构建里 W51..W54 / W56 **恒 0** (源模块不存在) 而 **W55 仍是真值**
#            (`tcp_tx_frame` 在任何构建里都例化) —— 读到 0 要先确认构建宏, 别当"没重传"。
#      ⭐ **P7B-WU 二轮新增 2 字** (窗口 61 → 63; 加在 MSB 端 ⇒ 旧字逐项未动):
#         `W61` = `app_ctrl.stat_wu`      (窗口重开通告 ACK **确实入 ackq 的次数**; 不是"已上线")
#         `W62` = `app_ctrl.rx_occ_bytes` (app RX 可读字节, 17 位显式零扩展 ⇒ 高位恒 0)
#         ⇒ 一次 j6-ladder 读数即可把"wu 机理"从推断升为观测 (判据见 `P7B_BIZ_PLAN.md` §4.1b)。
#      ⚠️ **窗口为什么能从 51 一步到 57 (越过旧 56 上限)**: 读侧地址译码 `ar_word` 从 6 位
#         加宽到 7 位 (araddr[8:2]) ⇒ 未实现地址域扩到 0x104..0x1FC, 窗口上限抬到 119 字;
#         < 0x100 的既有地址逐位等价 (零回归)。见 `_proj_pcie/rtl/axi_regs.v` 头部注释。
#      (它已就地修成"字数可覆盖"的版本, 可单独当窗口快检用);
#   ② 闸 4 的头条判据在 **NIC 侧** (真网卡 802.3 裁决) —— 那部分以前**没有脚本**, 只在文档里;
#   ③ 负对照必须能"把**合成的假读数**喂给解析函数" ⇒ 本脚本把 **I/O 层**与**解析/判据层**分开,
#      解析层是纯函数 (只吃规范文本), 所以假读数能直接灌进来 (见 p7b_gate4_negctrl.sh)。
#
# ---- 怎么跑 (本机 Git Bash, 工作目录 = 本仓根) -------------------------------
#   前置 (顺序不可换): **烧位流 → 重启对端机 → 才读得到板侧** (见 P7B_GATE4_PLAN.md 步骤 0/2/3)
#
#   # ① 全链 (板侧停机态 → NIC 基线 → 教学打流 → NIC 测量 → 板侧洪泛窗):
#   PEER_PW=111111 bash _proj_pcie/p7b_gate4_accept.sh
#
#   # ② 只跑停机态 + NIC 基线 (不教学/不打流):
#   PEER_PW=111111 G4_SKIP_TRAFFIC=1 bash _proj_pcie/p7b_gate4_accept.sh
#
#   # ③ 离线/负对照 (喂合成文本, 完全不碰板子与对端机): 逗号分隔 **2 或 4 个文件**
#   G4_SNAP_TEXT=a.txt,b.txt,c.txt,d.txt G4_NIC_TEXT=e.txt,f.txt,g.txt,h.txt \
#     bash _proj_pcie/p7b_gate4_accept.sh
#
#   开关: G4_BIT=<位流路径> · EXPECT_BID=0x... · SNAP_WORDS=63 · G4_IFACE=enp1s0f1np1
#         ⚠️ P7B-WU 二轮起窗口 = **63 字** (RTL `board/wrapper_p4.v` 的 `SNAP_NW_P6E`);
#            读**旧位流**必须显式覆盖 —— BIZ 61 字: `SNAP_WORDS=61 EXPECT_BID=0x00000008
#            UNIMPL_ADDR=0x114`; RATE 51 字: `SNAP_WORDS=51 EXPECT_BID=0x00000007 UNIMPL_ADDR=0xEC`.
#            ⛔ 2026-10-07 (Stage C): 默认身份 = **0x0000000A**; 读 P7B-WU 二轮 (Build 2, 63 字)
#               位流只需覆盖 `EXPECT_BID=0x00000009` (窗口 / 未实现地址都不用动)。
#            ⛔ 2026-10-10 (构建 C 门同步轮): 上面整段**已过时** —— 现役默认 = `SNAP_WORDS=65`
#               (0x20..0x120, 未实现 **0x124**) + `EXPECT_BID=0x00000017`。读旧位流要**同时**覆盖几何与身份
#               (Stage C 63 字 = `SNAP_WORDS=63 EXPECT_BID=0x0000000A`)。原句保留。
#         G4_TRAFFIC_CMD=<激励命令> · NIC_GOOD_MIN / NIC_MBPS_MIN (阈值)
#         W5_NOM_MHZ=156.25 (前端域标称; P6b 位流取 125) · TRAFFIC_TIMEOUT=180
#         G4_LIB_ONLY=1 (只加载函数; 负对照脚本 source 用)
#
# ---- ⚠️ 2026-09-30 fix2: 首次上板暴露的三处 live 路径缺陷 (全部已就地修, 见 TOOLING_FIX2) ----
#   (a) **live 模式永远只取一块快照** ⇒ `nsf` 恒 1 ⇒ G2 频率 / G3 守恒 / C 组 PCS / C8 / B_G6 /
#       N_XCHK **全被 SKIP**。现改成**按判据需要取多块**: live 一律取 2 块 (A/B 停机态),
#       打流档再取 2 块 (C/D 洪泛窗) —— 判据要几点就取几点 (规格 §6.1 G2/G3 是逐字判据)。
#   (b) `G4_TRAFFIC_CMD` **首词是绝对路径时被 MSYS 改写** (`/home/a/...` ⇒
#       `C:/Program Files/Git/home/a/...`) ⇒ 远端 `No such file or directory` ⇒ **激励静默没跑**,
#       而 NIC 判据照常打 FAIL (**看着像板子坏了**)。现: 远端命令**无条件**前置 `true; ` +
#       回显实际命令 + 退出码 (`TRAFFIC_CMD`/`TRAFFIC_RC`), 并加判据 `T_RUN`:
#       激励执行凭证缺失 ⇒ **T_RUN FAIL 并明写"下面任何 NIC FAIL 不是板子的结论"**
#       (不静默、不当作板子缺陷), 不再把"没跑"报成"板子不收帧"。
#   (c) Windows Python 的 stdout 会把远程 Linux 的 LF 翻成 **CRLF** ⇒ `parse_snap` 的严格
#       十六进制正则不匹配 ⇒ 前置闸 ABORT (退出 2)。旧版要调用者 `PY=py_nocrlf.sh` 注入才绕过;
#       现收进**脚本本体** (`peer()` 里 `tr -d '\r'`, 用 PIPESTATUS 保住远端退出码)。
#
# ---- ⚠️ 2026-09-30 fix3: 判据收口 (闸 4 第二轮 PASS=23/FAIL=3 的三条 FAIL 逐条定性) --------
#   全部原始证据与反例实测 = `_proj_10g/notes/P7B_GATE4_CRITERIA_CLOSEOUT.md` +
#   `_proj_10g/notes/p7b_gate4_criteria/`。三条定性结论 (**没有一条是设计缺陷**):
#   (a) **`T_RUN` 一条判据干了两件事** ⇒ 拆开: `T_RUN` = "激励**执行了没有**"(硬判据, 就是 fix2(b)
#       要防的 MSYS 改写/命令不存在), `T_TOOL` = "**工具自己**的端到端结论"(只能 triage, 不许
#       静默变绿)。本轮 rc=1 的真实来源 = 工具 `bad>0` (`p6e_udp_pattern.cpp:179`) —— 用户态单个
#       SO_RCVBUF(8 MB ≈ 1662 帧) 在 106k fps 下的**接收侧天花板** + 64 KB 重同步窗 (= 线上 0.42 ms)
#       + 首次失配后的**级联** (`pat` 在成功匹配时不推进 ⇒ 每次都要 resync; 失配后 `pat` 不变 ⇒
#       之后每帧都判"真失配", 且每次 resync 是 O(win²) ⇒ 板上实测 3.5 s/帧)。**容器不是板子**。
#   (b) **`N_SELF` 的 ±1 偏置 = 判据前提不成立**: 它假定 `good/bad/packets` 是同一次原子快照。
#       实测**单个 dump 内部**就自相矛盾 (nic_D: good+bad = packets **+1**, 其余 5 个 dump 残差 0)
#       ⇒ 三个字段不是同一时刻读出的 (NIC 的 RX 通路上有两个计数点, 至多一帧"在飞") ⇒ 容差 ±2。
#   (c) **`N_XCHK` 结构性永不评估** (守卫 `[ -n "${assoc+x}" ]` 对关联数组恒假, bash 语义),
#       且**两个口径不同刻** (板侧窗与 NIC 窗错开 8~12 s) ⇒ 即使跑起来也无判别力; 另实测
#       `port_rx_*` 与内核 `rx_packets/rx_bytes` **逐字相同** (同一来源报两遍) + 更新量子 ≈1 s
#       ⇒ **降级为旁证**: 加同刻守卫 + 窗口 ≥20 s + 量子反解容差, 判据名后缀"(旁证)"。
#       F4 的独立口径 = pcap 时间戳 (见 closeout §4), **不得**用本条单独裁决。
#
# ---- 判据 (逐条打印 判定/判据号/判据/期望/实测; 判定 ∈ PASS|FAIL|SKIP) ----------
#   板侧 (G1/G2/G3/B/C/E4): B_GEN  B_WIN  B_UNIMPL  G2-W5/W24/W50  B_CONS-a/b  B_DIR
#                           C1-C5  C6-C7  C8  C6-ev  B_G6
#   NIC 侧 (闸 2 网关判据 —— **四件一起**, 旧的 `port_rx_good > 0` 已被板子自己的
#   HELLO/ARP 背景流量满足 ⇒ 无判别力, 见 P7B_GATE4_PLAN.md §0.1):
#                           N_CRC N_BAD **N_RATE(增量+速率阈值)** **N_UCAST** **N_LEN(长度桶)**
#                           N_AVG N_SELF **N_BASE(判别力自检)** N_XCHK(板侧×网卡对账)
#   ⭐ fix2 新增: **T_RUN**(激励执行凭证 —— 远端回显 TRAFFIC_CMD + TRAFFIC_RC;
#   缺凭证 ⇒ 拒绝出结论, 不许把"激励没跑"报成"板子不收帧")
#   ⭐ fix3 拆出: **T_TOOL**(工具**自己**的端到端结论 —— rc=1 且工具自报"真失配"时给 SKIP+triage,
#   明确指出根因在工具接收侧 (SO_RCVBUF/重同步窗/级联), **不得**当板子缺陷, 内容裁决走独立口径)
#   负对照 = p7b_gate4_negctrl.sh (15 条: 1 正对照 + 9 板侧变异 + 5 NIC 变异, 全部真跑)
#           fix2 新增 live 路径假对端台架 = p7b_gate4_livefake.sh (7 case, 含新旧对照)
# ---- 退出码: 0=全 PASS / 1=有 FAIL / 2=前置闸拒绝 (身份/通道/结构) ------------
#=============================================================================
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PY=${PY:-/c/Users/zhxue/anaconda3/python.exe}
BIT=${G4_BIT:-$ROOT/vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit}
IFACE=${G4_IFACE:-enp1s0f1np1}
BOARD_IP=192.168.100.2
MYIP=192.168.100.100
DEV=/dev/xdma0_user
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
EXPECT_BID=${EXPECT_BID:-0x0000001D}      # persist 刀 = 0x1D (源码 board/wrapper_p4.v 的 BUILD_ID_V; 原 0x1C = 缺陷刀 / 0x1A = 构建 F)
# ⛔ 2026-10-07 Stage C 同步轮: 原句 = "P7B-WU 二轮 = 9"; 读 Build 2 (63 字 / BID 9) 覆盖 EXPECT_BID=0x00000009
# ⛔ 2026-10-10 订正 (构建 C 门同步轮): 原默认 0x0000000A (P7b Stage C 63 字) ⇒ 现役 = **17 / 65 字**。
#    ⚠️ 默认 `EXPECT_BID` 与默认 `SNAP_WORDS` **必须同代** (后者本轮已 = 65): 不同代 ⇒ G1 身份红 +
#    B_WIN "窗口不完整" 红 (假红)。读旧位流: Stage C 63 字 = `EXPECT_BID=0x0000000A SNAP_WORDS=63`;
#    WU 二轮 / Build 2 = `EXPECT_BID=0x00000009 SNAP_WORDS=63`。
SNAP_WORDS=${SNAP_WORDS:-70}
UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 70 ⇒ 0x138 (67 ⇒ 0x12C; 66 ⇒ 0x128; 65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)
# ⚠️ 未实现地址 = 0x20 + 4*SNAP_WORDS 这条公式本轮**重新成立**: 读侧译码已加宽到 7 位
#    (araddr[8:2]) ⇒ 地址每 **512** 字节才回绕, 而 `0x20+4*63 = 0x11C` 真正未实现 ⇒
#    仍回 0xffffffff。红线随之改成"**绝不能挑 ≥0x200**" (旧红线是 ≥0x100)。
W32=$((1<<32))
NIC_GOOD_MIN=${NIC_GOOD_MIN:-100000}      # 增量阈值 (帧): 背景 0.1~0.5 帧/s, 差 6 个数量级
NIC_MBPS_MIN=${NIC_MBPS_MIN:-800}         # 速率阈值 (Mbps, 线上字节率)
TRAFFIC_SECS=${TRAFFIC_SECS:-15}
TRAFFIC_TIMEOUT=${TRAFFIC_TIMEOUT:-180}
# ⭐ fix3: 跨设备对账 (N_XCHK) 的窗口与守卫 —— 见 check_xchk 的头注释
#   XCHK_SECS     : 测量窗里"板侧 C → NIC C → sleep → NIC D → 板侧 D"的那段睡眠 (秒)
#   XCHK_MAX_OFFSET: 两个口径取数时刻允许的差 (秒); 超了 ⇒ 量的不是同一段 ⇒ SKIP (不是 FAIL)
#   XCHK_Q        : 参考侧 (主机内核 rx 计数) 的**更新量子** (秒), 由 var_probe 三轮反解 (≈1)
XCHK_SECS=${XCHK_SECS:-20}
XCHK_MAX_OFFSET=${XCHK_MAX_OFFSET:-2}
XCHK_Q=${XCHK_Q:-1}
NIC_TOL_BASE=${NIC_TOL_BASE:-1.0}     # 容差下界 (%), 量子项更宽时取量子项
# W5 (前端域自由计数) 的**标称**随构建而变 —— 判据的期望值, 不跟上就是假 FAIL:
#   · P7B_10G 构建 (默认几何 63 字 / BID=10 —— ⛔ 2026-10-07 Stage C: 原句写 "BID=9"): 前端域 = PCS 的 CDR **恢复钟**
#     (`board/wrapper_p4.v:658-659` `ifdef P7B_10G assign gmii_clk = rx_clk_out_1`) ⇒ 156.25 MHz
#     (板级独立两点实测 156.1986 MHz, P7B_GATE4_ACCEPT.md §3.3 — 证否 P6b 的 "W5=125" 假设)
#   · 1G/P6b 位流 (SNAP_WORDS=36 / BID=6): 前端域 = PHY 回送的 RGMII RX 钟 ⇒ 125
W5_NOM_MHZ=${W5_NOM_MHZ:-156.25}
G4_SKIP_TRAFFIC=${G4_SKIP_TRAFFIC:-0}
# ⚠️ 默认值**故意不以 `/` 开头之前置 `cd ... &&`**: 首词是 `cd` ⇒ 整串不以 `/` 开头 ⇒
#    不触发 MSYS 的路径改写; 且 run_traffic() 还会再前置一个 `true; ` 兜底 (见其注释)。
G4_TRAFFIC_CMD=${G4_TRAFFIC_CMD:-cd /home/a/xdma_test && ./p6e_udp_pattern --secs $TRAFFIC_SECS --board $BOARD_IP --port 8081}
OUTDIR=${G4_OUTDIR:-$ROOT/_proj_10g/notes/p7b_gate4_tools}
MARKER_EXP=0xdeadbeef

PASS=0; FAIL=0; SKIP=0; FATAL=0
declare -a SUM
# 解析结果的容器 (必须**顶层**声明: 在函数里 `declare -A` 会变成局部变量, 属性装不上)
declare -a SW
declare -A SM NC
# NIC 块的四个容器 (必须**声明成关联数组**: 普通赋值会退化成下标数组, 之后 NC[<键>] 会被
# 当成算术下标 ⇒ 在 set -u 下报 "unbound variable", 看着像脚本坏了)
declare -A NB_NC NQ_NC

res(){ case "$1" in PASS) PASS=$((PASS+1));; FAIL) FAIL=$((FAIL+1));; SKIP) SKIP=$((SKIP+1));; esac
       SUM+=("$1|$2|$3|$5")
       printf "  [%-4s] %-10s %s | 期望=%s | 实测=%s\n" "$1" "$2" "$3" "$4" "$5"; }
fatal(){ echo "  [FATAL] $*"; FATAL=1; }
hr(){ echo; echo "===== $* ====="; }

dd32(){ local d=$(( ($2 - $1) % W32 )); [ "$d" -lt 0 ] && d=$(( d + W32 )); echo "$d"; }
# 结构坏 ⇒ **拒绝出结论**。⚠️ 不这么做的后果不是"少一条判据", 而是**静默用上一块的陈旧数组**:
#   解析失败时不调用 nic_copy/snap_copy ⇒ 全局数组还留着**上一对**的值 ⇒ 判据照常打印 PASS/FAIL,
#   而它与本块读数毫无关系 (= 本工程最贵的"判据与读数脱钩")。负对照 `nic_missing` 就是为它加的。
abort_if_fatal(){ [ "$FATAL" = 0 ] && return 0
  echo; echo "  [ABORT] $1: 结构/前置未过 ⇒ **本轮读数不可用** (退出 2): $PARSE_ERR"
  echo "########## PASS=$PASS FAIL=$FAIL SKIP=$SKIP ##########"; exit 2; }
bit(){ echo $(( ($1 >> $2) & 1 )); }
# 百分比/在容差内 (awk 做浮点; bash 只做整数)
in_pct(){ awk -v a="$1" -v b="$2" -v p="$3" 'BEGIN{ d=a-b; if(d<0)d=-d; exit !(b!=0 && d/b<=p/100) }'; }
hz2mhz(){ awk -v d="$1" -v t="$2" -v k="$3" 'BEGIN{ printf "%.4f", (t>0)? d/k/t/1e6 : 0 }'; }
mbps(){ awk -v b="$1" -v t="$2" 'BEGIN{ printf "%.2f", (t>0)? b*8/t/1e6 : 0 }'; }
dt2(){ awk -v a="$1" -v b="$2" -v c="$3" -v d="$4" 'BEGIN{ printf "%.6f", ((c+d)-(a+b))/2 }'; }
ge(){ awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a>=b) }'; }
le(){ awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a<=b) }'; }

# ---- I/O 层 (唯一碰外部世界的地方) -------------------------------------------
# ⚠️ fix2 (c): **CRLF 收进脚本本体**。为什么必须在这里做: `peer_ssh.py` 跑在 **Windows Python**
#   上, 它的 stdout 是 `newline=None` 的 TextIOWrapper ⇒ 写 `\n` 时被翻成 `os.linesep = "\r\n"`,
#   而本函数搬运的是**远程 Linux 的原始输出** (LF) ⇒ 本机拿到 CRLF ⇒ `parse_snap` 的严格正则
#   `^0[xX][0-9a-fA-F]{1,8}$` 不匹配 (值尾多一个 \r) ⇒ **前置闸 ABORT (退出 2)**。
#   实测: `python tools/peer_ssh.py "echo AAA" | od -c` = `A A A \r \n`; 对端机上同一读无 \r。
#   旧版要调用者显式注入 `PY=py_nocrlf.sh` 才绕过 —— 那是"靠人记得"的做法, 迟早再踩
#   (闸 4 首次上板的 stage1_attempt1 就是这么 ABORT 的)。现在**无条件剥 \r**, 且用
#   PIPESTATUS 保住远端退出码 (调用点用 `|| fatal`/`|| echo WARN` 判成败, 不能被管道吃掉)。
peer(){ PYTHONIOENCODING=utf-8 "$PY" "$ROOT/tools/peer_ssh.py" "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
need_pw(){ [ -n "${PEER_PW:-}" ] || { fatal "本脚本的 --sudo 调用需要 PEER_PW (环境变量, 不落盘)"; exit 2; }; }

# ---- 激励 (打流): 见文件头 fix2 (b) 的三条硬要求 ------------------------------
run_traffic(){   # 0=远端命令正常结束; 非 0=工具/链路退出码 (由 T_RUN/T_TOOL 分别记录)
  local cmd="$G4_TRAFFIC_CMD"
  case "$cmd" in *"'"*) fatal "G4_TRAFFIC_CMD 里不能含单引号 (远端脚本用它做引用)"; return 9;; esac
  TRAFFIC_TXT=$OUTDIR/traffic_cmd.txt
  # ⭐ fix3: 离线钩子 —— 喂一份**与远端回显同形**的日志就能在本地判 T_RUN/T_TOOL
  #   (本仓把 I/O 层与判据层分开的老做法; 反例实测见 p7b_gate4_criteria/negctrl_fix3.sh)
  if [ -n "${G4_TRAFFIC_TEXT:-}" ]; then
    [ -f "$G4_TRAFFIC_TEXT" ] || { fatal "G4_TRAFFIC_TEXT=$G4_TRAFFIC_TEXT 不存在"; return 9; }
    cp "$G4_TRAFFIC_TEXT" "$TRAFFIC_TXT"; cat "$TRAFFIC_TXT"; return 0
  fi
  # `true; ` 是 bash 空操作, 唯一作用是让整串**不以 `/` 开头** ⇒ 免疫 MSYS 的路径改写。
  # 同时回显 `TRAFFIC_CMD <...>`: 日志里必须留下"远端到底执行了什么"的原始凭证。
  peer --timeout "$TRAFFIC_TIMEOUT" \
    "echo TRAFFIC_BEGIN; printf 'TRAFFIC_CMD <%s>\n' '$cmd'; true; $cmd; echo TRAFFIC_RC=\$?; echo TRAFFIC_END" \
    > "$TRAFFIC_TXT" 2>&1
  local rc=$?
  cat "$TRAFFIC_TXT"
  return "$rc"
}
# 判据 A (`T_RUN`): **激励真的执行了吗** —— 缺凭证(BEGIN/END/RC)一律拒绝出结论 (fix2 (b) 的本意)
# 判据 B (`T_TOOL`): **工具自己**的端到端结论 —— 只 triage, 不许把"工具跟不上"静默算成 PASS,
#   也不许把"工具跟不上"当成板子缺陷。两类退出码的定性见下 (证据 = closeout §2)。
check_traffic(){  # <标签>
  local tg="$1" rc cmdv
  if [ -z "${TRAFFIC_TXT:-}" ] || [ ! -f "$TRAFFIC_TXT" ]; then
    res FAIL "T_RUN" "$tg 激励执行凭证" "TRAFFIC_BEGIN/END/RC 三行" "没有 $OUTDIR/traffic_cmd.txt ⇒ 无从证明激励跑过"; return 1
  fi
  rc=$(sed -n 's/^TRAFFIC_RC=//p' "$TRAFFIC_TXT" | tail -1 | tr -d ' \r')
  cmdv=$(sed -n 's/^TRAFFIC_CMD <\(.*\)>$/\1/p' "$TRAFFIC_TXT" | head -1)
  # ---- 凭证不完整: 这正是 fix2 (b) 要抓的失效形态 (MSYS 改写/命令不存在/ssh 断) ----
  if ! { grep -q '^TRAFFIC_BEGIN' "$TRAFFIC_TXT" && grep -q '^TRAFFIC_END' "$TRAFFIC_TXT" && [ -n "$rc" ]; }; then
    res FAIL "T_RUN" "$tg 激励执行凭证不完整" "TRAFFIC_BEGIN/END/RC 三行" \
      "缺行 ⇒ **激励没跑** (MSYS 改写/命令不存在/ssh 断) ⇒ 下面任何 NIC FAIL **不是板子的结论**"
    res SKIP "T_TOOL" "$tg 工具端到端" "rc=0" "脚本都没跑起来 ⇒ 无工具结论可言"
    return 0
  fi
  case "$rc" in
    0)
      res PASS "T_RUN"  "$tg 激励确实执行了 (远端回显 + 退出码)" "TRAFFIC_RC=0" "TRAFFIC_RC=0; 远端实收命令=<${cmdv}>"
      res PASS "T_TOOL" "$tg 工具端到端结论 (自报逐字节全对)" "rc=0 且逐字节全对" "TRAFFIC_RC=0 (工具自己打 [PASS] 全部 N 帧逐字节等于图案流)" ;;
    126|127)
      # 命令本身没跑起来 (shell 找不到 / 不可执行) —— 真警示, 且点名"先怀疑激励侧"
      res FAIL "T_RUN" "$tg 激励命令本身没跑起来 (rc=$rc)" "rc=0" \
        "TRAFFIC_RC=$rc (**先怀疑激励侧**: 命令没找到 / 不可执行 (rc=126/127) / 网卡没配好. 下面 NIC 的 FAIL **不得**当板子缺陷引用)"
      res SKIP "T_TOOL" "$tg 工具端到端" "rc=0" "命令没跑起来 ⇒ 无工具结论" ;;
    *)
      # ⭐ fix3: 命令**确实执行了** ⇒ T_RUN 成立; 非 0 是**工具自己的**结论 ⇒ 交给 T_TOOL triage
      res PASS "T_RUN" "$tg 激励确实执行了 (远端回显 + 退出码)" "三行凭证齐全" \
        "TRAFFIC_RC=$rc; 远端实收命令=<${cmdv}> (rc 是**工具自己**的结论, 不是'没跑')"
      if grep -q '一个包都没收到' "$TRAFFIC_TXT"; then
        res FAIL "T_TOOL" "$tg 工具**一个包都没收到**" "rc=0" \
          "工具自己的判据 = 零帧 ⇒ 必须查: peer 没学到 / 板子没发 / 网段与路由不对 (这条是**真警示**, 不是工具天花板)"
      elif grep -q '帧图案真失配' "$TRAFFIC_TXT"; then
        # 把工具**自己的**原文摘进来 (SKIP 行必须自带证据, 不许让读者去翻上文)
        local selfrep; selfrep=$(grep -m1 '帧图案真失配' "$TRAFFIC_TXT" | tr -d '\r' | sed 's/^ *//')
        res SKIP "T_TOOL" "$tg 工具端到端 (工具自报真失配, 根因在**它的接收侧**)" "rc=0" \
          "工具原文: ${selfrep} ⇒ 根因是**工具接收侧失去对齐** (单个 SO_RCVBUF(8MB≈1662 帧) 在 106k fps 下的天花板; 64 KB 重同步窗 = 线上 0.42 ms; 首次失配后 \`pat\` 不重锚 ⇒ 级联 + O(win²) resync ⇒ 实测 3.5 s/帧). **不得**当板子缺陷; 内容裁决走独立口径 pcap 逐字节 (见 closeout §1/§4)"
      else
        res SKIP "T_TOOL" "$tg 工具端到端" "rc=0" "TRAFFIC_RC=$rc 但日志里没有可 triage 的工具结论 (读上面的原文)"
      fi ;;
  esac
  return 0
}

read -r -d '' SNAP_REMOTE <<'EOS'
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//'; }
g0=$(rd 0x1c); g0=$(( (g0 >> 16) & 0xffff ))
t0=$(date +%s.%N)
$T/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1
for i in $(seq 1 100); do s=$(rd 0x1c); [ -n "$s" ] && [ $(( s & 2 )) -ne 0 ] && break; sleep 0.01; done
t1=$(date +%s.%N)
g1=$(rd 0x1c); g1=$(( (g1 >> 16) & 0xffff ))
printf 'SNAP_BEGIN\n'
printf 'TLATCH %s %s\n' "$t0" "$t1"
printf 'GEN %s %s\n' "$g0" "$g1"
printf 'MAGIC %s\n'  "$(rd 0x00)"
printf 'BID %s\n'    "$(rd 0x04)"
printf 'MARKER %s\n' "$(rd 0x14)"
# ⚠️ 循环上界与未实现地址**一律派生** (旧版写死 `seq 0 50` + `rd 0xEC` ⇒ 扩窗时必须
#    两处手改, 漏一处就读到"半代窗口 + 已实现地址当未实现"⇒ 假 FAIL/假 PASS 各一次)。
# ⚠️⚠️ `__SNAP_WORDS__` / `__UNIMPL_ADDR__` 是**占位符**: 本段是**引号 heredoc**, 而远端跑的是
#    `sudo bash -lc` (登录 shell) —— 本脚本的 `SNAP_WORDS`/`UNIMPL_ADDR` **既没 export、也不是
#    sudo 的保留变量 ⇒ 远端一个都看不到**。所以值必须由 `snap_fetch` 在**发送前**替换进文本里。
#    (历史缺陷: BIZ 轮把这里的 `seq 0 50` 改成"由 SNAP_WORDS 派生"却漏了这一步 ⇒ 远端
#     `seq 0 -1` = 空 ⇒ **live 档一块快照都取不回来**, 2026-10-07 实测复现;
#     而 livefake/negctrl 两个台架**结构上看不见它** —— 假对端自己造字, 不执行这段文本。)
for i in $(seq 0 $(( __SNAP_WORDS__ - 1 ))); do printf 'W%s %s\n' "$i" "$(rd $(printf '0x%X' $(( 0x20 + 4*i ))))"; done
printf 'UNIMPL %s\n' "$(rd "__UNIMPL_ADDR__")"
printf 'SNAP_END\n'
EOS

read -r -d '' NIC_REMOTE <<'EOS'
t0=$(date +%s.%N)
OUT=$(ethtool -S enp1s0f1np1 | grep -E '^ +(port_rx_(packets|good|bad|bytes|unicast|multicast|broadcast|64|65_to_127|128_to_255|256_to_511|512_to_1023|1024_to_15xx|15xx_to_jumbo|overflow|nodesc_drops|pause|control)|rx_eth_crc_err|rx_frm_trunc|port_tx_packets):')
t1=$(date +%s.%N)
printf 'NIC_BEGIN\n'
printf 'TLATCH %s %s\n' "$t0" "$t1"
echo "$OUT" | tr -d ' ' | tr ':' ' '
printf 'NIC_END\n'
EOS

snap_fetch(){  # live: 一次 ssh; 离线: 从 G4_SNAP_TEXT 列表里取第 n 个
  if [ -n "${G4_SNAP_TEXT:-}" ]; then cat "$1"; return 0; fi
  need_pw
  # ⚠️ **必须在发送前把几何值替换进远端文本** (见 SNAP_REMOTE 里那段注释): 远端是
  #    `sudo bash -lc`, 本脚本的 SNAP_WORDS/UNIMPL_ADDR 传不过去 ⇒ 不替换的话远端
  #    `seq 0 $((SNAP_WORDS-1))` 会退化成 `seq 0 -1` = **空**, 整块快照解析失败
  #    (2026-10-07 实测: `FATAL 快照块 A 解析: 窗口不完整: 缺 W0 (共收到 0 字)`）。
  local rw="${SNAP_REMOTE//__SNAP_WORDS__/$SNAP_WORDS}"
  rw="${rw//__UNIMPL_ADDR__/$UNIMPL_ADDR}"
  peer --sudo --timeout 120 "$rw"
}
nic_fetch(){
  if [ -n "${G4_NIC_TEXT:-}" ]; then cat "$1"; return 0; fi
  peer --timeout 60 "$NIC_REMOTE"
}
# 逗号列表取第 n 项 (1-based)
pick(){ echo "$1" | awk -F, -v n="$2" '{print $n}'; }
# 逗号列表的项数
count_items(){ echo "$1" | awk -F, '{print NF}'; }

# ---- 解析层 (纯函数: 规范文本 → 数组; **负对照就是往这里喂假文本**) ------------
# parse_snap <file> → SW[] + SM{GEN0,GEN1,T0,T1,MAGIC,BID,MARKER,UNIMPL,OPEN,CLOSE}
parse_snap(){
  PARSE_ERR=""; SW=(); SM=(); local k v v2 idx nw=0 dup=0
  while read -r k v v2 || [ -n "${k:-}" ]; do
    k=${k%$'\r'}; v=${v:-}; v2=${v2:-}      # fix2(c) 防御: 万一还有别的 CRLF 源 (见 peer() 注释)
    case "$k" in
      SNAP_BEGIN) SM[OPEN]=1;;
      SNAP_END)   SM[CLOSE]=1;;
      W[0-9]*)    idx=${k#W}
                  [[ "$idx" =~ ^[0-9]+$ ]] || continue
                  [[ "$v" =~ ^0[xX][0-9a-fA-F]{1,8}$ ]] || { PARSE_ERR="W$idx 的读数是 '$v' (不是 0x 十六进制 ⇒ 空读/读失败); **空读 ≠ 真 0**"; return 1; }
                  [ -n "${SW[$idx]:-}" ] && dup=1
                  SW[$idx]=$(( v )); nw=$(( nw+1 ));;
      GEN)        SM[GEN0]=$v; SM[GEN1]=${v2:-};;
      TLATCH)     SM[T0]=$v;   SM[T1]=${v2:-};;
      "")         ;;
      *)          SM[$k]=$v;;
    esac
  done < "$1"
  [ -n "${SM[OPEN]:-}" ] && [ -n "${SM[CLOSE]:-}" ] || { PARSE_ERR="缺 SNAP_BEGIN/SNAP_END"; return 1; }
  local i
  for (( i = 0; i < SNAP_WORDS; i++ )); do
    [ -n "${SW[$i]:-}" ] || { PARSE_ERR="窗口不完整: 缺 W$i (共收到 $nw 字; 期望下标 0..$((SNAP_WORDS-1)) 连续)"; return 1; }
  done
  [ "$dup" -eq 0 ] || { PARSE_ERR="有**下标重复**的字 (地址表重复 / 末字回绕成低地址字 —— 正是旧脚本尾部 8 项重复那处笔误的形态)"; return 1; }
  [ "${#SW[@]}" -eq "$SNAP_WORDS" ] || { PARSE_ERR="字数不符: 收到 ${#SW[@]} 个下标 (期望 $SNAP_WORDS)"; return 1; }
  for k in GEN0 GEN1; do [[ "${SM[$k]:-}" =~ ^[0-9]+$ ]] || { PARSE_ERR="缺/坏 GEN ($k='${SM[$k]:-}')"; return 1; }; done
  local dg=$(( (SM[GEN1] - SM[GEN0]) % 65536 )); [ "$dg" -lt 0 ] && dg=$(( dg + 65536 ))
  [ "$dg" -eq 1 ] || { PARSE_ERR="gen 不是恰好 +1 (${SM[GEN0]} → ${SM[GEN1]}) ⇒ 这一代不是我触发的/有并发写者; **读数不可归因, 整轮作废**"; return 1; }
  for k in MAGIC BID MARKER UNIMPL; do
    [[ "${SM[$k]:-}" =~ ^0[xX][0-9a-fA-F]{1,8}$ ]] || { PARSE_ERR="缺/坏 $k ('${SM[$k]:-}')"; return 1; }
  done
  return 0
}
# parse_nic <file> → NC[<key>] + NT0/NT1
parse_nic(){
  PARSE_ERR=""; NC=(); NT0=""; NT1=""; local k v v2
  while read -r k v v2 || [ -n "${k:-}" ]; do
    k=${k%$'\r'}; v=${v:-}; v2=${v2:-}      # fix2(c) 防御: 同上
    case "$k" in
      NIC_BEGIN|NIC_END|"") :;;
      TLATCH) NT0=$v; NT1=${v2:-};;
      *) [[ "$v" =~ ^[0-9]+$ ]] || { PARSE_ERR="NIC 字段 $k 的值 '$v' 不是十进制 (没采到/解析失败)"; return 1; }
         NC[$k]=$v;;
    esac
  done < "$1"
  [ -n "$NT0" ] && [ -n "$NT1" ] || { PARSE_ERR="NIC 文本缺 TLATCH"; return 1; }
  local need="rx_eth_crc_err port_rx_good port_rx_bad port_rx_bytes port_rx_packets port_rx_unicast port_rx_64 port_rx_1024_to_15xx port_rx_multicast"
  for k in $need; do [ -n "${NC[$k]:-}" ] || { PARSE_ERR="NIC 文本缺字段 $k"; return 1; }; done
  return 0
}
# snap_copy <A|B|C|D>: 把刚解析的 SW/SM 复制到 <P>_SW/<P>_* (前缀由本脚本写死 ⇒ eval 安全)
snap_copy(){ local p="$1"; eval "${p}_SW=(\"\${SW[@]}\")"
  for k in GEN0 GEN1 T0 T1 MAGIC BID MARKER UNIMPL; do eval "${p}_$k=\${SM[$k]}"; done; }
nic_copy(){ local p="$1" k; eval "${p}_NC=()"
  for k in "${!NC[@]}"; do eval "${p}_NC[\$k]=\${NC[\$k]}"; done
  eval "${p}_T0=\$NT0"; eval "${p}_T1=\$NT1"; }

# ---- 判据层 (纯函数) ----------------------------------------------------------
check_identity(){ # <标签> <MAGIC> <BID> <MARKER>
  local tg="$1" mg="$2" bd="$3" mk="$4"
  if [ "$mg" = "0x50360001" ] && [ "$(( bd ))" -eq "$(( EXPECT_BID ))" ] && [ "$mk" = "$MARKER_EXP" ]; then
    res PASS "G1" "位流身份 ($tg)" "MAGIC=0x50360001 BID=$EXPECT_BID MARKER=$MARKER_EXP" "MAGIC=$mg BID=$bd MARKER=$mk"; return 0
  fi
  res FAIL "G1" "位流身份 ($tg)" "MAGIC=0x50360001 BID=$EXPECT_BID MARKER=$MARKER_EXP" \
      "MAGIC=$mg BID=$bd MARKER=$mk ⇒ 不是本轮位流, 后面所有读数都不算数"; return 1
}
check_window(){ # <标签> <unimpl 值> <数组名>
  local tg="$1" un="$2"; local -n W="$3"
  local i nff=0
  for (( i = 0; i < SNAP_WORDS; i++ )); do [ "${W[$i]}" = "4294967295" ] && nff=$(( nff+1 )); done
  [ "$nff" -eq 0 ] && res PASS "B_WIN" "$tg 窗口 $SNAP_WORDS 字齐全且无 0xffffffff" "0 个 F" "0 个 F (SLVERR 没混进窗口)" \
                   || res FAIL "B_WIN" "$tg 窗口内不得出现 0xffffffff" "0 个 F" "$nff 个 F ⇒ 这些是**读失败**, 不是数据"
  if [ "$(( un ))" -eq 4294967295 ]; then res PASS "B_UNIMPL" "$tg 未实现地址 $UNIMPL_ADDR" "0xffffffff" "0xffffffff"
  else res FAIL "B_UNIMPL" "$tg 未实现地址 $UNIMPL_ADDR" "0xffffffff" "$un ⇒ 译码过宽, 或该地址其实是已实现字 (窗口挪了地址没挪)"; fi
}
check_freq(){ # <判据号> <名> <a> <b> <t0a> <t1a> <t0b> <t1b> <标称MHz> <除数>
  local id="$1" nm="$2" a="$3" b="$4" t0a="$5" t1a="$6" t0b="$7" t1b="$8" nom="$9" div="${10}"
  local dt d f
  dt=$(dt2 "$t0a" "$t1a" "$t0b" "$t1b"); d=$(dd32 "$a" "$b")
  if le "$dt" 0.05; then res SKIP "$id" "$nm 频率" "Δ/墙钟" "窗口 ${dt}s 太短 (合成文本里 TLATCH 相同?) ⇒ 反解不出频率"; return 0; fi
  if ! le "$dt" 20; then res SKIP "$id" "$nm 频率" "窗口 <20s" "窗口 ${dt}s ⇒ 32 位计数可能已回绕 (27.49s 一圈), 本轮不判"; return 0; fi
  f=$(hz2mhz "$d" "$dt" "$div")
  if in_pct "$f" "$nom" 1.0; then res PASS "$id" "$nm = $f MHz (Δ=$d / ${dt}s / ÷$div)" "$nom ±1%" "$f MHz"
  else res FAIL "$id" "$nm 频率" "$nom ±1%" "$f MHz (Δ=$d / ${dt}s / ÷$div) ⇒ 该域没起 / 计数被钉死 / 窗口里回绕过"; fi
}
# ⚠️ W50 的口径**在源码里是自相矛盾的, 不许猜** (本工程"未核实项不许当结论用"):
#   `board/wrapper_p4.v:3389` 的注释写"频率 = 沿数/2", 但 RTL (`:3387-3400`) 是
#   `tx_tgl_tx <= ~tx_tgl_tx` —— **每拍 tx_fe_clk 翻转一次**, dp 侧数的是**每次变化**
#   ⇒ 数学上 沿数/秒 = tx_fe_clk 频率, 也就是 **÷1**; 若按 ÷2 读会得到 78.125 MHz = **假 FAIL**。
#   两种口径差正好 2 倍, 不烧板判不了 ⇒ 本函数**两个都算**, 命中哪个就把它记下来
#   (命中 ÷1 ⇒ 注释错了要订正; 命中 ÷2 ⇒ 我这段分析错了) —— 一次上板就把这条钉死。
check_freq_tgl(){ # <判据号> <名> <a> <b> <t0a> <t1a> <t0b> <t1b> <标称MHz>
  local id="$1" nm="$2" a="$3" b="$4" t0a="$5" t1a="$6" t0b="$7" t1b="$8" nom="$9"
  local dt d f1 f2
  dt=$(dt2 "$t0a" "$t1a" "$t0b" "$t1b"); d=$(dd32 "$a" "$b")
  if le "$dt" 0.05; then res SKIP "$id" "$nm 频率" "Δ/墙钟" "窗口 ${dt}s 太短 ⇒ 反解不出频率"; return 0; fi
  if ! le "$dt" 20; then res SKIP "$id" "$nm 频率" "窗口 <20s" "窗口 ${dt}s ⇒ 32 位计数可能已回绕, 本轮不判"; return 0; fi
  f1=$(hz2mhz "$d" "$dt" 1); f2=$(hz2mhz "$d" "$dt" 2)
  if in_pct "$f1" "$nom" 1.0; then
    res PASS "$id" "$nm = $f1 MHz (**÷1 口径命中**)" "$nom ±1%" "÷1 ⇒ $f1 / ÷2 ⇒ $f2 (⇒ wrapper_p4.v:3389 的 '÷2' 注释需订正)"
  elif in_pct "$f2" "$nom" 1.0; then
    res PASS "$id" "$nm = $f2 MHz (**÷2 口径命中**)" "$nom ±1%" "÷1 ⇒ $f1 / ÷2 ⇒ $f2 (⇒ 注释的 ÷2 成立, 本文档的分析需订正)"
  else
    res FAIL "$id" "$nm 频率" "$nom ±1% (两种口径之一)" "÷1 ⇒ $f1 / ÷2 ⇒ $f2 都不命中 (Δ=$d / ${dt}s) ⇒ 该域没起 / 计数被钉死"
  fi
}
check_cons(){ # <数组名> 停机态守恒律
  local -n W="$1"
  local a=${W[0]} b=${W[1]} c=${W[32]} e=${W[33]} x=${W[30]} y=${W[31]}
  local rx=$(( (a + c) % W32 )) ry=$(( (b - 4*a + e) % W32 )); [ "$ry" -lt 0 ] && ry=$(( ry + W32 ))
  [ "$x" -eq "$rx" ] && res PASS "B_CONS-a" "W30 == W0 + W32" "$rx" "$x" \
                     || res FAIL "B_CONS-a" "W30 == W0 + W32" "$rx" "$x (差 $(( x - rx )) ⇒ CDC 丢/重帧)"
  [ "$y" -eq "$ry" ] && res PASS "B_CONS-b" "W31 == W1 - 4*W0 + W33" "$ry" "$y" \
                     || res FAIL "B_CONS-b" "W31 == W1 - 4*W0 + W33" "$ry" "$y (差 $(( y - ry )) ⇒ CDC 丢/重字节)"
  [ "$(( a - x ))" -ge -1 ] && res PASS "B_DIR" "链式触发方向性 W0 - W30 >= -1" ">=-1" "$(( a - x ))" \
                           || res FAIL "B_DIR" "链式触发方向性 W0 - W30 >= -1" ">=-1" "$(( a - x )) ⇒ 两束被写反了?"
}
check_pcs(){ # <数组名>
  local -n W="$1"; local v=${W[39]}
  if [ "$(bit $v 29)" = 1 ] && [ "$(bit $v 2)" = 1 ] && [ "$(bit $v 3)" = 1 ] \
     && [ "$(bit $v 4)" = 0 ] && [ "$(bit $v 5)" = 0 ] && [ "$(bit $v 6)" = 0 ]; then
    res PASS "C1-C5" "PCS: gtpowergood/block_lock/rx_status=1 且 hi_ber/local_fault=0" "全成立" "W39=0x$(printf '%08X' $v)"
  else res FAIL "C1-C5" "PCS 状态位" "gpw=1 blk=1 st=1 ber=0 lf=0" \
      "W39=0x$(printf '%08X' $v) (gpw=$(bit $v 29) blk=$(bit $v 2) st=$(bit $v 3) ber=$(bit $v 4) rlf=$(bit $v 5) tlf=$(bit $v 6))"; fi
  if [ "$(bit $v 21)" = 0 ] && [ "$(bit $v 11)" = 0 ] && [ "$(bit $v 10)" = 0 ] && [ "$(bit $v 8)" = 0 ] && [ "$(( v & 0x003FE000 ))" -eq 0 ]; then
    res PASS "C6-C7" "rx_error/fifo_error/bad_code_valid/framing_err_valid 全 0" "全 0" "W39=0x$(printf '%08X' $v)"
  else res FAIL "C6-C7" "PCS 的 err 位必须全 0" "全 0" "W39=0x$(printf '%08X' $v)"; fi
}
# ⚠️ fix3 归因 (2026-09-30, **本函数逻辑一字未改** —— 如实记录, 不许为凑绿改判据):
#   C8 判"valid_ctrl_code **持续增长**"在 8 位**饱和**计数器 (`wrapper_p4.v:3366-3379`,
#   源码注释自己写着"不得当精确事件数引用") 上**结构性不可判**: dp_clk 156.25 MHz ⇒ 1.6 µs
#   就饱和到 0xFF。板级实测 255 → 255 ⇒ 判 FAIL (判据口径), 但归因是**观测量设计上限**,
#   不是被测设计的状态问题; C8 想防的"恒 0 假干净"**没有发生** (正证据: 非 0 = 255)。
#   ⇒ 该条登记为"已知观测量上限", 纠错方向 = 加宽计数器/加 tick 位 (**观测面改动**)。
#   详见 `_proj_10g/notes/P7B_GATE4_CRITERIA_CLOSEOUT.md` §5。
check_evt(){ # <数组名1> <数组名2|->  W40: C8 正证据 + 事件计数恒 0
  local -n W="$1"; local v1=${W[40]}
  local evt1=$(( (v1 >> 8) & 0xffffff )) vcc1=$(( v1 & 0xff ))
  if [ "$2" != "-" ]; then
    local -n W2="$2"; local v2=${W2[40]}
    local vcc2=$(( v2 & 0xff )) evt2=$(( (v2 >> 8) & 0xffffff ))
    [ "$vcc2" -gt "$vcc1" ] && res PASS "C8" "W40.valid_ctrl_code_cyc 非 0 且在涨 (⭐正证据)" "> $vcc1" "$vcc1 → $vcc2" \
                            || res FAIL "C8" "W40.valid_ctrl_code_cyc 必须非 0 且在涨" "> $vcc1" "$vcc1 → $vcc2 (钉死 ⇒ 这条例数不是来自核)"
    [ "$evt1" -eq 0 ] && [ "$evt2" -eq 0 ] && res PASS "C6-ev" "W40 的 framing/bad_code/rx_error 事件计数恒 0" "0/0" "0/0" \
                                          || res FAIL "C6-ev" "W40 事件计数必须恒 0" "0/0" "$evt1/$evt2"
  else
    res SKIP "C8" "W40.valid_ctrl_code_cyc 在涨" ">0 且随窗口单调增" "只有一块 ⇒ 判不了'在涨' (vcc=$vcc1)"
    [ "$evt1" -eq 0 ] && res PASS "C6-ev" "W40 事件计数恒 0 (单块)" "0" "0" || res FAIL "C6-ev" "W40 事件计数恒 0" "0" "$evt1"
  fi
}
check_nic(){ # <标签> <want:1 测量窗 / 0 基线窗> <前缀1> <前缀2>
  local tg="$1" want="$2" p1="$3" p2="$4"
  local -n A="${p1}_NC" B="${p2}_NC"
  local t0a=${p1}_T0 t1a=${p1}_T1 t0b=${p2}_T0 t1b=${p2}_T1
  local dt dg dbad dpkt dbyt duni d1518 d64 dcrc avg mbps_v
  dt=$(dt2 "${!t0a}" "${!t1a}" "${!t0b}" "${!t1b}")
  dg=$(( B[port_rx_good] - A[port_rx_good] ))
  dbad=$(( B[port_rx_bad] - A[port_rx_bad] ))
  dpkt=$(( B[port_rx_packets] - A[port_rx_packets] ))
  dbyt=$(( B[port_rx_bytes] - A[port_rx_bytes] ))
  duni=$(( B[port_rx_unicast] - A[port_rx_unicast] ))
  d1518=$(( B[port_rx_1024_to_15xx] - A[port_rx_1024_to_15xx] ))
  d64=$(( B[port_rx_64] - A[port_rx_64] ))
  dcrc=$(( B[rx_eth_crc_err] - A[rx_eth_crc_err] ))
  mbps_v=$(mbps "$dbyt" "$dt")
  if [ "$want" = "0" ]; then
    # ⭐ 判别力自检: 同一套 N_RATE **必须不成立** (否则判据被背景流量满足 = 真空门)
    if [ "$dg" -lt "$NIC_GOOD_MIN" ]; then
      res PASS "N_BASE" "$tg: 速率判据**不成立** ⇒ 该判据有判别力" "< $NIC_GOOD_MIN 帧" "Δport_rx_good=$dg / ${dt}s (背景)"
    else res FAIL "N_BASE" "$tg: 速率判据必须不成立 (判别力自检)" "< $NIC_GOOD_MIN 帧" "Δ=$dg ⇒ 背景已满足阈值 ⇒ 该判据是**真空门**"; fi
    return 0
  fi
  [ "$dcrc" -eq 0 ] && res PASS "N_CRC" "$tg Δrx_eth_crc_err == 0" "0" "0" \
                    || res FAIL "N_CRC" "$tg Δrx_eth_crc_err == 0" "0" "$dcrc (FCS 错帧 ⇒ 立刻停, 回 mac_tx_10g 的 pad/FCS 修复)"
  [ "$dbad" -eq 0 ] && res PASS "N_BAD" "$tg Δport_rx_bad == 0" "0" "0" \
                    || res FAIL "N_BAD" "$tg Δport_rx_bad == 0" "0" "$dbad"
  if [ "$dg" -ge "$NIC_GOOD_MIN" ] && ge "$mbps_v" "$NIC_MBPS_MIN"; then
    res PASS "N_RATE" "$tg 增量 + 速率阈值" "Δ>=$NIC_GOOD_MIN 帧 且 >=$NIC_MBPS_MIN Mbps" "Δ=$dg 帧 / ${dt}s = $mbps_v Mbps"
  else res FAIL "N_RATE" "$tg 增量 + 速率阈值" "Δ>=$NIC_GOOD_MIN 帧 且 >=$NIC_MBPS_MIN Mbps" "Δ=$dg 帧 / ${dt}s = $mbps_v Mbps"; fi
  if [ "$dg" -gt 0 ] && ge "$duni" "$(awk -v g="$dg" 'BEGIN{print 0.9*g}')"; then
    res PASS "N_UCAST" "$tg Δport_rx_unicast 同步涨 (图案是单播)" ">=0.9Δgood" "Δuni=$duni / Δgood=$dg"
  else res FAIL "N_UCAST" "$tg Δport_rx_unicast 同步涨" ">=0.9Δgood" "Δuni=$duni / Δgood=$dg (涨的是广播 ⇒ 是板子背景, 不是图案)"; fi
  if [ "$dg" -gt 0 ] && ge "$d1518" "$(awk -v g="$dg" 'BEGIN{print 0.9*g}')" && le "$d64" "$(awk -v g="$dg" 'BEGIN{print 0.1*g}')"; then
    res PASS "N_LEN" "$tg 长度桶: 1518B 占绝对多数" "1024_15xx>=0.9Δgood 且 64<=0.1Δgood" "1518桶=$d1518 64桶=$d64 Δgood=$dg"
  else res FAIL "N_LEN" "$tg 长度桶" "1024_15xx>=0.9Δgood 且 64<=0.1Δgood" "1518桶=$d1518 64桶=$d64 Δgood=$dg (背景是 64/66B 小帧)"; fi
  if [ "$dpkt" -gt 0 ]; then
    avg=$(awk -v b="$dbyt" -v p="$dpkt" 'BEGIN{printf "%.6f", b/p}')
    if ge "$avg" 1517.5 && le "$avg" 1518.5; then res PASS "N_AVG" "$tg Δbytes/Δpackets ≈ 1518.000000" "[1517.5,1518.5]" "$avg"
    else res FAIL "N_AVG" "$tg Δbytes/Δpackets ≈ 1518.000000" "[1517.5,1518.5]" "$avg"; fi
  else res SKIP "N_AVG" "$tg Δbytes/Δpackets" "≈1518.000000" "Δpackets=0"; fi
  # ⭐ fix3: 自洽判据改成**带容差 + 报端点内残差** (原来要求"逐字相等" ⇒ 前提不成立, 见下)。
  #   为什么: 三个字段**不是同一次原子快照**。实测 `nic_D.txt` **单个 dump 内部**就
  #   `good + bad = packets + 1` (其余 5 个 dump 残差 0) ⇒ NIC 的 RX 通路上有两个计数点,
  #   一次快照至多落在一帧"在飞"之间 ⇒ **±1 每端点** (证据 = closeout §3.2)。
  #   判别力不受影响: 真缺陷 (有一类帧记进 packets 却既不算 good 也不算 bad) 会让残差**随帧数
  #   增长** —— 4 s 窗 @106k fps 下 1% 就是 4000 帧, 与 ±2 差三个数量级 (反例实测: 残差 −21200 ⇒ FAIL)。
  local rA rB dres
  rA=$(( A[port_rx_good] + A[port_rx_bad] - A[port_rx_packets] ))
  rB=$(( B[port_rx_good] + B[port_rx_bad] - B[port_rx_packets] ))
  dres=$(( rB - rA ))
  if [ "${rA#-}" -le 1 ] && [ "${rB#-}" -le 1 ] && [ "${dres#-}" -le 2 ]; then
    res PASS "N_SELF" "$tg 自洽: Δgood + Δbad == Δpackets (±2)" "端点内残差 ≤1 且 Δ残差 ≤2" \
      "$dg + $dbad - $dpkt = $dres (端点内残差 A=$rA B=$rB; ±1 = 两个计数点之间的在飞帧)"
  else
    res FAIL "N_SELF" "$tg 自洽: Δgood + Δbad == Δpackets (±2)" "端点内残差 ≤1 且 Δ残差 ≤2" \
      "$dg + $dbad - $dpkt = $dres (端点内残差 A=$rA B=$rB) ⇒ **超容差**: 有一类帧记进 packets 却不进 good/bad (驱动丢弃/分类缺口)"
  fi
}
# ---- N_XCHK: 跨设备帧率对账 (**旁证**, 不是 F4 的独立口径) ----------------------
# 名称里那个"(旁证)"是**判据的一部分, 不是措辞**: 这条判据的主机侧那一半**不是独立的硬件计数**。
#   ① `ethtool -S` 的 `port_rx_packets/bytes` 与内核 `rx_packets/rx_bytes` **逐字相同**
#      (`kernel_vs_hw_counters.txt`: 1081941695 == 1081941695; 346179975404 == 346179975404)
#      ⇒ 同一个数被报了两遍 (与 P6b 对 `port_tx_*` 的发现同族);
#   ② 该计数的**更新量子 ≈1 s**: `var_probe` 三轮**同长窗** (4.0116/4.0115/4.0120 s) 里它只走过
#      4.995 / 3.295 / 3.996 s 的流量 (同期板侧 W20 = 106,000/105,996/106,001 fps, ±0.002%;
#      pcap 时间戳第三条路径站在板侧一边) ⇒ 窗口短于 ~20 s 时它**结构性反解不到 1%**。
#   ⇒ 判据 = 同刻 + 窗口 ≥20 s + 容差 max(1%, 2·Q/dt); 结论只作旁证。
#   F4 的独立口径 = **pcap 时间戳** (对端 `notes/p7b_gate4_2/peer/rate_probe.sh`, 已两次实测
#   105,949 / 105,944 fps vs 板侧 105,985 fps ⇒ 偏差 0.05%; 见 closeout §4)。
check_xchk(){ # <ΔW20> <板侧dt> <Δport_rx_packets> <Δport_rx_bytes> <NIC侧dt> <端点0时差s> <端点1时差s>
  local d20="$1" dtb="$2" dpkt="$3" dbyt="$4" dtn="$5" off0="$6" off1="$7"
  local tol bfps nfps dev bmbps nmbps
  # 守卫 1: **同刻** —— 两个口径的取数时刻必须成对接近; 否则量的不是同一段时间, 算出来的"偏差"
  #   只是板子速率的漂移与背景流量 (本轮真实运行正是这种形态: 板侧窗与 NIC 窗错开 8~12 s)。
  if ! awk -v a="$off0" -v b="$off1" -v m="$XCHK_MAX_OFFSET" 'BEGIN{exit !(a<=m && b<=m)}'; then
    res SKIP "N_XCHK" "测量 两口径**同刻** (取数时刻差 ≤ ${XCHK_MAX_OFFSET}s)" "≤ ${XCHK_MAX_OFFSET}s" \
      "端点时差 A=${off0}s B=${off1}s ⇒ 两口径量的**不是同一段** ⇒ 本条不成立 (是**取数编排**的问题, 不是板子的)"
    return 0
  fi
  if [ "$d20" -eq 0 ]; then
    res SKIP "N_XCHK" "板侧 W20 增量 (旁证)" ">0" "ΔW20=0 (板子没在发) ⇒ 无从对账"; return 0
  fi
  # 守卫 2: **分辨率** —— 参考侧量子 Q≈1 s ⇒ 窗口 <20 s 时它反解不到 1% (结构性, 与板子无关)
  if ! awk -v t="$dtn" 'BEGIN{exit !(t>=20)}'; then
    res SKIP "N_XCHK" "对账窗口 ≥ 20 s (参考侧更新量子 ≈${XCHK_Q}s)" "≥ 20s" \
      "NIC 窗口 ${dtn}s ⇒ 量子/窗口 = $(awk -v t="$dtn" -v q="$XCHK_Q" 'BEGIN{printf "%.0f", 100*q/t}')% ⇒ 参考侧**反解不到 1%**, 本轮不判 (改 XCHK_SECS 加长窗口再跑)"
    return 0
  fi
  tol=$(awk -v t="$dtn" -v q="$XCHK_Q" -v b="$NIC_TOL_BASE" 'BEGIN{r=200*q/t; if(r<b)r=b; printf "%.2f", r}')
  bfps=$(awk -v f="$d20"  -v t="$dtb" 'BEGIN{printf "%.3f", (t>0)? f/t : 0}')
  nfps=$(awk -v f="$dpkt" -v t="$dtn" 'BEGIN{printf "%.3f", (t>0)? f/t : 0}')
  bmbps=$(awk -v f="$d20"  -v t="$dtb" 'BEGIN{printf "%.2f", (t>0)? f*1518*8/t/1e6 : 0}')
  nmbps=$(mbps "$dbyt" "$dtn")
  dev=$(awk -v a="$bfps" -v b="$nfps" 'BEGIN{printf "%.2f", (b>0)? (b-a)/b*100 : 0}')
  if in_pct "$bfps" "$nfps" "$tol"; then
    res PASS "N_XCHK" "测量 跨设备帧率对账 (**旁证**: 主机侧非独立硬件计数)" "偏差 < ${tol}%" \
      "板侧 $bfps fps vs 主机侧 $nfps fps (偏差 ${dev}%; 同刻窗 板 ${dtb}s / 主机 ${dtn}s; 字节口径 板 $bmbps / 主机 $nmbps Mbps)"
  else
    res FAIL "N_XCHK" "测量 跨设备帧率对账 (**旁证**: 主机侧非独立硬件计数)" "偏差 < ${tol}%" \
      "板侧 $bfps fps vs 主机侧 $nfps fps (偏差 ${dev}%) ⇒ 超容差; **下一步**: 先用 pcap 时间戳口径复算 (独立), 再怀疑板侧 W20"
  fi
}

# ---- 主流程 ------------------------------------------------------------------
main(){
  mkdir -p "$OUTDIR"
  hr "0. 位流身份 (G1 的位流一半) 与前置"
  if [ -f "$BIT" ]; then
    echo "  [INFO] 位流 = $BIT"
    echo "  [INFO] sha256 = $(sha256sum "$BIT" | awk '{print $1}')"
    echo "  [INFO] size   = $(wc -c < "$BIT") ; mtime = $(date -r "$BIT" '+%F %T')"
  else
    echo "  [WARN] 找不到位流 $BIT ⇒ G1 少了 sha256 那一半 (必须在验收报告里如实标注)"
  fi

  local OFFLINE=0; [ -n "${G4_SNAP_TEXT:-}${G4_NIC_TEXT:-}" ] && OFFLINE=1

  # ---------- 块数: **判据要几块就取几块** (fix2 (a)) ----------------------------
  #   A/B = 停机态两点 ⇒ G2 频率(两点差) / G3 守恒(方向性 B_DIR) / C 组 PCS / C8 "在涨"
  #   C/D = 打流后洪泛两点 ⇒ E4-G6(ΔW34) / N_XCHK(ΔW20 对账)
  #   ⚠️ 旧版 live 档 `nsf` 恒 1 ⇒ 上面那一整列判据**全被 SKIP**(合成文本路径看不出来)。
  local nsf
  if [ "$OFFLINE" = 1 ]; then
    nsf=1; [ -n "${G4_SNAP_TEXT:-}" ] && nsf=$(count_items "$G4_SNAP_TEXT")
  else
    nsf=2; [ "$G4_SKIP_TRAFFIC" = "1" ] || nsf=4
    echo "  [INFO] **live 档**: 按判据需要取 **$nsf 块**快照 (旧版恒取 1 块 ⇒ G2/G3/C 组被 SKIP)"
  fi
  # 取第 n 块 (1-based): live = 真取 (第 2 块起先等 5 s, 频率/增量判据要真实的间隔);
  # 离线 = 直接从逗号列表里取 (既有负对照行为, 一字不变)
  snap_block(){   # 用法: f=$(snap_block <n> <落盘路径>)
    local n="$1" f="$2"
    if [ "$OFFLINE" = 1 ]; then pick "$G4_SNAP_TEXT" "$n"; return 0; fi
    if [ "$n" -gt 1 ]; then echo "  (等 5 s 再取第 $n 块 —— 频率与增量判据需要两点)" >&2; sleep 5; fi
    snap_fetch > "$f" || return 1
    echo "$f"
  }

  # ---------- 块 A ----------
  local sf1
  if [ "$OFFLINE" = 1 ]; then
    echo "  [INFO] **离线/负对照模式**: 读数来自合成文本, 不碰板子/对端机"
    sf1=$(pick "$G4_SNAP_TEXT" 1); parse_snap "$sf1" || { fatal "合成快照块1: $PARSE_ERR"; }
  else
    sf1=$(snap_block 1 "$OUTDIR/snap_A.txt") || fatal "快照块 A 取数失败"
    if ! parse_snap "$sf1"; then fatal "快照块 A 解析: $PARSE_ERR"; fi
  fi
  if [ "$FATAL" = 0 ]; then
    snap_copy A; check_identity "块A" "$A_MAGIC" "$A_BID" "$A_MARKER" || fatal "身份不符 ⇒ 拒绝继续 (G1 前置闸)"
    check_window "块A" "$A_UNIMPL" A_SW
  fi
  if [ "$FATAL" != 0 ]; then echo; echo "  [ABORT] 前置闸未过 ⇒ 后面的读数都不算数"; echo "-------- 原始文本 --------"; cat "$sf1"; echo "########## PASS=$PASS FAIL=$FAIL SKIP=$SKIP ##########"; exit 2; fi

  # ---------- 块 B (停机态第二点) ----------
  local sf2
  if [ "$nsf" -lt 2 ]; then
    echo "  [SKIP] 只给了一块快照 ⇒ 频率/守恒/增量判据全部无法判 (需要两点)"
  else
    sf2=$(snap_block 2 "$OUTDIR/snap_B.txt") || fatal "快照块 B 取数失败"
    if parse_snap "$sf2"; then
      snap_copy B
      check_identity "块B" "$B_MAGIC" "$B_BID" "$B_MARKER" || fatal "块 B 身份不符"
      check_window "块B" "$B_UNIMPL" B_SW
      check_freq "G2-W5"  "前端域 gmii_free"   "${A_SW[5]}"  "${B_SW[5]}"  "$A_T0" "$A_T1" "$B_T0" "$B_T1" "$W5_NOM_MHZ" 1
      check_freq "G2-W24" "数据面域 dp_free"   "${A_SW[24]}" "${B_SW[24]}" "$A_T0" "$A_T1" "$B_T0" "$B_T1" 156.25 1
      check_freq_tgl "G2-W50" "TX 域 tx_clk_act" "${A_SW[50]}" "${B_SW[50]}" "$A_T0" "$A_T1" "$B_T0" "$B_T1" 156.25
      check_cons A_SW
      check_pcs A_SW
      check_evt A_SW B_SW
    else fatal "快照块 B 解析: $PARSE_ERR"; fi
  fi
  if [ "$FATAL" != 0 ]; then
    echo; echo "  [ABORT] 快照块结构/身份未过 ⇒ **整轮读数不可用** (退出 2): $PARSE_ERR"
    echo "########## PASS=$PASS FAIL=$FAIL SKIP=$SKIP ##########"; exit 2
  fi

  # ---------- NIC 侧 ----------
  local nicn=1; [ -n "${G4_NIC_TEXT:-}" ] && nicn=$(count_items "$G4_NIC_TEXT")
  hr "NIC 侧: 基线窗 (教学前) —— 含**判别力自检** N_BASE"
  if [ "$OFFLINE" = 1 ]; then
    if [ "$nicn" -ge 4 ]; then
      parse_nic "$(pick "$G4_NIC_TEXT" 1)" && nic_copy NB || fatal "合成 NIC 块1: $PARSE_ERR"
      parse_nic "$(pick "$G4_NIC_TEXT" 2)" && nic_copy NQ || fatal "合成 NIC 块2: $PARSE_ERR"
      abort_if_fatal "NIC 基线窗"
      check_nic "基线" 0 NB NQ
    elif [ "$nicn" -eq 2 ]; then
      res SKIP "N_BASE" "基线窗判别力自检" "判据必须不成立" "只给了 2 个 NIC 文本 ⇒ 当测量窗用, 基线自检无从做"
    else fatal "G4_NIC_TEXT 至少要 2 个文件"; abort_if_fatal "NIC 文本清单"; fi
  else
    nic_fetch > "$OUTDIR/nic_A.txt"; sleep 5; nic_fetch > "$OUTDIR/nic_B.txt"
    parse_nic "$OUTDIR/nic_A.txt" && nic_copy NB || fatal "NIC 块 A: $PARSE_ERR"
    parse_nic "$OUTDIR/nic_B.txt" && nic_copy NQ || fatal "NIC 块 B: $PARSE_ERR"
    if [ "$FATAL" != 0 ]; then
      echo; echo "  [ABORT] NIC 基线窗取数/解析失败 ⇒ **NIC 判据全部作废** (退出 2): $PARSE_ERR"
      echo "        先查: 口名对不对 (G4_IFACE=$IFACE) / ethtool 在不在 / ssh 通不通"
      echo "########## PASS=$PASS FAIL=$FAIL SKIP=$SKIP ##########"; exit 2
    fi
    check_nic "基线" 0 NB NQ
  fi

  hr "测量窗 (教学 → 打流 → **板侧 C** → NIC C/D → **板侧 D**)"
  local d20=0
  if [ "$OFFLINE" = 1 ]; then
    if [ "$nicn" -ge 4 ]; then
      parse_nic "$(pick "$G4_NIC_TEXT" 3)" && nic_copy NB || fatal "合成 NIC 块3: $PARSE_ERR"
      parse_nic "$(pick "$G4_NIC_TEXT" 4)" && nic_copy NQ || fatal "合成 NIC 块4: $PARSE_ERR"
      abort_if_fatal "NIC 测量窗"
      check_nic "测量" 1 NB NQ
    elif [ "$nicn" -eq 2 ]; then
      parse_nic "$(pick "$G4_NIC_TEXT" 1)" && nic_copy NB || fatal "合成 NIC 块1: $PARSE_ERR"
      parse_nic "$(pick "$G4_NIC_TEXT" 2)" && nic_copy NQ || fatal "合成 NIC 块2: $PARSE_ERR"
      abort_if_fatal "NIC 测量窗"
      check_nic "测量" 1 NB NQ
    fi
    if [ "$nsf" -ge 4 ]; then
      parse_snap "$(pick "$G4_SNAP_TEXT" 3)" && snap_copy C || fatal "合成快照块3: $PARSE_ERR"
      parse_snap "$(pick "$G4_SNAP_TEXT" 4)" && snap_copy D || fatal "合成快照块4: $PARSE_ERR"
    fi
    # ⭐ fix3: 离线也能判 T_RUN/T_TOOL (喂一份与远端回显同形的激励日志即可; 判据层与 I/O 层分离)
    if [ -n "${G4_TRAFFIC_TEXT:-}" ]; then run_traffic >/dev/null; check_traffic "离线"; fi
  elif [ "$G4_SKIP_TRAFFIC" = "1" ]; then
    res SKIP "N_RATE" "测量窗" "需要打流" "G4_SKIP_TRAFFIC=1 ⇒ 本段没跑 (按 P7B_GATE4_PLAN.md 步骤 5 打流后重跑)"
  else
    echo "  [INFO] 教学 + 图案激励 (远端实收命令见下, 首词已加 true; 免疫 MSYS 路径改写): $G4_TRAFFIC_CMD"
    peer --sudo "ip addr add $MYIP/32 dev $IFACE 2>/dev/null; ip route add $BOARD_IP/32 dev $IFACE src $MYIP 2>/dev/null; ip route get $BOARD_IP" || true
    run_traffic || echo "  [WARN] 图案工具退出码非 0 (读上面的 gap/bad 汇总; gap=接收侧掉包, bad=真失配)"
    check_traffic "打流"          # ⭐ 先回答"激励到底跑了没有", 再看 NIC 判据 (fix2 (b))
    # ⭐ fix3 (取数编排): **板侧 C 先取**, 然后 NIC C → 睡 → NIC D, 最后板侧 D ⇒
    #   板侧窗 [snap_C.latch, snap_D.latch] **包住** NIC 窗 [nic_C, nic_D], 两端各差 ~0.05 s
    #   ⇒ N_XCHK 的两个口径**同刻** (旧序是 NIC 先、板侧后 ⇒ 错开 8~12 s, 见 closeout §3.3)。
    #   ⚠️ 顺序不可再换: 判据 check_xchk 的同刻守卫按"取数时刻差 ≤ ${XCHK_MAX_OFFSET}s"判。
    local sfC sfD
    echo "  (打流后取板侧 C: 它是 N_XCHK 板侧窗的起点 —— 必须先于 NIC C)"
    sfC=$(snap_block 3 "$OUTDIR/snap_C.txt") && parse_snap "$sfC" && snap_copy C || fatal "快照块 C: $PARSE_ERR"
    nic_fetch > "$OUTDIR/nic_C.txt"; sleep "$XCHK_SECS"; nic_fetch > "$OUTDIR/nic_D.txt"
    parse_nic "$OUTDIR/nic_C.txt" && nic_copy NB || fatal "NIC 块 C: $PARSE_ERR"
    parse_nic "$OUTDIR/nic_D.txt" && nic_copy NQ || fatal "NIC 块 D: $PARSE_ERR"
    if [ "$FATAL" != 0 ]; then
      echo; echo "  [ABORT] NIC 测量窗取数/解析失败 ⇒ **NIC 判据全部作废** (退出 2): $PARSE_ERR"
      echo "########## PASS=$PASS FAIL=$FAIL SKIP=$SKIP ##########"; exit 2
    fi
    check_nic "测量" 1 NB NQ
    echo "  (打流后取板侧 D: 与板侧 C 构成洪泛窗, ΔW34 与 ΔW20 对账用)"
    # ⚠️ 这里**不能**走 snap_block(带 5 s 等待): 那会让板侧 D 比 NIC D 晚 ~5.7 s,
    #   同刻守卫 (≤2 s) 必然触发 ⇒ 活体档 N_XCHK **永远 SKIP** (实测: livefake 的 full case
    #   报 `端点时差 B=5.712s`)。块 3/4 只用于 ΔW34/ΔW20 对账, 不需要人为拉开间隔 ⇒ 直接取。
    sfD=$(snap_fetch > "$OUTDIR/snap_D.txt" && echo "$OUTDIR/snap_D.txt") \
      && parse_snap "$sfD" && snap_copy D || fatal "快照块 D: $PARSE_ERR"
  fi
  # 洪泛窗: ΔW34 (E4/G6) 与 ΔW20 (N_XCHK 的板侧分子)
  if [ -n "${C_SW+x}" ] && [ -n "${D_SW+x}" ] && [ "${#C_SW[@]}" -gt 0 ]; then
    local d34; d34=$(dd32 "${C_SW[34]}" "${D_SW[34]}")
    [ "$d34" -eq 0 ] && res PASS "B_G6" "洪泛窗 ΔW34 (rx_stat_drop_full) == 0" "0" "0" \
                     || res FAIL "B_G6" "洪泛窗 ΔW34 (rx_stat_drop_full) == 0" "0" "$d34 (有 FIFO 空间不足丢帧)"
    d20=$(dd32 "${C_SW[20]}" "${D_SW[20]}")
  fi
  # ⭐ fix3 修正的**守卫 bug**: 旧版写 `[ -n "${NQ_NC+x}" ]` —— 对**关联数组**恒为假
  #   (bash: `${assoc+x}` 只测下标 0; 键是 port_rx_good 这类非数字串 ⇒ 下标 0 不存在 ⇒ 恒空)
  #   ⇒ 本条判据**结构性永不评估** (两轮验收都以为它在 SKIP, 其实连 SKIP 都没打印)。
  #   现在按**真实键**存在性判; 且两个口径必须同刻 (守卫在 check_xchk 里)。
  if [ -n "${NQ_NC[port_rx_packets]:-}" ] && [ -n "${NB_NC[port_rx_packets]:-}" ] \
     && [ -n "${C_T0:-}" ] && [ -n "${D_T0:-}" ]; then
    local dbyt dpkt dtb dtn off0 off1
    dbyt=$(( NQ_NC[port_rx_bytes]    - NB_NC[port_rx_bytes] ))
    dpkt=$(( NQ_NC[port_rx_packets]  - NB_NC[port_rx_packets] ))
    dtb=$(dt2 "$C_T0" "$C_T1" "$D_T0" "$D_T1")        # 板侧窗 (surrounds NIC 窗)
    dtn=$(dt2 "$NB_T0" "$NB_T1" "$NQ_T0" "$NQ_T1")    # NIC 窗
    off0=$(awk -v a="$C_T0" -v b="$NB_T0" 'BEGIN{printf "%.3f", (a>b)? a-b : b-a}')
    off1=$(awk -v a="$D_T1" -v b="$NQ_T1" 'BEGIN{printf "%.3f", (a>b)? a-b : b-a}')
    check_xchk "$d20" "$dtb" "$dpkt" "$dbyt" "$dtn" "$off0" "$off1"
  else
    echo "  [INFO] N_XCHK 未评估: $( [ -n "${NQ_NC[port_rx_packets]:-}" ] || echo 'NIC 测量窗未解析; ' )$( [ -n "${C_T0:-}" ] || echo '板侧 C 未取' )"
  fi

  hr "汇总"
  printf '  %s\n' "${SUM[@]}"
  echo "########## PASS=$PASS FAIL=$FAIL SKIP=$SKIP (窗口 $SNAP_WORDS 字; 未实现地址 $UNIMPL_ADDR; EXPECT_BID=$EXPECT_BID) ##########"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

if [ "${G4_LIB_ONLY:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi
main "$@"
