#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P7B 读侧 **BID 默认值同步器**（参数化; 目标 = 阶段链的末代）。

  `--bid 0x1C`（缺省）: 阶段 ①  **0x1A → 0x1C**（缺陷刀 / RETXHI-GHOST 重放越界修复）
  `--bid 0x1D`        : 阶段 ②  **0x1C → 0x1D**（persist 刀）—— old 侧 = 阶段 ① 的 new 侧,
                        必须**链式**应用（`--rehearse` 会在内存里自动把前置阶段一起做掉）。

  两个阶段都是 **BID-only**（与 F 轮不同: 这两刀**都不加字**）:
    · 快照字长      **不变** = 70  (`SNAP_NW_P6E`, 权威源现读)
    · 未实现地址    **不变** = 0x138 (= 0x20 + 4*70)
    · 唯一变化      `BUILD_ID_V`（`board/wrapper_p4.v`）0x1A → 0x1C → 0x1D
                    ⇒ 所有"读侧默认身份"（EXPECT_BID / FAKE_BID / BID_FIX / 假板子 / 假对端 / 档表 /
                       sim TB 期望值）必须同批跟上; 字长/地址**一律不动**。
    · 档表特例: **70 字那一代现在能有多行**（`70|0x0000001D` persist / `70|0x0000001C` 缺陷刀 /
      `70|0x0000001A` 构建 F）⇒ 每代**加一行**, 旧行**逐字保留**（同几何、不同身份的并列档）。

  ⚠️ 目标值**不从权威源推导**: `board/wrapper_p4.v` 会被构建 agent 改（读到"改前/改中/改后"都可能）⇒
     `--bid` **显式钉死**（缺省 0x1C = 2026-10-11 现状兼容）; 权威源只用来读 **NW / 未实现地址**,
     并在与目标不一致时打**警告行**（不是 FAIL）。
  ⚠️ 模式与 F 轮相反: **默认 = dry-run**（只报"命中数 vs 断言值"）; 要落盘必须**显式** `--apply`,
     且 `--apply --bid 0x1D` 要求阶段 ① **已经落盘**（脚本只落最后一阶段）。
  ⚠️ 历史教训（F 轮自述"五处只改三处"）: 清单**逐处列出**、每条带**命中数断言**, 不做任何通配替换。
     引用行号一律**现读**（本文件不写死行号, 只在注释里给"现读行号"供人核对）。

  用法:  [--bid 0x1C|0x1D] [--dry-run(默认)|--apply] [--assert] [--rehearse] [--face] [--negctl=名]
"""
import io
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def rd(p):
    b = open(p, "rb").read()
    return b, (b"\r\n" if b.count(b"\r\n") else b"\n")


EDITS_1C = []          # 阶段 ①: 0x1A 树 -> 0x1C 树 (缺陷刀)
EDITS_1D = []          # 阶段 ②: 0x1C 树 -> 0x1D 树 (persist 刀); old 侧 = 阶段 ① 的 new 侧


def E1(rel, old, new, n=1):
    EDITS_1C.append((rel, old, new, n))


def E2(rel, old, new, n=1):
    EDITS_1D.append((rel, old, new, n))


EDITS_1E = []          # 阶段 ③: 0x1D 树 -> 0x1E 树 (snd_wnd 守卫; BID-only)
EDITS_1F = []          # 阶段 ④: 0x1E 树 -> 0x1F 树 (M1 镜像窗; **BID + 几何**: NW 70→71 + 未实现地址迁移)


def E3(rel, old, new, n=1):
    EDITS_1E.append((rel, old, new, n))


def E4(rel, old, new, n=1):
    EDITS_1F.append((rel, old, new, n))


# 目标 BID ⇒ 阶段链 (链上每阶段的 old 侧 = 上一阶段的 new 侧)。
# ⚠️ 列表对象身份共享 ⇒ 这里的引用能看见后面的 append (定义顺序无关)。
STAGES = [("0x0000001C", EDITS_1C, "缺陷刀 (2026-10-11)", 70, 0x138),
          ("0x0000001D", EDITS_1D, "persist 刀 (2026-10-11)", 70, 0x138),
          ("0x0000001E", EDITS_1E, "snd_wnd 守卫 (2026-10-11)", 70, 0x138),
          ("0x0000001F", EDITS_1F, "M1 镜像窗 (2026-10-11)", 71, 0x14C)]
#   ⚠️ 每个阶段带**自己的**几何 (nw, unimpl): 0x1F 起 M1 把快照扩到 71 字并在快照末字后插 4 个
#      MIR 字 (0x13C/0x140/0x144/0x148) ⇒ 未实现地址 = **0x20 + 4*NW + 16** = 0x14C (不再等于 0x20+4*NW)。
#      ⇒ 断言按**目标代**的几何比, 不按现读 wrapper (它可能已在更后的代上)。
ALL_BIDS = [b for b, _e, _n, _w, _u in STAGES]

# 已登记的历史身份 (含**不在链上**的上一代: 0x1A 是 F 轮的值, 只作为"旧值扫描/上一代"锚点)
HISTORY_BIDS = ["0x0000001A"] + ALL_BIDS

# 盘上"读侧代"的**哨兵** = j6 台架的 EXPECT_BID 默认值 (每一代都改它)。
SENTINEL = "_proj_10g/notes/p7b_affinity/j6_r6fix.sh"
SENTINEL_RX = r"(?m)^EXPECT_BID=\$\{EXPECT_BID:-0x([0-9A-Fa-f]+)\}"


def chain_for(target):
    """返回到 target 为止的阶段链 [(bid, edits, name, nw, unimpl), ...]。"""
    out = []
    for st in STAGES:
        out.append(st)
        if st[0] == target:
            return out
    raise SystemExit("不支持的 --bid: %s (支持: %s)" % (target, " / ".join(ALL_BIDS)))


def stage_of(bid):
    for st in STAGES:
        if st[0] == bid:
            return st
    raise SystemExit("未知阶段 %s" % bid)


def tree_gen(overlay=None):
    """**现读**盘上读侧的代 (哨兵 = j6 的 EXPECT_BID 默认值)。读不到 ⇒ None。"""
    s = _src(SENTINEL, overlay)
    m = re.search(SENTINEL_RX, s)
    return "0x%08X" % int(m.group(1), 16) if m else None


def stages_to_do(target, overlay=None):
    """**只剩还没落盘的阶段** (bid > 盘上代)。⚠️ 树可能被别的 agent 推过 ⇒ 不许假设"从 0x1A 起"。"""
    gen = tree_gen(overlay)
    g = int(gen, 16) if gen else -1
    return [st for st in chain_for(target) if int(st[0], 16) > g]


def predecessor_bid(target):
    """target 的上一代 (负对照/搜索面用)。⚠️ 对链上第一代 (0x1C) 要回到 0x1A ⇒ 用 HISTORY_BIDS。"""
    olds = [b for b in HISTORY_BIDS if int(b, 16) < int(target, 16)]
    return olds[-1] if olds else None


# ===========================================================================
# ① 两个 j6 台架脚本: EXPECT_BID 默认值 + GEOM_TIERS 加一行 (旧档一律保留)
#    ⚠️ 锚点按**整行**写（含行尾注释）—— 光锚 `EXPECT_BID=${EXPECT_BID:-0x0000001A}` 也能中,
#       但带上注释可以顺带把"这是哪一代"写死, 且防住未来在别处出现同名裸行。
# ===========================================================================
E1("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",                      # 现读 :76
  "EXPECT_BID=${EXPECT_BID:-0x0000001A}   # 2026-10-10 构建 F (70 字; 原 0x00000019 = 构建 E / 0x18 = 构建 D / 0x17 = 构建 C)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001C}   # 2026-10-11 缺陷刀 (70 字; 原 0x0000001A = 构建 F / 0x19 = 构建 E / 0x18 = 构建 D)", 1)
E1("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh",                   # 现读 :70
  "EXPECT_BID=${EXPECT_BID:-0x0000001A}   # 2026-10-10 构建 F (70 字; 原 0x00000019 = 构建 E / 0x18 = 构建 D / 0x09 = WU 二轮)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001C}   # 2026-10-11 缺陷刀 (70 字; 原 0x0000001A = 构建 F / 0x19 = 构建 E / 0x18 = 构建 D)", 1)
# GEOM_TIERS: 在最上面插**现役**那一行（格式照 F 轮该行: `"NW|BID|WEXTRA|label"`）;
# 旧行（同 70 字 / 0x1A）逐字保留 = 历史档, 台架仍可按档显式声明读 F 归档位流。
for f in ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",              # 现读 :82
          "_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh"):          # 现读 :77
    E1(f,
      '  "70|0x0000001A|61 62|构建 F (2026-10-10) 70 字 / BID 0x1A (W67/W68/W69 = 三个纯观测仪器)"',
      '  "70|0x0000001C|61 62|缺陷刀 (2026-10-11) 70 字 / BID 0x1C (RETXHI-GHOST 重放越界修复; 字长/未实现地址不变)"\n'
      '  "70|0x0000001A|61 62|构建 F (2026-10-10) 70 字 / BID 0x1A (W67/W68/W69 = 三个纯观测仪器)"', 1)

# ===========================================================================
# ② 取数器 p7b_snap.sh (EXPECT_BID 裸行 + 头部"现役"行 + 逐代订正块)
#    ⚠️ `EXPECT_BID=${EXPECT_BID:-0x0000001A}` 无行尾注释、全文唯一（现读 :51）。
# ===========================================================================
E1("_proj_pcie/p7b_biz/p7b_snap.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001A}",
  "EXPECT_BID=${EXPECT_BID:-0x0000001C}", 1)
E1("_proj_pcie/p7b_biz/p7b_snap.sh",                                # 现读 :2-:4
  "# p7b_snap.sh -- 板侧快照窗口取数器 (**现役 = 70 字 / BID 0x1A**; 标题原文 = \"板侧 **63** 字\n"
  "#   快照窗口的取数器 (P7b Stage C: BID=10 / SNAP_NW=63)\" —— 那一代已过时, 见下逐代订正)\n"
  "#   ⭐ 构建 F (2026-10-10): 67 → **70** (W67/W68/W69 = 三个纯观测仪器; 未实现地址 0x12C → **0x138**)。\n",
  "# p7b_snap.sh -- 板侧快照窗口取数器 (**现役 = 70 字 / BID 0x1C**; 标题原文 = \"板侧 **63** 字\n"
  "#   快照窗口的取数器 (P7b Stage C: BID=10 / SNAP_NW=63)\" —— 那一代已过时, 见下逐代订正)\n"
  "#   ⭐ 缺陷刀 (2026-10-11): 身份 0x1A → **0x1C** (**字长/未实现地址不变** = 70 字 / 0x138;\n"
  "#      RETXHI-GHOST 重放越界修复) ⇒ 70 字这一代现有**两个身份** (档表/字典按 NW 索引的件见下)。\n"
  "#   ⭐ 构建 F (2026-10-10): 67 → **70** (W67/W68/W69 = 三个纯观测仪器; 未实现地址 0x12C → **0x138**)。\n", 1)

# ===========================================================================
# ③ _proj_pcie 三个读侧验收脚本 (只动 EXPECT_BID; SNAP_WORDS/UNIMPL_ADDR 本轮**不动**)
# ===========================================================================
E1("_proj_pcie/p6e_snap_check.sh",                                  # 现读 :60
  "EXPECT_BID=${EXPECT_BID:-0x0000001A}       # ⛔ 2026-10-10 构建 F: 原默认 0x00000019 (构建 E 67 字) / 0x18 (构建 D) / 0x0A (Stage C)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001C}       # ⛔ 2026-10-11 缺陷刀: 原默认 0x0000001A (构建 F 70 字) / 0x19 (构建 E) / 0x0A (Stage C)", 1)
E1("_proj_pcie/p7b_gate4_accept.sh",                                # 现读 :131
  "EXPECT_BID=${EXPECT_BID:-0x0000001A}      # 构建 F = 0x1A (源码 board/wrapper_p4.v 的 BUILD_ID_V; 原 0x19 = 构建 E / 0x18 = 构建 D)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001C}      # 缺陷刀 = 0x1C (源码 board/wrapper_p4.v 的 BUILD_ID_V; 原 0x1A = 构建 F / 0x19 = 构建 E)", 1)

# ---- p7b_gate4_selftest.sh (假板子: FAKE_BID + "现役"注释块) ----
E1("_proj_pcie/p7b_gate4_selftest.sh",                              # 现读 :132-:134
  "  #    而\"正例必须 0 FAIL\"是本脚本的断言⑤)。现役 = **0x1A** (构建 F 70 字 —— ⛔ 2026-10-10 同步轮: 原 0x19 = 构建 E 67 字 /\n"
  "  #    原句 = 现役 17 (构建 C 65 字) / 10 (P7b Stage C) / 更早 9 (P7B-WU 二轮)); 跑旧口径时 FAKE_BID=0x00000017 /\n"
  "  #    0x0000000A / 0x00000009 / 0x00000008 (与 SNAP_WORDS=65/63 一起用)。\n",
  "  #    而\"正例必须 0 FAIL\"是本脚本的断言⑤)。现役 = **0x1C** (缺陷刀 70 字 —— ⛔ 2026-10-11 同步轮: 原 0x1A = 构建 F /\n"
  "  #    0x19 = 构建 E 67 字 / 原句 = 现役 17 (构建 C 65 字) / 10 (P7b Stage C) / 更早 9 (P7B-WU 二轮)); 跑旧口径时\n"
  "  #    FAKE_BID=0x0000001A (构建 F; SNAP_WORDS=70) / 0x00000017 / 0x0000000A / 0x00000009 / 0x00000008 (与 SNAP_WORDS=65/63 一起用)。\n", 1)
E1("_proj_pcie/p7b_gate4_selftest.sh",                              # 现读 :137
  "  0X04) V=\\${FAKE_BID:-0x0000001A};;\n",
  "  0X04) V=\\${FAKE_BID:-0x0000001C};;\n", 1)

# ---- p7b_gate4_negctrl.sh (合成夹具: 几何行 + BID echo) ----
E1("_proj_pcie/p7b_gate4_negctrl.sh",                               # 现读 :31
  "# 几何: **70 字 (W0..W69)** —— 构建 F (2026-10-10, BID=0x1A / 未实现 0x138);\n",
  "# 几何: **70 字 (W0..W69)** —— 缺陷刀 (2026-10-11, BID=0x1C / 未实现 0x138);\n"
  "#       (原句: \"70 字 (W0..W69) —— 构建 F (2026-10-10, BID=0x1A / 未实现 0x138)\" = 历史代, 逐字保留于下)\n", 1)
E1("_proj_pcie/p7b_gate4_negctrl.sh",                               # 现读 :58
  '    echo "MAGIC 0x50360001"; echo "BID 0x0000001A"; echo "MARKER 0xdeadbeef"   # 构建 F: 原 0x19 = 构建 E / 0x18 = 构建 D / 0x0A = Stage C',
  '    echo "MAGIC 0x50360001"; echo "BID 0x0000001C"; echo "MARKER 0xdeadbeef"   # 缺陷刀: 原 0x1A = 构建 F / 0x19 = 构建 E / 0x0A = Stage C', 1)

# ---- p7b_gate4_livefake.sh (假对端: bid 字典 + 兜底值) ----
#    ⚠️ 字典按 **NW** 索引 ⇒ 70 字那一代只能装**现役**那一个身份。构建 F 的 0x1A 落在
#       同槽的历史位 ⇒ 读 F 归档位流时本假对端必须配套（或整条覆盖）。
E1("_proj_pcie/p7b_gate4_livefake.sh",                              # 现读 :118
  "    #   ⛔ 2026-10-10 (构建 F): 加 **70 字那一代 = 0x1A**; 兜底值同改 0x1A (现役代)。\n",
  "    #   ⛔ 2026-10-10 (构建 F): 加 **70 字那一代 = 0x1A**。\n"
  "    #   ⛔ 2026-10-11 (缺陷刀): 70 字那一代的**身份** 0x1A → **0x1C** (字长没动 ⇒ 槽号仍是 70);\n"
  "    #      兜底值同改 0x1C (现役代)。⚠️ 本字典**按 NW 索引** ⇒ 读构建 F 归档位流 (70 字/0x1A) 时\n"
  "    #      本假对端需配套回改, 否则整台在 G1 身份上假红。\n", 1)
E1("_proj_pcie/p7b_gate4_livefake.sh",                              # 现读 :119
  '    bid = {70: "0x0000001A", 67: "0x00000019", 66: "0x00000018", 65: "0x00000017", 63: "0x0000000A", 61: "0x00000008", 51: "0x00000007"}.get(nw, "0x0000001A")',
  '    bid = {70: "0x0000001C", 67: "0x00000019", 66: "0x00000018", 65: "0x00000017", 63: "0x0000000A", 61: "0x00000008", 51: "0x00000007"}.get(nw, "0x0000001C")', 1)

# ---- p6e_snap_selftest_fix2.sh (假板子: FAKE_BID) ----
E1("_proj_pcie/p6e_snap_selftest_fix2.sh",                          # 现读 :77
  "  0X04) V=\\${FAKE_BID:-0x0000001A};;   # 构建 F = 0x1A (⛔ 原 0x19 = 构建 E / 0x18 = 构建 D / 0x0A = Stage C);",
  "  0X04) V=\\${FAKE_BID:-0x0000001C};;   # 缺陷刀 = 0x1C (⛔ 原 0x1A = 构建 F / 0x19 = 构建 E / 0x0A = Stage C);", 1)

# ===========================================================================
# ④ final_state.sh (EXPECT_BID)
# ===========================================================================
E1("_proj_10g/notes/p7b_gate4_3/final_state.sh",                    # 现读 :29
  "EXPECT_BID=${EXPECT_BID:-0x0000001A}   # ⛔ 2026-10-10 构建 F (70 字); 原 0x17 = 构建 C",
  "EXPECT_BID=${EXPECT_BID:-0x0000001C}   # ⛔ 2026-10-11 缺陷刀 (70 字); 原 0x1A = 构建 F", 1)

# ===========================================================================
# ⑤ 反例台架夹具 gen_inputs.py (几何 docstring / 逐代链 / BID_FIX)
#    ⚠️ 它自带 `_geo_guard`: 几何+身份与 accept 默认不同代 ⇒ **响亮失败 (exit 3 + 零文件)**
#       ⇒ 必须与 ③ 同批改, 否则"夹具跑不起来"看着像板子问题。
# ===========================================================================
E1("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",              # 现读 :10-:11
  "         ⚠️ 几何 = **70 字 / BID 0x1A** (P7b 构建 F, 2026-10-10 同步轮从 67 字/BID 0x19 同步)\n"
  "            ⛔ 2026-10-10 构建 F 同步: 上一行原写 \"几何 = 67 字 / BID 0x19 (构建 E)\";\n",
  "         ⚠️ 几何 = **70 字 / BID 0x1C** (P7b 缺陷刀, 2026-10-11 同步轮从 70 字/BID 0x1A 同步)\n"
  "            ⛔ 2026-10-11 缺陷刀同步: 上一行原写 \"几何 = 70 字 / BID 0x1A (P7b 构建 F)\";\n"
  "            ⛔ 2026-10-10 构建 F 同步: 那一行的上一行原写 \"几何 = 67 字 / BID 0x19 (构建 E)\";\n", 1)
E1("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",              # 现读 :39
  "# 现应读作 \"不同代 ⇒ 假红\": 本夹具现 = **70 字 / BID 0x1A**, accept 默认也已是 70 字 / BID 0x1A\n",
  "# 现应读作 \"不同代 ⇒ 假红\": 本夹具现 = **70 字 / BID 0x1C**, accept 默认也已是 70 字 / BID 0x1C\n", 1)
E1("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",              # 现读 :41
  "# 66 字/0x18 (构建 D) → 67 字/0x19 (构建 E) → **70 字/0x1A (构建 F, 未实现地址 0x138)**。\n",
  "# 66 字/0x18 (构建 D) → 67 字/0x19 (构建 E) → 70 字/0x1A (构建 F) → **70 字/0x1C (缺陷刀, 未实现地址 0x138 不变)**。\n", 1)
E1("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",              # 现读 :43
  "BID_FIX = 0x0000001A       # 位流身份 (P7b 构建 F) —— ⛔ 2026-10-10: 原值 0x00000019 (构建 E)",
  "BID_FIX = 0x0000001C       # 位流身份 (P7b 缺陷刀) —— ⛔ 2026-10-11: 原值 0x0000001A (构建 F)", 1)

# ===========================================================================
# ⑥ sim 侧两个 TB 的 BUILD_ID 期望值 (未实现地址 0x138 本轮**不动**)
# ===========================================================================
E1("sim/p6e_pcie/tb_p6e_pcie_counters.v",                           # 现读 :206
  "chk(\"0b BUILD_ID (构建 F 70-word = 0x1A; 原 67-word=0x19 / 66-word=0x18 / 63-word=9)\", v, 32'h0000001A);",
  "chk(\"0b BUILD_ID (缺陷刀 70-word = 0x1C; 原 70-word=0x1A(构建 F) / 67-word=0x19 / 63-word=9)\", v, 32'h0000001C);", 1)
E1("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",                            # 现读 :149
  "chk(\"2  BUILD_ID (构建 F 70 字=0x1A; 原 67 字=0x19 / 66 字=0x18 / 63 字=9)\", v, 32'h0000001A);",
  "chk(\"2  BUILD_ID (缺陷刀 70 字=0x1C; 原 70 字=0x1A(构建 F) / 67 字=0x19 / 63 字=9)\", v, 32'h0000001C);", 1)

# ===========================================================================
# ⑦ 上一轮(A3 负对照轮)的档位自检脚本 —— 它描述的是**现役缺省档**
#    (C-a 那条命令 `bash $SREAD id` 不带任何覆盖 ⇒ 用的就是 p7b_snap.sh 的默认值)
#    ⇒ 默认档随 ② 改代, 这里的文字必须同批跟上, 否则"自检说明"与实际行为不符。
#    ⚠️ 同目录的 `burn_arm.sh` **不改**: 它的 `BIE` 是绑**具体位流**的（E 臂烧的
#       `p7b_buildE_build/E/wrapper_p4.bit` = sha b88b2bee… = 构建 E = 0x19/67 字,
#       而 F 轮把该行的 BIE 改成了 0x1A ⇒ 现况已是"半代"）⇒ 再往上叠 0x1C 只会更错;
#       正确处置 = 把那一行**退回 0x00000019/67**（或整臂重指）, 属另一件事, 见 REPORT.md。
# ===========================================================================
E1("_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh",     # 现读 :4
  "#     (i)  缺省档 (NW=70 / 0x138 / BID 0x1A) 对 D **响亮失败** (且失败点只在 BID = 档位错, 不是板错);",
  "#     (i)  缺省档 (NW=70 / 0x138 / BID 0x1C) 对 D **响亮失败** (且失败点只在 BID = 档位错, 不是板错);", 1)
E1("_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh",     # 现读 :46
  'echo "### C-a) 默认档 (NW=70 / 0x138 / BID 0x1A) —— 对 D 位流: 期望 ID_FAIL 且失败点=身份不符 (BID 0x18 != 0x1A)"',
  'echo "### C-a) 默认档 (NW=70 / 0x138 / BID 0x1C) —— 对 D 位流: 期望 ID_FAIL 且失败点=身份不符 (BID 0x18 != 0x1C)"', 1)


# ===========================================================================
# ⑨ 阶段 ② (0x1C → 0x1D, **persist 刀**; BID-only, NW 仍 70 / 未实现地址仍 0x138)
#
#   ⚠️ 本阶段的 **old 侧 = 阶段 ① 的 new 侧**(即 0x1C 已 apply 之后的树) —— 逐条与 ① 对齐。
#   ⚠️ 权威值: persist 构建 agent **正在改** `board/wrapper_p4.v`(`.PERSIST_EN→1'b1` + BID `0x1C→0x1D`),
#      ⇒ 本表的期望值按**显式 `--bid 0x1D`** 钉死(0x0000001D), **不**从漂移中的权威源推导;
#      待其构建完成后**复读 `board/wrapper_p4.v` 复核一次**(见 REPORT_BID1D.md)。
# ===========================================================================
# ---- ① 两个 j6 台架脚本: EXPECT_BID 默认值 + GEOM_TIERS 再插一行 ----
E2("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001C}   # 2026-10-11 缺陷刀 (70 字; 原 0x0000001A = 构建 F / 0x19 = 构建 E / 0x18 = 构建 D)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001D}   # 2026-10-11 persist 刀 (70 字; 原 0x0000001C = 缺陷刀 / 0x1A = 构建 F / 0x19 = 构建 E)", 1)
E2("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001C}   # 2026-10-11 缺陷刀 (70 字; 原 0x0000001A = 构建 F / 0x19 = 构建 E / 0x18 = 构建 D)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001D}   # 2026-10-11 persist 刀 (70 字; 原 0x0000001C = 缺陷刀 / 0x1A = 构建 F / 0x19 = 构建 E)", 1)
for f in ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",
          "_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh"):
    E2(f,
      '  "70|0x0000001C|61 62|缺陷刀 (2026-10-11) 70 字 / BID 0x1C (RETXHI-GHOST 重放越界修复; 字长/未实现地址不变)"',
      '  "70|0x0000001D|61 62|persist 刀 (2026-10-11) 70 字 / BID 0x1D"\n'
      '  "70|0x0000001C|61 62|缺陷刀 (2026-10-11) 70 字 / BID 0x1C (RETXHI-GHOST 重放越界修复; 字长/未实现地址不变)"', 1)

# ---- ② 取数器 p7b_snap.sh ----
E2("_proj_pcie/p7b_biz/p7b_snap.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001C}",
  "EXPECT_BID=${EXPECT_BID:-0x0000001D}", 1)
E2("_proj_pcie/p7b_biz/p7b_snap.sh",
  "# p7b_snap.sh -- 板侧快照窗口取数器 (**现役 = 70 字 / BID 0x1C**; 标题原文 = \"板侧 **63** 字\n"
  "#   快照窗口的取数器 (P7b Stage C: BID=10 / SNAP_NW=63)\" —— 那一代已过时, 见下逐代订正)\n"
  "#   ⭐ 缺陷刀 (2026-10-11): 身份 0x1A → **0x1C** (**字长/未实现地址不变** = 70 字 / 0x138;\n"
  "#      RETXHI-GHOST 重放越界修复) ⇒ 70 字这一代现有**两个身份** (档表/字典按 NW 索引的件见下)。\n",
  "# p7b_snap.sh -- 板侧快照窗口取数器 (**现役 = 70 字 / BID 0x1D**; 标题原文 = \"板侧 **63** 字\n"
  "#   快照窗口的取数器 (P7b Stage C: BID=10 / SNAP_NW=63)\" —— 那一代已过时, 见下逐代订正)\n"
  "#   ⭐ persist 刀 (2026-10-11): 身份 0x1C → **0x1D** (**字长/未实现地址不变** = 70 字 / 0x138; PERSIST_EN=1'b1)。\n"
  "#   ⭐ 缺陷刀 (2026-10-11): 身份 0x1A → **0x1C** (字长/未实现地址不变; RETXHI-GHOST 重放越界修复)。\n", 1)

# ---- ③ _proj_pcie 的验收/夹具脚本 ----
E2("_proj_pcie/p6e_snap_check.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001C}       # ⛔ 2026-10-11 缺陷刀: 原默认 0x0000001A (构建 F 70 字) / 0x19 (构建 E) / 0x0A (Stage C)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001D}       # ⛔ 2026-10-11 persist 刀: 原默认 0x0000001C (缺陷刀) / 0x1A (构建 F) / 0x0A (Stage C)", 1)
E2("_proj_pcie/p7b_gate4_accept.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001C}      # 缺陷刀 = 0x1C (源码 board/wrapper_p4.v 的 BUILD_ID_V; 原 0x1A = 构建 F / 0x19 = 构建 E)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001D}      # persist 刀 = 0x1D (源码 board/wrapper_p4.v 的 BUILD_ID_V; 原 0x1C = 缺陷刀 / 0x1A = 构建 F)", 1)
E2("_proj_pcie/p7b_gate4_selftest.sh",
  "  #    而\"正例必须 0 FAIL\"是本脚本的断言⑤)。现役 = **0x1C** (缺陷刀 70 字 —— ⛔ 2026-10-11 同步轮: 原 0x1A = 构建 F /\n"
  "  #    0x19 = 构建 E 67 字 / 原句 = 现役 17 (构建 C 65 字) / 10 (P7b Stage C) / 更早 9 (P7B-WU 二轮)); 跑旧口径时\n"
  "  #    FAKE_BID=0x0000001A (构建 F; SNAP_WORDS=70) / 0x00000017 / 0x0000000A / 0x00000009 / 0x00000008 (与 SNAP_WORDS=65/63 一起用)。\n",
  "  #    而\"正例必须 0 FAIL\"是本脚本的断言⑤)。现役 = **0x1D** (persist 刀 70 字 —— ⛔ 2026-10-11 同步轮: 原 0x1C = 缺陷刀 /\n"
  "  #    0x1A = 构建 F / 0x19 = 构建 E 67 字 / 原句 = 现役 17 (构建 C 65 字) / 10 (P7b Stage C)); 跑旧口径时\n"
  "  #    FAKE_BID=0x0000001C (缺陷刀; SNAP_WORDS=70) / 0x0000001A (构建 F; 70) / 0x00000017 / 0x0000000A / 0x00000008。\n", 1)
E2("_proj_pcie/p7b_gate4_selftest.sh",
  "  0X04) V=\\${FAKE_BID:-0x0000001C};;\n",
  "  0X04) V=\\${FAKE_BID:-0x0000001D};;\n", 1)
E2("_proj_pcie/p7b_gate4_negctrl.sh",
  "# 几何: **70 字 (W0..W69)** —— 缺陷刀 (2026-10-11, BID=0x1C / 未实现 0x138);\n"
  "#       (原句: \"70 字 (W0..W69) —— 构建 F (2026-10-10, BID=0x1A / 未实现 0x138)\" = 历史代, 逐字保留于下)\n",
  "# 几何: **70 字 (W0..W69)** —— persist 刀 (2026-10-11, BID=0x1D / 未实现 0x138);\n"
  "#       (原句: \"70 字 (W0..W69) —— 缺陷刀 (2026-10-11, BID=0x1C / 未实现 0x138)\" = 历史代, 逐字保留于下)\n"
  "#       (原句: \"70 字 (W0..W69) —— 构建 F (2026-10-10, BID=0x1A / 未实现 0x138)\" = 历史代, 逐字保留于下)\n", 1)
E2("_proj_pcie/p7b_gate4_negctrl.sh",
  '    echo "MAGIC 0x50360001"; echo "BID 0x0000001C"; echo "MARKER 0xdeadbeef"   # 缺陷刀: 原 0x1A = 构建 F / 0x19 = 构建 E / 0x0A = Stage C',
  '    echo "MAGIC 0x50360001"; echo "BID 0x0000001D"; echo "MARKER 0xdeadbeef"   # persist 刀: 原 0x1C = 缺陷刀 / 0x1A = 构建 F / 0x19 = 构建 E', 1)
E2("_proj_pcie/p7b_gate4_livefake.sh",
  "    #   ⛔ 2026-10-10 (构建 F): 加 **70 字那一代 = 0x1A**。\n"
  "    #   ⛔ 2026-10-11 (缺陷刀): 70 字那一代的**身份** 0x1A → **0x1C** (字长没动 ⇒ 槽号仍是 70);\n"
  "    #      兜底值同改 0x1C (现役代)。⚠️ 本字典**按 NW 索引** ⇒ 读构建 F 归档位流 (70 字/0x1A) 时\n"
  "    #      本假对端需配套回改, 否则整台在 G1 身份上假红。\n",
  "    #   ⛔ 2026-10-10 (构建 F): 加 **70 字那一代 = 0x1A**。\n"
  "    #   ⛔ 2026-10-11 (缺陷刀): 70 字那一代的身份 0x1A → **0x1C**。\n"
  "    #   ⛔ 2026-10-11 (persist 刀): 70 字那一代的**身份** 0x1C → **0x1D** (字长没动 ⇒ 槽号仍是 70);\n"
  "    #      兜底值同改 0x1D (现役代)。⚠️ 本字典**按 NW 索引** ⇒ 读构建 F (0x1A) / 缺陷刀 (0x1C) 归档位流时\n"
  "    #      本假对端需配套回改, 否则整台在 G1 身份上假红。\n", 1)
E2("_proj_pcie/p7b_gate4_livefake.sh",
  '    bid = {70: "0x0000001C", 67: "0x00000019", 66: "0x00000018", 65: "0x00000017", 63: "0x0000000A", 61: "0x00000008", 51: "0x00000007"}.get(nw, "0x0000001C")',
  '    bid = {70: "0x0000001D", 67: "0x00000019", 66: "0x00000018", 65: "0x00000017", 63: "0x0000000A", 61: "0x00000008", 51: "0x00000007"}.get(nw, "0x0000001D")', 1)
E2("_proj_pcie/p6e_snap_selftest_fix2.sh",
  "  0X04) V=\\${FAKE_BID:-0x0000001C};;   # 缺陷刀 = 0x1C (⛔ 原 0x1A = 构建 F / 0x19 = 构建 E / 0x0A = Stage C);",
  "  0X04) V=\\${FAKE_BID:-0x0000001D};;   # persist 刀 = 0x1D (⛔ 原 0x1C = 缺陷刀 / 0x1A = 构建 F / 0x0A = Stage C);", 1)

# ---- ④ final_state.sh ----
E2("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001C}   # ⛔ 2026-10-11 缺陷刀 (70 字); 原 0x1A = 构建 F",
  "EXPECT_BID=${EXPECT_BID:-0x0000001D}   # ⛔ 2026-10-11 persist 刀 (70 字); 原 0x1C = 缺陷刀", 1)

# ---- ⑤ 反例台架夹具 gen_inputs.py ----
E2("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "         ⚠️ 几何 = **70 字 / BID 0x1C** (P7b 缺陷刀, 2026-10-11 同步轮从 70 字/BID 0x1A 同步)\n"
  "            ⛔ 2026-10-11 缺陷刀同步: 上一行原写 \"几何 = 70 字 / BID 0x1A (P7b 构建 F)\";\n"
  "            ⛔ 2026-10-10 构建 F 同步: 那一行的上一行原写 \"几何 = 67 字 / BID 0x19 (构建 E)\";\n",
  "         ⚠️ 几何 = **70 字 / BID 0x1D** (P7b persist 刀, 2026-10-11 同步轮从 70 字/BID 0x1C 同步)\n"
  "            ⛔ 2026-10-11 persist 刀同步: 上一行原写 \"几何 = 70 字 / BID 0x1C (P7b 缺陷刀)\";\n"
  "            ⛔ 2026-10-11 缺陷刀同步: 那一行的上一行原写 \"几何 = 70 字 / BID 0x1A (P7b 构建 F)\";\n"
  "            ⛔ 2026-10-10 构建 F 同步: 那一行的上一行原写 \"几何 = 67 字 / BID 0x19 (构建 E)\";\n", 1)
E2("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "# 现应读作 \"不同代 ⇒ 假红\": 本夹具现 = **70 字 / BID 0x1C**, accept 默认也已是 70 字 / BID 0x1C\n",
  "# 现应读作 \"不同代 ⇒ 假红\": 本夹具现 = **70 字 / BID 0x1D**, accept 默认也已是 70 字 / BID 0x1D\n", 1)
E2("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "# 66 字/0x18 (构建 D) → 67 字/0x19 (构建 E) → 70 字/0x1A (构建 F) → **70 字/0x1C (缺陷刀, 未实现地址 0x138 不变)**。\n",
  "# 66 字/0x18 (构建 D) → 67 字/0x19 (构建 E) → 70 字/0x1A (构建 F) → 70 字/0x1C (缺陷刀) → **70 字/0x1D (persist 刀, 未实现地址 0x138 不变)**。\n", 1)
E2("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "BID_FIX = 0x0000001C       # 位流身份 (P7b 缺陷刀) —— ⛔ 2026-10-11: 原值 0x0000001A (构建 F)",
  "BID_FIX = 0x0000001D       # 位流身份 (P7b persist 刀) —— ⛔ 2026-10-11: 原值 0x0000001C (缺陷刀)", 1)

# ---- ⑥ sim 侧两个 TB ----
E2("sim/p6e_pcie/tb_p6e_pcie_counters.v",
  "chk(\"0b BUILD_ID (缺陷刀 70-word = 0x1C; 原 70-word=0x1A(构建 F) / 67-word=0x19 / 63-word=9)\", v, 32'h0000001C);",
  "chk(\"0b BUILD_ID (persist 刀 70-word = 0x1D; 原 70-word=0x1C(缺陷刀) / 0x1A(构建 F) / 63-word=9)\", v, 32'h0000001D);", 1)
E2("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
  "chk(\"2  BUILD_ID (缺陷刀 70 字=0x1C; 原 70 字=0x1A(构建 F) / 67 字=0x19 / 63 字=9)\", v, 32'h0000001C);",
  "chk(\"2  BUILD_ID (persist 刀 70 字=0x1D; 原 70 字=0x1C(缺陷刀) / 0x1A(构建 F) / 63 字=9)\", v, 32'h0000001D);", 1)

# ---- ⑦ 上一轮(A3)的档位自检 (描述"现役缺省档", 随 ② 改代) ----
E2("_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh",
  "#     (i)  缺省档 (NW=70 / 0x138 / BID 0x1C) 对 D **响亮失败** (且失败点只在 BID = 档位错, 不是板错);",
  "#     (i)  缺省档 (NW=70 / 0x138 / BID 0x1D) 对 D **响亮失败** (且失败点只在 BID = 档位错, 不是板错);", 1)
E2("_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh",
  'echo "### C-a) 默认档 (NW=70 / 0x138 / BID 0x1C) —— 对 D 位流: 期望 ID_FAIL 且失败点=身份不符 (BID 0x18 != 0x1C)"',
  'echo "### C-a) 默认档 (NW=70 / 0x138 / BID 0x1D) —— 对 D 位流: 期望 ID_FAIL 且失败点=身份不符 (BID 0x18 != 0x1D)"', 1)


# ===========================================================================
# ⑨ 阶段 ③ (0x1D → 0x1E, **snd_wnd 守卫**; BID-only, 几何不变 = 70 / 0x138)
#
#   ⚠️ 本阶段的 old 侧 = 阶段 ② (0x1D) 已 apply 之后的树 —— 逐条与 ② 对齐。
#   ⚠️ **23 处**(不是 24): `sim/p6e_pcie/tb_p6e_pcie_wrapper.v` 的 BUILD_ID 那条已被 **M1 实施轮**
#      手工带到 `0x1E`(其注释逐字"期望值 0x1D → 0x1E —— 树上 wrapper_p4.v 的 BUILD_ID_V = 32'h0000001E
#      (snd_wnd 守卫构建)") ⇒ 本阶段**跳过**它, 由阶段 ④ 直接 0x1E → 0x1F 接走。
# ===========================================================================
E3("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001D}   # 2026-10-11 persist 刀 (70 字; 原 0x0000001C = 缺陷刀 / 0x1A = 构建 F / 0x19 = 构建 E)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001E}   # 2026-10-11 snd_wnd 守卫 (70 字; 原 0x0000001D = persist 刀 / 0x1C = 缺陷刀 / 0x1A = 构建 F)", 1)
E3("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001D}   # 2026-10-11 persist 刀 (70 字; 原 0x0000001C = 缺陷刀 / 0x1A = 构建 F / 0x19 = 构建 E)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001E}   # 2026-10-11 snd_wnd 守卫 (70 字; 原 0x0000001D = persist 刀 / 0x1C = 缺陷刀 / 0x1A = 构建 F)", 1)
for f in ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",
          "_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh"):
    E3(f,
      '  "70|0x0000001D|61 62|persist 刀 (2026-10-11) 70 字 / BID 0x1D"',
      '  "70|0x0000001E|61 62|snd_wnd 守卫 (2026-10-11) 70 字 / BID 0x1E"\n'
      '  "70|0x0000001D|61 62|persist 刀 (2026-10-11) 70 字 / BID 0x1D"', 1)
E3("_proj_pcie/p7b_biz/p7b_snap.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001D}",
  "EXPECT_BID=${EXPECT_BID:-0x0000001E}", 1)
E3("_proj_pcie/p7b_biz/p7b_snap.sh",
  "# p7b_snap.sh -- 板侧快照窗口取数器 (**现役 = 70 字 / BID 0x1D**; 标题原文 = \"板侧 **63** 字\n"
  "#   快照窗口的取数器 (P7b Stage C: BID=10 / SNAP_NW=63)\" —— 那一代已过时, 见下逐代订正)\n"
  "#   ⭐ persist 刀 (2026-10-11): 身份 0x1C → **0x1D** (**字长/未实现地址不变** = 70 字 / 0x138; PERSIST_EN=1'b1)。\n",
  "# p7b_snap.sh -- 板侧快照窗口取数器 (**现役 = 70 字 / BID 0x1E**; 标题原文 = \"板侧 **63** 字\n"
  "#   快照窗口的取数器 (P7b Stage C: BID=10 / SNAP_NW=63)\" —— 那一代已过时, 见下逐代订正)\n"
  "#   ⭐ snd_wnd 守卫 (2026-10-11): 身份 0x1D → **0x1E** (**字长/未实现地址不变** = 70 字 / 0x138)。\n"
  "#   ⭐ persist 刀 (2026-10-11): 身份 0x1C → **0x1D** (PERSIST_EN=1'b1)。\n", 1)
E3("_proj_pcie/p6e_snap_check.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001D}       # ⛔ 2026-10-11 persist 刀: 原默认 0x0000001C (缺陷刀) / 0x1A (构建 F) / 0x0A (Stage C)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001E}       # ⛔ 2026-10-11 snd_wnd 守卫: 原默认 0x0000001D (persist 刀) / 0x1C (缺陷刀) / 0x0A (Stage C)", 1)
E3("_proj_pcie/p7b_gate4_accept.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001D}      # persist 刀 = 0x1D (源码 board/wrapper_p4.v 的 BUILD_ID_V; 原 0x1C = 缺陷刀 / 0x1A = 构建 F)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001E}      # snd_wnd 守卫 = 0x1E (源码 board/wrapper_p4.v 的 BUILD_ID_V; 原 0x1D = persist 刀 / 0x1C = 缺陷刀)", 1)
E3("_proj_pcie/p7b_gate4_selftest.sh",
  "  #    而\"正例必须 0 FAIL\"是本脚本的断言⑤)。现役 = **0x1D** (persist 刀 70 字 —— ⛔ 2026-10-11 同步轮: 原 0x1C = 缺陷刀 /\n"
  "  #    0x1A = 构建 F / 0x19 = 构建 E 67 字 / 原句 = 现役 17 (构建 C 65 字) / 10 (P7b Stage C)); 跑旧口径时\n"
  "  #    FAKE_BID=0x0000001C (缺陷刀; SNAP_WORDS=70) / 0x0000001A (构建 F; 70) / 0x00000017 / 0x0000000A / 0x00000008。\n",
  "  #    而\"正例必须 0 FAIL\"是本脚本的断言⑤)。现役 = **0x1E** (snd_wnd 守卫 70 字 —— ⛔ 2026-10-11 同步轮: 原 0x1D = persist 刀 /\n"
  "  #    0x1C = 缺陷刀 / 0x1A = 构建 F / 原句 = 现役 17 (构建 C 65 字) / 10 (P7b Stage C)); 跑旧口径时\n"
  "  #    FAKE_BID=0x0000001D (persist 刀; SNAP_WORDS=70) / 0x0000001C (缺陷刀; 70) / 0x00000017 / 0x0000000A / 0x00000008。\n", 1)
E3("_proj_pcie/p7b_gate4_selftest.sh",
  "  0X04) V=\\${FAKE_BID:-0x0000001D};;\n",
  "  0X04) V=\\${FAKE_BID:-0x0000001E};;\n", 1)
E3("_proj_pcie/p7b_gate4_negctrl.sh",
  "# 几何: **70 字 (W0..W69)** —— persist 刀 (2026-10-11, BID=0x1D / 未实现 0x138);\n"
  "#       (原句: \"70 字 (W0..W69) —— 缺陷刀 (2026-10-11, BID=0x1C / 未实现 0x138)\" = 历史代, 逐字保留于下)\n",
  "# 几何: **70 字 (W0..W69)** —— snd_wnd 守卫 (2026-10-11, BID=0x1E / 未实现 0x138);\n"
  "#       (原句: \"70 字 (W0..W69) —— persist 刀 (2026-10-11, BID=0x1D / 未实现 0x138)\" = 历史代, 逐字保留于下)\n"
  "#       (原句: \"70 字 (W0..W69) —— 缺陷刀 (2026-10-11, BID=0x1C / 未实现 0x138)\" = 历史代, 逐字保留于下)\n", 1)
E3("_proj_pcie/p7b_gate4_negctrl.sh",
  '    echo "MAGIC 0x50360001"; echo "BID 0x0000001D"; echo "MARKER 0xdeadbeef"   # persist 刀: 原 0x1C = 缺陷刀 / 0x1A = 构建 F / 0x19 = 构建 E',
  '    echo "MAGIC 0x50360001"; echo "BID 0x0000001E"; echo "MARKER 0xdeadbeef"   # snd_wnd 守卫: 原 0x1D = persist 刀 / 0x1C = 缺陷刀 / 0x1A = 构建 F', 1)
E3("_proj_pcie/p7b_gate4_livefake.sh",
  "    #   ⛔ 2026-10-10 (构建 F): 加 **70 字那一代 = 0x1A**。\n"
  "    #   ⛔ 2026-10-11 (缺陷刀): 70 字那一代的身份 0x1A → **0x1C**。\n"
  "    #   ⛔ 2026-10-11 (persist 刀): 70 字那一代的**身份** 0x1C → **0x1D** (字长没动 ⇒ 槽号仍是 70);\n"
  "    #      兜底值同改 0x1D (现役代)。⚠️ 本字典**按 NW 索引** ⇒ 读构建 F (0x1A) / 缺陷刀 (0x1C) 归档位流时\n"
  "    #      本假对端需配套回改, 否则整台在 G1 身份上假红。\n",
  "    #   ⛔ 2026-10-10 (构建 F): 加 **70 字那一代 = 0x1A**。\n"
  "    #   ⛔ 2026-10-11 (缺陷刀/persist 刀): 70 字那一代的身份 0x1A → 0x1C → 0x1D。\n"
  "    #   ⛔ 2026-10-11 (snd_wnd 守卫): 70 字那一代的**身份** 0x1D → **0x1E** (字长没动 ⇒ 槽号仍是 70);\n"
  "    #      兜底值同改 0x1E (现役代)。⚠️ 本字典**按 NW 索引** ⇒ 读更早代归档位流时要配套回改。\n", 1)
E3("_proj_pcie/p7b_gate4_livefake.sh",
  '    bid = {70: "0x0000001D", 67: "0x00000019", 66: "0x00000018", 65: "0x00000017", 63: "0x0000000A", 61: "0x00000008", 51: "0x00000007"}.get(nw, "0x0000001D")',
  '    bid = {70: "0x0000001E", 67: "0x00000019", 66: "0x00000018", 65: "0x00000017", 63: "0x0000000A", 61: "0x00000008", 51: "0x00000007"}.get(nw, "0x0000001E")', 1)
E3("_proj_pcie/p6e_snap_selftest_fix2.sh",
  "  0X04) V=\\${FAKE_BID:-0x0000001D};;   # persist 刀 = 0x1D (⛔ 原 0x1C = 缺陷刀 / 0x1A = 构建 F / 0x0A = Stage C);",
  "  0X04) V=\\${FAKE_BID:-0x0000001E};;   # snd_wnd 守卫 = 0x1E (⛔ 原 0x1D = persist 刀 / 0x1C = 缺陷刀 / 0x0A = Stage C);", 1)
E3("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001D}   # ⛔ 2026-10-11 persist 刀 (70 字); 原 0x1C = 缺陷刀",
  "EXPECT_BID=${EXPECT_BID:-0x0000001E}   # ⛔ 2026-10-11 snd_wnd 守卫 (70 字); 原 0x1D = persist 刀", 1)
E3("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "         ⚠️ 几何 = **70 字 / BID 0x1D** (P7b persist 刀, 2026-10-11 同步轮从 70 字/BID 0x1C 同步)\n"
  "            ⛔ 2026-10-11 persist 刀同步: 上一行原写 \"几何 = 70 字 / BID 0x1C (P7b 缺陷刀)\";\n"
  "            ⛔ 2026-10-11 缺陷刀同步: 那一行的上一行原写 \"几何 = 70 字 / BID 0x1A (P7b 构建 F)\";\n",
  "         ⚠️ 几何 = **70 字 / BID 0x1E** (P7b snd_wnd 守卫, 2026-10-11 同步轮从 70 字/BID 0x1D 同步)\n"
  "            ⛔ 2026-10-11 snd_wnd 守卫同步: 上一行原写 \"几何 = 70 字 / BID 0x1D (P7b persist 刀)\";\n"
  "            ⛔ 2026-10-11 persist 刀同步: 那一行的上一行原写 \"几何 = 70 字 / BID 0x1C (P7b 缺陷刀)\";\n"
  "            ⛔ 2026-10-11 缺陷刀同步: 那一行的上一行原写 \"几何 = 70 字 / BID 0x1A (P7b 构建 F)\";\n", 1)
E3("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "# 现应读作 \"不同代 ⇒ 假红\": 本夹具现 = **70 字 / BID 0x1D**, accept 默认也已是 70 字 / BID 0x1D\n",
  "# 现应读作 \"不同代 ⇒ 假红\": 本夹具现 = **70 字 / BID 0x1E**, accept 默认也已是 70 字 / BID 0x1E\n", 1)
E3("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "# 66 字/0x18 (构建 D) → 67 字/0x19 (构建 E) → 70 字/0x1A (构建 F) → 70 字/0x1C (缺陷刀) → **70 字/0x1D (persist 刀, 未实现地址 0x138 不变)**。\n",
  "# 66 字/0x18 (构建 D) → 67 字/0x19 (构建 E) → 70 字/0x1A (构建 F) → 70 字/0x1C (缺陷刀) → 70 字/0x1D (persist 刀) → **70 字/0x1E (snd_wnd 守卫, 未实现地址 0x138 不变)**。\n", 1)
E3("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "BID_FIX = 0x0000001D       # 位流身份 (P7b persist 刀) —— ⛔ 2026-10-11: 原值 0x0000001C (缺陷刀)",
  "BID_FIX = 0x0000001E       # 位流身份 (P7b snd_wnd 守卫) —— ⛔ 2026-10-11: 原值 0x0000001D (persist 刀)", 1)
E3("sim/p6e_pcie/tb_p6e_pcie_counters.v",
  "chk(\"0b BUILD_ID (persist 刀 70-word = 0x1D; 原 70-word=0x1C(缺陷刀) / 0x1A(构建 F) / 63-word=9)\", v, 32'h0000001D);",
  "chk(\"0b BUILD_ID (snd_wnd 守卫 70-word = 0x1E; 原 70-word=0x1D(persist 刀) / 0x1C(缺陷刀) / 63-word=9)\", v, 32'h0000001E);", 1)
E3("_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh",
  "#     (i)  缺省档 (NW=70 / 0x138 / BID 0x1D) 对 D **响亮失败** (且失败点只在 BID = 档位错, 不是板错);",
  "#     (i)  缺省档 (NW=70 / 0x138 / BID 0x1E) 对 D **响亮失败** (且失败点只在 BID = 档位错, 不是板错);", 1)
E3("_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh",
  'echo "### C-a) 默认档 (NW=70 / 0x138 / BID 0x1D) —— 对 D 位流: 期望 ID_FAIL 且失败点=身份不符 (BID 0x18 != 0x1D)"',
  'echo "### C-a) 默认档 (NW=70 / 0x138 / BID 0x1E) —— 对 D 位流: 期望 ID_FAIL 且失败点=身份不符 (BID 0x18 != 0x1E)"', 1)


# ===========================================================================
# ⑩ 阶段 ④ (0x1E → 0x1F, **M1 镜像窗**; **BID + 几何**)
#
#   BID 面: 上列 23 处 + `sim/p6e_pcie/tb_p6e_pcie_wrapper.v` 的 BUILD_ID (那条被 M1 轮手工带到
#          0x1E ⇒ 本轮由**本阶段**接走 0x1E → 0x1F) = **24 处**。
#   几何面 (M1: 快照 70 → **71**, W70 = `app_rx_mirror.drop_bytes`; 未实现地址:
#          旧公式 `0x20+4*NW` → **新公式 `0x20+4*NW+16`** (= 0x14C; MIR_STATUS/DATA/CTRL/DMA_CNT 四字
#          插在快照末字与未实现地址之间) ⇒ 读数器公式 / 表长 / 地址 / 指纹 / 档表全跟)。
# ===========================================================================
# ---- BID: 23 处 (与 ③ 同形, 值 +1 代) ----
E4("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001E}   # 2026-10-11 snd_wnd 守卫 (70 字; 原 0x0000001D = persist 刀 / 0x1C = 缺陷刀 / 0x1A = 构建 F)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001F}   # 2026-10-11 M1 镜像窗 (71 字; 原 0x0000001E = snd_wnd 守卫 / 0x1D = persist 刀 / 0x1C = 缺陷刀)", 1)
E4("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001E}   # 2026-10-11 snd_wnd 守卫 (70 字; 原 0x0000001D = persist 刀 / 0x1C = 缺陷刀 / 0x1A = 构建 F)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001F}   # 2026-10-11 M1 镜像窗 (71 字; 原 0x0000001E = snd_wnd 守卫 / 0x1D = persist 刀 / 0x1C = 缺陷刀)", 1)
for f in ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",
          "_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh"):
    E4(f,
      '  "70|0x0000001E|61 62|snd_wnd 守卫 (2026-10-11) 70 字 / BID 0x1E"',
      '  "71|0x0000001F|61 62|M1 镜像窗 (2026-10-11) 71 字 / BID 0x1F (W70 = app_rx_mirror.drop_bytes; 未实现地址 0x138 → 0x14C)"\n'
      '  "70|0x0000001E|61 62|snd_wnd 守卫 (2026-10-11) 70 字 / BID 0x1E"', 1)
E4("_proj_pcie/p7b_biz/p7b_snap.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001E}",
  "EXPECT_BID=${EXPECT_BID:-0x0000001F}", 1)
E4("_proj_pcie/p6e_snap_check.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001E}       # ⛔ 2026-10-11 snd_wnd 守卫: 原默认 0x0000001D (persist 刀) / 0x1C (缺陷刀) / 0x0A (Stage C)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001F}       # ⛔ 2026-10-11 M1 镜像窗: 原默认 0x0000001E (snd_wnd 守卫) / 0x1D (persist 刀) / 0x0A (Stage C)", 1)
E4("_proj_pcie/p7b_gate4_accept.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001E}      # snd_wnd 守卫 = 0x1E (源码 board/wrapper_p4.v 的 BUILD_ID_V; 原 0x1D = persist 刀 / 0x1C = 缺陷刀)",
  "EXPECT_BID=${EXPECT_BID:-0x0000001F}      # M1 镜像窗 = 0x1F (源码 board/wrapper_p4.v 的 BUILD_ID_V; 原 0x1E = snd_wnd 守卫 / 0x1D = persist 刀)", 1)
E4("_proj_pcie/p7b_gate4_selftest.sh",
  "  #    而\"正例必须 0 FAIL\"是本脚本的断言⑤)。现役 = **0x1E** (snd_wnd 守卫 70 字 —— ⛔ 2026-10-11 同步轮: 原 0x1D = persist 刀 /\n"
  "  #    0x1C = 缺陷刀 / 0x1A = 构建 F / 原句 = 现役 17 (构建 C 65 字) / 10 (P7b Stage C)); 跑旧口径时\n"
  "  #    FAKE_BID=0x0000001D (persist 刀; SNAP_WORDS=70) / 0x0000001C (缺陷刀; 70) / 0x00000017 / 0x0000000A / 0x00000008。\n",
  "  #    而\"正例必须 0 FAIL\"是本脚本的断言⑤)。现役 = **0x1F** (M1 镜像窗 71 字 —— ⛔ 2026-10-11 同步轮: 原 0x1E = snd_wnd 守卫 /\n"
  "  #    0x1D = persist 刀 / 0x1C = 缺陷刀 / 原句 = 现役 17 (构建 C 65 字) / 10 (P7b Stage C)); 跑旧口径时\n"
  "  #    FAKE_BID=0x0000001E (snd_wnd 守卫; SNAP_WORDS=70) / 0x0000001D (persist 刀; 70) / 0x00000017 / 0x00000008。\n", 1)
E4("_proj_pcie/p7b_gate4_selftest.sh",
  "  0X04) V=\\${FAKE_BID:-0x0000001E};;\n",
  "  0X04) V=\\${FAKE_BID:-0x0000001F};;\n", 1)
E4("_proj_pcie/p7b_gate4_negctrl.sh",
  "# 几何: **70 字 (W0..W69)** —— snd_wnd 守卫 (2026-10-11, BID=0x1E / 未实现 0x138);\n"
  "#       (原句: \"70 字 (W0..W69) —— persist 刀 (2026-10-11, BID=0x1D / 未实现 0x138)\" = 历史代, 逐字保留于下)\n",
  "# 几何: **71 字 (W0..W70)** —— M1 镜像窗 (2026-10-11, BID=0x1F / 未实现 0x14C);\n"
  "#       (原句: \"70 字 (W0..W69) —— snd_wnd 守卫 (2026-10-11, BID=0x1E / 未实现 0x138)\" = 历史代, 逐字保留于下)\n"
  "#       (原句: \"70 字 (W0..W69) —— persist 刀 (2026-10-11, BID=0x1D / 未实现 0x138)\" = 历史代, 逐字保留于下)\n", 1)
E4("_proj_pcie/p7b_gate4_negctrl.sh",
  '    echo "MAGIC 0x50360001"; echo "BID 0x0000001E"; echo "MARKER 0xdeadbeef"   # snd_wnd 守卫: 原 0x1D = persist 刀 / 0x1C = 缺陷刀 / 0x1A = 构建 F',
  '    echo "MAGIC 0x50360001"; echo "BID 0x0000001F"; echo "MARKER 0xdeadbeef"   # M1 镜像窗: 原 0x1E = snd_wnd 守卫 / 0x1D = persist 刀 / 0x1C = 缺陷刀', 1)
E4("_proj_pcie/p7b_gate4_livefake.sh",
  "    #   ⛔ 2026-10-11 (snd_wnd 守卫): 70 字那一代的**身份** 0x1D → **0x1E** (字长没动 ⇒ 槽号仍是 70);\n"
  "    #      兜底值同改 0x1E (现役代)。⚠️ 本字典**按 NW 索引** ⇒ 读更早代归档位流时要配套回改。\n",
  "    #   ⛔ 2026-10-11 (snd_wnd 守卫 → M1 镜像窗): 70 字槽的身份 0x1D → 0x1E; M1 起几何变 **71 字**,\n"
  "    #      但本字典**按 NW 索引** ⇒ 新增 **71 槽 = 0x1F** (现役代); 70 槽降为历史 (0x1E)。\n", 1)
E4("_proj_pcie/p7b_gate4_livefake.sh",
  '    bid = {70: "0x0000001E", 67: "0x00000019", 66: "0x00000018", 65: "0x00000017", 63: "0x0000000A", 61: "0x00000008", 51: "0x00000007"}.get(nw, "0x0000001E")',
  '    bid = {71: "0x0000001F", 70: "0x0000001E", 67: "0x00000019", 66: "0x00000018", 65: "0x00000017", 63: "0x0000000A", 61: "0x00000008", 51: "0x00000007"}.get(nw, "0x0000001F")', 1)
E4("_proj_pcie/p6e_snap_selftest_fix2.sh",
  "  0X04) V=\\${FAKE_BID:-0x0000001E};;   # snd_wnd 守卫 = 0x1E (⛔ 原 0x1D = persist 刀 / 0x1C = 缺陷刀 / 0x0A = Stage C);",
  "  0X04) V=\\${FAKE_BID:-0x0000001F};;   # M1 镜像窗 = 0x1F (⛔ 原 0x1E = snd_wnd 守卫 / 0x1D = persist 刀 / 0x0A = Stage C);", 1)
E4("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  "EXPECT_BID=${EXPECT_BID:-0x0000001E}   # ⛔ 2026-10-11 snd_wnd 守卫 (70 字); 原 0x1D = persist 刀",
  "EXPECT_BID=${EXPECT_BID:-0x0000001F}   # ⛔ 2026-10-11 M1 镜像窗 (71 字); 原 0x1E = snd_wnd 守卫", 1)
E4("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "         ⚠️ 几何 = **70 字 / BID 0x1E** (P7b snd_wnd 守卫, 2026-10-11 同步轮从 70 字/BID 0x1D 同步)\n"
  "            ⛔ 2026-10-11 snd_wnd 守卫同步: 上一行原写 \"几何 = 70 字 / BID 0x1D (P7b persist 刀)\";\n"
  "            ⛔ 2026-10-11 persist 刀同步: 那一行的上一行原写 \"几何 = 70 字 / BID 0x1C (P7b 缺陷刀)\";\n",
  "         ⚠️ 几何 = **71 字 / BID 0x1F** (P7b M1 镜像窗, 2026-10-11 同步轮从 70 字/BID 0x1E 同步)\n"
  "            ⛔ 2026-10-11 M1 同步: 上一行原写 \"几何 = 70 字 / BID 0x1E (P7b snd_wnd 守卫)\";\n"
  "            ⛔ M1 起未实现地址不再 = 0x20+4*NW (快照末字后接 MIR 四字) ⇒ = 0x20+4*NW+16 = **0x14C**;\n"
  "            ⛔ 2026-10-11 snd_wnd 守卫同步: 那一行的上一行原写 \"几何 = 70 字 / BID 0x1D (P7b persist 刀)\";\n", 1)
E4("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "# 现应读作 \"不同代 ⇒ 假红\": 本夹具现 = **70 字 / BID 0x1E**, accept 默认也已是 70 字 / BID 0x1E\n",
  "# 现应读作 \"不同代 ⇒ 假红\": 本夹具现 = **71 字 / BID 0x1F**, accept 默认也已是 71 字 / BID 0x1F\n", 1)
E4("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "# 66 字/0x18 (构建 D) → 67 字/0x19 (构建 E) → 70 字/0x1A (构建 F) → 70 字/0x1C (缺陷刀) → 70 字/0x1D (persist 刀) → **70 字/0x1E (snd_wnd 守卫, 未实现地址 0x138 不变)**。\n",
  "# 66 字/0x18 (构建 D) → 67 字/0x19 (构建 E) → 70 字/0x1A (构建 F) → 70 字/0x1C (缺陷刀) → 70 字/0x1D (persist 刀) → 70 字/0x1E (snd_wnd 守卫) → **71 字/0x1F (M1 镜像窗, 未实现地址 0x138 → 0x14C)**。\n", 1)
E4("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "BID_FIX = 0x0000001E       # 位流身份 (P7b snd_wnd 守卫) —— ⛔ 2026-10-11: 原值 0x0000001D (persist 刀)",
  "BID_FIX = 0x0000001F       # 位流身份 (P7b M1 镜像窗) —— ⛔ 2026-10-11: 原值 0x0000001E (snd_wnd 守卫)", 1)
E4("sim/p6e_pcie/tb_p6e_pcie_counters.v",
  "chk(\"0b BUILD_ID (snd_wnd 守卫 70-word = 0x1E; 原 70-word=0x1D(persist 刀) / 0x1C(缺陷刀) / 63-word=9)\", v, 32'h0000001E);",
  "chk(\"0b BUILD_ID (M1 镜像窗 71-word = 0x1F; 原 70-word=0x1E(snd_wnd 守卫) / 0x1D(persist 刀) / 63-word=9)\", v, 32'h0000001F);", 1)
E4("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
  "u_dut.u_pcie_xdma.axil_read(32'h04, v); chk(\"2  BUILD_ID (M1 tree = 0x1E)\", v, 32'h0000001E);",
  "u_dut.u_pcie_xdma.axil_read(32'h04, v); chk(\"2  BUILD_ID (M1 镜像窗构建 = 0x1F)\", v, 32'h0000001F);", 1)
E4("_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh",
  "#     (i)  缺省档 (NW=70 / 0x138 / BID 0x1E) 对 D **响亮失败** (且失败点只在 BID = 档位错, 不是板错);",
  "#     (i)  缺省档 (NW=71 / 0x14C / BID 0x1F) 对 D **响亮失败** (且失败点只在 BID = 档位错, 不是板错);", 1)
E4("_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh",
  'echo "### C-a) 默认档 (NW=70 / 0x138 / BID 0x1E) —— 对 D 位流: 期望 ID_FAIL 且失败点=身份不符 (BID 0x18 != 0x1E)"',
  'echo "### C-a) 默认档 (NW=71 / 0x14C / BID 0x1F) —— 对 D 位流: 期望 ID_FAIL 且失败点=身份不符 (BID 0x18 != 0x1F)"', 1)

# ---- 几何 (M1): 公式 / 表长 / 表尾 / 地址 / 指纹 / 档表 ----
#   ⚠️ **j6 的 NW 默认值与几何门注释**: 台架自己也有 NW 默认值 ⇒ 必须跟着 70 → 71
#      （本条是 C 段断言在 rehearsal 里**抓出来的真漏**：`^NW=${NW:-70}` 期望 71 报红）。
for f, cmt_old, cmt_new in (
        ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh",
         "#     ⑦ **几何门 (硬断言)**: ① `NW=${NW:-70}` (构建 F; 更早构建 E=67 / P7B-A7=66 / P7B-GAP9-TX=65 / 原 63) 且 **export** (原先那个 `NW=${NW:-61}` **没 export**,",
         "#     ⑦ **几何门 (硬断言)**: ① `NW=${NW:-71}` (M1 镜像窗; 更早构建 F=70 / E=67 / P7B-A7=66 / P7B-GAP9-TX=65 / 原 63) 且 **export** (原先那个 `NW=${NW:-61}` **没 export**,"),
        ("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh",
         "#     ⑦ **几何门 (硬断言)**: ① `NW=${NW:-70}` (构建 F; 更早构建 E=67 / P7B-A7=66 / P7B-GAP9-TX=65 / 原 63) 且 **export** (原先那个 `NW=${NW:-61}` **没 export**,",
         "#     ⑦ **几何门 (硬断言)**: ① `NW=${NW:-71}` (M1 镜像窗; 更早构建 F=70 / E=67 / P7B-A7=66 / P7B-GAP9-TX=65 / 原 63) 且 **export** (原先那个 `NW=${NW:-61}` **没 export**,")):
    E4(f, cmt_old, cmt_new, 1)
    E4(f, "NW=${NW:-70}", "NW=${NW:-71}", 1)
E4("_proj_pcie/p7b_biz/p7b_snap.sh",
  "# (NW 的单一真值源 = board/wrapper_p4.v 的 `SNAP_NW_P6E`; 未实现地址 = 0x20+4*NW)",
  "# (NW 的单一真值源 = board/wrapper_p4.v 的 `SNAP_NW_P6E`; 未实现地址 = **0x20+4*NW+16** (M1 起:\n"
  "#  快照末字后接 MIR_STATUS/DATA/CTRL/DMA_CNT 四个字) —— 70 字及更早**无** +16, 读旧位流须显式 `UNIMPL_ADDR=`)", 1)
E4("_proj_pcie/p7b_biz/p7b_snap.sh",
  "NW=${NW:-70}",
  "NW=${NW:-71}", 1)
E4("_proj_pcie/p7b_biz/p7b_snap.sh",
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*NW )))}   # 70 ⇒ 0x138 (67 ⇒ 0x12C; 65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)",
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*NW + 16 )))}   # 71 ⇒ 0x14C (M1 期B 起; 70 字及更早 = 0x138/0x12C/0x124/0x11C/0x114/0xEC —— 读旧位流须显式覆盖)", 1)
E4("_proj_pcie/p7b_biz/p7b_snap.sh",
  "[67]=tx_winstall_cap      [68]=rx_stat_ack_adv     [69]=tx_win_at_winstall\n)",
  "[67]=tx_winstall_cap      [68]=rx_stat_ack_adv     [69]=tx_win_at_winstall\n"
  "# ⭐ M1 (2026-10-11): W70 —— 载荷镜像的拒收字节数 (真值源 = wrapper 装配段 `p7bdp_dout[30*32 +: 32]`):\n"
  "[70]=mir_drop_bytes\n)", 1)
E4("_proj_pcie/p7b_biz/p7b_snap.sh",
  "# p7b_snap.sh -- 板侧快照窗口取数器 (**现役 = 70 字 / BID 0x1E**; 标题原文 = \"板侧 **63** 字\n"
  "#   快照窗口的取数器 (P7b Stage C: BID=10 / SNAP_NW=63)\" —— 那一代已过时, 见下逐代订正)\n"
  "#   ⭐ snd_wnd 守卫 (2026-10-11): 身份 0x1D → **0x1E** (**字长/未实现地址不变** = 70 字 / 0x138)。\n",
  "# p7b_snap.sh -- 板侧快照窗口取数器 (**现役 = 71 字 / BID 0x1F**; 标题原文 = \"板侧 **63** 字\n"
  "#   快照窗口的取数器 (P7b Stage C: BID=10 / SNAP_NW=63)\" —— 那一代已过时, 见下逐代订正)\n"
  "#   ⭐ M1 镜像窗 (2026-10-11): 70 → **71** (W70 = app_rx_mirror.drop_bytes) + 身份 0x1E → **0x1F**;\n"
  "#      未实现地址 **0x138 → 0x14C** (MIR_STATUS/DATA/CTRL/DMA_CNT 四字插在快照末字之后)。\n"
  "#   ⭐ snd_wnd 守卫 (2026-10-11): 身份 0x1D → **0x1E** (字长/未实现地址不变)。\n", 1)
E4("_proj_pcie/p6e_snap_check.sh",
  "SNAP_WORDS=${SNAP_WORDS:-70}",
  "SNAP_WORDS=${SNAP_WORDS:-71}", 1)
E4("_proj_pcie/p6e_snap_check.sh",
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 70 ⇒ 0x138 (67 ⇒ 0x12C; 65 ⇒ 0x124; 63 ⇒ 0x11C; 51 ⇒ 0xEC)",
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS + 16 )))}   # 71 ⇒ 0x14C (M1 期B 起; 70 字及更早 = 0x138/0x12C/0x124/0x11C/0xEC —— 读旧位流须显式覆盖)", 1)
E4("_proj_pcie/p6e_snap_check.sh",
  "#    现在只改这一个数: 地址 = 0x20 + 4*i (i=0..SNAP_WORDS-1), 未实现地址 = 0x20 + 4*SNAP_WORDS。",
  "#    现在只改这一个数: 地址 = 0x20 + 4*i (i=0..SNAP_WORDS-1), 未实现地址 = 0x20 + 4*SNAP_WORDS\n"
  "#    **+ 16** (⭐ M1 起: 快照末字后接 MIR_STATUS/DATA/CTRL/DMA_CNT 四字; 70 字及更早**无** +16)。", 1)
E4("_proj_pcie/p6e_snap_check.sh",
  " #       真值源 = `board/wrapper_p4.v` 的装配段注释。表长必须 == SNAP_WORDS (70),\n"
  " #       否则循环把它们打成 `<无标签>` (2026-10-10 加固轮: 本表原只到 W64 ⇒ W65..W69 无名)。",
  " #       真值源 = `board/wrapper_p4.v` 的装配段注释。表长必须 == SNAP_WORDS (71),\n"
  " #       否则循环把它们打成 `<无标签>` (2026-10-10 加固轮: 本表原只到 W64; M1 再补 W70)。", 1)
E4("_proj_pcie/p6e_snap_check.sh",
  " \"tx_win_at_winstall (tcp_tx_frame.o_win_at_winstall: 等窗拍锁存; 构建 F)\" )",
  " \"tx_win_at_winstall (tcp_tx_frame.o_win_at_winstall: 等窗拍锁存; 构建 F)\"\n"
  " \"mir_drop_bytes     (app_rx_mirror.drop_bytes: 载荷镜像拒收字节数; M1)\" )", 1)
E4("_proj_pcie/p7b_gate4_accept.sh",
  "SNAP_WORDS=${SNAP_WORDS:-70}",
  "SNAP_WORDS=${SNAP_WORDS:-71}", 1)
E4("_proj_pcie/p7b_gate4_accept.sh",
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 70 ⇒ 0x138 (67 ⇒ 0x12C; 66 ⇒ 0x128; 65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)",
  "UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS + 16 )))}   # 71 ⇒ 0x14C (M1 期B 起; 70 字及更早 = 0x138/0x12C/0x128/0x124/0x11C/0x114/0xEC —— 读旧位流须显式覆盖)", 1)
E4("_proj_pcie/p7b_gate4_accept.sh",
  "# ⚠️ 未实现地址 = 0x20 + 4*SNAP_WORDS 这条公式本轮**重新成立**: 读侧译码已加宽到 7 位\n"
  "#    (araddr[8:2]) ⇒ 地址每 **512** 字节才回绕, 而 `0x20+4*63 = 0x11C` 真正未实现 ⇒\n"
  "#    仍回 0xffffffff。红线随之改成\"**绝不能挑 ≥0x200**\" (旧红线是 ≥0x100)。",
  "# ⚠️ 未实现地址的**公式 M1 起变了**: 旧 = `0x20 + 4*SNAP_WORDS` (63/65/66/67/70 字各代成立);\n"
  "#    M1 期B 起 = `0x20 + 4*SNAP_WORDS + 16` (快照末字后接 MIR_STATUS/DATA/CTRL/DMA_CNT 四字)\n"
  "#    ⇒ 71 字 = **0x14C**。⚠️ 读旧位流 (≤70 字) 必须显式 `UNIMPL_ADDR=` 覆盖, 否则默认值会指到真字。\n"
  "#    红线不变 (读侧译码 7 位 ⇒ **绝不能挑 ≥0x200**)。", 1)
E4("_proj_pcie/p7b_gate4_selftest.sh",
  "SW=${SNAP_WORDS:-70}",
  "SW=${SNAP_WORDS:-71}", 1)
E4("_proj_pcie/p7b_gate4_selftest.sh",
  "#   SW ≥ 70 (2026-10-10 构建 F 起) ⇒ 0x12C/0x130/0x134 也是**窗口内的真字**,\n"
  "#     `FAKE_UNIMPL` 挪到 **0x138**;",
  "#   SW ≥ 71 (2026-10-11 M1 起) ⇒ 0x138 也是**窗口内的真字** (W70), 且未实现地址 = 0x14C\n"
  "#     (M1 起公式 `0x20+4*SW+16`) ⇒ `FAKE_UNIMPL` 挪到 **0x14C**;\n"
  "#   SW ≥ 70 (构建 F) ⇒ 0x12C/0x130/0x134 是窗口内真字 ⇒ `FAKE_UNIMPL` 在 **0x138**;", 1)
E4("_proj_pcie/p7b_gate4_selftest.sh",
  "if [ \"$SW\" -ge 70 ]; then\n",
  "if [ \"$SW\" -ge 71 ]; then\n"
  "  FAKE_TAIL='  0X114) V=1234;;  # W61 app_ctrl.stat_wu (次数; 非 0 才像真板)\n"
  "  0X118) V=0;;     # W62 app_ctrl.rx_occ_bytes (17 位 ⇒ 高位恒 0)\n"
  "  0X11C) V=0;;     # W63 app_pattern.stat_frmwait_cyc (停滞拍数; 0 = 无停顿)\n"
  "  0X120) V=0;;     # W64 app_pattern.stat_bp_cyc (背压拍数)\n"
  "  0X124) V=0;;     # W65 mac_tx_10g.stat_tx_idle (S_IDLE 拍数; 0 = 空载, 建 D 新增)\n"
  "  0X128) V=0;;     # W66 tcp_tx_frame.stat_winstall (窗口门停顿拍数, 建 E 新增)\n"
  "  0X12C) V=0;;     # W67 tcp_tx_frame.stat_winstall_cap (板帽侧等窗拍数, 建 F 新增)\n"
  "  0X130) V=0;;     # W68 tcp_rx.stat_ack_adv (推进 snd_una 的 ACK 次数, 建 F 新增)\n"
  "  0X134) V=0;;     # W69 tcp_tx_frame.o_win_at_winstall (等窗拍操作点锁存, 建 F 新增)\n"
  "  0X138) V=0;;     # W70 app_rx_mirror.drop_bytes (载荷镜像拒收字节数, M1 新增; 真字)\n"
  "  0X14C) V=${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (71 字; M1 起 = 0x20+4*SW+16)'\n"
  "elif [ \"$SW\" -ge 70 ]; then\n", 1)
E4("_proj_pcie/p7b_gate4_negctrl.sh",
  "                0 0 0)   # W51..W69 (构建 F: W67/W68/W69 = 三个纯观测仪器)\n"
  "    local i; for (( i = 0; i < 70; i++ )); do printf 'W%d 0x%X\\n' \"$i\" \"${V[$i]}\"; done",
  "                0 0 0 0)   # W51..W70 (M1: W70 = app_rx_mirror.drop_bytes)\n"
  "    local i; for (( i = 0; i < 71; i++ )); do printf 'W%d 0x%X\\n' \"$i\" \"${V[$i]}\"; done", 1)
E4("_proj_pcie/p7b_gate4_negctrl.sh",
  "shift1(){ awk -v NW=70 ",
  "shift1(){ awk -v NW=71 ", 1)
E4("_proj_pcie/p7b_gate4_livefake.sh",
  "        + [0] * 19          # W51..W69 = P7B-BIZ/WU/构建C/D/E/F 新增字 (accept 只要求窗口齐全 + 无 0xffffffff)",
  "        + [0] * 20          # W51..W70 = P7B-BIZ/WU/C/D/E/F + M1 新增字 (accept 只要求窗口齐全 + 无 0xffffffff)", 1)
E4("_proj_pcie/p6e_snap_selftest_fix2.sh",
  "# ⚠️ 假板子的**几何必须与现役 RTL 同代** (= **70 字 / 未实现 0x138**; 2026-10-10 构建 F;",
  "# ⚠️ 假板子的**几何必须与现役 RTL 同代** (= **71 字 / 未实现 0x14C**; 2026-10-11 M1 镜像窗;\n"
  "#    原句 = 70 字 / 0x138 (构建 F);", 1)
E4("_proj_pcie/p6e_snap_selftest_fix2.sh",
  "  0X138) V=0xffffffff;;                                       # 未实现地址 (70 字; … -> 0x12C -> **0x138**)",
  "  0X138) V=0x00000000;;                                       # W70 app_rx_mirror.drop_bytes (71 字起; M1)\n"
  "  0X14C) V=0xffffffff;;                                       # 未实现地址 (71 字; M1 起 = 0x20+4*SW+16)", 1)
E4("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  "echo \"MAGIC=$(rd 0x00) BID=$BID MARKER=$(rd 0x14) UNIMPL=$(rd 0x138) gen=$(( (s >> 16) & 0xffff ))\"",
  "echo \"MAGIC=$(rd 0x00) BID=$BID MARKER=$(rd 0x14) UNIMPL=$(rd 0x14c) gen=$(( (s >> 16) & 0xffff ))\"", 1)
E4("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  "# ⚠️ UNIMPL 地址跟窗口宽度走: **70 字 (构建 F, 2026-10-10 起) ⇒ 0x138** (word 78);",
  "# ⚠️ UNIMPL 地址跟窗口宽度走: **71 字 (M1, 2026-10-11 起) ⇒ 0x14C** (word 83; 快照末字后接 MIR 四字\n"
  "#     ⇒ 公式 = 0x20+4*NW+16); 70 字 (构建 F 起) = 0x138 (word 78);", 1)
E4("_proj_10g/notes/p7b_gate4_3/final_state.sh",
  "echo \"W67=$(rd 0x12c) W68=$(rd 0x130) W69=$(rd 0x134)  # 构建 F: 板帽侧等窗拍数 / 推进 ACK 次数 / 等窗拍操作点锁存\"",
  "echo \"W67=$(rd 0x12c) W68=$(rd 0x130) W69=$(rd 0x134)  # 构建 F: 板帽侧等窗拍数 / 推进 ACK 次数 / 等窗拍操作点锁存\"\n"
  "echo \"W70=$(rd 0x138)  # M1: app_rx_mirror.drop_bytes (载荷镜像拒收字节数)\"", 1)
E4("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "NW_FIX = 70                # 快照字数 (W0..W69)",
  "NW_FIX = 71                # 快照字数 (W0..W70; M1 起 —— 原 70)", 1)
E4("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "  快照 : SNAP_BEGIN / TLATCH / GEN / MAGIC / BID / MARKER / W0..W69 / UNIMPL / SNAP_END",
  "  快照 : SNAP_BEGIN / TLATCH / GEN / MAGIC / BID / MARKER / W0..W70 / UNIMPL / SNAP_END", 1)
E4("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
  "    \"\"\"**70 字 (W0..W69)**; lat = 该块锁存的时刻 (秒) ⇒ 三个域自由计数由它算出。",
  "    \"\"\"**71 字 (W0..W70)**; lat = 该块锁存的时刻 (秒) ⇒ 三个域自由计数由它算出。", 1)
E4("_proj_10g/notes/p7b_biz_win/run_xvlog_wrapper.bat",
  "findstr /C:\"SNAP_NW_P6E = 70\" \"%SRCFILE%\" >NUL || ( echo [FINGERPRINT FAIL] source is not the 70-word version & exit /b 92 )",
  "findstr /C:\"SNAP_NW_P6E = 71\" \"%SRCFILE%\" >NUL || ( echo [FINGERPRINT FAIL] source is not the 71-word version & exit /b 92 )", 1)
E4("sim/p5wu_p1p2/run_xvlog_wrapper63.bat",
  "findstr /C:\"SNAP_NW_P6E = 70\" \"%SRCFILE%\" >NUL || ( echo [FINGERPRINT FAIL] source is not the 70-word version & exit /b 92 )",
  "findstr /C:\"SNAP_NW_P6E = 71\" \"%SRCFILE%\" >NUL || ( echo [FINGERPRINT FAIL] source is not the 71-word version & exit /b 92 )", 1)
E4("_proj_10g/p7b_chain/sim/tb_p7b_chain.v",
  "        u_dut.u_pcie_xdma.axil_read(32'h138, v);\n",
  "        u_dut.u_pcie_xdma.axil_read(32'h14C, v);\n", 1)
E4("_proj_10g/p7b_chain/sim/tb_p7b_chain.v",
  "        chk(\"7b 0x138 reads 0 no wrap\",",
  "        chk(\"7b 0x14C reads 0 no wrap\",", 1)
E4("_proj_10g/p7b_chain/sim/tb_p7b_chain.v",
  "            \"axi_regs decode; 70-word bound (原 67 字/0x12C, 66 字/0x128, 63 字/0x11C; 2026-10-10 订正)\");",
  "            \"axi_regs decode; 71-word bound (M1: 0x14C = 0x20+4*71+16; 原 70 字/0x138, 67 字/0x12C, 63 字/0x11C; 2026-10-11 M1 订正)\");", 1)


# ===========================================================================
# ⑧ 【读侧加固】三条结构性断言 (照搬 F 轮; 判据必须**走到退出码**)
#
#   动机 (F 轮同源): "同步"以前只靠一份**手写清单** + "锚点命中数" ⇒ 连翻三轮车
#   (66/67/70 字轮各漏一处)。三条把它封死:
#     A. 表长断言   : 每张名字表/字表的**项数 == NW**（NW **现读**权威源, 不写死）;
#     B. 搜索面全扫 : ① F 轮三个命名族 ② **本轮新增: 旧身份字面值 `0x0000001A` / `32'h0000001A`**
#                     全仓扫; 每个命中文件必须**已登记**(EDITS 目标 或 ALLOW 分类)
#                     ⇒ "还有哪处留着旧值而没人分类"变成硬失败, 而不是"没人看见";
#     C. 默认值一致 : 每个读侧默认值 (NW / BID / 未实现地址) == 权威源现读值。
#   ⚠️ 负对照一律在 **tempfile 副本**上做 (`--negctl=<名>`); 本脚本**绝不**为了演示改仓内文件。
# ===========================================================================
import re
import shutil
import subprocess
import tempfile


def _src(rel, overlay=None):
    """读一件。`overlay` = {rel: 文本} 时**优先**取 overlay 里的内容 —— 这是负对照
    唯一的注入口（内容来自 tempfile 里的故意破坏副本, 仓内文件一个字节都不动）。"""
    if overlay and rel in overlay:
        return overlay[rel]
    p = os.path.join(REPO, rel.replace("/", os.sep))
    return io.open(p, "r", encoding="utf-8", errors="replace").read()


def authoritative(overlay=None):
    """**权威源** = `board/wrapper_p4.v`（RTL 是唯一真源: 读侧一切几何/身份由它派生）。
    ⚠️ 这个源**本身会漂**（它按设计逐代变），所以断言**不写死期望值** —— 一律**现读**再比。
    本轮期望 = (70, 0x0000001C)，但判据本体是"读侧 == 现读值"，与具体数字无关。"""
    s = _src("board/wrapper_p4.v", overlay)
    nw = int(re.search(r"localparam\s+SNAP_NW_P6E\s*=\s*(\d+)\s*;", s).group(1))
    bid = "0x%08X" % int(re.search(r"\.BUILD_ID_V\s*\(\s*32'h([0-9A-Fa-f]+)\s*\)", s).group(1), 16)
    return nw, bid


def unimpl_addr(nw):
    """**旧公式** (M1 之前): 未实现地址 = 0x20 + 4*NW。⚠️ M1 期B 起不再是它 —— 见 stage_unimpl。"""
    return 0x20 + 4 * nw


def stage_nw(target):
    return stage_of(target)[3]


def stage_unimpl(target):
    """**目标代自己的**未实现地址 (M1 起 = 0x20+4*NW+16, 由 STAGES 元数据带) —— 断言按它比。"""
    return stage_of(target)[4]


def _arr_body(s, anchor):
    """取 `anchor` 之后、配平到 depth 0 的括号体 (双引号内的括号不计数)。
    anchor 末字符 = `(` 时按圆括号配平; = `[` 时按方括号配平 (python 字面表)。"""
    i = s.index(anchor) + len(anchor)
    op, cl = ("[", "]") if anchor.rstrip().endswith("[") else ("(", ")")
    depth, q, j = 1, False, i
    while j < len(s):
        c = s[j]
        if q:
            q = (c != '"')
        elif c == '"':
            q = True
        elif c == op:
            depth += 1
        elif c == cl:
            depth -= 1
            if depth == 0:
                return s[i:j]
        j += 1
    raise ValueError("括号未配平: " + anchor)


# ---- A. 表长断言: (文件, 种类, 锚点, 说明) —— 每条的期望长度都 = NW（现读）
TABLE_SPECS = [
    ("_proj_pcie/p6e_snap_check.sh", "bash_quoted", "WLABEL=(",
     "WLABEL (逐字打印的名字表; F 轮补到 70 —— 再短一项 ⇒ 该字打成 <无标签>)"),
    ("_proj_pcie/p7b_biz/p7b_snap.sh", "bash_keys", "declare -A NAME=(",
     "NAME[] (板侧取数器的名字表)"),
    ("_proj_pcie/p7b_gate4_livefake.sh", "py_list", "W = [",
     "假对端的 W 字表 (长度 < NW ⇒ for i in range(nw) 直接 IndexError = '整台安静')"),
    ("_proj_pcie/p7b_gate4_negctrl.sh", "bash_plain", "local -a V=(",
     "合成夹具的 V 字表 (长度 < NW ⇒ 尾部字打 0 = 假数据)"),
    #   `{nw}` = 现读的权威 NW（anchor 由它拼出来 —— 分档脚本的"现役那一档"必须 = 现役几何）
    ("_proj_pcie/p7b_gate4_selftest.sh", "bash_addrs",
     "if [ \"$SW\" -ge {nw} ]; then",
     "假板子的 FAKE_TAIL 地址表 (地址条数必须 == NW-60=W60..W(NW-1), 末条 = 未实现地址)"),
]


def table_count(rel, kind, anchor, overlay=None, nw=None):
    s = _src(rel, overlay)
    anchor = anchor.replace("{nw}", str(nw)) if nw else anchor
    if kind == "bash_addrs":
        # FAKE_TAIL: 分档分支体的 `0X<hex>)` 地址条 (条数 == NW-60; 末条 == 未实现地址)
        i = s.index(anchor)
        seg = s[i:i + 4000].split("elif")[0]
        return [int(x, 16) for x in re.findall(r"0X([0-9A-Fa-f]+)\)", seg)]
    if kind == "py_list":
        # `W = [..] + [..] * k + [..]`（跨行 + 行尾注释）—— 从 `W = [` 那一行起,
        # 取到第一条**整行注释**为止（行内 `#` 之后也去掉）, 再把函数调用/裸名换成 0 求长度。
        # ⚠️ 不能用 `_arr_body` 的方括号配平: 表达式里每一段 `[..]` 自己就是配平的。
        lines = s.split("\n")
        i = [k for k, l in enumerate(lines) if l.strip().startswith(anchor)][0]
        buf = []
        for l in lines[i:]:
            if l.strip().startswith("#"):
                break
            buf.append(re.sub(r"#.*$", "", l).replace("\\", "").strip())
        expr = " ".join(buf)
        expr = expr[expr.index("["):]
        expr = re.sub(r"[A-Za-z_]\w*\s*\([^()]*\)", "0", expr)
        expr = re.sub(r"\b[A-Za-z_]\w*\b", "0", expr)
        return len(eval(expr, {"__builtins__": {}}, {}))   # noqa: S307 (可信仓内文件)
    body = _arr_body(s, anchor)
    if kind == "bash_quoted":
        n = body.count('"')
        if n % 2:
            raise ValueError("%s: 引号数 %d 为奇数 (数组体被截断?)" % (rel, n))
        return n // 2
    if kind == "bash_plain":
        body = re.sub(r"(?m)^\s*#.*$", "", body)      # 去**整行**注释 (行内注释不动, 免得误伤数据)
        return len(body.split())
    if kind == "bash_keys":
        # ⚠️ 必须先去掉**整行注释**再数键: p7b_snap.sh 的注释里逐字引用了 `[56]=`/`[33]=`/`[34]=`
        #    ⇒ 不去注释会多数出 5 个键 (F 轮实测 75 vs 70)。
        body = re.sub(r"(?m)^\s*#.*$", "", body)
        ks = sorted(int(x) for x in re.findall(r"\[(\d+)\]=", body))
        return ks                                     # 键必须是 {0..NW-1} 且无洞无重
    raise ValueError("未知表种类 " + kind)


# ---- C. 默认值一致性: 每个读侧默认值都必须 == 权威源现读值
#      kind: NW / BID / UNIMPL / NW_key / BID_NW_PAIR / TIER_TOP
DEFAULT_SPECS = [
    ("_proj_pcie/p6e_snap_check.sh", r"SNAP_WORDS=\$\{SNAP_WORDS:-(\d+)\}", "NW"),
    ("_proj_pcie/p6e_snap_check.sh", r"EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)\}", "BID"),
    ("_proj_pcie/p7b_biz/p7b_snap.sh", r"NW=\$\{NW:-(\d+)\}", "NW"),
    ("_proj_pcie/p7b_biz/p7b_snap.sh", r"EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)\}", "BID"),
    #   头部"现役 = 70 字 / BID 0x1C" 也是**被断言的**（不是纯注释: 它是这件的自述身份）
    ("_proj_pcie/p7b_biz/p7b_snap.sh", r"现役 = \d+ 字 / BID (0x[0-9A-Fa-f]+)", "BID"),
    ("_proj_pcie/p7b_gate4_accept.sh", r"SNAP_WORDS=\$\{SNAP_WORDS:-(\d+)\}", "NW"),
    ("_proj_pcie/p7b_gate4_accept.sh", r"EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)\}", "BID"),
    ("_proj_pcie/p7b_gate4_selftest.sh", r"SW=\$\{SNAP_WORDS:-(\d+)\}", "NW"),
    ("_proj_pcie/p7b_gate4_selftest.sh", r"FAKE_BID:-?(0x[0-9A-Fa-f]+)", "BID"),
    ("_proj_pcie/p7b_gate4_selftest.sh", r"现役 = \*\*(0x[0-9A-Fa-f]+)\*\*", "BID"),
    ("_proj_pcie/p6e_snap_selftest_fix2.sh", r"FAKE_BID:-?(0x[0-9A-Fa-f]+)", "BID"),
    ("_proj_pcie/p7b_gate4_negctrl.sh", r"echo \"BID (0x[0-9A-Fa-f]+)\"", "BID"),
    ("_proj_pcie/p7b_gate4_negctrl.sh", r"for \(\( i = 0; i < (\d+); i\+\+ \)\)", "NW"),
    ("_proj_pcie/p7b_gate4_negctrl.sh", r"awk -v NW=(\d+)", "NW"),
    #   合成夹具的**几何自述**（现在带身份 ⇒ 也断言）
    #   ⚠️ 正则**故意同时匹配改前/改后**的措辞（`[^(]*` = "缺陷刀" / "构建 F" 都行）——
    #      这样 dry-run 里它是"值不对"的红（0x1A vs 0x1C）, 而不是"锚点没命中"的红。
    ("_proj_pcie/p7b_gate4_negctrl.sh",
     r"几何: \*\*\d+ 字 \(W\d+\.\.W\d+\)\*\* —— [^(]*\(2026-10-1\d, BID=(0x[0-9A-Fa-f]+)", "BID"),
    ("_proj_pcie/p7b_gate4_livefake.sh",
     r'bid = \{(\d+): "0x[0-9A-Fa-f]+"', "NW_key"),          # 表里有**现役 NW** 这一档
    ("_proj_pcie/p7b_gate4_livefake.sh",
     r'\}\.get\(nw, "(0x[0-9A-Fa-f]+)"\)', "BID"),            # 兜底值 = 现役 BID
    ("_proj_pcie/p7b_gate4_livefake.sh",
     r'bid = \{\d+: "(0x[0-9A-Fa-f]+)"', "BID"),               # 70 字槽 = 现役 BID（本轮新增）
    ("_proj_10g/notes/p7b_gate4_3/final_state.sh", r"EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)\}", "BID"),
    ("_proj_10g/notes/p7b_gate4_3/final_state.sh", r"UNIMPL=\$\(rd (0x[0-9A-Fa-f]+)\)", "UNIMPL"),
    ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh", r"(?m)^NW=\$\{NW:-(\d+)\}", "NW"),
    ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh", r"(?m)^EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)\}", "BID"),
    ("_proj_10g/notes/p7b_affinity/j6_r6fix.sh", r'"(\d+)\|(0x[0-9A-Fa-f]+)\|', "TIER_TOP"),
    ("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh", r"(?m)^NW=\$\{NW:-(\d+)\}", "NW"),
    ("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh", r"(?m)^EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)\}", "BID"),
    ("_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh", r'"(\d+)\|(0x[0-9A-Fa-f]+)\|', "TIER_TOP"),
    ("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py", r"NW_FIX = (\d+)", "NW"),
    ("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py", r"BID_FIX = (0x[0-9A-Fa-f]+)", "BID"),
    ("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py", r"几何 = \*\*\d+ 字 / BID (0x[0-9A-Fa-f]+)\*\*", "BID"),
    #   逐代链的**现役那一格**(加粗那一格)也断言 —— 正则改前/改后都匹配 (`构建 F` / `缺陷刀` 都行)
    ("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
     r"本夹具现 = \*\*\d+ 字 / BID (0x[0-9A-Fa-f]+)\*\*", "BID"),
    ("_proj_10g/notes/p7b_gate4_criteria/gen_inputs.py",
     r"→ \*\*\d+ 字/(0x[0-9A-Fa-f]+) \(", "BID"),
    ("_proj_10g/notes/p7b_biz_win/tb_biz_win.v", r"localparam integer NW = (\d+)", "NW"),
    # 单元门: 地址/期望值都锚在**活的那一行** (`^\s*u_dut...` 排掉 `//` 注释里的历史句)
    ("sim/p6e_pcie/tb_p6e_pcie_counters.v",
     r"(?m)^\s*u_dut\.u_pcie_xdma\.axil_read\(32'h04, v\); chk\(\"0b BUILD_ID[^\"]*\", v, 32'h([0-9A-Fa-f]+)\);", "BID"),
    ("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
     r"(?m)^\s*u_dut\.u_pcie_xdma\.axil_read\(32'h04, v\); chk\(\"2  BUILD_ID[^\"]*\", v, 32'h([0-9A-Fa-f]+)\);", "BID"),
    ("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
     #   ⚠️ 标签从"9  未实现地址"漂成"9  unimpl"(M1 实施轮) ⇒ 只锚前缀 `9  `, 值仍取地址
     r"axil_read\(32'h([0-9A-Fa-f]+), v\);\n\s*chk\(\"9  ", "UNIMPL"),
    ("sim/p6e_pcie/tb_p6e_pcie_wrapper.v",
     r"(?m)^\s*chk\(\"9  (?:未实现地址 |unimpl )(0x[0-9A-Fa-f]+)", "UNIMPL"),
    ("_proj_10g/p7b_chain/sim/tb_p7b_chain.v",
     r"axil_read\(32'h([0-9A-Fa-f]+), v\);\n\s*chk\(\"7b 0x", "UNIMPL"),
    ("_proj_10g/p7b_chain/sim/tb_p7b_chain.v",
     r"(?m)^\s*chk\(\"7b (0x[0-9A-Fa-f]+) reads 0 no wrap", "UNIMPL"),
    #   ⚠️ **不含 `//` 的活行**才有牙 (历史句全是 `// …` 注释; 负彩排抓到本行原本**无断言** ⇒ 漏改不报)
    ("_proj_10g/p7b_chain/sim/tb_p7b_chain.v",
     r"(?m)^\s{10,}\"axi_regs decode; (\d+)-word bound", "NW"),
    ("_proj_10g/notes/p7b_biz_win/run_tb_biz_win.bat", r"findstr /C:\"SNAP_NW_P6E = (\d+)\"", "NW"),
    ("_proj_10g/notes/p7b_biz_win/run_xvlog_wrapper.bat", r"findstr /C:\"SNAP_NW_P6E = (\d+)\"", "NW"),
    ("sim/p5wu_p1p2/run_xvlog_wrapper63.bat", r"findstr /C:\"SNAP_NW_P6E = (\d+)\"", "NW"),
    # 上一轮(A3)的档位自检: 它描述的"缺省档"/"默认档"= 现役默认值
    ("_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh",
     r"缺省档 \(NW=\d+ / 0x[0-9A-Fa-f]+ / BID (0x[0-9A-Fa-f]+)\)", "BID"),
    ("_proj_10g/notes/p7b_a3_negctl_20261010/step0_selfcheck.sh",
     r"默认档 \(NW=\d+ / 0x[0-9A-Fa-f]+ / BID (0x[0-9A-Fa-f]+)\)", "BID"),
    # ⚠️ **F 轮的两个 BID_NW_PAIR 断言已移除**: `p7b_buildF_board_20261010/{run,burn}_arm.sh`
    #    是**构建 F 那一轮的现场记录**（其 0x1A 是"它烧的就是 F 位流"的真值）⇒ 本轮归 ALLOW,
    #    不再断言 == 现役（否则它们会**正确地**红, 而"正确地红"在这里是噪声）。
]

# 派生式 (判据 = 一个必须成立的算式, 而不是单点值): check_window.py 的新字数分解
DERIVED_SPECS = [
    ("_proj_10g/notes/p7b_biz_win/check_window.py",
     [("nnew_top", r"nnew_top = (\d+)"), ("ntx", r"ntx = (\d+)"), ("nnew", r"nnew = (\d+)")],
     lambda v, nw: v["nnew_top"] + v["ntx"] + v["nnew"] == nw - 51,
     "nnew_top + ntx + nnew == NW - 51 (W51..W(NW-1) 的分解; 70-51=19)"),
]

# ---- B. 搜索面全扫: 四个族。**每个命中文件都必须已登记**, 否则 FAIL。
def families_for(target):
    """按**目标 BID** 造搜索面: `bid-oldvalue` 族 = **所有比 target 小的已登记身份字面值**
    （target 0x1C ⇒ 只扫 0x1A; target 0x1D ⇒ 扫 0x1A **和** 0x1C）。
    ⚠️ 只扫"8 位零填充"形态（`0x1A` 短写法在 base64/IP 数据里会出现假阳性 —— 实测
       `xdma_0_sim_netlist.v` 的 base64 行里逐字含 `0x1A`）; 短写法由 identity-BID 族按**上下文**兜住。
    ⚠️ 没有尾界会被 `0x0000001AA` 之类误伤 ⇒ 末尾 `\b`。"""
    olds = [b for b in HISTORY_BIDS if int(b, 16) < int(target, 16)]
    pat = "|".join(r"(?:0[xX]|32'[hH])0{6}%s\b" % b[-2:] for b in olds)
    # ⚠️ 防呆: 空 alternation 会编译成"匹配一切"（实测一次: 1843 文件全命中）—— 宁可响亮失败。
    assert pat, "families_for: target %s 没有更早的身份 ⇒ 旧值族为空 (会匹配一切!)" % target
    return [("bid-oldvalue[%s]" % ",".join(olds), re.compile(pat))] + FAMILIES_TAIL


FAMILIES_TAIL = [
    ("identity-BID", re.compile(
        r"EXPECT_BID=\$\{EXPECT_BID:-(0x[0-9A-Fa-f]+)"
        r"|BID_EXPECT=\$\{BID_EXPECT:-(0x[0-9A-Fa-f]+)"
        r"|BID_EXPECT=(0x[0-9A-Fa-f]+)"                 # 裸字面形式
        r"|BID_FIX = (0x[0-9A-Fa-f]+)|BIE=(0x[0-9A-Fa-f]+)"
        r"|FAKE_BID:-?(?:0x)?([0-9A-Fa-f]{6,8})"
        r"|BUILD_ID_V\s*\(\s*32'h([0-9A-Fa-f]+)"
        r"|bid = \{\d+: \"0x[0-9A-Fa-f]+\""            # ⭐ 本轮新增: livefake 的 bid 字典
        r"|echo \"BID (0x[0-9A-Fa-f]+)\"")),           # ⭐ 本轮新增: negctrl 的 BID echo 行
    ("geometry-NW", re.compile(
        r"NW=\$\{NW:-(\d+)|SNAP_WORDS=\$\{SNAP_WORDS:-(\d+)|SW=\$\{SNAP_WORDS:-(\d+)"
        r"|NW_FIX\s*=\s*(\d+)|awk -v NW=(\d+)|localparam\s+integer NW = (\d+)"
        r"|nnew_top = (\d+)|(?<![\w.])NW=(\d+)(?=[\s;)\"'&|]|$)")),   # 末项 = **裸字面形式**
    ("unimpl-addr", re.compile(
        r"axil_read\(32'h([0-9A-Fa-f]+)|UNIMPL_ADDR=\$\{UNIMPL_ADDR:-"
        r"|UNIMPL=\$\(rd (0x1[0-9A-Fa-f]{2})\)|rd (0x1[0-9A-Fa-f]{2})")),
]

# 允许清单: (路径正则, 分类) —— 分类只有三档 + "非读侧/位流绑定"豁免 (逐条给理由)。
ALLOW = [
    # —— 权威源 (只读; 它是"现读值"的来处, 不是"要同步的默认值") ——
    (r"^board/wrapper_p4\.v$", "权威源: SNAP_NW_P6E / BUILD_ID_V (只读; 由 ⑧ 现读)"),
    # —— 现役 (在飞/已同步) ——
    (r"^_proj_10g/notes/p7b_readside_bid1c_20261011/",
     "现役: 本轮预建脚本 (old-side 字符串是**补丁左值**, 必须留旧值; ⚠️ 目录原名 p7b_build0x1C, 因与 p7b_build_0x1C 撞名被 TL 改名 2026-10-11)"),
    (r"^_proj_10g/notes/p7b_defect_board_20261011/",
     "现役: 缺陷刀板级轮 (在飞; ⚠️ S-0 臂**刻意**用 0x1A = 绑定构建 F 位流, 不是漏同步)"),
    (r"^_proj_10g/notes/p7b_persist_board_20261011/",
     "旧位流读法: persist 板级 A/B 轮现场 (两臂各烧归档 0x1C/0x1D 位流; BID 由各自 `WANT` sha256 钉死)"),
    (r"^_proj_10g/notes/p7b_sndwnd_board_20261011/",
     "旧位流读法: snd_wnd 守卫板级轮现场 (0x1E 含守卫 / 0x1D 负对照; BID 由各自 `WANT` sha256 钉死)"),
    (r"^_proj_10g/notes/p7b_build_0x1[CDE]/",
     "构建轮目录 (读数/归档/位流; 非读侧 —— 但含各代 BID 字符串, 属该轮取证)"),
    (r"^_proj_10g/notes/p7b_m1[a-z0-9_]*_(synth|impl)_2026\d+/",
     "M1 综合/实现轮产物 (读数/日志; 非读侧)"),
    (r"^_proj_10g/notes/p7b_biz_win/(check_window\.py|tb_biz_win\.v|run_tb_biz_win\.bat|run_xvlog_wrapper\.bat)$",
     "现役: 窗口几何守卫 (几何本轮不动; 其 nnew_top 由 ⑧-C 派生式断言)"),
    # —— 旧位流读法 (可留: 值刻意绑某代已归档位流, 改它反而毁掉那一代的取证) ——
    (r"^_proj_10g/notes/p7b_buildF/", "旧位流读法: 上一代 apply_* (old/new 两侧都是那代的值 = 补丁左值)"),
    (r"^_proj_10g/notes/p7b_buildF_board2?_20261010/",
     "旧位流读法: 构建 F 两轮板级现场/跑臂 (它们烧的就是 F 位流 ⇒ 0x1A 是**真值**)"),
    (r"^_proj_10g/notes/p7b_microwin_20261010/", "旧位流读法: 微窗轮现场 (绑构建 F 位流)"),
    (r"^_proj_10g/notes/p7b_buildE(_board)?_20261010/", "旧位流读法: 构建 E 那一轮的件"),
    (r"^_proj_10g/notes/p7b_a7(_board)?_20261010/", "旧位流读法: 构建 C/D 那一轮的件"),
    (r"^_proj_10g/notes/p7b_a3_negctl_20261010/burn_arm\.sh$",
     "位流绑定: E 臂烧 build E 位流 (sha b88b2bee) ⇒ 其 BIE 依位流定; ⚠️ F 轮把它改成 0x1A 后已是半代, 本轮**不再叠加** (见 REPORT §4)"),
    (r"^_proj_10g/notes/p7b_a3_negctl_20261010/_tools/", "旧位流读法: A3 轮部署件快照"),
    (r"^_proj_10g/notes/p7b_(buildE_board|gap9_tx_board|lonsend_board|udp_longrun|uplink_ceil|window_side)_2026\d+/",
     "旧位流读法: 历史轮板级现场快照/跑臂"),
    (r"^_proj_10g/notes/p7b_longflow_board/", "旧位流读法: 长流台架母版 (默认 = S3 档; 各轮一律用 env 覆盖 NW/BID_EXPECT)"),
    (r"^_proj_10g/notes/p7b_(bench|board_stagea|board_stagec|wu_w54|wu_loop|wu_harness_fix|biz_s1|biz_tcpreg|biz_win/neg)/",
     "旧位流读法: 历史轮件/负面夹具"),
    (r"^_proj_10g/notes/p7b_biz_win/apply_.*\.py$",
     "历史注释: 更早的 apply 脚本 (old/new 两侧都是那代的值, 是补丁左值)"),
    (r"^_proj_10g/notes/p7b_(a7|buildE)/", "旧位流读法: 构建 C/D/E 的 apply_*"),
    (r"^_proj_10g/notes/p7b_gate4_tools/", "旧位流读法: 门工具轮的历史副本/生成物"),
    (r"^_proj_10g/notes/p7b_(rate|ratefrm|chain_cov)/", "同名不同物/变异件: 自带 NW 参数的自洽门 (NW=184 是帧字数)"),
    (r"^_proj_10g/notes/p7b_(retxhi|retxhi_impl|persist|persist_impl|retxhi_impl)_?(review)?_2026\d+/",
     "历史轮件: RETXHI / persist 审查与实施件 (只登记不动)"),
    (r"^_proj_10g/notes/p7b_(aliasgate|p5wrapper_diag)_20261010/",
     "另一路 agent 的对拍副本/工作副本 (在本轮范围外; 只登记不动)"),
    (r"^_proj_10g/notes/p7b_tool_debt_2026\d+/", "历史轮件: 工具债轮 (只登记不动)"),
    (r"^_proj_10g/notes/p7b_sinkfix_2026\d+/", "历史轮件: sink 修复轮 (只登记不动)"),
    (r"^_proj_10g/notes/p7b_(window_side|build_archive|buildF_build|buildE_build|build_a7|build_longsend|build_longflow)/",
     "历史读数/构建归档目录"),
    (r"^sim/aliasgate/", "另一路 agent 的 aliasgate 自检副本 (只登记不动)"),
    (r"^sim/p4gates/", "刻意的外来夹具 (禁全局替换)"),
    (r"^sim/snapcdc/|^tb/tb_snap_cdc\.v$",
     "同名不同物: `snap_cdc` 单元门的 NW 轴 = 束宽 (14/22) / 历史窗口宽 (24/32/36), 与现役字数无关"),
    (r"^sim/(p5bfix|p5b_|p5c_|p5d_|p5e_|p5sim|p5close|rxsim|txsim|p3sim)/", "sim 历史镜像件 (禁全局替换)"),
    (r"^sim/p5wu_p1p2/", "旧位流读法: 63 字世代的门与 run 器"),
    (r"^sim/p6e_pcie/", "旧代单元门 (参数自洽; 与 EDITS 里的 TB 共处, 由 EDITS 覆盖现役两件)"),
    (r"^sim/p7b_stage[bc]_[a-z0-9_]*regress/", "回归轮的树快照/镜像 (只登记不动)"),
    (r"^_proj_pcie/(tb|rtl)/", "旧代单元门/最小实验设计 (自带 SNAP_NW 参数)"),
    (r"^_proj_pcie/probe/", "探针工程产物"),
    (r"^tb/tb_snap63\.v$", "旧位流读法: 63 字世代门 (NW=63 是它的判据本体)"),
    (r"^int_scratch/", "scratch 目录 (非交付件)"),
    (r"^audit_scratch/", "审计 scratch"),
    (r"^p6b_accept_final/", "历史读数目录 (36 字世代)"),
    (r"^_proj_10g/p7b_chain/", "旧代链门 (现役两件由 EDITS 覆盖)"),
    (r"^_proj_10g/(p7b_mac|p7b_mac_synth|xxv_)", "10G MAC/PCS 的 IP 生成物与单元门 (自带参数)"),
]


def _fileset(extra=None):
    """非忽略文件集 = git ls-files + git ls-files --others --exclude-standard。
    ⚠️ `.gitignore` 的目录规则会让 `grep -r` 与 `git ls-files` 给出**不同**集合 ⇒
    两边都要跑 (本函数就是"两边都跑"的代码化)。`extra` = 负对照用的虚拟新文件。"""
    out = []
    for cmd in ("git ls-files", "git ls-files --others --exclude-standard"):
        r = subprocess.run(cmd.split(), cwd=REPO, stdout=subprocess.PIPE)
        out += r.stdout.decode("utf-8", "replace").splitlines()
    return sorted(set(out) | set(extra or []))


def assert_tables(nw, overlay=None, unimpl=None):
    fails = []
    for rel, kind, anchor, note in TABLE_SPECS:
        try:
            got = table_count(rel, kind, anchor, overlay, nw)
        except Exception as e:                                       # noqa: BLE001
            print("FAIL %-58s 表长断言异常: %s" % (rel, e))
            fails.append(rel)
            continue
        if kind == "bash_addrs":
            # 覆盖 = W61..W(NW-1) 的字地址 **+ 未实现地址那一格** (共 NW-60 条; 末条 = 未实现地址)。
            # ⚠️ M1 起未实现地址**不再**紧跟末字 (中间插 MIR 四字) ⇒ 末条**不是** 0x20+4*NW,
            #    必须用该代自己的 unimpl (缺省退回旧公式, 兼容旧代)。
            want = list(range(0x20 + 4 * 61, 0x20 + 4 * nw, 4)) +                    [(unimpl if unimpl is not None else unimpl_addr(nw))]
            ok = got == want
            print("%s %-58s 地址条数 = %d / 期望 %d (末条 0x%X)   %s"
                  % ("OK  " if ok else "FAIL", rel, len(got), len(want),
                     got[-1] if got else 0, note))
            if not ok:
                fails.append(rel)
            continue
        if kind == "bash_keys":
            want = list(range(nw))
            ok = got == want
            print("%s %-58s 键集合 = {%d..%d} 共 %d 项 / 期望 {%d..%d} 共 %d 项   %s"
                  % ("OK  " if ok else "FAIL", rel, got[0] if got else -1, got[-1] if got else -1,
                     len(got), 0, nw - 1, nw, note))
        else:
            ok = got == nw
            print("%s %-58s 表长 = %d / 期望 NW = %d   %s"
                  % ("OK  " if ok else "FAIL", rel, got, nw, note))
        if not ok:
            fails.append(rel)
    return fails


def assert_defaults(nw, bid, overlay=None, unimpl=None):
    want = {"NW": nw, "BID": int(bid, 16),
            "UNIMPL": unimpl if unimpl is not None else unimpl_addr(nw)}
    fails = []
    for rel, rx, kind in DEFAULT_SPECS:
        s = _src(rel, overlay)
        ms = re.findall(rx, s)
        if kind == "TIER_TOP":            # 档表**第一行**必须是现役档 (NW, BID)
            pairs = [(int(a), int(b, 16)) for a, b in ms]
            top = pairs[0] if pairs else (0, 0)
            ok = top == (nw, want["BID"])
            shown = "0x%08X,NW=%d (共 %d 档)" % (top[1], top[0], len(pairs)) if pairs else "(0 档)"
            wshow = "0x%08X,NW=%d" % (want["BID"], nw)
        elif kind == "BID_NW_PAIR":
            got = [(int(a, 16), int(b)) for a, b in ms]
            ok = bool(got) and all(v == (want["BID"], nw) for v in got)
            shown = " / ".join("0x%08X,NW=%d" % v for v in got) or "(0 命中)"
            wshow = "0x%08X,NW=%d" % (want["BID"], nw)
        elif kind == "NW_key":
            got = [int(x) for x in ms]
            ok = bool(got) and (nw in got) and all(v == nw for v in got)
            shown = ",".join(ms) or "(0 命中)"
            wshow = "含 %d 档" % nw
        elif kind == "BID_ANY":           # 一个文件里允许多处 BID（都 == 现役）
            vals = [int(m, 16) for m in ms]
            ok = bool(vals) and all(v == want["BID"] for v in vals)
            shown = ",".join(ms) or "(0 命中)"
            wshow = "0x%08X" % want["BID"]
        else:
            vals = [int(m, 16) if kind in ("BID", "UNIMPL") else int(m) for m in ms]
            ok = len(vals) == 1 and vals[0] == want[kind]
            shown = ",".join(ms) or "(0 命中)"
            if kind == "BID" and ms and not ms[0].lower().startswith("0x"):
                shown = ",".join("32'h" + m for m in ms)      # Verilog 写法, 显示给人看
            wshow = {"BID": "0x%08X" % want["BID"], "NW": str(want["NW"]),
                     "UNIMPL": "0x%X" % want["UNIMPL"]}[kind]
        print("%s %-52s %-14s = %-22s 期望 %s   %s"
              % ("OK  " if ok else "FAIL", rel, kind, shown, wshow, rx[:30]))
        if not ok:
            fails.append("%s[%s]" % (rel, kind))
    for rel, names, pred, note in DERIVED_SPECS:
        s = _src(rel, overlay)
        v = {}
        for nm, rx in names:
            m = re.search(rx, s)
            v[nm] = int(m.group(1)) if m else -1
        ok = pred(v, nw)
        print("%s %-52s 派生式             %s   %s"
              % ("OK  " if ok else "FAIL", rel, v, note))
        if not ok:
            fails.append("%s[derived]" % rel)
    return fails


COMMENT_PREFIX = ("//", "#", "REM", "rem", "*", "--", "%")
#   ⚠️ 扫之前先去掉**整行注释** (每种语言的注释前缀都列上): 注释里的旧值属"历史注释（可留）"。
#      **行内注释不剥** (那会误伤数据行) ⇒ EDITS 后带行内历史注释的行仍会命中 ⇒ 它必须
#      **仍是 EDITS 目标**(已登记) 才不报 —— 这正是"漏一处就红"的机制。


def _strip_comment_lines(text):
    out = []
    for l in text.split("\n"):
        if l.lstrip().startswith(COMMENT_PREFIX):
            out.append("")
        else:
            out.append(l)
    return "\n".join(out)


def assert_edit_coverage(edits):
    """**每个 EDITS 目标必须自带一个断言**（DEFAULT_SPECS / TABLE_SPECS / DERIVED_SPECS 里出现）——
    否则就是"改了但没人核": 下一轮它漂了不会有任何判据响（F 轮"五处只改三处"的同族缺口）。
    这条把"清单完整性"从**人的记忆**变成**脚本的结构**。"""
    spec_files = (set(rel for rel, _rx, _k in DEFAULT_SPECS)
                  | set(rel for rel, _k, _a, _n in TABLE_SPECS)
                  | set(rel for rel, _n, _p, _x in DERIVED_SPECS))
    edit_files = set(rel for rel, _a, _b, _c in edits)
    fails = []
    for rel in sorted(edit_files):
        if rel not in spec_files:
            print("FAIL EDITS 目标没有对应断言: %-52s ⇒ 改了没人核" % rel)
            fails.append(rel)
    print("%s EDIT_COVERAGE (本阶段 EDITS 文件 %d / 有对应断言 %d)"
          % ("OK  " if not fails else "FAIL", len(edit_files), len(edit_files) - len(fails)))
    return fails


def assert_search_face(overlay=None, extra=None, targets=None, fams=None):
    """搜索面全扫: 每个命中文件必须已登记 (EDITS 目标 或 ALLOW 分类)。
    `targets` = 阶段链上所有 edit 目标文件并集; `fams` = `families_for(目标 BID)`。"""
    if targets is None:
        targets = set(rel for b, e, n in chain_for("0x0000001D") for rel, _a, _b, _c in e)
        # 缺省 = 全链 (最严): 任何阶段的 EDITS 目标都算已登记
    if fams is None:
        fams = families_for("0x0000001C")
    ext = (".sh", ".bat", ".py", ".v", ".vh", ".tcl", ".ps1", ".cmd")
    fails, n_hit = [], 0
    for fam, rx in fams:
        hit = []
        for rel in _fileset(extra):
            if not rel.endswith(ext):
                continue
            if overlay and rel in overlay:
                text = overlay[rel]
                if rx.search(_strip_comment_lines(text)):
                    hit.append(rel)
                continue
            p = os.path.join(REPO, rel.replace("/", os.sep))
            try:
                b = open(p, "rb").read()
            except OSError:
                continue
            if b"\x00" in b[:4096] or len(b) > 4 * 1024 * 1024:
                continue
            if rx.search(_strip_comment_lines(b.decode("utf-8", "replace"))):
                hit.append(rel)
        n_hit += len(hit)
        unreg = []
        for rel in hit:
            if rel in targets:
                continue
            if any(re.search(pat, rel) for pat, _cls in ALLOW):
                continue
            unreg.append(rel)
        print("---- 搜索面 [%s]: 命中 %d 文件 (已登记 %d / 未登记 %d)"
              % (fam, len(hit), len(hit) - len(unreg), len(unreg)))
        for rel in unreg:
            print("FAIL 未登记的命中: %-60s ⇒ 先分类 (三档) 再决定改不改" % rel)
            fails.append("%s:%s" % (fam, rel))
    print("SEARCH_FACE %s (%d 族 / %d 命中文件)" % ("OK" if not fails else "FAIL", len(fams), n_hit))
    return fails


def list_face(target):
    """`--face`: 把各族的**每个命中文件 + 分类**打出来 (任务 1 全表的脚本面)。"""
    chain = chain_for(target)
    targets = set(rel for st in chain for rel, _a, _w, _c in st[1])
    fams = families_for(target)
    ext = (".sh", ".bat", ".py", ".v", ".vh", ".tcl", ".ps1", ".cmd")
    rows = []
    for fam, rx in fams:
        for rel in _fileset():
            if not rel.endswith(ext):
                continue
            p = os.path.join(REPO, rel.replace("/", os.sep))
            try:
                b = open(p, "rb").read()
            except OSError:
                continue
            if b"\x00" in b[:4096] or len(b) > 4 * 1024 * 1024:
                continue
            if not rx.search(_strip_comment_lines(b.decode("utf-8", "replace"))):
                continue
            cls = "EDITS 目标 (现役/已同步)" if rel in targets else None
            if cls is None:
                for pat, c in ALLOW:
                    if re.search(pat, rel):
                        cls = c
                        break
            rows.append((fam, rel, cls or "**未登记**"))
    for fam, rel, cls in rows:
        print("%-13s | %-74s | %s" % (fam, rel, cls))
    print("--face (target %s) 共 %d 行 (%d 文件)" % (target, len(rows), len(set(r[1] for r in rows))))
    return 0


def _apply_stage_on_overlay(overlay, bk, edits):
    """把**一阶段**的 edits 在 overlay 上应用 (逐条: 命中数 == n ⇒ 应用; ==0 且 new 已在 ⇒ 跳过)。
    返回 (applied, skipped, ok)。"""
    applied = skipped = 0
    for rel, old, new, n in edits:
        p = os.path.join(REPO, rel.replace("/", os.sep))
        b, nl = rd(p)
        cur = overlay.get(rel) or b.decode("utf-8")
        old2 = old.replace(chr(10), nl.decode())
        new2 = new.replace(chr(10), nl.decode())
        k = cur.count(old2)
        if k == n:
            overlay[rel] = cur.replace(old2, new2)
            applied += 1
        elif k == 0 and new2 in cur:
            skipped += 1
        else:
            print("FAIL 阶段 %s %-52s hits=%d/%d (锚点缺失或半应用)" % (bk, rel, k, n))
            return applied, skipped, False
    return applied, skipped, True


def rehearse(target):
    """**沙盘彩排**（不落盘）: 把**剩余阶段**（tree_gen 之后的）逐阶段**在内存里**应用成 overlay,
    再按**目标代**的几何跑 A/B/C/D 断言 —— 期望**全绿**。
    ⚠️ 盘上可能已被别的 agent 推到中途代 ⇒ 只做 `bid > tree_gen` 的阶段（更早的记为"已在盘上"）。
    ⛔ 仓内文件**一个字节都不动**（overlay 只活在进程内存里）。"""
    chain = chain_for(target)
    todo = stages_to_do(target)
    gen = tree_gen()
    print("REHEARSE 盘上读侧代 (哨兵 %s) = %s; 目标 = %s" % (SENTINEL, gen, target))
    print("REHEARSE 阶段链: %s" % " -> ".join("%s(%s, %d 处)%s"
          % (b, n, len(e), "" if any(b == t[0] for t in todo) else "[已在盘上]")
          for b, e, n, _w, _u in chain))
    overlay = {}
    for bk, edits, nm, _w, _u in todo:
        applied, skipped, ok = _apply_stage_on_overlay(overlay, bk, edits)
        print("REHEARSE 阶段 %s (%s): applied=%d / skipped=%d" % (bk, nm, applied, skipped))
        if not ok:
            return 1
    nw, unimpl = stage_nw(target), stage_unimpl(target)
    targets = set(rel for st in chain for rel, _a, _w2, _c in st[1])
    fails = []
    print("---- 彩排 A/B/C/D (内存 overlay; 仓内文件不动; 按目标代几何 NW=%d / 未实现 0x%X) ----"
          % (nw, unimpl))
    fails += assert_tables(nw, overlay, unimpl)
    fails += assert_search_face(overlay, None, targets=targets, fams=families_for(target))
    fails += assert_defaults(nw, target, overlay, unimpl)
    fails += assert_edit_coverage(todo[-1][1] if todo else chain[-1][1])
    print("REHEARSE %s (target %s; 剩余 %d 阶段 / 末阶段 %d edits; %d fail)"
          % ("OK —— 全绿 ⇒ 清单完整且自洽" if not fails else "FAIL", target,
             len(todo), len(todo[-1][1]) if todo else 0, len(fails)))
    return 1 if fails else 0


def negctl(name, target):
    """负对照 (判据要有牙): 在 **tempfile 里的故意破坏副本**上重跑**同一套**断言函数
    (同一条代码路径), 必须看到 FAIL。几何按**目标代** (NW / 未实现地址)。
    ⛔ 仓内文件一个字节都不动 —— 破坏件写在 `tempfile.mkdtemp()` 里, 靠 `overlay` 注入。
    RC 约定: **0 = 负对照成立 (断言确实变红)** / **1 = 负对照失败 (断言没牙)** / 2 = 未知档。"""
    nw, unimpl = stage_nw(target), stage_unimpl(target)
    chain = chain_for(target)
    tgts = set(rel for st in chain for rel, _a, _w, _c in st[1])
    pred = predecessor_bid(target) or "0x0000001A"
    tmp = tempfile.mkdtemp(prefix="readside_negctl_")
    try:
        overlay, extra, title = {}, [], ""
        if name == "table":      # 1 表长断言: 把 WLABEL 的**末项** (任意代) 删掉
            src = "_proj_pcie/p6e_snap_check.sh"
            s = _src(src)
            # 找 WLABEL 的**末项** (不写死那一行的文字 —— 它逐代变: 构建 F / M1): 用
            # `)⏎for (( i = 0; i < SNAP_WORDS` 定位闭括号, 再往前抓最后一个引号项。
            tail = chr(10) + 'for (( i = 0; i < SNAP_WORDS'
            i = s.index(tail)
            j = s.rindex(')', 0, i)              # WLABEL 的闭括号
            k = s.rindex('"', 0, j)              # 末项的闭引号
            l = s.rindex('"', 0, k)              # 末项的开引号
            while l > 0 and s[l-1] in ' \t':
                l -= 1                            # 连前面的空白一起去掉
            bad = s[:l] + s[k+1:]
            assert bad != s, "负对照 table: 末项锚点没命中"
            title = "把 %s 的 WLABEL 末项删掉 (表长 %d → %d)" % (src, nw, nw - 1)
            overlay = {src: bad}
        elif name == "bid":      # 2 默认值断言: 把 EXPECT_BID 改成一个**必然不等于目标值**的值
            src = "_proj_10g/notes/p7b_affinity/j6_r6fix.sh"
            s = _src(src)
            bad, nsub = re.subn(r"(?m)^EXPECT_BID=\$\{EXPECT_BID:-0x[0-9A-Fa-f]+\}",
                                "EXPECT_BID=${EXPECT_BID:-0x00000009}", s)
            assert nsub == 1, "负对照 bid: 锚点没命中 (nsub=%d)" % nsub
            title = "把 %s 的 EXPECT_BID 改成 0x00000009 (≠ 目标 %s)" % (src, target)
            overlay = {src: bad}
        elif name == "tier":     # 3 TIER_TOP 断言: 把档表**首行**改成错代 (错 BID)
            src = "_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh"
            s = _src(src)
            bad, nsub = re.subn(r'(?m)^  "\d+\|0x[0-9A-Fa-f]+\|', '  "70|0x00000009|', s, count=1)
            assert nsub == 1, "负对照 tier: 锚点没命中 (nsub=%d)" % nsub
            title = "把 %s 的档表**首行**改成 70|0x00000009 ⇒ TIER_TOP 必须红" % src
            overlay = {src: bad}
        elif name == "face":     # 4 搜索面: 未登记路径的新文件带**上一代值**
            src = "_proj_10g/notes/p7b_newround_2099/new_runner.sh"
            body = "#!/bin/bash" + chr(10) + "BID_EXPECT=${BID_EXPECT:-%s}" % pred \
                   + chr(10) + "NW=${NW:-%d}" % nw + chr(10)
            extra = [src]
            overlay = {src: body}
            title = "造一个**未登记路径**的新文件 %s (带 BID_EXPECT=%s = 目标 %s 的上一代)" % (src, pred, target)
        else:
            print("NEGCTL 未知名: %s" % name)
            return 2
        p = os.path.join(tmp, os.path.basename(src))
        io.open(p, "w", encoding="utf-8", newline="").write(overlay[src])
        print("NEGCTL 破坏件 (临时副本, 仓内原件不动): %s" % p)
        print("NEGCTL 做法: %s" % title)
        if name == "table":
            fails = assert_tables(nw, overlay, unimpl)
        elif name in ("bid", "tier"):
            fails = assert_defaults(nw, target, overlay, unimpl)
        else:
            fails = assert_search_face(overlay, extra, targets=tgts, fams=families_for(target))
        if name in ("bid", "tier"):
            key = "%s[%s]" % (src, "BID" if name == "bid" else "TIER_TOP")
            hit = key in fails
            print("NEGCTL 目标断言: %s ⇒ %s" % (key, "✅ 在 FAIL 名单里" if hit else "❌ 不在 (破坏没打中该断言!)"))
            teeth = bool(fails) and hit
            detail = ("断言确实变红 (共 %d 条 FAIL, 含目标 %s)" % (len(fails), key)) if teeth else "断言没红/目标没打中"
        else:
            teeth = bool(fails)
            detail = ("断言确实变红 (共 %d 条 FAIL)" % len(fails)) if teeth else "断言没红"
        print("NEGCTL_VERDICT %s (%s) ⇒ %s"
              % ("有牙" if teeth else "没牙", detail,
                 "真实运行会 FAIL 并非零退出" if teeth else "这条断言在真仓里永远绿!"))
        print("NEGCTL_EXIT=%d" % (1 if teeth else 0))
        return 1 if teeth else 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def parse_target(args):
    """`--bid 0x1C` / `--bid=0x1C` / 缺省 ⇒ ("0x0000001C", 是否显式)。接受大小写与前后导零。"""
    val = None
    for i, a in enumerate(args):
        if a == "--bid":
            val = args[i + 1] if i + 1 < len(args) else None
        elif a.startswith("--bid="):
            val = a.split("=", 1)[1]
    if val is None:
        return "0x0000001C", False        # 缺省 = 缺陷刀 (2026-10-11 现状兼容)
    t = val.strip().upper().replace("0X", "").lstrip("0") or "0"
    for b in ALL_BIDS:
        if b.upper().replace("0X", "").lstrip("0") == t:
            return b, True
    raise SystemExit("不支持的 --bid: %s (支持: %s)" % (val, " / ".join(ALL_BIDS)))


def _one_edit_hits(rel, old):
    """该 edit 的 old 侧在**盘上**的命中数 (行尾按文件自身风格)。"""
    p = os.path.join(REPO, rel.replace("/", os.sep))
    b, nl = rd(p)
    return b.decode("utf-8").count(old.replace("\n", nl.decode()))


def main():
    args = sys.argv[1:]
    do_apply = "--apply" in args                 # ⚠️ 默认 dry-run（与 F 轮的 --check 语义相反）
    only_assert = "--assert" in args             # 只跑 ⑧ 四条断言 (不同步, 用于"扩了搜索面重跑")
    neg = [a.split("=", 1)[1] for a in args if a.startswith("--negctl=")]
    target, explicit = parse_target(args)
    chain = chain_for(target)
    todo = stages_to_do(target)                  # 只做 `bid > 盘上代` 的阶段 (树可能已被别人推过)
    edits = todo[-1][1] if todo else chain[-1][1]
    # 过滤出"位置参数"给未知参数检查 (`--bid` 的值不是开关)
    rest, i = [], 0
    while i < len(args):
        if args[i] == "--bid":
            i += 2
            continue
        if args[i].startswith("--bid="):
            i += 1
            continue
        rest.append(args[i])
        i += 1
    if neg:
        return negctl("=".join(neg), target)
    if "--face" in rest:
        return list_face(target)
    if "--rehearse" in rest:
        return rehearse(target)
    unknown = [a for a in rest
               if a not in ("--apply", "--assert", "--dry-run", "--rehearse", "--face")]
    if unknown:
        print("未知参数: %s" % " ".join(unknown))
        print("用法: [--bid 0x1C|0x1D|0x1E|0x1F] [--dry-run|--apply] [--assert] [--rehearse] [--face] [--negctl=名]")
        return 2
    nw, bid_auto = authoritative()
    unimpl = stage_unimpl(target)
    gen = tree_gen()
    print("TARGET BID = %s (%s) · 目标代几何: NW=%d / 未实现地址=0x%X"
          % (target, "显式 --bid" if explicit else "缺省值", stage_nw(target), unimpl))
    print("盘上读侧代 (哨兵 %s) = %s; 待做阶段 = %s"
          % (SENTINEL, gen, " -> ".join("%s(%d 处)" % (b, len(e)) for b, e, _n, _w, _u in todo) or "(无)"))
    print("AUTHORITY board/wrapper_p4.v: SNAP_NW_P6E = %d / BUILD_ID_V = %s"
          % (nw, bid_auto))
    if bid_auto != target:
        print("⚠️ 现读 wrapper 的 BUILD_ID_V (= %s) != 目标 (= %s) —— 目标值按【显式/缺省给定】钉死,"
              " **不**从漂移中的权威源推导 (构建 agent 可能在改它 ⇒ 待构建收口后**复读复核**)。"
              % (bid_auto, target))
    if nw != stage_nw(target):
        print("⚠️ 现读 wrapper 的 NW (= %d) != 目标代 NW (= %d) —— 几何断言按**目标代**比。"
              % (nw, stage_nw(target)))
    if not todo:
        print("ℹ️ 盘上读侧代 (= %s) 已 ≥ 目标 (= %s) ⇒ **无待做阶段**; 只跑断言复核。" % (gen, target))
    print("MODE %s (target %s; 待做 %d 阶段 / 共 %d 处 edit)"
          % ("APPLY (真改仓内文件)" if do_apply else "DRY-RUN (只报命中数, 不落盘)",
             target, len(todo), sum(len(e) for _b, e, _n, _w, _u in todo)))
    if do_apply and len(todo) > 1:
        print("ℹ️ 链式落盘: %s (阶段按序; 任一阶段有红 ⇒ 停在其后, 不再往下写)"
              % " -> ".join(b for b, _e, _n, _w, _u in todo))
    fails = []
    stop = False
    overlay = {}                                 # 链式视图: 前阶段的新侧在这里 (与盘上一致)
    if len(todo) > 1:
        print("ℹ️ hits 按**链式视图**算 (第 2 阶段起, 前阶段的新侧已在内存/盘上) ⇒ 干跑与 apply 同视图。")
    for bk, stage_edits, nm, sw, su in ([] if only_assert else todo):
        if stop:
            print("⛔ 前一阶段有红 ⇒ 阶段 %s 不再落盘 (保持树在半代之外, 便于诊断)" % bk)
            break
        print("---- 阶段 %s (%s): %d 处 edit (几何 NW=%d / 未实现 0x%X) ----" % (bk, nm, len(stage_edits), sw, su))
        for rel, old, new, n in stage_edits:
            p = os.path.join(REPO, rel.replace("/", os.sep))
            b, nl = rd(p)
            old2 = old.replace("\n", nl.decode())
            new2 = new.replace("\n", nl.decode())
            cur = overlay.get(rel) or b.decode("utf-8")
            k = cur.count(old2)
            if k == n:
                tag = "OK  "
            elif k == 0 and new2 in cur:
                tag = "SKIP"                     # 该处已在盘上 (别人先落了, 或本阶段内已应用) ⇒ 不算红
            else:
                tag = "FAIL"
            print("%s %-56s hits=%d/%d  %s" % (tag, rel, k, n, old.split("\n")[0].strip()[:42]))
            if tag == "FAIL":
                fails.append((rel, k, n, old.split("\n")[0][:80]))
                if do_apply:
                    stop = True
                continue
            overlay[rel] = cur.replace(old2, new2)
            if do_apply and (k == n):
                # ⚠️ 判据用 `k == n`（不是 tag 字符串比较）—— 2026-10-11 曾因写成 `tag == "OK"`
                #    而 tag 实际是带对齐空格的 `"OK  "` ⇒ **写盘分支结构性永不执行**
                #    （干跑看着全对, apply 后文件一个字节没变）。此类"比较的字面量不是同一物"
                #    属哑门族 ⇒ 一律用**数值条件**而不是显示用的字符串。
                io.open(p, "w", encoding="utf-8", newline="").write(overlay[rel])

    # ---- ⑧ 四条结构性断言 (每次都跑; 任一条红 ⇒ 退出码 != 0) ----
    print("")
    if not do_apply and not only_assert:
        print("⚠️ 读法: A/B/C/D 跑在**未 apply 的现状**上 —— C 的红 = **待改处**"
              "(apply 后必须逐条转绿); A/B 的红才是真问题。")
    print("---- A. 表长断言 (每张表的项数必须 == NW=%d) ----" % stage_nw(target))
    fails += assert_tables(stage_nw(target), None, unimpl)
    print("---- B. 搜索面全扫 (旧值字面值 + 三个命名族; 未登记即红) ----")
    fails += assert_search_face(targets=set(rel for st in chain for rel, _a, _w, _c in st[1]),
                                fams=families_for(target))
    print("---- C. 默认值一致性 (读侧默认值 == 目标 BID %s; 未实现地址 0x%X) ----" % (target, unimpl))
    fails += assert_defaults(stage_nw(target), target, None, unimpl)
    print("---- D. 清单-断言覆盖 (每个 EDITS 目标必须自带断言) ----")
    fails += assert_edit_coverage(todo[-1][1] if todo else chain[-1][1])
    print("APPLY_READSIDE_BID %s (target %s, %d 阶段 / %d 处 edit, %d fail)"
          % ("OK" if not fails else "FAIL", target, len(todo),
             sum(len(e) for _b, e, _n, _w, _u in todo), len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
