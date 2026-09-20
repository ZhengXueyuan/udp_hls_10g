`timescale 1ns/1ps
// TCP TX 组帧器: ACK 段 (tcp_rx 请求, 无载荷) + app 数据段 (AXIS 字流) ->
// 完整 TCP/IP/以太网帧字流 (给 mac_tx_64)。ACK 优先于数据 (对端时延敏感)。
//
// 帧级递交 (同 udp_tx_frame 原因): TCP 校验和覆盖伪头+头+全载荷, 字段在头里
// (字节 50-51) — 载荷整帧入 FIFO 同时流过 checksum16, TLAST 后校验和落定再发。
//
// 头字构造 (左对齐, 帧首 = tdata[63:56], TCP 头 20B, 头共 54B = 6 整字 + 6 字节):
//   w0 = dst_mac+src_mac[47:32]; w1 = src_mac[31:0]+0800+45+00
//   w2 = total_len+id+0000+40+06; w3 = ip_csum+src_ip+dst_ip[31:16]
//   w4 = dst_ip[15:0]+src_port+dst_port+seq[31:16]
//   w5 = seq[15:0]+ack[31:0]+50(doff)+flags; w6 = window+tcp_csum+urg+载荷[0..1]
// 载荷相对帧头 6 字节偏移: 输出字 = {hold48, 当前载荷字高 2 字节} (hold48 初值 =
// {window, csum, urg}); 溢出尾字 = 末载荷字低 6 字节区左对齐 n-2 字节。
//
// 校验和 (与 UDP 不同!): TCP 头无长度字段, tcp_len 只在伪头计一次; 9 个半字分
// 3 拍 aen 补足 (checksum16 add_val 仅 18 位, 每组 ≤4 项不溢出)。init = src_ip +
// dst_ip + 0x0006。伪头协议字节 0x06。纯 ACK 段 flags=0x10, 数据段 0x18 (PSH+ACK)。
// 数据段 seq = TCB snd_nxt (首拍锁存), 发完 snd_nxt += plen; ack = rcv_nxt。
// 对端信息 (dmac/dip/端口) 由 CAM 读回口按 conn_id 组合取得, 首拍锁存。
// app 契约: 载荷 ≤1500B (plen 12 位, 超 4095 回绕不检查); S_IDLE 因 ACK 优先或
// FIFO 满挡数据期间, app 须保持 tdata/tkeep/tlast/tid 稳定 (presenting 契约)。
// csum_valid 由 fin 时序保证 (aen→fin→取数固定间隔), 不另检查。
module tcp_tx_frame (
    input  wire        clk,
    input  wire        rst_n,
    // app 载荷输入 (左对齐; tid = conn_id, 帧内稳定; 零长帧 = 单拍 tlast 且 tkeep=0)
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire [3:0]  s_axis_tid,
    // ACK 请求 (tcp_rx 脉冲 / tcp_synp SYN+ACK 请求; 入 8 深队列, 满则丢并计数)
    input  wire        ack_req,
    input  wire [3:0]  ack_id,
    input  wire [31:0] ack_val,
    input  wire        ack_syn,        // 1 = SYN+ACK 段 (flags=0x12, 发完 snd_nxt+1)
    // ---- P5: FIN/RST 发送通道 ----
    // ack_fin/ack_rst 兄弟 ack_syn (ackq 条目标志): FIN = flags 0x11 (发完
    // snd_nxt+1, 置 fin_sent_r/fin_seq_r), RST = flags 0x14 (发完 snd_nxt+1)。
    // fin_req/rst_req 是 app 侧每连接电平请求 (app_ctrl 产生; 本模块自扫描
    // 排队, 不消耗 app 侧 ACK 队列):
    //   FIN: 只在 snd_nxt == snd_una (无在飞数据) 且 state==ESTAB 时排队 (D4)
    //         — ring 不覆盖 FIN 的 1 字节 seq, 有在飞时排队会让 svc 回卷把
    //        FIN 的 seq 当 ring 数据重放 (垃圾载荷)。
    //   RST: 只要 ESTAB 即排队 (不消费 seq 语义, 中止用)。
    // 请求在 fin_sent_r/rst_sent_r 置位后不再重复排队 (每连接一次); 连接
    // 非 ESTAB 时 (扫描采到 state != 1) 清 fin_sent_r/rst_sent_r (重连可再用)。
    input  wire        ack_fin,
    input  wire        ack_rst,
    input  wire [15:0] fin_req,
    input  wire [15:0] rst_req,
    // P5a 复核 D1 修复: cfg ADD 收尾脉冲 (slow_cfg_adp 的 ev_up + ev_slot) —
    // 该槽重新建连时显式清 FIN/RST 已发标志。**不能只靠扫描清** (原来只在
    // scan_now 看到 rb_state!=1 时清): 背靠背 DEL→ADD (间隔 ~70 拍) 落在两次
    // 扫描 (~256 拍) 之间时 state=0 从未被采到 -> fin_sent_r 永久残留 ->
    // start_data 永久挡住该连接 -> app 字被吞进载荷 FIFO 却组不了帧 -> FIFO 满
    // + FSM 卡 S_IDLE = 数据面死锁 (测试 agent 实测, gap≈70 拍即现 / 4000 拍正常)。
    input  wire        cfg_up,
    input  wire [3:0]  cfg_up_id,
    output wire [15:0] o_fin_sent,     // 每连接 FIN 已发出 (纯线束, app_ctrl 用)
    // ---- P5c-T3 G3: abort 硬化 (TX fence) ----
    // RST 已发出 (每连接) ⇒ 该连接不再接受 app 数据帧 (abort 后不得再发数据)。
    // 与 fin_sent_r 同惯例的黑名单位; 纯线束 (app_ctrl 的 app_tx_ready 用)。
    // 清除路径与 rst_sent_r 完全一致 (扫描见 state!=ESTAB / cfg_up 收尾脉冲)
    // ⇒ fence 生命周期 = [RST 发出, state=0 落地并被扫描采到]。
    output wire [15:0] o_rst_sent,     // 每连接 RST 已发出 (abort fence; app_ctrl 用)
    // ---- P5b: 窗口更新 (wu) 条目通道 (app_ctrl 窗口重开 ACK) ----
    // wu_req 是**电平请求 + gnt 握手** (与 fin_req 同惯例): 保持到 wu_gnt 回来。
    // 条目 {wu_id, syn=0, fin=0, rst=0, wu_val} — 三标志皆 0 ⇒ 走现有"纯 ACK"
    // 路径 (ack = 条目 val, seq = rb_snd_nxt), **帧组装零改动** ✓。
    // wu_val = 该连接 rcv_nxt 的扫描采样值 (app_ctrl 提供): 与它同拍写进 TCB 的
    // 通告窗口同源自洽 (右沿 = wu_val + 帧里的 window 字段 = redge)。
    input  wire        wu_req,
    input  wire [3:0]  wu_id,
    input  wire [31:0] wu_val,
    output wire        wu_gnt,         // 1 拍脉冲: 条目已**确实入队** (见 wu_push)
    // TCB 读口 B (顶层实例化 tcb 并连线)
    output wire [3:0]  rb_id,
    input  wire [31:0] rb_snd_nxt,
    input  wire [31:0] rb_rcv_nxt,
    input  wire [15:0] rb_rcv_wnd,
    // P4b-6 窗口门控: 在飞字节 = snd_nxt - snd_una, >= 对端通告窗口 (drain 时已
    // 按 wscale 缩放) 则不开新数据帧 (纯 ACK 不挡 — 保活/窗口探测语义不受影响;
    // 无门控时板测实锤: PC 窗口关死后 FPGA 狂发被栈层静默丢弃, echo seq 出现
    // 永久空洞, 对端等缺失字节 -> 双向死锁 -> RST)
    input  wire [31:0] rb_snd_una,
    input  wire [15:0] rb_snd_wnd,
    input  wire [3:0]  rb_state,        // P5: FIN/RST 排队门 + 已发标志清理 (ESTAB=1)
    // P4b-7-P6 窗口门控注册读口 (tcb win 读口输出 -> 本模块输入): 门控决策全
    // 出自 tcb 内注册比较 — wnd_open 决策链无任何 TCB 组合读。
    // P4b-7-P6-fix: win_open = 注册的 32 位回绕正确门 (snd_nxt-snd_una 全 32 位
    // 减法与帽比较都在 tcb 内注册完成; 旧 16 位 hi_eq+低 16 位差门在在飞区间
    // 跨越 64K 边界时误关, 板上实锤冻结, 已废除)。win_inflight/win_wnd_eff
    // 保留为输入仅为接口/顶层 debug 走线稳定, 本模块不再消费。
    input  wire        win_open,           // 注册门: 在飞 (32 位回绕差) < 窗帽
    input  wire [15:0] win_inflight,       // 保留 (debug 走线, 门控不用)
    input  wire [15:0] win_wnd_eff,        // 保留 (debug 走线, 门控不用)
    // 重传请求 (P3: tcp_rx dup-ACK 检测电平保持至 retx_gnt; P2 先接地, RTO 自触发)
    input  wire        retx_req,
    input  wire [3:0]  retx_id,
    output wire        retx_gnt,           // 脉冲: retx_req 已服务 (回卷或确认空)
    output reg  [31:0] stat_retx,          // 回卷次数 (重传会话启动数)
    // P4d-fix 会话高水位暴露 (给 tcp_rx 的 ack_ok 上界; 纯线束 assign, 零逻辑):
    // 回卷把 snd_nxt 降到 snd_una, 本会话重放上界 = 回卷前 snd_nxt = retx_hi
    // (= 真正发送过的最高字节)。会话期间 ACK 合法上界必须用它 (理由见 tcp_rx)。
    output wire [31:0] o_retx_hi,          // 回卷高水位 (retx_active=1 时有效)
    output wire        o_retx_active,      // 重传会话进行中
    output wire [3:0]  o_retx_id,          // 会话连接 (P4d-fix 注的多连接加固项)
    // TCB 更新 (数据段末字消费拍组合脉冲: sel=1 snd_nxt <= seq+plen;
    // 与状态回 S_IDLE 同拍写入 — 下一帧最早下拍启动, 读到的是更新后的值)
    output wire        upd_wr,
    output wire [3:0]  upd_id,
    output wire [2:0]  upd_sel,
    output wire [31:0] upd_val,
    // CAM 读回 (顶层连 tcp_cam 读回口; 慢路径保证条目有效)
    output wire [3:0]  cam_rd_id,
    input  wire [47:0] cam_rd_dmac,
    input  wire [31:0] cam_rd_sip,     // 对端 IP = 发送帧 dst IP (dip 字段是本地 IP!)
    input  wire [15:0] cam_rd_sport,   // 对端端口 = 发送 dst_port
    input  wire [15:0] cam_rd_dport,   // 本地端口 = 发送 src_port
    // 配置
    input  wire [47:0] cfg_src_mac,
    input  wire [31:0] cfg_src_ip,
    // 帧字流输出 (接 mac_tx_64)
    output reg  [63:0] m_axis_tdata,
    output reg  [7:0]  m_axis_tkeep,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,
    // 统计
    output reg  [31:0] stat_frames,
    output reg  [31:0] stat_bytes,
    output reg  [31:0] stat_ack,        // 发出的纯 ACK 段数
    output reg  [31:0] stat_ack_drop,   // ACK 队列满丢弃
    output reg  [31:0] stat_eend,       // S_PAY 欠载提前收帧 (结构不可达; 亮灯即缺陷 A)
    // P5: 超长帧帧内中止丢弃数 (len_bad; app 契约违规兜底) + FIN/RST 段数
    output reg  [31:0] stat_drop_len,
    output reg  [31:0] stat_fin,
    output reg  [31:0] stat_rst,
    // P4b-7-P6 tlast 探针: 帧器吞到 tlast 的次数 (S_IDLE/S_RECV 的 accept && tlast)。
    // 与 tcp_echo stat_tlast_wr/fwd 对账: wr>0 而本计数 0 => tlast 死在 echo→帧器之间
    // (frame_fifo 读出 / axis_pipe / 帧器接受的 tlast 通路)。
    output reg  [31:0] stat_tlast_in,
    // ---- P4b-7-P6 调试探针 (纯 assign 线束输出, 不动任何逻辑) ----
    output wire        dbg_wnd_open,   // 窗口门控开 (wnd_open, S_IDLE 决策)
    output wire        dbg_pay_full,   // 载荷 FIFO 满 (pay_full)
    output wire        dbg_sready,     // s_axis_tready (接受活数据)
    output wire        dbg_saxis_tvalid, // s_axis_tvalid (帧器输入侧活请求, P6)
    output wire [11:0] dbg_plen_r,     // plen_r 帧载荷累计字节 (P6: S_RECV 吞到多少)
    output wire [2:0]  dbg_state,      // P6: tx FSM state 寄存器 (冻结态是否非法?)
    // P4b-7-P6 u_fifo 指针探针: 载荷 FIFO 报告 FULL 而单帧仅 183 字 —
    // wptr/rptr 差值 = 实际占用, 与 plen 对账可判"真满 vs 假满/溢出"
    output wire [8:0]  dbg_pay_wptr,   // u_fifo wptr[8:0]
    output wire [8:0]  dbg_pay_rptr,   // u_fifo rptr[8:0]
    output wire        dbg_pay_full2,  // u_fifo full (与 dbg_pay_full 同源, 直连端口)
    output wire        dbg_pay_empty,  // u_fifo empty
    output wire [11:0] dbg_plen        // RUNNING plen (帧内累计, 未锁存; 区别于 plen_r)
);

    parameter integer RTO_LIM  = 48828;    // RTO = RTO_LIM 次连接访问 x 16 tick x 16 连接
                                           // = 12.5M 拍 ≈ 100ms @125MHz (tick 版扫描, 见 scan_now)
    // P4c: 门控帽 0x2FFE -> 0xBFFE (窗口 12KB -> 48KB-2; tcb win 读口内亦硬编码
    // 同值, 两处必须一致)。
    // 门控消费 1 拍注册在飞 (win_open = 32 位回绕差 < 帽, 见下): 帧完成写
    // snd_nxt 的当拍, 下一 S_IDLE 决策读到的仍是旧值, 可误开 1 拍 (OPEN
    // 方向, 每次最多多放 1 帧); 连接切换 (scan/svc/ack 旁路 rb_id) 同效。
    // 实际在飞最坏 = (RING_CAP-1) + plen_max 4095 = 53244 < 65536 ring 字节
    // (retx_ram 13 位 ring 字 idx = 64KB/conn) — 硬 ring 界仍结构性成立,
    // 永不溢出。窗帽与在飞差均 32 位计算, 全 4GB 序列空间回绕正确
    // (帽 0xBFFE << 64K, 无 16 位化边角)。
    parameter [15:0]  RING_CAP = 16'hBFFE; // 窗口门控帽 (ring 容量的收紧版, 见上)
    // P5 长度守卫上界 (app 契约: 一帧 = 一个 TCP 段 ≤1460B; 这里放到 1500 留
    // 余量)。超过即整帧中止 (不写 FIFO/ring/csum, 不收帧, tlast 拍回 S_IDLE
    // 并冲洗已写入的字节 + stat_drop_len++)。上界必须 < 载荷 FIFO 容量
    // (256 字 = 2048B): 超限检出拍最多已写入 (PLEN_MAX+7)/8 = 188 字, 永不满
    // 也永不触发 pay_full 死锁 (>2048B 的帧在旧代码里会把 256 深 FIFO 顶死)。
    parameter [11:0] PLEN_MAX = 12'd1500;
    // P5b C8: ACK 队列深度提为参数 (原字面量 8/3)。板级突发丢帧时乱序 dup-ACK
    // 成组到达, 8 深溢出 ⇒ dup-ACK 全丢 ⇒ 对端只能等 200ms RTO (P5a-0 板级
    // 观测到的 TX 静默)。32 深 = LUTRAM 32:1 读 mux (时序注意: ackq_dout 只喂
    // start_id/aq_* 的寄存器路径, ack_pend_r 已切断最长链)。时序告急时一键回退
    // 16 (改这一处即可)。**无条件改动** (echo 模式同病理, 加深是纯改进 —
    // 不改变任何既有语义, 只减少 stat_ack_drop)。
    // ⚠️ 必须与上面参数同风格 (module body 内 parameter): 改成 ANSI 风格
    // #(...) 参数表会让 body 里的 RING_CAP/PLEN_MAX 变成不可覆盖
    // (xvlog: "localparam 'RING_CAP' cannot be overwritten") ⇒ 顶层
    // .RING_CAP(WIN_CAP_5) 覆盖失效 (实测踩过)。
    parameter integer ACKQ_D  = 32;
    parameter integer ACKQ_AW = 5;

    localparam [2:0] S_IDLE = 3'd0, S_RECV = 3'd1, S_WAIT = 3'd2, S_HDR = 3'd3,
                     S_PAY  = 3'd4, S_TAIL = 3'd5, S_DONE = 3'd6, S_RING = 3'd7;

    reg  [2:0]  state;
    reg  [11:0] plen;
    reg  [11:0] plen_r;
    reg  [15:0] tcp_len_r, total_len_r, ip_csum_r, tcp_csum_r;
    reg  [15:0] id_r, id_cap;
    reg  [2:0]  wait_cnt;
    reg  [2:0]  hcnt;
    reg  [47:0] hold48;
    reg  [63:0] tail_d;    // ljust6 返回 64 位左对齐字, 截断会丢高 2 字节
    reg  [7:0]  tail_k;
    // 帧首拍锁存
    reg  [3:0]  cur_id;
    reg         is_data_r, is_syn_r;
    reg         is_fin_r, is_rst_r;       // P5: FIN/RST 帧 (flags 0x11/0x14)
    // P5 长度守卫: len_bad = 本帧已超 PLEN_MAX (帧内中止); flush_pend = 中止后
    // 待冲洗 u_fifo 里已写入的字节 (S_IDLE 排空才清)
    reg         len_bad, flush_pend;
    // P5 FIN/RST 状态 (每连接)
    reg  [15:0] fin_sent_r;               // FIN 已发出 (阻止重复排队)
    reg  [15:0] rst_sent_r;               // RST 已发出
    reg  [31:0] fin_seq_r [0:15];         // FIN 的 seq (= 发出时 snd_nxt, RTO 用)
    reg  [15:0] fin_retx_pend;            // FIN 在飞被回卷打断 -> ring 会话排空处重推
    reg  [31:0] seq_r, ack_r;
    reg  [15:0] wnd_r;
    reg  [15:0] doff_flags_r;
    reg  [47:0] dmac_r;
    reg  [31:0] dip_r;
    reg  [15:0] sport_r, dport_r;
    // ---- P4b-7 重传状态 (retx 空闲时全部静止, 零行为影响) ----
    reg         retx_active;              // 重传会话进行中 (ring 帧源仲裁门)
    reg  [3:0]  retx_id_r;                // 会话连接
    reg  [31:0] retx_hi;                  // 会话重发上界 (svc 拍锁存回卷前 snd_nxt)
    reg  [3:0]  scan_id;                  // RTO 扫描指针 0..15 (每空闲拍 +1)
    reg  [20:0] rto_timer [0:15];         // 每连接 RTO 计时 (以该连接扫描次数计)
    reg  [15:0] rto_pend;                 // 每连接 RTO 未决 (等 svc 回卷)
    reg  [31:0] ring_seq;                 // ring 读游标 (S_RING 内待读字 seq)
    reg  [11:0] ring_rem;                 // P4b-7-P6: 本 ring 帧末 beat 字节数 (1..8)
    reg  [7:0]  nbeats;                   // P4b-7-P6: 本 ring 帧 beat 数 ((plen+7)>>3, <=183)
    reg  [7:0]  beat_cnt;                 // P4b-7-P6: S_RING 已发读的 beat 数 (1..nbeats+1)
    reg  [63:0] ring_d_r;                 // P4b-7-P6: ring 读出第 2 级 (拆 DOBDO->acc 路径)
    reg  [31:0] tap_seq;                  // ring 写游标 (下一待写字节 seq)
    // ---- P4b-7-P5 SEV2-1: RTO 无进展上限 (每连接) ----
    reg  [31:0] snd_una_prev [0:15];      // 上次 svc 拍的 snd_una (进展比对基)
    reg  [3:0]  epoch [0:15];             // 连续 svc 无进展会话计数 (封顶 15)
    integer     ri;

    // ---- P4d-fix 会话状态线束输出 (纯 assign, 与内部逻辑零耦合) ----
    assign o_retx_hi     = retx_hi;
    assign o_retx_active = retx_active;

    // ---- ACK 请求队列 ([38:35]=id [34]=syn [33]=fin [32]=rst [31:0]=ack_val) ----
    // P5: 37 -> 39 位 (加 fin/rst 标志两 bit; 计划文档写 38 是笔误 — 两个标志
    // 位 + 4 位 id + syn 位 + 32 位 ack_val = 39)
    localparam ACKQ_W = 39;
    wire        ackq_full, ackq_empty;
    wire [ACKQ_W-1:0] ackq_dout;
    wire        pay_full, pay_empty;
    wire        ack_pend = !ackq_empty;
    // P6 时序: ack_pend 寄存器化 (ack_pend_r) — 否则 ackq wptr -> ackq_empty
    // -> ack_pend -> start_id 复用 -> rb_id -> TCB -> wnd 比较 -> WEA 仍为最差
    // 路径 (实测 WNS -1.4ns)。ack_pend_r 用于所有仲裁/start_id 选择 (1 拍旧
    // 值只把 ACK 优先推迟 1 拍); start_ack 使能另加组合 !ackq_empty 防伪启动
    // (ack_pend_r 滞后 1 拍期间 ackq 已被弹出, 空读会发垃圾 ACK 帧)。
    reg         ack_pend_r;
    wire [3:0]  start_id = ack_pend_r ? ackq_dout[38:35] : s_axis_tid;
    // 队列条目字段别名 (W=39; 见 ACKQ_W 注释)
    wire        aq_syn  = ackq_dout[34];
    wire        aq_fin  = ackq_dout[33];
    wire        aq_rst  = ackq_dout[32];

    // ---- S_IDLE 帧启动仲裁链 (P4b-7): ack > retx svc > ring 帧 > RTO 扫描 > 活数据 ----
    // svc: 回卷一次重传会话 (snd_nxt <= snd_una, 占 TCB 写口 1 拍); svc_id 请求源
    // 优先 retx_req (电平, tcp_rx), 否则 RTO 未决最低位连接。
    // P6 时序: svc_id 优先级编码寄存器化 (svc_id_r) — 否则 rto_pend -> prio_lo
    // -> rb_id 复用 -> TCB 读 mux -> rb_snd_nxt -> w_tap_seq 位选 -> retx_ram
    // 写口 DIADI 成最差路径 (WNS -1.4ns)。svc_id_r 恒为上拍值: rto_pend 在
    // 扫描拍置位、下拍 svc 消费, 1 拍旧值恰为正确连接; retx_req 为电平且
    // retx_id 稳定, 亦无竞态。
    reg  [3:0]  svc_id_r;
    wire [3:0]  svc_id  = svc_id_r;
    // P6 时序: rto_pend 的 16 入 OR 也寄存器化 (rto_pend_any) — 否则
    // rto_pend -> |rto_pend -> svc -> rb_id 选择位 -> TCB 读 -> w_tap_seq
    // -> retx_ram ADDR 仍是最差路径 (实测 WNS -1.5ns)。rto_pend_any 滞后
    // 1 拍, 与 svc_id_r 同拍同源 (均自 rto_pend@上拍), 语义一致; retx_req
    // 为寄存器电平无路径。
    reg         rto_pend_any;
    // P5 长度守卫冲洗门: flush_pend 期间 S_IDLE 只做 u_fifo 排空 — 新帧启动/
    // svc/ring/scan 全部压住 (否则新帧的字会与待冲洗的旧字节混在同一 FIFO 里,
    // 排空指针可能吃掉新帧首字)。flush 只在超长帧中止后出现 (P4 流程恒 0)。
    wire        flush_act = (state == S_IDLE) && flush_pend;
    wire        svc     = (state == S_IDLE) && !ack_pend_r && !retx_active &&
                          !flush_pend && (retx_req || rto_pend_any);
    // ring_eval: retx 会话期间每个无 ACK 的 S_IDLE 拍评估 (ack 插帧不打断会话)
    wire        ring_eval = (state == S_IDLE) && !ack_pend_r && retx_active && !svc &&
                            !flush_pend;
    // ---- P5c-T1 G4: "连接可服务"门 (scan_estab) ----
    // 慢路径 DEL **只写 state=0** (slow_cfg_adp.v S_TCB: upd_sel=5 val=0), CAM 该
    // 槽已清零, 而 TCB 的 snd_nxt/snd_una/snd_wnd 全部原样保留。于是"死连接"在扫描
    // 眼里仍满足 snd_wnd!=0 && snd_nxt!=snd_una: 老代码照旧装 RTO -> rto_pend ->
    // svc 回卷 -> 从 ring 重放数据, 而帧的 dst MAC 取自已清空的 CAM (=0) — 对端收到
    // 垃圾帧 (G4)。故扫描侧装表、ring 重放、未决重传保留都必须要求 ESTAB。
    // 默认构建 (P4) 取 `1'b1` 保持老行为 (逐位不变, 硬约束): P4 无 FIN/RST/abort
    // 语义, 本门只服务 APP_MODE 关闭流程的清理。TL 裁决: 直接把 rb_state 加进装表
    // 条件必须包 ifdef — 无 ifdef 的"cfg_up 清 rto_pend/rto_timer"等效写法**不足以**
    // 覆盖 DEL 侧 (DEL 后计时器下一轮扫描仍会重新装表, 见上)。
`ifdef APP_MODE
    wire        scan_estab = (rb_state == 4'd1);
`else
    wire        scan_estab = 1'b1;
`endif
    wire [31:0] ring_delta = retx_hi - rb_snd_nxt;   // rb_* 已 mux 到 retx_id_r
    // G4: 死连接不再起 ring 重放 (否则整段在飞窗口重放给一个 CAM 已清空的连接)。
    // ring_start 被否后 ring_eval 走"排空拍"分支 => 会话在下拍收尾 (不退化成死锁)。
    wire        ring_start = ring_eval && (ring_delta != 32'd0) && scan_estab;
    // SEV2-2 (P6 重做): 扫描由自由运行 tick 驱动 (每 16 拍 1 次), 不再依赖
    // s_axis_tvalid。旧实现 (tvalid -> scan_now -> rb_id -> TCB 读 -> wnd 比较
    // -> accept -> retx 写口) 构成 19 级前向链, 板级 WNS -1.6ns; 且旧版门关+
    // tvalid 常高时扫描饿死 (force_scan 补丁又加深度)。tick 版: scan_now 与
    // tvalid 无组合关系 (无环无长链), 门关/数据展示期间照常每 16 拍访问;
    // 帧间 S_IDLE 撞 tick 概率 ~1/16 帧 (~0.3% 吞吐)。RTO 时间 = RTO_LIM
    // 次连接访问 x 16 tick x 16 连接 = RTO_LIM x 256 拍 (见 RTO_LIM 参数注
    // 释)。start_data/s_axis_tready 仍须 !scan_now (该拍 rb_id 指向 scan_id,
    // 吞帧首字会写错 ring 游标)。
    reg  [3:0]  tick_cnt;                 // 自由运行 16 分频
    wire        scan_tick = (tick_cnt == 4'd15);
    wire        scan_now = (state == S_IDLE) && !ack_pend_r && !svc && !ring_eval &&
                           !flush_pend && scan_tick;
    wire        start_ack  = (state == S_IDLE) && ack_pend_r && !ackq_empty &&
                             !flush_pend;
    // P4b-7-P6-fix 窗口门控: wnd_open = tcb 注册输出的 win_open — 门 =
    // REGISTERED 32 位回绕正确的在飞 (snd_nxt - snd_una, 全 32 位) vs
    // RING_CAP 帽 (0xBFFE) 钳位后的对端通告窗, 比较在 tcb win 读口内完成
    // (32 位减法 + 16 位比较 + 帽 mux 全在寄存器块前, 输出即寄存器) —
    // rb_id -> TCB mux -> 减法/比较 -> tready -> accept -> retx_ram WEA/ADDR
    // 的最差前向链已断 (win_* 比 rb_* 旧 1 拍且按 rb_id 上一拍取值, 误开界见
    // RING_CAP 注释)。rb_* 仍供帧首锁存与 svc/ring 逻辑 (那些链以 FF 端点
    // 为终点, 不是最差路径)。1 拍陈旧性分析 (RING_CAP 0xBFFE, 最坏误开 ≤
    // (CAP-1)+4095 = 53244 < 65536 ring 字节) 保持不变 — 本修复只把 16 位
    // 高半相等门换成 32 位回绕正确比较, 无跨 64K 边界误关边角。
    wire        wnd_open  = win_open;
    // P5 FIN 前置硬规则 (D4): 已排队/已发出 FIN 的连接不再启动 app 数据帧
    // (无在飞时排队, 帧启动时再查一次 — 保证 FIN 之后不再有新数据)
    // P5c-T3 G3 (abort fence): 已发出 RST 的连接同样不再启动数据帧 — abort 之后
    // app 若继续推帧, 帧会带着数据/PSH 发给一个已中止的连接 (协议违规, 且 seq
    // 已被 RST 终结)。**必须与 s_axis_tready 同门** (坑 10/P5a D2: 接受门比启动门
    // 宽 ⇒ 字被吞进载荷 FIFO 却组不了帧 ⇒ FIFO 满 + FSM 卡 S_IDLE = 死锁)。
    // 默认构建 (fin_req/rst_req 恒 0) 下 rst_sent_r 无置位路径 (S_DONE 的
    // is_rst_r 仅由 ackq 条目的 rst 位来, 而该位仅由 rst_push(rst_req)/ack_rst 置)
    // ⇒ 本项恒 1, 逐位不变 (与 T1 的 G1 Option B 同惯例, 无需 ifdef) ✓
    // 时序: 三个屏蔽项合并成一个 16 位 OR 后只做**一次** start_id 选择 (与原来的
    // `!fin_req[sid] && !fin_sent_r[sid]` 逐位等价 — De Morgan: !a&&!b&&!c ≡
    // !(a|b|c), 且三位本来就是同源向量); 合并后 16:1 mux 由两个表达式共享 ⇒
    // 面积/深度都不比原式差 (该锥是最差路径: rb_id->TCB 读->wnd 比较->tready->
    // accept->retx_ram WEA, 基线 WNS 仅 +0.2~0.5ns)。
    wire [15:0] tx_blk = fin_req | fin_sent_r | rst_sent_r;  // 该连接禁止新数据帧
    wire        start_data = (state == S_IDLE) && !ack_pend_r && !svc && !ring_eval &&
                             !scan_now && !flush_pend && s_axis_tvalid && !pay_full &&
                             wnd_open && !tx_blk[start_id];

    // rb/cam 读口 mux: svc/ring_eval/scan_now 拍旁路 start_id (TCB/CAM 组合读,
    // 本拍即目标连接值)。scan_now 仅依赖 scan_tick (寄存器) 与 state/ack_pend_r
    // 等, 与 tvalid/wnd_open 无组合关系 — 无组合环且无长前向链。
    assign rb_id     = svc ? svc_id : ring_eval ? retx_id_r : scan_now ? scan_id :
                       (state == S_IDLE) ? start_id : cur_id;
    assign cam_rd_id = rb_id;

    // TCB 更新 (sel=1 snd_nxt): S_DONE 数据段末字消费拍 或 svc 回卷拍。两拍互斥
    // (svc 仅 S_IDLE, S_DONE 段仅 S_DONE), TCB 单写口无冲突。
    // SEV2-1: blocked = 该连接连续 16 次 svc 无 snd_una 进展 (对端死), 停回卷 —
    // 回卷写/stat_retx 全经 svc_rewind 门控; retx_gnt 不门控 (tcp_rx 电平请求
    // 始终释放), rto_pend 清/计时器重装亦无条件 (svc 每次照常应答)。
    wire        blocked = (epoch[svc_id] >= 4'd15);
    wire        svc_rewind = svc && (rb_snd_nxt != rb_snd_una) && !blocked;
    // P5c-T1 G9 修复①: blocked (对端连续 16 次 svc 无 snd_una 进展 = 死连接) **且
    // FIN 在飞**时不建 ring 会话。G9 的洪水源恰好是"blocked + FIN 在飞":
    //   svc_rewind=0 (不回卷, snd_nxt 停在 fin_seq+1) 而 retx_hi 被钉在 fin_seq
    //   (老代码无条件取 fin_seq) ⇒ ring_delta = fin_seq-(fin_seq+1) = 0xFFFFFFFF
    //   (32 位下溢) ⇒ ring_start=1, plen_preset=1460 ⇒ 把整圈陈旧数据当"待重放
    //   区间"洪水重放 (T2 实测 31 帧/12000 拍, 投影 2941758 帧/4096MB)。
    // 只否定这一种组合 (而不是照抄 `retx_active <= svc_rewind`): blocked 且无 FIN
    // 时会话本来就只有 1 拍气泡 (无回卷 ⇒ snd_nxt 不变 ⇒ delta 恒 0, 重放窗口为空),
    // 保留它才能让**默认构建逐位不变** — 默认构建 fin_sent_r 恒 0 ⇒ retx_deny 恒 0
    // ⇒ retx_begin === svc (与老代码同), 无需 ifdef ✓
    wire        retx_deny  = blocked && fin_sent_r[svc_id];
    wire        retx_begin = svc && !retx_deny;
    // P5: FIN/RST 段也推进 snd_nxt (+1; upd_val 的 !is_data_r 分支即 32'd1)。
    // 超长帧走中止支 (S_RECV -> S_IDLE), 永不进 S_DONE ⇒ 其字节不推进 snd_nxt。
    assign upd_wr  = ((state == S_DONE) && (is_data_r || is_syn_r || is_fin_r ||
                      is_rst_r) && m_axis_tvalid && m_axis_tready) || svc_rewind;
    assign upd_id  = svc_rewind ? svc_id : cur_id;
    assign upd_sel = 3'd1;
    assign upd_val = svc_rewind ? rb_snd_una :
                     seq_r + (is_data_r ? {20'b0, plen_r} : 32'd1);
    assign retx_gnt = svc && retx_req;

    // svc 拍 accept 必须禁 (start_data 被 svc 压制, accept 不再等于帧首拍消费,
    // 否则会吞一个既不入 FIFO 计数也不入 plen 的字)。P5 同理: flush_pend 期间
    // S_IDLE 不接受任何活帧字 (start_data 被 !flush_pend 压制, 否则 app 的字会
    // 被 accept 吞掉却既不进 FIFO 也不进 plen — 2000B 坏帧后实测丢 144B)。
    // P5a 复核 D2 修复: S_IDLE 的接受门必须与 start_data 的启动门**同门** —
    // 原来只挡启动不挡接受: fin_req/fin_sent_r 的连接帧起不来却照样把 app 的
    // 字收进载荷 FIFO (FIFO 满 + 无人排空 = 死锁)。start_id 在 !ack_pend_r 下
    // = s_axis_tid (本子句已排除 ack_pend_r)。
    // P5c-T3 G3: 与 start_data 用**同一个** tx_blk (同门铁律, 坑 10 + 共享 mux)
    assign s_axis_tready = ((state == S_RECV) ||
                            ((state == S_IDLE) && !ack_pend_r && !svc &&
                             !ring_eval && !scan_now && !flush_pend && wnd_open &&
                             !tx_blk[start_id])) &&
                           !pay_full;
    wire        accept = s_axis_tvalid && s_axis_tready;

    // ---- 载荷 FIFO + 校验和 (活帧与 ring 帧共用写口; wr/fdin 定义见下, 需先
    //      声明 ring_wr/fdin_ring) ----
    wire [72:0] fdout;
    wire        pay_load = (state == S_PAY) && (m_axis_tready || !m_axis_tvalid);
    // P5: 超长帧中止后 S_IDLE 排空 u_fifo 里的残留字节 (flush_act; 见 flush_pend)
    wire        flush_rd = flush_act && !pay_empty;
    wire        rd = (pay_load && (plen_r != 12'd0) && !pay_empty) || flush_rd;

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

    // 末载荷字低 6 字节区左对齐 (溢出尾字, 1..6 字节)
    function [63:0] ljust6;
        input [47:0] w;
        input [2:0]  p;
        begin
            case (p)
                3'd1: ljust6 = {w[47:40], 56'b0};
                3'd2: ljust6 = {w[47:32], 48'b0};
                3'd3: ljust6 = {w[47:24], 40'b0};
                3'd4: ljust6 = {w[47:16], 32'b0};
                3'd5: ljust6 = {w[47:8],  24'b0};
                3'd6: ljust6 = {w[47:0],  16'b0};
                default: ljust6 = 64'b0;
            endcase
        end
    endfunction

    // RTO 未决最低位优先 (bit0 先服务)
    function [3:0] prio_lo;
        input [15:0] v;
        integer i;
        begin
            prio_lo = 4'd0;
            for (i = 15; i >= 0; i = i - 1)
                if (v[i]) prio_lo = i[3:0];
        end
    endfunction

    // ring 末拍字节掩码 (按字节 lane, rem=0 视为 8 全保留; 界外清零)
    function [63:0] rm_mask;
        input [2:0] rem;
        begin
            case (rem)
                3'd0: rm_mask = 64'hFFFFFFFFFFFFFFFF;
                3'd1: rm_mask = 64'hFF00000000000000;
                3'd2: rm_mask = 64'hFFFF000000000000;
                3'd3: rm_mask = 64'hFFFFFF0000000000;
                3'd4: rm_mask = 64'hFFFFFFFF00000000;
                3'd5: rm_mask = 64'hFFFFFFFFFF000000;
                3'd6: rm_mask = 64'hFFFFFFFFFFFF0000;
                default: rm_mask = 64'hFFFFFFFFFFFFFF00;
            endcase
        end
    endfunction

    // ---- P4b-7 重传 ring: 写拍点 = 活帧每个有效 accept 拍 (ring 源帧 accept=0
    //      天然不重写); 读口数据 rd_en 后 1 拍 ----
    // P5 长度守卫: len_bad 后的字节不入 ring (中止帧的字节永不发送 -> 不入
    // 重传缓冲; 之前已写入的残字节因 snd_nxt 未推进, 会被下一帧自同一基址
    // 覆盖 — 且在 retx_hi 之外, ring 读永不触及)
    wire        wr_tap = accept && (s_axis_tkeep != 8'h00) && !len_bad;
    wire [3:0]  w_tap_conn = (state == S_RECV) ? cur_id : start_id;
    wire [31:0] w_tap_seq  = start_data ? rb_snd_nxt : tap_seq;

    // ---- ring 源帧 (S_RING, P4b-7-P6 2 级读出 ring_d -> ring_d_r) ----
    // 时序 (c0 = ring_start 预读 beat1 拍; nbeats = (plen_preset+7)>>3):
    //   c(k) 拍 (S_RING, beat_cnt = k = 已发读次数): ring_d = beat k-1 (c(k-2) 读),
    //   ring_d_r = beat k-2; 写拍 c3..c(nbeats+2) 每拍写 1 beat (写 beat =
    //   beat_cnt-2 = ring_d_r, 即读于 3 拍前); 末写拍 (beat_cnt == nbeats+2,
    //   tlast) 边沿转 S_WAIT; 读 beat_cnt+1 直到 beat_cnt == nbeats — 读序列与
    //   旧版逐拍相同, 写序列整体后移 2 拍 (S_RING 总长 nbeats+2 拍)
    // P4c 时序修复 步骤 3 (2026-09-12): retx_ram 读地址入口寄存 1 拍 => 读延迟
    //   1 拍变 2 拍; 上表已按 2 拍重算 (读请求 rd_tap/r_tap_seq 与 §342 逐字不变)。
    wire        ring_act = (state == S_RING);
    wire [7:0]  ring_end = nbeats + 8'd2;
    wire        ring_wr  = ring_act && (beat_cnt >= 8'd3);     // 写拍 c3..c(nbeats+2)
    wire        ring_fin = ring_act && (beat_cnt == ring_end); // 末 beat 写拍 (tlast)
    wire [7:0]  ring_tkeep = ring_fin ? ((ring_rem == 12'd8) ? 8'hFF :
                             (8'hFF << (4'd8 - {1'b0, ring_rem[2:0]}))) : 8'hFF;
    wire [63:0] ring_d;
    // 末拍界外 lane (ring 读回的后续字节) 清零, 不进 FIFO/校验和
    wire [63:0] ring_w = ring_fin ? (ring_d_r & rm_mask(ring_rem[2:0])) : ring_d_r;
    wire [72:0] fdin_ring = {ring_fin, ring_tkeep, ring_w};
    // ring 读口: 首读在 ring_start 拍 (地址 rb_snd_nxt), S_RING 内每拍预读下一字
    wire        rd_tap = ring_start || (ring_act && (beat_cnt < nbeats));
    // P4c: ring 字节偏移 [15:0] (64KB/conn = 2^16 字节, 回绕恰在 16 位)
    wire [15:0] r_tap_seq = ring_start ? rb_snd_nxt[15:0] : ring_seq[15:0];
    // ring 帧载荷 = min(1460, 会话剩余区间); delta<1460 时 12 位精确不截断
    wire [11:0] plen_preset = (ring_delta >= 32'd1460) ? 12'd1460 :
                              ring_delta[11:0];

    retx_ram u_retx (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_tap), .w_conn(w_tap_conn), .w_seq(w_tap_seq[15:0]),
        .w_data(s_axis_tdata), .w_n(pop8(s_axis_tkeep)),
        .rd_en(rd_tap), .r_conn(retx_id_r), .r_seq(r_tap_seq), .r_data(ring_d)
    );

    // ---- 载荷 FIFO/校验和 写口 mux (活帧与 ring 帧按状态互斥) ----
    wire        wr  = (accept && (s_axis_tkeep != 8'h00) && !len_bad) || ring_wr;
    wire [72:0] fdin = ring_wr ? fdin_ring :
                       {s_axis_tlast, s_axis_tkeep, s_axis_tdata};

    // IP 头校验和 (组合树): S_WAIT 首拍算 (所有字段已锁存)
    function [15:0] ip_csum_calc;
        input [15:0] tlen;
        input [15:0] idc;
        input [31:0] dip;
        reg [19:0] s;
        reg [16:0] f1;
        begin
            s = {4'b0, 16'h4500} + {4'b0, tlen} + {4'b0, idc} + {4'b0, 16'h0000} +
                {4'b0, 16'h4006} + {4'b0, 16'h0000} + {4'b0, cfg_src_ip[31:16]} +
                {4'b0, cfg_src_ip[15:0]} + {4'b0, dip[31:16]} + {4'b0, dip[15:0]};
            f1 = s[15:0] + {12'b0, s[19:16]};
            ip_csum_calc = ~(f1[15:0] + {15'b0, f1[16]});
        end
    endfunction

    // 帧长 (tlast 拍): start_data 时 plen 还是上一帧残留值, 必须显式归零
    wire [11:0] plen_n = (start_data ? 12'd0 : plen) + {8'b0, pop8(s_axis_tkeep)};
    // P5 长度守卫: 本拍累计 (含本拍字节) 越过 PLEN_MAX -> 帧内中止。len_bad 是
    // 寄存器 (检出拍的下拍起屏蔽写口), 检出拍本身已写进 FIFO/ring 的字节由
    // S_IDLE 的 flush 与 ring 覆盖语义兜掉 (见 flush_pend / wr_tap 注释)。
    wire        len_over = (plen_n > PLEN_MAX);
    // 校验和伪头初值: dst IP 用组合读回 (dip_r 本拍才锁存)
    wire [31:0] csum_init_val = {4'b0, cfg_src_ip[31:16]} + {4'b0, cfg_src_ip[15:0]} +
                                {4'b0, cam_rd_sip[31:16]} + {4'b0, cam_rd_sip[15:0]} +
                                32'h0006;
    wire        csum_init = start_ack || start_data || ring_start;
    wire        csum_den  = ((start_data || (state == S_RECV)) && accept &&
                             (s_axis_tkeep != 8'h00) && !len_bad) || ring_wr;
    wire [63:0] csum_din   = ring_wr ? ring_w : s_axis_tdata;
    wire [7:0]  csum_dkeep = ring_wr ? ring_tkeep : s_axis_tkeep;
    // aen 三拍补足 9 半字 (每组 ≤4 项 < 2^18): 伪头 tcp_len + TCP 头 (csum/urg=0 不参与)
    wire        csum_aen  = (state == S_WAIT) && (wait_cnt <= 3'd2);
    wire [17:0] aen_v1 = {2'b0, tcp_len_r} + {2'b0, sport_r} + {2'b0, dport_r} +
                         {2'b0, seq_r[31:16]};
    wire [17:0] aen_v2 = {2'b0, seq_r[15:0]} + {2'b0, ack_r[31:16]} +
                         {2'b0, ack_r[15:0]} + {2'b0, doff_flags_r};
    wire [17:0] aen_v3 = {2'b0, wnd_r};
    wire [17:0] aen_val = (wait_cnt == 3'd0) ? aen_v1 :
                          (wait_cnt == 3'd1) ? aen_v2 : aen_v3;
    wire        csum_fin  = (state == S_WAIT) && (wait_cnt == 3'd3);
    wire [15:0] csum;
    wire        csum_valid;

    checksum16 u_csum (
        .clk(clk), .rst_n(rst_n),
        .init(csum_init), .init_val(csum_init_val),
        .den(csum_den), .din(csum_din), .dkeep(csum_dkeep),
        .aen(csum_aen), .add_val(aen_val),
        .fin(csum_fin),
        .csum(csum), .csum_valid(csum_valid)
    );

    fifo_sync #(.W(73), .D(256), .AW(8)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr(wr), .din(fdin),
        .rd(rd), .dout(fdout),
        .empty(pay_empty), .full(pay_full),
        .dbg_wptr(dbg_pay_wptr), .dbg_rptr(dbg_pay_rptr),
        .dbg_full(dbg_pay_full2), .dbg_empty(dbg_pay_empty)
    );

    // ---- P5 FIN/RST 排队 (扫描拍, 请求来自 app_ctrl 的 fin_req/rst_req) ----
    // FIN: 仅无在飞数据 (snd_nxt == snd_una) 且 ESTAB 且请求未服务 (D4);
    // RST: ESTAB 即排队 (不消费 seq)。两条都只占 ackq 一个条目, 发完即
    // fin_sent_r/rst_sent_r 置位 (S_DONE) 不再重复。ack_req 优先 (丢 ACK 比
    // 丢 FIN 严重; FIN 下轮扫描 (256 拍) 自动重试)。
    wire        fin_push = scan_now && fin_req[scan_id] && !fin_sent_r[scan_id] &&
                           !ackq_full && (rb_state == 4'd1) &&
                           (rb_snd_nxt == rb_snd_una);
    wire        rst_push = scan_now && rst_req[scan_id] && !rst_sent_r[scan_id] &&
                           !ackq_full && (rb_state == 4'd1);
    // FIN 重推 (RTO 回卷把已发出的 FIN 吞掉): ring 会话排空拍组合推同 seq 条目。
    // P5c-T1 追加两个结构性守卫 (默认构建下两者都不可达 — fin_retx_pend 恒 0 已使
    // fin_repush 恒 0 ⇒ 逐位不变, 无需 ifdef):
    //  ① (rb_state == 1): 连接已拆 (DEL, CAM 已清空) 时不得把 FIN 推给死连接 —
    //     帧的 dst MAC 取自已清空的 CAM = 0 = 垃圾帧 (G4)。
    //  ② (rb_snd_una == fin_seq_r): FIN 在飞的不变式 = 它正好压在 ACK 边界上
    //     (snd_una == fin_seq, 因为 FIN 用的是最后一个未确认 seq 且 app 数据在
    //     fin_sent_r 置位后不再启动)。snd_una 越过 fin_seq ⇒ FIN 已被对端 ACK ⇒
    //     再推同 seq 条目就是 spurious FIN (seq 落在对端窗口外, 可诱发 RST — TL
    //     点名的风险)。用**不变式**判定"是否仍未决", 不依赖扫描清挂起位的时延
    //     (扫描一轮 256 拍, 快 RTO 配置下可能来不及)。
    wire        fin_repush = ring_eval && !ring_start && fin_retx_pend[retx_id_r] &&
                             !ackq_full && (rb_state == 4'd1) &&
                             (rb_snd_una == fin_seq_r[retx_id_r]);
    wire        ack_req_ok = ack_req && !ackq_full;
    // ---- P5c-T1 G1 主修: FIN 重推"**确实入队**"的等价条件 ----
    // 排空拍上 ackq_din mux 的更高优先源只剩 ack_req_ok (排空拍要求 !ack_pend_r,
    // 而 ack_pend_r <= !ackq_empty ⇒ 上拍队列为空 ⇒ 排空拍 ackq_full 恒 0 — T2 实测
    // 纠正了 TL 的 "或 ackq_full" 猜测; 扫描侧的 fin_push/rst_push 与 ring_eval 互斥,
    // wu_push 自带 !fin_repush, 都抢不走)。这里仍显式带上 !ackq_full: 防御性 (ackq
    // 逻辑日后变化时守卫不退化), 且与"确实入队"严格等价。
    wire        fin_repush_ok = fin_repush && !ack_req_ok && !ackq_full;
    // ---- P5b C7: 窗口更新 (wu) 条目入队 ----
    // 优先级 (高→低): ack_req (数据/dup-ACK, 对端时延敏感) > fin_push/rst_push
    // (关闭语义, 丢不得) > fin_repush (FIN 重推) > wu (窗口更新)。
    // ⚠️ 坑 (P5a M1 同类): 若写 `wu_push = wu_req && !ackq_full` 而 ackq_din 的
    // mux 里 ack_req 优先, 同拍 ack_req_ok 为真时会"gnt 给了 wu 但条目写进了
    // ACK" ⇒ wu_pend 被清而窗口更新从未发出 ⇒ 对端在零窗上永久停等 (死锁)。
    // 因此 wu_push 必须**同时**排除全部更高优先级的入队源, 且 wu_gnt 与"确实
    // 入队"严格等价 (gnt = push)。
    // wu 排 fin_repush 之后 (TL 定稿): fin_repush 的 1 拍机会不可被抢 (抢了要等
    // 下一次 svc/RTO 才重来, 与 M1 同险); wu 是电平请求 + gnt 握手, 被抢只晚
    // 一拍, 下一拍仲裁必然重来 (ack_req 是脉冲, 不会长期占满) ⇒ 可接受。
    // **无需 state == S_IDLE**: ackq 是独立 FIFO, 写入与 FSM 无关 (条目在
    // start_ack 弹出拍才参与帧组装)。
    wire        wu_push    = wu_req && !ackq_full && !ack_req_ok && !fin_push &&
                             !rst_push && !fin_repush;
    wire        ackq_wr    = ack_req_ok || fin_push || rst_push || fin_repush ||
                             wu_push;
    wire [ACKQ_W-1:0] ackq_din = ack_req_ok ? {ack_id, ack_syn, ack_fin, ack_rst, ack_val} :
                                 fin_push   ? {scan_id, 1'b0, 1'b1, 1'b0, 32'h0} :
                                 rst_push   ? {scan_id, 1'b0, 1'b0, 1'b1, 32'h0} :
                                 fin_repush ? {retx_id_r, 1'b0, 1'b1, 1'b0, 32'h0} :
                                              {wu_id, 1'b0, 1'b0, 1'b0, wu_val};
    assign      wu_gnt = wu_push;

    fifo_sync #(.W(ACKQ_W), .D(ACKQ_D), .AW(ACKQ_AW)) u_ackq (
        .clk(clk), .rst_n(rst_n),
        .wr(ackq_wr), .din(ackq_din),
        .rd(start_ack), .dout(ackq_dout),
        .empty(ackq_empty), .full(ackq_full)
    );

    // P5: FIN 已发出状态线束 (app_ctrl 的 app_tx_ready 用) + 重传会话连接号
    assign o_fin_sent = fin_sent_r;
    // P5c-T3 G3: abort fence 线束 (纯加输出; app_ctrl 的 tx_ready_calc 消费)
    assign o_rst_sent = rst_sent_r;
    assign o_retx_id  = retx_id_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            plen <= 0; plen_r <= 0;
            tcp_len_r <= 0; total_len_r <= 0; ip_csum_r <= 0; tcp_csum_r <= 0;
            id_r <= 0; id_cap <= 0;
            wait_cnt <= 0; hcnt <= 0; hold48 <= 0; tail_d <= 0; tail_k <= 0;
            cur_id <= 0; is_data_r <= 0; is_syn_r <= 0;
            is_fin_r <= 0; is_rst_r <= 0; len_bad <= 0; flush_pend <= 0;
            fin_sent_r <= 16'h0; rst_sent_r <= 16'h0; fin_retx_pend <= 16'h0;
            seq_r <= 0; ack_r <= 0; wnd_r <= 0; doff_flags_r <= 0;
            dmac_r <= 0; dip_r <= 0; sport_r <= 0; dport_r <= 0;
            m_axis_tdata <= 0; m_axis_tkeep <= 0; m_axis_tvalid <= 0; m_axis_tlast <= 0;
            stat_frames <= 0; stat_bytes <= 0; stat_ack <= 0; stat_ack_drop <= 0;
            stat_eend <= 0; stat_tlast_in <= 0;
            stat_drop_len <= 0; stat_fin <= 0; stat_rst <= 0;
            retx_active <= 0; retx_id_r <= 0; retx_hi <= 0; scan_id <= 0;
            rto_pend <= 16'h0; ring_seq <= 0; ring_rem <= 0; tap_seq <= 0;
            nbeats <= 8'd0; beat_cnt <= 8'd0; ring_d_r <= 64'h0;
            svc_id_r <= 0; tick_cnt <= 0; rto_pend_any <= 0; ack_pend_r <= 0;
            stat_retx <= 0;
            for (ri = 0; ri < 16; ri = ri + 1) begin
                rto_timer[ri] <= 21'd0;
                snd_una_prev[ri] <= 32'd0;
                epoch[ri] <= 4'd0;
                fin_seq_r[ri] <= 32'd0;
            end
        end else begin
            // P5a 复核 D1 修复: cfg ADD 收尾脉冲 -> 显式清该槽的 FIN/RST 已发标志与
            // 重推挂起位 (同槽重连的新会话必须能发数据、能再 close)。放在最前面,
            // 与下面的扫描清 (rb_state!=1) 互补: 脉冲路径覆盖背靠背 DEL→ADD。
            if (cfg_up) begin
                fin_sent_r[cfg_up_id]    <= 1'b0;
                rst_sent_r[cfg_up_id]    <= 1'b0;
                fin_retx_pend[cfg_up_id] <= 1'b0;
                // ---- P5c-T1 G4+G6: 跨会话残留清理 (事件脉冲, 坑 9) ----
                // G6: epoch=15 / snd_una_prev 残留带进新会话 ⇒ 新会话第一次 svc
                // 就可能撞上 blocked (不回卷), 白丢一轮重传 (~1 个 RTO)。
                // G4: rto_pend/rto_timer 残留 ⇒ 新连接建连后立刻收到一个属于旧会话
                // 的"未决 RTO" ⇒ svc 回卷/重放 (新连接的 snd_nxt/snd_una 都还是 0,
                // 回卷无意义但会占一会话 + 复位计时)。DEL 后 state=0 并不自动让
                // 装表条件为假 (DEL 只写 state, snd_wnd/snd_nxt/snd_una 残留), 所以
                // 这两项必须由事件脉冲清, 不能指望轮扫采条件 (坑 9)。
                // 注: 本块在 always 最前, 同拍撞上 svc/扫描时后者的赋值优先。
                epoch[cfg_up_id]        <= 4'd0;
                snd_una_prev[cfg_up_id] <= 32'd0;
                rto_pend[cfg_up_id]     <= 1'b0;
                rto_timer[cfg_up_id]    <= 21'd0;
            end
            if (m_axis_tready && m_axis_tvalid) m_axis_tvalid <= 1'b0;
            if (ack_req && ackq_full) stat_ack_drop <= stat_ack_drop + 1;
            // P4b-7-P6 tlast 探针: 帧首拍 (S_IDLE start_data) 或 S_RECV 吞到末 beat
            // (两处都是 accept && s_axis_tlast; S_IDLE 的 accept 即 start_data 拍)
            if (accept && s_axis_tlast) stat_tlast_in <= stat_tlast_in + 32'd1;
            // svc 优先编码寄存器化 (P6 时序, 见 svc_id 声明注释): 每拍刷新,
            // svc 拍消费上拍编码 — rto_pend 置位到 svc 至少隔 1 拍 (扫描拍
            // 置位, 下一 S_IDLE 拍 svc), retx_req 电平期间 retx_id 稳定
            svc_id_r <= retx_req ? retx_id : prio_lo(rto_pend);
            rto_pend_any <= |rto_pend;
            ack_pend_r <= !ackq_empty;
            // 扫描 tick: 自由运行 16 分频 (P6 时序, 见 scan_now 声明注释)
            tick_cnt <= tick_cnt + 4'd1;
            ring_d_r <= ring_d;      // P4b-7-P6: 第 2 级读出 (ring_d = 上拍 rd 数据)
            case (state)
                S_IDLE: begin
                    // P5 超长帧冲洗收尾: 残留字节排空 (flush_rd 在上面的 rd 里);
                    // len_bad 必须在此清 (而不是留到下一帧帧首) — 否则下一帧首拍
                    // 会被 accept 但 wr 仍被 len_bad 屏蔽: plen 计了 8 字节而 FIFO
                    // 没写 = 载荷整帧错位 8 字节 (实测)。
                    if (flush_pend && pay_empty) begin
                        flush_pend <= 1'b0;
                        len_bad    <= 1'b0;
                    end
                    // 重传服务拍: 锁存会话 (上界 = 回卷前 snd_nxt, 连接 = svc_id),
                    // 回卷 snd_nxt -> snd_una (svc_rewind 组合脉冲突发), 清该连接
                    // RTO 未决并重装计时器; 请求应答与回卷同拍
                    if (svc) begin
                        // SEV2-1: snd_una 进展比对 — 无进展会话计数 +1 (封顶
                        // 15), 有进展清零; blocked 后 svc 仍应答但不回卷
                        if (rb_snd_una == snd_una_prev[svc_id]) begin
                            if (epoch[svc_id] < 4'd15)
                                epoch[svc_id] <= epoch[svc_id] + 4'd1;
                        end else
                            epoch[svc_id] <= 4'd0;
                        snd_una_prev[svc_id] <= rb_snd_una;
                        // P5: FIN 已发出时 (snd_nxt = fin_seq+1, snd_una = fin_seq)
                        // 会话高水位 = fin_seq_r — 否则 ring_delta = retx_hi -
                        // snd_nxt 会把 FIN 的 1 字节 seq 当 ring 数据重放
                        // (回卷后 snd_nxt = fin_seq, delta 应为 0: 无数据可重放,
                        //  只重推 FIN 条目, seq 不变 = 无漂移)。
                        // P5c-T1 G9 修复②: 取 fin_seq 的**前提是本次确实回卷**
                        // (svc_rewind, 即回卷后 snd_nxt = snd_una = fin_seq = retx_hi
                        // ⇒ delta=0)。若在**不回卷**的会话里仍取 fin_seq (blocked,
                        // 或 snd_nxt==snd_una 而 FIN 挂起位残留), 而 snd_nxt 还在
                        // fin_seq+1 ⇒ delta = fin_seq-(fin_seq+1) = 0xFFFFFFFF 下溢
                        // ⇒ 洪水重放 (G9)。加上 svc_rewind 后, **任何**分支下
                        // retx_hi >= rb_snd_nxt ⇒ 下溢结构性不可能 (与 ① 双重保险)。
                        retx_hi <= (fin_sent_r[svc_id] && svc_rewind) ? fin_seq_r[svc_id] :
                                   rb_snd_nxt;
                        if (fin_sent_r[svc_id]) fin_retx_pend[svc_id] <= 1'b1;
                        retx_id_r <= svc_id;
                        // P5c-T1 G9 修复① (见 retx_begin 声明注释): blocked 且 FIN
                        // 在飞时不建会话 — 否则 ① 的洪水前提 (无回卷却 retx_hi=fin_seq)
                        // 就成立了。默认构建 retx_begin === svc (fin_sent_r 恒 0)。
                        retx_active <= retx_begin;
                        rto_pend[svc_id] <= 1'b0;
                        rto_timer[svc_id] <= RTO_LIM;
                        if (svc_rewind) stat_retx <= stat_retx + 32'd1;
                    end
                    // ring 帧启动拍: 帧首锁存同活帧 (rb/cam_rd 已 mux 到
                    // retx_id_r); ring_seq 预推进 8 = 下拍(S_RING 首拍)预读地址
                    if (ring_eval) begin
                        if (ring_start) begin
                            cur_id <= retx_id_r;
                            is_data_r <= 1'b1;
                            is_syn_r <= 1'b0;
                            is_fin_r <= 1'b0;   // P5 (ring 帧绝不为 FIN/RST)
                            is_rst_r <= 1'b0;
                            len_bad  <= 1'b0;   // P5: 帧首清守卫 (ring 路径不看它)
                            seq_r <= rb_snd_nxt;
                            ack_r <= rb_rcv_nxt;
                            wnd_r <= rb_rcv_wnd;
                            doff_flags_r <= 16'h5018;   // 数据帧 PSH+ACK
                            dmac_r <= cam_rd_dmac;
                            dip_r <= cam_rd_sip;       // 对端 IP
                            sport_r <= cam_rd_dport;   // 本地端口
                            dport_r <= cam_rd_sport;   // 对端端口
                            id_cap <= id_r;
                            id_r <= id_r + 1;
                            plen_r <= plen_preset;
                            tcp_len_r <= {4'b0, plen_preset} + 16'd20;
                            total_len_r <= {4'b0, plen_preset} + 16'd40;
                            // P4b-7-P6 (2 级读出): ring_rem 固定为末 beat 字节数
                            ring_rem <= (plen_preset[2:0] == 3'd0) ? 12'd8 :
                                        {9'b0, plen_preset[2:0]};
                            nbeats   <= (plen_preset + 12'd7) >> 3;   // <= 183
                            beat_cnt <= 8'd1;      // 本拍已发 beat1 读
                            ring_seq <= rb_snd_nxt + 32'd8;
                            state <= S_RING;
                        end else begin
                            // 区间发完 (ring_delta == 0): 1 拍气泡回活数据。
                            // P5: FIN 曾在此会话被回卷吞掉 (fin_retx_pend) ⇒ 重推
                            // FIN 条目 (seq = 回卷后 snd_nxt = fin_seq, 与首发同值)
                            // ---- P5c-T1 G1 主修 (T2 mock-A 已验证) ----
                            // 老代码: 排空拍**无条件** retx_active<=0, 而挂起位的清
                            // 门是 (!ackq_full && !ack_req_ok) — 两个条件不同源。
                            // ack_req_ok 抢走 mux 那拍: FIN 条目被 ackq_din 吞掉
                            // (ACK 优先), 挂起位保留 1, 但会话照样结束 ⇒ 下拍
                            // snd_nxt == snd_una ⇒ RTO 装表条件恒假 ⇒ 再无 svc ⇒
                            // 再无排空拍 (排空拍需要 retx_active) ⇒ fin_repush 永不
                            // 再评估 ⇒ FIN 永不重发, 关闭永不完成 (G1/W2);
                            // 原注释"下一轮 ring 排空拍再重推"——代码给不出下一轮。
                            // 修法: 只有条目**确实进了 ackq** (fin_repush_ok) 才清挂起
                            // 位并结束会话; 被抢则两者都保持 ⇒ 下拍继续试。触发源是
                            // 会话自身 (ring_delta==0 时**每拍**都是排空拍), 不再依赖
                            // "下一轮 RTO/排空拍"这种给不出的机会。
                            // ⚠️ 配套两条退路 — "保持"必须有出口, 否则会话永久挂住会
                            // 一直压制 start_data/scan_now (ring_eval 覆盖全部
                            // S_IDLE&&!ack_pend 拍) = 整个 TX 数据面死锁:
                            //   a) 连接已拆 (rb_state != 1, DEL 后): 条目永不入队
                            //      (fin_repush 的 ① 守卫) ⇒ 放弃重推并释放会话。
                            //      同槽重连由 cfg_up 脉冲清全部 FIN 状态, app 重新
                            //      fin_req 即可。
                            //   b) FIN 已被对端 ACK (rb_snd_una != fin_seq_r): 挂起位
                            //      已无意义 (且 fin_repush 的 ② 守卫不会入队) ⇒ 清掉,
                            //      不再退化成"关闭完成后周期发 spurious FIN"。
                            if (fin_retx_pend[retx_id_r]) begin
                                if (fin_repush_ok) begin
                                    fin_retx_pend[retx_id_r] <= 1'b0;  // fin_repush 组合推条目
                                    retx_active <= 1'b0;
                                end else if ((rb_state != 4'd1) ||
                                             (rb_snd_una != fin_seq_r[retx_id_r])) begin
                                    fin_retx_pend[retx_id_r] <= 1'b0;  // 退路 a) / b)
                                    retx_active <= 1'b0;
                                end
                                // else: 被 ack_req 抢 ⇒ 两者都保持, 下拍重试
                            end else begin
                                retx_active <= 1'b0;
                            end
                        end
                    end
                    // RTO 扫描: 每 scan_now 拍访 scan_id 连接 (rb_* mux 到 scan_id;
                    // 该连接在飞且窗开: 计时 0->装 / 1->置未决并重装 / 否则自减)
                    if (scan_now) begin
                        // P5: 连接非 ESTAB (state=0 已拆/未配) 时清 FIN/RST 已发
                        // 标志 — 同槽重连可再发 (fin_push/rst_push 的门)。局限:
                        // 快速 DEL+ADD 落在两次扫描之间时会漏清 (P5c/P5d 若需
                        // 要再补 TCB 世代号)。
                        if (rb_state != 4'd1) begin
                            fin_sent_r[scan_id] <= 1'b0;
                            rst_sent_r[scan_id] <= 1'b0;
                            // P5c-T1 G4: 死连接的 FIN 挂起位同样作废 (svc 会把它重新
                            // 置 1 而无人消费 ⇒ 跨会话残留; 默认构建 fin_retx_pend
                            // 恒 0, 本条为无副作用)。
                            fin_retx_pend[scan_id] <= 1'b0;
                        end
                        // P5c-T1 G4: 死连接不保留**未决 RTO** (DEL 前装上的 rto_pend
                        // 仍会触发一次 svc -> 回卷 -> 从 ring 重放给一个 CAM 已清空
                        // 的连接)。用 !scan_estab 门控 ⇒ 默认构建 (scan_estab 恒 1)
                        // 本条不可达, 逐位不变。
                        if (!scan_estab)
                            rto_pend[scan_id] <= 1'b0;
                        // P5c-T1 G1 (Option B 兜底配套): FIN 已被 ACK (snd_una 已越过
                        // fin_seq, 见 fin_repush ② 的不变式) ⇒ 清挂起位。否则兜底的
                        // 装表条件会被该位长期保持为真 ⇒ **关闭完成后周期发 spurious
                        // FIN** (seq = 已被 ACK 的 fin_seq, 落在对端窗口外)。
                        if (fin_retx_pend[scan_id] && (rb_snd_una != fin_seq_r[scan_id]))
                            fin_retx_pend[scan_id] <= 1'b0;
                        // SEV3-4: 原 '!(retx_active && (scan_id==retx_id_r))' 排除项
                        // 是死代码 — scan_now 要求 !ring_eval; retx_active 期间
                        // ring_eval 覆盖全部 S_IDLE&&!ack_pend 拍 (ack_pend 也
                        // 排除 scan_now), 故 scan_now 拍 retx_active 恒 0
                        // P5c-T1 追加两个装表门:
                        //  ① scan_estab: 死连接 (state!=ESTAB) 不装表 (G4, 只 APP_MODE)。
                        //  ② || fin_retx_pend[scan_id]: **FIN 未决**的连接即使无在飞
                        //     数据 (回卷后 snd_nxt==snd_una) 也必须能进 svc — 兜底
                        //     覆盖"别的路径结束了会话而挂起位还在"的情形 (那时唯一
                        //     能重推 FIN 的入口就是 svc -> 排空拍)。默认构建
                        //     fin_retx_pend 恒 0 ⇒ 与老式逐位相同, 无需 ifdef。
                        if (scan_estab && ((rb_snd_wnd != 16'd0 && rb_snd_nxt != rb_snd_una) ||
                            fin_retx_pend[scan_id])) begin
                            if (rto_timer[scan_id] == 21'd0)
                                rto_timer[scan_id] <= RTO_LIM;
                            else if (rto_timer[scan_id] == 21'd1) begin
                                rto_pend[scan_id] <= 1'b1;
                                rto_timer[scan_id] <= RTO_LIM;
                            end else
                                rto_timer[scan_id] <= rto_timer[scan_id] - 21'd1;
                        end else
                            rto_timer[scan_id] <= 21'd0;
                        scan_id <= scan_id + 4'd1;
                    end
                    if (start_ack || start_data) begin
                        // 帧首拍: 锁存连接上下文 (rb/cam_rd 组合输出对 start_id 有效)
                        cur_id <= start_id;
                        is_data_r <= start_data;
                        is_syn_r <= start_ack && aq_syn;
                        // P5: FIN/RST 帧首拍; len_bad 每帧首拍清 (帧内守卫)
                        is_fin_r <= start_ack && aq_fin;
                        is_rst_r <= start_ack && aq_rst;
                        len_bad  <= 1'b0;
                        seq_r <= rb_snd_nxt;
                        // FIN/RST 的 ack 号取当前连接 rcv_nxt (队列条目的 val 对
                        // 这两类是 0, 陈旧; rb_* 在 S_IDLE 已 mux 到 start_id)
                        ack_r <= (start_data || aq_fin || aq_rst) ? rb_rcv_nxt :
                                 ackq_dout[31:0];
                        wnd_r <= rb_rcv_wnd;
                        doff_flags_r <= {8'h50, start_data ? 8'h18 :
                                         aq_syn ? 8'h12 : aq_fin ? 8'h11 :
                                         aq_rst ? 8'h14 : 8'h10};
                        dmac_r <= cam_rd_dmac;
                        dip_r <= cam_rd_sip;       // 对端 IP
                        sport_r <= cam_rd_dport;   // 本地端口
                        dport_r <= cam_rd_sport;   // 对端端口
                        id_cap <= id_r;
                        id_r <= id_r + 1;
                        if (start_ack) begin
                            plen_r <= 12'd0;
                            tcp_len_r <= 16'd20;
                            total_len_r <= 16'd40;
                            state <= S_WAIT; wait_cnt <= 3'd0;
                        end else begin
                            // ring 写游标越过本拍字节 (首拍 beat0 写 rb_snd_nxt,
                            // 游标 = 下一 beat 偏移)
                            tap_seq <= rb_snd_nxt + {20'b0, pop8(s_axis_tkeep)};
                            plen <= {8'b0, pop8(s_axis_tkeep)};
                            if (s_axis_tlast) begin
                                plen_r <= plen_n;
                                tcp_len_r <= {4'b0, plen_n} + 16'd20;
                                total_len_r <= {4'b0, plen_n} + 16'd40;
                                state <= S_WAIT; wait_cnt <= 3'd0;
                            end else begin
                                state <= S_RECV;
                            end
                        end
                    end
                end
                S_RECV: begin
                    if (accept) begin
                        tap_seq <= tap_seq + {20'b0, pop8(s_axis_tkeep)};
                        plen <= plen + {8'b0, pop8(s_axis_tkeep)};
                        // P5 长度守卫: 越过 PLEN_MAX -> 本帧中止 (len_bad 寄存器,
                        // 下拍起写口全屏蔽)。tlast 拍走中止收尾: 跳过 S_WAIT/
                        // S_HDR/S_PAY/S_DONE -> S_IDLE + flush_pend (排空已写入
                        // u_fifo 的残留字节) + stat_drop_len++。snd_nxt 不推进
                        // (S_DONE 不经过), ring 残字节被下帧覆盖 (见 wr_tap 注释)。
                        if (len_over) len_bad <= 1'b1;
                        if (s_axis_tlast) begin
                            if (len_over || len_bad) begin
                                state <= S_IDLE;
                                flush_pend <= 1'b1;
                                stat_drop_len <= stat_drop_len + 32'd1;
                            end else begin
                                plen_r <= plen_n;
                                tcp_len_r <= {4'b0, plen_n} + 16'd20;
                                total_len_r <= {4'b0, plen_n} + 16'd40;
                                state <= S_WAIT; wait_cnt <= 3'd0;
                            end
                        end
                    end
                end
                S_WAIT: begin
                    if (wait_cnt == 3'd0)
                        ip_csum_r <= ip_csum_calc(total_len_r, id_cap, dip_r);
                    if (wait_cnt == 3'd4) begin
                        tcp_csum_r <= csum_valid ? csum : 16'h0;
                        state <= S_HDR; hcnt <= 3'd0;
                    end else begin
                        wait_cnt <= wait_cnt + 3'd1;
                    end
                end
                S_HDR: begin
                    if (!m_axis_tvalid || m_axis_tready) begin
                        m_axis_tvalid <= 1'b1;
                        m_axis_tkeep <= 8'hFF;
                        m_axis_tlast <= 1'b0;
                        case (hcnt)
                            // 每字拼接必须恰 64 位
                            3'd0: m_axis_tdata <= {dmac_r, cfg_src_mac[47:32]};
                            3'd1: m_axis_tdata <= {cfg_src_mac[31:0], 16'h0800, 8'h45, 8'h00};
                            3'd2: m_axis_tdata <= {total_len_r, id_cap, 16'h0000, 8'h40, 8'h06};
                            3'd3: m_axis_tdata <= {ip_csum_r, cfg_src_ip, dip_r[31:16]};
                            3'd4: m_axis_tdata <= {dip_r[15:0], sport_r, dport_r, seq_r[31:16]};
                            default: m_axis_tdata <= {seq_r[15:0], ack_r, doff_flags_r};
                        endcase
                        if (hcnt == 3'd5) begin
                            state <= S_PAY;
                            hold48 <= {wnd_r, tcp_csum_r, 16'h0000};  // w6 前导 6 字节
                        end else begin
                            hcnt <= hcnt + 3'd1;
                        end
                    end
                end
                S_PAY: begin
                    if (!m_axis_tvalid || m_axis_tready) begin
                        if (plen_r == 12'd0) begin
                            // 纯 ACK 段 / 零长数据: w6 = {window, csum, urg} 6 字节收尾
                            m_axis_tvalid <= 1'b1;
                            m_axis_tdata <= {hold48, 16'h0000};   // 拼接必须 64 位
                            m_axis_tkeep <= 8'hFC;
                            m_axis_tlast <= 1'b1;
                            state <= S_DONE;
                        end else if (pay_empty) begin
                            // 欠载防御 (app 契约违规): 提前结束帧
                            stat_eend <= stat_eend + 1;   // 结构不可达 (整帧先入 FIFO
                            m_axis_tvalid <= 1'b1;        //  才开 S_WAIT) — 计数哨兵
                            m_axis_tdata <= {hold48, 16'h0000};
                            m_axis_tkeep <= 8'hFC;
                            m_axis_tlast <= 1'b1;
                            state <= S_DONE;
                        end else begin
                            m_axis_tvalid <= 1'b1;
                            m_axis_tdata <= {hold48, fdout[63:48]};
                            hold48 <= fdout[47:0];
                            if (fdout[72]) begin
                                // 末载荷字: n 有效字节。输出字 = {hold48(6B), cur[63:48](2B)}
                                // n<2: 本拍 6+n 字节收尾; n==2: 满字收尾; n>2: 满字+溢出尾字 (n-2 字节)
                                if (pop8(fdout[71:64]) < 4'd2) begin
                                    m_axis_tkeep <= 8'hFF << (4'd8 -
                                                    (4'd6 + pop8(fdout[71:64])));
                                    m_axis_tlast <= 1'b1;
                                    state <= S_DONE;
                                end else if (pop8(fdout[71:64]) == 4'd2) begin
                                    m_axis_tkeep <= 8'hFF;
                                    m_axis_tlast <= 1'b1;
                                    state <= S_DONE;
                                end else begin
                                    m_axis_tkeep <= 8'hFF;
                                    m_axis_tlast <= 1'b0;
                                    tail_d <= ljust6(fdout[47:0],
                                                     pop8(fdout[71:64]) - 4'd2);
                                    tail_k <= 8'hFF << (4'd8 -
                                              (pop8(fdout[71:64]) - 4'd2));
                                    state <= S_TAIL;
                                end
                            end else begin
                                m_axis_tkeep <= 8'hFF;
                                m_axis_tlast <= 1'b0;
                            end
                        end
                    end
                end
                S_TAIL: begin
                    if (!m_axis_tvalid || m_axis_tready) begin
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata <= tail_d;
                        m_axis_tkeep <= tail_k;
                        m_axis_tlast <= 1'b1;
                        state <= S_DONE;
                    end
                end
                3'd7: begin   // S_RING (P4b-7-P6 2 级读出; P4c 步骤 3: 读延迟
                    // 2 拍 => S_RING 总长 nbeats+2 拍, 见 §325 时序表)
                    // 每拍写 1 beat (ring_d_r 入 u_fifo+u_csum); 末写拍 ring_fin
                    // 边沿转 S_WAIT
                    if (ring_fin) begin
                        state <= S_WAIT; wait_cnt <= 3'd0;
                    end else begin
                        beat_cnt <= beat_cnt + 8'd1;
                        ring_seq <= ring_seq + 32'd8;
                    end
                end
                default: begin   // S_DONE: 等末字消费 (upd_* 组合脉冲突发于本拍)
                    if (!m_axis_tvalid || m_axis_tready) begin
                        stat_frames <= stat_frames + 1;
                        stat_bytes <= stat_bytes + plen_r;
                        if (!is_data_r) stat_ack <= stat_ack + 1;
                        // P5: FIN/RST 发出记账 (snd_nxt 已由 upd_wr 组合 +1; FIN
                        // 记 seq 供 RTO 回卷用, 标志阻止重复排队)
                        if (is_fin_r) begin
                            fin_sent_r[cur_id] <= 1'b1;
                            fin_seq_r[cur_id] <= seq_r;
                            fin_retx_pend[cur_id] <= 1'b0;
                            stat_fin <= stat_fin + 32'd1;
                        end
                        if (is_rst_r) begin
                            rst_sent_r[cur_id] <= 1'b1;
                            stat_rst <= stat_rst + 32'd1;
                        end
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end

    // ---- P4b-7-P6 调试探针 assign (纯线束, 与上述逻辑零耦合) ----
    assign dbg_wnd_open = wnd_open;
    assign dbg_pay_full = pay_full;
    assign dbg_sready   = s_axis_tready;
    assign dbg_saxis_tvalid = s_axis_tvalid;
    assign dbg_plen_r   = plen_r;
    assign dbg_state    = state;
    assign dbg_plen     = plen;

endmodule
