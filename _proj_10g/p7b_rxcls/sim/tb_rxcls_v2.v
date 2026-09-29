`timescale 1ns/1ps
// ===========================================================================
// tb_rxcls_v2 —— rx_classify_v2 (P7B 吞吐修复) 单元门
// ===========================================================================
// 结构: 一份激励表 -> **两个独立源** (A 喂 v1 黄金参考 / B 喂 v2) -> 逐拍对拍
//   v1 = sim/rx_classify_ref.v (= rtl/rx_classify.v 逐字副本; 已由既有门验收:
//        sim/p4sim 的 exp_rc_*/resp_rc_* 三模式一致 -> tools/gen_stim_p4_rxclass.py --check)
//   v2 = _proj_10g/p7b_rxcls/rtl/rx_classify_v2.v
// 判据三条腿 (每条带「期望来源」栏, 日志里打 src=...):
//   ① 保真: v1 vs v2 逐拍逐位 + 帧表 (nw/route/Σkeep/hash) + 独立 spec 模型期望
//   ② 吞吐: 背靠背最小帧的稳态帧周期 (v2 应 = N 字/帧; v1 应 = N+3 / N+6)
//   ③ 负对照: 深停等 (40 拍 > FIFO 深 16) + F4 TERM 截断帧 (丢帧丢整帧)
// 纪律: 判据一律 `cond !== 1'b1`; 判据名与来源全 ASCII (xsim 位向量里 CJK 会变 0xff);
//       期望值全部由本 TB 独立算 (spec 模型 + 算术), **不由 DUT 生成**。
//    两个源各自按**自己 DUT** 的 tready 推进 (共用源会在停顿分叉时给对方重复喂字),
//    所以两 DUT 看到**同一序列**、未必同一时刻 —— 内容对拍按序列, 吞吐按各自的拍号。
// ===========================================================================
module tb_rxcls_v2;

    // ---------------- 时钟 / 复位 ----------------
    reg clk = 1'b0;
    always #3.2 clk = ~clk;             // 6.4 ns = 156.25 MHz (10G 数据面时钟)
    reg rst_n = 1'b0;

    integer nchk = 0, nfail = 0;
    task chk;
        input            cond;
        input [8*80-1:0] name;
        input [8*32-1:0] src;
        begin
            nchk = nchk + 1;
            if (cond !== 1'b1) begin
                nfail = nfail + 1;
                $display("  [FAIL] %0s | src=%0s", name, src);
            end else begin
                $display("  [ ok ] %0s | src=%0s", name, src);
            end
        end
    endtask

    // ---------------- 小工具 ----------------
    function integer popc8;
        input [7:0] v;
        integer i, c;
        begin
            c = 0;
            for (i = 0; i < 8; i = i + 1) c = c + v[i];
            popc8 = c;
        end
    endfunction

    // 帧级滚动指纹 (逐帧独立; 顺序敏感) —— 汇总诊断用; 主判据是逐拍逐位比较
    function [63:0] hs_mix;
        input [63:0] h;
        input [76:0] b;
        reg   [63:0] x;
        begin
            x = b[63:0] ^ {b[76:64], 52'd0};
            hs_mix = (h ^ x) * 64'h00000100000001B3;
            hs_mix = hs_mix ^ (hs_mix >> 29);
        end
    endfunction

    // =====================================================================
    // 激励表
    // =====================================================================
    localparam MAXW = 32768;
    localparam MAXF = 1024;
    localparam MAXB = 32768;

    reg [63:0] st_d [0:MAXW-1];
    reg [7:0]  st_k [0:MAXW-1];
    reg        st_l [0:MAXW-1];
    reg        st_u [0:MAXW-1];
    reg        st_c [0:MAXW-1];
    reg        st_e [0:MAXW-1];
    reg [15:0] st_g [0:MAXW-1];       // 本字之后插入的 gap 拍数
    integer    nstim;

    integer    ex_nw [0:MAXF-1];
    integer    ex_rt [0:MAXF-1];
    integer    ex_pc [0:MAXF-1];
    reg [63:0] ex_hs [0:MAXF-1];
    integer    nfexp;

    integer    o1_nw [0:MAXF-1];  integer o1_rt [0:MAXF-1];  integer o1_pc [0:MAXF-1];
    reg [63:0] o1_hs [0:MAXF-1];  integer o1_sc [0:MAXF-1];  integer o1_ec [0:MAXF-1];
    integer    nf1;
    integer    o2_nw [0:MAXF-1];  integer o2_rt [0:MAXF-1];  integer o2_pc [0:MAXF-1];
    reg [63:0] o2_hs [0:MAXF-1];  integer o2_sc [0:MAXF-1];  integer o2_ec [0:MAXF-1];
    integer    nf2;

    reg [76:0] c1 [0:MAXB-1];   reg [31:0] c1cy [0:MAXB-1];
    reg [76:0] c2 [0:MAXB-1];   reg [31:0] c2cy [0:MAXB-1];
    integer    n1, n2;

    integer i, j, k;

    // =====================================================================
    // 两个源
    // =====================================================================
    reg [63:0] sa_d, sb_d;
    reg [7:0]  sa_k, sb_k;
    reg        sa_v, sb_v, sa_l, sb_l, sa_u, sb_u, sa_c, sb_c, sa_e, sb_e;
    reg [14:0] sa_idx, sb_idx;
    reg [15:0] sa_gap, sb_gap;
    reg        srcA_done, srcB_done;
    wire       v1_s_rdy, v2_s_rdy;

    always @(posedge clk) begin
        if (!rst_n) begin
            sa_v <= 1'b0; sa_idx <= 15'd0; sa_gap <= 16'd0; srcA_done <= 1'b0;
            sa_d <= 64'd0; sa_k <= 8'd0; sa_l <= 1'b0; sa_u <= 1'b0; sa_c <= 1'b0; sa_e <= 1'b0;
        end else begin
            if (sa_v && v1_s_rdy) sa_v <= 1'b0;
            if ((!sa_v) || (sa_v && v1_s_rdy)) begin
                if (sa_gap > 0) sa_gap <= sa_gap - 16'd1;
                else if (sa_idx < nstim) begin
                    sa_d <= st_d[sa_idx]; sa_k <= st_k[sa_idx];
                    sa_l <= st_l[sa_idx]; sa_u <= st_u[sa_idx];
                    sa_c <= st_c[sa_idx]; sa_e <= st_e[sa_idx];
                    sa_gap <= st_g[sa_idx];
                    sa_v <= 1'b1;
                    sa_idx <= sa_idx + 15'd1;
                end
            end
            if (sa_idx >= nstim && !sa_v) srcA_done <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            sb_v <= 1'b0; sb_idx <= 15'd0; sb_gap <= 16'd0; srcB_done <= 1'b0;
            sb_d <= 64'd0; sb_k <= 8'd0; sb_l <= 1'b0; sb_u <= 1'b0; sb_c <= 1'b0; sb_e <= 1'b0;
        end else begin
            if (sb_v && v2_s_rdy) sb_v <= 1'b0;
            if ((!sb_v) || (sb_v && v2_s_rdy)) begin
                if (sb_gap > 0) sb_gap <= sb_gap - 16'd1;
                else if (sb_idx < nstim) begin
                    sb_d <= st_d[sb_idx]; sb_k <= st_k[sb_idx];
                    sb_l <= st_l[sb_idx]; sb_u <= st_u[sb_idx];
                    sb_c <= st_c[sb_idx]; sb_e <= st_e[sb_idx];
                    sb_gap <= st_g[sb_idx];
                    sb_v <= 1'b1;
                    sb_idx <= sb_idx + 15'd1;
                end
            end
            if (sb_idx >= nstim && !sb_v) srcB_done <= 1'b1;
        end
    end

    // =====================================================================
    // 背压 (两个 DUT 用同一序列; 只按周期数 kc 生成, 与 DUT 状态无关)
    // =====================================================================
    reg [31:0] kc;
    reg        f_rdy, s_rdy;
    integer    bp_mode;         // 0 恒 ready / 1 周期 stall / 2 硬停窗 / 3 伪随机
    integer    hw0, hw1;
    reg [14:0] lfsr;

    always @(posedge clk) begin
        if (!rst_n) begin
            kc <= 32'd0; f_rdy <= 1'b1; s_rdy <= 1'b1; lfsr <= 15'h7FFF;
        end else begin
            kc <= kc + 32'd1;
            lfsr <= {lfsr[13:0], lfsr[14] ^ lfsr[13]};
            case (bp_mode)
                1: begin f_rdy <= (kc % 4 != 3); s_rdy <= (kc % 3 != 0); end
                2: begin f_rdy <= !(kc >= hw0 && kc < hw1);
                         s_rdy <= !(kc >= hw0 && kc < hw1); end
                3: begin f_rdy <= lfsr[3]; s_rdy <= lfsr[7]; end
                default: begin f_rdy <= 1'b1; s_rdy <= 1'b1; end
            endcase
        end
    end

    // TB 侧独立测的"输入停等拍数" (v1 没有该端口; v2 用它交叉核对 DUT 自报)
    integer v1_stall_tb, v2_stall_tb;
    always @(posedge clk) begin
        if (!rst_n) begin v1_stall_tb <= 0; v2_stall_tb <= 0; end
        else begin
            if (sa_v && !v1_s_rdy) v1_stall_tb <= v1_stall_tb + 1;
            if (sb_v && !v2_s_rdy) v2_stall_tb <= v2_stall_tb + 1;
        end
    end

    // =====================================================================
    // DUT 例化
    // =====================================================================
    wire [63:0] v1_f_d, v1_sl_d;   wire [7:0] v1_f_k, v1_sl_k;
    wire        v1_f_v, v1_f_l, v1_f_u, v1_f_c, v1_f_e;
    wire        v1_sl_v, v1_sl_l, v1_sl_u, v1_sl_c, v1_sl_e;
    wire [31:0] v1_stat_fast, v1_stat_slow, v1_win, v1_wout;

    rx_classify u_v1 (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(sa_d), .s_axis_tkeep(sa_k), .s_axis_tvalid(sa_v),
        .s_axis_tready(v1_s_rdy), .s_axis_tlast(sa_l), .s_axis_tuser(sa_u),
        .s_axis_tcrs(sa_c), .s_axis_terr(sa_e),
        .m_fast_tdata(v1_f_d), .m_fast_tkeep(v1_f_k), .m_fast_tvalid(v1_f_v),
        .m_fast_tready(f_rdy), .m_fast_tlast(v1_f_l), .m_fast_tuser(v1_f_u),
        .m_fast_tcrs(v1_f_c), .m_fast_terr(v1_f_e),
        .m_slow_tdata(v1_sl_d), .m_slow_tkeep(v1_sl_k), .m_slow_tvalid(v1_sl_v),
        .m_slow_tready(s_rdy), .m_slow_tlast(v1_sl_l), .m_slow_tuser(v1_sl_u),
        .m_slow_tcrs(v1_sl_c), .m_slow_terr(v1_sl_e),
        .stat_fast(v1_stat_fast), .stat_slow(v1_stat_slow),
        .dbg_stat_words_in(v1_win), .dbg_stat_words_out(v1_wout)
    );

    wire [63:0] v2_f_d, v2_sl_d;   wire [7:0] v2_f_k, v2_sl_k;
    wire        v2_f_v, v2_f_l, v2_f_u, v2_f_c, v2_f_e;
    wire        v2_sl_v, v2_sl_l, v2_sl_u, v2_sl_c, v2_sl_e;
    wire [31:0] v2_stat_fast, v2_stat_slow, v2_win, v2_wout;
    wire [31:0] v2_ovf, v2_rqovf, v2_stall;
    wire [4:0]  v2_occ;

    rx_classify_v2 u_v2 (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(sb_d), .s_axis_tkeep(sb_k), .s_axis_tvalid(sb_v),
        .s_axis_tready(v2_s_rdy), .s_axis_tlast(sb_l), .s_axis_tuser(sb_u),
        .s_axis_tcrs(sb_c), .s_axis_terr(sb_e),
        .m_fast_tdata(v2_f_d), .m_fast_tkeep(v2_f_k), .m_fast_tvalid(v2_f_v),
        .m_fast_tready(f_rdy), .m_fast_tlast(v2_f_l), .m_fast_tuser(v2_f_u),
        .m_fast_tcrs(v2_f_c), .m_fast_terr(v2_f_e),
        .m_slow_tdata(v2_sl_d), .m_slow_tkeep(v2_sl_k), .m_slow_tvalid(v2_sl_v),
        .m_slow_tready(s_rdy), .m_slow_tlast(v2_sl_l), .m_slow_tuser(v2_sl_u),
        .m_slow_tcrs(v2_sl_c), .m_slow_terr(v2_sl_e),
        .stat_fast(v2_stat_fast), .stat_slow(v2_stat_slow),
        .dbg_stat_words_in(v2_win), .dbg_stat_words_out(v2_wout),
        .dbg_stat_ovf(v2_ovf), .dbg_stat_route_ovf(v2_rqovf),
        .dbg_stat_stall_in(v2_stall), .dbg_occ(v2_occ)
    );

    // =====================================================================
    // 捕获 (两个 DUT; beat = {route, data, keep, last, user, crs, err})
    // =====================================================================
    integer both1, both2;

    always @(posedge clk) begin
        if (!rst_n) begin
            n1 <= 0; n2 <= 0; both1 <= 0; both2 <= 0;
        end else begin
            if ((v1_f_v && f_rdy) || (v1_sl_v && s_rdy)) begin
                if (v1_f_v && f_rdy)
                    c1[n1] <= {1'b0, v1_f_d, v1_f_k, v1_f_l, v1_f_u, v1_f_c, v1_f_e};
                else
                    c1[n1] <= {1'b1, v1_sl_d, v1_sl_k, v1_sl_l, v1_sl_u, v1_sl_c, v1_sl_e};
                c1cy[n1] <= kc;
                n1 <= n1 + 1;
                if (v1_f_v && f_rdy && v1_sl_v && s_rdy) both1 <= both1 + 1;
            end
            if ((v2_f_v && f_rdy) || (v2_sl_v && s_rdy)) begin
                if (v2_f_v && f_rdy)
                    c2[n2] <= {1'b0, v2_f_d, v2_f_k, v2_f_l, v2_f_u, v2_f_c, v2_f_e};
                else
                    c2[n2] <= {1'b1, v2_sl_d, v2_sl_k, v2_sl_l, v2_sl_u, v2_sl_c, v2_sl_e};
                c2cy[n2] <= kc;
                n2 <= n2 + 1;
                if (v2_f_v && f_rdy && v2_sl_v && s_rdy) both2 <= both2 + 1;
            end
        end
    end

    // ---- X 观测 (按 AXIS 合同写, 不一刀切) ----
    //   · tvalid **任何时候**都不许是 X
    //   · tvalid===1 那一拍, 其余侧带 (data/keep/last/user/crs/err) 都不许是 X
    //   ⚠️ 空 (valid=0) 时数据侧是**合法陈旧值**: fifo_sync 的 dout 每拍无条件载入
    //      mem[rptr_n], 未写过的单元就是 X (mac_rx_10g 同一个 FIFO 也如此)。
    //   ⚠️ 教训: X 与 X 用 !== 比较是**相等**的 ⇒ 内容对拍会被 X 流掩盖, 必须单列本判据。
    integer x1, x2;
    always @(posedge clk) begin
        if (!rst_n) begin x1 <= 0; x2 <= 0; end
        else begin
            if ((v1_f_v === 1'bx) || (v1_sl_v === 1'bx) ||
                ((v1_f_v === 1'b1)  && (^{v1_f_d, v1_f_k, v1_f_l, v1_f_u, v1_f_c, v1_f_e} === 1'bx)) ||
                ((v1_sl_v === 1'b1) && (^{v1_sl_d, v1_sl_k, v1_sl_l, v1_sl_u, v1_sl_c, v1_sl_e} === 1'bx))) begin
                if (x1 == 0) $display("  [dbg] v1 first X @cyc %0d f_v=%b sl_v=%b f_d=%h f_k=%h",
                                      kc, v1_f_v, v1_sl_v, v1_f_d, v1_f_k);
                x1 <= x1 + 1;
            end
            if ((v2_f_v === 1'bx) || (v2_sl_v === 1'bx) ||
                ((v2_f_v === 1'b1)  && (^{v2_f_d, v2_f_k, v2_f_l, v2_f_u, v2_f_c, v2_f_e} === 1'bx)) ||
                ((v2_sl_v === 1'b1) && (^{v2_sl_d, v2_sl_k, v2_sl_l, v2_sl_u, v2_sl_c, v2_sl_e} === 1'bx))) begin
                if (x2 == 0) $display("  [dbg] v2 first X @cyc %0d f_v=%b sl_v=%b f_d=%h f_k=%h",
                                      kc, v2_f_v, v2_sl_v, v2_f_d, v2_f_k);
                x2 <= x2 + 1;
            end
        end
    end

    // =====================================================================
    // 激励构造
    // =====================================================================
    reg [7:0]  fb [0:2047];      // ⚠️ 必须 >= 1514+  (256 会静默产生 X 数据字)
    reg [63:0] fwd [0:255];
    reg [7:0]  fwk [0:255];
    integer    curw;

    task mk_frame;
        input [15:0] et;
        input [7:0]  pr;
        input integer nb;            // 内容字节数 (FCS 已剥)
        input [7:0]  fl;             // TCP flags @byte47 (仅 nb>47 生效)
        input integer crs;
        input integer terr;
        input integer g0, g2, g3, g4, g6;
        integer i2, wi, nw, rem;
        begin
            for (i2 = 0; i2 < 2048; i2 = i2 + 1) fb[i2] = 8'h00;
            for (i2 = 0; i2 < nb; i2 = i2 + 1) begin
                if      (i2 < 6)  fb[i2] = (64'h112233445566 >> ((5-i2)*8))  & 8'hFF;
                else if (i2 < 12) fb[i2] = (64'h000A3501FEC0 >> ((11-i2)*8)) & 8'hFF;
                else if (i2 == 12) fb[i2] = et[15:8];
                else if (i2 == 13) fb[i2] = et[7:0];
                else if (i2 == 14) fb[i2] = 8'h45;
                else if (i2 == 23) fb[i2] = pr;
                else if (i2 == 47) fb[i2] = fl;
                else if (i2 >= 24) fb[i2] = (i2 * 5 + 1) & 8'hFF;
                else               fb[i2] = 8'h00;
            end
            nw  = (nb + 7) / 8;
            rem = nb - 8 * (nw - 1);
            for (wi = 0; wi < nw; wi = wi + 1) begin
                fwd[wi] = 64'd0;
                for (i2 = 0; i2 < 8; i2 = i2 + 1)
                    if (wi * 8 + i2 < nb) fwd[wi][(7-i2)*8 +: 8] = fb[wi*8 + i2];
                if (wi == nw - 1) fwk[wi] = (8'hFF << (8 - rem)) & 8'hFF;
                else              fwk[wi] = 8'hFF;
            end
            for (wi = 0; wi < nw; wi = wi + 1) begin
                st_d[curw] = fwd[wi];
                st_k[curw] = fwk[wi];
                st_l[curw] = (wi == nw - 1);
                st_u[curw] = (wi == 0);
                st_c[curw] = (wi == nw - 1) ? (crs  ? 1'b1 : 1'b0) : 1'b0;
                st_e[curw] = (wi == nw - 1) ? (terr ? 1'b1 : 1'b0) : 1'b0;
                if      (wi == 0) st_g[curw] = g0[15:0];
                else if (wi == 2) st_g[curw] = g2[15:0];
                else if (wi == 3) st_g[curw] = g3[15:0];
                else if (wi == 4) st_g[curw] = g4[15:0];
                else if (wi == 6) st_g[curw] = g6[15:0];
                else              st_g[curw] = 16'd0;
                curw = curw + 1;
            end
        end
    endtask

    task add_word_raw;
        input [63:0] d;
        input [7:0]  kk;
        input        l, u, cc, ee;
        input integer g;
        begin
            st_d[curw] = d; st_k[curw] = kk; st_l[curw] = l;
            st_u[curw] = u; st_c[curw] = cc; st_e[curw] = ee;
            st_g[curw] = g[15:0];
            curw = curw + 1;
        end
    endtask

    // F4 TERM 收尾字 = {tdata=0, tkeep=0, tlast=1, tuser=0, tcrs=0, terr=1}
    task add_term_word;
        input integer g;
        begin
            add_word_raw(64'd0, 8'h00, 1'b1, 1'b0, 1'b0, 1'b1, g);
        end
    endtask

    // =====================================================================
    // 独立 spec 模型: 从激励表算每帧期望 (nw / route / Σkeep / 指纹)
    //   来源 = rtl/rx_classify.v 头注释语义 + P7B_RXCLASSIFY_AUDIT.md §2
    //   ethertype@w1[31:16], proto@w2[7:0], TCP flags@w5[7:0] (bit2 RST bit1 SYN bit0 FIN)
    //   tlast 最优先; 非 TCP 在 w2 定案 SLOW; TCP 到 w5 定案; 决策点前 tlast -> SLOW
    // =====================================================================
    task build_expect;
        integer i2, widx, rt, done_f, nw, pc;
        reg [63:0] h;
        reg [76:0] bb;
        reg is_tcp, ctl;
        begin
            nfexp = 0; widx = 0; rt = 1; done_f = 0; nw = 0; pc = 0; h = 64'd0;
            for (i2 = 0; i2 < nstim; i2 = i2 + 1) begin
                if (widx == 2 && !st_l[i2] && !done_f) begin
                    is_tcp = (st_d[i2-1][31:16] == 16'h0800) && (st_d[i2][7:0] == 8'd6);
                    if (!is_tcp) begin rt = 1; done_f = 1; end
                end else if (widx == 5 && !st_l[i2] && !done_f) begin
                    ctl = |st_d[i2][2:0];
                    rt = ctl ? 1 : 0;
                    done_f = 1;
                end
                if (st_l[i2] && !done_f) begin rt = 1; done_f = 1; end
                bb = {rt[0], st_d[i2], st_k[i2], st_l[i2], st_u[i2], st_c[i2], st_e[i2]};
                h  = hs_mix(h, bb);
                pc = pc + popc8(st_k[i2]);
                nw = nw + 1;
                if (st_l[i2]) begin
                    ex_nw[nfexp] = nw; ex_rt[nfexp] = rt;
                    ex_pc[nfexp] = pc; ex_hs[nfexp] = h;
                    nfexp = nfexp + 1;
                    nw = 0; pc = 0; h = 64'd0; widx = 0; rt = 1; done_f = 0;
                end else begin
                    if (widx != 15) widx = widx + 1;
                end
            end
        end
    endtask

    // =====================================================================
    // 逐拍对拍 + 帧表比较
    // =====================================================================
    integer cap_mismatch, rt_bad, dang1, dang2, fr_bad, ex_bad1, ex_bad2;
    integer sum_pc1, sum_pc2, sum_pcexp, fast1, slow1, fast2, slow2, fsum1, fsum2;
    integer wok;          // 拍数相等 = 后续一切帧级判据的前提 (防"真空通过")

    task walk_and_check;
        input [8*20-1:0] tag;
        input integer    chk_vs_expect;
        integer i2;
        reg [76:0] b1, b2;
        integer nw1, nw2, pc1, pc2, rt1, rt2;
        reg [63:0] h1, h2;
        begin
            cap_mismatch = 0; rt_bad = 0; dang1 = 0; dang2 = 0;
            sum_pc1 = 0; sum_pc2 = 0; sum_pcexp = 0;
            fast1 = 0; slow1 = 0; fast2 = 0; slow2 = 0;
            fr_bad = 0; ex_bad1 = 0; ex_bad2 = 0;
            nf1 = 0; nf2 = 0;
            nw1 = 0; nw2 = 0; pc1 = 0; pc2 = 0; rt1 = 1; rt2 = 1; h1 = 64'd0; h2 = 64'd0;
            chk(n1 === n2, {tag, " beats: v1 count == v2 count"}, "cmp:v1==v2");
            wok = (n1 === n2) ? 1 : 0;
            $display("  ---- %0s: v1 beats=%0d v2 beats=%0d specFrames=%0d ----", tag, n1, n2, nfexp);
            if (wok == 1) begin
                for (i2 = 0; i2 < n1; i2 = i2 + 1) begin
                    b1 = c1[i2]; b2 = c2[i2];
                    if (b1 !== b2) cap_mismatch = cap_mismatch + 1;
                    // --- v1
                    if (nw1 == 0) begin rt1 = b1[76]; o1_sc[nf1] = c1cy[i2]; end
                    else if (rt1 !== b1[76]) rt_bad = rt_bad + 1;
                    h1 = hs_mix(h1, b1); pc1 = pc1 + popc8(b1[11:4]); nw1 = nw1 + 1;
                    if (b1[3]) begin
                        o1_nw[nf1]=nw1; o1_rt[nf1]=rt1; o1_pc[nf1]=pc1;
                        o1_hs[nf1]=h1;  o1_ec[nf1]=c1cy[i2];
                        if (rt1 == 0) fast1 = fast1 + 1; else slow1 = slow1 + 1;
                        sum_pc1 = sum_pc1 + pc1;
                        nf1 = nf1 + 1; nw1 = 0; pc1 = 0; h1 = 64'd0;
                    end
                    // --- v2
                    if (nw2 == 0) begin rt2 = b2[76]; o2_sc[nf2] = c2cy[i2]; end
                    else if (rt2 !== b2[76]) rt_bad = rt_bad + 1;
                    h2 = hs_mix(h2, b2); pc2 = pc2 + popc8(b2[11:4]); nw2 = nw2 + 1;
                    if (b2[3]) begin
                        o2_nw[nf2]=nw2; o2_rt[nf2]=rt2; o2_pc[nf2]=pc2;
                        o2_hs[nf2]=h2;  o2_ec[nf2]=c2cy[i2];
                        if (rt2 == 0) fast2 = fast2 + 1; else slow2 = slow2 + 1;
                        sum_pc2 = sum_pc2 + pc2;
                        nf2 = nf2 + 1; nw2 = 0; pc2 = 0; h2 = 64'd0;
                    end
                end
                dang1 = nw1; dang2 = nw2;
            end
            // ⚠️ 帧级判据一律带 wok: 拍数不等时帧表根本没建 ⇒ 不加守卫就是"真空通过"
            chk(cap_mismatch === 0, {tag, " beat-wise bit-exact v1 vs v2 (0 mism)"}, "cmp:v1==v2");
            chk(wok === 1 && rt_bad === 0, {tag, " route constant within each frame"}, "contract:1 route/frame");
            chk(wok === 1 && dang1 === 0,  {tag, " v1 no dangling frame (all end w/ tlast)"}, "cmp:whole-frame rule");
            chk(wok === 1 && dang2 === 0,  {tag, " v2 no dangling frame (all end w/ tlast)"}, "cmp:whole-frame rule");
            chk(wok === 1 && nf1 === nf2,  {tag, " frame count v1 == v2"}, "cmp:v1==v2");
            if (wok === 1 && nf1 === nf2) begin
                j = 0;
                for (i2 = 0; i2 < nf1; i2 = i2 + 1)
                    if (o1_nw[i2] !== o2_nw[i2] || o1_rt[i2] !== o2_rt[i2] ||
                        o1_pc[i2] !== o2_pc[i2] || o1_hs[i2] !== o2_hs[i2]) j = j + 1;
                fr_bad = j;
                chk(fr_bad === 0, {tag, " per-frame content/route identical (nw,route,keep,hash)"}, "cmp:v1==v2");
            end
            chk(both1 === 0, {tag, " v1 never valid on both routes same cycle"}, "contract:1 word/beat");
            chk(both2 === 0, {tag, " v2 never valid on both routes same cycle"}, "contract:1 word/beat");
            chk(x1 === 0, {tag, " v1 output sidebands carry no X"}, "contract:no X");
            chk(x2 === 0, {tag, " v2 output sidebands carry no X"}, "contract:no X");
            // 计数器 vs 内容 (计数器可以被伪装)
            chk(wok === 1 && v1_stat_fast === fast1, {tag, " v1 stat_fast == frames routed fast in capture"}, "content vs counter");
            chk(wok === 1 && v1_stat_slow === slow1, {tag, " v1 stat_slow == frames routed slow in capture"}, "content vs counter");
            chk(wok === 1 && v2_stat_fast === fast2, {tag, " v2 stat_fast == frames routed fast in capture"}, "content vs counter");
            chk(wok === 1 && v2_stat_slow === slow2, {tag, " v2 stat_slow == frames routed slow in capture"}, "content vs counter");
            fsum1 = 0; fsum2 = 0;
            for (i2 = 0; i2 < nf1; i2 = i2 + 1) if (o1_rt[i2] == 0) fsum1 = fsum1 + o1_nw[i2];
            for (i2 = 0; i2 < nf2; i2 = i2 + 1) if (o2_rt[i2] == 0) fsum2 = fsum2 + o2_nw[i2];
            chk(wok === 1 && v1_wout === fsum1, {tag, " v1 dbg words_out == words in fast frames"}, "content vs counter");
            chk(wok === 1 && v2_wout === fsum2, {tag, " v2 dbg words_out == words in fast frames"}, "content vs counter");
            chk(v1_win === nstim, {tag, " v1 accepted words == stimulus words"}, "stim:nstim");
            chk(v2_win === nstim, {tag, " v2 accepted words == stimulus words"}, "stim:nstim");
            if (chk_vs_expect === 1) begin
                chk(wok === 1 && nf1 === nfexp, {tag, " v1 frame count == spec model"}, "model:w2/w5/tlast");
                chk(wok === 1 && nf2 === nfexp, {tag, " v2 frame count == spec model"}, "model:w2/w5/tlast");
                for (i2 = 0; i2 < nfexp; i2 = i2 + 1) sum_pcexp = sum_pcexp + ex_pc[i2];
                j = 0;
                for (i2 = 0; i2 < nfexp; i2 = i2 + 1)
                    if (o2_nw[i2] !== ex_nw[i2] || o2_rt[i2] !== ex_rt[i2] ||
                        o2_pc[i2] !== ex_pc[i2] || o2_hs[i2] !== ex_hs[i2]) j = j + 1;
                ex_bad2 = j;
                chk(wok === 1 && ex_bad2 === 0, {tag, " v2 frame table == spec model (nw,route,keep,hash)"}, "model:w2/w5/tlast");
                j = 0;
                for (i2 = 0; i2 < nfexp; i2 = i2 + 1)
                    if (o1_nw[i2] !== ex_nw[i2] || o1_rt[i2] !== ex_rt[i2] ||
                        o1_pc[i2] !== ex_pc[i2] || o1_hs[i2] !== ex_hs[i2]) j = j + 1;
                ex_bad1 = j;
                chk(wok === 1 && ex_bad1 === 0, {tag, " v1 frame table == spec model (nw,route,keep,hash)"}, "model:w2/w5/tlast");
                chk(wok === 1 && sum_pc2 === sum_pcexp, {tag, " v2 sum(popc(tkeep)) == stimulus sum"}, "stim:byte conservation");
                chk(wok === 1 && sum_pc1 === sum_pcexp, {tag, " v1 sum(popc(tkeep)) == stimulus sum"}, "stim:byte conservation");
            end
        end
    endtask

    // =====================================================================
    // 场景跑批
    // =====================================================================
    integer idle_cnt, tmo;

    task run_scn;
        input [8*20-1:0] tag;
        input integer    mode;
        input integer    w0;
        input integer    w1;
        input integer    chk_vs_expect;
        begin
            rst_n = 1'b0;
            bp_mode = mode; hw0 = w0; hw1 = w1;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            tmo = 0;
            while ((srcA_done !== 1'b1 || srcB_done !== 1'b1) && tmo < 400000) begin
                @(posedge clk); tmo = tmo + 1;
            end
            chk(tmo < 400000, {tag, " stimulus fully consumed (no timeout)"}, "tb:source drain");
            idle_cnt = 0; tmo = 0;
            while (idle_cnt < 60 && tmo < 40000) begin
                @(posedge clk); tmo = tmo + 1;
                if (!v1_f_v && !v1_sl_v && !v2_f_v && !v2_sl_v) idle_cnt = idle_cnt + 1;
                else idle_cnt = 0;
            end
            chk(tmo < 40000, {tag, " both DUTs drained (no timeout)"}, "tb:pipeline drain");
            $display("  ==== %0s: mode=%0d cycles=%0d v1stall=%0d v2stall=%0d v2ovf=%0d rqovf=%0d occ=%0d",
                     tag, mode, kc, v1_stall_tb, v2_stall_tb, v2_ovf, v2_rqovf, v2_occ);
            walk_and_check(tag, chk_vs_expect);
        end
    endtask

    task period_chk;
        input [8*64-1:0] name;
        input integer    dut;         // 1 = v1, 2 = v2
        input integer    exp_per;
        input [8*32-1:0] src;
        integer nfl, span, per;
        begin
            if (dut == 1) begin nfl = nf1; span = o1_ec[nf1-1] - o1_ec[0]; end
            else          begin nfl = nf2; span = o2_ec[nf2-1] - o2_ec[0]; end
            per = span / (nfl - 1);
            $display("  [meas] %0s frames=%0d span=%0d -> period=%0d (exp %0d)",
                     name, nfl, span, per, exp_per);
            chk((per === exp_per) && (span === exp_per * (nfl - 1)), name, src);
        end
    endtask

    // =====================================================================
    // 激励场景
    // =====================================================================
    localparam NFSTREAM = 32;

    task build_stream;
        input [15:0] et;
        input [7:0]  pr;
        input integer nb;
        input [7:0]  fl;
        input integer nfr;
        integer r;
        begin
            curw = 0;
            for (r = 0; r < nfr; r = r + 1)
                mk_frame(et, pr, nb, fl, 1, 0, 0,0,0,0,0);
            nstim = curw;
            build_expect;
        end
    endtask

    // 旧矩阵 (tools/gen_stim_p4_rxclass.py build_stream 的 29 帧) + F4 TERM 用例
    task build_seq;
        input integer rep;
        integer r;
        begin
            curw = 0;
            for (r = 0; r < rep; r = r + 1) begin
                mk_frame(16'h0800, 8'd17,  32, 8'h00, 1, 0,  2,0,0,0,0);
                mk_frame(16'h0800, 8'd1,   32, 8'h00, 1, 0,  2,0,0,0,0);
                mk_frame(16'h0806, 8'd0,   28, 8'h00, 1, 0,  2,0,0,0,0);
                mk_frame(16'h88B5, 8'd0,   36, 8'h00, 1, 0,  2,0,0,0,0);
                mk_frame(16'h0800, 8'd6,    6, 8'h00, 1, 0,  2,0,0,0,0);
                mk_frame(16'h0800, 8'd6,   12, 8'h00, 1, 0,  2,0,0,0,0);
                mk_frame(16'h0800, 8'd6,   24, 8'h00, 1, 0,  2,0,0,0,0);
                mk_frame(16'h0800, 8'd17,  24, 8'h00, 1, 0,  2,0,0,0,0);
                mk_frame(16'h0800, 8'd6,   40, 8'h18, 1, 0,  3,0,0,0,0);
                mk_frame(16'h0800, 8'd6,   32, 8'h18, 1, 0,  2,0,0,0,0);
                mk_frame(16'h0800, 8'd6,   40, 8'h18, 0, 0,  2,0,0,0,0);
                mk_frame(16'h0800, 8'd6,   40, 8'h18, 1, 1,  2,0,0,0,0);
                mk_frame(16'h0800, 8'd6,   40, 8'h18, 1, 0,  0,0,0,0,0);
                mk_frame(16'h0800, 8'd17,  40, 8'h00, 1, 0,  0,0,0,0,0);
                mk_frame(16'h0800, 8'd6,   40, 8'h18, 1, 0,  0,0,0,0,0);
                mk_frame(16'h0806, 8'd0,   28, 8'h00, 1, 0,  2,0,0,0,0);
                mk_frame(16'h0800, 8'd6,   48, 8'h18, 1, 0,  2,1,1,0,0);
                mk_frame(16'h0800, 8'd6,   96, 8'h18, 1, 0,  2,0,0,0,0);   // TCP fast
                mk_frame(16'h0800, 8'd6,   56, 8'h18, 1, 0,  2,0,0,0,0);   // TCP fast
                mk_frame(16'h0800, 8'd6,   56, 8'h10, 1, 0,  2,0,0,0,0);   // 纯 ACK fast
                mk_frame(16'h0800, 8'd6,   56, 8'h02, 1, 0,  2,0,0,0,0);   // SYN slow
                mk_frame(16'h0800, 8'd6,   56, 8'h11, 1, 0,  2,0,0,0,0);   // FIN slow
                mk_frame(16'h0800, 8'd6,   56, 8'h04, 1, 0,  2,0,0,0,0);   // RST slow
                mk_frame(16'h0800, 8'd6,   56, 8'h18, 0, 0,  2,0,0,0,0);   // 坏 FCS 仍 fast
                mk_frame(16'h0800, 8'd6,   56, 8'h10, 1, 1,  2,0,0,0,0);   // rx_er 仍 fast
                mk_frame(16'h0800, 8'd6,   56, 8'h18, 1, 0,  0,0,0,0,0);   // b2b
                mk_frame(16'h0800, 8'd6,   56, 8'h10, 1, 0,  0,0,0,0,0);   // b2b
                mk_frame(16'h0800, 8'd17,  56, 8'h00, 1, 0,  0,0,0,0,0);   // b2b
                mk_frame(16'h0800, 8'd6,   64, 8'h18, 1, 0,  2,0,1,0,1);   // 帧内气泡
                // ---- F4 用例: 上游中止帧的残字 (抹掉 tlast) + TERM 收尾字 ----
                //   期望: 残字 + TERM 合成 1 个"整帧" (以 TERM 的 tlast 收尾), 路由 SLOW, terr=1
                mk_frame(16'h0800, 8'd6,   40, 8'h18, 1, 0,  0,0,0,0,0);
                st_l[curw-1] = 1'b0; st_c[curw-1] = 1'b0; st_e[curw-1] = 1'b0;
                add_term_word(2);
                add_term_word(2);                                          // 独立 TERM (1 字帧)
            end
            nstim = curw;
            build_expect;
        end
    endtask

    // =====================================================================
    // 主流程
    // =====================================================================
    integer nterm;

    initial begin
        curw = 0; nstim = 0; nfexp = 0; bp_mode = 0; hw0 = 0; hw1 = 0;
        $display("=== tb_rxcls_v2 (P7B rx_classify 吞吐修复单元门) ===");

        // ---- S1: 背靠背最小 TCP 帧 (64B -> 60B 内容 = 8 字) ----
        build_stream(16'h0800, 8'd6, 60, 8'h18, NFSTREAM);
        $display("-- S1 stream_min_tcp: %0d frames x 8 words, back-to-back, no gap", NFSTREAM);
        run_scn("S1_tcp_min", 0, 0, 0, 1);
        period_chk("S1 v2 steady min-TCP frame period == 8", 2, 8,  "derived:1 word/cycle input");
        period_chk("S1 v1 steady min-TCP frame period == 14", 1, 14, "derived:8+6 audit 4.2");
        chk(v2_stall_tb === 0, "S1 v2 input stall cycles == 0", "derived:dec 6 < fifo 16");
        chk(v1_stall_tb > 0,   "S1 v1 input stall cycles > 0", "derived:FILL blocks input");
        chk(v2_stall === v2_stall_tb, "S1 v2 stall: DUT counter == TB measurement", "content vs counter");
        chk(v2_ovf === 0 && v2_rqovf === 0, "S1 v2 self-check counters == 0", "derived:exact space gate");

        // ---- S2: 背靠背最小 UDP 帧 (非 TCP 路径: 3 拍停顿) ----
        build_stream(16'h0800, 8'd17, 60, 8'h00, NFSTREAM);
        $display("-- S2 stream_min_udp: %0d frames x 8 words, back-to-back", NFSTREAM);
        run_scn("S2_udp_min", 0, 0, 0, 1);
        period_chk("S2 v2 steady min-UDP frame period == 8", 2, 8,  "derived:1 word/cycle input");
        period_chk("S2 v1 steady min-UDP frame period == 11", 1, 11, "derived:8+3 audit 4.2");

        // ---- S3: 背靠背满帧 TCP (1514B -> 190 字) ----
        build_stream(16'h0800, 8'd6, 1514, 8'h18, 16);
        $display("-- S3 stream_max_tcp: 16 frames x 190 words, back-to-back");
        run_scn("S3_tcp_max", 0, 0, 0, 1);
        period_chk("S3 v2 steady max-TCP frame period == 190", 2, 190, "derived:1 word/cycle input");
        period_chk("S3 v1 steady max-TCP frame period == 196", 1, 196, "derived:190+6 audit 4.2");

        // ---- S4: 旧 29 帧矩阵 x4 + TERM, 无背压 ----
        build_seq(4);
        $display("-- S4 seq matrix x4 (%0d words): no backpressure", nstim);
        run_scn("S4_nostall", 0, 0, 0, 1);
        chk(o2_sc[0] === o1_sc[0] && o2_ec[0] === o1_ec[0],
            "S4 first-frame beat cycles identical v1 vs v2", "derived:same decision point");
        nterm = 0;
        for (i = 0; i < nf2; i = i + 1)
            if (o2_nw[i] === 1 && o2_pc[i] === 0 && o2_rt[i] === 1) nterm = nterm + 1;
        chk(nterm > 0, "S4 F4 TERM closure frames present (1 word, 0 payload bytes)", "model:TERM word");

        // ---- S5: 周期 stall ----
        run_scn("S5_stall", 1, 0, 0, 1);
        chk(o2_sc[0] === o1_sc[0] && o2_ec[0] === o1_ec[0],
            "S5 first-frame beat cycles identical v1 vs v2", "derived:same decision point");

        // ---- S6: 伪随机背压 ----
        run_scn("S6_rand", 3, 0, 0, 1);

        // ---- S7: 深停等负对照 (40 拍 > FIFO 深 16) ----
        run_scn("S7_hard", 2, 300, 340, 1);
        chk(v2_stall_tb > 0, "S7 stress real: v2 input stalled in 40-cycle stall", "derived:40 > fifo 16");
        chk(v2_ovf === 0 && v2_rqovf === 0, "S7 no silent loss under stall: ovf/rqovf == 0", "derived:exact space gate");
        nterm = 0;
        for (i = 0; i < nf2; i = i + 1)
            if (o2_nw[i] === 1 && o2_pc[i] === 0 && o2_rt[i] === 1) nterm = nterm + 1;
        chk(nterm > 0, "S7 truncated frame closed by TERM (whole-frame drop rule)", "model:TERM word");
        chk(nf2 === nfexp, "S7 frame count == spec model (TERM closes truncation)", "model:w2/w5/tlast");

        $display("=== tb_rxcls_v2 done: %0d checks, %0d fail ===", nchk, nfail);
        if (nfail === 0) $display("VERDICT = PASS");
        else             $display("VERDICT = FAIL");
        $finish;
    end

endmodule
