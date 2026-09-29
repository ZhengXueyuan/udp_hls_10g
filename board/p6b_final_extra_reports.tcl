#=============================================================================
# p6b_final_extra_reports.tcl — P6b 最终重建的**补充读数** (只读; 独立于 build 脚本)
#   用途 = 兜底: 若 build_p6b_final_ku5p.tcl 末尾的 CDC/ASYNC_REG 段因为 API 细节
#   (filter 语法 / 属性名 / 大设计超时) 没落盘, 用本脚本在**已布线的 checkpoint** 上重取。
#   用法: vivado -mode batch -source board/p6b_final_extra_reports.tcl -nojournal -nolog
#   产出 (全部落在 board/):
#     p6b_final_ku5p_hold_400.rpt     hold 三族口径 (report_timing -delay_type min)
#     p6b_final_ku5p_cdc.rpt          report_cdc -details
#     p6b_final_ku5p_async_reg.txt    ASYNC_REG==TRUE cell 普查 + 每 cell 的 REF_NAME/CLK
#     p6b_final_ku5p_lutram.txt       RAM32/64/128/256 + RAMB36E2/RAMB18E2/URAM288 实例数
#     p6b_final_ku5p_util.rpt         利用率 (与闸 G 基线对比)
#     p6b_final_ku5p_clocks.rpt       时钟表 (双域周期复核)
#=============================================================================
set script_dir [file dirname [file normalize [info script]]]
open_project ${script_dir}/../vivado_prj/p6b_final_ku5p_prj.xpr
open_run impl_1

puts "===== design state: [get_property STATUS [get_runs impl_1]] ====="

report_timing -delay_type min -max_paths 400 -nworst 1 \
    -file ${script_dir}/p6b_final_ku5p_hold_400.rpt
report_utilization -file ${script_dir}/p6b_final_ku5p_util.rpt
report_clocks     -file ${script_dir}/p6b_final_ku5p_clocks.rpt

# ---- report_cdc ----
report_cdc -details -file ${script_dir}/p6b_final_ku5p_cdc.rpt

# ---- ASYNC_REG 普查 (两种取法, 互为对照 —— 单一取法返回 0 时能立刻分辨"真没有" vs "语法错") ----
set fp [open ${script_dir}/p6b_final_ku5p_async_reg.txt w]
set ar1 [get_cells -hier -quiet -filter {ASYNC_REG == TRUE}]
puts $fp "# method1 get_cells -hier -filter {ASYNC_REG == TRUE}: [llength $ar1] cells"
set ar2 {}
foreach c [get_cells -hier -quiet] {
    if {[get_property -quiet ASYNC_REG $c] == 1} { lappend ar2 $c }
}
puts $fp "# method2 scan all cells, ASYNC_REG property == 1 : [llength $ar2] cells"
set union [lsort -unique [concat $ar1 $ar2]]
puts $fp "# union: [llength $union] cells"
puts $fp "#"
puts $fp "# NAME\tREF_NAME\tCLK\tIS_SEQUENTIAL"
foreach c $union {
    puts $fp "$c\t[get_property -quiet REF_NAME $c]\t[get_property -quiet CLK $c]\t[get_property -quiet IS_SEQUENTIAL $c]"
}
close $fp
puts "ASYNC_REG union count = [llength $union]"

# ---- LUTRAM / BRAM 原语普查 (FWFT FIFO 是否真落 LUTRAM) ----
set fl [open ${script_dir}/p6b_final_ku5p_lutram.txt w]
puts $fl "# primitive instance counts in the ROUTED design"
foreach t {RAM32X1S RAM32X1D RAM32M RAM64X1S RAM64X1D RAM64M RAM128X1D RAM256X1S \
           RAMB18E2 RAMB36E2 URAM288 FDRE FDCE FDSE FDCPE LUT6 LUT5 CARRY8} {
    set n [llength [get_cells -hier -quiet -filter "REF_NAME == $t"]]
    puts $fl "$t\t$n"
}
close $fl

exit
