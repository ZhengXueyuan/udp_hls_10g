`timescale 1ns/1ps
//=============================================================================
// app_pattern: 板级演示 app (P5a) — TX 图案发生器 + RX 图案校验器
//
// 图案 (D6): xorshift64 LFSR `s ^= s<<13; s ^= s>>7; s ^= s<<17;`, 每步取
//   byte = s[31:24], 种子 0x9E3779B97F4A7C15。字节流偏移 0 = 各方向首个数据
//   字节 (与 tools/cpp_peer 的 verify(bseq-(irs+1)) 语义对齐: 对端按 seq 偏移
//   查图案)。RTL 侧每拍推进 1 步 (1 字节/拍 = 125MB/s ≈ 1Gbps 线速), 凑 8 字节
//   呈交一个 64 位字 (tdata[63:56] = 该 beat 首字节, 与 MAC 字流约定一致)。
//
// TX: CONN_UP 事件 (app_ctrl.o_ev_up) 启动一次 TX_BYTES (默认 1MB) 的发送;
//   每帧 = 一个 TCP 段 (TX_SEGSZ=1460B, 最后一帧为余数), tid = 会话连接;
//   app_tx_ready[act_id] == 0 时不呈现新帧 (避免队头阻塞)。发完 TX_BYTES 后
//   脉冲 close_req (=> app_ctrl 置 fin_req; tcp_tx_frame 只在无在飞时排队 FIN)。
//   故障注入 i_bad_frame != 0: 第 N 个 app 帧用 BAD_LEN (2000B > PLEN_MAX) 的
//   载荷 — 用于验证 tcp_tx_frame 的超长帧帧内中止 (stat_drop_len)。坏帧期间
//   LFSR 冻结 (载荷为常数 0xA5), 故被丢弃后线上图案流仍然连续。
//
// RX: tcp_echo (零拷贝缓冲) 输出 -> 逐字节比对; 1 拍吞 1 字, 之后按字节比对
//   (每拍 1 字节, 期间 rx_tready=0 — FWFT 上游天然保持, AXIS 合同成立)。
//   失配计 stat_mismatch (字节数)。RX 图案 LFSR 在首字节处起算 (偏移 0)。
//
// 本阶段触发条件 = app_ctrl 的事件脉冲 (CONN_UP); 无事件时 RX 侧照常消费
// (不能让 echo 缓冲反压回 tcp_rx)。
//=============================================================================
module app_pattern #(
    parameter [31:0] TX_BYTES   = 32'd1048576,  // 1MB
    parameter [11:0] TX_SEGSZ   = 12'd1460,
    parameter [11:0] BAD_LEN    = 12'd2000,     // 注入坏帧长度 (> PLEN_MAX=1500)
    parameter [63:0] SEED       = 64'h9E3779B97F4A7C15,
    parameter        AUTO_CLOSE = 1'b1          // 发完自动 close_req
) (
    input  wire        clk,
    input  wire        rst_n,
    // 事件 (app_ctrl)
    input  wire        ev_up,
    input  wire        ev_down,
    input  wire [3:0]  ev_slot,
    // ---- TX: app -> stack (经 axis_pipe 接 tcp_tx_frame.s_axis) ----
    // 注意: 这几个口是 pw_* 的纯组合输出 (不能寄存器化 — 寄存器化的 valid
    // 会在消费拍之后多挂一拍, 同一 beat 被消费两次 = 每词重复)
    output wire [63:0] m_tdata,
    output wire [7:0]  m_tkeep,
    output wire        m_tvalid,
    input  wire        m_tready,
    output wire        m_tlast,
    output wire [3:0]  m_tid,
    input  wire [15:0] app_tx_ready,
    // 关闭请求 (app_ctrl.close_req)
    output reg         close_req,
    output reg  [3:0]  close_id,
    // ---- RX: stack -> app (tcp_echo 输出 = 零拷贝 app RX) ----
    input  wire [63:0] rx_tdata,
    input  wire [7:0]  rx_tkeep,
    input  wire        rx_tvalid,
    output wire        rx_tready,
    input  wire        rx_tlast,
    input  wire [3:0]  rx_tid,
    // ---- 故障注入 (TB 驱动; 0 = 关) ----
    input  wire [15:0] i_bad_frame,
    // ---- 统计/状态 ----
    output reg  [31:0] stat_tx_bytes,
    output reg  [31:0] stat_tx_frames,
    output reg  [31:0] stat_bad_frames,   // 注入的超长帧数 (帧被 RTL 丢弃)
    output reg  [31:0] stat_rx_bytes,
    output reg  [31:0] stat_mismatch,
    output reg         active,
    output reg  [3:0]  act_id,
    output reg         done,
    output reg  [31:0] dbg_lfsr,
    output wire [3:0]  led
);
    // ---------------- LFSR (xorshift64) ----------------
    function [63:0] xs_next;
        input [63:0] s;
        reg   [63:0] t;
        begin
            t = s ^ (s << 13);
            t = t ^ (t >> 7);
            t = t ^ (t << 17);
            xs_next = t;
        end
    endfunction

    // 左对齐: stg 低 n 字节 -> 高 n 字节 (显式 case, 禁变移位量)
    function [63:0] ljust8;
        input [63:0] s;
        input [3:0]  n;
        begin
            case (n)
                4'd1: ljust8 = {s[7:0],  56'b0};
                4'd2: ljust8 = {s[15:0], 48'b0};
                4'd3: ljust8 = {s[23:0], 40'b0};
                4'd4: ljust8 = {s[31:0], 32'b0};
                4'd5: ljust8 = {s[39:0], 24'b0};
                4'd6: ljust8 = {s[47:0], 16'b0};
                4'd7: ljust8 = {s[55:0], 8'b0};
                default: ljust8 = s;                 // 8 (及 0 的惰性值)
            endcase
        end
    endfunction

    // tkeep: 高 n 字节有效
    function [7:0] kmask8;
        input [3:0] n;
        begin
            case (n)
                4'd0: kmask8 = 8'h00;
                4'd1: kmask8 = 8'h80;
                4'd2: kmask8 = 8'hC0;
                4'd3: kmask8 = 8'hE0;
                4'd4: kmask8 = 8'hF0;
                4'd5: kmask8 = 8'hF8;
                4'd6: kmask8 = 8'hFC;
                4'd7: kmask8 = 8'hFE;
                default: kmask8 = 8'hFF;
            endcase
        end
    endfunction

    function [3:0] pop8;
        input [7:0] v;
        integer i;
        reg [3:0] c;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]};
            pop8 = c;
        end
    endfunction

    // 字内第 i 字节 (i = 0 为 tdata[63:56])
    function [7:0] byte_at;
        input [63:0] d;
        input [3:0]  i;
        begin
            case (i)
                4'd0: byte_at = d[63:56];
                4'd1: byte_at = d[55:48];
                4'd2: byte_at = d[47:40];
                4'd3: byte_at = d[39:32];
                4'd4: byte_at = d[31:24];
                4'd5: byte_at = d[23:16];
                4'd6: byte_at = d[15:8];
                default: byte_at = d[7:0];
            endcase
        end
    endfunction

    // ---------------- TX 侧 ----------------
    reg  [63:0] tx_lfsr;
    reg  [31:0] remain;        // 会话剩余待发字节
    reg  [11:0] seg_len;       // 当前帧载荷字节
    reg  [11:0] seg_sent;      // 当前帧已呈交字节
    reg  [3:0]  bcnt;          // 当前字已凑字节数
    reg  [63:0] stg;           // 当前字累积 (低 bcnt 字节)
    reg  [63:0] pw_data;       // 已呈交字 (tready 期间保持)
    reg  [7:0]  pw_keep;
    reg  [3:0]  pw_n;
    reg         pw_last;
    reg         pw_valid;
    reg         bad_frm;       // 当前帧是注入的超长帧
    reg  [15:0] frm_idx;       // 已发帧数 (注入序号比对)
    reg         closing;       // W3: 收到 CONN_DOWN, 正在收尾当前帧

    wire [11:0] left     = seg_len - seg_sent;                 // 本帧剩余字节
    wire [3:0]  need     = (left >= 12'd8) ? 4'd8 : left[3:0]; // 本字字节数
    // W3: 合成收尾字 (仅当本帧已有字节进了帧器 — 否则无需收尾, 免得发空帧)
    wire        close_beat = closing && !pw_valid && (seg_sent != 12'd0);
    wire        asm_go   = active && !pw_valid && !closing;
    // 字节生产 (坏帧不推进 LFSR: 载荷常数 0xA5, 丢弃后图案流仍连续)
    wire [7:0]  gen_byte = bad_frm ? 8'hA5 : tx_lfsr[31:24];
    wire        gen_en   = asm_go && (bcnt < need);
    wire [63:0] stg_n    = {stg[55:0], gen_byte};
    wire        asm_full = asm_go && (bcnt == need) && (need != 4'd0);

    // ---------------- RX 侧 (逐字节校验) ----------------
    reg  [1:0]  rxs;           // 0 = 取值, 1 = 逐字节比对
    reg  [63:0] rx_lfsr;
    reg  [63:0] rw_data;
    reg  [7:0]  rw_keep;
    reg  [3:0]  rw_n, rw_i;
    wire [7:0]  rx_exp = rx_lfsr[31:24];
    wire [7:0]  rx_got = byte_at(rw_data, rw_i);
    assign rx_tready = (rxs == 2'd0);

    // 事件/活动/失配指示灯 (APP_MODE 板级)
    reg [3:0]   led_r;
    reg [19:0]  act_tmr;
    reg         up_lat;
    assign led = led_r;

    // ---- TX 呈交口 (组合驱动: valid 有效期间 pw_* 稳定不变) ----
    // W3 收尾: closing 期间 (a) 若已有字在呈交, 该字强带 tlast (帧在此闭合,
    // 载荷 = 图案前缀); (b) 若正装配中 (无字), 合成一个 keep=0 + tlast 的收尾字
    // (tcp_tx_frame 的 accept 只按 pop8(keep)=0 计长, 不入 FIFO 不推进 plen)。
    assign m_tdata  = close_beat ? 64'd0 : pw_data;
    assign m_tkeep  = close_beat ? 8'h00 : pw_keep;
    assign m_tvalid = pw_valid || close_beat;
    assign m_tlast  = close_beat || pw_last || closing;
    assign m_tid    = act_id;

    integer ii;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_lfsr <= SEED; remain <= 32'd0; seg_len <= 12'd0; seg_sent <= 12'd0;
            bcnt <= 4'd0; stg <= 64'd0;
            pw_data <= 64'd0; pw_keep <= 8'h00; pw_n <= 4'd0; pw_last <= 1'b0;
            pw_valid <= 1'b0; bad_frm <= 1'b0; frm_idx <= 16'd0; closing <= 1'b0;
            close_req <= 1'b0; close_id <= 4'd0;
            active <= 1'b0; act_id <= 4'd0; done <= 1'b0;
            stat_tx_bytes <= 32'd0; stat_tx_frames <= 32'd0;
            stat_bad_frames <= 32'd0;
            rxs <= 2'd0; rx_lfsr <= SEED; rw_data <= 64'd0; rw_keep <= 8'h00;
            rw_n <= 4'd0; rw_i <= 4'd0;
            stat_rx_bytes <= 32'd0; stat_mismatch <= 32'd0;
            dbg_lfsr <= SEED;
            led_r <= 4'd0; act_tmr <= 20'd0; up_lat <= 1'b0;
        end else begin
            // 脉冲默认清零
            close_req <= 1'b0;
            dbg_lfsr  <= tx_lfsr;

            // ---- 连接事件 ----
            // P5b C11 (TL 2026-09-19): RX 图案流**每连接**重置, 与 TX 侧对称。
            // 旧行为: rx_lfsr <= SEED 只在 rst_n ⇒ RX 期望序列跨连接/跨会话连续
            // (同槽重连后对端必须"接着上次位置"发才对得上; 多连接下无意义, 板级
            // 测试不可重复)。TX 侧 tx_lfsr 在 ev_up 就重置 (L231) —— 两侧不对称是
            // 设计缺陷。这里补上 RX 侧: 新连接 = 新图案流起点 (含丢弃取值中间态)。
            if (ev_up) begin
                rx_lfsr <= SEED;
                rxs     <= 2'd0;
                // 新连接: 启动图案发送 (单会话; 已有会话时忽略新事件)
                if (!active) begin
                    active   <= 1'b1;
                    act_id   <= ev_slot;
                    remain   <= TX_BYTES;
                    tx_lfsr  <= SEED;
                    frm_idx  <= 16'd0;
                    done     <= 1'b0;
                    // 首帧长度即刻就位 (否则 asm_go 看到 seg_len=0 直接收帧)
                    seg_len  <= (TX_BYTES > {20'b0, TX_SEGSZ}) ? TX_SEGSZ :
                                TX_BYTES[11:0];
                    seg_sent <= 12'd0;
                    bcnt     <= 4'd0;
                    stg      <= 64'd0;
                    bad_frm  <= (i_bad_frame == 16'd1);
                end
                up_lat <= 1'b1;
            end
            // W3 (P5a 复核): 对端关闭不能直接撤 pw_valid (AXIS 违约: 无 tlast、
            // 不等 m_tready 就撤) — 若恰在呈交期间 ev_down, tcp_tx_frame 会停在
            // S_RECV (该态 tready=1) 等下一位, 下一帧首字被当续载荷吞掉 ⇒ 帧边界
            // 错位且 app 不再呈现新帧时永久卡住。正确做法: 置收尾标志, 在下一个
            // m_tready 拍把**当前字节**以 tlast 收帧 (不推进 remain/LFSR 语义),
            // 然后回 idle。
            if (ev_down && active && (ev_slot == act_id)) begin
                closing <= 1'b1;
            end

            // ---- W3 收尾 ----
            if (closing) begin
                if (pw_valid) begin
                    // 已有字在呈交: m_tlast 组合含 closing -> 该字带 tlast 被消费即闭合
                    if (m_tready) begin
                        pw_valid <= 1'b0; closing <= 1'b0; active <= 1'b0;
                        stat_tx_frames <= stat_tx_frames + 32'd1;
                    end
                end else if (close_beat) begin
                    if (m_tready) begin
                        closing <= 1'b0; active <= 1'b0;
                        stat_tx_frames <= stat_tx_frames + 32'd1;
                    end
                end else begin
                    // 本帧尚无字节入帧器 (帧器未开帧): 直接回 idle, 不发空帧
                    closing <= 1'b0; active <= 1'b0;
                end
            end

            // ---- TX 字装配 / 呈交 ----
            if (asm_go) begin
                if (need == 4'd0) begin
                    // 帧已发完 (seg_sent == seg_len): 收帧
                    stat_tx_frames <= stat_tx_frames + 32'd1;
                    if (bad_frm) stat_bad_frames <= stat_bad_frames + 32'd1;
                    frm_idx <= frm_idx + 16'd1;
                    bad_frm <= 1'b0;
                    if (remain == 32'd0) begin
                        active <= 1'b0;
                        done   <= 1'b1;
                        if (AUTO_CLOSE) begin
                            close_req <= 1'b1;
                            close_id  <= act_id;
                        end
                    end else begin
                        // 下一帧长度 (坏帧注入: 第 i_bad_frame 帧)
                        bad_frm <= (i_bad_frame != 16'd0) &&
                                   ((frm_idx + 16'd1) == i_bad_frame);
                        seg_len <= ((i_bad_frame != 16'd0) &&
                                    ((frm_idx + 16'd1) == i_bad_frame)) ? BAD_LEN :
                                   ((remain > {20'b0, TX_SEGSZ}) ? TX_SEGSZ : remain[11:0]);
                        seg_sent <= 12'd0;
                        bcnt <= 4'd0;
                    end
                end else if (bcnt < need) begin
                    bcnt    <= bcnt + 4'd1;
                    stg     <= stg_n;
                    if (!bad_frm) tx_lfsr <= xs_next(tx_lfsr);
                end
            end
            // 字齐 -> 呈交 (1 拍后 valid)
            if (asm_full && !pw_valid) begin
                pw_data  <= ljust8(stg, need);
                pw_keep  <= kmask8(need);
                pw_n     <= need;
                pw_last  <= ((seg_sent + {8'b0, need}) >= seg_len);
                pw_valid <= 1'b1;
                bcnt     <= 4'd0;
                stg      <= 64'd0;
            end
            // 呈交消费 (AXIS: tready=0 期间 pw_* 保持; m_* 组合输出)
            // W3: closing 期间由上面的收尾分支独占消费 (不推进 remain/LFSR)
            if (pw_valid && m_tready && !closing) begin
                pw_valid <= 1'b0;
                seg_sent <= seg_sent + {8'b0, pw_n};
                // 注入的超长帧不计入 TX_BYTES 计划 (被 RTL 丢弃, 不上线):
                // remain/stat_tx_bytes 都不动, 图案流位置不变 (LFSR 也冻结)
                if (!bad_frm) begin
                    remain <= (remain >= {20'b0, pw_n}) ? (remain - {20'b0, pw_n}) :
                              32'd0;
                    stat_tx_bytes <= stat_tx_bytes + {28'b0, pw_n};
                end
            end

            // ---- RX 取值/比对 ----
            if (rxs == 2'd0) begin
                if (rx_tvalid) begin
                    rw_data <= rx_tdata;
                    rw_keep <= rx_tkeep;
                    rw_n    <= pop8(rx_tkeep);
                    rw_i    <= 4'd0;
                    if (pop8(rx_tkeep) == 4'd0) begin
                        // 零有效字节 (空尾字): 直接完成
                        rxs <= 2'd0;
                    end else begin
                        rxs <= 2'd1;
                    end
                end
            end else begin
                if (byte_at(rw_data, rw_i) != rx_exp)
                    stat_mismatch <= stat_mismatch + 32'd1;
                rx_lfsr <= xs_next(rx_lfsr);
                stat_rx_bytes <= stat_rx_bytes + 32'd1;
                if (rw_i + 4'd1 >= rw_n) rxs <= 2'd0;
                else                      rw_i <= rw_i + 4'd1;
            end

            // ---- 活动/指示灯 ----
            if ((rx_tvalid && rx_tready) || (pw_valid && m_tready) || asm_go)
                act_tmr <= 20'd200_000;
            else if (act_tmr != 20'd0)
                act_tmr <= act_tmr - 20'd1;
            led_r[0] <= up_lat;
            led_r[1] <= (act_tmr != 20'd0);
            if (stat_mismatch != 32'd0) led_r[2] <= 1'b1;
            led_r[3] <= done;
        end
    end

    // rx_tlast / rx_tid / rw_keep: 本阶段只做字节流比对, 帧尾/连接号未消费
    // (P5b 的 RX 消费模型会用到)
endmodule
