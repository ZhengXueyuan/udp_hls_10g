# -*- coding: utf-8 -*-
"""udp_rx.v 补齐 (同一行写法: 在 %RTL%\\udp_split.v 前插入)。"""
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
        print('ok (has udp_rx.v)     ', f)
        continue
    for eol in ('\r\n', '\n'):
        # 独占一行
        tgt = '%RTL%\\udp_split.v' + eol
        if tgt in d:
            # 保留缩进
            idx = d.find(tgt)
            bol = d.rfind(eol, 0, idx) + len(eol)
            indent = d[bol:idx]
            d = d.replace(tgt, indent + '%RTL%\\udp_rx.v' + eol + tgt, 1)
            print('patched (own line)    ', f)
            break
        # 同行
        if '%RTL%\\udp_split.v' in d:
            d = d.replace('%RTL%\\udp_split.v',
                          '%RTL%\\udp_rx.v %RTL%\\udp_split.v', 1)
            print('patched (same line)   ', f)
            break
    else:
        print('MISSED                ', f)
        continue
    io.open(f, 'wb').write(d.encode('latin-1'))
