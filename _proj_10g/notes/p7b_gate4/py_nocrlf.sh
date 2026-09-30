#!/bin/bash
# py_nocrlf.sh — 环境补丁 (不改任何验收脚本): Windows Python 的 stdout 是 TextIOWrapper with
#   newline=None ⇒ 写 \n 时会被翻成 os.linesep = "\r\n"。而 peer_ssh.py 的 stdout 承载的是
#   **远程 Linux 的原始输出 (LF)** ⇒ 本机拿到的是 CRLF ⇒ p7b_gate4_accept.sh 的 parse_snap
#   严格正则 `^0[xX][0-9a-fA-F]{1,8}$` 不匹配 (值尾多一个 \r) ⇒ 前置闸 ABORT。
#   证据: `python tools/peer_ssh.py "echo AAA; echo BBB" | od -c` = `A A A \r \n B B B \r \n`;
#         而对端机上同一命令经 `od -c` = `0 x 0 0 ... 1 9 \n` (无 \r)。
#   为什么假板子自证没抓到: 自证/负对照喂的是**本地 bash 写的合成文本 (LF)** ⇒ 这条 live 路径
#   本来就没被覆盖过 (P7B_GATE4_TOOLING.md 自己声明了 "live 路径没有跑过")。
# 用法: PY=<本文件> bash _proj_pcie/p7b_gate4_accept.sh   (脚本内 peer() 用 "$PY" 调 peer_ssh.py)
REAL=${REAL_PY:-/c/Users/zhxue/anaconda3/python.exe}
"$REAL" "$@" | tr -d '\r'
exit "${PIPESTATUS[0]}"
