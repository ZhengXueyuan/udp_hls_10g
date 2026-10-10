# -*- coding: utf-8 -*-
"""patch_mkmut.py -- 重新对齐被 PERSIST 刀改写的 4 个旧锚点 + 追加 3 个新变异."""
import io, os

p = os.path.join(r"D:\repo\XCKU5PMini\udp_hls_10g",
                 "sim", "p7b_stagec_tx_regress", "author_gate", "mk_mut_tx.py")
raw = io.open(p, encoding="utf-8", newline="").read()
is_crlf = raw.count("\r\n") > 0
t = raw.replace("\r\n", "\n")

UPD_OLD = '    "    wire        upd_wr_ctrl = start_ack && (aq_syn | aq_fin | aq_rst);",'
UPD_NEW = '    "    wire        upd_wr_ctrl = start_ack && !probe_sel && (aq_syn | aq_fin | aq_rst);",'

SA_OLD = ('    "    wire        start_ack = rx_idle && ack_pend_r && !ackq_empty && !rx_flush &&\\n"\n'
          '    "                            !ctrl_slot_busy;          // ← 槽跨拍独占门 (C7/C8)",')
SA_NEW = ('    "    wire        start_ack = rx_idle && !rx_flush && !ctrl_slot_busy &&\\n"\n'
          '    "                            ((ack_pend_r && !ackq_empty) || probe_sel);",')

subs = []

# mut_c1 s1
a = ('add("mut_c1", [(\n' + UPD_OLD + '\n'
     '    "    wire        upd_wr_ctrl = upd_wr_data || (start_ack && (aq_syn | aq_fin | aq_rst));",\n'
     '    1)], "M-C1 同拍撞写口 => $onehot0 红")')
b = ('add("mut_c1", [(\n' + UPD_NEW + '\n'
     '    "    wire        upd_wr_ctrl = upd_wr_data || (start_ack && !probe_sel && (aq_syn | aq_fin | aq_rst));",\n'
     '    1)], "M-C1 同拍撞写口 => $onehot0 红")\n'
     '#   [!!] 2026-10-10 (PERSIST 实施轮) 重新对齐: `upd_wr_ctrl` 那一行被 PERSIST 刀加了\n'
     '#      `!probe_sel` 门 (rtl/tcp_tx_frame.v 的 §2.4-4 (1)) => 旧锚点 0 命中 (MUTFAIL)。\n'
     '#      变异语义 (同拍撞写口) 一字未变。')
subs.append((a, b))

# mut_c2 s1 (同一行) + s4 (mcd 版的 upd_wr_ctrl 下游)
a = ('    (' + UPD_OLD.strip() + '\n'
     '     "    // M-C2 形 A: (wr,val,id) 三件套一起寄存 8 拍\\n"')
b = ('    (' + UPD_NEW.strip() + '\n'
     '     "    // M-C2 形 A: (wr,val,id) 三件套一起寄存 8 拍\\n"')
subs.append((a, b))

a = '     "    wire        upd_wr_ctrl = (mcd == 4\'d1);", 1),'
b = '     "    wire        upd_wr_ctrl = (mcd == 4\'d1) && !probe_sel;", 1),'
subs.append((a, b))

# mut_c7
a = ('add("mut_c7", [(\n' + SA_OLD + '\n'
     '    "    wire        start_ack = rx_idle && ack_pend_r && !ackq_empty && !rx_flush;",\n'
     '    1)], "M-C7 撤槽独占 => issued > transmitted => J6 红")')
b = ('add("mut_c7", [(\n' + SA_NEW + '\n'
     '    "    wire        start_ack = rx_idle && !rx_flush &&\\n"\n'
     '    "                            ((ack_pend_r && !ackq_empty) || probe_sel);",\n'
     '    1)], "M-C7 撤槽独占 => issued > transmitted => J6 红")\n'
     '#   [!!] 2026-10-10 (PERSIST 实施轮) 重新对齐: `start_ack` 的**写法**变了\n'
     '#      (探询支并入 + 子句次序重排, rtl §2.5-(5)) => 旧锚点 0 命中; 变异语义 (撤\n'
     '#      `!ctrl_slot_busy`) 一字未变。')
subs.append((a, b))

# mut_c8
a = ('add("mut_c8", [(\n' + SA_OLD + '\n'
     '    "    wire        start_ack = ack_pend_r && !ackq_empty && !rx_flush &&\\n"\n'
     '    "                            !ctrl_slot_busy;",\n'
     '    1)], "M-C8 撤 rx_idle => 控制帧在收帧期装载 (混拼)")')
b = ('add("mut_c8", [(\n' + SA_NEW + '\n'
     '    "    wire        start_ack = !rx_flush && !ctrl_slot_busy &&\\n"\n'
     '    "                            ((ack_pend_r && !ackq_empty) || probe_sel);",\n'
     '    1)], "M-C8 撤 rx_idle => 控制帧在收帧期装载 (混拼)")\n'
     '#   [!!] 2026-10-10 (PERSIST 实施轮) 重新对齐 (同 mut_c7 注)。')
subs.append((a, b))

for a, b in subs:
    n = t.count(a)
    print(n, "|", a.strip().splitlines()[0][:56])
    assert n == 1, (n, a[:80])
    t = t.replace(a, b)

PS_BLOCK = '''
# ===========================================================================
# P7B-PERSIST 变异臂 (2026-10-10 实施轮; 判据在 tb/tb_tcp_tx_ovl.v 的 ARM_PERSIST 段)
#   每个变异 = 1 处改动, 锚点逐字取自**现役** rtl/tcp_tx_frame.v。
# ===========================================================================

# ---- PS-MUT-1: 删掉武装条件里的 !fin_sent_r[scan_id] (D-5 的第五子句) ----
#   判据 (j12-FIN): E5 窗内 (conn2 的 FIN 在飞 + 窗 0 + 有在飞) 必须 0 探询。
add("mut_ps_noarmfin", [(
    "    wire        ps_arm    = PERSIST_EN && scan_now && scan_estab &&\\n"
    "                            (rb_snd_wnd == 16'd0) && (rb_snd_nxt != rb_snd_una) &&\\n"
    "                            !fin_sent_r[scan_id] && !rst_sent_r[scan_id];",
    "    wire        ps_arm    = PERSIST_EN && scan_now && scan_estab &&\\n"
    "                            (rb_snd_wnd == 16'd0) && (rb_snd_nxt != rb_snd_una) &&\\n"
    "                            !rst_sent_r[scan_id];",
    1)], "PS-MUT-1 撤 !fin_sent_r => E5 冒出探询 => j12 红")

# ---- PS-MUT-2: 删掉武装条件里的 !rst_sent_r[scan_id] (v3 #6 的 RST 角) ----
add("mut_ps_noarmrst", [(
    "    wire        ps_arm    = PERSIST_EN && scan_now && scan_estab &&\\n"
    "                            (rb_snd_wnd == 16'd0) && (rb_snd_nxt != rb_snd_una) &&\\n"
    "                            !fin_sent_r[scan_id] && !rst_sent_r[scan_id];",
    "    wire        ps_arm    = PERSIST_EN && scan_now && scan_estab &&\\n"
    "                            (rb_snd_wnd == 16'd0) && (rb_snd_nxt != rb_snd_una) &&\\n"
    "                            !fin_sent_r[scan_id];",
    1)], "PS-MUT-2 撤 !rst_sent_r => E6' 冒出探询 => j12 红")

# ---- PS-MUT-3: 探询槽上线条件里删掉 ds_guard (v3 #1 / REVIEW2 blocking #1) ----
#   判据 (j13/j14, **多连接**): E7 相撞窗内不得出现跨连接数据帧。
#   [!] 单连接 (A==B) 时自洽 => 该变异**只有多连接臂能抓** (本轮的 H2 欠账)。
add("mut_ps_nodsg", [(
    "    wire        probe_sel = ps_stage_rdy && ps_stage_estab && rx_idle && !rx_flush &&\\n"
    "                            !ctrl_slot_busy && ackq_empty &&\\n"
    "                            !svc && !ring_eval && !scan_now && !retx_active && ds_guard;",
    "    wire        probe_sel = ps_stage_rdy && ps_stage_estab && rx_idle && !rx_flush &&\\n"
    "                            !ctrl_slot_busy && ackq_empty &&\\n"
    "                            !svc && !ring_eval && !scan_now && !retx_active;",
    1)], "PS-MUT-3 撤 ds_guard => E7 相撞 => 跨连接数据帧 => j13 红")

'''
a = "def norm(s):"
assert t.count(a) == 1
t = t.replace(a, PS_BLOCK.lstrip("\n") + a)

io.open(p, "w", encoding="utf-8", newline="").write(
    t.replace("\n", "\r\n") if is_crlf else t)
print("written; crlf =", is_crlf)
