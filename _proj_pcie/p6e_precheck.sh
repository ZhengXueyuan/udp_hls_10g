#!/bin/bash
#=============================================================================
# p6e_precheck.sh — 重启前的判别器: user BAR 全回 0xffffffff 到底是"该重启"还是"设计没应答"
#   逻辑: XDMA 有**两个** BAR —— config BAR (/dev/xdma0_control, XDMA 自己的寄存器)
#         与 user BAR (/dev/xdma0_user, **我们的**寄存器块)。
#     ① 若 **config BAR 读得动** (上次实测是 0x1fc00006) 而 user BAR 全 0xffffffff
#        ⇒ AXI 基础设施与 PCIe 链路都活着, 是**我们这侧**没应答 (axi_aresetn 没释放 /
#          axi_regs 没接上 / 地址没对上) ⇒ **重启主机救不了, 要回去查设计**。
#     ② 若 **两个都 0xffffffff** ⇒ 整个 AXI/PCIe 通路没起来 (烧录发生在 POST 之后,
#        端点没走完初始化) ⇒ **重启主机** (项目纪律: 烧完必重启)。
#   用法: sudo bash /home/a/xdma_test/p6e_precheck.sh
#   ⚠️ 别拿 lspci / config 空间 当"设备活着"的证据 —— 那可能是主机侧缓存状态。
#=============================================================================
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
rd(){ $T/reg_rw $1 $2 w 2>&1 | tail -1; }

echo "===== P6e 重启前判别 ====="
echo "-- config BAR (XDMA 自己的寄存器; 上次实测 0x1fc00006 = 0x1fc00006) --"
echo "   /dev/xdma0_control 0x00 : $(rd /dev/xdma0_control 0x00)"
echo "-- user BAR (我们的寄存器块; MAGIC 应 0x50360001; BUILD_ID=5 (1=最小 2=8字 3=16字 4=24字 5=P6b 双域32字)) --"
echo "   /dev/xdma0_user    0x00 : $(rd /dev/xdma0_user 0x00)"
echo "   /dev/xdma0_user    0x04 : $(rd /dev/xdma0_user 0x04)"
echo "-- 回绕自检 (排除"读的是同一个陈旧数据") --"
echo "   user 0x14 (MARKER=deadbeef) : $(rd /dev/xdma0_user 0x14)"
echo "-- dmesg (xdma) --"
dmesg 2>/dev/null | grep -iE "xdma|identify_bars" | tail -6
echo "===== 判读 ====="
echo "  config 读得动 + user 全 ffffffff  => 设计侧问题, **不用重启**, 回去查 axi_aresetn/接线"
echo "  两个都 ffffffff                  => **重启主机** (烧录发生在 POST 之后)"
