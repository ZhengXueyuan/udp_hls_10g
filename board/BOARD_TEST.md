# udp_hls_10g 板上环回 bring-up 测试

目标: 在 Kintex-7 ECO 板 (XC7K325T-2FFG676C) 上验证 10G-ready 数据面骨架的
**1G RGMII 板上环回**: PC 发帧 → FPGA MAC 层收 → 环回 → 原样回发 → PC 抓包对照。

本阶段为最小骨架: **无 UART、无 ARP/ICMP 应答** — 板子不回应任何协议,
"回显帧被 PC 抓到且与原帧逐字节一致"即 PASS 判据。

---

## 0. 工程形态 (前端 recipe 来源, 已逐行核对)

| 模块 | 形态 | 来源 / 处理 |
|------|------|-------------|
| `wrapper_1g.v` (本顶层) | RTL | 前端逐字复用 `udp_hls_eco/wrapper_1g.v`: MMCME2_BASE(200M)+BUFG+IDELAYCTRL = 该文件 L67-L110; `util_gmii_to_rgmii u_rgmii` 实例 = L219-L239; 异步低有效复位结构 = 全文。环回 + LED 为本次新增。 |
| `util_gmii_to_rgmii.v` | **纯 RTL 模块 (非 Xilinx IP/xci)** | k720 demo 原文件逐字节复制 (与 `udp_hls_eco/util_gmii_to_rgmii.v` 相同)。内部只有原语: BUFG `bufmr_rgmii_rxc` (倒相 RXC → `gmii_rx_clk`)、IDELAYE2(10)、IDDR/ODDR。**时钟端口**: `gmii_rx_clk` 输出 = 全设计时钟 (125MHz 恢复钟); `gmii_tx_clk` 内部直连 `gmii_rx_clk` (该文件 L137-L138) → **RX/TX 同域**。`reset` 接死 1'b0, `speed_selection=2'b10`(千兆), `duplex_mode=1`。 |
| `mac_rx_64.v` / `mac_tx_64.v` / `crc32_8b.v` / `fifo_sync.v` | RTL | `../rtl/` (已 xsim 验证), 不改动。 |
| `eco_rgmii_phy1.xdc` | 约束 | 逐字复用 `udp_hls_eco/xdc/eco_rgmii_phy1.xdc`, 仅删 UART 约束 (本 wrapper 无 UART 端口)。 |
| Xilinx IP (xci) | **无** | 全工程没有任何 xci/dcp IP。已核对 `udp_hls_eco/vivado_prj/...srcs/sources_1/` 只有 imports/*.v — 参考工程同样是 import_files 直加 RTL。 |

**build.tcl 因此的处理方式**: 无 IP 生成/升级步骤 — `import_files` 直接加入
`rtl/*.v` + `board/wrapper_1g.v` + `board/util_gmii_to_rgmii.v`, 约束用
`add_files -fileset constrs_1`。创建方式 `create_project -force` (重建最稳),
部件 `xc7k325tffg676-2`, 与 `udp_hls_eco/run_vivado_phy1g2.tcl` 同模式。

**xdc 与 RTL 的唯一耦合点**: generated clock 引用
`u_rgmii/bufmr_rgmii_rxc/O` — 实例名 `u_rgmii` 与 BUFG 名 `bufmr_rgmii_rxc`
必须保持 (wrapper_1g.v 已按此命名)。

时钟/复位接法要点:
- 全设计同域 `gmii_clk` (util 的 `gmii_rx_clk` 输出, 恢复钟; TX 侧 ODDR 也由
  它驱动, util 内部已处理)。两 MAC 与环回逻辑全部挂在 `gmii_clk` 上。
- `rst_n` = 板载按键 KEY1 (低有效), **照抄 wrapper_1g.v 的直连异步复位**:
  两 MAC 均为 `always @(posedge clk or negedge rst_n)`, 无额外同步释放。

---

## 1. 构建与烧录

```bash
# 构建 (综合+实现+位流, ~10-20 分钟)
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_build.bat'
# 产物: D:\repo\ECO\udp_hls_10g\vivado_prj\udp_loop_phy1.runs\impl_1\wrapper_1g.bit

# 烧录 (JTAG 1MHz; 板子需已上电, JTAG 已连)
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_program.bat'
```

- 构建成功判据: 日志 `===== BITSTREAM DONE =====`。
- 烧录成功判据: 日志 `PROGRAM_OK` (程序内部 `program_hw_devices` 成功 =
  "End of startup status: HIGH", 即 DONE=HIGH)。
- 失败排查: `NO_TARGETS_FOUND` → 检查 JTAG 线/板子供电;
  `HW_CONNECT_FAILED` → 参考 `udp_hls_eco` 的 hw_server 后台方案 (TCP:3121)。

## 2. 上电现象 (LED 对照)

板上 8 个 LED 中仅 4 个有验证过的引脚映射, 本设计占用:

| LED | 含义 | 正常现象 |
|-----|------|----------|
| led_d0 | RX 帧活动闪烁 | 每收到一帧点亮 ~0.5s; 连续 ping 时持续闪 |
| led_d1 | `stat_frames[0]` (RX 完整帧计数 LSB) | 每帧翻转 (灭/亮交替) |
| led_d2 | `stat_crc_err[0]` (FCS 错误计数 LSB) | **恒灭** (FCS 全对) |
| led_d3 | `stat_abort[0]` (TX 中止计数 LSB) | **恒灭** (源不断供) |

注意: 首次烧录完成瞬间可能看到 LED 乱闪 (复位释放瞬态), 属正常; 无流量时
led_d0 灭、led_d1/d2/d3 保持静止。

## 3. PC 发帧

> **历史教训: ping/抓包必须走有线网卡 (Killer E5000B)。WLAN 会假阳性**
> (ping 通是走 WiFi, 与板子无关)。先用 `pktmon comp list` 或
> `ipconfig` 确认有线网卡 IP (如 192.168.100.1), 并把有线网卡设为
> 192.168.100.x/24 网段。

任选其一 (都是"到板子所在网段"的流量, 板子会原样回显):

1. **ARP 广播 (默认, 最省事)**: `ping 192.168.100.2`
   - 板子不回应 ARP → Windows 会反复发 ARP who-has 192.168.100.2
     (广播帧)。ping 显示"超时"**属正常** — 本阶段板子不应答任何协议。
   - ARP 广播的回显仍是广播 → **PC 网卡直接可见, 无需混杂模式**。
2. **单播 ICMP (可选, 验证混杂模式必要性)**:
   ```
   arp -s 192.168.100.2 00-0a-35-01-fe-c0   # 静态 ARP, MAC 随便填 (板子不挑)
   ping 192.168.100.2 -n 5
   arp -d 192.168.100.2                      # 测完删除
   ```
   - 单播帧 (目的 MAC = 静态 ARP 里的 MAC) 的回显帧目的 MAC 仍是该值
     (≠ PC MAC) → **必须混杂模式抓包才可见**。
3. 任意 UDP/其他到 192.168.100.x 的流量亦可。

## 4. pktmon 抓包 (管理员 PowerShell)

```powershell
# 1) 找有线网卡组件号 (历史 = 117, Killer E5000B; 以 comp list 为准)
pktmon comp list

# 2) 开始抓包 (仅有线网卡组件; 抓包点在 miniport 层, 非本机目的帧也能看到)
pktmon start --capture --comp 117

# 3) 在另一个窗口发帧 (第 3 节), 连续 ping / 多发几次 ARP
ping 192.168.100.2 -n 5

# 4) 停止并转文本。历史教训: etl2txt 必须加 -v 才能拿到 MAC 地址
pktmon stop
pktmon etl2txt PktMon.etl -v -o cap.txt
```

## 5. 预期现象 (PASS 判据)

1. **每帧出现两份**: 原帧 (源 MAC = PC MAC) + 回显帧 (内容与原帧相同,
   方向反向)。ARP 广播的回显 PC 直接可见; 单播回显需混杂模式 (第 4 节)。
2. **帧内容逐字节一致**: 原帧与回显帧的 64 字节 (目的 MAC .. FCS) 应完全
   相同。注意前导不参与比对 (板子重新生成), FCS 由 `mac_tx_64` 重新计算 —
   内容相同则 FCS 也应相同; **若 FCS 不同 = 板 FCS 字节序问题** (历史铁律:
   本板 PHY/PC 链只接受 LSB-first 线上字节序, 参照 demo 帧 FCS = CA A3 F9 63)。
3. **LED 联动**: 每抓到一份回显, 板上 led_d0 闪一下、led_d1 翻转一次;
   led_d2/led_d3 恒灭。
4. **计数器自洽**: 回显帧数 == led_d1 翻转次数 (肉眼即可, 不必精确)。

## 6. 失败排查表

| 现象 | 排查方向 |
|------|----------|
| PC 抓不到任何帧 (含原帧) | 不是板子问题 — 先查有线网卡/网线/IP 网段 (WLAN 假阳性)。 |
| 只看到原帧, 没有回显 | 板上 RX 没收到: led_d1 不翻转 → 查 RX 链路 (IDELAY 相位/引脚组, 参考 `udp_hls_eco` 相位扫描史); 若 led_d1 翻转但无回显 → TX 链路 (对照实验见下)。 |
| 回显帧内容错位 / FCS 不同 | 板 FCS 或字节对齐问题 — 对照 `udp_hls_eco` 的 FCS 字节序铁律 (LSB-first); 帧内容比对必须含全部 64 字节。 |
| led_d2 亮 | RX FCS 错误计数 — PC 发的帧 FCS 应该全对; 若原帧 pktmon 都看不到 + led_d2 亮 = RX 采样错位 (IDELAY 相位)。 |
| led_d3 亮 | TX 源断供中止 — 环回常态不该发生; 若发生查背压环。 |
| ping 一直不通 | **正常** — 本阶段无 ARP/ICMP 应答, PASS 判据是抓包看到回显, 不是 ping 通。 |
| 背靠背高压流量下丢帧 | **预期内**: mac_rx_64 内部 FIFO 8 深 + mac_tx_64 每帧 12B IFG, 满则整帧原子丢弃 (`stat_drop` 累计, 属设计合同)。单发/低频流量不受影响。 |

**对照实验 (区分设计问题 vs 物理链路问题, 最快手段)**: 烧 `udp_hls_eco` 的
demo 位流 (同板同线) — 它每秒发 1 帧 ARP 广播 (demo 克隆生成器)。若 demo
位流 PC 可见而本工程零帧 → 设计问题; 若 demo 也零帧 → 物理链路 (网线/网卡/
PHY 配置)。demo 位流路径:
`D:\repo\ECO\udp_hls_eco\vivado_prj\udp_dual_phy1g2.runs\impl_1\wrapper_1g.bit`
(注意该 bitstream 含 demo 生成器, 烧录后 PC 每秒应收到 ARP 广播)。

## 7. 已知限制 (本阶段, 非 bug)

- 无 ARP/ICMP/UDP/TCP 任何应答 — 纯数据面骨架, 协议层后续阶段接入。
- 回显帧目的 MAC = 原帧目的 MAC (环回不改内容): 单播回显需混杂模式观察。
- 高压背靠背流量会按帧原子丢弃 (设计合同, 消费者按 TLAST 完整性处理)。
- 10G 升级 (P6) 时本 wrapper 的 1G 前端替换为 PG157 BASE-R, 环回与
  LED/stat 观测结构不变。
