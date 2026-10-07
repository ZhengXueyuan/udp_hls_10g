# -*- coding: utf-8 -*-
"""Stage C 回归: 为"两种盲"的破坏实验生成**单字节**变异件 (只在副本上改)。

两个变异件 (每个 = 恰好删掉 1 个字节 = 结尾的分号):
  mut/mut_ovl.v  -- 锚点落在 `ifdef TCP_TX_OVL 分支内 (L436, 乒乓新代码)
  mut/mut_def.v  -- 锚点落在 `else 分支内 (L1021, 默认/现役代码)

自证 (打印 + 任一不成立即非零退出):
  1. 基线 == 工作区 rtl/tcp_tx_frame.v (sha256 逐字相同) —— 证明变异打在"真件"的副本上
  2. 每个锚点在基线里恰命中 1 次 (不用行号盲删)
  3. 变异后 = 少 1 个字节, 其余字节逐字相同
  4. 锚点行号落在声明的 ifdef 区间内 (OVL: 204..1000 / DEF: 1001..1955)
  5. 变异后 sha256 != 基线 sha256

用法: python mk_mut.py            (在 sim/p7b_stagec_tx_regress/ 里跑)
"""
import hashlib
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")
MUTDIR = os.path.join(HERE, "mut")

BASE_SHA = "10e75f21f0720b03f28706abcc27e8f9cb0cc24b913137f8af943cb891245f27"

# (名字, 锚点原文, ifdef 区间, 说明)
CASES = [
    ("mut_ovl.v",
     "    wire        upd_wr_data = (rx_state == RX_FIN) && (fin_cnt == 3'd0);\n",
     (204, 1000),
     "删掉 OVL 分支内 upd_wr_data 声明的结尾分号"),
    ("mut_def.v",
     "    reg  [2:0]  wait_cnt;\n",
     (1001, 1955),
     "删掉默认分支内 wait_cnt 声明的结尾分号"),
]


def sha(b):
    return hashlib.sha256(b).hexdigest()


def main():
    with open(SRC, "rb") as f:
        raw = f.read()
    h = sha(raw)
    print("baseline  : %s" % SRC)
    print("sha256    : %s" % h)
    assert h == BASE_SHA, "BASE SHA MISMATCH: %s != %s" % (h, BASE_SHA)
    print("MATCH     : 与工作区 sha256 逐字相同 (== %s)" % BASE_SHA[:12])
    assert raw.count(b"\r\n") == 0 or True
    nl = "\r\n" if raw.count(b"\r\n") > raw.count(b"\n") / 2 else "\n"
    print("newline   : %s" % ("CRLF" if nl == "\r\n" else "LF"))
    text = raw.decode("utf-8", "replace")

    os.makedirs(MUTDIR, exist_ok=True)
    ok = True
    for name, anchor, (lo, hi), note in CASES:
        a = anchor if nl == "\n" else anchor.replace("\n", nl)
        n = text.count(a)
        line = text[: text.find(a)].count("\n") + 1
        if n != 1:
            print("FAIL %s: anchor hits=%d (expect 1)" % (name, n))
            ok = False
            continue
        if not (lo <= line <= hi):
            print("FAIL %s: anchor line %d outside ifdef region %d..%d"
                  % (name, line, lo, hi))
            ok = False
            continue
        # 删掉锚点里那个分号 (恰好 1 字节)
        mut = text.replace(a, a.replace(";", "", 1))
        mb = mut.encode("utf-8", "replace")
        assert len(mb) == len(raw) - 1, "not a 1-byte deletion"
        # 逐字节核对: 恰有 1 个删除点 k 使 mb == raw[:k] + raw[k+1:]
        delpos = [k for k in range(len(mb)) if mb[:k] == raw[:k]
                  and mb[k:] == raw[k + 1:]]
        assert len(delpos) == 1, "not an exact 1-byte deletion: %s" % delpos
        k = delpos[0]
        assert raw[k:k + 1] == b";", "deleted byte is %r not ';'" % raw[k:k + 1]
        diff = delpos
        out = os.path.join(MUTDIR, name)
        with open(out, "wb") as f:
            f.write(mb)
        mh = sha(mb)
        print("OK   %s: line=%d region=%d..%d  bytes %d -> %d  diff_at=%s  "
              "sha256=%s  (%s)" % (name, line, lo, hi, len(raw), len(mb),
                                   diff, mh[:16], note))
        if mh == h:
            print("FAIL %s: sha256 unchanged" % name)
            ok = False
    if not ok:
        sys.exit(1)
    print("MK_MUT: OK")


if __name__ == "__main__":
    main()
