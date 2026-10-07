# apply_script_updates.py -- P7B-BIZ: 把"窗口 55 -> 57 / 未实现地址 -> 0x104"同步到现役脚本
#   一次性脚本 (跑完留着当账); 每个替换都断言"原文命中", 不命中就整体退出 (不半改)。
import io, re, sys

def sub(p, pairs):
    s = io.open(p, encoding='utf-8', newline='').read()
    for a, b in pairs:
        if a not in s:
            sys.exit("MISS in %s: %s" % (p, a[:70]))
        s = s.replace(a, b)
    io.open(p, 'w', encoding='utf-8', newline='').write(s)
    print("ok", p)

# ---- 硬守卫 (2026-10-07 "台架修复轮" 加) -------------------------------------------
# ⚠️ 本件是**历史一次性补丁生成器** (窗口 55 -> 57 那一代; 55 从未出厂)。重跑它会把
#    旧一代的几何/文案贴回**现役验收脚本** (静默回退), 且 `sub()` 逐文件落盘 ⇒
#    可能留下**半改**状态。⇒ 先核 pre-state, 不符就拒绝 (exit 3), 不写任何文件。
def _guard_prestate():
    w = 'board/wrapper_p4.v'
    s = io.open(w, encoding='utf-8', newline='').read()
    m = re.search(r'localparam\s+SNAP_NW_P6E\s*=\s*(\d+)\s*;', s)
    got = int(m.group(1)) if m else -1
    if got != 55:
        sys.stderr.write(
            "GUARD_REFUSE: %s 的 SNAP_NW_P6E = %s (期望 pre-state = 55).\n"
            "  本脚本只适用于窗口 55 -> 57 那一代 (55 从未出厂); 现役窗口已不是那一代\n"
            "  => 拒绝执行, 未写任何文件 (防止把旧一代几何贴回现役脚本).\n"
            "  如确要重跑历史件, 请在**临时 worktree** 里 checkout 对应 revision 再跑.\n"
            % (w, got))
        sys.exit(3)
_guard_prestate()

# 1) 闸 4 验收脚本
sub('_proj_pcie/p7b_gate4_accept.sh', [
 ("# p7b_gate4_accept.sh — **P7b 闸 4 板级验收** (板侧 55 字 + NIC 侧网关判据)",
  "# p7b_gate4_accept.sh — **P7b 闸 4 板级验收** (板侧 57 字 + NIC 侧网关判据)"),
 ("#   ① 闸 4 的几何是 **55 字** (0x20..0xF8, 未实现 = 0xFC) —— P7B-BIZ 从 51 字扩来",
  "#   ① 闸 4 的几何是 **57 字** (0x20..0x100, 未实现 = **0x104**) —— P7B-BIZ 从 51 字扩来"),
 ("#      ⭐ **P7B-BIZ 的 4 个新字** (RTL 真值源 = `board/wrapper_p4.v` 的 `snap_dout_all`,\n"
  "#         装配项逐条带槽号注释; 全是 dp 域寄存器输出, 与 W39/W45..W50 同一束):\n"
  "#         `W51` = `app_pattern.stat_tx_bytes`  (TCP 演示 app **下行**载荷字节)\n"
  "#         `W52` = `app_pattern.stat_rx_bytes`  (TCP 演示 app **上行**载荷字节) → 判据 J13\n"
  "#         `W53` = `app_pattern.stat_mismatch`  (**上行载荷逐字节**失配数, 增量必须 = 0) → J12\n"
  "#         `W54` = `tcp_tx_frame.stat_retx`     (重传/RTO 回卷次数, 增量必须 = 0) → J14 / `F5b`\n"
  "#         ⚠️ 非 `APP_MODE` 构建里 W51..W53 **恒 0** (源模块不存在) 而 **W54 仍是真值**\n"
  "#            (`tcp_tx_frame` 在任何构建里都例化) —— 读到 0 要先确认构建宏, 别当\"没重传\"。",
  "#      ⭐ **P7B-BIZ 的 6 个新字** (RTL 真值源 = `board/wrapper_p4.v` 的 `snap_dout_all`,\n"
  "#         装配项逐条带槽号注释; 全是 dp 域寄存器输出, 与 W39/W45..W50 同一束):\n"
  "#         `W51` = `app_pattern.stat_tx_bytes`   (TCP 演示 app **下行**载荷字节)\n"
  "#         `W52` = `app_pattern.stat_tx_frames`  (TCP 下行载荷帧数; 几何账)\n"
  "#         `W53` = `app_pattern.stat_rx_bytes`   (TCP 演示 app **上行**载荷字节) → 判据 J13\n"
  "#         `W54` = `app_pattern.stat_mismatch`   (**上行载荷逐字节**失配, 增量必须 = 0) → J12\n"
  "#         `W55` = `tcp_tx_frame.stat_retx`      (重传/RTO 回卷次数, 增量必须 = 0) → J14 / `F5b`\n"
  "#         `W56` = `app_udp_pattern.stat_tx_ovf` (TX 字 FIFO 拒写; 静默丢字类回归的守卫)\n"
  "#         ⚠️ 非 `APP_MODE` 构建里 W51..W54 / W56 **恒 0** (源模块不存在) 而 **W55 仍是真值**\n"
  "#            (`tcp_tx_frame` 在任何构建里都例化) —— 读到 0 要先确认构建宏, 别当\"没重传\"。\n"
  "#      ⚠️ **窗口为什么能从 51 一步到 57 (越过旧 56 上限)**: 读侧地址译码 `ar_word` 从 6 位\n"
  "#         加宽到 7 位 (araddr[8:2]) ⇒ 未实现地址域扩到 0x104..0x1FC, 窗口上限抬到 119 字;\n"
  "#         < 0x100 的既有地址逐位等价 (零回归)。见 `_proj_pcie/rtl/axi_regs.v` 头部注释。"),
 ("#   开关: G4_BIT=<位流路径> · EXPECT_BID=0x... · SNAP_WORDS=55 · G4_IFACE=enp1s0f1np1\n"
  "#         ⚠️ P7B-BIZ 起窗口 = **55 字** (RTL `board/wrapper_p4.v` 的 `SNAP_NW_P6E`);",
  "#   开关: G4_BIT=<位流路径> · EXPECT_BID=0x... · SNAP_WORDS=57 · G4_IFACE=enp1s0f1np1\n"
  "#         ⚠️ P7B-BIZ 起窗口 = **57 字** (RTL `board/wrapper_p4.v` 的 `SNAP_NW_P6E`);"),
 ("SNAP_WORDS=${SNAP_WORDS:-55}\n"
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 55 ⇒ 0xFC (51 ⇒ 0xEC)\n"
  "# ⚠️ 未实现地址 = 0x20 + 4*SNAP_WORDS 只在 **SNAP_WORDS ≤ 55** 时成立 —— 56 会算出 0x100,\n"
  "#    而读侧 `ar_word = araddr[7:2]` 只有 6 位 ⇒ 地址每 256 字节回绕 ⇒ `rd 0x100` 别名回\n"
  "#    word 0 = MAGIC ⇒ **判据要么假 FAIL 要么(若放宽)变成假 PASS**。这正是 RTL 把窗口\n"
  "#    定为 55 而不是 56 (= 硬上限) 的原因: word 63 = 0xFC 必须留空当负对照地址。",
  "SNAP_WORDS=${SNAP_WORDS:-57}\n"
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 57 ⇒ 0x104 (51 ⇒ 0xEC)\n"
  "# ⚠️ 未实现地址 = 0x20 + 4*SNAP_WORDS 这条公式本轮**重新成立**: 读侧译码已加宽到 7 位\n"
  "#    (araddr[8:2]) ⇒ 地址每 **512** 字节才回绕, 而 `0x20+4*57 = 0x104` 真正未实现 ⇒\n"
  "#    仍回 0xffffffff。红线随之改成\"**绝不能挑 ≥0x200**\" (旧红线是 ≥0x100)。"),
 ("#   · P7B_10G 构建 (默认几何 55 字 / BID=7): 前端域 = PCS 的 CDR **恢复钟**",
  "#   · P7B_10G 构建 (默认几何 57 字 / BID=7): 前端域 = PCS 的 CDR **恢复钟**"),
])

# 2) 36/51/55 字时代的窗口快检 (共用几何)
sub('_proj_pcie/p6e_snap_check.sh', [
 ("#        W0..W54 (0x20..0xF8), 重复项结构性不可能再出现。",
  "#        W0..W56 (0x20..0x100), 重复项结构性不可能再出现。"),
 ('#     ② "未实现地址" 0xB0 → **0xEC** (51 字) → **0xFC** (P7B-BIZ 55 字; = 0x20 + 4*55)。',
  '#     ② "未实现地址" 0xB0 → 0xEC (51 字) → **0x104** (P7B-BIZ 57 字; = 0x20 + 4*57)。'),
 ("#              ⚠️ P7B-BIZ 起窗口 = **55 字** (RTL 当前值) ⇒ 读 51 字位流要显式覆盖 SNAP_WORDS=51",
  "#              ⚠️ P7B-BIZ 起窗口 = **57 字** (RTL 当前值) ⇒ 读 51 字位流要显式覆盖 SNAP_WORDS=51"),
 ("#    55 = **P7B-BIZ** (`wrapper_p4.v` 的 `SNAP_NW_P6E = 55`; 0x20..0xF8, 未实现 0xFC);",
  "#    57 = **P7B-BIZ** (`wrapper_p4.v` 的 `SNAP_NW_P6E = 57`; 0x20..0x100, 未实现 0x104);"),
 ("#    ⚠️ **未实现地址 = word 63 = 0xFC 是\"故意留空\"的**: 窗口最大只能到 55 字 —— 56 会\n"
  "#       把最后一个 word 也占掉 ⇒ 读侧 SLVERR 负对照 (判据 6) **结构性失效**, 而\n"
  "#       `0x20+4*56 = 0x100` 又绕过 `ar_word` 的 6 位 ⇒ 回绕别名 (见判据 6 的注释)。",
  "#    ⚠️ **未实现地址必须存在**: 它撑起读侧 SLVERR 负对照 (判据 6)。本轮把读侧译码\n"
  "#       从 6 位加宽到 7 位 (`_proj_pcie/rtl/axi_regs.v`) ⇒ 地址每 512 字节才回绕,\n"
  "#       `0x104` (word 65) 真正未实现 ✓; 红线 = **绝不能挑 ≥0x200** (旧红线是 ≥0x100)。"),
 ("SNAP_WORDS=${SNAP_WORDS:-55}\n"
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 55 ⇒ 0xFC (51 ⇒ 0xEC)",
  "SNAP_WORDS=${SNAP_WORDS:-57}\n"
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 57 ⇒ 0x104 (51 ⇒ 0xEC)"),
 ("# ⚠️ 这个\"未实现地址\"随地图扩张挪过: 0x18 -> 0x44 -> 0x60 -> 0x84 -> 0xB0 -> 0xEC -> **0xFC**\n"
  "#    (**55 字**把 0x20..0xF8 全占了 = word 8..62 ⇒ 第一个空地址 = word 63 = 0xFC;\n"
  "#     再往前一步 (56 字) 就**没有空地址了** ⇒ 本条判据只能删掉, 所以 RTL 钉在 55)。",
  "# ⚠️ 这个\"未实现地址\"随地图扩张挪过: 0x18 -> 0x44 -> 0x60 -> 0x84 -> 0xB0 -> 0xEC -> 0xFC -> **0x104**\n"
  "#    (**57 字**把 0x20..0x100 全占了 = word 8..64 ⇒ 第一个空地址 = word 65 = 0x104;\n"
  "#     本轮把读侧译码加宽到 7 位, 所以\"第一个空地址\"不会再撞上回绕别名)。"),
 ("#   · **P7B_10G 构建** (本脚本默认几何 55 字 / EXPECT_BID=7): 前端域 = PCS 的 CDR **恢复钟**",
  "#   · **P7B_10G 构建** (本脚本默认几何 57 字 / EXPECT_BID=7): 前端域 = PCS 的 CDR **恢复钟**"),
])

# 3) 假板子自证脚本
sub('_proj_pcie/p7b_gate4_selftest.sh', [
 ("#        ⚠️ 几何**由 `SNAP_WORDS` 派生** (默认 55 = P7B-BIZ; 55 ⇒ 末字 0xF8 / 未实现 0xFC);",
  "#        ⚠️ 几何**由 `SNAP_WORDS` 派生** (默认 57 = P7B-BIZ; 57 ⇒ 末字 0x100 / 未实现 0x104);"),
 ("#   默认 55 = P7B-BIZ (`board/wrapper_p4.v` 的 `SNAP_NW_P6E`); 跑 51 字旧位流: SNAP_WORDS=51。",
  "#   默认 57 = P7B-BIZ (`board/wrapper_p4.v` 的 `SNAP_NW_P6E`); 跑 51 字旧位流: SNAP_WORDS=51。"),
 ("SW=${SNAP_WORDS:-55}\nLAST_A=$(printf '0X%X' $(( 0x20 + 4*(SW-1) )))   # 末字地址  (55 ⇒ 0XF8)",
  "SW=${SNAP_WORDS:-57}\nLAST_A=$(printf '0X%X' $(( 0x20 + 4*(SW-1) )))   # 末字地址  (57 ⇒ 0X100)"),
 ("UNIMPL_A=$(printf '0X%X' $(( 0x20 + 4*SW )))      # 未实现地址 (55 ⇒ 0XFC)",
  "UNIMPL_A=$(printf '0X%X' $(( 0x20 + 4*SW )))      # 未实现地址 (57 ⇒ 0X104)"),
])

# 4) BIZ 取数器
sub('_proj_pcie/p7b_biz/p7b_snap.sh', [
 ("# p7b_snap.sh -- 板侧 55 字快照窗口的取数器 (P7B-BIZ: BID=7 (合体后 8) / SNAP_NW=55)",
  "# p7b_snap.sh -- 板侧 57 字快照窗口的取数器 (P7B-BIZ: BID=7 (合体后 8) / SNAP_NW=57)"),
 ("#   ⭐ P7B-BIZ 新增 4 字: W51 app_tx_bytes / W52 app_rx_bytes / W53 app_mismatch / W54 tx_stat_retx",
  "#   ⭐ P7B-BIZ 新增 6 字:\n"
  "#      W51 app_tx_bytes / W52 app_tx_frames / W53 app_rx_bytes /\n"
  "#      W54 app_mismatch / W55 tx_stat_retx / W56 app_udp_pattern.stat_tx_ovf"),
 ("#   bash p7b_snap.sh full TAG                # 触发一次 + 打全 55 字 (带名字)",
  "#   bash p7b_snap.sh full TAG                # 触发一次 + 打全 57 字 (带名字)"),
 ("#   ⚠️ **NW 上限 = 55**: 56 会把最后一个 word (0xFC) 也占掉 ⇒ 本脚本的\n"
  "#      `ID_UNIMPL` 负对照**结构性失效**; 而 0x20+4*56 = 0x100 会回绕到 word 0 = MAGIC\n"
  "#      (ar_word 只有 6 位) ⇒ 假 FAIL。见 board/wrapper_p4.v 的窗口预算注释。\n"
  "NW=${NW:-55}\n"
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*NW )))}   # 55 ⇒ 0xFC (51 ⇒ 0xEC)",
  "#   ⚠️ **NW 上限 = 119** (读侧译码 7 位 ⇒ 字 0..127; 快照从字 8 起; 负对照需留 1 个空字)。\n"
  "#      红线随之从\"≥ 0x100 回绕\" 改成 **\"绝不能挑 ≥ 0x200\"**\n"
  "#      (0x200 在 7 位译码下回绕到 word 0 = MAGIC ⇒ 假 FAIL)。\n"
  "NW=${NW:-57}\n"
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*NW )))}   # 57 ⇒ 0x104 (51 ⇒ 0xEC)"),
])

# 5) 收尾读数脚本 (P7b 时代那份)
sub('_proj_10g/notes/p7b_gate4_3/final_state.sh', [
 ('UNIMPL=$(rd 0xFC) gen=$(( (s >> 16) & 0xffff ))"',
  'UNIMPL=$(rd 0x104) gen=$(( (s >> 16) & 0xffff ))"'),
 ("# ⚠️ UNIMPL 地址跟窗口宽度走: 55 字 (P7B-BIZ 起) ⇒ 0xFC; 51 字位流 ⇒ 0xEC。\n"
  "#    绝不能用 0x100 —— 读侧 ar_word 只有 6 位, 地址每 256 字节回绕 ⇒ 0x100 别名回 MAGIC。",
  "# ⚠️ UNIMPL 地址跟窗口宽度走: **57 字 (P7B-BIZ 起) ⇒ 0x104**; 51 字位流 ⇒ 0xEC。\n"
  "#    绝不能用 ≥0x200 —— 读侧 ar_word 7 位, 地址每 512 字节回绕 ⇒ 0x200 别名回 MAGIC。"),
 ('echo "W51=$(rd 0xec) W52=$(rd 0xf0) W53=$(rd 0xf4) W54=$(rd 0xf8)   # P7B-BIZ: app tx/rx/mismatch + retx"',
  'echo "W51=$(rd 0xec) W52=$(rd 0xf0) W53=$(rd 0xf4) W54=$(rd 0xf8) W55=$(rd 0xfc) W56=$(rd 0x100)  # P7B-BIZ 六字"'),
])

# 6) P6b 验收脚本的注释 (它自己保持 36 字口径, 只更新"现役几何"提示)
sub('_proj_pcie/p6b_accept.sh', [
 ("#   **P7B-BIZ 的 55 字**占 0x20..0xF8 ⇒ 未实现 = **0xFC**",
  "#   **P7B-BIZ 的 57 字**占 0x20..0x100 ⇒ 未实现 = **0x104**"),
 ("#   ⚠️ **55 是可用最大值** —— 56 会把 word 63 也占掉 ⇒ 读侧 SLVERR 负对照结构性失效,\n"
  "#      而 0x20+4*56 = 0x100 又因 `ar_word` 只有 6 位而回绕别名 (见 wrapper 的窗口预算注释)。",
  "#   ⚠️ **P7B-BIZ 把读侧译码从 6 位加宽到 7 位** (`ar_word = araddr[8:2]`) ⇒ 窗口上限\n"
  "#      从 56 抬到 119, 未实现地址可行域 = 0x104..0x1FC (红线: 绝不能挑 ≥0x200)。"),
 ("#   **P7B-BIZ 55 字 = max {54,5'b0} = 1728 ⇒ 同一个 `[11:0]` 仍够, 本轮未动这一行**。",
  "#   **P7B-BIZ 57 字 = max {56,5'b0} = 1792 ⇒ 同一个 `[11:0]` 仍够, 本轮未动这一行**。"),
])
print("ALL OK")
