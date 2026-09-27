`timescale 1ns/1ps
//=============================================================================
// udp_split.v — P5e-T1: UDP app 接口**接收侧**分流 shim (仅 APP_MODE 构建使用)
//=============================================================================
// 位置: rx_classify 的 slow 输出 → [本模块] → ① slow_rx_adp (非 app-UDP 帧逐字保真)
//                                              ② udp_rx + 帧缓冲 → app UDP RX 口
//
// 【为什么必须"绝不反压"】(决定性实验 sim/p5e_pre)
//   慢口消费者一旦停, 反压经 rx_classify 传到 mac_rx_64 的 **8 字共享 FIFO**
//   (mac_rx_64.v:227) ⇒ 丢帧, 受害者可以是 fast TCP 帧 (实测 mac_drop=11, 13 帧
//   丢 7)。而 slow_rx_adp 是 `assign s_axis_tready = 1'b1` (故意永不反压) ⇒
//   本模块也不能停: 输入只进预取 FIFO, 装不下时**丢整帧**(绝不吐半帧), 见下。
//
// 【结构】三段, 全 64bit 字流 @125MHz, 每级 II=1:
//
//   ① u_pre: 预取 FIFO (LUTRAM FWFT, 76bit = tdata+tkeep+tlast+tuser+tcrs+terr)
//      输入只写它; 它的**读口同时喂** udp_rx 的 s_axis 与"透传支/分流判据"。
//      ⇒ 两支看到逐位同源的字流 (同一个 pop 流), 且本模块的帧内字计数 pw_cnt 与
//        udp_rx 内部 wcnt 严格同拍 (两者都在 SOP 拍归零、都在同一 accept 拍 +1)。
//      为什么需要它: udp_rx 在 S_TAIL 会给 s_axis_tready=0 (每帧 <=2 拍, 尾字
//      溢出支决定) —— 有预取 FIFO 吸收后, 本模块 s_axis_tready 只在"预取 FIFO
//      满"时为 0, 而这要求 udp_rx 连续停读 >=13 拍, 结构性不可能 (它唯一的停读
//      是 S_TAIL 的 <=2 拍)。⇒ 对外可断言恒 1 (TB 有专项断言)。
//
//   ② UDP 支 u_udp_rx + u_uf (frame_fifo 512 字 = 4KB) + 帧描述符 FIFO + 播放器
//      · udp_rx 的 m_axis_tready **恒 1** ⇒ udp_rx 永不因下游停而反压上游 (它在
//        S_PAY 的 s_axis_tready = `m_ready || !emit_v`)。装不下时本层自己吞字打
//        abort (同 slow_rx_adp 手法), 帧尾整帧回卷, 绝不吐半帧。
//      · 帧级弹性缓冲 (store-and-forward): 整帧收完且通过判据才提交 (commit),
//        提交后由播放器逐字吐到 app RX 口。消费者任意慢只影响本缓冲占用, 反压
//        永不回传 classify/mac_rx。
//      · 消解 udp_rx 两条弱点:
//        (a) "坏 FCS 照交" —— crc_ok 只在 TLAST 拍有效 ⇒ 本层在 TLAST 拍查
//            tuser[0], 坏则整帧回卷 (不提交/不交付/计数 stat_drop_crc);
//        (b) "长度不符 ⇒ 无 TLAST 半帧且无 fend/ferr 告警" —— 本层用"下一帧的
//            meta_valid 拍"作未决帧边界: 未提交残帧一律回卷作废 (stat_drop_part),
//            残字既不进 HLS 也不进 app 口 (零半帧泄漏)。
//      · 0 长数据报 (合法): udp_rx 不产任何载荷字 ⇒ 本层在 fend 拍提交 len=0
//        描述符, 播放器合成 1 拍 null beat (tkeep=0/tlast=1) ⇒ app 口硬不变量
//        "一帧 = >=1 拍, 末拍 tlast, 永不半帧/重复/乱序"。
//      · app 口边带: app_rx_len(载荷字节数, 整帧稳定) + app_rx_sof(帧首拍) +
//        app_rx_src_ip / app_rx_src_port (帧级描述符, 随帧缓冲一起排队)。
//        **不伪造 conn_id/tid** —— UDP 不合流到 TCP 的 AXIS, 无需流标识。
//
//   ③ 透传支 u_pb: 帧首 6 字**先扣住**, 判定后再吐给 slow_rx_adp。
//      · 为何扣 6 字: app-UDP 判定拍 = udp_rx.meta_valid = 帧第 6 字 (w5) 被接受
//        的同一拍 (组合, 短表达式 matched_reg && wcnt==5 && accept)。判为 app ⇒
//        该帧不能进 HLS 慢路径 ⇒ 必须能把已接受的字整帧撤回; 判为 HLS ⇒ 这 6 字
//        按原字节/原拍序/原侧带吐给 slow_rx_adp (含 tuser SOP 位)。
//      · 扣字用"尾区不可弹字数" hold_rem_p (不逐字打标): 弹口 = occ > hold_rem_p;
//        判定拍 hold_rem_p 清零 (HLS 释放) 或整帧回卷 (app 帧)。
//      · 撤回 = 写指针快照/回卷: 帧首字写入同拍 snap, app 判定拍 rollback ⇒
//        该帧已写字节全部作废, **HLS 路径零字节泄漏** (这 6 字从未被弹出过,
//        因为 hold_rem_p 一直挡着, rptr 不可能越过 wsnap)。
//      · 契约: p_axis_tready 必须恒 1 (slow_rx_adp 就是恒 1)。违反时不是反压而是
//        "整帧丢 + 计数": 未释放帧连已写字节一起回卷; 已释放帧无法回撤 ⇒ 余字吞掉,
//        已吐部分对 slow_rx_adp 表现为截断帧 (按它的既有 trunc 语义处理)。
//
//   ④ 学习口 meta_* (P5e-T3 新增, 纯线束): 把 udp_rx 的既有 meta_* 内部信号直接
//      引出 (meta_valid / meta_src_mac / meta_src_ip / meta_src_port / meta_len),
//      在 wrapper 里接到 udp_tx_cfg 的 peer 表写口 = **真正的 learn-on-RX**。
//      零新增逻辑/状态, 不碰上面三条性质 (详见端口注释与 body 末尾的 assign 段)。
//
// 【过滤语义】与 udp_rx 的 cfg_port0..3 / cfg_port_any / cfg_dst_ip /
//   cfg_multi_en 同源。本层额外做 EXCL_PORT 排除 (默认 8080 = HLS udp_echo 端口,
//   侦察 R6): 排除命中时**组合覆盖**送进 udp_rx 的端口配置, 使 port_match 恒不成立
//   (覆盖只在帧的 w4 字 + 本帧确为 IPv4/UDP 时生效, 与 udp_rx 判 port_match 同拍):
//       udp_rx.cfg_port_any = cfg_port_any && !excl_hit
//       udp_rx.cfg_portN    = excl_hit ? ~dst_port : cfg_portN   (恒不相等)
//   ⇒ 该帧在 udp_rx 眼里就是不匹配 (被它吞掉, 计入它的 nonmatch), meta_valid 不
//   脉冲 ⇒ 本层判据自动把它**留给 HLS 慢路径**。
//   app 帧的**唯一判据 = udp_rx 自己的 meta_valid** (单点真值: 不重复实现匹配/
//   校验和逻辑 ⇒ 本层与 udp_rx 不可能判分歧)。
//   默认配置全 0 ⇒ udp_rx 什么都不匹配 ⇒ 本模块对慢路径**逐字透明** (零回归)。
//
// 【统计口径】(32 位)
//   stat_app_frames/bytes/null : 交付 app 口的帧数 / 字节数 / 0 长帧数
//   stat_drop_crc  : app 帧 (匹配) 但 FCS 坏 / rx_er ⇒ 整帧丢弃 (不交付)
//   stat_drop_ovf  : UDP 帧缓冲满 (载荷 FIFO 或描述符 FIFO) ⇒ 整帧丢弃
//   stat_drop_part : 长度不符 / 截断 ⇒ 无 TLAST 的未决残帧被回卷作废
//   stat_drop_excl : 被 EXCL_PORT 排除 (未进匹配, 原样留给 HLS)
//   stat_hls_frames/drop/split : 透传给 slow_rx_adp 的帧数 / 丢弃的 HLS 帧数 /
//                                因判为 app-UDP 而从 HLS 路撤回的帧数
//=============================================================================

//---------------------------------------------------------------------------
// udp_split_fifo — LUTRAM FWFT FIFO + 写指针快照/回卷 (frame_fifo 的 LUTRAM 小深版)
//   · ram_style=distributed 强制 LUTRAM: 防被重映成 BRAM —— P6b 实测 RAMB18E1
//     边存会在板级丢 tlast (单元 TB 摸不出)。
//   · 组合读出 mem[rptr] 天然 FWFT (0 拍延迟); 写址 wptr / 读址 rptr 分离 ⇒
//     读到同拍被写的槽只可能发生在"空 FIFO 首次写入"那拍 (此时 empty=1,
//     消费端不看 dout), 下一拍即正确 ⇒ 无需 bypass 逻辑。
//   · snap: 锁当前 wptr (即本拍写入字所在槽) 作回卷边界; rollback: wptr 回 wsnap,
//     该帧已写字全部作废。**回卷拍与写拍不重合** (本模块按构造保证 + 下拍兜底)。
//---------------------------------------------------------------------------
module udp_split_fifo #(
    parameter W  = 76,
    parameter D  = 32,
    parameter AW = 5
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         wr,
    input  wire [W-1:0] din,
    input  wire         snap,
    input  wire         rollback,
    input  wire         rd,
    output wire [W-1:0] dout,
    output wire         empty,
    output wire         full,
    output wire [AW:0]  dbg_wptr,
    output wire [AW:0]  dbg_rptr
);
    (* ram_style = "distributed" *) reg [W-1:0] mem [0:D-1];
    reg [AW:0] wptr, rptr, wsnap;

    // full 用真满式 (与 fifo_sync/frame_fifo 同式): "+1 保守式" 在 rptr 低位==0
    // 的窗口内永不触发 ⇒ 写入绕回踩槽 (P4a slowrx 单元门实锤)。
    wire        full_n  = (wptr[AW-1:0] == rptr[AW-1:0]) && (wptr[AW] != rptr[AW]);
    wire        empty_n = (wptr == rptr);
    wire        rd_ok   = rd && !empty_n;
    wire        wr_ok   = wr && !full_n;
    wire [AW:0] rptr_n  = rptr + (rd_ok ? 1'b1 : 1'b0);
    wire [AW:0] wptr_n  = wptr + (wr_ok ? 1'b1 : 1'b0);

    // mem 独立无复位块 (LUTRAM 推断前提)
    always @(posedge clk) begin
        if (wr_ok) mem[wptr[AW-1:0]] <= din;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= {(AW+1){1'b0}}; rptr <= {(AW+1){1'b0}};
            wsnap <= {(AW+1){1'b0}};
        end else begin
            if (rollback) wptr <= wsnap;
            else          wptr <= wptr_n;
            if (rd_ok) rptr <= rptr_n;
            if (snap)  wsnap <= wptr;      // 本拍写入字所在槽 = 回卷边界
        end
    end

    assign dout     = mem[rptr[AW-1:0]];
    assign empty    = empty_n;
    assign full     = full_n;
    assign dbg_wptr = wptr;
    assign dbg_rptr = rptr;
endmodule

//=============================================================================
// udp_split — 顶层
//=============================================================================
module udp_split #(
    // 排除端口 (0 = 关闭排除)。默认 8080 = HLS udp_echo 端口 (侦察 R6):
    // 使 "cfg_port_any=1 全收" 这类 app 配置也不会抢走 HLS 的 echo 帧。
    parameter [15:0] EXCL_PORT = 16'd8080,
    parameter        PRE_AW    = 4,     // 预取 FIFO 深 16
    parameter        PB_AW     = 5,     // 透传暂存深 32
    parameter        DESC_AW   = 6,     // 帧描述符深 64
    parameter        UDP_AW    = 9      // UDP 载荷帧缓冲深 512 字 (= 4KB)
) (
    input  wire        clk,
    input  wire        rst_n,
    // ---- 来自 rx_classify 的 slow 输出 (与 slow_rx_adp 输入同构) ----
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,   // 结构性恒 1 (见头注释; TB 有专项断言)
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,    // SOP
    input  wire        s_axis_tcrs,     // TLAST: FCS 正确
    input  wire        s_axis_terr,     // TLAST: rx_er
    // ---- 透传输出 → slow_rx_adp (非 app-UDP 帧逐字节/逐拍/侧带保真) ----
    output wire [63:0] p_axis_tdata,
    output wire [7:0]  p_axis_tkeep,
    output wire        p_axis_tvalid,
    input  wire        p_axis_tready,   // 契约: 恒 1 (slow_rx_adp)
    output wire        p_axis_tlast,
    output wire        p_axis_tuser,
    output wire        p_axis_tcrs,
    output wire        p_axis_terr,
    // ---- app UDP RX 口 (帧级缓冲后直出; 一帧 = 1..N 拍, 末拍 tlast) ----
    output wire [63:0] app_rx_tdata,
    output wire [7:0]  app_rx_tkeep,
    output wire        app_rx_tvalid,
    input  wire        app_rx_tready,
    output wire        app_rx_tlast,
    output wire        app_rx_sof,       // 帧首拍 (与 tvalid 同拍)
    output wire [15:0] app_rx_len,       // 本帧载荷字节数 (整帧稳定; 0 = null beat)
    output wire [31:0] app_rx_src_ip,    // 本帧 peer IP   (整帧稳定)
    output wire [15:0] app_rx_src_port,  // 本帧 peer 端口 (整帧稳定)
    // ---- P5e-T3: RX 学习事件 (meta 线束输出 → wrapper 的 udp_tx_cfg.peer_wr) ----
    // 纯线束引出: 直接连到 udp_rx 的既有 meta_* 内部信号 (**零新增逻辑/零新增状态/
    // 零新增寄存器** —— 见下面 body 里的 5 条 assign)。语义 = "本帧已被 udp_rx 判为
    // app-UDP 且头字段收全" (meta_valid = 匹配帧 w5 接受拍的单拍组合脉冲);
    // src_mac/ip/port/len 在该拍已由 udp_rx 寄存就绪, 整拍稳定 ⇒ 可直接当
    // peer 表写口的同拍数据源 (udp_tx_cfg 在 peer_wr 沿采 peer_mac/peer_ip)。
    // 【为什么这修好了 T2 的缺口】T2 用慢路径 CONN_UP (scfg_ev_*) 当学习源 ——
    //   UDP 无连接 ⇒ 板级永不产生 CONN_UP ⇒ peer 表永远空 ⇒ UDP TX 永不激活
    //   (T2 的"默认不发送"在板上退化成"永不发送")。本口给出**真正的 learn-on-RX**:
    //   收到对端一帧 ⇒ 立刻学到 (mac, ip) ⇒ 下一帧即可回发。
    // 【安全论证】(a) 输出口 + 命名端口例化 ⇒ T1/T2 既有例化点 (tb_udp_split/
    //   sim/p5e_pre 的副本) 不接本口只是 unconnected 警告, 行为逐位不变;
    //   (b) 它是既有内部信号的线束, 不反压、不改时序路径 (只多几个扇出);
    //   (c) ⚠️ 已知语义边界: FCS 要到 TLAST 拍才知道 ⇒ **坏 FCS 帧同样脉冲**
    //   (该帧随后被本层整帧丢弃, stat_drop_crc)。学习语义上可接受: 头字段已过
    //   IP 校验和 + 端口匹配, 且下一好帧即覆盖。要"仅好帧才学"必须把 meta 缓存
    //   到 TLAST —— 那是新增状态, 明确不在本口合同内。
    output wire        meta_valid,       // = udp_rx.meta_valid (匹配帧 w5 接受拍脉冲)
    output wire [47:0] meta_src_mac,     // = udp_rx.meta_src_mac (对端 MAC)
    output wire [31:0] meta_src_ip,      // = udp_rx.meta_src_ip  (对端 IP)
    output wire [15:0] meta_src_port,    // = udp_rx.meta_src_port(对端端口)
    output wire [15:0] meta_len,         // = udp_rx.meta_len (本帧载荷字节数)
    // ---- 过滤配置 (语义同 udp_rx; 排除端口由 EXCL_PORT 参数下发) ----
    input  wire [31:0] cfg_dst_ip,
    input  wire        cfg_multi_en,
    input  wire [15:0] cfg_port0, cfg_port1, cfg_port2, cfg_port3,
    input  wire        cfg_port_any,
    // ---- 统计 ----
    output reg  [31:0] stat_app_frames, stat_app_bytes, stat_app_null,
    output reg  [31:0] stat_drop_crc, stat_drop_ovf, stat_drop_part,
    output reg  [31:0] stat_drop_excl,
    output reg  [31:0] stat_hls_frames, stat_hls_drop, stat_hls_split
`ifdef RXP_DIAG
    //=========================================================================
    // RXP_DIAG v3 (2026-09-26): 帧边界记账可见化 (ISSUE_RX_BYTE_CORRUPTION §13)
    //=========================================================================
    // 端口**一律追加在端口表末尾** (既有例化点按名连接 ⇒ 不接只是 unconnected
    // 警告; 插在中间则任何按位置例化的调用点会静默接错)。除 ds_cap 外全部是
    // 输出 (纯观测), 且整段只在 `RXP_DIAG 下达: 默认/P5 构建端口表逐位不变。
    // 各字段的语义/宽度/偏移见 rtl/app_status_uart.v 的 v3 段注释 (真值源在那)。
    //
    // v3 输入: 首失配触发脉冲 (来自 app_udp_pattern.ds_cap, 与 v2 整字快照同拍)
    , input  wire               ds_cap
    // v3 输出 ①: 写侧指纹 —— "播放器正在播的这帧, 它的第一个数据字写进口是什么"
    , output reg  [63:0]        v3_sw        // = SW
    , output reg  [UDP_AW-1:0]  v3_sf        // = SF (该字写入的槽址; 与 FR 低 9 位对账)
    , output reg                v3_sm        // = SM (1 = 命中/有效)
    , output reg  [7:0]         v3_wd        // = WD (帧首拍写侧领先帧数)
    // v3 输出 ②: 帧首记录 (current) / 上一帧 (prev) —— 均为 ds_cap 拍锁存值
    , output reg  [UDP_AW:0]    v3_fr, v3_fw, v3_fo, v3_fh
    , output reg  [1:0]         v3_fs
    , output reg  [15:0]        v3_fn
    , output reg  [UDP_AW:0]    v3_pr, v3_pw, v3_ph
    // v3 输出 ③: 首失配当拍的**活值**
    , output reg  [UDP_AW:0]    v3_lr, v3_lw, v3_lo, v3_lh
    // v3 输出 ④: 回卷一致性 (回卷是否吃掉已提交未读数据)
    , output reg  [15:0]        v3_rc, v3_vc        // 回卷次数 / 违例次数
    , output reg  [UDP_AW:0]    v3_vx              // 违例时: (wptr-wsnap)-hold_rem
    , output reg  [UDP_AW:0]    v3_vs              // 违例时: wsnap
    , output reg  [UDP_AW:0]    v3_vr              // 违例时: uf_rptr
    , output reg  [15:0]        v3_vn              // 违例时: 写侧提交序号
    // ---- RXP_DIAG v4 (2026-09-27): 异常帧路径计数器 (ISSUE_RX_BYTE_CORRUPTION §16.7) ----
    // 目的: §16.1 判死"坏字在写进 u_uf 时就已经是坏的", 但**这些分叉有没有在触发**
    //   一直是空白 —— 本组计数器把每条"载荷已写、帧未提交/帧归属异常"的路径变成
    //   可观测量。判据: 某个计数器的本轮值 == 该轮的 n (受损帧数) ⇒ 它就是根因。
    // 语义/口径见 body 末尾的 v4 段 (真值源在那里); 键名 CN/RD/NC/NP/WF/RL/WC
    // (与既有键全部不撞, 由 sim/rxpdiag/gen_offsets.py 做正则级遮蔽检查)。
    , output reg  [15:0]        v4_cn       // CN: 描述符 FIFO 满 ⇒ 本帧回卷 (u_commit_no)
    , output reg  [15:0]        v4_rd       // RD: 残帧边界回卷 (u_residue)
    , output reg  [15:0]        v4_nc       // NC: 0 长数据报事件 (u_nul_cyc)
    , output reg  [15:0]        v4_np       // NP: 0 长数据报提交 (u_nul_commit)
    , output reg  [15:0]        v4_wf       // WF: uf_ovf 拍数 (= 因满被吞的载荷**字数**)
    , output reg  [15:0]        v4_rl       // RL: uf_rollbk 拍数 (= 回卷次数, 与 v3 的 RC 同源)
    , output reg  [15:0]        v4_wc       // WC: 字数一致性违例 (提交拍 写字数 != ceil(len/8))
    // ---- RXP_DIAG v5 (2026-09-27): **写数据口 (din) 上的第二个 LFSR 校验器** ----
    // (ISSUE_RX_BYTE_CORRUPTION §14.6/§18.8; 目的见 body 末尾的 v5 段 —— 真值源在那里)
    // 与 app 的校验器**机制不同**: app 用 `wh_word[w_commit_cnt[2:0]]` 按**帧号索引**
    //   定址 (v3 的 SW), 而本组靠**纯字节计数**推进 —— 这正是它能**证伪** SW 归因假设
    //   的地方 (SW 的采集依赖"载荷字不与 meta_valid 同拍"这条无法从 TB 构造的假设)。
    // 键名 DV/DG/DE/DO/DM/VZ (A 部) 与 PS/NM/IC/DC/SB (B 部); 与既有全部键不撞,
    //   由 sim/rxpdiag/gen_offsets.py 做正则级遮蔽检查 (该脚本的断言是硬失败)。
    , output wire [31:0]        v5_dv_idx   // DV: 首个失配处的**累计字节序号** (纯计数锚)
    , output wire [7:0]         v5_dv_got   // DG: 该处收到的字节
    , output wire [7:0]         v5_dv_exp   // DE: 该处期望的字节 (LFSR)
    , output wire [15:0]        v5_dv_off   // DO: 该失配在本帧内的字节偏移
    , output wire [31:0]        v5_dv_mm    // DM: 失配字节总数 (整轮累计)
    , output wire               v5_dv_v     // VZ: 快照有效 (粘滞, 只记首个)
    // ---- RXP_DIAG v5 B 部: 解析器 (udp_rx) 的**已声明但从未显示**的计数器 ----
    // 零新逻辑: 它们本来就在本模块里 (内部悬空未用), 这里只是**接线到端口**。
    // 判据: PS (stat_pass) vs app 的 URF —— 不等 ⇒ 解析器与 app 之间有丢帧/重帧。
    , output wire [31:0]        v5_up_pass  // PS: udp_rx.stat_pass      (匹配且 FCS 好)
    , output wire [31:0]        v5_up_nm    // NM: udp_rx.stat_drop_nonmatch
    , output wire [31:0]        v5_up_ipc   // IC: udp_rx.stat_drop_ipcsum
    , output wire [31:0]        v5_up_crc   // DC: udp_rx.stat_drop_crc
    , output wire [31:0]        v5_up_bytes // SB: udp_rx.stat_bytes     (匹配帧的载荷字节)
    // ---- RXP_DIAG v6 (2026-09-27): **u_pre 输入侧** (s_axis) 的第三个 LFSR 校验器 ----
    // (ISSUE_RX_BYTE_CORRUPTION §18.9/§18.10; 目的/口径见 body 末尾的 v6 段 —— 真值源在那里)
    // 这是 §18.9 那个"三者不能同时为真"矛盾的裁决点: u_pre 的输入是整条链上**唯一
    //   还没插桩的流**。与 v5 (din = u_m_d, 写侧) 与 app (读侧) 都不同源:
    //     · v6 在**进 u_pre 之前** (s_axis), 即 u_uf 的三个上游模块 (mac_rx_64 的 8 字
    //       FIFO / rx_classify 的 6 字 skid / vlan_strip 直通) 之下游、u_pre 之上游。
    //   键名 CV/CG/CE/CO/CM/CZ/CS —— 与既有全部键不撞 (由 sim/rxpdiag/gen_offsets.py
    //   做正则级遮蔽检查, 断言是硬失败)。
    , output wire [31:0]        v6_dv_idx   // CV: 首个失配处的**累计载荷字节序号** (纯计数锚)
    , output wire [7:0]         v6_dv_got   // CG: 该处收到的字节
    , output wire [7:0]         v6_dv_exp   // CE: 该处期望的字节 (LFSR)
    , output wire [15:0]        v6_dv_off   // CO: 该失配的**帧内**字节偏移 (= 帧内序号 - 42)
    , output wire [31:0]        v6_dv_mm    // CM: 失配字节总数 (整轮累计)
    , output wire               v6_dv_v     // CZ: 快照有效 (粘滞, 只记首个)
    , output wire [7:0]         v6_dv_sk    // CS: 因输入 skid 满而**被丢掉的字数** (非 0 = 本
                                            //     轮 v6 读数不可用; 输入侧不能反压 ⇒ 只能丢)
`endif
);

    //=========================================================================
    // 线网声明 (先声明后用: wrapper_tcp.v 的先使用后声明靠 Vivado 宽容过关,
    // xvlog 直接报错 —— 本文件全部前置声明)
    //=========================================================================
    // ① 预取支
    wire        pre_empty, pre_full, pre_pop;
    wire [75:0] pre_dout;
    wire [63:0] f_d;      // tdata
    wire [7:0]  f_k;      // tkeep
    wire        f_l, f_u, f_c, f_e;   // tlast / tuser(SOP) / tcrs / terr
    wire        s_acc;
    // ② UDP 支
    wire        u_rx_tready;
    wire [63:0] u_m_d;
    wire [7:0]  u_m_k;
    wire        u_m_v, u_m_l;
    wire [1:0]  u_m_u;
    wire        u_fend, u_ferr, u_meta_valid;
    wire [47:0] u_meta_src_mac;
    wire [31:0] u_meta_src_ip;
    wire [15:0] u_meta_src_port, u_meta_len;
    wire [31:0] u_stat_pass, u_stat_nm, u_stat_ipc, u_stat_crc, u_stat_bytes;
    wire        uf_full, uf_empty;
    wire [72:0] uf_dout;
    wire [UDP_AW:0] uf_wptr, uf_rptr, uf_occ;
    wire        uf_wr, uf_snap, uf_rollbk, uf_rd;
    wire [63:0] desc_dout;
    wire        desc_empty, desc_full, desc_pop;
    // ③ 透传支
    wire [PB_AW:0] pb_wptr, pb_rptr, pb_occ;
    wire        pb_empty, pb_full;
    wire [75:0] pb_dout;
    wire        pb_wr, pb_snap, pb_rollbk, pb_pop;
    wire        pb_valid;
    // 判据
    reg  [3:0]  pw_cnt;
    wire [3:0]  pw_idx, pw_cnt_n;
    wire        pw_sop_w;
    wire        u_wr_evt;       // udp_rx 载荷字真正写入 (非满且本帧未废)

    //=========================================================================
    // ① 预取 FIFO: 输入只写它; 读口同时喂 udp_rx 与透传/判据支
    //=========================================================================
    // 输入侧永不反压: 只在预取 FIFO 真满时为 0 (深 16, 而 udp_rx 唯一停读是
    // S_TAIL 的 <=2 拍 ⇒ 占用 <=3, 结构性不可能满)
    assign s_axis_tready = !pre_full;
    assign s_acc         = s_axis_tvalid && s_axis_tready;

    udp_split_fifo #(.W(76), .D(16), .AW(PRE_AW)) u_pre (
        .clk(clk), .rst_n(rst_n),
        .wr(s_acc),
        .din({s_axis_tdata, s_axis_tkeep, s_axis_tlast, s_axis_tuser,
              s_axis_tcrs, s_axis_terr}),
        .snap(1'b0), .rollback(1'b0),
        .rd(pre_pop), .dout(pre_dout), .empty(pre_empty), .full(pre_full),
        .dbg_wptr(), .dbg_rptr()
    );

    assign f_d = pre_dout[75:12];
    assign f_k = pre_dout[11:4];
    assign f_l = pre_dout[3];
    assign f_u = pre_dout[2];
    assign f_c = pre_dout[1];
    assign f_e = pre_dout[0];

    // 弹出 = udp_rx 真正接受的字 (两支同源: 透传支/判据支只看这个流)
    assign pre_pop   = !pre_empty && u_rx_tready;

    // 帧内字计数 (与 udp_rx.wcnt 严格同拍: 同一个 pop 流, 同样 SOP 归零)
    //   消费第 k 字时 pw_cnt = k (SOP 字 = 0), 与 udp_rx "wcnt = 下一个字索引"
    //   的约定一致 (它在 SOP 拍置 wcnt=1, 消费 w1 时 wcnt==1)。
    assign pw_sop_w = pre_pop && f_u;
    assign pw_idx   = pw_sop_w ? 4'd0 : pw_cnt;
    assign pw_cnt_n = pw_sop_w ? 4'd1 : ((pw_cnt == 4'd15) ? 4'd15 : pw_cnt + 4'd1);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            pw_cnt <= 4'd0;
        else if (pre_pop)      pw_cnt <= pw_cnt_n;
    end

    //=========================================================================
    // 排除端口 (EXCL_PORT): 只在帧 w4 字 + 本帧确为 IPv4/UDP 时生效
    //=========================================================================
    reg  ip4_45_r, udp_r_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin ip4_45_r <= 1'b0; udp_r_r <= 1'b0; end
        else if (pre_pop) begin
            if (pw_idx == 4'd1)     // w1: ethertype + ver/ihl
                ip4_45_r <= (f_d[31:16] == 16'h0800) && (f_d[15:8] == 8'h45);
            if (pw_idx == 4'd2)     // w2: proto == 17
                udp_r_r  <= ip4_45_r && (f_d[7:0] == 8'h11);
        end
    end

    wire        w4_cyc   = pre_pop && (pw_idx == 4'd4);
    wire [15:0] w4_dport = f_d[31:16];   // 帧 byte36-37 (udp_rx 的 port_match 字段)
    wire [15:0] w4_sport = f_d[47:32];   // 帧 byte34-35
    wire        excl_hit = (EXCL_PORT != 16'd0) && w4_cyc && udp_r_r &&
                           ((w4_dport == EXCL_PORT) || (w4_sport == EXCL_PORT));

    wire        u_cfg_port_any = cfg_port_any && !excl_hit;
    wire [15:0] u_cfg_port0 = excl_hit ? ~w4_dport : cfg_port0;
    wire [15:0] u_cfg_port1 = excl_hit ? ~w4_dport : cfg_port1;
    wire [15:0] u_cfg_port2 = excl_hit ? ~w4_dport : cfg_port2;
    wire [15:0] u_cfg_port3 = excl_hit ? ~w4_dport : cfg_port3;

    //=========================================================================
    // ② UDP 支: udp_rx (P1 验证过的模块, 零改动复用)
    //    m_axis_tready 恒 1 ⇒ 它永不反压上游 (关键约束的结构性保证)
    //=========================================================================
    udp_rx u_udp_rx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(f_d), .s_axis_tkeep(f_k),
        .s_axis_tvalid(!pre_empty), .s_axis_tready(u_rx_tready),
        .s_axis_tlast(f_l), .s_axis_tuser(f_u),
        .s_axis_tcrs(f_c), .s_axis_terr(f_e),
        .m_axis_tdata(u_m_d), .m_axis_tkeep(u_m_k),
        .m_axis_tvalid(u_m_v),
        .m_axis_tready(1'b1),          // 恒 1: 装不下由本层吞字+整帧回卷
        .m_axis_tlast(u_m_l), .m_axis_tuser(u_m_u),
        .fend(u_fend), .ferr(u_ferr),
        .meta_valid(u_meta_valid),
        .meta_src_mac(u_meta_src_mac), .meta_src_ip(u_meta_src_ip),
        .meta_src_port(u_meta_src_port), .meta_len(u_meta_len),
        .cfg_dst_ip(cfg_dst_ip), .cfg_multi_en(cfg_multi_en),
        .cfg_port0(u_cfg_port0), .cfg_port1(u_cfg_port1),
        .cfg_port2(u_cfg_port2), .cfg_port3(u_cfg_port3),
        .cfg_port_any(u_cfg_port_any),
        .stat_pass(u_stat_pass), .stat_drop_nonmatch(u_stat_nm),
        .stat_drop_ipcsum(u_stat_ipc), .stat_drop_crc(u_stat_crc),
        .stat_bytes(u_stat_bytes)
    );

    // ---- 载荷帧缓冲 (frame_fifo: RAMB36 主存 + LUTRAM 边存, 含 snap/回卷) ----
    frame_fifo #(.W(73), .D(512), .AW(UDP_AW)) u_uf (
        .clk(clk), .rst_n(rst_n),
        .wr(uf_wr), .din({u_m_l, u_m_k, u_m_d}),
        .snap(uf_snap), .rollback(uf_rollbk),
        .rd(uf_rd), .dout(uf_dout), .empty(uf_empty), .full(uf_full),
        .dbg_wptr(uf_wptr), .dbg_rptr(uf_rptr), .dbg_empty(),
        .dbg_rd_addr({UDP_AW{1'b0}}), .dbg_rd_side()
    );
    assign uf_occ = uf_wptr - uf_rptr;

    // ---- 帧级状态 ----
    reg  [UDP_AW:0] hold_rem_u;   // 本(未提交)帧已写字数 = 尾区不可弹字数
    reg             u_open_r;     // 已开帧 (meta_valid 起) 未提交/回卷
    reg             u_snpend_r;   // 残帧回卷后下拍补 snap (回卷+snap 不可同拍)
    reg             u_abort_r;    // 本帧已写坏 (FIFO 满吞字)
    reg             u_rollpend_r; // 回卷请求与写字同拍 ⇒ 顺延一拍执行

    wire        u_word   = u_m_v;                     // tready 恒 1 ⇒ 恒被接受
    wire        u_end    = u_word && u_m_l;           // 本帧最后一个载荷字
    wire        u_uncrc  = !u_m_u[0] || u_m_u[1];     // FCS 坏 / rx_er
    wire        uf_ovf   = u_word && uf_full;         // 想写但满 ⇒ 本帧废

    // 0 长数据报: 无载荷字, 由 fend 拍提交/丢弃 (meta_len 帧内保持有效)
    wire        u_nul_cyc    = u_fend && (u_meta_len == 16'd0);
    wire        u_nul_commit = u_nul_cyc && !u_ferr;
    wire        u_nul_kill   = u_nul_cyc &&  u_ferr;

    wire        uf_commit_word = u_end && !u_uncrc && !u_abort_r && !uf_full;
    wire        uf_kill_word   = u_end && (u_uncrc || u_abort_r || uf_full);

    // 未决残帧 (长度不符/截断 ⇒ 无 TLAST ⇒ 永远不会有 TLAST 字/fend):
    // 由**下一帧的 meta_valid 拍**作边界 —— 彼时本帧已写字全部写完 (新帧载荷字
    // 最早在 meta_valid+1 拍出现), 回卷安全。
    wire        u_residue = u_meta_valid && u_open_r;

    // 描述符 FIFO (帧级元数据 {src_ip, src_port, len}; 提交拍入队, 播放器起播拍出队)
    wire        u_commit_evt = uf_commit_word || u_nul_commit;
    // 组合下发 (与 full 同拍判定): 提交/入队不可能因中间拍满而分叉
    wire        desc_wr = u_commit_evt && !desc_full;
    wire        u_commit_ok = desc_wr;
    wire        u_commit_no = u_commit_evt && desc_full;

    udp_split_fifo #(.W(64), .D(64), .AW(DESC_AW)) u_desc (
        .clk(clk), .rst_n(rst_n),
        .wr(desc_wr),
        .din({u_meta_src_ip, u_meta_src_port, u_meta_len}),
        .snap(1'b0), .rollback(1'b0),
        .rd(desc_pop), .dout(desc_dout), .empty(desc_empty), .full(desc_full),
        .dbg_wptr(), .dbg_rptr()
    );

    // 回卷请求 (三种: 坏帧尾 / 描述符满 / 残帧边界), 与写字同拍则顺延一拍
    wire        uf_roll_req = uf_kill_word || u_commit_no || u_residue;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                   u_rollpend_r <= 1'b0;
        else if (uf_roll_req && uf_wr) u_rollpend_r <= 1'b1;
        else if (u_rollpend_r)         u_rollpend_r <= 1'b0;
    end
    assign uf_rollbk = (uf_roll_req && !uf_wr) || u_rollpend_r;
    assign uf_snap   = (u_meta_valid && !u_open_r) || u_snpend_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_rem_u <= {(UDP_AW+1){1'b0}};
            u_abort_r  <= 1'b0; u_open_r <= 1'b0; u_snpend_r <= 1'b0;
            stat_drop_crc <= 32'd0; stat_drop_ovf <= 32'd0;
            stat_drop_part <= 32'd0; stat_drop_excl <= 32'd0;
            stat_app_null <= 32'd0;
        end else begin
            // 开帧/收帧
            // 0 长数据报的特例: 它的 meta_valid 与 fend 同拍 (w5 即帧尾) ⇒ 该拍
            // 就是"开帧即收帧", 优先级必须给"收" —— 否则 u_open_r 挂住 ⇒ 下一帧
            // 误判为残帧边界 (实测多算一次 stat_drop_part)。
            if (u_nul_cyc) begin
                u_open_r    <= 1'b0;
                u_snpend_r  <= u_residue;      // 前帧残帧回卷 ⇒ 下拍仍补 snap
            end else if (u_meta_valid) begin
                u_open_r    <= 1'b1;
                u_snpend_r  <= u_residue;      // 残帧 ⇒ 下拍补 snap (此拍已回卷)
            end else if (u_end) begin
                u_open_r    <= 1'b0;
                u_snpend_r  <= 1'b0;
            end else if (u_snpend_r) begin
                u_snpend_r  <= 1'b0;
            end
            // 尾区不可弹字数 (提交拍立即释放; 回卷路径等到回卷真正落地才释放 ——
            // 顺延的那一拍里尾区词还在 FIFO 里, 保持"不可弹"即无窗口)
            if (u_meta_valid || u_nul_cyc || uf_rollbk || (u_end && !uf_roll_req))
                hold_rem_u <= {(UDP_AW+1){1'b0}};
            else if (u_wr_evt)
                hold_rem_u <= hold_rem_u + 1'b1;
            // 吞字标记 (FIFO 满 ⇒ 本帧余字全吞; 帧尾/新帧起点清除)
            if (uf_ovf)                              u_abort_r <= 1'b1;
            else if (u_end || u_nul_cyc || u_meta_valid) u_abort_r <= 1'b0;
            // 统计 (丢弃原因互斥: 满优先 —— 保证 "判定数 == 交付数 + 三个丢弃
            // 计数之和" 的划分式成立, TB 有该恒等式断言)
            if (u_end && (uf_full || u_abort_r))      stat_drop_ovf <= stat_drop_ovf + 32'd1;
            else if (u_end && u_uncrc)                stat_drop_crc <= stat_drop_crc + 32'd1;
            if (u_nul_kill)                           stat_drop_crc <= stat_drop_crc + 32'd1;
            if (u_residue)                            stat_drop_part <= stat_drop_part + 32'd1;
            if (excl_hit)                             stat_drop_excl <= stat_drop_excl + 32'd1;
            if (u_nul_commit && !desc_full)           stat_app_null <= stat_app_null + 32'd1;
        end
    end

    // 写入: 满或本帧已废则不写 (吞字); 绝不因此让 udp_rx 停流
    assign u_wr_evt = u_word && !uf_full && !u_abort_r;
    assign uf_wr    = u_wr_evt;

    //=========================================================================
    // app RX 播放器: 描述符 FIFO → 载荷帧缓冲 → app 口
    //   一帧 = 描述符 1 条 + 载荷 ceil(len/8) 字; len==0 ⇒ 合成 1 拍 null beat。
    //   弹口门 = occ > hold_rem_u (只弹"已提交前缀") ⇒ 残帧/在收帧永不可见。
    //=========================================================================
    localparam [1:0] R_IDLE = 2'd0, R_PLAY = 2'd1, R_NULL = 2'd2;
    reg  [1:0]  rstate;
    reg  [15:0] len_r, sport_r;
    reg  [31:0] sip_r;
    reg         any_r;         // 本帧已吐过至少一拍 (sof 生成)
    reg         desc_pop_r;
    wire        play_gate = (uf_occ > hold_rem_u);
    wire        play_v    = (rstate == R_PLAY) && !uf_empty && play_gate;

    // 组合弹口 (工程坑 4: 寄存器化 rd 会让数据挂 2 拍被标准消费者双采 ⇒ 每词重复)
    assign uf_rd    = play_v && app_rx_tready;
    assign desc_pop = desc_pop_r;
    assign app_rx_tvalid = (rstate == R_PLAY) ? play_v :
                           (rstate == R_NULL) ? 1'b1 : 1'b0;
    assign app_rx_tdata  = (rstate == R_NULL) ? 64'd0  : uf_dout[63:0];
    assign app_rx_tkeep  = (rstate == R_NULL) ? 8'h00  : uf_dout[71:64];
    assign app_rx_tlast  = (rstate == R_NULL) ? 1'b1   : uf_dout[72];
    assign app_rx_sof    = app_rx_tvalid && !any_r;
    assign app_rx_len       = len_r;
    assign app_rx_src_ip    = sip_r;
    assign app_rx_src_port  = sport_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate <= R_IDLE; len_r <= 16'd0; sport_r <= 16'd0; sip_r <= 32'd0;
            any_r <= 1'b0; desc_pop_r <= 1'b0;
            stat_app_frames <= 32'd0; stat_app_bytes <= 32'd0;
        end else begin
            desc_pop_r <= 1'b0;
            case (rstate)
                R_IDLE: if (!desc_empty) begin
                    desc_pop_r <= 1'b1;
                    sip_r   <= desc_dout[63:32];
                    sport_r <= desc_dout[31:16];
                    len_r   <= desc_dout[15:0];
                    any_r   <= 1'b0;
                    rstate  <= (desc_dout[15:0] == 16'd0) ? R_NULL : R_PLAY;
                end
                R_NULL: if (app_rx_tready) begin
                    rstate <= R_IDLE;
                    stat_app_frames <= stat_app_frames + 32'd1;
                end
                R_PLAY: if (play_v && app_rx_tready) begin
                    any_r <= 1'b1;
                    if (uf_dout[72]) begin
                        rstate <= R_IDLE;
                        stat_app_frames <= stat_app_frames + 32'd1;
                        stat_app_bytes  <= stat_app_bytes + {16'd0, len_r};
                    end
                end
                default: rstate <= R_IDLE;
            endcase
        end
    end

    //=========================================================================
    // ③ 透传支: 帧首 6 字扣住 → 判定 (app ⇒ 整帧回卷 + 吞余字; HLS ⇒ 释放)
    //=========================================================================
    reg  [PB_AW:0] hold_rem_p;  // 尾区不可弹字数 (本帧未判定的已写字数, <=6)
    reg            dec_p_r;     // 本帧判定已发生 (释放/丢弃); SOP 拍清零
    reg            rel_r;       // 本帧已判为 HLS (释放)
    reg            swallow_r;   // 本帧余字吞掉 (app 帧 / 缓冲满丢弃)
    reg            ovf_r;       // 本帧因透传缓冲满被丢弃 (HLS 路真丢帧)
    reg            app_sel_r;   // 本帧被 udp_rx 判为 app (meta_valid 寄存, SOP 清零)
    reg            pb_rollpend_r;

    // 判定拍: 本帧第 6 字 (pw_idx==5, 与 udp_rx 的 wcnt==5/meta_valid 同拍)
    //         或帧尾 (短帧/残缺帧 —— 匹配至少需要 6 个头字, 故必非 app)
    wire        pb_dec_cyc = pre_pop && (f_l || (pw_idx == 4'd5));
    wire        pb_dec_app = pb_dec_cyc && !swallow_r && (app_sel_r || u_meta_valid);

    wire        pb_ovf     = pre_pop && pb_full && !swallow_r;
    wire        pb_roll_req= pb_dec_app || (pb_ovf && !rel_r);
    wire        pb_swallow_set = pb_dec_app || pb_ovf;
    // 新帧首字或帧尾结束吞字; 满丢弃拍不清 (否则该帧首字已丢却当成新帧续上)
    wire        pb_swallow_clr = pre_pop && (f_l || f_u) && !pb_ovf;
    wire        pb_wr_now  = pre_pop && !pb_full && !pb_dec_app &&
                             (f_u || !swallow_r);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pb_rollpend_r <= 1'b0; app_sel_r <= 1'b0;
        end else begin
            if (pb_roll_req && pb_wr_now)  pb_rollpend_r <= 1'b1;
            else if (pb_rollpend_r)        pb_rollpend_r <= 1'b0;
            // app 帧判据 (单点真值 = udp_rx.meta_valid), SOP 拍清零防跨帧残留
            if (pw_sop_w)                  app_sel_r <= u_meta_valid;
            else if (u_meta_valid)         app_sel_r <= 1'b1;
        end
    end
    wire pb_rollbk_now = (pb_roll_req && !pb_wr_now) || pb_rollpend_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_rem_p <= {(PB_AW+1){1'b0}};
            dec_p_r <= 1'b0; rel_r <= 1'b0; swallow_r <= 1'b0; ovf_r <= 1'b0;
            stat_hls_frames <= 32'd0; stat_hls_drop <= 32'd0; stat_hls_split <= 32'd0;
        end else begin
            // 吞字标记: 帧尾或新帧首字 (残缺帧兜底) 清除
            if (pb_swallow_clr)      swallow_r <= 1'b0;
            else if (pb_swallow_set) swallow_r <= 1'b1;
            // 满丢弃标记 (只在真丢帧时计 stat_hls_drop; app 帧的吞字不算丢)
            if (pb_ovf)                        ovf_r <= 1'b1;
            else if (pb_swallow_clr)           ovf_r <= 1'b0;
            // 帧上下文标记: 帧首字组合清零 (不能依赖寄存值滞后一拍 —— 否则本帧
            // 首字不受 hold 约束 = app 帧首字提前漏给 HLS, 实锤)
            if (pw_sop_w)                        dec_p_r <= 1'b0;
            else if (pb_dec_cyc)                 dec_p_r <= 1'b1;
            if (pw_sop_w)                        rel_r <= 1'b0;
            else if (pb_dec_cyc && !pb_dec_app)  rel_r <= 1'b1;
            // 尾区不可弹字数: 帧首字 (本拍写) 直接置 1; 判定拍清零 (释放/回卷);
            // 其余本帧未判定字逐字 +1 (判定后不再计入, 帧身自由流动)
            if (pw_sop_w)
                hold_rem_p <= pb_wr_now ? {{PB_AW{1'b0}}, 1'b1} : {(PB_AW+1){1'b0}};
            else if (pb_dec_cyc || pb_rollbk_now)
                hold_rem_p <= {(PB_AW+1){1'b0}};
            else if (pb_wr_now && !dec_p_r)
                hold_rem_p <= hold_rem_p + 1'b1;
            // 统计
            if (pb_dec_app)
                stat_hls_split <= stat_hls_split + 32'd1;
            if (ovf_r && pb_swallow_clr)
                stat_hls_drop <= stat_hls_drop + 32'd1;
            if (pre_pop && f_l && !swallow_r && !pb_dec_app)
                stat_hls_frames <= stat_hls_frames + 32'd1;
        end
    end

    // 弹口 = "有字" 且 "不属于未判定/未释放的尾区"; AXIS tvalid 不依赖 tready
    assign pb_occ   = pb_wptr - pb_rptr;
    assign pb_valid = !pb_empty && (pb_occ > hold_rem_p);

    assign pb_wr     = pb_wr_now;
    // 帧首拍恒 snap (与写无关: 本帧首字所在槽就是回卷边界; 满/吞字时也锁,
    // 否则 wsnap 会停在上一帧边界 ⇒ 后续回卷会误删上一帧已释放未弹完的字)
    assign pb_snap   = pw_sop_w;
    assign pb_rollbk = pb_rollbk_now;
    // 组合弹口 (坑 4: 寄存器化 rd ⇒ 双采重复)
    assign pb_pop    = pb_valid && p_axis_tready;

    udp_split_fifo #(.W(76), .D(32), .AW(PB_AW)) u_pb (
        .clk(clk), .rst_n(rst_n),
        .wr(pb_wr),
        .din({f_d, f_k, f_l, f_u, f_c, f_e}),
        .snap(pb_snap), .rollback(pb_rollbk),
        .rd(pb_pop), .dout(pb_dout), .empty(pb_empty), .full(pb_full),
        .dbg_wptr(pb_wptr), .dbg_rptr(pb_rptr)
    );

    assign p_axis_tdata  = pb_dout[75:12];
    assign p_axis_tkeep  = pb_dout[11:4];
    assign p_axis_tlast  = pb_dout[3];
    assign p_axis_tuser  = pb_dout[2];
    assign p_axis_tcrs   = pb_dout[1];
    assign p_axis_terr   = pb_dout[0];
    assign p_axis_tvalid = pb_valid;

    //=========================================================================
    // P5e-T3: RX meta 线束 (learn-on-RX 的 peer 学习源)
    //   纯 assign 别名 —— 不引入任何逻辑门/寄存器/状态。5 根线全部来自 u_udp_rx
    //   的既有输出 (见上面 ② 段的例化), 因此:
    //     · 不改变 T1 已验证的三条性质 (结构性不反压 / 透传逐字保真 / 坏帧与
    //       半帧整帧丢弃): 本段没有任何赋值反向影响 s_axis_tready / p_axis_* /
    //       帧缓冲门控;
    //     · 时序上只是把 udp_rx 的组合输出多扇出到一个外部口 (udp_tx_cfg 的
    //       两个寄存器输入), 不新增组合级。
    //=========================================================================
    assign meta_valid    = u_meta_valid;
    assign meta_src_mac  = u_meta_src_mac;
    assign meta_src_ip   = u_meta_src_ip;
    assign meta_src_port = u_meta_src_port;
    assign meta_len      = u_meta_len;

`ifdef RXP_DIAG
    //=========================================================================
    // RXP_DIAG v3: 帧边界记账可见化 (全部逻辑只在 `RXP_DIAG 下存在)
    //=========================================================================
    // 【为什么需要它】板级 v2 读数 (ISSUE_RX_BYTE_CORRUPTION §13): 5,699 帧里 9 帧
    //   (0.158%) 被**整帧换成下一帧的内容** —— 字数/帧数/FCS 全精确, 四桶密度相同
    //   ⇒ 内容被整体替换。本段把"坏帧开始时"的三类量锁出来:
    //     ① 读侧帧首记账 (FR/FW/FO/FH + 上一帧 PR/PW/PH) 与首失配当拍活值
    //        (LR/LW/LO/LH) ⇒ 指针/占用偏没偏、读者有没有跳过/重读一帧;
    //     ② 写侧: 播放器当前这帧的**第一个数据字**在 u_uf 写口是什么 (SW/SF/SM/WD)
    //        ⇒ "坏数据在写进缓冲时就已坏"(上游 mac_rx/udp_rx/FCS 盲区) vs
    //          "写对了、读错或被覆写";
    //     ③ 回卷一致性: 回卷丢弃字数必须恰 = 在收帧字数 (wptr-wsnap == hold_rem_u);
    //        超出 ⇒ 回卷**吃掉了已提交未读**的数据 ⇒ 写指针越过读者 ⇒ 读者随后
    //        读到的是**更晚那帧的内容**, 而字数/帧边界 (走边存) 不变 —— 与签名同形。
    //
    // 【"帧首"的精确含义】v3_fs_evt = app_rx_sof && app_rx_tvalid && app_rx_tready
    //   = 播放器**收下本帧第一拍**的那一拍 (每帧恰一次)。为什么必须带 tready:
    //   裸 app_rx_sof 在 tready=0 时持续为高 (R_NULL 态更是整个状态都高) ⇒ 会在
    //   同一帧内重复触发, 把真正的"上一帧"记录冲掉 (那正是本仪器要保的量)。
    // 【"首失配当拍"的精确含义】ds_cap 那一拍 (与 v2 的 ds_gw/ds_ew 写入同拍,
    //   见 app_udp_pattern.v: assign ds_cap = wr_end && (cap_pend || rx_bad&&!ds_v_r))。
    //   ⚠️ 已知滞后 (判读必读): app 的 RX 引擎 1 字前瞻 + 逐字节比对 ⇒ 失配字被
    //   **收下**到 ds_cap 相隔 9 拍 (稳态: 收下 -> +2 收下下一字 -> +9 该字末 lane)。
    //   若本帧在这 9 拍内已吐完并起了下一帧, 则 v3_f*/v3_fn 记的是**下一帧**的帧首
    //   (v3_fn 会比 `II/paylen` 大 1 ⇒ 离线一眼可辨); v2 的 GW/EW/桶不受影响
    //   (它们跟的是被比对的那个字, 走 cmp_sf 管线, 不是播放器状态)。
    wire        v3_fs_evt = app_rx_sof && app_rx_tvalid && app_rx_tready;

    // ---- 帧首记录 (活体; 在 v3_fs_evt 拍整体平移: current -> prev) ----
    reg  [UDP_AW:0] fs_rptr, fs_wptr, fs_occ, fs_hold;
    reg  [1:0]      fs_st;
    reg  [15:0]     fp_rptr, fp_wptr, fp_hold;
    reg  [15:0]     fs_cnt;               // 已发生的帧首次数 (= 交付帧序号 0 起)

    // ---- 写侧: 每帧第一个数据字 (定址 = 提交序号 mod 8) ----
    // 为什么要按**提交序号**定址而不是按槽址: 一帧 184 字而缓冲只有 512 字 ⇒ 槽址
    //   2.78 帧就绕回一次, 按槽址匹配会同值多义; 而"播放器交付的第 m 帧 == 第 m 次
    //   提交"(描述符 FIFO 一帧一条, 先入先出) ⇒ 按序号是一次无歧义的定址。
    //   写侧领先播放器 <= 512/184 = 2.78 帧 (受 full 约束) ⇒ mod 8 一定命中;
    //   越界由 WD 暴露 (WD>=8 ⇒ 表项已过期, 不可用)。
    // 8x74 的 distributed RAM (ram_style 强制; 组合读与写口分离)。
    (* ram_style = "distributed" *) reg [63:0]       wh_word [0:7];
    (* ram_style = "distributed" *) reg [UDP_AW-1:0] wh_slot [0:7];
    reg              wr_seen_r;           // 本帧第一个数据字已写
    reg  [15:0]      w_commit_cnt;        // 已提交帧数 (播放器帧序的真值源)
    reg  [63:0]      ww_r;                // 帧首拍锁存: 该帧第一个数据字
    reg  [UDP_AW-1:0] ws_r;               // 帧首拍锁存: 该字写入的槽址
    reg  [7:0]       wd_r;                // 帧首拍锁存: 写侧领先帧数
    reg              wm_r;                // 帧首拍锁存: 表项有效

    // ---- 回卷一致性 ----
    reg  [UDP_AW:0]  v3_wsnap_r;          // 影子 wsnap (与 frame_fifo 内部逐拍同值)
    reg              v3_rv_v;             // 已记录首个违例
    wire [UDP_AW:0]  v3_rb_dist = uf_wptr - v3_wsnap_r;   // 回卷将丢弃的字数
    wire             v3_rb_viol = uf_rollbk && (v3_rb_dist != hold_rem_u);
    wire [UDP_AW:0]  v3_rb_exc  = v3_rb_dist - hold_rem_u;
    wire [15:0]      v3_wdelta  = w_commit_cnt - fs_cnt;  // 帧首拍: 写侧领先帧数

    // 写侧第一个数据字取样: 帧首 (meta/nul) 之后的第一次真正写入。
    // 优先"清" ⇒ 与 meta_valid 同拍不可能有载荷字 (udp_rx 载荷首字在 w6, 比 w5
    // 的 meta_valid 晚一拍), 故优先序不影响正确性, 只是防御性写法。
    wire v3_first_wr = uf_wr && !wr_seen_r;
    always @(posedge clk) begin
        if (v3_first_wr) begin
            wh_word[w_commit_cnt[2:0]] <= u_m_d;
            wh_slot[w_commit_cnt[2:0]] <= uf_wptr[UDP_AW-1:0];
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            wr_seen_r <= 1'b0;
        else if (u_meta_valid || u_nul_cyc) wr_seen_r <= 1'b0;
        else if (uf_wr)                     wr_seen_r <= 1'b1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)               w_commit_cnt <= 16'd0;
        else if (u_commit_ok)     w_commit_cnt <= w_commit_cnt + 16'd1;
    end

    // 影子 wsnap: frame_fifo 在 snap 拍做 wsnap <= wptr (同一拍同一值), 故本影子与
    // 其内部 wsnap **逐拍逐位相同**, 不需要动 frame_fifo (它不在本次改动范围内)。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       v3_wsnap_r <= {(UDP_AW+1){1'b0}};
        else if (uf_snap) v3_wsnap_r <= uf_wptr;
    end

    // ---- 帧首记录更新 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fs_rptr <= 0; fs_wptr <= 0; fs_occ <= 0; fs_hold <= 0;
            fs_st <= 2'd0; fp_rptr <= 0; fp_wptr <= 0; fp_hold <= 0; fs_cnt <= 16'd0;
            ww_r <= 64'd0; ws_r <= 0; wd_r <= 8'd0; wm_r <= 1'b0;
        end else if (v3_fs_evt) begin
            fp_rptr <= fs_rptr; fp_wptr <= fs_wptr; fp_hold <= fs_hold;
            fs_rptr <= uf_rptr; fs_wptr <= uf_wptr; fs_occ <= uf_occ;
            fs_hold <= hold_rem_u; fs_st <= rstate;
            // 写侧指纹 (按本帧序号定址; 见上面 mod 8 的论证)
            ww_r    <= wh_word[fs_cnt[2:0]];
            ws_r    <= wh_slot[fs_cnt[2:0]];
            wd_r    <= v3_wdelta[7:0];
            wm_r    <= (v3_wdelta >= 16'd1) && (v3_wdelta <= 16'd7);
            fs_cnt  <= fs_cnt + 16'd1;
        end
    end

    // ---- ds_cap 拍: 锁 current / prev / 活值 / 写侧指纹 ----
    // ⚠️ **v3_fs_evt 与 ds_cap 可以同拍** —— 独立审查实测证伪了早先"结构上不可能"的
    //    断言: 帧长 1472 (184 字) 时, 首个失配落在该帧第 ~178..181 字, 就会让
    //    ds_cap (收下+9) 恰好落在下一帧的帧首拍上。
    //    那时**失配字属于上一帧**, 而帧首寄存器在本拍仍是上一帧的记录 (沿后才更新)
    //    ⇒ **一律用"更新前"的记录就是正确的那一份**。
    //    早先那组 `v3_fs_evt ? ...` 同拍 mux 只加在 v3_fn/pr/pw/ph/sw/sf/sm/wd 上,
    //    而 v3_fr/fw/fo/fh/fs 没有 ⇒ 同拍时记录**自相矛盾** (FR 是上一帧、FN 却是
    //    新帧) ⇒ 板级会读出 FR-PR = 0 并被判成"读者跳帧/重读帧"的**假指针级缺陷**。
    //    ⇒ 删除全部同拍 mux。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3_fr <= 0; v3_fw <= 0; v3_fo <= 0; v3_fh <= 0; v3_fs <= 2'd0;
            v3_fn <= 16'd0;
            v3_pr <= 0; v3_pw <= 0; v3_ph <= 0;
            v3_lr <= 0; v3_lw <= 0; v3_lo <= 0; v3_lh <= 0;
            v3_sw <= 64'd0; v3_sf <= 0; v3_sm <= 1'b0; v3_wd <= 8'd0;
        end else if (ds_cap) begin
            v3_fr <= fs_rptr;  v3_fw <= fs_wptr;  v3_fo <= fs_occ;
            v3_fh <= fs_hold;  v3_fs <= fs_st;
            // 序号: 恒取"更新前"的当前播放帧序号 (同拍帧首时它正是失配字所属帧)
            v3_fn <= fs_cnt - 16'd1;
            v3_pr <= fp_rptr;
            v3_pw <= fp_wptr;
            v3_ph <= fp_hold;
            v3_lr <= uf_rptr;  v3_lw <= uf_wptr;
            v3_lo <= uf_occ;   v3_lh <= hold_rem_u;
            // 写侧指纹: 恒取已登记的表项 (与 v3_fr/v3_fn 同属"更新前"的那一帧)
            v3_sw <= ww_r;   v3_sf <= ws_r;
            v3_sm <= wm_r;   v3_wd <= wd_r;
        end
    end

    // ---- 回卷一致性计数与首违例快照 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v3_rc <= 16'd0; v3_vc <= 16'd0; v3_rv_v <= 1'b0;
            v3_vx <= 0; v3_vs <= 0; v3_vr <= 0; v3_vn <= 16'd0;
        end else begin
            if (uf_rollbk) v3_rc <= v3_rc + 16'd1;
            if (v3_rb_viol) begin
                v3_vc <= v3_vc + 16'd1;
                if (!v3_rv_v) begin
                    v3_rv_v  <= 1'b1;
                    v3_vx    <= v3_rb_exc;
                    v3_vs    <= v3_wsnap_r;
                    v3_vr    <= uf_rptr;
                    v3_vn    <= w_commit_cnt;
                end
            end
        end
    end

    //=========================================================================
    // RXP_DIAG v4 (2026-09-27): 异常帧路径计数器 (ISSUE_RX_BYTE_CORRUPTION §16.7)
    //=========================================================================
    // 【要回答的问题】v3 把损坏钉在"写进 u_uf 时就已经坏了"(§16.1), 但**本模块内
    //   的几条"载荷已写、帧未提交 / 帧归属异常"分支从来没有被观测过** —— 只知道
    //   它们在源码里存在。本组把每一条变成"本轮累计计数", 判据是:
    //     某计数器 == 该轮的 n (受损帧数, 由 OZ 与 UMM/(p×255/256) 定出)
    //   ⇒ 那条路径就是根因 (它是"整帧内容被换掉"的搬运工)。
    //
    // 【计数口径 (必须读)】每个计数器都在**其条件为高的那一拍** +1 (非阻塞赋值,
    //   与条件同沿; 即"该拍被计入"), 因此:
    //     · CN/RD/NC/NP 的条件都是**单拍脉冲**:
    //         u_commit_no  = u_commit_evt && desc_full   (u_commit_evt 由 u_end/fend
    //                        单拍脉冲驱动 ⇒ 单拍)
    //         u_residue    = u_meta_valid && u_open_r     (u_meta_valid = w5 拍, 单拍)
    //         u_nul_cyc    = u_fend && (u_meta_len == 0)  (u_fend = udp_rx 的判定拍, 单拍)
    //         u_nul_commit = u_nul_cyc && !u_ferr         (同上)
    //       ⇒ 拍数 == 事件数, 不漏拍不重计。**这四个是"帧数"口径**。
    //     · WF 的条件 uf_ovf = u_word && uf_full 是**电平不是脉冲**: 缓冲满期间每个
    //       载荷字都为高 ⇒ WF 是**被吞掉的载荷字数**, 不是帧数 (一帧可贡献多个)。
    //       判读: WF>0 就是"发生过满"; 不要拿 WF 直接与 n 比。
    //     · RL 的条件 uf_rollbk 在一条回卷请求上恰高 1 拍 (与写字同拍时顺延到下一拍,
    //       由 u_rollpend_r 兜住) ⇒ RL == 回卷次数 == v3 的 RC (同一根线, 冗余但便于
    //       与 CN/RD 对账: RL 是"回卷总数"的上界包络, 三条路径各占多少看 CN/RD 与
    //       差值里的"坏帧尾回卷")。
    //-------------------------------------------------------------------------
    // v4: **载荷流与帧归属一致性的直接探针** (§16.7 要求的"最便宜的一刀")
    //-------------------------------------------------------------------------
    // 每帧提交时, 比较:
    //   · 该帧**实际写进 u_uf 的字数** = hold_rem_u 在提交拍的"更新前值" **+ 1**
    //     ⚠️ 那个 +1 不是修饰: 提交拍的条件是 u_end, 而 hold_rem_u 的更新式里
    //        `u_end && !uf_roll_req` 走的是**清零**分支 ⇒ **本拍这个末字不参与
    //        +1 累加**(它被清零语句吞掉) ⇒ 更新前的值 = N-1, N = 本帧写字总数。
    //        照字面用"更新前值 == ceil(len/8)"会**每帧都命中**(恒差 1) —— 那不是
    //        探针坏, 是口径少算了本拍的字。门里有正/负两相把这一点钉死 (干净流
    //        WC 必须恒 0; 把 u_meta_len 强偏 8 字节 ⇒ 每帧恰 1 次 WC)。
    //   · 该帧**声明的载荷长度应占的字数** = (u_meta_len + 7) >> 3
    //     (u_meta_len = udp_rx 的 meta_len, 整帧内保持有效, 提交拍仍有效 —— 描述符
    //      就是在同一拍用它的)
    // 不相等 = **该帧写的字数与它声明的长度对不上** ⇒ 载荷流与帧归属不一致
    //   (这正是"下一帧的载荷被算成本帧的"那一类错误的直接签名)。
    // 只在**载荷字提交路径** (uf_commit_word) 上判: 被回卷的帧不交付, 其字数无意义;
    //   0 长数据报没有载荷字 (0 == 0 恒成立), 判了也不会响。
    // ⚠️ 声明顺序: 三条 wire 必须在下面那个 always 之前 (xvlog 先声明后用 —— 坑 22)。
    wire [15:0] v4_wnum  = hold_rem_u + 16'd1;
    wire [15:0] v4_wdecl = (u_meta_len + 16'd7) >> 3;
    wire        v4_wc_bad = uf_commit_word && (v4_wnum != v4_wdecl);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v4_cn <= 16'd0; v4_rd <= 16'd0; v4_nc <= 16'd0; v4_np <= 16'd0;
            v4_wf <= 16'd0; v4_rl <= 16'd0; v4_wc <= 16'd0;
        end else begin
            if (u_commit_no)  v4_cn <= v4_cn + 16'd1;
            if (u_residue)    v4_rd <= v4_rd + 16'd1;
            if (u_nul_cyc)    v4_nc <= v4_nc + 16'd1;
            if (u_nul_commit) v4_np <= v4_np + 16'd1;
            if (uf_ovf)       v4_wf <= v4_wf + 16'd1;
            if (uf_rollbk)    v4_rl <= v4_rl + 16'd1;
            if (v4_wc_bad)    v4_wc <= v4_wc + 16'd1;
        end
    end

    //=========================================================================
    // RXP_DIAG v5 (2026-09-27): 写数据口 (din = u_m_d) 上的**第二个 LFSR 校验器**
    //=========================================================================
    // 【它证伪的是哪条假设 (§14.6 第一条)】v3 的写侧指纹 SW 由 `wh_word[w_commit_cnt
    //   [2:0]]`(按**提交序号 mod 8** 定址)在 `v3_fs_evt`(帧首被收下那一拍)采出, 而
    //   `wr_seen_r` 在 meta_valid/nul_cyc 拍清、在首个 uf_wr 拍置 ⇒ 整个采集**依赖
    //   "该帧的载荷字不与 meta_valid 同拍"**(依赖 udp_rx 的载荷首字在 w6, 比 w5 的
    //   meta_valid 晚一拍)。这条依赖**无法从 TB 侧构造**, 所以"SW 采到的就是 din 上的
    //   字"这一归因从未被独立验证。⇒ 本组是一个**机制完全不同**的探针: 不按帧号定址,
    //   只按**字节计数**推进; 期望序列 = 与 app 的 RX 校验器**逐字节同约定**的 xorshift64。
    //
    // 【为什么"纯计数"有判别力】两个校验器若都看同一条流, 必然同时看到同一个坏字节
    //   ⇒ `DV == II`(app 的 ds_idx) 且 `DM == UMM`(app 的 stat_mismatch)。反过来,
    //   若 SW 的归因有假 (取错了拍/取错了帧), app 的 II 仍指向真实失配, 而 SW/GW 会
    //   给出与之**互相矛盾**的组合 —— 分辨力正来自"两个不同机制的锚"。
    //
    // 【口径 (判读必读)】
    //   ① 本校验器统计**写进 u_uf 的字节流** (uf_wr 拍, 按 popcount(u_m_k) 计), 期望值
    //      取"按**累计字节序号**索引的图案流"。两个精度不同的口径必须分开说
    //      (2026-09-27 修正, 门里 W7 是这条的判别实验):
    //      · **内容**口径: 回卷(`RL`)只把写指针退回去, **不改写流内容** (下一帧仍在
    //        同一地址写自己的字节) ⇒ 写流仍是图案流的前缀 ⇒ 回卷**不**让内容校验失真。
    //        只有**满吞** `WF` 会在写流里挖洞 ⇒ `WF != 0` 时内容口径也失效。
    //      · **序号**口径: app 的字节序号只数**交付**的字节, 回卷掉的整帧被跳过 ⇒
    //        `DV == II` / `DM == UMM` 这两条跨机制对照要求 `RL == 0` **且** `WF == 0`。
    //      板级 8/8 轮 `RL = WF = 0` (§18.2/§18.5) ⇒ 两个口径在板级同时成立。
    //   ② `DV/DM` 与 app 的 `II/UMM` 严格可比 (同一全局字节序号、同一失配定义);
    //      `DO` 与 app 的 `II % paylen` 可比 (帧内偏移, 由 uf_snap 帧边界复位)。
    //   ③ 推进步数 = **popcount(u_m_k)** 而不是恒 8 —— 与 app 的 `cmp_n = pop8(rx_tkeep)`
    //      逐位同口径 (帧末部分字只推进几个字节)。
    //   ④ 快照 (DV/DG/DE/DO/VZ) 只记**首个**失配 (粘滞); DM 记**全部**失配字节。
    //   ⑤ 复位后 LFSR 从 SEED 起 —— 与 app 的 `rx_lfsr` 同源; 板级 app 的 i_en 恒 1
    //      (wrapper_p4.v:1767), 且两者共用同一 rst_n。
    //   ⑥ 本段**全部**在 `ifdef RXP_DIAG 内 ⇒ 默认构建端口表/网表逐位不变。
    //-------------------------------------------------------------------------
    // ---- B 部: 解析器计数器引出 (零新逻辑 —— 它们本来就在本模块里, 只是无人引用) ----
    // 判据: PS (stat_pass) vs app 的 URF(交付帧数) —— 不等 ⇒ 解析器与 app 之间有丢帧/重帧。
    // 口径: PS = 匹配且 FCS 好的帧数; SB = 这些帧的载荷字节数; NM/IC/DC = 三个丢弃计数
    //       (非匹配 / IP 校验和 / FCS 坏), 四者互斥 (见 rtl/udp_rx.v 的 stat 段)。
    assign v5_up_pass  = u_stat_pass;
    assign v5_up_nm    = u_stat_nm;
    assign v5_up_ipc   = u_stat_ipc;
    assign v5_up_crc   = u_stat_crc;
    assign v5_up_bytes = u_stat_bytes;

    // ---- 与 app_udp_pattern.xs_next **逐位同款**的一步 (同一组常数移位) ----
    // (函数声明必须在用之前 —— xvlog 先声明后用, 坑 22)
    function [63:0] v5_xs;
        input [63:0] s;
        reg   [63:0] t;
        begin
            t = s ^ (s << 13);
            t = t ^ (t >> 7);
            t = t ^ (t << 17);
            v5_xs = t;
        end
    endfunction

    function [3:0] v5_pop8;
        input [7:0] v;
        integer i;
        reg [3:0] c;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]};
            v5_pop8 = c;
        end
    endfunction

    reg  [63:0] v5_lfsr;                 // 期望序列状态 (先取后推进)
    reg  [31:0] v5_cnt;                  // 累计字节序号 (纯计数锚)
    reg  [15:0] v5_fo;                   // 帧内字节偏移 (uf_snap 复位)
    reg         v5_v_r;                  // 快照有效 (粘滞)
    reg  [31:0] v5_idx_r, v5_mm_r;
    reg  [7:0]  v5_got_r, v5_exp_r;
    reg  [15:0] v5_off_r;

    wire [3:0]  v5_nb  = v5_pop8(u_m_k); // 本字有效字节数 (与 app 的 cmp_n 同口径)
    wire        v5_cyc = uf_wr;          // 本拍真的写进了 u_uf

    // 链: s0 = 当前状态; s_{i+1} = xs(s_i)。lane i 的期望字节 = s_i[31:24] (lane0 =
    // tdata[63:56], 与 app 的 byte_at()/put8_0() 同序)。
    wire [63:0] v5_s1 = v5_xs(v5_lfsr);
    wire [63:0] v5_s2 = v5_xs(v5_s1);
    wire [63:0] v5_s3 = v5_xs(v5_s2);
    wire [63:0] v5_s4 = v5_xs(v5_s3);
    wire [63:0] v5_s5 = v5_xs(v5_s4);
    wire [63:0] v5_s6 = v5_xs(v5_s5);
    wire [63:0] v5_s7 = v5_xs(v5_s6);
    wire [63:0] v5_s8 = v5_xs(v5_s7);
    // **先取后推进**: lane0 的期望值取的是**推进前**的状态 (与 app 的
    // `wire [7:0] rx_exp = rx_lfsr[31:24]` + `rx_lfsr <= xs_next(rx_lfsr)` 逐位同款)
    wire [7:0]  v5_e0 = v5_lfsr[31:24];
    wire [7:0]  v5_e1 = v5_s1[31:24];
    wire [7:0]  v5_e2 = v5_s2[31:24];
    wire [7:0]  v5_e3 = v5_s3[31:24];
    wire [7:0]  v5_e4 = v5_s4[31:24];
    wire [7:0]  v5_e5 = v5_s5[31:24];
    wire [7:0]  v5_e6 = v5_s6[31:24];
    wire [7:0]  v5_e7 = v5_s7[31:24];
    // 推进后的状态 = s_{nb} (nb ∈ 0..8 ⇒ 9 选 1)
    reg  [63:0] v5_ns;
    always @(*) begin
        case (v5_nb)
            4'd0:    v5_ns = v5_lfsr;
            4'd1:    v5_ns = v5_s1;
            4'd2:    v5_ns = v5_s2;
            4'd3:    v5_ns = v5_s3;
            4'd4:    v5_ns = v5_s4;
            4'd5:    v5_ns = v5_s5;
            4'd6:    v5_ns = v5_s6;
            4'd7:    v5_ns = v5_s7;
            default: v5_ns = v5_s8;      // nb==8 (满字, 全场绝大多数)
        endcase
    end
    wire [7:0]  v5_g0 = u_m_d[63:56];
    wire [7:0]  v5_g1 = u_m_d[55:48];
    wire [7:0]  v5_g2 = u_m_d[47:40];
    wire [7:0]  v5_g3 = u_m_d[39:32];
    wire [7:0]  v5_g4 = u_m_d[31:24];
    wire [7:0]  v5_g5 = u_m_d[23:16];
    wire [7:0]  v5_g6 = u_m_d[15:8];
    wire [7:0]  v5_g7 = u_m_d[7:0];
    // 逐 lane 失配 (只对**有效 lane** 判: i < nb)
    wire        v5_b0 = (4'd0 < v5_nb) && (v5_g0 != v5_e0);
    wire        v5_b1 = (4'd1 < v5_nb) && (v5_g1 != v5_e1);
    wire        v5_b2 = (4'd2 < v5_nb) && (v5_g2 != v5_e2);
    wire        v5_b3 = (4'd3 < v5_nb) && (v5_g3 != v5_e3);
    wire        v5_b4 = (4'd4 < v5_nb) && (v5_g4 != v5_e4);
    wire        v5_b5 = (4'd5 < v5_nb) && (v5_g5 != v5_e5);
    wire        v5_b6 = (4'd6 < v5_nb) && (v5_g6 != v5_e6);
    wire        v5_b7 = (4'd7 < v5_nb) && (v5_g7 != v5_e7);
    wire [3:0]  v5_nbad = {3'b0, v5_b0} + {3'b0, v5_b1} + {3'b0, v5_b2} + {3'b0, v5_b3}
                        + {3'b0, v5_b4} + {3'b0, v5_b5} + {3'b0, v5_b6} + {3'b0, v5_b7};
    wire        v5_any = |{v5_b7, v5_b6, v5_b5, v5_b4, v5_b3, v5_b2, v5_b1, v5_b0};
    // 首个坏 lane (lane0 优先; 只在 v5_any 时有意义)
    wire [3:0]  v5_fb = v5_b0 ? 4'd0 : v5_b1 ? 4'd1 : v5_b2 ? 4'd2 : v5_b3 ? 4'd3 :
                        v5_b4 ? 4'd4 : v5_b5 ? 4'd5 : v5_b6 ? 4'd6 : 4'd7;
    reg  [7:0]  v5_gsel, v5_esel;
    always @(*) begin
        case (v5_fb)
            4'd0:    begin v5_gsel = v5_g0; v5_esel = v5_e0; end
            4'd1:    begin v5_gsel = v5_g1; v5_esel = v5_e1; end
            4'd2:    begin v5_gsel = v5_g2; v5_esel = v5_e2; end
            4'd3:    begin v5_gsel = v5_g3; v5_esel = v5_e3; end
            4'd4:    begin v5_gsel = v5_g4; v5_esel = v5_e4; end
            4'd5:    begin v5_gsel = v5_g5; v5_esel = v5_e5; end
            4'd6:    begin v5_gsel = v5_g6; v5_esel = v5_e6; end
            default: begin v5_gsel = v5_g7; v5_esel = v5_e7; end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v5_lfsr  <= 64'h9E3779B97F4A7C15;   // = app_udp_pattern.SEED
            v5_cnt   <= 32'd0;  v5_fo  <= 16'd0;  v5_v_r <= 1'b0;
            v5_idx_r <= 32'd0;  v5_mm_r <= 32'd0;
            v5_got_r <= 8'd0;   v5_exp_r <= 8'd0; v5_off_r <= 16'd0;
        end else begin
            // 帧内偏移: 帧边界 (uf_snap = 载荷首字节**前**的那一拍) 复位。
            // 与写字同拍时按"本字即本帧首字"处理 (结构上不会发生: 载荷首字在
            // uf_snap 的下一拍; 这里只是防御性写法, 不让两种口径产生分歧)。
            if (uf_snap && !v5_cyc) v5_fo <= 16'd0;
            else if (v5_cyc)        v5_fo <= (uf_snap ? 16'd0 : v5_fo) + {12'b0, v5_nb};
            if (v5_cyc) begin
                v5_lfsr <= v5_ns;
                v5_cnt  <= v5_cnt + {28'b0, v5_nb};
                v5_mm_r <= v5_mm_r + {28'b0, v5_nbad};
                if (v5_any && !v5_v_r) begin
                    v5_v_r   <= 1'b1;
                    v5_idx_r <= v5_cnt + {28'b0, v5_fb};
                    v5_got_r <= v5_gsel;
                    v5_exp_r <= v5_esel;
                    v5_off_r <= (uf_snap ? 16'd0 : v5_fo) + {12'b0, v5_fb};
                end
            end
        end
    end

    assign v5_dv_idx = v5_idx_r;
    assign v5_dv_got = v5_got_r;
    assign v5_dv_exp = v5_exp_r;
    assign v5_dv_off = v5_off_r;
    assign v5_dv_mm  = v5_mm_r;
    assign v5_dv_v   = v5_v_r;

    //=========================================================================
    // RXP_DIAG v6 (2026-09-27): **u_pre 输入侧** (s_axis) 上的第三个 LFSR 校验器
    //=========================================================================
    // 【要回答的问题 (§18.9 的矛盾)】板级已定案: 载荷被**窗口内循环旋转**; 而逐个
    //   结构排查说 `din` (= u_uf 写口) 之前**没有任何能装下整帧的存储**。v5 用
    //   **机制不同**的探针 (纯字节计数 vs SW 的帧号定址) 证明 `din` 上确实已经损坏。
    //   ⇒ 三者不能同时为真; 唯一还没插桩的点就是 **u_pre 的输入** (= 本段)。
    //   裁决表 (v6 上板后):
    //     · v6 干净 (CZ=0) 而 v5 损坏 ⇒ 重排在 **u_pre 或 udp_rx 内部**;
    //     · v6 也损坏 ⇒ 在 **mac_rx_64 / rx_classify / vlan_strip** ⇒ 必须带着这个
    //       反例重查"无帧级存储"的论证。
    //
    // 【为什么不需要解析表头】载荷起点是**常量 42 字节** (14 以太 + 20 IP + 8 UDP;
    //   本设计无 VLAN、无 IP 选项 —— 见 udp_rx.v 头注释), FCS 已在 mac_rx_64 剥离
    //   (它的 4 字节前瞻延迟线让帧尾 4 字节自然不打包)。⇒ 输入侧只做三件事:
    //     ① SOP (s_axis_tuser) 复位"帧内字节计数"; ② 帧内序号 < 42 的字节跳过;
    //     ③ 从第 42 字节起逐字节喂 LFSR 并比对, 直到帧末。
    //   ⚠️ 已知边界 (判读必读): 本段**不判 FCS/IP 头是否合法**, 也**不判该帧会不会被
    //     udp_rx 接受** —— 所有进入 udp_split 的字都计入 (含被 udp_rx 丢弃的非匹配帧
    //     与后续被回卷的坏 FCS 帧)。所以 `CV == app 的 II` 只在"**所有** UDP 帧都被
    //     app 交付"时成立 (板级 8/8 轮 RL=WF=0 且全匹配, 满足)。
    //
    // 【LFSR 约定 (必须与 v5 侧和 app 三方一致)】xorshift64, seed 0x9E3779B97F4A7C15,
    //   **先取后推进**, byte = state[31:24]。本段直接**复用 v5 段的 v5_xs 函数**
    //   (不另写一份 —— 两份实现迟早会漂移)。三个校验器的等价性由门里**动态断言**
    //   钉死: 同一次注入上 `CV == app 的 ds_idx` 且 `CM == app 的 stat_mismatch`
    //   且 `CV == v5 的 DV`, 任一 LFSR 有 1 字节相位差这些断言必然变红。
    //
    // 【推进步数 = popcount(tkeep)**】而不是恒 8 —— 与 v5 侧和 app 的 `cmp_n` 逐位同
    //   口径 (帧末部分字只推进几个字节)。
    //
    //-------------------------------------------------------------------------
    // 【时序: 为什么本段**不是**又一个 8 步组合链】(v5 已把 WNS 压到 0.07ns)
    //   输入侧 1 字/拍**上限**、且帧内只有 ~184 字载荷 (1G 下线速 = 1 字/8 拍),
    //   空闲很多 ⇒ 多拍计算是免费的。本段用一个 **2 拍/字** 的引擎 + 深 4 的输入
    //   skid: 每拍只做 **≤4 步** xorshift (≈12 级 LUT, v5 是一条 8 步 ≈24 级的链),
    //   吞吐 = 1 字/2 拍 = 1G 线速的 **4 倍余量**。
    //   ⚠️ 结构上限 (写清, 不藏): 本引擎**跟不上持续背靠背** (1 字/拍) 的输入 ——
    //     输入侧不能反压 (s_axis_tready = !pre_full, 而 pre_full 结构性几乎不出现),
    //     所以 skid 满时只能**丢字**, 并计入 `CS`。板级 1G 与真 wrapper 全链 (经
    //     mac_rx_64 的 8 字 FIFO) 都是 1 字/8 拍 ⇒ 余量 4 倍, `CS` 恒 0;
    //     `CS != 0` ⇒ **本轮 v6 读数不可用** (被丢的字让 LFSR 与字节流错位)。
    //     门里有一条**过速相**专门证明 `CS` 会动 (不是死 0)。
    //-------------------------------------------------------------------------
    // 载荷起点常量 (14 以太 + 20 IP + 8 UDP)。**不要**改成参数: gen_offsets.py 与
    //   门里的 41/42/43 边界相都按 42 写死, 变异测试 M-V1 就是把它改成 41。
    localparam [15:0] V6_HDR = 16'd42;

    // ---- 输入侧: 帧内字节序号 + 本字载荷字节数 ----
    // v6_fidx = 下一个被接受的字的**首字节**在帧内的序号 (SOP 字 = 0)。
    //   ⚠️ 它在**每次 s_acc** 推进 (与 skid 是否满无关) ⇒ 即使有丢字, 后续字的
    //     帧内序号仍然正确 (被丢的字只影响 LFSR 的字节计数, 不影响 fidx)。
    reg  [15:0] v6_fidx;
    wire [3:0]  v6_nbw  = v5_pop8(s_axis_tkeep);          // 本字有效字节数 (与 v5 同口径)
    wire        v6_sopw = s_acc && s_axis_tuser;          // SOP 字被接受
    wire [15:0] v6_fin  = v6_sopw ? 16'd0 : v6_fidx;      // 本字首字节的帧内序号
    wire [15:0] v6_end  = v6_fin + {12'b0, v6_nbw};       // 本字末字节之后的序号
    wire [15:0] v6_bs   = (v6_fin < V6_HDR) ? V6_HDR : v6_fin;  // 本字内首个载荷字节的序号
    wire [15:0] v6_np16 = (v6_end > v6_bs) ? (v6_end - v6_bs) : 16'd0;
    wire [3:0]  v6_np   = v6_np16[3:0];                   // 本字的载荷字节数 (0..8)
    // 载荷字节 = 本字的**尾部** np 个字节 (因为 42 不是 8 的倍数: 只有第 6 个字
    //   (帧内序号 40..47) 的前 2 字节是头, 其余整字要么全头要么全载荷)。
    wire [3:0]  v6_skip = v6_nbw - v6_np;                 // 本字**头部跳过**的字节数 (0..8)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            v6_fidx <= 16'd0;
        else if (s_acc)        v6_fidx <= v6_end;
    end

    // ---- 输入 skid: 深 4 的字 FIFO (写口 = s_acc; 满则丢并计入 CS) ----
    // 条目 = {tdata[63:0], skip[3:0], fidx[15:0], np[3:0]} = 88 位 (tkeep 不存: np 已够)。
    reg  [87:0] v6_mem [0:3];
    reg  [1:0]  v6_wp, v6_rp;
    reg  [2:0]  v6_oc;                                    // 占用 0..4
    wire        v6_full  = (v6_oc == 3'd4);
    wire        v6_empty = (v6_oc == 3'd0);
    wire        v6_put   = s_acc && !v6_full;
    wire        v6_ovf   = s_acc &&  v6_full;             // 丢字 (计入 CS)

    // ---- 引擎: 2 拍/字 ----
    //   ph=0 (start): 比对载荷字节 0..3; ph=1: 比对载荷字节 4..7。
    //   v6_lfsr 在**每个处理拍**按"本拍消费的字节数"推进一次 (0..4 步) ⇒ 状态在
    //   ph=1 拍开始时恰是"载荷第 4 字节"的状态 (A 拍已推进)。这是本引擎唯一的
    //   跨拍反馈, 而每拍的组合深度只有 ≤4 步。
    reg         v6_busy, v6_ph;
    reg  [87:0] v6_w;
    wire        v6_start = !v6_busy && !v6_empty;         // 本拍处理 skid 头字 (ph=0)
    wire        v6_cyc1  = v6_busy && v6_ph;              // 本拍处理上一个字的 ph=1
    wire        v6_pop   = v6_start;
    wire        v6_cyc   = v6_start || v6_cyc1;           // 本拍真的比了 ≤4 个字节

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v6_wp <= 2'd0; v6_rp <= 2'd0; v6_oc <= 3'd0;
            v6_busy <= 1'b0; v6_ph <= 1'b0; v6_w <= 88'd0;
        end else begin
            if (v6_put) v6_mem[v6_wp] <= {s_axis_tdata, v6_skip, v6_fin, v6_np};
            if (v6_put) v6_wp <= v6_wp + 2'd1;
            if (v6_pop) v6_rp <= v6_rp + 2'd1;
            v6_oc <= v6_oc + {2'b0, v6_put} - {2'b0, v6_pop};
            if (v6_start)      begin v6_busy <= 1'b1; v6_ph <= 1'b1; v6_w <= v6_mem[v6_rp]; end
            else if (v6_cyc1)  begin v6_busy <= 1'b0; v6_ph <= 1'b0; end
        end
    end

    // 当前处理字的字段 (ph=1 取寄存器副本, ph=0 组合读 skid 头)
    wire [87:0] v6_cw   = v6_cyc1 ? v6_w : v6_mem[v6_rp];
    wire [63:0] v6_cd   = v6_cw[87:24];
    wire [3:0]  v6_csk  = v6_cw[23:20];
    wire [15:0] v6_cfi  = v6_cw[19:4];
    wire [3:0]  v6_cnp  = v6_cw[3:0];

    // 本拍消费的载荷字节数: ph=0 取 min(np,4), ph=1 取 np-4 (np>4 时)
    wire [3:0]  v6_n0   = (v6_cnp > 4'd4) ? 4'd4 : v6_cnp;
    wire [3:0]  v6_n1   = (v6_cnp > 4'd4) ? (v6_cnp - 4'd4) : 4'd0;
    wire [3:0]  v6_n    = v6_cyc1 ? v6_n1 : v6_n0;
    wire [3:0]  v6_base = v6_cyc1 ? 4'd4 : 4'd0;          // 本拍首个载荷字节在字内的序号

    // ---- 状态寄存器 (声明必须在用之前 —— xvlog 先声明后用, 坑 22) ----
    reg  [63:0] v6_lfsr;                                 // 期望序列状态 (先取后推进)
    reg  [31:0] v6_cnt;                                  // 累计**比对**的载荷字节数 (活计数器)
    reg  [31:0] v6_mm;                                   // 失配字节总数 (整轮)
    reg  [31:0] v6_cv;  reg [7:0] v6_cg, v6_ce;
    reg  [15:0] v6_co;  reg v6_v;  reg [7:0] v6_cs;

    // ---- 期望字节: 从当前状态起 ≤3 步 (lane p = xs^p(state)[31:24], 先取后推进) ----
    wire [63:0] v6_s1 = v5_xs(v6_lfsr);
    wire [63:0] v6_s2 = v5_xs(v6_s1);
    wire [63:0] v6_s3 = v5_xs(v6_s2);
    wire [63:0] v6_s4 = v5_xs(v6_s3);
    wire [7:0]  v6_x0 = v6_lfsr[31:24];
    wire [7:0]  v6_x1 = v6_s1[31:24];
    wire [7:0]  v6_x2 = v6_s2[31:24];
    wire [7:0]  v6_x3 = v6_s3[31:24];
    // 推进后的状态 = xs^v6_n (n ∈ 0..4 ⇒ 5 选 1)
    reg  [63:0] v6_ns;
    always @(*) begin
        case (v6_n)
            4'd0:    v6_ns = v6_lfsr;
            4'd1:    v6_ns = v6_s1;
            4'd2:    v6_ns = v6_s2;
            4'd3:    v6_ns = v6_s3;
            default: v6_ns = v6_s4;                      // n==4
        endcase
    end

    // ---- 收到的字节: 把本字的载荷字节**左对齐打包**到 v6_pw (payload lane p = v6_pw 第 p 个字节)
    //   载荷 = 尾部 np 字节 ⇒ 左移 skip*8 位即可 (skip=8 ⇒ 全移出 ⇒ 恒 0, 而那 n=0 不比)
    wire [63:0] v6_pw = v6_cd << {v6_csk, 3'b0};
    // ph=0 比 payload lane 0..3 (= v6_pw[63:32]), ph=1 比 payload lane 4..7 (= v6_pw[31:0])
    wire [31:0] v6_gw = v6_cyc1 ? v6_pw[31:0] : v6_pw[63:32];
    wire [7:0]  v6_g0 = v6_gw[31:24];
    wire [7:0]  v6_g1 = v6_gw[23:16];
    wire [7:0]  v6_g2 = v6_gw[15:8];
    wire [7:0]  v6_g3 = v6_gw[7:0];
    // 逐 lane 失配 (只对有效 lane 判: p < n)
    wire        v6_b0 = (4'd0 < v6_n) && (v6_g0 != v6_x0);
    wire        v6_b1 = (4'd1 < v6_n) && (v6_g1 != v6_x1);
    wire        v6_b2 = (4'd2 < v6_n) && (v6_g2 != v6_x2);
    wire        v6_b3 = (4'd3 < v6_n) && (v6_g3 != v6_x3);
    wire [3:0]  v6_nbad = {3'b0, v6_b0} + {3'b0, v6_b1} + {3'b0, v6_b2} + {3'b0, v6_b3};
    wire        v6_any  = |{v6_b3, v6_b2, v6_b1, v6_b0};
    wire [3:0]  v6_fb   = v6_b0 ? 4'd0 : v6_b1 ? 4'd1 : v6_b2 ? 4'd2 : 4'd3;
    reg  [7:0]  v6_gsel, v6_esel;
    always @(*) begin
        case (v6_fb)
            4'd0:    begin v6_gsel = v6_g0; v6_esel = v6_x0; end
            4'd1:    begin v6_gsel = v6_g1; v6_esel = v6_x1; end
            4'd2:    begin v6_gsel = v6_g2; v6_esel = v6_x2; end
            default: begin v6_gsel = v6_g3; v6_esel = v6_x3; end
        endcase
    end

    // ---- 状态更新 (LFSR + 计数 + 粘滞快照) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v6_lfsr <= 64'h9E3779B97F4A7C15;             // = v5_lfsr / app SEED
            v6_cnt <= 32'd0;  v6_mm <= 32'd0;
            v6_cv  <= 32'd0;  v6_cg <= 8'd0;  v6_ce <= 8'd0;  v6_co <= 16'd0;
            v6_v   <= 1'b0;   v6_cs <= 8'd0;
        end else begin
            if (v6_ovf) v6_cs <= v6_cs + 8'd1;
            if (v6_cyc) begin
                v6_lfsr <= v6_ns;
                v6_cnt  <= v6_cnt + {28'b0, v6_n};
                v6_mm   <= v6_mm + {28'b0, v6_nbad};
                if (v6_any && !v6_v) begin
                    v6_v  <= 1'b1;
                    // CV = 本拍之前的累计字节数 + **本拍内**的 lane 号。
                    // ⚠️ 这里**不能**再加 v6_base: v6_cnt 在本拍开始前已经计入了
                    //    本字 ph=0 拍消费的那 4 个字节 ⇒ 它已经是"本拍第一个字节"
                    //    的全局序号 (ph=1 拍加 v6_base 会把那 4 字节算两遍 ——
                    //    v6 门 V1 实测 CV 恰好多 4, 就是这条)。
                    v6_cv <= v6_cnt + {28'b0, v6_fb};
                    v6_cg <= v6_gsel;
                    v6_ce <= v6_esel;
                    // CO = 该字节的**帧内**序号 - 42
                    v6_co <= v6_cfi + {12'b0, v6_csk} + {12'b0, v6_base}
                             + {12'b0, v6_fb} - V6_HDR;
                end
            end
        end
    end

    assign v6_dv_idx = v6_cv;
    assign v6_dv_got = v6_cg;
    assign v6_dv_exp = v6_ce;
    assign v6_dv_off = v6_co;
    assign v6_dv_mm  = v6_mm;
    assign v6_dv_v   = v6_v;
    assign v6_dv_sk  = v6_cs;
`endif

endmodule
