`timescale 1ns/1ps
// ===========================================================================
// tb_p7b_chain.v -- P7b **真 wrapper 全链门** (工程坑 8: 每个 ifdef 构建配置都要有
//   一条例化真 wrapper 的全链门; 子模块 TB 对 ifdef 里的接线错完全隐身)
// ===========================================================================
// 被测 = `wrapper_p4` 在 P7B_10G + P7B_SIM_NOPCS + PCIE_OBS + DEV_USP + APP_MODE
//        + DP_156MHZ + P6B_SIM_CLKGEN 下的**真实例化**。
//
// ⚠️ 边界 (不许当"真 PCS 已验证"引用): 官方 `xxv_ethernet` 是加密 GT IP, xsim
//   bring-up 在本工程**从未做过** (P7B_XXV_OFFICIAL.md U15 = 【未核实】)。PCS 那个
//   socket 里放 `board/p7b_pcs_stub.v` —— **端口表与真核逐一相同**, 只造 XGMII 字节流
//   与两个 156.25MHz 时钟。⇒ 除 `u_pcs` 这一个实例, MAC / CDC / 数据面 / 快照的接线
//   与综合构建**逐字相同**。真核的证据在闸 1/闸 2/P7A (板级), 不在本门。
//
// 判据一律 `cond !== 1'b1`; 每条带「期望来源」(src=...); 期望值全部由本 TB 自算
//   (位串行 CRC-32 + 逐字节图案), **不由 DUT 生成**。
// ---------------------------------------------------------------------------
// 判据表 (简标签 → 完整陈述 + 期望来源; 日志里只打简标签)
//   0a crc32_std("123456789") == 0xCBF43926            | 802.3 标准校验向量 (zlib=取反后)
//   0b 帧内容+其 FCS 的残留 == 0xDEBB20E3           | 工程铁律 (0xC704DD7B 是大端魔数)
//   0c PCS stub 放行 (user_rx_reset_1==0)                 | 激励前提
//   0d SFP2 TX_DIS 驱动为低                             | GATE1 5.8 三态判别实验
//   1a RX 至少交付 1 帧                              | 激励前提 (非真空分母)
//   1b RX 首字节 == 内容[0] (tdata[63:56])             | 注入字节数组 + GATE1 §C.2 镜像表
//   1c RX 首字节 != XGMII lane7 那个字节              | 负向: 前 8 个内容字节两两不同
//   2a/2b 最小/最大帧交付字节数 == 60/1514           | 802.3 Cl.4.4 + 注入长度
//   2c Σpopc(tkeep) 守恒                                  | 合同: 交付字节 == 注入内容字节
//   2d 63+65 非 8 倍数帧 → 128 字节                       | 注入长度
//   2e 帧数 == 2 (不合并不拆分)                          | 合同: 每帧 1 个 TLAST
//   3a 好 FCS 不加 stat_crc_err                           | 注入 FCS == TB 算的 CRC32
//   3b 好 FCS 帧被交付 (64B)                           | 合同: tcrs=1
//   3c 坏 FCS 使 stat_crc_err +1                            | 注入: FCS 字段改成 0
//   3d 坏 FCS 帧仍被交付 (标志而非丢弃)                 | 合同: crc 错是标志
//   3e 帧内 /E/ 使 stat_rx_er_words 增                   | 注入 /E/ 在内容第 10 字节
//   3f stat_rx_fifo_ovf 恒 0                                | mac_rx_10g 结构上恒 0
//   4a/4b 零间隔背靠背 3 帧 → 3 帧 / 180 字节         | derive: 3 × 60
//   5a F4(a) 下游停摆时有丢帧计数                     | 40×1514B 对 16 字 FIFO
//   5b F4(b) 交付流里出现 TERM 字                       | TERM 五元组逐字
//   5c 无一帧超过 1514 内容字节                         | 注入最长度
//   5d F4 丢帧计数 > 0                                   | 同 5a
//   5e 恢复后下一帧逐字节正确                         | 注入 64B, 首字节 PAT[0]
//   6a TX 线上恰 1 帧 (无幽灵/无拆分)                      | 注入 1 个 tlast 帧
//   6b TX 首字 /S/ 在 lane0                               | 厂商 :995/:1147-1149 + GATE1 §C.4
//   6c TX 首字其余部分 == 55×6+D5                        | 厂商 :995 字面量
//   6d/6e/6f TX 线上前导与内容的 lane 顺序                | 合同 tdata[63:56] + 注入字节
//   7 W36..W50 = 被 force 的生产者常量                    | force 在生产者节点
//   7b 0xEC 读 0 且 SLVERR (无回绕)                        | axi_regs 读侧译码; 51 字地图边界
//       ⛔ 2026-10-07 订正 (P7B_STAGEB_FIX.md): 窗口现 **63 字** (BIZ 61 / Stage A 63) 且
//          **0xEC = W51 已是真字** ⇒ 本判据地址改 **0x11C** (未实现地址); 判据语义不变
//          (出处 P7B_STAGEB_RX8_REGRESSION.md §5.6/§6-③; 地图 = P7B_BIZ_WINDOW.md §1)
//   2f..2i 逐字节 == 注入 (60/1514/63/65B)              | 注入字节数组 (旧判据只查 Σpopc)
//   2j 逐字节比较器自检 (期望错位 1 字节 ⇒ 必判不一致)   | 反例内建: 证明 2f..2i 非哑判据
//   G1.0..G1.7 lane4 起点 (内容 60..67 = /T/ 落 lane4..3) 逐字节 | 802.3 合法起点 + 注入数组
//   G1z lane4 八档: 8 帧 / 508 字节 / 无幽灵            | derived: sum(60..67)
//   G1c lane4 八档把 /T/ 落位扫遍 lane0..7 (激励面自检) | MAC dbg_rx_last_tlane 实测
//   G2a/b/c 两个规范 lane4 帧背靠背 (跨帧半字交接)      | 合同: 帧边界清半字
//   G3a..G3d lane4 + F4 背压 (丢弃 / TERM / 恢复逐字节) | LANEFIX §3.4-4 = 残余风险 R3
//   G4 SOP-1 每个 SOP 字满对齐 (tkeep==8'hFF)             | 合同 mac_rx_10g.v:12 —— 此前一条都没有
//   G4 SOP-2 Σ(SOP) == Σ(TLAST)                            | 合同 §5: 绝不留裸尾巴字
//   G4 TERM-1 TERM 字出现过 (非真空分母)                 | 合同 mac_rx_10g.v:16
//   G4 TERM-2 TERM 六元组逐项 (tdata/tkeep/tlast/tuser/tcrs/terr) | 合同 :16 —— 旧判据只 3/6
// ---------------------------------------------------------------------------
// ===========================================================================
module tb_p7b_chain;

    integer fails  = 0;
    integer checks = 0;

    task chk;
        input [255:0] name;
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
    // 反射多项式 0xEDB88320 / 初值 0xFFFFFFFF / 无终值取反 / 线序 LSB-first。
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

    // ======================= 内容图案 ======================================
    // ⭐ 前 8 个内容字节两两不同 —— 字节序镜像判据的判别力全靠这一条
    reg [7:0] PAT [0:2047];
    integer   pi;
    task init_pat;
        begin
            for (pi = 0; pi < 2048; pi = pi + 1) PAT[pi] = pi[7:0];
            PAT[0] = 8'h01; PAT[1] = 8'h23; PAT[2] = 8'h45; PAT[3] = 8'h67;
            PAT[4] = 8'h89; PAT[5] = 8'hAB; PAT[6] = 8'hCD; PAT[7] = 8'hEF;
        end
    endtask

    function integer popc8;
        input [7:0] v;
        integer i;
        begin
            popc8 = 0;
            for (i = 0; i < 8; i = i + 1) if (v[i]) popc8 = popc8 + 1;
        end
    endfunction

    // ======================= XGMII 注入队列 (RX 方向) ======================
    // ⚠️ 驱动器**必须与 DUT 的恢复钟同拍** —— 用自造的同频异相时钟会偶发重复采到一个
    //    XGMII 字 ⇒ 线上多 8 字节, 症状像 MAC 缺陷。
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

    task xq_pack_words;               // 把 wb/wc 的前 n 个字节按 lane0=首字节 打包
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

    // 组一帧: /S/ 0xFB + 55x6 + D5 + [内容 n 字节] + [FCS 或 4 个 0]
    //   er_at: >=0 时在该内容下标后插一个 /E/ 控制字符
    //   frame_lane: 注入起点 lane (0 = 现状; **4** = /S/ 落 lane4, 802.3 另一个合法起点)
    //     —— xq_pack_words 只从字边界起 ⇒ 旧门**结构性只走 lane0** (P7B_LANEFIX §3.4-1)。
    //     build_frame 读一次即清 0 ⇒ 既有调用点一行不改 (默认仍是 lane0)。
    integer frame_lane = 0;
    task xq_pack_words_sh;            // 与 xq_pack_words 同构 + 可指定起始 lane
        input integer n;
        input integer sh;
        integer i, k;
        reg [63:0] d;
        reg [7:0]  c;
        begin
            if (sh != 4) xq_pack_words(n);
            else begin
                d = 64'h0707070707070707; c = 8'hFF;         // 前 4 lane = idle
                for (k = 4; k < 8; k = k + 1)
                    if ((k - 4) < n) begin d[k*8 +: 8] = wb[k-4]; c[k] = wc[k-4]; end
                xq_d[xq_wr] = d; xq_c[xq_wr] = c; xq_wr = xq_wr + 1;
                i = 4;
                while (i < n) begin
                    d = 64'd0; c = 8'd0;
                    for (k = 0; k < 8; k = k + 1)
                        if (i + k < n) begin d[k*8 +: 8] = wb[i+k]; c[k] = wc[i+k];    end
                        else           begin d[k*8 +: 8] = 8'h07;   c[k] = 1'b1;       end
                    xq_d[xq_wr] = d; xq_c[xq_wr] = c; xq_wr = xq_wr + 1;
                    i = i + 8;
                end
            end
        end
    endtask
    reg [31:0] fcs_calc;
    task build_frame;
        input integer n;
        input         bad;
        input integer er_at;
        integer i, m;
        begin
            fcs_calc = 32'hFFFFFFFF;
            for (i = 0; i < n; i = i + 1) fcs_calc = crc32_byte(fcs_calc, PAT[i]);
            fcs_calc = ~fcs_calc;      // 线上 FCS = ~internal (与 MAC 的写法一致)
            wb[0] = 8'hFB; wc[0] = 1;
            for (i = 0; i < 6; i = i + 1) begin wb[1+i] = 8'h55; wc[1+i] = 0; end
            wb[7] = 8'hD5; wc[7] = 0;
            m = 8;
            for (i = 0; i < n; i = i + 1) begin
                wb[m] = PAT[i]; wc[m] = 0; m = m + 1;
                if (i == er_at) begin wb[m] = 8'hFE; wc[m] = 1; m = m + 1; end
            end
            if (!bad) begin
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
            // ⭐ 帧尾必须给 /T/ (0xFD,c=1) —— 802.3 46.2.1 说了
            //   inter-frame 以 Terminate 开头; 没有 /T/ 的话接收端
            //   **永远等不到帧尾** (本门第一版就是这个错:
            //   DIAG 显示 dbg_rx_state=1 卡在收帧, rx_stat_frames=0)。
            //   置于最后一个有效字节之后的那个 lane。
            wb[m] = 8'hFD; wc[m] = 1; m = m + 1;
            xq_pack_words_sh(m, frame_lane);
            frame_lane = 0;               // 一次性: 既有调用点仍默认 lane0
        end
    endtask

    // ======================= 交付侧 (RX 合同) 观察 =========================
    reg [31:0] got_bytes = 0, got_frames = 0;
    reg        got_term_seen = 0;
    reg [63:0] got_first_tdata = 0;
    reg        got_started = 0;
    reg [31:0] got_first_words = 0;
    reg [7:0]  got_buf [0:4095];
    integer    got_len = 0;
    integer    got_f_len [0:127];
    integer    got_f_cnt = 0;
    integer    got_last_len = 0;
    // F2X11: 每帧 TLAST 拍的交付合同位 (tcrs = FCS 正确 / terr = 帧内错误)
    integer    got_f_crs  [0:127];
    integer    got_f_terr [0:127];
    integer    bi;

    // ============== P7B_CHAIN_COVERAGE: RX 字几何 / TERM 六元组 ==============
    // 起因 (notes/P7B_LANEFIX.md §5.1 判据族扫描 第 6 条): 本门 RX 侧旧判据**全是字节流级**
    //   (Σpopc / 内容 / tcrs / terr) ⇒ **字几何 (keep 形状) 缺陷结构性隐身**: /S/ 落 lane4
    //   的帧 (SOP 字只有 4 字节 + 整帧偏 4 字节) 在旧判据下与 lane0 帧不可分。
    // 本段**只增加**观察量与判据, 既有 80 条一字不动。
    //   字几何类 (SOP-1/2) 的反例 = 换回修复前 mac_rx_10g (P7B_MUT) ⇒ 必须变红 (已实测)。
    integer  rx_sop_n      = 0;      // 交付流里 tuser==1 的字数
    integer  rx_sop_bad_n  = 0;      // 其中 tkeep != 8'hFF 的字数 (违合同)
    integer  rx_tlast_n    = 0;      // 全部 tlast 字数 (含 TERM)
    integer  rx_term_n     = 0;      // TERM 字数 (tlast && tkeep==0)
    integer  rx_term_bad_n = 0;      // TERM 六元组不成立的字数
    reg      rx_term_dv    = 0;
    reg [63:0] rx_term_d = 0;
    reg [7:0]  rx_term_k = 0;
    reg        rx_term_l = 0, rx_term_u = 0, rx_term_c = 0, rx_term_e = 0;
    reg [7:0]  sopk_cur  = 8'hFF;    // 本帧首字的 tkeep (逐帧登记)
    // 逐帧期望队列: 只对**登记过**的帧逐字节比对 (未登记 => -1, 不参与任何判据)
    localparam EXQ = 64;
    integer  exp_n [0:EXQ-1];
    integer  exp_b [0:EXQ-1];
    integer  exp_wr = 0, exp_rd = 0;
    integer  got_f_bx   [0:255];     // 1=逐字节一致 0=不一致 -1=未登记 -2=长度不符
    integer  got_f_sopk [0:255];     // 该帧首字的 tkeep 实测值 (诊断用)
    integer  bx_badq = -1, bx_len = 0;   // 最近一次逐字节比对: 首个失配下标 / 长度
    reg [7:0] bx_obs = 0, bx_exp = 0;    // 失配处的实测值 / 期望值
    integer  got_f_bxq [0:255];          // 逐帧留档 (诊断用)
    integer  got_f_bxo [0:255];
    integer  got_f_bxe [0:255];

    task exp_reset; begin exp_wr = 0; exp_rd = 0; end endtask

    task exp_add;
        input integer n;
        input integer base;
        begin
            if (exp_wr < EXQ) begin exp_n[exp_wr] = n; exp_b[exp_wr] = base; exp_wr = exp_wr + 1; end
        end
    endtask

    // 交付字节 (got_buf, 存储序 = 每个 8 字节组内与帧字节流**相反**) vs PAT[base..base+n-1]
    //   ⚠️ 组内反转的基准是**该组的有效 lane 数 r**, 不是 8: 末(残)字只有 r 个有效 lane
    //      (tkeep 高位有效 ⇒ 先被写入的是 lane 8-r) ⇒ 用 `8w+7-idx` 只对满字成立。
    function rx_bytes_match;
        input integer n;
        input integer base;
        integer q2, wl, r, gbi;
        reg ok;
        begin
            ok = 1'b1; bx_badq = -1; bx_len = got_len;
            if (got_len !== n) ok = 1'b0;
            else for (q2 = 0; q2 < n; q2 = q2 + 1) begin
                wl  = q2 / 8;
                r   = ((n - wl*8) > 8) ? 8 : (n - wl*8);
                gbi = wl*8 + (r - 1 - (q2 % 8));
                // ⚠️ 期望下标**不能**先 mod 256: PAT[0..7] 是 8 个两两不同的特殊字节,
                //    而 PAT[i≥8] = i%256 ⇒ (base+gbi)%256 落进 0..7 时会与特殊字节撞车
                //    (实测 1514B 帧在 q=256 处假失配 obs=07 exp=EF)。PAT 有 2048 项,
                //    所有用例 n ≤ 1514、base ≤ 1 ⇒ 直接按下标取即可。
                if (got_buf[q2] !== PAT[(base + gbi) % 2048]) begin
                    ok = 1'b0;
                    if (bx_badq < 0) begin
                        bx_badq = q2; bx_obs = got_buf[q2]; bx_exp = PAT[(base + gbi) % 2048];
                    end
                end
            end
            rx_bytes_match = ok;
        end
    endfunction

    always @(posedge u_dut.dp_clk) begin
        if (u_dut.rx_tvalid && u_dut.rx_tready) begin
            if (!got_started) begin
                got_started     <= 1'b1;
                got_first_tdata <= u_dut.rx_tdata;
            end
            got_bytes <= got_bytes + popc8(u_dut.rx_tkeep);
            for (bi = 0; bi < 8; bi = bi + 1)
                if (u_dut.rx_tkeep[bi] && (got_len < 4096)) begin
                    got_buf[got_len] = u_dut.rx_tdata[bi*8 +: 8];
                    got_len = got_len + 1;
                end
            got_first_words <= got_first_words + 32'd1;
            // ---- P7B_CHAIN_COVERAGE: 字几何 / TERM 观察 (只增不改) ----
            if (u_dut.rx_tuser === 1'b1) begin
                rx_sop_n = rx_sop_n + 1;
                if (u_dut.rx_tkeep !== 8'hFF) rx_sop_bad_n = rx_sop_bad_n + 1;
                sopk_cur = u_dut.rx_tkeep;          // 阻塞: 与 TLAST 同拍 (单字帧) 也正确
            end
            if (u_dut.rx_tlast === 1'b1) begin
                rx_tlast_n = rx_tlast_n + 1;
                if (u_dut.rx_tkeep === 8'h00) begin
                    rx_term_n = rx_term_n + 1;
                    if (!((u_dut.rx_tdata === 64'd0)  && (u_dut.rx_tkeep === 8'h00) &&
                          (u_dut.rx_tlast === 1'b1)  && (u_dut.rx_tuser === 1'b0) &&
                          (u_dut.rx_tcrs  === 1'b0)  && (u_dut.rx_terr  === 1'b1)))
                        rx_term_bad_n = rx_term_bad_n + 1;
                    if (!rx_term_dv) begin
                        rx_term_dv = 1'b1;
                        rx_term_d = u_dut.rx_tdata; rx_term_k = u_dut.rx_tkeep;
                        rx_term_l = u_dut.rx_tlast; rx_term_u = u_dut.rx_tuser;
                        rx_term_c = u_dut.rx_tcrs;  rx_term_e = u_dut.rx_terr;
                    end
                end
            end
            if (u_dut.rx_tlast) begin
                got_frames <= got_frames + 1;
                got_last_len = got_len;
                if (got_f_cnt < 128) begin
                    got_f_len[got_f_cnt]  = got_len;
                    got_f_crs[got_f_cnt]  = u_dut.rx_tcrs;   // F2X11
                    got_f_terr[got_f_cnt] = u_dut.rx_terr;   // F2X11
                    // ---- P7B_CHAIN_COVERAGE: 逐帧首字掩码 + 逐字节比对结果 ----
                    got_f_sopk[got_f_cnt] = sopk_cur;
                    if (u_dut.rx_tkeep === 8'h00)
                        got_f_bx[got_f_cnt] = -1;            // TERM 字: 无内容可比
                    else if (exp_rd < exp_wr) begin
                        got_f_bx[got_f_cnt] = rx_bytes_match(exp_n[exp_rd], exp_b[exp_rd]) ? 1 : 0;
                        got_f_bxq[got_f_cnt] = bx_badq;
                        got_f_bxo[got_f_cnt] = bx_obs;
                        got_f_bxe[got_f_cnt] = bx_exp;
                        exp_rd = exp_rd + 1;
                    end else
                        got_f_bx[got_f_cnt] = -1;
                    got_f_cnt = got_f_cnt + 1;
                end
                got_len = 0;
                if (u_dut.rx_tkeep === 8'h00 && u_dut.rx_tcrs === 1'b0 && u_dut.rx_terr === 1'b1)
                    got_term_seen <= 1'b1;
            end
        end
    end

    // ======================= TX 方向捕获 (线上字) ==========================
    reg [63:0] wq_d [0:16383];
    reg [7:0]  wq_c [0:16383];
    integer    wq_wr = 0;
    integer    wq_sw = 0;

    always @(posedge u_dut.tx_mii_clk_1) begin
        wq_d[wq_wr] <= u_dut.u_pcs.txcap_d1;
        wq_c[wq_wr] <= u_dut.u_pcs.txcap_c1;
        if (wq_wr < 16383) wq_wr <= wq_wr + 1;
    end

    // 逐帧解码线上内容 (起帧 = lane0 的 /S/; 结帧 = 任一 lane 的 /T/)
    //   帧内容 = /S/ 那一拍之后所有数据 lane 的字节 (含 55x6+D5), 不含 /T/ 之后的 lane
    reg [7:0]  wf_b [0:31][0:2047];
    integer    wf_n [0:31];
    integer    wf_cnt = 0;
    reg        wf_act = 0;
    integer    wf_cur = 0, wf_len = 0;
    integer    wk, wl;
    // ---- F2-DIAG-PATCH ----
    integer    wf_start [0:31];
    integer    wf_stop  [0:31];
    integer    wf_dump_max = 104;
    reg [63:0] injw_d [0:255];
    reg [7:0]  injw_k [0:255];
    reg        injw_l [0:255];
    integer    injw_n = 0;
    integer    f2_tr_n = 0, f2_tr_lim = 0;
    reg        f2_tr_on = 0;
    integer    f2_ev_n = 0;
    reg [63:0] f2_ev_d [0:63];
    reg [7:0]  f2_ev_c [0:63];
    reg        f2_ev_w = 0;
    integer    f2_ev_start = 0;
    reg [7:0]  wd, wcc;
    reg        wf_ghost = 0;         // 出现过"不属于任何注入帧"的线上帧

    task decode_wire;
        input integer upto;
        begin
            wf_cnt = 0; wf_act = 0; wf_cur = 0; wf_len = 0;
            for (wk = 0; wk < upto; wk = wk + 1) begin
                for (wl = 0; wl < 8; wl = wl + 1) begin
                    wd  = wq_d[wk][wl*8 +: 8];
                    wcc = wq_c[wk][wl];
                    if (wcc === 1'b1 && wd === 8'hFB && wl == 0) begin
                        if (wf_cur < 32) begin
                            wf_act = 1; wf_len = 0; wf_start[wf_cur] = wk;
                        end
                    end else if (wcc === 1'b1 && wd === 8'hFD) begin
                        if (wf_act && wf_cur < 32) begin
                            wf_n[wf_cur] = wf_len;
                            wf_stop[wf_cur] = wk;
                            wf_cur = wf_cur + 1;
                        end
                        wf_act = 0;
                    end else if (wf_act && wl < 8 && wcc === 1'b0) begin
                        if (wf_len < 2048 && wf_cur < 32) begin
                            wf_b[wf_cur][wf_len] = wd;
                            wf_len = wf_len + 1;
                        end
                    end
                end
            end
            wf_cnt = wf_cur;
        end
    endtask

    // ---- F2-DIAG-PATCH: raw XGMII word dump (index, c, d, lanes) ----
    task dump_raw;
        input integer from;
        input integer to;
        integer dk, dto, dfo;
        begin
            // F2X11: 起点钳 >= 0 (idx-4 在前几个字上会是负数; 负下标会越界读)
            dfo = (from > 0) ? from : 0;
            dto = (to < 16383) ? to : 16383;
            $display("  [RAW] span [%0d,%0d) wq_wr=%0d", dfo, dto, wq_wr);
            for (dk = dfo; dk < dto; dk = dk + 1) begin
                $display("  [RAW %0d] c=%02h d=%016h l0=%02h l1=%02h l2=%02h l3=%02h l4=%02h l5=%02h l6=%02h l7=%02h",
                    dk, wq_c[dk], wq_d[dk],
                    wq_d[dk][7:0], wq_d[dk][15:8], wq_d[dk][23:16], wq_d[dk][31:24],
                    wq_d[dk][39:32], wq_d[dk][47:40], wq_d[dk][55:48], wq_d[dk][63:56]);
            end
        end
    endtask

    // ---- F2-DIAG-PATCH: decoded wire frames, byte-exact ----
    task dump_frames;
        integer df, dk, dn;
        begin
            $display("  [WFRAMES] wf_cnt=%0d", wf_cnt);
            for (df = 0; df < wf_cnt && df < 32; df = df + 1) begin
                dn = wf_n[df];
                $display("  [WFRAME %0d] words[%0d..%0d] bytes=%0d",
                         df, wf_start[df], wf_stop[df], dn);
                for (dk = 0; dk < dn && dk < wf_dump_max; dk = dk + 8)
                    $display("    [%03d] %02h %02h %02h %02h %02h %02h %02h %02h",
                        dk, wf_b[df][dk], wf_b[df][dk+1], wf_b[df][dk+2], wf_b[df][dk+3],
                        wf_b[df][dk+4], wf_b[df][dk+5], wf_b[df][dk+6], wf_b[df][dk+7]);
                if (dn > wf_dump_max)
                    $display("    ... +%0d bytes not printed", dn - wf_dump_max);
            end
        end
    endtask

    // ---- F2-DIAG-PATCH: words actually written into u_txcdc (dp side) ----
    task dump_injw;
        integer di;
        begin
            $display("  [INJW] n=%0d", injw_n);
            for (di = 0; di < injw_n && di < 256; di = di + 1)
                $display("  [INJW %0d] keep=%02h last=%b d=%016h l0=%02h l1=%02h l2=%02h l3=%02h l4=%02h l5=%02h l6=%02h l7=%02h",
                    di, injw_k[di], injw_l[di], injw_d[di],
                    injw_d[di][7:0], injw_d[di][15:8], injw_d[di][23:16], injw_d[di][31:24],
                    injw_d[di][39:32], injw_d[di][47:40], injw_d[di][55:48], injw_d[di][63:56]);
        end
    endtask

    always @(posedge u_dut.dp_clk)
        if (u_dut.txsrc_tvalid && u_dut.txsrc_tready) begin
            if (injw_n < 256) begin
                injw_d[injw_n] = u_dut.txsrc_tdata;
                injw_k[injw_n] = u_dut.txsrc_tkeep;
                injw_l[injw_n] = u_dut.txsrc_tlast;
                injw_n = injw_n + 1;
            end
        end

    // ---- F2-DIAG-PATCH: per-cycle mac_tx_10g trace (windowed) ----
    always @(posedge u_dut.tx_mii_clk_1)
        if ((f2_tr_on == 1'b1) && (f2_tr_n < f2_tr_lim)) begin
            $display("  [TR %0d] st=%0d cwl=%0d cwlast=%b keep=%02h plen=%0d femp=%b frd=%b ftl=%b fcnt=%0d txd=%016h txc=%02h | abrt=%0d flw=%0d fldn=%0d frm=%0d txw=%0d sht=%0d clen=%0d | cdc_e=%b mtv=%b tsv=%b tsl=%b tsk=%02h tst=%b",
                f2_tr_n, u_dut.u_mac_tx.state, u_dut.u_mac_tx.cw_len,
                u_dut.u_mac_tx.cw_last, u_dut.u_mac_tx.cw_keep, u_dut.u_mac_tx.plen,
                u_dut.u_mac_tx.fempty, u_dut.u_mac_tx.frd, u_dut.u_mac_tx.flush_tl,
                u_dut.u_mac_tx.flush_cnt, u_dut.u_mac_tx.tx_d, u_dut.u_mac_tx.tx_c,
                u_dut.u_mac_tx.stat_abort, u_dut.u_mac_tx.stat_flush_words,
                u_dut.u_mac_tx.stat_flush_done, u_dut.u_mac_tx.stat_frames,
                u_dut.u_mac_tx.stat_tx_words, u_dut.u_mac_tx.stat_tx_short,
                u_dut.u_mac_tx.m_clen,
                u_dut.tx_fifo_empty, u_dut.m_tx_tvalid,
                u_dut.txsrc_tvalid, u_dut.txsrc_tlast, u_dut.txsrc_tkeep,
                u_dut.txsrc_tdata);
            f2_tr_n = f2_tr_n + 1;
        end

    // ================== F2X-PATCH: F-2 attribution experiments ==================
    localparam F2X_STRIDE = 64;
    reg [7:0]  f2x_c [0:15*F2X_STRIDE-1];   // injected frame content bytes (contract order)
    integer    f2x_clen [0:15];
    integer    f2x_cn = 0;
    integer    wq_base = 0;
    reg [7:0]  f2x_wire [0:31][0:255];      // decoded wire-frame content bytes
    integer    f2x_wlen [0:31];
    integer    f2x_wkind [0:31];
    integer    f2x_wn = 0;
    integer    f2x_cls_n = 0;
    integer    f2x_wstart [0:31];
    integer    f2x_wstop  [0:31];
    reg [31:0] f2x_abort0 = 0, f2x_flw0 = 0, f2x_fld0 = 0;

    // 内容图案 (与 PAT 相同的前 60 字节); 每帧独立登记, 支持多帧期望
    task f2x_add60;
        input integer base;
        integer i;
        begin
            for (i = 0; i < 60; i = i + 1) f2x_c[f2x_cn*F2X_STRIDE + i] = PAT[(base+i) % 256];
            f2x_clen[f2x_cn] = 60;
            f2x_cn = f2x_cn + 1;
        end
    endtask

    // 单拍确定性注入: force 在 negedge 落地/撤销 => 恰好跨过 1 个 posedge (坑 17)
    task f2x_push;
        input [63:0] d;
        input [7:0]  k;
        input        l;
        begin
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tdata = d;
            force u_dut.txsrc_tkeep = k;
            force u_dut.txsrc_tlast = l;
            force u_dut.txsrc_tvalid = 1'b1;
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tvalid = 1'b0;
        end
    endtask

    // F2X9-PATCH: 60 字节线上内容 (18 数据 + 42 pad) 的帧, FCS 两种覆盖面
    task f2x_build_pad;
        input        dut_fcs;      // 1 = FCS 只覆盖 18 个数据字节 (mac_tx_10g 实测)
        integer i, m;
        reg [31:0] fc;
        begin
            fc = 32'hFFFFFFFF;
            if (dut_fcs) begin
                for (i = 0; i < 18; i = i + 1) fc = crc32_byte(fc, PAT[i]);
            end else begin
                for (i = 0; i < 60; i = i + 1)
                    fc = crc32_byte(fc, (i < 18) ? PAT[i] : 8'h00);
            end
            fc = ~fc;
            wb[0] = 8'hFB; wc[0] = 1;
            for (i = 0; i < 6; i = i + 1) begin wb[1+i] = 8'h55; wc[1+i] = 0; end
            wb[7] = 8'hD5; wc[7] = 0;
            m = 8;
            for (i = 0; i < 60; i = i + 1) begin
                wb[m] = (i < 18) ? PAT[i] : 8'h00; wc[m] = 0; m = m + 1;
            end
            wb[m] = fc[7:0];   wc[m] = 0; m = m + 1;
            wb[m] = fc[15:8];  wc[m] = 0; m = m + 1;
            wb[m] = fc[23:16]; wc[m] = 0; m = m + 1;
            wb[m] = fc[31:24]; wc[m] = 0; m = m + 1;
            wb[m] = 8'hFD; wc[m] = 1; m = m + 1;
            xq_pack_words(m);
            $display("  [F2X X5d] built frame: 18 data + 42 pad, FCS=%s (%02h %02h %02h %02h)",
                     dut_fcs ? "over 18 data bytes (DUT style)" : "over 60 padded bytes (standard)",
                     fc[7:0], fc[15:8], fc[23:16], fc[31:24]);
        end
    endtask

    // F2X6-PATCH: 68 字节内容帧 (PAT[0..67] = TB build_frame(68) 的同一内容, 无 pad)
    task f2x_add68;
        integer i;
        begin
            for (i = 0; i < 68; i = i + 1) f2x_c[f2x_cn*F2X_STRIDE + i] = PAT[i];
            f2x_clen[f2x_cn] = 68;
            f2x_cn = f2x_cn + 1;
        end
    endtask

    task f2x_stream68;
        input integer f;
        integer i;
        reg [63:0] d;
        begin
            for (i = 0; i < 8; i = i + 1) begin
                @(negedge u_dut.dp_clk);
                d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                     f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                     f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                     f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                force u_dut.txsrc_tdata = d;
                force u_dut.txsrc_tkeep = 8'hFF;
                force u_dut.txsrc_tlast = 1'b0;
                force u_dut.txsrc_tvalid = 1'b1;
            end
            @(negedge u_dut.dp_clk);
            d = {f2x_c[f*F2X_STRIDE+64], f2x_c[f*F2X_STRIDE+65],
                 f2x_c[f*F2X_STRIDE+66], f2x_c[f*F2X_STRIDE+67], 32'd0};
            force u_dut.txsrc_tdata = d;
            force u_dut.txsrc_tkeep = 8'hF0;
            force u_dut.txsrc_tlast = 1'b1;
            force u_dut.txsrc_tvalid = 1'b1;
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tvalid = 1'b0;
        end
    endtask

    // F2X5-PATCH: 20 字节内容帧 (2 满字 + 1 个 tkeep=F0 尾字) —— 会被 MAC 补 pad 到 60
    task f2x_add20;
        input integer base;
        integer i;
        begin
            for (i = 0; i < 20; i = i + 1) f2x_c[f2x_cn*F2X_STRIDE + i] = PAT[(base+i) % 256];
            f2x_clen[f2x_cn] = 20;
            f2x_cn = f2x_cn + 1;
        end
    endtask

    task f2x_stream20;
        input integer f;
        integer i;
        reg [63:0] d;
        begin
            for (i = 0; i < 2; i = i + 1) begin
                @(negedge u_dut.dp_clk);
                d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                     f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                     f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                     f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                force u_dut.txsrc_tdata = d;
                force u_dut.txsrc_tkeep = 8'hFF;
                force u_dut.txsrc_tlast = 1'b0;
                force u_dut.txsrc_tvalid = 1'b1;
            end
            @(negedge u_dut.dp_clk);
            d = {f2x_c[f*F2X_STRIDE+16], f2x_c[f*F2X_STRIDE+17],
                 f2x_c[f*F2X_STRIDE+18], f2x_c[f*F2X_STRIDE+19], 32'd0};
            force u_dut.txsrc_tdata = d;
            force u_dut.txsrc_tkeep = 8'hF0;
            force u_dut.txsrc_tlast = 1'b1;
            force u_dut.txsrc_tvalid = 1'b1;
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tvalid = 1'b0;
        end
    endtask

    // F2X11: 任意长度内容帧的登记 + 连续注入 (1 字/拍, = DP 侧合同)
    //   n 字节 = (n/8) 个满字 + 1 个 keep 高位有效的尾字
    task f2x_addn;
        input integer n;
        input integer base;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) f2x_c[f2x_cn*F2X_STRIDE + i] = PAT[(base+i) % 256];
            f2x_clen[f2x_cn] = n;
            f2x_cn = f2x_cn + 1;
        end
    endtask

    task f2x_streamn;
        input integer f;
        input integer n;
        integer i, k, nw, rem;
        reg [63:0] d;
        begin
            nw  = n / 8;          // 满字数
            rem = n % 8;          // 尾字有效字节数 (0 => 最后一个满字带 TLAST)
            for (i = 0; i < nw; i = i + 1) begin
                @(negedge u_dut.dp_clk);
                d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                     f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                     f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                     f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                force u_dut.txsrc_tdata = d;
                force u_dut.txsrc_tkeep = 8'hFF;
                force u_dut.txsrc_tlast = (rem == 0 && i == nw-1) ? 1'b1 : 1'b0;
                force u_dut.txsrc_tvalid = 1'b1;
            end
            if (rem != 0) begin
                @(negedge u_dut.dp_clk);
                d = 64'd0;
                for (k = 0; k < rem; k = k + 1)
                    d[63 - 8*k -: 8] = f2x_c[f*F2X_STRIDE + nw*8 + k];
                force u_dut.txsrc_tdata = d;
                force u_dut.txsrc_tkeep = 8'hFF << (4'd8 - rem[3:0]);
                force u_dut.txsrc_tlast = 1'b1;
                force u_dut.txsrc_tvalid = 1'b1;
            end
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tvalid = 1'b0;
        end
    endtask

    // 把捕获窗口 [from,to) 的线上字回放进 RX 注入队列 (TB 侧环回)
    task f2x_loop;
        input integer from;
        input integer to;
        integer li;
        begin
            for (li = from; li < to; li = li + 1) begin
                xq_d[xq_wr] = wq_d[li];
                xq_c[xq_wr] = wq_c[li];
                xq_wr = xq_wr + 1;
            end
            $display("  [F2X loop] replayed %0d wire words into the RX injector (xq_wr=%0d)",
                     to - from, xq_wr);
        end
    endtask

    // F2X3-PATCH: 连续注入 (1 字/拍, = 真实 DP 侧合同) —— 全部 force 落在 negedge,
    //   于是每个 posedge 采到的都是稳定字 => 恰好 1 写/拍, 无 50% 占空比气泡
    task f2x_stream;
        input integer f;
        integer i;
        reg [63:0] d;
        begin
            for (i = 0; i < 8; i = i + 1) begin
                @(negedge u_dut.dp_clk);
                if (i < 7) begin
                    d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                         f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                         f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                         f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                    force u_dut.txsrc_tdata = d;
                    force u_dut.txsrc_tkeep = 8'hFF;
                    force u_dut.txsrc_tlast = 1'b0;
                end else begin
                    d = {f2x_c[f*F2X_STRIDE+56], f2x_c[f*F2X_STRIDE+57],
                         f2x_c[f*F2X_STRIDE+58], f2x_c[f*F2X_STRIDE+59], 32'd0};
                    force u_dut.txsrc_tdata = d;
                    force u_dut.txsrc_tkeep = 8'hF0;
                    force u_dut.txsrc_tlast = 1'b1;
                end
                force u_dut.txsrc_tvalid = 1'b1;
            end
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tvalid = 1'b0;
        end
    endtask

    // F2X2-PATCH: 带间隔的注入 (测 CDC 可见性/速率效应)
    task f2x_push_g;
        input [63:0] d;
        input [7:0]  k;
        input        l;
        input integer gap;
        integer gi;
        begin
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tdata = d;
            force u_dut.txsrc_tkeep = k;
            force u_dut.txsrc_tlast = l;
            force u_dut.txsrc_tvalid = 1'b1;
            @(negedge u_dut.dp_clk);
            force u_dut.txsrc_tvalid = 1'b0;
            for (gi = 0; gi < gap; gi = gi + 1) @(negedge u_dut.dp_clk);
        end
    endtask

    task f2x_push_frame_g;
        input integer f;
        input integer gap;
        integer i;
        reg [63:0] d;
        begin
            for (i = 0; i < 7; i = i + 1) begin
                d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                     f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                     f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                     f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                f2x_push_g(d, 8'hFF, 1'b0, gap);
            end
            d = {f2x_c[f*F2X_STRIDE+56], f2x_c[f*F2X_STRIDE+57],
                 f2x_c[f*F2X_STRIDE+58], f2x_c[f*F2X_STRIDE+59], 32'd0};
            f2x_push_g(d, 8'hF0, 1'b1, gap);
        end
    endtask

    // 把登记的第 f 帧按 7 满字 + 1 个 tkeep=F0 尾字推入 (总 60 内容字节, 无 pad)
    task f2x_push_frame;
        input integer f;
        integer i;
        reg [63:0] d;
        begin
            for (i = 0; i < 7; i = i + 1) begin
                d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                     f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                     f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                     f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                f2x_push(d, 8'hFF, 1'b0);
            end
            d = {f2x_c[f*F2X_STRIDE+56], f2x_c[f*F2X_STRIDE+57],
                 f2x_c[f*F2X_STRIDE+58], f2x_c[f*F2X_STRIDE+59], 32'd0};
            f2x_push(d, 8'hF0, 1'b1);
        end
    endtask

    // 推入第 f 帧的头 nw 个字 (不结束该帧)
    task f2x_push_head;
        input integer f;
        input integer nw;
        integer i;
        reg [63:0] d;
        begin
            for (i = 0; i < nw; i = i + 1) begin
                d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                     f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                     f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                     f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                f2x_push(d, 8'hFF, 1'b0);
            end
        end
    endtask

    // 推入第 f 帧的第 w0..w1 个字, 最后一个字带 TLAST (残字段)
    task f2x_push_tail;
        input integer f;
        input integer w0;
        input integer w1;
        integer i;
        reg [63:0] d;
        begin
            for (i = w0; i <= w1; i = i + 1) begin
                d = {f2x_c[f*F2X_STRIDE+i*8+0], f2x_c[f*F2X_STRIDE+i*8+1],
                     f2x_c[f*F2X_STRIDE+i*8+2], f2x_c[f*F2X_STRIDE+i*8+3],
                     f2x_c[f*F2X_STRIDE+i*8+4], f2x_c[f*F2X_STRIDE+i*8+5],
                     f2x_c[f*F2X_STRIDE+i*8+6], f2x_c[f*F2X_STRIDE+i*8+7]};
                if (i == w1) f2x_push(d, 8'hF0, 1'b1);   // 末字: 60B 内容 = 4 有效字节
                else         f2x_push(d, 8'hFF, 1'b0);
            end
        end
    endtask

    // 在 [wq_base, wq_wr) 上解码线上帧并逐帧分类 (kind 0=幽灵/1=残缺前缀/2=完整)
    task f2x_scan;
        integer q, l2, dn, f, k2, wl_exp;
        reg [7:0] byt, bexp;
        reg       in_f, done, fcs_ok;
        reg [31:0] fc_tb;
        integer   st;
        begin
            f2x_wn = 0; in_f = 1'b0; st = 0;
            for (q = wq_base; q < wq_wr; q = q + 1) begin
                for (l2 = 0; l2 < 8; l2 = l2 + 1) begin
                    byt = wq_d[q][l2*8 +: 8];
                    if (in_f !== 1'b1) begin
                        if (wq_c[q][l2] === 1'b1 && byt === 8'hFB && l2 == 0) begin
                            if (f2x_wn < 32) begin
                                in_f = 1'b1; st = 0; f2x_wstart[f2x_wn] = q;
                            end
                        end
                    end else if (wq_c[q][l2] === 1'b1) begin
                        if (byt === 8'hFD) begin
                            if (f2x_wn < 32) begin
                                f2x_wlen[f2x_wn] = (st < 256) ? st : 256;
                                f2x_wstop[f2x_wn] = q;
                                f2x_wn = f2x_wn + 1;
                            end
                            in_f = 1'b0;
                        end
                    end else begin
                        if (st < 256 && f2x_wn < 32) begin
                            f2x_wire[f2x_wn][st] = byt;
                            st = st + 1;
                        end
                    end
                end
            end
            // ---- 逐帧分类 (线上帧的前 7 字节 = 前导 55x6+D5, 内容从下标 7 起) ----
            // ⭐ F2X11 FIX (2026-09-30, 假阳性陷阱): 判据一律按**线上实际解出的长度/字节**
            //   判定; 注入长度只用来定义"期望的线上形态" = 内容 ++ 全 0 pad 补齐到 MIN_CLEN(60)。
            //   旧版直接拿**注入长度**硬比 (`wlen == dn+11` / `wlen-7 <= dn`) ⇒ 凡被 MAC 补过
            //   pad 的帧 (线上内容 60B > 注入 dn) 两条都不成立 ⇒ kind=0 "幽灵" **误标**
            //   (实测: X5a 的 20B 内容帧在自家 RX 判 FCS 正确的同一时刻被标成幽灵)。
            //   kind: 0=幽灵(内容+pad 都对不上 ⇒ FAIL) / 1=残缺前缀 / 2=完整且 FCS ==
            //         TB 独立复算 (覆盖线上全部内容字节, 含 pad) / 3=完整但 FCS 不符
            for (f = 0; f < f2x_wn && f < 32; f = f + 1) begin
                f2x_wkind[f] = 0;
                for (k2 = 0; k2 < f2x_cn; k2 = k2 + 1) begin
                    dn = f2x_clen[k2];
                    wl_exp = (dn >= 60) ? dn : 60;      // 期望线上内容字节数 (含 pad)
                    // (a) 完整帧: 线上内容 == 注入内容 ++ 全 0 pad, 且 FCS == TB crc32(线上内容)
                    if (f2x_wlen[f] == (wl_exp + 7 + 4)) begin
                        done = 1'b1;
                        for (q = 0; q < wl_exp; q = q + 1) begin
                            bexp = (q < dn) ? f2x_c[k2*F2X_STRIDE + q] : 8'h00;
                            if (f2x_wire[f][7+q] !== bexp) done = 1'b0;
                        end
                        if (done === 1'b1) begin
                            fc_tb = 32'hFFFFFFFF;
                            for (q = 0; q < wl_exp; q = q + 1)
                                fc_tb = crc32_byte(fc_tb, f2x_wire[f][7+q]);
                            fc_tb = ~fc_tb;                       // 线上 FCS 序: [7:0] 先
                            fcs_ok = 1'b1;
                            if (f2x_wire[f][7+wl_exp+0] !== fc_tb[7:0])   fcs_ok = 1'b0;
                            if (f2x_wire[f][7+wl_exp+1] !== fc_tb[15:8])  fcs_ok = 1'b0;
                            if (f2x_wire[f][7+wl_exp+2] !== fc_tb[23:16]) fcs_ok = 1'b0;
                            if (f2x_wire[f][7+wl_exp+3] !== fc_tb[31:24]) fcs_ok = 1'b0;
                            if (fcs_ok === 1'b1)                    f2x_wkind[f] = 2;
                            else if (f2x_wkind[f] == 0)             f2x_wkind[f] = 3;
                        end
                    end
                    // (b) 残缺前缀: 线上内容更短, 且逐字节 == (内容 ++ pad) 流的前缀
                    if ((f2x_wlen[f] >= 7) && ((f2x_wlen[f] - 7) < wl_exp)) begin
                        done = 1'b1;
                        for (q = 0; q < (f2x_wlen[f] - 7); q = q + 1) begin
                            bexp = (q < dn) ? f2x_c[k2*F2X_STRIDE + q] : 8'h00;
                            if (f2x_wire[f][7+q] !== bexp) done = 1'b0;
                        end
                        if (done === 1'b1 && f2x_wkind[f] == 0) f2x_wkind[f] = 1;
                    end
                end
            end
        end
    endtask

    task f2x_show;
        input [255:0] tag;
        integer f, q;
        begin
            $display("  [F2X %0s] wire frames=%0d (window [%0d,%0d) inj=%0d)",
                     tag, f2x_wn, wq_base, wq_wr, f2x_cn);
            $display("  [F2X %0s] injw_n=%0d (dp-side writes) | d_abort=%0d d_flush_words=%0d d_flush_done=%0d d_frames=%0d d_tx_short=%0d | cdc_occ_w=%0d cdc_e=%b m_tx_tvalid=%b",
                     tag, injw_n,
                     u_dut.u_mac_tx.stat_abort - f2x_abort0,
                     u_dut.u_mac_tx.stat_flush_words - f2x_flw0,
                     u_dut.u_mac_tx.stat_flush_done - f2x_fld0,
                     u_dut.u_mac_tx.stat_frames,
                     u_dut.u_mac_tx.stat_tx_short,
                     u_dut.txcdc_occ_w, u_dut.tx_fifo_empty, u_dut.m_tx_tvalid);
            dump_injw;
            for (f = 0; f < f2x_wn && f < 32; f = f + 1) begin
                $display("  [F2X %0s] frame %0d len=%0d kind=%0d (0=ghost 1=runt 2=complete+padFCSok 3=content ok, FCS bad)",
                         tag, f, f2x_wlen[f], f2x_wkind[f]);
                for (q = 0; q < f2x_wlen[f] && q < 80; q = q + 8)
                    $display("      [%03d] %02h %02h %02h %02h %02h %02h %02h %02h", q,
                        f2x_wire[f][q], f2x_wire[f][q+1], f2x_wire[f][q+2], f2x_wire[f][q+3],
                        f2x_wire[f][q+4], f2x_wire[f][q+5], f2x_wire[f][q+6], f2x_wire[f][q+7]);
            end
        end
    endtask

    task f2x_begin;
        begin
            repeat (120) @(posedge u_dut.tx_mii_clk_1);   // 排空
            f2x_cn = 0;
            injw_n = 0;
            f2_tr_on = 1'b0;
            wq_base = wq_wr;
            f2x_abort0 = u_dut.u_mac_tx.stat_abort;
            f2x_flw0   = u_dut.u_mac_tx.stat_flush_words;
            f2x_fld0   = u_dut.u_mac_tx.stat_flush_done;
        end
    endtask

    task f2x_settle;
        begin
            repeat (250) @(posedge u_dut.tx_mii_clk_1);
        end
    endtask

    // 等到 stat_abort 递增 (= DUT 已经确认中止, 残字尚未注入) —— 消除激励竞争
    task f2x_wait_abort;
        integer n;
        begin
            n = 0;
            while ((u_dut.u_mac_tx.stat_abort === f2x_abort0) && (n < 2000)) begin
                n = n + 1;
                @(posedge u_dut.tx_mii_clk_1);
            end
            $display("  [F2X] abort observed after %0d tx cycles (abort %0d -> %0d)", n,
                     f2x_abort0, u_dut.u_mac_tx.stat_abort);
        end
    endtask

    task diag;
        input [127:0] tag;
        begin
            $display("  [DIAG] %0s xq_wr=%0d xq_rd=%0d | rxw=%0d rxf=%0d rxs=%0d crc=%0d drop=%0d df=%0d dp=%0d orph=%0d | rxv=%b rdy=%b | rxcocc=%0d | txf=%0d txs=%0d txsv=%b mtxv=%b txocc=%0d wq=%0d",
                tag, xq_wr, xq_rd,
                u_dut.mrx_stat_rx_words, u_dut.rx_stat_frames, u_dut.mrx_dbg_state,
                u_dut.rx_stat_crc_err, u_dut.rx_stat_drop,
                u_dut.rx_stat_drop_full, u_dut.rx_stat_drop_partial,
                u_dut.rx_stat_orphan_bytes, u_dut.rxsrc_tvalid, u_dut.rx_tready,
                u_dut.rxcdc_occ_w,
                u_dut.mac_tx_frames, u_dut.mtx_dbg_state,
                u_dut.txsrc_tvalid, u_dut.m_tx_tvalid, u_dut.txcdc_occ_w, wq_wr);
        end
    endtask

    // ======================= 主流程 ========================================
    integer  i, j, k, m, n, nob_n, xa_f;
    reg [31:0] v, c0, c1;
    reg [255:0] gname;              // P7B_CHAIN_COVERAGE: 带序号的判据名
    integer  gg0, gg1;
    integer  tl_obs [0:7];          // lane4 sweep 每帧 /T/ 落位 (从注入的 XGMII 字里扫)
    integer  tl_dut [0:7];          // 同上, DUT 自报值 (诊断; 见 [DEFECT-REG #2])
    integer  tlane_msk = 0;
    integer  xq_before, kk2;
    reg [63:0] txw [0:511];
    integer    txwn;
    reg        allgood;

    initial begin
        init_pat();
        $display("==== tb_p7b_chain: P7b REAL-wrapper full-chain gate ====");

        // -------- 第 0 组: CRC 自检 (期望来源 = 标准向量 / 工程铁律) --------
        v = 32'hFFFFFFFF;
        v = crc32_byte(v,8'h31); v = crc32_byte(v,8'h32); v = crc32_byte(v,8'h33);
        v = crc32_byte(v,8'h34); v = crc32_byte(v,8'h35); v = crc32_byte(v,8'h36);
        v = crc32_byte(v,8'h37); v = crc32_byte(v,8'h38); v = crc32_byte(v,8'h39);
        // ⚠️ crc32_byte 给的是**内部状态** (无终值取反); 标准校验向量的值
        //    0xCBF43926 是**取反后**的 (zlib.crc32) ⇒ 必须 ~v 再比。
        //    这与工程约定一致: 线上 FCS = ~internal, 残留 = 0xDEBB20E3。
        chk("0a crc32_std(123456789)=CBF43926", (~v) === 32'hCBF43926,
            "802.3 check vector (zlib=~internal)");
        n = 16;
        v = 32'hFFFFFFFF;
        for (i = 0; i < n; i = i + 1) v = crc32_byte(v, PAT[i]);
        m = ~v;                                   // 线上 FCS = ~internal, LSB first
        v = crc32_byte(v, m[7:0]);   v = crc32_byte(v, m[15:8]);
        v = crc32_byte(v, m[23:16]); v = crc32_byte(v, m[31:24]);
        chk("0b residue == DEBB20E3", v === 32'hDEBB20E3,
            "project rule: 0xDEBB20E3, not 0xC704DD7B");

        reset_n = 0;
        repeat (40) @(posedge u_dut.dp_clk);
        reset_n = 1;
        repeat (2000) @(posedge u_dut.dp_clk);
        chk("0c stub link released",
            u_dut.pcs_user_rx_reset_1 === 1'b0, "stim precond");
        chk("0d SFP2 TX_DIS low",
            sfp2_tx_dis === 1'b0, "P7B_GATE1 5.8");

        // -------- 第 1 组: 字节序镜像 (用 /S/ 的 lane 位置反推) ------------
        got_started = 0; got_bytes = 0; got_frames = 0; got_len = 0; got_f_cnt = 0;
        build_frame(64, 1'b0, -1);
        repeat (600) @(posedge u_dut.dp_clk);
        chk("1a RX delivered >=1 frame", (got_frames >= 32'd1) === 1'b1,
            "stim precond (nonvacuous)");
        chk("1b RX first byte==content[0]",
            (got_first_tdata[63:56] === PAT[0]) === 1'b1,
            "injected bytes + GATE1 C.2");
        chk("1c RX 1st byte!=lane7 byte",
            (got_first_tdata[63:56] !== PAT[7]) === 1'b1,
            "neg: 8 distinct bytes");
        diag("after-group1");

        // -------- 第 2 组: 帧几何 ------------------------------------------
        // ⭐ P7B_CHAIN_COVERAGE 缺口 3: 旧判据在这组只查**字节计数** (Σpopc) ⇒ "内容被改
        //    一个字节 / pad 段错" 在这里完全隐身。现补**逐字节**判据 (首/中/末全覆盖)。
        //    反例 = 故意错位 1 字节登记期望 (2j 自检) ⇒ 同一比较器必须报不一致 (已实测)。
        exp_reset;
        got_bytes = 0; got_frames = 0; got_len = 0; got_f_cnt = 0;
        build_frame(60, 1'b0, -1);
        exp_add(60, 0);
        repeat (250) @(posedge u_dut.dp_clk);
        m = got_bytes;
        build_frame(1514, 1'b0, -1);
        exp_add(1514, 0);
        repeat (700) @(posedge u_dut.dp_clk);
        n = got_bytes - m;
        chk("2a min frame -> 60 bytes", m === 32'd60,
            "802.3 Cl.4.4 / injected");
        chk("2b max frame -> 1514 bytes", n === 32'd1514,
            "802.3 Cl.4.4 / injected");
        chk("2c Sum popc conservation",
            (got_bytes === (32'd60 + 32'd1514)) === 1'b1,
            "contract: bytes==injected");
        begin : g2diag
            integer dq;
            $display("  [2 DIAG] cnt=%0d exp(wr=%0d rd=%0d n0=%0d b0=%0d) | f0 len=%0d bx=%0d sopk=%02h badq=%0d obs=%02h exp=%02h | f1 len=%0d bx=%0d",
                     got_f_cnt, exp_wr, exp_rd, exp_n[0], exp_b[0],
                     got_f_len[0], got_f_bx[0], got_f_sopk[0],
                     got_f_bxq[0], got_f_bxo[0], got_f_bxe[0],
                     got_f_len[1], got_f_bx[1]);
            $display("  [2 DIAG] got_buf[0..15] = %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h",
                     got_buf[0],got_buf[1],got_buf[2],got_buf[3],got_buf[4],got_buf[5],
                     got_buf[6],got_buf[7],got_buf[8],got_buf[9],got_buf[10],got_buf[11],
                     got_buf[12],got_buf[13],got_buf[14],got_buf[15]);
            $display("  [2 DIAG] PAT[0..15]     = %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h",
                     PAT[0],PAT[1],PAT[2],PAT[3],PAT[4],PAT[5],PAT[6],PAT[7],
                     PAT[8],PAT[9],PAT[10],PAT[11],PAT[12],PAT[13],PAT[14],PAT[15]);
            $display("  [2 DIAG] f1 bn=%0d badq=%0d obs=%02h exp=%02h | exp1 n=%0d b=%0d",
                     bx_len, got_f_bxq[1], got_f_bxo[1], got_f_bxe[1], exp_n[1], exp_b[1]);
            $display("  [2 DIAG] f1 head got_buf[0..7]=%02h %02h %02h %02h %02h %02h %02h %02h | tail got_buf[1506..1513]=%02h %02h %02h %02h %02h %02h %02h %02h",
                     got_buf[0],got_buf[1],got_buf[2],got_buf[3],got_buf[4],got_buf[5],got_buf[6],got_buf[7],
                     got_buf[1506],got_buf[1507],got_buf[1508],got_buf[1509],got_buf[1510],got_buf[1511],got_buf[1512],got_buf[1513]);
            for (dq = 0; dq < 1514 && dq < 32; dq = dq + 8)
                $display("      f1 got[%03d] %02h %02h %02h %02h %02h %02h %02h %02h", dq,
                    got_buf[dq],got_buf[dq+1],got_buf[dq+2],got_buf[dq+3],
                    got_buf[dq+4],got_buf[dq+5],got_buf[dq+6],got_buf[dq+7]);
        end
        chk("2f 60B frame byte-exact (first/mid/last)",
            (got_f_cnt === 2) && (got_f_bx[0] === 1) && (got_f_sopk[0] === 8'hFF),
            "injected byte array vs delivered buffer");
        chk("2g 1514B frame byte-exact (first/mid/last)",
            (got_f_cnt === 2) && (got_f_bx[1] === 1),
            "injected byte array vs delivered buffer");
        got_bytes = 0; got_frames = 0; got_len = 0; got_f_cnt = 0;
        build_frame(63, 1'b0, -1);
        exp_add(63, 0);
        repeat (250) @(posedge u_dut.dp_clk);
        build_frame(65, 1'b0, -1);
        exp_add(65, 0);
        repeat (350) @(posedge u_dut.dp_clk);
        chk("2d 63+65 -> 128 bytes",
            got_bytes === 32'd128, "derived: 63+65");
        chk("2e frames==2 no merge", got_frames === 32'd2,
            "contract: 1 TLAST/frame");
        chk("2h 63B frame byte-exact", (got_f_cnt === 2) && (got_f_bx[0] === 1),
            "injected byte array vs delivered buffer");
        chk("2i 65B frame byte-exact", (got_f_cnt === 2) && (got_f_bx[1] === 1),
            "injected byte array vs delivered buffer");
        // ---- 2j: 比较器自检 (反例内建): 同一帧内容, 期望**故意错位 1 字节** ⇒
        //      got_f_bx 必须 != 1。没有这条, 2f..2i 的"逐字节"可能是恒真的哑判据。
        got_bytes = 0; got_frames = 0; got_len = 0; got_f_cnt = 0;
        build_frame(60, 1'b0, -1);
        exp_add(60, 1);                    // 期望 = PAT[1..60] (真交付是 PAT[0..59])
        repeat (350) @(posedge u_dut.dp_clk);
        chk("2j byte-comparator self-test (1-byte off => mismatch)",
            (got_f_cnt === 1) && (got_f_bx[0] === 0),
            "negative control: comparator has teeth");

        // -------- 第 3 组: FCS / /E/ ---------------------------------------
        c0 = u_dut.rx_stat_crc_err;
        got_bytes = 0; got_frames = 0; got_len = 0; got_f_cnt = 0;
        build_frame(64, 1'b0, -1);                       // 好 FCS
        repeat (350) @(posedge u_dut.dp_clk);
        chk("3a good FCS crc_err same",
            (u_dut.rx_stat_crc_err === c0) === 1'b1,
            "inj FCS == TB CRC32");
        chk("3b good FCS -> 64 bytes", got_bytes === 32'd64,
            "contract: tcrs=1");
        build_frame(64, 1'b1, -1);                       // 坏 FCS
        repeat (350) @(posedge u_dut.dp_clk);
        chk("3c bad FCS crc_err +1",
            (u_dut.rx_stat_crc_err === (c0 + 32'd1)) === 1'b1,
            "inj: FCS = 0x00000000");
        chk("3d bad FCS still delivered",
            got_bytes === 32'd128, "contract: crc is a flag");
        c0 = u_dut.mrx_stat_rx_er_words;
        build_frame(64, 1'b0, 10);                       // 内容第 10 字节后插 /E/
        repeat (350) @(posedge u_dut.dp_clk);
        chk("3e /E/ -> rx_er_words +",
            (u_dut.mrx_stat_rx_er_words > c0) === 1'b1,
            "inj /E/ at content byte 10");
        chk("3f stat_fifo_ovf==0",
            u_dut.rx_stat_fifo_ovf === 32'd0, "mac_rx_10g: structural 0");

        // -------- 第 4 组: 背靠背 (零帧间隙) -------------------------------
        got_bytes = 0; got_frames = 0; got_len = 0; got_f_cnt = 0;
        build_frame(60, 1'b0, -1);
        build_frame(60, 1'b0, -1);
        build_frame(60, 1'b0, -1);
        repeat (700) @(posedge u_dut.dp_clk);
        chk("4a b2b x3 -> 3 frames",
            got_frames === 32'd3, "derived: 3 frames, no IFG");
        chk("4b b2b x3 -> 180 bytes", got_bytes === 32'd180,
            "derived: 3x60");

        // -------- 第 5 组: F4 (空间门 + TERM 字 + 恢复) --------------------
        got_bytes = 0; got_frames = 0; got_len = 0; got_f_cnt = 0;
        got_term_seen = 0; got_started = 0;
        c0 = u_dut.rx_stat_drop_full + u_dut.rx_stat_drop_partial;
        force u_dut.rx_tready = 1'b0;                    // 下游停摆 (DP 侧读口)
        for (j = 0; j < 40; j = j + 1) build_frame(1514, 1'b0, -1);
        repeat (6000) @(posedge u_dut.dp_clk);
        c1 = u_dut.rx_stat_drop_full + u_dut.rx_stat_drop_partial;
        release u_dut.rx_tready;
        repeat (6000) @(posedge u_dut.dp_clk);
        chk("5a F4 drops recorded",
            (c1 > c0) === 1'b1, "40x1514B, 16w FIFO, tready=0");
        chk("5b F4 TERM word seen",
            got_term_seen === 1'b1,
            "TERM tuple verbatim");
        begin : no_overlong
            reg ok;
            ok = 1'b1;
            for (k = 0; k < got_f_cnt; k = k + 1)
                if (got_f_len[k] > 1514) ok = 1'b0;
            chk("5c no frame > 1514B",
                ok === 1'b1, "derived: max content 1514");
        end
        chk("5d F4 drop count > 0",
            (u_dut.rx_stat_drop_full + u_dut.rx_stat_drop_partial) > 32'd0,
            "40 x 1514B against a 16-word FIFO with tready=0");
        got_bytes = 0; got_frames = 0; got_len = 0; got_f_cnt = 0;
        got_started = 0; got_first_tdata = 0;
        build_frame(64, 1'b0, -1);
        repeat (600) @(posedge u_dut.dp_clk);
        chk("5e recovery byte-exact",
            ((got_bytes === 32'd64) && (got_first_tdata[63:56] === PAT[0])) === 1'b1,
            "derived: 64B, first=PAT[0]");

        // -------- 第 6 组: TX 方向 (线上格式) ------------------------------
        // 注入源 = `txsrc_*` (u_tx_arb 的输出线). ⚠️ **如实登记**: 这是 wrapper 级
        //   force ⇒ 它测 "u_txcdc→MAC→XGMII" 这段接线, **不测 u_tx_arb 内部。
        wq_wr = 0;
        force u_dut.txsrc_tdata = 64'h88776655_44332211;
        force u_dut.txsrc_tkeep = 8'hFF;
        force u_dut.txsrc_tvalid = 1'b1;
        force u_dut.txsrc_tlast = 1'b0;
        @(posedge u_dut.dp_clk);
        force u_dut.txsrc_tdata = 64'hAABBCCDD_11223344;
        @(posedge u_dut.dp_clk);
        force u_dut.txsrc_tdata = 64'h00000000_0000A55A;
        force u_dut.txsrc_tkeep = 8'hC0;
        force u_dut.txsrc_tlast = 1'b1;
        @(posedge u_dut.dp_clk);
        force u_dut.txsrc_tvalid = 1'b0;
        repeat (600) @(posedge u_dut.dp_clk);
        repeat (600) @(posedge u_dut.tx_mii_clk_1);
        release u_dut.txsrc_tdata;  release u_dut.txsrc_tkeep;
        release u_dut.txsrc_tvalid; release u_dut.txsrc_tlast;
        $display("  [F2W] group6 decode $time=%0t wq_wr=%0d injw_n=%0d", $time, wq_wr, injw_n);
        begin : g6inj
            integer gi;
            $display("  [INJW6] n=%0d", injw_n);
            for (gi = 0; gi < injw_n && gi < 256; gi = gi + 1)
                $display("  [INJW6 %0d] keep=%02h last=%b d=%016h", gi, injw_k[gi], injw_l[gi], injw_d[gi]);
        end
        injw_n = 0;
        decode_wire(wq_wr);   // 只解**本组新捕的**那些字 (旧写法用固定 4000/6000
                               // 会把上一组的陈帧也算进来 ⇒ 假 FAIL)
        chk("6a TX 1 wire frame",
            wf_cnt === 1, "derived: 1 tlast frame");
        // ⚠️ 第一版写成 `wf_cnt === 1` —— 那是 6a 的**重复**, 对
        //    "lane0 是不是 /S/" 零判别力。改成直接查扫到的那个帧首字:
        //    控制位必须**恰好 8'h01** (只有 lane0 是控制字符)。
        $display("  [DIAG6] wf_cnt=%0d wf_n0=%0d b=%02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h",
            wf_cnt, (wf_cnt > 0) ? wf_n[0] : -1,
            wf_b[0][0], wf_b[0][1], wf_b[0][2], wf_b[0][3], wf_b[0][4], wf_b[0][5],
            wf_b[0][6], wf_b[0][7], wf_b[0][8], wf_b[0][9], wf_b[0][10], wf_b[0][11],
            wf_b[0][12], wf_b[0][13], wf_b[0][14], wf_b[0][15]);
        begin : tx_w0
            reg [63:0] w0d;
            // 线上第 0 个字的原始捕获: 在捕获数组里找 wf 起点 —— 用解码器已找到的
            // 帧起点不可直接得到 ⇒ 这里改为**扫第一个 /S/ 字**的原始值。
            w0d = 64'h0;
            for (k = 0; k < 4000; k = k + 1)
                if (wq_c[k] === 8'h01 && wq_d[k][7:0] === 8'hFB) begin
                    w0d = wq_d[k]; wq_sw = k;
                end
            chk("6b TX /S/ at lane0", (wq_c[wq_sw] === 8'h01) === 1'b1,
                "vendor :995/:1147 + GATE1 C.4");
            chk("6c TX preamble word", (w0d[63:8] === 56'hD5555555555555) === 1'b1,
                "vendor :995 literal + c=8'h01");
            diag("after-group6");
        end
        // ⚠️ 线上帧的 wf_b[0][0..6] = 0x55 x6, [7] = 0xD5 (帧首字余下的 lane),
        //    内容从 **wf_b[0][8]** 起 —— 偏移算错会让"内容判据"变成在比对前导。
        if (wf_cnt == 1) begin
            // 测得的线上字节: 55 55 55 55 55 55 D5 | 88 77 66 55 44 33 22 11 | AA BB ...
            //   (首字的 lane0 是 /S/, lane1..6 = 0x55x6, lane7 = 0xD5;
            //    内容从第 2 个字的 lane0 起 = wf_b[0][7])
            chk("6d TX wf preamble",
                (wf_b[0][0] === 8'h55) && (wf_b[0][5] === 8'h55) &&
                (wf_b[0][6] === 8'hD5), "vendor :995 literal (55x6+D5)");
            chk("6e TX content lane order",
                (wf_b[0][7] === 8'h88) && (wf_b[0][8] === 8'h77) &&
                (wf_b[0][14] === 8'h11), "contract: tdata[63:56]=0x88 is byte 0");
            chk("6f TX w2 lane order",
                (wf_b[0][15] === 8'hAA) && (wf_b[0][22] === 8'h44),
                "derived: tdata[63:56]=0xAA .. tdata[7:0]=0x44");
        end else begin
            chk("6d TX wf preamble OFF", 1'b0,
                "diagnostic gate (off)");
            chk("6e TX lane order OFF", 1'b0,
                "diagnostic gate (off)");
            chk("6f TX w2 order OFF", 1'b0,
                "diagnostic gate (off)");
        end

        // -------- \u7b2c 8 \u7ec4: F-2 (\u5e27\u5185\u65ad\u4f9b \u21d2 \u51b2\u5237) \u2014\u2014 \u5224\u636e = **\u7ebf\u4e0a\u5185\u5bb9\u9010\u5e27**
        //   \u26a0\ufe0f \u4e3a\u4ec0\u4e48\u4e0d\u80fd\u53ea\u770b\u8ba1\u6570\u5668: \u672c\u5de5\u7a0b\u5b9e\u6d4b\u8fc7\u8ba1\u6570\u5668\u53ef\u4ee5\u88ab\u4f2a\u88c5
        //   (rxcls \u53d8\u5f02 M7b: \u53bb\u51b2\u5237 + \u8ba1\u6570\u5668 +1 \u21d2 \u65e7\u95e8 229/0 \u901a\u8fc7, \u800c\u7ebf\u4e0a\u771f\u51fa\u4e86 172B \u5e7d\u7075\u5e27)\u3002
        //   A = 2 \u4e2a\u5b57\u540e\u65ad\u4f9b (\u65e0 TLAST) \u21d2 mac_tx_10g \u5e27\u5185\u4e2d\u6b62; B = \u5b8c\u6574\u4e00\u5e27\u3002
        // ---- F2-DIAG-PATCH ----
        $display("  [F2W] group8 start $time=%0t wq_wr_before_reset=%0d", $time, wq_wr);
        injw_n = 0;
        f2_tr_on = 1'b1; f2_tr_n = 0; f2_tr_lim = 40;
        wq_wr = 0;
        $display("  [F2W] wq_wr_set=%0d", wq_wr);
        repeat (3) @(posedge u_dut.tx_mii_clk_1);
        $display("  [F2W] wq_wr_after3txedges=%0d  (~3 = reset honoured; ~1200 = stale group6 window)",
                 wq_wr);
        force u_dut.txsrc_tdata = 64'h88776655_44332211;
        force u_dut.txsrc_tkeep = 8'hFF;
        force u_dut.txsrc_tvalid = 1'b1;
        force u_dut.txsrc_tlast = 1'b0;
        @(posedge u_dut.dp_clk);
        force u_dut.txsrc_tdata = 64'h00000000_00000000;
        force u_dut.txsrc_tkeep = 8'hFF;
        @(posedge u_dut.dp_clk);
        force u_dut.txsrc_tvalid = 1'b0;      // \u65ad\u4f9b (\u6ca1\u6709 TLAST)
        repeat (600) @(posedge u_dut.dp_clk);
        repeat (400) @(posedge u_dut.tx_mii_clk_1);
        // frame B: \u4e00\u4e2a\u5b57 + TLAST
        $display("  [F2W] before frame B $time=%0t wq_wr=%0d injw_n=%0d", $time, wq_wr, injw_n);
        f2_tr_n = 0; f2_tr_lim = 70;
        force u_dut.txsrc_tdata = 64'hAABBCCDD_11223344;
        force u_dut.txsrc_tkeep = 8'hFF;
        force u_dut.txsrc_tvalid = 1'b1;
        force u_dut.txsrc_tlast = 1'b1;
        @(posedge u_dut.dp_clk);
        force u_dut.txsrc_tvalid = 1'b0;
        repeat (800) @(posedge u_dut.dp_clk);
        repeat (800) @(posedge u_dut.tx_mii_clk_1);
        release u_dut.txsrc_tdata;  release u_dut.txsrc_tkeep;
        release u_dut.txsrc_tvalid; release u_dut.txsrc_tlast;
        f2_tr_on = 1'b0;
        $display("  [F2W] decode $time=%0t wq_wr=%0d injw_n=%0d", $time, wq_wr, injw_n);
        dump_injw;
        decode_wire(wq_wr);
        dump_frames;
        $display("  [F2W] window head (first 10 captured words):");
        dump_raw(0, 10);
        if (wf_cnt > 0) begin
            $display("  [F2W] raw words of the decoded span:");
            dump_raw(wf_start[0], wf_stop[wf_cnt-1] + 2);
        end
        begin : f2
            integer f, nb, nm;
            reg ok_prefix, ok_b;
            ok_prefix = 1'b1; ok_b = 1'b0; nb = 0;
            for (f = 0; f < 32; f = f + 1) begin
                nm = wf_n[f];
                if (f < wf_cnt) begin
                    // \u5185\u5bb9 = \u524d\u5bfc\u4e4b\u540e\u7684\u5b57\u8282; A \u7684\u5b57\u8282 = 88 77 66 55 44 33 22 11
                    if (nm > 7) begin
                        if ((nm - 7) > 8) ok_prefix = 1'b0;
                        else if (wf_b[f][7] !== 8'h88) ok_prefix = 1'b0;
                        else begin
                            if ((nm - 7) > 1 && wf_b[f][8]  !== 8'h77) ok_prefix = 1'b0;
                            if ((nm - 7) > 2 && wf_b[f][9]  !== 8'h66) ok_prefix = 1'b0;
                            if ((nm - 7) > 3 && wf_b[f][10] !== 8'h55) ok_prefix = 1'b0;
                        end
                    end
                    // \u6700\u540e\u4e00\u5e27\u5fc5\u987b\u662f B
                    if (f == wf_cnt - 1) begin
                        if ((nm - 7) >= 8 &&
                            wf_b[f][7]  === 8'hAA && wf_b[f][8]  === 8'hBB &&
                            wf_b[f][9]  === 8'hCC && wf_b[f][10] === 8'hDD &&
                            wf_b[f][11] === 8'h11 && wf_b[f][12] === 8'h22 &&
                            wf_b[f][13] === 8'h33 && wf_b[f][14] === 8'h44) ok_b = 1'b1;
                        nb = nm - 7;      // \u5185\u5bb9\u5b57\u8282\u6570 (\u542b pad + FCS)
                    end
                end
            end
            $display("  [DIAG8] wf_cnt=%0d last_content_len=%0d prefix_ok=%b b_ok=%b",
                     wf_cnt, nb, ok_prefix, ok_b);
            $display("  [DIAG8b] f0_n=%0d f1_n=%0d | f0=%02h %02h %02h %02h %02h %02h %02h %02h %02h %02h | f1=%02h %02h %02h %02h %02h %02h %02h %02h %02h %02h",
                wf_n[0], wf_n[1],
                wf_b[0][0], wf_b[0][7], wf_b[0][8], wf_b[0][9], wf_b[0][10], wf_b[0][11], wf_b[0][12], wf_b[0][13], wf_b[0][14], wf_b[0][15],
                wf_b[1][0], wf_b[1][7], wf_b[1][8], wf_b[1][9], wf_b[1][10], wf_b[1][11], wf_b[1][12], wf_b[1][13], wf_b[1][14], wf_b[1][15]);
            // 8a: \u7ebf\u4e0a\u5e27\u6570 \u2014\u2014 \u65ad\u4f9b\u4e00\u5e27\u7684 runt + \u5b8c\u6574\u7684 B = 2 (\u65e0\u5e7d\u7075\u5c31\u662f 2)
            // F2X10-PATCH: 归因完成 (2026-09-30) -- see notes/P7B_F2_CHAIN_ATTRIB.md
            //   (1) 本组解码窗口 [0, wq_wr) 是**陈旧的**: 开头的 `wq_wr = 0` 被捕获 always
            //       块同拍 NBA 覆盖 (实测 wq_wr: 1202 -> 1205, 而 group6 那次生效) =>
            //       窗口里含**上一组 (group 6) 的帧** (它在 wf_start[0]=7)。
            //   (2) 本组期望 (runt + 完整 B) 与自己的激励矛盾: A 没有 TLAST => 按 F-2 合同
            //       (rtl/mac_tx_10g.v:24-31 情形3) 冲刷必然吞掉 B 整帧。
            //   => 合同正确的判据见 F2X X4 (同一激励) 与 X3 (A 带 TLAST 的场景)。
            $display("  [OPEN] 8a F-2 wire frames == 2 = %b   (SUPERSEDED by F2X X4; see notes/P7B_F2_CHAIN_ATTRIB.md)", (wf_cnt === 2) === 1'b1);
            // 8b: \u6bcf\u4e00\u5e27\u8981\u4e48\u662f A \u7684\u524d\u7f00, \u8981\u4e48\u5c31\u662f B (\u65e0\u5176\u5b83\u53ef\u80fd)
            $display("  [OPEN] 8b every wire frame is A-prefix or B = %b   (SUPERSEDED by F2X X4; see notes/P7B_F2_CHAIN_ATTRIB.md)", (ok_prefix === 1'b1) === 1'b1);
            // 8c: \u6700\u540e\u4e00\u5e27 == B \u9010\u5b57\u8282
            $display("  [OPEN] 8c post-flush frame == B byte-exact = %b   (SUPERSEDED by F2X X4; see notes/P7B_F2_CHAIN_ATTRIB.md)", (ok_b === 1'b1) === 1'b1);
            // 8d: B \u88ab pad \u5230 MIN_CLEN (\u5185\u5bb9 60B) + FCS 4B = 64B \u7ebf\u4e0a\u5185\u5bb9
            $display("  [OPEN] 8d post-flush frame content == 60B (pad) + 4B FCS = %b   (SUPERSEDED by F2X X4; see notes/P7B_F2_CHAIN_ATTRIB.md)", (nb === 64) === 1'b1);
        end

        // -------- 第 7 组: 快照 51 字逐字读回 ------------------------------
        //   ⛔ 2026-10-07 订正 (P7B_STAGEB_FIX.md): 窗口现 **63 字** (P7B-WU 二轮起;
        //      `board/wrapper_p4.v:3125` `SNAP_NW_P6E = 63`) —— 本组逐字读的 W36..W50
        //      (0xB0..0xE8) 不受影响; 组末那条边界判据的地址已随之订正 (0xEC → 0x11C)。
        //      ("51 字" = RATE/P7b 时代值; BIZ 61 字 / Stage A 63 字, 出处 P7B_BIZ_WINDOW.md §1)
        // ⚠️ force 打**生产者节点** (P6e 门的教训: 打 wrapper 级线会掩盖"生产者↔线"
        //    的连接错)。非 P7B 的数字信号源存在 (1G MAC 没有这些输出) ⇒ 这条判据
        //    只在 P7B 构建里有意义。
        force u_dut.u_classify.dbg_stat_ovf       = 32'hA5A50036;
        force u_dut.u_classify.dbg_stat_route_ovf = 32'hA5A50037;
        force u_dut.u_classify.dbg_stat_stall_in  = 32'hA5A50038;
        force u_dut.u_classify.dbg_occ            = 5'h15;
        force u_dut.u_txcdc.ovf_cnt               = 32'hA5A50045;
        force u_dut.u_rxcdc.ovf_cnt               = 32'hA5A50038;
        force u_dut.u_mac_tx.stat_flush_words     = 32'hA5A50041;
        force u_dut.u_mac_tx.stat_flush_done      = 32'hA5A50042;
        force u_dut.u_mac_tx.stat_tx_words        = 32'hA5A50043;
        force u_dut.u_mac_tx.stat_tx_ctrl_char    = 32'hA5A50044;
        force u_dut.u_mac_rx.stat_rx_words        = 32'hA5A50036;
        force u_dut.u_mac_rx.stat_rx_pay_bytes    = 32'hA5A50037;
        force u_dut.tx_clk_act                    = 32'hA5A50050;
        force u_dut.u_pcs.blk_lock                = 1'b1;
        force u_dut.u_pcs.hi_ber                  = 1'b1;
        repeat (300) @(posedge u_dut.pcie_axi_aclk);
        $display("  [DIAG7] busy=%b seq_busy=%b vld=%b | fe v=%b seen=%b | dp v=%b seen=%b | tx v=%b seen=%b | all=%b",
            u_dut.snap_busy, u_dut.snap_seq_busy, u_dut.snap_valid,
            u_dut.p7bfe_valid, u_dut.p7bfe_seen, u_dut.p7bdp_valid, u_dut.p7bdp_seen,
            u_dut.txsnap_valid, u_dut.tx_seen, u_dut.snap_valid_all);
        snap_take;
        $display("  [DIAG7b] busy=%b seen fe/dp/tx=%b%b%b r36=%08h r50=%08h r37=%08h r38=%08h",
            u_dut.snap_busy, u_dut.p7bfe_seen, u_dut.p7bdp_seen, u_dut.tx_seen,
            u_dut.snap_dout_all[36*32 +: 32], u_dut.snap_dout_all[50*32 +: 32],
            u_dut.snap_dout_all[37*32 +: 32], u_dut.snap_dout_all[38*32 +: 32]);
        $display("  [DIAG7c] W39=%08h W40=%08h | blk_sr=%b gpw=%b vcc=%b rerr=%02h",
            u_dut.snap_dout_all[39*32 +: 32], u_dut.snap_dout_all[40*32 +: 32],
            u_dut.pcs_blk_sr, u_dut.pcs_gpw_sr[2], u_dut.pcs_vcc_sr[2], u_dut.pcs_rerr_sr[0]);
        u_dut.u_pcie_xdma.axil_read(32'hB0, v); chk("7 W36 rx_words", v === 32'hA5A50036, "forced producer node");
        u_dut.u_pcie_xdma.axil_read(32'hB4, v); chk("7 W37 rx_pay_bytes", v === 32'hA5A50037, "forced producer node");
        u_dut.u_pcie_xdma.axil_read(32'hB8, v); chk("7 W38 rxcdc.ovf_cnt", v === 32'hA5A50038, "forced producer node");
        u_dut.u_pcie_xdma.axil_read(32'hBC, v); chk("7 W39[2] block_lock", v[2] === 1'b1, "forced producer bit");
        u_dut.u_pcie_xdma.axil_read(32'hBC, v); chk("7 W39[4] hi_ber", v[4] === 1'b1, "forced producer bit");
        u_dut.u_pcie_xdma.axil_read(32'hC4, v); chk("7 W41 stat_flush_words", v === 32'hA5A50041, "forced producer node");
        u_dut.u_pcie_xdma.axil_read(32'hC8, v); chk("7 W42 stat_flush_done", v === 32'hA5A50042, "forced producer node");
        u_dut.u_pcie_xdma.axil_read(32'hCC, v); chk("7 W43 stat_tx_words", v === 32'hA5A50043, "forced producer node");
        u_dut.u_pcie_xdma.axil_read(32'hD0, v); chk("7 W44 stat_tx_ctrl_char", v === 32'hA5A50044, "forced producer node");
        u_dut.u_pcie_xdma.axil_read(32'hD4, v); chk("7 W45 txcdc.ovf_cnt", v === 32'hA5A50045, "forced producer node");
        u_dut.u_pcie_xdma.axil_read(32'hD8, v); chk("7 W46 cls dbg_stat_ovf", v === 32'hA5A50036, "forced producer node");
        u_dut.u_pcie_xdma.axil_read(32'hDC, v); chk("7 W47 cls route_ovf", v === 32'hA5A50037, "forced producer node");
        u_dut.u_pcie_xdma.axil_read(32'hE0, v); chk("7 W48 cls stall_in", v === 32'hA5A50038, "forced producer node");
        u_dut.u_pcie_xdma.axil_read(32'hE4, v); chk("7 W49 cls dbg_occ", v === 32'h00000015, "forced producer node");
        u_dut.u_pcie_xdma.axil_read(32'hE8, v); chk("7 W50 tx_clk_act", v === 32'hA5A50050, "forced producer node");
        // 有界性: 51 字占 0x20..0xE8 ⇒ 0xEC 必须读 0 且 SLVERR。
        //   ⛔ 2026-10-10 订正 (构建 C 门同步轮): 窗口 63 → **65 字** (新增 W63/W64 =
        //      `app_pattern.stat_frmwait_cyc` / `stat_bp_cyc`; `board/wrapper_p4.v` 的
        //      `SNAP_NW_P6E = 65`) ⇒ 末字 W64 @ 0x120 ⇒ **未实现地址 = 0x20 + 4*65 = 0x124**
        //      (word 73)。`0x11C` 现在是**窗口内的真字 W63** ⇒ 原地址上的 SLVERR 断言
        //      已失去判别力 (必然红) ⇒ 只换地址常量。红线不变 (读侧译码 7 位 ⇒ 绝不能挑
        //      ≥0x200); 判据语义不变 (未实现地址必须回 0 + SLVERR)。原句 (63 字时代) 保留在下方。
        //   ⛔ 2026-10-07 订正 (P7B_STAGEB_FIX.md; 出处 P7B_STAGEB_RX8_REGRESSION.md §5.6/§6-③):
        //      窗口 BIZ 轮起 61 字 / Stage A 起 **63 字** (0x20..0x118) ⇒ **0xEC = W51 已是真字**
        //      (W51 = app_pattern 发字节, 见 P7B_BIZ_WINDOW.md §1) ⇒ 原地址必红、SLVERR 断言失去判别力;
        //      **未实现地址 = word 63 = 0x20+4*63 = 0x11C** (读侧译码 BIZ 轮起已 6→7 位 ⇒ 红线
        //      = 绝不能挑 ≥0x200; `board/wrapper_p4.v:3108-3112` 的预算复算逐字给出 0x11C)。
        //      判据语义不变 (未实现地址必须回 0 + SLVERR), 只换地址常量。
        //   ⚠️ 这条 + 上面 W50 那一条**一起**才钉死"读侧选字位宽够":
        //      只验前半段的话, `snap_base` 位宽不够造成的**高地址回绕**会逃逸
        //      (高字读回低字的值 = 假 PASS)。
        // 原句 (51 字时代, 逐字保留):
        //   u_dut.u_pcie_xdma.axil_read(32'hEC, v);
        //   chk("7b 0xEC reads 0 no wrap",
        //       (v === 32'h00000000) && (u_dut.u_pcie_xdma.last_rresp === 2'd2),
        //       "axi_regs decode; 51-word bound");
        // 原句 (63 字时代, 逐字保留):
        //   u_dut.u_pcie_xdma.axil_read(32'h11C, v);
        //   chk("7b 0x11C reads 0 no wrap",
        //       (v === 32'h00000000) && (u_dut.u_pcie_xdma.last_rresp === 2'd2),
        //       "axi_regs decode; 63-word bound (原 51 字/0xEC; 2026-10-07 订正)");
        u_dut.u_pcie_xdma.axil_read(32'h138, v);
        chk("7b 0x138 reads 0 no wrap",
            (v === 32'h00000000) && (u_dut.u_pcie_xdma.last_rresp === 2'd2),
            "axi_regs decode; 70-word bound (原 67 字/0x12C, 66 字/0x128, 63 字/0x11C; 2026-10-10 订正)");

        // =============================================================
        // F2X-PATCH: F-2 归因实验 (窗口 = 快照基准, 判据 = 线上逐帧内容)
        //   判据的判别力来源: 逐帧"内容必须等于某个注入帧 (完整或残缺前缀)", 任何
        //   "不是任何注入帧"的线上帧 = 幽灵帧 = FAIL。全部注入帧内容 = 60 字节
        //   (= MIN_CLEN, 无 pad), FCS 由 TB 位串行 crc32 独立算 (Python 侧复核)。
        // =============================================================
        $display("==== F2X: F-2 chain attribution experiments ====");

        // 释放组 7 的**生产者 force** (stat_flush_words/done, stat_tx_words/ctrl,
        //   txcdc.ovf, u_pcs.blk_lock/hi_ber, tx_clk_act...) —— 否则 F2X 的计数器
        //   判据读的是常量 (实测: flw=2779054145=0xA5A50041 = 组 7 的 force 值)
        release u_dut.u_classify.dbg_stat_ovf;   release u_dut.u_classify.dbg_stat_route_ovf;
        release u_dut.u_classify.dbg_stat_stall_in; release u_dut.u_classify.dbg_occ;
        release u_dut.u_txcdc.ovf_cnt;  release u_dut.u_rxcdc.ovf_cnt;
        release u_dut.u_mac_tx.stat_flush_words; release u_dut.u_mac_tx.stat_flush_done;
        release u_dut.u_mac_tx.stat_tx_words;    release u_dut.u_mac_tx.stat_tx_ctrl_char;
        release u_dut.u_mac_rx.stat_rx_words;    release u_dut.u_mac_rx.stat_rx_pay_bytes;
        release u_dut.tx_clk_act;  release u_dut.u_pcs.blk_lock;  release u_dut.u_pcs.hi_ber;

        // -------- X1a: 单帧, 连续注入 (1 字/拍, = DP 侧合同) --------
        $display("  ---- X1a: one frame, continuous injection (1 word/cycle) ----");
        f2x_begin;
        f2x_add60(1);                       // 帧 0 = PAT[1..60]
        f2_tr_on = 1'b1; f2_tr_n = 0; f2_tr_lim = 70;
        f2x_stream(0);
        f2x_settle;
        f2_tr_on = 1'b0;
        f2x_scan;
        f2x_show("X1a");
        chk("X1a one frame on the wire", f2x_wn === 1, "derived: 1 injected tlast frame");
        chk("X1a frame is complete (60B content + FCS)",
            (f2x_wn == 1) && (f2x_wkind[0] === 2), "derived: content byte-exact + FCS len");
        chk("X1a no ghost", (f2x_wn <= 0) || (f2x_wkind[0] !== 0), "derived: classification");

        // -------- X1b: 同一帧, 但以 50% 占空比注入 (1 字 / 2 拍) --------
        //   => 故意制造"帧内气泡" (F-2 语义下 = 断供): 期望线上只剩残帧 + 冲刷
        $display("  ---- X1b: same frame at 50%% duty (1 word / 2 cycles = deliberate bubble) ----");
        f2x_begin;
        f2x_add60(1);
        f2_tr_on = 1'b1; f2_tr_n = 0; f2_tr_lim = 70;
        f2x_push_frame(0);
        f2x_settle;
        f2_tr_on = 1'b0;
        f2x_scan;
        f2x_show("X1b");
        // F2X4-PATCH: 50% 占空比 = 故意帧内气泡 => 期望"残帧 + 冲刷" (F-2 语义), 不是完整帧
        chk("X1b bubble -> exactly 1 wire frame", f2x_wn === 1,
            "contract: mid-frame starvation aborts the frame (F-2)");
        chk("X1b that frame is a runt (prefix of the injected frame)",
            (f2x_wn == 1) && (f2x_wkind[0] === 1), "derived: prefix compare");
        chk("X1b flush counters advanced (rest of the frame flushed)",
            (u_dut.u_mac_tx.stat_flush_done === (f2x_fld0 + 32'd1)) &&
            (u_dut.u_mac_tx.stat_flush_words > f2x_flw0),
            "design bookkeeping (NOT the primary criterion)");
        chk("X1b no ghost", (f2x_wn >= 1) && (f2x_wkind[0] !== 0), "derived: classification");

        // -------- X2: 两帧背靠背 --------
        f2x_begin;
        f2x_add60(1);
        f2x_add60(100);                     // 帧 1 = PAT[100..159] (与帧 0 逐字节不同)
        f2x_stream(0);
        f2x_stream(1);
        f2x_settle;
        f2x_scan;
        f2x_show("X2");
        chk("X2 two frames back-to-back", f2x_wn === 2, "derived: 2 injected tlast frames");
        chk("X2 both frames complete/byte-exact",
            (f2x_wn == 2) && (f2x_wkind[0] === 2) && (f2x_wkind[1] === 2),
            "derived: per-frame content compare");

        // -------- X3: 帧内中止 + 残字 (含本帧 TLAST) 随后到达 + 完整 B --------
        //   = 设计合同 F-2 针对的场景 (单元门组 9 同构): 残字必须被冲刷掉, B 必须完整上线
        f2x_begin;
        f2x_add60(1);                       // 帧 0 = A (被中止, 60B)
        f2x_add60(100);                     // 帧 1 = B (冲刷后应完整发出)
        f2x_push_head(0, 2);                // A 的头 2 个字 (16B) => 之后断供
        f2x_wait_abort;                     // 等 DUT 确认中止 (runt 已上线)
        f2x_push_tail(0, 2, 7);             // A 的残字 + 本帧 TLAST (必须被冲刷)
        f2x_stream(1);                      // B (连续注入)
        f2x_settle;
        f2x_scan;
        f2x_show("X3");
        chk("X3 exactly 2 wire frames (runt + B)", f2x_wn === 2,
            "derived: 1 aborted runt + 1 complete B");
        chk("X3 frame0 is a runt (strict prefix of A)",
            (f2x_wn >= 1) && (f2x_wkind[0] === 1), "derived: prefix compare vs injected A");
        chk("X3 frame1 is B byte-exact",
            (f2x_wn >= 2) && (f2x_wkind[1] === 2), "derived: complete-frame compare vs B");
        chk("X3 no ghost at all",
            (f2x_wn >= 2) && (f2x_wkind[0] !== 0) && (f2x_wkind[1] !== 0),
            "derived: classification");

        // -------- X4: 帧内中止 + A 的 TLAST 永不到达 + B (链级探针的原始激励) --------
        //   合同 (mac_tx_10g.v:24-31 情形3): 冲刷会吃掉 B 整帧 => 线上只有 runt,
        //   且 stat_flush_done == 1 / stat_flush_words >= 1
        f2x_begin;
        f2x_add60(1);                       // A
        f2x_add60(100);                     // B (注入但不许上线)
        f2x_push_head(0, 2);
        f2x_wait_abort;
        f2x_stream(1);                      // B (连续注入): 必须被冲刷吞掉
        f2x_settle;
        f2x_scan;
        f2x_show("X4");
        chk("X4 exactly 1 wire frame (runt only)", f2x_wn === 1,
            "contract: flush swallows the next frame when the aborted one has no TLAST");
        chk("X4 that frame is a runt (prefix of A)",
            (f2x_wn == 1) && (f2x_wkind[0] === 1), "derived: prefix compare vs injected A");
        chk("X4 no ghost", (f2x_wn >= 1) && (f2x_wkind[0] !== 0), "derived: classification");
        chk("X4 flush counters advanced",
            (u_dut.u_mac_tx.stat_flush_done === (f2x_fld0 + 32'd1)) &&
            (u_dut.u_mac_tx.stat_flush_words > f2x_flw0),
            "design bookkeeping (NOT the primary criterion)");
        // F2X11c: 原判据只看 frame 0 ⇒ 实测在 MUT-NOFLUSH 下 **B 整帧在线** 却 PASS
        //   (logs/f2x11_mut_noflush_FINAL.log:2801 X4 frame1 kind=2 = PAT[100..])。
        //   改成扫**每一帧**: 任何帧都不得以 B 的 8 个内容字节开头。
        nob_n = -1;
        for (xa_f = 0; xa_f < f2x_wn && xa_f < 32; xa_f = xa_f + 1)
            if ((f2x_wlen[xa_f] >= 7 + 8) && (nob_n < 0) &&
                (f2x_wire[xa_f][7]  === f2x_c[F2X_STRIDE + 0]) &&
                (f2x_wire[xa_f][8]  === f2x_c[F2X_STRIDE + 1]) &&
                (f2x_wire[xa_f][9]  === f2x_c[F2X_STRIDE + 2]) &&
                (f2x_wire[xa_f][10] === f2x_c[F2X_STRIDE + 3]) &&
                (f2x_wire[xa_f][11] === f2x_c[F2X_STRIDE + 4]) &&
                (f2x_wire[xa_f][12] === f2x_c[F2X_STRIDE + 5]) &&
                (f2x_wire[xa_f][13] === f2x_c[F2X_STRIDE + 6]) &&
                (f2x_wire[xa_f][14] === f2x_c[F2X_STRIDE + 7])) nob_n = xa_f;
        $display("  [F2X X4] first wire frame with a B prefix: %0d (-1 = none) out of %0d frames",
                 nob_n, f2x_wn);
        chk("X4 no B on the wire", nob_n < 0,
            "F2X11c: every frame scanned");

        // -------- X5: TX → RX 环回 (短帧 FCS 覆盖面) --------
        $display("---- X5: TX->RX replay (short frame FCS scope) ----");
        begin : x5
            integer rf0, rc0;
            // X5b 控制组: 60B 内容 (无 pad)
            f2x_begin;
            f2x_add60(1);
            f2x_stream(0);
            f2x_settle;
            f2x_scan;
            rf0 = u_dut.rx_stat_frames; rc0 = u_dut.rx_stat_crc_err;
            f2x_loop(f2x_wstart[0] - 4, f2x_wstop[0] + 5);
            repeat (400) @(posedge u_dut.rx_clk_out_1);
            $display("  [F2X X5b] 60B frame: rx_frames %0d->%0d, rx_crc_err %0d->%0d",
                     rf0, u_dut.rx_stat_frames, rc0, u_dut.rx_stat_crc_err);
            $display("  [F2X X5b] DIAG only (not a criterion): replayed frame delivered=%b crc_err_delta=%0d",
                     (u_dut.rx_stat_frames > rf0), (u_dut.rx_stat_crc_err - rc0));
            // X5a 待测组: 20B 内容 (MAC 补 40B pad)
            f2x_begin;
            f2x_add20(1);
            f2x_stream20(0);
            f2x_settle;
            f2x_scan;
            $display("  [F2X X5a] injected 20B-content frame: wire frames=%0d kind=%0d content_len_incl_pad=%0d",
                     f2x_wn, f2x_wkind[0], f2x_wlen[0] - 7 - 4);
            // F2X11 正对照: 补 pad 的最小帧**不得**被判成幽灵。修 F2X11 前同一个 DUT 帧
            //   (线上内容 60B, 注入 20B) 会被旧分类器判 kind=0 -- 证据:
            //   logs/f2x11_before_nomac_none.log:1758 (`kind=0 content_len_incl_pad=60`),
            //   而同一帧在同一份日志 1760 行被自家 RX 接受 (crc_err 2->2)。
            chk("X5a pad frame complete+padFCS",
                (f2x_wn == 1) && (f2x_wkind[0] === 2), "F2X11: on-wire len + crc32");
            rf0 = u_dut.rx_stat_frames; rc0 = u_dut.rx_stat_crc_err;
            f2x_loop(f2x_wstart[0] - 4, f2x_wstop[0] + 5);
            repeat (400) @(posedge u_dut.rx_clk_out_1);
            $display("  [F2X X5a] 20B+pad frame: rx_frames %0d->%0d, rx_crc_err %0d->%0d",
                     rf0, u_dut.rx_stat_frames, rc0, u_dut.rx_stat_crc_err);
            // F2X10-PATCH: 这条是**缺陷登记判据** (不是 F-2 判据):
            //   DUT 短帧 (20B 内容补 pad 到 60) 的 FCS 只覆盖数据字节, 而我们自己的 RX
            //   (以及任何标准对端) 要求 FCS 覆盖 **pad 在内**的全部 60 字节。
            //   校准: X5c-b/X5d-1 (TB 自算 FCS) 都通过 => 回放通路可信;
            //         X5d-2 只改 FCS 覆盖面 => 立刻被判 crc_err (判别力证明)。
            //   ⚠️ 修法在 rtl/mac_tx_10g.v (crc_en 需含 pad), 本轮**按指示不动 rtl/**,
            //      所以这条在修好之前**应该保持红**。
            $display("  [DEFECT-REG #1] mac_tx_10g padded-frame FCS scope (FIXED 2026-09-30: pad is fed into the CRC; crc_keep/crc_en in rtl/mac_tx_10g.v now cover the pad lanes). This criterion + F2X11 X6 stay as the REGRESSION GUARD: mutation MUT-PADNOCRC (pad removed from the CRC in a scratch copy) re-reds it. History: X5a/X5d-2 vs X5d-1 calibration, see notes/P7B_F2_CHAIN_ATTRIB.md section 10.");
            chk("X5a DUT padded short frame passes our own RX (REGISTERED DEFECT #1)",
                (u_dut.rx_stat_crc_err === rc0) && (u_dut.rx_stat_frames > rf0),
                "derived: TX and RX must agree on the FCS of a padded frame; see [DEFECT-REG #1]");

            // -------- X5c: 校准 —— 同一内容 (68B, 无 pad) 两条路径 --------
            begin : x5c
                integer rf2, rc2, rf3, rc3;
                // (a) DUT TX 帧 (DUT 自算 FCS)
                f2x_begin;
                f2x_add68;
                f2x_stream68(0);
                f2x_settle;
                f2x_scan;
                $display("  [F2X X5c] DUT TX 68B frame: wire frames=%0d kind=%0d content_len=%0d",
                         f2x_wn, f2x_wkind[0], f2x_wlen[0] - 7 - 4);
                f2x_show("X5c");
                $display("  [F2X X5c] DUT replay window raw words (F2X11: snapshot window = the span f2x_loop replays):");
                if (f2x_wn >= 1) dump_raw(f2x_wstart[0] - 4, f2x_wstop[0] + 5);
                rf2 = u_dut.rx_stat_frames; rc2 = u_dut.rx_stat_crc_err;
                f2x_loop(f2x_wstart[0] - 4, f2x_wstop[0] + 5);
                repeat (400) @(posedge u_dut.rx_clk_out_1);
                $display("  [F2X X5c-a] DUT-TX frame replayed: rx_frames %0d->%0d crc_err %0d->%0d",
                         rf2, u_dut.rx_stat_frames, rc2, u_dut.rx_stat_crc_err);
                // (b) TB 自算 FCS 的同一内容帧 (build_frame 自己把帧推入 xq)
                rf3 = u_dut.rx_stat_frames; rc3 = u_dut.rx_stat_crc_err;
                build_frame(68, 1'b0, -1);
                begin : tbq
                    integer qi;
                    $display("  [F2X X5c] TB-FCS injected words (last 12):");
                    for (qi = xq_wr - 12; qi < xq_wr; qi = qi + 1)
                        $display("  [TBQ %0d] c=%02h d=%016h", qi, xq_c[qi], xq_d[qi]);
                end
                repeat (400) @(posedge u_dut.rx_clk_out_1);
                $display("  [F2X X5c-b] TB-FCS frame replayed : rx_frames %0d->%0d crc_err %0d->%0d",
                         rf3, u_dut.rx_stat_frames, rc3, u_dut.rx_stat_crc_err);
                chk("X5c calibration: TB-FCS frame passes our own RX",
                    (u_dut.rx_stat_crc_err === rc3) && (u_dut.rx_stat_frames > rf3),
                    "calibration: replay path is faithful (no crc_err for a TB-computed FCS)");
                chk("X5c same content, DUT-TX frame passes our own RX",
                    (u_dut.rx_stat_crc_err === rc2) && (u_dut.rx_stat_frames > rf2),
                    "derived: TX FCS must equal TB FCS for the same 68B content");

            // -------- X5d: 同一 60B 线上内容, 两种 FCS 覆盖面 (校准过的 A/B) --------
            f2x_build_pad(1'b0);                 // 标准: FCS 覆盖 pad
            repeat (400) @(posedge u_dut.rx_clk_out_1);
            $display("  [F2X X5d-1] TB frame, FCS over 60 padded bytes: rx_frames=%0d crc_err=%0d",
                     u_dut.rx_stat_frames, u_dut.rx_stat_crc_err);
            chk("X5d-1 TB frame with pad-covered FCS passes our own RX",
                (u_dut.rx_stat_crc_err === rc3), "calibration: RX accepts the standard scope");
            f2x_build_pad(1'b1);                 // DUT 风格: FCS 只覆盖 18 数据字节
            repeat (400) @(posedge u_dut.rx_clk_out_1);
            $display("  [F2X X5d-2] TB frame, FCS over 18 data bytes : rx_frames=%0d crc_err=%0d",
                     u_dut.rx_stat_frames, u_dut.rx_stat_crc_err);
            chk("X5d-2 TB frame with data-only FCS is flagged crc_err (discrimination)",
                (u_dut.rx_stat_crc_err === (rc3 + 32'd1)),
                "derived: the only difference is the FCS scope => RX wants the pad inside");
            end
        end

        // =============================================================
        // X6 (F2X11): **原生 TX -> 原生 RX 自洽** —— 自家 TX 发出的帧必须能被自家 RX 收到
        //   (交付合同: tcrs=1)。覆盖 3 个"必须补 pad 到 60"的线上尺寸:
        //     20B = 本工程图案短帧 (X5a 同款, 2 满字 + 4B 尾字)
        //     42B = ARP 应答的线上内容长度  (14 eth + 28 ARP)
        //     54B = TCP 纯 ACK 的线上内容长度 (14 eth + 20 IP + 20 TCP)
        //   每尺寸 3 条判据:
        //     a) 线上帧 = 完整 (kind=2): 长度/内容含 pad 逐字节 + FCS == TB crc32(线上全部内容)
        //        —— 与自家 RX 无关的**独立 oracle** (pad 不进 CRC 时立刻翻红)
        //     b) 回放进自家 RX 后**恰 1 帧交付**, 且 tcrs=1 / terr=0 / 交付长度 60
        //     c) 交付字节逐字节 == 内容 ++ 全 0 pad
        //   ⚠️ 回放窗口 = f2x_loop(f2x_wstart[0]-4, f2x_wstop[0]+5) (快照基准, 与 X5 同款)
        // =============================================================
        begin : x6
            integer si, n6, gc0, q6, rc6, gbi;
            reg okb;
            reg [7:0] bexp;
            integer ga, gb, gc;
            $display("==== F2X11 X6: own TX -> own RX self-consistency (tcrs=1) ====");
            for (si = 0; si < 3; si = si + 1) begin
                n6 = (si == 0) ? 20 : ((si == 1) ? 42 : 54);
                $display("  ---- X6.%0d: DUT TX %0dB-content frame (pad -> 60) -> own RX ----", si, n6);
                f2x_begin;
                f2x_addn(n6, 1);
                f2x_streamn(0, n6);
                f2x_settle;
                f2x_scan;
                $display("  [F2X X6.%0d] inj=%0dB wire frames=%0d kind=%0d wlen=%0d (window [%0d,%0d) inj_n=%0d)",
                         si, n6, f2x_wn, (f2x_wn >= 1) ? f2x_wkind[0] : -1,
                         (f2x_wn >= 1) ? f2x_wlen[0] : 0, wq_base, wq_wr, f2x_cn);
                if (f2x_wn >= 1)
                    for (q6 = 0; q6 < f2x_wlen[0] && q6 < 80; q6 = q6 + 8)
                        $display("      [%03d] %02h %02h %02h %02h %02h %02h %02h %02h", q6,
                            f2x_wire[0][q6], f2x_wire[0][q6+1], f2x_wire[0][q6+2], f2x_wire[0][q6+3],
                            f2x_wire[0][q6+4], f2x_wire[0][q6+5], f2x_wire[0][q6+6], f2x_wire[0][q6+7]);
                ga = ((f2x_wn == 1) && (f2x_wkind[0] === 2)) ? 1 : 0;
                gc0 = got_f_cnt;
                rc6 = u_dut.rx_stat_crc_err;
                if (f2x_wn >= 1) f2x_loop(f2x_wstart[0] - 4, f2x_wstop[0] + 5);
                repeat (400) @(posedge u_dut.rx_clk_out_1);
                $display("  [F2X X6.%0d] replayed -> got_frames %0d->%0d last_len=%0d tcrs=%0d terr=%0d | rx_frames %0d crc_err %0d (was %0d)",
                         si, gc0, got_f_cnt, got_last_len, got_f_crs[gc0], got_f_terr[gc0],
                         u_dut.rx_stat_frames, u_dut.rx_stat_crc_err, rc6);
                gb = ((got_f_cnt === (gc0 + 1)) && (got_f_len[gc0] === 60) &&
                      (got_f_crs[gc0] === 1) && (got_f_terr[gc0] === 0) &&
                      (u_dut.rx_stat_crc_err === rc6)) ? 1 : 0;
                okb = 1'b1;
                // ⚠️ got_buf 的存储序 = **lane0-first** (观察者按 `tdata[bi*8 +: 8]`, bi=0..7
                //    逐 lane 写) ⇒ 每个 8 字节组的顺序与帧字节流**相反** (帧首字节在 lane7,
                //    即该组最后一个被写进去的槽)。⇒ 逐字节比对必须按组反转。
                for (q6 = 0; q6 < 60; q6 = q6 + 1) begin
                    gbi = (q6 / 8) * 8 + 7 - (q6 % 8);
                    bexp = (gbi < n6) ? PAT[(1+gbi) % 256] : 8'h00;
                    if (got_buf[q6] !== bexp) okb = 1'b0;
                end
                gc = ((okb === 1'b1) && (got_f_cnt === (gc0 + 1))) ? 1 : 0;
                $display("  [F2X X6.%0d] delivered got_buf[0..7] = %02h %02h %02h %02h %02h %02h %02h %02h (lane0-first) | frame[0..7] = %02h %02h %02h %02h %02h %02h %02h %02h",
                         si, got_buf[0], got_buf[1], got_buf[2], got_buf[3],
                         got_buf[4], got_buf[5], got_buf[6], got_buf[7],
                         PAT[1], PAT[2], PAT[3], PAT[4], PAT[5], PAT[6], PAT[7], PAT[8]);
                $display("  [F2X X6.%0d] tail got_buf[52..59] = %02h %02h %02h %02h %02h %02h %02h %02h | expect all 0x00 above byte %0d",
                         si, got_buf[52], got_buf[53], got_buf[54], got_buf[55],
                         got_buf[56], got_buf[57], got_buf[58], got_buf[59], n6);
                if (si == 0) begin
                    chk("X6a 20B wire complete+padFCS", ga === 1, "F2X11: on-wire len + crc32");
                    chk("X6a 20B RX tcrs=1 len=60",     gb === 1, "F2X11: self TX->RX contract");
                    chk("X6a 20B RX bytes==content+pad", gc === 1, "F2X11: content + zero pad");
                end else if (si == 1) begin
                    chk("X6b 42B wire complete+padFCS", ga === 1, "F2X11: on-wire len + crc32");
                    chk("X6b 42B RX tcrs=1 len=60",     gb === 1, "F2X11: self TX->RX contract");
                    chk("X6b 42B RX bytes==content+pad", gc === 1, "F2X11: content + zero pad");
                end else begin
                    chk("X6c 54B wire complete+padFCS", ga === 1, "F2X11: on-wire len + crc32");
                    chk("X6c 54B RX tcrs=1 len=60",     gb === 1, "F2X11: self TX->RX contract");
                    chk("X6c 54B RX bytes==content+pad", gc === 1, "F2X11: content + zero pad");
                end
            end
        end

        // =============================================================
        // 第 9 组 (P7B_CHAIN_COVERAGE): **lane4 注入** + RX 字几何 + TERM 六元组
        //   缺口 1: 旧门每帧都从字边界起 (xq_pack_words) ⇒ **只走 lane0**, lane4 分支
        //     从未被激励 —— 而 lane4 是 802.3 的另一个合法起点 (官方监视器只认这两个)。
        //     字几何缺陷 (SOP 字只有 4 字节 + 整帧偏 4 字节) 在旧判据下结构性隐身。
        //   缺口 2: TERM 六元组旧判据只查 3/6 (tkeep/tcrs/terr) ⇒ 本组把
        //     {tdata,tkeep,tlast,tuser,tcrs,terr} 六项**逐项**判 (TERM-2)。
        //   反例实测: P7B_MUT=<修复前 mac_rx_10g> ⇒ 本组 + SOP-1/SOP-2 变红 (日志见
        //     notes/p7b_chain_cov/logs/)。
        // =============================================================
        $display("==== G: lane4 injection + RX word geometry + TERM tuple ====");

        // ---- G1: lane4 起点, 内容 60..67 ⇒ /T/ 落 lane 4,5,6,7,0,1,2,3 **八档全覆盖**
        //      (60..64 含冲字支路 / tlast 回落; 65..67 正是 LANEFIX §3.4-5 点名的
        //       "/T/ 落 lane1/2/3 的 lane4 帧" 缺口)
        exp_reset;
        got_bytes = 0; got_frames = 0; got_len = 0; got_f_cnt = 0; got_started = 0;
        for (i = 0; i < 8; i = i + 1) begin
            xq_before = xq_wr;
            frame_lane = 4;
            build_frame(60 + i, 1'b0, -1);
            exp_add(60 + i, 0);
            // ⭐ /T/ 落位 = 从**本帧刚打包进队列的那些 XGMII 字**里扫 (c==1 && d==FD)。
            //   ⚠️ 不用 `u_dut.u_mac_rx.dbg_rx_last_tlane`: 实测它在 "tlast 回落到前一字"
            //      的三种情形 (lane4 帧 /T/@lane5/6/7) 恒报 8 = "本字无 /T/" (那是错的,
            //      见 [DEFECT-REG #2] 的读数)。⇒ 覆盖面判据只挂在**激励面**上。
            tl_obs[i] = -1;
            for (k = xq_before; k < xq_wr; k = k + 1)
                for (kk2 = 0; kk2 < 8; kk2 = kk2 + 1)
                    if (xq_c[k][kk2] === 1'b1 && xq_d[k][kk2*8 +: 8] === 8'hFD) tl_obs[i] = kk2;
            repeat (600) @(posedge u_dut.dp_clk);
            tl_dut[i] = u_dut.u_mac_rx.dbg_rx_last_tlane;   // DUT 自报 (仅诊断)
        end
        $display("  [G DIAG] lane4 sweep: got_f_cnt=%0d got_bytes=%0d (expect 8 frames / 508 bytes)",
                 got_f_cnt, got_bytes);
        for (i = 0; i < 8 && i < 128; i = i + 1)
            $display("  [G DIAG]   frame %0d: len=%0d bx=%0d sopk=%02h | /T/ lane stim=%0d dut=%0d (expect len=%0d bx=1 sopk=ff)",
                     i, got_f_len[i], got_f_bx[i], got_f_sopk[i], tl_obs[i], tl_dut[i], 60 + i);
        // [DEFECT-REG #2] (2026-09-30, 本门新判据扫出来的): `mac_rx_10g.dbg_rx_last_tlane`
        //   = `b_last ? f_tlane : t_lane_lo` —— 当 tlast **回落到前一字** (末字整字都是 FCS,
        //   即 /T/ 落 lane5/6/7) 时, 该拍 t_lane_lo 指的是**当前输入字**(无 /T/) ⇒ 恒报 8。
        //   实测: lane4 帧内容 61/62/63 (/T/ 真值 lane5/6/7) 报 dut=8, 其余五档正确。
        //   影响 = **零** (该网在 wrapper 里只有 `.dbg_rx_last_tlane(mrx_dbg_last_tlane)`,
        //   而 `mrx_dbg_last_tlane` 全仓无消费者 ⇒ 悬空网, 不进快照/不出板) —— 登记为
        //   "仪表会撒谎"类: 谁将来接它做板级判读, 必须先修这里 (取 f_tlane)。
        $display("  [DEFECT-REG #2] dbg_rx_last_tlane reports 8 on TLAST-fallback words (no consumer; dangling net)");
        for (i = 0; i < 8; i = i + 1) begin
            $sformat(gname, "G1.%0d lane4 content %0d byte-exact", i, 60 + i);
            chk(gname, (got_f_cnt === 8) && (got_f_bx[i] === 1),
                "injected byte array vs delivered buffer (lane4 rebase)");
        end
        chk("G1z lane4 sweep: 8 frames / 508 bytes / no ghost",
            (got_f_cnt === 8) && (got_bytes === 32'd508),
            "derived: sum(60..67) = 508");
        // G1c = **激励面覆盖性自检** (不是 DUT 判据): 8 档长度是否真的把 /T/ 落位扫遍
        //   lane0..7 —— 否则 "覆盖了 /T/@lane1/3" 只是推导, 不是实测。
        tlane_msk = 0;
        for (i = 0; i < 8; i = i + 1)
            if (tl_obs[i] >= 0 && tl_obs[i] < 8) tlane_msk = tlane_msk | (32'd1 << tl_obs[i]);
        chk("G1c lane4 sweep covers /T/ lanes 0..7",
            tlane_msk === 8'hFF, "stimulus coverage (injected XGMII words), content 60..67");

        // ---- G2: 两个**规范 lane4 帧背靠背** (跨帧半字交接: LANEFIX §3.4-3)
        exp_reset;
        got_bytes = 0; got_frames = 0; got_len = 0; got_f_cnt = 0;
        frame_lane = 4; build_frame(61, 1'b0, -1); exp_add(61, 0);
        frame_lane = 4; build_frame(62, 1'b0, -1); exp_add(62, 0);
        repeat (800) @(posedge u_dut.dp_clk);
        $display("  [G DIAG] lane4 b2b: got_f_cnt=%0d got_bytes=%0d bx=%0d/%0d",
                 got_f_cnt, got_bytes, got_f_bx[0], got_f_bx[1]);
        chk("G2a lane4 back-to-back: exactly 2 frames",
            got_f_cnt === 2, "derived: 2 injected lane4 frames");
        chk("G2b lane4 back-to-back: both byte-exact",
            (got_f_cnt === 2) && (got_f_bx[0] === 1) && (got_f_bx[1] === 1),
            "contract: cross-frame half-word handoff");
        chk("G2c lane4 back-to-back: 61+62 bytes",
            got_bytes === 32'd123, "derived: 61+62");

        // ---- G3: lane4 + F4 背压 (丢弃 / TERM / 恢复; LANEFIX §3.4-4 = 残余风险 R3)
        exp_reset;
        got_bytes = 0; got_frames = 0; got_len = 0; got_f_cnt = 0;
        gg0 = rx_term_n;  gg1 = rx_sop_bad_n;
        c0 = u_dut.rx_stat_drop_full + u_dut.rx_stat_drop_partial;
        force u_dut.rx_tready = 1'b0;
        for (j = 0; j < 40; j = j + 1) begin frame_lane = 4; build_frame(1514, 1'b0, -1); end
        repeat (6000) @(posedge u_dut.dp_clk);
        c1 = u_dut.rx_stat_drop_full + u_dut.rx_stat_drop_partial;
        release u_dut.rx_tready;
        repeat (6000) @(posedge u_dut.dp_clk);
        $display("  [G DIAG] lane4 F4: drop %0d->%0d, term %0d->%0d, sop_bad %0d->%0d",
                 c0, c1, gg0, rx_term_n, gg1, rx_sop_bad_n);
        chk("G3a lane4+F4: drops recorded",
            (c1 > c0) === 1'b1, "40 x 1514B lane4 against a 16-word FIFO, tready=0");
        chk("G3b lane4+F4: TERM closing word emitted",
            (rx_term_n > gg0) === 1'b1, "contract: aborted frame leaves no bare tail");
        chk("G3c lane4+F4: no new mis-aligned SOP word",
            (rx_sop_bad_n === gg1) === 1'b1, "every delivered SOP word stays full");
        // 恢复: 再注入一个 lane4 帧, 必须逐字节正确
        exp_reset;
        got_bytes = 0; got_frames = 0; got_len = 0; got_f_cnt = 0;
        frame_lane = 4; build_frame(63, 1'b0, -1); exp_add(63, 0);
        repeat (900) @(posedge u_dut.dp_clk);
        chk("G3d lane4+F4 recovery byte-exact",
            (got_f_cnt === 1) && (got_f_bx[0] === 1) && (got_f_sopk[0] === 8'hFF),
            "derived: 63B lane4 frame after the F4 window");

        // ---- G4: 跨全 run 的字几何 / TERM 判据 (分母 > 0 ⇒ 非真空) ----
        $display("  [G DIAG] SOP n=%0d bad=%0d | TLAST n=%0d | TERM n=%0d bad=%0d | tuple: d=%016h k=%02h l=%b u=%b c=%b e=%b",
                 rx_sop_n, rx_sop_bad_n, rx_tlast_n, rx_term_n, rx_term_bad_n,
                 rx_term_d, rx_term_k, rx_term_l, rx_term_u, rx_term_c, rx_term_e);
        chk("G4 SOP-1 every RX SOP word full-aligned",
            (rx_sop_n > 0) && (rx_sop_bad_n === 0),
            "contract mac_rx_10g.v:12 (tkeep[7]=1) - never checked before");
        chk("G4 SOP-2 SUM(SOP) == SUM(TLAST)",
            (rx_sop_n > 0) && (rx_sop_n === rx_tlast_n),
            "contract: every SOP word is closed by exactly one tlast (no bare tail)");
        chk("G4 TERM-1 TERM word present (nonvacuous)",
            rx_term_n >= 1, "contract mac_rx_10g.v:16");
        chk("G4 TERM-2 TERM six-tuple verbatim",
            (rx_term_n >= 1) && (rx_term_bad_n === 0),
            "contract mac_rx_10g.v:16 {tdata=0,tkeep=0,tlast=1,tuser=0,tcrs=0,terr=1}");

        release u_dut.txsrc_tdata;  release u_dut.txsrc_tkeep;
        release u_dut.txsrc_tvalid; release u_dut.txsrc_tlast;

        $display("==== tb_p7b_chain done: %0d checks, %0d fail ====", checks, fails);
        if (fails == 0) $display("VERDICT = PASS"); else $display("VERDICT = FAIL");
        $finish;
    end

    task snap_take;
        integer n;
        begin
            u_dut.u_pcie_xdma.axil_write(32'h18, 32'h1);
            n = 0;
            while (n < 4000) begin
                u_dut.u_pcie_xdma.axil_read(32'h1C, v);
                if (v[1] === 1'b1) n = 4000; else begin n = n + 1; @(posedge u_dut.pcie_axi_aclk); end
            end
        end
    endtask

    initial begin
        #8000000;
        $display("  [FAIL] WATCHDOG timeout (simulation did not finish)");
        $display("VERDICT = FAIL");
        $finish;
    end

endmodule
