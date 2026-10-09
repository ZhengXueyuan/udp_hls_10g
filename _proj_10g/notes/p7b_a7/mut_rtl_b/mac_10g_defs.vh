// ===========================================================================
// mac_10g_defs.vh —— 64 位 XGMII MAC 的常量表 (每条带出处)
// ===========================================================================
// 出处缩写:
//   [S1] = IEEE Std 802.3-2008 Section 4 (Clause 44..55)。逐条转录见
//          _proj_10g/notes/P7B_BASER_TABLES.md §1/§2/§3/§4
//   [EX] = 官方明文 example: _proj_10g/xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_pkt_gen_mon.v
//          (AMD 生成/提供的例程; 本设计只**照它的约定**实现, 未抄其代码)
//   [IP] = 本仓已被板级验证的 1G 实现 rtl/mac_rx_64.v / rtl/mac_tx_64.v
// 纪律: 凡标【未核实】/【推论】的一律不写进这里 (见 P7B_MAC_DESIGN.md §9)
// ===========================================================================

// ---- 1. XGMII 控制码 (TXC=1 时 TXD 的取值) — [S1] Table 46-3 + Table 49-1 ----
localparam [7:0] XGMII_I = 8'h07;   // /I/ idle       (帧间填充)
localparam [7:0] XGMII_Q = 8'h9C;   // /Q/ sequence   (仅 lane0 合法; 链路故障信令)
localparam [7:0] XGMII_S = 8'hFB;   // /S/ start      (仅 lane0/lane4 合法, 见下)
localparam [7:0] XGMII_T = 8'hFD;   // /T/ terminate
localparam [7:0] XGMII_E = 8'hFE;   // /E/ error
// 其余取值 (0x00-0x06/0x08-0x9B/0x9D-0xFA/0xFC/0xFF 及 reserved 0x1C/0x3C/0x7C/0xBC/0xDC/0xF7/0x5C)
// 在 XGMII 上**正常无错时不应出现** ⇒ 收到即按保留控制码计 (stat_rx_bad / terr)

// ---- 2. 帧起始: /S/ + 0x55*6 + SFD(0xD5) 一拍 (64 位 XGMII) ----
//  [S1] 46.2.2: "The first preamble octet is replaced with a Start control character and it is
//  aligned to lane 0 ... the SFD assigned to lane 3" —— 标准写的是 32 位 XGMII;
//  64 位视图 (2 次 32 位传输 = 1 个 64 位字) 见 P7B_BASER_TABLES.md §2.2【推论】
//  ⭐ [EX]:995  localparam [63:0] preamble = 64'hFB_55_55_55_55_55_55_D5 ;   ← 官方字面量
//      [EX]:1148 tx_mii_d <= swapn(tx_datain);   [EX]:1240 swapn[i+:8] = d[(63-i)-:8]
//      ⇒ lane0 = 内部字最高字节 = 0xFB = /S/; lane7 = 内部字最低字节 = 0xD5 = SFD
//      [EX]:1147-1149 帧首那一拍 tx_mii_c = 8'h00, 仅 c[0] = 1 (只有 lane0 是控制字符)
//  ⇒ **XGMII 帧首拍 = lane0:/S/(c=1) + lane1..6:0x55(c=0) + lane7:0xD5(c=0)**
//  ⚠️ **不是** 1G 的 55x7+D5 ([IP] rtl/mac_tx_64.v:99): 照搬会少一个 /S/、多一个 0x55
//      ⇒ PCS 永远组不出块类型 0x78 ⇒ 对端静默丢帧
localparam [7:0] ETH_PRE_OCT = 8'h55;   // preamble octet (7 个里第 1 个被 /S/ 顶掉)
localparam [7:0] ETH_SFD     = 8'hD5;   // <sfd>, 串行位序 10101011

// ---- 3. 帧长 / IFG — [S1] Clause 4.4 + 4.3.1.4 ----
//  minFrameSize = 512 bit = 64 octets **含 FCS** ⇒ 内容 (DA..payload) 最小 60
//  maxBasicFrameSize = 1518 octets (不含 tag); Q-tag 帧 1522
localparam [15:0] ETH_MIN_CLEN   = 16'd60;                // 内容下界 (pad 目标); [IP] mac_tx_64.v:58
localparam [15:0] ETH_MAX_FRAME  = 16'd1518;              // 线上帧长上界 (含 FCS)
localparam [15:0] ETH_MAX_QTAG   = 16'd1522;
//  interPacketGap = 96 bit = 12 octets (1G/10G 同值)。
//  [S1] 46.2.1: <inter-frame> "begins with the Terminate control character, continues with Idle
//  control characters and ends with the Idle control character prior to a Start" ⇒ 12 octets 里
//  **含 /T/**, 即 /T/ 之后只需 11 个 /I/。本设计**故意取 12 个 /I/**(保守 1 字节):
//  ① [S1] 49.2.4.7 允许 PCS 删 /I/ 做速率适配(4 个一组, 但 /T/ 后头 4 个不能删) ⇒ 多留 1 个更稳;
//  ② 与 P7B_SPEC.md §4.2.3 / P7B_BASER_TABLES.md §3 的书面建议一致。
//  代价 = 小帧多花 1 拍 (见 P7B_MAC_DESIGN.md §7 吞吐算数)。
localparam [4:0]  ETH_IFG_IDLE   = 5'd12;                 // /T/ 之后至少这么多个 /I/

// ---- 4. FCS — [S1] 3.2.9 多项式 + [IP] 板级验证过的字节序约定 ----
localparam [31:0] ETH_CRC_RESIDUE = 32'hDEBB20E3;         // 帧全字节(含 FCS)流过后的寄存器值
//                                                    [IP] rtl/mac_rx_64.v:96 (权威)
//                                                    0xC704DD7B 是大端/非反射魔数, **勿用**
//  写 FCS 字段: fcs = crc ^ 32'hFFFFFFFF, **低字节先上线** (小端) — [IP] rtl/mac_tx_64.v:170,213

// ---- 5. /T/ 落位 ⇒ 该字的有效数据字节数 ----
//  [EX]:1378/:1561 (监视器) for(i=7;i>=0;i=i-1) if((mii_d[i*8+:8]==8'hFD) && mii_c[i]) byte_count1 = i;
//  ⇒ **/T/ 在 lane t ⇒ 该字 lane 0..t-1 是本帧数据, lane t 起属于帧间(块类型 0x87/0x99/...)**。
//  [EX]:1199 if(full_bits != 0) tx_mii_d[full_bits+:8] <= 8'hFD;  (full_bits = xfer_rmdr*8)
//  ⚠️ [EX] 在"帧长恰为 8 的整数倍"(xfer_rmdr==0) 时把 /T/ 放到**下一拍的 lane0**, 而那一拍
//     剩下 7 个 lane 是 xfer_ctl=8'h00 的**数据** ⇒ 组装出 `T0 D1..D7`。Figure 49-7 [S1]:13529-13610
//     的 16 种格式里**没有**这种 (T 后面只能是 C) ⇒ 本设计**不照搬这个角落**: 我们只产出
//     Figure 49-7 的 8 种 T 型块 (T 之后一律补 /I/)。
