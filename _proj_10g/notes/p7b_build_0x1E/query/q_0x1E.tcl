# q_0x1E.tcl - snd_wnd 守卫 (BID 0x1E) 定向时序查询
#   基座 = p7b_build_0x1D/query/q_0x1D.tcl v2 (沿用其坑回避: 'PATH_GROUP'/'PATH_TYPE'
#   不是 timing_path 属性 [Common 17-54] ⇒ 组名从 report_timing 文本报告取,
#   get_timing_paths 上只用 SLACK/LOGIC_LEVELS/STARTPOINT_PIN/ENDPOINT_PIN)。
#   本轮新增:
#     (a) snd_wnd 守卫相关族: *pend_wnd* / *pending_wnd* / *ackok* / *ack_ok* /
#         *ack_adv* / *dup_l_reg* (放/取最差 from/to + 全 cell 清单, 供"网名归并"判读)
#     (b) 守卫连通性定向路径: -from *ackok* -to *pend_wnd*  (ackok_l 是否真的
#         复活进 pend_wnd 的 D 网; 有路径 = 结构连上, 无路径 = 名为 NOPATH)
#     (c) persist 族 (ps_*) 与缺陷刀族 (whi_r/ring_hi) 原样保留 = 挤动复核
#   用法: vivado -mode batch -source q_0x1E.tcl -tclargs <routed.dcp> <outdir>
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
# --- 本轮 snd_wnd 守卫族 ---
fam pend_wnd    {*pend_wnd*}
fam pending_wnd {*pending_wnd*}
fam ackok       {*ackok*}
fam ack_ok      {*ack_ok*}
fam ack_adv     {*ack_adv*}
fam dup_l_reg   {*dup_l_reg*}

# ---------- 3) 守卫连通性: ackok -> pend_wnd 是否真有路径 ----------
set src [get_cells -hier -quiet -filter {NAME =~ *ackok*}]
set dst [get_cells -hier -quiet -filter {NAME =~ *pend_wnd*}]
puts "X ackok_cells=[llength $src] pend_wnd_cells=[llength $dst]"
if {[llength $src] > 0 && [llength $dst] > 0} {
  set xp [get_timing_paths -delay_type max -max_paths 5 -sort_by slack -quiet -from $src -to $dst]
  puts "X ackok_to_pendwnd n=[llength $xp]"
  set k 0
  foreach p $xp {
    incr k
    puts "X #$k slack=[get_property SLACK $p] lvl=[get_property LOGIC_LEVELS $p] sp=[get_property STARTPOINT_PIN $p] ep=[get_property ENDPOINT_PIN $p]"
  }
} else { puts "X SKIP (missing endpoint set)" }

# ---------- 4) 全 cell 清单 (限 30/族; 处理网名归并) ----------
foreach pat {*pend_wnd* *pending_wnd* *ackok* *ack_ok* *ack_adv* *dup_l_reg* *ack_hi*} {
  set cells [get_cells -hier -quiet -filter "NAME =~ $pat"]
  puts "E pat=$pat ncell=[llength $cells]"
  set k 0
  foreach c $cells {
    incr k
    if {$k <= 30} { puts "E   cell=[get_property NAME $c] ref=[get_property REF_NAME $c]" }
  }
}
puts "N_DONE"
