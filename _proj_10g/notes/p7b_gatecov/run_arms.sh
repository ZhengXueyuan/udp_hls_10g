#!/bin/sh
# P7B gate-coverage closeout: counterexample double-run matrix.
# Same TB (tb/tb_app_udp_rate.v) + same judge as the shipped gate sim/p5e_rate/run_tb_rate.bat;
# only two things differ between arms: the app_udp_pattern.v source, and the -d defines.
#
# usage:  sh _proj_10g/notes/p7b_gatecov/run_arms.sh
# output: one section per arm + logs under _proj_10g/notes/p7b_gatecov/logs/<tag>/
# NOTE: cmd.exe cannot execute a forward-slash relative path ("'_proj_10g' is not
#       recognized ..."), so every path handed to `cmd //c` is kept in backslash form.
set -u
cd "$(dirname "$0")/../../.." || exit 1
G='_proj_10g\notes\p7b_gatecov'
W=$(pwd -W)                       # windows-form absolute path of the repo root
PRE="$W\\_proj_10g\\notes\\p7b_gatecov\\mut\\app_udp_pattern_prefix.v"
FIX="$W\\rtl\\app_udp_pattern.v"

echo "### repo = $W"
echo "### PRE (defective)  md5=$(md5sum _proj_10g/notes/p7b_gatecov/mut/app_udp_pattern_prefix.v | cut -c1-32)  = git show HEAD:rtl/app_udp_pattern.v"
echo "### FIX (workspace)  md5=$(md5sum rtl/app_udp_pattern.v | cut -c1-32)"

run() {   # run <tag> <cfg> <app> <defines>
  echo "================ $1 : cfg=$2 defines=[$4] ================"
  RATE_ARM_DEFS="$4" cmd //c "$G\\run_gate_rate.bat" "$2" "$3" "logs\\$1" 2>&1 \
    | grep -a -E "C1 contract|C2 framer|C3 wire|coverage:|CONTRACT FAIL|GEOM FAIL|COV FAIL|RATE GATE|mean wire len|app tx_frames|RATE TB DONE|usage:|ARM FAIL|PATHGUARD|ERROR"
}

# ---- defect vs fixed in the SHIPPED default cfg (g0p1472, no P7B_10G) ----
run H1_prefix_defgate    g0p1472     "$PRE" ""
run H5_fix_defgate       g0p1472     "$FIX" ""
# ---- defect vs fixed in the SATURATING cfg (the one the gate must run) ----
run H2_prefix_p7b        g0p1472     "$PRE" "-d P7B_10G"
run H3_fix_p7b           g0p1472     "$FIX" "-d P7B_10G"
# ---- coverage: P7B_10G but WITH a TX gap => FIFO never fills => no defect possible ----
run H4_prefix_p7bslow    g58000p1472 "$PRE" "-d P7B_10G"
run H9_prefix_p7bg1380   g1380p1472  "$PRE" "-d P7B_10G"
run H10_prefix_p7bg5000  g5000p1472  "$PRE" "-d P7B_10G"
# ---- regression: the other cfgs of the shipped matrix (fixed RTL) ----
run H6_fix_g58000        g58000p1472 "$FIX" ""
run H7_fix_p996          g0p996      "$FIX" ""
run H8_fix_p512          g0p512      "$FIX" ""
