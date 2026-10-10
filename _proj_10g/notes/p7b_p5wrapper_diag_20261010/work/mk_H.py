# -*- coding: utf-8 -*-
"""任务2: 第三个同族门 p5e_udp_wrapper —— 用 E 臂的修好 wrapper 副本重跑。
只读仓内文件; 写全落在 work/H。"""
import os, shutil
W = r'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_p5wrapper_diag_20261010\work'
R = r'D:\repo\XCKU5PMini\udp_hls_10g'
H = os.path.join(W, 'H')
os.makedirs(H, exist_ok=True)
shutil.copyfile(os.path.join(R, 'sim', 'p5e_udp', 'run_tb_p5e_udp_wrapper.bat'), os.path.join(H, 'run.bat'))
for f in ('wrapper_p4.v', 'uart_dbg.v', 'util_gmii_to_rgmii.v'):
    shutil.copyfile(os.path.join(W, 'E', f), os.path.join(H, f))   # E = 修好的副本

p = os.path.join(H, 'run.bat')
b = open(p, 'rb').read()
old_root = (b'set "REPO_ROOT=%~dp0..\\..\\."\r\n'
            b'for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"\r\n'
            b'if "%REPO_ROOT:~-1%"=="\\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"\r\n')
assert old_root in b, 'root block'
b = b.replace(old_root, rb'set "REPO_ROOT=D:\repo\XCKU5PMini\udp_hls_10g"' + b'\r\n')
assert b'set BD=%REPO_ROOT%\\board' in b
b = b.replace(b'set BD=%REPO_ROOT%\\board', b'set BD=%~dp0.')
open(p, 'wb').write(b)
print('H ready; BD line:', [l for l in b.split(b'\r\n') if l.startswith(b'set BD')])
