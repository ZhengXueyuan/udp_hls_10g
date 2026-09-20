# -*- coding: utf-8 -*-
"""udp_rx.v 补齐 (容错行尾/同一行的两种清单写法)。"""
import io

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
    if 'udp_rx.v' in d:
        print('already has udp_rx.v   ', f)
        continue
    assert 'udp_split.v' in d, f
    line = [l for l in d.replace('\r\n', '\n').split('\n') if 'udp_split.v' in l][0]
    indent = line[:len(line) - len(line.lstrip())]
    if line.lstrip().startswith('%RTL%\\udp_split.v'):
        # 独占一行: 在前一行位置插入 udp_rx.v
        for eol in ('\r\n', '\n'):
            tgt = indent + '%RTL%\\udp_split.v' + eol
            if tgt in d:
                d = d.replace(tgt, indent + '%RTL%\\udp_rx.v' + eol + tgt, 1)
                break
    else:
        d = d.replace('%RTL%\\udp_split.v', '%RTL%\\udp_rx.v %RTL%\\udp_split.v', 1)
    io.open(f, 'wb').write(d.encode('latin-1'))
    print('patched                ', f)

for f in (r'board/build_p5.tcl', r'board/timing_p5.tcl'):
    d = io.open(f, 'rb').read().decode('latin-1')
    if 'rtl/udp_rx.v' in d:
        print('already has udp_rx.v   ', f)
        continue
    done = False
    for eol in ('\r\n', '\n'):
        tgt = '${root_dir}/rtl/udp_split.v \\' + eol
        if tgt in d:
            d = d.replace(tgt, '${root_dir}/rtl/udp_rx.v \\' + eol + tgt, 1)
            done = True
            break
    assert done, f
    io.open(f, 'wb').write(d.encode('latin-1'))
    print('patched                ', f)
