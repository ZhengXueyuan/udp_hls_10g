`timescale 1ns/1ps
//=============================================================================
// app_status_uart: app 接口独立快照行 (P5a) — 9600-8N1 ASCII, ~2s 一行
//
// 与 board/uart_dbg.v 的 P4 诊断行完全独立 (不改 uart_dbg.v — 那 443 字符
// 行是 P4 板级读出依赖)。本模块只复用其中的 uart_tx_9600 发送器 (8N1 字节
// 发送, !busy 时 tx_go 取字节), 行内容 = app 视角状态:
//
//   P5B1 ST=x NX=xxxxxxxx UA=xxxxxxxx RW=xxxx RN=xxxxxxxx RX=xxxxxxxx
//        TX=xxxxxxxx TF=xxxx MM=xxxx OC=xxxxx EV=xxxx DP=xxxx RY=xxxx
//        EC=xx DL=xxxx FI=xxxx RS=xxxx
//        AK=xxxx AD=xxxx TS=x WQ=xxxx WM=xxxx WU=xxxx PO=xxxxx PX=xxxx
//
//   ST = conn0 TCB state       NX/UA = conn0 snd_nxt / snd_una
//   RW = conn0 rcv_wnd         RN    = conn0 rcv_nxt
//   RX/TX = app 收/发字节      TF    = app 已发帧数
//   MM = app 失配字节数        OC    = RX 缓冲占用字节 (app 可读)
//   EV = 连接事件计数          DP    = 事件丢弃计数
//   RY = app_tx_ready[15:0]    EC    = ESTAB 连接数
//   DL = 超长帧丢弃计数        FI/RS = 已发 FIN/RST 计数
//   ---- P5b C9 追加 (板级病理定位缺观测: ACK 发没发/窗口收没收/池耗没耗) ----
//   AK = 已发 ACK 段数         AD    = ACK 队列满丢弃数
//   TS = tcp_tx_frame FSM state (0=S_IDLE...7=S_RING)
//   WQ = conn0 winq (接收配额) WM    = conn0 wu_mark (上次 wu 通告值)
//   WU = 窗口更新 ACK 发出数    PO    = 信用池余额 (17 位)
//   PX = 授予被池限制的连接数
//   ---- P5f 追加 (UDP app 通路板级观测缺口: P5e 只接 LED 读不出) ----
//   URB = app UDP 收字节       UMM   = app UDP 失配字节 (粘滞)
//   URF = app UDP 收帧数       UOV   = udp_split 缓冲溢出丢帧
//   UPC = udp_split 坏 FCS 丢帧 UPA  = udp_split 截断/残帧回卷
//   UTB = app UDP 发字节       UTF   = app UDP 发帧数
//
// 行 = 304 字符 (末尾 CR/LF), 9600 下 ~317ms。**除设计标识外** (index 2 起 4 字符
// 由 "P5A1" 改 "P5B1"), 前 156 字符的 [0,156) 区间与 P5a 逐字节相同 (P4 板级读出
// 依赖), 后续字段一律**追加在行尾** (P5b C9 追加到 220, P5f 追加到 304 —— 既有
// 字段的 ci 偏移**一律不动**, 只有行尾新增段需要算偏移)。字段值在行首 (ci==0)
// 一次性锁存 — 行内自洽; 行间 GAP 后重采。
// ⚠️ 追加字段必须**同步改** tb/tb_p5_status.v 与 tools/gen_stim_p5_app.py 的期望串
// (status 门是整行逐字节比对; 漏同步 = 门红)。
//=============================================================================
module app_status_uart #(
    parameter [13:0] BIT_LAST  = 14'd13020,        // 每比特拍数-1 @125MHz/9600
    parameter [27:0] GAP_TICKS = 28'd250_000_000   // 行间 ~2s
) (
    input  wire        clk,
    input  wire        rst_n,
    // 快照输入 (app 视角)
    input  wire [3:0]  st0,
    input  wire [31:0] snd_nxt,
    input  wire [31:0] snd_una,
    input  wire [15:0] rcv_wnd,
    input  wire [31:0] rcv_nxt,
    input  wire [31:0] stat_rx_bytes,
    input  wire [31:0] stat_tx_bytes,
    input  wire [15:0] stat_tx_frames,
    input  wire [15:0] stat_mismatch,
    input  wire [16:0] rx_occ,
    input  wire [15:0] ev_cnt,
    input  wire [15:0] ev_drop,
    input  wire [15:0] app_tx_ready,
    input  wire [15:0] estab_cnt,
    // W5: 板级可观测的帧器计数 (FIN 是否发出 / 坏帧是否被丢)
    input  wire [15:0] stat_drop_len,
    input  wire [15:0] stat_fin,
    input  wire [15:0] stat_rst,
    // P5b C9: 流控闭环观测
    input  wire [15:0] stat_ack,
    input  wire [15:0] stat_ack_drop,
    input  wire [2:0]  fsm_state,
    input  wire [15:0] winq0,
    input  wire [15:0] wu_mark0,
    input  wire [15:0] stat_wu,
    input  wire [16:0] pool,
    input  wire [15:0] stat_pool_exh,
    // P5f: UDP app 通路观测 (板级此前只能读 LED ⇒ 收发方向都读不出来)
    input  wire [31:0] udp_rx_bytes,
    input  wire [31:0] udp_mismatch,
    input  wire [15:0] udp_rx_frames,
    input  wire [15:0] udp_drop_ovf,
    input  wire [15:0] udp_drop_crc,
    input  wire [15:0] udp_drop_part,
    input  wire [31:0] udp_tx_bytes,
    input  wire [15:0] udp_tx_frames,
    output wire        txd
`ifdef RXP_DIAG
`ifdef APP_MODE
    // ---- RXP_DIAG (隐含 APP_MODE): 首失配快照字段 ----
    // 端口**追加在最后** (不插在 txd 之前): 否则同一份源码在不同配置下端口顺序
    // 不同, 任何按位置例化的调用点都会静默接错。
    // 双宏嵌套: 只定义 RXP_DIAG 时本模块不新增端口 ⇒ wrapper 里 (APP_MODE 分支内的)
    // RXP_DIAG 接线会**直接编译报错**, 而不是静默接成悬空输入去喂 lc 多路器。
    , input  wire [31:0] ds_idx, ds_b1, ds_b2, ds_bg, ds_dup
    , input  wire [7:0]  ds_got, ds_exp, ds_prev
    // v2 追加 (同样追加在最后, 理由同上): 首失配整字 (收/期望) + 帧内偏移桶
    , input  wire [63:0] ds_gw, ds_ew
    , input  wire [31:0] ds_oz, ds_ol, ds_om, ds_oh
    // ---- RXP_DIAG v3 (2026-09-26): 帧边界记账 (udp_split 的帧首/首失配/回卷快照) ----
    // 位宽按 udp_split.UDP_AW=9 (10 位指针/占用) 硬写 —— 诊断构建的固定配置;
    // 语义/判读见下面 TPL 段的 v3 注释。
    , input  wire [63:0] v3_sw
    , input  wire [8:0]  v3_sf
    , input  wire        v3_sm
    , input  wire [7:0]  v3_wd
    , input  wire [9:0]  v3_fr, v3_fw, v3_fo, v3_fh
    , input  wire [1:0]  v3_fs
    , input  wire [15:0] v3_fn
    , input  wire [9:0]  v3_pr, v3_pw, v3_ph
    , input  wire [9:0]  v3_lr, v3_lw, v3_lo, v3_lh
    , input  wire [15:0] v3_rc, v3_vc
    , input  wire [9:0]  v3_vx, v3_vs, v3_vr
    , input  wire [15:0] v3_vn
    // ---- RXP_DIAG v4 (2026-09-27): 异常帧路径计数器 + 受损帧运行结构/事件 FIFO ----
    // 来源: udp_split (CN/RD/NC/NP/WF/RL/WC) 与 app_udp_pattern (NE/NR/MR/EN/EO/QA..QH)。
    // ⚠️⚠️ **未接 = 假 0** (读板前必读): 本段端口若在某构建的顶层 (wrapper) 没有
    //   连接, 综合会把未连接输入**钳成常数 0** ⇒ 状态行上这些字段**全 0** ——
    //   那不是"该路径从未触发", 而是"这个仪器根本没接进去"。判读前必须先确认
    //   该构建的顶层把这些口接上了 (RXP_DIAG + APP_MODE 两个宏都有、且 wrapper 的
    //   例化点带这些名字)。2026-09-27 的 v4 交付: board/ 被要求不动, 故
    //   `board/wrapper_p4.v` 的 RXP_DIAG 段**没有**这些连线 ⇒ 用现成 wrapper 构建
    //   出来的位流读到的是假 0 (xelab 会报 `port 'v4_cn' remains unconnected`)。
    // 键名一律取 "=" 前**最后两个字母** (tools/board_p5b_check.py 的 parse 口径) ⇒
    // 新增键必须与既有键全不撞 (既有 = ST NX UA RW RN RX TX TF MM OC EV DP RY EC
    // DL FI RS AK AD TS WQ WM WU PO PX RB RF OV PC PA TB II GG EE PP BA BB BC DD
    // GW EW OZ OL OM OH SW SF SM FR FW FO FH FS FN PR PW PH LR LW LO LH RC VC VX VS
    // VR VN)。⚠️ 事件条目**不能用 E 打头**: EC 与 EE 已被占用 (EC=estab_cnt 在偏移
    // 130) —— 撞键会让板级读取器的 "last match wins" 把既有字段读成新值。故取
    // QA..QH (Q 前缀全空)。gen_offsets.py 有正则级遮蔽检查 (v4 的 20 个新键必须
    // 20/20 在行内唯一命中, 且不得给任何既有键添第二次命中)。
    , input  wire [15:0] v4_cn, v4_rd, v4_nc, v4_np, v4_wf, v4_rl, v4_wc
    , input  wire [15:0] v4_ne, v4_nr, v4_mr
    , input  wire [3:0]  v4_en
    , input  wire        v4_eo
    , input  wire [23:0] v4_qa, v4_qb, v4_qc, v4_qd
    , input  wire [23:0] v4_qe, v4_qf, v4_qg, v4_qh
    // ---- RXP_DIAG v5 (2026-09-27): 写数据口 (din) 上的第二个 LFSR 校验器 + 解析器计数 ----
    // 来源: udp_split (v5_dv_* = 写侧纯计数 LFSR 校验器; v5_up_* = udp_rx 的解析器计数)。
    // ⚠️ 同 v4 的"未接 = 假 0"铁律: 端口没接 ⇒ 综合钳 0 ⇒ 读数全 0 与"从未触发"
    //   不可区分。v5 的接线已落在 board/wrapper_p4.v 的 `ifdef RXP_DIAG 段内, 且由
    //   真 wrapper 全链门 (tb/tb_p5e_udp_wrapper.v 相 8) 做**正的存在性证明**。
    // 键名 (A 部) DV DG DE DO DM VZ 与 (B 部) PS NM IC DC SB —— 与既有全部键不撞
    //   (特别注意: RB RF OV PC PA TB TF MM 是既有 3 字母键 URB/URF/UOV/UPC/UPA/
    //   UTB/UTF/UMM 的**尾部**, 已被板级读取器占用 ⇒ 必须避开; gen_offsets.py 的
    //   正则遮蔽检查是硬断言)。
    // 口径/判据见 rtl/udp_split.v 的 v5 段注释 (真值源在那里)。
    , input  wire [31:0] v5_dv_idx  // DV: 首个失配处的累计字节序号 (纯计数锚)
    , input  wire [7:0]  v5_dv_got  // DG: 该处收到的字节
    , input  wire [7:0]  v5_dv_exp  // DE: 该处期望的字节 (LFSR)
    , input  wire [15:0] v5_dv_off  // DO: 该失配在本帧内的字节偏移
    , input  wire [31:0] v5_dv_mm   // DM: 失配字节总数 (整轮累计)
    , input  wire        v5_dv_v    // VZ: 快照有效 (粘滞)
    , input  wire [31:0] v5_up_pass // PS: udp_rx.stat_pass (匹配且 FCS 好)
    , input  wire [31:0] v5_up_nm   // NM: udp_rx.stat_drop_nonmatch
    , input  wire [31:0] v5_up_ipc  // IC: udp_rx.stat_drop_ipcsum
    , input  wire [31:0] v5_up_crc  // DC: udp_rx.stat_drop_crc
    , input  wire [31:0] v5_up_bytes// SB: udp_rx.stat_bytes (匹配帧的载荷字节数)
    // ---- RXP_DIAG v6 (2026-09-27): u_pre **输入侧** (s_axis) 的第三个 LFSR 校验器 ----
    // 来源: udp_split (v6_dv_*), 位置 = udp_split 的输入端口侧 (进 u_pre 之前)。
    //   目的 (ISSUE_RX_BYTE_CORRUPTION §18.9/§18.10): 裁决那个"三者不能同时为真"的
    //   矛盾 —— u_pre 的输入是整条链上唯一还没插桩的流。
    // ⚠️ 同 v4/v5 的"未接 = 假 0"铁律: 端口没接 ⇒ 综合钳 0 ⇒ 读数全 0 与"从未触发"
    //   不可区分。v6 的接线已落在 board/wrapper_p4.v 的 `ifdef RXP_DIAG 段内, 且由
    //   真 wrapper 全链门 (tb/tb_p5e_udp_wrapper.v 相 9) 做**正的存在性证明**。
    // 键名 CV CG CE CO CM CZ CS —— 与既有全部键不撞 (特别注意 CZ 与既有键的
    //   **尾部** 不冲突: OZ 是独立键; gen_offsets.py 的正则遮蔽检查是硬断言)。
    // 口径/判据见 rtl/udp_split.v 的 v6 段注释 (真值源在那里)。
    , input  wire [31:0] v6_dv_idx  // CV: 首个失配处的累计**载荷**字节序号 (纯计数锚)
    , input  wire [7:0]  v6_dv_got  // CG: 该处收到的字节
    , input  wire [7:0]  v6_dv_exp  // CE: 该处期望的字节 (LFSR)
    , input  wire [15:0] v6_dv_off  // CO: 该失配的**帧内**字节偏移 (= 帧内序号 - 42)
    , input  wire [31:0] v6_dv_mm   // CM: 失配字节总数 (整轮累计)
    , input  wire        v6_dv_v    // CZ: 快照有效 (粘滞, 只记首个)
    , input  wire [7:0]  v6_dv_sk   // CS: 输入 skid 满而丢掉的**字数** (0 = 本轮读数可用)
`endif
`endif
);
`ifdef RXP_DIAG
`ifdef APP_MODE
    // v2: 382 -> 470 (追加 GW(16) EW(16) OZ/OL/OM/OH(各 8) = +88 字符)。
    // v3: 470 -> **637** (追加 22 字段 = +167 字符; 见下 TPL 的 v3 段)。
    // ⚠️ 637 > 512 ⇒ ci 必须从 9 位加宽到 **10 位** (10 位字面量; LINE_LEN
    //   <= 1023 是 TPL 位选表达式的硬界, gen_offsets.py 有断言)。
    //   偏移**全部由 sim/rxpdiag/gen_offsets.py 拼接 TPL 串算出** (该脚本先
    //   复现发布的 v2 偏移 GW 384 / EW 404 / OZ 424 / OL 436 / OM 448 / OH 460 /
    //   CR 468 / LF 469 / LINE_LEN 470 才继续, 手数一律不算数)。
    // v4: 637 -> **807** (再追加 20 个键 = +170 字符; 见下 TPL 的 v4 段)。
    //   807 <= 1023 ⇒ ci 仍是 10 位 (10 位字面量的硬界由 gen_offsets.py 断言)。
    // v5: 807 -> **916** (再追加 11 个键 = +109 字符; 见下 TPL 的 v5 段)。
    //   916 <= 1023 ⇒ ci 仍是 10 位。偏移全部由 sim/rxpdiag/gen_offsets.py 拼接
    //   TPL 串算出 (该脚本先复现 v2/v3/v4 三组发布偏移才继续, 手数一律不算数)。
    // v6: 916 -> **971** (再追加 7 个键 = +55 字符; 见下 TPL 的 v6 段)。
    //   971 <= 1023 ⇒ ci 仍是 10 位。偏移由 gen_offsets.py 拼接 TPL 串算出
    //   (该脚本先复现 v2/v3/v4/v5 四组发布偏移与 RTL 解码窗口才继续)。
    localparam LINE_LEN = 10'd971;
`else
    localparam LINE_LEN = 9'd304;
`endif
`else
    localparam LINE_LEN = 9'd304;
`endif

    // 行模板 (固定文本; hex 位以 'x' 占位, 运行时由 lchar 覆盖)
    // 字节 i = TPL[8*(LINE_LEN-1) - 8*i +: 8] (首字符在最高字节)
    // W5: 追加 DL (超长帧丢弃) / FI (FIN 已发) / RS (RST 已发) 三段 —
    // 板级看不到 FIN 是否发出、坏帧是否被丢。
    // P5b C9: 行尾再追加 AK/AD/TS/WQ/WM/WU/PO/PX (前 156 字符逐字节不变) —
    // 板级病理 (对端停等/窗口不重开/池耗尽) 缺可观测量。
    // P5f: 行尾再追加 UDP app 段 URB/UMM/URF/UOV/UPC/UPA/UTB/UTF
    // (偏移: URB hex 223..230, UMM 236..243, URF 249..252, UOV 258..261,
    //  UPC 267..270, UPA 276..279, UTB 285..292, UTF 298..301; CR=302 LF=303)。
    // RXP_DIAG: 行尾再追加 8 字段 (ISSUE_RX_BYTE_CORRUPTION 专题首失配快照)。
    //   键名一律取"="前最后两个字母 (tools/board_p5b_check.py 的 parse 口径),
    //   故新增键必须与既有键不撞: 既有 = ST NX UA RW RN RX TX TF MM OC EV DP RY
    //   EC DL FI RS AK AD TS WQ WM WU PO PX RB RF OV PC PA TB。
    //   II=失配字节的全局序号 (= 图案流偏移)   GG=收到的坏字节  EE=期望字节
    //   PP=前一拍期望字节 (= 上一比对过的字节, 因其已匹配)
    //   BA/BB/BC = 失配字节数, popcount(got^exp) 为 1 / 2 / >=3
    //   DD=失配且 got==前一字节 的次数 (重复/陈旧签名)
    //   **不做帧内偏移/帧号字段**: 帧长恒 1472 ⇒ 离线由 II 精确导出, 而硬件侧的
    //   活计数器会因 1 字前瞻流水滞后 (仪器自检门实测 7 字节) ⇒ 会误导。
    //   偏移: II 306..313, GG 318..319, EE 324..325, PP 330..331, BA 336..343,
    //         BB 348..355, BC 360..367, DD 372..379; CR=380 LF=381。
    //         前 302 字符与 P5f 逐字节相同。
    // RXP_DIAG **v2** (2026-09-26): 行尾再追加 6 字段 —— 首失配**整字**指纹
    //   与帧内偏移桶计数。键名 GW EW OZ OL OM OH (与上面全部既有键均不撞;
    //   解析器口径 "="前最后两个字母 不变)。
    //   GW/EW = 首失配所在 64 位**收字 / 期望字**, 按**同一个字边界**逐 lane 对齐
    //           (lane0 = 该字的第 1 字节, 即 tdata[63:56]); **失配可以发生在字中**,
    //           故 EW 不是"从 II 起的 8 个期望字节" (那会与 GW 错位 —— 见
    //           rtl/app_udp_pattern.v 的 ds_gw/ds_ew 注释)。
    //           自洽性: GW^EW 的最低位非零 lane 就是首失配 lane, 且该 lane 的
    //           GW/EW 字节 == GG/EE。
    //   OZ/OL/OM/OH = **整轮聚合**计数: 失配字节的帧内偏移 (mod i_paylen) 落在
    //           0 / 1..7 / 8..63 / >=64 的次数 ⇒ 行内恒等式 OZ+OL+OM+OH == UMM
    //           (与 BA+BB+BC == UMM 同族; 前者划分"位置", 后者划分"形状")。
    //   偏移 (按模板串拼接程序化定位, 非手数):
    //     GW 384..399, EW 404..419, OZ 424..431, OL 436..443,
    //     OM 448..455, OH 460..467; CR=468 LF=469 ⇒ 行 = 470 字符。
    //     前 382 字符与 v1 的 RXP_DIAG 行逐字节相同 (既有字段偏移一律不动)。
    // RXP_DIAG **v3** (2026-09-26): 行尾再追加 22 字段 (470 → **637** 字符; 前 468
    //   字符与 v2 逐字节相同)。全部来自 udp_split 的帧边界快照 (见 rtl/udp_split.v
    //   的 v3 段), 唯一目的是回答 "坏帧开始时, 哪一个记账值是错的"。
    //   键名 (取"="前最后两字母, 与既有键**全部不撞**; 由 gen_offsets.py 做正则级
    //   遮蔽检查: 22/22 唯一命中):
    //   · 写侧指纹 (协调方要求): 播放器**正在播的那一帧**的第一个数据字, 在 u_uf
    //     写口出现时的原值 —— 与 GW 同类 (64 位整字), 可直接比:
    //       SW == GW ⇒ 坏数据**写进缓冲时就已经是坏的** ⇒ 上游 (mac_rx_64/udp_rx/
    //                  FCS 盲区), 与帧缓冲指针无关;
    //       SW == EW ⇒ 写侧是对的 ⇒ 坏在帧缓冲/读侧 ⇒ 指针记录与回卷记录才有意义;
    //       都不是   ⇒ 第三个值 (既不等于收字也不等于期望字), 如实记录不强行归类。
    //     SW 64 位 (16 hex) / SF 该字写入的**槽址** (9 位, 与 FR 低 9 位对账;
    //     不等 ⇒ 读写两端的帧边界不在同一个槽) / SM 1=命中 (WD<8 才有效) /
    //     WD 帧首拍"写侧提交序号 - 播放帧序号" (正常 1..4; >=8 表项已过期, 读数作废)。
    //   · 帧首记录 (current): 在**播放器收下本帧第一拍**那一拍锁存 ——
    //     FR/FW/FO/FH = uf_rptr/uf_wptr/uf_occ/hold_rem_u, FS = rstate (1=R_PLAY,
    //     2=R_NULL), FN = 帧序号 (0 起, 与 II/paylen 对账)。
    //     判读: FO=FW-FR 占用 (被写侧覆写 ⇒ 异常小或与帧长不符); FR-PR 必须恰 =
    //     上一帧的字数 (0 或 2x ⇒ 读者跳过/重读了一帧); FH 是在收帧字数 (写侧当拍
    //     进度, 不是"应该为 0" —— 播放器落后写侧整整一帧以上)。
    //   · 上一帧帧首记录: PR/PW/PH (同上三量)。FR-PR 是"读者一帧走了多少字"。
    //   · 首失配当拍活值: LR/LW/LO/LH = 那一拍的 uf_rptr/uf_wptr/uf_occ/hold_rem_u。
    //     ⚠️ app 的 RX 引擎 1 字前瞻 ⇒ LR 相对 FR 领先**失配字所在位置 +1 字**,
    //     不是"失配字号"; 且若失配落在帧末字, ds_cap 可能已跨到下一帧的帧首
    //     (那时 FN 比 II/paylen 大 1 ⇒ 离线一眼可辨)。
    //   · 回卷一致性: RC = 回卷次数, VC = **违例**次数 (回卷丢弃字数 != 在收帧字数),
    //     以及首违例当拍 VX=(wptr-wsnap)-hold_rem (超出在收帧的额外字数; 恰 184
    //     ⇒ 吃掉整整一帧已提交数据)、VS=wsnap、VR=uf_rptr (VR 落在被吃区间 ⇒
    //     读者刚好要读它 ⇒ 读到更晚那帧的内容, 字数不变 —— 与板级签名同形)、
    //     VN=写侧提交序号 (与 II/paylen 对账)。VC==0 才是"回卷没吃已提交数据"。
    //   偏移 (gen_offsets.py 输出; CR=635 LF=636):
    //     SW 472..487, SF 492..494, SM 499, FR 504..506, FW 511..513, FO 518..520,
    //     FH 525..527, FS 532, FN 537..540, PR 545..547, PW 552..554, PH 559..561,
    //     LR 566..568, LW 573..575, LO 580..582, LH 587..589, RC 594..597,
    //     VC 602..605, VX 610..612, VS 617..619, VR 624..626, VN 631..634。
    // RXP_DIAG **v4** (2026-09-27): 行尾再追加 20 个键 (637 -> **807**
    //   字符; 前 637 字符与 v3 逐字节相同)。两个来源, 目的是把 §16.7 留下的两个
    //   空白填上: "哪些异常帧路径在触发" 与 "受损帧是孤立还是成段"。
    //   【A 部: udp_split 的异常帧路径计数器】(口径见 rtl/udp_split.v 的 v4 段;
    //     全部是**本轮累计**, 每轮重新烧录=复位即清零):
    //     CN = 描述符 FIFO 满 ⇒ 本帧回卷的次数 (载荷已写、帧没提交)
    //     RD = 残帧边界回卷次数 (长度不符/截断 ⇒ 缺 TLAST, 由下一帧边界回卷)
    //     NC = 0 长数据报**事件**次数 (fend 拍且 meta_len==0)
    //     NP = 0 长数据报**提交**次数 (NC 里 FCS 好的那一部分)
    //     WF = uf_ovf 的**拍数** —— 即因缓冲满被吞掉的**载荷字数**(不是帧数:
    //          缓冲满期间每个载荷字都算一拍, 一帧可贡献多个)
    //     RL = 回卷次数 (= v3 的 RC 同源; 与 CN/RD 对账: RL 是总包络)
    //     WC = **字数一致性违例**次数: 提交拍 (hold_rem_u 更新前值 + 1) !=
    //          (u_meta_len+7)>>3 ⇒ 该帧写的字数与它声明的长度对不上
    //          (载荷流与帧归属不一致的直接签名; 干净构建必须恒 0)
    //   【B 部: app_udp_pattern 的受损帧运行结构 + 事件 FIFO】
    //     事件 = "首失配落在帧内偏移 0" 的那一拍 (= v2 的 OZ 桶同一门 ⇒ NE==OZ)。
    //     NE = 事件总数;  NR = **极大连续段数** (相邻帧号差 1 视为同段);
    //     MR = 最长连续段长度。判据: NR == NE ⇒ 受损帧全孤立; NR < NE ⇒ 存在连续段
    //     (连续段 = 帧边界整体位移的签名)。
    //     EN = 已入队条目数 (0..8);  EO = 1 ⇒ FIFO 曾满, **后续事件未记录**(粘滞)
    //     QA..QH = 条目 0..7, 每条 24 位 = {帧号[15:0], 该事件处的 rx_got[7:0]}
    //       (16 位帧号在上、8 位收到字节在下; 未使用的条目恒 0)。
    //       离线用途: (a) 位移符号从"每轮 1 个样本"扩到最多 8 个 (拿 got 字节去比
    //       pattern[帧首 ± paylen]); (b) 帧号的模结构 (若聚在某个 mod 值 ⇒ 指向
    //       环形缓冲/定址类根因)。
    //   偏移 (gen_offsets.py 拼接 TPL 串算出; CR=805 LF=806):
    //     CN 639..642, RD 647..650, NC 655..658, NP 663..666, WF 671..674,
    //     RL 679..682, WC 687..690, NE 695..698, NR 703..706, MR 711..714,
    //     EN 719, EO 724, QA 729..734, QB 739..744, QC 749..754, QD 759..764,
    //     QE 769..774, QF 779..784, QG 789..794, QH 799..804。
    //     ⚠️ 上表是**脚本输出 + 实跑行逐字符核对**的结果 (见 tb_rxp_diag 相 7);
    //        实现时任何一位改动都必须重跑 gen_offsets.py 与格式门。
    //   【v5 段】把**写数据口 (din) 上的第二个 LFSR 校验器**与**解析器计数**显示出来。
    //     A 部 (udp_split.v 的 v5 段): 不按帧号定址, 只按字节计数推进 ⇒ 与 v3 的 SW
    //       (按 `w_commit_cnt[2:0]` 帧号定址) 是**两个机制不同**的探针; 判据:
    //       DV == app 的 II 且 DM == app 的 UMM (两个锚互相独立)。
    //     B 部 (udp_rx 的 stat_* —— 在 udp_split 内部一直悬空未用, 这里零逻辑引出):
    //       PS (stat_pass) vs app 的 URF(交付帧数): 不等 ⇒ 解析器与 app 之间有丢帧/重帧。
    //   偏移 (gen_offsets.py 拼接 TPL 串算出; CR=914 LF=915):
    //     DV 809..816, DG 821..822, DE 827..828, DO 833..836, DM 841..848, VZ 853,
    //     PS 858..865, NM 870..877, IC 882..889, DC 894..901, SB 906..913。
    //   【v6 段】把 **u_pre 输入侧 (udp_split 的 s_axis, 进 u_pre 之前)** 的第三个
    //     LFSR 校验器显示出来 (ISSUE_RX_BYTE_CORRUPTION §18.9/§18.10):
    //     CV = 首个失配处的**累计载荷字节序号** · CG/CE = 该处 收/期望 字节
    //     CO = 该失配的**帧内**字节偏移 (= 帧内序号 - 42) · CM = 失配字节总数
    //     CZ = 快照有效 (粘滞, 只记首个) · CS = **输入 skid 满而丢的字数**
    //          (非 0 ⇒ 本轮 v6 读数不可用; 板级 1G = 1 字/8 拍, 引擎 = 1 字/2 拍
    //           ⇒ 余量 4 倍, 正常轮次 CS 恒 0)
    //   偏移 (gen_offsets.py 拼接 TPL 串算出; CR=969 LF=970):
    //     CV 918..925, CG 930..931, CE 936..937, CO 942..945, CM 950..957,
    //     CZ 962, CS 967..968。
    //     ⚠️ 上表是**脚本输出 + 实跑行逐字符核对**的结果 (见 tb_rxp_diag 相 7 的 v6
    //        断言); 实现时任何一位改动都必须重跑 gen_offsets.py 与格式门。
`ifdef RXP_DIAG
`ifdef APP_MODE
    wire [8*LINE_LEN-1:0] TPL = {
        "P5B1 ST=x NX=xxxxxxxx UA=xxxxxxxx RW=xxxx RN=xxxxxxxx ",
        "RX=xxxxxxxx TX=xxxxxxxx TF=xxxx MM=xxxx OC=xxxxx EV=xxxx ",
        "DP=xxxx RY=xxxx EC=xx DL=xxxx FI=xxxx RS=xxxx",
        " AK=xxxx AD=xxxx TS=x WQ=xxxx WM=xxxx WU=xxxx PO=xxxxx PX=xxxx",
        " URB=xxxxxxxx UMM=xxxxxxxx URF=xxxx UOV=xxxx UPC=xxxx UPA=xxxx",
        " UTB=xxxxxxxx UTF=xxxx",
        " II=xxxxxxxx GG=xx EE=xx PP=xx BA=xxxxxxxx BB=xxxxxxxx BC=xxxxxxxx DD=xxxxxxxx",
        " GW=xxxxxxxxxxxxxxxx EW=xxxxxxxxxxxxxxxx",
        " OZ=xxxxxxxx OL=xxxxxxxx OM=xxxxxxxx OH=xxxxxxxx",
        " SW=xxxxxxxxxxxxxxxx SF=xxx SM=x",
        " FR=xxx FW=xxx FO=xxx FH=xxx FS=x FN=xxxx",
        " PR=xxx PW=xxx PH=xxx",
        " LR=xxx LW=xxx LO=xxx LH=xxx",
        " RC=xxxx VC=xxxx",
        " VX=xxx VS=xxx VR=xxx VN=xxxx",
        " CN=xxxx RD=xxxx NC=xxxx NP=xxxx WF=xxxx RL=xxxx WC=xxxx",
        " NE=xxxx NR=xxxx MR=xxxx EN=x EO=x",
        " QA=xxxxxx QB=xxxxxx QC=xxxxxx QD=xxxxxx",
        " QE=xxxxxx QF=xxxxxx QG=xxxxxx QH=xxxxxx",
        " DV=xxxxxxxx DG=xx DE=xx DO=xxxx DM=xxxxxxxx VZ=x",
        " PS=xxxxxxxx NM=xxxxxxxx IC=xxxxxxxx DC=xxxxxxxx SB=xxxxxxxx",
        " CV=xxxxxxxx CG=xx CE=xx CO=xxxx CM=xxxxxxxx CZ=x CS=xx",
        8'h0D, 8'h0A
    };
`else
    wire [8*LINE_LEN-1:0] TPL = {
        "P5B1 ST=x NX=xxxxxxxx UA=xxxxxxxx RW=xxxx RN=xxxxxxxx ",
        "RX=xxxxxxxx TX=xxxxxxxx TF=xxxx MM=xxxx OC=xxxxx EV=xxxx ",
        "DP=xxxx RY=xxxx EC=xx DL=xxxx FI=xxxx RS=xxxx",
        " AK=xxxx AD=xxxx TS=x WQ=xxxx WM=xxxx WU=xxxx PO=xxxxx PX=xxxx",
        " URB=xxxxxxxx UMM=xxxxxxxx URF=xxxx UOV=xxxx UPC=xxxx UPA=xxxx",
        " UTB=xxxxxxxx UTF=xxxx",
        8'h0D, 8'h0A
    };
`endif
`else
    wire [8*LINE_LEN-1:0] TPL = {
        "P5B1 ST=x NX=xxxxxxxx UA=xxxxxxxx RW=xxxx RN=xxxxxxxx ",
        "RX=xxxxxxxx TX=xxxxxxxx TF=xxxx MM=xxxx OC=xxxxx EV=xxxx ",
        "DP=xxxx RY=xxxx EC=xx DL=xxxx FI=xxxx RS=xxxx",
        " AK=xxxx AD=xxxx TS=x WQ=xxxx WM=xxxx WU=xxxx PO=xxxxx PX=xxxx",
        " URB=xxxxxxxx UMM=xxxxxxxx URF=xxxx UOV=xxxx UPC=xxxx UPA=xxxx",
        " UTB=xxxxxxxx UTF=xxxx",
        8'h0D, 8'h0A
    };
`endif

    function [7:0] hexc;                 // 4 位 -> ASCII
        input [3:0] n;
        begin
            hexc = (n < 4'd10) ? (8'h30 + {4'b0, n}) :
                                 (8'h41 + {4'b0, n} - 8'd10);
        end
    endfunction

    function [7:0] hexd;                 // 32 位值的第 k 个 nibble (k: 0 = MSB)
        input [31:0] v;
        input [2:0]  k;
        begin
            case (k)
                3'd0: hexd = hexc(v[31:28]);
                3'd1: hexd = hexc(v[27:24]);
                3'd2: hexd = hexc(v[23:20]);
                3'd3: hexd = hexc(v[19:16]);
                3'd4: hexd = hexc(v[15:12]);
                3'd5: hexd = hexc(v[11:8]);
                3'd6: hexd = hexc(v[7:4]);
                default: hexd = hexc(v[3:0]);
            endcase
        end
    endfunction

`ifdef RXP_DIAG
`ifdef APP_MODE
    // 64 位值的第 k 个 nibble (k: 0 = MSB) —— v2 的 GW/EW 字段用 (hexd 只有 32 位)
    function [7:0] hexq;
        input [63:0] v;
        input [3:0]  k;
        begin
            case (k)
                4'd0:  hexq = hexc(v[63:60]);
                4'd1:  hexq = hexc(v[59:56]);
                4'd2:  hexq = hexc(v[55:52]);
                4'd3:  hexq = hexc(v[51:48]);
                4'd4:  hexq = hexc(v[47:44]);
                4'd5:  hexq = hexc(v[43:40]);
                4'd6:  hexq = hexc(v[39:36]);
                4'd7:  hexq = hexc(v[35:32]);
                4'd8:  hexq = hexc(v[31:28]);
                4'd9:  hexq = hexc(v[27:24]);
                4'd10: hexq = hexc(v[23:20]);
                4'd11: hexq = hexc(v[19:16]);
                4'd12: hexq = hexc(v[15:12]);
                4'd13: hexq = hexc(v[11:8]);
                4'd14: hexq = hexc(v[7:4]);
                default: hexq = hexc(v[3:0]);
            endcase
        end
    endfunction
`endif
`endif

    // 快照锁存 (行首)
    reg [3:0]  sn_st;
    reg [31:0] sn_nx, sn_ua, sn_rn, sn_rx, sn_tx;
    reg [15:0] sn_rw, sn_tf, sn_mm, sn_ev, sn_dp, sn_ry, sn_ec;
    reg [15:0] sn_dl, sn_fi, sn_rs;
    reg [16:0] sn_oc;
    // P5b C9 追加字段
    reg [15:0] sn_ak, sn_ad, sn_wq, sn_wm, sn_wu, sn_px;
    reg [2:0]  sn_ts;
    reg [16:0] sn_po;
    // P5f 追加字段
    reg [31:0] sn_urb, sn_umm, sn_utb;
    reg [15:0] sn_urf, sn_uov, sn_upc, sn_upa, sn_utf;
`ifdef RXP_DIAG
`ifdef APP_MODE
    // RXP_DIAG 追加字段 (首失配快照)
    reg [31:0] sn_ii, sn_ba, sn_bb, sn_bc, sn_dd;
    reg [7:0]  sn_gg, sn_ee, sn_pp;
    // RXP_DIAG v2 追加字段 (整字指纹 + 帧内偏移桶)
    reg [63:0] sn_gw, sn_ew;
    reg [31:0] sn_oz, sn_ol, sn_om, sn_oh;
    // RXP_DIAG v3 追加字段 (帧边界记账; 键名/语义见上面 TPL 段的 v3 注释)
    reg [63:0] sn_sw;
    reg [8:0]  sn_sf;
    reg        sn_sm;
    reg [7:0]  sn_wd;
    reg [9:0]  sn_fr, sn_fw, sn_fo, sn_fh;
    reg [1:0]  sn_fs;
    reg [15:0] sn_fn;
    reg [9:0]  sn_pr, sn_pw, sn_ph;
    reg [9:0]  sn_lr, sn_lw, sn_lo, sn_lh;
    reg [15:0] sn_rc, sn_vc;
    reg [9:0]  sn_vx, sn_vs, sn_vr;
    reg [15:0] sn_vn;
    // RXP_DIAG v4 追加字段 (异常帧路径计数器 + 运行结构/事件 FIFO; 见 TPL 段注释)
    reg [15:0] sn_cn, sn_rd, sn_nc, sn_np, sn_wf, sn_rl, sn_wc;
    reg [15:0] sn_ne, sn_nr, sn_mr;
    reg [3:0]  sn_en;
    reg        sn_eo;
    reg [23:0] sn_qa, sn_qb, sn_qc, sn_qd, sn_qe, sn_qf, sn_qg, sn_qh;
    // RXP_DIAG v5 追加字段 (写侧 LFSR 校验器 + 解析器计数; 见 TPL 段的 v5 注释)
    reg [31:0] sn_dv, sn_dm;
    reg [7:0]  sn_dg, sn_de;
    reg [15:0] sn_do;
    reg        sn_vz;
    reg [31:0] sn_ps, sn_nm, sn_ic, sn_dc, sn_sb;
    // RXP_DIAG v6 追加字段 (u_pre 输入侧 LFSR 校验器; 见 TPL 段的 v6 注释)
    reg [31:0] sn_cv, sn_cm;
    reg [7:0]  sn_cg, sn_ce, sn_cs;
    reg [15:0] sn_co;
    reg        sn_cz;
`endif
`endif

    reg [9:0]  ci;                       // 行内字符索引 (10 位: 最长行 637 = RXP_DIAG v3;
                                         // v2 时是 9 位/470 —— 470 > 512 边界由
                                         // gen_offsets.py 的 LINE_LEN<=1023 断言守住)
    reg [27:0] gap;
    reg        sending;

    // 当前字符: 固定模板 (寄存) + hex 字段覆盖 (组合)
    //-------------------------------------------------------------------------
    // ⚠️ 时序 (2026-09-27, v4 构建 WNS -0.435 / 9 条失败端点全部是
    //    `u_app_status/ci_reg[*]_replica_/C → u_app_status/u_uart/fr_reg[*]/D`):
    //    原来 `fixed_c` 是 **6456 位模板字面量的字节选择** (10 位索引 ⇒ ~10 级 2:1
    //    字节 mux), 它**直接**挂在最长组合链的头部:
    //        ci → TPL 字节选择 (~10 级) → 60 深 if/else-if 优先级链 → lc → fr/D
    //    ⇒ 一条链 ≈ 17+ 级, 8ns 周期下 -0.435ns。
    //-------------------------------------------------------------------------
    // 【为什么"寄存一级"是**零代价**的】`ci` 只在**字节被 UART 收下**时 +1
    //   (`if (uart_go) ... ci <= ci + 1`), 而一个字节 = BIT_LAST+1 ≈ 13021 拍;
    //   UART 也只在 `tx_go` 那一拍采 `byte_in` (board/uart_dbg.v:172:
    //   `else if (tx_go) fr <= {1'b1, byte_in, 1'b0};`)。所以在两次采样之间有
    //   1.3e4 拍的余量 ⇒ 把"模板字节"寄存一拍, **发出的字节一个都不变**。
    //   (复位后的**第一个**字节由下面的复位值直接给出 = TPL 的第 0 个字符 =
    //    组合版在 ci==0 时的输出, 逐位相同。)
    //   于是最长路径被切成两条互不相关的短路径:
    //        ① ci → TPL 选择 → fix_r/D            (~10 级 → 只是它自己)
    //        ② ci → 字段比较/hexd/hexc → lc → fr/D (60 深链, 不再背模板 mux)
    //   ⇒ 终点仍在 `fr/D` 的那条链短了约 10 级。
    // ⚠️ 不动握手: `tx_go` / `busy` / `ci` 的推进一个都没改 (延迟 tx_go 会丢字节)。
    wire [7:0] fixed_c = TPL[ (8*(LINE_LEN-1) - 8*ci) +: 8 ];
    reg  [7:0] fix_r;
    //-------------------------------------------------------------------------
    // ci -> lc 的**两级切分** (2026-09-27 时序修复; v4 构建 WNS -0.435, 9 条失败
    //   端点全部是 `u_app_status/ci_reg[*]_replica_/C -> u_app_status/u_uart/fr_reg[*]/D`):
    //   原结构是一条组合链 ci/快照 -> ~89 深 if/else-if 优先级链 (内含 hexd/hexc 的
    //   32 位 nibble mux 与 `ci - A` 减法) -> lc -> fr/D。私有 route_check 实测该链
    //   **33 级逻辑 / 9.485ns (其中布线 7.418ns, LUT6=27)** —— 深 + 高扇出 (ci 10 位 x
    //   ~180 个比较器、且全部快照寄存器都要汇进同一条 mux 树) 一起把布线拖垮。
    //   切法 (表达式一字不改, 只把每个分支的结果寄存):
    //     stage 1 (posedge): sel_r[i] <= 命中; ch_r[i] <= 命中 ? 该分支的值 : 0
    //     stage 2 (组合):    lc = |sel_r ? (ch_r 全 OR) : fix_r
    //   为什么逐字节不变:
    //     ① 分支条件互斥 (单点或 [A,B) 区间) ⇒ 至多一个 ch_r[i] 非 0 ⇒ OR 恰等于
    //        原来的优先级 mux 结果;
    //     ② `ci` 只在字节被收下时 +1 (BIT_LAST+1 ≈ 13021 拍), UART 只在 `tx_go` 那拍
    //        采 byte_in ⇒ 多一级寄存对**发出的字节**零影响; 行间 gap 里 ci 恒 0 ⇒
    //        开行前 ch_r/sel_r 已稳定在 ci=0 的结果上, 首字节无需特例;
    //     ③ 某 ifdef 配置里不存在的分支**没有驱动** ⇒ 停在复位值 0, 不影响 OR。
    //   代价: 条件算两遍 (比较器翻倍) + 89 x 8 位结果寄存器; 换来两条浅路径
    //        (stage1 ≈ 比较/减法 + hexd ≈ 7 级, stage2 ≈ OR + 一级 mux ≈ 4 级)。
    //-------------------------------------------------------------------------
    // v5: 89 -> **100** 条分支 (追加 11 个 v5 字段; 分支条件仍两两互斥 ⇒ stage-2 的
    //   按位 OR 仍旧恰等于原来的优先级 mux, 见上面"为什么逐字节不变"的论证)。
    // v6: 100 -> **107** 条分支 (再追加 7 个 v6 字段; 互斥性不变 —— CZ 是单点
    //   (`ci == 962`), 其余是互不重叠的半开区间)。
    reg  [106:0] sel_r;
    reg  [7:0]  ch_r [0:106];
    integer     chi;
    wire [7:0] lc = (|sel_r) ? (ch_r[0] | ch_r[1] | ch_r[2] | ch_r[3] | ch_r[4] | ch_r[5] | ch_r[6] | ch_r[7] |
                                ch_r[8] | ch_r[9] | ch_r[10] | ch_r[11] | ch_r[12] | ch_r[13] | ch_r[14] | ch_r[15] |
                                ch_r[16] | ch_r[17] | ch_r[18] | ch_r[19] | ch_r[20] | ch_r[21] | ch_r[22] | ch_r[23] |
                                ch_r[24] | ch_r[25] | ch_r[26] | ch_r[27] | ch_r[28] | ch_r[29] | ch_r[30] | ch_r[31] |
                                ch_r[32] | ch_r[33] | ch_r[34] | ch_r[35] | ch_r[36] | ch_r[37] | ch_r[38] | ch_r[39] |
                                ch_r[40] | ch_r[41] | ch_r[42] | ch_r[43] | ch_r[44] | ch_r[45] | ch_r[46] | ch_r[47] |
                                ch_r[48] | ch_r[49] | ch_r[50] | ch_r[51] | ch_r[52] | ch_r[53] | ch_r[54] | ch_r[55] |
                                ch_r[56] | ch_r[57] | ch_r[58] | ch_r[59] | ch_r[60] | ch_r[61] | ch_r[62] | ch_r[63] |
                                ch_r[64] | ch_r[65] | ch_r[66] | ch_r[67] | ch_r[68] | ch_r[69] | ch_r[70] | ch_r[71] |
                                ch_r[72] | ch_r[73] | ch_r[74] | ch_r[75] | ch_r[76] | ch_r[77] | ch_r[78] | ch_r[79] |
                                ch_r[80] | ch_r[81] | ch_r[82] | ch_r[83] | ch_r[84] | ch_r[85] | ch_r[86] | ch_r[87] |
                                ch_r[88] | ch_r[89] | ch_r[90] | ch_r[91] | ch_r[92] | ch_r[93] | ch_r[94] | ch_r[95] |
                                ch_r[96] | ch_r[97] | ch_r[98] | ch_r[99] | ch_r[100] | ch_r[101] | ch_r[102] |
                                ch_r[103] | ch_r[104] | ch_r[105] | ch_r[106]) : fix_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fix_r <= TPL[8*(LINE_LEN-1) +: 8];   // = ci==0 的模板字符
        else        fix_r <= fixed_c;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sel_r <= 107'd0;
            for (chi = 0; chi < 107; chi = chi + 1) ch_r[chi] <= 8'h00;
        end else begin
        sel_r[0] <= (ci == 8'd8);
        ch_r[0]  <= (ci == 8'd8) ? (hexc(sn_st)) : 8'h00;
        sel_r[1] <= (ci >= 8'd13  && ci < 8'd21);
        ch_r[1]  <= (ci >= 8'd13  && ci < 8'd21) ? (hexd(sn_nx, ci - 8'd13)) : 8'h00;
        sel_r[2] <= (ci >= 8'd25  && ci < 8'd33);
        ch_r[2]  <= (ci >= 8'd25  && ci < 8'd33) ? (hexd(sn_ua, ci - 8'd25)) : 8'h00;
        sel_r[3] <= (ci >= 8'd37  && ci < 8'd41);
        ch_r[3]  <= (ci >= 8'd37  && ci < 8'd41) ? (hexd({sn_rw, 16'b0}, ci - 8'd37)) : 8'h00;
        sel_r[4] <= (ci >= 8'd45  && ci < 8'd53);
        ch_r[4]  <= (ci >= 8'd45  && ci < 8'd53) ? (hexd(sn_rn, ci - 8'd45)) : 8'h00;
        sel_r[5] <= (ci >= 8'd57  && ci < 8'd65);
        ch_r[5]  <= (ci >= 8'd57  && ci < 8'd65) ? (hexd(sn_rx, ci - 8'd57)) : 8'h00;
        sel_r[6] <= (ci >= 8'd69  && ci < 8'd77);
        ch_r[6]  <= (ci >= 8'd69  && ci < 8'd77) ? (hexd(sn_tx, ci - 8'd69)) : 8'h00;
        sel_r[7] <= (ci >= 8'd81  && ci < 8'd85);
        ch_r[7]  <= (ci >= 8'd81  && ci < 8'd85) ? (hexd({sn_tf, 16'b0}, ci - 8'd81)) : 8'h00;
        sel_r[8] <= (ci >= 8'd89  && ci < 8'd93);
        ch_r[8]  <= (ci >= 8'd89  && ci < 8'd93) ? (hexd({sn_mm, 16'b0}, ci - 8'd89)) : 8'h00;
        sel_r[9] <= (ci >= 8'd97  && ci < 8'd102);
        ch_r[9]  <= (ci >= 8'd97  && ci < 8'd102) ? (hexd({sn_oc, 12'b0}, ci - 8'd97)) : 8'h00;
        sel_r[10] <= (ci >= 8'd106 && ci < 8'd110);
        ch_r[10]  <= (ci >= 8'd106 && ci < 8'd110) ? (hexd({sn_ev, 16'b0}, ci - 8'd106)) : 8'h00;
        sel_r[11] <= (ci >= 8'd114 && ci < 8'd118);
        ch_r[11]  <= (ci >= 8'd114 && ci < 8'd118) ? (hexd({sn_dp, 16'b0}, ci - 8'd114)) : 8'h00;
        sel_r[12] <= (ci >= 8'd122 && ci < 8'd126);
        ch_r[12]  <= (ci >= 8'd122 && ci < 8'd126) ? (hexd({sn_ry, 16'b0}, ci - 8'd122)) : 8'h00;
        // EC 只显示低 2 位 hex (16 位字段里的 8 位值): 左对齐低字节
        sel_r[13] <= (ci >= 8'd130 && ci < 8'd132);
        ch_r[13]  <= (ci >= 8'd130 && ci < 8'd132) ? (hexd({sn_ec[7:0], 24'b0}, ci - 8'd130)) : 8'h00;
        sel_r[14] <= (ci >= 8'd136 && ci < 8'd140);
        ch_r[14]  <= (ci >= 8'd136 && ci < 8'd140) ? (hexd({sn_dl, 16'b0}, ci - 8'd136)) : 8'h00;
        sel_r[15] <= (ci >= 8'd144 && ci < 8'd148);
        ch_r[15]  <= (ci >= 8'd144 && ci < 8'd148) ? (hexd({sn_fi, 16'b0}, ci - 8'd144)) : 8'h00;
        sel_r[16] <= (ci >= 8'd152 && ci < 8'd156);
        ch_r[16]  <= (ci >= 8'd152 && ci < 8'd156) ? (hexd({sn_rs, 16'b0}, ci - 8'd152)) : 8'h00;
        // ---- P5b C9 追加段 (字段位置见头注释; 前 156 字符不动) ----
        sel_r[17] <= (ci >= 8'd160 && ci < 8'd164);
        ch_r[17]  <= (ci >= 8'd160 && ci < 8'd164) ? (hexd({sn_ak, 16'b0}, ci - 8'd160)) : 8'h00;
        sel_r[18] <= (ci >= 8'd168 && ci < 8'd172);
        ch_r[18]  <= (ci >= 8'd168 && ci < 8'd172) ? (hexd({sn_ad, 16'b0}, ci - 8'd168)) : 8'h00;
        sel_r[19] <= (ci == 8'd176);
        ch_r[19]  <= (ci == 8'd176) ? (hexc({1'b0, sn_ts})) : 8'h00;
        sel_r[20] <= (ci >= 8'd181 && ci < 8'd185);
        ch_r[20]  <= (ci >= 8'd181 && ci < 8'd185) ? (hexd({sn_wq, 16'b0}, ci - 8'd181)) : 8'h00;
        sel_r[21] <= (ci >= 8'd189 && ci < 8'd193);
        ch_r[21]  <= (ci >= 8'd189 && ci < 8'd193) ? (hexd({sn_wm, 16'b0}, ci - 8'd189)) : 8'h00;
        sel_r[22] <= (ci >= 8'd197 && ci < 8'd201);
        ch_r[22]  <= (ci >= 8'd197 && ci < 8'd201) ? (hexd({sn_wu, 16'b0}, ci - 8'd197)) : 8'h00;
        // PO 17 位: 5 个 hex 数字 — 17 位值左对齐到 nibble 窗口需 12 位零扩
        // (同 OC 字段; 用 15 位扩会把值再左移 3 位, 实测显示 E06F0 而非 1C0DE)
        sel_r[23] <= (ci >= 9'd205 && ci < 9'd210);
        ch_r[23]  <= (ci >= 9'd205 && ci < 9'd210) ? (hexd({sn_po, 12'b0}, ci - 9'd205)) : 8'h00;
        sel_r[24] <= (ci >= 9'd214 && ci < 9'd218);
        ch_r[24]  <= (ci >= 9'd214 && ci < 9'd218) ? (hexd({sn_px, 16'b0}, ci - 9'd214)) : 8'h00;
        // ---- P5f 追加段 (UDP app; 前 218 字符不动) ----
        sel_r[25] <= (ci >= 9'd223 && ci < 9'd231);
        ch_r[25]  <= (ci >= 9'd223 && ci < 9'd231) ? (hexd(sn_urb, ci - 9'd223)) : 8'h00;
        sel_r[26] <= (ci >= 9'd236 && ci < 9'd244);
        ch_r[26]  <= (ci >= 9'd236 && ci < 9'd244) ? (hexd(sn_umm, ci - 9'd236)) : 8'h00;
        sel_r[27] <= (ci >= 9'd249 && ci < 9'd253);
        ch_r[27]  <= (ci >= 9'd249 && ci < 9'd253) ? (hexd({sn_urf, 16'b0}, ci - 9'd249)) : 8'h00;
        sel_r[28] <= (ci >= 9'd258 && ci < 9'd262);
        ch_r[28]  <= (ci >= 9'd258 && ci < 9'd262) ? (hexd({sn_uov, 16'b0}, ci - 9'd258)) : 8'h00;
        sel_r[29] <= (ci >= 9'd267 && ci < 9'd271);
        ch_r[29]  <= (ci >= 9'd267 && ci < 9'd271) ? (hexd({sn_upc, 16'b0}, ci - 9'd267)) : 8'h00;
        sel_r[30] <= (ci >= 9'd276 && ci < 9'd280);
        ch_r[30]  <= (ci >= 9'd276 && ci < 9'd280) ? (hexd({sn_upa, 16'b0}, ci - 9'd276)) : 8'h00;
        sel_r[31] <= (ci >= 9'd285 && ci < 9'd293);
        ch_r[31]  <= (ci >= 9'd285 && ci < 9'd293) ? (hexd(sn_utb, ci - 9'd285)) : 8'h00;
        sel_r[32] <= (ci >= 9'd298 && ci < 9'd302);
        ch_r[32]  <= (ci >= 9'd298 && ci < 9'd302) ? (hexd({sn_utf, 16'b0}, ci - 9'd298)) : 8'h00;
`ifdef RXP_DIAG
`ifdef APP_MODE
        // ---- RXP_DIAG 追加段 (偏移由脚本按模板串生成, 见头注释) ----
        sel_r[33] <= (ci >= 9'd306 && ci < 9'd314);
        ch_r[33]  <= (ci >= 9'd306 && ci < 9'd314) ? (hexd(sn_ii, ci - 9'd306)) : 8'h00;
        sel_r[34] <= (ci >= 9'd318 && ci < 9'd320);
        ch_r[34]  <= (ci >= 9'd318 && ci < 9'd320) ? (hexd({sn_gg, 24'b0}, ci - 9'd318)) : 8'h00;
        sel_r[35] <= (ci >= 9'd324 && ci < 9'd326);
        ch_r[35]  <= (ci >= 9'd324 && ci < 9'd326) ? (hexd({sn_ee, 24'b0}, ci - 9'd324)) : 8'h00;
        sel_r[36] <= (ci >= 9'd330 && ci < 9'd332);
        ch_r[36]  <= (ci >= 9'd330 && ci < 9'd332) ? (hexd({sn_pp, 24'b0}, ci - 9'd330)) : 8'h00;
        sel_r[37] <= (ci >= 9'd336 && ci < 9'd344);
        ch_r[37]  <= (ci >= 9'd336 && ci < 9'd344) ? (hexd(sn_ba, ci - 9'd336)) : 8'h00;
        sel_r[38] <= (ci >= 9'd348 && ci < 9'd356);
        ch_r[38]  <= (ci >= 9'd348 && ci < 9'd356) ? (hexd(sn_bb, ci - 9'd348)) : 8'h00;
        sel_r[39] <= (ci >= 9'd360 && ci < 9'd368);
        ch_r[39]  <= (ci >= 9'd360 && ci < 9'd368) ? (hexd(sn_bc, ci - 9'd360)) : 8'h00;
        sel_r[40] <= (ci >= 9'd372 && ci < 9'd380);
        ch_r[40]  <= (ci >= 9'd372 && ci < 9'd380) ? (hexd(sn_dd, ci - 9'd372)) : 8'h00;
        // ---- RXP_DIAG v2 追加段 (偏移由脚本拼接模板串后定位; 见头注释) ----
        // hexq 的 k 端口是 4 位: ci-9'd384 落在 [0,15] 内 (else if 已界定), 隐式
        // 9→4 位截断在此区间内是精确的 (同既有 hexd 传 ci-偏移 的手法)。
        sel_r[41] <= (ci >= 9'd384 && ci < 9'd400);
        ch_r[41]  <= (ci >= 9'd384 && ci < 9'd400) ? (hexq(sn_gw, ci - 9'd384)) : 8'h00;
        sel_r[42] <= (ci >= 9'd404 && ci < 9'd420);
        ch_r[42]  <= (ci >= 9'd404 && ci < 9'd420) ? (hexq(sn_ew, ci - 9'd404)) : 8'h00;
        sel_r[43] <= (ci >= 9'd424 && ci < 9'd432);
        ch_r[43]  <= (ci >= 9'd424 && ci < 9'd432) ? (hexd(sn_oz, ci - 9'd424)) : 8'h00;
        sel_r[44] <= (ci >= 9'd436 && ci < 9'd444);
        ch_r[44]  <= (ci >= 9'd436 && ci < 9'd444) ? (hexd(sn_ol, ci - 9'd436)) : 8'h00;
        sel_r[45] <= (ci >= 9'd448 && ci < 9'd456);
        ch_r[45]  <= (ci >= 9'd448 && ci < 9'd456) ? (hexd(sn_om, ci - 9'd448)) : 8'h00;
        sel_r[46] <= (ci >= 9'd460 && ci < 9'd468);
        ch_r[46]  <= (ci >= 9'd460 && ci < 9'd468) ? (hexd(sn_oh, ci - 9'd460)) : 8'h00;
        // ---- RXP_DIAG v3 追加段 (偏移由 sim/rxpdiag/gen_offsets.py 拼接 TPL 串算出) ----
        // 3 个 hex 字符的窗口 = 32 位端口值的**最高 12 位** (hexd 的 k=0 取 [31:28])。
        // 要让三位连读恰等于原值, 值必须**左对齐在窗口内**, 即端口值 = v << (32-12)
        // = v << 20 ⇒ 写 {v, 20'b0} (拼接 30/29 位, 高位零扩)。
        // ⚠️ 不是"补到 32 位"(22/23 个零): 那会把值左移出窗口 ⇒ 读出 v×4 / v×8
        //   —— 本门实测抓到过 (SF=1AB 显示成 D58 = ×8)。既有 PO/OC 的 12 位零扩
        //   同理 (32-20=12), 不是"补到 32 位"。
        // 1 位值 (SM/FS) 走 hexc (取 [3:0], 天然右对齐)。
        sel_r[47] <= (ci >= 10'd472 && ci < 10'd488);
        ch_r[47]  <= (ci >= 10'd472 && ci < 10'd488) ? (hexq(sn_sw, ci - 10'd472)) : 8'h00;
        sel_r[48] <= (ci >= 10'd492 && ci < 10'd495);
        ch_r[48]  <= (ci >= 10'd492 && ci < 10'd495) ? (hexd({sn_sf, 20'b0}, ci - 10'd492)) : 8'h00;
        sel_r[49] <= (ci == 10'd499);
        ch_r[49]  <= (ci == 10'd499) ? (hexc({3'b0, sn_sm})) : 8'h00;
        sel_r[50] <= (ci >= 10'd504 && ci < 10'd507);
        ch_r[50]  <= (ci >= 10'd504 && ci < 10'd507) ? (hexd({sn_fr, 20'b0}, ci - 10'd504)) : 8'h00;
        sel_r[51] <= (ci >= 10'd511 && ci < 10'd514);
        ch_r[51]  <= (ci >= 10'd511 && ci < 10'd514) ? (hexd({sn_fw, 20'b0}, ci - 10'd511)) : 8'h00;
        sel_r[52] <= (ci >= 10'd518 && ci < 10'd521);
        ch_r[52]  <= (ci >= 10'd518 && ci < 10'd521) ? (hexd({sn_fo, 20'b0}, ci - 10'd518)) : 8'h00;
        sel_r[53] <= (ci >= 10'd525 && ci < 10'd528);
        ch_r[53]  <= (ci >= 10'd525 && ci < 10'd528) ? (hexd({sn_fh, 20'b0}, ci - 10'd525)) : 8'h00;
        sel_r[54] <= (ci == 10'd532);
        ch_r[54]  <= (ci == 10'd532) ? (hexc({2'b0, sn_fs})) : 8'h00;
        sel_r[55] <= (ci >= 10'd537 && ci < 10'd541);
        ch_r[55]  <= (ci >= 10'd537 && ci < 10'd541) ? (hexd({sn_fn, 16'b0}, ci - 10'd537)) : 8'h00;
        sel_r[56] <= (ci >= 10'd545 && ci < 10'd548);
        ch_r[56]  <= (ci >= 10'd545 && ci < 10'd548) ? (hexd({sn_pr, 20'b0}, ci - 10'd545)) : 8'h00;
        sel_r[57] <= (ci >= 10'd552 && ci < 10'd555);
        ch_r[57]  <= (ci >= 10'd552 && ci < 10'd555) ? (hexd({sn_pw, 20'b0}, ci - 10'd552)) : 8'h00;
        sel_r[58] <= (ci >= 10'd559 && ci < 10'd562);
        ch_r[58]  <= (ci >= 10'd559 && ci < 10'd562) ? (hexd({sn_ph, 20'b0}, ci - 10'd559)) : 8'h00;
        sel_r[59] <= (ci >= 10'd566 && ci < 10'd569);
        ch_r[59]  <= (ci >= 10'd566 && ci < 10'd569) ? (hexd({sn_lr, 20'b0}, ci - 10'd566)) : 8'h00;
        sel_r[60] <= (ci >= 10'd573 && ci < 10'd576);
        ch_r[60]  <= (ci >= 10'd573 && ci < 10'd576) ? (hexd({sn_lw, 20'b0}, ci - 10'd573)) : 8'h00;
        sel_r[61] <= (ci >= 10'd580 && ci < 10'd583);
        ch_r[61]  <= (ci >= 10'd580 && ci < 10'd583) ? (hexd({sn_lo, 20'b0}, ci - 10'd580)) : 8'h00;
        sel_r[62] <= (ci >= 10'd587 && ci < 10'd590);
        ch_r[62]  <= (ci >= 10'd587 && ci < 10'd590) ? (hexd({sn_lh, 20'b0}, ci - 10'd587)) : 8'h00;
        sel_r[63] <= (ci >= 10'd594 && ci < 10'd598);
        ch_r[63]  <= (ci >= 10'd594 && ci < 10'd598) ? (hexd({sn_rc, 16'b0}, ci - 10'd594)) : 8'h00;
        sel_r[64] <= (ci >= 10'd602 && ci < 10'd606);
        ch_r[64]  <= (ci >= 10'd602 && ci < 10'd606) ? (hexd({sn_vc, 16'b0}, ci - 10'd602)) : 8'h00;
        sel_r[65] <= (ci >= 10'd610 && ci < 10'd613);
        ch_r[65]  <= (ci >= 10'd610 && ci < 10'd613) ? (hexd({sn_vx, 20'b0}, ci - 10'd610)) : 8'h00;
        sel_r[66] <= (ci >= 10'd617 && ci < 10'd620);
        ch_r[66]  <= (ci >= 10'd617 && ci < 10'd620) ? (hexd({sn_vs, 20'b0}, ci - 10'd617)) : 8'h00;
        sel_r[67] <= (ci >= 10'd624 && ci < 10'd627);
        ch_r[67]  <= (ci >= 10'd624 && ci < 10'd627) ? (hexd({sn_vr, 20'b0}, ci - 10'd624)) : 8'h00;
        sel_r[68] <= (ci >= 10'd631 && ci < 10'd635);
        ch_r[68]  <= (ci >= 10'd631 && ci < 10'd635) ? (hexd({sn_vn, 16'b0}, ci - 10'd631)) : 8'h00;
        // ---- RXP_DIAG v4 追加段 (偏移由 sim/rxpdiag/gen_offsets.py 拼接 TPL 串算出) ----
        // 16 位值 → 4 个 hex: 用 {v, 16'b0} 让值**左对齐**在 32 位里 (hexd 从 [31:28] 起取)
        //   —— 同 v3 的 RC/VC 手法。错写成"补到 32 位"会把值左移出窗口。
        // 24 位值 (QA..QH) → 6 个 hex: {v, 8'b0} (32-24 = 8)。
        // 1 位值 (EO) / 4 位值 (EN) 走 hexc (天然右对齐)。
        sel_r[69] <= (ci >= 10'd639 && ci < 10'd643);
        ch_r[69]  <= (ci >= 10'd639 && ci < 10'd643) ? (hexd({sn_cn, 16'b0}, ci - 10'd639)) : 8'h00;
        sel_r[70] <= (ci >= 10'd647 && ci < 10'd651);
        ch_r[70]  <= (ci >= 10'd647 && ci < 10'd651) ? (hexd({sn_rd, 16'b0}, ci - 10'd647)) : 8'h00;
        sel_r[71] <= (ci >= 10'd655 && ci < 10'd659);
        ch_r[71]  <= (ci >= 10'd655 && ci < 10'd659) ? (hexd({sn_nc, 16'b0}, ci - 10'd655)) : 8'h00;
        sel_r[72] <= (ci >= 10'd663 && ci < 10'd667);
        ch_r[72]  <= (ci >= 10'd663 && ci < 10'd667) ? (hexd({sn_np, 16'b0}, ci - 10'd663)) : 8'h00;
        sel_r[73] <= (ci >= 10'd671 && ci < 10'd675);
        ch_r[73]  <= (ci >= 10'd671 && ci < 10'd675) ? (hexd({sn_wf, 16'b0}, ci - 10'd671)) : 8'h00;
        sel_r[74] <= (ci >= 10'd679 && ci < 10'd683);
        ch_r[74]  <= (ci >= 10'd679 && ci < 10'd683) ? (hexd({sn_rl, 16'b0}, ci - 10'd679)) : 8'h00;
        sel_r[75] <= (ci >= 10'd687 && ci < 10'd691);
        ch_r[75]  <= (ci >= 10'd687 && ci < 10'd691) ? (hexd({sn_wc, 16'b0}, ci - 10'd687)) : 8'h00;
        sel_r[76] <= (ci >= 10'd695 && ci < 10'd699);
        ch_r[76]  <= (ci >= 10'd695 && ci < 10'd699) ? (hexd({sn_ne, 16'b0}, ci - 10'd695)) : 8'h00;
        sel_r[77] <= (ci >= 10'd703 && ci < 10'd707);
        ch_r[77]  <= (ci >= 10'd703 && ci < 10'd707) ? (hexd({sn_nr, 16'b0}, ci - 10'd703)) : 8'h00;
        sel_r[78] <= (ci >= 10'd711 && ci < 10'd715);
        ch_r[78]  <= (ci >= 10'd711 && ci < 10'd715) ? (hexd({sn_mr, 16'b0}, ci - 10'd711)) : 8'h00;
        sel_r[79] <= (ci == 10'd719);
        ch_r[79]  <= (ci == 10'd719) ? (hexc(sn_en)) : 8'h00;
        sel_r[80] <= (ci == 10'd724);
        ch_r[80]  <= (ci == 10'd724) ? (hexc({3'b0, sn_eo})) : 8'h00;
        sel_r[81] <= (ci >= 10'd729 && ci < 10'd735);
        ch_r[81]  <= (ci >= 10'd729 && ci < 10'd735) ? (hexd({sn_qa, 8'b0}, ci - 10'd729)) : 8'h00;
        sel_r[82] <= (ci >= 10'd739 && ci < 10'd745);
        ch_r[82]  <= (ci >= 10'd739 && ci < 10'd745) ? (hexd({sn_qb, 8'b0}, ci - 10'd739)) : 8'h00;
        sel_r[83] <= (ci >= 10'd749 && ci < 10'd755);
        ch_r[83]  <= (ci >= 10'd749 && ci < 10'd755) ? (hexd({sn_qc, 8'b0}, ci - 10'd749)) : 8'h00;
        sel_r[84] <= (ci >= 10'd759 && ci < 10'd765);
        ch_r[84]  <= (ci >= 10'd759 && ci < 10'd765) ? (hexd({sn_qd, 8'b0}, ci - 10'd759)) : 8'h00;
        sel_r[85] <= (ci >= 10'd769 && ci < 10'd775);
        ch_r[85]  <= (ci >= 10'd769 && ci < 10'd775) ? (hexd({sn_qe, 8'b0}, ci - 10'd769)) : 8'h00;
        sel_r[86] <= (ci >= 10'd779 && ci < 10'd785);
        ch_r[86]  <= (ci >= 10'd779 && ci < 10'd785) ? (hexd({sn_qf, 8'b0}, ci - 10'd779)) : 8'h00;
        sel_r[87] <= (ci >= 10'd789 && ci < 10'd795);
        ch_r[87]  <= (ci >= 10'd789 && ci < 10'd795) ? (hexd({sn_qg, 8'b0}, ci - 10'd789)) : 8'h00;
        sel_r[88] <= (ci >= 10'd799 && ci < 10'd805);
        ch_r[88]  <= (ci >= 10'd799 && ci < 10'd805) ? (hexd({sn_qh, 8'b0}, ci - 10'd799)) : 8'h00;
        // ---- RXP_DIAG v5 追加段 (偏移由 sim/rxpdiag/gen_offsets.py 拼接 TPL 串算出) ----
        // 32 位值 (DV/DM/PS/NM/IC/DC/SB) → 8 个 hex: 直接 `hexd(sn_xx, ci - 10'dA)`
        //   (无拼接 = 不左移; 窗口宽度恰 8 ⇒ 值与窗口逐位对齐)。
        // 16 位值 (DO) → 4 个 hex: `{sn_do, 16'b0}` (左对齐; 同 v3 的 RC/VC 手法)。
        // 8 位值 (DG/DE) → 2 个 hex: `{sn_dg, 24'b0}` (32-8 = 24)。
        // 1 位值 (VZ) 走 hexc (天然右对齐)。
        // ⚠️ 每个字段的**窗口末尾必须紧跟下一个字段的前导空格** —— 窗口串位/多一
        //    字符都会让 tb_rxp_diag 相 7 的逐值断言变红 (值刻意互不相同)。
        sel_r[89] <= (ci >= 10'd809 && ci < 10'd817);
        ch_r[89]  <= (ci >= 10'd809 && ci < 10'd817) ? (hexd(sn_dv, ci - 10'd809)) : 8'h00;
        sel_r[90] <= (ci >= 10'd821 && ci < 10'd823);
        ch_r[90]  <= (ci >= 10'd821 && ci < 10'd823) ? (hexd({sn_dg, 24'b0}, ci - 10'd821)) : 8'h00;
        sel_r[91] <= (ci >= 10'd827 && ci < 10'd829);
        ch_r[91]  <= (ci >= 10'd827 && ci < 10'd829) ? (hexd({sn_de, 24'b0}, ci - 10'd827)) : 8'h00;
        sel_r[92] <= (ci >= 10'd833 && ci < 10'd837);
        ch_r[92]  <= (ci >= 10'd833 && ci < 10'd837) ? (hexd({sn_do, 16'b0}, ci - 10'd833)) : 8'h00;
        sel_r[93] <= (ci >= 10'd841 && ci < 10'd849);
        ch_r[93]  <= (ci >= 10'd841 && ci < 10'd849) ? (hexd(sn_dm, ci - 10'd841)) : 8'h00;
        sel_r[94] <= (ci == 10'd853);
        ch_r[94]  <= (ci == 10'd853) ? (hexc({3'b0, sn_vz})) : 8'h00;
        sel_r[95] <= (ci >= 10'd858 && ci < 10'd866);
        ch_r[95]  <= (ci >= 10'd858 && ci < 10'd866) ? (hexd(sn_ps, ci - 10'd858)) : 8'h00;
        sel_r[96] <= (ci >= 10'd870 && ci < 10'd878);
        ch_r[96]  <= (ci >= 10'd870 && ci < 10'd878) ? (hexd(sn_nm, ci - 10'd870)) : 8'h00;
        sel_r[97] <= (ci >= 10'd882 && ci < 10'd890);
        ch_r[97]  <= (ci >= 10'd882 && ci < 10'd890) ? (hexd(sn_ic, ci - 10'd882)) : 8'h00;
        sel_r[98] <= (ci >= 10'd894 && ci < 10'd902);
        ch_r[98]  <= (ci >= 10'd894 && ci < 10'd902) ? (hexd(sn_dc, ci - 10'd894)) : 8'h00;
        sel_r[99] <= (ci >= 10'd906 && ci < 10'd914);
        ch_r[99]  <= (ci >= 10'd906 && ci < 10'd914) ? (hexd(sn_sb, ci - 10'd906)) : 8'h00;
        // ---- RXP_DIAG v6 追加段 (偏移由 sim/rxpdiag/gen_offsets.py 拼接 TPL 串算出) ----
        // 32 位值 (CV/CM) → 8 个 hex: 直接 `hexd(sn_xx, ci - 10'dA)` (窗口恰 8 ⇒ 对齐)。
        // 16 位值 (CO) → 4 个 hex: `{sn_co, 16'b0}` (左对齐; 同 v3/v5 的 RC/DO 手法)。
        // 8 位值 (CG/CE/CS) → 2 个 hex: `{sn_cg, 24'b0}` (32-8 = 24)。
        // 1 位值 (CZ) 走 hexc (天然右对齐; 单点窗口 `ci ==`)。
        // ⚠️ 每个字段的**窗口末尾必须紧跟下一个字段的前导空格** —— 窗口串位/多一
        //    字符都会让 tb_rxp_diag 相 7 的逐值断言变红 (值刻意互不相同)。
        sel_r[100] <= (ci >= 10'd918 && ci < 10'd926);
        ch_r[100]  <= (ci >= 10'd918 && ci < 10'd926) ? (hexd(sn_cv, ci - 10'd918)) : 8'h00;
        sel_r[101] <= (ci >= 10'd930 && ci < 10'd932);
        ch_r[101]  <= (ci >= 10'd930 && ci < 10'd932) ? (hexd({sn_cg, 24'b0}, ci - 10'd930)) : 8'h00;
        sel_r[102] <= (ci >= 10'd936 && ci < 10'd938);
        ch_r[102]  <= (ci >= 10'd936 && ci < 10'd938) ? (hexd({sn_ce, 24'b0}, ci - 10'd936)) : 8'h00;
        sel_r[103] <= (ci >= 10'd942 && ci < 10'd946);
        ch_r[103]  <= (ci >= 10'd942 && ci < 10'd946) ? (hexd({sn_co, 16'b0}, ci - 10'd942)) : 8'h00;
        sel_r[104] <= (ci >= 10'd950 && ci < 10'd958);
        ch_r[104]  <= (ci >= 10'd950 && ci < 10'd958) ? (hexd(sn_cm, ci - 10'd950)) : 8'h00;
        sel_r[105] <= (ci == 10'd962);
        ch_r[105]  <= (ci == 10'd962) ? (hexc({3'b0, sn_cz})) : 8'h00;
        sel_r[106] <= (ci >= 10'd967 && ci < 10'd969);
        ch_r[106]  <= (ci >= 10'd967 && ci < 10'd969) ? (hexd({sn_cs, 24'b0}, ci - 10'd967)) : 8'h00;
`endif
`endif
        end
    end

    wire uart_busy;
    wire uart_go = sending && !uart_busy;
    uart_tx_9600 #(.BIT_LAST(BIT_LAST)) u_uart (
        .clk(clk), .rst_n(rst_n),
        .byte_in(lc), .tx_go(uart_go), .txd(txd), .busy(uart_busy)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ci <= 10'd0; gap <= 28'd0; sending <= 1'b0;
            sn_st <= 4'd0; sn_nx <= 32'd0; sn_ua <= 32'd0; sn_rn <= 32'd0;
            sn_rx <= 32'd0; sn_tx <= 32'd0; sn_rw <= 16'd0; sn_tf <= 16'd0;
            sn_mm <= 16'd0; sn_oc <= 17'd0; sn_ev <= 16'd0; sn_dp <= 16'd0;
            sn_ry <= 16'd0; sn_ec <= 16'd0;
            sn_dl <= 16'd0; sn_fi <= 16'd0; sn_rs <= 16'd0;
            sn_ak <= 16'd0; sn_ad <= 16'd0; sn_ts <= 3'd0; sn_wq <= 16'd0;
            sn_wm <= 16'd0; sn_wu <= 16'd0; sn_po <= 17'd0; sn_px <= 16'd0;
            sn_urb <= 32'd0; sn_umm <= 32'd0; sn_utb <= 32'd0;
            sn_urf <= 16'd0; sn_uov <= 16'd0; sn_upc <= 16'd0;
            sn_upa <= 16'd0; sn_utf <= 16'd0;
`ifdef RXP_DIAG
`ifdef APP_MODE
            sn_ii <= 32'd0;
            sn_gg <= 8'd0;  sn_ee <= 8'd0;  sn_pp <= 8'd0;
            sn_ba <= 32'd0; sn_bb <= 32'd0; sn_bc <= 32'd0; sn_dd <= 32'd0;
            sn_gw <= 64'd0; sn_ew <= 64'd0;
            sn_oz <= 32'd0; sn_ol <= 32'd0; sn_om <= 32'd0; sn_oh <= 32'd0;
            sn_sw <= 64'd0; sn_sf <= 9'd0; sn_sm <= 1'b0; sn_wd <= 8'd0;
            sn_fr <= 10'd0; sn_fw <= 10'd0; sn_fo <= 10'd0; sn_fh <= 10'd0;
            sn_fs <= 2'd0;  sn_fn <= 16'd0;
            sn_pr <= 10'd0; sn_pw <= 10'd0; sn_ph <= 10'd0;
            sn_lr <= 10'd0; sn_lw <= 10'd0; sn_lo <= 10'd0; sn_lh <= 10'd0;
            sn_rc <= 16'd0; sn_vc <= 16'd0;
            sn_vx <= 10'd0; sn_vs <= 10'd0; sn_vr <= 10'd0; sn_vn <= 16'd0;
            sn_cn <= 16'd0; sn_rd <= 16'd0; sn_nc <= 16'd0; sn_np <= 16'd0;
            sn_wf <= 16'd0; sn_rl <= 16'd0; sn_wc <= 16'd0;
            sn_ne <= 16'd0; sn_nr <= 16'd0; sn_mr <= 16'd0;
            sn_en <= 4'd0;  sn_eo <= 1'b0;
            sn_qa <= 24'd0; sn_qb <= 24'd0; sn_qc <= 24'd0; sn_qd <= 24'd0;
            sn_qe <= 24'd0; sn_qf <= 24'd0; sn_qg <= 24'd0; sn_qh <= 24'd0;
            sn_cv <= 32'd0; sn_cm <= 32'd0;
            sn_cg <= 8'd0;  sn_ce <= 8'd0;  sn_cs <= 8'd0;
            sn_co <= 16'd0; sn_cz <= 1'b0;
`endif
`endif
        end else begin
            if (!sending) begin
                // 行间间隔到 -> 锁存快照并开新行
                if (gap == 28'd0) begin
                    sn_st <= st0;        sn_nx <= snd_nxt;  sn_ua <= snd_una;
                    sn_rn <= rcv_nxt;    sn_rw <= rcv_wnd;
                    sn_rx <= stat_rx_bytes; sn_tx <= stat_tx_bytes;
                    sn_tf <= stat_tx_frames; sn_mm <= stat_mismatch;
                    sn_oc <= rx_occ;     sn_ev <= ev_cnt;   sn_dp <= ev_drop;
                    sn_ry <= app_tx_ready; sn_ec <= estab_cnt;
                    sn_dl <= stat_drop_len; sn_fi <= stat_fin; sn_rs <= stat_rst;
                    sn_ak <= stat_ack;   sn_ad <= stat_ack_drop;
                    sn_ts <= fsm_state;  sn_wq <= winq0; sn_wm <= wu_mark0;
                    sn_wu <= stat_wu;    sn_po <= pool;  sn_px <= stat_pool_exh;
                    sn_urb <= udp_rx_bytes; sn_umm <= udp_mismatch;
                    sn_utb <= udp_tx_bytes;
                    sn_urf <= udp_rx_frames; sn_uov <= udp_drop_ovf;
                    sn_upc <= udp_drop_crc;  sn_upa <= udp_drop_part;
                    sn_utf <= udp_tx_frames;
`ifdef RXP_DIAG
`ifdef APP_MODE
                    sn_ii <= ds_idx;  sn_gg <= ds_got;
                    sn_ee <= ds_exp;  sn_pp <= ds_prev;
                    sn_ba <= ds_b1;   sn_bb <= ds_b2;  sn_bc <= ds_bg;
                    sn_dd <= ds_dup;
                    sn_gw <= ds_gw;   sn_ew <= ds_ew;
                    sn_oz <= ds_oz;   sn_ol <= ds_ol;
                    sn_om <= ds_om;   sn_oh <= ds_oh;
                    sn_sw <= v3_sw;   sn_sf <= v3_sf;  sn_sm <= v3_sm;
                    sn_wd <= v3_wd;
                    sn_fr <= v3_fr;   sn_fw <= v3_fw;  sn_fo <= v3_fo;
                    sn_fh <= v3_fh;   sn_fs <= v3_fs;  sn_fn <= v3_fn;
                    sn_pr <= v3_pr;   sn_pw <= v3_pw;  sn_ph <= v3_ph;
                    sn_lr <= v3_lr;   sn_lw <= v3_lw;  sn_lo <= v3_lo;
                    sn_lh <= v3_lh;
                    sn_rc <= v3_rc;   sn_vc <= v3_vc;
                    sn_vx <= v3_vx;   sn_vs <= v3_vs;  sn_vr <= v3_vr;
                    sn_vn <= v3_vn;
                    // ---- RXP_DIAG v4 追加段 ----
                    sn_cn <= v4_cn;   sn_rd <= v4_rd;  sn_nc <= v4_nc;
                    sn_np <= v4_np;   sn_wf <= v4_wf;  sn_rl <= v4_rl;
                    sn_wc <= v4_wc;
                    sn_ne <= v4_ne;   sn_nr <= v4_nr;  sn_mr <= v4_mr;
                    sn_en <= v4_en;   sn_eo <= v4_eo;
                    sn_qa <= v4_qa;   sn_qb <= v4_qb;  sn_qc <= v4_qc;
                    sn_qd <= v4_qd;   sn_qe <= v4_qe;  sn_qf <= v4_qf;
                    sn_qg <= v4_qg;   sn_qh <= v4_qh;
                    // v5: 写侧 LFSR 校验器 (udp_split) + 解析器计数 (udp_rx)
                    sn_dv <= v5_dv_idx; sn_dg <= v5_dv_got; sn_de <= v5_dv_exp;
                    sn_do <= v5_dv_off; sn_dm <= v5_dv_mm;  sn_vz <= v5_dv_v;
                    sn_ps <= v5_up_pass; sn_nm <= v5_up_nm; sn_ic <= v5_up_ipc;
                    sn_dc <= v5_up_crc;  sn_sb <= v5_up_bytes;
                    // v6: u_pre 输入侧 (udp_split 的 s_axis) LFSR 校验器
                    sn_cv <= v6_dv_idx; sn_cg <= v6_dv_got; sn_ce <= v6_dv_exp;
                    sn_co <= v6_dv_off; sn_cm <= v6_dv_mm;  sn_cz <= v6_dv_v;
                    sn_cs <= v6_dv_sk;
`endif
`endif
                    ci       <= 10'd0;
                    sending  <= 1'b1;
                end else begin
                    gap <= gap - 28'd1;
                end
            end else if (uart_go) begin
                // 本拍发送 lc (ci 指向它), 推进索引
                if (ci == (LINE_LEN - 10'd1)) begin
                    sending <= 1'b0;
                    gap     <= GAP_TICKS;
                    ci      <= 10'd0;
                end else begin
                    ci <= ci + 10'd1;
                end
            end
        end
    end
endmodule
