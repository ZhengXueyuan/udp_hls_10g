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
