#!/bin/bash
# burn_arm.sh -- P7b snd_wnd 守卫板级轮: 烧归档位流 (0x1E 含守卫 / 0x1D 不含守卫=负对照)
#   纪律: 只走 JTAG 易失烧录 (绝不写 QSPI); 每次测量前必重烧; 只烧本目录副本
#         (burn/wrapper_p4_<ARM>.bit, 由 p7b_build_<ARM>/wrapper_p4.bit 复制);
#         ⛔ 绝不碰 vivado_prj/** 的活位流。
#   判据: sha256 与派单给定值相同 + stdout 新鲜 + "End of startup status: HIGH"
#         + 位流路径匹配 + TCPREG-ABORT 未出现 (非注释行口径)。
#   用法: PEER_PW=... bash burn_arm.sh <0x1E|0x1D>
set -u
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_sndwnd_board_20261011
ARM=${1:?usage: burn_arm.sh 0x1E|0x1D}
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
ROOTW=D:/repo/XCKU5PMini/udp_hls_10g
SSH="$PY $ROOTW/tools/peer_ssh.py"
[ -n "${PEER_PW:-}" ] || { echo "FATAL: 需要 PEER_PW (只用于 --sudo)"; exit 3; }

case "$ARM" in
  0x1E) WANT=e489ae4a4b868695cff1c6dfc2fbdef70de29d391cdb9a43e0a08accd342be1a; EXPBID=0x0000001E ;;
  0x1D) WANT=b48dc7ee7ddb7df2a057fdae324dbf302c5adc6f430a413e0bce0e3a25ee0b1f; EXPBID=0x0000001D ;;
  *) echo "FATAL: ARM 必须是 0x1E 或 0x1D"; exit 3 ;;
esac
SRC=$ROOT/_proj_10g/notes/p7b_build_$ARM/wrapper_p4.bit
BS=wrapper_p4_${ARM}.bit
LOCAL_BIT=$OUT/burn/$BS
BIT_WIN="D:\\repo\\XCKU5PMini\\udp_hls_10g\\_proj_10g\\notes\\p7b_sndwnd_board_20261011\\burn\\$BS"

mkdir -p "$OUT/burn"
LOG=$OUT/burn/BURN_${ARM}_$(date +%Y%m%d_%H%M%S).txt
exec > >(tee "$LOG") 2>&1

echo "=== COPY $(date +%s.%N)"
cp "$SRC" "$LOCAL_BIT"
echo "--- 源 (归档) ---";      sha256sum "$SRC"
echo "--- 副本 (烧录件) ---";  sha256sum "$LOCAL_BIT"
GOT=$(sha256sum "$LOCAL_BIT" | cut -d' ' -f1)
echo "SHA_WANT want=$WANT"
[ "$GOT" = "$WANT" ] || { echo "SHA_MISMATCH ⇒ 拒绝烧"; exit 1; }
echo "SHA_OK copy==archive ($GOT)"
stat -c 'LOCAL_BIT %n size=%s mtime=%y' "$LOCAL_BIT"

echo "=== 板上烧前身份 (现读 0x04)"
$SSH --sudo "/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools/reg_rw /dev/xdma0_user 0x04 w 2>&1 | tail -1"

echo "=== BURN $(date +%s.%N)"
T0=$(date +%s)
TCPREG_BIT="$BIT_WIN" cmd /c "D:\\repo\\XCKU5PMini\\udp_hls_10g\\_proj_10g\\notes\\p7b_biz_tcpreg\\run_program_tcpreg.bat" >/dev/null 2>&1
F=$ROOT/_proj_10g/notes/p7b_biz_tcpreg/tcpreg_program_stdout.txt
MT=$(stat -c %Y "$F")
echo "BURN_STDOUT=$F mtime=$MT T0=$T0"
cp "$F" "$OUT/burn/BURN_${ARM}_stdout_copy_$(date +%Y%m%d_%H%M%S).txt"
echo "--- burn stdout (关键行逐字) ---"
grep -E "TCPREG_BIT =|TCPREG_BIT_EXISTS|TCPREG_BIT_MTIME|End of startup status|TCPREG_PROG_DONE|TCPREG-ABORT|TCPREG_PROG device" "$F"
echo "--- end ---"
grep -q "End of startup status: HIGH" "$F" || { echo "BURN_FAIL (无 HIGH)"; exit 1; }
# ⚠️ tcl 会被 Vivado **回显进 stdout** (注释行同样含 TCPREG_PROG_DONE / TCPREG-ABORT 字样)
#    ⇒ 本判据一律只看**非注释行**。
grep -v '^#' "$F" | grep -q "TCPREG_PROG_DONE" || { echo "BURN_FAIL (无 DONE)"; exit 1; }
grep -q "$BS" "$F" || { echo "BURN_FAIL (位流路径不匹配: 期望含 $BS)"; exit 1; }
grep -v '^#' "$F" | grep -q "TCPREG-ABORT" && { echo "BURN_FAIL (出现 TCPREG-ABORT)"; exit 1; }
echo "--- 非注释行里的 DONE/ABORT 判定 ---"
grep -v '^#' "$F" | grep -E "TCPREG_PROG_DONE|TCPREG-ABORT" | tail -3
[ "$MT" -ge "$((T0-5))" ] || { echo "BURN_FAIL (stdout 陈旧)"; exit 1; }
echo "BURN_OK (HIGH+DONE+bit路径+新鲜度+无ABORT 五判据)"

echo "=== RESCAN $(date +%s.%N)"
$SSH --sudo "sh -c 'echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove; sleep 1; echo 1 > /sys/bus/pci/rescan'; sleep 3; echo '--- lspci ---'; lspci -s 02:00.0; lspci -vvv -s 02:00.0 2>/dev/null | grep -E 'LnkSta:|Region 0|Region 1'; echo '--- dev ---'; ls -la /dev/xdma0_user"

echo "=== ID $(date +%s.%N)"
$SSH --sudo "EXPECT_BID=$EXPBID NW=70 bash /tmp/p7b_biz/p7b_snap.sh id; echo ID_RC=\$?; \
  T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; \
  echo -n 'MAGIC_0x00='; \$T/reg_rw /dev/xdma0_user 0x00 w 2>&1 | tail -1; \
  echo -n 'BID_0x04=';   \$T/reg_rw /dev/xdma0_user 0x04 w 2>&1 | tail -1; \
  echo -n 'UNIMPL_0x138='; \$T/reg_rw /dev/xdma0_user 0x138 w 2>&1 | tail -1; \
  echo -n 'SCRATCH_0x08='; \$T/reg_rw /dev/xdma0_user 0x08 w 2>&1 | tail -1; \
  echo -n 'CARRIER='; cat /sys/class/net/enp1s0f1np1/carrier; \
  echo -n 'IPADDR='; ip -4 addr show enp1s0f1np1 | grep -o 'inet [0-9./]*'"
echo "=== ARM_READY ${ARM} / EXPECT_BID=$EXPBID $(date +%s.%N)"
