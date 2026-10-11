#=============================================================================
# pb_query.tcl -- M1 期 B (C2H 环 + 两从机) 的**定向锥查** (synth 检查点, 只读)
#
#   派单 §④ 要的三面:
#     ① DP 域 (g_hw.clk_out0) 最差 20 (pre-place synth 面; 与 m1 / m1p2 臂并列)
#     ② **新锥定向**: u_mir_ring* / u_mir_c2h* / u_mir_h2c* 的 -from / -to 最差各 20 +
#        每族的最差 slack/级数/端点 (判"新逻辑是否落进临界区")
#     ③ **pcie 域 (pcie_axi_aclk) 面**: 新件全在 pcie 域 ⇒ 该域最差 10 条也取一份
#         (含它们的 Requirement, 用来读"pcie 域是几 ns 的约束")
#     + 同一对 pin 的历史对照 (m1p2 臂的 DP WNS 宿主对: rx_state_reg[0]/C -> stg_reg[0]/CE)
#
#   用法: vivado -mode batch -source pb_query.tcl -nojournal -nolog -tclargs <arm>
#=============================================================================
set arm "m1p2b"
if {[llength $argv] >= 1} { set arm [lindex $argv 0] }
set d [file dirname [file normalize [info script]]]
open_project ${d}/prj_${arm}/p7b_m1_synth_${arm}.xpr
open_run synth_1
puts "PBQ_ARM = $arm"

# ---------- ① DP 域最差 20 ----------
catch {
    report_timing -delay_type max -from [get_clocks -quiet g_hw.clk_out0] \
                  -to [get_clocks -quiet g_hw.clk_out0] -max_paths 20 \
                  -file ${d}/dp_worst_${arm}.rpt
}
set pdp [get_timing_paths -delay_type max -from [get_clocks -quiet g_hw.clk_out0] \
                            -to [get_clocks -quiet g_hw.clk_out0] -max_paths 1]
if {[llength $pdp] > 0} {
    puts "PBQ_DP_WORST_SLACK = [get_property SLACK $pdp]"
    puts "PBQ_DP_WORST_LVL   = [get_property LOGIC_LEVELS $pdp]"
    puts "PBQ_DP_WORST_SRC   = [get_property STARTPOINT_PIN $pdp]"
    puts "PBQ_DP_WORST_DST   = [get_property ENDPOINT_PIN $pdp]"
    puts "PBQ_DP_WORST_REQ   = [get_property REQUIREMENT $pdp]"
}

# ---------- ② 新锥定向 (三个新模块各查 -from / -to) ----------
foreach {tag pat} {ring *u_mir_ring* c2h *u_mir_c2h* h2c *u_mir_h2c*} {
    set pins [get_pins -quiet -hierarchical -filter "NAME =~ $pat"]
    puts "PBQ_${tag}_PINS = [llength $pins]"
    if {[llength $pins] > 0} {
        catch { report_timing -delay_type max -max_paths 20 -from $pins -file ${d}/pb_${tag}_from_${arm}.rpt }
        catch { report_timing -delay_type max -max_paths 20 -to   $pins -file ${d}/pb_${tag}_to_${arm}.rpt }
        set pf [get_timing_paths -delay_type max -from $pins -max_paths 1]
        if {[llength $pf] > 0} {
            puts "PBQ_${tag}_FROM_SLACK = [get_property SLACK $pf]"
            puts "PBQ_${tag}_FROM_LVL   = [get_property LOGIC_LEVELS $pf]"
            puts "PBQ_${tag}_FROM_SRC   = [get_property STARTPOINT_PIN $pf]"
            puts "PBQ_${tag}_FROM_DST   = [get_property ENDPOINT_PIN $pf]"
        }
        set pt [get_timing_paths -delay_type max -to $pins -max_paths 1]
        if {[llength $pt] > 0} {
            puts "PBQ_${tag}_TO_SLACK = [get_property SLACK $pt]"
            puts "PBQ_${tag}_TO_LVL   = [get_property LOGIC_LEVELS $pt]"
            puts "PBQ_${tag}_TO_SRC   = [get_property STARTPOINT_PIN $pt]"
            puts "PBQ_${tag}_TO_DST   = [get_property ENDPOINT_PIN $pt]"
        }
    }
}

# ---------- ③ pcie 域面 (新件所在域) ----------
catch {
    report_timing -delay_type max -from [get_clocks -quiet pcie_axi_aclk] \
                  -to [get_clocks -quiet pcie_axi_aclk] -max_paths 10 \
                  -file ${d}/pcie_worst_${arm}.rpt
}
set pp [get_timing_paths -delay_type max -from [get_clocks -quiet pcie_axi_aclk] \
                            -to [get_clocks -quiet pcie_axi_aclk] -max_paths 1]
if {[llength $pp] > 0} {
    puts "PBQ_PCIE_WORST_SLACK = [get_property SLACK $pp]"
    puts "PBQ_PCIE_WORST_LVL   = [get_property LOGIC_LEVELS $pp]"
    puts "PBQ_PCIE_WORST_SRC   = [get_property STARTPOINT_PIN $pp]"
    puts "PBQ_PCIE_WORST_DST   = [get_property ENDPOINT_PIN $pp]"
    puts "PBQ_PCIE_WORST_REQ   = [get_property REQUIREMENT $pp]"
}

# ---------- ④ 历史同对 pin (与 m1 / m1p2 臂的对照点) ----------
set fs [get_pins -quiet u_tcp_tx/FSM_sequential_rx_state_reg[0]/C]
set fd [get_pins -quiet u_app/stg_reg[0]/CE]
if {[llength $fs] > 0 && [llength $fd] > 0} {
    report_timing -delay_type max -from $fs -to $fd -max_paths 1 -file ${d}/pair_${arm}.rpt
    set pq [get_timing_paths -delay_type max -from $fs -to $fd -max_paths 1]
    puts "PBQ_PAIR_SLACK = [get_property SLACK $pq]"
    puts "PBQ_PAIR_LVL   = [get_property LOGIC_LEVELS $pq]"
    puts "PBQ_PAIR_DELAY = [get_property DATAPATH_DELAY $pq]"
}

# ---------- ⑤ 全局最差 (与 M1SYNTH_WNS 对账) ----------
puts "PBQ_GLOBAL_WNS = [get_property SLACK [get_timing_paths -delay_type max]]"
puts "PBQ_GLOBAL_WHS = [get_property SLACK [get_timing_paths -delay_type min]]"
puts "PBQ_DONE"
exit
