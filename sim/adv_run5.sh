#!/bin/bash
# 每 case 一个独立目录 (SIM=%~dp0): 彻底避免 xsim.dir 复用 / 文件锁问题
# 用法: bash adv_run_case.sh <case>
ROOT=/d/repo/ECO/udp_hls_10g
c="$1"
D="$ROOT/sim/advrun5/$c"
mkdir -p "$D"
sed 's|^set SIM=.*|set SIM=%~dp0|' "$ROOT/sim/p5adv/run_tb_p5_adv.bat" > "$D/run.bat"
"C:/Users/zhxue/anaconda3/python.exe" -c "
import sys
p=sys.argv[1]
d=open(p,'rb').read().replace(b'\r\n',b'\n').replace(b'\n',b'\r\n')
open(p,'wb').write(d)
" "$D/run.bat"
cd "$D"
cmd //c "D:\\repo\\ECO\\udp_hls_10g\\sim\\advrun5\\$c\\run.bat" "$c" > run.out 2>&1
rc=$?
echo "CASE $c EXIT=$rc"
tail -16 run.out
