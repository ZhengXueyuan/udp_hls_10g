//======================================================================
// p7b_lat_top.v -- P7b 分段延迟探针 (RX 通路) + VIO 读出
//======================================================================
//
// 目标问题
// --------
//   "一个以太网帧从 SFP 进来, 到整帧在 app 队列里准备好交给应用层, 耗时多少?"
//   本模块**不发一个数**, 它只做两件事:
//     ① 在 RX 通路上**逐段锁存时间戳** (每段一个读数);
//     ② 把同一帧的参数 (帧长 / 事件计数) 一起锁存, 让主机能判"这一对读数
//        真的属于同一帧"。
//
// 时间基 (两个自由计数器) —— **复用工程里已有的, 不新造**
// ----------------------------------------------------
//   fe_free : input, = wrapper 的 `gmii_free`   (FE 域, gmii_clk = rx_core_clk_1)
//   dp_free : input, = wrapper 的 `dp_free`     (DP 域, dp_clk)
//   两者都是 32 位自由计数, 每 27.49 s 绕一圈 (wrapper:3056/:3080 的口径注释)。
//   ⚠️ 绝不在本模块里再做一个计数器 —— 那会引入"两个计数器相位不同"的新未知。
//
// 时钟域
// ------
//   FE = gmii_clk = PCS 的 `rx_clk_out_1` (CDR **恢复**钟, 156.25MHz 标称)
//   DP = dp_clk   (Y1 100MHz 经 MMCM ×1.5625, 156.25MHz 标称)
//   ⚠️ 两者**物理无关** (P7a 实测 ~5ppm 差; ku5p_p7b_cdc.xdc:36-39 整组设
//      asynchronous)。⇒ **不能只用一个计数器跨域**。
//
// 跨域标定 (本模块的核心机制)
// --------------------------
//   后台跑一个**乒乓** (ping-pong), 每 2^CAL_DIV_BITS 个 dp_clk 一次:
//     DP 域翻 `cal_req_tgl` -> FE 域 2FF 收到后把**本域的 fe_free** 锁进
//     `cal_fe_r` 并把自己的 `calack_tgl` 跟上去 -> DP 域 2FF 收到后把
//     **本域的 dp_free** 锁进 `cal_dp_r`, `cal_evt++`。
//   ⇒ 一次标定给出**同一时刻**的一对数 (cal_fe, cal_dp)。
//   因整条链路是**固定级数**的触发器, `dp_free - fe_free` 在标定时刻是一个
//   常数 (相位抖动 ±1 拍), 主机侧用多组标定对做**离散度实测**而不是假设。
//
//   主机侧的换算式 (见 notes/P7B_LATENCY.md §2):
//     t_b 的绝对时刻 (以标定时刻为原点) = (fe_b - cal_fe) * T_fe
//     t_c 的绝对时刻                    = (dp_c - cal_dp) * T_dp
//     => Δ(b->c) = (dp_c - cal_dp) * T_dp - (fe_b - cal_fe) * T_fe
//   其中 T_fe / T_dp 用**实测频率** (P7a 的线速率 + P6b 的 156.2585MHz),
//   不用标称 156.25 —— 见报告; 本模块只负责给出原始计数。
//
// 快照协议 (与 P7a 的 VIO 同一套纪律)
// ----------------------------------
//   主机把 `probe_out0` 从 0 写到 1 (或 1 写到 0) => 本模块**边沿检测**后
//   发起一次原子快照:
//     ① DP 域把本域的量锁进 ro 寄存器;
//     ② DP 域翻 `cap_req_tgl` 向 FE 域要 FE 域的量;
//     ③ FE 域 2FF 收到后把 fe_a/fe_b/fe_len/evt_a/evt_b 锁进 capfe_* 并回翻
//        `capack_tgl`;
//     ④ DP 域 2FF 收到后把 capfe_* 搬进 ro, 并把 `snap_ack` 设成"看到的那
//        个 capack 值" => 主机**判 ack 变了**才知道这一代取数完成。
//   取数纪律 (本工程反复吃过真空零的亏): **没等到 ack 变化的读数一律作废**。
//
// 变异 (mutation) —— 直接作用在**观测链**上
// -----------------------------------------
//   `probe_out2` = mut_sel (0=无 / 1=fe_evt_b / 2=dp_evt_vs / 3=dp_evt_c /
//                            4=dp_evt_d / 5=fe_evt_a)
//   `probe_out3` = mut_n   (延迟拍数, 0 = 直通)
//   被选中的那一拍的**观测脉冲**被推迟 mut_n 拍 => 对应段落的读数必须**恰涨
//   mut_n**。⚠️ 它证明的是"锁存+换算链是忠实的拍计数", **不是**"数据面里真
//   有这么多拍" —— 后者由 物理下界 (线上串行化时间) 与 段间自洽 来证。
//   这一条必须在报告里如实这么写。
//
// VIO 打包 (必须与 scripts/probe_lat.tcl 的位图逐字一致)
// -----------------------------------------------------
//   字表 (每字 32 位, W<n>):
//     W0  fe_a    FE 计数器 @ XGMII 里出现 /S/ 的那个字
//     W1  fe_b    FE 计数器 @ MAC RX 输出 SOP 字被接收 (tvalid&&tready&&tuser)
//     W2  dp_vs   DP 计数器 @ vlan_strip 输出 SOP 被接收
//     W3  dp_c    DP 计数器 @ rx_classify **slow** 输出 SOP 被接收
//     W4  dp_d    DP 计数器 @ UDP app 帧缓冲**末字提交** (uf_commit_word)
//     W5  cal_fe  FE 计数器 @ 最近一次标定
//     W6  cal_dp  DP 计数器 @ 最近一次标定
//     W7  dp_cf   DP 计数器 @ rx_classify **fast** 输出 SOP 被接收
//     W8  {evt_a[15:0], evt_b[15:0]}     (高半字 = evt_a)
//     W9  {evt_c[15:0], evt_cf[15:0]}
//     W10 {evt_d[15:0], cal_evt[15:0]}
//     W11 {flags[15:0], fe_len[15:0]}    fe_len = mac_rx_10g.dbg_rx_last_len
//     W12 dp_d2   DP 计数器 @ app UDP RX 口 SOP 可见 (app_rx_tvalid&&app_rx_sof)
//     W13 {evt_vs[15:0], evt_d2[15:0]}
//     W14 {6'0, drp0_addr[9:0], 6'0, drp1_addr[9:0]}   GT DRP 回读地址
//     W15 {drp0_evt[15:0], drp0_do[15:0]}              通道0 事务数 / 数据
//     W16 {drp1_evt[15:0], drp1_do[15:0]}              通道1 事务数 / 数据
//     W17 {28'0, drp_to[1:0], drp_go_echo[1:0]}        DRP 超时标志 / go 回显
//     W18 dp_e    DP 计数器 @ 慢路径适配器入口 SOP (udp_split 透传口 srx_*)
//     W19 dp_e2   DP 计数器 @ 慢路径适配器入口 **TLAST** (= 整帧交付那一拍)
//     W20 {evt_e[15:0], evt_e2[15:0]}
//     W21 cal_fe_b  (b) 拍时刻的 FE 侧标定值  \
//     W22 cal_dp_c  (c) 拍时刻的 DP 侧标定值  / 跨域换算**必须**用这一对 (§3b)
//     W23 {cal_evt_fe_b[15:0], cal_evt_dp_c[15:0]}  两个锚点的标定序号
//
//  §3b 为什么跨域换算**不能**用快照时刻的标定对 (W5/W6):
//     两个计数器有 ~5ppm 的相对频差。若用"快照时刻"的标定对, 帧事件与标定
//     时刻相隔 ~0.1 s ⇒ 计数差 ~1.6e7 拍 ⇒ 即使用 P7a 实测到 6e-6 的频率,
//     换算误差 ≈ 1.6e7 × 6.4ns × 6e-6 ≈ **300 ns** —— 比要测的段还大。
//     ⇒ 必须锁"**帧时刻**"的标定对: FE 侧在 (b) 拍锁 `cal_fe_r`, DP 侧在 (c)
//       拍锁 `cal_dp_r`。两者相差 ≤1 个标定周期 (1.64us) ⇒ 放大因子 ≤256 拍
//       ⇒ 误差 ≈ 256 × 6.4ns × 6e-6 ≈ **1e-8 ns**, 可忽略。
//   VIO 输入探针 = 6 x 128 位 (lat_pi0..lat_pi5), 切成 24 个字 (W0 在最低)。
//   flags[0]=snap_ack  [1]=FE 已回过快照  [2]=快照在飞   [3]=lat_clr 电平
//         [4]=fe_rst_n  [5]=(mut_sel!=0) [6]=最近 /S/ 在 lane0 [7]=在 lane4
//   probe_out0 = snap_req (电平, 边沿检测)
//   probe_out1 = lat_clr  (电平, 边沿检测) —— 清全部锁存与事件计数
//   probe_out2 [3:0]  = mut_sel
//   probe_out3 [7:0]  = mut_n
//   probe_out4 [15:0] = drp_req_addr  (GT DRP 读地址; 只用低 10 位)
//   probe_out5 [1:0]  = drp_req_go    (每通道一个电平; 边沿检测 = 发一次读)
//   ⚠️ DRP 的跨域纪律 (见 p7b_lat_drp.v 头): **先写地址, 停 >= 1ms, 再翻 go**。
//
// 传入的信号都在 wrapper 的 `ifdef P7B_LAT` 块里接 (见那里的逐条出处)。
//======================================================================

`timescale 1ns / 1ps

module p7b_lat_top #(
    parameter integer CAL_DIV_BITS = 8      // 标定周期 = 2^CAL_DIV_BITS 个 dp_clk (256 => 1.64us)
)(
    // ---- FE 域 (gmii_clk = PCS 的 rx_clk_out_1, CDR 恢复钟) ----
    input  wire        fe_clk,
    input  wire        fe_rst_n,
    input  wire [31:0] fe_free,
    input  wire        fe_evt_a,        // XGMII 里出现 /S/ 的那个字 (PCS 边界)
    input  wire        fe_evt_b,        // MAC RX 输出 SOP 字被接收
    input  wire [3:0]  fe_lane_a,       // /S/ 落在哪个 lane (0 或 4 是合法的)
    input  wire [15:0] fe_len,          // mac_rx_10g.dbg_rx_last_len (线上长度, 含 FCS)
    // ---- DP 域 (dp_clk) ----
    input  wire        dp_clk,
    input  wire        dp_rst_n,
    input  wire [31:0] dp_free,
    input  wire        dp_evt_vs,       // vlan_strip SOP 被接收
    input  wire        dp_evt_c,        // rx_classify slow SOP 被接收
    input  wire        dp_evt_cf,       // rx_classify fast SOP 被接收
    input  wire        dp_evt_d,        // UDP app 帧缓冲末字提交 (uf_commit_word)
    input  wire        dp_evt_d2,       // app UDP RX 口 SOP 可见
    input  wire        dp_evt_e,        // 慢路径适配器入口 SOP (udp_split 透传口)
    input  wire        dp_evt_e2,       // 慢路径适配器入口 TLAST (整帧交付)
    // ---- GT DRP 结果 (dclk 域发布, 本模块在 dp 域采; 见 p7b_lat_drp.v 头) ----
    input  wire        drp0_tgl,
    input  wire [15:0] drp0_do,
    input  wire [15:0] drp0_addr,
    input  wire        drp0_to,
    input  wire [15:0] drp0_evt,
    input  wire        drp1_tgl,
    input  wire [15:0] drp1_do,
    input  wire [15:0] drp1_addr,
    input  wire        drp1_to,
    input  wire [15:0] drp1_evt,
    // ---- 去 DRP 控制器的请求 (dp 域, 由 VIO 驱动; 见 p7b_lat_drp.v 的纪律) ----
    output wire [15:0] drp_req_addr,
    output wire [1:0]  drp_req_go
);

    // VIO 出来的控制 (在 dp_clk 域里由 VIO 核驱动)
    wire [3:0]  mut_sel;
    wire [7:0]  mut_n;
    wire        snap_req;
    wire        lat_clr;
    // ⚠️ 这两个是**输出端口**, VIO 直接驱动它们 (声明在端口表里, 不要在这里再 wire)
    //    (xvlog 先声明后用: 若在这里隐式重建同名线 ⇒ 位宽 1 的隐式网 + 静默截断)

    // ---- lat_clr: DP -> FE 的清位请求 (必须先声明, §1/§2 的锁存块要用它) ----
    (* ASYNC_REG = "TRUE" *) reg [2:0] clrreq_sr;
    reg  clr_go_r;
    wire clr_go_dp    = lat_clr ^ clr_go_r;                  // DP 侧: 电平跳变那一拍
    wire clr_pulse_dp = clr_go_dp;
    wire clr_pulse_fe = clrreq_sr[2] ^ clrreq_sr[1];         // FE 侧: 2 拍内的一个脉冲

    // ---- §3 标定乒乓的**全部**寄存器 (必须先声明: §1 的 FE 锁存块要用 cal_fe_r,
    //      §2 的 DP 锁存块要用 cal_dp_r/cal_evt) --------------------------------
    reg  [CAL_DIV_BITS-1:0] cal_div;
    reg                     cal_req_tgl;    // DP -> FE
    reg  [31:0]             cal_dp_r;
    reg  [15:0]             cal_evt;
    (* ASYNC_REG = "TRUE" *) reg [2:0] calack_sr;   // FE -> DP
    reg                     calack_seen;
    reg  [31:0]             cal_fe_r;
    reg                     calack_tgl;     // FE -> DP
    reg  [15:0]             cal_evt_fe;
    (* ASYNC_REG = "TRUE" *) reg [2:0] calreq_sr;

    // =================================================================
    // 0. 变异: 观测脉冲的可编程延迟 (只在**观测链**上, 不碰数据面)
    // =================================================================
    // 只有 mut_n != 0 且 mut_sel 命中时, 该拍的观测脉冲才被推迟;
    // 其余一律**逐位直通** (mut_n=0 = 零新增延迟, 未选中 = 零新增延迟)。
    wire fe_sel_a = (mut_sel == 4'd5) && (mut_n != 8'd0);
    wire fe_sel_b = (mut_sel == 4'd1) && (mut_n != 8'd0);
    wire dp_sel_vs = (mut_sel == 4'd2) && (mut_n != 8'd0);
    wire dp_sel_c  = (mut_sel == 4'd3) && (mut_n != 8'd0);
    wire dp_sel_d  = (mut_sel == 4'd4) && (mut_n != 8'd0);
    // 同一时刻只有一个 tap 被选中 (单帧激励, 帧间隔 >= 20ms >> 255 拍 = 1.6us)
    wire fe_src_pulse = fe_sel_a ? fe_evt_a : (fe_sel_b ? fe_evt_b : 1'b0);
    wire dp_src_pulse = dp_sel_vs ? dp_evt_vs : (dp_sel_c ? dp_evt_c :
                        (dp_sel_d ? dp_evt_d : 1'b0));

    reg  [7:0] fe_dly_cnt;  reg fe_dly_armed;
    reg  [7:0] dp_dly_cnt;  reg dp_dly_armed;
    wire fe_dly_out = fe_dly_armed && (fe_dly_cnt == 8'd0);
    wire dp_dly_out = dp_dly_armed && (dp_dly_cnt == 8'd0);

    wire fe_evt_a_d = fe_sel_a ? fe_dly_out : fe_evt_a;
    wire fe_evt_b_d = fe_sel_b ? fe_dly_out : fe_evt_b;
    wire dp_evt_vs_d = dp_sel_vs ? dp_dly_out : dp_evt_vs;
    wire dp_evt_c_d  = dp_sel_c  ? dp_dly_out : dp_evt_c;
    wire dp_evt_d_d  = dp_sel_d  ? dp_dly_out : dp_evt_d;

    // =================================================================
    // 1. FE 域: 事件锁存 + 事件计数 (清位与 DP 侧同一代, 见 §6)
    // =================================================================
    reg [31:0] fe_a_r, fe_b_r;
    reg [31:0] cal_fe_b_r;              // (b) 拍上的 FE 侧标定值 (见 §3b)
    reg [15:0] evt_a, evt_b;
    reg [15:0] cal_evt_fe_b;
    reg [1:0]  lane_flags;

    always @(posedge fe_clk or negedge fe_rst_n) begin
        if (!fe_rst_n) begin
            fe_a_r <= 32'd0; fe_b_r <= 32'd0;
            evt_a  <= 16'd0; evt_b  <= 16'd0;
            lane_flags <= 2'b00;
        end else if (clr_pulse_fe) begin
            fe_a_r <= 32'd0; fe_b_r <= 32'd0;
            evt_a  <= 16'd0; evt_b  <= 16'd0;
            lane_flags <= 2'b00;
        end else begin
            if (fe_evt_a_d) begin
                fe_a_r     <= fe_free;          // 锁的就是**本拍**的计数值
                evt_a      <= evt_a + 16'd1;
                lane_flags <= { (fe_lane_a == 4'd4), (fe_lane_a == 4'd0) };
            end
            if (fe_evt_b_d) begin
                fe_b_r          <= fe_free;
                cal_fe_b_r      <= cal_fe_r;    // 帧时刻的标定锚点 (见 §3b)
                cal_evt_fe_b    <= cal_evt_fe;
                evt_b           <= evt_b + 16'd1;
            end
        end
    end

    always @(posedge fe_clk or negedge fe_rst_n) begin
        if (!fe_rst_n) begin
            fe_dly_cnt <= 8'd0; fe_dly_armed <= 1'b0;
        end else if (clr_pulse_fe) begin
            fe_dly_cnt <= 8'd0; fe_dly_armed <= 1'b0;
        end else begin
            if (fe_dly_armed) begin
                if (fe_dly_cnt == 8'd0) fe_dly_armed <= 1'b0;
                else                    fe_dly_cnt   <= fe_dly_cnt - 8'd1;
            end
            if (fe_src_pulse) begin
                fe_dly_cnt   <= mut_n - 8'd1;   // mut_n != 0 (由 sel 保证)
                fe_dly_armed <= 1'b1;
            end
        end
    end

    // =================================================================
    // 2. DP 域: 事件锁存 + 事件计数
    // =================================================================
    reg [31:0] dp_vs_r, dp_c_r, dp_cf_r, dp_d_r, dp_d2_r, dp_e_r, dp_e2_r;
    reg [31:0] cal_dp_c_r;              // (c) 拍上的 DP 侧标定值 (§3b)
    reg [15:0] evt_vs, evt_c, evt_cf, evt_d, evt_d2, evt_e, evt_e2;
    reg [15:0] cal_evt_dp_c;

    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            dp_vs_r <= 32'd0; dp_c_r <= 32'd0; dp_cf_r <= 32'd0;
            dp_d_r  <= 32'd0; dp_d2_r <= 32'd0; dp_e_r <= 32'd0; dp_e2_r <= 32'd0;
            cal_dp_c_r <= 32'd0; cal_evt_dp_c <= 16'd0;
            evt_vs  <= 16'd0; evt_c <= 16'd0; evt_cf <= 16'd0;
            evt_d   <= 16'd0; evt_d2 <= 16'd0; evt_e <= 16'd0; evt_e2 <= 16'd0;
        end else if (clr_pulse_dp) begin
            dp_vs_r <= 32'd0; dp_c_r <= 32'd0; dp_cf_r <= 32'd0;
            dp_d_r  <= 32'd0; dp_d2_r <= 32'd0; dp_e_r <= 32'd0; dp_e2_r <= 32'd0;
            cal_dp_c_r <= 32'd0; cal_evt_dp_c <= 16'd0;
            evt_vs  <= 16'd0; evt_c <= 16'd0; evt_cf <= 16'd0;
            evt_d   <= 16'd0; evt_d2 <= 16'd0; evt_e <= 16'd0; evt_e2 <= 16'd0;
        end else begin
            if (dp_evt_vs_d) begin dp_vs_r <= dp_free; evt_vs <= evt_vs + 16'd1; end
            if (dp_evt_c_d)  begin dp_c_r    <= dp_free;
                                   cal_dp_c_r  <= cal_dp_r;     // §3b 帧时刻锚点
                                   cal_evt_dp_c<= cal_evt;
                                   evt_c       <= evt_c + 16'd1; end
            if (dp_evt_cf)   begin dp_cf_r <= dp_free; evt_cf <= evt_cf + 16'd1; end
            // §3b: (c) 拍上的 DP 侧标定锚点 —— 与 (b) 拍锁的 cal_fe_b_r 配成
            //      "帧时刻的同一对 (FE,DP) 标定", 这是跨域段唯一正确的做法
            //      (用快照时刻的标定会差出 0.1s × 5ppm ≈ 300ns, 见报告 §2.3)
            if (dp_evt_d_d)  begin dp_d_r  <= dp_free; evt_d  <= evt_d  + 16'd1; end
            if (dp_evt_d2)   begin dp_d2_r <= dp_free; evt_d2 <= evt_d2 + 16'd1; end
            if (dp_evt_e)    begin dp_e_r  <= dp_free; evt_e  <= evt_e  + 16'd1; end
            if (dp_evt_e2)   begin dp_e2_r <= dp_free; evt_e2 <= evt_e2 + 16'd1; end
        end
    end

    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            dp_dly_cnt <= 8'd0; dp_dly_armed <= 1'b0;
        end else if (clr_pulse_dp) begin
            dp_dly_cnt <= 8'd0; dp_dly_armed <= 1'b0;
        end else begin
            if (dp_dly_armed) begin
                if (dp_dly_cnt == 8'd0) dp_dly_armed <= 1'b0;
                else                    dp_dly_cnt   <= dp_dly_cnt - 8'd1;
            end
            if (dp_src_pulse) begin
                dp_dly_cnt   <= mut_n - 8'd1;
                dp_dly_armed <= 1'b1;
            end
        end
    end

    // =================================================================
    // 3. 后台跨域标定乒乓 (DP -> FE -> DP)
    // =================================================================
    // (§3 的全部寄存器声明已上移到 §1 之前 —— FE/DP 的锁存块都要读它们)

    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            cal_div <= {CAL_DIV_BITS{1'b0}};
            cal_req_tgl <= 1'b0;
            cal_dp_r <= 32'd0; cal_evt <= 16'd0;
            calack_sr <= 3'b000; calack_seen <= 1'b0;
        end else begin
            // 周期性翻请求 (被漏掉也无害: 偏移是常数, 只要成功过就够)
            if (cal_div == {CAL_DIV_BITS{1'b0}}) cal_req_tgl <= ~cal_req_tgl;
            cal_div <= cal_div + 1'b1;
            // 收 ack: 看到新值就锁本域计数器
            calack_sr <= {calack_sr[1:0], calack_tgl};
            if (calack_sr[2] ^ calack_seen) begin
                calack_seen <= calack_sr[2];
                cal_dp_r    <= dp_free;
                cal_evt     <= cal_evt + 16'd1;
            end
        end
    end

    // (cal_fe_r / calack_tgl / calreq_sr 的**声明**已上移到本节第一个
    //  always 之前 —— FE 的同步器要先于读它的那个 always 声明)

    always @(posedge fe_clk or negedge fe_rst_n) begin
        if (!fe_rst_n) begin
            calreq_sr   <= 3'b000;
            cal_fe_r    <= 32'd0;
            calack_tgl  <= 1'b0;
            cal_evt_fe  <= 16'd0;
        end else begin
            calreq_sr <= {calreq_sr[1:0], cal_req_tgl};
            if (calreq_sr[2] ^ calack_tgl) begin
                cal_fe_r   <= fe_free;
                calack_tgl <= calreq_sr[2];
                cal_evt_fe <= cal_evt_fe + 16'd1;
            end
        end
    end

    // =================================================================
    // 4. lat_clr: DP -> FE 的清位请求 (同一代清两个域)
    //    ⚠️ 线/寄存器的**声明**在 §0 上方 (§1/§2 的锁存块要用 clr_pulse_*)
    // =================================================================
    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            clr_go_r   <= 1'b0;
            clrreq_sr  <= 3'b000;
        end else begin
            clr_go_r   <= lat_clr;
            clrreq_sr  <= {clrreq_sr[1:0], lat_clr};   // 电平本身就是握手, 直接送过去
        end
    end
    assign clr_pulse_dp = clr_go_dp;

    // =================================================================
    // 5. 原子快照 (DP 发起, FE 应答)
    // =================================================================
    (* ASYNC_REG = "TRUE" *) reg [2:0] snapreq_sr;
    reg snap_req_r;
    wire snap_go = snapreq_sr[2] ^ snap_req_r;

    reg                     cap_req_tgl;    // DP -> FE
    reg                     snap_busy;
    reg  [31:0] ro_fe_a, ro_fe_b, ro_cal_fe;
    reg  [15:0] ro_fe_len, ro_evt_a, ro_evt_b;
    reg  [1:0]  ro_laneflags;
    reg  [31:0] ro_calfeb;              // W21: (b) 拍上的 FE 标定锚点
    reg  [31:0] ro_caldpc;              // W22: (c) 拍上的 DP 标定锚点
    reg  [15:0] ro_evtfeb, ro_evtdpc;   // W23: 两个锚点的标定序号
    reg         snap_ack;
    reg         fe_cap_seen;

    // FE 侧的回执寄存器
    reg  [31:0] capfe_a, capfe_b, capfe_calfe;
    reg  [15:0] capfe_len, capfe_evta, capfe_evtb;
    reg  [31:0] capfe_calfeb;
    reg  [15:0] capfe_evtfeb;
    reg  [1:0]  capfe_lane;
    reg         capack_tgl;                 // FE -> DP
    (* ASYNC_REG = "TRUE" *) reg [2:0] capreq_sr_f;

    always @(posedge fe_clk or negedge fe_rst_n) begin
        if (!fe_rst_n) begin
            capreq_sr_f <= 3'b000;
            capfe_a <= 32'd0; capfe_b <= 32'd0; capfe_calfe <= 32'd0;
            capfe_len <= 16'd0; capfe_evta <= 16'd0; capfe_evtb <= 16'd0;
            capfe_calfeb <= 32'd0; capfe_evtfeb <= 16'd0;
            capfe_lane <= 2'b00;
            capack_tgl <= 1'b0;
        end else begin
            capreq_sr_f <= {capreq_sr_f[1:0], cap_req_tgl};
            if (capreq_sr_f[2] ^ capack_tgl) begin
                capfe_a     <= fe_a_r;
                capfe_b     <= fe_b_r;
                capfe_calfe <= cal_fe_r;
                capfe_len   <= fe_len;
                capfe_evta  <= evt_a;
                capfe_evtb  <= evt_b;
                capfe_calfeb<= cal_fe_b_r;
                capfe_evtfeb<= cal_evt_fe_b;
                capfe_lane  <= lane_flags;
                capack_tgl  <= capreq_sr_f[2];
            end
        end
    end

    (* ASYNC_REG = "TRUE" *) reg [2:0] capack_sr;

    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            snapreq_sr  <= 3'b000;
            snap_req_r  <= 1'b0;
            cap_req_tgl <= 1'b0;
            snap_busy   <= 1'b0;
            capack_sr   <= 3'b000;
            snap_ack    <= 1'b0;
            fe_cap_seen <= 1'b0;
            ro_fe_a <= 32'd0; ro_fe_b <= 32'd0; ro_cal_fe <= 32'd0;
            ro_fe_len <= 16'd0; ro_evt_a <= 16'd0; ro_evt_b <= 16'd0;
            ro_laneflags <= 2'b00;
            ro_calfeb <= 32'd0; ro_caldpc <= 32'd0;
            ro_evtfeb <= 16'd0; ro_evtdpc <= 16'd0;
        end else begin
            snapreq_sr <= {snapreq_sr[1:0], snap_req};
            snap_req_r <= snapreq_sr[2];
            capack_sr  <= {capack_sr[1:0], capack_tgl};

            if (snap_go) begin
                cap_req_tgl <= ~cap_req_tgl;    // 向 FE 要一份
                snap_busy   <= 1'b1;
                fe_cap_seen <= 1'b0;
            end
            if (capack_sr[2] ^ snap_ack) begin
                // FE 侧的值此刻已稳 (capfe_* 与 capack_tgl 在 FE 同一拍一起写)
                ro_fe_a     <= capfe_a;
                ro_fe_b     <= capfe_b;
                ro_cal_fe   <= capfe_calfe;
                ro_fe_len   <= capfe_len;
                ro_evt_a    <= capfe_evta;
                ro_evt_b    <= capfe_evtb;
                ro_laneflags<= capfe_lane;
                ro_calfeb   <= capfe_calfeb;
                ro_evtfeb   <= capfe_evtfeb;
                ro_caldpc   <= cal_dp_c_r;
                ro_evtdpc   <= cal_evt_dp_c;
                snap_ack    <= capack_sr[2];
                snap_busy   <= 1'b0;
                fe_cap_seen <= 1'b1;
            end
        end
    end

    // =================================================================
    // 5b. GT DRP 结果的跨域采集 (dclk -> dp, "toggle + 稳定数据")
    // =================================================================
    // p7b_lat_drp.v 在 dclk 域完成一次读事务后, 把 (out_do,out_addr,out_to)
    // 与 out_tgl **同拍发布**, 且在下次请求之前不再改 ⇒ 本域只要"2FF 看到 tgl
    // 变了再采数据"就是安全的 (数据在该时刻已稳 >= 2 个 dclk 拍)。
    (* ASYNC_REG = "TRUE" *) reg [2:0] drp0_sr, drp1_sr;
    reg [15:0] ro_drp0_do, ro_drp0_addr, ro_drp0_evt;
    reg [15:0] ro_drp1_do, ro_drp1_addr, ro_drp1_evt;
    reg [1:0]  ro_drp_to;

    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            drp0_sr <= 3'b000; drp1_sr <= 3'b000;
            ro_drp0_do <= 16'd0; ro_drp0_addr <= 16'd0; ro_drp0_evt <= 16'd0;
            ro_drp1_do <= 16'd0; ro_drp1_addr <= 16'd0; ro_drp1_evt <= 16'd0;
            ro_drp_to  <= 2'b00;
        end else begin
            drp0_sr <= {drp0_sr[1:0], drp0_tgl};
            drp1_sr <= {drp1_sr[1:0], drp1_tgl};
            if (drp0_sr[2] ^ drp0_sr[1]) begin
                ro_drp0_do   <= drp0_do;
                ro_drp0_addr <= drp0_addr;
                ro_drp0_evt  <= drp0_evt;
                ro_drp_to[0] <= drp0_to;
            end
            if (drp1_sr[2] ^ drp1_sr[1]) begin
                ro_drp1_do   <= drp1_do;
                ro_drp1_addr <= drp1_addr;
                ro_drp1_evt  <= drp1_evt;
                ro_drp_to[1] <= drp1_to;
            end
        end
    end

    // =================================================================
    // 6. 读出装配 (24 字 x 32 = 768 位 = 6 个 VIO 输入探针 x 128)
    //    ⚠️ 每个探针接一根**具名 wire** (lat_pi0..5), 不接表达式 —— VIO 的探针
    //       名取自被连的**网名**, 接表达式会让探针名变成工具自动生成的名字,
    //       主机脚本就只能靠猜 (位宽全是 128, 猜不出来)。
    // =================================================================
    wire [15:0] flags = { 8'd0,                                   // [15:8]
                          ro_laneflags[1],                        // [7] lane4
                          ro_laneflags[0],                        // [6] lane0
                          (mut_sel != 4'd0),                      // [5]
                          fe_rst_n,                               // [4]
                          lat_clr,                                // [3]
                          snap_busy,                              // [2]
                          fe_cap_seen,                            // [1]
                          snap_ack };                             // [0]

    wire [767:0] flat = {
        { {ro_evtfeb, ro_evtdpc}, ro_caldpc, ro_calfeb,
          {evt_e,  evt_e2} },                               // W23 W22 W21 | W20
        { dp_e2_r, dp_e_r,
          {28'd0, ro_drp_to, drp_req_go},
          {ro_drp1_evt, ro_drp1_do} },                      // W19 W18 W17 | W16
        { {ro_drp0_evt, ro_drp0_do},
          {6'd0, ro_drp0_addr[9:0], 6'd0, ro_drp1_addr[9:0]},
          {evt_vs, evt_d2}, dp_d2_r },                      // W15 W14 W13 | W12
        { {flags, ro_fe_len}, {evt_d, cal_evt},
          {evt_c, evt_cf}, {ro_evt_a, ro_evt_b} },          // W11 W10 W9  | W8
        { dp_cf_r, cal_dp_r, ro_cal_fe, dp_d_r },           // W7  W6  W5  | W4
        { dp_c_r, dp_vs_r, ro_fe_b, ro_fe_a }               // W3  W2  W1  | W0
    };

    wire [127:0] lat_pi0 = flat[127:0];
    wire [127:0] lat_pi1 = flat[255:128];
    wire [127:0] lat_pi2 = flat[383:256];
    wire [127:0] lat_pi3 = flat[511:384];
    wire [127:0] lat_pi4 = flat[639:512];
    wire [127:0] lat_pi5 = flat[767:640];

    // =================================================================
    // 7. VIO (读出窗口)
    // =================================================================
    vio_lat u_vio (
        .clk        (dp_clk),
        .probe_in0  (lat_pi0),
        .probe_in1  (lat_pi1),
        .probe_in2  (lat_pi2),
        .probe_in3  (lat_pi3),
        .probe_in4  (lat_pi4),
        .probe_in5  (lat_pi5),
        .probe_out0 (snap_req),
        .probe_out1 (lat_clr),
        .probe_out2 (mut_sel),
        .probe_out3 (mut_n),
        .probe_out4 (drp_req_addr),
        .probe_out5 (drp_req_go)
    );

endmodule
