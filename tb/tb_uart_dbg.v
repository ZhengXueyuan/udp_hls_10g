`timescale 1ns/1ps
// tb_uart_dbg.v — uart_dbg 单元测试: dbg_line_tx + uart_tx_9600 (参数提速版)
// 校验: ①复位后 run=0 期间线保持空闲高; ②run 后第 1 行 368 字节 ASCII 逐字节
// 等于期望串 (9600 中点采样解码); ③行间空线 (GAP 生效) 后第 2 行
// 重复且 TXST/RXST/ACC/EMV/EST/FFE/WPT/RPT/PF/TV/PV/SV/PLEN/TW/TF/TI/
// PW/PR/PFL/PEM/PLN/RXPL/RXPC/RXT/DROPS/PASS/WL 为行首新快照 (mid-line 改输入
// 不影响本行); ④末尾 CR LF。
//
// P4b-7-P6 扩展: 行 366 可打印字符 (117→146→182→216→301→358→366), RX 侧冻结位点字段
// (RXST/ACC/EMV/EST/FFE/WPT/RPT) + TX 输入侧握手链字段 (PF/TV/PV/SV/PLEN,
// tcp_tx_frame pay_full/s_axis_tvalid + u_eco_pipe m_valid/s_valid + plen_r)
// + tlast 三计数 (TW/TF/TI, tcp_echo 写/转发 + tcp_tx_frame 吞到末拍)
// + u_fifo 指针/标志 (PW/PR/PFL/PEM: 载荷 FIFO wptr/rptr[8:0] + full/empty,
//   报 FULL 而单帧仅 183 字时用占用字数判真满/指针异常) + PLN (RUNNING plen,
//   区别于 PLEN=plen_r),
// P6 第二轮追加 (行尾 RXPL..PASS): RX 侧帧判读锁存 (plen_l = IP total_len-40,
//   疑腐败 → over-length 守卫帧中段 S_DROP 断尾 → TX 永久等 tlast)、pcount、
//   原始 total_len 字段 w2_r[63:48] + 五路丢弃/通过计数 (哪一路随帧速率递增
//   = 该判据持续触发)。计数类按定宽 8 位 hex 打印 (32 位十进制定宽 = 10 位/
//   字段, 行宽与时序不值; hex 值本身精确无损)。
// 以上字段与 TXST 同语义 — 每行行首重采一次。
// 注: exp1/exp2 字符串由行格式 (wrapper_p4 头注释) 用 Python 渲染生成 —
//     与 RTL 字符位置表相互独立, 逐字节比对即验证位置表无漂移。
//
// P4b-7-P6 TRACE 扩展 (第三轮): tr_run=1 后每轮 = 快照行 + 4 行 TR; TR 行
// 期望值由 TB 侧独立算式 (exp_trc: 字 g=(lno-1)*16+tid → 环址 (wptr-63+g)&63
// → 镜像数组 rt[]) 逐字符生成 — 与 RTL 的 tid/tph 计数 + 预取寄存器实现相互
// 独立, 逐字节比对即验证环序/回卷/位序无漂移。第 3 轮快照行内容应与第 2 轮
// 完全一致 (mid-line 改写后输入未再变), 复用 exp2 比对。
//
// P4b-7-P6 TL 扩展 (第四轮): run=1 时每轮快照行 (+ TR 行) 之后追加 8 行 TL
// (每行 21 字符 = "TL=" + 8 字节 hex + CR LF):
//   行 k 字节 j = 边存址 (rptr-32+8k+j)&4095 的 tlast, 打印 00/01。
// TB 侧模型: 边存镜像 tlm[0:4095] (bit8 = (a%13==5), 周期 13 与 8/64 互素 →
// 任何址序/位序错位都会把 1 挪到别的字节位置, 肉眼+逐字节双重可见);
// dbg_rd_addr (DUT 输出) → tlm 组合读出 → dbg_rd_side (DUT 输入) 模拟
// frame_fifo 边存组合读口。期望值 exp_tl 由 TB 侧独立算式 (rpt_exp 基址 +
// 8k+j) 逐字符生成 — 与 RTL 的 tl_base/tl_g 读引擎 + tl_char 位置表相互独立。
// 覆盖: 第 1/2 轮 run=1&tr_run=0 (快照 + 8 TL, 基址 = mid-line 改写后的 456);
// 第 3 轮 run=1&tr_run=1 (快照 + 4 TR + 8 TL), 且 TL 前把 rpt 改为 010 →
// 基址 010-32 = FF0 (12 位回卷) 专测回卷; 第 4 轮 run=0&tr_run=1 → 无 TL
// (run 门控: 无锁存拍即无 rptr 基准), 行序 = 4 TR 后回 GAP (隐含无第 5 行)。
//
// P4b-7-P6 三站词计数扩展 (第七轮): 快照行尾追加 " MW=%08X CW=%08X/%08X
//   RW=%08X WC=%d" (50 字符, 行宽 310 → 360); 新输入 mw/cwi/cwo/rw/wc 与
//   其它实时字段同语义 (每行行首重采 — 第 1 行初值 / 第 2 行 mid-line 改写值,
//   证明行首锁存)。WC = 3 位 wcnt (0..7), 其余 32 位计数按 %08X。
// P4b-7-P6 RX-TRACE 扩展 (第五/六轮 + 第七轮加宽): 快照行尾追加 RXTR=%d 标志,
//   行序在 TL 段之后追加 4 行 RXT (134 字符 = "RXT=" + 16 字 × 7 hex + 空格
//   + CR LF, 与 TR 同构但前缀 4 字符、字宽 7 位 hex)。第 5 轮 run=1&tr_run=0&
//   rxt_run=1 → 快照 (RXTR=1) + 8 TL + 4 RXT; 第 6 轮 run=0&tr_run=0&
//   rxt_run=1 → 直发 4 RXT (S_IDLE 起点分支) 后回 GAP。
//   RXT 期望值由 TB 侧独立算式 exp_rxt (环址 (rxwp-63+g)&63 → 镜像 rxrt[])
//   逐字符生成 — RXT 环图案 (高位 wcnt = aa[2:0] + 固定 nibble 5A_CAB, 其中
//   第 4 位 = aa[5:4]) 与 TR 环 (BEEF/24 位) 全不同, wptr 亦不同 (23/10):
//   取错环/错 wptr/错字相位/错位宽 (24 vs 27) 都会逐字节失配。图案含 aa 全部
//   6 位 (7 hex 数字 = wcnt(3) + 5A?CAB 固定 nibble + aa[3:0]) → 64 个环址打印
//   两两不同, ±16/±32/±48 的整体址错位也逐字节可见 (16 周期图案会掩盖)。
//
// P4b-7-P6-P6b WL 扩展 (线上帧长, 行宽 360 → 368): 快照行**最末**追加
//   " WL=%04X" (8 字符, pos 358..365; CR 366 / LF 367), 输入 rx_wire_last =
//   wrapper_p4 异常触发拍锁存的线上帧字节数 (phy1_rxc 域 RX_CTL 高电平拍数 x8;
//   判别 66 字节短帧 (PC 侧) vs 1514 字节整帧被吞 (FPGA 侧))。
//   与其它实时字段同语义 (行首重采): 行 1 = 初值 0042 (66), 行 2 = mid-line
//   改写值 05EA (1514) — 8 个字符 (空格 W L = 4 hex) 逐字节比对覆盖字段位置、
//   大写、'=' 与 4 位 hex 高位在前 (两值 nibble 全不同 → 取错拍/取错字节序/
//   漏首字符都会失配); CR/LF 位置同步后移 (366/367), 行宽/SNAP_M1 错则整行失配。
module tb_uart_dbg;
    reg clk = 0;
    always #4 clk = ~clk;                    // 125 MHz

    localparam [13:0] BITL = 14'd79;         // 80 拍/位 (提速, 帧结构不变)
    localparam [29:0] GAPL = 30'd80_000;     // 行间 80k 拍 (提速)
    localparam        HALF = 40;             // 半位
    localparam        PER  = 80;             // 每 bit 拍数 (BITL+1)

    reg         rst_n;
    reg         run = 1'b0;  // 声明即清零 — 防止 t=0 时 X 使 while(!run) 等待块
                             // 立即误退出 (xsim 多 initial 同拍竞态, 实测踩坑)
    reg         trun = 1'b0; // tr_run (trace_frozen): 第三轮拉高
    reg  [5:0]  twp  = 6'd10;        // trace_wptr (下一写址 = 最老条目址)
    reg  [1535:0] tring = 1536'd0;   // trace_ring (64 x 24b 展平)
    reg  [23:0] rt [0:63];           // TB 侧环镜像 (期望值算式用)
    // P4b-7-P6 RX-TRACE: 第二环 (RXT 行) — 独立 wptr/图案, 与 TR 环交叉验证
    reg         rxtrun = 1'b0;       // rxt_run (rx_trace_frozen)
    reg  [5:0]  rxwp  = 6'd23;       // rxt_wptr (与 twp 不同, 混用即失配)
    reg  [1727:0] rxtring = 1728'd0; // rxt_ring (64 x 27b 展平)
    reg  [26:0] rxrt [0:63];         // TB 侧 RX 环镜像
    reg  [31:0] nx, ua;
    reg  [15:0] wn, inf, eff;
    reg  [3:0]  ws, st, lv;
    reg  [2:0]  ts;                          // tx FSM state
    reg  [2:0]  rxs;                         // rx FSM state
    reg         acc, emv;                    // rx accept / emit_v
    reg  [2:0]  est;                         // echo FSM state
    reg         ff, fe;                      // fifo full / empty
    reg  [11:0] wpt, rpt;                    // fifo wptr / rptr
    reg         pf, tv, pv, sv;              // P4b-7-P6: tx pay_full /
                                             // s_axis_tvalid / pipe m/s_valid
    reg  [11:0] plen;                        // P4b-7-P6: tx plen_r
    reg  [31:0] tw, tf, ti;                  // P4b-7-P6: tlast 三计数 (echo 写/
                                             // 转发 + 帧器吞到末拍)
    reg  [8:0]  pw, pr;                      // P4b-7-P6: u_fifo wptr/rptr[8:0]
    reg         pfl, pem;                    // P4b-7-P6: u_fifo full / empty
    reg  [11:0] pln;                         // P4b-7-P6: tx RUNNING plen
    reg  [15:0] rpl, rpc, rwt;               // P4b-7-P6 追加: rx {plen_l,pcount,w2_tlen}
    reg  [31:0] dsq, dcr, dnm, dip, pss;     // P4b-7-P6 追加: rx 丢弃/通过五计数
    reg  [31:0] mw, cwi, cwo, rw;            // 三站词计数 (mac 出 / cls 进/出 / rx 进)
    reg  [2:0]  wc;                          // tcp_rx wcnt (头字计数器)
    reg  [15:0] wl;                          // P4b-7-P6-P6b: 线上帧长 (WL 字段)
    wire        txd;
    // P4b-7-P6 TL: 边存读口 (DUT 出址, TB 镜像数组组合出值) + 期望基址
    reg  [8:0]  tlm [0:4095];                // 边存镜像 (bit8 = tlast, a%13==5)
    wire [11:0] tl_addr;                     // DUT dbg_rd_addr (读引擎址)
    wire [8:0]  tl_side = tlm[tl_addr];      // 组合读回 DUT dbg_rd_side
    reg  [11:0] rpt_exp;                     // TB 侧 rpt 基准 (exp_tl 用)

    dbg_line_tx #(.BIT_LAST(BITL), .GAP_LAST(GAPL)) uut (
        .clk(clk), .rst_n(rst_n), .run(run),
        .snd_nxt(nx), .snd_una(ua), .snd_wnd(wn),
        .wscale(ws), .tcb_state(st), .latch_val(lv),
        .win_inflight(inf), .win_wnd_eff(eff),
        .tx_state(ts), .rx_state(rxs),
        .rx_accept(acc), .rx_emitv(emv),
        .echo_state(est), .fifo_full(ff), .fifo_empty(fe),
        .fifo_wptr(wpt), .fifo_rptr(rpt),
        .tx_pay_full(pf), .tx_saxis_tv(tv),
        .pipe_mv(pv), .pipe_sv(sv),
        .tx_plen_r(plen),
        .tlast_wr(tw), .tlast_fwd(tf), .tlast_in(ti),
        .pay_wptr(pw), .pay_rptr(pr),
        .pay_full2(pfl), .pay_empty(pem),
        .tx_plen(pln),
        .rx_plen_l(rpl), .rx_pcount(rpc), .rx_w2_tlen(rwt),
        .rx_drop_seq(dsq), .rx_drop_crc(dcr), .rx_drop_nonmatch(dnm),
        .rx_drop_ipcsum(dip), .rx_pass(pss),
        .mac_words_out(mw), .cls_words_in(cwi), .cls_words_out(cwo),
        .rx_words_in(rw), .rx_wcnt(wc),
        .trace_ring(tring), .trace_wptr(twp), .tr_run(trun),
        .rxt_ring(rxtring), .rxt_wptr(rxwp), .rxt_run(rxtrun),
        .rx_wire_last(wl),
        .dbg_rd_addr(tl_addr), .dbg_rd_side(tl_side),
        .txd(txd)
    );

    integer errs;
    integer i, k, l, aa;
    integer idlec;
    reg [7:0] g1 [0:371];
    reg [7:0] g2 [0:371];
    reg [7:0] eb [0:371];

    // ---- 解码一行: 等 start 沿 (空闲后首见低) → d0 中点 → 逐字符采 8 位 +
    //      stop 位高检查; 字符间距 = uart 停位结束 + 1 拍握手气泡 = 2*PER+1 ----
    task decode_line;
        input integer nch;
        integer kk, ii;
        begin
            while (txd) @(posedge clk);
            repeat(HALF + PER) @(posedge clk);
            for (kk = 0; kk < nch; kk = kk + 1) begin
                for (ii = 0; ii < 8; ii = ii + 1) begin
                    g1[kk][ii] = txd;
                    if (ii != 7) repeat(PER) @(posedge clk);
                end
                repeat(PER) @(posedge clk);
                if (txd !== 1'b1) begin
                    $display("FAIL: 行内 char%0d stop 位为低", kk);
                    errs = errs + 1;
                end
                if (kk != nch - 1) repeat(2 * PER + 1) @(posedge clk);
            end
        end
    endtask

    // ---- 等下一次起始沿并统计空线拍数 (idlec): 正常行间 ~800 拍, GAP 后 ~80k ----
    task wait_gap;
        begin
            idlec = 0;
            while (txd) begin
                @(posedge clk);
                idlec = idlec + 1;
            end
        end
    endtask

    // ---- TR 行期望字符 (独立算式实现, 见头注释) ----
    function [7:0] hexd;                     // nibble → ASCII
        input [3:0] n;
        begin
            hexd = (n < 4'd10) ? (8'h30 + {4'b0, n}) : (8'h37 + {4'b0, n});
        end
    endfunction

    function [7:0] exp_trc;
        input [3:0] lno;
        input [8:0] pos;
        integer kk, tt, pp, gg, aad;
        reg [23:0] wd;
        begin
            if (pos == 9'd0)        exp_trc = 8'h54;       // 'T'
            else if (pos == 9'd1)   exp_trc = 8'h52;       // 'R'
            else if (pos == 9'd2)   exp_trc = 8'h3D;       // '='
            else if (pos == 9'd115) exp_trc = 8'h0D;       // CR
            else if (pos == 9'd116) exp_trc = 8'h0A;       // LF
            else begin
                kk = pos - 3;                  // 0..111
                tt = kk / 7;                   // 字号 0..15
                pp = kk % 7;                   // 字内相 0..6 (6 = 空格)
                gg = (lno - 1) * 16 + tt;
                aad = (twp - 63 + gg) % 64;    // 环址 (mod 64)
                if (aad < 0) aad = aad + 64;
                wd = rt[aad];
                if (pp < 6) exp_trc = hexd(wd[23 - 4*pp -: 4]);
                else        exp_trc = 8'h20;
            end
        end
    endfunction

    // ---- TL 行期望字符 (独立算式: 基址 rpt_exp-32 (12 位回卷) + 8k+j → 镜像) ----
    function [7:0] exp_tl;
        input [3:0] k;                         // 行内组号 0..7 (lno-5)
        input [8:0] pos;
        integer u, j, aad;
        begin
            if      (pos == 9'd0)  exp_tl = 8'h54;     // 'T'
            else if (pos == 9'd1)  exp_tl = 8'h4C;     // 'L'
            else if (pos == 9'd2)  exp_tl = 8'h3D;     // '='
            else if (pos == 9'd19) exp_tl = 8'h0D;     // CR
            else if (pos == 9'd20) exp_tl = 8'h0A;     // LF
            else begin
                u   = pos - 9'd3;                  // 0..15
                j   = u / 2;                       // 字节号 0..7
                aad = (rpt_exp - 12'd32 + k * 8 + j) & 12'hFFF;
                if ((u % 2) == 0) exp_tl = 8'h30;              // 高 nibble '0'
                else              exp_tl = tlm[aad][8] ? 8'h31 : 8'h30;
            end
        end
    endfunction

    // ---- RXT 行期望字符 (独立算式: 环址 (rxwp-63+g)&63 → 镜像 rxrt[];
    //      前缀 4 字符 (pos 0..3) → 字相位 = (pos-4) % 8 (7 hex + 1 空格),
    //      与 DUT 的 tph 初值 7 技巧相互独立验证):
    //      27 位字按 7 位 hex 转储 — 第 1 个 hex 数字 = {1'b0, wd[26:24]}
    //      (3 位 wcnt 零扩展), 余 6 数字 = wd[23:0] 逐 nibble ----
    function [7:0] exp_rxt;
        input [4:0] lno;
        input [8:0] pos;
        integer kk, tt, pp, gg, aad;
        reg [26:0] wd;
        begin
            if (pos == 9'd0)        exp_rxt = 8'h52;       // 'R'
            else if (pos == 9'd1)   exp_rxt = 8'h58;       // 'X'
            else if (pos == 9'd2)   exp_rxt = 8'h54;       // 'T'
            else if (pos == 9'd3)   exp_rxt = 8'h3D;       // '='
            else if (pos == 9'd132) exp_rxt = 8'h0D;       // CR
            else if (pos == 9'd133) exp_rxt = 8'h0A;       // LF
            else begin
                kk = pos - 4;                  // 0..127
                tt = kk / 8;                   // 字号 0..15
                pp = kk % 8;                   // 字内相 0..7 (7 = 空格)
                gg = (lno - 13) * 16 + tt;
                aad = (rxwp - 63 + gg) % 64;   // 环址 (mod 64)
                if (aad < 0) aad = aad + 64;
                wd = rxrt[aad];
                if (pp == 0)     exp_rxt = hexd({1'b0, wd[26:24]});
                else if (pp < 7) exp_rxt = hexd(wd[27 - 4*pp -: 4]);
                else             exp_rxt = 8'h20;
            end
        end
    endfunction

    // ---- 解码 1 行 TL (21 字符) 并逐字节比对期望 ----
    integer tk;
    task chk_tl;
        input [3:0] kk;                        // 行内组号 0..7
        begin
            decode_line(21);
            for (tk = 0; tk < 21; tk = tk + 1)
                if (g1[tk] !== exp_tl(kk, tk[8:0])) begin
                    $display("FAIL: TL k%0d char%0d got %02X want %02X",
                             kk, tk, g1[tk], exp_tl(kk, tk[8:0]));
                    errs = errs + 1;
                end
            $display("TL k%0d: ", kk);
            for (tk = 0; tk < 21; tk = tk + 1) $write("%c", g1[tk]);
            $write("\n");
        end
    endtask

    // ---- 解码 1 行 RXT (134 字符) 并逐字节比对期望 ----
    task chk_rxt;
        input [4:0] l;                         // 行号 13..16
        begin
            decode_line(134);
            for (tk = 0; tk < 134; tk = tk + 1)
                if (g1[tk] !== exp_rxt(l, tk[8:0])) begin
                    $display("FAIL: RXT l%0d char%0d got %02X want %02X",
                             l, tk, g1[tk], exp_rxt(l, tk[8:0]));
                    errs = errs + 1;
                end
            $display("RXT l%0d: ", l);
            for (tk = 0; tk < 134; tk = tk + 1) $write("%c", g1[tk]);
            $write("\n");
        end
    endtask
    // 期望行 (固定向量, 由行格式用 Python 渲染生成 — 与 RTL 字符位置表相互
    // 独立; 366 可打印字符 + CR LF):
    //   nx=FEDCBA98 ua=01234567 wn=8BAD ws=F st=5 lv=1011 inf=1001 eff=2FFE
    //   TXST 行1=3 (行中改 7 不影响本行) 行2=7 (行首重采)
    //   RXST 行1=1(S_PAY) 行2=2(S_PAD)  ACC 1→0  EMV 0→1  EST 1→0
    //   FFE 10→01  WPT ABC→DEF  RPT 123→456
    //   PF 1→0 (tx pay_full)  TV 0→1 (s_axis_tvalid)  PV 1→0 (pipe m_valid)
    //   SV 1→0 (pipe s_valid)  PLEN 22F→345 (tx plen_r)
    //   TW 11111111→12345678  TF 22222222→9ABCDEF0  TI 44444444→0F0F0F0F
    //   PW 0A5→1B6 (u_fifo wptr[8:0], bit8 两态都走)  PR 0C3→1D4 (u_fifo rptr)
    //   PFL 1→0 (u_fifo full)  PEM 0→1 (u_fifo empty)  PLN 123→4AB (running plen)
    //   RXPL 0123→ABCD (plen_l)  RXPC 0456→CDEF (pcount)  RXT 0789→EF01 (w2_tlen)
    //   DROPS 0000000A/0000000B/0000000C/0000000D → 11223344/55667788/99AABBCC/
    //         DDEEFF00 (drop_seq/crc/nonmatch/ipcsum)
    //   PASS 0000000E→0F1E2D3C (stat_pass)
    // 注: xsim 把字符串字面量里的 \r 存成 0x72('r') 而非 0x0D, 故期望串不含
    // 转义, 只含 366 个可打印字符; 行尾 CR LF 单独用 0x0D/0x0A 显式核对。
    // 行尾三站词计数: 行 1 = 初值 (mw/cwi/cwo/rw = 1/2/3/4, wc=1), 行 2 =
    // mid-line 改写值 (11/22/33/44, wc=5) — 与其它实时字段同行首锁存语义。
    reg [2927:0] exp1 = "NX=FEDCBA98 UA=01234567 WN=8BAD WS=F ST=5 W=1011 I=1001 E=2FFE TXST=3 RXST=1 ACC=1 EMV=0 EST=1 FFE=10 WPT=ABC RPT=123 PF=1 TV=0 PV=1 SV=1 PLEN=22F TW=11111111 TF=22222222 TI=44444444 PW=0A5 PR=0C3 PFL=1 PEM=0 PLN=123 RXPL=0123 RXPC=0456 RXT=0789 DROPS=0000000A/0000000B/0000000C/0000000D PASS=0000000E RXTR=0 MW=00000001 CW=00000002/00000003 RW=00000004 WC=1 WL=0042";
    reg [2927:0] exp2 = "NX=FEDCBA98 UA=01234567 WN=8BAD WS=F ST=5 W=1011 I=1001 E=2FFE TXST=7 RXST=2 ACC=0 EMV=1 EST=0 FFE=01 WPT=DEF RPT=456 PF=0 TV=1 PV=0 SV=0 PLEN=345 TW=12345678 TF=9ABCDEF0 TI=0F0F0F0F PW=1B6 PR=1D4 PFL=0 PEM=1 PLN=4AB RXPL=ABCD RXPC=CDEF RXT=EF01 DROPS=11223344/55667788/99AABBCC/DDEEFF00 PASS=0F1E2D3C RXTR=0 MW=00000011 CW=00000022/00000033 RW=00000044 WC=5 WL=05EA";

    // ---- mid-line 输入改写 (第 1 行发送途中; 行首快照不应受影响) ----
    initial begin
        while (!run) @(posedge clk);        // 等主流程置 run
        repeat(25_000) @(posedge clk);      // 第 1 行 (368 字 ~295k 拍) 中段
        ts  = 3'd7;
        rxs = 3'd2; acc = 1'b0; emv = 1'b1;
        est = 3'd0; ff = 1'b0; fe = 1'b1;
        wpt = 12'hDEF; rpt = 12'h456;       // 只应影响第 2 行
        pf = 1'b0; tv = 1'b1; pv = 1'b0; sv = 1'b0;
        plen = 12'h345;
        tw = 32'h12345678; tf = 32'h9ABCDEF0; ti = 32'h0F0F0F0F;
        pw = 9'h1B6; pr = 9'h1D4; pfl = 1'b0; pem = 1'b1; pln = 12'h4AB;
        rpl = 16'hABCD; rpc = 16'hCDEF; rwt = 16'hEF01;
        rpt_exp = 12'h456;                  // 第 1/2 轮 TL 期望基址源 (= rpt-32)
        dsq = 32'h11223344; dcr = 32'h55667788;
        dnm = 32'h99AABBCC; dip = 32'hDDEEFF00; pss = 32'h0F1E2D3C;
        mw = 32'h00000011; cwi = 32'h00000022; cwo = 32'h00000033;
        rw = 32'h00000044; wc = 3'd5;
        wl = 16'h05EA;                      // WL 行 2 = 1514 (整帧判别值; 0042→05EA
                                            //  两 nibble 全变 → 行首锁存逐字节可见)
    end

    // ---- 主流程 ----
    initial begin
        rst_n = 0; run = 0;
        nx = 32'hFEDCBA98; ua = 32'h01234567; wn = 16'h8BAD;
        ws = 4'hF; st = 4'h5; lv = 4'b1011;
        inf = 16'h1001; eff = 16'h2FFE;
        ts = 3'd3;
        rxs = 3'd1; acc = 1'b1; emv = 1'b0;
        est = 3'd1; ff = 1'b1; fe = 1'b0;
        wpt = 12'hABC; rpt = 12'h123;
        pf = 1'b1; tv = 1'b0; pv = 1'b1; sv = 1'b1;
        plen = 12'h22F;
        tw = 32'h11111111; tf = 32'h22222222; ti = 32'h44444444;
        pw = 9'h0A5; pr = 9'h0C3; pfl = 1'b1; pem = 1'b0; pln = 12'h123;
        rpl = 16'h0123; rpc = 16'h0456; rwt = 16'h0789;
        dsq = 32'h0000000A; dcr = 32'h0000000B;
        dnm = 32'h0000000C; dip = 32'h0000000D; pss = 32'h0000000E;
        mw = 32'h00000001; cwi = 32'h00000002; cwo = 32'h00000003;
        rw = 32'h00000004; wc = 3'd1;
        wl = 16'h0042;                   // WL 行 1 = 66 (短帧判别值)
        errs = 0; idlec = 0;
        // TRACE 环图案: entry(a) = {16'hBEEF, a[5:0], 2'b00} → hex "BEEF" +
        // (a*4 两位) — 环址在字面可读 (低两位 hex / 4 = 环址), 且逐条唯一
        for (aa = 0; aa < 64; aa = aa + 1) begin
            rt[aa] = {16'hBEEF, aa[5:0], 2'b00};
            tring[24*aa +: 24] = rt[aa];
        end
        twp = 6'd10;                     // 最老条目址 = (10-63+g)&63 = (g+11)&63
        // RXT 环图案 (27 位): {wcnt=aa[2:0], 1'b0, 4'h5, 4'hA, 4'hC, aa[5:4],
        //   4'hB, aa[3:0]} — 打印为 "<aa[2:0]>5AC<aa[5:4]>B<aa[3:0]>", 含 aa
        //   全部 6 位 → 64 环址打印两两不同 (16 周期图案会掩盖 ±16 的整址错位);
        //   与 TR 环 (BEEF/24 位) 全不同, 两环 wptr 不同 (10/23) → 取错环/错
        //   wptr/错位宽 (24 vs 27) 都会逐字节失配
        for (aa = 0; aa < 64; aa = aa + 1) begin
            rxrt[aa] = {aa[2:0], 1'b0, 4'h5, 4'hA, 4'hC, aa[5:4], 4'hB, aa[3:0]};
            rxtring[27*aa +: 27] = rxrt[aa];
        end
        rxwp = 6'd23;                    // 最老条目址 = (23-63+g)&63 = (g+24)&63
        // TL 边存镜像: bit8 (tlast) = (a%13==5) — 周期 13 与 8/64 互素, 任何址序
        // /位序错位都把 1 挪到其它字节位置 (打印可肉眼见 + 逐字节比对)
        for (aa = 0; aa < 4096; aa = aa + 1) tlm[aa] = {((aa % 13) == 5), 8'b0};
        rpt_exp = 12'h456;               // TL 期望基址源 = mid-line 改写后的 rpt
                                         // (改写 ~25k 拍 << 快照行末 243k, 故第 1
                                         //  轮 TL 突发时 DUT rpt 已是 456)

        repeat(300) @(posedge clk);
        rst_n = 1;
        repeat(500) @(posedge clk);
        if (txd !== 1'b1) begin
            $display("FAIL: 空闲期 txd 非高 (run=0 不应发送)");
            errs = errs + 1;
        end
        run = 1'b1;                         // 模块下一 posedge 起发第 1 行

        // ===== 第 1 行解码 (行首 = 空闲后的第一个下降沿) =====
        while (txd) @(posedge clk);         // 停在 start 沿 (首见低)
        repeat(HALF + PER) @(posedge clk);  // 到 d0 中点
        for (k = 0; k < 368; k = k + 1) begin
            for (i = 0; i < 8; i = i + 1) begin
                g1[k][i] = txd;
                if (i != 7) repeat(PER) @(posedge clk);
            end
            repeat(PER) @(posedge clk);     // 到 stop 中点
            if (txd !== 1'b1) begin
                $display("FAIL: 第 1 行 char%0d stop 位为低", k);
                errs = errs + 1;
            end
            // 字符间距 801 拍 (uart 停位结束->下一 start 有 1 拍握手气泡)
            if (k != 367) repeat(2 * PER + 1) @(posedge clk);
        end

        for (i = 0; i < 366; i = i + 1) eb[i] = exp1[2927 - 8 * i -: 8];
        $display("L1 decoded: ");
        for (i = 0; i < 368; i = i + 1) $write("%c", g1[i]);
        $write("\n");
        for (i = 0; i < 366; i = i + 1)
            if (g1[i] !== eb[i]) begin
                $display("FAIL: L1 char%0d got %02X want %02X (%c)",
                         i, g1[i], eb[i], (g1[i] < 8'h20) ? 8'h2E : g1[i]);
                errs = errs + 1;
            end
        if ((g1[366] !== 8'h0D) || (g1[367] !== 8'h0A)) begin
            $display("FAIL: L1 行尾 got %02X %02X (expect 0D 0A)", g1[366], g1[367]);
            errs = errs + 1;
        end
        $display("L1 last two bytes: %02X %02X (expect 0D 0A)", g1[366], g1[367]);

        // ===== 第 1 轮 8 行 TL (run=1 & tr_run=0: 快照行后直接 TL 突发) =====
        // 基址 = rpt-32 = 456-32 = 436 (无回卷); 行 k(=lno-5) 字节 j = 址 436+8k+j
        for (l = 0; l < 8; l = l + 1) chk_tl(l[3:0]);
        $display("L1 TL burst done (8 lines ok)");

        // ===== 行间空线 + 第 2 行 (重复发送) =====
        while (txd) begin                   // 空线直到第 2 行 start 沿
            @(posedge clk);
            idlec = idlec + 1;
        end
        if (idlec < 10_000) begin
            $display("FAIL: 行间空线仅 %0d 拍 (GAP 未生效?)", idlec);
            errs = errs + 1;
        end
        repeat(HALF + PER) @(posedge clk);
        for (k = 0; k < 368; k = k + 1) begin
            for (i = 0; i < 8; i = i + 1) begin
                g2[k][i] = txd;
                if (i != 7) repeat(PER) @(posedge clk);
            end
            repeat(PER) @(posedge clk);
            if (txd !== 1'b1) begin
                $display("FAIL: 第 2 行 char%0d stop 位为低", k);
                errs = errs + 1;
            end
            if (k != 367) repeat(2 * PER + 1) @(posedge clk);
        end
        // 第 2 行实时字段应为行首新值 (TXST=7 RXST=2 ACC=0 EMV=1 EST=0
        // FFE=01 WPT=DEF RPT=456 PF=0 TV=1 PV=0 SV=0 PLEN=345
        // TW=12345678 TF=9ABCDEF0 TI=0F0F0F0F
        // PW=1B6 PR=1D4 PFL=0 PEM=1 PLN=4AB
        // RXPL=ABCD RXPC=CDEF RXT=EF01
        // DROPS=11223344/55667788/99AABBCC/DDEEFF00 PASS=0F1E2D3C
        // WL=05EA (P4b-7-P6-P6b 线上帧长: 0042=66 → 05EA=1514, 行首重采))
        for (i = 0; i < 366; i = i + 1) eb[i] = exp2[2927 - 8 * i -: 8];
        $display("L2 decoded: ");
        for (i = 0; i < 368; i = i + 1) $write("%c", g2[i]);
        $write("\n");
        for (i = 0; i < 366; i = i + 1)
            if (g2[i] !== eb[i]) begin
                $display("FAIL: L2 char%0d got %02X want %02X", i, g2[i], eb[i]);
                errs = errs + 1;
            end
        if ((g2[366] !== 8'h0D) || (g2[367] !== 8'h0A)) begin
            $display("FAIL: L2 行尾 got %02X %02X (expect 0D 0A)", g2[366], g2[367]);
            errs = errs + 1;
        end
        $display("L1 idle gap = %0d cycles", idlec);

        // ===== 第 2 轮 8 行 TL (rpt 未再变 → 期望与第 1 轮逐字节相同) =====
        for (l = 0; l < 8; l = l + 1) chk_tl(l[3:0]);
        $display("L2 TL burst done (8 lines ok)");

        // ===== 第 3 轮: tr_run=1 → 一轮 = 快照行 + 4 行 TR + 8 行 TL (突发) =====
        trun = 1'b1;                        // trace_frozen 锁存 (第 2 轮 TL 后 GAP 中)
        wait_gap;
        if (idlec < 10_000) begin
            $display("FAIL: TR 轮前空线仅 %0d 拍 (GAP 未生效?)", idlec);
            errs = errs + 1;
        end
        // 快照行: 输入自 mid-line 改写后未再变 → 内容应与第 2 行逐字节一致
        decode_line(368);
        for (i = 0; i < 366; i = i + 1) eb[i] = exp2[2927 - 8 * i -: 8];
        $display("L3 (TR 轮快照行, 期望 = exp2): ");
        for (i = 0; i < 368; i = i + 1) $write("%c", g1[i]);
        $write("\n");
        for (i = 0; i < 366; i = i + 1)
            if (g1[i] !== eb[i]) begin
                $display("FAIL: L3 char%0d got %02X want %02X", i, g1[i], eb[i]);
                errs = errs + 1;
            end
        if ((g1[366] !== 8'h0D) || (g1[367] !== 8'h0A)) begin
            $display("FAIL: L3 行尾 got %02X %02X (expect 0D 0A)", g1[366], g1[367]);
            errs = errs + 1;
        end
        // -- 第 3 轮 TL 基址改为 rpt=010 (基址 010-32 = FF0, 12 位回卷专测) —
        // 改点在快照行之后 (TR 行不用 rpt; TL 基址在 TR4 行末才锁存, 故生效)
        rpt = 12'h010; rpt_exp = 12'h010;
        // 4 行 TR (每行 117 字符 = "TR=" + 16 字 × 6 hex + 空格 + CR LF)
        for (l = 1; l <= 4; l = l + 1) begin
            decode_line(117);
            for (k = 0; k < 117; k = k + 1)
                if (g1[k] !== exp_trc(l[3:0], k[8:0])) begin
                    $display("FAIL: TR%0d char%0d got %02X want %02X",
                             l, k, g1[k], exp_trc(l[3:0], k[8:0]));
                    errs = errs + 1;
                end
            $display("TR%0d: ", l);
            for (k = 0; k < 117; k = k + 1) $write("%c", g1[k]);
            $write("\n");
        end
        // ===== 第 3 轮 8 行 TL (TR4 后, 基址 FF0 回卷) =====
        for (l = 0; l < 8; l = l + 1) chk_tl(l[3:0]);
        $display("L3 TL burst done (base FF0 回卷, 8 lines ok)");
        // 8 行 TL 后应回 GAP (证明行序终止, 无第 9 行); run 随置 0 —
        // 此刻模块仍在 TL8 后的 S_GAP 内 (TL8 的 LF 已入 uart), 下一轮起
        // 走 run=0 路径 (板级真实到达序: 必须先验证 TL 段受 run 门控)。
        // wait_gap 停在下一轮首行 start 沿 (idlec = 本轮 GAP 拍数)
        run = 1'b0;
        wait_gap;
        if (idlec < 10_000) begin
            $display("FAIL: TR 突发后空线仅 %0d 拍 (行序未终止?)", idlec);
            errs = errs + 1;
        end
        $display("TR burst ok; 突发后空线 %0d 拍", idlec);

        // ===== 第 4 轮: run=0 + tr_run=1 → 无快照行, 直接 4 行 TR (且无 TL:
        // TL 段受 run 门控 — 无锁存拍即无 rptr 基准; 若误发 TL, 下面的
        // wait_gap 会在 TL1 start 沿提前退出 → idlec 小 → FAIL) =====
        // (start 沿已由上面的 wait_gap 捕获, 直接解码)
        for (l = 1; l <= 4; l = l + 1) begin
            decode_line(117);
            for (k = 0; k < 117; k = k + 1)
                if (g1[k] !== exp_trc(l[3:0], k[8:0])) begin
                    $display("FAIL: R4 TR%0d char%0d got %02X want %02X",
                             l, k, g1[k], exp_trc(l[3:0], k[8:0]));
                    errs = errs + 1;
                end
            $display("R4 TR%0d: ", l);
            for (k = 0; k < 117; k = k + 1) $write("%c", g1[k]);
            $write("\n");
        end
        // 下一轮门控: run=1 & tr_run=0 & rxt_run=1 (R4 突发后 S_GAP 内改, 生效于下轮)
        run = 1'b1; trun = 1'b0; rxtrun = 1'b1;
        wait_gap;
        if (idlec < 10_000) begin
            $display("FAIL: R4 突发后空线仅 %0d 拍", idlec);
            errs = errs + 1;
        end
        $display("R4 (run=0) 直发 TR 突发 ok; 突发后空线 %0d 拍", idlec);

        // ===== 第 5 轮: run=1 & tr_run=0 & rxt_run=1 → 快照 (RXTR=1) + 8 TL + 4 RXT =====
        // 快照行内容 = exp2 但 RXTR=1 (行首重采 rxt_run; 其余输入未再变);
        // 行序证明 RXT 段跟在 TL 段之后且 TL 段仍受 run 门控 (8 行不变)
        decode_line(368);
        for (i = 0; i < 366; i = i + 1)
            eb[i] = exp2[2927 - 8 * i -: 8];
        // 本轮输入 = 第 3 轮中途改写后的稳态值: rpt 已是 010 (exp2 里是 456,
        // 那是第 3 轮快照行拍上的值, 之后从未还原) → RPT 字段 (char 114..116) 覆盖;
        // 行首重采 rxt_run=1 → RXTR 字段 (char 307) = '1'
        eb[114] = 8'h30; eb[115] = 8'h31; eb[116] = 8'h30;   // RPT=010
        eb[307] = 8'h31;                                     // RXTR=1
        $display("L5 (RXT 轮快照行, 期望 = exp2 且 RXTR=1): ");
        for (i = 0; i < 368; i = i + 1) $write("%c", g1[i]);
        $write("\n");
        for (i = 0; i < 366; i = i + 1)
            if (g1[i] !== eb[i]) begin
                $display("FAIL: L5 char%0d got %02X want %02X", i, g1[i], eb[i]);
                errs = errs + 1;
            end
        if ((g1[366] !== 8'h0D) || (g1[367] !== 8'h0A)) begin
            $display("FAIL: L5 行尾 got %02X %02X (expect 0D 0A)", g1[366], g1[367]);
            errs = errs + 1;
        end
        // 8 行 TL (rpt=010 未再变 → 与第 3 轮同基址 FF0)
        for (l = 0; l < 8; l = l + 1) chk_tl(l[3:0]);
        $display("L5 TL burst done (8 lines ok)");
        // 4 行 RXT (紧跟 TL8 之后; 每行 134 字符)
        for (l = 13; l <= 16; l = l + 1) chk_rxt(l[4:0]);
        $display("L5 RXT burst done (4 lines ok)");

        // ===== 第 6 轮: run=0 & tr_run=0 & rxt_run=1 → 无快照/TL/TR, 直发 4 RXT =====
        // (S_IDLE 起点分支 = rxt_run 独走; 若误发快照行, 下面的解码立即失配)
        run = 1'b0;
        wait_gap;
        if (idlec < 10_000) begin
            $display("FAIL: L5 后空线仅 %0d 拍", idlec);
            errs = errs + 1;
        end
        for (l = 13; l <= 16; l = l + 1) chk_rxt(l[4:0]);
        $display("L6 (run=0) 直发 RXT 突发 ok");
        // 4 行 RXT 后应回 GAP (行序终止; 若误发第 5 行, wait_gap 提前退出)
        wait_gap;
        if (idlec < 10_000) begin
            $display("FAIL: R6 突发后空线仅 %0d 拍 (行序未终止?)", idlec);
            errs = errs + 1;
        end
        $display("L6 突发后空线 %0d 拍", idlec);

        if (errs == 0) $display("ALL_OK");
        else           $display("FAIL: %0d mismatches", errs);
        $finish;
    end
endmodule
