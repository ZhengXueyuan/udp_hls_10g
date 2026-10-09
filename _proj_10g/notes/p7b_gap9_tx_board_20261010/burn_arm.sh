#!/bin/bash
# burn_arm.sh -- P7b-GAP9-TX 板级轮 (2026-10-10): 烧一臂 (A=负对照 0x16 / C=被测 0x17) 并现核身份
#   纪律: 只走 JTAG 易失烧录 (绝不写 QSPI); 每次测量前必重烧; 只烧归档件 (p7b_build_longsend/A
#         或 p7b_build_gap9/C), 绝不碰 vivado_prj/.../impl_1/。
#   用法: bash burn_arm.sh A|C  (本机 Git Bash)
set -u
ARM=${1:?usage: burn_arm.sh A|C}
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_gap9_tx_board_20261010
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSHSCRIPT='D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py'
SSH="$PY $SSHSCRIPT"

case "$ARM" in
  A) REL='_proj_10g/notes/p7b_build_longsend/A/wrapper_p4.bit'
     WANT=052c52006215a2c3d5f9d59f8c47e620e41eb20f271fbc09dabfff96330bc284
     BIT='D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longsend\A\wrapper_p4.bit'
     BID=0x00000016; BIE=0x00000016; NW=63 ;;   # 长流档: 63 字
  C) REL='_proj_10g/notes/p7b_build_gap9/C/wrapper_p4.bit'
     WANT=5fff2be847b36eeca48c2290fa799fdad555bcea547514ee33355717dcb32253
     BIT='D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_gap9\C\wrapper_p4.bit'
     BID=0x00000017; BIE=0x00000017; NW=65 ;;   # 构建 C: 65 字 (W63/W64)
  *) echo "ARM_UNKNOWN $ARM"; exit 2;;
esac
BS=$(basename "$BIT")

echo "=== SHA_PRE $(date +%s.%N)"
GOT=$(sha256sum "$ROOT/$REL" | cut -d' ' -f1)
echo "SHA_LOCAL arm=$ARM got=$GOT"
echo "SHA_WANT  arm=$ARM want=$WANT"
[ "$GOT" = "$WANT" ] || { echo "SHA_MISMATCH arm=$ARM"; exit 1; }
echo "SHA_OK arm=$ARM"
# 存档件 mtime (取证: 与构建轮登记的 C 位流时刻 2026-10-10 02:21 对照)
stat -c 'BIT_FILE %n size=%s mtime=%y' "$ROOT/$REL"

echo "=== BURN $(date +%s.%N)"
T0=$(date +%s)
TCPREG_BIT="$BIT" cmd /c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_biz_tcpreg\run_program_tcpreg.bat' >/dev/null 2>&1
F=$ROOT/_proj_10g/notes/p7b_biz_tcpreg/tcpreg_program_stdout.txt
MT=$(stat -c %Y "$F")
echo "BURN_STDOUT=$F mtime=$MT T0=$T0"
cp "$F" "$OUT/burn/burn_${ARM}_$(date +%Y%m%d_%H%M%S).txt"
echo "--- burn stdout (逐字) ---"
cat "$F"
echo "--- end burn stdout ---"
grep -q "End of startup status: HIGH" "$F" || { echo "BURN_FAIL $ARM (无 HIGH)"; exit 1; }
grep -q "TCPREG_PROG_DONE" "$F" || { echo "BURN_FAIL $ARM (无 DONE)"; exit 1; }
grep -q "$BS" "$F" || { echo "BURN_FAIL $ARM (位流路径不匹配)"; exit 1; }
[ "$MT" -ge "$((T0-5))" ] || { echo "BURN_FAIL $ARM (stdout 陈旧)"; exit 1; }
echo "BURN_OK arm=$ARM (HIGH+DONE+bit路径+新鲜度 四判据全过)"

echo "=== RESCAN $(date +%s.%N)"
PEER_PW=111111 $SSH --sudo "sh -c 'echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove; sleep 1; echo 1 > /sys/bus/pci/rescan'; sleep 3; echo '--- lspci ---'; lspci -s 02:00.0; lspci -vvv -s 02:00.0 2>/dev/null | grep -E 'LnkSta:|Region 0|Region 1'; echo '--- dmesg ---'; dmesg | tail -12; echo '--- dev ---'; ls -la /dev/xdma0_user; echo '--- xdma modules ---'; lsmod | grep xdma" 2>&1

echo "=== ID $(date +%s.%N)"
PEER_PW=111111 $SSH --sudo "EXPECT_BID=$BIE NW=$NW bash /tmp/p7b_biz/p7b_snap.sh id; echo ID_RC=\$?; echo '--- 0x08 ---'; /home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools/reg_rw /dev/xdma0_user 0x08 w 2>&1 | tail -1" 2>&1 | tee "$OUT/burn/id_${ARM}_$(date +%Y%m%d_%H%M%S).txt"
echo "=== ARM_READY $ARM $(date +%s.%N)"
