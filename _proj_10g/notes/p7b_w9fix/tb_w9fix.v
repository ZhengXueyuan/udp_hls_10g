`timescale 1ns/1ps
//=============================================================================
// tb_w9fix.v — P7B-W9 缺陷修复的**判别性台架** (反例双跑: 修前 vs 修后)
//-----------------------------------------------------------------------------
// 链路: app_udp_pattern(i_paylen=1472) -> udp_tx_cfg(peer 门) -> udp_tx_frame -> sink(恒收)
// 定义: -d P7B_10G / -d UDP_TX_OVL 由命令行给 (与 P7B RATE 位流同款);
//       -d POSTFIX 只在被测 = 修复后 RTL 时给 (用于探测新增的 stat_tx_ovf/txf_full_n)。
//
// 判据 (本台架的核心 = **归零对账**, 与"帧几何"两条互相独立):
//   A. QUIESCENT: stat_tx_bytes == Σ_landed popcount(tkeep)
//      —— "app 计了账的载荷字节" == "真正写进字 FIFO 的载荷字节"。
//      修前 P7B_10G: 差 8 × 丢字数 (每帧 1 字); 修后: **必须逐位相等**。
//   B. dropped = push_dec - landed == 0 (修后)。
//      push_dec = 推送决策拍数 (push_now | nul_push | wide_ok);
//      landed    = 真落笔拍数 (txf_wr && !txf_full) —— FIFO 的写口合同;
//      两者在**静止态** (i_tx_ready 拉低 + 排空后) 无"在飞"歧义。
//   C. ovf_pulse (u_txf 内部拒写) 计数: 修前**结构性恒 0** (wr 已预 AND !full ⇒
//      wr&&full 恒假) ⇒ 丢字无计数器可见; 修后 = 真自检, 且必须 == 0。
//   D. 帧几何: 每帧线上字节数 (帧器输出, 不含 FCS)。
//      def/ovl 两档: 1514 (42+1472); P7B_10G 修前: 1506 (42+1464), 修后: 1514。
//=============================================================================
module tb_w9fix;

    function [3:0] pc8;
        input [7:0] v;
        integer i;
        reg [3:0] c;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]};
            pc8 = c;
        end
    endfunction

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---------------- app -> cfg ----------------
    wire [63:0] a_tdata;
    wire [7:0]  a_tkeep;
    wire        a_tvalid, a_tready, a_tlast;
    wire [31:0] a_tx_bytes, a_tx_frames, a_rx_bytes, a_rx_frames, a_rx_null, a_mismatch;
    wire        a_active, a_done;
    wire [3:0]  a_led;
    // ---------------- cfg -> framer ----------------
    wire [63:0] c_tdata;
    wire [7:0]  c_tkeep;
    wire        c_tvalid, c_tready, c_tlast;
    wire [47:0] c_dst_mac, c_src_mac;
    wire [31:0] c_dst_ip, c_src_ip;
    wire [15:0] c_dst_port, c_src_port;
    wire        c_csum_en, c_ready;
    wire [31:0] c_frames, c_deny;
    // ---------------- framer -> sink ----------------
    wire [63:0] f_tdata;
    wire [7:0]  f_tkeep;
    wire        f_tvalid, f_tready, f_tlast;
    wire [31:0] f_frames, f_bytes, f_drop;
    wire        f_busy;

    reg  peer_wr = 1'b0;
    reg  run_en  = 1'b0;               // 门控 i_tx_ready: 0 ⇒ 不启新帧 (T_IDLE 门)

    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0)) u_app (
        .clk(clk), .rst_n(rst_n),
        .i_en(1'b1), .i_tx_ready(c_ready && run_en), .i_paylen(12'd1472),
        .m_tdata(a_tdata), .m_tkeep(a_tkeep), .m_tvalid(a_tvalid),
        .m_tready(a_tready), .m_tlast(a_tlast),
        .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
        .rx_tlast(1'b0), .rx_sof(1'b0), .rx_len(16'd0),
        .stat_tx_bytes(a_tx_bytes), .stat_tx_frames(a_tx_frames),
        .stat_rx_bytes(a_rx_bytes), .stat_rx_frames(a_rx_frames),
        .stat_rx_null(a_rx_null), .stat_mismatch(a_mismatch),
        .active(a_active), .done(a_done), .led(a_led),
        .ds_idx(), .ds_b1(), .ds_b2(), .ds_bg(), .ds_dup(),
        .ds_got(), .ds_exp(), .ds_prev(), .ds_v(),
        .ds_gw(), .ds_ew(), .ds_oz(), .ds_ol(), .ds_om(), .ds_oh()
    );

    udp_tx_cfg u_cfg (
        .clk(clk), .rst_n(rst_n),
        .peer_wr(peer_wr), .peer_mac(48'h000A3501FEC1), .peer_ip(32'hC0A86403),
        .frame_busy(f_busy),
        .cfg_my_mac(48'h000A3501FEC0), .cfg_my_ip(32'hC0A86402),
        .cfg_my_port(16'd8081), .cfg_dst_port(16'd8081), .cfg_csum_en(1'b1),
        .s_axis_tdata(a_tdata), .s_axis_tkeep(a_tkeep), .s_axis_tvalid(a_tvalid),
        .s_axis_tready(a_tready), .s_axis_tlast(a_tlast),
        .m_axis_tdata(c_tdata), .m_axis_tkeep(c_tkeep), .m_axis_tvalid(c_tvalid),
        .m_axis_tready(c_tready), .m_axis_tlast(c_tlast),
        .o_dst_mac(c_dst_mac), .o_dst_ip(c_dst_ip), .o_dst_port(c_dst_port),
        .o_src_mac(c_src_mac), .o_src_ip(c_src_ip), .o_src_port(c_src_port),
        .o_csum_en(c_csum_en), .o_ready(c_ready),
        .stat_frames(c_frames), .stat_deny(c_deny)
    );

    udp_tx_frame u_frm (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(c_tdata), .s_axis_tkeep(c_tkeep), .s_axis_tvalid(c_tvalid),
        .s_axis_tready(c_tready), .s_axis_tlast(c_tlast),
        .cfg_src_mac(c_src_mac), .cfg_dst_mac(c_dst_mac),
        .cfg_src_ip(c_src_ip), .cfg_dst_ip(c_dst_ip),
        .cfg_src_port(c_src_port), .cfg_dst_port(c_dst_port),
        .cfg_csum_en(c_csum_en),
        .m_axis_tdata(f_tdata), .m_axis_tkeep(f_tkeep), .m_axis_tvalid(f_tvalid),
        .m_axis_tready(f_tready), .m_axis_tlast(f_tlast),
        .stat_frames(f_frames), .stat_bytes(f_bytes), .stat_drop_len(f_drop),
        .o_busy(f_busy)
    );

    // 下游 sink: 默认恒收; -testplusarg STALL ⇒ 每 8 拍停 1 拍 (帧器比 app 慢 ⇒
    //   字 FIFO 长期饱和 = **板级工况**, 丢字变成 100% 每帧 1 字)。
    reg  stall_en = 1'b0;
    reg  [7:0] cyc = 8'd0;
    always @(posedge clk) if (rst_n) cyc <= cyc + 8'd1;
    assign f_tready = !(stall_en && (cyc[2:0] == 3'd0));

    //=========================================================================
    // 探针 (全部 TB 侧, 不改 RTL)
    //=========================================================================
    wire app_push_dec = u_app.push_now || u_app.nul_push
`ifdef P7B_10G
                      || u_app.wide_ok
`endif
                      ;
    wire app_landed    = u_app.txf_wr && !u_app.txf_full;      // 真落笔 (两版同式)
    wire app_ovf       = u_app.u_txf.ovf_pulse;                // FIFO 内部拒写
    wire [3:0] ld_pc   = pc8(u_app.txf_in[71:64]);             // 落笔字的载荷字节数
`ifdef POSTFIX
    wire app_full_n    = u_app.txf_full_n;                     // 修复后才有
    wire [31:0] a_ovf  = u_app.stat_tx_ovf;                    // 修复后才有
`else
    wire app_full_n    = 1'b0;
    wire [31:0] a_ovf  = 32'd0;
`endif

    wire [9:0] occ_now = (u_app.u_txf.dbg_wptr - u_app.u_txf.dbg_rptr) & 10'h1FF;
    integer n_pushdec = 0, n_landed = 0, n_ovf = 0;
    integer land_bytes = 0;            // Σ popcount(tkeep) over landed words
    integer occ_max = 0, full_cyc = 0;
    integer q_pushdec = 0, q_landed = 0, q_land_bytes = 0, q_ovf = 0;
    reg     quiesced = 1'b0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (app_push_dec) n_pushdec <= n_pushdec + 1;
            if (app_landed) begin
                n_landed   <= n_landed + 1;
                land_bytes <= land_bytes + {28'b0, ld_pc};
            end
            if (app_ovf) n_ovf <= n_ovf + 1;
            if (occ_now > occ_max) occ_max <= occ_now;
            if (u_app.txf_full) full_cyc <= full_cyc + 1;
            if (!quiesced) begin       // 静止态前一刻的冻结副本 (对账用)
                q_pushdec <= n_pushdec; q_landed <= n_landed;
                q_land_bytes <= land_bytes; q_ovf <= n_ovf;
            end
        end
    end

    // ---- 帧器输出逐帧解码 ----
    integer frm_cnt = 0, frm_bytes = 0;
    integer len_min = 100000, len_max = 0;
    integer n1506 = 0, n1510 = 0, n1514 = 0, n1518 = 0, n_other = 0;
    integer cap_i = 0;
    reg [63:0] cap_w [0:3][0:7];
    integer i, j, k;
    // ---- 逐帧头字段 (W2: ip_tot@[63:48], W4: udp_len@[47:32]; 见 P7B_W9_GAP.md) ----
    // ⚠️ 必须**逐帧统计**而不是看第 0 帧: FIFO 起始为空 ⇒ **首帧恒不丢字**,
    //    丢字只出现在饱和之后 (实测前 2..3 帧干净), 拿 FRAME0 会得出错误结论。
    integer   ulw_i = 0;
    reg [15:0] cur_ulen = 16'd0, cur_iptot = 16'd0;
    integer n_ul1480 = 0, n_ul1472 = 0, n_ul_oth = 0;
    integer n_ip1500 = 0, n_ip1492 = 0, n_ip_oth = 0;
    reg [63:0] f5_w2 = 64'd0, f5_w4 = 64'd0;      // 第 5 帧 (帧号 5) 的 W2/W4

    always @(posedge clk) begin
        if (rst_n && f_tvalid && f_tready) begin
            frm_bytes <= frm_bytes + {28'b0, pc8(f_tkeep)};
            if ((cap_i < 6) && (frm_cnt == 0)) cap_w[0][cap_i] <= f_tdata;
            cap_i <= cap_i + 1;
            // 字节序 (lane0 = 首字节): w2 = bytes16..23 ⇒ ip_tot = bytes16-17 = [63:48];
            //                            w4 = bytes32..39 ⇒ udp_len = bytes38-39 = [15:0]
            if (ulw_i == 2) cur_iptot <= f_tdata[63:48];       // ip_tot
            if (ulw_i == 4) cur_ulen  <= f_tdata[15:0];        // udp_len
            if (frm_cnt == 5) begin
                if (ulw_i == 2) f5_w2 <= f_tdata;
                if (ulw_i == 4) f5_w4 <= f_tdata;
            end
            ulw_i <= ulw_i + 1;
            if (f_tlast) begin
                if ((frm_bytes + {28'b0, pc8(f_tkeep)}) < len_min)
                    len_min <= frm_bytes + {28'b0, pc8(f_tkeep)};
                if ((frm_bytes + {28'b0, pc8(f_tkeep)}) > len_max)
                    len_max <= frm_bytes + {28'b0, pc8(f_tkeep)};
                case (frm_bytes + {28'b0, pc8(f_tkeep)})
                    1506: n1506 <= n1506 + 1;
                    1510: n1510 <= n1510 + 1;
                    1514: n1514 <= n1514 + 1;
                    1518: n1518 <= n1518 + 1;
                    default: n_other <= n_other + 1;
                endcase
                case (cur_ulen)                     // 本帧真实 udp_len (头字段)
                    1480: n_ul1480 <= n_ul1480 + 1;
                    1472: n_ul1472 <= n_ul1472 + 1;
                    default: n_ul_oth <= n_ul_oth + 1;
                endcase
                case (cur_iptot)
                    1500: n_ip1500 <= n_ip1500 + 1;
                    1492: n_ip1492 <= n_ip1492 + 1;
                    default: n_ip_oth <= n_ip_oth + 1;
                endcase
                frm_cnt <= frm_cnt + 1;
                frm_bytes <= 0;
                cap_i <= 0;
                ulw_i <= 0;
            end
        end
    end

    // ---- 输出流指纹 (FNV-1a 64): 帧器输出 beats + app 计数 ----
    // 用途: **默认构建**下"修前 vs 修后"必须给出**逐位相同**的指纹 (行为等价);
    //       P7B_10G 下两者必须**不同** (修复改变了线上载荷)。
    reg  [63:0] hsh = 64'hCBF29CE484222325;
    wire [63:0] hterm = f_tdata ^ {56'b0, f_tkeep} ^ {63'b0, f_tlast};
    always @(posedge clk) if (rst_n && f_tvalid && f_tready)
        hsh <= (hsh ^ hterm) * 64'h100000001B3;

    initial begin
        for (i = 0; i < 4; i = i + 1)
            for (j = 0; j < 8; j = j + 1) cap_w[i][j] = 64'd0;
        if ($test$plusargs("STALL")) stall_en = 1'b1;
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (20) @(posedge clk);
        peer_wr = 1'b1;                       // learn-on-RX: 写入 peer 表
        @(posedge clk);
        peer_wr = 1'b0;
        run_en = 1'b1;                        // 开流
        repeat (20000) @(posedge clk);
        run_en = 1'b0;                        // 停流: 不启新帧
        repeat (400) @(posedge clk);          // 排空: 帧走完 + 无在飞推送
        @(posedge clk);
        quiesced = 1'b1;                      // 冻结副本
        @(posedge clk);
        $display("W9FIX STALL=%0d", stall_en);
        $display("W9FIX app: bytes=%0d frames=%0d pushdec=%0d landed=%0d land_bytes=%0d ovf_pulse=%0d",
                 a_tx_bytes, a_tx_frames, n_pushdec, n_landed, land_bytes, n_ovf);
        $display("W9FIX stat_tx_ovf=%0d (修前结构性不存在/恒 0)", a_ovf);
        $display("W9FIX RECON: stat_tx_bytes-land_bytes=%0d  pushdec-landed=%0d",
                 a_tx_bytes - land_bytes, n_pushdec - n_landed);
        $display("W9FIX fifo: occ_max=%0d full_cyc=%0d depth=256", occ_max, full_cyc);
        $display("W9FIX framer: frames=%0d bytes=%0d drop_len=%0d",
                 f_frames, f_bytes, f_drop);
        $display("W9FIX wire: frames=%0d len_min=%0d len_max=%0d n1506=%0d n1510=%0d n1514=%0d n1518=%0d nother=%0d",
                 frm_cnt, len_min, len_max, n1506, n1510, n1514, n1518, n_other);
        for (k = 0; k < 6; k = k + 1)
            $display("W9FIX FRAME0 w%0d=%h", k, cap_w[0][k]);
        $display("W9FIX hdr: udp_len1480=%0d udp_len1472=%0d oth=%0d | ip_tot1500=%0d ip_tot1492=%0d oth=%0d",
                 n_ul1480, n_ul1472, n_ul_oth, n_ip1500, n_ip1492, n_ip_oth);
        $display("W9FIX FRAME5 w2=%h w4=%h  (udp_len=w4[47:32], ip_tot=w2[63:48])", f5_w2, f5_w4);
        // 判据 (修后必须全 1; 修前 A/B 必须 0)
        $display("W9FIX JUDGE recon_zero=%0d  no_drop=%0d  ovf_zero=%0d",
                 (a_tx_bytes == land_bytes),
                 (n_pushdec == n_landed) && (n_ovf == 0),
                 (n_ovf == 0));
        $display("W9FIX HASH out=%h full=%h", hsh, hsh ^ {a_tx_bytes, a_tx_frames});
        $display("W9FIX END");
        $finish;
    end

endmodule
