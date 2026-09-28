`timescale 1ns/1ps
// 带帧回卷的 FWFT 同步 FIFO (fifo_sync 同语义 + 写指针快照/回卷)。
// snap (帧首拍): 快照本拍写后的 wptr; rollback (帧判定拍): wptr 回卷, 该帧已写字全部作废。
// full 为保守判定 (忽略同拍 rd), 无组合环; 深度必须 >= 单帧最大字数 (1518B = 190 字)。
//
// P4b-7-P6 改动 (两轮):
//   P6a: 内存由 reg 数组改显式 Xilinx BRAM 原语 (原全宽寄存器数组读 mux 链 12 级,
//     板级 WNS=-2.9ns 不收敛)。布局: 主存 din[63:0] 拆 NB=D/512 片 RAMB36E1 (512 字
//     x72 SDP), 边存 din[W-1:64] (W=73 时 9 bit) 拆 NB 片 RAMB18E1 (512 字 x36 SDP)。
//   P6b (本版): P6a 的 RAMB18E1 侧存板级丢 tlast (回显帧流断 tlast -> 冻结根因; 单元
//     TB 逐拍通过但摸不出, 板级才暴露) -> 边存退回 LUTRAM reg 数组 + 寄存器读; 主存
//     RAMB36E1 保留 (WNS 时序驱动在主存 64bit 宽路径, 与侧存独立)。
//   P6c: 加 dbg_rd_addr/dbg_rd_side 边存组合读口 (tlast 位图转储: 冻结后按 rptr±32
//     直读边存 bit SW-1, 看 tlast=1 的帧末拍落在哪些槽)。纯读, 无逻辑耦合。
// 布局: 主存 = NB x RAMB36E1 (512 字 x72 SDP, 覆盖 din[63:0]); 边存 = LUTRAM reg 数组
//   [0:D-1] 单块覆盖全深 (无片选/回卷; W=73 时 SW=9 位存 tkeep+tlast), 读出寄存器
//   side_dout_r <= mem_s[rptr_n] —— 1 拍读延迟与主存 DOA_REG=0 对齐, 呈现时
//   {side_dout_r, main_sel} 拼回 W 位。W<=64 时无边存 (主存余 [W-1:0], SW 占位 1
//   防 0 宽; 无复位写块是 LUTRAM 推断前提, 故 mem_s 只存在于 W>64 分支)。
// 主存 BRAM 端口语义 (7 系列 unisim 实测 + xpm_fifo 综合网表对照; 边存 LUTRAM 不适用):
//   - SDP 模式写口 = B (ADDRBWRADDR/CLKBWRCLK/ENBWREN/WEBWE), 读口 = A
//     (ADDRARDADDR/CLKARDCLK/ENARDEN/REGCEAREGCE)。DOA_REG=0: 沿 N 捕获的字在
//     N+1 呈现 (1 拍延时, 与边存寄存器读逐拍一致); DOA_REG=1 是 2 拍延时, 无法
//     逐拍复刻, 故必须 DOA_REG(0)。
//   - 512 行配置的无效位按 Xilinx 网表惯例 (xpm 亦如此) 恒接 1。字址位段实测
//     (单元 TB 碰撞时序反推): RAMB36 (16 位地址) 512x72 字址在 [14:6]:
//     {1'b1, a[8:0], 6'h3F}。DRC: WRITE_MODE_A 必须 == WRITE_MODE_B。
//   - unisim 实测: 写边沿 ENARDEN=0 的写会丢 (探针 P3: 唯一 ENARDEN=0 的写未落盘;
//     P2/P4 全部 ENARDEN=1 的写落盘且读回正确)。故 ENARDEN 恒 1, 每片每拍以本地
//     r_ad[8:0] 捕获; 空拍重复捕获同址无害 (读不改内容)。
//
// 拍级语义 (主/边逐拍对齐, 消费端零改动):
//   - 读捕获: 主存每拍 ENARDEN=1, 地址 = rptr_n (下一拍的头); 边存同沿同址读
//     side_dout_r <= mem_s[rptr_n[AW-1:0]] —— 等价旧 dout_r <= mem[rptr_n]。
//   - 同址写 (旧 RTL 的 bypass 拍: 空推入 / 深度 1 pop+push) 与捕获同沿撞同址 →
//     主存 WRITE_FIRST 碰撞: 该片 DOA 在碰撞沿后 X 一拍, 存储内容存活 (探针 P4 P2:
//     X 一拍后读回正确); 边存 LUTRAM 天然 read-first: 读到碰撞沿前的旧槽内容 (无 X)。
//     两半碰撞拍内容都不对, 但都被 bypass_r 掩掉 (bypass_r(N+1)=bypass(N)=1,
//     dout 走 din_r; din_r 全 W 位含 din[W-1:64]), 永不漏出; 非 bypass 拍
//     写址 != 读址, 无碰撞。
//   - 直通: bypass_r/din_r 登记 bypass 拍, 下拍 dout = din_r —— 等价旧 bypass 分支。
//   - 显示选择 (主存): DOA_REG 输出 = 上拍捕获 (地址 = rptr_n 上拍值 == 本拍 rptr),
//     故输出 mux 按登记指针 rptr (非 rptr_n!) 选片 —— 跨片边界拍 rptr_n 已进下一片
//     而 DOA 仍在上片, 若按 rptr_n 选片会拿错片冻结输出。写路径不受此限。边存数组
//     覆盖全深, 无片选, 寄存器读天然与 rptr 对齐。
module frame_fifo #(
    parameter W  = 73,
    parameter D  = 2048,
    parameter AW = 11,
    // side 宽 (din[W-1:64]); 1 占位防 0 宽。parameter (非 localparam) 供 ANSI
    // 端口表引用 (dbg_rd_side 宽度 = SW; Verilog 端口表看不到 body 的 localparam)。
    parameter SW = (W > 64) ? (W - 64) : 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        wr,
    input  wire [W-1:0] din,
    input  wire        snap,
    input  wire        rollback,
    input  wire        rd,
    output wire [W-1:0] dout,
    output wire        empty,
    output wire        full,
    // P4b-7-P6 诊断 (UART RX 侧快照, 纯 assign): 指针/空标志读出
    output wire [AW:0] dbg_wptr,
    output wire [AW:0] dbg_rptr,
    output wire        dbg_empty,
    // P4b-7-P6 诊断 (边存 tlast 位图转储): 组合读址 + 该址边存值 (bit SW-1 = tlast)
    // 址 = 边存槽址 (低 AW 位, 天然 mod D); 与读指针/空满逻辑零耦合。W<=64 时
    // 无边存, 读出恒 0 (SW=1 占位宽度)。
    input  wire [AW-1:0] dbg_rd_addr,
    output wire [SW-1:0] dbg_rd_side
);

    localparam NB = D / 512;                  // 片数; 每片 512 字 (全实例 D%512==0)

    reg [AW:0]   wptr, rptr, wsnap;
    reg          bypass_r;                    // 上拍 bypass 的登记 (本拍输出直通字)
    reg [W-1:0]  din_r;

    // full = 真满 (绕回位不同 + 低位相同), 与 fifo_sync 同式。
    // 曾用 "+1 保守式": wptr 低位==511 时等效 rptr 低位==512 (不可能) → rptr 低
    // 位==0 的窗口内 full 永不触发, 写入绕回踩槽 (P4a slowrx 单元 TB 实锤)。
    wire        full_n  = (wptr[AW-1:0] == rptr[AW-1:0]) && (wptr[AW] != rptr[AW]);
    wire        empty_n = (wptr == rptr);
    wire        rd_ok   = rd && !empty_n;
    wire        wr_ok   = wr && !full_n;
    wire [AW:0] rptr_n  = rptr + (rd_ok ? 1'b1 : 1'b0);
    wire [AW:0] wptr_n  = wptr + (wr_ok ? 1'b1 : 1'b0);
    wire        bypass  = wr_ok && (rptr_n[AW-1:0] == wptr[AW-1:0]);
    // (ENARDEN 恒 1 见头注释: 写边沿 ENARDEN=0 的写在 unisim 上会丢)

    // 全宽字地址 (含片号位段) 做片选范围比较; 片内地址 = 低 9 位 (512 对齐天然切出)
    wire [AW-1:0] w_ad = wptr[AW-1:0];
    wire [AW-1:0] r_ad = rptr_n[AW-1:0];      // 捕获地址 (下一拍头)
    wire [AW-1:0] r_sel = rptr[AW-1:0];       // 显示地址 (当前头)

    // 主存掩码累积: 非显示片 DOA 冻结于旧值, 必须清零掩掉; 显示片 r_hit_o=1 直通 DOA。
    // (边存 LUTRAM 单数组覆盖全深, 无掩码; 边存 reg/读寄存器见 gen_side。)
    wire [63:0]  main_mux [NB-1:0];
    reg  [63:0]  main_sel;

    // ---------------- 主存: NB x RAMB36E1 (x72 SDP, 写口 B / 读口 A) ----------------
    genvar g;
    generate
    for (g = 0; g < NB; g = g + 1) begin : gen_mem
        wire w_hit = (w_ad >= g * 512) && (w_ad < (g + 1) * 512);  // 本片写选
        wire r_hit_o = (r_sel >= g * 512) && (r_sel < (g + 1) * 512);  // 本片为显示片
        wire [63:0] mo;                       // 本片 DOA 读回 (DOA_REG=0: 1 拍延时)

        RAMB36E1 #(
            .RAM_MODE("SDP"),
            .WRITE_WIDTH_A(72), .WRITE_WIDTH_B(72),
            .READ_WIDTH_A(72), .READ_WIDTH_B(72),
            .WRITE_MODE_A("WRITE_FIRST"), .WRITE_MODE_B("WRITE_FIRST"),
            .DOA_REG(0), .DOB_REG(0),
            .RDADDR_COLLISION_HWCONFIG("DELAYED_WRITE"),
            .SIM_COLLISION_CHECK("ALL"),
            .SIM_DEVICE("7SERIES")
        ) u_main (
            .CLKARDCLK(clk), .CLKBWRCLK(clk),
            .ENARDEN(1'b1), .ENBWREN(1'b1),    // 每拍捕获 (写边沿必须 ENARDEN=1)
            .WEA(4'h0), .WEBWE(w_hit && wr_ok ? 8'hFF : 8'h00),
            .ADDRARDADDR({1'b1, r_ad[8:0], 6'h3F}),
            .ADDRBWRADDR({1'b1, w_ad[8:0], 6'h3F}),
            .DIADI(din[31:0]), .DIPADIP(4'h0),
            .DIBDI(din[63:32]), .DIPBDIP(4'h0),
            .REGCEAREGCE(1'b1), .REGCEB(1'b0),
            .RSTRAMARSTRAM(1'b0), .RSTRAMB(1'b0),
            .RSTREGARSTREG(1'b0), .RSTREGB(1'b0),
            .DOADO(mo[31:0]), .DOPADOP(),
            .DOBDO(mo[63:32]), .DOPBDOP(),
            .CASCADEINA(1'b0), .CASCADEINB(1'b0),
            .CASCADEOUTA(), .CASCADEOUTB(),
            .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
            .DBITERR(), .SBITERR(), .ECCPARITY(), .RDADDRECC()
        );
        assign main_mux[g] = r_hit_o ? mo : 64'h0;
    end
    endgenerate

    // ---------------- 边存 (tkeep+tlast: W=73 时 9 位) ----------------
    // P6b: P6a 的 RAMB18E1 侧存板级丢 tlast (冻结根因) -> 退回 LUTRAM reg 数组 + 寄存器
    // 读 (P4b-6 板级验证过的形式); 主存 RAMB36E1 保留。无复位写块 (LUTRAM 推断前提;
    // 加 ram_style 防被重映成 BRAM), 读寄存器带异步复位。读址 = rptr_n —— 与主存捕获
    // 同址同拍, 1 拍读延迟对齐主存 DOA_REG=0。碰撞 (bypass) 拍读到碰撞前的旧槽内容,
    // 由 bypass_r/din_r 直通掩掉 (与主存 WRITE_FIRST 的 X 拍同一掩除机制)。
    reg [SW-1:0] side_dout_r;              // 侧段呈现值 (W<=64 时 gen_no_side 恒 0)
    wire [SW-1:0] dbg_side_mux;            // 边存诊断读口 (组合读, 见端口注释)
    generate if (W > 64) begin : gen_side
        (* ram_style = "distributed" *) reg [SW-1:0] mem_s [0:D-1];
        always @(posedge clk) begin
            if (wr_ok) mem_s[wptr[AW-1:0]] <= din[W-1:64];
        end
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) side_dout_r <= {SW{1'b0}};
            else side_dout_r <= mem_s[rptr_n[AW-1:0]];
        end
        // P4b-7-P6 诊断: 组合读第 2 读口 (ram_style=distributed 下 Vivado 复制
        // LUTRAM 存储实现多读口; 下游只用 bit SW-1 = tlast, 综合裁剪其余位)。
        assign dbg_side_mux = mem_s[dbg_rd_addr];
    end else begin : gen_no_side
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) side_dout_r <= {SW{1'b0}};
            else side_dout_r <= {SW{1'b0}};
        end
        assign dbg_side_mux = {SW{1'b0}};
    end endgenerate

    // 主存掩码 OR 累积选片 (显示片唯一, 余片已清零)
    integer i;
    always @* begin
        main_sel = 64'h0;
        for (i = 0; i < NB; i = i + 1)
            main_sel = main_sel | main_mux[i];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= 0; rptr <= 0; wsnap <= 0;
            bypass_r <= 0; din_r <= 0;
        end else begin
            if (rollback) wptr <= wsnap;
            else wptr <= wptr_n;
            if (rd_ok) rptr <= rptr_n;
            bypass_r <= bypass;
            if (bypass) din_r <= din;      // 仅 bypass 拍采样, 下拍直通
            if (snap) wsnap <= wptr;
        end
    end

    assign dout  = bypass_r ? din_r : ((W > 64)
                          ? {side_dout_r, main_sel}
                          : main_sel[W-1:0]);
    assign empty = empty_n;
    assign full  = full_n;

    // P4b-7-P6 诊断读出 (纯线束, 与逻辑零耦合)
    assign dbg_wptr  = wptr;
    assign dbg_rptr  = rptr;
    assign dbg_empty = empty_n;
    assign dbg_rd_side = dbg_side_mux;
endmodule
