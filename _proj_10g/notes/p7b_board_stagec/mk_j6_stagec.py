#!/usr/bin/env python3
"""mk_j6_stagec.py -- 生成 Stage C 轮的 j6 台架副本 (j6_stagec.sh)。

种子 = _proj_10g/notes/p7b_board_stagea/j6_stagea.sh (md5 记录在输出里)
唯一改动 = 几何默认值 9 -> 0xA (BID 已 bump; Build 3 = Stage C 位流)。
每处替换都断言**恰好命中一次** (少一处/多一处 = 停, 不写盘)。
"""
import hashlib
import io
import sys

SEED = "_proj_10g/notes/p7b_board_stagea/j6_stagea.sh"
OUT = "_proj_10g/notes/p7b_board_stagec/j6_stagec.sh"

src = io.open(SEED, encoding="utf-8", newline="").read()
seed_md5 = hashlib.md5(io.open(SEED, "rb").read()).hexdigest()

REPL = [
    # ① 头注: 加一行 Stage C 轮副本声明 (种子 md5 现场填)
    (
        "# tcpreg_j6.sh -- J6/J15 TCP 上行 A/B 测量 (peer -> board, port 8080)",
        "# tcpreg_j6.sh -- J6/J15 TCP 上行 A/B 测量 (peer -> board, port 8080)\n"
        "# ⭐ 2026-10-07 Stage C 板级轮副本 j6_stagec.sh: 种子 = p7b_board_stagea/j6_stagea.sh\n"
        "#    md5(__SEED_MD5__); 种子的 STALE 注释写 '默认 = 63 字 / BID 9';\n"
        "#    本副本**唯一改动** = 几何默认 9 -> 0xA。\n"
        "#    ⛔ 原句保留在下方 (BID 9 = P7B-WU 二轮 = Build 2 的历史口径)。",
    ),
    # ② head note (几何行)
    (
        "#   ⚠️ 几何: 默认 = **63 字 / BID 9** (P7B-WU 二轮, 现役)。读**旧位流** (BIZ 61 字 / BID 8)",
        "#   ⚠️ 几何: 默认 = **63 字 / BID 0xA** (P7b Stage C, 现役; ⛔ 种子原写 '63 字 / BID 9')。读**旧位流** (BIZ 61 字 / BID 8)",
    ),
    # ③ 默认 BID
    (
        "EXPECT_BID=${EXPECT_BID:-0x00000009}",
        "EXPECT_BID=${EXPECT_BID:-0x0000000A}   # 2026-10-07 Stage C: 原值 0x00000009 (Build 2)",
    ),
    # ④ 默认档硬断言
    (
        '{ [ "$NW" = "63" ] && [ "$EXPECT_BID" = "0x00000009" ]; } || {',
        '{ [ "$NW" = "63" ] && [ "$EXPECT_BID" = "0x0000000A" ]; } || {',
    ),
    # ⑤ 默认档失败文案
    (
        'echo "J6_GEOM_FAIL 默认档要求 NW=63 + EXPECT_BID=0x00000009 (实测 NW=$NW EXPECT_BID=$EXPECT_BID);"',
        'echo "J6_GEOM_FAIL 默认档要求 NW=63 + EXPECT_BID=0x0000000A (实测 NW=$NW EXPECT_BID=$EXPECT_BID);"',
    ),
    # ⑥ 几何门提示行
    (
        'echo "              (现役 63 字 = 0x00000009; BIZ 61 字 = 0x00000008 需 J6_LEGACY_GEOM=1)"',
        'echo "              (现役 63 字 = 0x0000000A; BIZ 61 字 = 0x00000008 需 J6_LEGACY_GEOM=1)"',
    ),
    # ⑦ BID 比较的大小写归一 (2026-10-07 Stage C 二次订正; 实测: 原字符串比较在 BID>=0xA 必假红)
    (
        'BID0=$(brd 0x04)\nif [ "$BID0" != "$EXPECT_BID" ]; then',
        'BID0=$(brd 0x04)\n'
        '# ⛔ 2026-10-07 Stage C 二次订正: reg_rw 打**小写** (0x0000000a) 而 EXPECT_BID 写大写\n'
        '#    ⇒ 原句 `[ "$BID0" != "$EXPECT_BID" ]` 在 BID 含字母的世代**必假红** (板子是对的);\n'
        '#    比较前两边归一到小写, 判据语义零改动 (打印仍用原样)。\n'
        'norm(){ printf "%s" "$1" | tr "A-F" "a-f"; }\n'
        'if [ "$(norm "$BID0")" != "$(norm "$EXPECT_BID")" ]; then',
    ),
]

out = src
for i, (old, new) in enumerate(REPL, 1):
    n = out.count(old)
    assert n == 1, "anchor %d hit %d times (want exactly 1): %r" % (i, n, old[:60])
    out = out.replace(old, new)

out = out.replace("__SEED_MD5__", seed_md5)
# 拒绝任何残留的 09 默认值 (值行口径)
assert "EXPECT_BID:-0x00000009" not in out, "stale default left"
assert "= \"0x00000009\"" not in out, "stale assert left"

io.open(OUT, "w", encoding="utf-8", newline="").write(out)
print("SEED = %s  md5=%s" % (SEED, seed_md5))
print("OUT  = %s  md5=%s" % (OUT, hashlib.md5(io.open(OUT, "rb").read()).hexdigest()))
print("OK: %d anchors replaced, no stale default left" % len(REPL))
