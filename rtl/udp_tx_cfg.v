`timescale 1ns/1ps
//=============================================================================
// udp_tx_cfg.v — P5e-T2: UDP app 接口**发送侧**的目标锁存 + 使能门
//=============================================================================
// 位置: app UDP TX (AXIS 字流) → [本模块] → udp_tx_frame → tx_arb(新) → tx_arb
//
// 【为什么需要本模块】udp_tx_frame 的 cfg 是**静态端口** (udp_tx_frame.v:25-28:
// dst_mac/dst_ip/dst_port/src_port/csum_en) —— 它不是流式边带, 每帧换目标必须
// 由外部锁存成"帧内稳定"的值 (P1 的 udp_echo 就是这么干的: meta_valid 拍把
// 原帧的 src 锁进寄存器再喂 udp_tx_frame 的 cfg)。本模块 = 通用化的那一层。
//
// 【目标来源: learn-on-RX 的 peer 表】(二选一, 见下"为什么不选 tid 索引")
//   peer_wr 一拍把 {peer_mac, peer_ip} 写进表项并置有效位。表项来源在 wrapper
//   里 = **udp_split 的 meta 线束** (= udp_rx 的 meta_*, 匹配帧 w5 接受拍脉冲):
//   对端 mac/ip 都是从**收到的那个帧**里解析出来的 —— 单一"对端是谁"真值源,
//   不新增解析器 (T1 的原则: 不重复实现 RX 判据 ⇒ 两个判据不可能分歧)。
//   ⚠️ **T2 的原始方案 (慢路径 CONN_UP = scfg_ev_up) 已在 T3 废弃**: UDP 无连接
//   ⇒ 板上永不产生 CONN_UP ⇒ peer 表永远空 ⇒ UDP TX 永不激活 (T2 的"默认不发送"
//   在板上退化成"永不发送")。本模块的端口语义不变, 只换 wrapper 侧的驱动源。
//   **端口是配置而不是学习**: UDP 目标端口由 cfg_dst_port 静态配置, 本机端口
//   cfg_my_port —— 对端的临时端口不是 UDP 语义, 拿来当 UDP 目的端口是错的;
//   真实终端也是"地址学习 + 端口配置"。
//
// 【为什么不选 app 侧 tid 索引】(T1 结论: UDP 不合流到 TCP 的 AXIS ⇒ tid 需自定义)
//   ① tid 索引要有一张可被索引的 peer 表才有意义, 而 T2 阶段没有任何"多对端"
//      需求 (app UDP 口是单对端会话): 表 + 索引 = 纯开销。
//   ② app 侧 tid 需要 app 先知道"对端标识从哪来" —— 那正是 learn-on-RX 提供的,
//      即 tid 方案是 learn 方案的超集而非替代。
//   ③ 目标一旦换了, 语义上必须换帧 (帧内换目标 = 帧头与载荷不一致), 本模块
//      "空闲刷新 + 帧内冻结"结构对两种方案都成立 ⇒ 将来 T3 要多对端, 只需把表项
//      数组化 + 加 frame_tid 输入, 本模块的锁存/门控结构**不需要改** (扩展局部)。
//
// 【默认不发送 (零回归的论证)】
//   表项有效位 peer_v 复位为 0, 且**没有任何其它路径**能发送:
//     · 帧首拍待发 (s_axis_tvalid && first_r) 而 peer_v==0 ⇒ deny=1 ⇒
//       s_axis_tready=0 (app 的帧被拒在门外, 按 AXIS 契约保持稳定等待)
//       且 m_axis_tvalid=0 (下游 udp_tx_frame 完全看不到这一帧)。
//     · 所以"无 peer"⇒ udp_tx_frame 的输入恒空 ⇒ 它永远停在 S_RECV ⇒
//       TX 线上零新增帧。P5 板上行为 (无 CONN_UP 学习事件) 与 T1 完成后逐位一致。
//   app 侧推帧被拒时计 stat_deny (每帧 1 次, 计"进入拒绝"的沿), 不是静默吞掉:
//   帧不会丢 (它还在 app 手里), 配置好 peer 后**原帧照发** (TB 有该用例)。
//   o_ready (→ wrapper 的 app_udp_tx_ready) 就是 "peer_v": app 可据此门控自己
//   的生成器, 避免推出注定被拒的帧。
//
// 【cfg 稳定性: 空闲刷新 + 帧窗口冻结 + 启动同步门】 (实测两轮才做对, 见下)
//   下游 udp_tx_frame 在**两个不同时刻**采 cfg: ① 帧首被接受的那个边沿
//   (csum_init_val = src_ip+dst_ip+0x0011 -> checksum16.init) ② S_HDR 拍与
//   TLAST 拍 (帧头字节 + ip_csum_calc)。所以任何"帧中途/帧尾后"的 cfg 变化都会
//   让同一帧的头与校验和取自两个对端。
//   ⇒ ① **冻结窗口** = 本层帧在途 (first_r=0) **直到下游回到空闲 (frame_busy=0)**,
//        而不是到"最后一拍被接受"为止 (后者仍会在报文传输期间放走 cfg 变化)。
//      ② **启动同步门**: o_* 未与源对齐 (刷新未落地) 时不许帧首拍进下游 —— 否则
//        刷新与帧首拍同一边沿, 下游那些组合采样点采到的是刷新前的旧值 (复位后
//        首帧 UDP 校验和少 src_ip+dst_ip; 换 peer 后首帧差两个 IP 之差)。
//
// 【反压合同】本模块是**纯组合直通 + 门** (无缓冲, II=1):
//   m_axis_tvalid = s_axis_tvalid && !deny   (deny 时下游不可见)
//   s_axis_tready = m_axis_tready && !deny
//   tid/tkeep/tlast/tdata 逐位透传。位宽/时序与既有 AXIS 级一致 (坑 4: 无寄存器化
//   的 rd/valid 变形)。
//=============================================================================
module udp_tx_cfg (
    input  wire        clk,
    input  wire        rst_n,
    // ---- peer 表写口 (RX 学习事件; 单表项 = 单对端会话语义) ----
    input  wire        peer_wr,      // 一拍脉冲, 写 {peer_mac, peer_ip} 并置有效
    input  wire [47:0] peer_mac,
    input  wire [31:0] peer_ip,
    // ---- 下游帧器状态: 1 = udp_tx_frame 非空闲 (帧在收或在发) ----
    // 冻结窗口必须盖到"帧头已发出"为止: cfg 在下游被两个时刻采样 (帧首拍的
    // init_val + S_HDR/TLAST 拍的帧头字节), 所以窗口 = 首拍 ... 下游回 S_RECV。
    input  wire        frame_busy,
    // ---- 静态配置 (本机 + 端口 + 校验和) ----
    input  wire [47:0] cfg_my_mac,
    input  wire [31:0] cfg_my_ip,
    input  wire [15:0] cfg_my_port,  // 本机 (源) UDP 端口
    input  wire [15:0] cfg_dst_port, // 对端 (目标) UDP 端口
    input  wire        cfg_csum_en,  // 1 = 算 UDP 校验和 (0 = 字段置 0)
    // ---- app UDP TX (AXIS 字流: 一帧 = 一个 UDP 数据报) ----
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    // ---- 门后字流 → udp_tx_frame ----
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    // ---- cfg → udp_tx_frame (空闲刷新, 帧内冻结 ⇒ 整帧稳定) ----
    output reg  [47:0] o_dst_mac,
    output reg  [31:0] o_dst_ip,
    output reg  [15:0] o_dst_port,
    output reg  [47:0] o_src_mac,
    output reg  [31:0] o_src_ip,
    output reg  [15:0] o_src_port,
    output reg         o_csum_en,
    // ---- 门控 / 统计 ----
    output wire        o_ready,        // peer 表有效 (→ app_udp_tx_ready)
    output reg  [31:0] stat_frames,    // 通过门的帧数
    output reg  [31:0] stat_deny       // 被门拒的帧数 (每帧 1 次, 非逐拍;
                                       // 两种原因: 无 peer / cfg 刷新未落地)
);
    reg        peer_v;                 // 表项有效位 (复位 0 = 默认不发送)
    reg [47:0] peer_mac_r;
    reg [31:0] peer_ip_r;
    reg        first_r;                // 下一被接受拍 = 帧首拍
    reg        deny_r;                 // 上一拍 deny (上升沿计数用)

    assign o_ready = peer_v;

    //=========================================================================
    // cfg 锁存: **空闲持续刷新, 帧窗口内冻结** + **启动同步门**
    //=========================================================================
    // 空闲 = 本层下一拍即帧首 (first_r) 且下游已回到空闲 (frame_busy=0)。
    // 冻结窗口必须盖满 "帧首拍 ... 下游帧头发出": 下游在帧首拍采 init_val, 在
    // S_HDR/TLAST 拍采帧头字节 —— 中间改 cfg 会让同一帧的头与校验和用两个对端
    // (实测: 头=新 peer+csum=旧 peer, 首帧则是 csum 少 src_ip+dst_ip)。
    wire idle = first_r && !frame_busy;
    // 启动同步门: o_* 必须已经等于源值 (刷新已落地) 才允许帧首拍进下游。
    // 否则会出现"刷新与帧首拍同一边沿"的采样歧义 (下游采到刷新前的旧值)。
    // 声明顺序: 本门在下面被 deny 引用 ⇒ 必须先声明 (xvlog 不容后置声明)。
    wire cfg_sync = (o_dst_mac  == peer_mac_r)  && (o_dst_ip  == peer_ip_r) &&
                    (o_dst_port == cfg_dst_port) && (o_src_mac == cfg_my_mac) &&
                    (o_src_ip  == cfg_my_ip)    && (o_src_port == cfg_my_port) &&
                    (o_csum_en == cfg_csum_en);

    // 帧首拍待发: 本拍就是某帧的第一拍 (first_r 在帧末拍后回 1)
    wire first_pend = s_axis_tvalid && first_r;
    // 无 peer (表空) 或 cfg 未同步 ⇒ 本帧连门都不进 (帧留在 app 手里, 不丢)
    wire deny       = first_pend && (!peer_v || !cfg_sync);

    assign s_axis_tready = m_axis_tready && !deny;
    assign m_axis_tvalid = s_axis_tvalid && !deny;
    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tkeep  = s_axis_tkeep;
    assign m_axis_tlast  = s_axis_tlast;

    wire pass = s_axis_tvalid && s_axis_tready;   // = m_axis_tvalid && m_axis_tready

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            peer_v <= 1'b0; peer_mac_r <= 48'd0; peer_ip_r <= 32'd0;
            first_r <= 1'b1; deny_r <= 1'b0;
            o_dst_mac <= 48'd0; o_dst_ip <= 32'd0; o_dst_port <= 16'd0;
            o_src_mac <= 48'd0; o_src_ip <= 32'd0; o_src_port <= 16'd0;
            o_csum_en <= 1'b0;
            stat_frames <= 32'd0; stat_deny <= 32'd0;
        end else begin
            // peer 表写口 (RX 学习 / 将来 app 寄存器): 帧内写不影响本帧 (o_* 冻结)
            if (peer_wr) begin
                peer_v     <= 1'b1;
                peer_mac_r <= peer_mac;
                peer_ip_r  <= peer_ip;
            end
            // ---- cfg 锁存: **空闲拍持续刷新, 帧内冻结** ----
            // ⚠️ 为什么不是"帧首拍同拍锁存": udp_tx_frame 在**帧首被接受的那个边沿**
            // 组合采 cfg (csum_init_val = src_ip+dst_ip+0x0011 喂 checksum16 的 init),
            // 而帧头字节是后来的 S_HDR 拍采的。若本模块在同一个边沿才更新 o_*,
            // 则帧首那次采样拿到的是**上一帧/复位时的旧值** ⇒ 首帧/换 peer 后的首帧
            // UDP 校验和错 (实测: 首帧差 src_ip+dst_ip, 换 peer 帧差两个 IP 之差;
            // 帧头字节却是新值 = 上下游分歧, 单体 TB 才能抓到)。
            // 空闲刷新 ⇒ 帧首拍之前 o_* 已稳定至少 1 拍, 下游任何采样点都同源。
            if (idle) begin
                o_dst_mac  <= peer_mac_r;
                o_dst_ip   <= peer_ip_r;
                o_dst_port <= cfg_dst_port;
                o_src_mac  <= cfg_my_mac;
                o_src_ip   <= cfg_my_ip;
                o_src_port <= cfg_my_port;
                o_csum_en  <= cfg_csum_en;
            end
            if (pass) first_r <= s_axis_tlast;   // 帧末拍后回到"下一拍是帧首"
            // 统计
            if (pass && s_axis_tlast) stat_frames <= stat_frames + 32'd1;
            if (deny && !deny_r)     stat_deny   <= stat_deny + 32'd1;
            deny_r <= deny;
        end
    end
endmodule
