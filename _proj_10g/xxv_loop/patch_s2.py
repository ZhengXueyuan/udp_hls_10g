# patch_s2.py -- round-2 build-script changes: use the parameterised copy of the
# vendor traffic module and grow the VIO window to 48 probe_in / 8 probe_out.
import io

p = 'tcl/s2_build.tcl'
s = io.open(p, encoding='utf-8').read()


def rep(a, b, n=1):
    global s
    assert s.count(a) == n, ('count=%d pattern=%r' % (s.count(a), a[:80]))
    s = s.replace(a, b)


rep('set vrtl  "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_pkt_gen_mon.v"',
    'set vrtl  "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_pkt_gen_mon.v"\n'
    'set vrtlc "$root/rtl/pcs64_pkt_gen_mon_ds.v"   ;# parameterised COPY (pay_sel)')

rep("""    "$root/rtl/xgmii_rx_chk.v" \\
    $vrtl ]""",
    """    "$root/rtl/xgmii_rx_chk.v" \\
    $vrtlc ]""")

rep("""# the vendor file is USED VERBATIM: print its digest so "unmodified" is a fact
# in the log and not a claim in a report.
set fh [open $vrtl r]; set vtxt [read $fh]; close $fh
puts "S2_VENDOR_FILE = $vrtl"
puts "S2_VENDOR_BYTES = [string length $vtxt]\"""",
    """# The traffic module used by THIS build is rtl/pcs64_pkt_gen_mon_ds.v, a copy of
# the vendor file whose ONLY difference is a new `pay_sel` input threaded down to
# pcs64_mii_pkt_gen's `data_select` (the vendor hard-wired it to 2'b0, i.e. an
# all-zero XGMII payload).  pay_sel = 0 reproduces the vendor behaviour exactly.
# Both digests are printed so the relationship is a fact in the log, not a claim.
set fh  [open $vrtl r];  set vtxt  [read $fh]; close $fh
set fh2 [open $vrtlc r]; set vtxt2 [read $fh2]; close $fh2
puts "S2_VENDOR_FILE = $vrtl"
puts "S2_VENDOR_BYTES = [string length $vtxt]"
puts "S2_COPY_FILE = $vrtlc"
puts "S2_COPY_BYTES = [string length $vtxt2]"
puts "S2_COPY_DIFF_LINES = [llength [split [string trim [exec diff $vrtl $vrtlc]] \\n]]"
if {[catch {exec sha256sum $vrtl}  sh1]} { set sh1 "<no sha256sum>" }
if {[catch {exec sha256sum $vrtlc} sh2]} { set sh2 "<no sha256sum>" }
puts "S2_VENDOR_SHA256 $sh1"
puts "S2_COPY_SHA256 $sh2\"""")

rep("set vcfg [list CONFIG.C_NUM_PROBE_IN {36} CONFIG.C_NUM_PROBE_OUT {6}]",
    "set vcfg [list CONFIG.C_NUM_PROBE_IN {48} CONFIG.C_NUM_PROBE_OUT {8}]")
rep("""for {set i 0} {$i < 36} {incr i} {
    lappend vcfg CONFIG.C_PROBE_IN${i}_WIDTH {32}
}
for {set i 0} {$i < 6} {incr i} {
    lappend vcfg CONFIG.C_PROBE_OUT${i}_WIDTH {1}
}""",
    """for {set i 0} {$i < 48} {incr i} {
    lappend vcfg CONFIG.C_PROBE_IN${i}_WIDTH {32}
}
for {set i 0} {$i < 6} {incr i} {
    lappend vcfg CONFIG.C_PROBE_OUT${i}_WIDTH {1}
}
lappend vcfg CONFIG.C_PROBE_OUT6_WIDTH {3}
lappend vcfg CONFIG.C_PROBE_OUT7_WIDTH {1}""")
rep('puts "S2_VIO_W35    = [get_property CONFIG.C_PROBE_IN35_WIDTH [get_ips vio_0]]"',
    'puts "S2_VIO_W47    = [get_property CONFIG.C_PROBE_IN47_WIDTH [get_ips vio_0]]"\n'
    'puts "S2_VIO_O6W    = [get_property CONFIG.C_PROBE_OUT6_WIDTH [get_ips vio_0]]"')
# label the run so the log says which bitstream this is
rep('puts "S2_PART = [get_property part [current_project]]"',
    'puts "S2_PART = [get_property part [current_project]]"\n'
    'puts "S2_STAGE = round2 (loopback + payload-select + stat-domain probes)"')
io.open(p, 'w', encoding='utf-8').write(s)
print('s2_build.tcl patched')
