//======================================================================
// clk_gen_p6b.v -- P6b data-plane clock generator (reference -> 156.25 MHz)
//======================================================================
//
// 目的
// ----
// P6b 把数据面从 PHY 回送的 125 MHz `i_rxc` 搬到一个独立的 156.25 MHz 自由运行
// 时钟域 (10G 前置步骤)。本模块是那个时钟域的**唯一发生器**。
//
// 拓扑
// ----
//   clk_p/clk_n --IBUFDS--> BUFG(u_in) --> clk_in_100   (参考钟, 给别处用)
//                                \----> MMCME4_BASE.CLKIN1
//   MMCME4_BASE.CLKOUT0 -------------------> BUFG(u_out) --> clk_dp
//   MMCME4_BASE.LOCKED --------------------> locked  (只作观测/复位释放门, 见下)
//
// 频率 (默认配置, 输入 = 板上 Y1 = SG7050VAN-100.000000M ⇒ 100 MHz)
// -----------------------------------------------------------------
//   F_PFD = 100 MHz / DIVCLK_DIVIDE(1)                       =  100.000 MHz
//   F_VCO = F_PFD * CLKFBOUT_MULT_F(12.500)                  = 1250.000 MHz
//   F_OUT = F_VCO / CLKOUT0_DIVIDE_F(8.000)                  =  156.250 MHz
//
// 次选参数组 (实测均已 place 通过, 见 board/ku5p_probe/clkgen_p6b/):
//   次选 A: M=25.000, D=2, O=8.000  -> VCO = 1250.0 MHz, PFD = 50 MHz  (PFD 降到 50)
//   次选 B: M= 9.375, D=1, O=6.000  -> VCO =  937.5 MHz, PFD =100 MHz  (换一个 VCO,
//           万一 1250 MHz 在板上因电源/温升不理想可退到这里)
//
// 备用输入 (若 T25/U25 路线不成立, 或想直接锁 RGMII 的 i_rxc):
//   输入 125 MHz (i_rxc): CLKIN1_PERIOD_NS=8.000, CLKFBOUT_MULT_F=10.000,
//   DIVCLK_DIVIDE=1, CLKOUT0_DIVIDE_F=8.000
//     F_VCO = 125 * 10.000 / 1 = 1250.000 MHz, F_OUT = 1250/8 = 156.250 MHz
//   ⇒ **两条路线的 VCO 完全相同 (1250 MHz)**, 只差 CLKIN1_PERIOD_NS 与 MULT_F。
//   ⚠️ i_rxc 路线在 i_rxc 消失 (链路 down) 时 MMCM 会失锁 ⇒ rst_dp 自动断言,
//      数据面停摆; 这是**有意的**权衡, 但 T25/U25 自由运行路线没有这个耦合。
//
// 器件合法性 (不是凭记忆, 证据见 board/ku5p_probe/clkgen_p6b/README.md)
// --------------------------------------------------------------------
// * xcku5p-ffvb676-1-e, T25/U25 = IO_L14P/N_T2L_N2/N3_GC_A04/A05_D20/D21_65
//   器件模型属性: IS_GLOBAL_CLK=1, BANK=65 (BT_HIGH_PERFORMANCE),
//   CLOCK_REGION=X0Y1; MMCM_X0Y1 就在同一 CLOCK_REGION ⇒ 同 CMT 可达。
//   (实测: 把 clk_p/clk_n 挪到 bank65 的非 GC 脚 N24/P24 ⇒ place_design 报
//    `PLCK-58 Error` 失败, 证明这条规则是被工具强制的。)
// * MMCM 合法区间 (两处独立工具证据一致):
//   (a) ds922 (Kintex UltraScale+) **Table 38 MMCM Specification**,
//       -1 速度等级列: FVCOMIN=800 / FVCOMAX=1600 MHz,
//       FPFDMAX=550 / FPFDMIN=10 MHz, FINMAX=800 MHz, FOUTMAX=891 MHz。
//   (b) 本机时钟向导 (clk_wiz v6.0) 对 xcku5p-ffvb676-1-e 生成的 .xci:
//       C_VCO_MIN=800.000, C_VCO_MAX=1600.000, C_M_MIN/MAX=2.000/128.000,
//       C_D_MIN/MAX=1.000/80.000, C_O_MIN/MAX=1.000/128.000  (resolve_type=generated)
//   ⇒ 本模块: VCO=1250 ∈ [800,1600] ✓; PFD=100 ∈ [10,550] ✓;
//             CLKIN1=100 ≤ 800 ✓; CLKOUT0=156.25 ∈ [6.25,891] ✓;
//             M=12.500 ∈ [2,128] ✓; D=1 ∈ [1,80] ✓; O=8.000 ∈ [1,128] ✓
//   ⚠️ 但 **Vivado 的 implementation DRC 不检查 VCO / PFD 区间** ——
//      实测把 M 设成 1.000 (VCO=100 MHz) 或 64.000/O=2.000 (VCO=6400 MHz)
//      仍能一路 place 通过。所以"能过 DRC"**不能**当合法性证据。
// * IOSTANDARD = **`DIFF_SSTL12`**, 不是厂商 Demo 的 `DIFF_POD12_DCI` —— 这里有坑:
//   - bank 65 的 VCCO = **1.2 V** (同 bank 的 DDR4 用 POD12_DCI; 原理图 VCCO_65 -> VDD1.2)。
//   - Y1 = SG7050VAN-100.000000M (**LVDS 输出**, VDD3.3 供电), 输出经
//     0.1 uF 交流耦合 (C118/C119) 后用 **1k/1k 分压到 VDD1.2** (R52/R54, R53/R55)
//     ⇒ FPGA 侧共模 = **0.600 V = VCCO/2**; 另有 100 Ω 差分端接 R58。
//   - ds922 **Table 14** (HP banks, 互补差分): `DIFF_SSTL12` VICM = VCCO/2 ± 0.150
//     = **0.450 / 0.600 / 0.750 V**, VID(min) = 0.100 V ⇒ 我们的 0.600 V / ~0.35 V **正好是 typ**。
//   - ds922 **Table 15**: `DIFF_POD12` VICM = **0.76 / 0.84 / 0.92 V** ⇒ 0.600 V
//     **低于下限**, 厂商 Demo 的 `DIFF_POD12_DCI` 对本时钟输入**电气上是错的**。
//   - `LVDS`: ds922 Table 19 的 AC 耦合 VICM 范围是 **0.600 – 1.100 V** ⇒ 0.600 V 恰好压在
//     **下限** (零裕量, 且要求不使能内部端接)。能用, 但不如 `DIFF_SSTL12` 居中。
//   - `DIFF_POD12_DCI` 另有代价: DRC 报 2 条 `DCIRST-1` (DCI 标准必须配 `DCIRESET`
//     原语, AR#000038677)。我们只用输入, 板上也已有外部 100 Ω, **不需要 DCI**。
//   ⚠️ 这一条**工具不会替你判**: 上面 4 个标准 Vivado 全部接受 (0 Error) ——
//      只有原理图 (VCCO=1.2 V + 0.6 V 偏置) 与 ds922 的表能定案。
// * MMCME4_BASE vs ADV: 本模块只用一路 CLKOUT0、不动 DRP ⇒ 用 BASE
//   (ADV 会多出 DADDR/DCLK/DEN/DI/DO/DRDY/DWE/PSDONE 等 DRP 端口, 全不用)。
//
// locked 的语义 —— 为什么不能直接当复位
// --------------------------------------
// MMCM 的 LOCKED 是**电平**, 它会在下列情况**瞬时掉低**: 输入钟抖动/瞬断、
// 输入频率漂移出捕获范围、PWRDWN/RST、器件温度/电压越界引发重锁。
// 若直接 `rst_dp = ~locked`:
//   (a) 复位**释放**变成异步事件 —— 下游 flop 的复位撤销沿相对 clk_dp 随机,
//       直接违反 recovery/removal, 亚稳态会扩散到整个数据面;
//   (b) LOCKED 的毛刺会变成复位毛刺, 把正在飞的事务撕成半截。
// 正确做法 (本模块实现的方案):
//   **异步置位 / 同步释放的复位同步器** (Xilinx 标准写法):
//       rst_async = (~locked) | rst_ext            // 置位: 立即, 与 clk_dp 无关
//       rel_sr    <= 0           当 rst_async       // 异步清
//       rel_sr    <= {rel_sr[2:0],1'b1} 否则       // 每拍 clk_dp 移入一个 1
//       rst_dp    = ~rel_sr[3]
//   即: locked **参与复位释放** (必须连续 4 个 clk_dp 沿都看到 `rst_async==0`
//   才放行), **不单独参与复位产生** (还有 rst_ext 这个确定性的置位源)。
//   置位是异步的 (所以 locked 掉了立刻停摆), 释放是同步的 (所以下游安全)。
//   `locked` 端口本身原样引出, **只作观测 (VIO/LED)**, 请勿拿它当复位用。
//
// 仿真
// ----
// SIM_BYPASS=1 时用行为级模型代替 IBUFDS/BUFG/MMCME4_BASE: 输出周期直接由
// CLKFBOUT_MULT_F / DIVCLK_DIVIDE / CLKOUT0_DIVIDE_F 算出
//   T_dp = CLKIN1_PERIOD * DIVCLK_DIVIDE * CLKOUT0_DIVIDE_F / CLKFBOUT_MULT_F
// ⇒ **改错 MULT_F 就真的会跑错频率** (TB 的负对照靠这个), 且不需要等 MMCM 锁定。
// SIM_BYPASS=0 (默认) 例化真原语, 走 UNISIM 模型。
//======================================================================

`timescale 1ns / 1ps

module clk_gen_p6b #(
    // 1 = 行为级时钟模型 (快速仿真, 支持错参数负对照); 0 = 真 IBUFDS/BUFG/MMCME4_BASE
    parameter integer SIM_BYPASS       = 0,
    // 参考钟周期 (ns)。默认 10.000 = 100 MHz (板上 Y1);
    // 备用 8.000 = 125 MHz (RGMII 的 i_rxc)
    parameter         CLKIN1_PERIOD_NS = 10.000,
    // MMCM 倍频/分频 (见头注释的频率表)
    parameter         CLKFBOUT_MULT_F  = 12.500,   // 备用 10.000
    parameter integer DIVCLK_DIVIDE    = 1,
    parameter         CLKOUT0_DIVIDE_F = 8.000,
    parameter         REF_JITTER1      = 0.010
)(
    input  wire clk_p,        // 差分参考钟 (板上 Y1 = SYS_CLK_P, T25)
    input  wire clk_n,        // 差分参考钟 (板上 Y1 = SYS_CLK_N, U25)
    input  wire rst_ext,      // 外部复位, 高有效, 异步置位 (上电复位/软复位)
    output wire clk_dp,       // 156.25 MHz 数据面时钟
    output wire clk_in_100,   // 参考钟缓冲输出 (默认配置下 = 100 MHz)
    output wire locked,       // MMCM LOCKED 原样引出 —— 只观测, 别当复位
    output wire rst_dp        // clk_dp 域复位: 异步置位 / 同步释放
);

    //------------------------------------------------------------------
    // 派生常量 (供头注释与 TB 交叉核对; 综合期即为常数)
    //------------------------------------------------------------------
    localparam real    F_VCO_MHZ = (1000.0 / CLKIN1_PERIOD_NS) * CLKFBOUT_MULT_F / DIVCLK_DIVIDE;
    localparam real    F_OUT_MHZ = F_VCO_MHZ / CLKOUT0_DIVIDE_F;

    // 行为级模型用的整数 ps 运算 (避免 real 除法的舍入)
    localparam integer CLKIN1_PERIOD_PS = CLKIN1_PERIOD_NS * 1000;            // 10000 ps
    localparam integer MULT_MILLI       = CLKFBOUT_MULT_F * 1000;             // 12500
    localparam integer OUTDIV_MILLI     = CLKOUT0_DIVIDE_F * 1000;            // 8000
    localparam integer HALF_DP_PS       = (CLKIN1_PERIOD_PS * DIVCLK_DIVIDE * OUTDIV_MILLI)
                                          / (2 * MULT_MILLI);                 // 3200 ps

    wire locked_raw;

    //==================================================================
    // 时钟产生: 两条互斥路径 (generate if/else, 只综合一条)
    //==================================================================
    generate
    if (SIM_BYPASS != 0) begin : g_sim
        //--------------------------------------------------------------
        // 行为级模型: T_dp = T_in * DIVCLK_DIVIDE * CLKOUT0_DIVIDE_F / MULT_F
        // 默认参数下 = 10.000 * 1 * 8.000 / 12.500 = 6.400 ns (156.25 MHz)
        // HALF_DP_PS 为整数 ⇒ 只有当它整除时才精确 (默认配置 3200 精确)。
        // 若某组参数不精确, 频率比门会以"非 0 误差"报出来 —— 这是特性不是 bug。
        //--------------------------------------------------------------
        reg clk_dp_byp = 1'b0;
        always #(HALF_DP_PS / 1000.0) clk_dp_byp = ~clk_dp_byp;

        assign clk_dp     = clk_dp_byp;
        assign clk_in_100 = clk_p;      // 行为级: 直接透传 (真路径是 IBUFDS+BUFG)

        // LOCKED 行为模型: 参考钟连续活跃 ⇒ 锁; 参考钟停 >16 个 clk_dp 周期 ⇒ 失锁。
        // (真 MMCM 的锁定时序慢得多 —— 那正是 SIM_BYPASS 存在的理由。)
        reg [4:0] quiet = 5'd0;
        reg       lock_byp = 1'b0;
        always @(posedge clk_p) quiet <= 5'd0;
        always @(posedge clk_dp_byp) begin
            if (quiet != 5'd31) quiet <= quiet + 5'd1;
            lock_byp <= (quiet < 5'd16);
        end
        assign locked_raw = lock_byp;
    end
    else begin : g_hw
        //--------------------------------------------------------------
        // 真实硬件路径
        //--------------------------------------------------------------
        wire clk_in_ibuf;
        wire clk_in_bufg;

        IBUFDS #(
            .DIFF_TERM    ("FALSE"),        // 板上已有 R58 100Ω 差分端接 + 1k/1k 偏置
            .IOSTANDARD   ("DIFF_SSTL12")   // 见头注释: VCCO=1.2V, 共模 0.6V=VCCO/2
        ) u_ibufds (
            .I  (clk_p),
            .IB (clk_n),
            .O  (clk_in_ibuf)
        );

        BUFG u_bufg_in (
            .I (clk_in_ibuf),
            .O (clk_in_bufg)
        );
        assign clk_in_100 = clk_in_bufg;

        wire clk_fb;
        wire clk_out0;

        MMCME4_BASE #(
            .BANDWIDTH          ("OPTIMIZED"),
            .CLKFBOUT_MULT_F    (CLKFBOUT_MULT_F),
            .CLKFBOUT_PHASE     (0.000),
            .CLKIN1_PERIOD      (CLKIN1_PERIOD_NS),
            .CLKOUT0_DIVIDE_F   (CLKOUT0_DIVIDE_F),
            .CLKOUT0_DUTY_CYCLE (0.500),
            .CLKOUT0_PHASE      (0.000),
            .DIVCLK_DIVIDE      (DIVCLK_DIVIDE),
            .REF_JITTER1        (REF_JITTER1),
            .STARTUP_WAIT       ("FALSE")
        ) u_mmcm (
            .CLKOUT0  (clk_out0),
            .CLKFBOUT (clk_fb),
            .CLKFBIN  (clk_fb),
            .CLKIN1   (clk_in_bufg),
            .LOCKED   (locked_raw),
            .PWRDWN   (1'b0),
            .RST      (1'b0)        // 不软复位 MMCM: 复位由下方 locked/rst_ext 逻辑负责
        );

        BUFG u_bufg_out (
            .I (clk_out0),
            .O (clk_dp)
        );
    end
    endgenerate

    assign locked = locked_raw;

    //==================================================================
    // 复位: 异步置位 / 同步释放 (见头注释 "locked 的语义")
    //   置位源 = ~locked (MMCM 失锁) | rst_ext (外部)
    //   释放   = 连续 4 个 clk_dp 上升沿都看到置位源为 0
    //==================================================================
    wire rst_async = (~locked_raw) | rst_ext;

    (* ASYNC_REG = "TRUE" *) reg [3:0] rel_sr;

    always @(posedge clk_dp or posedge rst_async) begin
        if (rst_async) rel_sr <= 4'h0;
        else           rel_sr <= {rel_sr[2:0], 1'b1};
    end

    assign rst_dp = ~rel_sr[3];

endmodule
