p = 'B/run.bat'
b = open(p, 'rb').read()
old = b'%TB%\\tb_p5_wrapper.v > xvlog_w.log'
new = b'%~dp0tb_probe.v > xvlog_w.log'
assert old in b, 'not found'
b = b.replace(old, new)
open(p, 'wb').write(b)
print('ok')
