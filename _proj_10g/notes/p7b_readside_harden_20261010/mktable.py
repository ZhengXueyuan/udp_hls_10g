# -*- coding: utf-8 -*-
"""生成任务 1 的**全表** (行级): 路径:行号 | 现写什么 | 维度 | 分类。
   分类源 = `_proj_10g/notes/p7b_buildF/apply_readside.py` 的 FAMILIES / ALLOW / EDITS (单一真相)。
   ⛔ 只读: 本脚本不写任何仓内文件 (只往 stdout 打)。"""
import importlib.util, io, os, re, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
REPO = os.path.abspath(".")
spec = importlib.util.spec_from_file_location(
    "ar", os.path.join(REPO, "_proj_10g", "notes", "p7b_buildF", "apply_readside.py"))
ar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ar)          # ⚠️ import 只建 EDITS 表, 不写盘

targets = set(rel for rel, _a, _b, _c in ar.EDITS)
ext = (".sh", ".bat", ".py", ".v", ".vh", ".tcl", ".ps1", ".cmd", ".md")
rows = []
for fam, rx in ar.FAMILIES:
    for rel in ar._fileset():
        if not rel.endswith(ext):
            continue
        p = os.path.join(REPO, rel.replace("/", os.sep))
        try:
            b = open(p, "rb").read()
        except OSError:
            continue
        if b"\x00" in b[:4096] or len(b) > 4 * 1024 * 1024:
            continue
        text = b.decode("utf-8", "replace")
        ismd = rel.endswith(".md")
        scan = text if ismd else ar._strip_comment_lines(text)
        for i, line in enumerate(scan.split("\n"), 1):
            if not rx.search(line):
                continue
            if ismd:
                cls = u"历史注释（可留）: .md 文档 (不在本加固轮的授权写集合内)"
            elif rel in targets:
                cls = u"必须同步 (现役/已同步; 本脚本 EDITS 目标)"
            else:
                cls = None
                for pat, c in ar.ALLOW:
                    if re.search(pat, rel):
                        cls = c
                        break
                cls = cls or u"**未登记 (未定)**"
            rows.append((rel, i, line.strip()[:96], fam, cls))
out = io.open(os.path.join(REPO, "_proj_10g/notes/p7b_readside_harden_20261010",
                           "FULL_TABLE.tsv"), "w", encoding="utf-8", newline="")
for r in rows:
    out.write("%s:%d\t%s\t%s\t%s\n" % r)
out.close()
print("行数 = %d / 文件数 = %d" % (len(rows), len(set(r[0] for r in rows))))
how = {}
for r in rows:
    how[r[4][:22]] = how.get(r[4][:22], 0) + 1
for k in sorted(how, key=lambda x: -how[x]):
    print("%6d  %s" % (how[k], k))
