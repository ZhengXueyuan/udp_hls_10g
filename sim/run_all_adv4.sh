#!/bin/bash
S=/d/repo/ECO/udp_hls_10g/sim
for c in dbg wnd fin abort evfifo reconn_fast reconn_slow multi len b2b findrop; do
  bash $S/adv_run4.sh $c
  sleep 3
done
echo "ADV ALL DONE"
