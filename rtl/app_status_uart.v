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
    localparam LINE_LEN = 10'd637;
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
`endif
`endif

    reg [9:0]  ci;                       // 行内字符索引 (10 位: 最长行 637 = RXP_DIAG v3;
                                         // v2 时是 9 位/470 —— 470 > 512 边界由
                                         // gen_offsets.py 的 LINE_LEN<=1023 断言守住)
    reg [27:0] gap;
    reg        sending;

    // 当前字符 (组合): 固定模板 + hex 字段覆盖
    wire [7:0] fixed_c = TPL[ (8*(LINE_LEN-1) - 8*ci) +: 8 ];
    reg  [7:0] lc;
    always @(*) begin
        lc = fixed_c;
        if      (ci == 8'd8)                        lc = hexc(sn_st);
        else if (ci >= 8'd13  && ci < 8'd21)        lc = hexd(sn_nx, ci - 8'd13);
        else if (ci >= 8'd25  && ci < 8'd33)        lc = hexd(sn_ua, ci - 8'd25);
        else if (ci >= 8'd37  && ci < 8'd41)        lc = hexd({sn_rw, 16'b0}, ci - 8'd37);
        else if (ci >= 8'd45  && ci < 8'd53)        lc = hexd(sn_rn, ci - 8'd45);
        else if (ci >= 8'd57  && ci < 8'd65)        lc = hexd(sn_rx, ci - 8'd57);
        else if (ci >= 8'd69  && ci < 8'd77)        lc = hexd(sn_tx, ci - 8'd69);
        else if (ci >= 8'd81  && ci < 8'd85)        lc = hexd({sn_tf, 16'b0}, ci - 8'd81);
        else if (ci >= 8'd89  && ci < 8'd93)        lc = hexd({sn_mm, 16'b0}, ci - 8'd89);
        else if (ci >= 8'd97  && ci < 8'd102)       lc = hexd({sn_oc, 12'b0}, ci - 8'd97);
        else if (ci >= 8'd106 && ci < 8'd110)       lc = hexd({sn_ev, 16'b0}, ci - 8'd106);
        else if (ci >= 8'd114 && ci < 8'd118)       lc = hexd({sn_dp, 16'b0}, ci - 8'd114);
        else if (ci >= 8'd122 && ci < 8'd126)       lc = hexd({sn_ry, 16'b0}, ci - 8'd122);
        // EC 只显示低 2 位 hex (16 位字段里的 8 位值): 左对齐低字节
        else if (ci >= 8'd130 && ci < 8'd132)       lc = hexd({sn_ec[7:0], 24'b0}, ci - 8'd130);
        else if (ci >= 8'd136 && ci < 8'd140)       lc = hexd({sn_dl, 16'b0}, ci - 8'd136);
        else if (ci >= 8'd144 && ci < 8'd148)       lc = hexd({sn_fi, 16'b0}, ci - 8'd144);
        else if (ci >= 8'd152 && ci < 8'd156)       lc = hexd({sn_rs, 16'b0}, ci - 8'd152);
        // ---- P5b C9 追加段 (字段位置见头注释; 前 156 字符不动) ----
        else if (ci >= 8'd160 && ci < 8'd164)       lc = hexd({sn_ak, 16'b0}, ci - 8'd160);
        else if (ci >= 8'd168 && ci < 8'd172)       lc = hexd({sn_ad, 16'b0}, ci - 8'd168);
        else if (ci == 8'd176)                      lc = hexc({1'b0, sn_ts});
        else if (ci >= 8'd181 && ci < 8'd185)       lc = hexd({sn_wq, 16'b0}, ci - 8'd181);
        else if (ci >= 8'd189 && ci < 8'd193)       lc = hexd({sn_wm, 16'b0}, ci - 8'd189);
        else if (ci >= 8'd197 && ci < 8'd201)       lc = hexd({sn_wu, 16'b0}, ci - 8'd197);
        // PO 17 位: 5 个 hex 数字 — 17 位值左对齐到 nibble 窗口需 12 位零扩
        // (同 OC 字段; 用 15 位扩会把值再左移 3 位, 实测显示 E06F0 而非 1C0DE)
        else if (ci >= 9'd205 && ci < 9'd210)       lc = hexd({sn_po, 12'b0}, ci - 9'd205);
        else if (ci >= 9'd214 && ci < 9'd218)       lc = hexd({sn_px, 16'b0}, ci - 9'd214);
        // ---- P5f 追加段 (UDP app; 前 218 字符不动) ----
        else if (ci >= 9'd223 && ci < 9'd231)       lc = hexd(sn_urb, ci - 9'd223);
        else if (ci >= 9'd236 && ci < 9'd244)       lc = hexd(sn_umm, ci - 9'd236);
        else if (ci >= 9'd249 && ci < 9'd253)       lc = hexd({sn_urf, 16'b0}, ci - 9'd249);
        else if (ci >= 9'd258 && ci < 9'd262)       lc = hexd({sn_uov, 16'b0}, ci - 9'd258);
        else if (ci >= 9'd267 && ci < 9'd271)       lc = hexd({sn_upc, 16'b0}, ci - 9'd267);
        else if (ci >= 9'd276 && ci < 9'd280)       lc = hexd({sn_upa, 16'b0}, ci - 9'd276);
        else if (ci >= 9'd285 && ci < 9'd293)       lc = hexd(sn_utb, ci - 9'd285);
        else if (ci >= 9'd298 && ci < 9'd302)       lc = hexd({sn_utf, 16'b0}, ci - 9'd298);
`ifdef RXP_DIAG
`ifdef APP_MODE
        // ---- RXP_DIAG 追加段 (偏移由脚本按模板串生成, 见头注释) ----
        else if (ci >= 9'd306 && ci < 9'd314)       lc = hexd(sn_ii, ci - 9'd306);
        else if (ci >= 9'd318 && ci < 9'd320)       lc = hexd({sn_gg, 24'b0}, ci - 9'd318);
        else if (ci >= 9'd324 && ci < 9'd326)       lc = hexd({sn_ee, 24'b0}, ci - 9'd324);
        else if (ci >= 9'd330 && ci < 9'd332)       lc = hexd({sn_pp, 24'b0}, ci - 9'd330);
        else if (ci >= 9'd336 && ci < 9'd344)       lc = hexd(sn_ba, ci - 9'd336);
        else if (ci >= 9'd348 && ci < 9'd356)       lc = hexd(sn_bb, ci - 9'd348);
        else if (ci >= 9'd360 && ci < 9'd368)       lc = hexd(sn_bc, ci - 9'd360);
        else if (ci >= 9'd372 && ci < 9'd380)       lc = hexd(sn_dd, ci - 9'd372);
        // ---- RXP_DIAG v2 追加段 (偏移由脚本拼接模板串后定位; 见头注释) ----
        // hexq 的 k 端口是 4 位: ci-9'd384 落在 [0,15] 内 (else if 已界定), 隐式
        // 9→4 位截断在此区间内是精确的 (同既有 hexd 传 ci-偏移 的手法)。
        else if (ci >= 9'd384 && ci < 9'd400)       lc = hexq(sn_gw, ci - 9'd384);
        else if (ci >= 9'd404 && ci < 9'd420)       lc = hexq(sn_ew, ci - 9'd404);
        else if (ci >= 9'd424 && ci < 9'd432)       lc = hexd(sn_oz, ci - 9'd424);
        else if (ci >= 9'd436 && ci < 9'd444)       lc = hexd(sn_ol, ci - 9'd436);
        else if (ci >= 9'd448 && ci < 9'd456)       lc = hexd(sn_om, ci - 9'd448);
        else if (ci >= 9'd460 && ci < 9'd468)       lc = hexd(sn_oh, ci - 9'd460);
        // ---- RXP_DIAG v3 追加段 (偏移由 sim/rxpdiag/gen_offsets.py 拼接 TPL 串算出) ----
        // 3 个 hex 字符的窗口 = 32 位端口值的**最高 12 位** (hexd 的 k=0 取 [31:28])。
        // 要让三位连读恰等于原值, 值必须**左对齐在窗口内**, 即端口值 = v << (32-12)
        // = v << 20 ⇒ 写 {v, 20'b0} (拼接 30/29 位, 高位零扩)。
        // ⚠️ 不是"补到 32 位"(22/23 个零): 那会把值左移出窗口 ⇒ 读出 v×4 / v×8
        //   —— 本门实测抓到过 (SF=1AB 显示成 D58 = ×8)。既有 PO/OC 的 12 位零扩
        //   同理 (32-20=12), 不是"补到 32 位"。
        // 1 位值 (SM/FS) 走 hexc (取 [3:0], 天然右对齐)。
        else if (ci >= 10'd472 && ci < 10'd488)     lc = hexq(sn_sw, ci - 10'd472);
        else if (ci >= 10'd492 && ci < 10'd495)     lc = hexd({sn_sf, 20'b0}, ci - 10'd492);
        else if (ci == 10'd499)                     lc = hexc({3'b0, sn_sm});
        else if (ci >= 10'd504 && ci < 10'd507)     lc = hexd({sn_fr, 20'b0}, ci - 10'd504);
        else if (ci >= 10'd511 && ci < 10'd514)     lc = hexd({sn_fw, 20'b0}, ci - 10'd511);
        else if (ci >= 10'd518 && ci < 10'd521)     lc = hexd({sn_fo, 20'b0}, ci - 10'd518);
        else if (ci >= 10'd525 && ci < 10'd528)     lc = hexd({sn_fh, 20'b0}, ci - 10'd525);
        else if (ci == 10'd532)                     lc = hexc({2'b0, sn_fs});
        else if (ci >= 10'd537 && ci < 10'd541)     lc = hexd({sn_fn, 16'b0}, ci - 10'd537);
        else if (ci >= 10'd545 && ci < 10'd548)     lc = hexd({sn_pr, 20'b0}, ci - 10'd545);
        else if (ci >= 10'd552 && ci < 10'd555)     lc = hexd({sn_pw, 20'b0}, ci - 10'd552);
        else if (ci >= 10'd559 && ci < 10'd562)     lc = hexd({sn_ph, 20'b0}, ci - 10'd559);
        else if (ci >= 10'd566 && ci < 10'd569)     lc = hexd({sn_lr, 20'b0}, ci - 10'd566);
        else if (ci >= 10'd573 && ci < 10'd576)     lc = hexd({sn_lw, 20'b0}, ci - 10'd573);
        else if (ci >= 10'd580 && ci < 10'd583)     lc = hexd({sn_lo, 20'b0}, ci - 10'd580);
        else if (ci >= 10'd587 && ci < 10'd590)     lc = hexd({sn_lh, 20'b0}, ci - 10'd587);
        else if (ci >= 10'd594 && ci < 10'd598)     lc = hexd({sn_rc, 16'b0}, ci - 10'd594);
        else if (ci >= 10'd602 && ci < 10'd606)     lc = hexd({sn_vc, 16'b0}, ci - 10'd602);
        else if (ci >= 10'd610 && ci < 10'd613)     lc = hexd({sn_vx, 20'b0}, ci - 10'd610);
        else if (ci >= 10'd617 && ci < 10'd620)     lc = hexd({sn_vs, 20'b0}, ci - 10'd617);
        else if (ci >= 10'd624 && ci < 10'd627)     lc = hexd({sn_vr, 20'b0}, ci - 10'd624);
        else if (ci >= 10'd631 && ci < 10'd635)     lc = hexd({sn_vn, 16'b0}, ci - 10'd631);
`endif
`endif
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
