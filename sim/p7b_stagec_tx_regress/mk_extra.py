# -*- coding: utf-8 -*-
"""Stage C 回归: 把"作者未跑的追加门"复制进本 agent 的 scratch 并改路径。

纪律: **canonical 目录 (sim/p5sim, sim/p5d_multi, _proj_10g/p7b_*) 零写入**
      —— 每条门都在本 scratch 里跑自己的副本 (xsim.dir / 日志都落在副本目录)。

生成:
  extra/<gate>/run.bat        工作区臂 (RTL = 真仓 %REPO_ROOT%\\rtl)
  extra_head/<gate>/run.bat   HEAD 臂 (RTL = 本 scratch 的 head_rtl/, 内含 HEAD 版
                              tcp_tx_frame.v / app_pattern.v, 其余文件与工作区逐字相同)
  head_rtl/                   = rtl/ 的工作区副本 + 两个 HEAD 件覆盖

替换规则 (逐条, 每条都断言命中 1 次):
  S1  set "REPO_ROOT=%~dp0..\\..\\."  -> ..\\..\\..\\..        (副本深两层)
  S2  set RTL=%REPO_ROOT%\\rtl        -> set RTL=<abs head_rtl> (仅 HEAD 臂)
  S3  set SIM=%REPO_ROOT%\\sim\\p5sim  -> set SIM=%~dp0
  S4  set ROOT=D:\\repo\\XCKU5PMini\\udp_hls_10g -> set ROOT=<abs head_root> (p7b 门 HEAD 臂)
"""
import hashlib
import os
import shutil
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
HEAD = os.path.join(HERE, "head_rtl")
HEADROOT = os.path.join(HERE, "head_root")

HEAD_SHA = {
    "tcp_tx_frame.v": "d2dab616530f419f1ff20acdd57e0ca031d116e683cc4b13e2f1e87fb3369847",
    "app_pattern.v": "da7a2c7c6876000b5b7c2e378a8862460803133c04deefdee33f6de035a499e1",
}

# gate -> (canonical bat, [额外文件(相对 canonical dir 的兄弟文件)])
GATES = {
    "p5_status":    (r"sim\p5sim\run_tb_p5_status.bat", []),
    "p5_pattern":   (r"sim\p5sim\run_tb_p5_pattern.bat", []),
    "p5d_multi":    (r"sim\p5d_multi\run_tb_p5_multi.bat", []),
    "p7b_appsplit": (r"_proj_10g\p7b_appsplit\sim\run_tb_p7b_appsplit.bat",
                     ["tb_p7b_appsplit.v"]),
    "p7b_chain":    (r"_proj_10g\p7b_chain\sim\run_tb_p7b_chain.bat",
                     ["tb_p7b_chain.v"]),
}
P7B = ("p7b_appsplit", "p7b_chain")


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def sub1(text, a, b, tag):
    n = text.count(a)
    if n != 1:
        raise SystemExit("SUBFIX %s: hits=%d (expect 1) for %r" % (tag, n, a))
    return text.replace(a, b)


# 2026-10-07 实测踩到: 用文本模式读 + 二进制写会把 CRLF 压成 LF, 而
# `_proj_10g/p7b_chain` 的 bat 在 LF 下会被 cmd.exe **逐行错位执行**
# (REM 里的单词被当命令跑: `'clk_gen_p6b' is not recognized...`)。
# ⇒ 全部替换改在 **bytes** 层做, 行尾一个字节都不动。
def subb(blob, a, b, tag):
    a, b = a.encode(), b.encode()
    n = blob.count(a)
    if n != 1:
        raise SystemExit("SUBFIX %s: hits=%d (expect 1) for %r" % (tag, n, a))
    return blob.replace(a, b)


def build_head_rtl():
    if os.path.isdir(HEAD):
        shutil.rmtree(HEAD)
    shutil.copytree(os.path.join(ROOT, "rtl"), HEAD)
    for f in HEAD_SHA:
        # HEAD 版必须来自 git 对象库 (不是上一轮的复印件)
        out = os.path.join(HEAD, f)
        with open(out, "wb") as fh:
            import subprocess
            fh.write(subprocess.check_output(
                ["git", "show", "46b2f68:rtl/" + f], cwd=ROOT))
        got = sha(out)
        assert got == HEAD_SHA[f], "HEAD sha mismatch %s: %s" % (f, got)
        print("head_rtl/%s sha256=%s  (== HEAD 46b2f68)" % (f, got[:16]))
    print("head_rtl: %d files" % len(os.listdir(HEAD)))


def build_head_root():
    """p7b 门的 HEAD 臂: 一个只把 rtl 换掉的最小树 (其余路径逐字复制真仓)。"""
    if os.path.isdir(HEADROOT):
        shutil.rmtree(HEADROOT)
    os.makedirs(HEADROOT)
    shutil.copytree(HEAD, os.path.join(HEADROOT, "rtl"))
    for rel in (r"board\wrapper_p4.v", r"board\util_gmii_to_rgmii_us.v",
                r"board\uart_dbg.v", r"board\p7b_pcs_stub.v",
                r"_proj_pcie\rtl\axi_regs.v", r"sim\p6e_pcie\xdma_0_sim_stub.v"):
        d = os.path.join(HEADROOT, os.path.dirname(rel))
        os.makedirs(d, exist_ok=True)
        shutil.copy2(os.path.join(ROOT, rel), os.path.join(HEADROOT, rel))
    for rel in (r"_proj_10g\p7b_mac\rtl",
                r"hls\slowstack_prj\solution1\syn\verilog"):
        shutil.copytree(os.path.join(ROOT, rel), os.path.join(HEADROOT, rel))
    print("head_root built: %s" % HEADROOT)


def make(arm):
    base = os.path.join(HERE, arm)
    if os.path.isdir(base):
        shutil.rmtree(base)
    for g, (rel, extra) in GATES.items():
        dst = os.path.join(base, g)
        os.makedirs(dst)
        src = os.path.join(ROOT, rel)
        out = open(src, "rb").read()          # bytes: 行尾逐字节保留
        assert out.count(b"\r\n") == out.count(b"\n"), "source bat is not CRLF"
        if g in P7B:
            if arm == "extra_head":
                out = subb(out, r"set ROOT=D:\repo\XCKU5PMini\udp_hls_10g",
                           "set ROOT=" + HEADROOT, g)
        else:
            out = subb(out, r'set "REPO_ROOT=%~dp0..\..\."',
                       r'set "REPO_ROOT=%~dp0..\..\..\..\.', g)
            if b"set SIM=%REPO_ROOT%\\sim\\p5sim" in out:   # p5d_multi 已是 %~dp0
                out = subb(out, r"set SIM=%REPO_ROOT%\sim\p5sim",
                           r"set SIM=%~dp0", g)
            if arm == "extra_head":
                out = subb(out, r"set RTL=%REPO_ROOT%\rtl",
                           "set RTL=" + HEAD, g)
        assert out.count(b"\r\n") == out.count(b"\n"), "output bat lost CRLF"
        with open(os.path.join(dst, "run.bat"), "wb") as f:
            f.write(out)
        for e in extra:
            shutil.copy2(os.path.join(os.path.dirname(src), e),
                         os.path.join(dst, e))
        print("%s/%-12s <- %s   (bat sha256=%s)" % (arm, g, rel, sha(os.path.join(dst, "run.bat"))[:16]))


if __name__ == "__main__":
    build_head_rtl()
    build_head_root()
    make("extra")
    make("extra_head")
    print("MK_EXTRA: OK")
