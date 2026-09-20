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
    reg         frm_wait;      // P5d-D2: 本帧已交付完, 等 tx_ok 才启动下一帧
    reg         op_pend;       // P5e: 本帧的 0 载荷 opener 尚未呈交
    reg         op_sent;       // P5e: 本帧 opener 已交付给 pipe (帧已"预开")

    // ---------------- P5d-D2: "连接不可发"时的 TX 硬化 (D1 曝光的缺陷②) ----
    // 背景 (现象已在 sim/p5sim 的 close 门实测复现, 非推测): app 的呈交口对
    // axis_pipe 有 **1 拍前瞻** —— pipe.s_ready = m_ready || !m_valid, 于是
    // "pipe 空但下游帧器被 tx_blk 挡住" 的那一拍, app 的已装配字照样被 pipe
    // 锁存; 该字此后一直压在 pipe 里, 直到 fence 放开 (新会话 cfg ADD 让
    // state 回到 ESTAB)。复位/新会话都不冲 pipe (axis_pipe 只有 rst_n) ⇒ 残余字
    // 被当成**新会话首帧的首字** → 载荷整段错位 + app 字节计数与线上差 8。
    //
    // 修法 (两条, 都是"帧边界"语义, 不加状态机):
    //  ① **帧启动门**: 连接不可发 (tx_ok=0) 时不再启动新帧 —— 已开始的帧照常
    //     走完 (见 ②), 因为帧一旦开在帧器里, 半途停手会让 tcp_tx_frame 停在
    //     S_RECV 等 tlast (帧器吊死; 同 W3 注释的理由)。
    //     残余字的来源正是"帧结束后又启动下一帧"的首字 ⇒ 门住启动即根除。
    //  ② **tx_ok 只挡启动不挡收尾**: 帧的余下字节照发 (这些字在帧器 S_RECV 期间
    //     被无条件接受 —— 该子句不含 tx_blk, 故 fence 不挡帧内续传), 交付完后
    //     置 frm_wait 静默等 tx_ok 恢复或等同槽新会话。
    // tx_ok 的六个条件 (app_ctrl.v tx_ready_calc): ESTAB / 在飞<帽 / !fin_req /
    //   !fin_sent / !rst_req / !rst_sent。**所有**让 app_tx_ready 掉的因素
    //   (abort fence、窗口关闭、连接拆除、FIN 已排) 都只影响"能不能起新帧",
    //   不影响"当前帧能不能收尾" ⇒ 对每一种都是正确的:
    //     - abort/fence (rst_req/rst_sent): 帧内续传靠 S_RECV 无条件接受 ⇒ 收尾
    //       成功, 且线上帧的载荷/seq 连续 (逐字节判据不破);
    //     - 窗口关闭 (在飞>=帽, P5b 闭环): 收尾当前帧后静默, 窗口重开 ⇒ frm_wait
    //       解除, 下一帧从 remain 续 (不丢字节、不发空帧);
    //     - 连接拆除/DEL (state!=ESTAB): 同上, 且随后 ev_up 会重启会话。
    //  默认协议语义: tx_ok 恢复即可继续 (窗口型), 同槽 ev_up 则换流 (会话型)。
    wire        tx_ok = app_tx_ready[act_id];   // 16:1 mux, 纯控制路径 (不进 m_* 数据路)

    // ---------------- P5e: 每帧首字 = 0 载荷 opener (结构性根除跨会话载荷泄漏) ----
    // 残余缺陷 (P5d-D2 的帧启动门修不掉的那一条, 只在"帧边界 + pipe 前瞻"窄窗):
    //   app 的呈交口对 axis_pipe 有 1 拍前瞻 (pipe.s_ready = m_ready || !m_valid)。
    //   帧 N 的末字被**帧器**(S_RECV, tready=1) 收走的同一拍, pipe 就把 app 摊开的
    //   **帧 N+1 首字**锁存了 —— 而此后帧器要花 S_WAIT/S_HDR/S_PAY ≈195 拍把帧 N
    //   发上线, 这段时间它一个 beat 都不收。 ⇒ 帧 N+1 的首字在 pipe 里滞留 ~195 拍
    //   (占帧周期 ~13%, 不是"极窄")。若这期间连接被 fence/拆除后**重建** (新会话,
    //   新 ISN), 帧器一回到 S_IDLE 就把这个滞留字当**新会话首帧的首字**收下:
    //     - 无 opener: 它是 8 字节**旧流载荷** ⇒ 对新会话 = 8 字节陈旧载荷 + 整段
    //       图案偏移 8 (D1 观测到的 "8B 循环移位 / 计数差 8" 就是这个);
    //     - 有 opener: 它是 0 载荷占位字 (tkeep=8'h00) ⇒ 对新会话只是"预开一帧":
    //       帧器 `accept` 只按 pop8(keep) 计长 (L598 plen_n / L538 wr_tap / L577 wr
    //       全部 `tkeep != 0` 门), 该字不入 FIFO、不进 ring、不推进 plen/tap_seq
    //       ⇒ seq 仍取**收下那一拍**的 snd_nxt (新会话 ISN), 载荷从新会话起点算。
    //   触发面无关于哪种 fence: abort (rst_req/rst_sent)、窗口关、DEL 都行 ——
    //   app_tx_ready 的 ESTAB 项是 256 拍轮扫快照 (拆除后最多 256 拍 app 仍见
    //   tx_ok=1), 而帧器的启动门 `st_ok` 是 rb_state **活读** ⇒ 同型窗口。
    //   为什么不能靠 flush/撤回: app 撤不回已交给 pipe 的字, axis_pipe 也没有 flush
    //   口 (加 flush 要动 wrapper 例化)。把首字做成"无载荷"是同一效果的**结构性**解。
    // 帧器语义复核 (逐行走过 rtl/tcp_tx_frame.v, 帧首 keep=0 与 W3 帧尾 keep=0 不同):
    //   S_IDLE + start_data + accept + keep=0 + !tlast ⇒ plen<=0, tap_seq<=rb_snd_nxt,
    //   state<=S_RECV (L973-985); 帧器**不**认为"没载荷"而提前收帧 (只有 tlast 才收),
    //   故后续真实载荷字照常追加 (S_RECV 的 accept 子句不含 tx_blk/wnd ⇒ 只判
    //   state==S_RECV && !pay_full) ⇒ 帧 = [空首拍][载荷...], plen = 载荷字节数 ✓。
    //   代价 1 拍/帧 (帧周期 ~1650 拍) ⇒ 可忽略。时序上只是 m_* 多一层寄存器级 mux。
    wire [11:0] left     = seg_len - seg_sent;                 // 本帧剩余字节
    wire [3:0]  need     = (left >= 12'd8) ? 4'd8 : left[3:0]; // 本字字节数
    // opener 呈交 (帧首字): 装配必须等它落地 (!op_pend), closing 期间不摊开 (见 W3:
    // 收尾路径要独占呈交口, 且此时"还没交付过任何字"⇒ 直接回 idle 才是对的)。
    // seg_len=0 (TX_BYTES=0 退化) 不发 opener: 那种会话线上不该出现任何帧。
    wire        op_beat   = op_pend && !pw_valid && !closing && (seg_len != 12'd0);
    // 本帧"已有字交付给 pipe" = opener 已交付 或 已有载荷字节交付。装配门/W3 收尾
    // 都用它 —— 语义从"帧已在帧器里"精确前移到"帧首字已不可撤回" (同一条理由:
    // 已经进了 pipe 的字收不回来 ⇒ 已开始的帧必须走完 tlast, 否则帧器停 S_RECV)。
    wire        frm_inflight = op_sent || (seg_sent != 12'd0);
    // P5e 收尾字重定义 (两条都是"帧首字已不可撤回"的直接推论):
    //   drop_pw  : 收尾时呈交口的字**若本帧一个载荷字节都还没交付** (seg_sent==0)
    //     ⇒ 该字是帧首字 (opener 之后的第一个载荷字), 且它**从未被计数** (计数在
    //     交付拍) ⇒ 直接撤掉, 改用 0 载荷 + tlast 收尾字闭合本帧。理由: 这个字是
    //      上一会话图案流的一段, 拆连/换流时放任它交付 = 新会话首帧前 8 字节是旧
    //      载荷 (与 pipe 残余字同族的泄漏, 只是路径从 pipe 换成 W3 主动交付)。
    //     撤掉零代价: 没计过数 ⇒ remain/stat_tx_bytes 不用回退, 该字节会随新会话
    //      从图案起点重发。
    //   close_send: 本拍发 0 载荷 + tlast 收尾字 (帧器可能已把 opener 收下并停在
    //     S_RECV ⇒ 必须补 tlast, 否则下一个 beat 会被当续载荷吞掉)。
    wire        drop_pw    = closing && pw_valid && (seg_sent == 12'd0);
    wire        close_send = closing && !op_beat &&
                             (drop_pw || (!pw_valid &&
                                          (op_sent || (seg_sent != 12'd0))));
    // ---- P5e: 会话换流 (ev_up) 与 W3 收尾同拍撞车 ----
    // ev_up 落在 closing 拍 (拆连后 app 正等 pipe 交付收尾字) 是真实时序: 慢路径的
    // 拆连→重建间隔 ~70 拍, 而 app 的收尾要等帧器把上一帧发完 (~195 拍) ⇒ 两事件
    // 天然共用同一窗口。撞车时必须换流优先 (W3 块让位, 见 `if (closing && !ev_restart)`):
    // ev_up 是脉冲、错过就没了 —— 旧行为 (判据不含 seg_sent==0) 会把 app 收尾完
    // 直接 idle, 新会话一帧都上不去。而呈交口的旧流载荷字已由 drop_pw 撤成 0 载荷,
    // pipe 本拍纵使 s_ready (帧器已收下 opener 在 S_RECV 等) 也只会装到收尾字 ✓。
    wire        ev_restart = ev_up && (!active || ((ev_slot == act_id) &&
                             (frm_wait || (seg_sent == 12'd0))));
    wire        rst_close  = ev_restart && closing && !op_beat &&
                             (pw_valid || close_send);
    // 本帧"已在飞" (frm_inflight): 把装配分成两段:
    //   - 新帧的第一个字 (seg_sent==0 且 opener 未交付): 必须 tx_ok —— 否则"新会话
    //     首字"会落进 pipe 成为残余字 (P5d-D2 修复的主目标);
    //   - 帧内续字: 不看 tx_ok —— 帧首字一进 pipe 就**必须收尾** (见 frm_inflight)。
    // 两段拼接即"启动门 + 强制收尾", 且交付给 app 的计数只在**确实交付**时推进
    // (pw_valid && m_tready) ⇒ pipe 里的字与 stat_tx_bytes 天然不会差 8。
    wire        asm_go   = active && !pw_valid && !closing && !frm_wait && !op_pend &&
                           (frm_inflight || tx_ok || (remain == 32'd0));

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
    // P5e opener: 帧首字 = {tdata=0, tkeep=8'h00, tlast=0} 的 0 载荷占位字。
    // W3 收尾: closing 期间 (a) 若已有字在呈交, 该字强带 tlast (帧在此闭合,
    // 载荷 = 图案前缀); (b) 若正装配中 (无字), 合成一个 keep=0 + tlast 的收尾字
    // (tcp_tx_frame 的 accept 只按 pop8(keep)=0 计长, 不入 FIFO 不推进 plen)。
    // (op_beat 与 close_send 互斥: 前者带 !closing, 后者带 closing ⇒ 两个 0 载荷
    //  字不会叠加成两个 beat。op_beat 与 pw_valid 也互斥 ⇒ m_tlast 的优先级无歧义)
    assign m_tdata  = (op_beat || close_send) ? 64'd0 : pw_data;
    assign m_tkeep  = (op_beat || close_send) ? 8'h00 : pw_keep;
    assign m_tvalid = op_beat || pw_valid || close_send;
    assign m_tlast  = op_beat ? 1'b0 : (close_send || pw_last || closing);
    assign m_tid    = act_id;

    integer ii;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_lfsr <= SEED; remain <= 32'd0; seg_len <= 12'd0; seg_sent <= 12'd0;
            bcnt <= 4'd0; stg <= 64'd0;
            pw_data <= 64'd0; pw_keep <= 8'h00; pw_n <= 4'd0; pw_last <= 1'b0;
            pw_valid <= 1'b0; bad_frm <= 1'b0; frm_idx <= 16'd0; closing <= 1'b0;
            frm_wait <= 1'b0; op_pend <= 1'b0; op_sent <= 1'b0;
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
                // 新连接: 启动图案发送 (单会话; 其它槽的新事件忽略)
                // P5d-D2: 同槽 ev_up = **新会话** (对端按连接起点认图案流; 继续旧
                // 流会让对端整段错位, 见 tools/cpp_peer --expect-pattern), 故旧
                // 会话即使还 active (被 abort fence 卡住的场景) 也必须换流重启。
                // 重启前提 = 旧帧**已交付完** (frm_wait / idle): 半帧重启会把帧器
                // 丢在 S_RECV 等 tlast。
                // P5e: 判据扩一项 `seg_sent == 0` (本帧**一个载荷字节都没交付**)。
                //   这一项正是 opener 方案的收尾: 帧首字被做成 0 载荷后, "旧会话的
                //   残留字"里已不可能有载荷 ⇒ 只要本帧的载荷还没出手, 换流就是干净
                //   的 (对齐 TL 语义: seq/载荷都从新会话起点算)。没有它, DEL 场景
                //   会退化: ev_down(拆连) 把 app 推进 closing 等 pipe 交付, ev_up
                //   (重建) 落在同拍 → 旧判据不认 (frm_wait=0 且 active=1) ⇒ app
                //   错过事件脉冲、收尾完直接 idle 死掉 (新会话一帧都上不去)。
                //   为什么安全: 交付是**逐字计数**的 (pw_valid && m_tready ⇒
                //   seg_sent += pw_n), 而 pipe 是 1 深且只在 s_ready 拍装载 ⇒
                //   seg_sent==0 ⇒ 本帧没有任何载荷字进过 pipe (帧器更不可能有)。
                //   唯一在呈交口未落地的载荷字 (pw_valid=1) 下面显式撤掉。
                if (!active || ((ev_slot == act_id) &&
                                (frm_wait || (seg_sent == 12'd0)))) begin
                    active   <= 1'b1;
                    act_id   <= ev_slot;
                    remain   <= TX_BYTES;
                    tx_lfsr  <= SEED;
                    frm_idx  <= 16'd0;
                    // P5e: 未落地的载荷字必须撤 (seg_sent==0 的换流路径下它可能正
                    //   摊在呈交口): 它没被计数过、pipe 也没装载 (装载即计数) ⇒
                    //   撤回不丢字节、不破坏 AXIS 数据 (下游只看 s_ready 拍)。
                    pw_valid <= 1'b0;
                    op_pend  <= 1'b1;   // 新会话首帧同样以 opener 起
                    op_sent  <= 1'b0;
                    // P5e: 撞车拍 (本拍同时闭合旧帧: close_send 的 0 载荷收尾字
                    // 已交付) 的帧计数不能漏 (W3 块已让位给本次换流)。
                    if (rst_close && m_tready)
                        stat_tx_frames <= stat_tx_frames + 32'd1;
                    // P5d-D2: `done` 不再被新会话清 0 —— 语义是"app 至少跑完过
                    // 一轮" (checker 原话"app 未跑完一轮"), 逐会话清零会让
                    // "最后一段是 abort/拆连"的正常场景误报未完成。
                    // (默认单会话门: 只有一次 ev_up ⇒ 与旧行为逐位相同)
                    frm_wait <= 1'b0;
                    closing  <= 1'b0;
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
            // P5e: 换流撞车拍 (ev_restart) 由上面的 ev_up 块接管 (它撤字 + 发
            // close_send 的 0 载荷收尾字闭合本帧) ⇒ 本块让位, 否则同拍双写会把
            // 换流的赋值盖掉 (块序在 Verilog 里就是优先级: ev_up 块在前 ⇒ 必须
            // 显式让位, 不能靠先后)。
            if (closing && !ev_restart) begin
                if (pw_valid && !drop_pw) begin
                    // 已有字在呈交且本帧**有**载荷: m_tlast 组合含 closing -> 该字
                    // 带 tlast 被消费即闭合 (载荷 = 图案前缀, 逐字节判据不破)
                    if (m_tready) begin
                        pw_valid <= 1'b0; closing <= 1'b0; active <= 1'b0;
                        op_pend <= 1'b0; op_sent <= 1'b0;
                        stat_tx_frames <= stat_tx_frames + 32'd1;
                    end
                end else if (close_send) begin
                    // 0 载荷收尾字 (含 drop_pw 撤字拍): 帧器若已收下 opener 停在
                    // S_RECV, 这个 tlast 就是唯一出路
                    if (m_tready) begin
                        pw_valid <= 1'b0; closing <= 1'b0; active <= 1'b0;
                        op_pend <= 1'b0; op_sent <= 1'b0;
                        stat_tx_frames <= stat_tx_frames + 32'd1;
                    end
                end else begin
                    // 本帧尚无**任何字**交付 (op_sent=0 且 seg_sent=0; op_beat 被
                    // !closing 挡住 ⇒ 本拍不会摊开 opener): 帧器未开帧, 直接回
                    // idle, 不发空帧。
                    closing <= 1'b0; active <= 1'b0; op_pend <= 1'b0; op_sent <= 1'b0;
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
                        op_pend <= 1'b0; op_sent <= 1'b0;
                        if (AUTO_CLOSE) begin
                            close_req <= 1'b1;
                            close_id  <= act_id;
                        end
                    end else if (tx_ok) begin
                        // 下一帧长度 (坏帧注入: 第 i_bad_frame 帧)
                        bad_frm <= (i_bad_frame != 16'd0) &&
                                   ((frm_idx + 16'd1) == i_bad_frame);
                        seg_len <= ((i_bad_frame != 16'd0) &&
                                    ((frm_idx + 16'd1) == i_bad_frame)) ? BAD_LEN :
                                   ((remain > {20'b0, TX_SEGSZ}) ? TX_SEGSZ : remain[11:0]);
                        seg_sent <= 12'd0;
                        bcnt <= 4'd0;
                        // P5e: 新帧先发 0 载荷 opener (帧首字), 载荷等它落地
                        op_pend <= 1'b1; op_sent <= 1'b0;
                    end else begin
                        // P5d-D2: 连接不可发 (abort fence / 窗口关 / 拆连) ⇒ 不再
                        // 启动新帧。**本帧已完整交付** (上面 else-if 分支只在
                        // need==0 且 remain!=0 时到达), 故此刻 app 侧没有在飞字:
                        // pipe 里不会留下任何"下一帧首字"给新会话继承 —— D1 曝光
                        // 的 8B 循环移位/计数差 8/pat_done=0 三条的根因即此处。
                        // 静默等 tx_ok 恢复 (窗口重开) 或同槽新会话 (ev_up 重启)。
                        frm_wait <= 1'b1;
                    end
                end else if (bcnt < need) begin
                    bcnt    <= bcnt + 4'd1;
                    stg     <= stg_n;
                    if (!bad_frm) tx_lfsr <= xs_next(tx_lfsr);
                end
            end
            // ---- P5d-D2: frm_wait 解除 (tx_ok 恢复 ⇒ 启动下一帧, 从 remain 续) ----
            // 与上面的帧启动门**同一组赋值** (只在 frm_wait 拍生效, 而 asm_go 在
            // frm_wait 拍恒 0 ⇒ 两者互斥, 不会同拍双写)。
            if (frm_wait && tx_ok) begin
                frm_wait <= 1'b0;
                bad_frm  <= (i_bad_frame != 16'd0) &&
                            ((frm_idx + 16'd1) == i_bad_frame);
                seg_len  <= ((i_bad_frame != 16'd0) &&
                             ((frm_idx + 16'd1) == i_bad_frame)) ? BAD_LEN :
                            ((remain > {20'b0, TX_SEGSZ}) ? TX_SEGSZ : remain[11:0]);
                seg_sent <= 12'd0;
                bcnt     <= 4'd0;
                op_pend  <= 1'b1; op_sent <= 1'b0;   // P5e: 同样以 opener 起帧
            end
            // ---- P5e: opener 交付 (帧首字落地 = 帧已"预开") ----
            // 交付判据与载荷字同一条 (pw_valid && m_tready 的镜像): m_tready 就是
            // axis_pipe 的 s_ready ⇒ 该拍 pipe 会把这个 0 载荷字装进它的 1 深寄存器。
            // op_pend 清掉后 m_tvalid 转为载荷字 (组合输出, 无空拍; 载荷装配要 8 拍,
            // 期间 m_tvalid=0 是正常的 —— 帧器此时在 S_IDLE 等帧首字)。
            if (op_beat && m_tready) begin
                op_pend <= 1'b0;
                op_sent <= 1'b1;
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
