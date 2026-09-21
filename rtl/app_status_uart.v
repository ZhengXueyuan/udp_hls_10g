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
);
    localparam LINE_LEN = 9'd304;

    // 行模板 (固定文本; hex 位以 'x' 占位, 运行时由 lchar 覆盖)
    // 字节 i = TPL[8*(LINE_LEN-1) - 8*i +: 8] (首字符在最高字节)
    // W5: 追加 DL (超长帧丢弃) / FI (FIN 已发) / RS (RST 已发) 三段 —
    // 板级看不到 FIN 是否发出、坏帧是否被丢。
    // P5b C9: 行尾再追加 AK/AD/TS/WQ/WM/WU/PO/PX (前 156 字符逐字节不变) —
    // 板级病理 (对端停等/窗口不重开/池耗尽) 缺可观测量。
    // P5f: 行尾再追加 UDP app 段 URB/UMM/URF/UOV/UPC/UPA/UTB/UTF
    // (偏移: URB hex 223..230, UMM 236..243, URF 249..252, UOV 258..261,
    //  UPC 267..270, UPA 276..279, UTB 285..292, UTF 298..301; CR=302 LF=303)。
    wire [8*LINE_LEN-1:0] TPL = {
        "P5B1 ST=x NX=xxxxxxxx UA=xxxxxxxx RW=xxxx RN=xxxxxxxx ",
        "RX=xxxxxxxx TX=xxxxxxxx TF=xxxx MM=xxxx OC=xxxxx EV=xxxx ",
        "DP=xxxx RY=xxxx EC=xx DL=xxxx FI=xxxx RS=xxxx",
        " AK=xxxx AD=xxxx TS=x WQ=xxxx WM=xxxx WU=xxxx PO=xxxxx PX=xxxx",
        " URB=xxxxxxxx UMM=xxxxxxxx URF=xxxx UOV=xxxx UPC=xxxx UPA=xxxx",
        " UTB=xxxxxxxx UTF=xxxx",
        8'h0D, 8'h0A
    };

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

    reg [8:0]  ci;                       // 行内字符索引 (9 位: 行 304 字符)
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
    end

    wire uart_busy;
    wire uart_go = sending && !uart_busy;
    uart_tx_9600 #(.BIT_LAST(BIT_LAST)) u_uart (
        .clk(clk), .rst_n(rst_n),
        .byte_in(lc), .tx_go(uart_go), .txd(txd), .busy(uart_busy)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ci <= 9'd0; gap <= 28'd0; sending <= 1'b0;
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
                    ci       <= 9'd0;
                    sending  <= 1'b1;
                end else begin
                    gap <= gap - 28'd1;
                end
            end else if (uart_go) begin
                // 本拍发送 lc (ci 指向它), 推进索引
                if (ci == (LINE_LEN - 9'd1)) begin
                    sending <= 1'b0;
                    gap     <= GAP_TICKS;
                    ci      <= 9'd0;
                end else begin
                    ci <= ci + 9'd1;
                end
            end
        end
    end
endmodule
