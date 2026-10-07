import hashlib
import importlib.util
import io
import os
import sys

sys.dont_write_bytecode = True   # 别往作者目录里写 __pycache__ (审查纪律: 不碰别人的目录)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
AUTHOR = os.path.join(ROOT, 'sim', 'p7b_stageb_rx8')

spec = importlib.util.spec_from_file_location('apply_rx8', os.path.join(AUTHOR, 'apply_rx8.py'))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)          # 只加载定义 (main 有 __main__ 守卫, 不会写文件)

old = mod.rd(mod.ORIG)
funcs = mod.extract_funcs(mod.UDP)
gen = mod.build(old, funcs)

disk = io.open(os.path.join(ROOT, 'rtl', 'app_pattern.v'), encoding='utf-8', newline='').read()
same = (gen == disk)
h = hashlib.sha256(disk.encode('utf-8')).hexdigest()
print('apply_rx8.py build() output == rtl/app_pattern.v on disk :', 'IDENTICAL' if same else 'DIFFER')
print('rtl/app_pattern.v sha256 =', h)
print('author claimed sha256    = da7a2c7c6876000b...  (prefix match:', h.startswith('da7a2c7c6876000b'), ')')
sys.exit(0 if same else 1)
