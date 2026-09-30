`timescale 1ns/1ps
// UDP TX 组帧器: app 载荷帧 (AXIS 字流) -> 完整 UDP/IP/以太网帧字流 (给 mac_tx_64)。
//
// 帧级递交的原因: UDP 校验和覆盖伪头+头+全载荷, 而字段位置在头里 (字节 40-41) —
// 流式直通时头发出前载荷未到, 校验和不可知。载荷整帧入 FIFO 同时流过 checksum16,
// TLAST 后 3 拍校验和落定, 再流式发头+载荷 (载荷只存不复制, FIFO 一遍写一遍读)。
// 延迟 = 帧长 (1G/100B ≈ 0.8µs; 10G 时 80ns)。
//
// 头字构造 (左对齐, 帧首 = tdata[63:56]):
//   w0 = dst_mac+src_mac[47:40]; w1 = src_mac[39:0]+0800+45+00
//   w2 = total_len+id+0000+40+11; w3 = ip_csum+src_ip+dst_ip[31:24]
//   w4 = dst_ip[23:0]+src_port+dst_port+udp_len; w5 = udp_csum+载荷[0..5]
// 载荷相对帧头 2 字节偏移: 输出字 = {上一字低 2 字节, 当前字高 6 字节}。
// 前导/FCS/pad/IFG 由 mac_tx_64 负责。
//
// P5e-T2 长度守卫 (app 契约: 一帧 = 一个 UDP 数据报 ≤1472B; 这里放到 1500 留
// 余量): 帧内累计 > PLEN_MAX ⇒ **整帧中止** (不写 FIFO/不发帧/不加统计),
// 残留字节原地冲洗 (flush_pend), stat_drop_len 计数。两个硬理由:
//   ① >2048B 会**永久死锁** — 内部载荷 FIFO 只有 256 字 (2048B), 载满后
//      s_axis_tready 恒 0 而 FSM 停在 S_RECV 等 tlast ⇒ 该帧永不收尾也永不放行。
//   ② >1518B 会**上线巨帧** (mac_tx_64 不做长度截断), 对端/交换机丢弃或报警。
// 上界必须 < FIFO 容量: 超限检出拍最多已写入 (PLEN_MAX+7)/8+1 = 189 字
// (1500/8 = 187.5 -> 检出拍 = 第 188 拍), 结构性不满 256 ⇒ 无死锁路径。
// 不加 FSM 状态 (P5a tcp_tx_frame 同款做法: len_bad/flush_pend 两个 flag),
// 默认构建/P1 echo 路径的帧恒 ≤1500B ⇒ len_bad/flush_pend 恒 0, 逐位不变。
module udp_tx_frame (
    input  wire        clk,
    input  wire        rst_n,
    // app 载荷输入 (左对齐; 零长帧 = 单拍 tlast 且 tkeep=0)
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    // 配置
    input  wire [47:0] cfg_src_mac, cfg_dst_mac,
    input  wire [31:0] cfg_src_ip,  cfg_dst_ip,
    input  wire [15:0] cfg_src_port, cfg_dst_port,
    input  wire        cfg_csum_en,     // 1=算 UDP 校验和, 0=字段置 0
    // 帧字流输出 (接 mac_tx_64)
    output reg  [63:0] m_axis_tdata,
    output reg  [7:0]  m_axis_tkeep,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,
    // 统计
    output reg  [31:0] stat_frames,
    output reg  [31:0] stat_bytes,
    // P5e-T2 长度守卫: 超长帧帧内中止丢弃数 (app 契约违规兜底)。
    // ⚠️ 新增输出口: 现有例化点 (tb_udp_tx / tb_udp_echo / wrapper_echo) 不接
    // 本口 = 仅 unconnected 警告 (全部命名端口例化), P1 三门行为不变 (坑 12)。
    output reg  [31:0] stat_drop_len,
    // P5e-T2 cfg 稳定性握: 1 = 本模块非空闲 (帧在收/在发)。
    // 用途: 上游 udp_tx_cfg 必须**冻结 cfg 直到本模块回到 S_RECV** —— 因为 cfg
    // 在本模块里被两个不同时刻采样: init_val(帧首拍, 进 checksum16) 与帧头字节
    // (S_HDR 拍)+ip_csum_calc(TLAST 拍)。若上游在"最后一拍已收完但帧头还没发"
    // 的窗口里改 cfg, 帧头会用新值而校验和用旧值 (实测: 头=新 peer, csum=旧 peer)。
    output wire        o_busy
);

    // P5e-T2 长度守卫上界: 默认 1500 = app 契约上限 (P1 门 tools/gen_stim_udp_tx.py
    // 的 LENS 含 1500 用例 ⇒ 阈值必须 >=1500, 且必须 < FIFO 容量 2048B)。
    // 风格同 tcp_tx_frame.PLEN_MAX: module body 内参数 (不能写成 #(...) 参数表 —
    // 那会让 body 里的本参数不可被顶层覆盖)。
    parameter [11:0] PLEN_MAX = 12'd1500;

    localparam [2:0] S_RECV = 3'd0, S_WAIT = 3'd1, S_HDR = 3'd2,
                     S_PAY  = 3'd3, S_TAIL = 3'd4, S_DONE = 3'd5;

    reg  [2:0]  state;
    // P5e-T2 cfg 稳定性握手 (声明后置: 先声明后用, xvlog 要求)
    assign o_busy = (state != S_RECV);
    reg         recv_first;
    reg  [11:0] plen;
    reg  [11:0] plen_r;
    // P5e-T2 长度守卫: len_bad = 本帧已超 PLEN_MAX (下拍起写口全屏蔽);
    // flush_pend = 中止后待冲洗 FIFO 里已写入的残留字 (S_RECV 排空才清)
    reg         len_bad, flush_pend;
    reg  [15:0] udp_len_r, total_len_r, ip_csum_r, udp_csum_r;
    reg  [15:0] id_r, id_cap;
    reg  [1:0]  wait_cnt;
    reg  [2:0]  hcnt;
    reg  [15:0] hold16;
    reg  [63:0] tail_d;
    reg  [7:0]  tail_k;

    wire        accept = s_axis_tvalid && s_axis_tready;
    // FIFO 字位段 (与读取位段一致): [72]=last [71:64]=keep [63:0]=data
    wire [72:0] fdin   = {s_axis_tlast, s_axis_tkeep, s_axis_tdata};
    wire [72:0] fdout;
    wire        fifo_full, fifo_empty;
    // P5e-T2 长度守卫: len_bad 后的字节不入 FIFO (中止帧的字节永不发送 —
    // 也就不进校验和: csum_den 同步屏蔽)
    wire        wr = accept && (s_axis_tkeep != 8'h00) && !len_bad;
    wire        pay_load = (state == S_PAY) && (m_axis_tready || !m_axis_tvalid);
    // 冲洗读口: 中止帧的残留字在 S_RECV 每拍弹 1 个 (<=188 拍排空);
    // 与 S_PAY 读口互斥 (状态不同), 拼成同一条 rd
    wire        flush_rd = (state == S_RECV) && flush_pend && !fifo_empty;
    wire        rd = (pay_load && (plen_r != 12'd0) && !fifo_empty) || flush_rd;

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

    function [63:0] ljust16x;
        input [15:0] w;
        input [1:0]  p;
        begin
            case (p)
                2'd1: ljust16x = {w[15:8], 56'b0};
                2'd2: ljust16x = {w[15:0], 48'b0};
                default: ljust16x = 64'b0;
            endcase
        end
    endfunction

    // IP 头校验和 (组合树): 10 半字反码和取反, 在 TLAST 拍随 total_len/id 同拍算出
    function [15:0] ip_csum_calc;
        input [15:0] tlen;
        input [15:0] idc;
        reg [19:0] s;
        reg [16:0] f1;
        begin
            s = {4'b0, 16'h4500} + {4'b0, tlen} + {4'b0, idc} + {4'b0, 16'h0000} +
                {4'b0, 16'h4011} + {4'b0, 16'h0000} + {4'b0, cfg_src_ip[31:16]} +
                {4'b0, cfg_src_ip[15:0]} + {4'b0, cfg_dst_ip[31:16]} +
                {4'b0, cfg_dst_ip[15:0]};
            f1 = s[15:0] + {12'b0, s[19:16]};
            ip_csum_calc = ~(f1[15:0] + {15'b0, f1[16]});
        end
    endfunction

    // 帧长 (tlast 拍): recv_first 时 plen 还是上一帧残留值, 必须显式归零
    wire [11:0] plen_n  = (recv_first ? 12'd0 : plen) + {8'b0, pop8(s_axis_tkeep)};
    // P5e-T2 长度守卫判据 (含本拍字节)。len_bad 是寄存器 (检出拍的下拍起屏蔽
    // 写口), 检出拍本身那条字已写进 FIFO — 由中止拍的 flush 排空兜掉。
    wire        len_over = (plen_n > PLEN_MAX);
    wire [15:0] tl_c    = plen_n + 12'd28;
    wire [15:0] id_now  = recv_first ? id_r : id_cap;
    wire [31:0] csum_init_val = {4'b0, cfg_src_ip[31:16]} + {4'b0, cfg_src_ip[15:0]} +
                                {4'b0, cfg_dst_ip[31:16]} + {4'b0, cfg_dst_ip[15:0]} +
                                32'h0011;
    wire        csum_init = (state == S_RECV) && accept && recv_first;
    wire        csum_den  = (state == S_RECV) && accept &&
                            (s_axis_tkeep != 8'h00) && !len_bad;
    wire        csum_aen  = (state == S_WAIT) && (wait_cnt == 2'd0);
    wire        csum_fin  = (state == S_WAIT) && (wait_cnt == 2'd1);
    wire [15:0] csum;
    wire        csum_valid;

    // P5e-T2: 接受门与"能否启动/续收一帧"同门 (工程坑 10): 冲洗期间既不接受
    // 也不启动 — 否则新帧首字会与待冲洗的残留字混在同一 FIFO 里, 排空指针会
    // 吃掉新帧首字 (帧长错 8 字节)。
    assign s_axis_tready = (state == S_RECV) && !fifo_full && !flush_pend;

    checksum16 u_csum (
        .clk(clk), .rst_n(rst_n),
        .init(csum_init), .init_val(csum_init_val),
        .den(csum_den), .din(s_axis_tdata), .dkeep(s_axis_tkeep),
        // aen 一次补足: 伪头 udp_len + UDP 头 (udp_len+sport+dport; csum 字段本身为 0 不参与)
        // RFC 768: udp_len 在伪头与 UDP 头中各计一次 -> 两倍
        .aen(csum_aen), .add_val({2'b0, udp_len_r} + {2'b0, udp_len_r} +
                                  {2'b0, cfg_src_port} + {2'b0, cfg_dst_port}),
        .fin(csum_fin),
        .csum(csum), .csum_valid(csum_valid)
    );

    fifo_sync #(.W(73), .D(256), .AW(8)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr(wr), .din(fdin),
        .rd(rd), .dout(fdout),
        .empty(fifo_empty), .full(fifo_full)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_RECV; recv_first <= 1'b1;
            plen <= 0; plen_r <= 0;
            len_bad <= 1'b0; flush_pend <= 1'b0; stat_drop_len <= 32'd0;
            udp_len_r <= 0; total_len_r <= 0; ip_csum_r <= 0; udp_csum_r <= 0;
            id_r <= 0; id_cap <= 0;
            wait_cnt <= 0; hcnt <= 0; hold16 <= 0; tail_d <= 0; tail_k <= 0;
            m_axis_tdata <= 0; m_axis_tkeep <= 0; m_axis_tvalid <= 0; m_axis_tlast <= 0;
            stat_frames <= 0; stat_bytes <= 0;
        end else begin
            if (m_axis_tready && m_axis_tvalid) m_axis_tvalid <= 1'b0;
            case (state)
                S_RECV: begin
                    // P5e-T2 超长帧冲洗收尾: 残留字排空 (rd 见 flush_rd) 后清标志。
                    // len_bad 必须在此清 (而非留到下一帧首拍) — 否则下一帧首拍会被
                    // accept 但 wr 仍被 len_bad 屏蔽: 计了字节而 FIFO 没写 = 整帧
                    // 错位 (P5a tcp_tx_frame 实测踩过同坑)。flush_pend 期间
                    // s_axis_tready 恒 0 ⇒ 与下面的帧首拍接收结构性不可能同拍。
                    if (flush_pend && fifo_empty) begin
                        flush_pend <= 1'b0;
                        len_bad    <= 1'b0;
                    end
                    if (accept) begin
                        if (recv_first) begin
                            recv_first <= 1'b0;
                            id_cap <= id_r;
                            id_r <= id_r + 1;
                            plen <= {8'b0, pop8(s_axis_tkeep)};
                        end else begin
                            plen <= plen + {8'b0, pop8(s_axis_tkeep)};
                        end
                        // 超限 ⇒ 置 len_bad (下拍起不写 FIFO/不进校验和)
                        if (len_over) len_bad <= 1'b1;
                        if (s_axis_tlast) begin
                            if (len_over || len_bad) begin
                                // 中止: 不回 S_WAIT (不组头/不发帧/不加 stat_frames
                                // /不推进任何线上状态), 原地冲洗残留 + 计数。
                                // 状态保持 S_RECV ⇒ 无新增 FSM 状态。
                                recv_first    <= 1'b1;
                                flush_pend    <= 1'b1;
                                stat_drop_len <= stat_drop_len + 32'd1;
                            end else begin
                                plen_r <= plen_n;
                                udp_len_r <= plen_n + 12'd8;
                                total_len_r <= tl_c;
                                ip_csum_r <= ip_csum_calc(tl_c, id_now);
                                state <= S_WAIT; wait_cnt <= 2'd0;
                            end
                        end
                    end
                end
                S_WAIT: begin
                    if (wait_cnt == 2'd2) begin
                        udp_csum_r <= cfg_csum_en ? (csum_valid ? csum : 16'h0) : 16'h0;
                        state <= S_HDR; hcnt <= 3'd0;
                    end else begin
                        wait_cnt <= wait_cnt + 2'd1;
                    end
                end
                S_HDR: begin
                    if (!m_axis_tvalid || m_axis_tready) begin
                        m_axis_tvalid <= 1'b1;
                        m_axis_tkeep <= 8'hFF;
                        m_axis_tlast <= 1'b0;
                        case (hcnt)
                            // 字节布局铁律: w0 = dst[6]+src[0..1]; w1 = src[2..5]+ethertype+45+00;
                            // w2 = total_len+id+0000+40+11; w3 = ip_csum+src_ip+dst[31:16];
                            // w4 = dst[15:0]+sport+dport+udp_len — 每字拼接必须恰 64 位
                            3'd0: m_axis_tdata <= {cfg_dst_mac, cfg_src_mac[47:32]};
                            3'd1: m_axis_tdata <= {cfg_src_mac[31:0], 16'h0800, 8'h45, 8'h00};
                            3'd2: m_axis_tdata <= {total_len_r, id_cap, 16'h0000, 8'h40, 8'h11};
                            3'd3: m_axis_tdata <= {ip_csum_r, cfg_src_ip, cfg_dst_ip[31:16]};
                            default: m_axis_tdata <= {cfg_dst_ip[15:0], cfg_src_port,
                                                      cfg_dst_port, udp_len_r};
                        endcase
                        if (hcnt == 3'd4) begin
                            state <= S_PAY;
                            hold16 <= udp_csum_r;   // 首载荷拍前导 2 字节
                        end else begin
                            hcnt <= hcnt + 3'd1;
                        end
                    end
                end
                S_PAY: begin
                    if (!m_axis_tvalid || m_axis_tready) begin
                        if (plen_r == 12'd0) begin
                        // 零长载荷: {csum, 0} 2 字节
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata <= {udp_csum_r, 48'h0000};   // 拼接必须 64 位
                        m_axis_tkeep <= 8'hC0;
                        m_axis_tlast <= 1'b1;
                        state <= S_DONE;
                    end else if (fifo_empty) begin
                        // 欠载防御 (app 契约违规): 提前结束帧
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata <= {hold16, 48'h0000};
                        m_axis_tkeep <= 8'hC0;
                        m_axis_tlast <= 1'b1;
                        state <= S_DONE;
                    end else begin
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata <= {hold16, fdout[63:16]};
                        hold16 <= fdout[15:0];
                        if (fdout[72]) begin
                            // 末载荷字: n 有效字节。输出字 = {hold16(2B), cur[63:16](6B)}
                            // n<6: 本拍 2+n 字节收尾; n==6: 满字收尾; n>6: 满字+溢出尾字 (n-6 字节)
                            if (pop8(fdout[71:64]) < 4'd6) begin
                                m_axis_tkeep <= 8'hFF << (4'd8 -
                                                (4'd2 + pop8(fdout[71:64])));
                                m_axis_tlast <= 1'b1;
                                state <= S_DONE;
                            end else if (pop8(fdout[71:64]) == 4'd6) begin
                                m_axis_tkeep <= 8'hFF;
                                m_axis_tlast <= 1'b1;
                                state <= S_DONE;
                            end else begin
                                m_axis_tkeep <= 8'hFF;
                                m_axis_tlast <= 1'b0;
                                tail_d <= ljust16x(fdout[15:0],
                                                   pop8(fdout[71:64]) - 4'd6);
                                tail_k <= 8'hFF << (4'd8 -
                                          (pop8(fdout[71:64]) - 4'd6));
                                state <= S_TAIL;
                            end
                        end else begin
                            m_axis_tkeep <= 8'hFF;
                            m_axis_tlast <= 1'b0;
                        end
                    end
                end
                end
                S_TAIL: begin
                    if (!m_axis_tvalid || m_axis_tready) begin
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata <= tail_d;
                        m_axis_tkeep <= tail_k;
                        m_axis_tlast <= 1'b1;
                        state <= S_DONE;
                    end
                end
                default: begin   // S_DONE: 等末字消费
                    if (!m_axis_tvalid || m_axis_tready) begin
                        stat_frames <= stat_frames + 1;
                        stat_bytes <= stat_bytes + plen_r;
                        state <= S_RECV;
                        recv_first <= 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
