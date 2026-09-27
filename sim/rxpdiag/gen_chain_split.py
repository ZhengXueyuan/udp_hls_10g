#!/usr/bin/env python
# gen_chain_split.py -- mechanically split the app_status_uart character chain
# (ci -> ~90-deep if/else-if priority mux -> lc -> u_uart/fr_reg/D) into two
# registered stages, WITHOUT changing any expression:
#
#   stage 1 (clocked): per branch i:  sel_r[i] <= hit_i ; ch_r[i] <= hit_i ? EXPR : 0
#   stage 2 (comb):    lc = (|sel_r) ? (ch_r[0] | ... | ch_r[NB-1]) : fix_r
#
# Byte-identical argument:
#   * branch conditions are disjoint (single index or [A,B) range) => at most one
#     ch_r[i] is non-zero => the OR equals the original priority-mux result;
#   * `ci` advances only when a byte is accepted (BIT_LAST+1 ~ 13021 cycles) and
#     uart_dbg samples byte_in only on tx_go => the extra register stage cannot
#     change the emitted stream; during the inter-line gap ci stays 0 so the
#     registers already hold the ci=0 character before a line starts (no special
#     case for the first byte);
#   * branches absent in a given ifdef config have no driver => they stay at their
#     reset value 0 => the OR is unaffected.
import io, os, re

here = os.path.dirname(os.path.abspath(__file__))
rtl = os.path.normpath(os.path.join(here, '..', '..', 'rtl', 'app_status_uart.v'))
src = io.open(rtl, 'r', encoding='utf-8', newline='').read()
lines = src.split('\n')

br = re.compile(r'^(\s*)(?:else\s+)?if\s*\((.*)\)\s*lc\s*=\s*(.*);\s*$')
idx = []
for i, l in enumerate(lines):
    m = br.match(l)
    if m:
        idx.append((i, m.group(1), m.group(2), m.group(3)))
assert idx, 'no branch lines found'
NB = len(idx)
print('branch lines: %d' % NB)

i_first, i_last = idx[0][0], idx[-1][0]
blk_start = None
for i in range(i_first, 0, -1):
    if 'always @(*)' in lines[i]:
        blk_start = i
        break
assert blk_start is not None and i_last > blk_start

nlines = list(lines)
for n, (i, ind, cond, expr) in enumerate(idx):
    nlines[i] = ('%ssel_r[%d] <= (%s);\n%sch_r[%d]  <= (%s) ? (%s) : 8\'h00;'
                 % (ind, n, cond, ind, n, cond, expr))

i_def = None
for i in range(blk_start, i_first):
    if re.match(r'^\s*lc\s*=\s*fix_r;\s*$', lines[i]):
        i_def = i
        break
assert i_def is not None
nlines[blk_start] = '    always @(posedge clk or negedge rst_n) begin'
nlines[i_def] = ("        if (!rst_n) begin\n"
                 "            sel_r <= %d'd0;\n"
                 "            for (chi = 0; chi < %d; chi = chi + 1) ch_r[chi] <= 8'h00;\n"
                 "        end else begin" % (NB, NB))
i_end = None
for i in range(i_last + 1, len(lines)):
    if lines[i].rstrip() == '    end':
        i_end = i
        break
assert i_end is not None
nlines[i_end] = '        end\n    end'

or_terms = ''
for i in range(NB):
    or_terms += 'ch_r[%d]%s' % (i, (' |\n                                '
                                    if (i % 8 == 7 and i != NB - 1) else (' | ' if i != NB - 1 else '')))
decl = (
"    //-------------------------------------------------------------------------\n"
"    // ci -> lc 的**两级切分** (2026-09-27 时序修复; v4 构建 WNS -0.435, 9 条失败\n"
"    //   端点全部是 `u_app_status/ci_reg[*]_replica_/C -> u_app_status/u_uart/fr_reg[*]/D`):\n"
"    //   原结构是一条组合链 ci/快照 -> ~%d 深 if/else-if 优先级链 (内含 hexd/hexc 的\n"
"    //   32 位 nibble mux 与 `ci - A` 减法) -> lc -> fr/D。私有 route_check 实测该链\n"
"    //   **33 级逻辑 / 9.485ns (其中布线 7.418ns, LUT6=27)** —— 深 + 高扇出 (ci 10 位 x\n"
"    //   ~180 个比较器、且全部快照寄存器都要汇进同一条 mux 树) 一起把布线拖垮。\n"
"    //   切法 (表达式一字不改, 只把每个分支的结果寄存):\n"
"    //     stage 1 (posedge): sel_r[i] <= 命中; ch_r[i] <= 命中 ? 该分支的值 : 0\n"
"    //     stage 2 (组合):    lc = |sel_r ? (ch_r 全 OR) : fix_r\n"
"    //   为什么逐字节不变:\n"
"    //     ① 分支条件互斥 (单点或 [A,B) 区间) ⇒ 至多一个 ch_r[i] 非 0 ⇒ OR 恰等于\n"
"    //        原来的优先级 mux 结果;\n"
"    //     ② `ci` 只在字节被收下时 +1 (BIT_LAST+1 ≈ 13021 拍), UART 只在 `tx_go` 那拍\n"
"    //        采 byte_in ⇒ 多一级寄存对**发出的字节**零影响; 行间 gap 里 ci 恒 0 ⇒\n"
"    //        开行前 ch_r/sel_r 已稳定在 ci=0 的结果上, 首字节无需特例;\n"
"    //     ③ 某 ifdef 配置里不存在的分支**没有驱动** ⇒ 停在复位值 0, 不影响 OR。\n"
"    //   代价: 条件算两遍 (比较器翻倍) + %d x 8 位结果寄存器; 换来两条浅路径\n"
"    //        (stage1 ≈ 比较/减法 + hexd ≈ 7 级, stage2 ≈ OR + 一级 mux ≈ 4 级)。\n"
"    //-------------------------------------------------------------------------\n"
"    reg  [%d:0] sel_r;\n"
"    reg  [7:0]  ch_r [0:%d];\n"
"    integer     chi;\n"
"    wire [7:0] lc = (|sel_r) ? (%s) : fix_r;\n"
% (NB, NB, NB - 1, NB - 1, or_terms))
out = '\n'.join(nlines)
k = out.index('    always @(posedge clk or negedge rst_n) begin')
out = out[:k] + decl + out[k:]
io.open(rtl, 'w', encoding='utf-8', newline='').write(out)
print('app_status_uart.v rewritten: %d branches -> sel_r/ch_r + OR stage' % NB)
