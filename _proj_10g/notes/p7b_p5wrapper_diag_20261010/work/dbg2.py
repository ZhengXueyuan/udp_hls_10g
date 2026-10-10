# -*- coding: utf-8 -*-
import re, sys, io, os
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'census2.py')).read().split('# ---------------- 端口方向表')[0].replace(
    "srcfiles = sorted", "raise SystemExit\nsrcfiles = sorted") if False else '')
# 直接重跑 census2 的解析部分: 用它的函数
import importlib.util
spec = importlib.util.spec_from_file_location('c2', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'census2.py'))
# 不能直接 import (会执行全文件) -> 用一次子集执行
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'census2.py'), encoding='utf-8').read()
head = src.split("srcfiles = sorted")[0]
g = {}
exec(compile(head, 'census2_head', 'exec'), g)
portmap = g['portmap']
print('app_pattern ports n =', len(portmap.get('app_pattern', {})))
for p in ['rx_tready', 'stat_bp_cyc', 'stat_tx_bytes', 'm_tvalid', 'm_tready']:
    print('  app_pattern.%s = %s' % (p, portmap.get('app_pattern', {}).get(p, 'MISSING')))
print('axis_pipe ports n =', len(portmap.get('axis_pipe', {})))
print('  axis_pipe.m_valid =', portmap.get('axis_pipe', {}).get('m_valid', 'MISSING'))
print('app_ctrl ports n =', len(portmap.get('app_ctrl', {})))
print('  app_ctrl.dbg_c0_state =', portmap.get('app_ctrl', {}).get('dbg_c0_state', 'MISSING'))

# ---- 例化解析 ----
text = g['text']
act = g['active_lines'](text, {'APP_MODE'})
insts = g['find_insts'](text, act)
print('instances parsed =', len(insts))
for mod, inst, conns, off in insts:
    if inst in ('u_app', 'u_app_pipe', 'u_app_ctrl', 'u_tx_arb', 'u_mac_tx', 'u_tcp_tx'):
        print('  INST %s %s conns=%d  line=%d' % (mod, inst, len(conns), g['line_of'](off)))
print('u_app present:', any(i[1] == 'u_app' for i in insts))
