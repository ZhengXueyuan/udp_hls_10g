# `_proj_pcie/` — P6e 最小版：**我们自己的** PCIe/XDMA 观测通道

> 前置：`../_pcie/`（厂商出厂位流上的 PCIe 通道验证，已通过）。本目录是**下一步**：
> 把 XDMA 放进**我们自己的设计**里，从而拿到 `user BAR`（寄存器窗口）——厂商那份设计
> `axilite_master_en=false` ⇒ 只有 config BAR ⇒ 没法读我们自己的状态（见 `../_pcie/README.md`）。

## 一、本设计是什么

`pcie_min_top.v` = **只有观测通道、没有数据面**的最小设计：

| 组成 | 说明 |
|---|---|
| `IBUFDS_GTE4` | 金手指 100MHz 差分参考钟（AB7/AB6 = `MGTREFCLK0_224`） |
| `xdma_0`（IP `xdma:4.2`） | 配置**逐条复制厂商那份实测跑通的值**，唯一改动 = `axilite_master_en=true` |
| `axi_regs.v`（我们写的） | 挂在 **user BAR (AXI4-Lite master)** 上的寄存器块，主机用 `reg_rw /dev/xdma0_user` 读写 |

**寄存器表**（字节地址）：

| 地址 | 属性 | 内容 |
|---|---|---|
| `0x00` | RO | `MAGIC` = `0x50360001`（证明"读的是我们的逻辑"，不是厂商的） |
| `0x04` | RO | `BUILD_ID` = **前置闸**读的那一项（每次改动自增） |
| `0x08` | RW | `SCRATCH`（读写回环 + 字节选通测试） |
| `0x0C` | RO | `FREECNT`（axi_aclk 自由计数器 ⇒ 活体探针 + **反解 AXI 时钟频率**） |
| `0x10` | RO | `HW_STATUS` = `{msi_vector_width, msi_enable, user_lnk_up}` |
| `0x14` | RO | `MARKER` = `0xDEADBEEF`（地址译码检查） |
| 其它 | — | 读/写都回 **SLVERR**（不静默成功） |

**接线配方逐条照抄厂商 BD**（那是这块板上唯一跑通过的 XDMA 接法，从 `.bd` 的 nets 读出）：
`IBUFDS_GTE4.O → sys_clk_gt`、`IBUFDS_GTE4.ODIV2 → sys_clk`、`pcieReset → sys_rst_n`（**直连无反相器**）。

## 二、验收流程（一次上板，4 步）

```bash
# 1) 构建（本机，~10 min）
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_pcie\run_build_pcie_min.bat'
#    成功判据 = 位流存在（Vivado batch 出错**不一定**返回非零）+ XCICHK 全 OK
# 2) 烧录（本机，经 hw_server；1MHz；只走 JTAG，绝不写 QSPI）
vivado -mode batch -source _proj_pcie/program_pcie_min.tcl     # 看 'End of startup status: HIGH'
# 3) ⚠️ **重启主机**（192.168.0.38）—— PCIe 端点只认"FPGA 配置先于主机 POST"
sudo reboot
# 4) 主机侧验寄存器（一次 sudo）
ssh a@192.168.0.38 'sudo bash /home/a/xdma_test/pcie_regs_check.sh'
#    判据: MAGIC / MARKER 常量 + SCRATCH 读写回环 + 字节选通 + FREECNT 递增
#          + 未实现地址报错(负向) + AXI 时钟频率反解        日志 /tmp/pcie_regs_check.log
```

## 二·补、板级验收结果（2026-09-28，**已通过**）

烧 `pcie_min_top.bit`（JTAG 1MHz，`End of startup status: HIGH`）→ 重启主机 → 跑
`pcie_regs_check.sh`（日志 `/tmp/pcie_regs_check.log`）：

| 项 | 读数 | 证据强度 |
|---|---|---|
| 端点 / 链路 | `02:00.0 [10ee:9034]`，`5.0 GT/s` | ✓ |
| **BAR 结构** | `dmesg: identify_bars: **2 BARs: config 1, user 0**, bypass -1` | ⭐ 对比厂商设计的 `1 BARs: config 0, **user -1**` ⇒ **我们的设计多出一个 user BAR**（硬证据） |
| **设备节点** | 多了 **`/dev/xdma0_user`**（厂商设计**从来没有**） | ⭐ 同上 |
| **`MAGIC`(0x00)** | **`0x50360001`** | ⭐⭐ **确认读的是我们自己的逻辑** |
| `MARKER`(0x14) | `0xdeadbeef` | ✓ 地址译码正确 |
| `SCRATCH`(0x08) 回环 + 字节选通 | `0xa5a55a5a`；写 `0xFFFFFFFF` 后只写低字节 → `0xffffff11` | ✓ 写通路与 wstrb 都对 |
| `FREECNT`(0x0C) | 递增；Δ=77858253 / 0.3s ⇒ **≈250 MHz**（实测 259.5，误差来自 `sleep 0.3` 不准） | ✓ AXI 域活着 + 时钟反解有效 |
| 未实现地址(0x40) | 读出 **`0xffffffff`** | ✓ SLVERR 生效（见下"用法坑"） |
| **`/dev/xdma0_xvc`** | **存在**（厂商设计没有） | ⭐ **U4b 有了新的可能**：XVC 支持已编进驱动（`cdev_xvc.c`），只差一个**用户态 TCP 桥**（XVC 协议很简单）就能让 hw_server 经 PCIe 连 ⇒ 有机会省掉 USB/JTAG 线 |

⚠️ **用法坑（本轮踩到，已修判据）**：`reg_rw` **不会**因 SLVERR 打印错误 —— XDMA 的 AXI-Lite 主机把
错误响应的数据填成 **`0xffffffff`** 交回用户态。⇒ 判"未实现地址"要看**读出值**，不能去 grep
"error/fail" 字样（初版判据因此假 FAIL）。修正后本门 **8/8 全过**。

## 三、这一版**关掉/没关掉**什么

- ✅ 关掉：**我们自己例化的 XDMA 能否枚举 + 绑定驱动**（P6e 的配方）
- ✅ 关掉：**寄存器窗口通路**（user BAR / AXI-Lite）——之前厂商设计给不了
- ✅ 关掉：**前置闸**（读回 `BUILD_ID` 确认烧的就是这一版）
- ❌ 没做：**数据面**（本设计把 XDMA 的 `m_axi` DMA 通道全部 tie 成"永不应答"）
- ❌ 没做：**XVC**（若要省 USB/JTAG 线，需要在 IP 里另外例化；U4b 仍开着）
- ❌ 没做：**数据面 + 观测通道的合体**（那是下一步：把本目录的 `axi_regs` 与
  `xdma_0` 搬进 `board/wrapper_p4.v` 的 US+ 分支，注意状态位束要跨 `gmii_clk → axi_aclk`）

## 四、本目录文件

| 文件 | 用途 |
|---|---|
| `rtl/pcie_min_top.v` | 顶层：IBUFDS_GTE4 + xdma_0 + axi_regs |
| `rtl/axi_regs.v` | **我们的** AXI4-Lite 寄存器块（可复用到数据面设计） |
| `tb/tb_axi_regs.v` + `run_tb_axi_regs.bat` | 单元门（9 项判据，含字节选通与 SLVERR 负向） |
| `ku5p_pcie_min.xdc` | 引脚（PCIe 参考钟/复位/通道 + io_nor 探点） |
| `build_pcie_min.tcl` + `run_build_pcie_min.bat` + `check_xci.py` | 构建 + .xci 持久化校验 |
| `program_pcie_min.tcl` | 经 hw_server 烧录（复制到对端机后亦可由对端 Vivado 执行） |
| `pcie_regs_check.sh` | 主机侧验收脚本（对端机 `/home/a/xdma_test/` 下跑） |
| `probe_xdma.tcl` / `probe/` | 生成 XDMA IP 的探针工程（确定参数名与端口表的来源） |
