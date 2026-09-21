`timescale 1ns/1ps
//=============================================================================
// wrapper_p4.v — udp_hls_10g 板上 P4a 顶层 (1G RGMII): TCP fast path + HLS 慢路径
//=============================================================================
// 数据面: PC → PHY1 RGMII → util_gmii_to_rgmii → mac_rx_64 → rx_classify
//   fast (IPv4/TCP 数据/纯ACK): tcp_rx → tcp_echo → tcp_tx_frame ─┐
//     (P4b: 握手/SYN/FIN/RST 分流慢路径 HLS 正式处理, tcp_synp 已拆; ├→ tx_arb (fast 优先)
//      CAM/TCB 由 slow_cfg_adp 按 HLS cfg_stream 记录配置)          │
//   slow (其他全部):  slow_rx_adp → udp_echo (HLS 慢路径)│
//     udp_echo.tx_stream → slow_tx_adp ─────────────────┘
//   tx_arb → mac_tx_64 → util → PHY1 → PC
//
// 前端 recipe 与 wrapper_tcp.v 逐字一致 (MMCM 200M + IDELAYCTRL + u_rgmii
// 实例名 + RX 再寄存一拍; eco_rgmii_phy1.xdc 原样复用)。
//
// MAC 统一: HLS 编译期 MAC = 00:0A:35:01:FE:C0 (板验资产) — fast path cfg
// 同步改为 C0 (原 C1 作废)。HLS 应答 ARP (who-has 192.168.100.2 → C0),
// PC 免静态 ARP。HLS 自发行文: 上电 ~1s DHCP DISCOVER ×3 + 每 ~5s UDP HELLO
// (白送的慢路径 TX 冒烟, pktmon 可见)。
//
// LED readout (pins as wrapper_1g.v; on-board LEDs active-high -- high turns
// them on, so direct drive without inversion; lit = probe value 1):
//   Boot self-test: first ~1.2s after reset ALL 4 LEDs blink 3x (0.2s on +
//   0.2s off each) to verify polarity/mapping. If invisible, polarity is
//   inverted -- report, do not invert. Then normal mode below.
//   Pre-latch (no RTO rewind yet): live probes
//     led_d0 = tcp_tx_frame dbg_wnd_open  (window gate open)
//     led_d1 = OFF
//     led_d2 = tcp_tx_frame dbg_sready    (accepting live payload)
//     led_d3 = tcp_echo dbg_fifo_full     (echo frame FIFO full)
//   Event latch: the freeze's first RTO rewind (svc_rewind makes
//   tx_stat_retx nonzero ~100ms into the freeze; a deterministic moment deep
//   in the frozen state) latches ONCE and samples the win-port probes on the
//   same cycle: latch_val = {wnd_open, 1'b0 (was hi_eq, removed), (wnd_eff==0),
//   (inflight>=wnd_eff)}. A run with NO freeze never latches -> led_d0 stays
//   the live wnd_open probe.
//   Post-latch (freeze diagnosed): led_d1 = solid ON (data ready indicator);
//   led_d2/led_d3 keep their live probes throughout. led_d0 = blink encoding:
//   it blinks (latch_val+1) times, 0.25s on + 0.25s off each, then a 2.0s
//   pause, then repeats. Count N blinks in one burst; N decodes as the binary
//   value {wnd,0,eff0,infge} with N = value+1:
//     1=0000 2=0001 3=0010 4=0011 5=0100 6=0101 7=0110 8=0111
//     9=1000 10=1001 11=1010 12=1011 13=1100 14=1101 15=1110 16=1111.
//   (Old P4a probes rx_stat_frames/tcp_rx.stat_pass/slow_rx_adp/slow_tx_adp
//    retired; their assign text is kept commented at the file tail)
//
// UART 全精度读出 (uart_txd, PACKAGE_PIN A17 = 板载 CH340E USB 串口, k707
//   demo 验证引脚; 9600-8N1, gmii_clk 125MHz 域, 13021 拍/位):
//   锁存拍 (首次 RTO 回卷) 同拍快照 TCB conn0 全字段 (snd_nxt/snd_una/
//   snd_wnd/wscale/state, dbg_* 口 = 阵列 entry[0] 纯组合读) + win 读口
//   16 位全值; 锁存后 dbg_line_tx 立即发首行、此后每 ~5s 重复一行 358 字符
//   ASCII (9600 下 ~373ms/行, 重复防 PC 漏读)。行格式:
//     NX=%08X UA=%08X WN=%04X WS=%01X ST=%01X W=%d%d%d%d I=%04X E=%04X TXST=%1X RXST=%1X ACC=%d EMV=%d EST=%1X FFE=%d%dWPT=%04XRPT=%04X PF=%d TV=%d PV=%d SV=%d PLEN=%03X TW=%08X TF=%08X TI=%08X PW=%03X PR=%03X PFL=%d PEM=%d PLN=%03X RXPL=%04X RXPC=%04X RXT=%04X DROPS=%08X/%08X/%08X/%08X PASS=%08X RXTR=%d MW=%08X CW=%08X/%08X RW=%08X WC=%d WL=%04X\r\n
//   NX=snap snd_nxt0  UA=snap snd_una0  WN=snap snd_wnd0  (32/32/16 位 hex)
//   WS=snap wscale0   ST=snap tcb state0                (4 位 hex 各 1 位)
//   W = latch_val 4 位 '0'/'1' MSB 前: {wnd,0,eff0,infge} (与 LED blink 同;
//   bit2 = 1'b0 占位 — P6 的 win_hi_eq 已随 64K 边界误关修复废除)
//   I=snap win_inflight  E=snap win_wnd_eff             (16 位 hex)
//   TXST = tcp_tx_frame FSM state[2:0] 每行开头实时重采 (非法态/循环诊断)
//   RXST = tcp_rx FSM state[2:0]       每行开头重采 — 冻结位点诊断:
//          停在 S_PAY(1)/S_PAD(2)/S_DROP(3)/S_TAIL(4) 即 RX 中段卡死
//   ACC = tcp_rx 接受拍 (tvalid&&tready; 冻结后应恒 0 — 非 0 说明 RX 仍在吃数据)
//   EMV = tcp_rx emit_v ('0'/'1' — 载荷输出字挂起, 背压链阻塞位点)
//   EST = tcp_echo FSM state[1:0]     每行开头重采 (S_IDLE=0/S_FWD=1)
//   FFE = echo frame_fifo {full, empty} 逐位 '0'/'1' (冻结时 11=回卷后仍堵)
//   WPT/RPT = echo frame_fifo wptr/rptr[12:0] 每行开头重采 (P4c AW=13: 4 位 hex,
//             字段 8 字符无前导分隔空格; 差 mod 8192 ≈ 占用字数)
//   PF = tcp_tx_frame dbg_pay_full  TX 载荷 FIFO 满 (S_RECV 失 tlast 停吞位点)
//   TV = tcp_tx_frame s_axis_tvalid PV = u_eco_pipe m_valid  SV = u_eco_pipe
//        s_valid (TX 输入侧握手链, 每行开头重采; 失 tlast 时 SV=1 PV=0?)
//   PLEN = tcp_tx_frame plen_r 帧载荷累计 (S_RECV 已吞字数, 冻结恒值)
//   TW = tcp_echo stat_tlast_wr TF = tcp_echo stat_tlast_fwd
//        TI = tcp_tx_frame stat_tlast_in (P4b-7-P6 tlast 定位三计数, 每行行首
//        重采; 三值同步增长为正常: TW>TF => tlast 死在 echo frame_fifo;
//        TW==TF>TI => 死在 echo→帧器链路; TI 随 TW => 已到帧器)
//   PW/PR = u_fifo (tx 载荷 FIFO) wptr/rptr[8:0] 每行行首重采 — 差值 = 实际
//        占用字数, 与 PLN 对账判 PF 报满是真满还是指针异常
//   PFL/PEM = u_fifo {full, empty} 逐位 '0'/'1' (端口直出, 与 PF 同源)
//   PLN = tcp_tx_frame RUNNING plen[11:0] (帧内累计; 区别于 PLEN = plen_r)
//   RXPL = tcp_rx plen_l 帧判读锁存 (IP total_len-40)  RXPC = tcp_rx pcount
//        RXT = tcp_rx w2_r[63:48] 原始 IP total_len 字段 (plen_l 上游真值)
//        DROPS = tcp_rx stat_drop_{seq,crc,nonmatch,ipcsum}  PASS = stat_pass
//        (计数为定宽 8 位 hex; 冻结期哪一路随帧速率递增 = 该判据持续触发,
//         nonmatch 递增 => over-length 守卫在帧中段 S_DROP 断尾丢 tlast)
//   P4b-7-P6 三站词计数 (快照行尾, 每行行首重采 — 丢词站裁决):
//     MW  = mac_rx_64   dbg_stat_words_out (发出 m_axis 字, tvalid&&tready)
//     CW  = rx_classify {dbg_stat_words_in, dbg_stat_words_out} (接受 s_axis 字 /
//           发出 fast 路字); RW = tcp_rx dbg_stat_words_in (接受 s_axis 字)
//     WC  = tcp_rx wcnt (头字计数器 0..7, 与 RXT 条目 [26:24] 同源)
//     读法: 正常流量 MW ≈ CW_in ≈ CW_out ≈ RW (级间 skew 常数); 触发帧上
//     MW 与 CW 之差 = 滞压未消费词, CW_out 与 RW 之差 = fast 路在途/被丢词。
//     若触发帧的 7 头字+1 载荷字在 MW/CW 上完整、仅 RW 少 => 丢在 classify
//     输出→RX 输入之间; 三站都完整而 wcnt 轨迹错拍 => RX 头字锁存错位。

//   P4b-7-P6 TRACE (快照行之后 4 行, 仅 trace_frozen 锁存后发):
//     TR=%06X %06X ... 每行 16 字 × 6 位 hex (117 字符), 4 行 = 64 字环全量;
//     字 = 拍级 beat 历史快照 (位布局见下 trace_mem 注释), 字序 = 环时间序
//     (g=0 最旧 ... g=62 最新, g=63 = 环内最老一条, 见 uart_dbg.v 头注释)。
//     触发 = 与快照锁存同一事件 (首次 RTO 回卷, tx_stat_retx != 0), 环自锁存
//     下拍停写 — 环内 64 条 = 回卷拍及其前 63 拍真冻结态 (tvalid=1, tready=0,
//     tlast=0, accept=0), 与快照行严格同点, 不再依赖 stall 探测器。
//   P4b-7-P6 TL (TR 行之后 8 行, 仅锁存后发 = 帧 FIFO 边存 tlast 位图):
//     TL=%02X%02X%02X%02X%02X%02X%02X%02X 每行 8 字节 (21 字符), 8 行 = 64 槽;
//     行 k 字节 j = 边存址 (rptr-32+8k+j) & 8191 的 bit8 (tlast), 打印 00/01
//     (一字节一槽, 地址顺序)。基址 rptr 在 TL 段首拍 (快照行末/TR4 行末) 锁存。
//     上游 = frame_fifo dbg_rd_addr/dbg_rd_side 边存组合读口 (P6c); 位图直接
//     给出「tlast=1 的帧末拍落在哪些槽、间隔是否 = 帧长」, 用于定位丢 tlast。
//   P4b-7-P6 RX-TRACE (TL 行之后 4 行, 仅 rxt_run 时发 = RX 帧尾计数异常环):
//     RXT=%07X %07X ... 每行 16 字 × 7 位 hex (4+128+CR LF = 134 字符), 4 行
//     = 64 字环全量; 字序/时间轴语义同 TR 行 (g=0 最旧 ... g=63 = 触发拍,
//     环址 = (rxt_wptr - 63 + g) & 63)。字 27 位布局见下 rx_trace_mem 注释
//     (每字最高位 hex 数字 = wcnt, 板级肉眼即读头字计数):
//     [26:24] wcnt  [23] pad  [22:20] rx FSM state  [19] emit_v  [18] emit_l
//     [17] accept  [16] echo tready (!fifo_full)  [15:12] pay_r[3:0]
//     [11:0] pcount[11:0]
//     触发 = RX 帧尾拍 fend && pcount < plen_l-4 (帧尾 ≥5 载荷字节未入账),
//     sticky 一次性锁存 → 环内 = 触发拍及前 63 拍 RX 逐拍状态; 看 pcount 从哪
//     拍起偏离 (正常 1460B 帧 pcount 每 S_PAY 拍 +8, fend 拍 = plen_l-2) 即可
//     定位 pay_r 变大的源头 → 尾分支误走 S_TAIL (emit_l=0) → 帧边界丢失。
//     快照行尾 RXTR=%d 与 rxt_run 同源 (1 = RX 环已冻结, 保证 RXT 行有数据)。
//   P4b-7-P6-P6b 线上帧长 WL (快照行**最后**一个字段, 与 RXTR 同一触发拍锁存):
//     WL=%04X = 异常触发帧的线上字节数 (phy1_rxc 域累计 RGMII RX_CTL 高电平
//     拍数 x8; 帧中段 RX_CTL 恒高, 一帧只在首/尾各有一个跳变沿) — 判别器:
//       WL≈0042 (66)   => PC/网卡真的只发来 66 字节短帧 (PC 侧/驱动/协议栈);
//       WL≈05EA (1514) => 线上是整帧, 帧中段字节被 RGMII 桥/mac_rx 路径吞掉
//                         (FPGA 侧) — fend pcount=1 的 62 字节与线长无关。
//     WL 含前导/SFD 时 ≈帧长+8 (不做去偏, 判别器只需区分 66 vs 1500+);
//     未触发 (RXTR=0) 时恒 0 (无异常帧即无线长语义)。计数域 → UART 域 =
//     逐位 2 级同步 (采样抖动 ≤1 gmii 拍, 见 wrapper 内 wire_last 同步块注释)。
//   板级读法: PC PowerShell System.IO.Ports 打开 CH340 COMx 9600-8N1 后再跑
//   速率测试; 冻结 ~100ms 后 UART 每 ~5s 出一轮 (快照行 + 4 TR 行 + 8 TL 行
//   + 4 RXT 行, ~1.5s; led_d1 恒亮即行在发)。
//=============================================================================

module wrapper_p4 (
    input           reset_n,
    input           fpga_gclk,
    input           phy1_rxc,
    input  [3:0]    phy1_rxd,
    input           phy1_rxctl,
    output          phy1_txc,
    output [3:0]    phy1_txd,
    output          phy1_txctl,
    output          led_d0,
    output          led_d1,
    output          led_d2,
    output          led_d3,
    // P4b-7-P6 冻结态 UART 全精度读出 (板载 CH340E 串口 → PC, 9600-8N1)
    output          uart_txd
);

    // --- P5 app 接口构建开关 (默认关 = 现状 echo 数据面, 逐位不变) -------------
    // APP_MODE 定义时: 数据面接 app (AXIS 收发 + 寄存器控制), 且
    // cfg_suppress_data_ack 必须为 0 —— app 模式没有 echo 捎带, 逐段纯 ACK 是
    // 对端确认的唯一途径。默认 (未定义) 时本文件所见行为与 P4 完全一致。
`ifdef APP_MODE
    localparam APP_EN = 1'b1;
`else
    localparam APP_EN = 1'b0;
`endif

    // ---- P5: 窗口/ring 帽单一来源 (W5) ----
    // 三处必须同值: tcp_tx_frame.RING_CAP (ring 门控帽) = tcb.WIN_CAP (注册窗口
    // 门帽) = app_ctrl.WIN_CAP (app_tx_ready 的窗帽)。原先各自独立字面量,
    // 改一处漏两处就会分叉 — 现在全部由本 localparam 下发。
    localparam [15:0] WIN_CAP_5 = 16'hBFFE;

    // --- 200MHz IDELAYCTRL 参考钟 (逐字照抄 wrapper_tcp.v) ---
    wire ref200_clk, ref200_clk_raw, ref200_fb, mmcm_ref_locked;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(20.0),
        .CLKFBOUT_MULT_F(20.0),
        .CLKFBOUT_PHASE(0.0),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(5.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE(0.0),
        .CLKOUT1_DIVIDE(1), .CLKOUT1_DUTY_CYCLE(0.5), .CLKOUT1_PHASE(0.0),
        .CLKOUT2_DIVIDE(1), .CLKOUT2_DUTY_CYCLE(0.5), .CLKOUT2_PHASE(0.0),
        .CLKOUT3_DIVIDE(1), .CLKOUT3_DUTY_CYCLE(0.5), .CLKOUT3_PHASE(0.0),
        .CLKOUT4_DIVIDE(1), .CLKOUT4_DUTY_CYCLE(0.5), .CLKOUT4_PHASE(0.0),
        .CLKOUT5_DIVIDE(1), .CLKOUT5_DUTY_CYCLE(0.5), .CLKOUT5_PHASE(0.0),
        .CLKOUT6_DIVIDE(1), .CLKOUT6_DUTY_CYCLE(0.5), .CLKOUT6_PHASE(0.0),
        .REF_JITTER1(0.010),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm_ref (
        .CLKIN1(fpga_gclk),
        .CLKOUT0(ref200_clk_raw),
        .CLKOUT0B(),
        .CLKOUT1(), .CLKOUT1B(),
        .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBOUT(ref200_fb),
        .CLKFBOUTB(),
        .CLKFBIN(ref200_fb),
        .LOCKED(mmcm_ref_locked),
        .PWRDWN(1'b0),
        .RST(!reset_n)
    );
    BUFG u_bufg_200 (.I(ref200_clk_raw), .O(ref200_clk));

    wire delay_ready;
    (* IODELAY_GROUP = "idelay" *) IDELAYCTRL u_idelayctrl (
        .RDY(delay_ready),
        .REFCLK(ref200_clk),
        .RST(1'b0)
    );

    // --- RGMII 适配 (实例名 u_rgmii 不可改, XDC generated clock 引用) ---
    wire gmii_clk;
    wire [7:0] e_rxd;
    wire       e_rxdv, e_rxer;
    wire [7:0] e_txd;
    wire       e_txen;
    wire       e_txer;

    util_gmii_to_rgmii u_rgmii (
        .reset          (1'b0),
        .rgmii_td       (phy1_txd),
        .rgmii_tx_ctl   (phy1_txctl),
        .rgmii_txc      (phy1_txc),
        .rgmii_rd_i     (phy1_rxd),
        .rgmii_rx_ctl_i (phy1_rxctl),
        .gmii_rx_clk    (gmii_clk),
        .rgmii_rxc      (phy1_rxc),
        .gmii_txd       (e_txd),
        .gmii_tx_en     (e_txen),
        .gmii_tx_er     (e_txer),
        .gmii_tx_clk    (),
        .gmii_crs       (),
        .gmii_col       (),
        .gmii_rxd       (e_rxd),
        .gmii_rx_dv     (e_rxdv),
        .gmii_rx_er     (e_rxer),
        .speed_selection(2'b10),
        .duplex_mode    (1'b1)
    );

    // ---- P4b-7-P6-P6b 线上帧长计数器 (gmii_clk 域; diag18 重写 — 原 phy1_rxc
    //      域版本废除: 新时钟域 + 异步复位扇出是 diag17 HLS 死亡的头号嫌疑,
    //      且 RGMII RX_CTL 信息本就存在于 u_rgmii 输出的 e_rxdv, 无需再开域) ----
    // 判别器: 快照行 WL 字段 = 异常触发帧的线上字节数 —
    //   WL≈66   => PC/网卡真的只发来 66 字节短帧 (协议栈/NIC 侧);
    //   WL≈1518 => 线上是整帧, 帧中段字节被 RGMII 桥/mac_rx 路径吞掉 (FPGA 侧)。
    // 原理: GMII rx_dv 高电平持续时间 = 线上整帧 (含前导/SFD/FCS), 每 gmii 拍
    // 1 字节 (125MHz 字节流) — 直接累计高拍数即字节数, 无乘 8/无 CDC。
    reg [15:0] wl_cnt;        // 帧内累计 (rx_dv 高拍数 = 线上字节数)
    reg [15:0] wl_last;       // 完整帧线上字节数 (rx_dv 落沿锁存, 帧间保持)
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            wl_cnt <= 16'd0; wl_last <= 16'd0;
        end else begin
            if (e_rxdv) wl_cnt <= wl_cnt + 16'd1;
            else if (wl_cnt != 16'd0) begin        // 帧尾: 锁存整帧字节数
                wl_last <= wl_cnt;
                wl_cnt  <= 16'd0;
            end
        end
    end

    // --- RX 流再寄存一拍 (照抄) ---
    reg [7:0] rx_d1;
    reg       rx_dv_d1, rx_er_d1;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin rx_d1<=0; rx_dv_d1<=0; rx_er_d1<=0; end
        else begin rx_d1<=e_rxd; rx_dv_d1<=e_rxdv; rx_er_d1<=e_rxer; end
    end

    // --- mac_rx_64 → rx_classify ---
    wire [63:0] rx_tdata;
    wire [7:0]  rx_tkeep;
    wire        rx_tvalid, rx_tready, rx_tlast, rx_tuser, rx_tcrs, rx_terr;
    wire [31:0] rx_stat_frames, rx_stat_crc_err, rx_stat_drop, rx_stat_bytes;
    wire [31:0] mac_dbg_words_out, cls_dbg_words_in, cls_dbg_words_out;

    wire [63:0] f_tdata;
    wire [7:0]  f_tkeep;
    wire        f_tvalid, f_tready, f_tlast, f_tuser, f_tcrs, f_terr;
    wire [63:0] s_tdata;
    wire [7:0]  s_tkeep;
    wire        s_tvalid, s_tready, s_tlast, s_tuser, s_tcrs, s_terr;
    wire [31:0] cls_stat_fast, cls_stat_slow;

    mac_rx_64 u_mac_rx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .gmii_rxd       (rx_d1),
        .gmii_rx_dv     (rx_dv_d1),
        .gmii_rx_er     (rx_er_d1),
        .m_axis_tdata   (rx_tdata),
        .m_axis_tkeep   (rx_tkeep),
        .m_axis_tvalid  (rx_tvalid),
        .m_axis_tready  (rx_tready),
        .m_axis_tlast   (rx_tlast),
        .m_axis_tuser   (rx_tuser),
        .m_axis_terr    (rx_terr),
        .m_axis_tcrs    (rx_tcrs),
        .stat_frames    (rx_stat_frames),
        .stat_crc_err   (rx_stat_crc_err),
        .stat_drop      (rx_stat_drop),
        .stat_bytes     (rx_stat_bytes),
        .dbg_stat_words_out (mac_dbg_words_out)
    );

    // --- P4e VLAN 剥离 shim: mac_rx_64 → rx_classify 之间剥单层 802.1Q/1ad
    //     (TPID+TCI = 4 字节左移), 使带 tag 帧在 classify/tcp_rx 眼里就是无 tag
    //     字节布局 (ethertype 回 byte 12-13) — tcp_rx 载荷偏移 54B 无须改动。
    //     MW (mac_rx_64 出词) 计数点在本模块之前, 不受影响; VLAN 帧剥后短 4B
    //     => 出词少 0~1 个 (CW/RW 相应少, 非丢词)。QinQ 剥一层后内层 TPID 仍落
    //     byte 12-13 -> 慢路径 (HLS 支持多层), 本模块不误判。
    //     时序: 非 VLAN 恒 1 拍直通; VLAN 帧 tag 字处 1 拍输出气泡 + 尾字至多
    //     1 拍 S_TAIL (s_axis_tready=0), 由 mac_rx_64 的 8 深 FIFO + IFG 吸收。 ---
    wire [63:0] vs_tdata;
    wire [7:0]  vs_tkeep;
    wire        vs_tvalid, vs_tready, vs_tlast, vs_tuser, vs_tcrs, vs_terr;
    wire [31:0] vlan_stat_stripped;   // 板级观测: UART 帧行未接 (后续可加)
    wire        vlan_dbg;

    vlan_strip u_vlan_strip (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (rx_tdata),
        .s_axis_tkeep   (rx_tkeep),
        .s_axis_tvalid  (rx_tvalid),
        .s_axis_tready  (rx_tready),
        .s_axis_tlast   (rx_tlast),
        .s_axis_tuser   (rx_tuser),
        .s_axis_tcrs    (rx_tcrs),
        .s_axis_terr    (rx_terr),
        .m_axis_tdata   (vs_tdata),
        .m_axis_tkeep   (vs_tkeep),
        .m_axis_tvalid  (vs_tvalid),
        .m_axis_tready  (vs_tready),
        .m_axis_tlast   (vs_tlast),
        .m_axis_tuser   (vs_tuser),
        .m_axis_tcrs    (vs_tcrs),
        .m_axis_terr    (vs_terr),
        .stat_stripped  (vlan_stat_stripped),
        .dbg_vlan       (vlan_dbg)
    );

    rx_classify u_classify (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (vs_tdata),
        .s_axis_tkeep   (vs_tkeep),
        .s_axis_tvalid  (vs_tvalid),
        .s_axis_tready  (vs_tready),
        .s_axis_tlast   (vs_tlast),
        .s_axis_tuser   (vs_tuser),
        .s_axis_tcrs    (vs_tcrs),
        .s_axis_terr    (vs_terr),
        .m_fast_tdata   (f_tdata),
        .m_fast_tkeep   (f_tkeep),
        .m_fast_tvalid  (f_tvalid),
        .m_fast_tready  (f_tready),
        .m_fast_tlast   (f_tlast),
        .m_fast_tuser   (f_tuser),
        .m_fast_tcrs    (f_tcrs),
        .m_fast_terr    (f_terr),
        .m_slow_tdata   (s_tdata),
        .m_slow_tkeep   (s_tkeep),
        .m_slow_tvalid  (s_tvalid),
        .m_slow_tready  (s_tready),
        .m_slow_tlast   (s_tlast),
        .m_slow_tuser   (s_tuser),
        .m_slow_tcrs    (s_tcrs),
        .m_slow_terr    (s_terr),
        .stat_fast      (cls_stat_fast),
        .stat_slow      (cls_stat_slow),
        .dbg_stat_words_in  (cls_dbg_words_in),
        .dbg_stat_words_out (cls_dbg_words_out)
    );

    // --- fast 路由: P3 TCP 链 (tcp_rx → tcp_echo → tcp_tx_frame) ---
    wire [63:0] pay_tdata;
    wire [7:0]  pay_tkeep;
    wire        pay_tvalid, pay_tready, pay_tlast;
    wire [1:0]  pay_tuser;
    wire        pay_fend, pay_ferr;
    wire        pay_meta_valid;
    wire [31:0] pay_meta_src_ip;
    wire [15:0] pay_meta_src_port;
    wire [15:0] pay_meta_len;
    wire [3:0]  pay_meta_conn_id;
    wire [31:0] pay_meta_seq;

    wire [63:0] eco_tdata;
    wire [7:0]  eco_tkeep;
    wire        eco_tvalid, eco_tready, eco_tlast;
    wire [3:0]  eco_tid;

    // P4b-7-P6: echo -> tx_frame 流水寄存器总线 (拆 frame_fifo RAMB -> csum 临界路径)
    wire [63:0] eco2_tdata;
    wire [7:0]  eco2_tkeep;
    wire        eco2_tvalid, eco2_tready, eco2_tlast;
    wire [3:0]  eco2_tid;
    wire [76:0] eco2_pack;
    assign {eco2_tkeep, eco2_tlast, eco2_tdata, eco2_tid} = eco2_pack;

    // ---- P5: 新增跨模块线网先声明 (app_ctrl 实例在前引用) ----
    // echo frame_fifo 指针 (P4c: AW=13 -> 14 位含绕回位; app RX 占用换算用)
    wire [13:0] eco_dbg_fifo_wptr, eco_dbg_fifo_rptr;
    // ---- P5b C9: 状态行观测源 (两种构建都声明 — 由 tcp_tx_frame 输出驱动,
    //      默认构建无消费者) ----
    wire [31:0] tx_stat_ack_w, tx_stat_ack_drop_w;
    wire [2:0]  tx_dbg_state;   // tcp_tx_frame FSM state (P4/P5 诊断共用)
    // ---- P5c-T3 G3: abort fence 线束 (tcp_tx_frame.o_rst_sent -> app_ctrl) ----
    // **两种构建都声明**: u_tcp_tx 在两种构建里都例化 (它的 .o_rst_sent 必须接一
    // 根真网线 — 否则会隐式造出 1 位网线并丢掉高 15 位); 默认构建无消费者
    // (app_ctrl 不存在) ⇒ 仅空置, 与上面 tx_stat_ack_w 同惯例。声明必须在
    // u_app_ctrl / u_tcp_tx 两个实例之前 (P5a 教训: 用前必须声明)。
    wire [15:0] tx_rst_sent;
`ifdef APP_MODE
    // P5: app RX 缓冲占用 (echo frame_fifo 字节数; 17 位 = 8192 字 x 8)
    wire [16:0] app_rx_occ = {(eco_dbg_fifo_wptr - eco_dbg_fifo_rptr), 3'b0};
    // ---- P5b: 流控闭环跨模块线网 (先声明后使用; u_app_ctrl 在下面几百行) ----
    // ① 窗口纠偏写 (app_ctrl -> TCB 写口第 4 级仲裁)
    wire        fc_upd_wr;
    wire [3:0]  fc_upd_id;
    wire [2:0]  fc_upd_sel;
    wire [31:0] fc_upd_val;
    wire        fc_gnt;
    // ② 窗口更新 ACK 请求 (app_ctrl -> tcp_tx_frame 的 ackq 条目)
    wire        app_wu_req, app_wu_gnt;
    wire [3:0]  app_wu_id;
    wire [31:0] app_wu_val;
    // ③ 状态行 (C9) 观测源
    wire [15:0] app_winq0, app_wu_mark0;
    wire [16:0] app_pool;
    wire [31:0] app_stat_wu, app_stat_pool_exh;
    wire [31:0] app_stat_slot_reuse;   // C18 观测 (未接状态行; 寄存器读 0x9E 可见)
`endif
    // tcb 组合读口 C (app_ctrl 轮扫源; 默认模式恒读 0 号条目, 无副作用)
    wire [3:0]  rc_id;
    wire [31:0] rc_snd_nxt, rc_snd_una, rc_rcv_nxt;
    wire [15:0] rc_rcv_wnd, rc_snd_wnd;
    wire [3:0]  rc_state;
    // slow_cfg_adp 连接事件源 (ADD 收尾 / DEL state=0 授权拍脉冲 + 保持字段)
    wire        scfg_ev_up, scfg_ev_down;
    wire [3:0]  scfg_ev_slot;
    wire [31:0] scfg_ev_peer_ip;
    wire [15:0] scfg_ev_peer_port;
    wire [47:0] scfg_ev_peer_mac;

    // ---- P5: app 接口 (AXIS 数据面) 连线 ----
    // APP_MODE: echo 输出 (= 零拷贝 app RX) 给 app_pattern 校验器; app TX 经
    // axis_pipe 进 tcp_tx_frame (下面 txin_* 选择)。默认 (未定义 APP_MODE):
    // txin_* = eco2_* / eco2_tready = tcp_tx_frame.s_axis_tready — 与 P4 逐位
    // 相同 (仅是线名重命名)。
    wire [63:0] txin_tdata;
    wire [7:0]  txin_tkeep;
    wire        txin_tvalid, txin_tready, txin_tlast;
    wire [3:0]  txin_tid;
`ifdef APP_MODE
    wire [63:0] app_rx_tdata  = eco2_tdata;
    wire [7:0]  app_rx_tkeep  = eco2_tkeep;
    wire        app_rx_tvalid = eco2_tvalid;
    wire        app_rx_tready;
    wire        app_rx_tlast  = eco2_tlast;
    wire [3:0]  app_rx_tid    = eco2_tid;
    assign eco2_tready = app_rx_tready;

    wire [63:0] app_tx_tdata, app2_tdata;
    wire [7:0]  app_tx_tkeep, app2_tkeep;
    wire        app_tx_tvalid, app_tx_tready, app_tx_tlast;
    wire        app2_tvalid, app2_tready, app2_tlast;
    wire [3:0]  app_tx_tid, app2_tid;
    wire [76:0] app2_pack;
    assign {app2_tkeep, app2_tlast, app2_tdata, app2_tid} = app2_pack;
    assign txin_tdata  = app2_tdata;
    assign txin_tkeep  = app2_tkeep;
    assign txin_tvalid = app2_tvalid;
    assign txin_tlast  = app2_tlast;
    assign txin_tid    = app2_tid;
    // u_app_pipe 的 m_ready = tcp_tx_frame.s_axis_tready (= txin_tready):
    // 必须由此处驱动 (P5a 复核 W1 — 原先误写成 assign app_tx_tready =
    // app2_tready, 既与 u_app_pipe.s_ready 抢同一根线 (组合自环 DRC),
    // 又让 app 侧 tready 退化成 m_ready (丢了 axis_pipe 的 !m_valid 背压 ⇒
    // 流水寄存器还压着字时 app 再推一个字 = 丢字)。
    assign app2_tready = txin_tready;

    wire [15:0] app_tx_ready;
    wire [7:0]  app_reg_addr;
    wire        app_reg_wr;
    wire [31:0] app_reg_wdata, app_reg_rdata;
    wire [15:0] app_fin_req, app_rst_req, app_fin_sent;
    wire        app_ev_up, app_ev_down;
    wire [3:0]  app_ev_slot;
    wire        app_close_req;
    wire [3:0]  app_close_id;
    wire [3:0]  app_led;
    wire [31:0] app_tx_bytes, app_tx_frames, app_rx_bytes, app_mismatch;
    wire        app_uart_txd;
    // app_ctrl 状态线束 (免跨模块层次引用; 合成器不支持层次引用)
    wire [3:0]  app_c0_state;
    wire [31:0] app_c0_snd_nxt, app_c0_snd_una, app_c0_rcv_nxt;
    wire [15:0] app_c0_rcv_wnd, app_estab_cnt, app_ev_cnt;
    wire [31:0] app_ev_drop;

    // =====================================================================
    // P5d H-fix: 接受裕度 ACC_MARGIN 按 ESTAB 连接数**动态缩**
    // ---------------------------------------------------------------------
    //   [C12 绑定行] N<=2 (单/双连接门与板级默认配置) 时 .ACC_MARGIN = 16'd4096
    //   —— 即旧常量的值, 逐位零回归。N>=3 的动态值见下表 (新门 sim/p5d_multi
    //   独立断言 + 负向对照; 本行是 tools/gen_stim_p5_adv.py 的 check_phys_margin
    //   文本解析目标, 勿删勿改数值 —— 它明令"解析失败 = FAIL"且不在允许改动清单内)。
    //
    // [为什么] N 条连接共享**同一个** 64KB 零拷贝 frame_fifo (tcp_echo) ⇒ 物理界:
    //     Σwinq + N*ACC_MARGIN + Δ(2816) + U(1518) + SEG_MAX(1500) <= 65536
    //   各项来源:
    //     Σwinq    <= WIN_POOL = 49152  (D4 分池后由构造保证, 见 app_ctrl 的 wq_cap_r)
    //     Δ = 2816 = ackq 深 x 每 ACK 帧拍数 x 到达率 (规格 C1b 的 1G Δ 上界)
    //     U = 1518 = 未判定帧 (54 + 1460 + 4)
    //     SEG_MAX = 1500 = 一个段可整段被接受 (win_ok 只看段起始 seq ⇒ 越界量 <= plen-1)
    //   ⇒ N*ACC_MARGIN <= 65536 - 49152 - 2816 - 1518 - 1500 = **10550**
    //   ⇒ ACC_MARGIN <= 10550/N:  N=1/2/3 ⇒ 10550 / 5275 / **3516**
    //   (旧实现硬传 4096: N=3 时 3*4096 = 12288 > 10550 ⇒ 超 **1738 B** ⇒ frame_fifo
    //    满 ⇒ 上游 mac_rx 丢整帧 = 破坏 P5b "零丢字节" 承诺。旧门没有一条能抓:
    //    adv multi 只有 2 条连接且 conn1 winq=0 的注入是脚本无条件灌的 150B。)
    //
    // [下界钳位] ACC_MARGIN >= 3328 = Δ(2816) + 512 余量。低于它 = 接受界覆盖不了
    //   通告漂移 ⇒ 对端按旧右沿合法发出的段被判窗外 ⇒ 静默丢弃 + 等 200ms RTO
    //   (C16-修订 要消掉的板级病理, 实测漂移最大 308B)。10550/N < 3328 即 N>=4 时
    //   钳到 3328 —— **本设计的支持包线就是 N<=3** (HLS MAX_TCP_CONN=3; 且 N>=4 时
    //   N*3328 = 13312 > 10550 ⇒ 物理界与漂移下界不可能同时满足, 不是本 fix 能救的)。
    //
    // [为什么查表 + 寄存器, 不做除法] acc_wnd = ra_rcv_wnd + ACC_MARGIN 直接进
    //   tcp_rx **w5 拍的关键判据** (win_ok -> acc/ackresp/drop)。32 位除法或多级
    //   比较串进去就是又一条长组合链 (P5b 坑 12: 组合算术串链 = WNS -3.089 的教训)。
    //   这里: 输入只有 ESTAB 数 (app_ctrl.dbg_estab_cnt, 每 256 拍刷新一次, 本身
    //   就是 c_state[] 的与); 表只有 3 项 (N<=2 / N=3 / N>=4) ⇒ 一级 LUT;
    //   输出再**打一拍寄存器**才进 tcp_rx ⇒ 接受界只多一个加法器输入 (常量变寄存器
    //   输入), 不加深 win_ok 链。引脚/参数都不新增 (0 新顶层端口)。
    // 动态缩的语义边界: 连接数变化 → 裕度在 1 拍内跟着变; 已通告的窗口不受影响
    //   (本裕度只放宽**接受判据**, 不改变通告值 ⇒ 与 D4 的"窗口不可撤销"无冲突)。
    // =====================================================================
    function [15:0] acc_margin_of;
        input [4:0] n;                      // ESTAB 连接数 (0 按 1 处理)
        begin
            if (n <= 5'd2)      acc_margin_of = 16'd4096;   // min(4096, 10550/n) = 4096
            else if (n == 5'd3) acc_margin_of = 16'd3516;   // 10550/3 = 3516.67 -> 3516
            else                acc_margin_of = 16'd3328;   // 10550/n < 3328 ⇒ 钳下界
        end
    endfunction
    wire [4:0]  acc_margin_n   = (app_estab_cnt[4:0] == 5'd0) ? 5'd1 : app_estab_cnt[4:0];
    reg  [15:0] acc_margin_eff;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) acc_margin_eff <= 16'd4096;    // 复位 = N<=2 值 (零回归)
        else          acc_margin_eff <= acc_margin_of(acc_margin_n);
    end

    app_pattern #(.TX_BYTES(32'd1048576), .TX_SEGSZ(12'd1460)) u_app (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .ev_up          (app_ev_up),
        .ev_down        (app_ev_down),
        .ev_slot        (app_ev_slot),
        .m_tdata        (app_tx_tdata),
        .m_tkeep        (app_tx_tkeep),
        .m_tvalid       (app_tx_tvalid),
        .m_tready       (app_tx_tready),
        .m_tlast        (app_tx_tlast),
        .m_tid          (app_tx_tid),
        .app_tx_ready   (app_tx_ready),
        .close_req      (app_close_req),
        .close_id       (app_close_id),
        .rx_tdata       (app_rx_tdata),
        .rx_tkeep       (app_rx_tkeep),
        .rx_tvalid      (app_rx_tvalid),
        .rx_tready      (app_rx_tready),
        .rx_tlast       (app_rx_tlast),
        .rx_tid         (app_rx_tid),
        .i_bad_frame    (16'd0),          // 故障注入仅 TB 用 (板级恒关)
        .stat_tx_bytes  (app_tx_bytes),
        .stat_tx_frames (app_tx_frames),
        .stat_rx_bytes  (app_rx_bytes),
        .stat_mismatch  (app_mismatch),
        .active         (),
        .act_id         (),
        .done           (),
        .dbg_lfsr       (),
        .led            (app_led)
    );

    axis_pipe #(.W(77)) u_app_pipe (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_data         ({app_tx_tkeep, app_tx_tlast, app_tx_tdata, app_tx_tid}),
        .s_valid        (app_tx_tvalid),
        .s_ready        (app_tx_tready),
        .m_data         (app2_pack),
        .m_valid        (app2_tvalid),
        .m_ready        (app2_tready)
    );

    app_ctrl #(.WIN_CAP(WIN_CAP_5)) u_app_ctrl (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .ev_up          (scfg_ev_up),
        .ev_down        (scfg_ev_down),
        .ev_slot        (scfg_ev_slot),
        .ev_peer_ip     (scfg_ev_peer_ip),
        .ev_peer_port   (scfg_ev_peer_port),
        .ev_peer_mac    (scfg_ev_peer_mac),
        .rc_id          (rc_id),
        .rc_snd_nxt     (rc_snd_nxt),
        .rc_snd_una     (rc_snd_una),
        .rc_rcv_nxt     (rc_rcv_nxt),
        .rc_rcv_wnd     (rc_rcv_wnd),
        .rc_snd_wnd     (rc_snd_wnd),
        .rc_state       (rc_state),
        .rx_occ_bytes   (app_rx_occ),
        .fin_sent       (app_fin_sent),
        // P5c-T3 G3: RST 已发出 (abort fence) — 非 ESTAB/未发 RST 时为 0
        .rst_sent       (tx_rst_sent),
        .o_ev_up        (app_ev_up),
        .o_ev_down      (app_ev_down),
        .o_ev_slot      (app_ev_slot),
        .fin_req        (app_fin_req),
        .rst_req        (app_rst_req),
        // P5b: 窗口纠偏写 (第 4 级仲裁) + 窗口更新 ACK 请求
        .fc_upd_wr      (fc_upd_wr),
        .fc_upd_id      (fc_upd_id),
        .fc_upd_sel     (fc_upd_sel),
        .fc_upd_val     (fc_upd_val),
        .fc_gnt         (fc_gnt),
        .wu_req         (app_wu_req),
        .wu_id          (app_wu_id),
        .wu_val         (app_wu_val),
        .wu_gnt         (app_wu_gnt),
        .close_req      (app_close_req),
        .close_id       (app_close_id),
        .reg_addr       (app_reg_addr),
        .reg_wr         (app_reg_wr),
        .reg_wdata      (app_reg_wdata),
        .reg_rdata      (app_reg_rdata),
        .app_tx_ready   (app_tx_ready),
        .stat_ev_up     (),
        .stat_ev_down   (),
        .stat_ev_drop   (app_ev_drop),
        .stat_cmd_close (),
        .stat_cmd_abort (),
        .dbg_c0_state   (app_c0_state),
        .dbg_c0_snd_nxt (app_c0_snd_nxt),
        .dbg_c0_snd_una (app_c0_snd_una),
        .dbg_c0_rcv_nxt (app_c0_rcv_nxt),
        .dbg_c0_rcv_wnd (app_c0_rcv_wnd),
        .dbg_c0_snd_wnd (),
        .dbg_estab_cnt  (app_estab_cnt),
        .dbg_ev_cnt     (app_ev_cnt),
        // P5b: 流控观测 (状态行 C9)
        .dbg_redge0     (),
        .dbg_winq0      (app_winq0),
        .dbg_wu_mark0   (app_wu_mark0),
        .dbg_pool       (app_pool),
        .stat_wu        (app_stat_wu),
        .stat_pool_exhaust (app_stat_pool_exh),
        .stat_slot_reuse   (app_stat_slot_reuse)
    );

    // P5 寄存器总线默认静止 (板级无 CPU/AXI; 将来接 AXI-Lite 桥)
    assign app_reg_addr  = 8'h00;
    assign app_reg_wr    = 1'b0;
    assign app_reg_wdata = 32'd0;

    // ---- P5f: app_status_uart 新增的 UDP app 观测输入源 ----
    // 声明必须**先于**下面的例化: xvlog 先声明后用, 后声明会被判
    // "already implicitly declared" 硬错 (坑 22 同族); 更坏的变体是静默 1 位
    // 隐式线 (坑 24 —— 高位全 Z 且所有传统检查都不报)。
    // 默认构建里这两组是"已声明未用" (零网表影响, 同原有 app_udp_stat_* 状态)。
    wire [31:0] udpapp_tx_bytes, udpapp_tx_frames, udpapp_rx_bytes, udpapp_rx_frames;
    wire [31:0] udpapp_rx_null, udpapp_mismatch;
    wire        udpapp_active, udpapp_done;
    wire [3:0]  udpapp_led;

    wire [31:0] app_udp_stat_frames, app_udp_stat_bytes, app_udp_stat_null,
                app_udp_stat_drop_crc, app_udp_stat_drop_ovf,
                app_udp_stat_drop_part, app_udp_stat_drop_excl,
                app_udp_stat_hls_frames, app_udp_stat_hls_drop,
                app_udp_stat_hls_split;
    app_status_uart u_app_status (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .st0            (app_c0_state),
        .snd_nxt        (app_c0_snd_nxt),
        .snd_una        (app_c0_snd_una),
        .rcv_wnd        (app_c0_rcv_wnd),
        .rcv_nxt        (app_c0_rcv_nxt),
        .stat_rx_bytes  (app_rx_bytes),
        .stat_tx_bytes  (app_tx_bytes),
        .stat_tx_frames (app_tx_frames[15:0]),
        .stat_mismatch  (app_mismatch[15:0]),
        .rx_occ         (app_rx_occ),
        .ev_cnt         (app_ev_cnt),
        .ev_drop        (app_ev_drop[15:0]),
        .app_tx_ready   (app_tx_ready),
        .estab_cnt      (app_estab_cnt),
        // W5: 板级可观测计数 (FIN 是否发出 / 坏帧是否被丢)
        .stat_drop_len  (tx_stat_drop_len[15:0]),
        .stat_fin       (tx_stat_fin[15:0]),
        .stat_rst       (tx_stat_rst[15:0]),
        // P5b C9: 流控闭环观测 (ACK 计数 / 窗口 / 信用池)
        .stat_ack       (tx_stat_ack_w[15:0]),
        .stat_ack_drop  (tx_stat_ack_drop_w[15:0]),
        .fsm_state      (tx_dbg_state),   // C9: 复用已有 dbg_state 线, 不加新端口
        .winq0          (app_winq0),
        .wu_mark0       (app_wu_mark0),
        .stat_wu        (app_stat_wu[15:0]),
        .pool           (app_pool),
        .stat_pool_exh  (app_stat_pool_exh[15:0]),
        // P5f: UDP app 通路板级观测 (P5e 缺口: 这 8 根线此前只接 LED 或悬空,
        // PC→板 方向的校验结果与全部丢帧计数在板上**读不出来**)。
        // 默认构建 (无 APP_MODE) 恒接常数 ⇒ 与 P4 逐位等价 (新增端口常量)。
`ifdef APP_MODE
        .udp_rx_bytes   (udpapp_rx_bytes),
        .udp_mismatch   (udpapp_mismatch),
        .udp_rx_frames  (udpapp_rx_frames[15:0]),
        .udp_drop_ovf   (app_udp_stat_drop_ovf[15:0]),
        .udp_drop_crc   (app_udp_stat_drop_crc[15:0]),
        .udp_drop_part  (app_udp_stat_drop_part[15:0]),
        .udp_tx_bytes   (udpapp_tx_bytes),
        .udp_tx_frames  (udpapp_tx_frames[15:0]),
`else
        .udp_rx_bytes   (32'd0),
        .udp_mismatch   (32'd0),
        .udp_rx_frames  (16'd0),
        .udp_drop_ovf   (16'd0),
        .udp_drop_crc   (16'd0),
        .udp_drop_part  (16'd0),
        .udp_tx_bytes   (32'd0),
        .udp_tx_frames  (16'd0),
`endif
        .txd            (app_uart_txd)
    );
`else
    // P5d H-fix (默认构建支): 接受裕度恒 0 ⇒ acc_wnd = {1'b0, ra_rcv_wnd}, 与旧
    // 参数版 (ACC_MARGIN=16'd0) **逐位等价** (P4 矩阵 16 门是证据)。这里声明成
    // 常量而不是 APP_MODE 支那个寄存器 —— 默认构建零新增寄存器/零新增逻辑。
    wire [15:0] acc_margin_eff = 16'd0;
    assign txin_tdata  = eco2_tdata;
    assign txin_tkeep  = eco2_tkeep;
    assign txin_tvalid = eco2_tvalid;
    assign txin_tlast  = eco2_tlast;
    assign txin_tid    = eco2_tid;
    assign eco2_tready = txin_tready;
`endif

    wire [63:0] tx_tdata;
    wire [7:0]  tx_tkeep;
    wire        tx_tvalid, tx_tready, tx_tlast;
    wire [31:0] tx_stat_frames, tx_stat_bytes, tx_stat_abort;
    wire [31:0] tx_stat_retx;    // P4b-7: 重传回卷计数 (暂留内部 wire, LED 后议)
    wire        tx_retx_req;     // P4b-7 P3: dup-ACK 快速重传 tcp_rx -> tcp_tx_frame
    wire [3:0]  tx_retx_id;
    wire        tx_retx_gnt;

    wire [31:0] rx_stat_pass, rx_stat_nonmatch, rx_stat_ipcsum, rx_stat_crc,
                rx_stat_seq, rx_stat_ack, rx_stat_bytes_tcp;
    wire [31:0] eco_stat_echo, eco_stat_drop_crc;
    // P4b-7-P6 调试探针 (冻结态 LED 观测; tcp_tx_frame/tcp_echo 纯 assign 引出)
    wire        tx_dbg_wnd_open, tx_dbg_pay_full, tx_dbg_sready;
    wire        tx_dbg_saxis_tvalid;
    wire [11:0] tx_dbg_plen_r;
    // P4b-7-P6: u_fifo 载荷 FIFO 指针/标志 + RUNNING plen (报 FULL 而单帧 183 字)
    wire [8:0]  tx_dbg_pay_wptr, tx_dbg_pay_rptr;
    wire        tx_dbg_pay_full2, tx_dbg_pay_empty;
    wire [11:0] tx_dbg_plen;
    wire        eco_dbg_fifo_full;
    // P4b-7-P6 tlast 三计数 (TW/TF/TI; tlast 死于哪一级的定位探针)
    wire [31:0] eco_dbg_tlast_wr, eco_dbg_tlast_fwd;   // tcp_echo 写/转发末拍数
    wire [31:0] tx_dbg_tlast_in;                       // tcp_tx_frame 吞到末拍数
    // P4b-7-P6 UART 全精度读出: tx FSM state (纯 assign) + tcb conn0 阵列快照
    wire [31:0] dbg_snd_nxt0, dbg_snd_una0, dbg_rcv_nxt0;
    wire [15:0] dbg_snd_wnd0;
    wire [3:0]  dbg_wscale0, dbg_state0;
    // P4b-7-P6 诊断: RX 侧冻结位点 (tcp_rx/tcp_echo/frame_fifo 纯 assign 引出)
    wire [2:0]  rx_dbg_state;
    wire        rx_dbg_accept, rx_dbg_emitv;
    // P4b-7-P6 RX-TRACE: RX emit 侧探针 (tcp_rx 纯 assign 新增口)
    wire        rx_dbg_emit_l, rx_dbg_fend;
    wire [15:0] rx_dbg_pay_r, rx_dbg_pcount2;
    // P4b-7-P6 三站词计数 (UART 行尾 MW/CW/RW 字段 + RXT 条目 [26:24] wcnt):
    //   MW = mac_rx_64 出词, CWin/CWout = rx_classify 进/出词, RW = tcp_rx 进词,
    //   WC = tcp_rx wcnt (头字计数器 — 与 w2_r 长度锁存同步性同拍可读)
    wire [31:0] rx_dbg_words_in;
    wire [2:0]  rx_dbg_wcnt;
    // P4b-7-P6 追加: RX 帧判读锁存/原始 total_len + 丢弃·通过计数
    //   (UART 行尾 RXPL/RXPC/RXT/DROPS/PASS; plen_l 腐败 => over-length 守卫
    //    帧中段 S_DROP 断尾 => TX 永久等 tlast)
    wire [15:0] rx_dbg_plen_l, rx_dbg_pcount, rx_dbg_w2_tlen;
    wire [31:0] rx_dbg_drop_seq, rx_dbg_drop_crc;
    wire [31:0] rx_dbg_drop_nonmatch, rx_dbg_drop_ipcsum, rx_dbg_drop_trunc, rx_dbg_pass;
    wire [2:0]  eco_dbg_state;
    wire        eco_dbg_fifo_empty;
    // P4c: frame_fifo 8192 字 (AW=13) -> 指针 14 位 (含回卷位), 地址低 13 位;
    // uart_dbg 侧吃 [12:0] (WPT/RPT 4 位 hex 显示字段), 占用差用全宽算。
    // P4b-7-P6 TL: echo frame_fifo 边存组合读口 (dbg_line_tx 驱动读址, 上游边存
    // LUTRAM 直出该址值; bit8 = tlast)。UART 快照/TR 行之后 8 行 tlast 位图转储。
    // P4c: 读址 13 位 (AW=13, 与 frame_fifo dbg_rd_addr 同宽, 直连不再补位)
    wire [12:0] eco_dbg_fifo_tladdr;
    wire [8:0]  eco_dbg_fifo_tlside;
    // P4b-7-P6: u_eco_pipe 握手观测线 (纯 debug 别名, 零逻辑)
    wire        pipe_mv = eco2_tvalid;  // pipe m_valid (tx 帧器输入侧)
    wire        pipe_sv = eco_tvalid;   // pipe s_valid (echo 输出侧)

    // ---- P4b-7-P6 TRACE: 冻结拍前后 beat 级 64 拍环 (64 x 24b) ----
    // 每拍写一条 (addr 0..63 回卷, 与 write 同拍推进), 内容 = 本拍 echo→pipe→
    // tcp_tx_frame 全握手链 + 帧内进度。触发 = 与 UART 快照锁存同一事件:
    // 首次 RTO 回卷 (tx_stat_retx != 0) => trace_frozen=1, 环自下拍起停写;
    // 写门 = !trace_frozen, 故最后一条写下的样本 = tx_stat_retx 首次非零被采到
    // 的那拍 (svc 回卷拍的下 1 拍)。旧 stall 探测器 (tcp_tx_frame 停 S_RECV 且
    // tvalid=1/tready=0 连续 1000 拍) 已废: 正常流量里的瞬态 8us 停顿就能提前
    // 锁存, 64 条全是健康流 (tlast=1) — 与真冻结无关, 无用。
    // 回卷点深在真冻结内 (回卷拍 TX FSM 为 S_IDLE, 输入侧恒定 tvalid=1/tready=0
    // — tready 仅 S_RECV 拍有效), 故环内 64 条 = 回卷拍 (含) 及其前 63 拍冻结态
    // (tvalid=1, tready=0, tlast=0, accept=0, tx_dbg_state=0=S_IDLE)。
    // 停写后 trace_waddr = 下一写址 = 环内最老条目址; UART 在快照行后附 4 行
    // TR= 转储全 64 条 (字序/时间轴语义见 uart_dbg.v 头注释)。
    // 条目位布局 [23:0]:
    //   [23:21] tx_dbg_state  tcp_tx_frame FSM state (0 = S_IDLE, 1 = S_RECV)
    //   [20]    pipe_mv       u_eco_pipe m_valid (= eco2_tvalid, 帧器输入侧)
    //   [19]    pipe_sv       u_eco_pipe s_valid (= eco_tvalid, echo 输出侧)
    //   [18]    tx tvalid     tcp_tx_frame s_axis_tvalid
    //   [17]    tx tready     tcp_tx_frame s_axis_tready
    //   [16]    echo tlast    tcp_echo m_axis_tlast (pipe 之前, eco_tlast 原线)
    //   [15]    tx accept     s_axis_tvalid && s_axis_tready (本拍帧器真吞拍)
    //   [14:0]  echo fifo 占用 (wptr-rptr) 低 15 位 (帧内进度; 堵死态恒值)
    wire        tx_dbg_accept = tx_dbg_saxis_tvalid && tx_dbg_sready;
    wire [15:0] eco_dbg_occ   = {2'b0, eco_dbg_fifo_wptr} - {2'b0, eco_dbg_fifo_rptr};
    wire [23:0] trace_entry   = {tx_dbg_state, pipe_mv, pipe_sv,
                                 tx_dbg_saxis_tvalid, tx_dbg_sready,
                                 eco_tlast, tx_dbg_accept, eco_dbg_occ[14:0]};
    wire          trace_rewind = (tx_stat_retx != 32'd0);  // 首次 RTO 回卷 (同 snap 锁存)
    reg           trace_frozen;  // 一次性: 回卷即锁, 环停写
    reg  [5:0]    trace_waddr;   // 下一写址 (冻结后恒值 = 最老条目址)
    reg  [1535:0] trace_mem;     // 展平环 ([24*addr +: 24], 无复位 — 写满 64 拍即全有效)
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            trace_frozen <= 1'b0;
            trace_waddr  <= 6'd0;
        end else begin
            trace_frozen <= trace_rewind;
            if (!trace_frozen) begin
                trace_mem[24*trace_waddr +: 24] <= trace_entry;
                trace_waddr <= trace_waddr + 6'd1;
            end
        end
    end

    // ---- P4b-7-P6 RX-TRACE: RX 帧尾异常拍前后 64 拍环 (64 x 24b, 快照行后
    //      4 行 RXT= 转储) ----
    // 与 TX 环同构但触发/域不同: TX 环抓"TX 侧冻结拍模式" (回卷), RX 环抓
    // **帧尾词计数异常拍** — fend 拍 pcount 落后 plen_l 超 4 字节 (≥5 字节
    // 载荷字未入账)。1460B 帧正常 fend 时 pcount = 1458 = plen_l-2, 差值恒
    // 2; 超出说明本帧的 S_PAY 计数链丢拍 (accept 拍被吞/emit 阻塞漏计) →
    // pay_r 偏大 → 尾分支误走 S_TAIL 溢出支 (emit_l=0, 帧边界不发) → 与下帧
    // 合并成 ~262 词无尽帧 (TL 位图实锤: 尾 tlast 就在 rptr 前 5 词)。
    // 触发 = 组合脉冲 (fend 只 1 拍) 故冻结用 sticky OR 一次性锁存; 写门
    // = !rx_trace_frozen, 与 TX 环同 — 触发拍本身仍被写入, 故环内最新条目
    // (g=62) = 触发拍, 其后全部冻结前历史可逐拍对账 pay_r/pcount 何时错位。
    // 条目位布局 [26:0] (27 位; RXT 行按 7 位 hex 转储, 最高位 hex 数字 = wcnt):
    //   [26:24] rx_dbg_wcnt    tcp_rx 头字计数器 wcnt (0..6 = 帧头第几字,
    //                          7 = 载荷/尾段已开始) — 与 w2_r 长度锁存同拍可读:
    //                          头字错位/重读旧值时 wcnt 轨迹立即显出错拍
    //   [23]    pad 0          (旧版 [23] pad 原址保留, 字段整体上移 3 位)
    //   [22:20] rx_dbg_state   tcp_rx FSM state (0=S_HDR 1=S_PAY 2=S_PAD
    //                          3=S_DROP 4=S_TAIL)
    //   [19]    dbg_emit_v     emit_v (载荷输出字挂起)
    //   [18]    dbg_emit_l     m_axis_tlast (本拍挂起字的帧尾位 — 帧边界生死)
    //   [17]    dbg_accept     tvalid && tready (本拍 RX 真吞源字)
    //   [16]    echo tready    !echo frame_fifo full (= tcp_rx 下游 tready,
    //                          tcp_echo s_axis_tready 恒 = !fifo_full)
    //   [15:12] pay_r[3:0]     TLAST 拍剩余载荷字节低 4 位 (0/1..6 = 简单尾支
    //                          emit_l=1; 7/8 = 溢出尾支 S_TAIL; 4 位够分辨)
    //   [11:0]  pcount[11:0]   帧内已累计载荷字节 (≤1500, 12 位无损)
    wire [26:0] rx_trace_entry = {rx_dbg_wcnt, 1'b0, rx_dbg_state, rx_dbg_emitv,
                                  rx_dbg_emit_l, rx_dbg_accept,
                                  ~eco_dbg_fifo_full,
                                  rx_dbg_pay_r[3:0], rx_dbg_pcount2[11:0]};
    // P4b-7-P6 板测修正: plen_l==0 (纯 ACK/填充帧) 不触发 — 旧触发器把纯 ACK
    // 误判为异常 (pcount=0 < 0-4), RXTR 环/WL 锁存被 72 字节 ACK 帧污染
    wire        rx_trace_rewind = rx_dbg_fend && (rx_dbg_plen_l != 16'd0) &&
                                  (rx_dbg_pcount2 < (rx_dbg_plen_l - 16'd4));
    reg         rx_trace_frozen;  // 一次性: 帧尾计数异常即锁 (sticky), 环停写
    reg  [5:0]  rx_trace_waddr;   // 下一写址 (冻结后恒值 = 环内最老条目址)
    reg  [1727:0] rx_trace_mem;   // 展平环 ([27*addr +: 27], 无复位 — 写满 64 拍全有效)
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            rx_trace_frozen <= 1'b0;
            rx_trace_waddr  <= 6'd0;
        end else begin
            // sticky: 触发是 1 拍脉冲 (fend), 非电平 — 不能直接赋值
            rx_trace_frozen <= rx_trace_frozen | rx_trace_rewind;
            if (!rx_trace_frozen) begin
                rx_trace_mem[27*rx_trace_waddr +: 27] <= rx_trace_entry;
                rx_trace_waddr <= rx_trace_waddr + 6'd1;
            end
        end
    end

    // ---- P4b-7-P6-P6b: WL 异常触发拍锁存 (gmii_clk 域, 与 RX 环冻结同拍;
    //      diag18: 同域直锁, 废除 phy1_rxc 2 级同步) ----
    // 触发判据 (fend && pcount < plen_l-4) 在帧尾后若干拍生效 (mac_rx/classify/
    // tcp_rx 流水延迟), 此时 wl_last 已是本帧线上字节数 (帧间保持, 无背靠背
    // 异常帧时即目标帧); sticky 首次锁存, 与环冻结同拍。
    reg [15:0] wl_last_lat;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            wl_last_lat <= 16'd0;
        end else if (rx_trace_rewind && !rx_trace_frozen) begin
            wl_last_lat <= wl_last;
        end
    end

    wire [3:0]  ra_id;
    wire [31:0] ra_rcv_nxt, ra_snd_nxt, ra_snd_una;
    wire [15:0] ra_rcv_wnd;
    wire [3:0]  ra_state;
    wire [3:0]  ra_wscale;
    // P4d-fix: tcp_tx_frame 回卷会话高水位/活性 -> tcp_rx ack_ok 上界
    // (纯线束: 会话期 ack 上界 = retx_hi 而非回卷后 snd_nxt, 见 tcp_rx 注释)
    wire [31:0] tx_retx_hi;
    wire        tx_retx_active;
    wire [3:0]  rb_id;
    wire [31:0] rb_rcv_nxt, rb_snd_nxt, rb_snd_una;
    wire [15:0] rb_rcv_wnd, rb_snd_wnd;
    wire [3:0]  rb_state;
    // P4b-7-P6: tcb 注册窗口读口 -> tcp_tx_frame 门控 (win_id = rb_id 同一条线)
    // P4b-7-P6-fix: win_open = 注册 32 位回绕正确门 (替代已废 win_hi_eq)
    wire        win_open;
    wire [15:0] win_inflight;
    wire [15:0] win_wnd_eff;
`ifndef APP_MODE
    assign rc_id = 4'd0;      // 默认模式无消费者 (APP_MODE 下由 u_app_ctrl 驱动)
`endif

    // TCB 更新仲裁输出 (tx > rx > cfg) — 显式先声明再供 u_tcb 使用
    // (wrapper_tcp.v 的先使用后声明靠 Vivado 宽容过关, xvlog 直接报错)
    wire        tcb_wr;
    wire [3:0]  tcb_id;
    wire [2:0]  tcb_sel;
    wire [31:0] tcb_val;

    wire        rx_upd_wr, rx_upd_gnt;
    wire [3:0]  rx_upd_id;
    wire [2:0]  rx_upd_sel;
    wire [31:0] rx_upd_val;
    wire        tx_upd_wr;
    wire [3:0]  tx_upd_id;
    wire [2:0]  tx_upd_sel;
    wire [31:0] tx_upd_val;

    wire        rx_ack_req;
    wire [3:0]  rx_ack_id;
    wire [31:0] rx_ack_val;

    wire        syn_v;
    wire [47:0] syn_smac;
    wire [31:0] syn_sip;
    wire [15:0] syn_sport, syn_dport;
    wire [31:0] syn_seq;
    wire [15:0] syn_wnd;

    // ---- P4b: tcp_synp 已废除 (正式握手归慢路径 HLS) — CAM/TCB 配置 =
    // slow_cfg_adp (解析 HLS cfg_stream 记录); syn_v sideband 端口留空 ----
    wire        scfg_cam_wr;
    wire [3:0]  scfg_cam_addr;
    wire [31:0] scfg_cam_sip, scfg_cam_dip;
    wire [15:0] scfg_cam_sport, scfg_cam_dport;
    wire [47:0] scfg_cam_dmac;
    wire        scfg_upd_wr;
    wire [3:0]  scfg_upd_id;
    wire [2:0]  scfg_upd_sel;
    wire [31:0] scfg_upd_val;
    wire        scfg_gnt;
    wire [31:0] scfg_stat_add, scfg_stat_del;
    wire [31:0] hls_cfg_tdata;      // P4b: 连接配置记录通道 (先声明后使用)
    wire        hls_cfg_tvalid, hls_cfg_tready;
    wire        hls_rst_n;          // 看门狗 (slow_rx_adp): HLS 饥饿超时复位
    wire [21:0] srx_dbg_starv;      // diag18 看门狗饥饿累计 (UART SV 字段)

    wire [31:0] cam_q_sip, cam_q_dip;
    wire [15:0] cam_q_sport, cam_q_dport;
    wire        cam_q_hit;
    wire [3:0]  cam_q_id;
    wire [3:0]  cam_rd_id;
    wire [47:0] cam_rd_dmac;
    wire [31:0] cam_rd_sip, cam_rd_dip;
    wire [15:0] cam_rd_sport, cam_rd_dport;

    tcp_rx u_tcp_rx (
        // P5d H-fix: 接受裕度按 ESTAB 数动态缩 (推导见上面的 H-fix 块)。
        // N<=2 时 = 16'd4096 (旧常量, 逐位零回归); N=3 时 3516; N>=4 钳 3328。
        // 默认构建 (acc_margin_eff = 16'd0) ⇒ acc_wnd = ra_rcv_wnd ⇒ 逐位不变。
        .ACC_MARGIN     (acc_margin_eff),
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (f_tdata),
        .s_axis_tkeep   (f_tkeep),
        .s_axis_tvalid  (f_tvalid),
        .s_axis_tready  (f_tready),
        .s_axis_tlast   (f_tlast),
        .s_axis_tuser   (f_tuser),
        .s_axis_tcrs    (f_tcrs),
        .s_axis_terr    (f_terr),
        .cfg_suppress_data_ack(!APP_EN),// P4c ACK-early 实验裁决 (echo 模式板级回退 1):
                                        // suppress=0 板测 28.4Mbps < 124Mbps —
                                        // TX 帧率翻倍使 PC 网卡线级截断帧 (TRU=32)
                                        // 与 FPGA->PC 线丢 (缺陷 A) 触发率翻倍,
                                        // PC RTO 停发 77% 时间吃掉全部理论收益。
                                        // RTL w6a 修复 (纯 ACK 窗口内接受) 保留;
                                        // TB 保持 suppress=0 验证 ACK 路径全功能。
                                        // P5: APP_EN=1 (app 模式) 时强制 0 — 无 echo
                                        // 捎带, 逐段纯 ACK; P5a-0 实验用合成对端复测该配置
        .m_axis_tdata   (pay_tdata),
        .m_axis_tkeep   (pay_tkeep),
        .m_axis_tvalid  (pay_tvalid),
        .m_axis_tready  (pay_tready),
        .m_axis_tlast   (pay_tlast),
        .m_axis_tuser   (pay_tuser),
        .fend           (pay_fend),
        .ferr           (pay_ferr),
        .meta_valid     (pay_meta_valid),
        .meta_src_ip    (pay_meta_src_ip),
        .meta_src_port  (pay_meta_src_port),
        .meta_len       (pay_meta_len),
        .meta_conn_id   (pay_meta_conn_id),
        .meta_seq       (pay_meta_seq),
        .ra_id          (ra_id),
        .ra_rcv_nxt     (ra_rcv_nxt),
        .ra_snd_nxt     (ra_snd_nxt),
        .ra_snd_una     (ra_snd_una),
        .ra_rcv_wnd     (ra_rcv_wnd),
        .ra_state       (ra_state),
        .ra_wscale      (ra_wscale),
        .ra_retx_hi     (tx_retx_hi),
        .ra_retx_active (tx_retx_active),
        .upd_wr         (rx_upd_wr),
        .upd_id         (rx_upd_id),
        .upd_sel        (rx_upd_sel),
        .upd_val        (rx_upd_val),
        .upd_gnt        (rx_upd_gnt),
        .ack_req        (rx_ack_req),
        .ack_id         (rx_ack_id),
        .ack_val        (rx_ack_val),
        .retx_req       (tx_retx_req),
        .retx_id        (tx_retx_id),
        .retx_gnt       (tx_retx_gnt),
        .syn_v          (syn_v),
        .syn_smac       (syn_smac),
        .syn_sip        (syn_sip),
        .syn_sport      (syn_sport),
        .syn_dport      (syn_dport),
        .syn_seq        (syn_seq),
        .syn_wnd        (syn_wnd),
        .cam_q_sip      (cam_q_sip),
        .cam_q_dip      (cam_q_dip),
        .cam_q_sport    (cam_q_sport),
        .cam_q_dport    (cam_q_dport),
        .cam_q_hit      (cam_q_hit),
        .cam_q_id       (cam_q_id),
        .stat_pass          (rx_stat_pass),
        .stat_drop_nonmatch (rx_stat_nonmatch),
        .stat_drop_ipcsum   (rx_stat_ipcsum),
        .stat_drop_crc      (rx_stat_crc),
        .stat_drop_seq      (rx_stat_seq),
        .stat_ack           (rx_stat_ack),
        .stat_bytes         (rx_stat_bytes_tcp),
        .dbg_state          (rx_dbg_state),
        .dbg_accept         (rx_dbg_accept),
        .dbg_emitv          (rx_dbg_emitv),
        .dbg_plen_l         (rx_dbg_plen_l),
        .dbg_pcount         (rx_dbg_pcount),
        .dbg_w2_tlen        (rx_dbg_w2_tlen),
        .dbg_stat_drop_seq  (rx_dbg_drop_seq),
        .dbg_stat_drop_crc  (rx_dbg_drop_crc),
        .dbg_stat_drop_nonmatch (rx_dbg_drop_nonmatch),
        .dbg_stat_drop_ipcsum   (rx_dbg_drop_ipcsum),
        .dbg_stat_drop_trunc    (rx_dbg_drop_trunc),
        .dbg_stat_pass      (rx_dbg_pass),
        // P4b-7-P6 RX-TRACE: emit 侧探针 (RXT 环条目)
        .dbg_emit_l         (rx_dbg_emit_l),
        .dbg_pay_r          (rx_dbg_pay_r),
        .dbg_pcount2        (rx_dbg_pcount2),
        .dbg_fend           (rx_dbg_fend),
        // P4b-7-P6 三站词计数 (第 2 站) + 头字计数器 (RXT 条目 [26:24])
        .dbg_stat_words_in  (rx_dbg_words_in),
        .dbg_wcnt           (rx_dbg_wcnt)
    );

    tcp_echo u_tcp_echo (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (pay_tdata),
        .s_axis_tkeep   (pay_tkeep),
        .s_axis_tvalid  (pay_tvalid),
        .s_axis_tready  (pay_tready),
        .s_axis_tlast   (pay_tlast),
        .s_axis_tuser   (pay_tuser),
        .fend           (pay_fend),
        .ferr           (pay_ferr),
        .meta_valid     (pay_meta_valid),
        .meta_conn_id   (pay_meta_conn_id),
        .meta_len       (pay_meta_len),
        .m_axis_tdata   (eco_tdata),
        .m_axis_tkeep   (eco_tkeep),
        .m_axis_tvalid  (eco_tvalid),
        .m_axis_tready  (eco_tready),
        .m_axis_tlast   (eco_tlast),
        .m_axis_tid     (eco_tid),
        .stat_echo      (eco_stat_echo),
        .stat_drop_crc  (eco_stat_drop_crc),
        .stat_tlast_wr  (eco_dbg_tlast_wr),
        .stat_tlast_fwd (eco_dbg_tlast_fwd),
        .dbg_fifo_full  (eco_dbg_fifo_full),
        .dbg_state      (eco_dbg_state),
        .dbg_fifo_empty (eco_dbg_fifo_empty),
        .dbg_fifo_wptr  (eco_dbg_fifo_wptr),
        .dbg_fifo_rptr  (eco_dbg_fifo_rptr),
        .dbg_rd_addr    (eco_dbg_fifo_tladdr),     // P4c: [12:0] 直连 (AW=13)
        .dbg_rd_side    (eco_dbg_fifo_tlside)
    );

    // ---- P4b-7-P6: tcp_echo -> tcp_tx_frame 1-deep 全速流水寄存器 (拆临界
    //     路径: tcp_echo u_fifo RAMB36E1 -> u_csum acc; 77b = tkeep+last+data+tid) ----
    axis_pipe #(.W(77)) u_eco_pipe (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_data         ({eco_tkeep, eco_tlast, eco_tdata, eco_tid}),
        .s_valid        (eco_tvalid),
        .s_ready        (eco_tready),
        .m_data         (eco2_pack),
        .m_valid        (eco2_tvalid),
        .m_ready        (eco2_tready)
    );

    tcp_cam u_cam (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .cfg_wr         (scfg_cam_wr),
        .cfg_addr       (scfg_cam_addr),
        .cfg_sip        (scfg_cam_sip),
        .cfg_dip        (scfg_cam_dip),
        .cfg_sport      (scfg_cam_sport),
        .cfg_dport      (scfg_cam_dport),
        .cfg_dmac       (scfg_cam_dmac),
        .q_sip          (cam_q_sip),
        .q_dip          (cam_q_dip),
        .q_sport        (cam_q_sport),
        .q_dport        (cam_q_dport),
        .q_id           (cam_q_id),
        .q_hit          (cam_q_hit),
        .rd_id          (cam_rd_id),
        .rd_dmac        (cam_rd_dmac),
        .rd_sip         (cam_rd_sip),
        .rd_dip         (cam_rd_dip),
        .rd_sport       (cam_rd_sport),
        .rd_dport       (cam_rd_dport)
    );

    tcb #(.WIN_CAP(WIN_CAP_5)) u_tcb (   // = tcp_tx_frame.RING_CAP (同源 localparam)
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        // P5: 组合读口 C (app_ctrl 轮扫; 默认模式消费者不存在, 无副作用)
        .rc_id          (rc_id),
        .rc_snd_nxt     (rc_snd_nxt),
        .rc_snd_una     (rc_snd_una),
        .rc_rcv_nxt     (rc_rcv_nxt),
        .rc_rcv_wnd     (rc_rcv_wnd),
        .rc_snd_wnd     (rc_snd_wnd),
        .rc_state       (rc_state),
        .ra_id          (ra_id),
        .ra_rcv_nxt     (ra_rcv_nxt),
        .ra_snd_nxt     (ra_snd_nxt),
        .ra_snd_una     (ra_snd_una),
        .ra_rcv_wnd     (ra_rcv_wnd),
        .ra_snd_wnd     (),
        .ra_state       (ra_state),
        .ra_wscale      (ra_wscale),
        .rb_id          (rb_id),
        .rb_rcv_nxt     (rb_rcv_nxt),
        .rb_snd_nxt     (rb_snd_nxt),
        .rb_snd_una     (rb_snd_una),
        .rb_rcv_wnd     (rb_rcv_wnd),
        .rb_snd_wnd     (rb_snd_wnd),
        .rb_state       (rb_state),
        .win_id         (rb_id),
        .win_open       (win_open),
        .win_inflight   (win_inflight),
        .win_wnd_eff    (win_wnd_eff),
        .dbg_snd_nxt0   (dbg_snd_nxt0),
        .dbg_snd_una0   (dbg_snd_una0),
        .dbg_rcv_nxt0   (dbg_rcv_nxt0),
        .dbg_snd_wnd0   (dbg_snd_wnd0),
        .dbg_wscale0    (dbg_wscale0),
        .dbg_state0     (dbg_state0),
        .upd_wr         (tcb_wr),
        .upd_id         (tcb_id),
        .upd_sel        (tcb_sel),
        .upd_val        (tcb_val)
    );

    // ---- TCB 更新仲裁 (组合, tx > rx > cfg 级; cfg 级 = slow_cfg_adp, 带 gnt) ----
    // P5b C5: APP_MODE 追加第 4 级 fc (窗口纠偏写), **最低**优先级 (在 cfg 之下)。
    // 硬约束: scfg_gnt 表达式逐字不变 (cfg 语义/时序逐位不变是 P5b 的硬门);
    // 原三级式也逐字保留在 `else 支 (默认构建源文本不变 ⇒ 逐位等价)。
    wire        sel_tx = tx_upd_wr;
    wire        sel_rx = !sel_tx && rx_upd_wr;
    assign rx_upd_gnt = sel_rx;
    assign scfg_gnt   = !sel_tx && !sel_rx && scfg_upd_wr;  // cfg 级授权: 空即给
`ifdef APP_MODE
    // sel_fc: fc 请求 (app_ctrl 电平 + gnt 握手) 只有在 tx/rx/cfg 三级都没请求时
    // 才落地。mux 链里 scfg 的选择条件用 scfg_upd_wr (不是 scfg_gnt) 保持与原来
    // 等价 —— 原式 `sel_tx ? tx : sel_rx ? rx : scfg` 在 sel_tx||sel_rx 时 scfg
    // 分支不可达, 加 fc 后同理 (前两支已覆盖)。
    wire        sel_fc = !sel_tx && !sel_rx && !scfg_upd_wr && fc_upd_wr;
    assign tcb_wr  = sel_tx || sel_rx || (scfg_upd_wr && scfg_gnt) || sel_fc;
    assign tcb_sel = sel_tx ? tx_upd_sel : (sel_rx ? rx_upd_sel :
                     (scfg_upd_wr ? scfg_upd_sel : fc_upd_sel));
    assign tcb_id  = sel_tx ? tx_upd_id  : (sel_rx ? rx_upd_id  :
                     (scfg_upd_wr ? scfg_upd_id  : fc_upd_id));
    assign tcb_val = sel_tx ? tx_upd_val : (sel_rx ? rx_upd_val :
                     (scfg_upd_wr ? scfg_upd_val : fc_upd_val));
    assign fc_gnt  = sel_fc;
`else
    assign tcb_wr  = sel_tx || sel_rx || (scfg_upd_wr && scfg_gnt);
    assign tcb_sel = sel_tx ? tx_upd_sel : (sel_rx ? rx_upd_sel : scfg_upd_sel);
    assign tcb_id  = sel_tx ? tx_upd_id  : (sel_rx ? rx_upd_id  : scfg_upd_id);
    assign tcb_val = sel_tx ? tx_upd_val : (sel_rx ? rx_upd_val : scfg_upd_val);
`endif

    // ---- SYN 应答器已拆除 (P4b 慢路径 HLS 正式握手) — slow_cfg_adp ----
    // P4b-4 审查 finding: rst_n 必须跟 HLS 看门狗复位 — HLS 被 hls_rst_n
    // 复位时若 8 词记录写一半 (FIFO 残留 1..7 词), 解析会永久错位
    // (垃圾记录误开/误删连接)。同拍复位清 FIFO/state/wcnt。
    slow_cfg_adp u_slow_cfg (
        .clk            (gmii_clk),
        .rst_n          (reset_n & hls_rst_n),
        .s_axis_tdata   (hls_cfg_tdata),
        .s_axis_tvalid  (hls_cfg_tvalid),
        .s_axis_tready  (hls_cfg_tready),
        .cam_cfg_wr     (scfg_cam_wr),
        .cam_cfg_addr   (scfg_cam_addr),
        .cam_cfg_sip    (scfg_cam_sip),
        .cam_cfg_dip    (scfg_cam_dip),
        .cam_cfg_sport  (scfg_cam_sport),
        .cam_cfg_dport  (scfg_cam_dport),
        .cam_cfg_dmac   (scfg_cam_dmac),
        .upd_wr         (scfg_upd_wr),
        .upd_id         (scfg_upd_id),
        .upd_sel        (scfg_upd_sel),
        .upd_val        (scfg_upd_val),
        .cfg_gnt        (scfg_gnt),
        .stat_add       (scfg_stat_add),
        .stat_del       (scfg_stat_del),
        // P5: 连接事件源 (纯加输出; 默认模式无消费者)
        .ev_up          (scfg_ev_up),
        .ev_down        (scfg_ev_down),
        .ev_slot        (scfg_ev_slot),
        .ev_peer_ip     (scfg_ev_peer_ip),
        .ev_peer_port   (scfg_ev_peer_port),
        .ev_peer_mac    (scfg_ev_peer_mac)
    );

    // ---- TX ACK: synp 已拆除, 仅 tcp_rx 的 ACK 请求 (P4b 握手 SYN+ACK 由
    //      HLS 慢路径直接发出, 不走 fast TX) ----
    // P5: 合并结构留好 (ACK 优先级 rx > fin/rst push)。本阶段 fin_push/rst_push
    // 恒 0 (FIN/RST 由 tcp_tx_frame 自己按 fin_req/rst_req 扫描排队, 不需要
    // app 侧推 ACK 条目); P5c/P5d 若需即时推送再驱动这两根线。
    wire        fin_push = 1'b0;
    wire        rst_push = 1'b0;
    // P5b: wu **不并入** tx_ack_req — 走 tcp_tx_frame 的专用 wu_req/wu_gnt 口
    // (C7 修正版: wu 条目在 ackq 内是最低优先级, 且 wu_gnt 必须与"条目确实入队"
    //  严格等价)。若把 wu 并进 ack_req: ① ack_req 在 ackq_din 里最高优先 ⇒ wu
    // 会盖过 fin_repush (违反 C7 "FIN 重推不可被抢"); ② tcp_tx_frame 的
    // wu_push 恒假 ⇒ wu_gnt 恒 0 ⇒ app_ctrl 的 wu_pend 永不清 ⇒ 每拍都推一条
    // wu 值的 ACK (ACK 风暴); ③ 电平请求在 ackq 满时每拍给 stat_ack_drop 计数
    // (观测污染)。三条都致命, 故此处只用专用口。
    wire        tx_ack_req = rx_ack_req | fin_push | rst_push;
    wire [3:0]  tx_ack_id  = rx_ack_id;
    wire [31:0] tx_ack_val = rx_ack_val;
    wire        tx_ack_syn = 1'b0;
    wire        tx_ack_fin = 1'b0;
    wire        tx_ack_rst = 1'b0;
    // P5: FIN/RST 请求源 (APP_MODE = app_ctrl; 默认 = 恒 0, P4 行为不变)
    wire [15:0] tx_fin_req, tx_rst_req, tx_fin_sent;
    wire [31:0] tx_stat_drop_len, tx_stat_fin, tx_stat_rst;
    wire [3:0]  tx_retx_id_o;
    // P5b: wu 通道 (默认构建 = 常量 0 ⇒ 逐位等价; APP_MODE = app_ctrl)
    wire        app_wu_req_t, app_wu_gnt_t;
    wire [3:0]  app_wu_id_t;
    wire [31:0] app_wu_val_t;
`ifdef APP_MODE
    assign tx_fin_req = app_fin_req;
    assign tx_rst_req = app_rst_req;
    assign app_fin_sent = tx_fin_sent;
    assign app_wu_req_t = app_wu_req;
    assign app_wu_id_t  = app_wu_id;
    assign app_wu_val_t = app_wu_val;
    assign app_wu_gnt   = app_wu_gnt_t;
`else
    assign tx_fin_req = 16'h0;
    assign tx_rst_req = 16'h0;
    assign app_wu_req_t = 1'b0;
    assign app_wu_id_t  = 4'd0;
    assign app_wu_val_t = 32'd0;
`endif

    tcp_tx_frame #(.RING_CAP(WIN_CAP_5)) u_tcp_tx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (txin_tdata),
        .s_axis_tkeep   (txin_tkeep),
        .s_axis_tvalid  (txin_tvalid),
        .s_axis_tready  (txin_tready),
        .s_axis_tlast   (txin_tlast),
        .s_axis_tid     (txin_tid),
        .ack_req        (tx_ack_req),
        .ack_id         (tx_ack_id),
        .ack_val        (tx_ack_val),
        .ack_syn        (tx_ack_syn),
        // P5: FIN/RST 通道 (APP_MODE 由 app_ctrl 驱动; 默认模式恒 0 =
        // 与 P4 逐位相同)
        .ack_fin        (tx_ack_fin),
        .ack_rst        (tx_ack_rst),
        .fin_req        (tx_fin_req),
        .rst_req        (tx_rst_req),
        // P5a 复核 D1 修复: cfg ADD 收尾脉冲 -> 清该槽 FIN/RST 已发标志
        // (背靠背 DEL→ADD 同槽重连时, 扫描路径采不到 state=0, 会永久卡死连接)
        .cfg_up         (scfg_ev_up),
        .cfg_up_id      (scfg_ev_slot),
        // P5b: 窗口更新 (wu) 条目通道 (app_ctrl; 默认模式无此模块 ⇒ 见 `else)
        .wu_req         (app_wu_req_t),
        .wu_id          (app_wu_id_t),
        .wu_val         (app_wu_val_t),
        .wu_gnt         (app_wu_gnt_t),
        .o_fin_sent     (tx_fin_sent),
        // P5c-T3 G3: abort fence (RST 已发出) -> u_app_ctrl.rst_sent
        // (声明在 P5 前置线网块; 默认构建无消费者 ⇒ 空接也可能, 但显式接线
        //  保证两个构建的端口表一致 — C12)
        .o_rst_sent     (tx_rst_sent),
        .o_retx_id      (tx_retx_id_o),
        .rb_id          (rb_id),
        .rb_snd_nxt     (rb_snd_nxt),
        .rb_rcv_nxt     (rb_rcv_nxt),
        .rb_rcv_wnd     (rb_rcv_wnd),
        .rb_snd_una     (rb_snd_una),
        .rb_snd_wnd     (rb_snd_wnd),
        .rb_state       (rb_state),
        .win_open       (win_open),
        .win_inflight   (win_inflight),
        .win_wnd_eff    (win_wnd_eff),
        .upd_wr         (tx_upd_wr),
        .upd_id         (tx_upd_id),
        .upd_sel        (tx_upd_sel),
        .upd_val        (tx_upd_val),
        .cam_rd_id      (cam_rd_id),
        .cam_rd_dmac    (cam_rd_dmac),
        .cam_rd_sip     (cam_rd_sip),
        .cam_rd_sport   (cam_rd_sport),
        .cam_rd_dport   (cam_rd_dport),
        .cfg_src_mac    (48'h000A3501FEC0),  // 00:0A:35:01:FE:C0 (P4 统一 HLS MAC)
        .cfg_src_ip     (32'hC0A86402),      // 192.168.100.2
        .m_axis_tdata   (tx_tdata),
        .m_axis_tkeep   (tx_tkeep),
        .m_axis_tvalid  (tx_tvalid),
        .m_axis_tready  (tx_tready),
        .m_axis_tlast   (tx_tlast),
        .stat_frames    (tx_stat_frames),
        .stat_bytes     (tx_stat_bytes),
        // P5b C9: ACK 计数补全 (板级病理定位缺观测: ACK 发没发/丢没丢)
        .stat_ack       (tx_stat_ack_w),
        .stat_ack_drop  (tx_stat_ack_drop_w),
        .stat_eend      (),
        .stat_drop_len  (tx_stat_drop_len),
        .stat_fin       (tx_stat_fin),
        .stat_rst       (tx_stat_rst),
        .stat_tlast_in  (tx_dbg_tlast_in),
        .retx_req       (tx_retx_req),
        .retx_id        (tx_retx_id),
        .retx_gnt       (tx_retx_gnt),
        .stat_retx      (tx_stat_retx),
        .o_retx_hi      (tx_retx_hi),
        .o_retx_active  (tx_retx_active),
        .dbg_wnd_open   (tx_dbg_wnd_open),
        .dbg_pay_full   (tx_dbg_pay_full),
        .dbg_sready     (tx_dbg_sready),
        .dbg_saxis_tvalid (tx_dbg_saxis_tvalid),
        .dbg_plen_r     (tx_dbg_plen_r),
        .dbg_state      (tx_dbg_state),
        .dbg_pay_wptr   (tx_dbg_pay_wptr),
        .dbg_pay_rptr   (tx_dbg_pay_rptr),
        .dbg_pay_full2  (tx_dbg_pay_full2),
        .dbg_pay_empty  (tx_dbg_pay_empty),
        .dbg_plen       (tx_dbg_plen)
    );

    // --- slow 路由: slow_rx_adp → udp_echo (HLS) → slow_tx_adp ---
    //          + udp_echo.cfg_stream (P4b) → slow_cfg_adp → CAM/TCB
    wire [15:0] hls_rx_tdata;
    wire        hls_rx_tvalid, hls_rx_tready;
    wire [15:0] hls_tx_tdata;
    wire        hls_tx_tvalid, hls_tx_tready;
    wire [15:0] hls_msg_tdata;
    wire        hls_msg_tvalid;
    wire [31:0] srx_stat_commit, srx_stat_drop;
    wire [63:0] stx_tdata;
    wire [7:0]  stx_tkeep;
    wire        stx_tvalid, stx_tready, stx_tlast;
    wire [31:0] stx_stat_frames, stx_stat_purge;

    // ---- P5e-T1: slow 路由出口 (classify.m_slow → slow_rx_adp) 重命名 ----
    // 默认构建 (未定义 APP_MODE): srx_* 是 s_* 的纯线名别名, s_tready 直接来自
    // u_slow_rx ⇒ 与 P4 逐位相同 (同 txin_* 的既有手法, 仅重命名)。
    // APP_MODE: classify.slow → u_udp_split → ①透传口 → slow_rx_adp (非 app-UDP
    // 帧逐字保真) ②帧缓冲 → app UDP RX 口。
    wire [63:0] srx_tdata;
    wire [7:0]  srx_tkeep;
    wire        srx_tvalid, srx_tlast, srx_tuser, srx_tcrs, srx_terr;
    wire        srx_tready;          // u_slow_rx 的 s_axis_tready (恒 1)
    // app UDP RX 口 + 统计 (APP_MODE 才有消费者; 默认构建无引用)
    wire [63:0] app_udp_rx_tdata;
    wire [7:0]  app_udp_rx_tkeep;
    wire        app_udp_rx_tvalid, app_udp_rx_tlast, app_udp_rx_sof;
    wire [15:0] app_udp_rx_len, app_udp_rx_src_port;
    wire [31:0] app_udp_rx_src_ip;
`ifdef APP_MODE
    // =====================================================================
    // P5e-T1: UDP 分流 shim (接收侧)
    // ---------------------------------------------------------------------
    // 约束来源 (决定性实验 sim/p5e_pre): 慢口一停, 反压经 classify 打到
    // mac_rx_64 的 8 字共享 FIFO ⇒ 连累 fast TCP 帧丢. 故本 shim 的
    // s_axis_tready 结构性恒 1 (输入只进 16 深预取 FIFO; 装不下丢整帧不回压),
    // 详见 rtl/udp_split.v 头注释 (缓冲选择 + 反压合同的完整论证)。
    //
    // 配置 (P5e-T3 起由 T1 的全哨兵改为**精确匹配 app 端口**):
    //   cfg_dst_ip = 本板 IP (192.168.100.2, 与 udp_tx_cfg.cfg_my_ip 同源)
    //   cfg_port0  = UDP_APP_PORT (8081); port1..3 保持 0xFFFF 未配置哨兵
    //     (**不能用 0: 0 是合法端口**); cfg_port_any = 0 (不做全收)。
    //   排他: HLS 的 udp_echo 端口 8080 由 udp_split.EXCL_PORT 参数排除 (且它不在
    //   cfg_port0..3 里) ⇒ HLS 的 echo 帧永远留给慢路径。
    //   未配置端口/未匹配 dst_ip 的 UDP 帧仍逐字走慢路径 (T1 的透明性性质)。
    //   cfg_multi_en = 0: 只收单播到本板 IP 的帧 (组播行情是 10G 阶段的课题;
    //   置 1 即额外放行 dst_ip[31:28]==E 的组播, 一行可切)。
    // app_rx_tready = app_udp_rx_tready (P5e-T3: 真 app 消费者 = app_udp_pattern
    //   的逐字节校验器)。它是**真反压** (每字 8 拍), 但上游是帧级 store-and-forward
    //   + 4KB 帧缓冲 ⇒ 反压停在缓冲里, 永不到 mac_rx (T1 的"绝不反压"合同不破)。
    // =====================================================================
    // T3: RX 学习事件线束 (udp_split 的 meta 输出口 → udp_tx_cfg 的 peer 表写口)。
    // 声明必须在两个例化点之前 (xvlog 先声明后用; 坑 8: 漏声明 = 隐式 1 位线 +
    // 静默截断, multi/driv 检查抓不到 —— T2 已实测踩过)。
    wire        udp_meta_valid;
    wire [47:0] udp_meta_src_mac;
    wire [31:0] udp_meta_src_ip;
    wire [15:0] udp_meta_src_port, udp_meta_len;
    wire        app_udp_rx_tready;   // app UDP RX 口反压 (→ udp_split.app_rx_tready)
    // UDP app 端口 (8080 留给 HLS udp_echo — 见 udp_split.EXCL_PORT=8080 的排除)
    // 声明在两个 APP_MODE 块之前: udp_split 例化与 udp_tx_cfg 例化都要用。
    localparam [15:0] UDP_APP_PORT = 16'h1F91;   // 8081
    udp_split u_udp_split (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (s_tdata),
        .s_axis_tkeep   (s_tkeep),
        .s_axis_tvalid  (s_tvalid),
        .s_axis_tready  (s_tready),      // → classify.m_slow_tready (恒 1)
        .s_axis_tlast   (s_tlast),
        .s_axis_tuser   (s_tuser),
        .s_axis_tcrs    (s_tcrs),
        .s_axis_terr    (s_terr),
        .p_axis_tdata   (srx_tdata),
        .p_axis_tkeep   (srx_tkeep),
        .p_axis_tvalid  (srx_tvalid),
        .p_axis_tready  (srx_tready),    // 来自 u_slow_rx (恒 1, 契约)
        .p_axis_tlast   (srx_tlast),
        .p_axis_tuser   (srx_tuser),
        .p_axis_tcrs    (srx_tcrs),
        .p_axis_terr    (srx_terr),
        .app_rx_tdata   (app_udp_rx_tdata),
        .app_rx_tkeep   (app_udp_rx_tkeep),
        .app_rx_tvalid  (app_udp_rx_tvalid),
        .app_rx_tready  (app_udp_rx_tready),  // ← app_udp_pattern 的校验器
        .app_rx_tlast   (app_udp_rx_tlast),
        .app_rx_sof     (app_udp_rx_sof),
        .app_rx_len     (app_udp_rx_len),
        .app_rx_src_ip  (app_udp_rx_src_ip),
        .app_rx_src_port(app_udp_rx_src_port),
        // P5e-T3: RX 学习事件 (learn-on-RX 的**唯一** peer 源; 见 udp_tx_cfg 段)
        .meta_valid     (udp_meta_valid),
        .meta_src_mac   (udp_meta_src_mac),
        .meta_src_ip    (udp_meta_src_ip),
        .meta_src_port  (udp_meta_src_port),
        .meta_len       (udp_meta_len),
        .cfg_dst_ip     (32'hC0A86402),  // 192.168.100.2 = 本板 IP
        .cfg_multi_en   (1'b0),
        .cfg_port0      (UDP_APP_PORT), .cfg_port1(16'hFFFF),
        .cfg_port2      (16'hFFFF),     .cfg_port3(16'hFFFF),
        .cfg_port_any   (1'b0),
        .stat_app_frames(app_udp_stat_frames),
        .stat_app_bytes (app_udp_stat_bytes),
        .stat_app_null  (app_udp_stat_null),
        .stat_drop_crc  (app_udp_stat_drop_crc),
        .stat_drop_ovf  (app_udp_stat_drop_ovf),
        .stat_drop_part (app_udp_stat_drop_part),
        .stat_drop_excl (app_udp_stat_drop_excl),
        .stat_hls_frames(app_udp_stat_hls_frames),
        .stat_hls_drop  (app_udp_stat_hls_drop),
        .stat_hls_split (app_udp_stat_hls_split)
    );
`else
    assign srx_tdata = s_tdata;      // 纯别名 (默认构建逐位不变)
    assign srx_tkeep = s_tkeep;
    assign srx_tvalid= s_tvalid;
    assign srx_tlast = s_tlast;
    assign srx_tuser = s_tuser;
    assign srx_tcrs  = s_tcrs;
    assign srx_terr  = s_terr;
    assign s_tready  = srx_tready;   // 原路径: classify 慢口 tready = slow_rx_adp
`endif

    slow_rx_adp u_slow_rx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (srx_tdata),
        .s_axis_tkeep   (srx_tkeep),
        .s_axis_tvalid  (srx_tvalid),
        .s_axis_tready  (srx_tready),
        .s_axis_tlast   (srx_tlast),
        .s_axis_tuser   (srx_tuser),
        .s_axis_tcrs    (srx_tcrs),
        .s_axis_terr    (srx_terr),
        .hls_rx_tdata   (hls_rx_tdata),
        .hls_rx_tvalid  (hls_rx_tvalid),
        .hls_rx_tready  (hls_rx_tready),
        .hls_rst_n      (hls_rst_n),
        .stat_commit    (srx_stat_commit),
        .stat_drop      (srx_stat_drop),
        .dbg_starv      (srx_dbg_starv),
        .dbg_hls_rst    ()
    );

    // HLS 慢路径协议栈 (udp_hls_10g/hls 副本综合, P4b 版: cfg_stream +
    // 限次重传; ap_ctrl_none; 看门狗 hls_rst_n 脉冲复位; reset_n 软复位必接)
    udp_echo u_hls (
        .ap_clk           (gmii_clk),
        .ap_rst_n         (reset_n & hls_rst_n),
        .reset_n          (reset_n & hls_rst_n),
        .rx_stream_TDATA  (hls_rx_tdata),
        .rx_stream_TVALID (hls_rx_tvalid),
        .rx_stream_TREADY (hls_rx_tready),
        .tx_stream_TDATA  (hls_tx_tdata),
        .tx_stream_TVALID (hls_tx_tvalid),
        .tx_stream_TREADY (hls_tx_tready),
        .msg_stream_TDATA (hls_msg_tdata),
        .msg_stream_TVALID(hls_msg_tvalid),
        .msg_stream_TREADY(1'b1),
        .cfg_stream_TDATA (hls_cfg_tdata),
        .cfg_stream_TVALID(hls_cfg_tvalid),
        .cfg_stream_TREADY(hls_cfg_tready),
        .led_d0           (),
        .led_d1           (),
        .led_d2           (),
        .led_d3           ()
    );

    slow_tx_adp u_slow_tx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .hls_tx_tdata   (hls_tx_tdata),
        .hls_tx_tvalid  (hls_tx_tvalid),
        .hls_tx_tready  (hls_tx_tready),
        .m_axis_tdata   (stx_tdata),
        .m_axis_tkeep   (stx_tkeep),
        .m_axis_tvalid  (stx_tvalid),
        .m_axis_tready  (stx_tready),
        .m_axis_tlast   (stx_tlast),
        .stat_frames    (stx_stat_frames),
        .stat_purge     (stx_stat_purge)
    );

    // =====================================================================
    // P5e-T2: UDP app 接口**发送侧** (APP_MODE) — 目标锁存 shim + 帧器 + TX 合流
    // ---------------------------------------------------------------------
    // 优先级声明 (整链, 严格优先级): **TCP fast (u_tx_arb.s_fast) >
    //   UDP app TX (本块 u_tx_udp_arb.s_fast) > HLS 慢路径 (slow_tx_adp)**
    //   · u_tx_arb 原样不动 (它给 TCP 严格优先 = 既有硬约束)。
    //   · 新合流器里 UDP app TX 压 HLS: app 数据面帧是**流式**发出的 (帧内每拍
    //     都依赖下游推进, 载荷 FIFO 只有 256 字), 而 slow_tx_adp 是整帧缓冲
    //     (frame_fifo 512 字, store-and-forward), 被让路不会丢字 —— 优先级给
    //     低延迟者。两个 arb 都是"帧级锁定 + 帧末 1 拍重仲裁", 故 UDP 帧和 HLS
    //     帧都不会被切断 (帧原子性由 arb 的 busy/TLAST 锁定保证)。
    //   · 饿死风险: UDP app 帧 <=1500B (长度守卫), HLS 帧 <=1518B ⇒ 单帧有界,
    //     互不无界阻塞。HLS 侧被压期间其 frame_fifo 若被 HLS 自己写满会走它既有
    //     的 purge 语义 (stat_purge), 与 TCP 压它时同病同治, 不新增病理。
    //
    // **默认不发送 (零回归)**: T2 阶段 wrapper 内没有 app UDP TX 消费者 (T3 的
    //   UDP app 演示才产生帧) ⇒ app_udp_tx_tvalid 恒 0。且即便有人推帧, shim 的
    //   peer 表复位为无效 (o_ready=0) ⇒ 帧被拒在 udp_tx_frame 之前, 线上零新增
    //   (见 rtl/udp_tx_cfg.v 头注释的论证)。两条独立保险。
    //
    // 默认构建 (未定义 APP_MODE, 走 `else 支): mrg_* 是 stx_* 的**纯线名别名**
    //   (同 txin_*/srx_* 的既有手法) ⇒ 与 P4/P5a 逐位等价, 无新增逻辑/寄存器。
    // =====================================================================
    // ---- P5e-T2: TX 合流输出 (slow 口的上游 → u_tx_arb.s_slow_*) ----
    // ⚠️ **必须显式声明** (坑 8 的教科书案例, 本项已实测踩到): 漏声明 ⇒ Verilog
    // 隐式声明成 **1 位** 线 ⇒ 64/8 位连接**静默截断**, 高位 = Z (无驱动)。
    // 症状: mac_tx 收到 Z 填充字 ⇒ cw_len = popc8(Z) = X ⇒ mac_tx 永卡 S_DATA
    // (plen 一路涨), TX 全线死。子模块 TB 全绿、xelab 只有 unconnected 类警告
    // ("implicitly declared" 不在多驱动/未驱动检查里!) ⇒ **只有真 wrapper 全链门
    // (sim/p5e_t2/run_tb_p5e_t2_wrapper.bat) 能抓到**。
    wire [63:0] mrg_tdata;
    wire [7:0]  mrg_tkeep;
    wire        mrg_tvalid, mrg_tready, mrg_tlast;
`ifdef APP_MODE
    // ---- app UDP TX 口 (P5e-T3: 由 app_udp_pattern 驱动; T2 时恒空) ----
    wire [63:0] app_udp_tx_tdata;
    wire [7:0]  app_udp_tx_tkeep;
    wire        app_udp_tx_tvalid, app_udp_tx_tready, app_udp_tx_tlast;
    wire        app_udp_tx_ready;    // 1 = peer 已学习 (app 可推帧)
    // UDP app 演示的统计线束 (板级不可观测, 由 TB/将来状态行读; 不接 = 无消费者)

    // shim → 帧器 → 合流器 内部线 + cfg 锁存线 + 统计
    wire [63:0] utx_tdata, utx2_tdata;
    wire [7:0]  utx_tkeep, utx2_tkeep;
    wire        utx_tvalid, utx_tready, utx_tlast;
    wire        utx2_tvalid, utx2_tready, utx2_tlast;
    wire [47:0] utx_cfg_dst_mac, utx_cfg_src_mac;
    wire [31:0] utx_cfg_dst_ip,  utx_cfg_src_ip;
    wire [15:0] utx_cfg_dst_port, utx_cfg_src_port;
    wire        utx_cfg_csum_en;
    wire [31:0] utx_stat_frames, utx_stat_bytes, utx_stat_drop_len;
    wire [31:0] utx_cfg_frames, utx_cfg_deny;
    wire        utx_busy;            // 帧器非空闲 (cfg 冻结窗口的右边界)

    // =====================================================================
    // P5e-T3: UDP 演示 app (图案发生器 + 图案校验器) — 真消费者接上
    // ---------------------------------------------------------------------
    // TX 数据流: app_udp_pattern.m_* → u_udp_tx_cfg (peer 门 + cfg 锁存) →
    //            u_udp_tx (长度守卫) → u_tx_udp_arb → u_tx_arb → mac_tx_64
    // RX 数据流: mac_rx → classify.slow → u_udp_split.app_rx_* → 本模块校验
    // i_paylen 恒 12'd1472 = app 契约上限 (1518 - 42); 超过由 udp_tx_frame 的
    // PLEN_MAX=1500 守卫兜底 (stat_drop_len)。
    // TX_GAP = **0 (全速)** —— P5f 线速验收口径。原 58000 拍 (~24.7 Mbps) 是按
    // T6 在旧位流上测的"HLS 慢路径天花板 ~25 Mbps"标定的, 而 P5e 之后 app 通路
    // **走 fast path 不经 HLS** ⇒ 该标定不适用 (默认值偏保守)。
    // **行为变更 (已记录)**: 板上默认从"限速演示"变为"学到 peer 后全速发流"
    // (~929 Mbps 载荷 @1472B/帧)。要恢复限速演示只需把本行改回 16'd58000 ——
    // **不新增构建配置** (单参数, 不引入 ifdef)。
    // **默认不激活**: i_en=1 但 i_tx_ready = peer_v = 0 (没收到过对端帧) ⇒ 零帧。
    // =====================================================================
    app_udp_pattern #(.TX_BYTES(32'd0), .TX_GAP(16'd0)) u_app_udp (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .i_en           (1'b1),              // 板级: 演示常使能 (TX 另受 peer 门)
        .i_tx_ready     (app_udp_tx_ready),  // peer 表有效 (learn-on-RX 学到才发)
        .i_paylen       (12'd1472),          // MTU 内最大 UDP 载荷
        .m_tdata        (app_udp_tx_tdata),
        .m_tkeep        (app_udp_tx_tkeep),
        .m_tvalid       (app_udp_tx_tvalid),
        .m_tready       (app_udp_tx_tready),
        .m_tlast        (app_udp_tx_tlast),
        .rx_tdata       (app_udp_rx_tdata),
        .rx_tkeep       (app_udp_rx_tkeep),
        .rx_tvalid      (app_udp_rx_tvalid),
        .rx_tready      (app_udp_rx_tready),
        .rx_tlast       (app_udp_rx_tlast),
        .rx_sof         (app_udp_rx_sof),
        .rx_len         (app_udp_rx_len),
        .stat_tx_bytes  (udpapp_tx_bytes),
        .stat_tx_frames (udpapp_tx_frames),
        .stat_rx_bytes  (udpapp_rx_bytes),
        .stat_rx_frames (udpapp_rx_frames),
        .stat_rx_null   (udpapp_rx_null),
        .stat_mismatch  (udpapp_mismatch),
        .active         (udpapp_active),
        .done           (udpapp_done),
        .led            (udpapp_led)
    );

    udp_tx_cfg u_udp_tx_cfg (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        // 帧器"非空闲"回授: cfg 锁存必须冻结到帧头真正发出 (见 udp_tx_cfg 头注释)
        .frame_busy     (utx_busy),
        // ---- peer 表写口 = **learn-on-RX** (P5e-T3 修复; TL 重新裁决) ----
        // 源 = u_udp_split 的 meta 线束 (= udp_rx 的 meta_*, 匹配帧 w5 接受拍脉冲)。
        // 【为什么换掉 T2 的 scfg_ev_up (慢路径 CONN_UP)】UDP **无连接** ⇒ 板上
        //   永不产生 CONN_UP ⇒ 用 CONN_UP 当学习源等于 peer 表永远空 ⇒ UDP TX
        //   永不激活 (T2 的"默认不发送"在板上退化成"永不发送")。meta_valid 则
        //   在**收到对端任一 app-UDP 帧**时必脉冲 ⇒ 真正的 learn-on-RX。
        // 【单一真值源不变】src_mac/ip 仍是从**收到的帧**里解析出来的 (udp_rx 的
        //   w3/w4 拍寄存), 不新增解析器 (T1 的原则: 不重复实现 RX 判据)。
        // 【端口语义】peer 表只学 MAC/IP; UDP 目标端口是**静态配置** (cfg_dst_port
        //   = 8081) —— 对端的临时端口不是 UDP 语义, 见 udp_tx_cfg 头注释。
        .peer_wr        (udp_meta_valid),
        .peer_mac       (udp_meta_src_mac),
        .peer_ip        (udp_meta_src_ip),
        .cfg_my_mac     (48'h000A3501FEC0),   // P4 统一 MAC (同 tcp_tx_frame)
        .cfg_my_ip      (32'hC0A86402),       // 192.168.100.2
        .cfg_my_port    (UDP_APP_PORT),
        .cfg_dst_port   (UDP_APP_PORT),
        .cfg_csum_en    (1'b1),
        .s_axis_tdata   (app_udp_tx_tdata),
        .s_axis_tkeep   (app_udp_tx_tkeep),
        .s_axis_tvalid  (app_udp_tx_tvalid),
        .s_axis_tready  (app_udp_tx_tready),
        .s_axis_tlast   (app_udp_tx_tlast),
        .m_axis_tdata   (utx_tdata),
        .m_axis_tkeep   (utx_tkeep),
        .m_axis_tvalid  (utx_tvalid),
        .m_axis_tready  (utx_tready),
        .m_axis_tlast   (utx_tlast),
        .o_dst_mac      (utx_cfg_dst_mac),
        .o_dst_ip       (utx_cfg_dst_ip),
        .o_dst_port     (utx_cfg_dst_port),
        .o_src_mac      (utx_cfg_src_mac),
        .o_src_ip       (utx_cfg_src_ip),
        .o_src_port     (utx_cfg_src_port),
        .o_csum_en      (utx_cfg_csum_en),
        .o_ready        (app_udp_tx_ready),
        .stat_frames    (utx_cfg_frames),
        .stat_deny      (utx_cfg_deny)
    );

    udp_tx_frame u_udp_tx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (utx_tdata),
        .s_axis_tkeep   (utx_tkeep),
        .s_axis_tvalid  (utx_tvalid),
        .s_axis_tready  (utx_tready),
        .s_axis_tlast   (utx_tlast),
        .cfg_src_mac    (utx_cfg_src_mac),
        .cfg_dst_mac    (utx_cfg_dst_mac),
        .cfg_src_ip     (utx_cfg_src_ip),
        .cfg_dst_ip     (utx_cfg_dst_ip),
        .cfg_src_port   (utx_cfg_src_port),
        .cfg_dst_port   (utx_cfg_dst_port),
        .cfg_csum_en    (utx_cfg_csum_en),
        .m_axis_tdata   (utx2_tdata),
        .m_axis_tkeep   (utx2_tkeep),
        .m_axis_tvalid  (utx2_tvalid),
        .m_axis_tready  (utx2_tready),
        .m_axis_tlast   (utx2_tlast),
        .stat_frames    (utx_stat_frames),
        .stat_bytes     (utx_stat_bytes),
        .stat_drop_len  (utx_stat_drop_len),
        .o_busy         (utx_busy)
    );

    tx_arb u_tx_udp_arb (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_fast_tdata   (utx2_tdata),
        .s_fast_tkeep   (utx2_tkeep),
        .s_fast_tvalid  (utx2_tvalid),
        .s_fast_tready  (utx2_tready),
        .s_fast_tlast   (utx2_tlast),
        .s_slow_tdata   (stx_tdata),
        .s_slow_tkeep   (stx_tkeep),
        .s_slow_tvalid  (stx_tvalid),
        .s_slow_tready  (stx_tready),
        .s_slow_tlast   (stx_tlast),
        .m_axis_tdata   (mrg_tdata),
        .m_axis_tkeep   (mrg_tkeep),
        .m_axis_tvalid  (mrg_tvalid),
        .m_axis_tready  (mrg_tready),
        .m_axis_tlast   (mrg_tlast)
    );
`else
    // 默认构建: 合流 = 纯别名 (slow_tx_adp 直通 u_tx_arb.s_slow, 与 P4 逐位等价)
    assign mrg_tdata  = stx_tdata;
    assign mrg_tkeep  = stx_tkeep;
    assign mrg_tvalid = stx_tvalid;
    assign mrg_tlast  = stx_tlast;
    assign stx_tready = mrg_tready;
`endif

    // --- TX 仲裁: fast (TCP) 严格优先于 slow ({UDP app TX, HLS} 合流) ---
    wire [63:0] m_tx_tdata;
    wire [7:0]  m_tx_tkeep;
    wire        m_tx_tvalid, m_tx_tready, m_tx_tlast;

    tx_arb u_tx_arb (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_fast_tdata   (tx_tdata),
        .s_fast_tkeep   (tx_tkeep),
        .s_fast_tvalid  (tx_tvalid),
        .s_fast_tready  (tx_tready),
        .s_fast_tlast   (tx_tlast),
        .s_slow_tdata   (mrg_tdata),
        .s_slow_tkeep   (mrg_tkeep),
        .s_slow_tvalid  (mrg_tvalid),
        .s_slow_tready  (mrg_tready),
        .s_slow_tlast   (mrg_tlast),
        .m_axis_tdata   (m_tx_tdata),
        .m_axis_tkeep   (m_tx_tkeep),
        .m_axis_tvalid  (m_tx_tvalid),
        .m_axis_tready  (m_tx_tready),
        .m_axis_tlast   (m_tx_tlast)
    );

    mac_tx_64 u_mac_tx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .s_axis_tdata   (m_tx_tdata),
        .s_axis_tkeep   (m_tx_tkeep),
        .s_axis_tvalid  (m_tx_tvalid),
        .s_axis_tready  (m_tx_tready),
        .s_axis_tlast   (m_tx_tlast),
        .gmii_txd       (e_txd),
        .gmii_tx_en     (e_txen),
        .gmii_tx_er     (e_txer),
        .stat_frames    (),
        .stat_abort     (tx_stat_abort)
    );

    // --- LED 观测 (P4b-7-P6 冻结态探针) ---
    // 板载 LED active-high: 引脚高电平点亮 (k701 demo "1 on, 0 off"; 板上实测
    // 零错误计数 LED 恒灭亦证实 — active-low 则应为恒亮)。故直连不反相:
    // 点亮 = 探针信号为 1。

    // ---- P4b-7-P6 blink readout: event latch + blink encoder (gmii_clk) ----
    // The old watchdog (0.54s of sready=0) also latched at normal test end,
    // so its 4 simultaneous LEDs gave an ambiguous eye read that could not
    // distinguish a true freeze. New trigger is deterministic to the freeze
    // itself: the first RTO rewind (svc_rewind -> tx_stat_retx nonzero,
    // ~100ms into the freeze). A run that never freezes never rewinds ->
    // no latch -> led_d0 keeps showing the live wnd_open probe. Latch value
    // = win-port probes sampled on that same cycle:
    //   latch_val = {wnd_open, 1'b0, (wnd_eff==0), (inflight>=wnd_eff)}
    //   (bit2 was win_hi_eq in P6 — removed with the 64K-boundary fix)
    // Readout (post-latch): led_d1 solid ON = data ready; led_d0 blinks
    // (latch_val+1) times (0.25s on + 0.25s off each), then a 2.0s pause,
    // then repeats. N blinks in a burst = binary value above (N=value+1).
    // led_d2/led_d3 stay live for the whole test.

    // ---- 1) one-shot event latch on the first RTO rewind ----
    // P6 UART: 同拍快照 TCB conn0 全字段 + win 16 位值 (冻结态全精度读出源)
    reg        latched;
    reg [3:0]  latch_val;
    reg [31:0] snap_nxt, snap_una;
    reg [15:0] snap_wnd;
    reg [3:0]  snap_wscale, snap_st;
    reg [15:0] snap_inf, snap_eff;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            latched     <= 1'b0;
            latch_val   <= 4'd0;
            snap_nxt    <= 32'd0; snap_una <= 32'd0; snap_wnd <= 16'd0;
            snap_wscale <= 4'd0;  snap_st   <= 4'd0;
            snap_inf    <= 16'd0; snap_eff  <= 16'd0;
        end else if (!latched && (tx_stat_retx != 32'd0)) begin
            latched   <= 1'b1;               // freeze's first RTO rewind
            latch_val <= {tx_dbg_wnd_open, 1'b0,        // bit2: was win_hi_eq
                          (win_wnd_eff == 16'd0),
                          (win_inflight >= win_wnd_eff)};
            snap_nxt    <= dbg_snd_nxt0;
            snap_una    <= dbg_snd_una0;
            snap_wnd    <= dbg_snd_wnd0;
            snap_wscale <= dbg_wscale0;
            snap_st     <= dbg_state0;
            snap_inf    <= win_inflight;
            snap_eff    <= win_wnd_eff;
        end
    end

    // ---- 2) boot self-test: 3 quick blinks on ALL 4 LEDs after reset ----
    // 0.2s on + 0.2s off per blink x 3 = ~1.2s, active regardless of latch
    // (boot counter overrides the LED mux). If the blinks are not visible
    // the LED polarity is inverted -- report, do not invert.
    localparam [24:0] BOOT_HALF = 25'd25_000_000;   // 0.2s at 125MHz
    reg [24:0] boot_cnt;
    reg        boot_ph;                            // 0 = on half of the blink
    reg [2:0]  boot_h;                             // half index 0..5 (3 blinks)
    wire       boot_act = (boot_h < 3'd6);
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            boot_cnt <= 25'd0;
            boot_ph  <= 1'b0;
            boot_h   <= 3'd0;
        end else if (boot_act) begin
            if (boot_cnt == (BOOT_HALF - 25'd1)) begin
                boot_cnt <= 25'd0;
                boot_ph  <= ~boot_ph;
                boot_h   <= boot_h + 3'd1;
            end else begin
                boot_cnt <= boot_cnt + 25'd1;
            end
        end
    end
    wire boot_on = boot_act && !boot_ph;

    // ---- 3) blink encoder (runs only after latch) ----
    // Half period = 0.25s = 31,250,000 cyc (0x1DCD650, fits 25 bits, exact
    // compare wrap); blk_ph toggles each half. blk_idx = blink slot index;
    // one slot = 0.5s (0.25s on + 0.25s off) for a blink, or one 0.5s pause
    // slot. Blink slots 0..latch_val (N = latch_val+1 blinks, 1..16), pause
    // slots N..N+3 (2.0s total), then blk_idx wraps to 0 and the burst
    // repeats forever. Pause is 4 slots so the blink bursts are countable.
    localparam [24:0] BLK_HALF = 25'd31_250_000;    // 0.25s at 125MHz
    reg [24:0] blk_cnt;
    reg        blk_ph;                              // 0 = on half
    reg [4:0]  blk_idx;                             // 0..latch_val+4
    wire [4:0] n_blk  = {1'b0, latch_val} + 5'd1;   // blink slots (1..16)
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            blk_cnt <= 25'd0;
            blk_ph  <= 1'b0;
            blk_idx <= 5'd0;
        end else if (latched) begin
            if (blk_cnt == (BLK_HALF - 25'd1)) begin
                blk_cnt <= 25'd0;
                blk_ph  <= ~blk_ph;
                if (blk_ph) begin                   // off half done: next slot
                    if (blk_idx == (n_blk + 5'd3)) blk_idx <= 5'd0;
                    else                            blk_idx <= blk_idx + 5'd1;
                end
            end else begin
                blk_cnt <= blk_cnt + 25'd1;
            end
        end
    end
    wire blk_on = latched && !blk_ph && (blk_idx < n_blk);

    // ---- LED mux: boot self-test > blink/latch readout > live probes ----
    // P5 APP_MODE: LED = app 演示指示灯 (app_pattern.led:
    //   d0 = CONN_UP 曾见 / d1 = 收发活动 / d2 = 失配粘滞 / d3 = 传输完成)
    // P5e-T3: TCP app 与 UDP app **共用**这 4 个灯 (两条演示通路同性质):
    //   d0 = TCP 曾建连 | UDP 曾学到 peer;  d1 = 任一方向有活动;
    //   d2 = 任一方向有失配 (粘滞);        d3 = 传输完成 / UDP 会话在跑
`ifdef APP_MODE
    assign led_d0 = boot_act ? boot_on : (app_led[0] | udpapp_led[0]);
    assign led_d1 = boot_act ? boot_on : (app_led[1] | udpapp_led[1]);
    assign led_d2 = boot_act ? boot_on : (app_led[2] | udpapp_led[2]);
    assign led_d3 = boot_act ? boot_on : (app_led[3] | udpapp_led[3]);
`else
    assign led_d0 = boot_act ? boot_on
                            : (latched ? blk_on : tx_dbg_wnd_open);
    assign led_d1 = boot_act ? boot_on : latched;        // solid ON = latched
    assign led_d2 = boot_act ? boot_on : tx_dbg_sready;  // live, watch in test
    assign led_d3 = boot_act ? boot_on : eco_dbg_fifo_full;
`endif

    // ---- 4) P6 UART 全精度读出 (uart_dbg.v): 锁存后立即发首行, 之后 ~5s
    //        重复一行 148 字符 ASCII (9600-8N1, 154ms/行), 见头注释格式 ----
    // 输入 = 锁存拍快照 (snap_*/latch_val) + 实时 FSM/指针 (每行首重采:
    // TXST/RXST/ACC/EMV/EST/FFE/WPT/RPT/PF/TV/PV/SV/PLEN); 与 LED blink 互不
    // 干扰 (同 gmii_clk 域, 快照读自 tcb 组合 conn0 口, 零行为耦合)
    // diag18: run 加 boot 触发 — boot 自检结束 (boot_h==6, ~1.2s) 即开始发
    // 行, 周期重复不再依赖回卷锁存; 冻结锁存后快照字段自然生效, TR/TL/RXT
    // 段仍由各自 frozen 门控。HLS 死/活一望便知 (SC/SF/SV/HR 字段)。
    wire        uart_run = latched || (boot_h == 3'd6);
    // P5: 顶层只有一根 UART TX — APP_MODE 下前 2^29 拍 (= 4.295s @125MHz) 给
    // P4 诊断行 (boot/早诊断), 之后常切到 app 状态行 (168 字符/2s); 默认模式
    // 直连 P4 行 (逐位不变)。**切换点必然截出半行** (两行字符不可能对齐),
    // PC 侧解析按 LF 或行首前缀 "P5A1 " 重对齐, 丢弃首个不完整行。
    wire        p4_uart_txd;
`ifdef APP_MODE
    reg [29:0]  uart_sel;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) uart_sel <= 30'd0;
        else if (!uart_sel[29]) uart_sel <= uart_sel + 30'd1;
    end
    assign uart_txd = uart_sel[29] ? app_uart_txd : p4_uart_txd;
`else
    assign uart_txd = p4_uart_txd;
`endif
    dbg_line_tx u_dbg_line (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .run            (uart_run),
        .snd_nxt        (snap_nxt),
        .snd_una        (snap_una),
        .snd_wnd        (snap_wnd),
        .wscale         (snap_wscale),
        .tcb_state      (snap_st),
        .latch_val      (latch_val),
        .win_inflight   (snap_inf),
        .win_wnd_eff    (snap_eff),
        .tx_state       (tx_dbg_state),
        .rx_state       (rx_dbg_state),
        .rx_accept      (rx_dbg_accept),
        .rx_emitv       (rx_dbg_emitv),
        .echo_state     (eco_dbg_state),
        .fifo_full      (eco_dbg_fifo_full),
        .fifo_empty     (eco_dbg_fifo_empty),
        .fifo_wptr      (eco_dbg_fifo_wptr[12:0]),  // P4c: 13 位 (直连低 13 位)
        .fifo_rptr      (eco_dbg_fifo_rptr[12:0]),  // P4c: 13 位 (直连低 13 位)
        .tx_pay_full    (tx_dbg_pay_full),
        .tx_saxis_tv    (tx_dbg_saxis_tvalid),
        .pipe_mv        (pipe_mv),
        .pipe_sv        (pipe_sv),
        .tx_plen_r      (tx_dbg_plen_r),
        .tlast_wr       (eco_dbg_tlast_wr),
        .tlast_fwd      (eco_dbg_tlast_fwd),
        .tlast_in       (tx_dbg_tlast_in),
        .pay_wptr       (tx_dbg_pay_wptr),
        .pay_rptr       (tx_dbg_pay_rptr),
        .pay_full2      (tx_dbg_pay_full2),
        .pay_empty      (tx_dbg_pay_empty),
        .tx_plen        (tx_dbg_plen),
        // P4b-7-P6 追加: RX 帧判读 (plen_l/pcount/w2 total_len) + 丢弃·通过计数
        .rx_plen_l      (rx_dbg_plen_l),
        .rx_pcount      (rx_dbg_pcount),
        .rx_w2_tlen     (rx_dbg_w2_tlen),
        .rx_drop_seq    (rx_dbg_drop_seq),
        .rx_drop_crc    (rx_dbg_drop_crc),
        .rx_drop_nonmatch (rx_dbg_drop_nonmatch),
        .rx_drop_ipcsum (rx_dbg_drop_ipcsum),
        .rx_drop_trunc  (rx_dbg_drop_trunc),
        .rx_pass        (rx_dbg_pass),
        // P4b-7-P6 三站词计数 (行尾 MW/CW/RW/WC): mac 出词 / classify 进出 /
        // tcp_rx 进词 + 头字计数器 (MW 与 CW 对账裁决丢词站)
        .mac_words_out  (mac_dbg_words_out),
        .cls_words_in   (cls_dbg_words_in),
        .cls_words_out  (cls_dbg_words_out),
        .rx_words_in    (rx_dbg_words_in),
        .rx_wcnt        (rx_dbg_wcnt),
        // P4b-7-P6 TRACE: 64x24b 环 + 冻结停写址 + 冻结锁存 (首次 RTO 回卷)
        .trace_ring     (trace_mem),
        .trace_wptr     (trace_waddr),
        .tr_run         (trace_frozen),
        // P4b-7-P6 TL: echo frame_fifo 边存读址/读出 (tlast 位图转储, 仅 run 时发)
        .dbg_rd_addr    (eco_dbg_fifo_tladdr),
        .dbg_rd_side    (eco_dbg_fifo_tlside),
        // P4b-7-P6 RX-TRACE: RX 侧 64x24b 环 (TL 行之后 4 行 RXT= 转储;
        // 触发 = fend 拍 pcount 落后 plen_l 超 4 字节, sticky 一次性锁存)
        .rxt_ring       (rx_trace_mem),
        .rxt_wptr       (rx_trace_waddr),
        .rxt_run        (rx_trace_frozen),
        // P4b-7-P6-P6b 线上帧长 (WL 字段): 异常触发拍锁存的线上帧字节数
        // (phy1_rxc 域计数 → gmii_clk 2 级同步 → 触发拍锁存)
        .rx_wire_last   (wl_last_lat),
        // diag18 慢路径/HLS 存活字段 (每行行首重采):
        //   SC = slow_rx_adp 提交给 HLS 的帧数 (RX→HLS 交付证明; ARP/ICMP/SYN
        //        每帧 +1 — 静止应为 0, 有流量时随帧递增)
        //   SD = slow_rx_adp 丢弃帧数 (坏 FCS/rx_er/fifo 满)
        //   SF = slow_tx_adp 发出帧数 (HLS 自发行文/应答 — 静止应 ~5s +1,
        //        恒 0 = HLS TX 链死)
        //   SP = slow_tx_adp purge 数
        //   SV = slow_rx_adp starv 看门狗累计 (HLS 有数据不读的拍数; 每 ~16.8ms
        //        回到 0 = 看门狗循环复位 HLS; 恒 0 = 无饥饿)
        //   HR = hls_rst_n 实时 (0 = HLS 正在复位)
        .srx_commit     (srx_stat_commit),
        .srx_drop       (srx_stat_drop),
        .stx_frames     (stx_stat_frames),
        .stx_purge      (stx_stat_purge),
        .starv          (srx_dbg_starv),
        .hls_rst        (hls_rst_n),
        .txd            (p4_uart_txd)
    );

    // 旧观测 (P4a, 已换线保留对照):
    // assign led_d0 = rx_stat_frames[0];     // RX 帧活动
    // assign led_d1 = rx_stat_pass[0];       // TCP 匹配且 FCS 好
    // assign led_d2 = srx_stat_commit[0];    // 提交给 HLS 的慢帧 (ARP/ICMP 活动)
    // assign led_d3 = stx_stat_frames[0];    // HLS 发出帧 (应答/自发行文)

endmodule
