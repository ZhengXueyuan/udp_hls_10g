# 生成 P4 门的**隔离副本** (p4iso/): 把 bat 里的 sim\p4sim 路径换成
# sim\p5d_multi\p4iso, 这样 xsim.dir 与 stim 文件都不与其它 agent 共享 (坑 7)。
# 用 chr(92) 拼反斜杠, 避免任何转义层吃掉它。
import io
import os

BS = chr(92)
ROOT = r'D:\repo\ECO\udp_hls_10g'
SRC = os.path.join(ROOT, 'sim', 'p4sim')
DST = os.path.join(ROOT, 'sim', 'p5d_multi', 'p4iso')
OLD = BS.join(['', 'repo', 'ECO', 'udp_hls_10g', 'sim', 'p4sim'])
NEW = BS.join(['', 'repo', 'ECO', 'udp_hls_10g', 'sim', 'p5d_multi', 'p4iso'])

for b in ['run_tb_p4_chain.bat', 'run_tb_p4_burst.bat', 'run_tb_p4_chain_vlan.bat',
          'run_tb_p4_burst_vlan.bat', 'run_tb_p4_chain_stall.bat']:
    raw = io.open(os.path.join(SRC, b), 'r', encoding='utf-8', errors='replace',
                  newline='').read()
    n = raw.count(OLD)
    raw = raw.replace(OLD, NEW)
    io.open(os.path.join(DST, b), 'w', encoding='ascii', errors='replace',
            newline='').write(raw)
    print('%s: %d refs replaced' % (b, n))
