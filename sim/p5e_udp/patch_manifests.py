# -*- coding: utf-8 -*-
"""P5e-T3 清单镜像补齐: 把 rtl/app_udp_pattern.v 加进所有**例化真 wrapper_p4 且
带 -d APP_MODE** 的文件清单 (工程坑 12: 新增模块必须补全所有例化点/清单)。
只动"文件清单行", 不动任何门逻辑 (候选门目录只做最小机械补齐, 否则它们会因
"module app_udp_pattern not found" 而全部假失败)。
用法: /c/Users/zhxue/anaconda3/python.exe sim/p5e_udp/patch_manifests.py
"""
import io, os

ROOT = r'D:/repo/ECO/udp_hls_10g'

# ---- .bat: 同行内联 (续行 "^" 结构不能插新行) ----
BATS = [
    r'sim/p5b_acc/wrapper/run_wrapper.bat',
    r'sim/p5b_ind2/run_tb_p5_wrapper.bat',
    r'sim/p5c_t3/rev/run_wrapper_elab_chk.bat',
    r'sim/p5c_t4reg/run_tb_p5_wrapper.bat',
    r'sim/p5c_t5/g_p5/run_tb_p5_wrapper.bat',
    r'sim/p5c_t5/run_tb_p5_wrapper.bat',
    r'sim/p5d_multi/p5dpriv/p5sim/run_tb_p5_wrapper.bat',
    r'sim/p5e_t2/run_tb_p5e_t2_wrapper.bat',
    r'sim/p5sim/run_tb_p5_wrapper.bat',
]
# ---- tcl: 反斜杠续行的独占一行 ⇒ 插一整行 ----
TCLS = [
    r'board/build_p5.tcl',
    r'board/timing_p5.tcl',
    r'sim/p5e_t2/route_check.tcl',
    r'sim/p5udp/route_check.tcl',
]


def rd(path):
    full = os.path.join(ROOT, path)
    return full, io.open(full, 'rb').read().decode('latin-1')


def wr(full, d):
    io.open(full, 'wb').write(d.encode('latin-1'))


def main():
    for f in BATS:
        full, d = rd(f)
        if 'app_udp_pattern.v' in d:
            print('ALREADY', f); continue
        if r'app_pattern.v' not in d:
            print('MISS   ', f); continue
        d = d.replace(r'app_pattern.v', r'app_pattern.v %RTL%\app_udp_pattern.v')
        wr(full, d); print('patch  ', f)
    for f in TCLS:
        full, d = rd(f)
        if 'app_udp_pattern.v' in d:
            print('ALREADY', f); continue
        out, hit = [], 0
        for l in d.split('\n'):
            out.append(l)
            if 'rtl/app_pattern.v' in l:
                cr = '\r' if l.endswith('\r') else ''
                out.append('                         ${root_dir}/rtl/app_udp_pattern.v \\' + cr)
                hit += 1
        if hit == 0:
            print('MISS   ', f); continue
        wr(full, '\n'.join(out)); print('patch x%d %s' % (hit, f))
    # 诊断 bat (只 parse wrapper_p4.v, 无 RTL 变量): 用全路径补上模块文件
    f = r'sim/p5d_multi/chk/chkwrap.bat'
    full, d = rd(f)
    if 'app_udp_pattern.v' in d:
        print('ALREADY', f)
    else:
        d = d.replace(r'%BD%\wrapper_p4.v',
                      r'%BD%\wrapper_p4.v D:\repo\ECO\udp_hls_10g\rtl\app_udp_pattern.v')
        wr(full, d); print('patch  ', f)
    print('done')


main()
