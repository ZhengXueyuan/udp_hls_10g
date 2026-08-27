# udp_hls_10g — 10G-ready 纯硬件 TCP/IP 数据面 (1G 先行施工)

终局目标: 10G 线速纯硬件 TCP/IP (低延时行情 UDP 组播 + 交易 TCP 少量连接), 对上提供 TCP/UDP 调用接口。
施工策略 (2026-08-23 用户拍板): **1G 先行、10G-ready** — 数据面统一 64bit 宽流水 @125MHz,
10G 时仅提时钟到 156.25MHz, 流水线不改。设计审查与总计划: `../udp_hls_eco/design_review/` (01-04)。

## 10G-ready 设计决策 (不可违背)

1. **数据面所有模块 64bit 字流 @125MHz** (10G 时 156.25MHz), 每级 II=1, 帧内零整包暂存。
2. **MAC 边界 = 左对齐字流** (见下接口规范): 1G 前端 = GMII 字节流→字流 (`mac_rx_64`);
   10G 前端 = PG157 AXIS 输出加一层 shim 对齐到同一约定。
3. **fast/slow path 划分**: 数据面全 RTL; 慢路径 (ARP/ICMP/IGMP/DHCP/TCP 握手/重传/RTO)
   移植 `../udp_hls_eco` 现有 HLS 层 (ap_ctrl_hs @125MHz), 经 AXIS CDC FIFO + BRAM mailbox 解耦;
   **TCB 唯一状态源归属 fast 数据面**。
4. **背压合同**: 级间弹性 FIFO; 必须丢帧时在帧边界丢整帧 (消费者按 TLAST 完整性丢弃半帧)。

## MAC 字流接口规范

- `tdata[63:56]` = 帧首字节 (dst_mac[0]), 字内字节从高到低连续
- SOP 字总是满对齐 (`tkeep[7]=1`); TLAST 字 `tkeep` 高位有效
- FCS 在 MAC 层校验并剥离; `tcrs` (TLAST 有效) = FCS 正确; `terr` = 帧内 rx_er
- CRC-32: 反射多项式 0xEDB88320 / 初值 0xFFFFFFFF / 残留 == **0xDEBB20E3** 为正确
  (0xC704DD7B 是大端/非反射魔数, 勿用); 线上 FCS 字节序 **LSB-first** (zlib.crc32 值小端)

## 目录

| 路径 | 内容 |
|------|------|
| `rtl/` | RTL: mac_rx_64 / crc32_8b / fifo_sync (后续: mac_tx_64, parser, classifier, TCB...) |
| `tb/` | xsim testbench |
| `sim/` | xsim 工作目录 (run_tb.bat / run.tcl / stim / resp 生成物) |
| `tools/` | Python (anaconda: `/c/Users/zhxue/anaconda3/python.exe`) |
| `vivado_prj/` | (待建) 板上工程 |

## 验证

```bash
cd /d/repo/ECO/udp_hls_10g
/c/Users/zhxue/anaconda3/python.exe tools/run_mac_rx_tb.py
# 三模式: nostall (逐词全等) / stall (周期抖动, 逐词全等) / hard (硬停窗口, 结构一致)
```

## 教训继承 (详见 ../udp_hls_eco/CLAUDE.md 与全局 CLAUDE.md)

- FCS 字节序 LSB-first; csim≠RTL — 本工程数据面纯 RTL, 以 **xsim + 板级 ILA** 为准
- bat 从 git bash 调: `cmd //c 'D:\path\x.bat'`; xvlog/xelab 库必须同用 `xil_defaultlib`
  (xelab 用全限定名 `xil_defaultlib.tb_x`); bat 行尾必须 CRLF
- 窄类型索引按最大 BASE+长度核算; 丢帧丢整帧; 关键 recipe 亲自逐行读源码

## 本工程新增坑 (P0 实战, 详见 PORT_NOTES.md)

1. **CRC 使能/初值必须与数据同拍 (组合逻辑)**: 寄存器化 en 会让 CRC 与字节流错位一拍
   (漏首字节 + 帧尾多算 IFG 字节)。排查法: 用 crc 终值反解实际字节流。
2. **FCS 残留魔数 = 0xDEBB20E3** (zlib 值小端线上字节序): 0xC704DD7B 是大端魔数, 勿用。
3. **TB 激励必须时钟化非阻塞驱动** (`always @(posedge clk) rx <= stim[i]`): 阻塞赋值+
   @(posedge) 循环与 DUT 竞争, 症状诡异且随背压模式漂移。
4. **AXIS 输出 = 组合 valid + 组合 rd + FWFT FIFO**: 寄存器化 rd 会让数据挂 2 拍被标准
   消费者双采 (每词重复)。
5. **移位量表达式禁用宽不匹配字面量** (如 `3'd8` 截断为 0): 左对齐用显式 case 拼接。
6. **脉冲型寄存器 (push_*) 每拍默认清零**, 否则跨帧残留污染。
