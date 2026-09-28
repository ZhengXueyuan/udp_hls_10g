# program_factory.tcl - 把厂商出厂位流 (带 XDMA+DDR4) 经 JTAG 烧回 KU5P,
#   目的是恢复 PCIe 端点以验证 XDMA/PCIe 观测通道。
#   ⚠️ 只走 JTAG 易失烧录, **绝不写板载 QSPI** (见 XCKU5PMini/CLAUDE.md 的纪律)。
#   JTAG 时钟降到 1MHz; 烧完检查 DONE 是否为高。
set bit D:/repo/XCKU5PMini/Demo/XCKU5P_PCIe_DDR4_ETH_aurora_12g/vivado/ku5p/XCKU5P_PCIe_DDR4_ETH_arurora.runs/impl_1/DDR_PCIE_ETH_SFP_TOP.bit

open_hw_manager
connect_hw_server -url 192.168.0.38:3121
set tgt [lindex [get_hw_targets] 0]
open_hw_target $tgt
set dev [lindex [get_hw_devices xcku5p*] 0]
puts "PROG device = $dev"
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PARAM.FREQUENCY 1000000 [get_hw_targets $tgt]
puts "PROG jtag freq = 1 MHz"

set_property PROGRAM.FILE $bit $dev
puts "PROG file = $bit"
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev

puts "==== POST-PROGRAM ===="
foreach p {IS_PROGRAMMED PROGRAM.IS_PROGRAMMED REGISTER.IR.IDCODE} {
    if {[catch {get_property -quiet $p $dev} v]} { set v "<n/a>" }
    puts "PROG $p = $v"
}
puts "PROG DONE"
close_hw_target
disconnect_hw_server
close_hw_manager
