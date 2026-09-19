`timescale 1ns/1ps
// vlan_strip — fast path 单层 VLAN (802.1Q 0x8100 / 802.1ad 0x88A8) 剥离 shim。
// 位置: mac_rx_64 (m_axis) -> vlan_strip -> rx_classify (s_axis)。端口 = mac_rx_64
// 输出侧 AXIS 同款 (tdata/tkeep/tvalid/tready/tlast/tuser/tcrs/terr)。
//
// 目的: rx_classify 按"无 tag"字节布局判定 (ethertype @ w1[31:16] = byte 12-13),
//   带 tag 帧的 TPID 恰好落在这个位置 -> 判非 IPv4 -> 全走慢路径。本模块把 tag
//   (TPID+TCI, 4 字节) 从字节流里删掉再交给 rx_classify, 使带 tag 的 TCP 数据帧
//   回到无 tag 布局: ethertype 回到 byte 12-13, IP 头回到 byte 14 -> fast 路
//   (rx_classify/tcp_rx 载荷偏移 54B) 与非 tag 帧完全一致。
//
// 字节映射 (tdata[63:56] = 帧首字节, 字内字节从高到低):
//   out byte m = in byte m     (m <  12)   // dst + src 前 12B 原样
//   out byte m = in byte m + 4 (m >= 12)   // 剥掉 in byte 12..15 = TPID + TCI
// 展开成输出字 (左对齐 64bit 字流):
//   out_w0        = in_w0                            // SOP 字原样
//   out_w1        = {in_w1[63:32], in_w2[63:32]}     // 12B 头 + 新 ethertype (边界字)
//   out_wk (k>=2) = {in_w{k-1}[31:0], in_w{k}[63:32]}  // 半字错位拼接 (4B 左移)
// tkeep: out_keep = {hold_keep, in_keep[k][7:4]}, hold_keep = tag 字 in_keep[7:4]
//   (k=1) 或 in_keep[k-1][3:0] (k>=2) — 与上式同源, 高半来自 hold, 低半来自当前字。
//
// tlast 边界 (剥后帧短 4B, 输出帧比输入帧少 0 或 1 个字):
//   (a) 末输入字 in_keep[3:0] == 0 (帧长 mod 8 = 1..4): 末输出字 = 本拍拼出的字,
//       tlast 同拍落在该字, 无尾拍。
//   (b) 末输入字 in_keep[3:0] != 0: 该字低 4 字节内容自成尾字 (低半字无效,
//       keep = {in_keep[3:0], 4'b0}), 在 tlast 后一拍 (S_TAIL) 输出; 该拍
//       s_axis_tready = 0 (1 拍, 由 mac_rx_64 的 8 深 FIFO 吸收)。
//
// 时序/吞吐: 非 VLAN 帧 = 1 拍寄存直通 (II=1, 无气泡, 1-deep 弹性)。
//   VLAN 帧 = 剥 4 字节需要半个字拍的时间, 在 tag 字处产生 1 拍输出气泡 (S_W1
//   不装载输出寄存器); 帧尾至多多 1 拍 (S_TAIL)。1G 字流帧间隔 (IFG >= 1.5 字拍)
//   与上游 8 深 FIFO 天然吸收 ≤2 拍的额外停顿, 帧率不受影响。
//   背压合同: s_axis_tready = od_free = (!m_axis_tvalid || m_axis_tready) —
//   下游每拍能吞则本模块每拍能吞 (只延迟不缓冲), 下游停则上游停, 不丢字。
//
// QinQ (双层 tag, 802.1ad): 剥一层后内层 TPID 仍落 byte 12-13 -> rx_classify 判
//   非 IPv4 -> 自然退化走慢路径 (HLS 慢路径支持多层 802.1Q/1ad), 本模块不显式
//   处理也不误判 (只剥"恰好一层")。
// runt/异常: VLAN 帧最小 64B (60B 无 tag 最小帧 + 4B tag) => w1 拍恒非 tlast,
//   若 w1 拍即 tlast (残缺帧) 则按非 VLAN 直通; 帧内出现 SOP (tuser, 上游截断
//   残段) 则中止剥离支, 该字按新帧首字直通 (重置到 S_W1), 不会永久卡死。
// 尾字对齐已核: 剥后帧 >= 56B (原 >= 60B), 输出 keep 恒为连续高位有效。

module vlan_strip (
    input  wire        clk,
    input  wire        rst_n,
    // 来自 mac_rx_64 (m_axis)
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,   // SOP
    input  wire        s_axis_tcrs,    // 与 tlast 同拍: FCS 正确
    input  wire        s_axis_terr,    // 与 tlast 同拍: 帧内 rx_er
    // 下游 (rx_classify s_axis)
    output reg  [63:0] m_axis_tdata,
    output reg  [7:0]  m_axis_tkeep,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,
    output reg         m_axis_tuser,
    output reg         m_axis_tcrs,
    output reg         m_axis_terr,
    // 统计/调试
    output reg  [31:0] stat_stripped,  // VLAN 帧剥离计数 (帧尾拍 +1)
    output reg         dbg_vlan        // 当前帧处于剥离支 (调试观测)
);

    localparam [1:0] S_PASS  = 2'd0,   // 直通 (帧首字/非 VLAN 帧体)
                     S_W1    = 2'd1,   // 帧第 2 字: 判 TPID, 决 VLAN/非 VLAN
                     S_SHIFT = 2'd2,   // VLAN 剥离支: 半字错位拼接
                     S_TAIL  = 2'd3;   // VLAN 尾字 (末输入字低半字单独成字)

    reg [1:0]  state;
    reg [31:0] hold;         // 待拼入下一输出字高半的 4 字节
    reg [3:0]  hold_keep;    // 对应 keep (4 位)
    reg        tail_crs, tail_err;   // 尾字沿用末输入字的 tlast 侧带

    wire [31:0] cur_hi = s_axis_tdata[63:32];
    wire [31:0] cur_lo = s_axis_tdata[31:0];
    // byte 12-13 = 字流第 2 字高 2 字节 (与 rx_classify 的 w1[31:16] 同一位置)
    wire        is_vlan = (s_axis_tdata[31:16] == 16'h8100) ||
                          (s_axis_tdata[31:16] == 16'h88A8);
    // 输出寄存器可装载: 空 或 本拍被下游取走 (1-deep 弹性, 上游 tready 同源)
    wire        od_free = !m_axis_tvalid || m_axis_tready;
    wire        acc     = s_axis_tvalid && s_axis_tready;
    // tlast 落在本拍拼出的输出字 (末输入字低半无有效字节)
    wire        last_now = s_axis_tlast && (s_axis_tkeep[3:0] == 4'b0);
    // S_W1 进剥离支 (帧第 2 字 + TPID 命中 + 非尾拍 + 正常续帧)
    wire        vlan_go  = is_vlan && !s_axis_tlast && !s_axis_tuser;
    // S_SHIFT 正常拼接拍 (tuser = 上游截断残段 -> 走直通恢复支)
    wire        shifting = (state == S_SHIFT) && !s_axis_tuser;

    // 输出寄存器装载条件 (装载拍即输出字成形拍, 字在下一拍出现在 m_axis)
    wire        load_pass  = (state == S_PASS)  && acc;
    wire        load_w1    = (state == S_W1)    && acc && !vlan_go;
    wire        load_shift = (state == S_SHIFT) && acc;
    wire        load_tail  = (state == S_TAIL)  && od_free;
    wire        od_load    = load_pass || load_w1 || load_shift || load_tail;

    assign s_axis_tready = (state == S_TAIL) ? 1'b0 : od_free;

    // ---- 输出字成形 ----
    reg [63:0] nd;
    reg [7:0]  nk;
    reg        nl, nu, nc, ne;
    always @(*) begin
        if (state == S_TAIL) begin
            // 尾字: 末输入字低 4 字节内容, 低半字无效 (keep = {hold_keep, 4'b0})
            nd = {hold, 32'b0};
            nk = {hold_keep, 4'b0};
            nl = 1'b1; nu = 1'b0; nc = tail_crs; ne = tail_err;
        end else if (shifting) begin
            // 剥离拼字: 高半 = hold, 低半 = 当前字高半 (4B 左移)
            nd = {hold, cur_hi};
            nk = {hold_keep, s_axis_tkeep[7:4]};
            nl = last_now; nu = 1'b0;
            nc = last_now && s_axis_tcrs;   // tcrs/terr 仅 tlast 拍有效
            ne = last_now && s_axis_terr;
        end else begin
            // 直通拍 (S_PASS / S_W1 / S_SHIFT 的 tuser 恢复支)
            nd = s_axis_tdata; nk = s_axis_tkeep;
            nl = s_axis_tlast; nu = s_axis_tuser;
            nc = s_axis_tcrs; ne = s_axis_terr;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_PASS;
            hold <= 32'd0; hold_keep <= 4'd0;
            tail_crs <= 1'b0; tail_err <= 1'b0;
            m_axis_tdata <= 64'd0; m_axis_tkeep <= 8'd0;
            m_axis_tvalid <= 1'b0; m_axis_tlast <= 1'b0;
            m_axis_tuser <= 1'b0; m_axis_tcrs <= 1'b0; m_axis_terr <= 1'b0;
            stat_stripped <= 32'd0; dbg_vlan <= 1'b0;
        end else begin
            // ---- 输出寄存器 (1-deep 弹性) ----
            if (od_load) begin
                m_axis_tdata  <= nd;
                m_axis_tkeep  <= nk;
                m_axis_tlast  <= nl;
                m_axis_tuser  <= nu;
                m_axis_tcrs   <= nc;
                m_axis_terr   <= ne;
                m_axis_tvalid <= 1'b1;
            end else if (m_axis_tvalid && m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
            end

            // ---- 半字暂存 (hold): 只在剥离支装载 ----
            if ((state == S_W1) && acc && vlan_go) begin
                // tag 字: 高半字进 hold (低半字 = TCI 丢弃), 本拍不产生输出字
                hold      <= cur_hi;
                hold_keep <= s_axis_tkeep[7:4];
            end else if (shifting && acc) begin
                // 剥离支常规拍: 本字低半字成为下一输出字的高半
                hold      <= cur_lo;
                hold_keep <= s_axis_tkeep[3:0];
                tail_crs  <= s_axis_tcrs;
                tail_err  <= s_axis_terr;
            end

            // ---- 帧状态机 ----
            case (state)
                S_PASS: if (acc) begin
                    state <= (s_axis_tuser && !s_axis_tlast) ? S_W1 : S_PASS;
                end
                S_W1: if (acc) begin
                    if (vlan_go) begin
                        // 本帧 VLAN: 剥 tag, 进入错位拼接支
                        state    <= S_SHIFT;
                        dbg_vlan <= 1'b1;
                    end else begin
                        // 非 VLAN / 残缺 / 异常 SOP: 直通, 回常态等下一帧首字
                        state <= S_PASS;
                    end
                end
                S_SHIFT: if (acc) begin
                    if (s_axis_tuser) begin
                        // 上游残段 (无 tlast): 本字按新帧首字直通重建
                        state    <= (s_axis_tlast) ? S_PASS : S_W1;
                        dbg_vlan <= 1'b0;
                    end else if (s_axis_tlast) begin
                        stat_stripped <= stat_stripped + 32'd1;   // 帧尾 +1
                        dbg_vlan      <= 1'b0;
                        state         <= last_now ? S_PASS : S_TAIL;
                    end
                end
                S_TAIL: if (od_free) state <= S_PASS;   // 尾字已装载
                default: state <= S_PASS;
            endcase
        end
    end
endmodule
