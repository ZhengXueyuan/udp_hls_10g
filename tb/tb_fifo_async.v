`timescale 1ns/1ps
//=============================================================================
// tb_fifo_async.v — fifo_async 单元门 (自检, 无 Python; 金标准队列对拍 + 灰码监视 +
//                   极端时钟比 + 满/空捶打 + 复位矩阵 + 时钟停摆 + 结构契约延迟)
//=============================================================================
// 用法 (由 sim/fifoasync/run_tb_fifo_async.bat 调用, 每个 case 独立目录/独立 xsim.dir):
//   xsim tb_fifo_async -runall -testplusarg C_<CASE>
//   CASE ∈ BAL WRFAST RDFAST BOUND RESET CLKSTOP LAT
//
// 时钟方案 (全部由 clk_ref 派生 ⇒ **两侧时钟沿永不重合**, 两条金标准记账路径才无竞争):
//   clk_ref 半周期 0.4ns; 写侧在 clk_ref 上升沿计 WH 步翻转 (写沿恒在 0.8k 网格),
//   读侧在 clk_ref 下降沿计 RH 步翻转 (读沿恒在 0.4+0.8k 网格)。两者奇偶不同 ⇒
//   **任何 WH/RH 组合下都不会重合**, 且相距恒 0.4ns —— 这正是本 TB 敢用两个 always 块
//   分别记账 (写域推 / 读域弹) 的原因。周期: T_wr = 1.6*WH ns, T_rd = 1.6*RH ns。
//   顶层一切信号只在 "写沿 + 0.15ns" 改变 (离最近的对侧时钟沿仍 >= 0.25ns) ⇒ 无 0 延迟竞争。
//
// 4 个被测实例 (同一组时钟, 各自独立驱动/记账/监视):
//   A = 72bit/16/FWFT=1 (主 drop-in 配置)   B = 72bit/16/FWFT=0 (标准 1 拍延迟)
//   C = 40bit/4 /FWFT=1 (最小深度 = DEPTH 下界)  D = 40bit/4/FWFT=0
//
// 判据总表 (逐条印在日志里; 详见文件末 "判据表" 打印):
//   1 金标准对拍    : 随机激励下每拍核对 dout == 队列头 (FWFT=1) / 弹出字次拍呈现 (FWFT=0);
//                     结束时 写-读 == 0。                              → o_cmp / o_err
//   2 无丢失/重复/重排: 每个字自带递增 seq, 逐字与队列相同 (seq 有洞 = 丢字指纹)。
//   3 极端时钟比    : WRFAST 100:1 (写快读慢) / RDFAST 1:100 (写慢读快)。
//   4 随机使能占空比: 写 6/8、读 5/8 随机门 (不是每拍都读写), 全 case 生效;
//                     BAL 用 g_duty=1 (写5/8 读4/8, 5:4 时钟下速率**精确匹配**) ⇒ 占用在 0..DEPTH
//                     全区间随机游走; BOUND3 用 g_duty=2 (等周期下两侧都 5/8) 同理。
//   5 满/空捶打     : 灌到**恰好满** (full 期间计数不再增) / 排到**恰好空** (空态常读弹不出) /
//                     1:1 高速下 full 与 empty 各 >=5 次上升沿 + 占用极值到 0/DEPTH。
//   6 灰码监视      : 指针每次变化必须 (a) 只变 1 位 (b) == bin2gray(bin) (c) bin 只 +1;
//                     且被验证的变化次数 > 0 (否则判据是空的)。     → o_gmon_chk(正证据)/o_gmon(违规)
//   7 复位矩阵      : ① 空 FIFO 复位 ② 灌满后复位 ③ 在途数据两侧同复位 ④ 只复位读侧 ⑤ 只复位写侧
//                     ⑥ 重新对齐复位后恢复干净。④⑤ 的期望值精确可预测 (见对应 chk 的文字)。
//   8 时钟停摆      : 停读时钟 ⇒ 写侧被 full 挡住 (不挂死), 恢复后逐字补齐; 停写时钟 ⇒ 读侧照常排空。
//   9 结构契约延迟  : 二级同步 ⇒ 空标志最早在写入沿后第 4 个 rd 沿被采到 (dt > 3*T_rd); 满标志对称。
//                     少一级同步 ⇒ dt = eps + 2T < 3T ⇒ 必被这条抓 (负对照 mut_empty1)。
//  10 参数化        : 4 个实例 (含小深度/窄位宽/FWFT=0) 全部同门, 全部有正证据要求。
//
// ⚠️ 本门**测不到**的: 亚稳态/MTBF (行为级仿真没有亚稳态模型) ⇒ "同步链少一级"这类缺陷
//    只能靠判据 9 的**延迟契约**间接抓; 真正的 MTBF 只能靠综合后 CDC 报告 / STA。
//=============================================================================

// ---------------- 单元检查器 (内含 DUT + 驱动 + 金标准队列 + 监视) ----------------
module fifo_async_chk #(
    parameter WIDTH = 72,
    parameter DEPTH = 16,
    parameter FWFT  = 1,
    parameter TAGID = 0
)(
    input  wire         wr_clk,
    input  wire         rd_clk,
    input  wire         g_wr_rst_n,       // 原始复位 (顶层按场景给; 本模块自行同步释放)
    input  wire         g_rd_rst_n,
    input  wire         g_run,            // 正常流量 (随机占空比)
    input  wire         g_fill,           // 只写 (灌满)
    input  wire         g_drain,          // 只读 (排空)
    input  wire         g_pause,          // 常规流量暂停 (单次写/弹模式用)
    input  wire [1:0]   g_duty,           // 占空比模式: 0=写6/8 读5/8 (默认) / 1=写5/8 读4/8
                                          //   (5:4 时钟下速率**精确匹配** ⇒ 占用 0..DEPTH 随机游走)
                                          //   2=两侧都 5/8 (等周期下平衡)
    input  wire         g_dirty,          // 脏模式 (单侧复位后: 不做内容对拍, 只计数)
    input  wire         g_onewr,          // 单次写 (空标志延迟测量)
    input  wire         g_onepop,         // 单次弹 (满标志延迟测量)
    input  wire         g_early,          // F-1: 驱动侧改用**原始复位**释放 (比 DUT 内部两级早 1~2 拍)
    // ---- 观测 ----
    output reg  [31:0]  o_wr, o_rd, o_cmp, o_err,          // 被接受写 / 弹出 / 比较次数 / 内容错误
    output reg  [31:0]  o_gmon, o_gmon_chk,                // 灰码违规 / 灰码被验证的变化次数
    output reg  [31:0]  o_occ_max, o_occ_min,              // 占用极值 (金标准侧)
    output reg  [31:0]  o_full_blk, o_empty_blk,           // 被 full 挡掉的写 / 空态被忽略的读
    output reg  [31:0]  o_full_rise, o_empty_rise,         // full / empty 的 0→1 次数
    output reg  [31:0]  o_dirty_pop, o_dirty_wr,           // 脏窗口内: 弹出数 / 被接受写数
    output reg  [31:0]  o_snap_qcnt, o_snap_wmod,          // 脏窗口起点快照: 真实未读 / 写指针 mod
    output reg  [31:0]  o_head_seq, o_first_pop_seq,       // 脏窗口起点头字 seq / 脏窗口首次弹出 seq
    output reg  [31:0]  o_lat_e0, o_lat_e1,                // 空延迟: 写入沿 / 观察到 empty=0 的沿 (ps)
    output reg  [31:0]  o_lat_f0, o_lat_f1,                // 满延迟: 弹出沿 / 观察到 full=0 的沿 (ps)
    output wire         o_full, o_empty,
    output wire [31:0]  o_ovf_cnt,        // F-1: DUT 拒写计数直出 (顶层做差分)
    output wire         o_ovf_pulse,      // F-1: DUT 拒写脉冲直出
    output reg          o_done
);
    localparam AW   = $clog2(DEPTH);
    localparam QMAX = 2*DEPTH;             // 环形金标准队列 (>= 最大占用, 留一倍余量)
    localparam [31:0] PMASK = (1 << (AW+1)) - 1;

    // ---- 复位同步器 (与 DUT 同构 ⇒ 同一沿释放; 本模块记账与 DUT 严格同拍) ----
    (* ASYNC_REG = "TRUE" *) reg [1:0] wrs_sr, rds_sr;
    always @(posedge wr_clk or negedge g_wr_rst_n)
        if (!g_wr_rst_n) wrs_sr <= 2'b00; else wrs_sr <= {wrs_sr[0], 1'b1};
    always @(posedge rd_clk or negedge g_rd_rst_n)
        if (!g_rd_rst_n) rds_sr <= 2'b00; else rds_sr <= {rds_sr[0], 1'b1};
    wire wrs_n   = wrs_sr[1];
    wire rds_n   = rds_sr[1];
    wire rst_act = !(wrs_n && rds_n);      // 任一侧仍在复位 ⇒ 金标准队列保持清空

    // ---- 驱动寄存器 (全部非阻塞驱动 DUT 端口; 本工程坑 3/17) ----
    reg              wr_en_r, rd_en_r;
    reg [WIDTH-1:0]  din_r;
    reg [39:0]       prng_w, prng_r;
    reg [31:0]       seq_r;               // 提供写的序号 (跨复位不复位, 只增; 失配时可定位)
    reg [1:0]        st_latw, st_latp;

    wire [39:0] wx1 = prng_w ^ (prng_w << 13);
    wire [39:0] wx2 = wx1 ^ (wx1 >> 17);
    wire [39:0] wx3 = wx2 ^ (wx2 << 5);
    wire [39:0] rx1 = prng_r ^ (prng_r << 13);
    wire [39:0] rx2 = rx1 ^ (rx1 >> 17);
    wire [39:0] rx3 = rx2 ^ (rx2 << 5);

    // ⚠️ 2026-10-11 (M1): 原式 `{prng_w[WIDTH-33:0], seq_r}` 要求 **WIDTH>=33** —— 新加的
    //   u_E (M1 实参 WIDTH=32) 会让 WIDTH-33 变负 ⇒ `[-1:0]` 反向段选 ⇒ xelab 硬错
    //   (VRFC 10-1219, 实测)。改成"先拼 72 位再截断": 对既有 72/40 两档**逐位等价**
    //   (旧式两档都恰等于该拼接的低 WIDTH 位), 对 WIDTH=32 退化为纯 `seq_r`。
    wire [71:0]      din_full = {prng_w, seq_r};
    wire [WIDTH-1:0] din_n = din_full[WIDTH-1:0];

    // ---- DUT ----
    wire [AW:0]      occ_probe_w, occ_probe_r;   // P6b 占用探针 (必须先声明后使用)
    integer          occ_w_max, occ_r_max;
    // ⚠️ 探针违规必须用**独立计数器**, 绝不能计入 o_err —— o_err 由本模块**既有的**
    //    always 块驱动, 新开一个块写它 = 多过程驱动 ⇒ xsim 里后写覆盖 ⇒ 既有
    //    "内容错" 计数会被吞掉 (实测: mut_full 变异体因此不再报 DOUT-MISMATCH,
    //    门把它误判成"变异体没被抓到")。TB 主体用层次引用 u_A.occ_bad_cnt 断言。
    integer          occ_bad_cnt;
    wire [WIDTH-1:0] dut_dout;
    wire             dut_full, dut_empty;
    wire [31:0]      dut_ovf_cnt;
    wire             dut_ovf_pulse;
    fifo_async #(.WIDTH(WIDTH), .DEPTH(DEPTH), .FWFT(FWFT), .AW(AW)) u_dut (
        .wr_clk(wr_clk), .wr_rst_n(g_wr_rst_n), .wr_en(wr_en_r), .din(din_r), .full(dut_full),
        .rd_clk(rd_clk), .rd_rst_n(g_rd_rst_n), .rd_en(rd_en_r), .dout(dut_dout), .empty(dut_empty),
        .dbg_wbin(), .dbg_rbin(), .dbg_wgray(), .dbg_rgray(),
        // ---- P6b 新增: 占用探针 (W27/W28 的来源) 必须在本门里被守卫 ----
        //   ⚠️ 这两根是**纯观测线**, 但探针自己错了没人管就会污染板级读法 (W27/W28 被
        //      当成"深度够不够"的唯一读数) ⇒ 本节把它们接进来, 硬界检查计入 o_err
        //      (所有既有 `err==0` 判据自动覆盖), 最大值另由 TB 主体对金标准 o_occ_max 断言。
        .dbg_occ_w(occ_probe_w), .dbg_occ_r(occ_probe_r),
        .ovf_pulse(dut_ovf_pulse), .ovf_cnt(dut_ovf_cnt)     // F-1 拒写探针
    );
    assign o_full  = dut_full;
    assign o_empty = dut_empty;
    assign o_ovf_cnt   = dut_ovf_cnt;
    assign o_ovf_pulse = dut_ovf_pulse;

    // ---- P6b: 占用探针守卫 (硬界 + 历史最大) ----
    //   ① `occ <= DEPTH` 恒成立 (超出 = 指针/灰码转二进制算错或位宽截断);
    //   ② 写域可见占用是**悲观**方向 ⇒ 它的历史最大必须 **>= 金标准的真实最大占用**
    //      (o_occ_max)。探针若恒 0 / 未连接, 这条在有任何流量时立刻 FAIL —— 这正是
    //      "空读数 != 真 0" 在探针上的落地。
    always @(posedge wr_clk) begin
        if (g_wr_rst_n) begin
            if (occ_probe_w > occ_w_max) occ_w_max = occ_probe_w;
            // ⚠️ 只在**指针一致**的窗口里查硬界: 单侧复位(脏)场景故意把两侧指针对错开,
            //    此时 occ_w 会回绕成巨大值 —— 那是被测特性的产物, 不是探针缺陷 (RESET 门实测)。
            if ((occ_probe_w > DEPTH) && !g_dirty) begin
                occ_bad_cnt = occ_bad_cnt + 1;
                if (occ_bad_cnt <= 8) $display("  [%0d] OCC-W-OVER-DEPTH t=%0t occ_w=%0d DEPTH=%0d",
                                               TAGID, $time, occ_probe_w, DEPTH);
            end
        end
    end
    always @(posedge rd_clk) begin
        if (g_rd_rst_n) begin
            if (occ_probe_r > occ_r_max) occ_r_max = occ_probe_r;
            if ((occ_probe_r > DEPTH) && !g_dirty) begin   // 同写域: 脏窗口不比硬界
                occ_bad_cnt = occ_bad_cnt + 1;
                if (occ_bad_cnt <= 8) $display("  [%0d] OCC-R-OVER-DEPTH t=%0t occ_r=%0d DEPTH=%0d",
                                               TAGID, $time, occ_probe_r, DEPTH);
            end
        end
    end

    // ---- 金标准队列 (写域只动 qt/qcnt, 读域只动 qh/qcnt; 两侧沿永不重合 ⇒ 无竞争) ----
    reg [WIDTH-1:0] q [0:QMAX-1];
    integer         qh, qt, qcnt;
    reg [WIDTH-1:0] dout_exp;              // FWFT=0: 上一次弹出字的期望 (次拍呈现)
    reg             cmp_pend;

    wire accept_w = wr_en_r && !dut_full;  // 本拍被 DUT 接受的写 (边沿前值 = 本拍真实值)
    wire rd_ok    = rd_en_r && !dut_empty; // 本拍被 DUT 执行的弹

    // 监视采样寄存器
    reg [AW:0] wgray_q, wbin_q, rgray_q, rbin_q;
    reg        gmon_w_init, gmon_r_init;
    reg        full_q, empty_q;
    reg        dirty_q_w, dirty_q_r;       // g_dirty 边沿检测 (每段脏窗口重新取快照)

    function integer popcnt;
        input [AW:0] v;
        integer i;
        begin
            popcnt = 0;
            for (i = 0; i <= AW; i = i + 1) popcnt = popcnt + v[i];
        end
    endfunction

    function [31:0] ps_now;                // $realtime(ns) → 整数 ps (0.4ns 量化; 0.5ps 取整躲浮点噪声)
        input dummy;                       // Verilog 要求函数至少一个入参
        begin ps_now = $rtoi($realtime * 1000.0 + 0.5); end
    endfunction

    // ---------------- 写域驱动 (非阻塞; 本工程坑 3/17) ----------------
    // F-1 场景开关: g_early=1 时驱动侧用**原始 rst_n** 释放 ⇒ 比 DUT 内部两级同步释放早
    //   1~2 个 wr 拍 ⇒ 稳定造出"生产者已放行、FIFO 写域还在复位"的窗口 (审计 t4 场景同构)。
    wire rst_drv_n = g_early ? g_wr_rst_n : wrs_n;
    always @(posedge wr_clk or negedge rst_drv_n) begin
        if (!rst_drv_n) begin
            wr_en_r   <= 1'b0;
            din_r     <= {WIDTH{1'b0}};
            prng_w    <= 40'h00C0FFEE11 + TAGID;
            st_latw   <= 2'd0;
        end else begin
            prng_w <= wx3;
            if (g_onewr && !g_run && !g_fill && !g_drain) begin     // 单次写 (延迟测量)
                if      (st_latw == 2'd0) begin wr_en_r <= 1'b1; st_latw <= 2'd1; end
                else if (st_latw == 2'd1) begin wr_en_r <= 1'b0; st_latw <= 2'd2; end
                else                          wr_en_r <= 1'b0;
            end else begin
                st_latw <= 2'd0;
                if      (g_drain)                     wr_en_r <= 1'b0;
                else if (g_fill)                       wr_en_r <= 1'b1;                       // 只写
                else if (g_run && !g_pause)            wr_en_r <= (g_duty != 2'd0) ? (prng_w[2:0] >= 3'd3)
                                                                        : (prng_w[2:0] >= 3'd2);
                else                                   wr_en_r <= 1'b0;                       // 6/8 随机门
            end
            din_r <= din_n;
            if (wr_en_r) seq_r <= seq_r + 32'd1;   // "提供"即前进 (含被 full 挡掉的 ⇒ seq 有洞 = 丢字指纹)
        end
    end

    // ---------------- 读域驱动 ----------------
    always @(posedge rd_clk or negedge rds_n) begin
        if (!rds_n) begin
            rd_en_r <= 1'b0;
            prng_r  <= 40'h00BEEF5EED + TAGID;
            st_latp <= 2'd0;
        end else begin
            prng_r <= rx3;
            if (g_onepop && !g_run && !g_fill && !g_drain) begin    // 单次弹 (延迟测量)
                if      (st_latp == 2'd0) begin rd_en_r <= 1'b1; st_latp <= 2'd1; end
                else if (st_latp == 2'd1) begin rd_en_r <= 1'b0; st_latp <= 2'd2; end
                else                          rd_en_r <= 1'b0;
            end else begin
                st_latp <= 2'd0;
                if      (g_drain)                     rd_en_r <= 1'b1;                       // 排空: 全速读
                else if (g_fill)                       rd_en_r <= 1'b0;
                else if (g_run && !g_pause)            rd_en_r <= (g_duty == 2'd1) ? (prng_r[2:0] >= 3'd4)
                                                     : (g_duty == 2'd2) ? (prng_r[2:0] >= 3'd3)
                                                                        : (prng_r[2:0] >= 3'd3);
                else                                   rd_en_r <= 1'b0;                       // 5/8 随机门
            end
        end
    end

    // ---------------- 写域记账 (全部用边沿前值 = 本拍真实值) ----------------
    always @(posedge wr_clk) begin
        if (!wrs_n) begin
            // ⚠️ 金标准队列**只由写域复位清** (不是 rst_act): 两侧释放不同步时, 写侧可能先恢复
            //    并写入若干字 (DUT 的 wbin 从 0 起算), 这些字读侧一释放就会按序读出 ⇒ 必须记账。
            //    早先用 rst_act 清 ⇒ 那段窗口内的写**完全没被计数** ⇒ 1:100 写快读慢时窗口长达
            //    2 个 rd 周期 (WRFAST = 1280ns = 200 个 wr 周期), 金标准队列说"空"而 FIFO 里
            //    有 16 个字 ⇒ 假失配 (本门第一次跑 WRFAST 就撞上: 327 个假错误)。
            //    只清本域计数器 ⇒ 单侧复位时另一域的记账不受影响。
            o_wr = 32'd0; o_full_blk = 32'd0; o_full_rise = 32'd0; o_dirty_wr = 32'd0;
            o_lat_e0 = 32'd0;
            full_q = 1'b0;
            qh = 0; qt = 0; qcnt = 0;           // qh 也归写域清 (队列基点 = 写侧指针 0)
        end else begin
            if (accept_w) begin
                o_wr = o_wr + 32'd1;
                if (g_dirty) o_dirty_wr = o_dirty_wr + 32'd1;
                else begin
                    q[qt] = din_r;
                    qt = qt + 1; if (qt == QMAX) qt = 0;
                    qcnt = qcnt + 1;
                    if (qcnt > o_occ_max) o_occ_max = qcnt;
                end
            end
            if (wr_en_r && dut_full) o_full_blk = o_full_blk + 32'd1;

            // 空标志延迟契约: 记第一个被接受的写沿 (只在 g_onewr 窗口内)
            if (g_onewr && accept_w && o_lat_e0 == 32'd0) o_lat_e0 = ps_now(1'b0);
            // 满标志延迟契约: 观察 full 从 1 → 0 (边沿前采样)
            if (o_lat_f0 != 32'd0 && o_lat_f1 == 32'd0 && full_q == 1'b1 && dut_full == 1'b0)
                o_lat_f1 = ps_now(1'b0);
            if (full_q == 1'b0 && dut_full == 1'b1) o_full_rise = o_full_rise + 32'd1;
            full_q = dut_full;

            // 脏窗口起点快照 (g_dirty 上升沿那拍; 场景保证此刻两侧静止)
            if (g_dirty && !dirty_q_w) begin
                o_snap_qcnt = qcnt;
                o_snap_wmod = o_wr & PMASK;
            end
            dirty_q_w = g_dirty;
        end
    end

    // ---------------- 读域记账 ----------------
    always @(posedge rd_clk) begin
        if (!rds_n) begin
            // 只清本域计数器; **不动** qh/qt/qcnt (队列归写域管, 见写域注释)
            o_rd = 32'd0; o_cmp = 32'd0; o_err = 32'd0; o_empty_blk = 32'd0;
            o_empty_rise = 32'd0; o_dirty_pop = 32'd0; o_first_pop_seq = 32'hFFFFFFFF;
            dout_exp = {WIDTH{1'b0}}; cmp_pend = 1'b0;
            empty_q = 1'b1;
            o_done = 1'b0;
        end else begin
            // 1) FWFT=0: 检查上一拍弹出字是否在本拍呈现
            if (!g_dirty && cmp_pend) begin
                o_cmp = o_cmp + 32'd1;
                if (dut_dout !== dout_exp) begin
                    o_err = o_err + 32'd1;
                    if (o_err <= 8) $display("  [%0d] FWFT0-DOUT-MISMATCH t=%0t got=%h exp=%h", TAGID, $time, dut_dout, dout_exp);
                end
                cmp_pend = 1'b0;
            end
            // 2) FWFT=1: 每拍核对 dout == 队列头 (只要 !empty)
            if (FWFT == 1 && !g_dirty && dut_empty == 1'b0) begin
                o_cmp = o_cmp + 32'd1;
                if (dut_dout !== q[qh]) begin
                    o_err = o_err + 32'd1;
                    if (o_err <= 8) $display("  [%0d] FWFT1-DOUT-MISMATCH t=%0t got=%h exp=%h (seq got=%0d exp=%0d)",
                                             TAGID, $time, dut_dout, q[qh], dut_dout[31:0], q[qh][31:0]);
                end
            end
            // 3) 弹出
            if (rd_ok) begin
                if (g_dirty) begin
                    o_dirty_pop = o_dirty_pop + 32'd1;
                    if (o_first_pop_seq == 32'hFFFFFFFF) o_first_pop_seq = dut_dout[31:0];
                    if (qcnt > 0) begin qh = qh + 1; if (qh == QMAX) qh = 0; qcnt = qcnt - 1; end
                end else if (qcnt <= 0) begin
                    o_err = o_err + 32'd1;              // 弹出了库里没有的字 = 多弹 (结构性错误)
                    if (o_err <= 8) $display("  [%0d] UNDERFLOW-POP t=%0t dout=%h qcnt=0", TAGID, $time, dut_dout);
                end else begin
                    if (FWFT == 0) begin dout_exp = q[qh]; cmp_pend = 1'b1; end
                    qh = qh + 1; if (qh == QMAX) qh = 0;
                    qcnt = qcnt - 1;
                    o_rd = o_rd + 32'd1;
                    if (qcnt < o_occ_min) o_occ_min = qcnt;
                end
            end else if (rd_en_r && dut_empty) begin
                o_empty_blk = o_empty_blk + 32'd1;
            end

            // 4) 空标志延迟契约: 观察 empty 从 1 → 0 (边沿前采样)
            if (g_onewr && o_lat_e1 == 32'd0 && empty_q == 1'b1 && dut_empty == 1'b0)
                o_lat_e1 = ps_now(1'b0);
            // 5) 满标志延迟契约: 记单次弹出的沿
            if (g_onepop && rd_ok && o_lat_f0 == 32'd0) o_lat_f0 = ps_now(1'b0);
            // 6) empty 上升沿计数 + 脏窗口起点头字 seq
            if (empty_q == 1'b0 && dut_empty == 1'b1) o_empty_rise = o_empty_rise + 32'd1;
            empty_q = dut_empty;
            if (g_dirty && !dirty_q_r) o_head_seq = q[qh][31:0];
            dirty_q_r = g_dirty;

            // 7) 排空完成
            if (!g_drain) o_done = 1'b0;
            else if (dut_empty == 1'b1 && !rd_ok) o_done = 1'b1;
        end
    end

    // ---------------- 灰码监视 (独立块; 只读 DUT 内部指针, 与记账零耦合) ----------------
    // 判据: 指针每次变化必须 (a) 只变 1 位 (b) == bin2gray(bin) (c) bin 只 +1 ⇒ 否则违规。
    // 变体 mut_binptr (灰码换二进制) 必被 (a)/(b) 抓 ⇒ 这条判据的区分能力由负对照证明。
    always @(posedge wr_clk) begin
        if (!wrs_n) begin
            gmon_w_init = 1'b0;
        end else if (!gmon_w_init) begin
            wgray_q = u_dut.wgray_r; wbin_q = u_dut.wbin_r; gmon_w_init = 1'b1;
        end else begin
            if ((u_dut.wgray_r !== wgray_q) || (u_dut.wbin_r !== wbin_q)) begin
                o_gmon_chk = o_gmon_chk + 32'd1;
                if (popcnt(u_dut.wgray_r ^ wgray_q) != 1)                    o_gmon = o_gmon + 32'd1;
                if (u_dut.wgray_r !== (u_dut.wbin_r ^ (u_dut.wbin_r >> 1)))  o_gmon = o_gmon + 32'd1;
                if (u_dut.wbin_r !== ((wbin_q + 1) & PMASK))                 o_gmon = o_gmon + 32'd1;
                if (o_gmon != 0 && o_gmon <= 4)
                    $display("  [%0d] GRAY-MON-VIOLATION(wr) t=%0t wgray=%b/%b wbin=%b/%b popcnt=%0d",
                             TAGID, $time, u_dut.wgray_r, wgray_q, u_dut.wbin_r, wbin_q,
                             popcnt(u_dut.wgray_r ^ wgray_q));
            end
            wgray_q = u_dut.wgray_r; wbin_q = u_dut.wbin_r;
        end
    end

    always @(posedge rd_clk) begin
        if (!rds_n) begin
            gmon_r_init = 1'b0;
        end else if (!gmon_r_init) begin
            rgray_q = u_dut.rgray_r; rbin_q = u_dut.rbin_r; gmon_r_init = 1'b1;
        end else begin
            if ((u_dut.rgray_r !== rgray_q) || (u_dut.rbin_r !== rbin_q)) begin
                o_gmon_chk = o_gmon_chk + 32'd1;
                if (popcnt(u_dut.rgray_r ^ rgray_q) != 1)                    o_gmon = o_gmon + 32'd1;
                if (u_dut.rgray_r !== (u_dut.rbin_r ^ (u_dut.rbin_r >> 1)))  o_gmon = o_gmon + 32'd1;
                if (u_dut.rbin_r !== ((rbin_q + 1) & PMASK))                 o_gmon = o_gmon + 32'd1;
                if (o_gmon != 0 && o_gmon <= 4)
                    $display("  [%0d] GRAY-MON-VIOLATION(rd) t=%0t rgray=%b/%b rbin=%b/%b popcnt=%0d",
                             TAGID, $time, u_dut.rgray_r, rgray_q, u_dut.rbin_r, rbin_q,
                             popcnt(u_dut.rgray_r ^ rgray_q));
            end
            rgray_q = u_dut.rgray_r; rbin_q = u_dut.rbin_r;
        end
    end

    initial begin
        gmon_w_init = 1'b0; gmon_r_init = 1'b0;
        o_wr=0; o_rd=0; o_cmp=0; o_err=0; o_gmon=0; o_gmon_chk=0;
        o_occ_max=0; o_occ_min=32'h0000FFFF;
        o_full_blk=0; o_empty_blk=0; o_full_rise=0; o_empty_rise=0;
        o_dirty_pop=0; o_dirty_wr=0;
        o_snap_qcnt=32'hFFFFFFFF; o_snap_wmod=0; o_head_seq=32'hFFFFFFFF; o_first_pop_seq=32'hFFFFFFFF;
        o_lat_e0=0; o_lat_e1=0; o_lat_f0=0; o_lat_f1=0;
        o_done=0; qh=0; qt=0; qcnt=0; dout_exp={WIDTH{1'b0}}; cmp_pend=1'b0;
        occ_w_max=0; occ_r_max=0; occ_bad_cnt=0;
        seq_r=32'd0; full_q=1'b0; empty_q=1'b1; dirty_q_w=1'b0; dirty_q_r=1'b0;
    end
endmodule


// ---------------- 顶层: 时钟生成 + 场景脚本 + 判据汇总 ----------------
module tb_fifo_async;
    reg c_bal, c_wrfast, c_rdfast, c_bound, c_reset, c_clkstop, c_lat, c_early, c_mir;
    integer WH, RH;                        // 半周期步数 (步 = 0.8ns)
    integer TWR_PS, TRD_PS;                // 周期 (ps)
    reg     run_on_rd;                     // 长跑阶段等哪个时钟 (等快的那个)

    initial begin
        c_bal=0; c_wrfast=0; c_rdfast=0; c_bound=0; c_reset=0; c_clkstop=0; c_lat=0; c_early=0; c_mir=0;
        if      ($test$plusargs("C_WRFAST"))  c_wrfast = 1;
        else if ($test$plusargs("C_RDFAST"))  c_rdfast = 1;
        else if ($test$plusargs("C_BOUND"))   c_bound  = 1;
        else if ($test$plusargs("C_RESET"))   c_reset  = 1;
        else if ($test$plusargs("C_CLKSTOP")) c_clkstop= 1;
        else if ($test$plusargs("C_LAT"))     c_lat    = 1;
        else if ($test$plusargs("C_EARLY"))   c_early  = 1;
        else if ($test$plusargs("C_MIR"))     c_mir    = 1;
        else                                   c_bal    = 1;
        if      (c_wrfast) begin WH =   4; RH = 400; end   // 写快读慢 100:1
        else if (c_rdfast) begin WH = 400; RH =   4; end   // 写慢读快 1:100
        else if (c_bound)  begin WH =   4; RH =   4; end
        // ⭐ M1 (2026-10-11): 镜像 FIFO 的域对 = dp_clk(156.25MHz, 6.4ns) → pcie_axi_aclk(250MHz, 4.0ns)
        //   ⇒ 周期比 = 1.6。0.8ns 步长表达不出 4.0ns (RH=2.5 非整数) ⇒ 取 **2× 缩放**:
        //   12.8ns : 8.0ns = **比例精确 1.6** (FIFO 的全部契约都是按"周期数"写的 ⇒ 时间缩放等价)。
        else if (c_mir)    begin WH =   8; RH =   5; end   // 12.8ns : 8.0ns = 2 x (6.4ns : 4.0ns)
        else                begin WH =   5; RH =   4; end   // 8ns : 6.4ns = 125MHz : 156.25MHz 的比
        TWR_PS = WH * 1600;
        TRD_PS = RH * 1600;
        run_on_rd = (TWR_PS > TRD_PS);
        $display("FIFO_ASYNC TB: case=%0s WH=%0d RH=%0d T_wr=%0dps T_rd=%0dps",
                 c_wrfast?"WRFAST":c_rdfast?"RDFAST":c_bound?"BOUND":c_reset?"RESET":
                 c_clkstop?"CLKSTOP":c_lat?"LAT":c_early?"EARLY":c_mir?"MIR":"BAL", WH, RH, TWR_PS, TRD_PS);
    end

    // ---- 时钟 ----
    reg clk_ref = 1'b1;
    always #0.4 clk_ref = ~clk_ref;

    reg [15:0] wcnt = 16'd0, rcnt = 16'd0;
    reg        wr_clk = 1'b0, rd_clk = 1'b0;
    reg        stop_wr = 1'b0, stop_rd = 1'b0;
    reg [15:0] WH16, RH16;

    always @(posedge clk_ref) begin
        if (stop_wr) begin end
        else if (wcnt == 16'd0) begin wcnt <= WH16 - 16'd1; wr_clk <= ~wr_clk; end
        else wcnt <= wcnt - 16'd1;
    end
    always @(negedge clk_ref) begin
        if (stop_rd) begin end
        else if (rcnt == 16'd0) begin rcnt <= RH16 - 16'd1; rd_clk <= ~rd_clk; end
        else rcnt <= rcnt - 16'd1;
    end

    // ---- 场景控制 (只在写沿 + 0.15ns 改变) ----
    reg g_wr_rst_n = 1'b0, g_rd_rst_n = 1'b0;
    reg g_run = 1'b0, g_fill = 1'b0, g_drain = 1'b0, g_pause = 1'b1;
    reg g_dirty = 1'b0, g_onewr = 1'b0, g_onepop = 1'b0, g_early = 1'b0;
    reg [1:0] g_duty = 2'd0;

    // ---- 4 个被测实例 ----
    wire [31:0] A_wr,A_rd,A_cmp,A_err,A_gmon,A_gchk,A_omax,A_omin,A_fblk,A_eblk,A_frise,A_erise,
                A_dpop,A_dwr,A_sqc,A_swm,A_hseq,A_fpseq,A_le0,A_le1,A_lf0,A_lf1;
    wire        A_full,A_empty,A_done;
    wire [31:0] A_ovf;
    wire        A_ovfp;
    fifo_async_chk #(.WIDTH(72), .DEPTH(16), .FWFT(1), .TAGID(0)) u_A (
        .wr_clk(wr_clk), .rd_clk(rd_clk), .g_wr_rst_n(g_wr_rst_n), .g_rd_rst_n(g_rd_rst_n),
        .g_run(g_run), .g_fill(g_fill), .g_drain(g_drain), .g_pause(g_pause), .g_duty(g_duty),
        .g_dirty(g_dirty), .g_onewr(g_onewr), .g_onepop(g_onepop), .g_early(g_early),
        .o_wr(A_wr), .o_rd(A_rd), .o_cmp(A_cmp), .o_err(A_err), .o_gmon(A_gmon), .o_gmon_chk(A_gchk),
        .o_occ_max(A_omax), .o_occ_min(A_omin), .o_full_blk(A_fblk), .o_empty_blk(A_eblk),
        .o_full_rise(A_frise), .o_empty_rise(A_erise), .o_dirty_pop(A_dpop), .o_dirty_wr(A_dwr),
        .o_snap_qcnt(A_sqc), .o_snap_wmod(A_swm), .o_head_seq(A_hseq), .o_first_pop_seq(A_fpseq),
        .o_lat_e0(A_le0), .o_lat_e1(A_le1), .o_lat_f0(A_lf0), .o_lat_f1(A_lf1),
        .o_full(A_full), .o_empty(A_empty), .o_ovf_cnt(A_ovf), .o_ovf_pulse(A_ovfp), .o_done(A_done));

    wire [31:0] B_wr,B_rd,B_cmp,B_err,B_gmon,B_gchk,B_omax,B_omin,B_fblk,B_eblk,B_frise,B_erise,
                B_dpop,B_dwr,B_sqc,B_swm,B_hseq,B_fpseq,B_le0,B_le1,B_lf0,B_lf1;
    wire        B_full,B_empty,B_done;
    wire [31:0] B_ovf;
    wire        B_ovfp;
    fifo_async_chk #(.WIDTH(72), .DEPTH(16), .FWFT(0), .TAGID(1)) u_B (
        .wr_clk(wr_clk), .rd_clk(rd_clk), .g_wr_rst_n(g_wr_rst_n), .g_rd_rst_n(g_rd_rst_n),
        .g_run(g_run), .g_fill(g_fill), .g_drain(g_drain), .g_pause(g_pause), .g_duty(g_duty),
        .g_dirty(g_dirty), .g_onewr(g_onewr), .g_onepop(g_onepop), .g_early(g_early),
        .o_wr(B_wr), .o_rd(B_rd), .o_cmp(B_cmp), .o_err(B_err), .o_gmon(B_gmon), .o_gmon_chk(B_gchk),
        .o_occ_max(B_omax), .o_occ_min(B_omin), .o_full_blk(B_fblk), .o_empty_blk(B_eblk),
        .o_full_rise(B_frise), .o_empty_rise(B_erise), .o_dirty_pop(B_dpop), .o_dirty_wr(B_dwr),
        .o_snap_qcnt(B_sqc), .o_snap_wmod(B_swm), .o_head_seq(B_hseq), .o_first_pop_seq(B_fpseq),
        .o_lat_e0(B_le0), .o_lat_e1(B_le1), .o_lat_f0(B_lf0), .o_lat_f1(B_lf1),
        .o_full(B_full), .o_empty(B_empty), .o_ovf_cnt(B_ovf), .o_ovf_pulse(B_ovfp), .o_done(B_done));

    wire [31:0] C_wr,C_rd,C_cmp,C_err,C_gmon,C_gchk,C_omax,C_omin,C_fblk,C_eblk,C_frise,C_erise,
                C_dpop,C_dwr,C_sqc,C_swm,C_hseq,C_fpseq,C_le0,C_le1,C_lf0,C_lf1;
    wire        C_full,C_empty,C_done;
    wire [31:0] C_ovf;
    wire        C_ovfp;
    fifo_async_chk #(.WIDTH(40), .DEPTH(4), .FWFT(1), .TAGID(2)) u_C (
        .wr_clk(wr_clk), .rd_clk(rd_clk), .g_wr_rst_n(g_wr_rst_n), .g_rd_rst_n(g_rd_rst_n),
        .g_run(g_run), .g_fill(g_fill), .g_drain(g_drain), .g_pause(g_pause), .g_duty(g_duty),
        .g_dirty(g_dirty), .g_onewr(g_onewr), .g_onepop(g_onepop), .g_early(g_early),
        .o_wr(C_wr), .o_rd(C_rd), .o_cmp(C_cmp), .o_err(C_err), .o_gmon(C_gmon), .o_gmon_chk(C_gchk),
        .o_occ_max(C_omax), .o_occ_min(C_omin), .o_full_blk(C_fblk), .o_empty_blk(C_eblk),
        .o_full_rise(C_frise), .o_empty_rise(C_erise), .o_dirty_pop(C_dpop), .o_dirty_wr(C_dwr),
        .o_snap_qcnt(C_sqc), .o_snap_wmod(C_swm), .o_head_seq(C_hseq), .o_first_pop_seq(C_fpseq),
        .o_lat_e0(C_le0), .o_lat_e1(C_le1), .o_lat_f0(C_lf0), .o_lat_f1(C_lf1),
        .o_full(C_full), .o_empty(C_empty), .o_ovf_cnt(C_ovf), .o_ovf_pulse(C_ovfp), .o_done(C_done));

    wire [31:0] D_wr,D_rd,D_cmp,D_err,D_gmon,D_gchk,D_omax,D_omin,D_fblk,D_eblk,D_frise,D_erise,
                D_dpop,D_dwr,D_sqc,D_swm,D_hseq,D_fpseq,D_le0,D_le1,D_lf0,D_lf1;
    wire        D_full,D_empty,D_done;
    wire [31:0] D_ovf;
    wire        D_ovfp;
    fifo_async_chk #(.WIDTH(40), .DEPTH(4), .FWFT(0), .TAGID(3)) u_D (
        .wr_clk(wr_clk), .rd_clk(rd_clk), .g_wr_rst_n(g_wr_rst_n), .g_rd_rst_n(g_rd_rst_n),
        .g_run(g_run), .g_fill(g_fill), .g_drain(g_drain), .g_pause(g_pause), .g_duty(g_duty),
        .g_dirty(g_dirty), .g_onewr(g_onewr), .g_onepop(g_onepop), .g_early(g_early),
        .o_wr(D_wr), .o_rd(D_rd), .o_cmp(D_cmp), .o_err(D_err), .o_gmon(D_gmon), .o_gmon_chk(D_gchk),
        .o_occ_max(D_omax), .o_occ_min(D_omin), .o_full_blk(D_fblk), .o_empty_blk(D_eblk),
        .o_full_rise(D_frise), .o_empty_rise(D_erise), .o_dirty_pop(D_dpop), .o_dirty_wr(D_dwr),
        .o_snap_qcnt(D_sqc), .o_snap_wmod(D_swm), .o_head_seq(D_hseq), .o_first_pop_seq(D_fpseq),
        .o_lat_e0(D_le0), .o_lat_e1(D_le1), .o_lat_f0(D_lf0), .o_lat_f1(D_lf1),
        .o_full(D_full), .o_empty(D_empty), .o_ovf_cnt(D_ovf), .o_ovf_pulse(D_ovfp), .o_done(D_done));

    // ---- "满与空同时为 1" 的角落观测 (A 实例; 两域各自悲观到极点才会同时出现:
    //      写侧看到的读指针还没离开"满"位, 读侧看到的写指针已回到"空" —— 排空瞬间必然出现) ----
    reg [31:0] both_a = 32'd0;
    always @(posedge wr_clk) if (A_full && A_empty) both_a <= both_a + 32'd1;

    // ---- ⭐ M1 (2026-10-11): 第 5 个被测实例 = **M1 实参** (WIDTH=32/DEPTH=256/FWFT=1/AW=8) ----
    //   动机 (设计件 v2 §V3/§V5-A-3): 镜像的新 FIFO 例化 = `fifo_async #(.WIDTH(32), .DEPTH(256),
    //   .FWFT(1), .AW(8))` —— 由 dp(6.4ns) 写、pcie(4.0ns) 读。既有 4 个实例的参数集
    //   (72/16, 72/16, 40/4, 40/4) **一个都不覆盖**这组参数 ⇒ 必须有一条它自己的门。
    //   ⚠️ 只在 `c_mir` 工况里**参与激励** (其余工况 g_* 全部钉 0 ⇒ 只在复位里待着):
    //      否则 RESET/CLKSTOP 等工况的"单侧脏复位"会让 E 的记账噪声进日志, 且那些
    //      工况的断言本来就不是为它写的。E 自己的断言全部写在 c_mir 分支里。
    wire e_gate = c_mir;
    wire [31:0] E_wr,E_rd,E_cmp,E_err,E_gmon,E_gchk,E_omax,E_omin,E_fblk,E_eblk,E_frise,E_erise,
                E_dpop,E_dwr,E_sqc,E_swm,E_hseq,E_fpseq,E_le0,E_le1,E_lf0,E_lf1;
    wire        E_full,E_empty,E_done;
    wire [31:0] E_ovf;
    wire        E_ovfp;
    fifo_async_chk #(.WIDTH(32), .DEPTH(256), .FWFT(1), .TAGID(4)) u_E (
        .wr_clk(wr_clk), .rd_clk(rd_clk), .g_wr_rst_n(g_wr_rst_n), .g_rd_rst_n(g_rd_rst_n),
        .g_run(g_run & e_gate), .g_fill(g_fill & e_gate), .g_drain(g_drain & e_gate),
        .g_pause(g_pause | ~e_gate), .g_duty(g_duty),
        .g_dirty(g_dirty & e_gate), .g_onewr(g_onewr & e_gate), .g_onepop(g_onepop & e_gate),
        .g_early(g_early & e_gate),
        .o_wr(E_wr), .o_rd(E_rd), .o_cmp(E_cmp), .o_err(E_err), .o_gmon(E_gmon), .o_gmon_chk(E_gchk),
        .o_occ_max(E_omax), .o_occ_min(E_omin), .o_full_blk(E_fblk), .o_empty_blk(E_eblk),
        .o_full_rise(E_frise), .o_empty_rise(E_erise), .o_dirty_pop(E_dpop), .o_dirty_wr(E_dwr),
        .o_snap_qcnt(E_sqc), .o_snap_wmod(E_swm), .o_head_seq(E_hseq), .o_first_pop_seq(E_fpseq),
        .o_lat_e0(E_le0), .o_lat_e1(E_le1), .o_lat_f0(E_lf0), .o_lat_f1(E_lf1),
        .o_full(E_full), .o_empty(E_empty), .o_ovf_cnt(E_ovf), .o_ovf_pulse(E_ovfp), .o_done(E_done));

    // ---- 判据累加器 (消息直接写在 $display 的字面量里: xsim 会把"当表达式传递"的非 ASCII
    //      字符串逐字节损坏 (实测), 所以不用任务入参, 也不用 %0s 传中文) ----
    integer fails = 0;

    task wait_wr_n; input integer n; integer i; begin
        for (i = 0; i < n; i = i + 1) begin @(posedge wr_clk); #0.15; end
    end endtask
    task wait_rd_n; input integer n; integer i; begin
        for (i = 0; i < n; i = i + 1) begin @(posedge rd_clk); #0.15; end
    end endtask
    task wait_run_n; input integer n; begin
        if (run_on_rd) wait_rd_n(n); else wait_wr_n(n);
    end endtask

    // ---- 场景脚本 ----
    integer prev_wr, prev_rd, prev_both, prev_ovf, ovf_win;
    integer wmod_a, qc_a, rmod_a, wmod_c, qc_c, p_a, p_c, pw_a, pw_c;

    initial begin
        WH16 = 0; RH16 = 0;
        #0.7;                                   // 等 plusarg/时钟比算完
        WH16 = WH[15:0]; RH16 = RH[15:0];
        wait_wr_n(8);
        @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b1; g_rd_rst_n = 1'b1;
        wait_wr_n(20);

        if (c_lat) begin
            // ============ case LAT: 结构契约延迟 (空标志 / 满标志各一测) ============
            $display("== case LAT: 空/满标志同步延迟契约 (二级同步 ⇒ dt > 3*T) ==");
            g_run = 1'b0; g_pause = 1'b1; wait_wr_n(20);
            $display("  %0s: LAT 前置: 四实例复位后都为空", (A_empty && B_empty && C_empty && D_empty) ? "ok" : "FAIL-DETAIL");
            if ((A_empty && B_empty && C_empty && D_empty) !== 1'b1) fails = fails + 1;
            @(posedge wr_clk); #0.15; g_onewr = 1'b1;      // 每实例各 1 拍写 (共用时钟, 各自独立 FIFO)
            wait_wr_n(6);
            g_onewr = 1'b0;
            wait_rd_n(12);
            $display("  %0s: LAT 空延迟: A 记录到写入沿与 empty 拉低沿", (A_le0 != 0 && A_le1 != 0) ? "ok" : "FAIL-DETAIL");
            if ((A_le0 != 0 && A_le1 != 0) !== 1'b1) fails = fails + 1;
            $display("  %0s: LAT 空延迟: B 记录到写入沿与 empty 拉低沿", (B_le0 != 0 && B_le1 != 0) ? "ok" : "FAIL-DETAIL");
            if ((B_le0 != 0 && B_le1 != 0) !== 1'b1) fails = fails + 1;
            $display("  %0s: LAT 空延迟: C 记录到写入沿与 empty 拉低沿", (C_le0 != 0 && C_le1 != 0) ? "ok" : "FAIL-DETAIL");
            if ((C_le0 != 0 && C_le1 != 0) !== 1'b1) fails = fails + 1;
            $display("  %0s: LAT 空延迟: D 记录到写入沿与 empty 拉低沿", (D_le0 != 0 && D_le1 != 0) ? "ok" : "FAIL-DETAIL");
            if ((D_le0 != 0 && D_le1 != 0) !== 1'b1) fails = fails + 1;
            $display("  %0s: LAT A: 空标志延迟 > 3*T_rd dt=%0dps > %0dps", ((A_le1 - A_le0) > (TRD_PS*3)) ? "ok" : "FAIL-DETAIL", A_le1 - A_le0, TRD_PS*3);
            if (!((A_le1 - A_le0) > (TRD_PS*3))) fails = fails + 1; $display("LAT_CONTRACT_VIOLATION");
            $display("  %0s: LAT B: 空标志延迟 > 3*T_rd dt=%0dps > %0dps", ((B_le1 - B_le0) > (TRD_PS*3)) ? "ok" : "FAIL-DETAIL", B_le1 - B_le0, TRD_PS*3);
            if (!((B_le1 - B_le0) > (TRD_PS*3))) fails = fails + 1; $display("LAT_CONTRACT_VIOLATION");
            $display("  %0s: LAT C: 空标志延迟 > 3*T_rd dt=%0dps > %0dps", ((C_le1 - C_le0) > (TRD_PS*3)) ? "ok" : "FAIL-DETAIL", C_le1 - C_le0, TRD_PS*3);
            if (!((C_le1 - C_le0) > (TRD_PS*3))) fails = fails + 1; $display("LAT_CONTRACT_VIOLATION");
            $display("  %0s: LAT D: 空标志延迟 > 3*T_rd dt=%0dps > %0dps", ((D_le1 - D_le0) > (TRD_PS*3)) ? "ok" : "FAIL-DETAIL", D_le1 - D_le0, TRD_PS*3);
            if (!((D_le1 - D_le0) > (TRD_PS*3))) fails = fails + 1; $display("LAT_CONTRACT_VIOLATION");
            g_pause = 1'b0; g_fill = 1'b1;                 // 灌满 (四实例各自满)
            wait_wr_n(200);
            g_fill = 1'b0; g_pause = 1'b1; wait_wr_n(20);
            $display("  %0s: LAT 顺序前置: 四实例都已被灌满", (A_full && B_full && C_full && D_full) ? "ok" : "FAIL-DETAIL");
            if ((A_full && B_full && C_full && D_full) !== 1'b1) fails = fails + 1;
            @(posedge rd_clk); #0.15; g_onepop = 1'b1;     // 各弹 1 拍
            wait_rd_n(6);
            g_onepop = 1'b0;
            wait_wr_n(12);
            $display("  %0s: LAT 满延迟: A 记录到弹出沿与 full 拉低沿", (A_lf0 != 0 && A_lf1 != 0) ? "ok" : "FAIL-DETAIL");
            if ((A_lf0 != 0 && A_lf1 != 0) !== 1'b1) fails = fails + 1;
            $display("  %0s: LAT 满延迟: B 记录到弹出沿与 full 拉低沿", (B_lf0 != 0 && B_lf1 != 0) ? "ok" : "FAIL-DETAIL");
            if ((B_lf0 != 0 && B_lf1 != 0) !== 1'b1) fails = fails + 1;
            $display("  %0s: LAT 满延迟: C 记录到弹出沿与 full 拉低沿", (C_lf0 != 0 && C_lf1 != 0) ? "ok" : "FAIL-DETAIL");
            if ((C_lf0 != 0 && C_lf1 != 0) !== 1'b1) fails = fails + 1;
            $display("  %0s: LAT 满延迟: D 记录到弹出沿与 full 拉低沿", (D_lf0 != 0 && D_lf1 != 0) ? "ok" : "FAIL-DETAIL");
            if ((D_lf0 != 0 && D_lf1 != 0) !== 1'b1) fails = fails + 1;
            $display("  %0s: LAT A: 满标志延迟 > 3*T_wr dt=%0dps > %0dps", ((A_lf1 - A_lf0) > (TWR_PS*3)) ? "ok" : "FAIL-DETAIL", A_lf1 - A_lf0, TWR_PS*3);
            if (!((A_lf1 - A_lf0) > (TWR_PS*3))) fails = fails + 1; $display("LAT_CONTRACT_VIOLATION");
            $display("  %0s: LAT B: 满标志延迟 > 3*T_wr dt=%0dps > %0dps", ((B_lf1 - B_lf0) > (TWR_PS*3)) ? "ok" : "FAIL-DETAIL", B_lf1 - B_lf0, TWR_PS*3);
            if (!((B_lf1 - B_lf0) > (TWR_PS*3))) fails = fails + 1; $display("LAT_CONTRACT_VIOLATION");
            $display("  %0s: LAT C: 满标志延迟 > 3*T_wr dt=%0dps > %0dps", ((C_lf1 - C_lf0) > (TWR_PS*3)) ? "ok" : "FAIL-DETAIL", C_lf1 - C_lf0, TWR_PS*3);
            if (!((C_lf1 - C_lf0) > (TWR_PS*3))) fails = fails + 1; $display("LAT_CONTRACT_VIOLATION");
            $display("  %0s: LAT D: 满标志延迟 > 3*T_wr dt=%0dps > %0dps", ((D_lf1 - D_lf0) > (TWR_PS*3)) ? "ok" : "FAIL-DETAIL", D_lf1 - D_lf0, TWR_PS*3);
            if (!((D_lf1 - D_lf0) > (TWR_PS*3))) fails = fails + 1; $display("LAT_CONTRACT_VIOLATION");
            g_pause = 1'b0; g_drain = 1'b1; wait_rd_n(400);      // 收尾排空 (满足通用7)
            g_drain = 1'b0;
        end
        else if (c_reset) begin
            // ============ case RESET: 复位矩阵 ============
            $display("== case RESET: 空复位 / 满复位 / 在途两侧复位 / 单侧复位(脏) / 重新对齐 ==");
            // (1) 空 FIFO 复位
            g_pause = 1'b0; g_run = 1'b1; wait_wr_n(300);
            g_run = 1'b0; g_drain = 1'b1; wait_rd_n(300);
            $display("  %0s: RESET1 前置: 排空完成", (A_done && B_done && C_done && D_done) ? "ok" : "FAIL-DETAIL");
            if ((A_done && B_done && C_done && D_done) !== 1'b1) fails = fails + 1;
            g_drain = 1'b0; g_pause = 1'b1; wait_wr_n(10);
            @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b0; g_rd_rst_n = 1'b0;
            wait_wr_n(8*WH + 20);
            @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b1; g_rd_rst_n = 1'b1;
            wait_wr_n(2*WH + 10);
            $display("  %0s: RESET1: 空 FIFO 复位后 empty=1 / full=0", (A_empty && B_empty && C_empty && D_empty && !A_full && !B_full && !C_full && !D_full) ? "ok" : "FAIL-DETAIL");
            if ((A_empty && B_empty && C_empty && D_empty && !A_full && !B_full && !C_full && !D_full) !== 1'b1) fails = fails + 1;
            $display("  %0s: RESET1: 复位不产生任何幽灵读写", (A_wr==0 && A_rd==0 && C_wr==0 && C_rd==0) ? "ok" : "FAIL-DETAIL");
            if ((A_wr==0 && A_rd==0 && C_wr==0 && C_rd==0) !== 1'b1) fails = fails + 1;
            // (2) 灌满后复位 + 复位丢弃在途数据
            g_pause = 1'b0; g_fill = 1'b1;
            wait_wr_n(400);
            $display("  %0s: RESET2: 四实例都灌到 full=1", (A_full && B_full && C_full && D_full) ? "ok" : "FAIL-DETAIL");
            if ((A_full && B_full && C_full && D_full) !== 1'b1) fails = fails + 1;
            g_fill = 1'b0; g_pause = 1'b1; wait_wr_n(10);
            @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b0; g_rd_rst_n = 1'b0;
            wait_wr_n(8*WH + 20);
            @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b1; g_rd_rst_n = 1'b1;
            wait_wr_n(2*WH + 10);
            $display("  %0s: RESET2: 灌满后复位 ⇒ empty=1/full=0", (A_empty && !A_full) ? "ok" : "FAIL-DETAIL");
            if ((A_empty && !A_full) !== 1'b1) fails = fails + 1;
            g_pause = 1'b0; g_drain = 1'b1; wait_rd_n(200);
            $display("  %0s: RESET2: 复位丢弃全部在途数据 (复位后读不出任何字)", (A_rd==0 && B_rd==0 && C_rd==0 && D_rd==0) ? "ok" : "FAIL-DETAIL");
            if ((A_rd==0 && B_rd==0 && C_rd==0 && D_rd==0) !== 1'b1) fails = fails + 1;
            g_drain = 1'b0; g_pause = 1'b1; wait_wr_n(10);
            // (3) 在途数据 + 两侧同时复位 (不停流量) ⇒ 之后必须干净
            g_pause = 1'b0; g_run = 1'b1; wait_wr_n(400);
            @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b0; g_rd_rst_n = 1'b0;
            wait_wr_n(8*WH + 20);
            @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b1; g_rd_rst_n = 1'b1;
            wait_wr_n(2*WH + 10);
            g_run = 1'b0; g_drain = 1'b1; wait_rd_n(600);
            $display("  %0s: RESET3: 在途复位后仍能排空 (无挂死)", (A_done && B_done && C_done && D_done) ? "ok" : "FAIL-DETAIL");
            if ((A_done && B_done && C_done && D_done) !== 1'b1) fails = fails + 1;
            $display("  %0s: RESET3: 在途两侧复位后逐字干净 (在途数据全丢, 无旧字重现)", (A_err==0 && B_err==0 && C_err==0 && D_err==0) ? "ok" : "FAIL-DETAIL");
            if ((A_err==0 && B_err==0 && C_err==0 && D_err==0) !== 1'b1) fails = fails + 1;
            $display("  %0s: RESET3: 复位后流量正常恢复 (正证据)", (A_wr>0 && A_rd>0) ? "ok" : "FAIL-DETAIL");
            if ((A_wr>0 && A_rd>0) !== 1'b1) fails = fails + 1;
            g_drain = 1'b0; g_pause = 1'b1; wait_wr_n(10);
            // (4) 只复位读侧 (脏): 期望 弹出数 P == 写指针 W, 而真实未读 qcnt < W ⇒ 多弹
            //     前置用**确定性**状态: 灌满 → 只排 2 个 rd 沿 (R=1..2, qcnt=DEPTH-R 必非零) → 停。
            g_pause = 1'b0; g_fill = 1'b1; wait_wr_n(200);
            g_fill = 1'b0; g_drain = 1'b1; wait_rd_n(2);
            g_drain = 1'b0; g_pause = 1'b1; wait_wr_n(4*WH + 20);
            @(posedge wr_clk); #0.15; g_dirty = 1'b1;
            wait_wr_n(4*WH + 20);
            $display("  %0s: RESET4 前置: 脏窗口快照已取", (A_sqc != 32'hFFFFFFFF && C_sqc != 32'hFFFFFFFF) ? "ok" : "FAIL-DETAIL");
            if ((A_sqc != 32'hFFFFFFFF && C_sqc != 32'hFFFFFFFF) !== 1'b1) fails = fails + 1;
            wmod_a = A_swm; qc_a = A_sqc; rmod_a = (wmod_a - qc_a) & 31;
            wmod_c = C_swm; qc_c = C_sqc;
            $display("  %0s: RESET4 前置(A): 读指针非零且未读数非零 (否则本项无判别力)", (rmod_a != 0 && qc_a != 0) ? "ok" : "FAIL-DETAIL");
            if ((rmod_a != 0 && qc_a != 0) !== 1'b1) fails = fails + 1;
            $display("  %0s: RESET4 前置(C): 读指针非零且未读数非零", (((wmod_c - qc_c) & 7) != 0 && qc_c != 0) ? "ok" : "FAIL-DETAIL");
            if ((((wmod_c - qc_c) & 7) != 0 && qc_c != 0) !== 1'b1) fails = fails + 1;
            $display("  info: RESET4 快照 A: W=%0d qcnt=%0d R=%0d | C: W=%0d qcnt=%0d R=%0d",
                     wmod_a, qc_a, rmod_a, wmod_c, qc_c, ((wmod_c-qc_c)&7));
            @(posedge wr_clk); #0.15; g_rd_rst_n = 1'b0;    // 只复位读侧
            wait_wr_n(8*RH + 40);
            @(posedge wr_clk); #0.15; g_rd_rst_n = 1'b1;
            wait_wr_n(2*RH + 20);
            g_drain = 1'b1;                                 // 脏排空 (一直读到空)
            wait_rd_n(400);
            p_a = A_dpop; p_c = C_dpop;
            $display("  info: RESET4 脏排空 A 弹数 P=%0d (期望 == W=%0d; 真实未读只有 %0d) | C 弹数 %0d (期望 %0d)",
                     p_a, wmod_a, qc_a, p_c, wmod_c);
            $display("  %0s: RESET4: 只复位读侧 ⇒ 弹出数 == 写指针 W (指针错位实锤)", (p_a == wmod_a) ? "ok" : "FAIL-DETAIL");
            if ((p_a == wmod_a) !== 1'b1) fails = fails + 1;
            $display("  %0s: RESET4: 弹出数 != 真实未读数 (多弹 = 静默脏数据)", (p_a != qc_a) ? "ok" : "FAIL-DETAIL");
            if ((p_a != qc_a) !== 1'b1) fails = fails + 1;
            $display("  %0s: RESET4: C 实例(深度4)同样多弹 == W != qcnt", (p_c == wmod_c && p_c != qc_c) ? "ok" : "FAIL-DETAIL");
            if ((p_c == wmod_c && p_c != qc_c) !== 1'b1) fails = fails + 1;
            $display("  %0s: RESET4: 脏窗口确实弹出了字 (正证据)", (p_a > 0) ? "ok" : "FAIL-DETAIL");
            if ((p_a > 0) !== 1'b1) fails = fails + 1;
            g_drain = 1'b0; g_pause = 1'b1; wait_wr_n(20);
            // (5) 重新对齐后, 只复位写侧 (脏): 期望 灌满字数 PW == R + DEPTH > 真实空位
            @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b0; g_rd_rst_n = 1'b0; g_dirty = 1'b0;
            wait_wr_n(8*WH + 20);
            @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b1; g_rd_rst_n = 1'b1;
            wait_wr_n(2*WH + 10);
            g_pause = 1'b0; g_fill = 1'b1; wait_wr_n(200);        // 确定性前置 (同 (4))
            g_fill = 1'b0; g_drain = 1'b1; wait_rd_n(2);
            g_drain = 1'b0; g_pause = 1'b1; wait_wr_n(4*WH + 20);
            @(posedge wr_clk); #0.15; g_dirty = 1'b1;
            wait_wr_n(4*WH + 20);
            $display("  %0s: RESET5 前置: 脏窗口快照已取", (A_hseq != 32'hFFFFFFFF && A_sqc != 32'hFFFFFFFF) ? "ok" : "FAIL-DETAIL");
            if ((A_hseq != 32'hFFFFFFFF && A_sqc != 32'hFFFFFFFF) !== 1'b1) fails = fails + 1;
            wmod_a = A_swm; qc_a = A_sqc; rmod_a = (wmod_a - qc_a) & 31;
            wmod_c = C_swm; qc_c = C_sqc;
            $display("  %0s: RESET5 前置(A): 读指针非零且未读数非零 (否则本项无判别力)", (rmod_a != 0 && qc_a != 0) ? "ok" : "FAIL-DETAIL");
            if ((rmod_a != 0 && qc_a != 0) !== 1'b1) fails = fails + 1;
            $display("  %0s: RESET5 前置(C): 读指针非零且未读数非零", (((wmod_c - qc_c) & 7) != 0 && qc_c != 0) ? "ok" : "FAIL-DETAIL");
            if ((((wmod_c - qc_c) & 7) != 0 && qc_c != 0) !== 1'b1) fails = fails + 1;
            $display("  info: RESET5 快照 A: W=%0d qcnt=%0d R=%0d head_seq=%0d | C: W=%0d qcnt=%0d",
                     wmod_a, qc_a, rmod_a, A_hseq, wmod_c, qc_c);
            @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b0;    // 只复位写侧
            wait_wr_n(8*RH + 40);
            @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b1;
            wait_wr_n(2*RH + 20);
            g_fill = 1'b1;                                  // 写侧全速灌到满
            wait_wr_n(200);
            g_fill = 1'b0;
            pw_a = A_dwr; pw_c = C_dwr;
            $display("  info: RESET5 脏灌 A PW=%0d (期望 R+DEPTH=%0d; 真实空位 %0d; 超标 %0d) | C PW=%0d (期望 %0d, 真实空位 %0d)",
                     pw_a, rmod_a + 16, 16 - qc_a, pw_a - (16 - qc_a), pw_c, ((wmod_c-qc_c)&7) + 4, 4 - qc_c);
            $display("  %0s: RESET5: 只复位写侧 ⇒ 灌满字数 == R+DEPTH (指针错位实锤)", (pw_a == rmod_a + 16) ? "ok" : "FAIL-DETAIL");
            if ((pw_a == rmod_a + 16) !== 1'b1) fails = fails + 1;
            $display("  %0s: RESET5: 写入数 > 真实空位 (覆盖了未读字)", (pw_a > (16 - qc_a)) ? "ok" : "FAIL-DETAIL");
            if ((pw_a > (16 - qc_a)) !== 1'b1) fails = fails + 1;
            $display("  %0s: RESET5: C 实例(深度4)同样多写 == R+DEPTH", (pw_c == (((wmod_c - qc_c) & 7) + 4) && pw_c > (4 - qc_c)) ? "ok" : "FAIL-DETAIL");
            if ((pw_c == (((wmod_c - qc_c) & 7) + 4) && pw_c > (4 - qc_c)) !== 1'b1) fails = fails + 1;
            g_fill = 1'b0; g_drain = 1'b1; wait_rd_n(200);
            $display("  %0s: RESET5: 被覆盖的未读字读出时 seq 已变 (内容实锤损坏)", (A_fpseq != A_hseq) ? "ok" : "FAIL-DETAIL");
            if ((A_fpseq != A_hseq) !== 1'b1) fails = fails + 1;
            g_drain = 1'b0; g_pause = 1'b1;
            // (6) 重新对齐复位 ⇒ 干净可用
            @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b0; g_rd_rst_n = 1'b0; g_dirty = 1'b0;
            wait_wr_n(8*WH + 20);
            @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b1; g_rd_rst_n = 1'b1;
            wait_wr_n(2*WH + 10);
            g_pause = 1'b0; g_run = 1'b1; wait_wr_n(600);
            g_run = 1'b0; g_drain = 1'b1; wait_rd_n(600);
            $display("  %0s: RESET6: 重新对齐复位后逐字干净 (恢复可用)", (A_err==0 && B_err==0 && C_err==0 && D_err==0) ? "ok" : "FAIL-DETAIL");
            if ((A_err==0 && B_err==0 && C_err==0 && D_err==0) !== 1'b1) fails = fails + 1;
            $display("  %0s: RESET6: 恢复后流量正常 (正证据)", (A_wr>0 && A_rd>0) ? "ok" : "FAIL-DETAIL");
            if ((A_wr>0 && A_rd>0) !== 1'b1) fails = fails + 1;
        end
        else if (c_clkstop) begin
            // ============ case CLKSTOP: 时钟停摆 ============
            $display("== case CLKSTOP: 读时钟停摆 / 写时钟停摆 ==");
            g_pause = 1'b0; g_run = 1'b1; wait_run_n(300);
            // (1) 停读时钟: 写侧必被 full 挡住 (不挂死), 恢复后逐字补齐
            stop_rd = 1'b1;
            prev_wr = A_wr;
            $display("  info: CLKSTOP 停读时钟 t=%0t 时 A_wr=%0d A_rd=%0d", $time, A_wr, A_rd);
            wait_wr_n(600);
            $display("  %0s: CLKSTOP1: 停读时钟后四实例都被写满 (full=1)", (A_full && B_full && C_full && D_full) ? "ok" : "FAIL-DETAIL");
            if ((A_full && B_full && C_full && D_full) !== 1'b1) fails = fails + 1;
            $display("  %0s: CLKSTOP1: 停摆期间写侧仍在推进 (不是挂死)", (A_wr > prev_wr) ? "ok" : "FAIL-DETAIL");
            if ((A_wr > prev_wr) !== 1'b1) fails = fails + 1;
            prev_rd = A_rd;
            $display("  info: CLKSTOP 停摆结束 A_wr=%0d A_rd=%0d (读侧应未推进)", A_wr, A_rd);
            stop_rd = 1'b0;
            g_run = 1'b0; g_drain = 1'b1;
            wait_rd_n(2000);
            $display("  %0s: CLKSTOP1: 读时钟恢复后全部排空 (无挂死)", (A_done && B_done && C_done && D_done) ? "ok" : "FAIL-DETAIL");
            if ((A_done && B_done && C_done && D_done) !== 1'b1) fails = fails + 1;
            $display("  %0s: CLKSTOP1: 恢复后读侧真的继续消费", (A_rd > prev_rd) ? "ok" : "FAIL-DETAIL");
            if ((A_rd > prev_rd) !== 1'b1) fails = fails + 1;
            $display("  %0s: CLKSTOP1: 恢复后逐字干净 (无丢失/重复/重排)", (A_err==0 && B_err==0 && C_err==0 && D_err==0) ? "ok" : "FAIL-DETAIL");
            if ((A_err==0 && B_err==0 && C_err==0 && D_err==0) !== 1'b1) fails = fails + 1;
            g_drain = 1'b0; g_pause = 1'b1; wait_wr_n(10);
            // (2) 停写时钟: 读侧把存量排空, 恢复后继续
            g_pause = 1'b0; g_fill = 1'b1; wait_wr_n(200);
            g_fill = 1'b0; g_pause = 1'b1; wait_wr_n(10);
            stop_wr = 1'b1;
            prev_wr = A_wr; prev_rd = A_rd;
            g_drain = 1'b1;                                 // 读侧全速排空
            wait_rd_n(2000);
            $display("  info: CLKSTOP 停写时钟期间 A_wr=%0d(应冻结) A_rd=%0d", A_wr, A_rd);
            $display("  %0s: CLKSTOP2: 停写时钟期间写侧完全冻结 (计数不变)", (A_wr == prev_wr) ? "ok" : "FAIL-DETAIL");
            if ((A_wr == prev_wr) !== 1'b1) fails = fails + 1;
            $display("  %0s: CLKSTOP2: 停写时钟期间读侧照常排空", (A_rd > prev_rd) ? "ok" : "FAIL-DETAIL");
            if ((A_rd > prev_rd) !== 1'b1) fails = fails + 1;
            g_drain = 1'b0; g_pause = 1'b1;
            stop_wr = 1'b0;
            wait_wr_n(40);
            g_pause = 1'b0; g_run = 1'b1; wait_run_n(400);
            g_run = 1'b0; g_drain = 1'b1; wait_rd_n(2000);
            $display("  %0s: CLKSTOP2: 写时钟恢复后逐字干净", (A_err==0 && B_err==0 && C_err==0 && D_err==0) ? "ok" : "FAIL-DETAIL");
            if ((A_err==0 && B_err==0 && C_err==0 && D_err==0) !== 1'b1) fails = fails + 1;
        end
        else if (c_bound) begin
            // ============ case BOUND: 满/空边界捶打 ============
            $display("== case BOUND: 灌满 / 排空 / 空态常读 / 1:1 高速两端捶打 ==");
            g_pause = 1'b0; g_fill = 1'b1;
            wait_wr_n(200);
            $display("  %0s: BOUND1: 灌到 full=1", (A_full && B_full && C_full && D_full) ? "ok" : "FAIL-DETAIL");
            if ((A_full && B_full && C_full && D_full) !== 1'b1) fails = fails + 1;
            prev_wr = A_wr; wait_wr_n(50);
            $display("  %0s: BOUND1: full 期间写被严格挡住 (计数不再增)", (A_wr == prev_wr) ? "ok" : "FAIL-DETAIL");
            if ((A_wr == prev_wr) !== 1'b1) fails = fails + 1;
            $display("  %0s: BOUND1: 占用极值 == DEPTH (真的到过满)", (A_omax == 16 && C_omax == 4) ? "ok" : "FAIL-DETAIL");
            if ((A_omax == 16 && C_omax == 4) !== 1'b1) fails = fails + 1;
            $display("  %0s: BOUND1: 存在被 full 挡掉的写 (正证据)", (A_fblk > 0) ? "ok" : "FAIL-DETAIL");
            if ((A_fblk > 0) !== 1'b1) fails = fails + 1;
            // (2) 满→空**最速排空**角落: 立刻全速读, 并测 full 撤销延迟必须有界
            //     (悲观 full 若不在有限拍内撤销, 写侧会被永久挂住 = 结构性死锁;
            //      这条同时是 LAT 结构的第二个独立观测点)
            g_fill = 1'b0; g_drain = 1'b1;
            @(posedge rd_clk); #0.15; g_onepop = 1'b1;
            wait_rd_n(6);
            g_onepop = 1'b0;
            wait_rd_n(200);
            $display("  %0s: BOUND2: 排空完成", (A_done && B_done && C_done && D_done) ? "ok" : "FAIL-DETAIL");
            if ((A_done && B_done && C_done && D_done) !== 1'b1) fails = fails + 1;
            // 上界取 6*T_wr (理论值 = eps+3T ∈ (3T,4T]; 门里留 2T 余量, 不把界钉在样本极值上;
            // 真正要否掉的是"full 永不撤销"= 结构性死锁 ⇒ 那时 A_lf1 根本不记录)
            $display("  %0s: BOUND2: 满→空最速排空时 full 撤销延迟有界 (实测 %0dps, 上界 6*T_wr=%0dps)", ((A_lf0 != 0) && (A_lf1 > A_lf0) && ((A_lf1 - A_lf0) <= TWR_PS*6)) ? "ok" : "FAIL-DETAIL", A_lf1 - A_lf0, TWR_PS*6);
            if (((A_lf0 != 0) && (A_lf1 > A_lf0) && ((A_lf1 - A_lf0) <= TWR_PS*6)) !== 1'b1) fails = fails + 1;
            $display("  %0s: BOUND2: 占用到过 0", (A_omin == 0) ? "ok" : "FAIL-DETAIL");
            if ((A_omin == 0) !== 1'b1) fails = fails + 1;
            prev_rd = A_rd; wait_rd_n(60);
            $display("  %0s: BOUND2: 空态下常读弹不出任何字", (A_rd == prev_rd) ? "ok" : "FAIL-DETAIL");
            if ((A_rd == prev_rd) !== 1'b1) fails = fails + 1;
            $display("  %0s: BOUND2: 存在空态被忽略的读 (正证据)", (A_eblk > 0) ? "ok" : "FAIL-DETAIL");
            if ((A_eblk > 0) !== 1'b1) fails = fails + 1;
            // (3) 1:1 高速捶打 (g_duty=2: 等周期下两侧都 5/8 ⇒ 占用 0..DEPTH 全区间随机游走)
            prev_wr = A_frise; prev_rd = A_erise; prev_both = both_a;
            g_drain = 1'b0; g_pause = 1'b0; g_run = 1'b1; g_duty = 2'd2;
            wait_run_n(4000);
            $display("  info: BOUND3 期间 A: full 上升 %0d 次, empty 上升 %0d 次 (C: %0d / %0d)",
                     A_frise - prev_wr, A_erise - prev_rd, C_frise, C_erise);
            $display("  %0s: BOUND3: 1:1 捶打期间 full 上升 >= 5 次", (A_frise - prev_wr >= 5) ? "ok" : "FAIL-DETAIL");
            if ((A_frise - prev_wr >= 5) !== 1'b1) fails = fails + 1;
            $display("  %0s: BOUND3: 1:1 捶打期间 empty 上升 >= 5 次", (A_erise - prev_rd >= 5) ? "ok" : "FAIL-DETAIL");
            if ((A_erise - prev_rd >= 5) !== 1'b1) fails = fails + 1;
            $display("  %0s: BOUND3: 小深度实例 (D=4) 两端都撞过 >= 5 次", (C_frise >= 5 && C_erise >= 5) ? "ok" : "FAIL-DETAIL");
            if ((C_frise >= 5 && C_erise >= 5) !== 1'b1) fails = fails + 1;
            $display("  info: BOUND3 期间 full&&empty 同时为 1 的拍数 = %0d (DEPTH>=4 且同步只 2 级时该角落不可达: 排空 DEPTH 个字必然慢于 full 撤销)", both_a - prev_both);
            g_duty = 2'd0; g_run = 1'b0; g_drain = 1'b1; wait_rd_n(400);
            $display("  %0s: BOUND3: 收尾排空完成", (A_done && B_done && C_done && D_done) ? "ok" : "FAIL-DETAIL");
            if ((A_done && B_done && C_done && D_done) !== 1'b1) fails = fails + 1;
        end
        else if (c_early) begin
            // ============ case EARLY: 复位释放窗口 (审计 F-1) ============
            // 构造: 驱动侧改用**原始 rst_n** 释放 (比 DUT 内部两级同步释放早 1~2 个 wr 拍),
            //   且持续提供写 (g_fill) ⇒ 稳定出现"生产者已放行、FIFO 写域还在复位"的窗口。
            // 判据形态 = "**丢字必须被计数到**", 而不是"不丢字":
            //   ① 窗口内被拒的写数 (ovf_cnt 差分) ∈ [1,4] —— 修前 (full 复位值 = 0) 此项 = 0;
            //   ② 窗口后 <=6 个 wr 拍内必有写被接受 (full 不卡死 —— 这是 (a) 方案唯一可能的坑);
            //   ③ 之后逐字正确 + 能排空。
            $display("== case EARLY: 复位释放窗口内的被拒写是否被计数 (F-1) ==");
            g_run = 1'b0; g_pause = 1'b1; wait_wr_n(20);
            @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b0; g_rd_rst_n = 1'b0;
            wait_wr_n(4*WH + 20);
            g_early = 1'b1; g_fill = 1'b1;
            prev_ovf = A_ovf; prev_wr = A_wr;
            @(posedge wr_clk); #0.15; g_wr_rst_n = 1'b1; g_rd_rst_n = 1'b1;
            wait_wr_n(6);
            ovf_win = A_ovf - prev_ovf;
            $display("  info: EARLY 窗口内被拒写 A=%0d C=%0d (期望 1..4); 窗口后已接受写 A=%0d",
                     ovf_win, C_ovf, A_wr - prev_wr);
            $display("  %0s: EARLY-1: 复位释放窗口内被拒的写被计数 (1..4)", (ovf_win >= 1 && ovf_win <= 4) ? "ok" : "FAIL-DETAIL");
            if ((ovf_win >= 1 && ovf_win <= 4) !== 1'b1) fails = fails + 1;
            $display("  %0s: EARLY-2: 窗口后 6 拍内立刻能写 (full 不卡死)", ((A_wr - prev_wr) >= 1) ? "ok" : "FAIL-DETAIL");
            if (((A_wr - prev_wr) >= 1) !== 1'b1) fails = fails + 1;
            g_fill = 1'b0; g_early = 1'b0; g_pause = 1'b0; g_run = 1'b1; wait_run_n(600);
            g_run = 1'b0; g_drain = 1'b1; wait_rd_n(600);
            $display("  %0s: EARLY-3: 收尾排空完成", (A_done && B_done && C_done && D_done) ? "ok" : "FAIL-DETAIL");
            if ((A_done && B_done && C_done && D_done) !== 1'b1) fails = fails + 1;
            $display("  %0s: EARLY-4: 窗口后数据逐字正确 (金标准)", (A_err==0 && B_err==0 && C_err==0 && D_err==0) ? "ok" : "FAIL-DETAIL");
            if ((A_err==0 && B_err==0 && C_err==0 && D_err==0) !== 1'b1) fails = fails + 1;
        end
        else if (c_mir) begin
            // ============ case MIR: u_E = M1 实参实例 ==================================
            // 被测 = u_E (WIDTH=32/DEPTH=256/FWFT=1/AW=8), 时钟比 12.8ns:8.0ns = **1.6**
            //   (= dp 156.25MHz 写 → pcie 250MHz 读 的 2x 缩放; 0.8ns 步长表达不出 4.0ns)。
            // 判据 (E 专属; A..D 在本工况只吃通用判据):
            //   E1 复位后空/不满      E2 单写 ⇒ empty 拉低延迟 > 3*T_rd (硬契约, 与 case LAT 同式)
            //   E3 灌到满 (DEPTH=256) E4 满态续写 ⇒ 拒写被计数 (ovf 探针有牙; F-1 同族)
            //   E5 单弹 ⇒ full 拉低延迟 > 3*T_wr
            //   E6 随机占空长跑 + 排空 (E_done) ⇒ E7 内容/灰码/记账汇总 (逐字 0 错)
            //   E8 拒写探针 == 门自己的挡写计数 (±2; 探针被拿掉/恒 0 立刻 FAIL)
            $display("== case MIR: u_E = M1 实参 (32/256/FWFT=1) @ T_wr=12.8ns : T_rd=8.0ns (ratio 1.6) ==");
            g_pause = 1'b1; wait_wr_n(20);
            $display("  %0s: E1 复位后 empty=1 / full=0", (E_empty && !E_full) ? "ok" : "FAIL-DETAIL");
            if ((E_empty && !E_full) !== 1'b1) fails = fails + 1;
            // ---- E2 单写延迟契约 ----
            @(posedge wr_clk); #0.15; g_onewr = 1'b1;
            wait_wr_n(6);
            g_onewr = 1'b0;
            wait_rd_n(20);
            $display("  %0s: E2a 单写被观察到 (le0=%0d le1=%0d)", (E_le0 != 0 && E_le1 != 0) ? "ok" : "FAIL-DETAIL", E_le0, E_le1);
            if ((E_le0 != 0 && E_le1 != 0) !== 1'b1) fails = fails + 1;
            $display("  %0s: E2b empty 拉低延迟 > 3*T_rd (dt=%0dps > %0dps)", ((E_le1 - E_le0) > (TRD_PS*3)) ? "ok" : "FAIL-DETAIL", E_le1 - E_le0, TRD_PS*3);
            if (!((E_le1 - E_le0) > (TRD_PS*3))) fails = fails + 1;
            g_drain = 1'b1; wait_rd_n(30); g_drain = 1'b0; wait_wr_n(20);
            // ---- E3 灌满 (256 深) ----
            g_pause = 1'b0; g_fill = 1'b1; wait_wr_n(400);
            $display("  %0s: E3 灌到 full=1 (DEPTH=256)", (E_full) ? "ok" : "FAIL-DETAIL");
            if ((E_full) !== 1'b1) fails = fails + 1;
            // ---- E4 满态续写 ⇒ 拒写计数 ----
            prev_ovf = E_ovf;
            wait_wr_n(200);
            ovf_win = E_ovf - prev_ovf;
            $display("  info: E4 满态续写 200 拍, 拒写窗口 = %0d", ovf_win);
            $display("  %0s: E4 满态被拒的写被计数 (探针有牙)", (ovf_win > 0) ? "ok" : "FAIL-DETAIL");
            if ((ovf_win > 0) !== 1'b1) fails = fails + 1;
            // ---- E5 单弹延迟契约 (满态弹一字 ⇒ full 落) ----
            g_fill = 1'b0; g_pause = 1'b1; wait_wr_n(20);
            @(posedge rd_clk); #0.15; g_onepop = 1'b1;
            wait_rd_n(6);
            g_onepop = 1'b0;
            wait_wr_n(20);
            $display("  %0s: E5a 单弹被观察到 (lf0=%0d lf1=%0d)", (E_lf0 != 0 && E_lf1 != 0) ? "ok" : "FAIL-DETAIL", E_lf0, E_lf1);
            if ((E_lf0 != 0 && E_lf1 != 0) !== 1'b1) fails = fails + 1;
            $display("  %0s: E5b full 拉低延迟 > 3*T_wr (dt=%0dps > %0dps)", ((E_lf1 - E_lf0) > (TWR_PS*3)) ? "ok" : "FAIL-DETAIL", E_lf1 - E_lf0, TWR_PS*3);
            if (!((E_lf1 - E_lf0) > (TWR_PS*3))) fails = fails + 1;
            // ---- E6 随机占空长跑 + 排空 ----
            g_pause = 1'b0; g_run = 1'b1; g_duty = 2'd1;
            wait_run_n(6000);
            g_run = 1'b0; g_duty = 2'd0; g_drain = 1'b1;
            wait_rd_n(4000);
            // ⚠️ E_done 的判据式 = `g_drain && empty && !rd_ok` ⇒ **必须在 g_drain 还高时查**
            //   (清掉 g_drain 的下一拍 o_done 就被清 — 本相位第一版就是这么假红的)。
            $display("  %0s: E6 排空到 done", (E_done) ? "ok" : "FAIL-DETAIL");
            if ((E_done) !== 1'b1) fails = fails + 1;
            g_drain = 1'b0; wait_wr_n(20);
            // ---- E7 汇总 ----
            $display("  info: E7 E_wr=%0d E_rd=%0d E_cmp=%0d E_err=%0d E_gmon=%0d E_gchk=%0d E_omax=%0d E_omin=%0d E_fblk=%0d E_eblk=%0d E_ovf=%0d",
                     E_wr, E_rd, E_cmp, E_err, E_gmon, E_gchk, E_omax, E_omin, E_fblk, E_eblk, E_ovf);
            $display("  %0s: E7a 内容 0 错 (逐字 == 金标准)", (E_err == 0) ? "ok" : "FAIL-DETAIL");
            if ((E_err == 0) !== 1'b1) fails = fails + 1;
            $display("  %0s: E7b 真做过对拍/写/读 (cmp/wr/rd 全 > 0)", (E_cmp>0 && E_wr>0 && E_rd>0) ? "ok" : "FAIL-DETAIL");
            if ((E_cmp>0 && E_wr>0 && E_rd>0) !== 1'b1) fails = fails + 1;
            $display("  %0s: E7c 排空后 写-读 == 0", ((E_wr-E_rd)==0) ? "ok" : "FAIL-DETAIL");
            if (((E_wr-E_rd)==0) !== 1'b1) fails = fails + 1;
            $display("  %0s: E7d 灰码监视 0 违规 且 真验证过 (gmon==0 && gchk>0)", (E_gmon==0 && E_gchk>0) ? "ok" : "FAIL-DETAIL");
            if ((E_gmon==0 && E_gchk>0) !== 1'b1) fails = fails + 1;
            $display("  %0s: E7e 占用探针非空且 >= 金标准峰值, 硬界 0 违规", (u_E.occ_w_max > 0 && u_E.occ_w_max >= E_omax && u_E.occ_bad_cnt == 0) ? "ok" : "FAIL-DETAIL");
            if ((u_E.occ_w_max > 0 && u_E.occ_w_max >= E_omax && u_E.occ_bad_cnt == 0) !== 1'b1) fails = fails + 1;
            $display("  %0s: E7f 探针到过满量程 (omax == 256 ⇒ 灌满判据不是空判据)", (E_omax == 256) ? "ok" : "FAIL-DETAIL");
            if ((E_omax == 256) !== 1'b1) fails = fails + 1;
            // ---- E8 拒写探针 vs 门自己的挡写计数 ----
            $display("  %0s: E8 DUT 拒写计数 == 门自己的挡写计数 (±2)", ((E_ovf+2 >= E_fblk) && (E_fblk+2 >= E_ovf)) ? "ok" : "FAIL-DETAIL");
            if (((E_ovf+2 >= E_fblk) && (E_fblk+2 >= E_ovf)) !== 1'b1) fails = fails + 1;
        end
        else begin
            // ============ case BAL / WRFAST / RDFAST: 常规对拍 (含极端时钟比) ============
            $display("== case %0s: 金标准对拍 (随机占空比, 不同周期) ==",
                     c_wrfast ? "WRFAST(100:1)" : c_rdfast ? "RDFAST(1:100)" : "BAL");
            g_pause = 1'b0; g_run = 1'b1;
            if (c_bal) g_duty = 2'd1;              // 写5/8 读4/8: 5:4 时钟下速率精确匹配 ⇒ 占用全区间游走
            wait_run_n(30000);
            g_run = 1'b0; g_duty = 2'd0; g_drain = 1'b1;
            wait_rd_n(6000);
            $display("  %0s: BAL: 排空完成 (四实例)", (A_done && B_done && C_done && D_done) ? "ok" : "FAIL-DETAIL");
            if ((A_done && B_done && C_done && D_done) !== 1'b1) fails = fails + 1;
            if (c_wrfast) begin
                $display("  %0s: WRFAST: 写侧确实被 full 挡过 (100:1 下必然)", (A_fblk > 0) ? "ok" : "FAIL-DETAIL");
            if ((A_fblk > 0) !== 1'b1) fails = fails + 1;
                $display("  %0s: WRFAST: 占用到过 DEPTH", (A_omax == 16) ? "ok" : "FAIL-DETAIL");
            if ((A_omax == 16) !== 1'b1) fails = fails + 1;
            end
            if (c_rdfast) begin
                $display("  %0s: RDFAST: 读侧确实被 empty 挡过 (1:100 下必然)", (A_eblk > 0) ? "ok" : "FAIL-DETAIL");
            if ((A_eblk > 0) !== 1'b1) fails = fails + 1;
                $display("  %0s: RDFAST: 占用到过 0", (A_omin == 0) ? "ok" : "FAIL-DETAIL");
            if ((A_omin == 0) !== 1'b1) fails = fails + 1;
            end
        end

        // ---- 收尾: 判据表 ----
        $display("");
        $display("== 判据表 (每实例) ==");
        $display("  inst WIDTH/DEPTH/FWFT   写    读   比较  内容错  灰码违规/验证  占用max/min  full挡/empty挡  fullUp/emptyUp  队列余");
        $display("  A    72/16/FWFT=1     %0d %0d %0d %0d %0d/%0d %0d/%0d %0d/%0d %0d/%0d %0d",
                 A_wr,A_rd,A_cmp,A_err,A_gmon,A_gchk,A_omax,A_omin,A_fblk,A_eblk,A_frise,A_erise,(A_wr-A_rd));
        $display("  B    72/16/FWFT=0     %0d %0d %0d %0d %0d/%0d %0d/%0d %0d/%0d %0d/%0d %0d",
                 B_wr,B_rd,B_cmp,B_err,B_gmon,B_gchk,B_omax,B_omin,B_fblk,B_eblk,B_frise,B_erise,(B_wr-B_rd));
        $display("  C    40/4/FWFT=1      %0d %0d %0d %0d %0d/%0d %0d/%0d %0d/%0d %0d/%0d %0d",
                 C_wr,C_rd,C_cmp,C_err,C_gmon,C_gchk,C_omax,C_omin,C_fblk,C_eblk,C_frise,C_erise,(C_wr-C_rd));
        $display("  D    40/4/FWFT=0      %0d %0d %0d %0d %0d/%0d %0d/%0d %0d/%0d %0d/%0d %0d",
                 D_wr,D_rd,D_cmp,D_err,D_gmon,D_gchk,D_omax,D_omin,D_fblk,D_eblk,D_frise,D_erise,(D_wr-D_rd));
        // ⭐ M1: u_E (只在 c_mir 工况参与激励; 其余工况全 0 = 预期)
        $display("  E    32/256/FWFT=1    %0d %0d %0d %0d %0d/%0d %0d/%0d %0d/%0d %0d/%0d %0d",
                 E_wr,E_rd,E_cmp,E_err,E_gmon,E_gchk,E_omax,E_omin,E_fblk,E_eblk,E_frise,E_erise,(E_wr-E_rd));

        // ---- 通用判据 (所有 case) ----
        $display("  %0s: 通用1: 四实例内容错 0 (无丢失/重复/重排)", (A_err==0 && B_err==0 && C_err==0 && D_err==0) ? "ok" : "FAIL-DETAIL");
            if ((A_err==0 && B_err==0 && C_err==0 && D_err==0) !== 1'b1) fails = fails + 1;
        $display("  %0s: 通用2: 四实例都真做过 dout 对拍 (比较数 > 0)", (A_cmp>0 && B_cmp>0 && C_cmp>0 && D_cmp>0) ? "ok" : "FAIL-DETAIL");
            if ((A_cmp>0 && B_cmp>0 && C_cmp>0 && D_cmp>0) !== 1'b1) fails = fails + 1;
        $display("  %0s: 通用3: 四实例都真有被接受的写", (A_wr>0 && B_wr>0 && C_wr>0 && D_wr>0) ? "ok" : "FAIL-DETAIL");
            if ((A_wr>0 && B_wr>0 && C_wr>0 && D_wr>0) !== 1'b1) fails = fails + 1;
        $display("  %0s: 通用4: 四实例都真有弹出", (A_rd>0 && B_rd>0 && C_rd>0 && D_rd>0) ? "ok" : "FAIL-DETAIL");
            if ((A_rd>0 && B_rd>0 && C_rd>0 && D_rd>0) !== 1'b1) fails = fails + 1;
        $display("  %0s: 通用5: 灰码监视零违规", (A_gmon==0 && B_gmon==0 && C_gmon==0 && D_gmon==0) ? "ok" : "FAIL-DETAIL");
            if ((A_gmon==0 && B_gmon==0 && C_gmon==0 && D_gmon==0) !== 1'b1) fails = fails + 1;
        $display("  %0s: 通用6: 灰码监视真有被验证的指针变化 (判据非空)", (A_gchk>0 && B_gchk>0 && C_gchk>0 && D_gchk>0) ? "ok" : "FAIL-DETAIL");
            if ((A_gchk>0 && B_gchk>0 && C_gchk>0 && D_gchk>0) !== 1'b1) fails = fails + 1;
        $display("  [F-1] 拒写探针: A ovf=%0d/独立挡写=%0d | B %0d/%0d | C %0d/%0d | D %0d/%0d",
                 A_ovf,A_fblk,B_ovf,B_fblk,C_ovf,C_fblk,D_ovf,D_fblk);
        $display("  %0s: F1-1: DUT 拒写计数 == 门自己的挡写计数 (±2; 探针被拿掉/恒 0 会立刻 FAIL)",
                 ((A_ovf+2 >= A_fblk) && (A_fblk+2 >= A_ovf) && (C_ovf+2 >= C_fblk) && (C_fblk+2 >= C_ovf)) ? "ok" : "FAIL-DETAIL");
        if ((((A_ovf+2 >= A_fblk) && (A_fblk+2 >= A_ovf) && (C_ovf+2 >= C_fblk) && (C_fblk+2 >= C_ovf))) !== 1'b1) fails = fails + 1;
        $display("  %0s: F1-2: 探针有非零正证据 (真数到过被拒的写)", ((A_ovf > 0 || A_fblk == 0) && (C_ovf > 0 || C_fblk == 0)) ? "ok" : "FAIL-DETAIL");
        if (((A_ovf > 0 || A_fblk == 0) && (C_ovf > 0 || C_fblk == 0)) !== 1'b1) fails = fails + 1;
        $display("  %0s: 通用7: 收尾时 写-读 == 0 (排空后队列空)", ((A_wr-A_rd)==0 && (B_wr-B_rd)==0 && (C_wr-C_rd)==0 && (D_wr-D_rd)==0) ? "ok" : "FAIL-DETAIL");
            if (((A_wr-A_rd)==0 && (B_wr-B_rd)==0 && (C_wr-C_rd)==0 && (D_wr-D_rd)==0) !== 1'b1) fails = fails + 1;

        // ---- P6b 新增: 占用探针 (W27/W28 的来源) 对金标准断言 ----
        //   写域可见占用是**悲观**方向 ⇒ 它的历史最大必须 >= 金标准的真实最大占用。
        //   探针恒 0 / 未连接 / 算错方向都会在这里 FAIL (本工程"空读数 != 真 0"纪律)。
        //   ⚠️ 用**层次引用**读 (u_A.occ_w_max) 而不是加端口: 不动本文件的端口表。
        $display("  [P6b] 占用探针: A occ_w_max=%0d/occ_r_max=%0d (金标准 occ_max=%0d) | C occ_w_max=%0d/occ_r_max=%0d (金标准 occ_max=%0d)",
                 u_A.occ_w_max, u_A.occ_r_max, A_omax, u_C.occ_w_max, u_C.occ_r_max, C_omax);
        $display("  %0s: P6b-1: 写域占用探针峰值 >= 金标准真实峰值 (A/C)",
                 (u_A.occ_w_max >= A_omax && u_C.occ_w_max >= C_omax) ? "ok" : "FAIL-DETAIL");
            if ((u_A.occ_w_max >= A_omax && u_C.occ_w_max >= C_omax) !== 1'b1) fails = fails + 1;
        $display("  %0s: P6b-2: 探针非空 (真有占用过 ⇒ 探针不是恒 0 的未连接线)",
                 (u_A.occ_w_max > 0 && u_C.occ_w_max > 0) ? "ok" : "FAIL-DETAIL");
            if ((u_A.occ_w_max > 0 && u_C.occ_w_max > 0) !== 1'b1) fails = fails + 1;
        $display("  %0s: P6b-3: 探针硬界 (占用永不 > DEPTH; 独立计数, 不计入 o_err)",
                 (u_A.occ_bad_cnt == 0 && u_B.occ_bad_cnt == 0 && u_C.occ_bad_cnt == 0 && u_D.occ_bad_cnt == 0) ? "ok" : "FAIL-DETAIL");
            if ((u_A.occ_bad_cnt == 0 && u_B.occ_bad_cnt == 0 && u_C.occ_bad_cnt == 0 && u_D.occ_bad_cnt == 0) !== 1'b1) fails = fails + 1;

        $display("");
        if (fails == 0) $display("FIFO_ASYNC_GATE: PASS_ALL (case=%0s)",
                 c_wrfast?"WRFAST":c_rdfast?"RDFAST":c_bound?"BOUND":c_reset?"RESET":c_clkstop?"CLKSTOP":c_lat?"LAT":c_early?"EARLY":c_mir?"MIR":"BAL");
        else            $display("FIFO_ASYNC_GATE: FAIL (%0d 条判据不成立)", fails);
        $finish;
    end
endmodule
