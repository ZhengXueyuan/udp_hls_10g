# `_pcie/` — KU5P 的 PCIe/XDMA 观测通道：验证结论与**用法**

> 背景：KU5P 板上**没有 UART**（见 `XCKU5PMini/CLAUDE.md`），P6 的观测通道定为
> **PCIe / XDMA**（`p6_spec.md` §P6e 与风险 U4）。本目录是 2026-09-28 那次验证的产物与用法。

## 一、结论（已实测，2026-09-28）

| 项 | 读数 | 证据 |
|---|---|---|
| 端点枚举 | `02:00.0` `10ee:9034`（Serial controller class `0700` —— 手册里"PCI 串行端口"陷阱的来源） | `lspci -nn` |
| 链路 | **`current_link_speed=5.0 GT/s`, `current_link_width=4`** = PCIe 2.0 x4（理论 2.0 GB/s）；端点 `max=8.0GT/s` 但根端是 Z87 芯片组 ⇒ 封顶 2.0 | `/sys/bus/pci/devices/0000:02:00.0/current_link_*` |
| 驱动 | **`Xilinx XDMA Reference Driver xdma v2025.2.0`**（**out-of-tree** ✓ 不是 in-tree 那个 DMAEngine 版） | `dmesg`：`xdma_mod_init` / `probe_one: 0000:02:00.0 xdma0` |
| BAR | **`identify_bars: 1 BARs: config 0, user -1, bypass -1`** ⇒ **该设计只引出配置 BAR，没有 user BAR** | `dmesg` + 无 `/dev/xdma0_user` |
| 通道 | `ch 1,1` = **1 个 H2C + 1 个 C2H** | `dmesg` `probe_one ... ch 1,1` |
| 设备节点 | **19 个**：`xdma0_control` / `h2c_0` / `c2h_0` / `events_0..15`（`crw------- root root` ⇒ **工具要 root**） | `ls /dev/xdma*` |
| 中断 | `IR-PCI-MSI-0000:02:00.0`，完成中断有计数 ⇒ **DMA 真的在走** | `/proc/interrupts` |
| 寄存器通路 | `reg_rw /dev/xdma0_control 0x0 w` → **`0x1fc00006`**（非 0 非全 F） | `reg_rw` |
| 数据通路 | **4MB 图案 H2C→(DDR4)→C2H 逐字节一致**，地址 0 与 16MB 两处都对；同址重读一致；**反向读序（尾→头）也对** ⇒ 是真存储不是 FIFO | `dma_to_device`/`dma_from_device` + `cmp` |
| 吞吐（扫曲线，见下） | **H2C 收敛到 ~804 MB/s**；C2H ≤ **257 MB/s**（且几乎不随批量改善 ⇒ **被工具开销污染，真实上限未测到**） | `/tmp/pcie_verify2.log` |
| **XVC**（JTAG over PCIe，风险 U4b） | **不可用**：无 `/dev/xdma0_xvc`（厂商 BD 没例化 XVC）⇒ **USB/JTAG 线仍必需** | 同上 |

## 一·补、吞吐特性（阶段 2 实测，2026-09-28）

| 用例（`-s` × `-c`） | H2C MB/s | C2H MB/s |
|---|---|---|
| 64KB ×1 | 39.1 | 20.3 |
| 64KB ×64（=4MB，批量） | **741.4** | 36.4 |
| 1MB ×1 | 369.8 | 161.7 |
| 4MB ×1 | 624.5 | 248.9 |
| 16MB ×1 | **804.2** | **256.8** |

**读法（曲线的形状比数字本身更重要）**：
- **H2C 是"固定开销 + 线性"**：64KB 单发只有 39 MB/s，批量（`-c 64`）后跳到 **741 MB/s**，
  16MB 单发 **804 MB/s** ⇒ **天花板 ~800 MB/s ≈ 40% 链路**，瓶颈在**这个工具/单队列**，
  不是链路。⇒ 要用 PCIe 灌数就得**多通道 + 深提交**（自写用户态程序）。
- **C2H 几乎不随批量改善**（64KB×64 只 36 MB/s，×1 是 20 MB/s；16MB 单发才 257 MB/s）
  ⇒ 每个传输有 **~1.8ms 级固定成本**（工具的完成等待/轮询粒度），**C2H 的真实上限没被测到**。
  ⚠️ **不要把 257 MB/s 当成板子能力**；要判 C2H 真实上限得换工具（多通道 / 非阻塞 poll / 批量提交）。
- ⚠️ **规划约束（给 P6e/P6f）**：板子在**芯片组槽 2.0 x4 = 2.0 GB/s 理论**，而 10G 线速是
  **1.25 GB/s** ⇒ **只有 1.6× 余量**，扣掉协议开销与上述工具损失后**不适合当 10G 速率的采集通道**；
  它适合当**寄存器/状态/低频数据**通道。若要 10G 级采集，得靠"把板子搬到本机 4.0 x4（7.9 GB/s）"
  或走 1G/10G 网络本身（见 `p6_spec.md` §1.8 的搬机权衡）。

## 二、⭐ 头号操作纪律：**PCIe 端点的存亡取决于"配置 ↔ 主机 POST 的先后"**

- 只要 FPGA 上跑的是**没有 PCIe 的设计**（例如我们的 MDIO/数据面位流），端点就不存在；
  **主机开机时扫描不到 ⇒ 根端口 LTSSM 直接放弃**。
- 事后**再烧**一个带 PCIe 的设计也**救不回来**：实测 4 种主机侧手段全部无效 ——
  `rescan`（根端口与全总线）、桥复位（`/sys/.../reset` = secondary bus reset）、
  `setpci CAP_EXP+0x10.w=0x20`（Retrain Link）、`setpci ...=0x10 → 0x00`（Link Disable 1→0）。
  现象恒为 `LnkSta: Speed 2.5GT/s, Width x0`。
- **唯一可靠的恢复 = 重启主机**（热重启即可）：BIOS 在 POST 重新训练链路 ✓。
  重启期间 FPGA 若不掉电则保留位流，掉了就从 QSPI 加载厂商设计（**也带 XDMA**）——两种都对。
- ⇒ **纪律**：**要 PCIe 通道时，先把带 PCIe 的位流烧好再重启**；反之，每次 JTAG 烧非 PCIe
  设计都等于"本次上电周期内放弃 PCIe 观测"。这条对 P6e（正式观测通道）是硬约束。
- ⚠️ 附带解释：`SltSta: ... PresDet-`（主机认为槽里没卡）在本板一直如此，**与链路无关**，
  不是故障信号；`LnkCap: 5GT/s x4` 才是槽的能力。

## 三、用法（可复跑）

```bash
# 0) 前提：FPGA 已配置**带 XDMA 的设计**（厂商出厂位流即可），且主机是在那之后开的机
# 1) 加载驱动 —— ⚠️ 必须 insmod 绝对路径；modprobe 会取 in-tree 的 DMAEngine 版（无 /dev/xdma*）
sudo insmod /home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/xdma/xdma.ko
ls /dev/xdma0_*                 # 应出现 19 个节点

# 2) 判定"驱动真的绑上了"—— ⚠️ 不要用 lspci -k（insmod 的 out-of-tree 模块不一定显示为
#    "Kernel driver in use"，会假失败）；用 dmesg 的 probe 行：
sudo dmesg | grep -E "xdma0|identify_bars|probe_one"

# 3) 寄存器读（配置 BAR，XDMA IP 自身寄存器；该设计无 user BAR）
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
sudo $TOOLS/reg_rw /dev/xdma0_control 0x0 w          # 期望 0x1fc00006

# 4) 数据往返（-d 设备 / -a AXI 地址 / -s 单次字节 / -c 提交次数 / -f 文件）
sudo $TOOLS/dma_to_device   -d /dev/xdma0_h2c_0 -f /tmp/pat.bin -s 4194304 -a 0
sudo $TOOLS/dma_from_device -d /dev/xdma0_c2h_0 -f /tmp/out.bin -s 4194304 -a 0
cmp /tmp/pat.bin /tmp/out.bin && echo 一致

# 5) 一键验证脚本（本目录，跑在对端机）
scp pcie_verify.sh a@192.168.0.38:/home/a/xdma_test/ && ssh a@192.168.0.38 'sudo bash /home/a/xdma_test/pcie_verify.sh'
#   日志 /tmp/pcie_verify.log；阶段 A=枚举 B=驱动 C=寄存器 D=数据往返 E=XVC
```

**AXI 地址空间（厂商设计）**：XDMA 的 M_AXI 映射到 **DDR4 偏移 `0x0`、范围 512M**
（见 `XCKU5PMini/CLAUDE.md` 的 BD 说明）⇒ `-a 0x0` 写的是板载 DDR4。
⚠️ 该窗口是厂商设计的（非我们自己的），**别指望里面的数据有意义**；它只用来验证通道。

## 四、对我们自己设计的三条含义（P6e 之前必读）

1. **user BAR 要自己例化**：厂商设计没有 user BAR ⇒ 我们的寄存器窗口（P6e 的"寄存器映射"）
   必须在 BD 里显式引出（XDMA 的 AXI-Lite master → 我们的 app_ctrl/状态寄存器）。
2. **XVC 也要自己例化**（若要省掉 USB/JTAG 线）：本次设计无 `cdev_xvc` ⇒ U4b 未验证。
3. **单通道 1 H2C + 1 C2H 的吞吐远低于链路**：正式采集/灌数要**多通道 + 深提交**
   （`-c` 或自写 `xdma` 用户态程序批量提交），别用 `dma_to_device` 的单发数字当性能预期。

## 五、本目录文件

| 文件 | 用途 |
|---|---|
| `probe_dev.tcl` / `run_probe_dev.bat` | 只读：经 hw_server 看器件状态（PART/IS_PROGRAMMED/IDCODE） |
| `program_factory.tcl` / `run_program_factory.bat` | **把厂商出厂位流（带 XDMA）经 JTAG 烧回**（1MHz；只走 JTAG，绝不写 QSPI）。板子 PCIe 端点丢失时的恢复第一步 |
| `pcie_verify.sh` | 对端机上的一键验证（5 阶段，见上）——**脚本内容以对端机 `/home/a/xdma_test/` 那份为准**（本目录是源） |
| `pcie_verify2.sh` | 阶段 2：修判据（dmesg probe 而非 lspci -k）+ 吞吐特性扫（`-s`/`-c`）+ 反向读序 |
