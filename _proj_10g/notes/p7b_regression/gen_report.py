# -*- coding: utf-8 -*-
"""把 results.json + 各门日志合成 P7B_REGRESSION.md 的"门清单表"段。"""
import io
import json
import os
import re
import sys

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
HERE = os.path.dirname(os.path.abspath(__file__))
LOGDIR = os.path.join(HERE, 'logs')

TRIAGE = {
    # 门名: (归因标签, 依据)
    'p4_rxclass': ('★真回归', 'A/B: 基线 PASS / 本轮 FAIL（fifo_sync not found）'),
    'p4_rxclass_xk': ('★真回归', '同上（同因）'),
    'p5_app_close': ('既存', 'A/B: 基线同红（同两条 MISMATCH）'),
    'p5_wrapper': ('既存', 'A/B: 基线同红（同样 0 帧）'),
    'p5e_t2_wrapper': ('既存', 'A/B: 基线同红（errs=117 逐字同）'),
    'p5e_udp_wrapper': ('既存', 'A/B: 基线同红（errs=1489 逐字同）'),
    'p5b_flowwnd': ('既存', 'A/B: 基线同红'),
    'p5b_ind': ('既存', 'A/B: 基线同红'),
    'p3_tcp_chain': ('既存', 'A/B: 基线同红（窗口陈旧期望 0x3000≠0xC000）'),
    'p3_tcp_echo': ('既存', 'A/B: 基线同红（同 TCBF 陈旧期望）'),
    'p3_tcp_rx': ('既存', 'A/B: 基线同红（hard 段 MAC 统计）'),
    'p3_tcp_tx': ('既存', 'A/B: 基线同红（0 帧 vs 期望 17）'),
    'f4_regress': ('既存', 'A/B: 基线同红（缺文件 + stats 不一致）'),
    'run_tb_tx': ('既存/坏门', 'A/B: 基线同红（xsim 打印用法 ⇒ 调用参数错）'),
    'snapcdc_skew': ('既存/坏门', 'A/B: 基线同红（Module <snap_cdc> not found）'),
    'snapcdc24_p6e': ('既存', 'A/B: 基线同红（1 项失败）'),
    'p6e_pcie_cnt': ('既存', 'A/B: 基线同红（1 项失败）'),
    'p4_chain_active': ('既存', 'A/B: 基线同红（9 errs）'),
    'p4_chain_active_slow': ('既存', 'A/B: 基线同红'),
    'p4_probe': ('既存/坏门', 'A/B: 基线同红（XVLOG_FAIL，路径不存在）'),
    'p4_hlsprobe': ('既存', 'A/B: 基线同红（udp payload mismatch / fcs bad）'),
    'p5d_mech': ('既存', 'A/B: 基线同红（失配字节=8）'),
    'p7b_impl_xvlog_all': ('坏脚本', 'xvlog 不在 PATH ⇒ "命令语法不正确" exit 255'),
    'p5e_udp_portout': ('偶发', '复跑 3/3 EXIT=0；首跑日志有 RAMB36E1 存储碰撞（坑 17）'),
}

MUTE = {
    'p4_matrix16': '哑门(类型②)：runner 尾 `:log` → exit /b 0；矩阵**自带** gates run/failed 汇总，已读',
    'd2_suite': '哑门(类型②)：尾是 echo；自报 GATE wrapper EXIT=1',
    'p5c_rev_elab': '哑门(类型②)：尾是 echo DONE；日志内有 elab 硬失败（udp_tx_cfg/udp_tx_frame not found）',
    'f4_sttrace': '哑门(类型②)：`xsim ... > NUL` 后 `exit /b 0`',
    'p4_replay': '空门：bat 里 `CACK` 笔误，什么都没跑，exit 0',
    'p4indm_4gates': '空/坏脚本：run_4gates.sh 用 cmd 语法 %REPO_ROOT% ⇒ 结果写不出；cmd 跑 .sh 无效',
    'p7b_impl_one': '哑门：日志 XVLOG_RC=1 但 exit 0',
    'unit_retx': '哑门(类型①)：尾是 `type xsim.log` ⇒ 无条件 exit 0',
    'unit_fifo': '哑门(类型①)：尾是 `type xsim.log` ⇒ 无条件 exit 0',
    'p7b_chain': '有判据但**真空**风险：`findstr "VERDICT = PASS" || exit /b 1` 后才 exit /b 0（判据成立）',
    'p7b_mac': '有判据：findstr "VERDICT = PASS" + errorlevel ⇒ exit /b 0（判据成立）',
}


def verdict_line(logp):
    try:
        t = io.open(logp, encoding='utf-8', errors='replace').read()
    except Exception:
        return ''
    lines = [l.strip().replace('\r', '') for l in t.split('\n') if l.strip()]
    gate = [l for l in lines if not l.startswith('#')
            and 'runner: EXIT' not in l]
    for l in reversed(gate):
        if re.search(r'ALL_OK|PASS_ALL|VERDICT\s*=|GATE:|FAIL|MISMATCH|OK\b|'
                     r'errs=|DONE|EXIT=', l, re.I):
            return l[:88]
    return (gate[-1][:88] if gate else '(无输出)')


rows = json.load(io.open(os.path.join(HERE, 'results.json'), encoding='utf-8'))
order = []
out = []
out.append('| # | 门 | 命令 | EXIT | 判据行（日志尾） | 判定 | 归因 |')
out.append('|---|---|---|---|---|---|---|')
for i, r in enumerate(rows, 1):
    n = r['name']
    v = r['verdict']
    if v == 'PASS(neg-as-expected)':
        j = 'PASS(期望非零)'
    elif v == 'PASS':
        j = 'PASS'
    else:
        j = 'FAIL'
    tag = TRIAGE.get(n, ('', ''))[0]
    if v == 'PASS' and n in MUTE:
        j = 'PASS(哑门)'
    cmd = (r['bat'] + (' ' + ' '.join(r['args']) if r['args'] else ''))
    vl = verdict_line(os.path.join(LOGDIR, n + '.log'))
    vl = vl.replace('|', '\\|')
    out.append('| %d | `%s` | `%s` | %s | %s | %s | %s |'
               % (i, n, cmd, r['rc'], vl, j, tag))
io.open(os.path.join(HERE, 'gate_table.md'), 'w', encoding='utf-8',
        newline='\n').write('\n'.join(out) + '\n')
print('写出 %d 行表 -> gate_table.md' % len(rows))
