# 独立审查: 核对 _tmp_make_p4mirror.py 生成的"本仓镜像"是否忠实
# 方法: 把镜像文件做**逆向**路径替换 (LOC -> ECO), 与原件逐字节比较。
#       逆向映射自己写 (不复用生成脚本的函数), 长串优先。
import io, os, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

ECO = 'D:' + chr(92) + 'repo' + chr(92) + 'ECO' + chr(92) + 'udp_hls_10g'
LOC = 'D:' + chr(92) + 'repo' + chr(92) + 'XCKU5PMini' + chr(92) + 'udp_hls_10g'
# 逆向映射: 长串优先 (retxsim2_p6b 必须在 retxsim_p6b 之前)
REV = [(r'sim\retxsim2_p6b', r'sim\retxsim2'), (r'sim\retxsim_p6b', r'sim\retxsim'),
       (r'sim\p4sim_p6b', r'sim\p4sim'), (r'sim\vlansim_p6b', r'sim\vlansim'),
       (r'sim\tbgate_p6b', r'sim\tbgate')]

pairs = []
for a in ['p4sim_p6b/run_tb_p4_chain.bat', 'p4sim_p6b/run_tb_p4_burst.bat',
          'p4sim_p6b/run_tb_p4_chain_vlan.bat', 'p4sim_p6b/run_tb_p4_burst_vlan.bat',
          'p4sim_p6b/run_tb_p4_chain_stall.bat', 'retxsim_p6b/run_retx_tb.bat',
          'retxsim2_p6b/run_tb_frame_fifo.bat', 'vlansim_p6b/run_tb_vlan_strip.bat',
          'tbgate_p6b/run_tb_uart_dbg.bat']:
    src = os.path.join('sim', a.replace('_p6b/', '/'))
    pairs.append((src, os.path.join('sim', a)))

allok = True
for src, mir in pairs:
    if not os.path.exists(mir):
        print('MISSING', mir); allok = False; continue
    s = io.open(src, encoding='latin-1', newline='').read()
    m = io.open(mir, encoding='latin-1', newline='').read()
    back = m
    for x, y in REV:
        back = back.replace(x, y)
        back = back.replace(x.replace(chr(92), '/'), y.replace(chr(92), '/'))
        back = back.replace(x.replace(chr(92), chr(92) * 2), y.replace(chr(92), chr(92) * 2))
    back = back.replace(LOC, ECO).replace(LOC.replace(chr(92), '/'), ECO.replace(chr(92), '/'))
    ok = (back == s)
    if not ok:
        allok = False
    # 统计镜像里还剩多少 LOC / 多少 ECO
    n_loc = m.count('XCKU5PMini'); n_eco = m.count('repo' + chr(92) + 'ECO') + m.count('repo/ECO')
    print('%-42s 逆向还原==原件: %-5s  镜像里 LOC 出现 %d 次, ECO 残留 %d 处' %
          (mir, ok, n_loc, n_eco))
    if not ok:
        import difflib
        for l in list(difflib.unified_diff(s.split('\n'), back.split('\n'), lineterm='', n=0))[:14]:
            print('      ', l[:150])
print('MIRROR_FAITHFUL' if allok else 'MIRROR_NOT_FAITHFUL')
