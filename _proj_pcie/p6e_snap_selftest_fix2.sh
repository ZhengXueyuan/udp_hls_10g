#!/bin/bash
#=============================================================================
# p6e_snap_selftest_fix2.sh — 用**假板子**证明 `freq_check` 的度量伪影修复真的生效
#                            (闸 4 工具轮 fix2 ③; 真跑, 不碰板子/对端机)
#
# 被验的缺陷 (2026-09-30 真板实测, 原始件 _proj_10g/notes/p7b_gate4/live/snap_check_halt.txt):
#   旧 `freq_check` 的顺序是 `a=rd(字) → t1=date → snap_take(触发) → b=rd(字) → t2=date`。
#   快照字**只在触发时刷新** ⇒ `a` 是**上一次触发锁存的陈旧值**, 而 t1 记在本次触发之前
#   ⇒ 分子量的是 [上一次锁存 → 本次锁存], 分母量的是 [t1 → t2] —— **两个不同的区间**。
#   后果: W5 报 **371.04 MHz**、W24 报 **293.58 MHz** (标称的 2~3 倍, 物理不可能),
#   两条 [FAIL] 是**度量伪影**; 同一个 2 倍偏差还把 W50 的 ÷1/÷2 口径误判成 "÷2 命中"。
#
# 假板子的关键 (与上一轮 selftest 的假板子**不同**): 这里的字是**真锁存语义** ——
#   字值 = f(最后一次触发的时刻), **不是**"读的时候现算"。这正是真板的行为, 也是伪影的
#   必要条件; 上一轮的假板子每次读都现算 ⇒ 它结构性看不见这个缺陷。
#
# 四条 case (全部真跑):
#   ① good       新版 + 正常假板      ⇒ 0 FAIL, W5/W24 = 156.25 MHz, W50 **÷1** 命中
#   ② genstuck   新版 + gen 不增       ⇒ 必须**拒绝出频率**, 打印"gen 不是恰好 +1 / 取不到自证新一代"
#   ③ stale      新版 + 字被冻结(陈旧)  ⇒ 必须报"计数被钉死"(Δ=0) 的 FAIL, **不打印假频率**
#   ④ good_old   **旧版**(留档件) + 同一块正常假板 ⇒ 对照: 旧版没有自证 ⇒ 记下它读到什么
#
# 用法: bash _proj_pcie/p6e_snap_selftest_fix2.sh
# 产物: _proj_10g/notes/p7b_gate4_tools/fix2/{selftest_*.log, addrlog_*.txt, SUMMARY.txt}
# 退出码: 0 = 全部按期望 / 1 = 有不符
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NEW=$ROOT/_proj_pcie/p6e_snap_check.sh
OLD=$ROOT/_proj_10g/notes/p7b_gate4_tools/fix2/old/p6e_snap_check.sh.pre_fix2
W=$ROOT/_proj_10g/notes/p7b_gate4_tools/fix2
BIN=$W/bin
[ -f "$OLD" ] || { echo "[FATAL] 找不到留档的旧版 $OLD"; exit 1; }
mkdir -p "$BIN" "$W/sys/bus/pci/devices/0000:02:00.0"
echo "5.0 GT/s PCIe" > "$W/sys/bus/pci/devices/0000:02:00.0/current_link_speed"
touch "$W/xdma0_user"

N_OK=0; N_BAD=0
ck(){ if [ "$2" = "$3" ]; then N_OK=$((N_OK+1)); printf "  [OK  ] %-46s %s\n" "$1" "$2"
      else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-46s got='%s' want='%s'\n" "$1" "$2" "$3"; fi; }
ckc(){ if grep -qF -- "$2" "$3"; then N_OK=$((N_OK+1)); printf "  [OK  ] %-46s 命中 '%s'\n" "$1" "$2"
       else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-46s 日志里没有 '%s' (%s)\n" "$1" "$2" "$3"; fi; }
ckn(){ if ! grep -qF -- "$2" "$3"; then N_OK=$((N_OK+1)); printf "  [OK  ] %-46s 未出现 '%s'\n" "$1" "$2"
       else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-46s 不该出现 '%s' (%s)\n" "$1" "$2" "$3"; fi; }

# ---------- 假工具: reg_rw 是**真锁存语义** --------------------------------------
# 状态放文件里: LATCH (最后一次触发的时刻, 秒), GEN (代计数)
#   FAKE_GEN_STUCK=1 ⇒ 触发不增 gen (但字仍刷新) → 新版必须拒绝出频率
#   FAKE_STALE=1     ⇒ 触发不刷新字 (陈旧值)      → 新版必须报"计数被钉死", 不打印假频率
cat > "$BIN/reg_rw" <<EOS
#!/bin/bash
# 假 reg_rw: \$1=dev \$2=addr [w [data]]; 输出形态与真 reg_rw 逐字一致
DEV="\$1"; A=\$(echo "\$2" | tr '[:lower:]' '[:upper:]'); OP="\${3:-}"; DAT="\${4:-}"
NOW=\$(cat "$W/vclk")          # 与假 date 同一时间基 (虚拟钟)
echo "\$A" >> "\${FAKE_ADDRLOG:-/dev/null}"
if [ "\$OP" = "w" ] && [ -n "\$DAT" ]; then
  if [ "\$A" = "0X18" ]; then
    [ "\${FAKE_GEN_STUCK:-0}" = "1" ] || echo \$(( \$(cat "$W/gen") + 1 )) > "$W/gen"
    [ "\${FAKE_STALE:-0}" = "1" ] || echo "\$NOW" > "$W/latch"
  fi
  echo "Write 32-bit \$DAT to address \$A"; exit 0
fi
LT=\$(cat "$W/latch")
freecnt(){ awk -v t="\$1" -v f="\$2" 'BEGIN{ n=int((t-1700000000)*f)%4294967296; if(n<0) n+=4294967296; printf "0x%08x", n }'; }
case "\$A" in
  0X00) V=0x50360001;;
  0X04) V=0x00000007;;
  0X08) V=0x00000000;;
  0X0C) V=\$(freecnt "\$LT" 250000000);;
  0X10) V=0x00000018;;
  0X14) V=0xdeadbeef;;
  0X18) V=0x00000000;;
  0X1C) V=\$(awk -v g="\$(cat "$W/gen")" 'BEGIN{printf "0x%08x", g*65536+2}');;
  0X20) V=0x00000045;; 0X24) V=0x00002bb4;; 0X28) V=0x0000014d;; 0X30) V=0x00000000;;
  0X34) V=\$(freecnt "\$LT" 156250000);;                       # W5  前端域 (P7B = PCS 恢复钟 156.25)
  0X80) V=\$(freecnt "\$LT" 156250000);;                       # W24 数据面域 156.25
  0X3C) V=0x00000000;; 0X40) V=0x00000000;; 0X44) V=0x00000000;;
  0X9C) V=0x00000000;; 0XA0) V=0x00000000;; 0XA4) V=0x00000000;; 0XA8) V=0x00000000;;
  0XBC) V=0x2000100c;; 0XC0) V=0x000000ff;;
  0XE8) V=\$(freecnt "\$LT" 156250000);;                       # W50 toggle (÷1 口径 ⇒ 156.25)
  0XEC) V=0xffffffff;;
  *)    V=0x00000000;;
esac
echo "Read 32-bit from address \$A : \$V"
EOS
cat > "$BIN/lspci" <<'EOS'
#!/bin/bash
echo "02:00.0 Serial controller [0700]: Xilinx Corporation Device [10ee:9034]"
EOS
cat > "$BIN/lsmod" <<'EOS'
#!/bin/bash
echo "xdma 123456 0 - Live 0x0000000000000000"
EOS
cat > "$BIN/insmod" <<'EOS'
#!/bin/bash
exit 0
EOS
# 假 date: **虚拟钟** —— 每被调用一次前进 2.000000 s (放在文件里)。
#   ⚠️ 为什么不用真实墙钟: 本假板子跑在 Windows/MSYS 上, 每次 fork+exec 要 50~150 ms
#      (真板是 Linux, ~2~5 ms) ⇒ 真实墙钟会把**台架自己的进程启动延迟**灌进频差里
#      (实测 ±3%, 与设计无关)。虚拟钟让"锁存→时间戳"的延迟在两点上**逐字相同** ⇒ 差分里
#      自动对消, 确定性可复算。真板上的精度证据见 P7B_GATE4_ACCEPT.md §3.3 (−0.033%)。
cat > "$BIN/date" <<EOS
#!/bin/bash
case "\$1" in
  +%s.%N) t=\$(cat "$W/vclk"); printf '%s\n' "\$t.000000"; awk -v t="\$t" 'BEGIN{printf "%.6f", t+0.001}' > "$W/vclk";;
  *)      echo "2026-09-30 00:00:00";;
esac
EOS
# 假 sleep: 虚拟钟按"实际睡眠时长"前进 (**不再真睡** ⇒ 台架快)。这样虚拟钟仍然模拟
#   "墙钟在两次触发之间流逝"这件事 —— 这正是旧 freq_check 伪影的成因, 也是它被重现的关键。
cat > "$BIN/sleep" <<EOS
#!/bin/bash
t=\$(cat "$W/vclk")
awk -v t="\$t" -v d="\${1:-0}" 'BEGIN{printf "%.6f", t+d}' > "$W/vclk"
exit 0
EOS
chmod +x "$BIN"/*

# 把脚本里的四个路径换成假路径 (脚本本体一字不改)
mkfake(){  # mkfake <源脚本> <目标>
  sed -e "s#^TOOLS=.*#TOOLS=$BIN#" -e "s#^DEV=.*#DEV=$W/xdma0_user#" \
      -e "s#^LOG=.*#LOG=$W/fake_run_$(basename "$2" .sh).log#" \
      -e "s#/sys/bus/pci#$W/sys/bus/pci#" "$1" > "$2"
  grep -q "TOOLS=$BIN" "$2" || { echo "[FATAL] 路径替换失败"; exit 1; }
}
mkfake "$NEW" "$W/new_fake.sh"
mkfake "$OLD" "$W/old_fake.sh"

runcase(){  # runcase <名字> <脚本> [额外 env...]
  local name="$1" script="$2"; shift 2
  echo "5" > "$W/gen"; echo "1000000" > "$W/vclk"; echo "1000000" > "$W/latch"
  env "$@" FAKE_ADDRLOG="$W/addrlog_$name.txt" PATH="$BIN:$PATH" \
      SNAP_FREQ_GAP=4 \
      bash "$script" > "$W/selftest_$name.log" 2>&1
  echo "$?" > "$W/rc_$name.txt"
}

echo "########## fix2 ③ 自证 (假板子, 真锁存语义) $(date '+%F %T') ##########"
echo "— ① good: 新版 + 正常假板 (正对照: 必须 0 FAIL, 且频率读回标称) —"
runcase good "$W/new_fake.sh"
ckc "① good: 整脚本 0 FAIL"            "FAIL=0"                "$W/selftest_good.log"
ckc "① good: W5 PASS (名义 156.25)"      "[PASS] 前端域 gmii_free" "$W/selftest_good.log"
ckc "① good: W24 PASS (名义 156.25)"     "[PASS] 数据面域 dp_free" "$W/selftest_good.log"
ckc "① good: W50 命中 **÷1** 口径"      "÷1 口径命中"            "$W/selftest_good.log"
ckc "① good: 每点都自证新一代"          "都是自证的新一代"        "$W/selftest_good.log"
ck  "① good: 退出码 0"                 "$(cat "$W/rc_good.txt")" "0"

echo "— ② genstuck: 触发不增 gen (该被抓住: 读数不可归因 ⇒ 拒绝出频率) —"
runcase genstuck "$W/new_fake.sh" FAKE_GEN_STUCK=1
ckc "② genstuck: 命中 gen 自证失败"     "gen 不是恰好 +1"        "$W/selftest_genstuck.log"
ckc "② genstuck: 拒绝出频率"            "取不到 **自证新一代** 的一对读数" "$W/selftest_genstuck.log"
ckn "② genstuck: 不得打印任何分辨率频率" "MHz (标称"             "$W/selftest_genstuck.log"
ck  "② genstuck: 退出码非 0"           "$([ "$(cat "$W/rc_genstuck.txt")" -ne 0 ] && echo OK)" "OK"

echo "— ②b 对照: **旧版**在同一块假板上 (没有自证 ⇒ 它照样报一个频率出来) —"
runcase genstuck_old "$W/old_fake.sh" FAKE_GEN_STUCK=1
ckc "②b 旧版确实报出了频率 (所以它抓不到这个故障)" "MHz (标称" "$W/selftest_genstuck_old.log"
ckn "②b 旧版日志里没有 gen 自证 (对照点)" "SNAP_STATUS.gen 不是恰好 +1" "$W/selftest_genstuck_old.log"

echo "— ③ stale: 字被冻结 (合成一个陈旧值 ⇒ 必须报错, 不得报一个假频率) —"
runcase stale "$W/new_fake.sh" FAKE_STALE=1
ckc "③ stale: 报'计数被钉死'类 FAIL"    "0.0000 MHz, 偏离标称"    "$W/selftest_stale.log"
ckn "③ stale: 不得出现 [PASS] 前端域 (无假频率)" "[PASS] 前端域"  "$W/selftest_stale.log"
ck  "③ stale: 退出码非 0"              "$([ "$(cat "$W/rc_stale.txt")" -ne 0 ] && echo OK)" "OK"

echo "— ④ 对照: **旧版**在同一块正常假板上 (必须重现出那个伪影: 报一个 ≈2× 的假频率) —"
runcase good_old "$W/old_fake.sh"
ckc "④ 旧版: 4.3 段确实跑出了读数 (供对照)" "4.3"                "$W/selftest_good_old.log"
ckc "④ 旧版报出 ≈2× 标称的**假频率** (伪影重现)" "⇒ 312.5"        "$W/selftest_good_old.log"
ckc "④ 旧版把 W50 误判成 ÷2 (真值 ÷1)" "÷2 口径命中"            "$W/selftest_good_old.log"
ckc "④ 旧版把它判成 FAIL (伪 FAIL)"        "[FAIL] 前端域"          "$W/selftest_good_old.log"

echo
echo "########## fix2 ③ 自证汇总: OK=$N_OK BAD=$N_BAD ##########"
{ echo "p6e_snap_check.sh fix2 ③ 自证 (假板子, 真锁存语义, 不碰真板) $(date '+%F %T')"
  echo "OK=$N_OK BAD=$N_BAD"
  echo "case: good / genstuck / genstuck_old / stale / good_old  (日志 selftest_*.log, 退出码 rc_*.txt)"
} > "$W/SUMMARY.txt"
[ "$N_BAD" -eq 0 ] || exit 1
exit 0
