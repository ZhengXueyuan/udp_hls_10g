#!/usr/bin/env python3
# snap_series.py -- 把 persist_run.sh 的 snap.log 展开成"每点一行"的字表 (板侧计数随时间的轨迹)
#   字表见 P7B_BIZ_WINDOW.md §1 (70 字); 本脚本只挑与 persist 轮相关的字。
#   用法: python3 snap_series.py <snap.log> [w1 w2 ...]
#   输出: # 头一行是列名; 每点一行 "t=<wall> W20=.. W43=.. ..."
import sys

DEFAULT = [5, 20, 43, 51, 55, 57, 58, 66, 67, 69]
# W5=滴答 W20=mac_tx_frames W43=tx_words W51=app_tx_bytes W55=stat_retx
# W57=o_retx_hi W58=o_retx_active W66=stat_winstall W67=stat_winstall_cap W69=win_at_winstall


def main():
    path = sys.argv[1]
    words = [int(x) for x in sys.argv[2:]] or DEFAULT
    t = None
    cur = {}
    n = 0
    rows = []
    for line in open(path, "r", errors="replace"):
        line = line.rstrip("\n")
        if line.startswith("SNAP_T "):
            t = line.split()[1]
        elif line.startswith("SNAP_BEGIN"):
            cur = {}
        elif line.startswith("W") and "\t" not in line:
            p = line.split()
            if len(p) >= 4 and p[0][1:].isdigit():
                cur[int(p[0][1:])] = p[3]
        elif line.startswith("SNAP_END"):
            n += 1
            row = [t] + [cur.get(w, "-") for w in words]
            rows.append(row)
    print("# point t_wall " + " ".join("W%d" % w for w in words))
    for i, r in enumerate(rows):
        print("%4d %s %s" % (i, r[0], " ".join(r[1:])))


if __name__ == "__main__":
    main()
