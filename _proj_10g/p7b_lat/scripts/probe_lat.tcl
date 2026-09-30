#=============================================================================
# probe_lat.tcl -- P7b 分段延迟: 板级取数 (VIO over JTAG)
#=============================================================================
#
#  Run (Windows, Git Bash):
#     cmd //c '_proj_10g\p7b_lat\scripts\run_probe_lat.bat'
#   Env overrides:
#     LAT_BIT    bitstream   (默认 p7b_lat_prj/runs/impl_1/wrapper_p4.bit)
#     LAT_HWURL  hw_server   (默认 192.168.0.38:3121)
#     LAT_STIM   1/0 是否真的发激励 (默认 1; 0 = 只读当前锁存)
#     LAT_DRPSCAN 1/0 是否扫 DRP (默认 1)
#     LAT_PEER   ssh 目标 (默认 a@192.168.0.38)
#     LAT_IFACE  对端网口 (默认 enp1s0f1np1)
#
#  ⚠️ 本脚本**烧板** (JTAG 易失)。纪律: 构建期间绝不烧; 每次测量前必重烧。
#     绝不写 QSPI。
#
#  ⚠️ **32 位 Tcl 陷阱**: Vivado 2025.2 的 `format %d/%X` 对 >2^31 静默输出 0
#     ⇒ 本脚本**一个数都不转换**: VIO 输入一律按**十六进制字符串**取出、切片、
#     原样打印 (`LAT_HEX <probe> <hex>`), 所有算术留给离线 Python。
#     唯一需要的活体判据是 **1 位** (snapshot ack), 用 `scan %x` 取值 (0..15)。
#
#  ⚠️ 取数纪律: 每次快照都**先发 snap_req 再等 ack 变化**; 等不到就把这一代
#     标成 ACK_TIMEOUT 并**不当作读数** (本工程吃过 "拿一个值和它自己比" 的亏)。
#=============================================================================

set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here .. .. ..]]
set bit  [file join $root vivado_prj p7b_lat_prj.runs impl_1 wrapper_p4.bit]
set ltx  [file join $root vivado_prj p7b_lat_prj.runs impl_1 wrapper_p4.ltx]
set url  192.168.0.38:3121
set stim 1
# ⚠️ 默认 **关**: 本轮的位流**没有**开 `ADD_GT_CNTRL_STS_PORTS` ⇒ IP 没有 DRP 端口,
#    wrapper 的 `P7B_LAT_DRP` 分支没编 ⇒ DRP 读出字恒 0, 扫它只是白花 JTAG 时间。
#    要扫必须先用"参数置 1 + 45 个控制端口全部显式驱动"的配置重出位流 (见 §1.5)。
set drpscan 0
set peer  a@192.168.0.38
set iface enp1s0f1np1
if {[info exists ::env(LAT_BIT)]}      { set bit  $::env(LAT_BIT) }
if {[info exists ::env(LAT_HWURL)]}    { set url  $::env(LAT_HWURL) }
if {[info exists ::env(LAT_STIM)]}     { set stim $::env(LAT_STIM) }
if {[info exists ::env(LAT_DRPSCAN)]}  { set drpscan $::env(LAT_DRPSCAN) }
if {[info exists ::env(LAT_PEER)]}     { set peer $::env(LAT_PEER) }
if {[info exists ::env(LAT_IFACE)]}    { set iface $::env(LAT_IFACE) }

proc sec {s} { puts "\n@@@@@@ LAT >>> $s" ; flush stdout }
proc pget {o n} { if {[catch {set v [get_property $n $o]} e]} { return "<ERR:$e>" }; return $v }
proc padhex {s n} {
    set s [string trim $s]
    if {[string match "0x*" $s]} { set s [string range $s 2 end] }
    while {[string length $s] < $n} { set s "0$s" }
    return $s
}

sec "PREFLIGHT"
puts "LAT_BIT   = $bit"
puts "LAT_LTX   = $ltx"
puts "LAT_URL   = $url"
puts "LAT_STIM  = $stim"
puts "LAT_PEER  = $peer"
puts "LAT_IFACE = $iface"
if {![file exists $bit]} { puts "LAT-ABORT: bitstream not found"; exit 1 }
if {![file exists $ltx]} { puts "LAT-ABORT: .ltx not found -- VIO probes cannot be enumerated"; exit 1 }
puts "BIT_MTIME  = [file mtime $bit]"
puts "LTX_MTIME  = [file mtime $ltx]"

sec "CONNECT / SAFETY GATE"
open_hw_manager
connect_hw_server -url $url
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
set dlist [get_hw_devices]
puts "DEVICE_COUNT = [llength $dlist]"
foreach d $dlist { puts "DEVICE $d PART=[pget $d PART] IDCODE=[pget $d IDCODE_HEX]" }
set tdev ""
foreach d $dlist { if {[pget $d IDCODE_HEX] eq "04A62093"} { set tdev $d } }
if {$tdev eq "" || [llength $dlist] != 1} {
    puts "LAT-SAFETY_ABORT: target='$tdev' count=[llength $dlist] -- NOT PROGRAMMING"
    exit 1
}
puts "SAFETY_GATE = PASS -> $tdev"

sec "PROGRAM (JTAG volatile; NEVER QSPI)"
current_hw_device $tdev
set_property PROGRAM.FILE $bit $tdev
set_property PROBES.FILE $ltx $tdev
set_property FULL_PROBES.FILE $ltx $tdev
if {[catch {program_hw_devices $tdev} em]} { puts "LAT-ABORT PROGRAM FAILED: $em"; exit 1 }
puts "DONE_PIN = [pget $tdev REGISTER.CONFIG_STATUS.BIT\[14\]_DONE_PIN]"
refresh_hw_device $tdev

sec "PEER LINK RESTORE (precondition for the stimulus)"
# 为什么要等: 烧进去会复位 GT ⇒ 对端网卡看到 carrier 下/上 ⇒ **Linux 会重新给
#   enp1s0f1np1 加 IPv6 link-local 地址**。没有地址 ⇒ 内核在 IPv6 输出路径就把
#   包丢了 (socket 层仍报 "transmitted"), 实测:
#     ping6 报 "3 packets transmitted" 而 `port_tx_packets` 一动不动。
#   本次施工**没有 root** ⇒ 不能 `ip addr add`; 只能等这次 carrier flap 自己恢复。
set peer_ok 0
for {set i 0} {$i < 40} {incr i} {
    set rc [catch {exec ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
                   $peer "ip -br addr show $iface | grep -c 'fe80::'" } out]
    set n 0
    if {$rc == 0} { catch { set n [string trim $out] } }
    if {$n eq "1"} { set peer_ok 1 ; puts "LAT_PEER_ADDR_OK after [expr {$i * 500}] ms" ; break }
    after 500
}
if {!$peer_ok} {
    puts "LAT_PEER_ADDR_FAIL -- 对端 $iface 仍无 IPv6 link-local 地址; 激励发不出去"
    puts "  (不中止: 先跑无激励的负对照例, 但基线的 len 读数会是 0)"
}
# 另外记一次网卡自己的发射计数, 事后对账 "激励真的上线了吗"
catch { puts "LAT_PEER_TX0 [exec ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 $peer "ethtool -S $iface | grep -E 'port_tx_packets'"]" }

sec "VIO DISCOVERY"
set vio [lindex [get_hw_vios -of_objects $tdev] 0]
if {$vio eq ""} { puts "LAT-ABORT: no VIO in this design"; exit 1 }
puts "VIO = $vio"
set allp [get_hw_probes -of_objects $vio]
foreach p $allp { puts "  PROBE NAME=[pget $p NAME] WIDTH=[pget $p WIDTH]" }

proc findprobe {vio names} {
    set all [get_hw_probes -of_objects $vio]
    foreach n $names { foreach p $all { if {$p eq $n} { return $p } } }
    foreach n $names { foreach p $all { if {[string match $n $p]} { return $p } } }
    return ""
}
proc wof {p} { set w 1 ; catch {set w [get_property WIDTH $p]} ; return $w }
# 输出探针专用: 名字会撞车 (实测 `lat_clr` 先匹配到**输入**探针 `u_lat/lat_clr_1`)。
# 判据 = 这个探针支不支持 `OUTPUT_VALUE` (只有 VIO 的**输出**探针有)。
proc findoutprobe {vio names} {
    set all [get_hw_probes -of_objects $vio]
    set cand {}
    foreach n $names { foreach p $all { if {$p eq $n} { lappend cand $p } } }
    foreach n $names { foreach p $all { if {[string match $n $p]} { lappend cand $p } } }
    foreach p $cand {
        if {![catch {get_property OUTPUT_VALUE $p}]} { return $p }
    }
    return ""
}

# ---- 输入: 6 组 x 128 位 ----------------------------------------------------
#   ⚠️⚠️ 实测 (2026-09-30 第 1 次板级尝试): **不能**直接把 "128 位探针" 当一个数读。
#     Vivado 把宽网按**常量位**切碎 —— 例如 probe_in0 变成
#       {[0:31] ro_fe_a}{[32:63] ro_fe_b}{[64:95] dp_vs_r…}{[96:127] dp_c_r}
#     而 probe_in2 变成 {[0:114] lat_pi2_1}{[115] lat_clr}{[116] fe_rst_n}
#                      {[117:119] lat_pi2}{[120:127] <const0>_1..8}
#     ⇒ `get_hw_probes` 给回的是一堆**碎片**, 位序还得按 .ltx 的表拼回去。
#   这张表由 `gen_pinmap.py` 从 `.ltx` 抽出 (逐位覆盖自检: 每组 128/128, 无空洞)。
source [file join $here pinmap.tcl]
array set PP {}
foreach e $PINMAP {
    set port [lindex $e 0]
    set l    [lindex $e 1]
    set r    [lindex $e 2]
    set nm   [lindex $e 3]
    set p ""
    if {$nm ne ""} {
        # ⚠️ `.ltx` 里存的是**总线元素名** (如 `u_lat/dp_vs_r_reg_n_53_[31]`), 而
        #    `get_hw_probes` 给回的整条总线名**没有 `[n]` 后缀**
        #    (实测: `u_lat/dp_vs_r_reg_n_53_`) ⇒ 必须两个都试。
        set nm2 [regsub {\[[0-9]+\]$} $nm ""]
        set base [lindex [split $nm /] end]
        set base2 [regsub {\[[0-9]+\]$} $base ""]
        set p [findprobe $vio [list $nm $nm2 $base $base2]]
        if {$p eq ""} { puts "LAT-ABORT: pin net '$nm' (or '$nm2') not found among hw probes"; exit 1 }
        if {[wof $p] != [expr {$r - $l + 1}]} {
            puts "LAT-ABORT: pin '$nm' width=[wof $p] expected [expr {$r - $l + 1}]"; exit 1
        }
    }
    lappend PP($port) [list $l $r $p]
}
foreach port {probe_in0 probe_in1 probe_in2 probe_in3 probe_in4 probe_in5} {
    if {![info exists PP($port)]} { puts "LAT-ABORT: $port missing from pinmap"; exit 1 }
    set tot 0
    foreach it $PP($port) { incr tot [expr {[lindex $it 1] - [lindex $it 0] + 1}] }
    if {$tot != 128} { puts "LAT-ABORT: $port pinmap covers $tot bits, expected 128"; exit 1 }
    puts "PINMAP $port pieces=[llength $PP($port)] bits=$tot"
}
set PI {probe_in0 probe_in1 probe_in2 probe_in3 probe_in4 probe_in5}
# ---- 输出: 6 根控制 --------------------------------------------------------
#   期望的网名 = rtl 里那 6 根; 6 个位宽 (1,1,4,8,16,2) **两两不同** ⇒ 名字对不上时
#   可以按**唯一位宽**回捞 (仍然逐位断言, 不会静默抓错)。
set PO_NAME {snap_req lat_clr mut_sel mut_n drp_req_addr drp_req_go}
set PO_W    {1        1       4       8     16           2}
set PO {}
for {set i 0} {$i < 6} {incr i} {
    set want [lindex $PO_W $i]
    set p [findoutprobe $vio [list "u_lat/[lindex $PO_NAME $i]" [lindex $PO_NAME $i] "*[lindex $PO_NAME $i]*" "raw_po$i" "probe_out$i"]]
    if {$p eq "" || [wof $p] != $want} {
        # 回捞: 在**输出**向探针里找唯一一个该位宽的
        set cand ""
        set n 0
        foreach q [get_hw_probes -of_objects $vio] {
            if {[string match "*probe_out*" $q] || [string match "*raw_po*" $q]} {
                if {[wof $q] == $want} { lappend cand $q ; incr n }
            }
        }
        if {$n == 1} { set p [lindex $cand 0] }
    }
    if {$p eq ""} { puts "LAT-ABORT: output probe '[lindex $PO_NAME $i]' not found"; exit 1 }
    if {[wof $p] != $want} {
        puts "LAT-ABORT: output probe '[lindex $PO_NAME $i]' resolved to '$p' width=[wof $p] expected $want"
        exit 1
    }
    lappend PO $p
}
set P_SNAP [lindex $PO 0] ; set P_CLR  [lindex $PO 1]
set P_MUTS [lindex $PO 2] ; set P_MUTN [lindex $PO 3]
set P_DADDR [lindex $PO 4] ; set P_DGO [lindex $PO 5]
foreach {nm p} [list snap_req $P_SNAP lat_clr $P_CLR mut_sel $P_MUTS mut_n $P_MUTN drp_addr $P_DADDR drp_go $P_DGO] {
    puts "MAP $nm -> [pget $p NAME]"
}
puts "PROBES RESOLVED"

#------------------------------------------------------------------ helpers
proc vset {vio p val} {
    set w [wof $p]
    set n [expr {int(ceil($w / 4.0))}]
    set mask [expr {(1 << $w) - 1}]
    set s [format "%0${n}X" [expr {$val & $mask}]]
    set_property OUTPUT_VALUE $s $p
    commit_hw_vio $vio
}
proc vsetstr {vio p hexstr} {
    # 直接写十六进制字符串 (宽度必须已经对好) —— 避开所有整数转换
    set_property OUTPUT_VALUE $hexstr $p
    commit_hw_vio $vio
}
proc vread {vio p w} {
    refresh_hw_vio $vio
    set s [get_property INPUT_VALUE $p]
    return [padhex $s [expr {$w / 4}]]
}
proc viget {vio p} {
    refresh_hw_vio $vio
    return [get_property INPUT_VALUE $p]
}
proc pulse {vio p} { vset $vio $p 1 ; vset $vio $p 0 }
# drp_go 是 2 位探针 (每通道一位)。这里**同时翻两位** —— 一次把两个通道的
# 读请求都发出去, 它们在同一地址上各做一次事务 (仲裁器串行化)。
# ⚠️ 不读回当前值 (VIO 输出回读要额外一次 refresh), 用本地变量记账: 上电值 = 0。
set g_drpgo 0
proc toggle_drp_go {vio p} {
    global g_drpgo
    set g_drpgo [expr {$g_drpgo ? 0 : 3}]
    vset $vio $p $g_drpgo
}

# ---- 碎片拼接: 按 .ltx 的位表把 128 位拼回来 ---------------------------------
proc hex2bits {h n} {
    set out ""
    foreach ch [split [string toupper $h] ""] {
        switch -- $ch {
            0 { append out 0000 } 1 { append out 0001 } 2 { append out 0010 } 3 { append out 0011 }
            4 { append out 0100 } 5 { append out 0101 } 6 { append out 0110 } 7 { append out 0111 }
            8 { append out 1000 } 9 { append out 1001 } A { append out 1010 } B { append out 1011 }
            C { append out 1100 } D { append out 1101 } E { append out 1110 } F { append out 1111 }
            default { append out 0000 }
        }
    }
    if {[string length $out] < $n} { set out "[string repeat 0 [expr {$n - [string length $out]}]]$out" }
    return [string range $out end-[expr {$n - 1}] end]
}
proc bits2hex {bits} {
    set h ""
    for {set k 0} {$k < 128} {incr k 4} {
        set nib [string range $bits $k [expr {$k + 3}]]
        set v 0
        catch { set v [scan $nib %b] }
        append h [string index "0123456789ABCDEF" $v]
    }
    return $h
}
proc assemble {vio port} {
    global PP
    set bits [string repeat 0 128]      ;# bits[0] = 探针的**最高位** (bit127)
    foreach it $PP($port) {
        lassign $it l r p
        if {$p eq ""} { continue }      ;# 常量位 = 0
        set w [expr {$r - $l + 1}]
        set v [padhex [get_property INPUT_VALUE $p] [expr {int(ceil($w / 4.0))}]]
        set vb [hex2bits $v $w]
        for {set i 0} {$i < $w} {incr i} {
            set b [string index $vb end-$i]
            if {$b ne "0"} {
                set idx [expr {127 - ($l + $i)}]
                set bits [string replace $bits $idx $idx $b]
            }
        }
    }
    return [bits2hex $bits]
}
proc readall {vio} {
    refresh_hw_vio $vio                 ;# 一次 refresh 覆盖全部输入探针
    set out {}
    foreach port {probe_in0 probe_in1 probe_in2 probe_in3 probe_in4 probe_in5} {
        lappend out [assemble $vio $port]
    }
    return $out
}

# ---- flags 字 = W11 = probe_in2 的位 [127:112] = 32 位十六进制串的**头 4 个字符**
#      flags[0] = snap_ack ------------------------------------------------------
proc ackbit {pi2hex} {
    set fl [string range $pi2hex 0 3]
    set low [string index $fl 3]
    set v 0
    catch { set v [scan $low %x] }
    return [expr {$v & 1}]
}

set g_nsnap 0
# ⚠️ **必须用"翻电平"而不是"1 然后 0"**: RTL 边沿检测吃的是**任意跳变**, 发两个沿
#    就会做**两次快照** ⇒ ack 翻两次又回到原值, 主机的"等 ack 变化"永远等不到
#    (2026-09-30 实测: 13 例全部 ack=0 超时 3s, 而数据其实是好的 —— 那 3 秒的
#    空窗还放进来了背景帧, 把 `fe_len` 污染成 111)。
proc tgllevel {vio p} {
    global g_tglv
    if {![info exists g_tglv($p)]} { set g_tglv($p) 0 }
    set g_tglv($p) [expr {$g_tglv($p) ? 0 : 1}]
    vset $vio $p $g_tglv($p)
    return $g_tglv($p)
}
proc snapshot {vio p_snap} {
    global g_nsnap
    set before [ackbit [lindex [readall $vio] 2]]
    set lvl [tgllevel $vio $p_snap]         ;# 一次跳变 = 一次快照
    set t0 [clock milliseconds]
    set ok 0
    while {1} {
        set h [lindex [readall $vio] 2]
        if {[ackbit $h] != $before} { set ok 1 ; break }
        if {[clock milliseconds] - $t0 > 2000} { break }
    }
    incr g_nsnap
    return $ok
}

proc dump_all {vio label} {
    set i 0
    foreach h [readall $vio] {
        puts "LAT_HEX $label pi$i $h"
        incr i
    }
}

#------------------------------------------------------------------ 激励
proc stim_ping6 {peer iface len} {
    # 目标 = 网卡自己所属的全节点组播 (无需 ND / 无需对端有任何 IPv4 地址)
    # 以太网帧长(含 FCS) = 14(Eth) + 40(IPv6) + 8(ICMPv6) + N + 4
    #   => N = len - 66   (100 -> 34 / 158 -> 92 / 1514 -> 1448)
    set n [expr {$len - 66}]
    if {$n < 0} { return "BADLEN" }
    set cmd [list ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 $peer "ping6 -c 1 -W 2 -i 1 -s $n ff02::1%$iface"]
    set rc [catch {exec {*}$cmd} out]
    puts "LAT_STIM len=$len n=$n ssh_rc=$rc out=<[string map {"\n" " | "} $out]>"
    return $rc
}

proc run_case {vio p_snap p_clr p_muts p_mutn label len msel mn do_stim peer iface} {
    vset $vio $p_muts $msel
    vset $vio $p_mutn $mn
    tgllevel $vio $p_clr                    ;# 一次跳变 = 一次清位 (同样不要发两个沿)
    after 80
    if {$do_stim} { stim_ping6 $peer $iface $len }
    after 500
    set ok [snapshot $vio $p_snap]
    puts "LAT_CASE $label len=$len mut_sel=$msel mut_n=$mn ack=[expr {$ok ? 1 : 0}]"
    dump_all $vio $label
    # 第二次快照 (同一帧, 只是重读一次) —— 用来判"这一代读数是不是稳的"
    set ok2 [snapshot $vio $p_snap]
    puts "LAT_CASE2 $label ack=[expr {$ok2 ? 1 : 0}]"
    dump_all $vio "R_$label"
}

#================================================================== 测量
sec "MEASURE"
set cases {}
#   label            len   msel mn  stim
lappend cases [list nostim158    158  0 0 0]
lappend cases [list base100      100  0 0 1]
lappend cases [list base158      158  0 0 1]
lappend cases [list base1514    1514  0 0 1]
lappend cases [list rep100a      100  0 0 1]
lappend cases [list rep158a      158  0 0 1]
lappend cases [list rep1514a    1514  0 0 1]
lappend cases [list rep100b      100  0 0 1]
lappend cases [list rep158b      158  0 0 1]
lappend cases [list rep1514b    1514  0 0 1]
lappend cases [list mut_b_n10    158  1 10 1]
lappend cases [list mut_c_n10    158  3 10 1]
lappend cases [list mut_a_n10    158  5 10 1]
lappend cases [list mut_d_n10    158  4 10 1]
lappend cases [list mut_b_n30    158  1 30 1]
lappend cases [list mut_b_n0     158  1  0 1]
lappend cases [list postmut158   158  0  0 1]

foreach c $cases {
    if {!$stim} { set cs 0 } else { set cs [lindex $c 4] }
    run_case $vio $P_SNAP $P_CLR $P_MUTS $P_MUTN [lindex $c 0] [lindex $c 1] [lindex $c 2] [lindex $c 3] $cs $peer $iface
    # 清掉变异, 免得影响下一例
    vset $vio $P_MUTS 0
    vset $vio $P_MUTN 0
}

#================================================================== DRP
if {$drpscan} {
    sec "DRP SCAN"
    # ⚠️ 跨域纪律 (见 rtl/p7b_lat_drp.v 头): **先写地址, 停 >= 5ms, 再翻 go**
    # 先点名读一遍 (含任务书点名的 0x269), 再全扫 0x000..0x3FF 建图。
    # ⚠️ 顺序: DRP 在所有延迟例**之后** —— 若 DRP 仲裁出岔子影响了链路,
    #    延迟读数已经落袋。
    set addrs {}
    foreach a {0x000 0x001 0x011 0x018 0x01E 0x021 0x03E 0x057 0x0C6 \
               0x200 0x201 0x210 0x236 0x268 0x269 0x269 0x269 0x26A 0x2E9 0x2EA 0x2F0 0x3FF} {
        lappend addrs [expr {$a}]
    }
    puts "LAT_DRP_NAMED_N = [llength $addrs]"
    set prev0 ""
    set prev1 ""
    foreach a $addrs {
        set hex [format "%04X" $a]
        vsetstr $vio $P_DADDR $hex      # 先写地址...
        after 20                        # ...停 >> 1ms (跨域准静态纪律)...
        toggle_drp_go $vio $P_DGO       # ...再翻 go (边沿 = 一次事务)
        after 40
        refresh_hw_vio $vio             # 一次 refresh 读走 pi3/pi4
        set h3 [lindex [readall $vio] 3]
        set h4 [lindex [readall $vio] 4]
        puts "LAT_DRP addr=$hex pi3=$h3 pi4=$h4"
    }
    # 全扫 (10 位地址空间 = 1024 个地址 x 2 通道); 每条 ~60ms => ~1 分钟量级
    for {set a 0} {$a < 1024} {incr a} {
        set hex [format "%04X" $a]
        vsetstr $vio $P_DADDR $hex
        after 12
        toggle_drp_go $vio $P_DGO
        after 25
        refresh_hw_vio $vio
        set h3 [lindex [readall $vio] 3]
        set h4 [lindex [readall $vio] 4]
        puts "LAT_DRP addr=$hex pi3=$h3 pi4=$h4"
    }
    # 一次原子快照, 把 DRP 的 evt/回读地址固定下来
    set ok [snapshot $vio $P_SNAP]
    puts "LAT_DRP_SNAP ack=[expr {$ok ? 1 : 0}]"
    dump_all $vio drpsnap
}

sec "DONE"
puts "LAT_NSNAP = $g_nsnap"
exit
