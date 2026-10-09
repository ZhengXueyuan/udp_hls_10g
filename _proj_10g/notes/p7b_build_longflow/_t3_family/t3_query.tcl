# ==============================================================================
# t3_query.tcl — 只读时序取证 (T3)
# 用法: vivado -mode batch -source t3_query.tcl -nojournal -nolog -tclargs <tag> <dcp> <outdir>
# 纪律: 只 open_checkpoint + report_*/get_timing_paths + puts/file 写输出
#       禁: open_project / place_design / route_design / write_bitstream / write_checkpoint
# ==============================================================================
set tag    [lindex $argv 0]
set dcpp   [lindex $argv 1]
set outdir [lindex $argv 2]
file mkdir $outdir

proc stamp {} { return [clock format [clock seconds] -format "%H:%M:%S"] }
proc gp {obj prop {def "-"}} {
  if {[catch {set v [get_property $prop $obj]}]} { return $def }
  if {$v eq ""} { return $def }
  return $v
}
proc resolve_pin {pat} {
  foreach cand [list $pat "wrapper_p4/$pat"] {
    if {[catch {set p [get_pins -quiet $cand]} e]} { continue }
    if {[llength $p] > 0} { return $p }
  }
  return {}
}

puts "T3|BEGIN|$tag|[stamp]"
puts "T3|DCP|$tag|$dcpp|bytes=[file size $dcpp]|mtime=[file mtime $dcpp]"
open_checkpoint $dcpp
puts "T3|OPEN|$tag|[stamp]|design=[get_property NAME [current_design]]|part=[get_property PART [current_design]]"

# ---------- 0. 身份交叉核对 (dcp<->档) ----------
puts "T3|UTIL|$tag|LUTs=[llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == LUT}]]|REGs=[llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == REGISTER}]]"
puts "T3|UTIL2|$tag|FDRE=[llength [get_cells -hier -quiet -filter {REF_NAME == FDRE}]]|FDCE=[llength [get_cells -hier -quiet -filter {REF_NAME == FDCE}]]"

# ---------- 1. 关键寄存器存在性普查 ----------
foreach pat {bank_rdy_reg retx_active_reg ctrl_tcpcsum recv_first_reg tx_lfsr_reg ack_pend_r c_snd_una stg_reg pw_data snd_wnd_r} {
  set cells [get_cells -hier -quiet -filter "NAME =~ *${pat}*"]
  puts "T3|CELLS|$tag|$pat|n=[llength $cells]|ex=[lrange $cells 0 3]"
}

# ---------- 2. 全局 WNS / WHS ----------
set pmax [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
puts "T3|WNS|$tag|slack=[gp $pmax SLACK]|src=[gp $pmax STARTPOINT_PIN]|dst=[gp $pmax ENDPOINT_PIN]|grp=[gp $pmax PATH_GROUP]|lv=[gp $pmax LOGIC_LEVELS]|[stamp]"
set pmin [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
puts "T3|WHS|$tag|slack=[gp $pmin SLACK]|src=[gp $pmin STARTPOINT_PIN]|dst=[gp $pmin ENDPOINT_PIN]"

# ---------- 3. 近临界计数 (nworst=1 => 每端点最差一条) ----------
foreach thr {0.05 0.10 0.20 0.50} {
  set n [llength [get_timing_paths -quiet -delay_type max -slack_lesser_than $thr -max_paths 10000 -nworst 1]]
  puts "T3|CNT|$tag|lt_$thr|$n|[stamp]"
}

# ---------- 4. 最差 2000 条明细 (族普查用) ----------
set paths [get_timing_paths -quiet -delay_type max -max_paths 2000 -nworst 1]
set f [open "$outdir/worst2000_$tag.txt" w]
puts $f "# slack|src|dst|levels|datapath_delay|path_group"
foreach p $paths {
  puts $f "[gp $p SLACK]|[gp $p STARTPOINT_PIN]|[gp $p ENDPOINT_PIN]|[gp $p LOGIC_LEVELS]|[gp $p DATAPATH_DELAY]|[gp $p PATH_GROUP]"
}
close $f
puts "T3|DUMP|$tag|worst2000 lines=[llength $paths]|[stamp]"

# ---------- 5. task 指定的 report_timing 取证 ----------
report_timing -quiet -delay_type max -max_paths 200 -nworst 1 -file "$outdir/worst200_$tag.rpt"
puts "T3|RPT|$tag|worst200 written|[stamp]"

# ---------- 6. 同族定位 (每族: 精确端点对 + 该源的全体去向 + 该宿的全体来源) ----------
proc famq {tag label fromstr tostr outdir} {
  set a {}
  if {$fromstr ne ""} {
    set p [resolve_pin $fromstr]
    if {[llength $p] == 0} { puts "T3|FAM|$tag|$label|SRC_NOT_FOUND|$fromstr"; return }
    puts "T3|FAMRES|$tag|$label|src=[get_property NAME $p]"
    lappend a -from $p
  }
  if {$tostr ne ""} {
    set p [resolve_pin $tostr]
    if {[llength $p] == 0} { puts "T3|FAM|$tag|$label|DST_NOT_FOUND|$tostr"; return }
    puts "T3|FAMRES|$tag|$label|dst=[get_property NAME $p]"
    lappend a -to $p
  }
  set r [get_timing_paths -quiet -delay_type max -max_paths 8 -nworst 1 {*}$a]
  if {[llength $r] == 0} { puts "T3|FAM|$tag|$label|NOPATH"; return }
  set k 0
  foreach p $r {
    puts "T3|FAM|$tag|$label|$k|slack=[gp $p SLACK]|src=[gp $p STARTPOINT_PIN]|dst=[gp $p ENDPOINT_PIN]|lv=[gp $p LOGIC_LEVELS]|dly=[gp $p DATAPATH_DELAY]"
    incr k
  }
  # 全路径块 (仅精确对/单端时写)
  if {($fromstr ne "") && ($tostr ne "")} {
    catch { report_timing -quiet -delay_type max -max_paths 3 -nworst 1 {*}$a -file "$outdir/fam_${tag}_${label}.rpt" }
  }
}

puts "T3|FAMQ|$tag|start|[stamp]"
# 族 A = C1 的最差族 (23 级)
famq $tag A_exact "u_tcp_tx/bank_rdy_reg[0]/C" "u_app/stg_reg[33]/CE" $outdir
famq $tag A_src_only "u_tcp_tx/bank_rdy_reg[0]/C" "" $outdir
famq $tag A_dst_only "" "u_app/stg_reg[33]/CE" $outdir
famq $tag A2_dst_only "" "u_app/stg_reg[0]/CE" $outdir
# 族 B = retx_active -> ctrl_tcpcsum
famq $tag B_exact "u_tcp_tx/retx_active_reg/C" "u_tcp_tx/ctrl_tcpcsum_reg[14]/D" $outdir
famq $tag B_src_only "u_tcp_tx/retx_active_reg/C" "" $outdir
famq $tag B_dst_only "" "u_tcp_tx/ctrl_tcpcsum_reg[14]/D" $outdir
# 族 C = recv_first -> u_app
famq $tag C_exact "u_tcp_tx/recv_first_reg/C" "u_app/tx_lfsr_reg[10]/D" $outdir
famq $tag C_src_only "u_tcp_tx/recv_first_reg/C" "" $outdir
# 族 D = S2 最差 (c_snd_una -> tx_lfsr)
famq $tag D_exact "u_app_ctrl/c_snd_una_reg[14][8]/C" "u_app/tx_lfsr_reg[19]/D" $outdir
famq $tag D_src_only "u_app_ctrl/c_snd_una_reg[14][8]/C" "" $outdir
# 族 E = S1 最差 (ack_pend_r_reg_replica -> ctrl_tcpcsum)
famq $tag E_exact "u_tcp_tx/ack_pend_r_reg_replica/C" "u_tcp_tx/ctrl_tcpcsum_reg[14]/D" $outdir
famq $tag E_src_only "u_tcp_tx/ack_pend_r_reg_replica/C" "" $outdir
# 族 F = u_udp_tx 计和族 (S1/S3 第 10/7 条)
famq $tag F_src_only "u_app_udp/u_txf/dout_reg[70]/C" "" $outdir
puts "T3|FAMQ|$tag|done|[stamp]"

puts "T3|END|$tag|[stamp]"
