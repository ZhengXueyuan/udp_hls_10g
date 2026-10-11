`timescale 1ns/1ps
//=============================================================================
// mir_dma_ring.v — M1 期 B: DMA 侧的**采集环** (排空器 + 16 KB 环 + 字计数器)
//=============================================================================
// 设计件 = `_proj_10g/notes/P7B_PCIE_DATAPATH_DESIGN.md` §2.2 候选 (A) 的"板载环形缓冲"
//   —— 但**按本树实况收窄了一处**: 设计件写"BRAM 真双口: 写口 @dp_clk、读口 @pcie_axi_clk"，
//   那种接法要求"写指针/已写量"跨 dp→pcie 传 (多比特 CDC)。本实现把它**整体放进 pcie 域**:
//   写口由**排空器**从镜像的 FIFO 里逐字弹出 (`app_rx_mirror` 的 aux 读口), 于是
//   **多比特 CDC 一条都不需要** (设计件自己点名的正是这个风险) —— 代价 = 写入要过 FIFO 一级
//   (1 KB 弹性, 见 `app_rx_mirror` 头注释"两条读出口不许混用")。⛔ 偏离处如实登记在此。
//
// 数据流:
//   app_rx_mirror.FIFO (32b, dp→pcie) ──(aux 弹出)──> 本模块: 32b 写口 (pcie 域)
//                                                          │  4 bank × 2^ROW_AW 行 × 32b
//   aximm_c2h_win (AXI-MM 读从机) <──(1 拍延迟读行 = 128b)──┘  逻辑字 L → 物理 (L mod RING_WORDS)
//
// 语义 (冻结; 都是判据的依据):
//   · **幂等只读**: 读口**不移动任何指针** ⇒ 重读/多读者/主机重启都安全 (与 MIR_DATA 的
//     "读=弹出"是两种语义 —— 别在文档里混用)。
//   · `wr_words` = **已写进环的字数** (32 位, mod 2^32 自然回绕)。主机侧协议:
//     `cur = wr_words` 起读, 每次读前重取该值; 一段数据的**新鲜度**由"写者是否已回绕越过
//     该段起点"判定 (主机侧事后检查, 见 `p7b_mir_dump.cpp` 的 `clobber`)。
//   · `clr_pulse` (来自镜像的 rd 域 clr 脉冲) ⇒ `wr_words` 与写指针**同时归零**:
//     "逻辑字 0" 从这一刻起算 ⇒ 起测协议 (① clr ② cap_en=1 ③ 发端开跑) 之后
//     主机拿到的字节流**从被采集流的第一字节开始**, 字节偏移 = 4 × wr_words (判据锚)。
//   · `en` (dma_en) = 0 时**只停采**: 环里旧内容照常可读 (读侧永远应答), 计数器不动。
//   · 环会被写者**回绕覆盖** (free-running): 没有流控、没有 full —— 这是"不可丢帧"的
//     反面对价, 由计数器差分 + clobber 检查**可观测** (本工程口径: 丢字不许静默)。
//
// 实现要点:
//   · 4 个 bank (每 bank 2^ROW_AW × 32b) ⇒ 128 位 R 拍 = **一次行读** (4 bank 并行同址),
//     读口在 pcie 域**每拍可出一行** ⇒ R 通路不受环读口限制 (128b @250MHz = 4 GB/s)。
//   · 写口每拍 1 字 (bank = 物理字[1:0]) ⇒ 与排空器 1 字/拍对齐。
//   · mem **不带复位** (BRAM 推断前提, 同 fifo_async); 数据可见性 = 写入沿之后**下一拍**
//     即可被读口看到 (同一时钟域, 无同步器) ⇒ 主机读到"未写完的整行"时, 未写的那几个字
//     是旧值 —— 由 `wr_words` 截断 (主机只用 < 计数器的字) 保证不用到它们。
//   · 参数自检在仿真里**响亮地死** (同 fifo_async 的做法): 参数非法不许静默少一块存储。
//=============================================================================
module mir_dma_ring #(
    // 环深 = 4 × 2^ROW_AW 个字 (字 = 32 位) ⇒ ROW_AW=10 ⇒ 4096 字 = 16 KB。
    parameter integer ROW_AW = 10
)(
    input  wire                rd_clk,        // pcie_axi_aclk (写口/读口/计数器同域)
    input  wire                rst_n,         // pcie_axi_aresetn
    input  wire                en,            // dma_en (MIR_CTRL[3]); 0 = 停采 (环内容照常可读)
    input  wire                clr_pulse,     // 镜像的 clr_pulse_rd: 计数/写指针归零
    // ---- 排空口 (接 app_rx_mirror 的 aux 读口) ----
    output wire                src_req,       // 恒 = en (镜像侧再与 !empty/优先级合门)
    input  wire                src_gnt,       // 1 拍: 本拍 src_data 已被弹出 (写一字)
    input  wire [31:0]         src_data,      // 被弹出的那个字
    // ---- AXI 从机的读口 (128 位行读; 1 拍延迟) ----
    input  wire [ROW_AW-1:0]   rr_row,        // 行地址 (物理行 = 逻辑字[ROW_AW+1:2])
    output reg  [127:0]        rr_dout,       // 该行 4 个字 {bank3,bank2,bank1,bank0}
    // ---- 观测/主机侧 ----
    output reg  [31:0]         wr_words       // 已写字数 (→ 快照/寄存器; mod 2^32)
);

`ifndef SYNTHESIS
    initial begin
        if (ROW_AW < 2) begin
            $display("FATAL mir_dma_ring: ROW_AW=%0d 非法 (要求 >=2)", ROW_AW);
            $finish;
        end
    end
`endif

    localparam integer ROWS = 1 << ROW_AW;

    // ---- 存储: 4 个 bank (无复位写块 = BRAM 推断前提) ----
    reg [31:0] mem0 [0:ROWS-1];
    reg [31:0] mem1 [0:ROWS-1];
    reg [31:0] mem2 [0:ROWS-1];
    reg [31:0] mem3 [0:ROWS-1];

    wire [ROW_AW+1:0] wphys = wr_words[ROW_AW+1:0];   // 物理字号 = 计数器的低 ROW_AW+2 位
    wire [ROW_AW-1:0] wrow  = wphys[ROW_AW+1:2];      // 物理行
    wire [1:0]        wbank = wphys[1:0];             // bank

    // ---- 写口 (每拍至多 1 字; 计数器与写地址**同一个寄存器**) ----
    always @(posedge rd_clk) begin
        if (src_gnt) begin
            case (wbank)
                2'd0: mem0[wrow] <= src_data;
                2'd1: mem1[wrow] <= src_data;
                2'd2: mem2[wrow] <= src_data;
                2'd3: mem3[wrow] <= src_data;
            endcase
        end
    end

    always @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n)          wr_words <= 32'd0;
        else if (clr_pulse)  wr_words <= 32'd0;       // clr ⇒ 计数与写指针同拍归零 ("逻辑字 0")
        else if (src_gnt)    wr_words <= wr_words + 32'd1;
    end

    // ---- 读口 (AXI 从机; 1 拍延迟; 4 bank 并行同址 = 一行 128 位) ----
    always @(posedge rd_clk) begin
        rr_dout <= {mem3[rr_row], mem2[rr_row], mem1[rr_row], mem0[rr_row]};
    end

    assign src_req = en;

endmodule
