`timescale 1ns/1ps
//=============================================================================
// tb_p5_status: app_status_uart 单元 TB (P5a Step 6)
//
// P5 全链 TB 只跑 ~10ms 仿真, 9600 波特下连一行 (142ms) 都发不完 => app_status_uart
// 在全链门里未被真正驱动。本单元 TB 用缩短的 BIT_LAST (位周期 14 拍) + GAP_TICKS
// 跑完整行, 并把 txd 逐位解码成 ASCII 落盘 (status_line.txt) 供 Python 比对
// (期望串由 tb 打印, 判据在 gen_stim_p5_app.py checkstatus)。
//
// 采样: 检测 start 沿后, 在位中点 (1.5 位周期) 采 d0..d7, 再等 1 位周期查 stop=1。
//=============================================================================
module tb_p5_status;
    localparam integer BIT_LAST  = 13;          // 位周期 14 拍 (仿真加速)
    localparam integer GAP_TICKS = 100;

    reg clk, rst_n;
    reg [3:0]  st0;
    reg [31:0] snd_nxt, snd_una, rcv_nxt;
    reg [15:0] rcv_wnd;
    reg [31:0] stat_rx_bytes, stat_tx_bytes;
    reg [15:0] stat_tx_frames, stat_mismatch, ev_cnt, ev_drop, app_tx_ready,
               estab_cnt;
    reg [15:0] stat_drop_len, stat_fin, stat_rst;
    // P5b C9 追加字段源
    reg [15:0] stat_ack, stat_ack_drop, winq0, wu_mark0, stat_wu, stat_px;
    reg [2:0]  fsm_state;
    reg [16:0] pool;
    reg [16:0] rx_occ;
    wire txd;

    integer fd;
    integer ci;
    reg [7:0] dbyte;
    integer bi;
    integer nchar;

    app_status_uart #(.BIT_LAST(BIT_LAST), .GAP_TICKS(GAP_TICKS)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .st0(st0), .snd_nxt(snd_nxt), .snd_una(snd_una), .rcv_wnd(rcv_wnd),
        .rcv_nxt(rcv_nxt),
        .stat_rx_bytes(stat_rx_bytes), .stat_tx_bytes(stat_tx_bytes),
        .stat_tx_frames(stat_tx_frames), .stat_mismatch(stat_mismatch),
        .rx_occ(rx_occ), .ev_cnt(ev_cnt), .ev_drop(ev_drop),
        .app_tx_ready(app_tx_ready), .estab_cnt(estab_cnt),
        .stat_drop_len(stat_drop_len), .stat_fin(stat_fin), .stat_rst(stat_rst),
        // P5b C9: 流控观测字段
        .stat_ack(stat_ack), .stat_ack_drop(stat_ack_drop), .fsm_state(fsm_state),
        .winq0(winq0), .wu_mark0(wu_mark0), .stat_wu(stat_wu), .pool(pool),
        .stat_pool_exh(stat_px),
        .txd(txd)
    );

    always #4 clk = ~clk;      // 125MHz

    // 收一个字节: 进入时 start 沿刚发生 (txd 已低)。字符周期必须恰 10*(BIT_LAST+1)
    // 拍 — 每字符少算 1 拍会累积漂移, 几字符后整体错一位 (实测)。
    task get_byte;
        output [7:0] b;
        integer k;
        begin
            // 等 1.5 位周期到 d0 中点 (+21)
            repeat (BIT_LAST+1 + (BIT_LAST+1)/2) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = txd;
                repeat (BIT_LAST+1) @(posedge clk);      // 14
            end
            // 此刻 +133 (stop 位区间 [126,140) 内): 查 stop=1
            if (txd !== 1'b1)
                $display("STATFAIL stop bit low at char %0d", nchar);
            // 字节间相位由主循环的 @(negedge txd) 重新对齐 (不靠周期数累加)
        end
    endtask

    // DUT 侧发射字符计数 + 每字符 ci (定位多/少字符)
    integer sent;
    always @(posedge clk) begin
        if (!rst_n) sent <= 0;
        else if (u_dut.uart_go) begin
            sent <= sent + 1;
            if (sent >= 130) $display("STATCH ci=%0d lc=%02h", u_dut.ci, u_dut.lc);
        end
    end

    integer j;
    initial begin
        clk = 0; rst_n = 0; nchar = 0;
        st0 = 4'h1;
        snd_nxt = 32'h12345679; snd_una = 32'h12345678; rcv_nxt = 32'h20000065;
        rcv_wnd = 16'hC000;
        stat_rx_bytes = 32'h00001234; stat_tx_bytes = 32'h0056789A;
        stat_tx_frames = 16'h0123; stat_mismatch = 16'h0007;
        rx_occ = 17'h1ABCD; ev_cnt = 16'h0003; ev_drop = 16'h0001;
        app_tx_ready = 16'h8001; estab_cnt = 16'h0002;
        stat_drop_len = 16'h0003; stat_fin = 16'h0001; stat_rst = 16'h0000;
        // P5b C9 字段: 取可辨识值 (每个字段一个不同的 hex 图案, 便于错位定位)
        stat_ack = 16'hBEEF; stat_ack_drop = 16'h00CD; fsm_state = 3'd5;
        winq0 = 16'hC000; wu_mark0 = 16'h6035; stat_wu = 16'h0011;
        pool = 17'h1C0DE; stat_px = 16'h0009;
        fd = $fopen("status_line.txt", "wb");   // 二进制: 文本模式会把 0x0A 写成 0x0D0A
        #200; rst_n = 1;
        // 等首行开始 (txd 空闲高 -> start 沿)
        @(negedge txd);
        // P5b: 行 168 -> 220 字符, 读循环上界跟着放宽 (原 200 会截尾)
        for (ci = 0; ci < 240; ci = ci + 1) begin
            get_byte(dbyte);
            nchar = nchar + 1;
            $fwrite(fd, "%c", dbyte);
            if (dbyte == 8'h0A) ci = 240;      // LF: 行结束 (上界一致)
            else @(negedge txd);               // 下一字符 start 沿 (逐字符重对齐)
        end
        $fclose(fd);
        $display("STATLEN %0d", nchar);
        $display("STAT TB DONE");
        $finish;
    end
endmodule
