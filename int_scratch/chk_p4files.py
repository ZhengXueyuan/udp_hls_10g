# 独立审查: P4 矩阵门编译的源文件 —— ECO 工作区 vs 本仓 HEAD 逐字节比较
import io, re, os, hashlib, subprocess, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
ECO = r'D:\repo\ECO\udp_hls_10g'
PREF = 'D:' + chr(92) + 'repo' + chr(92) + 'ECO' + chr(92) + 'udp_hls_10g' + chr(92)
bats = ['sim/p4sim/run_tb_p4_chain.bat', 'sim/p4sim/run_tb_p4_burst.bat',
        'sim/p4sim/run_tb_p4_chain_vlan.bat', 'sim/p4sim/run_tb_p4_burst_vlan.bat',
        'sim/p4sim/run_tb_p4_chain_stall.bat', 'sim/retxsim/run_retx_tb.bat',
        'sim/retxsim2/run_tb_frame_fifo.bat', 'sim/vlansim/run_tb_vlan_strip.bat',
        'sim/tbgate/run_tb_uart_dbg.bat']
pat = re.compile(re.escape(PREF) + r'([^\s^"]+\.(?:v|py))')
files = set()
for b in bats:
    t = io.open(b, encoding='latin-1').read()
    for m in pat.finditer(t):
        files.add(m.group(1).replace(chr(92), '/'))
same = diff = miss = 0
dl = []
for f in sorted(files):
    ep = os.path.join(ECO, f.replace('/', os.sep))
    if not os.path.exists(ep):
        miss += 1; dl.append((f, 'ECO 无此文件')); continue
    e = hashlib.md5(io.open(ep, 'rb').read()).hexdigest()
    l = hashlib.md5(subprocess.run(['git', 'show', 'HEAD:' + f], capture_output=True).stdout).hexdigest()
    w = hashlib.md5(io.open(f, 'rb').read()).hexdigest() if os.path.exists(f) else 'N/A'
    if e == l:
        same += 1
        if e != w:
            dl.append((f, 'ECO==本仓HEAD, 但本仓工作区已改 (P6b/F4)'))
    else:
        diff += 1; dl.append((f, '本仓HEAD(%s) != ECO(%s)' % (l[:8], e[:8])))
print('P4 门编译的源文件数=%d  逐字节相同=%d  不同=%d  ECO缺=%d' % (len(files), same, diff, miss))
for f, w in dl:
    print('   ', f, w)
