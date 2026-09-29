#=====================================================================
# clkwiz_oracle.tcl -- 让 Xilinx Clocking Wizard 自己解一遍
#   100 MHz 差分输入 -> 156.25 MHz 输出
# 用它当 MMCM 参数合法性的**第二个独立证据源** (第一个是直接例化
# MMCME4_BASE 走 synth/opt/place 的 DRC)。工具自己解出来的
# MULT / DIVCLK / CLKOUT_DIVIDE / VCO 是我们预案的交叉核对。
#=====================================================================
set part_name xcku5p-ffvb676-1-e
set root D:/repo/XCKU5PMini/udp_hls_10g/board/ku5p_probe/clkgen_p6b
set prj $root/prj_clkwiz
file delete -force $prj
file mkdir $prj
create_project -force -part $part_name $prj/cw

create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 -module_name cw_oracle
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ              {100.000} \
    CONFIG.PRIM_SOURCE               {Differential_clock_capable_pin} \
    CONFIG.PRIMITIVE                 {MMCM} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {156.250} \
    CONFIG.CLKOUT1_REQUESTED_PHASE    {0.000} \
    CONFIG.USE_LOCKED                {true} \
    CONFIG.USE_RESET                 {false} \
] [get_ips cw_oracle]

puts "########## CLKWIZ ORACLE: 100 MHz -> 156.25 MHz ##########"
puts "--- solved CONFIG values (the wizard's own answer) ---"
foreach p [lsort [list_property [get_ips cw_oracle]]] {
    if {[string match "*MULT*" $p] || [string match "*DIVIDE*" $p] ||
        [string match "*VCO*" $p]  || [string match "*ACTUAL_OUT_FREQ*" $p] ||
        [string match "*PRIM_IN_FREQ*" $p] || [string match "*CLKOUT1_*FREQ*" $p]} {
        puts [format "  %-46s = %s" $p [get_property $p [get_ips cw_oracle]]]
    }
}

if {[catch { generate_target all [get_ips cw_oracle] } err]} {
    puts "ORACLE_ERR generate_target: $err"
} else {
    puts "--- generate_target all OK (wizard accepted these constraints) ---"
}

# 生成出来的 RTL 里 MMCM 原语的实参 = 工具最终解
set gv [glob -nocomplain $prj/cw/cw_oracle.srcs/sources_1/ip/cw_oracle/cw_oracle_clk_wiz.v \
                    $prj/cw/*.srcs/sources_1/ip/cw_oracle/cw_oracle_clk_wiz.v]
puts "--- generated RTL: $gv ---"
foreach f $gv {
    set fh [open $f r]
    while {[gets $fh line] >= 0} {
        if {[string match "*CLKFBOUT_MULT_F*" $line] ||
            [string match "*DIVCLK_DIVIDE*" $line]    ||
            [string match "*CLKOUT0_DIVIDE_F*" $line] ||
            [string match "*CLKOUT1_DIVIDE*" $line]   ||
            [string match "*CLKIN1_PERIOD*" $line]    ||
            [string match "*MMCME4*" $line]} {
            puts "  RTL| $line"
        }
    }
    close $fh
}
puts "########## CLKWIZ ORACLE DONE ##########"
