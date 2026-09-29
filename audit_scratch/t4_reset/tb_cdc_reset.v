`timescale 1ns/1ps
//=============================================================================
// tb_cdc_reset.v -- P6b 跨域 FIFO: 复位 / 时钟停摆 边界审计 (C11/C12)
//=============================================================================
// 四个独立实例 (同一 module, 不同接线; 各自独立 xsim 也行, 这里同跑):
//   A  WRAPPER 接线 (两侧 rst 都接 rst_n) 中途复位 -> 守恒 + 无半帧 (判据 A1/A2)
//   B  **只复位读侧** (禁止用法) -> 量"多弹/脏数据" (判据 B1/B2; 契约 §② 的可预测后果)
//   C  **复位释放窗口**: 生产者与 rst_n 同拍释放, FIFO 写域还在本域复位里
//        -> 量"full 读 0 而写被静默丢弃"的字数 (判据 C1) —— F-1
//   D  时钟停摆: 停 rd_clk 很久再恢复 -> 写侧被 full 挡住(不挂死), 恢复后逐字补齐 (D1/D2)
//=============================================================================
module cdc_reset_chk #(
    parameter MODE = 0,          // 0=A 1=B 2=C 3=D
    parameter TAGC = 0
)(
    input  wire wr_clk,
    input  wire rd_clk,
    input  wire rst_n,           // 顶层复位
    output reg  [31:0] o_model_acc,   // 我记账的 "wr_en && !full" 拍数
    output reg  [31:0] o_wbin,        // DUT 写指针终值
    output reg  [31:0] o_rbin,        // DUT 读指针终值
    output reg  [31:0] o_get,         // 收到的字数
    output reg  [31:0] o_bad,         // 数据/守恒失败计数
    output reg  [31:0] o_fullcyc,
    output reg  [31:0] o_stale         // 收到的字与期望不符的次数
);
    localparam W = 76;
    reg  [W-1:0] wd;
    reg          wv;
    wire         wready;
    wire [W-1:0] rd_;
    wire         rempty, rfull;
    reg          rr;
    wire         wr_rst_n = rst_n;              // A/B/C/D: 写侧一律由 rst_n
    // ⚠️ MODE==1: 读侧复位由外部单独控制 (rd_rst_ext) ⇒ 可做 "只复位读侧" 的故障注入
    reg          rd_rst_ext = 1'b0;   // 0 = 读侧被复位 (单侧注入用)
    wire         rd_rst_n = (MODE == 1) ? (rd_rst_ext & rst_n) : rst_n;
    // 读侧时钟可由 TB 停摆 (MODE==3)
    reg          rd_clk_en = 1'b1;
    wire         rclk = rd_clk_en ? rd_clk : 1'b0;

    fifo_async #(.WIDTH(W), .DEPTH(256), .FWFT(1), .AW(8)) u_fifo (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n), .wr_en(wv), .din(wd), .full(rfull),
        .rd_clk(rclk),  .rd_rst_n(rd_rst_n), .rd_en(rr && !rempty),
        .dout(rd_), .empty(rempty),
        .dbg_wbin(), .dbg_rbin(), .dbg_wgray(), .dbg_rgray(), .dbg_occ_w(), .dbg_occ_r()
    );
    assign wready = ~rfull;

    // ---------------- 写侧: 递增 seq, 复位窗口内也照发 (MODE==2 故意) ----------------
    reg [31:0] wseq, wacc, wref, fullcyc, dut_acc;
    reg [8:0]  wbin_r;
    reg        accd;
    wire       wbin_moved = (u_fifo.dbg_wbin !== wbin_r);
    // MODE==2: 生产者只被 rst_n 复位 (与 mac_rx_64 同), 立刻开始发
    // 其它模式: 生产者等 w_go (避开复位窗口, 便于把窗口单独测量)
    reg [3:0] wgo;
    wire      w_go = (MODE == 2) ? 1'b1 : (wgo == 4'hF);
    always @(posedge wr_clk or negedge rst_n)
        if (!rst_n) wgo <= 0; else if (!w_go) wgo <= wgo + 4'h1;

    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            wd <= 0; wv <= 0; wseq <= 0; wacc <= 0; wref <= 0; fullcyc <= 0;
            wbin_r <= 0; accd <= 0; dut_acc <= 0;
        end else begin
            if (rfull) fullcyc <= fullcyc + 32'd1;
            if (w_go && !wv) begin
                wd <= {8'hA5, 36'h012345678, wseq};     // 可辨识的 seq 数据
                wv <= 1'b1;
            end
            if (wv) begin
                if (!wready) wref <= wref + 32'd1;
                else begin
                    wacc <= wacc + 32'd1;
                    wseq <= wseq + 32'd1;
                    wd   <= {8'hA5, 36'h012345678, wseq + 32'd1};
                end
            end
            if (u_fifo.dbg_wbin !== wbin_r) dut_acc <= dut_acc + 32'd1;   // DUT 真接受写数
            wbin_r <= u_fifo.dbg_wbin;
            accd   <= (wv && !rfull);
        end
    end

    // ---------------- 读侧: 全速收 (MODE==3 时钟由 TB 停) ----------------
    reg [31:0] get, stale, last_seq, next_exp;
    reg        anyrecv;
    always @(posedge rclk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rr <= 0; get <= 0; stale <= 0; last_seq <= 0; anyrecv <= 0; next_exp <= 0;
        end else begin
            rr <= 1'b1;
            if (rr && !rempty) begin
                get <= get + 32'd1;
                // 收到字的 seq 字段 (低 32 位) 应比上一个 +1 (除非发生过复位)
                if (anyrecv && (rd_[31:0] !== (last_seq + 32'd1))) begin
                    stale <= stale + 32'd1;
                    if (stale < 32'd5)
                        $display("RST%0d STALE-EVENT t=%0t got_seq=%0d exp=%0d (回退/跳变 = 脏数据)",
                                 TAGC, $time, rd_[31:0], last_seq + 32'd1);
                end
                last_seq <= rd_[31:0];
                anyrecv  <= 1'b1;
            end
        end
    end

    // ---------------- 终判 (由 TB 顶层按相位驱动 rst 后调用) ----------------
    task fin;
        input [31:0] tag;
        begin
            o_model_acc = wacc;
            o_wbin      = dut_acc;
            o_rbin      = u_fifo.dbg_rbin;
            o_get       = get;
            o_bad       = 0;
            o_fullcyc   = fullcyc;
            o_stale     = stale;
            $display("RST%0d tag=%0d model_acc=%0d dut_acc=%0d (raw_wbin=%0d raw_rbin=%0d) get=%0d stale=%0d fullcyc=%0d wref=%0d",
                     TAGC, tag, wacc, dut_acc, u_fifo.dbg_wbin, u_fifo.dbg_rbin, get, stale, fullcyc, wref);
        end
    endtask
endmodule

module tb_cdc_reset;
    reg wr_clk = 0, rd_clk = 0, rst_n = 0;
    always #4.0 wr_clk = ~wr_clk;
    always #3.2 rd_clk = ~rd_clk;

    wire [31:0] a_acc, a_wbin, a_rbin, a_get, a_bad, a_full, a_stale;
    wire [31:0] b_acc, b_wbin, b_rbin, b_get, b_bad, b_full, b_stale;
    wire [31:0] c_acc, c_wbin, c_rbin, c_get, c_bad, c_full, c_stale;
    wire [31:0] d_acc, d_wbin, d_rbin, d_get, d_bad, d_full, d_stale;

    cdc_reset_chk #(.MODE(0), .TAGC(0)) uA (
        .wr_clk(wr_clk), .rd_clk(rd_clk), .rst_n(rst_n),
        .o_model_acc(a_acc), .o_wbin(a_wbin), .o_rbin(a_rbin), .o_get(a_get),
        .o_bad(a_bad), .o_fullcyc(a_full), .o_stale(a_stale));
    cdc_reset_chk #(.MODE(1), .TAGC(1)) uB (
        .wr_clk(wr_clk), .rd_clk(rd_clk), .rst_n(rst_n),
        .o_model_acc(b_acc), .o_wbin(b_wbin), .o_rbin(b_rbin), .o_get(b_get),
        .o_bad(b_bad), .o_fullcyc(b_full), .o_stale(b_stale));
    cdc_reset_chk #(.MODE(2), .TAGC(2)) uC (
        .wr_clk(wr_clk), .rd_clk(rd_clk), .rst_n(rst_n),
        .o_model_acc(c_acc), .o_wbin(c_wbin), .o_rbin(c_rbin), .o_get(c_get),
        .o_bad(c_bad), .o_fullcyc(c_full), .o_stale(c_stale));
    cdc_reset_chk #(.MODE(3), .TAGC(3)) uD (
        .wr_clk(wr_clk), .rd_clk(rd_clk), .rst_n(rst_n),
        .o_model_acc(d_acc), .o_wbin(d_wbin), .o_rbin(d_rbin), .o_get(d_get),
        .o_bad(d_bad), .o_fullcyc(d_full), .o_stale(d_stale));

    initial begin
        rst_n = 0;
        repeat (30) @(posedge wr_clk);
        rst_n = 1;
        uB.rd_rst_ext = 1;                 // B 实例上电时正常释放 (之后才做单侧注入)
        // ---- ① 正常运行 ----
        repeat (4000) @(posedge wr_clk);
        uA.fin(1); uB.fin(1); uC.fin(1); uD.fin(1);
        // ---- ② **只复位读侧** (禁止用法; B 实例) ----
        uB.rd_rst_ext = 0;                 // 写侧照常写, 读侧被单侧复位
        repeat (20) @(posedge rd_clk);
        uB.rd_rst_ext = 1;
        repeat (9000) @(posedge wr_clk);
        uB.fin(2);
        // ---- ③ 中途同时复位 (WRAPPER 接线; A 实例) ----
        rst_n = 0;
        repeat (40) @(posedge wr_clk);
        rst_n = 1;
        repeat (6) @(posedge wr_clk);
        uA.fin(30);                       // 双复位后 6 拍快照: 指针必须已同归零
        repeat (20000) @(posedge wr_clk);
        uA.fin(3);
        // ---- ④ 停读时钟 (MODE 3) ----
        uD.rd_clk_en = 0;
        repeat (6000) @(posedge wr_clk);
        uD.fin(4);
        uD.rd_clk_en = 1;
        repeat (20000) @(posedge wr_clk);
        uD.fin(5);
        $display("CDC_RESET SUMMARY");
        $display("  A(wrapper both-rst): mid-reset 前后 model_acc=%0d dut_wbin=%0d get=%0d stale=%0d", a_acc, a_wbin, a_get, a_stale);
        $display("  B(rd-side-only-rst): get=%0d stale=%0d (契约: 多弹/脏数据)", b_get, b_stale);
        if (b_stale > 0) $display("RESET **B-CONFIRMED**: 只复位读侧 => %0d 次脏数据读 (got 计数=%0d > 真实在飞)", b_stale, b_get);
        $display("  C(release-window)  : model_acc=%0d dut_wbin=%0d  => 静默丢 %0d 字", c_acc, c_wbin, c_acc - c_wbin);
        $display("  D(clk-stop)        : fullcyc=%0d get=%0d stale=%0d wbin=%0d", d_full, d_get, d_stale, d_wbin);
        if ((c_acc > c_wbin) && ((c_acc - c_wbin) >= 1))
            $display("RESET **F-1-CONFIRMED**: 复位释放窗口内 %0d 个字被静默丢弃 (full 读 0)", c_acc - c_wbin);
        else
            $display("RESET NO-F-1-EVIDENCE: model_acc=%0d dut_wbin=%0d", c_acc, c_wbin);
        if (b_get > b_wbin)
            $display("RESET **B-CONFIRMED**: 只复位读侧 => get=%0d > 已写入 %0d (多弹 %0d 字, 全是旧槽残留)", b_get, b_wbin, b_get - b_wbin);
        else
            $display("RESET B: get=%0d wbin=%0d (未观察到多弹)", b_get, b_wbin);
        $display("RESET DONE");
        $finish;
    end
    initial begin
        #3000000;
        $display("RESET: TIMEOUT");
        $finish;
    end
endmodule
