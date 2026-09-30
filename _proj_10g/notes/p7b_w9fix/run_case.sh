#!/bin/sh
# run_case.sh -- P7B-W9 反例双跑台架 (自定位: 从本脚本位置推 repo root)
# usage: sh run_case.sh <tag> <app_src> "<xvlog -d flags>"
#   app_src  = 被测的 app_udp_pattern.v (修前/修后两份)
#   flags    = -d P7B_10G -d UDP_TX_OVL -d POSTFIX ... (POSTFIX 只在修后给)
TAG=$1; SRC=$2; DEFS=$3; PA=$4
W=$(cd "$(dirname "$0")" && pwd -W)          # = .../udp_hls_10g/_proj_10g/notes/p7b_w9fix (Windows 形式!)
R=$(cd "$W/../../.." && pwd -W)              # = .../udp_hls_10g  (git 仓库根)
XV=C:/AMDDesignTools/2025.2/Vivado/bin
D=$W/run_$TAG
mkdir -p $D
rm -rf $D/xsim.dir
case "$SRC" in /*|[A-Za-z]:*) ;; *) SRC="$W/$SRC" ;; esac   # 相对路径按本台架目录解析
echo "TAG=$TAG SRC=$SRC DEFS=$DEFS PA=$PA" > $D/cmd.txt
md5sum "$SRC" >> $D/cmd.txt
cmd //c "cd /d $D && $XV/xvlog.bat -work xil_defaultlib $DEFS $R/rtl/fifo_sync.v $R/rtl/checksum16.v $SRC $R/rtl/udp_tx_cfg.v $R/rtl/udp_tx_frame.v $W/tb_w9fix.v" > $D/xvlog.log 2>&1
echo "xvlog_errs=$(grep -ci 'ERROR' $D/xvlog.log)"
cmd //c "cd /d $D && $XV/xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_w9fix -s tb_w9fix" > $D/xelab.log 2>&1
cmd //c "cd /d $D && $XV/xsim.bat tb_w9fix -runall $PA -log xsim.log" > $D/xsim_out.log 2>&1
grep "W9FIX" $D/xsim.log
