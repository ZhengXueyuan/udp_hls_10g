`timescale 1ns/1ps
// TCP RX: 段解析 (w0..w6) + CAM 4 元组匹配 + seq==rcv_nxt 顺序流检查 + 载荷直出 (6 字节偏移)
// + 每数据段 ACK 请求 + TCB 更新 (rcv_nxt/snd_una/snd_wnd, drain 排序一字段一拍)。
//
// 字节布局 (帧首 = tdata[63:56], 无 VLAN, TCP 头 20B, 载荷偏移 = 54 字节 = 6 整字 + 6 字节):
//   w4 = dst_ip[15:0]+src_port+dst_port+seq[31:16]
//   w5 = seq[15:0]+ack[31:0]+data_off/reserved+flags
//   w6 = window+tcp_csum+urg+载荷[0..1]
// 载荷流 = 源字流偏移 6 字节: 输出字 = {上一源字低 2 字节, 当前源字高 6 字节}。
//
// P3 范围 (握手/重传/RTO 归 P4 慢路径): 仅 ESTABLISHED 数据段; 顺序流假设
// 只接受 seg.seq == rcv_nxt; 乱序/重复 (窗口内) 丢数据仍回 ACK (快速重传依赖);
// 窗口外丢段不回 ACK; SYN/FIN/RST/带选项段丢弃 (P4 处理); 纯 ACK 段只更新
// snd_una/snd_wnd, 绝不回 ACK (防 ACK 环)。TCP 校验和 cut-through 无法验证, 不查。
// 填充帧: pop8(TLAST) 允许 > 剩余载荷 (60B 最小帧填充), 多余字节按填充忽略。
// 坏 FCS 段: 载荷照发 (tuser[0]=0 标记) 但不回 ACK、不推进 rcv_nxt (对端重传)。
module tcp_rx #(
    // P5b C16-修订: **接受界对通告界的裕度** (字节)。
    // 通告窗 W = max(0, winq - occ) 是"我还能收多少"; 但对端在收到新窗口之前是按
    // **旧窗口**发的, 其右沿 = redge + Δ (Δ = 通告滞后, 见规格 C1b) ⇒ 接受判据
    // 必须预留 Δ, 否则"按旧窗合法发出的零头段"落地时窗已塌陷 ⇒ 顺序段被拒
    // (只回 ACK 靠重传 = 活性问题; 更早的静默丢弃 = 200ms RTO)。
    // 默认 0 ⇒ 接受界 == ra_rcv_wnd, 默认构建逐位不变。
    // APP_MODE 由 wrapper 传 4096: occ + W + 4096 <= 49152 + 4096 = 53248,
    // 再加未判定帧 U(<=1518) = 54766 < 65536 ✓ 余量 ~10.7KB (不会物理溢出)。
    parameter [15:0] ACC_MARGIN = 16'd0
) (
    input  wire        clk,
    input  wire        rst_n,
    // 来自 mac_rx_64
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,   // SOP
    input  wire        s_axis_tcrs,    // TLAST: FCS 正确
    input  wire        s_axis_terr,    // TLAST: 帧内 rx_er
    // 配置: echo 应用场景置 1 — 被接受的顺序数据段不再发纯 ACK (echo 帧自带
    // ACK 位+ack 号, 纯 ACK 冗余)。板测实锤: 每段 2 帧使 TX 比 RX 慢 16%
    // (536B 段) → echo fifo 持续净流入 → 溢出丢段 → 对端重传雪崩 (1.5Mbps)。
    // dup/ooo (drop_ack) 路径不受此门控 (快速重传依赖), 纯 ACK 本就不回。
    input  wire        cfg_suppress_data_ack,
    // 载荷直出 (左对齐; meta_valid 指示帧首)
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire [1:0]  m_axis_tuser,   // [0]=crc_ok [1]=err (TLAST 拍)
    output wire        fend,           // 接受帧完成脉冲 (载荷 TLAST 拍 / 纯 ACK 帧尾拍)
    output wire        ferr,           // fend 拍有效: 帧坏 (FCS 错或 rx_er)
    // 每帧元数据 (meta_valid 脉冲 = w6 接受拍, 即载荷首拍前)
    output wire        meta_valid,
    output wire [31:0] meta_src_ip,
    output wire [15:0] meta_src_port,
    output wire [15:0] meta_len,       // 载荷字节数 = IP total_len - 40
    output wire [3:0]  meta_conn_id,
    output wire [31:0] meta_seq,
    // TCB 读口 A (顶层实例化 tcb 并连线; 本模块仅 w5 拍组合判读)
    output wire [3:0]  ra_id,
    input  wire [31:0] ra_rcv_nxt,
    input  wire [31:0] ra_snd_nxt,
    input  wire [31:0] ra_snd_una,
    input  wire [15:0] ra_rcv_wnd,
    input  wire [3:0]  ra_state,
    input  wire [3:0]  ra_wscale,   // 对端 window scale (snd_wnd drain 缩放用)
    // P4d-fix: tx 侧重传会话高水位 (来自 tcp_tx_frame o_retx_*; ack_ok 上界)
    input  wire [31:0] ra_retx_hi,
    input  wire        ra_retx_active,
    // TCB 更新 (fend 后 drain: 拍1 rcv_nxt, 拍2 snd_una, 拍3 snd_wnd;
    // 组合电平输出, upd_gnt 未给则保持该字段 — 顶层仲裁必须无损 (tx 优先时 rx 靠 gnt 顺延)。
    // P4b-7-P6 ROOT CAUSE #2 修复: pend 标志 sticky — fend 只置位不覆盖, drain 在
    // 写被 gnt 时逐字段清除。旧实现每 fend 重锁存 (非推进帧的 fend — 重复纯 ACK
    // 突发 / 坏 FCS 帧 — 把未写出的推进 pend_una/pend_rcv 重锁成 0 → snd_una/
    // rcv_nxt 永久停滞 → 在飞涨到 RING_CAP → 窗门误关 → 死锁)。值寄存器只在
    // 对应条件成立时更新 (否则挂起推进值被重复帧的旧 ack/旧窗口覆盖)。
    // pend_id 假设: 三个 pend 同一连接 (单连接数据面; 多连接需逐字段 pend_id)。
    output wire        upd_wr,
    output wire [3:0]  upd_id,
    output wire [2:0]  upd_sel,
    output wire [31:0] upd_val,
    input  wire        upd_gnt,
    // ACK 请求 (TX 侧消费: 发无载荷 ACK 段, ack 号 = ack_val)
    output wire        ack_req,
    output wire [3:0]  ack_id,
    output wire [31:0] ack_val,
    // dup-ACK 快速重传请求 (P3): 3 个 dup-ACK 检出置位, 电平保持至 tcp_tx_frame
    // 的 retx_gnt; in_retx 屏蔽会话内重复计数, 真推进 ACK 也解锁
    output reg         retx_req,
    output reg  [3:0]  retx_id,
    input  wire        retx_gnt,
    // SYN sideband (P4-lite 握手用): 纯 SYN 段帧尾脉冲 (FCS 好才发), 字段全锁存
    output reg         syn_v,
    output wire [47:0] syn_smac,
    output wire [31:0] syn_sip,
    output wire [15:0] syn_sport,
    output wire [15:0] syn_dport,
    output wire [31:0] syn_seq,
    output wire [15:0] syn_wnd,
    // CAM 查询 (外部 tcp_cam 实例, 与 TX 读回共享同一份连接表;
    // q_* 组合输出在 w4 拍有效, q_hit/q_id 同拍返回)
    output wire [31:0] cam_q_sip,
    output wire [31:0] cam_q_dip,
    output wire [15:0] cam_q_sport,
    output wire [15:0] cam_q_dport,
    input  wire        cam_q_hit,
    input  wire [3:0]  cam_q_id,
    // 统计
    output reg  [31:0] stat_pass,          // 接受且 FCS 好 (含纯 ACK)
    output reg  [31:0] stat_drop_nonmatch, // 头坏/非 TCP/CAM 未命中/状态/标志/带选项/窗口外
    output reg  [31:0] stat_drop_trunc,    // P4b-7-P6: 截断帧 (线上 tlast 早于承诺载荷) — 修复后按真实字节收下转发
    output reg  [31:0] stat_drop_ipcsum,   // IP 头校验和错
    output reg  [31:0] stat_drop_crc,      // 接受但 FCS 坏 (载荷交付, 不回 ACK)
    output reg  [31:0] stat_drop_seq,      // 窗口内 seq 不符 (重复/乱序): 丢数据仍回 ACK
    output reg  [31:0] stat_ack,           // ACK 请求数
    output reg  [31:0] stat_bytes,         // 接受且 FCS 好的载荷字节
    // P4b-7-P6 诊断 (UART RX 侧快照, 纯 assign): FSM 位点 + 接受/发射状态
    output wire [2:0]  dbg_state,          // FSM state (S_HDR/S_PAY/S_PAD/S_DROP/S_TAIL)
    output wire        dbg_accept,         // 接受拍 = s_axis_tvalid && s_axis_tready
    output wire        dbg_emitv,          // emit_v (载荷输出字挂起)
    // P4b-7-P6 追加 (UART 行尾 RXPL/RXPC/RXT/DROPS/PASS, 纯 assign 零逻辑):
    //   plen_l = IP total_len-40 的锁存 (帧判读依据; 腐败则 over-length 守卫
    //   S_DROP 中段断尾 → TX 侧永久等 tlast), pcount = 帧内已累计载荷字,
    //   w2_tlen = w2_r[63:48] 原始 total_len 字段 (plen_l 的上游真值) + 五路
    //   丢弃/通过计数 (冻结期逐行对比: 哪一路在递增 = 哪条判据在持续触发)
    output wire [15:0] dbg_plen_l,
    output wire [15:0] dbg_pcount,
    output wire [15:0] dbg_w2_tlen,
    output wire [31:0] dbg_stat_drop_seq,
    output wire [31:0] dbg_stat_drop_crc,
    output wire [31:0] dbg_stat_drop_nonmatch,
    output wire [31:0] dbg_stat_drop_ipcsum,
    output wire [31:0] dbg_stat_drop_trunc,   // P4b-7-P6: 截断帧计数 (DROPS 第 5 字段)
    output wire [31:0] dbg_stat_pass,
    // P4b-7-P6 RX emit 轨迹 (UART RXT 行; 纯 assign 零逻辑):
    //   emit_l  = m_axis_tlast (尾字 emit 是否带帧尾 — 帧边界是否发出)
    //   pay_r   = plen_l - pcount (TLAST 拍剩余载荷字节 = 尾分支判据)
    //   pcount2 = pcount 别名 (RXT 环专用连线; 与 dbg_pcount 同寄存器同值,
    //             dbg_pcount 已被 UART 快照行 RXPC 占用, 分开走线免串扰)
    //   fend    = 接受帧完成脉冲 (RXT 环触发源: fend 拍 pcount 落后 plen_l
    //             超 4 字节 = 尾分支误走/帧尾丢失)
    output wire        dbg_emit_l,
    output wire [15:0] dbg_pay_r,
    output wire [15:0] dbg_pcount2,
    output wire        dbg_fend,
    // P4b-7-P6 三站词计数 (第 2 站, UART 行尾 RW 字段): dbg_stat_words_in =
    //   本模块接受的 s_axis 字计数 (accept = tvalid && tready, 含全部头字与
    //   载荷字, 每拍至多 1)。与上游 MW (mac_rx_64 出词) / CW (rx_classify
    //   进/出词) 对账: 三站差额直接裁决丢词发生在哪一级。
    // dbg_wcnt = 头字计数器 wcnt (RXT 轨迹条目 [26:24]): 帧头判读是否错拍
    //   (= w2_r 锁存到旧帧长度字段的假设) 由轨迹逐拍裁决。
    output wire [31:0] dbg_stat_words_in,
    output wire [2:0]  dbg_wcnt
);

    localparam [2:0] S_HDR = 3'd0, S_PAY = 3'd1, S_PAD = 3'd2, S_DROP = 3'd3, S_TAIL = 3'd4;
    localparam [3:0] ESTAB = 4'd1;   // tcb state: 1 = ESTABLISHED (P4 加握手态)

    reg  [2:0]  state;
    reg  [2:0]  wcnt;
    reg  [15:0] w1_lo, w3_r;             // w3_r[15:0] = dst_ip[31:16]
    reg  [63:0] w2_r;                    // 必须 64 位 (IP 校验和树读全部 4 半字)
    reg  [19:0] ipc_s9;
    reg  [15:0] mac_lo;                  // src_mac[47:32] (SYN 应答要用对端 MAC)
    reg  [31:0] mac_hi;                  // src_mac[31:0]
    reg  [31:0] src_ip_r;
    reg  [15:0] src_port_r, seq_hi_r, dport_r;
    reg         syn_l, drop_syn_r;
    reg  [15:0] syn_wnd_r;
    reg         cam_hit_l;
    reg  [3:0]  conn_id_l;
    // w5 拍判读锁存 (w5->w6 沿)
    reg         acc_l, ackresp_l, ack_adv_l;
    reg         w6a_ok_l;               // P4c: 窗口内非边界纯 ACK (w5 锁存)
    reg  [31:0] ack32_l, seq32_l, rcv_nxt_l;
    reg  [15:0] plen_l;                  // 载荷字节数 = IP total_len - 40
    reg  [15:0] wnd_l;                   // w6 拍锁存对端窗口
    reg         drop_ack;
    reg  [15:0] hold16;                  // 上一源字低 2 字节 (载荷字节 8j..8j+1)
    reg  [15:0] pcount;
    reg         emit_v;
    reg  [63:0] emit_d;
    reg  [7:0]  emit_k;
    reg         emit_l;
    reg  [1:0]  emit_u;
    reg         tail_stage;
    reg  [63:0] tail_d;
    reg  [7:0]  tail_k;
    reg  [1:0]  tail_u;
    // fend 后 TCB 更新 pend + drain FSM
    reg         pend_rcv, pend_una, pend_wnd;
    reg  [3:0]  pend_id;
    reg  [31:0] pend_rcv_val, pend_una_val;
    reg  [15:0] pend_wnd_val;
    reg  [1:0]  drn;
    // P4b-7-P6 三站词计数 (第 2 站): 接受的 s_axis 字 (accept 拍, 含头字)
    reg  [31:0] words_in;
    // P3 dup-ACK 检测: dup_l = w5 拍判出"纯 ACK 且 ack==snd_una"(w5->w6 沿锁存);
    // dup_cnt 每连接 2 位计数, in_retx 位屏蔽已请求连接
    reg         dup_l;
    reg  [1:0]  dup_cnt [0:15];
    reg  [15:0] in_retx;
    integer     di;

    wire        accept = s_axis_tvalid && s_axis_tready;

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

    // 1..2 字节窗口左对齐 (短载荷尾字 / 溢出尾字共用)
    function [63:0] ljust2;
        input [15:0] w;
        input [2:0]  p;
        begin
            case (p)
                3'd1: ljust2 = {w[15:8], 56'b0};
                default: ljust2 = {w[15:0], 48'b0};
            endcase
        end
    endfunction

    function [15:0] fold16x;
        input [19:0] v;
        reg [16:0] f1;
        begin
            f1 = v[15:0] + {12'b0, v[19:16]};
            fold16x = f1[15:0] + {15'b0, f1[16]};
        end
    endfunction

    // IP 头校验和: 同 udp_rx (proto 字节不同, 校验和覆盖同样 20 字节)
    wire [19:0] ipc_sum9 = {4'b0, w1_lo} + {4'b0, w2_r[15:0]} + {4'b0, w2_r[31:16]} +
                           {4'b0, w2_r[47:32]} + {4'b0, w2_r[63:48]} +
                           {4'b0, s_axis_tdata[15:0]} + {4'b0, s_axis_tdata[31:16]} +
                           {4'b0, s_axis_tdata[47:32]} + {4'b0, s_axis_tdata[63:48]};
    wire [19:0] ipc_sum10 = ipc_s9 + {4'b0, s_axis_tdata[63:48]};
    wire        ipcsum_ok = (fold16x(ipc_sum10) == 16'hFFFF);
    wire        hdr_ok1   = (wcnt == 3'd1) && (s_axis_tdata[31:16] == 16'h0800) &&
                            (s_axis_tdata[15:8] == 8'h45);
    wire        hdr_ok2   = (wcnt == 3'd2) && (s_axis_tdata[7:0] == 8'h06);

    // ---- w5 拍判读 (组合, 寄存器 ra_id 提供 TCB 读) ----
    assign ra_id = conn_id_l;
    wire [31:0] seq32    = {seq_hi_r, s_axis_tdata[63:48]};   // seq[15:0] = 字节 40..41
    wire [31:0] ack32    = s_axis_tdata[47:16];               // ack[31:0] = 字节 42..45
    wire [7:0]  flags    = s_axis_tdata[7:0];
    wire        flags_ok = flags[4] && !flags[2] && !flags[1] && !flags[0];  // ACK 置, RST/SYN/FIN 清
    wire        doff_ok  = (s_axis_tdata[15:12] == 4'd5);
    wire        state_ok = (ra_state == ESTAB);
    wire        len_ok   = (w2_r[63:48] >= 16'd40);
    wire [31:0] seq_diff = seq32 - ra_rcv_nxt;
    // P5b C16-修订: 接受界 = 通告界 + ACC_MARGIN (位宽扩展防 16 位回绕)。
    // 默认构建 ACC_MARGIN=0 ⇒ acc_wnd = {1'b0,ra_rcv_wnd} ⇒ 与旧判据逐位等价
    // (多了 1 位零扩展, 数值不变)。
    wire [16:0] acc_wnd  = {1'b0, ra_rcv_wnd} + {1'b0, ACC_MARGIN};
    wire        win_ok   = (seq_diff < acc_wnd);
    wire        seq_eq   = (seq32 == ra_rcv_nxt);
    wire        seq_lt   = (seq32 < ra_rcv_nxt);   // 重复/旧段 (回绕安全: 无符号比较)
    // P4d-fix: 回卷会话期间 ACK 上界 = 高水位 retx_hi (回卷前 snd_nxt = 真正发送
    // 过的字节)。回卷把 snd_nxt 降到 snd_una, 若仍用 snd_nxt 判上界, 对端"确认
    // 已到达数据"的合法 ACK (ack > 回卷后 snd_nxt) 被拒 —— TCP 不重传 ACK,
    // snd_una 永久冻结, in-flight 恒 = 满窗 → 窗口门永关 → 死锁 (板级实证: 48KB
    // 窗 + RTO 重放 35 帧, PC ack=高水位 落在重放期被拒, 板侧 seq 永不前进)。
    // 会话期 retx_hi >= snd_nxt 恒成立 (回卷只降 snd_nxt, 重放最多推回 retx_hi),
    // 故直接用 retx_hi 即可, 无需比较; 会话结束 retx_active=0 自动回 snd_nxt 语义。
    // 语义自检: ①会话中 ack ∈ [snd_una, retx_hi] 都接受 — 这些字节确实发送过;
    // ②会话中 ack 超过 retx_hi 仍拒 (防接受未发送数据的 ACK); ③接受 ack =
    // retx_hi 时 snd_una 可能暂时 > 当前 snd_nxt (重放未完) — in-flight 回绕为
    // 大数、窗口门保持关 (无害: 重放帧走 ring 绕过门), 重放推进到 retx_hi 后
    // in-flight = 0; 期间若 RTO 再触发, svc 回卷 snd_nxt := snd_una (= 高水位,
    // 前跳) 且 ring_delta = 0 → 会话立即收敛结束, 剩余重放帧已被 ACK 确认 →
    // 语义正确。
    wire [31:0] ack_hi   = ra_retx_active ? ra_retx_hi : ra_snd_nxt;
    wire        ack_ok   = ((ack32 - ra_snd_una) <= (ack_hi - ra_snd_una));
    wire        ack_adv  = ack_ok && (ack32 != ra_snd_una);
    wire [15:0] plen_w   = w2_r[63:48] - 16'd40;
    wire        frag_ok  = (w2_r[29:16] == 14'h0);   // MF=0 且片偏移=0 (分片段丢给 P4)
    wire        base_ok  = cam_hit_l && state_ok && flags_ok && doff_ok && len_ok &&
                           frag_ok;
    // P4c ACK-early 修复: 纯 ACK 帧 (plen=0) 的 seq 无需在 rcv_nxt 边界 —
    // RFC 零长段可落在窗口右沿 (seq == rcv_nxt+rcv_wnd, 不占字节); 窗口内/
    // 右沿/旧段都接受, 其 ACK/窗口字段是 snd_una 推进的唯一途径 (PC 满窗
    // 停发后只发纯 ACK, 且该 ACK 的 seq = PC snd_nxt ≈ FPGA 窗口右沿)。
    // 旧行为: seq 非边界 -> 无 fend/S_DROP -> ACK 丢弃 -> snd_una 停滞 ->
    // RTO 回卷风暴 (板级 ACK-early 实验 17.6Mbps 暴跌 + reset 根因;
    // 抓包 frame 2436: PC ACK seq = rcv_nxt+49152 恰在右沿被丢)
    wire        w6a_ok   = base_ok && (plen_w == 16'd0) &&
                           ((seq_diff <= {16'b0, ra_rcv_wnd}) || seq_lt);
    // P3: dup-ACK 判据 — 无载荷纯 ACK 且 ack 不推进 (ack==snd_una) 且还有在飞
    // 未确认数据 (snd_nxt != snd_una: 排除空闲连接的窗口探测 ACK 被误计)
    wire        dup_ack  = base_ok && (plen_w == 16'd0) && ack_ok && !ack_adv &&
                           (ra_snd_nxt != ra_snd_una);
    wire        acc      = base_ok && win_ok && seq_eq;
    // 窗口内乱序 (seq > rcv_nxt) 与重复 (seq < rcv_nxt): 丢数据仍回 ACK (快速重传/dup-ACK 依赖)
    // P5b C16-修订兜底: `seq_eq && !win_ok` (顺序段但窗瞬时不足 — 即使加了
    // ACC_MARGIN 仍越界, 即 Δ > margin 的极端情形) 也必须回 ACK, 否则静默丢弃
    // 只让对端等 200ms RTO (RFC 793 要求不可接受的段回 ACK)。远超前段
    // (!seq_eq && !win_ok && !seq_lt) 仍不回 ACK (与原语义一致); 纯 ACK 帧
    // (plen_w==0) 不受影响。
    wire        ackresp  = base_ok && (plen_w != 16'd0) &&
                           ((!seq_eq && (win_ok || seq_lt)) || (seq_eq && !win_ok));

    // ---- 帧尾/ACK 组合信号 ----
    wire [3:0] pop8w   = pop8(s_axis_tkeep);
    wire [15:0] pay_r   = plen_l - pcount;      // TLAST 拍剩余载荷字节
    wire w6_tlast_ok = acc_l && (plen_l <= 16'd2) && (pop8w == 4'd6 + plen_l[3:0]);
    // P4b-7-P6 trunc 修复: 线上 tlast 早于 IP 承诺载荷 = 截断帧 (PC/NIC 侧怪帧,
    // 板级 WL=72 字节实证)。旧行为: 静默吞尾不发 fend/不闭合 emit_l -> echo 帧
    // 永不判尾 -> 后续帧全合并成无尽帧 -> TX 卡死。修复: 收多少转发多少
    // (真实字节计数), 帧边界闭合, TCB 按真实字节推进 — PC 靠重传补回缺口。
    wire        trunc_pay = (state == S_PAY) && accept && s_axis_tlast &&
                            ({12'b0, pop8w} < pay_r);
    // w6 帧尾截断 (plen_l > 2 但帧在 w6 就结束, 无载荷字): 发 fend 闭合边界,
    // 不 emit 不推进 rcv_nxt (≤2 字节损失交给 PC 重传) — 防与后续帧合并
    // 审查 P2-4: !s_axis_tuser 防 SOP 拍 (单字 runt 防御) 带陈旧 acc_l/plen_l
    // 触发假 fend (fend_w6 同病)
    wire fend_w6t = (state == S_HDR) && accept && (wcnt == 3'd6) && s_axis_tlast &&
                    !s_axis_tuser && !w6_tlast_ok && acc_l && !ackresp_l && !syn_l;
    wire fend_w6 = (state == S_HDR) && accept && (wcnt == 3'd6) && s_axis_tlast &&
                   !s_axis_tuser && w6_tlast_ok;
    wire fend_pay = (state == S_PAY) && (!emit_v || m_axis_tready) && accept &&
                    s_axis_tlast && (({12'b0, pop8w} >= pay_r) || trunc_pay);
    wire fend_pad = (state == S_PAD) && accept && s_axis_tlast;
    // P4b-7-P6 半帧中止防御: S_PAY 见 SOP (前帧无 tlast 中断) 拍 = 半帧 fend,
    // ferr=1 -> echo 坏帧回卷 (合成尾拍 judged 拍) — 防半帧残留合并
    wire fend_trunc = (state == S_PAY) && (!emit_v || m_axis_tready) && accept &&
                      s_axis_tuser;
    // P4c ACK-early 修复: 窗口内非边界纯 ACK 在 w6 拍结束 (TB 短帧注入可达;
    // 真实 60B 帧 tlast 在 w7 走 S_PAD 路径 — 两路都判 fend 处理 ACK 字段)
    wire fend_w6a = (state == S_HDR) && accept && (wcnt == 3'd6) && s_axis_tlast &&
                    !s_axis_tuser && w6a_ok_l && !syn_l;
    assign fend   = fend_w6 || fend_w6t || fend_w6a || fend_pay || fend_pad || fend_trunc;
    assign ferr   = fend_trunc || !s_axis_tcrs || s_axis_terr;
    // 帧真实载荷字节 (截断帧 = 实际到达字节; w6 截断 = 0; 正常帧 = plen_l)
    wire [15:0] adv_cnt = trunc_pay ? (pcount + {12'b0, pop8w}) :
                          (fend_w6t ? 16'd0 : plen_l);
    // ACK 请求: 接受的数据段 (FCS 好, 可被 cfg_suppress_data_ack 抑制 — echo 场景)
    // / 窗口内 seq 不符数据段 (丢数据仍回 ACK); 纯 ACK 绝不回
    assign ack_req = (((fend_w6 && (plen_l != 16'd0)) || fend_pay ||
                       // 审查 P2-6: w6 截断帧 (adv_cnt=0) 也回 ACK = rcv_nxt —
                       // 对端立刻知道本帧未推进, 不等 RTO
                       fend_w6t) && s_axis_tcrs &&
                      !cfg_suppress_data_ack) ||
                     ((state == S_HDR) && accept && (wcnt == 3'd6) && s_axis_tlast &&
                      ackresp_l && s_axis_tcrs) ||
                     ((state == S_DROP) && accept && s_axis_tlast && drop_ack && s_axis_tcrs);
    assign ack_id  = conn_id_l;
    assign ack_val = (fend_w6 || fend_pay) ? (rcv_nxt_l + {16'b0, adv_cnt}) : rcv_nxt_l;

    assign meta_valid   = (state == S_HDR) && accept && (wcnt == 3'd6) &&
                          acc_l && (plen_l != 16'd0) &&
                          (!s_axis_tlast || w6_tlast_ok);
    assign meta_src_ip   = src_ip_r;
    assign meta_src_port = src_port_r;
    assign meta_len      = plen_l;
    assign meta_conn_id  = conn_id_l;
    assign meta_seq      = seq32_l;

    // w6 拍可能发短帧末字, 须等上一帧尾字排空 (硬背压跨帧角例)
    assign s_axis_tready = (state == S_PAY) ? (m_axis_tready || !emit_v) :
                           (state == S_TAIL) ? 1'b0 :
                           ((state == S_HDR) && (wcnt == 3'd6)) ?
                               (m_axis_tready || !emit_v) : 1'b1;
    assign m_axis_tdata  = emit_d;
    assign m_axis_tkeep  = emit_k;
    assign m_axis_tvalid = emit_v;
    assign m_axis_tlast  = emit_l;
    assign m_axis_tuser  = emit_u;

    // CAM 查询 (外部实例): 4 元组组合输出, w4 拍锁存结果
    assign cam_q_sip   = src_ip_r;
    assign cam_q_dip   = {w3_r[15:0], s_axis_tdata[63:48]};
    assign cam_q_sport = s_axis_tdata[47:32];
    assign cam_q_dport = s_axis_tdata[31:16];

    assign syn_smac  = {mac_lo, mac_hi};
    assign syn_sip   = src_ip_r;
    assign syn_sport = src_port_r;
    assign syn_dport = dport_r;
    assign syn_seq   = seq32_l;
    assign syn_wnd   = syn_wnd_r;

    // P4b-7-P6 诊断读出 (纯线束, 与逻辑零耦合)
    assign dbg_state  = state;
    assign dbg_accept = accept;
    assign dbg_emitv  = emit_v;
    // P4b-7-P6 追加: 帧判读锁存值/原始 total_len + 丢弃·通过计数 (纯 assign)
    assign dbg_plen_l           = plen_l;
    assign dbg_pcount           = pcount;
    assign dbg_w2_tlen          = w2_r[63:48];
    assign dbg_stat_drop_seq    = stat_drop_seq;
    assign dbg_stat_drop_crc    = stat_drop_crc;
    assign dbg_stat_drop_nonmatch = stat_drop_nonmatch;
    assign dbg_stat_drop_ipcsum = stat_drop_ipcsum;
    assign dbg_stat_drop_trunc  = stat_drop_trunc;
    assign dbg_stat_pass        = stat_pass;
    // P4b-7-P6 RX emit 轨迹 (纯 assign, 零逻辑; 位宽/语义见端口注释)
    assign dbg_emit_l  = emit_l;
    assign dbg_pay_r   = pay_r;
    assign dbg_pcount2 = pcount;
    assign dbg_fend    = fend;
    // P4b-7-P6 三站词计数 (第 2 站) + 头字计数器 (RXT 条目高位)
    assign dbg_stat_words_in = words_in;
    assign dbg_wcnt          = wcnt;

    wire [15:0] wnd_f = fend_w6 ? s_axis_tdata[63:48] : wnd_l;
    // snd_wnd drain 按握手 wscale 缩放 (P4b-6 窗口门控的真实量纲; 钳 16 位 —
    // P4c: 我方通告 rcv_wnd 0xC000 = 48K 为 PC 在飞上限, 钳位不影响门控语义)。
    // 32 位扩展再钳: wscale>7 (HLS 侧钳 ws<=7 是软契约, 此处自防守)
    wire [31:0] wnd_scaled = {16'b0, wnd_f} << ra_wscale;
    wire [15:0] wnd_ws    = |wnd_scaled[31:16] ? 16'hFFFF : wnd_scaled[15:0];

    // TCB 更新口 (组合: drn 状态电平保持, gnt 拍被写进 TCB 并顺延下一字段)
    assign upd_wr  = ((drn == 2'd1) && pend_rcv) || ((drn == 2'd2) && pend_una) ||
                     ((drn == 2'd3) && pend_wnd);
    assign upd_id  = pend_id;
    assign upd_sel = (drn == 2'd1) ? 3'd0 : (drn == 2'd2) ? 3'd2 : 3'd4;
    assign upd_val = (drn == 2'd1) ? pend_rcv_val :
                     (drn == 2'd2) ? pend_una_val : {16'b0, pend_wnd_val};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_HDR; wcnt <= 0;
            w1_lo <= 0; w2_r <= 0; w3_r <= 0; ipc_s9 <= 0;
            src_ip_r <= 0; src_port_r <= 0; seq_hi_r <= 0; dport_r <= 0;
            mac_lo <= 0; mac_hi <= 0;
            syn_l <= 0; drop_syn_r <= 0; syn_wnd_r <= 0; syn_v <= 0;
            cam_hit_l <= 0; conn_id_l <= 0;
            acc_l <= 0; ackresp_l <= 0; ack_adv_l <= 0; dup_l <= 0;
            w6a_ok_l <= 0;
            ack32_l <= 0; seq32_l <= 0; rcv_nxt_l <= 0; plen_l <= 0; wnd_l <= 0;
            drop_ack <= 0; hold16 <= 0; pcount <= 0;
            emit_v <= 0; emit_d <= 0; emit_k <= 0; emit_l <= 0; emit_u <= 0;
            tail_stage <= 0; tail_d <= 0; tail_k <= 0; tail_u <= 0;
            pend_rcv <= 0; pend_una <= 0; pend_wnd <= 0;
            pend_id <= 0; pend_rcv_val <= 0; pend_una_val <= 0; pend_wnd_val <= 0;
            drn <= 0;
            retx_req <= 0; retx_id <= 0; in_retx <= 0;
            for (di = 0; di < 16; di = di + 1) dup_cnt[di] <= 2'd0;
            stat_pass <= 0; stat_drop_nonmatch <= 0; stat_drop_ipcsum <= 0;
            stat_drop_crc <= 0; stat_drop_seq <= 0; stat_ack <= 0; stat_bytes <= 0;
            stat_drop_trunc <= 0;
            words_in <= 32'd0;
        end else begin
            if (m_axis_tready && emit_v) emit_v <= 1'b0;   // 输出被消费
            syn_v <= 1'b0;                                 // 脉冲型: 每拍默认清零
            // ---- fend 拍锁存 TCB 更新 (P4b-7-P6: sticky pend — fend 只置位不覆盖;
            //      值寄存器只在对应条件成立时更新; 本帧置任一 pend 即重启 drain 到
            //      拍1 (fend 拍 drain 分支互斥, 重启保证新置 pend 不会被越过) ----
            if (fend) begin
                // P4b-7-P6 trunc: adv_cnt = 真实字节 (截断帧按到达量, w6 截断 0)
                // 半帧防御拍 (fend_trunc) 屏蔽 pend_rcv: 陈旧 acc_l/plen_l 不得
                // 误推 rcv_nxt (半帧未完成, 数据将由 PC 重传补回)
                pend_rcv <= (acc_l && (adv_cnt != 16'd0) && s_axis_tcrs &&
                             !fend_trunc) || pend_rcv;
                pend_una <= (ack_adv_l && s_axis_tcrs) || pend_una;
                pend_wnd <= s_axis_tcrs || pend_wnd;
                if (acc_l && (adv_cnt != 16'd0) && s_axis_tcrs && !fend_trunc) begin
                    pend_rcv_val <= rcv_nxt_l + {16'b0, adv_cnt};
                    pend_id <= conn_id_l;
                end
                if (ack_adv_l && s_axis_tcrs) begin
                    pend_una_val <= ack32_l;
                    pend_id <= conn_id_l;
                end
                if (s_axis_tcrs) begin
                    pend_wnd_val <= wnd_ws;
                    pend_id <= conn_id_l;
                end
                drn <= 2'd1;
            end else begin
                // ---- drain FSM (upd_* 组合输出; 该字段写被 gnt 的当拍清除其 pend,
                //      每推进恰好写一次; 非推进帧的 fend 不再能清掉未写出的推进) ----
                case (drn)
                    2'd1: if (!pend_rcv || upd_gnt) begin
                              if (upd_gnt) pend_rcv <= 1'b0;
                              drn <= 2'd2;
                          end
                    2'd2: if (!pend_una || upd_gnt) begin
                              if (upd_gnt) pend_una <= 1'b0;
                              drn <= 2'd3;
                          end
                    2'd3: if (!pend_wnd || upd_gnt) begin
                              if (upd_gnt) pend_wnd <= 1'b0;
                              drn <= 2'd0;
                          end
                    default: ;
                endcase
            end
            // ---- P3 dup-ACK 快速重传检测: fend 拍 (纯 ACK 完整到达, FCS 好)
            //      且本帧是 dup (dup_l), 按 conn_id_l 计数 ----
            //      P4b-7-P6: fend_trunc (半帧防御) 拍 dup_l 陈旧, 不计数
            if (fend && s_axis_tcrs && dup_l && !fend_trunc) begin
                if (!in_retx[conn_id_l]) begin
                    if (dup_cnt[conn_id_l] == 2'd2) begin
                        // 第 3 个 dup: 发重传请求。retx_req 未服务前保持 dup_cnt=2
                        // (不继续累加防回绕), retx_gnt 路径统一归零
                        if (!retx_req) begin
                            retx_req <= 1'b1;
                            retx_id  <= conn_id_l;
                            in_retx[conn_id_l] <= 1'b1;
                            dup_cnt[conn_id_l] <= 2'd0;
                        end
                    end else begin
                        dup_cnt[conn_id_l] <= dup_cnt[conn_id_l] + 2'd1;
                    end
                end
            end
            // 服务确认 (tcp_tx_frame svc 回卷拍) 或真实推进 ACK — 解锁该连接计数
            if (retx_gnt) begin
                retx_req <= 1'b0;
                in_retx[retx_id] <= 1'b0;
                dup_cnt[retx_id] <= 2'd0;
            end else if (fend && s_axis_tcrs && ack_adv_l && !fend_trunc) begin
                in_retx[conn_id_l] <= 1'b0;
                dup_cnt[conn_id_l] <= 2'd0;
                // SEV2-3: 真推进 ACK 已在 svc 前解决空洞 — 取消挂起重传请求,
                // 否则迟到的 svc 触发至多 12KB 无谓全量重放 (数据已确认)
                if (retx_req && (conn_id_l == retx_id))
                    retx_req <= 1'b0;
            end
            // P4b-7-P6 三站词计数 (第 2 站): 接受拍 +1 (头字与载荷字同一计法)
            if (accept) words_in <= words_in + 32'd1;
            if (ack_req) stat_ack <= stat_ack + 1;
            case (state)
                S_HDR: begin
                    if (accept) begin
                        if (s_axis_tuser) begin
                            // 截断防御: 本字即新帧 w0。仅清半帧残留 (emit_l=0);
                            // 完整帧尾 (emit_l=1) 未消费时必须保留, w6 门控等其排空
                            if (!emit_l) emit_v <= 1'b0;
                        end
                        if (s_axis_tlast && (wcnt != 3'd6)) begin
                            // 头没走完帧就结束 (TCP 最小帧 54B, w6 之前 TLAST 必畸形)
                            state <= S_HDR; wcnt <= 3'd0;
                            stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                        end else begin
                            case (s_axis_tuser ? 3'd0 : wcnt)
                                3'd0: begin
                                    if (s_axis_tkeep != 8'hFF) begin
                                        state <= S_DROP; drop_ack <= 1'b0; drop_syn_r <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        mac_lo <= s_axis_tdata[15:0];   // src_mac[47:32]
                                        drop_syn_r <= 1'b0;
                                        wcnt <= 3'd1;
                                    end
                                end
                                3'd1: begin
                                    if (s_axis_tkeep != 8'hFF || !hdr_ok1) begin
                                        state <= S_DROP; drop_ack <= 1'b0; drop_syn_r <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        mac_hi <= s_axis_tdata[63:32];
                                        w1_lo <= s_axis_tdata[15:0];
                                        wcnt <= 3'd2;
                                    end
                                end
                                3'd2: begin
                                    if (s_axis_tkeep != 8'hFF || !hdr_ok2) begin
                                        state <= S_DROP; drop_ack <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        w2_r <= s_axis_tdata;
                                        wcnt <= 3'd3;
                                    end
                                end
                                3'd3: begin
                                    if (s_axis_tkeep != 8'hFF) begin
                                        state <= S_DROP; drop_ack <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        w3_r <= s_axis_tdata[15:0];
                                        src_ip_r <= s_axis_tdata[47:16];
                                        ipc_s9 <= ipc_sum9;
                                        wcnt <= 3'd4;
                                    end
                                end
                                3'd4: begin
                                    if (s_axis_tkeep != 8'hFF) begin
                                        state <= S_DROP; drop_ack <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else if (!ipcsum_ok) begin
                                        state <= S_DROP; drop_ack <= 1'b0;
                                        stat_drop_ipcsum <= stat_drop_ipcsum + 1;
                                    end else begin
                                        cam_hit_l <= cam_q_hit;
                                        conn_id_l <= cam_q_id;
                                        src_port_r <= s_axis_tdata[47:32];
                                        dport_r <= s_axis_tdata[31:16];
                                        seq_hi_r <= s_axis_tdata[15:0];
                                        wcnt <= 3'd5;
                                    end
                                end
                                3'd5: begin
                                    if (s_axis_tkeep != 8'hFF) begin
                                        state <= S_DROP; drop_ack <= 1'b0;
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end else begin
                                        acc_l <= acc;
                                        ackresp_l <= ackresp;
                                        ack_adv_l <= ack_adv;
                                        dup_l <= dup_ack;
                                        w6a_ok_l <= w6a_ok;   // P4c: 窗口内非边界纯 ACK
                                        ack32_l <= ack32;
                                        seq32_l <= seq32;
                                        plen_l <= plen_w;
                                        rcv_nxt_l <= ra_rcv_nxt;
                                        syn_l <= (flags == 8'h02);   // 纯 SYN (无 ACK/RST/FIN)
                                        wcnt <= 3'd6;
                                    end
                                end
                                default: begin   // wcnt==6: 判定 + 载荷入口
                                    syn_wnd_r <= s_axis_tdata[63:48];
                                    // 审查 P2-5: w6-tlast 拍锁存 wnd_l (fend_w6t
                                    // 会置 pend_wnd 取 wnd_f = wnd_l — 旧代码漏锁存,
                                    // 多连接下会把别连接的旧窗口写进本连接)
                                    wnd_l <= s_axis_tdata[63:48];
                                    if (s_axis_tlast) begin
                                        state <= S_HDR; wcnt <= 3'd0;
                                        if (w6_tlast_ok || fend_w6a) begin
                                            // 纯 ACK (plen=0) 或短载荷 (plen=1..2, 无填充);
                                            // P4c: 含窗口内非边界纯 ACK (w6a)
                                            if (s_axis_tcrs) begin
                                                stat_pass <= stat_pass + 1;
                                                stat_bytes <= stat_bytes + plen_l;
                                            end else begin
                                                stat_drop_crc <= stat_drop_crc + 1;
                                            end
                                            if (plen_l != 16'd0) begin
                                                emit_v <= 1'b1;
                                                emit_d <= ljust2(s_axis_tdata[15:0], plen_l[2:0]);
                                                emit_k <= 8'hFF << (4'd8 - plen_l[3:0]);
                                                emit_l <= 1'b1;
                                                emit_u <= {s_axis_terr, s_axis_tcrs};
                                            end
                                        end else if (ackresp_l) begin
                                            stat_drop_seq <= stat_drop_seq + 1;
                                        end else begin
                                            // 纯 SYN 短帧 (w6-tlast): 帧尾即报握手
                                            if (syn_l && s_axis_tcrs && !s_axis_terr)
                                                syn_v <= 1'b1;
                                            // P4b-7-P6 trunc: acc_l=1 的 w6 截断帧
                                            // (fend_w6t) 计入 trunc, 其余仍 nonmatch
                                            if (acc_l)
                                                stat_drop_trunc <= stat_drop_trunc + 1;
                                            else
                                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                        end
                                    end else if (acc_l) begin
                                        if (plen_l == 16'd0) begin
                                            state <= S_PAD;   // 纯 ACK 带填充: 吞到帧尾
                                        end else begin
                                            state <= S_PAY;
                                            hold16 <= s_axis_tdata[15:0];
                                            pcount <= (plen_l >= 16'd2) ? 16'd2 : 16'd1;
                                        end
                                        wnd_l <= s_axis_tdata[63:48];
                                        wcnt <= 3'd7;
                                    end else if (w6a_ok_l) begin
                                        // P4c: 窗口内非边界纯 ACK (带填充, 真实 60B
                                        // 帧 tlast 在 w7) — 吞到帧尾, fend_pad 处理
                                        // 其 ACK/窗口字段 (snd_una 推进的唯一途径)
                                        state <= S_PAD;
                                        wcnt <= 3'd7;
                                    end else if (ackresp_l) begin
                                        state <= S_DROP; drop_ack <= 1'b1; drop_syn_r <= 1'b0;
                                        stat_drop_seq <= stat_drop_seq + 1;
                                    end else begin
                                        state <= S_DROP; drop_ack <= 1'b0;
                                        drop_syn_r <= syn_l;   // SYN 帧在 S_DROP 帧尾报握手
                                        stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                                    end
                                end
                            endcase
                        end
                    end
                end
                S_PAY: begin
                    if ((!emit_v || m_axis_tready) && accept) begin
                        if (s_axis_tuser) begin
                            // P4b-7-P6 冻结第三机制修复 (半帧中止防御): 上游帧流
                            // 无 tlast 中断 (mac_rx 中止) 时丢弃当前帧残余, 合成
                            // ferr 尾拍 (fend_trunc) 让 echo 以坏帧回卷半帧 (不再
                            // 合并巨帧), 回 S_HDR 重收。本拍即新帧 w0 已牺牲 (与
                            // slow_rx_adp trunc_evt 同策略: 后续错头字被 S_HDR
                            // 判据丢入 S_DROP 吞到帧尾, PC 重传补回)。旧行为只救
                            // RX 自己, echo 半帧残留 -> 合并巨帧 -> TX 卡死
                            // (板级+TB 复现实锤)。
                            emit_v <= 1'b1;                    // 合成尾拍
                            emit_d <= 64'h0; emit_k <= 8'h00;
                            emit_l <= 1'b1; emit_u <= 2'b00;
                            state <= S_HDR; wcnt <= 3'd0;
                            stat_drop_trunc <= stat_drop_trunc + 1;
                        end else if (s_axis_tlast) begin
                            state <= S_HDR; wcnt <= 3'd0;
                            if ({12'b0, pop8w} < pay_r) begin
                                // P4b-7-P6 trunc 修复: 截断帧 (承诺 > 到达)。帧真实
                                // 结束 — 尾 = hold16 + 本字有效字节 (pop8w), 按真实
                                // 字节数闭合 emit_l (或走 S_TAIL 溢出), fend 已由
                                // fend_pay 含 trunc_pay 覆盖, TCB 按真实字节推进。
                                // 旧行为 (静默吞尾无 fend 无 emit_l=1) = 冻结根源。
                                // 审查 P2-3: 计数按 tcrs 分流 (好 FCS pass/bytes,
                                // 坏 FCS drop_crc), trunc 维度独立计数
                                stat_drop_trunc <= stat_drop_trunc + 1;
                                if (s_axis_tcrs) begin
                                    stat_pass  <= stat_pass + 1;
                                    stat_bytes <= stat_bytes + pcount +
                                                  {12'b0, pop8w};
                                end else begin
                                    stat_drop_crc <= stat_drop_crc + 1;
                                end
                                emit_v <= 1'b1;
                                emit_u <= {s_axis_terr, s_axis_tcrs};
                                emit_d <= {hold16, s_axis_tdata[63:16]};
                                if (pop8w <= 4'd6) begin
                                    // 3..8 字节: 单尾字闭合 (emit_k 按真实数掩)
                                    emit_k <= 8'hFF << (4'd8 - pop8w[3:0] - 4'd2);
                                    emit_l <= 1'b1;
                                end else begin
                                    // 9..10 字节: 主字 8B + S_TAIL 溢出 1..2B
                                    emit_k <= 8'hFF;
                                    emit_l <= 1'b0;
                                    state <= S_TAIL; tail_stage <= 1'b0;
                                    tail_d <= ljust2(s_axis_tdata[15:0],
                                                     pop8w[3:0] - 4'd6);
                                    tail_k <= 8'hFF << (4'd8 - pop8w[3:0] + 4'd6);
                                    tail_u <= {s_axis_terr, s_axis_tcrs};
                                end
                            end else begin
                                if (s_axis_tcrs) begin
                                    stat_pass <= stat_pass + 1;
                                    stat_bytes <= stat_bytes + plen_l;
                                end else begin
                                    stat_drop_crc <= stat_drop_crc + 1;
                                end
                                emit_v <= 1'b1;
                                emit_u <= {s_axis_terr, s_axis_tcrs};
                                if (pay_r == 16'd0) begin
                                    // 短载荷带填充: 只剩 hold16
                                    emit_d <= ljust2(hold16, plen_l[2:0]);
                                    emit_k <= 8'hFF << (4'd8 - plen_l[3:0]);
                                    emit_l <= 1'b1;
                                end else if (pay_r <= 16'd6) begin
                                    emit_d <= {hold16, s_axis_tdata[63:16]};
                                    emit_k <= 8'hFF << (4'd8 - (pay_r[3:0] + 4'd2));
                                    emit_l <= 1'b1;
                                end else begin
                                    // 主尾字 8 字节 + 溢出尾字 (pay_r-6 字节在源字低 2 字节区)
                                    emit_d <= {hold16, s_axis_tdata[63:16]};
                                    emit_k <= 8'hFF;
                                    emit_l <= 1'b0;
                                    state <= S_TAIL; tail_stage <= 1'b0;
                                    // pay_r ∈ {7,8}: 必须用 4 位截 (3 位会把 8 截成 0)
                                    tail_d <= ljust2(s_axis_tdata[15:0], pay_r[3:0] - 4'd6);
                                    tail_k <= 8'hFF << (4'd8 - (pay_r[3:0] - 4'd6));
                                    tail_u <= {s_axis_terr, s_axis_tcrs};
                                end
                            end
                        end else begin
                            if (s_axis_tkeep != 8'hFF) begin
                                state <= S_DROP; drop_ack <= 1'b0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else if (pcount + 16'd8 > plen_l) begin
                                // 帧身超过 IP total_len 声明的载荷: 畸形, 吞掉防 pcount 回绕
                                state <= S_DROP; drop_ack <= 1'b0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else begin
                                emit_v <= 1'b1;
                                emit_d <= {hold16, s_axis_tdata[63:16]};
                                emit_k <= 8'hFF;
                                emit_l <= 1'b0;
                                hold16 <= s_axis_tdata[15:0];
                                pcount <= pcount + 16'd8;
                            end
                        end
                    end
                end
                S_PAD: begin
                    if (accept) begin
                        if (s_axis_tuser) begin
                            if (s_axis_tlast) begin
                                state <= S_HDR; wcnt <= 3'd0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else if (s_axis_tkeep != 8'hFF) begin
                                state <= S_DROP; drop_ack <= 1'b0; drop_syn_r <= 1'b0;
                                stat_drop_nonmatch <= stat_drop_nonmatch + 1;
                            end else begin
                                mac_lo <= s_axis_tdata[15:0];   // 本字即新帧 w0
                                drop_syn_r <= 1'b0;
                                state <= S_HDR; wcnt <= 3'd1;
                            end
                        end else if (s_axis_tlast) begin
                            state <= S_HDR; wcnt <= 3'd0;
                            if (s_axis_tcrs) stat_pass <= stat_pass + 1;
                            else stat_drop_crc <= stat_drop_crc + 1;
                        end
                    end
                end
                S_TAIL: begin
                    if (tail_stage) begin
                        if (m_axis_tready) begin
                            state <= S_HDR; wcnt <= 3'd0;   // 溢出尾字已消费
                            emit_v <= 1'b0;
                        end
                    end else if (m_axis_tready) begin
                        emit_v <= 1'b1; emit_d <= tail_d;
                        emit_k <= tail_k; emit_l <= 1'b1; emit_u <= tail_u;
                        tail_stage <= 1'b1;
                    end
                end
                default: begin   // S_DROP: 吞到帧尾 (drop_ack 帧尾回 ACK; drop_syn 帧尾报握手)
                    if (accept && s_axis_tlast) begin
                        state <= S_HDR; wcnt <= 3'd0;
                        if (drop_syn_r && s_axis_tcrs && !s_axis_terr) syn_v <= 1'b1;
                        drop_ack <= 1'b0;
                        drop_syn_r <= 1'b0;
                    end
                end
            endcase
        end
    end
endmodule
