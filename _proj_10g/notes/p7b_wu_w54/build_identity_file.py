#!/usr/bin/env python3
"""build_identity_file.py -- 把对端原始 stdout (ASCII) + 中文表头 合成 tool_identity.txt。

用法: python build_identity_file.py <raw_stdout_file> <out_file>
(raw 由 tools/peer_ssh.py 直接重定向得到; 只有 ASCII, 无编码风险。)
"""
import sys

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
hdr = """=== W54 关闸轮 工具身份现核 (2026-10-07, 全只读) ===

[1] 对端 /tmp/p7b_biz 现算 md5 (peer side)
[2] 重编译等价 (peer, g++ 13.3.0 -O2; 临时产物随即删除, 未覆盖在役件)
    => 三个二进制全部逐字节等于其源码 x `g++ -O2`
[3] 仓库侧 md5 (repo copies) —— 与 [1] 逐条比对

说明: 对端在役三件 = 旧版 p7b_tcp_src (7f9aa716 源码 / c038e14a 二进制)
      · diag 版 (ffbc7f29 / 8c5b101d) · fix 版 (e0b7baa1 / 09a266a9)。
      阶梯轮 (2026-10-07 02:24-02:36) 跑的是 ./p7b_tcp_src = 旧版 (见本轮报告 §1.4)。

---- raw stdout (ASCII, 逐字) ----
"""
# 防止本地路径里的反斜杠干扰, 原样保留
open(sys.argv[2], "w", encoding="utf-8").write(hdr + raw)
print("wrote %s (%d bytes)" % (sys.argv[2], len(hdr) + len(raw)))
