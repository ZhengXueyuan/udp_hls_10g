`timescale 1ns/1ps
//=============================================================================
// fifo_async.v — 参数化异步 FIFO (灰码指针 + 两级同步, 经典 Cummings 结构)
//=============================================================================
// 用途: P6b 数据面跨时钟域 (125MHz 前端 ↔ 156.25MHz 数据面)。本工程设计里**第一条
//   真正的双时钟 FIFO** —— 此前的 rtl/fifo_sync.v / rtl/frame_fifo.v 都是单时钟的。
//
// ---- 接口与 fifo_sync / frame_fifo 的关系 (集成侧读这段就够) ----
//   FWFT=1 (**默认**): 与 fifo_sync / frame_fifo **语义逐条相同** ——
//     `!empty` 时 dout 就是当前头字 (组合读出, 同拍有效); `rd_en && !empty` 弹出一字;
//     空态 dout = 旧槽残留/不定 (消费者只在 `!empty` 时取用, 与 frame_fifo 的合同一致)。
//     ⇒ 把 frame_fifo / fifo_sync 换成 fifo_async: 读侧**零改动** (只是 clk → rd_clk),
//       写侧把 clk → wr_clk, rst_n → wr_rst_n/rd_rst_n。
//   FWFT=0: 标准 1 拍读延迟模式 —— `rd_en && !empty` 是"弹出请求", 被弹出的字**下一拍**
//     出现在 dout 上并保持到下一次 rd_en (空态 dout 保留上次的值 = 不定)。
//   ⚠️ 两种模式都在单元门里被测 (tb/tb_fifo_async.v 同时例化 4 个变体: 72/16/FWFT=1、
//     72/16/FWFT=0、40/4/FWFT=1、40/4/FWFT=0)。
//
// ---- 读侧时序表 (dout/empty/rd_en 都在 rd_clk 域) ----
//   FWFT=1:  拍 N: `!empty` ⇒ dout = W (本拍头字); rd_en=1 ⇒ 本拍把 W 弹掉 (消费者本拍
//            取用 W); 拍 N+1: dout = 下一头字 (若 empty=1 则该值不定, 勿用)。
//   FWFT=0:  拍 N: `!empty` 且 rd_en=1 ⇒ 发出弹出请求, **本拍 dout 上的值不是这次弹的**;
//            拍 N+1: dout = W (被请求的字), 有效条件 = 上拍的 `rd_en && !empty`;
//            拍 N+1 若又发请求 ⇒ 拍 N+2 更新, 如此类推。
//
// ---- ⚠️ 满/空标志的 2 拍同步延迟是**契约的一部分**, 上游必须遵守 ----
//   写侧 `full` 由**同步过来的读指针**判定 ⇒ 相对读侧真实状态:
//     · 可能**提前**拉高 (读指针的推进还没传过来 ⇒ 以为更满) ⇒ 最多白白浪费 DEPTH-1 个空位;
//     · 可能**滞后**拉低 (最坏 = 2 个 rd_clk + 2 个 wr_clk + 1 拍; rd 时钟慢时按 rd 周期算,
//       1:100 写快读慢的极端下 full 会长期保持高)。**这是常态, 不是抖动。**
//   硬规则 ①: **只在 `full==0` 时置 `wr_en`**。`full==1` 时的 wr_en 被**静默忽略**
//             (不写入、不报错、那个字丢) —— 本模块与 fifo_sync/frame_fifo 一样**不做溢出保护**。
//   硬规则 ②: **不许**拿 full/empty 做精确定量 (如"还剩几个空位") —— 它只会少报空位、
//             多报占用。要定量必须自建计数器, 且按"被接受的写 / 被弹出的读"记。
//   硬规则 ③: 上游**不得**因为 full 高就断定下游没在消费 —— 读侧时钟停摆时 full 会永久
//             保持 (这是**正确行为**, 不是死锁); 反之, 下游不得因为 empty 高就断定上游没写。
//   数据可见性延迟: 写侧被接受后, 最快 **2 个 rd_clk** 才能被读侧看见 (两级同步), 即
//     `!empty` 最早出现在写入沿之后的第 3 个 rd 沿 (被外部按"采样到 empty 变 0"数则是第 4 个沿)。
//     ⚠️ 这条延迟是**硬契约**: 单元门 case `lat` 按"写入沿之后至少 4 个 rd 沿才可能观察到
//     empty 拉低"逐实例断言 —— 少一级同步会立刻违反它 (负对照 mut_empty1 专测这条)。
//
// ---- 复位 (两侧各自独立, 但**必须一起给**) ----
//   各域一条**异步置位 / 同步释放**的复位同步器 (Cummings 标准做法); 域内所有寄存器
//   (含灰码同步链) 都用本域同步释放后的复位 ⇒ 复位**释放**不会落在本域时钟沿附近。
//   ★★ 硬契约: 两侧复位必须同时 (同源分两路, 或同一时刻断言)。
//     ① 两侧同时复位: 指针同归零 ⇒ FIFO 空, 在途数据**全部丢弃**, 无残留。两域各自同步
//        释放 ⇒ 释放时刻不同步**没关系**, 释放后两侧仍是"都归零"的一致态。
//     ② **只复位一侧 ⇒ 指针不一致 = 未定义行为 (静默脏数据)**。可预测的后果 (单元门量过):
//        · 只复位读侧: 读侧以 rbin=0 去追它看到的写指针 W ⇒ **多弹** (弹到 rbin==W 为止),
//          而真实未读只有 qcnt < W 个字 ⇒ 弹出的是旧槽残留/被覆盖过的字。
//        · 只复位写侧: 写侧以 wbin=0 去追它看到的读指针 R ⇒ **多写** (写到 wbin==R+DEPTH),
//          而真实空位只有 DEPTH-qcnt ⇒ 覆盖尚未读出的字。
//        ⇒ **单侧复位是禁止用法**, 仅供故障注入测试 (sim/fifoasync/case_reset 的判据 5/6)。
//     ③ 复位期间**另一侧时钟停摆**: 停摆侧的复位同步器不推进 ⇒ 该侧复位**保持** (异步置位
//        立即生效), 时钟恢复后才同步释放; 该侧不消费/不生产, 另一侧会正常走到 full/empty
//        边界 (正确行为, 不挂死)。⚠️ 若"停摆侧的复位"与"工作侧的复位"不是同时给的,
//        时钟恢复后就落到 ② 的脏状态。
//
// ---- 不做的事 (与 fifo_sync / frame_fifo 完全一致) ----
//   · 不做溢出/下溢保护 (见硬规则 ①) —— 调用方自己保证。
//   · **mem 不带复位** (无复位写块是 LUTRAM/BRAM 推断前提; 与 fifo_sync/frame_fifo 同)
//     ⇒ 空态 dout 可能是 X/旧值, 只在 `!empty` 时使用。
//   · 无中断/状态输出; 要观测就接 dbg_* 探针 (纯 assign 线束, 与逻辑零耦合)。
//
// ---- 实现要点 (改之前先读) ----
//   · 指针 = (AW+1) 位二进制 (wbin/rbin) + 灰码 (wgray/rgray); bin2gray = b ^ (b>>1)。
//     低 AW 位是地址, 最高位是绕回位; DEPTH = 2^AW ⇒ 满/空靠"最高位相反/相同"区分。
//   · **每个寄存器只有一个 always 块驱动它** (写域两个块: ①复位同步器 (只驱动 wr_rst_sync,
//     源 = 原始 wr_rst_n) ②写域其余全部寄存器 (源 = 同步释放后的 wr_rst_n_s); 读域对称;
//     外加一个只驱动 mem 的无复位写块)。本工程踩过"多驱动 + 位宽静默截断"的坑
//     (见 _proj_pcie/rtl/axi_regs.v 里 snap_base 的注释), 这里逐处核对:
//       - `{{AW{1'b0}}, wr_ok}` 是 AW+1 位 (加法两端等宽);
//       - `{~rgray_s2_w[AW:AW-1], rgray_s2_w[AW-2:0]}` 是 2+(AW-1) = AW+1 位
//         (**要求 AW>=2 ⇒ DEPTH>=4**, 这正是 DEPTH 下界 4 的出处);
//       - 地址是 `wbin[AW-1:0]` / `rbin[AW-1:0]` (AW 位, 天然 mod DEPTH);
//       - 同步器每级都是**整宽寄存器** (灰码总线 2FF), 不是 1 位移位链。
//   · **满判据用 `wgray_n` (含本拍待写), 不是 `wgray`**: 用当前 wgray 会让 FIFO 在"刚好满"
//     的那一拍多接受一次写 = 覆盖未读槽 (静默丢数据)。负对照 sim/fifoasync/mut/mut_full_off.v
//     就是这一行改错 —— 单元门必须抓得到它。
//   · **空判据用 `rgray_n` (含本拍待弹)**: 于是 empty 在最后一字被弹出的那一拍之后就拉高,
//     FWFT 下 `!empty` 期间 `mem[rbin]` 必定是"已写入且未被覆盖"的字 (灰码不变式:
//     rbin 永远 <= 写侧实际指针, 且 !empty ⇒ rbin < 实际写指针)。TB 里逐拍对拍 dout 即验此条。
//   · FWFT=1 的读口是**组合读** ⇒ 综合落 LUTRAM (双时钟 + 组合读口 = 只能是分布式 RAM);
//     深/宽 FIFO 用 FWFT=0 (读口是"地址寄存器 → 存储 → 输出寄存器", 可推 BRAM)。
//     ⚠️ 两种模式的综合推断结果**尚未过综合验证** (本单元只做行为级仿真)。
module fifo_async #(
    parameter WIDTH = 72,          // 数据位宽 (72 = 64 数据 + 8 keep/last)
    parameter DEPTH = 16,          // 深度: **必须是 2 的幂, 且 >= 4** (灰码满/空判据要求 AW>=2)
    parameter FWFT  = 1,           // 1 = 首字直通 (与 fifo_sync/frame_fifo 同语义); 0 = 标准 1 拍延迟
    // AW = 地址位宽 = log2(DEPTH)。**必须是 parameter**(不是 localparam): Verilog-2001 的
    //   端口表看不到 body 里的 localparam, 而 dbg_* 端口宽度要引用它 (与 frame_fifo 的
    //   SW 同一处理)。覆盖 DEPTH 时 AW 默认值会自动跟着算 (参数默认值按声明序求值);
    //   若两个都覆盖, 必须自洽 (DEPTH == 2**AW), 否则 $display 报错终止 (见下)。
    parameter AW    = $clog2(DEPTH)
)(
    // ---- 写域 ----
    input  wire             wr_clk,
    input  wire             wr_rst_n,      // 低有效; 异步置位 / 本域同步释放
    input  wire             wr_en,
    input  wire [WIDTH-1:0] din,
    output wire             full,          // 只在本域用; 悲观 (见头注释)
    // ---- 读域 ----
    input  wire             rd_clk,
    input  wire             rd_rst_n,      // 低有效; 异步置位 / 本域同步释放
    input  wire             rd_en,
    output wire [WIDTH-1:0] dout,
    output wire             empty,         // 只在本域用; 悲观 (见头注释)
    // ---- 调试探针 (纯 assign 线束, 与上述逻辑零耦合; 风格同 fifo_sync/frame_fifo) ----
    output wire [AW:0]      dbg_wbin,      // 写指针 (二进制, 含绕回位)
    output wire [AW:0]      dbg_rbin,      // 读指针 (二进制, 含绕回位)
    output wire [AW:0]      dbg_wgray,     // 写指针 (灰码) —— 跨域那一束
    output wire [AW:0]      dbg_rgray,     // 读指针 (灰码) —— 跨域那一束
    // ---- P6b 新增: 占用探针 (W27/W28 的来源) ----
    // ⚠️ 两根都必须在**本域**用**已经过 2FF 同步的**对方指针算 —— 直接拿 dbg_rgray/dbg_wgray
    //    (未同步的原始灰码总线) 做组合运算等于**多比特 CDC** (正是 snap_cdc.v 头注释警告的
    //    "位混型假值")。这里用的是 rgray_s2_w / wgray_s2_r (本域已同步的 2 级输出)。
    // 语义: **悲观** (写侧看到的占用 >= 真实占用, 读侧看到的 <= 真实占用) —— 与 full/empty
    //   同方向, 是"只少报空位、多报占用"这条既有契约的自然延伸 (见头注释硬规则②)。
    output wire [AW:0]      dbg_occ_w,     // 写域可见占用 (写侧用):  wbin_r - gray2bin(rgray_s2_w)
    output wire [AW:0]      dbg_occ_r      // 读域可见占用 (读侧用):  gray2bin(wgray_s2_r) - rbin_r
);

`ifndef SYNTHESIS
    // 参数自检: 仿真里参数非法就**响亮地死**, 而不是静默地少一块存储 (本工程"空读数 != 真 0"纪律)。
    initial begin
        if (DEPTH != (1 << AW) || DEPTH < 4 || WIDTH < 2) begin
            $display("FATAL fifo_async: 参数非法 WIDTH=%0d DEPTH=%0d AW=%0d (要求 DEPTH==2**AW, DEPTH>=4)",
                     WIDTH, DEPTH, AW);
            $finish;
        end
    end
`endif

    // ---------------- 复位同步器 (每域一条; 异步置位 / 同步释放) ----------------
    // 断言是异步的 (复位一拉低立即生效); 释放经两级同步 ⇒ 不会落在本域时钟沿附近。
    // ASYNC_REG 打在这两个 flop 上 (它们本身也是跨域位; 同 rtl/snap_cdc.v 的做法)。
    (* ASYNC_REG = "TRUE" *) reg [1:0] wr_rst_sync;
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) wr_rst_sync <= 2'b00;
        else           wr_rst_sync <= {wr_rst_sync[0], 1'b1};   // 1 位输入 ⇒ 移位式
    end
    wire wr_rst_n_s = wr_rst_sync[1];

    (* ASYNC_REG = "TRUE" *) reg [1:0] rd_rst_sync;
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) rd_rst_sync <= 2'b00;
        else           rd_rst_sync <= {rd_rst_sync[0], 1'b1};
    end
    wire rd_rst_n_s = rd_rst_sync[1];

    // ---------------- 存储 (声明提前, 见下"声明序"注) ----------------
    // ⚠️ 本工程坑 24: 引用后文声明的标识符在 xvlog 下会变成**隐式 1 位网线** (静默截断,
    //   multi/driv/unconnected 检查都不报) ⇒ 所有 reg/wire 声明集中在逻辑块之前,
    //   逻辑块之间只做引用。门里把 xvlog 的 "implicitly" 当硬失败。
    reg  [AW:0]      wbin_r, wgray_r, rbin_r, rgray_r;
    reg              full_r, empty_r;
    (* ASYNC_REG = "TRUE" *) reg [AW:0] rgray_s1_w, rgray_s2_w;   // rd 域灰码 → 写域 (两级)
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wgray_s1_r, wgray_s2_r;   // wr 域灰码 → 读域 (两级)

    // ---------------- 写域: 指针 + 满 ----------------
    wire        wr_ok   = wr_en && !full_r;
    wire [AW:0] wbin_n  = wbin_r + {{AW{1'b0}}, wr_ok};           // AW+1 位 (进位即绕回位)
    wire [AW:0] wgray_n = wbin_n ^ (wbin_n >> 1);                 // bin2gray
    // 满 ⇔ 二进制 wbin_n == 同步过来的 rbin + DEPTH; 灰码下等价于"除最高两位取反外全同"。
    // 用 wgray_n (含本拍待写) ⇒ 不会多写一个字 (见头注释; 负对照 mut_full_off 专测这条)。
    wire        full_n  = (wgray_n == {~rgray_s2_w[AW:AW-1], rgray_s2_w[AW-2:0]});

    // 本域**全部**寄存器在这一个块里 (只驱动下面列出的这几个 reg; 见头注释的驱动纪律)
    always @(posedge wr_clk or negedge wr_rst_n_s) begin
        if (!wr_rst_n_s) begin
            wbin_r     <= {(AW+1){1'b0}};
            wgray_r    <= {(AW+1){1'b0}};
            full_r     <= 1'b0;                        // 复位后不满
            rgray_s1_w <= {(AW+1){1'b0}};
            rgray_s2_w <= {(AW+1){1'b0}};
        end else begin
            wbin_r     <= wbin_n;
            wgray_r    <= wgray_n;
            full_r     <= full_n;
            rgray_s1_w <= rgray_r;                     // 第 1 级
            rgray_s2_w <= rgray_s1_w;                  // 第 2 级
        end
    end
    assign full = full_r;

    // ---------------- 读域: 指针 + 空 ----------------
    wire        rd_ok   = rd_en && !empty_r;
    wire [AW:0] rbin_n  = rbin_r + {{AW{1'b0}}, rd_ok};
    wire [AW:0] rgray_n = rbin_n ^ (rbin_n >> 1);
    // 空 ⇔ rgray_n (含本拍待弹) == 同步过来的 wgray。复位值必须是 1 (复位后为空)。
    wire        empty_n = (rgray_n == wgray_s2_r);

    always @(posedge rd_clk or negedge rd_rst_n_s) begin
        if (!rd_rst_n_s) begin
            rbin_r     <= {(AW+1){1'b0}};
            rgray_r    <= {(AW+1){1'b0}};
            empty_r    <= 1'b1;                        // 复位后为空 (**不能是 0**)
            wgray_s1_r <= {(AW+1){1'b0}};
            wgray_s2_r <= {(AW+1){1'b0}};
        end else begin
            rbin_r     <= rbin_n;
            rgray_r    <= rgray_n;
            empty_r    <= empty_n;
            wgray_s1_r <= wgray_r;                     // 第 1 级
            wgray_s2_r <= wgray_s1_r;                  // 第 2 级
        end
    end
    assign empty = empty_r;

    // ---------------- 存储 ----------------
    // 无复位写块 (与 fifo_sync/frame_fifo 同): 带异步复位的 always 里写 mem 会被综合成
    // 寄存器数组 (深 FIFO 时序炸)。地址 = 指针低 AW 位 (天然 mod DEPTH)。
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    always @(posedge wr_clk) begin
        if (wr_ok) mem[wbin_r[AW-1:0]] <= din;
    end

    // ---------------- 读口呈现 ----------------
    generate
    if (FWFT) begin : gen_fwft
        // 首字直通: 组合读当前头槽 ⇒ !empty 同拍有效 (与 fifo_sync/frame_fifo 同合同)。
        assign dout = mem[rbin_r[AW-1:0]];
    end else begin : gen_std
        // 标准模式: 弹出请求的下一拍呈现, 保持到下一次 rd_en (地址寄存器 → 存储 → 输出寄存器)
        reg [WIDTH-1:0] dout_r;
        always @(posedge rd_clk or negedge rd_rst_n_s) begin
            if (!rd_rst_n_s) dout_r <= {WIDTH{1'b0}};
            else if (rd_ok)  dout_r <= mem[rbin_r[AW-1:0]];
        end
        assign dout = dout_r;
    end
    endgenerate

    // ---------------- 调试探针 (纯线束) ----------------
    // gray2bin: 纯组合函数 (AW+1 位), 供占用探针用。**必须是 function 而不是内联循环** ——
    //   它要被两个不同域的表达式各调一次, 而 Verilog 的 for 只能写在 always/function 里。
    function [AW:0] gray2bin;
        input [AW:0] g;
        integer i;
        begin
            gray2bin[AW] = g[AW];
            for (i = AW-1; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    assign dbg_wbin  = wbin_r;
    assign dbg_rbin  = rbin_r;
    assign dbg_wgray = wgray_r;
    assign dbg_rgray = rgray_r;
    // 占用 = 本域二进制指针 − 同步过来的对方二进制指针 (灰码先转二进制)。
    // 时序上只是 1 个加法器 + AW 级异或树, 纯观测, 无扇出到功能逻辑。
    assign dbg_occ_w = wbin_r - gray2bin(rgray_s2_w);
    assign dbg_occ_r = gray2bin(wgray_s2_r) - rbin_r;
endmodule
