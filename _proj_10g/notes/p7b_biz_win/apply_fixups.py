# apply_fixups.py -- P7B-BIZ 收尾修补 (由"假板子自证"暴露出来的三处)
#   ① W51..W56 的**标签**缺失 ⇒ 板级读数的表里会是 <无标签> (可读性) -> 补 WLABEL
#   ② 表行数判据的正则只认 **2 位十六进制地址** ⇒ 0x100/0x104 (3 位) 匹配不上
#      (这是被"窗口跨过 0xFF"逼出来的**工具缺陷**, 不是设计问题)
#   ③ 表里印出末字的断言用了大写 `0X100`, 而表里印的是小写 `0x100` ⇒ 逐字不符
import io, re, sys

def sub(p, pairs):
    s = io.open(p, encoding='utf-8', newline='').read()
    for a, b in pairs:
        if a not in s:
            sys.exit("MISS in %s: %s" % (p, a[:70]))
        s = s.replace(a, b)
    io.open(p, 'w', encoding='utf-8', newline='').write(s)
    print("ok", p)

# ---- 硬守卫 (2026-10-07 "台架修复轮" 加; 与 apply_c.py 同款, pre-state = 57) --------
# ⚠️ 本件是**历史一次性补丁生成器** (窗口 57 字那一代的收尾修补)。重跑它会把旧一代
#    的文本贴回现役脚本 (静默回退), 且 `sub()` 逐文件落盘 ⇒ 可能留下**半改**状态。
#    ⇒ 先核 pre-state, 不符就拒绝 (exit 3), 不写任何文件。
def _guard_prestate():
    w = 'board/wrapper_p4.v'
    s = io.open(w, encoding='utf-8', newline='').read()
    m = re.search(r'localparam\s+SNAP_NW_P6E\s*=\s*(\d+)\s*;', s)
    got = int(m.group(1)) if m else -1
    if got != 57:
        sys.stderr.write(
            "GUARD_REFUSE: %s 的 SNAP_NW_P6E = %s (期望 pre-state = 57).\n"
            "  本脚本只适用于窗口 57 字那一代; 现役窗口已不是那一代\n"
            "  => 拒绝执行, 未写任何文件 (防止把旧一代文本贴回现役件).\n"
            "  如确要重跑历史件, 请在**临时 worktree** 里 checkout 对应 revision 再跑.\n"
            % (w, got))
        sys.exit(3)
_guard_prestate()

# ① 标签: p6e_snap_check.sh 的 WLABEL 数组末尾补 6 项 (顺序 = 字序)
sub('_proj_pcie/p6e_snap_check.sh', [
 (' "tx_clk_act         (TX 域 toggle 沿数 ⭐G2 = 频率×2)" )',
  ' "tx_clk_act         (TX 域 toggle 沿数 ⭐G2 = 频率×2)"\n'
  ' # ---- P7B-BIZ 新增 6 字 (全是 dp 域寄存器输出) ----\n'
  ' "app_tx_bytes       (TCP 演示 app TX 载荷字节)"\n'
  ' "app_tx_frames      (TCP 演示 app TX 载荷帧数)"\n'
  ' "app_rx_bytes       (TCP 演示 app RX 载荷字节)"\n'
  ' "app_mismatch       (载荷逐字节失配 ⭐必须恒 0 增量)"\n'
  ' "tx_stat_retx       (TCP 重传/RTO 回卷次数 ⭐必须恒 0 增量,F5b)"\n'
  ' "udpapp_tx_ovf      (UDP app TX 字 FIFO 拒写 ⭐必须恒 0,丢字类回归守卫)" )'),
 # (②③ 那两条在自证脚本里, 不在本文件)
])

# ② + ③ 都在自证脚本里
sub('_proj_pcie/p7b_gate4_selftest.sh', [
 ('ck "section5 表格行数" "$(grep -cE \'^  W[0-9]+ +0x[0-9A-F]{2} \' "$W/good.log")" "$SW"',
  '# ⚠️ 正则要容忍 **2 或 3 位**地址: 窗口跨过 0xFF 以后, W56 的地址是 `0x100`\n'
  '#    (旧版写死 `{2}` ⇒ 末字行数不入表, 行数少 1 —— 被本轮假板子自证当场抓到)\n'
  'ck "section5 表格行数" "$(grep -cE \'^  W[0-9]+ +0x[0-9A-F]{2,3} \' "$W/good.log")" "$SW"'),
 ('ckc "section5 表里印出 W$((SW-1))" "W$((SW-1))  $LAST_A" "$W/good.log"',
  '# ⚠️ 表里印的是**小写** `0x100`; `$LAST_A` 是**大写** (`0X100`, 用于 addrlog) ⇒ 两者不能互用\n'
  'ckc "section5 表里印出 W$((SW-1))" "W$((SW-1))  $(printf \'0x%X\' $(( 0x20 + 4*(SW-1) )))" "$W/good.log"'),
])
print("ALL OK")
