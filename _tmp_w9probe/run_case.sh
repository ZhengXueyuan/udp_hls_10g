#!/bin/sh
# usage: run_case.sh <tag> "<xvlog -d flags>" "<xsim plusargs>"
TAG=$1; DEFS=$2; PA=$3
R=D:/repo/XCKU5PMini/udp_hls_10g
W=$R/_tmp_w9probe
XV=C:/AMDDesignTools/2025.2/Vivado/bin
D=$W/run_$TAG
mkdir -p $D
rm -rf $D/xsim.dir
cmd //c "cd /d $D && $XV/xvlog.bat -work xil_defaultlib $DEFS $R/rtl/fifo_sync.v $R/rtl/checksum16.v ${APPSRC:-$R/rtl/app_udp_pattern.v} $R/rtl/udp_tx_cfg.v $R/rtl/udp_tx_frame.v $W/tb_w9probe.v" > $D/xvlog.log 2>&1
echo "xvlog_errs=$(grep -ci ERROR $D/xvlog.log)"
cmd //c "cd /d $D && $XV/xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_w9probe -s tb_w9probe" > $D/xelab.log 2>&1
cmd //c "cd /d $D && $XV/xsim.bat tb_w9probe -runall $PA -log xsim.log" > $D/xsim_out.log 2>&1
grep "W9PROBE" $D/xsim.log
