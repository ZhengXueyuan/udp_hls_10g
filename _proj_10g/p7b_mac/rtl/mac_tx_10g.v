`timescale 1ns/1ps
// ===========================================================================
// mac_tx_10g —— 64 位帧流合同 → 64 位 XGMII 发送 MAC
// ===========================================================================
// 输出帧 (线上, XGMII 一拍 8 个字符):
//   [lane0:/S/(c=1) + lane1..6:0x55 + lane7:0xD5] [内容 DA..payload] [pad 到 60] [FCS 4B]
//   [/T/ 落在最后一个有效字节之后的那个 lane] [/I/ 补满 IFG (>= 12 个 /I/)]
// ⭐ FCS 覆盖面: **内容字节 + 补出来的 pad 字节** (802.3 3.2.9: FCS 覆盖 <data> 全部字节;
//   pad 是 <data> 的一部分) —— 2026-09-30 修复 (原实现只覆盖内容, 短帧被自家 RX 拒收)。
// 前导/IFG 常量与出处见 rtl/mac_10g_defs.vh §2/§3; FCS 见 §4。
// 源约定 (与 1G 版逐字相同): 每词 tkeep != 0 (高位有效, = mac_rx_10g 的输出约定);
//   帧边界**只**靠 tlast (TX 字流不带 tuser/SOP) —— rtl/mac_tx_64.v:21
//
// ⭐ 真流水的 64 位结构 (不是"把 1G 的字节机加宽"; 对照 1G 的 8+4+12=24 拍固定开销):
//   前导只占**帧首那一拍**的 lane 里 (没有 S_PRE 的 8 拍);
//   FCS 在**末内容字那一拍**用 8 字节并行 CRC 结清 (crc_nxt 组合), 并与该字**同拍**落位
//   (末字 = "内容残余 + pad + FCS + /T/ + /I/" 的**合并字**, 不额外占拍);
//   pad / FCS / /T/ / /I/ 由"尾向量 t16"的变长字节拼接一次成形, 不逐字节播放。
//   ⇒ 每帧拍数 = 1(前导) + ceil(L/8)(内容, 末字与尾合并) + 1(尾字) + IFG(1~2)
//      L=60 → 11 拍 (线侧预算 84B/88B = 95.5%); L=1514 → 99.6%  (算数见 notes §7)
//
// 尾向量 t16 (12 字节, 逻辑索引; lane 与索引之差 = t_start = 本字内容字节数 + 本字 pad 数):
//   [0..3] = FCS (小端: 低字节先上线)   [4] = /T/   [>=5] = /I/
//
// ===========================================================================
// §F-2 (逐字保住 rtl/mac_tx_64.v:224-244 的语义): 帧内中止后必须冲刷到本帧 TLAST
// ===========================================================================
// 中止 ⇒ **立即补一个 /T/ 把帧结掉** (802.3 46.2.1: <inter-frame> 以 Terminate 开头;
//   缺 /T/ 会让对端一直等不到帧尾 ⇒ 线上不能出现"永不终止的数据流"。1G GMII 没有 /T/
//   概念, 这是 XGMII 的必要补充, 已登记为"与 1G 实现的必要偏离"), 然后进 S_FLUSH:
//   **一个字都不发**, 逐字弹掉输入 FIFO 直到吞掉本帧 TLAST (判据 `frd && fdout[0]`),
//   再等够 IFG 才回 S_IDLE ⇒ 残字绝不被当成下一帧 (否则会发出 FCS 完全正确的"幽灵帧")。
// ===========================================================================

module mac_tx_10g (
    input  wire        clk,          // tx_mii_clk (官方核 tx_mii_clk_N)
    input  wire        rst_n,        // 低有效; 建议 = ~user_tx_reset_N (同域)
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    output wire [63:0] xgmii_txd,    // lane l = [8l +: 8]
    output wire [7:0]  xgmii_txc,    // c[l] ↔ lane l
    output reg  [31:0] stat_frames,
    output reg  [31:0] stat_abort,        // 帧内中止次数 (线上留 runt + /T/ 结帧)
    output reg  [31:0] stat_flush_words,  // 冲刷期被丢弃的输入字数 (F-2)
    output reg  [31:0] stat_flush_done,   // 冲刷完成次数 (= 重新对齐到帧边界的次数)
    // P7b 新增
    output reg  [31:0] stat_tx_words,     // 发出的 XGMII 字数 (速率正证据: ×64bit = 线速)
    output reg  [31:0] stat_tx_ctrl_char, // 发出的控制字符数 (含 /S/ /T/ /I/; IFG 证据)
    output reg  [31:0] stat_tx_short,     // 中止帧数 (= 线上 runt 数)
    // ⭐ P7B-A7-LINE (2026-10-10): **线占空计数器** —— 纯观测, 不接任何功能路径。
    //   语义 (逐字, 与下面的计数块逐字对应): rst_n 有效且**本拍执行态** `state == S_IDLE`
    //   的每一拍 +1。
    //     · 计: 复位释放后 FIFO 空、FSM 停在 S_IDLE 的那些拍 (线上正发 /I/)。
    //     · 不计: 复位那一拍 (走 !rst_n 支, 计数清零); 以及 state ∈ {S_PRE, S_DATA,
    //       S_TAIL0, S_TAIL1, S_IFG, S_ABORT, S_FLUSH} 的拍。
    //   ⚠️ 与 `stat_tx_words`/`stat_tx_ctrl_char` 的**分工** (别读混): 那两个是"线上
    //     发了什么"(每拍无条件 +1 / 数控制字符); 本计数器量的是"**帧间 FSM 无事可做**
    //     的拍数" —— S_IFG/S_FLUSH **也发 /I/** 但它们属于帧的线上占用, **不算空闲**。
    //   回卷: 32 位 @156.25 MHz ⇒ 每 **27.487 s** 自然回卷 (= 与 stat_tx_words 同域同周期)。
    //   独立复算 (板级, 同窗同域): Δstat_tx_idle / Δstat_frames = **每帧 S_IDLE 拍数**
    //     (= `P − 帧内占用拍`, 其中 P = Δstat_tx_words/Δstat_frames);
    //     两量都按 mod 2³² 读 (窗口 < 27.487 s 时与直接相减等价)。
    output reg  [31:0] stat_tx_idle,
    output reg  [15:0] dbg_tx_last_clen,  // 最近一帧的**线上内容长度** (含 pad, 不含 FCS)
    output reg  [1:0]  dbg_tx_state       // 0=空闲 1=发帧 2=中止 3=冲刷
);

    // =======================================================================
    // 常量副本 —— **必须与 rtl/mac_10g_defs.vh 逐字一致** (那是带出处的溯源文本;
    // Verilog-2001 不允许 root-scope localparam, 故各 module 内自持一份)
    // =======================================================================
    localparam [7:0] XGMII_I = 8'h07;   // /I/ idle     [S1] Table 46-3
    localparam [7:0] XGMII_Q = 8'h9C;   // /Q/ sequence (仅 lane0 合法)
    localparam [7:0] XGMII_S = 8'hFB;   // /S/ start
    localparam [7:0] XGMII_T = 8'hFD;   // /T/ terminate
    localparam [7:0] XGMII_E = 8'hFE;   // /E/ error
    localparam [7:0] ETH_PRE_OCT = 8'h55;      // preamble octet
    localparam [7:0] ETH_SFD     = 8'hD5;      // <sfd> (串行位序 10101011)
    localparam [15:0] ETH_MIN_CLEN  = 16'd60;  // 内容下界 (pad 目标) [IP] mac_tx_64.v:58
    localparam [15:0] ETH_MAX_FRAME = 16'd1518;// 线上帧长上界 (含 FCS) [S1] Clause 4.4
    localparam [15:0] ETH_MAX_QTAG  = 16'd1522;// Q-tag 帧上界
    localparam [4:0]  ETH_IFG_IDLE  = 5'd12;   // /T/ 之后至少这么多个 /I/ (保守 1 字节)
    localparam [31:0] ETH_CRC_RESIDUE = 32'hDEBB20E3;  // [IP] rtl/mac_rx_64.v:96 (权威)
    // 0xC704DD7B 是 FCS 大端/非反射实现的魔数, **勿用**

    localparam [2:0] S_IDLE = 3'd0, S_PRE = 3'd1, S_DATA = 3'd2,
                     S_TAIL0 = 3'd3, S_TAIL1 = 3'd4, S_IFG = 3'd5,
                     S_ABORT = 3'd6, S_FLUSH = 3'd7;

    reg [2:0] state;

    // ---- 字 FIFO (73b = tdata+tkeep+tlast; 与 1G 版同构, 深度 16) ----
    localparam FW = 73;
    wire [FW-1:0] fdin = {s_axis_tdata, s_axis_tkeep, s_axis_tlast};
    wire [FW-1:0] fdout;
    wire          fempty, ffull;
    wire          frd;
    reg           flush_tl;      // F-2: 本帧 TLAST 已被吞掉 (停止再弹)
    wire          fwr = s_axis_tvalid && s_axis_tready;
    assign s_axis_tready = !ffull;

    fifo_sync #(.W(FW), .D(16), .AW(4)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr(fwr), .din(fdin),
        .rd(frd), .dout(fdout),
        .empty(fempty), .full(ffull),
        .dbg_wptr(), .dbg_rptr(), .dbg_full(), .dbg_empty(), .full_next(), .ovf_pulse()
    );

    // ---- 当前字 cw (= 本拍要发射的内容字) ----
    reg [63:0] cw_data;
    reg [7:0]  cw_keep;
    reg        cw_last;
    reg [3:0]  cw_len;
    reg [15:0] plen;          // 已发内容字节数 (不含本拍 cw)
    // ⭐ padrem = max(0, ETH_MIN_CLEN - plen) —— plen 的**寄存器副本** (与 plen 同拍更新)。
    //   它存在的唯一理由是**时序**: lw_ts 原来要经过 plen+cw_len (进位链) → 60-lw_L
    //   (进位链) → lw_ph (比较+选择) → cw_len+lw_ph 才出来, 而 lw_ts 又直接喂 crc_keep
    //   ⇒ 整条 plen → CRC → 尾字拼装 → PCS 的组合链在 156.25MHz 上不收敛
    //   (P7b 全设计 −0.173 / 39 失败端点; 见 notes/P7B_MAC_TIMING_FIX.md)。
    //   有它以后 lw_ts 只依赖两个**寄存器** (cw_len / padrem), 等价性证明见 lw_ts 处。
    reg [5:0]  padrem;        // 距 60B 最小帧还差的字节数 (钳 0)

    // ⭐ 弹出请求必须是**组合**的: fifo_sync 的 dout 恒等于"本拍的头字"
    //   (dout(T+1)=mem[rptr(T+1)]), 而 rd 在 T 拍为 1 时头字才在 T 沿被消费
    //   ⇒ 只有"同拍捕获 + 同拍弹出"才能一个字/拍推进。
    //   (寄存器版 frd 会晚一拍: 首字被捕获两次、整帧多一拍并丢掉 TLAST —— 实测踩过)
    assign frd = (state == S_PRE)   ? !fempty :
                 (state == S_DATA)  ? (!cw_last && (cw_len != 4'd0) && !fempty) :
                 (state == S_FLUSH) ? (!fempty && !flush_tl) : 1'b0;

    // ---- 尾部寄存器 ----
    reg [31:0] m_fcs;         // 本帧 FCS (末内容字那一拍锁存)
    reg [5:0]  m_pad_left;    // 尚需补的 pad 字节数
    reg [4:0]  m_dhere;       // S_TAIL0 本字承载的内容字节数 (只可能是 0)
    reg [4:0]  m_tptr;        // S_TAIL1 本字的尾向量起始索引
    reg [4:0]  m_idle;        // /T/ 之后已发出的 /I/ 字节数
    reg [15:0] m_clen;        // 本帧内容字节数 (含 pad)
    reg [3:0]  flush_cnt;
    wire [4:0] t1_idle = (m_tptr >= 5'd5) ? 5'd8 : (m_tptr + 5'd3);

    function [3:0] popc8;
        input [7:0] x;
        reg [3:0] c;
        integer i;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + x[i];
            popc8 = c;
        end
    endfunction

    // ---- 纯 8 字节镜像 (无位序翻转) ----
    function [63:0] bswap64;
        input [63:0] d;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1) bswap64[i*8 +: 8] = d[(7-i)*8 +: 8];
        end
    endfunction

    // ---- 尾向量取值: idx 0..3 = FCS(小端先出), 4 = /T/, >=5 = /I/ ----
    function [7:0] tl;
        input [31:0] f;
        input [4:0]  idx;
        begin
            case (idx)
                5'd0:    tl = f[7:0];
                5'd1:    tl = f[15:8];
                5'd2:    tl = f[23:16];
                5'd3:    tl = f[31:24];
                5'd4:    tl = XGMII_T;
                default: tl = XGMII_I;
            endcase
        end
    endfunction

    // ---- 合并字 (XGMII lane 序): [内容 0..dhere-1][pad 0][尾 t16] ----
    function [63:0] merge_d;
        input [63:0] content;   // 合同序 (tdata[63:56] = 首字节)
        input [4:0]  dhere;
        input [4:0]  tstart0;   // 尾部起始 lane (0..8)
        input [31:0] f;
        integer l;
        reg [7:0] b;
        begin
            merge_d = 64'd0;
            for (l = 0; l < 8; l = l + 1) begin
                if (l < dhere)             b = content[63 - 8*l -: 8];
                else if (l < tstart0)      b = 8'h00;              // pad
                else                       b = tl(f, {1'b0, l} - tstart0);
                merge_d[8*l +: 8] = b;
            end
        end
    endfunction
    function [7:0] merge_c;
        input [4:0] tstart0;
        integer l;
        begin
            merge_c = 8'h00;
            for (l = 0; l < 8; l = l + 1)
                if (l >= tstart0 + 5'd4) merge_c[l] = 1'b1;   // /T/ 及其后 = 控制字符
        end
    endfunction
    // ---- S_TAIL1 尾字: 第 l lane = tl(m_tptr + l) ----
    function [63:0] tail_d;
        input [31:0] f;
        input [4:0]  lane0;
        integer l;
        begin
            tail_d = 64'd0;
            for (l = 0; l < 8; l = l + 1) tail_d[8*l +: 8] = tl(f, lane0 + l);
        end
    endfunction
    function [7:0] tail_c;
        input [4:0] lane0;
        integer l;
        begin
            tail_c = 8'h00;
            for (l = 0; l < 8; l = l + 1) tail_c[l] = ((lane0 + l) >= 5'd4);
        end
    endfunction

    // ---- cw_data 的前 n 个 lane (合同序: lane0 = [63:56]) 置 1, 其余置 0 ----
    //   用途: 修复 DEFECT #1 后 CRC 的 keep 会把 **pad lane** 也标成有效 (pad 要进 FCS),
    //   而 crc32_64 对被 keep 标为有效的 lane 一律取 d 的值 ⇒ 必须先把 tkeep 之外的 lane
    //   (合同上可以是任意残值) 压成 0x00, 否则会把残值当 pad 喂进 CRC。
    //   n = popc(tkeep) ⇒ 对合同允许的"高位有效"输入, 该掩码与 keep 覆盖的 lane 逐位一致。
    function [63:0] cmask64;
        input [3:0] n;
        integer l;
        begin
            cmask64 = 64'd0;
            for (l = 0; l < 8; l = l + 1)
                if (l < n) cmask64[63 - 8*l -: 8] = 8'hFF;
        end
    endfunction

    // ---- 末内容字那一拍的组合量 (合并字就用它算出来的 t_start 与 fcs) ----
    wire [31:0] crc, crc_nxt;      // CRC 寄存器 / 组合下一值 (驱动器见下方 u_crc, 与发射同拍)
    wire [15:0] lw_L    = plen + {12'd0, cw_len};
    wire [5:0]  lw_pad  = (lw_L >= ETH_MIN_CLEN) ? 6'd0 : (ETH_MIN_CLEN - lw_L);
    wire [5:0]  lw_room = 6'd8 - {2'd0, cw_len};
    wire [4:0]  lw_ph   = (lw_pad > lw_room) ? lw_room[4:0] : lw_pad[4:0];   // 本字 pad 数
    wire [5:0]  lw_pr   = lw_pad - {1'b0, lw_ph};                           // 剩余 pad
    // ---- 尾起始 lane (本字内容 + 本字 pad 的字节数) -------------------------
    // ⭐ 2026-09-30 **等价化简** (P7b 时序修复; 见 notes/P7B_MAC_TIMING_FIX.md):
    //   原式 lw_ts = cw_len + lw_ph, 其中 lw_ph = min(max(0,60-plen-cw_len), 8-cw_len)
    //   ⇒ cw_len + min(60-plen-cw_len, 8-cw_len)   [当 plen+cw_len < 60]
    //     = min(60-plen, 8)
    //   ⇒ 合并两种情形 (plen+cw_len >= 60 时原式 = cw_len, 而 max(cw_len,60-plen) = cw_len):
    //        lw_ts = min(max(cw_len, padrem), 8),  padrem = max(0, 60-plen)
    //   且因 padrem ∈ [0,60]、cw_len ∈ [0,8]:
    //        * padrem > 8 ⇒ 结果恒 8        (max >= padrem > 8, 再 min 8)
    //        * padrem <= 8 ⇒ 结果 = max(cw_len, padrem) <= 8
    //   **逐位等价, 无任何行为改变** —— 只是把"两个进位链 + 比较器"换成"两个寄存器 + 比较器"。
    //   ⚠️ crc_keep / crc_d / crc_en 三行**一字未动** (变异 M11a/M11b/M11c 的锚点在那里,
    //      改动会同时废掉那三条判据的锚点; 且它们语义上本来就正确)。
    wire [4:0]  lw_ts   = (padrem > 6'd8) ? 5'd8
                        : (({1'b0, cw_len} > padrem[4:0]) ? {1'b0, cw_len} : padrem[4:0]);
    wire [31:0] lw_fcs  = crc_nxt ^ 32'hFFFFFFFF;   // 终值取反 (小端上线)

    // ---- S_TAIL0 (纯 pad 续字) 的组合量 ----
    wire [4:0]  p0_ph  = (m_pad_left > 6'd8) ? 5'd8 : m_pad_left[4:0];
    wire [4:0]  p0_room= 5'd8 - m_dhere;
    wire [4:0]  p0_use = (p0_ph > p0_room) ? p0_room : p0_ph;
    wire [4:0]  p0_ts  = m_dhere + p0_use;
    wire [5:0]  p0_rst = m_pad_left - {1'b0, p0_use};

    // ---- ⭐ CRC 挂在"本拍发射的 cw"上 (en/d/keep 与发射同拍) ----
    // ⚠️ 2026-09-30 修复 DEFECT #1 (notes/P7B_F2_CHAIN_ATTRIB.md §10):
    //   **pad 字节必须参与 FCS**。802.3 3.2.9 的 FCS 覆盖 <data> 的**全部**字节; 补 pad 后
    //   的 60B 最小帧里 pad 就属于 <data> ⇒ 只喂内容字节会让线上 FCS 与自家 RX / 任何标准
    //   对端不一致 (实测: 自家 TX 的短帧被自家 RX 判 crc_err; 10G 下所有 <60B 内容帧中招)。
    //   改法 = 把 pad 生成**并入 CRC 输入** (pad 字节 = 值 0x00 的正常数据字节, 在线上紧接
    //   内容之后; 与 crc32_64 的 lane 序 = 线上字节序同向) ⇒ 只需把 keep 扩到 pad 位置、
    //   并把 pad 位置的 d 压成 0, 就是"内容 ++ pad"的正确 CRC 输入 (新增"一套"逻辑 = 0):
    //     · S_DATA 末字: keep 由"内容"扩到"内容 + 本字 pad"(lw_ts 个字节 = 本字有效字节数),
    //       且 pad 位置的 d 强制 0 (tkeep 之外的 lane 按合同可以是任意值, 不能喂进去)
    //     · S_TAIL0 纯 pad 续字: 整字 8 个 0 值字节 (keep=8'hFF, d=0) ⇒ 寄存器推进 8 字节
    //     · S_TAIL0 尾起始字: keep = 本字 pad 字节数 ⇒ crc_nxt = M^{本字pad}·crc = 含本字
    //       pad 的最终 CRC (该字与尾向量同拍 ⇒ 必须组合, 见 p0_fcs)
    //   未变: init/en/d/keep 全部与发射同拍 (工程坑 1: 寄存器化 en 会让 CRC 与字节流错位);
    //         无终值取反 (终值取反只在写 FCS 字段时做, 见 lw_fcs/p0_fcs)
    wire        crc_init = (state == S_PRE);
    wire [7:0]  crc_keep = (state == S_TAIL0)
                           ? ((p0_rst != 6'd0) ? 8'hFF : (8'hFF << (5'd8 - p0_use)))
                           : (cw_last ? (8'hFF << (5'd8 - lw_ts)) : cw_keep);
    wire [63:0] crc_d    = (state == S_TAIL0) ? 64'd0 : (cw_data & cmask64(cw_len));
    wire        crc_en   = (state == S_DATA)  ? (cw_len != 4'd0)
                         : (state == S_TAIL0) ? 1'b1 : 1'b0;
    crc32_64 u_crc (
        .clk(clk), .rst_n(rst_n),
        .init(crc_init), .en(crc_en),
        .d(crc_d), .keep(crc_keep),
        .crc(crc), .crc_nxt(crc_nxt)
    );

    // S_TAIL0 尾起始字的 FCS: 本字 pad 已进 CRC 输入 ⇒ crc_nxt 就是"内容+全部 pad"的 CRC
    //   (纯 pad 字里 p0_fcs 是中间态, 那里 merge_d 的 tstart0=8 ⇒ 尾向量不被取用)
    wire [31:0] p0_fcs  = crc_nxt ^ 32'hFFFFFFFF;   // 终值取反 (小端上线)

    // ---- 发射 mux (组合) ----
    reg [63:0] tx_d;
    reg [7:0]  tx_c;
    always @* begin
        case (state)
            S_PRE:   begin tx_d = {ETH_SFD, ETH_PRE_OCT, ETH_PRE_OCT, ETH_PRE_OCT,
                                   ETH_PRE_OCT, ETH_PRE_OCT, ETH_PRE_OCT, XGMII_S};
                           tx_c = 8'h01; end            // 只有 lane0 是控制字符
            S_DATA:  if (cw_len == 4'd0) begin
                         tx_d = 64'h0707070707070707; tx_c = 8'hFF; end
                     else if (cw_last) begin
                         // ⭐ 末内容字 = 合并字 (内容残余 + pad + FCS + /T/ + /I/), 不额外占拍
                         tx_d = merge_d(cw_data, {1'b0, cw_len}, lw_ts, lw_fcs);
                         tx_c = merge_c(lw_ts); end
                     else begin
                         tx_d = bswap64(cw_data); tx_c = 8'h00; end
            S_TAIL0: begin tx_d = merge_d(cw_data, m_dhere, p0_ts, p0_fcs);
                           tx_c = merge_c(p0_ts); end
            S_TAIL1: begin tx_d = tail_d(m_fcs, m_tptr); tx_c = tail_c(m_tptr); end
            S_ABORT: begin tx_d = {56'h07070707070707, XGMII_T}; tx_c = 8'hFF; end
            default: begin tx_d = 64'h0707070707070707; tx_c = 8'hFF; end   // IDLE/IFG/FLUSH
        endcase
    end
    assign xgmii_txd = tx_d;
    assign xgmii_txc = tx_c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            cw_data <= 64'd0; cw_keep <= 8'd0; cw_last <= 1'b0; cw_len <= 4'd0; plen <= 16'd0;
            padrem <= ETH_MIN_CLEN[5:0];
            m_fcs <= 32'd0; m_pad_left <= 6'd0; m_dhere <= 4'd0; m_tptr <= 4'd0;
            m_idle <= 5'd0; m_clen <= 16'd0; flush_cnt <= 4'd0; flush_tl <= 1'b0;
            stat_frames <= 0; stat_abort <= 0; stat_flush_words <= 0; stat_flush_done <= 0;
            stat_tx_words <= 0; stat_tx_ctrl_char <= 0; stat_tx_short <= 0;
            stat_tx_idle <= 0;
            dbg_tx_last_clen <= 16'd0; dbg_tx_state <= 2'd0;
        end else begin
            // ---- 观测: 每个时钟发一个 XGMII 字; 控制字符数按 c 的 popcount ----
            stat_tx_words     <= stat_tx_words + 32'd1;
            stat_tx_ctrl_char <= stat_tx_ctrl_char + {28'd0, popc8(tx_c)};
            // ⭐ P7B-A7-LINE: 线占空计数 —— **本拍执行态**是 S_IDLE 才 +1 (语义逐字见端口
            //   声明处)。放在 case 之外、但用 state 的**本拍值** ⇒ 与发射 mux 是同一拍
            //   (S_IDLE 那一拍线上发的就是全 /I/), 无相位歧义。
            if (state == S_IDLE) stat_tx_idle <= stat_tx_idle + 32'd1;

            case (state)
                // ---------------------------------------------------
                S_IDLE: if (!fempty) state <= S_PRE;
                // ---------------------------------------------------
                S_PRE: begin
                    // 本拍发前导字; 同拍"捕获 + 弹出"首字 (下一拍发)
                    if (!fempty) begin
                        cw_data <= fdout[72:9];
                        cw_keep <= fdout[8:1];
                        cw_last <= fdout[0];
                        cw_len  <= popc8(fdout[8:1]);
                        plen    <= 16'd0;
                        padrem  <= ETH_MIN_CLEN[5:0];   // plen=0 ⇒ 60-plen = 60
                        state   <= S_DATA;
                    end else begin
                        state <= S_IDLE;          // 保险 (S_IDLE 已查非空)
                    end
                end
                // ---------------------------------------------------
                S_DATA: begin
                    if ((cw_len == 4'd0) || (!cw_last && (cw_keep != 8'hFF))) begin
                        // 防御: 违反源约定 (tkeep=0, 或非末字却非满对齐) ⇒ 按中止处理, 绝不发垃圾
                        state <= S_ABORT;
                        stat_abort    <= stat_abort + 32'd1;
                        stat_tx_short <= stat_tx_short + 32'd1;
                    end else if (cw_last) begin
                        // 末内容字: FCS 本拍结清 (crc_nxt 含本字**及其内 pad**), 与内容/pad
                        //   合并成同一拍发出。⚠️ 仅当 lw_pr == 0 (pad 全部落在本字) 时它才是
                        //   最终 FCS; 否则剩余 pad 在 S_TAIL0 里发出, 最终 FCS 由 p0_fcs 组合
                        //   结清并覆盖 m_fcs (中间那几拍是纯 pad 字 ⇒ 尾向量不被取用)
                        m_fcs  <= lw_fcs;
                        m_clen <= (lw_L >= ETH_MIN_CLEN) ? lw_L : ETH_MIN_CLEN;
                        if (lw_pr != 6'd0) begin
                            m_dhere    <= 4'd0;
                            m_pad_left <= lw_pr;
                            state      <= S_TAIL0;
                        end else if (lw_ts <= 5'd3) begin
                            m_idle <= 5'd3 - lw_ts;      // /T/ 已在本字里
                            state  <= S_IFG;
                        end else begin
                            m_tptr <= 5'd8 - lw_ts;      // 尾字接着发
                            m_idle <= 5'd0;
                            state  <= S_TAIL1;
                        end
                    end else if (!fempty) begin
                        // 还有下一字: 同拍捕获 + 弹出 (dout 就是本拍的头字)
                        cw_data <= fdout[72:9];
                        cw_keep <= fdout[8:1];
                        cw_last <= fdout[0];
                        cw_len  <= popc8(fdout[8:1]);
                        plen    <= plen + {12'd0, cw_len};
                        // 下一拍的 padrem = max(0, 60 - (plen+cw_len)) —— 正是本拍的 lw_pad
                        // (lw_pad 由本拍 plen/cw_len 组合算出, 与 plen 的新值同拍锁存 ⇒
                        //  两个寄存器永远描述同一个 plen, 无相位差)
                        padrem  <= lw_pad;
                    end else begin
                        // 断供 ⇒ 中止 (runt): 下一拍补一个 /T/ 把帧结掉
                        state <= S_ABORT;
                        stat_abort    <= stat_abort + 32'd1;
                        stat_tx_short <= stat_tx_short + 32'd1;
                    end
                end
                // ---------------------------------------------------
                // 纯 pad 续字 (只在 pad 超过末内容字容量时进入)
                S_TAIL0: begin
                    // FCS 在"尾起始字"上是**组合**结清的 (pad 已进 CRC ⇒ 与末内容字锁存的
                    //   m_fcs 不同, 必须用 p0_fcs; 纯 pad 字里 tstart0=8 ⇒ 该值不被取用)
                    m_fcs <= p0_fcs;
                    if (p0_rst != 6'd0) begin
                        m_dhere    <= 4'd0;
                        m_pad_left <= p0_rst;
                    end else if (p0_ts <= 5'd3) begin
                        m_idle <= 5'd3 - p0_ts;
                        state  <= S_IFG;
                    end else begin
                        m_tptr <= 5'd8 - p0_ts;
                        m_idle <= 5'd0;
                        state  <= S_TAIL1;
                    end
                end
                // ---------------------------------------------------
                // 尾字: FCS 尾 + /T/ + /I/ (一次 8 字符)
                S_TAIL1: begin
                    m_idle <= t1_idle;
                    m_tptr <= m_tptr + 4'd8;
                    state  <= S_IFG;
                end
                // ---------------------------------------------------
                // IFG: 发 idle 字直到 /T/ 之后 >= 12 个 /I/
                S_IFG: begin
                    if (m_idle + 5'd8 >= ETH_IFG_IDLE) begin
                        stat_frames      <= stat_frames + 32'd1;
                        dbg_tx_last_clen <= m_clen;
                        state <= fempty ? S_IDLE : S_PRE;   // 够 IFG 了: 可立刻发下一帧前导
                    end else begin
                        m_idle <= m_idle + 5'd8;
                    end
                end
                // ---------------------------------------------------
                // 中止结帧: 一个 [T][I]x7 字 (一个字都不再带数据)
                S_ABORT: begin
                    state <= S_FLUSH; flush_cnt <= 4'd0; flush_tl <= 1'b0;
                end
                // ---------------------------------------------------
                // F-2 冲刷 (判据与 1G 版同构: 本拍弹的正是 TLAST 字 ⇒ 同拍停请求)
                S_FLUSH: begin
                    if (flush_cnt != 4'd12) flush_cnt <= flush_cnt + 4'd1;
                    if (frd) stat_flush_words <= stat_flush_words + 32'd1;
                    if (frd && fdout[0]) flush_tl <= 1'b1;
                    if (flush_tl && (flush_cnt == 4'd12)) begin
                        state <= S_IDLE;
                        stat_flush_done <= stat_flush_done + 32'd1;
                    end
                end
                default: state <= S_IDLE;
            endcase

            dbg_tx_state <= (state == S_FLUSH) ? 2'd3 :
                            (state == S_ABORT) ? 2'd2 :
                            (state == S_IDLE)  ? 2'd0 : 2'd1;
        end
    end

endmodule
