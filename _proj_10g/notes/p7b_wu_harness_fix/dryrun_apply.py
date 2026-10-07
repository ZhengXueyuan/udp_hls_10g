#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dryrun_apply.py -- 对 p7b_biz_win/ 的历史一次性 apply 脚本做**只读干跑**:
   "今天再跑一次, 它会命中哪些锚点 / 会不会真的改写文件?"

做法: 把 `io.open` 打成一个"写模式一律抛异常"的假件 ⇒
  · 若脚本跑到某文件的写盘 ⇒ 打出 WRITE-ATTEMPTED (= 那个文件**今天会被改写**)
  · 若某锚点 MISS ⇒ 脚本自己 `sys.exit("MISS[...]")` ⇒ 打出 MISS + 锚点文本
不写任何文件 (写模式被结构性挡住)。

用法: python dryrun_apply.py <repo_root> <script.py> [<script.py> ...]
"""
import io as _io
import os
import sys

REAL_OPEN = _io.open


class Reader:
    def __init__(self, text):
        self._t = text

    def read(self, *a):
        return self._t

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def fake_open(path, mode="r", *a, **k):
    if "w" in mode or "a" in mode or "+" in mode:
        raise RuntimeError("WRITE-ATTEMPTED %s" % path)
    with REAL_OPEN(path, mode, *a, **k) as fh:
        return Reader(fh.read())


def main():
    try:                                # 本工程坑 16①: GBK 控制台下 print 非 ASCII 会 UnicodeEncodeError
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    root = sys.argv[1]
    scripts = sys.argv[2:]
    os.chdir(root)
    _io.open = fake_open          # 全进程生效: 脚本里 `import io` 拿到的是同一个模块
    for s in scripts:
        print("=" * 74)
        print("SCRIPT %s" % s)
        src = REAL_OPEN(s, encoding="utf-8").read()
        g = {"__name__": "__main__", "__file__": s}
        try:
            exec(compile(src, s, "exec"), g)
            print("  RESULT: 全部锚点命中到**第一个写盘之前**为止?? (不该到这) ")
        except SystemExit as e:
            print("  RESULT: SystemExit => %s" % (e,))
        except RuntimeError as e:
            print("  RESULT: RuntimeError => %s  ⇒ **这个文件今天仍会被改写**" % (e,))
        except Exception as e:                       # noqa
            print("  RESULT: %s: %s" % (type(e).__name__, e))


if __name__ == "__main__":
    main()
