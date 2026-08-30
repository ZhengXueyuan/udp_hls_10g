# udp_hls_10g 施工日志

规则 (继承 udp_hls_eco): **每次实验先追加记录再动手**。

## 2026-08-23 开工 (P0: 数据面骨架, 1G 先行) — ✅ xsim 三模式全 PASS

- **决策 (用户拍板)**: 1G 先行、10G-ready。总计划 `../udp_hls_eco/design_review/04_construction_plan.md`。
  数据面 64bit 字流 @125MHz; 10G 升级 = P6 (换晶振 SIT9120AI-2B3-33E156.25 + PG157 + 提时钟)。
- **字流接口规范确定**: 左对齐 (tdata[63:56]=dst_mac[0]); FCS 校验剥离; 4 字节前瞻延迟线
  (打包落后 CRC 4 字节, 帧尾 FCS 自然不打包); 整字延迟一拍 (保持字 hwreg) 以标记 TLAST;
  背压满则整帧丢弃 (消费者按 TLAST 完整性丢弃半帧)。
- **RTL**: mac_rx_64 / crc32_8b / fifo_sync (FWFT) + xsim TB。11 帧用例:
  arp60 / udp64 / long1514 / vlan / 背靠背×2 / 坏CRC / runt46 / 长前导 / 垃圾前导 / rx_er。
- **验证 ✅**: xsim 三模式 (无背压 / 周期抖动 / 硬停 3000 字节窗) — nostall/stall 逐词全等,
  hard 结构一致 (帧原子丢弃, 半帧=丢帧正常产物); 工具全 Python (anaconda)。
- **工具链**: xvlog/xelab/xsim 不在 PATH, bat 内用全路径 + CRLF 行尾 + 全路径调用;
  xelab 必须全限定库名 `xil_defaultlib.tb_x` (xvlog -work 编译进该库, xelab 默认找 work)。

### P0 破案教训 (全部已修, 详细过程见 git 历史)

1. **CRC 使能必须与数据同拍 (组合)**: crc_en/crc_init 寄存器化会让 CRC 与字节流错位一拍
   (漏首字节 + 帧尾多算一个 IFG 字节 0x07) — 用 crc 值反解字节流 (raw(fb+07)) 定位。
2. **FCS 残留魔数 = 0xDEBB20E3** (线上 FCS = zlib.crc32 值小端, 铁律): 反射 CRC (无终值取反)
   全帧流过后的残留 == raw(0xFFFFFFFF) == 0xDEBB20E3, 帧长无关 (Python 实测)。
   **0xC704DD7B 是 FCS 大端魔数, 勿用**; raw 值小端 FCS 的残留才是 0。
3. **TB 驱动必须时钟化非阻塞**: 阻塞赋值 + @(posedge) 循环与 DUT 竞争 → 诡异现象
   (crc_log 显示 en 跨帧连 2151 字节; 词数 525/304 vs 268 随背压模式漂移)。改
   `always @(posedge clk) rx_d <= stim_d[i]` 后一次性消除。
4. **AXIS 输出握手 = 组合 valid + 组合 rd + FWFT FIFO**: 寄存器化 rd 会让数据在总线挂 2 拍,
   标准消费者 (每拍 valid&&ready 采样) 双采 → 每词重复一遍 (2N-1 模式)。FWFT 旁路写
   (空时 dout<=din) + 组合 rd 才是单拍窗口。
5. **移位量表达式陷阱**: `3'd8` 截断为 0, `wreg << ((3'd8-bcnt)*8)` 移位量异常 → 输出全 0。
   左对齐改用显式 case 拼接 (ljust64/ljust8), 与将来 10G shim 做法一致。
6. **push_* 标志寄存器每拍默认清零**: 否则上一帧的 push_crs=1 粘住, 污染后续所有词。
7. 部分字右累积 + flush 时 case 拼接左对齐 (首字节恒在 [63:56], 解析器免查偏移)。

## 2026-08-23 晚 (P0 续: mac_tx_64 + 板上 wrapper) — ✅ TX xsim 双模式 PASS, 构建中

- **mac_tx_64 完成**: AXIS 字流→GMII (前导 55×7+D5 / FCS = zlib 值小端 / pad 46 / IFG 12 /
  欠载中止 runt)。**关键设计**: gmii_txd/tx_en 用组合 mux (状态机只存状态), 否则寄存器化
  txd 会让 CRC 在 DATA→PAD 转换拍重复计入末字节 (FCS 反解实锤)。
- **crc32_8b 增加 crc_nxt 组合输出**: FCS 装载需要"本拍含末字节"的 CRC 终值, 寄存器值晚一拍。
- **TX xsim 双模式 PASS**: main (60B 无 pad + 42B pad4 + 8B pad38, 逐拍全等, stats 3/0) +
  abort (1 词 + 长空窗 → 欠载中止 runt 16B + 残余词开新帧, stats 1/1)。
- **TX 破案教训**:
  1. **TB 展示词在"接受拍"重赋同词** (tdata <= stim_d[old si]) → FIFO 双采首词 (2N-1 模式
     再现, mem[0]==mem[1] 实锤) → 接受拍撤 valid 一拍再装下一词。
  2. **$readmemh 按十六进制解析** — 生成器写 GAP 10000 十进制被读成 0x10000=65536 拍
     (超仿真时长, w2 永不出现); stim 文件一律写 hex。
  3. Python 模型的 init 检查要在状态切换前快照 (cur_state), 否则 D5 拍 init 失效。
  4. 模型 abort 分支不能覆盖本拍已发出的末字节 (RTL 组合 txd 语义)。
  5. 模型的 TB 必须非阻塞语义 (本拍可见=上拍计算值), 否则 gap 结束点偏移。
  6. 欠载测试的 gap 必须远大于 FIFO 排空时间 (容量博弈下 ±1 拍就变结果)。
- **板上 wrapper (agent 交付, 已核查)**: board/wrapper_1g.v — MMCM 50→200M 闭环 +
  util_gmii_to_rgmii (纯 RTL, 已 diff 验证与原文件一致) + RX 再寄存一拍 (照抄 7/7 PASS
  结构) + mac_rx_64/mac_tx_64 环回直连 + 4 LED 观测; XDC 逐字复用 (PHY1=AB2 demo 引脚组,
  generated clock 依赖 u_rgmii/bufmr_rgmii_rxc 命名); build.tcl create_project -force
  无 IP 步骤 (参考工程 sources_1 无 xci)。
- 板测方案: 烧录 → PC ping 192.168.100.2 造 ARP 广播 → FPGA 环回 → pktmon comp 117
  混杂模式验证原帧+回显两份逐字节一致; LED d0 闪烁/d1 翻转 = PASS (ping 不通属正常)。

## 2026-08-23 深夜 — ✅ 板上环回 bring-up PASS (1G RGMII 全链实锤)

- **构建**: 0 Warnings / 0 Errors, bit = vivado_prj/udp_loop_phy1.runs/impl_1/wrapper_1g.bit。
- **烧录**: JTAG 1MHz, "End of startup status: HIGH" ✓。
- **板测实锤 (pktmon)**: PC ping 192.168.100.2 (8 发 0 收, 预期 — 纯回环不应答) 抓包:
  - `21:58:16.584317500 方向Tx ARP length 42 (who-has 192.168.100.2, len 28)` → PC 原帧
  - `21:58:16.586173600 方向Rx ARP length 60 (who-has 192.168.100.2, len 46)` → **FPGA 回显**
    (1.9µs 后; 长度 42→60 = mac_tx_64 把 28B 净荷 pad 到 46B, 与 xsim 行为精确一致;
    src/dst MAC 与内容逐字节相同; FCS 有效 — 坏 FCS 会被网卡硬件丢弃)。
  - 另有 282B UDP 广播 Tx 后 1.4µs 出现 Rx 副本 (同机制)。
- **教训**: pktmon comp ID 会变 — 本机 Killer E5000B = **comp 102** (历史 117 已失效,
  用错 ID 抓 60 秒全空); 方向字段在事件头行 (`方向 Tx/Rx`), 帧行在其后;
  etl2txt 输出 UTF-16; 用"网卡计数器差值"做对照时注意空闲窗也有背景广播。
- **P0+P1 全部完成**: 10G-ready 64bit 字流 MAC RX/TX 在 1G RGMII 板上全链验证。
  下一步 (P2): 头解析器 (parser) → 分类 → UDP fast path。

## 2026-08-23 P2 开工 (UDP fast path) — 设计决策先行

GitHub 仓库已建: https://github.com/ZhengXueyuan/udp_hls_10g (public, master 已推)。

**字节布局 (无 VLAN, 左对齐字, 帧首=tdata[63:56])**:
- w0 = dst_mac[6] + src_mac[0..1]; w1 = src_mac[2..5] + ethertype + ver/ihl + dscp
- w2 = total_len + id + flags/frag + ttl + proto; w3 = ip_csum + src_ip[4]
- w4 = dst_ip[0..1] + src_port + dst_port + udp_len; w5 = udp_csum + 载荷[0..5]
- 载荷从字节 42 起 = 5 整字 + **2 字节偏移** → 载荷流 = 源字流移位 2 字节
  (输出字 i = {src[i-1][47:0], src[i][63:48]})。

**RX 决策 (cut-through + 头吸收)**:
- 匹配判定在 w4 拍 (dst_port 可见) 完成 → 吸收 w0..w4 (40B 头) 后从 w5 直出载荷,
  不匹配帧整帧吞掉 (不占下游带宽, 只计数) — "非业务数据旁路快速处理"。
- CRC 结果 (tcrs) 在 TLAST 拍才知道, cut-through 无法回撤 → 末拍 tuser[0]=crc_ok
  标记, 下游 (echo) 自行丢弃; stat 计 crc 坏帧。UDP 校验和默认不验 (行情组播常置 0)。
- P2 范围: 仅无 VLAN IPv4/UDP (行情标准); IHL≠5 / 非 UDP / VLAN → 旁路丢弃计数。

**TX 决策 (帧级递交 + 整帧校验和, 流式发出)**:
- 原因: UDP 校验和覆盖全载荷, 而字段位置在头 (w5) — 流式直通时头发出前载荷未到,
  校验和不可知。行情源普遍置 0 合法, 但通用接口不应依赖。
- app 接口 = 整帧递交 (载荷 AXIS + TLAST 定界), 组帧器: 收载荷 (过 checksum16 运行累加)
  → TLAST 折叠锁存 csum → 发 5 字头 (IP csum 组合树同拍算完) → 流式读 FIFO 发载荷 →
  TLAST 尾字带 2 字节前导偏移。延迟 = 帧长, 1G/100B ≈ 0.8µs, 订单场景可接受;
  10G 时 80ns。载荷一字不复制 (FIFO 单口一遍写一遍读)。
- IP 头固定: ver4/ihl5/dscp0/ttl64/proto17, id 递增, flags=0。UDP csum 可配置 0。

**模块划分**: checksum16 (反码和, 补码累加+帧尾折叠) → udp_rx (parser+filter 合一,
含 2 字节移位器) → udp_tx_frame (组帧器) → echo 集成 → 板测 (PC Python UDP 对端 +
线速泛洪)。

## 2026-08-24 P2 验证完成 — ✅ RX 三模式 + TX 双模式全 PASS (提交 3e3f0bd)

**udp_rx**: 33 帧矩阵 (匹配 0..1500B 全尾形/端口错/IP 错/TCP/VLAN/ihl6/坏 IP 校验和/
udp_len 不符/坏 CRC/背靠背/组播切换) × 三模式 (nostall/stall 逐拍全等 + hard 硬停窗
帧原子丢), stats 与 meta 全对拍 PASS。
**udp_tx_frame**: 20 帧 (0..1500B + 背靠背) × csum_en 0/1, GMII 解码验证头字段/IP 校验和/
UDP 校验和/载荷/FCS/pad/id 递增/stats 全 PASS。
**checksum16**: init+den 同拍共存 (首拍即数据拍) 改动后回归仍 PASS。

### P2 破案教训 (全部已修)

1. **宽度声明错误 → 部分越界选择 = X → if(X) 静默走 else → 校验被绕过**:
   `reg [15:0] w2_r` 却赋 64 位 → `w2_r[31:16]` 越界 = X → ipcsum_ok=X →
   `if (!ipcsum_ok)` 走 else → 坏 IP 校验和帧全放行 (pass 21 vs 期望 20)。
   定位法: TB 探针直打内部值 (ipc_s9=xxxxx 一眼定位)。铁律: 寄存器位宽 = 赋值位宽。
2. **拼接宽度铁律**: 赋给 64 位寄存器的拼接必须恰 64 位 — 72 位截断丢高字节
   (w1 丢 src_mac 一字节 / w4 丢 dst_ip 一字节), 56/32 位零扩展顶部补 0 错位
   (w3 / 零长 w5 = {csum,0} 写成 32 位)。字节流全部错位, 症状 = 整帧内容偏移。
3. **尾字剩余字节公式方向相关**: TX (hold 2B) 剩余 = n-6; RX (hold 6B) 剩余 = n-2 —
   混用后 n-6 为负 → 移位超界 → **keep=0 的字** → mac_tx_64 S_DATA 死循环
   (`cw_idx == cw_len-1` 下溢成 31 永不成立, plen 疯涨 5 万拍)。
   mac_tx_64 可加 keep=0 防御 (后续补)。
4. **RFC 768: udp_len 在伪头与 UDP 头中各计一次** — 少加一次的校验和恰好差 udp_len,
   差值随帧长变化是活线索。
5. **单字帧 plen 残留**: recv_first 分支 NBA 更新 plen 与同拍 plen_r 读旧值竞争 →
   跨帧累加污染 (udp_len=len+8+残留)。帧长在 tlast 拍必须用显式归零表达式。
6. **`-tclbatch ..\run.tcl` 的 \r 被 Tcl 当转义** (source {..\nun.tcl}) — 子目录
   放 run.tcl 副本 + 相对路径引用 (rxsim/txsim 模式)。
7. **agent 教训**: 输出 32000 token 上限 — 大验证任务两轮 agent 报废 (103/18 次调用
   后死在最终报告)。对策: 报告 ≤400 词、逐文件 Write、禁止粘贴代码; RTL 规格先由
   主会话定死, agent 只做验证套件+修 bug 并逐条报告改动。

## 2026-08-24 P2 echo 闭环集成 — ✅ 全链 xsim PASS (提交 d3332d0)

全链 GMII→mac_rx_64→udp_rx→udp_echo→udp_tx_frame→mac_tx_64→GMII, 22 帧矩阵
(0..1500B + 坏 CRC + 不匹配 + 背靠背), 20 回声逐字节验证 (地址交换/双校验和/FCS/
pad/id 递增), 坏帧回卷丢弃 1, 统计全对。
新模块: frame_fifo (FWFT + 写指针快照/回卷), udp_echo (帧级判定 + 顺序转发队列);
udp_rx 增加 fend/ferr 帧级判定 sideband (零长帧无 TLAST, 下游需要帧结束脉冲)。

### echo 集成破案教训

1. **emit 寄存器一拍延迟 vs 帧判定脉冲**: 短帧 (载荷 ≤6B) 的载荷字在 fend 脉冲后
   1..2 拍才上总线 (udp_rx 的 emit 寄存器语义) — 消费端在 fend 拍查 FIFO 必空 →
   误判零长帧 → 晚到字污染下一帧 (整体错位一帧)。判定必须挂起 (pend) 等载荷
   末字实际交付 (accept&&tlast) 或 meta_len==0。
2. **回卷快照差一位**: `wsnap <= wptr_n` 把本拍写入算进快照 → 回卷后坏帧首字幸存
   (+8 字节残留, 症状 = 下一帧内容多一个整字)。快照必须 = 本拍写槽 `wptr`。
3. **单比特队列丢帧**: 转发一帧期间可积压多帧判定 — fwd_pend 单比特在"前一帧
   出队 + 新帧入队"交错时丢一帧 (最后一帧回声消失)。用 4-bit 队列深度计数 fq。
4. **判定逻辑必须在状态机外** (与转发并发): 放 case(S_IDLE) 里 → 转发大帧期间
   新帧的 fend 被忽略 (坏帧回卷丢失)。
5. 转发期间新帧照常写入 (FIFO 并发读写), 顺序转发由 fq 队列保证; 零长帧回发用
   电平信号 ztx (S_FWD 期间被 mux 屏蔽, 回 IDLE 后自然完成)。

## 2026-08-24 P2 板上验证 — ✅ UDP echo 双模式 PASS (提交 42af350)

- **构建**: 首版 WNS **-0.108** (24 路径失败) — 根因: mem 数组写在带异步复位的
  always 块里 → BRAM 推断失败 → 2048 深 frame_fifo 落 LUTRAM (11 级读 mux 链)。
  修复: mem 独立无复位 always 块 (fifo_sync/frame_fifo 都拆) → WNS +0.223,
  LUT 11.6K→6.2K。**但 BRAM 仍为 0** (2048×73 仍未推断成功 — 125MHz 无碍,
  10G (156.25MHz) 前必须解决, 记入 P6: 试 72 位宽或显式 BRAM 例化)。
- **烧录**: JTAG 1MHz, DONE=HIGH ✓。
- **板测 (tools/pc_udp_echo_test.py)**: 组播 239.1.2.3:8080 (免 ARP) 20/200/500 帧
  全收对零丢零错 (328 fps, PC Python 循环为瓶颈); 单播 192.168.100.2:8080
  (静态 ARP 00-0a-35-01-fe-c1, 网卡名"以太网 2") 100/100 全对。
- **教训**: ① cfg_multi_en=1 最初只放行组播 → 单播被旁路丢弃 (ip_match 改为
  组播与单播并存); TB 的 cfg 切换要与板上实际配置一致 (cfg_dst_ip 固定不变)。
  ② PC 双网卡 (WLAN 192.168.0.12 / 以太网 2 192.168.100.1): 组播走 metric 低者;
  单播测试前提 = FPGA 所在网段接口有 IP + 静态 ARP。③ 测试脚本收包循环要
  "收到本帧即 break", 否则每帧多等 1 秒超时 (fps 假性 ~1)。
- **P2 全部完成**: 行情 UDP 的 RX 直出 (udp_rx) + TX 组帧 (udp_tx_frame) +
  全链 xsim + 板上 echo 双模式验证。下一步 P3: TCP fast path 数据段 (TCB 寄存器 +
  ACK 生成)。

## 2026-08-24 10G 晶振调查 (P6 硬件准备, 结论落档)

- **官方说明原文** (`数据手册/关于光通信晶振说明.txt`): "如果大家需要光口支持万兆以太网，
  推荐型号是156.25M晶振。型号是 SIT9120AI-2B3-33E156.25"。
- **原理图 (R3最新版本/Kintex7_ECO_R3开发板原理图.pdf 第 6 页) 实锤**:
  位号 **X5** = 125M 差分晶振 (6 脚: PLL/OE/NC/GND/CLKp/CLKn/VDD), 网络
  SYS_CLK_125M_P/N → FPGA Quad115 MGTREFCLK0 (H5/H6); 去耦 C246/C247 (104),
  OE 上拉 R85 4.7K。注释: "125M 差分收发器参考时钟（默认出125M）…
  如需要使用万兆以太网通信功能，请将晶振改为 156.25Mhz"。
  另两颗: X4 = 74.25M (HDMI), X6 = 50M/10PPM (系统)。
- **板上辨识**: 丝印 clkdiffgtx 旁 / C246 旁 6 脚小金属封装 = X5; 顶面丝印
  "A10LP" = SiT9102 系列型号代码 (SiTime 顶面不刻品牌, 只刻代码+频率两行),
  频率在第二行 (应为 125.000)。手册: 开发板硬件资料/芯片手册/siT9102差分晶振.pdf。
- **换晶振不影响 C246/C247/R85**; 换 SIT9120AI-2B3-33E156.25 (156.25M, 同 6 脚差分)。
- **换板对比 (KU115)**: LUT 3.3× / BRAM 4.7× / DSP 6.6× / 多 270Mb UltraRAM /
  GTH 16.3G (10G 有 60% 余量, 325T GTX 10.3G 恰好零余量) — 本协议栈 30-45K LUT
  在 325T 只占 15-22%, 够用不换; KU115 留给 25G 演进/全行情流水线再考虑。

## 2026-08-24 P3 开工 (TCP fast path 数据段)

计划行: 微型 CAM + 寄存器 TCB (seq/ack/窗口) + payload FIFO + ACK 生成; RX/TX 双向
(里程碑: TCP 数据面亚微秒)。

**字节布局 (无 VLAN, TCP 头 20B, 载荷偏移 = 54 字节 = 6 整字 + 6 字节)**:
- w4 = dst_ip[15:0] + src_port + dst_port + seq[31:16]
- w5 = seq[15:0] + ack[31:0] + data_off/reserved + flags
- w6 = window + tcp_csum + urg + 载荷[0..1]; 载荷流 = 源字流**偏移 6 字节**
  (输出字 i = {src[i-1][15:0], src[i][63:48]}) — 与 UDP 的 2 字节偏移同构, 参数不同

**P3 范围决策 (握手/重传/RTO 归 P4 慢路径)**:
- 只处理 ESTABLISHED 数据段; 顺序流假设: **只接受 seg.seq == rcv_nxt** (乱序丢弃
  数据但仍回 ACK — 标准快速重传依赖); 重复段 (seq < rcv_nxt) 丢数据回 ACK
- 窗口检查: seg.seq ∈ [rcv_nxt, rcv_nxt+rcv_wnd) 之外 → 丢段 (慢路径/对端处理)
- ACK 生成: 每数据段一 ACK (延迟 ACK 合并后置优化); ACK 段 = 无载荷帧
  (seq=snd_nxt, ack=rcv_nxt, ACK flag)
- 连接数 16 (微型 CAM: 顺序比较 16×4×32b, 组合两级, 125/156MHz 均无压力)

**模块划分**: tcp_cam (5-tuple→conn_id) → tcb (16×寄存器组: rcv_nxt/snd_nxt/
snd_una/rcv_wnd/snd_wnd/state, 每拍 1 更新仲裁) → tcp_rx (解析+seq 检查+载荷直出
6B 偏移+ACK 请求) → ack_gen + tcp_tx_frame (TCP 组帧, 校验和伪头 0x0006, tcp_len
计两次同 RFC768 规则) → 全链 xsim (Python 模型对拍 seq/ack) → 板测 (PC TCP 对端)。

## 2026-08-28 P3 中段: tcp_rx / tcp_tx_frame 落地 (xsim 全绿)

**修正上文一处规划错误**: TCP 校验和的 tcp_len **只计一次** (伪头) — TCP 头没有
长度字段 (UDP 的 udp_len 在伪头+UDP 头各出现一次才计两次)。伪头协议字 = 0x0006。

**tcp_rx (三模式 274 行周期精确对拍全等, 28 帧)**:
- 头吸收 w0..w6; w5 拍组合判读 (CAM 命中/state==ESTAB/flags=ACK 且无 RSF/doff==5/
  total_len>=40/窗口/seq==rcv_nxt/ack∈(snd_una,snd_nxt]); w6 拍定案
- 载荷从字节 54 起 = 6 整字 + **6 字节偏移** (hold16, 输出 = {上一源字低 2 字节,
  当前源字高 6 字节}); 短载荷 w6 直出 (plen<=2), 填充帧 pop8 允许 > 剩余 (S_PAD)
- 重复段判定: seq < rcv_nxt 用**无符号直接比较** (不能用 seq-rcv_nxt 差值判窗口,
  32 位回绕会把 dup 判成窗口外 -> dup-ACK 丢失, 快速重传废掉)
- 纯 ACK (plen=0) 绝不回 ACK (防 ACK 环), 但仍 fend + drain snd_una/snd_wnd
- 坏 FCS 段: 载荷照发 (tuser 标记), 不回 ACK 不推进 rcv_nxt (对端超时重传)
- TCB drain: fend 锁存 pend_{rcv,una,wnd} -> 拍1 rcv_nxt, 拍2 snd_una, 拍3 snd_wnd;
  **drain case 绝不能有 default 覆写 drn** (NBA 后者胜出, fend 拍的 drn<=1 会被
  default 的 drn<=0 吃掉 -> drain 永不启动, 实测抓到)
- 同型坑复现: pay_r[2:0] 把 8 截成 0 -> 溢出尾字 keep=0 (全局教训"移位量宽不
  匹配"又一实例; 以后所有 pay_r 切片用 [3:0])

**tcp_tx_frame (17 帧 GMII 语义校验全过: 头/双校验和/载荷/FCS/seq 推进/ACK 插队)**:
- ACK 段 8 深队列, 帧边界调度, 优先于数据段; 纯 ACK flags=0x10, w6 keep=0xFC
- 头 54B: w0..w5 整字 + w6={window,csum,urg,载荷[0..1]}; hold48 偏移 (与 RX 镜像)
- 校验和分 3 拍 aen: checksum16 add_val 仅 18 位, 每组 <=4 半字 (<2^18) 防溢出
- 测试 agent 抓到 2 个主会话盲区 bug: ① tail_d 声明 48 位截断 ljust6 的 64 位
  (len%8>=3 的帧尾字丢高 2 字节) ② S_DONE 注册 upd 与紧挨的下一帧 start_data
  同拍 -> 读旧 snd_nxt (背靠背同连接帧 seq 丢增量); 改组合 upd (S_DONE 消费拍
  与状态回 IDLE 同拍写 TCB, 下一帧最早下拍启动读到新值)
- upd_* 组合化的时序判据: 消费者同拍写 TCB, 下一帧 start 至少晚 1 拍, 安全

**工作流更新 (用户指令)**: ① 重构允许, "只移植不重构"作废, 功能实现为唯一标准;
② 每里程碑必开审查 agent + 测试 agent (本次 2 个真 bug 均为测试 agent 抓获)。

下一步: #48 全链 xsim (mac_rx_64->tcp_rx->tcb->tcp_tx_frame->mac_tx_64 环回,
PC 侧模拟对端: 发数据段收 ACK, 收数据段回 ACK), 然后 #49 板测。

## 2026-08-28 P3 审查修复轮 (review agent 首轮实战)

**真 bug (已修, 全部回归复绿)**:
1. **SOP 截断防御无条件清 emit_v (tcp_rx + udp_rx 同源)**: 上一帧末字
   (emit_l=1) 在下游硬背压 >=20 拍未消费时, 新帧 w0 到达即覆盖 -> 好帧静默
   丢尾字。修: 仅清半帧残留 (!emit_l); 完整尾字由 w5/w6 拍 s_axis_tready
   门控等排空 (S_HDR 此前 tready 恒 1, w5/w6 是唯一会发 emit 的头拍)。
2. **TCB 更新口 RX/TX 冲突无仲裁 (集成契约缺失)**: tcp_rx drain 3 拍电平 vs
   tcp_tx S_DONE 单拍, 同拍冲突丢 snd_nxt/rcv_nxt = 连接卡死级。修: rx upd_*
   改组合电平 + upd_gnt 输入 (保持到 granted); tx 保持 S_DONE 消费拍组合单拍;
   顶层仲裁 tx > rx > 慢路径 (tx 不可等待, rx 靠 gnt 顺延, cfg 只在配置期用)。
   **P4 慢路径写 TCB 必须容忍被抢 (无 gnt 反馈), 只能在连接建立期写**。

**加固 (角例/脆点)**: w6-tlast emit 门控; stat_bytes 补 tcrs 门控;
S_TAIL→S_HDR 补 wcnt 复位; S_PAY 非末字加帧身超长检查 (pcount+8>plen ->
S_DROP, 防 pcount 回绕留半帧); tcp_rx 加 IP 分片检查 (MF/offset!=0 丢给 P4,
新 frag 场景帧); tx 注释补 app presenting 契约 + plen 12 位上限。

**drain 与下一帧 fend 交叠: 确认不可达** (drain 3 拍 vs 帧间 >=20 拍 IFG +
最短帧 7 字), pend_* 不会被覆盖。前提: mac_rx_64 帧间契约成立。

**重构落地 (限制放开后首件)**: tcp_cam 从 tcp_rx 内部提升到顶层 —
tcp_rx 输出 4 元组组合查询 (w4 拍), 输入 q_hit/q_id; TX 读回口共享同一
连接表; 慢路径只配置一份。tb_tcp_rx 同步改外置 CAM, 回归无损。

**模型维护教训**: RTL 改组合/注册语义时, 周期精确模型必须同步改
(本次 drain 从"注册 upd 延迟 1 拍写"改"组合 drn 拍当拍写"; 无观测差异时
也不可偷懒, 否则日后加场景时模型静默失真)。

## 2026-08-28 P3 #48 全链 xsim PASS (test agent 一次通过)

**拓扑**: mac_rx_64 -> tcp_rx -> tcb <-> tcp_tx_frame -> mac_tx_64; CAM 外置共享;
仲裁器 tx > rx > cfg (组合)。TB 模拟 PC 对端: Python 周期精确调度器离线推演
整条时间线 (DUT 行为确定), 反应式生成 RX 流 (DUT 数据段 -> 对端回 ACK),
锚点对齐制造 upd 冲突窗口。

**结果**: 14 RX 帧 -> 12 TX 帧, 帧序/事件 (FEND/ACK/TUPD/COLL) 逐拍全等;
两处工程化仲裁碰撞 (k=230 tx snd_nxt vs rx snd_una; k=1571 tx vs data1000
drain) 均无损: rx 被压字段顺延 1 拍, 值无丢; TCBF 终态精确。

**全链抓到的存量 bug (mac_tx_64)**: pad 判定 `plen+1 >= 46` 用了 payload 基准,
但 plen 计的是含 14B 以太头的全部内容字节 -> content∈[46,60) 的帧不补 pad
上线成 runt (TCP 纯 ACK 54B 必中; UDP echo 的 42..59B 帧也曾中招, 板测能过
是 Killer 网卡收 runt)。修: MIN_CLEN=60 (内容基准)。**所有 Python 模型的 pad
规则同步改** (gen_stim_tx/udp_tx/echo/tcp_tx/tcp_chain), 五个 TX 侧回归全部
重跑复绿。教训: "46" 是 payload 基准, "60" 是内容基准, 注释必须写明含头与否。

**工作流坑 (已修)**: sim/p3sim 下多个 TB 共享 stim_*.memh/txp_*.memh 文件名,
后跑的生成会覆盖先跑的 -> tcp_tx 回归曾拿 chain 的刺激跑出 frames=4 假象。
修: run_tb_tcp_rx.bat / run_tb_tcp_tx.bat 头部加自生成步骤 (chain 的 bat 本来
就是生成->编译->仿真->check 一条线)。**规矩: p3sim 每个 bat 必须自生成刺激**。

下一步 #49: 板上 TCP 对端 (wrapper_tcp + PC TCP client)。需要新增 tcp_echo
适配模块 (RX 载荷 -> TX app, 帧边界握手: meta_valid 锁 conn, 等 tx S_IDLE),
并先在全链 xsim 里过一遍再上板。

## 2026-08-28 P3 完成 ✅ 板上 TCP echo PASS (Windows 真栈对接)

**结果**: 三次握手 13.2ms; 14 块 (1..1460B) 逐字节回显全对, 平均 RTT 0.05ms。
Windows 真实 SYN 带 12B 选项 (doff=8, mss1460/ws8/sackOK) — tcp_rx 的
doff!=5 丢弃路径不影响 SYN sideband (syn_l 在 w5 无条件锁存, S_DROP 帧尾
照样 syn_v); 我方 SYN+ACK 无选项, PC 接受。

**板上两轮抓到 3 个问题 (xsim 全没抓到的原因各异)**:
1. **SYN+ACK dst IP = 本机 IP**: CAM 4 元组是 RX 视角 (sip=对端, dip=本机),
   TX 组帧错用 rd_dip 当目的 IP — **模型与 RTL 同错互相印证** (chain/echo
   xsim 全绿但语义错)。修: CAM 读回口加 rd_sip, TX 用它作 dst IP。
   教训: 语义级正确性要**独立于 RTL 的参考** (例如让模型按协议规范写期望值,
   而不是镜像 RTL 的行为), 至少关键字段要有常识校验 (dst IP 不可能等于本机)。
2. **批量替换空格变体**: TB 的 `.port(wire),` 紧凑格式被替换命中, wrapper 的
   `.port   (wire),` 对齐格式漏掉 → wrapper 的 CAM 实例没接 rd_sip → 悬空=0
   → dst IP=0.0.0.0。教训: 端口接线批量改必须 grep 验证每个实例的每个端口。
3. **pktmon etl 追加合并**: 多次 stop 合并进同一 PktMon.etl, 旧帧在前 —
   重新抓包前必须删除 etl, 否则误读旧数据 (两次"行为没变"的假象)。
   pktmon etl2txt 参数是 `--verbose --hex` (没有 -v); 路径用正斜杠。
   pktmon 的 etl 落在调用时 cwd (git-bash 的 cwd), 不是固定目录。

**P3 全部里程碑**: cam/tcb -> tcp_rx -> tcp_tx_frame -> 全链 -> SYN 握手 ->
echo 全链 -> 板上 PASS。6 个回归 (cam_tcb/tcp_rx/tcp_tx/chain/echo + P2 三套)
全绿。板级: WNS +0.482, LUT 8.3K, BRAM 0 (frame_fifo 分布式 RAM, 10G 前要解决)。

**下一步 P4**: 慢路径 HLS 移植 (ARP/ICMP/DHCP/重传/RTO/FIN, 正式握手替代
tcp_synp)。P5: app 接口。P6: 10G (晶振 + PG157 + BRAM 化)。

## 2026-08-29 P4 开工 — 里程碑分解与架构决策 (先行落档)

**总目标**: 慢路径 = udp_hls_eco 现有 HLS 协议栈 (ap_ctrl_none, 8bit+TLAST 字节流)
原样集成为独立 IP, 经宽度转换挂进 64bit 字流数据面; 数据面新增帧级分流器。
里程碑 (每程独立板级可验证, 每程必开审查+测试 agent):

- **P4a 物理通路 + ARP/ICMP**: rx_classify + w64to8/w8to64 + tx_arb + HLS IP 原样
  集成 (udp_echo_prj 综合产物直接用, 零代码改动); TCP 仍走 fast (tcp_synp 握手
  保留); 板测 = 删静态 ARP 后 ping 通 + TCP echo 回归 (+ UDP 8080 echo 慢路径白送)。
- **P4b TCP 正式握手**: classify 加深 skid 到 6 字窥 w5 flags, SYN/FIN/RST 分流
  慢路径; HLS 握手结果 (peer ip/port/iss, 本机 iss/wnd) 经配置通道写 CAM/TCB
  (cfg 仲裁口, 只连建期写, 容忍被 tx/rx 抢 — P3 审查轮契约); 移除 tcp_synp。
- **P4c 重传/RTO**: fast 侧重传缓冲 + slow 侧 RTO 扫描, 事件化注入。
- **P4d DHCP/IGMP** (可选)。

**架构决策**:

1. **分流点 = mac_rx_64 之后立即 classify** (不让 tcp_rx/udp_rx 各自吞帧过滤):
   ethertype 在 w1[31:16] (byte 12-13), proto 在 w2[7:0] (byte 23) — w2 拍定路由,
   3 字 skid 缓冲 w0..w2, 定路由后先倒 skid 再 cut-through。路由: TCP→fast;
   UDP→slow (P4a 权宜, HLS UDP echo 白送; P5 才接 fast UDP); 其他→slow。
2. **slow 路由水位丢帧**: 决策拍检查 slow 字节 FIFO 剩余 <1536B 则整帧吞掉+计数,
   **绝不因慢路径堵塞 fast 路由** (mac_rx_64 的"背压满丢整帧"会误伤 TCP 数据帧)。
3. **宽度转换**: w64to8 = 1 字 8 拍串行 (125MB/s ≈ 1Gbps, 慢帧稀有足够);
   字节流格式 = 9bit {tlast, data[7:0]}, 与 wrapper_1g 的 HLS FIFO 桥同语义。
4. **TX 仲裁**: tx_arb 2:1 帧级 mux, fast (tcp_tx_frame) 严格优先, 锁定到 TLAST。
   HLS 慢路径 TX 帧含完整以太头, mac_tx_64 直接发 (pad/FCS 照旧)。
5. **IP/MAC 一致性**: fast cfg (cfg_src_mac/cfg_src_ip) 与 HLS 编译期 MAC/IP 必须
   同值 (00-0a-35-01-fe-c1 / 192.168.100.2) — 集成时核对。
6. **HLS TCP/UDP 数据面代码在 P4a 是死代码** (classify 不分数据帧给它), 36K LUT
   资源占用可接受 (8.3K+36K < 60K 预算); P4b 只做"加法手术" (握手点旁路出配置
   记录), 不切除 — 降低移植风险。

**调查 agent 已派**: 测绘 HLS 栈顶层端口/配置值/自发行文/TX 仲裁/空转风险,
结果落档后指导 wrapper 集成。

### HLS 栈测绘结果 (agent 报告归档, 源: udp_hls_eco/src + 综合产物)

- **顶层模块 `udp_echo`** (ap_ctrl_none, 综合 verilog 161 文件): 端口 =
  ap_clk / ap_rst_n / **reset_n (ap_none 软复位, 必须显式接, 悬空=phi-mux X 死锁)** /
  rx_stream_TDATA[15:0] = {6'b0, TLAST(bit8), byte} + TVALID/TREADY /
  tx_stream 同构输出 / msg_stream (UART 调试, TREADY  tie 1) / led_d0..d3
  (d0=DHCP_DONE)。无 ap_ctrl。
- **时钟 125MHz** (gmii_clk 域, csynth 达成 6.373ns); 资源 ~41.8K LUT (HLS 估计)
  / 36.2K (Vivado 优化后) + 30 BRAM18 + 4 DSP。与本工程 8.3K 合计 <60K 预算。
- **MAC 冲突实锤**: HLS 编译期 MAC = 00:0A:35:01:FE:**C0** (eth_types.h),
  fast path 一直用 C1! **统一为 C0** (HLS 是板验资产不动, fast 侧 cfg 一行;
  P4a 板测删 PC 静态 ARP 后由 HLS ARP 应答建立 C0 绑定)。IP 同为 192.168.100.2。
- **HLS MAC RX 契约** (layer_mac.cpp:71-170): 需要 0x55 前导 + 0xD5 同步;
  单播过滤 dst==C0 或广播 (组播丢); **不校验 FCS** — ethertype 之后全部字节
  (含 pad/FCS) 都进 frame_fifo, 上层按 IP total_len/定长解析, 尾部自然忽略。
  → slow_rx_adp 只补前导不重生成 FCS; 坏帧由适配器按 tcrs/terr 拦截。
- **HLS MAC TX 契约** (layer_mac.cpp:176-318): 完整线上帧 7×55+D5 + 头 +
  payload + pad(60B) + FCS 4B (LSB-first), tlast 在末 FCS 字节。
  → slow_tx_adp 剥前导 + 4B 回持剥 FCS (FCS 由 mac_tx_64 重算, 免双重 FCS)。
- **自发行文 (P4a 全部保留, 白送的慢路径 TX 冒烟)**: 上电 ~1s DHCP DISCOVER
  ×3 (~130ms 间隔, 无服务器则永久 DHCP_FAILED); 每 ~5s UDP HELLO 到
  192.168.100.1:8080 (首次前先发 ARP 请求)。均不阻塞其他 TX (tx_req 逐拍仲裁)。
- **HLS TCP 在 P4a 是死代码但安全**: 见不到 SYN 则无 TCB; SYN+ACK 未应答会
  RTO 重传 (80ms→640ms 倍增) 永不放弃 — P4b 接握手时必须有配套处理。
  HLS 无 RST 显式处理 (落入 ACK-only 分支无害)。TCP 听端口 7, MAX_TCP_CONN=3,
  ISS = 0x12345678 | (cid<<20), SYN 接受点在 layer_tcp.cpp:370 (P4b 旁路点)。
- **ARP 表**: l1[8] 全并行 + l2[256] BRAM, 每个收到的 ARP 帧都学习 sender。

### P4a RTL 落地 (rx_classify / slow_rx_adp / slow_tx_adp / tx_arb, xvlog 已过)

- **rx_classify**: 3 字 skid, w2 拍定路由 (ethertype==0x0800 && proto==6 → fast,
  其他→slow; runt→slow)。DRAIN 期 s_tready=0 (≤3 拍/帧, mac_rx_64 的 8 深 FIFO
  吸收; 1G 字流天然 ≥3 拍帧间隔, stall 不传播)。**10G min-frame 洪泛极限**:
  每帧 8 字+3 拍 stall > 10.5 拍预算 → mac 层计数丢帧, 记 P6 复审 (加深 mac fifo
  或 skid 改真 FIFO)。
- **slow_rx_adp**: 字流→frame_fifo(512×73) 整帧缓冲 (snap@SOP / commit@好帧尾
  / rollback@坏帧; s_tready≡1, 满则吞字 abort) → 字节播放器补 8B 前导 →
  2048×9 → HLS。**单字 runt (SOP&&TLAST) 不写不快照不回卷** (frame_fifo 同拍
  snap+rollback 会读旧 wsnap 的坑)。
- **slow_tx_adp**: HLS tx_stream→2048×9→字节 FSM (剥前导 55..D5, 容忍 4..15 个
  55; 4B 回持剥 FCS; 字节索引直写打包避移位量坑) → frame_fifo(512×73) 整帧字
  缓冲 (字节率 << 字率, 不整帧缓冲会 mac_tx_64 欠载 runt) → AXIS。**末字合成**:
  in_last 拍毕业字节直接拼末字 (pc==7 时该字即末字带 tlast), 否则部分字索引
  合并+显式 keep case。
- **tx_arb**: 注册授权帧级 mux, fast 优先, 锁到 TLAST, 帧间 1 拍气泡。
- **committed 计数器 (+1 commit / -1 play_done 同拍互抵)** — 两适配器同构。

### wrapper_p4 + 构建基建落地

- **wrapper_p4.v**: 前端逐字复用 wrapper_tcp 配方; mac_rx_64 → rx_classify →
  fast (P3 TCP 链原样, tcp_synp 保留) / slow (slow_rx_adp → udp_echo →
  slow_tx_adp) → tx_arb → mac_tx_64。**cfg_src_mac 改 C0** (与 HLS 统一)。
  LED: d0=RX 帧 / d1=TCP pass / d2=慢帧提交 / d3=HLS 发出。
- **隐式声明坑 (wrapper_tcp 遗传)**: tcb_wr 等 4 线先用于 u_tcb 实例后声明 —
  Vivado 综合宽容过关 (wrapper_tcp 板测全绿但一直带这颗雷), xvlog 直接报
  10-2938 拒编。wrapper_p4 显式前置声明 + assign。**以后 wrapper 级文件必须
  过一遍 xvlog** (Vivado 综合不是语法金标准)。
- **build_p4.tcl**: 模式照抄 build_tcp + udp_hls_eco 的 HLS import 配方
  (glob import 161 个 .v + .dat 系数文件拷到导入目录, $readmemh 相对路径)。
  program_p4.tcl / run_*.bat 同模式 (bat 用 Write 工具写 + unix2dos —
  **printf 写 bat 会被 bash+printf 双重转义毁掉** (\r \E \202 \v \b 全中),
  实测 od 验证)。

### P4a 审查轮 (review agent 首战: 2 致命 + 1 风险, 全部已修)

1. **slow_tx_adp i_rd 寄存器化 = 铁律#4 再犯 (致命)**: FWFT fifo 的 rd 寄存
   器化 → 字节在 dout 挂 2 拍 → FSM 每字节处理两次 → 打包流全废。修:
   `i_rd = (tstate != T_IDLE) && !i_empty` 组合同拍消费。**主会话明知铁律
   仍踩坑 — 铁律检查必须进每个含 fifo 模块的自查清单**。
2. **slow_tx_adp wf_rd 同病 (致命)**: 组合 tvalid + 寄存 rd → 每帧首字双发
   + 后帧首字被无握手吃掉 (headless frame)。修: `wf_rd = m_valid && m_tready`。
   slow_rx_adp 的 P_LOAD 免于此病 (wreg 锁存 + ≥2 拍间隔, 审查确认免疫)。
3. **截断帧 SOP 防御 (风险)**: mac_rx_64 fifo 满截断帧 (无 tlast 前缀) 后,
   下一帧 SOP 到达: classify 会把 B 帧词 glued 进 A 的路由; slow_rx_adp 原
   实现会把 B 的 snap 覆盖 A 的 wsnap → A 的孤儿词复活进播放流。修:
   slow_rx_adp 加 in_frame/resync_drop — 截断事件回卷 A 残余 + 牺牲 B 整帧
   (frame_fifo 不能同拍 rollback+写, 别无选择); fast 侧由 tcp_rx 自带 SOP
   防御兜住 (P3 审查轮已加固)。classify 本身不加逻辑 (两端的消费者都兜住)。
- HLS 158 个 .v (163 模块) xvlog 全过零 ERROR — 集成 TB 可带真 HLS 仿真。

### P4a 全链 xsim PASS (tb_p4_chain, 真 HLS 进仿真) — 一次通过

**拓扑** = wrapper_p4 数据面完整复制 (无 RGMII 前端): GMII → mac_rx_64 →
rx_classify → fast (P3 TCP 链) / slow (slow_rx_adp → **真 udp_echo HLS** →
slow_tx_adp) → tx_arb → mac_tx_64 → GMII 捕获。校验全语义级 (HLS 应答拍级
不可预期; 快慢流在 tx_arb 自由交错): 慢流顺序 = RX 顺序 (HLS 串行处理),
逐帧谓词 (ARP op/地址、ICMP id/seq/payload/双校验和、UDP 端口交换/payload)
+ 全帧 FCS 重算; 快流 = tb_tcp_echo 逐字节匹配 (ip id = 快流内序号 — 慢帧
不过 tcp_tx_frame 不占 id)。

**结果**: 9 RX (arp/icmp/udp/syn/hs_ack/data7/data9/arp/c1data20) →
11 TX (fast 7 = synack + 3×(ack+echo), slow 4 = 2×arp_reply + icmp_reply +
udp_echo), 逐字节全对; STATS7/TX/ECO/CAMF/TCBF/SLOWRX/SLOWTX 全精确;
FEND=4 SYNP=1 ACKEV=4。**唯一期望值笔误**: STATS7 nonmatch=1 是 SYN 的
CAM miss (conn0 未配置时的正常计数), 期望误写 0。

**基建**: run_tb_p4_chain.bat 自生成一条线 (拷 3 个 .dat → gen → xvlog
(rtl + HLS -f) → xelab → xsim → check); **xelab/xsim 的 -log 文件名会与
shell 重定向同名文件冲突** (xelab.log/xsim.log 是工具默认名, 重定向占用
导致 17-183) — 重定向用 xelab_run.log/xsim_run.log。

### P4a 完成 ✅ 板上 PASS (一次通过: ARP 免静态 + ping + TCP 回归 + UDP)

**构建**: WNS **+0.918** (全约束达成), LUT 26.3K (12.9% — HLS 优化后仅 ~18K,
远低于 41.8K 估计), FF 17.6K, BRAM 26.5。烧录 DONE=HIGH。
**板测 (tools/pc_p4_test.py, 先删静态 ARP: netsh delete neighbors)**:
1. **ARP+ICMP**: ping 192.168.100.2 = 4/4 0ms; ARP 表出现 **动态** 绑定
   192.168.100.2 → 00-0a-35-01-fe-c0 — HLS ARP 应答器生效, 免静态 ARP。
2. **TCP 回归**: 握手 10.3ms, 14 块 1..1460B 逐字节回显全对, 平均 RTT
   0.04ms — classify 插入后 fast path 无损。
3. **UDP echo** (HLS 慢路径白送): 64B 回显 RTT 0.16ms。
**P4a BOARD PASS** — 全链 xsim (真 HLS) 把板级风险全部前置消除, 板上一次通过。

**P4a 遗留**: 单元 TB (test agent 进行中); GitHub push 网络中断待重试
(本地 commit 070f194)。

## 2026-08-30 P4a 单元回归轮 — 审查/测试 agent 价值实锤 (3 真 bug 全修)

test agent 交付 tb_rx_classify + tb_slow_rx 后撞 403 配额; 主会话接手补完
tb_slow_tx/tb_tx_arb。排错链挖出 **3 个真 RTL bug** (板测 PASS 都没暴露,
全是单元压力路径):

1. **frame_fifo full 公式缺陷 (存量地雷, P2 起就在)**: 旧式
   `(wptr 低位+1 == rptr 低位) && 绕回位异` 在 rptr 低位==0 时等效要求
   rptr==512 (不可能) → **该窗口内 full 永不触发**, 写满后继续写绕回踩槽
   (数据面静默损坏)。P2/P3 板测全绿是因 fifo 从未逼近满。修: 与 fifo_sync
   同式真满判定。所有 Python 模型同步 (模型同步铁律)。
2. **播放器幻影开播 (slow_rx_adp + slow_tx_adp 同病)**: committed 计数器
   在播完拍 (done_pulse/play_done) 递减, 而 P_IDLE/O_IDLE 的"有帧可播"
   判断同拍读到未减旧值 → 最后一帧播完的下拍**幻影开播**, 抢读下一帧的
   未提交词 (绕过 commit/rollback 纪律 — 坏帧会泄漏给 HLS)。板测过是因
   慢帧稀疏, 幻影开播时 fifo 恒空 (P_LOAD 等不到词就挂着, 下一真帧来了
   被截流式播放, 内容碰巧一样)。修: committed 语义改"提交未开播", 开播拍
   即减。**状态机设计教训: "队列计数 + 开播条件"必须同源同拍, 不能一个
   看滞后值**。
3. **gen 模型 wsnap 用后增量 wptr (模型 bug, RTL 正确)**: 回卷边界差一槽,
   丢帧首词复活混入下一帧 — 模型与 RTL 背离, 自查 xref 抓到。
   (P2 教训 "快照=本拍写槽" 的模型侧翻版。)

**修复后回归**: P0×2 + P2×3 + P3×4 (cam_tcb/tcp_rx 三模式/tcp_tx/chain/echo)
+ P4a×5 (rxclass/slowrx/slowtx/txarb/p4chain 真 HLS) 全绿。
**顺手补的基建债**: ① run_tb_tcp_rx/tcp_tx.bat 原来**没有 checker 调用**
(xsim 跑完即算过) — tcp_tx 的 checker 期望还是 rd_sip 修复前的旧语义
(dst=本机 IP), 一直假绿! 已修 checker (dst=sip) 并给两 bat 补 checker 调用。
② 教训追加: printf 写 bat 会被 bash+printf 双重转义 (\U \t \r 全中) — bat
一律 Write 工具 + unix2dos。

下一步: 重建 bitstream 重上板回归 (RTL 变了) → P4b 正式握手。

**修复后板级复测 ✅ (同日)**: 重建 WNS +0.217, 烧录重跑 pc_p4_test.py =
P4a BOARD PASS (ARP 免静态 + ping 4/4 + TCP 14 块回归 + UDP echo)。
**P4a 全部完成。**

### P4a 吞吐率实测与破案 (2026-08-30, tools/pc_throughput_test.py + pktmon)

**实测 (修复前)**: TCP 流式吞吐仅 **1.5 Mbps** (16MB/80s); UDP 慢路径泛洪
300 发只回 24 (慢路径设计如此, 非 bug)。Windows Python 不支持 TCP_MAXSEG
(10042), 段大小只能由对端 MSS 决定 — **我方 SYN+ACK 无 MSS 选项 → Windows
退回默认 MSS=536** (P4b 正式握手时 HLS 的 SYN+ACK 带 MSS=1460 自然解决)。

**pktmon 破案链**:
1. 数据段线速到达无问题; FPGA 的 ack 会**卡死在某个序号** (如 246697256)
   不推进 → PC 快速重传/RTO → 拥塞崩溃 → 吞吐崩塌到 1.5M。
2. 根因 = **结构性带宽倒挂**: 每数据段 TX 要发 2 帧 (纯 ACK 84B + echo
   610B) vs RX 610B — 536B 段下 TX 比 RX 慢 **16.6%** → echo fifo 持续
   净流入 ~11 词/段 → ~186 段 (~0.9ms 满速流) 后填满 → mac_rx_64 截断丢段
   → 重传 → 更堵 → 雪崩。1460B 段时倒挂 5.7% (同病较轻)。
3. **修法 = 标准 TOE 做法: 顺序数据段的纯 ACK 抑制** (echo 帧本来就带
   ACK 位+ack 号, 纯 ACK 冗余)。tcp_rx 加 cfg_suppress_data_ack: 只门控
   fend_w6/fend_pay 路径; **dup/ooo 的 drop_ack 不抑制** (快速重传依赖);
   纯 ACK 段本就不回 (防环)。抑制后 TX=RX 恰好同速, fifo 零净流入。
4. **xsim 反向实证**: 板上还有一处一次性 ~1.95ms 首响应延迟 (空闲后首个
   突发), 用"空闲 200k 拍 + 10 段 536B 背靠背"刺激跑 tb_p4_chain —
   **xsim 里首 echo 仅 ~µs**, 复现不出来 → 该延迟不是本 RTL 链路的
   (疑 PC NIC 中断聚合/pktmon 采集位置), 留观察清单。

**回归覆盖**: tcp_rx/chain 保持 cfg=0 (覆盖未抑制路径); tcp_echo/p4_chain
改 cfg=1 (与板上一致), 模型同步 (rx_model 加 suppress_data_ack 参数;
期望流去掉随行纯 ACK; 统计同步)。四回归全绿。

**pktmon 教训追加**: 同时间戳同内容的"重复帧"是 pktmon 双点采集伪影
(NIC+协议栈两层), 分析前先按 (内容+时间戳) 去重, 别当真丢帧/重传。

### P4a 续: 泛洪死锁破案 + 修复 (2026-08-30 上午, 板测+探针+TB 全链)

**现象**: 150 个 UDP 64B 线速泛洪后, 慢路径永久失联 (ARP/ICMP 不应答),
快路径照常 (静态 ARP 下 TCP echo 仍通)。重烧录复位即恢复 → 泛洪诱发死锁。

**破案链 (全部 xsim 层级探针实锤, tools/gen_stim_p4_flood.py 复现)**:
1. **HLS 内部 512 词帧 fifo 灌满 → mac_rx 写阻塞 → 永久停读** (hls_rx_tready
   恒 0, o_fifo 剩 495B 半帧永不读) — 慢路径泛洪死锁的根因在 HLS 栈内部
   (老工程从未泛洪测试过)。26 个 echo 后卡死。
2. **修法 1 = 开播节流**: slow_rx_adp 只在 o_fifo 占用 ≤256B 时才开播下一帧
   (occ 是 HLS 内部积压的直接代理) — HLS 内 backlog 恒 ≤4 帧 ≪ 512 词,
   泛洪永不灌满它。吞吐影响: 控制面帧 ~30µs/帧, 无所谓。
3. **修法 2 = abort 粘连修复**: "fifo 恰好 TLAST 拍首次满" 时, 帧尾的
   `abort<=0` 清零与满置位同拍竞争, NBA 后写胜出 → abort 粘在 1 →
   **下一帧无条件回卷 → 慢路径死** (ARP#2 被吞实锤)。修: 置位条件加
   `!tlast` (tlast 拍的满已由 frame_bad 覆盖, 无需置 abort)。
   单元 TB 未覆盖此角例 (4200B 大帧提前满, `!abort` 已 0 掩住) — 泛洪
   集成 TB 抓到。**教训: 清零/置位同拍竞争审计 = 状态寄存器的死角**。
4. **修法 3 = HLS 看门狗** (slow_rx_adp, WDOG 参数默认 2^21≈16.8ms):
   tvalid&&!tready 持续超时 → 打 64 拍复位脉冲 (HLS MAC RX 按 0x55 前导
   重同步, 半帧垃圾自动丢弃)。泛洪有了 1+2 后看门狗永不触发 (纯兜底);
   单元 TB 新增 wd 模式 (tready 恒 0, 复位脉冲拍级对拍 PASS)。
5. 附带: tb_p4_chain 加 PROBE 模式 (层级探针打内部状态) — 本次破案主力。

**修后**: xsim 泛洪 = ARP#2 照常应答 (69 提交/83 丢弃/65 TX 帧全 accounted);
四模式单元 TB 全绿; p4_chain/tcp_echo 回归绿。

**pktmon/测量教训**: ① sendall 阻塞模式下的"吞吐"是 Windows/Python 调度
假象 (16MB/80s = 1.5Mbps 是 app 侧节拍, 不是 FPGA) — 真吞吐要双线程 +
稳态段速率。② 我方面无 MSS 选项 → Windows 退回 MSS=536, 小段放大了
ACK 倒挂问题 (1460B 段倒挂 5.7% vs 536B 段 16.6%)。

### P4a 终态: 吞吐率数字 + 边界归因 (板级实测, 全修复后)

**修复后实测 (板上)**:
- **TCP echo 持续流: ~110 Mbps 稳态** (32MB, 发送侧/稳态一致; 修复前 1.5Mbps
  → 73×); 零丢段零重传。窗口 8K→12K 不动 → 非窗口限制。
- **FPGA 瞬时线速能力 ~890Mbps** (迹线密区 4.8µs/echo 段, 536B 段) — 均值
  被 PC 侧环路压制: pktmon 测得的段→echo 延迟 ~40µs 里, xsim 证明 FPGA 只占
  ~9µs (536B 段 RX 4.7µs + 提交 + TX), 其余 ~30µs 是 PC 网卡 RX 中断/DPC
  延迟 (pktmon Rx 时间戳在驱动层)。**所以 110Mbps 是 Windows 对端环路极限,
  不是 FPGA 天花板**; 真天花板需硬件对端 (P6 后双口对打)。
- UDP 慢路径: 控制面设计 (~几 Mbps), 泛洪按帧边界丢 — 不丢包不保证。
- **泛洪存活 ✅**: 1200×64B UDP 线速泛洪后 ping 通 + TCP echo 通 (修复前
  泛洪后慢路径永久失联)。

**速查 — 当前吞吐率**: TCP fast path 持续 ~110 Mbps (Windows 对端环路限制);
FPGA 本身近线速 (890Mbps 瞬时, xsim 段→echo ~9µs)。P4b 的 MSS 选项会把
536B→1460B, 预期显著提升 (更少段数/更少轮次)。

### P4b 展望 (下一里程碑)

正式握手 (SYN/FIN/RST 分流慢路径 + HLS 握手结果写 CAM/TCB + 移除 tcp_synp);
注意: ① HLS SYN+ACK 带 MSS=1460 (吞吐直接受益) ② HLS 看门狗已备
(slow_rx_adp) ③ FIN/RST 进慢路径后 tcp_rx 的 fast 数据面不再见它们。

## 2026-08-30 P4b 开工 — 设计决策先行 (正式握手替代 tcp_synp)

**目标**: TCP 三次握手/FIN/RST 由慢路径 HLS 正式处理 (带 MSS 选项),
连接建立结果经配置通道写入 fast path CAM/TCB; 移除 tcp_synp。

**架构决策 (设计张力已解)**:

1. **分流**: rx_classify skid 加深到 6 字, w5 拍窥 TCP flags (w5[7:0] =
   byte 47): proto==6 && (SYN|FIN|RST) → slow; 纯 ACK/数据 → fast。
   握手第 3 个 ACK (纯 ACK) 天然进 fast path — 那时 CAM/TCB 已由 HLS
   配好 (乐观 ESTABLISHED, tcp_synp 已板验此语义可行)。
2. **HLS 乐观建连**: SYN 接受拍 (layer_tcp.cpp:370) 即经 cfg 通道写
   CAM/TCB (state=ESTABLISHED) — 不等第 3 个 ACK (它进 fast path,
   HLS 永远看不到)。HLS 自己 T_SYN_RCVD 只用于 SYN+ACK 重传。
3. **SYN+ACK 重传必须限次** (HLS 现状: 无上限, 80ms→640ms 永不放弃):
   工作连接的 ACK 全进 fast path, HLS 永远收不到 → 会无限重传 SYN+ACK
   垃圾帧, 对端 (Windows) 收重复 SYN+ACK 会回 RST 杀连接! 改
   layer_tcp.cpp: 重传 ≤3 次后放弃 (T_SYN_RCVD → 释放槽位; fast 侧
   CAM/TCB 条目保留 — 若连接活着照常工作, 若死了等下次 SYN 覆盖)。
4. **配置通道 = HLS 新增 cfg_stream 输出** (HLS 手术: 顶层加端口,
   layer_tcp 在 SYN 接受/FIN 处写配置记录); 记录格式自定 (定长 16B×N
   或 32b 字流); 新 slow_cfg_adp (fast 侧) 解析记录 → CAM cfg_wr +
   TCB upd (cfg 仲裁级, tx>rx>cfg 已有)。
5. **tcp_rx 的 syn sideband 变死代码** (SYN 不再进 fast) — 保留不拆
   (回归兼容), wrapper 不再接 synp。
6. **FIN**: 对端 FIN → 慢路径 → HLS 建 FIN+ACK 应答 + 写 CFG_DEL
   (fast CAM 清连接 / TCB state→CLOSED — tcp_rx 后续段 CAM miss 丢弃)。
   RST 类似 (HLS 无 RST 显式处理 — P4b 补最小: 收到 RST → CFG_DEL)。

**分解**:
- P4b-1: classify w5 flags 分流 (skid 6 字) + 单元 TB
- P4b-2: HLS 手术 (cfg_stream + SYN/FIN tap + 限次重传) + 重综合
- P4b-3: slow_cfg_adp + wrapper_p4 集成 (移除 tcp_synp)
- P4b-4: xsim 全链 (握手+数据+FIN, 真 HLS)
- P4b-5: 板测 (连接/echo/关闭循环 + 吞吐 MSS=1460 复测)
- 每步必开审查+测试 agent。

## 2026-08-30 P4b-4 排障 — 三个根因 (全链 xsim)

**症状**: udp echo 载荷 24B 中 bytes 17-19 = `03 07 01` (期望 `7a 81 88`),
FCS 与污染内容自洽 (checker 不报 fcs bad); CAMF 错位一词; TCB state=0。

**根因 1 — slow_cfg_adp 记录错位一词**: 编译清单 (run_tb_p4_chain.bat)
漏了 slow_cfg_adp.v → xelab 链接的是旧 .sdb (xsim.dir 残留) → 所有源文件
修复全部无效! 症状: w regs 整体错位 (w1=0, w3 持 w2 值...)。修: bat 补
slow_cfg_adp.v (同时移除 tcp_synp.v)。教训: **bat 改文件清单后必查
xvlog 是否真的编译了目标文件; xsim.dir 里的旧 .sdb 会让 xelab 静默用旧码**。

**根因 2 — slow_cfg_adp 的 TCB 第 6 字段 (state=1) 永远写不进**:
upd_sel/upd_val 是寄存器, 比 tcb_idx 晚一拍可见。gnt 拍写入的是前一
idx 的字段 (字段 0-4 恰好各写一次, 值对), tcb_idx==5 的 gnt 拍 FSM
直接退出 (upd_wr<=0) → state=1 从未落地。修: tcb_idx==5 && gnt 时进
S_TCB_LAST 状态, upd_wr 再保持一拍 (upd_sel=5/upd_val=1 可见) 再退。
(写口语义: upd_wr 电平 + 仲裁 cfglvl_wr = upd_wr && gnt, 每拍一字段。)

**根因 3 — HLS tcp_send 直写共享 TX 区砸在飞帧 (udp echo 污染)**:
eco 工程给 TCP 数据路径修过 (tcp_queue 私有 BRAM, busy-gate), 但
**控制帧 (SYN+ACK/FIN+ACK) 路径漏修** — tcp_send 无条件写
buffer[TX_UDP_BASE], 与 udp echo 同区。mac_tx 逐字节流式读该区
(每字节一拍, 每词读 4 次) — 帧完成拍 tcp_send 一拍写入就把在飞帧
砸了。实测时间线 (HLSTX 探针): echo 载荷 byte 16 @k=63810 干净,
byte 17 @k=63990 已污染; cfg 记录首词 @k=63970 — 正好是 SYN 处理拍。
污染值 `03 07 01` = SYN+ACK 选项区 seg[25..27] (WS=03 03 07 尾 + NOP 01)
— 逐字吻合 (word 523 = `03 03 07 01`, byte 16 已读走所以幸存)。
P4a 时代 SYN 走 RTL tcp_synp, HLS 永远不见 SYN, 此坑从未暴露。
修: udp_echo.cpp 顶层 — TCP 帧完成拍若 mac_tx_busy, 存元数据
(ip_rx + src_mac) 延迟到 MAC 空闲拍再处理; 新帧完成即作废旧挂起帧
(frame_buf 被覆盖, 对端重传兜底)。隔离实验 (tb_hls_udp_probe 直喂
ARP+UDP) 先证 HLS 本身干净, 才定位到链上 — 排障顺序值得记下:
**HLS 孤立探针 → 链上字节探针 (SRXW/HLSRX/HLSTX) → 时间线对位**。

**根因 4 — 刺激时序**: syn 后间距只有 300B, hs_ack/data7a 在 fast
路径 CAM/TCB 配好前就到达被丢 (HLS 处理 SYN + cfg 落地 ~4k 拍)。
真实 TCP 里 PC 等 SYN+ACK 才发数据。修: **hs_ack 的 gap → GAP_SLOW**
(注意 gen_stim 的 gap 语义 = **帧前**间距! 第一次改到 syn 的 gap 上
只是把 syn 自己推迟, hs_ack 依然紧跟其后 — 坑上加坑)。

**P4b-4 修正清单**: slow_cfg_adp.v (f_rd 组合去双驱动 + state 字段
S_TCB_LAST 拍) / udp_echo.cpp (TCP 控制帧 busy 延迟) / gen_stim
(hs_ack gap 20000) / run_tb_p4_chain.bat (补 slow_cfg_adp.v 编译)。
结果: P4 CHAIN OK (9 RX / 8 TX: fast 3 echo + slow 5)。

## 2026-08-30 P4b-4 审查 agent findings 处置 (回归 17/17 绿后)

**修了**:
1. **看门狗复位打断 cfg 记录 → slow_cfg_adp 永久错位**: HLS 被 hls_rst_n
   复位时若 8 词记录写一半, 解析永久偏移 (8-N) 词, 垃圾记录误开/误删连接。
   修: wrapper_p4.v + tb — slow_cfg_adp 的 rst_n 改接 `reset_n & hls_rst_n`,
   与 HLS 同拍复位清 FIFO/state/wcnt。
2. **RST 对已释放槽不补 DEL**: 重传超限释放的槽 (peer_ip/port 保留) 收到
   对端 RST 时, 旧代码在 state==T_FREE 守卫处直接 return → fast 残留条目
   永远清不掉。修: RST 处理前移, 4 元组命中任一槽 (含 T_FREE) 均清拆 +
   CFG_DEL; **未命中则静默** (乱选空闲槽发 DEL 会误杀同槽活连接)。

**不修 (设计意图, 审查误判)**:
- 审查建议"重传超限释放槽位时补 CFG_DEL" — 不可取: 超限释放的典型场景
  是握手 ACK 走 fast path (HLS 永远看不到), fast 条目正是**活连接** —
  补 DEL 会杀掉正常工作的数据面连接。半开场景靠新 SYN 复用同槽 (ADD
  覆盖) 自愈。超限释放不清 fast 是 P4b 设计决策 (PORT_NOTES 开工节)。

**观察项接受** (不阻塞 P4b-5):
- 看门狗复位不清 fast 侧 CAM/TCB — fast 数据面独立于慢路径, 清条目会
  断活连接; 慢路径复位后连接状态由后续 SYN/FIN/RST 重建。
- cfg FIFO 16 深 + gnt 长抢占的理论饥饿 (观察项, 正常流量不会)。
- FIN 即发 CFG_DEL: 对端 FIN 后的重传段 fast 侧 CAM miss 被丢, 依赖
  对端重传超时 — 协议边缘可接受。
- snd_wnd 用 SYN 原始 wnd 未乘 peer_wscale — fast 侧不按 snd_wnd 门控
  发送, 影响小。

## 2026-08-30 P4b-5 前发现: T_ESTABLISHED 的 FIN 分支是死代码 (已修)

乐观建连下第 3 个 ACK 走 fast path, HLS 永远停在 T_SYN_RCVD —
T_ESTABLISHED 的 FIN 分支 (FIN+ACK + CFG_DEL) 永不触发; 对端 FIN 到
T_SYN_RCVD 被静默忽略 → 无 FIN+ACK、fast 条目不清, PC 只能靠 RST 兜底
(close() 拖几秒), 重连前 fast 侧残留 ESTABLISHED。
修: T_SYN_RCVD 补 FIN 分支 — FIN+ACK (seq 是旧值, 对端因 out-of-window
多半丢弃, 无害) + **CFG_DEL 拆 fast 条目 (关键)** + T_LAST_ACK。
全链 tb 无 FIN 帧所以没抓到 — 教训: **单元/全链 tb 的刺激要覆盖握手后
关闭路径** (P4b-5 板测的连接循环天然覆盖, 先板测再回归也行)。

## 2026-08-30 P4b-5 板测: 连接循环第 4 轮超时 — 槽位耗尽 (已修)

**现象**: echo 测试连开连关, 1-3 轮全 PASS, 第 4 轮 connect 超时;
同时 ping 2/2 + UDP echo 100/100 正常 (慢路径活着, 仅 TCP 槽位问题)。

**根因链**: PC 每次 connect 用新临时端口 → 新 4 元组 → tcp_find 不匹配
旧槽 → 占新槽。FIN 后槽位进 T_LAST_ACK, 最后 ACK 走 fast path HLS 永远
收不到 → 槽位要等 4 个 RTO (10M pass ≈ 1.6s/档, 共 ~13s) 限次重传才
释放 → 三轮测试占死 MAX_TCP_CONN=3 全部槽, 第 4 轮无槽可用 SYN 被丢。

**修**: FIN 分支处理完 (FIN+ACK + CFG_DEL) 后**立即 T_FREE +
retrans_pending=false** — 最后 ACK 反正收不到, 等 T_LAST_ACK 无意义;
FIN+ACK 重传也无意义 (seq 是旧值, 对端 out-of-window 丢弃, PC close
靠 RST 兜底)。槽位即刻回收, 连接循环任意轮次可用。

## 2026-08-30 P4b-5 板测: 吞吐测试 2.6s 必死 — SYN+ACK 定时重传杀活连接 (已修)

**症状**: rate test 每次恰在 ~2.6s 挂 ConnectionResetError (WinError
10054); pktmon 抓包显示 PC 自己发的 RST。

**排障链**:
1. burst 复现 sim: 200×1460B 线速突发全回显零丢失, echo 帧距 1550
   拍 = 线速 (1526 拍/帧) — **fast 路径无结构问题**。
2. 抓包 (pktmon comp 102): PC 发送线程被 pktmon 自身 CPU 过载卡了
   310ms — 回显停顿是跟随 PC 输入, 非 FPGA 问题 (首次误判!); FPGA
   rcv_nxt 与 PC 发送完全吻合 = RX 零丢包; 1335 段全回显, 其余是 PC
   自己的重传 (按设计不回显)。
3. **不带 pktmon 仍 2.6s 必死** — 排除抓包因素后定位: RTO =
   10M pass ≈ 2.6s (@~32 拍/pass), SYN+ACK 定时重传正好打在**已建立**
   连接上 — Windows 收意外 SYN 直接 RST 杀连接。之前抓包没看到
   [S.] 重传帧是 pktmon 过载漏帧。
4. 教训: 抓包工具本身可能改变被测系统行为 (CPU 占用) — 先对照
   "无抓包复现"再下结论。

**修** (layer_tcp.cpp):
- T_SYN_RCVD 超时**不重传** — 直接释放半开槽位 (连接已建立时对端
  不会重发 SYN, 槽位释放不影响 fast 数据面; fast 条目保留)。
- SYN+ACK 丢失恢复改由**对端 SYN 重传驱动**: T_SYN_RCVD 的 re-SYN
  分支原样重发 (seq 不变, tcp_send 对 SYN 会 +1 故先退一拍)。
- T_LAST_ACK 保留限次重传 (FIN+ACK 路径)。

## 2026-08-30 P4b-5 板测 (续): 吞吐仍死 — 两个 fast 路径缺陷 (P4b-6 修)

修复 SYN+ACK 重传后, rate test 失败点从 2.65s 移到 ~19s, 但仍
ConnectionResetError。三次抓包 (pktmon) 逐层排除:

1. **PC NIC 零丢弃零错误** (Get-NetAdapterStatistics) — 线是干净的,
   丢的是 PC 栈层; pktmon 抓包自身会占 CPU 卡 PC 发送线程 310ms
   (首次误判"FPGA 回显停顿", 实为跟随 PC 输入)。
2. **burst sim (200×1460B 线速) 全绿**: echo 帧距 1550 拍 = 线速,
   fast 路径 RX/TX 结构无瓶颈。
3. **真缺陷 A — echo seq 空洞**: 抓包显示 echo #420→#421 之间 seq 跳
   1812 字节 (=1460+352), 空洞处恰是 PC 发送停顿 (~250ms) 后的
   恢复点。PC 栈等缺失字节 → ACK 冻结 → PC 发送窗口关死 → FPGA
   rcv_nxt 停 → 互相等待死锁 → PC 重传风暴 → ~19s RST。
   机制候选: tcp_tx_frame 的 pay_empty 提前收帧 (S_PAY 欠载防御) 或
   mac_tx_64 断供 runt — 帧没上线但 snd_nxt 照走 (upd 在 S_DONE 发)。
   需在 tb 里复现"帧间停顿后恢复"场景定位 (burst tb 加 PC 发送停顿)。
4. **真缺陷 B — 无 snd_wnd 门控**: fast 路径不查对端接收窗口就狂发
   (审查观察项 #6 当时判"影响小" — 板测推翻)。PC 接收侧一旦变慢
   (窗口关), FPGA 超窗狂发 → PC 栈丢弃超窗段 → 同上死锁。修:
   tcp_tx_frame 加窗口门控 (rb_snd_una + rb_snd_wnd, start_data 前查
   snd_nxt-snd_una < snd_wnd) + HLS cfg 记录传缩放后窗口 (peer_wscale,
   钳 16 位)。tb 的 burst 刺激需加反应式 ACK (PC 模型) 否则窗口
   门控会在 tb 里把 echo 卡死 (tb 无 ACK 回注)。

**P4b-6 清单**: 缺陷 A 定位+修 / 缺陷 B 窗口门控+tb PC 模型 / 重综合
+ 回归 + 板测复测。板测教训: 抓包先查 NIC 计数器, 再对照无抓包复现;
   sim 与板的差距往往在"对端行为"而非 FPGA 结构。


## 2026-08-30 施工截面 (compact 前快照) — P4b-6 开工状态

### 已提交 (943b2d9, ls-remote 验证)
P4b 正式握手全链 + P4b-5 板测三项修复 (FIN 即释放槽位 / RST 命中任一槽
补 DEL / SYN+ACK 定时重传废除改 SYN 驱动)。回归 17/17 绿 (测试 agent
验证)。板上: 连接循环 6/6 PASS, UDP echo 100/100, ping 2/2。

### 板上当前 bitstream
= 943b2d9 的 HLS (SYN 驱动重发 + FIN 即释放 + RST 扫描) + slow_cfg_adp
(rst_n 跟 hls_rst_n)。烧录 OK (DONE=HIGH)。吞吐仍死 (~19s RST)。

### P4b-6 待办 (按序)

**1. 缺陷 A — echo seq 空洞 1812B 定位**
- 现象: echo #420→#421 seq 跳 1812 (=1460+352), 在 PC 发送停顿 ~250ms
  后的恢复点; PC 栈等缺失字节 → ACK 冻结 → 双向死锁 → ~19s RST。
- 候选机制: tcp_tx_frame S_PAY 的 pay_empty 提前收帧 (欠载防御, 帧短
  但 snd_nxt 按 plen_r 全量走) 或 mac_tx_64 断供 runt (abort)。
- 方法: burst tb 的刺激加"停顿-恢复"段 (数据中间插 ~300k 拍空隙),
  看 sim 是否复现 echo 空洞; 加探针 (tcp_tx_frame 的 state/plen_r、
  mac_tx_64 stat_abort、u_echo fifo 水位)。run_tb_p4_burst.bat 已建。
- 注意: burst tb 无 ACK 回注, snd_una 永不前进 — 修缺陷 B 的窗口
  门控前, tb 必须加反应式 ACK (否则门控会卡死 echo, 期望值全错)。

**2. 缺陷 B — snd_wnd 门控**
- tcp_tx_frame: 加 rb_snd_una/rb_snd_wnd 输入口; start_data 与
  S_IDLE 的 s_axis_tready 门控加 `(rb_snd_nxt - rb_snd_una) < rb_snd_wnd`。
- HLS cfg 记录 w5 的 peer_wnd 改传缩放窗口: T_LISTEN 的 cfg_write 调用
  处用 `c.peer_window` (wnd<<peer_wscale, 已算好) 钳 16 位
  `(pw>0xFFFF)?0xFFFF:pw`。
- wrapper_p4.v + tb_p4_chain.v 接线 rb_snd_una/rb_snd_wnd (tcb 已有输出)。
- tb burst 反应式 PC 模型: 捕获 TX 帧尾 → 解析 echo seq+len →
  注入纯 ACK (seq = u_tcb.rcv_nxt_r[0], ack = echo end, sport 0x3039
  dport 0x1F90 flags 0x10 wnd 0x4000) 到 RX 流 (驱动 FSM 暂停静态流
  播注入帧); 常规 5 帧链 tb 不受影响 (echo 总量 36B < wnd 0x2000)。

**3. 验证链**: 重综合 (run_hls.bat) → 常规链 tb + burst tb (含停顿段
+ PC 模型) → build_p4.bat → run_program_p4.bat → 板测 (rate test
16MB + 连接循环 + UDP/ping)。

### 关键工具/文件 (已建)
- sim/p4sim/run_tb_p4_burst.bat (burst 200 生成+仿真+burstcheck)
- sim/p4sim_hlsprobe/run_hls_udp_probe.bat (HLS 孤立探针, 证 HLS 干净)
- tools/gen_stim_p4_chain.py: burst/burstcheck 模式; gap 语义=帧前间距!
- pktmon 配方: start --capture --comp 102 --file-name X.etl; etl2txt
  --verbose --hex; UTF-16 读; 抓包自身会占 CPU 干扰被测系统, 结论前
  必对照无抓包复现 + Get-NetAdapterStatistics (NIC 计数零丢弃是硬证据)。

### 板测环境
- PC NIC 192.168.100.1 (1G 全双工), FPGA 192.168.100.2:8080,
  MAC 00:0A:35:01:FE:C0; 静态 ARP 已配 (P4a 遗留, UDP 测试脚本输出
  提到 FE-C1 是过期文案, 实际 C0)。
- anaconda python: /c/Users/zhxue/anaconda3/python.exe

## 2026-08-30 P4b-6: snd_wnd 窗口门控全链 + PCACK TB 模型 (已 sim 全绿)

### 缺陷 A 结论性排查 (echo seq 空洞 1812B)
- **结构分析 + sim 双重否定**: tcp_tx_frame 整帧先入 256 深 pay FIFO 才开
  S_WAIT → S_PAY 欠载 (pay_empty 提前收帧) 结构不可达; mac_tx_64 断供
  abort 必留 runt → 板上 NIC 零错误计数排除。两路各加哨兵计数器
  (stat_eend / mac abort 进 STATS_MAC, tb 无条件监听, 变化即 $display)。
- **burst tb 停顿-恢复复现尝试**: burst 200 中段 (第 100 段改 352B 尾包 +
  后段前插 300k 拍停顿) → BURST OK, 202 echo seq 链连续无空洞。
  **FPGA 侧结构性丢帧排除; 板上空洞的最可能解释收敛为缺陷 B 本身**
  (PC 窗口关 → 超窗段被 Windows 栈层静默丢弃, NIC 计数不动, pktmon
  在自身 CPU 过载下漏帧 → 抓到的"空洞"实际是栈层丢弃)。
- 若板测复测仍有空洞, 哨兵会区分: stat_eend/abort 亮 = FPGA; 否则对端。

### 缺陷 B 修法 (窗口门控全链)
- **wscale 必须进 fast 路径** (否则对端 wscale=8 时 raw wnd 比真窗小 256x,
  门控把吞吐掐死): TCB 加第 7 字段 wscale (sel=6, 复位 0 = 不缩放,
  旧配置链语义不变); HLS cfg 记录 w0[19:16] 携带; slow_cfg_adp 写 7 字段
  (S_TCB_LAST 移到 idx=6 后); tcp_rx drain snd_wnd 时 `wnd<<wscale` 钳
  0xFFFF (echo 在飞 ≤ 我方通告 rcv_wnd 0x3000 << 64K, 钳位不影响语义)。
- tcp_tx_frame: 新口 rb_snd_una/rb_snd_wnd; `wnd_open = (snd_nxt-snd_una)
  < snd_wnd` (32 位减法回绕安全) 门控 start_data 与 S_IDLE tready;
  纯 ACK 不挡 (窗口探测/保活语义)。snd_wnd=0 (未配置槽) 天然禁发。
- HLS cfg_write: ADD 传 `min(peer_wnd<<peer_wscale, 0xFFFF)` 与 wscale;
  DEL 传 0。门控期间 tcp_echo 2048 深 frame_fifo 积压, 再满则背压至
  mac_rx 丢整帧 → 对端 TCP 重传恢复 (自然拥塞语义)。

### TB: PCACK 反应式 PC 模型 (tb_p4_chain.v, +PCACK)
- 捕获 conn0 echo 帧尾 (sport 1F90/dport 3039/flags 18/tlen>40) →
  RX 流帧间隙注入纯 ACK (60B, seq=rcv_nxt_r[0], ack=echo_end_seq,
  FCS 由 tb crc32b 函数现算, IP csum 恒定)。
- **坑 1 (实锤)**: 注入帧必须前缀 12 拍 IFG (dv=0) — 直接进前导会让
  mac_rx_64 收不到帧间间隙, 注入帧与静态前帧**融合成一帧** (帧身混入
  55 55 前导字节, pcount 超长 → S_DROP)。
- **坑 2**: 采样 rcv_nxt 须等前一帧 fend 的 TCB drain 落地 (实测最长
  fend+9 拍, tx/rx 仲裁排队) — gap_cnt≥11 个间隙字节才触发构建。
- echo_seen/inj_done 双计数器分属两个 always (单驱动铁律), 差值=待注入;
  inj_done<=echo_seen 一次覆盖 (累计 ACK 语义)。
- 静态 burst 段 wnd 参数化 (gen burst 第 4 参, hex); +PCWND1K 把注入
  ACK 的 wnd 压 0x1000 — 门控交战测试 (TCBF snd_wnd=4096 确认钳制,
  202 echo 仍全回无空洞)。

### 验证状态 (sim)
- run_tb_p4_chain (常规 9 帧全语义): P4 CHAIN OK
- burst 200 / burst 200+300k 停顿 / burst 200 wnd=1000: 三模式 BURST OK
  (202 echo 连续无空洞, abort=eend=0, STATS7 零丢)
- 回归 20/20 绿 (测试 agent); 审查 agent 结论: 放行 + 2 major 建议

### 审查处置 (2026-08-30)
- **M1 wscale≠0 零覆盖 → 已修**: p4 链 SYN 固定带 WS=2 选项 (gen
  mk_syn_ws, doff=6 [03 03 02 01])。HLS 解析 peer_wscale=2 → cfg 下发 →
  drain 缩放真实交战: 常规链 TCBF snd_wnd 期望改 0xFFFF (0x4000<<2 钳位),
  burst 门控交战变体改 raw wnd=0x400 (缩放后 0x1000, TCBF=4096 确认)。
  全链 (chain + burst×3) 复跑全绿。
- **M2 移位截断 → 已修**: tcp_rx 缩放改 32 位扩展再钳 (原 24 位在
  wscale≥9 会回绕成 0 → 锁死; 原被 HLS ws<=7 软钳挡住, 现 RTL 自防守)。
- m3 (tcb sel=7 落入 wscale) → 已修: sel=6 显式, default 空操作拒写。
- m4 (state 先于 wscale 落地, 瞬态按 wscale=0 缩放 → 窗口偏小) → 接受:
  保守方向, 下一帧 drain 自愈, 不改写字段序。
- m5 (门控使背压成常态: 对端关窗 → tcp_echo 积压 → mac_rx 丢整帧 →
  对端重传簇) → 记录为**预期行为**, 板测抓包看到重传簇不是丢帧 bug。
- n1 (注入帧 dst MAC C0 vs gen_stim_tcp_chain 的 C1) → 误报: P4 统一
  MAC 就是 C0 (gen_stim_p4_chain 覆盖了库默认); n2 (inj 构建代码重复)
  → TB 代码从简, 不抽。

### 板测复测清单 (P4b-6b)
build_p4.bat → run_program_p4.bat → rate test 16MB (重点: 原 ~19s RST
点) + 连接循环 6 轮 + UDP 100 + ping。若 rate test 再挂: 查 STATS 哨兵
(需要 ILA 或 LED 暴露 stat_eend/mac abort — 暂未接线, 复测失败再加)。

## 2026-08-30 P4b-6 板测: 速率测试仍死 — pktmon pcapng 抓包实锤根因 (wscale 钳位)

### 症状 (修复前, 每次可复现)
- rate test: **恰 t=18.95s RST, sent=1.00MB, echo=0.01MB** (确定性)。
- 失败后板子**永久僵死** (UDP/ping/TCP connect 全超时) — 只能重烧恢复。
- NIC 零错误零丢弃 (线干净); 链路 1G。

### 抓包还原 (pktmon --comp 102 → pktmon pcapng → python 解析)
1. Windows SYN: **WS=8** (12B 选项), wnd raw 65535。
2. 3rd ACK wnd raw=**255** (→65280 有效); 后续数据帧 wnd raw=**4096**
   (→1MB 有效, Windows 自动调窗)。数据段 flags=0x10 (无 PSH!), L=1460。
3. FPGA 只回了 7 个 echo 后 TX 静默; RX 收到第 17 段后 rcv_nxt 冻结
   (第 18 段起全被上游拥塞丢弃); PC 重传第 18 段 (0.070/0.130/0.252/
   0.492s) 全部无应答 → 300ms×2^n 退避 6 次 ≈18.9s → RST。
4. 0.62s 起 PC 发 ARP 请求无应答 (慢路径 RX 也死了) — RX 拥塞在
   rx_classify 共享入口, 两条路一起饿死。

### 根因链 (两层)
1. **触发**: HLS SYN 解析 `peer_wscale=(ws<=7)?ws:0` — **Windows 的 ws=8
   被钳成 0** → fast 路径 drain 从不缩放 → snd_wnd = Windows 的**原始**
   窗口 4096 (wscale=8 时真窗 = raw×256)。门控按 4096 字节执行:
   7 个 echo 后 in_flight=4380 ≥ 4096 → 门控永久关闭。
2. **放大成死锁**: echo 停了 → tcp_echo 管道 (~17KB = 11 帧) 被 10 帧
   未回显数据塞满 → tcp_rx 停收 → rx_classify 共享输入拥塞 → **PC 的
   ACK 和重传全部进不来** (ACK 是重开门控的唯一钥匙) → snd_una 冻结
   → 死锁; 连 SYN/ARP 也进不来 → 板子僵死只能重烧。

### 修 (layer_tcp.cpp)
- **wscale 钳位 7→14** (RFC 7323 上限; cfg w0[19:16] 4 位装得下)。
  修后 snd_wnd = 4096<<8 = 1M → 钳 0xFFFF = 64KB 门控, 正常锯齿。
- **SYN+ACK 不再通告 WS** (our_wscale 7→0, 选项只剩 MSS+2NOP, doff
  7→6): 我方 rcv_wnd 0x3000 (12KB) 不被对端缩放成 1.5MB — PC 在飞
  ≤12KB < echo 管道容量 17KB → **门控即使真关闭, PC 的纯 ACK 也能
  穿过管道重开门控, 结构性防死锁**。
- 12KB/0.05ms RTT ≈ 240MB/s > 1G 线速, 吞吐不受影响。

### TB 镜像 Windows (防再犯)
- SYN_WSCALE 2→**8** (旧钳位下此值会让 sim 复现死锁 — 板测教训入 sim);
- check_synack doff 期望 7→6; 门控交战变体 raw wnd 0x0400→**0x10**
  (×256 = 4096 有效)。

### 方法论沉淀
- pktmon 抓包 recipe 升级: **`pktmon start --capture --comp 102` →
  `pktmon stop` → `pktmon pcapng X.etl -o X.pcapng`** (etl2txt 只出流
  摘要无包字节; pcapng 直转最稳) → python 手写 pcapng 解析 (~50 行)。
- 抓包必须在**干净板子**上做 (RST 失败后板子僵死, 抓到的只有超时);
  先跑轻载测试确认恢复再抓。
- 板测复测铁律: 失败后先重烧, 否则后续所有测试都是僵尸板噪声。

## 2026-08-30 P4b-6 板测 (续): 修后 sim 复现新死锁 — HLS 延迟处理路径 cfg 谓词死锁

### 症状
wscale 钳位 + SYN+ACK 去 WS 修复后, 链 tb 全挂: **HLS 收 SYN 后不发
SYN+ACK、不出 cfg 记录, 且之后所有慢路径帧 (arp2) 不再应答** — HLS
主循环卡死 (top FSM 停在 state41, mac_rx 状态机冻结在 IDLE)。

### 定位链 (TB 窥探 HLS 生成 RTL 内部寄存器)
1. TB 加探针 `u_hls.grp_mac_rx_process_fu_1620.state_1` (mac_rx 状态机):
   arp/icmp/udp 正常 0→1→2→4→0; **SYN 帧完整收完 (st→0 后再无变化)**,
   regslice 吞了 2 个前导字节后停 — 子函数没被调用。
2. top FSM 卡在 **ap_CS_fsm_state41** — 查生成 RTL:
   `ap_block_state41_on_subcall_done = (tcp_rx_process_ap_done==0 &
   predicate)` — **卡在延迟 tcp_rx_process 子调用上**。
3. `ap_predicate_op325_call_state41 = (tx_req_request==0 & !mac_tx_busy)`
   — 延迟调用 + **cfg_stream 接受**都以 `tx_req.request==0` 为谓词;
   而 tcp_rx_process 内 `tcp_send(SYN+ACK)` 先置 request=1 → **谓词
   死亡 → cfg 写入永不被接受 → 子调用永不返回 → 顶层永久卡死**。
4. 触发条件: SYN 的 do_process 落在 UDP echo 的 MAC 忙窗口内 → 走
   延迟路径 (直调路径的 cfg 接受在 state19, 无谓词, 所以旧时序下
   从未炸)。新 HLS 综合时序变化 + 新 SYN 帧长变化让 SYN 恰好落入
   忙窗口 — **潜伏死锁首次被踩中** (板级 connect 超时同根因)。

### 修 (layer_tcp.cpp)
- **cfg 先于 tcp_send** (三处: T_LISTEN ADD / T_SYN_RCVD FIN / 
  T_ESTABLISHED FIN): cfg 在 request 置位前流完, 谓词存活;
  T_LISTEN 的 w7 显式 `c.seq+1` (SYN+ACK 稍后才推进)。
- TCP_MAX_HDR 28→24 (doff=6 只剩 MSS 选项; 原 28 会让 total/csum
  覆盖 4 字节幽灵数据 — 与 doff=6 失配, 顺手修)。
- tcp_build_hdr 删掉 NOP 写入 (4B MSS 恰满 24B 头)。

### 验证
链 tb (WS=2/WS=8) + burst 三变体全绿; 门控交战变体 raw=0x10 →
snd_wnd=4096 生效。板级重建中。

## 2026-08-30 P4b-6 板测终局: 抓包重放定位缺陷 A 为线级丢帧

### 数据 (pktmon --pkt-size 0 完整抓包, 三次板测)
- 修复后: sent 1.0MB/1.56MB/1.81MB, echo 0.01/0.51/0.78MB (递增 —
  每次重烧后起点不同, 但都在首次窗口周期出现 **同型空洞**后 19s RST)。
- 空洞: 5094/608 echo 中恰 1 处, **seq 跳 1812 = 1460+352**; PC 栈
  ACK 冻在空洞首字节 → dup-ACK 风暴 → 门控打满 → PC 6×RTO 退避
  (~19s, 300ms×2^n) → FIN+RST。
- 空洞时刻的完整交换: PC 重传 (RTO) → FPGA 接受并回 echo + 纯 ACK/
  echo 同 seq 交替 (ackresp 路径正常) → **两个 echo (1460B+352B)
  消失: FPGA snd_nxt 走了 1812, PC 网卡零收到零错误**。

### 重放排障 (决定性)
- pktmon 默认 snaplen=128B (首轮抓包全截断 — 教训!); --pkt-size 0
  重抓 1514B 全帧。
- gen replay 模式: pcapng 帧重定基 (seq/ack/端口) + IP csum 重算
  (NIC 卸载导致抓包 csum 无效) + 间隙压缩; tb 数组 1M→4M。
- **557 帧精确重放 → sim 429 echo 零空洞** — fast 路径 RTL 在板级
  精确帧序列下干净。

### 结论与遗留
- 缺陷 A = **线级/PHY 侧丢帧**: 2 个 echo 帧在 FPGA TX 与 PC 网卡
  之间消失 (NIC 零 CRC 错误 = 帧未以坏帧形式到达, 而是完全消失);
  候选: FPGA TX MAC 起点丢弃 / RGMII-PHY / tx_arb 慢路径锁死 —
  板上哨兵 (stat_eend/mac abort) 未接线, 需 ILA 或 LED 接线指认。
- **fast 路径无重传逻辑** — 空洞无法自愈 (PC 等缺失 echo 字节
  永不到达) → 任何线级丢帧都致命。P4b-7 候选: fast 路径 seq 重传
  (dup-ACK 触发) 或 echo 应用层重传。
- 板测方法论沉淀: pktmon --pkt-size 0 必带; 抓包帧 IP csum 因
  NIC 卸载无效需重算; 每次 RST 后板子僵死必须重烧; 重放 = 区分
  "RTL 缺陷" 与 "物理链路问题" 的决定性手段。
