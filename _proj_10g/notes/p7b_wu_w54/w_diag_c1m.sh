#!/bin/bash
# W54 轮「刻意造洞」臂 (diag 版 + 强制 --chunk 1048576)。
# 机理: 旧代码每调用 fill(整 chunk) 推进图案, 而非阻塞 send() 只能收下 ~sndbuf 的字节
# (ss 实测 tb600576 / w427820) => 首发必然部分写, 洞 ~620 KB => 板侧连续 LFSR 失步。
# 用途: 负对照 (证明 W54 在 160e6 档也「有牙」, 不是因为没牙才读 0)。
M=$(md5sum /tmp/p7b_biz/p7b_tcp_src_diag | cut -d' ' -f1)
echo "WRAPPER diag_c1m diag_md5=$M chunk=1048576"
exec /tmp/p7b_biz/p7b_tcp_src_diag --chunk 1048576 "$@"
