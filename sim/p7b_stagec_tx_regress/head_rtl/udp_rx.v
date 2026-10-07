`timescale 1ns/1ps
// UDP RX: 头解析 + 匹配过滤 + 载荷 cut-through 直出 (64bit 左对齐字流, 零整包暂存)。
//
// 字节布局 (帧首 = tdata[63:56], 无 VLAN):
//   w0 = dst_mac[6]+src_mac[0..1]; w1 = src_mac[2..5]+ethertype+ver/ihl+dscp
//   w2 = total_len+id+flags/frag+ttl+proto; w3 = ip_csum+src_ip+dst_ip[31:16]
//   w4 = dst_ip[15:0]+src_port+dst_port+udp_len; w5 = udp_csum+载荷[0..5]
// 载荷从字节 42 起 = 5 整字 + 2 字节偏移: 输出字 = {上一源字低 48 位, 当前源字高 2 字节}。
//
// 头吸收 w0..w4; 匹配判定在 w4 拍 (IP 校验和 20B 半字反码和 == 0xFFFF 同拍组合树);
// 不匹配/坏头/坏 IP 校验和 -> 整帧吞掉 (旁路, 不占下游带宽), 仅计数。
// tcrs 在 TLAST 拍才知道, cut-through 不可回撤 -> 末拍 tuser[0]=crc_ok 标记, 下游自决。
// 背压: 载荷期组合直通 (s_ready = m_ready || 输出空闲), 上游 mac_rx_64 的 8 深 FIFO
// 满时按帧原子丢弃 (其 stat_drop 计数) — 本模块不丢帧只停流。
module udp_rx (
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
    // 载荷直出 (左对齐; meta_valid 指示帧首)
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire [1:0]  m_axis_tuser,   // [0]=crc_ok [1]=err (TLAST 拍)
    output wire        fend,           // 帧判定拍脉冲 (载荷 TLAST 拍 / 零长帧 w5 拍; 丢弃帧不脉冲)
    output wire        ferr,           // fend 拍有效: 帧坏 (FCS 错或 rx_er)
    // 每帧元数据 (meta_valid 脉冲 = w5 接受拍, 即载荷首拍前)
    output wire        meta_valid,
    output wire [47:0] meta_src_mac,
    output wire [31:0] meta_src_ip,
    output wire [15:0] meta_src_port,
    output wire [15:0] meta_len,       // 载荷字节数 = udp_len - 8
    // 配置
    input  wire [31:0] cfg_dst_ip,
    input  wire        cfg_multi_en,   // dst_ip[31:28]==4'hE 即接受
    input  wire [15:0] cfg_port0, cfg_port1, cfg_port2, cfg_port3,
    input  wire        cfg_port_any,
    // 统计
    output reg  [31:0] stat_pass,          // 匹配且 FCS 好
    output reg  [31:0] stat_drop_nonmatch, // 头坏/非 UDP/不匹配/长度不符
    output reg  [31:0] stat_drop_ipcsum,   // IP 头校验和错
    output reg  [31:0] stat_drop_crc,      // 匹配但 FCS 坏 (帧交付, 末拍标记)
    output reg  [31:0] stat_bytes          // 匹配且 FCS 好的载荷字节
`ifdef RXP_DIAG
    //=========================================================================
    // RXP_DIAG v7 (2026-09-27): IP identification (16 位) 序列检查
    //   = "线缆上到达的帧顺序本身是否被打乱" 的**直接度量**
    //   (ISSUE_RX_BYTE_CORRUPTION §18.15 / §18.16)
    //=========================================================================
    // 【为什么用 IP ID】peer 每发一帧 `ip.id` 逐帧 +1 —— 抓包实测 (§18.15:
    //   5699 帧按 ip.id 逐帧比对图案, 0 失配)。ID 是**帧的一部分**: 如果帧级顺序
    //   被换过 (整帧置换), 那么**到达顺序**上的 ID 序列就不再是 +1。这正是
    //   §18.15 收窄后的两条假设 (PC 侧 NIC/驱动 TX 路径 vs PHY/GMII 接收裕量)
    //   的判决量, 而且不需要板上任何缓冲就能测 —— 与 §18.9 那个"装不下整帧"
    //   的结构矛盾不冲突。
    // 【口径 (三条必须说清)】
    //   ① 比的是**线上到达顺序**, 不是发送顺序 —— 到达顺序就是被测对象。
    //   ② 只比**通过匹配门的帧** (= 会走到 meta_valid 的那些: ip 校验和 +
    //      ip_match + port_match + udp_len_ok 全过)。混进 ICMP/别的端口/坏校验和
    //      的帧只会污染判据 (板级每轮都有若干非数据帧: §18.16 的 100 Mbps 轮)。
    //      ⚠️ 代价如实记录: 数据帧之间若插进了别的 IP 帧 (ICMP 等), 它们的 ID 也
    //      在 peer 的 ID 空间里前进 ⇒ 序列会出现**正向跳变** (delta >= 2), 这类
    //      违例**不能**直接判成重排。故除 IV (总违例) 外另给 IW (**反向**跳跃数):
    //      `id < prev` (mod 2^16 递减) 才是"顺序被打乱"的确凿签名 ⇒ 判据用
    //      IW (确凿) / IV-IW (正向, 混杂) 两条分别读, 而不是只看 IV。
    //      另一种口径 (比**所有**帧) 被否掉的理由: 未过门的帧里既有 ICMP (消费 ID)
    //      也有坏校验和/非 UDP 帧 (不消费), 两者混在一起后 IV 的分布无法解释;
    //      而"过门帧"集合恰好等于 app 真正看到的数据帧集合 (PS/SB 已逐位对账)。
    //   ③ **第一个**通过门的帧不参与比较 (它没有上一帧) ⇒ 只在 IS!=0 时比,
    //      且它照样写入 prev。⇒ **IS = 进入本检查器的"过门帧"数** (含第一帧),
    //      实际比较次数 = IS-1 ⇒ IS 是判据的分母 (自证"IV==0 不是死 0")。
    //      ★ 板级自洽式: **IS == PS + DC** (PS = stat_pass = 匹配且 FCS 好,
    //        DC = stat_drop_crc = 匹配但 FCS 坏; 两者之和恰是过门帧数) ——
    //        差一帧就说明口径/接线有问题, 这是一条不需要额外字段的交叉核对。
    // 【字节布局 (逐字核对本文件头注释的 w0..w5 布局)】
    //   w2 = total_len + id + flags/frag + ttl + proto (帧 byte16..23)
    //     → total_len = w2[63:48] (byte16-17), **id = w2[47:32] (byte18-19)**,
    //       flags/frag = w2[31:16] (byte20-21), ttl = w2[15:8] (byte22),
    //       proto = w2[7:0] (byte23) —— 与 hdr_ok2 判 `s_axis_tdata[7:0]==8'h11`
    //       (wcnt==2) 的位置互为印证。
    //   id 是**网络序**字段 (byte18 在 bit[47:40]); peer 的 +1 是"网络序读数 +1"
    //   (同 tshark 显示的 ip.id) ⇒ 必须**原样**比较 w2_r[47:32], **不能**做字节
    //   交换 (交换后 +1 关系不成立)。
    //   取字段位置/字节序由门相 P3 实测钉死: 两个 ID 取**互为字节交换**的值
    //   (0xA5C3 / 0x3C5A) ⇒ 取错字节序或取错偏移都不可能解出构造值。
    // 【时序】每帧**一次**: 16 位比较 + 计数器增量, 路径 = w2_r/prev_r → 比较器 →
    //   计数器 D (无 xorshift 那类 8 步链)。
    // 【端口】一律追加在端口表末尾; 整段只在 `RXP_DIAG 下达 ⇒ 默认构建
    //   (build_p4) 的端口表/逻辑/时序逐位不变。
    , output reg  [15:0] ip_id_viol    // IV: id != prev+1 的次数 (总违例)
    , output reg  [15:0] ip_id_seen    // IS: 过门帧数 (比较次数 = IS-1; 自证不是死 0)
    , output reg  [15:0] ip_id_cur     // IA: 首个违例的**本帧** ID
    , output reg  [15:0] ip_id_prev    // IB: 首个违例的**上一帧** ID
    , output reg  [15:0] ip_id_back    // IW: 其中**反向**跳跃数 (id < prev; 重排签名)
`endif
);

    localparam [1:0] S_HDR = 2'd0, S_PAY = 2'd1, S_DROP = 2'd2, S_TAIL = 2'd3;

    reg  [1:0]  state;
    reg  [5:0]  wcnt;
    reg         matched;
    reg  [15:0] w1_lo, w3_r;             // 头字段暂存
    reg  [63:0] w2_r;                    // 必须 64 位: IP 校验和树要读全部 4 半字
                                         // (声明窄了会部分越界选择 -> X -> if(X) 静默绕过校验)
    reg  [15:0] mac_lo;                  // src_mac[47:32] (线上字节 6..7)
    reg  [31:0] mac_hi;                  // src_mac[31:0]  (线上字节 8..11)
    reg  [31:0] src_ip_r;
    reg  [15:0] src_port_r, meta_len_r;
    reg  [47:0] hold;
    reg  [11:0] pcount;
    reg         emit_v;
    reg  [63:0] emit_d;
    reg  [7:0]  emit_k;
    reg         emit_l;
    reg  [1:0]  emit_u;
    reg         tail_stage;
    reg  [63:0] tail_d;
    reg  [7:0]  tail_k;
    reg  [1:0]  tail_u;

    wire        accept = s_axis_tvalid && s_axis_tready;

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

    // 6 字节窗口左对齐 (短载荷尾字 / 溢出尾字共用)
    function [63:0] ljust6;
        input [47:0] w;
        input [2:0]  p;
        begin
            case (p)
                3'd1: ljust6 = {w[47:40], 56'b0};
                3'd2: ljust6 = {w[47:32], 48'b0};
                3'd3: ljust6 = {w[47:24], 40'b0};
                3'd4: ljust6 = {w[47:16], 32'b0};
                3'd5: ljust6 = {w[47:8],  24'b0};
                3'd6: ljust6 = {w[47:0],  16'b0};
                default: ljust6 = 64'b0;
            endcase
        end
    endfunction

    function [15:0] fold16x;
        input [19:0] v;
        reg [16:0] f1;
        begin
            f1 = v[15:0] + {12'b0, v[19:16]};
            fold16x = f1[15:0] + {15'b0, f1[16]};
        end
    endfunction

    // IP 头校验和: 20B = w1[15:0]+w2(8B)+w3(8B)+w4[63:48] 的 10 半字反码和 == 0xFFFF
    // 前 9 半字在 w3 拍用当前 tdata 组合树算好寄存, w4 拍只加 1 半字+折叠+比较
    wire [19:0] ipc_sum9 = {4'b0, w1_lo} + {4'b0, w2_r[15:0]} + {4'b0, w2_r[31:16]} +
                           {4'b0, w2_r[47:32]} + {4'b0, w2_r[63:48]} +
                           {4'b0, s_axis_tdata[15:0]} + {4'b0, s_axis_tdata[31:16]} +
                           {4'b0, s_axis_tdata[47:32]} + {4'b0, s_axis_tdata[63:48]};
    reg  [19:0] ipc_s9;
    wire [19:0] ipc_sum10 = ipc_s9 + {4'b0, s_axis_tdata[63:48]};
    wire        ipcsum_ok = (fold16x(ipc_sum10) == 16'hFFFF);
    // 组播过滤与单播精确匹配并存 (cfg_multi_en 只额外放行组播, 不关闭单播)
    wire        ip_match  = ((cfg_multi_en && (w3_r[15:12] == 4'hE)) ||
                             ({w3_r[15:0], s_axis_tdata[63:48]} == cfg_dst_ip));
    wire        port_match = cfg_port_any ||
                             (s_axis_tdata[31:16] == cfg_port0) ||
                             (s_axis_tdata[31:16] == cfg_port1) ||
                             (s_axis_tdata[31:16] == cfg_port2) ||
                             (s_axis_tdata[31:16] == cfg_port3);
    wire        udp_len_ok = (s_axis_tdata[15:0] >= 16'd8);

    wire        hdr_ok1  = (wcnt == 6'd1) && (s_axis_tdata[31:16] == 16'h0800) &&
                           (s_axis_tdata[15:8] == 8'h45);
    wire        hdr_ok2  = (wcnt == 6'd2) && (s_axis_tdata[7:0] == 8'h11);

    assign s_axis_tready = (state == S_PAY) ? (m_axis_tready || !emit_v) :
                           (state == S_TAIL) ? 1'b0 :
                           ((state == S_HDR) && (wcnt == 6'd5)) ?
                               (m_axis_tready || !emit_v) : 1'b1;
    assign m_axis_tdata  = emit_d;
    assign m_axis_tkeep  = emit_k;
    assign m_axis_tvalid = emit_v;
    assign m_axis_tlast  = emit_l;
    assign m_axis_tuser  = emit_u;
    assign meta_valid    = (state == S_HDR) && accept && (wcnt == 6'd5) && matched;
    assign fend          = ((state == S_HDR) && accept && (wcnt == 6'd5) && matched &&
                             s_axis_tlast &&
                             ({8'b0, pop8(s_axis_tkeep)} - 12'd2 == meta_len_r)) ||
                           ((state == S_PAY) && (!emit_v || m_axis_tready) && accept &&
                            s_axis_tlast && (pop8(s_axis_tkeep) != 4'd0) &&
                            (pcount + {8'b0, pop8(s_axis_tkeep)} == meta_len_r));
    assign ferr          = !s_axis_tcrs || s_axis_terr;
    assign meta_src_mac  = {mac_lo, mac_hi};
    assign meta_src_ip   = src_ip_r;
    assign meta_src_port = src_port_r;
    assign meta_len      = meta_len_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_HDR; wcnt <= 0; matched <= 0;
            w1_lo <= 0; w2_r <= 0; w3_r <= 0; ipc_s9 <= 0;
            mac_lo <= 0; mac_hi <= 0; src_ip_r <= 0; src_port_r <= 0; meta_len_r <= 0;
            hold <= 0; pcount <= 0;
            emit_v <= 0; emit_d <= 0; emit_k <= 0; emit_l <= 0; emit_u <= 0;
            tail_stage <= 0; tail_d <= 0; tail_k <= 0; tail_u <= 0;
            stat_pass <= 0; stat_drop_nonmatch <= 0; stat_drop_ipcsum <= 0;
            stat_drop_crc <= 0; stat_bytes <= 0;
        end else begin
            if (m_axis_tready && emit_v) emit_v <= 1'b0;   // 输出被消费
            case (state)
                S_HDR: begin
                    if (accept) begin
                        if (s_axis_tuser) begin
                            // 仅清半帧残留 (emit_l=0); 完整帧尾未消费时保留,
                            // w5 门控 (s_axis_tready) 等其排空
                            if (!emit_l) emit_v <= 1'b0;
                        end
                        if (s_axis_tlast && (wcnt != 6'd5)) begin
                            // 头没走完帧就结束: 畸形 (w5 的 TLAST 是合法短帧, 走 case 特例)
                            state <= S_HDR; wcnt <= 6'd0; matched <= 1'b0;
                            stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                        end else begin
                            case (s_axis_tuser ? 6'd0 : wcnt)
                                6'd0: begin
                                    if (s_axis_tkeep != 8'hFF) begin
                                        state <= S_DROP; matched <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        mac_lo <= s_axis_tdata[15:0];   // src_mac[47:32]
                                        wcnt <= 6'd1;
                                    end
                                end
                                6'd1: begin
                                    if (s_axis_tkeep != 8'hFF || !hdr_ok1) begin
                                        state <= S_DROP; matched <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        mac_hi <= s_axis_tdata[63:32];
                                        w1_lo <= s_axis_tdata[15:0];
                                        wcnt <= 6'd2;
                                    end
                                end
                                6'd2: begin
                                    if (s_axis_tkeep != 8'hFF || !hdr_ok2) begin
                                        state <= S_DROP; matched <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        w2_r <= s_axis_tdata[63:0];
                                        wcnt <= 6'd3;
                                    end
                                end
                                6'd3: begin
                                    if (s_axis_tkeep != 8'hFF) begin
                                        state <= S_DROP; matched <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        w3_r <= s_axis_tdata[63:0];
                                        src_ip_r <= s_axis_tdata[47:16];
                                        ipc_s9 <= ipc_sum9;
                                        wcnt <= 6'd4;
                                    end
                                end
                                6'd4: begin
                                    if (s_axis_tkeep != 8'hFF) begin
                                        state <= S_DROP; matched <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else if (!ipcsum_ok) begin
                                        state <= S_DROP; matched <= 1'b0;
                                        stat_drop_ipcsum <= stat_drop_ipcsum + 1;
                                    end else if (!ip_match || !port_match || !udp_len_ok) begin
                                        state <= S_DROP; matched <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        matched <= 1'b1;
                                        src_port_r <= s_axis_tdata[47:32];
                                        meta_len_r <= s_axis_tdata[15:0] - 16'd8;
                                        wcnt <= 6'd5;
                                    end
                                end
                                default: begin   // wcnt==5
                                    if (!matched || s_axis_tkeep[7:6] != 2'b11) begin
                                        state <= S_DROP; matched <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else if (s_axis_tlast) begin
                                        // 短载荷帧 (0..6 字节)
                                        state <= S_HDR; wcnt <= 6'd0; matched <= 1'b0;
                                        if ({8'b0, pop8(s_axis_tkeep)} - 12'd2 != meta_len_r) begin
                                            stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                        end else begin
                                            if (s_axis_tcrs) begin
                                                stat_pass <= stat_pass + 1;
                                                stat_bytes <= stat_bytes + meta_len_r;
                                            end else begin
                                                stat_drop_crc <= stat_drop_crc + 1;
                                            end
                                            emit_v <= (s_axis_tkeep != 8'hC0);
                                            emit_d <= ljust6(s_axis_tdata[47:0],
                                                             pop8(s_axis_tkeep) - 3'd2);
                                            emit_k <= 8'hFF << (4'd8 -
                                                      (pop8(s_axis_tkeep) - 4'd2));
                                            emit_l <= 1'b1;
                                            emit_u <= {s_axis_terr, s_axis_tcrs};
                                        end
                                    end else begin
                                        state <= S_PAY;
                                        hold <= s_axis_tdata[47:0];
                                        pcount <= {8'b0, pop8(s_axis_tkeep)} - 12'd2;
                                        wcnt <= 6'd6;
                                    end
                                end
                            endcase
                        end
                    end
                end
                S_PAY: begin
                    if ((!emit_v || m_axis_tready) && accept) begin
                        if (s_axis_tuser) begin
                            // 截断防御: 丢弃当前帧残余 (半帧无 TLAST), 本字即新帧 w0
                            if (!emit_l) emit_v <= 1'b0;
                            if (s_axis_tlast) begin
                                state <= S_HDR; wcnt <= 6'd0; matched <= 1'b0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else if (s_axis_tkeep != 8'hFF) begin
                                state <= S_DROP; matched <= 1'b0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else begin
                                mac_lo <= s_axis_tdata[15:8];
                                state <= S_HDR; wcnt <= 6'd1; matched <= 1'b0;
                            end
                        end else if (s_axis_tlast) begin
                            if (pop8(s_axis_tkeep) == 4'd0) begin
                                // 空尾字: 畸形
                                state <= S_HDR; wcnt <= 6'd0; matched <= 1'b0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else if (pcount + {8'b0, pop8(s_axis_tkeep)} != meta_len_r) begin
                                // 长度不符: 末尾字不交付 (半帧无 TLAST, 下游丢弃)
                                state <= S_HDR; wcnt <= 6'd0; matched <= 1'b0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else begin
                                state <= S_HDR; wcnt <= 6'd0; matched <= 1'b0;
                                if (s_axis_tcrs) begin
                                    stat_pass <= stat_pass + 1;
                                    stat_bytes <= stat_bytes + meta_len_r;
                                end else begin
                                    stat_drop_crc <= stat_drop_crc + 1;
                                end
                                emit_v <= 1'b1;
                                emit_d <= {hold, s_axis_tdata[63:48]};
                                emit_u <= {s_axis_terr, s_axis_tcrs};
                                if (pop8(s_axis_tkeep) <= 4'd2) begin
                                    emit_k <= 8'hFF << (4'd8 -
                                              (4'd6 + pop8(s_axis_tkeep)));
                                    emit_l <= 1'b1;
                                end else begin
                                    // 主尾字 8 字节 + 溢出尾字 (剩余 n-2 字节在低 6 字节区)
                                    emit_k <= 8'hFF;
                                    emit_l <= 1'b0;
                                    state <= S_TAIL; tail_stage <= 1'b0;
                                    tail_d <= ljust6(s_axis_tdata[47:0],
                                                     pop8(s_axis_tkeep) - 4'd2);
                                    tail_k <= 8'hFF << (4'd8 -
                                              (pop8(s_axis_tkeep) - 4'd2));
                                    tail_u <= {s_axis_terr, s_axis_tcrs};
                                end
                            end
                        end else begin
                            if (s_axis_tkeep != 8'hFF) begin
                                // 帧内非整字: 畸形
                                state <= S_DROP; matched <= 1'b0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else if (pcount + 12'd8 > meta_len_r) begin
                                // 帧身超过 udp_len 声明的载荷: 畸形, 吞掉防 pcount 回绕
                                state <= S_DROP; matched <= 1'b0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else begin
                                emit_v <= 1'b1;
                                emit_d <= {hold, s_axis_tdata[63:48]};
                                emit_k <= 8'hFF;
                                emit_l <= 1'b0;
                                hold <= s_axis_tdata[47:0];
                                pcount <= pcount + 12'd8;
                            end
                        end
                    end
                end
                S_TAIL: begin
                    if (tail_stage) begin
                        if (m_axis_tready) begin
                            state <= S_HDR; wcnt <= 6'd0;   // 溢出尾字已消费
                            emit_v <= 1'b0;
                        end
                    end else if (m_axis_tready) begin
                        // 主尾字消费 -> 装溢出字
                        emit_v <= 1'b1; emit_d <= tail_d;
                        emit_k <= tail_k; emit_l <= 1'b1; emit_u <= tail_u;
                        tail_stage <= 1'b1;
                    end
                end
                default: begin   // S_DROP: 吞到帧尾
                    if (accept && s_axis_tlast) begin
                        state <= S_HDR; wcnt <= 6'd0;
                    end
                end
            endcase
        end
    end

`ifdef RXP_DIAG
    //=========================================================================
    // RXP_DIAG v7: IP ID 序列检查 (口径/布局/判据见端口段的 v7 注释 —— 真值源那里)
    //=========================================================================
    reg  [15:0] v7_prev_r;      // 上一**通过匹配门**帧的 ID
    // 参与比较的判定 = meta_valid 的条件 (wcnt==5 且 matched 的接受拍)。w2_r 在本
    // 帧 wcnt==2 拍锁存、到 w5 拍仍稳定 ⇒ 直接用 w2_r[47:32], 不新增 ID 寄存器。
    wire        v7_cyc  = (state == S_HDR) && accept && (wcnt == 6'd5) && matched;
    wire [15:0] v7_id   = w2_r[47:32];              // = 帧 byte18-19 (网络序)
    wire        v7_bad  = (v7_id != (v7_prev_r + 16'd1));  // 期望 +1
    wire        v7_bwd  = (v7_id < v7_prev_r);      // 反向跳跃 (mod 2^16 递减)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v7_prev_r   <= 16'd0;
            ip_id_viol  <= 16'd0;
            ip_id_seen  <= 16'd0;
            ip_id_cur   <= 16'd0;
            ip_id_prev  <= 16'd0;
            ip_id_back  <= 16'd0;
        end else if (v7_cyc) begin
            if (ip_id_seen != 16'd0) begin          // 第一帧没有"上一帧" ⇒ 不比
                if (v7_bad) begin
                    ip_id_viol <= ip_id_viol + 16'd1;
                    // 首个违例: 用 IV==0 当"首次"条件 (结构性保证: IV>0 ⇔ 锁存有效)
                    if (ip_id_viol == 16'd0) begin
                        ip_id_cur  <= v7_id;
                        ip_id_prev <= v7_prev_r;
                    end
                    if (v7_bwd) ip_id_back <= ip_id_back + 16'd1;
                end
            end
            v7_prev_r  <= v7_id;
            ip_id_seen <= ip_id_seen + 16'd1;
        end
    end
`endif

endmodule
