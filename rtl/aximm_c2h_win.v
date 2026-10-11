`timescale 1ns/1ps
//=============================================================================
// aximm_c2h_win.v — M1 期 B: 挂在 XDMA `m_axi` **读通道**上的 AXI-MM 只读从机
//=============================================================================
// 角色: XDMA 的 C2H 引擎发起 AR 突发 ⇒ 本从机把 `mir_dma_ring` 的 16 KB 环
//   **按卡内地址**呈现出去 (128 位 R 通路, 每拍一行 = 4 个 32 位字)。主机侧 =
//   `/dev/xdma0_c2h_0` 上 `lseek(卡内字节偏移) + read` (见 `p7b_mir_dump.cpp` 头注释)。
//
// ---- 从机合同 (冻结; 每一条都有单元门判据) ----
//   · **永远应答**: AR 被接受后, 所有 R 拍都由本地存储产生 ⇒ 不存在"等数据"的停顿;
//     唯一的停顿源是主机的 `rready` 低。⛔ 从机**不得**悬空任何握手。
//   · **ID 回填**: `rid` = 本笔 `arid` (⛔ 本 IP 把 `m_axi_arid` 在核内硬接 0 ——
//     `xdma_0_sim_netlist.v:9851-9854` 逐字 `assign m_axi_arid[3:0] = <const0>`;
//     但回填逻辑照实现, 不依赖"它恒 0"这个事实)。
//   · **地址映射**: 卡内字节地址 `[ROW_AW+3:0]` = {行[ROW_AW-1:0], 4'b0} ⇒ 每行 16 字节;
//     读 = **幂等** (不移动任何指针)。
//   · **合法性** (不合法 ⇒ **整笔 SLVERR + 照常发满 arlen+1 拍 + rlast**, 响亮不挂):
//       ① `araddr[63:ROW_AW+4] == 0` (窗外)   ② `araddr[3:0] == 0` (未对齐, 见下)
//       ③ `arsize == 3'd4` (16 B/拍)          ④ `arburst[1] == 0` (只认 FIXED/INCR)
//     ⚠️ ② 的理由: 未对齐访问要按 AXI 字节通道语义拆拍, 本从机**不做**那种映射 ⇒ 与其
//        "静默返回错位数据", 不如**响亮 SLVERR** (本工程口径)。XDMA 引擎是否可能发未对齐
//        = **未现核** (登记; 见下"IP 侧的既知事实")。
//     ⚠️ ④ 的理由: IP 把 `m_axi_arburst[1]` 核内硬接 0 (`:9855-9856`) ⇒ **WRAP 结构性
//        不可能**; 但本从机仍显式拒 WRAP, 不依赖那个事实。
//   · **4 KB 边界**: 本从机地址映射是**线性**的 (行地址自然递增) ⇒ 跨 4 KB 的突发会被
//     **正确服务** (不拒)。AXI4 规定主机不该发跨 4 KB 的突发; 这里只是"来者不拒且正确"。
//
// ---- IP 侧的既知事实 (明文网表现读, 2026-10-11; 全部可回核) ----
//   `vivado_prj/p7b_ku5p_prj.gen/sources_1/ip/xdma_0/xdma_0_sim_netlist.v`:
//     · `:9851-9854` `assign m_axi_arid[3:0] = <const0>` (同 `:9869-9872` AWID)
//     · `:9855-9856` `m_axi_arburst[1] = const0` · `[0] = ^m_axi_arburst[0]` ⇒ 只可能 00/01
//     · `:9882-9883` `m_axi_arsize[1:0] = const0` · `[2] = ^m_axi_arsize[2]` ⇒ size ∈ {0, 4}
//     · `:9857-9860` `arcache = 4'b0011` · `:9861` `arlock = 0` · `:9862-9864` `arprot = 0`
//       ⇒ 本从机**忽略** cache/lock/prot 是安全的 (它们恒为常量)。
//     · 两个通道的信号在 core_top 里**各自独立直连** (无共享 glue): 逐信号计数
//       port/wire/例化三处, 无第四条引用 ⇒ 明文层面读/写通道无耦合。⚠️ **引擎本体在
//       加密块内** (`xdma_v4_2_2_udma_wrapper`, 明文段 153080-329416 为加密信封) ⇒
//       "只接读通道、写通道留 tie-off 是否安全"**明文网表判不了** (登记为未定项)。
//
// ---- 时钟/复位 ----
//   clk/rst_n = `pcie_axi_aclk` / `pcie_axi_aresetn` (与 `axi_regs`、环、XDMA 的
//   m_axi 同域同源) ⇒ **零新增 CDC**。
//=============================================================================
module aximm_c2h_win #(
    parameter integer ROW_AW = 10          // 环行深 (必须与 mir_dma_ring 同值) ⇒ 窗口 = 2^(ROW_AW+4) B
)(
    input  wire                clk,
    input  wire                rst_n,
    // ---- m_axi 读通道 (来自 XDMA) ----
    input  wire [3:0]          arid,
    input  wire [63:0]         araddr,
    input  wire [7:0]          arlen,
    input  wire [2:0]          arsize,
    input  wire [1:0]          arburst,
    input  wire                arvalid,
    output wire                arready,
    output wire [3:0]          rid,        // = 本笔 arid 的回填 (寄存器)
    output reg  [127:0]        rdata,
    output reg  [1:0]          rresp,
    output reg                 rlast,
    output reg                 rvalid,
    input  wire                rready,
    // ---- 环读口 (pcie 域; 同源时钟) ----
    output wire [ROW_AW-1:0]   rr_row,     // 行地址
    input  wire [127:0]        rr_dout     // 该行数据 (1 拍延迟)
);

`ifndef SYNTHESIS
    initial begin
        if (ROW_AW < 2) begin
            $display("FATAL aximm_c2h_win: ROW_AW=%0d 非法 (要求 >=2)", ROW_AW);
            $finish;
        end
    end
`endif

    localparam [1:0] S_IDLE  = 2'd0,   // 等 AR (arready=1)
                     S_PRE   = 2'd1,   // 1 拍: 把第一行地址呈现给环读口
                     S_DATA  = 2'd2,   // 逐拍发 R (1 拍/行 = 1 拍/拍)
                     S_DONE  = 2'd3;   // 末拍 (arlen==0 的单拍突发) 等 rready 收尾

    // ---- 合法性判据 (全部由输入组合决定, 与状态无关) ----
    wire legal = (araddr[63:ROW_AW+4] == {64-ROW_AW-4{1'b0}})
              && (araddr[3:0] == 4'd0)
              && (arsize == 3'd4)
              && (arburst[1] == 1'b0);

    reg [1:0]        st;
    reg [3:0]        rid_r;
    reg [7:0]        arlen_r;
    reg              err_r;         // 1 = 本笔整笔 SLVERR (数据回 0)
    reg              fixed_r;       // FIXED 突发: 行地址不递增
    reg [ROW_AW-1:0] row_r;
    reg [7:0]        cur_r;

    assign rr_row  = row_r;
    assign arready = (st == S_IDLE);
    assign rid     = rid_r;          // ID 回填 (本笔 AR 的 id; ⛔ 别忘这根线 —— 单元门抓过)

    // 行地址推进的**唯一条件** = "本拍把一行数据装进 rdata" (一次 presentation) **且是 INCR**:
    //   S_PRE (装第一行) · S_DATA 且 (!rvalid) (第一拍) · S_DATA 且 rready 且非末拍 (换下一拍)
    //   ⇒ 每一拍都已把"下一行"摆上读口 (环读口 1 拍延迟 ⇒ 数据链永不断)。
    //   ⚠️ FIXED (burst=00, IP 侧可能发: `m_axi_arburst[1]` 核内硬接 0) ⇒ **不推进** (每拍同一行)。
    wire row_go = !fixed_r &&
                  ((st == S_PRE)
                || (st == S_DATA && (!rvalid))
                || (st == S_DATA && rvalid && rready && (cur_r != arlen_r)));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= S_IDLE;
            rid_r   <= 4'd0;
            arlen_r <= 8'd0;
            err_r   <= 1'b0;
            fixed_r <= 1'b0;
            row_r   <= {ROW_AW{1'b0}};
            cur_r   <= 8'd0;
            rdata   <= 128'd0;
            rresp   <= 2'b00;
            rlast   <= 1'b0;
            rvalid  <= 1'b0;
        end else begin
            case (st)
            S_IDLE: begin
                rvalid <= 1'b0;
                if (arvalid) begin                        // arready 本拍 = 1 ⇒ 握手成立
                    rid_r   <= arid;
                    arlen_r <= arlen;
                    err_r   <= !legal;
                    fixed_r <= (arburst == 2'b00);
                    row_r   <= araddr[ROW_AW+3:4];
                    cur_r   <= 8'd0;
                    st      <= S_PRE;
                end
            end
            S_PRE: begin                                  // 呈现第一行 (rr_dout 下拍有效)
                if (row_go) row_r <= row_r + {{(ROW_AW-1){1'b0}}, 1'b1};
                st <= S_DATA;
            end
            S_DATA: begin
                if (!rvalid) begin                        // 第一拍: 采用 rr_dout, 不需要 rready
                    rdata  <= err_r ? 128'd0 : rr_dout;
                    rresp  <= err_r ? 2'b10 : 2'b00;
                    rlast  <= (arlen_r == 8'd0);
                    rvalid <= 1'b1;
                    if (row_go) row_r <= row_r + {{(ROW_AW-1){1'b0}}, 1'b1};
                    if (arlen_r == 8'd0) st <= S_DONE;    // 单拍突发: 等 rready 收尾
                end else if (rready) begin                // 当前拍被取走 ⇒ 换下一拍
                    if (cur_r == arlen_r) begin           // 末拍已取走 ⇒ 整笔完成
                        rvalid <= 1'b0;
                        st     <= S_IDLE;
                    end else begin
                        cur_r  <= cur_r + 8'd1;
                        rdata  <= err_r ? 128'd0 : rr_dout;   // rr_dout 仍对应已推进的行
                        rresp  <= err_r ? 2'b10 : 2'b00;
                        rlast  <= ((cur_r + 8'd1) == arlen_r);
                        if (row_go) row_r <= row_r + {{(ROW_AW-1){1'b0}}, 1'b1};
                    end
                end
            end
            S_DONE: begin                                 // 只有 arlen==0 会进来
                if (rready) begin
                    rvalid <= 1'b0;
                    st     <= S_IDLE;
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    // ⚠️ 未用输入 (arcache/arlock/arprot 等) 由 wrapper 侧不接 —— 本模块端口表里**没有**它们。
    //    未用信号在 wrapper 的连接处显式悬空 (加注释), 不引入隐式网 (工程坑 24)。

endmodule
