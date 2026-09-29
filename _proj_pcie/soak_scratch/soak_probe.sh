#!/bin/bash
#=============================================================================
# soak_probe.sh -- P6b FINAL bitstream (BUILD_ID=6, 36-word window) long soak:
#                  try to CATCH the "slow path goes deaf" phenomenon.
#
#   现象 (历史上两次, 均为 BUILD_ID=3 / 16-word 窗口时代; 两次都在配置后约 20 秒;
#         表现为帧到了慢路径 W6 涨, 但 HLS 一个包不回 W7 不动, ping 也不通; 约 20 分钟自愈):
#     that era had NO W19 (adapter drop) / W21 (MAC TX abort) / W32-W35 (F4 conservation
#     words) -- so the two defects discovered later could not be excluded from the
#     explanation.  This run uses the FINAL bitstream, where all of them exist.
#
#   Usage: sudo bash soak_probe.sh [dense_secs] [dense_iv] [loose_iv] [total_secs]
#          default: 600 5 20 5760   (~96 min; first 10 min sampled every 5 s)
#   Logs: /tmp/soak_probe.log     (tee'd human+machine lines)
#         /tmp/soak_words.tsv     (per-round 36 words, machine readable)
#         /tmp/soak_stdout.log    (raw stdout, for nohup)
#
#   DISCIPLINE (do not "simplify"):
#     * empty read != real 0 : rd() returns non-zero on failure; a failed read voids
#       the WHOLE round (printed INVALID, never silently coerced to 0).
#     * snap() self-check: gen must advance by EXACTLY +1 (catches generation
#       confusion when a second writer exists) -- copied in spirit from
#       _proj_pcie/p6e_slowpath_probe.sh, NOT simplified.
#     * unimplemented address = 0xB0 -> 0xffffffff (SKIP semantics, never PASS).
#       Never pick a criterion address >= 0x100: axi_regs ar_word = araddr[7:2] is only
#       6 bits => addresses alias/wrap every 256 bytes.
#     * W17 (hls_rst_n low cycles) divides by **80** (P6b changed RST_CNT 64 -> 80).
#     * W24 (dp_free) is a SNAPSHOT word: reading 0x80 twice back-to-back returns the
#       SAME frozen value.  A frequency needs "trigger -> read" at BOTH ends, and a
#       window < 20 s (32-bit @156.25MHz wraps every 27.49 s).
#=============================================================================
set -u
DENSE_SECS=${1:-600}
DENSE_IV=${2:-5}
LOOSE_IV=${3:-20}
TOTAL_SECS=${4:-5760}
IFACE=enp3s0
BOARD=192.168.100.2
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
LOG=/tmp/soak_probe.log
WTSV=/tmp/soak_words.tsv
MAGIC_EXP=0x50360001
BID_EXP=0x00000006
PING_N=5
PING_IV=0.2   # -i 0.2 so 5 pings fit inside a 5 s sampling tick (keeps dense cadence)
W32=$((1<<32))
exec > >(tee -a "$LOG") 2>&1

# rd(): read one word; FAILURE RETURNS NON-ZERO (an empty read must never look like 0)
rd(){ local v; v=$($TOOLS/reg_rw $D "$1" w 2>/dev/null | grep -oE '0x[0-9a-fA-F]+' | tail -1); [ -n "$v" ] || return 1; echo "$v"; }

# snap(): write 0x18=1, poll done, then prove **gen advanced by exactly +1**.
#   done is sticky => it only proves "finished at least once", not "this generation is
#   mine".  The gen==+1 check is what catches a concurrent writer.
GEN=0
snap(){ local g0 g1 s i
        g0=$(rd 0x1c) || return 1; g0=$(( (g0 >> 16) & 0xffff ))
        $TOOLS/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1
        for i in $(seq 1 100); do s=$(rd 0x1c) || continue
            [ $(( s & 2 )) -ne 0 ] && break; sleep 0.01; done
        g1=$(rd 0x1c) || return 1; g1=$(( (g1 >> 16) & 0xffff ))
        GEN=$g1
        [ $(( (g1 - g0) & 0xffff )) -eq 1 ]; }

# readall(): read all 36 words W0..W35 (0x20..0xAC).  Any empty read voids the round.
declare -a W
readall(){ local a i v; for i in $(seq 0 35); do
             a=$(printf '0x%x' $((0x20 + 4*i)))
             v=$(rd "$a") || return 1
             W[$i]=$(( v )); done; return 0; }

dd(){ local d=$(( ($2 - $1) % W32 )); echo $(( d < 0 ? d + W32 : d )); }
hex(){ printf '0x%08x' $(( $1 )); }

# host-side preconditions, rechecked EVERY round
#   (so "I never sent it" can never be misread as "the board never answered")
prep(){
    ip -br addr show "$IFACE" 2>/dev/null | grep -q "192.168.100.1" || {
        ip link set "$IFACE" up 2>/dev/null
        ip addr add 192.168.100.1/24 dev "$IFACE" 2>/dev/null && echo "[setup] re-added 192.168.100.1/24"
    }
    ROUTE=$(ip route get "$BOARD" 2>/dev/null | head -1 | grep -c "$IFACE")
    ARP=$(arp -n 2>/dev/null | grep -c "$BOARD")
}

# ---------- quiescent-state check (traffic stopped: in-flight frames must drain) ----------
#   Wait >=13us (drain) and <4s (avoid the HLS HELLO period) with no traffic, then take TWO
#   snapshots and require every traffic-related word to be frozen between them.
#   Also evaluate the structural conservation laws on the frozen state.
stopcheck(){ local tag="$1" i a b badc=0
    sleep 0.5
    snap || { echo "  [stopcheck $tag] snap A failed"; return; }
    readall || { echo "  [stopcheck $tag] readall A failed (empty read)"; return; }
    declare -a A; A=( "${W[@]}" )
    sleep 0.5
    snap || { echo "  [stopcheck $tag] snap B failed"; return; }
    readall || { echo "  [stopcheck $tag] readall B failed (empty read)"; return; }
    declare -a B; B=( "${W[@]}" )
    local chg=""
    # W5/W24 are free-running counters -> legitimately change; everything below must freeze
    for i in 0 1 6 7 16 30 31 18 19 20 21 32 33 34 35; do
        if [ "${A[$i]}" != "${B[$i]}" ]; then chg="$chg W$i(${A[$i]}->${B[$i]})"; badc=1; fi
    done
    local c1=$(( (A[30] - A[0] - A[32]) % W32 ))
    local c2=$(( (A[31] - (A[1] - 4*A[0] + A[33])) % W32 ))
    echo "  [stopcheck $tag] quiescent check: $([ $badc -eq 0 ] && echo 'FROZEN (in-flight frames drained)' || echo "MOVING:$chg")"
    echo "  [stopcheck $tag] A: W0=${A[0]} W1=${A[1]} W30=${A[30]} W31=${A[31]} W32=${A[32]} W33=${A[33]}"
    echo "  [stopcheck $tag] conservation on frozen state: W30-W0-W32=$c1 (want 0) ; W31-(W1-4*W0+W33)=$c2 (want 0)"
    echo "  [stopcheck $tag] (note: W1==W31 is mathematically impossible when W0>0 -- W31 is the"
    echo "  [stopcheck $tag]  Sum-popcount byte view and excludes the 4B per-frame FCS; use W31==W1-4*W0+W33.)"
}

echo "########## soak_probe  $(date '+%F %T') ##########"
echo "params: dense=${DENSE_SECS}s/${DENSE_IV}s  loose=${LOOSE_IV}s  total=${TOTAL_SECS}s  ping=-c ${PING_N} -W 1 -i ${PING_IV}"
for i in $(seq 1 45); do lspci -n 2>/dev/null | grep -q '10ee:9034' && break; sleep 2; done
lsmod | grep -qw xdma || { insmod /home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/xdma/xdma.ko; sleep 2; }
[ -e $D ] || { echo "FATAL: $D missing => observation channel unusable"; exit 1; }

M=$(rd 0x00) || M=""
B=$(rd 0x04) || B=""
MARK=$(rd 0x14) || MARK=""
UB=$(rd 0xb0) || UB=""
echo "IDENT: MAGIC=$(hex $((M))) (want 0x50360001) | BUILD_ID=$(hex $((B))) (want 0x00000006) | MARKER=$MARK | 0xB0(unimpl)=$UB"
if [ "$((UB))" = "$((0xffffffff))" ]; then echo "GATE: 0xB0 -> 0xffffffff => 'unimplemented word = SKIP, never PASS' holds"; else echo "GATE: WARN 0xB0 = $UB (expected 0xffffffff)"; fi
if [ "$((M))" != "$((MAGIC_EXP))" ]; then echo "FATAL: MAGIC mismatch => wrong bitstream or dead channel"; exit 1; fi
if [ "$((B))" != "$((BID_EXP))" ]; then echo "FATAL: BUILD_ID mismatch => wrong bitstream"; exit 1; fi
echo "GATE: identity OK (BUILD_ID=6 = 36-word window + F-1/F-2 fixes)"
echo "W#MAP: 0 rx_frames|1 rx_bytes|3 fcs_err|5 gmii_free|6 srx_commit|7 stx_frames|13 udpapp_mismatch"
echo "       16 srx_hls_bytes|17 hr_cnt(/80)|18 stx_purge|19 srx_drop|20 mac_tx_frames|21 tx_abort"
echo "       24 dp_free|25 mmcm_locked|26 rxcdc_full|27 rxcdc_occ_max|28 txcdc_occ_max|29 txwire_stall"
echo "       30 rxcdc_out_frames|31 rxcdc_out_bytes|32 drop_partial|33 orphan_bytes|34 drop_full|35 fifo_ovf"
: > "$WTSV"
printf "t\tgen\t%s\n" "$(seq -f 'W%g' 0 35 | tr '\n' '\t')" >> "$WTSV"

T0=$(date +%s)
PREV0=""; PREV6=""; PREV7=""; PREV1=""; PREV16=""
PREVRX=$(cat /sys/class/net/$IFACE/statistics/rx_packets)
PREV_PING=""
FIRST_DEAF=""; DEAF_ROUND=0
R=0; HAVE_PREV=0
MAXW17=0; MAXW19=0; MAXW21=0; MAXW35=0; MAXW32=0; MAXW33=0; MAXW34=0; MAXW18=0
NZ_W17=0; NZ_W19=0; NZ_W21=0; NZ_W35=0; NZ_W32=0; NZ_W34=0
CONS1_BAD=0; CONS2_BAD=0; INVALID=0
LAST_W24=""; LAST_W24_T=""
PING_MIN=99
STOP1=$(( DENSE_SECS / 5 ))     # first quiescent check: ~2 min in
STOP2=$(( DENSE_SECS / 2 ))     # second: ~5 min in
DID1=0; DID2=0

echo
echo "cols: t | ping | arp | rt | W0 | dW0 | W6 | dW6 | W7 | dW7 | W1 | dW1 | W16 | dW16 | W17 | dW17 | W18 | W19 | W20 | W21 | W24MHz | dW32 | dW33 | dW34 | dW35 | cons1 | cons2 | NICdRX"
while : ; do
    TS=$(( $(date +%s) - T0 ))
    [ "$TS" -ge "$TOTAL_SECS" ] && break
    R=$((R+1))
    prep
    GOT=$(ping -c $PING_N -W 1 -i $PING_IV "$BOARD" 2>/dev/null | grep -oE '[0-9]+ received' | grep -oE '[0-9]+')
    GOT=${GOT:-0}
    [ "$GOT" -lt "$PING_MIN" ] && PING_MIN=$GOT
    # self-certification: MAGIC + gen==+1 + all 36 words read non-empty
    OK=1
    MM=$(rd 0x00) || MM=""
    [ "$MM" = "$(hex $MAGIC_EXP)" ] || OK=0
    snap || OK=0
    readall || OK=0
    if [ "$OK" != 1 ]; then
        INVALID=$((INVALID+1))
        printf "%5d | %2s/%2d | INVALID ROUND (MAGIC=%s snap/gen self-check or empty read) => ALL COLUMNS VOID\n" "$TS" "$GOT" "$PING_N" "${MM:-readfail}"
        PREV_PING=$GOT
        sleep "$DENSE_IV"; continue
    fi
    RX=$(cat /sys/class/net/$IFACE/statistics/rx_packets)
    C1=$(( (W[30] - W[0] - W[32]) % W32 ))
    C2=$(( (W[31] - (W[1] - 4*W[0] + W[33])) % W32 ))
    [ "$C1" -ne 0 ] && CONS1_BAD=$((CONS1_BAD+1))
    [ "$C2" -ne 0 ] && CONS2_BAD=$((CONS2_BAD+1))
    # W24 frequency: "trigger -> read" at BOTH ends (never a straight read)
    W24M="--"
    if [ -n "$LAST_W24" ]; then
        DT=$(( TS - LAST_W24_T ))
        if [ "$DT" -gt 0 ]; then
            DW24=$(dd "$LAST_W24" "${W[24]}")
            if [ "$DT" -lt 20 ]; then W24M=$(awk -v d="$DW24" -v t="$DT" 'BEGIN{printf "%.2f", d/t/1e6}')
            else W24M=$(awk -v d="$DW24" -v t="$DT" 'BEGIN{printf "%.2f*", d/t/1e6}'); fi
        fi
    fi
    LAST_W24=${W[24]}; LAST_W24_T=$TS
    if [ "$HAVE_PREV" = 1 ]; then
      dW0=$(dd $PREV0 ${W[0]}); dW6=$(dd $PREV6 ${W[6]}); dW7=$(dd $PREV7 ${W[7]})
      dW1=$(dd $PREV1 ${W[1]}); dW16=$(dd $PREV16 ${W[16]}); dRX=$(dd $PREVRX $RX)
    else
      dW0=0; dW6=0; dW7=0; dW1=0; dW16=0; dRX=0
    fi
    dW32=$(dd "${PREVW32:-${W[32]}}" "${W[32]}")
    dW33=$(dd "${PREVW33:-${W[33]}}" "${W[33]}")
    dW34=$(dd "${PREVW34:-${W[34]}}" "${W[34]}")
    dW35=$(dd "${PREVW35:-${W[35]}}" "${W[35]}")
    if [ "$HAVE_PREV" = 1 ]; then dW17=$(dd $PREV17 ${W[17]}); else dW17=0; fi
    printf "%5d | %2s/%2d | %2s | %2s | %10d | %5d | %8d | %5d | %8d | %5d | %10d | %6d | %10d | %6d | %10d | %5d | %5d | %5d | %8d | %5d | %8s | %6d | %5d | %5d | %5d | %5d | %5d | %6d\n" \
        "$TS" "$GOT" "$PING_N" "$ARP" "$ROUTE" \
        "${W[0]}" "$dW0" "${W[6]}" "$dW6" "${W[7]}" "$dW7" "${W[1]}" "$dW1" \
        "${W[16]}" "$dW16" "${W[17]}" "$dW17" "${W[18]}" "${W[19]}" "${W[20]}" "${W[21]}" \
        "$W24M" "$dW32" "$dW33" "$dW34" "$dW35" "$C1" "$C2" "$dRX"
    { printf "%s\t%s\t" "$TS" "$GEN"; for i in $(seq 0 35); do printf "%s\t" "${W[$i]}"; done; printf "\n"; } >> "$WTSV"
    # maxima / ever-nonzero bookkeeping
    [ "${W[17]}" -gt "$MAXW17" ] && MAXW17=${W[17]}
    [ "${W[19]}" -gt "$MAXW19" ] && MAXW19=${W[19]}
    [ "${W[21]}" -gt "$MAXW21" ] && MAXW21=${W[21]}
    [ "${W[35]}" -gt "$MAXW35" ] && MAXW35=${W[35]}
    [ "${W[32]}" -gt "$MAXW32" ] && MAXW32=${W[32]}
    [ "${W[33]}" -gt "$MAXW33" ] && MAXW33=${W[33]}
    [ "${W[34]}" -gt "$MAXW34" ] && MAXW34=${W[34]}
    [ "${W[18]}" -gt "$MAXW18" ] && MAXW18=${W[18]}
    [ "${W[17]}" -ne 0 ] && NZ_W17=$((NZ_W17+1))
    [ "${W[19]}" -ne 0 ] && NZ_W19=$((NZ_W19+1))
    [ "${W[21]}" -ne 0 ] && NZ_W21=$((NZ_W21+1))
    [ "${W[35]}" -ne 0 ] && NZ_W35=$((NZ_W35+1))
    [ "${W[32]}" -ne 0 ] && NZ_W32=$((NZ_W32+1))
    [ "${W[34]}" -ne 0 ] && NZ_W34=$((NZ_W34+1))
    # ---- DEAFNESS SIGNATURE: frames reach the slow path (dW6>0) but the HLS emits
    #      nothing (dW7=0), AND ping flipped working -> not-working => REPRODUCTION ----
    if [ "$HAVE_PREV" = 1 ] && [ "$dW6" -gt 0 ] && [ "$dW7" -eq 0 ]; then
        if [ "$GOT" = "0" ] && [ -n "$PREV_PING" ] && [ "$PREV_PING" != "0" ]; then
            if [ -z "$FIRST_DEAF" ]; then
                FIRST_DEAF=$TS; DEAF_ROUND=$R
                echo "  *** REPRODUCTION SIGNATURE at t=${TS}s (round $R): dW6=$dW6 dW7=0, ping $PREV_PING -> 0 ***"
                echo "  *** FULL 36 WORDS, verbatim (this round, gen=$GEN): ***"
                for i in $(seq 0 35); do printf "      W%-2d = %10d (0x%08x)\n" "$i" "${W[$i]}" "${W[$i]}"; done
                echo "  *** 4 s packet capture (ground truth): ***"
                timeout 4 tcpdump -i "$IFACE" -n -e -c 40 arp or icmp 2>/dev/null | sed 's/^/     /'
                echo "  *** NO reboot / NO reprogram from here on -- preserve the scene ***"
            else
                echo "  (deaf signature repeats at t=${TS}s round $R: dW6=$dW6 dW7=$dW7 ping=$GOT)"
                for i in $(seq 0 35); do printf "      W%-2d = %10d\n" "$i" "${W[$i]}"; done
            fi
        else
            echo "  (weak signal t=${TS}s round $R: dW6=$dW6 dW7=$dW7 but ping=$GOT/$PING_N still ok)"
        fi
    fi
    PREV0=${W[0]}; PREV6=${W[6]}; PREV7=${W[7]}; PREV1=${W[1]}; PREV16=${W[16]}
    PREV17=${W[17]}; PREVW32=${W[32]}; PREVW33=${W[33]}; PREVW34=${W[34]}; PREVW35=${W[35]}
    PREVRX=$RX; PREV_PING=$GOT; HAVE_PREV=1
    if [ "$DID1" = 0 ] && [ "$TS" -ge "$STOP1" ]; then DID1=1; stopcheck "1"; fi
    if [ "$DID2" = 0 ] && [ "$TS" -ge "$STOP2" ]; then DID2=1; stopcheck "2"; fi
    if [ "$TS" -lt "$DENSE_SECS" ]; then sleep "$DENSE_IV"; else sleep "$LOOSE_IV"; fi
done

echo
echo "########## soak_probe END $(date '+%F %T') ##########"
echo "rounds=$R invalid_rounds=$INVALID elapsed=$(( $(date +%s) - T0 ))s first_deaf=${FIRST_DEAF:-none} (round ${DEAF_ROUND:-n/a})"
echo "min ping received/round = $PING_MIN / $PING_N"
echo "EVER-NONZERO rounds: W17=$NZ_W17 W19=$NZ_W19 W21=$NZ_W21 W32=$NZ_W32 W34=$NZ_W34 W35=$NZ_W35"
echo "MAX values: W17=$MAXW17 W18=$MAXW18 W19=$MAXW19 W21=$MAXW21 W32=$MAXW32 W33=$MAXW33 W34=$MAXW34 W35=$MAXW35"
echo "CONSERVATION violation rounds: W30==W0+W32 bad=$CONS1_BAD ; W31==W1-4*W0+W33 bad=$CONS2_BAD"
echo "words file: $WTSV"
echo "SOAK_DONE"
