`timescale 1ns/1ps
//=============================================================================
// tb_biz_win.v — P7B-BIZ 快照窗口的**逐字读回**门 (axi_regs @ SNAP_NW=70; 构建 F 起;
//
// 为什么必须有它 (本工程两次踩过的同一类错, 见 wrapper_p4.v 的扩窗注释):
//   快照装配/读侧译码错一处, **不会读出垃圾, 只会读出"另一个字的正确值"** ——
//   单测一个地址看不出来, lint 也全程沉默 (xvlog 不检查端口连接的位宽)。
//   ⇒ 唯一的抓法是: **给每个字一个互不相同的常数, 再逐字核对"地址 ↔ 值"一一对应**。
//      本门 57 个字全用 `32'hB17B_0000 + i` ⇒ 任何错位/回绕/截断都会立刻显形。
//
// 覆盖的失配模式 (每一条都是本工程真实踩过的):
//   ① 读侧 `snap_base` 位宽不够 ⇒ 高地址字**回绕**读回低地址字 (NW=24/32/36 时代各一次)
//   ② 读侧下标写成 `r_word[k:0]` 截断 ⇒ 同上, 且 0x20 也串位
//   ③ `SNAP_LAST_IDX` 边界错 ⇒ 末字读不到 / 未实现地址读到数据
//   ④ 6 位 `ar_word` 时代: `0x100` 别名回 word 0 = MAGIC ⇒ 判据假 FAIL;
//      写 `0x108` 别名到 SCRATCH ⇒ **一次误写就改掉 TX_DIS 门** (本轮加宽译码时一并修掉)
//   ⑤ 拼接项数 ≠ SNAP_NW ⇒ 高位悬空 (X) 或被静默截断 (本门看不见装配; 由
//      `check_window.py` 的静态项数核对 + 合体构建的 xelab/synth 那两面覆盖)
//
// 边界声明 (honest scope): 本门例化的是**寄存器块 (axi_regs)**, 不是真 wrapper ——
//   wrapper 的 `snap_dout_all` 装配是**纯文本映射**, 由 `check_window.py` 静态核对
//   (项数/槽号/旧字不移位) + 合体构建的 xelab/synth 核对。本门管的是"地址 ↔ 字"这一半。
//=============================================================================
module tb_biz_win;

    localparam integer NW = 70;  // = wrapper 的 SNAP_NW_P6E (构建 F, 2026-10-10; 原 61/63/65/66/67)

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg  [2:0]  awprot = 0, arprot = 0;
    reg  [3:0]  wstrb = 4'hF;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;

    reg  [31:0] hw_status = 32'h0000_0005;
    wire [31:0] scratch, wr_count;
    wire        decode_err;

    wire        snap_req;
    reg         snap_busy  = 0;
    reg         snap_valid = 0;
    reg  [NW*32-1:0] snap_din = 0;
    reg  [2:0]  fe_state   = 3'b101;      // → SNAP_STATUS[5:3]
    reg         locked_axi = 1'b1;        // → SNAP_STATUS[6]

    axi_regs #(.MAGIC_V(32'h50360001), .BUILD_ID_V(32'h00000008), .SNAP_NW(NW)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(awaddr), .s_axil_awprot(awprot), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arprot(arprot), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .hw_status(hw_status), .scratch(scratch), .wr_count(wr_count), .decode_err(decode_err),
        .snap_req(snap_req), .snap_busy(snap_busy), .snap_valid(snap_valid), .snap_din(snap_din),
        .fe_state(fe_state), .locked_axi(locked_axi)
    );

    integer fails = 0, npass = 0;
    // ⚠️ 被 task 引用的模块级变量必须声明在 task **之前** (工程坑 22: xvlog 先声明后用)
    reg [31:0] v, v2;
    reg [1:0]  resp;
    integer    i;
    reg [31:0] wrd [0:NW-1];

    task chk(input [255:0] name, input [31:0] got, input [31:0] exp);
        begin
            if (got === exp) begin $display("  [PASS] %0s = %08x", name, got); npass = npass + 1; end
            else begin $display("  [FAIL] %0s = %08x (期望 %08x)", name, got, exp); fails = fails + 1; end
        end
    endtask

    task chkresp(input [255:0] name, input [1:0] got, input [1:0] exp);
        begin
            if (got === exp) begin $display("  [PASS] %0s rresp=%b", name, got); npass = npass + 1; end
            else begin $display("  [FAIL] %0s rresp=%b (期望 %b)", name, got, exp); fails = fails + 1; end
        end
    endtask

    task axil_wr(input [31:0] a, input [31:0] d, input [3:0] strb_in, output [1:0] resp_o);
        begin
            @(negedge clk);
            awaddr = a; awvalid = 1'b1; wdata = d; wstrb = strb_in; wvalid = 1'b1; bready = 1'b1;
            @(posedge clk);
            while (!(awready && wready)) @(posedge clk);
            @(negedge clk);
            awvalid = 1'b0; wvalid = 1'b0;
            while (!bvalid) @(posedge clk);
            @(negedge clk);
            resp_o = bresp;
            bready = 1'b0;
            @(posedge clk);
        end
    endtask

    task axil_rd(input [31:0] a, output [31:0] d_o, output [1:0] resp_o);
        begin
            @(negedge clk);
            araddr = a; arvalid = 1'b1; rready = 1'b1;
            @(posedge clk);
            while (!arready) @(posedge clk);
            @(negedge clk);
            arvalid = 1'b0;
            while (!rvalid) @(posedge clk);
            d_o = rdata; resp_o = rresp;
            @(negedge clk);
            rready = 1'b0;
            @(posedge clk);
        end
    endtask

    // 每个字一个**互不相同**的常数: 高半字是"人眼可辨的标记", 低半字是**字号本身**。
    //   ⇒ 读出 `B17B_0038` 就说明"地址 0x20+4*56 映射到了字 56" (一一对应可直接判)。
    function [31:0] code_of(input integer idx);
        begin
            code_of = 32'hB17B_0000 + idx[31:0];
        end
    endfunction

    // ⚠️ Verilog (非 SV) 的函数**至少要有一个输入** ⇒ 给个哑参数 (VRFC 10-8982)
    function [NW*32-1:0] make_bundle(input integer dummy);
        integer k;
        reg [NW*32-1:0] b;
        begin
            b = {NW*32{1'b0}};
            for (k = 0; k < NW; k = k + 1) b[k*32 +: 32] = code_of(k);
            make_bundle = b;
        end
    endfunction

    initial begin
        $display("=== tb_biz_win: P7B-BIZ 快照窗口逐字读回门 (SNAP_NW=%0d) ===", NW);
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        // ---- 判据 1: 身份 (前置闸读的那两项) ----
        axil_rd(32'h00, v, resp); chk("1a MAGIC", v, 32'h50360001);
        axil_rd(32'h04, v, resp); chk("1b BUILD_ID", v, 32'h00000008);
        axil_rd(32'h14, v, resp); chk("1c MARKER (地址译码)", v, 32'hDEADBEEF);

        // ---- 判据 2: 触发 + 注入一束**逐字唯一**的数据 ----
        snap_din = make_bundle(0);
        @(negedge clk); snap_valid = 1'b1; @(negedge clk); snap_valid = 1'b0;
        axil_rd(32'h1C, v, resp);
        chk("2a gen 恰好 = 1", {16'd0, v[31:16]}, 32'h0000_0001);
        chk("2b done 置起",     {31'd0, v[1]},     32'd1);
        chk("2c [15:7] 零填充区", v[15:7],         9'd0);

        // ---- 判据 3 (⭐本体): 57 个字**逐字**读回, 地址 ↔ 值一一对应 ----
        //   任何一个字错位/回绕/截断, 都会在这里变成"读到了**另一个字**的正确值" ⇒ 立刻红。
        for (i = 0; i < NW; i = i + 1) begin
            axil_rd(32'h20 + i*4, wrd[i], resp);
            if (wrd[i] !== code_of(i)) begin
                $display("  [FAIL] 3 W%0d @%08x = %08x (期望 %08x)  ← 槽位错位/回绕",
                         i, 32'h20 + i*4, wrd[i], code_of(i));
                fails = fails + 1;
            end
        end
        if (fails == 0) begin
            $display("  [PASS] 3 W0..W%0d 共 %0d 字逐字一一对应 (无错位/无回绕)", NW-1, NW);
            npass = npass + 1;
        end

        // ---- 判据 4: 相邻字**互不相同** (证明判据 3 不是"全同值"的假门) ----
        v = 32'd0;
        for (i = 1; i < NW; i = i + 1) if (wrd[i] === wrd[i-1]) v = v + 32'd1;
        chk("4 相邻字重复数 (必须 0 ⇒ 判据 3 有牙)", v, 32'd0);

        // ---- 判据 5: 末字**恰好**是最后一个已实现字 (边界一侧) ----
        axil_rd(32'h20 + (NW-1)*4, v, resp);
        chk("5a 末字 (0x20+4*(NW-1) = 0x134 @NW=70) 读得到", v, code_of(NW-1));
        chkresp("5b 末字 rresp = OKAY", resp, 2'b00);

        // ---- 判据 6 (⭐): 下一个地址**恰好**未实现 (边界另一侧) ----
        //   两侧都判 ⇒ "边界差 1" 这种错必被抓 (只判一侧的话, 边界整体平移会漏)。
        axil_rd(32'h20 + NW*4, v, resp);
        chk("6a 未实现地址 (0x20+4*NW = 0x138 @NW=70) 回 0", v, 32'h0000_0000);
        chkresp("6b 未实现地址 rresp = SLVERR", resp, 2'b10);

        // ---- 判据 7: **回绕红线的实测位置** (本轮把译码 6 位 → 7 位的直接后果) ----
        //   ⚠️ 本判据第一版把期望写错了 (我原以为 0x200 会 SLVERR) —— **门当场抓住**:
        //      `ar_word = araddr[8:2]` 只有 7 位 ⇒ 地址每 **512** 字节回绕 ⇒ `0x200` 恰好
        //      别名回 **word 0 = MAGIC**。这正是本次改宽译码后**红线的新位置**:
        //        · 旧 (6 位): 禁区 = 0x100 起 (0xEC 是 51 字时代的边界);
        //        · 新 (7 位): 禁区 = **0x200 起**, 可用域 = 0x104..0x1FC。
        //      ⇒ 所以"未实现地址 = 0x20 + 4*NW" 这条公式对 NW ≤ 119 成立; 挑 0x200 会
        //        读出 MAGIC (≠0xffffffff) ⇒ 判据**假 FAIL** (与旧时代挑 0x100 同款)。
        //      把这条**实测**下来, 是为了让下一个人不必再推一遍位宽。
        axil_rd(32'h200, v, resp);
        chkresp("7a 0x200 rresp = OKAY (回绕别名是真实的)", resp, 2'b00);
        chk("7b 0x200 别名回 word 0 = MAGIC (⇒ 禁区红线在 0x200)", v, 32'h50360001);
        // 对照: 边界内最后一格 0x1FC (= 0x20+4*119) 仍是**未实现** (SLVERR) ⇒ 可用域到 0x1FC
        axil_rd(32'h1FC, v, resp);
        chkresp("7c 0x1FC (= 0x20+4*119) 仍未实现 ⇒ NW 上限 119 成立", resp, 2'b10);

        // ---- 判据 8 (⭐ 修掉的既存隐患): 写 0x108 **不许**命中 SCRATCH ----
        //   旧 6 位译码 (`awaddr_r[7:2]`) 下 0x108 → word 2 = SCRATCH ⇒ 一次误写就改掉
        //   TX_DIS 门 (scratch 的 bit0/1)。加宽到 7 位后必须是 SLVERR 且 SCRATCH 不变。
        axil_wr(32'h08, 32'hA5A5_1234, 4'hF, resp);
        axil_rd(32'h08, v, resp); chk("8a 先写 SCRATCH (基准)", v, 32'hA5A5_1234);
        axil_wr(32'h108, 32'hDEAD_0000, 4'hF, resp);
        chkresp("8b 写 0x108 = SLVERR (不是 SCRATCH)", resp, 2'b10);
        axil_rd(32'h08, v, resp); chk("8c SCRATCH 未被 0x108 改到", v, 32'hA5A5_1234);

        // ---- 判据 9: 窗口外**高**地址也不许别名 (写 0x118 不能触发快照) ----
        //   旧译码下 0x118 → word 6 = SNAP_CTRL ⇒ 误写会触发快照 (污染 gen 自证)。
        axil_rd(32'h1C, v, resp); v2 = {16'd0, v[31:16]};      // 当前 gen
        chk("9a 前置: done 已置起", {31'd0, v[1]}, 32'd1);
        axil_wr(32'h118, 32'h1, 4'hF, resp);
        chkresp("9b 写 0x118 = SLVERR", resp, 2'b10);
        axil_rd(32'h1C, v, resp);
        chk("9c gen 未被 0x118 动过", {16'd0, v[31:16]}, v2);
        chk("9d done 未被 0x118 清掉 (⇒ 它没命中 SNAP_CTRL)", {31'd0, v[1]}, 32'd1);
        // 正对照: 真正的触发地址**确实会**清 done (不然 9c/9d 可能是"触发根本没用"的假通过)
        //   ⚠️ gen 只在 `snap_valid` (CDC 回程脉冲) 时才自增 —— 写 0x18 只清 done + 发请求,
        //      所以"gen 在写 0x18 后立刻 +1"这个期望是**错的** (本门第一版就是这么写错的,
        //      当场被自己的正对照抓住)。正对照取 done 位, 再补一次注入看 gen+1。
        axil_wr(32'h18, 32'h1, 4'hF, resp);
        axil_rd(32'h1C, v, resp);
        chk("9e 正对照: 写 0x18 清掉了 done", {31'd0, v[1]}, 32'd0);
        chk("9f 正对照: gen 不受写 0x18 影响 (只等 snap_valid)", {16'd0, v[31:16]}, v2);
        @(negedge clk); snap_valid = 1'b1; @(negedge clk); snap_valid = 1'b0;
        axil_rd(32'h1C, v, resp);
        chk("9g 再来一次 snap_valid ⇒ gen 恰好 +1", {16'd0, v[31:16]}, v2 + 32'd1);

        // ---- 判据 10: 未触发 ⇒ 窗口冻结 (不自动刷新) ----
        axil_rd(32'h20 + 5*4, v, resp); axil_rd(32'h20 + 5*4, v2, resp);
        chk("10 两次读同一字相同 (窗口冻结)", v2, v);

        $display("----------------------------------------------------------");
        if (fails == 0) $display("PASS_ALL  tb_biz_win: %0d 项判据全过 (窗口 %0d 字)", npass, NW);
        else            $display("FAIL      tb_biz_win: %0d 项失败", fails);
        $finish;
    end

endmodule
