# -*- coding: utf-8 -*-
"""建 G 臂 (APP_MODE + DP_156MHZ + P6B_SIM_CLKGEN): bat 副本 + TB 副本 (驱动 sys_clk_p/n)。
只读仓内文件; 所有写都落在 work/G。"""
import os, shutil
W = r'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_p5wrapper_diag_20261010\work'
G = os.path.join(W, 'G')
R = r'D:\repo\XCKU5PMini\udp_hls_10g'
os.makedirs(G, exist_ok=True)

# ---- bat ----
b = open(os.path.join(W, 'A', 'run.bat'), 'rb').read()
o1 = b'call %XV%\\xvlog.bat -work xil_defaultlib -d APP_MODE -f hls_files_w.f'
assert o1 in b
b = b.replace(o1, b'call %XV%\\xvlog.bat -work xil_defaultlib -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN -f hls_files_w.f')
o2 = b'call %XV%\\xvlog.bat -work xil_defaultlib -d APP_MODE ^\r\n'
assert o2 in b
b = b.replace(o2, b'call %XV%\\xvlog.bat -work xil_defaultlib -d APP_MODE -d DP_156MHZ -d P6B_SIM_CLKGEN ^\r\n')
o3 = b'  %RTL%\\crc32_8b.v %RTL%\\fifo_sync.v %RTL%\\checksum16.v %RTL%\\frame_fifo.v ^\r\n'
assert o3 in b
b = b.replace(o3, o3 + b'  %RTL%\\fifo_async.v %RTL%\\clk_gen_p6b.v ^\r\n')
o4 = b'  %TB%\\tb_p5_wrapper.v > xvlog_w.log'
assert o4 in b
b = b.replace(o4, b'  %~dp0tb_dp.v > xvlog_w.log')
open(os.path.join(G, 'run.bat'), 'wb').write(b)
print('G bat written')

# ---- TB (驱动 sys_clk_p/n) ----
t = open(os.path.join(R, 'tb', 'tb_p5_wrapper.v'), encoding='utf-8').read()
o5 = """    reg        reset_n, fpga_gclk, phy1_rxc;"""
assert o5 in t
t = t.replace(o5, """    reg        reset_n, fpga_gclk, phy1_rxc;
    // ---- DIAG G 臂加: KU5P 板 SYS_CLK 100MHz 差分对 (原门未接 => clk_gen 输入悬空) ----
    reg        sysclk = 1'b0;
    always #5 sysclk = ~sysclk;
    wire       sys_clk_p = sysclk;
    wire       sys_clk_n = ~sysclk;""")
o6 = """        .reset_n     (reset_n),"""
assert o6 in t
t = t.replace(o6, """        .reset_n     (reset_n),
        .sys_clk_p   (sys_clk_p),
        .sys_clk_n   (sys_clk_n),""")
open(os.path.join(G, 'tb_dp.v'), 'w', encoding='utf-8', newline='').write(t)
print('G TB written; sysclk lines added:', t.count('sys_clk_p'))
