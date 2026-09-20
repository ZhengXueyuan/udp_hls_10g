# udp_hls_10g — 10G-ready 纯硬件 TCP/IP 数据面 (1G 先行)

Kintex-7 XC7K325T 纯硬件 TCP/IP 数据面: 64bit 字流 @125MHz, 当前 1G RGMII 前端
(10G 仅提时钟到 156.25MHz, 流水线不改)。顶层 = `board/wrapper_p4.v`。
施工日志/踩坑/决策详见 `PORT_NOTES.md`; 工程规范与铁律见 `CLAUDE.md`。

## 状态 (2026-09-21)

**P0-P5e 全部完成并提交; P5a/P5b/P5c/P5d/P5e 均通过板级验证。**
**P6 (10G 提速) 经用户裁决停止, 未做** —— 调研结论作为交接记录存档 (见"遗留"; 定性与
6 块工作、K1-K6 前置实验、三个决策点、两个阻断级风险、工期更正都在那里)。

| 里程碑 | 内容 | 状态 |
|---|---|---|
| P0 | MAC RX/TX 64bit 字流 + 接口规范 | ✅ 板级 PASS |
| P1 | UDP echo 全链 bring-up | ✅ 板级 PASS |
| P2 | TCP fast path echo (CAM/TCB 基础) | ✅ 板级 PASS |
| P3 | TCP fast path echo + HLS 慢路径 (ARP/ICMP/DHCP 自发行文) | ✅ 板级 PASS |
| P4a | ARP 免静态 + ping + TCP/UDP echo | ✅ 板级 PASS |
| P4b | HLS 正式握手 (SYN/FIN/RST 分流 + cfg 通道) | ✅ 板级 PASS |
| P4b-7 | **快速重传自愈** (dup-ACK 触发 + RTO 兜底, retx_ram ring) | ✅ 板级 PASS |
| P4c | 窗口 12KB→48KB + retx_ram 64KB/连接 + ACK-early 破案 (w6a 纯 ACK 修复) | ✅ 板级 PASS |
| P4d | 修补包: TCP 主动连接 (客户端) + VLAN fast path + w6 截断支 TB | ✅ sim 全绿 |
| P5a | **app interface 数据面** (app AXIS 收发 + 寄存器控制面 + FIN/RST/close + 演示 app) | ✅ **板级双向 PASS** |
| P5b | 应用 RX 流控闭环 (窗口随缓冲占用收缩 + 慢消费者背压) | ✅ **门全绿 + 板级 PASS** |
| P5c | 关闭语义完善 (FIN 重推死锁 / RST 回卷洪水 / abort fence / 关闭超时) | ✅ **门全绿 + 板级 PASS** |
| P5d | 多连接加固 (信用池分池 / 动态接受裕度 / 并发关闭门 / TX 双门硬化 + 0 载荷 opener / HLS 槽释放) | ✅ **门全绿 + 构建/板级 PASS** |
| P5e | **UDP app 接口** (接收侧分流 shim + 发送侧目标锁存/长度守卫 + UDP 演示 app + learn-on-RX) | ✅ **门全绿 + 构建/板级 PASS** |
| P6 | 10G 提速 (换前端 + 重收敛, 不是"提时钟") | ⬜ **未做 (用户 2026-09-20 裁决停止)** |

- **P5b 一句话结论**: 通告窗口 = `winq - occ` 随 frame_fifo 占用收缩、零窗后由 `wu` ACK
  主动重开;接受界加 `ACC_MARGIN(4096)` 裕度 + 拒收回 ACK ⇒ 慢消费者背压**零丢字节**。
  板级两张 UART 快照闭合 `W + occ ≈ winq`;构建 WNS −3.089 → **+0.271**。
- **P5c 一句话结论**: 修掉 FIN 重推死锁 (G1) 与 `ring_delta` 下溢洪水 (G9),abort 加 TX
  fence + `state=0` 写 + 配额归还,关闭超时**带对端活性判据** (静默 400ms 才 RST)。
  板级: FIN 后持续有数据 **5.2s 不被 RST**;对端静默后 **400ms RST**。
- **P5d 一句话结论**: 多连接可用 —— 窗口不可撤销 ⇒ 分池上限由 app 在**建连前**写寄存器
  `0x0C` (`WIN_POOL/N`,不写 = 旧行为),接受裕度按 ESTAB 数动态缩 `min(4096, 10550/N)`;
  新多连接门 (3 连接并发 + 慢消费者 + 并发 close) **122 checks / 0 FAIL** 且三条负对照
  (不分池 / 裕度 4096 / 裕度 0) 各自 FAIL;TX 启动门补 `rst_req` + ESTAB、帧首改 **0 载荷
  opener** ⇒ 跨会话零载荷泄漏;HLS 槽泄漏 (D6) 修复后**同四元组重连 15-23ms**
  (修复前 ~1.0s);构建 WNS **+0.268** / WHS **+0.035**,单连接 4MB 板级回归 `RX` 逐字节精确。
- **P5e 一句话结论**: UDP app 通路成立 (10G-ready 行情方向先行) —— 接收侧在 `rx_classify` 的
  **slow 支**插 `udp_split` (不改已验收的分类器 ⇒ **TCP 数据面永不经过它**), 用**帧级缓冲**
  消解 `udp_rx` 的"坏 FCS 照交/无 TLAST 半帧"两条弱点, 并对上游**结构性不反压**
  (决定性实验: 慢口一停就经 `mac_rx_64` 的 8 字共享 FIFO 丢帧, 实测 `mac_drop=11`, 受害者
  可以是 fast TCP 帧); 发送侧 `udp_tx_cfg` (learn-on-RX 的 peer 表 + cfg 冻结) → `udp_tx_frame`
  (长度守卫 ≤1500, 防 `mac_tx` 巨帧与 FIFO 死锁) → 两级 arb (**TCP fast > UDP app > HLS**)。
  默认不激活 (两条独立保险) ⇒ 零回归; 门 **49 + 5 条负对照**; 构建 **WNS +0.290 / WHS +0.051 /
  0 失败端点**,**app 侧锥实测进 worst-400 setup (144/400 条, 0.297ns) 且未被综合裁掉**;
  板级: PC 收板侧图案流 `verified=82432 mismatch=0`、帧间隔 478.5µs ≈ 设计 476.3µs、
  20/50/100/200 Mbps 全档通、TCP 4MB + 同四元组重连 5/5、8080(HLS)/8081(app) 分流正确。

## 已完成功能

**fast path (纯 RTL 数据面, 每级 II=1)**:
- 64bit 左对齐字流 MAC (`mac_rx_64`/`mac_tx_64`), FCS 校验/剥离 (CRC 残留 0xDEBB20E3)
- TCP 数据段解析 + CAM 四元组匹配 + 16 连接 TCB (rcv/snd 状态机 + 窗口门控)
- 逐帧判定的 echo 管道 (tcp_rx → tcp_echo → tcp_tx_frame, frame_fifo 8192 字坏帧回卷)
- **快速重传自愈**: 3×dup-ACK 触发回卷重放 + RTO 兜底扫描器 (retx_ram 每连接 64KB ring,
  读延迟 2 拍流水, 窗口门控 in_flight < min(peer_wnd, RING_CAP=0xBFFE), 32 位回绕安全比较)
- **P4c**: 通告窗口 48KB (0xC000, 免 WS); 纯 ACK 帧 seq 窗口内 (含右沿, RFC 零长段) 即
  接受并处理其 ACK/窗口字段 (w6a 修复 — 板级 ACK-early 暴跌根因, 顺带扩大 dup-ACK
  快速重传检测覆盖)

**slow path (HLS 协议栈 IP, ap_ctrl_none @125MHz)**:
- ARP / ICMP echo / IGMP / UDP echo (8080) / TCP SYN-FIN-RST 握手 (服务端被动打开) +
  DHCP DISCOVER / UDP HELLO 周期自发行文
- HLS cfg 通道 (wscale/窗口) → CAM/TCB; 看门狗 (饥饿超时 64 拍复位脉冲) 防 HLS 死锁

## 协议功能全景 (P4c 收官)

| 协议 | 能力 | 路径 |
|---|---|---|
| ARP | 应答 (192.168.100.2)、免静态 ARP 学对端身份 | HLS 慢路径 |
| ICMP | echo 应答 (ping 通) | HLS |
| IGMP | 接收处理 (组播入口) | HLS |
| UDP | **接收+回显** (8080) + **主动发送** (周期 UDP HELLO 广播) | HLS |
| DHCP | DISCOVER 自发行文 (主动 UDP 客户端行为) | HLS |
| TCP | 服务端被动握手 (SYN→SYN+ACK→ESTABLISHED / FIN→FIN+ACK→LAST_ACK / RST) + **数据 echo** | 握手 HLS; 数据 fast path |

- **TCP 角色**: 服务端 (被动打开) + **客户端 (主动 connect, P4d)** — ACTIVE_CONNECT 宏
  上电自动连固定 IP:port (ARP 前置 + T_SYN_SENT 状态 + SYN 限次重传, 与被动监听共存);
  端口 8080; 16 连接 CAM/TCB
- **VLAN**: fast path 单层 802.1Q/1ad 剥离 (P4d: vlan_strip shim — mac_rx 后剥 TPID+TCI
  重对齐, 下游零改动; QinQ 剥一层后自然退化慢路径); 慢路径 HLS 支持多层 802.1Q/1ad;
  TX 恒无 tag (接 trunk 时回包不带 tag — 已知语义)
- **流控**: TX 窗口门控 in_flight < min(peer_wnd, RING_CAP); RX 通告 48KB; seq 窗口语义
  (边界接受 / 窗口内 OOO 丢数据回 dup-ACK / 超窗静默丢 / 零长 ACK 含右沿); 无拥塞控制 (设计决策)
- **重传**: 3×dup-ACK 整窗口回卷重放 + RTO 兜底 (16 连接轮扫, 双丢自愈); 无 SACK/NewReno
  (echo 场景够用)
- **鲁棒性三层防御**: 截断帧闭合 / 半帧中止防御 / 对端风暴免疫 (详见下)
- **应用接口 (P5a)**: `APP_MODE` 构建下, 应用通过 **AXIS 流**发/收 TCP 载荷
  (`app_tx_*` 一帧 = 一个 TCP 段 ≤1460B, `tid`=conn_id; `app_rx_*` 零拷贝直出接收缓冲,
  带 `len` 边带), 通过**寄存器面**拿连接事件 (CONN_UP/DOWN + peer ip/port/mac)、下发
  close(发 FIN)/abort(发 RST)、读每连接状态与计数。默认构建 (宏未定义) 仍为 echo 语义。
  板级实测: app 连上后主动发 1MB 图案 → PC 收逐字节零失配 + close/FIN; PC 发 32KB →
  板侧校验器零失配。详见 `PORT_NOTES.md` 的 P5a 段与 `rtl/app_ctrl.v`/`rtl/app_pattern.v` 头注释。
  窗口闭环与关闭语义见下 (P5b/P5c/P5d)。
- **应用 RX 流控闭环 (P5b)**: 每连接信用配额 `winq` (池 `WIN_POOL=0xC000`,按构造
  `Σwinq + pool == WIN_POOL`) + 单调右沿 `redge`;通告窗口 = `winq - occ`
  (`occ` = 全局 frame_fifo 占用,字粒度向上取整 ⇒ 保守) ⇒ app 消费慢则窗口收、零窗后
  由 **`wu` ACK** 主动重开 (电平请求 + gnt 握手,最低优先不抢 FIN 重推) ⇒ 对端停等可解。
  接受界 = 通告界 + **`ACC_MARGIN`(4096)** (对端按旧窗口合法发出的在飞段不被拒),
  拒收段回 ACK (RFC 793) ⇒ 不再白等 200ms RTO。app 侧慢消费者经 `tb_app_sink` 建门。
- **关闭语义 (P5c)**: FIN 重推不再只有一次机会 (排空拍"确实入队才清 pend" + RTO 装表兜底,
  修 G1 死锁)、`blocked` 期不回卷导致的 `ring_delta` 下溢洪水修复 (G9,修前会重放
  逐字节可验证的旧数据)、abort 后 TX fence (`rst_sent` 进 `start_data` 与 `s_axis_tready`
  同门) + `state=0` 写 (复用 fc 写通道) + 配额归还、**关闭超时 = 连续 400ms 对端无进展**
  (活性判据:该槽 `rcv_nxt` 未推进;合法半关闭的数据流不会被误拆)。
- **多连接加固 (P5d)**:
  · **信用分池**: `WIN_Q_MAX` 由参数改**可写寄存器 `wq_cap_r`** (`app_ctrl` 地址 `0x0C`,
    复位默认 `0xC000` = 旧行为) —— 窗口一旦通告不可撤销 ⇒ 上限必须**建连之前**设小:
    app 写 `WIN_POOL/N` ⇒ `Σwinq <= WIN_POOL` 由构造保证 (逐拍 `Σwinq + pool == WIN_POOL`)。
  · **动态接受裕度 (H-fix)**: `tcp_rx.ACC_MARGIN` 由参数改**端口**,wrapper 查表 + 寄存器
    下发 `min(4096, 10550/N)`、下界钳 `3328` (N = ESTAB 数) —— N 条连接共享同一个 64KB
    `frame_fifo` ⇒ `N*ACC_MARGIN` 必须进物理预算;N≤2 时 = 旧常量 4096 (逐位零回归)。
  · **TX 双门硬化 (D1)**: 启动/接受门补 `rst_req` (abort 请求到 RST 上线之间最长 ~300 拍
    的数据帧窗口) + "该连接必须 ESTAB" (残余 1 拍 F 项 ⇒ 已拆连接的帧 + FIN seq 漂移)。
  · **0 载荷 opener**: 每帧首字 = `{tdata=0, tkeep=0, tlast=0}` 占位字 ⇒ `axis_pipe` 的
    1 拍前瞻把"下一帧首字"跨过 DEL→ADD 时只是"预开一帧",载荷/seq 从新会话起点算
    ⇒ 跨会话**零载荷泄漏** (代价 1 拍/帧)。
  · **HLS 槽释放 (D6)**: bare SYN 落在非空闲槽 = 对端重新发起该四元组 ⇒ 入口处
    `CFG_DEL` 清 fast 侧残留 + 槽归零走既有全新建连路径 (与首建连逐字段同码) ⇒
    同四元组重连不再依赖 RTO 自释放 (~1.0s → 15-23ms)。
- **UDP app 接口 (P5e)**: UDP **无连接** ⇒ 与 TCP app 口完全独立的一套通路 (无握手/ACK/重传/
  窗口/CAM):
  · **RX 侧**: `rx_classify.slow → udp_split →` ①透传口 → `slow_rx_adp` (非 app-UDP 帧**逐字保真**)
    ②帧缓冲 → app UDP RX 口 (`app_rx_*` AXIS + `len/src_ip/src_port/sof` 边带)。**结构性不反压**
    (输入只写预取 FIFO; 装不下丢**整帧**), **坏 FCS 整帧丢** (`stat_drop_crc`), 长度不符的残帧
    用"下一帧 meta"作边界**整帧回卷** (`stat_drop_part`) ⇒ **永不半帧**。⚠️ 已知取舍: 匹配但
    畸形的帧**两条路都不进**。
  · **TX 侧**: app → `udp_tx_cfg` (**learn-on-RX** 的 peer 表: 学的是收到的那个帧的 src mac/ip;
    cfg 冻结到帧头发出后 — 因 `udp_tx_frame` 在**两个时刻**采 cfg) → `udp_tx_frame`
    (**长度守卫 ≤1500**: 防内部 FIFO 死锁与线上巨帧) → `tx_arb`(UDP 压 HLS) → `tx_arb`(TCP 严格优先)。
  · **演示 app** `app_udp_pattern`: UDP 版图案发生器+校验器 (与 `peer.exe --udp-*` 逐字节一致);
    RX 校验 1 字节/拍 II=1 无缝 (天花板 = 1G 线速 = 125 MB/s), TX 限速帧间 `TX_GAP` 拍 (默认 ≈25Mbps)。
  · **默认不激活** (cfg 全哨兵 + peer 表复位为空 ⇒ 零新增帧) ⇒ 板上行为与 P5 逐位一致。
  · 板级: 8080 仍走 HLS `udp_echo`, **8081 = app 分流** (负对照: 往 8080 发不教 peer 表);
    PC 收板侧图案流 `verified=82432 mismatch=0`; 帧间隔 478.5µs ≈ 设计 476.3µs;
    20/50/100/200 Mbps 全档 PASS; TCP 4MB + 重连 5/5 不回归。
  ⚠️ **板级观测缺口**: `udpapp_*` / `app_udp_stat_*` 计数**没有 UART 消费者** (只接 LED 或悬空)
    ⇒ PC→板方向 (app RX 口) 的板侧校验读数与**全部丢帧计数**读不出来 (只有 TB 门覆盖)。

**鲁棒性 (板级实战逼出的三层防御)**:
1. 截断帧闭合 — 线上帧短于 IP 承诺载荷时按真实字节收下转发, 缺口由 PC 重传自愈
2. 半帧中止防御 — 上游无 tlast 帧流中断时合成 ferr 尾拍闭合 echo 半帧 (坏帧回卷),
   杜绝与后续帧合并成巨帧
3. 对端风暴免疫 — PC 网卡驱动重启 (抓包强杀) 引发的 dup-ACK/重传风暴全消化

**板级诊断接口 (长期保留)**:
- UART 9600-8N1 (板载 CH340E — **枚举为 COM9**, 换 USB 口会变; `tools/board_vlan_test.py`
  与 `tools/board_p5b_check.py --port` 用 COM9, `tools/board_diag18_test.py` 里的 COM8 已过时)
  全精度快照: TCB/窗口/FSM/三站词计数/tlast 三计数/
  截断计数 (TRU)/慢路径存活字段 (SC/SD/SF/SP/SV/HR)/线缆帧长 (WL) + 64 拍 TR/RXT 轨迹环
  + FIFO tlast 位图 (TL), boot 自检后每 5s 一行 (见 `board/uart_dbg.v` 头注释)
- LED: boot 自检 3 闪 + 门控/锁存/满标志实时探针

## 综合结果 (Vivado 2025.2, routed — P5e)

| 项 | 值 |
|---|---|
| 时序 | **WNS +0.290 ns**, TNS=0.000 / **WHS +0.051** / THS=0.000, **0 失败端点** (133723 端点, 全部约束达成; **0 DRC error**) |
| Slice LUT | 51,588 / 203,800 (25.31%) — 含诊断脚手架与 P5 app/流控/多连接/UDP app 逻辑 |
| Slice Register | 41,513 / 407,600 (10.18%) |
| Block RAM | **312 / 445 (70.11%)** — retx_ram 16 连接 × 64KB + 各级 frame FIFO + HLS 内部缓存 |
| 布局策略 | Performance_ExtraTimingOpt (官方 build 走 `launch_runs impl_1` 全流程, 含 `phys_opt_design`) |

- **cell 探针 (P5e 新增块)**: `u_udp_split=1927 / u_udp_tx=1890 / u_udp_tx_cfg=336 /
  u_app_udp=1128 / u_tx_udp_arb=8` ⇒ app 侧逻辑**确实在网表里** (没被当无消费者裁掉)。
  层次面积 (`p5e_verify/p5e_util_hier.rpt`): `u_udp_split` **869 LUT** (含 222 LUTRAM) + 1 BRAM /
  `u_app_udp` **460 LUT** / `u_udp_tx_cfg` **122 LUT**; 参照 **`u_hls` = 19953 LUT = 全设计 38.7%**
  (10G 决策点 E 的输入: 慢路径比整个 UDP app 支重一个数量级)。
- **app 侧锥进 setup 最差族**: `report_timing_summary -max_paths 20` 里 **9/20** 条是
  `u_app_udp/pw_keep_reg[5] → u_udp_tx/ip_csum_r_reg[*]` (#3/4/5/8/9/10/11/12/13, 最差 +0.297);
  worst-400 setup 只有两个族 = `u_tcp_tx FSM → u_tcb.rcv_nxt_r` (256 条, 0.290) + app 侧锥 (144 条)。
- **旧族退出**: `u_retx → RAMB` 与 `u_hls/*` 在 worst-400 setup 里 **0 命中**; P5d 记录的
  新风险族 `app_ctrl.c_snd_wnd → app_pattern` 也**完全退出**。
- ⚠️ **hold 余量仍薄** (WHS 仅 **+0.051**): 最差 hold = `u_app_ctrl/c_snd_una_reg[0][15] →
  u_app_status/sn_ua_reg[15]` (诊断状态行的跨模块短路径, 纯布线主导), 其后是
  `retx wa_o_r_reg → mem ADDRARDADDR` (0.056) 与 `mac_tx fifo wptr → RAMB WADR` (0.057) ——
  比 P5d 的 `u_hls/.../mac_tx` CRC 短路径更好 (**+0.051 vs +0.035**)。往这三族加逻辑仍会先失败。
- **注**: T3 期的私有 route 门 (`sim/p5e_udp/route_check.tcl`) 报 +0.123 属**流程差异**
  (手动 opt/place/route、未 `launch_runs` ⇒ strategy 未生效且缺 `phys_opt_design`),
  **不是布局方差**; 官方口径以本表为准。

## 板级结果

- **100MB TCP echo 速率测试全通** (P4b-7): 126.9/127.0 Mbps 发送/回显稳态,
  104,857,600 B 完整收齐, 零冻结零 RST; 期间 563 次重传/dup-ACK 自愈事件被正确消化
- **P4c 板级**: 48KB 窗口用满 (PC 在飞 45-48KB 实锤); 64MB 回归 105.9 Mbps 稳态完整
  收齐; ACK-early 实验 (suppress=0) 板测 28.4Mbps — 根因破案 (纯 ACK 窗口右沿被丢
  → snd_una 停滞 → RTO 风暴) 并修复 (w6a), 最终裁决: TX 帧率翻倍使 PC 网卡线级截断
  与线级丢帧触发率翻倍, RTO 自愈成本吃掉全部收益 → 板级回退 suppress=1, 修复保留
- **冻结三类根因全部破案修复** (详见 PORT_NOTES 会话存档点):
  1. wire counter 新时钟域杀死 HLS 慢路径 (回退 + WL 改 gmii_clk 域)
  2. tcp_rx 截断支静默吞尾 → echo 帧合并 (按真实字节闭合修复)
  3. PC 网卡驱动重启 → 无 tlast 半帧 → echo 半帧不判尾 (fend_trunc 合成尾拍修复)
- **驱动重启风暴免疫验收**: 强杀 npcap 抓包进程复现法 5/5 轮 100MB 全部完整
  (124-157 Mbps; 修复前复现率 ~75%)
- **吞吐实测 (P4d 修正)**: C++ 合成对端 (tools/cpp_peer, 绕过内核栈) 实测
  **1GB @ 891.5 Mbps / 256MB @ 890.4 Mbps** (逐字节零失配, 零 RTO, 双向近 1G 线速) —
  旧记的 "echo 架构 125Mbps 铁律" 已证伪 (那是 Python 内核栈 + 逐包 pcap 的工具链产物);
  实测瓶颈 = 板侧 48KB 通告窗 × RTT (428µs, 板子纯 ACK 仅 0.9% 全靠 echo 捎带)
- **P5b 板级 (窗口闭环成立)**: 两张 UART 快照闭合 `通告窗 W + 占用 OC ≈ winq (49152)` —
  · `RW=1E40` (7744) / `OC=0A1E8` (41448) ⇒ 和 = 49192 (差 +40)
  · `RW=2078` (8312) / `OC=09F60` (40800) ⇒ 和 = 49112 (差 −40)
  差值 = 字粒度取整 + 两个字段的采样时刻差 (与 flow 门的"抖动"同源,**非撤窗**)。
  `WU`/`PX` 只在**连接建立瞬间的配额竞争**时同步 +1 (冷启动单次 4MB 运行 `WU=0` ⇒
  正常数据流零额外帧,符合设计意图)。
- **P5c 板级 (关闭超时活性判据)**: FIN 之后对端**持续有数据 5.2s 不被 RST** (旧判据
  400ms 就 RST,会把对端 4MB 全丢);对端**静默 400ms 后 RST** ✓ —— 合法半关闭不再被误拆,
  无响应连接仍能拆干净 (RST 上线 + `state=0` + 配额归还)。
  · **阴性对照 (对端主动关闭)**: PC `shutdown(SHUT_WR)` ⇒ 走 HLS 慢路径 DEL ⇒ `RS` 不增
    (线上无 RST 帧),超时**不误触发** ✓
  · **配额归还后新连接可用**: 超时拆除后新连接拿到满窗 `WQ=C000` 并收全数据 ✓
    (累计 `RX=10,960,896` 逐字节精确、`MM=0`,工具 `BOARD_P5B OK`)
  · ⚠️ `FI` 口径: 它只是 **fast path** 的 FIN 计数;慢路径 HLS 另发一帧 FIN+ACK
    (`hls/src/layer_tcp.cpp` 的 `T_SYN_RCVD` 收 FIN 分支,seq 用旧值 ⇒ 对端 out-of-window
    丢弃,是该分支的正确行为) ⇒ **"一次 close 恰 1 帧 FIN"在线上不成立**,判据勿按线帧数写。
- **P5d 板级 (同四元组重连 / D6 判别性变体)**: 固定本地源端口连续重连,轮间隔 `--gap 0.6`
  压到 D6 的 RTO 自释放窗口 (~2-5s) **之前** ⇒ **post-D6 建连 15-23ms**,pre-D6 同脚本
  **~1.0s** (轮 2/3 各 1.029/1.012s) —— 两版位流可判别。
  逐帧签名 (pre-D6): `SYN → SYN+ACK(ack=旧 ISN+1, 无 cfg ADD) → PC RST → 1.0s 后 SYN 重传才成功`。
  (**默认 `--gap 4.0` 两版都过** —— 轮周期 ~5.5s 晚于自释放 ⇒ 不可分,判据必须用窄间隔)
  · **4MB 单连接回归** (post-D6): `RX` 逐字节精确、`MM=0` ⇒ 分池/动态裕度/opener 不破单连接。
  · ⚠️ **板级多连接不可行**: `app_pattern` 是单连接演示 app、板级寄存器总线无 CPU ⇒
    分池门槛 (app 建连前写 `0x0C`) 只能在 TB 侧设 ⇒ 板级只验**单连接不回归**。
  · ⚠️ `FI` 口径同 P5b/P5c: `FI`/`RS`/`EC`/`ST` 都不是 D6 的判据 (两版一样) ——
    `RS` 每轮重连 +1 是关闭超时 RST 的正常语义,`DP` (事件丢弃) 会随重连爬升 (每轮 +1)。

## 验证

**TB 门矩阵** (P6 类改动的固定回归门, ~25 min, 见 `sim/p4sim/`):
```bash
cd sim/p4sim
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_burst.bat 200'                    # 门1 无注入基线
TRUNC=100 TRUNCM=8   cmd //c '...run_tb_p4_burst.bat 200'                              # 门2 截断帧
HALFDROP=100 HALFDROPK=990 cmd //c '...run_tb_p4_burst.bat 200'                        # 门3 半帧中止
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_chain.bat'                        # 门4 全链
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_chain_stall.bat'                  # 门5 死锁复现 (P4d-fix)
# 附加: TXDROP=50 (快速重传自愈) / gate-4096 / dupstorm / pause-300k /
#       PCACKOOB=1 (纯 ACK 窗口右沿语义, w6a 修复复现门) / conn1 判据
#       单元 TB: retx_ram (7 组含 latency=2cyc) / frame_fifo (D=8192) / uart_dbg
# 全矩阵一键: bash sim/p4sim/run_matrix_p4dfix.sh (16 门, 逐门日志 matrix_*.log)
```
判据: BURST OK + 载荷逐字节全等 + ECOMAX≤182 (无合并巨帧) + TRUNCS/HALFD 哨兵 +
ACK 位置合法性 (截断段/OOO/补缺口段) + abort/eend=0。P4c 当前全矩阵 13 门绿。

**门5 (PCSTALL, P4d-fix)**: 复现板级 48KB 满窗 + RTO 重放期收到"已收全部数据"
的高水位 ACK。TB: 累计 ACK 到阈值字节后**永久停发 ACK** → 板侧在飞累积 → RTO
回卷 → 重放开始后注入**一个** ack = 高水位的纯 ACK → 之后不再注入。判据
(`gen_stim_p4_chain.py stallcheck`): 注入确在会话期内且注入时 snd_nxt < ack
(原始 bug 条件) + 之后 **snd_una 追上高水位** 且新数据继续发出 (seq >= 高位
的 echo 帧)。**修复前 (ack_ok 用回卷后 snd_nxt) 必 FAIL** (ACK 被拒 → snd_una
永久冻结), 修复后 OK — 两跑拍级同构, 证据 `sim/p4sim/stall_gate_*.log`。
参数: `run_tb_p4_chain_stall.bat [N [BYTES [DELAY]]]` (默认 200 49150 300;
BYTES/DELAY 经 pcstall.memh 同源传入 TB 与 checker)。

**板级测试** (`tools/`):
- `pc_tcp_rate_test.py [MB]` — TCP echo 吞吐 (双线程, 稳态 10-90% 速率)
- `capture_rate_test.ps1 [MB]` — tshark 抓包 + 怪帧/重传统计
- `board_diag18_test.py [秒]` — COM8 UART 快照 + 并行抓包
- `pc_p5b_win_test.py [--bytes 4194304]` — **P5b/P5c app RX 方向板级验收**: PC 全速灌图案
  (板侧校验器消费 ~0.89 字节/拍 ⇒ 必然积压 ⇒ 触发窗口收缩/wu 重开);图案生成**先于 connect**
- `board_p5b_check.py [--port COM9] [--expect-rx N]` — 读板侧 P5B1 状态行并自动判据
  (RX/MM/AD/DL/OC);`WU`/`PX`/`FI`/`RS` 只作诊断,口径见脚本头注释
- `pc_p5d_reconn_test.py [--rounds 5] [--gap 0.6] [--bytes 32768]` — **P5d D6 同四元组重连
  板级验收**: 固定本地源端口连续轮 [connect → 灌 32KB → drain → close],每轮读 P5B1 状态行;
  判据 = 全部轮次建连 + 传输成功 (槽泄漏未修时第 4 轮起 (MAX_TCP_CONN=3) connect 失败/超时)。
  **必须用窄轮间隔** (`--gap 0.6`): 默认 `4.0` 的轮周期 (~5.5s) 晚于 D6 的 RTO 自释放窗口
  ⇒ 修前修后不可分

**构建/烧录** (`board/`) — 两套独立工程, 位流互不覆盖:
```bash
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_build_p4.bat'      # 默认构建 (echo 数据面) → p4_prj
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_program_p4.bat'    # JTAG 烧录 (1MHz)
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_build_p5.bat'      # APP_MODE (app 接口) → p5_prj
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_program_p5.bat'
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_timing_p5.bat'     # 快速时序迭代 (synth+place, 不 route/bitgen)
```
**P5 app 门** (`sim/p5sim/`, 独立目录): `run_tb_p5_app.bat` (1MB 图案逐字节) /
`run_tb_p5_app.bat close` (**P5c 关闭语义门**: 恰一 FIN / FIN 丢失 RTO 重发 / abort→RST+fence /
同时关闭 / 超时 → 5 条判据 + 3 条负向对照) / `run_tb_p5_wrapper.bat`
(**wrapper APP_MODE 全链 — 接线错误只有它能抓**) / `run_tb_p5_status.bat` /
`run_tb_p5_adv.bat <case>` (对抗集 11 例,含 `accmgn` 接受裕度定价) /
`run_tb_p5_fc.bat` (**P5b 定向单元门**: 池/右沿算术边界/4GB 回绕/事件撞车) /
`run_tb_p5_flow.bat` (**P5b 窗口闭环门**: 慢消费者 + 对端灌数据,逐拍占用/右沿/零重传)。
**P5c 定向证伪门**: `run_tb_tcp_close.bat` (`sim/p5close/`, G1 FIN 重推死锁 / G9 回卷洪水;
修复前 FAIL、修复后 PASS)。
**P5d 门**: `run_tb_p5_multi.bat [case]` (`sim/p5d_multi/`, **多连接门**: 3 连接并发大流量 +
可编程慢消费者 + 并发 close;判据 ①-⑨ = 122 checks / 0 FAIL;负对照 `neg_wq`⇒①FAIL /
`neg_mgn`⇒④FAIL / `neg_mgn0`⇒⑥⑦FAIL;`known_idle_fifo` = 长只写后首读**逐字节守卫**
(曾误判为 `frame_fifo` 预存缺陷,已证伪:实为 TB 激励的 0 延迟竞争)) /
`run_tb_p5d_d1.bat` (`sim/p5d_d1/`, **D1 单元门**: abort 请求窗 `rst_req` + 残余 F 项
ESTAB 状态门 + 释放,6 条判据) / `run_tb_p5e_win.bat` (`sim/p5e_win/`, **0 载荷 opener
窄窗门**: pipe 残余字跨会话 ⇒ 逐字节图案零泄漏) / `run_tb_p5c_fence.bat` (`sim/p5c_t3/`,
abort fence 单元门 F1-F5,判据文本未改、激励按真链路补 `rst_req` 释放)。

**P5e 门 (UDP app, 需 `-d APP_MODE`)**:
- `run_tb_udp_split.bat` (`sim/p5udp/`, **T1 分流器单元门**: 分流/结构性不反压 (`tready` 恒 1)/
  透传逐字保真/坏帧与半帧整帧丢弃/缓冲溢出整帧丢; 决定性实验副本在 `sim/p5e_pre/`)。
- `run_tb_udp_tx_guard.bat` (`sim/p5e_t2/`, **T2 守卫单元门**: peer 门 + `PLEN_MAX` 守卫 +
  内置负对照) / `run_tb_p5e_t2_wrapper.bat` (**T2 真 wrapper 全链**, 含 `implicit` 检查)。
- `run_tb_app_udp.bat <case>` (`sim/p5e_udp/`, **T4 UDP 演示 app**: `pos` 正例 EXIT=0;
  负对照 `splitoff`/`portout`/`badcrc`/`nopeer` 各 EXIT=0 且正向判据不成立;
  `neglearn` **期望 exit 1** = 判别力实证) / `run_tb_p5e_udp_wrapper.bat`
  (**T5 真 wrapper 全链**: 真 GMII 注入 + 内部 GMII 解码 + `+NOUDP` 零帧对照 + DRC)。
- 一键: `bash sim/p5e_udp/run_regress.sh` — **49 门**, 唯一非零 = `t4_neglearn` (期望值)。

## 遗留

- **P5e 已收官 (2026-09-21)**: UDP app 接口完成 (见上"已完成功能"与 `PORT_NOTES.md` 的
  P5e-T1/T2 与 P5e-T3/T4/T5 两节)。**未闭合的板级缺口** = app 通路的板侧观测无读数
  (`udpapp_*` 只接 LED、`app_udp_stat_*` 悬空) ⇒ **PC→板方向的板侧校验/丢帧计数不可见**;
  要补只需把这几根计数线接进 `uart_dbg` 状态行 (小工作量, 非阻断)。另: **口径更正** ——
  "app RX 字节串行 15.6 MB/s" 是 **8× 错误** (实为 **125 MB/s = 1G 线速**);
  **~25 Mbps 天花板是 HLS 慢路径的**, 与 app 通路无关。
- **P5d 剩余 (非阻断)**:
  · **`scan_now` 饥饿**: `fin_push`/`rst_push`/RTO 装表只在 FSM `S_IDLE` 拍评估 ⇒ app 饱和
    发送时 close/abort 被推到数据流结束才发 (生产 1MB ≈ 8ms);判据全绿但"应用中途 abort
    的响应延迟"无上界。
  · **ackq 条目不带 seq** (P5c T1 残余): FIN 条目弹出那 1 拍内对端 ACK 到达时仍可能发
    `seq = fin_seq+1` 的 FIN ⇒ 需条目带 seq (接口改动)。
  · **HLS 硬编码 48K 通告窗 (C21) 未改**: 慢路径每个段 (含 SYN-ACK) 仍写死 `0xC000`;
    D4 分池后**零配额连接这一成因消失** (N≤3 每条连接都拿 `WIN_POOL/N > 0`),但 N≥2 时
    SYN-ACK 通告值 (>实际配额) 与 fast path 实际窗口不一致 —— 物理安全由接受窗兜住,
    代价是首轮多发的段被拒/回 ACK。
  · **3 槽耗尽后的新连接仍被静默丢弃**: `tcp_find` 对不匹配四元组在**无空槽**时返回 −1
    ⇒ 属**策略**问题 (D6 修的是"槽未释放",不含"槽不够");已加只读观测计数
    `tcp_stat_no_slot` (`hls/src/layer_tcp.cpp`)。
  · **`ACTIVE_CONNECT=1`** (当前 netlist 的 SourceFlags) 让板子每 ~6.7s 自发占一个 HLS 槽
    ⇒ `MAX_TCP_CONN=3` 的可用包线要扣掉一个。
### P6 (10G 提速) — **未做 (用户 2026-09-20 裁决: P5e 完成后停止)。以下为调研交接记录, 一行 RTL 都没写**

> 存档位置 = `PORT_NOTES.md` 末节 "P6 交接记录"; 将来重启 10G 从那里读, **不要重新调研**。

- **定性 (最重要的一条)**: P6 的技术前提**不是"提时钟"而是"换前端 + 重收敛"** ——
  `mac_rx_64`/`mac_tx_64` 是**字节串行 (1B/拍) 的 GMII 模块** ⇒ 10G 下**必须整体替换**
  (否则 TX 天花板 **1.25 Gbps**)。"流水线不改"对**中间各级**成立, **对 MAC 边界不成立**。
- **要做的 6 块**: A 时钟与前端 (换晶振 + PCS/PMA + shim) / B **MAC 语义 (FCS 改 8B/拍)** /
  C 吞吐复核 (`rx_classify` **skid 改真 FIFO**: 现每帧停 6 拍 ⇒ 64B 帧下吞吐只剩 **57%**;
  VLAN 重构) / D 窗口与缓冲 (**DDR3 大窗**: BRAM 只有 2MB, retx 已占 1MB) /
  E HLS 慢路径 (`u_hls` = **38.7% LUT** ⇒ **单域/双域抉择**) / F 工具链 (校验器 8 路并行 + 10G 对端)。
- **要准备**: 换晶振 (`SiT9120AI-2B3-33E156.25`) + **10G 对端** (现网卡 Killer E5000B 是
  **5G RJ45、无 SFP+**) + SFP+/DAC。⚠️ **一个必须先定案的物理前提**: `PORT_NOTES` 记参考钟
  **X5→Quad115(H5/H6)**, 但 **DEMO `k724` XDC 实测是 D6/quad116/X0Y0/G4** —— 冲突;
  **若晶振真在 quad 115, 换晶振无效**。**买硬件之前先定案**。
- **六个前置实验 K1-K6** (都不需要新硬件, 可现在做): K1 156.25MHz 时序尖峰 / K2 字节序实测 /
  K3 HLS 收敛探针 / K4 **license 核查** / K5 参考钟定案 / K6 BRAM 映射尖峰。
- **三个决策点**: ① 单域 vs 双域 ② **免费 10GBASE-R PCS/PMA (PG068) + 自写 shim** vs
  PG157 (**收费核, eval 版硬件 8 小时停机**) ③ 10G 对端方案 (PCIe NIC+DPDK /
  **同板双 SFP+ 自环对打** / 商用测试仪 / 仅物理层自环)。
- **两个阻断级风险**: ① **156.25MHz 时序** (worst-400 slack 全在 **0.290–0.297ns**、**85% 是
  布线**、扇出 `fo=498` ⇒ 每条要砍 **≥1.6ns**, 属结构性改动) ② **TCP 吞吐 = 窗口 × RTT**
  (48KB × 428µs ⇒ **~890Mbps 就是天花板** ⇒ **不换 DDR3 大窗, TCP 方向测出来还是 ~1G**;
  **UDP 行情方向无此问题**)。
- **建议阶段 P6-0→P6f + 工期 33–66 天**; ⚠️ `../udp_hls_eco/design_review/04` 的 **"8–15 人天"
  只覆盖前端替换那一段**, 不能拿来排期。
- **六条更正** (别照抄旧记载): ① **C1b 的 `Δ=32×88×8=22528` 是单位混乘** —— Δ 实为按
  字节比不变量 **≈2.7KB**, 加扫描周期项 2KB 合计 ~4.7KB **< 16KB 余量 ⇒ 大概率不溢出**
  (但**门判据要重写**); ② **参考钟归属冲突** (X5/quad115 vs k724 D6/quad116); ③
  `design_review/04` 说慢路径是 `ap_ctrl_hs`, **实际是 `ap_ctrl_none`**; ④ 该文档工期只覆盖前端;
  ⑤ `PORT_NOTES` 旧记的 "**3 字 skid**" 已过时 (**代码是 6 字**); ⑥ **P5e 提交后基线冻结**
  (本节数字锚在 P5e 提交: WNS +0.290 / LUT 51588 / BRAM 312)。
- **P5b/P5c/P5d/P5e 已知代价**: 接受窗 (`ACC_MARGIN` = `min(4096, 10550/N)`) 的多连接 + 大流量
  组合已由 `p5d_multi` 门覆盖 (3 连接),但**板级只验单连接** (`app_pattern` 单连接 + 无 CPU)。
  构建 **hold 余量 +0.051ns 仍薄** (P5e 最差 hold = `u_app_ctrl/c_snd_una_reg →
  u_app_status/sn_ua_reg` 诊断状态行的跨模块短路径; 其后 `retx wa_o_r → mem ADDRARDADDR`
  0.056 / `mac_tx fifo wptr → RAMB WADR` 0.057) ⇒ 往这三族加逻辑会先在这里失败;
  **setup 侧当前最差族 = `u_tcp_tx FSM → u_tcb.rcv_nxt_r` (0.290) 与
  `u_app_udp/pw_keep_reg[5] → u_udp_tx/ip_csum_r_reg[*]` (0.297, P5e 新增)** ——
  P5d 记录的 `app_ctrl.c_snd_wnd → app_pattern` 与 `retx → RAMB` 已**退出最差 400**。
- 板侧既有病理 (P4 起就有, 非 P5 引入): 偶发突发丢帧 + TX 静默 ~200ms
  (因果链推断 = 乱序 dup-ACK 请求 → `ackq` 8 深溢出 → 对端只能等 200ms RTO);
  P5b 对症 = ackq 加深 (8→32) + `stat_ack/drop` 接进 UART 快照 + 窗口闭环
- SACK、拥塞控制未实现 (echo 场景决策); TCP 主动连接/VLAN fast path 已补 (P4d),
  板级实测待做 (主动连接默认宏关, VLAN 无真实带 tag 对端)
- 10G 风险预记: VLAN 剥离的 tag 字气泡 + 尾拍停靠 (1G 由 mac 8 深 FIFO + IFG 吸收)
  在 10G 线速会吃掉 IFG 的 2/3 — P6 需复核 (与 rx_classify 已知 min-frame 丢帧叠加)
- **测试工具余量 (P6 前哨)**: C++ 合成对端的 flush 路径上限 ~191k 帧/s (≈1.1 Gbps 载荷),
  实测峰值 147.9k fps = 上限 78% (双向双帧/段需 155k fps)。**1G 够用但只剩 ~20% 余量,
  10G 必须换工具** (`pcap_sendqueue_transmit(sync=1)` + 逐帧 `pcap_next_ex` 的结构撑不住)
- PC 侧网卡 (Killer E5000B) 驱动重启的怪帧/半帧由 RTL 三层防御兜底, 对端根因未深究;
  PC 网卡线级截断/线级丢帧是 1G 线速不可达的最终瓶颈 (FPGA 侧可做项已尽)
- wrapper_tcp.v (P3 目标) 端口过时 (仅历史参考; 新接口已接线但 tb 无覆盖)
- 诊断脚手架 (UART/trace/LED) 保留为长期板级诊断接口
