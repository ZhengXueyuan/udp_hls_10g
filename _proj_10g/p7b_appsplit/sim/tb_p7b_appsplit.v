`timescale 1ns/1ps
// ===========================================================================
// tb_p7b_appsplit.v -- P7b app-UDP split-path root-cause probe
// ===========================================================================
// 目的: 复现"发往 192.168.100.2:8081 的 UDP 帧被交给 HLS 慢路径、app 口收 0"
//       (P7B_GATE4_ACCEPT.md 4.3), 并定位到**具体哪一条匹配条件不成立**。
//
// 手段 = 真 wrapper 全链 (与 _proj_10g/p7b_chain/sim/tb_p7b_chain.v 同一手法,
//       同一组编译宏): 用 p7b_pcs_stub 在 XGMII 上注入一个**真实几何**的 UDP 帧,
//       逐拍打印 classify-slow 字流 / udp_split 内部 pw_idx / udp_rx FSM。
//
// 帧 (与 _proj_pcie/p6e_udp_pattern.cpp 的 teach 帧同几何):
//   dst mac 00:0a:35:01:fe:c0 / src mac 00:0f:53:2c:68:01
//   src ip 192.168.100.100 : 50177  ->  dst ip 192.168.100.2 : <dport>
//   UDP 载荷 plen=100 B, IP total = 128, 帧内容 = 142 B
// ===========================================================================
module tb_p7b_appsplit;

    integer fails  = 0;
    integer checks = 0;

    task chk;
        input [8*64-1:0] name;      // P7B_LANEFIX: 判据名带 lane 前缀, 原 256 位会截掉前缀
        input         cond;
        input [255:0] src;
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                fails = fails + 1;
                $display("  [FAIL] %0s   src=%0s", name, src);
            end else begin
                $display("  [PASS] %0s   src=%0s", name, src);
            end
        end
    endtask

    // ======================= 时钟 / 复位 ===================================
    reg reset_n = 0;
    reg pcie_sys_clk_p = 0, pcie_sys_clk_n = 1;
    reg sys_clk_p = 0, sys_clk_n = 1;
    always #5 pcie_sys_clk_p = ~pcie_sys_clk_p;
    always #5 pcie_sys_clk_n = ~pcie_sys_clk_n;
    always #5 sys_clk_p = ~sys_clk_p;
    always #5 sys_clk_n = ~sys_clk_p;

    reg [3:0] pcie_rxp = 0, pcie_rxn = 0;
    wire [3:0] pcie_txp, pcie_txn;
    reg gt_refclk_p = 0, gt_refclk_n = 1;
    reg sfp1_rxp = 0, sfp1_rxn = 0, sfp2_rxp = 0, sfp2_rxn = 0;
    wire sfp1_txp, sfp1_txn, sfp2_txp, sfp2_txn;
    reg  sfp1_rx_los = 1, sfp2_rx_los = 0;
    wire sfp1_tx_dis, sfp2_tx_dis;
    wire led_d0, led_d1, led_d2, led_d3, uart_txd;

    wrapper_p4 u_dut (
        .reset_n(reset_n),
        .pcie_sys_clk_p(pcie_sys_clk_p), .pcie_sys_clk_n(pcie_sys_clk_n),
        .pcie_txp(pcie_txp), .pcie_txn(pcie_txn),
        .pcie_rxp(pcie_rxp), .pcie_rxn(pcie_rxn),
        .sys_clk_p(sys_clk_p), .sys_clk_n(sys_clk_n),
        .gt_refclk_p(gt_refclk_p), .gt_refclk_n(gt_refclk_n),
        .sfp1_rxp(sfp1_rxp), .sfp1_rxn(sfp1_rxn),
        .sfp1_txp(sfp1_txp), .sfp1_txn(sfp1_txn),
        .sfp2_rxp(sfp2_rxp), .sfp2_rxn(sfp2_rxn),
        .sfp2_txp(sfp2_txp), .sfp2_txn(sfp2_txn),
        .sfp1_rx_los(sfp1_rx_los), .sfp2_rx_los(sfp2_rx_los),
        .sfp1_tx_dis(sfp1_tx_dis), .sfp2_tx_dis(sfp2_tx_dis),
        .led_d0(led_d0), .led_d1(led_d1), .led_d2(led_d2), .led_d3(led_d3),
        .uart_txd(uart_txd)
    );

    // ======================= CRC-32 (位串行, TB 自算) ======================
    function [31:0] crc32_byte;
        input [31:0] c;
        input [7:0]  b;
        integer i;
        reg [31:0] x;
        begin
            x = c ^ {24'd0, b};
            for (i = 0; i < 8; i = i + 1)
                x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
            crc32_byte = x;
        end
    endfunction

    function integer popc8;
        input [7:0] v;
        integer i;
        begin
            popc8 = 0;
            for (i = 0; i < 8; i = i + 1) if (v[i]) popc8 = popc8 + 1;
        end
    endfunction

    // ======================= XGMII 注入队列 (RX 方向) ======================
    reg [63:0] xq_d [0:16383];
    reg [7:0]  xq_c [0:16383];
    integer    xq_wr = 0, xq_rd = 0;
    wire       xq_empty = (xq_rd == xq_wr);

    always @(posedge u_dut.rx_clk_out_1) begin
        if (!xq_empty) xq_rd <= xq_rd + 1;
        u_dut.u_pcs.inj_d1 <= xq_empty ? 64'h0707070707070707 : xq_d[xq_rd];
        u_dut.u_pcs.inj_c1 <= xq_empty ? 8'hFF                 : xq_c[xq_rd];
    end

    reg [7:0] wb [0:8191];
    reg       wc [0:8191];
    // ⭐ P7B_LANEFIX: /S/ 注入 lane —— 802.3 只允许 lane0 与 lane4 两个起始 lane;
    //    lane4 时前导组跨字 ⇒ 帧首数据字原只有 4 字节 ⇒ 下游按"帧首字必满"判 nonmatch。
    //    本 TB 两个 lane 都跑 (原先只跑 lane0 ⇒ 缺陷从整条门逃逸)。
    integer   inj_lane = 0;

    task xq_pack_words;               // lane0 = 首字节 打包
        input integer n;
        integer i, k;
        reg [63:0] d;
        reg [7:0]  c;
        begin
            i = 0;
            while (i < n) begin
                d = 64'd0; c = 8'd0;
                for (k = 0; k < 8; k = k + 1) begin
                    if (i + k < n) begin
                        d[k*8 +: 8] = wb[i+k];
                        c[k]        = wc[i+k];
                    end else begin
                        d[k*8 +: 8] = 8'h07;
                        c[k]        = 1'b1;
                    end
                end
                xq_d[xq_wr] = d; xq_c[xq_wr] = c; xq_wr = xq_wr + 1;
                i = i + 8;
            end
        end
    endtask

    // ======================= UDP 帧构造 ====================================
    reg [7:0]  fb [0:2047];          // 帧内容 (不含前导/FCS)
    integer    fb_n;                 // 内容字节数
    integer    mon_ip_sum;           // IP 头校验和 (TB 自算)

    function [31:0] ipcsum_of;       // 20 字节 IP 头的反码和
        input dummy;                 // (Verilog 要求至少一个输入)
        integer i; reg [31:0] s;
        begin
            s = 0;            for (i = 0; i < 20; i = i + 2) s = s + {16'd0, fb[14+i], fb[15+i]};
            s = (s & 32'hFFFF) + (s >> 16);
            s = (s & 32'hFFFF) + (s >> 16);
            ipcsum_of = (~s) & 32'hFFFF;
        end
    endfunction

    reg [31:0] fcs_calc;
    integer    udp_csum_bad_plen;    // 未用

    // dport: 目标端口; plen: UDP 载荷字节数; badcrc: 坏 FCS
    task build_udp_frame;
        input integer dport;
        input integer plen;
        input         badcrc;
        integer i, m;
        begin
            // ---- 内容 (14 + 20 + 8 + plen) ----
            fb[0]=8'h00; fb[1]=8'h0a; fb[2]=8'h35; fb[3]=8'h01; fb[4]=8'hfe; fb[5]=8'hc0;
            fb[6]=8'h00; fb[7]=8'h0f; fb[8]=8'h53; fb[9]=8'h2c; fb[10]=8'h68; fb[11]=8'h01;
            fb[12]=8'h08; fb[13]=8'h00;
            fb[14]=8'h45; fb[15]=8'h00;
            fb[16]=((20+8+plen) >> 8) & 8'hFF; fb[17]=(20+8+plen) & 8'hFF;
            fb[18]=8'h00; fb[19]=8'h2a;
            fb[20]=8'h40; fb[21]=8'h00;
            fb[22]=8'd64; fb[23]=8'd17;
            fb[24]=8'h00; fb[25]=8'h00;                       // csum 占位
            fb[26]=8'd192; fb[27]=8'd168; fb[28]=8'd100; fb[29]=8'd100;
            fb[30]=8'd192; fb[31]=8'd168; fb[32]=8'd100; fb[33]=8'd2;
            fb[34]=(50177 >> 8) & 8'hFF; fb[35]=50177 & 8'hFF;   // sport = 50177
            fb[36]=(dport >> 8) & 8'hFF; fb[37]=dport & 8'hFF;   // dport
            fb[38]=((8+plen) >> 8) & 8'hFF; fb[39]=(8+plen) & 8'hFF;
            fb[40]=8'h00; fb[41]=8'h00;                        // UDP csum (udp_rx 不查)
            m = ipcsum_of(1'b0);
            fb[24]=m[15:8]; fb[25]=m[7:0];
            for (i = 0; i < plen; i = i + 1) fb[42+i] = (8'hA0 + i[7:0]);
            fb_n = 42 + plen;
            $display("  [TB] build: dport=%0d plen=%0d frame_len=%0d ip_csum=%02h%02h ip_total=%0d",
                     dport, plen, fb_n, fb[24], fb[25], 20+8+plen);

            // ---- 线上: /S/ + 55x6 + D5 + 内容 + FCS ----
            fcs_calc = 32'hFFFFFFFF;
            for (i = 0; i < fb_n; i = i + 1) fcs_calc = crc32_byte(fcs_calc, fb[i]);
            fcs_calc = ~fcs_calc;
            // /S/ 落 lane0 或 lane4: 前导组占 8 字节 (/S/ + 0x55x6 + 0xD5),
            //   落 lane4 时它跨字 ⇒ 帧数据从下一字的 lane4 起 (与官方监视器同约定)
            for (i = 0; i < inj_lane; i = i + 1) begin wb[i] = 8'h07; wc[i] = 1; end
            wb[inj_lane+0] = 8'hFB; wc[inj_lane+0] = 1;
            for (i = 0; i < 6; i = i + 1) begin wb[inj_lane+1+i] = 8'h55; wc[inj_lane+1+i] = 0; end
            wb[inj_lane+7] = 8'hD5; wc[inj_lane+7] = 0;
            m = inj_lane + 8;
            for (i = 0; i < fb_n; i = i + 1) begin
                wb[m] = fb[i]; wc[m] = 0; m = m + 1;
            end
            if (!badcrc) begin
                wb[m] = fcs_calc[7:0];   wc[m] = 0; m = m + 1;
                wb[m] = fcs_calc[15:8];  wc[m] = 0; m = m + 1;
                wb[m] = fcs_calc[23:16]; wc[m] = 0; m = m + 1;
                wb[m] = fcs_calc[31:24]; wc[m] = 0; m = m + 1;
            end else begin
                wb[m] = 8'h00; wc[m] = 0; m = m + 1;
                wb[m] = 8'h00; wc[m] = 0; m = m + 1;
                wb[m] = 8'h00; wc[m] = 0; m = m + 1;
                wb[m] = 8'h00; wc[m] = 0; m = m + 1;
            end
            wb[m] = 8'hFD; wc[m] = 1; m = m + 1;   // /T/
            xq_pack_words(m);
        end
    endtask

    // ======================= 观测: classify slow 字流 ======================
    integer sw_n = 0;
    always @(posedge u_dut.dp_clk) begin
        if (u_dut.s_tvalid && u_dut.s_tready) begin
            $display("  [SLOW %0d] td=%016h tk=%02h tl=%b user=%b crs=%b err=%b",
                     sw_n, u_dut.s_tdata, u_dut.s_tkeep, u_dut.s_tlast,
                     u_dut.s_tuser, u_dut.s_tcrs, u_dut.s_terr);
            sw_n <= sw_n + 1;
        end
    end

    // ======================= 观测: udp_split 内部 ==========================
    integer pw_n = 0;
    always @(posedge u_dut.dp_clk) begin
        if (u_dut.u_udp_split.pre_pop) begin
            $display("    [POP %0d] pw_idx=%0d td=%016h tk=%02h tl=%b u=%b | ip45=%b udp_r=%b excl=%b port_any=%b p0=%04h",
                     pw_n, u_dut.u_udp_split.pw_idx, u_dut.u_udp_split.f_d,
                     u_dut.u_udp_split.f_k, u_dut.u_udp_split.f_l, u_dut.u_udp_split.f_u,
                     u_dut.u_udp_split.ip4_45_r, u_dut.u_udp_split.udp_r_r,
                     u_dut.u_udp_split.excl_hit, u_dut.u_udp_split.u_cfg_port_any,
                     u_dut.u_udp_split.u_cfg_port0);
            pw_n <= pw_n + 1;
        end
    end

    reg [1:0]  prv_st  = 2'd3;
    reg [5:0]  prv_wc  = 6'd63;
    reg        prv_mat = 1'b0;
    reg [3:0]  prv_hd  = 4'd0;
    always @(posedge u_dut.dp_clk) begin
        if ((u_dut.u_udp_split.u_udp_rx.state  !== prv_st) ||
            (u_dut.u_udp_split.u_udp_rx.wcnt   !== prv_wc) ||
            (u_dut.u_udp_split.u_udp_rx.matched!== prv_mat)) begin
            $display("      [UDPRX] st=%0d wcnt=%0d matched=%b ipc_ok=%b ipm=%b pm=%b lenok=%b | w1lo=%04h w3=%016h w2r=%016h",
                     u_dut.u_udp_split.u_udp_rx.state, u_dut.u_udp_split.u_udp_rx.wcnt,
                     u_dut.u_udp_split.u_udp_rx.matched,
                     u_dut.u_udp_split.u_udp_rx.ipcsum_ok,
                     u_dut.u_udp_split.u_udp_rx.ip_match,
                     u_dut.u_udp_split.u_udp_rx.port_match,
                     u_dut.u_udp_split.u_udp_rx.udp_len_ok,
                     u_dut.u_udp_split.u_udp_rx.w1_lo,
                     u_dut.u_udp_split.u_udp_rx.w3_r,
                     u_dut.u_udp_split.u_udp_rx.w2_r);
            prv_st  <= u_dut.u_udp_split.u_udp_rx.state;
            prv_wc  <= u_dut.u_udp_split.u_udp_rx.wcnt;
            prv_mat <= u_dut.u_udp_split.u_udp_rx.matched;
        end
    end

    // app 口交付
    integer app_n = 0;
    always @(posedge u_dut.dp_clk) begin
        if (u_dut.app_udp_rx_tvalid && u_dut.app_udp_rx_tready) begin
            $display("      [APPRX %0d] td=%016h tk=%02h tl=%b sof=%b len=%0d",
                     app_n, u_dut.app_udp_rx_tdata, u_dut.app_udp_rx_tkeep,
                     u_dut.app_udp_rx_tlast, u_dut.app_udp_rx_sof,
                     u_dut.app_udp_rx_len);
            app_n <= app_n + 1;
        end
    end

    // ======================= 观测: SOP 字满对齐 (合同第 2 条) ==============
    // ⭐ P7B_LANEFIX: mac_rx_10g.v:12 第 2 条「帧首字总是满对齐 (tkeep[7]=1)」在
    //    lane4 起帧时曾不成立 (SOP 字 tkeep=0xF0) ⇒ 下游 udp_rx 第 0 拍就判 nonmatch。
    //    这里在**两个**下游观察点各留一条计数: ①分流器输入字流 ②慢路径输出字流。
    integer sopw_n = 0, sopw_bad = 0;      // ① udp_split 输入 (pre_pop, pw_idx==0)
    integer slw_n  = 0, slw_bad  = 0;      // ② classify-slow 输出 (s_t*)
    always @(posedge u_dut.dp_clk) begin
        if (u_dut.u_udp_split.pre_pop && (u_dut.u_udp_split.pw_idx === 4'd0)) begin
            sopw_n = sopw_n + 1;
            if (u_dut.u_udp_split.f_k !== 8'hFF) begin
                sopw_bad = sopw_bad + 1;
                $display("      [SOPKEEP-FAIL split] td=%016h tk=%02h (期望 FF)",
                         u_dut.u_udp_split.f_d, u_dut.u_udp_split.f_k);
            end
        end
        if (u_dut.s_tvalid && u_dut.s_tready && u_dut.s_tuser) begin
            slw_n = slw_n + 1;
            if (u_dut.s_tkeep !== 8'hFF) begin
                slw_bad = slw_bad + 1;
                $display("      [SOPKEEP-FAIL slow] td=%016h tk=%02h (期望 FF)",
                         u_dut.s_tdata, u_dut.s_tkeep);
            end
        end
    end

    // ======================= 主流程 ========================================
    integer k1;
    integer plen_s;
    integer cw;
    reg [31:0] ca, cp, cb, cn;
    integer cf0, cpf0, caf0;                  // 场景起点快照 (判据按**增量**判 ⇒ 可跑多场景)
    integer sopw_n0, sopw_bd0, slw_n0, slw_bd0;
    reg [8*12-1:0] ltag;                      // 判据名前缀 "L0 "/"L4 "
    integer lane_ck0, lane_fl0;

    // 一个完整场景 (lane = /S/ 注入 lane ⇒ 0 或 4)。同一套判据按增量各判一遍。
    task scenario;
        input integer lane;
        begin
            inj_lane = lane;
            ltag = (lane == 0) ? "L0 " : "L4 ";
            lane_ck0 = checks; lane_fl0 = fails;
            cf0   = u_dut.rx_stat_frames;
            cpf0  = u_dut.u_udp_split.u_udp_rx.stat_pass;
            caf0  = u_dut.app_udp_stat_frames;
            sopw_n0 = sopw_n; sopw_bd0 = sopw_bad; slw_n0 = slw_n; slw_bd0 = slw_bad;

        // ---------- 第 1 帧: 8081 (app 端口) ----------
        $display("---- [LANE %0d] FRAME 1: dport=8081 (app port) ----", lane);
        build_udp_frame(8081, 100, 1'b0);
        repeat (600) @(posedge u_dut.dp_clk);
        $display("  [F1] rx_frames=%0d rx_bytes=%0d crc_err=%0d | srx_commit=%0d | split(stat_app=%0d app_bytes=%0d drop_crc=%0d drop_ovf=%0d drop_part=%0d drop_excl=%0d hls=%0d hls_drop=%0d hls_split=%0d) | udprx(pass=%0d nm=%0d ipc=%0d crc=%0d bytes=%0d)",
                 u_dut.rx_stat_frames, u_dut.rx_stat_bytes, u_dut.rx_stat_crc_err,
                 u_dut.srx_stat_commit,
                 u_dut.app_udp_stat_frames, u_dut.app_udp_stat_bytes,
                 u_dut.app_udp_stat_drop_crc, u_dut.app_udp_stat_drop_ovf,
                 u_dut.app_udp_stat_drop_part, u_dut.app_udp_stat_drop_excl,
                 u_dut.app_udp_stat_hls_frames, u_dut.app_udp_stat_hls_drop,
                 u_dut.app_udp_stat_hls_split,
                 u_dut.u_udp_split.u_udp_rx.stat_pass,
                 u_dut.u_udp_split.u_udp_rx.stat_drop_nonmatch,
                 u_dut.u_udp_split.u_udp_rx.stat_drop_ipcsum,
                 u_dut.u_udp_split.u_udp_rx.stat_drop_crc,
                 u_dut.u_udp_split.u_udp_rx.stat_bytes);
        $display("  [F1] app_rx_frames(W10)=%0d udpapp_rx_frames=%0d",
                 app_n, u_dut.udpapp_rx_frames);

        chk({ltag, "A1 frame received by MAC"},
            u_dut.rx_stat_frames === (cf0 + 32'd1), "W0 +1 on board");
        chk({ltag, "A2 udp_rx saw a matching frame (stat_pass)"},
            u_dut.u_udp_split.u_udp_rx.stat_pass === (cpf0 + 32'd1),
            "root criterion: ipcsum+ip+port+len all pass");
        chk({ltag, "A3 udp_split claimed it for app"},
            u_dut.app_udp_stat_frames === (caf0 + 32'd1), "W10 must be 1");

        // ---------- 长度扫描: app 口对 60..1518B 全几何都要认领 ----------
        // (板级 W2 最近帧长 = 333; 覆盖该长度, 排除"长度相关"的 RTL 缺陷)
        for (k1 = 0; k1 < 6; k1 = k1 + 1) begin
            case (k1)
                0: plen_s = 18;    // 内容 60  (802.3 最小, 无 pad)
                1: plen_s = 56;    // 内容 98  (ping 尺寸)
                2: plen_s = 100;   // 内容 142 (教学帧)
                3: plen_s = 291;   // 内容 333 (板级 W2 读数)
                4: plen_s = 1476;  // 内容 1518 (最大)
                5: plen_s = 8;     // 内容 50 -> 内核会 pad 到 60; 这里不 pad, 测短帧
                default: plen_s = 100;
            endcase
            ca = u_dut.app_udp_stat_frames;
            cp = u_dut.u_udp_split.u_udp_rx.stat_pass;
            cb = u_dut.app_udp_stat_bytes;
            cn = u_dut.app_udp_stat_hls_frames;
            build_udp_frame(8081, plen_s, 1'b0);
            // 等到 app 口把这一帧播完 (app 的校验器 1 字节/拍 ⇒ 1518B 要 ~12k 拍) 或超时
            for (cw = 0; cw < 40000; cw = cw + 1) begin
                @(posedge u_dut.dp_clk);
                if (u_dut.app_udp_stat_frames !== ca) cw = 40000;
            end
            repeat (800) @(posedge u_dut.dp_clk);
            chk({ltag, "SW app claim (len sweep)"}, (u_dut.app_udp_stat_frames === (ca + 32'd1)) === 1'b1,
                "every length must be claimed by udp_split");
            $display("     [SWEEP] plen=%0d content=%0d: app_frames %0d->%0d bytes+%0d pass %0d->%0d hls %0d->%0d",
                     plen_s, 42+plen_s, ca, u_dut.app_udp_stat_frames,
                     u_dut.app_udp_stat_bytes - cb, cp, u_dut.u_udp_split.u_udp_rx.stat_pass,
                     cn, u_dut.app_udp_stat_hls_frames);
        end

        // ---------- 120 帧背景流量: 复现板级"教学包是第 120 帧"的状态 ----------
        // 板级读数: 发教学包前 W0=0x77=119 ⇒ 教学帧是第 120 帧。本组先灌 120 帧
        // 非 app UDP (dport=9999 ⇒ 非 app 非 excl ⇒ 走 HLS), 再发教学帧。
        $display("---- BACKGROUND: 120 non-app UDP frames ----");
        cn = u_dut.app_udp_stat_hls_frames;
        for (k1 = 0; k1 < 120; k1 = k1 + 1) begin
            build_udp_frame(9999, 60, 1'b0);
            repeat (400) @(posedge u_dut.dp_clk);
        end
        $display("  [BG] hls_frames %0d->%0d  app_frames=%0d  drop_excl=%0d",
                 cn, u_dut.app_udp_stat_hls_frames, u_dut.app_udp_stat_frames,
                 u_dut.app_udp_stat_drop_excl);
        ca = u_dut.app_udp_stat_frames;
        cp = u_dut.u_udp_split.u_udp_rx.stat_pass;
        cn = u_dut.app_udp_stat_hls_frames;
        $display("---- FRAME 120+: teach frame (dport=8081) after 120 frames ----");
        build_udp_frame(8081, 100, 1'b0);
        repeat (900) @(posedge u_dut.dp_clk);
        chk({ltag, "B1 teach frame after 120 frames is claimed"},
            (u_dut.app_udp_stat_frames === (ca + 32'd1)) === 1'b1,
            "board: teach frame is frame #120, not #1");
        chk({ltag, "B2 udp_rx matched it"},
            (u_dut.u_udp_split.u_udp_rx.stat_pass === (cp + 32'd1)) === 1'b1,
            "match criteria after long frame history");
        $display("     [BG+] app %0d->%0d pass %0d->%0d hls %0d->%0d",
                 ca, u_dut.app_udp_stat_frames, cp,
                 u_dut.u_udp_split.u_udp_rx.stat_pass, cn, u_dut.app_udp_stat_hls_frames);

        // ---------- 第 2 帧: 8080 (HLS 端口, 负对照) ----------
        $display("---- [LANE %0d] FRAME 2 (neg ctl): dport=8080 (HLS echo port) ----", lane);
        build_udp_frame(8080, 100, 1'b0);
        repeat (600) @(posedge u_dut.dp_clk);
        $display("  [F2] rx_frames=%0d | srx_commit=%0d | stat_app=%0d drop_excl=%0d hls=%0d | udprx(pass=%0d nm=%0d ipc=%0d)",
                 u_dut.rx_stat_frames, u_dut.srx_stat_commit,
                 u_dut.app_udp_stat_frames, u_dut.app_udp_stat_drop_excl,
                 u_dut.app_udp_stat_hls_frames,
                 u_dut.u_udp_split.u_udp_rx.stat_pass,
                 u_dut.u_udp_split.u_udp_rx.stat_drop_nonmatch,
                 u_dut.u_udp_split.u_udp_rx.stat_drop_ipcsum);

        // ---------- ⭐ P7B_LANEFIX: SOP 字满对齐 (合同第 2 条) ----------
        //  非空前提 (n > 0) 是必须的 —— 否则"没有 SOP 字"会让判据**空真**通过
        chk({ltag, "A4 SOP words full-aligned @split input (tkeep==FF)"},
            (sopw_n > sopw_n0) && (sopw_bad === sopw_bd0),
            "mac_rx_10g.v:12 §2: 帧首字总是满对齐 —— lane4 起帧曾经给出 0xF0");
        chk({ltag, "A5 SOP words full-aligned @slow path out (tkeep==FF)"},
            (slw_n > slw_n0) && (slw_bad === slw_bd0),
            "classify-slow 输出口的帧首字同样必须满对齐 (tcp_rx/慢路径同吃这条合同)");
        $display("     [SOPKEEP] split: %0d 个 SOP 字 (坏 %0d->%0d) | slow: %0d 个 (坏 %0d->%0d)",
                 sopw_n - sopw_n0, sopw_bd0, sopw_bad, slw_n - slw_n0, slw_bd0, slw_bad);

        $display("---- [LANE %0d] %0d checks, %0d fail ----",
                 lane, checks - lane_ck0, fails - lane_fl0);
        end
    endtask

    initial begin
        $display("==== tb_p7b_appsplit: P7b app-UDP split-path probe (lane0 + lane4) ====");
        reset_n = 0;
        repeat (40) @(posedge u_dut.dp_clk);
        reset_n = 1;
        repeat (2000) @(posedge u_dut.dp_clk);
        scenario(0);
        scenario(4);
        $display("==== tb_p7b_appsplit done: %0d checks, %0d fail ====", checks, fails);
        $finish;
    end

    initial begin
        #20000000;                       // 两个场景 ⇒ 两倍预算 (原 #4000000 只够一个)
        $display("  [FAIL] WATCHDOG timeout");
        $display("==== tb_p7b_appsplit done: %0d checks, %0d fail ====", checks, fails);
        $finish;
    end

endmodule
