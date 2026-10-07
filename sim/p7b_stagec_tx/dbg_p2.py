import io, os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.join(HERE, "tcp_tx_frame.v.base")
BR = os.path.join(HERE, "ovl_branch.v")
ANCH1 = ("    parameter integer ACKQ_D  = 32;\n"
         "    parameter integer ACKQ_AW = 5;\n"
         "\n")
ANCH2 = "    assign dbg_plen     = plen;\n"


def rd(p):
    return io.open(p, encoding="utf-8", newline="").read()


def pp(src, defs):
    out, st = [], []
    for ln in src.split("\n"):
        t = ln.lstrip()
        if t.startswith("`ifdef ") or t.startswith("`ifndef "):
            inv = t.startswith("`ifndef ")
            name = t.split()[1]
            v = (name in defs) != inv
            st.append([v, v]); continue
        if t.startswith("`else"):
            st[-1][0] = not st[-1][1]; st[-1][1] = st[-1][1] or st[-1][0]; continue
        if t.startswith("`endif"):
            st.pop(); continue
        if all(f[0] for f in st):
            out.append(ln)
    return "\n".join(out)


base = rd(BASE)
br = rd(BR)
new = base.replace(ANCH1, ANCH1 + "`ifdef TCP_TX_OVL\n" + br + "`else\n")
new = new.replace(ANCH2, ANCH2 + "`endif\n")
bl = base.split("\n")
nl = pp(new, set()).split("\n")
nlo = pp(new, {"TCP_TX_OVL"}).split("\n")
print("lines base=%d  pp-off=%d  pp-on=%d" % (len(bl), len(nl), len(nlo)))
for i in range(max(len(bl), len(nl))):
    a = bl[i] if i < len(bl) else "<MISSING>"
    b = nl[i] if i < len(nl) else "<MISSING>"
    if a != b:
        print("first diff at line %d" % (i + 1))
        print("BASE:", repr(a[:160]))
        print("NEW :", repr(b[:160]))
        break
else:
    print("no diff??")
