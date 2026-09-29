`timescale 1ns/1ps
// 1G GMII 字节流 -> 64bit 左对齐 AXI-Stream 字流 (10G-ready MAC 边界)。
//
// 字流约定 (10G 升级时 PG157 的 AXIS 输出加一层 shim 对齐到同一约定):
//  - tdata[63:56] = 帧首字节 (dst_mac[0]), 字内字节从高到低连续
//  - SOP 字总是满对齐 (tkeep[7]=1); TLAST 字 tkeep 高位有效
//  - FCS 在本层校验并剥离: crc 残留 == 32'hC704DD7B 为正确 (tcrs, TLAST 有效)
//  - 剥离实现: 4 字节前瞻延迟线, 打包落后 CRC 输入 4 字节, 帧尾 4 字节 FCS 自然不打包
//
// ---------------------------------------------------------------------------
// 背压 / 溢出合同 (P6b F4 修复后重写 —— 这是本模块与下游的**接口语义**)
// ---------------------------------------------------------------------------
// 1. **满/空契约**: 内部 FIFO = `fifo_sync` (FWFT)。`m_axis_tvalid = !empty` 组合有效;
//    消费 = `tvalid && tready`。生产侧只看 `fifo_full_next` (见 2)。
// 2. **空间判定与"本次推入"的关系 (F4(b) 的根因)**:
//    推入是**寄存器** (`push`): 本轮 T 决定、T+1 拍才在 `fifo_sync` 里落笔。而
//    `fifo_sync.wr && !full` 里的 `full` 是**拍 T+1** 的值 —— 同拍在飞的另一次写
//    (即 T 拍正在执行的 `push`) 会把 `wptr` 顶一格, 于是"T 拍读到 full=0 (7/8)"与
//    "T+1 拍 full=1" 可以同时成立 ⇒ 该笔写被 `fifo_sync` **静默丢弃**。
//    ⇒ 修复: 空间门一律用 `fifo_sync.full_next` (下一拍满的**精确**预测, 含在飞写与
//    本拍读的影响): `push_ok = !full_next` ⇔ "本轮决定的这次推入下拍**一定落笔**"。
//    **多字 push 的空间要求**: 每拍至多决定一次推入; 一次推入只需 **1** 个空位
//    (但该空位必须在下拍仍然存在 ⇒ 判据用 full_next, 不是 full)。
// 3. **溢出行为 (绝无静默丢失)**:
//    空间不足时的动作一律是**整帧丢弃 + 计数**, 且区分原因:
//      - `stat_drop_full`    : 因 FIFO 空间不足丢的帧 (本模块丢弃动作的正常原因)
//      - `stat_drop_partial` : 其中"已经推过字"的帧 (孤儿字节 = `stat_orphan_bytes`)
//      - `stat_fifo_ovf`     : `fifo_sync` 拒写次数 —— **结构上恒 0**。
//        非 0 = 有字被静默丢弃 (修复失效), 是"无静默丢失"这条合同的自检回读。
//    ⚠️ `stat_drop - stat_drop_full` 还含另一类: **欠 TERM 期间帧字让路**造成的丢帧
//      (见 4②) —— 那类丢帧时 FIFO 有空间, 但帧字不得先于 TERM 落笔。
// 4. **帧边界 (绝不留裸尾巴字)**:
//    ① **收帧不需要空间** —— 字节先进 `hwv`/`wreg`, 只有**推字**才需要 FIFO 空位。
//       ⇒ 欠 TERM 期间**照常收帧**, 只是推不出去时整帧丢 (该帧零推入 ⇒ 不欠新 TERM)。
//    ② **TERM 优先**: 一旦某帧有字已进 FIFO 而该帧被中止, 立刻置 `term_pend`; 此后
//       **任何帧字都不得先落笔** (帧推入门 = `push_ok && !term_pend`) ⇒ TERM 必然排在
//       下一个 SOP 字之前。收尾两选一:
//      (i)  正常完成 —— 末字带真实 `tkeep`/`tcrs`/`terr`;
//      (ii) 被中止 —— 补一个 **TERM 字**: `tdata=0, tkeep=8'h00, tlast=1,
//           tuser=0, tcrs=0, terr=1` (0 字节, 不污染字节计数; tcrs=0 ⇒ 下游按坏帧丢)。
//    ⇒ **条件式保证 (实测边界, 勿读成无条件)**: 只要消费者在该 SOP 之后**还接受过
//      至少 1 个字** (即 FIFO 排空过 ≥1 格), 该 SOP 与下一个 SOP 之间就**恰好一个**
//      TLAST。**唯一例外**: 消费者自该 SOP 起**永久不再排空** (FIFO 长期满) ⇒ 最后
//      那个已开始的帧会停在"无 TLAST"状态 (它欠的 TERM 推不出去)。该例外: **有界**
//      (只影响那一帧, 不吞后续帧 —— 后续帧照常被收下并各自按合同丢/推)、**有计数**
//      (`stat_drop_partial`)、**非静默**、**不死锁** (空出 1 格立即补 TERM, 无需复位)。
//      实测: 消费者停摆期间 `SOP=3/TLAST=2/TERM=0`, 恢复后 TERM 立即落笔。
// 5. **守恒律 (可用计数器判)**:
//      #(TLAST 且 tkeep!=0 的交付帧) == stat_frames
//      Σpopc(tkeep)(全部交付字)    == stat_bytes - 4*stat_frames + stat_orphan_bytes
//      #(TLAST 且 tkeep==0 的交付帧) == stat_drop_partial
//      stat_drop_partial <= stat_drop_full <= stat_drop;  stat_fifo_ovf == 0
//    (FCS 4 字节不打包 ⇒ 完好帧的 Σpopc = fbytes - 4; 中止帧的 Σpopc = 孤儿字节。)
// 6. **无溢出路径逐位不变**: 不触发空间不足时, `push_ok` 与旧 `!fifo_full` 判据**同值**
//    (推导: 旧判据只在"本拍在飞写恰好填满"时分歧, 而那正是旧代码写被丢弃的场合),
//    故交付字节流与计数器逐位不变。
// 7. **消费者按 TLAST 完整性丢弃半帧** 的老合同仍然成立 (TERM 是它的显式化), 但下游
//    不再需要靠"下一个 SOP"来兜底重同步 (旧行为: 孤儿字 + 无 TLAST)。
// ---------------------------------------------------------------------------
module mac_rx_64 (
    input  wire        clk,          // 125 MHz (GMII 域)
    input  wire        rst_n,
    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rx_dv,
    input  wire        gmii_rx_er,
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_tuser,  // SOP
    output wire        m_axis_terr,   // TLAST 有效: 帧内 rx_er / 本帧被中止 (TERM 字)
    output wire        m_axis_tcrs,   // TLAST 有效: FCS 正确
    // 帧/字节统计 (只计"完整交付"的帧, 即末字真的进了 FIFO)
    output reg  [31:0] stat_frames,
    output reg  [31:0] stat_crc_err,
    output reg  [31:0] stat_drop,        // 丢帧总数 (各原因之和)
    output reg  [31:0] stat_bytes,
    // ---- P6b F4: 丢弃归因 / 守恒律计数 (快照窗口待接; 见头注释 §3/§5) ----
    output reg  [31:0] stat_drop_full,     // 因 FIFO 空间不足丢的帧
    output reg  [31:0] stat_drop_partial,  // 其中已推过字 (孤儿) 的帧数
    output reg  [31:0] stat_orphan_bytes,  // 这些帧已进 FIFO 的字节数 (Σpopc of orphans)
    output reg  [31:0] stat_fifo_ovf,      // fifo_sync 拒写次数 (恒 0; 非 0 = 静默丢失)
    // P4b-7-P6 三站词计数 (第 1 站, UART 行尾 MW 字段): 发出的 m_axis 字计数
    //   (tvalid && tready)。与下游 CW (rx_classify 进/出) / RW (tcp_rx 进) 对账:
    //   MW 增长而下游不增长 = 本层 FIFO 后段/下游拒收期间词被滞压 (非丢失);
    //   MW 与 CW 同步增长而 RW 落后 = 丢词发生在 rx_classify 或其后。
    output reg  [31:0] dbg_stat_words_out
);

    localparam [2:0] S_IDLE = 3'd0, S_PRE = 3'd1, S_DATA = 3'd2,
                     S_DROP = 3'd3, S_FLUSH = 3'd4;
    // 线上 FCS = zlib.crc32(payload) 值小端 (LSB-first, 铁律) -> 反射 CRC (无终值取反)
    // 全帧流过后的残留 == raw(0xFFFFFFFF) == 32'hDEBB20E3 (帧长无关, Python 实测)。
    // 0xC704DD7B 是 FCS 大端/非反射实现的魔数, 勿用。
    localparam [31:0] CRC_RESIDUE = 32'hDEBB20E3;

    reg  [2:0]  state;
    reg  [5:0]  pre_cnt;
    reg  [2:0]  bcnt;          // 当前累积字内字节数
    reg  [63:0] wreg;
    reg  [7:0]  wkeep;
    reg  [31:0] dline;         // FCS 前瞻: 打包消费旧 dline[31:24]
    reg  [15:0] fbytes;        // 帧字节总数 (含 FCS)
    reg         ferr;
    reg         first_done;    // 本帧 SOP 已发出 (⇒ 本帧已有字进 FIFO)
    reg  [15:0] fpushed;       // 本帧已推入 FIFO 的字所含字节数 (= 孤儿字节数)
    reg         term_pend;     // 有孤儿字欠一个 TERM 收尾字 (见头注释 §4)
    reg  [63:0] hwreg;         // 已完成整字保持 (延迟一拍以标记 TLAST)
    reg  [7:0]  hwkeep;
    reg         hwv;
    // CRC 使能/初值必须与 gmii_rxd 同拍 (组合), 否则漏首字节/多算尾字节
    wire        crc_en   = (state == S_DATA) && gmii_rx_dv;
    wire        crc_init = (state == S_PRE) && gmii_rx_dv &&
                           (gmii_rxd == 8'hD5) && (pre_cnt >= 6'd6);
    wire [31:0] crc;

    reg         push, push_last, push_sop, push_crs, push_err;
    reg  [63:0] push_data;
    reg  [7:0]  push_keep;
    wire        fifo_full, fifo_full_next, fifo_ovf_pulse;

    crc32_8b u_crc (.clk(clk), .init(crc_init), .en(crc_en), .d(gmii_rxd), .crc(crc));

    // ---- FIFO 空间判定 (F4(b) 修复核心; 见头注释 §2) ----
    // push 是寄存器: 本轮决定、下拍落笔。下拍的满判据 = fifo_full_next (精确, 含本拍
    // 在飞写与本拍读) ⇒ push_ok ⇔ 本轮这次推入下拍一定被接受。
    wire        push_ok  = !fifo_full_next;
    // ⚠️ **帧字推入还要让 TERM 优先** (P6b F4-2): 欠着 TERM 时, 任何帧字都不得先落笔
    //    (否则 TERM 会落在那帧的字之后 = 把 TERM 变成它的 TLAST, 帧边界错位)。
    //    注意: **收帧不需要空间** (字先进 hwv/wreg), 只有**推字**需要 ⇒ 欠 TERM 期间
    //    仍然正常收帧, 只是推不出去时整帧丢 (该帧零推入 ⇒ 不欠新 TERM)。
    wire        push_frame_ok = push_ok && !term_pend;
    // TERM 收尾字 (0 字节, 只闭合帧边界): 空间到位就推 —— 优先级高于帧字 (见上)
    wire        term_fire = term_pend && push_ok;

    // 右累积字 (首字节在 [8*n-1:8*n-8]) -> 左对齐 (首字节在 [63:56]); 用拼接免移位歧义
    function [63:0] ljust64;
        input [63:0] w;
        input [2:0]  n;
        begin
            case (n)
                3'd1: ljust64 = {w[7:0],   56'b0};
                3'd2: ljust64 = {w[15:0],  48'b0};
                3'd3: ljust64 = {w[23:0],  40'b0};
                3'd4: ljust64 = {w[31:0],  32'b0};
                3'd5: ljust64 = {w[39:0],  24'b0};
                3'd6: ljust64 = {w[47:0],  16'b0};
                3'd7: ljust64 = {w[55:0],   8'b0};
                default: ljust64 = w;
            endcase
        end
    endfunction

    function [7:0] ljust8;
        input [7:0] k;
        input [2:0] n;
        begin
            case (n)
                3'd1: ljust8 = {k[0],   7'b0};
                3'd2: ljust8 = {k[1:0], 6'b0};
                3'd3: ljust8 = {k[2:0], 5'b0};
                3'd4: ljust8 = {k[3:0], 4'b0};
                3'd5: ljust8 = {k[4:0], 3'b0};
                3'd6: ljust8 = {k[5:0], 2'b0};
                3'd7: ljust8 = {k[6:0], 1'b0};
                default: ljust8 = k;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; pre_cnt <= 0; bcnt <= 0; wreg <= 0; wkeep <= 0;
            dline <= 0; fbytes <= 0; ferr <= 0; first_done <= 0; fpushed <= 0;
            term_pend <= 1'b0;
            hwreg <= 0; hwkeep <= 0; hwv <= 0;
            push <= 0; push_last <= 0; push_sop <= 0; push_crs <= 0; push_err <= 0;
            push_data <= 0; push_keep <= 0;
            stat_frames <= 0; stat_crc_err <= 0; stat_drop <= 0; stat_bytes <= 0;
            stat_drop_full <= 0; stat_drop_partial <= 0;
            stat_orphan_bytes <= 0; stat_fifo_ovf <= 0;
            dbg_stat_words_out <= 32'd0;
        end else begin
            // P4b-7-P6 三站词计数 (第 1 站): 输出字握手拍 +1
            if (m_axis_tvalid && m_axis_tready)
                dbg_stat_words_out <= dbg_stat_words_out + 32'd1;
            // 无静默丢失自检回读: fifo_sync 拒写 (本轮 push 落不下) 计一次
            if (fifo_ovf_pulse)
                stat_fifo_ovf <= stat_fifo_ovf + 32'd1;
            push      <= 1'b0;
            push_last <= 1'b0;
            push_sop  <= 1'b0;
            push_crs  <= 1'b0;
            push_err  <= 1'b0;
            // ---- TERM 收尾字: 全局优先 (与帧字推入互斥: 帧推入门含 !term_pend) ----
            // 任何状态 (含 S_DROP/S_DATA 中途) 只要有 1 个空位就先把它送出去 ⇒
            // 下一次帧字推入必然排在 TERM 之后 ⇒ 交付流里不会出现"裸 SOP"。
            if (term_fire) begin
                push      <= 1'b1;
                push_data <= 64'd0;
                push_keep <= 8'd0;
                push_last <= 1'b1;
                push_sop  <= 1'b0;
                push_crs  <= 1'b1;   // MUT_termcrs
                push_err  <= 1'b0;
                term_pend <= 1'b0;
            end
            case (state)
                S_IDLE: begin
                    if (gmii_rx_dv && gmii_rxd == 8'h55) begin
                        state <= S_PRE; pre_cnt <= 1;
                    end
                end
                S_PRE: begin
                    if (!gmii_rx_dv) begin
                        state <= S_IDLE;
                    end else if (gmii_rxd == 8'h55) begin
                        pre_cnt <= (pre_cnt == 6'd63) ? pre_cnt : pre_cnt + 1;
                    end else if (gmii_rxd == 8'hD5 && pre_cnt >= 6'd6) begin
                        state <= S_DATA; bcnt <= 0; wreg <= 0; wkeep <= 0;
                        dline <= 0; fbytes <= 0; ferr <= 0; first_done <= 0;
                        fpushed <= 0;
                        hwreg <= 0; hwkeep <= 0; hwv <= 0;
                    end else begin
                        state <= S_IDLE;      // 前导内垃圾 -> 重新找前导
                    end
                end
                S_DATA: begin
                    if (!gmii_rx_dv) begin
                        // ---- 帧尾 ----
                        if (hwv && push_frame_ok) begin
                            // 本帧已有字进 FIFO 且末字还能进 ⇒ 正常完成
                            push <= 1'b1; push_data <= hwreg; push_keep <= hwkeep;
                            push_last <= (bcnt == 3'd0); push_sop <= !first_done;
                            first_done <= 1'b1;
                            fpushed <= fpushed + 16'd8;   // hwkeep 恒 8'hFF
                            push_crs <= (bcnt == 3'd0) && (crc == CRC_RESIDUE);
                            push_err <= (bcnt == 3'd0) && ferr;
                            if (bcnt == 3'd0) begin
                                state <= S_IDLE; hwv <= 0;
                                stat_frames <= stat_frames + 1;
                                if (crc != CRC_RESIDUE) stat_crc_err <= stat_crc_err + 1;
                                stat_bytes <= stat_bytes + fbytes;
                            end else begin
                                state <= S_FLUSH; hwv <= 0;
                            end
                        end else if (hwv && !push_frame_ok) begin
                            // 末字进不去 ⇒ 整帧丢。两种原因:
                            //   ① !push_ok: FIFO 没空间 (记 stat_drop_full)
                            //   ② term_pend: 空间有但 TERM 优先 (帧字让路) —— 该帧必然零推入
                            //      (first_done=0, 因为欠 TERM 期间帧字推不出去) ⇒ 不需要新 TERM
                            // 旧实现 (F4-2 缺陷): 这里无条件进 S_TERM, 而 term_pend 只在
                            //   first_done 时置 ⇒ term_pend=0 时 S_TERM 只能"等下一个前导再
                            //   牺牲它" ⇒ 白吞一个本来有空间的好帧。
                            state <= S_IDLE; hwv <= 0;
                            stat_drop <= stat_drop + 1;
                            if (!push_ok) stat_drop_full <= stat_drop_full + 1;
                            if (first_done) begin
                                term_pend <= 1'b1;
                                stat_drop_partial <= stat_drop_partial + 1;
                                stat_orphan_bytes <= stat_orphan_bytes + {16'd0, fpushed};
                            end
                        end else if (bcnt == 3'd0) begin
                            state <= S_IDLE;      // 零字节净荷帧: 丢弃 (无字入 FIFO)
                            stat_drop <= stat_drop + 1;
                        end else if (push_frame_ok) begin
                            // 短帧 (<8 字节净荷, 无保持字): 单字 TLAST 交付
                            push <= 1'b1;
                            push_data <= ljust64(wreg, bcnt);
                            push_keep <= ljust8(wkeep, bcnt);
                            push_last <= 1'b1; push_sop <= 1'b1;
                            push_crs <= (crc == CRC_RESIDUE); push_err <= ferr;
                            state <= S_IDLE;
                            stat_frames <= stat_frames + 1;
                            if (crc != CRC_RESIDUE) stat_crc_err <= stat_crc_err + 1;
                            stat_bytes <= stat_bytes + fbytes;
                        end else begin
                            // 单字 TLAST 也进不去: 该帧从未推过字 ⇒ 整帧丢, 无 TERM
                            state <= S_IDLE;
                            stat_drop <= stat_drop + 1;
                            if (!push_ok) stat_drop_full <= stat_drop_full + 1;
                        end
                    end else begin
                        // ---- 帧内字节 ----
                        ferr   <= ferr | gmii_rx_er;
                        fbytes <= fbytes + 1;
                        dline  <= {dline[23:0], gmii_rxd};
                        if (fbytes >= 16'd4) begin
                            if (bcnt == 3'd7) begin
                                // 整字完成 -> 进保持字; 旧保持字先推
                                if (hwv && !push_frame_ok) begin
                                    state <= S_DROP; hwv <= 0;
                                    stat_drop <= stat_drop + 1;
                                    if (!push_ok) stat_drop_full <= stat_drop_full + 1;
                                    if (first_done) begin
                                        term_pend <= 1'b1;
                                        stat_drop_partial <= stat_drop_partial + 1;
                                        stat_orphan_bytes <= stat_orphan_bytes + {16'd0, fpushed};
                                    end
                                end else begin
                                    if (hwv) begin
                                        push <= 1'b1; push_data <= hwreg; push_keep <= hwkeep;
                                        push_last <= 1'b0; push_sop <= !first_done;
                                        first_done <= 1'b1;
                                        fpushed <= fpushed + 16'd8;   // hwkeep 恒 8'hFF
                                    end
                                    hwreg  <= {wreg[55:0], dline[31:24]};
                                    hwkeep <= 8'hFF; hwv <= 1'b1;
                                    wreg <= 0; wkeep <= 0; bcnt <= 0;
                                end
                            end else begin
                                wreg  <= {wreg[55:0], dline[31:24]};
                                wkeep <= {wkeep[6:0], 1'b1};
                                bcnt  <= bcnt + 1;
                            end
                        end
                    end
                end
                S_FLUSH: begin
                    if (push_frame_ok) begin
                        push <= 1'b1;
                        push_data <= ljust64(wreg, bcnt);
                        push_keep <= ljust8(wkeep, bcnt);
                        push_last <= 1'b1; push_sop <= !first_done;
                        push_crs <= (crc == CRC_RESIDUE); push_err <= ferr;
                        fpushed <= fpushed + {13'd0, bcnt};
                        state <= S_IDLE;
                        stat_frames <= stat_frames + 1;
                        if (crc != CRC_RESIDUE) stat_crc_err <= stat_crc_err + 1;
                        stat_bytes <= stat_bytes + fbytes;
                    end else begin
                        // 末字进不去: S_FLUSH 态的帧必已有字进 FIFO (first_done 恒 1)
                        // ⇒ 欠 TERM 收尾 (§4)。first_done=1 只可能出现在 term_pend=0 的帧上
                        // (推入门含 !term_pend), 故这里必然 !push_ok (空间不足)。
                        state <= S_IDLE;
                        stat_drop <= stat_drop + 1;
                        stat_drop_full <= stat_drop_full + 1;
                        term_pend <= 1'b1;
                        stat_drop_partial <= stat_drop_partial + 1;
                        stat_orphan_bytes <= stat_orphan_bytes + {16'd0, fpushed};
                    end
                end
                S_DROP: begin
                    // 只吞本帧剩余字节。**不在这里等空间、也不吞下一帧**: 欠着的 TERM 由
                    // 全局优先级块推 (§ 见上), 收帧不受它阻塞 ⇒ 下一帧照常被识别。
                    // S_DROP 恒由 gmii_rx_dv=1 的拍进入 (帧中), 故 !dv 即本帧结束。
                    if (!gmii_rx_dv) state <= S_IDLE;
                end
            endcase
        end
    end

    // ---- 输出 FIFO + AXIS ----
    localparam FW = 76;   // tdata[75:12] tkeep[11:4] sop[3] last[2] crs[1] err[0]
    wire [FW-1:0] fdin  = {push_data, push_keep, push_sop, push_last, push_crs, push_err};
    wire [FW-1:0] fdout;
    wire          fempty;
    wire          rd = m_axis_tvalid && m_axis_tready;   // 组合: 与 valid 同拍消费

    fifo_sync #(.W(FW), .D(8), .AW(3)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr(push), .din(fdin),
        .rd(rd), .dout(fdout),
        .empty(fempty), .full(fifo_full),
        .full_next(fifo_full_next),     // P6b F4(b): 精确下一拍满 (空间门用)
        .ovf_pulse(fifo_ovf_pulse)      // P6b F4: 拒写脉冲 (自检; 应恒 0)
    );

    assign m_axis_tdata  = fdout[75:12];
    assign m_axis_tkeep  = fdout[11:4];
    assign m_axis_tuser  = fdout[3];
    assign m_axis_tlast  = fdout[2];
    assign m_axis_tcrs   = fdout[1];
    assign m_axis_terr   = fdout[0];
    assign m_axis_tvalid = !fempty;
endmodule
