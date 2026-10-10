# -*- coding: utf-8 -*-
"""G 臂 v2: 加 PCIE_OBS (sys_clk_p/n 端口在 ifdef PCIE_OBS 内) + PCIE_OBS 需要的 4 个文件。"""
import os
G = r'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_p5wrapper_diag_20261010\work\G'
p = os.path.join(G, 'run.bat')
b = open(p, 'rb').read()
b = b.replace(rb'-d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN',
              rb'-d APP_MODE -d DP_156MHZ -d PCIE_OBS -d P6B_SIM_CLKGEN')
o = rb'  %RTL%\fifo_async.v %RTL%\clk_gen_p6b.v ^' + b'\r\n'
assert o in b, 'anchor missing'
extra = (rb'  %RTL%\snap_cdc.v %RTL%\snap_seq.v ^' + b'\r\n' +
         rb'  %REPO_ROOT%\_proj_pcie\rtl\axi_regs.v %REPO_ROOT%\sim\p6e_pcie\xdma_0_sim_stub.v ^' + b'\r\n')
b = b.replace(o, o + extra)
open(p, 'wb').write(b)
print('patched; -d lines:')
for l in b.split(b'\r\n'):
    if b'-d APP_MODE' in l:
        print('   ', l.decode('ascii'))
