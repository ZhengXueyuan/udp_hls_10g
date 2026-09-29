#!/bin/bash
#=============================================================================
# soak_postcheck.sh -- follow-up on the P6b FINAL bitstream AFTER the 96-min soak:
#   (1) precise W24 (dp_free) frequency with nanosecond wall clock  -> positive
#       evidence that the datapath is really running on its MMCM clock;
#   (2) a CLEAN quiescent-state check (retried until FROZEN, up to N attempts):
#       traffic stopped, in-flight frames drained, conservation laws on the frozen state;
#   (3) re-read the health words W17/W19/W21/W32..W35 to confirm they are still zero.
#   New file; modifies no existing script.  Read-only w.r.t. the board (only the
#   0x18 snapshot trigger is written, same as the soak probe).
#=============================================================================
set -u
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user
W32=$((1<<32))
rd(){ local v; v=$($TOOLS/reg_rw $D "$1" w 2>/dev/null | grep -oE '0x[0-9a-fA-F]+' | tail -1); [ -n "$v" ] || return 1; echo "$v"; }
GEN=0
snap(){ local g0 g1 s i
        g0=$(rd 0x1c) || return 1; g0=$(( (g0 >> 16) & 0xffff ))
        $TOOLS/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1
        for i in $(seq 1 100); do s=$(rd 0x1c) || continue
            [ $(( s & 2 )) -ne 0 ] && break; sleep 0.01; done
        g1=$(rd 0x1c) || return 1; g1=$(( (g1 >> 16) & 0xffff ))
        GEN=$g1
        [ $(( (g1 - g0) & 0xffff )) -eq 1 ]; }
declare -a W
readall(){ local a i v; for i in $(seq 0 35); do
             a=$(printf '0x%x' $((0x20 + 4*i)))
             v=$(rd "$a") || return 1
             W[$i]=$(( v )); done; return 0; }

echo "=== soak_postcheck $(date '+%F %T') ==="
echo "IDENT: MAGIC=$(rd 0x00) BUILD_ID=$(rd 0x04) 0xB0=$(rd 0xb0)"

echo
echo "--- (1) W24 dp_free frequency, ns-precision wall clock, two trigger->read ends ---"
snap || { echo "snap A failed"; exit 1; }; readall || { echo "readall A failed"; exit 1; }
A=${W[24]}; TA=$(date +%s.%N)
sleep 10
snap || { echo "snap B failed"; exit 1; }; readall || { echo "readall B failed"; exit 1; }
B=${W[24]}; TB=$(date +%s.%N)
DT=$(awk -v a="$TA" -v b="$TB" 'BEGIN{printf "%.9f", b-a}')
DW=$(( (B - A) % W32 )); [ "$DW" -lt 0 ] && DW=$((DW+W32))
echo "  A(W24)=$A  B(W24)=$B  dW=$DW  dt=${DT}s"
awk -v d="$DW" -v t="$DT" 'BEGIN{printf "  => dp clock = %.4f MHz  (window %.3f s, < 27.49 s wrap period)\n", d/t/1e6, t}'

echo
echo "--- (2) clean quiescent-state check (retry until FROZEN) ---"
ok=0
for att in 1 2 3 4 5 6; do
    sleep 0.5
    snap || continue; readall || continue
    declare -a A2; A2=( "${W[@]}" )
    sleep 0.5
    snap || continue; readall || continue
    declare -a B2; B2=( "${W[@]}" )
    chg=""
    for i in 0 1 6 7 16 30 31 18 19 20 21 32 33 34 35; do
        [ "${A2[$i]}" != "${B2[$i]}" ] && chg="$chg W$i(${A2[$i]}->${B2[$i]})"
    done
    c1=$(( (A2[30] - A2[0] - A2[32]) % W32 ))
    c2=$(( (A2[31] - (A2[1] - 4*A2[0] + A2[33])) % W32 ))
    if [ -z "$chg" ]; then
        echo "  attempt $att: FROZEN (in-flight frames drained, no background traffic)"
        echo "  W0=${A2[0]} W1=${A2[1]} W30=${A2[30]} W31=${A2[31]} W32=${A2[32]} W33=${A2[33]}"
        echo "  conservation: W30-W0-W32 = $c1 (want 0)   W31-(W1-4*W0+W33) = $c2 (want 0)"
        echo "  raw difference W1-W31 = $((A2[1]-A2[31]))  (= 4*W0 - W33 = $((4*A2[0]-A2[33])))"
        ok=1; break
    else
        echo "  attempt $att: MOVING:$chg  (background frame arrived; retrying)"
    fi
done
[ "$ok" = 0 ] && echo "  !! never reached a frozen window in 6 attempts"

echo
echo "--- (3) health words on the LAST snapshot (gen=$GEN) ---"
snap || echo "  snap failed"; readall || echo "  readall failed"
for i in 17 18 19 21 32 33 34 35 3 4 25; do printf "  W%-2d = %d\n" "$i" "${W[$i]}"; done
echo "POSTCHECK_DONE"
