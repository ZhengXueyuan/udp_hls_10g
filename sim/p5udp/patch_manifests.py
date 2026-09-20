# -*- coding: utf-8 -*-
"""把 rtl/udp_split.v 补进所有引用 wrapper_p4 的仿真门清单 (坑 11/C12 清单镜像).

不改: sim/p4sim/xvlog_wp4b.bat (默认构建, 不引用 APP_MODE 模块),
      board/build_p5a0.tcl (历史实验脚本, 头部明令不要重跑)。
"""
import io, sys

files = [
    r'sim/p5sim/run_tb_p5_wrapper.bat',
    r'sim/p5b_acc/wrapper/run_wrapper.bat',
    r'sim/p5b_ind2/run_tb_p5_wrapper.bat',
    r'sim/p5c_t4reg/run_tb_p5_wrapper.bat',
    r'sim/p5c_t5/run_tb_p5_wrapper.bat',
    r'sim/p5c_t5/g_p5/run_tb_p5_wrapper.bat',
    r'sim/p5d_multi/p5dpriv/p5sim/run_tb_p5_wrapper.bat',
    r'sim/p5c_t3/rev/run_wrapper_elab_chk.bat',
]
OLD = ('  %RTL%\\slow_rx_adp.v %RTL%\\slow_cfg_adp.v %RTL%\\slow_tx_adp.v '
       '%RTL%\\tx_arb.v ^')
NEW = ('  %RTL%\\slow_rx_adp.v %RTL%\\slow_cfg_adp.v %RTL%\\slow_tx_adp.v ^\r\n'
       '  %RTL%\\udp_split.v %RTL%\\tx_arb.v ^')
OLD2 = ' %RTL%\\slow_tx_adp.v %RTL%\\slow_cfg_adp.v %RTL%\\tx_arb.v '
NEW2 = ' %RTL%\\slow_tx_adp.v %RTL%\\slow_cfg_adp.v %RTL%\\udp_split.v %RTL%\\tx_arb.v '

n = 0
for f in files:
    data = io.open(f, 'rb').read().decode('latin-1')
    if OLD in data:
        data = data.replace(OLD, NEW)
        n += 1
        io.open(f, 'wb').write(data.encode('latin-1'))
        print('patched (list form)  ', f)
    elif OLD2 in data:
        data = data.replace(OLD2, NEW2)
        n += 1
        io.open(f, 'wb').write(data.encode('latin-1'))
        print('patched (one-line form)', f)
    else:
        print('NOT FOUND            ', f)
print('total patched =', n)
