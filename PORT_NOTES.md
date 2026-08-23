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
