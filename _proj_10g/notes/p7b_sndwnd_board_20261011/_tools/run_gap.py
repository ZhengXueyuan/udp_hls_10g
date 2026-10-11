import sys
sys.path.insert(0, "_tools")
import importlib.util
spec = importlib.util.spec_from_file_location("aa", "_tools/arm_analyze.py")
aa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aa)
import struct
def inj_times(probe_log):
    out = []
    for line in open(probe_log, encoding="utf-8", errors="replace"):
        if line.startswith("PROBE_INJECT"):
            for kv in line.split()[1:]:
                if kv.startswith("t="): out.append(float(kv[2:]))
    return out
tag = sys.argv[1]; log = sys.argv[2]; cap = sys.argv[3]
t = inj_times(log)
aa.gap_analysis(cap, t, tag)
