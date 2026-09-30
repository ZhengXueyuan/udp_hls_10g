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
//   demo 验证引脚; 9600-8N1):
//   ⚠️ P6b: 该时钟域取决于构建 —— 默认构建 (K7 各档 / P6a) 仍挂在 gmii_clk(125MHz,
//      13021 拍/位); **PCIE_OBS 构建 (P6b/P6e) 搬到 156.25MHz 数据面域 (dp_clk,
//      16276 拍/位)**。波特率与墙钟不变, 只有拍数 ×1.25 (见 P6B_SPEC §5.1)。
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
`ifndef DEV_USP
    input           fpga_gclk,     // K7 板 50MHz 晶振 -> MMCM -> 200MHz IDELAYCTRL 参考钟
`endif
    // P6a-T2: US+ (DEV_USP) 分支**不需要** fpga_gclk —— 本板 RGMII 走**零 IDELAY**配方
    //   (KU5P 的 RGMII 引脚在 bank86=HDIO, 放不了 IDELAYE3; 且底板 PHY 的 RXDLY/TXDLY
    //   已搭接为 1, 延迟由 PHY 内部提供) ⇒ 无 IDELAYCTRL ⇒ 无参考钟需求。
    //   详见 board/util_gmii_to_rgmii_us.v 头注释与 board/ku5p_probe/README.md。
`ifndef P7B_10G
    // ⚠️ P7b (10G 前端) 下**没有 RGMII**: 那 15 根脚与 RTL8211E 在本设计里完全不用
    //   ⇒ 端口在 P7B_10G 分支里**整体去掉** (留着的话它们是"未约束的悬空输出",
    //   而 P7b 的 XDC 里又绝不能出现 RGMII 的 PACKAGE_PIN —— 那会让每条 set_property
    //   报 12-4739 并被静默丢弃, 而构建脚本正是靠 grep 12-4739 判约束生效)。
    //   默认/1G 构建的端口表**逐字不变**。
    input           phy1_rxc,
    input  [3:0]    phy1_rxd,
    input           phy1_rxctl,
    output          phy1_txc,
    output [3:0]    phy1_txd,
    output          phy1_txctl,
`endif
    output          led_d0,
    output          led_d1,
    output          led_d2,
    output          led_d3,
    // P4b-7-P6 冻结态 UART 全精度读出 (板载 CH340E 串口 → PC, 9600-8N1)
    output          uart_txd
`ifdef P7B_10G
    ,
    // ---- P7b: 10G 前端端口 (官方 xxv_ethernet PCS/PMA 64-bit, 2 通道) ----
    //   ⚠️ GT 串行脚**不在本文件约束**: 通道 LOC 由核内 XDC 钉死
    //      (ip_0 = GTHE4_CHANNEL_X0Y4, ip_1 = _X0Y5), 串行球号由站点推导。
    input           gt_refclk_p,      // V7 = MGTREFCLK0_225 (核心板 Y2 = 156.25MHz)
    input           gt_refclk_n,      // V6
    input           sfp1_rxp,         // X0Y4 RX = J7  (闸 2: 全系统**无线**)
    input           sfp1_rxn,
    output          sfp1_txp,         // X0Y4 TX = J7
    output          sfp1_txn,
    input           sfp2_rxp,         // X0Y5 RX = J8  (**唯一连线** ↔ 网卡 enp1s0f1np1)
    input           sfp2_rxn,
    output          sfp2_txp,         // X0Y5 TX = J8
    output          sfp2_txn,
    input           sfp1_rx_los,      // B11 (三态判别实验实测)
    output          sfp1_tx_dis,      // C11 (高有效; 悬空 = 发射关闭 = 全黑)
    input           sfp2_rx_los,      // C9
    output          sfp2_tx_dis       // D9
`endif
`ifdef PCIE_OBS
    ,
    // ---- P6e: PCIe/XDMA 观测通道 (仅 KU5P 板可用; K7 板没有金手指) ----
    //   ⚠️ 全部包在 `ifdef PCIE_OBS 内: 默认构建 (K7 各档 + P6a) 的端口表/逻辑**逐位不变**。
    //   ⚠️ 复位**不另开端口**: 本板 reset_n 就接在 PCIe 槽的 PERST# (J9) 上 (见 ku5p_p6a_*.xdc),
    //      与 xdma.sys_rst_n 是同一个物理信号 —— 厂商 BD 也是这么接的 (pcieReset → sys_rst_n)。
    input           pcie_sys_clk_p,      // AB7 (MGTREFCLK0_224, 金手指 100MHz 差分)
    input           pcie_sys_clk_n,      // AB6
    output [3:0]    pcie_txp,            // AF7 AE9 AD7 AC5
    output [3:0]    pcie_txn,
    input  [3:0]    pcie_rxp,            // AF2 AE4 AD2 AB2
    input  [3:0]    pcie_rxn,
    // ---- P6b: 数据面时钟源 (核心板 Y1 = SG7050VAN-100.000000M, 网络 SYS_CLK_P/N,
    //      ball T25/U25 = bank65 的 GC 差分对, CLOCK_REGION X0Y1 有 MMCM) ----
    //   ⚠️ 端口**包在 PCIE_OBS 内**(而不是 DEV_USP): P6a 构建 (DEV_USP 但无 PCIE_OBS)
    //      仍是单域, 它的 XDC (ku5p_p6a_t8p0.xdc) 里没有这两根脚 ⇒ 端口一放出去就会
    //      DRC 报"未约束端口"。这正是 P6B_SPEC §B 的 B2 那一条, 这里按"最小暴露面"定案。
    input           sys_clk_p,           // T25
    input           sys_clk_n            // U25
`endif
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

`ifndef DEV_USP
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

`endif

    // --- P7b: 前端 (FE) 时钟的两个**域别名** (声明在分支之前, 见下面的 assign) ------
    // 默认构建: FE RX 与 FE TX 是**同一个** gmii_clk ⇒ `tx_fe_clk` 逐位等于它 (纯线名,
    //   网表不变 —— 与 dp_clk 别名的同一手法)。
    // P7B_10G:  RX 侧 = PCS 恢复钟 `rx_clk_out_1`; TX 侧 = `tx_mii_clk_1` (两域, 物理无关)。
    wire gmii_clk;      // FE RX 域 (u_mac_rx / u_rxcdc 写侧 / wl_last / gmii_free / 快照 FE 束)
    wire tx_fe_clk;     // FE TX 域 (u_mac_tx / u_txcdc 读侧)

    // =====================================================================
    // P7b: 10G 前端 —— 官方 `xxv_ethernet` PCS/PMA 64-bit + 自写 64 位 XGMII MAC
    //----------------------------------------------------------------------
    // 与默认构建的**唯一**结构差别: 前端从 "RGMII → mac_rx_64/mac_tx_64" 换成
    //   "PCS → mac_rx_10g/mac_tx_10g"。`vlan_strip` 及其后的**全部数据面一字未动**
    //   (含 u_rxcdc / u_txcdc 两个异步边界 —— 它们只是换了 FE 侧的时钟源)。
    //
    // 时钟域 (四个, 两两异步; 约束见 board/ku5p_p7b_gt.xdc + ku5p_p7b_cdc.xdc):
    //   · dclk          = 核心板 Y1 100MHz (clk_gen_p6b 的 clk_in_100) → PCS 控制/DRP
    //   · rx_core_clk_1 = PCS `rx_clk_out_1` (CDR **恢复**钟, 156.25MHz) → mac_rx_10g
    //                     + u_rxcdc 的写侧 ⇒ 本文件的 `gmii_clk` **别名到它**
    //   · tx_mii_clk_1  = PCS `tx_mii_clk_1` (QPLL0 派生, 156.25MHz) → mac_tx_10g
    //                     + u_txcdc 的读侧 ⇒ 新增别名 `tx_fe_clk`
    //   · dp_clk        = Y1 经 MMCM ×1.5625 = 156.25MHz (P6b 既有) → 数据面
    //   ⚠️ rx_core_clk 是**恢复**钟 —— 与 tx_mii_clk 同标称频率但物理无关
    //      (P7B_GATE1 §B3 的网表实证 + 该工程 XDC 把它们整组设为 asynchronous)。
    //
    // 通道选择: **channel 1 = X0Y5 = SFP B = J8**。闸 2 的双向实测钉死了
    //   "全系统只有一根 AOC: FPGA J8 ↔ 网卡 enp1s0f1np1" (P7B_GATE2 §2.3)。
    //   channel 0 = X0Y4 = J7 无线 ⇒ 只发常量 IDLE (10GBASE-R 要求连续块流)。
    //
    // 字节序: **镜像在 MAC 内部** (`mac_rx_10g`/`mac_tx_10g` 各做一次纯 8 字节
    //   `bswap`, 见 P7B_MAC_DESIGN §2/§C.2) ⇒ 本 wrapper 侧是 **1:1 直连**,
    //   `xgmii_txd[8l +: 8] ↔ tx_mii_d_1[8l +: 8]` 逐位对接, 无任何变换。
    //
    // ⚠️ `pcs64` 是**两根通道**的核 (与 xxv_loop 闸 1 同配置): 单通道核的 LOC
    //   默认落在 X0Y4 = 无线的那根上, 而两通道核的 LOC 由核内 XDC 钉死
    //   (X0Y4/X0Y5), 已被闸 1/闸 2 反复验证。
    // =====================================================================
`ifdef P7B_10G
    wire [63:0] rx_mii_d_1, tx_mii_d_1;
    wire [7:0]  rx_mii_c_1, tx_mii_c_1;
    wire [63:0] rx_mii_d_0, tx_mii_d_0;
    wire [7:0]  rx_mii_c_0, tx_mii_c_0;
    wire        rx_core_clk_1, tx_mii_clk_1, rx_clk_out_1;
    wire        rx_core_clk_0, tx_mii_clk_0, rx_clk_out_0;
    wire        pcs_user_rx_reset_1, pcs_user_tx_reset_1;
    wire        pcs_user_rx_reset_0, pcs_user_tx_reset_0;
    wire        pcs_rx_reset_0, pcs_tx_reset_0, pcs_rx_reset_1, pcs_tx_reset_1;
    wire        pcs_gtpowergood_0, pcs_gtpowergood_1;
    wire        gt_refclk_out_w, rxrecclkout_0, rxrecclkout_1;
    // PCS 状态 (域**未确证**, 见 P7B_GATE1 §B4: 只有 block_lock 实证在 dclk; 其余
    //   一律按"可能异步"处理 ⇒ 进快照前每位一个 2FF, 见下面的同步块)
    wire        pcs_blk_lock, pcs_rx_status, pcs_hi_ber;
    wire        pcs_rx_localfault, pcs_tx_localfault;
    wire        pcs_framing_err, pcs_framing_err_v;
    wire        pcs_bad_code, pcs_bad_code_v;
    wire        pcs_fifo_error, pcs_valid_ctrl_code;
    wire [7:0]  pcs_rx_error;
    wire        pcs_rx_error_v;
    // ch0 未用的控制/状态
    //   ⚠⚠ **每个输出必须有自己的线** —— 把它们接到同一根 `pcs_ch0_unused`
    //   会让那根线有 ~12 个驱动源 ⇒ opt_design 报
    //     [DRC MDRV-1] Multiple Driver Nets: Net u_pcs/inst/i_pcs64_top_0/stat_rx_status_0
    //     has multiple drivers: ... (本轮实测，建构直接死在 opt_design)
    //   输入端共用一根常量线是合法的 (多个输入端可以同源)。
    wire        pcs_ch0_u_ferr, pcs_ch0_u_ferrv, pcs_ch0_u_rlf, pcs_ch0_u_blk;
    wire        pcs_ch0_u_vcc, pcs_ch0_u_status, pcs_ch0_u_ber, pcs_ch0_u_bad;
    wire        pcs_ch0_u_badv, pcs_ch0_u_errv, pcs_ch0_u_fifo, pcs_ch0_u_tlf;
    wire [7:0]  pcs_ch0_u_err;
    wire [57:0] pcs_ch0_unused58;
    // PCS 控制域时钟 (clk_gen_p6b.clk_in_100, 驱动点在本块之后) 与 PCS 总复位 ——
    //   两者都**必须在这里先声明** (xvlog 先声明后用; 隐式 1 位网会让 64 位/多比特
    //   连接静默截断, 工程坑 24)。
    wire        clk_in_100;
    wire        sys_reset_p7b;
`ifdef P7B_LAT
    // ---- P7b-LAT: GT DRP 总线线网 (必须在 `u_pcs` **之前**声明 —— 它的端口要用;
    //      隐式 1 位网会让 16/10 位的连接静默截断, 工程坑 24) -------------------
    wire [15:0] drp_do_w   [0:1];
    wire        drp_rdy_w  [0:1];
    wire        drp_en_w   [0:1];
    wire        drp_we_w   [0:1];
    wire [9:0]  drp_addr_w [0:1];
    wire [15:0] drp_di_w   [0:1];
    wire [15:0] drp0_do_r, drp0_addr_r, drp0_evt_r;
    wire [15:0] drp1_do_r, drp1_addr_r, drp1_evt_r;
    wire        drp0_tgl_r, drp0_to_r, drp1_tgl_r, drp1_to_r;
    wire [15:0] lat_drp_req_addr;
    wire [1:0]  lat_drp_req_go;
`endif
    // ---- MAC 的新增观测线 (P7B_MAC_DESIGN §3 的端口表; 名字不同名于 1G 版) ----
    wire [31:0] mrx_stat_rx_words, mrx_stat_rx_pay_bytes, mrx_stat_rx_er_words;
    wire [31:0] mrx_stat_rx_bad_words, mrx_stat_rx_frag, mrx_stat_rx_no_s;
    wire [31:0] mrx_stat_rx_q, mrx_stat_rx_short, mrx_stat_rx_long;
    wire [15:0] mac_rx_10g_last_len;
    wire [3:0]  mrx_dbg_last_tlane;
    wire [1:0]  mrx_dbg_state;
    wire [31:0] mtx_stat_flush_words, mtx_stat_flush_done, mtx_stat_tx_words;
    wire [31:0] mtx_stat_tx_ctrl_char, mtx_stat_tx_short;
    wire [15:0] mtx_dbg_last_clen;
    wire [1:0]  mtx_dbg_state;
    // ---- MAC 复位: 板级 reset_n 同步进各自域, 再 AND 核的 `user_*_reset_*` -----
    //   §B3 的施工纪律: RX 用 `user_rx_reset_1` (核的输出, 天然在 RX 恢复域,
    //   把 MAC 的 FSM 与核内状态对齐), TX 用 `user_tx_reset_1` (TX-MII 域)。
    //   ⚠️ 两者由**不同域**的核内逻辑驱动 ⇒ 不能与 reset_n 组合 (会产生跨域组合复位);
    //      reset_n 先各自 2FF 同步进本域, 再在**本域内**相与。
    (* ASYNC_REG = "TRUE" *) reg [2:0] rstn_rx_sr, rstn_tx_sr;
    wire        rx_mac_rst_n, tx_mac_rst_n;
    // ---- MAC 输入的 XGMII 直连 (镜像在 MAC 内部, 本 wrapper 无变换) ----
    // PCS 状态/事件束的**打包结果** (位域定义在采集段, 见那里的逐位注释)
    wire [31:0] pcs_status_bundle, pcs_evt_bundle;

    // ⚠️ PCS socket = 唯一在"仿真 vs 综合"之间换掉的东西 (端口表**逐一相同**):
    //   综合 = 真核 `pcs64` (加密 GT IP, 本工程从未在 xsim 里跑过);
    //   仿真 = `p7b_pcs_stub` (行为级 XGMII 泵, 只造字节流与两个 156.25MHz 钟)。
    //   ⇒ 除这一个实例, MAC / CDC / 数据面 / 快照的接线两边**逐字相同** ——
    //   这正是"ifdef 里的接线错只有真 wrapper 全链门能抓"能成立的前提。
    //   (与 P6B_SIM_CLKGEN 把 MMCM 换成行为级模型是同一个手法。)
`ifdef P7B_SIM_NOPCS
    p7b_pcs_stub u_pcs (
`else
    pcs64 u_pcs (
`endif
        .gt_refclk_p                      (gt_refclk_p),
        .gt_refclk_n                      (gt_refclk_n),
        .sys_reset                        (sys_reset_p7b),
        .dclk                             (clk_in_100),
        // ---- channel 0 = SFP A = X0Y4 = J7 (无线: 只发 IDLE) ----
        .gt_rxp_in_0                      (sfp1_rxp),
        .gt_rxn_in_0                      (sfp1_rxn),
        .gt_txp_out_0                     (sfp1_txp),
        .gt_txn_out_0                     (sfp1_txn),
        .rx_core_clk_0                    (rx_core_clk_0),
        .tx_mii_clk_0                     (tx_mii_clk_0),
        .rx_clk_out_0                     (rx_clk_out_0),
        .txoutclksel_in_0                 (3'b101),
        .rxoutclksel_in_0                 (3'b101),
        .gtwiz_reset_tx_datapath_0        (1'b0),
        .gtwiz_reset_rx_datapath_0        (1'b0),
        .rxrecclkout_0                    (rxrecclkout_0),
        .gtpowergood_out_0                (pcs_gtpowergood_0),
        .rx_reset_0                       (pcs_rx_reset_0),
        .user_rx_reset_0                  (pcs_user_rx_reset_0),
        .rx_mii_d_0                       (rx_mii_d_0),
        .rx_mii_c_0                       (rx_mii_c_0),
        .ctl_rx_test_pattern_0            (1'b0),
        .ctl_rx_data_pattern_select_0     (1'b0),
        .ctl_rx_test_pattern_enable_0     (1'b0),
        .ctl_rx_prbs31_test_pattern_enable_0 (1'b0),
        .stat_rx_framing_err_0            (pcs_ch0_u_ferr),
        .stat_rx_framing_err_valid_0      (pcs_ch0_u_ferrv),
        .stat_rx_local_fault_0            (pcs_ch0_u_rlf),
        .stat_rx_block_lock_0             (pcs_ch0_u_blk),
        .stat_rx_valid_ctrl_code_0        (pcs_ch0_u_vcc),
        .stat_rx_status_0                 (pcs_ch0_u_status),
        .stat_rx_hi_ber_0                 (pcs_ch0_u_ber),
        .stat_rx_bad_code_0               (pcs_ch0_u_bad),
        .stat_rx_bad_code_valid_0         (pcs_ch0_u_badv),
        .stat_rx_error_0                  (pcs_ch0_u_err),
        .stat_rx_error_valid_0            (pcs_ch0_u_errv),
        .stat_rx_fifo_error_0             (pcs_ch0_u_fifo),
        .tx_reset_0                       (pcs_tx_reset_0),
        .user_tx_reset_0                  (pcs_user_tx_reset_0),
        .tx_mii_d_0                       (tx_mii_d_0),
        .tx_mii_c_0                       (tx_mii_c_0),
        .stat_tx_local_fault_0            (pcs_ch0_u_tlf),
        .ctl_tx_test_pattern_0            (1'b0),
        .ctl_tx_test_pattern_enable_0     (1'b0),
        .ctl_tx_test_pattern_select_0     (1'b0),
        .ctl_tx_data_pattern_select_0     (1'b0),
        .ctl_tx_test_pattern_seed_a_0     (pcs_ch0_unused58),
        .ctl_tx_test_pattern_seed_b_0     (pcs_ch0_unused58),
        .ctl_tx_prbs31_test_pattern_enable_0 (1'b0),
        // ---- channel 1 = SFP B = X0Y5 = J8 (唯一连线) ----
        .gt_rxp_in_1                      (sfp2_rxp),
        .gt_rxn_in_1                      (sfp2_rxn),
        .gt_txp_out_1                     (sfp2_txp),
        .gt_txn_out_1                     (sfp2_txn),
        .rx_core_clk_1                    (rx_core_clk_1),
        .tx_mii_clk_1                     (tx_mii_clk_1),
        .rx_clk_out_1                     (rx_clk_out_1),
        .txoutclksel_in_1                 (3'b101),
        .rxoutclksel_in_1                 (3'b101),
        .gtwiz_reset_tx_datapath_1        (1'b0),
        .gtwiz_reset_rx_datapath_1        (1'b0),
        .rxrecclkout_1                    (rxrecclkout_1),
        .gtpowergood_out_1                (pcs_gtpowergood_1),
        .rx_reset_1                       (pcs_rx_reset_1),
        .user_rx_reset_1                  (pcs_user_rx_reset_1),
        .rx_mii_d_1                       (rx_mii_d_1),
        .rx_mii_c_1                       (rx_mii_c_1),
        .ctl_rx_test_pattern_1            (1'b0),
        .ctl_rx_data_pattern_select_1     (1'b0),
        .ctl_rx_test_pattern_enable_1     (1'b0),
        .ctl_rx_prbs31_test_pattern_enable_1 (1'b0),
        .stat_rx_framing_err_1            (pcs_framing_err),
        .stat_rx_framing_err_valid_1      (pcs_framing_err_v),
        .stat_rx_local_fault_1            (pcs_rx_localfault),
        .stat_rx_block_lock_1             (pcs_blk_lock),
        .stat_rx_valid_ctrl_code_1        (pcs_valid_ctrl_code),
        .stat_rx_status_1                 (pcs_rx_status),
        .stat_rx_hi_ber_1                 (pcs_hi_ber),
        .stat_rx_bad_code_1               (pcs_bad_code),
        .stat_rx_bad_code_valid_1         (pcs_bad_code_v),
        .stat_rx_error_1                  (pcs_rx_error),
        .stat_rx_error_valid_1            (pcs_rx_error_v),
        .stat_rx_fifo_error_1             (pcs_fifo_error),
        .tx_reset_1                       (pcs_tx_reset_1),
        .user_tx_reset_1                  (pcs_user_tx_reset_1),
        .tx_mii_d_1                       (tx_mii_d_1),
        .tx_mii_c_1                       (tx_mii_c_1),
        .stat_tx_local_fault_1            (pcs_tx_localfault),
        .ctl_tx_test_pattern_1            (1'b0),
        .ctl_tx_test_pattern_enable_1     (1'b0),
        .ctl_tx_test_pattern_select_1     (1'b0),
        .ctl_tx_data_pattern_select_1     (1'b0),
        .ctl_tx_test_pattern_seed_a_1     (58'd0),
        .ctl_tx_test_pattern_seed_b_1     (58'd0),
        .ctl_tx_prbs31_test_pattern_enable_1 (1'b0),
        .gt_loopback_in_0                 (3'b000),
        .gt_loopback_in_1                 (3'b000),
        .qpllreset_in_0                   (1'b0),
        .ctl_rx_wdt_disable_0             (1'b0),
        .ctl_rx_wdt_disable_1             (1'b0),
        .gt_refclk_out                    (gt_refclk_out_w)
`ifdef P7B_LAT_DRP
        // ---- P7b-LAT: GT DRP 用户口 -------------------------------------
        //   ⚠️⚠️ **本轮默认不定义 `P7B_LAT_DRP`** —— 实测: 只有把 IP 的
        //      `CONFIG.ADD_GT_CNTRL_STS_PORTS` 置 1 才会有这 16 个端口, 而置 1
        //      会**同时**放出每通道 45 个必须显式驱动的 GT 控制输入
        //      (txprecursor/txdiffctrl/txpmareset/...); 不驱动 ⇒ `opt_design`
        //      硬失败 `ERROR: [Opt 31-67] ... GTYE4_CHANNEL_PRIM_INST_i_3`
        //      (2026-09-30 两次构建实测复现)。那些端口在 =0 的那版里由**核内
        //      参数**驱动, 取值本仓无权威来源 ⇒ 强行接 0 有改坏 TX 眼图的风险。
        //      取证与建议见 _proj_10g/notes/P7B_LATENCY.md §1.5。
        //   下面这 16 行是"参数置 1 版"的正确接法, 留作下一轮的施工入口。
        ,
        .gt_drpclk_0  (clk_in_100),       // DRP 时钟 = dclk (pcs64_wrapper.v:434)
        .gt_drpclk_1  (clk_in_100),       //            (ch1 同 :956)
        .gt_drprst_0  (1'b0),             // 复位钉 0 (与核内原接法一致)
        .gt_drprst_1  (1'b0),
        .gt_drpdo_0   (drp_do_w[0]),
        .gt_drpdo_1   (drp_do_w[1]),
        .gt_drprdy_0  (drp_rdy_w[0]),
        .gt_drprdy_1  (drp_rdy_w[1]),
        .gt_drpen_0   (drp_en_w[0]),
        .gt_drpen_1   (drp_en_w[1]),
        .gt_drpwe_0   (drp_we_w[0]),
        .gt_drpwe_1   (drp_we_w[1]),
        .gt_drpaddr_0 (drp_addr_w[0]),
        .gt_drpaddr_1 (drp_addr_w[1]),
        .gt_drpdi_0   (drp_di_w[0]),
        .gt_drpdi_1   (drp_di_w[1])
`endif
    );
`ifdef P7B_LAT_DRP
    // ---- P7b-LAT: 两通道的 GT DRP 读事务机 (默认不编 —— 见上面的长注释) ----
    //   ⚠️ 线网声明在**上面** `u_pcs` 之前 (那里是它们的第一处使用点)。
    //   复位: `~sys_reset_p7b` = POR 释放后才跑 (核内 GT 复位序列走完再碰 DRP)。
    wire drp_por_n = ~sys_reset_p7b;
    p7b_lat_drp u_drp0 (
        .clk(clk_in_100), .rst_n(drp_por_n),
        .req_addr(lat_drp_req_addr), .req_go(lat_drp_req_go[0]),
        .drpaddr(drp_addr_w[0]), .drpdi(drp_di_w[0]),
        .drpen(drp_en_w[0]), .drpwe(drp_we_w[0]), .drprst(),
        .drpdo(drp_do_w[0]), .drprdy(drp_rdy_w[0]),
        .out_do(drp0_do_r), .out_addr(drp0_addr_r),
        .out_timeout(drp0_to_r), .out_tgl(drp0_tgl_r), .out_evt(drp0_evt_r)
    );
    p7b_lat_drp u_drp1 (
        .clk(clk_in_100), .rst_n(drp_por_n),
        .req_addr(lat_drp_req_addr), .req_go(lat_drp_req_go[1]),
        .drpaddr(drp_addr_w[1]), .drpdi(drp_di_w[1]),
        .drpen(drp_en_w[1]), .drpwe(drp_we_w[1]), .drprst(),
        .drpdo(drp_do_w[1]), .drprdy(drp_rdy_w[1]),
        .out_do(drp1_do_r), .out_addr(drp1_addr_r),
        .out_timeout(drp1_to_r), .out_tgl(drp1_tgl_r), .out_evt(drp1_evt_r)
    );
`endif
    // ch1 的发射/接收**不由本 wrapper 管**: TX 由 mac_tx_10g 驱动 tx_mii_d/c_1,
    //   RX 由 mac_rx_10g 消费 rx_mii_d/c_1 (下面)。
    //
    // ch0 (= X0Y4 = J7, 无线) 发常量 IDLE 流。
    //   ⚠⚠ 这两行曾被一次编辑**误删** (去重 SFP TX_DIS 的那次)。
    //   无驱动的输出端是合法 Verilog, 而 ch0 又不在任何判据里
    //   ⇒ 没有门报警; 但 Vivado 会把核内那个端口的副本报成
    //   **Driverless net** 并在 opt_design 升级成错:
    //     WARNING: [Opt 31-155] Driverless net .../i_TX_ENCODER/tx_mii_d[36] ...
    //     ERROR:   [Opt 31-67] ... i_TX_ENCODER/is_valid_ctrl[3]_i_3 ... missing I0
    //   修法: 恢复为 `dont_touch` 寄存器 (值不变 = 合法 10GBASE-R idle,
    //   但核看到的是真网而非可被常量折叠的字面量 —— 同一类 LUT 还有
    //   另一条出错路径就是它)。
    (* dont_touch = "true" *) reg [63:0] p7b_ch0_idle_d;
    (* dont_touch = "true" *) reg [7:0]  p7b_ch0_idle_c;
    always @(posedge tx_mii_clk_0) begin
        p7b_ch0_idle_d <= 64'h0707070707070707;   // 全 lane /I/
        p7b_ch0_idle_c <= 8'hFF;
    end
    assign tx_mii_d_0 = p7b_ch0_idle_d;
    assign tx_mii_c_0 = p7b_ch0_idle_c;

    // --- PCS 总复位 `sys_reset` (高有效) ------------------------------------
    // 配方逐行照抄闸 1 的实测版本 (P7B_GATE1 §B2, 那里 POR 释放后 ~10.5ms 两通道
    //   都起、45ms 内块锁已建立): GT 的复位序列 (powergood → QPLL lock → tx/rx
    //   resetdone) 由**核内 reset controller** 自己走 (INCLUDE_SHARED_LOGIC=1),
    //   用户侧只有这一个入口, **不要**在用户侧造细粒度复位去猜核的时序。
    // ⚠️ 它的最小宽度**未核实**; 10.5ms 是实测够用的值。
    // ⚠️ 仿真 (`P6B_SIM_CLKGEN`) 里把 POR 缩短到 2^4 拍 —— 否则 10.5ms 仿真时间
    //    白白拖死门; 真实构建 (不定义该宏) 仍是 2^20 拍。
`ifdef P6B_SIM_CLKGEN
    localparam P7B_POR_BITS = 4;
`else
    localparam P7B_POR_BITS = 20;
`endif
    // PCS 的 dclk = 100MHz 参考钟缓冲输出 (clk_gen_p6b.clk_in_100, 见下)
    //   ⚠️ **不要把 156.25 喂给 dclk**: 它是 DRP/复位控制域, 快 1.56× 会让复位/DRP
    //      定时器跟着快 (P7B_GATE1 §B5 实测该参数对数据通路无影响但这是它的时基)。
    //   (`clk_in_100` / `sys_reset_p7b` 的**声明**在本块开头 —— 先声明后用)
    reg  [P7B_POR_BITS-1:0] p7b_por_cnt = {P7B_POR_BITS{1'b0}};
    wire                    p7b_por_n   = &p7b_por_cnt;
    always @(posedge clk_in_100) if (!p7b_por_n) p7b_por_cnt <= p7b_por_cnt + 1'b1;
    assign sys_reset_p7b = ~p7b_por_n;

    assign rx_core_clk_1 = rx_clk_out_1;        // 厂商 example 的接法 (自环恢复钟)
    assign rx_core_clk_0 = rx_clk_out_0;
    assign pcs_rx_reset_1 = 1'b0;               // 默认不请求复位核数据通路 (§B3)
    assign pcs_tx_reset_1 = 1'b0;
    assign pcs_rx_reset_0 = 1'b0;
    assign pcs_tx_reset_0 = 1'b0;

    // --- MAC 复位 (两域各自同步; 见文件里 rx_mac_rst_n/tx_mac_rst_n 的声明处注释) ---
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) rstn_rx_sr <= 3'b000;
        else          rstn_rx_sr <= {rstn_rx_sr[1:0], 1'b1};
    end
    always @(posedge tx_fe_clk or negedge reset_n) begin
        if (!reset_n) rstn_tx_sr <= 3'b000;
        else          rstn_tx_sr <= {rstn_tx_sr[1:0], 1'b1};
    end
    // `user_rx_reset_1` / `user_tx_reset_1` 都是**高有效** (MAC 端口文档写 rst_n = ~user_*_reset_*)
    assign rx_mac_rst_n = rstn_rx_sr[2] & ~pcs_user_rx_reset_1;
    assign tx_mac_rst_n = rstn_tx_sr[2] & ~pcs_user_tx_reset_1;

    // (SFP TX_DIS 的驱动在**后面**的 PCIE_OBS 段 —— 它用 `pcie_scratch` 做负对照,
    //  而 `pcie_scratch` 的声明在那一块里, xvlog 要求先声明后用)
`else
    // --- RGMII 适配 (实例名 u_rgmii 不可改, XDC generated clock 引用) ---
    // (`gmii_clk` 的**声明**已上移到本段之前的域别名处; 这里只驱动它)
    wire [7:0] e_rxd;
    wire       e_rxdv, e_rxer;
    wire [7:0] e_txd;
    wire       e_txen;
    wire       e_txer;

`ifdef DEV_USP
    util_gmii_to_rgmii_us u_rgmii (     // US+ 零 IDELAY 版 (bank86 HDIO 约束)
`else
    util_gmii_to_rgmii u_rgmii (        // K7 版 (IDELAYE2 10 tap + BUFG(~rxc))
`endif
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
`endif  // P7B_10G

    // --- P7b: 前端 (FE) 时钟的两个**域别名** ---------------------------------
    // 默认构建: FE RX 与 FE TX 是**同一个** gmii_clk ⇒ 两个别名都等于它, 纯线名,
    //   网表逐位不变 (与 dp_clk 别名的同一手法)。
    // P7B_10G:  RX 侧 = PCS 恢复钟 `rx_clk_out_1`; TX 侧 = `tx_mii_clk_1`。
    //   ⇒ `gmii_clk` 这个名字在本文件里继续表示"FE RX 域" (它被 u_mac_rx / u_rxcdc /
    //      wl_last / gmii_free / 快照 FE 束共用, 一处不改), 只有 TX 侧的
    //      u_mac_tx / u_txcdc 读口改挂 `tx_fe_clk`。
    //   ⚠️ 两个声明都放在**这里** (先声明后用: 复位同步器 / wl_last 等都在下面,
    //      而 `gmii_clk` 的驱动点在两个 ifdef 分支里各一个)。
`ifdef P7B_10G
    assign gmii_clk  = rx_clk_out_1;
    assign tx_fe_clk = tx_mii_clk_1;
`else
    assign tx_fe_clk = gmii_clk;
`endif

    //=========================================================================
    // P6b: 数据面时钟域 (clk_gen_p6b → 156.25MHz) 与**域别名** dp_clk / dp_rst_n
    //-------------------------------------------------------------------------
    // 方案 A (P6B_SPEC §0.1): 前端 `u_rgmii` / `u_mac_rx` / `u_mac_tx` 与 RGMII DDR I/O
    //   **留 125MHz**; `vlan_strip` 及其后**全部**搬到 156.25MHz 数据面域。两个域之间只有
    //   两处异步 FIFO 边界 (RX: u_rxcdc, TX: u_txcdc), 见 P6B_SPEC §2.2。
    //
    // 域别名的写法 (为什么不是把 gmii_clk 逐处换名):
    //   · 默认构建 (K7 各档 / P6a, **无 PCIE_OBS**) 里数据面 == 前端 ⇒ 本处把 dp_clk 别名成
    //     gmii_clk、dp_rst_n 别名成 reset_n ⇒ **整篇 always 语句块只有一份文本**, 两种构建
    //     走同一份源码 (`wire` 别名不产生任何逻辑) ⇒ P4 "K7 各档逐位不变"契约由此落地。
    //   · 极性: clk_gen_p6b 给的是**高有效** rst_dp (异步置位 / 4 拍同步释放)。这里取反成
    //     低有效的 dp_rst_n, 只是为了与既有 `negedge reset_n` 共用同一份文本 —— 与
    //     P6B_SPEC §6.1 的 rst_dp 是同一个信号的两种极性, 逻辑等价。
    //   ⚠️ **FIFO 的两侧复位绝不接 dp_rst_n**: 硬规则见 P6B_SPEC §4.4 —— 两个指针必须在
    //      "同一代"上复位, 所以 u_rxcdc/u_txcdc 的 wr_rst_n/rd_rst_n **都接板级 reset_n**。
    //      `mmcm_locked` 绝不进 FIFO 的复位路径 (dp_rst_n 只喂数据面**功能**逻辑)。
    //=========================================================================
`ifdef DP_156MHZ
`ifdef P6B_SIM_CLKGEN
    localparam SIM_CLKGEN_BYPASS = 1;   // 仿真: 行为级时钟模型 (不等 MMCM 锁定, P6B_SPEC R7)
`else
    localparam SIM_CLKGEN_BYPASS = 0;   // 综合: 真 IBUFDS + BUFG + MMCME4_BASE
`endif
    wire dp_clk;         // 156.25MHz
    wire dp_rst_dp;      // clk_gen_p6b 给的高有效复位 (异步置位 / 同步释放)
    wire mmcm_locked;    // MMCM LOCKED —— 只观测 / 参与复位释放, **不当复位用**
    clk_gen_p6b #(
        .SIM_BYPASS       (SIM_CLKGEN_BYPASS),
        .CLKIN1_PERIOD_NS (10.000),     // 必须与 ku5p_p6b_sysclk.xdc 的 create_clock 同值
        .CLKFBOUT_MULT_F  (12.500),     // VCO = 100/1 * 12.5 = 1250.0 MHz
        .DIVCLK_DIVIDE    (1),
        .CLKOUT0_DIVIDE_F (8.000),      // 1250/8 = 156.25 MHz ⇒ 6.400 ns
        .REF_JITTER1      (0.010)
    ) u_clkgen (
        .clk_p(sys_clk_p), .clk_n(sys_clk_n), .rst_ext(~reset_n),
`ifdef P7B_10G
        .clk_dp(dp_clk), .clk_in_100(clk_in_100), .locked(mmcm_locked), .rst_dp(dp_rst_dp)
`else
        .clk_dp(dp_clk), .clk_in_100(), .locked(mmcm_locked), .rst_dp(dp_rst_dp)
`endif
    );
    // ⚠️ 只接 CLKOUT0 —— 其余输出不接负载 ⇒ 不会多出 5.0–9.0ns 带内的第三个时钟
    //    (P6B_SPEC §8.3 的施工纪律; 本板 RGMII 在 HDIO 且零 IDELAY ⇒ 不需要 IDELAYCTRL
    //     ⇒ 不需要 200MHz)。
    wire dp_rst_n = ~dp_rst_dp;        // 低有效 (与 reset_n 同极性), 见上面极性说明
`else
    // 单域 (默认构建 / P6a): 数据面 = 前端时钟。**与 P6b 之前的网表逐位等价**
    //   (wire 别名无逻辑; dp_rst_n 直接就是 reset_n)。
    wire dp_clk   = gmii_clk;
    wire dp_rst_n = reset_n;
`ifdef PCIE_OBS
    // 单域构建里没有 MMCM ⇒ "锁定"恒真: 快照段 (PCIE_OBS) 的 W25 与 SNAP_STATUS[6] 仍要
    // 有一根线可读 (对抗审查 F1: 两个宏的四种组合都要能编过)。
    wire mmcm_locked = 1'b1;
`endif
`endif

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
`ifdef P7B_10G
    // P7b: 前端没有 GMII `rx_dv` ⇒ 这个"线上字节数"判别器的**等价来源**是
    //   `mac_rx_10g.dbg_rx_last_len` (最近交付帧的线上长度, 含 FCS) —— 口径相同
    //   (都是"整帧的线上字节数"), 且它在同一个 gmii_clk (= rx_core_clk) 域里。
    //   仍走寄存器 (快照束的 `din_b` 必须是寄存器输出)。
    //   (rx_d1/rx_dv_d1/rx_er_d1 那组 GMII 再寄存是 mac_rx_64 专用 ⇒ P7b 分支不存在)
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin wl_cnt <= 16'd0; wl_last <= 16'd0; end
        else          begin wl_cnt <= 16'd0; wl_last <= mac_rx_10g_last_len; end
    end
`else
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
`endif

    // --- mac_rx_64 → (P6b 异步 FIFO u_rxcdc) → vlan_strip ---
    // ⚠️ P6b 方案 A 的 **RX 异步边界** (P6B_SPEC §2.2/§3.1): u_mac_rx 留在前端 125MHz 域,
    //    它的 64 位 AXIS 输出经 u_rxcdc 跨到 156.25MHz 数据面域。
    //    背压: DP 消费者停 ⇒ u_rxcdc.full (FE 本地: 写指针 vs **同步过来的**读指针) ⇒
    //    u_mac_rx.m_axis_tready=0 ⇒ 其内部 8 深 FIFO 满 ⇒ **整帧丢** (stat_drop++)。这是
    //    rtl/mac_rx_64.v 头注释里已接受的背压合同, 由 W4/W26/W27 归因 (P6B_SPEC §3.4)。
    //    默认构建 (无 PCIE_OBS): FIFO 被**旁路**成纯线名别名 ⇒ 与 P6b 之前逐位等价。
    wire [63:0] rxsrc_tdata;                 // FE 侧 (u_mac_rx 输出)
    wire [7:0]  rxsrc_tkeep;
    wire        rxsrc_tvalid, rxsrc_tready, rxsrc_tlast, rxsrc_tuser, rxsrc_tcrs, rxsrc_terr;
    wire        rx_fifo_full, rx_fifo_empty; // FE 侧 full / DP 侧 empty (探针用)
    // ⚠️ 占用探针**无条件声明** (两个分支各自驱动): 快照段 (PCIE_OBS) 会引用它, 而它的
    //    生产者 (u_rxcdc) 只在双域分支里存在 ⇒ 若声明也放在双域分支里, "有 PCIe 窗口但
    //    单域"的构建会在快照段报 undeclared (对抗审查 F1 那个组合)。
    wire [8:0]  rxcdc_occ_w;                 // u_rxcdc 写域可见占用 (W27 的来源; 见 §7.2 探针)
    wire [31:0] rxcdc_ovf_cnt;               // P7b: u_rxcdc 拒写计数 (**FE = wr_clk 域**)
    wire [63:0] rx_tdata;                    // DP 侧 (FIFO 输出 → vlan_strip)
    wire [7:0]  rx_tkeep;
    wire        rx_tvalid, rx_tready, rx_tlast, rx_tuser, rx_tcrs, rx_terr;
    wire [31:0] rx_stat_frames, rx_stat_crc_err, rx_stat_drop, rx_stat_bytes;
    wire [31:0] rx_stat_drop_full, rx_stat_drop_partial, rx_stat_orphan_bytes, rx_stat_fifo_ovf;
    wire [31:0] mac_dbg_words_out, cls_dbg_words_in, cls_dbg_words_out;

    wire [63:0] f_tdata;
    wire [7:0]  f_tkeep;
    wire        f_tvalid, f_tready, f_tlast, f_tuser, f_tcrs, f_terr;
    wire [63:0] s_tdata;
    wire [7:0]  s_tkeep;
    wire        s_tvalid, s_tready, s_tlast, s_tuser, s_tcrs, s_terr;
    wire [31:0] cls_stat_fast, cls_stat_slow;
    // P7b: rx_classify v2 新增的 4 个观测 (旧 v1 没有这些输出)
    wire [31:0] cls_dbg_stat_ovf, cls_dbg_stat_route_ovf, cls_dbg_stat_stall_in;
    wire [4:0]  cls_dbg_occ;

`ifdef P7B_10G
    // ---- P7b: 64 位 XGMII MAC (自写, 单元门 252 判据/0 fail) ----
    // ⚠️ **字节序镜像在 MAC 内部** (`mac_rx_10g` 的 `align8` / `mac_tx_10g` 的
    //    `bswap64`, 见 P7B_MAC_DESIGN §2/§C.2) ⇒ 本 wrapper 是 1:1 直连:
    //      `xgmii_rxd[8l +: 8]` ↔ `rx_mii_d_1[8l +: 8]` (lane0 = 帧首字节)
    //    `xgmii_txd[8l +: 8]` ↔ `tx_mii_d_1[8l +: 8]`
    //    判据 (为什么这样接就对): 板上实测的起帧字 = `64'hD5555555555555FB`
    //    ⇒ lane0 = 0xFB = `/S/` 而合同要求 `tdata[63:56]` = 帧首字节 (DA0) (P7B_GATE1 §C.2)。
    mac_rx_10g u_mac_rx (
        .clk            (gmii_clk),
        .rst_n          (rx_mac_rst_n),
        .xgmii_rxd      (rx_mii_d_1),
        .xgmii_rxc      (rx_mii_c_1),
        .m_axis_tdata   (rxsrc_tdata),
        .m_axis_tkeep   (rxsrc_tkeep),
        .m_axis_tvalid  (rxsrc_tvalid),
        .m_axis_tready  (rxsrc_tready),
        .m_axis_tlast   (rxsrc_tlast),
        .m_axis_tuser   (rxsrc_tuser),
        .m_axis_terr    (rxsrc_terr),
        .m_axis_tcrs    (rxsrc_tcrs),
        .stat_frames        (rx_stat_frames),
        .stat_crc_err       (rx_stat_crc_err),
        .stat_drop          (rx_stat_drop),
        .stat_bytes         (rx_stat_bytes),
        // F4 四计数**名称逐字同 1G 版** ⇒ W32..W35 与 C10 守恒律一字不改地继续成立
        .stat_drop_full     (rx_stat_drop_full),
        .stat_drop_partial  (rx_stat_drop_partial),
        .stat_orphan_bytes  (rx_stat_orphan_bytes),
        .stat_fifo_ovf      (rx_stat_fifo_ovf),
        .dbg_stat_words_out (mac_dbg_words_out),
        // ---- P7b 新增: XGMII 层证据 (官方 PCS 的 stat_* 看不见这一层) ----
        .stat_rx_words      (mrx_stat_rx_words),
        .stat_rx_pay_bytes  (mrx_stat_rx_pay_bytes),
        .stat_rx_er_words   (mrx_stat_rx_er_words),
        .stat_rx_bad_words  (mrx_stat_rx_bad_words),
        .stat_rx_frag       (mrx_stat_rx_frag),
        .stat_rx_no_s       (mrx_stat_rx_no_s),
        .stat_rx_q          (mrx_stat_rx_q),
        .stat_rx_short      (mrx_stat_rx_short),
        .stat_rx_long       (mrx_stat_rx_long),
        .dbg_rx_last_len    (mac_rx_10g_last_len),
        .dbg_rx_last_tlane  (mrx_dbg_last_tlane),
        .dbg_rx_state       (mrx_dbg_state)
    );
`else
    mac_rx_64 u_mac_rx (
        .clk            (gmii_clk),
        .rst_n          (reset_n),
        .gmii_rxd       (rx_d1),
        .gmii_rx_dv     (rx_dv_d1),
        .gmii_rx_er     (rx_er_d1),
        .m_axis_tdata   (rxsrc_tdata),
        .m_axis_tkeep   (rxsrc_tkeep),
        .m_axis_tvalid  (rxsrc_tvalid),
        .m_axis_tready  (rxsrc_tready),
        .m_axis_tlast   (rxsrc_tlast),
        .m_axis_tuser   (rxsrc_tuser),
        .m_axis_terr    (rxsrc_terr),
        .m_axis_tcrs    (rxsrc_tcrs),
        .stat_frames    (rx_stat_frames),
        .stat_crc_err   (rx_stat_crc_err),
        .stat_drop      (rx_stat_drop),
        .stat_bytes     (rx_stat_bytes),
        // ---- P6b/F4 (2026-09-29): F4 修复新增的 4 个计数器 (前端 125MHz 域) ----
        //   W32/W33 是 C10 守恒律的必需项; W34/W35 是健康位 (W35 结构上恒 0)。
        //   必须**具名连接** (不接也能编译, 但 C10 就判不了)。
        .stat_drop_full     (rx_stat_drop_full),
        .stat_drop_partial  (rx_stat_drop_partial),
        .stat_orphan_bytes  (rx_stat_orphan_bytes),
        .stat_fifo_ovf      (rx_stat_fifo_ovf),
        .dbg_stat_words_out (mac_dbg_words_out)
    );
`endif  // P7B_10G

    // ---- P6b RX 异步 FIFO (W=**76** = 64 data + 8 keep + tuser + tlast + tcrs + terr) ----
    // ⚠️ 对抗审查 F6: 规格书写的 77 是**算术错** (64+8+1+1+1+1 = 76)。77 位端口接 76 位拼接
    //    功能上"良性"(补零), 但回程 `dout` 的 77 位赋给 76 位拼接会**静默截掉最高位** ——
    //    那正是 `rx_tdata[63]` = 每个字的**首字节** ⇒ 全线数据错位。位域顺序 (从 MSB 侧):
    //    {tdata[63:0], tkeep[7:0], tuser, tlast, tcrs, terr}。
    // FWFT=1: 与 fifo_sync/frame_fifo **语义逐条相同** (读侧零改动, 只是 clk → rd_clk)。
    // ⚠️ 深度 256 是从协议算出来的下界之上的取值: 一个 1518B 最大帧 = 190 字 (P6B_SPEC §4.2);
    //    FWFT=1 的读口是组合读 ⇒ 综合**只落 LUTRAM** (rtl/fifo_async.v:82-85) ⇒ 深度翻倍 =
    //    LUTRAM 翻倍, 而"最深停顿无上界"⇒ 弹性没有上界需求 ⇒ 取 256 (硬下界 190 之上)。
    // ⚠️ 两侧复位**都接板级 reset_n** (硬规则, 见 P6B_SPEC §4.4): 指针必须同代复位。
`ifdef DP_156MHZ
    fifo_async #(.WIDTH(76), .DEPTH(256), .FWFT(1), .AW(8)) u_rxcdc (
        .wr_clk(gmii_clk), .wr_rst_n(reset_n), .wr_en(rxsrc_tvalid),
        .din({rxsrc_tdata, rxsrc_tkeep, rxsrc_tuser, rxsrc_tlast, rxsrc_tcrs, rxsrc_terr}),
        .full(rx_fifo_full),
        .rd_clk(dp_clk),   .rd_rst_n(reset_n), .rd_en(rx_tvalid && rx_tready),
        .dout({rx_tdata, rx_tkeep, rx_tuser, rx_tlast, rx_tcrs, rx_terr}),
        .empty(rx_fifo_empty),
        .dbg_wbin(), .dbg_rbin(), .dbg_wgray(), .dbg_rgray(),
        .dbg_occ_w(rxcdc_occ_w), .dbg_occ_r(),
        // P7b: `fifo_async.ovf_cnt` 原来**悬空** (P7B_SPEC 点名的观测缺口) ⇒ 接出
        .ovf_cnt(rxcdc_ovf_cnt)
    );
    assign rxsrc_tready = ~rx_fifo_full;   // FE 侧反压 (本地组合, 不跨域)
    assign rx_tvalid    = ~rx_fifo_empty;  // FWFT: dout 就是头字
`else
    assign rx_tdata = rxsrc_tdata;         // 单域: 纯线名别名 (逐位不变)
    assign rx_tkeep = rxsrc_tkeep;
    assign rx_tuser = rxsrc_tuser;
    assign rx_tlast = rxsrc_tlast;
    assign rx_tcrs  = rxsrc_tcrs;
    assign rx_terr  = rxsrc_terr;
    assign rx_tvalid     = rxsrc_tvalid;
    assign rxsrc_tready  = rx_tready;
    assign rx_fifo_full  = 1'b0;           // 单域无此 FIFO (探针源恒 0)
    assign rx_fifo_empty = 1'b0;
    assign rxcdc_occ_w   = 9'd0;
    assign rxcdc_ovf_cnt = 32'd0;      // 单域: 无此 FIFO (P7b 探针源恒 0)
`endif

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
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
        .dbg_stat_words_out (cls_dbg_words_out),
        // ---- P7b: rx_classify v2 的 4 个新增观测 (纯观测, 悬空不影响功能) --------
        //   dbg_stat_ovf/route_ovf 是**自检计数**: 结构上恒 0 (字 FIFO 满 ⇒ 顶背压,
        //   路由队列因 rq_occ ≤ w_occ ≤ 15 < 16 不可能满) —— 一旦非 0 = 有东西被静默丢。
        //   dbg_stat_stall_in = 输入停等拍数; dbg_occ = 字 FIFO 当前占用 (0..16)。
        .dbg_stat_ovf       (cls_dbg_stat_ovf),
        .dbg_stat_route_ovf (cls_dbg_stat_route_ovf),
        .dbg_stat_stall_in  (cls_dbg_stat_stall_in),
        .dbg_occ            (cls_dbg_occ)
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
    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) acc_margin_eff <= 16'd4096;   // 复位 = N<=2 值 (零回归)
        else           acc_margin_eff <= acc_margin_of(acc_margin_n);
    end

    app_pattern #(.TX_BYTES(32'd1048576), .TX_SEGSZ(12'd1460)) u_app (
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
        .s_data         ({app_tx_tkeep, app_tx_tlast, app_tx_tdata, app_tx_tid}),
        .s_valid        (app_tx_tvalid),
        .s_ready        (app_tx_tready),
        .m_data         (app2_pack),
        .m_valid        (app2_tvalid),
        .m_ready        (app2_tready)
    );

    app_ctrl #(.WIN_CAP(WIN_CAP_5)) u_app_ctrl (
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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

`ifdef RXP_DIAG
    // ---- RXP_DIAG (ISSUE_RX_BYTE_CORRUPTION 专题): app_udp_pattern 首失配快照 ----
    // 只在 RXP_DIAG + APP_MODE 构建里存在 (诊断位流专用); 声明必须先于下面的
    // app_status_uart 例化 (坑 22/24: 先声明后用, 防隐式 1 位线静默截断)。
    wire [31:0] ds_idx_w, ds_b1_w, ds_b2_w, ds_bg_w, ds_dup_w;
    wire [7:0]  ds_got_w, ds_exp_w, ds_prev_w;
    // v2 (2026-09-26): 首失配整字 (收/期望) + 帧内偏移桶
    wire [63:0] ds_gw_w, ds_ew_w;
    wire [31:0] ds_oz_w, ds_ol_w, ds_om_w, ds_oh_w;
    // ---- RXP_DIAG v3 (2026-09-26): 帧边界记账 (udp_split 快照 → app_status_uart) ----
    // 声明必须先于 udp_split (下面 ~1490 行) 的例化 —— 且 ds_cap_w 是**唯一**新增的
    // 跨模块连线 (app_udp_pattern.ds_cap → udp_split.ds_cap)。
    wire        ds_cap_w;
    wire [63:0] v3_sw_w;
    wire [8:0]  v3_sf_w;
    wire        v3_sm_w;
    wire [7:0]  v3_wd_w;
    wire [9:0]  v3_fr_w, v3_fw_w, v3_fo_w, v3_fh_w;
    wire [1:0]  v3_fs_w;
    wire [15:0] v3_fn_w;
    wire [9:0]  v3_pr_w, v3_pw_w, v3_ph_w;
    wire [9:0]  v3_lr_w, v3_lw_w, v3_lo_w, v3_lh_w;
    wire [15:0] v3_rc_w, v3_vc_w;
    wire [9:0]  v3_vx_w, v3_vs_w, v3_vr_w;
    wire [15:0] v3_vn_w;
    // ---- RXP_DIAG v4 (2026-09-27): 异常帧路径计数 + 受损帧运行结构/事件 FIFO ----
    // 来源: udp_split (CN/RD/NC/NP/WF/RL/WC) 与 app_udp_pattern (NE/NR/MR/EN/EO/QA..QH)
    // → app_status_uart 的 v4 字段。与 v3 同款: **声明必须前置于两个来源例化点**
    // (app_status_uart 在下面 ~711 行, udp_split/app_udp_pattern 在 ~1514/~1733 行) —
    // 坑 22/24: 先声明后用, 防隐式 1 位线把 16/24 位连接静默截断。
    // 整段只在 `RXP_DIAG 下达 ⇒ 默认构建 (无宏) 的端口表/线网/逻辑逐位不变
    // (这些 wire 在默认构建里根本不存在)。
    wire [15:0] v4_cn_w, v4_rd_w, v4_nc_w, v4_np_w, v4_wf_w, v4_rl_w, v4_wc_w;
    wire [15:0] v4_ne_w, v4_nr_w, v4_mr_w;
    wire [3:0]  v4_en_w;
    wire        v4_eo_w;
    wire [23:0] v4_qa_w, v4_qb_w, v4_qc_w, v4_qd_w;
    wire [23:0] v4_qe_w, v4_qf_w, v4_qg_w, v4_qh_w;
    // ---- RXP_DIAG v5 (2026-09-27): 写数据口 (din) 的第二个 LFSR 校验器 + 解析器计数 ----
    // 来源 = udp_split 的 v5_dv_* (A 部) 与 v5_up_* (B 部) → app_status_uart 的 v5 字段。
    // A 部意义: v3 的 SW 按**帧号**定址, v5 的 DV/DM 按**纯字节计数**定址 ⇒ 两个机制
    //   不同的锚, 用来裁决 §14.6 那条"SW 采集依赖载荷字不与 meta_valid 同拍"的假设。
    // B 部意义: udp_rx 的 stat_pass 等在 udp_split 内部**一直悬空未用**, 现在零逻辑引出
    //   (判据: PS vs app 的 URF, 不等 ⇒ 解析器与 app 之间有丢帧/重帧)。
    // ⚠️ 同 v4 的教训 (§17.5): **未接 = 综合钳 0 = 假 0**, 与"从未触发"不可区分 ⇒
    //   本段接线由 tb_p5e_udp_wrapper.v 相 8 做正的存在性证明 (直取状态行模块入口)。
    wire [31:0] v5_dv_w, v5_dm_w;
    wire [7:0]  v5_dg_w, v5_de_w;
    wire [15:0] v5_do_w;
    wire        v5_vz_w;
    wire [31:0] v5_ps_w, v5_nm_w, v5_ic_w, v5_dc_w, v5_sb_w;
    // ---- RXP_DIAG v6 (2026-09-27): u_pre **输入侧** (s_axis) 的第三个 LFSR 校验器 ----
    // 来源 = udp_split 的 v6_dv_* → app_status_uart 的 v6 字段 (CV/CG/CE/CO/CM/CZ/CS)。
    // 意义 (§18.9/§18.10 的裁决点): v6 在 udp_split 的**输入端口侧** (进 u_pre 之前),
    //   ⇒ "v6 干净而 v5 损坏" = 重排在 u_pre/udp_rx 内部; "v6 也损坏" = 在
    //   mac_rx_64 / rx_classify / vlan_strip。
    // ⚠️ 同 v4/v5 的教训 (§17.5): **未接 = 综合钳 0 = 假 0**, 与"从未触发"不可区分 ⇒
    //   本段接线由 tb_p5e_udp_wrapper.v 相 9 做正的存在性证明 (直取状态行模块入口)。
    wire [31:0] v6_dv_w, v6_cm_w;
    wire [7:0]  v6_dg_w, v6_de_w, v6_cs_w;
    wire [15:0] v6_co_w;
    wire        v6_cz_w;
    // ---- RXP_DIAG v7 (2026-09-27): IP ID 序列检查 + v6 的非 UDP 帧口径修正 ----
    // 来源 = udp_split 的 v7_id_* (再往上游是 udp_rx 的 ip_id_* 检查器) + v7_nb
    //   (udp_split v6 段新增的"跳过的非 UDP 字节数") → app_status_uart 的 v7 字段。
    // 意义 (§18.15/§18.16): 事件形状已定死为整帧置换、发送方抓包干净 ⇒ 只剩
    //   "PC 侧 NIC/驱动 TX 打乱帧序" vs "PHY/GMII 接收裕量" 两条; IP ID 的
    //   到达顺序是这个判决的直接量 (IW>0 = 顺序确凿被打乱)。
    // ⚠️ 同 v4/v5/v6 的教训 (§17.5): **未接 = 综合钳 0 = 假 0**, 与"从未触发"
    //   不可区分 ⇒ 本段接线由 tb_p5e_udp_wrapper.v 相 10 做正的存在性证明
    //   (直取状态行模块入口 u_app_status.v7_*)。
    wire [15:0] v7_id_viol_w, v7_id_seen_w, v7_id_cur_w;
    wire [15:0] v7_id_prev_w, v7_id_back_w, v7_nb_w;
`endif

    wire [31:0] app_udp_stat_frames, app_udp_stat_bytes, app_udp_stat_null,
                app_udp_stat_drop_crc, app_udp_stat_drop_ovf,
                app_udp_stat_drop_part, app_udp_stat_drop_excl,
                app_udp_stat_hls_frames, app_udp_stat_hls_drop,
                app_udp_stat_hls_split;
    app_status_uart u_app_status (
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
`ifdef RXP_DIAG
        // RXP_DIAG 隐含 APP_MODE (build_p5_diag.tcl 同时定义两个宏); 上一行已有
        // 尾逗号, 故此处端口列表**不带前导逗号** (带前导 = 双逗号语法错)。
        .ds_idx (ds_idx_w),
        .ds_b1  (ds_b1_w),  .ds_b2  (ds_b2_w),  .ds_bg  (ds_bg_w),
        .ds_dup (ds_dup_w),
        .ds_got (ds_got_w), .ds_exp (ds_exp_w), .ds_prev (ds_prev_w),
        .ds_gw  (ds_gw_w),  .ds_ew  (ds_ew_w),
        .ds_oz  (ds_oz_w),  .ds_ol  (ds_ol_w),
        .ds_om  (ds_om_w),  .ds_oh  (ds_oh_w),
        // v3 (2026-09-26): 帧边界记账 (udp_split 快照)
        .v3_sw  (v3_sw_w),  .v3_sf  (v3_sf_w),
        .v3_sm  (v3_sm_w),  .v3_wd  (v3_wd_w),
        .v3_fr  (v3_fr_w),  .v3_fw  (v3_fw_w),
        .v3_fo  (v3_fo_w),  .v3_fh  (v3_fh_w),
        .v3_fs  (v3_fs_w),  .v3_fn  (v3_fn_w),
        .v3_pr  (v3_pr_w),  .v3_pw  (v3_pw_w),
        .v3_ph  (v3_ph_w),
        .v3_lr  (v3_lr_w),  .v3_lw  (v3_lw_w),
        .v3_lo  (v3_lo_w),  .v3_lh  (v3_lh_w),
        .v3_rc  (v3_rc_w),  .v3_vc  (v3_vc_w),
        .v3_vx  (v3_vx_w),  .v3_vs  (v3_vs_w),
        .v3_vr  (v3_vr_w),  .v3_vn  (v3_vn_w),
        // v4 (2026-09-27): 异常帧路径计数 + 受损帧运行结构/事件 FIFO
        // (端口/键名/口径见 rtl/app_status_uart.v 的 v4 段; 20 个字段)
        .v4_cn  (v4_cn_w),  .v4_rd  (v4_rd_w),  .v4_nc  (v4_nc_w),
        .v4_np  (v4_np_w),  .v4_wf  (v4_wf_w),  .v4_rl  (v4_rl_w),
        .v4_wc  (v4_wc_w),
        .v4_ne  (v4_ne_w),  .v4_nr  (v4_nr_w),  .v4_mr  (v4_mr_w),
        .v4_en  (v4_en_w),  .v4_eo  (v4_eo_w),
        // v5 (2026-09-27): 写数据口 (din) 的第二个 LFSR 校验器 + 解析器计数
        // (A 部 = udp_split.v5_dv_* → DV/DG/DE/DO/DM/VZ; B 部 = udp_split.v5_up_*
        //  → PS/NM/IC/DC/SB; 端口/键名/口径见 rtl/udp_split.v 与 app_status_uart.v 的 v5 段)
        .v5_dv_idx (v5_dv_w), .v5_dv_got (v5_dg_w), .v5_dv_exp (v5_de_w),
        .v5_dv_off (v5_do_w), .v5_dv_mm (v5_dm_w), .v5_dv_v (v5_vz_w),
        .v5_up_pass (v5_ps_w), .v5_up_nm (v5_nm_w), .v5_up_ipc (v5_ic_w),
        .v5_up_crc (v5_dc_w), .v5_up_bytes (v5_sb_w),
        // v6 (2026-09-27): u_pre 输入侧 (udp_split 的 s_axis) 的第三个 LFSR 校验器
        // (端口/键名/口径见 rtl/udp_split.v 与 rtl/app_status_uart.v 的 v6 段)
        .v6_dv_idx (v6_dv_w), .v6_dv_got (v6_dg_w), .v6_dv_exp (v6_de_w),
        .v6_dv_off (v6_co_w), .v6_dv_mm (v6_cm_w), .v6_dv_v (v6_cz_w),
        .v6_dv_sk (v6_cs_w),
        // v7 (2026-09-27): IP ID 序列检查 (IV/IS/IA/IB/IW) + v6 跳过的非 UDP 字节数 (NB)
        // (端口/键名/口径见 rtl/udp_rx.v · rtl/udp_split.v · rtl/app_status_uart.v 的 v7 段)
        .v7_id_viol (v7_id_viol_w), .v7_id_seen (v7_id_seen_w),
        .v7_id_cur  (v7_id_cur_w),  .v7_id_prev (v7_id_prev_w),
        .v7_id_back (v7_id_back_w), .v7_nb      (v7_nb_w),
        .v4_qa  (v4_qa_w),  .v4_qb  (v4_qb_w),  .v4_qc  (v4_qc_w),
        .v4_qd  (v4_qd_w),  .v4_qe  (v4_qe_w),  .v4_qf  (v4_qf_w),
        .v4_qg  (v4_qg_w),  .v4_qh  (v4_qh_w),
`endif
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
    // P6e: `mac_tx_64.stat_frames` 原来**悬空** (线上真发出去多少帧, 以前全设计没有这个数)
    //   ⇒ 接出来当观测 (PCIE_OBS 作快照 W20)。声明在 ifdef **外**: 例化点在 ifdef 外,
    //   若只在分支里声明, 默认构建会退化成"隐式 1 位线 ⇒ 静默截断"(工程坑 24)。
    //   默认构建里这根线无负载 ⇒ 综合后与改前逐位等价。
    wire [31:0] mac_tx_frames;
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
    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
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
    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
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

    // ---- P4b-7-P6-P6b: WL 异常触发拍锁存 (**留前端 gmii_clk 域**) ----
    // 触发判据 (fend && pcount < plen_l-4) 在帧尾后若干拍生效 (mac_rx/classify/
    // tcp_rx 流水延迟), 此时 wl_last 已是本帧线上字节数 (帧间保持, 无背靠背
    // 异常帧时即目标帧); sticky 首次锁存。
    // ⚠️ P6b 特例① (P6B_SPEC §3.5): 本块**故意留在 FE 域** —— 它锁存的是 FE 值 `wl_last`;
    //    但触发源 `rx_trace_rewind`/`rx_trace_frozen` 现在在 **DP 域** (由 u_tcp_rx 的
    //    探针驱动) ⇒ 必须加 2FF 同步器 (DP→FE, 1 位, ASYNC_REG)。
    //    为什么不让整块搬去 DP: 那会把 16 位的 `wl_last` 变成**无同步的多比特跨域** ⇒
    //    位混型假值 (rtl/snap_cdc.v 头注释警告的现象), 而它只在"WL 异常"时才被读,
    //    坏读几乎必被当成证据。同步的只是**1 位**触发, 语义无损 (`wl_last` 是帧间保持的
    //    值, 偏斜几十 ns 读到的仍是同一帧的长度)。
    (* ASYNC_REG = "TRUE" *) reg [1:0] rx_trace_rewind_sync;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) rx_trace_rewind_sync <= 2'b00;
        else          rx_trace_rewind_sync <= {rx_trace_rewind_sync[0], rx_trace_rewind};
    end
    reg [15:0] wl_last_lat;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            wl_last_lat <= 16'd0;
        end else if (rx_trace_rewind_sync[1] && !rx_trace_rewind_sync[0]) begin
            wl_last_lat <= wl_last;   // 同步后的上升沿 (=首次异常帧), 与 sticky 语义一致
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
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
        .s_data         ({eco_tkeep, eco_tlast, eco_tdata, eco_tid}),
        .s_valid        (eco_tvalid),
        .s_ready        (eco_tready),
        .m_data         (eco2_pack),
        .m_valid        (eco2_tvalid),
        .m_ready        (eco2_tready)
    );

    tcp_cam u_cam (
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
        .clk            (dp_clk),
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
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
`ifdef RXP_DIAG
        // v3 (2026-09-26): 帧边界记账快照。ds_cap 是本仪器**唯一**新增的跨模块
        // 信号 (app_udp_pattern 是"首失配"的唯一判定者, 见 udp_split.v 的 v3 段)。
        , .ds_cap       (ds_cap_w)
        , .v3_sw        (v3_sw_w)
        , .v3_sf        (v3_sf_w)
        , .v3_sm        (v3_sm_w)
        , .v3_wd        (v3_wd_w)
        , .v3_fr        (v3_fr_w)
        , .v3_fw        (v3_fw_w)
        , .v3_fo        (v3_fo_w)
        , .v3_fh        (v3_fh_w)
        , .v3_fs        (v3_fs_w)
        , .v3_fn        (v3_fn_w)
        , .v3_pr        (v3_pr_w)
        , .v3_pw        (v3_pw_w)
        , .v3_ph        (v3_ph_w)
        , .v3_lr        (v3_lr_w)
        , .v3_lw        (v3_lw_w)
        , .v3_lo        (v3_lo_w)
        , .v3_lh        (v3_lh_w)
        , .v3_rc        (v3_rc_w)
        , .v3_vc        (v3_vc_w)
        , .v3_vx        (v3_vx_w)
        , .v3_vs        (v3_vs_w)
        , .v3_vr        (v3_vr_w)
        , .v3_vn        (v3_vn_w)
        // v4 (2026-09-27): 异常帧路径计数器 (CN/RD/NC/NP/WF/RL/WC, 全部输出)
        , .v4_cn        (v4_cn_w)
        , .v4_rd        (v4_rd_w)
        , .v4_nc        (v4_nc_w)
        , .v4_np        (v4_np_w)
        , .v4_wf        (v4_wf_w)
        , .v4_rl        (v4_rl_w)
        , .v4_wc        (v4_wc_w)
        // v5 (2026-09-27): 写数据口 (din) 的第二个 LFSR 校验器 + 解析器计数
        // (A 部 udp_split.v5_dv_* → DV/DG/DE/DO/DM/VZ; B 部 udp_split.v5_up_* → PS/NM/IC/DC/SB)
        , .v5_dv_idx    (v5_dv_w)
        , .v5_dv_got    (v5_dg_w)
        , .v5_dv_exp    (v5_de_w)
        , .v5_dv_off    (v5_do_w)
        , .v5_dv_mm     (v5_dm_w)
        , .v5_dv_v      (v5_vz_w)
        , .v5_up_pass   (v5_ps_w)
        , .v5_up_nm     (v5_nm_w)
        , .v5_up_ipc    (v5_ic_w)
        , .v5_up_crc    (v5_dc_w)
        , .v5_up_bytes  (v5_sb_w)
        // v6 (2026-09-27): u_pre 输入侧 (s_axis) 的第三个 LFSR 校验器
        // (CV/CG/CE/CO/CM/CZ/CS; 见 rtl/udp_split.v / rtl/app_status_uart.v 的 v6 段)
        , .v6_dv_idx    (v6_dv_w)
        , .v6_dv_got    (v6_dg_w)
        , .v6_dv_exp    (v6_de_w)
        , .v6_dv_off    (v6_co_w)
        , .v6_dv_mm     (v6_cm_w)
        , .v6_dv_v      (v6_cz_w)
        , .v6_dv_sk     (v6_cs_w)
        // v7 (2026-09-27): IP ID 序列检查 (IV/IS/IA/IB/IW, 上游 = udp_rx 的 ip_id_*)
        // + NB (v6 段修掉 §18.16 尾伪影后, 被跳过的非 UDP 帧载荷字节数)
        // (见 rtl/udp_rx.v / rtl/udp_split.v / rtl/app_status_uart.v 的 v7 段)
        , .v7_id_viol   (v7_id_viol_w)
        , .v7_id_seen   (v7_id_seen_w)
        , .v7_id_cur    (v7_id_cur_w)
        , .v7_id_prev   (v7_id_prev_w)
        , .v7_id_back   (v7_id_back_w)
        , .v7_nb        (v7_nb_w)
`endif
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
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
        .ap_clk           (dp_clk),
        .ap_rst_n         (dp_rst_n & hls_rst_n),
        .reset_n          (dp_rst_n & hls_rst_n),
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
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
`ifdef RXP_DIAG
        , .ds_idx (ds_idx_w)
        , .ds_b1  (ds_b1_w),  .ds_b2  (ds_b2_w),  .ds_bg  (ds_bg_w)
        , .ds_dup (ds_dup_w)
        , .ds_got (ds_got_w), .ds_exp (ds_exp_w), .ds_prev (ds_prev_w)
        , .ds_v   ()
        , .ds_gw  (ds_gw_w),  .ds_ew  (ds_ew_w)
        , .ds_oz  (ds_oz_w),  .ds_ol  (ds_ol_w)
        , .ds_om  (ds_om_w),  .ds_oh  (ds_oh_w)
        // v3: 首失配触发脉冲 → udp_split (帧边界记账快照的唯一触发源)
        , .ds_cap (ds_cap_w)
        // v4 (2026-09-27): 受损帧运行结构 + 事件 FIFO (NE/NR/MR/EN/EO/QA..QH)
        , .v4_ne (v4_ne_w), .v4_nr (v4_nr_w), .v4_mr (v4_mr_w)
        , .v4_en (v4_en_w), .v4_eo (v4_eo_w)
        , .v4_ea (v4_qa_w), .v4_eb (v4_qb_w), .v4_ec (v4_qc_w), .v4_ed (v4_qd_w)
        , .v4_ee (v4_qe_w), .v4_ef (v4_qf_w), .v4_eg (v4_qg_w), .v4_eh (v4_qh_w)
`endif
    );

    udp_tx_cfg u_udp_tx_cfg (
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
    // ⚠️ P6b 方案 A 的 **TX 异步边界** (P6B_SPEC §2.2/§3.1): u_tx_arb 及其上游全部在
    //    156.25MHz 数据面域, u_mac_tx 留在前端 125MHz 域, 两者之间是 u_txcdc (W=73 =
    //    64 data + 8 keep + tlast —— mac_tx_64 的输入只有这三个字段)。
    //    背压: RGMII 线 125MB/s < DP 产能 ⇒ u_txcdc.full (DP 本地) ⇒ u_tx_arb.m_axis_tready=0
    //    ⇒ 不 grant ⇒ 源停 (TCP 靠窗口/ring 保住, UDP app 靠 utx_busy 停发, HLS 的
    //    frame_fifo 满后按既有语义整帧回卷 stat_purge=W18)。
    //    ⚠️ W21 (MAC 帧内中止) 的语义因此**升级**: DP 现在可以领先 MAC 最多 256 字
    //    (≈1.35 个最大帧) ⇒ 小抖动被吸收, 中止门槛 = "持续型 DP 断供" (P6B_SPEC §3.4)。
    wire [63:0] txsrc_tdata;                 // DP 侧 (u_tx_arb 输出)
    wire [7:0]  txsrc_tkeep;
    wire        txsrc_tvalid, txsrc_tready, txsrc_tlast;
    wire        tx_fifo_full, tx_fifo_empty; // DP 侧 full / FE 侧 empty
    wire [8:0]  txcdc_occ_w;                 // u_txcdc **写域 (= dp_clk)** 可见占用 (W28 来源
                                             //   —— 见快照段声明的口径说明: 占用探针一律
                                             //   取"写者那一侧" (对抗审查 F13: dbg_occ_w 是
                                             //   **上界**, dbg_occ_r 是下界; 只有"贴 256"那侧
                                             //   有判别力)。无条件声明, 同 rxcdc_occ_w)
    wire [63:0] m_tx_tdata;                  // FE 侧 (FIFO 输出 → u_mac_tx)
    wire [7:0]  m_tx_tkeep;
    wire [31:0] txcdc_ovf_cnt;               // P7b: u_txcdc 拒写计数 (**DP = wr_clk 域**)
    wire        m_tx_tvalid, m_tx_tready, m_tx_tlast;

    tx_arb u_tx_arb (
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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
        .m_axis_tdata   (txsrc_tdata),
        .m_axis_tkeep   (txsrc_tkeep),
        .m_axis_tvalid  (txsrc_tvalid),
        .m_axis_tready  (txsrc_tready),
        .m_axis_tlast   (txsrc_tlast)
    );

    // ---- P6b TX 异步 FIFO (W=73) ----
    // 深度硬下界 = 一个最大帧的字数 = ceil(1518/8) = 190 (P6B_SPEC §4.3): u_tx_arb 一次
    // 只放一帧 (busy 锁到 TLAST) ⇒ 想让 DP 预置下一帧, FIFO 必须装得下**整帧**。
    // 同 RX: FWFT=1 ⇒ LUTRAM ⇒ 取 256 (256/190 = 1.35 帧)。
    // ⚠️ 深度不是"越大越好": 它同时**放宽** W21 的触发条件 (§4.3 的警告)。
`ifdef DP_156MHZ
    fifo_async #(.WIDTH(73), .DEPTH(256), .FWFT(1), .AW(8)) u_txcdc (
        .wr_clk(dp_clk),   .wr_rst_n(reset_n), .wr_en(txsrc_tvalid),
        .din({txsrc_tdata, txsrc_tkeep, txsrc_tlast}), .full(tx_fifo_full),
        .rd_clk(tx_fe_clk), .rd_rst_n(reset_n), .rd_en(m_tx_tvalid && m_tx_tready),
        .dout({m_tx_tdata, m_tx_tkeep, m_tx_tlast}),   .empty(tx_fifo_empty),
        .dbg_wbin(), .dbg_rbin(), .dbg_wgray(), .dbg_rgray(),
        .dbg_occ_w(txcdc_occ_w), .dbg_occ_r(),
        .ovf_cnt(txcdc_ovf_cnt)
    );
    assign txsrc_tready = ~tx_fifo_full;    // DP 侧反压 (本地组合, 不跨域)
    assign m_tx_tvalid  = ~tx_fifo_empty;   // FWFT
`else
    assign txsrc_tdata = m_tx_tdata;        // 单域: 纯线名别名 (逐位不变)
    assign txsrc_tkeep = m_tx_tkeep;
    assign txsrc_tlast = m_tx_tlast;
    assign txsrc_tvalid= m_tx_tvalid;
    assign m_tx_tready = txsrc_tready;
    assign tx_fifo_full  = 1'b0;
    assign tx_fifo_empty = 1'b0;
    assign txcdc_occ_w   = 9'd0;
    assign txcdc_ovf_cnt = 32'd0;      // 单域: 无此 FIFO (P7b 探针源恒 0)
`endif

`ifdef P7B_10G
    mac_tx_10g u_mac_tx (
        .clk            (tx_fe_clk),         // = PCS tx_mii_clk_1 (见上面的域别名)
        .rst_n          (tx_mac_rst_n),
        .s_axis_tdata   (m_tx_tdata),
        .s_axis_tkeep   (m_tx_tkeep),
        .s_axis_tvalid  (m_tx_tvalid),
        .s_axis_tready  (m_tx_tready),
        .s_axis_tlast   (m_tx_tlast),
        // 镜像在 MAC 内部 (bswap64) ⇒ 逐位直连 PCS 的 XGMII 输入
        .xgmii_txd      (tx_mii_d_1),
        .xgmii_txc      (tx_mii_c_1),
        .stat_frames        (mac_tx_frames),   // W20 (名称逐字同 1G 版)
        .stat_abort         (tx_stat_abort),   // W21
        // ⭐ P7b **补上的观测缺口** (1G 版这两个计数在 wrapper 里零出现)
        .stat_flush_words   (mtx_stat_flush_words),
        .stat_flush_done    (mtx_stat_flush_done),
        .stat_tx_words      (mtx_stat_tx_words),
        .stat_tx_ctrl_char  (mtx_stat_tx_ctrl_char),
        .stat_tx_short      (mtx_stat_tx_short),
        .dbg_tx_last_clen   (mtx_dbg_last_clen),
        .dbg_tx_state       (mtx_dbg_state)
    );
`else
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
        .stat_frames    (mac_tx_frames),     // P6e: 原悬空 ⇒ 接出 (快照 W20); 默认构建无负载
        .stat_abort     (tx_stat_abort)
    );
`endif  // P7B_10G

`ifndef P7B_10G
    // ---- 默认构建: P7b 新增观测线的**常量占位** ------------------------------
    // 1G 的 mac_rx_64 / mac_tx_64 没有这些输出 (XGMII 层证据、F-2 冲刷计数、
    // 线上长度判别器)。给它们常量而不是让快照段悬空 —— 悬空会让 snap_cdc 的
    // `din_b` 采到 X, 并且会让 `axi_regs` 读回 X (假 PASS/假 FAIL 都难判)。
    // ⚠️ 常量满足快照束的前提 ("din_b 只在 clk_b 沿变化"), 不引入组合量。
    //   ⇒ 默认构建的快照字 W36.. 读回来恒 0, 这是**预期的**(不是缺陷)。
    assign mac_rx_10g_last_len  = 16'd0;
    assign mrx_stat_rx_words    = 32'd0;
    assign mrx_stat_rx_pay_bytes= 32'd0;
    assign mrx_stat_rx_er_words = 32'd0;
    assign mrx_stat_rx_bad_words= 32'd0;
    assign mrx_stat_rx_frag     = 32'd0;
    assign mrx_stat_rx_no_s     = 32'd0;
    assign mrx_stat_rx_q        = 32'd0;
    assign mrx_stat_rx_short    = 32'd0;
    assign mrx_stat_rx_long     = 32'd0;
    assign mrx_dbg_last_tlane   = 4'd0;
    assign mrx_dbg_state        = 2'd0;
    assign mtx_stat_flush_words = 32'd0;
    assign mtx_stat_flush_done  = 32'd0;
    assign mtx_stat_tx_words    = 32'd0;
    assign mtx_stat_tx_ctrl_char= 32'd0;
    assign mtx_stat_tx_short    = 32'd0;
    assign mtx_dbg_last_clen    = 16'd0;
    assign mtx_dbg_state        = 2'd0;
`endif

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
    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
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
    // ⚠️ P6b: boot/blink/LED/latch/UART 全部搬进 156.25MHz 数据面域 ⇒ 拍数 ×1.25。
    //    只有 P6b 构建 (PCIE_OBS) 用新值; 默认构建保持旧值 (逐位不变契约)。
    //    ⚠️ 39,062,500 > 2^25 (33,554,432) ⇒ **位宽必须加宽到 26 位**, 否则静默截断
    //    (P6B_SPEC §5.1 点名的那一条)。
`ifdef DP_156MHZ
    localparam [25:0] BOOT_HALF = 26'd31_250_000;   // 0.2s at 156.25MHz
`else
    localparam [25:0] BOOT_HALF = 26'd25_000_000;   // 0.2s at 125MHz
`endif
    reg [25:0] boot_cnt;   // P6b: 25 -> 26 位 (BOOT_HALF 新值 31,250,000 仍 < 2^25; 见下面 BLK_HALF)
    reg        boot_ph;                            // 0 = on half of the blink
    reg [2:0]  boot_h;                             // half index 0..5 (3 blinks)
    wire       boot_act = (boot_h < 3'd6);
    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            boot_cnt <= 26'd0;
            boot_ph  <= 1'b0;
            boot_h   <= 3'd0;
        end else if (boot_act) begin
            if (boot_cnt == (BOOT_HALF - 26'd1)) begin
                boot_cnt <= 26'd0;
                boot_ph  <= ~boot_ph;
                boot_h   <= boot_h + 3'd1;
            end else begin
                boot_cnt <= boot_cnt + 26'd1;
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
`ifdef DP_156MHZ
    localparam [25:0] BLK_HALF = 26'd39_062_500;    // 0.25s at 156.25MHz (需 26 位!)
`else
    localparam [25:0] BLK_HALF = 26'd31_250_000;    // 0.25s at 125MHz
`endif
    reg [25:0] blk_cnt;    // P6b: 25 -> 26 位 (BLK_HALF 新值 39,062,500 > 2^25)
    reg        blk_ph;                              // 0 = on half
    reg [4:0]  blk_idx;                             // 0..latch_val+4
    wire [4:0] n_blk  = {1'b0, latch_val} + 5'd1;   // blink slots (1..16)
    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            blk_cnt <= 26'd0;
            blk_ph  <= 1'b0;
            blk_idx <= 5'd0;
        end else if (latched) begin
            if (blk_cnt == (BLK_HALF - 26'd1)) begin
                blk_cnt <= 26'd0;
                blk_ph  <= ~blk_ph;
                if (blk_ph) begin                   // off half done: next slot
                    if (blk_idx == (n_blk + 5'd3)) blk_idx <= 5'd0;
                    else                            blk_idx <= blk_idx + 5'd1;
                end
            end else begin
                blk_cnt <= blk_cnt + 26'd1;
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
    // ⚠️ P6b: 切换点从"2^29 拍"改成"**同一墙钟**的拍数" ⇒ 671,088,640 = 2^29 + 2^27
    //    **不是 2 的幂** ⇒ 判据必须从"单个位测试 (!uart_sel[29])"改成**幅值比较**。
    //    `reg [29:0]` 的位宽够 (2^30 = 1.07e9 > 6.71e8) ⇒ 不需要加宽 (P6B_SPEC §5.1)。
    //    默认构建保持旧的位测试写法 (逐位不变契约)。
`ifdef DP_156MHZ
    localparam [29:0] UART_SW = 30'd671_088_640;   // 4.295s @156.25MHz (= 旧 2^29 @125MHz)
`else
    localparam [29:0] UART_SW = 30'h2000_0000;     // 2^29 (位测试等价; 4.295s @125MHz)
`endif
    reg [29:0]  uart_sel;
    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n)                 uart_sel <= 30'd0;
        else if (uart_sel < UART_SW)   uart_sel <= uart_sel + 30'd1;
    end
    assign uart_txd = (uart_sel >= UART_SW) ? app_uart_txd : p4_uart_txd;
`else
    assign uart_txd = p4_uart_txd;
`endif
    dbg_line_tx u_dbg_line (
        .clk            (dp_clk),
        .rst_n          (dp_rst_n),
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

`ifdef PCIE_OBS
    //=========================================================================
    // P6e: PCIe/XDMA 观测通道 + 数据面快照 (板级可读的"寄存器窗口")
    //-------------------------------------------------------------------------
    // 为什么需要它: 这块 KU5P 板上**没有 UART** (见 XCKU5PMini/CLAUDE.md), 传统 printf 式
    //   调试在这块板上不存在。PCIe 是唯一的高带宽观测通道: 主机 `reg_rw /dev/xdma0_user`
    //   直接读寄存器 ⇒ 不用 ILA、不用 JTAG 交互、可脚本化判定。
    //
    // 结构 (自下而上):
    //   23 路数据面计数 → ⑥snap_cdc (gmii_clk → axi_aclk 相干快照, 一次性锁存整束)
    //   → ⑤axi_regs (我们的 AXI4-Lite 寄存器块) → ④xdma_0 (user BAR) → 金手指 → 主机
    //
    // ⚠️ 跨时钟域是这里唯一的技术难点: 数据面在 PHY 回送的 gmii_clk(125MHz), 寄存器块在
    //   XDMA 的 axi_aclk(250MHz)。多比特计数**不能**用两级同步器直接跨 (各比特到达时刻不同
    //   ⇒ 读出来的是"位混"的假值, 而且看起来像数据面疯了) ⇒ 走 snap_cdc 的 toggle 握手,
    //   由它保证"整束来自同一个 gmii 沿"。
    // ⚠️ 快照**只在主机写 SNAP_CTRL 时更新**, 不自动刷新 —— 理由是主机读 N 个字要走 N 笔
    //   独立 PCIe 事务, 自动刷新会让读出来的字跨越两代快照 (寄存器文件这一层撕裂,
    //   CDC 再相干也救不了)。详见 _proj_pcie/rtl/axi_regs.v 头注释。
    // ⚠️ 复位复用 reset_n (板上就是 PCIe 槽的 PERST#, J9) —— 与厂商 BD 的接法一致。
    //=========================================================================

    // ---- 0. 线网声明先行 (xvlog 先声明后用; 也防隐式 1 位线 —— 工程坑 24) ----
    // ⚠️ 快照字数 = **单一来源**: snap_src 拼接项数 / snap_cdc.NW / snap_dout 与 snap_src 的位宽
    //    / axi_regs.SNAP_NW 全从这里推导。手写 256 的教训: 扩到 16 字时源头与回程**两条线**都
    //    会被静默截断成"上 256 位悬空 ⇒ 读回 X", 而 **xvlog 的位宽检查不覆盖端口连接**
    //    (lint 全绿) ⇒ 这种错只有例化真 wrapper 的全链门能抓 (判据 6 的 W8-W15 读回 zzzz 就是它)。
    // ⚠️ **扩窗要五处同改** (24 字版起定为五处 —— "三处/四处"的旧说法漏了 ③⑤):
    //    ① 本 localparam ② snap_src 拼接项数 ③ `axi_regs` 里 `snap_base` 的**位宽**
    //    (装不下 ⇒ 高位静默截断 ⇒ 高地址字回绕读低地址字; 24 字版已加宽到 [9:0])
    //    ④ `axi_regs.SNAP_NW` (同一参数) ⑤ **验收/采样脚本里"未实现地址"的取值** (0x60→0x84)。
    //    ⑤ 绝不能挑 ≥0x100: `ar_word = araddr[7:2]` 6 位 ⇒ 地址每 256 字节回绕。
    // 字宽 24 (2026-09-29 从 16 扩上来): 动机 = 钉死"慢路径失聪"现象的机理。
    // 字宽 32 (P6b, 2026-09-29): 数据面搬 156.25MHz ⇒ **快照被拆成两个域的两束**, 每束各挂
    //    一个 snap_cdc, 由链式序列器 rtl/snap_seq.v 定序 (**FE 先 → DP 后**)。新增 8 个字
    //    W24-W31 全是"跨域完整性锚点"与"新时钟域的正证据" (见下面 §7.1 注释)。
    // ⚠️ 扩窗的处数从"五处"变成**七处** (P6B_SPEC §7.4): 多出来的两处是
    //    ⑥ 三个门自己的参数 (tb_axi_regs / tb_snap_cdc / tb_p6e_pcie_*) 
    //    ⑦ **两束的索引表** (rtl/snap_seq.v 的 fe_idx_of/dp_idx_of —— 它们必须与下面
    //       fe_src/dp_src 的**拼接项数与顺序**逐项一致; 错一处只会读出"另一个字的正确值")。
    //    ⇒ 唯一能抓 ⑥⑦ 的手段是**逐字读回 32 个字**(全链门)，lint 全程沉默。
    // 字宽 51 (P7b, 2026-09-29): 36 → 51 (**硬上限 56**, 见下面的预算)。
    //   动机 = P7b 前端的观测面: 官方 PCS 的 stat_* + 新 MAC 的 XGMII 层证据 +
    //   两个点名补上的缺口 (`mac_tx_*.stat_flush_*`、`fifo_async.ovf_cnt`) +
    //   `rx_classify` v2 的 4 个新 dbg。
    //   ⚠️ **预算怎么算的** (先算再改, 不许"试试看"):
    //     硬上限来自读侧地址译码 `ar_word = araddr[7:2]` (6 位 ⇒ 字 0..63) 而快照从
    //     word 8 起 ⇒ **最多 56 字** (64 - 8)。51 ≤ 56 ✓ 余 5 字。
    //     同一处还有 **`snap_base` 的位宽** (见 `_proj_pcie/rtl/axi_regs.v`):
    //     `{snap_idx,5'b0}` 最大 = (51-1)<<5 = 1600 ⇒ **必须 ≥ 12 位** (旧 11 位会
    //     **静默回绕**: 高地址字读回低地址字的值 = 假 PASS)。本轮的 36→51 一并改了。
    //     还有 **`snap_idx`**: `r_word[5:0] - 8` 最大 55 ⇒ 6 位仍够 (未变)。
    localparam SNAP_NW_P6E = 51;        // 总字数 W0..W50
    // ⚠️ 这两个是 **snap_seq (链式序列器)** 的两束, **P7b 未改** —— P7b 的 15 个新字走
    //    三条独立的 snap_cdc 束 (见采集段的"三束并行"注释), 所以这里仍是 14/22。
    localparam SNAP_FE_NW  = 14;        // FE 束字数 (b 域 = gmii_clk)
    localparam SNAP_DP_NW  = 22;        // DP 束字数 (b 域 = dp_clk)
    // P7b 三条新束的字数 (与上面同源: 装配段 `snap_dout_all` 的项数必须与之对账)
    localparam SNAP_P7BFE_NW = 3;       // W36..W38 (b 域 = gmii_clk)
    localparam SNAP_P7BDP_NW = 12;      // W39/W40, W45..W50 (b 域 = dp_clk)
    localparam SNAP_TX_NW    = 4;       // W41..W44 (b 域 = tx_mii_clk)
    wire         pcie_clk_gt, pcie_clk;
    wire         pcie_axi_aclk, pcie_axi_aresetn;
    wire         pcie_lnk_up, pcie_msi_enable;
    wire [2:0]   pcie_msi_vec_w;
    wire [0:0]   pcie_irq_ack;
    wire [31:0]  pcie_awaddr, pcie_wdata, pcie_araddr;
    wire [2:0]   pcie_awprot, pcie_arprot;
    wire [3:0]   pcie_wstrb;
    wire         pcie_awvalid, pcie_awready, pcie_wvalid, pcie_wready;
    wire [1:0]   pcie_bresp;
    wire         pcie_bvalid, pcie_bready, pcie_arvalid, pcie_arready;
    wire [31:0]  pcie_rdata;
    wire [1:0]   pcie_rresp;
    wire         pcie_rvalid, pcie_rready;
    wire         snap_req, snap_valid;
    wire         snap_seq_busy;        // snap_seq 自己的 busy
    wire         snap_busy;            // = 五束的 busy 之和 (P7b 扩展)
    // ---- P6b: 两个束 + 链式序列器的握手线 ----
    wire         req_fe, req_dp, busy_fe, busy_dp, valid_fe, valid_dp;
    wire [2:0]   snap_fe_state;        // {fe_busy, fe_seen, fe_done} → SNAP_STATUS[5:3]
    wire [SNAP_FE_NW*32-1:0] fe_dout;
    wire [SNAP_DP_NW*32-1:0] dp_dout;
    // ⚠️ 宽度必须由 SNAP_NW_P6E 推导: 手写常数 (如 256 = 8 字时代 / 512 = 16 字时代) 会让
    //    snap_cdc 的**高位悬空** ⇒ axi_regs 采到的那些字全是 X。这是同一处坑的**另一半**:
    //    源头那侧 (snap_src) 修好只能让"送进 CDC 的数据"对, 回程这条线宽度不对照样白搭
    //    —— 两边都要跟着 NW 走 (扩窗时这两条线是分开改的, 漏一条的症状都像"数据面坏了")。
    // ⚠⚠ 宽度必须是 **snap_seq 自己的** FW+DW (=36), 不是总字数 51:
    //    写成 SNAP_NW_P6E 会让下面 `snap_dout_all` 的拼接**多出 480 位**
    //    ⇒ 新加的 15 个字被**静默截掉** (顶端 15 槽 变成 snap_dout 未驱动的高位 = **z**)。
    //    本轮实测踩到并修正 (DIAG7b 读 r36/r50 = zzzzzzzz, 而三条 seen 全 1)。
    //    同族结论: **拼接项数/位宽错一处都不会被 xvlog 报出来** —— 只有逐字读回的门能抓。
    wire [SNAP_FE_NW*32 + SNAP_DP_NW*32 - 1:0] snap_dout;   // = snap_seq 装配好的 36 字 (同 axi 域)
    wire [31:0]  pcie_hw_status, pcie_scratch, pcie_wr_cnt;
    wire         pcie_decode_err;
    // (快照字数 localparam 见本段开头的声明区 —— 必须在那里, xvlog 先声明后用)
    wire [SNAP_FE_NW*32-1:0] fe_src;
    wire [SNAP_DP_NW*32-1:0] dp_src;
    reg  [31:0]  gmii_free;
    // ---- W16/W17 要用的两个**新增计数器** (gmii 域寄存器输出 ⇒ 满足 snap_cdc 的 CDC 前提:
    //      din_b 只在 clk_b 沿变化; snap_src 里其余各路也都是寄存器, 这里不能引入组合量) ----
    // srx_hls_bytes: 累加"**HLS 真读走的字节数**" = HLS rx_stream 上 `tvalid && tready` 的**字节拍数**。
    //   口径说明 (为什么按拍计而不是 popcount): `slow_rx_adp` 到 HLS 的接口是 **9 位字节流**
    //   `{TLAST, byte}` (rtl/slow_rx_adp.v 的 hls_rx_tdata/_tvalid/_tready), **一拍恰好一个字节**,
    //   没有 tkeep 可数 ⇒ 接受拍数 ≡ 字节数。它包含每帧 8 字节前导 (0x55×7 + 0xD5), 所以
    //   它与 `srx_stat_commit`(帧数) 的比例 ≈ 帧长+8, 不是纯内容字节 —— 判读时按"涨不涨"看。
    //   ⚠️ 为什么它才是真正的"HLS 读了"证据: `srx_stat_commit` (W6) 在适配器**输入侧**帧尾自增
    //   (只说明排进了给 HLS 的缓冲), `stx_stat_frames` (W7) 在 slow_tx_adp 写自己的 wf FIFO 时
    //   自增 (冻结既可能"没产生"也可能"产生了被回卷")。本计数在**消费侧**, 与 FIFO 的 rd 是
    //   同一个表达式 (`hls_rx_tvalid && hls_rx_tready` 就是 slow_rx_adp 的 o_pop) ⇒ 它停 = HLS 真的不读了。
    //   (核实过: wrapper 里就能看见这个握手, **不需要**给 slow_rx_adp 加端口 —— 那会动数据面。)
    reg  [31:0]  srx_hls_bytes;
    // hr_cnt: `hls_rst_n` 为低的 gmii 拍数 (÷64 = 看门狗复位次数, 每次低电平 64 拍 = 512ns)。
    //   为什么必须用计数而不是把它当一个位塞进快照: 低电平只持续 512ns, 而快照是**采样**
    //   ⇒ 瞬时命中率 ~1%, 当位用几乎永远读不到。累计拍数则单调可见。
    reg  [31:0]  hr_cnt;
    // =====================================================================
    // P6b 新增仪表 (W24..W31) —— 每一条都要能"独立复算", 见 P6B_SPEC §7.1
    // =====================================================================
    // 【W24】dp_free: **数据面域 (156.25MHz) 32 位自由计数器** = "数据面真跑在新时钟上"的
    //   唯一正证据。判据 (可独立复算): 两次快照之间 ΔW24 / 墙钟间隔 = 156.25MHz ±1%
    //   (32 位 @156.25MHz 每 27.49s 绕一圈 ⇒ 判据的窗口必须 < 20s)。
    reg  [31:0]  dp_free;
    // 【W25】mmcm_locked 的两个域同步版 (DP 束里的那一位 + SNAP_STATUS[6] 的镜像)。
    //   为什么要两处: DP 束在"DP 时钟停摆"时读不到 ⇒ 卡住时只剩 SNAP_STATUS[6] 可用
    //   (P6B_SPEC §6.4)。
    reg  [1:0]   mmcm_locked_sr_dp;
    reg  [1:0]   mmcm_locked_sr_axi;
    // 【W26】rxcdc_full_cycles: u_rxcdc.full 高电平**拍数** (FE 域) —— RX 方向"DP 跟不上"
    //   的直接量。独立复算: 与本域 W0(收帧) 同时看 —— W4 随 W0 涨且 W26 单调涨 ⇒ 确认是
    //   新 FIFO 造成的丢帧 (P6B_SPEC §4.2 的症状判据)。零新增域 (full 本来就在 FE)。
    reg  [31:0]  rxcdc_full_cycles;
    // 【W27】rxcdc_occ_max: u_rxcdc 在**写域**看到的历史最大占用(字) = 深度探针。
    //   独立复算: 它必须恒 <= DEPTH=256, 且一次板级跑里"峰值贴 256"就意味着深度真不够。
    reg  [15:0]  rxcdc_occ_max;   // 只用到 9 位, 高 7 位恒 0 (拼成 {16'd0,...} = 32 位)
    // 【W28】txcdc_occ_max: u_txcdc 在**写域 (= dp_clk)** 看到的历史最大占用。
    //   ⚠️ 口径说明 (与 P6B_SPEC §7.1 的字面表述有一处刻意的技术选择): 取 **dbg_occ_w**
    //   (写域) 而不是 dbg_occ_r (读域) —— DBG_OCC_R 属于 **gmii_clk 域**, 直接塞进 DP 束就是
    //   多比特 CDC (snap_cdc 头注释警告的位混)。两个 FIFO 的占用探针一律取"**写者那一侧**":
    //   RX FIFO 的写者是 FE ⇒ W27 在 FE 束; TX FIFO 的写者是 DP ⇒ W28 在 DP 束。
    reg  [15:0]  txcdc_occ_max;   // 同上
    // 【W29】txwire_stall_cycles: DP 侧 `txsrc_tvalid==1 && txsrc_tready==0` 的拍数 ——
    //   区分"DP 在等线"(W29 大而 W18 不涨) vs "DP 在丢帧" (P6B_SPEC §4.3)。
    reg  [31:0]  txwire_stall_cycles;
    // 【W30/W31】RX FIFO **读侧**的帧数 / 字节数 —— 跨域完整性锚点。
    //   独立复算 (逐位等式, P6B_SPEC §7.3 的证明): Σpopc(tkeep) + 4×帧数 ≡ MAC 的 stat_bytes
    //   ⇒ 停机态 (RX FIFO 必空) 下必须 **W0==W30 且 W1==W31 逐位相等**; 跑流量时
    //   `0 <= W0-W30 <= 界` 且不漂移 (有向! 链式触发保证 W30 的采样不早于 W0)。
    reg  [31:0]  rxcdc_out_frames;
    reg  [31:0]  rxcdc_out_bytes;
    // 8 位 popcount (W31 的口径: 一帧的 Σpopc(tkeep) = 内容字节数)
    function [3:0] popc8;
        input [7:0] k;
        integer i;
        begin
            popc8 = 4'd0;
            for (i = 0; i < 8; i = i + 1) popc8 = popc8 + {3'd0, k[i]};
        end
    endfunction

    // ---- 1. 参考钟: 与厂商 BD 逐条同构 (O→sys_clk_gt, ODIV2→sys_clk, 不加 BUFG_GT) ----
    IBUFDS_GTE4 #(
        .REFCLK_EN_TX_PATH (1'b0),
        .REFCLK_HROW_CK_SEL(2'b00),
        .REFCLK_ICNTL_RX   (2'b00)          // ⚠️ 2025.2 的参数名是 ICNTL_RX (不是 TX), 2 位
    ) u_pcie_refclk (
        .O    (pcie_clk_gt),
        .ODIV2(pcie_clk),
        .I    (pcie_sys_clk_p),
        .IB   (pcie_sys_clk_n),
        .CEB  (1'b0)
    );

    // ---- 2. 快照数据源 (gmii_clk 域; 全部是寄存器输出 ⇒ 只在 gmii 沿变化, 满足 CDC 前提) ----
    // 24 个字 (NW=24, 2026-09-29 从 16 扩上来): W0-W15 **逐位保持原义** (已有板级基线读数
    // 依赖它们, 所以新项一律加在拼接的**最高位侧** —— 拼接 LSB 端是 W0 = 地址最低),
    // W16-W23 是这一轮为"**慢路径失聪**"现象加的健康位 + MAC 级 TX 锚点。
    //   W0 线上有帧吗 → W1 多少字节 → W2 那一帧有多长 (66 vs 1518) → W3 FCS 干净吗
    //   → W4 被丢了吗 → W5 gmii 时钟在跑吗 → W6 慢路径收下了吗 (ARP/ICMP) → W7 HLS 回了吗
    //   → W8/W9 图案 app 发出 → W10/W11 图案 app 收到 → W12 空帧 → W13 图案失配(必须恒 0)
    //   → W14/W15 **TCP fast path** 的 tcp_tx_frame 计数 (⚠️ **不是 MAC**: mac_tx_64.stat_frames
    //     在本 wrapper 里原先悬空, 现在接到了 W20; 图案走 UDP 通路 ⇒ W14/W15 正确读 0,
    //     别当成"MAC 没发" —— 要看 MAC 发帧数请看 W20)
    //   → W16 HLS 真读走的字节 (⚡ 与 W6 配对: W6 涨而 W16 不涨 = HLS 不吃了)
    //   → W17 hls_rst_n 低电平拍数 (÷64 ≈ 饥饿看门狗复位次数; ⚡ 与 W16/W7 同时看)
    //   → W18 slow_tx_adp 回卷帧数 (⚡ 解释 W7 冻结: 是"没产生"还是"产生了被回卷")
    //   → W19 slow_rx_adp 丢帧数 (坏 FCS/rx_er/fifo 满/截断)
    //   → W20 **MAC 级**发帧数 (线上真发出去多少帧; 以前全设计没有这个数)
    //   → W21 MAC 帧内中止数 (源流断供 ⇒ runt, mac_tx_64.stat_abort)
    //   → W22 TCP fast path 接受帧数 → W23 TCP fast path 最大丢帧桶 (nonmatch)
    // ⚠️ 拼接项数必须**恰好 SNAP_NW_P6E**: 少一项 ⇒ 高位悬空 (X); 多一项 ⇒ 被截断。
    //    两者都不会被 xvlog 的位宽检查报出来 (不覆盖端口连接) ⇒ 只有全链门能抓
    // ⚠️ `udpapp_*` 的 wire 声明在 wrapper 里是**无条件**的, 但驱动它们的 app_udp_pattern 只在
    //    `ifdef APP_MODE 里 ⇒ 本块与 APP_MODE 是一对 (P6e 构建固定 APP_MODE=1 ✓)。若将来做
    //    "PCIE_OBS 但不带 APP_MODE" 的构建, W8-W13 会是未驱动线 (读出来是 X/0), 不是缺陷。
    // ⚠️ P6b §3.5 特例②: 原来 gmii_free / srx_hls_bytes / hr_cnt 写在**同一个** always 块里。
    //    搬域后三个计数器分属两个域 ⇒ **必须拆成两块**:
    //      · gmii_free 留 FE (**故意的**: 它是"PHY 回送的时钟还在跑吗"的活性锚点, 搬走就等于
    //        毁掉这个判据);
    //      · srx_hls_bytes / hr_cnt → DP (`hls_rx_tvalid/tready` 与 `hls_rst_n` 都来自 DP 域的
    //        u_slow_rx)。
    //    P6b 新增的同域仪表跟着各自的域走 (W26/W27 → FE, W24/W25/W28/W29/W30/W31 → DP)。
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            gmii_free         <= 32'd0;
            rxcdc_full_cycles <= 32'd0;
            rxcdc_occ_max     <= 16'd0;
        end else begin
            gmii_free <= gmii_free + 32'd1;
            // W26: u_rxcdc.full 高电平拍数 (RX 方向"DP 跟不上"的直接量)
            if (rx_fifo_full) rxcdc_full_cycles <= rxcdc_full_cycles + 32'd1;
            // W27: 写域可见占用的历史最大 (深度探针); 9 位探针零扩展后比较
            if ({7'd0, rxcdc_occ_w} > rxcdc_occ_max) rxcdc_occ_max <= {7'd0, rxcdc_occ_w};
        end
    end

    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            srx_hls_bytes       <= 32'd0;
            hr_cnt              <= 32'd0;
            dp_free             <= 32'd0;
            txwire_stall_cycles <= 32'd0;
            txcdc_occ_max       <= 16'd0;
            rxcdc_out_frames    <= 32'd0;
            rxcdc_out_bytes     <= 32'd0;
            mmcm_locked_sr_dp   <= 2'b00;
        end else begin
            // 字节拍数 (见上面 srx_hls_bytes 声明的口径注释) —— 与 slow_rx_adp 的 o_pop 同式
            if (hls_rx_tvalid && hls_rx_tready) srx_hls_bytes <= srx_hls_bytes + 32'd1;
            // 看门狗复位脉冲的**持续拍数**; 低电平只 RST_CNT 拍 (P6b: 80) ⇒ 只能累计
            if (!hls_rst_n)                     hr_cnt        <= hr_cnt + 32'd1;
            // W24: 数据面域自由计数 (本模块唯一的"这个域真在跑"的正证据)
            dp_free <= dp_free + 32'd1;
            // W29: DP 在等线 (有字要发但下游不收)
            if (txsrc_tvalid && !txsrc_tready) txwire_stall_cycles <= txwire_stall_cycles + 32'd1;
            // W28: u_txcdc **写域**可见占用的历史最大 (深度探针; 见声明处的口径说明)
            if ({7'd0, txcdc_occ_w} > txcdc_occ_max) txcdc_occ_max <= {7'd0, txcdc_occ_w};
            // W30/W31: RX FIFO 读侧 (TLAST 数 / Σpopc(tkeep))
            if (rx_tvalid && rx_tready) begin
                if (rx_tlast) rxcdc_out_frames <= rxcdc_out_frames + 32'd1;
                rxcdc_out_bytes <= rxcdc_out_bytes + {28'd0, popc8(rx_tkeep)};
            end
            // W25: MMCM locked 的 DP 域同步版 (2FF)
            mmcm_locked_sr_dp <= {mmcm_locked_sr_dp[0], mmcm_locked};
        end
    end

    // W25 的第二处 (SNAP_STATUS[6]): axi 域同步版 —— DP 时钟停摆时只有它可读
    always @(posedge pcie_axi_aclk or negedge pcie_axi_aresetn) begin
        if (!pcie_axi_aresetn) mmcm_locked_sr_axi <= 2'b00;
        else                   mmcm_locked_sr_axi <= {mmcm_locked_sr_axi[0], mmcm_locked};
    end

    // =====================================================================
    // =====================================================================
    // P7b: 新增仪表的采集 (W36..W50) —— **三束并行**方案, 逐条给理由
    //----------------------------------------------------------------------
    // 为什么不把它们塞进 snap_seq 的 FE/DP 束 (那本来更"整齐"):
    //   snap_seq 的映射表是**单一来源 + 带自检**的 (rtl/snap_seq.v), 改它就必须同步改
    //   它的单元门 `tb/tb_snap_seq.v` 里那张**手抄的 36 行对照表**和一串硬写位宽。
    //   本轮的选择 = **不动那条已验收的路径**, 用**同一个 snap_cdc 原语**并行加三束,
    //   在 axi 域装配。代价 = 多三个 `seen` 锁存; 收益 = snap_seq / tb_snap_seq /
    //   axi_regs 的**接口一字未改** (只有读侧 `snap_base` 的位宽按扩窗规则加宽)。
    //
    // 三束 (全部 `clk_a = pcie_axi_aclk`, `req_a = snap_req` —— 主机那一个写脉冲):
    //   u_snap_p7bfe : clk_b = gmii_clk (= PCS 恢复钟)  NW=3  → W36/W37/W38
    //   u_snap_p7bdp : clk_b = dp_clk                   NW=12 → W39/W40, W45..W50
    //   u_snap_tx    : clk_b = tx_fe_clk (= tx_mii_clk) NW=4  → W41..W44
    // ⚠️ W41..W44 在 **tx 域** ⇒ 归 u_snap_tx (多比特计数器**不许** 2FF)。
    //    装配顺序见下面的 `snap_dout_all` (逐项写出, 不靠"拼接从右往左"这种记忆)。
    //
    // ⚠️ 同步手法逐条按 P7B_GATE1 §B4 的实证:
    //   · PCS 的 `stat_*`: 只有 `block_lock` 有网表实证 (dclk); 其余**域未确证**
    //     ⇒ 一律按异步处理, **每位一个 2FF** (电平信号)。`rx_error[7:0]` 是**逐 lane**
    //     的指示位 (每 bit 一条 lane), 位间偏斜不是"数值错误" ⇒ 每 bit 各一个 2FF 可以,
    //     但**语义必须按位读** (不得当 8 位数值引用)。
    //   · `block_lock` 本身在 dclk 域 (实证) ⇒ 同一个 2FF 手法对它是"跨域"而非"同步",
    //     但它是**慢变电平** ⇒ 2FF 是正确的处理 (不是脉冲)。
    //   · 三条新束与 snap_seq 的两束**同代**: 同一个 `snap_req` 触发, 完成后由
    //     `snap_valid_all` 一起放行 ⇒ 51 个字来自**同一代**读数。
    // =====================================================================
`ifdef P7B_10G
    // ---------------------------------------------------------------------
    // ch0 (= X0Y4 = J7, 无线) 的**全部未用输出折叠成一个签名位**
    //----------------------------------------------------------------------
    // ⚠⚠ 这不是装饰: 若 ch0 的状态/控制输出**完全无负载**, Vivado 会修剪
    //   它们的驱动逻辑, 修剪会连带核内逻辑 ⇒ 本轮实测两次都死在
    //   这一类上:
    //     ① [DRC MDRV-1] 把它们全接到同一根线 ⇒ 那根线 ~12 个驱动源 (已修)
    //     ② [Opt 31-67] 各自接独立线但**无负载** ⇒ 核内
    //        `i_TX_ENCODER/is_valid_ctrl[3]_i_3` 的 I0 悬空 (本次修)
    //   修法 = 把它们 XOR 折叠成 1 位, 送进快照的**空余位 W39[30]**
    //   ⇒ 真实负载 + 顺便多一个可读的健康签名。
    //   (同手法先例: P7B_MAC_TIMING.md 的 `mtx_sig_hold`/`mrx_sig_hold` 签名寄存器。)
    //----------------------------------------------------------------------
    wire pcs_ch0_sig = ^{pcs_ch0_u_ferr, pcs_ch0_u_ferrv, pcs_ch0_u_rlf, pcs_ch0_u_blk,
                        pcs_ch0_u_vcc,  pcs_ch0_u_status, pcs_ch0_u_ber, pcs_ch0_u_bad,
                        pcs_ch0_u_badv, pcs_ch0_u_errv,   pcs_ch0_u_fifo, pcs_ch0_u_tlf,
                        pcs_ch0_u_err,
                        pcs_user_rx_reset_0, pcs_user_tx_reset_0, pcs_gtpowergood_0,
                        pcs_rx_reset_0, pcs_tx_reset_0};
    // ⚠️ `gt_refclk_out` / `rxrecclkout_0` **故意不进签名**: 它们只能驱动时钟资源,
    //   把它们接进组合逻辑会让 route_design 失败 (闸 1 侦察期实测过的事实)。

    // ---- PCS 状态位: 每位一个 2FF 进 dp 域 ----------------------------------
    (* ASYNC_REG = "TRUE" *) reg [2:0] pcs_blk_sr, pcs_st_sr, pcs_ber_sr, pcs_rlf_sr, pcs_tlf_sr;
    (* ASYNC_REG = "TRUE" *) reg [2:0] pcs_ferr_sr, pcs_ferrv_sr, pcs_bad_sr, pcs_badv_sr;
    (* ASYNC_REG = "TRUE" *) reg [2:0] pcs_fifo_sr, pcs_vcc_sr, pcs_erv_sr, pcs_gpw_sr;
    (* ASYNC_REG = "TRUE" *) reg [2:0] pcs_rtxrst_sr, pcs_ttxrst_sr;
    (* ASYNC_REG = "TRUE" *) reg [2:0] pcs_rerr_sr [7:0];
    integer pcs_i;
    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            pcs_blk_sr <= 3'd0; pcs_st_sr <= 3'd0; pcs_ber_sr <= 3'd0;
            pcs_rlf_sr <= 3'd0; pcs_tlf_sr <= 3'd0; pcs_ferr_sr <= 3'd0;
            pcs_ferrv_sr <= 3'd0; pcs_bad_sr <= 3'd0; pcs_badv_sr <= 3'd0;
            pcs_fifo_sr <= 3'd0; pcs_vcc_sr <= 3'd0; pcs_erv_sr <= 3'd0;
            pcs_gpw_sr <= 3'd0; pcs_rtxrst_sr <= 3'd0; pcs_ttxrst_sr <= 3'd0;
            for (pcs_i = 0; pcs_i < 8; pcs_i = pcs_i + 1) pcs_rerr_sr[pcs_i] <= 3'd0;
        end else begin
            pcs_blk_sr    <= {pcs_blk_sr[1:0],    pcs_blk_lock};
            pcs_st_sr     <= {pcs_st_sr[1:0],     pcs_rx_status};
            pcs_ber_sr    <= {pcs_ber_sr[1:0],    pcs_hi_ber};
            pcs_rlf_sr    <= {pcs_rlf_sr[1:0],    pcs_rx_localfault};
            pcs_tlf_sr    <= {pcs_tlf_sr[1:0],    pcs_tx_localfault};
            pcs_ferr_sr   <= {pcs_ferr_sr[1:0],   pcs_framing_err};
            pcs_ferrv_sr  <= {pcs_ferrv_sr[1:0],  pcs_framing_err_v};
            pcs_bad_sr    <= {pcs_bad_sr[1:0],    pcs_bad_code};
            pcs_badv_sr   <= {pcs_badv_sr[1:0],   pcs_bad_code_v};
            pcs_fifo_sr   <= {pcs_fifo_sr[1:0],   pcs_fifo_error};
            pcs_vcc_sr    <= {pcs_vcc_sr[1:0],    pcs_valid_ctrl_code};
            pcs_erv_sr    <= {pcs_erv_sr[1:0],    pcs_rx_error_v};
            pcs_gpw_sr    <= {pcs_gpw_sr[1:0],    pcs_gtpowergood_1};
            pcs_rtxrst_sr <= {pcs_rtxrst_sr[1:0], pcs_user_rx_reset_1};
            pcs_ttxrst_sr <= {pcs_ttxrst_sr[1:0], pcs_user_tx_reset_1};
            for (pcs_i = 0; pcs_i < 8; pcs_i = pcs_i + 1)
                pcs_rerr_sr[pcs_i] <= {pcs_rerr_sr[pcs_i][1:0], pcs_rx_error[pcs_i]};
        end
    end

    // ---- PCS 事件计数 (dp 域, 8 位饱和) -------------------------------------
    //   ⚠️ 口径写清: ferr/bad/erv 数的是 "同步后为高的 dp 拍数" —— **不是** PCS 的事件数
    //   (PCS 的 `_valid` 是 1 个 dclk 拍宽的脉冲, 2FF 后可能被展宽/合并)。
    //   ⇒ 用途是"这条线有没有动过"; ★ **不得当精确事件数引用**。
    reg [7:0] pcs_ferr_evt, pcs_bad_evt, pcs_erv_evt, pcs_vcc_cyc;
    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            pcs_ferr_evt <= 8'd0; pcs_bad_evt <= 8'd0;
            pcs_erv_evt  <= 8'd0; pcs_vcc_cyc <= 8'd0;
        end else begin
            if (pcs_ferr_sr[2] && (pcs_ferr_evt != 8'hFF)) pcs_ferr_evt <= pcs_ferr_evt + 8'd1;
            if (pcs_bad_sr[2]  && (pcs_bad_evt  != 8'hFF)) pcs_bad_evt  <= pcs_bad_evt  + 8'd1;
            if (pcs_erv_sr[2]  && (pcs_erv_evt  != 8'hFF)) pcs_erv_evt  <= pcs_erv_evt  + 8'd1;
            if (pcs_vcc_sr[2]  && (pcs_vcc_cyc  != 8'hFF)) pcs_vcc_cyc  <= pcs_vcc_cyc  + 8'd1;
        end
    end

    // ---- tx_mii_clk 活性锚点 (W50) -----------------------------------------
    //   "PCS 的 TX 时钟真的在跑吗"必须有**独立于 MAC 计数**的正证据:
    //   tx 域一个 1 位 toggle 跨到 dp, 数沿 ⇒ 频率 = 沿数/2。⚠️ 量化 ±1 沿。
    reg        tx_tgl_tx;
    always @(posedge tx_fe_clk or negedge reset_n) begin
        if (!reset_n) tx_tgl_tx <= 1'b0;
        else          tx_tgl_tx <= ~tx_tgl_tx;
    end
    (* ASYNC_REG = "TRUE" *) reg [2:0] tx_tgl_sr;
    reg [31:0] tx_clk_act;
    always @(posedge dp_clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin tx_tgl_sr <= 3'd0; tx_clk_act <= 32'd0; end
        else begin
            tx_tgl_sr <= {tx_tgl_sr[1:0], tx_tgl_tx};
            if (tx_tgl_sr[2] ^ tx_tgl_sr[1]) tx_clk_act <= tx_clk_act + 32'd1;
        end
    end

    // W39 = PCS 状态束 (31 位有效): 位域**写死在这里**, 判读照此拆。
    //   [31] 0 | [30] **ch0 健康签名** (XOR 折叠全部 ch0 未用输出; 它同时是
    //        "ch0 的输出有真实负载" 的结构保证 —— 见上面的 MDRV-1/Opt 31-67 记录)
    //      | [29] gtpowergood | [28] user_rx_reset | [27] user_tx_reset | [26:22] 0
    //   [21] rx_error_valid | [20:13] rx_error[7:0] (bit7=lane7) | [12] valid_ctrl_code
    //   [11] fifo_error | [10] bad_code_valid | [9] bad_code | [8] framing_err_valid
    //   [7] framing_err | [6] tx_local_fault | [5] rx_local_fault | [4] hi_ber
    //   [3] rx_status | [2] block_lock | [1:0] 0
    assign pcs_status_bundle = {1'b0, pcs_ch0_sig,
        pcs_gpw_sr[2], pcs_rtxrst_sr[2], pcs_ttxrst_sr[2], 5'd0,
        pcs_erv_sr[2],
        pcs_rerr_sr[7][2], pcs_rerr_sr[6][2], pcs_rerr_sr[5][2], pcs_rerr_sr[4][2],
        pcs_rerr_sr[3][2], pcs_rerr_sr[2][2], pcs_rerr_sr[1][2], pcs_rerr_sr[0][2],
        pcs_vcc_sr[2], pcs_fifo_sr[2], pcs_badv_sr[2], pcs_bad_sr[2],
        pcs_ferrv_sr[2], pcs_ferr_sr[2], pcs_tlf_sr[2], pcs_rlf_sr[2],
        pcs_ber_sr[2], pcs_st_sr[2], pcs_blk_sr[2], 2'd0};
    assign pcs_evt_bundle = {pcs_ferr_evt, pcs_bad_evt, pcs_erv_evt, pcs_vcc_cyc};
`else
    // 非 P7B 构建: 这些源**不存在** ⇒ 常量占位 (装配出来恒 0, 是预期的, 不是缺陷)。
    //   ⚠️ 常量满足 snap_cdc 的前提 ("din_b 只在 clk_b 沿变化")。
    wire [31:0]  pcs_status_bundle = 32'd0;
    wire [31:0]  pcs_evt_bundle    = 32'd0;
    wire [31:0]  tx_clk_act        = 32'd0;
`endif

    // ---- P7b: 三束 (全部在 axi 域装配) ---------------------------------------
    //   ⚠️ `dout_a` 拆成逐槽的命名线是为了让装配段可逐项写清槽号 (避免"数拼接"的错)。
    // ⚠️ 用**打包向量**而不是 wire 的非打包数组: 后者连到
    //    端口的拼接上在 xsim 里**读回 z** (本门实测: seen 全 1 而
    //    dout 全 z) —— 这种错只有逐字读回的门能抓。
    wire [95:0]  p7bfe_dout;    // [2:0] → 槽 0/1/2
    wire [383:0] p7bdp_dout;    // [11:0] → 槽 0..11
    wire [127:0] txsnap_dout;   // [3:0]  → 槽 0..3
    wire        p7bfe_valid, p7bdp_valid, txsnap_valid;
    wire        p7bfe_busy,  p7bdp_busy,  txsnap_busy;

`ifdef P7B_10G
    wire [95:0]  p7bfe_din = {rxcdc_ovf_cnt,          // 槽 2 → W38 (wr 域 = FE)
                              mrx_stat_rx_pay_bytes,  // 槽 1 → W37
                              mrx_stat_rx_words};     // 槽 0 → W36
    wire [127:0] txsnap_din = {mtx_stat_tx_ctrl_char, // 槽 3 → W44
                               mtx_stat_tx_words,     // 槽 2 → W43
                               mtx_stat_flush_done,   // 槽 1 → W42
                               mtx_stat_flush_words}; // 槽 0 → W41
`else
    wire [95:0]  p7bfe_din  = 96'd0;
    wire [127:0] txsnap_din = 128'd0;
`endif

    // p7bdp 的 12 个槽: 槽 0/1/6..11 是本模块的信号, 槽 2..5 由 **tx 束**搬来
    //   (W41..W44 在 tx_mii_clk 域, 不能在这里引用) ⇒ 这里只驱动自己的那些槽,
    //   装配时 (snap_dout_all) 才把 tx 束的 4 个字插到 W41..W44 的位置。
    wire [383:0] p7bdp_din;
    genvar gi;
    generate
        for (gi = 0; gi < 12; gi = gi + 1) begin : g_p7bdp
            assign p7bdp_din[gi*32 +: 32] =
                (gi == 0)  ? pcs_status_bundle :        // W39
                (gi == 1)  ? pcs_evt_bundle    :        // W40
                (gi == 6)  ? txcdc_ovf_cnt     :        // W45 (wr 域 = DP)
                (gi == 7)  ? cls_dbg_stat_ovf  :        // W46
                (gi == 8)  ? cls_dbg_stat_route_ovf :   // W47
                (gi == 9)  ? cls_dbg_stat_stall_in  :   // W48
                (gi == 10) ? {27'd0, cls_dbg_occ}   :   // W49 (5 位)
                (gi == 11) ? tx_clk_act        :        // W50
                            32'd0;                      // 槽 2..5: 由 tx 束装配
        end
    endgenerate

    snap_cdc #(.W(32), .NW(SNAP_P7BFE_NW)) u_snap_p7bfe (
        .clk_a(pcie_axi_aclk), .rst_n(pcie_axi_aresetn), .req_a(snap_req),
        .busy_a(p7bfe_busy),
        .dout_a(p7bfe_dout),
        .valid_a(p7bfe_valid), .clk_b(gmii_clk), .din_b(p7bfe_din)
    );
    snap_cdc #(.W(32), .NW(SNAP_P7BDP_NW)) u_snap_p7bdp (
        .clk_a(pcie_axi_aclk), .rst_n(pcie_axi_aresetn), .req_a(snap_req),
        .busy_a(p7bdp_busy),
        .dout_a(p7bdp_dout),
        .valid_a(p7bdp_valid), .clk_b(dp_clk), .din_b(p7bdp_din)
    );
    snap_cdc #(.W(32), .NW(SNAP_TX_NW)) u_snap_tx (
        .clk_a(pcie_axi_aclk), .rst_n(pcie_axi_aresetn), .req_a(snap_req),
        .busy_a(txsnap_busy),
        .dout_a(txsnap_dout),
        .valid_a(txsnap_valid), .clk_b(tx_fe_clk), .din_b(txsnap_din)
    );

    // ---- 三条新束的 `seen` 锁存 + 完成门 ------------------------------------
    //   `snap_valid_all` 才是给 axi_regs 的 "可以采了": 它要求 **snap_seq 的两束 +
    //   三条新束**在本代**都到齐 (任一条早到不构成完成 —— 那是"读到半代快照")。
    //   清位 = 下一次 `snap_req` (同一代的分界)。
    reg p7bfe_seen, p7bdp_seen, tx_seen;
    always @(posedge pcie_axi_aclk or negedge pcie_axi_aresetn) begin
        if (!pcie_axi_aresetn) begin
            p7bfe_seen <= 1'b0; p7bdp_seen <= 1'b0; tx_seen <= 1'b0;
        end else begin
            if (snap_req)      begin p7bfe_seen <= 1'b0; p7bdp_seen <= 1'b0; tx_seen <= 1'b0; end
            else begin
                if (p7bfe_valid) p7bfe_seen <= 1'b1;
                if (p7bdp_valid) p7bdp_seen <= 1'b1;
                if (txsnap_valid) tx_seen   <= 1'b1;
            end
        end
    end
    wire snap_valid_all = snap_valid & p7bfe_seen & p7bdp_seen & tx_seen;
    // 合体 busy: 任一束在飞就是 busy (主机的 "trigger→poll done"协议靠它)
    assign snap_busy = snap_seq_busy | p7bfe_busy | p7bdp_busy | txsnap_busy;

    // ---- 51 字装配 (**逐项写出**: 每项的槽号在注释里, 不依赖"从右往左"的记忆) ----
    //   ⚠️ 这条总线是 axi 域的组合量, 源全是 snap_cdc 的 `dout_a` 寄存器 ⇒ 采集沿稳定。
    //   ⚠️ 非 P7B 构建里三条新束的 din 全是常量 ⇒ 后 15 个字读回恒 0 (预期, 不是缺陷)。
    wire [SNAP_NW_P6E*32-1:0] snap_dout_all = {
        p7bdp_dout[11*32 +: 32],   // W50 tx_mii_clk 活性 (toggle 沿计数)
        p7bdp_dout[10*32 +: 32],   // W49 rx_classify 字 FIFO 当前占用
        p7bdp_dout[9*32 +: 32],    // W48 rx_classify 输入停等拍数
        p7bdp_dout[8*32 +: 32],    // W47 rx_classify 路由队列拒写 (恒 0)
        p7bdp_dout[7*32 +: 32],    // W46 rx_classify 字 FIFO 拒写   (恒 0)
        p7bdp_dout[6*32 +: 32],    // W45 u_txcdc 拒写 (wr 域 = DP)
        txsnap_dout[3*32 +: 32],   // W44 mac_tx_10g.stat_tx_ctrl_char
        txsnap_dout[2*32 +: 32],   // W43 mac_tx_10g.stat_tx_words
        txsnap_dout[1*32 +: 32],   // W42 mac_tx_10g.stat_flush_done
        txsnap_dout[0*32 +: 32],   // W41 mac_tx_10g.stat_flush_words
        p7bdp_dout[1*32 +: 32],    // W40 PCS 事件束
        p7bdp_dout[0*32 +: 32],    // W39 PCS 状态束
        p7bfe_dout[2*32 +: 32],    // W38 u_rxcdc 拒写 (wr 域 = FE)
        p7bfe_dout[1*32 +: 32],    // W37 mac_rx_10g Σpopc(tkeep) 已交付
        p7bfe_dout[0*32 +: 32],    // W36 mac_rx_10g XGMII 字数 (速率正证据)
        snap_dout};       // W35..W0 (snap_seq 装配, 原样)


    // ⚠️ **两束的拼接顺序 = 快照字编号的反向** (拼接从右往左读): 最后写的那一项落在
    //    **向量 MSB 端 = 束内最高槽号**。所以 fe[9]=W26, fe[8]=W27 (而 W26 是先写的) —— 这正是
    //    "手抄下标最容易错"的地方, 也正是全链门必须逐字读回 32 个字的原因
    //    (错一处只会读出"另一个字的正确值", 单测一遍看不出来)。
    // ⚠️ 每一项**必须恰好 32 位**: 少写零扩展 = 位宽截断 (本工程踩过两次)。
    // ---- P7b: FE 束 14 → 17 (新项落在 fe[16:14], 即**向量 MSB 端的最前面**) ----------
    //   全部在 FE = gmii_clk = PCS 恢复钟 (rx_core_clk) 域内 ⇒ 无新增 CDC。
    assign fe_src = {rx_stat_fifo_ovf,        // W35 → fe[13] fifo_sync 拒写次数 (恒 0)
                     rx_stat_drop_full,       // W34 → fe[12] FIFO 空间不足丢帧
                     rx_stat_orphan_bytes,    // W33 → fe[11] 孤儿字节 (C10 必需)
                     rx_stat_drop_partial,    // W32 → fe[10] 已推过字的丢帧 (C10 必需)
                     rxcdc_full_cycles,       // W26 → fe[9]  RX FIFO 满拍数 (FE)
                     {16'd0, rxcdc_occ_max},  // W27 → fe[8]  RX FIFO 占用峰值(字)
                     mac_tx_frames,           // W20 → fe[7]  **MAC 级**发帧
                     tx_stat_abort,           // W21 → fe[6]  MAC 帧内中止 (语义升级见 §3.4)
                     gmii_free,               // W5  → fe[5]  gmii 时钟自由计数 (活性锚点)
                     rx_stat_drop,            // W4  → fe[4]  MAC 丢弃
                     rx_stat_crc_err,         // W3  → fe[3]  FCS 错
                     {16'd0, wl_last},        // W2  → fe[2]  线上帧长判别器
                     rx_stat_bytes,           // W1  → fe[1]  MAC 收字节
                     rx_stat_frames};         // W0  → fe[0]  MAC 收帧
    // ---- P7b: DP 束 22 → 34 (新项落在 dp[33:22], 即**向量 MSB 端的最前面**) --------
    assign dp_src = {rxcdc_out_bytes,         // W31 → dp[21] RX FIFO 读侧 Σpopc(tkeep)
                     rxcdc_out_frames,        // W30 → dp[20] RX FIFO 读侧 TLAST 数
                     txwire_stall_cycles,     // W29 → dp[19] DP 在等线
                     {16'd0, txcdc_occ_max},  // W28 → dp[18] TX FIFO 占用峰值(字)
                     {31'd0, mmcm_locked_sr_dp[1]}, // W25 → dp[17] MMCM locked (DP 同步版)
                     dp_free,                 // W24 → dp[16] 数据面域自由计数
                     rx_stat_nonmatch,        // W23 → dp[15] TCP fast path nonmatch
                     rx_stat_pass,            // W22 → dp[14] TCP fast path 接受帧数
                     srx_stat_drop,           // W19 → dp[13] slow_rx_adp 丢帧
                     stx_stat_purge,          // W18 → dp[12] slow_tx_adp 回卷
                     hr_cnt,                  // W17 → dp[11] hls_rst_n 低电平拍数 (÷RST_CNT)
                     srx_hls_bytes,           // W16 → dp[10] HLS 真读走的字节
                     tx_stat_bytes,           // W15 → dp[9]  TCP fast path 发字节
                     tx_stat_frames,          // W14 → dp[8]  TCP fast path 发帧
                     udpapp_mismatch,         // W13 → dp[7]  图案失配 (必须恒 0)
                     udpapp_rx_null,          // W12 → dp[6]  空帧/坏帧
                     udpapp_rx_bytes,         // W11 → dp[5]  图案 app 收字节
                     udpapp_rx_frames,        // W10 → dp[4]  图案 app 收帧
                     udpapp_tx_bytes,         // W9  → dp[3]  图案 app 发字节
                     udpapp_tx_frames,        // W8  → dp[2]  图案 app 发帧
                     stx_stat_frames,         // W7  → dp[1]  HLS 慢路径发出的帧 (ping 回包)
                     srx_stat_commit};        // W6  → dp[0]  提交给 HLS 的慢帧

    // ---- 3. 相干快照 CDC (gmii_clk → axi_aclk) ----
    // ⚠️ NW 必须与下面 snap_src 的项数、axi_regs 的 `.SNAP_NW` 与读侧 `snap_base` 位宽、
    //    以及验收脚本的"未实现地址"**五处同改** (完整清单见本段开头声明区)
    snap_cdc #(.W(32), .NW(SNAP_FE_NW)) u_snap_fe (
        .clk_a      (pcie_axi_aclk),
        .rst_n      (pcie_axi_aresetn),
        .req_a      (req_fe),
        .busy_a     (busy_fe),
        .dout_a     (fe_dout),
        .valid_a    (valid_fe),
        .clk_b      (gmii_clk),
        .din_b      (fe_src)
    );

    snap_cdc #(.W(32), .NW(SNAP_DP_NW)) u_snap_dp (
        .clk_a      (pcie_axi_aclk),
        .rst_n      (pcie_axi_aresetn),
        .req_a      (req_dp),
        .busy_a     (busy_dp),
        .dout_a     (dp_dout),
        .valid_a    (valid_dp),
        .clk_b      (dp_clk),           // ★ P6b: 数据面 156.25MHz
        .din_b      (dp_src)
    );

    // ---- 3b. 链式触发序列器 (axi 域) ----
    // **FE 先 → DP 后** (确定序)。偏斜上界 ≤59.2ns < 96ns = 1G 背靠背帧的最小 IFG ⇒ 两次
    // 锁存之间最多跨过 1 个帧边界 ⇒ 跨域对账可以用**有向**判据 (W6-W0 ∈{0,1},
    // -1 ≤ W0-W30 ≤ 界) 而不是对称容差。论证见 P6B_SPEC §2.5 / rtl/snap_seq.v 头注释。
    // ⚠️ snap_cdc 硬契约① (req 恰好 1 拍) 由 snap_seq 内部寄存器化保证;
    //    契约② (用 valid 而不是"busy 落下"当完成) 也已满足。
    snap_seq #(.FW(SNAP_FE_NW), .DW(SNAP_DP_NW)) u_snap_seq (
        .clk        (pcie_axi_aclk),
        .rst_n      (pcie_axi_aresetn),
        .req        (snap_req),
        .busy       (snap_seq_busy),
        .dout       (snap_dout),
        .valid      (snap_valid),
        .fe_state   (snap_fe_state),    // → SNAP_STATUS[5:3] (卡在哪个域的可判定读数)
        .dbg_state  (),
        .req_fe     (req_fe),   .busy_fe(busy_fe), .valid_fe(valid_fe), .dout_fe(fe_dout),
        .req_dp     (req_dp),   .busy_dp(busy_dp), .valid_dp(valid_dp), .dout_dp(dp_dout)
    );

    // ---- 4. XDMA (配置 = 厂商那份实测跑通的值的复制 + user BAR) ----
    xdma_0 u_pcie_xdma (
        .sys_clk        (pcie_clk),
        .sys_clk_gt     (pcie_clk_gt),
        .sys_rst_n      (reset_n),          // = 板上 PERST# (J9), 直连无反相器
        .pci_exp_txp    (pcie_txp),
        .pci_exp_txn    (pcie_txn),
        .pci_exp_rxp    (pcie_rxp),
        .pci_exp_rxn    (pcie_rxn),
        .user_lnk_up    (pcie_lnk_up),
        .axi_aclk       (pcie_axi_aclk),
        .axi_aresetn    (pcie_axi_aresetn),
        .usr_irq_req    (1'b0),
        .usr_irq_ack    (pcie_irq_ack),
        .msi_enable     (pcie_msi_enable),
        .msi_vector_width(pcie_msi_vec_w),
        // ---- DMA (m_axi) 通道本设计**不用**: 全回"永不应答" (只走寄存器窗口) ----
        .m_axi_awready  (1'b0),
        .m_axi_wready   (1'b0),
        .m_axi_bid      (4'd0),
        .m_axi_bresp    (2'd0),
        .m_axi_bvalid   (1'b0),
        .m_axi_arready  (1'b0),
        .m_axi_rid      (4'd0),
        .m_axi_rdata    (128'd0),
        .m_axi_rresp    (2'd0),
        .m_axi_rlast    (1'b0),
        .m_axi_rvalid   (1'b0),
        .m_axi_bready   (),          // 输出, 不用
        .m_axi_awid     (), .m_axi_awaddr(), .m_axi_awlen(), .m_axi_awsize(),
        .m_axi_awburst  (), .m_axi_awprot(), .m_axi_awvalid(), .m_axi_awlock(),
        .m_axi_awcache  (), .m_axi_wdata(), .m_axi_wstrb(), .m_axi_wlast(),
        .m_axi_wvalid   (), .m_axi_arid(), .m_axi_araddr(), .m_axi_arlen(),
        .m_axi_arsize   (), .m_axi_arburst(), .m_axi_arprot(), .m_axi_arvalid(),
        .m_axi_arlock   (), .m_axi_arcache(), .m_axi_rready(),
        // ---- user BAR (AXI4-Lite master) -> 我们的寄存器块 ----
        .m_axil_awaddr  (pcie_awaddr), .m_axil_awprot (pcie_awprot),
        .m_axil_awvalid (pcie_awvalid), .m_axil_awready(pcie_awready),
        .m_axil_wdata   (pcie_wdata),  .m_axil_wstrb  (pcie_wstrb),
        .m_axil_wvalid  (pcie_wvalid), .m_axil_wready (pcie_wready),
        .m_axil_bvalid  (pcie_bvalid), .m_axil_bresp  (pcie_bresp),
        .m_axil_bready  (pcie_bready),
        .m_axil_araddr  (pcie_araddr), .m_axil_arprot (pcie_arprot),
        .m_axil_arvalid (pcie_arvalid), .m_axil_arready(pcie_arready),
        .m_axil_rdata   (pcie_rdata),  .m_axil_rresp  (pcie_rresp),
        .m_axil_rvalid  (pcie_rvalid), .m_axil_rready (pcie_rready),
        // ---- 配置管理接口: 不实现 (输入 tie 0 / 输出悬空) ----
        .cfg_mgmt_addr      (19'd0),
        .cfg_mgmt_write     (1'b0),
        .cfg_mgmt_write_data(32'd0),
        .cfg_mgmt_byte_enable(4'd0),
        .cfg_mgmt_read      (1'b0),
        .cfg_mgmt_read_data (),
        .cfg_mgmt_read_write_done()
    );

    // ---- 5. 寄存器块 ----
    // HW_STATUS 字段 (低 8 位): [7:5]=msi_vector_width [4]=msi_enable [3]=user_lnk_up [2:0]=0
    // ⚠️ 拼接必须**恰好 32 位** (24+3+1+1+3): 旧版写 26'd0 ⇒ 34 位 ⇒ 高 2 位被静默截掉
    //    (低 32 位不变, 所以功能没错, 但那是"靠截断碰巧对"——不留这种账)
    assign pcie_hw_status = {24'd0, pcie_msi_vec_w, pcie_msi_enable, pcie_lnk_up, 3'd0};

    // --- P7b: SFP 发射门 (TX_DIS) -------------------------------------------
    // TX_DIS 高有效且板上 10k 上拉 ⇒ **悬空 = 发射关闭 = 全黑** (P7B_GATE1 §5.8 /
    //   2026-09-27 三态判别实验)。默认驱动低 = 发射打开;
    //   `pcie_scratch[1:0]` 由主机写 (0x10) ⇒ **不重建位流**就能把被连通道的发射
    //   拉高, 做"链路必掉 / 恢复必起"的决定性负对照 (闸 2 §5 C-1 的同一手法)。
    //   scratch 复位值 = 0 ⇒ 上电即发射打开。
`ifdef P7B_10G
 `ifdef PCIE_OBS
    assign sfp1_tx_dis = pcie_scratch[0];
    assign sfp2_tx_dis = pcie_scratch[1];
 `else
    assign sfp1_tx_dis = 1'b0;
    assign sfp2_tx_dis = 1'b0;
 `endif
`endif

    axi_regs #(
        .MAGIC_V    (32'h50360001),
        .BUILD_ID_V (32'h00000007),     // ⚠️ 每次改动自增 (前置闸读这一项认位流)
                                        //    1 = 最小版 / 2 = 合体版 8 字 / 3 = 合体版 16 字
                                        //    4 = 合体版 24 字 (+ W16-W23 慢路径健康位)
                                        //    5 = P6b 双时钟域 32 字 (W24-W31 跨域锚点)
                                        //    6 = **P6b + F4 修复**: 36 字 (W32-W35 = F4 的 4 个新计数器)
                                        //    7 = **P7b**: 51 字 (W36-W50), 五束
                                        //        (snap_seq 的 FE14+DP22 + p7bfe3 + p7bdp12 + tx4)
        .SNAP_NW    (SNAP_NW_P6E)       // 51 = 14+22 (snap_seq) + 3+12+4 (P7b 三束)
    ) u_pcie_regs (
        .clk            (pcie_axi_aclk),
        .rst_n          (pcie_axi_aresetn),
        .s_axil_awaddr  (pcie_awaddr), .s_axil_awprot (pcie_awprot),
        .s_axil_awvalid (pcie_awvalid),.s_axil_awready(pcie_awready),
        .s_axil_wdata   (pcie_wdata),  .s_axil_wstrb  (pcie_wstrb),
        .s_axil_wvalid  (pcie_wvalid), .s_axil_wready (pcie_wready),
        .s_axil_bresp   (pcie_bresp),  .s_axil_bvalid (pcie_bvalid),
        .s_axil_bready  (pcie_bready),
        .s_axil_araddr  (pcie_araddr), .s_axil_arprot (pcie_arprot),
        .s_axil_arvalid (pcie_arvalid),.s_axil_arready(pcie_arready),
        .s_axil_rdata   (pcie_rdata),  .s_axil_rresp  (pcie_rresp),
        .s_axil_rvalid  (pcie_rvalid), .s_axil_rready (pcie_rready),
        .hw_status      (pcie_hw_status),
        .scratch        (pcie_scratch),
        .wr_count       (pcie_wr_cnt),
        .decode_err     (pcie_decode_err),
        .snap_req       (snap_req),
        // ⚠️ P7b: busy/valid/din 三根都换成**五束**的合体版
        //   (snap_seq 的 FE+DP 两束 + 本轮新加的 p7bfe/p7bdp/tx 三束):
        //   · busy  = 合体 ⇒ 主机不会在任一束还在飞的时候重触发
        //   · valid = `snap_valid_all` ⇒ 五束本代全到齐才采 (否则读到 "**半代**快照")
        //   · din   = `snap_dout_all` (51 字, axi 域装配, 见采集段)
        .snap_busy      (snap_busy),
        .snap_valid     (snap_valid_all),
        .snap_din       (snap_dout_all),
        // P6b: SNAP_STATUS 的两个新字段 (加位不改已有位 ⇒ 既有脚本的取位方式不受影响)
        .fe_state       (snap_fe_state),          // [5:3] = {fe_busy, fe_seen, fe_done}
        .locked_axi     (mmcm_locked_sr_axi[1])   // [6]   = MMCM locked (axi 域同步版)
    );
`endif

`ifdef P7B_10G
`ifdef P7B_LAT
`ifdef APP_MODE
    // =====================================================================
    // P7b-LAT: RX 通路**分段延迟**探针 (P7B_LATENCY 专项)
    //   本体 = _proj_10g/p7b_lat/rtl/p7b_lat_top.v (头注释有完整设计说明)
    // ---------------------------------------------------------------------
    //  ⚠️ 本块**只在 `P7B_LAT 定义时才存在** ⇒ 不带它的构建 (含 P7b 现役构建
    //     build_p7b_ku5p.tcl) 的端口表与网表**逐位不变** (与 APP_MODE / PCIE_OBS
    //     的同一约定)。
    //  ⚠️ 纯观测: 本块**不驱动任何数据面信号**。唯一的输出到核的路径是 DRP 读
    //     (VIO 位 `drp_req` 默认 0 门控) —— 不开就一个字都不发。
    //  ⚠️ 依赖 APP_MODE (`u_udp_split` 只在那个分支里存在) —— 故三层 ifdef。
    //
    //  时间基 = 工程**已有**的两个自由计数器, 不新造:
    //     gmii_free (声明 :3056, FE = gmii_clk = rx_core_clk_1 = CDR 恢复钟)
    //     dp_free   (声明 :3080, DP = dp_clk 156.25MHz)
    //   两个计数器相位不同 ⇒ 靠 p7b_lat_top 的**后台标定乒乓**给出同刻的一对
    //   (cal_fe, cal_dp), 主机侧换算跨域段。见该文件头 §跨域标定。
    //
    //  分段观测点 (逐条带出处, 全部是**被接收**的拍 = tvalid && tready):
    //   (a)  PCS 边界   : XGMII 里出现 /S/ 的那个字 (lane 0..7 任一;
    //                     合同只允许 lane0/lane4, 本探针把"落哪个 lane"也记下来
    //                     以便判是不是异常)
    //                     判式: rx_mii_c_1[l] && rx_mii_d_1[8l +: 8] == 8'hFB
    //   (b)  MAC RX 出  : rxsrc_tvalid && rxsrc_tready && rxsrc_tuser
    //                     (mac_rx_10g 的 SOP 字被 u_rxcdc 接收 ⇒ 进入跨域 FIFO)
    //   (c1) vlan_strip : vs_tvalid && vs_tready && vs_tuser   (DP 域)
    //   (c)  classify   : s_tvalid && s_tready && s_tuser      (DP 域, slow 支)
    //   (cf) classify   : f_tvalid && f_tready && f_tuser      (DP 域, fast 支)
    //   (d)  app 队列   : u_udp_split.uf_commit_word
    //                     (rtl/udp_split.v:491 = "本帧最后一个载荷字写进 UDP
    //                      帧缓冲 **且**提交成功" ⇒ "整帧在 app 队列里备好")
    //   (d2) app 口可见 : app_udp_rx_tvalid && app_udp_rx_sof (旁证; 被消费者
    //                     的 tready 门控 ⇒ 单独列出, 不与 (d) 混报)
    //  帧长            : mac_rx_10g_last_len (= dbg_rx_last_len, 线上长度含 FCS)
    //                     ⚠️ 它是"最近一次交付帧"的长度 ⇒ 取数前后各快照一次,
    //                        两次相同才认 (单帧激励下必然如此)
    // =====================================================================
    // /S/ 检测: 组合, 8 lane 优先编码 (合同只允许 lane0/lane4, 其余 = 异常)
    reg  [3:0] lat_lane_a;
    reg        lat_sop_a;
    integer    lat_li;
    always @* begin
        lat_lane_a = 4'd15;
        lat_sop_a  = 1'b0;
        for (lat_li = 0; lat_li < 8; lat_li = lat_li + 1) begin
            if (!lat_sop_a && rx_mii_c_1[lat_li] && (rx_mii_d_1[8*lat_li +: 8] == 8'hFB)) begin
                lat_sop_a  = 1'b1;
                lat_lane_a = lat_li[3:0];
            end
        end
    end

    wire        lat_fe_evt_a  = lat_sop_a;
    wire        lat_fe_evt_b  = rxsrc_tvalid && rxsrc_tready && rxsrc_tuser;
    wire        lat_dp_evt_vs = vs_tvalid   && vs_tready   && vs_tuser;
    wire        lat_dp_evt_c  = s_tvalid    && s_tready    && s_tuser;
    wire        lat_dp_evt_cf = f_tvalid    && f_tready    && f_tuser;
    wire        lat_dp_evt_d  = u_udp_split.uf_commit_word;
    wire        lat_dp_evt_d2 = app_udp_rx_tvalid && app_udp_rx_sof;
    //   (e) 慢路径应用侧适配器入口 = udp_split 的**透传口** `srx_*` (契约 tready 恒 1)
    //       SOP = 整帧开始交给 slow_rx_adp; TLAST = **整帧交付完成**
    //       (对不可达 app UDP 队列的帧, 这是路径上最后一级"整帧交给应用侧"的点)
    wire        lat_dp_evt_e  = srx_tvalid && srx_tready && srx_tuser;
    wire        lat_dp_evt_e2 = srx_tvalid && srx_tready && srx_tlast;

    p7b_lat_top u_lat (
        // ---- FE 域 (gmii_clk = rx_core_clk_1 = PCS 的 CDR 恢复钟) ----
        .fe_clk      (gmii_clk),
        .fe_rst_n    (rstn_rx_sr[2]),        // 本域 3FF 同步器末级 (与 rx_mac_rst_n 同源)
        .fe_free     (gmii_free),
        .fe_evt_a    (lat_fe_evt_a),
        .fe_evt_b    (lat_fe_evt_b),
        .fe_lane_a   (lat_lane_a),
        .fe_len      (mac_rx_10g_last_len),
        // ---- DP 域 (dp_clk 156.25MHz) ----
        .dp_clk      (dp_clk),
        .dp_rst_n    (dp_rst_n),
        .dp_free     (dp_free),
        .dp_evt_vs   (lat_dp_evt_vs),
        .dp_evt_c    (lat_dp_evt_c),
        .dp_evt_cf   (lat_dp_evt_cf),
        .dp_evt_d    (lat_dp_evt_d),
        .dp_evt_d2   (lat_dp_evt_d2),
        .dp_evt_e    (lat_dp_evt_e),
        .dp_evt_e2   (lat_dp_evt_e2),
        // ---- GT DRP (dclk 域的结果 + dp 域发出的请求) ----
        //   默认构建 (`P7B_LAT_DRP` 未定义): 输入全部钉 0 ⇒ 读出字 W14-W17 恒 0,
        //   而 `drp_req_*` 两个输出悬空 (没有消费者, 会被 opt 自动修剪)。
        //   ⚠️ 悬空的是**本模块的输出** ⇒ 不会造出 driverless net。
`ifdef P7B_LAT_DRP
        .drp0_tgl    (drp0_tgl_r),  .drp0_do (drp0_do_r),
        .drp0_addr   (drp0_addr_r), .drp0_to (drp0_to_r), .drp0_evt (drp0_evt_r),
        .drp1_tgl    (drp1_tgl_r),  .drp1_do (drp1_do_r),
        .drp1_addr   (drp1_addr_r), .drp1_to (drp1_to_r), .drp1_evt (drp1_evt_r),
        .drp_req_addr(lat_drp_req_addr),
        .drp_req_go  (lat_drp_req_go)
`else
        .drp0_tgl(1'b0), .drp0_do(16'd0), .drp0_addr(16'd0),
        .drp0_to(1'b0),  .drp0_evt(16'd0),
        .drp1_tgl(1'b0), .drp1_do(16'd0), .drp1_addr(16'd0),
        .drp1_to(1'b0),  .drp1_evt(16'd0),
        .drp_req_addr(), .drp_req_go()
`endif
    );
`endif  // APP_MODE
`endif  // P7B_LAT
`endif  // P7B_10G

endmodule
