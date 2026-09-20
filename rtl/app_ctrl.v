`timescale 1ns/1ps
//=============================================================================
// app_ctrl: app 接口控制面 (P5a) + 应用 RX 流控闭环 (P5b)
//
// 职责: ① 连接事件 FIFO (CONN_UP/CONN_DOWN, 源 = slow_cfg_adp) — 满则丢弃 +
// 计数, 绝不反压 HLS cfg 流; ② 16 分频轮扫 TCB 组合读口 C, 采集每连接
// state/snd_nxt/snd_una/rcv_nxt/rcv_wnd/snd_wnd 供寄存器读取 + 计算
// app_tx_ready; ③ 寄存器总线 (读组合, 写 1 拍); ④ FIN/RST 请求输出 (CMD 写
// close/abort 或 app_pattern 的 close_req); ⑤ (P5b) 信用池 + 通告窗口闭环:
// 窗口随 frame_fifo 占用收缩 (fc 写 TCB.rcv_wnd) + 窗口重开主动 ACK (wu)。
//
// ---- P5b 流控闭环 (为什么) ----
// app RX 是零拷贝直出 (tcp_rx -> tcp_echo(frame_fifo 8192 字) -> app_rx_*),
// 所以 TCP 接收缓冲 = 那个 frame_fifo。P5a 通告窗口是静态 48KB, 与占用无关:
// app 不消费 -> FIFO 填满 -> tcp_rx 写不进 -> mac_rx_64 丢帧 (数据永久丢失,
// 对端以为发了); 对端还按 48KB 猛灌 (物理只有 64KB)。P5b 让通告窗口随占用
// 收缩: app 慢 -> 窗口收 -> 对端停发; app 消费后窗口重开 -> 主动窗口更新
// ACK (wu) 解开对端停等。三条硬约束 (写错就是"偶尔丢帧", 门都未必抓得住):
//   C1 右沿 redge 单调 + **饱和**: occ >= winq 时必须把 redge 钉在 rcv_nxt
//      (W=0), 绝不能裸 32 位相减 (occ 大时下溢成巨大值 ⇒ 窗口撑满 ⇒ 溢出)。
//   C2 W 计算必须判 wdiff[31] (redge 落后 rcv_nxt 时裸减法回绕成巨大值)。
//   C3/C10 同槽重连必须重设 redge/wu_mark 并立即纠正 TCB.rcv_wnd。
//
// 地址位宽: 8 位 (0x00..0xFF)。计划文档写"5 位地址", 但其自带的地址映射
// (0x10+4c 到 0x4F / 0x90+ 计数) 已超出 5 位可寻址范围 — 按映射实现, 位宽
// 放宽到 8 位 (将来 AXI-Lite 桥就是它的字节地址低位)。
//
// 事件字 (102 位, 入 16 深 FWFT FIFO; 头组合可读 = 寄存器 0x01..0x04):
//   {kind[1:0], slot[3:0], peer_mac[47:0], peer_port[15:0], peer_ip[31:0]}
//   kind: 0 = CONN_UP, 1 = CONN_DOWN
// 拆字 (寄存器读):
//   0x01 = {26'b0, kind, slot}
//   0x02 = peer_ip[31:0]
//   0x03 = {peer_port[15:0], peer_mac[47:32]}
//   0x04 = peer_mac[31:0]
//
// 寄存器映射 (8 位地址):
//   0x00 R: {30'b0, ovf, empty}   事件 FIFO 状态 (ovf = 曾丢弃, sticky)
//   0x01..0x04 R: 事件字 1..4 (FWFT 头)
//   0x05 W: 事件弹出脉冲 (写任意值即弹一项)
//   0x06 W: CMD = {cmd[3:0], id[3:0]}: cmd 1 = close (fin_req[id]), 2 = abort
//           (rst_req[id]); 其余忽略
//   0x07 R: {16'b0, app_tx_ready[15:0]}
//   0x08 R: {15'b0, rx_occ_bytes}   app RX 可读字节 (echo 缓冲占用)
//   0x09 R: {estab_cnt[15:0], ev_cnt[15:0]}   ESTAB 连接数 / 事件总数
//   0x0A R: conn7..0 的 state (每连接 4 位, conn0 在 [3:0])
//   0x0B R: conn15..8 的 state
//   0x10+4c R: 每连接块 4 字: +0 = {28'b0,state} +1 = snd_una +2 = snd_nxt
//              +3 = {rcv_wnd, snd_wnd}
//   0x50+c R: 每连接 rcv_nxt[31:0]
//   0x90 R: CONN_UP 计数      0x91 R: CONN_DOWN 计数
//   0x92 R: 事件丢弃计数      0x93 R: CMD close 计数
//   0x94 R: CMD abort 计数    0x95 R: 扫描心跳 (每 16 次采集 +1)
//   0x96 R: stat_wu (窗口更新 ACK 发出数)
//   0x97 R: {15'b0, pool}     信用池余额
//   0x98 R: stat_pool_exhaust (授予被池限制的连接数)
//   0x99 R: redge[0]          0x9A R: {16'b0, winq[0]}
//   0x9B R: {16'b0, wu_mark[0]}   0x9C R: stat_fc_upd (窗口纠偏写数)
//   0x9D R: stat_fc_wait_max (fc 请求最长连续挂起拍数 — 活性观测)
//   0x9E R: stat_slot_reuse (C18: 该槽仍持旧配额时又来 ev_up 的次数;
//           正常 HLS 流程恒 0 — 非 0 表示走过"旧配额先归还"的防御路径)
//   0x9F R: 设计标识 0x5035_4231 ("P5B1")
//
// ---- P5c-T3: 关闭超时 (G2) + abort 硬化 (G3) ----
// G2 关闭超时: 半关闭 (FIN 已发而对端不 ACK/不回 FIN) 时 fast path 原状是
//   fin_sent=1 / state=1 永久保持 ⇒ HLS 槽位永久占用 (MAX_TCP_CONN=3 ⇒ 三次半关闭
//   后板子再也建不了连)。本模块内实现 per-slot 超时 (0 新顶层端口):
//     fin_sent[c] && c_state[c]==ESTAB && **连接无进展** 连续 FIN_TO_LIM 轮扫描
//     ⇒ 三件事同拍:
//       ① rst_req[c] <= 1 (abort 该连接: tcp_tx_frame 扫描排队发 RST)
//       ② CONN_DOWN 事件 (o_ev_down/o_ev_slot 脉冲; 见下面的投递说明)
//       ③ st_pend[c] <= 1 (state=0 写, 经 fc 通道 → TCB.upd_sel=5)
//     ④ 归还该槽配额 (pool += winq[c], winq[c]=0) — 见下"审查修正"
//   **"无进展" = 对端自上次扫描以来没有新数据到达 (rcv_nxt 未推进)** —
//   活性判据见下面 "P5c 关闭超时活性判据" 一节 (板级实测缺陷的修正)。
//   计数单位 = **该槽被扫描到的轮次**: 扫描 tick 每 16 拍 1 次 (tick_cnt 16 分频),
//   16 槽轮一遍 = 256 拍/轮 ⇒ 1 计数 = 256 拍 = 2.048us @125MHz。
//   FIN_TO_LIM = 195313 ⇔ 195313 x 256 拍 = 50.0M 拍 = 400ms = **4 x RTO**
//   (tcp_tx_frame RTO = RTO_LIM 48828 x 256 拍 = 12.5M 拍 = 100ms)。参数化以便
//   单元门用小值定向验证 (与 tcp_tx_frame.RTO_LIM 同惯例; 生产值不改)。
//   计数器**饱和**到 FIN_TO_LIM + FIN_GRACE; 触发用 to_fired[c] 保鲜 (只触发一次)
//   — 不用"每扫描拍检查条件的一次性脉冲"(坑 9: 跨扫描事件会漏), to_fired/st_done
//   都在 ev_up/ev_down 事件脉冲清 (同槽重连不继承旧计数; fin_to 亦在条件不成立
//   或事件拍清 0)。
//
// ---- P5c 关闭超时活性判据 (板级实测缺陷修正; T3 的 G2 判据不够) ----
// T3 原判据 = "fin_sent[c] && c_state[c]==ESTAB 连续 FIN_TO_LIM 轮" —— **不看对端
// 活性、不看 FIN 是否被 ACK** ⇒ 把"我正在收对端数据的半关闭连接"误判为死连接。
// 板级实测 (tshark 逐帧 + 板侧状态行): 板侧 app_pattern 发完自己的 1MB 就 close
// (发 FIN); PC 侧此刻**正在合法地**给板子灌 4MB (RFC 793: 收到 FIN 不阻止继续发
// 数据 = 完全合法的半关闭)。线上: 板侧 FIN @41ms → PC 最后一个数据字节 @62ms →
// 板侧 RST @FIN+400.017ms (恰是 FIN_TO_LIM)。后果: PC 的 4MB 全被丢弃
// (板侧 RX=0 / RS=1, PC 报 WinError 10053)。
// ⇒ 判据必须是"**连接无进展**"而不是"FIN 已发且 ESTAB"。修法 (最小改动):
//   **对端活性 = 该槽 rcv_nxt 相比上次扫描有推进 ⇒ fin_to[c] 清零重新计时**。
//   rcv_nxt 只在对端发来**新数据**时推进 (纯 ACK 不推进; 重复/越界段被 tcp_rx 丢弃
//   也不推进) ⇒ 该判据精确等价于"对端仍有数据流进来 = 有进展"。
//   **零新增状态**: 复用既有的 per-slot 扫描快照 c_rcv_nxt[c] (每 256 拍 = 该槽的
//   计数轮周期更新一次) —— "本次扫描的实时 rc_rcv_nxt != 上次扫描的快照值"即"自上次
//   扫描以来有推进"; 比较用 != (4GB seq 回绕安全)。per-slot 天然隔离 (快照与计数
//   都是 per-slot 阵列)。
//   **语义边界 (三个都成立)**:
//     ① 对端持续有数据 ⇒ 永不触发 (每轮都清零; 半关闭 + 对端在传数据 = 合法状态);
//     ② 对端真静默 ⇒ 到期照常触发 (半关闭且无数据流 ⇒ ~400ms 后 RST) —— 活性判据
//        **不会**让超时永不触发;
//     ③ 活性停止 ⇒ 从**停止时刻**起重新计时 (~FIN_TO_LIM 轮后触发), 不是从 FIN 发出
//        时刻起算。
//   to_fire 也带 !act_now: 恰在"该触发的那一轮"到达的数据同样算活性 ⇒ 该轮不触发、
//   计数清零重来 (否则 to_fire 用的是**旧**计数, 会在有数据的同拍误触发)。
//   **to_fired 之后不再清零** (活性只对未触发的槽计时): 触发时该槽的配额已归还、
//   流控状态已清 (①②③④ 全部做过), 半途恢复一个"已拆除"的连接是不可能的; 且计数
//   必须继续走向 fin_to_max 以驱动 st_grace 兜底 (F2: RST 发不出的情况下仍要拆 state)。
//
// ---- P5c-T3 审查修正 (独立审查 agent 的三条实测发现, 全部采纳) ----
// F1 配额泄漏: state=0 写**不会**产生 ev_down (真 DEL 由 slow_cfg_adp 发), 若只是
//   写 state 而不归还配额, 池被死连接永久占住 ⇒ 后续新连接 winq=0 ⇒ 通告窗 0 ⇒
//   收不了数据 (G2 想治的"再也建不了连"换一种形式复活; 审查 R6 实测)。修法:
//   超时触发与 state 写挂出时都归还配额 (与 ev_down 共用 pool_ret_x 表达式,
//   消除同拍双写 pool 的覆盖风险), 并给 C15 增量补授加 !st_done/!to_fired 守卫
//   (否则刚归还的配额会被同一槽领回去)。winq 清 0 ⇒ 该槽日后真收到 DEL 时归还量
//   为 0 ⇒ 天然不 double-free。
// F2 RST 发不出去: 超时同拍挂 state=0 写, 它 ~3 拍落地 ⇒ 连接变非 ESTAB ⇒
//   tcp_tx_frame 的 rst_push 门 (rb_state==1) 永久为假 (两个模块的 tick 都是复位起
//   自由运行 /16, 同槽访问间隔必为 16 的整数倍, 落在 3 拍窗口外) ⇒ RST 结构性发不
//   出去。修法: 超时只置 rst_req + 事件; state=0 写改由 st_req_now 挂出 = "RST 确实
//   发出 (rst_sent 上升)" 或 "再数 FIN_GRACE 轮 (4 轮 = 1024 拍) 仍发不出" 的兜底。
//   正常时序因此变成 RST 先发、再拆 state (与协议一致)。
// F3 "清位 ≠ 落地": 窗口写 (sel=3) 的 gnt 会把同槽挂着的 state 写请求一起清掉, 而
//   st_done 已锁 ⇒ state=0 写永久丢失 (槽永不释放/永久发不出数据)。修法: st_pend 只在
//   **本次落地的确是 state 写** (fc_sel_r==5) 时清; 未落地则保留 ⇒ 下一轮重选重发。
//   (这正是规格 §4"清除条件必须与确实落地等价"; 与 T1 的 G1 同坑。)
// F4 事件脉冲宽度: 连续投递会变成 2 拍高电平 + 槽号跳变 ⇒ 按沿消费的消费者漏事件。
//   修法: 上一拍有事件 (ev1_v) 或上拍刚投递 (to_pushed_r) 时顺延 ⇒ o_ev_down 恒为
//   孤立 1 拍脉冲 (现有消费者 app_pattern 用电平+槽号, 不受影响)。
//   事件投递选择 (见 G2 裁决二选一): **只给 o_ev_down/o_ev_slot 脉冲**, 不推事件
//   FIFO。理由: ① 事件 FIFO 的 ev_din 携带 peer_ip/port/mac, 而这些字段只在
//   ev_up/ev_down 脉冲拍有效 — 超时事件没有 peer (且 kind 只有 0/1 两位, 复用
//   kind=1 与 DEL 的 CONN_DOWN 不可区分, 新 kind 需改事件字编码 = 接口变更);
//   ② 板级 reg 总线硬接死 (wrapper: app_reg_addr=0/app_reg_wr=0, 无 CPU 消费者)
//   ⇒ FIFO 投递今天零功能价值; ③ 真正的硬件消费者 (app_pattern) 消费的就是
//   o_ev_down/o_ev_slot 这一对。可观测性由 stat_ev_down (寄存器 0x91) 与状态行
//   的 ev_cnt 提供 ⇒ 事件不丢观测。若 P5d 接入 AXI-Lite CPU 读事件字, 再补
//   kind=2 + 零 peer 的 FIFO 投递 (本处留有明确扩展点)。
//   投递拍与外部事件 (ev_up/ev_down) 的互斥: 外部事件优先, 超时事件顺延
//   (to_pend 位图保持到真正投递) — 保证 o_ev_slot 与所投递事件永远一致 (否则
//   app_pattern 会拿错槽号启动 TX)。
// G3 abort 硬化 (state=0 写路径): fast path 原先**无任何 state 写口** (DEL 由慢路径
//   slow_cfg_adp 独占)。这里复用 P5b 的 fc 写通道: fc_upd_sel 由常量 3'd3 改为
//   寄存器 fc_sel_r (3=rcv_wnd 纠偏 / 5=state), abort 完成 (rst_sent[c] 上升,
//   即 RST 确实发出) 或关闭超时时改发 {sel=5, val=0}。**不新增 TCB 写级**
//   (wrapper 的 4 级仲裁 mux 锥余量只剩 0.297ns, 不动它)。
//   互斥: fc 请求只有**一个**请求寄存器 (fc_v/fc_id_r/fc_sel_r/fc_val_r) ⇒ 同拍
//   只可能有一个写落地; st_pend 与 fc_pend 合并进同一个 round-robin 选择
//   (同槽两者皆 pending 时 state 写优先, 且 gnt 时两个位一起清) ⇒ 写窗口与写
//   state 结构性互斥, 不会对同一槽同拍发两个写。
//
// ---- P5b 第二轮: 扫描块 3 拍流水 (时序修复, 阻断级) ----
// 第一版把四级算术串在同一组合链里:
//   winq[c] -> redge_calc(17b 减 + 32b 加) -> sdelta(32b 序比较) ->
//   wcalc(32b 减) -> wu_mark 比较(17b 加)
// 全量构建实测: 37 级逻辑 / 22 CARRY4 (2+8+8+4, 与四级一一对应) / 路由 62.9%,
// WNS -3.089ns / TNS -3475 / 4027 失败端点; 且 Vivado 做了资源共享 (16:1 mux
// 串进链), 出现跨槽路径 winq[14] -> wu_mark[1]。
// 关键观察: 扫描是每 16 拍一次 (tick_cnt 16 分频), 中间 15 拍完全空闲 ⇒ 插入
// 流水线是**免费**的 (无需握手; 延迟寄存器与下一次 scan_tick 间隔 16 拍)。
//   拍 T   (scan_tick): 采样 rc_* -> c_*[]; 锁存 (sid, fq, redge_n, rn, rwnd, state)
//   拍 T+1: 单调判据 (一次 32 位序比较) -> redge[sid] 更新; wscan_r <= fq[15:0]
//   拍 T+2: fc_pend / C6 wu 判定 / C15 增量授权 (全用寄存值)
// 每拍只剩一级算术 ⇒ 组合深度 ~1/3。
// **等价性 (P0 优化 ①)**: 原式 wscan = wcalc(redge_post, rn) 与 fq[15:0] 恒等 ——
// wcalc(redge_n, rn) = fq 因为 redge_n - rn = fq 无回绕 (fq <= WIN_Q_MAX < 2^31),
// wd[31]=0 / wd[31:16]=0 / wd[15:0]=fq <= WIN_Q_MAX ⇒ 三个夹紧分支全假;
// 而 redge_post 与 redge_n 的差别只在 redge_upd=0 时 (sdelta == 0 ⇒
// redge_n == redge[c] ⇒ wcalc(redge[c],rn) = redge_n - rn = fq, 同样相等)。
// sdelta 的物理含义 = 自上次扫描以来 app 消费的字节数 (饱和分支下亦 >= 0 —
// rcv_nxt 每推进 1 字节必同额进 frame_fifo, occ 只由 tcp_rx 写 (+) 与 app 读 (-)
// 改变), 故 sdelta >= 0 恒成立, 上述两分支穷尽了全部情形 ⇒ **逐位等价**。
// ⇒ 扫描拍直接取 fq[15:0], 白算的 32 位减法消失 (证明见报告)。
// **fc 判据/写值同源自洽 (C5)**: 判据用 wscan_r, 写值也取**同一个** wscan_r ——
// 置 fc_pend[c] 时同拍把该值存进 fc_wq[c], fc_upd_val 按 fc_id 从 fc_wq 选。
// 绝不回头用 warr[] 的组合值 (那样判据与写值可能不一致 ⇒ 写错窗口 ⇒ 溢出)。
//
// 时序: 轮扫用自由运行 16 分频 (tick_cnt), 与 tcp_tx_frame 的 RTO 扫描同惯用法
// (scan 与数据路径无组合关系)。消费者是慢速寄存器逻辑 — 采集注册值, 无组合环。
// fc 选择/取值全用寄存值, 消费端是 TCB 写口 (每拍最多 1 次写) 且 fc 是最低优先级
// — 无新增长前向链 (最差链仍是 rb_id -> TCB 读 -> wnd 比较 -> tready)。
//=============================================================================
module app_ctrl #(
    parameter [15:0] WIN_CAP   = 16'hBFFE,  // 与 tcp_tx_frame.RING_CAP 同值 (发送侧帽)
    parameter [15:0] WIN_POOL  = 16'hC000,  // 信用池上限 (单连接 = 今天静态 48K)
    // P5b: 单连接配额上限 (按构造 Σ winq <= WIN_POOL, 窗口不可撤销 ⇒ 必须预分配)。
    // 多连接场景把它调成 WIN_POOL/预期连接数 (P5d 文档写明): 池空时后续连接只能
    // 拿到剩余量 (stat_pool_exhaust 观测), 已建连接不重分配 (降级是有意的 —
    // 窗口不可撤销)。
    parameter [15:0] WIN_Q_MAX = 16'hC000,
    // P5c-T3 G2: 关闭超时阈值 (单位 = 该槽被扫描到的轮次; 见文件头换算 —
    // 生产值 195313 轮 = 400ms = 4xRTO @125MHz)。18 位 (195313 < 2^18)。
    parameter [17:0] FIN_TO_LIM = 18'd195313,
    // P5c-T3 G2 (审查 F2 修正): RST 宽限轮数。超时触发时 state=0 写只需 ~3 拍就
    // 落地, 而 RST 要等 tcp_tx_frame 的**下几次扫描** (该模块 rst_push 要求
    // rb_state==1) — 两个模块的 tick 都是复位起自由运行的 /16, 同槽访问间隔必为
    // 16 的整数倍 ⇒ 无宽限时 state 先落地, RST 结构性发不出去 (实测 R1: 0 帧)。
    // 因此超时只先置 rst_req + 事件, state=0 写等"RST 确实发出 (rst_sent 上升)"
    // 或"再数 FIN_GRACE 轮仍发不出"的兜底 (4 轮 x 256 拍 = 1024 拍 = 8.2us)。
    parameter [17:0] FIN_GRACE = 18'd4
) (
    input  wire        clk,
    input  wire        rst_n,
    // ---- 连接事件源 (slow_cfg_adp; 脉冲 + 保持字段) ----
    input  wire        ev_up,
    input  wire        ev_down,
    input  wire [3:0]  ev_slot,
    input  wire [31:0] ev_peer_ip,
    input  wire [15:0] ev_peer_port,
    input  wire [47:0] ev_peer_mac,
    // ---- TCB 组合读口 C (轮扫采样 / init 拍读新槽) ----
    output wire [3:0]  rc_id,
    input  wire [31:0] rc_snd_nxt,
    input  wire [31:0] rc_snd_una,
    input  wire [31:0] rc_rcv_nxt,
    input  wire [15:0] rc_rcv_wnd,
    input  wire [15:0] rc_snd_wnd,
    input  wire [3:0]  rc_state,
    // ---- 状态输入 ----
    input  wire [16:0] rx_occ_bytes,   // app RX 可读字节 (echo frame_fifo 占用)
    input  wire [15:0] fin_sent,       // tcp_tx_frame.o_fin_sent
    // P5c-T3 G3: tcp_tx_frame.o_rst_sent (abort fence) — abort 后 app 不该再看到
    // tx_ready; 上升沿同时是"abort 完成"的触发 (⇒ 走 fc 通道写 state=0)
    input  wire [15:0] rst_sent,
    // ---- 事件脉冲转发 (app_pattern 用; 与事件 FIFO 推送同拍) ----
    output reg         o_ev_up,
    output reg         o_ev_down,
    output reg  [3:0]  o_ev_slot,
    // ---- FIN/RST 请求 (tcp_tx_frame.fin_req/rst_req) ----
    output reg  [15:0] fin_req,
    output reg  [15:0] rst_req,
    // ---- app_pattern 关闭请求 (等价 CMD close; 与寄存器写同源) ----
    input  wire        close_req,
    input  wire [3:0]  close_id,
    // ---- P5b: 窗口纠偏写 (TCB 写口第 4 级仲裁, 最低优先级) ----
    // 电平请求 + gnt 握手 (与 slow_cfg_adp.upd_wr/cfg_gnt 同惯例): fc_upd_wr 保持
    // 到 fc_gnt 回来。sel 恒 3'd3 = rcv_wnd; val = 该连接当前应通告的窗口。
    output wire        fc_upd_wr,
    output wire [3:0]  fc_upd_id,
    output wire [2:0]  fc_upd_sel,
    output wire [31:0] fc_upd_val,
    input  wire        fc_gnt,
    // ---- P5b: 窗口更新 ACK (wu) 请求 (tcp_tx_frame.wu_*) ----
    // 电平保持到 wu_gnt (M1 教训: 脉冲请求在 ackq 满时会永久丢失 ⇒ 关闭/重开
    // 永不完成); wu_gnt = 条目确实入队 (见 tcp_tx_frame C7)。
    output wire        wu_req,
    output wire [3:0]  wu_id,
    output wire [31:0] wu_val,
    input  wire        wu_gnt,
    // ---- 寄存器总线 (读组合, 写 1 拍) ----
    input  wire [7:0]  reg_addr,
    input  wire        reg_wr,
    input  wire [31:0] reg_wdata,
    output reg  [31:0] reg_rdata,
    // ---- 状态输出 ----
    output wire [15:0] app_tx_ready,
    // conn0 采集快照 (纯线束; 板上状态行/调试用 — 免跨模块层次引用)
    output wire [3:0]  dbg_c0_state,
    output wire [31:0] dbg_c0_snd_nxt,
    output wire [31:0] dbg_c0_snd_una,
    output wire [31:0] dbg_c0_rcv_nxt,
    output wire [15:0] dbg_c0_rcv_wnd,
    output wire [15:0] dbg_c0_snd_wnd,
    output wire [15:0] dbg_estab_cnt,
    output wire [15:0] dbg_ev_cnt,
    // P5b 流控观测 (状态行 C9 / 寄存器读)
    output wire [31:0] dbg_redge0,
    output wire [15:0] dbg_winq0,
    output wire [15:0] dbg_wu_mark0,
    output wire [16:0] dbg_pool,
    output reg  [31:0] stat_ev_up,
    output reg  [31:0] stat_ev_down,
    output reg  [31:0] stat_ev_drop,
    output reg  [31:0] stat_cmd_close,
    output reg  [31:0] stat_cmd_abort,
    output reg  [31:0] stat_wu,
    output reg  [31:0] stat_pool_exhaust,
    output reg  [31:0] stat_fc_upd,
    // C18 观测: 该槽仍持旧配额时又来 ev_up (配额被归还而非蒸发) 的次数。
    // 正常 HLS 流程恒 0 (ADD 不会重发到已占用槽); 非 0 = 触发过防御路径。
    output reg  [31:0] stat_slot_reuse,
    // P5b 活性观测: fc 请求最长连续挂起拍数 (看门狗式)。规格 C1b 的 Δ 界
    // (通告右沿 = redge_old + Δ) 依赖"窗口写口不被长期饿死"这一活性假设 ——
    // 若该值 > 16384 拍 (131us), Δ 的定量上界失效 ⇒ 必须落档提醒 (P6 前哨)。
    output reg  [31:0] stat_fc_wait_max
);
    // ESTABLISHED = state 1 (slow_cfg_adp ADD 写 state=1; DEL 写 0)
    localparam [3:0] ST_ESTAB = 4'd1;
    // C6: 窗口"显著增长"阈值 = 半个池。数据流正常时 W_new 恒在 winq ⇒ 该分支
    // 恒假 ⇒ **零额外帧** (帧率是稀缺资源: P5a-0 实测每段两帧已近对端上限)。
    localparam [15:0] WU_STEP = WIN_POOL >> 1;

    // ---- 事件 FIFO (FWFT, 102 位 x 16) ----
    localparam EW = 102;
    wire          ev_full, ev_empty;
    wire [EW-1:0] ev_dout;
    reg           ev_ovf;            // sticky: 满时丢弃过
    reg           ev_pop;            // 弹出脉冲 (寄存器 0x05 写)
    wire          ev_push = (ev_up || ev_down) && !ev_full;
    wire [EW-1:0] ev_din  = {ev_up ? 2'd0 : 2'd1, ev_slot, ev_peer_mac,
                             ev_peer_port, ev_peer_ip};
    wire [1:0]  hd_kind = ev_dout[101:100];
    wire [3:0]  hd_slot = ev_dout[99:96];
    wire [47:0] hd_mac  = ev_dout[95:48];
    wire [15:0] hd_port = ev_dout[47:32];
    wire [31:0] hd_ip   = ev_dout[31:0];

    fifo_sync #(.W(EW), .D(16), .AW(4)) u_evfifo (
        .clk(clk), .rst_n(rst_n),
        .wr(ev_push), .din(ev_din),
        .rd(ev_pop), .dout(ev_dout),
        .empty(ev_empty), .full(ev_full),
        .dbg_wptr(), .dbg_rptr(), .dbg_full(), .dbg_empty()
    );

    // ---- 16 分频轮扫 (自由运行 tick) ----
    reg  [3:0]  tick_cnt;
    reg  [3:0]  scan_id;
    wire        scan_tick = (tick_cnt == 4'd15);
    //=========================================================================
    // P5b 流控状态
    //=========================================================================
    // redge[c]: 已通告给对端的**接收右沿上界** (32 位单调不降)。语义: 对端
    //           允许发送的数据上界 = redge[c] (窗口 = redge[c] - rcv_nxt)。
    //           右沿一旦通告就不可撤销 ⇒ 只能抬高, 不能降低 (降低会把对端
    //           已发出的数据"撤窗" ⇒ 静默丢帧 + 死锁)。
    // winq[c] : 该连接的接收配额 (= 授予的信用; 池分配 + C15 增量补授)
    // wu_mark : 上次 wu 通告的窗口值 (C6 的显著增长判据)
    // wu_zero : 窗口曾关到 0 (对端在停等, 必须主动通知重开)
    // wu_pend : 窗口更新 ACK 电平请求 (等 wu_gnt)
    // fc_pend : TCB.rcv_wnd 纠偏请求位图 (组合选择 -> 装载进请求寄存器)
    // fc_wq   : 与 fc_pend 同拍写入的"该写什么窗口" (wscan_r / init 的 winq) —
    //           fc_upd_val 按 fc_id 从这个阵列选 ⇒ 判据与写值同源自洽 (C5)
    // fc_v/fc_id_r/fc_val_r: 请求寄存器 (C5 时序建议: 与 svc_id_r 同惯例 —
    //           round-robin 优先编码 (16 项 4 级 LUT) 不许压在 TCB 写口那条
    //           只剩 0.297ns 余量的锥上; 1 拍旧值只让窗口更新晚一拍, 无害)
    // pool    : 信用池余额 (17 位, 保证不下溢)
    reg  [31:0] redge   [0:15];
    reg  [15:0] winq    [0:15];
    reg  [15:0] wu_mark [0:15];
    // P5b 修正: 三个 1 位位图用 16 位向量而非 unpacked 数组 —— round-robin
    // 优先编码要整体传进 function (Verilog 不能按值传 unpacked 数组),
    // 且位选 (fc_pend[i]) 可读可写, 语义与数组等价。
    reg  [15:0] wu_zero;
    reg  [15:0] wu_pend;
    reg  [15:0] fc_pend;
    reg  [15:0] fc_wq   [0:15];      // fc_pend[c] 对应的目标窗口 (同拍写入)
    reg         fc_v;
    reg  [31:0] fc_wait;             // 当前连续挂起拍数
    reg  [3:0]  fc_id_r;
    reg  [31:0] fc_val_r;
    // P5c-T3 G3: fc 通道的写**选择** (原为常量 3'd3)。3 = rcv_wnd 纠偏 (P5b),
    // 5 = state (tcb upd_sel 语义; val=0 = 拆连)。与 fc_v/fc_id_r/fc_val_r 同拍
    // 装载、保持到 gnt (消费者只在 fc_upd_wr=fc_v=1 时看它)。
    reg  [2:0]  fc_sel_r;
    reg  [3:0]  fc_rr;               // round-robin 起点 (上次服务的 id+1)
    reg  [16:0] pool;
    reg         init_pend;
    reg  [3:0]  init_slot;
    // ---- P5c-T3 G2/G3: 关闭超时 + state=0 写请求 ----
    reg  [17:0] fin_to    [0:15];    // FIN 已发且仍 ESTAB 的连续扫描轮数 (饱和)
    reg  [15:0] to_pend;             // (G2) 待投递的 CONN_DOWN 超时事件位图
    reg  [15:0] to_fired;            // (G2) 超时已触发 (只触发一次; ev_up/ev_down 清)
    reg  [15:0] st_pend;             // (G3) state=0 写请求位图 (经 fc 通道, sel=5)
    reg  [15:0] st_done;             // 该槽已请求过 state 写 (只做一次;
                                     // 只在 ev_up/ev_down 事件脉冲清 — 同槽重连不继承)
    reg         to_pushed_r;         // 上拍投递过超时 CONN_DOWN (脉冲隔离, 见 to_push)
    // 超时计数饱和上限 = 超时阈值 + RST 宽限轮数 (见 FIN_GRACE 参数注释)
    wire [17:0] fin_to_max = FIN_TO_LIM + FIN_GRACE;
    // ---- P0 扫描流水线寄存器 (见文件头等价性证明) ----
    // 拍 T: 采样 + fq/redge_n 计算
    reg         pa_v;
    reg  [3:0]  pa_sid;              // 被采样的槽号
    reg  [16:0] pa_fq;               // (occ >= winq) ? 0 : winq - occ
    reg  [31:0] pa_redge_n;          // 右沿候选 = rn + fq
    reg  [15:0] pa_rwnd;             // 采样 rcv_wnd (fc 判据对照)
    reg  [3:0]  pa_state;
    // 拍 T+1: 单调判据 + wscan 落定
    reg         pb_v;
    reg  [3:0]  pb_sid;
    reg  [15:0] pb_wscan;            // = pa_fq[15:0] (等价性证明)
    reg  [15:0] pb_rwnd;
    reg  [3:0]  pb_state;
    // 事件撞车跟踪 (让位): 事件的清理/授权/init 才是权威值 — 流水线 landing
    // 若与同一槽的事件撞在同一拍, 必须丢弃 (否则用旧会话数据毒化 redge/fc/wu)。
    reg         ev1_v;               // 上一拍有 ev_up/ev_down
    reg  [3:0]  ev1_slot;


    // C3/C10: init_pend 拍 rc_id 旁路到 init_slot — 该拍读的是刚 cfg 完的新槽
    // (rcv_nxt 等七字段已落地), 用来初始化 redge/wu_mark/rcv_wnd 纠偏。
    assign      rc_id = init_pend ? init_slot : scan_id;
    reg  [3:0]  c_state   [0:15];
    reg  [31:0] c_snd_nxt [0:15];
    reg  [31:0] c_snd_una [0:15];
    reg  [31:0] c_rcv_nxt [0:15];
    reg  [15:0] c_rcv_wnd [0:15];
    reg  [15:0] c_snd_wnd [0:15];
    reg  [31:0] scan_round;          // 扫描心跳 (每 16 次采集 +1)

    // ---- app_tx_ready: ESTAB && 在飞 < min(snd_wnd, WIN_CAP) && !fin_req
    //      && !fin_sent && !rst_req && !rst_sent (P5a 用轮扫注册值;
    //      精门 = tcp_tx_frame 的 win_open) ----
    // ⚠️ WIN_CAP 帽保持不变: 这是**发送侧**帽 (ring 容量), 与接收窗口闭环无关。
    // P5c-T3 G3: 追加 rst_req / rst_sent 两项 (abort 硬化的 app 侧一半) —
    //   rst_sent (tcp_tx_frame 的"RST 已发出"黑名单) 覆盖 [RST 发出, state=0 落定]
    //   窗口; rst_req 再往前覆盖 [abort 请求, RST 发出] 窗口 (与 fin_req 对称 —
    //   FIN 侧本来就是 fr 起作用)。两者都由事件/扫描路径自愈 (state!=ESTAB 时
    //   app_ctrl 扫描清 rst_req、tcp_tx_frame 扫描清 rst_sent_r), 不会永久卡死。
    // 默认构建: rst_req/rst_sent 恒 0 ⇒ 本项恒 1 (APP_MODE 独有模块, 无默认路径) ✓
    function [15:0] tx_ready_calc;
        input [3:0]  st;
        input [31:0] nxt;
        input [31:0] una;
        input [15:0] wnd;
        input        fr;
        input        fs;
        input        rs;             // P5c-T3: rst_sent[c]
        input        rq;             // P5c-T3: rst_req[c]
        reg   [15:0] eff;
        begin
            eff = (wnd < WIN_CAP) ? wnd : WIN_CAP;
            tx_ready_calc = (st == ST_ESTAB) &&
                            ((nxt - una) < {16'b0, eff}) && !fr && !fs &&
                            !rs && !rq;
        end
    endfunction

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : g_rdy
            assign app_tx_ready[gi] = tx_ready_calc(c_state[gi], c_snd_nxt[gi],
                                                    c_snd_una[gi], c_snd_wnd[gi],
                                                    fin_req[gi], fin_sent[gi],
                                                    rst_sent[gi], rst_req[gi]);
        end
    endgenerate

    // ---- ESTAB 计数 (读寄存器 0x09) ----
    reg [15:0] estab_cnt;
    integer    ci;
    always @(*) begin
        estab_cnt = 16'd0;
        for (ci = 0; ci < 16; ci = ci + 1)
            if (c_state[ci] == ST_ESTAB) estab_cnt = estab_cnt + 16'd1;
    end

    // conn0 采集快照 (纯线束; 板上状态行/调试用 — 免跨模块层次引用)
    assign dbg_c0_state   = c_state[0];
    assign dbg_c0_snd_nxt = c_snd_nxt[0];
    assign dbg_c0_snd_una = c_snd_una[0];
    assign dbg_c0_rcv_nxt = c_rcv_nxt[0];
    assign dbg_c0_rcv_wnd = c_rcv_wnd[0];
    assign dbg_c0_snd_wnd = c_snd_wnd[0];
    assign dbg_estab_cnt  = estab_cnt;
    assign dbg_ev_cnt     = stat_ev_up[15:0] + stat_ev_down[15:0];

    assign dbg_redge0   = redge[0];
    assign dbg_winq0    = winq[0];
    assign dbg_wu_mark0 = wu_mark[0];
    assign dbg_pool     = pool;

    // ---- C2: 窗口计算 (带符号语义 + 夹紧; 禁止裸减法) ----
    // wdiff[31] = 1 表示 redge 落后 rcv_nxt (占用曾满期间 redge 停在 rcv_nxt 而
    // rcv_nxt 继续推进) ⇒ 窗口必须为 0。裸减法在此回绕成巨大值 ⇒ W 撑满 ⇒
    // 物理缓冲溢出 (本里程碑的安全核心)。
    // 夹紧帽用 WIN_Q_MAX (配额上限) 而**不是** WIN_CAP(0xBFFE): 配额 0xC000 是
    // 与 P5a 静态值逐位一致的合法窗口, 用 0xBFFE 当帽会把它夹掉 ⇒ 通告窗变小、
    // 与 HLS SYN-ACK 通告的 48K 不一致 (P5a 门判据也按 0xC000)。redge 由构造
    // 恒 <= rcv_nxt + winq <= rcv_nxt + WIN_Q_MAX ⇒ 夹紧分支结构性不可达, 纯防御。
    // ⚠️ P5b 第二轮: 本函数**不再参与扫描拍的关键路径** (扫描拍用 fq[15:0], 见
    // 文件头的等价性证明 —— wcalc(redge_n, rn) ≡ fq); 保留它是为了保留那条
    // 参考语义 (以及 init/调试口径), 若将来有"从注册阵列算窗口"的新路径, 必须
    // 用它而不是自己拼减法。
    function [15:0] wcalc;
        input [31:0] rg;             // redge
        input [31:0] rn;             // rcv_nxt
        reg   [31:0] wd;
        begin
            wd = rg - rn;
            if (wd[31])                      wcalc = 16'd0;
            else if (|wd[31:16])             wcalc = WIN_Q_MAX;
            else if (wd[15:0] > WIN_Q_MAX)   wcalc = WIN_Q_MAX;
            else                             wcalc = wd[15:0];
        end
    endfunction

    // ---- C1: 配额内剩余 fq (饱和) + 右沿候选 (同一表达式 ⇒ 算术不可能分叉) ----
    // fq = (occ >= winq) ? 0 : (winq - occ); 0 <= fq <= winq <= WIN_Q_MAX < 2^16
    // ⇒ fq[16] 恒 0, fq[15:0] 即窗口 (等价性证明见文件头)。
    function [16:0] fq_calc;
        input [15:0] q;              // winq[c]
        input [16:0] oc;             // 全局 frame_fifo 占用字节
        begin
            // occ >= winq ⇒ 缓冲占满配额 ⇒ 剩余 0 (饱和, 禁止 17 位回绕)
            fq_calc = (oc >= {1'b0, q}) ? 17'd0 : ({1'b0, q} - oc);
        end
    endfunction

    function [31:0] redge_calc;
        input [15:0] q;              // winq[c]
        input [31:0] rn;             // rcv_nxt
        input [16:0] oc;             // 全局 frame_fifo 占用字节
        begin
            redge_calc = rn + {15'b0, fq_calc(q, oc)};
        end
    endfunction

    // ---- C5: fc 选择 (round-robin, 不能固定最低位优先 — 高频低位会饿死其余) ----
    function [4:0] fc_pick;          // {valid, id}
        input [15:0] pend;
        input [3:0]  rr;
        integer i;
        reg [3:0]  cand;
        reg        found;
        begin
            cand = rr; found = 1'b0;
            // 逆序扫描: 最后写入的是离 rr 最近的置位 (同 prio_lo 惯用法)
            for (i = 15; i >= 0; i = i - 1) begin
                if (pend[rr + i[3:0]]) begin
                    cand  = rr + i[3:0];
                    found = 1'b1;
                end
            end
            fc_pick = {found, cand};
        end
    endfunction

    // ---- P5c-T3 G2: 超时 CONN_DOWN 事件的投递选择 ----
    // 事件投递 = o_ev_down/o_ev_slot **脉冲** (理由见文件头 "事件投递选择")。
    // 投递与外部事件 (ev_up/ev_down, 源 slow_cfg_adp) **互斥**: 外部事件优先
    // (它带 peer 字段且 1 拍就消失, 丢了不可恢复), 超时事件顺延到下一个无外部
    // 事件的拍 (to_pend 位图保持到真正投递)。若同拍抢 o_ev_slot, 该拍挂出的
    // (o_ev_up, o_ev_slot) 会是"脉冲 A + 槽号 B"的错配 ⇒ app_pattern 会在错的
    // 槽上启动 TX — 必须结构性排除。
    // 多位同时 pending ⇒ 最低位优先 (一次投一个, 下拍自动投下一个)。
    function [3:0] prio_lo4;         // 最低置位优先 (同 tcp_tx_frame.prio_lo 惯例)
        input [15:0] v;
        integer i;
        begin
            prio_lo4 = 4'd0;
            for (i = 15; i >= 0; i = i - 1)
                if (v[i]) prio_lo4 = i[3:0];
        end
    endfunction
    wire [3:0] to_slot_w = prio_lo4(to_pend);
    // 脉冲隔离: 连续投递会变成"一个 2 拍宽的高电平 + 槽号跳变" —— 按上升沿消费的
    // 消费者 (将来的 CPU 事件读口) 会漏掉第二个事件。故上一拍有事件 (ev1_v) 或上
    // 一拍刚投递过 (to_pushed_r) 时顺延一拍 ⇒ o_ev_down 恒为**孤立 1 拍脉冲**。
    // (现有真消费者 app_pattern 用"电平 + 槽号比较", 不受影响; 这是契约加固。)
    wire       to_push   = (|to_pend) && !(ev_up || ev_down) && !ev1_v &&
                           !to_pushed_r;

    // ---- P5c-T3 G3: state=0 写请求 (st_pend) 并入**同一个** fc 请求寄存器 ----
    // 互斥 (TL 要求: 同一槽既有 pending 的窗口写、又要写 state): 本模块只有一个
    // 请求寄存器 (fc_v/fc_id_r/fc_sel_r/fc_val_r) ⇒ 任何时刻最多一个写落地, 同拍
    // 不可能发两个写。st_pend 与 fc_pend 合并进同一次 round-robin 选择 (fc_rr
    // 共用、gnt 时推进) — 同槽两者皆 pending 时 state 写优先 (槽正在拆除, 窗口
    // 纠偏已无意义), 且 gnt 时把**两个**位一起清 (否则残留位会对已拆的槽反复发写)。
    // st_pend=0 时本选择与旧式 (fc_pick(fc_pend, fc_rr)) 逐位相同 ⇒ 既有门不变。
    wire [15:0] fc_req_all = fc_pend | st_pend;
    wire [4:0] fc_sel5 = fc_pick(fc_req_all, fc_rr);
    wire       fc_new  = fc_sel5[4];
    wire       fc_is_st = st_pend[fc_sel5[3:0]];   // 选中槽 = state 写?
    // 装载条件: 当前无挂起请求且有新请求 (本拍选择)。装载后 id/val 冻结到 gnt —
    // 写口与本模块的"清位"用**同一个** fc_id_r ⇒ 写的连接与清的位永远一致。
    wire       fc_load = !fc_v && fc_new;
    assign fc_upd_wr  = fc_v;                     // 电平: 保持到 fc_gnt
    assign fc_upd_id  = fc_id_r;
    assign fc_upd_sel = fc_sel_r;                 // 3 = rcv_wnd / 5 = state (T3)
    assign fc_upd_val = fc_val_r;
    // 组合候选值 (仅装载拍采样): C5 强制 — 按 fc_id 选**与该位同拍写入的**窗口值
    // (fc_wq: 判据 wscan_r 或 init 的 winq)。绝不能用"当前扫描连接 (scan_id) 算出的
    // W_new" —— 那会写错连接的窗口, 恶意大窗能把 occ 顶到 2×winq ⇒ 物理溢出 (审查 Q4)。
    // P5b 第二轮: 由 warr[] (redge 组合重算) 改为 fc_wq[] (判据同源存值) —— 判据与
    // 写值永远一致 (扫描是流水的, 判据 wscan_r 已与当拍 redge[fc_id] 解耦)。
    // P5c-T3: state 写 (fc_is_st) 的写值恒 0 (tcb upd_sel=5 只取低 4 位 state;
    // val=0 = 拆连)。否则仍是"与判据同源"的 fc_wq 窗口值。
    wire [31:0] fc_val_new = fc_is_st ? 32'd0 : {16'b0, fc_wq[fc_sel5[3:0]]};
    wire [2:0]  fc_sel_new = fc_is_st ? 3'd5 : 3'd3;

    // ---- C6: wu 选择 (同一 round-robin 起点; 电平请求保持到 wu_gnt) ----
    wire [4:0] wu_sel5 = fc_pick(wu_pend, fc_rr);
    assign wu_req = wu_sel5[4];
    assign wu_id  = wu_sel5[3:0];
    // wu_val = 该连接 rcv_nxt 的**扫描采样值** (c_rcv_nxt, 与写进 TCB 的窗口
    // 同源自洽: 帧里 right = wu_val + window = redge)。不用实时 rc_rcv_nxt —
    // 那需要读口 C 复用 (与扫描抢地址), 且采样值偏差 <= 一次扫描 (见 C1b Δ)。
    assign wu_val = c_rcv_nxt[wu_sel5[3:0]];

    // ---- 寄存器读 (组合, 无等待) ----
    // 每连接块索引: 0x10 + 4c (0x10..0x4F) -> c = addr[5:2] + 12 (mod 16)
    wire [3:0] pc_c   = reg_addr[5:2] + 4'd12;
    wire [1:0] pc_sel = reg_addr[1:0];
    always @(*) begin
        reg_rdata = 32'd0;
        if (reg_addr <= 8'h0B) begin
            case (reg_addr[3:0])
                4'h0: reg_rdata = {30'b0, ev_ovf, ev_empty};
                4'h1: reg_rdata = {26'b0, hd_kind, hd_slot};
                4'h2: reg_rdata = hd_ip;
                4'h3: reg_rdata = {hd_port, hd_mac[47:32]};
                4'h4: reg_rdata = hd_mac[31:0];
                4'h7: reg_rdata = {16'b0, app_tx_ready};
                4'h8: reg_rdata = {15'b0, rx_occ_bytes};
                4'h9: reg_rdata = {estab_cnt,
                                   (stat_ev_up[15:0] + stat_ev_down[15:0])};
                4'hA: reg_rdata = {c_state[7],  c_state[6],  c_state[5],  c_state[4],
                                   c_state[3],  c_state[2],  c_state[1],  c_state[0]};
                4'hB: reg_rdata = {c_state[15], c_state[14], c_state[13], c_state[12],
                                   c_state[11], c_state[10], c_state[9], c_state[8]};
                default: reg_rdata = 32'd0;
            endcase
        end else if (reg_addr >= 8'h10 && reg_addr <= 8'h4F) begin
            case (pc_sel)
                2'd0: reg_rdata = {28'b0, c_state[pc_c]};
                2'd1: reg_rdata = c_snd_una[pc_c];
                2'd2: reg_rdata = c_snd_nxt[pc_c];
                default: reg_rdata = {c_rcv_wnd[pc_c], c_snd_wnd[pc_c]};
            endcase
        end else if (reg_addr >= 8'h50 && reg_addr <= 8'h5F) begin
            reg_rdata = c_rcv_nxt[reg_addr[3:0]];
        end else begin
            case (reg_addr)
                8'h90: reg_rdata = stat_ev_up;
                8'h91: reg_rdata = stat_ev_down;
                8'h92: reg_rdata = stat_ev_drop;
                8'h93: reg_rdata = stat_cmd_close;
                8'h94: reg_rdata = stat_cmd_abort;
                8'h95: reg_rdata = scan_round;
                8'h96: reg_rdata = stat_wu;
                8'h97: reg_rdata = {15'b0, pool};
                8'h98: reg_rdata = stat_pool_exhaust;
                8'h99: reg_rdata = redge[0];
                8'h9A: reg_rdata = {16'b0, winq[0]};
                8'h9B: reg_rdata = {16'b0, wu_mark[0]};
                8'h9C: reg_rdata = stat_fc_upd;
                8'h9D: reg_rdata = stat_fc_wait_max;
                8'h9E: reg_rdata = stat_slot_reuse;    // C18: 已占槽二次 ev_up
                8'h9F: reg_rdata = 32'h5035_4231;      // "P5B1"
                default: reg_rdata = 32'd0;
            endcase
        end
    end

    // ---- C4/C14: 授予量/归还量 (组合, 只用当拍可见的注册值) ----
    // 授予 (C14-①): g = (pool > occ) ? min(WIN_Q_MAX, pool - occ) : 0
    // 池与物理缓冲共享同一笔额度 —— 零拷贝遗留占用 (occ) 必须从新连接配额里扣掉。
    wire [16:0] pool_q    = {1'b0, WIN_Q_MAX};
    wire [16:0] pool_occ  = (pool > rx_occ_bytes) ? (pool - rx_occ_bytes) : 17'd0;
    wire [16:0] g_grant   = (pool_q < pool_occ) ? pool_q : pool_occ;
    // 归还: pool + winq[ev_slot], 封顶 WIN_POOL (重复 ev_down 时 winq=0 ⇒ 归还 0)。
    // P5c-T3: 归还表达式统一为 pool_ret_x (与超时/abort 收尾的归还**同一个**表达式,
    // 见下声明处) —— ev_down 时两者逐位相同, 合并只为消除同拍双写 pool 的覆盖风险。
    // (原 p_sum/pool_ret 已并入 pool_ret_x)
    // C18: ev_up 记池 = pool - g_grant + winq[ev_slot] (旧配额先归还, 封顶 WIN_POOL)。
    // 若该槽仍持旧配额而无 ev_down 归还 (HLS 在已占用槽上重发 ADD), 旧值被 g_grant
    // 覆盖却不归池 ⇒ Σwinq + pool < WIN_POOL ⇒ pool==0 时 g_grant=0 ⇒ winq=0 且
    // C15 补授 (要求 pool != 0) 永远救不回 ⇒ **永久零窗**。防御性修复 + stat_slot_reuse
    // 观测 (TL 已确认正常 HLS 流程不可达: T_SYN_RCVD 收到 SYN 重传只重发 SYN+ACK,
    // 不重发 ADD)。
    wire [17:0] pool_reuse = {1'b0, pool} - {1'b0, g_grant} + {2'b0, winq[ev_slot]};
    wire [16:0] pool_upd   = (pool_reuse > {2'b0, WIN_POOL}) ? {1'b0, WIN_POOL}
                                                             : pool_reuse[16:0];
    // C15-② 增量授权量: min(WIN_Q_MAX - winq[c], pool), 位宽扩展防下溢
    // ⚠️ 与 C14-① 的交互 (测试 agent 实测): 扫描拍若与 ev_up 同拍, 增量补授会
    // **赢过** C14-① 的授予预留 (occ=20480 时预留 28672 被补成 49152)。安全性仍由
    // redge_calc 的 occ 修正兜住 (occ + 窗 = 49152 <= 65536 ✓), 但"双保险"实为
    // 单保险 ⇒ C17 的扫描让位 (下 always 的采样守卫) 使两者不再同拍。
    wire [15:0] inc_room  = WIN_Q_MAX - winq[pb_sid];    // 用流水槽号 (拍 T+2)
    wire [16:0] inc_grant = ({1'b0, inc_room} < pool) ? {1'b0, inc_room}
                                                      : pool;

    // ---- C1: 扫描拍级 1 组合算术 (注册阵列 + 当拍 rc_* 读出) ----
    // 只剩一级 17 位饱和减法 (fq) + 一级 32 位加法 (redge_n)。原来是四级串联
    // (fq -> redge_n -> sdelta -> wcalc -> wu_mark 比较), 实测 22 CARRY4 / 37 级
    // 逻辑 / WNS -3.089ns。fq 同时供 redge_n 与 fq_r 锁存 (wscan 由它直接得到)。
    wire [16:0] fq_scan  = fq_calc(winq[scan_id], rx_occ_bytes);
    wire [31:0] redge_n  = rc_rcv_nxt + {15'b0, fq_scan};
    // 拍 T+1 的单调判据 (对寄存值做一次 32 位序比较)
    wire signed [31:0] sdelta_b = $signed(pa_redge_n - redge[pa_sid]);
    wire               upd_b    = (sdelta_b > 32'sd0);   // 单调 (序比较, 回绕安全)
    // 事件撞车 (让位): 事件块/init 的清理与授权是权威值 —— 同一槽的事件若落在
    // 流水线窗口内, 该 item 必须丢弃, 否则用旧会话数据毒化 redge/fc/wu。
    //  拍 T   : 采样守卫 (ev_up/ev_down 同槽 ⇒ 本拍不采样, 见下 always)
    //  拍 T+1 : 上拍事件 (ev1) 不可能同槽 (守卫已挡); 只需查当拍
    //  拍 T+2 : 查当拍 + 上拍 (ev1)
    wire        ev_blk   = ev_up || ev_down;
    wire        hit_b    =  ev_blk && (ev_slot == pa_sid);
    wire        hit_c    = (ev_blk && (ev_slot == pb_sid)) ||
                           (ev1_v && (ev1_slot == pb_sid));

    // ---- P5c 关闭超时活性判据 (见文件头 "P5c 关闭超时活性判据" 一节) ----
    // act_now = 本槽自上次扫描以来 rcv_nxt 有推进 = 对端有新数据到达 = 连接有进展。
    // 零新增状态: 复用 per-slot 扫描快照 c_rcv_nxt[scan_id] (每 256 拍 = 该槽的计数
    // 轮周期更新一次, 与 fin_to 的计数单位严格同周期) 作"上次扫描值"。两者同在本
    // always 块内非阻塞赋值 ⇒ 本组合式读到的是**上次**采样值 (逐位精确)。
    // 比较用 != (而不是序比较): 4GB seq 回绕安全, 且与"是否推进"语义完全等价。
    // 纯组合、只喂寄存器端点 (to_fire 判定 + fin_to 计数), 无新增长前向链。
    wire        act_now = (rc_rcv_nxt != c_rcv_nxt[scan_id]);

    // ---- P5c-T3 G2/G3: 超时 / state 写请求的组合判据 (全部只喂寄存器端点) ----
    // to_fire: 本拍满足"超时触发"的全部条件 (含扫描拍守卫)。**必须带 !ev_blk**:
    //   ① 与 ev_up (C18 记账: pool <= pool_upd) 同拍时两条 pool 赋值会互相覆盖
    //      (后写者胜 ⇒ 前者静默丢失 ⇒ Σwinq + pool == WIN_POOL 不变量破缺);
    //   ② 与 ev_down 同拍则归还量会重复计 (E 项) 或漏计 (池的物理界因此失守)。
    //   事件是 1 拍脉冲且稀疏, 顺延 1 拍再触发零代价 ⇒ 结构性排除这类同拍。
    // **必须带 !act_now** (P5c 活性判据): fin_to 是寄存器, 本拍的 to_fire 看到的是
    //   **上一轮**的计数 —— 若本拍恰好有数据到达 (对端刚开始活动 / 恰在第 LIM 轮
    //   到达), 旧计数可能已达阈值 ⇒ 会在一轮"有数据"的同拍误触发。带上 !act_now
    //   ⇒ 该轮改为清零重新计时 (与块内计数清零同拍、同判据, 无窗口错位)。
    //   触发拍之后对端再活跃也不改变已触发事实 (to_fired 保鲜), 见文件头 ③。
    wire        to_fire = scan_tick && !init_pend && !ev_blk && !act_now &&
                          fin_sent[scan_id] && (rc_state == ST_ESTAB) &&
                          (fin_to[scan_id] >= FIN_TO_LIM) && !to_fired[scan_id];
    // st_req_now: 本拍要挂出 state=0 写请求 (两来源, 都只发一次):
    //   a) rst_sent[scan_id] (RST 确实发出 = abort 完成 / 超时路径的正常时序)
    //   b) 超时宽限到点 (to_fired 且 fin_to 饱和到 fin_to_max) 而 RST 发不出 ⇒ 兜底
    //  两种情形都在扫描拍采样 rst_sent (寄存器输入, 16:1 mux -> 寄存器端点)。
    wire        st_grace  = to_fired[scan_id] && (fin_to[scan_id] >= fin_to_max);
    // !ev_blk (而不是"同槽事件") 的理由同 to_fire: 本块也要写 pool ⇒ 必须与
    // ev_up 的 C18 记账结构性互斥 (事件拍顺延 1 拍到下一次扫描打点, 零代价)。
    wire        st_req_now = scan_tick && !init_pend && !ev_blk &&
                             (rc_state == ST_ESTAB) && !st_done[scan_id] &&
                             (rst_sent[scan_id] || st_grace);
    // ---- 配额归还 (超时/abort 收尾 与 ev_down 共用同一个表达式) ----
    // 为什么合并: `winq`/`pool` 是同一笔额度的两面。若"拆连归还"与 ev_down 的归还
    // 分两处写 pool, 同拍时后写者胜 ⇒ 另一笔信用凭空消失 (Σwinq + pool == WIN_POOL
    // 破缺 ⇒ 后续连接要么收不了数据, 要么能超发到物理缓冲之外)。to_fire 已含
    // !ev_blk ⇒ 两者结构性互斥, 同一个表达式在两条路径上都写同一个值 ✓
    // (ev_down 时 ret_slot_q = winq[ev_slot], 与 P5b 原式逐位一致 ⇒ 零行为变化)。
    wire [15:0] ret_slot_q = ev_down ? winq[ev_slot] : winq[scan_id];
    wire [17:0] p_sum_x    = {1'b0, pool} + {1'b0, ret_slot_q};
    wire [16:0] pool_ret_x = (p_sum_x > {1'b0, WIN_POOL}) ? {1'b0, WIN_POOL}
                                                        : p_sum_x[16:0];

    // ---- 事件脉冲转发 + 事件/命令写口 ----
    integer wi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= 4'd0; scan_id <= 4'd0; scan_round <= 32'd0;
            ev_ovf <= 1'b0; ev_pop <= 1'b0;
            o_ev_up <= 1'b0; o_ev_down <= 1'b0; o_ev_slot <= 4'd0;
            fin_req <= 16'h0; rst_req <= 16'h0;
            stat_ev_up <= 32'd0; stat_ev_down <= 32'd0; stat_ev_drop <= 32'd0;
            stat_cmd_close <= 32'd0; stat_cmd_abort <= 32'd0;
            stat_wu <= 32'd0; stat_pool_exhaust <= 32'd0; stat_fc_upd <= 32'd0;
            stat_slot_reuse <= 32'd0;
            pool <= {1'b0, WIN_POOL};
            fc_rr <= 4'd0; init_pend <= 1'b0; init_slot <= 4'd0;
            fc_v <= 1'b0; fc_id_r <= 4'd0; fc_val_r <= 32'd0;
            fc_sel_r <= 3'd3;                 // P5c-T3: 复位默认 = rcv_wnd 纠偏写
            fc_wait <= 32'd0; stat_fc_wait_max <= 32'd0;
            wu_zero <= 16'd0; wu_pend <= 16'd0; fc_pend <= 16'd0;
            // P5c-T3 G2/G3: 超时/state 写状态复位
            to_pend <= 16'd0; st_pend <= 16'd0; st_done <= 16'd0;
            to_fired <= 16'd0; to_pushed_r <= 1'b0;
            pa_v <= 1'b0; pa_sid <= 4'd0; pa_fq <= 17'd0; pa_redge_n <= 32'd0;
            pa_rwnd <= 16'd0; pa_state <= 4'd0;
            pb_v <= 1'b0; pb_sid <= 4'd0; pb_wscan <= 16'd0; pb_rwnd <= 16'd0;
            pb_state <= 4'd0;
            ev1_v <= 1'b0; ev1_slot <= 4'd0;
            for (wi = 0; wi < 16; wi = wi + 1) begin
                c_state[wi] <= 4'd0; c_snd_nxt[wi] <= 32'd0; c_snd_una[wi] <= 32'd0;
                c_rcv_nxt[wi] <= 32'd0; c_rcv_wnd[wi] <= 16'd0; c_snd_wnd[wi] <= 16'd0;
                redge[wi] <= 32'd0; winq[wi] <= 16'd0; wu_mark[wi] <= 16'd0;
                fc_wq[wi] <= 16'd0;
                fin_to[wi] <= 18'd0;          // P5c-T3 G2: 关闭超时计数
            end
        end else begin
            // 每拍默认清零 (脉冲型寄存器铁律)
            ev_pop    <= 1'b0;
            o_ev_up   <= 1'b0;
            o_ev_down <= 1'b0;
            tick_cnt  <= tick_cnt + 4'd1;
            ev1_v     <= ev_up || ev_down;     // 事件撞车跟踪 (下一拍的流水线让位)
            ev1_slot  <= ev_slot;
            // P0 流水线: item only lives one beat per stage — 拍 T 由扫描块置 1
            // (在文件里更靠后, 故同拍覆盖本默认值), 其余拍必须落 0, 否则 stage B/C
            // 会拿陈旧 pa_*/pb_* 每拍重放 (C15 补授/ fc / wu 会连拍狂发)。
            pa_v      <= 1'b0;

            // ---- C3/C10: init 拍 (ev_up 的下一拍) ----
            // 本拍 rc_id = init_slot ⇒ rc_* 是刚 cfg 完的新槽值 (rcv_nxt 等七字段
            // 已落地; ev_up 在 cfg 序列最后一个字段 wscale 的授权拍)。
            // **放在事件块之前**: 若同一拍又有 ev_up (背靠背 ADD), 由后面的事件块
            // 覆盖 init_pend/init_slot (= 重新武装给新槽), 顺序不能反。
            if (init_pend) begin
                // C14-②: init 拍的 redge 初始化**必须用 occ 修正** (与扫描同一
                // 公式) —— 不得只写 rcv_nxt + winq: 零拷贝占用在 ev_down 时不释放
                // (连接拆了 app 没读走的数据照样占槽), 同槽 DEL→ADD 时遗留占用
                // 会同新配额叠加 ⇒ occ(遗留) + 49152 > 65536 (遗留 > 16KB 即溢出)。
                // occ=0 时简并为 rcv_nxt + winq (C3 原式)。
                redge[init_slot]   <= redge_calc(winq[init_slot], rc_rcv_nxt,
                                                 rx_occ_bytes);
                // C10: wu_mark 取 winq (刚授予的配额), 不取采样的 rc_rcv_wnd —
                // init 后 TCB 值即 winq (下面 fc_pend 立即纠正), 两者一致, 且免去
                // 对采样值的时序依赖 ⇒ 连接刚建立不会多发一个 wu。
                wu_mark[init_slot] <= winq[init_slot];
                // 让 warr[] 组合值与本次 redge 自洽 (fc 纠偏写的值 = winq):
                // 否则 c_rcv_nxt 若还是旧会话/复位残留值, warr 会算出巨大窗口。
                c_rcv_nxt[init_slot] <= rc_rcv_nxt;
                wu_zero[init_slot]   <= 1'b0;
                // C17: wu_pend 也纳入 init 拍清洁 —— 旧会话残留的窗口更新请求
                // (wu_gnt 未回来就拆连) 不得落到新会话 (M1 类: 请求被吞/发错连接)
                wu_pend[init_slot]   <= 1'b0;
                // C10: **立即**纠偏 TCB.rcv_wnd — HLS ADD 序列 (slow_cfg_adp
                // tcb_idx=3) 把 rcv_wnd 写死 0xC000, 池耗尽时 winq[c] < 0xC000 ⇒
                // 通告窗口 > 实际配额 ⇒ 物理溢出。扫描纠正在 256 拍后才到, 而
                // 对端拿到 SYN+ACK 就可能开始发 ⇒ 不能等扫描。
                // 单连接 (winq=0xC000=原值) 时写与不写等价, 零行为差异。
                fc_pend[init_slot]   <= 1'b1;
                // 写值 = **该 init redge 蕴含的窗口** = redge_init - rc_rcv_nxt
                // = fq = max(0, winq - occ) (与上面 redge 同一函数, 同源自洽)。
                // occ=0 时 = winq ⇒ 与规格 C10 的字面值逐位相同 (单连接常态);
                // occ>0 时若写 winq 会通告 > redge 的右沿 ⇒ 下一次扫描的 fc 写
                // 变成"撤窗" (在飞数据被拒 ⇒ C16 病理) ⇒ 必须取空闲量。
                fc_wq[init_slot]     <= fq_calc(winq[init_slot], rx_occ_bytes);
                init_pend <= 1'b0;
            end

            // ---- 事件 (源脉冲) ----
            if (ev_up || ev_down) begin
                if (ev_full) stat_ev_drop <= stat_ev_drop + 32'd1;
                if (ev_up) begin
                    stat_ev_up <= stat_ev_up + 32'd1;
                    o_ev_up    <= 1'b1;
                    o_ev_slot  <= ev_slot;
                    fin_req[ev_slot] <= 1'b0;   // 新连接槽位清关闭/中止请求
                    rst_req[ev_slot] <= 1'b0;
                    // ---- C4/C14-①: 信用池授予 (预留物理占用) ----
                    // g = (pool > occ) ? min(WIN_Q_MAX, pool - occ) : 0
                    // 语义: 池与物理缓冲**共享同一笔额度** — 零拷贝占用不随
                    // ev_down 释放 (单帧 FIFO 服务所有连接), 故建立新连接时必须
                    // 从配额里扣掉当前占用量, 否则遗留占用与新配额叠加即溢出。
                    // 池 17 位 ⇒ g <= pool 恒成立, pool - g 不下溢。
                    // C18: 记池必须**先归还该槽旧配额** (pool_upd = pool - g + winq[slot],
                    // 封顶 WIN_POOL) —— 否则同槽二次 ev_up (无 ev_down) 会让旧配额蒸发
                    // (理由见 pool_reuse 注释)。单连接正常流程 winq[ev_slot]=0 ⇒ 与原式逐位相同。
                    winq[ev_slot] <= g_grant;
                    pool          <= pool_upd;
                    if (winq[ev_slot] != 16'd0)
                        stat_slot_reuse <= stat_slot_reuse + 32'd1;
                    if (g_grant < WIN_Q_MAX)
                        stat_pool_exhaust <= stat_pool_exhaust + 32'd1;
                    // ---- C3/C10: 一拍的 init (读新槽 TCB 值) ----
                    init_pend <= 1'b1;
                    init_slot <= ev_slot;
                    // 同槽重连 (D1 类): 旧会话的挂起位/零窗标志不得污染新会话
                    wu_pend[ev_slot] <= 1'b0;
                    wu_zero[ev_slot] <= 1'b0;
                    fc_pend[ev_slot] <= 1'b0;
                    // 撤掉可能正挂着的本槽 fc 请求 (陈旧写落进新会话 = 写错窗口)
                    if (fc_v && (fc_id_r == ev_slot)) fc_v <= 1'b0;
                    // ---- P5c-T3 G2/G3: 超时/state 写状态按事件脉冲清理 (坑 9) ----
                    // 新会话绝不继承旧会话的计数与"已触发"标记 (否则同槽重连会在
                    // 建连后立刻被上一会话的标记顶掉 state 写 / 或带着旧计数秒超时);
                    // st_pend 清 = 绝不对新会话写 state=0 (与 fc_pend 同源清理);
                    // to_pend 清 = 旧会话的超时 CONN_DOWN 不得记到新会话头上
                    // (app 会看到 UP 后紧跟一个属于旧会话的 DOWN)。
                    st_done[ev_slot]  <= 1'b0;
                    st_pend[ev_slot]  <= 1'b0;
                    to_pend[ev_slot]  <= 1'b0;
                    to_fired[ev_slot] <= 1'b0;
                    fin_to[ev_slot]   <= 18'd0;
                end else begin
                    stat_ev_down <= stat_ev_down + 32'd1;
                    o_ev_down    <= 1'b1;
                    o_ev_slot    <= ev_slot;
                    // CONN_DOWN: 清该连接的关闭/中止请求 (同时关闭不重复发 FIN)
                    fin_req[ev_slot] <= 1'b0;
                    rst_req[ev_slot] <= 1'b0;
                    // ---- C4: 配额归还 (饱和加, 封顶 WIN_POOL) ----
                    // winq 清 0 后归还量 = 0 ⇒ 重复 ev_down 天然不 double-free;
                    // 封顶只是防御 (池上界 = WIN_POOL 由构造保证)。
                    // 注意: 归还的是**配额**, 不是物理占用 (占用不释放 — 见 C14)。
                    // P5c-T3: 归还表达式 = pool_ret_x (与超时/abort 收尾同一个;
                    // ev_down 时两者逐位一致 ⇒ 行为不变, 但同拍双写变得不可能不一致)
                    pool          <= pool_ret_x;
                    winq[ev_slot] <= 16'd0;
                    // C1: redge **保持不变** (不要写 0)。写 0 在 rcv_nxt >= 2^31
                    // (约 50% 的对端 ISS) 会被序比较 sdelta = $signed(redge_n - 0)
                    // 判为"未来值"(负) 而永久留存 ⇒ W 恒 0 ⇒ 死锁。同槽重连由
                    // ev_up 的 init 拍重设, state != ESTAB 期间扫描不消费 redge。
                    wu_mark[ev_slot] <= 16'd0;
                    wu_zero[ev_slot] <= 1'b0;
                    wu_pend[ev_slot] <= 1'b0;
                    // C5 尾: 必须清 fc_pend[c] — 陈旧 fc 写会落在新会话 ADD 之后
                    // (同类事件型状态清理, 见 CLAUDE.md 坑 9)
                    fc_pend[ev_slot] <= 1'b0;
                    if (fc_v && (fc_id_r == ev_slot)) fc_v <= 1'b0;
                    // P5c-T3 G3: 同理清 st_pend/计数 (拆连后不得再对该槽写 state;
                    // 计数条件 state==ESTAB 已天然为假, 这里顺手归零保持不变量)
                    st_pend[ev_slot]  <= 1'b0;
                    to_pend[ev_slot]  <= 1'b0;
                    to_fired[ev_slot] <= 1'b0;
                    fin_to[ev_slot]   <= 18'd0;
                end
            end

            // ---- P5c-T3 G2: 超时 CONN_DOWN 事件投递 ----
            // 通道 = o_ev_down/o_ev_slot 脉冲 (app_pattern 消费的那一对; 选择理由
            // 见文件头)。to_push 定义里已排除 ev_up/ev_down 同拍 ⇒ o_ev_slot 不会
            // 出现"外部脉冲 + 超时槽号"错配; 未投递的位留在 to_pend 里下拍再投
            // (顺延不丢; 与外部事件块的 o_ev_* 赋值在寄存器上互斥 ⇒ 无竞争)。
            to_pushed_r <= to_push;      // 脉冲隔离 (见 to_push 注释)
            if (to_push) begin
                o_ev_down          <= 1'b1;
                o_ev_slot          <= to_slot_w;
                to_pend[to_slot_w] <= 1'b0;
                stat_ev_down       <= stat_ev_down + 32'd1;   // 0x91 / 状态行可观测
            end

            // ---- 轮扫 拍 T: 采样该连接 TCB 状态 + 锁存流水 item ----
            // C10: init_pend 与 scan_tick 同拍时必须**暂停一次采样** (该拍 rc_id
            // 指向 init_slot, 采进 c_*[scan_id] 就是快照污染), scan_id 亦不推进
            // (扫描周期少 1 拍无害)。
            // C17: ev_up/ev_down 落在同槽扫描拍时扫描**让位** —— 否则本块 (更靠后)
            // 会覆盖事件块的清理/授权 (旧版: winq 走增量补授而非 C14-① 的授予预留,
            // wu_zero 被清 0 覆盖等)。ev_down 本可依赖 `state != ESTAB` 天然为假,
            // 但 redge 更新/位图清理并不看 state, 故一并让位 (跳过一拍采样无害)。
            if (scan_tick && !init_pend && !(ev_blk && (ev_slot == scan_id))) begin
                scan_id <= scan_id + 4'd1;
                if (scan_id == 4'd15) scan_round <= scan_round + 32'd1;
                c_state  [scan_id] <= rc_state;
                c_snd_nxt[scan_id] <= rc_snd_nxt;
                c_snd_una[scan_id] <= rc_snd_una;
                c_rcv_nxt[scan_id] <= rc_rcv_nxt;
                c_rcv_wnd[scan_id] <= rc_rcv_wnd;
                c_snd_wnd[scan_id] <= rc_snd_wnd;
                // 连接已不在 ESTAB: 清关闭/中止请求 (拆连后自愈; 同槽重连可再用)
                if (rc_state != ST_ESTAB) begin
                    fin_req[scan_id] <= 1'b0;
                    rst_req[scan_id] <= 1'b0;
                end
                // 锁存流水 item (拍 T+1 只用这些寄存值 ⇒ 组合深度 1 级)
                pa_v       <= 1'b1;
                pa_sid     <= scan_id;
                pa_fq      <= fq_scan;
                pa_redge_n <= redge_n;
                pa_rwnd    <= rc_rcv_wnd;
                pa_state   <= rc_state;
                // ---- P5c-T3 G2 + P5c 活性判据: 关闭超时计数 (本槽"FIN 已发、仍
                //      ESTAB 且**无进展**"的连续扫描轮数; 饱和到
                //      fin_to_max = FIN_TO_LIM + FIN_GRACE) ----
                // 单位 = 该槽被扫描到的轮次 (256 拍/轮, 见 FIN_TO_LIM 换算)。
                // 计数归零: ① 条件不成立 (未到点就拆连/state 变化) 即清, 不跨会话
                // 累积; ② **对端有进展 (act_now) 即清零重新计时** (P5c 活性判据:
                // 见文件头 — 半关闭时对端合法地继续发数据, 不得被判死连接);
                // ev_up/ev_down 脉冲另行清零 (坑 9, 同槽重连不继承)。
                // act_now 的清除只在 !to_fired 时生效: 触发后该槽已进入拆除流程
                // (配额已归还/流控已清), 不能在数据到达时"复活"; 且计数必须继续
                // 走向 fin_to_max 以驱动 st_grace 兜底 (F2) ⇒ 触发后 act_now 走
                // 下面的饱和加分支 (不是清零分支)。
                if (fin_sent[scan_id] && (rc_state == ST_ESTAB)) begin
                    if (act_now && !to_fired[scan_id])
                        fin_to[scan_id] <= 18'd0;      // 对端活跃 ⇒ 重新计时
                    else if (fin_to[scan_id] < fin_to_max)
                        fin_to[scan_id] <= fin_to[scan_id] + 18'd1;
                    // ---- 到点触发 (to_fire: 含"非事件拍"守卫, 见组合判据声明) ----
                    // 只做两件事: ① abort 请求 (RST 由 tcp_tx_frame 扫描排队) ② 事件。
                    // **state=0 写不在这里发** (审查 F2): 若同拍挂出, 它 ~3 拍就落地
                    // 而 RST 要等 tcp_tx_frame 的下次扫描 ⇒ state 先变非 ESTAB ⇒
                    // rst_push 的门 (rb_state==1) 永久为假 ⇒ RST 结构性发不出去。
                    // 现在 state 写改由 st_req_now (rst_sent 上升 或 宽限到点) 挂出。
                    if (to_fire) begin
                        rst_req[scan_id] <= 1'b1;      // ① abort 该连接 (发 RST)
                        to_pend[scan_id] <= 1'b1;      // ② CONN_DOWN 事件 (下拍投递)
                        to_fired[scan_id] <= 1'b1;     // 只触发一次
                        // ③ 归还配额 + 清该槽流控状态 (等价 ev_down 的归还部分):
                        //    连接已被 fast path 判定拆除。不归还则池被死连接永久占住
                        //    ⇒ 后续新连接 winq=0 ⇒ 通告窗 0 ⇒ 收不了任何数据
                        //    (审查实测 R6) —— G2 想治的"再也建不了连"会换一种形式复活。
                        //    winq 清 0 后, 该槽日后真收到 HLS 的 DEL (ev_down) 时归还量
                        //    为 0 ⇒ 天然不 double-free (与 C4 的饱和加同构)。
                        //    物理占用不受影响 (归还的是**配额**; occ 由 C14-① 的授予
                        //    公式另行扣除) ⇒ 不越物理界。
                        pool           <= pool_ret_x;
                        winq[scan_id]  <= 16'd0;
                        wu_pend[scan_id] <= 1'b0;
                        wu_zero[scan_id] <= 1'b0;
                        wu_mark[scan_id] <= 16'd0;
                        fc_pend[scan_id] <= 1'b0;
                        // C15 补授同步闭嘴 (否则下几轮会把刚归还的配额又授给这个
                        // 正在拆除的槽 ⇒ 归还白做): 见 T+2 块的 !to_fired 守卫。
                    end
                end else begin
                    fin_to[scan_id] <= 18'd0;
                end
                // ---- P5c-T3 G3: state=0 写请求 (st_req_now, 只挂一次) ----
                // 两个来源: a) rst_sent[scan_id] (RST 确实发出 = abort 完成 / 超时的
                // 正常时序: RST 先发, 再拆 state — 顺序与协议一致) b) 宽限到点仍发不出
                // RST (ackq 长期满 / 已非 ESTAB 边界) ⇒ 兜底, 保证槽一定被拆。
                // st_req_now 里已带 rc_state==ESTAB (只对还站着的连接收尾) 与
                // !st_done (同槽只写一次; rst_sent 会保持到 tcp_tx_frame 扫描/cfg_up
                // 清, 无守卫会每轮重发写)。
                // 同时归还配额 (与超时路径共用 pool_ret_x; 两者结构性互斥: st_req_now 的
                // 兜底支要求 to_fired, 而 to_fire 拍不重叠; rst_sent 支与 to_fire 可分属
                // 不同轮次 —— 若同拍发生则两次 pool 赋值同值, 见 pool_ret_x 注释)。
                if (st_req_now) begin
                    st_pend[scan_id] <= 1'b1;
                    st_done[scan_id] <= 1'b1;
                    pool             <= pool_ret_x;
                    winq[scan_id]    <= 16'd0;
                    // 该槽正在拆除: 挂着的窗口纠偏与窗口更新 ACK 请求一并作废
                    // (对死连接写窗口/发重开 ACK 都是噪声; 与 ev_down 的清理同源)
                    fc_pend[scan_id] <= 1'b0;
                    wu_pend[scan_id] <= 1'b0;
                    wu_zero[scan_id] <= 1'b0;
                    wu_mark[scan_id] <= 16'd0;
                end
            end

            // ---- 轮扫 拍 T+1: 单调判据 (C1) + wscan 落定 ----
            // 单调: 只抬高 (TCP 序比较, 4GB seq 回绕安全 — 不用 redge_n > redge[c])
            if (pa_v) begin
                // item 已消费: 拍 T+1 之后 pa_v 由上方默认值落 0 (只活一拍)
                if (upd_b && !hit_b) redge[pa_sid] <= pa_redge_n;
                pb_v     <= !hit_b;
                pb_sid   <= pa_sid;
                // wscan = fq[15:0] (等价性证明见文件头: wcalc(redge_n, rn) ≡ fq,
                // 且 redge_upd=0 时两式同样相等 ⇒ 与旧式逐位等价)
                pb_wscan <= pa_fq[15:0];
                pb_rwnd  <= pa_rwnd;
                pb_state <= pa_state;
            end else begin
                pb_v     <= 1'b0;
            end

            // ---- 轮扫 拍 T+2: 窗口判据 (fc / C6 wu / C15 增量授权) ----
            if (pb_v && !hit_c) begin
                // ---- C15-②: 增量授权 (池回收后自愈, 不会永久零窗) ----
                // 并发建连时 WIN_Q_MAX=WIN_POOL ⇒ 后续连接 winq=0 (单 64KB FIFO
                // 服务 N 条连接, Σwinq <= WIN_POOL 是物理约束); 池里有余额就补授,
                // 否则该连接永久零窗。补授只抬高 winq ⇒ redge 单调 ✓ 安全。
                // P5c-T3 G2/G3: 追加 !st_done[pb_sid] && !to_fired[pb_sid] —— 正在
                // 拆除的槽 (超时触发/已挂 state 写) 不得把已归还给池的配额再领
                // 回去, 否则归还白做 (池仍被死连接占住)。两个标志都由 ev_up/ev_down
                // 事件脉冲清 ⇒ 同槽重连/真 DEL 之后正常补授 (坑 9)。
                // P5c-T3 R8 (审查 agent 确定性复现的**预存** P5b 缺陷, 顺手闭合):
                // 加 !ev_blk —— 本拍若同时有 ev_up, 事件块 (更靠前) 的 C18 会按**同一个
                // 旧池余额**再授一份 (pool 只减一份) ⇒ Σwinq 越过 WIN_POOL (实测 2x),
                // 后果是"授予总量 + occ" 可超 64KB 物理缓冲 (C4/C15 想守的那条界)。
                // 事件 1 拍脉冲且稀疏 ⇒ 该拍不授、下一次扫描访到该槽再授, 零代价。
                if ((pb_state == ST_ESTAB) && (winq[pb_sid] < WIN_Q_MAX) &&
                    (pool != 17'd0) && !ev_blk &&
                    !st_done[pb_sid] && !to_fired[pb_sid]) begin
                    winq[pb_sid] <= winq[pb_sid] + inc_grant[15:0];
                    // **必须同时扣池**: 只加 winq 不扣 pool 会让 Σwinq > WIN_POOL
                    // (定向门 T5c 实测抓到: winq 补到 C000 而 pool 仍 C000 ⇒ 池
                    //  可被反复超发, 物理缓冲失去信用约束)
                    pool <= pool - inc_grant;
                end
                // fc 判据: 通告窗口与"应然值"不一致 ⇒ 请求纠偏写
                // (判据 pb_wscan 与写值 fc_wq 同源自洽 — C5 强制)
                if ((pb_state == ST_ESTAB) && (pb_wscan != pb_rwnd)) begin
                    fc_pend[pb_sid] <= 1'b1;
                    fc_wq  [pb_sid] <= pb_wscan;
                end
                // ---- C6: 窗口重开通知 (只在"对端可能停等"时发, 零额外帧前提) ----
                if (pb_state == ST_ESTAB) begin
                    if (pb_wscan == 16'd0) begin
                        wu_zero[pb_sid] <= 1'b1;     // 窗关: 对端即将/已经停等
                    end else if (wu_zero[pb_sid] ||
                                 ({1'b0, pb_wscan} >= {1'b0, wu_mark[pb_sid]} +
                                                      {1'b0, WU_STEP})) begin
                        wu_pend[pb_sid] <= 1'b1;     // 电平请求 (等 wu_gnt)
                        wu_mark[pb_sid] <= pb_wscan;
                        wu_zero[pb_sid] <= 1'b0;
                    end
                end
            end

            // ---- C5: fc 应答 (清请求位 + 请求寄存器出空 + round-robin 推进) ----
            // 清位与写口用**同一个 fc_id_r** (写的连接 == 清的位, 永不错位)
            if (fc_gnt) begin
                fc_pend[fc_id_r] <= 1'b0;
                // P5c-T3 G3 (审查 F3 修正): st_pend **只能在本次落地确实是 state 写
                // (fc_sel_r==5) 时清** —— 否则一次窗口写 (sel=3) 的 gnt 会把同槽挂着的
                // state 写请求一起吞掉, 而 st_done 已锁 (只 ev_up/ev_down 清) ⇒
                // state=0 写永久丢失 ⇒ 槽永不释放 + 该连接永久发不出数据。
                // 这正是规格 §4"清除条件必须与'确实落地'等价"(M1/W2 同一个坑);
                // 未落地时保留位 ⇒ 下一轮 round-robin 重新选中它并重发 (自动重试)。
                // 反向 (state 写落地时连 fc_pend 一起清) 是**有意**的: 该槽正在拆除,
                // 窗口纠偏已无意义 (见文件头 G3 互斥说明)。
                if (fc_sel_r == 3'd5) st_pend[fc_id_r] <= 1'b0;
                fc_v             <= 1'b0;
                fc_rr            <= fc_id_r + 4'd1;   // 推进条件 = fc_gnt (不是每拍)
                // stat_fc_upd 语义扩展: 计数 = "经 fc 通道落地的 TCB 写" (含
                // rcv_wnd 纠偏写与 state 写) — P5b 门判据是 "> 0 且活" ⇒ 不受影响
                stat_fc_upd      <= stat_fc_upd + 32'd1;
            end else if (fc_load) begin
                // 装载组合选择 (此后 id/val/sel 冻结到 gnt; val = 按 fc_id 从采样
                // 数组选的窗口 — 见 fc_val_new 注释)
                fc_v     <= 1'b1;
                fc_id_r  <= fc_sel5[3:0];
                fc_val_r <= fc_val_new;
                fc_sel_r <= fc_sel_new;   // 3 = rcv_wnd 纠偏 / 5 = state (T3)
            end
            // ---- P5b 活性观测: fc 请求连续挂起拍数 (含本拍) ----
            if (fc_v) begin
                if (fc_wait != 32'hFFFFFFFF) fc_wait <= fc_wait + 32'd1;
                if ((fc_wait + 32'd1) > stat_fc_wait_max)
                    stat_fc_wait_max <= fc_wait + 32'd1;
            end else begin
                fc_wait <= 32'd0;
            end
            // ---- C6/C7: wu 应答 (条目确实入队才清; 被更高优先级抢 ⇒ 保持电平) ----
            if (wu_gnt) begin
                wu_pend[wu_id] <= 1'b0;
                stat_wu        <= stat_wu + 32'd1;
            end

            // ---- CMD 写 (0x06): {cmd[3:0], id[3:0]} ----
            if (reg_wr && reg_addr == 8'h06) begin
                case (reg_wdata[7:4])
                    4'd1: begin fin_req[reg_wdata[3:0]] <= 1'b1;
                               stat_cmd_close <= stat_cmd_close + 32'd1; end
                    4'd2: begin rst_req[reg_wdata[3:0]] <= 1'b1;
                               stat_cmd_abort <= stat_cmd_abort + 32'd1; end
                    default: ;
                endcase
            end

            // ---- app_pattern 关闭请求 (等价 CMD close) ----
            if (close_req) begin
                fin_req[close_id] <= 1'b1;
                stat_cmd_close <= stat_cmd_close + 32'd1;
            end

            // ---- 事件弹出 (0x05 写) ----
            if (reg_wr && reg_addr == 8'h05) ev_pop <= 1'b1;
            if ((ev_up || ev_down) && ev_full) ev_ovf <= 1'b1;
        end
    end

endmodule
