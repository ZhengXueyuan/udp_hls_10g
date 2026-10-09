#!/bin/bash
# ls_pair_ab.sh -- P7B-LONGSEND **交错配对 A/B** (S3 负对照 vs A 被测), 本机 (Git Bash) 侧驱动
#   为什么需要它: 两臂的单跑散布极大 (S3 3.88–9.33 Gbps) ⇒ 非交错的"A 之后跑 B"会把
#   漂移读成臂差。交错设计 = 每对里两臂紧挨 (烧 S3 → 跑 → 烧 A → 跑), 3–4 对取配对差。
#   ⛔ 只走 JTAG 易失烧录; 每次烧后**现核 sha256 ↔ 板侧 BID** 两处对账。
set -u
# ⛔ 单实例锁 (2026-10-10 教训: 上一版被 TaskStop 只杀了管道、脚本本体存活 ⇒ 两个实例
#    同时抢 JTAG 与同一个 stdout 文件 ⇒ 判据读到别人的产物。两实例并行 = 证据不可归因。)
LOCK=/tmp/ls_pair_ab.lock
if [ -e "$LOCK" ]; then echo "LOCK_PRESENT ($LOCK): 已有实例在跑, 拒绝启动"; exit 9; fi
echo $$ > "$LOCK"; trap 'rm -f "$LOCK"' EXIT
ROOT=/d/repo/XCKU5PMini/udp_hls_10g
BIT_S3='D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longflow\S3\wrapper_p4.bit'
BIT_A='D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longsend\A\wrapper_p4.bit'
SUM_S3=492c35797eabed33e9ba8d529a622c287aa7d164daebeff5eb2d29655a0dc42c
SUM_A=052c52006215a2c3d5f9d59f8c47e620e41eb20f271fbc09dabfff96330bc284
PY=/c/Users/zhxue/anaconda3/python.exe
# ⚠️ 坑: python.exe 是 Windows 程序, 脚本路径必须写 **Windows 形式** (MSYS_NO_PATHCONV=1 下
#    `/d/repo/...` 不会被转换 ⇒ Python 会去找 `D:\d\repo\...` 并报 FileNotFoundError)。
SSHSCRIPT='D:/repo/XCKU5PMini/udp_hls_10g/tools/peer_ssh.py'
SSH="$PY $SSHSCRIPT"
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
OUT=$ROOT/_proj_10g/notes/p7b_longsend_board/runs
NPAIR=${NPAIR:-3}

for i in $(seq 1 $NPAIR); do
  for arm in S3 A; do
    if [ "$arm" = S3 ]; then BIT=$BIT_S3; WANT=$SUM_S3; BID=0x00000015; else BIT=$BIT_A; WANT=$SUM_A; BID=0x00000016; fi
    echo "=== PAIR $i ARM $arm $(date +%s.%N)"
    GOT=$(sha256sum "$ROOT/_proj_10g/notes/p7b_build_longflow/S3/wrapper_p4.bit" "$ROOT/_proj_10g/notes/p7b_build_longsend/A/wrapper_p4.bit" | grep -c "$WANT")
    echo "SHA_GATE arm=$arm hits=$GOT (want 1)"
    T0=$(date +%s)
    TCPREG_BIT="$BIT" cmd /c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_biz_tcpreg\run_program_tcpreg.bat' >/dev/null 2>&1
    F=$ROOT/_proj_10g/notes/p7b_biz_tcpreg/tcpreg_program_stdout.txt
    MT=$(stat -c %Y "$F")
    # ⚠️ 坑: run_program_tcpreg.bat 里 `echo TCPREG_PROG_EXIT=%ERRORLEVEL%` 在**重定向之外**
    #    ⇒ 该行只进 console, **不在** stdout 文件里 (本轮实测: 按它判 => 假红)。
    grep -q "End of startup status: HIGH" "$F" || { echo "BURN_FAIL $arm"; exit 1; }
    grep -q "TCPREG_PROG_DONE" "$F" || { echo "BURN_DONE_MISSING $arm"; exit 1; }
    grep -q "$(basename $BIT)" "$F" || { echo "BURN_BIT_MISMATCH $arm"; exit 1; }
    [ "$MT" -ge "$((T0-5))" ] || { echo "BURN_STALE_FILTEXT $arm mtime=$MT T0=$T0"; exit 1; }
    echo "BURN_OK $arm mtime=$MT T0=$T0 (HIGH+DONE+bit路径+新鲜度 四判据全过)"
    cp "$F" "$OUT/burn_${arm}_p$i.txt"
    PEER_PW=111111 $SSH --sudo "sleep 4; echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove; sleep 1; echo 1 > /sys/bus/pci/rescan; sleep 3; EXPECT_BID=$BID bash /tmp/p7b_biz/p7b_snap.sh id | grep -E 'ID_OK|ID_FAIL|ID_BID'"
    PEER_PW=111111 $SSH --sudo "cd /tmp/p7b_biz && TAG=LSAB${i}${arm} SECS=30 BID_EXPECT=$BID KW='5 43 20 51 15' SINK_EXTRA='--check lane8 --maxbytes 269484031' MAXSNAP=80 SNAPGAP=0.02 bash /tmp/p7b_biz/lf_dl.sh" > "$OUT/LSAB${i}${arm}.txt" 2>&1
    echo "RUN_DONE $arm $(grep -oE 'agg_Mbps=[0-9.]+' "$OUT/LSAB${i}${arm}.txt" | head -1)"
  done
done
echo "PAIR_AB_ALL_DONE $(date +%s.%N)"
