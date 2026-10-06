#!/bin/bash
# W54 轮「刻意造洞」臂的 fix 对照 (fix 版 + 同一 --chunk 1048576)。
# 预期: partial_sends>0 但 ΔW54=0 (与 diag 同锤不同命)。
M=$(md5sum /tmp/p7b_biz/p7b_tcp_src_fix | cut -d' ' -f1)
echo "WRAPPER fix_c1m fix_md5=$M chunk=1048576"
exec /tmp/p7b_biz/p7b_tcp_src_fix --chunk 1048576 "$@"
