# -*- coding: utf-8 -*-
"""Stage C 回归 / 破坏实验: 建镜像树 + 为每条臂摆好文件 (只动镜像, 真树零写入)。

镜像树 = `sim/p7b_stagec_tx_regress/mirror/` (本 agent 独占 scratch):
  rtl/ tb/ tools/ hls/.../verilog/ sim/p4gates/{*.bat,*.py,*.txt,*.f}
  sim/p4sim/run_tb_*.bat  CLAUDE.md
  ⇒ 镜像里的 `sim/p4gates/p4env.bat` **自定位** ⇒ REPO_ROOT = 镜像根
    ⇒ runner/守卫/指纹/工作目录全部落在镜像内 (真树只会被**读**)。

臂:
  M0  纯净件 + 原始 bat                        -> 基线 (期望 EXIT=0 / P4 CHAIN OK)
  M1  单字节变异件 mut_ovl.v (`ifdef TCP_TX_OVL 内) + 原始 bat
  M2  同 M1, 但 bat 的 rtl xvlog 行加 `-d TCP_TX_OVL`
  M3  单字节变异件 mut_def.v (`else 分支内) + 原始 bat  (门有牙的对照臂)

用法: python setup_arm.py M0|M1|M2|M3 [--build]
打印: 摆好后镜像内 tcp_tx_frame.v / run_tb_p4_chain.bat 的 sha256 + 关键事实
      (变异是否在 ifdef 区内 / bat 是否带 -d TCP_TX_OVL)
"""
import hashlib
import os
import shutil
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
MIR = os.path.join(HERE, "mirror")

SRC_TXF = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")
SRC_BAT = os.path.join(ROOT, "sim", "p4sim", "run_tb_p4_chain.bat")
MIR_TXF = os.path.join(MIR, "rtl", "tcp_tx_frame.v")
MIR_BAT = os.path.join(MIR, "sim", "p4sim", "run_tb_p4_chain.bat")

BAT_ANCHOR = "call %XV%\\xvlog.bat -work xil_defaultlib ^\r\n  %REPO_ROOT%\\rtl\\crc32_8b.v"


def sha(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def build_mirror():
    if os.path.isdir(MIR):
        shutil.rmtree(MIR)
    os.makedirs(MIR)
    for d in ("rtl", "tb", "tools"):
        shutil.copytree(os.path.join(ROOT, d), os.path.join(MIR, d))
    # manifests also name board/uart_dbg.v (uart_src.f) -- the fingerprint
    # walks the union of all 5 manifests, so it must be present.
    os.makedirs(os.path.join(MIR, "board"))
    shutil.copy2(os.path.join(ROOT, "board", "uart_dbg.v"),
                 os.path.join(MIR, "board", "uart_dbg.v"))
    os.makedirs(os.path.join(MIR, "hls", "slowstack_prj", "solution1", "syn"))
    shutil.copytree(os.path.join(ROOT, "hls", "slowstack_prj", "solution1", "syn",
                                 "verilog"),
                    os.path.join(MIR, "hls", "slowstack_prj", "solution1", "syn",
                                 "verilog"))
    gd = os.path.join(MIR, "sim", "p4gates")
    os.makedirs(gd)
    for pat in (".py", ".bat", ".txt", ".f"):
        for n in os.listdir(os.path.join(ROOT, "sim", "p4gates")):
            if n.endswith(pat):
                shutil.copy2(os.path.join(ROOT, "sim", "p4gates", n),
                             os.path.join(gd, n))
    sd = os.path.join(MIR, "sim", "p4sim")
    os.makedirs(sd)
    for n in os.listdir(os.path.join(ROOT, "sim", "p4sim")):
        if n.startswith("run_tb_") and n.endswith(".bat"):
            shutil.copy2(os.path.join(ROOT, "sim", "p4sim", n),
                         os.path.join(sd, n))
    shutil.copy2(os.path.join(ROOT, "CLAUDE.md"), os.path.join(MIR, "CLAUDE.md"))
    print("mirror built: %s" % MIR)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    arm = (args[0] if args else "M0").upper()
    if "--build" in sys.argv or not os.path.isdir(MIR):
        build_mirror()

    # 每次都先复位 bat 与 rtl 件 -> 臂之间零串味 (可反复复算)
    shutil.copy2(SRC_BAT, MIR_BAT)
    shutil.copy2(SRC_TXF, MIR_TXF)

    if arm == "M0":
        pass
    elif arm in ("M1", "M2"):
        shutil.copy2(os.path.join(HERE, "mut", "mut_ovl.v"), MIR_TXF)
        if arm == "M2":
            with open(MIR_BAT, "rb") as f:
                b = f.read()
            for nl in (b"\r\n", b"\n"):
                anch = BAT_ANCHOR.replace("\r\n", nl.decode()).encode()
                if anch in b:
                    break
            n = b.count(anch)
            assert n == 1, "bat anchor hits=%d (expect 1)" % n
            b2 = b.replace(anch, anch.replace(b"-work xil_defaultlib",
                                              b"-work xil_defaultlib -d TCP_TX_OVL"))
            with open(MIR_BAT, "wb") as f:
                f.write(b2)
    elif arm == "M3":
        shutil.copy2(os.path.join(HERE, "mut", "mut_def.v"), MIR_TXF)
    else:
        print("unknown arm %r" % arm)
        sys.exit(2)

    with open(MIR_TXF, "rb") as f:
        t = f.read()
    with open(MIR_BAT, "rb") as f:
        bt = f.read()
    ovl_region = t.find(b"`ifdef TCP_TX_OVL")
    els = t.find(b"`else", ovl_region)
    print("arm        : %s" % arm)
    print("ifdef@byte : OVL=%d  else=%d  (OVL region = bytes %d..%d)"
          % (ovl_region, els, ovl_region, els))
    print("mirror txf : %s  %d bytes  sha256=%s"
          % (MIR_TXF, len(t), sha(MIR_TXF)))
    print("mirror bat : sha256=%s   has TCP_TX_OVL=%s"
          % (sha(MIR_BAT), b"TCP_TX_OVL" in bt))
    srcb = open(SRC_TXF, "rb").read()
    print("vs worktree: txf same=%s (bytes %d vs %d)"
          % (t == srcb, len(t), len(srcb)))


if __name__ == "__main__":
    main()
