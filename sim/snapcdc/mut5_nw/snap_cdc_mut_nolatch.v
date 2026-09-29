`timescale 1ns/1ps
//=============================================================================
// snap_cdc.v — 跨时钟域的**相干快照** (P6e 合体用: gmii_clk → axi_aclk)
//=============================================================================
// 用途: 数据面跑在 PHY 回送的 gmii_clk(125MHz), 而观测寄存器在 XDMA 的 axi_aclk(250MHz);
//   主机要读的是数据面的一束**计数/状态**。多比特信号**不能**用两级同步器直接跨 (各比特
//   到达时刻不同 ⇒ 读出的是"位混"的假值)。本模块用 **toggle 握手** 保证:
//     ① 数据在 b 域被**一次性锁存** (hold_b) ⇒ 快照内的各位来自同一拍 ⇒ 相干;
//     ② hold_b 保持到下一次请求 ⇒ a 域采样时它已稳定;
//     ③ 回送的 toggle 到达 a 域才置 valid ⇒ 不读到半成品。
//
// 协议 (a 域 = 访问域, b 域 = 数据源域):
//   req_a 脉冲 → (2FF 同步到 b) → b 锁存 din_b 到 hold_b (并自翻转 ack_b 回送)
//   → (2FF 回同步到 a) → done_a 上升沿 ⇒ dout_a <= hold_b 且 valid_a 拉高 1 拍
//   往返延迟约 4-6 拍 (两域各 2 拍同步 + 1 拍) —— 对"读诊断计数"绰绰有余, 且**天然限速**
//   (两次请求之间必须等上一次 done)。
//
// ⚠️ 前提 (调用方负责): din_b **必须只在 clk_b 的沿上变化** (即 b 域寄存器输出)。
//   b 域组合逻辑的毛刺会在锁存沿被采到 ⇒ 快照可能截到一跳变中的位。
// ⚠️⚠️ **硬契约 ①: req_a 必须是"恰好 1 个 clk_a 周期宽"的脉冲**。
//   本模块对 req_a 的实现是组合的 `req_a && !busy_a` ⇒ 请求期间电平**一直高就会被反复受理**
//   (对抗测试实测: 常高 200 拍 ⇒ 25 次请求/25 次 valid, 1:1; 不是 1 次)。"忙时再发被忽略"
//   只是因为往返要 ~10 拍 —— **脉冲一旦宽过一个往返, 语义就从"一次请求"变成"连续重触发"**,
//   所以"1 拍脉冲"是契约而不是描述。本工程唯一的调用方 (axi_regs 的
//   `snap_req = wr_go && (w_word==6)`) 天然是 1 拍 ✓; 换调用方时这条要当硬要求。
//   若将来需要"电平型请求", 必须在本模块里加边沿检测, 不能指望调用方自觉。
// ⚠️ **硬契约 ②: 必须用 valid_a 采样 dout_a, 不要用"busy_a 落下"当完成信号**:
//   busy_a 落在 done_a 拉高的那一拍, valid_a 与 dout_a 更新在**下一拍** ⇒ "等 busy 落下就读"
//   会读到**上一代**的数据 (实测逐拍核对过: 535 次采样全部落在 done_a=1 那拍, 无一例外是
//   busy 已落而 valid 未到的那一拍)。本文件的集成用法 (寄存器块在 snap_valid 上捕获) 用的是
//   valid_a, 所以没事; 但换调用方时这条是硬要求。
//
// ⚠️ **复位只有一根 rst_n (a 域), b 域握手复位由它同步而来 —— 这是设计选择, 理由要看清**:
//   一开始写它的理由是"两域各自复位会死锁", 那条**已被实测证伪** (见下) —— 现按实测理由保留:
//   ① **实测 (sim/snapcdc/negctrl/)**: 用"两个域各用各的复位"的旧结构, 请求飞行途中**只复位
//      b 域** ⇒ busy_a **能自己恢复** (不是死锁)。原因: 同步器把 toggle_a 当**电平**连续采样,
//      b 域复位后它会把"仍然是 1 的电平"重新识别成一次沿 ⇒ 更新脉冲重新产生 ⇒ 握手补完。
//      (我原先按"沿驱动"推理, 断言会死锁 —— 推理错了, 是测量纠正的。)
//   ② 那为什么还保留同源复位: 追求**复位后的确定性** —— 单一复位源 + 同步释放 ⇒ 复位一释放,
//      两侧握手寄存器必然同处"空闲/一致"态; 而独立复位下, 飞行中复位会让那次请求被**重跑一遍**
//      (数据重新锁存一次, a 域收到一次"没有被重新请求过"的 valid)。对监视通路无害, 但不干净。
//   数据源 din_b 自己那套复位与握手无关 (只影响数据, 不影响握手), 可以独立复位。
//   ★ **实测性质 (两条, 集成侧要用的)**: (a) 判据 7 —— clk_b **跑一阵再停** ⇒ busy_a 挂高、
//     不误报 valid; 恢复后握手**自动补完**, 数据正确。 (b) 判据 9 —— **复位释放时 clk_b 根本
//     没起** (板上 PHY 时钟晚到的真实上电顺序) ⇒ 空闲、不冒假 valid/busy; clk_b 起来后第一次
//     快照即正常。 两条合起来 ⇒ 观测通道只会"暂时没更新", 不会永久失明。
//     (⚠️ 早先这里把 (b) 记在判据 7 名下 —— 引错证据出处, 现已各归各。)
//=============================================================================
module snap_cdc #(
    parameter W  = 32,          // 每字位宽
    parameter NW = 6            // 字数 (总位宽 = NW*W)
) (
    // ---- a 域: 访问域 (axi_aclk) ----
    input  wire              clk_a,
    input  wire              rst_n,        // 唯一复位, 低有效; b 域握手复位由它同步而来
    input  wire              req_a,        // 1 拍脉冲: 请求一次快照 (busy 时忽略)
    output wire              busy_a,       // 高 = 上一次请求还没回来
    output reg  [NW*W-1:0]   dout_a,       // 快照结果 (valid_a 同拍有效)
    output reg               valid_a,      // 1 拍脉冲
    // ---- b 域: 数据源 (gmii_clk) ----
    input  wire              clk_b,
    input  wire [NW*W-1:0]   din_b
);

    // ---------------- b 域握手复位: 同源异步置位 + 同步释放 ----------------
    // (理由见文件头: 不是为了躲死锁 —— 那是被证伪的, 是为了"复位释放后必然空闲/一致")
    (* ASYNC_REG = "TRUE" *) reg [1:0] rstb_sync;    // 复位同步器链 (同样是跨域位)
    always @(posedge clk_b or negedge rst_n) begin
        if (!rst_n) rstb_sync <= 2'b00;
        else        rstb_sync <= {rstb_sync[0], 1'b1};
    end
    wire rst_b_n = rstb_sync[1];       // 干净的寄存器输出, 可当 b 域异步复位用

    // ---------------- a → b: 请求 toggle ----------------
    reg toggle_a;
    always @(posedge clk_a or negedge rst_n) begin
        if (!rst_n)                  toggle_a <= 1'b0;
        else if (req_a && !busy_a)   toggle_a <= ~toggle_a;
    end

    // ⚠️ ASYNC_REG 必须打在**同步器链的每一个触发器**上 (这里是一个 3 位 reg, 属性覆盖全部 3 位):
    //    它告诉工具"这几位跨时钟域", 影响到布局 (放在一起、靠近目的地) 与优化 (不许被吸收/复制)。
    //    本工程此前没有任何 ASYNC_REG —— 集成到 P6e 之后这才是第一条真正的跨时钟域路径。
    (* ASYNC_REG = "TRUE" *) reg [2:0] tog_sync_b;
    always @(posedge clk_b or negedge rst_b_n) begin
        if (!rst_b_n) tog_sync_b <= 3'd0;
        else          tog_sync_b <= {tog_sync_b[1:0], toggle_a};
    end
    wire update_b = (tog_sync_b[2] ^ tog_sync_b[1]);   // 同步后的沿 (1 拍宽)

    // ---------------- b 域: 相干锁存 ----------------
    reg [NW*W-1:0] hold_b;
    always @(posedge clk_b or negedge rst_b_n) begin
        if (!rst_b_n)      hold_b <= {(NW*W){1'b0}};
        else if (update_b) hold_b <= din_b;            // 一次性锁存整束
    end

    // ---------------- b → a: 回送 toggle ----------------
    reg ack_b;
    always @(posedge clk_b or negedge rst_b_n) begin
        if (!rst_b_n)      ack_b <= 1'b0;
        // ⚠️ 必须写 `~ack_b`, **不能**写 `tog_sync_b[2]` —— update_b 有效的那个沿,
        //    tog_sync_b[2] 采到的还是**旧**值 (新值要到下一拍才进 [2]) ⇒ 回送永远慢一代,
        //    握手永远完不成 (单元门第一次跑就 TIMEOUT 挂在这里)。
        else if (update_b) ack_b <= ~ack_b;            // 自翻转: 与 toggle_a 逐次同步
    end

    (* ASYNC_REG = "TRUE" *) reg [2:0] ack_sync_a;   // 同步器链, 见上
    always @(posedge clk_a or negedge rst_n) begin
        if (!rst_n) ack_sync_a <= 3'd0;
        else        ack_sync_a <= {ack_sync_a[1:0], ack_b};
    end

    // ---------------- a 域: 结果呈现 ----------------
    wire done_a = (ack_sync_a[2] == toggle_a);         // 回送与本域 toggle 一致 ⇒ 已回来
    reg  done_r;
    assign busy_a = (ack_sync_a[2] != toggle_a);

    always @(posedge clk_a or negedge rst_n) begin
        if (!rst_n) begin
            done_r  <= 1'b1;      // 复位后 done_a 本来就是 1 ⇒ 预置 1 以免假 valid
            dout_a  <= {(NW*W){1'b0}};
            valid_a <= 1'b0;
        end else begin
            done_r  <= done_a;
            valid_a <= done_a && !done_r;              // 1 拍脉冲
            if (done_a && !done_r) dout_a <= din_b;   // MUTANT-NOLATCH (generated, do not edit)   // 此刻 hold_b 已稳定
        end
    end

endmodule
