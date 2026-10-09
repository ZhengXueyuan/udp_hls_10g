`timescale 1ns/1ps
// ===========================================================================
// tb_app_tailcarry.v -- P7B-GAP9-TX: app_pattern 尾字 carry (TX_TAILCARRY) 行为门
// ---------------------------------------------------------------------------
// 依据 = _proj_10g/notes/P7B_GAP9_TX_RECALC.md §B.2 (尾字刀: 改法 + 仓外原型实测)。
// 同一份 TB 源码, 四种编译方式 (bat 切宏); 见 sim/p7b_longsend/run_tailcarry_gate.bat:
//   ARM A: 无宏                     -- 逐字节路基线 (无 P7B_10G, 无 carry)
//   ARM B: -d P7B_10G               -- **改动前参照** (A2 整字路, carry 关)
//   ARM C: -d P7B_10G -d APP_TC_ARM -- **本轮交付配置** (A2 + carry 开)
//   ARM D: -d APP_TC_ARM            -- 参数传 1 但无 P7B_10G
//                                      ⇒ 结构性无效 ⇒ dump/stats 必须与 ARM A 逐字节相同
//                                      (= "参数门有牙 + 不该生效时不生效" 的负对照)
// 判据 (G1..G16, 全部在本 TB 内自判; 两臂的 dump 逐字节比对由 runner 做):
//   G1  图案流 oracle: 交付载荷字节逐字节 == TB 的 xorshift64 模型 (**跨帧连续**)
//   G2  AXIS 保持合同 (tvalid && !tready 期间数据不变)
//   G3  stat_tx_bytes / stat_tx_frames == TB 逐字/逐帧记账 (+ 在飞前缀分解)
//   G4  逐帧长度序列 == 模型 min(TX_SEGSZ, 量子剩余) (含量子尾帧 ⇒ "帧数x1460+尾")
//   G5  active 期间 seg_len 恒 != 0 (非零配置) = "无 seg_len==0 帧"
//   G6  u_cont 帧数 >= 20 + sum(帧长) == 帧数x1460 + 尾
//   G7  u_fw: stat_frmwait_cyc == TB 独立复算 == 先验窗长 W_FW; 且 != 0; 且 bp == 0
//   G8  u_bp: stat_bp_cyc == TB 独立复算 == 先验窗长 W_BP; 且 != 0; 且 frmwait == 0
//   G9  u_nostall: 两个计数器**都恒 0** (负对照: 无门控 ⇒ 无停顿)
//   G10 u_bad: 注入帧确实发生 (stat_bad_frames==1) 且其后图案流仍连续 (由 G1 覆盖)
//   G11 wc_n 不变量: 恒 <= 7; u_mul8 (每帧恰 8 B) 恒 == 0
//   G12 u_rec: ev_down -> ev_up 同槽重连后**确实恢复** (新会话帧起始数 > 0)
//   G13 帧周期: 1460B 帧周期 == 186 拍 (carry 臂) / 190 拍 (参照臂) —— 设计件 §B.2 预测
//   G14 u_zero: 零量子臂静默 (0 帧 0 字节) —— G5 的排除项由它锚定
//   G15 u_fin: 有限会话正常收尾 (done=1 且 close_req 有脉冲)
//   G16 u_cont: 连续模式 close_req 恒 0 / done 恒 0
// ⚠️ 打印字符串一律 ASCII (xsim 写中文会变 0xFF)。
// ⚠️ 本 TB **不**编译冻结锚 (run_cont_gate.bat 负责那一面) ⇒ 可以接新端口。
// ⚠️ 记账变量的写者**唯一**: 模型块 (NB/阻塞混用, 仿 tb_app_cont) 与结构探针块分开。
// ===========================================================================
module tb_app_tailcarry;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #3.2 clk = ~clk;                       // 6.4 ns = 156.25 MHz

    localparam [63:0] SEED = 64'h9E3779B97F4A7C15;
    localparam integer NALL   = 10;
    localparam integer CY_TOT = 45000;              // no-A2 臂 1828 拍/帧也能出 >=20 帧
    localparam integer W_FW   = 200;              // u_fw: app_tx_ready 低窗 (拍)
    localparam integer W_BP   = 120;              // u_bp: m_tready 低窗 (拍)
    localparam integer FW_TL  = 6;                // u_fw 窗口起点 = 第 FW_TL 个 tlast 之后
    localparam integer BP_TL  = 12;               // u_bp 窗口起点 = 第 BP_TL 个 tlast 之后
    localparam integer BP_OFF = 20;               // 再 +BP_OFF 拍 (确保落在帧中)
    localparam [11:0]  SEGI   = 12'd1460;

    // ---- 每实例参数表 (最左 = idx9, 最右 = idx0; 用 [gi*W +: W] 取) ----
    // idx0 u_fin    5877 = 1460*4+37 -> 5 帧 (跨 4 个帧边界; 尾字 4/5 两种)
    // idx1 u_bad    同上 + i_bad_frame=3 (坏帧注入 + carry)
    // idx2 u_rec    同上 + ev_down/ev_up 同槽重连 (换流 + carry)
    // idx3 u_zero   0   (退化: 静默)
    // idx4 u_cont   4417 = 1460*3+37 -> 4 帧/量子, 连续 (>=20 帧)
    // idx5 u_fw     同上 + app_tx_ready 低窗 W_FW   (frm_wait 计数器判据)
    // idx6 u_bp     同上 + m_tready 低窗 W_BP       (bp 计数器判据)
    // idx7 u_nostall 同上, 无任何门控              (两个计数器的负对照)
    // idx8 u_mul8   8   (每帧恰 1 个满字 => carry 必须恒空)
    // idx9 u_one    1   (每帧 1 B, need_a=1 的最小 case)
    localparam [NALL*32-1:0] BYTTAB = {
        32'd1, 32'd8, 32'd4417, 32'd4417, 32'd4417, 32'd4417,
        32'd0, 32'd5877, 32'd5877, 32'd5877 };
    localparam [NALL*2-1:0] CONTAB = {
        2'd1, 2'd1, 2'd1, 2'd1, 2'd1, 2'd1,
        2'd0, 2'd0, 2'd0, 2'd0 };
    localparam [NALL*16-1:0] BADTAB = {
        16'd0, 16'd0, 16'd0, 16'd0, 16'd0, 16'd0,
        16'd0, 16'd0, 16'd3, 16'd0 };
    // 参与"帧长模型"判据的实例 (零臂不参与)
    localparam [NALL*2-1:0] LOKTAB = {
        2'd1, 2'd1, 2'd1, 2'd1, 2'd1, 2'd1,
        2'd0, 2'd1, 2'd1, 2'd1 };

    // ---------------- TB 侧图案模型 (与 app / peer 同一递推) ----------------
    function [63:0] xs_next;
        input [63:0] s;  reg [63:0] t;
        begin t = s ^ (s << 13); t = t ^ (t >> 7); t = t ^ (t << 17); xs_next = t; end
    endfunction

    function [3:0] pop8v;
        input [7:0] x;
        integer q;
        begin q = 0; if (x[0]) q = q + 1; if (x[1]) q = q + 1; if (x[2]) q = q + 1;
              if (x[3]) q = q + 1; if (x[4]) q = q + 1; if (x[5]) q = q + 1;
              if (x[6]) q = q + 1; if (x[7]) q = q + 1; pop8v = q[3:0];
        end
    endfunction


    // ---------------- 实例端口阵列 ----------------
    wire [63:0] w_d [0:NALL-1];
    wire [7:0]  w_k [0:NALL-1];
    wire        w_v [0:NALL-1];
    wire        w_l [0:NALL-1];
    wire [3:0]  w_tid [0:NALL-1];
    wire [31:0] w_txb [0:NALL-1], w_txf [0:NALL-1], w_badf [0:NALL-1];
    wire [31:0] w_rxb [0:NALL-1], w_mm [0:NALL-1];
    wire [31:0] w_fw [0:NALL-1], w_bp [0:NALL-1];      // ⭐ 两个新计数器
    wire        w_done [0:NALL-1], w_act [0:NALL-1], w_cr [0:NALL-1];
    // TB 侧记账/模型 (module 级数组: generate 里按 gi 索引; 每项**单一写者**)
    reg [63:0] M_mdl [0:NALL-1];
    reg [31:0] M_nby [0:NALL-1], M_nfr [0:NALL-1], M_nn [0:NALL-1];
    reg [31:0] M_orc [0:NALL-1], M_ax [0:NALL-1], M_cr [0:NALL-1];
    reg [31:0] M_fer [0:NALL-1], M_rem [0:NALL-1], M_exp [0:NALL-1], M_sumlen [0:NALL-1];
    reg [31:0] M_tl1 [0:NALL-1], M_tlp [0:NALL-1], M_d12 [0:NALL-1];
    reg [31:0] M_d23 [0:NALL-1], M_d34 [0:NALL-1], M_nst [0:NALL-1], M_fup [0:NALL-1];
    reg        M_in [0:NALL-1], M_ovr [0:NALL-1], M_dset [0:NALL-1];
    reg [31:0] M_prb [0:NALL-1];                        // G5/G11 结构探针 (独立块)
    reg [31:0] M_nc [0:NALL-1];                         // 本帧被 DUT 计数的字节 (closing 收尾字不计)
    reg [31:0] M_frmord [0:NALL-1];                     // 帧序号 (1 起; opener 拍递增)
    reg        M_badnow [0:NALL-1];                     // 本帧 = 注入帧 (BAD_LEN/0xA5)
    reg [63:0] M_shd [0:NALL-1];
    reg [7:0]  M_shk [0:NALL-1];
    reg        M_shl [0:NALL-1], M_stall [0:NALL-1];
    integer    fd_b [0:NALL-1], fd_f [0:NALL-1];

    // ---------------- 全局起始脉冲 ----------------
    reg [1:0] est;
    always @(posedge clk) if (!rst_n) est <= 2'd0;
    else est <= (est == 2'd3) ? 2'd3 : (est + 2'd1);
    wire up_glob = (est == 2'd1);

    // ---------------- m_tready / app_tx_ready 门控 ----------------
    //   idx5 = u_fw : app_tx_ready[0] 低窗 (W_FW 拍, 由"第 FW_TL 个 tlast"触发)
    //   idx6 = u_bp : m_tready 低窗 (W_BP 拍, 由"第 BP_TL 个 tlast"+BP_OFF 触发)
    //   ⚠️ 触发一律用**接口事件** (tvalid && tready && tlast, 取 idx4 的), 不用绝对拍号
    //      —— 这样两臂 (carry 开/关) 的**字节位置**相同, dump 才可比。
    reg  [NALL-1:0] rdy_r;
    wire [NALL-1:0] rdy = rdy_r;
    reg  fw_low, bp_low;
    reg  [31:0] tl_cnt;
    reg  [31:0] fw_cy_low, bp_cy_low;        // TB 自己数的"门低拍数" (激励自证)
    reg  [31:0] fw_recount, bp_recount;      // TB 按语义独立复算的拍数
    reg  [7:0]  fw_st, bp_st;
    reg  [31:0] bp_wait;
    wire any_tlast = (w_v[4] && rdy[4] && w_l[4]);

    always @(posedge clk) if (!rst_n) begin
        tl_cnt <= 32'd0; fw_low <= 1'b0; bp_low <= 1'b0;
        fw_cy_low <= 32'd0; bp_cy_low <= 32'd0;
        fw_st <= 8'd0; bp_st <= 8'd0; bp_wait <= 32'd0;
    end else begin
        if (any_tlast) tl_cnt <= tl_cnt + 32'd1;
        // ---- u_fw: 第 FW_TL 个 tlast 那一拍之后开始拉低 ----
        if (fw_st == 8'd0) begin
            if (any_tlast && (tl_cnt == (FW_TL-1))) begin fw_st <= 8'd1; fw_low <= 1'b1; end
        end else begin
            if (fw_cy_low == (W_FW-1)) fw_low <= 1'b0;
        end
        if (fw_low) fw_cy_low <= fw_cy_low + 32'd1;
        // ---- u_bp: 第 BP_TL 个 tlast 之后再过 BP_OFF 拍开始拉低 ----
        if (bp_st == 8'd0) begin
            if (any_tlast && (tl_cnt == (BP_TL-1))) begin bp_st <= 8'd1; bp_wait <= 32'd0; end
        end else if (bp_st == 8'd1) begin
            bp_wait <= bp_wait + 32'd1;
            if (bp_wait == (BP_OFF-1)) begin bp_st <= 8'd2; bp_low <= 1'b1; end
        end else begin
            if (bp_cy_low == (W_BP-1)) bp_low <= 1'b0;
        end
        if (bp_low) bp_cy_low <= bp_cy_low + 32'd1;
    end

    // ---------------- u_rec (idx2): ev_down -> 6 拍 tready 低 -> +240 拍 ev_up ----
    //   与 tb_app_cont 的 u_rec3 同款 (tready 低窗短 ⇒ 收尾能完成 ⇒ 重连必定恢复);
    //   "第 20 个 payload beat" 触发 = 接口事件 ⇒ 两臂的字节位置相同。
    reg [15:0] r2n, r2t;  reg r2dn, r2tlow;
    wire rec_beat = w_v[2] && rdy[2] && (w_k[2] != 8'h00);
    wire rec_dn   = (r2n == 16'd190) && rec_beat && !r2dn;   // 第 190 个 payload beat
    //   (= 第 2 帧中段: 此时 carry **非空** (第 1 帧尾字留下 4 B) => ev_down/ev_up 落在
    //    "carry 有残留"的相位上 —— 这是 M3 变异件 (换流不清 carry) 必须被看见的激励条件;
    //    若把触发点放在第 1 帧内, carry 恰为空 => 该变异件结构性地无判别力)
    wire rec_up   = r2dn && (r2t == 16'd240);
    always @(posedge clk) if (!rst_n) begin
        r2n <= 16'd0; r2t <= 16'd0; r2dn <= 1'b0; r2tlow <= 1'b0;
    end else begin
        if (rec_beat) r2n <= r2n + 16'd1;
        if (rec_dn) begin r2dn <= 1'b1; r2tlow <= 1'b1; end
        else if (r2dn) begin
            r2t <= r2t + 16'd1;
            if (r2t == 16'd6) r2tlow <= 1'b0;
        end
    end
    wire [NALL-1:0] up_x = {{(NALL-1){1'b0}}, rec_up} << 2;
    wire [NALL-1:0] dn_x = {{(NALL-1){1'b0}}, rec_dn} << 2;
    wire [NALL-1:0] up_w = {NALL{up_glob}} | up_x;
    wire [NALL-1:0] dn_w = dn_x;

    always @(posedge clk) if (!rst_n) rdy_r <= {NALL{1'b1}};
    else begin
        rdy_r <= {NALL{1'b1}};
        rdy_r[2] <= ~(r2tlow | rec_dn);
        rdy_r[6] <= ~bp_low;
    end

    // ================= 全局时钟计数 =================
    reg [31:0] cyc;
    always @(posedge clk) if (!rst_n) cyc <= 32'd0; else cyc <= cyc + 32'd1;

    // 连续/carry 参数宏 (不传 ⇒ 用模块默认值; 这是"默认关"那一半的编译形态)
`ifdef APP_TC_ARM
    `define TC .TX_TAILCARRY(1'b1),
`else
    `define TC
`endif

    // ---------------- DUT 阵列 (generate) ----------------
    genvar gi;
    generate
    for (gi = 0; gi < NALL; gi = gi + 1) begin : GB
        localparam [31:0] TXBI = BYTTAB[gi*32 +: 32];
        localparam        CONTI = CONTAB[gi*2];
        localparam [15:0] BADI = BADTAB[gi*16 +: 16];
        localparam        LOKI  = LOKTAB[gi*2];
        wire [15:0] app_rdy_g = (gi == 5) ? {15'h7FFF, ~fw_low} : 16'hFFFF;
        integer li;  reg [7:0] bb;

        app_pattern #(`TC .TX_BYTES(TXBI), .TX_SEGSZ(SEGI),
                      .TX_CONTINUOUS(CONTI)) u_dut (
            .clk(clk), .rst_n(rst_n), .ev_up(up_w[gi]), .ev_down(dn_w[gi]),
            .ev_slot(4'd0),
            .m_tdata(w_d[gi]), .m_tkeep(w_k[gi]), .m_tvalid(w_v[gi]),
            .m_tready(rdy[gi]), .m_tlast(w_l[gi]), .m_tid(w_tid[gi]),
            .app_tx_ready(app_rdy_g),
            .close_req(w_cr[gi]), .close_id(),
            .rx_tdata(64'd0), .rx_tkeep(8'h00), .rx_tvalid(1'b0), .rx_tready(),
            .rx_tlast(1'b0), .rx_tid(4'd0),
            .i_bad_frame(BADI),
            .stat_tx_bytes(w_txb[gi]), .stat_tx_frames(w_txf[gi]),
            .stat_bad_frames(w_badf[gi]),
            .stat_rx_bytes(w_rxb[gi]), .stat_mismatch(w_mm[gi]),
            .active(w_act[gi]), .act_id(), .done(w_done[gi]), .dbg_lfsr(), .led(),
            .stat_frmwait_cyc(w_fw[gi]), .stat_bp_cyc(w_bp[gi])
        );

        // ---- 结构不变量 (G5/G11) —— 单独的写者, 只写 M_prb ----
        always @(posedge clk) begin
            if (!rst_n) M_prb[gi] <= 32'd0;
            else if (TXBI != 32'd0) begin
                if (u_dut.wc_n > 4'd7)
                    M_prb[gi] <= M_prb[gi] + 32'd1;
                if (u_dut.active && (u_dut.seg_len == 12'd0))
                    M_prb[gi] <= M_prb[gi] + 32'd1;
                if ((TXBI == 32'd8) && (u_dut.wc_n != 4'd0))
                    M_prb[gi] <= M_prb[gi] + 32'd1;
            end
        end

        // ---- 逐实例: dump + oracle + 帧长模型 + AXIS 合同 ----
        always @(posedge clk) begin
            if (!rst_n) begin
                M_mdl[gi] <= SEED; M_nby[gi] <= 0; M_nfr[gi] <= 0; M_nn[gi] <= 0;
                M_orc[gi] <= 0; M_ax[gi] <= 0; M_cr[gi] <= 0;
                M_fer[gi] <= 0; M_sumlen[gi] <= 0;
                M_rem[gi] <= TXBI;
                M_exp[gi] <= (TXBI > {20'b0, SEGI}) ? SEGI : {20'b0, TXBI[11:0]};
                M_ovr[gi] <= (TXBI == 0); M_in[gi] <= 1'b0; M_dset[gi] <= 1'b0;
                M_fup[gi] <= 0; M_nst[gi] <= 0;
                M_tl1[gi] <= 0; M_tlp[gi] <= 0; M_d12[gi] <= 0; M_d23[gi] <= 0;
                M_d34[gi] <= 0;
                M_shd[gi] <= 0; M_shk[gi] <= 0; M_shl[gi] <= 0; M_stall[gi] <= 0;
                M_frmord[gi] <= 0; M_badnow[gi] <= 1'b0; M_nc[gi] <= 0;
            end else begin
                // AXIS 保持合同
                if (M_stall[gi] && w_v[gi] && !rdy[gi] &&
                    ((w_d[gi] !== M_shd[gi]) || (w_k[gi] !== M_shk[gi]) || (w_l[gi] !== M_shl[gi]))) begin
                    M_ax[gi] = M_ax[gi] + 32'd1;
                    $display("  [FAIL] G2 AXIS hold idx=%0d cyc=%0d", gi, cyc);
                end
                M_stall[gi] <= w_v[gi] && !rdy[gi];
                M_shd[gi] <= w_d[gi]; M_shk[gi] <= w_k[gi]; M_shl[gi] <= w_l[gi];

                if (w_cr[gi]) M_cr[gi] = M_cr[gi] + 32'd1;
                if (w_done[gi]) M_dset[gi] = 1'b1;

                // ---- 接受一个 beat ----
                if (w_v[gi] && rdy[gi]) begin
                    if (!M_in[gi]) M_in[gi] = 1'b1;
                    if ((w_k[gi] == 8'h00) && !w_l[gi]) begin
                        M_nst[gi] = M_nst[gi] + 32'd1;
                        M_frmord[gi] = M_frmord[gi] + 32'd1;              // 1-based frame ordinal
                        // app_pattern 的注入帧口径 (逐字读 RTL): 收帧拍里 `bad_frm <= (frm_idx+1)==i_bad_frame`
                        //   而 frm_idx 本拍才自增 => **坏帧 = 第 (i_bad_frame+1) 帧** (i_bad_frame>=2);
                        //   i_bad_frame==1 另有 ev_up 特例 (第 1 帧也坏) —— 本 TB 取 BADI=3 避开它。
                        M_badnow[gi] = (BADI != 16'd0) && (M_frmord[gi] == ({16'd0, BADI} + 32'd1));
                    end
                    for (li = 0; li < 8; li = li + 1) begin
                        if (w_k[gi][7 - li]) begin
                            case (li)
                                0: bb = w_d[gi][63:56];  1: bb = w_d[gi][55:48];
                                2: bb = w_d[gi][47:40];  3: bb = w_d[gi][39:32];
                                4: bb = w_d[gi][31:24];  5: bb = w_d[gi][23:16];
                                6: bb = w_d[gi][15:8];   default: bb = w_d[gi][7:0];
                            endcase
                            $fwrite(fd_b[gi], "%02x", bb);
                            if (M_badnow[gi]) begin
                                // injected frame (i_bad_frame): payload = CONSTANT 0xA5 in BOTH builds
                                //   (default path gen_byte const-fill same as carry path wc_pwv const),
                                //   pattern LFSR frozen => do NOT advance the model, do NOT count into M_nby
                                //   (DUT stat_tx_bytes excludes injected frames too); M_nn DO counts it
                                //   (the frame-length criterion needs the length).
                                if (bb !== 8'hA5) begin
                                    M_orc[gi] = M_orc[gi] + 32'd1;
                                    if (M_orc[gi] <= 32'd4)
                                        $display("  [FAIL] G1 injected-frame payload != 0xA5 idx=%0d cyc=%0d got=%02x",
                                                 gi, cyc, bb);
                                end
                            end else begin
                                if (bb !== M_mdl[gi][31:24]) begin
                                    M_orc[gi] = M_orc[gi] + 32'd1;
                                    if (M_orc[gi] <= 32'd4)
                                        $display("  [FAIL] G1 pattern mismatch idx=%0d cyc=%0d got=%02x exp=%02x",
                                                 gi, cyc, bb, M_mdl[gi][31:24]);
                                end
                                M_mdl[gi] = xs_next(M_mdl[gi]);
                                // counted-byte scope == DUT stat_tx_bytes: the word delivered
                                //   DURING closing is NOT counted by the DUT (W3 wrap-up does not
                                //   advance remain/stat_tx_bytes) => the TB must not count it either.
                                if (!(w_l[gi] && u_dut.closing)) begin
                                    M_nby[gi] = M_nby[gi] + 32'd1;
                                    M_nc[gi]  = M_nc[gi] + 32'd1;
                                end
                                if ((M_nby[gi] % 32) == 0) $fwrite(fd_b[gi], "\n");
                            end
                            M_nn[gi]  = M_nn[gi] + 32'd1;
                        end
                    end
                    if (w_l[gi]) begin
                        // ---- 帧长模型 (只在 LOK 且非零配置的实例上判) ----
                        if (LOKI && (TXBI != 0) && M_badnow[gi]) begin
                            // injected frame: length must be BAD_LEN (2000); remain untouched
                            if (M_nn[gi] != 32'd2000) begin
                                M_fer[gi] = M_fer[gi] + 32'd1;
                                $display("  [FAIL] G4 injected frame len idx=%0d cyc=%0d got=%0d exp=2000",
                                         gi, cyc, M_nn[gi]);
                            end
                        end else if (u_dut.closing) begin
                            // teardown-truncated frame (ev_down mid-frame): delivered length is
                            //   timing-dependent => length check skipped; the COUNTED bytes (M_nc)
                            //   still consume remain (the DUT decrements remain at each counted word).
                            if (M_rem[gi] >= M_nc[gi]) M_rem[gi] = M_rem[gi] - M_nc[gi];
                            else                      M_rem[gi] = 32'd0;
                        end else if (LOKI && (TXBI != 0)) begin
                            if (M_ovr[gi]) begin
                                M_fer[gi] = M_fer[gi] + 32'd1;
                                $display("  [FAIL] G4 frame after session end idx=%0d cyc=%0d", gi, cyc);
                            end else if (M_nn[gi] != M_exp[gi]) begin
                                M_fer[gi] = M_fer[gi] + 32'd1;
                                if (M_fer[gi] <= 32'd4)
                                    $display("  [FAIL] G4 frame length idx=%0d cyc=%0d got=%0d exp=%0d frm=%0d",
                                             gi, cyc, M_nn[gi], M_exp[gi], M_nfr[gi]);
                                if (M_rem[gi] >= M_nn[gi]) M_rem[gi] = M_rem[gi] - M_nn[gi];
                                else                       M_rem[gi] = 32'd0;
                            end else begin
                                M_rem[gi] = M_rem[gi] - M_exp[gi];
                            end
                            if (M_rem[gi] == 32'd0) begin
                                if (CONTI) M_rem[gi] = TXBI;      // 连续: 重装载一个量子
                                else       M_ovr[gi] = 1'b1;      // 有限: 会话结束
                            end
                            M_exp[gi] = (M_rem[gi] > {20'b0, SEGI}) ? SEGI : M_rem[gi];
                        end
                        $fwrite(fd_f[gi], "%0d\n", M_nn[gi]);
                        M_nfr[gi] = M_nfr[gi] + 32'd1;
                        M_sumlen[gi] = M_sumlen[gi] + M_nn[gi];
                        M_fup[gi] = M_fup[gi] + 32'd1;
                        M_in[gi] = 1'b0;
                        M_nn[gi] = 32'd0;
                        M_nc[gi] = 32'd0;
                        if (M_nfr[gi] == 32'd1) M_tl1[gi] = cyc;
                        else if (M_nfr[gi] == 32'd2) M_d12[gi] = cyc - M_tlp[gi];
                        else if (M_nfr[gi] == 32'd3) M_d23[gi] = cyc - M_tlp[gi];
                        else if (M_nfr[gi] == 32'd4) M_d34[gi] = cyc - M_tlp[gi];
                        M_tlp[gi] = cyc;
                    end
                end
                // ---- 换流: 新会话图案从 SEED 重开, 帧长模型重开 ----
                if (up_w[gi]) begin
                    M_mdl[gi] = SEED;
                    M_rem[gi] = TXBI;
                    M_exp[gi] = (TXBI > {20'b0, SEGI}) ? SEGI : {20'b0, TXBI[11:0]};
                    M_ovr[gi] = (TXBI == 0);
                    M_fup[gi] = 0; M_nst[gi] = 0; M_nc[gi] = 0;
                end
            end
        end
    end
    endgenerate

    // 计数器语义的独立复算门 (只挂 idx5/idx6 两个实例; 层次引用 = 常量下标 ✓)
    wire fw_recount_w = GB[5].u_dut.frm_wait && GB[5].u_dut.active && !GB[5].u_dut.bad_frm;
    wire bp_recount_w = GB[6].u_dut.pw_valid && !rdy[6] && !GB[6].u_dut.closing
                        && !GB[6].u_dut.bad_frm;
    always @(posedge clk) if (!rst_n) begin
        fw_recount <= 32'd0; bp_recount <= 32'd0;
    end else begin
        if (fw_recount_w) fw_recount <= fw_recount + 32'd1;
        if (bp_recount_w) bp_recount <= bp_recount + 32'd1;
    end

    // ================= 判据 =================
    integer errs;
    task chk;
        input cond;  input [1023:0] msg;
        begin
            if (!cond) begin errs = errs + 1; $display("  [FAIL] %0s", msg); end
            else         $display("  [ ok ] %0s", msg);
        end
    endtask

    integer ii, kk;
    reg [31:0] exp_sum;
    integer f_stats, f_rate;
    reg [255:0] fn;

    initial begin
        errs = 0; rst_n = 1'b0; est = 2'd0; cyc = 0;
        fw_low = 1'b0; bp_low = 1'b0; r2n = 0; r2t = 0; r2dn = 0; r2tlow = 0;
        for (ii = 0; ii < NALL; ii = ii + 1) begin
            $sformat(fn, "d%0d.hex", ii);  fd_b[ii] = $fopen(fn, "w");
            $sformat(fn, "f%0d.txt", ii);  fd_f[ii] = $fopen(fn, "w");
        end
        f_stats = $fopen("stats.txt", "w");
        f_rate  = $fopen("rate.txt", "w");

        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (CY_TOT) @(posedge clk);
        #1;

        for (ii = 0; ii < NALL; ii = ii + 1) begin
            $fclose(fd_b[ii]);  $fclose(fd_f[ii]);
        end

        for (ii = 0; ii < NALL; ii = ii + 1)
            $display("  I%0d: frames=%0d bytes=%0d done=%0d active=%0d cr=%0d bad=%0d | tb_bytes=%0d orc=%0d ax=%0d prb=%0d ferr=%0d fw=%0d bp=%0d",
                     ii, w_txf[ii], w_txb[ii], w_done[ii], w_act[ii], M_cr[ii], w_badf[ii],
                     M_nby[ii], M_orc[ii], M_ax[ii], M_prb[ii], M_fer[ii], w_fw[ii], w_bp[ii]);
        $display("  RATE: tl1=%0d d12=%0d d23=%0d d34=%0d (u_cont idx4)", M_tl1[4], M_d12[4], M_d23[4], M_d34[4]);
        $display("  FW : low_cycles=%0d recount=%0d dut=%0d", fw_cy_low, fw_recount, w_fw[5]);
        $display("  BP : low_cycles=%0d recount=%0d dut=%0d", bp_cy_low, bp_recount, w_bp[6]);
        $display("  NST: fw=%0d bp=%0d (u_nostall)", w_fw[7], w_bp[7]);
        $display("  REC: u_rec_frames=%0d starts_after_up=%0d active=%0d", w_txf[2], M_nst[2], w_act[2]);
        $display("  BAD: u_bad_frames=%0d badf=%0d bytes=%0d", w_txf[1], w_badf[1], w_txb[1]);
        $display("  ZRO: frames=%0d bytes=%0d active=%0d done=%0d", w_txf[3], w_txb[3], w_act[3], w_done[3]);

        for (ii = 0; ii < NALL; ii = ii + 1)
            $fwrite(f_stats, "I%0d TX_BYTES=%0d cont=%0d frames=%0d bytes=%0d bad=%0d tb_bytes=%0d tb_frames=%0d orc=%0d ax=%0d prb=%0d ferr=%0d fw=%0d bp=%0d done=%0d act=%0d cr=%0d\r\n",
                    ii, BYTTAB[ii*32 +: 32], (CONTAB[ii*2] ? 1 : 0), w_txf[ii], w_txb[ii], w_badf[ii],
                    M_nby[ii], M_nfr[ii], M_orc[ii], M_ax[ii], M_prb[ii], M_fer[ii], w_fw[ii], w_bp[ii],
                    w_done[ii], w_act[ii], M_cr[ii]);
        $fclose(f_stats);
        $fwrite(f_rate, "tl1=%0d d12=%0d d23=%0d d34=%0d\r\n", M_tl1[4], M_d12[4], M_d23[4], M_d34[4]);
        $fclose(f_rate);

        // ---------- G1..G4: 通用 (全部实例) ----------
        for (ii = 0; ii < NALL; ii = ii + 1) begin
            chk(M_orc[ii] == 0, "G1 oracle: payload byte stream == TB xorshift64 model (cross-frame)");
            chk(M_ax[ii]  == 0, "G2 AXIS hold contract");
            chk(M_prb[ii] == 0, "G5/G11 structural probes (seg_len!=0 while active; wc_n<=7; u_mul8 carry empty)");
            chk(w_txb[ii] == M_nby[ii], "G3 stat_tx_bytes == TB delivered byte count");
            chk(w_txf[ii] == M_nfr[ii], "G3 stat_tx_frames == TB tlast count");
            chk(M_fer[ii] == 0, "G4 frame length sequence == model min(SEG, quantum rest)");
        end

        // ---------- G6 + "帧数x1460+尾" 的显式算术 ----------
        chk(w_txf[4] >= 32'd20, "G6 u_cont frames >= 20 (continuous arm long enough)");
        exp_sum = 32'd0;
        for (kk = 0; kk < w_txf[4]; kk = kk + 1)
            exp_sum = exp_sum + (((kk % 4) == 3) ? 32'd37 : 32'd1460);
        chk(M_sumlen[4] == exp_sum, "G6b u_cont: sum(frame lens) == frames*1460 + quantum tail");
        chk(w_txb[4] == M_sumlen[4] + M_nn[4], "G3b stat_tx_bytes == sum(completed) + in-flight prefix");

        // ---------- G7: u_fw (frm_wait 计数器) ----------
        chk(fw_cy_low == W_FW, "G7a stimulus self-check: tx_ready low window == W_FW cycles");
        chk(fw_recount == W_FW, "G7b independent recount == W_FW (a-priori timing model)");
        chk(w_fw[5] == fw_recount, "G7c DUT stat_frmwait_cyc == independent recount");
        chk(w_fw[5] != 32'd0, "G7d stat_frmwait_cyc non-zero (connected AND triggered)");
        chk(w_bp[5] == 32'd0, "G7e u_fw bp_cyc == 0 (no backpressure stimulus)");

        // ---------- G8: u_bp (背压计数器) ----------
        chk(bp_cy_low == W_BP, "G8a stimulus self-check: m_tready low window == W_BP cycles");
        chk(bp_recount == W_BP, "G8b independent recount == W_BP");
        chk(w_bp[6] == bp_recount, "G8c DUT stat_bp_cyc == independent recount");
        chk(w_bp[6] != 32'd0, "G8d stat_bp_cyc non-zero");
        chk(w_fw[6] == 32'd0, "G8e u_bp frmwait_cyc == 0 (no credit stall stimulus)");

        // ---------- G9: 负对照 ----------
        chk(w_fw[7] == 32'd0, "G9 u_nostall stat_frmwait_cyc == 0");
        chk(w_bp[7] == 32'd0, "G9 u_nostall stat_bp_cyc == 0");

        // ---------- G10/G12/G14/G15/G16 ----------
        chk(w_badf[1] == 32'd1, "G10 u_bad injected bad frame counted (stat_bad_frames==1)");
        chk(w_txf[1] != 32'd0,  "G10 u_bad still produced good frames");
        chk(M_nst[2] >= 32'd1, "G12 u_rec resumed after same-slot reconnect (new session frame start)");
        chk((w_txf[3] == 32'd0) && (w_txb[3] == 32'd0), "G14 u_zero silent (0 frames 0 bytes)");
        chk(w_done[0] == 1'b1, "G15 u_fin finite session finished (done=1)");
        chk(M_cr[0] >= 32'd1, "G15 u_fin close_req fired (AUTO_CLOSE)");
        chk(M_cr[4] == 32'd0, "G16 u_cont continuous: close_req == 0");
        chk(w_done[4] == 1'b0, "G16 u_cont continuous: done == 0");

`ifdef P7B_10G
    // ---------- G13: 帧周期 (只在 A2 构建里有意义) ----------
    //   设计件 §B.2 预测: 1460B 帧 (尾字 4 B) **carry 关** = 190 拍, **carry 开** = 186 拍。
    //   d12 = u_cont 第 1 帧 (1460 B) 的 tlast-to-tlast 周期。
  `ifdef APP_TC_ARM
        chk(M_d12[4] == 32'd186, "G13 carry arm: 1460B frame period == 186 (design predict)");
  `else
        chk(M_d12[4] == 32'd190, "G13 ref arm: 1460B frame period == 190 (design predict)");
  `endif
`endif

        $display("TB_APP_TC_SUM errs=%0d", errs);
        if (errs == 0) $display("TB_APP_TAILCARRY: OK");
        else           $display("TB_APP_TAILCARRY: FAIL errs=%0d", errs);
        $display("TB_APP_TAILCARRY DONE");
        $finish;
    end
endmodule
