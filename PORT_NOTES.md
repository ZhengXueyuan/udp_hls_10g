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

## 2026-09-05 P4b-7 开工 (fast 路径快速重传: dup-ACK + RTO) — P1/P2 完成

### 目标与方案 (用户拍板: 继续 P4 自愈; DDR 暂不用, BRAM ring 够 12KB 窗口)
- **retx_ram.v**: 16 conn × 16KB ring, 偶/奇字双 bank (跨字写每 bank 每拍至多
  1 写), 8 字节写使能, 1 拍读延迟漏斗 `(W_w<<8o)|(W_{w+1}>>8(8-o))`。
  移位方向血案: 计划文档 w+1 字写 "<<8(8-o)" 被我当 typo 改成 ">>", 单元 TB
  字节级参考模型穷举证明 **原方向 (左移) 才对** — agent 用 TB 证伪了我的
  "修正"。教训: lane 数学必须穷举 TB 仲裁, 人工推导两次都出过号。
- **tcp_tx_frame**: RING_CAP=0x3000 门控帽 (对端窗口可 64KB > ring!); S_IDLE
  仲裁链 ack > svc > ring_eval > scan > data; svc 拍回卷 snd_nxt<=snd_una 走
  原 TCB 写口 (tx 优先天然成立); S_RING 2 级流水读 ring 写 u_fifo (共用
  checksum16); RTO 扫描器 16 连接 × 21bit 计时 (781250 次访问 ≈ 100ms)。
- **组合环规避**: scan_now 仅依赖 !s_axis_tvalid (不得依赖 start_data/wnd_open,
  否则 rb_id mux 与 wnd_open 成环震荡)。门关+数据展示时无扫描 = 已接受局限
  (板级 1MB 有效窗门不关; sim 尾丢激励耗尽 tvalid=0)。
- **P2 三处规格修正 (实现 agent 提, TL 复核认可)**: tap_seq 首拍即 +pop8
  (我原规格差一拍); ring_seq 锁存 = snd_nxt+8 (首读在 ring_start 拍);
  s_axis_tready 加 !svc (svc 拍 accept 必须禁, 防吞帧首字)。
- **bat 约定修正**: `burst N 0 0 wnd` 的 0 0 被 gen_stim 当 pause_len=0 →
  帧融合塌缩 (基线发现); 现 `%2==0&&%3==0` = 无暂停 (等价 -1 0)。
- **TL 巡检实绩**: P1 agent 输出超限 (32k token) 未落盘 → 换新 agent 带防爆
  纪律重派; P2 agent 基线先行发现 harness bug 并停手请示 → 批准后完成。
  P3 agent 首轮 13 次调用全读无写超限 → 同法重派。

### P4b-7 P3 完成 (dup-ACK 快速重传全链, 6 门 TL 独立复跑全绿)

- **tcp_rx**: dup-ACK 判据 = 纯 ACK 且 ack==snd_una 且有在飞 (排除空闲窗口探测);
  w5->w6 沿锁存 (同 ack_adv_l), fend+FCS 好拍计数; 每连接 2bit 计数 + in_retx
  位; 第 3 个 dup -> retx_req 电平保持至 retx_gnt; retx_req 忙时其他连接计数
  停在 2 等待; gnt/真推进 ACK 双路径解锁。
- **TB PCACK exp_seq 模型**: 首帧建序 / 顺序推进 / OOO 每个恰好 1 个 dup
  (ack=exp_seq, Windows 行为) / 全重包也回 dup。
- **TXDROP 故障注入**: **-testplusarg TXDROP=N 被 xsim loader 拆碎 '=' 到不了
  TB** -> 改 txdrop.memh 文件通道 ($fscanf)。丢窗两阶段: N 帧 start_data 武装,
  mac S_PRE 开窗, S_IFG 关窗 — **S_IFG 不能撤武装** (mac TX FIFO 16 深背压下
  上一帧 S_IFG 抢在目标帧 S_PRE 之前, 提前撤武装丢帧落空, 实测抓到)。
  监视侧 gmii_tx_en_mon 屏蔽, DUT/mac_stat_frames 无感 (对账用)。
- **burstcheck 重传容错**: 区间并集覆盖检查 (OOO 原发帧先于回卷修复帧上线,
  顺序 merge 会误判洞, 实测抓到); RETX == 会话数 (相邻双丢 = 1 会话)。
- **tcp_echo FIFO 加宽 2048->4096** (真根因, 故障注入暴露): 重传会话期间
  tcp_tx_frame 只喂 ring 不接新帧 -> 回声管道饿死, 而 PC 滑动窗口持续发送
  (rcv_wnd 通告恒定) -> FIFO 累积; 双会话背靠背超 2048 字 -> **丢 1 个 PC 数据帧
  -> 永久空洞 (该帧 echo 从未发送, ring 无此数据, 重传救不了)**。4096 字
  (=32KB) 覆盖双会话+12KB 常驻。结构性极限 = 常驻 12KB + 每会话 ~2.6KB,
  ~7 会话余量; 极端情况仍会溢 -> 后续加固候选: echo FIFO 满时延迟 tcp_rx ACK
  (窗口闭合式背压), 本轮不做。
- **TL 修补**: chain/probe bat 开头清 txdrop.memh (burst 中途被杀残留文件会
  污染无注入门)。
- **RTO_LIM 未压缩的原因 (agent 决策, TL 认可)**: chain 场景无 conn0/1 ACK 模型,
  压缩到 2000 会在 60k 尾窗内 RTO 风暴破 chain 门; P4 用 `ifdef RTOLIM_FAST`
  + burst 激励补 conn1 累计 ACK 解决。

### P4b-7 P4 完成 (RTO 兜底验证, 7+1 门 TL 独立复跑全绿)

- **机制**: 扫描器每 scan_now 拍访 1 连接; 计时 0->装 RTO_LIM / 1->置未决重装 /
  否则自减; 未决走同一 svc 回卷路径 (每次回卷重装 timer = 双丢自愈)。
- **sim 压缩通道**: `ifdef RTOLIM_FAST defparam u_tx.RTO_LIM=2000` (TB 内),
  burst bat 的 TB xvlog 行加 `-d RTOLIM_FAST`; chain/probe bat 不加
  (chain 无对端 ACK 模型, 压缩会在尾窗 RTO 风暴破门)。
- **conn1 20B 永久未确认问题**: PCACK 只建模 conn0 -> 压缩 RTO_LIM 后 conn1
  RTO 风暴 (+RETX 破所有 burst 门)。修: burst 刺激在 c1data20 后加 c1ack 纯
  ACK (seq=97, ack=920, 1500 拍间隙 ≫ echo ~300 拍延迟), snd_una 追平 920。
  **教训: 仿真模型只覆盖一个连接 = 陷阱, 真实对端 ACK 所有连接**。
- **TL 预判失误修正**: 我原以为 segment-3 位置安全 (echo 应已发出), agent 实测
  snd_nxt 仍 900 被拒 -> c1ack 紧贴 c1data20 + 1500 拍间隙。信任门禁而非我
  的时序心算。
- **门结果**: TXDROP=202 纯尾丢 (0 dup) RTO 自愈 RETX=1; TXDROP=200 (2 dup
  不足) RTO 自愈 RETX=1; TXDROP=199 (3 dup) 快速重传自愈; P3 全门在
  RTOLIM_FAST+c1ack 下复绿。

### P4b-7 P5 审查+测试轮 (agent 工作流, 结论与裁决)

- **审查 agent: 无 SEV1 数据损坏**。ring 溢出数学/写拍点对齐/S_RING 帧化/
  svc 互斥/dup 计数组态全部复核干净。
- **SEV2-1 (修)**: RTO 无限重放无退避 — 每连接无进展 epoch 计数, 16 会话后
  停回卷 (svc 仍应答释放), 进展即复位。
- **SEV2-2 (修)**: 门关+tvalid 时扫描饿死 (比原注释更广的僵局: 丢帧+对端静默+
  在飞钉死 RING_CAP+app 持续展示) — force_scan: 阻塞 16 拍后强制扫 1 拍
  (register 破组合环; start_data/s_axis_tready 必须加 !scan_now, 否则
  rb_id 指 scan_id 时吞帧首字+ring 写错游标)。
- **SEV2-3 (修)**: 真推进 ACK 只清 in_retx 不清 retx_req — 迟到的 svc 会无谓
  重放至多 12KB 重复数据; 修: ack_adv 且同连接时取消挂起请求。
- **SEV3-4 (删)**: 扫描器 retx_active 排除条件死代码 (ring_eval 覆盖全部
  S_IDLE&&!ack_pend)。
- **SEV3-5 (不改, 记档)**: 窗口更新/探测纯 ACK 计 dup — 与 Linux dupthresh
  语义一致 (任何不推进 snd_una 的 ACK 都是 dup), 3 次触发重传是标准行为。
- **SEV3-6 (记档后续)**: S_RING 尾拍 rem 只被 {0,4} 覆盖 (激励 plen 集合全
  ≡0 mod 4, 会话尾帧 rem 恒 0/4); rem∈{1..7}/小会话需要向 TB (P4b-7-hardening);
  c1ack 的 1500 拍间隙对 conn0 重传会话延迟 conn1 echo 的情况时序脆 (无害
  但依赖时序)。
- **测试 agent: 14/16 通过**。TXDROP=1 首帧丢失探针证实 TB 模型缺陷 (exp_seen
  首帧建序把第二帧当首帧, 累计 ACK 跳过空洞 -> 7B 永久头洞, RETX=0) —
  **真实对端从握手起就知道期望 seq**, 模型修复 = exp_seq 静态初始化为
  tcbc snd_nxt+1。xvlog_wp4b.bat 用陈旧 hls_files_new.f (缺 8 个 HLS 文件)
  且无错误传播 — bat 修复。

### P4b-7 P5 第二轮: retx_ram 读漏斗一拍偏斜 (重大发现)

- **真 bug**: retx_ram 读漏斗的选择 (r_seq[3:0]) 是组合信号, 而 q_e/q_o 数据是
  rd_en 前一拍的寄存器 — S_RING 逐拍推进地址时, 当拍漏斗用"新地址的偏移/奇偶"
  选"旧地址的数据" -> 每两拍错一个 bank, ring 重发帧载荷是垃圾。
- **为什么所有门都放行了**: 单元 TB 采样拍 r_seq 保持不变 (漏测背靠背推进);
  burstcheck 只查 seq 覆盖 + RETX, **从不校验载荷字节** — seq 头字段与载荷
  独立计算, 坏载荷完全隐身。**铁律: 覆盖检查 ≠ 数据检查; 重传路径必须做
  字节级比对** (板级 pc_tcp_rate_test 会抓, 但 sim 里就该抓)。
- **修**: r_sel 随 rd_en 寄存器化 (r_sel <= r_seq[3:0]), 选择与数据同源。
- **补测**: tb_retx_ram 新组 G (流式背靠背读, 逐拍推进地址) — 旧代码必挂;
  burstcheck 加 payload_map.json 侧车: 生成器记录每个 conn0 数据段的
  echo seq -> 载荷字节, 检查器对每个捕获 echo (含重发帧) 逐字节比对。

### P4b-7 P6: 板级构建时序失败 + frame_fifo 拆分修复

- **P6 首建 WNS=-3.07ns 未收敛** (bitstream 照常产出但板级不可用)。最差路径:
  `u_tcp_echo/u_fifo` wptr[4] -> dout_r[19], 读指针网扇出 35473 — frame_fifo
  4096x73 落 LUTRAM 12 级读 mux 链。
- **根因**: 73 位宽超过 BRAM36 的 72 位上限, W=73 不可能推断 BRAM。P3 加宽
  2048->4096 时 mux 链从 11 级变 12 级, 125MHz 下从"无碍"变"炸" — 
  **深度加宽前必须先确认 BRAM 推断, 否则 LUTRAM 深度翻倍 = 时序翻车**。
- **修**: frame_fifo.v 内部拆 64+9 双阵列 (主 4096x64 = 8 BRAM36, 侧 4096x9 =
  BRAM18; 接口/FWFT/bypass/snap/rollback 语义不变), 全部 4 个 W=73 例化点
  (tcp_echo 4096 / slow_rx_adp·slow_tx_adp 512 / udp_echo 2048) 受益。

### P6 时序二次破案: 拆分无效, 根因 = FWFT bypass mux 阻断 BRAM 推断

- **拆分后重建仍 WNS=-2.9ns**。合成报告实锤: retx_ram 成功推断 64xRAMB36,
  但 frame_fifo 的 mem_m/mem_s 仍落 `RAM64M x 1408` (LUTRAM) — 拆 64+9 不
  解决, 宽度不是根因。
- **真根因**: `dout_r <= bypass ? din : mem[rptr_n]` — FWFT 首字直通的 bypass
  mux 挡在寄存器前, Vivado 的 BRAM 推断规则要求 mem 输出直连寄存器。
  纯 RTL 写不出"碰撞拍读回新数据"的 write-first 语义 (非阻塞读必回旧值),
  bypass mux 是语义必需 → **纯 RTL FWFT 与 BRAM 推断结构性矛盾**。
- **修 (进行中)**: frame_fifo 内改用 RAMB36E1 (主 64b) + RAMB18E1 (侧 9b)
  原语直例化 (WRITE_FIRST, SDP, REGCEB=1, NB=D/512 bank 译码 + NB:1 读出 mux);
  dout_r 寄存器改 wire (原语内部输出寄存器已提供 1 拍读延迟);
  指针/bypass/snap/rollback 逻辑零改动。unisim 模型自带 write-first 语义 →
  sim == 板级。配套 tb_frame_fifo 单元 TB 证 FWFT 时序字节级全等。

### P6 时序第三次破案: 原语修复后 WNS -3.07 -> -1.41, 新最差路径 = svc 优先编码链

- **原语版重建**: LUTRAM 9401->1561, BRAM 97.5->112.5 瓦, WNS 大幅改善但仍
  -1.41ns。新最差路径: rto_pend[2] -> retx_ram 写口 DIADI/WEA。
- **根因**: P4b-7 给 rb_id 复用加了 svc 来源: rto_pend -> prio_lo (16 入优先
  编码 ~5 级) -> svc_id -> TCB 读 mux -> rb_snd_nxt -> w_tap_seq 位选 ->
  retx_ram 写数据选择 (d_e/d_o by seq[3]) — 全组合链 ~14 级 + 时钟树偏移
  (SCD-DCD 0.7ns)。P4b-7 之前 rb_id 只有 start_id/cur_id 两源, 无此链。
- **修**: svc_id 优先级编码寄存器化 (svc_id_r <= retx_req ? retx_id :
  prio_lo(rto_pend), 每拍刷新)。语义安全: rto_pend 在扫描拍置位、下拍 svc
  消费, 1 拍旧值恰为正确连接; retx_req 电平 + retx_id 稳定亦无竞态。
  rb_id 全部选择源 (svc_id_r/retx_id_r/scan_id/start_id/cur_id) 均寄存器
  或稳定信号, 组合链断。

### P6 时序第四次破案: tvalid -> scan_now -> rb_id 前向链 (结构性修复)

- **svc_id_r 修复后仍 WNS=-1.6ns**, 新最差路径全貌: tcp_echo wptr -> empty_n
  (carry) -> m_axis_tvalid -> scan_now (P4b-7 为破组合环而依赖 tvalid!) ->
  rb_id mux -> TCB 读口 -> rb_snd_nxt -> wnd 比较 (carry) -> tready/start_data
  -> accept -> retx_ram WEA/ADDR — 19 级逻辑、7 个 CARRY4、布线占 78%
  (跨 tcp_echo/tcp_tx/retx_ram 三模块散射)。
- **结构性修复**: scan_now 改自由运行 tick 驱动 (scan_tick = tick_cnt==15,
  tick_cnt 每拍自增) — 与 tvalid 零组合关系, 前向链断; force_scan/block_cnt/
  data_blocked 机制整体删除 (tick 天然覆盖门关+展示的饿死场景)。帧间 S_IDLE
  撞 tick ~1/16 帧 (~0.3% 吞吐)。
- **RTO_LIM 重标定**: tick 把访问速率再降 16 倍 (scan_id 轮转本已 /16),
  RTO = RTO_LIM x 256 拍。默认 781250->48828 (12.5M 拍 ≈ 100ms 不变);
  RTOLIM_FAST 2000->125 (32k 拍, 尾窗内)。TXDROP=202 首跑 RETX=0 实锤
  旧值超窗 (512k 拍), 重标定后复绿。

### P6 时序攻坚战 (第五/六轮): 长尾 = rb_id -> TCB -> wnd 比较 -> accept -> retx 写口

- **逐源消杀的教训**: svc_id_r (杀 rto_pend 源) -> scan_tick (杀 tvalid 源) ->
  rto_pend_any (杀 |rto_pend 选择位) -> ack_pend_r (杀 ackq wptr 源) + wnd 16 位化
  — 每轮杀掉当前最差源后, 下一个源浮现: 所有经 rb_id mux 进 TCB 读口再穿
  wnd 比较到达 retx_ram 写口的路径同尾。**逐源打地鼠到不了头, 必须砍尾巴**。
- **决定性修复 (进行中)**: tcb 加第三个寄存器化"窗口读口" (win_id 地址,
  内部完成 16 位减法 + 高位比较 + RING_CAP 钳位, 输出全寄存器) — 门控
  wnd_open = win_hi_eq && (win_inflight < win_wnd_eff) 只吃寄存器, 尾部
  4 级 CARRY 比较即到 WEA。
- **RING_CAP 0x3000 -> 0x2FFE**: 寄存器滞后 1 拍在连接切换拍可能误开门,
  最坏实际在飞 <= (0x2FFE-1) + plen_max 4095 = 16380 < 16384 ring 容量 —
  硬上界依然成立 (1 拍滞后 + 每连接切换至多 1 次误开, 论证见注释)。
- 保留 16 位化时发现的 4GB 回绕边角 (高半差 1 误关门, ACK 过界自愈) —
  寄存器化窗口口下高半比较也入寄存器, 边角语义相同。

### P6 板测冻结取证 (时序收敛后的新故障, 与缺陷 A 不同)

- **症状四联征** (p4b7_syn.pcapng 取证): ①~30ms 健康全双工后 (echo/ack 全对)
  t=874 静默 — FPGA 停止一切 TX (echo+纯 ACK); ②rcv_nxt 冻结 (PC 后续数据
  不响应不 ACK, PC 窗口 12KB 填满停发); ③100ms 后 RTO 回卷重发 3 帧 —
  TX 侧活着 (ring 帧不经 RX); ④PC 的 piggyback ack=305858505 (=snd_nxt,
  合法) 被拒 → snd_una 永停 305854125 → RTO 每 100ms 无限循环。
- **关键矛盾**: 重发帧 S_DONE 应把 snd_nxt 推回 305858505 → ack_ok=(4380<=4380)
  应过 → snd_una 应推进。板上被拒 → 要么 S_DONE 的 TCB 写没落地, 要么
  RX 侧 fend/drain 停摆。sim 全门绿 (PCACK 纯 ACK 12-IFG 间隙注入, 从未
  覆盖"全速 piggyback-ack 数据流")。
- **排查进行中**: 板级抓包重放进 sim (复用 P4b-6 replay 设施) — sim 可复现
  则 sim 级快速定位; 不可复现则指向综合/原语级板-模差异 (frame_fifo
  BRAM 配置/tcb win 口综合)。

### P6 板测冻结: 重放诊断结论 + LED 探针部署

- **重放诊断 (agent)**: 板级 PC→FPGA 全流 (414 帧) 重放进 sim — **不复现**,
  sim 全量回显并接受板上被拒的 ack → 板-模分歧 (board-only)。变体 (b)
  (ack 常量) 在 sim 复现了死锁级联结构: 门关 -> TX 停 -> echo FIFO 满 ->
  tcp_rx 帧中部 stall — **级联机制本身在 RTL 里存在**, 但板的触发前提
  (在飞仅 4380, 门应开) 与 (b) 不同 — 怀疑 win 口寄存器值在板上出错。
- **板冻结与 echo FIFO 98% 满精确重合** (32120B 缺口 / 32768B 容量)。
- **LED 探针部署中** (4 LED): wnd_open / echo fifo_full / s_axis_tready /
  pay_full — 冻结是持久可复现的, LED 直接读冻结时刻状态。
  决策树: wnd_open=0 → win 口/门控理论 (下一步探 win 三值);
  wnd_open=1+fifo_full=1 → FIFO 死锁 (原语级); wnd_open=1+fifo_full=0
  → tcp_tx_frame 或 RX 上游卡死。

### P6 冻结诊断: sim 门控失配探测器结论

- **失配 ~5000 拍/run, 99.85% 误关, 全部 1 拍瞬态** (runmax=1) — 模式
  win=(1 0 0) fresh=(1 1460 12286): 扫描跨未配置连接采样的固有闪烁。
  阻塞帧启动仅 28/9 次且各 1 拍 (无害)。**持续性关门无法由 win 口注册
  逻辑产生** — 板的冻结需要 board-only 触发器。
- **frame_fifo 碰撞路径穷举验证干净**: 碰撞条件 (rptr_n==wptr && wr_ok)
  与 bypass 条件恒等 → 每碰撞必被 bypass_r 掩蔽, 模型 X 与硅片 write-first
  新数据都在掩蔽下一致 — 原语碰撞不是嫌疑。
- **板级闩锁探针部署中**: 看门狗 (sready 无活数据 1.07s) 锁存冻结时刻
  wnd_open / win_hi_eq / (win_wnd_eff==0) / (win_inflight>=win_wnd_eff)
  四值, LED 显示锁存值 (稳定可读)。RTO 重发不拉 sready 不误复位。

### P6 冻结: 时序余量理论 (头号嫌疑)

- **最紧路径余量 8-63ps** (P4b-6 时代有余量, P4b-7 推到悬崖): 
  `tcp_echo/u_fifo RAMB36E1 CLKA -> tcp_tx/u_csum/acc_reg` — 16 级 7 CARRY,
  活跃回显每帧必走; 侧存 RAMB18E1 的 **tkeep/tlast 位同路径** (0.028ns)。
- **冻结机制推演**: 真实硅片温度/电压下 8ps 余量翻转 — tlast/tkeep 位错 →
  tcp_tx_frame 帧边界错判 → S_RECV 永不见 tlast / 非法状态 → 永久卡死。
  解释全部证据: 确定性 (特定数据模式 ~98% 占用)、板级独有 (sim 无时序)、
  LED 读数自相矛盾 (FSM 状态被破坏 = 任意信号组合)、RTO 环 (TX 部分功能
  活着)。
- **修复方案**: ①tcp_echo->tcp_tx_frame 之间插 1 拍全速流水寄存器
  (axis_pipe, m_valid 寄存器化, s_ready=m_ready||!m_valid, presenting
  契约由寄存器自然满足) — BRAM 出口路径终止于流水寄存器; ②S_RING 读
  两级化 (r_data 再寄存器一拍, 校验和路径劈开)。目标 WNS 恢复到 ~1ns+。

### P6 冻结: 闪烁探针决定性读数 → 时序理论确认

- **闪烁编码 1 次 = 锁存值 0000** (首次 RTO 回卷时刻): {wnd_open=0,
  win_hi_eq=0, wnd_eff≠0, inflight<eff} — 门关的直接原因是 **win_hi_eq=0**,
  而冻结时刻真实 snd_nxt/snd_una 高半字节明明相等 (0x123A/0x123A) →
  **win 寄存器捕获了损坏值** — 与 8-63ps 边际余量下 TCB 写/win 读路径
  翻转的时序理论完全吻合。所有矛盾读数 (sready=1∧pay_full=1 不可能组合)
  亦由"FSM 状态被破坏"统一解释。
- **修复实施中**: ①axis_pipe 1 拍全速流水寄存器插在 tcp_echo→tcp_tx_frame
  之间 (劈开 BRAM 出口→校验和累加器 16 级关键路径); ②S_RING 读两级化
  (ring_d_r, 劈开 retx_ram 出口→累加器 18 级路径)。目标 WNS ≥0.5ns。

### P6 冻结: 时序理论排除 → win_hi_eq=0 是逻辑级板-模差异

- **余量修复后 (WNS 8ps→361ns, axis_pipe + S_RING 两级化) 冻结依旧, 闪烁
  码仍 1 = 0000**: {wnd=0, hieq=0, eff≠0, infge<eff} — hi_eq=0 稳定可复现,
  非时序翻转, 是确定性逻辑级差异。
- **矛盾核心**: 板级已知连接 (conn0: 0x123AE2C9/0x123AD1AD, 高半相同;
  conn1..15: 0/0) 任何连接都无法产生 hi_eq=0 — win 寄存器捕获的值在
  任何合法 TCB 状态下不存在 → tcb win 口或 TCB 阵列本身在硅片上与 sim
  语义分歧 (疑: 多读口阵列综合实现 / 时钟化读与写口时序 / HLS cfg 写
  了 sim 不存在的值)。
- **下一轮: UART 全精度读出** (板载 CH340, 9600-8N1) — 冻结时刻一次性
  发送 conn0 的 snd_nxt/snd_una/snd_wnd/wscale/state + win 三值 +
  tx FSM 状态 (FSM 是否非法状态是另一个关键数据点)。

### P6 冻结根因破案 (UART 全精度快照)

- **快照**: NX=1239FF11 UA=1239FF11 WN=FFFF ST=1 W=0000 I=0B68 E=2FFE
  TXST=0。回卷前 snd_nxt=0x123A0A79 / snd_una=0x1239FF11 — **在飞 2920B
  跨过 64K 边界 (0x123A0000)**, 高半字节 0x123A ≠ 0x1239 — win_hi_eq=0
  "正确", win_inflight=0x0B68 与 win_wnd_eff=0x2FFE 都正确。
- **根因 = P6 时序优化自己引入的 16 位门控 bug**: `hi_eq && (低16差<帽)`
  的注释断言"4GB 级会话才触发"是**错的** — 任何 64K 边界跨越即触发
  (ISS 0x12345678 起每 ~64KB echo 一次, 首跨在 ~43KB 处)。跨边界期间
  门关 → TX 停 → echo FIFO 满 → RX 冻结 → 边界另一侧的 ACK 无法处理 →
  永久死锁。此前几次边界因 ACK 及时推进 snd_una 瞬态通过, 本边界赶上
  ACK 时序就级联 (确定性: 数据模式固定 → 冻结点固定)。
- **教训双杀**: ①时序优化引入语义回归 — 16 位化的"4GB 边角"论证漏了
  64K 边界; sim 的 burst 也跨界但 PCACK 即刻 ACK 使跨界瞬态 — **sim
  的快速 ACK 模型掩盖了跨界死锁级联**。②LED/闪烁读数的反复矛盾其实
  都是真值 — 死锁态的 TX FSM (TXST=0, S_IDLE 健康) 与门控信号组合本就
  如此。
- **修复 (进行中)**: tcb win 口回归 32 位回绕安全比较 (sub+compare 移入
  寄存器块, 时序收益保留 — 门控输出仍是寄存器); 配套 sim 跨界探针
  (straddle 计数 + 跨界拍 win_open 必须开)。

### P6 冻结第二根因 (32 位门修复后新快照): drain 重启丢失

- **新快照**: NX=125F14DD UA=125F14DD W=0001 I=3908(14592) E=2FFE TXST=1 —
  32 位门"正确"判定: 在飞 14592 ≥ 帽 12286, 门关是**对的**。真凶在更上游:
  冻结前 ~10 帧 PC 的 ACK 处理已停 → 在飞积累 → 门关 → 级联。
- **根因**: tcp_rx 的 drain (rcv_nxt→snd_una→snd_wnd, 每字段一拍+gnt)
  被每个新 fend 整体重启 (drn<=1 + pend_* 重锁存) — PC 板上发**背靠背
  纯 ACK 小帧** (fend 间隔 ~10-15 拍 < drain 完成窗口), 重复 ACK 帧的
  fend 把 pend_una/pend_rcv 清零 → 推进**永久丢失** → snd_una/rcv_nxt
  停摆。sim 的 PCACK 单 ACK + 12-IFG (fend ≥84 拍) 永不触发 — 又一个
  "快速/宽松 ACK 模型掩盖真缺陷"的案例。
- **修 (进行中)**: pend_* 三标志改粘性置位 (fend 只置不覆盖, drain 的
  gnt 落写才清; 值寄存器仅在对应条件真时更新) + 单元 TB 背靠背 ACK
  突发定向用例 (旧代码必挂/新代码必过)。
- **本轮双重根因回顾**: ①16 位门 64K 跨界误关 (P6 时序优化引入);
  ②drain 重启丢失 (P4b-5/6 时代遗留, 板上真实 ACK 模式才触发)。
  两个都被 sim 的宽松 ACK 模型掩盖, 板级 UART 快照逐层剥开。

### P6 冻结第三层 (drain 修复后): RX 管道整体冻结是主事件

- **drain 修复后快照不变**: NX=UA, I=3908(14592)≥帽, TXST=1(S_RECV 卡住)。
  重理因果: TX 卡在 S_RECV (帧字节断流 = echo FIFO 中途干涸) + 在飞在
  ~10 帧内涨到 14592 → **主事件 = RX 管道在冻结前 ~10 帧整体停摆**
  (数据接受与 ACK 处理同停, PC 窗口随后填满停发, TX 的最后一帧饿死),
  门关与 RTO 循环都是下游。drain 丢失只是次要贡献 (每 burst 丢 1 个推进,
  积累太慢, 不是这次冻结的直接触发器)。
- **嫌疑收敛**: ①echo frame_fifo 的满标志粘死 (指针逻辑在 BRAM 外无变化,
  但满判定 + bypass_r 与真实流量交互未覆盖); ②axis_pipe 与 tcp_tx_frame
  tready 的边界交互; ③tcp_rx FSM 卡点。
- **下一轮: UART 快照扩展 RX 侧** (tcp_rx FSM/accept/emit, tcp_echo FSM,
  FIFO 满/空 + wptr/rptr 指针值) — 指针值直接裁决"满标志是否粘死"。

### P6 冻结第四层: 卡点 = echo->pipe->TX 握手, tlast 丢失假设

- **RX 侧快照**: RXST=0 (S_HDR 健康空闲), EST=1 (S_FWD 呈现中), FFE=00
  (FIFO 不空不满, WPT=D1F/RPT=AF4 = 555 词滞留), TXST=1 (S_RECV 卡住)。
  因果定局: TX 卡 S_RECV → 单线程 FSM 无法启动 ACK 帧 → PC 窗口填满停发
  → 全链死锁。字节断流点 = echo(呈现中)->pipe->TX 之间。
- **最强假设: 帧流中 tlast 丢失** → S_RECV 持续收满 256 词 pay FIFO →
  tready=0 → echo 停在 555 词。旁证: 第三轮 LED 的"不可能组合"
  sready=1 ∧ pay_full=1 恰是此态的时序切片。
- **已排除**: RAMB18E1 侧存的 DIADI/WEBWE 接线 (36 位写数据横跨
  DIADI+DIBDI, WEBWE=0011 恰使能 DIADI 两字节 — 接线正确)。
- **下一轮快照: PF/TV/PV/SV/PLEN** (pay_full, tx tvalid, pipe m_valid/
  s_valid, plen_r) — plen_r > 1460 即实锤帧长破坏。

### P6 冻结第五层: tlast 丢失实锤 → 侧存原语嫌疑

- **TX 握手快照**: PF=1 (pay 满) TV=1 PV=1 SV=1 PLEN=5B4(1460, 上一帧) —
  当前 S_RECV 帧已收满 256 词 (2048B > 1460) 仍未 tlast → **帧流的 tlast
  位在 echo FIFO -> pipe -> TX 途中丢失**; pay 满 → tready=0 → echo 停 →
  WPT-RPT=921 词滞留 → TX 单线程 FSM 卡 S_RECV 无法发 ACK → PC 窗口填满
  → 全链死锁。因果链完整闭合。
- **pipe 打包/解包核对对称无误** (wrapper 与 TB 同构, sim 全绿佐证)。
- **头号嫌疑: P6 换的 frame_fifo 侧存 RAMB18E1** (tkeep+tlast 9 位) — 
  P4b-6 时代的 LUTRAM 侧存板上验证过; 主存 64 位 BRAM 保留 (时序)。
- **修 (进行中)**: 混合结构 — 侧存退回寄存器数组 + 寄存器读 (与主存
  1 拍读延迟对齐, bypass_r 掩蔽机制天然覆盖侧存碰撞), 主存不动。

### ===== 会话存档点 (2026-09-06 深夜, 用户叫停) =====

**P4b-7 状态**: P1-P5 完成 (提交 542689d 本地, GitHub 推送当时网络不通未遂);
P6 板级重建+速率测试进行中, 五层根因剥除已到最后一层:
①16 位门 64K 跨界误关 (已修: 32 位回绕安全, tcb win 口寄存器化)
②drain 重启丢推进 (已修: pend 粘性置位, 单元 TB 新旧对照实锤)
③frame_fifo 全 LUTRAM 时序 (已修: 主存 RAMB36 原语)
④svc/rb_id/ack_pend/tick 长链 (已修: 逐源寄存器化 + tick 扫描)
⑤**tlast 丢失 (进行中)**: 侧存 RAMB18E1 疑似板上丢 tlast 位 —
**修复 agent 正在后台运行** (混合结构: 侧存退回 LUTRAM 寄存器数组+
寄存器读, 主存 BRAM 不动), 完成后将重建+烧录。

**重启后待办**:
1. 收尾 agent 的混合侧存修复 (sim 门 + WNS + 烧录) → 板测 20MB/100MB
2. 若板测过: 清理诊断脚手架 (LED 闪烁/UART 快照/dbg 端口 — 或保留 UART
   作为长期诊断口), 全矩阵回归 + 审查 agent, 提交 (本地 542689d 之后
   的所有改动) + 推送 (GitHub 当时不可达, 需重试) + ls-remote 验证
3. 若仍冻结: 下一探针 = echo fdout[72] (fifo dout tlast 位) 直接入 UART
   快照, 或 ILA
4. 板上 UART 读取配方 (PowerShell COM8 9600-8N1, 测试后延迟 ~5s 重复行)

### 存档点补记 (侧存混合修复后): tlast 丢失点不在侧存

- **混合侧存修复 (主存 RAMB36 + 侧存 LUTRAM 寄存器读) sim 全绿 + 板上
  烧录后速率测试仍冻结** → tlast 丢失与侧存的 BRAM/LUTRAM 实现无关。
- **下一轮探针 (重启后第一步)**: 把 echo 的 fdout[72] (fifo dout 的
  tlast 位) + tx 侧 s_axis_tlast 直入 UART 快照 — 定位 tlast 死在
  echo 出口 / pipe / tx 入口的哪一段; 备选: pipe 边沿行为 (m_valid<=s_valid
  的 1 拍延迟与 echo FWFT 弹出的对齐) 或 tx S_RECV 的 tlast 判断。
- 其余四层根因 (64K 跨界门/drain 丢推进/LUTRAM 时序/rb_id 长链) 均已
  修复并验证, 修复均保留。

### 会话恢复 (2026-09-11): 冻结复现确认 + 三计数器探针部署

- 板掉电丢配置已重烧; 速率测试冻结签名与存档完全一致 (PF=1 TV=1 PV=1
  SV=1 PLEN=1460, echo 滞留 555 词) — **侧存 LUTRAM 回退后 tlast 丢失
  依旧, 侧存正式排除**。
- **三计数器探针部署中**: TW (echo 写侧 tlast 计数) / TF (echo 转发
  tlast 计数) / TI (tx 接受 tlast 计数) — 三者差额定位 tlast 死在
  写侧 (tcp_rx emit_l 上游) / FIFO 转送 / pipe+tx 接收的哪一段。

### P6 冻结第六层: 三计数器推翻 tlast 丢失假设 → pay FIFO 满标志焦点

- **TW=3237 TF=TI=3233**: tlast 写侧 3237 帧全齐, 转发与接收完全一致
  (差额 4 = 冻结时 FIFO 内的积压帧) — **tlast 没有在途丢失**, 第五层的
  "tlast 丢失"方向正式推翻 (侧存 RAMB18E1/LUTRAM 的整个嫌疑链也随之
  排除)。
- **新焦点**: TX 的 S_RECV 收第 3234 帧时 pay FIFO (fifo_sync 73x256)
  报满 (PF=1) — 单帧仅 183 词, 真满公式下不可能 → 要么指针坏要么内容
  真是 256 (运行 plen ≥2048 即实锤帧被异常拉长)。echo 滞留 555 词
  (~3 帧) 与 TW-TF=4 吻合 (第 3234-3237 帧在积压中)。
- **下一轮探针: u_fifo wptr/rptr/full/empty + 运行 plen** 直入 UART —
  指针/内容直接裁决"满标志粘死 vs 帧异常拉长"。

### P6 冻结第七层: pay FIFO 真满裁决 → RX 前缀丢弃理论

- **PW=0x0BF PR=0x1BF** (低 8 位相等+绕回位不同 = 公式真满 256 词) +
  **PLN=0x800=2048** — 当前帧确实被拉长到 2048+ 字节, 满标志没粘死。
- **RXST=0 (S_HDR 健康)** + TW-TF=4 + echo 滞留 555 词 → 拼图:
  RX 发出 ~262 词前缀后**把帧尾丢了 (S_DROP)** 且无 tlast, 前缀留在
  echo FIFO → TX 吃无尽前缀 → pay 满 → tready=0 → 全链冻结。
- **头号嫌疑: RX 的帧长判断被破坏** — plen_l 锁存错位 (头部丢一拍 →
  w2 总长字段读到垃圾 → 超长守卫 pcount+8>plen_l 误触发 → S_DROP
  吞掉帧尾)。
- **下一轮探针: RX 的 plen_l/pcount/w2 总长 + 四路丢弃统计** 直入
  UART — plen_l 异常值即实锤锁存破坏。

### P6 冻结第八层: RX 帧判正常 → 轨迹缓冲探针部署

- **RX 侧快照**: RXPL=05B4(1460)/RXPC=05B2/RXT=05DC(1500) 全部正常,
  DROPS=13/0/14/0 (重传乱序处理, 量级正常) — RX 帧长判断与丢弃路径
  排除。无尽帧的 tlast 缺失发生在 echo 层 (TX 恰在 2795 帧第 184 拍
  (tlast 位) 未见 tlast → FIFO 存了 tlast=0 或拍本身丢失)。
- **状态探针已到极限**: RX 冻结时已回 S_HDR, 事件现场无法从冻结态重建。
- **轨迹缓冲探针部署中**: 64 拍 x 24 位环形记录 (TX FSM/pipe 握手/
  echo tlast/accept/FIFO 占用), "S_RECV 停滞 1000 拍"触发冻结, UART
  按环序倾卸 — 直接看到 2795 帧尾拍的 tlast 与握手时序。

### P6 冻结第九层: 轨迹缓冲首轮 — 停滞检测早触发, 改回卷触发

- **首轮轨迹全部 64 拍同值** (S_RECV + 握手全 1 + tlast=1 + occ=189):
  停滞检测 (S_RECV&&tvalid&&!tready 连续 1000 拍) 在某个**瞬态停滞**上
  早触发一次性冻结, 真实冻结 (回卷时刻) 没抓到。教训: 一次性探针的
  触发事件必须选不可逆的终态事件 (回卷), 不能选可恢复的瞬态。
- **修复: 环形冻结改由 tx_stat_retx!=0 (首次回卷) 触发** — 与快照锁存
  同刻, 最后 64 拍 = 冻结拍模式 (tvalid=1/tready=0/tlast=0/accept=0)。

### P6 冻结第十层: 回卷触发轨迹 → TX 在 S_IDLE/S_RECV 间循环

- **回卷触发轨迹**: 冻结拍 = S_IDLE + tvalid=1 + tready=0 + occ=2092 —
  TX 在回卷时刻空闲待门开 (在飞 14592≥帽, 门正确关闭), 快照的 TXST=1
  是 5 秒后的实时重采样 (TX 又回到 S_RECV)。**完整图景: TX 每 100ms
  循环 S_IDLE(回卷→门开) → S_RECV(吃无尽帧 256 词→pay 满→卡住)** —
  无尽帧的 tlast 在 FIFO 中某处消失 (word 184 存储位非 1), RTO 每周期
  吃掉 256 词, PC 19s 后 RST。
- **终结性探针部署中: FIFO 侧存 tlast 位倾卸** (rptr±32 词 x 64 位位图,
  8 行 hex) — 直接看到帧 A 的 tlast=1 存在哪里/是否缺失。

### P6 冻结第十一层: FIFO tlast 倾卸 → 合并流裁决

- **TL 位图**: 64 词窗口 (rptr±32) 内唯一 tlast=1 在 slot 167 = **读指针
  前 5 词** — 帧尾就在眼前, 但 pay FIFO 已满 256。结合 TW/TI 对账与
  pay 指针: **TX 当前帧 = 合并流 ~262 词** — 帧 A 的尾拍被 RX 以
  emit_l=0 发出 → 帧边界消失 → A+B 合并 → 无尽帧。
- **根因收敛到 RX 的 emit 尾字逻辑**: pcount 词计数错位 (多/少一个词)
  → pay_r 错 → 尾分支误走 (emit_l=0) — 1460B 帧尾 4 字节本应走
  pay_r≤6 简单支 (emit_l=1)。
- **终局探针部署中: RX 侧 emit 轨迹** (64 拍 x state/emit_v/emit_l/
  accept/pay_r/pcount) + 帧尾词缺失触发 (fend 时 pcount<plen_l-4)。

### P6 冻结第十二层: RX emit 轨迹 → 62 字节短帧 + 长度字段错锁存

- **触发帧的轨迹**: 7 个头词 (S_HDR 接收) + 1 个载荷词 (S_PAY) → fend
  (pcount=1 << plen_l-4=1456) — **实际帧 ~62 字节 (真实小段, 窗口边缘
  残片), 但 w2_r 锁存的总长 = 1460** (旧值/错词) → pay_r=1459 走错尾
  分支 → emit 畸变 → 下游合并 → 无尽帧。
- **二分嫌疑**: ①上游丢词 (mac_rx_64/rx_classify 掉了帧中段 — 真实短帧
  的其余词丢失); ②RX 头部锁存错位 (w2_r 读了旧值 — 62 字节帧的头部
  处理错拍)。
- **三站词计数探针部署中** (mac_rx 出词 / classify 进出 / tcp_rx 进词
  + wcnt 入轨迹) — 计数差额直接裁决丢词站; wcnt 轨迹裁决头部锁存。

### P6 冻结第十三层: 三站计数零丢词 → 线缆帧长度裁决

- **MW=CW入 / CW出=RW**: mac_rx→classify→tcp_rx 零丢词 (91 差额 =
  慢路径帧未计数); wcnt 轨迹 0→6→7 正常 — **头部处理无错拍, 帧真的
  只有 62 字节, 自己的总长字段 = 1500, FCS 有效**。
- **FCS 有效性约束**: 若 RGMII 桥吞中段, 收到的 62+4 字节的 CRC 必败
  → 帧会被丢 — 与"帧被接受"矛盾 → 要么 PC 真发了 66 字节怪帧 (NIC/
  栈 bug), 要么桥有不可解释的跳变。
- **线缆长度探针部署中**: PHY rx_ctl 高电平宽度计数 (RGMII 每拍 8 位),
  异常触发时锁存 — WL=66 → PC 侧; WL=1518 → 桥/PHY 侧。

### 会话存档点 #2 (2026-09-12): 线长探针待读 + HLS 慢路径死亡新阻塞

**未完成的关键裁决**: 异常帧 (62 字节 + 总长 1500 + FCS 有效) 的来源 —
PC 侧 (NIC/栈) vs FPGA RGMII 桥。WL 探针 (PHY rx_ctl 高电平计数) 已构建
烧录但**没读到** (链路故障吃掉了时间)。

**链路故障链条 (PC 侧)**: 板子断电重启后 "以太网 2" 静态 IP 192.168.100.1
丢失 (抓包见 DHCP 发现!) → 重配 (netsh) → ping 需 -S 强制源 → 静态 ARP
(netsh interface ip add neighbors 192.168.100.2 00-0a-35-01-fe-c0) →
测试脚本已加 s.bind(('192.168.100.1',0))。

**新阻塞: HLS 慢路径从启动即死** (当前 wire-counter 构建; 此前 diag11-15
构建的板测正常连接)。症状: ICMP/ARP/SYN 全无应答 (重烧不愈)。分水岭 =
diag17 的 wire-counter 构建 (wrapper 新增 phy1_rxc 时钟域计数器)。
**重启后第一步**: 与 diag15 构建对比 — 回退 wire-counter 重测, 或用
回退法二分定位 wrapper 哪处改动杀了 HLS (嫌疑: 新时钟域的复位扇出 /
综合布局扰动 / uart_dbg 的接口)。

**其他遗留**: 提交 542689d 未推送 (GitHub 需重试); 诊断脚手架 (UART 快照/
轨迹/LED) 保留待清理; pc_tcp_rate_test.py 的 bind 补丁已在工作区。

### 会话存档点 #3 (2026-09-12): HLS 死亡确诊 + diag18 二分构建

**HLS 死亡确诊 (今天上午, 非链路伪影)**:
- 重烧录两次 (10:31/10:35) 均 PROGRAM_OK + DONE=HIGH; 烧录后 LED boot 自检
  3 闪可见 → FPGA 逻辑在跑、gmii_clk 正常、复位释放正常。
- PktMon (comp 102 = Killer E5000B) 20s: 板上 MAC 00-0a-35-01-fe-c0 **零帧** —
  连 HLS 每 ~5s 的 UDP HELLO 自发行文都没有 → HLS 主循环从未运行 (不是 RX
  侧聋, 是整体死/复位循环)。
- UART 静默 (latched=0, 无 RTO 回卷 — 与 HLS 死无握手一致)。
- 链路 Up 1G 不证明 FPGA 工作 (PHY 独立芯片, 与 PC 自协商)。
- PC 侧已排: 无残留 TCP 连接 (netstat), 静态 IP/ARP 完好, 线缆 10s 静默。
- LED 稳态 (丝印 D3/D4 亮) — 丝印↔led_d 映射仍未定论, 待 boot 自检 4 灯齐闪
  对照; led_d2=sready 空闲恒 1 是唯一天然亮的探针, D4 亮疑为映射偏移。

**排查已排除**: 慢路径适配器 diff 仅调试口 tie-off; HLS 实例接线 (ap_clk/ap_rst_n/
rx_stream/tx_stream/cfg_stream) 未变; hls_rst_n 看门狗是 P4b-4 老代码 (diag15 正常);
HLS 导出 8-30 未变; 两构建时序全绿 (WNS +0.42/+0.56); 合成 0 错 0 critical;
RTL diff 全部 = 调试纯增量 (计数器/tie-off/assign)。

**diag18 二分构建 (本轮)**:
1. **回退 wire counter (phy1_rxc 域)** — diag15→17 唯一新时钟域, 头号嫌疑。
2. **WL 重写到 gmii_clk 域** (e_rxdv 高拍数 = 线上字节数, 1 字节/拍, 无乘 8 无
   CDC — 功能等价, 判别力不变: 66 vs 1518)。
3. **UART boot 行**: run = latched || boot_h==6 (~1.2s 后开始发, 每 5s 重复) —
   不再依赖回卷锁存, HLS 死/活一望便知。
4. **慢路径存活字段** (行尾追加 64 字符, SNAP_M1 431):
   SC=%08X SD=%08X SF=%08X SP=%08X SV=%06X HR=%d
   SC/SD = slow_rx_adp 提交/丢弃 (RX→HLS 交付证明; 有流量时 SC 随帧递增);
   SF/SP = slow_tx_adp 发出/purge (HLS→TX 链证明; 活着应 ~5s +1);
   SV = 看门狗饥饿累计 (周期归 0 = 看门狗循环复位 HLS ≈ 16.8ms 一循环);
   HR = hls_rst_n 实时 (0 = HLS 复位中)。
5. 顺手修: mac_dbg_words_out 声明移到使用前 (xvlog VRFC 10-2938); uart_dbg
   新字段避开既有 sv_l/v_sv 名 (改名 srv_l/v_srv); CR/LF 位点随行宽挪到
   430/431。

**判读表 (烧录 diag18 后读 UART boot 行 + 抓包)**:
- HELLO 恢复 + SC/SF 随流量递增 → wire counter 域是杀手, 结案;
- 仍无 HELLO: HR=0 恒 (HLS 复位不释放) 或 SV 周期性归零 (看门狗循环) →
  HLS 被反复复位 (查 starve 源: HLS tready=0 为何) — 或 SC/SF=0 SV=0 HR=1
  (无饥饿无输出) → HLS 内部死/时钟域问题, 下一刀砍 TR/TL/RXT 环与 uart_dbg。

**其他**: 提交 542689d 仍未推送 (GitHub 网络); diag18 通过后一并处理。

### 会话存档点 #4 (2026-09-12): 双谜题破案 + trunc 修复 + diag19

**谜题一结案: wire counter (phy1_rxc 域) 杀死 HLS**。diag18 回退后 HLS 复活
(DHCP DISCOVER 上线, ping 3/3, SC/SF/SV/HR 全正常)。WL 改 gmii_clk 域 (e_rxdv
高拍计数) 功能等价。教训: 无必要不开新时钟域; PHY 链路 Up 不证明 FPGA 活着。

**谜题二结案: 冻结根因 = tcp_rx 截断支静默吞尾**。diag18 UART 快照一次到位:
- WL=0048 (72 字节) → 截断帧**来自 PC 侧** (NIC/栈, 非 FPGA 桥吞帧; GigaLite/
  LSO/USO/校验和 offload 全关仍复现, drop_seq 恒 13 确定性触发)
- TW=6F4 TF=TI=6F0 → tlast 从未丢失 (旧方向全废)
- PLN=800 (2048 字) + PF=1 → TX 吃无尽合并帧
- 机制: 截断帧 (声称 1500 实到 8) → S_PAY 尾拍 pop8w<pay_r → 旧代码静默吞尾
  无 fend 无 emit_l=1 → echo 帧永不判尾 → 后续帧合并 → 无尽帧 → 冻结

**trunc 修复 (diag19)**: tcp_rx 截断支按真实字节闭合 (emit_l/tail_k 按 pop8w,
9..10 字节走 S_TAIL 溢出), fend 正常, adv_cnt = 真实字节 (ack_val/pend_rcv),
stat_drop_trunc 新计数 (UART 行尾 TRU 字段); w6 截断 (fend_w6t) 闭合边界不推进。
审查 agent 发现并已修: ①tcp_echo judged 拍 has_data<=meta_valid (P1-7 同拍
冲突, 重传风暴+fifo 满边缘时序) ②fend_w6/w6t 补 !s_axis_tuser ③截断支 stat
按 tcrs 分流 ④w6-tlast 拍锁存 wnd_l ⑤fend_w6t 回 ACK ⑥TRU 位基 442 修 8 位。
待: 实现 agent TB 截断注入 (TRUNC=N) + 测试 agent 全矩阵 → 烧录 → 100MB。

**新工具**: Wireshark 4.6.8 + tshark 已装 (接口 8 = 以太网 2); tools/
capture_rate_test.ps1 = tshark 抓包 + 速率测试 + 怪帧过滤 (ip.len==1500 &&
frame.len<100) + 重传/dup-ACK 统计; board_diag18_test.py = COM8 + 抓包并行。
pktmon 教训: etl2txt 输出 UTF-16LE; 板 MAC 在 txt 中为大写 00-0A-35-01-FE-C0。

### P4b-7-P6 里程碑 (2026-09-12): TB 截断帧注入 + 自愈验证 (TRUNC 门全绿)

烧板前先在 xsim 全链证明 trunc 修复: TB 注入板级 PC/NIC 怪帧 (承诺 1500B
实到 8B, FCS 重算有效), 判据全部落地为自动门 (gen_stim burstcheck), 不再
人工读日志。

**注入机制 (与 TXDROP 同通道)**: xsim.bat loader 会拆含 '=' 的 -testplusarg
("Expected a switch but found 5") — TRUNC/TRUNCM 走环境变量 => sim/p4sim/
trunc.memh ("N M"; bat 每次重写, chain 门开头删除防残留)。TB (tb_p4_chain.v)
$fscanf 读 N/M, gen_stim_p4_chain.py read_trunc() 读同一文件 — 注入点两侧同源。

- 注入帧 = 同头 (seq / IP total_len=1500 / TCP 头 / sport) 只留前 M 字节载荷,
  FCS 按截断后内容重算 (finish()); 线上 54+M+4 字节。M 合法域 6..10: M<6 被
  60B 最小帧填充吃掉语义 (板上把填充当载荷), M>10 不再是部分尾字。
- 自愈模型 = PC RTO 重传: 截断段后面各原发段在板上全判 OOO (rcv_nxt 停在
  S+M) → 板上逐帧回 dup-ACK 但丢载荷, 缺口只能 PC 补。续传帧 seq=S+M,
  plen=1452 (= snd_nxt-snd_una, 真实 tcp_retransmit_skb 行为), 其后各段按
  原样重放。板上 ring 只有真实的 M 字节救不了 → **RETX 恒 0** (实测确认)。
- TB 新观测: u_rx.stat_drop_trunc 接线 + resp 尾部 TRUNCS n stat / ECOMAX
  (tcp_echo 出口最长无 tlast 词串; 1460B 帧 = 182 非尾词, 旧冻结签名 256 词
  无尽帧在此现行)。

**门命令 (Git Bash)**:
```bash
cd /d/repo/ECO/udp_hls_10g/sim/p4sim
TRUNC=100 TRUNCM=8 cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_burst.bat 200'  # 截断门
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_burst.bat 200'                      # burst 回归
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_chain.bat'                          # 全链门
```

**判据 (burstcheck)**: ①stat_drop_trunc>=1 且 TRUNCS n == 注入点; ②截断段 echo
plen==M 且 ack==S+M (rcv_nxt 只按真实字节推进); ③板上对 OOO 段的纯 ACK 全部
ack==S+M (dup-ACK 证据); ④echo 无合并: 单帧 plen<=1460 且 ECOMAX<=182;
⑤覆盖并集 == 原计划 [base, base+16+200*1460) 连续无洞 (自愈); ⑥STATS7 bytes
== 原计划+conn1 20B (好 FCS 截断按真实字节记账 — 审查 P2-3 分流语义)。

**结果 (2026-09-12 全绿)**:
| 门 | 结果 | 关键数 |
|---|---|---|
| TRUNC=100 M=8, NB=200 | BURST OK | TRUNCS(100,1) ECOMAX 182; echo(8B)@12367FBD ack=00022D34; 并集 292016B; RETX=0 |
| TRUNC=100 M=10, NB=200 | BURST OK | echo(10B) ack=00022D36 (M=9..10 的 S_TAIL 溢出支实测) |
| burst 200 (无注入) | BURST OK | 202 echo 连续链; RETX=0; TRUNCS(0,0); ECOMAX 182 |
| TXDROP=50 / 50+51 | BURST OK | RETX=1; 并集干净 (板上重传路径无回归) |
| 全链 chain | P4 CHAIN OK | 9 RX / 8 TX (fast 3 / slow 5) |

**过程中抓到的注入器 bug (非 RTL)**: healrem 续传帧载荷写成 payload(p0-M)
(= 段头重来) 而非 payload(p0)[M:] (按流偏移切) — 板上 echo 载荷整体回退 M
字节; 被 P4b-7-P5 逐字节验证器当场抓住 ("期望 3b42.. 实得 030a.."), 修正后
203 帧全等。RTL echo 路径本身字节精确 (收到的 = 发出的)。

**遗留**: 板上 diag19 烧录 → 100MB 传输复测; TRUNC 门只覆盖 S_PAY 截断支
(M>=6), w6 截断支 (plen>2 但帧在 w6 结束) 无 TB 干净用例 (M=1..2 落该支,
但 60B 最小帧填充使其不可从激励侧构造)。

### P4b-7-P6 板级里程碑通过 (2026-09-12)

**100MB 速率测试全通** (diag19 = wire-counter 回退 + trunc 修复 + 审查修复):
- 64MB: 110.7 Mbps 发送 / 112.5 Mbps echo 稳态 / 完整收齐 / 448 自愈事件
- 100MB: 126.9 Mbps 发送 / 127.0 Mbps echo 稳态 / **104857600 B 完整收齐** /
  563 重传/dup-ACK 自愈事件 / 零冻结零 RST / exit 0
- tshark 怪帧过滤 (ip.len==1500 && frame.len<100) = 0 — 本轮无怪帧 (偶发)
- UART: NXT=UNA 全确认, TW=TF=TI=1CD1D 全等, DROPS 全 0, PASS=118k,
  TRU=0 (截断支 sim 已验证, 板级本轮未触发)
- **新发现 (诊断遗留)**: RXTR 触发器误触发 — 纯 ACK 帧 (plen_l=0, pcount=0 <
  0-4) 也触发 rx_trace_rewind → RXTR=1 + WL=72 锁的是纯 ACK 帧长。已修
  (plen_l != 0 排除), 随下次构建生效。diag18 时代 WL=72 的解读同样受此影响:
  该锁存可能是纯 ACK 而非怪帧; 怪帧认定不依赖 WL (内部 62B+总长1500 直测)。

**遗留清单**:
- w6 截断支 (帧在 w6 结束 plen_l>2) 无干净 TB 用例 (60B 填充不可从激励侧构造)
- 怪帧 (PC 侧 62B+总长1500+FCS 有效) 的 PC 侧根因未定 (offload 全关仍复现;
  偶发; 修复后对板无害 — 收多少转发多少 + PC 重传自愈)
- wrapper_tcp.v (P3 目标) 例化端口过时 (build_tcp.tcl 仍引入新 tcp_rx.v)
- 诊断脚手架 (UART/trace/LED) 保留为长期诊断接口
- GitHub 推送待办 (542689d 未推)

### P4b-7-P6 测试矩阵复跑 (2026-09-12, 测试 agent 独立复跑)

trunc 修复落 RTL 后的完整回归: **19 次跑 = 17 PASS / 2 FAIL (同一用例复现两次)**。
每次跑 = gen_stim 生成 + xvlog/xelab/xsim + burstcheck/check 判据全链。
日志: `sim/p4sim/p6logs/*.log`; FAIL 用例另存 `17_xsim_run.log` / `17_resp.memh` /
`17_stim_data.memh` / `17_payload_map.json`。命令形式 (Git Bash):
`cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_burst.bat <参数>'`。

| # | 命令 (bat 参数) | 结果 | 关键数 |
|---|---|---|---|
| 01 | `200` | **BURST OK** | 202 echo / 292016B; RETX=0; TRUNCS(0,0); ECOMAX 182 |
| 02 | `TRUNC=100 TRUNCM=8 200` | **BURST OK** | TRUNCS(100,1); echo seq=12367FBD **plen=8** ack=00022D34; dup-ACK 8 帧全 ack=00022D34; RETX=0 |
| 03 | `TRUNC=100 TRUNCM=10 200` | **BURST OK** | TRUNCS(100,1); plen=10 ack=00022D36 (S_TAIL 溢出支) |
| 04 | `TRUNC=50 TRUNCM=6 200` | **BURST OK** | TRUNCS(50,1); plen=6 ack=0001100A |
| 05 | `200 0 0 10` (gate-4096/PCWND1K) | **BURST OK** | TCBF snd_wnd[0]=4096 (基线 65535, 门控真交战); 202 echo; RETX=0 |
| 06 | `200 0 0 4000 608 dup` (dupstorm) | **BURST OK** | 202 echo / 273272B; RETX=0; ECOMAX 182 |
| 07 | `200 -1 0 4000 0 0 50` (TXDROP) | **BURST OK** | RETX=1; 207 echo; 并集 292016 无洞 |
| 08 | `... 50 51` (TXDROP 双丢相邻) | **BURST OK** | RETX=1 (相邻=1 会话); 206 echo |
| 09 | `... 199` | **BURST OK** | RETX=1; 205 echo |
| 10 | chain (`run_tb_p4_chain.bat`) | **P4 CHAIN OK** | RX=9 TX=8 (fast 3 / slow 5); TRUNCS(0,0); ECOMAX 182 未越界 |
| 11 | `200 100 300000` (pause-300k) | **BURST OK** | 202 echo / 290908B; RETX=0; 链连续无洞 |
| 12 | `TXDROP=50 200` (**环境变量形式**) | 基线结果 | RETX=0 / TRUNCS(0,0) / 202 echo — **未注入任何丢帧 (见下"陷阱")** |
| 13 | `TRUNC=100 TRUNCM=8 200` (复跑) | **BURST OK** | 与 02 逐数一致 (确定性, 无跨跑串扰) |
| 14 | `200 0 0 400` (P4b-6 wnd=0x400 变体) | **BURST OK** | 202 echo; RETX=0; 注意 TCBF snd_wnd=65535 (见下"观察") |
| 15 | `... 200` (TXDROP) | **BURST FAIL (exit 1)** | `MISMATCH: RETX 2 != 期望 1`; 204 echo; conn1 echo=2; TCBF conn1 snd_una=900 |
| 16 | `... 202` | **BURST OK** | RETX=1; 202 echo |
| 17 | `... 200` (复跑) | **BURST FAIL (exit 1)** | 与 15 逐数一致 (确定性) |
| 18 | `... 198` | **BURST OK** | RETX=1; 206 echo |
| 19 | `... 201` | **BURST OK** | RETX=1; 203 echo |

判据逐项: BURST/CHAIN OK 打印 ✅; 截断门 TRUNCS(100,1)/(50,1) 且 echo plen==M、ack==S+M (S+M=00022D34/00022D36/0001100A 全部对齐) ✅;
dup-ACK 纯 ACK 全 ack==S+M ✅; ECOMAX 恒 182 ≤ 182 (无合并/无尽帧) ✅; STATS_MAC abort/eend 恒 0 ✅;
RETX: 无注入门恒 0、TXDROP 门 ≥1 ✅ (唯一例外 = #15/#17 的精确计数, 见下);
并集覆盖恒 = 292016B 原计划连续无洞 ✅; 载荷逐字节验证 (live + ring 重放) 全等 ✅。

**唯一红门: TXDROP=200 (#15/#17), 非数据损坏**。证据链:
- 拆包 (用 parse_gmii 复解 17_resp.memh): conn0 洞在 echo seq `1238BA0D` (倒数第 3 段), 之后只剩 2 段
  → 凑不满 3 个 dup → 板上恢复走 **RTO 回卷** (RTOLIM_FAST: RTO_LIM=125 → 125×256 ≈ 32k 拍, 落在 60k 尾窗内);
  捕获顺序 = [洞] → 1238BFC1 → 1238C575 → 回卷重放 3 帧 (1238BA0D/1238BFC1/1238C575) → conn1 20B echo → conn1 20B 再发一次。
- 第 2 个会话 = **conn1 的 RTO 自愈**, 不是 conn0 二次会话: TCBF conn1 = (97, 920, 900) —
  snd_nxt=920 (echo 已发) 而 snd_una=900 (刺激末帧 c1ack 的 ack=920 从未生效) → conn1 的 20B 永久未确认 → RTO 重发 (协议正确行为)。
- 机制: c1ack 生效前提是"被处理时 snd_nxt 已=920" (生成器注释: GAP_TCP 1500 拍 ≫ echo ~300 拍);
  conn0 的 RTO 回卷重放 (3×1460B ≈ 4.4k 拍) 恰好压在 conn1 echo 之前, 把 echo 起点推到 c1ack 到达之后
  → DUT 对"确认未发数据"的 ACK 正确拒收 (或 c1ack 在尾窗背压下被丢 — 两分支需实现 agent 探针区分)。
- 索引敏感性佐证: 198/199 (洞后 ≥3 段 → 3 dup 快速重传立即回卷, 不撞 c1ack) 与 201/202 (尾段丢, 回卷早于 conn1 帧完成)
  全过; 只有 200 落在"RTO 回卷撞 c1ack"窗口。**复跑逐数一致 = 确定性边界效应, 非随机**。
- 数据面干净的硬证据: 并集 292016B 无洞; 载荷逐字节验证 204 帧全等 (含 3 帧 ring 重放); ECOMAX 182; mac abort/eend=0;
  conn1 重发帧与首发**仅 IP ID(+1)/IP 校验和/FCS 不同, 载荷 20B 与 TCP 头逐字节相同** (新 IP ID = 合法逐帧计数器)。

**结论**: 数据面全绿; 唯一红门 = 判据问题 (checker 的"单丢 = 1 会话"模型不覆盖邻居连接 RTO 自愈,
且生成器 c1ack 时序假设在该向量被打破), 非 RTL 缺陷。**P4 记录"TXDROP=200 → RETX=1"(PORT_NOTES:1118) 在当前代码+激励下已过期**, 不应作为放行依据。
建议 (择一, 需实现 agent 确认分支): ①checker 对尾窗 RTO 回卷放宽 RETX 判据 (允许 +1 邻居自愈会话);
②生成器把 c1data/c1ack 前移或把 c1ack 的 GAP_TCP 加大到 ≥4000 拍 / 补发第二个 c1ack (让 ACK 不依赖 1500 拍假设)。

**两个陷阱/观察 (供后续复跑者)**:
1. **`TXDROP=N` 环境变量无效**: `run_tb_p4_burst.bat` 的丢帧注入只认**位置参数 %7/%8**
   (`> txdrop.memh echo %7`), 写成 `TXDROP=50 cmd //c '...bat 200'` 会静默退化成普通跑 (#12 实测: RETX=0、202 echo,
   与基线逐数一致)。正确形式: `...bat 200 -1 0 4000 0 0 50`。TRUNC/TRUNCM 才是环境变量 (P6 新增)。
2. **`200 0 0 400` (wnd=0x400) 门控应力已弱化**: 该变体只改 SYN/数据帧通告窗, 但 TB 的 PCACK 注入纯 ACK
   带 inj_wnd=0x4000 → snd_wnd 终值被覆盖成 65535 (非 P4b-6 记录的 4096); 真门控交战 = `200 0 0 10` (+PCWND1K,
   实测 snd_wnd=4096) — 需要门控应力时用 %4=10。
3. (记录) xsim 报 **113 条 RAMB36E1 Memory Collision Error** (`u_echo.u_fifo` / `u_slow_rx.u_ff` / `u_slow_tx.u_wf`,
   P6 frame_fifo 拆分后的 BRAM 例化); **PASS 与 FAIL 跑逐条时间戳完全一致** → 与本次红门无因果, 属既有现象
   (同地址读写 = FWFT 写穿语义, 实现 agent 可复核是否需加保护)。

#### 判据修正 (实现 agent, 2026-09-12): RETX 改按连接语义 — 采纳上节建议 ①

只改 checker 侧 (`tools/gen_stim_p4_chain.py` 的 `check_burst`), 生成器/RTL/TB 未动。

- **conn1 数据面独立判据 (新增)**: 按端口对 `(CONN[1].dport, CONN[1].sport)` 拆出 conn1 echo 帧
  → `1 <= 帧数 <= 2`; 每帧 `plen==20` 且载荷逐字节 == 首发 `payload(20)`; TCBF conn1 `snd_nxt==920`
  (20B 全发出) 且 `900 <= snd_una <= snd_nxt`。实测 TXDROP=200: conn1 echo 2 帧、载荷与首发全等。
- **RETX 期望按连接拆**: `RETX == conn0 会话期望 + conn1 自愈会话`; conn0 期望 = 单丢/双丢相邻 1, 否则 2;
  conn1 自愈会话 = 1 (仅当 conn1 echo >= 2 帧, 即确实重发过) 否则 0。无丢帧门则退化为 `RETX == conn1 自愈会话`。
  即多出的会话必须由 conn1 重发解释, conn0 侧仍严格 (无 conn1 重发时 RETX 必须恰为原期望)。
- **snd_una=900 是 TB 模型缺口非 RTL 缺陷**: TB 无 conn1 ACK 注入 (PCACK 只覆盖 conn0), 首个 c1ack 被拒后
  无第二个 ACK, 故 conn1 的 20B 永久未确认 (RTO 已自愈重发 = 协议正确)。要断言"snd_una 覆盖 20B"须先补
  conn1 ACK 模型 (上节建议 ②, 本轮未做, 留待需要时)。
- **复跑 (修正后)**: `...bat 200 -1 0 4000 0 0 200` → **BURST OK** (RETX=2 = conn0 1 + conn1 1, conn1 echo 2 帧载荷全等);
  `... 200 -1 0 4000 0 0 50` → BURST OK (RETX=1, conn1 echo 1); `200` → BURST OK (RETX=0); `TRUNC=100 TRUNCM=8 200` → BURST OK;
  chain → P4 CHAIN OK。上表 #15/#17 由 FAIL 转 PASS, 其余用例逐数不变。
