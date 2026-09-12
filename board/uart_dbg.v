`timescale 1ns/1ps
//=============================================================================
// uart_dbg.v — P4b-7-P6 冻结态 UART 全精度读出 (板载 CH340E, 9600-8N1)
//   uart_tx_9600 : 字节串行器, 参数化每比特拍数 (默认 13021 拍 @125MHz = 9600
//                  baud, 误差 +0.002%)
//   dbg_line_tx  : 锁存后立即发一行, 之后每 ~5s 重复 (防 PC 漏读); 行内容为
//                  ASCII hex 快照, 366 字符 @9600 = ~381ms/行
//
// 行格式 (与 wrapper_p4 头注释逐字一致):
//   NX=%08X UA=%08X WN=%04X WS=%01X ST=%01X W=%d%d%d%d I=%04X E=%04X TXST=%1X RXST=%1X ACC=%d EMV=%d EST=%1X FFE=%d%dWPT=%04XRPT=%04X PF=%d TV=%d PV=%d SV=%d PLEN=%03X TW=%08X TF=%08X TI=%08X PW=%03X PR=%03X PFL=%d PEM=%d PLN=%03X RXPL=%04X RXPC=%04X RXT=%04X DROPS=%08X/%08X/%08X/%08X PASS=%08X RXTR=%d MW=%08X CW=%08X/%08X RW=%08X WC=%d WL=%04X\r\n
//   NX = snd_nxt0   UA = snd_una0   WN = snd_wnd0    (32/32/16 位 hex)
//   WS = wscale0    ST = tcb state0                  (4 位 hex, 各 1 位)
//   W  = latch_val 4 位逐位 '0'/'1': {wnd_open, 1'b0(was hi_eq), (eff==0), (inf>=eff)}
//        (bit2 占位 — P6 的 win_hi_eq 已随 64K 边界误关修复废除)
//   I  = win_inflight[15:0]   E  = win_wnd_eff[15:0]
//   TXST = tcp_tx_frame FSM state[2:0] (每行开始重采 — FSM 是否停在非法态 /
//          是否仍循环是冻结诊断的关键数据点)
//   RXST = tcp_rx FSM state[2:0]  (每行开始重采 — 冻结位点: 是否停在 S_PAY 中段)
//   ACC  = tcp_rx 接受拍 tvalid&&tready  ('0'/'1'; 冻结后应恒 0)
//   EMV  = tcp_rx emit_v                  ('0'/'1'; 载荷输出字是否挂起)
//   EST  = tcp_echo FSM state[1:0]        (每行开始重采)
//   FFE  = echo frame_fifo {full, empty} 逐位 '0'/'1'
//   WPT/RPT = echo frame_fifo wptr/rptr[12:0] (P4c AW=13; 值域 0..1FFF 需 4 位
//             hex — 字段仍 8 字符 101..108/109..116, 无前导分隔空格, 与 FFE 的
//             末位字符直接相邻; 差值 mod 8192 ≈ 已占用字数)
//   PF   = tcp_tx_frame 载荷 FIFO 满 pay_full     (S_RECV 停吞位点诊断)
//   TV   = tcp_tx_frame s_axis_tvalid             (帧器输入侧活请求)
//   PV   = u_eco_pipe m_valid  SV = u_eco_pipe s_valid (echo→tx 握手链;
//          lost-tlast 时: SV=1 PV=0 表示 echo 已吐完、pipe 被帧器吞住)
//   PLEN = tcp_tx_frame plen_r[11:0] (S_RECV 已累计字节, 冻结恒值)
//   PW/PR = tcp_tx_frame u_fifo (载荷 FIFO) wptr/rptr[8:0] 每行行首重采 —
//          (wptr-rptr) 低 8 位掩码 = 实际占用字数; 与 PLN/PLEN 对账判 PF 报满是
//          真满 (占用=256) 还是指针/绕回异常 (单帧仅 183 字却报满)
//   PFL/PEM = u_fifo {full, empty} 逐位 '0'/'1' (端口直出, 与 PF 同源)
//   PLN  = tcp_tx_frame RUNNING plen[11:0] (帧内累计, 未锁存; 区别于 PLEN)
//   TW   = tcp_echo stat_tlast_wr  (帧末拍写入 echo frame_fifo 次数)
//   TF   = tcp_echo stat_tlast_fwd (帧末拍从 echo frame_fifo 转发次数)
//   TI   = tcp_tx_frame stat_tlast_in (帧器吞到帧末拍次数)
//          P4b-7-P6 tlast 定位: 期望三值同步增长; TW>TF => 死在 echo FIFO;
//          TW==TF>TI => 死在 echo→帧器 (fifo 读出/axis_pipe/接受拍);
//          TI 跟 TW 同步 => tlast 已到帧器, 冻结另有其因 (S_RECV 停吞)。
//   RXPL = tcp_rx plen_l        帧判读锁存 (IP total_len-40; 被腐败则
//          over-length 守卫在帧中段转 S_DROP 断尾 → TX 永久等 tlast)
//   RXPC = tcp_rx pcount        帧内已累计载荷字 (与 RXPL 对账断尾位点)
//   RXT  = tcp_rx w2_r[63:48]   原始 IP total_len 字段 (plen_l 上游真值:
//          RXT 正常而 RXPL 异常 => 减法/锁存链错; RXT 自身异常 => 头字错位)
//   DROPS = tcp_rx stat_drop_seq/crc/nonmatch/ipcsum (每行重采; 冻结期哪一路
//          在递增 = 该判据持续触发: nonmatch 随帧速率涨 => over-length 守卫)
//   PASS = tcp_rx stat_pass
//   RXTR = rx_trace_frozen (P4b-7-P6 RX-TRACE 冻结标志: 1 = RX 帧尾计数异常环
//          已锁存, 本轮必附 4 行 RXT; 0 = 未触发, 无 RXT 行)
//   WL   = rx_wire_last (P4b-7-P6-P6b **线上帧长** = 异常触发帧的线上字节数,
//          与 RXTR 同一触发拍锁存; 计数在 phy1_rxc 域 (RGMII RX_CTL 高电平
//          拍数 x8 = 线上字节数), 经 2 级同步到本域, 每行行首重采) —
//          判别器: WL≈0042 (66) = PC/NIC 真发 66 字节短帧 (PC 侧);
//          WL≈05EA (1514) = 线上整帧, 中段字节被 RGMII 桥/mac_rx 吞掉 (FPGA 侧)。
//          未触发时为 0; 含前导/SFD 时 ≈帧长+8 (不去偏)。
//          注: 逐位 2-FF 同步, 采样抖动 ≤1 gmii 拍 (值每帧只变一次, 无影响)
//   P4b-7-P6 三站词计数 (行尾追加, 每行行首重采 — 丢词站裁决):
//     MW = mac_rx_64 dbg_stat_words_out (发出 m_axis 字, tvalid&&tready)
//     CW = rx_classify dbg_stat_words_in / dbg_stat_words_out (接受 s_axis 字 /
//          发出 fast 路字)   RW = tcp_rx dbg_stat_words_in (接受 s_axis 字)
//     WC = tcp_rx wcnt (头字计数器 0..7; 与 RXT 条目 [26:24] 同源)
//     三站差额裁决 (触发帧): MW-CWin = 滞压未消费词; CWout-RW = classify→RX
//     在途/被丢词。MW/CW 计数到 9 位 hex 会截断, 定宽 8 位 hex 与 DROPS 同法。
//   以上 RXST..WC (含 RXPL/RXPC/RXT/DROPS/PASS/MW/CW/RW/WC/WL) 与 TXST 同语义:
//   每行开始一次重采, 行内不变。CR LF 收尾。计数类 (DROPS/PASS/MW/CW/RW)
//   为 8 位 hex 定宽 — 32 位十进制定宽需 10 位/字段, 行宽与时序代价不值,
//   值本身精确无损 (本行 443 字符 + CR LF = 445; SNAP_M1 = 444)。
//
// P4b-7-P6 TRACE 追加 (快照行之后, 仅 tr_run=trace_frozen 时发, 共 4 行):
//   TR=%06X %06X %06X %06X %06X %06X %06X %06X %06X %06X %06X %06X %06X %06X
//      %06X %06X
//   每行 = "TR=" + 16 字 × "%06X " (字后恒带空格, 位宽固定 7 字符) + CR LF
//   = 117 字符/行 (0..114 正文, 115=CR 116=LF); 4 行共 64 字 = 环全量。
//   字序 = 环时间序, 字 g (0..63) 的环址 = (trace_wptr - 63 + g) & 63:
//   trace_wptr = 冻结停写的下一写址 = 环内最老条目址, 故
//     g = 0..62 → 冻结前 63..1 拍 (由旧到新), g = 63 → 冻结前 64 拍 (环内
//     最老, 无写入即被覆盖) — 64 字全为有效样本, 时间回卷点落在末字 (g=62
//     为最新拍, g=63 为最老拍, 读时间轴时注意)。
//   行 lno (1..4) 的字 tid (0..15) → g = (lno-1)*16 + tid。
//   每字 24 位 = wrapper trace_entry 原位 (位布局见 wrapper_p4.v trace_mem 注释):
//     [23:21] tx FSM state   [20] pipe_mv      [19] pipe_sv   [18] tx tvalid
//     [17] tx tready         [16] echo m_axis_tlast (pipe 前) [15] tx accept
//     [14:0] echo frame_fifo 占用 (wptr-rptr)
//   板级读法: 冻结点 (S_RECV 堵死 1000 拍) 锁存后 UART 每轮 = 快照行 + 4 TR 行
//   (~803ms/轮 @9600), 每 ~5s 重复; PC 端按 %06X 解析, 按上式还原时间轴。
//   tr_run=0 时只发快照行 (无 TR 行, 行序与旧版逐字节一致)。
//
// P4b-7-P6 TL 追加 (TR 行之后, 仅 run 时发, 共 8 行 — 帧 FIFO 边存 tlast 位图):
//   TL=%02X%02X%02X%02X%02X%02X%02X%02X\r\n     (21 字符/行, 8 行)
//   行 k (lno = 5+k, k=0..7) 第 j 字节 (j=0..7) = 边存址 (rptr-32+8k+j) & (D-1)
//   的 tlast 位, 按 %02X 打印 (故字节值恒 00/01 — 一个字节一个槽, 地址顺序,
//   无位序歧义): 行 k 覆盖 rptr-32+8k .. rptr-32+8k+7, 8 行覆盖 rptr-32..rptr+31
//   (64 槽)。基址 rptr 在 TL 段起始拍 (快照行末 或 TR4 行末) 锁存, 与快照行同点。
//   读出路径 = dbg_rd_addr/dbg_rd_side (frame_fifo 边存 LUTRAM 组合读口, 见
//   rtl/frame_fifo.v P6c): TL 段起始拍起 64 拍逐拍读 1 址, 位 g 入 tl_bits[g]。
//   板级读法: 冻结点前后回显帧的 tlast 落在哪些槽 (期望每帧 1 个 = 帧长间隔处
//   的孤立 1; 冻结帧的 tlast 缺失/错位 = 该帧被回卷或被覆盖; 位图可精确到槽)。
//   行序: run=1&tr_run=1 → 快照 + 4 TR + 8 TL; run=1&tr_run=0 → 快照 + 8 TL;
//   run=0&tr_run=1 → 4 TR (无 TL: 无锁存拍即无 rptr 基准)。
//
// P4b-7-P6 RX-TRACE 追加 (TL 行之后, 仅 rxt_run 时发, 共 4 行 — RX 帧尾计数环):
//   RXT=%07X %07X ... 每行 = "RXT=" + 16 字 × "%07X " + CR LF (134 字符/行,
//   0..131 正文, 132=CR 133=LF), 4 行 = 64 字环全量。
//   字序/环址语义同 TR 行 (见上): 字 g (0..63) 的环址 = (rxt_wptr-63+g)&63,
//   g=62 为最新 (触发拍), g=63 = 环内最老; 行 lno (13..16) 的 tid (0..15) →
//   g = (lno-13)*16 + tid。每字 27 位 = wrapper rx_trace_entry 原位:
//     [26:24] wcnt (头字计数器, 每字最高位 hex 数字)  [23] pad
//     [22:20] rx FSM state  [19] emit_v  [18] emit_l  [17] accept
//     [16] echo tready (!frame_fifo full = tcp_rx 下游 tready)
//     [15:12] pay_r[3:0]    [11:0] pcount[11:0]
//   27 位按 7 位 hex 转储: 第 1 个 hex 数字 = {1'b0, wd[26:24]} (3 位 wcnt
//   零扩展), 余 6 数字 = wd[23:0] 逐 nibble — 与 %07X 语义一致。
//   板级读法: 触发 = fend 拍 pcount < plen_l-4 (帧尾 ≥5 载荷字节未入账) 一次性
//   锁存 → 环内 = 触发拍及前 63 拍 RX 逐拍状态; pcount 每 S_PAY 拍 +8, 正常
//   1460B 帧 fend 拍 = plen_l-2 → 从哪拍起 pcount 停滞/跳变 = pay_r 变大源头
//   = 尾分支误走 S_TAIL (emit_l=0, 帧边界丢失 → 与下帧合并) 的确证。
//   行序 (含 RXT): run=1 → 快照 (+4 TR) + 8 TL (+4 RXT); run=0&tr_run=1 →
//   4 TR (+4 RXT); run=0&tr_run=0&rxt_run=1 → 直发 4 RXT。
//   RXTR 标志 (快照行尾) = 行首重采的 rxt_run, 冻结后恒 1 — 保证 RXT 行有数据。
//
// P4b-7-P6-P6b WL 追加 (快照行**最末**字段, 紧接 WC=%d 之后, 8 字符):
//   WL=%04X = 异常触发帧的线上字节数 (wrapper_p4: phy1_rxc 域计 RGMII RX_CTL
//   高电平拍数 x8, RX_CTL 落沿锁存整帧; 触发拍 (rx_trace_rewind) 经 2 级同步
//   锁入 wire_last_lat → 本模块 rx_wire_last, 每行行首重采 = wl_l)。
//   判别「62 字节去哪了」: WL≈0042 (66) = PC/NIC 真发 66 字节短帧 (PC 侧);
//   WL≈05EA (1514) = 线上整帧而 mac_rx/classify/tcp_rx 只入账 62 字节
//   (FPGA 侧丢词, 配合 MW/CW/RW 三站计数定位)。未触发恒 0。
//   行宽: 358 → 366 字符 (WL 追加); 其后 diag18 (SC/SD/SF/SP/SV/HR) + TRU 追加
//   至 443 字符 (CR 在 443, LF 在 444), SNAP_M1 = 444。
//=============================================================================

//-------------------------------------------------------------------------
// uart_tx_9600: 8N1 字节发送器 (电平握手: !busy 期间 tx_go 高即取 byte_in)
// 帧 = 10 位: start(0) d0..d7 stop(1), 每位 BIT_LAST+1 拍; 空闲线高。
//-------------------------------------------------------------------------
module uart_tx_9600 #(
    parameter [13:0] BIT_LAST = 14'd13020      // 每比特拍数-1 (125MHz@9600)
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] byte_in,
    input  wire       tx_go,          // !busy 期间拉高 1 拍即取字节发送
    output wire       txd,
    output reg        busy
);
    reg [13:0] cnt;                   // 位内计数 0..BIT_LAST
    reg [3:0]  bcnt;                  // 已发位号 0..9 (0=start 已发)
    reg [9:0]  fr;                    // {stop,d7..d0,start} 右移帧, txd=fr[0]

    assign txd = fr[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 14'd0; bcnt <= 4'd0;
            fr  <= 10'h3FF;           // 空闲高电平
            busy <= 1'b0;
        end else if (busy) begin
            if (cnt == BIT_LAST) begin
                cnt <= 14'd0;
                if (bcnt == 4'd9) begin        // stop 位全周期发完
                    busy <= 1'b0;
                    bcnt <= 4'd0;
                end else begin
                    bcnt <= bcnt + 4'd1;
                    fr   <= {1'b1, fr[9:1]};
                end
            end else begin
                cnt <= cnt + 14'd1;
            end
        end else if (tx_go) begin
            busy <= 1'b1;
            cnt  <= 14'd0;
            bcnt <= 4'd0;
            fr   <= {1'b1, byte_in, 1'b0};     // 同拍 fr[0]=0 出 start 沿
        end
    end
endmodule

//-------------------------------------------------------------------------
// dbg_line_tx: run/tr_run 锁存后立即发首行, 行间 GAP_LAST+1 拍重复; 全组合
// 字符 mux (line_char) 由 ci/lno 与快照/环数据生成, 发送节奏由 uart busy 握手。
//   一轮 = 5 行 (S_IDLE 起 / S_GAP 到期回 S_IDLE):
//     行 0   = 快照行   (303 字符; 仅 run 时发)
//     行 1..4= TR 行    (117 字符; 仅 tr_run 时发, 每行 16 字 = 环内 16 条)
//   run=1/tr_run=0 → 只发行 0 (与旧版逐字节一致); run=0/tr_run=1 → 跳过行 0
//   直发 4 行 TR (冻结早于 RTO 回卷锁存时也能读出环)。
//   TR 字数据经 tr_word 预取寄存器 (字末空格前 1 字符处取下一字号, 行首取
//   tid=0) — 把 64:1 环 mux 从字符组合路径上摘掉, 见 line_char/tr_char。
//-------------------------------------------------------------------------
module dbg_line_tx #(
    parameter [13:0] BIT_LAST = 14'd13020,           // 每比特拍数-1 @125MHz
    parameter [29:0] GAP_LAST = 30'd624_999_999      // 行间 5s-1 @125MHz
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        run,             // 冻结锁存电平 (1 = 发首行并周期重复)
    input  wire [31:0] snd_nxt,         // 冻结拍快照: TCB conn0 snd_nxt
    input  wire [31:0] snd_una,         // 冻结拍快照: TCB conn0 snd_una
    input  wire [15:0] snd_wnd,         // 冻结拍快照: TCB conn0 snd_wnd
    input  wire [3:0]  wscale,          // 冻结拍快照: conn0 wscale
    input  wire [3:0]  tcb_state,       // 冻结拍快照: conn0 tcb state
    input  wire [3:0]  latch_val,       // {wnd_open, 1'b0(was hi_eq), eff==0, inf>=eff}
    input  wire [15:0] win_inflight,    // 冻结拍快照
    input  wire [15:0] win_wnd_eff,     // 冻结拍快照
    input  wire [2:0]  tx_state,        // 实时 tx FSM state (每行重采)
    input  wire [2:0]  rx_state,        // 实时 tcp_rx FSM state (每行重采)
    input  wire        rx_accept,       // 实时 tcp_rx accept (tvalid&&tready)
    input  wire        rx_emitv,        // 实时 tcp_rx emit_v
    input  wire [2:0]  echo_state,      // 实时 tcp_echo FSM state (每行重采)
    input  wire        fifo_full,       // 实时 echo frame_fifo full
    input  wire        fifo_empty,      // 实时 echo frame_fifo empty
    input  wire [12:0] fifo_wptr,       // 实时 echo frame_fifo wptr[12:0] (P4c AW=13)
    input  wire [12:0] fifo_rptr,       // 实时 echo frame_fifo rptr[12:0] (P4c AW=13)
    input  wire        tx_pay_full,     // 实时 tcp_tx_frame 载荷 FIFO 满 (每行重采)
    input  wire        tx_saxis_tv,     // 实时 tcp_tx_frame s_axis_tvalid
    input  wire        pipe_mv,         // 实时 u_eco_pipe m_valid
    input  wire        pipe_sv,         // 实时 u_eco_pipe s_valid
    input  wire [11:0] tx_plen_r,       // 实时 tcp_tx_frame plen_r
    // P4b-7-P6: tx 载荷 FIFO (u_fifo) 指针/标志 + RUNNING plen (每行行首重采)
    //   pay_wptr/rptr = u_fifo wptr/rptr[8:0] (差值低 8 位 = 实际占用字数)
    //   pay_full2/pay_empty = u_fifo full/empty (端口直出; full 与 tx_pay_full 同源)
    //   tx_plen = tcp_tx_frame RUNNING plen[11:0] (帧内累计, 未锁存)
    input  wire [8:0]  pay_wptr,
    input  wire [8:0]  pay_rptr,
    input  wire        pay_full2,
    input  wire        pay_empty,
    input  wire [11:0] tx_plen,
    // P4b-7-P6 tlast 三计数 (每行行首重采; 与 TXST/PLEN 同语义):
    //   TW = tcp_echo stat_tlast_wr  (帧末拍写入 echo frame_fifo)
    //   TF = tcp_echo stat_tlast_fwd (帧末拍从 echo frame_fifo 转发)
    //   TI = tcp_tx_frame stat_tlast_in (帧器吞到帧末拍)
    // 对账法: TW>TF => tlast 死在 echo frame_fifo (写入有 / 转发无);
    //         TW==TF>TI => 死在 echo→帧器链路 (fifo 读出 / axis_pipe / 接受拍)
    input  wire [31:0] tlast_wr,
    input  wire [31:0] tlast_fwd,
    input  wire [31:0] tlast_in,
    // P4b-7-P6 追加 (UART 行尾 RXPL/RXPC/RXT/DROPS/PASS): RX 侧帧判读锁存 +
    //   原始 total_len + 五路丢弃/通过计数 (每行行首重采, 语义同 RXST/ACC/EMV)
    input  wire [15:0] rx_plen_l,       // tcp_rx plen_l   (锁存的 IP total_len-40)
    input  wire [15:0] rx_pcount,       // tcp_rx pcount   (帧内已累计载荷字)
    input  wire [15:0] rx_w2_tlen,      // tcp_rx w2_r[63:48] (原始 total_len 字段)
    input  wire [31:0] rx_drop_seq,     // tcp_rx stat_drop_seq
    input  wire [31:0] rx_drop_crc,     // tcp_rx stat_drop_crc
    input  wire [31:0] rx_drop_nonmatch,// tcp_rx stat_drop_nonmatch (over-length 守卫计此路)
    input  wire [31:0] rx_drop_ipcsum,  // tcp_rx stat_drop_ipcsum
    input  wire [31:0] rx_drop_trunc,   // tcp_rx stat_drop_trunc (P4b-7-P6 trunc 修复计数, 行尾 TRU)
    input  wire [31:0] rx_pass,         // tcp_rx stat_pass
    // P4b-7-P6 三站词计数 (行尾 MW/CW/RW/WC, 每行行首重采 — 丢词站裁决):
    //   mac_words_out = mac_rx_64 发出字; cls_words_in/out = rx_classify 进/出字;
    //   rx_words_in = tcp_rx 接受字 (全部含头字); rx_wcnt = tcp_rx 头字计数器。
    input  wire [31:0] mac_words_out,   // MW
    input  wire [31:0] cls_words_in,    // CW 前值 (classify 进)
    input  wire [31:0] cls_words_out,   // CW 后值 (classify 出, fast 路)
    input  wire [31:0] rx_words_in,     // RW
    input  wire [2:0]  rx_wcnt,         // WC
    // P4b-7-P6 TRACE 转储 (wrapper_p4 trace_mem 直出):
    //   trace_ring = 64 x 24b 环展平 (条目 addr 占 [24*addr +: 24])
    //   trace_wptr = 环下一写址 (冻结后停写恒值 = 环内最老条目址)
    //   tr_run     = trace_frozen (S_RECV 堵死 1000 拍一次性锁存)
    input  wire [1535:0] trace_ring,
    input  wire [5:0]    trace_wptr,
    input  wire          tr_run,
    // P4b-7-P6 RX-TRACE 转储 (wrapper_p4 rx_trace_mem 直出; 行序 = TL 行之后):
    //   rxt_ring = RX 侧 64 x 27b 环展平 (条目 addr 占 [27*addr +: 27]);
    //   rxt_wptr = 环下一写址 (冻结后停写恒值 = 环内最老条目址);
    //   rxt_run  = rx_trace_frozen (帧尾计数异常 sticky 一次性锁存; 也是快照行
    //              尾 RXTR=%d 标志源 — 1 = RX 环已冻结, RXT 行才有数据)。
    //   条目位布局 (见 wrapper_p4 rx_trace_mem 注释; 每字按 7 位 hex 转储,
    //   最高位 hex 数字 = wcnt):
    //     [26:24] wcnt [23] pad [22:20] rx FSM state [19] emit_v [18] emit_l
    //     [17] accept [16] echo tready (!fifo_full) [15:12] pay_r[3:0]
    //     [11:0] pcount[11:0]
    input  wire [1727:0] rxt_ring,
    input  wire [5:0]    rxt_wptr,
    input  wire          rxt_run,
    // P4b-7-P6-P6b 线上帧长 (快照行末 WL=%04X 字段源):
    //   rx_wire_last = 异常触发拍锁存的线上帧字节数 (wrapper_p4 wire_last_lat —
    //   phy1_rxc 域 RGMII RX_CTL 高电平拍数 x8, 触发拍经 2 级同步锁存)。
    //   判别 66 字节短帧 (PC 侧) vs 1514 字节整帧被吞 (FPGA 侧); 每行行首重采。
    input  wire [15:0]   rx_wire_last,
    // diag18 慢路径/HLS 存活字段 (每行行首重采):
    //   srx_commit = slow_rx_adp 提交帧数 (RX→HLS 交付证明)
    //   srx_drop   = slow_rx_adp 丢弃帧数 (坏 FCS/rx_er/满)
    //   stx_frames = slow_tx_adp 发出帧数 (HLS 自发行文/应答 — 活着应 ~5s +1)
    //   stx_purge  = slow_tx_adp purge 数
    //   starv      = slow_rx_adp 看门狗饥饿累计 (周期归 0 = 看门狗循环)
    //   hls_rst    = hls_rst_n 实时 (0 = HLS 正在复位)
    input  wire [31:0]   srx_commit,
    input  wire [31:0]   srx_drop,
    input  wire [31:0]   stx_frames,
    input  wire [31:0]   stx_purge,
    input  wire [21:0]   starv,
    input  wire          hls_rst,
    // P4b-7-P6 TL: 帧 FIFO 边存 tlast 位图转储 (快照/TR 行之后 8 行, 仅 run 时发):
    //   dbg_rd_addr = 本拍边存读址 (TL 读引擎驱动), dbg_rd_side[8] = 该址 tlast;
    //   行 k 字节 j 打印址 (rptr-32+8k+j) 的 tlast (00/01), 基址 TL 段首拍锁存。
    //   见头注释 TL 段; 上游 = frame_fifo dbg_rd_addr/dbg_rd_side 组合读口。
    output wire [12:0]   dbg_rd_addr,
    input  wire [8:0]    dbg_rd_side,
    output wire          txd
);
    localparam [8:0] SNAP_M1 = 9'd444;  // 快照行末字符号 (0..443: 443 打印 + CR LF; diag18 +64, TRU +1)
    localparam [8:0] TR_M1   = 9'd116;  // TR 行末字符号 (0..116: "TR=" + 16*7 + CR LF)
    localparam [8:0] TL_M1   = 9'd20;   // TL 行末字符号 (0..20: "TL=" + 16 hex + CR LF)
    localparam [8:0] RXT_M1  = 9'd133;  // RXT 行末字符号 (0..133: "RXT=" + 16*8 + CR LF)
    localparam [1:0] S_IDLE  = 2'd0, S_CH = 2'd1, S_GAP = 2'd2;

    reg [1:0]  st;
    reg [8:0]  ci;                      // 9 位: 行宽 360 > 255
    reg [7:0]  cur;                     // 当前待发字节
    reg [29:0] gap;
    reg [4:0]  lno;                     // 行号: 0=快照行, 1..4=TR 行, 5..12=TL 行,
                                        //       13..16=RXT 行 (5 位 — RXT 行到 16)
    reg [3:0]  tid;                     // TR 行内字号 0..15
    reg [2:0]  tph;                     // TR 行内字内相 0..6 (0..5=hex 位, 6=空格);
                                        //   RXT 行 0..7 (0..6=hex 位, 7=空格)
    reg [23:0] tr_word;                 // TR 行字号 24 位条目 (行内预取, 拆 mux)
    reg [26:0] rxt_word;                // RXT 行字号 27 位条目 (同上, RX 环)
    reg        rxt_l;                   // 行起始拍 rxt_run 快照 (快照行 RXTR 位)
    reg [2:0]  ts_l;                    // 行起始拍的 tx_state 快照 (全行一致)
    reg [2:0]  rxs_l;                   // 行起始拍 tcp_rx state 快照
    reg        acc_l, emv_l;            // 行起始拍 accept / emit_v 快照
    reg [2:0]  est_l;                   // 行起始拍 tcp_echo state 快照
    reg        ffl_l, fel_l;            // 行起始拍 fifo full/empty 快照
    reg [12:0] wpt_l, rpt_l;            // 行起始拍 fifo wptr/rptr 快照 (P4c AW=13)
    reg        pf_l, tv_l, pv_l, sv_l;  // 行起始拍 tx 握手链快照 (P4b-7-P6)
    reg [11:0] plen_l;                  // 行起始拍 tcp_tx_frame plen_r 快照
    reg [31:0] tw_l, tf_l, ti_l;        // 行起始拍 tlast 三计数快照 (P4b-7-P6)
    reg [8:0]  pw_l, pr_l;              // 行起始拍 u_fifo wptr/rptr[8:0] 快照
    reg        pfl_l, pem_l;            // 行起始拍 u_fifo full/empty 快照
    reg [11:0] pln_l;                   // 行起始拍 RUNNING plen 快照
    reg [15:0] rpl_l, rpc_l, rwt_l;     // 行起始拍 tcp_rx {plen_l,pcount,w2_tlen}
    reg [31:0] dsq_l, dcr_l, dnm_l, dip_l, pss_l;  // 行起始拍 rx 五路计数快照
    // P4b-7-P6 三站词计数快照 (行尾 MW/CW/RW/WC)
    reg [31:0] mw_l, cwi_l, cwo_l, rw_l;
    reg [2:0]  wc_l;                    // tcp_rx wcnt 快照
    reg [15:0] wl_l;                    // P4b-7-P6-P6b 线上帧长快照 (WL 字段)
    // diag18 慢路径/HLS 存活字段快照 (行尾 SC/SD/SF/SP/SV/HR)
    reg [31:0] sc_l, sd_l, sf_l, sp_l;
    reg [21:0] srv_l;
    reg        hr_l;
    reg [31:0] tru_l;                   // P4b-7-P6 trunc 计数快照 (行尾 TRU)
    reg [63:0] tl_bits;                 // P4b-7-P6 TL: 64 址 tlast 位图 (位 g)
    reg [12:0] tl_base;                 // TL 基址 = TL 段首拍 rptr - 32 (13 位回卷)
    reg [5:0]  tl_g;                    // TL 读引擎址偏移 0..63 (每拍 +1)
    reg        tl_run;                  // TL 读引擎忙 (64 拍)
    wire       ubusy;
    wire       ugo = (st == S_CH) && !ubusy;

    // ---- TR 行地址/预取 (全 6 位加法, 自然 mod 64) ----
    // g(tid) = (lno-1)*16 + tid; 环址 = trace_wptr - 63 + g = trace_wptr + 1 + g
    //   tr_off  = (lno-1)*16 (当前行 g 偏移)   tr_offn = 下一行 (lno+1) g 偏移
    //   预取时机 (见 always): 行首取 tid=0; 行内 tph == 末 hex 位相时取 tid+1
    //   (先取后 wrap: 该拍发出的字符是分隔空格, 紧接着 wrap 到下一字首 hex 位)
    wire [8:0] nl_m1   = (lno == 4'd0) ? SNAP_M1 :
                         ((lno >= 4'd13) ? RXT_M1 :
                          ((lno >= 4'd5) ? TL_M1 : TR_M1)); // 当前行末字符号
    wire [4:0] lno_n   = (lno == 5'd0) ? (tr_run ? 5'd1 : 5'd5)
                                      : (lno + 5'd1);       // 下一行号
    // P4b-7-P6: RXT 字 = 7 hex + 空格 (tph 0..7), TR 字 = 6 hex + 空格 (0..6) —
    //   末相与预取相按段选择 (RXT 段 7/6, TR 段 6/5)
    wire [2:0] f_last  = (lno >= 4'd13) ? 3'd7 : 3'd6;      // 字内末相 (分隔空格)
    wire [2:0] f_pre   = (lno >= 4'd13) ? 3'd6 : 3'd5;      // 预取相 (末 hex 位)
    // 行首相位 hold: TR 行前缀 3 字符 → hold 0 (pos3 起 ph=0); RXT 行前缀 4
    // 字符 → hold 7 (ci==3 时 7+1 自然回绕 0, 使 pos4 起 ph 与 pos 严格对齐)
    // 注意: RXT 段 hold 相 7 与 f_last 同值 → ci==3 释放拍会误判"字末"多增一次
    //   tid (整行字址 +1, 首字仍对而后续字全部错位) → 前缀区 ci<=3 一律保持
    //   tid=0 (TR 段 ci==3 的 tph 为 1, 本就不增, 故合并门控无损)
    wire [3:0] tid_n   = (ci <= 9'd3) ? 4'd0 :
                         ((tph == f_last) ? (tid + 4'd1) : tid);  // 下一字符字号
    wire [2:0] tph_n   = (ci <= 9'd2) ? ((lno >= 4'd13) ? 3'd7 : 3'd0) :
                         ((tph == f_last) ? 3'd0 : (tph + 3'd1)); // 下一字符相
    wire [5:0] tr_off  = {lno[1:0], 4'b0} - 6'd16;          // (lno-1)*16
    wire [5:0] tr_offn = {lno_n[1:0], 4'b0} - 6'd16;        // (lno_n-1)*16
    wire [5:0] tr_tid1 = {2'b0, tid} + 6'd1;                // tid+1 (预取字号)
    wire [5:0] tr_rap  = trace_wptr + 6'd1 + tr_off + tr_tid1;  // 行内预取址
    wire [5:0] tr_ran  = trace_wptr + 6'd1 + tr_offn;           // 行首预取址 (tid=0)
    wire [23:0] tr_wpre = trace_ring[tr_rap * 24 +: 24];
    wire [23:0] tr_wnew = trace_ring[tr_ran * 24 +: 24];

    // ---- RXT 行地址/预取 (镜像 TR 机制, 环 = rx_trace_mem/rxt_wptr) ----
    // 行 lno (13..16) → 组号 k = lno-13 (0..3); g(tid) = k*16 + tid; 环址 =
    // rxt_wptr - 63 + g = rxt_wptr + 1 + g。tr_off/tr_offn 是"下一行的组偏移"
    // 通用式 ({lno[1:0],4'b0}-16): TR 段 (lno 1..4) 与 RXT 段 (13..16) 的
    // lno[1:0] 相位同构 (1,2,3,0), 故同一表达式对两段都成立, 直接复用。
    wire [5:0]  rxt_rap  = rxt_wptr + 6'd1 + tr_off + tr_tid1;  // 行内预取址
    wire [5:0]  rxt_ran  = rxt_wptr + 6'd1 + tr_offn;           // 行首预取址
    wire [26:0] rxt_wpre = rxt_ring[rxt_rap * 27 +: 27];
    wire [26:0] rxt_wnew = rxt_ring[rxt_ran * 27 +: 27];

    // ---- P4b-7-P6 TL: 边存 tlast 位图转储 (行 5..12, 64 址 x 1 位) ----
    // 进入 TL 段的拍 (快照行末 或 TR4 行末; 本行 LF 已入 uart) 锁 rptr 起读引擎:
    // 之后 64 拍逐拍读 1 址, dbg_rd_side[8] (tlast) 入 tl_bits[g]。址 = tl_base+tl_g
    // (13 位自然回卷 = mod 8192 = 边存槽数, P4c AW=13)。读引擎 64 拍 << 首字节所需 3*10 位
    // 时间 (行首 'T','L','=' 三字符 = ~390k 拍 @125M/9600), 故首 hex 前必就绪。
    // 边存 = LUTRAM 组合读, 冻结期内容静态; 逐拍步址无收敛风险。
    wire tl_enter = (st == S_CH) && !ubusy && (ci == nl_m1) &&
                    (((lno == 4'd0) && !tr_run) || ((lno == 4'd4) && run));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tl_bits <= 64'd0; tl_base <= 13'd0; tl_g <= 6'd0; tl_run <= 1'b0;
        end else if (tl_enter) begin
            tl_base <= fifo_rptr - 13'd32;      // 基址 = rptr-32 (13 位回卷, 锁存拍实时值)
            tl_g    <= 6'd0;
            tl_run  <= 1'b1;
        end else if (tl_run) begin
            tl_bits[tl_g] <= dbg_rd_side[8];    // 位 g = 址 (base+g) 的 tlast
            tl_g <= tl_g + 6'd1;
            if (tl_g == 6'd63) tl_run <= 1'b0;
        end
    end
    assign dbg_rd_addr = tl_base + tl_g;

    uart_tx_9600 #(.BIT_LAST(BIT_LAST)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .byte_in(cur), .tx_go(ugo),
        .txd(txd), .busy(ubusy)
    );

    // 4 位 hex → ASCII
    function [7:0] hexc;
        input [3:0] n;
        begin
            case (n)
                4'd0: hexc = 8'h30; 4'd1: hexc = 8'h31; 4'd2: hexc = 8'h32;
                4'd3: hexc = 8'h33; 4'd4: hexc = 8'h34; 4'd5: hexc = 8'h35;
                4'd6: hexc = 8'h36; 4'd7: hexc = 8'h37; 4'd8: hexc = 8'h38;
                4'd9: hexc = 8'h39; 4'd10: hexc = 8'h41; 4'd11: hexc = 8'h42;
                4'd12: hexc = 8'h43; 4'd13: hexc = 8'h44; 4'd14: hexc = 8'h45;
                default: hexc = 8'h46;
            endcase
        end
    endfunction

    // 快照行字符生成 (pos 0..444, 字段位置见头注释; hex 高位在前)
    function [7:0] snap_char;
        input [8:0]  pos;
        input [31:0] v_nx, v_ua;
        input [15:0] v_wn, v_inf, v_eff;
        input [3:0]  v_ws, v_st, v_lv;
        input [2:0]  v_ts, v_rxs, v_est;
        input        v_acc, v_emv, v_ff, v_fe;
        input [12:0] v_wpt, v_rpt;
        input        v_pf, v_tv, v_pv, v_sv;
        input [11:0] v_plen;
        input [31:0] v_tw, v_tf, v_ti;
        input [8:0]  v_pw, v_pr;
        input        v_pfl, v_pem;
        input [11:0] v_pln;
        input [15:0] v_rpl, v_rpc, v_rwt;
        input [31:0] v_dsq, v_dcr, v_dnm, v_dip, v_pss;
        input        v_rxr;                  // P4b-7-P6: RX-TRACE 冻结标志
        // P4b-7-P6 三站词计数 + 头字计数器 (行尾追加字段, 见头注释)
        input [31:0] v_mw, v_cwi, v_cwo, v_rw;
        input [2:0]  v_wc;
        input [15:0] v_wl;                   // P4b-7-P6-P6b: 线上帧长 (WL 字段)
        // diag18 慢路径/HLS 存活字段 (行尾追加, 见头注释)
        input [31:0] v_sc, v_sd, v_sf, v_sp;
        input [21:0] v_srv;
        input        v_hr;
        input [31:0] v_tru;
        begin
            if      (pos <= 7'd2)     snap_char =(pos == 7'd0) ? 8'h4E :     // N
                                                 (pos == 7'd1) ? 8'h58 : 8'h3D; // X =
            else if (pos <= 7'd10)    snap_char =hexc(v_nx >> (4 * (7'd10 - pos)));
            else if (pos == 7'd11)    snap_char =8'h20;                        // ' '
            else if (pos <= 7'd14)    snap_char =(pos == 7'd12) ? 8'h55 :      // U
                                                 (pos == 7'd13) ? 8'h41 : 8'h3D; // A =
            else if (pos <= 7'd22)    snap_char =hexc(v_ua >> (4 * (7'd22 - pos)));
            else if (pos == 7'd23)    snap_char =8'h20;
            else if (pos <= 7'd26)    snap_char =(pos == 7'd24) ? 8'h57 :      // W
                                                 (pos == 7'd25) ? 8'h4E : 8'h3D; // N =
            else if (pos <= 7'd30)    snap_char =hexc(v_wn >> (4 * (7'd30 - pos)));
            else if (pos == 7'd31)    snap_char =8'h20;
            else if (pos <= 7'd34)    snap_char =(pos == 7'd32) ? 8'h57 :      // W
                                                 (pos == 7'd33) ? 8'h53 : 8'h3D; // S =
            else if (pos == 7'd35)    snap_char =hexc(v_ws);
            else if (pos == 7'd36)    snap_char =8'h20;
            else if (pos <= 7'd39)    snap_char =(pos == 7'd37) ? 8'h53 :      // S
                                                 (pos == 7'd38) ? 8'h54 : 8'h3D; // T =
            else if (pos == 7'd40)    snap_char =hexc(v_st);
            else if (pos == 7'd41)    snap_char =8'h20;
            else if (pos <= 7'd43)    snap_char =(pos == 7'd42) ? 8'h57 : 8'h3D; // W =
            else if (pos <= 7'd47)    snap_char =8'h30 + v_lv[7'd47 - pos];   // bit3..0
            else if (pos == 7'd48)    snap_char =8'h20;
            else if (pos <= 7'd50)    snap_char =(pos == 7'd49) ? 8'h49 : 8'h3D; // I =
            else if (pos <= 7'd54)    snap_char =hexc(v_inf >> (4 * (7'd54 - pos)));
            else if (pos == 7'd55)    snap_char =8'h20;
            else if (pos <= 7'd57)    snap_char =(pos == 7'd56) ? 8'h45 : 8'h3D; // E =
            else if (pos <= 7'd61)    snap_char =hexc(v_eff >> (4 * (7'd61 - pos)));
            else if (pos == 7'd62)    snap_char =8'h20;
            else if (pos <= 7'd67)    snap_char =(pos == 7'd63) ? 8'h54 :      // T
                                                 (pos == 7'd64) ? 8'h58 :       // X
                                                 (pos == 7'd65) ? 8'h53 :       // S
                                                 (pos == 7'd66) ? 8'h54 : 8'h3D; // T =
            else if (pos == 7'd68)    snap_char =hexc({1'b0, v_ts});
            else if (pos <= 7'd74)    snap_char =(pos == 7'd69) ? 8'h20 :      // ' '
                                                 (pos == 7'd70) ? 8'h52 :       // R
                                                 (pos == 7'd71) ? 8'h58 :       // X
                                                 (pos == 7'd72) ? 8'h53 :       // S
                                                 (pos == 7'd73) ? 8'h54 : 8'h3D; // T =
            else if (pos == 7'd75)    snap_char =hexc({1'b0, v_rxs});
            else if (pos <= 7'd81)    snap_char =(pos == 7'd76) ? 8'h20 :
                                                 (pos == 7'd77) ? 8'h41 :       // A
                                                 (pos == 7'd78) ? 8'h43 :       // C
                                                 (pos == 7'd79) ? 8'h43 :       // C
                                                 (pos == 7'd80) ? 8'h3D :       // =
                                                 8'h30 + v_acc;
            else if (pos <= 7'd87)    snap_char =(pos == 7'd82) ? 8'h20 :
                                                 (pos == 7'd83) ? 8'h45 :       // E
                                                 (pos == 7'd84) ? 8'h4D :       // M
                                                 (pos == 7'd85) ? 8'h56 :       // V
                                                 (pos == 7'd86) ? 8'h3D :       // =
                                                 8'h30 + v_emv;
            else if (pos <= 7'd93)    snap_char =(pos == 7'd88) ? 8'h20 :
                                                 (pos == 7'd89) ? 8'h45 :       // E
                                                 (pos == 7'd90) ? 8'h53 :       // S
                                                 (pos == 7'd91) ? 8'h54 :       // T
                                                 (pos == 7'd92) ? 8'h3D :       // =
                                                 hexc({1'b0, v_est});
            else if (pos <= 7'd100)   snap_char =(pos == 7'd94) ? 8'h20 :
                                                 (pos == 7'd95) ? 8'h46 :       // F
                                                 (pos == 7'd96) ? 8'h46 :       // F
                                                 (pos == 7'd97) ? 8'h45 :       // E
                                                 (pos == 7'd98) ? 8'h3D :       // =
                                                 (pos == 7'd99) ? 8'h30 + v_ff :
                                                                  8'h30 + v_fe;
            // P4c: WPT/RPT 加宽 4 位 hex (AW=13 → 值域 0..1FFF) — 字段保持
            // 8 字符 (101..108 / 109..116), 弃前导分隔空格; 其余字符位置与
            // SNAP_M1 全不变 (TB 只按本行位置表比对)
            else if (pos <= 7'd108)   snap_char =(pos == 7'd101) ? 8'h57 :      // W
                                                 (pos == 7'd102) ? 8'h50 :      // P
                                                 (pos == 7'd103) ? 8'h54 :      // T
                                                 (pos == 7'd104) ? 8'h3D :      // =
                                                 hexc(v_wpt >> (4 * (7'd108 - pos)));
            else if (pos <= 7'd116)   snap_char =(pos == 7'd109) ? 8'h52 :      // R
                                                 (pos == 7'd110) ? 8'h50 :      // P
                                                 (pos == 7'd111) ? 8'h54 :      // T
                                                 (pos == 7'd112) ? 8'h3D :      // =
                                                 hexc(v_rpt >> (4 * (7'd116 - pos)));
            else if (pos <= 7'd121)   snap_char =(pos == 7'd117) ? 8'h20 :     // ' '
                                                 (pos == 7'd118) ? 8'h50 :      // P
                                                 (pos == 7'd119) ? 8'h46 :      // F
                                                 (pos == 7'd120) ? 8'h3D :      // =
                                                 8'h30 + v_pf;
            else if (pos <= 7'd126)   snap_char =(pos == 7'd122) ? 8'h20 :
                                                 (pos == 7'd123) ? 8'h54 :      // T
                                                 (pos == 7'd124) ? 8'h56 :      // V
                                                 (pos == 7'd125) ? 8'h3D :      // =
                                                 8'h30 + v_tv;
            else if (pos <= 8'd131)   snap_char =(pos == 8'd127) ? 8'h20 :
                                                 (pos == 8'd128) ? 8'h50 :      // P
                                                 (pos == 8'd129) ? 8'h56 :      // V
                                                 (pos == 8'd130) ? 8'h3D :      // =
                                                 8'h30 + v_pv;
            else if (pos <= 8'd136)   snap_char =(pos == 8'd132) ? 8'h20 :
                                                 (pos == 8'd133) ? 8'h53 :      // S
                                                 (pos == 8'd134) ? 8'h56 :      // V
                                                 (pos == 8'd135) ? 8'h3D :      // =
                                                 8'h30 + v_sv;
            else if (pos <= 8'd145)   snap_char =(pos == 8'd137) ? 8'h20 :
                                                 (pos == 8'd138) ? 8'h50 :      // P
                                                 (pos == 8'd139) ? 8'h4C :      // L
                                                 (pos == 8'd140) ? 8'h45 :      // E
                                                 (pos == 8'd141) ? 8'h4E :      // N
                                                 (pos == 8'd142) ? 8'h3D :      // =
                                                 hexc(v_plen >> (4 * (8'd145 - pos)));
            else if (pos <= 8'd157)   snap_char =(pos == 8'd146) ? 8'h20 :      // ' '
                                                 (pos == 8'd147) ? 8'h54 :      // T
                                                 (pos == 8'd148) ? 8'h57 :      // W
                                                 (pos == 8'd149) ? 8'h3D :      // =
                                                 hexc(v_tw >> (4 * (8'd157 - pos)));
            else if (pos <= 8'd169)   snap_char =(pos == 8'd158) ? 8'h20 :      // ' '
                                                 (pos == 8'd159) ? 8'h54 :      // T
                                                 (pos == 8'd160) ? 8'h46 :      // F
                                                 (pos == 8'd161) ? 8'h3D :      // =
                                                 hexc(v_tf >> (4 * (8'd169 - pos)));
            else if (pos <= 8'd181)   snap_char =(pos == 8'd170) ? 8'h20 :      // ' '
                                                 (pos == 8'd171) ? 8'h54 :      // T
                                                 (pos == 8'd172) ? 8'h49 :      // I
                                                 (pos == 8'd173) ? 8'h3D :      // =
                                                 hexc(v_ti >> (4 * (8'd181 - pos)));
            else if (pos <= 8'd188)   snap_char =(pos == 8'd182) ? 8'h20 :      // ' '
                                                 (pos == 8'd183) ? 8'h50 :      // P
                                                 (pos == 8'd184) ? 8'h57 :      // W
                                                 (pos == 8'd185) ? 8'h3D :      // =
                                                 hexc(v_pw >> (4 * (8'd188 - pos)));
            else if (pos <= 8'd195)   snap_char =(pos == 8'd189) ? 8'h20 :      // ' '
                                                 (pos == 8'd190) ? 8'h50 :      // P
                                                 (pos == 8'd191) ? 8'h52 :      // R
                                                 (pos == 8'd192) ? 8'h3D :      // =
                                                 hexc(v_pr >> (4 * (8'd195 - pos)));
            else if (pos <= 8'd201)   snap_char =(pos == 8'd196) ? 8'h20 :      // ' '
                                                 (pos == 8'd197) ? 8'h50 :      // P
                                                 (pos == 8'd198) ? 8'h46 :      // F
                                                 (pos == 8'd199) ? 8'h4C :      // L
                                                 (pos == 8'd200) ? 8'h3D :      // =
                                                                  8'h30 + v_pfl;
            else if (pos <= 8'd207)   snap_char =(pos == 8'd202) ? 8'h20 :      // ' '
                                                 (pos == 8'd203) ? 8'h50 :      // P
                                                 (pos == 8'd204) ? 8'h45 :      // E
                                                 (pos == 8'd205) ? 8'h4D :      // M
                                                 (pos == 8'd206) ? 8'h3D :      // =
                                                                  8'h30 + v_pem;
            else if (pos <= 8'd215)   snap_char =(pos == 8'd208) ? 8'h20 :      // ' '
                                                 (pos == 8'd209) ? 8'h50 :      // P
                                                 (pos == 8'd210) ? 8'h4C :      // L
                                                 (pos == 8'd211) ? 8'h4E :      // N
                                                 (pos == 8'd212) ? 8'h3D :      // =
                                                 hexc(v_pln >> (4 * (8'd215 - pos)));
            // ---- P4b-7-P6 追加: RX 侧帧判读 + 丢弃/通过计数 (216..300) ----
            else if (pos <= 9'd225)   snap_char =(pos == 9'd216) ? 8'h20 :      // ' '
                                                 (pos == 9'd217) ? 8'h52 :      // R
                                                 (pos == 9'd218) ? 8'h58 :      // X
                                                 (pos == 9'd219) ? 8'h50 :      // P
                                                 (pos == 9'd220) ? 8'h4C :      // L
                                                 (pos == 9'd221) ? 8'h3D :      // =
                                                 hexc(v_rpl >> (4 * (9'd225 - pos)));
            else if (pos <= 9'd235)   snap_char =(pos == 9'd226) ? 8'h20 :      // ' '
                                                 (pos == 9'd227) ? 8'h52 :      // R
                                                 (pos == 9'd228) ? 8'h58 :      // X
                                                 (pos == 9'd229) ? 8'h50 :      // P
                                                 (pos == 9'd230) ? 8'h43 :      // C
                                                 (pos == 9'd231) ? 8'h3D :      // =
                                                 hexc(v_rpc >> (4 * (9'd235 - pos)));
            else if (pos <= 9'd244)   snap_char =(pos == 9'd236) ? 8'h20 :      // ' '
                                                 (pos == 9'd237) ? 8'h52 :      // R
                                                 (pos == 9'd238) ? 8'h58 :      // X
                                                 (pos == 9'd239) ? 8'h54 :      // T
                                                 (pos == 9'd240) ? 8'h3D :      // =
                                                 hexc(v_rwt >> (4 * (9'd244 - pos)));
            else if (pos <= 9'd286)   snap_char =(pos == 9'd245) ? 8'h20 :      // ' '
                                                 (pos == 9'd246) ? 8'h44 :      // D
                                                 (pos == 9'd247) ? 8'h52 :      // R
                                                 (pos == 9'd248) ? 8'h4F :      // O
                                                 (pos == 9'd249) ? 8'h50 :      // P
                                                 (pos == 9'd250) ? 8'h53 :      // S
                                                 (pos == 9'd251) ? 8'h3D :      // =
                                                 (pos == 9'd260) ? 8'h2F :      // /
                                                 (pos == 9'd269) ? 8'h2F :      // /
                                                 (pos == 9'd278) ? 8'h2F :      // /
                                                 (pos <= 9'd259) ? hexc(v_dsq >> (4 * (9'd259 - pos))) :
                                                 (pos <= 9'd268) ? hexc(v_dcr >> (4 * (9'd268 - pos))) :
                                                 (pos <= 9'd277) ? hexc(v_dnm >> (4 * (9'd277 - pos))) :
                                                                   hexc(v_dip >> (4 * (9'd286 - pos)));
            else if (pos <= 9'd300)   snap_char =(pos == 9'd287) ? 8'h20 :      // ' '
                                                 (pos == 9'd288) ? 8'h50 :      // P
                                                 (pos == 9'd289) ? 8'h41 :      // A
                                                 (pos == 9'd290) ? 8'h53 :      // S
                                                 (pos == 9'd291) ? 8'h53 :      // S
                                                 (pos == 9'd292) ? 8'h3D :      // =
                                                                   hexc(v_pss >> (4 * (9'd300 - pos)));
            // ---- P4b-7-P6 RX-TRACE 标志 (301..307): " RXTR=%d" ----
            // 1 = RX 环已冻结 (帧尾计数异常触发), 与 rxt_run 同源; 行首重采
            else if (pos <= 9'd307)   snap_char =(pos == 9'd301) ? 8'h20 :      // ' '
                                                 (pos == 9'd302) ? 8'h52 :      // R
                                                 (pos == 9'd303) ? 8'h58 :      // X
                                                 (pos == 9'd304) ? 8'h54 :      // T
                                                 (pos == 9'd305) ? 8'h52 :      // R
                                                 (pos == 9'd306) ? 8'h3D :      // =
                                                                   8'h30 + v_rxr;
            // ---- P4b-7-P6 三站词计数 (308..357): " MW=%08X CW=%08X/%08X
            //      RW=%08X WC=%d" (50 字符, 见头注释) ----
            else if (pos <= 9'd319)   snap_char =(pos == 9'd308) ? 8'h20 :      // ' '
                                                 (pos == 9'd309) ? 8'h4D :      // M
                                                 (pos == 9'd310) ? 8'h57 :      // W
                                                 (pos == 9'd311) ? 8'h3D :      // =
                                                 hexc(v_mw >> (4 * (9'd319 - pos)));
            else if (pos <= 9'd340)   snap_char =(pos == 9'd320) ? 8'h20 :      // ' '
                                                 (pos == 9'd321) ? 8'h43 :      // C
                                                 (pos == 9'd322) ? 8'h57 :      // W
                                                 (pos == 9'd323) ? 8'h3D :      // =
                                                 (pos == 9'd332) ? 8'h2F :      // '/'
                                                 (pos <= 9'd331) ?
                                                     hexc(v_cwi >> (4 * (9'd331 - pos))) :
                                                     hexc(v_cwo >> (4 * (9'd340 - pos)));
            else if (pos <= 9'd352)   snap_char =(pos == 9'd341) ? 8'h20 :      // ' '
                                                 (pos == 9'd342) ? 8'h52 :      // R
                                                 (pos == 9'd343) ? 8'h57 :      // W
                                                 (pos == 9'd344) ? 8'h3D :      // =
                                                 hexc(v_rw >> (4 * (9'd352 - pos)));
            else if (pos <= 9'd357)   snap_char =(pos == 9'd353) ? 8'h20 :      // ' '
                                                 (pos == 9'd354) ? 8'h57 :      // W
                                                 (pos == 9'd355) ? 8'h43 :      // C
                                                 (pos == 9'd356) ? 8'h3D :      // =
                                                                   8'h30 + v_wc;
            // ---- P4b-7-P6-P6b 线上帧长 (358..365): " WL=%04X" (行末字段) ----
            // 异常触发帧的线上字节数 (phy1_rxc 域 RX_CTL 高电平拍数 x8, 触发拍
            // 锁存): 0042≈66 字节短帧 (PC 侧) vs 05EA≈1514 字节整帧被吞 (FPGA 侧)
            else if (pos <= 9'd365)   snap_char =(pos == 9'd358) ? 8'h20 :      // ' '
                                                 (pos == 9'd359) ? 8'h57 :      // W
                                                 (pos == 9'd360) ? 8'h4C :      // L
                                                 (pos == 9'd361) ? 8'h3D :      // =
                                                 hexc(v_wl >> (4 * (9'd365 - pos)));
            // ---- diag18 慢路径/HLS 存活字段 (366..428): " SC=%08X SD=%08X
            //      SF=%08X SP=%08X SV=%06X HR=%d" (行尾追加) ----
            // SC/SD = slow_rx_adp 提交/丢弃 (RX→HLS 交付证明), SF/SP = slow_tx_adp
            // 发出/purge (HLS→TX 链证明; 活着应 ~5s +1), SV = 看门狗饥饿累计
            // (周期归 0 = 看门狗循环复位 HLS), HR = hls_rst_n 实时 (0 = 复位中)
            else if (pos <= 9'd377)   snap_char =(pos == 9'd366) ? 8'h20 :      // ' '
                                                 (pos == 9'd367) ? 8'h53 :      // S
                                                 (pos == 9'd368) ? 8'h43 :      // C
                                                 (pos == 9'd369) ? 8'h3D :      // =
                                                 hexc(v_sc >> (4 * (9'd377 - pos)));
            else if (pos <= 9'd389)   snap_char =(pos == 9'd378) ? 8'h20 :      // ' '
                                                 (pos == 9'd379) ? 8'h53 :      // S
                                                 (pos == 9'd380) ? 8'h44 :      // D
                                                 (pos == 9'd381) ? 8'h3D :      // =
                                                 hexc(v_sd >> (4 * (9'd389 - pos)));
            else if (pos <= 9'd401)   snap_char =(pos == 9'd390) ? 8'h20 :      // ' '
                                                 (pos == 9'd391) ? 8'h53 :      // S
                                                 (pos == 9'd392) ? 8'h46 :      // F
                                                 (pos == 9'd393) ? 8'h3D :      // =
                                                 hexc(v_sf >> (4 * (9'd401 - pos)));
            else if (pos <= 9'd413)   snap_char =(pos == 9'd402) ? 8'h20 :      // ' '
                                                 (pos == 9'd403) ? 8'h53 :      // S
                                                 (pos == 9'd404) ? 8'h50 :      // P
                                                 (pos == 9'd405) ? 8'h3D :      // =
                                                 hexc(v_sp >> (4 * (9'd413 - pos)));
            else if (pos <= 9'd423)   snap_char =(pos == 9'd414) ? 8'h20 :      // ' '
                                                 (pos == 9'd415) ? 8'h53 :      // S
                                                 (pos == 9'd416) ? 8'h56 :      // V
                                                 (pos == 9'd417) ? 8'h3D :      // =
                                                 hexc(v_srv >> (4 * (9'd423 - pos)));
            else if (pos <= 9'd429)   snap_char =(pos == 9'd424) ? 8'h20 :      // ' '
                                                 (pos == 9'd425) ? 8'h48 :      // H
                                                 (pos == 9'd426) ? 8'h52 :      // R
                                                 (pos == 9'd427) ? 8'h3D :      // =
                                                 (pos == 9'd428) ? 8'h30 + v_hr : 8'h20;
            // ---- P4b-7-P6 trunc 计数 (430..442): " TRU=%08X" (行尾追加;
            //      审查 P2-8: 位基 442 = 8 位 hex 全宽) ----
            else if (pos <= 9'd442)   snap_char =(pos == 9'd430) ? 8'h20 :      // ' '
                                                 (pos == 9'd431) ? 8'h54 :      // T
                                                 (pos == 9'd432) ? 8'h52 :      // R
                                                 (pos == 9'd433) ? 8'h55 :      // U
                                                 (pos == 9'd434) ? 8'h3D :      // =
                                                 hexc(v_tru >> (4 * (9'd442 - pos)));
            else if (pos == 9'd443)   snap_char =8'h0D;                        // CR
            else                      snap_char =8'h0A;                        // LF (444)
        end
    endfunction

    // TR 行字符生成 (pos 0..116): "TR=" + 16 字 × (6 hex + 空格分隔)
    //   字数据由 tr_word 预取寄存器直入 (wd), ph = 字符在字内相位 (0..5=hex 位,
    //   高位在前; 6=空格)。CR/LF 用 pos 显式拦截 (此时 tid/tph 已无意义)。
    function [7:0] tr_char;
        input [8:0]  pos;
        input [2:0]  ph;
        input [23:0] wd;
        begin
            case (pos)
                9'd0:   tr_char = 8'h54;               // 'T'
                9'd1:   tr_char = 8'h52;               // 'R'
                9'd2:   tr_char = 8'h3D;               // '='
                9'd115: tr_char = 8'h0D;               // CR
                9'd116: tr_char = 8'h0A;               // LF
                default: case (ph)
                    3'd0: tr_char = hexc(wd[23:20]);
                    3'd1: tr_char = hexc(wd[19:16]);
                    3'd2: tr_char = hexc(wd[15:12]);
                    3'd3: tr_char = hexc(wd[11:8]);
                    3'd4: tr_char = hexc(wd[7:4]);
                    3'd5: tr_char = hexc(wd[3:0]);
                    default: tr_char = 8'h20;          // ' ' 字间分隔
                endcase
            endcase
        end
    endfunction

    // P4b-7-P6 RXT 行字符生成 (pos 0..133): "RXT=" + 16 字 × (7 hex + 空格) + CR LF
    //   字数据由 rxt_word 预取寄存器直入 (wd), ph = 字符在字内相位 (0..6=hex 位,
    //   高位在前; 7=空格)。前缀 4 字符 → 行首 tph 初值 7 (与字末空格同相, 见
    //   tph_n 的 13 段 hold 值), 使 pos = 4+8*tt+pp 处 ph = pp; CR/LF 用 pos
    //   显式拦截。27 位条目按 7 位 hex 转储: 首数字 = {1'b0, wd[26:24]} (3 位
    //   wcnt 零扩展 = %07X 的语义), 余 6 数字 = wd[23:0] 逐 nibble。
    function [7:0] rxt_char;
        input [8:0]  pos;
        input [2:0]  ph;
        input [26:0] wd;
        begin
            case (pos)
                9'd0:   rxt_char = 8'h52;               // 'R'
                9'd1:   rxt_char = 8'h58;               // 'X'
                9'd2:   rxt_char = 8'h54;               // 'T'
                9'd3:   rxt_char = 8'h3D;               // '='
                9'd132: rxt_char = 8'h0D;               // CR
                9'd133: rxt_char = 8'h0A;               // LF
                default: case (ph)
                    3'd0: rxt_char = hexc({1'b0, wd[26:24]});
                    3'd1: rxt_char = hexc(wd[23:20]);
                    3'd2: rxt_char = hexc(wd[19:16]);
                    3'd3: rxt_char = hexc(wd[15:12]);
                    3'd4: rxt_char = hexc(wd[11:8]);
                    3'd5: rxt_char = hexc(wd[7:4]);
                    3'd6: rxt_char = hexc(wd[3:0]);
                    default: rxt_char = 8'h20;          // ' ' 字间分隔
                endcase
            endcase
        end
    endfunction

    // TL 行字符生成 (pos 0..20): "TL=" + 8 字节 %02X (地址顺序) + CR LF
    //   行 k = lno-5 (0..7), 字节 j (0..7) = 址 (base+8k+j) 的 tlast 位; 位值 0/1
    //   打印成 hex 00/01 (高 nibble 恒 '0'), 一字节一槽, 无位序歧义。
    //   字符相 u = pos-3 (0..15): 偶 u = 高 nibble, 奇 u = 低 nibble。
    function [7:0] tl_char;
        input [8:0]  pos;
        input [63:0] bits;                 // 位图 (位 g = 址 base+g 的 tlast)
        input [3:0]  k;                    // 行内组号 0..7 (lno-5)
        integer u, bb;
        begin
            if      (pos == 9'd0)  tl_char = 8'h54;      // 'T'
            else if (pos == 9'd1)  tl_char = 8'h4C;      // 'L'
            else if (pos == 9'd2)  tl_char = 8'h3D;      // '='
            else if (pos == 9'd19) tl_char = 8'h0D;      // CR
            else if (pos == 9'd20) tl_char = 8'h0A;      // LF
            else begin
                u  = pos - 9'd3;                 // 0..15
                bb = k * 8 + (u / 2);            // 位号 0..63
                tl_char = ((u % 2) == 0) ? 8'h30 :            // 高 nibble '0'
                                           (8'h30 + {7'b0, bits[bb]});
            end
        end
    endfunction

    // 行字符总 mux: lno=0 → 快照行 (snap_char), lno=1..4 → TR 行 (tr_char),
    // lno=5..12 → TL 行 (tl_char), lno=13..16 → RXT 行 (rxt_char)
    // (TR/RXT 行不需要快照/环地址参数: 字已由 tr_word/rxt_word 预取, 只需字内
    //  相位 ph; TL 行只需位图 + 行内组号 k; RXT 与 TR 共用 f_twd 口 — 调用点
    //  按 lno 选 rxt_word/tr_word 送入)
    function [7:0] line_char;
        input [4:0]  f_lno;
        input [8:0]  pos;
        input [31:0] v_nx, v_ua;
        input [15:0] v_wn, v_inf, v_eff;
        input [3:0]  v_ws, v_st, v_lv;
        input [2:0]  v_ts, v_rxs, v_est;
        input        v_acc, v_emv, v_ff, v_fe;
        input [12:0] v_wpt, v_rpt;
        input        v_pf, v_tv, v_pv, v_sv;
        input [11:0] v_plen;
        input [31:0] v_tw, v_tf, v_ti;
        input [8:0]  v_pw, v_pr;
        input        v_pfl, v_pem;
        input [11:0] v_pln;
        input [15:0] v_rpl, v_rpc, v_rwt;
        input [31:0] v_dsq, v_dcr, v_dnm, v_dip, v_pss;
        input        v_rxr;
        input [31:0] v_mw, v_cwi, v_cwo, v_rw;
        input [2:0]  v_wc;
        input [15:0] v_wl;
        // diag18 慢路径/HLS 存活字段
        input [31:0] v_sc, v_sd, v_sf, v_sp;
        input [21:0] v_srv;
        input        v_hr;
        input [31:0] v_tru;
        input [2:0]  f_ph;
        input [26:0] f_twd;
        input [63:0] f_bits;
        input [3:0]  f_k;
        begin
            if (f_lno == 4'd0)
                line_char = snap_char(pos, v_nx, v_ua, v_wn, v_inf, v_eff, v_ws,
                                      v_st, v_lv, v_ts, v_rxs, v_est, v_acc,
                                      v_emv, v_ff, v_fe, v_wpt, v_rpt, v_pf,
                                      v_tv, v_pv, v_sv, v_plen, v_tw, v_tf,
                                      v_ti, v_pw, v_pr, v_pfl, v_pem, v_pln,
                                      v_rpl, v_rpc, v_rwt, v_dsq, v_dcr,
                                      v_dnm, v_dip, v_pss, v_rxr,
                                      v_mw, v_cwi, v_cwo, v_rw, v_wc, v_wl,
                                      v_sc, v_sd, v_sf, v_sp, v_srv, v_hr, v_tru);
            else if (f_lno >= 4'd13)
                line_char = rxt_char(pos, f_ph, f_twd);
            else if (f_lno >= 4'd5)
                line_char = tl_char(pos, f_bits, f_k);
            else
                line_char = tr_char(pos, f_ph, f_twd);
        end
    endfunction

    // 行首推进 (S_IDLE 首行 / S_GAP 到期回 S_IDLE): 重采 tx_state, 起 0 号字符
    // 发送节奏: ugo = S_CH && !busy; uart 与 FSM 同拍采样非阻塞 —
    // uart 取的是推进前的 cur, FSM 同拍推进 ci/cur, 无丢/重字。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; ci <= 8'd0; cur <= 8'd0; gap <= 30'd0;
            lno <= 4'd0; tid <= 4'd0; tph <= 3'd0; tr_word <= 24'd0;
            ts_l <= 3'd0; rxs_l <= 3'd0; acc_l <= 0; emv_l <= 0;
            est_l <= 3'd0; ffl_l <= 0; fel_l <= 0;
            wpt_l <= 13'd0; rpt_l <= 13'd0;
            pf_l <= 0; tv_l <= 0; pv_l <= 0; sv_l <= 0;
            plen_l <= 12'd0;
            tw_l <= 32'd0; tf_l <= 32'd0; ti_l <= 32'd0;
            pw_l <= 9'd0; pr_l <= 9'd0; pfl_l <= 1'b0; pem_l <= 1'b0;
            pln_l <= 12'd0;
            rpl_l <= 16'd0; rpc_l <= 16'd0; rwt_l <= 16'd0;
            dsq_l <= 32'd0; dcr_l <= 32'd0; dnm_l <= 32'd0;
            dip_l <= 32'd0; pss_l <= 32'd0;
            mw_l <= 32'd0; cwi_l <= 32'd0; cwo_l <= 32'd0; rw_l <= 32'd0;
            wc_l <= 3'd0;
            wl_l <= 16'd0;
            sc_l <= 32'd0; sd_l <= 32'd0; sf_l <= 32'd0; sp_l <= 32'd0;
            srv_l <= 22'd0; hr_l <= 1'b0; tru_l <= 32'd0;
            rxt_word <= 27'd0; rxt_l <= 1'b0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (run || tr_run || rxt_run) begin
                        st <= S_CH; ci <= 8'd0;
                        tid <= 4'd0;
                        if (run) begin
                            tph <= 3'd0;
                            lno <= 4'd0;                    // 快照行
                            // 行首重采 (实时值只在这一拍进快照; char0='N' 不吃新值)
                            ts_l <= tx_state; rxs_l <= rx_state;
                            acc_l <= rx_accept; emv_l <= rx_emitv;
                            est_l <= echo_state;
                            ffl_l <= fifo_full; fel_l <= fifo_empty;
                            wpt_l <= fifo_wptr; rpt_l <= fifo_rptr;
                            pf_l <= tx_pay_full; tv_l <= tx_saxis_tv;
                            pv_l <= pipe_mv; sv_l <= pipe_sv;
                            plen_l <= tx_plen_r;
                            tw_l <= tlast_wr; tf_l <= tlast_fwd; ti_l <= tlast_in;
                            pw_l <= pay_wptr; pr_l <= pay_rptr;
                            pfl_l <= pay_full2; pem_l <= pay_empty;
                            pln_l <= tx_plen;
                            rpl_l <= rx_plen_l; rpc_l <= rx_pcount;
                            rwt_l <= rx_w2_tlen;
                            dsq_l <= rx_drop_seq; dcr_l <= rx_drop_crc;
                            dnm_l <= rx_drop_nonmatch; dip_l <= rx_drop_ipcsum;
                            tru_l <= rx_drop_trunc;
                            pss_l <= rx_pass;
                            mw_l <= mac_words_out; cwi_l <= cls_words_in;
                            cwo_l <= cls_words_out; rw_l <= rx_words_in;
                            wc_l <= rx_wcnt;
                            rxt_l <= rxt_run;               // RXTR 标志 (行首重采)
                            wl_l <= rx_wire_last;           // WL 线上帧长 (行首重采)
                            sc_l <= srx_commit; sd_l <= srx_drop;   // diag18 慢路径
                            sf_l <= stx_frames; sp_l <= stx_purge;   // 存活字段重采
                            srv_l <= starv;     hr_l <= hls_rst;
                            cur <= line_char(4'd0, 9'd0, snd_nxt, snd_una, snd_wnd,
                                             win_inflight, win_wnd_eff,
                                             wscale, tcb_state, latch_val, ts_l,
                                             rxs_l, est_l, acc_l, emv_l,
                                             ffl_l, fel_l, wpt_l, rpt_l,
                                             pf_l, tv_l, pv_l, sv_l, plen_l,
                                             tw_l, tf_l, ti_l,
                                             pw_l, pr_l, pfl_l, pem_l, pln_l,
                                             rpl_l, rpc_l, rwt_l,
                                             dsq_l, dcr_l, dnm_l, dip_l, pss_l,
                                             rxt_l,
                                             mw_l, cwi_l, cwo_l, rw_l, wc_l,
                                             wl_l,
                                             sc_l, sd_l, sf_l, sp_l, srv_l, hr_l, tru_l,
                                             3'd0, 27'd0, 64'd0, 4'd0);
                        end else if (tr_run) begin
                            tph <= 3'd0;
                            lno <= 4'd1;                    // run=0: 直发 TR 行 1
                            tr_word <= tr_wnew;             // 行首预取 (tid=0)
                            cur <= 8'h54;                   // 'T'
                        end else begin
                            tph <= 3'd7;                    // RXT 前缀 4 字符相位
                            lno <= 4'd13;                   // 直发 RXT 行 1
                            rxt_word <= rxt_wnew;           // 行首预取 (tid=0)
                            cur <= 8'h52;                   // 'R'
                        end
                    end
                end
                S_CH: begin
                    if (!ubusy) begin
                        if (ci == nl_m1) begin              // 本行末 (LF 已入 uart)
                            if (lno == 5'd16) begin         // 末 RXT 行 → GAP
                                st <= S_GAP; gap <= 30'd0;
                            end else if (lno == 4'd12) begin // TL8 → RXT (rxt_run) 或 GAP
                                if (rxt_run) begin
                                    lno <= 4'd13; ci <= 8'd0;
                                    tid <= 4'd0; tph <= 3'd7;   // RXT 前缀相位
                                    rxt_word <= rxt_wnew;       // 行首预取 (tid=0)
                                    cur <= 8'h52;           // 'R'
                                end else begin
                                    st <= S_GAP; gap <= 30'd0;
                                end
                            end else if (lno == 4'd4) begin // TR4 → TL (run) / RXT / GAP
                                if (run) begin
                                    lno <= 4'd5; ci <= 8'd0;
                                    cur <= 8'h54;           // 'T'
                                end else if (rxt_run) begin
                                    lno <= 4'd13; ci <= 8'd0;
                                    tid <= 4'd0; tph <= 3'd7;
                                    rxt_word <= rxt_wnew;
                                    cur <= 8'h52;           // 'R'
                                end else begin
                                    st <= S_GAP; gap <= 30'd0;
                                end
                            end else begin
                                lno <= lno_n; ci <= 8'd0;   // 0→1 / 0→5 / lno+1
                                if (lno_n <= 4'd4) begin    // 下一行是 TR: 行首预取
                                    tid <= 4'd0; tph <= 3'd0;
                                    tr_word <= tr_wnew;     // (tid=0)
                                end else if (lno_n >= 4'd13) begin  // 下一行是 RXT
                                    tid <= 4'd0; tph <= 3'd7;
                                    rxt_word <= rxt_wnew;   // (tid=0)
                                end
                                cur <= (lno_n >= 4'd13) ? 8'h52 : 8'h54;  // 'R' : 'T'
                            end
                        end else begin
                            ci <= ci + 9'd1;
                            if (lno == 4'd0) begin
                                cur <= line_char(4'd0, ci + 9'd1,
                                             snd_nxt, snd_una, snd_wnd,
                                             win_inflight, win_wnd_eff,
                                             wscale, tcb_state, latch_val, ts_l,
                                             rxs_l, est_l, acc_l, emv_l,
                                             ffl_l, fel_l, wpt_l, rpt_l,
                                             pf_l, tv_l, pv_l, sv_l, plen_l,
                                             tw_l, tf_l, ti_l,
                                             pw_l, pr_l, pfl_l, pem_l, pln_l,
                                             rpl_l, rpc_l, rwt_l,
                                             dsq_l, dcr_l, dnm_l, dip_l, pss_l,
                                             rxt_l,
                                             mw_l, cwi_l, cwo_l, rw_l, wc_l,
                                             wl_l,
                                             sc_l, sd_l, sf_l, sp_l, srv_l, hr_l, tru_l,
                                             3'd0, 27'd0, 64'd0, 4'd0);
                            end else if ((lno >= 4'd5) && (lno < 4'd13)) begin
                                // TL 行: 位图 + 行内组号 k = lno-5
                                cur <= line_char(lno, ci + 9'd1,
                                             snd_nxt, snd_una, snd_wnd,
                                             win_inflight, win_wnd_eff,
                                             wscale, tcb_state, latch_val, ts_l,
                                             rxs_l, est_l, acc_l, emv_l,
                                             ffl_l, fel_l, wpt_l, rpt_l,
                                             pf_l, tv_l, pv_l, sv_l, plen_l,
                                             tw_l, tf_l, ti_l,
                                             pw_l, pr_l, pfl_l, pem_l, pln_l,
                                             rpl_l, rpc_l, rwt_l,
                                             dsq_l, dcr_l, dnm_l, dip_l, pss_l,
                                             rxt_l,
                                             mw_l, cwi_l, cwo_l, rw_l, wc_l,
                                             wl_l,
                                             sc_l, sd_l, sf_l, sp_l, srv_l, hr_l, tru_l,
                                             3'd0, 27'd0, tl_bits, lno[3:0] - 4'd5);
                            end else begin
                                // TR 行 (1..4) / RXT 行 (13..16): 预取寄存器 + 字内相
                                tid <= tid_n; tph <= tph_n;
                                if (lno >= 4'd13) begin
                                    if (tph == f_pre) rxt_word <= rxt_wpre; // 预取 tid+1 字
                                end else if (tph == f_pre) begin
                                    tr_word <= tr_wpre;                     // 预取 tid+1 字
                                end
                                cur <= line_char(lno, ci + 9'd1,
                                             snd_nxt, snd_una, snd_wnd,
                                             win_inflight, win_wnd_eff,
                                             wscale, tcb_state, latch_val, ts_l,
                                             rxs_l, est_l, acc_l, emv_l,
                                             ffl_l, fel_l, wpt_l, rpt_l,
                                             pf_l, tv_l, pv_l, sv_l, plen_l,
                                             tw_l, tf_l, ti_l,
                                             pw_l, pr_l, pfl_l, pem_l, pln_l,
                                             rpl_l, rpc_l, rwt_l,
                                             dsq_l, dcr_l, dnm_l, dip_l, pss_l,
                                             rxt_l,
                                             mw_l, cwi_l, cwo_l, rw_l, wc_l,
                                             wl_l,
                                             sc_l, sd_l, sf_l, sp_l, srv_l, hr_l, tru_l,
                                             tph_n,
                                             (lno >= 4'd13) ? rxt_word : tr_word,
                                             64'd0, 4'd0);
                            end
                        end
                    end
                end
                S_GAP: begin
                    if (gap == GAP_LAST) begin
                        gap <= 30'd0;
                        st <= S_IDLE;              // 下一拍走 S_IDLE 首行逻辑
                    end else begin
                        gap <= gap + 30'd1;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
