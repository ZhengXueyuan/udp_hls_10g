# patch_top.py -- apply the round-2 additions to rtl/xxv_loop_top.v.
# Written as a file (not python -c) because the Windows paths and the RTL quotes
# do not survive bash -> heredoc -> python quoting.
import io

p = 'rtl/xxv_loop_top.v'
s = io.open(p, encoding='utf-8').read()


def rep(a, b, n=1):
    global s
    assert s.count(a) == n, ('count=%d pattern=%r' % (s.count(a), a[:80]))
    s = s.replace(a, b)


# (a) new VIO control wires
rep("""    wire       vio_send_cont, vio_cmd_restart, vio_cmd_sysreset;
    wire       vio_cmd_sfp1_tx_dis, vio_cmd_sfp2_tx_dis, vio_cmd_snap;""",
    """    wire       vio_send_cont, vio_cmd_restart, vio_cmd_sysreset;
    wire       vio_cmd_sfp1_tx_dis, vio_cmd_sfp2_tx_dis, vio_cmd_snap;
    wire [2:0] vio_gt_loopback;   // ch0 GT loopback mode (gate 1a witness)
    wire       vio_pay_sel;       // 0 = vendor all-zero payload, 1 = all-ones""")

# (b) loopback driving (was tied to 3'b000)
rep("        .gt_loopback_in_0                 (3'b000),",
    "        .gt_loopback_in_0                 (vio_gt_loopback),")

# (c) traffic module: the parameterised copy
rep("    pcs64_pkt_gen_mon #(", "    pcs64_pkt_gen_mon_ds #(")
rep("        .send_continuous_pkts          (vio_send_cont),",
    "        .send_continuous_pkts          (vio_send_cont),\n"
    "        .pay_sel                       (vio_pay_sel),")

# (d) checkers: pay_sel + e_pre/e_post
rep("""    xgmii_rx_chk u_chk0 (
        .clk_rx      (rx_core_clk_0),
        .rst         (user_rx_reset_0),
        .d           (rx_mii_d_0),""",
    """    wire [31:0] e_pre0, e_post0, e_pre1, e_post1;
    xgmii_rx_chk u_chk0 (
        .clk_rx      (rx_core_clk_0),
        .rst         (user_rx_reset_0),
        .pay_sel     (vio_pay_sel),
        .d           (rx_mii_d_0),""")
rep("""        .o_t_lane    (c0_tlane),   .o_in_frame(c0_inframe)
    );""",
    """        .o_t_lane    (c0_tlane),   .o_in_frame(c0_inframe),
        .o_e_pre     (e_pre0),     .o_e_post   (e_post0)
    );""")
rep("""    xgmii_rx_chk u_chk1 (
        .clk_rx      (rx_core_clk_1),
        .rst         (user_rx_reset_1),
        .d           (rx_mii_d_1),""",
    """    xgmii_rx_chk u_chk1 (
        .clk_rx      (rx_core_clk_1),
        .rst         (user_rx_reset_1),
        .pay_sel     (vio_pay_sel),
        .d           (rx_mii_d_1),""")
rep("""        .o_t_lane    (c1_tlane),   .o_in_frame(c1_inframe)
    );""",
    """        .o_t_lane    (c1_tlane),   .o_in_frame(c1_inframe),
        .o_e_pre     (e_pre1),     .o_e_post   (e_post1)
    );""")

# (e) the stat_* clock-domain probe
rep("    // ------------------------------------------------ free-running counters",
    """    // --------------------------------- stat_* CLOCK DOMAIN probe (spec U8)
    // The same four stat_* signals are counted TWICE: once in dclk (where the
    // next round's MAC will sample them) and once in the ch1 recovered clock.
    //   * a dclk-domain pulse (>=10 ns) is caught by BOTH  -> counts equal
    //   * an rx-domain pulse (6.4 ns) is caught by the rx counter and MISSED
    //     roughly a third of the time by the dclk counter -> rx > dclk
    //   * a LEVEL held for the same wall time gives counts in the ratio of the
    //     clock frequencies (dclk:rx ~ 0.64) -- a third, distinct signature
    // That is what turns U8 ("presumed dclk") into something measurable.
    reg [31:0] s_vcc_d, s_ferr_d, s_bcd_d, s_ffe_d;
    always @(posedge dclk) begin
        if (stat_rx_valid_ctrl_code_1)             s_vcc_d  <= s_vcc_d  + 32'd1;
        if (stat_rx_framing_err_valid_1 & ferr1_s) s_ferr_d <= s_ferr_d + 32'd1;
        if (stat_rx_bad_code_valid_1 & bcd1_s)     s_bcd_d  <= s_bcd_d  + 32'd1;
        if (stat_rx_fifo_error_1)                  s_ffe_d  <= s_ffe_d  + 32'd1;
    end
    reg [31:0] s_vcc_r, s_ferr_r, s_bcd_r, s_ffe_r, s_errv_r;
    always @(posedge rx_core_clk_1) begin
        if (user_rx_reset_1) begin
            s_vcc_r <= 32'd0; s_ferr_r <= 32'd0; s_bcd_r <= 32'd0;
            s_ffe_r <= 32'd0; s_errv_r <= 32'd0;
        end else begin
            if (stat_rx_valid_ctrl_code_1)                           s_vcc_r  <= s_vcc_r  + 32'd1;
            if (stat_rx_framing_err_valid_1 & stat_rx_framing_err_1) s_ferr_r <= s_ferr_r + 32'd1;
            if (stat_rx_bad_code_valid_1 & stat_rx_bad_code_1)       s_bcd_r  <= s_bcd_r  + 32'd1;
            if (stat_rx_fifo_error_1)                                s_ffe_r  <= s_ffe_r  + 32'd1;
            if (stat_rx_error_valid_1)                               s_errv_r <= s_errv_r + 32'd1;
        end
    end

    // ------------------------------------------------ free-running counters""")

# (f) buses: extend rx1 and rx0 with the rx-domain probes
rep("""    wire [479:0] rx1_bus = {rx1_free, {c1_sc, c1_tlane, 4'b0, c1_inframe, 15'b0},
                            c1_idle, c1_lastw, c1_abort, c1_badlen, c1_badterm,
                            c1_badhdr, c1_badstart, c1_badpay, c1_pay, c1_e,
                            c1_ctrl, c1_frames, c1_words};
    wire [479:0] rx1_hold;""",
    """    wire [703:0] rx1_bus = {e_post1, e_pre1, s_errv_r, s_ffe_r, s_bcd_r, s_ferr_r,
                            s_vcc_r,
                            rx1_free, {c1_sc, c1_tlane, 4'b0, c1_inframe, 15'b0},
                            c1_idle, c1_lastw, c1_abort, c1_badlen, c1_badterm,
                            c1_badhdr, c1_badstart, c1_badpay, c1_pay, c1_e,
                            c1_ctrl, c1_frames, c1_words};
    wire [703:0] rx1_hold;""")
rep("    snap_hold #(.W(480)) u_snap_rx1 (", "    snap_hold #(.W(704)) u_snap_rx1 (")
rep("""    wire [255:0] rx0_bus = {rx0_free, c0_badterm, c0_abort, c0_frames,
                            c0_e, c0_idle, c0_ctrl, c0_words};
    wire [255:0] rx0_hold;""",
    """    wire [319:0] rx0_bus = {e_post0, e_pre0, rx0_free, c0_badterm, c0_abort,
                            c0_frames, c0_e, c0_idle, c0_ctrl, c0_words};
    wire [319:0] rx0_hold;""")
rep("    snap_hold #(.W(256)) u_snap_rx0 (", "    snap_hold #(.W(320)) u_snap_rx0 (")
# rx0_free moved from [255:224] to [319:288]
rep("obs_reg #(.W(32)) r06 (.clk(dclk), .d(rx0_hold[255:224]),    .q(oi06));",
    "obs_reg #(.W(32)) r06 (.clk(dclk), .d(rx0_hold[319:288]),    .q(oi06));")

# (g) new probes 34..47
rep("    wire [31:0] oi30, oi31, oi32, oi33;",
    "    wire [31:0] oi30, oi31, oi32, oi33, oi34, oi35, oi36, oi37, oi38, oi39;\n"
    "    wire [31:0] oi40, oi41, oi42, oi43, oi44, oi45, oi46, oi47;")
rep("    obs_reg #(.W(32)) r33 (.clk(dclk), .d(dclk_hold),            .q(oi33));",
    """    obs_reg #(.W(32)) r33 (.clk(dclk), .d(dclk_hold),            .q(oi33));
    obs_reg #(.W(32)) r34 (.clk(dclk), .d(err_w),                .q(oi34));
    obs_reg #(.W(32)) r35 (.clk(dclk), .d(dclk_hold),            .q(oi35));
    // stat_* domain probe: dclk-domain count and rx-domain count side by side
    obs_reg #(.W(32)) r36 (.clk(dclk), .d(s_vcc_d),              .q(oi36));
    obs_reg #(.W(32)) r37 (.clk(dclk), .d(rx1_hold[511:480]),    .q(oi37));
    obs_reg #(.W(32)) r38 (.clk(dclk), .d(s_ferr_d),             .q(oi38));
    obs_reg #(.W(32)) r39 (.clk(dclk), .d(rx1_hold[543:512]),    .q(oi39));
    obs_reg #(.W(32)) r40 (.clk(dclk), .d(s_bcd_d),              .q(oi40));
    obs_reg #(.W(32)) r41 (.clk(dclk), .d(rx1_hold[575:544]),    .q(oi41));
    obs_reg #(.W(32)) r42 (.clk(dclk), .d(s_ffe_d),              .q(oi42));
    obs_reg #(.W(32)) r43 (.clk(dclk), .d(rx1_hold[607:576]),    .q(oi43));
    obs_reg #(.W(32)) r44 (.clk(dclk), .d(rx1_hold[639:608]),    .q(oi44));
    obs_reg #(.W(32)) r45 (.clk(dclk), .d(rx1_hold[671:640]),    .q(oi45));
    obs_reg #(.W(32)) r46 (.clk(dclk), .d(rx1_hold[703:672]),    .q(oi46));
    obs_reg #(.W(32)) r47 (.clk(dclk), .d(rx0_hold[287:256]),    .q(oi47));""")

# (h) VIO instance: 48 probe_in, 8 probe_out
rep("        .probe_in32 (oi32),  .probe_in33(oi33),",
    """        .probe_in32 (oi32),  .probe_in33(oi33),  .probe_in34(oi34),
        .probe_in35 (oi35),  .probe_in36(oi36),  .probe_in37(oi37),
        .probe_in38 (oi38),  .probe_in39(oi39),  .probe_in40(oi40),
        .probe_in41 (oi41),  .probe_in42(oi42),  .probe_in43(oi43),
        .probe_in44 (oi44),  .probe_in45(oi45),  .probe_in46(oi46),
        .probe_in47 (oi47),""")
rep("        .probe_out5 (vio_cmd_snap)\n    );",
    """        .probe_out5 (vio_cmd_snap),
        .probe_out6 (vio_gt_loopback),
        .probe_out7 (vio_pay_sel)
    );""")

io.open(p, 'w', encoding='utf-8').write(s)
print('xxv_loop_top.v patched: probes/dirs/loopback/pay_sel/stat-domain counters')
