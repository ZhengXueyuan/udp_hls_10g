`timescale 1ns/1ps
// tb_vlan_strip — vlan_strip 单元门 (fast path 单层 VLAN 剥离 shim)。
//
// 参考真值 = 字节级模型 (与 RTL 字拼接解耦): 激励按字节数组 (左对齐字流约定
// tdata[63:56] = 帧首字节) 打包成输入字流; 期望输出 = 同一字节数组删掉 byte
// 12..15 (VLAN 帧) 后再打包。逐字比对 tdata/tkeep/tlast/tuser/tcrs/terr。
//
// 三段相位 (激励全部在复位释放前生成完 — 生成/消费并发写数组会造成
// "空槽误跳"竞争, 见 P0 教训):
//   0 NOSTALL: 黄金帧 + 确定性帧表 (60..72B 边界 + 背靠背 VLAN/非 VLAN 交替),
//              m_axis_tready 恒 1
//   1 STALL  : 同帧表, m_axis_tready 随机抖动
//   2 RAND   : 随机帧长 (60..220) + 随机 VLAN + 随机 tready
// 相位边界 = 期望输出字数 (ph0_no/ph1_no), tready 模型与相位号均按 oidx 判定。
//
// 覆盖: 非 VLAN 直通逐字全等 / VLAN 剥离逐字全等 (0x8100 与 0x88A8) /
//   尾字边界 keep 0xF0 (60B) 与低半字非 0 (61..67B) / tlast 前移字 /
//   tuser/tcrs/terr 侧带跟随 / 背靠背 VLAN+非 VLAN 零间隙 / tready 抖动不丢字 /
//   TPID 相似但不命中 (0x8101/0x88A9) 直通 / 黄金矢量 (64B VLAN 帧字节 j = j,
//   前 3 输出字硬编码比对) / stat_stripped 计数与 dbg_vlan 落零。
module tb_vlan_strip;
    reg clk, rst_n;

    // 输入侧 (TB 驱动)
    reg  [63:0] s_tdata;
    reg  [7:0]  s_tkeep;
    reg         s_tvalid;
    wire        s_tready;
    reg         s_tlast, s_tuser, s_tcrs, s_terr;
    // 输出侧 (TB 消费)
    wire [63:0] m_tdata;
    wire [7:0]  m_tkeep;
    wire        m_tvalid;
    reg         m_tready;
    wire        m_tlast, m_tuser, m_tcrs, m_terr;
    wire [31:0] stat_stripped;
    wire        dbg_vlan;

    // 激励/期望字流
    reg [63:0] iw [0:16383];
    reg [7:0]  ik [0:16383];
    reg        il [0:16383], iu [0:16383], ic [0:16383], ie [0:16383];
    reg        iv [0:16383];      // 该槽位是否驱动 tvalid (0 = 空闲拍)
    integer ni;
    reg [63:0] ew [0:16383];
    reg [7:0]  ek [0:16383];
    reg        el [0:16383], eu [0:16383], ec [0:16383], ee [0:16383];
    integer no;

    integer idx, oidx;
    integer nerr;
    integer vlan_frames;          // 期望剥离帧数 (与 stat_stripped 对账)
    integer golden_oidx;          // 黄金帧首输出字下标 (-1 = 未用)
    integer ph0_no, ph1_no;       // 相位 0/1 末的期望输出字数
    integer si, t;
    reg [31:0] pcnt;

    vlan_strip u_dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .m_axis_tcrs(m_tcrs), .m_axis_terr(m_terr),
        .stat_stripped(stat_stripped), .dbg_vlan(dbg_vlan)
    );

    always #4 clk = ~clk;   // 125 MHz

    // ---- 输入驱动 (组合 valid; 握手拍或空闲槽推进) ----
    always @(*) begin
        s_tvalid = (idx < ni) && iv[idx];
        s_tdata  = iw[idx];
        s_tkeep  = ik[idx];
        s_tlast  = il[idx];
        s_tuser  = iu[idx];
        s_tcrs   = ic[idx];
        s_terr   = ie[idx];
    end

    always @(posedge clk) begin
        if (rst_n && idx < ni && (!s_tvalid || s_tready)) idx <= idx + 1;
    end

    // ---- 输出比对 (握手拍读拍前值, 与 DUT 采样同拍一致) ----
    // 相位号 (仅报告用): 由 oidx 阈值判定, 与 tready 同源
    integer ph;
    always @(*) ph = (oidx >= ph1_no) ? 2 : ((oidx >= ph0_no) ? 1 : 0);

    always @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            if (oidx >= no) begin
                $display("ERR[ph%0d] unexpected extra output word #%0d data=%016h keep=%02h",
                         ph, oidx, m_tdata, m_tkeep);
                nerr = nerr + 1;
            end else begin
                if (m_tdata !== ew[oidx] || m_tkeep !== ek[oidx] ||
                    m_tlast !== el[oidx] || m_tuser !== eu[oidx] ||
                    m_tcrs !== ec[oidx] || m_terr !== ee[oidx]) begin
                    $display("ERR[ph%0d] out#%0d got d=%016h k=%02h l=%b u=%b c=%b e=%b | exp d=%016h k=%02h l=%b u=%b c=%b e=%b",
                             ph, oidx, m_tdata, m_tkeep, m_tlast, m_tuser,
                             m_tcrs, m_terr, ew[oidx], ek[oidx], el[oidx],
                             eu[oidx], ec[oidx], ee[oidx]);
                    nerr = nerr + 1;
                end
            end
            // 黄金矢量: 64B VLAN 帧 (字节 j = j) 前 3 输出字硬编码
            if (golden_oidx >= 0) begin
                if (oidx == golden_oidx && m_tdata !== 64'h0001020304050607)
                    begin nerr = nerr + 1;
                        $display("ERR[ph%0d] golden w0 %016h != 0001020304050607",
                                 ph, m_tdata); end
                if (oidx == golden_oidx + 1 && m_tdata !== 64'h08090A0B10111213)
                    begin nerr = nerr + 1;
                        $display("ERR[ph%0d] golden w1 %016h != 08090A0B10111213",
                                 ph, m_tdata); end
                if (oidx == golden_oidx + 2 && m_tdata !== 64'h1415161718191A1B)
                    begin nerr = nerr + 1;
                        $display("ERR[ph%0d] golden w2 %016h != 1415161718191A1B",
                                 ph, m_tdata); end
            end
            oidx <= oidx + 1;
        end
    end

    // ---- 下游 tready 模型: 相位 0 恒 1; 相位 1/2 随机抖动 ----
    wire stall_en = rst_n && (oidx >= ph0_no);
    always @(posedge clk) begin
        if (!rst_n) m_tready <= 1'b0;
        else if (!stall_en) m_tready <= 1'b1;
        else if ((($random % 4) == 0) || (($random % 9) == 0)) m_tready <= 1'b0;
        else m_tready <= 1'b1;
    end

    // ================= 帧打包 =================
    reg [7:0] fb [0:255];      // 工作帧字节 (含 tag)
    reg [7:0] gb [0:255];      // 期望帧字节 (去 tag)

    // 字节数组 -> 激励字流 (SOP/tlast/crs/err 侧带: tcrs/terr 仅末拍)
    task pack_in;
        input integer n;
        input integer last_terr;   // 本帧 tlast 拍 terr
        integer w, k, cnt;
        reg [63:0] word;
        reg [7:0]  keep;
        begin
            for (w = 0; w * 8 < n; w = w + 1) begin
                word = 64'd0; cnt = 0;
                for (k = 0; k < 8; k = k + 1) begin
                    if (w * 8 + k < n) begin
                        word = (word << 8) | {56'd0, fb[w * 8 + k]};
                        cnt  = cnt + 1;
                    end
                end
                if (cnt < 8) word = word << (8 * (8 - cnt));  // 末字左对齐
                keep = 8'hFF << (8 - cnt);
                iw[ni] = word;  ik[ni] = keep;
                il[ni] = (w * 8 + 8 >= n);          // 末字
                iu[ni] = (w == 0);                  // SOP
                ic[ni] = (w * 8 + 8 >= n) ? 1'b1 : 1'b0;   // tcrs 仅末拍给 1
                ie[ni] = (w * 8 + 8 >= n) ? last_terr[0] : 1'b0;
                iv[ni] = 1'b1;
                ni = ni + 1;
            end
        end
    endtask

    // 期望字流 (同上, 写 ew/ek/el/eu/ec/ee)
    task pack_exp;
        input integer n;
        input integer last_terr;
        integer w, k, cnt;
        reg [63:0] word;
        reg [7:0]  keep;
        begin
            for (w = 0; w * 8 < n; w = w + 1) begin
                word = 64'd0; cnt = 0;
                for (k = 0; k < 8; k = k + 1) begin
                    if (w * 8 + k < n) begin
                        word = (word << 8) | {56'd0, gb[w * 8 + k]};
                        cnt  = cnt + 1;
                    end
                end
                if (cnt < 8) word = word << (8 * (8 - cnt));  // 末字左对齐
                keep = 8'hFF << (8 - cnt);
                ew[no] = word;  ek[no] = keep;
                el[no] = (w * 8 + 8 >= n);
                eu[no] = (w == 0);
                ec[no] = (w * 8 + 8 >= n) ? 1'b1 : 1'b0;
                ee[no] = (w * 8 + 8 >= n) ? last_terr[0] : 1'b0;
                no = no + 1;
            end
        end
    endtask

    // 生成一帧: nb 字节, vlan = 插 802.1Q tag (tpid + TCI A57B), terrf = 末拍 terr
    //   非 VLAN: tpid 强制写进 byte 12-13 (可放 0x8101/0x88A9 测"相似不命中")
    task gen_frame;
        input integer nb;
        input integer vlan;
        input [15:0]  tpid;
        input integer terrf;
        input integer nidle;      // 帧后空闲拍数
        integer j, g;
        begin
            for (j = 0; j < nb; j = j + 1)
                fb[j] = (pcnt + j) & 8'hFF;
            fb[12] = tpid[15:8];
            fb[13] = tpid[7:0];
            if (vlan) begin
                fb[14] = 8'hA5;                      // TCI (prio 5 / vid 0x0D7B)
                fb[15] = 8'h7B;
            end
            g = 0;
            for (j = 0; j < nb; j = j + 1) begin
                if (!(vlan && j >= 12 && j < 16)) begin
                    gb[g] = fb[j]; g = g + 1;
                end
            end
            pack_in(nb, terrf);
            pack_exp(g, terrf);
            if (vlan) vlan_frames = vlan_frames + 1;
            for (j = 0; j < nidle; j = j + 1) begin
                iv[ni] = 1'b0; iw[ni] = 64'd0; ik[ni] = 8'd0;
                il[ni] = 1'b0; iu[ni] = 1'b0; ic[ni] = 1'b0; ie[ni] = 1'b0;
                ni = ni + 1;
            end
            pcnt = pcnt + 32'd37;      // 下一帧字节图案换相 (黄金帧后 pcnt != 0)
        end
    endtask

    // 等输出排空到目标字数 (带超时) + dbg_vlan 落零检查
    task wait_drain;
        input integer target;
        begin
            t = 0;
            while (oidx < target && t < 2000000) begin
                @(posedge clk);
                t = t + 1;
            end
            if (oidx < target) begin
                $display("ERR drain timeout: oidx=%0d < %0d", oidx, target);
                nerr = nerr + 1;
            end
            repeat (10) @(posedge clk);
            // 注意: 此处不能查 dbg_vlan — 相位边界上输入流仍在继续, DUT 可能
            // 正在处理下一帧 (随机停顿时其输出尚未交付), dbg_vlan=1 属正常。
            // 落零检查只在全程排空后的末态做 (相位 2 之后)。
        end
    endtask

    // ---- 确定性帧表 ----
    task phase_det;
        begin
            // 非 VLAN 直通 (60..68 + 100B, 含 terr)
            gen_frame(60, 0, 16'h0800, 0, 0);
            gen_frame(61, 0, 16'h0800, 0, 0);
            gen_frame(64, 0, 16'h0800, 0, 2);
            gen_frame(68, 0, 16'h0800, 0, 0);
            gen_frame(100, 0, 16'h0800, 1, 3);
            // 非 VLAN 但 TPID 相似 (0x8101/0x88A9) -> 必须直通
            gen_frame(60, 0, 16'h8101, 0, 0);
            gen_frame(64, 0, 16'h88A9, 0, 0);
            // VLAN 剥离 (边界长度: 60 -> 剥后 56 整字; 61..67 -> 尾字 keep 非 0)
            gen_frame(60, 1, 16'h8100, 0, 0);
            gen_frame(61, 1, 16'h8100, 0, 0);
            gen_frame(62, 1, 16'h8100, 0, 0);
            gen_frame(63, 1, 16'h88A8, 0, 0);
            gen_frame(64, 1, 16'h8100, 0, 0);   // 剥后 60B -> 尾字 keep 非 0
            gen_frame(65, 1, 16'h8100, 1, 1);
            gen_frame(66, 1, 16'h88A8, 0, 0);
            gen_frame(67, 1, 16'h8100, 0, 0);   // 剥后 = 63B
            gen_frame(68, 1, 16'h8100, 0, 0);   // 剥后 = 64B 整字
            gen_frame(100, 1, 16'h88A8, 1, 4);
            // 背靠背零间隙: VLAN + 非 VLAN 交替
            gen_frame(60, 1, 16'h8100, 0, 0);
            gen_frame(60, 0, 16'h0800, 0, 0);
            gen_frame(61, 1, 16'h88A8, 0, 0);
            gen_frame(61, 0, 16'h0800, 0, 0);
            gen_frame(64, 1, 16'h8100, 0, 0);
            gen_frame(64, 0, 16'h0800, 0, 0);
            gen_frame(72, 1, 16'h8100, 0, 0);
            gen_frame(72, 0, 16'h0800, 0, 0);
            gen_frame(60, 1, 16'h88A8, 1, 0);
            gen_frame(60, 1, 16'h8100, 0, 0);
        end
    endtask

    // ---- 随机帧表 ----
    // 注意: 非 VLAN 帧的 byte 12-13 必须给真 ethertype (0x0800) — 若给 0x8100/
    // 0x88A8 则按 802.1Q 定义本帧就是 VLAN 帧 (DUT 会剥), 属激励歧义而非 RTL 缺陷。
    task phase_rand;
        input integer nf;
        integer r, nb, vl;
        begin
            for (r = 0; r < nf; r = r + 1) begin
                nb = 60 + ({$random} % 161);        // 60..220
                vl = $random & 1;
                gen_frame(nb, vl, vl ? ((($random & 1) ? 16'h8100 : 16'h88A8))
                                     : 16'h0800,
                          ($random & 1) && ((r % 7) == 3),
                          (($random % 3) == 0) ? 2 : 0);
            end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0;
        idx = 0; oidx = 0; ni = 0; no = 0;
        nerr = 0; vlan_frames = 0; pcnt = 0;
        golden_oidx = -1;
        ph0_no = 0; ph1_no = 0;
        m_tready = 0;
        for (si = 0; si < 16384; si = si + 1) begin
            iw[si] = 64'd0; ik[si] = 8'd0; il[si] = 1'b0; iu[si] = 1'b0;
            ic[si] = 1'b0; ie[si] = 1'b0; iv[si] = 1'b0;
            ew[si] = 64'd0; ek[si] = 8'd0; el[si] = 1'b0; eu[si] = 1'b0;
            ec[si] = 1'b0; ee[si] = 1'b0;
        end

        // ---- 全部激励在复位释放前生成完 (消除生成/消费并发写数组的竞争) ----
        // 相位 0: 黄金帧 + 确定性帧表
        pcnt = 32'd0; golden_oidx = no;         // 黄金帧: 字节 j = j
        gen_frame(64, 1, 16'h8100, 0, 0);
        phase_det();
        ph0_no = no;
        // 相位 1: 确定性帧表 (黄金帧不再用)
        golden_oidx = -1;
        phase_det();
        ph1_no = no;
        // 相位 2: 随机帧
        phase_rand(60);

        repeat (5) @(posedge clk);
        // 复位释放在时钟边沿之间 — 与边沿同时刻释放会让部分 always 块看到不同
        // 的 rst_n (进程执行顺序决定), 造成首个握手丢失/激励错位 (P0 教训)
        @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk);

        // ---- 相位 0 (无停顿) / 相位 1 (随机停顿) / 相位 2 (随机帧+停顿) ----
        wait_drain(ph0_no);
        $display("PHASE0 (nostall) done: %0d words", oidx);
        wait_drain(ph1_no);
        $display("PHASE1 (stall) done: %0d words", oidx);
        t = 0;
        while ((idx < ni || oidx < no) && t < 2000000) begin
            @(posedge clk);
            t = t + 1;
        end
        repeat (10) @(posedge clk);
        $display("PHASE2 (rand) done: %0d words", oidx);

        // ---- 统计对账 ----
        if (idx !== ni || oidx !== no) begin
            $display("ERR 末态 idx=%0d/%0d oidx=%0d/%0d", idx, ni, oidx, no);
            nerr = nerr + 1;
        end
        if (dbg_vlan !== 1'b0) begin
            $display("ERR 末态 dbg_vlan 未落零");
            nerr = nerr + 1;
        end
        if (stat_stripped !== vlan_frames) begin
            $display("ERR stat_stripped=%0d != 期望剥离帧数 %0d",
                     stat_stripped, vlan_frames);
            nerr = nerr + 1;
        end
        if (nerr == 0)
            $display("VLAN_STRIP TB PASS (in=%0d words, out=%0d words, vlan frames=%0d, stripped=%0d)",
                     ni, no, vlan_frames, stat_stripped);
        else
            $display("VLAN_STRIP TB FAIL (%0d errs)", nerr);
        $finish;
    end

    // 兜底超时 (TB 自身挂起的最后防线)
    initial begin
        repeat (8000000) @(posedge clk);
        $display("ERR timeout: TB 未在 8M 拍内结束 (idx=%0d oidx=%0d)", idx, oidx);
        $display("VLAN_STRIP TB FAIL (timeout)");
        $finish;
    end
endmodule
