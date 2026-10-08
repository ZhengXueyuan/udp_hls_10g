#!/bin/bash
# pcap_off_dryrun.sh -- ⭐ 2026-10-09 三台架脚本的 **"默认不写盘" 门** (不碰板子, 不碰 10G 口)
#
# 为什么有它: 用户 2026-10-09 要求"收发数据不许落在硬盘上, 防止 IO 瓶颈"。台架上**唯一**的
# 落盘路径 = `tcpdump -w` (三条脚本原来都无条件抓)。改动后必须有一条**能同时翻红**的门:
#   臂 A (默认, PCAP_ON 未设): 必须 `PCAP_ACTIVE=0` + **tcpdump 从未被调用** + **没有新 pcap 文件**
#   臂 B (PCAP_ON=1)          : 必须 `PCAP_ACTIVE=1 IO_AFFECTING=1` + tcpdump **恰好被调用一次**
#                               + **pcap 文件真的出现** (否则"能抓"这条能力被改坏了)
# ⇒ 两臂**互为反例**: 只测臂 A 的门在"忘了写抓包分支"的设计上也全绿 (空判据)。
#
# 手法: 把 `tcpdump` / `ethtool` / `reg_rw` / `p7b_snap.sh` 全部换成**桩件** (自带, 写在 $TMP 里),
#   其中 tcpdump 桩件会把"自己被调用"记进一个文件 —— 该文件就是臂 A 的判据物。
#   ⛔ 全程不碰板子 (桩件代替所有硬件访问)、不碰 10G 口。
#
# 用法 (对端机): bash pcap_off_dryrun.sh            # 需 /tmp/p7b_biz 存在 (部署目录; 脚本自己 cd 它)
#   env:  D=/tmp/p7b_biz (部署目录)  TMP=$(mktemp -d) (桩件目录, 默认自动建)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
D=${D:-/tmp/p7b_biz}
TMP=${TMP:-$(mktemp -d /tmp/pcapoff.XXXXXX)}
mkdir -p "$TMP/stubbin" "$TMP/tools"
PASS=0; FAIL=0
ck(){ if [ "$2" = "$3" ]; then echo "  [PASS] $1 = $2"; PASS=$((PASS+1));
      else echo "  [FAIL] $1 got='$2' want='$3'"; FAIL=$((FAIL+1)); fi; }

[ -d "$D" ] || { echo "PRECHECK_FAIL 部署目录 $D 不存在 (三脚本里有 `cd $D`; 先把脚本部署过去)"; exit 3; }
cp -f "$HERE/stc_dl.sh" "$HERE/j6_stagec.sh" "$D/" 2>/dev/null
cp -f "$HERE/../p7b_biz_tcpreg/tcpreg_j6.sh" "$D/" 2>/dev/null

# ---------------- 桩件 ----------------
cat > "$TMP/tools/reg_rw" <<'EOS'
#!/bin/bash
case "${2:-}" in
  0x04) echo "0x04: ${BID_STUB:-0x0000000a}" ;;
  0x00) echo "0x00: 0x50360001" ;;
  0x14) echo "0x14: 0xdeadbeef" ;;
  *)    echo "${2:-0x??}: 0x00000001" ;;
esac
EOS
cat > "$TMP/p7b_snap_stub.sh" <<'EOS'
#!/bin/bash
# p7b_snap 桩件: 行格式与真件逐字相同 (W<字> <地址> <名字> 0x..); 数值可独立复算
set -u
case "${1:-}" in
  id) echo "ID_MAGIC 0x50360001   (want 0x50360001)"; echo "ID_BID   0x0000000a"
      echo "ID_MARKER 0xdeadbeef"; echo "ID_UNIMPL 0xffffffff"; echo "ID_OK $(date +%s.%N)";;
  full) echo "SNAP_BEGIN ${2:-FULL} gen=1"
        printf 'W%-3s %-6s %-22s %s\n' 20 0x70 mac_tx_frames 0x00001000
        echo "SNAP_END ${2:-FULL} nff=0";;
  snap) tag="${2:-SNAP}"; shift 2
        echo "SNAP_BEGIN $tag gen=1"
        case "$tag" in *_t0) o5=$((0x00200000)); o20=$((0x00001000)); o43=$((0x00200000)); o53=$((0x00010000));;
                       *)    o5=$((0x00200000+1562500)); o20=$((0x00001000+1000)); o43=$((0x00200000+193000)); o53=$((0x00010000+1460000));;
        esac
        for w in "$@"; do
          case "$w" in 5) v=$o5;; 20) v=$o20;; 43) v=$o43;; 53) v=$o53;; *) v=0;; esac
          printf 'W%-3s %-6s %-22s %s\n' "$w" 0x0 stub_word "$(printf '0x%08x' "$v")"
        done
        echo "SNAP_END $tag nff=0";;
  *) echo "SNAP_STUB_USAGE";;
esac
EOS
cat > "$TMP/stubbin/tcpdump" <<'EOS'
#!/bin/bash
# tcpdump 桩件: **记录自己被调用** (臂 A 的判据物: 该文件必须为空/不存在)
echo "TCPDUMP_CALLED $(date +%s.%N) argv: $*" >> "${TCPDUMP_CALLS:-/tmp/pcapoff_calls.log}"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-w" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && echo "stub-pcap" > "$out"
sleep 8
EOS
cat > "$TMP/stubbin/ethtool" <<'EOS'
#!/bin/bash
# ethtool 桩件: 第 n 次调用给第 n 档计数 ⇒ Δbytes/Δpkts 可独立复算 (1000 包 × 1518 B)
n=$(cat "${ETHTOOL_CALLS:-/tmp/pcapoff_eth_calls}" 2>/dev/null || echo 0); n=$((n+1))
echo "$n" > "${ETHTOOL_CALLS:-/tmp/pcapoff_eth_calls}"
printf '     port_rx_good_bytes: %d\n' $((1518000*n))
printf '     port_rx_packets: %d\n'     $((1000*n))
printf '     port_tx_bytes: %d\n'       $((500000*n))
printf '     port_tx_packets: %d\n'     $((300*n))
EOS
chmod +x "$TMP/tools/reg_rw" "$TMP/p7b_snap_stub.sh" "$TMP/stubbin/tcpdump" "$TMP/stubbin/ethtool"
export P7B_TOOLS="$TMP/tools" P7B_SNAP="$TMP/p7b_snap_stub.sh" TCPDUMP_CALLS="$TMP/tcpdump_calls.log"
export ETHTOOL_CALLS="$TMP/eth_calls" PATH="$TMP/stubbin:$PATH"

arm(){  # arm <脚本> <tag> <PCAP_ON(空 = 真的不设这个变量)> <env...>
  local scr="$1" tag="$2" pon="$3"; shift 3
  [ -f "$D/$scr" ] || { echo "  [FAIL] 找不到 $D/$scr"; FAIL=$((FAIL+1)); return; }
  rm -f "$TCPDUMP_CALLS" "$ETHTOOL_CALLS"
  local e=(TAG="$tag"); [ -n "$pon" ] && e+=("PCAP_ON=$pon")
  env "${e[@]}" "$@" bash "$D/$scr" >"$TMP/out_$tag.txt" 2>&1
  echo "  [INFO] $scr PCAP_ON='$pon' RC=$? (输出 $TMP/out_$tag.txt)"
}
arms(){ # arms <A|B> <PCAP_ON>  —— 同一个循环跑两个臂 (确保两臂**逐字对称**, 差异只有 PCAP_ON)
  local k="$1" pon="$2" s o
  for s in stc_dl.sh j6_stagec.sh tcpreg_j6.sh; do
    rm -f /tmp/tcpreg.pcap "/tmp/${k}_$s.pcap"
    case "$s" in
      stc_dl.sh)    arm "$s" "${k}_$s" "$pon" SECS=2 CONNS=1 SINK=/bin/true;;
      tcpreg_j6.sh) arm "$s" "${k}_$s" "$pon" BIN=/bin/true EXPECT_BID=0x00000009 BID_STUB=0x00000009;;
      *)            arm "$s" "${k}_$s" "$pon" BIN=/bin/true;;
    esac
    o="$TMP/out_${k}_$s.txt"
    if [ "$k" = "A" ]; then
      ck "A/$s 醒目标记行 'PCAP_ACTIVE=0 IO_AFFECTING=0'" "$(grep -c '^PCAP_ACTIVE=0 IO_AFFECTING=0' "$o")" "1"
      ck "A/$s 元数据块也记了 IO_AFFECTING=0" "$(grep -c 'META_IO_AFFECTING=0' "$o")" "1"
      ck "A/$s tcpdump 一次都没被调用 (判据物 = 桩件日志)" "$( [ -e "$TCPDUMP_CALLS" ] && wc -l < "$TCPDUMP_CALLS" || echo 0 )" "0"
      ck "A/$s 没有 pcap 文件 (默认路径 + TAG 路径都不许有)" "$( ls /tmp/tcpreg.pcap "/tmp/${k}_$s.pcap" 2>/dev/null | wc -l )" "0"
    else
      ck "B/$s PCAP_ACTIVE=1 IO_AFFECTING=1 标记" "$(grep -c '^PCAP_ACTIVE=1 IO_AFFECTING=1' "$o")" "1"
      ck "B/$s tcpdump 恰好被调用 1 次" "$( [ -e "$TCPDUMP_CALLS" ] && wc -l < "$TCPDUMP_CALLS" || echo 0 )" "1"
      ck "B/$s pcap 文件真的出现 (抓包能力没被改坏)" "$( ls /tmp/tcpreg.pcap "/tmp/${k}_$s.pcap" 2>/dev/null | wc -l )" "1"
    fi
    ck "$k/$s GEOM_NOPCAP 行数 (不抓包也有几何口径)" "$(grep -c '^GEOM_NOPCAP_' "$o")" \
       "$([ "$s" = "stc_dl.sh" ] && echo 2 || echo 3)"
    rm -f /tmp/tcpreg.pcap "/tmp/${k}_$s.pcap"
  done
}

echo "===== 臂 A = 默认 (PCAP_ON **未设**) ====="; arms A ""
echo "===== 臂 B = PCAP_ON=1 (抓包能力必须还在) ====="; arms B 1

echo
echo "PCAPOFF_SUMMARY PASS=$PASS FAIL=$FAIL   (桩件目录 $TMP)"
[ "$FAIL" -eq 0 ] && echo "PCAPOFF_OK" || echo "PCAPOFF_BAD"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
