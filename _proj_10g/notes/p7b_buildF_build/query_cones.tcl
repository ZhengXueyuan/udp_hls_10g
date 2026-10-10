# query_cones.tcl - P7b 构建 F: directed cone queries on a routed checkpoint.
# usage: vivado -mode batch -nojournal -nolog -source query_cones.tcl -tclargs <dcp> <tag> <outdir>
# Prints everything to stdout AND writes per-query report files into <outdir>.
# read-only: open_checkpoint + report_timing only.  No writes to the design.

set dcp [lindex $argv 0]
set tag [lindex $argv 1]
set out [lindex $argv 2]

puts "=== QUERY_TAG $tag ==="
puts "=== QUERY_DCP $dcp ==="
open_checkpoint $dcp

# ---- 0. discriminator counts ------------------------------------------------
proc cnt {pat} {
  if {[catch {llength [get_cells -hier -quiet -filter "NAME =~ $pat"]} n]} { set n ERR }
  return $n
}
foreach pat {*stat_winstall_reg* *stat_winstall_cap_reg* *win_at_winstall_reg* \
             *stat_ack_adv_reg* *win_wnd_eff_reg* *win_inflight_reg*} {
  puts "CELLCOUNT $tag $pat = [cnt $pat]"
}

# ---- 0b. name dump for the instrument families (exact FF names) -------------
foreach pat {*stat_winstall_reg* *stat_winstall_cap_reg* *win_at_winstall_reg* \
             *stat_ack_adv_reg*} {
  foreach c [get_cells -hier -quiet -filter "NAME =~ $pat"] {
    puts "CELL $tag $pat [get_property NAME $c]"
  }
}

# ---- 1. WNS (true worst setup) ---------------------------------------------
set p [get_timing_paths -max_paths 1 -delay_type max]
if {[llength $p]} {
  puts "WNS_$tag SLACK=[get_property SLACK $p]"
  puts "WNS_$tag SRC=[get_property STARTPOINT_PIN $p]"
  puts "WNS_$tag DST=[get_property ENDPOINT_PIN $p]"
  if {[catch {get_property PATH_GROUP $p} g]} { set g "(n/a)" }
  puts "WNS_$tag GROUP=$g"
  if {[catch {get_property LOGIC_LEVELS $p} l]} { set l "(n/a)" }
  puts "WNS_$tag LOGIC_LEVELS=$l"
  if {[catch {get_property DATAPATH_DELAY $p} dd]} { set dd "(n/a)" }
  puts "WNS_$tag DATAPATH_DELAY=$dd"
} else { puts "WNS_$tag NOPATH" }

report_timing -max_paths 1 -delay_type max -file $out/${tag}_wns_setup.rpt
report_timing -max_paths 20 -delay_type max -file $out/${tag}_top20_setup.rpt
report_timing -max_paths 5 -delay_type min -file $out/${tag}_worst_hold.rpt

# ---- 2. helper: worst path into a pin family --------------------------------
proc fam {tag out label regs pinname} {
  if {![llength $regs]} { puts "FAM $tag $label : NO CELLS"; return }
  set pins [get_pins -quiet -of $regs -filter "REF_PIN_NAME =~ $pinname"]
  if {![llength $pins]} { puts "FAM $tag $label : NO PINS ($pinname)"; return }
  set p [get_timing_paths -to $pins -max_paths 1 -delay_type max]
  if {[llength $p]} {
    puts "FAM $tag $label slack=[get_property SLACK $p] lvl=[get_property LOGIC_LEVELS $p] src=[get_property STARTPOINT_PIN $p] dst=[get_property ENDPOINT_PIN $p]"
  } else { puts "FAM $tag $label : NOPATH" }
  report_timing -to $pins -max_paths 10 -delay_type max -file $out/${tag}_${label}.rpt
}

# ---- 3. new-instrument cones (F only for *_cap / win_at; both tags for W66) -
set w67 [get_cells -hier -quiet -filter {NAME =~ *stat_winstall_cap_reg*}]
set w69 [get_cells -hier -quiet -filter {NAME =~ *win_at_winstall_reg*}]
set w68 [get_cells -hier -quiet -filter {NAME =~ *stat_ack_adv_reg*}]
set w66 [get_cells -hier -quiet -filter {NAME =~ *stat_winstall_reg*}]
set winw [get_cells -hier -quiet -filter {NAME =~ *win_wnd_eff_reg*}]
set wini [get_cells -hier -quiet -filter {NAME =~ *win_inflight_reg*}]

fam $tag $out w67_CE   $w67 CE
fam $tag $out w67_D    $w67 D
fam $tag $out w69_D    $w69 D
fam $tag $out w69_CE   $w69 CE
fam $tag $out w68_CE   $w68 CE
fam $tag $out w68_D    $w68 D
fam $tag $out w66_CE   $w66 CE
fam $tag $out win_wnd_eff_all $winw D
fam $tag $out win_inflight_all $wini D

# ---- 4. directed: win_wnd_eff -> w67 CE ------------------------------------
if {[llength $w67] && [llength $winw]} {
  set w67ce [get_pins -quiet -of $w67 -filter {REF_PIN_NAME =~ CE}]
  if {[llength $w67ce]} {
    report_timing -from $winw -to $w67ce -max_paths 10 -delay_type max -file $out/${tag}_winw2w67ce.rpt
    set q [get_timing_paths -from $winw -to $w67ce -max_paths 1 -delay_type max]
    if {[llength $q]} {
      puts "DIR $tag winw->w67ce slack=[get_property SLACK $q] lvl=[get_property LOGIC_LEVELS $q] src=[get_property STARTPOINT_PIN $q] dst=[get_property ENDPOINT_PIN $q]"
    } else { puts "DIR $tag winw->w67ce NOPATH" }
  }
  report_timing -from $winw -max_paths 10 -delay_type max -file $out/${tag}_winw_all.rpt
}

# ---- 5. the u_app/stg_reg family (E-档 WNS 宿族) ----------------------------
set stg [get_cells -hier -quiet -filter {NAME =~ u_app/stg_reg*}]
puts "CELLCOUNT $tag u_app/stg_reg* = [llength $stg]"
fam $tag $out stg_D  $stg D
fam $tag $out stg_CE $stg CE

# ---- 6. WNS source cell of E (rx_state_reg[1]_replica) ---------------------
set rep [get_cells -hier -quiet -filter {NAME =~ *FSM_sequential_rx_state_reg*replica*}]
puts "CELLCOUNT $tag rx_state_replica* = [llength $rep]"
if {[llength $rep]} {
  report_timing -from $rep -max_paths 10 -delay_type max -file $out/${tag}_rxstate_replica_all.rpt
  set q [get_timing_paths -from $rep -max_paths 1 -delay_type max]
  if {[llength $q]} {
    puts "DIR $tag rxreplica_all slack=[get_property SLACK $q] lvl=[get_property LOGIC_LEVELS $q] dst=[get_property ENDPOINT_PIN $q]"
  }
}

puts "=== QUERY_DONE $tag ==="
