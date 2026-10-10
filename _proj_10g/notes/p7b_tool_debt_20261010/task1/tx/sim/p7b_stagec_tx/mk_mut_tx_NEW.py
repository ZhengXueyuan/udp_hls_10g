#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mk_mut_tx.py -- 从现役 rtl/tcp_tx_frame.v 生成负对照变异件 (每个 = 1 处改动).
   每个变异在源文件上做**声明过的**替换, 命中数不足/超出 ⇒ 硬失败 (不是"静默没打上").
   输出到 <本目录>/mut/*.v   (由 run_tx_ovl_gate.bat 消费)

   ------------------------------------------------------------------
   2026-10-10 工具修复 (地雷处置; 修法照已修好的参照件
   sim/p7b_stagec_tx_regress/author_gate/mk_mut_tx.py, 变异清单仍是本目录自己的 13 条):
   (1) **落盘时机 = 全成或全不落 (all-or-nothing)**: 旧版**边匹配边写盘** ⇒
       锚点没命中的那些变异被写成**未变异的源文件副本** (参照件那支实测: 三件 sha256
       == 源文件), 多锚点的变异只落**一半替换** —— 而"变异臂"这个名字会照样被门消费
       = 哑门族 (判据看着有牙, 其实打的是源文件)。旧版还会对失败的件照打 `WROTE`。
       现在: 先在内存里把**所有**变异件做完 + 逐锚点核命中数 + 核源文件 sha256 未变,
       全部通过才一次性落盘; 任一失败 ⇒ **不落盘任何变异件**, 并把本清单里**已存在的**
       同名旧件删掉 (打印 PURGED) ⇒ 硬不变式:
       **mut/ 要么是"本清单全部变异件的完整、已核验的一份", 要么是空的**,
       绝不会出现"半套/陈旧混装"。
   (2) **换行归一化改成显式**: 本工作树受 core.autocrlf=true 影响, `rtl/tcp_tx_frame.v`
       工作树是 CRLF (2026-10-10 实测 136,970 B / 2,170 CRLF / 0 lone CR), 而锚点里的
       多行串写的是裸 "\n"。旧版靠 `io.open(...)` 的**默认通用换行**在**读侧**归一 ——
       碰巧能work, 但**输出风格随之依赖读侧行为**, 且 `newline=""` 读法下会静默全 MISS。
       现在: 读入即显式 `norm()`, 锚点做同样归一化, 输出**一律写 LF**
       ⇒ 变异件与签出风格无关 (CRLF/LF 工作树产出逐字节相同, 可对 sha256 断言),
       且与 `git show HEAD:` 的存法一致。
   (3) **命中数一律在【未修改的源文本】上计** (参照件同款): 旧版在**逐条替换后的**
       中间文本上 `t.count(old)` —— 一旦某条替换的 new 里含另一条的 old 就会静默漂移。
       本清单一律核过 (逐锚点见 `--dry-run`), 两法等价; 取参照件写法防将来漂移。
   ------------------------------------------------------------------
   `--dry-run` (或 `--check`): 只做匹配 + 打印逐锚点命中表, **一个字节都不写**.
   退出码: 0 = 全部锚点命中数 == 声明值; 1 = 有差异.
"""
import hashlib
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")
OUT = os.path.join(HERE, "mut")

MUTS = []   # (name, [(old, new, hits)], note)


def add(name, subs, note):
    MUTS.append((name, subs, note))


# ---- S0a: 推进写值少一帧 (OVL 分支; 与 M-C3 "推进写搬回 S_DONE" 同族) ----
add("mut_s0a", [(
    "assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + {20'b0, f_plen[rx_bank]}) :",
    "assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + 32'd0) :",
    1)], "OVL: 数据推进写不推进 (seq 复用)")

# ---- S0b: 默认 (串行) 分支同族变异: 数据段推进写不推进 ----
add("mut_s0b", [(
    "    assign upd_val = svc_rewind ? rb_snd_una :\n"
    "                     seq_r + (is_data_r ? {20'b0, plen_r} : 32'd1);",
    "    assign upd_val = svc_rewind ? rb_snd_una :\n"
    "                     seq_r + (is_data_r ? 32'd0 : 32'd1);",
    1)], "默认分支: 数据推进写不推进 (S0 灵敏度证明用)")

# ---- M-C1: 撞写口 (upd_wr_ctrl 与 upd_wr_data 同拍) ----
add("mut_c1", [(
    "    wire        upd_wr_ctrl = start_ack && (aq_syn | aq_fin | aq_rst);",
    "    wire        upd_wr_ctrl = upd_wr_data || (start_ack && (aq_syn | aq_fin | aq_rst));",
    1)], "M-C1 同拍撞写口 => $onehot0 红")

# ---- M-C2: 预留写寄存 8 拍 (形 A: (wr,val,id) 三件套一起延) ----
#   ⚠️ s2/s3 锚点 = RETXFIX 后的**三级三目**形态 (`upd_wr_ctrl ? start_id :` 之后还有
#      `(replay_jump ? retx_id_r : svc_id)`); 本变异只动第二级 ctrl 分支的取值来源,
#      语义与旧版声明完全一致。2026-10-10 实测三条锚点 hits 全 = 1 (`--dry-run`)。
add("mut_c2", [
    ("    wire        upd_wr_ctrl = start_ack && (aq_syn | aq_fin | aq_rst);",
     "    // M-C2 形 A: (wr,val,id) 三件套一起寄存 8 拍\n"
     "    reg [3:0]  mcd; reg [3:0] mcd_id; reg [31:0] mcd_val;\n"
     "    always @(posedge clk or negedge rst_n) begin\n"
     "        if (!rst_n) begin mcd <= 4'd0; mcd_id <= 4'd0; mcd_val <= 32'd0; end\n"
     "        else if (start_ack && (aq_syn | aq_fin | aq_rst)) begin\n"
     "            mcd <= 4'd8; mcd_id <= start_id; mcd_val <= rb_snd_nxt + 32'd1;\n"
     "        end else if (mcd != 4'd0) mcd <= mcd - 4'd1;\n"
     "    end\n"
     "    wire        upd_wr_ctrl = (mcd == 4'd1);", 1),
    ("    assign      upd_id  = upd_wr_data ? f_conn[rx_bank] :\n"
     "                          (upd_wr_ctrl ? start_id :\n"
     "                           (replay_jump ? retx_id_r : svc_id));",
     "    assign      upd_id  = upd_wr_data ? f_conn[rx_bank] :\n"
     "                          (upd_wr_ctrl ? mcd_id :\n"
     "                           (replay_jump ? retx_id_r : svc_id));", 1),
    ("    assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + {20'b0, f_plen[rx_bank]}) :\n"
     "                          (upd_wr_ctrl ? (rb_snd_nxt + 32'd1) :\n"
     "                           (replay_jump ? retx_hi : rb_snd_una));",
     "    assign      upd_val = upd_wr_data ? (f_seq[rx_bank] + {20'b0, f_plen[rx_bank]}) :\n"
     "                          (upd_wr_ctrl ? mcd_val :\n"
     "                           (replay_jump ? retx_hi : rb_snd_una));", 1),
], "M-C2 预留写滞后 8 拍 => J_seq_mono / J_seq_cont 红")

# ---- M-C3: 乒乓退化单 bank (接收门再加 TX 空闲) ----
add("mut_c3", [(
    "          && !fifo_full && !bank_rdy[rx_bank];",
    "          && !fifo_full && (bank_rdy == 2'b00) && (tx_state == T_IDLE);",
    1)], "M-C3 退化单 bank => 帧周期/TX 引擎拍数红")

# ---- M-C6: 撤回卷门 (!ctrl_adv_inflight) ----
add("mut_c6", [(
    "    wire        svc_x     = svc && !ctrl_adv_inflight;    // 回卷门 (§1.4(4))",
    "    wire        svc_x     = svc;",
    1)], "M-C6 撤回卷门 => FIN 预留被当 ring 数据重放 => J_seq_cont 红")

# ---- M-C7: 撤 start_ack 的 !ctrl_slot_busy ----
add("mut_c7", [(
    "    wire        start_ack = rx_idle && ack_pend_r && !ackq_empty && !rx_flush &&\n"
    "                            !ctrl_slot_busy;          // ← 槽跨拍独占门 (C7/C8)",
    "    wire        start_ack = rx_idle && ack_pend_r && !ackq_empty && !rx_flush;",
    1)], "M-C7 撤槽独占 => issued > transmitted => J6 红")

# ---- M-C8: 撤 start_ack 的 rx_idle ----
add("mut_c8", [(
    "    wire        start_ack = rx_idle && ack_pend_r && !ackq_empty && !rx_flush &&\n"
    "                            !ctrl_slot_busy;          // ← 槽跨拍独占门 (C7/C8)",
    "    wire        start_ack = ack_pend_r && !ackq_empty && !rx_flush &&\n"
    "                            !ctrl_slot_busy;",
    1)], "M-C8 撤 rx_idle => 控制帧在收帧期装载 (混拼)")

# ---- M-C9: 仲裁键改回 ctrl_slot_busy (两处帧边界判定) ----
add("mut_c9", [(
    "if (ctrl_tx_pend) begin",
    "if (ctrl_slot_busy) begin",
    2)], "M-C9 仲裁键=busy => 控制帧 T_DONE 自选 => transmitted > issued => J6 红")

# ---- M-F1: 撤回 F1 修复 (两分支同时回退 => "越顶下溢"重现) ----
# ⚠️ P7B-RETXFIX 后 OVL 分支的 ring_start 多带重放预算门 (replay_left), 两分支
#    文本不再相同 ⇒ 拆成两条替换, 各 hits=1 (语义不变: 都只撤 !retx_ovf)。
#    注: 预算门会把变异后的洪水截到每会话 ≤ RETX_SPAN 帧, 但探针判据是"任何
#    重放帧 > 0 ⇒ FLOOD", 牙齿保留 (P7B_RETXFIX 轮实测: Q 臂仍 FLOOD)。
add("mut_f1", [(
    """    wire        ring_start = ring_eval && (ring_delta != 32'd0) && !retx_ovf &&
                             scan_estab && ((replay_left != 4'd0) || replay_full);""",
    """    wire        ring_start = ring_eval && (ring_delta != 32'd0) &&
                             scan_estab && ((replay_left != 4'd0) || replay_full);""",
    1), (
    """    wire        ring_start = ring_eval && (ring_delta != 32'd0) && !retx_ovf &&
                             scan_estab;""",
    """    wire        ring_start = ring_eval && (ring_delta != 32'd0) &&
                             scan_estab;""",
    1)], "M-F1 撒!retx_ovf => delta 下溢当起重放 => 洪水 (两分支)")

# ---- M-C4: 会话自锁 (排空支不清 retx_active) ----
add("mut_c4", [(
    """                        end else begin
                            retx_active <= 1'b0;
                        end""",
    """                        end else begin
                            retx_active <= retx_active;   // M-C4 自锁
                        end""",
    1)], "M-C4 排空支不清会话 => retx 会话永不终止 => stuck 红")

# ---- M-K1 (P7B-RETXFIX 负对照): 撤重放预算 + 收尾跳写 (整条特性回退 ⇒ 整窗重放) ----
add("mut_k1", [(
    "    wire        ring_start = ring_eval && (ring_delta != 32'd0) && !retx_ovf &&\n"
    "                             scan_estab && ((replay_left != 4'd0) || replay_full);",
    "    wire        ring_start = ring_eval && (ring_delta != 32'd0) && !retx_ovf &&\n"
    "                             scan_estab;", 1),
    ("    wire        upd_wr_rew  = svc_rewind || replay_jump;",
     "    wire        upd_wr_rew  = svc_rewind;", 1),
], "M-K1 撤预算+跳写 => 会话重放整窗 => 跨度判据红 (确定性)")

# ---- M-K2 (P7B-RETXFIX 负对照): 只撤收尾跳写 (预算在 ⇒ 会话提前结束但 snd_nxt 不到位) ----
add("mut_k2", [(
    "    wire        upd_wr_rew  = svc_rewind || replay_jump;",
     "    wire        upd_wr_rew  = svc_rewind;", 1),
], "M-K2 撤跳写 => 会话收尾 snd_nxt<retx_hi => 跳写判据红 (确定性)")

# ---- M-L1 (P7B-RETXFIX r6, L-A 负对照): 撤 ack_seen 数据启动门 (tx_blk_sid 少一项) ----
add("mut_l1", [(
    "    wire        tx_blk_sid = tx_blk[start_id] | ~st_ok | ~acks_ok;",
    "    wire        tx_blk_sid = tx_blk[start_id] | ~st_ok;   // (M-L1: 撤 ack_seen 门)",
    1)], "M-L1 撤 ack_seen 门 => ARM_ACKGATE 保持窗内帧照常启动 => 判据红 (确定性)")


def norm(s):
    """换行归一化: \\r\\n / 单独 \\r 一律成 \\n (幂等)."""
    return s.replace("\r\n", "\n").replace("\r", "\n")


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def plan(src_lf):
    """只做匹配, 不落盘. 源文本必须已归一化为 LF.
    返回 [(name, subs, note, hits_list)]; hits_list[i] = 第 i 个锚点的实测命中数.
    ⚠️ 命中数一律在**未修改的源文本**上计 (见文件头 (3))."""
    out = []
    for name, subs, note in MUTS:
        out.append((name, subs, note, [src_lf.count(norm(old)) for old, _, _ in subs]))
    return out


def render(src_lf, subs):
    """按 subs 逐条替换, 返回变异件正文 (LF). 调用前必须已核过命中数."""
    t = src_lf
    for old, new, _ in subs:
        t = t.replace(norm(old), norm(new))
    return t


def main(argv):
    dry = ("--dry-run" in argv) or ("--check" in argv)

    raw_bytes = open(SRC, "rb").read()
    src = norm(io.open(SRC, encoding="utf-8", newline="").read())
    ref = sha256_bytes(raw_bytes)
    n_crlf = raw_bytes.count(b"\r\n")
    n_cr = raw_bytes.count(b"\r") - n_crlf
    print("SRC %s  %d B  sha256 %s" % (SRC, len(raw_bytes), ref))
    if n_crlf or n_cr:
        print("NORM: %d CRLF / %d lone CR -> LF (matching + output, 与签出风格无关)"
              % (n_crlf, n_cr))

    results = plan(src)
    fails = []
    for name, subs, note, hits in results:
        want = [e for _, _, e in subs]
        if hits != want:
            for i, (h, e) in enumerate(zip(hits, want), 1):
                if h != e:
                    print("MUTFAIL %s: pattern hits=%d expect=%d" % (name, h, e))
            fails.append(name)

    if dry:
        print("%-9s %-4s %s" % ("mutant", "sub", "hits/expect"))
        for name, subs, note, hits in results:
            for i, ((_, _, e), h) in enumerate(zip(subs, hits), 1):
                print("%-9s s%-3d %d/%d %s" % (name, i, h, e, "" if h == e else "<== MISMATCH"))
            print("%-9s %s" % ("", "USABLE" if hits == [e for _, _, e in subs] else "BROKEN"))
        print("DRYRUN %s (0 bytes written)" % ("OK" if not fails else "FAIL %d" % len(fails)))
        return 0 if not fails else 1

    if fails:
        print("MUTGEN FAIL %d" % len(fails))
        purge(results)
        return 1

    # 源文件在匹配期间被改过 ⇒ 整轮作废 (与"改 RTL / 在跑回归 互斥"同一条纪律)
    now = sha256_bytes(open(SRC, "rb").read())
    if now != ref:
        print("SRC-CHANGED during generation: %s -> %s" % (ref, now))
        print("MUTGEN FAIL 1")
        purge(results)
        return 1

    texts = [(name, note, render(src, subs)) for name, subs, note, _ in results]
    os.makedirs(OUT, exist_ok=True)
    for name, note, text in texts:
        io.open(os.path.join(OUT, name + ".v"), "w", encoding="utf-8", newline="").write(text)
        print("WROTE %-10s %s" % (name, note))

    # 落盘后再核一次 (窗口内被改也作废, 保证落盘集 = 单一已核源修订)
    now = sha256_bytes(open(SRC, "rb").read())
    if now != ref:
        print("SRC-CHANGED after write: %s -> %s" % (ref, now))
        print("MUTGEN FAIL 1")
        purge(results)
        return 1

    n_subs = sum(len(subs) for _, subs, _, _ in results)
    print("ANCHORS: all %d mutants matched (%d subs, each hits==expect)"
          % (len(results), n_subs))
    print("MUTGEN OK (%d mutants)" % len(MUTS))
    return 0


def purge(results):
    """失败路径: 删掉本清单里**已存在的**同名旧件 (只删这些文件名, 不做通配删除).
    理由: mut/ 里同名旧件一定来自**另一个源修订**, 混装 = 静默陈旧证据;
    硬不变式 = mut/ 要么是"本清单的完整已核验一份", 要么是空的."""
    for name, _, _, _ in results:
        p = os.path.join(OUT, name + ".v")
        if os.path.exists(p):
            os.remove(p)
            print("PURGED stale %s" % p)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
