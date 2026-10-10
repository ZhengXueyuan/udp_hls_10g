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
> 📌 **历史记录, 保留原样**: 本节写于 2026-09-12, 那时 `D:\repo\ECO\udp_hls_10g`
> **就是**当时的开发树 (本仓 2026-09-28 才从那里整体拷贝而来, 那份 checkout 仍在)
> ⇒ 现在照抄这些绝对路径会跑**另一个 checkout** (= 真空门)。
> **现役自定位跑法**: 在本仓根执行 `cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'`
> (sh 版 `bash sim/p4sim/run_matrix_p4dfix.sh`); 单门 = `cmd //c 'sim\p4sim\run_tb_p4_burst.bat 200'`。
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
`17_stim_data.memh` / `17_payload_map.json`。命令形式 (Git Bash,**历史记录**: 那时 ECO 就是
开发树; 现役 = 本仓根下 `cmd //c 'sim\p4sim\run_tb_p4_burst.bat <参数>'`):
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

### 怪帧研究结论 (2026-09-12 下午): 怪帧证伪, 真凶 = 驱动重启 + 半帧中止

**复现实验链**:
- 强杀 tshark (npcap) → 下一轮 100MB 冻结; 优雅停止 → 成功。复现率 ~75% (4/5)。
- Killer E5000B pktmon 组件 ID 102→239: **强杀导致网卡驱动重启** (npcap 挂
  Killer 驱动)。
- 冻结轮抓包 (PktMon, ETW 层与 npcap 独立) 2728 帧: **零怪帧** (声称 1500
  实发<100 的帧不存在), PC 发送全规范 (1514/54/662)。"怪帧"假设证伪 —
  diag18 时代 RXT 环的"62 字节怪帧"解读系把测试最初几拍的正常帧 + RXTR
  触发器纯 ACK 误触发混读所致。
- 冻结轮帧序: 板 echo 到 seq 307325317 正常 → PC dup-ACK 回跳 (ack 326777↔
  323857 — PC 丢 echo 帧 seq 307323857, 驱动重启 RX 盲区) → PC 同段重传 5 次
  → 板 DHCP DISCOVER×3 (HLS 被看门狗复位过) → PC RST (协议违例)。
- **drop_seq 恒 13** (PASS=1796/2723/7161/86727/1328 各轮皆 13): 13 个重复段
  是冻结的确定性前奏 — 驱动重启后 PC 重传风暴, 板对重复段回 ACK。

**冻结第三机制 (本轮新发现)**: mac_rx 对"无 tlast 半帧"的中止丢弃 → RX 的
SOP 截断防御 (S_PAY 见 tuser 丢残余转新帧) 救了 RX 自己 → 但 **echo 已收的
半帧永不判尾** → 与后续帧合并成巨帧 → TX S_RECV 吃巨帧 (pay 满 256 无
tlast) → 冻结。TRU=0 与 RXT 环 RX 空闲均为佐证 (RX 没走截断支)。形态与
diag18 冻结同构 (echo 帧合并), 来源不同 (上游中止 vs 截断帧)。

**修复方向 (待实现)**: RX 的 SOP 截断防御拍**合成一个 ferr 尾拍** (emit_l=1,
emit_u.terr=1, 挡新帧首字 1 拍) → echo 以坏帧判定回卷 (现有机制全复用) →
半帧不残留 → 巨帧消除。需 TB 注入 "半帧无 tlast + 紧接新帧 SOP" 复现。

**修复设计 (TL, 待 TB 复现确认后实施)**:
- tcp_rx S_PAY 的 SOP 防御拍 (line ~588): 清残余 emit → 合成尾拍 (emit_v=1,
  emit_d=0, emit_k=0, emit_l=1, emit_u=2'b00) → state<=S_HDR wcnt<=0 →
  sop_def<=1 (新 reg, 挡新帧 w0 一拍; tready 加 !sop_def 门控)。
- fend 加 fend_trunc (= SOP 防御拍组合条件); ferr = fend_trunc || !tcrs || terr
  → echo pend 置位 p_err=1 → 合成尾拍接受拍 judged → 回卷半帧 (现有机制全复用)。
- 屏蔽防御拍的陈旧 acc_l/dup_l: pend_rcv/dup 检测/ack_adv 清 in_retx 均加
  !fend_trunc (前帧 plen_l 不得误推 rcv_nxt)。
- S_HDR/S_PAD 防御不动 (头字/填充不 emit, echo 无半帧残留)。
- 新帧 w0 不再内联处理 (防御拍回 S_HDR, 下拍挡 w0, 再下拍走正常 w0 case)。
- stat_drop_trunc 兼计半帧中止 (与截断帧同语义)。

### P4b-7-P6 半帧中止注入复现 (实现 agent, 2026-09-12): 冻结第三机制 TB 复现成立

**目的**: 先复现后修 — TB 注入"半帧中止"场景, 证明**现有 RTL 确实会冻结** (本轮不改 RTL)。
**注入机制 (新通道 `halfdrop.memh`, 仿 TRUNC/TXDROP)**:
- **参数**: env `HALFDROP=N` / `HALFDROPK=K` → `sim/p4sim/halfdrop.memh` ("N K"; bat 每次重写, 缺省 0/0 = 关)。
  与 trunc.memh 同通道 (xsim loader 拆含 '=' 的 -testplusarg, 文件绕开); TB 与 gen_stim/burstcheck 读同一文件。
- **线上帧形**: 第 N 个 conn0 数据段 (编号同 TRUNC/TXDROP: data7a=1, data7b=2, burst_k=k+3) 只发帧头 54B
  (seq / IP total_len=1500 / TCP 头 / csum 全保原样) + 前 K 字节载荷, 随即停线 — **无 FCS, 无 tlast**,
  帧后是普通 IFG 空闲 (下一帧前导正常) = 板级 PC/NIC 驱动重启时 TX DMA 半途中断的帧形。
- **TB 必须在 mac_rx 出口模拟板级中止** (`tb/tb_p4_chain.v:333` `raw_badtail`): 链 TB 的 `mac_rx_64` 对线上
  中止 (帧内 dv 掉) 走 S_DATA 帧尾支 — 残段**仍交付一拍** `push_last=1/push_crs=0` (≠ 板上"半帧词不入流")。
  若只做线上截断, tcp_rx 走既有 trunc 修复路径 (fend+ferr → echo 回卷), **复现不出冻结**。
  故 TB 只抹掉该残段拍的 tlast (`s_tlast = raw_tlast && !raw_badtail`), tkeep/tuser/tcrs 原样。
  触发 = 激励里**唯一 tcrs=0 的 tlast 拍** (其余帧 FCS 全好), 一次性 (`hd_fired`); `hd_n==0` 时恒不触发。
- **自愈激励** (缺口只能由 PC 重传补): 尾部追加 seq=S 整段重传 (`halfrem`) + 其后各段原样重放 (`halfheal*`),
  与 trunc heal 模型同构。半帧在板上 = "零接收": 无 tlast → tcp_rx 的 `pend_rcv` 需 `s_axis_tcrs`
  (tcp_rx.v:404) → **rcv_nxt 不推进** → 其后原发段全 OOO 被丢。
- **参数校验 (gen_stim, exit(2))**: `3 <= N <= burst+2`; `K >= 6`; **(50+K) % 8 == 0 (K ≡ 6 mod 8)** —
  残段尾字在 tcp_rx 侧整字落地 (尾拍 tkeep!=0xFF 且无 tlast 会把 tcp_rx 打进 S_DROP, 而 S_DROP 只在真 tlast
  退出 → 变成"吞掉后续整帧", 注入语义不再是 SOP 截断防御); `K < 该段 plen`; 与 TRUNC 互斥。

**改动**: `tools/gen_stim_p4_chain.py` (`read_halfdrop` :126 / `build_rx_frames(half_at,half_k)` :143, 半帧发射
:253, 自愈重传 :314 / `parse_gmii` 的 `HALFD` 行 :406 / `check_burst` 复现判据块 :966 / `__main__` :1170);
`tb/tb_p4_chain.v` (halfdrop.memh 读入 :751 / raw_* 线 + 出口 tlast 掩码 :333-346 / TX 冻结哨兵 :849 /
resp 新行 `HALFD <n> <k> <fired> <tdstk_max>` :794 + `$display` :800);
`sim/p4sim/run_tb_p4_burst.bat` :52-61 (HALFDROP/HALFDROPK → memh); `run_tb_p4_chain.bat` :9-10 (chain 门删 memh)。

**注入命令 (Git Bash)** (**历史记录**: 那时 ECO 就是开发树; 现役 = 本仓根下
`HALFDROP=100 HALFDROPK=990 cmd //c 'sim\p4sim\run_tb_p4_burst.bat 200'`):
```
HALFDROP=100 HALFDROPK=990 cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p4sim\run_tb_p4_burst.bat 200'
```

**复现证据 (burst 200, N=100, K=990; 复跑逐数一致)**: 存档 `sim/p4sim/p6logs/{22_*_resp.memh, 22_*_xsim.log, 22_*_check.log}`
| 项 | 值 | 说明 |
|---|---|---|
| TB `HALFD` 行 | `100 990 1 241113` | 掩码触发 ✓; TX 卡 `S_RECV && pay_full` **241113 拍** |
| ECOMAX (echo 出口最长无 tlast 词串) | **257 > 182** | 残留半帧 + 首段重传合并成巨帧 |
| conn0 echo 数 | 99 (期望 202) | 冻结在注入段 — 其后全不再 echo |
| STATS_TX 字节 | 141636 = 16 + 97×1460 | TX 恰停在注入段之前 (一段不多) |
| TCBF conn0 snd_nxt | 305561533 = `0x12367FBD` = e_hd | TX 序号卡在注入段的 echo seq |
| STATS_MAC abort/eend | 0 / 0 | 非 mac 丢帧 — 纯 TX pay FIFO 停摆 |
| 判据 | **BURST FAIL (exit 1)** | 当前 RTL 必 FAIL = 缺陷存在性证明 |

- 注入段 PC seq = 1016 + 97×1460 = **142636** ✓ (与 `half_at=100` 一一对应)。
- 板级签名同构: 板测 = TX 停在 S_RECV 且 PLN=0x800 (=256 字 pay FIFO 满) + PF=1 + TL 位图只 1 个 tlast;
  本复现 = `u_tx.state==S_RECV && u_tx.pay_full` 连拍 241113 (哨兵阈值 1000 拍), 合并点后无任何 tlast 交付。
- 长度数学: 残段线上 54+K 字节 → mac_rx 推 (50+K)/8 词 (K=990 → 130 词, 末拍被掩码后成"帧内词");
  echo 侧残留 = K−4 字节级 (beats 按 8B 重排); 与整段重传 (1460B → 183 词) 合并 **> 256 词** → pay FIFO (256 深)
  满 → `s_axis_tready=0` → tcp_echo 与整条上游停摆 (帧内无整帧丢弃点 = 无自愈出口, 与板级一致)。

**对照 (K=22 与 K=14: 合并不冻结)**:
- `HALFDROP=10 HALFDROPK=22 ... 20`: `HALFD 10 22 1 0` (哨兵 0 = 无冻结); **ECOMAX=184 > 182**;
  conn0 echo = 22 段 (满) 但 echo plen = **1476 = 1460+16** → 载荷流整体位移 16 字节, 并集 292032B = 计划+16B
  → 载荷逐字节验证 FAIL。**小 K 不冻结但静默错位** (残余 16B 被重传重复计一次)。
- `HALFDROP=10 HALFDROPK=14 ... 20`: 残段仅 1 拍, ECOMAX = **183 > 182** (边界, 经 TB 实测) → 合并阈值 = **K ≥ 14**。
- **冻结阈值** = 残段字节 + 1460 > 2048 → K > 592 → K ≡ 6 (mod 8) 下 **最小冻结 K = 598** (K=990 为稳健主用例)。

**回归 (无注入, 全绿)**:
- `run_tb_p4_burst.bat 200` → **BURST OK** (exit 0): echo 202; ECOMAX **182** (上限内); RETX=0; STATS_MAC 208/0/0;
  TB `HALFD 0 0 0 0` = 掩码未触发 / 哨兵恒 0 → **新哨兵对正常跑零影响**; 存档 `p6logs/24_*`。
- `run_tb_p4_chain.bat` → **P4 CHAIN OK** (exit 0) (chain 门删 halfdrop.memh + hd_n=0 恒不触发)。

**后修判据 (TL 修完后复用本注入当验收门)**: 同上命令, 期望 **BURST OK**, 且:
`HALFD 100 990 1 0` (哨兵归零, 不再冻结); ECOMAX ≤ 182; conn0 echo = 202 段连续 (严格分支);
**半帧段 echo 由 seq=S 整段重传补位** (seq=`0x12367FBD`, plen=1460, 载荷逐字节 == payload_map);
checker 打印 `HALFDROP 未复现合并/冻结` + `半帧段 echo: seq=12367FBD plen=1460 (seq=S 整段重传补位)`。
→ 若修复把残段字节计进 rcv_nxt, 重传段会变 OOO → echo 数 < 202 → 该门 FAIL (设计稿 `fend_trunc` 屏蔽
`pend_rcv` 已覆盖此点, 修时勿漏)。

**注意**: `halfdrop.memh` 常驻 sim/p4sim (与 trunc.memh 同), burstcheck 与 TB 读同一文件; chain 门/其他向量
由 bat 负责删除/重写。手工跑 gen_stim 时残留 halfdrop.memh 会带注入 (调试可用, 勿误判为回归)。

#### 热修 (同日): 第一版改动打破了 TRUNC 门 — 根因 = 刺激重构丢帧 (教训)

- **症状**: `TRUNC=100 TRUNCM=8 ...bat 200` FAIL: conn0 echo 99、`TRUNCS (100, 0)` (stat_drop_trunc 未走)、
  STATS_MAC 仅 122 帧 (测试流在注入点附近停摆)。RTL/TB/掩码/memh 残留均无关 (与协调者排除结论一致)。
- **根因 (单点)**: `build_rx_frames` 段循环原为 `if dfi == trunc_at: 改 fb/fcs` + **if 之后无条件 `add(...)`**;
  我加 half 分支时改写成 if/elif/else, `add('burst%d')` 被挂到 `else` 上 → **trunc 分支只重算载荷不再 add** →
  截断帧整个从刺激里消失 (PC 直接跳过该段), 其后 `healrem` 自 seq+8 起跳 → 板上判 OOO/空洞 → 停摆。
- **修复**: trunc 分支补回 `add('burst%d' % b, fb, fcs, 12)` (`tools/gen_stim_p4_chain.py:253`)。
- **教训**: 注入类改动必须跑**全门矩阵** — 本轮首验只跑了"注入门 + 无注入 + chain", 漏了 TRUNC 门 → 裸奔一轮。
  P4b-7-P6 四门 = ① `...bat 200` (无注入) ② `TRUNC=100 TRUNCM=8 ...bat 200`
  ③ `HALFDROP=100 HALFDROPK=990 ...bat 200` ④ `run_tb_p4_chain.bat`。

#### 修复后复跑 (TL 的 tcp_rx 半帧修复已在位: `rtl/tcp_rx.v` 含 `fend_trunc`) — 四门全绿

| 门 | 命令 | 结果 |
|---|---|---|
| 无注入 | `...bat 200` | **BURST OK**; echo 202; ECOMAX 182; RETX 0 |
| 截断 | `TRUNC=100 TRUNCM=8 ...bat 200` | **BURST OK**; `TRUNCS (100, 1)`; **echo 203**; ECOMAX 182 — 与历史基线 `p6logs/02_trunc100_m8.log` 逐数一致 (203/1/RETX 0) |
| 半帧中止 | `HALFDROP=100 HALFDROPK=990 ...bat 200` | **BURST OK**; `HALFD 100 990 1 0`; `TRUNCS (0, 1)` (半帧中止计入 stat_drop_trunc, 与设计稿一致); ECOMAX 182; echo 202; **半帧段 echo: seq=12367FBD plen=1460 (seq=S 整段重传补位)**; checker 打印 `HALFDROP 未复现合并/冻结` |
| chain | `run_tb_p4_chain.bat` | **P4 CHAIN OK** |

- 冻结彻底消除: 修复前 `HALFD ... 241113` + ECOMAX 257 → 修复后 `HALFD 100 990 1 0` (哨兵 0),
  xsim `HALFDROP n=100 k=990 fired=1 ECOMAX=182 TXSTUCK=0`。
- 注: 截断门 echo = **203** 而非 202 — 截断段按真实字节拆成 8B + 续传 1452B 两帧 echo (历史基线即 203);
  202 是无注入基线的数, 勿混。
- 存档: `p6logs/{27_halffix_k990_*, 28_trunc100_m8_afterfix.log, 29_base200_afterfix*}`。
- 截断其它变体亦复跑通过 (确认整条 trunc 路径恢复): `TRUNC=100 TRUNCM=10 ... 200` 与 `TRUNC=50 TRUNCM=6 ... 200`
  → BURST OK, `TRUNCS (100,1)` / `(50,1)`, 203 echo / RETX 0 — 与历史基线 `03_trunc100_m10.log` / `04_trunc50_m6.log`
  逐数一致 (存档 `p6logs/{30_trunc100_m10_afterfix.log, 31_trunc50_m6_afterfix.log}`)。

#### 四门矩阵**独立复跑** (测试 agent, 2026-09-12): 10/10 PASS, 与实现 agent 存档逐位一致

**方法**: 驱动脚本 `sim/p4sim/p6logs/indep/run_matrix.sh` — 每门开跑前删 `trunc.memh / halfdrop.memh / txdrop.memh`
(防残留), 每门记录 exit / 时长 / memh 落盘状态; **全程不改任何源文件**。日志与 resp 转储存档 `sim/p4sim/p6logs/indep/`。
跑的 RTL 即 TL 修复版 (`rtl/tcp_rx.v` 含 `fend_trunc`)。

| # | 门 | 命令 (Git Bash) | exit | conn0 echo | RETX | TRUNCS (n,stat) | HALFD (n,k,fired,stuck) | ECOMAX | STATS_MAC (fr,abort,eend) | 判据 |
|---|---|---|---|---|---|---|---|---|---|---|
| 1–3 | 无注入 ×3 | `run_tb_p4_burst.bat 200` | 0 | 202 | 0 | (0,0) | 0 0 0 0 | 182 | 208,0,0 | **PASS** |
| 4 | 截断 | `TRUNC=100 TRUNCM=8 ...bat 200` | 0 | 203 | 0 | (100,1) | 0 0 0 0 | 182 | 217,0,0 | **PASS** |
| 5 | 截断 | `TRUNC=100 TRUNCM=10 ...bat 200` | 0 | 203 | 0 | (100,1) | 0 0 0 0 | 182 | 217,0,0 | **PASS** |
| 6 | 截断 | `TRUNC=50 TRUNCM=6 ...bat 200` | 0 | 203 | 0 | (50,1) | 0 0 0 0 | 182 | 217,0,0 | **PASS** |
| 7 | 半帧中止 | `HALFDROP=100 HALFDROPK=990 ...bat 200` | 0 | 202 | 0 | (0,1) | **100 990 1 0** | 182 | 215,0,0 | **PASS** |
| 8 | 半帧中止 | `HALFDROP=100 HALFDROPK=22 ...bat 200` | 0 | 202 | 0 | (0,1) | **100 22 1 0** | 182 | 215,0,0 | **PASS** |
| 9 | chain | `run_tb_p4_chain.bat` | 0 | — (9RX/8TX frames) | — | (0,0) | — | — | — | **PASS** (`P4 CHAIN OK`) |
| 10 | TXDROP 回归 | `...bat 200 -1 0 4000 0 0 50` | 0 | 207 | **1** | (0,0) | 0 0 0 0 | 182 | 214,0,0 | **PASS** |
| 11 | 门控 | `...bat 200 0 0 10` (PCACK+PCWND1K) | 0 | 202 | 0 | (0,0) | 0 0 0 0 | 182 | 208,0,0 | **PASS** (TCBF snd_wnd=4096 生效) |

- 门 4/5/6 的截断支证据: `截断验证 echo plen=8/10/6 ack=00022D34/00022D36/0001100A (只确认真实字节)` +
  `dup-ACK 证据 8 帧纯 ACK` + `自愈覆盖并集完整 292016B`; 门 7/8 的 TB 行
  `HALFDROP n=100 k=990/22 fired=1 ECOMAX=182 TXSTUCK=0` (逐字读自存档 xsim log),
  checker 打印 `HALFDROP 未复现合并/冻结` + `半帧段 echo: seq=12367FBD plen=1460 (seq=S 整段重传补位)`。
- **门 8 (K=22) 修复前是 FAIL** (`ECOMAX 184` + 载荷整体位移 16B, 见 `23_half100_k22_*`): 修复后与 K=990 逐数一致
  — 残留半帧对 echo 侧零残留 (载荷逐字节 202 帧全等, echo 链连续无洞), 说明 `fend_trunc` 的丢弃与 K 无关。
- memh 落盘核对 (bat 每次重写是否可信): 门1 `0 8 / 0 0`; 门4–6 `100 8 / 100 10 / 50 6`; 门7–8 `100 990 / 100 22`;
  chain 门跑后 `trunc.memh/halfdrop.memh` 不存在 (删文件证据见下加严项 1, 该处为投毒后实测)。

**加严项 (超出规约, 均为发现型验证)**

1. **chain 防残留投毒实测**: 预先写 `trunc.memh=100 8 / halfdrop.memh=100 990 / txdrop.memh=50` 再跑
   `run_tb_p4_chain.bat` → 仍 `P4 CHAIN OK` (exit 0), 跑后三文件全空 = 泄露防护真的生效 (非"恰好没文件")。
   存档 `p6logs/indep/11_chain_leakcheck.txt`。
2. **逐位对照 (最强独立证据)**: `resp_p4_chain.memh` md5 —
   无注入 `56c2c81c…` 与**修复前**存档 `24/26_regress200_resp` 及**修复后** `29_base200_afterfix_resp`
   **三者完全相同** (fend_trunc 对无注入路径零影响, 逐位不变); 半帧 K=990 `7c206c41…`
   与实现 agent `27_halffix_k990_resp` **逐位相同**。检查器输出与 `27/28/30/31` 逐行一致
   (唯一差异 = 实现 agent 日志尾部多一行人工 `exit=0` 标签)。
3. **RAMB SDP "Memory Collision" 警告计数** (xsim 模型噪声, 非功能错): 基线 113 拍 = 修复前基线 `24` 的 113;
   注入跑 115 (修复前注入跑亦 115) → 计数只随刺激规模变, 修复未引入新警告。
4. 无注入基线跑了 **4 次** (规约 ×2; 第 4 次 `12_base_*` 为留档 xsim log 做警告计数对照), 四次 output 逐数一致
   (echo 202 / RETX 0 / ECOMAX 182 / MAC 208,0,0) — 无随机性。

**结论**: 半帧中止修复 (`fend_trunc` 合成 ferr 尾拍 + `pend_rcv/dup/ack_adv` 屏蔽) 在四门矩阵 + TXDROP/门控
回归下 **全绿**; 冻结签名 `TXSTUCK 241113 → 0`, ECOMAX 182 (上限内), 无注入行为逐位不变。
四门 + TXDROP/门控 5 命令组成的靶场可直接作为 P6 类改动的固定回归门 (总耗时约 13 min)。
**遗留 (未验, 供板测)**: 本矩阵只覆盖"半帧中止 + 后续重传自愈"的仿真形; 板上 PC/NIC 重启的真实半帧
是否每次都能在 `fend_trunc` 拍被捕获 (即 mac_rx 交付的残段拍 `tcrs=0 && 无 tlast` 的形态) 仍需 bitstream 实测。

### P4c 里程碑: 窗口扩张 12KB→48KB (2026-09-12 下午)

**瓶颈实证** (板级免费项验证): 吞吐 125.5Mbps = 12KB 窗口 ÷ ~96us burst 周期
(PC ACK 节奏主导; RTT 中位 104us 非瓶颈; echo 84% 帧 <20us 爆发式; delayed
ACK 关反而 -59% = ACK 洪水挤 TCB 写仲裁)。主线 = 扩窗口。

**实现 (agent)**: HLS SYN-ACK 0x3000→0xC000 (免 WS 避 P4b-6 死锁); echo FIFO
4096→8192 字 (fq/cq 加宽); retx_ram 16→64KB/连接 (TL 批准偏离 48KB: 2 幂掩码
回绕零组合逻辑 + 最坏在飞 53244>48KB 会损坏数据); RING_CAP/win_cap 0xBFFE;
slow_cfg_adp rcv_wnd 0xC000; TB 期望同步; HLS 网表重建核验 (8'd192)。四门矩阵
+ retx_ram/frame_fifo 单元 TB 全绿。

**时序崩 (审查 P1-1 应验)**: WNS -0.848, 912 端点全在 retx_ram 写地址族 —
FSM 状态 → 256 片 RAMB36 ADDRBWRADDR 的布线拥塞 (logic 1.5ns + route 6.3ns,
80% 布线)。修复中: 写地址寄存器化 + bank 复制 → 不够则内部递增器 (顺序写
只给帧首基址) → 再不够 TL 裁决砍连接数 16→12 (256→192 片)。

**审查 P2 处置**: P2-3 uart_dbg 12 位别名 (agent 修中); P2-4 frame_fifo 单元
TB 补 D=8192; P2-5 tcp_synp.v 0x3000 残留; P2-6 HLS csim 窗口断言; P1-2
已由 TXDROP=50 RETX=1 覆盖; P2-7 (0xBFFE 帽仿真不绑定) 板测兜底。

### P4c 测试矩阵独立复跑 (2026-09-12 晚, 独立测试 agent)

**任务**: P4c = 窗口 12KB→48KB + retx_ram 16→64KB/连接 (读地址输入寄存器化, 读延迟 1→2 拍,
环形消费窗口移 1 拍) + echo FIFO 4096→8192 字。对实现 agent 的"全绿"自报做独立复核:
逐条重跑 8 命令仿真门 + 2 个单元 TB (**只跑测试, 未改任何源文件**)。

**方法 / 溯源**
- 驱动: `sim/p4sim/p6logs/indep4c/run_matrix4c.sh` (首轮 01-10 门)、`run_matrix4c_rerun.sh`
  (冻结复跑 11-18 门)、`probe_txdrop.sh` (TXDROP 落点判别 19-20)。每门: 先清注入 memh, 记
  exit/时长/resp md5/对端 ACK 事件数/RAMB 碰撞条数/GATEPROBE, 逐门归档 resp 与 xsim 日志;
  汇总 = `summary.txt` / `summary2.txt` / `probe_summary.txt`。
- 指纹: `00_rev_fingerprint{,2}.txt` = 全部输入 (rtl/*.v、tb/*.v、tools/gen_stim_p4_chain.py、
  HLS 网表 udp_echo.v) 的 md5+mtime。
- 独立反查 (结论不依赖 checker/TCBF 自证): `check_wnd.py` 直读 GMII 捕获里的 TCP 窗口字段/plen,
  `classify.py` 帧分类, `dset.py` (seq,plen) 集合比较, `framediff.py` 按 seq 对齐逐帧逐字节 diff,
  `burstdump.py`/`maskloc.py` 定位被遮罩帧。
- **首轮中途源文件被并行 agent 改写 (前提)**: `tb/tb_p4_chain.v` 于 **18:58:43** 被改
  (md5 `cea2ef98…` → `9b445fb9…`), 唯一语义改动 = `.cfg_suppress_data_ack(1'b1)` → `1'b0`
  (注释 "P4c: 与板上 wrapper_p4 一致 (数据 ACK 提前)")。逐文件核对: RTL (retx_ram 17:48、
  tcp_tx_frame 17:49、tcp_rx 15:34、tcb 15:20、tcp_echo 15:21、slow_cfg_adp 15:22、tcp_synp
  16:32)、HLS 网表、单元 TB、gen_stim 全部未动。⇒ 首轮 01-04 门跑的是**旧 TB**、06-08 门是
  **新 TB**, 首轮只能作混合 revision 参考; 19:10 起在冻结 revision (新 TB `9b445fb9`) 上整轮
  复跑 = 表 2, **结论一律以表 2 为准**。交叉核对 `board/wrapper_p4.v:599` = `1'b0` ⇒ 新 TB 才与
  板上一致 (旧 TB 的 1'b1 是历史仿真专用配置)。副作用: 每个数据段多一个独立纯 ACK 上线
  (base 门 STATS_TX 406 帧 = 203 数据 + 203 ACK; 旧 TB 同场景只有 203 帧)。

**表 1 首轮 (混合 revision, 仅参考, 不作结论依据)**

| # | 门 | 命令 | rc | 关键数 | 判 |
|---|---|---|---|---|---|
| 01 | base run1 | `run_tb_p4_burst.bat 200` | 0 | echo 202 / RETX 0 / ECOMAX 182 / MAC(208,0,0) / md5 f46b0c91 | OK |
| 02 | base run2 | 同上 | 0 | md5 与 01 全等 (同命令确定性) | OK |
| 03 | TRUNC | `TRUNC=100 TRUNCM=8 … 200` | 0 | echo 203 / 33 dup-ACK 全 =00022D34 / TRUNCS(100,1) / MAC(242,0,0) | OK |
| 04 | HALFDROP | `HALFDROP=100 HALFDROPK=990 … 200` | 0 | fired=1 / TXSTUCK 0 / MAC(240,0,0) | OK |
| 05 | chain | `run_tb_p4_chain.bat` | 1 | 13s 无任何仿真产物 (resp md5 仍是 04 的 58500eef, 未重写) | FAIL (环境) |
| 06 | TXDROP=50 | `… 200 -1 0 4000 0 0 50` | 1 | `RETX 0 != 期望 1`, 且捕获与 base **md5 全等** = 注入完全未生效 | FAIL (环境) |
| 07 | 门控 PCWND1K | `… 200 0 0 10` | 0 | TCBF snd_wnd 4096 / MAC(411,0,0) / md5 26df22a1 | OK |
| 08 | dupstorm | `… 200 0 0 4000 608 dup` | 0 | echo 202 / 247 ACK / MAC(455,0,0) | OK |
| 09 | retx_ram 单元 | `sim/retxsim/run_retx_tb.bat` | 0 | ALL 7 GROUPS PASS | OK |
| 10 | frame_fifo 单元 | `sim/retxsim2/run_tb_frame_fifo.bat <rtl/frame_fifo.v>` | 0 | PASS_ALL (D=8192 f1/f2/f3) | OK |

**表 2 冻结复跑 (tb 9b445fb9 = 当前工作区; 19-20 为 TXDROP 落点判别实验)**

| # | 门 | 命令 | rc | 关键数 | 判 |
|---|---|---|---|---|---|
| 11 | base | `… 200` | 0 | md5 6c614777; echo 202 无洞; STATS7(407,0,0,0,0,203,292036); STATS_TX(406,292036,203,0); MAC(411,0,0); TCBF rcv_wnd 49152 / snd_wnd 65535 | OK |
| 12 | base 复跑 | 同上 | 0 | md5 与 11 **全等** (确定性) | OK |
| 13 | TRUNC | `TRUNC=100 TRUNCM=8 … 200` | 1 | TRUNCS(100,1)✓ 载荷 203 帧全等✓ 无洞✓, 但 checker "纯 ACK 必全 =00022D34" 断言被逐段数据 ACK 打中 | FAIL (判据失配) |
| 14 | HALFDROP | `HALFDROP=100 HALFDROPK=990 … 200` | 0 | fired=1 / TXSTUCK 0 / 半帧段整段重传补位 (seq=12367FBD plen=1460) / MAC(443,0,0) / md5 942cf605 | OK |
| 15 | chain | `run_tb_p4_chain.bat` | 1 | 36s 正常仿真; 4 条 MISMATCH (fast count 6≠3 / ACK events 3≠0 / STATS7 ack 3≠0 / STATS_TX(6,36,3,0)) = suppress=0 新基线; DUT 段数/字节/abort 与期望一致 | FAIL (判据失配) |
| 16 | TXDROP=50 | `… 200 -1 0 4000 0 0 50` | 1 | RETX 0≠1; 数据帧 203/203 **逐字节全等**无洞, 但纯 ACK 203→202 = 遮罩落在**纯 ACK 帧** (burst[102] 1 字节前导碎片); STATS_TX bytes 292036 (无回放) | FAIL (注入失效) |
| 17 | 门控 PCWND1K | `… 200 0 0 10` | 0 | TCBF snd_wnd 4096; md5 26df22a1 与首轮 07 全等 | OK |
| 18 | dupstorm | `… 200 0 0 4000 608 dup` | 0 | echo 202 / 247 ACK / MAC(455,0,0); md5 6fdc198c 与首轮 08 全等 | OK |
| 19 | TXDROP=51 判别 | `… 200 -1 0 4000 0 0 51` | 1 | 同 16: 纯 ACK 203→202, 碎片 burst[104], RETX 0 | FAIL (注入失效) |
| 20 | TXDROP=2 判别 | `… 200 -1 0 4000 0 0 2` | 1 | 同 16: 纯 ACK 203→202, 碎片 burst[6], RETX 0 | FAIL (注入失效) |

(09/10 单元 TB 冻结复跑未再跑: RTL/单元 TB 指纹与首轮逐字节相同 = 同一份被测源, 结果沿用。)

**P4c 判据逐条核对**

1. **48K 窗口真上线 — ✓ (独立证据, 不经 checker)**: `check_wnd.py` 直读线上字段: SYN|ACK
   window = 49152; conn0 数据帧 202 帧全部 49152 (唯一例外 6144 = conn1 那帧, 即 TCBF 里 conn1
   的 rcv_wnd, P4c 未改 conn1); 纯 ACK 同 (202 conn0 @49152 + 1 conn1 @6144)。TCBF rcv_wnd =
   49152 (0xC000) 全门一致。与 pre-P4c 基线 (`indep/12_base_resp.memh`, 14:40) 按 seq 对齐逐帧
   逐字节 diff (203 帧, 长度全等): **载荷区 (eth[54:]) 差异 0 字节**, 差异仅 = TCP 窗口高字节
   (eth[48] 0x30→0xC0, 202 帧) + TCP 校验和 (eth[50]/[51]) —— 纯代码变更的线上足迹与宣称一致。
   附精确化: 线上实测 pre-P4c = 数据窗口 12288 (0x3000) / SYN|ACK 65535, P4c 后 = 49152/49152
   (SYN-ACK 与数据窗口自洽); 上文 "HLS SYN-ACK 0x3000→0xC000" 的 0x3000 实为数据窗口值。
2. **snd_wnd 门语义 — ✓**: 对端通告 4096 的门 (17) TCBF snd_wnd = 4096 (0x1000), 其余门 65535
   (饱和) ✓。门控定向探针 GATEPROBE (P6 冻结修复的回归哨兵): 全门 wro=0 (**零"误开窗口"** =
   不会提前启动帧), runmax=1 / oprun=0 / clrun=1 (失配全是单拍瞬态), 64K 跨界探针 strad 6789
   拍中注册门误关仅 strmm 0-3 拍, blk 27-52 拍只让活帧晚 1 拍启动 ⇒ 48K 窗口下门控与设计一致。
3. **重传回放在 2 拍读延迟契约下逐字节复现 (TXDROP: union 无洞 + RETX≥1) — ✗ 未验证** (根因 A)。
4. **ECOMAX/abort/eend/载荷/截断/半帧 — ✓**: 全门 ECOMAX=182 (上限内); STATS_MAC abort=0、
   tx_stat_eend=0; 载荷逐字节全等 (含 ring 重放帧); TRUNCS(100,1) + "截断验证: echo
   seq=12367FBD plen=8 ack=00022D34" ✓; HALFDROP fired=1 / TXSTUCK=0 (P6 冻结哨兵在 P4c 下仍
   0) + 半帧段被整段重传补位; dupstorm 273272 字节无洞。
5. **单元 TB — ✓**: retx_ram 7 组全 PASS, 含 **GRP E 延迟恰 2 拍** (不断言 <1、不断言 =1、恰 =2
   + 释放后保持) 与 GRP G 流式 back-to-back 读对齐 2 拍契约; frame_fifo D=8192: f1 (8191 非满 /
   8192 满 / 排空逐字节), f2 soak 512k-1/512k 拍钉满 (occ=8191, full-cycles=5405, wptr 回卷 66),
   f3 指针回卷后 snap/rollback ✓。

**FAIL 根因 A — TXDROP 注入在 suppress=0 下系统性遮错帧 (遮纯 ACK, 不丢数据)**

证据链 (gate 16 + 判别 19/20):
- 数据帧**零损失**: 203 数据帧 (seq,plen) 集合与 base 门完全一致 (对称差 0、重复 seq 0、逐帧
  逐字节 diff 0 字节), STATS_TX bytes = 292036 = 200×1460+16 = **无任何回放字节**;
- 但**纯 ACK 少一个**: 203→202, 被遮位置留下 "1/7 字节前导碎片" burst (gate16 burst[102] len=1、
  gate19 burst[104] len=1、gate20 burst[6] len=7) = 窗口在帧首拍后打开, 整帧 60B ACK 消失;
  落点随索引**线性平移** (索引 2→burst[6]、50→burst[102]、51→burst[104], 即每个 conn0 数据帧
  对应 2 个 TX 帧: 数据+纯 ACK), 三条索引**全部**落在 ACK 上;
- 后果: 对端模型只跟踪 conn0 数据帧 (tb 933-936 行: flags 0x18 + sport 1F90 + dport 3039 +
  IP len>40), 看不到数据空洞 ⇒ `exp_seq` 不后移 ⇒ 无 OOO ⇒ 无 dup-ACK ⇒ DUT 无 `retx_req`
  ⇒ RETX=0 ⇒ `MISMATCH: RETX 0 != 期望 1` ⇒ BURST FAIL;
- 机制: TB 两阶段注入 = "arm 设于第 N 个 conn0 数据帧 `start_data` (data_cnt==N-1), 窗口开在此后
  **第一个** `u_mactx.state==S_PRE`, 关在其 S_IFG" (tb 966-993 行) —— 它**不跟踪被 arm 的那一帧**,
  遮的是"当时排到 mac 队首的帧"。旧 TB (suppress=1) TX 流里只有数据帧 ⇒ P6 时代该门能丢中数据帧
  (`indep/09_extra_txdrop50.txt`: RETX=1, STATS_TX (209,300796,0,0) = 回放 6×1460=8760B, conn0
  echo 207); 换成 suppress=0 (= 板上配置) 后数据/ACK 在 TX FIFO 里 1:1 交替, 队首固定为 ACK
  ⇒ 注入**必然**打空, 与索引无关;
- 结论: **注入标定失效 (测试侧)**, 非数据面回归 (载荷/无洞/ECOMAX/abort 全绿)。但它同时**否掉了
  上文"审查 P2 处置: P1-2 已由 TXDROP=50 RETX=1 覆盖"的依据** —— 本 revision 下该门根本没造成
  数据丢包; 而 P4c 恰恰改了重传回放路径 (读延迟 1→2 拍 + 消费窗口移 1 拍), 所以**"重传回放在新
  契约下逐字节复现"这条判据目前空白 (未验证)**, 不能计入绿;
- 修复建议: 注入改为**按帧头内容匹配** (mac 侧按 flags=0x18/seq 计数第 N 个 conn0 数据帧, 或 arm
  时记下该帧 seq 并在 S_PRE 比 seq), 不再数 `start_data` + 取"第一个 S_PRE"; 修好后同命令复跑,
  期望: 数据帧少 1 / RETX=1 / STATS_TX bytes > 292036 / union 靠回放补齐无洞。

**FAIL 根因 B — TRUNC / chain 两门 checker 期望值未随 suppress=0 同步 (判据失配, 非 DUT)**

- gate 13: `MISMATCH: 板上纯 ACK ack 号 ['000003EF','000003F8','000009AC','00000F60'] 含非
  00022D34`。该断言写作于 suppress=1 时代 —— 那时线上纯 ACK 只有 OOO dup-ACK 那 33 个 (首轮
  gate 03 证据: "dup-ACK 证据: 33 帧纯 ACK 全部 ack=00022D34"); suppress=0 后线上纯 ACK = 237
  = **33 dup-ACK + ~204 逐段累计 ACK** (与 base 门 203 逐段 ACK 同源) ⇒ 断言必失败。该门其余
  判据全绿 (见判据 4 行): 载荷 203 帧逐字节全等 / merge 干净 / 截断验证 ✓ / MAC(446,0,0)。
- gate 15 (chain): 4 条 MISMATCH 同一根因 (帧数与 ACK 数翻倍): fast count 6≠3 (= 3 数据 + 3 纯
  ACK), ACK events 3≠0, STATS7 ack 3≠0, STATS_TX(6,36,3,0); DUT 段数/字节与期望一致,
  MAC abort/eend=0 ⇒ 期望值没跟上配置。
- 修复建议: checker 按 `cfg_suppress_data_ack` 分支区分"逐段累计 ACK"与"OOO dup-ACK"两类期望
  (gen_stim 里硬编码的 fast count / ACK events / STATS7.ack / STATS_TX 同样要按配置分支)。
- 首轮两处异常再定性: gate 05 (13s、无任何仿真产物) 与 gate 06 (注入完全未生效、捕获与 base
  md5 全等) = **与并行 agent 共用 sim/p4sim 目录的竞争** (对方 bat 收尾会 `del txdrop.memh`, 并
  用同名 stim_*.memh / resp_p4_chain.memh / xsim.dir 快照) —— 冻结复跑独占目录后 gate 15/16 给出
  真实结果。**教训: 验证矩阵期间 sim 目录必须独占、被测源文件必须冻结。**

**结论**

- **P4c 主项 (48K 窗口 + 2 拍读延迟 + 8192 echo FIFO) 通过独立复核**: 窗口字段 49152 真上线且与
  pre-P4c 逐帧 diff 只差窗口/校验和字节 (载荷 0 字节差异); snd_wnd 门语义正确; 门控零"误开";
  ECOMAX / abort / eend / 载荷 / 截断 / 半帧中止 (含 P6 冻结哨兵) 全部保持; 两个单元 TB (含
  GRP E 延迟恰 2 拍、D=8192 soak) 全过; 同命令复跑 md5 全等 (确定性)。
- **8 门里 3 门 FAIL, 全部落在测试侧, 未见数据面回归**: 2 门 = checker 期望未随 suppress=0 同步;
  1 门 = TXDROP 注入标定在 suppress=0 下系统性遮错帧。**但 P4c 明确要求的"重传回放逐字节复现"
  判据目前无法验证**, 且它正对 P4c 最敏感的路径 (retx 读延迟 + 消费窗口), 不能计入绿 ⇒
  实现 agent 的"全绿"自报**不成立**, 需按根因 A/B 修复后重跑本矩阵 (约 30 min: 8 门 + 2 单元 TB)。
- 板测提示: suppress=0 (= wrapper 现状) 下每个数据段带一个独立纯 ACK, 线上 TX 帧数翻倍 (base 门
  MAC 411 帧 = 203 数据 + 203 ACK + 5 慢路径; STATS_TX 406), 即 P6 记过的 "ACK 洪水挤 TCB 写
  仲裁" 形态; 若板测吞吐不达预期, 优先回看该配置与 ACK 节奏。

### P4c 板级首轮 + ACK-early 实验 (2026-09-12 傍晚)

**P4c 首轮板测**: 窗口 48KB 用满 (PC 在飞 45-48KB 实锤, SYN-ACK 49152 字节级验证)
但吞吐 124Mbps 不变 — **echo 架构铁律**: 吞吐 = 1460B/12us ≈ 125Mbps 与窗口无关
(窗口×4 时 echo 帧级判定排队延迟也×4, 精确抵消)。

**PC 侧调优全堵死**: TcpAckFrequency=1 (-59%, ACK 洪水挤 TCB 仲裁) /
InterruptModeration 关 (-40%, 中断洪水) / TcpDelAckTicks=0 (连接 reset) /
AckFrequency=2+DelAckTicks=0 (无变化)。PC ack 推进时间线显示 40ms 级 delayed
ACK 死区, 但消除后仍无收益 → 瓶颈在板侧帧级判定排队。

**ACK-early 实验** (cfg_suppress_data_ack=0, 设计预留开关): TB 绿; 板级:
①SYN 无应答 (重烧后恢复 — 跑坏残留态, 非天生) ②吞吐 17.6Mbps 暴跌 (TX 线速
发 ACK/echo 1:1 交替, PC 发帧却慢到 890 帧/s — PC 窗口推不动) ③两轮测试均
ConnectionResetError ④LED latched=1 (RTO 回卷发生过)。板级行为复杂, 回 sim
钉语义: TB checker 按 suppress 分支 + TXDROP 注入按帧头匹配 (测试 agent 发现
旧注入在 suppress=0 下遮的是 ACK 帧, 重传回放路径验证空白 — P4c 核心风险)
+ UART 静默 (P2-3 板级回归嫌疑)。待 agent 三项报告。

### P4c ACK-early 破案 + 全矩阵收官 (2026-09-12 晚)

**三任务完成 (TL 接手)**:

1. **TRUNC/chain checker 同步**: chain 期望随 suppress=0 同步 — GMII 实测帧序
   每段 [纯 ACK(seq=snd_nxt, ack=rcv_nxt推进), echo] 交替, exp_fast 加 ACK 条目
   (顺带复活 "echo before its ACK" 时序检查), ACK 事件/STATS7/STATS_TX 期望
   同步; TRUNC 判据③改**位置合法性**: 正常段推进 / 截断段+窗口内 OOO 停
   s_tr+trunc_len / 补缺口段 s_tr+1460 / 重放段推进无回退。窗口内 OOO 段数 =
   (rcv_wnd-1452)//1460+1 = 33 (48K 窗) — **窗口外 OOO 静默是 tcp_rx 设计行为**
   (TRUNC=100/200 实测 33 帧 dup-ACK, 判据 v1 误报 FAIL)。

2. **UART 静默**: uart_dbg 单元 TB ALL_OK (P2-3 12→13 位修复 sim 侧干净);
   板级静默 = 旧 bitstream (P2-3 未修) + ACK-early 残留态叠加, uart_run 上电
   1.2s 即触发 — 新 bitstream 板测应自然复活。

3. **ACK-early 帧序破案 (P4c 核心)**: 板级 ack_slow.pcapng frame 2436 —
   PC 满窗 (48KB 耗尽) 停发后发纯 ACK, seq = PC snd_nxt = FPGA rcv_nxt+49152
   **恰在窗口右沿**; 旧 tcp_rx 对 seq 非边界纯 ACK (win_ok 严格 < wnd) 无
   fend/S_DROP → **ACK 信息静默丢弃 → snd_una 停滞 → RTO 回卷风暴**
   (抓包 2446/2449/2452 三连 100ms 重发 + PC 重传, 与板级 17.6Mbps 暴跌同构)。
   suppress=1 时代 PC 窗口从不耗尽 (echo piggyback 推进慢) → 纯 ACK 罕见 →
   机制潜伏。**修复**: w6a_ok = base_ok && plen==0 && (seq_diff <= rcv_wnd ||
   seq_lt) (RFC 零长段含右沿); w6 拍 tlast 走 fend_w6a, 60B 带填充帧走 S_PAD
   (fend_pad), ACK/窗口字段照常 pend_una/pend_wnd。**复现**: TB +PCACKOOB
   (注入 ACK seq=窗口右沿) — HEAD 版 FAIL (RETX=1, snd_una 停滞 305419897,
   echo 63≠32, 63 帧 ACK 全 nonmatch) / 修复版 OK (全推进无洞)。闭环成立。

**全矩阵绿 (tcp_rx 修复后复跑)**: chain / burst200 base / TRUNC=50,100 /
HALFDROP=50k6,100k990 / TXDROP=50 (55,200) / gate4096 / dupstorm /
PCACKOOB / uart_dbg / retx_ram (7 GRP, 含 latency=2cyc) / frame_fifo (D=8192)。
待办: 板级重建烧录 + ACK-early 吞吐重测 (修复后 suppress=0 预期 ~900Mbps
破 echo 铁律) + UART 复活确认。

### P4c 板级重建 + UART 复活 (2026-09-12 晚)

- 板级重建: WNS=+0.271 WHS=+0.022 (tcp_rx w6a 修复未伤时序), bitstream 0 错 0 警
- 烧录 PROGRAM_OK (DONE=HIGH)
- **UART 静默真凶 = CH340 USB 设备挂死** (COM8 打开报"设备没有发挥作用", 设备树
  状态 OK 但端口句柄卡死; Disable/Enable 重新枚举即复活)。快照行完整 (443 字符
  + TL 位图, WPT/RPT 4 位 hex 板级确认); 上电快照: HLS 活 (SC=16 SF=4 HR=1),
  TCB 空, MW=366。板级静默与 bitstream/P2-3 无关。
- 待: ACK-early 64MB 吞吐重测结果 (修复后 suppress=0 预期 ~900Mbps)

### P4c ACK-early 板级复测 + 最终裁决 (2026-09-12 深夜)

**64MB 板测 (suppress=0 + w6a 修复)**: 数据完整收齐 (无 RST, echo 64MB 全等),
snd_una 完全推进 (UA=NX=0x12402151 — ACK 丢弃 bug 修复板级实锤)。但吞吐
28.4Mbps < 124Mbps 基线, PC 重传 3917 帧, 51 次 ~285ms RTO 停发 (264/307ms
交替 = RTO 退避, 占总时长 77%)。

**机制定位** (UART 终态快照 + RXT 环 + tshark 三方对账):
- TRU=32 截断帧 (FPGA 唯一观察点; tshark 是 NDIS 层抓不到线级截断 —
  P4b-7-P6 怪帧机制复发); RXT 环冻结现场 0x71120E2 = S_PAY/accept=0 背压
  卡 64+ 拍/pay_r=14/pcount=226 = ~240B 处中断的线级截断帧
- drop_seq=1791 = PC RTO 重传的重复段 (51 次 × ~35 帧, FPGA 正确丢弃);
  CW 进-出差额 725 词 = slow 路词 (words_out 只计 fast), 非丢弃
- PC 发帧结构: 48K 帧 us 级连发 (线速正常) + 周期性停发 = PC 网卡 TX 截断
  与 FPGA->PC 线丢 (缺陷 A) 在 TX 帧率翻倍下触发率上升 -> RTO 自愈周期
- UART 静默真凶: CH340 USB 挂死 (COM8 "设备没有发挥作用", 设备树 OK;
  Disable/Enable 重新枚举即复活) — 与 bitstream/P2-3 无关

**裁决**: ACK-early 失败于线级物理层 (PC Killer 网卡 TX DMA 截断 + 缺陷 A),
非 RTL。RTL w6a 修复保留 (纯 ACK 窗口内接受 = RFC 零长段正确性, 防潜伏
bug); 板级 cfg_suppress_data_ack 回 1 (124Mbps 稳定基线); TB 保持 suppress=0
(验证 ACK 路径全功能 + PCACKOOB 门)。P4c 冲 1G 结论: **瓶颈已从 FPGA 架构
(125Mbps 帧级判定铁律) 转移到 PC 网卡/线级物理层**, FPGA 侧可做项已尽。

### P4c suppress=1 回归复测 (2026-09-12 深夜)

- 重建烧录 (WNS=0.237 WHS=0.034), 64MB 板测: echo 完整收齐 67108864 B,
  稳态 (10-90%) 105.9 Mbps, exit 0。PC 重传 1614 帧偏多 (本次线级丢帧
  波动) 但自愈完整。P4c 里程碑收尾: 窗口 48KB + retx_ram 64KB + w6a 纯 ACK
  修复 + 全矩阵绿, 板级基线稳定 (~106-124Mbps 区间 = 线级波动带)。

### P4d 修补包 小项1: w6 截断支 TB 用例 (2026-09-19)

TRUNC 注入放宽 M=0..2: 帧体 54+M ≤ 56B 无 pad (finish 的 60B 补零会把
tlast 推到 w7 走 S_PAY) → tlast 落 w6 拍走 fend_w6t。验证:
- RTL 行为 ✓: 截断段无短 echo (0 字节交付), fend_w6t 闭合边界, rcv_nxt
  不推进 (ACK/dup-ACK 停 s_tr), stat_drop_trunc 计数, healrem 整段重传
  (PC RTO 从 s_tr 起 1460B — 修正 gen_stim 模型旧假设"从 s_tr+M 起补缺口",
  那是 S_PAY 截断语义) 回显 1460B
- 三边界门绿: M=0 (54B) / M=1 (55B) / M=2 (56B); TRUNC=8/chain 回归绿
- 判据② M≤2 分支: 断言无 plen≤2 的 e_tr echo (healrem echo 也在 seq=e_tr
  但 plen=1460, 按 plen 区分)

### P4d 修补包 小项2: TCP 主动连接 (客户端) (2026-09-19)

**设计**: ACTIVE_CONNECT 宏 (默认 0 关) — 上电等 ACTIVE_DELAY 后自动向
ACTIVE_IP:ACTIVE_PORT 主动连接。ARP 前置 (who-has 限次, 新 arp_lookup_l1
8 项每拍廉价探测 — 完整 arp_lookup 的 L2 顺序扫描 ~800 拍/次, 每拍调用把
顶层 pass 拉长 30 倍, xsim PROBE 实测被动握手 3.7k→55k 拍) → 占**最高**
空闲槽 (低槽留给被动分配序) → SYN (seq=ACTIVE_ISS + MSS 1460) →
T_SYN_SENT 收 SYN+ACK (ack==ISS+1) → tcp_parse_opts (从被动分支提取共用) →
cfg_write(ADD) 先于纯 ACK (P4b-6 死锁教训) → T_ESTABLISHED; RST→T_FREE;
SYN 限次重传超限释放半开槽 (P4b-5), 回等待可重试。与被动监听共存。

**验证**: csynth 0 ERROR / Fmax 156.92MHz / 网表核验 (grp_tcp_active_tick,
T_SYN_SENT=5, ACTIVE_ISS/IP/PORT 全进网表); TB +PCACTIVE 反应式 PC 模型
(GMII 捕获板侧主动 SYN → 注入 ARP reply/SYN+ACK/100B 数据; sim 网表
-DACTIVE_IP=0xC0A86463=192.168.100.99 逼出 ARP who-has 路径, 板级默认宏
192.168.100.1) — PCACTIVE OK: 三连接共存 (conn0 被动 + conn1 预置 + 主动
conn2), 数据段全收全回 nm=0; 回归 chain/burst 绿; rtl/ 零改动 (数据面冻结)。

**TL 复核**: HLS diff 逐段核验 (重传 seq-- 补偿 tcp_send SYN +1 / cfg 字段
逐项对齐 T_LISTEN / 槽位选择不碰 T_LISTEN) + PCACTIVE/activecheck 复跑绿 +
回归复跑绿。提交 a1980fc。

**P2 文档对齐 (2026-09-19 TL 复核)**: k_syn = SYN 捕获拍, 随网表/激励时序
变化, 不是固定量 — 提交 a1980fc 报文写 70499, 审查侧产物 probe_run.log
(PROBE 调试运行, 网表时序不同) 记 204483。2026-09-19 P1 修复轮复跑标准
PCACTIVE 门 (active 网表 ACTIVE_DELAY=2000 + TCP_RTO_MIN=100000) 实测
`iss=89abcdef k_syn=70499` — 与 a1980fc 报文一致。引用时注明运行配置,
勿把两者混为一谈 (commit 报文不改)。

### P4d 修补包 小项3: VLAN fast path (2026-09-19)

**方案**: 新模块 rtl/vlan_strip.v (mac_rx_64 → vlan_strip → rx_classify) —
单层 802.1Q/1ad tag (TPID+TCI 4B) 从字节流删除, 下游 (classify/tcp_rx)
零改动回到无 tag 布局。字节映射 (TL 任务书原公式是 2 字节位移笔误,
agent 按字节映射推导纠正): out_w1={in_w1[63:32],in_w2[63:32]},
out_wk(k≥2)={in_w{k}[31:0],in_w{k+1}[63:32]} (等价: 第 k 输入字到拍拼出输出字
k-1)。tlast 边界: 末输入字低半无有效
→ 同拍; 否则 S_TAIL 尾拍 (上游停 1 拍, mac 8 深 FIFO 吸收)。VLAN 帧 tag
字处 1 气泡 + 帧尾 ≤1 拍停顿, 1G 帧间隔 ≥1.5 字拍天然吸收 (202 帧零丢实测)。
QinQ 剥一层后自然退化慢路径; 上游残段 (tuser) 有恢复支不卡死。

**验证**: 单元 TB 65 VLAN 帧逐字全等 (1586→1493 词) + chain VLAN
(STRIPPED=2 OK) + burst 200 VLAN (STRIPPED=202 OK, RETX=0, 292016B 逐字节
全等) + 默认门回归 (STRIPPED=0, TRUNC/HALFDROP 复跑绿); 板级构建
WNS=+0.401 (基线 +0.237, 不退化)。TL 复核复跑全绿。提交 683837b/bf8b262/
932f6ee/0f8c523。

### P4d 板级验收 第一天: RTO 重放 ACK 拒收死锁 (2026-09-19)

**现象**: 烧 P1-fix bitstream (含 vlan_strip) 跑 32MB 速率测试, ~1.5MB 处板侧停摆,
PC RTO 退避 (2.6/5/9.8s) 后 RST; UART 快照 = 真死锁 (TXST=0 S_IDLE 空转,
RXST=1 S_PAY + EMV=1, echo fifo 8192 字全满, 全计数器冻结)。

**抓包解码 (决定性)**: 板侧 seq 最大值恒 = 5,507,085 (t=0.486s 后再无新字节),
同一 51,100 字节窗口被重放 17 轮 (每 ~100ms = RTO 周期; 560 个 replay 帧);
PC 的 ACK 恒 = 5,508,545 (= 板侧高水位, "我全收到了")。

**根因链 (逐环实证)**:
1. 窗口填满: in-flight = 0xC79C = 51,100 = **恰 35×1460** (含 1 拍陈旧门控越界量
   vs RING_CAP 49,150); PC 随后停发 ACK (延迟 ACK/收缓冲)。
2. RTO → svc 回卷 snd_nxt := snd_una, tx_frame 存高水位 retx_hi = 5,508,545。
3. 重放 35 帧 (ring 源帧绕过窗口门), 每帧推进 snd_nxt。
4. **PC 的 ACK 撞进重放期**: 此时 snd_nxt < 5,508,545 → tcp_rx 的
   `ack_ok = (ack-snd_una) <= (snd_nxt-snd_una)` 判 ack > snd_nxt → **拒绝**
   (时间线: 末帧 8581 起始 t=1.9989135 + 12.1us 传输 = S_DONE ~1.9989256;
   PC 末 ACK 8582 t=1.9989175 → 早 ~5us)。
5. 重放完成 snd_nxt 回到高水位, 但 **PC 不再发 ACK** (已确认全部数据, 无新数据
   可 ACK; 重放帧诱发的 dup-ACK 被 Windows 大量抑制 — 21 重放帧只 5 个 ACK)。
6. snd_una 永久冻结 → in-flight 恒 = 满窗 → win_open 恒 0 → start_data = 0 →
   echo 管道 (8192 字满) 反压 tcp_rx → **整条 fast path 死锁**, 仅靠下个 RTO
   再回卷再重放, 循环不止。

**本质**: 回卷暂时降低 snd_nxt 破坏"已发送字节单调"假设 → 对端对已到达数据的
合法 ACK 被丢, 而 TCP 不重传 ACK → 无自愈路径。**P4c 窗口 12KB→48KB 使重放
时长 ×4 (~420us), ACK 落进重放期概率大增** → 潜伏 bug (P4b-7 起存在) 现在必现;
P4b-7/P4c 此前通过属时序未撞。**与 vlan_strip 无关** (排查中证).

**修复方向** (agent 实施中): 会话期 ACK 有效上界 = retx_hi (回卷前 snd_nxt =
真正发送过的字节), 即 tcp_rx 的 ack_ok 用 `retx_active ? retx_hi : snd_nxt`;
tx_frame 暴露 retx_hi/retx_active 两个纯线束输出。会话结束 snd_nxt 已追回
retx_hi, 自动回原语义。TB 补 +PCSTALL 复现门 (窗口填满停 ACK → 重放期注入
高水位 ACK → 断言 snd_nxt 继续前进; 修复前必须 FAIL)。

### P4d-fix 实施记录 (agent, 同日): 会话高水位 ACK 上界 + PCSTALL 复现门

**RTL 改动 (3 文件, 与 TL 方案逐字一致)**:
- `rtl/tcp_tx_frame.v`: 新增纯线束输出 `o_retx_hi`/`o_retx_active` (= 内部
  retx_hi/retx_active, 零逻辑零耦合);
- `rtl/tcp_rx.v`: TCB 读口组旁新增 `ra_retx_hi`/`ra_retx_active`, ack_ok 改为
  `ack_hi = ra_retx_active ? ra_retx_hi : ra_snd_nxt`, 判据
  `(ack32-snd_una) <= (ack_hi-snd_una)` (其余 ack_adv/dup_ack 语义不变;
  会话结束 retx_active=0 自动回原语义);
- `board/wrapper_p4.v` + `board/wrapper_tcp.v`: 两处连线 (u_tcp_tx 出 ->
  u_tcp_rx ack_ok); tcp_rx 另有 4 个 TB 实例同步连线 (tb_tcp_chain/echo/rx
  走 u_tx.retx_* 层次引用, tb_tcp_rx 无 tx 侧恒接 0)。

**TB 复现门 (+PCSTALL, 仅与 +PCACK 同开)**: `tb/tb_p4_chain.v` 新增
- 阈值/延迟经 `pcstall.memh` 传入 (xsim loader 拆含 '=' 的 plusarg, 同
  txdrop/trunc/halfdrop 文件通道), 默认 49150 字节 / 300 拍;
- 停发判据 = **累计已收 echo 字节** (hi_wm - conn0 ISN 0x12345679 >= 阈) —
  不能按未确认差判: 本模型每帧即 ACK (PCACK 语义), 未确认差恒 ≈1 帧, 永达
  不到窗帽; 板级实体是"PC 收满一窗字节后停发 ACK";
- 停发后 inj_done 冻结; 盯 `u_tx.retx_active && u_tx.retx_id_r==0` (conn0
  会话, 只看全局 retx_active 会被 conn1 自愈会话误触发) 记会话起点, 会话 +
  延迟后注入**一个**纯 ACK, ack = 当时高水位 hi_wm (= 板侧 retx_hi, 因为重放
  帧 seq 恒 < 高水位, 高水位不再增长); 之后不再注入;
- resp 追加 `PCSTALL` 行 (阈值/延迟/停发拍/会话拍/注入拍/注入时板侧 TCB/
  高水位/停摆后新数据帧数/终态 TCB/会话数)。

**判据** (`tools/gen_stim_p4_chain.py check_stall`, 模式 `stallcheck`):
① 前提链 k_stall < k_sess < k_inj + sess_seen + inj_sent + 停发时已收 >= 阈;
② 命中原始 bug 条件 = 注入落在会话期内 (`inj_in_sess`) **且注入拍 snd_nxt <
   注入的 ack** (snxt_inj < hi_inj) + 回卷时在飞 >= 阈-2帧;
③ 修复判据 = 注入后 snd_una 追上高水位 (`snd_una_end >= hi_inj`) + GMII 独立
   核验出现 seq >= 高水位的 conn0 echo 帧 (ring 重放帧恒 < 高水位) + 终态
   snd_nxt > 高水位; ④ 不变量 mac abort/eend=0 + max plen<=1460 + ECOMAX<=182。

**突变验证 (硬要求, 两跑拍级同构)**: `sim/p4sim/stall_gate_prefix_fail.log` /
`stall_gate_postfix_pass.log` — 同一激励下停发拍 141600 / 会话拍 205489 /
注入拍 206660 完全一致:
- 修复前 (HEAD): 注入拍 snd_nxt = snd_una = 0x123512BD、高水位 0x1235F129 在
  重放期被 ack_ok 拒 → 终态 snd_una **恒 0x123512BD < 高水位** → `PCSTALL FAIL`
  (exit 1);
- 修复后: 终态 snd_una = 0x1235F129 (= 高水位, ACK 被接受)、snd_nxt =
  0x1236CF95 (继续发新数据, 127 帧)、`PCSTALL OK` (exit 0)。

**全矩阵回归 (16 门全绿, `sim/p4sim/matrix_p4dfix.log`)**: chain / burst200 /
TRUNC=50,100 / HALFDROP=100k990 / TXDROP=50 (RETX=1 自愈仍成立) / gate4096 /
dupstorm / PCACKOOB / VLAN chain+burst / stall 门 / 单元 retx_ram (7 GRP) /
frame_fifo (PASS_ALL) / vlan_strip / uart_dbg。矩阵用**默认 HLS 网表** (开工时
工作区是 ACTIVE 变体, 已按 TL 指示 `hls/run_hls.bat` 重综合恢复)。

**板级构建** (`board/run_build_p4.bat`, 默认网表): WNS=+0.110 / WHS=+0.045,
0 failing endpoints, bitstream 已生成。WNS 最差路径 = `u_tcp_tx/u_retx/
ra_e_r_reg -> retx_ram ADDRBWRADDR` (P4c 起既有族, 96.99% 走线, 0 逻辑级) —
**与本次 ack_ok 32 位 mux 无关** (最近两次基线 0.149/0.149, 差 ~0.04ns 属布局
布线抖动); ack_ok 未进关键路径。

**TB 侧 harness 观察 (供后续门参考, 与本次修复无关)**:
1. **注册窗口门在仿真里漏** — tcb 的 win_open 用**上一拍 rb_id** 的
   snd_nxt-snd_una 判定, 而 scan_now 拍 rb_id = scan_id (空闲槽 2..15 在飞 0)
   → 门每 16 拍被空闲槽"开"一次, 在飞远超窗帽时数据仍按刺激速率发出 (本门
   停发后在飞涨到 292KB)。**板级 P4b-7-P6 实测门确实关死过** (冻结), 故此处
   仿真/板级行为差异需 TL 判: 可能板级 app 无数据呈现拍远多于仿真, 或板级
   scan 拍与 start_data 拍很少相邻。本门判据因此**不依赖门控** (核心判据 =
   snd_una 追上高水位)。
2. **RTO tick 实测远慢于标称** — scan_now 需 S_IDLE && !ack_pend_r && scan_tick
   三条件, 数据/ACK 繁忙期实测 1900~5850 拍/次连接访问 (标称 256) → RTO 门用
   RTOLIM_STALL=12 才落在尾窗内 (30 次访问已能拖到 175k 拍)。
3. **修复的残余多连接风险 (建议 TL 裁决, 本次按方案未改)**: `ra_retx_active/
   ra_retx_hi` 是**全局会话**信号, 而 ack_hi 作用在 `conn_id_l` 的 ack 判据上。
   若 conn1 正在回卷会话而 conn0 的 ACK 到达, ack_hi 会取 conn1 的 retx_hi —
   32 位回绕差可能放大成"接受未发送字节的 ACK" → snd_una 越过 snd_nxt →
   在飞回绕成巨数 → 窗口门永关 (另一种死锁)。数据面单连接假设下无害 (板级
   conn1 空闲无会话), 一行加固: tx_frame 再暴露 `o_retx_id` (= retx_id_r),
   tcp_rx 用 `ra_retx_active && (ra_retx_id == conn_id_l)` 选 ack_hi。

### P4d-fix 板级验证: 死锁修复确认 (2026-09-19)

烧修复版 (112ad78, WNS +0.110, ack_ok mux 不在关键路径):
- **32MB 通过** (exit 0, echo 33,554,432 B 完整, 105.3 Mbps 稳态, 897 次自愈事件)
- **64MB 通过** (exit 0, 46,846 × 1514B 帧)
- UART 终态健康: NX==UA (全确认), FFE=01 (echo fifo 已排空), TXST/RXST=0 (idle),
  TRU=8 (8 次截断全消化), latch I=C1E8=49,640=34×1460 (> cap 49,150 — **满窗 RTO
  回卷确实发生过且这次成功自愈** = 修复生效的直接证据)。
- 结论: 48KB 满窗 + RTO 回放期高水位 ACK 的拒收死锁已修复; 之前的 32MB 必死
  (t=0.486s 起 17 轮重放无进展) → 现在 32+64MB 全通。
- 遗留 (P5 多连接前置): ack_hi 的 retx_hi/retx_active 是**全局会话信号**, 现按
  per-ACK 连接使用; 单连接数据面下无害, 多连接时需加 retx_id 归属比对
  (tx_frame 暴露 o_retx_id + tcp_rx 比对 conn_id_l) — 见 112ad78 注。

### P4d 板级验收: VLAN fast path 全链路实证 (2026-09-19)

**平台障碍**: Killer E5000B 不支持 npcap raw 注入透传 802.1Q tag (关闭 "优先级和
VLAN" 属性 + 重启网卡后 MW 词计数仍 19/19 = tag 未上线; 读 mac_rx_64 RTL 确认
计数口径 = 不含 FCS 的帧体, 排除口径误判)。

**破解**: 用网卡自带 **VLAN ID 属性**给*所有*出站帧打 tag (VLAN 100, 注册键
RegVlanid; 抓包点在 tag 插入之前故抓包看不见 tag, 用板侧 MW 计数判决):
- 单帧 ping (-l 11, 帧体 53B + 4B tag) → MW delta = **8 词** (无 tag 为 7) ✓
  = 内核流量也被打 tag, tag 确实上线
- **32MB 速率测试全通**: 109.2/102.2 Mbps, 33,554,432 B 完整 (全 tag 链路:
  TCP 握手/数据/ACK 全经 802.1Q, 板侧 shim 剥离后 fast path 正常)
- **64MB 全通**: 109.1/103.4 Mbps, 67,108,864 B 完整, exit 0
- 板→PC 回包无 tag 被 PC 正常接收 (网卡不按 VLAN 过滤入向)
- 测试后已还原: RegVlanid=0, 网卡重启, ping 恢复

**结论**: VLAN fast path 板级验收通过 (端到端 + 内核栈互操作 + 全量数据完整)。
比 scapy 注入更强: 真实 Windows TCP 栈的全部行为都在带 tag 链路上跑过。

**测试工具结论 (用户议题)**: 噪声/性能问题的根因 = 内核栈参与测试, 解法 =
合成对端 (不走 socket) + 屏蔽内核反应, 语言 (C++ vs Python) 次要; C++/npcap 的
增量价值在精确时序/线速生成/故障注入 (P6 10G 仍不够, 需 DPDK 或硬件测试仪)。

### P4d 板级验收: TCP 主动连接通过 (2026-09-19)

- 烧 ACTIVE_CONNECT=1 板级 bitstream (WNS +0.219), PC 侧 `tools/board_active_test.py`
  监听 9090 → **71.1s 后板侧主动连上** (源 192.168.100.2:8080) → 握手 OK →
  100B 数据 echo 逐字节一致 ✓ (fast path TCB 由 HLS cfg 记录配好)
- **ACTIVE_DELAY 实测**: 71s 而非注释估的 2s — "pass" 换算系数实为 ~52 cycle/pass
  (与修复 agent 的 sim 实测一致), 250000000 passes ≈ 100s 量级。板级默认值宜下调
  (或注释修正); 不影响功能 (期间自动重试)。
- 期间踩坑: 两个并行任务 (我 + C++ agent) 先后用板, C++ agent 把板压死时用
  `run_program_tcp.bat` (P3 旧 bitstream, Aug 28) 重烧恢复 → 我的主动测试一度失败。
  **教训: 板子必须串行占用; 恢复用 run_program_p4.bat (当前设计), 不要用旧项目
  bitstream。**

### P4d 板级验收总计: 3/3 通过
① 死锁修复 (32/64MB 全通) ② VLAN fast path (全 tag 链路 32/64MB 全通)
③ 主动连接 (握手 + echo)

### 重大修正: 板子实测 ~890 Mbps — "125Mbps 吞吐铁律"证伪 (2026-09-19)

**C++ 合成对端 (tools/cpp_peer) 批量发送整改后实测** (板子在跑 P4 当前 bitstream):
- peer 自测发送能力: 81,274 fps / **984.4 Mbps** (1G 线速 99%) — 不是瓶颈
- **1GB: 稳态 891.55 Mbps (111.44 MB/s)**, 逐字节零失配, retx=0 (零 RTO)
- **TL 复核 256MB: 890.44 Mbps (111.31 MB/s)**, RTT avg 426.8µs, retx=0 ✓ 可复现
- 双向: 本端 TX 890 Mbps / 板端 TX 937 Mbps — 双向都接近 1G 线速

**归因三分解 (1GB)**: peer 发 1,484,407 帧 / 板侧 MW 增量 == peer TX 词数 (差 0) /
板侧 DROPS[0] +565 (0.038%), TRU +0 → **零丢帧、无线级问题、无自激循环**。
瓶颈 = **板侧固定通告窗 48KB × RTT 428µs** (在飞量顶在窗口 97-100%;
不同 flush 档下 `吞吐 × RTT` 恒 = ~48KB)。RTT 高的原因 = 板子几乎不发纯 ACK
(0.9%, 全是 echo 捎带) → ACK 满 48KB 需先 echo 48KB = 384µs 串行化。

**结论修正**: P4c 记的"echo 架构铁律: 吞吐 = 1460B/帧级判定 12us ≈ 125Mbps 与窗口
无关"是**测试工具链的产物** (Python 内核栈 socket + 逐包 pcap: 前者受延迟 ACK/缓冲区
限制, 后者天花板 9 MB/s)。板子真实上限 ~890 Mbps ≈ 1G 线速的 94% (TCP 净荷),
**架构本身从不是瓶颈**。P4c 的 ACK-early 实验 (suppress=0 冲窗口) 因此无必要;
板级 suppress=1 (现配置) 在干净对端下即达 890 Mbps。

**遗留**: 内核栈 Python 版吞吐波动大 (历史 105, 本轮 55.4 Mbps) — 取决于内核
ACK/缓冲时序, 未深究 (已由合成对端取代为主测试工具)。要突破 890 Mbps 需更大
通告窗 (DDR/WS) — 1G 下已无必要, 10G (P6) 时再上。

### P5 开工 — app interface 计划定案 (2026-09-19)

**用户拍板三项**: ① 接口形态 = **AXIS 流 + 寄存器/mailbox 控制** (本轮不做 AXI-Lite);
② 板级演示载体 = **RTL 图案发生器+校验器** (不做 UART 桥); ③ 范围 = **TCP 先行, UDP 收尾**。

**计划**: `C:\Users\zhxue\.claude\plans\distributed-herding-gadget.md` (含接口定义/
安全论证/Step 1-8 逐行改动点/子里程碑 P5a-P5e 与门)。关键设计决定:
- D1 窗口 = **单调右沿寄存器** `redge[c]`，写 TCB 的 `W = redge - rcv_nxt` —
  草案"右沿自然不缩"不成立 (TCB 的 W 是采样值、ACK 的 ack 是新鲜 rcv_nxt，不原子 ⇒ 右沿被抬高 δ)
- D2 多连接配额 = **信用池** (CONN_UP 授、DOWN 归还) — `free/N` 不安全 (窗口授予不可撤销，
  Σ 历史最大窗可超缓冲)
- D3 扫描**不得复用 TCB `win_id` 口** (那是 TX 门控的注册读口) → 新增组合读口 C
- D4 FIN **只在 `snd_nxt == snd_una` 时排队** (ring 不覆盖 FIN 的 1 字节 seq，
  否则重放会读出发送垃圾字节)
- D5 超长帧 = 帧内中止 + 冲洗 (不加 FSM 状态；>2048B 否则 `pay_full` 永久死锁)
- APP_MODE 构建开关默认**关** ⇒ 默认位流与 P4 逐位一致 (回归保护)

### P5a-0 前置实验: suppress=0 板级复测 (2026-09-19) — **吞吐不达标，根因待查**

目的: P4c 记的"suppress=0 板测 28.4Mbps"是 **w6a 修复前**的数据；app 模式必须逐段纯 ACK
(无 echo 捎带)，需重新确认该配置的板级可行性。

构建: `board/build_p5a0.tcl` (工程名 `p5a0_prj`，**不覆盖已验证的 p4_prj 位流**)，
`APP_MODE=1` ⇒ wrapper 的 `cfg_suppress_data_ack(!APP_EN)` = 0。WNS +0.126 / TMS 0 / WHS +0.048。

**对照实验** (同一时刻、同一机器、同命令 `peer.exe --bytes 16777216`):

| 位流 | elapsed | peer RX 帧数 | RX 帧率 | dup_acks | fast_retx | 吞吐 |
|---|---|---|---|---|---|---|
| p4_prj (suppress=1) | **0.150 s** | 11634 | 77,440 fps | 36 | 1 | **891.94 Mbps** |
| p5a0_prj (suppress=0) | 0.290 s | 33804 | 116,696 fps | **20609** | **1159** | 462.50 Mbps |
| suppress=0 + `--no-fast-retx` | 0.366 s | 23218 | 63,598 fps | 11606 | 0 | 368.10 Mbps |
| suppress=0 + `--no-mintocopy` | 0.415 s | 37078 | 89,432 fps | 23399 | 1516 | 323.15 Mbps |

三个配置**都逐字节零失配** (协议正确)；慢的是吞吐。

**已定位的 peer 缺陷**: `peer.cpp:736 process_ack()` 的 dup-ACK 判据
`if (ack == snd_una && !inflight.empty())` **不区分报文是否携带数据** — suppress=0 下
"纯 ACK(推进) + echo(同 ack 值)" 成对出现 ⇒ 每数据段白计 1 次 dup (20609 ≈ 段数) ⇒
3 连 dup 触发**虚假快速重传** (1159 次 ⇒ 60% 额外流量)。标准 (RFC 5681 / Linux
`FLAG_NOT_DUP`) 携带数据的段不计入 dup-ACK。**这条无论如何要修。**

**未解**: 即使禁掉快速重传、传输完全干净 (unique 16.8MB 零丢帧)，仍只有 368 vs 891 Mbps；
此时板子 TX 仅 ~400Mbps 未饱和、peer RX 帧率低于 P4 基线的 77.4k fps。已派专职 agent
(板子独占) 查根因 + 修 peer 标准语义，产出可信数值。**结论影响 P5 的 ACK 策略**
(是否需延迟 ACK 批处理)。

### P5a-0 破案: 主因 = 工具 dup-ACK 语义，次因 = 板子既有"突发丢帧 + 静默"病理 (2026-09-19)

**主因 (peer 工具缺陷)**: `process_ack()` 把**携带数据的报文**计入 dup-ACK。suppress=0 下
板子对每个数据段发"纯 ACK + echo"两帧、**同一 ack 值**，其中 echo 那帧被白计 1 次 dup
(20609 ≈ 段数) → 每 3 段触发一次**虚假快速重传** (1457 次/趟 → 60% 额外流量 → 板子 TX 打满)。

修复 (peer.cpp，标准语义): ①带数据的段绝不计 dup (RFC 5681 / Linux `FLAG_NOT_DUP`)
②dup-ACK 还要求通告窗口未变 ③Reno 快速恢复状态机 (恢复期内 dup 只膨胀 cwnd，不武装新重传；
`ack >= recover` 退出) ④重传保留 go-back-N 修补 (实测单段 Reno 重传只有 174-363 Mbps —
板子整串丢帧等不到后续) ⑤仪表 (flush/RX/loop 分段计时、CPU 核数、RTO 现场诊断、
`--legacy-dupack` A/B 开关)。**`--no-mintocopy` 会腰斩吞吐 (496-499)，禁止用于速率测量。**

**修复后实测 (TL 独立复核)**:

| 128MB | 位流 | 吞吐 |
|---|---|---|
| P4 (suppress=1) | p4_prj | 875.2 / **898.5** Mbps |
| **app 模式所需 (suppress=0)** | p5a0_prj | 557.8 (撞一次静默停顿) / **857.3** Mbps |

**判定: app 模式逐段纯 ACK 可行** — 稳态 857 Mbps = echo 基线 (~895) 的 **95.5%**，
理论线速上限 905 Mbps 的 94.7%。**计划里的"延迟 ACK 批处理"兜底不需要。**

**次因 (板子真实病理，两配置都有，suppress=0 下频率高 5-25 倍)**: 板子偶发**整串丢帧 +
TX 静默 ~200ms** —— 证据: ①tshark 独立抓包 6s 内两次 202.9/205.6ms 板子零帧
(`D:\tmp\captures\stall1.pcapng`) ②peer RTO 诊断 `board silent for 212428us`,
`ack_hi == snd_una` ③板侧三站词计数 MW/CW[0]/RW 一致 ⇒ **帧已进 tcp_rx**，
同期 `DROPS[0]` (窗口内 seq 不符) +358 ≈ 14 事件 × 25-33 帧 ④重传 `seq=snd_una` 一帧后
板子 <1ms 复活 (ack +1460)。**链条推断: 突发帧丢失 (mac_rx 8 深 FIFO 满丢整帧) → 后续帧
判"乱序" → dup-ACK 请求 → `ackq`(8 深) 溢出 → dup-ACK 一个都没上线 → 对端只能等 200ms RTO。**
待办 (P5a 后续): ①`ackq` 加深 8→32 (让快速重传恢复成立) ②`stat_ack/stat_ack_drop` +
`tcp_tx_frame` FSM state 接进 UART 快照 (当前无法从外部定案) ③P5b 的窗口闭环正是
"不让 RX 流水线堵"的对症机制。

**工具余量 (供 P6 参考)**: peer flush 路径 ~191k 帧/s ≈ 1.1 Gbps 载荷上限；实测峰值
147.9k fps = 上限 78% (双向双帧/段需 155k fps)。**工具不是当前瓶颈但只剩 ~20% 余量，
10G 必须换工具 (pcap_sendqueue_transmit(sync=1) + 逐帧 pcap_next_ex 的结构撑不住)。**

### P5a 实现+审查+测试轮: 首轮全量构建失败 (DRC 组合环) — 2026-09-19

**实现 agent 交付**: Step 1-7 全部完成 (tcp_tx_frame 长度守卫+FIN/RST 通道; tcb 读口 C +
WIN_CAP 参数化; slow_cfg_adp 事件源; 新 app_ctrl/app_pattern/app_status_uart;
wrapper APP_MODE 分支; sim/p5sim 门 + tb_p5_app/tb_p5_status)；
sim 侧: P5 三门 OK (1MB 图案逐字节/超长帧 drop_len=1/状态行 136 字符) + **P4 矩阵 16/16 绿**；
实施者额外自查出 3 个真 bug (flush 期间 accept 吞字 / len_bad 跨帧残留致载荷错位 8B / 冲洗未完成即启新帧)。

**审查 agent 独立复核** (只读 + 独立解析 resp_p5_app.memh) 结论:
- 「默认构建等价性」**成立** (唯一例外: `PLEN_MAX` 守卫未 APP_MODE 门控 —— 有意加固,
  ≤1500B 输入逐位等价, >1500B 由挂死改为丢弃; 用量指纹: p4 vs p5a0 的 FDRE 完全相等 16362)。
- 抓到 **H1 (阻断板测)**: peer 图案表**先推进后取字节**, RTL **先取后推进** ⇒ `peer[k]==RTL[k+1]`,
  板级逐字节判据会全失配 (且 peer 无 `--rx-only`, 计划 §八 的板测命令当时不可执行)。
- **H2**: 5 个旧文件 (`tb_tcp_tx/tb_tcp_chain/tb_tcp_echo/tb_tcp_tx_dbg` + `board/wrapper_tcp.v`)
  未接 tcp_tx_frame 新输入 → xsim 悬空 Z 进 ackq → 纯 ACK 帧 flags/ack 半 X (P4 矩阵覆盖不到)。
- **M1**: `fin_repush` 与 `ack_req` 抢 ackq 条目 → FIN 重推**永久丢失** (关闭永不完成 + 完成检测误报)。
- **M3**: `app_pattern` 在 `ev_down` 直接撤 `pw_valid` (无 tlast) → AXIS 违约 + 帧器卡 S_RECV。
- L1/L2/L3/M2/M4 若干 (UART 分时实为 4.295s 且必截半行; 快照缺 drop_len/fin/rst; 三处 0xBFFE 独立; ...)。

**TL 门核查 + 构建**: `board/run_build_p5.bat` **失败** — DRC LUTLP-1 组合环
`u_app_pipe/m_data_r[76]_i_2`, bitgen 不跑。**根因 (W1, 真 bug)**:
`board/wrapper_p4.v:446 assign app_tx_tready = app2_tready;` 与 `u_app_pipe.s_ready(app_tx_tready)`
**同时驱动同一根线**, 且 APP_MODE 分支**没人驱动 `app2_tready`** (默认分支才有
`eco2_tready = txin_tready`) ⇒ ①自环 ②语义错: `axis_pipe` 正确背压是 `s_ready = m_ready || !m_valid`,
现在退化成 `= m_ready` ⇒ 流水寄存器压着字时 app 还能再推 ⇒ **丢字**。
**教训: 模块级 TB 绿 ≠ wrapper 分支正确 —— P5 门必须有一个带 `-d APP_MODE` 例化 `wrapper_p4` 的全链门**。

**处置**: W1 (含 wrapper 级门) / W2 (=M1) / W3 (=M3) / W4 (=H2) / W5 (小项) 已退回实现 agent 修;
H1 (peer 图案相位, 1 行) + `--rx-only` 扩展已通知测试 agent。修完重跑 `board/run_build_p5.bat`。
`board/build_p5a0.tcl` 已标注**历史实验脚本勿重跑** (RTL 已演进, 清单不含 app 模块)。

### P5a 板级验收: app 接口双向实测通过 (2026-09-19)

**修复后构建**: `p5_prj` 全量通过, **WNS +0.205 / TNS 0 / WHS +0.053** (P4 基线 +0.219 ⇒ 无退化),
bitstream `vivado_prj/p5_prj.runs/impl_1/wrapper_p4.bit`。DRC 组合环消失 (W1 修复生效)。

**TL 亲自复跑门**: P4 矩阵 **16/16 EXIT=0** (首轮 chain/burst200 因残留 xsim 进程占目录假失败,
补跑 `P4 CHAIN OK` / `BURST OK`)。

**板级实测 (内核栈 socket 客户端, 免合成对端)**:
- **app TX 路径**: 连上 192.168.100.2:8080 → 板侧 cone_up 后主动发 1MB →
  PC 收 **1,048,576 B 逐字节零失配** (16ms, 511 Mbps 内核栈口径), 收完 EOF ⇒ **close/FIN 走通**
- 首字节 `7f 0b 02 e5 36 a1 4e d6 1a b0 49 b8 56 ad d6 3f` = RTL 的"先取后推进"序列
  (**反证审查报告的 H1**: peer 的图案表相位差 1 字节, 必须改成先取后推进)
- **app RX 路径**: PC 立即发 32KB 图案 → 板侧 app 校验器 **MM=0000 零失配**
  （⚠️ **平台限定**（2026-09-30 补，`P7B_W13_AUDIT.md` §②-V25）：该读数来自**有 UART 状态行的板**
  （P5a 轮，同段自写"板侧计数器 (UART P5A1 行)"、工具走 `--port COM9`）；**KU5P 上
  `app_pattern.stat_mismatch` 结构性不可读** —— 该线束只喂 `app_status_uart` 的状态行，`uart_txd`
  无消费者（`P7B_BIZ_PLAN.md` R3）。KU5P 上只有 PCIe 快照窗口的 `W13`（且须**同窗 `ΔW10>0`**）。）
- **板侧计数器 (UART P5A1 行) 与 PC 侧逐项吻合**:
  `TX=00100000`(=1MB) `TF=02CF`(=719 帧, 与仿真门同值) `DL=0000`(无超长帧) `RS=0000`(无 RST)
  `FI=0001`(1 FIN) `EV=0002`(CONN_UP+CONN_DOWN) `NX==UA`(数据全确认)；
  第二轮 `RX=00008000`(32768B) `MM=0000` `EV=0004` `FI=0002` `TF=059E`

**结论: P5a 出口判据全部达成** (仿真门 + 时序 WNS≥0 + 板级 app 双向 + 计数器自洽)。
遗留 (转 P5b/P5c): 合成对端仍缺 `--rx-only` (线速 app TX 验证需它)；慢消费者/窗口闭环 (P5b)；
FIN 丢失重传与 RST 的板级用例 (P5c)。

## 2026-09-19 P5a 实现 (Step 1-7, app 接口第一阶段) — xsim 门全绿

**范围**: app AXIS 数据面 + 事件/寄存器控制面 (不含 TCB 窗口写口/信用池 = P5b/P5d)。
RTL 改动 + 新模块 + 新仿真门; **未碰板子/未跑 Vivado 构建** (TL 独占板跑 P5a-0)。

**Step 1 `rtl/tcp_tx_frame.v` (长度守卫 + FIN/RST 通道)**:
- `PLEN_MAX=1500` 长度守卫: `len_over` 检出 -> `len_bad` 屏蔽 `wr/wr_tap/csum_den`;
  `tlast && len_bad` 跳过 S_WAIT 直接 S_IDLE + `flush_pend` + `stat_drop_len++`;
  S_IDLE 排空 u_fifo 后清 `flush_pend`/`len_bad`; 上界 < FIFO 容量 (256 字) 故
  永不触发 `pay_full` 死锁 (>2048B 帧的旧死锁路径消失)。**不加 FSM 状态**。
  帧内中止不经过 S_DONE ⇒ snd_nxt 不推进 ⇒ ring 残字节被下帧覆盖 (无暴露)。
- FIN/RST: ackq W 37->39 (`{id,syn,fin,rst,val}`; 计划文档写 38 是笔误);
  `fin_req/rst_req` 输入 + 本模块**扫描自排队** (FIN 仅 `snd_nxt==snd_una` &&
  ESTAB && !fin_sent, D4); flags 0x11/0x14; FIN 发完记 `fin_seq_r`, RTO 回卷时
  `retx_hi <= fin_seq_r` (杀 1 字节幻影重放) + `fin_retx_pend` 在 ring 会话排空处
  **组合重推** FIN 条目 (seq 同值, 无漂移); `o_fin_sent`/`o_retx_id` (Step 8 提前做)。
  `start_data` 对 `fin_req/fin_sent` 的连接屏蔽; 扫描采到非 ESTAB 清这两个标志。
- 三个新 bug (xsim 抓到, 全在"中止帧后的下一帧"):
  ① `flush_pend` 期间 `s_axis_tready` 未压制 -> app 的字被 accept 吞掉却既不进
     FIFO 也不进 plen (实测丢 144B); 修 = S_IDLE 的 tready 加 `!flush_pend`。
  ② `len_bad` 留到下一帧帧首才清 -> 下一帧首拍被 accept 但 `wr` 仍被屏蔽
     (plen 计 8 字节而 FIFO 没写 = 整帧载荷错位 8B); 修 = 冲洗排空拍同拍清。
  ③ (同族) 计划文档"tlast 拍跳过 S_WAIT"的实现必须让**整个**缓冲区间被冲洗,
     否则残字节在下帧前混入 — 已由 ①② 覆盖。

**Step 2 `rtl/tcb.v`**: `WIN_CAP` 参数化 (= `tcp_tx_frame.RING_CAP` 0xBFFE,
wrapper 显式传参) + **组合读口 C** (`rc_id -> rc_*`; 慢速消费者, 不动 ra/rb/win 口, D3)。

**Step 3 `rtl/slow_cfg_adp.v`**: 纯加输出 `ev_up/ev_down` (脉冲) + `ev_slot/peer_ip/
peer_port/peer_mac` (S_CAM 锁存, 保持到记录结束)。ADD 收尾 = `S_TCB_LAST` 的 wscale
授权写落地拍; DEL = state=0 授权落地拍。FSM 时序零改动 (P4 TB 无需改端口即编译)。

**Step 4-6 新模块**:
- `rtl/app_ctrl.v`: 事件 FIFO (fifo_sync 102b x 16 FWFT, 满丢弃+计数) + 16 分频轮扫
  采 TCB 状态 + 8 位地址寄存器总线 (地址映射按计划, **位宽从 5 位放宽到 8 位** —
  计划自带映射 0x10+4c/0x90 超出 5 位可寻址) + `app_tx_ready` + FIN/RST 请求输出。
  P5a 不做 TCB 写口/窗口计算 (P5b/P5d)。
- `rtl/app_pattern.v`: xorshift64 图案 TX/RX 双实例 (每拍 1 字节 = 8 字节/9 拍呈交一字,
  ≈0.89 B/cycle ≈ 890Mbps 上限); CONN_UP 启动 `TX_BYTES` (默认 1MB) 发送, 每帧
  ≤1460B; 发完 `close_req`; RX 逐字节比对 (`stat_mismatch`); 故障注入
  `i_bad_frame` (第 N 帧用 2000B 常数载荷 + LFSR 冻结 ⇒ 被丢弃后图案流仍连续)。
  **呈交口必须组合驱动** (寄存器化 valid 会在消费拍后多挂一拍 = 同 beat 双消费)。
- `rtl/app_status_uart.v`: 独立 136 字符快照行 (复用 `uart_tx_9600`, 不改 uart_dbg.v)。

**Step 7 `board/wrapper_p4.v`**: `ifdef APP_MODE` 分支 (默认分支逐位不变):
`eco2_*` (echo 输出) -> app RX; app TX -> `axis_pipe` -> `u_tcp_tx.s_axis` (经 `txin_*`
选择线); app_ctrl/app_pattern/app_status_uart 实例化; LED 走 app 指示灯; UART 前
~8.6s 给 P4 诊断行、之后给 app 状态行 (一根 txd 的分时复用); ACK 源合并结构
`rx_ack_req | fin_push | rst_push` 留好 (本阶段 fin/rst push 恒 0 — FIN 由帧器自扫描)。
新 `board/build_p5.tcl` + `run_build_p5.bat` (p5_prj + `verilog_define APP_MODE=1`,
不覆盖 P4 的 wrapper_p4.bit; build_p4.tcl 不动)。

**P5a 门 (`sim/p5sim/`, 独立于 p4sim 的 xsim.dir)**: `tb/tb_p5_app.v`
(APP_MODE 数据面 + 从 tb_p4_chain 移植的 PC ACK 模型 + 一次 100B 图案数据段注入) +
`tools/gen_stim_p5_app.py` (激励 + 判据) + `run_tb_p5_app.bat` (P5BAD=N 注入超长帧)。
**结果 (两条门全绿)**:
- 默认门: 719 帧 / 1048576 B 逐字节 == 图案 (偏移 = seq-(ISS+1)); 覆盖
  [12345679,12445679) 连续无洞无重叠; FCS/doff=0x50/flags=0x18/win=0xC000 全合法;
  `stat_eend=0` / mac abort=0 / ECOMAX=182; app RX 收到注入的 100B 图案且失配 0;
  事件字 ① 全对 (kind=0/slot=0/peer_ip/port/mac) + REG 0x9F=0x50354131。
- `P5BAD=5` 门: `stat_drop_len=1` 恰 1 次, 其后 719 帧 / 1048576 B 仍连续无洞、
  逐字节全等 (坏帧不上线, 图案流不被跳过); 无死锁。
- 附带验证 (P5c 预演): FIN 段 flags=0x11, seq = snd_una (无在飞), ack = 当前 rcv_nxt ✓。

**P4 回归**: Step 1 后 15/15 门绿; Step 2+3+7 后重跑 (见下条)。默认构建路径 (无
APP_MODE) 的 wrapper 全量 xelab 通过 (APP_MODE 变体亦通过, 含 HLS 网表)。

### P5a 补: app_status_uart 单元门 (Step 6) — 抓到 2 个真 bug

P5 全链 TB 只跑 ~10ms, 9600 下连一行 (142ms) 都发不完 ⇒ 状态行在全链门里没被
真正驱动。新 `tb/tb_p5_status.v` + `sim/p5sim/run_tb_p5_status.bat` (缩短
BIT_LAST=13 + 位中点采样 + 逐字符按 start 沿重对齐 + 二进制写文件) 解码 136 字符
行并与期望串逐字节比对 ⇒ **P5 STATUS OK**。两个 bug 都是这个门抓到的:
1. **nibble 索引方向反了**: 字段 32 位值左对齐后第 k 位取自 LSB 端 ⇒ 整行每个
   字段内部**倒序** ("12345679" 打成 "97654321")。修: `hexd(v, ci - start)`。
2. **EC (2 位 hex) 取错 nibble**: 16 位寄存器左对齐成 4 位 hex 后取前 2 nibble,
   实际应取低字节 (`{sn_ec[7:0], 24'b0}`) — 否则 EC=02 打成 EC=00。
3. (测试侧) TB 解码器每字符少算 1 拍 → 累积漂移, 几字符后整体错一位; 修 = 每字符
   按 start 沿重新对齐 (不靠周期数累加)。另: `$fopen(...,"w")` 文本模式会把 0x0A
   写成 0x0D0A (多一个 CR), 必须 "wb"。

**P5a 门命令 (Git Bash)**:
> 📌 **历史记录, 保留原样**: 本节写于 2026-09-19, 那时 `D:\repo\ECO\udp_hls_10g`
> **就是**当时的开发树 (本仓 2026-09-28 才从那里整体拷贝而来) ⇒ 照抄这些绝对路径
> 会跑**另一个 checkout** (= 真空门)。**现役自定位跑法**: 在本仓根执行
> `cmd //c 'sim\p5sim\run_tb_p5_app.bat'` / `bash sim/p4sim/run_matrix_p4dfix.sh`。
```bash
cd /d/repo/ECO/udp_hls_10g/sim/p5sim
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_app.bat'          # 默认门 (~2min)
P5BAD=5 cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_app.bat'  # 2000B 超长帧门
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_status.bat'       # 状态行单元门
bash /d/repo/ECO/udp_hls_10g/sim/p4sim/run_matrix_p4dfix.sh            # P4 15 门回归
```

### P5a 收尾: 门结果 + P4 回归 (2026-09-19 18:58)

| 门 | 命令 | 结果 | 关键数 |
|---|---|---|---|
| P5 默认 | `run_tb_p5_app.bat` | **P5 APP OK** | 719 帧 / 1048576B 逐字节==图案; 覆盖 [12345679,12445679) 无洞; drop_len=0; fin=1; eend=0; mac abort=0; ECOMAX=182; app RX 100B 失配 0 |
| P5 超长帧 | `P5BAD=5 ...` | **P5 APP OK** | stat_drop_len=1 (恰 1 次); 其后 719 帧 / 1048576B 仍连续无洞逐字节全等; 无死锁 |
| P5 状态行 | `run_tb_p5_status.bat` | **P5 STATUS OK** | 136 字符行逐字节 == 期望 (含 EC/字段序) |
| P4 回归 | `run_matrix_p4dfix.sh` | **16/16 EXIT=0** | chain/burst200/trunc50/trunc100/halfdrop/txdrop50/gate4096/dupstorm/pcackoob/vlanchain/vlanburst/stallgate/unit_retx/unit_fifo/unit_vlan/unit_uart 全绿 (ECOMAX 恒 182, 无注入门 RETX=0) |
| 默认 wrapper | xelab 全量 (含 HLS 网表, 无 APP_MODE) | **snapshot built** | 默认构建路径编译/elab 干净 |
| APP_MODE wrapper | xelab 全量 (-d APP_MODE) | **snapshot built** | app 分支端口连接全部一致 |

### P5a 复核轮 (审查 + 测试 agent) 发现与修复 (2026-09-19 晚)

**流程**: 实现 agent 交付 Step 1-7 → 审查 agent (只读全 diff) + 测试 agent (独立复跑 + 对抗用例)
并行 → TL 门核查 → 修复 → 复验 → 板级。

**首轮全量构建失败 (TL 门核查抓到)**: `board/run_build_p5.bat` DRC `LUTLP-1` 组合环
`u_app_pipe/m_data_r[76]_i_2` ⇒ bitgen 不跑。根因 = **W1**: `board/wrapper_p4.v` 里
`assign app_tx_tready = app2_tready;` 与 `u_app_pipe.s_ready(app_tx_tready)` 同时驱动同一根线,
且 APP_MODE 分支**没人驱动 `app2_tready`** (默认分支才有 `eco2_tready = txin_tready`) ⇒
①自环 ②语义错: `axis_pipe` 正确背压 `s_ready = m_ready || !m_valid`, 退化成 `= m_ready` ⇒
流水寄存器压着字时 app 还能再推 ⇒ **丢字**。修: `assign app2_tready = txin_tready;`。

**教训 (本里程碑最值钱的一条)**: **模块级 TB 绿 ≠ wrapper 分支正确**。原 P5 门只测模块,
APP_MODE 接线错在 xsim 里完全隐身, 直到 Vivado DRC 才炸。→ 新增
`sim/p5sim/run_tb_p5_wrapper.bat` + `tb/tb_p5_wrapper.v` (带 `-d APP_MODE` 例化真
`wrapper_p4`, 跑 app_pattern → axis_pipe → tcp_tx_frame → tx_arb 全链, 逐字节判据)。

**审查 agent 抓到的其它项**: H1 peer 图案相位差 1 字节 (peer 先推进后取字节 / RTL 先取
后推进 ⇒ `peer[k]==RTL[k+1]`; 板级逐字节判据会 100% 失配) — 已修并加 `--pat-selftest`
免板自检; H2 5 个旧文件 (`tb_tcp_tx/tb_tcp_chain/tb_tcp_echo/tb_tcp_tx_dbg` + `wrapper_tcp.v`)
未接 tcp_tx_frame 新输入 ⇒ xsim 悬空 Z 进 ackq ⇒ 纯 ACK 帧 flags/ack 半 X (P4 矩阵覆盖不到)
— 已补齐; M1 `fin_repush` 与 `ack_req` 抢 ackq 条目 ⇒ FIN 重推**永久丢失** (关闭永不完成)
— 清除条件加 `&& !ack_req_ok`; M3 `app_pattern` 在 `ev_down` 直接撤 `pw_valid` (无 tlast)
⇒ AXIS 违约 + 帧器卡 S_RECV — 改为走收尾路径。

**测试 agent 抓到 D1 (阻断, 可复现)**: **同槽背靠背 DEL→ADD 后 `fin_sent_r[slot]` 残留
⇒ 连接永久不可用**。复现: `cfg_del(slot0)` 紧接 `cfg_add(slot0, 新 seq 空间)` (间隔 ~70 拍)
→ 推 2 帧 + `CMD close` → 新会话一帧不发、第 2 个 FIN 永不到来、`app_tx_ready=0000`、
app 已被吞 2052B 而 DUT 停在 `S_IDLE` + `pay_full=1` ⇒ **静默吞数据 + 数据面死锁**。
边界对照: gap≈70 拍 ❌ / gap=4000 拍 ✅ (4000 拍 ≈15 次扫描, 够采到 state=0)。
**修法**: 不依赖扫描时序 — 新增 `cfg_up/cfg_up_id` 输入 (接 `slow_cfg_adp` 的
`ev_up/ev_slot`), cfg ADD 收尾脉冲显式清该槽 `fin_sent_r/rst_sent_r/fin_retx_pend`。
**D2 (同源)**: `s_axis_tready` 的 S_IDLE 分支只挡 `start_data` 不挡 accept ⇒ 帧起不来却照样
把 app 的字收进载荷 FIFO (FIFO 满 + 无人排空 = 死锁, D1 的入口) — 补
`!fin_req[start_id] && !fin_sent_r[start_id]` 与启动门同门。

**修复后复验 (TL 亲自跑)**: 对抗集 **10/10 OK** (含修前 FAIL 的 `reconn_fast`;
顺带新发现 D1 的一个连带效应: 数据面自愈后 `reconn_fast` 用例的 `fin_sent=1` 属新会话正常态);
P4 矩阵 **16/16 EXIT=0**; P5 四门 OK; 重构建 **WNS +0.264 / TNS 0 / WHS +0.019**;
重烧板子复验: app TX 1MB 逐字节零失配 + app RX 32KB `MM=0000` + 计数器自洽。
（⚠️ **平台限定**（2026-09-30 补）：`MM` 读自 **UART 状态行** ⇒ 这是**有 UART 的板**的读数；
**KU5P 上结构性不可读**，见上文 P5a 段的同一条注与 `P7B_W13_AUDIT.md` §②-V25。）

**僵尸进程坑**: 首轮矩阵门失败 (`chain/burst200` EXIT=1) 与测试 agent 的 4 门失败
**都不是判据不符**, 而是残留 `xsim/xsimk/xelab` 进程占住 `xsim.dir` (链接期
`Unable to remove previous simulation file`)。教训: **并行跑仿真必须用独立目录**,
且失败先 `tasklist | grep xsim` 排查是不是文件锁。

### P5a 提交
- `6121050` cpp_peer: dup-ACK 标准语义 + 图案相位修正 + `--rx-only/--expect-pattern`
- `8daa6bd` P5a: app interface 数据面 + 板级双向验证 (35 文件 +5867 行)
- `706ee8c` README: P5a 收官 + P5b-P5e 分解


---

## 2026-09-20 P5b 实现 (应用 RX 流控闭环: 窗口随 frame_fifo 占用收缩 + wu ACK) — 门全绿

**范围**: `rtl/app_ctrl.v` (信用池 winq/pool + 右沿 redge + fc 纠偏写 + wu 请求 +
增量补授 C15)、`rtl/tcp_tx_frame.v` (ackq 8->32 深 + wu 条目最低优先入队)、
`board/wrapper_p4.v` (TCB 写口第 4 级 fc 仲裁 + wu 接线 + 状态行源)、
`rtl/app_status_uart.v` (行尾追加 AK/AD/TS/WQ/WM/WU/PO/PX, 168->220 字符)、
`rtl/app_pattern.v` (C11: RX 图案流 ev_up 重置, 与 TX 侧对称)。

**门**: P4 矩阵 16/16、P5a 四门 + 对抗集、**新 flow 门** (`sim/p5sim/run_tb_p5_flow.bat`:
512KB 慢消费者 + 对端灌数据, 逐拍占用/右沿/窗关-重开/零重传完成)、
**新定向单元门** (`sim/p5sim/run_tb_p5_fc.bat`: occ 四点饱和边界/4GB 回绕/
ev_up 与扫描拍对撞/同槽 DEL→ADD 遗留占用/池补授/wu 电平握手)。

### 关键事实与坑 (按价值排序)

1. **接收窗 (accept) vs 通告窗 (advertise) —— P5b 已知代价/待修 (第二轮更新)**:
   帧里 `ack` 来自 ACK 队列 (请求拍采样), `window` 来自 TCB (上次 fc 写) ⇒
   两者独立陈旧 ⇒ 实际通告右沿 = redge ± 抖动 (C1b 只写了 + 方向)。
   当窗口收到 0 (占用满) 时, 对端在**旧窗口下合法发出**、落在 rcv_nxt 边界上的段
   会被 tcp_rx 的 `seq_diff < ra_rcv_wnd`(=0) 判超窗 ⇒ 永久空洞 ⇒ 其后所有段按
   乱序丢弃 (第一轮 flow TB 实测 34 段)。
   **P5b 第二轮的处置 (C16-修订, 已落地)**:
   ① **治本**: `tcp_rx` 新增参数 `ACC_MARGIN` (默认 0 = 默认构建逐位不变),
      `win_ok` 改用 `acc_wnd = ra_rcv_wnd + ACC_MARGIN`; wrapper 在 APP_MODE 下
      传 **4096** ⇒ 对端按旧窗口发出的在飞段**被接受, 不丢数据** (安全性:
      `occ + W + 4096 + 未判定段(≤1518) = 54766 < 65536` ✓)。
   ② **兜底**: `ackresp` 增加 `|| (seq_eq && !win_ok)` (RFC 793: 不可接受的段也要
      回 ACK) ⇒ 极端情形下对端**立刻**重传, 而不是等 200ms RTO。
   **实测 (flow 门, TB 与 wrapper 同配 4096)**: `seq 丢弃 79→0`、
   `対端重传 75→0`、`图案失配 256→0`、`mac_drop=0`、逐字节完整 ⇒ 零丢失,
   唯一残余是右沿抖动 ≤ 308B (须 < ACC_MARGIN, checker 已加硬断言)。
   ⚠️ **门/板配置必须一致**: TB 若漏传 `.ACC_MARGIN(4096)` 就是"用另一个配置跑门"
   (第一轮 79 丢弃/75 重传全部由此而来) — 见坑 11。
   → 若将来要彻底消除抖动 (P6): 把 tcp_rx 的 win_ok 改用板侧 `redge`
   (精确右沿), 或把 window 字段在帧组装时按 `redge - rcv_nxt` 现算。
2. **C15 多连接语义**: 零拷贝是单一全局 64KB FIFO ⇒ Σwinq ≤ WIN_POOL 是物理约束。
   默认 `WIN_Q_MAX = WIN_POOL` ⇒ 第 1 条连接拿满 48KB, 第 2 条起 winq=0 (窗口 0,
   对端不发)。`_adv multi` 门按此语义更新 (不是放宽判据, 是语义演进); 增量补授
   只在池回收后生效 ⇒ 多连接分池策略是 **P5d** 课题。
3. **C14 零拷贝占用不在 ev_down 释放**: 同槽 DEL→ADD 时遗留占用会与新配额叠加
   (`遗留 > 16KB` 即溢出)。两道保险: ev_up 授予 `min(WIN_Q_MAX, pool - occ)` +
   init/扫描的 redge 一律用 occ 修正 (veto 裸 `rcv_nxt + winq`)。
4. **wrapping 算术三处铁律**: ① redge 饱和 (occ >= winq ⇒ 右沿 = rcv_nxt), 禁裸
   17 位相减; ② W = wcalc 必须判 `wdiff[31]`; ③ **ev_down 不得把 redge 写 0**
   (rcv_nxt ≥ 2^31 时会被序比较判为"未来值"永久留存 ⇒ 窗恒 0 死锁);
   `init 拍` 才重设 redge。定向门 T2/T3 已锁死这三条。
5. **wu/ackq 优先级 (M1 类坑)**: wu 条目必须**最低优先**且 `wu_gnt = 确实入队`
   (若写 `wu_push = wu_req && !ackq_full` 而 ackq_din 的 mux 让 ack_req 优先 ⇒
   gnt 给了 wu 但条目写的是 ACK ⇒ wu_pend 被清而窗口更新从未发出 ⇒ 对端永久停等)。
   `fin_repush` 与 wu 严格互斥 (同源条件), FIN 重推不可被抢。
6. **xvlog 坑**: 给 module 加 ANSI 风格 `#(...)` 参数表会让 **body 里的 parameter
   变成不可覆盖** (`localparam 'RING_CAP' cannot be overwritten`) ⇒ 顶层
   `.RING_CAP(WIN_CAP_5)` 覆盖失效。新增参数必须与既有参数同风格 (body parameter)。
7. **~~tcp_rx pcount 泄漏~~ —— 归因错误, 第二轮已证伪 (勿据此修 P6!)**:
   第一轮把"窗口吃紧期短段被丢"归因到 `pcount` 跨帧残留泄漏。独立复核证伪:
   `state <= S_PAY` 全文件唯一 (tcp_rx.v 的 wcnt==6 判定拍) 且**同拍无条件写
   `pcount` 初值** ⇒ 不存在残留路径 (84 次进入 S_PAY 全部 pcount=2)。
   **真因**: (a) 窗口收缩期 `ra_rcv_wnd == 0` + ack/window 采样时差 ⇒
   `seq_eq && !win_ok` 的顺序段被判超窗 ⇒ 空洞 ⇒ 后续全乱序 (即坑 1);
   (b) TB 侧当时用"只发整段"绕行把该工况从门里删掉了 (假绿)。
   第二轮处置: 撤销 TB 绕行 (C20, 中流短段成为**显式用例**) + tcp_rx 加
   ACC_MARGIN 接受裕度 + 拒收回 ACK (C16-修订); 修完实测丢段 0/重传 0。
   ⚠️ **不要再按"pcount 泄漏"去改 tcp_rx 的 S_PAY 入口**。
8. **门类**: flow 门逐拍断言 `occ ≤ winq + 2816 + 1518` (C1b 的 Δ + 一段, 这是
   §3 判据 ① 的保守上界, 不是"抖动实测值") 且 `occ < 65528`;
   右沿判据 = **抖动幅度 < 512B** 且 **< 接受裕度 ACC_MARGIN(4096)** (后者是真正的
   安全条件: 抖动必须被接受裕度覆盖, 否则合法在飞数据被拒);
   活性观测 `stat_fc_wait_max` (fc 请求最长挂起, > 16384 拍即 Δ 界失效)。
   第二轮实测 (C20 真实短段 + ACC_MARGIN=4096): occ 峰值 49336 (软界 53486)、
   fc_wait_max = 2、健康流 stat_wu = 0 (零额外帧)、`window` 取值含 **0**、
   抖动 37 次 / 最大 308B、seq 丢弃 0、重传 0、逐字节完整。

---

## 2026-09-20 P5b 第二轮 (时序不收敛 + 功能复核修复) — 坑与事实

**背景**: 第一版功能门全绿, 但**全量构建时序严重不收敛** (WNS -3.089 / TNS -3475 /
4027 失败端点), 且复核发现若干功能缺陷 (C16-C20)。本轮修复的坑按价值排序:

9. **流水线 item 必须显式"只活一拍" (本轮最大自伤)**: 扫描块改 3 拍流水后, 第一版
   只在 scan_tick 置 `pa_v <= 1`, **忘了清** ⇒ stage B/C 每拍都拿陈旧
   `pa_*/pb_*` 重放 ⇒ C15 增量补授/fc 写/wu 请求连拍狂发 ⇒ 池被瞬间抽干、
   `pool` 记账全错 (定向门 T5/T6/T8/T9 当场炸)。**铁律**: 流水线的 valid 位必须
   在"每拍默认清零"段 (always 块顶部) 里落 0, 由产生拍覆盖为 1 —— 与脉冲型
   寄存器同一条铁律 (坑 6)。判据: 定向门 T5a (`ev_down 后 pool=C000`)。
10. **扫描块四级算术串一条链 = 时序致命 (22 CARRY4 / 37 级逻辑 / 路由 62.9%)**:
    `winq[c] -> fq -> redge_n -> sdelta -> wcalc -> wu_mark` 全组合 ⇒ 还诱发
    Vivado **跨槽资源共享** (winq[14] → wu_mark[1]), 最差路径 37 级。
    **修法 (已落地)**: ① 扫描拍用 `wscan = fq[15:0]` —— 与 `wcalc(redge_post,
    rcv_nxt)` **逐位等价** (证明: `redge_n - rn = fq <= WIN_Q_MAX < 2^31` ⇒ 夹紧
    分支全假; 且 `sdelta` 的物理含义 = 自上次扫描以来 app 消费的字节数 ≥ 0, 故
    只有 sdelta>0 (redge_post = redge_n ⇒ wcalc = fq) 与 sdelta=0
    (redge_n == redge[c] ⇒ wcalc(redge[c],rn) = redge_n - rn = fq) 两种情形);
    ② 扫描拆 3 拍流水 (T 采样 / T+1 右沿 / T+2 fc+wu+C15) —— 扫描周期 256 拍,
    中间 15 拍空闲 ⇒ 流水免费。
    **⭐ 流水化后 `fc_upd_val` 必须与判据同源**: 判据用 `wscan_r` ⇒ 写值也取**同一个**
    `wscan_r` (置 `fc_pend[c]` 时并存进 `fc_wq[c]`, `fc_upd_val` 按 `fc_id` 从
    `fc_wq` 选)。绝不能用"从注册阵列现算"的组合值 (判据与写值可能不一致 ⇒ 写错窗口)。
11. **新参数/端口必须同步到所有例化点 —— 包括 TB 的"配置镜像" (C12 血的教训)**:
    `tcp_rx` 加了 `ACC_MARGIN` (默认 0) 后, **APP_MODE 的 TB 忘了传 4096** ⇒
    TB 用"无裕度"配置跑 flow 门, 实测 seq 丢弃 79 / 对端重传 75 / 图案失配 256,
    看着像 DUT 缺陷, 实际是**门与板跑的是两个配置**。判据修复后同一次仿真
    三项全归零。**铁律**: 全链 TB 必须镜像 wrapper 的 ifdef 分支参数; 加参数时
    `grep -rn "<module>" tb/ board/` 逐点核对。
12. **TB 激励的图案 LFSR 不能被"另一条流"覆盖**: `flow_build` 无条件写
    `plfsr <= tls; plfsr_rt <= tls;` ⇒ 每次重传都把**正常流**的 LFSR 拽到重传位置
    ⇒ 之后 seq 对而**载荷内容**错位 (sink 侧表现为局部失配后自动对齐)。第一版
    没暴露是因为绕行下 peer_retx 恒 0 (重传路径从未跑过)。修法: 由**调用方**各自
    推进自己的流, 并加独立参考 LFSR (pref/pref_rt) 对账 (PATMM 诊断)。
13. **扫描流水必须对"事件撞车"让位**: 事件块 (ev_up/ev_down) 在 always 里更靠前,
    流水线的 landing 更晚 ⇒ 同一槽的事件若落在流水窗口内, 必须丢弃该 item
    (否则用旧会话数据毒化 redge/fc_pend/wu_pend)。实现: 采样拍守卫
    `!(ev_blk && ev_slot == scan_id)` (C17) + stage B/C 的 `hit_b/hit_c` 比较
    (当拍 + 上拍事件槽号), 定向门 T9 锁死"授予量 = min(WIN_Q_MAX, pool-occ)
    且未被 C15 补授覆盖"。
14. **C18 同槽二次 ev_up 会蒸发配额**: `pool <= pool - g` 覆盖旧 winq 却不归还 ⇒
    Σwinq + pool < WIN_POOL ⇒ pool=0 时永久零窗 (C15 补授要求 pool != 0, 救不回)。
    修法: `pool <= pool - g_grant + winq[ev_slot]` (封顶) + `stat_slot_reuse` 观测
    (寄存器 0x9E); 定向门 T8 锁死守恒式 `Σwinq + pool == WIN_POOL`。
15. **flow 门右沿判据的正确形态**: "严格单调不降"结构性不成立 (ack/window 采样
    时刻不同)。第一轮用 ±(2816+1460) = 14× 实测抖动 ⇒ 能静默放过一次 3 段撤回;
    第二轮改为 **抖动 < 512B (实测 308B 的 ~1.7 倍) 且 < ACC_MARGIN(4096)**
    —— 后者是真正的安全条件 (抖动被接受裕度覆盖 ⇒ 不拒收合法在飞数据)。
    ⚠️ C20 撤销"只发整段"绕行后, 实测最大抖动从 136B 升到 **308B** (真实短段参与),
    故 256B 不可达; 判据值必须随工况重测, 不能照抄。

### P5b 收尾修复 (2026-09-20, checker/TB/文档 only — 不动 RTL)

**背景**: 独立验收 agent 判定 P5b 门全绿 + 板级核心性质成立, 但揪出**判据覆盖**漏洞。
以下改动全在判据/TB/文档层, **未改任何 RTL**。

16. **判据覆盖的三个漏洞 (必修)**:
    - `adv > 4096` (multi 门 conn1) 是**恒假断言**: 该门只注入 150B ⇒ `adv ∈ {0,150}`,
      `150 > 4096` 永假 ⇒ `ACC_MARGIN` 被误设成 60000 也照样 PASS = "接受裕度失控"
      这个安全方向**零覆盖**。改为 **`adv == 150`** 精确钉住 C16-修订 语义
      (整段落进裕度内 ⇒ 必须被整段接受 ⇒ 前推不多不少 150)。
    - conn0 的窗判据曾被放宽成 `(0xC000-8192, 0xC000)` —— 规格 §4c 的 **C19 明确驳回**
      (下界 8192 是注入量的 79 倍, 能放过 17% 的欠通告)。验收实测 conn0 四帧 `win`
      全 == `0xC000` ⇒ **已恢复严格判据 `win == 0xC000`**, conn1 的 `(0,1460)` 保持
      (C15 真语义演进)。
    - ACK 轨迹的"允许集合"此前用**混合连接**的集合 (`ev['ack']` 不过滤 ack_id), conn0 的
      rcv_nxt 值漏进 conn1 的判据窗口 (数值恰好更小 ⇒ 侥幸不误报)。已按 `a[1]` 分流,
      并把 conn1 收紧成**枚举判据** `{pcis+1, pcis+1+150}`。
17. **"接受裕度必须 <= 物理余量"现在有门了 (新 case `accmgn` + 配置断言)**:
    物理不等式 (零拷贝单 FIFO 口径, 与 flow 门 ① 同源): `WINQ(49152) + Δ(2816) +
    U(1518) + 单段(1500) + ACC_MARGIN <= FIFO(65536)` ⇒ **`ACC_MARGIN <= 10550`**。两道:
    ① **配置级**: `tb_p5_adv.v` 把 `TB_ACC_MARGIN` (与 `u_rx` 端口**同一 localparam**)
      dump 成 `ADVCFG` 行, checker 断言它 == wrapper 的 APP_MODE 值 (C12 扩展: 参数镜像)
      且 <= 10550; flow 门同理由**源码解析** wrapper + `tb_p5_app.v` 的镜像值
      (不再硬编码 4096 ⇒ 与 RTL 参数解耦的毛病一起修掉)。
    ② **行为级** (`accmgn`): 在**零配额 conn1** (通告窗 = 0) 注乱序探针段 (带洞 ⇒ 不占
      缓冲、不推进 rcv_nxt), 看 `tcp_rx` 的窗口判决 (win_ok/ackresp):
      `D < ACC_MARGIN` ⇒ **回 ACK** (`stat_drop_seq` +1); `D >= ACC_MARGIN` ⇒ **静默**
      (`stat_drop_nonmatch` +1)。探针 `D=3328` (= C1b 1G Δ 2816 + 512) 必须回 ACK;
      `D=10551` (= 物理余量 +1) 必须静默。
    **灵敏度自测 (必修证据, 已完成)**: TB 副本改 `TB_ACC_MARGIN = 60000` 重跑 `accmgn`
    ⇒ `D=10551` 探针从"静默"变成"回 ACK" (`seq` +1) 且 `ADVCFG` 撞预算 ⇒ 门 FAIL 2 项;
    改回 4096 ⇒ 全 PASS。flow 门同样: wrapper/TB 副本改 60000 ⇒ ⑥ 两条断言 FAIL。
18. **flow 门现已覆盖真 W=0 关窗 (C23 事实更新)**: 独立验收在 362 条 ACK 上统计
    `window ∈ [0, 49152]`, **`==0` 的 2 帧** (ACK #213/#214), `<=1460` 共 **11 帧**,
    且板侧 `stat_wu = 2` (wu 通路真的发出过, 不只是单元级 `tb_p5_fc` T7)。
    ⇒ C23 早先记的"帧里从未出现真 W=0 / ==0 的 0 帧"是**撤销 C20 绕行之前**的旧口径,
    已过时并更新。**措辞约束保留**: 判据本身只要求 "<= 1 段", 不得写成"判据证明了
    真 W=0 关窗"; 可写"本门现已走过真 W=0 + wu 重开"。

### P5b 板级观测补充 (2026-09-20, 数据来自验收 agent 板级实测)

- **`WU` (= `stat_wu`, 已发窗口更新 ACK 数) 的触发源 = 连接建立瞬间的配额竞争**:
  与 `PX` (`stat_pool_exhaust`) **同步 +1** —— 建连时 `pool` 已被占 ⇒ 授予量
  `g < WIN_Q_MAX` ⇒ 置 `stat_pool_exhaust` 且窗口需一次纠正 ⇒ 发 wu。
  **冷启动单次 4MB 运行 `WU = 0`** (无配额竞争 ⇒ 零额外帧) — 与 C6 "数据流正常时
  `W_new` 恒定 ⇒ 零额外帧" 的设计意图一致。
- **板级两张 UART 快照闭合 `W + occ ≈ winq`** (窗口收缩公式 `W = winq - occ` 在板级成立,
  即 C1/C2/C4 的闭环):
  · `RW=1E40` (7744) / `OC=0A1E8` (41448) ⇒ 和 = 49192 (winq 49152, 差 +40)
  · `RW=2078` (8312) / `OC=09F60` (40800) ⇒ 和 = 49112 (winq 49152, 差 -40)
  差值 = 字粒度取整 (occ 按 8B 字向上取整) + `W`/`OC` 两个字段的采样时刻差, 与 flow 门
  ③ 的"抖动"同源 (非撤窗)。

### P5b 第二轮时序: 根因与结果 (2026-09-20 落档)

**根因 (坑 10 的量化)**: 扫描块把四级算术串成**一条组合链** ——
`winq[c] → 占用差 fq → 右沿 redge_n → sdelta → wcalc → wu_mark`,最差路径
**37 级逻辑 / 22 个 CARRY4 / 路由占比 62.9%**,还诱发 Vivado **跨槽资源共享**
(`winq[14] → wu_mark[1]`)。

**修法**: ① **等价化简** —— 扫描拍直接用 `wscan = fq[15:0]` 顶替 `wcalc(redge_post, rcv_nxt)`:
`redge_n - rn = fq ≤ WIN_Q_MAX < 2^31` ⇒ wcalc 的夹紧分支全假;而 `sdelta` 的物理含义 =
"自上次扫描以来 app 消费的字节数" ⇒ **`sdelta ≥ 0` 恒成立**,只剩两种情形 ——
`sdelta > 0`(`redge_post = redge_n` ⇒ 两式同为 `fq`)与 `sdelta == 0`
(`redge_n == redge[c]` ⇒ 两式同为 `redge_n - rn = fq`) ⇒ **两式逐位恒等 (非近似)**,
饱和分支下亦成立。② **扫描拆 3 拍流水** (采样 / 右沿 / fc+wu+C15): 扫描周期 256 拍、
中间 15 拍空闲 ⇒ 流水免费。

**结果**: WNS **−3.089 / TNS −3475 / 4027 失败端点** → **WNS +0.271 / TNS 0.000 /
0 失败端点** (routed;WHS 仅 **+0.049**)。
⚠️ **代价是 hold 边界极薄**: 最差 hold = retx RAM `wa_o_r → ADDRARDADDR`(0 级逻辑,纯布线),
place 阶段曾 −0.159 / 718 端点,全靠 router 收口 ⇒ **后续每次构建都要盯 WHS**。

### P5b 观测口径与工具坑 (2026-09-20 落档, 编号接坑 18)

19. **C16 的定性 (独立测试 agent 的限定, 口径必须照抄)**: 窗口塌陷期的顺序段
    (`seq_eq && !win_ok`) 被 `tcp_rx` 静默丢弃 —— 这是**活性/时延问题, 不是内存安全问题**:
    既没越界也没写坏数据, 代价只是对端白等一个 RTO (200ms) 才重传。`ACC_MARGIN`(接受界
    宽容于通告界) + "拒收回 ACK" 兜底治的是**丢包重传成本**,不是溢出。
    物理预算式 (零拷贝单 FIFO 口径):`WINQ(49152) + Δ(2816) + U(1518) + 单段(1500) +
    ACC_MARGIN ≤ FIFO(65536)` ⇒ **`ACC_MARGIN ≤ 10550`**;wrapper 取 4096 (余量 ~10.7KB)。
    该式现有双门: **配置级** (`accmgn` case 的 `ADVCFG` 断言 = 与 wrapper 同值且 ≤ 10550) +
    **行为级** (D=3328 必回 ACK / D=10551 必静默,灵敏度自测 = 改 60000 ⇒ FAIL 2 项)。
20. **C12 扩展成工程坑: "所有例化点" 包含"参数镜像"这一层**: `tcp_rx` 新增
    `ACC_MARGIN`(默认 0) 后,APP_MODE 的全链 TB **漏传 4096** ⇒ **门与板跑的是两个配置**,
    症状看着像 DUT 缺陷 (79 段丢弃 / 75 次重传 / 256B 图案失配),补齐参数后**同一次仿真**
    三项全归零。**铁律**: 加参数时除 `grep -rn "<module>" tb/ board/` 补端口外,
    还要核对每个例化点的**参数值是否镜像 wrapper 的 ifdef 分支取值** (已升级为 CLAUDE.md 坑 11)。
21. **板级工具三坑 (全在 `tools/*.py`, 都是"判据全过却报 FAIL / 报假数据")**:
    - `board_p5b_check.py` 的 `parse()` **定义了却没被调用** ⇒ 直接 `d.get()` 撞
      `AttributeError` (板级 agent 实测踩到;已修 `d = parse(line)`)。
    - **GBK 控制台下 print 非 ASCII 抛 `UnicodeEncodeError` ⇒ 退出码变 1**: 任何按 exit code
      判 PASS/FAIL 的自动化都会**误报 FAIL** (实测量: 判据全过却 exit 1)。两个板级脚本
      开头都加了 `sys.stdout.reconfigure(encoding="utf-8", errors="replace")` 兜底。
    - `pc_p5b_win_test.py` 的**图案必须先于 connect 生成**: 板侧关闭超时 400ms
      (FIN_TO_LIM=195313 轮 @125MHz = 4×RTO),而本机 4MB 图案生成约 **1.13s** ⇒ 先 connect
      再生成时,板侧早已发完自己的 1MB + FIN 并超时 RST ⇒ 连接被拆、数据全丢
      (板级实测 PC WinError 10053 / 板侧 RX=0 RS=1)。
22. **`--offset` 的口径反转 (C11 的连带)**: C11 让板侧 `rx_lfsr` 在 `ev_up` 重置 ⇒
    **每个连接都从图案头开始**,所以脚本 `--offset` 的**正确值恒为 0**;照旧文档逐轮累加
    offset 反而会得到**假的 MM 失配**。脚本与文档都写明"默认 0 就是对的"。
23. **`FI` 的口径 = fast path 计数, 不是线上的 FIN 帧总数**: UART 状态行的 `FI` 只是
    `board/wrapper_p4.v` 的 `tx_stat_fin` (fast path)。慢路径 HLS **另发 FIN+ACK**
    (`hls/src/layer_tcp.cpp` 的 `T_SYN_RCVD` 收 FIN 分支,seq 取 HLS 自己停住的值) ⇒
    **"一次 close 恰 1 帧 FIN" 这类判据在线上不成立**;板级看到的 `seq=1` 是 Wireshark
    相对口径。该帧**不是缺陷** (反而是全设计里唯一正确 ACK 对端 FIN 的帧) ——
    要改的是**观测层口径**,不是 RTL。同类:`WU`/`RS` 也都不是 PASS 判据 (见
    `tools/board_p5b_check.py` 头注释的完整口径)。

---

## 2026-09-20 P5c 关闭语义完善 (FIN/RST/abort + 关闭完成 + 关闭超时) — 门全绿 + 构建/板级通过

**范围** (默认构建逐位不变;新增逻辑一律走"默认路径无可达置位 ⇒ 自然恒 0"的**无 ifdef** 写法):
`rtl/tcp_tx_frame.v` (T1: G1 FIN 重推死锁 / G9 `ring_delta` 下溢洪水 / G4 死连接重传 /
G6 跨会话残留;T3: `tx_blk` fence + `o_rst_sent`)、`rtl/app_ctrl.v` (T3: G2 关闭超时;
T3b: 超时活性判据;G3: abort 的 `state=0` 写与配额归还)、`board/wrapper_p4.v` (接线 + 状态行源)、
`tb/tb_p5_app.v` + `tools/gen_stim_p5_app.py` (T4 close 门)、`tb/tb_app_fc.v` (T3b 活性判据)、
新 `sim/p5close/` (T2 定向证伪门)、新 `sim/p5c_t3/` (fence 单元门)。

**门**: `p5close` 双门 (G1: FIN 帧 **1→17** 且下拍重试成功;G9: flood **31 帧→0**,全文无
`ffffffff`)、P4 矩阵 16/16、P5b 全门 (app/wrapper/status/adv×11/flow/fc)、fence 门 PASS、
`tb_app_fc` **110 PASS** (**负对照** 强制 `act_now=0` ⇒ **FAIL 22**,失败项正是新断言 ⇒ 门有鉴别力)、
`run_tb_p5_app.bat close` **EXIT=0** (39s;5 条判据 + 3 条负向对照 `neg_rst`/`neg_fin`/`neg_pool`
**三者都 FAIL**)。**T5 取消** —— 计划的三例 (close_simul/close_timeout/abort_fence) 已被
T4 判据④ / T3b 的 T12-T13 / `tb_p5c_fence` F3 + `tb_app_fc` T11 覆盖,不重复造门。

### 关键坑与事实 (按价值排序)

1. **关闭超时必须带对端活性判据 (T3b, 板级证伪 TL 裁决后的修正)**: 板侧发完自己的 1MB + FIN 后,
   PC 仍在灌 4MB (**合法半关闭**);旧判据 (`fin_sent[c] && c_state==ESTAB`,**不看对端活性**)
   400ms 到点就 RST ⇒ **PC 的 4MB 全丢** (板侧 RX=0/RS=1,PC WinError 10053);线上时序
   FIN@41ms → 最后数据字节@62ms → RST@FIN+400.017ms。
   **修法 (零新增状态/端口)**: 复用既有 per-slot 扫描快照 —— `act_now = (rc_rcv_nxt !=
   c_rcv_nxt[scan_id])` (快照与计数同周期、同 always 块非阻塞赋值 ⇒ 读到"上次扫描值",逐位精确;
   `!=` 比较 4GB 回绕安全),`to_fire` 加 `!act_now` (收严:否则"恰好第 LIM 轮到达数据"那拍会用
   **旧**计数误触发),计数块 `if (act_now && !to_fired[scan_id]) fin_to <= 0` (触发后配额已归还,
   不得"复活";计数须继续走向 `fin_to_max` 驱动 `st_grace` 兜底)。
   **精确语义**: 静默 = 该槽连续 FIN_TO_LIM 轮 `rcv_nxt` 未推进 ⇒ 400ms 无进展才 RST;
   任一轮有推进 ⇒ 从**最后一次进展**重新起算 (`rcv_nxt` 只在对端新数据被接受时推进,
   纯 ACK/重复段不推进) ⇒ 精确等价"对端仍有数据流"。
   **判据 (TL 采纳 T3 的质疑)**: 必须查"**线上真的出现 RST 帧**"(FCS 有效)+"**配额真的归还**"
   (新槽 `rcv_wnd != 0`),不能只查 `rst_req` 位。
2. **G1 的致命点不是 `ackq_full` 那一支**: `ackq_full` 支是**死代码** (排空拍要求 `!ack_pend_r`,
   而 `ack_pend_r <= !ackq_empty` ⇒ 上拍队列空 ⇒ 排空拍 `ackq_full` 恒 0)。真凶 =
   **`retx_active <= 0` 无守卫** —— 被 `ack_req` 抢的那拍 `fin_repush=1` 仍成立,条目被
   `ackq_din` 的 mux 吞掉;注释写"下一轮 ring 排空拍再重推"但代码**给不出下一轮**
   (`snd_nxt == snd_una` ⇒ RTO 装表恒假 ⇒ 再无 svc) ⇒ **FIN 永不重发 ⇒ 关闭永不完成**。
   修法: 排空拍"**确实入队才清 pend / 才结束会话**" (`ring_delta=0` 时每拍都是排空拍 ⇒ 下拍继续试)
   + RTO 装表条件加 `|| fin_retx_pend[scan_id]` 兜底 + FIN 被 ACK 后清标志
   (`rb_snd_una != fin_seq_r` ⇒ 清) 防 spurious FIN。默认构建下相关位恒 0 ⇒ **无需 ifdef**。
3. **G9 = `ring_delta` 下溢洪水 (本轮最高危)**: `blocked`(epoch=15) 时不回卷,而 FIN 在飞
   `snd_nxt = fin_seq+1 > retx_hi = fin_seq` ⇒ `ring_delta` **下溢 `0xFFFFFFFF`** ⇒ ring 洪水
   重放**逐字节可验证的旧数据** (T2 实测 31 帧 / 12000 clk ≈ 490MB/s;投影 **2941758 帧 /
   4096 MB**),且触发不稀有 (生产 RTO 100ms 下 close 后约 **1.7s** 自己走到,非层级灌值)。
   修法: `retx_deny = blocked && fin_sent_r` (只否定"blocked && FIN 在飞",可证与默认构建逐位
   等价) + `retx_hi` 加 `&& svc_rewind` 守卫 —— TL 原稿在"FIN 已被 ACK 但挂起位残留 +
   无回卷"时**仍会下溢**。**T1 纠正 TL 定稿 4 处,全部接受** (含"给 `fin_repush` 加
   `rb_state==1` 会引入 **TX 数据面死锁**:重试期若连接被 DEL ⇒ 永不入队而 `ring_eval`
   压制全部 `S_IDLE && !ack_pend` 拍 ⇒ 整个 TX 面死锁 ⇒ 必须留两条退路)。
4. **G1 × G9 在同一连接上互斥** (G1 的死锁态让 `snd_nxt==snd_una` ⇒ 不再累积 epoch ⇒
   不触发 G9): 同一个 svc 代码体的两个出口,门必须**分别**构造 (T2 的双门就是为此)。
5. **G2/G3 的四个审查真缺陷 (T3 自查 + 修)**:
   ① **配额泄漏** —— 超时只写 `state=0` 不还配额 ⇒ 池被死连接占死 ⇒ G2 想治的"再也建不了连"
   以**配额形式复活** (实测新槽 `winq=0/rcv_wnd=0` 收不了数据);
   ② **RST 结构性发不出** —— 触发同拍挂 `state=0` ⇒ `rb_state==1` 门关闭,而 RST 要等
   `tcp_tx_frame` 扫描,两模块 tick 同相 (复位起自由运行 /16,同槽访问间隔必为 16 整数倍)
   ⇒ 永不发出;故 `state=0` 改由 `st_req_now` 挂出 = "RST 确实发出 (`rst_sent` 上升)" 或
   "再数 `FIN_GRACE=4` 轮仍发不出" 的兜底;
   ③ **清位 ≠ 落地** —— `st_pend` 只在 `fc_sel_r==5` (本次落地的确是 state 写) 时清,
   否则一次窗口写的 `gnt` 会吞掉 state 写请求且 `st_done` 已锁 ⇒ **永久丢失**;
   ④ 脉冲隔离 (保证 `o_ev_down` 是孤立 1 拍)。
   事件投递**用脉冲** (`o_ev_down/o_ev_slot`),**不推事件 FIFO** (超时事件无 peer/kind 只 2 位/
   板级无 CPU 消费者 ⇒ FIFO 投递今天零功能价值;真消费者 `app_pattern` 消费的就是这一对) ✓。
6. **R8 (预存 P5b 漏洞, 本轮闭合)**: C15 增量补授 与 ev_up 的 C18 **同拍各按同一旧池余额
   各授一份** ⇒ `Σwinq` 可达 **2×WIN_POOL** (可越 64KB 物理界)。修法 = C15 条件加 `!ev_blk`
   (只延后 ≤256 拍,不饿死) ⇒ 守恒恢复。
7. **T3 的时序风险预测被构建证伪 (构建 agent 纠正, TL 采纳)**: T3 自评头号风险
   `u_tcp_echo/wptr → u_app_ctrl/pool_reg[...]/D` 实测 slack **1.149ns (改善 +0.60)**,
   该锥由布局布线主导 (route 68.8%),连 top-30 都进不去 ⇒ **"归还路径寄存器化 1 拍"不做**
   (会给 `Σwinq + pool == WIN_POOL` 的同拍饱和不变量引入 1 拍信用归还延迟)。
   ✅ `tx_blk`/`tready` 锥判断正确 (实测 3.533ns);T1 的 ackq select 锥改善 (0.549 → 1.000ns)。
   ⚠️ **新记录的上界风险**: 真正的近临界族是 `u_tcp_tx/ack_pend_r_reg → u_tcb/*/CE`
   (LL=13, slack **0.465–0.523**,占 #4–#30) 与 `→ tcp_len_r[*]/D` (LL=19, 0.465) ——
   任何给 `ack_pend_r` 扇出或 TCB CE 路径加重逻辑的改动都要先评估。
8. **T4 发现的语义边界 (P5c 不修, 归 P5d/P6)**: **`scan_now` 饥饿 ⇒ close/abort 延迟无上界** ——
   `fin_push`/`rst_push`/RTO 装表都只在 `scan_now` 拍评估,而 `scan_now` 要求 FSM `S_IDLE`;
   app 饱和发送时 FSM 几乎恒在 `S_RECV/S_PAY` (74K 拍窗口内 `scan_now` 仅 **36** 次) ⇒
   RST/close 被**推到 app 数据流结束才发** (生产 1MB ≈ 8ms)。判据仍全绿 (RST 确实发出、
   顺序正确)。**推论**: G3 的 fence 在**全链 close 门内是空判据** (RST 总在数据流末尾发出);
   非空验证由 `sim/p5c_t3/tb_p5c_fence.v` 的 F3 (RST 后同槽 400 拍 `s_axis_tready` 恒 0
   且零新帧) + `tb_app_fc` T11 承担。
9. **异常 A 的结论: HLS 慢路径 FIN, 不是缺陷** (TL 初判正确, 板级 agent 的假设被否证):
   DEL 路径上多出的 `seq=1 ack=65538` FIN 帧出自 `hls/src/layer_tcp.cpp` 的 `T_SYN_RCVD`
   收 FIN 分支;含**真 HLS 网表**的 `tb_p4_chain` 复现逐字段同签名帧,对照变体 (FIN 的 ack
   改成 `c.seq`) **不发**该帧 ⇒ 分支判据钉死;fast path **结构性发不出** `seq=1`
   (FIN seq 恒取 `rb_snd_nxt`)。要改的是**观测层** —— 见 P5b 坑 23 的 `FI` 口径。
10. **T1 的残余未修 (记录)**: ackq 条目**不带 seq** —— FIN 条目入队后、等弹出那 1 拍内若对端
    ACK 到达,弹出时按当时 `rb_snd_nxt` 取 seq ⇒ 仍可能发 `seq = fin_seq+1` 的 FIN
   (老代码同缺陷;不变式守卫把窗口从"整个重试期"缩到 **1 拍**);彻底修需 ackq 条目带 seq
   (接口改动) ⇒ 归 **P5d**。

### 构建 (全量 APP_MODE, 2026-09-20 12:24-12:30, 通过)

| 指标 | P5b 末 | P5c |
|---|---|---|
| WNS | +0.271 | **+0.137** |
| TNS / 失败端点 | 0.000 / 0 | **0.000 / 0** |
| WHS | +0.049 | **+0.041** |
| THS / 失败端点 | 0.000 / 0 | **0.000 / 0** |
| 面积 (placed) | LUT 47256 / FF 39436 | LUT **49426** / FF **39887** |
| Block RAM | — | **310** / 445 (69.66%) |

位流 `wrapper_p4.bit` 11,443,735 B @12:30,**晚于最后 RTL 改动 (11:38) 52 分钟** ⇒ 新鲜可用。
WNS 的 0.09ns 退化与 T1/T3 的逻辑深度无关 (落在 `retx we_o_r → WEA` 这类布局布线方差族,
与 P5b 基线 #1 同族);T3b (活性判据) 在 `app_ctrl` 的改动落在同一族上。

### 板级 (2026-09-20)

- **关闭超时活性判据**: FIN 之后对端**持续有数据 5.2s 不被 RST** (旧判据 400ms 就 RST);
 对端**静默 400ms 后 RST** ✓ —— 合法半关闭的数据流不再被误拆,无响应的连接仍能拆干净
  (配额归还 + `state=0`)。
- **对端主动关闭 (阴性对照)**: PC `shutdown(SHUT_WR)` ⇒ 走 HLS 慢路径 DEL ⇒ `RS` **不增**
  (线上无 RST 帧) ⇒ 超时**不误触发** ✓
- **配额归还后新连接可用**: 超时拆除后新连接拿到满窗 `WQ=C000` 并收全数据 ✓
  (累计 `RX=10,960,896` 逐字节精确、`MM=0`;工具 `BOARD_P5B OK`)
- 板级观测口径同 P5b 坑 19/23: `RS` 递增 = 超时 RST (正常语义);`FI` = fast path FIN 计数。
- **判据鉴别力的教训 (TL 自省)**: 首轮板级任务书要求"4MB 用例 `RS` 必须为 0" —— 该判据
  **不可达且无鉴别力**: 脚本的 `drain` 静默窗口 (>400ms) 必然产生一次**良性** RST,且旧位流
  在同样条件下也会给出 `RX=0x400000` (4MB 线上耗时仅 71ms ≪ 400ms)。**上一轮 `RX=0` 的
  主因其实是工具 bug** (`pc_p5b_win_test.py` 在 `connect` 后才生成图案, 1.02s 吃掉超时窗口),
  活性判据的问题真实存在但**只在"FIN 后持续小数据流"场景显现** ⇒ 真验证靠**连续灌注
  500×4KB×12ms 间隔**的决定性实验。**教训**: 判据要选"只有修复后才成立"的量, 别选
  "两版都成立"的量。

---

## 2026-09-20 P5d 多连接加固 (信用分池 / 动态接受裕度 / 并发关闭门 / HLS 槽释放 / 0 载荷 opener) — 门全绿 + 构建/板级通过

**范围**:
- **D1** (`rtl/tcp_tx_frame.v`): TX 启动/接受门补两项 —— ① `tx_blk` 加 **`rst_req`**
  (G3 fence 原来只覆盖 `rst_sent_r` = "RST **已发出**", 而 RST 要等一次扫描 + 组装,
  最长 ~300 拍的 [app 请求 abort, RST 上线] 窗口里数据帧照样能起 ⇒ 给已被 app 中止的连接组帧);
  ② 残余 F 项闭合 —— 启动/接受门再要求该连接 **ESTAB** (`st_ok`, 即 `rb_state==1`;
  fin_push 写 ackq 的 T+1 拍 `ack_pend_r` 仍为旧值 0, 若此刻 `fin_req` 刚被清而 `fin_sent_r`
  仍 0 ⇒ 三项全 0 ⇒ 已拆连接的帧被起, CAM 已清 ⇒ dst MAC=0 垃圾帧 + FIN 落地 seq 漂移)。
  口径: `tx_blk` 是 16 位按连接位图而 `rb_state` 是**当前 rb_id 那一个**连接的组合读 ⇒ 状态门
  **只对 `start_id` 那一位**做, 且**只准出现在 S_IDLE 子句**(S_RECV 拍 `rb_id = cur_id` 查的是
  别的连接)。该项**包 `ifdef APP_MODE`**: 它是**常驻**黑名单 (释放只能等该槽被重新配成 ESTAB),
  默认构建的 echo 数据面没有 app 侧就绪门 (帧一进 FIFO 就不可撤) ⇒ 对端 FIN/RST 后残留帧会永久
  占住队首 ⇒ 整条 TX 面饿死 (P5a-D1 同族)。门 `sim/p5d_d1/` (`GATE tb_p5d_d1: PASS`)。
- **D4** (`rtl/app_ctrl.v`): `WIN_Q_MAX` 参数 → **可写寄存器 `wq_cap_r`** (地址 `0x0C`,
  复位默认 = 旧参数 `0xC000`)。**窗口一旦通告不可撤销 ⇒ 每条连接的上限必须在建连之前设小**:
  app 在建连前写 `WIN_POOL/N` ⇒ `Σwinq <= WIN_POOL` 由构造保证。**不做成 wrapper 传参**
  (坑 11 —— 参数化会强制所有 TB 镜像取值, 漏一个就是"门与板两个配置"); 参数只剩"复位默认值"语义。
- **H-fix** (`rtl/tcp_rx.v` + `board/wrapper_p4.v`): `ACC_MARGIN` 参数 → **输入端口**, 由
  wrapper 查表 + **寄存器**下发 `min(4096, 10550/N)`, 下界钳 `3328` (N = ESTAB 数;
  10550 = 65536 − WIN_POOL(49152) − Δ(2816) − U(1518) − SEG_MAX(1500))。默认构建与各默认 TB
  显式传 `16'd0` ⇒ 逐位不变; 端口名**保持大写**是故意的 (工具按 `.ACC_MARGIN` 文本解析)。
- **D5** (门): 新 `tb/tb_p5_multi.v` + `tools/gen_stim_p5_multi.py` + `sim/p5d_multi/`
  (3 连接并发大流量 + 可编程慢消费者 + 并发 close; 5 个独立工作目录 main/neg_wq/neg_mgn/
  neg_mgn0/known_idle_fifo)。
- **opener** (`rtl/app_pattern.v`): 每帧首字改成 **0 载荷占位字** (`tkeep=8'h00`, `tlast=0`),
  帧器只按 `pop8(keep)` 计长 ⇒ 不入 FIFO / 不进 ring / 不推进 plen/tap_seq ⇒ 结构性根除跨会话
  载荷泄漏 (见下 ⑥); 代价 1 拍/帧 (帧周期 ~1650 拍)。
- **D6** (`hls/src/layer_tcp.cpp`): HLS 槽释放 —— bare SYN (无 ACK) 落在**非空闲**槽 = 对端重新
  发起该四元组 (旧会话已在本地拆除/失联) ⇒ 先 `CFG_DEL` 清 fast 侧残留, 再把槽归零、由既有
  "全新 SYN" 路径接管 (与首建连**逐字段同码**, 不新增状态/流水线/缓存); 另加槽耗尽观测计数
  `tcp_stat_no_slot` (纯寄存器, 不新增端口)。
- 附带: `tb/tb_frame_fifo.v` 新增"长只写后首读"**永久回归**; `sim/p5c_t3/tb_p5c_fence.v` 激励
  修正 (F2 挂上的 `rst_req[0]` 一直挂到 F5, 与真链路不符 —— 真链路里它是成对释放的电平;
  挂着 abort 请求却要求"帧恢复可发"正是 D1 要禁的行为 ⇒ 按真链路补一次释放,**判据文本一字未改**)。

**门**: P4 矩阵 **16/16**(隔离复跑) / `p5close` / `close` / `sim/p5c_t3` fence / app·wrapper·
status·fc(**110**)·flow / adv×11 / **`p5d_multi main` 判据①-⑨ = 122 checks / 0 FAIL** /
`neg_wq`(不分池)⇒**①FAIL** / `neg_mgn`(裕度 4096)⇒**④FAIL** / `neg_mgn0`(裕度 0)⇒**⑥⑦FAIL** /
`p5d_d1` **PASS** / `sim/p5e_win` **PASS**。`known_idle_fifo` 由"必须复现缺陷"改判为**正向守卫**
(失配字节必须为 0)。

### 因果修正链 (本轮最有价值的部分, 按价值排序)

1. **修 H-fix 的真实价值不是"防可达溢出", 而是"守文档化保守界 + 覆盖接受漂移"**。
   复核发现 Σ(当前窗) = Σ`max(0, winq − occ)` **随 occ 塌缩** (zero-copy 单 FIFO 里窗与占用
   共享同一笔额度) ⇒ 上界在 **occ = 0** 处取最大, 而 3 连接实测 `mac_drop` **恒 0** ⇒
   旧常量 4096 在这条通路上**抓不到可达溢出** (推论: "N×4096 超 10550" 是**契约/文档化**的
   保守界破缺, 不是当时可复现的内存事故 —— 判据④因此写成**契约式**而非行为式)。
   它的**真实**价值在另一条: `neg_mgn0` 实测 (裕度强制 0) ⇒ 窗塌陷期的顺序段被拒 (seq=2) +
   对端 go-back-N 回卷重传 2 次 (判据⑦ FAIL) —— 裕度是**接受漂移**的唯一兜底 (C16-修订的板级
   病理), 缩到 0 立刻复现。**结论**: ④ 与 ⑦ 两条判据分别证明"界守住"与"漂移被覆盖", 缺一不可。
2. **opener 的"窄窗"不是罕见现象**: `axis_pipe` 的 `s_ready = m_ready || !m_valid` ⇒ app 呈交口
   有 **1 拍前瞻**: 帧 N 的末字被帧器收走的**同拍**, pipe 就锁存了帧 N+1 的首字; 此后帧器要花
   S_WAIT/S_HDR/S_PAY ≈ **195 拍**发完帧 N, 期间一个 beat 都不收 ⇒ 该字在 pipe 里滞留 ~195 拍
   = 帧周期的 **12-13%**, **每个帧边界都出现** (不是"极窄窗口")。这正是 D1 的 fence 曝光出来的
   既有隐患 (见下 ⑥)。
3. **`frame_fifo` 的"8B 错位"是 TB 的 0 延迟竞争, 不是模块缺陷 (证伪)**:
   判据 = **TB 侧影子写流逐拍断言读侧恒等** (`dout(N) === mem[rptr(N)]`): MEMMON 实测
   `checks=263674 bad=1`, 且那 1 拍**恰在 readiness 变化同拍**。触发与方向无关 ——
   `sink_rate` 从 0 变 1 (`rate=1 cyc=0` 那一拍) 一样破: 脚本的 `22: sink_rate = sa;`
   **阻塞赋值**在时钟沿同一步改 readiness ⇒ `frame_fifo` 的组合读址 `r_ad = rptr + rd_ok`
   沿后变化 ⇒ unisim BRAM 采到"沿后"地址而 rptr 寄存器采到"沿前"值 ⇒ 读输出提前一个字
   (坑 3 的复刻)。改成分级非阻塞落地后同一 RTL 下 `miss 8 → 0` (main 门 122 checks / 0 FAIL)。
   ⇒ **`known_idle_fifo` 从"预存缺陷探针"改判为"长只写后首读逐字节守卫"** (常驻回归)。
4. **D6 的实际影响被重新定级**: stale 槽**会被 RTO 扫描自释放** (~2-5s ≈ `RTO_MIN 10e6 pass`
   × ~52 cycle/pass) ⇒ 不是"永久建不起连", 而是**"重连延迟 ~1s + 每次多一个 RST"**。
   默认轮间隔 (`--gap 4.0`, 轮周期 ~5.5s) **恰好晚于自释放** ⇒ **两版位流不可分** (这解释了
   为何"判别性变体"必须另造, 见下教训)。
5. **D6 板级逐帧签名** (`--gap 0.6`, 同四元组重连): pre-D6 线上 =
   `SYN → SYN+ACK(ack=旧 ISN+1, 无 cfg ADD) → PC RST → 1.0s 后 SYN 重传才成功`
   (T_SYN_RCVD 只重发 SYN+ACK 不重发 cfg ADD ⇒ 对端"握手看着正常"但 fast 侧无 TCB = 死数据
   路径; T_ESTABLISHED/T_LAST_ACK 则**完全静默** ⇒ 对端 connect 超时)。
6. **修复会曝光既有隐患 (D1 → opener)**: D1 的 fence 把"连接不可发"这一档做实之后,
   `app_pattern`/`axis_pipe` 的**跨会话残余字**才显形 —— 帧边界上 pipe 里的下一帧首字若跨过
   DEL→ADD (新会话/新 ISN) 就被当新会话首帧首字收下: 无 opener 时是 8 字节**旧流载荷** ⇒
   新会话整段图案偏移 8 (D1 观测到的"8B 循环移位 / 计数差 8"); 有 opener 时是 0 载荷占位字
   ⇒ 只是"预开一帧", 载荷从新会话起点算 = **零泄漏** (`sim/p5e_win` 的 W1-W4 判据)。

### 通用教训 (单列)

**判据必须选"只有修复后才成立"的量 —— 本轮两次踩坑**:
① (P5c 首轮板级, 见上段) "4MB 用例 `RS` 必须为 0"**不可达且无判别力** (drain 静默窗口必然产生
一次**良性** RST, 且旧位流在同样条件下也给出 `RX=0x400000`);
② (P5d) A/B 用的"判别性变体"在**默认轮间隔**下两版不可分 —— 轮周期 (~5.5s) 晚于 D6 的
RTO **自释放**窗口 (~2-5s) ⇒ 必须把轮间隔缩到自释放之前 (`--gap 0.6`) 才得到
`post-D6 15-23ms vs pre-D6 ~1.0s`。**造判别性实验前先算清"缺陷的自愈时间尺度"**。

### 记录项 (现象/口径, 不是缺陷)

- **`RS`/`EC`/`ST` 不能做 D6 判据**: `RS` 每轮重连 +1 (关闭超时 RST 的正常语义)、`EC` 两版都 00、
  `ST` 只反映 fast path state ⇒ 三者对 D6 "两版一样"。
- **3 槽耗尽的签名可达但 D6 修不了**: `tcp_find` 对不匹配四元组在**无空槽**时返回 −1 ⇒
  bare SYN 被静默丢弃 (已加 `tcp_stat_no_slot` 观测) ⇒ "3 次泄漏后彻底不能收连"这一半是
  **策略**问题, 不在 D6 的修法里。
- **`ACTIVE_CONNECT=1` 让板子每 ~6.7s 自发占一个 HLS 槽** (当前 netlist 的 SourceFlags 即
  `-DACTIVE_CONNECT=1`) ⇒ `MAX_TCP_CONN=3` 的包线里必须扣掉一个。
- **烧录不会改写 `.bit`**: 位流 mtime 保持构建时刻 (18:16), 18:30/18:54 两次烧录均未变
  ⇒ 判"位流新鲜度"只能用 `mtime` vs 最后 RTL 改动, **不能用烧录时刻**。
- **`DP` (事件丢弃计数) 随重连爬升** (实测 3 轮 0002→0005, 每轮 +1): 疑似 demo app 的事件
  FIFO 消费跟不上 (非缺陷, 但任何按 `DP==0` 写的判据都会误报)。

### 构建 (全量 APP_MODE, 2026-09-20 17:47 pre-D6 / 18:16 post-D6, 均通过)

| 指标 | P5c 末 | P5d pre-D6 (17:47) | P5d post-D6 (18:16) |
|---|---|---|---|
| WNS | +0.137 | +0.272 | **+0.268** |
| TNS / 失败端点 | 0.000 / 0 | 0.000 / 0 | **0.000 / 0** |
| WHS | +0.041 | +0.052 | **+0.035** |
| THS / 失败端点 | 0.000 / 0 | 0.000 / 0 | **0.000 / 0** |
| 面积 (placed) | LUT 49426 / FF 39887 | — | LUT **48938** / FF **39827** |
| Block RAM | 310 | — | **311** / 445 (69.89%) |

**0 失败端点 / 0 DRC error**; 位流 11,443,735 B @18:16 (晚于最后 RTL 改动)。
**"改 HLS 的实际代价"**: `+0.272/+0.052 → +0.268/+0.035` ⇒ **无实质退化** (HLS 只是换网表,
不新增外部逻辑); 真正的变化是**旁观族名次洗牌** —— `u_hls/*` 内部的 setup 依旧**不在最差 400**
(即改 HLS 没有把它的内部路径推上来), WNS/WHS 的小幅移动来自布局布线方差与族间名次互换。

### 板级 (2026-09-20, post-D6 位流)

- **同四元组重连 (D6 判别性变体 `--gap 0.6`)**: post-D6 **15-23ms** 建连 (0.023/0.021/0.020s);
  pre-D6 同脚本 **~1.0s** (轮 2/3 各 1.029s/1.012s) ⇒ 修复有效且**可判别**。
  (`--gap 4.0` 两版都过 —— 轮间隔晚于自释放, 见教训 ②)
- **4MB 回归**: `RX` 逐字节精确、`MM=0` ⇒ 分池/动态裕度/opener 没有破坏单连接数据面。
- **板级多连接不可行 (记录)**: `app_pattern` 是**单连接**演示 app、板级寄存器总线**无 CPU** ⇒
  分池门槛 (app 建连前写 `0x0C`) 只能在 TB 侧设; 板级只验**单连接不回归**。

## 2026-09-20 P5e-T1/T2 UDP app 接口施工 (接收侧分流 shim + 发送侧目标锁存/长度守卫) — 设计决定 + 决定性实验

**范围 (整个 P5e 的构建面)**: 新增 `rtl/udp_split.v` (T1 接收侧分流) + `rtl/udp_tx_cfg.v`
(T2 发送侧目标锁存/使能门) + `rtl/udp_tx_frame.v` 长度守卫 (T2) + wrapper 的 UDP 支
(`` `ifdef APP_MODE ``); **`rtl/udp_rx.v` 与 `rtl/udp_tx_frame.v` 本轮首次进 p5 构建清单**
(`board/build_p5.tcl` / `board/timing_p5.tcl` 此前只有 `app_*.v` 与 `tx_arb.v`) —— 两者都是
P1 就存在且已过 P1 门的模块, 本轮只是把 APP_MODE 构建纳入它们。默认构建 (`build_p4.tcl`,
宏未定义) **逐位不变** (新逻辑全在 `` `ifdef APP_MODE `` 内, 新增线束在默认路径上是纯线名
别名, 同 P5a 的 `txin_*`/`srx_*` 手法)。T3 的 `rtl/app_udp_pattern.v` + learn-on-RX 闭合见下一节。

### ① 为什么**不动** `rx_classify` (插在它的 **slow 输出**与 `slow_rx_adp` 之间)

- `rx_classify` 把所有 UDP 都送 slow 口 —— 这是 **P4 门的逐字断言**; 改它要同时改 5 个活例化点
  (wrapper + `tb_p4_chain` / `tb_p5_app` / `tb_p5_adv` / `tb_p5_multi`) 外加单元 TB
  `tb_rx_classify`, 且它的 FSM 族在 P5d 是 **0.598ns** 的临界族 (动它 = 拿时序赌一个不需要的功能)。
- ⇒ **在 slow 支插入** `udp_split` ⇒ **TCP 数据面永不经过本模块** (fast 帧根本不进 slow 口),
  TCP 侧零功能风险 / 零时序影响。这是"附加功能不碰已验收路径"原则的直接落地。

### ② ⚠️ 真正的风险是**背压**, 不是分类 (决定性实验 `sim/p5e_pre`)

- 初版的担心是"分类判错 ⇒ 帧走错路"。决定性实验 (基线 vs 接入分流器的逐场景对比, 见
  `sim/p5e_pre/` 的 `tb_p5_baseline.v` / `tb_p5_udp_split.v` + `gen_stim_p5e_udp.py`) 把真风险
  暴露成另一条: **慢口消费者一停 ⇒ 反压经 `rx_classify` 传到 `mac_rx_64` 的 8 字共享 FIFO**
  (`rtl/mac_rx_64.v:227`) ⇒ **丢帧, 且受害者可以是 fast TCP 帧**: 实测 **`mac_drop=11`**,
  13 帧丢 7。(旧 `slow_rx_adp` 是 `assign s_axis_tready = 1'b1` —— 故意永不反压, 就是因为这条。)
- ⇒ `udp_split` 的输入口**结构性不反压**: `s_axis_tready` 只在"预取 FIFO 满"时为 0, 而这要求
  `udp_rx` **连续停读 ≥13 拍**; 而 `udp_rx` 唯一的停读是 S_TAIL 的 **≤2 拍** ⇒ **结构性不可能**
  ⇒ 对外可断言**恒 1** (T1 门与 T4 门都有专项断言, 实测全程恒 1)。装不下时**丢整帧**(绝不吐半帧)。
- **预取 FIFO 的第二个作用 (易忽略)**: 两支 (透传支 / 分流判据) 看到的是**逐位同源**的字流
  (同一个 pop 流), 且本模块的帧内字计数 `pw_cnt` 与 `udp_rx` 内部 `wcnt` **严格同拍** ⇒ 判定拍不会错位。

### ③ 帧级缓冲 (store-and-forward) 如何消解 `udp_rx` 的两条已知弱点

| `udp_rx` 的弱点 | `udp_split` 的做法 | 结果 |
|---|---|---|
| **坏 FCS 照交** (`crc_ok` 只在 TLAST 拍有效) | TLAST 拍查 `tuser[0]`, 坏则**整帧回卷** (不提交/不交付) | `stat_drop_crc`, 零坏帧进 app |
| **长度不符 ⇒ 无 TLAST 半帧**(且无 `fend/ferr` 告警) | 用**下一帧的 `meta_valid` 拍**作未决帧边界: 未提交残帧一律回卷作废 | `stat_drop_part`, **永不半帧** |

- **代价 (写清, 是有意的取舍)**: "**匹配但畸形**"的帧 (匹配 app 端口但长度字段坏) 会**从两条路
  都消失** —— 它既没进 app (被回卷), 也没进 HLS (判定拍已把它从透传支撤走)。app 通路的合同是
  "要么完整正确, 要么零交付"。
- **0 长数据报 (合法)** 也照顾到: 播放器合成 1 拍 `tkeep=0/tlast=1` 的 null beat ⇒ app 口硬不变量
  "一帧 ≥1 拍, 末拍 tlast, 永不半帧/重复/乱序"。

### ④ `udp_tx_cfg`: 下游 `udp_tx_frame` 的 cfg 是**双时刻采样** ⇒ 锁存必须冻结到**帧头发出之后**

- 采样点 ① **帧首接受拍** (`csum_init_val` 进 `checksum16.init`) ② **S_HDR 拍 + TLAST 拍**
  (帧头字节 + `ip_csum_calc`)。⇒ 任何"帧中途/帧尾后"的 cfg 变化会让**同一帧的头与校验和取自
  两个对端** (实测症状: 头 = 新 peer, csum = 旧 peer)。
- ⇒ `udp_tx_frame` 新增 **`o_busy`** (1 = 非空闲) 回授给 `udp_tx_cfg` 作冻结窗口右边界;
  另加**启动同步门** (刷新未落地不许帧首拍进下游, 否则复位后首帧 csum 少 `src_ip+dst_ip`,
  换 peer 后首帧差两个 IP 之差)。**两轮才做对** —— 第一版只冻结到"最后一拍被接受"为止, 仍在
  报文传输期间放走了 cfg 变化。
- 表项来源 = **learn-on-RX** 的 peer 表 (T3 闭合); **端口是配置而不是学习** (对端的临时端口
  不是 UDP 语义)。不选 tid 索引的理由 (UDP 不合流到 TCP 的 AXIS ⇒ tid 需自定义; 单对端会话下
  表+索引 = 纯开销; 且 tid 方案是 learn 方案的超集而非替代) 见 `rtl/udp_tx_cfg.v` 头注释。

### ⑤ `udp_tx_frame`: 长度守卫 (app 契约兜底, 两个**硬**理由)

- 帧内累计 `plen_n > PLEN_MAX(=1500)` ⇒ **整帧中止** (不写 FIFO / 不发帧 / 不进校验和), 残留字
  在 `S_RECV` 冲洗 (`flush_rd`), `stat_drop_len` 计数。理由:
  ① **`>2048B` 会永久死锁** —— 内部载荷 FIFO 只有 256 字, 载满后 `s_axis_tready` 恒 0 而 FSM 停在
     `S_RECV` 等 `tlast` ⇒ **该帧永不收尾也永不放行**;
  ② **`>1518B` 会上线巨帧** (`mac_tx_64` 不做长度截断), 对端/交换机丢弃或报警。
  上界必须 < FIFO 容量: 超限检出拍最多已写 189 字 ⇒ 结构性无死锁路径。
- 接受门 `s_axis_tready` 加 `!flush_pend` (**接受门与"能否启动一帧"同门**, 工程坑 10): 否则新帧
  首字会与待冲洗的残字混在同一 FIFO, 排空指针吃掉新帧首字 ⇒ **帧长错 8 字节**。
- 不加 FSM 状态 (同 `tcp_tx_frame` 手法: `len_bad`/`flush_pend` 两个 flag) ⇒ 默认构建与 P1 echo
  路径的帧恒 ≤1500B ⇒ 两位恒 0, 逐位不变 (P1 门 `run_tb_udp_tx.bat` 的 LENS 含 1500 用例, PASS)。

### ⑥ TX 优先级 (wrapper 的两级 arb)

**TCP fast (严格优先) > UDP app TX > HLS 慢路径**。两个 arb 都是"帧级锁定 + 帧末 1 拍重仲裁"
⇒ 帧原子性不被切断; UDP 帧 ≤1500B、HLS 帧 ≤1518B ⇒ 单帧有界, 互不无界阻塞。给 UDP 压 HLS 的
理由: HLS 慢路径自带 `frame_fifo` (512 字, store-and-forward), 被让路**不丢字** ⇒ 优先级给低延迟者。

### ⑦ 零回归论证 (默认不激活, 两条**独立**保险)

- T1 的 `cfg_*` 全 0 哨兵 (不匹配任何帧 ⇒ 分流器对慢路径透明) + T2 的 `peer_v` 复位 0
  (表空 ⇒ `o_ready=0` ⇒ app 侧推出的帧被**拒在 `udp_tx_frame` 之前**, 线上零新增帧)。
  ⇒ **app 侧默认不激活, 板上行为与 P5 逐位一致**; 两门里两条保险各自被单独验证过。

### ⑧ 门 (T1/T2)

- **T1 单元门** `sim/p5udp/run_tb_udp_split.bat` (`tb/tb_udp_split.v`): 分流正确性 / 结构性不反压
  (`s_axis_tready` 恒 1) / 透传逐字保真 / 坏帧与半帧整帧丢弃 / 帧缓冲溢出整帧丢。**PASS**。
  决定性实验的两个 TB 副本在 `sim/p5e_pre/` (`tb_p5_baseline.v` / `tb_p5_udp_split.v`)。
- **T2 双门**: `sim/p5e_t2/run_tb_udp_tx_guard.bat` (peer 门 + `PLEN_MAX` 守卫 + 内置负对照;
  实测 `P5E-T2 GUARD GATE: OK (frames=6 drop_len=2 deny=2 neg_stuck=0)`) 与
  `sim/p5e_t2/run_tb_p5e_t2_wrapper.bat` (真 wrapper 全链)。
- ⚠️ **坑 8 再次实锤 (本项实测踩到)**: 漏声明一根 64/8 位内部线 ⇒ Verilog **隐式 1 位线** ⇒
  连接**静默截断**, 高位 = Z ⇒ `mac_tx` 收到 Z 填充字 ⇒ `cw_len = popc8(Z) = X` ⇒ **永久卡
  `S_DATA`**, TX 全线死。**子模块 TB 全绿, xelab 只有 unconnected 类警告** ("implicitly declared"
  **不在**多驱动/未驱动检查里) ⇒ **只有真 wrapper 全链门能抓到**。⇒ 门里应用
  **隐式网当硬失败** (T3/T5 的门已加)。
  ⚠️ **2026-09-29 订正 (P7B 实测)**: Vivado 2025.2 **不再打印 `implicitly declared`** (实测全部日志命中 0) ⇒ 旧关键字是**哑门**。Vivado 2025.2 的真实签名分两种形态、**两个不同检测点**: ① 端口连接形式 (静默截断) —— **xvlog 一个字都不打印** (exit 0、日志全空, `-sv` 也一样), 只有 `xelab` 报 `WARNING: [VRFC 10-3091] actual bit length 1 differs from formal bit length 64 for port 'q'`, 或 `synth_design` 报 `INFO: [Synth 8-11241] undeclared symbol 'mid', assumed default net type 'wire'`; ② 表达式形式 —— `xvlog` 报 `ERROR: [VRFC 10-2989] '<name>' is not declared` (synth 用 `8-36`)。⇒ **只 grep xvlog 日志的门结构性地拓不到本坑 —— 换任何关键字都不行, 必须补 `xelab`/`synth_design` 这一面** (现役两处 lint 入口 `board/run_lint_p6e.bat` / `_proj_10g/tcl/run_lint_p7a.bat` 已补, 各 +12 s / +24 s)。 **推荐键表 (5 键, OR 语义)**: `Synth 8-11241` · `undeclared symbol` · `VRFC 10-3091] actual bit length 1 differs from formal bit length` · `VRFC 10-2989` · `implicitly declared` (末者只为 2025.2 之前的工具保留, 在 2025.2 下恒 0)。 ⚠️ **`10-3091` 必须带上 `] actual bit length 1 differs from formal bit length`**: 裸 `VRFC 10-3091` 会命中 `board/util_gmii_to_rgmii.v` 的 **14 处良性 unsized 字面量** (`.CE(1)`/`.D1(1)`/`.D2(0)`/`.R(0)`/`.S(0)`, 报 `actual bit length 32 differs from formal bit length 1`) —— 默认 (K7) 配置每次 xelab 都报, 当硬失败就是天天误伤。隐式网**必然是 1 位** ⇒ "actual = 1" 就是本坑的精确签名 (收窄后仍抓住病理件 A1)。 **刻意排除的键 (都有实测假阳性)**: `8-7129`/`unconnected or has no load` (命中干净件的**合法未用端口**)、`8-6014`/`8-3917` (纯优化提示)、`VRFC 10-3645`/`remains unconnected` (xelab 侧对偶 —— 干净的真实 P6e 设计一跑就 **20 条**)。 ⚠️ **裸 `findstr /C:"10-3091"` 那一族"位宽不符"判定结构性常哑**: 语料实测 `10-3091` 在 **869 份 xvlog 日志中 0 命中**、452 份 xelab 日志中 173 份命中 ⇒ **凡 grep `xvlog_*.log` 的裸 `10-3091` 判定永远不会触发**。 ⚠️ **历史事实**: `IMPLICIT-DECL-FAIL` / `BITWIDTH-MISMATCH-FAIL` 在**全仓留存日志里 0 命中** ⇒ 无任何证据表明这两条门**曾经**响过 (严格措辞: "没有留存日志含这些标记" ≠ "从未失败")。 规范检测器 = `sim/p4gates/implicit_gate.bat` (+ `implicit_gate_selftest.bat` 九项对照)；取证 = `_proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md` (修复) + `_proj_10g/notes/P7B_IMPLICIT_GATE_ROLLOUT.md` (铺开 + 语料级假阳性验证)。
- 本轮新增坑已补进 `CLAUDE.md` **24-26**: 隐式 1 位线 (本条) / **"这东西从哪来"要单独测**
  (T2 两门都靠 `force` 灌 peer ⇒ 缺口从两条门逃逸, 只有 `neglearn` 负对照能暴露) /
  **近似时序门绝对值不可跨流程比较** (手动 opt/place/route 不 `launch_runs` ⇒ 缺 `phys_opt`
  且 strategy 不生效, 比官方口径悲观 ~0.17ns)。

## 2026-09-20 P5e-T3/T4/T5 UDP 演示 app + learn-on-RX 缺口闭合 (真 wrapper 全链) — 门全绿 + 时序收口

**范围**: TL 重新裁决的**设计缺口** + UDP 演示 app + 门。T1 (`udp_split` 接收侧分流) 与
T2 (`udp_tx_cfg` + `udp_tx_frame` 发送侧) 的产物**性质不动**, 只加/换接线与新增模块。

### ① 缺口闭合: `udp_split` 的 meta 输出口 (learn-on-RX)

**缺口 (T2 描述与板级事实不符)**: T2 把 `udp_tx_cfg.peer_wr` 接在**慢路径 CONN_UP**
(`scfg_ev_up`) 上。**UDP 无连接 ⇒ 板上永不产生 CONN_UP ⇒ peer 表永远空 ⇒ UDP TX 永不激活**
—— T2 的"默认不发送"在板级退化成"**永不发送**"。T2 的单元门与 wrapper 门都是 `force` 灌
peer 事件才绿的, 所以**门抓不到**这个语义缺口 (两门都测"注入 peer 后会发", 没测"peer 从哪来")。

**闭合** (`rtl/udp_split.v` 新增 5 个输出口, 纯线束):

| 口 | 来源 | 语义 |
|---|---|---|
| `meta_valid` | `u_udp_rx.meta_valid` | 匹配帧 w5 接受拍的**单拍组合脉冲** |
| `meta_src_mac/ip/port` | `u_udp_rx.meta_*` | 该帧解析出的对端 MAC/IP/端口 (w3/w4 拍已寄存, 脉冲拍稳定) |
| `meta_len` | `u_udp_rx.meta_len` | 该帧载荷字节数 |

body 里就是 5 条 `assign` —— **零新增逻辑/零新增寄存器/零新增状态**, 不改
`s_axis_tready` / `p_axis_*` / 帧缓冲的任何门控 ⇒ T1 的三条已验证性质 (结构性不反压 /
透传逐字保真 / 坏帧与半帧整帧丢弃) **结构性不变** (T1 的 `sim/p5udp/run_tb_udp_split.bat`
在改后仍 PASS, 见下)。**为什么安全**: 纯输出口 + 命名端口例化 ⇒ T1/T2 的既有例化点
(tb_udp_split / sim/p5e_pre 的副本) 不接新口只是 unconnected 警告, 行为逐位不变。

wrapper 侧: `.peer_wr(udp_meta_valid) / .peer_mac(udp_meta_src_mac) / .peer_ip(udp_meta_src_ip)`,
并同时把 `udp_split` 的过滤配置从 T1 的"全哨兵 (对慢路径透明)"改成**精确匹配 app 端口**:
`cfg_dst_ip = 192.168.100.2` (本板) / `cfg_port0 = 8081` / `cfg_port_any = 0`
(8080 由 `EXCL_PORT` 排除, 仍留给 HLS `udp_echo`)。

**⚠️ 已文档化的语义边界**: `meta_valid` 在 w5 (头字段收全) 就脉冲, 而 **FCS 要到 TLAST 拍
才知道** ⇒ **坏 FCS 帧的头字段同样会被学入 peer 表** (该帧随后被整帧丢弃, `stat_drop_crc`);
下一好帧即覆盖。要改成"仅好帧才学"必须把 meta 缓存到 TLAST = **新增状态**, 明确不在本口
合同内。本语义由 `tb_app_udp` 的 `badcrc` 模式**逐条断言钉死** (改语义必须同时改断言)。

### ② 演示 app `rtl/app_udp_pattern.v` (UDP 版图案发生器 + 校验器)

- **图案约定与 `app_pattern.v` / `peer.exe --udp-*` 逐字节一致**: xorshift64
  (`s ^= s<<13; s ^= s>>7; s ^= s<<17`), 每步取 `s[31:24]`, 种子 `0x9E3779B97F4A7C15`,
  **先取后推进**。独立模块 (不是复用 `app_pattern`) 的理由: UDP **无连接语义** —— 没有
  CONN_UP/DOWN 事件、没有 tid、没有 FIN/RST 收尾, 硬塞进 TCP app 的事件驱动 FSM 会引入
  一堆板上恒假的分支。
- **消费速率: 字节串行 + II=1 无缝 (选它, 不选 8 路并行)** —— 论证三条:
  ① **需求侧**: 本构建是 1G MAC ⇒ 线上字节率结构性 <= 125 MB/s, 而本 verifier 有数据时
     恰好 **125 MB/s** (1 字节/拍, 8 字节恰 8 拍); 更深一层, 以太网每帧还有 42+4+20 = 66
     字节开销 ⇒ **载荷**率只有线速的 1472/1538 = 95.7% ⇒ 净余量 ~4.5%, 且 `udp_split` 的
     4KB 帧缓冲吸收帧间缝隙。板级验收用 `peer --rate-mbps 20` (= 2.5 MB/s) ⇒ 裕度 **50x**。
     ⚠️ **顺手纠正 T1/T2 与 `tools/cpp_peer/peer.cpp` 的一处 8x 口径错误**: 注释里写的
     "app RX 消费是字节串行 (~15.6 MB/s @125MHz)" **是错的** —— 1 字节/拍 @125MHz =
     **125 MB/s = 1 Gbps 线速**; 15.6 MB/s 是 125 **Mbps** 的字节数。真实结论因此相反:
     T1/T2 的字节串行 RX **不是**"跟不上所以才必须限速", 而是**恰好等于 1G 线速**。
     (peer.cpp 的默认 `--rate-mbps 50` 的"2.5x 裕量"实际上是 ~20x。)
  ② **关键改进**: `app_pattern` 的 RX 是"1 拍装字 + n 拍比字节" ⇒ 8 字节 9 拍 = 111 MB/s
     (89% 线速, **无限速灌包时结构性跟不上**); 本模块把**装载与比对并行** (1 字前瞻寄存器,
     比对期间把下一字收进 `nx_*`) ⇒ 8 字节恰 8 拍, **无空拍**。`rx_tready = !nx_v`
     是真反压 (每字 8 拍), 但上游是帧级 store-and-forward + 4KB 缓冲 ⇒ 反压停在缓冲里,
     永不到 `mac_rx` (T1 的"绝不反压"合同不破)。
  ③ **上限写清**: 本 verifier 天花板 = **1G 线速**。10G 必须换 8 路并行 (8 步 xorshift/拍
     = 1 GB/s); 本次不做是因为 (a) 1G 用不到, (b) 8 步 xorshift64 组合链 = 24 级 64 位 XOR
     (~3-7ns), 而 T2 布线后 **WNS 只剩 +0.230ns @8ns 周期** ⇒ 加进去大概率直接破时序。
     真要做需要"两级流水 + 4 lane" (500 MB/s 仍不够 10G 的 1.25 GB/s) 或线性代数化
     (`s_8 = M^8 * s_0` 矩阵异或树, 深度 ~6 级 LUT)。
- **TX 限速**: 帧间 `TX_GAP` 个空闲拍 (参数)。默认 58000 ⇒ 帧周期 1538+58000 ~= 59538 拍
  @125MHz ⇒ **1472*8/476us ~= 24.7 Mbps payload (~=25.4 Mbps 线上)**。选它的理由:
  T6 板级实测 (peer.cpp:2529 记录) —— 参考对端在 20/25 Mbps 全收, >=30 Mbps 丢 ~2/3 帧。
  `TX_GAP=0` = 全速 (受 mac_tx 线速限制, 约 957 Mbps)。
- **`TX_BYTES != 0` = 有界会话** (发完 `done` 粘滞): 末帧长 = `min(i_paylen, 剩余)` ⇒
  逐字节精确。⚠️ 实现里必须用 `rem_eff = first_frm ? TX_BYTES : remain` —— remain 是寄存器,
  而"首帧启动拍"与 `remain <= TX_BYTES` 是**同一边沿**, 直接读 remain 会拿到复位值 0
  ⇒ 首帧变成 0 长数据报 (坑 6 同族: 新状态第一次用的采样时刻)。门里有专项断言
  (`TX_BYTES=1000` ⇒ bytes=1000 / frames=1 / beats=125 / done=1 / 之后零拍)。
- **超长帧冻结 LFSR**: `seg_len > PLEN_MAX` 的帧必被 `udp_tx_frame` 帧内中止 (零字节上线);
  若 LFSR 照常推进, 线上图案流就留一个空洞 ⇒ 对端连续校验必然失配。对齐 `app_pattern.bad_frm`
  的手法 (冻结 + 常数填充) ⇒ **线上图案流始终连续**。板级 `i_paylen` 恒 1472 ⇒ 该路径不可达。
- **默认不激活**: `i_en=0` (未使能 ⇒ 不校验、LFSR 钉 SEED) 或 `i_tx_ready = udp_tx_cfg.o_ready
  = peer_v = 0` (peer 表空 ⇒ TX 零帧)。板级在**收到对端任一 app-UDP 帧**后才开始回发图案 ——
  这本身就是演示: 主机发一个数据报, 板子自动开始回图案流。

### ③ 门 (新目录 `sim/p5e_udp/`, 与 T1 的 `sim/p5udp/` 不撞)

**T4 单元门** `tb/tb_app_udp.v` (自检式, 无 Python) —— 链 = TB 帧流 -> `udp_split`
-> ①`p_axis`->`slow_rx_adp`(HLS) ②`app_rx`->app; `meta_*`->`udp_tx_cfg.peer_wr`;
app TX -> `udp_tx_cfg` -> `udp_tx_frame` -> `tx_arb` -> 捕获。

| 模式 | 判据 | 实测 |
|---|---|---|
| `pos` (默认) | P① RX 载荷逐字节+meta ② TX 帧逐字节 (双校验和/长度/载荷) ③ 边界 0/1472/1500/1501 ④ 突发 8x1472 零间隙 ⑤ learn-on-RX (+换 peer B) ⑥ `TX_BYTES=1000` 有界会话 | EXIT=0; RX 3 帧/2944B/**零失配**; meta 3 脉冲; 突发: 交付 3 + 溢出丢 5 == 8, `drop_part=0`, **`s_axis_tready` 全程恒 1**; 1501 ⇒ 零帧上线 + `drop_len=1` 且后续帧照常; 全部 18 帧 TX 载荷 = 图案流**连续**前缀 (`pat_bad=0`) |
| `splitoff` | 拆分器 cfg 全哨兵 ⇒ app **0 帧** + HLS `stat_commit=2` (UDP 逐字走慢路径) | EXIT=0 |
| `portout` | dport=9090 (过滤外) ⇒ app 0 帧 + HLS 见 echo | EXIT=0 |
| `badcrc` | 匹配帧坏 FCS ⇒ app **0 帧** + `drop_crc=1` + `drop_part=0` + 不进 HLS; **并断言文档化的边界** (头字段仍被学入 peer 表) | EXIT=0 |
| `nopeer` | 一个 RX 帧都不注入 ⇒ peer 表空 ⇒ TX **零帧** | EXIT=0 |
| `neglearn` | **P5d 风格负对照**: peer 学习源钉 0 (复现 T2 配置) ⇒ 正例判据必然不成立 | **EXIT=1 (期望)**; 104 条 FAIL 全部落在 P⑤/③ (P① RX 仍全绿) ⇒ 判别力实证 |

**T5 真 wrapper 全链门** `tb/tb_p5e_udp_wrapper.v` (坑 8) —— 例化 `board/wrapper_p4.v`
(`-d APP_MODE`), 用 `force` 往 wrapper 内部 **GMII RX 侧** (`u_dut.e_rxd/e_rxdv/e_rxer`)
注入 1 帧 (前导 8B + MAC 1514B + 自算 FCS), 于是**真走完** `mac_rx_64 -> rx_classify ->
u_udp_split -> app RX + meta_* -> u_udp_tx_cfg (learn-on-RX) -> u_udp_tx -> u_tx_udp_arb ->
u_tx_arb -> mac_tx_64 -> 内部 GMII TX`, 并在 GMII 上逐字节解码回帧。未覆盖的只有 RGMII
DDR 转换器本身 (未改动)。判据: ① 注入前 `app_udp_tx_ready=0` 且零 UDP 帧 ② app RX
`stat_rx_frames=1`/1472B/**`stat_mismatch=0`** ③ `peer_v=1` 且 `peer_mac_r/peer_ip_r` =
注入帧 src ④ GMII UDP 帧 MAC 长 1514 / dst=peer / src=板 MAC / IP+UDP 校验和正确 / 载荷逐字节
⑤ TCP fast 帧照常 + `mac_tx.stat_abort=0`。**结果: `P5E-T5 UDP WRAPPER GATE: OK`**;
`+NOUDP` 对照 (不注入) ⇒ `peer_v=0 ready=0 udp_tx_fr=0 gufr=0 mac_tx_state=2 abort=0` = **零 UDP 帧**。

**DRC 级静态检查** (xvlog + xelab, **两个 ifdef 配置都查**): 隐式网 (T2 建议加 ——
漏声明 ⇒ 隐式 1 位线 ⇒ 静默截断, `multi/driv/unconnected` 都抓不到) / `multi` / `driv` /
`unconnected` 各 grep 一次; 结果 **implicit 命中 0 x 4 个日志**, 未连接清单与 T2 期逐项相同
(全是既有 `dbg_wptr`/`crc_nxt` 类), **无新增**。
  ⚠️ **2026-09-29 订正 (P7B 实测)**: Vivado 2025.2 **不再打印 `implicitly declared`** (实测全部日志命中 0) ⇒ 旧关键字是**哑门**。Vivado 2025.2 的真实签名分两种形态、**两个不同检测点**: ① 端口连接形式 (静默截断) —— **xvlog 一个字都不打印** (exit 0、日志全空, `-sv` 也一样), 只有 `xelab` 报 `WARNING: [VRFC 10-3091] actual bit length 1 differs from formal bit length 64 for port 'q'`, 或 `synth_design` 报 `INFO: [Synth 8-11241] undeclared symbol 'mid', assumed default net type 'wire'`; ② 表达式形式 —— `xvlog` 报 `ERROR: [VRFC 10-2989] '<name>' is not declared` (synth 用 `8-36`)。⇒ **只 grep xvlog 日志的门结构性地拓不到本坑 —— 换任何关键字都不行, 必须补 `xelab`/`synth_design` 这一面** (现役两处 lint 入口 `board/run_lint_p6e.bat` / `_proj_10g/tcl/run_lint_p7a.bat` 已补, 各 +12 s / +24 s)。 **推荐键表 (5 键, OR 语义)**: `Synth 8-11241` · `undeclared symbol` · `VRFC 10-3091] actual bit length 1 differs from formal bit length` · `VRFC 10-2989` · `implicitly declared` (末者只为 2025.2 之前的工具保留, 在 2025.2 下恒 0)。 ⚠️ **`10-3091` 必须带上 `] actual bit length 1 differs from formal bit length`**: 裸 `VRFC 10-3091` 会命中 `board/util_gmii_to_rgmii.v` 的 **14 处良性 unsized 字面量** (`.CE(1)`/`.D1(1)`/`.D2(0)`/`.R(0)`/`.S(0)`, 报 `actual bit length 32 differs from formal bit length 1`) —— 默认 (K7) 配置每次 xelab 都报, 当硬失败就是天天误伤。隐式网**必然是 1 位** ⇒ "actual = 1" 就是本坑的精确签名 (收窄后仍抓住病理件 A1)。 **刻意排除的键 (都有实测假阳性)**: `8-7129`/`unconnected or has no load` (命中干净件的**合法未用端口**)、`8-6014`/`8-3917` (纯优化提示)、`VRFC 10-3645`/`remains unconnected` (xelab 侧对偶 —— 干净的真实 P6e 设计一跑就 **20 条**)。 ⚠️ **裸 `findstr /C:"10-3091"` 那一族"位宽不符"判定结构性常哑**: 语料实测 `10-3091` 在 **869 份 xvlog 日志中 0 命中**、452 份 xelab 日志中 173 份命中 ⇒ **凡 grep `xvlog_*.log` 的裸 `10-3091` 判定永远不会触发**。 ⚠️ **历史事实**: `IMPLICIT-DECL-FAIL` / `BITWIDTH-MISMATCH-FAIL` 在**全仓留存日志里 0 命中** ⇒ 无任何证据表明这两条门**曾经**响过 (严格措辞: "没有留存日志含这些标记" ≠ "从未失败")。 规范检测器 = `sim/p4gates/implicit_gate.bat` (+ `implicit_gate_selftest.bat` 九项对照)；取证 = `_proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md` (修复) + `_proj_10g/notes/P7B_IMPLICIT_GATE_ROLLOUT.md` (铺开 + 语料级假阳性验证)。

**清单镜像 (坑 12)**: `%RTL%\app_udp_pattern.v` 补进了 **13 个**会因缺模块而假失败的清单
(`board/build_p5.tcl` / `board/timing_p5.tcl` / `sim/p5sim/run_tb_p5_wrapper.bat` /
`sim/p5e_t2/{run_tb_p5e_t2_wrapper.bat,route_check.tcl}` / `sim/p5udp/route_check.tcl` /
`sim/p5b_acc|p5b_ind2|p5c_t3/rev|p5c_t4reg|p5c_t5|p5c_t5/g_p5|p5d_multi/p5dpriv/p5sim` 的
`run_*_wrapper*.bat` / `sim/p5d_multi/chk/chkwrap.bat`), 由 `sim/p5e_udp/patch_manifests.py`
一次做完 (只动清单行, 不动门逻辑)。

**T2 的门随缺口闭合做了最小激励修正** (`tb/tb_p5e_t2_wrapper.v`): 旧的 `force scfg_ev_*`
不再产生学习 ⇒ 改成 `force` wrapper 的 `udp_meta_valid/meta_src_mac/meta_src_ip` 一拍
(仍覆盖 wrapper 里 `meta -> peer_wr` 的**接线本身**, 只跳过 `udp_split` 生成 meta 的那段 ——
那段由 T5 用真 GMII 注入覆盖)。**T2 的判据 ①②③ 一字未改, 改后 PASS**
(`gnfr=3 udp=1 tcp=2`)。T1 的 `run_tb_udp_split.bat` 未改任何东西, 改后仍 PASS。

### ④ 时序门 (T1/T2 都点名要重跑的项: app 侧锥是否被覆盖)

T1/T2 的遗留问题: **app 侧无消费者时锥会被综合裁剪 ⇒ 时序报告不覆盖输入侧关键路径**。
接上真 app (u_app_udp, 且它的 `m_*` 驱动 `udp_tx_cfg`、`rx_tready` 驱动 `udp_split`,
结构性不可裁) 后重跑:

| 门 | 结果 |
|---|---|
| `board/run_timing_p5.bat` (synth+opt+place) | Setup **WNS +0.475 / 0 失败端点**; Hold WHS -0.158 / 604 端点 (place-only 的已知悲观, 基线 718); **place 报告的最差 setup 路径 = `u_app_udp/pw_keep_reg[4]` -> `u_udp_tx/ip_csum_r_reg[13]`** |
| 私有 route 门 (`sim/p5e_udp/route_check.tcl`, p5r3_prj, +route_design) | **WNS +0.123 / WHS +0.036 / 失败端点 0 / 0** (133674 端点), "All user specified timing constraints are met"; 最差 setup 路径族 = `u_tcp_tx/u_retx` BRAM 地址, 而 **`u_app_udp -> u_udp_tx` 位列第 7 (+0.285ns)** |
| cell 数探针 | `u_udp_split=1927 / u_udp_tx=1890 / u_udp_tx_cfg=336 / u_app_udp=1128 / u_tx_udp_arb=8` ⇒ **app 侧锥确实被综合进去了** |

**结论 (明确)**: **app 侧锥这次真的被覆盖了** —— 它既出现在 place 的**第一**最差路径, 又在
route 报告的前 10 名里, 且有 1128 个 cell 实证没被裁。代价: 相对 T2 基线
(+0.230/+0.036) WNS **-107ps**, WHS 不变, 仍是 0 失败端点 (全部约束 MET)。

### ⑤ 本轮新增坑 (已补进 CLAUDE.md 21-23)

1. **TB 注入以太网帧的两处字节序/拍对齐错, 症状都指向错误的模块**:
   IP 校验和是**网络序 (大端)** 16 位字段 —— 写成小端 ⇒ `udp_rx` 判 nonmatch, 看着像
   "拆分器过滤不匹配"; 往 GMII 注入时**帧尾多挂 1 拍 `dv=1`** ⇒ 多算 1 字节 ⇒ FCS 残差错
   (`mac_rx.stat_crc_err=1`, 看着像"FCS 算错")。**两步定位**: 先 CRC 自检
   (`crc32("123456789")==0xCBF43926`), 再看 `mac_rx.stat_bytes` 是否**恰等于**帧长
   (实测 1519 vs 1518 = 拍对齐问题)。
2. **force 的层次名必须与 wrapper 线名逐字一致** (`udp_meta_smac` vs 实际
   `udp_meta_src_mac` ⇒ xelab "not declared under prefix"); TB 的整型声明若在引用它的 task
   之后 ⇒ 编译错 (与 RTL 同一条"先声明后用")。
3. **被下游中止的帧必须冻结图案 LFSR** (否则线上图案流留空洞 ⇒ 对端连续校验失配)。

### ⑥ 回归 (本轮全部重跑; 驱动 `sim/p5e_udp/run_regress.sh`, 日志 `sim/p5e_udp/regress_t3.log`)

**49 门: 唯一非零退出码 = `t4_neglearn EXIT=1` (P5d 风格负对照的**期望值**), 其余 48 门全 0。**

- **P1 三门** (echo / udp_rx / udp_tx): EXIT=0 x3
- **P4 矩阵 16 门** (`sim/p4sim/run_matrix_p4dfix.sh`): EXIT=0 x16, 无一失败
- **P5 全套 24 门**: app / close / wrapper / status / adv x11 (len b2b wnd fin findrop abort
  evfifo reconn_fast reconn_slow multi accmgn) / flow / fc / p5close / p5c_t3 / p5d_d1 /
  fence_neg / multi main + known_idle_fifo — 全 EXIT=0
- **P5e 新增**: T1 splitter 门 (未改动, 仍 PASS) + T2 双门 (判定未改, 激励对齐后 PASS) +
  T4 x6 模式 + T5 wrapper 门 (含 +NOUDP 对照)
- **负对照 5 条** (P5d 风格): `t4_splitoff` / `t4_portout` / `t4_badcrc` / `t4_nopeer` 四条
  **期望 exit 0 且正向判据不成立**; `t4_neglearn` 为**期望 FAIL (exit 1)** 的判别力实证
  (104 条 FAIL 全落在 P⑤/③, P① RX 仍全绿)。

### ⑦ 官方构建门 (p5_prj, routed) — WNS +0.290 / WHS +0.051 / 0 失败端点

| 项 | 值 |
|---|---|
| 时序 (routed, 133723 端点) | **WNS +0.290 / TNS 0.000 / WHS +0.051 / THS 0.000 / 0 失败端点**; "All user specified timing constraints are met" (WPWS +0.264 / TPWS 0) |
| 面积 | LUT **51588** (25.31%) / FF **41513** (10.18%) / BRAM **312** (70.11%) / DSP 4 / IOB 19 |
| DRC (routed) | **0 error** — 89 项全为 Warning/Advisory (REQP-1839/1840 RAMB 异步控制、DPOR-1 异步加载、DPIP/DPOP 流水等既有族); 静态侧 `implicit` 命中 **0** (4 个 xelab/xvlog 日志 grep) |
| route | **78014/78014 全布通**, routing errors **0**; 报告落 `p5e_verify/` (`verify_p5e.tcl`) |

**app 侧锥确实上榜 (T1/T2 点名要复核的那一项)**: `report_timing_summary -max_paths 20` 里 **9/20**
条落在 `u_app_udp/pw_keep_reg[5] → u_udp_tx/ip_csum_r_reg[*]` (**#3/4/5/8/9/10/11/12/13**, 最差
**+0.297**); 布线后 worst-400 setup 只有**两个族**: `u_tcp_tx FSM → u_tcb.rcv_nxt_r` (256 条, 0.290)
与 **app 侧锥 (144 条, 0.297)**。cell 探针 `u_udp_split=1927 / u_udp_tx=1890 / u_udp_tx_cfg=336 /
u_app_udp=1128 / u_tx_udp_arb=8` ⇒ **没被综合裁掉** (T1/T2 期的"无消费者则锥被裁"疑虑解除)。

**旧族大幅改善**: `u_retx → RAMB` 从 setup 最差 400 **完全消失** (0 命中), `u_hls` 也 0 命中;
P5d 记录的新风险族 `app_ctrl.c_snd_wnd → app_pattern` 同样**完全退出** (0 命中)。worst-400 hold
里最差换成 `u_app_ctrl/c_snd_una_reg → u_app_status/sn_ua_reg` (0.051), 其次
`retx wa_o_r_reg → mem ADDRARDADDR` (0.056)、`mac_tx fifo wptr → RAMB WADR` (0.057)。

**⚠️ T3 私有 route 门 (+0.123) 与官方构建 (+0.290) 的差异是流程差异, 不是布局方差**:
`sim/p5e_udp/route_check.tcl` 在 `set_property strategy Performance_ExtraTimingOpt` 之后是
**手动 `opt_design/place_design/route_design`**、从未 `launch_runs impl_1` ⇒ **strategy 未生效**,
且**缺 `phys_opt_design`** (官方 build 走 launch_runs 全流程) ⇒ 该报告的绝对值**只能当相对参考**
(它给出的"app 侧锥位列第 7"这类族序结论仍有效)。

### ⑧ 板级验证 (T6, APP_MODE 位流)

- **`peer.exe --udp-selftest` PASS** (无板闭环: 构造 → 解析 → 图案校验 + 5 类负对照)。
- **UDP app 通路 (板发 → PC 收, 逐字节校验)**: `--udp-rx-only` 收板侧图案流
  **`verified=82432 mismatch=0`**。
- **帧间隔实测 478.5µs** vs 设计值 `TX_GAP=58000` 拍 @125MHz ⇒ (1538+58000)/125MHz = **476.3µs**
  ⇒ 限速发生器与设计一致 (差 0.5% 内, 时间戳分辨率)。
- **限速档全通**: 20 / 50 / 100 / 200 Mbps 全档 PASS (`--rate-mbps`)。
- **TCP 不回归**: 4MB 单连接逐字节精确 + **同四元组重连 5/5** (D6 判据)。
- **端口分流实测**: 8080 = HLS `udp_echo` 照旧回显 / **8081 = app 分流** (app 收 + app 回图案流);
  **负对照: 往 8080 发不会教 peer 表** ⇒ 8081 的 app TX 仍零帧 (学习源只认自己匹配的帧)。
- **UDP 与 TCP 共存互不干扰** (TCP 4MB 期间 app 图案流照常被 TCP 优先让路)。

### ⑨ ⚠️ 板级观测缺口 (这一版**没验**的东西, 必须记)

> ⛔ **本段已过期（2026-09-30 标注，`P7B_W13_AUDIT.md` §②-V27）** —— **别按它当现状引用**：
> P6e/P6b 起 `udpapp_*` 已进 **PCIe 快照窗口**（36 字版 = `W8–W13`；**现役 = 61 字窗口**
> —— P7b-BIZ 扩窗、新增字全落 MSB 端、`BUILD_ID_V=8`；`W8–W13` 这一批**逐项未动** ⇒ 上句的读法不变；**现役表 = `P7B_BIZ_WINDOW.md` §1**，`P6E_OBS.md` 的 36 字表是历史件），
> **板级可读**；KU5P 上仍无 UART 消费者这一点**继续成立**（所以读法只走 PCIe 窗口）。
> ⚠️ 另：`W13` 的读数**须同窗 `ΔW10 > 0`** 才有判别力，否则是空判据。

- `udpapp_*` (app 演示统计: `tx_bytes/tx_frames/rx_bytes/rx_frames/rx_null/mismatch/active/done`)
  在 wrapper 里**只有 LED 消费者** (`led_d0..d3`), **无 UART 消费者**; `u_udp_split` 的
  `app_udp_stat_*` (frames/bytes/null/**drop_crc/drop_ovf/drop_part/drop_excl**/hls_*) 更是**完全悬空**。
- ⇒ 口径 (~~以本段为准~~ **已过期, 见段首注**): **板 → PC 方向有硬证据** (PC 逐字节 82432B / `mismatch=0`);
  ~~**PC → 板方向 (app RX 口) 只有"PC 连续灌入无异常"**, 板侧校验器的逐字节结论
  (`udpapp_rx_bytes/mismatch`) 与**全部丢帧计数**都**读不出来** ⇒ 该方向的正确性**只有 TB 门**
  (T4 `pos`/`badcrc` 等 + T5 真 wrapper 全链) 覆盖, 板级不覆盖。~~
  ⇒ ⛔ **这句对 P6e/P6b 起已不成立**：`udpapp_*` 已进 PCIe 快照窗口（W8–W13）、**板级可读**
  （全仓唯一一条强引用 = BIZ S1 的 2.5 GB / `ΔW13 ≡ 0`，须同窗 `ΔW10 > 0`）。
- 影响: 将来要板级断言 app RX 正确性/丢帧率, 必须先把这几根计数线接进 `uart_dbg` 状态行
  (工作量小, 但要动 `board/uart_dbg.v` 与 wrapper 的状态行拼接)。

### ⑩ 口径更正: "app RX 字节串行 = 15.6 MB/s" 是 **8× 口径错误**

- **1 字节/拍 @125MHz = 125 MB/s = 1 Gbps 线速**; 15.6 是 125 **Mbps** 的字节数 (TL 的说明与
  `tools/cpp_peer/README.md` 都写错了 —— **README 已同步更正**; `peer.cpp` 的三处注释
  (`://364` / `://2283` / `://2611` 附近) 里同一错误**按本轮"只写文档"的纪律未改**, 重启 P6 时顺手修)。
- ⇒ **字节串行 RX 不是"跟不上"**, 而是**恰好等于 1G 线速** (以太网每帧 66B 开销 ⇒ 载荷率只有线速
  的 1472/1538 = **95.7%**, 净余量 ~4.5%, 帧间缝隙由 `udp_split` 的 4KB 帧缓冲吸收)。
- **T6 实测的 ~25 Mbps 天花板是 HLS 慢路径的限制** (816B/ms 量级), 与 app RX 通路**无关**。
- ⇒ 推论 (写给将来): 若以"app RX 必须限速所以设计要迁就"为前提做取舍, 该前提是**错的**;
  限速只对 HLS 慢路径方向成立。

## P6 交接记录 (未做 — 用户 2026-09-20 裁决: P5e 完成后停止, 不做 P6)

> 本节是 **P6 的调研结论存档**, 不是施工记录。**P6 一行 RTL 都没写、一次板都没上。**
> 素材 = `../udp_hls_eco/design_review/04` (10G 迁移评估) + 本工程的实测基线 + 本轮针对 10G 的
> 专项核查。**用途**: 将来无论谁重启 10G, 从本节开始, 不要重新调研。

### 定性: P6 的技术前提**不是"提时钟"而是"换前端 + 重收敛"**

- 本工程 CLAUDE.md 的立项目标写的是"10G 时仅提时钟到 156.25MHz, 流水线不改"。**这句话只对
  中间各级成立, 对 MAC 边界不成立**: `rtl/mac_rx_64.v` / `rtl/mac_tx_64.v` 是**字节串行
  (1 字节/拍) 的 GMII 模块** (前导/GMII 字节搬运/FCS 逐字节 CRC 都在里面) ⇒ 10G 下**必须整体
  替换**, 否则 **TX 天花板 1.25 Gbps** (1B/拍 @156.25MHz), 连 10G 的 1/8 都不到。
- ⇒ P6 = **前端替换 (PCS/PMA + shim + MAC 语义) + 全设计重收敛 (时序/BRAM 映射/HLS 域) +
  对端与工具链换代**, 是一个**新工程量的里程碑**, 不是一次时钟手术。

### 要做的事 (6 块)

| 块 | 内容 | 关键点 |
|---|---|---|
| **A 时钟与前端** | 换晶振 (10G 参考钟) + PCS/PMA + AXIS→左对齐字流 shim | 参考钟归属**必须先定案** (见"物理前提") |
| **B MAC 语义** | **FCS 改 8B/拍** (现有逐字节 CRC 在 8B/拍 下要么 8 路并行要么换算法) + 前导/IFG/pad 语义复核 | 64B 帧下每帧开销敏感 |
| **C 吞吐复核** | `rx_classify` 的吞吐上限: ~~**skid 改真 FIFO**~~ (现每帧停 3 拍 (非 TCP) / 6 拍 (TCP) ⇒ 上限 `N/(N+停顿)`、**最小帧 57.1%**); VLAN 重构 ⚠️ **2026-09-29 复核更正**（原件 `_proj_10g/notes/P7B_RXCLASSIFY_AUDIT.md`）：① 该 TODO **未落地**（as-built 仍是 6 字寄存器 skid，`rtl/rx_classify.v:52,60-65`；`git log -1 -- rtl/rx_classify.v` = `122b0c0`，P6a/P6b/F4/P7a 全未碰）；② 但**它不是"静默丢字"那类**（DRAIN 是寄存器 hold + `tready=0` 顶背压，`:78-85,102-103`；1G 下字间隔 10 dp 拍 > 6 拍停顿, 安全）；③ **真实的病是硬吞吐上限**（FILL 与 DRAIN 同 FSM 不重叠、FILL 期不输出，`:84-85`），**"加深上游 FIFO 修不了"**，只有"收字与等 w5 决策解耦"能修；④ **10G 下必然触发**（156.25MHz 每拍有字时 TCP 每帧净赤字 ≈4.5 字，现有 264 字弹性 ≈3.6 µs 填满 ⇒ MAC 层整帧丢，有计数 `W34` 已接出快照窗口） | 1G 时代"停 6 拍"无所谓, 10G 是致命 |
| **D 窗口与缓冲** | **DDR3 大窗** (BRAM 只剩 ~30%, 且 retx 已用 16×64KB = 1MB) | 见风险 ②: 不换大窗, TCP 方向**测出来还是 ~1G** |
| **E HLS 慢路径** | `u_hls` = **38.7% LUT** (层次面积实测) ⇒ **单域 vs 双域**抉择 (慢路径是否也跑 156.25MHz) | 单域省 CDC 但要重收敛最重的块; 双域省事但要 CDC 与一致性论证 |
| **F 工具链** | 校验器 8 路并行 (图案/校验吞吐) + **10G 对端** (1G 的 C++ 合成对端 flush 上限 ~191k fps ≈ 1.1 Gbps, 必须换) | 见"要准备" |

### 要准备的东西

- **晶振** (10G 参考钟候选: `SiT9120AI-2B3-33E156.25`, 156.25MHz)。
- **10G 对端**: 现有 PC 网卡 **Killer E5000B 是 5G RJ45、无 SFP+** ⇒ 10G 对端**不存在**,
  必须新购/新配 (SFP+ 网卡 + DAC/光模块, 或同板双口自环)。
- ⚠️ **一个必须先定案的物理前提 (可能推翻整个 A 块)**: `PORT_NOTES` 记的 10G 参考钟引脚是
  **X5 → Quad 115 (H5/H6)**, 而 **DEMO `k724` 的 XDC 实测是 D6 / quad 116 / X0Y0 / G4** ——
  **两者冲突。若晶振实际在 quad 115, 换晶振无效** (参考钟必须进 GT 对应的 quad)。
  **定案方法**: 读 `DEMO/k724*` 的 XDC + 本板原理图 `开发板硬件资料/` 的 GT 时钟网络,
  两者对上再动硬件。**这件事在买晶振之前做。**

### 六个前置实验 (K1-K6, 都不需要新硬件, 可以现在就做)

| 编号 | 实验 | 产出 |
|---|---|---|
| **K1** | 156.25MHz 时序尖峰: 用现有网表 + 收紧周期跑一次 impl, 看最差族的 slack 分布 | 判断 10G 时序是"紧"还是"崩" |
| **K2** | 字节序实测: MAC 边界改 8B/拍后 FCS/前导的字节序在真链路上复核 | 避免"仿真对/板子错" |
| **K3** | HLS 收敛探针: `u_hls` 单独在 156.25MHz 跑一次 | 单域/双域抉择的输入 |
| **K4** | **license 核查**: PG157 (10G MAC) 是否在现有 license 覆盖范围内 | ~~**可阻断**: 不覆盖则只能走免费 PCS/PMA 路线~~ ⇒ ✅ **已答（2026-09-29 复核更正）：不阻断。** 本机 `Xilinx.lic` 含 `INCREMENT xxv_eth_mac_pcs … permanent uncounted`（同批 `ten_gig_eth_mac`/`l_eth_mac_pcs`/`xxv_eth_basekr` 等全部 permanent），`_lic/prep_stdout.txt` 实测 `xxv_ethernet 5.0` 三种 CORE 配置 `IS_LOCKED` **全 0** 且 `generate_target all` 出完整 RTL ⇒ **PG157 路线可用**；失败形态是**综合期硬失败**（`Fatal Error. License Check failed for secure IP for feature 'xxv_eth_mac_pcs@2025.05'`），**不是**位流超时 |
| **K5** | 参考钟定案 (上面那条物理前提) | 决定 A 块是否要改板 |
| **K6** | BRAM 映射尖峰: 8B/拍 下各级 FIFO/缓冲的 BRAM 映射 (现 312/445 = 70%) | 判断是否必须先上 DDR3 |

### 三个决策点

1. **单域 vs 双域** (数据面与 HLS 慢路径是否都跑 156.25MHz) —— 输入 = K3 + 风险 ①。
2. **前端 IP 路线**: **免费 10GBASE-R PCS/PMA (PG068) + 自写 shim** vs **PG157** (10G MAC
   ~~收费核; **eval 版硬件有 8 小时停机限制** ⇒ 板级长时间测试不可行~~)。输入 = K4。
   ⚠️ **2026-09-29 复核更正**：上面那个"收费核 + eval 版 8 小时停机"的前提**被证伪** —— 本机 license
   **永久覆盖** `xxv_eth_mac_pcs`（`Xilinx.lic` 的 `permanent uncounted`），**没有** eval 停机计时；
   而**缺** license 的失败形态是**综合期硬失败**（`Feature: Internal_bitstream` /
   `Fatal Error. License Check failed for secure IP for feature 'xxv_eth_mac_pcs@2025.05'`），
   **不是**"位流能出但跑几小时就停"。⇒ 路线抉择的输入不再是 license，而是判据直接性（仍推荐 PG068 路线，
   理由见 `_proj_10g/notes/P7B_PHY_IFACE.md`；P7a 已实测 gtwizard 路线可用）。
3. **10G 对端方案**: PCIe NIC + DPDK / **同板双 SFP+ 自环对打** (最省外部依赖) / 商用测试仪 /
   仅物理层自环 (只验链路不验数据面)。输入 = 预算 + 现有工具余量。

### 两个**阻断级**风险

1. **156.25MHz 时序**: 当前 125MHz 下 worst-400 的 slack **全在 0.290–0.297ns** (app 锥最差
   0.297, TCP 锥 0.290), **85% 是布线延迟** (`net (fo=46642…) 1.454ns` 这种扇出/布线主导项),
   最差族扇出 **fo=498** ⇒ 从 8ns 压到 6.4ns 要**每条砍 ≥1.6ns**。这不是"收紧约束再跑一遍"
   能解决的量级 —— 它要求**结构性改动** (降扇出/加流水级/换算法), 属于 P6 的主体工程量。
2. **TCP 吞吐 = 窗口 × RTT 的天花板**: 现通告窗 48KB、PC↔板 RTT 428µs ⇒
   `48KB / 428µs ≈ 890 Mbps` —— **这就是 TCP 方向的天花板** (`--rx-only` 实测 1GB @ 891.5 Mbps
   正是它)。⇒ **不换 DDR3 大窗, 10G 下 TCP 方向测出来还是 ~1G**。**行情 (UDP 组播) 方向无此问题**
   (单/双向流式, 无窗口约束) ⇒ 若 P6 的目标是行情通路, TCP 窗口改造可以推后。

### 建议阶段划分与工期

`P6-0` (前置 K1-K6 + 硬件定案) → `P6a` (时钟/前端替换, 含新 MAC 8B/拍) → `P6b` (数据面重收敛:
`rx_classify` skid→FIFO / VLAN / 各级 FIFO 重映射) → `P6c` (BRAM/DDR3 大窗) → `P6d` (HLS 慢路径
单域/双域 + 收敛) → `P6e` (工具链 + 对端) → `P6f` (板级验收: 线速/延迟/共存)。

⚠️ **2026-09-29 复核更正**：上面的 `P6b` 阶段项 **`rx_classify` skid→FIFO 未落地**（P6b 已验收，
该项仍留在"要做"栏；as-built = 6 字寄存器 skid，`git log -1 -- rtl/rx_classify.v` = `122b0c0`），
且**"skid 改真 FIFO"本身不是正确修法** —— 真实病是**硬吞吐上限**（最小帧 57.1%，10G 必然触发），
只有"收字与等 w5 决策解耦"能修。原件 `_proj_10g/notes/P7B_RXCLASSIFY_AUDIT.md`。

**工期估计 33–66 天** (取决于单域/双域与 DDR3 是否进范围)。⚠️ `../udp_hls_eco/design_review/04`
给的 **"8–15 人天"只覆盖了前端替换那一段** (A/B 块的一部分), 不含 C/D/E/F 与验收 ⇒ **不能引用
那个数字做排期**。

### 六条更正 (调研中查出的既有记载错误, 将来别照抄)

1. **C1b 的 `Δ = 32×88×8 = 22528` 是单位混乘** (TL 的旧记载): 把"ackq 深 × 每帧拍数"的**字节**比
   当成了**拍**数。按拍/字节的**不变量**算, Δ 实为 **≈2.7KB**; 再加扫描周期项 ~2KB, 合计
   **~4.7KB < 16KB 余量** ⇒ **大概率不溢出**。⚠️ 但**门的判据要重写** (旧判据基于错误算式)。
2. **10G 参考钟归属冲突** (见"物理前提"): `PORT_NOTES` 的 X5→Quad115 与 `k724` XDC 的
   D6/quad116 不一致, 必须定案。
3. `design_review/04` 说慢路径是 **`ap_ctrl_hs`**, **实际是 `ap_ctrl_none`** (本工程 HLS 全
   自由运行) ⇒ 该文档中依赖 `ap_ctrl_hs` 握手时序的论证**不适用本工程**。
4. `design_review/04` 的工期估计**只覆盖前端替换** (见上)。
5. `PORT_NOTES` 早前记的 **"3 字 skid"** 已过时 —— **代码里是 6 字** (见 `rx_classify`)。
6. **P5e 提交后基线冻结**: 本节的实测数字全部锚在 `9218c47` 之后的 **P5e 提交** (WNS +0.290 /
   LUT 51588 / BRAM 312); 若将来在 1G 上继续改代码, 这些数字需要重测才能当 10G 的起点。

## 2026-09-28 P6a-T1/T2 (K7 → KU5P 器件移植第一批: frame_fifo 的 RAMB36E2 + RGMII 前端) — 门全绿

> 平台切换: **P6 落在 XCKU5PMini (xcku5p-ffvb676-1-e)**; K7/ECO 板保留为已验证的 1G 基线。
> 本节的源码在 `D:/repo/XCKU5PMini/udp_hls_10g` (本仓已整体拷贝到那里, **以该副本为准**)。
> 规格见 `~/.claude/plans/p6_spec.md`; 板卡事实见同目录 `CLAUDE.md`。

### T1 — `rtl/frame_fifo.v` 主存 RAMB36E1 → RAMB36E2 (`` `ifdef DEV_USP ``)
- **K7 路径零改动**: 未定义宏时逐字不变 (`git diff` 为纯新增; RTL 行 0 删除, 仅注释行有更正)。
- **E2 与 E1 的四处差异** (按本机 unisim 源核对 + 实测):
  ① 地址口 **15 位** (E1 16 位); 512x72 的字址仍在 **[14:6]** ⇒ `{a[8:0],6'h00}` (E1 是 `{1'b1,a[8:0],6'h3F}`)
     (依据 `RAMB36E2.v:2190` 的 `rd_addr_a_mask` = `{9{1'b1},6'h00}`)。
  ② **宽度属性的方向语义**: `READ_WIDTH_A`/`WRITE_WIDTH_B` 可为 **72**, 而 **`READ_WIDTH_B`/`WRITE_WIDTH_A` 不许 72**
     (只许 0/1/2/4/9/18/36 —— SDP 只有 A 读 / B 写一个方向)。照抄 E1 的"四个都填 72"会被模型内部归一成
     非法值 8 而报 `Unisim RAMB36E2-269/278`。**正确组合 = `READ_WIDTH_A(72), WRITE_WIDTH_B(72), 另两个 0`**。
  ③ 端口改名 (DOUTADOUT/DINADIN/DINP*), 且 **无 `RAM_MODE`/`SIM_DEVICE`/`RDADDR_COLLISION_HWCONFIG` 参数**;
     新增 `CASCADE_ORDER_*`/`CLOCK_DOMAINS`/`ENADDRENA,B`/`RDADDRCHANGEA,B`/`SLEEP_ASYNC`, 需显式接
     `ADDRENA/ADDRENB=1`、`SLEEP=0` 与 CASDIMUX/CASDOMUX(EN)/CASOREGIMUX(EN) 一族哑端口。
  ④ **仿真模型行为差异两条**: `ENBWREN=0` 的写**丢** (两代同); 而 **未写槽初值 E2 = 0** (INIT 默认)。
     ⚠️ 另有一条**仿真器坑**: E2 模型的 INIT 装载在 t>0 才完成 ⇒ **上电头 ~200ns 的写会被 INIT 覆盖**
     (非硬件行为; TB 里必须先 `#200` 再写, 否则首写"丢失")。
- **判据两条** (`sim/p6a_ku5p/`):
  · 原语级 `tb/tb_ramb36e2_sem.v`: `SEM RESULT: E2_SEMANTICS_MATCH_7SERIES` —— 1 拍读延迟 / 同址碰撞
    (X 一拍 + 内容存活) / 字址 [14:6] 三条判据全一致。
  · 行为级**同一 TB 同激励 A/B** (`run_tb_frame_fifo_{us,k7}.bat`): 两者 `PASS_ALL` 六计数逐数一致
    (`writes A=568139 B=595715 C=616302 pops A=567224 B=591216 C=611802 cycles=750700`)。
- ⚠️ **写使能口的更正**: 本仓 P4b-7 期的注释把"写边沿使能"记成 `ENARDEN` —— 那是**读口 A** 的使能;
  **SDP 下写走 B 口, 使能是 `ENBWREN`** (旧探针只拨 en_a, 测的是"读口使能不影响写", 结论系测量错误)。
  已更正 `rtl/frame_fifo.v` 注释与探针 (P3a/P3b 两口分测)。两代器件在这一点上**行为一致**。
- ⚠️ **DEV_USP 分支尚未过综合/实现**（闸 G 才有答案）⇒ "仿真语义已复验" ≠ "已上器件验证"。

### T2 — RGMII 前端: 三条实证把配方从"IDELAYE3 重标定"改成"零 IDELAY"
1. **HDIO 放不了 IDELAY**: KU5P 的 RGMII/MDIO 全在 **bank 86 = HDIO** (不是 HP)。自建
   `board/ku5p_probe/idly_probe.v` (真实引脚 + IBUF/BUFG/MMCME4/IDELAYCTRL/IDELAYE3/IDDRE1/ODDRE1)
   综合过、opt 过, `place_design` 报 **`ERROR: [DRC PLHDIO-6] … the shape contains IDelay and ISerDes
   (details: presence of I/ODELAY or I/OSERDES is not supported in HDIO)`**。
   HDIO 同时**没有 BUFIO/BUFR** (厂商 KU5P 设计里 `BUFIO` 被综合降级成 `BUFGCE`)。
2. **底板把 PHY 的两个延迟搭接都拉高** (底板原理图**出图**实测 —— PDF 文本层是错位叠加的, **不能 grep 判读**):
   `LED2/RXDLY`(pin32)→R52 10k→VDD3.3 (**RXDLY=1**)、`RXD[1]/TXDLY`(pin16)→R51 10k→VDD3.3 (**TXDLY=1**)。
   即 RTL8211E 手册 10.6.5 Figure 32/33 的 "internal delay added" 模式 ⇒ **2ns 在 PHY 内部, FPGA 侧零延迟**。
   顺带: 原理图注记 `PHY_ADDR[2:0]=001` ⇒ PHY 在 MDIO 地址 1。
3. **判据不用 K7 当 oracle** (两块板 PHY 搭接不同 ⇒ 前端本来就该不同): 新写
   `tb/tb_rgmii_phy_model.v` = **行为级 RTL8211E 模型** (RXDLY=1/TXDLY=1) + 往返逐字节一致。
   实测: **KU5P 前端 TX/RX 各 200/200 字节 d=0 全对**; **K7 前端 TX 也全对, RX mis=179 全错**
   ⇒ 反推 **ECO 板 PHY 的 RXDLY=0** (K7 靠 `IDELAYE2` + `BUFG(~rxc)` 自己凑相位)。
4. **⚠️ 一条被实测推翻的推论 (值得记)**: 一度以为"K7 的 TX 结构在 TXDLY=1 下不自洽"(理由:
   `.D1(gmii_txd_r_d1)` 取 2 拍前字节的低 nibble、`.D2(gmii_txd_low)` 取 1 拍前字节的高 nibble)。
   **错** —— `gmii_txd_low` 是**同一时钟块内的阻塞赋值**读沿前 `gmii_txd_r` (天然多滞后一拍),
   正好补偿 `gmii_txd_r_d1` 的两级流水 ⇒ **两代前端在 nibble 约定上等价**。教训: 逐拍手算流水线时,
   必须把**阻塞赋值**的采样时刻单独算一遍 (它读的是沿前值, 相当于额外的寄存器级)。
5. **落地文件**: `board/util_gmii_to_rgmii_us.v` (零 IDELAY: RX `IBUF→BUFG→IDDRE1`
   + `IS_CB_INVERTED=1` 且 C/CB 同网; TX `ODDRE1` 边沿对齐, D1/D2 = **同一个**已寄存字节的低/高 nibble);
   `board/wrapper_p4.v` 加 `` `ifdef DEV_USP `` 三处 (端口表去掉 `fpga_gclk` / 去掉 MMCM+IDELAYCTRL /
   前端实例换模块名 —— 端口名一致故只需换名); `board/ku5p_p6a_{t8p0,t6p4}.xdc` (与 K7 闸 B 的 XDC
   **逐项同构**, 差异 = LVCMOS33 / **generated clock 不带 -invert** / 无 fpga_gclk);
   `board/build_p6a_ku5p.tcl` + `run_build_p6a_ku5p.bat [t8p0|t6p4]`; `p6a_ku5p_verify/` (只读校验, 同 K7 的 p6_verify)。

### 本轮踩到的坑 (按坑的"咬人程度"排序)
1. **判据的假通过路径 (最贵)**: 初版 `tb_rgmii_phy_model.v` 把 `ctl_fall_bad` 只打印、不进 PASS 条件,
   且 ER 恒 0 ⇒ **"D2 接错"与"gmii_rx_er 硬接 0"两种坏前端都会 PASS**。已修: PASS 四项
   (data / 条数 / TX_CTL 两半 / RX_ER), 且序列里**各注入 1 个 ER=1 的字节**把两条通路都激励到。
   ⇒ **审查/测试 agent 的第一价值就是找这种"判据声称检查了却没接进判据"的洞。**
2. **bat 里写中文注释 → GBK 控制台下被拆成伪命令** (本仓老坑复发): 症状是 `'T' 不是内部或外部命令`
   + `系统找不到文件`, 但构建其实照常跑 (极易忽略)。**新 bat 一律纯 ASCII**, 写完用
   "非 ASCII 字节数 == 0 且 CR 数 == LF 数" 自检 (本项目已把这条写进自检脚本)。
3. **`str.replace` 改到不该改的分支**: 给 `frame_fifo` 加 E2 分支时, 一条跨行的
   `.WRITE_WIDTH_A(72), .WRITE_WIDTH_B(72),` 替换**同时命中了 E1 分支** ⇒ 直接破坏"K7 零回归"。
   靠 `git diff --numstat` (发现 4 条删除行) 才抓到。⇒ **改 RTL 后立刻看 numstat**; 多分支文件用
   索引切片而不是宽匹配替换。
4. **Vivado 的 `dfx_runtime.txt` 落在当前工作目录** (每次跑都在 cwd 掉一个), 会被 git 当新文件。
   本仓根的那份是**已跟踪**的历史遗留, 新目录里出现的要及时删。
5. **`-tclargs` 会贪婪吞掉后面的 `-log`** (老坑): 本轮改用**环境变量** `P6A_TAG` 传参。
6. **E2 的 `Error: [Unisim RAMB36E2-11] Memory Collision at ...` 是设计预期的信息** (bypass 拍的同址
   碰撞, 每帧都可能出现成百条) —— ⚠️ **任何按 "Error" 抓失败的脚本会在此假报**。
7. **自建模型时"解码/编码必须镜像" (本项目最贵的一条判据教训)**: `tb_rgmii_phy_model.v` 的 TX 侧
   解码按 **RGMII 半槽**口径 (`TX_ER = ctl_rise ^ ctl_fall`), 而 RX 侧初版把 `RX_CTL` 整字节驱动成
   同值 ⇒ ER=1 的字节被 DUT 解成 **DV=0** (整条流错位 recorded=199 / data_mis=99), 且"ER 通路"
   那条判据**在任何合法 DUT 上都不可被激励** (假绿色)。修正 = 一行: `ctl_w = phy_clk ? load_en :
   (load_en & ~cur_er)` (与数据 nibble 同相位)。⇒ **凡自建 stimulus/模型, 必须把"对端的编解码"
   写成同一套口径, 并问一句"这条判据真的能被一个坏 DUT 激励到吗"**。
8. **xvlog 少了 `-work xil_defaultlib` 会静默落到 `work` 库** (本轮 bat 重生成时漏了):
   症状是 xelab 报 `Cannot find design unit xil_defaultlib.<tb> in library work`。
   更隐蔽的是**反向情形**: 库已存在时, xvlog 分析了新源码但 `.sdb` 时间戳**可能不更新**
   (本次实测: 库里 `rgmii_pair.sdb` 停在 21:54, 而我在 22:02 用"修好的判据"跑出与修前**一模一样**
   的 FAIL 读数 —— 差点被当成 DUT 缺陷)。⇒ **判据类跑之前先 `rm -rf xsim.dir`** (或独立目录)
   是最省事的免疫; 判读异常时**先看库文件时间戳**, 别先改 RTL。
9. **`{1'b0, r_ad[8:0], 6'h00}` 接到 15 位地址口是 no-op** (最高位被端口截掉, 与原式功能相同) ——
   这类"16 位字面量 → 15 位端口"的静默截断**功能门抓不住**, 只有 elaboration 的
   `WARNING: [VRFC 10-3091] actual bit length ... differs ...` 能看见。
   ⇒ 已把 `10-3091` 与隐式网签名一并列为门里的**硬失败**。
   ⚠️ **2026-09-29 订正 (P7B 实测)**: Vivado 2025.2 **不再打印 `implicitly declared`** (实测全部日志命中 0) ⇒ 旧关键字是**哑门**。Vivado 2025.2 的真实签名分两种形态、**两个不同检测点**: ① 端口连接形式 (静默截断) —— **xvlog 一个字都不打印** (exit 0、日志全空, `-sv` 也一样), 只有 `xelab` 报 `WARNING: [VRFC 10-3091] actual bit length 1 differs from formal bit length 64 for port 'q'`, 或 `synth_design` 报 `INFO: [Synth 8-11241] undeclared symbol 'mid', assumed default net type 'wire'`; ② 表达式形式 —— `xvlog` 报 `ERROR: [VRFC 10-2989] '<name>' is not declared` (synth 用 `8-36`)。⇒ **只 grep xvlog 日志的门结构性地拓不到本坑 —— 换任何关键字都不行, 必须补 `xelab`/`synth_design` 这一面** (现役两处 lint 入口 `board/run_lint_p6e.bat` / `_proj_10g/tcl/run_lint_p7a.bat` 已补, 各 +12 s / +24 s)。 **推荐键表 (5 键, OR 语义)**: `Synth 8-11241` · `undeclared symbol` · `VRFC 10-3091] actual bit length 1 differs from formal bit length` · `VRFC 10-2989` · `implicitly declared` (末者只为 2025.2 之前的工具保留, 在 2025.2 下恒 0)。 ⚠️ **`10-3091` 必须带上 `] actual bit length 1 differs from formal bit length`**: 裸 `VRFC 10-3091` 会命中 `board/util_gmii_to_rgmii.v` 的 **14 处良性 unsized 字面量** (`.CE(1)`/`.D1(1)`/`.D2(0)`/`.R(0)`/`.S(0)`, 报 `actual bit length 32 differs from formal bit length 1`) —— 默认 (K7) 配置每次 xelab 都报, 当硬失败就是天天误伤。隐式网**必然是 1 位** ⇒ "actual = 1" 就是本坑的精确签名 (收窄后仍抓住病理件 A1)。 **刻意排除的键 (都有实测假阳性)**: `8-7129`/`unconnected or has no load` (命中干净件的**合法未用端口**)、`8-6014`/`8-3917` (纯优化提示)、`VRFC 10-3645`/`remains unconnected` (xelab 侧对偶 —— 干净的真实 P6e 设计一跑就 **20 条**)。 ⚠️ **裸 `findstr /C:"10-3091"` 那一族"位宽不符"判定结构性常哑**: 语料实测 `10-3091` 在 **869 份 xvlog 日志中 0 命中**、452 份 xelab 日志中 173 份命中 ⇒ **凡 grep `xvlog_*.log` 的裸 `10-3091` 判定永远不会触发**。 ⚠️ **历史事实**: `IMPLICIT-DECL-FAIL` / `BITWIDTH-MISMATCH-FAIL` 在**全仓留存日志里 0 命中** ⇒ 无任何证据表明这两条门**曾经**响过 (严格措辞: "没有留存日志含这些标记" ≠ "从未失败")。 规范检测器 = `sim/p4gates/implicit_gate.bat` (+ `implicit_gate_selftest.bat` 九项对照)；取证 = `_proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md` (修复) + `_proj_10g/notes/P7B_IMPLICIT_GATE_ROLLOUT.md` (铺开 + 语料级假阳性验证)。
10. **两家 unisim 模型的报错口径不同**: US+ 构建里 bypass 拍的同址碰撞打 **`Error: [Unisim RAMB36E2-11]`**
    (通过的正常仿真里 1983 条), K7 构建同现象却是 **2004 条无 `Error:` 前缀**的
    `Memory Collision Error on RAMB36E1`。两个构建功能逐位相同而报数不同 ⇒
    **任何"日志含 Error 即失败"的判据会在 US+ 构建上假失败** (本项目 BAS 期已有同源教训)。

### 闸 G — KU5P 上的时序基线 (2026-09-28, **结论: 数据面在 16nm 上直接收口**)

构建口径: 与 K7 闸 B **逐项同构** (`build_p6a_ku5p.tcl` 同文件清单 / `APP_MODE=1` /
`Performance_ExtraTimingOpt` / `launch_runs` 全流程 / XDC 同构, 只换器件+前端模块+引脚),
两跑 `P6A_TAG=t8p0|t6p4` 只改 `create_clock` 的周期。读数脚本 `p6a_ku5p_verify/`(只读)。

| 指标 | **KU5P @8.000ns (真实 1G)** | **KU5P @6.400ns (10G 时钟尖峰)** | K7 @6.400ns (闸 B, 对照) |
|---|---|---|---|
| WNS / TNS 失败端点 | **+0.973** / 0 | **+0.426** / **0** | −0.948 / **647** |
| WHS / THS 失败端点 | **+0.013** / 0 | **+0.012** / 0 | +0.054 / 0 |
| WPWS / 失败端点 | +6.501 / 0 | **−1.600 / 16** (见下) | +0.264 / 0 |
| LUT / FF | 46,842 (21.6%) / 40,688 (9.4%) | 同左 | 51,588 / 41,513 |
| Block RAM | **312** (RAMB36E2×281 + RAMB18E2×62) | 312 | 312 (RAMB36E1) |
| IOB / DSP / URAM | 18 / 4 / 0 | 同左 | 177 / 3 / – |
| 位流 | 15,431,261 B | 有 | – |

**三条结论**:
1. ⭐ **K7 在 6.4ns 下的 647 个 setup 失败端点 (WNS −0.948) 到 KU5P 上全部消失**: 同样 RTL、同样
   流程与策略, 只换器件+前端 ⇒ WNS 从 −0.948 变 **+0.426**, 失败端点 647 → **0**。
   这正是前置闸 U1 ("K7 上 −0.948, 16nm 预计吸收, 未实测") 的答案 —— **16nm -1 速度等级吸收有余**。
2. ⚠️ **t6p4 的 16 条脉冲宽度违例是实验方法的产物, 不是数据面缺陷**: 全部是
   `IDDRE1/C` 与 `IDDRE1/CB` 的 **Min Period 检查 (required 8.000ns, actual 6.400ns, slack −1.600)**
   —— UltraScale+ **HDIO 的 DDR I/O 寄存器器件上限就是 125MHz**。本实验把 RGMII 前端(本质 125MHz)
   一起按 156.25MHz 约束才触发; 而 **P6b 的既定方案正是"1G 前端留在 125MHz + async FIFO 跨域"**
   (见 p6_spec §P6b) ⇒ 该违例在正式方案里不复存在。**读数时务必把这条与 setup/hold 分开看**。
3. **RAMB36E2 映射正确**: Block RAM tile = **312, 与 K7 逐数相同**, 且器件报告点名
   `RAMB36E2 only ×281` / `RAMB18E2 only ×62` ⇒ T1 的 `DEV_USP` 分支**综合+实现都成立**
   (此前只到行为级仿真)。

**hold 余量仍薄**: t8p0 WHS **+0.013** / t6p4 **+0.012** (K7 时代是 +0.010/+0.051), 性质一致 ——
`report_timing -delay_type min -max_paths 400` 的族 (见 `p6a_<tag>_hold_400.rpt`) 是后续加逻辑时
**最先失败**的地方; 与 K7 的结论相同: 加逻辑前先看这三个族的余量。

**遗留**: 位流已出, 但**未上板** —— 板级第一步是"烧 t8p0 位流 + ping/图案测试"来验证 15 根 RGMII
引脚与零 IDELAY 配方 (两者都只有图纸/模型证据, 无硅上证据); 且烧录会把板子的 PCIe 端点顶掉(见
`XCKU5PMini/CLAUDE.md` 的纪律)。

## 2026-09-28 PCIe/XDMA 观测通道验证 (P6 风险 U4 关闭; U4b 判不可用)

**背景**: KU5P 板上**没有 UART** ⇒ P6 的观测通道定为 **PCIe / XDMA**。此前状态: 驱动"能编译+能链接"
已证, "**能加载 + 能搬数据**"未证 (全程未 insmod, 无 sudo)。本轮把后者关掉。

### 结论 (证据: `_pcie/README.md` 与对端机 `/tmp/pcie_verify.log`)

| 项 | 读数 |
|---|---|
| 端点 / 链路 | `02:00.0` `10ee:9034`; **`5.0 GT/s × 4` = PCIe 2.0 x4**(理论 2.0 GB/s; 端点 max 8.0GT/s, 受 Z87 芯片组封顶) |
| 驱动 | **out-of-tree `Xilinx XDMA Reference Driver xdma v2025.2.0`** probe 成功 (`dmesg: probe_one 0000:02:00.0 xdma0`) |
| 节点 | **19 个** `/dev/xdma0_{control,h2c_0,c2h_0,events_0..15}` (`crw------- root root` ⇒ **工具要 root**) |
| BAR | **`identify_bars: 1 BARs: config 0, user -1, bypass -1`** ⇒ 只引出配置 BAR, **无 user BAR**; `ch 1,1` = 1 H2C + 1 C2H |
| 寄存器 | `reg_rw /dev/xdma0_control 0x0 w` → **`0x1fc00006`** (非 0 非全 F) |
| 数据 | **4MB 图案 H2C→DDR4→C2H 逐字节一致**; 地址 0 与 16MB 两处都对; 同址重读一致; **反向读序(尾→头)也对** ⇒ 真存储非 FIFO |
| 吞吐(扫曲线) | **H2C 收敛到 ~804 MB/s**(64KB 单发仅 39 ⇒ 固定开销主导, `-c 64` 批量 741); **C2H ≤257 MB/s 且几乎不随批量改善** ⇒ 被工具的完成等待(~1.8ms/传输)污染, **真实上限未测到**, 别当板子能力。⚠️ 规划: 板子在**芯片组槽 2.0x4 = 2.0 GB/s**, 10G 线速 1.25 GB/s ⇒ **仅 1.6x 余量** ⇒ **不适合当 10G 速率的采集通道**, 适合寄存器/状态/低频数据 |
| MSI | `/proc/interrupts` 里 `IR-PCI-MSI-0000:02:00.0` 有计数 ⇒ 完成中断真的在走 |
| **U4b (XVC)** | **不可用**: 无 `/dev/xdma0_xvc` (厂商 BD 未例化) ⇒ **USB/JTAG 线仍必需**; 要省线须在自己 BD 里例化 |

### ⭐⭐ 本轮最贵的一条操作纪律 (已实测): **PCIe 端点只认"FPGA 配置先于主机 POST"**
- 主机开机时若 FPGA 跑的是**无 PCIe 的设计** (本轮: 我们 09-28 用 JTAG 烧的 `_proj_mdio` 位流,
  且**主机重启不会给 PCIe 槽断电** ⇒ 板子一直跑着它), 根端口扫描不到就**直接放弃链路**。
- **事后补烧带 PCIe 的设计救不回来**: 实测四种主机侧手段**全部无效** ——
  `rescan`(根端口/全总线) / 桥复位(`/sys/bus/pci/devices/0000:00:1c.0/reset` = secondary bus reset) /
  `setpci CAP_EXP+0x10.w=0x20`(Retrain Link) / `setpci ...=0x10→0x00`(Link Disable 1→0)。
  现象恒为 `LnkSta: Speed 2.5GT/s, Width x0` (而 `LnkCap: 5GT/s x4` 说明槽本身没问题)。
  机理: 主机侧复位的语义是"对**已训练**的链路发 hot reset", 链路没起来时传不下去;
  而 Xilinx PCIe 硬核通常还要一次 **PERST# 沿**才启动 LTSSM。
- **唯一可靠恢复 = 重启主机**(热重启即可; BIOS 在 POST 重新训练 ✓)。FPGA 若不掉电则保留位流,
  掉了就从 QSPI 加载厂商设计(**也带 XDMA**) —— 两种结果都对。
- ⇒ **纪律**: **要 PCIe 观测, 就先烧好带 PCIe 的位流、再重启主机**; 反过来, 每次 JTAG 烧非 PCIe
  设计都等于"本上电周期内放弃 PCIe 观测"。这对 P6e(正式观测通道)是硬约束。
- ⚠️ 附带: `SltSta: ... PresDet-`(主机认为槽里没卡) 在本板**一直如此**, 与链路无关, **不是故障**。

### 两个"判据写错会假失败"的坑 (都踩了)
1. **判"驱动是否绑定"不能用 `lspci -k`**: `insmod` 的 out-of-tree 模块不一定显示为
   `Kernel driver in use:`(它显示的是 in-tree 候选 `8250_pci`) ⇒ 计数为 0 的假 FAIL。
   **真证据 = `dmesg` 的 `probe_one ... xdma0` 行 + `/dev/xdma*` 节点齐**。
2. **`modinfo -n xdma` 会指向 in-tree 路径**(`.../kernel/drivers/dma/xilinx/xdma.ko.zst`),
   而实际加载的是我们的 out-of-tree 模块 —— 用 `dmesg` 的 `loading out-of-tree module` +
   `xdma v2025.2.0` 判身份, 别用 modinfo 的路径。

### 对我们自己设计的三条含义 (P6e 必读)
1. **user BAR 要自己例化**(厂商设计没有) —— P6e 的"寄存器映射/前置闸"必须显式引出 AXI-Lite。
2. **XVC 也要自己例化**(若要省 USB/JTAG 线); 否则"板子搬不搬"的权衡里 XVC 这条收益拿不到。
3. **单通道吞吐远低于链路**: 正式采集/灌数要**多通道 + 深提交**(`-c` 或自写批量提交的
   用户态程序), 不能拿 `dma_to_device` 单发数字当性能预期(`pcie_verify2.sh` 在扫这条曲线)。

## 2026-09-28 P6e 最小版: **我们自己的** PCIe/XDMA 观测通道 — 板级通过

**动机**: `_pcie/` 那轮验的是**厂商设计**上的 PCIe 通道, 但厂商 BD 的 `axilite_master_en=false`
⇒ 只有 config BAR ⇒ **读不到我们自己的任何状态**。P6e 要的是"我们自己的寄存器窗口 + 前置闸"。
本轮把它做出来并上板验穿 (全程约 2 小时, 从建工程到读数)。

**做法** (`_proj_pcie/`): `pcie_min_top.v` = `IBUFDS_GTE4` + `xdma_0`(IP `xdma:4.2`) + 我们写的
`axi_regs.v`(AXI4-Lite, 6 个寄存器)。**XDMA 配置逐条复制厂商那份实测跑通的值**
(`pcie_blk_locn=X0Y0` / `pf0_device_id=9034` / `ref_clk_freq=100_MHz` / `num_queues=1` /
`axi_data_width=128b`), **唯一改动 = `axilite_master_en=true`** ⇒ 引出 user BAR。
**接线配方逐条照抄厂商 BD 的 nets** (从那块板上唯一跑通过的接法里读出来的):
`IBUFDS_GTE4.O → sys_clk_gt`、`IBUFDS_GTE4.ODIV2 → sys_clk`、`pcieReset → sys_rst_n`(**直连无反相器**)。

**板级读数** (证据: `_proj_pcie/README.md` 与对端机 `/tmp/pcie_regs_check.log`):
- `identify_bars: **2 BARs: config 1, user 0**` (厂商: `1 BARs: config 0, user -1`) + `/dev/xdma0_user` 出现
  ⇒ **user BAR 生效**, 这是我们自己的逻辑存在的硬证据;
- **`MAGIC` = `0x50360001`** + `MARKER` = `0xdeadbeef` + SCRATCH 回环 + 字节选通 `0xffffff11`
  ⇒ 寄存器窗口全通; `FREECNT` 反解出 **AXI ≈250MHz**;
- 设计侧: `PCIE40E4`×1 + `GTYE4_CHANNEL`×4 + 36 BRAM, setup/hold 0 失败端点, DRC 0 错;
- **`/dev/xdma0_xvc` 也出现了** (厂商设计没有) ⇒ **U4b (JTAG over PCIe) 有了新可能**: XVC 支持已在驱动里
  (`cdev_xvc.c`), 只差一个**用户态 TCP 桥** (XVC 协议简单) 就能让 hw_server 经 PCIe 连 ⇒ 有机会省掉 USB 线。

**本轮踩的坑 (都是"判据/流程"而不是设计)**:
1. **`reg_rw` 不会因 SLVERR 报错**: XDMA 的 AXI-Lite 主机把错误响应的数据填成 **`0xffffffff`** 交回
   ⇒ 判"未实现地址"要看**读出值**, 不能 grep "error/fail"(初版判据因此假 FAIL; 修正后门 8/8 全过)。
2. **Vivado batch 出错不一定返回非零** ⇒ 构建的成功判据必须是**产物存在**(本目录的 bat 已改成
   `if not exist %BIT% ... exit /b 1`), 不能信 exit code。
3. **Tcl 的花括号串不能含不平衡括号** ⇒ 我最初把 .xci 校验写成 tcl 的 `regexp` 就报
   `missing close-brace`(且因此整个构建在综合前就退了) ⇒ **改成 bat 里跑 `check_xci.py`**。
4. **`IBUFDS_GTE4` 在 2025.2 的参数名是 `REFCLK_ICNTL_RX`(2 位), 不是 `REFCLK_ICNTL_TX`** ——
   凭记忆写会综合报错(`Synth 8-7136`)。**照例去本机 unisim 源核对**(`data/verilog/src/unisims/IBUFDS_GTE4.v`)。
5. (流程纪律) 一个会话里被"相对路径在错误的 cwd 下失效"咬了 **三次** ⇒ 复合命令一律先
   `cd /d <绝对路径>` 再干活。

## 2026-09-28 P6e 合体: 数据面 + 观测通道进同一个比特流 (RTL 与门先做完, 等构建)

**目标**: 把 `_proj_pcie/` 那套 (XDMA + 我们的寄存器块) 搬进 `board/wrapper_p4.v` 的
`PCIE_OBS` 分支 ⇒ 一个位流里同时有 1G 数据面和 PCIe 寄存器窗口。做法与读数见 `P6E_OBS.md`。

**结构**: 8 路 gmii 域计数 → `rtl/snap_cdc.v` (新增, 相干快照 CDC) → `axi_regs` 扩展的
快照窗口 (0x18 触发 / 0x1C 状态 / 0x20-0x3C 八个字) → `xdma_0`(user BAR) → 金手指 → 主机。

**本轮的技术判断 (值得记的)**:
1. **多比特跨时钟域必须"整束一次性锁存"**, 不能指望两级同步器: 各位到达时刻不同 ⇒ 读出位混的
   假值, 且症状像"数据面疯了"。`snap_cdc` 用 toggle 握手在 b 域锁存 `hold_b`。
2. **"快照"与"读"必须解耦**: 主机读 8 个字要走 8 笔独立 PCIe 事务 (几十 µs); 自动周期刷新
   必然让这 8 个字跨越两代 (撕裂发生在**寄存器文件**这一层, CDC 再相干也救不了) ⇒ 用**显式触发**
   (写 0x18), 触发后 8 字冻结到下一次触发 ⇒ 读窗口天然原子, 主机零状态。
3. **`done` 必须 sticky**: 否则"快照在第一次轮询之前就完成"会被漏看 (busy 只可能被漏看, done 不能)。

**本轮实测纠正的一条自己的错误判断 (重点)**:
`snap_cdc` 初版按"两个域各用各的复位会把握手永久卡死"来设计, 并把这条**写进了注释**。因为本工程
有"未实测的断言被打脸"的历史, 我专门写了负对照 (`sim/snapcdc/negctrl/`) 去证伪它 ——
**结果是不死锁**: 同步器把 toggle 当**电平**连续采样, b 域复位后会把"仍然是 1 的电平"重新识别成
一次沿 ⇒ 更新脉冲重新产生 ⇒ 握手自动补完。**推理错了, 是测量纠正的**。同源复位保留, 但理由改成
"复位释放后必然空闲/一致"这种确定性, 注释已按实测改写。
⇒ 这条的经验与工程坑 7/18 同源: **能把结论写成一句"必然"的时候, 先想办法花十分钟把它跑掉**。

**本轮新增的三道门 (全过)**:
- `sim/snapcdc/run_tb_snap_cdc.bat` — 相干性核心判据 = 请求**飞行途中**换掉整个 b 域位束,
  结果必须是"全旧"或"全新"; 扫 16 相位 (旧 13 / 新 3, 两侧都扫到 ⇒ 判据非空) + 一条
  **撕裂负对照** (只推一个字 ⇒ 检查器必须报混, 实测**恰好抓到 1 次** ⇒ 判别力被证明,
  并顺带证明锁存窗口恰好一个 b 沿宽); 另有 busy 语义/背靠背 8 次/飞行中复位/**b 时钟停摆后恢复**。
- `_proj_pcie/run_tb_axi_regs.bat` — 17 项 (快照窗口: 触发脉冲/别的地址不许触发/冻结/gen 恰好 +1/
  中途换代的 gen 守卫负对照)。⚠️ 原判据 9a 把 **0x18** 当"未实现地址", 0x18 现在变成 SNAP_CTRL ⇒
  **必须换地址**, 否则门会把"新功能上线"误报成回归。
- `sim/p6e_pcie/run_tb_p6e_pcie.bat` — ⭐ **真 wrapper 全链门** (工程坑 8: 每个 ifdef 配置都要有一个
  例化真 wrapper 的门)。手段: 用 `force` 把 7 路计数源打成**互不相同的常数**, 然后**从 AXI 侧**读回来
  逐字比对 ⇒ 任何"接错一路/接反"当场现形; `gmii_free` 那路故意不 force, 用"两次快照必须递增"验它。
  IP 的仿真模型只在 Vivado 工程里 ⇒ 写了替身 `xdma_0_sim_stub.v` (端口表从真 IP 的 `_stub.v` 抄,
  用**层次任务**给 TB 提供 AXI-Lite 主机 —— 比 force 十几根线干净)。

**本轮踩的坑**:
1. **Verilog-2001 不许对"部分选择的结果"再取位/再做部分选择**: `cap_dout[0*32 +: 32][23:0]` 非法,
   必须先落到变量; 同理**函数调用结果也不能直接做部分选择** (`make_bundle(g)[i*32 +: 32]` 非法)。
2. **尺寸字面量里不能放表达式**: `24'd(200+try*2)` 语法错 (`syntax error near '('`)。
3. **拼接位宽必须逐项核**: `{g[23:0], 8'd0, i[7:0]}` 是 40 位不是 32 位; `snap_src` 我第一版写成了
   **9 项** (要 8 项)。两处都由门的 `findstr 10-3091`/`-d` 预检抓出来。
4. **TB 里 task 的输出端口会覆盖调用处传进来的变量** —— 我一度用同一个变量既当"代际基线"又当
   `snap_take` 的输出 ⇒ 判据算术被悄悄改掉 (与"判据 4 用被循环重写的 k0 当基线"是同一类错)。
5. **`HW_STATUS` 拼接写 `26'd0` ⇒ 34 位进 32 位, 高 2 位被静默截掉**。低 32 位不变所以功能没错,
   但那是"靠截断碰巧对" ⇒ 已改成 `24'd0` 并注明字段位置 (`user_lnk_up` 在 **bit3**, 不是 bit0)。
6. **cmd 不展开通配符**: `xvlog ...\rtl\*.v` 会报 `Can not find file` ⇒ 文件清单改用 `dir /b /s` 生成 +
   `xvlog -f`; 并且**第一条 xvlog 也要带 `-work xil_defaultlib`**, 否则 xelab 找不到设计单元。
7. **未实现地址读回 `0xFFFFFFFF` 是 XDMA 主机填的, 不是 `axi_regs` 的行为** ⇒ 仿真替身不模仿那一段,
   所以"单元门验 rresp / 主机脚本验读数"两边各验一半, 别把结论张冠李戴。

## 2026-09-29 P6e 合体: 审查 agent + 对抗测试 agent 的结论 (snap_cdc)

**两份独立复核的结论**: `snap_cdc` 的**功能正确** —— 审查 agent 自建 5 个 TB (`sim/snapcdc/review/`,
TOR_PASS 46 项 / 往返 32-40ns); 对抗 agent 自建 5 个门 (`sim/snapcdc/atk/`, 40+ 次运行、
**5000+ 次快照捕获全相干**), 覆盖 b 慢 50 倍 / b 快 20 倍 / 非通约比 / 1ps 复位脉冲 / X 注入 /
通道偏斜 / 亚周期相位扫描 —— **一次都没破"NW 个字必须来自同一个 clk_b 沿"**。
两份都独立复测了"busy 比 valid 早落一拍" (对抗侧 306 次采样: busy 落下同拍 valid 已高 **0 次**)。

**但两侧都在"验证侧"抓到同一条真缺陷 (最有价值的产出)**:
**相干性判据对"不锁存直采"半盲**。把 `dout_a <= hold_b` 改成 `dout_a <= din_b`
(正是本模块存在的唯一理由要防的错), 原单元门**照样 PASS_ALL** —— 因为零延迟仿真里,
只要源在 negedge 整代原子写入、且两时钟通约 (如恰好 2:1), 直采拿到的永远是"相干的一代"。
**两个配置同时具备才可见: 非通约时钟 (打破沿对齐) + 通道间偏斜 (造出撕裂窗)。**
⇒ 判据 8 已按此重写 (源每拍都变 + 扫 clk_b 周期 9.1-12.0ns + 通道偏斜 0.15-1.2ns + 负对照 B),
实测: 真 RTL **0/200**, 直通模型 **12/200**, 把该变异体装回真门 ⇒ 判据 8a 报 12/200 并 FAIL
(`sim/snapcdc/mut2/run_mut2_no_latch.bat`, 期望 MUTANT-CAUGHT-OK)。
**教训 (可复用)**: "我把源写成原子的 + 时钟恰好通约" = 我的 TB 替被测模块**假定掉了**那个前提,
于是这条判据在我手里是空的; **负对照必须喂给另一个实现, 不能只喂给检查器** (判据 5 只练了
检查器, 所以它绿得毫无意义)。

**语义锐边 (已升级为硬契约, 写进 rtl/snap_cdc.v 头注释)**:
- `req_a` **必须是恰好 1 拍脉冲**。实现是组合的 `req_a && !busy_a` ⇒ 电平常高会**连续重触发**
  (对抗侧实测: 常高 200 拍 ⇒ 25 次请求/25 次 valid, 1:1)。单元门判据 3 (连发 3 拍只 1 次 valid)
  之所以过, 只是因为 **3 拍 < 往返 ~10 拍** —— 脉冲一旦宽过一个往返, 同一条判据就翻。
  真实调用方 (`axi_regs`: `snap_req = wr_go && w_word==6`) 天然 1 拍 ✓。
- 采样必须用 `valid_a` (busy 比 valid 早落 1 拍)。

**一条留给后续的空白 (对抗 agent 明确列出)**: `hold_b → dout_a` 这条**多比特异步采样**路径靠
**握手协议**保证稳定, 工具看不见它 —— ASYNC_REG 只打在三条同步器链上。⇒ 集成后必须**读 Vivado 的
CDC 报告**确认这条怎么报 (`board/run_p6e_verify.bat` 就是为这个加的: report_cdc +
report_clock_interaction + 时序/资源, 全只读)。

**方法论收获 (对抗 agent 自己踩的)**: 复位会污染任何"按边沿计数"的外部监视器 —— 被复位打断的
飞行请求会把 `toggle_a` 异步清 0, 这次**寄存器变化被数成一次请求翻转** ⇒ 假 FAIL (160 vs 319)。
修法 = 按**受理条件** (`req_p && !busy_p`) 计数; 改后逐数吻合: 受理 240 = 完成 160 + 打断 80。

## 2026-09-29 P6e 首次上板: user BAR 全回 0xffffffff —— 判据侧的两条教训

**现象**: 烧完 P6e 位流 (JTAG, `End of startup status: HIGH`), 未重启主机就跑验收 ⇒
**所有寄存器 (含 MAGIC) 都读回 0xffffffff**。

**教训 1: 0xffffffff 是"这次读没成功", 不是数据。** XDMA 的 AXI-Lite 主机把 SLVERR 的
响应数据填成 0xffffffff ⇒ 任何"按位判断"的判据都会**假通过**:
- 判据 2.1 (`done` 位 = `s & 2`) 在 `s = 0xffffffff` 时**恒真** ⇒ 通道全坏却报 PASS;
- "8 字冻结"也会因两次都读到同一个 ffffffff 而"通过"。
⇒ 验收脚本已加 **0.3 总闸**: MAGIC 读出 0xffffffff 就判"通道没应答"并**立刻退出**
(不让后面的判据在坏通道上产生假结论)。这与审查 agent 抓到的"判据 5 只练检查器没练 DUT"
是**同一类错**: 判据必须只有"真的通了"才成立。

**教训 2: `lspci` / config 空间读得出 → 不能当"设备活着"的证据。**
我一开始拿 `xxd /sys/.../config` 读出 `ee10 3490` + `current_link_speed 5.0 GT/s x4` 当作
"端点还活着, 不用重启" ⇒ **结论错了** (接着就发现 BAR 全 ffffffff)。
那些是**主机侧/可能被缓存**的状态; 唯一靠得住的是"**BAR 打得动**"。
⚠️ 本条修正了我在这一轮中途给出的建议 —— 记下来是因为它正是本工程反复强调的
"判据要选只有修复后才成立的量"。

**判别器 (已落成脚本 `_proj_pcie/p6e_precheck.sh`)**: XDMA 有**两个** BAR ——
`xdma0_control` (XDMA 自己) 与 `xdma0_user` (我们的)。读数组合能直接分开两种原因:
- 只有 user 坏 ⇒ **设计侧**没应答 (axi_aresetn 没释放/接线/地址), 重启救不了;
- **两个都坏** ⇒ 整个通路没起来 ⇒ **重启主机** (烧录在 POST 之后)。
实测 = 两个都 `0xffffffff` (`config` 也是) + dmesg 显示 boot 时 probe 正常
(`2 BARs: config 1, user 0`, BAR1 length=65536) ⇒ 判为"该重启"。

## 2026-09-29 P6a 板级正题收口: **真实 ping 通了** (KU5P, 零 IDELAY 前端 + 64bit 数据面)

**接线事实**: 板子 RJ45 接在 Linux 机 (192.168.0.38) **唯一那块 1G 网卡 `enp3s0` (RTL8111E)**
上; 该机的 SSH 走 WiFi `wlp6s0` ⇒ 给 `enp3s0` 加 `192.168.100.1/24` 不影响会话。

**结果**: `ping 192.168.100.2` ⇒ **5/5 通, rtt avg 0.128ms**;
数据面计数严格对账: **ΔW0=21 帧 / ΔW6=21 全进慢路径 / ΔW7=7 回发** (5 ICMP 应答 + ARP 应答)。
⇒ RGMII 前端 + 数据面 + HLS 慢路径在 KU5P 上端到端成立; **FCS 错帧恒 0** 证明零 IDELAY 配方正确。

**⚠️ 未结项 (记下来免得丢)**: 同一操作在 5 分钟前是 **100% 丢包** —— 当时 **ΔW6=8 (帧进了
慢路径) 但 ΔW7=0 (HLS 一个包没回)**, 中间无任何重建/复位就自愈。两种可能: ①配置后的热身;
②饥饿看门狗把卡住的 HLS 复位了。`p6e_capture.sh` 第 5 段 (10 轮 × 3 包) 专门测这条。
若确认间歇失效 ⇒ 把 `hls_rst_n`/`srx_dbg_starv`/`stx_stat_purge` 加进快照 (NW 扩到 16) 再上板。

**本轮判据侧的教训 (又一次)**: `p6e_capture.sh` 里我用
`ip -s link show | awk '/RX:/{r=$2}'` 取计数 ⇒ **匹配到表头行** "RX: bytes packets..." ⇒ `$2` = 字面量
"bytes" ⇒ 算术展开在 `set -u` 下炸掉 (`unbound variable`), **后面的对账与抓包全部丢失**。
⇒ 计数一律从 `/sys/class/net/$IFACE/statistics/*` 取 (稳、无解析)。这与"判据里用被重写的基线"
是同一类错: **取值方式本身要有唯一确定的结果**。

## 2026-09-29 P6a 图案/吞吐收口: **931 Mbps = 1G 线速** (KU5P, UDP 图案通路)

从直连板子的 Linux 网卡发一个**图案正确的教学包**到 `192.168.100.2:8081` 教会板子 peer
(learn-on-RX) ⇒ 板子立即全速发图案帧 (`TX_GAP=0`, `i_paylen=1472`)。

| 判据 | 读数 |
|---|---|
| 板子自报图案 TX (`W9`) | **931–932 Mbps** (79,069~79,229 帧/s × 1472B) |
| 理论天花板 (1472B 载荷 / +66B 开销 @1000Mbps) | 957 Mbps ⇒ **实测 = 97.4% 线速** |
| 独立复核: 网卡硬件计数 | 78,917 帧/s ⇒ 与板子自报吻合 **0.2%** |
| 逐字节图案 | 收到的帧**全部**等于 xorshift64 流连续前缀 (C++ 对端, 含掉包重对齐) |
| 板子自己的 RX 校验器 | **RX 侧单帧 100 B 校验通过** (`W13 失配 = 0`; 我的教学包被它按图案**验证通过**, `W10 收帧=1`) —— ⚠️ **只覆盖这 100 B**；"失配恒 0"是过度声称（`P7B_W13_AUDIT.md` §②-V13） |
| `gmii_free` 反解 | 124.5 / 125.4 / 125.6 MHz (三次一致) |

**本轮踩的坑 (全是"判据口径"类, 不是设计缺陷)**:
1. ⭐ **别拿用户态 socket 的收包数当"板子能跑多快"** —— ~80k pps 下内核缓冲必然溢出:
   我测到 6.4 Mbps / 50% 丢包, 而同时**板子自报 931 Mbps、网卡硬件计数 78,917 帧/s**。
   判速率只有两个靠得住的口径: **板子自报计数** 或 **网卡 `/sys/.../statistics` 硬件计数**。
   我一度据此推断"背靠背两帧缺 IFG" ⇒ **查 `mac_tx_64` FSM 后自己否掉** (`S_IFG` 只有数满
   12 拍一条出口; 而且网卡 99.8% 收全了)。这是"工具余量"坑的又一次现身。
2. **快照寄存器是"冻结到下次触发"** —— 采样脚本**每次读之前都要写 0x18=1**, 否则两次相减恒 0
   (我的速率脚本第一版就是这么骗过自己的)。
3. **计数器 32 位会回绕** —— 931 Mbps 下 `W9` 每 ~37s 绕一圈, 裸减法会打印负速率
   (脚本里出现过 `-10520 Mbps`) ⇒ 一律先取模 2^32。
4. **`W14/W15` 是 `tcp_tx_frame`(TCP fast path) 的计数, 不是 MAC** —— `mac_tx_64.stat_frames`
   在本 wrapper 里**悬空**; 图案走 UDP ⇒ 它们正确读 0。**这种错标签最危险**("MAC 发=0
   却明明在线速跑"); 标签与文档已改。真 MAC 计数接出来是一行改动 (未做, 不需要)。
5. (诚信更正) 提交 `d055c0b` 的说明里描述了标签修正, 但**那些改动没被 staged** ——
   已在 `e5d52ed` 补齐并注明。**commit message 与内容不一致就是问题, 不留着。**

**工具** (都在 `_proj_pcie/`, 对端机 `/home/a/xdma_test/`):
`p6e_udp_pattern.py`(功能) / `p6e_udp_pattern.cpp`(吞吐, 已编译) / `p6e_rate.sh`(板子自报速率,
含上面 3 个坑的注释) / `p6e_snap_check.sh`(16 字验收) / `p6e_watch.sh` / `p6e_capture.sh`(抓包对账)。
**除读寄存器外, 图案测试全程不需要 root。**

**开着的两笔账**: ① 早先那次 ping 失败 (IP 在位、7 分钟后自愈) 机理未查明;
② 若要 MAC 级 TX 计数, 把 `mac_tx_64.stat_frames` 从悬空接出来 (一行 + 重建)。

## 2026-09-29 "慢路径失聪"调查: 两个 agent 的结论 + 时间线实测 (现象已复现)

**现象 (实测复现, 不是偶发)**: 配置+重启后, 慢路径**先正常应答 ARP/ping (~20s), 然后失聪 9 分钟以上**
—— 板子还在发周期帧 (`W7` 每 ~40s +1), 但主机 ARP 解析不到它 ⇒ ping 全 0。
`p6e_boot_timeline.sh` 的 26 轮时间线: 第 1 轮 (t=1s) **2/2 通**, 第 2 轮 (t=23s) 起**全 0/2**, W7 一路缓涨。
⇒ **是板内状态变化**, 不是操作失误 (第 1 轮通就排除了地址/路由问题)。

**两条被 agent 纠正的、我自己写错的理解 (重要)**:
1. **`W6` 不能证明 "HLS 收到了"** —— `srx_stat_commit` 在**适配器输入侧**帧尾自增
   (`rtl/slow_rx_adp.v:195`), 与 HLS 有没有读走无关; 它只说明"排进了给 HLS 的缓冲"。
2. **`W7` 也不等于 "HLS 产出了帧并且上了线"** —— 它在 `slow_tx_adp` 把整帧写进**自己的 wf frame_fifo**
   时自增 (`rtl/slow_tx_adp.v:153`), 而 wf 满时同一条路会走 `stat_purge++` 的整帧回卷分支
   ⇒ `W7` 冻结**既代表"没产生"也可能代表"产生了被回卷"**。
⇒ 我先前"帧进了慢路径但 HLS 没回"的证据强度下调; 要分开这些情况**必须**补 `stx_stat_purge`/`srx_stat_drop`。

**一处实测出来的潜伏 bug (观测审计 agent 用 xsim 测的, 不是推理)**:
`_proj_pcie/rtl/axi_regs.v` 的 `wire [8:0] snap_base = {snap_idx, 5'b0};` —— `{5,5}=10 位赋给 9 位`,
**最高位被静默截掉**: NW=24 时 `0x60..0x7C` 这 8 个字会**读回 W0..W7 的值**; NW=32 时 16 个错;
改 `[9:0]` ⇒ 0 错。**xvlog 完全沉默** (lint 日志 `10-3091` 计数 0) ⇒ 只有单元门能抓,
且门自己也得扩到同样字数 (16 字版当年就是漏了这层才让它潜伏)。
⇒ 扩窗第一步必须是这一行; 这条已写进下一版的施工单。

**另一条时间线吻合的线索**: HLS 的定时器是**按 pass 计数**而不是按周期 (`layer_dhcp.cpp:205` 等),
按实测 RTT 反推 pass ≈ 45-100 周期 ⇒ 文档里"HELLO ~5s"实际是**分钟级**; `dhcp_delay` ≈ 40-80s。
而 **DHCP 的 RX 路径是死代码** (`layer_udp.cpp:53` 只在 `dst_port==8080` 时置 valid, DHCP 用 68
⇒ 永远进不去) ⇒ 板子**必然**在 T+约 1 分钟进 `DHCP_FAILED`。
⇒ 与时间线上"t=23s 起失聪"在量级上吻合 ⇒ **"DHCP 失败 → 慢路径不再应答"是当前最值得证伪的机理**。

**顺带查到的其它账 (都不阻塞, 单独记)**:
- `slow_rx_adp.dbg_hls_rst` 悬空但 == `hls_rst_n`, **不丢信息**, 不用管;
- `hls_rst_n` 低电平只持续 **64 gmii 拍 = 512ns** (`slow_rx_adp.v:119`) ⇒ 把它当一个位放进快照
  **采样命中率 ~1%, 读回 0 不能证明"没发生"** ⇒ 短事件必须做成**计数器** (这是本轮方法论要点);
- HLS 自己的统计文本 (`msg_stream`, 含 `RX/TX/A/I` 计数) 被 wrapper `tready=1'b1` **直接丢掉**
  (`wrapper_p4.v:1778`) ⇒ 一条现成、零重综合的观测通道被浪费;
- `mac_tx_64.stat_frames/stat_abort` 悬空 ⇒ **全设计没有"线上实际发出帧数"这个锚点**;
- `axi_regs.wr_count`/`decode_err` 算了但**不在读 mux 里** ⇒ 主机读不到;
- `ping -s >248` 会越界写 HLS 的 `uint8_t csum_buf[256]` (`layer_icmp.cpp:104`) ⇒ **测试别用大 ping**;
- `DHCP`/`ICMP` 两个按收到长度驱动的循环有越界风险 (`layer_dhcp.cpp:125-139`: `msg_bytes` 最大 65535
  而 `frame_buf` 只有 400 词)。

## 2026-09-29 24 字扩窗上板验证 + 一个必须记住的工具坑

**① 24 字扩窗在板上通过** (`BUILD_ID=0x00000004` ✓ 前置闸): 三个门 + lint 在仿真侧全过;
板上实测新字全部工作 —— `W16`(srx_hls_bytes, HLS 真读走的字节) 稳定增长 / `W17`(hr_cnt 看门狗拍) = **0**
/ `W20`(mac_tx_frames) 与 `W7`(stx_stat_frames) **逐帧一致** (慢路径产出的每一帧都上了 MAC ✓) /
`W18`/`W19` = 0 / `snap` 每轮成功。峰值读数示例: 20 个 ping ⇒ `W0` 精确 +20 ✓、`W16` +2424 B ✓。

**② "慢路径失聪"在这轮 33 分钟里没有复现**: 探针每轮 `ping -c 20 -i 0.05` **全部 20/20** ✓
(ping 不经寄存器通道 ⇒ 这份数据有效)。而上一版 (`BUILD_ID=3`) 是配置后 **t=23s 就聋**、
持续 9 分钟以上 ⇒ **该现象不是"每次配置后必然发生"**, 而是**条件性/间歇性**的。
⇒ 下次再遇到时, 探针要连着跑并**同时记录当时有没有别的流量**(尤其图案 app 的 peer 是否已被教过)。

**③ ⚠️ 工具坑 —— 但真凶不是当初猜的那个 (本节按实测更正, 留档以免重犯)**

现象: 长跑探针从第 2 轮起, `W0/W6/W7/W16/W20` **全部冻结** (或读成 0), 而数据面活得好好的
(ping 每轮 20/20 ✓)。

**❌ 我最初的归因是错的**: 我写成"观测通道的触发+读不是多写者安全的 (`done` sticky ⇒ 并发读者
互相污染)" —— **实测否掉了**: 单写者跑同样冻结 (单写者 3 轮里第 1 轮正常、后两轮全 INVALID)。

**✅ 真凶: 我自己脚本里的变量名撞车。** 探针里 `T` 本来是**工具目录** (`$T/reg_rw`), 而我在循环里
又写了 `T=$(( $(date +%s) - T0 ))` 把"已跑秒数"赋给它 ⇒ 第 2 轮起 `$T/reg_rw` 变成 **`1/reg_rw`**
⇒ `reg_rw` 不存在 ⇒ **所有读静默失败** ⇒ 空读被 `$(( ))` 当成 **0** ⇒ 表里就是"计数冻结/变 0"。
`bash` 只把它当"命令找不到"打到 stderr (被 `2>/dev/null` 吞了), **读数里完全看不出来**。
修法: 工具目录改名 `TOOLS`, 秒数改名 `TS` (现已在脚本注释里写明"别用 T")。

**本轮真正学到的一条 (才值得记)**: 我给探针加的 **"gen 必须恰好 +1" 自证守卫逮到了它** ——
`snap()` 先记 `SNAP_STATUS.gen`, 触发后要求 gen 恰好 +1 才接受本轮, 否则整行标 INVALID。
没有这道守卫, 这种"读失败伪装成 0"的错会一路静默地伪造结论 (本工程的"空读=0 不可区分"老坑
又现身一次, 只是这次藏得更深)。
⇒ **纪律**: 读数类脚本必须 (a) `rd()` 判空返回非零, (b) 每轮读 `MAGIC` 自检, (c) 用 gen 自证
"这一轮确实是本进程触发的"; (d) 变量名不要用 `T` 这种会和常见局部量撞车的短名。

### 2026-09-29 "失聪"追踪小结 (仪器修好后的两轮长跑)

| 运行 | 流量 | 时长 | 结果 |
|---|---|---|---|
| 探针 A (修好后) | `ping -c 20 -i 0.05` / 15s | 25 min | **100/100 轮 20/20**; W17 恒 0; W20≡W7; 零 INVALID |
| 探针 B (轻流量) | `ping -c 2` / 20s | (跑到 7.4 min 时仍全 2/2, 继续) | 同上, 健康 |

⇒ 累计 **~65 分钟 / 约 2500 个 ping 一次没丢**。而最初那两次失聪 (均在 `BUILD_ID=3` / 16 字版) 是
**配置后 t≈20s 起聋、持续 9 分钟以上**。**现象是罕见/条件性的, 且现有仪器没能复现**。
已排除的猜测: ①并发读者污染 (实测否掉, 真凶是我的 `$T` 撞车) ②轻流量触发 (轻流量版健康)。
**留下的姿态**: 仪器已就位 (W16 HLS 吃字节 / W17 看门狗拍 / W18 回卷 / W19 适配器丢 + 失聪自动抓包),
再出现就能一次说清; 不阻塞主线 (P6b)。

**另一条闭合**: 默认构建 **P4 回归矩阵 16 门全过 (rc=0)** —— 本轮全部改动 (24 字扩窗 + 门调整 +
文档) 未破坏默认构建 (审查 agent 留的"没跑 P4 矩阵"这条未核实项就此闭合)。
⚠️ **这条后来被勘误了**：那次"16 门全过"的物证躺在 **ECO 仓**里（跑的是另一个 checkout）——
见下面 2026-09-29 P6b 收口 一节的 **⑥ 勘误**。

---

## 2026-09-29 P6b 收口: 数据面 125MHz → **156.25MHz** (双时钟域 + 手写异步 FIFO) — 板级正式验收 35/35 + 四个缺陷修复 + 一个"空门"元问题

> **归档索引**（本节是里程碑日志；判据的逐条推导与复现步骤在别的文件，别在这里找）：
> `P6B_SUMMARY.md`（一页式总览）· `P6B_SPEC.md`（施工规格 + 勘误节）· `P6B_ACCEPT.md`（**板级验收原始记录**）·
> `P6B_CDC_AUDIT.md`（跨域审计 + F-1/F-2/F-3）· `P6B_REVIEW.md`（对抗审查 F1–F13 + 附录 R 的 F4 复核）·
> `P6B_INTEGRATION_REVIEW.md`（集成与"空门"核实）· `P6E_OBS.md`（**36 字寄存器表**，现役）·
> `sim/p4gates/evidence/`（P4 硬化与负对照的全部原始读数）· `p6b_accept_final/`（验收归档物）。

### ① 目标与最终形状

`P6B_SPEC` 的边界裁决 = **方案 A**：**前端留 125MHz、数据面整体搬 156.25MHz**，两者之间只留
**两个异步边界**（RX 一个 / TX 一个），用**新写的手写异步 FIFO** `rtl/fifo_async.v`（灰码指针 + 两级同步，
DEPTH=256 / FWFT=1）跨域；时钟由 `rtl/clk_gen_p6b.v` 从核心板 **Y1 100MHz** 经 MMCM ×1.5625 产生
（**不是**从 PHY 的 RXC 倍频 —— 那条路的结构性否决见 `P6B_SPEC §2.1`）。两束快照用 `rtl/snap_seq.v` 做
**链式触发**（FE 先 → DP 后）以保住跨域判据的**方向性**。

**结果**：`board/build_p6b_final_ku5p.tcl` 产出的位流在板上跑通 —— 1G 图案通路 **956.0 Mbps**
（= 1G 线速上限 957.1 的 **99.9%**），数据面实测 **156.2585 MHz** 与前端 **125.0061 MHz** 双域并存。

### ② 板级验收读数（**正式验收 35 条判据全 PASS**；原件 = `P6B_ACCEPT.md`）

| 项 | 读数 | 出处 |
|---|---|---|
| 位流 | `sha256 = c17700868b08170865f4a4ae0292ebb636aed03070e2875f6dbb005123a948ca`（`BUILD_ID=6`） | `P6B_ACCEPT.md` §1.1 |
| 时序 | `WNS +0.168 / WHS +0.010 / WPWS 0.000`，**0 失败端点** | 同上 §1.2 |
| 数据面频率 | **156.2585 MHz**（`W24` / 真实墙钟，12.188566 s 窗口） | 同上 B2b |
| 前端对照 | **125.0061 MHz**（`W5`，**同一窗口** ⇒ 两域确实不同频） | 同上 B3 |
| 图案速率 | **956.0 Mbps**；网卡硬件计数独立复核 **956.3**（偏差 0.03%）；tcpdump 离线**逐字节** 1999/1999 | 同上 D1/D2/D3 |
| ping | 5/5（rtt avg 0.091 ms）· 20/20（`-i 0.05`） | 同上 C1/C2 |
| 守恒律（停机态） | `W30 == W0 + W32`（147==147）· `W31 == W1 − 4·W0 + W33`（21235==21235） | 同上 E1a/E1b/E8 |
| 验收总计 | **42 条 PASS 记录 / 0 FAIL / 0 SKIP / 0 NOTE** | 同上 §0 |

⚠️ **引用冒烟轮的数字必须注明位流**：冒烟轮（11:14–11:25）烧的是 **`03f9c6d0…fe5a0d`（过期位流，
不含 F-1/F-2 修复）** ⇒ 它的"逐字节判据 FAIL"是**工具天花板**（C++/socket 口径只交付 3858/855,930 帧），
不是板子缺陷；正式验收换用 **tcpdump + 离线代数**这条独立路径才判得了。两个位流的 sha256 对照表
在 `P6B_ACCEPT.md` §1.1，**别把两轮的读数混着引**。

### ③ 本轮修的四个缺陷（**其中两个早于 P6b 就存在**）+ 一个修复自身引入的缺陷

| # | 一句话根因 | 修法 | 判据归属（**哪个读数是它的牙**） |
|---|---|---|---|
| **F4(a)**（🔴 高，**P6b 前就有**）| `mac_rx_64` 的丢帧分支在**已经 push 过字之后**才丢 ⇒ 流里留下**孤儿字**（有 `popc`、无 TLAST）⇒ `W31` 永久多算、下游只能靠"下一个 SOP"兜底重同步 | 新增 **TERM 收尾字**（`tdata=0, tkeep=8'h00, tlast=1, tuser=0, tcrs=0, terr=1`）+ `term_pend` 优先门 ⇒ 每个 SOP 与下一个 SOP 之间**恰一个** TLAST | **W32/W33/W34**（新计数器）+ 结构式 `W30==W0+W32` / `W31==W1−4·W0+W33`（`rtl/mac_rx_64.v:50` 明文）；E7/E8d 全 0 |
| **F4(b)**（🔴 高，**P6b 前就有**，更严重）| 帧尾那一拍的 `push` 决策用的是**寄存器化的 `full`**（FIFO 7/8，判得"对"）⇒ `stat_frames`/`stat_bytes` **谎报成功**；而**同一拍**完成字的 push 把 `wptr` 推到满，**下一拍** `fifo_sync` 的 `wr && !full` 判假 ⇒ **TLAST 字被静默丢弃**（`fifo_sync` 无溢出保护）| 空间门一律换成 `fifo_sync.full_next`（**下一拍满的精确预测**，含在飞写与本拍读）：`push_ok = !full_next`；并给 `fifo_sync` 加 `ovf_pulse` 自检回读 | **W35**（`rx_stat_fifo_ovf`，**结构上恒 0**，非 0 = 修复失效）+ 逐拍轨迹（`P6B_REVIEW.md` §3.4）；`sim/f4sim/` 的门 + `tb/tb_mac_rx_f4.v` |
| **F4-2**（🟠，**修 F4 时自己引入的**，被对抗复核抓到）| `hwv && !push_ok` 时**无条件**进 `S_TERM`，而 `term_pend` 只在 `first_done` 时置 ⇒ **`term_pend==0` 空入 `S_TERM`** ⇒ 下一个（空间充足、完全正常的）帧被吞掉并计成丢帧 | **一行**：`state <= first_done ? S_TERM : S_IDLE;`（`rtl/mac_rx_64.v:250-261`）| `P6B_REVIEW.md` **附录 R.4** 的 A/B（同一激励、同一 tready 表）：修复前 `frames=1 drop=2` → 修复后 `frames=2 drop=1`（**白丢的那一帧回来了**）。⚠️ **原门永远测不到它**：`tools/gen_f4_stim.py` 的帧尺寸最小 = 60 ⇒ 该分支覆盖率 0（**"同一个 agent 写门又写修复"的缺口，只能靠独立复核补**）|
| **F-2**（🟠 中，**P6b 前就有**）| `mac_tx_64` 帧内中止（源断供）后**残字被当成新帧的开头发出去** ⇒ 线上出现一个 **FCS 完全正确的"幽灵帧"**，载荷是被中止帧的**中段残字**（对端无法分辨）| 新增 **`S_FLUSH`** 状态（唯一入口 = `S_DATA` 的 `!fempty` 中止分支）：中止后**一个字都不发**，逐字弹掉输入 FIFO 直到吞掉**本帧自己的 TLAST**，再等够 IFG 12 字节才回 `S_IDLE`；新增 `stat_flush_words/stat_flush_done`。**时序要点**：判据必须是 `frd && !fempty && fdout[0]`（本拍真弹且弹的就是 TLAST），用"上一拍看到的 tlast"会多弹一个字 | `audit_scratch/t3_txcdc/`：**幽灵帧 0**（撤回修复 ⇒ **FAIL**）；**无中止路径指纹逐位不变**（`33f82978` 修前/修后相同 + flush 计数器为 0 = 冲刷从未运行的正证据）；E3 的 `W20−W7 ∈{0,1}` **且** `W21==0` |
| **F-1**（🟠 中，P6b 期新写模块的契约漏洞）| `fifo_async` 的 `full` 在**写域复位释放窗口**里读 0（复位值），而此时的 `wr_en` 被**静默丢弃**（无写入、无计数、无探针）⇒ `!full` 这个唯一闸门在此期间不可信；`fifo_sync` 有 `ovf_pulse` 自检，`fifo_async` **什么都没有** | 新增 **`ovf_pulse` + `ovf_cnt`** 端口（与 `fifo_sync` 的 `ovf_pulse` **同形同义**）：**拒写不再静默**，`ovf_cnt` 恒 0 才叫"无丢字" | `sim/fifoasync/run_all.bat` 的 **12 个基础门 + 7 个变异**；关键负对照 `run_mut_noovf.bat`（把 `ovf_pulse` 钉 0 = **撤回 F-1 修复**）实测 **FAIL（3 条判据不成立）**；`audit_scratch/t4_reset/` 的实测 `model_acc=3999 vs dut_acc=3996`（3 字静默丢弃）|

⚠️ **F-1 / F-2 的板级缺口都没有闭环**（**必须记，否则后人会以为它们已经可观测**）：`rtl/fifo_async.v` 有了探针，
但 `board/wrapper_p4.v` 的两个例化 `.ovf_cnt()` **悬空**、快照字里**没有**对应字 ⇒ 板上仍**无法归因 CDC
FIFO 自身的丢字**。板上的 `W35` 是 `mac_rx_64` **内部那个 8 深 `fifo_sync`** 的拒写数，**是另一个 FIFO**。
⚠️ **同族缺口（F-2，2026-09-29 复核补记）**：`mac_tx_64` 的 **`stat_flush_words` / `stat_flush_done`**
（声明在 `rtl/mac_tx_64.v:48-49`）在 `board/wrapper_p4.v` 里**未连接**（该文件内这两个名字**零出现**，
全仓 grep 证实），36 字快照窗口里也**没有**对应字 ⇒ **F-2 修复在板级不可观测**：
它只在仿真 TB 里被接过并判过（`audit_scratch/t3_txcdc/tb_tx_cdc_chain.v:109-110`、
`p6b_final_verify/t3_f2/tb_tx_cdc_chain.v:109-110`），**板级从未观测过**（唯一痕迹是 xelab 的
`VRFC 10-3645` 未连接告警）。含义：**F-2 是"仿真里验过的修复"，不是"板上验过的修复"。**
**F-1 当前也不是活缺陷**（可达性论证：RX 侧最早 push 在复位释放后 ≥19 个 gmii 拍；TX 侧功能逻辑的释放
含 `~locked` ⇒ 恒不早于 FIFO 写域释放），但它把"不丢字"押在一个**隐含时序假设**上。

**F4/F4-2 的连带修正（"把缺陷当金标准"）**：`tools/gen_stim_tx.py` 的参考模型**把 F-2 缺陷写进了期望**
（"残余 2 词开新帧"）⇒ `abort` 模式的门在修复后反而变红。已按 `S_FLUSH` 同形更新（现 `md5 b4ee17da…`，
旧版留档 `audit_scratch/tools_orig/`）；`main` 模式**逐字节不变**（改前/改后模型相同 = 无扰动证据）。
⚠️ 同类地雷（**未改，已报备**）：`sim/run_tb_tx.bat` 里仍写着 `cd /d D:\repo\ECO\udp_hls_10g\sim`
（**另一个 checkout**）—— `audit_scratch/regress_mactx.py` 用自定位路径绕过了它。

### ④ F-3：**已知限制，未修**（触发条件 / 后果 / 为什么三种接线都无解）

**现象**：两个 CDC FIFO 的复位**只接板级 `reset_n`**，而数据面功能逻辑接 `dp_rst_n`
（`clk_gen_p6b` 产生，**`locked` 参与**：`rst_async = (~locked_raw) | rst_ext`）⇒ **MMCM 失锁/重锁**时
DP 功能逻辑重启，而 FIFO 的**指针与内容保留** ⇒ DP 侧会在**帧中**重启。

**实测（`audit_scratch/t9_f3restart/`，三种接线都跑了，不是推断）**：

| 变体 | 重启后首个交付帧 | `stale_words` | 带 `tcrs=1` 的截断帧 | 契约 |
|---|---|---|---|---|
| A 现行（两侧都只接 `reset_n`） | 40B **片段**（帧3 偏移24） | 0 | **1** | 合规 |
| B 只复位读侧（= 规格书的**字面建议**） | 帧0 完整 ⇒ **帧0/1/2 被重复投递** | **26** | 0 | **违反硬契约** |
| C 两侧同源同拍复位（FIFO 清空） | 48B **片段**（帧3 偏移16） | 0 | **1** | 合规 |

⇒ **结论**：① **三种接线都会让 DP 在重启后交付一个"帧中截断的片段，且携带原帧 `tcrs=1`"**
（= 截断帧被当 FCS 有效帧交付）—— **F-3 的危害在接线层面无解**；② **字面建议（只把读侧接 `dp_rst_n`）
必须不做**（实测把**已被消费的整帧重新投递**）；③ 变体 C 另外观测到 FE 侧 8 帧丢弃 + DP 只消费 9 字
（机制 = 复位窗口内 FIFO 写侧 `full_r=1` ⇒ `m_tready=0` ⇒ FE 内部 8 深 FIFO 填满 ⇒ `mac_rx` 按既有语义
**整帧丢并计数** ⇒ 是**设计内的背压丢帧路径**，有计数、可归因，**不是** F-1 同类的新漏洞）。
**根因** = **DP 侧没有"以 SOP 为界"的重启重同步**（FIFO 无法提供帧对齐信息）。
**后果有界**：**丢/重一帧**（不会持续坏下去）；进不了 fast 路（`rx_classify` 完全不用 `tuser`，片段起点
是帧中 ⇒ ethertype 是垃圾 ⇒ 一律走慢路径）⇒ 危害是"**坏帧带 `tcrs=1`，FCS 保护在 MAC 边界被击穿**，
靠下游解析器兜底"，**不是**"垃圾载荷进数据面"。
**真正的收口方向**（超出当时授权，**建议单列任务**）：(i) 让 DP 侧重启后**等 `tuser` 才开帧**
（`vlan_strip`/`rx_classify` 加入口门控）；(ii) 把 `mac_rx_64` 也纳入"同源同拍复位"。
**本轮未改 `board/wrapper_p4.v`**（保持 `03e76507605f88acf2847dc5101eca14` 不变）。

### ⑤ 元问题：全仓 **243 个"真空门"**（跑起来测的是**另一个 checkout**）

**发现**：全仓 **364 个代码文件**的**活行**里含指向 `D:/repo/ECO/udp_hls_10g` 的绝对路径；
其中 **243 个是"真空门"**（`empty gate` 类：**跑起来编译的是另一个 checkout 的源码、
日志写进另一个 checkout 的仓、然后 exit 0**）。本仓是 2026-09-28 从 `D:\repo\ECO\udp_hls_10g`
整体拷贝来的，**拷贝之后**这些硬编码路径就全变成了空门。

**修**：**340 个已修 / 1 个只留注释（历史）/ 23 个未修**（23 个全是 Python（手工）与 1 个 `.ps1`，
逐条清单在 `sim/p4gates/evidence/inventory_eco_class.txt`，**没修的原因与位置都写在那张表里**；
机器可读的扫描结果 = `sweep_summary.txt` / `sweep_code_files.txt` / `sweep_absolute_paths.txt`）。

**守卫三层（+一层事后扫描），全部装在 `sim/p4gates/` 的自定位工具链上**：

| # | 守卫 | 位置 | 挡什么 |
|---|---|---|---|
| 1 | **根守卫** `guard` | `sim/p4gates/p4env.bat`（`REPO_ROOT` 由**脚本自身位置**推导 `%~dp0..\..`）| 配置的根**不含本 checkout** ⇒ 拒绝运行（`REQUIRED_MARKERS` 逐项列出缺哪个文件）|
| 2 | **路径边界** `checkpaths` | 每个门 `xvlog` **之前**的 PROLOGUE | 任何路径/manifest 条目**解析到根之外**或不存在 ⇒ 拒绝（外来路径永远编不进去）|
| 3 | **绊线** `selfcheck`（**243 个**） | 各门 `.bat` 头部 | 该 `.bat` 的**活行**若指向仓外 ⇒ **拒绝运行** |
| 4 | **事后扫描** `scanlog` | 每个门跑完之后 | 编译/仿真日志里出现根外绝对路径 ⇒ 硬失败（防"溜过前置检查"）|
| — | **修订指纹** `fingerprint` | 跑前 + 跑后各一次 | 235 个文件（编译集 + 生成器 + bats）**逐字节**比对；跑期间源码被改动 ⇒ `REVISION DRIFT` 并**作废整轮** |

**负对照（证明守卫有牙 —— 这也是 ⑨-3 那条教训的来源）**：`sim/p4gates/evidence/negctl/` 里放了
**外仓替身夹具**（`foreign` = 把工具链复制一份、其中某个门**故意重新硬编码** ECO 路径；`notarepo` = 只做根目录）。
原始读数：`negctl_A_raw.txt` 的 **A1**（根配成 `D:\repo\ECO\udp_hls_10g`）⇒
`[P4GUARD FAIL] REFUSING ... 'empty gate' mode`，`RC=1`；**A2**（根配成父目录 `D:\repo\XCKU5PMini`）⇒
列出 7 个缺失 marker 后 FAIL；**B**（门自己重新硬编码）⇒ 被拦下，`EXIT=97`。
⇒ **不装守卫的话这些都会 exit 0**。

### ⑥ 勘误：提交 **`a31c86b`** 的"P4 默认构建矩阵 16 门全过"**实际跑在 ECO 树上**

- 那次"16 门全过"的**物证躺在另一个仓**：ECO 的 `sim/p4sim/matrix_p4dfix.log`
  `start Tue Sep 29 03:58:35` / `MATRIX DONE Tue Sep 29 04:23:11`（mtime 09-29 04:23），
  而提交 `a31c86b` 的时间是 09-29 04:27。
- 那时 ECO 树 = **干净工作区 @ `a719030`**（本仓 HEAD 的第 27 代祖先），且其中
  **`rtl/frame_fifo.v` 比本仓还旧一版**；**真正需要回归的 4 个文件**（`rtl/fifo_sync.v` /
  `rtl/mac_rx_64.v` / `rtl/slow_rx_adp.v` / `rtl/tcp_tx_frame.v`，都是当时本仓工作区的未提交改动）
  **根本没进那次运行**（逐文件用 git blob 比对：P4 各门编译的 23 个源文件里 22 个相同、1 个不同；
  HLS 输出目录 176/176 相同 —— 细节见 `P6B_INTEGRATION_REVIEW.md` §5.1）。
- ⇒ **这一次的"16 门全过"是空门**，**不能**作为"P4 默认构建没被碰过"的证据。
- ✅ **历史（P6b 之前）的 P4 矩阵证据不受影响**：拷贝之前 ECO 就是当时的开发树，那时它不是空门。
  受影响的**只有"拷贝之后仍然引用这条命令"的说法** ⇒ 就是 `a31c86b`，以及本仓里那份
  **看起来是证据、实际是 09-27 陈旧数据**的 `sim/p4sim/matrix_p4dfix.log`（**更毒**：谁去读它，
  读到的是别的仓两天前的读数）。

### ⑦ 本仓 P4 矩阵的**当前**状态（诚实版，**含一条在飞的实验**）

| 时间 | 事件 | 读数 / 判定 |
|---|---|---|
| 11:46 | 硬化后的矩阵**首次全跑**（本仓根） | ⚠️ `vlanburst EXIT=1` / `stallgate EXIT=1` **且** `[P4GUARD FAIL] REVISION DRIFT: sources changed while the matrix ran` ⇒ **整轮作废**（不是"两个门坏了"）。见 `evidence/matrix_full_run_console.txt` |
| 11:59 / 12:01 | 两个可疑门**单独重跑** | `canonical_vlanburst.txt` = `BURST OK` / `VLANBURST_RC=0`；`canonical_stallgate.txt` = `PCSTALL OK` / `STALLGATE_RC=0` ⇒ **那两个 EXIT=1 是并发产物**（编辑与运行重叠）。另有 `rerun_two_gates_isolated.txt` / `rerun_stallgate_isolated.txt` |
| 12:07 | 再跑一轮 | ✅ **`matrix_freeze_verdict.txt`：`VERDICT: FROZEN`** —— 235 个被哈希的文件在跑前/跑后**逐字节相同**，日志绑定到修订 `DIGEST_ALL(content)=921d62d9…`（`DIGEST_COMPILE=9e58dc58…` / `FILES=201`）⇒ **"修订绑定"这条结构性缺口已闭合** |
| **13:21–** | **"无并发"复跑（正在跑）** | ⏳ **另一 agent 在飞行中**（`sim/p4gates/work_20260929_132056/`，目的是判定"并发是否曾影响结果"）⇒ **本文件不替它下结论** |

⚠️ **"跑门 ≠ 判门"（本轮最便宜的一条教训）**：矩阵 16 门里有 **2 门
（`unit_retx` / `unit_fifo`）无条件 `exit 0`**（它们的 `.bat` 以 `type xsim*.log` 结尾）
⇒ **"16 门 EXIT=0"并不等于"16 条判据被判定过"**，这两个门必须**读控制台尾部**才算判过。
`sim/p4gates/run_matrix_p4dfix.bat:104-105` 的头注释已经把这条写在脸上，
但**任何自动化汇总都必须显式处理它**，否则会得到"全绿"的假象。

### ⑧ `u_dbg_line`：**48 位无同步穿越**（已知，**本板不可观测** ⇒ 不修）

设计把 `u_dbg_line`（P4 诊断 UART 状态行）搬进了 DP 域，于是它从 FE 域**直接组合读**了两束**未同步**的
总线：`u_mac_rx/dbg_stat_words_out_reg[31:0]`（32 位）+ `wl_last_lat_reg[15:0]`（16 位）= **48 位**。
`board/p6b_final_ku5p_cdc.rpt` 里这 48 条全是 **CDC-15 Warning（Clock enable controlled CDC structure）**
—— 即"**这不被工具认成同步器**"，只按一般跨域结构告警（该报告 1324 条 CDC-15、223 条 CDC-1 Critical）。

**为什么可以放着**：`u_dbg_line` 的唯一输出 `uart_txd` 虽然**在 XDC 里有引脚**（`AD15`，借厂商
`io_nor[]` 的空闲脚，`board/ku5p_p6a_t8p0.xdc:57`），但 **KU5P 这块板上没有 UART**（无 CH340/CP210x/
FTDI/MAX3232、无 USB 口、无调试排针；见 `../XCKU5PMini/CLAUDE.md`「板上没有 UART」）⇒
**这条通路的输出在本板上物理不可观测**，它坏了也**不会**污染任何数据面/功能通路
（"诊断行字符错乱"是唯一可能的后果）。
⚠️ **若将来给这块板接上 UART 并把它当观测通道，这 48 位必须先过同步器**（或改成快照字）——
**别在没同步的情况下把它当读数用**。

### ⑨ 本轮三条教训（写给下一个 agent）

1. **"跑门 ≠ 判门"**：见 ⑦。门"退出码 0"可能只是**它没判**（`type xsim*.log` 结尾的门；
   判据打印与判据结果脱节的门 —— 本工程历史上有过"固定文案"：`P6E_OBS.md` §七·补2 记着一次
   "5/5 全通的那轮照样打印'慢路径没回 ARP'"）。
   **纪律**：汇总前先看这个门**判据本身**有没有跑（证据非空自检：`checks>0` / `refw>0` / `stat_drop>0`）。
2. **并发 agent 的文件所有权必须互斥**（本轮吃了两次）：
   ① 11:46 的矩阵跑与源码编辑重叠 ⇒ `REVISION DRIFT` 整轮作废（**编辑者以为门红了，其实是自己踩的**）；
   ② F-1 的探针被另一个 agent 改动（`rtl/fifo_async.v` md5 从 `1c21c024…` 变成 `11e8d82a…`，
   `P6B_CDC_AUDIT.md` **A.4** 专门留了"**版本提示（审计时效）**"）；同族还有 `P6B_REVIEW.md` 头部的
   "时间戳与自我更正（必读）"与 **F3**（审查到一半时施工方已修好）。
   **纪律**：① **构建/仿真期间不得改动被构建的源码**（本工程既有坑的加强版）；② 交接时**必须留
   md5/sha256**；③ 凡与"当前文件内容"绑定的结论都要**标注时效**（行号会漂）。
   ⚠️ **同族但更隐蔽的一条（2026-09-29 TL 裁定已合并，此前的"两说未合并"作废）**：
   `SNAP_STATUS.done` 是 **sticky** 的 ⇒ 它只证明"完成过至少一次"，**不证明"这一代是我的"**
   ⇒ 有**并发触发**时，"触发—锁存—读全"三步无法靠 `done` 自证 ⇒ `snap()` 必须用
   **`gen` 恰好 +1** 自证。⇒ 守卫**必需且保留**。
   ⚠️ **但归因要改写**：本文件早先与 `P6B_ACCEPT.md` §7.4 都把"并发读者会互相污染（计数冻结）"
   记为**当日实测踩到** —— **那是错的归因**。那次"计数冻结 / 读数全部作废"的真凶是**该脚本
   自己的变量名撞车**（`$T` 被复用作已跑秒数 ⇒ `$T/reg_rw` 不存在 ⇒ 所有读静默失败 ⇒ 空读
   被 `$(( ))` 当 0），见提交 `b91f763`。
   ⇒ **正确的说法（三处已同步改口）**：`gen+1` 守卫逮的是**代际混淆**（读到别人那一代），
   **不是**"计数冻结"；后者是脚本 bug 的症状，与并发无关。**不要再把那条实测当并发的证据引用。**
3. **批量装守卫之前必须先跑负对照**（否则你不知道守卫是"挡得住"还是"永远绿"）：
   本轮的做法 = 造 **`negctl/foreign` 外仓替身夹具**（一个故意重新硬编码 ECO 路径的门 + 一个非仓目录），
   读数落在 `negctl_A_raw.txt` / `negctl_B_raw.txt`（`RC=1` / `EXIT=97`，**没守卫的话这些都 exit 0**）。
   同一条纪律在**时序闸**上也做了一遍：`board/p6b_verify/CONTROLS.txt` = **13/13 条**正/负样本符合期望
   （含 5 个人造病理报告 `path/neg_path_*.rpt`，由 `run_controls.py` 一键重建），
   才敢说"闸有区分能力"。

### ⑩ 本轮新增 / 退役的文件（索引）

**新增**：`rtl/clk_gen_p6b.v` · `rtl/fifo_async.v` · `rtl/snap_seq.v` · `tb/tb_clk_gen_p6b.v` ·
`tb/tb_fifo_async.v` · `tb/tb_snap_seq.v` · `tb/tb_mac_rx_f4.v` · `tb/tb_f4_chain.v` ·
`board/ku5p_p6b_sysclk.xdc` · `board/ku5p_p6b_cdc.xdc` · `board/build_p6b_ku5p.tcl` ·
`board/build_p6b_final_ku5p.tcl` · `board/check_p6b_timing.py` · `sim/fifoasync/` · `sim/clkgen/` ·
`sim/snapseq/` · `sim/f4sim/` · `sim/f4chain/` · `sim/p4gates/`（P4 硬化工具链 + 证据）·
`_proj_pcie/p6b_accept.sh` + `p6b_smoke_*` · `p6b_accept_final/`（**验收归档**）· `board/p6b_verify/` ·
`P6B_*.md`。（另有 `audit_scratch/` `review_scratch/` `int_scratch/` 三个**审查/审计 agent 的原始证据目录**，
按纪律**保留**；它们的 `.txt` 读数与 TB 源码要入库，`xsim.dir/`/`*.wdb`/`*.memh` 等产物已由 `.gitignore` 排除
—— 见 `P6B_COMMIT_PLAN.md`。）

**已退役（2026-09-29；理由 = 原件已由路径硬化修好，镜像本身是"空门"的临时绕道）**：
`_tmp_make_p4mirror.py` · `sim/p4sim_p6b/` · `sim/retxsim_p6b/` · `sim/retxsim2_p6b/` ·
`sim/vlansim_p6b/` · `sim/tbgate_p6b/`（合计 **~39 MB**）。**退役前逐条确证**：
① 硬化后的矩阵 runner（`sim/p4gates/run_matrix_p4dfix.bat:112-127`）用的是**原件**
（`sim\p4sim\…` / `sim\retxsim\…` / `sim\retxsim2\…` / `sim\vlansim\…` / `sim\tbgate\…`），**不是**镜像目录；
② `paths.txt` 的 `FINGERPRINT_GLOBS` 只哈希原件（⇒ 删镜像**不改**矩阵指纹）；
③ 唯一有独立价值的 `sim/p4sim_p6b/matrix_p4_p6b.log` 与归档副本
`board/p6b_verify/p4_matrix_local_repo.log` **md5 逐字节相同**（`a8079bfc4398dcf1ef1612ed5a147eea`）；
④ 全仓**活代码**里对镜像的引用 = **0**（只剩 `int_scratch/chk_mirror.py` 这个**审查用的核对脚本**，
它因此不能再跑 —— 但它的结论已固化在 `P6B_INTEGRATION_REVIEW.md` §5.2：「镜像脚本忠实：9 个镜像 bat
逆向还原后与原件**逐字节相同**、`XCKU5PMini` 出现 26/26/26/26/26/3/1/3/1 次、**ECO 残留 0 处**」）；
⑤ 另加了 `.gitignore` 规则 `sim/*_p6b/` **防复发**。

**保留未删（说明理由）**：
- `_tmp_p4_gates_harden.py` —— **唯一可执行**的路径硬化迁移记录（`pathfix_applied.txt` /
  `pathfix_dryrun.txt` 两份 39 KB 证据的**生成器**；`inventory_eco_class.txt` 与 `sweep_*.txt` 也由同批工具产出）。
  再跑它会**失败退出**（每步都断言命中计数 ⇒ 已迁移的树必然不命中）⇒ **不是**静默危险的脚本。
  ⚠️ 它本身仍是"23 个未修"之一（Python（手工）类），**保留 = 明知而未修，不是遗漏**。
- `sim/p4gates/` —— **硬化层本体**（`p4env.bat` / `p4gate.py` / `paths.txt` / `run_matrix_p4dfix.bat` /
  各 `*_src.f` / `evidence/`），**当前构建窗口正在用它跑矩阵**。
- `board/ku5p_probe/clkgen_p6b/` —— clk_wiz MMCM **预言机**与引脚探针的原始读数（`*.rpt`/`*.txt`/`*.png`，
  含 `cw_oracle.xci` 与其生成物）；**不是**仿真残渣，**未加忽略规则**。

---

## 2026-09-29 补记 · P6b 长时"失聪"复现探针（**未复现**）+ 一条会改变诊断方法的机理线索

**在最终位流上跑 348 轮 / 96.3 分钟**（前 600 秒每 5 秒一轮 = 101 轮，覆盖"配置后约 20 秒"这个历史高发窗口；
之后每 20 秒）。每轮自证三件（MAGIC + `gen` 恰好 +1 + 36 字无空读），全程只发 ICMP/ARP。

- **101 轮中 0 轮**满足失聪签名（`ΔW6>0 且 ΔW7=0`）；有 `ΔW6>0` 的 100 轮里 **min ΔW7 = 4**（每轮都在回包）。
- 全程 `W21`(TX 中止)/`W19`/`W17`/`W35` **max = 0**；**守恒律 348/348 轮零违规**；
  另发现第三条恒等式 `W16 == W1 + 4·W0` 也 348/348 零违规。
- `W24` ns 级复测 = **156.2409 / 156.2419 MHz**（设计 156.25，偏差 0.006%）⇒ 数据面时钟活着的正面证据。

### ⭐ 新机理线索：失聪**签名本身有天然混淆源**
抓包证实存在 **HELLO ↔ ICMP-unreachable 循环** —— 板子周期性向 `192.168.100.1:8080` 发 UDP HELLO，
主机回 ICMP port unreachable，**该帧进慢路径而 HLS 不应答** ⇒
**一块完全健康的板子也会天然产生 `ΔW6>0 而 ΔW7=0`**。
⇒ **单靠这个签名不足以判失聪**，必须附加"ping 由通变不通"（本工程的旧探针曾因此在 postcheck 的
第一次尝试上报 MOVING，被这个混淆源骗过；主机另有周期性 296B UDP 广播到 `192.168.100.255:1534`）。

### 结论的**措辞边界**（必须照此引用）
只能说"**F4/F-2 修复之后该现象没有出现**"；**不能**说"证明已修好"——
样本量 1，且历史基率本身极低（那两次之后 65 分钟 / 2500 次 ping 也零复现）。

### 两个结构性限制（诚实记录）
1. **"配置后约 20 秒"这个绝对时刻在结构上无法覆盖**：端点只认"FPGA 配置先于 POST"
   ⇒ 必须先烧录再重启主机 ⇒ 配置完成（13:52:43）到首轮采样（13:54:03）之间有 **80 秒观测通道不可用**。
   补偿论证：若现象是"配置后 20 s 触发、持续 ~20 min"，则 t=0 应仍在失聪中；实测 t=0 即 5/5 且 `W7` 在增长。
2. **高流量场景未覆盖**（全程只发 ICMP/ARP ⇒ F-2 的中止分支与 F4 的 `W19` 耦合分支
   **从未在真机被激励**）。历史那两次也是轻流量（相符，但无法外推）。

**证据**：`_proj_pcie/soak_scratch/`（`soak_stdout.log` 348 行逐轮全表 / `soak_words.tsv` 每轮 36 字 + gen /
`soak_postcheck.log` / `program_soak.log`）。

---

## 2026-09-29 补记 · P4 矩阵自身的两条**报告**弱点（两轮皆然，非本次引入，未修）

1. **`unit_uart` 的判据行结构性地不会进矩阵日志**：它的 bat 末行把 xsim 输出丢进 `NUL`，
   只在非零退出时才 `type` ⇒ 矩阵日志里该门只剩守卫那一行。（退出码仍正确传导，**只是丢诊断**。）
2. **runner stdout 末尾的 `---- summary ----` 永远是空块**：`findstr /b "GATE "` 在矩阵日志里
   匹配 **0 行**（日志里是 `=== GATE …` / `EXIT=`；`GATE …` 只进 stdout）⇒ 模式应改成 `"=== GATE "`。

⇒ 这两条与 runner 头注释里已写明的"**跑门 ≠ 判门**"是同一族（另：`unit_fifo` 的 `exit 0` 无条件，
`unit_retx` 亦然 ⇒ 它们的唯一真判据是日志里的 `PASS_ALL` / `ALL 7 GROUPS PASS`）。
**本次只记录、未改**：改判图层会让"16/16"的证据再次与树不同版。

---

## 2026-09-29 P7a: **10G PCS/PMA（含 64b/66b gearbox）实测达标** —— BER 上界 4.997e-13 + 四条新教训

> **归档索引**（本节是里程碑日志；逐条判据与复现步骤在别处，别在这里找）：
> **`P7A_RESULT.md`**（**板级验收原始记录**：两阶段判据表 + gearbox 三条腿 + 两次停下的归因 + 未覆盖清单）·
> `P7A_SPEC.md`（闸 0 施工规格：工具事实核实 / 判据设计 / 风险表）·
> `_proj_10g/`（RTL + XDC + 构建/读数脚本 + 全部原始读数：`reports/` `board_scratch/logs/` `ctrl_scratch/logs/`）。

### ① 一句话

**通过。** 回合 09-27 留下的**最大未知数**（`P7A_SPEC.md` §0：那轮 iBERT **`TXGEARBOX_EN=FALSE`**、
跑 **raw** ⇒ **PCS/gearbox 一层是空白**）已经收口：位流 `p7a_top.bit`
（sha256 `f88d019f…8651d`）在板上双向各跑 **600 s**，**每向 6,003,265,225,472 bit / 0 错字 /
0 头错** ⇒ **95% 置信上界 4.997×10⁻¹³**（严于 10GBASE-R 的 1e-12）；速率
**1.000025×10¹⁰ bit/s**（+0.0025%）⇒ 与 `10.3125 GBd × 64/66` 相差 2.5×10⁻⁵
⇒ **gearbox 比率被实测钉死**（raw 会读 1.031250 / ~1.0313×10¹⁰）。

### ② 判据的两条硬要求（本阶段新增的两个"不这么写就不算数"）

1. **gearbox 必须有"三条腿"同时成立**（`P7A_RESULT.md` §3.3）：
   ① 布局后回读原语属性（`GEARBOX_MODE=5'b10001` / `TX|RXGEARBOX_EN=TRUE` / `TX_DATA_WIDTH=64`）；
   ② 频率恒等式（fabric 侧 **156.25 MHz** vs GTY 的 **161.13 MHz** 那个"raw 才会用"的时钟
   —— 两值差 3.125%，而测量分辨力在 10⁻⁵ 量级）；
   ③ 动态负对照（`rxgearboxslip` 脉冲 ⇒ 爆错 16640/16628 + 掉链 latch + 零错重锁；
   **raw 通路里没有 gearbox 边界可滑**）。
   只 ①② 不能排除"配了但没跑"；只 ③ 不能排除"错误来自别处"。
2. **BER 判据不能用 example 的 `link_status_out`**：它是**漏桶**（一次错只扣 34/67 ⇒ 容忍孤立错误，
   "看着干净"≠零误码）。P7a 的计数器是自己写的（`rtl/p7a_counters.v`），语义可复算；
   且必须带**正对照**（`bits_cnt > 0`）+ **恒等式**（`hdrs_cnt == bits_cnt/64`）防"0 是真空 0"。

### ③ 本阶段新增的四条教训（都要往回收）

1. **问物理装配，要问"线两头分别插在哪"，不能问简称。**
   当时问的是"SFP 环回还在吗"→ 得到"**还在、未动**"；实际拓扑是"**一头板子、一头网卡**"
   ⇒ `sfp1_rx_los=1`、20 s 无锁 ⇒ **白白多跑一轮**（run1 + 两次暗对照 + 一次诊断轮）。
   **要问的是形态**：「这条线的 A 头插哪个笼子、B 头插哪个笼子，两者在不在一台设备上」
   —— "在/不在/没动"这类简称答案**不构成证据**。
2. **Vivado 2025.2 的 Tcl 是 32 位的**（实测 `tcl = 8.6.13 wordSize = 4`，
   `_proj_10g/board_scratch/logs/p7a_board_stdout.txt:43`）
   ⇒ **`format %d/%X` 对 > 2³¹ 的值静默输出 0** ⇒ 读 `bits_cnt`（6×10¹²）会**伪装成"零误码"**。
   ⇒ 读数脚本里**所有大数只用字符串插值，绝不过 `format`**
   （`_proj_10g/board_scratch/dryrun_stub.tcl:78-81` 记着这条是怎么被干跑台架自己抓到的）。
   ⚠️ 与既有铁律同族但是**新的一类**：以前的坑是"**读不到**"（空读数），
   这条是"**读错了还看着更好看**"—— 对判据的杀伤力更大。
3. **XDC 只接受 Tcl 子集**：`if` / `foreach` / `puts` 会让整段约束被**静默跳过**，
   而构建**照样 exit 0、位流照样出**。P7a build #1 里 `dbg_hub` 频率、clock groups、
   CDC 假路径**全部没生效**。可复现的最小证据：`_proj_10g/reports/p7a_xdc_probe_stdout.txt` 里
   `CRITICAL WARNING: [Designutils 20-1307] Command 'if'|'foreach' is not supported ...`，
   紧跟着 **`PROBE_SYNTH_RC = ok`**（报错但综合成功）。
   ⇒ 约束拆平铺 + **判据落到"约束的效果"**（时序报告里的 clock group、`dbg_hub` 的实际频率），
   而不是"脚本没报错 / 构建退出码是 0"。（本工程"真空门"家族的又一成员：**退出码不证明生效**。）
4. **测量台架缺陷会伪装成被测对象的缺陷**：run2 在负对照 A 的取数点**没先发快照请求**
   （`raw_snap` 脉冲）⇒ 读的是**上一批冻结值** ⇒ "前后对比"变成**拿一个值和它自己比**
   （`delta 恒 0`），于是判据退化成 `NEGCTRL_A_ERR_BURST=0 / RELOCK=0` ⇒ 误报 `STOP_NEGCTRL_A`。
   **加剧错觉的一点**：同一状态字里还有**实时位**（`ref_down_latched` 照样翻转）
   ⇒ "有的数在动、有的数不动"极容易被归因到 RTL。
   ⇒ 取数一律 **`snapwait`（发请求 + 等 ack 翻转）再读**；且**判据异常时先怀疑台架**，
   用一条独立探针（这里 = 连发三次真快照看 ack 与计数是否推进）把"被测对象"与"台架"分开。

### ④ 两条事实更正 / 现状（非教训，但别记错）

- 板上这两个模块是 **SFP+ 10G**（**不是 SFP28**；对 10GBASE-R 完全适用）。
  ⚠️ 来源是**口头**（TL 在本轮汇报中的更正），日志里没有模块型号字符串 —— 底板**未引出 SFP 的 I2C**，
  读不到 DOM/型号。"SFP28"的旧措辞出现在 `P7A_SPEC.md` §5.5/§10。
- **本文件写成时板子载的是 P7a 位流**（volatile，最后一次编程是 run3；之后只有读操作）。
  下一次上板**必须重烧 + 重核 sha256**（本工程既有铁律）。

### ⑤ 未覆盖（与 `P7A_RESULT.md` §7 同源，摘要）

超过 10 分钟的长期稳定性（无 soak）· SFP 的 I2C/DOM 无通路 · 手册 12 GHz 边界未触及 ·
对照件里 X0Y6 的 `LINE_RATE=0.000 / RX_BER=inf` 未深究 ·
6-bit `rxheader` 只判"稳定"（2-bit sync header 不在 fabric 可观测面，**已承认的覆盖缺口**）·
整窗比率读到 **0.999995** 而非 1.000000（≈5 ppm，成因未查；与 raw 候选差 3.1%，判别力不受影响）·
只有 PRBS31，没有真实以太网帧/MAC/背压。

---

## 2026-09-29 P7b: 10G 数据面上板第一轮（官方 XGMII 核 + 自写 64 位 MAC）—— **闸 0 / 闸 1 完成；闸 2/3/4 未起**

> **归档索引**（本节是里程碑日志；逐条判据、IP 配置逐项回读与复现命令在别处，别在这里找）：
> **`P7B_SPEC.md`**（施工规格：路线与 license 分叉 / 接口冻结 / 闸序 / **66 条正判据 + 9 条负对照**）·
> **`_proj_10g/notes/P7B_GATE1.md`**（**闸 1 板级读数原始件**：拓扑 / IP 逐项回读 / 长窗零错 / 三条负对照 / 1a 补测）·
> 同目录 `P7B_XXV_OFFICIAL.md`（闸 0：官方核与 license 分叉）·
> `P7B_MAC_{DESIGN,REVIEW,GATEFIX,TIMING}.md`（新 MAC：设计 / 对抗审查 / 判据修复 / 时序）·
> `P7B_RXCLASSIFY_{AUDIT,DESIGN}.md`（v2）· `P7B_IMPLICIT_GATE_{FIX,ROLLOUT}.md`（哑门修复与铺开）·
> `P7B_U7_AND_PEER.md`（字节序取证 + 闸 2 的对端机现状）· `_proj_10g/notes/p7b_tail/logs/`（尾巴轮原始日志）。
> **本轮提交**：`c5f81cd` · `65753c3` · `11e93d3` · `95ce60f` · `fc718b2` · `e450b65`
>（闸 0 的归档在更早的 `2b68936` / `ecc19ba`；`fa9e094` = 文档订正、`e87375a` = 归档补漏。）

### ① 一句话

**未完成 —— 但两块最硬的地基已经落地，且都是"工具/板级原始读数级"的证据。**
闸 0（**选型**：官方 `xxv_ethernet` `CORE = Ethernet PCS/PMA 64-bit` 出 XGMII + **自写 64 位 XGMII MAC**）✅；
闸 1（**板内 J7↔J8 自环**：2 通道官方 PCS + 官方 example 图案发生器/监视器，**未改一行**）✅ 板级 PASS；
新 64 位 MAC 单元门 252 条 0 fail、与 PCS 合并时序收敛 ✅；`rx_classify` v2 设计完成但**未落进 `rtl/`**。
**闸 2（真网卡 802.3 裁决）进行中；闸 3（全链门）/ 闸 4（板级验收）未起。**

### ② 关键读数（逐条带出处）

**闸 0 —— 工具 / 接口 / 选型**（`P7B_XXV_OFFICIAL.md` §0/§0.1/§0.2/§4.5/§4.6；`P7B_SPEC.md` §0/§3.6）

- ⭐ **决定性对照**：官方 10GBASE-R PCS-only 核 `w2_pcs64_baser` 内嵌的 GT 子核与我们的 `gt_10gbr`
  **配置逐项逐字相同**，而它的 fabric 面是 **XGMII**（`w_pcs64_baser.veo:78-79,98-99` =
  `rx_mii_d_0[63:0]` / `rx_mii_c_0[7:0]`）⇒ **GT 是纯 gearbox + PMA，64b/66b PCS 在 GT 之外的 soft logic 里**。
- ⭐ **license 按 CORE 分叉**：本机 `Xilinx.lic` 含 `INCREMENT xxv_eth_mac_pcs … permanent uncounted`；
  `CORE = Ethernet PCS/PMA 64-bit` **位流过**（`probe_pcs64_top.bit`，15,431,266 B），
  **含 MAC 的变体被拒**（原文 `require licenses greater than a Design Linking license`）。
  ⚠️ **`generate_target` 成功 ≠ 能出位流**。
- ⭐ ⚠️ **一个被证伪的前提**：P7a 曾以"`xxv_ethernet` 要 license"为由绕开官方 IP 自拼 PCS ——
  **该前提不成立**（它来自"把 license 藏起来"的负对照；那个负对照口径没错，错的是把它延伸成
  "`xxv_ethernet` 锁着"）。**"查不到"和"锁着"是两件事。**
- ⭐ **U2 定案（证据升级）**：官方核**网表里确有** `i_TX_SCRAMBLER` / `i_RX_DECODER` / `i_RX_WD_ALIGN`
  ⇒ **GT 不加扰，加扰在 soft logic** —— 由 **Xilinx 自己的产物**说话。
- ⭐ **字节序定案**：官方 XGMII 是 **lane0 = 首字节**，与 `tdata[63:56]` 首发的冻结合同**相反**
  ⇒ 新 MAC 在 XGMII 边界做**纯 8 字节镜像**（无位序翻转）。证据 = 官方**明文** example
  `pcs64_pkt_gen_mon.v`（`swapn` @`:1238-1241`；五条独立证据见 `P7B_U7_AND_PEER.md` §A.6）
  **且被板上读数 `c1_sword = 0xD5555555555555FB` 反推验证**（`P7B_GATE1.md` §5.3）。

**闸 1 —— 板内 J7↔J8 自环**（`P7B_GATE1.md` §4、§5.1-5.8、§10.1）

- 位流 `xxv_loop_top.bit`，sha256 `5560375b…72ee2c`；**−1 时序 WNS +1.404 / WHS +0.011 / WPWS +0.514，
  三类失败端点全 0**；资源 7,942 LUT / 15,419 FF / **0 BRAM** / 2×GTYE4_CHANNEL。
- 双向 `block_lock=1 status=1 los=0`，`hi_ber/local_fault/framing_err/bad_code/fifo_error` 全 0。
- **零错的正证据**（防"真空 0"）：6.6 s 内 **30,056,095 帧**；**载荷字/帧 = 29.000000**
  （实测 28.9999997）、**XGMII 字/帧 = 34.000000**（实测 33.9999997）；线速 **9,999.94 Mbps**（−0.0006%）；
  官方 FSM `completion_status = 1`（`SUCCESSFUL_COMPLETION`）。
- **负对照**：拉 `SFP1_TX_DIS`(C11) ⇒ ch1 掉块锁 + 对端 `sfp2_rx_los`(C9) **精确亮**；
  `completion_status` 1→2(`NO_BLOCK_LOCK`)→恢复回 1；**打断时 `/E/` 计数 0→11,808 ⇒ 零错不是真空 0**。
- **1a 补测**：GT 内部环回档 `001` ⇒ ch0 收到自己 **17,572,669** 帧、`010` ⇒ **11,945,493**，与 ch1 逐数相等；
  `000/100/110` 全 0 作负对照。
- ⚠️ **自报未测**：`stat_rx_error[7:0]` 的 `_valid` **整场从未触发** ⇒ 那条线"恒 0"是"**没话说**"，
  **按未测登记**（R12 形态）。

**新 64 位 XGMII MAC —— 已完成，未接入**（`P7B_MAC_DESIGN.md` §0/§2/§7/§8；`P7B_MAC_TIMING.md` §0/§2.2/§3/§4）

- 单元门 **252 条判据 / 0 fail**；变异 **12 条 = 10 非等价全抓住 + 2 等价如实报"没抓到"**。
- **帧首排布在板上闭环**：`lane0 /S/(0xFB,c=1) + lane1..6 0x55 + lane7 0xD5(c=0)`，`c=8'h01`；
  手算例程前 3 字与板上实测 `0xD5555555555555FB` / `0xFE14FFFFFFFFFFFF` / `0x00000006829ADDB5` 逐字节吻合。
- ⚠️ **拒绝了厂商例程的非标角落**（帧长恰为 8 的倍数时它组 `T0 D1..D7`，**IEEE Figure 49-7 无此格式**）。
- 最小帧吞吐 **~1/3 → 95.5%**（L=60：11 拍/帧 = 88B / 理想 84B）。
- **时序**：与 PCS 合并 **WNS +0.401 / WHS +0.008 / 三类失败端点全 0**，`route_design Complete`；
  LUT 9040→**12877**；CRC 实测 **1058 / 1091 LUT**、reg→reg 仅 **6~7 级**；**时钟域核实无新增跨域对**。
  ⚠️ MAC 单独 OOC 报的 hold 239 违例，**239 / 33 条起点全是端口、0 条来自寄存器 ⇒ OOC 端口伪影**；
  真实 reg→reg `TX +0.024 / RX +0.011`。

**`rx_classify` 收发解耦 v2 —— 设计完成，⚠️ 未落进 `rtl/`**（`P7B_RXCLASSIFY_DESIGN.md` §0/§5.1/§8）

- 最小帧帧周期 **14 → 8 拍**（死拍 6→0）；10G 最小帧 **57.1% → 100%**（57.1% = `P7B_SPEC.md` §1.1 的 8/14）。
- 保真：v1/v2 **逐拍逐位 6224 beat × 7 场景 0 失配**；变异 **4 条非等价全抓住 + 3 条等价如实报"没抓到"**。

**门修复 —— 隐式网"哑门"**（`P7B_IMPLICIT_GATE_FIX.md` §0/§2.6/§3；`P7B_IMPLICIT_GATE_ROLLOUT.md` §1/§5）

- 起因：`findstr implicit` 在 **Vivado 2025.2 是哑门**（2025.2 不再打印 `implicitly declared`）。
- 2025.2 真实签名三条：synth `INFO: [Synth 8-11241] undeclared symbol`、
  xelab `WARNING: [VRFC 10-3091] actual bit length 1 differs from formal bit length`、
  xvlog 表达式 `ERROR: [VRFC 10-2989]`。⚠️ **端口连接形式的隐式网 xvlog 一个字都不打印**。
- 铺开 **87 文件 / 261 处**；**假阳性 0**（收窄后本仓 43 份命中里 **41 份指向 `D:/repo/ECO/` 的陈旧日志**）。
- ⭐ 真阳性首捕 `tb/tb_p5_app.v:511`（隐式 `tx_fsm_state_w` 驱动 3 位 `dbg_state`）；**污染核查 = 无**。
- ⭐ `sim/p4sim/run_matrix_p4dfix.sh`（16 门矩阵现役 sh 入口，被 4 份文档引用）**从未入库** ⇒ 已放行。
- 回归：P4 16 门矩阵 **16/16 EXIT=0**（`_proj_10g/notes/p7b_tail/logs/matrix_full_after.txt`）；
  冻结校验 `VERDICT: FROZEN`（237 份哈希文件逐字节一致）。

### ③ 教训（10 条）

1. **计数器可以被伪装 —— 只有"按帧独立的内容比对"能抓幽灵帧。** 我们为 F-2 付过一轮学费
   （线上出现 **FCS 正确**的幽灵帧），原案靠的是"该帧 content 与**任何注入帧都不等**"这条**内容判据**；
   新门却只留了计数器 ⇒ 审查方新造变异 **M7b（去冲刷 + 计数器伪装）真的发出幽灵帧，而门 229/0 PASS**。
   修后 **M7b FAIL**（而被伪装的那两条计数器判据**照样 PASS** ⇒ 反向证明计数器确实可被骗）。
2. **"有输出没牙齿"是哑门的第二种形态**：14 行"检测到了只打印"不成硬失败。且 **cmd 管道写法实测
   会反向误判**（病理读 0、干净读 1）⇒ 修门必须配负对照、并实测退出码真能传播。
3. **`generate_target` 成功 ≠ 能出位流**（`Design_Linking` 级授权的分叉）。
4. **"检测到了" ≠ "判据有判别力"**：审查还揪出两条**恒真**判据，以及一条**前提根本不成立**的判据
   （"T/S 同拍"而原激励里**根本没有 `/T/`**）。
5. **单帧用例测不出 IFG**：MAC 门的 IFG 变异最初没抓住，因为**单帧用例里 `S_IDLE` 空闲字与 IFG 空闲字
   不可区分**；必须"两帧连发看 `/S/`→`/S/` 周期 == 12 拍"才成立。
6. **自环回是对称的、对绝对字节序/加扰/802.3 符合性零判别力** ⇒ 必须有真网卡裁决
   （这是闸 2 存在的理由）。
7. **`gitignore` 是最后匹配者胜** ⇒ `!` 行与排除行的**相对位置**决定成败；且 **`git check-ignore -v`
   的退出码在 `!` 行上不可信**（只有 `-q` 可信）。本次真踩过：一大块规则被编辑锚点带到第 53 行，
   而否定行在第 462 行 ⇒ 排除被反向覆盖。
8. **`core.autocrlf=true` 下，从 HEAD blob 看不出工作区的行尾**（索引里永远存 LF）——
   本轮有两次测量栽在这上面。
9. **"报告引用的东西必须真的在库里"**（本轮又有两处：`run_matrix_p4dfix.sh`、
   以及 8 棵 0 已跟踪文件的树）。
10. **"查不到" ≠ "锁着"**（闸 0 那条被证伪的前提）—— 负对照口径没错，错在把它的结论
    延伸出适用范围；**一个负对照只能否定它自己测过的那个命题**。

### ④ 现状 / 未核实（别记错）

- **板上现载位流 = 未核实**（闸 2 正在用板；本文件写成时没有取过这条读数）。
  上板前一律**重烧 + 重核 sha256**（本工程既有铁律）。
- 闸 2 的**在库**现状读数（`P7B_U7_AND_PEER.md` §B.1.2/§B.3）取数时两口都是 `NO-CARRIER`
  （`Link detected: no`）；`enp1s0f1np1` 是本机唯一实测上过 10000Mbps 的口。
  **"当前已 link"与那次读数不同时点 —— 本文件未核实两者之间的状态变化。**

### ⑤ 未结项（**别写成已完成**）

- **闸 2（真网卡裁决 802.3）—— 进行中。** 诊断要点：`enp1s0f1np1` `Link detected: yes` /
  `Speed: 10000Mb/s` / `FIBRE`，但 `RX packets 0`（⚠️ 那是 **netdev** 计数，**不是硬件计数**；
  判收包只能看 `ethtool -S` 的 `port_rx_packets` / `rx_eth_crc_err`）。
  **决定性负对照（拉 `TX_DIS` ⇒ 网卡必须掉 link）尚未完成。**
- **闸 3（全链门）/ 闸 4（板级验收）—— 未起。**
- **`rx_classify` v2 未落进 `rtl/`**（落地要配 P4 矩阵 + P6b 验收门回归）。
- **MAC 未接入 `board/wrapper_p4.v`。**
- 官方核 RTL **全加密**（读不到实现）；那 **10 条厂商例程**（`pcs64_pkt_gen_mon_ds.v`）的隐式网**未修**
  （预先存在、与本轮无关）。
- **其余 76 门未逐门重跑。**

## 2026-09-30 P7b（闸 3 收口 → 闸 4 板级通过）: 两个真缺陷修复 + 全仓门回归 + 板级验收三轮收口

> **归档索引**（本节是里程碑日志；逐条判据、原始读数与复现命令在别处，别在这里找）：
> **`_proj_10g/notes/P7B_HANDOFF.md`**（**下一轮开工先读这份**：环境现状 / 状态总表 / 下一步 / 待办账 / 产品级 Gap）·
> **`P7B_GATE4_ACCEPT{,2,3}.md`**（闸 4 三轮：PARTIAL → PARTIAL → **通过**）·
> `P7B_GATE4_CRITERIA_CLOSEOUT.md`（3 条 FAIL 的判据侧定性与修法 + **产品级 Gap 6 条**）·
> `P7B_GATE4_PLAN.md` / `P7B_GATE4_TOOLING{,FIX2}.md`（runbook 与验收工具）·
> `P7B_UDP_APP_ROOTCAUSE.md`（三假设全否）→ `P7B_UDP_DIAG2.md`（**lane4 根因 + 双证**）→ `P7B_LANEFIX.md`（修法 +122/−25）·
> `P7B_TIMING_RERUN.md`（`−0.173 / 39 失败`）→ `P7B_MAC_TIMING_FIX.md`（`padrem`/`lw_ts` 等价化简）→ **`P7B_BUILD_FINAL.md`**（合并构建 +0.128 / 0 失败）·
> `P7B_REGRESSION.md`（**136 门回归**）· `P7B_CHAIN_COVERAGE.md`（链级门 80→106）·
> **`P7B_EVIDENCE_AUDIT.md`**（历史证据污染审计）· `P7B_VENDOR_EXAMPLE_DEFECTS.md`（厂商两笔账结案）· `P7B_LATENCY_GAPS.md`（延迟两缺口归因）。
> **本轮提交**：**尚未提交** —— 全部改动仍在工作区，HEAD 仍为 `f86b07f`（上一条是本轮之前的"P7b 归档收口"）。

### ① 一句话

**闸 3 收口、闸 4 板级通过。** 板级卡住的那个"app 分流失效"根因**不是台架、也不是配置**，
而是**新 64 位 MAC 的 `/S/` 落 lane4 缺陷**（SOP 字只有 4 字节 ⇒ `udp_rx` 第 0 拍就判 nonmatch）
—— 已修（+122/−25）并配齐判据族；**时序被这次修复打出的 `−0.173 / 39 失败端点` 也已等价化简收回**
（`+0.128 / 三类失败端点全 0`，位流 sha256 `0e1c8088…`）。
闸 4 三轮 `PARTIAL → PARTIAL → **通过**`，**唯一 FAIL = `C8`**（8 位饱和计数器上"在涨"结构性不可判，
**判据一字未改、非设计缺陷**），另有 4 项未测/缺口。
**10G 线速仍未达标**（app 发生器 1 字节/拍 ⇒ 实测载荷 1.248 Gbps = 线速 ~12.5%）—— 产品级第一优先。

### ② 关键读数（逐条带出处）

**① 板级失效的根因链（三个假设被逐个否掉，最后双证钉死）**

- 先两路否证：`P7B_UDP_APP_ROOTCAUSE.md` 否掉"配置回归 / RTL 逻辑缺陷 / 宏组合接线错"（新建 P7B_10G 真 wrapper 门
  用逐字节同几何教学帧实测 `stat_pass=1 → meta_valid → app 口 stat_app=1`，11 判据 0 fail），
  并把 `W2 = 0x92 = 146`（= 142 内容 + 4 FCS）补成"板子收到的就是教学帧"的实锤。
- ⭐ **根因 = `mac_rx_10g` 对 `/S/` 落 XGMII lane4 的帧处理缺陷**（`P7B_UDP_DIAG2.md`，板级 + 全 wrapper 仿真双证）：
  首字只有 4 字节（`tkeep=0xF0`）+ **整帧字流偏 4 字节** ⇒ `udp_rx` 第 0 拍按 `s_axis_tkeep != 8'hFF` 判 nonmatch
  ⇒ `S_DROP` ⇒ 原样透传 HLS ⇒ **板级签名 `W6+1 / W10=0 / W3=0 / 字节守恒`**。
  **判别性证据**：同一条工具、同一帧内容、同一长度 —— **单发 0/1 认领、20 连发认领 8~11/20**、
  同内容不可复现 ⇒ 唯一还能逐帧变化的输入 = **字级打包（起始 lane）**；仿真里只改注入 lane（lane0→lane4）
  即逐字复现该签名（`udp_rx` 读数 `pass=8 nm=121` → `pass=0 nm=129`）。
- **修法**（`P7B_LANEFIX.md`，`_proj_10g/p7b_mac/rtl/mac_rx_10g.v` **+122 / −25 行**，唯一 canonical 副本）：
  新增"级 A-3"——lane4 帧首 4 字节**扣住**，与下一字前 4 字节拼成满字 SOP，此后每拍滚动，
  末字 `/T/` 落 lane5..7 时余下字节由**冲字** F 交付。**下游一行未改**（字节序合同未动）；
  **lane0 帧逐位不变**（`ap_* ≡ a_*`）。
- **验证（五路实跑）**：MAC 单元门 **391 / 0**（+54 条 lane4 判据）· wrapper 门 **26 / 0**（lane0 13 + lane4 13）·
  链级门 **80 / 0** · P4 默认矩阵 **16/16 EXIT=0 + FROZEN** · **反例有牙**（换回修前 RTL ⇒ MAC 门 391/**9 fail**，
  9 条**全是 SOP 满对齐判据**，其余 382 条全绿）。
- ⚠️ **修法改变拍对齐**：lane4 帧的 `(a)→(b)` 段由 **4 拍变 5 拍**（`P7B_LANEFIX.md` §5.3）
  ⇒ `P7B_EVIDENCE_AUDIT.md` §B.3.1 **理由 #1（"lane4 不引入额外一拍"）已失效**；该段因此变成 **lane4 探测器**
  （复跑取数：全 4 拍 ⇒ 样本无 lane4；出现 5 拍 ⇒ 需按 lane 重新制表）。

**② 时序：回归 → 等价化简 → 合并构建收敛**

- 回归读数（`P7B_TIMING_RERUN.md`）：**`WNS −0.173 / WHS +0.010`**，**39 个 setup 失败端点**
  **全部同一个起点** `u_mac_tx/plen_reg[6]/C`、终点全在 PCS TX 编码器，**逻辑 15–21 级**；
  hold / 脉宽失败端点全 0。**vs P6b 基线（`+0.168 / 0 失败`）是回归**。
  归因 = `effef26` 的 pad/FCS 修复把"组合算术"接进 CRC（`crc_keep = f(lw_ts)`）⇒ 同一条结构性路径被拉长。
- 修复（`P7B_MAC_TIMING_FIX.md`）：**改 1 个文件 / 5 处 / +28 −1 行，全部等价化简** —— 把 `lw_ts` 从**两个进位链**里
  解放出来，改由**新寄存器 `padrem`（= `max(0, 60−plen)`）**算。**零新增/删除逻辑层次**，不碰 `crc_keep/crc_d/crc_en`
  三行、不碰 `crc32_64.v`、不碰状态机/拍序/XDC。等价性双证：单元门日志**逐行 diff 只剩一行时间戳**；
  穷举 **14409 组 `(plen,cw_len)` 逐点相同 + `padrem` 不变式零违反**。OOC 同 flow 因果量：**+0.478 ns**（18 级 → 12 级）。
- ⭐ **合并构建收敛**（`P7B_BUILD_FINAL.md`）：**`WNS +0.128 / WHS +0.010`，setup/hold/pulse-width 三类失败端点全 0**；
  **11 个 intra clock group + 3 条 inter-clock + 3 条 async_default 逐组 0 失败**。
  上轮主目标组 `txoutclk_out[0]_3` **`−0.173 / 39` → `+0.765 / 0`（+0.938 ns，是 MAC-only 预测 +0.478 的两倍）**；
  `rxoutclk_out[0]_3` 端点 9599→9674（**+75 = lane4 修复的代价如实反映**）但 WNS **+0.206 → +0.209** ⇒ **RX 域裕量未被侵蚀**。
  位流 `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit`，15,431,261 B，
  sha256 **`0e1c8088d3907bd52915fa1a1a291ceeb627ed1b5252e421f825c9abdd7fb557`**。
- ⚠️ **组名后缀逐轮漂移**（裸名/`_1` ↔ `_2`/`_3`）：根因已定位到工具侧 `opt_design` 的 clock-buffer 插入
  （`BUFGCE` 6/4/5，而 BRAM/CARRY8/GT 逐数相同）⇒ **跨轮对比必须按端点指纹（3429 / 817 / 34 / ~2376 / ~9600）对齐，不能按名字**。

**③ 闸 4 板级验收（三轮：PARTIAL → PARTIAL → 通过）**

- 第一轮（`P7B_GATE4_ACCEPT.md`）：`PASS=8 / FAIL=3 / SKIP=1`，**新发现板级缺陷** = app-UDP 分流失效（见 ①）。
- 第二轮（`P7B_GATE4_ACCEPT2.md`，干净时序位流）：`PASS=23 / FAIL=3 / SKIP=0`；
  ⭐ **lane4 修复在板上生效** —— 第一次做到**单发教学即被认领**、成批 **20/20** 认领、
  **图案流 2999 帧逐字节**等于图案流且偏移从 0 连续；2M 最小帧洪泛下 `drop_full` 恒 0。
- ⭐ 第三轮（`P7B_GATE4_ACCEPT3.md`，**收口轮**）：`p7b_gate4_accept.sh`（fix3 冻结版**首次上真板**）
  **`PASS=26 / FAIL=1 / SKIP=1`（28 条判据）**；`p6e_snap_check.sh` **`PASS=15 / FAIL=0 / SKIP=0`**。
  ⭐ **最终判据表**（`P7B_GATE4_ACCEPT3.md` §2，**38 行**）：**`PASS=33` / `FAIL=1`（仅 `C8`）/ `未测=4`** ——
  计法写死在该节读法里（**一行一状态；规格原文含可分开判的两半则拆行**，全表只有 `F1-E4`→`a`/`b` 与 `F5`→`a`/`b` 两处）。
  **未测 4 = `F1-E4b` · `F1-E5` · `F1-E6` · `F5b`**。⚠️ **两个 `E4` 不是同一条**：§6.1 的 `E4` = 洪泛 `ΔW34`；
  `F1-E4` 是闸 2 的 E4（反向：NIC 发帧 → FPGA RX）。⚠️ 此前引用的"32"作废（它把两条"骑墙行"的一半计入 PASS、
  又各记一个未测行 ⇒ 37 行，在 36 行表里不自洽）。**一律以 `P7B_GATE4_ACCEPT3.md` §2 的表为准。**
- 烧录 = JTAG @1 MHz 经 `192.168.0.38:3121`，`End of startup status: HIGH`；**次序不可换**：
  **先烧位流 → 再重启对端机**（重启后 BAR 立刻读通 ⇒ PCIe 观测窗口活）。
  ⚠️ **PCIe 端点只认"FPGA 配置先于主机 POST"**（这条硬约束本轮再次被遵守）。
- **⭐ 2 条 FAIL 的去向（必须分开写"判据改了" vs "现象变了"）**：
  `T_RUN` 从 FAIL → PASS 是**判据改了**（一条判据干了两件事 ⇒ 拆成 `T_RUN`（激励**执行了没有**，硬判）
  + `T_TOOL`（**工具自己**的结论，SKIP + 归因））；`N_SELF` 从 FAIL → PASS 是**判据加了容差**
  （实测**单个 dump 内部**就 `good+bad = packets +1` ⇒ 三个字段不是同一次原子快照）；
  `N_XCHK` 从"FAIL" → PASS 是**判据修好了、本轮第一次真的被评估**（旧守卫 `${assoc+x}` 对关联数组
  **只测下标 0** ⇒ **两轮验收日志里从来没有这一行**）。
  ⇒ ⚠️ **没有一条是"现象变好了"**；`C8` 更是**判据一字未改、原样 FAIL**。
- **唯一 FAIL = `C8`**：`W40` 低 8 位 = `pcs_vcc_cyc`，**四块快照全是 `0xFF`（255 → 255）**；
  `board/wrapper_p4.v:3366-3379` 是 **8 位饱和计数器**，`dp_clk` 156.25 MHz ⇒ **1.6 µs 饱和** ⇒
  **"持续增长"在这条观测线上结构性不可判**。**正证据成立**（非 0 ⇒ 状态线确实来自核，不是被钉 0）。
  收口建议（⚠️ **本轮未动手**）：① **不重建位流** —— 把判据形式改成"**饱和本身就是下界证据**"
  （任何 ≥1.6 µs 的窗口都有 **≥255 个/窗口** 的硬下界）；② **重建位流** —— 该计数加宽到 ≥16 位或另加 tick 位。
- **F4/F3 换独立口径**：F3 = 3000 帧全载荷**逐字节** + 步长恒 1 帧（**GF(2) 线性反解锚定，无需重烧**，
  判据自带 3 正 + 3 负自检）；F4 = pcap 端点时间戳 **106,182 / 106,174 fps** vs 板侧 `W20` **106,003.170 fps**
  ⇒ **偏差 +0.17%**。
- **F5（TCP @10G）从"未测"升级为"定性 PASS + 两处显式缺口"**：握手 5/5（0.10–0.20 ms）；
  TX 从全 0 起 `W14` 0→**1592** 帧 / `W15` 0→**2,290,952 B**；RX `W22` 0→**1493**、`W23` 0→**7**；
  通道整场 `W3`=0、`W39 = 0x2000100C` 不变。⭐ TCP TX 流内容**不是回显而是图案流**（GF(2) 反解出状态
  **== 公共种子 `0x9E3779B97F4A7C15`、每连接归零**）⇒ "回显不匹配"是**期望错、不是缺陷**。
  **未测①（`F1-E4b`）** TCP RX 载荷逐字节（本构建 app 是 UDP 版，**TCP 载荷没有消费者**）；
  **未测②（`F5b`）** RTO/重传计数 —— `tx_stat_retx` 是 wrapper **内部 wire**（`board/wrapper_p4.v:1496`），
  **不在 51 字快照窗口内 ⇒ 结构性不可读**。
  （⚠️ 行名以 `P7B_GATE4_ACCEPT3.md` §2 为准：`F5` 拆成 **`F5a` = PASS（定性）/ `F5b` = 未测**，
  `F1-E4` 拆成 **`F1-E4a` = PASS / `F1-E4b` = 未测**。）

**④ 全仓门回归（`P7B_REGRESSION.md`）**

- **逐门跑过 136 门**：通过 **112**（108 PASS + 4 期望非零）；失败 **24** = **本轮真回归 2** + **既存 21** + **偶发 1**；
  另有 **8 条哑门/空门/坏脚本**（不计入通过）。
- ★ **本轮引入的真回归 = `p4_rxclass` / `p4_rxclass_xk`**：`rx_classify` v2 新增 `fifo_sync` 例化（`rtl/rx_classify.v:88`），
  而两条门的编译清单（`sim/p4sim/run_tb_rxclass.bat:29`）**没跟上** ⇒ `Module <fifo_sync> not found` ⇒ elab 硬失败。
  **不是设计缺陷**（设计本身编译得过：P4 矩阵 16/16 + `p7b_rxcls_v2` 门 PASS）。
  ⇒ ✅ **已收口**（`P7B_GATE_HARNESS_FIX.md`）：两条门的 `xvlog` 行各补 1 个 `..\..\rtl\fifo_sync.v`
  ⇒ **两条都 EXIT=0**，判据行 `nostall/stall/hard: PASS (161 lines)` + `tb_rx_classify: PASS`，**与基线逐字相同**；
  **未改 RTL**。清单原型 = 同 TB/同 DUT 的另两条现役门（`_proj_10g/p7b_rxcls/sim/run_{legacy_tb_rxclass,tb_rxcls_v2}.bat`，二者都列了该文件）。
  反例真跑：用 `git show HEAD:` 的修前清单 ⇒ `VRFC 10-2063` **EXIT=1**。
- **21 条既存失败在基线 `02d51ed` 上逐字/逐因复现**（A/B 双跑，用 `git worktree` 建独立基线树）。
- **8 条哑门实测**：`p4_matrix16`(自带汇总) · `d2_suite` · **`p5c_rev_elab`（哑门正在掩盖一个既存 elab 硬失败：
  `udp_tx_cfg` / `udp_tx_frame` 不在该门的 RTLF 清单里）** · `f4_sttrace` · `p4_replay`（`CACK` = 空门）·
  **`p4indm_4gates`（`run_4gates.sh` 用 cmd 语法 `%REPO_ROOT%` ⇒ 结果永远写不出去 = 真空门家族残留）** ·
  `p7b_impl_one` · `p7b_impl_xvlog_all`（坏脚本）。
  ⚠️ **哑门不止 README/CLAUDE 写的 `unit_retx`/`unit_fifo` 那两条**；后两条本轮按纪律**读了日志尾**
  （`ALL 7 GROUPS PASS` / `PASS_ALL`）⇒ 实为 PASS。
- ⭐ **其中 3 条已修**（`P7B_GATE_HARNESS_FIX.md`，**反例 4 条真跑、全按期望翻转**）：
  ① **`p5c_rev_elab`** —— 核实为"**门的清单缺件，不是模块不存在**"（`rtl/udp_tx_cfg.v` / `udp_tx_frame.v` 都在）
  ⇒ `RTLF` 补 2 文件 + 加 **ERROR 硬失败判据** ⇒ **EXIT=0**、两配置（默认 + `-d APP_MODE`）`0 ERROR`；**未动 RTL**。
  ② **`p4_replay`** —— ⚠️ **订正**：真因**不是 `CACK` 笔误**，而是那行 REM **同时含 `%` 与非 ASCII** ⇒
  cmd 把它当**活命令**执行（三方对照实测：纯 ASCII + `%` ✅ / 无 `%` ✅）；且门**其实跑了 117 s**并打印了 TB 末行
  ⇒ 真正的病是**没有判据**（末行 = xsim 的退出码）。修 = 该行改纯 ASCII + 补 **DONE 完成判据** ⇒ **EXIT=0**。
  ⭐ 这条归到用户全局经验"**bat 注释禁 UTF-8 中文**"一族，本轮补上了**精确触发条件（`%` ∧ 非 ASCII）**；
  全仓扫描 609 份 `.bat`/`.cmd` ⇒ 同类 REM 行**只剩 3 处、全在归档/私有副本，现役门 0 处**。
  ③ **`p4indm_4gates`** —— 新建 `sim/p4indm/run_4gates.bat` **委托** P4 矩阵 runner
  （`-only pcackoob+vlanchain+vlanburst+stallgate`），`run_4gates.sh` 改**薄 shim** ⇒ **EXIT=0**、`gates run 4/16`。
  拒绝传播有牙：门名表塞未声明的门 ⇒ 两条入口都 **EXIT=97**。
  ⚠️ **残留（不在本文件所有权内）**：① 回归 harness 的门表仍指向 `.sh`（`_proj_10g/notes/p7b_regression/run_all_gates.py:158`，
  而 runner 用 `cmd /c <bat>` 跑不动 .sh）；② **两条修好的门脚本在 `.gitignore` 里**（`sim/p4indm/**`、`sim/p5c_t3/**`）
  ⇒ **放行处理中**（未经放行，`git add` 带不走这两个修复）。

**⑤ 链级门覆盖面补齐（`P7B_CHAIN_COVERAGE.md`）**

- **判据 80 → 106（+26）**，**既有 80 条逐语句零改动**（脚本对账：消失/改名 0、条件被改 0）。
- 补的三处缺口：① **链级 RX 侧此前一条 SOP 判据都没有** ⇒ 补 `SOP-1`（每个 `tuser==1` 的字必须 `tkeep==8'hFF`）
  + `SOP-2`（ΣSOP == ΣTLAST）；② TERM 六元组 **3/6 → 6/6**；③ 帧长扫描从"只看字节计数" → **逐字节**。
  另加 **lane4 注入**（`xq_pack_words_sh(n,4)`）与 **`60..67` 八档扫描** ⇒ `/T/` 落 **lane4..3 八档全遍历**
  （由 `G1c` 从注入的 XGMII 字里**实测**掩码 `0xFF`，不是推导）。
- **反例有牙（实跑）**：换回修前 `mac_rx_10g` ⇒ **106 / 12 fail**，12 条**全在新判据族**，
  **既有 80 条一条不红**；换回修复版 ⇒ 106/0。定点变异 `MUT-TERMDATA` ⇒ 只红 TERM-2
  （**旧 3/6 判据全绿** ⇒ 这正是缺口②的价值）；`MUT-TERMKEEP` ⇒ 红 TERM-1/TERM-2 + 既有 5b。
- 顺带抓出 **`[DEFECT-REG #2]`**：`mac_rx_10g.dbg_rx_last_tlane` 在"tlast 回落到前一字"时**恒报 8**
  （`mac_rx_10g.v:400`）。**该网无消费者（悬空）⇒ 零功能影响**，但属"仪表会撒谎" ⇒ 谁要接它做板级判读**必须先修这里**。
- **残余缺口（显式列出）**：链级门对 `stat_rx_bad_words`（保留控制码）**任何 lane 都无判据**；
  lane4 的**碎片 / 0 字节退化帧**链级未测；`SOP-2` **无实跑反例**。

**⑥ 历史证据污染审计（`P7B_EVIDENCE_AUDIT.md`）**

- **两处伪影零污染**：缺陷 A（`freq_check()` 的"陈旧锁存值 + 本次时间戳"）
  **从未进入任何已提交版本**（六个提交 `git show` 逐版核对，`grep freq_check` 六次全空）⇒
  已入库的频率读数（P6b `156.2585`/`125.0061`、闸 1 `9,999.94 Mbps`、P7a `1.000025e10 bit/s`）**不受影响**；
  已提交版 `snap_check` 的时钟路径是**正确顺序**（两端对称）。
- **缺陷 B（lane4）的免疫边界**：`mac_rx_10g.v` **只有 `65753c3`（09-29 23:12:59）一个提交**
  ⇒ **凡在此之前的板级读数天然免疫**；闸 1/闸 2/P7a/P6b/P6e **走的都不是这条通路**（文件级判据）。
  ⚠️ **受影响的是 `P7B_LATENCY.md` 的分段延迟**：**读数我认为不受影响，但"样本代表性"要打问号**
  （P7b 现役位流**没有任何一个字**能统计"lane4 命中数" ⇒ 无判别力）⇒ **修好后复跑同一套取数做 A/B**。
- ⚠️ **订正**：`P7B_UDP_DIAG2.md` §2.4 写"MAC 单元门 252 条**全部只在 lane0 注入**"**不确** ——
  `tb_mac_10g.v:715-729` **有** lane4 用例；真因是**那 4 条判据没有判别力**（`rx_sop_ok = (rx_wcnt===0)`
  只查 `tuser` 落在第 0 字、**不查 `tkeep`**；另三条在 lane4 下**也都成立**）⇒ **门绿了，合同却没被验**。

**⑦ 厂商 example 的两笔账结案（`P7B_VENDOR_EXAMPLE_DEFECTS.md`，**建议都不修**）**

- **FCS 缺陷成立，且由"长度论证"升级为"逐位复算"**：发生器的 CRC 覆盖长度用 `pkt_len-4 = 252`，
  而实际被保护的数据只有 **244 B**，多出的 **8 B 正好是 word0 那个"`/S/` + 前导"字**
  （厂商把 `pkt_len` 当成了"不含前导的帧长"）。复算：厂商实际发出的 FCS = `5F 3F DD 10`，
  正确值应为 `7F 9E D8 D5`；出厂默认 `insert_crc=1'b0` 时 FCS 字段恒 `00 00 00 00` ⇒ **两档都被任何 802.3 接收器判坏**
  ⇒ 这解释了闸 2 那条"没有按期望翻转"的差分负对照。oracle = **`zlib.crc32`**（与厂商 RTL 无共同代码）。
  ⭐ **我们自己的 MAC 没有这个缺陷**（**结构性**：CRC 输入只来自内容 lane，前导字在 `S_PRE` 且 `crc_en=0`）。
  **不修的理由**：① 我们自己的通路不经过它（`build_p7b_ku5p.tcl` 只导入官方 **PCS 核**，不导入 example 流量模块）；
  ② 它历史上只造成"激励不合法"，未污染任何设计结论；③ 改它会让"板级读数 ↔ 未改一行的厂商明文源码"这条链断掉。
- **10 条 `Synth 8-11241` 全在厂商 example 的 `pcs64_pkt_gen_mon*.v` 里**（我们自己的 RTL **0 条**）：
  逐条判过，**3 条**接的是显式 1 位端口（宽度一致），**7 条**是**死网**（全文件仅此一处、无消费者）⇒ **无功能影响**。
  ⭐ **踩点**：`assign ctl_local_loopback = 1'b1;` 看着像"默认打开 GT 本地环回"，**实际是死网**
  —— **谁想照抄 example 做自环，照着这行是拿不到环回的**（我们闸 1 的内环是用 VIO 自己拉起来的）。
  ⚠️ **但门有两个洞**：① **p7b 项目自己的 IP OOC run 日志里有同族 28 条**（厂商生成的 `pcs64_wrapper.v`），
  **不在 bat 的 grep 面内**；② **该 bat 命中后不置退出码**（三条硬门都只打 banner，退出码仍由"位流是否存在"决定）。

**⑧ 延迟两个缺口的归因（`P7B_LATENCY_GAPS.md`）**

- **缺口一（`(d)` tap 恒不触发）归因 = 激励，不是接线**：四条证据（层次名解析成立 / 只有已知的故意悬空网
  `pcs_ch0_unused58` 被报无驱动 / 被 tap 的 `uf_commit_word` **有功能消费者** ⇒ 不可能是常量网 /
  `.ltx` 里探针**不是 `<const0>`** 且有正对照）都指向"接线到位"，但**没有一条能把"接没接到位"做成实锤**。
  真因 = **当时的激励（IPv6 ICMPv6）在 RTL 上结构性不可能满足触发条件**（`udp_rx` 要求 IPv4 `0x0800`+`0x45`、
  proto 17、目的 IP = 192.168.100.2：**IPv6 一票否决**）。
  **零 RTL 改动**即可测 —— 缺的只是**一个真 IPv4/UDP 帧**（对端机 root + `/32` 路由是硬前置）。
  ⭐ **旁证**：同一 `rtl/udp_split.v` 在 **1G 构建**上被 IPv4/UDP 报文触发过（P6e 教学包 `W10` 收帧 = 1）。
- **缺口二（fast path → app 队列）链路已查清**（`rx_classify.fast → tcp_rx → pay_* → tcp_echo(64KB frame_fifo) → axis_pipe(1 拍) → app_rx_*`）；
  **终点信号（推荐）= `tcp_echo.stat_tlast_wr`**（"整帧已完整写进 FIFO"）；固定开销**读 RTL 推算 13~15 拍 ≈ 83~96 ns**
  （⚠️ **推算，不是读数**）。要测**必须加探针 + 重建**，且**必须先过闸 4**。
- ⭐ **已量到的段覆盖不了全程**：`(a)→(b)→(c)→(e)` 只覆盖**慢支**固定流水（95.98 ns）；
  **(cf)→app 队列零读数 · (c)→(d) 零读数 · `L_PCS` 零读数**。

### ③ 教训（11 条）

1. **门的"覆盖面"要按合同逐句配判据 —— "注入过" ≠ "测到了"。** 本轮 lane4 缺陷逃逸，
   **不是"没注入 lane4"**（单元门里**有** lane4 用例），真因是**那几条判据没有判别力**：
   `rx_sop_ok = (rx_wcnt===0)` 只查 `tuser` 落在第 0 字、**不查 `tkeep`**，另三条查字节数/`tcrs`/`terr`
   在 lane4 下**也全部成立** ⇒ **门绿了，而合同 `mac_rx_10g.v:12`「帧首字总是满对齐」一条判据都没有**。
   **比"只注入 lane0"更隐蔽。** 补法 = 对着**合同原文**逐句配（本案：链级门 80→106），
   再用**换回缺陷版 RTL** 做反例双跑（**106/12 fail 且 12 条全在新族、既有 80 条一条不红**）。
   ⚠️ 另一形态：**只注入默认的物理模态（lane0）也不够** —— 10GBASE-R 的 `/S/` 实际只落 **lane0 与 lane4**。
2. **"判据修好了" ≠ "现象变好了" —— 报告里必须分开写。** 闸 4 三轮里 3 条 FAIL 的消失，
   **2 条是"判据改了"（`T_RUN` 拆分 / `N_SELF` 加容差）、1 条是"判据修好了、首次真的被评估"（`N_XCHK`），
   没有一条是现象变好**；`C8` 更是**判据一字未改、原样 FAIL**。混着写会把"口径调整"读成"设计进步"。
3. **守卫写错了会静默地"从不评估"**：`if [ -n "${NQ_NC+x}" ]` 对 **关联数组**只测下标 `0`，
   而键是 `port_rx_good` 这类非数字串 ⇒ **恒为空** ⇒ `if` 永远为假。旁证：两轮验收日志 `grep -c XCHK` = **0**
   ⇒ "上一轮 N_XCHK SKIP（ΔW20=0）"这个说法**也不成立**（当时同样从未评估）。
   ⇒ **判据要能自证"我真的跑过了"**（有判据行、有分母、有 `gen` 恰好 +1 之类的凭据）。
4. **"硬件计数"未必是独立口径 —— 先核实它是不是另一条的复制品。** `ethtool -S` 的 `port_rx_*` / `port_tx_*`
   与内核 `rx_packets`/`tx_*` **逐字相同**（同一来源报两遍）；再叠加**参考侧更新量子 ≈1 s**
   （同长 4 s 窗给出 ±0.7~1.0 s 的整档差）⇒ **拿它做"偏差 <1%"的判据结构性不成立**
   （这也解释了报告里 0.4%~24.5% 的"偏差"）。**独立口径 = pcap 时间戳**（抓包点在**驱动队列**，
   三条不同消费者路径 + 逐帧时间戳，无刷新量子）。
5. **时间基里的"陈旧锁存值 + 当前时间戳"会给出系统性高估的频率。** `freq_check()` 的伪影顺序
   （`a=rd → t1=date → snap_take → b=rd → t2=date`，分母取 `t2−t1`）让分子分母量**两个不同区间**
   ⇒ 真板上倍率 `Δt_真/Δt_测` 是 1.88× / 2.97× 这类**非 2 的怪值**（⚠️ **"没看到恰好 2×"不能当证明**）。
   ⇒ **每个采样点必须自证是"新一代"**（触发 → 断言 `gen` 恰好 +1 → 再打时间戳）。
6. **同 flow 的构建是确定性的，不存在"随机抖动"。** `S_fix / S_fix2 / C_fix_explore` 三次构建
   **WNS / 级数 / logic·net 延迟逐位相同**；归档 `+0.285` vs 我的 `+0.749`（**同一份 RTL**）
   差异来自 **strategy 没对齐**，不是随机。⇒ **不要用"抖动"解释回归**，先核实两次跑的 strategy 是否同一个。
   ⚠️ 配套：**时钟组名后缀（`_2/_3`）会跨轮变** ⇒ 跨轮对比**必须按端点指纹对齐**。
7. **换 strategy 能撼动失败端点，但方向不可控且不解决因果 —— 它不是修复。** 实测：同设计同 RTL
   只换 strategy，TX 域 slack 摆动 **0.197 ns（忠实探针）/ 0.464 ns（端口探针）**，
   而 39 条失败端点的 slack 区间是 −0.173…−0.003（**均值仅 −0.075**）⇒ 摆动**确实足以**把它们推过零；
   但 `Performance_ExtraTimingOpt` 在这里**比默认策略差 0.464 ns**（与名字的暗示相反），且不改变
   "pad 修复把这条链从 10 级拉到 18 级"这个事实。⇒ **先吃确定性收益（+0.478 ns），再叠 strategy 搜索。**
8. **哑门的账远不止已知的那两条。** 本轮又实测出 **6 条**（`d2_suite` / `p5c_rev_elab` / `f4_sttrace` /
   `p4_replay` / `p4indm_4gates` / `p7b_impl_one`），其中 **`p5c_rev_elab` 的哑门掩盖了一个既存 elab 硬失败**；
   `p4indm_4gates` 是 **cmd 语法串进 bash**（`%REPO_ROOT%`）的真空门残留。
   ⇒ **"跑门"必须配"判门"**：读日志尾 / 读判据行，别只看退出码。
9. **面板/台架的量测公式本身会错（不只是"什么都没做"）。** 本轮抓到两条同族：
   ① 频率那一条（教训 5）；② **pcap 时间戳是"批量打戳"的** —— 同一条流 3000 条记录只有 **555 个不同时间戳**，
   每个时间戳挂 2~8 条**内容不同**的帧 ⇒ **帧间隔分布不可用**（中位数读到 0，看着像"重复副本"）。
   ⭐ **但"记录数 = 不同载荷数"（3000/3000，零重复）已自证没有副本** ⇒ **端点跨度口径仍然有效**。
   ⇒ 口径 = **端点跨度 + 去重自证，禁用间隔分布**（已写进 `pcap_rate.py` / `f3_check.py` 的注释）。
10. **修法会改变拍对齐 ⇒ 依赖"拍数不变"的旧论证会失效，且必须显式说。** lane4 修复给 lane4 帧**加了 1 拍**
    ⇒ `P7B_EVIDENCE_AUDIT.md` §B.3.1 理由 #1 失效。**反过来这是一条新判据**：修后 `(a)→(b)` 段
    对 lane0 = 4 拍、对 lane4 = 5 拍 ⇒ **复跑取数即可判定样本里有没有 lane4 帧**。
11. **"原件可复现性"是一种资产，值一次"不修"。** 厂商 example 的 FCS 缺陷**建议不修**：
    闸 1/闸 2 的价值在于"板级读数 ↔ 未改一行的厂商明文源码"这条链；一旦动了 CRC 行，
    `P7B_GATE1.md:647` 的 sha256 溯源与两份板级副本的对应关系就断了，**下一个排查的人会失去唯一的对照件**。

### ④ 现状 / 未核实（别记错）

- **板上现载位流 = 闸 4 第三轮的验收位流**（sha256 `0e1c8088…b557`，**本轮只烧 1 次**）；
  `gen=33`；链路在、`W3`=0、`W39 = 0x2000100C`。⚠️ **peer 表里有对端条目 ⇒ 板子仍在发图案流**
  （`W8/W20` 持续增长，~1.29 Gbps 线上，~106 kfps）。
- **PCIe 观测通道活着**（本轮最后没有再烧录）⇒ 下一轮**可以直接读板侧**，不需要"烧 → 重启"那一套。
  **判活仍按 BAR 读**（`0x00 == 0x50360001`），不看 `lspci`。
- **对端机**：网络配置**已复原**（`enp1s0f1np1` 无 IPv4、无 `192.168.100.*` 路由）；`/tmp` 里本轮 pcap/脚本已删；
  `hw_server` active。
- **工作区状态**：本轮所有改动**未提交**（HEAD = `f86b07f`）；`board/wrapper_p4.v` 的改动是**别人的注释订正**
  （TX_DIS 写地址 `0x10 → 0x08`，闸 4 相关），本轮判据**锚在位流 sha256** 上 ⇒ 不受影响。
- ⚠️ **`P7B_LATENCY.md` 的样本代表性**：**未核实**（要靠修好后复跑同一套取数做 A/B；
  拍数**预计可留用**，但这是预期不是读数）。
- ⚠️ **`P7B_MAC_DESIGN.md` 的 U3 已由"未核实"升级为"已核实（板上确实发生）"**；
  `:348` 第 4 行的"验收"口径偏松（验了内容与首字节位置，**未验 `tkeep` 合同**），引用时别当合同已被验。
- ⚠️ **本轮之后** `p7b_ku5p` 的三条硬门仍是 **banner 不是退出码**（见 ②-⑦），且**看不到 IP OOC run 日志** ——
  别把"bat 没报错"当"门通过了"。

### ⑤ 未结项（**别写成已完成**）

- **`C8` 判据仍 FAIL**：`pcs_vcc_cyc` **8 位饱和** ⇒ "在涨"不可判；**判据一字未改、非设计缺陷**。
  收口 = 改判据形式（饱和即下界证据）**或**重建时把该计数加宽到 **≥16 位**。
- **10G 线速未达标（产品级第一优先）**：app 发生器 **1 字节/拍** ⇒ 实测载荷 **1.248 Gbps** / 线上 **1.287 Gbps**
  = 10G 线速的 **~12.5%**。修法 = **8 路并行**（TX 发生器与 RX 校验器**必须同批改**）。
  ⚠️ 闸 1（9,999.94 Mbps）与闸 2 的 NIC link **只证明链路/物理层**能到 10G，**数据面端到端从未跑过线速**。
- **F5 的 2 处未测**：① TCP RX 载荷逐字节（本构建 app 是 UDP 版，TCP 载荷**没有消费者**）；
  ② RTO/重传计数 —— `tx_stat_retx` **不在 51 字窗口内 ⇒ 结构性不可读**。
- **lane4 的"+1 拍"双模态在 51 字内不可观测**（没有任何一字统计"每帧拍数 / lane4 命中数"）。
- ~~`p4_rxclass` / `p4_rxclass_xk` 真回归未收口~~ ⇒ ✅ **已收口**（`P7B_GATE_HARNESS_FIX.md`；见 ②-④）。
- **21 个既存失败门 + 8 个哑门**：**8 个哑门里 3 条已修**（`p5c_rev_elab` / `p4_replay` / `p4indm_4gates`，见 ②-④），
  其余 5 条（`p4_matrix16` 自带汇总 / `d2_suite` / `f4_sttrace` / `p7b_impl_one` / `p7b_impl_xvlog_all`）**未改**；
  **21 个既存失败门一条未修**。⚠️ 两条已修门脚本在 `.gitignore` 里 ⇒ **放行处理中**。
- **厂商 example 的 FCS 缺陷不修**（理由见 ②-⑦ / 教训 11）；**10 条 `Synth 8-11241` 在厂商例程里、不误伤**。
- **`P7B_LATENCY.md` 的样本代表性**待 A/B 复跑确认；**`P7B_LATENCY_GAPS.md` 的两个缺口**未闭合
  （(d) 缺 root + 一个 IPv4/UDP 帧；fast→app 队列缺探针 + 重建）。
- **`L_PCS` 零读数**（PCS/PHY 内部那段完全没测 = **最大延迟缺口**）—— 补它需要第二轮构建开
  `C_ADD_GT_CNTRL_STS_PORTS` + 从 `generate_target example` 抄 45 个 GT 控制输入。
  ⚠️ **`P7B_VENDOR_EXAMPLE_DEFECTS.md` 已登记：厂商例程里 `assign ctl_local_loopback = 1'b1` 是死的，照抄拿不到 GT 环回。**
- **激励工具在 10G app 速率下结构性不可用**（`SO_RCVBUF` 8 MB ≈ 1662 帧 + 64 KB 重同步窗 = 线上 0.42 ms
  + `pat` 不重锚 ⇒ 级联 3.5 s/帧；收包率 0.091%）—— **验收能力 Gap，非板子**。
- **`g_hw.clk_out0` 端点 131794 → 131435、CLB 寄存器 68689 → 68471 的具体来源未逐条追查**
  （两次 RTL 改动都**不在**该域）⇒ 归工具侧漂移，**不影响收敛判定**；未做 `report_clock_utilization`
  ⇒ 未能点名第 5 个 `BUFGCE` 驱动哪条网（要收口结论就是最省事的下一个探针）。

## 2026-09-30 P7b RATE 里程碑: **10G 线速达标** (两刀: 8 路并行发生器 + 组帧器乒乓重叠)

> **归档索引**（本节是里程碑日志；逐条判据、原始读数与复现命令在别处，别在这里找）：
> **`_proj_10g/notes/P7B_RATE_RESULT.md`**（⭐ **板级测量原件**：判据表 / 四项差分账 / 两条负对照 / 未测清单 / 停板步骤）·
> `P7B_RATE_MEASURE_PLAN.md`（测量方案：主判据 / 独立口径 / 负对照 / Runbook）·
> `P7B_RATE_BOTTLENECK.md`（瓶颈定位：`app_udp_pattern` **1474 拍/帧 = 1.248 Gbps**，与板侧 `W20` 吻合 **0.0002%**）·
> `P7B_RATE_DATAPATH.md`（独立核算：单流 4.84 / **双流 9.51 Gbps**；`P_udp = 2⌈plen/8⌉+12`）·
> `P7B_RATE_8WAY.md`（第一刀：发生器/校验器 8 字节/拍 + **逐字节等价五重证据**）·
> `P7B_RATE_FRAMER.md`（第二刀：组帧器乒乓，378→191 拍，`o_busy` **只变一处**）·
> **`P7B_RATE_BUILD.md`**（合并构建 `WNS +0.136 / 三类失败端点全 0`，位流 sha256 `4eeb0f5f…3133`）。
> **本轮提交**：**尚未提交** —— 两份 RTL 改动 + `board/build_p7b_ku5p.tcl` 的 define + 七份笔记仍在工作区。

### ① 一句话

**10G 线速达标。** 两刀 —— ① **8 路并行图案发生器**
（`rtl/app_udp_pattern.v`，包在**既有宏 `P7B_10G`** 内，`M^k` 常量 XOR 网，发生器 **1474 → 186 拍/帧**；
TX 发生器与 RX 校验器**同批改**）② **组帧器乒乓重叠**
（`rtl/udp_tx_frame.v`，**新宏 `UDP_TX_OVL`**，**378 → 191 拍/帧**）—— 落地后
**主判据（板内自洽、不依赖主机墙钟）`ΔW20/(ΔW5/156.25e6)` = 813,794.7 fps**，
**线上载荷 9.531 Gbps（最保守口径）= 同几何上限 9.569 的 99.61% · 达标界 6.8 Gbps 的 ×1.402**。
**产品级第一优先（10G 线速未达标）由此关闭。**

### ② 关键读数（逐条带出处）

**① 主判据与三维互证（`P7B_RATE_RESULT.md` §1）**

- **四层守卫全过**（缺一层整轮作废）：`MAGIC/BID/MARKER` 八块快照逐字相同 · 51 字下标连续无重复 ·
  `gen` 17 次触发**每次恰好 +1** · 同配置四轮 `fps` 极差 **2×10⁻⁶ 相对**（判据要求 ≤1%）。
- **主判据**：`ΔW20/(ΔW5/156.25e6)` = **813,794.7 fps**（R1/R2/R3/**L20** 四轮**逐字一致**到 0.0003%；
  优于计划期望 808,579 的 **+0.65%**）。**交叉判据**：FE 域 813,794.7 vs DP 域 813,797.4 ⇒
  差 **+0.0003%** ⇒ **三域同频自证成立**。
- **辅助判据**：拍/帧 `ΔW43/ΔW20` = **192.000**（四轮逐字一致）· `ΔW8−ΔW20` = 0（2.5 s 窗）·
  `ΔW21/ΔW41/ΔW42` = **0/0/0** · ⛔ ~~`ΔW13`（图案失配）= **0**（四个测量窗内零增长）~~ ⇒ **空判据，未参与比对**
  （四窗 app RX 零流量：`ΔW10=ΔW11=ΔW12=0`，`W13` 窗内**一次都没比**；`P7B_W13_AUDIT.md` §②-V3）· `ΔW9/ΔW20` = **1472.000**。
- ⭐ **达标结论对口径免疫**（防"拿口径给板子开脱"）：线上载荷（1464 B，**最保守**）9.531 Gbps /
  `W9` 口径（1472 B）9.583 / 线上（帧+前导）9.883 = 10 Gbps 的 98.83% /
  ~~**XGMII 占空（`fps×192/156.25e6`）99.9991%**（每拍都有字，无多余空拍）~~ ⇒ ⛔ **2026-10-10 订正（口径）**：
  该式 ≡ `192/P`，而 `W43` **每拍无条件 +1**（`_proj_10g/p7b_mac/rtl/mac_tx_10g.v:330`，在 `case (state)` 之外）
  ⇒ `P ≡ 156.25e6/fps` ⇒ **它只是"帧率 = 几何帧率"的换算式，不是线占空测量**；"每拍都有字"是 XGMII 接口定义
  （每拍恒发 8 字符）、"无多余空拍"是未测的转写（板侧**没有**线占空计数器）⇒ **该短语作废**；速率/帧率读数与达标结论保留。

**② 两刀的两条独立证据 + 落点（`P7B_RATE_{8WAY,FRAMER,BUILD}.md`）**

- 仿真：发生器单独 **1474 → 186 拍/帧**（7.92×，天花板 9.89 Gbps **高于** 10G 线速载荷上限 9.571）·
  板级同构全链 **1470.6~1477.8 → 377.834 拍/帧**（3.90×）· 帧器单独 **378 → 191 拍** /
  帧器+arb+MAC **379 → 193 拍**（1.96×）；**193 拍 ≈ `mac_tx_10g` 自身天花板 193.24** ⇒ **接棒瓶颈按预测换成 MAC**。
- 逐字节等价（不是近似）：发生器侧 **14 个 dump 文件 `fc /b` 全同**（7 配置 × 2 构建 + 回环 + 注入，
  含非 8 倍数尾字 / >`PLEN_MAX` 冻结 / 限速 / 有限会话）；帧器侧 **51 帧线上帧流 `fc /b` FRAMES-IDENTICAL**。
  **五重证据**：① 源码级预处理器等价证明（无 `P7B_10G` ⇒ 与改动前**逐字节相同**）·
  ② `peer.exe` oracle · ③ Python 重写递推 · ④ xsim 两构建 dump · ⑤ 既有 `p5e_udp pos` 门的**线上捕获**模型。
- 宏的边界：两刀**各自包在已有/新增宏内**（`P7B_10G` 内 274 insertions/0 deletions；
  `UDP_TX_OVL` 内 343 insertions/0 deletions）⇒ **默认构建逐位不变**；P4 矩阵 16/16 EXIT=0 + `FROZEN`。
- ⭐ **构建（`P7B_RATE_BUILD.md`）**：`board/build_p7b_ku5p.tcl:145` 的 `verilog_define` 追加 **`UDP_TX_OVL=1`**
  （**既有的 `APP_MODE/DEV_USP/PCIE_OBS/DP_156MHZ/P7B_10G` 五个宏一字未动**），并加一行只读回显
  ⇒ `P7B_VERILOG_DEFINE = … UDP_TX_OVL=1`（`board/p7b_ku5p_stdout.txt:270`）。
  **宏生效的直接证据**：网表里同时出现 `u_fifo_a`/`u_fifo_b`（只存在于 `UDP_TX_OVL` 分支）。
  ⚠️ **`UDP_TX_OVL` 只在 `board/build_p7b_ku5p.tcl` 这一个构建里打开**；**关掉它就回到 HEAD 的帧器行为**
  （`ifdef` 的默认分支逐字保留，**343 insertions / 0 deletions**）—— 这一点必须写死，别把它当成全局已改。
  **时序 `WNS +0.136 / WHS +0.010 / 三类失败端点全 0`**；位流 15,431,261 B，sha256 `4eeb0f5f…3133`。
  ⚠️ **位流大小与上一版逐字节相同是巧合、sha256 不同**。⚠️ 最薄处 = `txoutclk_out[0]_3` **+0.141**
  （归因布局漂移，路径里无本轮新逻辑；**加逻辑前先看它**）。

**③ 口径定案：计划书错、板子对（三个独立仪器）**

- 测量计划 §2.2 假设 **载荷 1472 / 线长 1518 / 193.24 拍**；实测三个**互相独立**的仪器给同一套几何：
  **① pcap 逐帧**（40/40 帧长度集合 `{1506}`，`-s 0` 无截断：`udp_len=1472` ⇒ **载荷 1464**，含 FCS 线长 **1510**）·
  **② 对端 NIC** `Δport_rx_good_bytes/Δport_rx_good` = **1510.0000**（四轮逐字相同）·
  **③ 板侧** `W43/W20` = **192.000**（= 1 前导 + 190 内容 + 2 IFG，IFG 16 B ≥ 802.3 的 12 B ✓）。
- ⇒ 计划里按 1472 口径写的 `A1` 与 `B0-2` **按原口径 FAIL，而根因在口径**；
  **读数本身没有任何一项显示板子有问题**。**"硬上界 9.571"这条反向判据按设计工作了**（它正确报出"口径错"）。

**④ 四项差分账：板子清白（`P7B_RATE_RESULT.md` §2）**

- 20 s 窗：`d_board = ΔW20 = 16,284,789` vs `d_dma = Δrx-0.rx_packets = 16,252,460` ⇒ **比值 0.99802（−0.20%）**；
  2.5 s 窗 ±0.7%。**`Δrx_eth_crc_err = Δport_rx_bad = Δport_rx_overflow = 0`（四轮全 0）**，
  `nodesc_drops` 只占 0.27%。
  ⇒ 按计划 §8-R1 判别树走"**全链对账 ⇒ 最强结论**"一档 ⇒ **"对端吃不下"这个头号担忧被实测推翻**。

**⑤ 负对照 N-a（零重建，`P7B_RATE_RESULT.md` §5）**

- 写 `0x08 = 0x2`（拉 `TX_DIS`）⇒ 读回 `0x00000002` · 对端 `carrier 1→0`/`operstate up→down` ·
  **静默窗内 `Δport_rx_packets = 0`**（且 `rx-0`/`bytes`/`nodesc_drops`/`crc`/`bad` 同时全 0 ⇒ 对端口径**有牙**）。
- ⭐ **同窗 `ΔW20` = 4,095,125 / 5.032 s = 813,802 fps —— 仍在满速** ⇒ **两条口径的独立性被直接证明**
  （板子在**空发**（内部满速），对端**一无所知**）。恢复后对照窗 `Δrx-0/ΔW20 = 0.998`。
- 侧录：掉链过渡在线上留了 **1 个 CRC 错**（`rx_eth_crc_err 0→1`）—— 截断帧的**应然**产物 ⇒ 反向证明负对照作用到了线上。

### ③ 教训（5 条）

1. ⭐ **`port_rx_*` 是 ~1.2 s 刷新的快照，不是连续计数器。** 以 **0.204 s** 间隔连采 16 次：
   `port_rx_packets` **连续 5–6 次逐字不变后阶跃 +813k**（量子/窗宽 ≈ **48%**）⇒ **短窗速率裁决结构性不可达**；
   `rx-0.rx_packets` **才是连续可读**的（0.1 s 稳定 +84,000 ⇒ ~840 kfps）。**"MAC 计数与板侧 ±0.5% 对账"
   这条判据形态本身要改**（不是把容差放宽）—— 它解释了同配置三轮给出 `d_mac/d_board` = 0.914 / 1.312 / 0.796。
2. ⭐ **量测方案书自己会错 —— "计划口径按 1472 写、实测 1464"。** 计划书的 1472/1518/193.24 与实测
   1464/1510/192.00 都在**同一个量级**上，肉眼不可分辨 ⇒ **必须有"用独立仪器定案口径"这一步**（本轮 = 40 B 的 pcap + NIC 字节计数 + 板侧拍数，三方互证）。
   ⇒ 判据按原口径 FAIL 时，**先问"分母对不对"**（计划书那条"两个都错 ⇒ 先查守卫"的规则按次序执行过：四层守卫先全过，再查口径）。
   ⛔ **本条已被下一节（P7b BIZ，2026-09-30）推翻** —— **计划书的口径才是对的（1472 / 1518），当时错的是板子**：
   实测的 1464/1510/192.00 是 `app_udp_pattern` 写门一拍错位（**每帧静默丢 1 整字 = 8 B**）的**后果**。
   ⇒ 本条只保留方法论的一半："**要有独立仪器定案口径**"**不足以**保证正确 —— 还要追问
   "**这几台仪器是不是都穿过了同一条缺陷路径**"（= 下一节 §③ 教训 1「一致 ≠ 正确」）。
3. **"改了口径"与"修好了"必须分开写。** 本轮 `A1`/`B0-2`/`N_SELF` 三条 FAIL 的去向**全是口径/编排**，
   **没有一条是现象变好**；同时 `9.583 Gbps` 越界读数**只是 `W9` 口径**，不是线上载荷。
4. **负对照的最强形态 = "一侧归零、另一侧仍满速"。** 拉 `TX_DIS` 后对端全 0 而**同窗板侧仍 813,802 fps**
   ⇒ 直接证明两条口径**测的不是同一个东西**（比"两边都变小了"有力得多）。侧录的 1 个 CRC 错是**应然产物**，反向佐证负对照确实作用到了线上。
5. **锁存后先读 NIC、再 dump 51 字**：快照是**锁存**的，读回耗时（dump 实测 0.104~0.115 s）不改变锁存时刻
   ⇒ 可把 NIC 采样压到锁存外 **5~14 ms**（宽度偏置仅 +0.06%~0.59%）。这是"四项差分账"可信的编排前提。

### ④ 现状 / 未结项（**别写成已完成**）

- ⚠️ **板子已停**（`P7B_RATE_RESULT.md` §8 两步：先拉 `TX_DIS` 保底 → 再重烧同一位流 ⇒ peer 表清空 ⇒
  TX 门关 ⇒ **零帧**；`pcie_scratch` 复位 ⇒ **`TX_DIS` 已释放、对端 carrier=1/operstate=up/speed=10000**）。
  ⚠️ **PCIe 观测窗口暂不可读**（重烧后端点需主机 POST 才枚举）⇒ 要读板侧得走
  "**先烧位流 → 再重启对端机**"的次序。⚠️ 这个状态与上一节收尾的"仍在发流"**不同**。
- ⚠️ **4 项未测（不许当通过）**：① **RX 方向载荷逐字节**（板侧校验器对线上图案）；② **工具自报的"图案真失配"**
  （未采信、也未否定 —— 工具在 10G 速率下结构性不可用，其退出码**不得**当板子证据）；③ **`N-b1`（`TX_GAP` 低速档）**；
  ④ **`W9` 与线上差 8 B/帧的 RTL 定位**（`rtl/udp_tx_frame.v:271/:568` 的 `udp_len <= plen_n + 8` 与
  wrapper 的 `i_paylen = 12'd1472` 指向 1480，而线上是 1472 ⇒ **中间路径有 8 B/帧的差，未定位**）。
- ⚠️ **一处"已知红"未处置**：`sim/p5e_udp pos` 的 `CHK_65`（"P④ 突发确实溢出丢帧"）在 **wide 构建**下变红
  —— **判据前提被"app 消费 8 B/拍 > 前端 1 B/拍"推翻，不是设计缺陷**（同一次运行里 8 帧全交付、零失配）。
  默认构建不受影响；**处置属该门 owner**（`P7B_RATE_8WAY.md` §4.1 给了建议改法）。
- ⚠️ **对端机现状**：`enp1s0f1np1` 的 `192.168.100.100/32` + `/32` 路由**仍在（未回滚）**，
  但会被 NetworkManager 静默冲掉 ⇒ **每次发送前现取 `ip route get 192.168.100.2`**；
  驱动是**手工 insmod 的 out-of-tree 版**（`modprobe` 取到 in-tree DMAEngine 版、**不提供 `/dev/xdma*`**）。
- ⚠️ **本轮未做**：N-b1 低速档（需 2 次构建 + 2 次重启 ~1.5 h）· `C8` 等 PCS 状态字未读 · 复测轮数止于 4 轮。

> ⛔ **本节 §③「口径定案：计划书错、板子对」**及其 **§③ 教训 2「量测方案书自己会错」**（该教训推的是同一个结论）
> **已被下一节（P7b BIZ）推翻**（2026-09-30）：
> 那三个"独立仪器"量的是**同一个缺陷**（`app_udp_pattern` 每帧静默丢 1 整字 = 8 B）的后果
> ⇒ **载荷 1464 / 线长 1510 / 192.00 不是设计真值**，`A1`/`B0-2` 本来就该 FAIL。
> ⚠️ **本节的线速结论（813,794.7 fps / 9.531 Gbps 最保守口径）不受影响**（它不依赖载荷字节数）。
> 订正详情见下一节的 §③ 与 `_proj_10g/notes/P7B_HANDOFF.md` §2「RATE 轮口径订正」。

## 2026-09-30 P7b BIZ 里程碑: 业务实测 + 一个"每帧静默丢 8 B"的真缺陷 (修复 + 两个同族潜伏) + 观测面 61 字 + 一条历史判据降级

> **归档索引**（本节是里程碑日志；逐条判据、原始读数与复现命令在别处，别在这里找）：
> **`_proj_10g/notes/P7B_BIZ_PLAN.md`**（本轮计划与判据表）·
> **`P7B_W9_{GAP,GAP_VERIFY,FIX}.md`**（那个真缺陷：定案 → 复核 → 修复 + 归零 + 同类普查）·
> **`P7B_LATENT_FIFO_FIX.md`**（两个同族潜伏实例）· **`P7B_GATE_COV_FIX.md`**（门为什么当时看不见它）·
> **`P7B_BIZ_WINDOW.md`**（观测面 51 → 61 字）· **`P7B_BIZ_BUILD.md`**（合并构建 + 时序）·
> **`P7B_BIZ_S1.md`**（Stage 0/1 业务实测）· **`P7B_BIZ_S2.md`**（Stage 2 受阻 + 恢复清单）·
> **`P7B_BIZ_REGRESSION.md`**（仿真回归）· **`P7B_W13_AUDIT.md`** + `P7B_DOC_CORRECTIONS.md`（空判据审计与订正）·
> **`P7B_BRAM_REPORT.md`** + 四路分路件（BRAM 研究报告）· `P7B_PCIE_RESCAN_RECOVERY.md`（PCIe 端点恢复配方）。
> **本轮提交**：**尚未提交**（HEAD = `d417589` = RATE 轮；BIZ 轮的 6 个已跟踪文件 + 19 份新笔记仍在工作区）。

### ① 一句话

**本轮抓到一个"藏了一整轮"的真缺陷并修掉，顺手收掉两个同族潜伏实例**：
`rtl/app_udp_pattern.v` 的 TX 字 FIFO 写口 **`txf_wr` 是寄存器（下拍落笔），却拿本拍 `txf_full` 做空间门**
⇒ `P7B_10G`（8 B/拍）下**每帧静默丢 1 个整字（8 B）**，线上 1510 / `udp_len` 1472（意图 1518 / 1480）。
**只由 `P7B_10G` 触发**，与 `UDP_TX_OVL` 无关；1G 时代 app 比帧器慢 8 倍 ⇒ **永不暴露**。
同轮：**观测面 51 → 61 字**（`BUILD_ID_V` 7 → 8）· **业务实测 Stage 0/1 完成、Stage 2 因对端机硬件故障全部未测** ·
**仿真回归 11 入口 / 25 门 / 30 次执行全 EXIT=0、真回归 0 条** · **BRAM 研究报告（348/480 = 72.50%，URAM 全空）** ·
**`W13` 空判据审计 ⇒ 一条已发布判据 `A4` 从 PASS 降级为"未测（空判据）"**。

### ② 关键读数（逐条带出处）

**① 缺陷本体与修复（`P7B_W9_FIX.md`）**

- **形态**：写口 `.wr(txf_wr && !txf_full)` 用**本拍** `full` 做空间门，而 `txf_wr` 是寄存器 ⇒ **一拍错位**；
  又被**先行 AND** 进 `.wr()` ⇒ FIFO 内部的 `ovf_pulse = wr && full` **结构性恒 0** ⇒ **丢字无任何计数器可见**。
- **丢失是"帧中间挖洞"不是截尾**：线上载荷 = 图案流 `[0..583] ++ [592..1471]`（后段 **880 B**；`584+880 = 1464` ✓）
  —— 原始件 = `P7B_W9_GAP_VERIFY.md` §1.3（TB 侧读数 `payload=1464 first_bad=584`，
  `#match@+8=884` ⇒ 后段在 `+8` 偏移上连续）。⚠️ **原写 `[592..1463]` / "后 872 B" 与 `payload=1464` 不自洽**
  （`584+872 = 1456`），2026-09-30 订正。
- **修法**：空间门移到生产者侧，改用合同里的 **`full_next`**（`rtl/fifo_sync.v:6-17`；先例 `rtl/mac_rx_64.v:131`）
  + `.wr()` 不带预 AND + 接出 **`stat_tx_ovf`**（→ 快照字 **W56**）。
- **变异双跑的反向证据（负对照 `ovfctl`）**：只把门退回本拍 `full`、其余保持修复后接线 ⇒
  `ovf_pulse`/`stat_tx_ovf` 读 **54 / 85**，**恰好等于丢字笔数**，且输出流指纹与缺陷版**逐位相同**
  ⇒ **"修好了"与"它本可被看见"两件事被同时证明**（这就是"修完必须让它可见"的实测答案）。
- **归零对账**：修复后 `P7B_10G` 下 `stat_tx_bytes == Σ_landed popc(tkeep)`（差 **0**）、`pushdec == landed`（差 **0**）；
  修前分别是 **432 B / 680 B** 与 **54 / 85 笔**。

**② 两个同族潜伏实例（`P7B_LATENT_FIFO_FIX.md`）**

- `rtl/slow_tx_adp.v` 的 `frame_fifo`（D=512）：慢路径被 `tx_arb` 饿死 ≥33 µs（⛔ 2026-10-10 注: 本条的"饿死"= **有界延迟窗口**；"慢路径会被**无界**饿死"已被板级证伪 —— 见本文件 2026-10-09/10 LONGSEND 节 ④；本条不受影响） ⇒ 占用涨到 511 ⇒
  帧末两笔写落在 `occ=511` 那拍 ⇒ **末字落笔在 `occ=512` 被丢，而该拍 FSM 已回 `T_IDLE`
  ⇒ abort 安全网结构性不触发** ⇒ **帧已 `stat_frames++` 却永不闭合（帧合流）**。
  构造性反例读数（修前 = 变异）：`frames=5 purge=3 words=512 tlasts=4 dangling=1`、`fifo_ovf=1`、**J1/J2/J3 全 FAIL**；
  修后 `frames=4 purge=4 words=385 ... dangling=0`、`fifo_ovf=0`、**三条全 PASS**（`words = 385 + 127` 与复算逐数吻合）。
- `rtl/slow_rx_adp.v` 的 `fifo_sync`（D=2048）：要摸到 2047 需**载荷 ≥1783 B**，而该尺度**没有任何 RTL 守卫**
  （10G MAC 对超长帧 `stat_rx_long++` **后照常交付**）⇒ 窗口 **1784..4096 真实存在**。
  反例（配置 `2100 7 0`）：修前 `popped=2107 first_bad=2048 maxocc=2049 ovf_cyc=1`；修后 `popped=2108 first_bad=-1 maxocc=2048 ovf_cyc=0`（**饱和照样到得了，但不再丢**）。
- ⚠️ **两份"够不着满"的读法都被证伪**：充分条件有**两条**（占用够 **且** 写决定连续两拍），第一轮两份构造都只满足一条
  （均匀 128 字帧给出 `512 = 4×128` **正好整除** ⇒ 丢一格相位；`nb=8` 让 `occ=2047` 恰落在 `P_LOAD` 空拍）。

**③ 观测面 51 → 61 字（`P7B_BIZ_WINDOW.md`）**

- 新增 **W51..W60**（全落 MSB 端 ⇒ **旧字逐项未动**，已由 `check_window.py` 机械核对 + 逐字读回 TB 钉住）：
  `W51/W52`=`app_pattern` 发字节/发帧 · `W53/W54`=`app_pattern` 收字节/**失配** · `W55`=`tcp_tx_frame.stat_retx` ·
  `W56`=`app_udp_pattern.stat_tx_ovf` · `W57/W58`=`o_retx_hi`/`o_retx_active` · `W59/W60`=两个适配器的 `stat_fifo_ovf`。
  **未实现地址 `0xEC → 0x114`**。
- ⭐ **顺带修掉三处"判据结构性无牙"**：① 窗口吃满 56 字上限时读侧 SLVERR 负对照**恒不触发** ⇒
  `ar_word/w_word/r_word` **6→7 位**（上限 56 → 119 字）；② 旧 6 位译码**每 256 B 回绕别名**
  （写 `0x108` 会别名到 SCRATCH = **`TX_DIS` 门**！）⇒ 加宽后 ≥`0x100` 一律 SLVERR；
  ③ `app_pattern`/`slow_*_adp` 的拒写计数只在仿真里可读 ⇒ 接进窗口。

**④ 合并构建（`P7B_BIZ_BUILD.md`）**

- **`WNS +0.136 → +0.077`**（−0.059）/ **WHS +0.010** / **三类失败端点 `0/0/0`**；
  `BUILD_ID_V` **7 → 8**；位流 **sha256 `d20c08c9…5ed5`（15,431,261 B）**，⛔ **未烧**。
- **−0.059 已归因**：全局最差宿端 = `u_pcie_regs/snap_words_r_reg[174]/CLR`（**本轮扩窗的快照阵列 +320 FF**），
  **逻辑级数 0、97.2% 只是布线**；**上轮全局最差是同一族** ⇒ 同族内换最差位，**非新缺陷族**。
  ⚠️ 含义：**再往窗口加字会继续吃这条**（每 +10 字 ≈ +320 FF）。
  ⛔ **2026-10-07 订正（出处 `P7B_WU_TIMING_DELTA.md` §5.3；本条即它逐字点名的 `PORT_NOTES.md:5168-5170`）**：
  **"每 +10 字 ≈ +320 FF" 只数了快照阵列那一份** —— 真实成本 ≈ **96 FF/字**（DP 域 `snap_cdc.hold_b` 32 + pcie 域 `dout_a` 32 + 阵列 `snap_words_r` 32 **三份**）
  ⇒ "每 10 字 +320 FF" 应读作 **总数 ≈ 960 FF/10 字，其中 320 落数据面域**。另两条口径：
  ① 本句说的"这条"**不是数据面 setup 路径** —— 宿端 `u_pcie_regs/snap_words_r_reg[174]/CLR` 是 **pcie 域**的异步复位 Recovery；DP 那条 `+0.147` 是**另一族**；
  ② **WU 构建里窗口一个字没动**（仍 61 字），同族 slack 自己从 **0.077 → 0.496（+0.419）** ⇒ "扩窗必吃 WNS"的**方向不变、幅度大部分由 P&R 重排决定**。⚠️ 下一轮扩窗的可测风险排序：① `async_default` 两族（pcie **0.496** / DP **0.743**）；② 数据面域 FF 数（+32/字）+ 布局压力。
- ⚠️ **两栏 grep 的教训**：`Synth 8-11241` / `undeclared symbol` **主 stdout = 0、4 份 run 日志 = 33**
  （28 在 `pcs64_synth_1`、5 在 `xdma_0_synth_1`，**我们自己的 RTL = 0**）
  ⇒ 那个 bat 的三条硬门**只 grep 主 stdout，且命中不置退出码** ⇒ **对本坑永久瞎**。
- ⚠️ **一条事实订正**：原写「厂商 `pcs64_pkt_gen_mon*.v` 的 10 条已登记不修」—— **本构建里那些文件根本不存在**
  （6 个副本全在闸 1/example 工程，不在 `board/build_p7b_ku5p.tcl` 的导入表里）⇒ **不是被修掉，是构建面里没有。**

**⑤ 业务实测 Stage 0/1（`P7B_BIZ_S1.md`，**旧位流**）**

| 方向 | 实测 | 归因 |
|---|---|---|
| TCP 下行 | **903.7 Mbps/连接**（聚合 893.85） | `app_pattern` TX ~~**1 B/拍**（板侧 78,001 fps = 2,003 拍/帧）~~ ⛔ **2026-10-07 DOCFIX3 订正：TX 实测 = `8 B/10 拍 = 0.8 B/拍`、一帧 `1828 拍 / 1460 B`**（xsim 直测；出处 `P7B_GAP9_TCPAPP_8WAY_DESIGN.md` §1.1；`2003 拍/帧` 的分解（1460+380）两项都不准 ⇒ app 单独上界 **998 Mbps**；`78,001 fps` 为 pace 受限的板级读数、保留） |
| TCP 上行 | **1,073.0 Mbps** | `app_pattern` RX 校验器（实测/预测 **0.966**） |
| UDP 上行 | 板子 **100% 吸收** | 上游**对端**天花板 ~2.8–3.0 Gbps（**CPU1 100% 饱和**） |

- ⭐ **UDP 上行 `2,501,222,400 / 2,501,222,400 = 1.000000` 逐字节相等**（四段每段 `ΔW11_i == S_i`、`ΔW13_i == 0`、`ΣΔW12 = 0`）。
- ⚠️ **瓶颈一个都不在 10G 链路或板内数据面**（`ΔW3=ΔW4=ΔW32-35=ΔW46-49=0`）。
- ⭐ **两条新发现（都未定位）**：**板子每条 TCP 连接多发 ~11.9 个重复 seq 整段**
  （300 连接共 3,572 段 = 载荷 **1.658%**，**对端 NIC 计数证明真在线上**）；
  **2 次非受令 carrier flap**（`carrier_changes` 7→9）。
- ⚠️ **口径警告**：上游"满速"在本台架上只有 ~2.8–3.0 Gbps ⇒ **"板子能不能吃 10G 上行"本轮没答（也答不了）**。

**⑥ ⛔ Stage 2 全部未测（`P7B_BIZ_S2.md`）**

- 阻因 = **对端机 `192.168.0.38` 硬件故障**（19:57–20:49 全程 DOWN；**20:50:56 曾恢复 35 秒**：
  `uptime up 0 min` / `hw_server` LISTEN / `lspci 02:00.0` = `Xilinx 9034` 端点已枚举 / 无 xdma / `/tmp` 已清 ⇒ 20:51:30 再失联）。
  ⇒ **唯一上板路径四条全经它**（JTAG / PCIe 窗口 / 激励 pcap / 板子物理插在它槽里）⇒ **判据一条没跑，不许推断为 PASS**。
- ⚠️ **方法论更正（本轮自踩）**：**Windows `ping` 的退出码不是可达性判据** —— 收到本机产生的
  `无法访问目标主机` 时**仍 `exit 0` 且统计行写"已接收 = 1、丢失 = 0"** ⇒ 先后报出 **3 次假 `PEER_UP`**。
  改用 **TCP connect** + 对扫描器自身做正负对照。
- ⚠️ **`J16` 的判据强度已订正**：`W56 恒 0` **不是**"8 B/帧已修"的正证据（修复前该计数器**结构性恒 0**，
  且旧位流里**根本没有这个字**）⇒ 正证据只能是**几何四仪器 + `ΔW9 == Σ线上载荷`**（后者在缺陷态**必然失败**，差值恰 `8 × 帧数`）。

**⑦ 仿真回归（`P7B_BIZ_REGRESSION.md`）**

- **11 入口 / 25 门 / 30 次执行全部 EXIT=0，真回归 0 条**；矩阵 `16/16 · gates failed: 0 · VERDICT: FROZEN`（237 文件逐字相同）。
- 唯一数字差异 `p5e_rate` 默认档 `stat_tx_bytes` **61112 → 61120（+8 B）**，已**三方 A/B 钉死为门自己的抽样点位移**
  （TB 新增的 `repeat(2) @(posedge clk)`），**线上输出与 12/12 `[pre]` 采样行逐字不变**。
- ⚠️ **未能覆盖的如实标注**：`run_tb_slowrx` / `slowtx` **覆盖不到组②**（`full|occ|ovf` **0 命中**，对缺陷版同样 PASS ⇒
  只提供"零附带损伤"证据）；`stat_tx_ovf` / `stat_fifo_ovf` **没有任何 TB 读它们**（只有板级 `W56/W59/W60`）。

**⑧ `W13` 空判据审计（`P7B_W13_AUDIT.md`）**

- `W13 == 0` 在**没有 RX 流量**的窗口里是**空判据**（`i_en` 门控 + 没喂进 app）⇒
  **`P7B_RATE_RESULT.md` 判据 `A4` 从 `PASS` 降为 `未测（空判据）`**，并删掉"速率裁决窗口内图案流无失配"。
- **全仓 27 处引用逐条裁定**：**只有 BIZ S1（本轮的 2.5 GB）真正喂进去过**；
  ⚠️ 并**撤回一条对 oracle 的错误指控**（`f5b_rx_probe` 的"校验器是真空门" ⇒ 真因是**探针喂的是 TCP 载荷而 app 是 UDP 版**，`ΔW11 = 0`）。
- ⚠️ **不波及**：**10G 线速达标**与**闸 4 的 `PASS=33`** 都不依赖它（它们的支撑是 fps/几何/差分账/认领数/pcap 逐字节）。

**⑨ BRAM 研究报告（`P7B_BRAM_REPORT.md`）**

- **BRAM 348/480 = 72.50%**（R36 317 + R18 62）；**URAM 0/64 完全未用**；LUTRAM 6.66%；**对账差额 0**（三级读数链）。
- ⭐ **三个大块 = 94.5%**（`256+37+36 = 329`；`329/348 = 0.9454`；⚠️ 原写 88.5% **算术不成立**，2026-09-30 订正，
  源头 `P7B_BRAM_{REPORT,INVENTORY}.md` 已同改）：`retx_ram` **256** / HLS `udp_echo` **37** / `xdma_0` **36**；**中间没有任何 4–15 tile 的中块**；
  **其余手写 RTL = 0 tile**（全被推断成分布式 RAM）；`pcs64` = **0**。
- ⭐ **唯一够格迁 URAM 的是 `retx_ram`** ⇒ **348 → 92 tile（72.50% → 19.17%）**，代价 **29–32/64 URAM + 读流水 2→3 级**。
  **Vivado 自己试过并拒绝**（`Synth 8-6793` 原文：`Available pipeline stages = 0, Minimum required pipeline stages = 3`）；
  ⚠️ **不能只加 `ram_style="ultra"`**（已拆成 8 字节 lane × 16 深度片 ⇒ 直接套会炸成 **128 URAM/阵列 = 2 倍全器件**）。
- ⚠️ **BRAM 不是时序/延迟瓶颈，是"面积 + 扇出"项**：实测 95.98 ns 流水里 **BRAM 贡献 = 0 拍**；
  `(e)→HLS` 的 1209 ns 里 BRAM 只占 128 ns，**主项是"1 字节/拍字节播放器"的 1062 ns**。
- ⚠️ **本轮零实验**（用户要求"当前先不动代码"）；⚠️ 本机 Vivado **没装任何 PDF 文档** ⇒ 硬约束由 unisim 原语 + XPM DRC 源码支撑。

### ③ 教训（6 条，本轮新增）

1. ⭐⭐ **"三台独立仪器一致" ≠ 正确 —— 它们可能量的是同一个缺陷。** RATE 轮用三台仪器
   （pcap 逐帧 40/40 · 对端 NIC `Δgood_bytes/Δgood = 1510.0000` · 板侧 `W43/W20 = 192.000`）把
   **1464 / 1510 / 192.00** 定案为"**设计真值**"，并宣布"**错的是计划书，不是板子**"—— 下一轮证明那 8 B/帧
   是 `app_udp_pattern` 写门错位的后果 ⇒ **三台量的是同一个缺陷**。**仪器"独立"要独立在机理上，不是实现上**；
   判据里的"设计真值"必须有一条**能从 RTL 合同独立复算**的路径。⚠️ 那 8 B/帧**早已被自己登记为"未定位"**
   —— **未定位的东西不许升级成"真值"**。
2. ⭐⭐ **"到不了满"只是必要条件，相位才是充分条件。** 同一个"写门一拍错位"形态在本仓里
   **潜伏了三处**（1 真 + 2 潜伏），**两份"够不着满"的论证都被构造性反例证伪**：丢失的充要条件是
   ① 占用 = `D-1` **且** ② 该拍有在飞写 **且** ③ 该拍**本拍还要再决定一笔写** **且** ④ 无 pop。
   ⇒ **"能到满"与"会丢字"是两个独立的量**（实测：旧门 + 到满 2048 + `nb=8` ⇒ **零丢**；改成 `nb=7` ⇒ **丢 1 字节**）。
   ⇒ 凡"占用到不了 D"的论证，都必须**配上一条实测的覆盖率见证**，否则"修好了"与"根本没到过"读数上不可区分。
3. ⭐⭐ **门的"覆盖面"要按**编译集**核，不是按"门跑过"核。** 那条速率门两层都是空的：
   ① **没有任何 cfg 会编到缺陷所在的路径**（`git grep P7B_10G HEAD -- tb/` **全空** ⇒ 8 B/拍那条路**从未被编译过**）；
   ② 判据只有 `findstr "RATE TB DONE"`（**跑完即过**），其余 7 行全是打印 ⇒ 强行编进 `P7B_10G` 后**判据全命中、照样 exit 0**，
   而屏幕上 `mean wire len = 1517`（修好是 1525）**差 8 B 摆着没人判**。
   ⇒ 判据要**逐字照合同写**（本轮 = **逐拍** `txf_wr(T) ⇒ !txf_full(T)`）+ 覆盖率见证 + 变异双跑；
   ⚠️ **非默认档不显式跑就盖不到，且必须登记进常驻矩阵**（否则这条判据等于没加）。
4. ⭐ **"自检计数器结构性恒 0"会把缺陷藏一整轮 —— 修完必须让它在负对照里真的响。**
   `.wr(wr && !full)` 把空间门**预 AND 进写口** ⇒ `ovf_pulse ≡ 0` ⇒ 丢字**无任何计数器可见**。
   修法 = 空间门**移到生产者侧**（`full_next`）+ `.wr()` **不带预 AND** ⇒ 判据一回归，计数器**立刻会响**
   （负对照实测 `54 / 85` **恰好等于丢字笔数**，输出流指纹与缺陷版**逐位相同**）。
   ⚠️ 配套：**"恒 0 型"判据必须自带非空前置** —— `W13` 在**没有 RX 流量**的窗口里是空判据，
   全仓 27 处引用逐条裁定后有 **1 条 `PASS` 降级**。
5. ⭐ **台架/工具会安静地给出**假阳性**（比不响更难发现）。** 本轮三例：① **Windows `ping` 退出码**
   （`无法访问目标主机` 仍 `exit 0` + 统计行写"已接收 = 1" ⇒ **3 次假 `PEER_UP`**）；
   ② **有符号/无符号比较**（`integer f_max <= -1` 作哨兵 ⇒ `-1` 变 4294967295 ⇒ "单元素"判据**结构性永不触发**，
   把修复版判成**假红**）；③ **`full_cyc > 0` 被当成"饱和已覆盖"的充分证据**（见教训 2）。
   ⚠️ 另有一条工具形态：**把 `xvlog` 输出重定向到 `xvlog.log`** = 撞工具自己的默认日志名 ⇒ `Common 17-183`
   句柄冲突 ⇒ **工具根本没跑**，看着像权限问题。
6. ⭐ **窗口扩字会吃时序，而且吃在最难优化的那一族。** 快照窗口 51 → 61 字（+320 FF）⇒ WNS `+0.136 → +0.077`。
   全局最差 = `user_reset/C → u_pcie_regs/snap_words_r_reg[174]/CLR` 的**异步复位 Recovery** 检查：
   **逻辑级数 0、97.2% 只是布线**，源端是厂商 FF ⇒ 机制只能是**复位网扇出/布线变长**
   （上轮全局最差是**同族**另一处快照寄存器，那行还印着 `net (fo=4267, routed)`）
   ⇒ 是"**同族内换了最差那一位**"，不是新缺陷族。⚠️ **含义：再往窗口加字会继续吃这条。**
   ⛔ **2026-10-07 订正（出处 `P7B_WU_TIMING_DELTA.md` §5.3；本条即它逐字点名的 `PORT_NOTES.md:5263`）**：
   ① 本条的**方向成立，幅度口径要改**：那句"这条"指 **pcie 域**快照阵列的异步复位 Recovery（宿端 `snap_words_r_reg[174]/CLR`），**不是**数据面 setup 路径（`0.147` 那条是另一族）；
   ② **WU 构建窗口没动**（仍 61 字），同族 slack 自己从 **0.077 → 0.496（+0.419）** ⇒ **幅度大部分由 P&R 重排决定**（本流程重排幅度 ±0.4–1.3 ns）；
   ③ 扩窗真实成本 ≈ **96 FF/字**（`hold_b`(DP) + `dout_a`(pcie) + 阵列 **三份**）⇒ "每 10 字 +320 FF"只数了阵列那一份，**总数 ≈ 960 FF/10 字（其中 320 落 DP 域）**。
   ④ ⛔ **2026-10-09 位级订正（对上条 ② 的引用口径）**：② 引的"重排幅度 ±0.4–1.3 ns" **= 两个不同网表之间**的位移（BIZ 基线 ↔ WU 构建；17 条样本**全落 pcs64/PCIe-GT/pipe_clk 域**），**不是"同输入重跑"的幅度** —— **同输入重跑 = 位级复现、方差 0**（R0/R1 `cmp -l` 只差 5 字节 `.bit` 头时间戳；C1 vs r6-fix 归档 6 字节头差 + `SW_CRC=da663843` 逐字相同）。本条 ①②③ 的结论不变。见 `P7B_WU_TIMING_DELTA.md` §8 + `p7b_build_longflow/INDEX.txt`。

### ④ 现状 / 未结项（**别写成已完成**）

- ⛔ **对端机 `192.168.0.38` 硬件故障**（开机循环签名）⇒ **所有板级动作阻塞**。恢复后照跑
  `_proj_10g/notes/P7B_BIZ_S2.md` **§8 清单**（含每次重启后必做的四条：`modprobe xdma` ·
  `ip link set enp1s0f1np1 up` · 补 `192.168.100.2/32` 路由 · 核 `carrier`）；
  工具一次到位 = `p7b_biz_tools.tgz` + `s2_setup.sh`。
- ⛔ **新位流未烧**（sha256 `d20c08c9…5ed5`；板上仍是 RATE 版 `4eeb0f5f…3133`）⇒
  `W51..W60`、`BUILD_ID_V=8`、"每帧不再丢 8 B"**都还没有板级读数**。
  板侧前置闸：读 `0x04` 必须 = `0x00000008`、`0x00` = `0x50360001`、`0x14` = `0xdeadbeef`、
  窗口 **61 字**（`0x20..0x110`）、未实现地址 **`0x114`**（必须回 `0xffffffff`），**绝不能挑 ≥ `0x200`**。
- ⚠️ **Stage 2 全部判据未测**（`J0`..`J16`、`N-a`、风险 a/b）—— **不许当通过，也不许推断为 PASS**。
- ⚠️ **两条未定位的板级现象**：每连接 **~11.9 个重复 seq 整段**（3,572 段 = 载荷 1.658%，**真在线上**）·
  **2 次非受令 carrier flap**（`carrier_changes` 7→9）。
- ⚠️ **几条新登记的常驻风险**：`p7b1472` 饱和档**未登记进回归矩阵**（不显式跑就盖不到）·
  `sim/p4indm/run_4gates.bat` 会**覆盖** `sim/p4sim/matrix_p4dfix.log` ·
  `p5e_rate` 默认档的"逐字对照"被 `repeat(2)` 打断 · 组②的潜伏门**没有进任何常驻 runner** ·
  `P7B_10G` 的 **RX 侧无任何 TB 覆盖**（强编出来就撞 `udp_split` 的 BRAM 碰撞，**未做三态判别**）。
- ⚠️ **BRAM 减/换的全部实验本轮未做**（零实验）；**产品输入缺口**：`N_biz`（并发连接数）与目标 RTT
  **需要用户拍板**才能定 `retx_ram` N 与 `WIN_CAP` 的力度。

## 2026-10-06/07 P7b BIZ Stage 2 板级验收 + TCP 上行归因: "每帧丢 8 B"确已修复 + 一个"板从不主动通告窗口"的设计缺陷

> **归档索引**（本节是里程碑日志；逐条判据、原始读数与复现命令在别处，别在这里找）：
> **`_proj_10g/notes/P7B_BIZ_S2.md`**（**§10 起 = Stage 2 执行结果**；§0–§9 是前任的"受阻"记录，保留不改）·
> **`_proj_10g/notes/P7B_BIZ_TCPREG.md`**（TCP 上行退化归因：A/B 判决 / 机理 / 判据 W·X / 4 组速率对照）·
> 原始件 = `_proj_10g/notes/p7b_biz_s2/`（`s2_raw_readouts.txt` 等）· `_proj_10g/notes/p7b_biz_tcpreg/`（两臂 pcap / 窗口分析器 / 各档 run 日志）。
> **下一轮开工先读 = `_proj_10g/notes/P7B_HANDOFF.md`**（已按这两轮重写）。
> **本轮提交**：**尚未提交** —— HEAD = `origin/master` = `1793990`；未提交 = `M _proj_10g/notes/P7B_BIZ_S2.md`（§10+ 追加）+
> `?? _proj_10g/notes/P7B_BIZ_TCPREG.md` + `?? p7b_biz_s2/` + `?? p7b_biz_tcpreg/`。

### ① 一句话

**对端机恢复后，Stage 2 的板级判据跑完了：⭐ `J0` PASS —— "每帧静默丢 8 B"确已在板级修复**（四台仪器 + 最强判别式
`ΔW9 == Σ线上载荷` 全中）；`W55` 定案（**一次回卷重放整段 `[snd_una, snd_nxt]`**，且拿到"对端确实发过 dup-ACK"的包级证据）；
`J12/J13` PASS（`W54` 有牙 = 翻 1 bit 精确计 1）。
⭐ **同时抓到并归因一个产品级设计缺陷**：Stage 2 发现 **TCP 上行从 1,073 Mbps 塌到 4.8–6.2 Mbps**（`J6` FAIL）——
**归因轮的判决性 A/B 证明"不是我们的 RTL"**（从 `d417589` 重建的 RATE 位流**同病**，4.544 vs 4.719 Mbps），
真因 = **窗口"通告"通路的长期弱点**（`app_ctrl` 的 `wu` 两个触发条件**结构性不可达** ⇒ 板**从不主动通告窗口重开**
⇒ 对端只能等 **~208 ms persist 定时器**）⇒ **这块板当前唯一一个已定案的产品级设计缺陷，修法已给出**。

### ② 关键读数（逐条带出处）

**① Stage 2 的 `J0` = "每帧丢 8 B"已修（`P7B_BIZ_S2.md` §10.2 + `p7b_biz_s2/s2_raw_readouts.txt`）**

| 仪器 | 缺陷态（RATE 轮） | **修复后实测** |
|---|---|---|
| pcap 逐帧 `eth/ip_tot/udp_len/载荷` | 1506 / 1492 / 1472 / **1464** | **1514 / 1500 / 1480 / 1472**（300/300 帧） |
| 对端 NIC `Δbytes/Δpkts` | 1510.0000 | **1518.0009** |
| 板侧 `ΔW43/ΔW20`（XGMII 字/帧） | 192.000 | **192.999989** |
| ⭐ **`ΔW9 == Σ线上载荷`** | **不成立**（差 14,974,320 B = `8×帧数`） | **成立**（差 **−168 B = 6.1×10⁻⁸**） |

- 同窗：**`ΔW8 == ΔW20`**（1,871,790 逐数相等 ⇒ 无下游丢弃）、**`W56 = 0`**、所有丢弃计数 0。
- **速率 809,577.9 fps = `156.25e6/193`** ⇒ 线上 **9.8315 Gbps** / 载荷 **9.5336 Gbps**。
- ⚠️ **修复的确定性代价**：帧周期 **192 → 193 拍（−0.52%）** —— 那个字本来就没进 FIFO（帧器少读一个字就快一拍），
  所以是"**把丢掉的补回来**"，不是新缺陷。

**② `W55` 定案：一次回卷 = 重放 `[snd_una, snd_nxt]` 整段（§10.3/§10.3.1）**

- `ΔW55`（回卷次数）= **365 / 374**（两次独立跑） vs pcap `dupseq` = **1,695 / 1,878** ⇒ **平均 4.64 / 5.02 段/回卷**；
  `ΔW15 − 对端 socket 字节 = dupseq × 1460` **两次精确**。
- ⭐ **包级证据**（60 连接双向 pcap）：dup-ACK 三连后 **+42 µs**，板子整段重放 **8 段（11,680 B）**；
  **202/370 条重传紧跟 ≥3 连 dup-ACK**、310/370 紧跟 ≥1 条 ⇒ **RATE 轮"RTO 被排除"的参数推理现在有直接读数背书**。
- ⚠️ **残余（如实登记）**：**对端"第一个 dup-ACK 三连"出现在任何数据被确认之前**（`ack = ISN+1` 连发 3 次；
  60 连接恰 60 个 SYN-ACK）⇒ **根触发在更上游，未定位**。另：**每连接 2 个 FIN**（120/60），未定位。

**③ `J12`/`J13`：`W54` 的"牙"被实测证明（§10.4）**

- `--flip-at -1`（65,536 B 不翻）⇒ `ΔW54 = 0`、`ΔW53 = 65,536` 精确；`--flip-at 32768`（翻 1 bit）⇒ **`ΔW54 = 1` 精确**、
  `ΔW53 = 65,536` 精确 ⇒ **"会响"与"不误报"同时成立**；300 连接下行跑 `ΔW53 = 0`（无假阳性）。

**④ Stage 2 的 A/B 复现 + 上行天花板推高（§10.5/§10.6）**

- TCP 下行 **897.0 Mbps** 聚合 · `J1` 300/300 `-1` · `J2a` 板侧全 0 · **`J2b` 补上**（`Δrx_eth_crc_err = 0`、
  `Δnodesc_drops = 0`；帧数改用 pcap：218,292 vs `ΔW20` 218,296，**差 4 = 窗边界 0.002%**）· `J3` 成立 · `J4` ·
  `J8/J9`（4 段 + 追加 5 段 = **3.41 GB**，每段 `ΔW11 == S`、`ΔW13 = 0`）· **`J8` 负对照 `--skip-at` 可复算** ·
  `J10`（四个精确 1000；8082 NC `ok=0/bad=200`）· `J11` 停板守恒 · **`N-a`**（carrier 1→0→1）。
- ⭐ **4 进程 `taskset` 洪泛 9999**：板侧 **`ΔW0 = 1,769,731`**、线上 **8.38 Gbps**；`ΔW37/ΔW0 = 1514.00` 几何精确、
  板侧丢帧计数全 0 ⇒ **把"板子能吃多快上行"从 ~3 Gbps 推到 8.4 Gbps**。
  ⚠️ 与对端计数差 **0.166%**，落在**对端发送路径**侧、未定位 —— **不许写成"板子丢帧"**。
- ⭐ **UDP 上行叠加在 9.5 Gbps 下行洪流上**：5 段逐段精确、`ΔW13 = 0` ⇒ **双向同时满负荷下 RX 侧仍零错**。

**⑤ TCP 上行归因轮（`P7B_BIZ_TCPREG.md`）**

- **判决性 A/B**：用 `git worktree` 从 `d417589` **重建 RATE 位流**（sha256 `6475c3ba…`；**时序签名
  `WNS +0.136 / WHS +0.010` 与 09-30 逐字一致**；`wrapper_p4.v` / `udp_tx_frame.v` / 构建 tcl 哈希逐条相同）
  ⇒ **RATE 臂 4.544 / BIZ 臂 4.719 Mbps（同病）**；`git diff` 逐处核过 **TCP-8080 快路径 RTL 两臂逐字节相同**。
- **真因（三段）**：① 窗被对端突发（GSO 超级段 29,200/19,584 B）压垮；② **信用在正常回收**
  （pcap `redge = ack + win` 与交付量 **1:1 前进**；板侧 `ΔW53 = 3,538,940` ≈ 对端 `tx_bytes = 3,538,944`，差 **4 B**；
  `ΔW54 = 0`）；③ **缺陷在"通告"** —— `rtl/app_ctrl.v:1109-1122` 的 `wu_pend` 只有两触发：
  **`pb_wscan == 0`（恰好 0）** 与 **`≥ wu_mark + WU_STEP(24576)`**；窗口下界被 app 消费托在 **56–128**（永不触 0）、
  `wu_mark` 初值 = **全池 49152**（要 ≥73728）⇒ **两个都结构性不可达** ⇒ 对端只能等 **`persist`（实测 207.6–207.9 ms）**
  ⇒ 每周期 ~68 KB ⇒ **4.5 Mbps**。⚠️ **现象订正**：不是"单调下降"，是 **~208 ms 周期循环**。
- **判据 W（对端 pcap，不需要新字）**：`redge(t) = ack(t) + win(t)` —— **冻结而 ack 前进 ⇒ 没回收**；
  **与交付 1:1 ⇒ 在回收**。**判据 X（板侧存量字）**：`ΔW53` vs `ΔW22 × 1460` ⇒ 「**消费 ✅ / 回收 ✅ / 通告 ❌**」。
- ⭐ **速率对照 4 组（同板同工具）**：未 pacing **4.5/4.7** ❌ · pacing@**100 MB/s ⇒ 800.1 Mbps ✅** ·
  @160 MB/s ⇒ **13.2** ❌ · @**2^30** ⇒ **4.7** ❌ ⇒ **稳定 ⟺ 发送速率 ≤ app 有效消费率**（今日界 ⊂ (100, 134.2] MB/s）；
  拐点 **knife-edge**（窗平衡点 2.7–3.6 KB ≈ 2–2.5 MSS）。
  ⛔ **2026-10-07 订正（三处口径；4 组读数本身全部有效；独立复核裁定 = `P7B_WU_PACE_AUDIT_VERIFY.md` §2.1/§2.4/§5）**：(a) `--pace-bps` 的**单位 = bytes/s**（对端 `ss` 三档逐字 `pacing_rate 800000000bps / 1280000000bps / 8589934592bps` = 恰 8.000×）⇒ 上面 `2^30` 那条臂按 **8.59 Gbps 的帽**读（该臂今天实测塌陷 `4.719 Mbps`）；(b) 界写 **⊂ (100, 138.9] MB/s**（`134.2` 无出处；结构值 = `0.889 B/拍 × 156.25 MHz = 138.89 MB/s`）；(c) **"knife-edge"被实测证伪**：`PACE=100e6` 档窗全程未关（6 份 pcap 独立重解：`min(win_raw) = 29,584 B = 20 MSS`、`#win<1460` = 0、无 persist 静默段 ⇒ 余量很大；拐点本身未测）。⭐ 正面证据（丙）：`800.186 Mbps` = **pace 帽在位**（`SRC_SUM tx_bytes=600139784 / dur_s=6.000` ⇒ 达成率 `100,023,297/100,000,000 = 1.00023`）、**不是板子容量** —— 该跑不需要"窗口重开通告" ⇒ 与 `wu` 定案**相容且是它的正面证据**。
- ⚠️ **顺带抓到一条归因陷阱**：Stage 1 的 `1,073.043 Mbps` = **`2^30 bps` 的 99.94%**，而**原始件没有 pace 记录**
  ⇒ **很可能量的是工具的帽子**（今天同 pace 照样塌）⇒ **今后 J6 一律把 pace 打进读数**。
  ⛔ **2026-10-07 订正（上面这条"归因陷阱"整条撤回；独立复核裁定 = `P7B_WU_PACE_AUDIT_VERIFY.md` §2.1–§2.7）**：① 单位 = bytes/s（`sock.h:493` 逐字 `unsigned long sk_pacing_rate; /* bytes per second */`；`ss` 三档 = 恰 8.000×）⇒ `2^30` 的真值是 **8.59 Gbps 的帽**（该臂今天实测塌陷 `4.719 Mbps`），**算术上压不到 1.07 Gbps**；② 日志 `tx_MB` 是 **MiB** ⇒ **Stage 1 稳态 = `132.414 MiB/s = 138.85 MB/s = 1,110.8 Mbps`** = `app_pattern` RX 校验器结构值（`8 B/9 拍 × 156.25 MHz = 1,111.1 Mbps`）的 **99.97%**（逐秒 `132.406 / 132.407 / 132.437 / 132.406` MiB/s 与 `8/9×156.25e6/1048576 = 132.4123 MiB/s` 吻合到 5×10⁻⁵；`1,073.043` = 6 s 均值，含一次 **0.2056 s** 停顿，⚠️ 停顿归因不可判）⇒ **"被 app 的 RX 校验器钉死"成立**。⚠️ **"原始件没有 pace 记录"保留为事实**（不许改写成"已记录"）。**制度保留并加强**：判据原文 = `P7B_BIZ_PLAN.md` §4.1b 的「J6-ladder」，pace 值 = 判据的组成部分。

**⑥ 两条环境级配方（都已实测）**

- ⭐ **PCIe 恢复配方扩展**：开机时 FPGA 跑 QSPI 厂商设计（POST 只枚举 **1 个 BAR**）⇒ 父桥 `00:1c.0` 窗按 1 M 定死 ⇒
  烧我们的设计后**设备级 `rescan` 失败**（`BAR 1 can't assign; no space` + `xdma ... probe err -22`）⇒
  **必须连根端口一起 `remove`+`rescan`**（窗重算 2 M）；**同会话内后续重烧只需设备级**。判别式 =
  `identify_bars` 的 **`1 BARs: config 0, user -1` = 厂商 / `2 BARs: config 1, user 0` = 我们的**
  （⚠️ **两者 `lspci` 都报 `10ee:9034`**）。
- ⚠️ **NetworkManager 静默冲掉 `/32`**：表现 = **全部 connect timeout**（极易误判成"板子死了"）⇒
  根治 = `nmcli device set enp1s0f1np1 managed no`；**每次测量前仍要现取** `ip route get 192.168.100.2`。

### ③ 教训（4 条，本轮新增）

1. ⭐⭐ **"被测物的能力"可能其实是"工具的帽子" —— 而原始件里往往没有记录决定它的那个参数。**
   Stage 1 的 `1,073.043 Mbps` = `2^30` 的 **99.94%**，而 pace 值**没有任何留档**；本轮同板同 RTL 的四组对照
   （4.5/4.7 · **800.1** · 13.2 · 4.7）证明**稳定性完全由"发送速率 ≤ 消费率"决定，且边界是 knife-edge**
   （窗平衡点 2.7–3.6 KB ≈ 2–2.5 MSS）⇒ **凡速率读数必须把发送侧 pacing 参数写进同一行**；
   "上轮很好、这轮很差"的**第一嫌疑是参数差异，不是硬件/代码变化**。
   ⛔ **2026-10-07 订正（本条举例作废、教训反向修正；出处 = `P7B_WU_PACE_AUDIT_VERIFY.md` §2.1–§2.7 + §5）**：上面那个实例是错的 —— **Stage 1 的 `1,073.043 Mbps` 不是工具帽子**：单位 = bytes/s（`2^30` = **8.59 Gbps 的帽**）⇒ 算术上压不到 1.07 Gbps；`tx_MB` 是 MiB ⇒ 稳态 = **1,110.8 Mbps = app 天花板（1,111.1 Mbps）的 99.97%**。⇒ "1,073 → 5 Mbps 的退化"里**没有"测试参数"这一分量**（真因 = 板侧 `wu` 通告缺陷）；**"knife-edge"在 `PACE=100e6` 档被实测证伪**（窗地板 `min(win) = 29,584 B = 20 MSS`），拐点本身未测。⭐ **本条教训的正确形态（保留、且更锋利）**：(a) **参数必须记录** —— 这**正是**能把"参数嫌疑"证伪/证实的唯一手段；(b) **"读数贴着 2 的幂"要先查单位**（bytes/s vs bits/s 差 8 倍，恰好能造出"99.94%"这种假巧合）；(c) **真正的"工具的帽子"实例是同轮的 `PACE=100e6` ⇒ `800.186 Mbps`** —— **达成率 `1.00023` × 8.000 的换算关系才是帽子的签名**。
2. ⭐⭐ **把"一个笼统的现象"拆成三段，要用被测件之外的独立量。** 本轮把"TCP 上行慢"拆成
   **消费 / 回收 / 通告**，**一个新字都没加**：用**对端 pcap 里板自己的 ACK 流**构造 `redge = ack + win`
   （冻结 ⇒ 没回收；1:1 ⇒ 在回收），配板侧 `ΔW53` vs 对端 `tx_bytes`（消费账）。
   ⇒ 独立路径不只用来"归因故障在哪一侧"，还能**把一个黑盒内部切成三段、逐个排除**
   （构造性实例化的全局第 2 条）。
3. ⭐ **A/B 判决的前提是"两只手都能重新点火"，而重建件的等价性必须逐条论证、残余如实登记。**
   原 RATE 位流已被后续构建覆盖 ⇒ 只能 `git worktree` 重建；等价性三件套 = **时序签名逐字相同** +
   **相关源文件哈希逐条相同** + **通路审计**（`git diff` 逐处核"改动在不在被测量的通路上"）。
   ⚠️ 残余（`app_udp_pattern.v` 的盘上字节不可复原）**如实写进报告**，措辞只说"不可能解释 200× 的差异"，
   **不说"逐字节相同"**。⚠️ 另一面：**重建件用完即弃**（worktree 已删 ⇒ 再要 A/B 得重建）。
4. ⭐ **环境里会有守护进程安静地撤销你的配置**（同族全局第 41 条）：NetworkManager 把手工 `/32` 地址+路由
   **静默冲掉** ⇒ 表现 = **全部 connect timeout**，**极易误判成"板子死了"**（尤其当对端机刚经历过
   "开机循环"故障时，两个环境问题会互相掩护）。⇒ ① 根治用 `nmcli ... managed no`；
   ② 但**每次测量前仍要现取** `ip route get`；③ 判活**只用 TCP connect**（`ping` 退出码不是可达性判据）。

### ④ 现状 / 未结项（**别写成已完成**）

- ⛔ **TCP 上行仍不达标**：`J6` FAIL 的**归因完成、修复未做**（修法 = 改 `wu_zero` 的武装条件 + `wu_mark` 改基；
  建议同批把 **`app_ctrl.stat_wu`（已存在，寄存器 `0x96`）** 与 `rx_occ_bytes` 接进快照 ⇒ ⚠️ **吃 WNS 余量**）。
- ⚠️ **`W57`/`W58` 全轮 `W58 = 0`**（瞬态 ~15 µs vs 快照几十 ms）⇒ **要高频 `snap` 专打这两个字**；
  `J5`（`ss -ti`）样本太稀；`J15` 未跑；闸 4 的 `F1-E5`/`F1-E6` 两条负对照仍未做；RATE 轮的 `N-b1` 仍未做。
  ⛔ 2026-10-07 订正：`J15` 已作废并并入 `J6-ladder`（上界 `1.111 Gbps`）；出处 `P7B_WU_PACE_AUDIT_VERIFY.md` §4.5 / `P7B_BIZ_PLAN.md` §4.1b。⇒ 这一格（当时 = "未跑"）已由本文件后面的「2026-10-07 P7b WU 窗口通告修复（闭环收口）」节追平：**pace 阶梯已跑**（`(e)/(f)` PASS、**`J6` = 行为层已证实 / 判据层待裁定**（⛔ 2026-10-07 DOCFIX3 订正：原文写 "`J6` = PASS"、已撤回 —— 裁定权在用户），`J15` 已随 J6-ladder 并入）。
- ⚠️ **未定位现象**：对端第一个 dup-ACK 三连的根触发 · 每连接 2 个 FIN · 4 核洪泛 0.166% 帧差 ·
  `dupseq` 11.9 → 5.65 的下降未归因 · 2 次非受令 carrier flap。
- ⚠️ **重建的 RATE 位流 `6475c3ba…` 已随 worktree 一起删除**（全仓无副本）⇒ 再要 A/B 得重建（~22 min）。
- ⚠️ **对端 NIC 的 `mcdi nvram fw.*` rc=-22**（元数据损坏，与数据面无关，是"被动过/送修"的物证）；
  **本机没有第二条 10G 路径** ⇒ "换独立发送路径"这条手段在 10G 尺度上做不了。
- ⚠️ **板上现态 = BIZ 位流 `d20c08c9…`**（末次烧录 2026-10-07 00:12:22；**Stage 2 之前的登记"板上仍是 RATE 版"已作废**）。

## 2026-10-07 P7b WU 窗口通告修复（闭环收口）: "板从不主动通告窗口重开"的设计缺陷 —— 修复 + 板级两臂 A/B 坐实 + 独立验收

> **归档索引**（本节是里程碑日志；逐条判据、原始读数与复现命令在别处，别在这里找）：
> **`_proj_10g/notes/P7B_WU_ACCEPT.md`**（**独立验收 = 权威**：盲算 24 跑 → 逐格比对 / Q1–Q7 裁定 / "还差什么"清单）·
> **`_proj_10g/notes/P7B_WU_BOARD.md`**（板级测量：两臂 24 跑表 / 台架自证 (a)–(d) / (e)–(h) 冲突登记 / 收尾态与恢复配方）·
> `P7B_WU_{FIX,BUILD,TIMING_DELTA,REVIEW,REGRESSION,BATFIX,LOCALFIX}.md`（修复 / 构建 / 时序归因 / 对抗审查 / 回归 / bat 编码 / 文档局部订正）·
> `P7B_WU_PACE_AUDIT{,_VERIFY}.md` + `P7B_WU_PACE_DOCFIX{,2}.md`（pace 单位与天花板的"两次翻案"）·
> `P7B_GAP9_TCPAPP_8WAY_DESIGN.md`（Gap #9 设计研究，**未实施**）·
> 原始件 = `_proj_10g/notes/p7b_wu_loop/`（24 跑 txt/ss + pcap 留档 + 工具 + 烧录日志）· `p7b_wu_build/` · `p7b_wu_batfix/`。
> **下一轮开工先读 = `_proj_10g/notes/P7B_HANDOFF.md`**（已更新到 WU 新基线）。
> **本轮提交**：HEAD 已前进两笔 = `3257631`（WU 侦察 + 测量台）+ **`09d2189`（`wu` 修复）**；**`master` 领先 `origin/master` 2 笔（未推送）**；
> 文档/证据增量（本节 + 十余份 `P7B_WU_*.md` + `p7b_wu_*/`）同样待提交（提交由 TL 统一做）。

### ① 一句话

**上一轮抓到的那个产品级设计缺陷**（`app_ctrl` 的 `wu` 窗口重开通告两个触发条件**结构性不可达** ⇒ 板从不主动通告
⇒ 对端只能等 ~208 ms persist ⇒ TCP 上行被压到 4.7 Mbps）**已修复、并板级两臂 A/B 坐实**：同一台架、同一 6 点 pace 阶梯、
两臂紧挨（≈4 min）——**塌陷三档（`0 / 160e6 / 1000e6`）从 3.6–13.2 Mbps 抬到 1110.97–1111.05 Mbps**；
**中间三档（`50/100/134`）两臂逐字相同**（台架可比的正证据）；**静默段 55→0 · `MAX_GAP` 0.2086→0.0008 s · 低窗恢复 208 ms→200 µs**。
⭐ **独立验收**（另一 agent 盲算后比对）：**每一个数逐位相同** ⇒ 修复在**行为层"已独立证实"**。
⚠️ **但机理（"`wu` 通告真的发了"）仍是推断**（`stat_wu` 不在快照 —— 缺一件仪器）；
⚠️ **上界 = 1.111 Gbps（演示 app 天花板），不是 10G**；⚠️ **板子当前是受控停流态**（恢复配方见 ④）。

### ② 关键读数（逐条带出处）

**① 板级两臂 A/B（读数 = `P7B_WU_BOARD.md` §2/§5/§6；逐格复算 = `P7B_WU_ACCEPT.md` §1/§2）**

| 档（`PACE_BPS`，bytes/s） | 缺陷臂（`d20c08c9…5ed5`）Mbps | 修复臂（`1076e50e…1160`）Mbps |
|---|---:|---:|
| **0** | 3.714 / 3.714 | **1111.010 / 1111.010** |
| 50e6 | 400.104 / 400.104 | 400.104 / 400.104（**两臂逐字相同**） |
| 100e6 | 800.074 / 800.084 | 800.098 / 800.083（同上） |
| 134e6 | 1072.082 / 1072.082 | 1072.169 / 1072.081（同上） |
| **160e6** | **13.194 / 13.020** | **1111.007 / 1110.970** |
| **1000e6** | **3.626 / 3.801** | **1111.053 / 1111.045** |

- 倍数（⚠️ 配对口径）：×299 / ×84–85 / ×292–306（分母 = **含首秒瞬时的 12 s 均值**，偏保守；稳态分母 = ×409 / ×90 / ×432）。
- 形态（P0 档）：**静默段 55 → 0** · **`MAX_GAP` 0.2086 → 0.0008 s**（验收复算 `FIX_P1000_R1 = 0.0009`，不影响结论）·
  **低窗恢复 207.9 ms（n=78）→ 0.0002 s（n=52,086）** = ×1,040 —— ⚠️ 口径 = `win<1460 → 首个 win≥1460`；
  同段文字里的"470 段"是 `win==0` 口径，**该口径下两臂都是 200 µs、不可分**（引用这对数必须把口径写全）。
- 台架自证四条全过：`PACE_BPS` 24/24 可查 · `ss` 的 `pacing_rate == 8×PACE`（恰 8.000×）· pcap 单连接 24/24 ·
  `ΔW53(pre→post) == tx_bytes`（最差比 0.999732）。
- 验收的"还差什么"（按价值）：① `stat_wu`（`0x96`）+ `rx_occ_bytes` 进快照；② 用修好的工具重跑 `100e6`/`160e6`；
  ③ 负对照臂 sha 原件不存在（全盘搜过）；④ `W54` 打洞污染（见教训 ④）；⑤ 134e6 档的边际性只记读数。

**② 构建与时序（`P7B_WU_BUILD.md` / `P7B_WU_TIMING_DELTA.md`）**：`WNS +0.077 → +0.147`（好 +0.070）/ WHS +0.010 /
三类失败端点 `0/0/0`；位流 `1076e50e…1160`（15,431,261 B）。⭐ **全局最差换了族**：从 `async_default` 异步复位 Recovery
换到**数据面域 `g_hw.clk_out0` 的 setup 0.147**（`u_app_udp/u_txf/dout_reg[68] → u_udp_tx/ip_csum_r`，20 级逻辑）；
**该路径与 `wu` 修复无逻辑通路**（锥内无 `u_app_ctrl`，结构性排除）⇒ −0.045 是**换网表 ⇒ P&R 重排**的伴随产物
（本流程"同输入 ⇒ 读数逐字复现"由 RATE 原件/重建件对照证明；同轮 17 条同路径移动 −0.591…+1.302 ns）。
⚠️ **数据面域现在是全局最差（2.3% 余量）**，DP 前 10 有 6 条同源（跨 0.147–0.229）。

**③ `J0` 复验（`P7B_WU_BOARD.md` §7）**：pcap **1514/1500/1480/1472**（300/300 帧）· NIC **1517.9991** ·
板侧 `ΔW43/ΔW20 = 193.00008` · **`ΔW9 − 1472×ΔW20 = +1,144 B`** · `ΔW8 == ΔW20` · `W56=ΔW3=ΔW4=0`
⇒ **8 B/帧修复没被 `wu` 修复碰坏**。

**④ 判据（`P7B_WU_ACCEPT.md` §4/§7）**：**(e)/(f) PASS**（独立复算；三档全落在结构天花板 99.977–99.987%）；
**(g)/(h) 按字面 FAIL 属实，但被证明为判据缺陷** —— (g) 与 (e) **结构性互斥**、(h) 首子条件**两臂同 FAIL ⇒ 无判别力**、
(h) 第二子条件有判别力且修复臂 ✅；**`J15` 并入 J6-ladder**。⚠️ 措辞纪律："按字面 FAIL"是读数事实、"判据缺陷"是裁定结论。
⛔ **2026-10-07 DOCFIX3 补充**：**`J6`（J6-ladder）= 行为层已证实；判据层未裁定（待裁定 —— 裁定权在判据所有者/用户）** —— 本段的 "(e)/(f) PASS" / "(g)/(h) 按字面 FAIL" 全属**判据按字面**的读数与论证，**里程碑/文档层不代行裁定**；其它文件里 "`J6` = PASS" 的写法已逐处撤回（依据：`P7B_WU_ACCEPT.md:295`/`:330`，且该件 `grep -n J6` = 0 命中）。

### ③ 教训（都已实测；★ = 本轮新增/更新的全局经验编号）

1. ⭐⭐ **判据会把对的结论改错 —— 而且带着"已订正"的权威继续传播**（全局 **#49**）。一个读数 `1,073.043 Mbps` 恰好贴
   `2^30` 的 99.94% ⇒ 被判"量的是工具的限速帽子"，**把一条本来正确的归因（"被 app RX 校验器钉死"）降了级**；
   独立复核回源码发现 `SO_MAX_PACING_RATE` 单位 = **bytes/s**（内核头逐字 `/* bytes per second */`；`ss` 三档 8.000× 自证）
   ⇒ `2^30` 是 **8.59 Gbps** 的帽、根本够不着 ⇒ 那个"贴 2 的幂"是**巧合**；真值 = **1,110.8 Mbps = RTL 结构上界
   （`8/9 × 156.25 MHz = 1,111.1 Mbps`）的 99.97%**。⇒ ① **"贴 2 的幂"是报警器不是判决**，报警后必须**回源码/内核头核语义**；
   ② **要推翻已入库结论，先安排独立复核**（同一数据点一天被翻两次，这件事本身就是信号）；③ 日志的 `MB` 常是 **MiB**（差 4.86%）。
2. ⭐ **自己造成的资源争抢会产生假红，而且它长得像真缺陷**（全局 **#50**）。同机并行跑 **Vivado 全设计实现 + xsim 门矩阵**
   ⇒ **xsim 引擎被饿死**：矩阵里**孤零零**那条红 = `Simulation engine not responding` + memh 半行截断 ⇒ 检查器 `IndexError`。
   物证 = 两窗**完全重叠**（build `01:50:57`–`02:18:27` vs 崩溃 `~01:58–02:00:39`）+ 私有目录重跑 **EXIT=0**。
   ⇒ ① "读数确定"只对**被测工具本身**成立，同机的**其它**工具会以"崩溃/截断/超时"把噪声注入进来；
   ② 并发编排按**最脆弱的那个工具**定；③ 收到**孤零零的一条红**先问"我这一轮还同时跑了什么"。
3. ⭐ **判据缺陷也可以有"硬证明" —— 同族于闸 4 那三条 FAIL，但这次**不必看板子**。** J6-ladder 的 (g)（"阶梯单调非降 +
   相邻台阶比 ≤1.15"）与 (e)（帽达满）**结构性互斥**：任何满足 (e) 的实现（`50→100` 的帽比本身就是 2.0 > 1.15）必违反 (g)；
   `PACE=0` 被 (f) 要求 ≥1.0 Gbps、又被 (g) 要求 ≤P50 档 ⇒ 两子条件不可能同时满足。(h) 第一子条件（`min(win) ≥ 1460`）
   在"发送率 ≥ app 消费率"的工作点**结构性不可满足**（两臂同 FAIL ⇒ 无判别力）。
   ⇒ **改判据是判据所有者的裁定** —— 报告只登记"读数 + 冲突论证 + 支持/反对"，**不许自己宣布判据无效**（但可以给硬证明）。
4. ⭐ **"部分写打洞"会污染内容证据 —— 而且它极易被读成板子缺陷。** `W54` 在 `100e6`/`160e6` 档**两臂都爆**到 1e9 量级；
   判别式 = **`dW54 > 0 ⟺ tx_bytes mod 65536 ≠ 0`**（24/24 完美相关、无例外）；根因 = 对端工具 `send()` 部分写时
   **丢弃剩下的图案字节**（工具自己的物证 `partial_sends=1326 skip_bytes=5718136`）⇒ 板侧校验器无重同步，洞之后每个字节都算失配。
   ⇒ ① 内容 oracle 必须能区分"**谁制造的**洞"；② 这类读数**必须**与"工具有没有部分写"对账，否则会把工具缺陷记到板子账上。

### ④ 现状 / 未结项（**别写成已完成**）

- ⛔ **机理（"`wu` 通告真的发了"）仍是推断**：`stat_wu`（`0x96`，**已存在**）/`rx_occ_bytes` **未接快照** ⇒ **下一轮第一件事**。
  ⚠️ 接线前先知 **P2**：`stat_wu` 计 `wu_gnt` 拍数、**空转连接/共享占用噪声会计入** ⇒ 不能当"真通告"特异计数器；
  接线代价 ≈ **96 FF/字**（`hold_b`+`dout_a`+阵列三份）且 **DP 域已是全局最差** ⇒ **必须由一次构建收口**。
- ⚠️ **`100e6`/`160e6` 两档的图案内容证据要重跑才能拿回**（工具打洞；修好的工具 `p7b_tcp_src_fix` 已存在）。
- ⭐ **2026-10-07 订正（`W54` 关闸轮）：上一格已关闸；§②「还差什么」的 ② 也已完成** —— 修好的工具已重跑 `100e6`/`160e6`：**主判据 `ΔW54 == 0` 四跑全 0**，且每跑带工具侧自证（`partial_sends` = **2281 / 2159 / 0 / 4** ⇒ **修复路径被大量行使**）。⭐ **最干净的负对照 = 同会话、同 pace（100e6）**：**旧二进制** ⇒ `ΔW54 = 1,193,974,559`（= `ΔW53` 的 **99.49%**，`skip_bytes = 7,271,152` **直接见证**）⇒ **修复二进制 0**；另加**刻意造洞臂**（`--chunk 1M`，160e6）：旧 ⇒ **99.60%**、修复件**同锤**（**10,178 次部分写**）⇒ **0**。**工具身份已核清**：阶梯轮跑的**确是旧版**（`SRC_CMD=./p7b_tcp_src`、`SRC_SUM` 无 `partial_sends`；修好件当时**没上**）；三个二进制“源码 × `g++ -O2` ⇒ 逐字节等价”。**速率副判据 = 未变**（≤0.047% / ≤0.059%、逐秒稳态同带；⚠️ 严格“逐字相同”**做不到** ⇒ 口径 = “同帽 + 差值”）。⚠️ **两条未归因**：① 第 8 跑一次 **EPIPE / 板上 RST**（t=7.77 s 被拆；peer 15 次超时重传、**板侧零丢帧**；pcap 保留）；② **P160 自然打洞本会话 5 跑全 0**（阶梯轮 3/4 有）⇒ **会话级差异**。**收尾态 = 受控停流**（`0x08=0x2` / `carrier=0`；恢复配方 `0x08 w 0x0`，本轮实测两次）；**全程未重烧、未写 QSPI**。原件 = **`P7B_WU_W54_CLOSURE.md`** + `p7b_wu_w54/`。
- ⚠️ **负对照臂位流 sha 原件已不存在**（整棵仓 15 MB 级 `.bit` 逐个 sha256 过）⇒ 身份 = "支持（非密码学证明）"（验收裁定）。
- ⚠️ **板子现态 = 受控停流**（`0x08 = 0x2` ⇒ `carrier = 0`）：**恢复 = `reg_rw /dev/xdma0_user 0x08 w 0x0`**
  （⚠️ peer 表还在 ⇒ 立刻恢复发流）或重烧；⚠️ **`0x08` 既是 SCRATCH 又是 `TX_DIS` 门**。
- ⚠️ **新登记的小账**：对端 NIC `rx_eth_crc_err` 0→1（本轮某时点 1 个 CRC 错帧，无人登记）· **P1/P2** 两条边界
  （P1：`winq ≤ 3` 时新武装条件不可达且**比修复前更差**，产品配置不受影响；P2：见上）·
  `rtl/app_ctrl.v:205` 注释与实现不符（**不许改 RTL，只登记**）· `run_program_tcpreg.bat` 纯 LF（等所有者顺手修）。
- ⚠️ **仍未测**：`W57/W58` · `J5` · `F1-E5`/`F1-E6` · `N-b1` · 风险 b；**Gap #9 设计研究已备、未实施（等用户授权）**。
- ⚠️ **本机没有第二条 10G 路径**；**重建的 RATE 位流 `6475c3ba…` 已随 worktree 删除**（再要 A/B 需重建 ~22 min）。

## 2026-10-07 P7b Stage A（P1/P2 + 快照 63 字 + 机制观测）: `wu` 机理从"推断"升为"观测"，新判据 §4.1c 板上复跑两臂分开

> **归档索引**（本节是里程碑日志；逐条判据、原始读数与复现命令在别处，别在这里找）：
> **`_proj_10g/notes/P7B_BOARD_STAGEA.md`**（**板级原件**：身份核验 / `ΔW61` 机制读数 / 新判据下 13 跑逐跑表 / 负对照臂离线重判 / 现态与复跑命令）·
> **`_proj_10g/notes/P7B_BUILD_STAGEA.md`**（构建：`+0.100 / 0/0/0` / `hold_b` 族 524 位逐端点 / 位流 `b9f16c75…d804`）·
> `P7B_WU_F2_F1_FIX.md`（F2 显式不发 + 2³² 穷举等价）· `P7B_WU_P1P2_SNAP.md`（P1/P2 + W61/W62 接线）·
> `P7B_WU_HARNESS_FIX.md`（测量台架四条缺口 + 三个真缺陷）· `P7B_WU_P1P2_REVIEW.md`（对抗审查 F1/F2/F3）·
> 原始件 = `_proj_10g/notes/p7b_board_stagea/` · `p7b_build_stageA/`。
> **下一轮开工先读 = `_proj_10g/notes/P7B_HANDOFF.md`**（已同步到 Stage A 新基线）。

### ① 一句话

**上一轮留下的唯一仪器缺口（"`wu` 通告真的发了"只是推断）已补上**：`stat_wu`/`rx_occ_bytes` 接进快照（**W61/W62**，窗口 **63 字** / `BUILD_ID_V=9` / 未实现地址 `0x11C`），
位流 **`b9f16c754e693ca4…8146d804` 已烧**、板侧身份逐条全中；**传输窗内 `ΔW61 > 0`（6 跑）+ 静默态 `ΔW61 ≡ 0` 负对照 ⇒ 机理升为观测**。
**改写后的新判据 `§4.1c` 已在板上复跑、两臂分开**：修复臂 PASS / 负对照臂 FAIL。
⛔ **`J6` 仍不许写成 PASS**（`J6` 是**旧**判据名；这一格 = "行为层已证实 / 新判据已板级复跑两臂分开"，裁定权在用户）。

### ② 关键读数（逐条带出处）

**① 构建（`P7B_BUILD_STAGEA.md`）**：**`WNS +0.100 / WHS +0.010 / 三类失败端点 0/0/0`**（vs 上一版 `+0.147` = **同族换最差位**：
`u_app_udp/u_txf/dout_reg[69] → u_udp_tx/ip_csum_r`）；位流 `b9f16c754e693ca48997c70c49b9ac21e5cd404d52c6ca2eb5a64d7b8146d804`（15,431,261 B，构建 23 min 08 s）。
对抗审查点名的 `u_snap_p7bdp/hold_b_reg[*]` 族**全族 524 D 位逐端点扫过**：最差 hold `0.011` 落在**旧位**（642，W59）、
新位 W61=0.021 / W62=0.221 ⇒ **判非新族**（三条支证：结构面 LL=0 成簇 / 基线对照 0 命中 / 新锥两向都无紧张端点）。

**② 板级身份（`P7B_BOARD_STAGEA.md` §1）**：`0x04 = 0x00000009` · **`0x114` 现在是真字**（旧口径下是未实现地址）· **`0x11C` 回 `0xffffffff`** ·
`LnkSta x4` · `2 BARs` · **63 字窗口**；PCIe 恢复 = 设备级 `remove`+`rescan` 一次成功；会话末复读 BID 仍 9（无中途重烧）。

**③ ⭐ 机制读数（§2）**：`ΔW61 = 23,775 / 7 / 42,129 / 0×6（P50/P100/P134 三档）/ 14,297 / 9 / 45,573 / 49,621` —— **13/13 跑与"板上行窗进过危险区
（`min(win) < winq/4 = 12,288`）"一致**；P160_R1 的 `ΔW61 = 14,297` 与线上"低窗恢复段数 14,553"**同量级（差 1.8%）**（两条独立通路互证）。
负对照：**静默态 `ΔW61 ≡ 0`** + 同窗 `W5` 自由计数照跑（窗口是活的）+ `W62` 非零正证据。⚠️ 精确关系未建立（P0_r1 ≈1:2）。

**④ 新判据 `§4.1c` 板上复跑（§3/§4）**：修复臂 **13/13 跑 `ρ ∈ [0.99980, 1.00024]`**（`(e)` 4/4、`(f)` 6/6）；`(h′)①` 适用 7 跑里 6 跑 0 段
（唯一例外 P0_r1 的 2 段已归因为 2.09 s 连接建立失败）、`(h′)②` max ≤ 273 µs ≤ 1 ms。负对照臂（**离线重判** —— 旧位流全盘无副本）：
`ρ = 0.0033–0.0119`、`(h′)①` 55 段 ×6/6、`(h′)②` med **206–208 ms**。⇒ **改写判据的最低要求（修复臂 PASS + 负对照臂 FAIL）由板上读数满足**。

**⑤ P1/P2/F2（`P7B_WU_P1P2_SNAP.md` / `P7B_WU_F2_F1_FIX.md`）**：F2 = `winq == 0` 显式不发（整块 guard，功能 +1/−0 行）+
**穷举 2³² 格点**证明 `winq != 0` 的全部取值与修前**逐位相同（差异数 0）**；P1 = 武装阈值加下界 1；P2 = per-slot `wu_act` 进度门（空转连接结构性不武装）。

### ③ 教训（都已实测；★ = 本轮新增/更新的全局经验编号）

1. ⭐⭐ **"回归通过"可能只是"矩阵没看你" —— 指纹逐字节不变就是它没看见你**（全局 **#52**）。16 门 P4 矩阵对两个改动文件结构性盲：
   5 个 manifest（`chain_src.f` 等）**一个都不含** `rtl/app_ctrl.v` / `board/wrapper_p4.v`；矩阵的 **237 文件哈希集**与**上一个 commit（`ff78247`）**那次运行
   **逐行 diff = `FILE LISTS IDENTICAL (paths+hashes)`**、`DIGEST_COMPILE/DIGEST_ALL` 与更早的 `d417589` **完全相同** ⇒ **三个 revision 同一个指纹**。
   ⇒ ① 「16 门全绿」**不是**这两个文件的回归证据（只证明另外 19 个模块没坏）；② **判"覆盖"要按编译集/manifest 核**，不按"门跑过"核；
   ③ 见到"指纹逐字节不变"先问"**它到底哈希了谁**"。（出处 = `P7B_WU_P1P2_REGRESSION.md` §4）
2. ⭐⭐ **哑门的新变种：`[FAIL]` + `exit 0` + 末行无条件 `PASS`**（全局 **#53**）。`p6b_smoke_gate.sh` 实测：A1b 判 `[FAIL]` + `[FATAL] 拒绝继续`，
   **末行照样 `冒烟门: PASS`、`rc=0`**；`ID_BAD=1` **赋值后从未被读**（`grep -c` = 1）。修后 = 末行 `FAIL` + **`rc=7`** + 点名根因、**仍读完 A3/A4**（归因纪律保留）。
   **同族"默认值陷阱"**：`tcpreg_j6.sh:53` / `j6_fix.sh:58` 的 `NW=${NW:-61}` **没有 export** ⇒ `NW=61 bash …` 里的 61 **不会**传给取数器
   ⇒ "文档里的覆盖办法"**静默失效**、旧几何**被记进日志而不报错**；修后 = 默认 **63 + export** + **几何门**（(NW,BID) 成对断言，不符 `exit 3`）。
   ⇒ **凡"默认值可被环境覆盖"的写法，必须有一条实测证明覆盖真的到达了**。（出处 = `P7B_WU_HARNESS_FIX.md`）
3. ⭐ **"重跑历史脚本会把旧版本贴回去"这类论断必须实测，不能想当然。** 审查判"重跑 `apply_c.py` 会把 61 字版**贴回 RTL**"；
   **实测**（把 `io.open` 的写模式打成一律抛异常）= "**第一个锚点 MISS 就退出、不写盘**" ⇒ 论断**当天的行为**不成立 ——
   **但守卫仍然必要**：`sub()` 是**逐文件**落盘 ⇒ "前几个文件命中、后面某个 MISS"会留下**半改**状态（比全不写更坏）；
   四个历史 `apply_*` 已加**代际硬守卫**（现役 `SNAP_NW_P6E` 必须等于本件的 pre-state，否则 `GUARD_REFUSE` + `exit 3`、**一个字节都不写**）。
4. ⭐ **同族顺带新发现（同一轮，三条真缺陷都已修 + 有 before/after）**：① 假对端用默认 `open()` 写日志 ⇒ Windows **GBK** 遇 `⚠` 直接
   `UnicodeEncodeError` **崩掉整个台架**（22 条假红，**与几何无关**）；② 假对端的几何必须**按"请求方那一代"**回（一刀切会**反向**打断老臂）；
   ③ 变异体生成器的第二处 `replace` **无断言** ⇒ 锚点消失时静默退化成"与真文件一样" ⇒ **负对照假通过**。（出处 = `P7B_WU_HARNESS_FIX.md` §3.1）

### ④ 现状 / 未结项（**别写成已完成**）

- ⚠️ **板上现态 = Stage A 位流 `b9f16c75…d804`（63 字 / BID 9）/ 受控停流态**（`0x08 = 0x2` ⇒ `carrier = 0`）；
  **恢复 = `reg_rw /dev/xdma0_user 0x08 w 0x0`**（⚠️ `0x08` 既是 SCRATCH 又是 `TX_DIS` 门）或重烧。
- ⛔ **`(h′)①` 的"建立期算不算静默段"待判据所有者裁定**（P0_r1 的 2.09 s 连接建立失败；本件按字面登记 `2 段` + 摆出可复核的 pcap/ss 证据）。
- ⚠️ **对端机上有未识别的第三方**：3/13 跑的 pcap 出现 `192.168.100.1:9090 → 板:8080` 的 2 包（0 个板 ACK；对端 `ps`/脚本 grep 查无）—— 登记为"测量环境里有个安静的第三方"。
- ⚠️ **旧几何臂做不到**（旧位流全盘无副本）；`ΔW61` 与线上段数的**精确**关系未建立；`W62` 绝对标定未做；P160_R2 的 `(h′)②` 为 `n=0`（**按空判据记**，不记 PASS）。
- ⛔ **第一优先 = TCP 单路双向 10 Gbps**（仍待实施）；**下一步 = Stage B（RX 8 路）**，设计件 = `P7B_SINGLE_FLOW_10G_DESIGN.md`（已落盘，**等授权**）。

## 2026-10-07 P7b Stage B（RX 8 路 R1）: 上行 1,110.9 → 4,058–4,151 Mbps（×3.65–3.73，下界）+ 新限速级 = 测量台架（`≤4.72 Gbps`）+ 独立验收拆掉三条支撑论证

> **归档索引**（本节是里程碑日志；逐条判据、原始读数与复现命令在别处，别在这里找）：
> **`_proj_10g/notes/P7B_BOARD_STAGEB.md`**（板级原件：身份 10/10 / 主判据 13 跑 / 新限速级判定 / J6-ladder / `ΔW61` 机制**负结果** / `J0` 复验 / 现态与复跑命令）·
> **`_proj_10g/notes/P7B_BOARD_STAGEB_ACCEPT.md`**（**独立验收 = 权威**：逐格复算 / U1–U8 / 三条支撑论证的拆解 / "还差什么"）·
> **`P7B_BUILD_STAGEB.md`**（构建 `+0.006 / 0/0/0` / 新锥 11 级 / DP 前 10 对照）· `P7B_STAGEB_RX8.md`（作者件）·
> **`P7B_STAGEB_RX8_REVIEW.md`**（对抗审查：相位洞最小反例 / XOR 网线性完备证明）· **`P7B_STAGEB_RX8_REGRESSION.md`**（全仓 16 门 + "两种盲"破坏实验）·
> `P7B_STAGEB_FIX.md` / **`P7B_STAGEB_CRITERIA_FIX.md`**（32 位回卷 mod 2³² 逐处订正）/ `P7B_STAGEB_CORRECT.md`（订正落库）·
> **`P7B_TX_PINGPONG_FIX_DESIGN.md`**（Stage C 设计件）+ 两轮审查 `P7B_TX_PINGPONG_FIX_REVIEW{,2}.md`。
> 原始件 = `_proj_10g/notes/p7b_board_stageb/`（103 文件）· `p7b_build_stageB/`。
> **下一轮开工先读 = `_proj_10g/notes/P7B_HANDOFF.md`**（已同步到 Stage B 新基线）。

### ① 一句话

**R1（`rtl/app_pattern.v` 的 TCP app RX 8 路并行，+199/−0、全部包在既有宏 `P7B_10G` 内）已落地并经板级坐实 + 独立验收**：
unpaced 上行 **4,058.033 / 4142.682 / 4133.629 Mbps**（vs Build 1 锚 1110.87–1110.97 ⇒ **×3.65–3.73，下界**）、**`ΔW54 ≡ 0`（13/13 跑 ≈45 GB）**、`J0` 未回退、`ΔW61 ≡ 0`。
⛔ **但"新限速级是谁"答不了"是不是 `tcp_rx`"—— 本轮实测落在"台架自己"上（对端单核 `≤4.72 Gbps`），板子真实天花板仍未测（只有下界 ≥4.72 Gbps，且只有单边证据）**；
⛔ **独立验收拆掉三条支撑论证 + 订正两处读数**（②-⑥）；⛔ **"R1 内容 = RX 8 路" = 无法判定**（验收按纪律未读 `rtl/`，只有行为证据）。
**下一步 = Stage C（TX 8 路 + 乒乓重叠）**：设计件 `P7B_TX_PINGPONG_FIX_DESIGN.md` 已 **implementation-ready（附条件；3 轮对抗审查）**。

### ② 关键读数（逐条带出处）

**① 构建（`P7B_BUILD_STAGEB.md`）**：**`WNS +0.006 / WHS +0.008 / 三类失败端点 0/0/0`**（`board/p7b_ku5p_timing.rpt:156,159`）；位流 **`1ccbd9cd84292d1a10973a1442f71ca2187e66834be5e09d7eeb22b42c6cdd07`**（15,431,261 B，构建 25 min 22 s）。
⭐ **对抗审查的预测被实测证实且精确**：新锥 = **11 级 / logic 1.230 ns**（预测"10–11 级 ≈1.2–1.5 ns"）⇒ **新锥一条都没进 DP 前 10**（余量 12×）；
⚠️ **WNS 掉的 −0.094 全部落在老旧族**（`u_app_udp/u_txf/dout_reg[70] → u_udp_tx/ip_csum_r`，同族占位 WU 6 → Stage A 2 → **Stage B 10**，**非单调** = P&R 重排特征）；
⚠️ **`+142 FF` 与 diff 结构不符（未归因）**（diff 里没有任何新 `reg`；PW 端点数也恰 +142 ⇒ 疑 opt/retiming 重构产物；⚠️ **不可判**：Build 1 的 post-synth 归档已被 `create_project -force` 删除）。

**② 板级身份（`P7B_BOARD_STAGEB.md` §0/§1）**：烧前现核 sha256、`End of startup status: HIGH`、PCIe **设备级** `remove`+`rescan` 一次成功；**身份 10/10**（`0x04 = 9` / `0x118`(W62) 可读 / **`0x11C` 未实现** / **63 字** / `2 BARs` / `LnkSta x4`）。
⚠️ **两构建 `BUILD_ID` 都是 9**（`b9f16c75…d804` 与 `1ccbd9cd…6cdd07`）⇒ **板级身份门分不出 Build 1 / Build 2，只有 bitstream sha256 能分** ⇒ **纪律（新增）：每次构建必须 bump `BUILD_ID_V`**。

**③ 主判据 R1 生效（§2）**：unpaced 6 跑 4058.033 / 4142.682 / 4133.629 / 4150.802 / 4062.022 / 3970.648 Mbps（对端 64 位口径）；**板侧第三口径** `ΔW53×8/(ΔW5/156.25e6)`（**mod 2³² 还原**）逐跑吻合 ≤0.25%；`ΔW53/tx_bytes = 0.9999998–1.0000000`；**17 项丢帧计数 × 14 跑恒 0**。
⚠️ **两侧语义不同**（Build 1 = 板受限 1110.9 = 其结构天花板 99.98%；Build 2 = 台架受限）⇒ 倍数只能当**下界**。

**④ 新限速级判定（§3）**：实测 4.06–4.15 Gbps **低于全部候选**（`tcp_rx` 9.605 / S2 8.38 / XGMII 9.493 Gbps）⇒ 落在"台架自己"：**只测速变体（去图案生成）= 4719.291 Mbps** + 工具进程 **100% 单核** ⇒ **台架 ≤ 4.72 Gbps**。
**板子清白** = E1（4,262,906 个 ACK 的 `win ∈ [47,688, 49,152]`、`win<1460` = 0）· E2（`W27` 恒 6 字）· E3（零丢失/零错）· E4（RTT 39 µs ⇒ BDP 10.1 Gbps）—— 独立验收逐条"已证实"；
⚠️ **E5 已降级为"形态描述"**（credit ≈ `win − rate×RTT` = **环路恒等式**）⇒ 诚实口径 = **"板端吞吐已证清白 / 板端时延未被排除（无法判定）"**。
⚠️ **"板 ≥ 4.72 Gbps" 只有单边证据**（`RATE_ONLY_R1` 真灌进 `7,078,936,576 B`、`bytes_acked` 差 379 B，**但该跑无 `run_*.txt`/pcap**）。

**⑤ J6-ladder 6 档 13 跑 + 机制负结果（§4/§5）**：`(a)–(d)` 台架自证全过（(d) 须 mod 2³²）、`(e)` 4/4 ✅、`(f)` ✅（`0`/`160e6`/`1000e6` 三档全过；⚠️ **分母口径件内不一致** —— `P7B_BOARD_STAGEB.md` §0④ 写 `5/6`、§4.1 写 `6/6`，引用前回原始件核）、`(g′)` **4/6 档 PASS / 2 档 FAIL（`0` 与 `1000e6`）**、`(h′)①` **0 段 ✅**、`(h′)②` **空判据（n=0）**、`ΔW54 ≡ 0`（13/13）。
**`ΔW61 ≡ 0`（13/13 跑）**——全部 ACK 的 `win ∈ [47,688, 49,152]` ⇒ **窗口从未进危险区 ⇒ `wu` 通路本轮不被激励**（与 Stage A 正相关不矛盾：构造不同）；`W62` = **6/26 点非 0（max 1400 B）**、`W49` **非恒 0**。
⛔ **`(g′)` 的独立验收裁定 = 空判据（本工况，无判别力）**——两档 FAIL 的分母取"板容量（结构值 9759.4）"而实测被台架帽压住 ⇒ **FAIL 与板子无关、结构注定**；换平台值仍两头都可能（`4719.291 ⇒ ρ=0.860–0.878` FAIL / `4150.802 ⇒ 0.978–0.998` PASS）⇒ **判定完全由未知量决定**；验收**不建议记 PASS/FAIL**（同族先例 = `W13==0` 降级；**裁定权在判据所有者** —— 本日志不代行）。

**⑥ `J0` 复验 + 独立验收的三条拆解（§6 / 验收 §2/§3）**：`J0` **全中**（`ΔW43/ΔW20 = 193.000001` · **809,577.9 fps** · NIC `Δbytes/Δpkts = 1518.0000` · pcap 300/300 = 1514 · `ΔW8==ΔW20` · `W56 = 0`）⇒ **8 B/帧修复未被碰坏**。
⛔ 验收**拆掉三条**：**(I)** 台架 `RETX_seq_backward = 159,852 (33.34%)` = **32 位 seq 回卷假象**（64 位 unwrap：并集 = 求和、重复 19 B ⇒ **线上零重传**）⇒ **谁引用"33% 重传"就是引用工具缺陷**；**(II)** credit = 环路恒等式（见 ④）；**(III)** `RATE_ONLY_R1` 无板侧原件（见 ④）。
⛔ 验收**订正两处读数**：`W62` 6/26 点（非"1 点 528 B"）、`W49` 非恒 0；另 **`W1`/`W31`/`W37`（402–403 MB/s）才是真回卷族**（报告的 `W54`/`W52` 是错例 —— **下游拿 `W1` 当"板收字节" oracle 会差 3×**）。
⭐ 验收另**给报告记一笔没被吹的地方**：报告自己登记了 RTT 口径依赖 / E5 分辨率受 GSO 量化 / 多连接探针结构性失效 / `(h′)②` 空判据 / `tcp_rx` 未测。

### ③ 教训（都已实测；★ = 全局经验编号）

1. ★ **回归矩阵两种盲同时成立（= 全局 52）**：旗舰 16 门 P4 矩阵对 `rtl/app_pattern.v` 的 +199 行**结构性不可见** —— **(a) 5 份 manifest 一份都不含它**；**(b) 16 门里没有一门带 `P7B_10G`/`APP_MODE`**（被改的行全在宏内）。
   ⭐ **可复算证据 = 单字节破坏实验**（镜像树，不碰真树）：把 `xs_next8[63]` 那一行真改坏 ⇒ **M1（不进清单）绿 / M2（进清单 + 进 xvlog 表）仍绿 / M2p（再开 `-d P7B_10G`）才红**（`VRFC 10-4982`，点 `app_pattern.v:97`）。
   ⇒ **要看见这行代码必须同时补两样；少一样都看得见"绿"而看不见代码** —— 而 R1 的可覆盖性**全押在一条新门上**（`sim/p7b_stageb_rx8/`，全仓唯一"编它 + 开宏 + 真驱动 app RX"的门）⇒ 建议登记进常驻 runner（`P7B_HANDOFF.md` §4-#57）。
2. **32 位计数器回卷**：12 s 窗门槛 = `2³²/12 s = 2.863 Gbps` —— **本板 TCP 上行 4.15 Gbps、UDP 下行 9.53 Gbps 都已在门槛之上** ⇒ **凡字节类判据先假设"已回卷"**：必须 **mod 2³²** + `raw`/`k` 同表落档 + 由**板外 64 位口径**反推 k。
   ⚠️ **错例 + 漏例**：`W54`/`W52` 不是回卷候选；**真回卷族 = `W1`/`W31`/`W37`（402–403 MB/s）+ `W53`（387 MB/s）**。
   ⚠️ **既有工具已经印过静默错**：`W9` 在 9.53 Gbps 下 **3.61 s** 回卷一次，而某档 xchk 窗 **5.7 s** ⇒ `parse_xchk.py` 印出的"板侧 app 载荷率 (W9)"**静默错 k·2³²**（6 个解析器 + 2 个台架 + 判据原文 (d) 已逐处订正 = `P7B_STAGEB_CRITERIA_FIX.md`）。
   ⚠️ 同族边界：`W5/W24/W36/W43`（自由计数）**27.487 s** 回绕 ⇒ **"把窗拉到 30 s 就万事大吉"是错的**。
3. **"最漂亮的证据"可能是环路恒等式 —— 证据的论证负荷要单独称重，不能凭形态好看就加重**：E5（"发送方有信用却没在发"）数算对了，但 `p50 credit = 20,416 B ≈ 47,752 − 506.1 MB/s × 50.5 µs` ⇒ **任何平均 4.06 Gbps、环路 ~50 µs 的发送方都会给出这个数**（它量的是"窗口减去一个环路时延的送达量"，不是"余量"）；且**反例可构造**（板端 ACK 回路 +~40 µs ⇒ 同样的五条读数，但限速的是板子）。
   ⚠️ 更狠的一条：**交付件自带的 `ss` 原件方向相反**（`rwnd_limited` = busy 的 26–99%、`notsent` ≈15–16 KB），而**报告全文 `grep rwnd_limited|notsent` = 0 命中** ⇒ **"不是窗口限速"在即时级与自家原件相反** ⇒ 诚实写法 = **"板端吞吐已证清白；板端时延未被排除"**。
   ⇒ 读任何"形态判据"前先问：**这个量在"另一种病因"下会不会照样是这个值？**
4. ★ **每次构建都会摧毁上一次构建的取证 —— `create_project -force` 开工即清 `impl_1/`（= 全局 54）**：Build 2 开工时 **Build 1 的 `-max_paths 10` 报告 / routed dcp / post-synth 读数全丢** ⇒ 两件事**不可判**（新锥深度变化的归属 / `+142 FF` 的来源）；本轮只靠"构建**前**抢救 `board/p7b_ku5p_*.rpt` 五件"保住**部分**对照。
   ⇒ **"与基线对照"的前提是"基线还在"** —— 先问基线在不在，再谈差值；**归档必须写进构建脚本本身**（靠人记得不算）。

### ④ 现状 / 未结项（**别写成已完成**）

- ⚠️ **板上现态 = Stage B 位流 `1ccbd9cd…6cdd07`（63 字 / BID 9）/ 受控停流态**（`0x08 = 0x2` ⇒ `carrier = 0`）；**恢复 = `reg_rw /dev/xdma0_user 0x08 w 0x0`**（⚠️ `0x08` 既是 SCRATCH 又是 `TX_DIS` 门）或重烧。
- ⛔ **未能证明**：**R1 的 RTL 内容 = 无法判定**（只有行为证据）· **板子真实天花板未测**（下界 ≥4.72 Gbps 单边）· **缺"能单流 >8 Gbps 的对端发送端"** · **`tcp_rx` 190 拍仍为 RTL 推值**（app 只余 3 拍，RX 收益的落点全靠它）· **2-sender 归因 = 无法判定**（缺 W53/W54 原始读数，#56）· `(g′)`/`(h′)②` 空判据待裁定 · 未测/未采：`W57/W58` · `J5` · `F1-E5`/`F1-E6` · `N-b1` · 风险 b。
- ⚠️ **两条物理约束**（下一轮必须带着读）：**板子每段一 ACK**（pcap `ACK/段 = 1.0000`，4.1 Gbps 时 ≈**355k ACK/s**）+ **默认单池**（`Σwinq + pool == WIN_POOL`）⇒ **第二连接拿不到信用**（实测 `send_err=32` EPIPE）⇒ **要绕开必须建连前由 app 写 `app_ctrl` `0x0C` 分池**（demo app 做不到）。
- **下一步 = Stage C（TX 8 路 + 乒乓重叠）**，设计件 = `P7B_TX_PINGPONG_FIX_DESIGN.md`（**implementation-ready 附条件**：S0 先建门证有牙 / 一键回退 / 一次构建收口 / T1–T12 全过）；⚠️ 该设计件**零仿真/零综合/零上板**、TCP 源 193 拍与 ACK 11 拍**都还没有板级读数**。

## 2026-10-07 P7b Stage C（TX 8 路 + 乒乓）: ⛔ 下行退化 0.25–0.40×（Build 2 = 889.4/890.3 vs Build 3 = 224–352 Mbps）+ 追出 "整窗重放" 自持反馈环（`W55` 旧定案是它的一环）

> **归档索引**（本节是里程碑日志；逐条判据、原始读数与复现命令在别处，别在这里找）：
> **`_proj_10g/notes/P7B_BOARD_STAGEC.md`**（**板级原件**：身份 12/12 / 主判据 4 跑 + 同会话 A/B / 限速级判定 / 上行复验 / `J0` / 双向 11 拍 / BID=0xA 专节 / 环境缺陷 5 条 / 未证 7 条）·
> **`P7B_BUILD_STAGEC.md`**（构建 `+0.070 / 0/0/0` / DP 前 10 整体换族 / 归档写进构建脚本 / BID 引用清册）·
> **`P7B_STAGEC_TX.md`**（实施：乒乓 +823/−1 / 门 15 臂 / **F1 阻断级既存缺陷**已修两分支）· **`P7B_STAGEC_TX_REVIEW.md`**（对抗审查：F1 最小反例 / 逐条裁定）·
> `P7B_STAGEC_A2.md`（TX 8 路 app）· `P7B_STAGEC_TX_REGRESSION.md`（全仓回归 + 冻结版）·
> **`P7B_BID_SYNC.md`**（BID 9→0xA 全同步 10 文件/29 处 + 2 个冻结复核件）· `P7B_IGNORE_STAGEC.md`（归档目录 ignore 收口）。
> 原始件 = `_proj_10g/notes/p7b_board_stagec/`（22 件）· `p7b_build_stageC/` · `p7b_build_archive/20261007_163651/`。
> **新 session 入口 = `_proj_10g/notes/P7B_LOOP_HANDOFF.md`**。

### ① 一句话

**Stage C（TCP app TX 8 路 `A2` + `tcp_tx_frame` 乒乓 `TCP_TX_OVL`，BID 提升到 0xA）已上板：⛔ 主判据 = 下行退化** —— 4 跑 sink 聚合 **224.1–352.5 Mbps**（板侧 208.8–316.6）；**同会话 A/B 的 Build 2 臂 = 889.4 / 890.3 Mbps ⇒ Build 3 = 0.25–0.40×**。
⛔ **限速级既不是 TX 能力（板侧帧率只有几何上限的 43–46%）也不是对端收包能力（UDP 洪流下照收 809,578 fps），而是 "板侧整窗重放" 自持反馈环**（三台仪器同指：板侧重复率 13.8–19.3 · 首连 pcap 93.4% 帧是重复 · 对端 OFO 仅 0.16–0.4%）。
⛔ **2026-10-10 订正（口径）**：原写"板侧 TX 线只忙 43–46%"—— `W43` 每拍无条件 +1（`mac_tx_10g.v:330`）⇒ `P ≡ 156.25e6/fps` ⇒ `193/P` 只是"fps 未达几何上限"的**换算式**，**不是线占空测量**（板侧无线占空计数器）；本条的诊断依据 = **帧率 + 重复率（`W15/W51`）+ pcap 实拍**（见 `_proj_10g/notes/P7B_BOARD_STAGEC.md` §3 订正块）。
✅ **数据内容是对的**（4 跑 `fail_conns=0` / `mismatch_bytes=0`）· ✅ **上行未被碰坏**（**4042.682 / 4149.076 Mbps**，锚 4058–4151）· ✅ **`J0` 全中** · ✅ **双向 "每 ACK 11 拍" 首次板级读数**（251.7k ACK/s ⇒ −1.772%，模型逐位吻合）。
⚠️ **板上现态 = 受控停流**（`0x08 = 0x2` ⇒ `carrier = 0`），板上位流 = **`1609d6f5…576f3c`**（63 字 / **BID 0xA**）。

### ② 关键读数（逐条带出处）

**① 构建（`P7B_BUILD_STAGEC.md`）**：**`WNS +0.070 / WHS +0.010 / 三类失败端点 0/0/0`**（基线 `+0.006`，**反而好 0.064**）；位流 `1609d6f55e8a119b2f88c1a57cd4776e2219f56d3d1e84f840b198555e576f3c`（15,431,261 B，28 min 43 s）；宏自证 `… UDP_TX_OVL=1 TCP_TX_OVL=1`。
⭐ **DP 域前 10 整体换族（10/10 独占）**：新族 = `u_tcp_tx/retx_active_reg/C → u_tcp_tx/ctrl_tcpcsum_reg[*]/D`（**22 级 / logic 2.611 ns**，7 个 CARRY8 = `fold16` 进位链）；老族一条未进（源码面证据：`ctrl_tcpcsum` 在 HEAD 里不存在 ⇒ 新锥）。⇒ **DP 余量只剩 1.09%（0.070/6.400），以后加逻辑都先落这条族**。
📦 **全局 #54 收口**：pre-build archive 块写进 `board/run_build_p7b_ku5p.bat`（每次构建无条件归档 19 件、~150 MB/次；本轮实测 `ARCHIVE_DONE`，且自动副本 bit 与手工归档逐字相同）；`.gitignore` 由 `P7B_IGNORE_STAGEC.md` 收口（整目录排除、只放行 `SHA256SUMS.txt`）。

**② ⛔ 主判据 = 下行（板→对端）退化（§2）**：DL2–DL5 sink 聚合 **312.1 / 224.1 / 239.5 / 352.5 Mbps**；**同会话 A/B**（Build 2 位流现成在盘，`1ccbd9cd…` / BID 9）**= 889.4 / 890.3 Mbps**；形态 = 拍/帧 **2578 → 416–461**（TX 线 43–46% 忙）、重复率 `W15/W51` **1.01 → 13.8–19.3**。⇒ **四个候选上界（9.456 / 9.493 / 8.86–8.95 / 对端收包）一个都没接近**；`--nocheck`、RX ring 4096、无 tcpdump 三种放松都没破环。（历史基线对照：Stage 2 的 895.445 Mbps 与本轮 Build 2 臂 889–890 Mbps 同量级 = 两条独立时点一致。）

**③ ⭐ 机制 = 整窗重放自持环（§3）**：板发整窗（窗口上限 33 帧）→ 对端栈 **0.16–0.4%** 的洞（`TcpExtTCPOFOQueue` 仅 +627…+1198；ring=4096 时 `Δnodesc=0` ⇒ 不是（仅）NIC ring）→ 对端 quickack **每帧一个 dup-ACK**（pcap：10,183 数据帧 / 9,815 ACK）→ **板重放整段 `[snd_una, snd_nxt]`（27.6–34.5 帧/会话，6,970–11,449 会话）** → 重复段被 Linux 立即回 ACK → 更多 dup-ACK ⇒ **自持** —— **627 个 OFO 事件被放大成 36 万重复帧**（~20×）。
⚠️ **归因边界（不许读过头）**：洞的最后一米**没定到**（对端栈内部，无逐洞见证）；**拆刀未做**（没分别关 A2 / `TCP_TX_OVL`）；板的 dup-ACK 阈值 / 重放粒度**只有行为证据**。
⭐ **同一族的历史订正**：**`W55` 定案（一次回卷重放整段）当年（Stage 2）被读成 "良性解释"** —— 现在才知道**它就是本环的一环**；**Build 2 因慢（拍/帧 ≈2578、重复率 1.01）从未触发**。

**④ 附带项全过（§4）**：**上行复验** = `4042.682 / 4149.076 Mbps`（板侧 `ΔW53` 4021.051 / 4127.525，`ΔW53/tx_bytes = 1.000000`；**`ΔW54 ≡ 0`** ⇒ ≈6.3 GB 逐字节）；**`J0` 全中**（pcap **300/300 = 1514 B**（1472 载荷）· **809,577.9 fps** · `ΔW43/ΔW20` **193.0000** · 载荷 **9.5336 Gbps** · `ΔW9` 差 **+32 B** · 丢弃计数全 0 · NIC `Δbytes/Δpkts = 1517.9994`）；⭐ **双向 "每 ACK 11 拍" 首次板级读数**：**251.7k ACK/s** 使 UDP 帧率掉 **−1.772%**（= 模型 `251,666×11/156.25e6` **逐位吻合**）；**停上行后 fps 逐字回到 809,578**（这条同时是 §3 的关键负对照：同板同 TX 线、无 TCP ACK 环时满几何零重复）。

**⑤ `BID = 0xA` 板级证据（首次取得，§5）**：`0x04 = 0x0000000a` + `ID_OK`；A/B 期间换 Build 2 读回 `0x00000009` ⇒ **BID 真有区分力**；**63 字 / `0x11C` 未实现**不变 ⇒ 本轮变更 = 纯身份（几何一字未动）。

### ③ 教训（都已实测；⚠️ 这四条尚未回灌全局文件）

1. ⭐ **"提速" 会激活沉睡的协议层反馈环 —— 同一个 "整窗重放" 行为在慢构建上从不触发（Build 2 重复率 1.01），提速后自持（627 → 36 万重复帧）** ⇒ **"数据面很健康" 与 "端到端退化" 可以同时成立**：内容逐字节正确、上行无损、`J0` 全中，而下行只有 0.25–0.40×。判 "退化" 之前先分清 "发不出去 / 收不下 / 线上被重放占据" 三种形态（本例第三种的识别键 = 板侧**帧率只有几何上限的 43–46% + 重复率 13.8–19.3×**；⛔ 2026-10-10 订正（口径）：原写"TX 线只忙 43–46%"—— `W43` 每拍无条件 +1 ⇒ `193/P` 是换算、**不是线占空测量**）。
2. ⭐ **BID ≥ 0xA 会暴露大小写敏感的身份门**：`reg_rw` 打 `0x0000000a`、判据写 `0x0000000A`、原代码是**字符串**比较 ⇒ **必假红**；8/9/7 全是数字 ⇒ 结构性从未暴露 —— **首次出现含字母的常量会踩**。修 = 比较前大小写归一（4 处就地订正），**判据语义零改动**；`p7b_gate4_accept.sh` 用**数值**比较 ⇒ 免疫。（另：BID_SYNC 轮把 10 处默认值统一到 0xA，`gen_inputs.py` 的活守卫实测"半同步 ⇒ 结构性拒绝 + 一个字节都不写"。）
3. ⭐ **对端 NIC 计数在 ~1M fps 虚高 ≈18%（逐包仪器在极高帧率下不可当绝对量）**：J0 窗 NIC 记 **983,201 fps > 几何上限 809,578 fps（物理不可能）**；`ethtool` 与 `ip -s link` 同源同偏；**比值口径（`Δbytes/Δpkts`）不受虚高影响** ⇒ 判据应优先用板侧计数 + 比值口径，且凡拿 NIC 绝对计数做判据的先过 "线上时间预算" 这一关。
4. ⭐ **"烧成了没有" 要读被测件自己的身份，不信烧录器 stdout**：本轮抓到一次**静默没烧成**（板侧仍读旧 BID、`tcpreg_program_stdout.txt` mtime 未更新 ⇒ 那次 bat 没有真正落盘执行）；判据 = **板侧 BID 读数**（身份门），不是 bat 的输出。

（同族两条已登记：台架**无 `timeout` 护栏**时 sink 永久阻塞会把 ssh 通道拖死、stdout 丢失 ⇒ 护栏是取证的前提；FIN 卡死 1/280 未定位、对端 `p6b_smoke_gate.sh` 是修前副本 —— 见 `P7B_BOARD_STAGEC.md` §6。）

### ④ 现状 / 未结项（**别写成已完成**）

- ⚠️ **板上现态 = Stage C 位流 `1609d6f5…576f3c`（63 字 / BID 0xA）/ 受控停流态**（`0x08 = 0x2` ⇒ `carrier = 0`）；**恢复 = `reg_rw /dev/xdma0_user 0x08 w 0x0`** 或重烧。
- ⛔ **未能证明**：洞的最后一米（对端栈内部，无逐洞见证）· **拆刀未做**（A2 / `TCP_TX_OVL` 单独效应）· 板的 dup-ACK 阈值 / 重放粒度（无 RTL 级证据）· **9.456 Gbps 可达性未证**（不是 "已证不可达"）· 双向 TCP-数据 × TCP-数据构型没做 · 对端 NIC 虚高机理未定位。
- ⚠️ **F1**（阻断级**既存**缺陷 = `retx_hi` 被 `+1` 越顶 ⇒ `ring_delta` 下溢 ⇒ 重放洪水；对抗审查抓出、已修**两分支** + 新判据有牙）—— ⛔ **板上事件计数未接快照**（`stat_retx_wrap` = **静默类**）⇒ **不许读成 "板上已验证它不再发生"**。
- ⛔ **`W55` 的口径已更新**（见 ②-③）：读 `P7B_BIZ_S2.md` §10+ 的 `W55` 定案时，须并读本轮 "它是自持环的一环" 这条。
- **未结项与下一步 = `_proj_10g/notes/P7B_LOOP_HANDOFF.md`（新 session 入口）**。

## 2026-10-09 P7b 长流刀（S3）+ 台架提速 + 时序知识

> 起点 = 用户 2026-10-09 逐字目标「继续调试测试框架和 fpga 测的 app，**特别是 tcp 的，让单连接的实际流量能不断接近线速**」
> （⇒ 单连接吞吐方向的 RTL 改动已获授权）；设计件 = `_proj_10g/notes/P7B_LONGFLOW_DESIGN.md`（含末"板级结果块"）。
> **一句话**：**单连接持续下行实测 9.1–9.3 Gbps = 设计上界 9.456 Gbps 的 98.5%（最快合格跑口径）** —— 长流刀达标。

- **① 先被时序门拦下，并由此拿到一条本工程级结论**：长流刀第一版 = `board/wrapper_p4.v` **只改两个数据常量**
  （`.TX_BYTES` 2²⁰→2³¹ + `BUILD_ID_V` 0x11→0x12）⇒ **WNS `+0.014 → −0.035`（0 → 24 个 setup 失败端点）**
  ⇒ 按纪律**停在"上板前"**（⛔ 不许 '重跑到过为止'）。归因靠**两条位级对照**（事前声明三条落盘在
  `p7b_build_longflow/INDEX.txt`）：**R1 重跑（同输入）= 位级复现**（`cmp -l` 只差 5 字节 `.bit` 头时间戳、
  WNS/TNS/端点数逐字相同）；**C1 对照（常量改回 r6-fix 值）= 逐字回到 `+0.014`/`0/0/0`** 且与归档 r6-fix 位流
  位级复现（6 字节头差 + `SW_CRC=da663843` 逐字相同）⇒ **同输入重跑方差 = 0 ⇒ 差异只能归因于输入差异**
  ⇒ ⛔ **"改常量就安全"不成立**（数据常量参与综合/实现；本条 = 全局 **#63**，且它顺带作废了全仓 6 处
  "同输入重跑会漂 ±0.4–1.3 ns"的误引 —— 那个幅度是**两个不同网表之间**的位移）。
- **② 常量阶梯（换目标轮）**：S1 2²⁴ `+0.016` 首个合格即停 → **换目标为"找最长合格档"**（准则一字不动、事前声明落盘）
  → S2 2²⁶ `+0.052` / **S3 2²⁸ `+0.052`** 均合格 ⇒ **取 S3**（256 MiB−1 B ≈ **227 ms**/会话，BID `0x15`，
  位流 **`492c3579…dc42c`**）。阶梯全景（五档同机同流程）= 2²⁰ `+0.014` · 2²⁴ `+0.016` · 2²⁶ `+0.052` ·
  2²⁸ `+0.052` · 2³¹ `−0.035`（24 端点）⇒ **非单调、有断崖、每档独立**（全局 **#64**）。
  ⚠️ 2²⁹/2³⁰ 未跑 ⇒ "最长"只在阶梯内成立；BID 与 TX_BYTES 的时序贡献**未分离**（无分离臂，如实登记）。
- **③ 板级（S3 / 10 跑 / 同板同线）**：
  - **主读数（板侧内窗）= 9.108 Gbps**（LF8；实测 `P = 200.4` 拍、`193/P` 换算 96.3%）= 设计上界 **96.3%** / 天花板 9.4935 的 **95.9%**；
    ⛔ **2026-10-10 订正（口径）**：原写"线占空 96.3%"—— `W43` 每拍无条件 +1（`mac_tx_10g.v:330`）⇒ `P ≡ 156.25e6/fps`
    ⇒ `193/P` 只是"fps 未达几何上限"的**换算式**，**不是线占空测量**（板侧无线占空计数器）；速率读数保留；
    **同档最快（对端墙钟 230.6 ms 全程）= 9.314 Gbps ⇒ 98.5% / 98.1%**（"98.5%"指这一格）。
  - 内容/记账：**10 跑 `ΔW51 = 268,435,455 = TX_BYTES` 逐位精确** · `first_mismatch=-1 / mism_bytes=0`（逐字节全查）·
    饱和档 `ΔW15/ΔW51 = 1.000000`（重传字节 = 0）· 板侧丢弃/溢出守卫全 0 · NIC `B/pkt = 1517.9676` 恒定。
  - ⭐ **对产品口径的意义**：`3.69 Gbps`（RETXFIX 台架下界）与 `8.4 Gbps`（Stage B 台架受限读）**都不是板子上限**；
    但**达标前提 = 台架接收侧被正确配置**（本轮 = 关掉对端网卡 RX 中断合并；默认配置同一位流只有 6.5–8.4 Gbps）。
- **④ 台架提速（本轮同步完成，根治"台架是帽子"这个问题）**：`P7bPat::check` 的逐字节 `seq` 路径 = 每字节 6 拍串行链
  （封顶 5.13 Gbps）⇒ 换 **M⁸ lane-parallel**（与 RTL `xs_next8` 同一数学、逐位等价已自证）：**`--check lane8`
  时纯校验 11.27 / recv-check 9.53 / 双线程端到端 11.1528 Gbps（×2.27）** ⇒ **端到端已站到天花板 9.493 之上，台架不再是帽子**
  （默认仍是 `seq`；⚠️ 开关写法 = **两个参数** `--check lane8`）。原件 = `_proj_10g/notes/p7b_affinity/BUILD.md` §5d。
- **⑤ 台架帽三连环（先证伪、再判板）**：校验路径三臂阶梯按设计走（`seq` 臂 `slot_wait_spins` 自证）→ 对端接收窗**构造性排除**
  （`--rcvbuf 128 MiB` 反而更慢、`Recv-Q≈0`）→ ⭐ **真凶 = 对端网卡 RX 中断合并**（`Adaptive RX on, rx-usecs 60`；
  同会话唯一变量 A/B ⇒ 关掉后 9.108/8.992）。全局 **#68**。
- **⑥ 仪器三处失效（新覆盖，下游引用必带）**：① **12 字快照 ~288 ms > 整条流 227 ms** ⇒ 快照系列**全落在流外**
  （改 5 字短表才塞得进）· ② **`sfc` 网卡硬件计数周期刷新**（流后 1.7 s 读到 = 旧值，加 `pre2/post2`）·
  ③ **`--check lane8` 实为两个参数**（写成一个词 ⇒ RC=2 硬失败）。⇒ 全局 **#67**。
- **⑦ 两条读码结论被读数处置**：`ΔW55` 的"饱和流每 ~20 ms 一次全窗重放"预测（227 ms 档预期 ≈11）
  **被实测证伪**（饱和档 `ΔW55 = 1/0/0/0`；`>0` 只出现在**线未饱和**档 3–19 ⇒ 与"卡不卡"相关、与"饱和时长"无关，
  机理未复核）；**C8（RTT 见证）未判定**（纯接收方向 `ss -ti` 只有握手 RTT ⇒ 既不能声称被窗帽限住、也不能声称排除）。
- **⑧ 工作树与现态**：**`D:\repo\XCKU5PMini\udp_hls_10g_fix`（另一 session 的工作树）已于 2026-10-09 删除** ——
  删前审计（是 `origin/master` 祖先 + 已跟踪文件零改动）⇒ 无提交/合并遗留；**唯一副本保全到
  `_proj_10g/notes/p7b_retxfix_salvage/`**（368 MB / 280 件；**r6-fix 位流新路径 = `…\bits\8c8b6126__wrapper_p4.bit`**）。
  ⚠️ 保全件 `burn_r6fix.bat` 内部三条路径仍指已删旧树 ⇒ **直接跑会白跑**（现役烧法 = `TCPREG_BIT` 指向该位流 + 主树
  `p7b_biz_tcpreg\run_program_tcpreg.bat`）。⚠️ **"`vivado_prj` GUI 重编 = '永久禁发'陷阱"仍有效**（指本树自己的
  `vivado_prj/p7b_ku5p_prj.srcs/sources_1/imports/board/wrapper_p4.v`，2026-10-09 复核仍是 BID 0xA / 0 处 `ack_seen`）
  ⇒ **构建只走 `board/run_build_p7b_ku5p.bat`**。
  **板上现态 = S3（BID `0x15`）+ 受控停流**（`0x08 = 0x2` ⇒ `carrier = 0`；恢复 = `reg_rw /dev/xdma0_user 0x08 w 0x0`）。
  ⚠️ 对端网卡合并与 `rmem_max` **已还原**、无遗留进程、未新建 pcap（10 跑全 `PCAP_ACTIVE=0`）。
- **⑨ 未测/未定位（不许当已答）**：C8 · 残余散布（coalescing 关掉后仍有 LF10 = 6.80 Gbps 离群，n=4，机理未定位）·
  `P > 193` 的 **8.15 拍/帧等效帧周期差**未拆开（窗帽 / 对端 ACK 回流 / app 残余开销三者未分离；⛔ 2026-10-10 订正（口径）：`W43` 每拍无条件 +1 ⇒ `P ≡ 156.25e6/fps`，该差值**不是**"线上空转"的测量 —— 它是 `(1/fps − 1/fps_max)×clock` 的换算式；板侧无线占空计数器）· r6-fix 跨刀锚未跑 ·
  UDP 泛洪负对照未跑 · `seq` 快档复跑未跑 · **LF5 窗内 4 个 CRC 错帧**（对端 NIC 累积 0→4，其余 9 跑 0）未定位 ·
  2²⁹/2³⁰ 档未跑。
- **⑩ 新增全局经验 = `~/.claude/fpga_net_dev.md` §六 #64–#68**（#64 改常量不安全 · #65 级数变短 ≠ slack 变好 ·
  #66 端点清单藏族 + WNS 是不同对象 · #67 仪器高码率下变慢/窗口落到流外 · #68 先查对端网卡中断合并）。
  原件 = `_proj_10g/notes/p7b_longflow_board/ACCEPT.md`（板级；含 10 跑表 + `runs/LF*.txt`）·
  `p7b_build_longflow/{INDEX.txt,S_LADDER.txt,S1,S2,S3,R1,C1}` · `_t3_family/`（族分析原始件）。

## 2026-10-09/10 P7b-LONGSEND: 「长时间不停发送的 app（TCP + UDP）」板级收口 + 一条假结论的就地证伪 + "窗帽收益"如实记为【未判定】

> 起点 = 用户逐字派单「实现长时间不停发送的 app，实现线速发送，**TCP 和 UDP 各实现一个**」。
> 轮级收口件 = `_proj_10g/notes/P7B_LONGSEND_ACCEPT.md`；**新 session 入口 = `P7B_LONGSEND_HANDOFF.md`**；
> 设计件 = `P7B_LONGSEND_DESIGN.md`（§7 实现轮 / §8 板级追加块）。

- **① TCP 连续发送 = 新实现（构建 A）**：`rtl/app_pattern.v` 新参数 `TX_CONTINUOUS`（**默认 `1'b0`**）+
  `board/wrapper_p4.v:1186-1187` 传 `1'b1`；实现点 = `:360`（`CONT_OK`）`:364-365` `:691` `:705/:755` `:711/:760`。
  **默认关 = 逐位退化（实证，不是论证）**：ARM A vs 冻结锚 `frozen/app_pattern_rev0e804099.v` 在 **24 个交付文件上 `fc /b` 逐字节相同**。
  位流 **A = `052c5200…30bc284`**（15,431,261 B · `SW_CRC 2c237c32` · **BID `0x16`** · `WNS +0.021 / WHS +0.010 / 0/0/0`）。
- **② TCP 板级（A 臂长跑）**：单连接 **236.3 s / 270,000,000,495 B = 1005.83 个 `TX_BYTES` 量子** / 逐字节零失配 / 零 stall；
  **三口径互差 ≤0.4%**（板内窗 **9.1377 Gbps** · sink 墙钟 **9139.1 Mbps** · 对端内核 **9.1709 Gbps**）；
  **跨 62 次 2³² 回卷无可分辨异常**（含/不含回卷区间速率中位差 0.02 Gbps、`ΔW23` 两组恒 0）；
  板 `ΔW20 = 184,949,978` **= 对端 NIC `Δport_rx_packets` 逐位相同**。原件 = `p7b_longsend_board/ACCEPT.md`。
- **③ UDP 连续（本来就连续，本轮落成 300 s 读数）**：板上例化 `TX_BYTES=0`（`wrapper_p4.v:2525`）靠**三处短路**
  （`app_udp_pattern.v:529/:537/:853`）—— **不是靠计数器回卷**。**L1 = 300.014 s**：板内窗 **9.5336 Gbps / 809,577.8 fps**、
  ⭐ **300 个逐秒段取值集合 = {9.5336}（min=max=mean）**；对端 NIC **809,081.4 fps**（两口径差 **−0.06%**）；
  内容两跑各 3000 帧逐字节。⚠️ **天花板 = UDP 口径 `1472/1538×10 = 9.5709 Gbps`**（实测 **99.61%**）——
  **历史 TCP 口径 9.4935 对 UDP 不适用**。原件 = `p7b_udp_longrun_20261009/`。
- **④ ⛔ 一条假结论就地证伪（本轮最高优先的知识订正）**：`P7B_LONGSEND_DESIGN.md` §5.2 曾把
  「慢路径（ARP/ICMP/SYN-ACK/建连）在严格优先仲裁下**可被永续数据源无限期饿死**」当**已确立的缺陷**写进去 ——
  **板级实测证伪**：泛洪**已持续 300 s 时**，对端 `ping -c 5` **5/5 通**（rtt avg 0.094 ms vs 不泛洪基线 0.077 ms）+
  `nc -z 8080` **TCP 建连成功**（SYN-ACK 只能来自 HLS 慢路径）；两跑共 10 个 ICMP 应答 + 2 次建连。
  **机理（推断，未证）** = 结构读法本身没错（严格优先 + 只在帧末重仲裁），**漏了快侧本来就有每帧 ≥2 拍气泡**
  （`T_DONE` 1 拍 + `tx_arb` 帧间 1 拍重仲裁）⇒ "无 aging" ⇒ "必然无界饿死"**推不出**。
  ⚠️ **顺带订正**：`rtl/tx_arb.v:1-3` 与 `board/wrapper_p4.v:2449-2466` 的设计理由（"单帧有界 ⇒ 互不无界阻塞"）**没被证伪**；
  `wrapper_p4.v:2096`/`tcp_tx_frame.v:452` 记的"SYN-ACK 被饿死 ~14 µs"是**有界**延迟（r5/r6 板级定案）⇒ 相容。
  **慢路径 aging 里程碑 = 已取消**（其动机已消失）。§5.2 已整条改写（2026-10-10）。
- **⑤ ⛔ "窗帽抬升（49150→61440）是否带来收益" = 本轮【未判定】（不是"无收益"，也不是"证伪"）** ——
  三条理由：① 负对照臂 S3 **结构性做不出长窗口**（发满 `TX_BYTES=32'h0FFFFFFF` 即 FIN ⇒ 227 ms 天花板）；
  ② **短窗噪声主导**（S3 9 跑 3.7513–8.6503 Gbps / A 短跑中位 7.3421 · 中位差 30% 但**秩和 `p≈0.34` 不显著**，
  而 **A 长跑 9.1377 > 短跑中位** ⇒ 短窗很可能被建连瞬态拉低，**候选未分离**）；
  ③ **同位素臂无判别力** —— 只压对端通告窗（450 KB→42 KB，见证 `rcv_space`）却落在**未贴窗的低档**
  （7.2390→7.5982 Gbps、`P = 251.9/240.1`、`193/P` 换算 76.6%/80.4%；⛔ 2026-10-10 订正（口径）：原写"线占空"—— `W43` 每拍无条件 +1 ⇒ `193/P` 是"fps 未达几何上限"的换算式、**非线占空测量**）⇒ "压窗不掉速"推不出"窗不是限速源"。
  **配对 A/B 3/3 对 A ≤ S3**（−3805.2/−220.2/−220.0 Mbps）只支持"未观察到可判定的涨幅"。
  **`WIN_CAP_5` 保留** = 未判定不构成回退理由 + 回退会作废已验收位流 —— ⛔ **不许写成"保留作 BDP 余量"**；回退 = 改一行。
- **⑥ `P` 与几何预期的差没缩小**（⛔ 2026-10-10 订正（口径）：原写"死拍没缩小"—— `W43` 每拍无条件 +1 ⇒ `P ≡ 156.25e6/fps`，该差值 = **等效帧周期差**、非"线上空转"的测量）：A 臂 `P ≈ 199.7`（由 9.1377 反推；桶均 199.06）vs S3 200.4 ⇒ 同基差 ≤1.3 拍（散布内）；
  三候选（窗/BDP · 对端 ACK 回流节奏 · app 残余开销）**仍未分离**。⇒ 下一轮：**构建 B-1**（补 `win_open==0`/`frm_wait`/`txcdc 空拍` 三计数器）
  / **构建 B-2**（A-minus 臂 = `TX_CONTINUOUS=1` + `WIN_CAP_5` 回 `0xBFFE`，唯一能给"窗帽"干净判决的构架）。
- **⑦ A7 静默形态（本轮不修，已复现）**：连续模式下"对端关闭 → 同槽重连"可能 `ev_up` 被吞 ⇒ 新连接静默零数据、无自愈
  （`u_rec1/k=40`、`u_rec2/k=240` ⇒ `frames=1 starts_after_up=0`；`u_rec3` tready 低窗只 6 拍 ⇒ RESUMED）。
  ⭐ **反直觉：判别变量 = "`ev_up` 到达时是否仍卡在 closing"，不是间隔 k（k=40 ≤ 70 也照样被吞）⇒ 推翻"~70 拍窗口"的直觉**；
  机制**既存**（ARM A 不传 `TX_CONTINUOUS` 同样复现），连续模式只是把它从"窄窗"变"常驻"；最小修法 = +1 FF pending 位。
- **⑧ 未收口/未定位（不许当已答）**：`W29`/`W45` 在 UDP 泛洪中 ≈900/s 单调增（**机理未定位**）·
  `port_rx_nodesc_drops` 1.72%（对端描述符耗尽 ⇒ 对端限速，非板缺陷）· 两处 RFC 偏离（绝对比较；
  62 次回卷未观测到后果，"没观察到"≠"不存在"；⚠️ `rtl/tcp_rx.v:284` 注释"回绕安全"措辞过宽 = 待订正）
  · **（本轮新发现）L1 的 `W11/W13` 在 learn 窗非 0（`ΔW13 = +11,917,714`）而 L2 同相位为 0 ⇒ 未归因**
  · G3 门跑不通（既存工具缺陷：`tcp_tx_frame.v` 是 CRLF 2040 个 CR + `mut_c2` 锚点陈旧；与本刀无关已用 `git hash-object` 证）
  · 常驻矩阵编译清单不含 `app_pattern.v`/`wrapper_p4.v`（**空证据**；`sim/` 下含 `app_pattern #(` 的镜像件实测 **71 个**）。⛔ **2026-10-10 订正（构建 F 轮）：旧值 71 未能复现** —— 现核 = **全仓 161 个文件**（`sim/` **79** + `_proj_10g/` 39 + `vivado_prj/` 32 + `tb/` 7 + `rtl/` 1 + `board/` 1 + 顶层 `.md` 2；`.md` 共 9，其中 7 个已在 `_proj_10g/` 的 39 内；**本次自行 `grep -rl` 重跑、逐项复现**）；**旧值口径 = `sim/` 内，同口径现测 = 79** ⇒ **"风险面更大"**。原句保留。
- **⑨ 几条通用坑（本轮实测，详版 = 设计件 §5.6-9..17）**：`cmd /c` vs `cmd //c` 是**条件式**陷阱（判据 = 本次的 `HIGH` 行 + mtime）·
  `--check lane8` 是**两个参数**（**本轮已就地订正 `lf_dl.sh` 用法注释** —— 该文件 md5 因此变化，部署前须重核）·
  `--maxbytes 0` = 立即退出（**RC=1 假红**）· `--seconds` 不终止正在跑的连接 · `TCPREG_PROG_EXIT` 不在 stdout 文件里 ·
  `W51` 跨连接累积 · **`carrier=0` 时板侧照跑 ≈809,578 fps 而对端 NIC 全 0 ⇒ 两条测量口径的独立性被直接证实** ·
  `0x08 w 0x2` = **物理停发** ⇒ 不能当"停流后对照"。
- **⑩ 环境与现态**：板上现役 = **A 臂（BID `0x16`）+ `0x08 = 0` + `carrier = 1`（未停流）**；
  对端中断合并收尾态 = **off**（`p7b_env_restore_20261009/12_final_state.txt`；跑长流必须 off = #68）。
  环境恢复五项 + 重烧配方 + 位流 sha256/BID 对照表 = `_proj_10g/notes/P7B_LONGSEND_HANDOFF.md` §2–§4。
  原件 = `_proj_10g/notes/{P7B_LONGSEND_ACCEPT.md, p7b_longsend_board/, p7b_udp_longrun_20261009/, p7b_build_longsend/}` ·
  `p7b_env_restore_20261009/`。

## 2026-10-10 P7b A7 轮（构建 D + E）: 线空闲首次直接测量 ⇒ **墙是窗口**（~88–90%）· R-1 重定时把 WNS 从 +0.006 救回 +0.099 · 一条被否掉的路线（尾字 carry 零收益）

> 两档构建 + 两轮板级：**D** = R-1「T+2 重定时」+ 退回尾字 carry + 线空闲计数器（`stat_tx_idle`→**W65**）+ 快照 66 字；
> **E** = 帧器侧窗口门计数器（`stat_winstall`→**W66**）+ A3 重连修复 + 快照 **67 字**。
> 原件 = `_proj_10g/notes/{P7B_A7_BUILD.md, P7B_A7_CSUM_SINK_DESIGN.md}`（实现/设计）· `p7b_build_a7/READINGS.txt`（构建 D）·
> `p7b_buildE_build/READINGS.txt`（构建 E）· `p7b_a7_board_20261010/`（板级 D 轮）· `p7b_buildE_board_20261010/`（板级 E 轮）·
> **新 session 入口 = `_proj_10g/notes/P7B_A7_HANDOFF.md`**。

- **① ⭐ 设计件手数 193 精确无误，`P` 的差额 100% 是线空闲**（三步独立复现）：`ΔWnonidle/ΔW20 ≡ 192.9999`
  （三次跑 + 每个逐区间，恒定到 1e-4）⇒ **MAC 服务时间恒 193.000 拍/帧**；`ΔW65/ΔW5` = **3.16% / 21.19% / 23.25%**、
  `ΔW65/ΔW20` = **6.30 / 51.90 / 58.45 拍/帧**（`p7b_a7_board_20261010/runs/{FINAL_TABLE.txt,DERIVE.txt}`）。
  ⇒ ⛔ **此前"设计件手数少了 ~7.4 拍"的说法作废**（差额是一个从来没人计过的独立量）。**空载正对照** =
  `ΔW43 = ΔW65 = 160,307,432` 逐位相同（比值 1.000000000；`D_idle_control.txt`）。
- **② ⭐⭐ 线空闲里 ~88–90% 是【窗口】⇒ "墙是窗/BDP"被坐实**：板级三跑 **`ΔW66/ΔW65` = 0.876 / 0.899 / 0.881**
  （三跑取值极差 = 0.023；逐区间中位 0.875/0.913/0.881），跨 **5.7–9.3 Gbps**、跨空闲占空 **2.1%–39.4%** 都稳定
  （`p7b_buildE_board_20261010/runs/{FINAL_TABLE.txt,DERIVE.txt,CORR_IDLE_W66.txt}`）⇒ **不是帧器流水、不是 app 生产节奏**。
  **白送负对照** = 无连接 2 s 窗 `ΔW65 = 318,344,982`（自由计数）而 **`ΔW66 ≡ 0`**（`A3_RECON.txt`）。
  ⚠️ 约 **12%** 的线空闲**不归窗口门**；按实现轮登记的盲区（`ΔH` 无计数器）**不许逐拍归因**。
  ⚠️ 窗口门的**子成因 = 已分离（2026-10-10 窗口侧轮；见本节末尾追加块）**：按窗大小分工 —— 窗 ≳30 KB ⇒ 板的 `WIN_CAP`(61,440) 咬合；≲20 KB ⇒ 对端侧接管。
- **③ R-1 是本轮最实的一刀（但归因受限）**：把 `ctrl_tcpcsum`/`ctrl_ipcsum` 的装载**推迟 1 拍、改从已寄存的 `ctrl_*` 复算**
  （+1 FF）⇒ **WNS `+0.006 → +0.099`**（C→D），**旧锥 `ctrl_tcpcsum_reg[*]/D` 整体退出报告面**（C 档 27 次 → D 档 0 次）。
  ⛔ **不许写"时序问题已解决"**、**不许把改善单独归因给 R-1**（D 捆绑三项改动、无拆刀 A/B）。⚠️ E 档 WNS 宿又换对象
  （`u_app/stg_reg[4]/D`），且**新计数器是否加深该锥 = 未定论**。
- **④ 五档 WNS 轨迹 + 位流身份**：S3 `+0.052` · A `+0.021` · C `+0.006` · **D `+0.099`** · **E `+0.090`**；
  **三类失败端点五档全 `0/0/0`**；**五档位流全为 15,431,261 B ⇒ 只有 sha256 与 BID 能分版**。
  现役 = **构建 E（BID `0x19` / sha256 `b88b2bee…a64f`）+ `0x08 = 0` + `carrier = 1`**（`FINAL_STATE.txt`）。
- **⑤ ⛔ 一条被否掉的路线（否定结论）**：**尾字 carry**（Gap #9 的 TX 半边）**零收益** —— 高码率档 fps 中位
  **784,742 vs 负对照 785,558（−0.104%）**、两臂区间峰值同为 `802.7–802.8k fps`（退回理由块 `board/wrapper_p4.v:1197-1208`），
  却把 WNS 从 0.33% 吃到 0.094% ⇒ **构建 D 已退回**（`.TX_TAILCARRY(1'b0)`，一行）。
  ⭐ 同批**证伪"app 生产节奏是瓶颈"**：该臂把 **app 下游的 TX CDC FIFO（`u_txcdc`，`board/wrapper_p4.v:2748`）喂到满**
  （`W28 = 256` = 满深度、`W45` 拒写 **≈5.6×10⁷–6.1×10⁷ 拍**；`p7b_gap9_tx_board_20261010/runs/FINAL_TABLE.md`）而**帧率一点没涨**
  ⇒ **约束在下游** ⇒ **整条"提高 app 产字率"的路线（含 8 路发生器）关闭**。
  （⚠️ 文档轮口径核实：`W28`/`W45` 量的是 `u_txcdc` = app 下游最后一级队列，不是"app↔帧器"那一级；结论方向不变。）
- **⑥ A3 修复**（连续模式"对端关闭 → 同槽重连"吞 `ev_up` ⇒ 新连接静默零数据）：`up_pend_r`/`up_pend_id` 待补登记位
  （`rtl/app_pattern.v:384-385/:503-505/:784-790`）。**板级 5/5 重连回合第二条连接照常收数据**
  （A3E 三回合 `bytes2` = 1,517,494,075 / 1,576,631,375 / 1,652,378,950；A3T 两回合 = 1,034,765,805 / 1,475,338,035；
  `runs/{A3E.txt,A3T.txt,A3_RECON.txt}`）。⚠️ **本轮没做同会话负对照**（A3 全部板级回合都跑在 E 位流上，`a3_round*.sh` 无 D 臂）
  —— ⛔ **文档轮订正**：E 轮 A3 脚本里写的理由"（D 档也含 A3 代码）"**与源码不符**：构建 D 的 `rtl/app_pattern.v` sha256 `387a7d94…`（与 C 档逐字相同，`p7b_build_a7/READINGS.txt` 步骤 0）⇒ **D 不含 A3 修复**（A3 修复 = E 档 `811a84e4…`）
  ⇒ 准确说法 = "**没做**"而非"做不了"，**D 位流可作 A3 的改动前负对照**（E 轮已把冻结锚 arm G 用同一逻辑钉成"改动前负对照"，见 `p7b_buildE/apply_contgate.py` 头注释）；⚠️ **"pending 补做路径真被触发过"未证**。
- **⑦ 上行天花板（零构建轮，`p7b_uplink_ceil_20261010/`）**：memset 构型（对端换发送件）把**上行稳态推到 6.16 Gbps**
  （`an_run_UC_memset.out`：`SUM_STEADY` UP = **6159.195 Mbps**），而限速级 = **板自己通告的窗**（对端 `ss -ti` 逐点
  `rwnd_limited:100.0%`、`snd_wnd` 在 47752/49152 量级；`up_UC_ss.txt`）⇒ **Stage B 记的"上行 4,058–4,151 Mbps"
  应读作台架（对端发送侧）帽**，不是板端上限；**双向单连接**（同一条连接上行+下行同时跑）稳态 = **8.876 / 9.045 Gbps
  = 10 Gbps 的 88.8% / 90.5%（≈89–90%）**（`an_run_UG_guards.out` / `an_run_UD.out` 的 `SUM_STEADY`）。
- **⑧ `P` 口径**：上一批已把「线占空 = `193/P`」全仓订正为**恒等式**（`W43` 每拍无条件 +1 ⇒ `P ≡ 156.25e6/fps`）；
  本轮的**线空闲计数器（W65）是它的替代仪器**（语义 = `state == S_IDLE` 拍数；`S_IFG`/`S_FLUSH` 不算空闲）。
- **⑨ 工具/仓储**：`.gitignore` 那条**自相矛盾的整目录规则**（`sim/p7b_stagec_tx_regress/author_gate/` 整目录忽略 ⇒
  门驱动/脚本会被静默丢掉）**已改成按类排除**（`author_gate/mut/` + `author_gate/run*/`；`dcf2bb6`）；
  变异器三病根修复入库（`15defaf`）；三个计数器变异**已登记进常驻清单（M18–M20）**
  （`_proj_10g/p7b_mac/scripts/mutate_gate.py:151-159`，`dcf2bb6`）；取数器 `p7b_snap.sh` 的 `NAME[]` 补上 `[65]/[66]`。
- **⑩ ⛔ 未收口（不许当已答）**：**窗口子成因 = 已答（⇒ 本节末窗口侧轮追加块：按窗大小分工）** · **~12% 线空闲归因未证** · **窗帽 49150→61440 有无收益仍未判定**
  （需 A-minus 臂 = 构建 B-2；⚠️ 其判决价值已被「抬窗线收益上界 +1.5～2%」压住 ⇒ 优先级下降，见追加块）· **`WIN_POOL`（板通告接收窗）= 上行墙，未做**（产品级）· `retx_ram`→URAM 未做（等窗帽判决）·
  **新增未定位（窗口侧轮）**：**`L`（每窗刷新死时间 0.9–11 µs）** · **板侧有效 wscale = 0 的机制** ·
  `gen_inputs.py` **仍停在 63 字/`0x0A`**（落后两代 ⇒ `negctrl_fix3.sh` 第一步 FATAL）· 同族变异器"失败仍落盘"地雷仍在两处旁支 ·
  `lf_dl.sh:90` 锁屏行仍硬编码 `NW=63`（⚠️ 窗口侧轮的 12 跑 `GEOM:` 行全部复现这一显示误标 —— 靠身份闸兜底、非数据错） ·
  `A12` 残差（`ΔW51 − sink`）E 轮未复算 · A4（`W45`/`W28` 机理）仍未定位。
  逐条四格 = `_proj_10g/notes/P7B_OPEN_ITEMS.md`（窗口侧轮后已刷新）。
- **⑪ 三条可复用的教训**：① **"读数低"先查对端配置**（#68 同族：本轮整套读数都要求 `adaptive-rx off rx-usecs 0`）；
  ② **"差额"要先问"有没有仪器测过它"** —— 上一轮的"死拍"说法在补上 W65 后变成"100% 是线空闲"，**换掉的是问题本身**；
  ③ **给计数器起名要连"量在哪一侧"一起定**（`W28`/`W45` 的"app↔帧器"口头指称与真实拓扑 `u_txcdc` 不符，本轮已核实订正）。

### 追加（2026-10-10 晚）：**窗口侧判别实验**（零构建 —— 只压对端 `--rcvbuf`，位流不动 = 构建 E / BID `0x19`）= A7 §7-选项1 的收官

> 原件 = `_proj_10g/notes/p7b_window_side_20261010/`（79 件；主表 `runs/RAWK_FINAL.txt` / `runs/DERIVE_ALL.txt` ·
> 线上窗见证 `runs/WS_WITNESS_ALL.txt` · 抓包探针 `runs/DP_*` · 逐跑 `runs/WS_*.txt`）。

- **① 线上真值：本构型【没有窗口缩放协商】**（两条独立见证 = tcpdump 逐 ACK 抓 win 字段 / 6 个探针 + 对端 `ss` 的 `wscale 取值集合={'None'}`）：
  SYN = `win 64240, options[mss 1460, sackOK, TS, nop, wscale 10]`（对端**请求了** wscale）；**SYN-ACK = `win 49152, options[mss 1460]` ⇒ 板没有回 wscale**
  （= `hls/src/layer_tcp.cpp` 里的**刻意设计**，非缺陷）⇒ 该方向按 RFC **不缩放** ⇒ **对端通告窗被 16 位字段硬顶在 65,535**
  （对端 socket 想给更多：`ss` 的 `rcv_space` 到 **481,800**）⇒ **板侧有效窗 = `min(65,535, WIN_CAP 61,440)` = 61,440**
  ⇒ **基准档咬合的是板自己的 `WIN_CAP`**（对端只多给 6.7% = 65,535/61,440）。
- **② 响应曲线（线上窗 → 速率；sink 墙钟口径，每档）**：**65,535（基准）→ 9,150 Mbps**；**33,580–35,040 / 26,280**（对 61,440 的 0.55× / 0.43×）→
  **与基准不可区分**（9,188 / 6,917 与 8,974 / 8,946）；**11,680**（0.19×）→ **5,101**（−38～−50%）；**2,920 → 1,872**；**1,460（≈1 MSS）→ 888**（−90%）
  ⇒ **分工：窗 ≳30 KB ⇒ 板的 `WIN_CAP` 在咬；窗 ≲20 KB ⇒ 对端侧接管**并严格决定速率。深压 = **如实节流**（12/12 `mism_bytes=0` 逐字节全查 ·
  冗余率 `W15/W51 ≤ 1.000731` · 对端 `ΔTcpRetransSegs = 0` / `ΔTcpOFOQueue = 0`（12/12 逐跑现核）· `ss` 的 `rcv_ooopack` 逐跑 ≤ 1,059（相对每跑 ~10⁷ 段可忽略；`runs/WS_WITNESS_ALL.txt`）· 缓冲从未满）；
  每档**非空闲拍恒 192.9999 拍/帧（12/12）**（= A7 恒等式的第二次独立复现）。
- **③ ⭐⭐ 裁定：整条「抬窗线」（`WIN_POOL` / 拓宽 `snd_wnd` 过 16 位 / 扩 `retx_ram` 迁 URAM）收益上界 = +1.5～2% ⇒ 不值得做**
  （量化理由 = 基准档窗等待**只占线时间 2.0–3.7%**（`ΔW66/ΔW43`）+ 对端相对板帽只多给 6.7% + 窗 ≳26 KB 后读数已平坦 + 16 位硬顶 65,535；
  ⛔ **不是"已排除"** —— 上界是算出来的、不是 0，也不是"证伪"）。其"正确前置"（先让窗口缩放真正协商出来）本就不成立 —— **板根本不发 wscale**。
  ⚠️ **边界**："+1.5～2%" 量测自**下行侧**（板为发送方）；上行侧（`WIN_POOL`）自己的直接判决不在本轮测量面上（A6/B2 登记照旧）。
- **④ ⚠️ 反着说的一半（更重要）："读数低"的第一主因不是窗帽** —— 同档**跨跑散布 6.9–9.24 Gbps（1.33×）与窗无关**
  （例：线上窗同为 26,280 的两跑读出 6,917 vs 8,974 Mbps）；把每档换算成「**每窗刷新的死时间**」`L = (W/1518)×(P−193)`：
  **W ≥ 26 KB ⇒ L ≈ 0.9–2.2 µs；W ≤ 11.7 KB ⇒ L ≈ 6–11 µs** ⇒ **抬帽换不回 `L`** ⇒ **`L` = 新增未定位项**。
- **⑤ ⚠️ 新增未定位：板侧有效 wscale = 0 的机制** —— 源码面上 HLS 被动路径**确实解析**了对端 SYN 的 wscale（本例 = 10）并下发 TCB
  （`hls/src/layer_tcp.cpp` / `rtl/slow_cfg_adp.v` → `rtl/tcb.v`），`rtl/tcp_rx.v:436` 也会按它左移 —— **但行为上与 scale = 0 一致**
  （深压档速率随线上窗塌陷）。当前"歪打正着"是**对的**（本构型无 WS ⇒ scale 必须 0）；**机制需一次构建/仿真级调查**。
- **口径**：`ID_BID 0x19 / ID_OK / 0x08 = 0 / carrier = 1` · `COALESCE = Adaptive RX: off`（12/12）· `PIN_CPU` 4↔5 漂移（与 2026-10-08 登记一致）·
  ⚠️ **`ss` 的 `rcv_space`/`rcv_ssthresh` 在基准档不是线上窗真值**（给 37,376–2,390,622 而线上 65,535）⇒ **裁据一律以 tcpdump win 字段为准** ·
  对端 sysctl「收尾与开工逐字相同」（**派单口径；⚠️ 文档轮未在 `p7b_window_side_20261010/` 内定位到该见证文件 —— 引用时按未取证读**）。
- **三条可复用教训（① 为文档轮新增；②③ 归纳自本轮口径）**：① **抓包方向要先定死**：下行（板是发送方）时只有 `'dst port 8080'` 抓到的是**对端的 ACK**（其 win = 对端通告窗）；
  `'src port 8080'` 抓到的是板自己的包（win = 板的 49,152）—— 首跑 `DP_B8M` 就踩了这个坑，修正后才取到 65,535（见 `wdump.sh` 头注释）；
  ② **`ss` 的 `rcv_space`/`rcv_ssthresh` 不是线上窗真值** —— 窗口类裁据必须回包层（tcpdump `win` 字段）；
  ③ **"抬窗收益上界"要先把 16 位硬顶算进去**：对端能给的只比板帽多 6.7% ⇒ 收益空间先天被限，再叠加窗等待只占 2.0–3.7% ⇒ 上界 +1.5～2%。

## 2026-10-10 P7b 构建 F 轮（`L` 首次直读 / `p5_wrapper` 既存红定位 = 真缺陷 / 两轮对抗审查 / 读侧加固）

> 四条线：**构建 F**（三个纯观测仪器 W67/W68/W69 + 快照 70 字）· **板级**（`L` 首次直读 + 8 跑内容/守卫）·
> **`p5_wrapper` 既存红定位**（真缺陷）· **读侧加固**（穷举 771 条 + 三条断言 + 4 条负对照）；另有两轮对抗审查（构建 F / Build G 设计件）。
> 原件 = `_proj_10g/notes/p7b_buildF_build/READINGS.txt`（构建）· `_proj_10g/notes/p7b_buildF_board_20261010/REPORT.md`（板级）·
> `_proj_10g/notes/p7b_p5wrapper_diag_20261010/REPORT.md`（定位，含 §7 追加轮）· `_proj_10g/notes/p7b_buildF_review_20261010/FINDINGS.md`
> 与 `p7b_buildG_review_20261010/FINDINGS.md`（两轮审查）· `_proj_10g/notes/p7b_readside_harden_20261010/`（读侧加固）。
> 提交 = **`34fb68b`**（构建 F 实现 + 构建归档）+ **`70d5d59`**（板级 + 审查 + 定位 + 加固）；**尚未 push**。

- **① 构建 F = BID `0x1A` / 快照 70 字 / 未实现地址 `0x138`**（= `0x20 + 4×70`，word 78；`board/wrapper_p4.v:3228/4050`）；
  位流 sha256 **`89e89f31efb5f1450a1c39acfce587bb4e4b6347c5fdc2f470c91ff0d4400f45`**（15,431,261 B；⚠️ `.bit` 按仓规**不进库**，只在 `p7b_buildF_build/F/`）。
  内容 = 三个**纯观测**仪器 **W67/W68/W69**（`tcp_tx_frame.stat_winstall_cap` / `tcp_rx.stat_ack_adv` / `tcp_tx_frame.o_win_at_winstall`）+ 搭车**纯注释**订正（`rtl/retx_ram.v` / `rtl/tcb.v` / `rtl/tcp_tx_frame.v` 里"帽值仍写 0xBFFE"的注释）。
  构建 **`WNS +0.111 / WHS +0.010 / 三类失败端点 0/0/0`**（`Slack (VIOLATED)` 计数 0；12 键硬门全 0）。
  ⚠️ 全局 `+0.111` = `u_pcie_xdma/inst/pcie4_ip_i/inst/user_reset_reg/C → u_pcie_regs/snap_words_r_reg[1797]/CLR`
  的 **`async_default` Recovery**（Logic Levels **0**、97.3% 布线）⇒ **不是数据面 setup**；**DP 域 setup WNS = `+0.281`**（宿 = `rel_sr_reg[3] → retx RSTRAMB`，纯布线）。
  ⇒ 与 E 档 `+0.090` **既不同对象、也不同检查类型（setup ↔ recovery）⇒ 不可比**（全局 #66）。**六档 WNS** = S3 `+0.052` / A `+0.021` / C `+0.006` / D `+0.099` / E `+0.090` / **F `+0.111`**；
  三类失败端点**六档全 `0/0/0`**；**六档位流全 15,431,261 B ⇒ 只有 sha256/BID 能分版**。三个新仪器锥**全部远离** DP WNS（最小 **4.2×**）、报告面 **0 命中**。
  ⚠️ **本构建跑了两次**：run1 在 **`xdma_0` IP OOC 综合子进程**上**工具级停滞**（三项冻结判据：CPU 三次采样零增长 / IO 计数零增长 / 16 线程全 Wait；**机理未定位**，只做了排除），
  按纪律 **#3 例外（判为"不可复现原因"）** **原样重跑一次**（run2 正常收口，全部读数来自它）。取证 = `p7b_buildF_build/hang_evidence/`（7 件）。
  归档：run1 = `ARCHIVE_DONE 20261010_091536`（内含 **E 档位流 + E 的 routed dcp**，双路核对 ⇒ 上一档取证已保全）；run2 = `ARCHIVE_SKIP`（因 run1 的 `create_project -force` 已抹 `impl_1`、而 run1 死在 bitgen 前 —— **如实记录，不是失败**）。
- **② ⭐ `L` 首次直读（8 跑 + 2 压窗臂 + 1 干跑）**：`L = ΔW66/(156.25·ΔW68)` 稳态区间中位 = **0.106–0.170 µs/事件**
  =（**显式换算**）**1.19–1.56 µs/窗**（基线四跑）⇒ 落在历史换算带 **0.9–2.2 µs** 内。
  ⛔ **量纲 = µs/事件**（`W66` 每拍 +1 / `W68` 单拍脉冲、每帧至多一次）—— **不是 µs/窗**（审查轮的订正）。
  ⛔ **"直读 ≈ 历史换算值 89–92%"是恒等式、不是独立互证**（比值 ≡ `ΔW66/ΔW65`；代数推导 = 板级 `REPORT.md` 的 **TL 附注**）
  ⇒ 直读的新增信息**只有两条**：**绝对量级** + **它改正了历史式的口径**（`L_hist` 含**全部**帧间空闲，窗口门只占 `ΔW66/ΔW65`）。
  ⚠️ **绝对准确度未证**：`W68` 已知**多计**（缺口 A/B，发生率未量）⇒ 系统性偏小；**未做**对端 pcap 全程 ACK 计数（`W22` 与 `W68` 在本构型几乎同源，差 0.022% ⇒ 不能互证）。
- **③ `W67` 分裂随窗翻转（措辞按【阈值归属】）**：基线 `ΔW67/ΔW66` = `0.9265 / 0.9272 / 0.9240` → 压窗 **`0.0000`**；**压窗三跑 + BF3 的 `W67` raw 逐位不动**（`215d7ddb`，跨越三次跑及以上）。
  线上窗见证（tcpdump `dst port 8080`）= `min 21,900 / med 26,280 / max 26,280` ⇒ 压窗确实生效。⛔ **`W67` 高 = 生效阈值是板帽 ⇒ 不推出"板是瓶颈"**。
  ⚠️ **同臂内自然翻转**（BF3 为**基线臂**、eff = 36,500 ⇒ `ΔW67 ≡ 0`）⇒ 对端窗取值**跑间不确定**（n=1，只登记、不外推；A17 的 1.33× 散布与窗无关这事不受影响）。
- **④ 板级内容 / 守卫（8 跑）**：`first_mismatch=-1` / `mism_bytes=0` / `fail_conns=0`；守卫 `W21/23/35/41/42/45/59/60` **全 0**；
  四跑 **9,044–9,216 Mbps / 774.7k–789.0k fps（散布 1.85%）**；**退化族 `infl ≫ eff` = 未观测到**（凡 `eff>0` 者 `infl−eff ∈ {0, 1,340 B}` = 撞帽同拍正常形态）。
  落场 = **BID `0x1A` / `0x08 = 0` / `carrier = 1`**（`FINAL_STATE.txt`）；⚠️ 对端残留点采样 pcap 未删（`§3.5` 的原始件）。
  ⚠️ 工具自述行 `LF_GEOM_OK NW=63` 是**硬编码字面量**（审查点名）⇒ **身份只引** `ID_BID 0x0000001a` + `ID_UNIMPL 0xffffffff`。
- **⑤ ⭐ `p5_wrapper` 既存红 = 真缺陷（不是门的问题）**：`board/wrapper_p4.v:2771-2775` 五行 `assign` **方向全反**（`ifndef DP_156MHZ` 的 TX 单域别名块）
  ⛔ **2026-10-11 订正（行号）**：现核真值 = **`:2784-2788`**（五行 `assign`）/ **`:2782-2783`**（两行订正注释）—— 2026-10-11 现读工作树（该文件当时带另一支构建 agent 的**未提交改动**，+5 行落在 `:2141` 一带）；位移链 = 修复前 `2771-2775`（本句原写 = 修复前旧行号）→ `faee172` 修复后 `2773-2777` → `fd671b6`（2026-10-10 20:46，= 此前"深夜现核 `2779-2783`"那一态）→ 现工作树再 +5 ⇒ **`2784-2788`**。⚠️ 该 5 行已由 `faee172` 修复 —— 现读 `:2784-2788` 是**正确方向**；本句"方向全反"指**修复前原状**。引用前请现读。
  ⇒ `mac_tx_64.s_axis_tvalid` / `tx_arb.m_axis_tready` **无驱动（Z）** ⇒ **该配置 TX 全死**（`rtl/tx_arb.v:33` 的 `busy&&sel_fast&&m_axis_tready` = `1&&1&&z` = X ⇒ `mac_tx_64` FIFO 零写）；
  引入点 = **`f08fc6a`**（2026-09-29 P6b 顶层双域搬迁）⇒ 与"自 P6b 起红"逐字吻合、**养了 11 天**（三轮日志 md5 `e042afb3…` 逐字节相同）。
  **证伪三件**（一处 5 行 = 三门全绿）：只改这 5 行 ⇒ `p5_wrapper` **EXIT=0**（3 帧）；同一份副本喂 `p5e_t2_wrapper`（`FAIL errs=117` → EXIT=0）与 `p5e_udp_wrapper`（`FAIL errs=1489` → EXIT=0）。
  **同族普查**：配置 A（`APP_MODE`）30 条纯别名中反向**恰好 5 条 = 就是已知根因**、**无第二个**（与 xsim Z 扫描的 5 条 Z **1:1 互证**）；配置 G（板那一支）**0 条反向**；
  ⭐ **板那一支功能正控实测 EXIT=0**（未修的活 wrapper + DP 宏 ⇒ `P5 WRAPPER OK` / 6 帧）⇒ **板配置清白**。
  ⛔ **修法未实施**（`REPORT.md` §2 只给最小修法，待下次构建搭车）；⛔ **lint 面结构性看不见本族** —— 实跑负对照：现役 lint 的宏**不含 `DP_156MHZ`** ⇒ **恰好编的就是坏分支**却 `LINT-OK`/EXIT=0。
- **⑥ 两轮对抗审查（红队；全程只读）**：**构建 F 审查**抓出 —— **量纲订正 = µs/事件** · `_proj_pcie/p6e_snap_check.sh` 的 `WLABEL` **65 项 vs `SNAP_WORDS=70`**（W65..W69 逐字打 `<无标签>`）·
  活件硬编码 `LF_GEOM_OK NW=63`（`lf_dl.deployed.sh:84`）· **`ΔW68 ≤ ΔW22` 不是结构性牙**（`fend_w6t` 反例：正确式 = `ΔW68 ≤ ΔW22 + Δ(截断帧)`）· `analyze.py` 三角核右腿 = **假牙**（严格式 = `ΔW64 ≥ ΔW66 − ΔH`，`ΔH` 无计数器）。
  **Build G 设计件审查**（被审 = `P7B_BUILDG_RFC_SEQ_DESIGN.md`，**纯纸面：未改 RTL / 未构建 / 未上板**）最狠三条：**oracle 清单不完整**（漏 `tools/gen_stim_tcp_chain.py:355` 的同款绝对比较）·
  **退出码纪律第 3 条自相矛盾且操作数为空集** · **§4.3「G 臂 +3」与 §4.2 的 G 臂定义互斥**（G 臂 = 纯冻结件 ⇒ 没有 `stat_absrej` 可读）⇒ **设计件待修订、未实施**。
- **⑦ 读侧加固（穷举 + 断言 + 负对照）**：穷举 **771 条 / 149 文件**（`FULL_TABLE.tsv`；分类 = **361** geometry-NW / **232** unimpl-addr / **178** identity-BID）、**无一条"未定"**；
  **必须同步 20 文件 / 56 处**；**真缺口 1 处已修** = `_proj_pcie/p6e_snap_check.sh` 的 `WLABEL` **65 → 70**（补 W65..W69；D/E/F 三轮未补）。
  `apply_readside.py` 加**三条结构性断言**（**A 表长 == NW / B 搜索面全扫〔未登记即红〕/ C 默认值 == 权威源现读值**）+ **负对照 4 条全红 RC=1**（删一项 / 改 BID / 造未登记新件 / 旧键 vs 新族）。
  ⚠️ 附带一条**搜索面的坑**：只搜 `EXPECT_BID=\${` **看不见** `BID_EXPECT=` / `BIE=` 整个命名族（三实例全是旧键 0 命中 / 新族 1 命中）。
- **⑧ 三条可复用教训**：① **"标记存在" ≠ "缺陷存在"** —— 判缺陷要回到**行为**（`grep -n MUTFAIL` 看着"地雷还在"，其实那颗地雷 = "**失败后仍落盘**"、已在更早提交 `0713a13` 修掉；`MUTFAIL` 打印是**正常失败路径**的一部分）；
  ② **"既存红"的门后面可能站着真缺陷** —— "历轮只证明与我无关"会把它养 11 天 ⇒ 既存红先**分类**（门的问题 / 本件的问题 / 别的件的问题）再留档；判据族按**改动的形态**建（别名类改动 ⇒ **方向自校验**静态门，判据 = 被例化模块的 **input/output**，**不看名字**）；
  ③ **"直读 ≈ 换算值"先问是不是恒等式** —— 两条路径都合法、公式看似独立时，恒等式可能藏在"一方用了另一方的经验常数"里（本轮比值 ≡ `ΔW66/ΔW65`）⇒ 自查 = **把两式都展开、看能不能互相消掉**。
- **⑨ ⛔ 未结项（不许当已收口）**：`L` 的**绝对准确度**未证（`W68` 多计 + 无独立分母见证）· `W67` 分裂的**满端**（→ 1.0）**未撞到** · **深压档（≤11.7 KB）本轮无读数** ·
  **`p5_wrapper` 修法未实施**（且"未观察到其它受害门" ≠ "不存在其它受害门"；`DP_156MHZ && !PCIE_OBS` 那条隐式网**未复现**）· 构建 F 的 WNS 宿主换位 / FF +293 **无拆刀 A/B、不许归因** ·
  run1 停滞**机理未定位** · 冗余率**只在 BF5 可判** · `W66` 残余（跳槽 1 拍）**未量** · 新逻辑对既有功能网的**负载加深未定向查** · Build G **未实施** ·
  两处**陈旧注释**（`_proj_pcie/p7b_gate4_accept.sh:67-69` 与 `p7b_biz/p7b_snap.sh:55-58` 仍写"现役 = 65 字 / `0x17`"）**未清** —— 该两文件的**默认值**本身已同步（断言 C 全 OK），**注释与默认值自相矛盾**。
  逐条 = `_proj_10g/notes/P7B_OPEN_ITEMS.md`（由本轮并行文档轮刷新；⚠️ **引用前现读**）。

## 2026-09-30 README 重写时移出的历史内容 (原 README.md 全文逐条保留)

> **本节是 README.md 结构性重写时的「移出件」，不是新的施工记录。**
>
> 背景: `README.md` 在 2026-09-30 做了一次**结构性重写**（诊断: 该文件是一层层摞上去的沉积岩 ——
> 顶层事实过期、同一节里夹三层时间戳、同一件事说两遍、一节挂四处相同警示、长句串 4-5 层修饰）。
> 重写**只搬不删** —— 凡从 README 移出的内容，**原文**逐条保留在本节；新 README 的「归档」节**只放索引**。
>
> 阅读约定:
> - 本节内的行号一律指**重写前**的 `README.md`（491 行版本），形式为 `原 README.md:NNN`。
> - 本节内容**多数已过期**（例如状态块写的是 2026-09-21 的 K7 时期），
>   **技术结论一律以本文件其它各节的较新记录为准**；本节的历史价值在于"当时是怎么记的"。
> - ⚠️ **唯一一处事实订正**（重写时改的，已在新 README 生效）: 原第 3 行的
>   `Kintex-7 XC7K325T` 是**事实错误** —— 本工程 2026-09 已换到 **XCKU5P**（`xcku5p-ffvb676-1-e`）。
>   该行原文见下面「原 README.md:1-5」。
> - ⚠️ 原第 3 行同一句里的"10G 仅提时钟到 156.25MHz, 流水线不改"是**不完整的**，
>   已在重写中改为文件自己后来给出的口径（原 README.md:428-430）:
>   「流水线不改」对**中间各级**成立、**对 MAC 边界不成立**（`mac_rx_64`/`mac_tx_64` 是字节串行模块 ⇒ 10G 必须整体替换）。
> - 原文件里**四处重复出现**的"空门"警示（原 README.md:58-63 / 298-312 / 315 / 356-357）在下面**按原样保留**；
>   新 README 只保留**一处**集中警示（在「怎么跑」节）。

---

### 原 README.md:1-5 (标题与定位)

#### udp_hls_10g — 10G-ready 纯硬件 TCP/IP 数据面 (1G 先行)

Kintex-7 XC7K325T 纯硬件 TCP/IP 数据面: 64bit 字流 @125MHz, 当前 1G RGMII 前端
(10G 仅提时钟到 156.25MHz, 流水线不改)。顶层 = `board/wrapper_p4.v`。
施工日志/踩坑/决策详见 `PORT_NOTES.md`; 工程规范与铁律见 `CLAUDE.md`。

##### 状态 (2026-09-21)

**P0-P5e 全部完成并提交; P5a/P5b/P5c/P5d/P5e 均通过板级验证。**
~~**P6 (10G 提速) 经用户裁决停止, 未做**~~ —— ⚠️ **已于 2026-09-29 重启并推进**:
P6a(数据面移植到 KU5P) ✅ / P6e(我们自己的 PCIe 观测通道) ✅ / **P6b(数据面 125→156.25MHz) ✅ 板级正式验收 35/35**。
**P7a(10G PCS/PMA，含 64b/66b gearbox) ✅ 板级验收 PASS** —— **10G PHY 已实测达标，BER 上界 4.997e-13**
（双向各 600 s / 6.003×10¹² bit 零错；gearbox 三条腿齐）: 见 **`P7A_RESULT.md`**。
**P7b(10G 数据面上板第一轮：官方 XGMII 核 + 自写 64 位 MAC) —— 🚧 进行中**:
**闸 0(选型) ✅ / 闸 1(2 通道官方 PCS 板内 J7↔J8 自环) ✅** —— 6.6 s / **30,056,095 帧**零错、
载荷字/帧 29.000000、XGMII 字/帧 34.000000、**9,999.94 Mbps**、官方 FSM `completion_status = 1`;
负对照(拉 `SFP1_TX_DIS`(C11)) 按期望翻转(掉块锁 + 对端 `RX_LOS`(C9) 亮 + `/E/` 计数 0→11,808)。
新 MAC 单元门 **252 条 / 0 fail**(变异 12 条: 10 非等价全抓住)、与 PCS 合并 **WNS +0.401 / 三类失败端点全 0**。
⚠️ **未完成**: **闸 2(真网卡 802.3 裁决) 进行中**、**闸 3(全链门) / 闸 4(板级验收) 未起**;
**新 MAC 未接入 `board/wrapper_p4.v`**、**`rx_classify` v2 未落进 `rtl/`**。
规格 **`P7B_SPEC.md`**、闸 1 读数原件 **`_proj_10g/notes/P7B_GATE1.md`**。
本节以下内容仍是 **2026-09-21 当时的记录**; 现状看上面那个 ⭐ 块。
调研结论仍存档在"遗留"(定性与 6 块工作、K1-K6 前置实验、三个决策点、两个阻断级风险、工期更正)。

> ### ⭐ P6b 已收口 (2026-09-29) —— 数据面已搬 156.25MHz, **在 XCKU5P 上通过板级正式验收**
>
> 下面的 "状态 (2026-09-21)" 与 "遗留 → P6" 两节是**当时的记录**（目标板还是 K7），
> **现状**以这三份为准：
>
> | 想知道什么 | 看哪份 |
> |---|---|
> | **一页式总览**（目标 / 改了什么 / 关键数字 / 证据地图 / 已知限制）| **`P6B_SUMMARY.md`** ← **先读这个** |
> | **板级验收的原始记录**（35 条判据、位流 sha256、复现步骤、未覆盖项）| **`P6B_ACCEPT.md`** |
> | 板级观测通道怎么用（**36 字**寄存器表 + 判据变更）| **`P6E_OBS.md`** |
> | 施工规格（**含 §0.4 勘误**：索引表错误 / as-built 偏离）| `P6B_SPEC.md` |
> | 跨域审计（F-1/F-2/F-3）、对抗审查（F1–F13）、集成与"空门"核实 | `P6B_CDC_AUDIT.md` / `P6B_REVIEW.md` / `P6B_INTEGRATION_REVIEW.md` |
> | **P7a 10G PHY（PCS/PMA + gearbox）板级验收的原始记录** | **`P7A_RESULT.md`** + `P7A_SPEC.md` |
> | **P7b 施工规格**（路线与 license 分叉 / 接口冻结 / 闸序 / 66 条正判据 + 9 条负对照）| **`P7B_SPEC.md`** |
> | **P7b 闸 1 板级读数原始件**（2 通道官方 PCS 板内 J7↔J8 自环：拓扑 / IP 逐项回读 / 长窗零错 / 三条负对照 / 1a 补测）| **`_proj_10g/notes/P7B_GATE1.md`** |
> | **P7b 其余笔记**（闸 0 官方核与 license · 新 MAC 设计/审查/门修/时序 · v2 · 哑门修复与铺开 · 闸 2 对端现状）| `_proj_10g/notes/P7B_{XXV_OFFICIAL,MAC_DESIGN,MAC_REVIEW,MAC_GATEFIX,MAC_TIMING,RXCLASSIFY_AUDIT,RXCLASSIFY_DESIGN,IMPLICIT_GATE_FIX,IMPLICIT_GATE_ROLLOUT,U7_AND_PEER}.md` |
> | ⚠️ **P7b 的"未完成"清单**（闸 2/3/4 未起 · MAC 未接入 wrapper · v2 未落 `rtl/`）| `P7B_SPEC.md` §5 · `PORT_NOTES.md` 的 "2026-09-29 P7b" 节 |
> | 里程碑日志与教训 | `PORT_NOTES.md` 的 "2026-09-29 P6b 收口" / "2026-09-29 P7a" / "2026-09-29 P7b" 三节 |
>
> **一句话读数**：1G 图案通路 **956.0 Mbps**（线速 957.1 的 99.9%）· 数据面 **156.2585 MHz**
> 与前端 **125.0061 MHz** 双域并存 · 同批修掉两个**早于 P6b 就存在**的数据通路缺陷（F4 / F-2）。
>
> **P6 全部三段**：**P6a**（数据面移植到 KU5P：真 ping 5/5 + 图案 931 Mbps + 闸 G 时序基线）
> · **P6e**（我们自己的 PCIe/XDMA 观测通道：user BAR 寄存器窗口，**快照 36 字**，`BUILD_ID=6`）
> · **P6b**（数据面搬到独立 **156.25MHz** 域：核心板 Y1 100MHz 经 MMCM ×1.5625；
> 前端 RGMII 留 125MHz；两者之间只有**两个**手写异步 FIFO 跨域）。
> ⭐ **P6b 的可测量收益**：吞吐 **931 → 956 Mbps** —— 提频把 DP 自身的处理节拍瓶颈消掉了，
> 不再只是"为 10G 做准备"。
> ⭐ **长时"慢路径失聪"探针（348 轮 / 96.3 分钟，含历史上高发的"配置后 20 秒"窗口）未复现**；
> 结论措辞只能是"**F4/F-2 修复之后该现象没有出现**"（样本量 1，不能写"证明已修好"）。
> ⚠️ **诊断陷阱**：板子周期性向 `192.168.100.1:8080` 发 UDP HELLO ⇒ 主机回 ICMP port unreachable
> ⇒ **该帧进慢路径而 HLS 不应答** ⇒ **健康的板子也会天然产生 `ΔW6>0 而 ΔW7=0`** ⇒
> 这个签名单独不足以判失聪，必须附加"ping 由通变不通"。
> ⚠️ **本文件的"验证"一节里的 `D:\repo\ECO\udp_hls_10g\...` 命令是"空门"形态**
> （跑起来编的是**另一个 checkout**）—— 见下面该节顶部的警示。
> ⚠️ **元问题（已修 340 文件 + 三层守卫，但读者要知道）**：本仓 2026-09-28 从
> `D:\repo\ECO\udp_hls_10g` 整体拷贝，**那份拷贝源至今仍活着** ⇒ 全仓 **243 个门是"真空门"**
> （照抄老命令 = 编另一个 checkout、日志写进另一个仓、然后 exit 0）。
> **跑门一律走 `sim/p4gates/run_matrix_p4dfix.bat`（自定位 + 守卫 + 修订指纹）**。

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
| P6 (10G 提速) | ~~未做 (用户 2026-09-20 裁决停止)~~ ⇒ **2026-09-29 重启** | —— |
| P6a | **数据面移植到 KU5P** (零 IDELAY RGMII 前端 + 闸 G 时序基线 + 真 ping) | ✅ **板级 PASS** (931 Mbps) |
| P6e | **我们自己的 PCIe/XDMA 观测通道** (user BAR 寄存器窗口, 无 UART 板上的唯一观测手段) | ✅ **板级 PASS** |
| P6b | **数据面 125 → 156.25MHz** (前端留 125MHz + 手写异步 FIFO 跨域) | ✅ **板级正式验收 35/35** (956.0 Mbps) |
| **P7a** | **10G PCS/PMA（含 64b/66b gearbox）在板上真的在跑** (X0Y4↔X0Y5 经 AOC 外部环回, 自写 PRBS31 计数器判 BER) | ✅ **板级 PASS** — 双向各 600 s / 6.003×10¹² bit 零错 ⇒ **BER 上界 4.997e-13**; 速率 1.000025×10¹⁰ bit/s 钉死 gearbox 比率 |
| **P7b-闸0** | **选型定案**: 官方 `xxv_ethernet`(`CORE = Ethernet PCS/PMA 64-bit`, **XGMII 出**) + **自写 64 位 XGMII MAC** | ✅ **闸 0 完成** — PCS-only **能出位流** / **含 MAC 的变体被 license 拒**; 官方核网表里确有加扰·解码·对齐 ⇒ **GT 不加扰** |
| **P7b-闸1** | **2 通道官方 PCS 板内自环** (J7↔J8, 用官方 example 的图案发生器/监视器, **未改一行**) | ✅ **板级 PASS** — 6.6 s / 30,056,095 帧零错 · 9,999.94 Mbps · 官方 FSM `completion_status = 1`; 三条负对照按期望翻转 |
| **P7b-②** | **新 64 位 XGMII MAC** (`mac_rx_10g` / `mac_tx_10g` / `crc32_64`) | ✅ **单元门 252/0 + 与 PCS 合并 WNS +0.401 / 三类失败端点全 0**; ⚠️ **未接入 `board/wrapper_p4.v`** |
| **P7b-③** | **`rx_classify` 收发解耦 v2** (最小帧帧周期 14→8 拍; 10G 最小帧 57.1%→100%) | 🚧 **设计完成, 未落进 `rtl/`** (落地要配 P4 矩阵 + P6b 验收门回归) |
| **P7b-门修复** | 隐式网门 (`implicitly declared` 在 2025.2 是**哑门**) + xelab 面判据铺开 | ✅ 87 文件 / 261 处、**假阳性 0**; P4 矩阵 **16/16 EXIT=0** + 冻结校验 `FROZEN` |
| **P7b-闸2/3/4** | 真网卡 802.3 裁决 / 全链门 / 板级验收 | 🚧 **闸 2 进行中** (决定性负对照未做); **闸 3 · 闸 4 未起** |

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

##### 已完成功能

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
- HLS cfg 通道 (wscale/窗口) → CAM/TCB; 看门狗 (饥饿超时 64 拍复位脉冲; **P6b 构建 (DP_156MHZ) 下是 80 拍** —— 同一墙钟 512ns, 见 P6B_SPEC §5.1) 防 HLS 死锁

##### 协议功能全景 (P4c 收官)

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
  板侧校验器零失配。⚠️ **平台限定**（2026-09-30 补，`P7B_W13_AUDIT.md` §②-V25）：这里"板侧校验器零失配"
  是 **P5a 轮经 UART 状态行**读到的，**只对"有 UART 状态行的板"成立**；**KU5P 上该字结构性不可读**
  （`udpapp_*` 只喂 `app_status_uart` 的状态行，`uart_txd` 无消费者）。KU5P 上只能用 PCIe 快照窗口
  的 `W13`，且**须同窗 `ΔW10 > 0`** 才有判别力。
  详见 `PORT_NOTES.md` 的 P5a 段与 `rtl/app_ctrl.v`/`rtl/app_pattern.v` 头注释。
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
  (⚠️ 2026-09-29: 该 UART 诊断行**在 KU5P 上不可观测** —— 本板无 UART; 且它在 DP 域有
   **48 位未同步穿越**（`u_dbg_line`）。历史与理由见 `PORT_NOTES.md` P6b 收口 §⑧)
  + FIFO tlast 位图 (TL), boot 自检后每 5s 一行 (见 `board/uart_dbg.v` 头注释)
- LED: boot 自检 3 闪 + 门控/锁存/满标志实时探针

##### 综合结果 (Vivado 2025.2, routed — P5e)

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

##### 板级结果

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

##### 验证

> ⚠️ **2026-09-29 警示（先读这段，再照下面的命令抄）**：下面小段里的
> `D:\repo\ECO\udp_hls_10g\...` 是**硬编码的另一个 checkout**。本仓是 2026-09-28 从那里
> 整体拷贝来的 ⇒ **照抄这些命令 = "空门"**：编译的是 ECO 的源码、日志写进 ECO 的仓，**然后 exit 0**。
> **现役跑法**（自定位，路径全部由脚本自身位置推导 + 三层守卫）：
> ```bash
> cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\sim\p4gates\run_matrix_p4dfix.bat'        # 16 门全跑
> cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\sim\p4gates\run_matrix_p4dfix.bat' -only stallgate
> bash /d/repo/XCKU5PMini/udp_hls_10g/sim/p4sim/run_matrix_p4dfix.sh               # 入口 sh 版
> ```
> ⚠️ **补一行（2026-09-29 实测）**：从 git bash 调用时开关要用**短横线** `-only`（不是 `/only`）——
> MSYS 会把 `/only` 改写成 `"C:/Program Files/Git/only"` ⇒ 开关**静默丢弃** ⇒ **不报错地跑满 16 门**
> （上面那行已按实测改正；纯 cmd 窗口里 `/only` 仍可用）。门 bat 均已自定位，故**相对仓根**的
> `cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'` 亦可（等价且更短）。
> 守卫与负对照、以及"跑门 ≠ 判门"（16 门里 `unit_retx`/`unit_fifo` **无条件 exit 0**）
> 详见 `PORT_NOTES.md` 的 P6b 收口 §⑤/§⑦。

**TB 门矩阵** (P6 类改动的固定回归门, ~25 min, 见 `sim/p4sim/`)：
**⚠️ 下面这些命令里的 `D:\repo\ECO\udp_hls_10g\...` 是历史形态（= 空门），不要照抄** —— 等价的自定位写法见本节的警示块。
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
> ⚠️ 下面这几条是**空门形态**（同本节顶部警示；这一段此前没有就近警示）：`board\` 的 bat **都已自定位**，
> 在**本仓根**用相对路径即可 ⇒ `cmd //c 'board\run_build_p4.bat'` 等（判据/产物不变）。
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
  内置负对照) / `run_tb_p5e_t2_wrapper.bat` (**T2 真 wrapper 全链**, 含隐式网检查: `Synth 8-11241` / `VRFC 10-3091] actual bit length 1 differs from formal bit length` / `VRFC 10-2989` (⚠️ 裸 `10-3091` 不行 —— 见 CLAUDE.md 坑 24))。
- `run_tb_app_udp.bat <case>` (`sim/p5e_udp/`, **T4 UDP 演示 app**: `pos` 正例 EXIT=0;
  负对照 `splitoff`/`portout`/`badcrc`/`nopeer` 各 EXIT=0 且正向判据不成立;
  `neglearn` **期望 exit 1** = 判别力实证) / `run_tb_p5e_udp_wrapper.bat`
  (**T5 真 wrapper 全链**: 真 GMII 注入 + 内部 GMII 解码 + `+NOUDP` 零帧对照 + DRC)。
- 一键: `bash sim/p5e_udp/run_regress.sh` — **49 门**, 唯一非零 = `t4_neglearn` (期望值)。

##### 遗留

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
###### P6 (10G 提速) — ⚠️ **本节是 2026-09-20/21 的调研交接记录（当时"未做、一行 RTL 都没写"）**

> ⚠️ **该状态已于 2026-09-29 失效** —— P6a / P6e / P6b 都已落地并板级验收（见开头 ⭐ 块与里程碑表）。
> **下面这段历史价值在于它的一句定性判断，而 P6b 恰好印证了它**：
> **"10G 的技术前提不是'提时钟'而是'换前端 + 重收敛'"** —— 连 P6b 这种"只提时钟"的步子，
> 前端也只能**留在 125MHz**（`mac_rx_64`/`mac_tx_64` 是字节串行 GMII 模块，必然绑在 RGMII 时钟上），
> 跨域靠异步 FIFO 解决。**10G 时 `mac_*` 这两级仍必须整体替换，没有捷径。**
>
> 存档位置 = `PORT_NOTES.md` 末节 "P6 交接记录"; 将来重启 10G 从那里读, **不要重新调研**。
> 现役总览 = `P6B_SUMMARY.md`。

- **定性 (最重要的一条)**: P6 的技术前提**不是"提时钟"而是"换前端 + 重收敛"** ——
  `mac_rx_64`/`mac_tx_64` 是**字节串行 (1B/拍) 的 GMII 模块** ⇒ 10G 下**必须整体替换**
  (否则 TX 天花板 **1.25 Gbps**)。"流水线不改"对**中间各级**成立, **对 MAC 边界不成立**。
- **要做的 6 块**: A 时钟与前端 (换晶振 + PCS/PMA + shim) / B **MAC 语义 (FCS 改 8B/拍)** /
  C 吞吐复核 (`rx_classify`: 现每帧停 3 拍 (非 TCP) / 6 拍 (TCP) ⇒ 上限 `N/(N+停顿)`、
  **最小帧 57.1%**; ⚠️ **"skid 改真 FIFO"这个提法是错的** —— **2026-09-29 复核更正**：该 TODO
  未落地（as-built 仍是 6 字寄存器 skid，`rtl/rx_classify.v:52,60-65`；`git log -1 -- rtl/rx_classify.v`
  = `122b0c0`，P6a/P6b/F4/P7a 全未碰），但**它不是"静默丢字"那类**（DRAIN 是寄存器 hold + `tready=0`
  顶背压，`:78-85,102-103`）—— **真实的病是硬吞吐上限**，**"加深上游 FIFO 修不了"**，只有
  "收字与等 w5 决策解耦"能修；**10G 下必然触发**（156.25MHz 每拍有字时 TCP 每帧净赤字 ≈4.5 字，
  现有 264 字弹性 ≈3.6 µs 填满 ⇒ MAC 层整帧丢，有计数 `W34`）。原件
  `_proj_10g/notes/P7B_RXCLASSIFY_AUDIT.md`;
  VLAN 重构) / D 窗口与缓冲 (**DDR3 大窗**: BRAM 只有 2MB, retx 已占 1MB) /
  E HLS 慢路径 (`u_hls` = **38.7% LUT** ⇒ **单域/双域抉择**) / F 工具链 (校验器 8 路并行 + 10G 对端)。
- **要准备**: 换晶振 (`SiT9120AI-2B3-33E156.25`) + **10G 对端** (现网卡 Killer E5000B 是
  **5G RJ45、无 SFP+**) + SFP+/DAC。⚠️ **一个必须先定案的物理前提**: `PORT_NOTES` 记参考钟
  **X5→Quad115(H5/H6)**, 但 **DEMO `k724` XDC 实测是 D6/quad116/X0Y0/G4** —— 冲突;
  **若晶振真在 quad 115, 换晶振无效**。**买硬件之前先定案**。
- **六个前置实验 K1-K6** (都不需要新硬件, 可现在做): K1 156.25MHz 时序尖峰 / K2 字节序实测 /
  K3 HLS 收敛探针 / K4 **license 核查** / K5 参考钟定案 / K6 BRAM 映射尖峰。
  ⚠️ **2026-09-29 复核更正: K4 已答、且不阻断** —— 本机 `Xilinx.lic` 含
  `INCREMENT xxv_eth_mac_pcs … permanent uncounted`，`_lic/prep_stdout.txt` 实测 `xxv_ethernet 5.0`
  三种 CORE 配置 `IS_LOCKED` **全 0**、`generate_target all` 出**完整 RTL** ⇒ **"PG157 要买 license"这个
  前提不成立**；缺 license 的失败形态是**综合期硬失败**（`Fatal Error. License Check failed for secure IP
  for feature 'xxv_eth_mac_pcs@2025.05'`），**不是**位流超时。
- **三个决策点**: ① 单域 vs 双域 ② **免费 10GBASE-R PCS/PMA (PG068) + 自写 shim** vs
  PG157 (~~**收费核, eval 版硬件 8 小时停机**~~ ⇒ **2026-09-29 复核更正: 本前提被证伪** —— 本机 license
  **永久覆盖** `xxv_eth_mac_pcs`，**无 eval 停机计时**；抉择输入改成"判据直接性"而非 license) ③ 10G 对端方案 (PCIe NIC+DPDK /
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
