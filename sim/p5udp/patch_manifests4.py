# -*- coding: utf-8 -*-
"""udp_split.v 例化 rtl/udp_rx.v (P1 模块) —— 所有 APP_MODE 清单必须同时补进
udp_rx.v (此前只有 P1 三门用得到它)。坑 11/C12: 漏一个 = 门/板跑不起来。"""
import io

# 1) bat 清单 (在 udp_split.v 之前插入 udp_rx.v)
bats = [
    r'sim/p5sim/run_tb_p5_wrapper.bat',
    r'sim/p5sim/run_tb_p5_app.bat',
    r'sim/p5sim/run_tb_p5_adv.bat',
    r'sim/p5sim/run_tb_p5_flow.bat',
    r'sim/p5b_acc/wrapper/run_wrapper.bat',
    r'sim/p5b_ind2/run_tb_p5_wrapper.bat',
    r'sim/p5c_t4reg/run_tb_p5_wrapper.bat',
    r'sim/p5c_t5/run_tb_p5_wrapper.bat',
    r'sim/p5c_t5/g_p5/run_tb_p5_wrapper.bat',
    r'sim/p5d_multi/p5dpriv/p5sim/run_tb_p5_wrapper.bat',
    r'sim/p5c_t3/rev/run_wrapper_elab_chk.bat',
]
for f in bats:
    d = io.open(f, 'rb').read().decode('latin-1')
    done = False
    for eol in ('\r\n', '\n'):
        old = 'udp_split.v' + eol
        if old in d and ('udp_rx.v' + eol) not in d:
            # 沿用该行的缩进: 找到包含 udp_split.v 的那一行的前缀
            for line in d.split(eol):
                if 'udp_split.v' in line:
                    indent = line[:len(line) - len(line.lstrip())]
                    break
            new = indent + '%RTL%\\udp_rx.v' + eol + 'udp_split.v' + eol
            d2 = d.replace('udp_split.v' + eol, new, 1)
            io.open(f, 'wb').write(d2.encode('latin-1'))
            print('patched', f, '(eol=%s)' % ('crlf' if eol == '\r\n' else 'lf'))
            done = True
            break
    if not done:
        print('SKIP (no change needed?)', f)

# 2) Vivado 工程 tcl
for f in (r'board/build_p5.tcl', r'board/timing_p5.tcl'):
    d = io.open(f, 'rb').read().decode('latin-1')
    old = '${root_dir}/rtl/udp_split.v \\\n'
    new = '${root_dir}/rtl/udp_rx.v \\\n                         ${root_dir}/rtl/udp_split.v \\\n'
    if old in d and 'rtl/udp_rx.v' not in d:
        io.open(f, 'wb').write(d.replace(old, new, 1).encode('latin-1'))
        print('patched', f)
    else:
        print('SKIP', f)
