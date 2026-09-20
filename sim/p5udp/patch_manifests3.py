# -*- coding: utf-8 -*-
"""run_tb_p5_flow.bat 的清单行尾是 LF (非 CRLF), 单独处理。"""
import io
f = r'sim/p5sim/run_tb_p5_flow.bat'
d = io.open(f, 'rb').read().decode('latin-1')
for eol_name, eol in (('crlf', '\r\n'), ('lf', '\n')):
    old = '  %RTL%\\slow_cfg_adp.v ^' + eol
    new = '  %RTL%\\slow_cfg_adp.v ^' + eol + '  %RTL%\\udp_split.v ^' + eol
    if d.count(old) == 1:
        io.open(f, 'wb').write(d.replace(old, new).encode('latin-1'))
        print('patched (%s)' % eol_name, f)
        break
else:
    raise SystemExit('pattern not found')
