`timescale 1ns/1ps
//=============================================================================
// app_udp_pattern.v — P5e-T3: UDP 演示 app (TX 图案发生器 + RX 图案校验器)
//=============================================================================
// 与 rtl/app_pattern.v (TCP 演示 app) 的关系: **同风格 / 同图案约定, 独立模块**。
//   · 图案: xorshift64 `s ^= s<<13; s ^= s>>7; s ^= s<<17`, 每步取 s[31:24],
//     种子 0x9E3779B97F4A7C15, **先取后推进** —— 与 tools/cpp_peer 的
//     --udp-send-pattern / --udp-rx-only 逐字节一致 (peer.cpp:1950 rpat::fill:
//     `dst[i] = s>>24; s = xs_next64(s)`), 也与 app_pattern.v 逐位同款。
//   · 为什么另开模块而不复用 app_pattern: UDP **无连接语义** —— 没有 CONN_UP/DOWN
//     事件、没有 tid/conn_id、没有 FIN/RST 收尾, 帧边界就是数据报边界。硬塞进
//     TCP app 的事件驱动 FSM 会引入一堆板上恒假的分支 (板级不可测)。
//
// 【TX】(→ wrapper 的 app_udp_tx_* → udp_tx_cfg (peer 门 + cfg 锁存) →
//        udp_tx_frame (长度守卫) → tx_arb → mac_tx_64)
//   · 启动门 = `i_en && i_tx_ready`;  i_tx_ready = udp_tx_cfg.o_ready = peer 表
//     有效位。**默认不激活**: 无 peer (未 learn-on-RX) ⇒ 一帧不发, 且数据面上
//     恒 valid=0 ⇒ 下游 (peer 门) 看不到任何帧 (与 T2 的"默认不发送"逐位一致)。
//   · 每帧载荷 = `i_paylen` 字节 (板级 = 1472 = MTU 1518 - 42), 载荷 = 图案流的
//     **连续前缀**, 跨帧连续 (与 peer --udp-rx-only 的"自 offset 0 连续校验"一致;
//     跨会话不重置 —— UDP 无会话概念, 只有 i_en 的上升沿重启, 见下)。
//   · 限速 = 帧间 `TX_GAP` 个空闲拍 (参数)。0 = 全速 (线上约 957 Mbps, 受
//     mac_tx 线速限制); 默认 58000 ⇒ 帧周期 1538+58000 = 59538 拍 @125MHz
//     ⇒ 1472*8/476.3us ≈ **24.7 Mbps payload (≈25.4 Mbps 线上)**。
//     选 25 Mbps 的理由: T6 板级实测 (peer.cpp:2529 记录) —— 参考对端
//     (peer.exe --udp-rx-only) 在 20/25 Mbps 全收, >=30 Mbps 丢 ~2/3 帧。
//     板级验收用 `peer --rate-mbps 20` ⇒ 本默认与它同量级, 双向都稳。
//   · `TX_BYTES != 0` = 一次会话发完即停 (done 粘滞); 0 (默认) = 连续不停。
//   · AXIS 契约: m_* 是 pw_* 的**纯组合输出** (坑 4: 寄存器化 valid 会在消费拍后
//     多挂一拍 ⇒ 同一 beat 被双采); tready=0 期间 pw_* 保持不变。
//
// 【RX】(← wrapper 的 app_udp_rx_* ← udp_split 帧缓冲播放器, 帧级 store-and-forward)
//   · 载荷**逐字节**比对图案流, 失配计 stat_mismatch (字节数, 粘滞)。
//   · 消费速率 = **1 字节/拍, II=1 无空拍** (125 MB/s @125MHz = 1G 线速)。
//     关键在"1 字前瞻寄存器": app_pattern 的 RX 是"1 拍装字 + n 拍比字节"
//     ⇒ 8 字节 9 拍 = 111 MB/s (89% 线速, 结构性跟不上无限速灌包):
//     本模块把**装载与比对并行** (比对期间把下一字收进 nx_*), 8 字节恰 8 拍。
//   · **为什么选"字节串行 + 无缝"而不是 8 路并行 (8 步 xorshift/拍)**: 三条论证
//     ① 需求侧: 本构建是 1G MAC ⇒ 线上字节率结构性 <= 125 MB/s, 而本 verifier
//        有数据时恰好 125 MB/s ⇒ 跟得上; 更深一层, 以太网每帧还有 42+4+20 = 66
//        字节开销 (MAC/IP/UDP 头 + FCS + 前导/IFG) ⇒ **载荷**率只有线速的
//        1472/1538 = 95.7% ⇒ 净余量 ~4.5%, 且 udp_split 的 4KB 帧缓冲吸收帧间
//        缝隙 (每帧缝隙 <=6 拍, 4KB 缓冲可吸收 ~500 帧的累积)。板级验收用
//        peer --rate-mbps 20 (= 2.5 MB/s) ⇒ 裕度 50x。
//     ② 成本侧: 8 步 xorshift64 的组合链 = 24 级 64 位 XOR (~3-7ns @K7-2),
//        而 T2 布线后 **WNS 只剩 +0.230ns @8ns 周期** (vivado_prj/timing_p5_routed.rpt)
//        ⇒ 加进去大概率直接破时序, 修法只能是再加一级流水 (复杂度换来的余量
//        本构建用不上)。
//     ③ 上限写清 (**这是本 verifier 的天花板**): 1G 线速。10G 构建必须改成
//        8 路并行 (8 步/拍 = 1 GB/s); 若那时要压时序, 拆两级流水 (每级 4 步,
//        4 字节/拍 = 500 MB/s) **仍然不够 10G 的 1.25 GB/s** ⇒ 10G 版需要
//        "两级流水 + 4 lane" 或线性代数化 (s_8 = M^8·s_0 的矩阵异或树, 深度
//        ~6 级 LUT)。本模块的参数化只留了 TX 侧, RX 侧是本次 1G 口径的定版。
//   · `i_en = 0` ⇒ **不校验**: 不计数失配, LFSR 钉在 SEED。使能后从下一个字节起
//     按 SEED 起算 ⇒ 板级"先使能再灌图案"语义清晰。⚠️ i_en 必须在静止时翻转
//     (半个字中途翻转会让该字剩余字节用错期望序列)。
//   · app_rx_tready 是**真反压** (前瞻空位才收): 上游 udp_split 的播放器是帧级
//     store-and-forward + 4KB 帧缓冲 ⇒ 反压停在缓冲里, 永不到 mac_rx_64
//     (T1 的"结构性不反压"合同不被破坏)。
//   · 帧边界在 RX **不参与判据**: 图案流是逐字节连续的, 校验只需字节序; tlast/
//     sof/len 只用于统计 (帧数 / 0 长帧数)。
//=============================================================================
module app_udp_pattern #(
    // 一次会话的总载荷字节数 (0 = 连续不停; 非 0 = 发完置 done 粘滞)。
    // 非 0 时**逐字节精确**: 末帧长度 = min(i_paylen, 剩余) ⇒ 线上恰好 TX_BYTES
    // 字节图案 (gap 语义: seg_len_n 见下), 便于 peer --udp-rx-only N 对账。
    parameter [31:0] TX_BYTES = 32'd0,
    parameter [63:0] SEED     = 64'h9E3779B97F4A7C15,
    // 帧间空闲拍数 (限速; 0 = 全速)。默认 58000 ⇒ ~24.7 Mbps payload (见头注释)
    parameter [15:0] TX_GAP   = 16'd58000,
    // 载荷长度守卫阈值 —— **必须镜像 rtl/udp_tx_frame.v 的 PLEN_MAX** (默认 1500):
    //   seg_len > PLEN_MAX 的帧会被 udp_tx_frame **帧内中止** (零字节上线),
    //   若本模块的 LFSR 照常推进, 线上图案流就出现一个空洞 (下游 peer 的连续
    //   校验必然失配)。这里对齐 app_pattern.v 的 bad_frm 手法 (LFSR 冻结 +
    //   常数填充), 使"被丢弃帧不消耗图案流" ⇒ **线上图案流始终连续**。
    //   板级 i_paylen 恒 1472 ⇒ 本路径不可达 (纯 TB 边界用例用)。
    parameter [11:0] PLEN_MAX = 12'd1500
) (
    input  wire        clk,
    input  wire        rst_n,
    // ---- 控制 ----
    input  wire        i_en,             // 演示使能 (1 = 收/发都工作; 0 = 都不工作)
    input  wire        i_tx_ready,       // = udp_tx_cfg.o_ready (peer 表有效)
    input  wire [11:0] i_paylen,         // 每帧载荷字节数 (板级 1472)
    // ---- TX: app → stack (AXIS 字流; 一帧 = 一个 UDP 数据报) ----
    output wire [63:0] m_tdata,
    output wire [7:0]  m_tkeep,
    output wire        m_tvalid,
    input  wire        m_tready,
    output wire        m_tlast,
    // ---- RX: stack → app (udp_split 的 app UDP RX 口) ----
    input  wire [63:0] rx_tdata,
    input  wire [7:0]  rx_tkeep,
    input  wire        rx_tvalid,
    output wire        rx_tready,
    input  wire        rx_tlast,
    input  wire        rx_sof,
    input  wire [15:0] rx_len,
    // ---- 统计 / 状态 ----
    output reg  [31:0] stat_tx_bytes,
    output reg  [31:0] stat_tx_frames,
    output reg  [31:0] stat_rx_bytes,
    output reg  [31:0] stat_rx_frames,
    output reg  [31:0] stat_rx_null,     // 收到的 0 长数据报帧数 (rx_len==0)
    output reg  [31:0] stat_mismatch,    // 失配字节数 (粘滞)
    output reg         active,           // TX: 正在发帧 或 在帧间限速间隙里
    output reg         done,             // TX_BYTES 已发完 (粘滞, TX_BYTES!=0 才有意义)
    output reg  [3:0]  led
);
    // ---------------- 图案函数 (与 app_pattern.v / peer.cpp 同款) ----------------
    function [63:0] xs_next;
        input [63:0] s;
        reg   [63:0] t;
        begin
            t = s ^ (s << 13);
            t = t ^ (t >> 7);
            t = t ^ (t << 17);
            xs_next = t;
        end
    endfunction

    // 左对齐: stg 低 n 字节 → 高 n 字节 (显式 case, 坑 5: 禁变移位量)
    function [63:0] ljust8;
        input [63:0] s;
        input [3:0]  n;
        begin
            case (n)
                4'd1: ljust8 = {s[7:0],  56'b0};
                4'd2: ljust8 = {s[15:0], 48'b0};
                4'd3: ljust8 = {s[23:0], 40'b0};
                4'd4: ljust8 = {s[31:0], 32'b0};
                4'd5: ljust8 = {s[39:0], 24'b0};
                4'd6: ljust8 = {s[47:0], 16'b0};
                4'd7: ljust8 = {s[55:0], 8'b0};
                default: ljust8 = s;                 // 8 (及 0 的惰性值)
            endcase
        end
    endfunction

    // tkeep: 高 n 字节有效 (本工程 AXIS 约定: 左对齐 + tkeep 高位连续)
    function [7:0] kmask8;
        input [3:0] n;
        begin
            case (n)
                4'd0: kmask8 = 8'h00;
                4'd1: kmask8 = 8'h80;
                4'd2: kmask8 = 8'hC0;
                4'd3: kmask8 = 8'hE0;
                4'd4: kmask8 = 8'hF0;
                4'd5: kmask8 = 8'hF8;
                4'd6: kmask8 = 8'hFC;
                4'd7: kmask8 = 8'hFE;
                default: kmask8 = 8'hFF;
            endcase
        end
    endfunction

    function [3:0] pop8;
        input [7:0] v;
        integer i;
        reg [3:0] c;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]};
            pop8 = c;
        end
    endfunction

    // 字内第 i 字节 (i = 0 为 tdata[63:56])
    function [7:0] byte_at;
        input [63:0] d;
        input [3:0]  i;
        begin
            case (i)
                4'd0: byte_at = d[63:56];
                4'd1: byte_at = d[55:48];
                4'd2: byte_at = d[47:40];
                4'd3: byte_at = d[39:32];
                4'd4: byte_at = d[31:24];
                4'd5: byte_at = d[23:16];
                4'd6: byte_at = d[15:8];
                default: byte_at = d[7:0];
            endcase
        end
    endfunction

    //=========================================================================
    // TX 侧
    //=========================================================================
    localparam [1:0] T_IDLE = 2'd0, T_FRM = 2'd1, T_GAP = 2'd2, T_DONE = 2'd3;

    reg  [1:0]  txs;
    reg  [63:0] tx_lfsr;
    reg  [11:0] seg_len;      // 本帧载荷长度 (帧起锁存 i_paylen)
    reg  [11:0] seg_sent;     // 本帧已交付字节
    reg  [3:0]  bcnt;         // 当前字已凑字节数
    reg  [63:0] stg;          // 当前字累积 (低 bcnt 字节)
    reg  [63:0] pw_data;      // 已呈交字 (tready=0 期间保持)
    reg  [7:0]  pw_keep;
    reg  [3:0]  pw_n;
    reg         pw_last;
    reg         pw_valid;
    reg         nul_pend;     // 本帧 = 0 长数据报 (呈交 1 拍 tkeep=0 + tlast)
    reg  [15:0] gap_cnt;      // 帧间限速倒计时
    reg  [31:0] remain;       // TX_BYTES != 0 时的剩余字节
    reg         first_frm;    // 本会话首帧 (复位置 1, 首帧启动拍清)

    // 呈交口 (纯组合; 坑 4)
    assign m_tdata  = pw_data;
    assign m_tkeep  = pw_keep;
    assign m_tvalid = pw_valid;
    assign m_tlast  = pw_last;

    wire [11:0] left = seg_len - seg_sent;                     // 本帧剩余字节
    wire [3:0]  need = (left >= 12'd8) ? 4'd8 : left[3:0];     // 本字字节数
    wire [31:0] rem_n = (TX_BYTES == 32'd0) ? 32'd0 :
                        ((remain >= {20'b0, pw_n}) ? (remain - {20'b0, pw_n}) : 32'd0);
    // 下一帧长度: TX_BYTES=0 ⇒ 恒 i_paylen (连续模式); 非 0 ⇒ 末帧取余数
    // (逐字节精确: 线上恰好 TX_BYTES 字节)。
    // ⚠️ rem_eff 的存在理由: remain 是寄存器, 而"会话首帧"的启动拍与 remain<=TX_BYTES
    //   是**同一边沿** ⇒ 直接读 remain 会拿到复位值 0 ⇒ 首帧变成 0 长数据报 (坑 6 同族:
    //   新状态第一次用的采样时刻). 首帧用 TX_BYTES, 之后用 remain。
    wire [31:0] rem_eff   = first_frm ? TX_BYTES : remain;
    wire [11:0] seg_len_n = (TX_BYTES == 32'd0)       ? i_paylen :
                            ((rem_eff[31:12] != 20'd0) ? i_paylen : rem_eff[11:0]);
    // 长度守卫: 超 PLEN_MAX 的帧必被 udp_tx_frame 中止 (零字节上线) ⇒ 本模块
    // 冻结 LFSR (载荷常数 0xA5) 保住"线上图案流连续" (见 PLEN_MAX 注释)
    wire        pay_ok  = (seg_len <= PLEN_MAX);
    wire [7:0]  gen_byte = pay_ok ? tx_lfsr[31:24] : 8'hA5;
    wire        pass = pw_valid && m_tready;                   // 呈交被消费
    // 帧收尾 (末字被消费) —— 帧计数/限速/done 判定的唯一落点
    wire        frm_close = pass && pw_last;

    //=========================================================================
    // RX 侧: 字节串行逐字节比对, 1 字前瞻寄存器 ⇒ 8 字节恰 8 拍 (II=1 无缝)
    //=========================================================================
    reg  [63:0] rx_lfsr;
    reg  [63:0] cmp_d;   reg [7:0] cmp_k;  reg [3:0] cmp_n, cmp_i;  reg cmp_busy;
    reg  [63:0] nx_d;    reg [7:0] nx_k;   reg [3:0] nx_n;          reg nx_v;

    // 前瞻空即收: 引擎比对 8 拍期间恰好等下一次装载 ⇒ 稳态 1 字节/拍
    assign rx_tready = !nx_v;

    wire [7:0] rx_exp  = rx_lfsr[31:24];
    wire [7:0] rx_got  = byte_at(cmp_d, cmp_i);
    wire       cmp_hit = cmp_busy && (cmp_n != 4'd0);          // 本拍真比一个字节
    wire       cmp_end = (cmp_i + 4'd1 >= cmp_n);              // 本拍比的是本字末字节
    wire       rx_bad  = cmp_hit && i_en && (rx_got !== rx_exp);
    wire       rx_ld   = rx_tvalid && rx_tready;               // 前瞻装载

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            txs <= T_IDLE; tx_lfsr <= SEED;
            seg_len <= 12'd0; seg_sent <= 12'd0; bcnt <= 4'd0; stg <= 64'd0;
            pw_data <= 64'd0; pw_keep <= 8'h00; pw_n <= 4'd0; pw_last <= 1'b0;
            pw_valid <= 1'b0; nul_pend <= 1'b0; gap_cnt <= 16'd0; remain <= 32'd0;
            first_frm <= 1'b1;
            stat_tx_bytes <= 32'd0; stat_tx_frames <= 32'd0;
            active <= 1'b0; done <= 1'b0;
            rx_lfsr <= SEED;
            cmp_d <= 64'd0; cmp_k <= 8'h00; cmp_n <= 4'd0; cmp_i <= 4'd0;
            cmp_busy <= 1'b0;
            nx_d <= 64'd0; nx_k <= 8'h00; nx_n <= 4'd0; nx_v <= 1'b0;
            stat_rx_bytes <= 32'd0; stat_rx_frames <= 32'd0;
            stat_rx_null <= 32'd0; stat_mismatch <= 32'd0;
            led <= 4'd0;
        end else begin
            //=================================================================
            // TX FSM
            //=================================================================
            case (txs)
                T_IDLE: begin
                    // 默认不激活: i_en=0 (未使能) 或 i_tx_ready=0 (peer 表空 =
                    // 未 learn-on-RX) ⇒ 停在这里, m_tvalid 恒 0 ⇒ 下游看不到帧,
                    // 线上零新增 (与 T2 的默认不发送逐位一致)。
                    if (i_en && i_tx_ready) begin
                        seg_len   <= seg_len_n;
                        seg_sent  <= 12'd0;
                        bcnt      <= 4'd0;
                        stg       <= 64'd0;
                        nul_pend  <= (seg_len_n == 12'd0);  // 0 长数据报: 单拍收尾
                        remain    <= rem_eff;              // 首帧 = TX_BYTES, 之后不动
                        first_frm <= 1'b0;
                        txs       <= T_FRM;
                    end
                end
                T_FRM: begin
                    if (!pw_valid) begin
                        if (nul_pend) begin
                            // 0 长数据报: 1 拍 {tkeep=0, tlast=1}
                            // (udp_tx_frame 的 wr 只按 tkeep!=0 ⇒ plen=0 ⇒ 线上 42+8
                            //  字节的合法空数据报; 与 peer --udp-paylen 0 语义一致)
                            pw_data  <= 64'd0;
                            pw_keep  <= 8'h00;
                            pw_n     <= 4'd0;
                            pw_last  <= 1'b1;
                            pw_valid <= 1'b1;
                        end else if (bcnt < need) begin
                            // 产 1 字节 (先取后推进 —— 与 peer/app_pattern 同款;
                            // 超长帧冻结 LFSR, 见 pay_ok)
                            bcnt    <= bcnt + 4'd1;
                            stg     <= {stg[55:0], gen_byte};
                            if (pay_ok) tx_lfsr <= xs_next(tx_lfsr);
                        end else begin
                            // 字凑齐 (bcnt == need != 0) ⇒ 呈交
                            pw_data  <= ljust8(stg, need);
                            pw_keep  <= kmask8(need);
                            pw_n     <= need;
                            pw_last  <= ((seg_sent + {8'b0, need}) >= seg_len);
                            pw_valid <= 1'b1;
                            bcnt     <= 4'd0;
                            stg      <= 64'd0;
                        end
                    end
                    if (pass) begin
                        pw_valid      <= 1'b0;
                        seg_sent      <= seg_sent + {8'b0, pw_n};
                        stat_tx_bytes <= stat_tx_bytes + {28'b0, pw_n};
                        remain        <= rem_n;
                    end
                    if (frm_close) begin
                        stat_tx_frames <= stat_tx_frames + 32'd1;
                        gap_cnt        <= TX_GAP;
                        if (TX_BYTES != 32'd0 && rem_n == 32'd0) begin
                            txs  <= T_DONE;
                            done <= 1'b1;
                        end else begin
                            txs <= T_GAP;
                        end
                    end
                end
                T_GAP: begin
                    // 限速: TX_GAP 个空闲拍后才允许下一帧 (TX_GAP=0 ⇒ 下拍即下一帧)
                    if (gap_cnt != 16'd0) gap_cnt <= gap_cnt - 16'd1;
                    else                  txs     <= T_IDLE;
                end
                default: begin   // T_DONE: 粘滞, 只有复位才能再开
                    txs <= T_DONE;
                end
            endcase

            // active: 发帧中 或 帧间限速间隙 (板级 LED "有会话" 语义)
            active <= (txs == T_FRM) || (txs == T_GAP);

            //=================================================================
            // RX 引擎 (装载与比对并行)
            //=================================================================
            // 装载 (前瞻空位才有 rx_tready ⇒ 与下面的"消费 nx"结构性互斥)
            if (rx_ld) begin
                nx_d <= rx_tdata;
                nx_k <= rx_tkeep;
                nx_n <= pop8(rx_tkeep);
                nx_v <= 1'b1;
            end
            if (cmp_busy) begin
                // 比对 cmp_i 字节 (组合 rx_bad) + 推进/收字
                if (cmp_n == 4'd0) begin
                    // 空拍 (0 长数据报的合成拍, 或 tkeep=0): 无字节可比, 1 拍收
                    if (nx_v) begin
                        cmp_d <= nx_d; cmp_k <= nx_k; cmp_n <= nx_n; cmp_i <= 4'd0;
                        nx_v  <= 1'b0;
                    end else begin
                        cmp_busy <= 1'b0;
                    end
                end else if (cmp_end) begin
                    if (nx_v) begin
                        cmp_d <= nx_d; cmp_k <= nx_k; cmp_n <= nx_n; cmp_i <= 4'd0;
                        nx_v  <= 1'b0;
                    end else begin
                        cmp_busy <= 1'b0;
                    end
                end else begin
                    cmp_i <= cmp_i + 4'd1;
                end
            end else if (nx_v) begin
                cmp_d <= nx_d; cmp_k <= nx_k; cmp_n <= nx_n; cmp_i <= 4'd0;
                cmp_busy <= 1'b1; nx_v <= 1'b0;
            end
            // 期望序列: 未使能 ⇒ 钉 SEED (不校验); 使能 ⇒ 每比一个字节推进 1 步
            if (!i_en)               rx_lfsr <= SEED;
            else if (cmp_hit)        rx_lfsr <= xs_next(rx_lfsr);
            // 统计
            if (cmp_hit)        stat_rx_bytes <= stat_rx_bytes + 32'd1;
            if (rx_bad)         stat_mismatch <= stat_mismatch + 32'd1;
            if (rx_ld && rx_sof) begin
                stat_rx_frames <= stat_rx_frames + 32'd1;
                if (rx_len == 16'd0) stat_rx_null <= stat_rx_null + 32'd1;
            end

            //=================================================================
            // LED (板级可观测): d0 = 曾见 peer (i_tx_ready 锁存)
            //                    d1 = 有活动 (收发)
            //                    d2 = 失配粘滞
            //                    d3 = TX 会话在跑 / 已发完
            //=================================================================
            led[0] <= (led[0] || i_tx_ready);
            led[1] <= (cmp_hit || pass);
            if (stat_mismatch != 32'd0) led[2] <= 1'b1;
            led[3] <= (active || done);
        end
    end
endmodule
