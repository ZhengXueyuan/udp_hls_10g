#!/bin/bash
#=============================================================================
# j6_double_run.sh -- 用**本地替身**跑改过的 j6 台架 (tcpreg_j6.sh / j6_fix.sh),
#   证明三件事 (真板跑不了: 本机没有 PEER_PW ⇒ 不能 sudo ⇒ 读不了 /dev/xdma0_user):
#     ① 默认档 (BID 9) 下 t0/t1 的**字表里真的有 61 62** (替身把 argv 逐字记下来)
#     ② 板侧 BID 与声明几何不符 ⇒ **当场红** (exit 3), 不再"记录错几何且不报错"
#     ③ 显式 legacy 档 (NW=61 / BID 8) 下字表退回 5 53 54 且打 J6_GEOM_LEGACY
#   替身只替"板 + 对端机"两件事, 被验的编排逻辑是真的 (脚本本体一字未改地跑)。
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
W=$ROOT/_proj_10g/notes/p7b_wu_harness_fix
OUT=$W/logs/j6double
rm -rf /tmp/p7b_biz "$W/faketools" "$W/fakebin"; mkdir -p /tmp/p7b_biz "$W/faketools" "$W/fakebin" "$OUT"

# ---- 替身 1: /tmp/p7b_biz/p7b_snap.sh (记 argv; id 的 rc 可注入) ---------------
cat > /tmp/p7b_biz/p7b_snap.sh <<EOS
#!/bin/bash
echo "STUB_SNAP_CALL|NW=\${NW:-<unset>}|\$*" >> "$OUT/calls.txt"
case "\${1:-}" in
  id)  echo "ID_MAGIC 0x50360001"; echo "ID_BID   \${STUB_BID:-0x00000009}"; echo "ID_OK"
       exit "\${STUB_ID_RC:-0}";;
  snap|full) echo "SNAP_BEGIN \${2:-TAG} gen=1"
       # 把点名的字逐字打出来 (含它到底被点名了没有)
       shift; shift
       for w in "\$@"; do echo "W\$w (stub)"; done
       echo "SNAP_END nff=0"; exit 0;;
esac
EOS
chmod +x /tmp/p7b_biz/p7b_snap.sh
printf '#!/bin/bash\necho "SRC_STUB \$*"; exit 0\n' > /tmp/p7b_biz/p7b_tcp_src
chmod +x /tmp/p7b_biz/p7b_tcp_src

# ---- 替身 2: tools/reg_rw (只回 0x04 = BID, 其余 0) --------------------------
cat > "$W/faketools/reg_rw" <<EOS
#!/bin/bash
A=\$(echo "\$2" | tr '[:lower:]' '[:upper:]')
if [ "\${3:-}" = "w" ] && [ -n "\${4:-}" ]; then echo "Write 32-bit \${4} to address \$A"; exit 0; fi
case "\$A" in
  0X04) V=\${STUB_BID:-0x00000009};;
  *)    V=0x00000000;;
esac
echo "Read 32-bit from address \$A : \$V"
EOS
chmod +x "$W/faketools/reg_rw"

# ---- 替身 3: tcpdump / ss (前者长睡, 保证 kill 打的是自己的后台进程) ---------
printf '#!/bin/bash\nsleep 30\n' > "$W/fakebin/tcpdump"
printf '#!/bin/bash\nexit 0\n'        > "$W/fakebin/ss"
chmod +x "$W/fakebin/tcpdump" "$W/fakebin/ss"

N_OK=0; N_BAD=0
ck(){ if [ "$2" = "$3" ]; then N_OK=$((N_OK+1)); printf "  [OK  ] %-44s %s\n" "$1" "$2"
      else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-44s got='%s' want='%s'\n" "$1" "$2" "$3"; fi; }
ckc(){ if grep -qF -- "$2" "$3"; then N_OK=$((N_OK+1)); printf "  [OK  ] %-44s 命中 '%s'\n" "$1" "$2"
       else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-44s 日志里没有 '%s'\n" "$1" "$2"; fi; }
ckn(){ if ! grep -qF -- "$2" "$3"; then N_OK=$((N_OK+1)); printf "  [OK  ] %-44s 未出现 '%s'\n" "$1" "$2"
       else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-44s 不该出现 '%s'\n" "$1" "$2"; fi; }

run(){  # run <脚本> <tag> [env...]
  local script="$1" tag="$2"; shift 2
  rm -f "$OUT/calls.txt"
  env "$@" P7B_TOOLS="$W/faketools" PATH="$W/fakebin:$PATH" \
      bash "$script" 1 "/tmp/j6double_$tag.pcap" "$tag" > "$OUT/$tag.log" 2>&1
  echo "$?" > "$OUT/$tag.rc"
}

echo "########## 替身跑: tcpreg_j6.sh (改后) ##########"
J6=$ROOT/_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh
run "$J6" default STUB_BID=0x00000009
ck  "A1 默认档 (BID 9) 退出码 0"          "$(cat "$OUT/default.rc")" "0"
ckc "A2 几何门通过"                        "J6_GEOM_OK NW=63 BID=0x00000009" "$OUT/default.log"
ckc "A3 t0/t1 字表**含 61 62**"           "SNAP_BEGIN default_t0"           "$OUT/default.log"
ck  "A4 替身收到的 t0 字表 (+NW 真的传过去了)" "$(grep -m1 'default_t0' "$OUT/calls.txt")" "STUB_SNAP_CALL|NW=63|snap default_t0 5 53 54 61 62"
ck  "A5 替身收到的 t1 字表"               "$(grep -m1 'default_t1' "$OUT/calls.txt")" "STUB_SNAP_CALL|NW=63|snap default_t1 5 53 54 61 62"
ckc "A6 full 两点仍在 (pre/post 全窗)"     "full default_pre"                "$OUT/calls.txt"
ckc "A6b full post 仍在"                   "full default_post"               "$OUT/calls.txt"
ckc "A7 元数据行带几何"                    "J6META_NW=63 J6META_EXPECT_BID=0x00000009" "$OUT/default.log"
ckc "A8 跑到底"                            "TCPREG_J6_DONE"                  "$OUT/default.log"

echo "########## 替身跑: 反例 —— 板上是 BID 8 (旧位流) 而台架按 63 字跑 ##########"
run "$J6" bid8 STUB_BID=0x00000008
ck  "B1 退出码 3 (拒绝)"                   "$(cat "$OUT/bid8.rc")" "3"
ckc "B2 报 J6_GEOM_FAIL"                   "J6_GEOM_FAIL 板侧 BID=0x00000008" "$OUT/bid8.log"
ckn "B3 不再往下跑 (没有 pre_snapshot)"    "PHASE pre_snapshot"              "$OUT/bid8.log"

echo "########## 替身跑: 显式 legacy 档 (NW=61 / BID 8) ##########"
run "$J6" legacy STUB_BID=0x00000008 J6_LEGACY_GEOM=1 NW=61 EXPECT_BID=0x00000008
ck  "C1 退出码 0"                          "$(cat "$OUT/legacy.rc")" "0"
ckc "C2 打 J6_GEOM_LEGACY 醒目行"          "J6_GEOM_LEGACY"                   "$OUT/legacy.log"
ck  "C3 字表**退回 5 53 54** (无 61 62)"   "$(grep -m1 'legacy_t0' "$OUT/calls.txt")" "STUB_SNAP_CALL|NW=61|snap legacy_t0 5 53 54"
ck  "C4 export 生效: 替身看到 NW=61"       "$(grep -m1 'id' "$OUT/calls.txt")" "STUB_SNAP_CALL|NW=61|id"

echo "########## 替身跑: 反例 —— NW=61 但**没有** legacy 声明 ##########"
run "$J6" badnw NW=61
ck  "D1 退出码 3"                          "$(cat "$OUT/badnw.rc")" "3"
ckc "D2 报 J6_GEOM_FAIL (NW=61 != 63)"     "J6_GEOM_FAIL 默认档要求 NW=63"     "$OUT/badnw.log"

echo "########## 替身跑: 反例 —— 取数器身份闸不过 (id rc=1) ##########"
run "$J6" idfail STUB_BID=0x00000009 STUB_ID_RC=1
ck  "E1 退出码 3"                          "$(cat "$OUT/idfail.rc")" "3"
ckc "E2 报取数器身份闸未过"                 "J6_GEOM_FAIL 取数器身份闸未过"     "$OUT/idfail.log"

echo "########## 替身跑: **改前副本** (对照; 证明缺口真的存在) ##########"
run "$W/tcpreg_j6.sh" before_default STUB_BID=0x00000009
ck  "G1 改前: t0 字表只有 5 53 54, 且取数器收到 **NW=<unset>**" "$(grep -m1 'before_default_t0' "$OUT/calls.txt")" "STUB_SNAP_CALL|NW=<unset>|snap before_default_t0 5 53 54"
ckn "G2 改前: 没有几何门 (无 J6_GEOM_OK)"  "J6_GEOM_OK"                      "$OUT/before_default.log"
ckc "G3 改前: 却把 NW=61 写进日志 (记录错几何)" "NW=61"                       "$OUT/before_default.log"
ck  "G4 改前: BID=8 的板子照样跑到底 (静默)" "$(cat "$OUT/before_default.rc")" "0"

echo "########## 替身跑: j6_fix.sh (同款) ##########"
JF=$ROOT/_proj_10g/notes/p7b_wu_w54/j6_fix.sh
run "$JF" fix_default STUB_BID=0x00000009
ck  "F1 默认档退出码 0"                    "$(cat "$OUT/fix_default.rc")" "0"
ck  "F2 t0 字表含 61 62 (j6_fix 同款)"      "$(grep -m1 'fix_default_t0' "$OUT/calls.txt")" "STUB_SNAP_CALL|NW=63|snap fix_default_t0 5 53 54 61 62"
run "$JF" fix_bid8 STUB_BID=0x00000008
ck  "F3 BID 8 默认档 ⇒ 退出码 3"           "$(cat "$OUT/fix_bid8.rc")" "3"

echo
echo "########## j6 替身汇总: OK=$N_OK BAD=$N_BAD ##########"
[ "$N_BAD" -eq 0 ] || exit 1
exit 0
