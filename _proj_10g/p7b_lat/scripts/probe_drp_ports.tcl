#=============================================================================
# probe_drp_ports.tcl -- can we get the GT DRP out of `xxv_ethernet`?
#
#   The P7B IP (`pcs64`) was generated with C_ADD_GT_CNTRL_STS_PORTS=0, and the
#   generated `pcs64_wrapper.v` ties the internal per-channel DRP bus to
#   constants (drpaddr_in_N = 0, drpen_in_N = 0, drpdo_out_N dangling).
#   The GUI parameter "Enable Additional GT Control/Status and DRP Ports" is
#   what exposes them.  This script answers, empirically:
#     Q1 does the parameter take effect on this IP/version?
#     Q2 what are the EXACT port names and widths it adds?
#     Q3 does the IP still generate + lock?
#
#   READ-ONLY w.r.t. the real build: it uses its own throwaway project dir.
#   It does NOT program anything and does NOT touch vivado_prj/p7b_ku5p_prj.
#=============================================================================
set part_name  xcku5p-ffvb676-1-e
set gquad      Quad_X0Y1
set here       [file dirname [file normalize [info script]]]
set root       [file normalize [file join $here .. .. ..]]
set probe_dir  [file join $root _proj_10g p7b_lat drp_probe]

proc sec {s} { puts "\nDRPP >>>>>>>>>> $s" }
catch {set_param general.maxThreads 8}

sec "DRPP_ENV"
puts "DRPP_VIVADO = [version -short]"
puts "DRPP_ROOT   = $root"

file mkdir $probe_dir
create_project -force drp_probe $probe_dir -part $part_name
set_property target_language Verilog [current_project]

sec "DRPP_IP_CREATE"
create_ip -name xxv_ethernet -vendor xilinx.com -library ip -version 5.0 -module_name pcs64
set ip [get_ips pcs64]

set DESIRED [list \
    CONFIG.LINE_RATE                  {10} \
    CONFIG.CLOCKING                   {Asynchronous} \
    CONFIG.BASE_R_KR                  {BASE-R} \
    CONFIG.GT_REF_CLK_FREQ            {156.25} \
    CONFIG.GT_TYPE                    {GTY} \
    CONFIG.INCLUDE_SHARED_LOGIC       {1} \
    CONFIG.GT_GROUP_SELECT            $gquad \
    CONFIG.NUM_OF_CORES               {2} \
    CONFIG.LANE1_GT_LOC               {X0Y4} \
    CONFIG.LANE2_GT_LOC               {X0Y5} \
    CONFIG.CORE                       {Ethernet PCS/PMA 64-bit} \
    CONFIG.ADD_GT_CNTRL_STS_PORTS     {1} ]

set conv -1
for {set rnd 1} {$rnd <= 8} {incr rnd} {
    foreach {k v} $DESIRED { catch {set_property $k $v $ip} e }
    set bad 0
    foreach {k v} $DESIRED {
        set gv "<err>"; catch {set gv [get_property $k $ip]}
        if {[string trim $gv] ne [string trim $v]} {
            incr bad ; puts "DRPP_RB_MISMATCH $k want=<$v> got=<$gv>"
        }
    }
    puts "DRPP_ROUND #$rnd MISMATCH_N = $bad"
    if {$bad == 0} { set conv $rnd ; break }
}
puts "DRPP_CONVERGED_AT_ROUND = $conv"
if {$conv < 0} { puts "DRPP_VERDICT = IP_NOT_CONVERGED" ; exit 1 }

set genrc [catch {generate_target all $ip} egen]
puts "DRPP_GENERATE_RC = $genrc"
if {$genrc != 0} { puts "DRPP_GENERATE_ERR = $egen" ; puts "DRPP_VERDICT = GENERATE_FAIL" ; exit 1 }
puts "DRPP_IS_LOCKED_POSTGEN = [get_property IS_LOCKED $ip]"

# ---- Q2: the authoritative added-port list comes from the generated .veo ----
sec "DRPP_VEO"
set veo [file join $probe_dir drp_probe.gen sources_1 ip pcs64 pcs64.veo]
puts "DRPP_VEO_PATH = $veo"
puts "DRPP_VEO_EXISTS = [file exists $veo]"
if {[file exists $veo]} {
    set fh [open $veo r]
    set n 0
    while {[gets $fh line] >= 0} {
        incr n
        if {[string match -nocase "*drp*" $line]} { puts "DRPP_VEO_DRP $n : $line" }
    }
    close $fh
    puts "DRPP_VEO_LINES = $n"
}
# also dump the whole port list so the wrapper edit can be written from facts
set vfile [file join $probe_dir drp_probe.gen sources_1 ip pcs64 pcs64.v]
puts "DRPP_VFILE_EXISTS = [file exists $vfile]"
if {[file exists $vfile]} {
    set fh [open $vfile r]
    set inside 0 ; set n 0
    while {[gets $fh line] >= 0} {
        incr n
        if {[string match "*module pcs64*" $line]} { set inside 1 ; puts "DRPP_MOD $n : $line" ; continue }
        if {$inside && [string match ");*" [string trim $line]]} { set inside 0 ; puts "DRPP_ENDMOD $n" }
        if {$inside && ([string match "*input*" [string trim $line]] || [string match "*output*" [string trim $line]])} {
            puts "DRPP_PORT $n : [string trim $line]"
        }
    }
    close $fh
}
puts "DRPP DONE"
exit
