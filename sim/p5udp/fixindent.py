# -*- coding: utf-8 -*-
import io
f = r'board/build_p5.tcl'
d = io.open(f, 'rb').read().decode('latin-1')
bad = '${root_dir}/rtl/udp_split.v \\\r\n'
good = '                         ${root_dir}/rtl/udp_split.v \\\r\n'
assert bad in d
io.open(f, 'wb').write(d.replace(bad, good, 1).encode('latin-1'))
print('indent fixed')
