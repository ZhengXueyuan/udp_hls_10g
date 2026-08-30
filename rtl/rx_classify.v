`timescale 1ns/1ps
// 帧级分流器: mac_rx_64 之后的 fast/slow 路由 (P4 慢路径入口)。
//   ethertype @ w1[31:16] (byte 12-13), proto @ w2[7:0] (byte 23),
//   TCP flags @ w5[7:0] (byte 47)
//   路由: 非 IPv4/TCP -> slow; TCP 且 SYN|FIN|RST (w5 拍决策) -> slow (P4b:
//   握手/拆除归慢路径 HLS); TCP 数据/纯 ACK -> fast。
// 6 字 skid: 非 TCP 在 w2 拍定案 (3 字倒空即直通); TCP 等到 w5 (6 字)。
// TCP 帧最小 54B 头 => 恒 >=7 字, w5 必存在; 提前 tlast 的残缺帧兜底 slow。
// DRAIN 期间 s_tready=0 (<=6 拍/帧, 由 mac_rx_64 的 8 深 FIFO 吸收; 1G 字流
// 天然 >=6 拍帧间隔, stall 不传播。10G min-frame 洪泛极限场景: mac 层计数
// 丢帧 — P6 复审 (skid 改真 FIFO 已记入 P6 清单)。
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
    // fast 路由 (TCP 数据面)
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
    reg        wait_w5;      // 本帧是 TCP: 等 w5 flags 再定路由
    reg [3:0]  n;            // skid 有效字数 (0..6)
    // skid 字 = {tdata, tkeep, tlast, tuser, tcrs, terr} 共 76 位
    reg [63:0] sk_d [0:5];
    reg [7:0]  sk_k [0:5];
    reg        sk_l [0:5];
    reg        sk_u [0:5];
    reg        sk_c [0:5];
    reg        sk_e [0:5];

    // w2 拍 (n==2 接受): w1 在 sk_d[1], w2 = 当前 s_axis_tdata
    wire is_ipv4 = (sk_d[1][31:16] == 16'h0800);
    wire is_tcp  = is_ipv4 && (s_axis_tdata[7:0] == 8'd6);
    // w5 拍 (n==5 接受): flags = 当前 s_axis_tdata[7:0] (byte 47)
    wire tcp_ctl = |{s_axis_tdata[2], s_axis_tdata[1], s_axis_tdata[0]};
    //                                        // RST(bit2) SYN(bit1) FIN(bit0)

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

    integer ii;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_FILL; route <= RT_SLOW; wait_w5 <= 1'b0; n <= 4'd0;
            stat_fast <= 0; stat_slow <= 0;
        end else begin
            case (state)
                S_FILL: if (s_acc) begin
                    sk_d[n[2:0]] <= s_axis_tdata;
                    sk_k[n[2:0]] <= s_axis_tkeep;
                    sk_l[n[2:0]] <= s_axis_tlast;
                    sk_u[n[2:0]] <= s_axis_tuser;
                    sk_c[n[2:0]] <= s_axis_tcrs;
                    sk_e[n[2:0]] <= s_axis_terr;
                    if (s_axis_tlast) begin
                        route <= RT_SLOW;            // 残缺/runt: slow
                        n <= n + 4'd1;
                        state <= S_DRAIN;
                    end else if (n == 4'd2 && !wait_w5) begin
                        if (is_tcp) begin
                            wait_w5 <= 1'b1;         // TCP: 等 w5 flags
                            n <= n + 4'd1;
                        end else begin
                            route <= RT_SLOW;        // 非 TCP: w2 拍定案
                            n <= n + 4'd1;
                            state <= S_DRAIN;
                        end
                    end else if (n == 4'd5) begin
                        route <= tcp_ctl ? RT_SLOW : RT_FAST;
                        n <= 4'd6;
                        state <= S_DRAIN;
                        wait_w5 <= 1'b0;
                    end else begin
                        n <= n + 4'd1;
                    end
                end
                S_DRAIN: if (o_acc) begin
                    if (sk_l[0]) begin               // 帧尾在 skid 内
                        state <= S_FILL; n <= 4'd0; wait_w5 <= 1'b0;
                        if (out_fast) stat_fast <= stat_fast + 1;
                        else          stat_slow <= stat_slow + 1;
                    end else begin
                        for (ii = 0; ii < 5; ii = ii + 1) begin
                            sk_d[ii] <= sk_d[ii+1]; sk_k[ii] <= sk_k[ii+1];
                            sk_l[ii] <= sk_l[ii+1]; sk_u[ii] <= sk_u[ii+1];
                            sk_c[ii] <= sk_c[ii+1]; sk_e[ii] <= sk_e[ii+1];
                        end
                        n <= n - 4'd1;
                        if (n == 4'd1) state <= S_PASS;  // skid 空, 帧身切直通
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
