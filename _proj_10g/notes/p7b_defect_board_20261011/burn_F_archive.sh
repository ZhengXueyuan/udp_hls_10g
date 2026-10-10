#!/bin/bash
# burn_F_archive.sh -- PETXHI-GHOST 板级轮 A (S-0): 烧【归档的】构建 F 位流 (修复前 / BID 0x1A)
#   纪律: 只走 JTAG 易失烧录 (绝不写 QSPI); 每次测量前必重烧; 只烧本目录副本
#         (burn/wrapper_p4_F_archive.bit, 由 p7b_build_archive/20261011_002044/wrapper_p4.bit 复制);
#         ⛔ 绝不碰 vivado_prj/** 的活位流。
#   判据 (五项): sha256 与归档 SHA256SUMS 值相同 + stdout 出现本次 "End of startup status: HIGH"
#                + TCPREG_PROG_DONE + 位流路径匹配 + stdout mtime 新鲜 (>= T0-5)。
#   用法: bash burn_F_archive.sh
set -u
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
OUT=$ROOT/_proj_10g/notes/p7b_defect_board_20261011
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
PY=/c/Users/zhxue/anaconda3/python.exe
SSH="$PY D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py"

ARCH_SRC=$ROOT/_proj_10g/notes/p7b_build_archive/20261011_002044/wrapper_p4.bit
WANT=89e89f31efb5f1450a1c39acfce587bb4e4b6347c5fdc2f470c91ff0d4400f45
LOCAL_BIT=$OUT/burn/wrapper_p4_F_archive.bit
BIT_WIN='D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_defect_board_20261011\burn\wrapper_p4_F_archive.bit'
BS=wrapper_p4_F_archive.bit

mkdir -p "$OUT/burn"
echo "=== COPY $(date +%s.%N)"
cp "$ARCH_SRC" "$LOCAL_BIT"
echo "--- 源 (归档) ---";      sha256sum "$ARCH_SRC"
echo "--- 副本 (烧录件) ---";  sha256sum "$LOCAL_BIT"
GOT=$(sha256sum "$LOCAL_BIT" | cut -d' ' -f1)
echo "SHA_WANT  want=$WANT"
[ "$GOT" = "$WANT" ] || { echo "SHA_MISMATCH: 副本与归档 SHA256SUMS 值不同 ⇒ 拒绝烧"; exit 1; }
echo "SHA_OK copy==archive ($GOT)"
stat -c 'LOCAL_BIT %n size=%s mtime=%y' "$LOCAL_BIT"

echo "=== 板上烧前身份 (现核 0x04; 期望 = 构建 F 0x1A)"
PEER_PW=111111 $SSH --sudo "/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools/reg_rw /dev/xdma0_user 0x04 w 2>&1 | tail -1" 2>&1

echo "=== BURN $(date +%s.%N)"
T0=$(date +%s)
TCPREG_BIT="$BIT_WIN" cmd /c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_biz_tcpreg\run_program_tcpreg.bat' >/dev/null 2>&1
F=$ROOT/_proj_10g/notes/p7b_biz_tcpreg/tcpreg_program_stdout.txt
MT=$(stat -c %Y "$F")
echo "BURN_STDOUT=$F mtime=$MT T0=$T0"
cp "$F" "$OUT/burn/BURN_F_archive_$(date +%Y%m%d_%H%M%S).txt"
echo "--- burn stdout (关键行逐字) ---"
grep -E "TCPREG_BIT =|TCPREG_BIT_EXISTS|TCPREG_BIT_MTIME|End of startup status|TCPREG_PROG_DONE|TCPREG-ABORT|TCPREG_PROG device" "$F"
echo "--- end ---"
grep -q "End of startup status: HIGH" "$F" || { echo "BURN_FAIL (无 HIGH)"; exit 1; }
grep -q "TCPREG_PROG_DONE" "$F" || { echo "BURN_FAIL (无 DONE)"; exit 1; }
grep -q "$BS" "$F" || { echo "BURN_FAIL (位流路径不匹配: 期望含 $BS)"; exit 1; }
[ "$MT" -ge "$((T0-5))" ] || { echo "BURN_FAIL (stdout 陈旧)"; exit 1; }
echo "BURN_OK (HIGH+DONE+bit路径+新鲜度 四判据全过)"

echo "=== RESCAN $(date +%s.%N)"
PEER_PW=111111 $SSH --sudo "sh -c 'echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove; sleep 1; echo 1 > /sys/bus/pci/rescan'; sleep 3; echo '--- lspci ---'; lspci -s 02:00.0; lspci -vvv -s 02:00.0 2>/dev/null | grep -E 'LnkSta:|Region 0|Region 1'; echo '--- dev ---'; ls -la /dev/xdma0_user" 2>&1

echo "=== ID $(date +%s.%N)"
PEER_PW=111111 $SSH --sudo "EXPECT_BID=0x0000001A NW=70 bash /tmp/p7b_biz/p7b_snap.sh id; echo ID_RC=\$?; \
  T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools; \
  echo -n 'SCRATCH_0x08='; \$T/reg_rw /dev/xdma0_user 0x08 w 2>&1 | tail -1; \
  echo -n 'CARRIER='; cat /sys/class/net/enp1s0f1np1/carrier; \
  echo -n 'ABORTCNT_0x94='; \$T/reg_rw /dev/xdma0_user 0x94 w 2>&1 | tail -1" 2>&1 | tee "$OUT/burn/id_F_archive_$(date +%Y%m%d_%H%M%S).txt"
echo "=== ARM_READY F/0x1A $(date +%s.%N)"
