#!/usr/bin/env python3
# ===========================================================================
# make_xxv_mac_top.py -- generate xxv_mac_top.v (xxv_loop_top + the P7b MAC)
# from the byte-exact copy of xxv_loop_top.v.  Every substitution is asserted
# to happen EXACTLY ONCE, so a silent no-op is impossible.
# ===========================================================================
import hashlib, sys, io, os

B   = r"D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\p7b_mac_synth\xxv_mac"
SRC = os.path.join(B, "rtl", "xxv_loop_top.v")
DST = os.path.join(B, "rtl", "xxv_mac_top.v")

raw = io.open(SRC, "r", encoding="utf-8", newline="").read()
print("SRC_SHA256 %s" % hashlib.sha256(raw.encode("utf-8")).hexdigest())
print("SRC_BYTES  %d" % len(raw.encode("utf-8")))
print("SRC_CRLF_N %d" % raw.count("\r\n"))
# patch on LF, write back CRLF (the source file is CRLF; the copy stays CRLF)
src = raw.replace("\r\n", "\n")
assert "\r" not in src, "stray CR in the source"

def sub1(txt, old, new, label):
    n = txt.count(old)
    assert n == 1, "PATCH %s: expected 1 occurrence, found %d" % (label, n)
    print("PATCH_OK %-28s (1 occurrence replaced)" % label)
    return txt.replace(old, new)

# --- 1. module name -------------------------------------------------------
src = sub1(src,
    "module xxv_loop_top (",
    "module xxv_mac_top (",
    "module-rename")

# --- 2. the ch1 TX constants are replaced by the MAC ----------------------
src = sub1(src,
"""    // X0Y5 transmits a constant 64b/66b IDLE stream (/I/ = 0x07, c=1 on every
    // lane).  10GBASE-R requires a continuous block stream, and it hands the
    // X0Y4 receiver a real signal to lock onto.
    assign tx_mii_d_1 = 64'h0707070707070707;
    assign tx_mii_c_1 = 8'hFF;""",
"""    // X0Y5 used to transmit a constant 64b/66b IDLE stream (/I/ = 0x07, c=1 on
    // every lane).  In THIS build (P7b MAC timing/area probe) that constant is
    // replaced by mac_tx_10g -- see the MAC integration block further down.
    // The MAC emits /I/ words whenever it is idle, so the 64b/66b block stream
    // stays continuous either way.  Nothing else about X0Y5 changes.""",
    "ch1-tx-constant-removed")

# --- 3. the MAC integration block, inserted before the VIO instantiation ---
MAC_BLOCK = r"""
    // =====================================================================
    //  P7b 64-bit XGMII MAC -- INTEGRATION FOR TIMING/AREA MEASUREMENT
    // =====================================================================
    //  This build exists to answer one question: does mac_rx_10g / mac_tx_10g
    //  close timing on xcku5p-ffvb676-1-e when it is glued to the official
    //  xxv_ethernet PCS/PMA?  The MAC is therefore wired to LIVE data and is
    //  NOT tied off anywhere:
    //
    //    mac_rx_10g : clock = rx_core_clk_1  (the X0Y5 CDR-RECOVERED clock),
    //                 input = the REAL XGMII receive bus rx_mii_d_1/rx_mii_c_1,
    //                 m_axis_tready = 1, so it decodes every received word and
    //                 its CRC engine runs on every word of every frame.
    //
    //    mac_tx_10g : clock = tx_mii_clk_1, DRIVES the X0Y5 transmitter
    //                 (tx_mii_d_1 / tx_mii_c_1) in place of the idle constant.
    //                 Its upstream is the frame feeder below.
    //
    //  X0Y4 -- the vendor test's judged direction -- is untouched, and so is
    //  the receiver on X0Y5.  Only a constant was removed.
    //
    //  Every MAC output is consumed by the signature registers below, so
    //  nothing is trimmed and the reported area is the real area.
    // =====================================================================

    wire        mac_tx_rst_n = ~user_tx_reset_1;
    wire        mac_rx_rst_n = ~user_rx_reset_1;

    // ---- TX feeder: alternating 60-byte / 1514-byte content frames ---------
    reg  [15:0] fd_len;      // content length of the frame in flight
    reg  [15:0] fd_cnt;      // content bytes already handed over
    reg         fd_long;
    reg  [63:0] fd_lfsr;
    wire        mac_tx_ready;   // DECLARED ON PURPOSE: an undeclared net used as a
                                // port connection is the project's trap-24 defect
                                // (Vivado 2025.2 reports Synth 8-11241), and this
                                // probe file must stay clean for the hard gates.
    wire [15:0] fd_left = fd_len - fd_cnt;
    wire [3:0]  fd_k    = (fd_left >= 16'd8) ? 4'd8 : fd_left[3:0];
    wire        fd_last = (fd_left <= 16'd8);
    wire [7:0]  fd_keep = (fd_k >= 4'd8) ? 8'hFF : (8'hFF << (4'd8 - fd_k));

    always @(posedge tx_mii_clk_1 or negedge mac_tx_rst_n) begin
        if (!mac_tx_rst_n) begin
            fd_len  <= 16'd60;
            fd_cnt  <= 16'd0;
            fd_long <= 1'b0;
            fd_lfsr <= 64'h0123456789ABCDEF;
        end else begin
            fd_lfsr <= {fd_lfsr[62:0], fd_lfsr[63] ^ fd_lfsr[62] ^ fd_lfsr[60] ^ fd_lfsr[59]};
            if (mac_tx_ready) begin
                if (fd_last) begin
                    fd_long <= ~fd_long;
                    fd_len  <= fd_long ? 16'd60 : 16'd1514;
                    fd_cnt  <= 16'd0;
                end else begin
                    fd_cnt <= fd_cnt + {12'd0, fd_k};
                end
            end
        end
    end

    wire [31:0] mtx_frames, mtx_abort, mtx_fw, mtx_fd, mtx_words, mtx_ctrl, mtx_short;
    wire [15:0] mtx_clen;
    wire [1:0]  mtx_state;

    mac_tx_10g u_mac_tx (
        .clk               (tx_mii_clk_1),
        .rst_n             (mac_tx_rst_n),
        .s_axis_tdata      (fd_lfsr),
        .s_axis_tkeep      (fd_keep),
        .s_axis_tvalid     (1'b1),
        .s_axis_tready     (mac_tx_ready),
        .s_axis_tlast      (fd_last),
        .xgmii_txd         (tx_mii_d_1),
        .xgmii_txc         (tx_mii_c_1),
        .stat_frames       (mtx_frames),
        .stat_abort        (mtx_abort),
        .stat_flush_words  (mtx_fw),
        .stat_flush_done   (mtx_fd),
        .stat_tx_words     (mtx_words),
        .stat_tx_ctrl_char (mtx_ctrl),
        .stat_tx_short     (mtx_short),
        .dbg_tx_last_clen  (mtx_clen),
        .dbg_tx_state      (mtx_state)
    );

    // ---- RX side -----------------------------------------------------------
    wire [63:0] mrx_tdata;
    wire [7:0]  mrx_tkeep;
    wire        mrx_tvalid, mrx_tlast, mrx_tuser, mrx_tcrs, mrx_terr;
    wire [31:0] mrx_frames, mrx_crcerr, mrx_drop, mrx_bytes;
    wire [31:0] mrx_dfull, mrx_dpart, mrx_orph, mrx_ovf, mrx_wout;
    wire [31:0] mrx_words, mrx_pay, mrx_erw, mrx_badw;
    wire [31:0] mrx_frag, mrx_nos, mrx_q, mrx_short, mrx_long;
    wire [15:0] mrx_len;
    wire [3:0]  mrx_tlane;
    wire [1:0]  mrx_state;

    mac_rx_10g u_mac_rx (
        .clk                (rx_core_clk_1),
        .rst_n              (mac_rx_rst_n),
        .xgmii_rxd          (rx_mii_d_1),
        .xgmii_rxc          (rx_mii_c_1),
        .m_axis_tdata       (mrx_tdata),
        .m_axis_tkeep       (mrx_tkeep),
        .m_axis_tvalid      (mrx_tvalid),
        .m_axis_tready      (1'b1),
        .m_axis_tlast       (mrx_tlast),
        .m_axis_tuser       (mrx_tuser),
        .m_axis_tcrs        (mrx_tcrs),
        .m_axis_terr        (mrx_terr),
        .stat_frames        (mrx_frames),
        .stat_crc_err       (mrx_crcerr),
        .stat_drop          (mrx_drop),
        .stat_bytes         (mrx_bytes),
        .stat_drop_full     (mrx_dfull),
        .stat_drop_partial  (mrx_dpart),
        .stat_orphan_bytes  (mrx_orph),
        .stat_fifo_ovf      (mrx_ovf),
        .dbg_stat_words_out (mrx_wout),
        .stat_rx_words      (mrx_words),
        .stat_rx_pay_bytes  (mrx_pay),
        .stat_rx_er_words   (mrx_erw),
        .stat_rx_bad_words  (mrx_badw),
        .stat_rx_frag       (mrx_frag),
        .stat_rx_no_s       (mrx_nos),
        .stat_rx_q          (mrx_q),
        .stat_rx_short      (mrx_short),
        .stat_rx_long       (mrx_long),
        .dbg_rx_last_len    (mrx_len),
        .dbg_rx_last_tlane  (mrx_tlane),
        .dbg_rx_state       (mrx_state)
    );

    // ---- signature registers: keep every MAC output live -------------------
    // An XOR-reduce pulls in EVERY bit of every counter (so none of the adder
    // chains can be trimmed) at a cost of one 32-input XOR per domain -- it
    // sits behind the counters, NOT on the MAC's own critical path.
    wire [31:0] mtx_live = mtx_frames ^ mtx_abort ^ mtx_fw ^ mtx_fd ^ mtx_words
                         ^ mtx_ctrl ^ mtx_short ^ {16'd0, mtx_clen}
                         ^ {30'd0, mtx_state};
    reg  [31:0] mtx_sig = 32'd0;
    always @(posedge tx_mii_clk_1) mtx_sig <= {mtx_sig[30:0], ^mtx_live};

    wire [31:0] mrx_live = mrx_frames ^ mrx_crcerr ^ mrx_drop ^ mrx_bytes
                         ^ mrx_dfull ^ mrx_dpart ^ mrx_orph ^ mrx_ovf ^ mrx_wout
                         ^ mrx_words ^ mrx_pay ^ mrx_erw ^ mrx_badw
                         ^ mrx_frag ^ mrx_nos ^ mrx_q ^ mrx_short ^ mrx_long
                         ^ {16'd0, mrx_len} ^ {28'd0, mrx_tlane}
                         ^ {30'd0, mrx_state}
                         ^ mrx_tdata[63:32] ^ mrx_tdata[31:0]
                         ^ {24'd0, mrx_tkeep} ^ {31'd0, mrx_tvalid}
                         ^ {31'd0, mrx_tlast} ^ {31'd0, mrx_tuser}
                         ^ {31'd0, mrx_tcrs} ^ {31'd0, mrx_terr};
    reg  [31:0] mrx_sig = 32'd0;
    always @(posedge rx_core_clk_1) mrx_sig <= {mrx_sig[30:0], ^mrx_live};

    // cross into the observer domain through the project's own toggle-handshake
    // snapshot primitive (never through two flops)
    wire [31:0] mtx_sig_hold, mrx_sig_hold;
    wire        ack_mtx, gen_mtx, ack_mrx, gen_mrx;
    snap_hold #(.W(32)) u_snap_mactx (
        .src_clk(tx_mii_clk_1), .obs_clk(dclk),
        .obs_req(snap_req_tgl), .obs_ack(ack_mtx), .obs_gen(gen_mtx),
        .din(mtx_sig), .dout(mtx_sig_hold));
    snap_hold #(.W(32)) u_snap_macrx (
        .src_clk(rx_core_clk_1), .obs_clk(dclk),
        .obs_req(snap_req_tgl), .obs_ack(ack_mrx), .obs_gen(gen_mrx),
        .din(mrx_sig), .dout(mrx_sig_hold));

"""
src = sub1(src,
    "    // one obs_reg per probe_in:",
    MAC_BLOCK + "    // one obs_reg per probe_in:",
    "mac-block-inserted")

# --- 4. put the two spare probes onto the MAC signatures -------------------
src = sub1(src,
    "    obs_reg #(.W(32)) r34 (.clk(dclk), .d(err_w),                .q(oi34));",
    "    // P7b: oi34/oi35 used to duplicate err_w / dclk_hold (spare slots).\n"
    "    // They now carry the P7b MAC signature registers: probe_in34 = MAC TX,\n"
    "    // probe_in35 = MAC RX.  No probe count or width changed.\n"
    "    obs_reg #(.W(32)) r34 (.clk(dclk), .d(mtx_sig_hold),         .q(oi34));",
    "probe34-rewire")
src = sub1(src,
    "    obs_reg #(.W(32)) r35 (.clk(dclk), .d(dclk_hold),            .q(oi35));",
    "    obs_reg #(.W(32)) r35 (.clk(dclk), .d(mrx_sig_hold),         .q(oi35));",
    "probe35-rewire")

# --- 5. LED: surface the MAC error flags (also keeps them live) ------------
src = sub1(src,
    "    assign led[3] = c1_e[0] | ferr0_s | ferr1_s;   // any error indication",
    "    assign led[3] = c1_e[0] | ferr0_s | ferr1_s   // any error indication\n"
    "                  | mrx_terr | mrx_crcerr[0] | mtx_abort[0];",
    "led3-mac-error")

out = src.replace("\n", "\r\n")
io.open(DST, "w", encoding="utf-8", newline="").write(out)
print("DST_WROTE  %s" % DST)
print("DST_SHA256 %s" % hashlib.sha256(out.encode("utf-8")).hexdigest())
print("DST_BYTES  %d" % len(out.encode("utf-8")))
print("DST_CRLF_N %d" % out.count("\r\n"))
print("PATCH_VERDICT = OK")
