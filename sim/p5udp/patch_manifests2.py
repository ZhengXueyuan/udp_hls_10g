# -*- coding: utf-8 -*-
"""把 rtl/udp_split.v 补进 app/adv/flow 三门 xvlog 清单 (编译覆盖; 这三门不例化
udp_split, 加进去等于给新模块加一道编译门, 不影响任何判据)。

不加: run_tb_p5_fc.bat / run_tb_p5_status.bat / run_tb_p5_pattern.bat ——
      纯单元门 (只编 app_ctrl / app_status_uart / app_pattern), 与 RX 链无关,
      加 udp_split.v 会把它的依赖 (frame_fifo/udp_rx) 变成悬空引用, 反而误导。
"""
import io

edits = [
    (r'sim/p5sim/run_tb_p5_app.bat', 2),
    (r'sim/p5sim/run_tb_p5_adv.bat', 1),
    (r'sim/p5sim/run_tb_p5_flow.bat', 1),
]
OLD_LIST = '  %RTL%\\slow_cfg_adp.v ^\r\n  %RTL%\\tx_arb.v ^'
NEW_LIST = '  %RTL%\\slow_cfg_adp.v ^\r\n  %RTL%\\udp_split.v ^\r\n  %RTL%\\tx_arb.v ^'
OLD_ONE = '%RTL%\\slow_cfg_adp.v %RTL%\\tx_arb.v'
NEW_ONE = '%RTL%\\slow_cfg_adp.v %RTL%\\udp_split.v %RTL%\\tx_arb.v'

for f, expect in edits:
    d = io.open(f, 'rb').read().decode('latin-1')
    n = d.count(OLD_LIST)
    if n:
        d = d.replace(OLD_LIST, NEW_LIST)
    m = d.count(OLD_ONE)
    if m:
        d = d.replace(OLD_ONE, NEW_ONE)
    io.open(f, 'wb').write(d.encode('latin-1'))
    print('%s: list-form=%d one-line=%d (expected %d)' % (f, n, m, expect))
