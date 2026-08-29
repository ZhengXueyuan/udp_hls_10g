`timescale 1ns/1ps
// 帧级分流器: mac_rx_64 之后的 fast/slow 路由 (P4 慢路径入口)。
//   ethertype @ w1[31:16] (byte 12-13), proto @ w2[7:0] (byte 23)
//   路由: ethertype==0x0800 && proto==6 -> fast (TCP); 其他全部 -> slow
// 3 字 skid 缓冲 w0..w2, 定路由后倒空再 cut-through; runt (<3 字即 tlast) 一律 slow。
// DRAIN 期间 s_tready=0 (<=3 拍/帧, 由 mac_rx_64 的 8 深 FIFO 吸收; 1G 字流天然
// >=3 拍帧间隔, stall 实际不传播。10G min-frame 洪泛极限场景: mac 层计数丢帧 — P6 复审)。
module rx_classify (
    input  wire        clk,
    input  wire        rst_n,
    // 来自 mac_rx_64
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,   // SOP
    input  wire        s_axis_tcrs,    // TLAST: FCS 正确
    input  wire        s_axis_terr,    // TLAST: 帧内 rx_er
    // fast 路由 (TCP)
    output wire [63:0] m_fast_tdata,
    output wire [7:0]  m_fast_tkeep,
    output wire        m_fast_tvalid,
    input  wire        m_fast_tready,
    output wire        m_fast_tlast,
    output wire        m_fast_tuser,
    output wire        m_fast_tcrs,
    output wire        m_fast_terr,
    // slow 路由 (慢路径 HLS)
    output wire [63:0] m_slow_tdata,
    output wire [7:0]  m_slow_tkeep,
    output wire        m_slow_tvalid,
    input  wire        m_slow_tready,
    output wire        m_slow_tlast,
    output wire        m_slow_tuser,
    output wire        m_slow_tcrs,
    output wire        m_slow_terr,
    output reg  [31:0] stat_fast,
    output reg  [31:0] stat_slow
);
    localparam S_FILL = 2'd0, S_DRAIN = 2'd1, S_PASS = 2'd2;
    localparam RT_FAST = 1'b0, RT_SLOW = 1'b1;

    reg [1:0]  state;
    reg        route;
    reg [2:0]  n;            // skid 有效字数 (0..3)
    // skid 字 = {tdata, tkeep, tlast, tuser, tcrs, terr} 共 76 位
    reg [63:0] sk_d [0:2];
    reg [7:0]  sk_k [0:2];
    reg        sk_l [0:2];
    reg        sk_u [0:2];
    reg        sk_c [0:2];
    reg        sk_e [0:2];

    // w2 拍决策: w1 在 sk_d[1], w2 = 当前 s_axis_tdata
    wire is_tcp = (sk_d[1][31:16] == 16'h0800) && (s_axis_tdata[7:0] == 8'd6);

    wire out_fast = (route == RT_FAST);
    wire m_tready_sel = out_fast ? m_fast_tready : m_slow_tready;

    // 输出字: DRAIN 来自 skid 头, PASS 直通输入
    wire [63:0] o_d = (state == S_DRAIN) ? sk_d[0] : s_axis_tdata;
    wire [7:0]  o_k = (state == S_DRAIN) ? sk_k[0] : s_axis_tkeep;
    wire        o_l = (state == S_DRAIN) ? sk_l[0] : s_axis_tlast;
    wire        o_u = (state == S_DRAIN) ? sk_u[0] : s_axis_tuser;
    wire        o_c = (state == S_DRAIN) ? sk_c[0] : s_axis_tcrs;
    wire        o_e = (state == S_DRAIN) ? sk_e[0] : s_axis_terr;
    wire        o_v = (state == S_DRAIN) ? 1'b1 :
                      (state == S_PASS)  ? s_axis_tvalid : 1'b0;

    assign m_fast_tdata  = o_d;
    assign m_fast_tkeep  = o_k;
    assign m_fast_tlast  = o_l;
    assign m_fast_tuser  = o_u;
    assign m_fast_tcrs   = o_c;
    assign m_fast_terr   = o_e;
    assign m_fast_tvalid = o_v && out_fast;
    assign m_slow_tdata  = o_d;
    assign m_slow_tkeep  = o_k;
    assign m_slow_tlast  = o_l;
    assign m_slow_tuser  = o_u;
    assign m_slow_tcrs   = o_c;
    assign m_slow_terr   = o_e;
    assign m_slow_tvalid = o_v && !out_fast;

    assign s_axis_tready = (state == S_FILL) ? 1'b1 :
                           (state == S_PASS) ? m_tready_sel : 1'b0;

    wire s_acc = s_axis_tvalid && s_axis_tready;          // 输入接受
    wire o_acc = o_v && m_tready_sel;                     // 输出接受 (DRAIN/PASS)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_FILL; route <= RT_SLOW; n <= 3'd0;
            stat_fast <= 0; stat_slow <= 0;
        end else begin
            case (state)
                S_FILL: if (s_acc) begin
                    sk_d[n[1:0]] <= s_axis_tdata;
                    sk_k[n[1:0]] <= s_axis_tkeep;
                    sk_l[n[1:0]] <= s_axis_tlast;
                    sk_u[n[1:0]] <= s_axis_tuser;
                    sk_c[n[1:0]] <= s_axis_tcrs;
                    sk_e[n[1:0]] <= s_axis_terr;
                    if (s_axis_tlast) begin
                        route <= RT_SLOW;            // runt: 无法判 proto -> slow
                        n <= n + 3'd1;
                        state <= S_DRAIN;
                    end else if (n == 3'd2) begin
                        route <= is_tcp ? RT_FAST : RT_SLOW;
                        n <= 3'd3;
                        state <= S_DRAIN;
                    end else begin
                        n <= n + 3'd1;
                    end
                end
                S_DRAIN: if (o_acc) begin
                    if (sk_l[0]) begin               // 帧尾在 skid 内
                        state <= S_FILL; n <= 3'd0;
                        if (out_fast) stat_fast <= stat_fast + 1;
                        else          stat_slow <= stat_slow + 1;
                    end else begin
                        sk_d[0] <= sk_d[1]; sk_d[1] <= sk_d[2];
                        sk_k[0] <= sk_k[1]; sk_k[1] <= sk_k[2];
                        sk_l[0] <= sk_l[1]; sk_l[1] <= sk_l[2];
                        sk_u[0] <= sk_u[1]; sk_u[1] <= sk_u[2];
                        sk_c[0] <= sk_c[1]; sk_c[1] <= sk_c[2];
                        sk_e[0] <= sk_e[1]; sk_e[1] <= sk_e[2];
                        n <= n - 3'd1;
                        if (n == 3'd1) state <= S_PASS;  // skid 空, 帧身切直通
                    end
                end
                S_PASS: if (s_acc && s_axis_tlast) begin
                    state <= S_FILL;
                    if (out_fast) stat_fast <= stat_fast + 1;
                    else          stat_slow <= stat_slow + 1;
                end
                default: state <= S_FILL;
            endcase
        end
    end
endmodule
