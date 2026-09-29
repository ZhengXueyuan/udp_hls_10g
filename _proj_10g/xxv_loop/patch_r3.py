# patch_r3.py -- round-2 follow-ups: fix the s7 probe labels and harden the
# build gate against the implicit-net message Vivado 2025.2 actually emits.
import io

# ---- 1) s7 probe labels: exactly NPROBE entries, RTL order -------------------
p = 'tcl/s7_probe2.tcl'
s = io.open(p, encoding='utf-8').read()
old = "set IN_LABEL {st0 st1 cnt0 cnt1"
i = s.index(old)
j = s.index("}", s.index("e_pre0", i))
new = """# 48 labels, in the RTL's own probe order.  oi32/oi33 and oi34/oi35 are
# deliberate DUPLICATES (err_w / dclk_snap are wired to two VIO pins each).
# The first version of this list had 46 entries, which silently shifted every
# label from 34 upwards and made the stat-domain counters read as the wrong nets.
set IN_LABEL {st0 st1 cnt0 cnt1 dclk_free tx0_free rx0_free rx1_free \\
              c0_words c0_ctrl c0_idle c0_e c0_frames \\
              c1_words c1_frames c1_ctrl c1_e c1_pay c1_badpay c1_badstart \\
              c1_badhdr c1_badterm c1_badlen c1_abort c1_lastw c1_idle c1_misc \\
              snap_gen c1_sword_lo c1_sword_hi c0_sword_lo flags err_w dclk_snap \\
              err_w2 dclk_snap2 vcc_d vcc_r ferr_d ferr_r bcd_d bcd_r ffe_d ffe_r \\
              errv_r e_pre1 e_post1 e_pre0}
if {[llength $IN_LABEL] != $NPROBE} { error "IN_LABEL/NPROBE mismatch" }"""
s = s[:i] + new + s[j+1:]
# c0_badterm / c0_abort are not exposed as probes
s = s.replace("badterm=$LA(c0_badterm) abort=$LA(c0_abort) ",
              "idle=$LA(c0_idle) e_pre0=$LA(e_pre0) ")
io.open(p, 'w', encoding='utf-8').write(s)
print('s7 labels:', s.count('err_w2'), 'label-check:', 'IN_LABEL/NPROBE' in s)

# ---- 2) build gate ----------------------------------------------------------
p2 = 'tcl/s2_build.tcl'
t = io.open(p2, encoding='utf-8').read()
old2 = 'set keys {implicitly\\ declared "Opt 31-155"'
assert old2 in t
head = t.index(old2)
tail = t.index('}', t.index('"multiple driver"', head))
new2 = ('# MEASURED 2026-09-29 (round 2): an implicit net is reported by Vivado 2025.2 as\n'
        "#   INFO: [Synth 8-11241] undeclared symbol 'pay_sel', assumed default net type 'wire'\n"
        '# and the resulting floating net as\n'
        '#   WARNING: [Synth 8-3848] Net pay_sel in module/entity ... does not have driver\n'
        '#   WARNING: [Synth 8-7129] Port pay_sel ... is either unconnected or has no load\n'
        '# The round-1/2 gate only looked for the phrase "implicitly declared" and so reported 0\n'
        '# while the design DID contain a real implicit net (which is how the ones-payload run\n'
        '# silently failed).  All four strings are gates now.\n'
        'set keys {implicitly\\ declared "8-11241" "undeclared symbol" "does not have driver" \\\n'
        '          "unconnected or has no load" "Opt 31-155" "Opt 31-67" "Route 35-54" \\\n'
        '          "Route 35-7" "AVAL-326" "NSTD-1" "UCIO-1" "12-4739" "not permitted" \\\n'
        '          "multiple driver"}')
t = t[:head] + new2 + t[tail+1:]
io.open(p2, 'w', encoding='utf-8').write(t)
print('gate keys:', t.count('8-11241'), 'undeclared:', t.count('undeclared symbol'))
