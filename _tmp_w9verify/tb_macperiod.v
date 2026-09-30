`timescale 1ns/1ps
//=============================================================================
// tb_macperiod.v  —— 对抗复核 P7B_W9_GAP 用: mac_tx_10g 的**帧周期 (XGMII 拍/帧)**
//-----------------------------------------------------------------------------
// 目的 (与 app / 帧器完全独立的一条路径):
//   板级 W43/W20 = 192.000;  W43 = mac_tx_10g.stat_tx_words, 其自增在
//   always 里**无条件** (mac_tx_10g.v:330) —— 而 XGMII 每拍必发一个字 (空闲发 /I/)
//   ⇒ W43/W20 = 平均"帧周期(拍)"。本 TB 直接给 mac_tx_10g 喂**已知内容长度 C**
//   的连续帧流 (C = s_axis 入口字节 = 14+20+8+payload), 数出每帧拍数。
//   ⇒ 回答: 192 拍/帧 对应线上内容 1510B 还是 1518B?
// 用法: xsim ... -testplusarg "C=1506,1514,..."  (逗号分隔的 C 列表, 逐帧轮转)
//       每个 C 各跑 -testplusarg "NF=" 帧
// 读数: MACPERIOD RESULT C=<c> cyc/frame=<拍> ctrl/frame=<控制字符数>
//       对照板级: 192.000 拍/帧  &  19.000 控制字符/帧
//=============================================================================
module tb_macperiod;

    reg clk = 1'b0, rst_n = 1'b0;
    always #3.2 clk = ~clk;              // 6.4 ns = 156.25 MHz

    integer NF = 40;                     // 每个 C 的帧数
    integer clist [0:31];
    integer nlist = 0;
    integer k;

    reg [8*64-1:0] clist_str;            // "1506,1514,..."

    initial begin
        if (!$value$plusargs("NF=%d", NF)) NF = 20;
        // C 列表**写死在 TB 里** (xsim 的 -testplusarg 会按逗号切分, 不能传列表)
        clist[0]=1500; clist[1]=1502; clist[2]=1504; clist[3]=1506; clist[4]=1508;
        clist[5]=1510; clist[6]=1512; clist[7]=1514; clist[8]=1516; clist[9]=1518;
        clist[10]=1520; clist[11]=1511; clist[12]=1513; clist[13]=1507; clist[14]=1505;
        nlist = 15;
        $display("MACPERIOD cfg nlist=%0d NF=%0d", nlist, NF);
        for (k = 0; k < nlist; k = k + 1) $display("MACPERIOD   list[%0d]=%0d", k, clist[k]);
    end

    // ---- 源: 帧号 fr, 帧内字下标 wi; 帧长 C = clist[fr % nlist] ----
    integer fr = 0;
    integer wi = 0;
    wire [11:0] Cw    = clist[fr % nlist];
    wire [11:0] nw_w  = (Cw + 7) / 8;
    wire [11:0] rem_w = Cw - (nw_w - 1) * 8;
    wire [3:0]  wlen  = (wi == nw_w - 1) ? rem_w[3:0] : 4'd8;
    wire [63:0] wdata = {8'hA0 + wi[7:0], 8'hA1, 8'hA2, 8'hA3, 8'hA4, 8'hA5, 8'hA6, 8'hA7};
    wire [7:0]  wkeep = (wlen == 4'd8) ? 8'hFF : (8'hFF << (4'd8 - wlen));

    reg [63:0] s_tdata; reg [7:0] s_tkeep; reg s_tvalid, s_tlast;
    always @* begin
        s_tdata  = wdata;
        s_tkeep  = wkeep;
        s_tlast  = (wi == nw_w - 1);
        s_tvalid = (fr < NF * nlist);
    end

    wire s_tready;
    wire [63:0] xd; wire [7:0] xc;
    wire [31:0] stat_frames, stat_abort, stat_flush_words, stat_flush_done;
    wire [31:0] stat_tx_words, stat_tx_ctrl_char, stat_tx_short;
    wire [15:0] dbg_clen; wire [1:0] dbg_state;

    mac_tx_10g u_mac (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .xgmii_txd(xd), .xgmii_txc(xc),
        .stat_frames(stat_frames), .stat_abort(stat_abort),
        .stat_flush_words(stat_flush_words), .stat_flush_done(stat_flush_done),
        .stat_tx_words(stat_tx_words), .stat_tx_ctrl_char(stat_tx_ctrl_char),
        .stat_tx_short(stat_tx_short),
        .dbg_tx_last_clen(dbg_clen), .dbg_tx_state(dbg_state)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fr <= 0; wi <= 0; end
        else if (s_tvalid && s_tready) begin
            if (wi == nw_w - 1) begin wi <= 0; fr <= fr + 1; end
            else wi <= wi + 1;
        end
    end

    // ---- 逐帧测量: 第 b 个帧边界 (b 从 0 起) 结束的是帧号 b, 其 C = clist[b % nlist] ----
    reg [31:0] pf;
    integer cyc;
    integer sum_cyc  [0:31];
    integer n_cyc    [0:31];
    integer sum_ctrl [0:31];
    integer pc;
    integer bcnt;                      // 已完成帧数 (= 边界数)
    integer i2, j2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pf <= 0; cyc <= 0; pc <= 0; bcnt <= 0;
            for (i2 = 0; i2 < 32; i2 = i2 + 1) begin
                sum_cyc[i2] <= 0; n_cyc[i2] <= 0; sum_ctrl[i2] <= 0;
            end
        end else begin
            cyc <= cyc + 1;
            if (stat_frames != pf) begin
                if (bcnt > 0) begin       // 跳过启动瞬态
                    j2 = bcnt % nlist;   // 边界 bcnt 结束的正是帧号 bcnt
                    sum_cyc[j2]  <= sum_cyc[j2] + cyc + 1;
                    n_cyc[j2]    <= n_cyc[j2] + 1;
                    sum_ctrl[j2] <= sum_ctrl[j2] + (stat_tx_ctrl_char - pc);
                end
                cyc <= 0;
                bcnt <= bcnt + 1;
                pf <= stat_frames;
                pc <= stat_tx_ctrl_char;
            end
            if (bcnt >= NF * nlist) begin
                for (j2 = 0; j2 < nlist; j2 = j2 + 1)
                    $display("MACPERIOD RESULT C=%0d n=%0d cyc/frame=%0d.%04d ctrl/frame=%0d.%04d",
                        clist[j2], n_cyc[j2],
                        sum_cyc[j2]/n_cyc[j2], ((sum_cyc[j2]*10000)/n_cyc[j2])%10000,
                        sum_ctrl[j2]/n_cyc[j2], ((sum_ctrl[j2]*10000)/n_cyc[j2])%10000);
                $display("MACPERIOD DONE abort=%0d short=%0d", stat_abort, stat_tx_short);
                $finish;
            end
        end
    end

    initial begin
        #64 rst_n = 1'b1;
        #200000000 $display("MACPERIOD TIMEOUT frames=%0d", stat_frames);
        $finish;
    end
endmodule
