#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""One-shot patch: replace the P7b instrumentation block in board/wrapper_p4.v
with the three-parallel-bundle version (snap_seq / tb_snap_seq untouched)."""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/board/wrapper_p4.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()
lines = s.split('\n')

start = None
for i, l in enumerate(lines):
    if l.startswith('    // P7b: 新增仪表的采集'):
        start = i
        break
assert start is not None, 'start marker not found'

end = None
for j in range(start, len(lines)):
    if lines[j].rstrip() == '`endif' and j > start + 10:
        end = j
        break
assert end is not None, 'end marker not found'
print('replacing file lines %d..%d' % (start + 1, end + 1))

NEW = r'''    // =====================================================================
    // P7b: 新增仪表的采集 (W36..W50) —— **三束并行**方案, 逐条给理由
    //----------------------------------------------------------------------
    // 为什么不把它们塞进 snap_seq 的 FE/DP 束 (那本来更"整齐"):
    //   snap_seq 的映射表是**单一来源 + 带自检**的 (rtl/snap_seq.v), 改它就必须同步改
    //   它的单元门 `tb/tb_snap_seq.v` 里那张**手抄的 36 行对照表**和一串硬写位宽。
    //   本轮的选择 = **不动那条已验收的路径**, 用**同一个 snap_cdc 原语**并行加三束,
    //   在 axi 域装配。代价 = 多三个 `seen` 锁存; 收益 = snap_seq / tb_snap_seq /
    //   axi_regs 的**接口一字未改** (只有读侧 `snap_base` 的位宽按扩窗规则加宽)。
    //
    // 三束 (全部 `clk_a = pcie_axi_aclk`, `req_a = snap_req` —— 主机那一个写脉冲):
    //   u_snap_p7bfe : clk_b = gmii_clk (= PCS 恢复钟)  NW=3  → W36/W37/W38
    //   u_snap_p7bdp : clk_b = dp_clk                   NW=12 → W39/W40, W45..W50
    //   u_snap_tx    : clk_b = tx_fe_clk (= tx_mii_clk) NW=4  → W41..W44
    // ⚠️ W41..W44 在 **tx 域** ⇒ 归 u_snap_tx (多比特计数器**不许** 2FF)。
    //    装配顺序见下面的 `snap_dout_all` (逐项写出, 不靠"拼接从右往左"这种记忆)。
    //
    // ⚠️ 同步手法逐条按 P7B_GATE1 §B4 的实证:
    //   · PCS 的 `stat_*`: 只有 `block_lock` 有网表实证 (dclk); 其余**域未确证**
    //     ⇒ 一律按异步处理, **每位一个 2FF** (电平信号)。`rx_error[7:0]` 是**逐 lane**
    //     的指示位 (每 bit 一条 lane), 位间偏斜不是"数值错误" ⇒ 每 bit 各一个 2FF 可以,
    //     但**语义必须按位读** (不得当 8 位数值引用)。
    //   · `block_lock` 本身在 dclk 域 (实证) ⇒ 同一个 2FF 手法对它是"跨域"而非"同步",
    //     但它是**慢变电平** ⇒ 2FF 是正确的处理 (不是脉冲)。
    //   · 三条新束与 snap_seq 的两束**同代**: 同一个 `snap_req` 触发, 完成后由
    //     `snap_valid_all` 一起放行 ⇒ 51 个字来自**同一代**读数。
    // =====================================================================
`ifdef P7B_10G
    // ---- PCS 状态位: 每位一个 2FF 进 dp 域 ----------------------------------
    (* ASYNC_REG = "TRUE" *) reg [2:0] pcs_blk_sr, pcs_st_sr, pcs_ber_sr, pcs_rlf_sr, pcs_tlf_sr;
    (* ASYNC_REG = "TRUE" *) reg [2:0] pcs_ferr_sr, pcs_ferrv_sr, pcs_bad_sr, pcs_badv_sr;
    (* ASYNC_REG = "TRUE" *) reg [2:0] pcs_fifo_sr, pcs_vcc_sr, pcs_erv_sr, pcs_gpw_sr;
    (* ASYNC_REG = "TRUE" *) reg [2:0] pcs_rtxrst_sr, pcs_ttxrst_sr;
    (* ASYNC_REG = "TRUE" *) reg [2:0] pcs_rerr_sr [7:0];
    integer pcs_i;
    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            pcs_blk_sr <= 3'd0; pcs_st_sr <= 3'd0; pcs_ber_sr <= 3'd0;
            pcs_rlf_sr <= 3'd0; pcs_tlf_sr <= 3'd0; pcs_ferr_sr <= 3'd0;
            pcs_ferrv_sr <= 3'd0; pcs_bad_sr <= 3'd0; pcs_badv_sr <= 3'd0;
            pcs_fifo_sr <= 3'd0; pcs_vcc_sr <= 3'd0; pcs_erv_sr <= 3'd0;
            pcs_gpw_sr <= 3'd0; pcs_rtxrst_sr <= 3'd0; pcs_ttxrst_sr <= 3'd0;
            for (pcs_i = 0; pcs_i < 8; pcs_i = pcs_i + 1) pcs_rerr_sr[pcs_i] <= 3'd0;
        end else begin
            pcs_blk_sr    <= {pcs_blk_sr[1:0],    pcs_blk_lock};
            pcs_st_sr     <= {pcs_st_sr[1:0],     pcs_rx_status};
            pcs_ber_sr    <= {pcs_ber_sr[1:0],    pcs_hi_ber};
            pcs_rlf_sr    <= {pcs_rlf_sr[1:0],    pcs_rx_localfault};
            pcs_tlf_sr    <= {pcs_tlf_sr[1:0],    pcs_tx_localfault};
            pcs_ferr_sr   <= {pcs_ferr_sr[1:0],   pcs_framing_err};
            pcs_ferrv_sr  <= {pcs_ferrv_sr[1:0],  pcs_framing_err_v};
            pcs_bad_sr    <= {pcs_bad_sr[1:0],    pcs_bad_code};
            pcs_badv_sr   <= {pcs_badv_sr[1:0],   pcs_bad_code_v};
            pcs_fifo_sr   <= {pcs_fifo_sr[1:0],   pcs_fifo_error};
            pcs_vcc_sr    <= {pcs_vcc_sr[1:0],    pcs_valid_ctrl_code};
            pcs_erv_sr    <= {pcs_erv_sr[1:0],    pcs_rx_error_v};
            pcs_gpw_sr    <= {pcs_gpw_sr[1:0],    pcs_gtpowergood_1};
            pcs_rtxrst_sr <= {pcs_rtxrst_sr[1:0], pcs_user_rx_reset_1};
            pcs_ttxrst_sr <= {pcs_ttxrst_sr[1:0], pcs_user_tx_reset_1};
            for (pcs_i = 0; pcs_i < 8; pcs_i = pcs_i + 1)
                pcs_rerr_sr[pcs_i] <= {pcs_rerr_sr[pcs_i][1:0], pcs_rx_error[pcs_i]};
        end
    end

    // ---- PCS 事件计数 (dp 域, 8 位饱和) -------------------------------------
    //   ⚠️ 口径写清: ferr/bad/erv 数的是 "同步后为高的 dp 拍数" —— **不是** PCS 的事件数
    //   (PCS 的 `_valid` 是 1 个 dclk 拍宽的脉冲, 2FF 后可能被展宽/合并)。
    //   ⇒ 用途是"这条线有没有动过"; ★ **不得当精确事件数引用**。
    reg [7:0] pcs_ferr_evt, pcs_bad_evt, pcs_erv_evt, pcs_vcc_cyc;
    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            pcs_ferr_evt <= 8'd0; pcs_bad_evt <= 8'd0;
            pcs_erv_evt  <= 8'd0; pcs_vcc_cyc <= 8'd0;
        end else begin
            if (pcs_ferr_sr[2] && (pcs_ferr_evt != 8'hFF)) pcs_ferr_evt <= pcs_ferr_evt + 8'd1;
            if (pcs_bad_sr[2]  && (pcs_bad_evt  != 8'hFF)) pcs_bad_evt  <= pcs_bad_evt  + 8'd1;
            if (pcs_erv_sr[2]  && (pcs_erv_evt  != 8'hFF)) pcs_erv_evt  <= pcs_erv_evt  + 8'd1;
            if (pcs_vcc_sr[2]  && (pcs_vcc_cyc  != 8'hFF)) pcs_vcc_cyc  <= pcs_vcc_cyc  + 8'd1;
        end
    end

    // ---- tx_mii_clk 活性锚点 (W50) -----------------------------------------
    //   "PCS 的 TX 时钟真的在跑吗"必须有**独立于 MAC 计数**的正证据:
    //   tx 域一个 1 位 toggle 跨到 dp, 数沿 ⇒ 频率 = 沿数/2。⚠️ 量化 ±1 沿。
    reg        tx_tgl_tx;
    always @(posedge tx_fe_clk or negedge reset_n) begin
        if (!reset_n) tx_tgl_tx <= 1'b0;
        else          tx_tgl_tx <= ~tx_tgl_tx;
    end
    (* ASYNC_REG = "TRUE" *) reg [2:0] tx_tgl_sr;
    reg [31:0] tx_clk_act;
    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin tx_tgl_sr <= 3'd0; tx_clk_act <= 32'd0; end
        else begin
            tx_tgl_sr <= {tx_tgl_sr[1:0], tx_tgl_tx};
            if (tx_tgl_sr[2] ^ tx_tgl_sr[1]) tx_clk_act <= tx_clk_act + 32'd1;
        end
    end

    // W39 = PCS 状态束 (31 位有效): 位域**写死在这里**, 判读照此拆。
    //   [31:30] 0 | [29] gtpowergood | [28] user_rx_reset | [27] user_tx_reset | [26:22] 0
    //   [21] rx_error_valid | [20:13] rx_error[7:0] (bit7=lane7) | [12] valid_ctrl_code
    //   [11] fifo_error | [10] bad_code_valid | [9] bad_code | [8] framing_err_valid
    //   [7] framing_err | [6] tx_local_fault | [5] rx_local_fault | [4] hi_ber
    //   [3] rx_status | [2] block_lock | [1:0] 0
    assign pcs_status_bundle = {2'd0,
        pcs_gpw_sr[2], pcs_rtxrst_sr[2], pcs_ttxrst_sr[2], 5'd0,
        pcs_erv_sr[2],
        pcs_rerr_sr[7][2], pcs_rerr_sr[6][2], pcs_rerr_sr[5][2], pcs_rerr_sr[4][2],
        pcs_rerr_sr[3][2], pcs_rerr_sr[2][2], pcs_rerr_sr[1][2], pcs_rerr_sr[0][2],
        pcs_vcc_sr[2], pcs_fifo_sr[2], pcs_badv_sr[2], pcs_bad_sr[2],
        pcs_ferrv_sr[2], pcs_ferr_sr[2], pcs_tlf_sr[2], pcs_rlf_sr[2],
        pcs_ber_sr[2], pcs_st_sr[2], pcs_blk_sr[2], 2'd0};
    assign pcs_evt_bundle = {pcs_ferr_evt, pcs_bad_evt, pcs_erv_evt, pcs_vcc_cyc};
`else
    // 非 P7B 构建: 这些源**不存在** ⇒ 常量占位 (装配出来恒 0, 是预期的, 不是缺陷)。
    //   ⚠️ 常量满足 snap_cdc 的前提 ("din_b 只在 clk_b 沿变化")。
    wire [31:0]  pcs_status_bundle = 32'd0;
    wire [31:0]  pcs_evt_bundle    = 32'd0;
    wire [31:0]  tx_clk_act        = 32'd0;
`endif

    // ---- P7b: 三束 (全部在 axi 域装配) ---------------------------------------
    //   ⚠️ `dout_a` 拆成逐槽的命名线是为了让装配段可逐项写清槽号 (避免"数拼接"的错)。
    wire [31:0] p7bfe_dout [0:2];
    wire [31:0] p7bdp_dout [0:11];
    wire [31:0] txsnap_dout [0:3];
    wire        p7bfe_valid, p7bdp_valid, txsnap_valid;
    wire        p7bfe_busy,  p7bdp_busy,  txsnap_busy;

`ifdef P7B_10G
    wire [95:0]  p7bfe_din = {rxcdc_ovf_cnt,          // 槽 2 → W38 (wr 域 = FE)
                              mrx_stat_rx_pay_bytes,  // 槽 1 → W37
                              mrx_stat_rx_words};     // 槽 0 → W36
    wire [127:0] txsnap_din = {mtx_stat_tx_ctrl_char, // 槽 3 → W44
                               mtx_stat_tx_words,     // 槽 2 → W43
                               mtx_stat_flush_done,   // 槽 1 → W42
                               mtx_stat_flush_words}; // 槽 0 → W41
`else
    wire [95:0]  p7bfe_din  = 96'd0;
    wire [127:0] txsnap_din = 128'd0;
`endif

    // p7bdp 的 12 个槽: 槽 0/1/6..11 是本模块的信号, 槽 2..5 由 **tx 束**搬来
    //   (W41..W44 在 tx_mii_clk 域, 不能在这里引用) ⇒ 这里只驱动自己的那些槽,
    //   装配时 (snap_dout_all) 才把 tx 束的 4 个字插到 W41..W44 的位置。
    wire [383:0] p7bdp_din;
    genvar gi;
    generate
        for (gi = 0; gi < 12; gi = gi + 1) begin : g_p7bdp
            assign p7bdp_din[gi*32 +: 32] =
                (gi == 0)  ? pcs_status_bundle :        // W39
                (gi == 1)  ? pcs_evt_bundle    :        // W40
                (gi == 6)  ? txcdc_ovf_cnt     :        // W45 (wr 域 = DP)
                (gi == 7)  ? cls_dbg_stat_ovf  :        // W46
                (gi == 8)  ? cls_dbg_stat_route_ovf :   // W47
                (gi == 9)  ? cls_dbg_stat_stall_in  :   // W48
                (gi == 10) ? {27'd0, cls_dbg_occ}   :   // W49 (5 位)
                (gi == 11) ? tx_clk_act        :        // W50
                            32'd0;                      // 槽 2..5: 由 tx 束装配
        end
    endgenerate

    snap_cdc #(.W(32), .NW(3)) u_snap_p7bfe (
        .clk_a(pcie_axi_aclk), .rst_n(pcie_axi_aresetn), .req_a(snap_req),
        .busy_a(p7bfe_busy),
        .dout_a({p7bfe_dout[2], p7bfe_dout[1], p7bfe_dout[0]}),
        .valid_a(p7bfe_valid), .clk_b(gmii_clk), .din_b(p7bfe_din)
    );
    snap_cdc #(.W(32), .NW(12)) u_snap_p7bdp (
        .clk_a(pcie_axi_aclk), .rst_n(pcie_axi_aresetn), .req_a(snap_req),
        .busy_a(p7bdp_busy),
        .dout_a({p7bdp_dout[11], p7bdp_dout[10], p7bdp_dout[9], p7bdp_dout[8],
                 p7bdp_dout[7],  p7bdp_dout[6],  p7bdp_dout[5], p7bdp_dout[4],
                 p7bdp_dout[3],  p7bdp_dout[2],  p7bdp_dout[1], p7bdp_dout[0]}),
        .valid_a(p7bdp_valid), .clk_b(dp_clk), .din_b(p7bdp_din)
    );
    snap_cdc #(.W(32), .NW(4)) u_snap_tx (
        .clk_a(pcie_axi_aclk), .rst_n(pcie_axi_aresetn), .req_a(snap_req),
        .busy_a(txsnap_busy),
        .dout_a({txsnap_dout[3], txsnap_dout[2], txsnap_dout[1], txsnap_dout[0]}),
        .valid_a(txsnap_valid), .clk_b(tx_fe_clk), .din_b(txsnap_din)
    );

    // ---- 三条新束的 `seen` 锁存 + 完成门 ------------------------------------
    //   `snap_valid_all` 才是给 axi_regs 的 "可以采了": 它要求 **snap_seq 的两束 +
    //   三条新束**在本代**都到齐 (任一条早到不构成完成 —— 那是"读到半代快照")。
    //   清位 = 下一次 `snap_req` (同一代的分界)。
    reg p7bfe_seen, p7bdp_seen, tx_seen;
    always @(posedge pcie_axi_aclk or negedge pcie_axi_aresetn) begin
        if (!pcie_axi_aresetn) begin
            p7bfe_seen <= 1'b0; p7bdp_seen <= 1'b0; tx_seen <= 1'b0;
        end else begin
            if (snap_req)      begin p7bfe_seen <= 1'b0; p7bdp_seen <= 1'b0; tx_seen <= 1'b0; end
            else begin
                if (p7bfe_valid) p7bfe_seen <= 1'b1;
                if (p7bdp_valid) p7bdp_seen <= 1'b1;
                if (txsnap_valid) tx_seen   <= 1'b1;
            end
        end
    end
    wire snap_valid_all = snap_valid & p7bfe_seen & p7bdp_seen & tx_seen;

    // ---- 51 字装配 (**逐项写出**: 每项的槽号在注释里, 不依赖"从右往左"的记忆) ----
    //   ⚠️ 这条总线是 axi 域的组合量, 源全是 snap_cdc 的 `dout_a` 寄存器 ⇒ 采集沿稳定。
    //   ⚠️ 非 P7B 构建里三条新束的 din 全是常量 ⇒ 后 15 个字读回恒 0 (预期, 不是缺陷)。
    wire [SNAP_NW_P6E*32-1:0] snap_dout_all = {
        p7bdp_dout[11],   // W50 tx_mii_clk 活性 (toggle 沿计数)
        p7bdp_dout[10],   // W49 rx_classify 字 FIFO 当前占用
        p7bdp_dout[9],    // W48 rx_classify 输入停等拍数
        p7bdp_dout[8],    // W47 rx_classify 路由队列拒写 (恒 0)
        p7bdp_dout[7],    // W46 rx_classify 字 FIFO 拒写   (恒 0)
        p7bdp_dout[6],    // W45 u_txcdc 拒写 (wr 域 = DP)
        txsnap_dout[3],   // W44 mac_tx_10g.stat_tx_ctrl_char
        txsnap_dout[2],   // W43 mac_tx_10g.stat_tx_words
        txsnap_dout[1],   // W42 mac_tx_10g.stat_flush_done
        txsnap_dout[0],   // W41 mac_tx_10g.stat_flush_words
        p7bdp_dout[5],    // W40 PCS 事件束
        p7bdp_dout[4],    // W39 PCS 状态束
        p7bfe_dout[2],    // W38 u_rxcdc 拒写 (wr 域 = FE)
        p7bfe_dout[1],    // W37 mac_rx_10g Σpopc(tkeep) 已交付
        p7bfe_dout[0],    // W36 mac_rx_10g XGMII 字数 (速率正证据)
        snap_dout};       // W35..W0 (snap_seq 装配, 原样)
'''

lines[start:end + 1] = NEW.split('\n')
io.open(P, 'w', encoding='utf-8', newline='').write('\n'.join(lines))
print('patched OK')
