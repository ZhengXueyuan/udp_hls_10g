//======================================================================
// p7b_lat_drp.v -- 一条 GT DRP 读事务的状态机 (每通道一个实例)
//======================================================================
//
// 为什么要它
// ----------
//   P7b 现役的 `pcs64` (xxv_ethernet) 是带 `C_ADD_GT_CNTRL_STS_PORTS=0` 生成的,
//   那个参数把每通道的内部 DRP 总线**钉成常量** (生成物
//   `pcs64_wrapper.v:429-434 / :951-956`: drpaddr_in_N=0, drpen_in_N=0, 而
//   drpdo_out_N / drprdy_out_N 悬空) ⇒ 顶层**根本没有 DRP 端口**可接。
//   ⇒ 想读 DRP 就必须把该参数置 1 重新生成 IP, 那时顶层出现:
//        gt_drpaddr_N[9:0] gt_drpen_N gt_drpdi_N[15:0] gt_drpwe_N  (输入)
//        gt_drpdo_N[15:0]  gt_drprdy_N                               (输出)
//        gt_drpclk_N       gt_drprst_N                               (输入)
//     实测取证 = _proj_10g/p7b_lat/scripts/probe_drp_ports.tcl 的读数
//     (`drp_probe_stdout.txt` 的 DRPP_VEO_DRP 行)。
//
// 时序 (逐条抄自 IP 自带的**明文** gtwizard 源码, 不是猜的)
// -------------------------------------------------------
//   · `pcs64/ip_*/hdl/gtwizard_ultrascale_v1_7_gte4_drp_arb.v`
//       :499-539  DRP_READ : DEN_O<=1 与 DADDR_O<=daddr **同一拍**;
//                            DWE_O<=0; **DI_O 在 READ 状态不赋值**(读时 don't-care);
//                 DRP_READ_ACK : DEN_O<=0 (⇒ drpen 只持续 1 拍);
//                            `if (DRDY_I==1'b1) do_r <= DO_I;`
//                            ⇒ **drprdy = 数据有效, 且 drpdo 与它同拍有效**。
//       :411-423  用户侧再由仲裁器经 DRP_DONE -> ARB_WAIT -> ARB_REPORT 交付,
//                 DRDY_USR_O 与 DO_USR_O **仍然同拍**。
//   · 用户是仲裁器的**第 3 个客户端**, 与 TX/RX CPLL 校准 round-robin 共享
//     (`gtye4_cpll_cal.v:318-337`)。0x269 不在被仲裁器劫持的地址表里
//     (`gte4_drp_arb.v:267-278` 只劫持 0x03E/0x057/0x00C/0x0C6)。
//   · DRP 时钟 = `dclk` (`pcs64_wrapper.v:434/:956 assign drpclk_in_N = dclk`),
//     本设计 = clk_in_100 = 100 MHz。地址宽 10 位, 数据宽 16 位。
//
// 与主机侧的接口 (跨域纪律, 必须遵守)
// ----------------------------------
//   `req_addr` / `req_go` 由 VIO (dp_clk 域) 驱动, 本模块在 dclk 域:
//     ⚠️ **主机必须先写 `req_addr`, 停 >= 1ms, 再翻 `req_go`** —— 多比特准静态
//        值的 2FF 同步只在"源在同步窗口内不变"时才安全。本模块的用途是扫描
//        地址 (几十毫秒一位), 天然满足。
//   `out_do` / `out_addr` / `out_timeout` 与 `out_tgl` **同拍发布**, 且在下一次
//   请求之前不再变 ⇒ 接收侧 (dp 域) 只要"看到 out_tgl 变化再采数据"就是安全的。
//   ⚠️ 因此在飞期间**不要**发第二次请求 (本 FSM 会忽略, 但结果会混)。
//======================================================================

`timescale 1ns / 1ps

module p7b_lat_drp (
    input  wire        clk,          // dclk (100 MHz)
    input  wire        rst_n,        // 低有效 (= ~sys_reset_p7b, POR 释放后才跑)
    input  wire [15:0] req_addr,     // 来自 VIO (dp 域): 必须稳定后才翻 req_go
    input  wire        req_go,       // 电平; 边沿检测 => 一次读事务
    // ---- GT DRP 总线 (直连 pcs64 的 gt_drp*_N) ----
    output reg  [9:0]  drpaddr,
    output reg  [15:0] drpdi,
    output reg         drpen,
    output reg         drpwe,
    output reg         drprst,
    input  wire [15:0] drpdo,
    input  wire        drprdy,
    // ---- 结果 (发布到 dp 域) ----
    output reg  [15:0] out_do,
    output reg  [15:0] out_addr,
    output reg         out_timeout,
    output reg         out_tgl,      // 每完成一次事务翻一次
    output reg  [15:0] out_evt       // 完成的事务数 (含超时), 供主机判"这一代真跑过"
);

    (* ASYNC_REG = "TRUE" *) reg [2:0] go_sr;
    reg go_seen;
    wire go_pulse = go_sr[2] ^ go_seen;

    (* ASYNC_REG = "TRUE" *) reg [15:0] addr_sr;   // 准静态, 见头注释的纪律

    localparam [1:0] D_IDLE = 2'd0, D_REQ = 2'd1, D_WAIT = 2'd2;
    reg [1:0] st;
    reg [7:0] tmo;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            go_sr <= 3'b000; go_seen <= 1'b0;
            addr_sr <= 16'd0;
            st <= D_IDLE; tmo <= 8'd0;
            drpaddr <= 10'd0; drpdi <= 16'd0;
            drpen <= 1'b0; drpwe <= 1'b0; drprst <= 1'b0;
            out_do <= 16'd0; out_addr <= 16'd0; out_timeout <= 1'b0;
            out_tgl <= 1'b0; out_evt <= 16'd0;
        end else begin
            go_sr  <= {go_sr[1:0], req_go};
            addr_sr <= req_addr;                    // 准静态多比特
            // (go_seen 在下面被更新)
            case (st)
                D_IDLE: begin
                    drpen <= 1'b0;
                    if (go_pulse) begin
                        drpaddr <= addr_sr[9:0];    // 地址与 den **同拍**
                        drpdi   <= 16'd0;           // 读时 don't-care, 钉 0 更好读
                        drpwe   <= 1'b0;            // 0 = 读
                        drpen   <= 1'b1;            // den 只 1 拍
                        tmo     <= 8'd0;
                        st      <= D_REQ;
                    end
                end
                D_REQ: begin
                    drpen <= 1'b0;
                    st    <= D_WAIT;
                end
                D_WAIT: begin
                    tmo <= tmo + 8'd1;
                    if (drprdy) begin               // drpdo 与 drprdy 同拍有效
                        out_do      <= drpdo;
                        out_addr    <= {6'd0, drpaddr};
                        out_timeout <= 1'b0;
                        out_evt     <= out_evt + 16'd1;
                        out_tgl     <= ~out_tgl;
                        st          <= D_IDLE;
                    end else if (tmo == 8'hFF) begin
                        out_do      <= 16'hDEAD;    // 超时: 一个不可能被误读成真值的哨兵
                        out_addr    <= {6'd0, drpaddr};
                        out_timeout <= 1'b1;
                        out_evt     <= out_evt + 16'd1;
                        out_tgl     <= ~out_tgl;
                        st          <= D_IDLE;
                    end
                end
                default: st <= D_IDLE;
            endcase
            if (go_pulse) go_seen <= go_sr[2];
        end
    end

endmodule
