# q_0x1F.tcl - M1 载荷镜像窗 (BID 0x1F) 定向时序查询 (后布线)
#   基座 = p7b_build_0x1E/query/q_0x1E.tcl (沿用其坑回避: 'PATH_GROUP'/'PATH_TYPE'
#   不是 timing_path 属性 [Common 17-54] ⇒ 组名从 report_timing 文本报告取,
#   get_timing_paths 上只用 SLACK/LOGIC_LEVELS/STARTPOINT_PIN/ENDPOINT_PIN)。
#   本轮新增 (M1 面):
#     (a) M1 族 from/to 最差: *u_mir* (全) / *u_mir/* (app_rx_mirror 内部) /
#         *u_mir_ring* / *u_mir_c2h* / *u_mir_h2c*
#     (b) *mir_axi* —— ⚠️ 它们在 wrapper 里是 **wire (net) 不是 cell** ⇒
#         get_cells 预期 NOCELL; 改用 get_nets + get_pins -of_objects 做 from/to
#         (网名 ≠ RTL 信号, 见全局 #90)
#     (c) M1 cell 在 **DP 组 (g_hw.clk_out0) 内**的 from/to 最差 = "M1 锥离 DP WNS 多远"
#     (d) 0x1E 族 (pend_wnd/ackok/ack_adv/dup_l_reg) 复核未被挤动
#   保留: persist 族 (ps_*) / 缺陷刀族 (whi_r/ring_hi) 挤动复核 + 全局 top5 + DP top10/50
#   用法: vivado -mode batch -source q_0x1F.tcl -tclargs <routed.dcp> <outdir>
set dcp [lindex $argv 0]
set out [lindex $argv 1]
file mkdir $out
open_checkpoint $dcp

# ---------- 0) 全局 setup top-5 ----------
catch {report_timing -delay_type max -max_paths 5 -sort_by slack -file $out/global_top5.rpt}
set gp [get_timing_paths -delay_type max -max_paths 5 -sort_by slack -quiet]
set i 0
foreach p $gp {
  incr i
  puts "G #$i slack=[get_property SLACK $p] lvl=[get_property LOGIC_LEVELS $p] sp=[get_property STARTPOINT_PIN $p] ep=[get_property ENDPOINT_PIN $p]"
}
puts "G_DONE n=[llength $gp]"

# ---------- 1) DP 域 g_hw.clk_out0: setup 前 10 / 前 50 ----------
catch {report_timing -group g_hw.clk_out0 -delay_type max -max_paths 10 -sort_by slack -file $out/dp_top10.rpt}
catch {report_timing -group g_hw.clk_out0 -delay_type max -max_paths 50 -sort_by slack -file $out/dp_top50.rpt}
set dp [get_timing_paths -group g_hw.clk_out0 -delay_type max -max_paths 10 -sort_by slack -quiet]
set i 0
foreach p $dp {
  incr i
  puts "DP #$i slack=[get_property SLACK $p] lvl=[get_property LOGIC_LEVELS $p] sp=[get_property STARTPOINT_PIN $p] ep=[get_property ENDPOINT_PIN $p]"
}
puts "DP_DONE n=[llength $dp]"
set dw [get_timing_paths -group g_hw.clk_out0 -delay_type max -max_paths 1 -sort_by slack -quiet]
if {[llength $dw] > 0} {
  set p [lindex $dw 0]
  puts "DPWNS slack=[get_property SLACK $p] lvl=[get_property LOGIC_LEVELS $p] sp=[get_property STARTPOINT_PIN $p] ep=[get_property ENDPOINT_PIN $p]"
} else { puts "DPWNS NOPATH" }

# ---------- 2) 族 from/to 最差 ----------
proc fam {tag pat} {
  set cells [get_cells -hier -quiet -filter "NAME =~ $pat"]
  puts "F $tag ncell=[llength $cells]"
  if {[llength $cells] == 0} { puts "F $tag NOCELL"; return }
  set pf [get_timing_paths -delay_type max -max_paths 1 -sort_by slack -quiet -from $cells]
  if {[llength $pf] > 0} {
    set p [lindex $pf 0]
    puts "F $tag from_worst slack=[get_property SLACK $p] lvl=[get_property LOGIC_LEVELS $p] sp=[get_property STARTPOINT_PIN $p] ep=[get_property ENDPOINT_PIN $p]"
  } else { puts "F $tag from_NOPATH" }
  set pt [get_timing_paths -delay_type max -max_paths 1 -sort_by slack -quiet -to $cells]
  if {[llength $pt] > 0} {
    set p [lindex $pt 0]
    puts "F $tag to_worst slack=[get_property SLACK $p] lvl=[get_property LOGIC_LEVELS $p] sp=[get_property STARTPOINT_PIN $p] ep=[get_property ENDPOINT_PIN $p]"
  } else { puts "F $tag to_NOPATH" }
}
# --- ⭐ 本轮 M1 族 ---
fam m1_all      {*u_mir*}
fam m1_app_core {*u_mir/*}
fam m1_ring     {*u_mir_ring*}
fam m1_c2h      {*u_mir_c2h*}
fam m1_h2c      {*u_mir_h2c*}
fam m1_axi_cell {*mir_axi*}
# --- persist 族 (0x1D 内容; 复核未被挤动) ---
fam ps_timer    {*ps_timer_reg*}
fam ps_phase    {*ps_phase_reg*}
fam ps_stage    {*ps_stage_*}
fam ps_rd_d1    {*ps_rd_d1_reg*}
fam ps_rd_d2    {*ps_rd_d2_reg*}
fam ctrl_probe  {*ctrl_probe*}
fam tx_is_probe {*tx_is_probe*}
fam ctrl_pld    {*ctrl_pld_reg*}
fam probe_net   {*probe_sel*}
# --- 缺陷刀族 (0x1C 内容; 复核未被挤动) ---
fam whi_r       {*whi_r_reg*}
fam ring_hi     {*ring_hi_reg*}
# --- 0x1E 族 (snd_wnd 守卫; 复核未被挤动) ---
fam pend_wnd    {*pend_wnd*}
fam ackok       {*ackok*}
fam ack_adv     {*ack_adv*}
fam dup_l_reg   {*dup_l_reg*}

# ---------- 3) mir_axi_* (net, 非 cell) → pins → from/to ----------
set mnets [get_nets -hier -quiet -filter {NAME =~ *mir_axi*}]
puts "N mir_axi_nets=[llength $mnets]"
if {[llength $mnets] > 0} {
  set mpins [get_pins -quiet -of_objects $mnets]
  puts "N mir_axi_pins=[llength $mpins]"
  if {[llength $mpins] > 0} {
    set pf [get_timing_paths -delay_type max -max_paths 1 -sort_by slack -quiet -from $mpins]
    if {[llength $pf] > 0} { set p [lindex $pf 0]
      puts "N mir_axi from_worst slack=[get_property SLACK $p] lvl=[get_property LOGIC_LEVELS $p] sp=[get_property STARTPOINT_PIN $p] ep=[get_property ENDPOINT_PIN $p]"
    } else { puts "N mir_axi from_NOPATH" }
    set pt [get_timing_paths -delay_type max -max_paths 1 -sort_by slack -quiet -to $mpins]
    if {[llength $pt] > 0} { set p [lindex $pt 0]
      puts "N mir_axi to_worst slack=[get_property SLACK $p] lvl=[get_property LOGIC_LEVELS $p] sp=[get_property STARTPOINT_PIN $p] ep=[get_property ENDPOINT_PIN $p]"
    } else { puts "N mir_axi to_NOPATH" }
  }
}

# ---------- 4) M1 cell 在 DP 组内的 from/to (离 DP WNS 多远) ----------
set m1 [get_cells -hier -quiet -filter {NAME =~ *u_mir*}]
puts "M m1_cells=[llength $m1]"
if {[llength $m1] > 0} {
  set pf [get_timing_paths -group g_hw.clk_out0 -delay_type max -max_paths 1 -sort_by slack -quiet -from $m1]
  if {[llength $pf] > 0} { set p [lindex $pf 0]
    puts "M m1_dp_from slack=[get_property SLACK $p] lvl=[get_property LOGIC_LEVELS $p] sp=[get_property STARTPOINT_PIN $p] ep=[get_property ENDPOINT_PIN $p]"
  } else { puts "M m1_dp_from NOPATH" }
  set pt [get_timing_paths -group g_hw.clk_out0 -delay_type max -max_paths 1 -sort_by slack -quiet -to $m1]
  if {[llength $pt] > 0} { set p [lindex $pt 0]
    puts "M m1_dp_to slack=[get_property SLACK $p] lvl=[get_property LOGIC_LEVELS $p] sp=[get_property STARTPOINT_PIN $p] ep=[get_property ENDPOINT_PIN $p]"
  } else { puts "M m1_dp_to NOPATH" }
  # 全时钟面 (不分组) —— 含 pcie 域
  set pf2 [get_timing_paths -delay_type max -max_paths 3 -sort_by slack -quiet -from $m1]
  set k 0
  foreach p $pf2 { incr k
    puts "M m1_any_from #$k slack=[get_property SLACK $p] lvl=[get_property LOGIC_LEVELS $p] sp=[get_property STARTPOINT_PIN $p] ep=[get_property ENDPOINT_PIN $p]"
  }
  set pt2 [get_timing_paths -delay_type max -max_paths 3 -sort_by slack -quiet -to $m1]
  set k 0
  foreach p $pt2 { incr k
    puts "M m1_any_to #$k slack=[get_property SLACK $p] lvl=[get_property LOGIC_LEVELS $p] sp=[get_property STARTPOINT_PIN $p] ep=[get_property ENDPOINT_PIN $p]"
  }
} else { puts "M SKIP (no m1 cells)" }

# ---------- 5) 全 cell 清单 (限 30/族; 处理网名归并) ----------
foreach pat {*u_mir* *u_mir_ring* *u_mir_c2h* *u_mir_h2c*} {
  set cells [get_cells -hier -quiet -filter "NAME =~ $pat"]
  puts "E pat=$pat ncell=[llength $cells]"
  set k 0
  foreach c $cells {
    incr k
    if {$k <= 30} { puts "E   cell=[get_property NAME $c] ref=[get_property REF_NAME $c]" }
  }
}
puts "N_DONE"
