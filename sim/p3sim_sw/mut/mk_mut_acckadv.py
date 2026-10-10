#!/usr/bin/env python
"""P7B-SNDWND-GUARD 变异件生成器: mut_acckadv = 故意把守卫谓词写错。

变异 = 把 rtl/tcp_rx.v 里两处守卫的 `ackok_l` 换成 `ack_adv_l` (任务点名的坑:
`ack_adv_l` 要求 ACK 推进 ⇒ 零推进的窗口更新 ACK 被判假 ⇒ 零窗恢复被打死)。
期望后果: 腿 B1 红 (snd_wnd 停在 0), 腿 A / B2 仍绿 ⇒ 证明腿 B **测的就是这个谓词**,
不是真空判据 (设计件 §2.2/§4.2 的否决理由的机器证明)。

锚点纪律 (本仓 #72/#75 类坑): 锚点必须**计数断言** —— 现读行内容不符/出现次数
≠2 时硬失败, 不许静默产出"没变异的变异件"。用法:
    python mk_mut_acckadv.py <repo_root> [--out <dir>]
"""
import hashlib
import os
import sys

ANCHOR = '(s_axis_tcrs && (ackok_l | !SNDWND_GUARD))'
MUTANT = '(s_axis_tcrs && (ack_adv_l | !SNDWND_GUARD))'


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.dirname(os.path.abspath(__file__))))), '')
    outdir = None
    if len(sys.argv) > 3 and sys.argv[2] == '--out':
        outdir = sys.argv[3]
    srcpath = os.path.join(root, 'rtl', 'tcp_rx.v')
    outdir = outdir or os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(outdir, 'mut_acckadv.v')

    # ⚠️ 以**二进制**读写: rtl/tcp_rx.v 是 CRLF (929 CRLF) —— 文本模式会把行尾
    #    归一化成 LF, 让"变异件"凭空多出 929 行差异 (且锚点计数题外的坑)
    raw = open(srcpath, 'rb').read()
    src = raw.decode('utf-8')
    n = src.count(ANCHOR)
    assert n == 2, ('anchor count != 2 (stale anchor? guard text changed?): %d' % n)
    mut = src.replace(ANCHOR, MUTANT)
    assert mut.count(MUTANT) == 2 and mut.count(ANCHOR) == 0
    # diff 面 = 恰好 2 行 (两处守卫); 其余逐字相同 (含行尾)
    sl, ml = src.splitlines(), mut.splitlines()
    assert len(sl) == len(ml), 'line count changed'
    diffs = [i + 1 for i in range(len(sl)) if sl[i] != ml[i]]
    assert len(diffs) == 2, ('expected exactly 2 changed lines, got %r' % diffs)
    mraw = mut.encode('utf-8')
    # 字节级不变量: 除两处替换长度差外总字节差 = 2*(len(MUTANT)-len(ANCHOR))
    assert len(mraw) - len(raw) == 2 * (len(MUTANT) - len(ANCHOR))
    assert mraw.count(b'\r\n') == raw.count(b'\r\n'), 'CRLF count changed'
    with open(out, 'wb') as fh:
        fh.write(mraw)
    print('MUTGEN OK src=%s sha256=%s' % (srcpath, hashlib.sha256(raw).hexdigest()[:16]))
    print('MUTGEN OUT %s sha256=%s changed_lines=%r' %
          (out, hashlib.sha256(mraw).hexdigest()[:16], diffs))
    print('MUTGEN SUBST %s' % ANCHOR)
    print('MUTGEN SUBST %s' % MUTANT)


if __name__ == '__main__':
    main()
