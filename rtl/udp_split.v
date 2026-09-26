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
`endif

endmodule
