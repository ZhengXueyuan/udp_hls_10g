#!/bin/bash
#=============================================================================
# p7b_gate4_selftest.sh — 用**假板子**证明 p6e_snap_check.sh 的两处修复真的生效
#
# 为什么要有它: 闸 4 之前**不许烧板**, 而"窗口读全了 / 未实现地址挪对了"这两件事
#   如果不跑一次, 就只是"我改了行代码" —— 本工程的规矩是**判据必须真跑**。
#   所以这里造一套假的世界 (假 reg_rw / 假 lspci / 假 date / 假寄存器表),
#   把 p6e_snap_check.sh **原样**跑一遍 (只替换 TOOLS/DEV/LOG/sysfs 四个路径),
#   然后断言:
#     ① section 5 的地址序列**恰好**是 0x20,0x24,...,<末字> (SW 个, 连续, 不重复) —— 缺陷①的正面证据
#        ⚠️ 几何**由 `SNAP_WORDS` 派生** (默认 63 = P7B-WU 二轮; 63 ⇒ 末字 0x118 / 未实现 0x11C);
#        跑旧位流就用 `SNAP_WORDS=61 UNIMPL_ADDR=0x114 EXPECT_BID=0x00000008 bash ...` (⇒ 0x110 / 0x114)
#        或 `SNAP_WORDS=51 …` (⇒ 0xE8 / 0xEC)。
#        ⛔ 2026-10-07 Stage C BID 同步轮: 几何 (63 字 / 0x11C) 不变, **身份默认 9 → 10**;
#        读 P7B-WU 二轮位流用 `EXPECT_BID=0x00000009 FAKE_BID=0x00000009 bash ...`
#        (假板子与真板子的身份必须同代 —— 这正是本脚本断言⑤要保的性质)。
#        ⚠️ 假板子的字表也必须跟着 SW 走: 本脚本的假 `reg_rw` 里 **W61/W62 (0x114/0x118) 已按真字给值**,
#           `0x11C` 才是 `FAKE_UNIMPL` 的坑位 —— 若只改 SW 不改假字表, 正例会在 5.0 假 FAIL。
#     ② 一次服务里<末字地址>被读过 (旧版只到 0xAC) ③ <未实现地址>被读过 (缺陷②的新地址)
#     ④ <未实现地址> 回 0xffffffff ⇒ 6.1 **PASS**; 改成回真数据 ⇒ 6.1 **FAIL** (负对照: 判据有牙)
#     ⑤ 好消息况下整脚本 **0 FAIL** —— 保证断言④不是"什么都会 FAIL"的真空门
#
# 用法: bash _proj_pcie/p7b_gate4_selftest.sh
# 产物: _proj_10g/notes/p7b_gate4_tools/selftest/{*.log, addrlog_*, SUMMARY.txt}
# 退出码: 0 = 全部按期望 / 1 = 有不符
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE=$ROOT/_proj_10g/notes/p7b_gate4_tools
W=$BASE/selftest
BIN=$W/bin
rm -rf "$W"; mkdir -p "$BIN"
# ---- 窗口几何 (**单一来源**: 与 p6e_snap_check.sh 同一个数) -------------------------
#   默认 63 = P7B-WU 二轮 (`board/wrapper_p4.v` 的 `SNAP_NW_P6E`); 跑 61 字旧位流: SNAP_WORDS=61。
#   ⚠️ 上一版把 51 / 0xE8 / 0xEC **全写死在断言里** ⇒ 扩窗时"判据自己先红", 看着像
#      "扩窗弄坏了工具"而不是"判据没跟上" (同族教训见 P7B_GATE4_CRITERIA_CLOSEOUT.md)。
SW=${SNAP_WORDS:-67}
LAST_A=$(printf '0X%X' $(( 0x20 + 4*(SW-1) )))   # 末字地址  (65 ⇒ 0X120)
UNIMPL_A=$(printf '0X%X' $(( 0x20 + 4*SW )))      # 未实现地址 (65 ⇒ 0X124)
N_OK=0; N_BAD=0
ck(){ if [ "$2" = "$3" ]; then N_OK=$((N_OK+1)); printf "  [OK  ] %-28s %s\n" "$1" "$2"
      else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-28s got='%s' want='%s'\n" "$1" "$2" "$3"; fi; }
ckc(){ if grep -qF -- "$2" "$3"; then N_OK=$((N_OK+1)); printf "  [OK  ] %-28s 命中 '%s'\n" "$1" "$2"
       else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-28s 日志里没有 '%s' (见 %s)\n" "$1" "$2" "$3"; fi; }
ckn(){ if ! grep -qF -- "$2" "$3"; then N_OK=$((N_OK+1)); printf "  [OK  ] %-28s 未出现 '%s'\n" "$1" "$2"
       else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-28s 不该出现 '%s' (见 %s)\n" "$1" "$2" "$3"; fi; }
ckre(){ if grep -qE -- "$2" "$3"; then N_OK=$((N_OK+1)); printf "  [OK  ] %-28s 命中 /%s/\n" "$1" "$2"
        else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-28s 日志里没有 /%s/ (见 %s)\n" "$1" "$2" "$3"; fi; }

# ---------- 假工具 -------------------------------------------------------------
# 假的"虚拟时钟": 放在文件里, `date +%s.%N` 返回当前值并把时钟 +5s;
#   自由计数 = 频率 × 虚拟时钟 ⇒ 只要两次**计数读**之间夹着一次 date 调用,
#   Δ/Δt 就**恰等于**标称频率 (确定性, 不受进程启动抖动影响)。
VCLK=$W/vclk; echo 1000 > "$VCLK"
GENC=$W/gen; echo 7 > "$GENC"

# ⚠️ 假字表的**尾段随几何走** (W61..W65 与"未实现地址"的坑位):
#   SW ≥ 67 (2026-10-10 构建 E 起) ⇒ 0x11C/0x120/0x124/0x128 也是**窗口内的真字**,
#     `FAKE_UNIMPL` 挪到 **0x12C**;
#   SW ≥ 66 (P7B-A7 构建 D) ⇒ `FAKE_UNIMPL` 在 **0x128**;
#   SW = 65 (2026-10-10 P7B-GAP9-TX) ⇒ `FAKE_UNIMPL` 在 **0x124**;
#   SW = 63 (P7B-WU 二轮) ⇒ `FAKE_UNIMPL` 在 0x11C;
#   SW = 61 (历史口径) ⇒ 0x114 就是未实现地址 ⇒ `FAKE_UNIMPL` 必须留在那里, 否则负对照打空。
#   ⚠️ 单引号是**故意的**: 要让 `${FAKE_UNIMPL:-…}` 原样落进生成的假 reg_rw (由它运行时展开),
#      在这里展开会把负对照冻成常量 0xffffffff。
#   ⚠️⚠️ **变量内容不参与 heredoc 的转义处理** (实测): 这里**不能**写 `\${...}` —— 那个反斜杠
#      会原样落进生成的脚本, 假 reg_rw 把字面串当值打印出来 ⇒ 判据 6.1 读到空串报假 FAIL
#      (看着像"板子不对", 实际是夹具自己坏了)。直接写 `${...}` 即可。
if [ "$SW" -ge 67 ]; then
  FAKE_TAIL='  0X114) V=1234;;  # W61 app_ctrl.stat_wu (次数; 非 0 才像真板)
  0X118) V=0;;     # W62 app_ctrl.rx_occ_bytes (17 位 ⇒ 高位恒 0)
  0X11C) V=0;;     # W63 app_pattern.stat_frmwait_cyc (停滞拍数; 0 = 无停顿)
  0X120) V=0;;     # W64 app_pattern.stat_bp_cyc (背压拍数)
  0X124) V=0;;     # W65 mac_tx_10g.stat_tx_idle (S_IDLE 拍数; 0 = 空载, 建 D 新增)
  0X128) V=0;;     # W66 tcp_tx_frame.stat_winstall (窗口门停顿拍数, 建 E 新增)
  0X12C) V=${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (67 字)'
elif [ "$SW" -ge 66 ]; then
  FAKE_TAIL='  0X114) V=1234;;  # W61 app_ctrl.stat_wu (次数; 非 0 才像真板)
  0X118) V=0;;     # W62 app_ctrl.rx_occ_bytes (17 位 ⇒ 高位恒 0)
  0X11C) V=0;;     # W63 app_pattern.stat_frmwait_cyc (停滞拍数; 0 = 无停顿)
  0X120) V=0;;     # W64 app_pattern.stat_bp_cyc (背压拍数)
  0X124) V=0;;     # W65 mac_tx_10g.stat_tx_idle (S_IDLE 拍数; 0 = 空载, 建 D 新增)
  0X128) V=${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (66 字)'
elif [ "$SW" -ge 65 ]; then
  FAKE_TAIL='  0X114) V=1234;;  # W61 app_ctrl.stat_wu (次数; 非 0 才像真板)
  0X118) V=0;;     # W62 app_ctrl.rx_occ_bytes (17 位 ⇒ 高位恒 0)
  0X11C) V=0;;     # W63 app_pattern.stat_frmwait_cyc (停滞拍数; 0 = 无停顿)
  0X120) V=0;;     # W64 app_pattern.stat_bp_cyc (背压拍数)
  0X124) V=${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (65 字)'
elif [ "$SW" -ge 63 ]; then
  FAKE_TAIL='  0X114) V=1234;;  # W61 app_ctrl.stat_wu (次数; 非 0 才像真板)
  0X118) V=0;;     # W62 app_ctrl.rx_occ_bytes (17 位 ⇒ 高位恒 0)
  0X11C) V=${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (63 字)'
else
  FAKE_TAIL='  0X114) V=${FAKE_UNIMPL:-0xffffffff};;   # 未实现地址 (61 字口径)'
fi

cat > "$BIN/date" <<EOS
#!/bin/bash
case "\$1" in
  +%s.%N) t=\$(cat "$VCLK"); echo "\$t.000000"; echo \$((t+5)) > "$VCLK";;
  *)      echo "2026-09-30 00:00:00";;
esac
EOS

cat > "$BIN/reg_rw" <<EOS
#!/bin/bash
# 假 reg_rw: \$1=device \$2=addr [w [data]]; 打印形态与真 reg_rw 一致
DEV="\$1"; A=\$(echo "\$2" | tr '[:lower:]' '[:upper:]'); OP="\${3:-}"; DAT="\${4:-}"
echo "\$A" >> "\${FAKE_ADDRLOG:-/dev/null}"
if [ "\$OP" = "w" ] && [ -n "\$DAT" ]; then     # 写
  if [ "\$A" = "0X18" ]; then echo \$(( \$(cat "$GENC") + 1 )) > "$GENC"; fi
  echo "Write 32-bit 0x\$DAT to address \$A"; exit 0
fi
T=\$(cat "$VCLK")
V=0xffffffff
case "\$A" in
  0X00) V=0x50360001;;
  # ⚠️ 假板子的 BID 必须与 p6e_snap_check.sh 的 EXPECT_BID **同代** (否则正例的判据 1.2 假 FAIL,
  #    而"正例必须 0 FAIL"是本脚本的断言⑤)。现役 = **0x19** (构建 E 67 字 —— ⛔ 2026-10-10 同步轮: 原 0x18 = 构建 D 66 字 /
  #    原句 = 现役 17 (构建 C 65 字) / 10 (P7b Stage C) / 更早 9 (P7B-WU 二轮)); 跑旧口径时 FAKE_BID=0x00000017 /
  #    0x0000000A / 0x00000009 / 0x00000008 (与 SNAP_WORDS=65/63 一起用)。
  #    ⚠️ 注释里**不许出现反引号/$( )** —— 这是**无引号 heredoc**, 它们会被当场求值
  #       (实测: 反引号里的 EXPECT_BID 被当命令执行, 报 "command not found")。
  0X04) V=\${FAKE_BID:-0x00000019};;
  0X08) V=0x00000000;;
  0X0C) V=\$(awk -v t="\$T" 'BEGIN{printf "0x%08x", int(t*250000000)%4294967296}');;
  0X10) V=0x00000018;;
  0X14) V=0xdeadbeef;;
  0X18) V=0x00000000;;
  0X1C) V=\$(awk -v g="\$(cat "$GENC")" 'BEGIN{printf "0x%08x", g*65536+2}');;
  0X20) V=1000;; 0X24) V=1518000;; 0X28) V=1518;; 0X2C) V=0;; 0X30) V=0;;
  0X34) V=\$(awk -v t="\$T" 'BEGIN{printf "0x%08x", int(t*125000000)%4294967296}');;
  0X38) V=998;; 0X3C) V=998;; 0X40) V=0;; 0X44) V=0;; 0X48) V=0;; 0X4C) V=0;;
  0X50) V=0;; 0X54) V=0;; 0X58) V=0;; 0X5C) V=0;; 0X60) V=0;; 0X64) V=0;;
  0X68) V=0;; 0X6C) V=0;; 0X70) V=998;; 0X74) V=0;; 0X78) V=0;; 0X7C) V=0;;
  0X80) V=\$(awk -v t="\$T" 'BEGIN{printf "0x%08x", int(t*156250000)%4294967296}');;
  0X84) V=1;; 0X88) V=0;; 0X8C) V=0;; 0X90) V=0;; 0X94) V=0;; 0X98) V=1000;;
  0X9C) V=1514000;; 0XA0) V=0;; 0XA4) V=0;; 0XA8) V=0;; 0XAC) V=0;;
  0XB0) V=20000000;; 0XB4) V=151800000;; 0XB8) V=0;; 0XBC) V=0x2000100c;;
  0XC0) V=0x00000099;; 0XC4) V=0;; 0XC8) V=0;; 0XCC) V=0;; 0XD0) V=0;;
  0XD4) V=0;; 0XD8) V=0;; 0XDC) V=0;; 0XE0) V=0;; 0XE4) V=0;;
  0XE8) V=\$(awk -v t="\$T" 'BEGIN{printf "0x%08x", int(t*312500000)%4294967296}');;
  # ---- P7B-BIZ: W51..W60 (0xEC..0x110) ---------------------------------------
  #   ⚠️ 窗口 57/59 字时代的旧注释里的 0x100/0x104 已作废 (现役 = 63 字 / 0x11C)
  #   ⚠️ 旧版把 0XEC 当"未实现地址" ⇒ 扩窗后它变成**窗口内的 W51** ⇒ 必须回真值,
  #      否则 5.0 "窗口内无 0xffffffff" 会假 FAIL (而负对照再也打不中未实现地址)。
  0XEC) V=1000;;   # W51 app_tx_bytes
  0XF0) V=10;;     # W52 app_tx_frames
  0XF4) V=900;;    # W53 app_rx_bytes
  0XF8) V=0;;      # W54 app_mismatch (必须 0)
  0XFC) V=0;;      # W55 tx_stat_retx (必须 0)
  0X100) V=0;;     # W56 app_udp_pattern.stat_tx_ovf (必须 0)
  0X104) V=0;;                                        # W57 tcp_tx_frame.o_retx_hi
  0X108) V=0;;                                        # W58 tcp_tx_frame.o_retx_active
  0X10C) V=0;;                                        # W59 slow_tx_adp.stat_fifo_ovf
  0X110) V=0;;                                        # W60 slow_rx_adp.stat_fifo_ovf
  # ---- P7B-WU 二轮: W61/W62 与新的未实现地址 (尾段随 SW 走, 见上面的 FAKE_TAIL) ----
  #   ⚠️ 与 W51 同一手法: 0x114 在 61 字时代是"未实现", 现在它**是窗口内的 W61** ⇒ 必须回真值,
  #      否则正例的 5.0 假 FAIL + 负对照打不中真正的未实现地址 (判据成了真空门)。
${FAKE_TAIL}
  *)    V=0xffffffff;;
esac
echo "Read 32-bit from address \$A : \$V"
EOS

cat > "$BIN/lspci" <<'EOS'
#!/bin/bash
echo "02:00.0 Processing accelerators: Xilinx Corporation Device 9034 [10ee:9034]"
EOS
cat > "$BIN/lsmod" <<'EOS'
#!/bin/bash
echo "xdma 123456 0 - Live 0x0000000000000000"
EOS
cat > "$BIN/insmod" <<'EOS'
#!/bin/bash
exit 0
EOS
chmod +x "$BIN"/*

# ---------- 造"假 sysfs" 与假设备节点, 并生成改过路径的脚本副本 -----------------
SYS=$W/sys/bus/pci/devices/0000:02:00.0; mkdir -p "$SYS"
echo "5.0 GT/s PCIe" > "$SYS/current_link_speed"
touch "$W/xdma0_user"
SRC=$W/p6e_snap_check_fake.sh
sed -e "s#^TOOLS=.*#TOOLS=$BIN#" \
    -e "s#^DEV=.*#DEV=$W/xdma0_user#" \
    -e "s#^LOG=.*#LOG=$W/fake_run.log#" \
    -e "s#/sys/bus/pci#$W/sys/bus/pci#" \
    "$ROOT/_proj_pcie/p6e_snap_check.sh" > "$SRC"
grep -q "TOOLS=$BIN" "$SRC" && grep -q "DEV=$W/xdma0_user" "$SRC" || { echo "[FATAL] 路径替换失败"; exit 1; }

echo "########## p6e_snap_check.sh 修复自证 (假板子) $(date '+%F %T') ##########"
echo "— 缺陷①的静态证据: 旧的**手抄 44 项地址表**必须已从源码消失 —"
if grep -q "a0 a4 a8 ac 80 84 88 8c 90 94 98 9c" "$ROOT/_proj_pcie/p6e_snap_check.sh"; then
  ck "旧手抄地址表已消失" "还在" "已消失"
else ck "旧手抄地址表已消失" "已消失" "已消失"; fi
ckc "源码里已按 SNAP_WORDS 派生" 'snap_addr(){' "$ROOT/_proj_pcie/p6e_snap_check.sh"

echo "— 正例: $UNIMPL_A 回 0xffffffff (期望: 6.1 PASS, 整脚本 0 FAIL) —"
FAKE_ADDRLOG=$W/addrlog_good.txt FAKE_UNIMPL=0xffffffff PATH="$BIN:$PATH" bash "$SRC" > "$W/good.log" 2>&1
rc=$?
ckn "正例 6.1 不得 FAIL" "[FAIL] 6.1" "$W/good.log"
ckc "正例 6.1 PASS"  "[PASS] 6.1" "$W/good.log"
ckc "正例 汇总 0 FAIL" "FAIL=0" "$W/good.log"
ck  "正例退出码" "$rc" "0"
ckre "正例读过末字地址 $LAST_A" "^$LAST_A$" "$W/addrlog_good.txt"
ckre "正例读过未实现地址 $UNIMPL_A" "^$UNIMPL_A$" "$W/addrlog_good.txt"

# SW 个地址的**连续块** (section 5 的读取序列; 顺序 + 不重不漏三者一起验)
awk "/^0X20\$/{f=1} f&&/^0X/{print; n++} f&&n==$SW{exit}" "$W/addrlog_good.txt" > "$W/addrseq.txt"
{ for (( i = 0; i < SW; i++ )); do printf '0X%X\n' $(( 0x20 + 4*i )); done; } > "$W/addrseq_want.txt"
ck "section5 地址序列 ($SW 个, 0x20..$LAST_A 连续不重复)" "$(md5sum < "$W/addrseq.txt" | cut -c1-8)" "$(md5sum < "$W/addrseq_want.txt" | cut -c1-8)"
ck "section5 序列长度" "$(wc -l < "$W/addrseq.txt")" "$SW"
# ⚠️ 表里印的是**小写** `0x100`; `$LAST_A` 是**大写** (`0X100`, 用于 addrlog) ⇒ 两者不能互用
ckc "section5 表里印出 W$((SW-1))" "W$((SW-1))  $(printf '0x%X' $(( 0x20 + 4*(SW-1) )))" "$W/good.log"
# ⚠️ 正则要容忍 **2 或 3 位**地址: 窗口跨过 0xFF 以后, W56 的地址是 `0x100`
#    (旧版写死 `{2}` ⇒ 末字行数不入表, 行数少 1 —— 被本轮假板子自证当场抓到)
ck "section5 表格行数" "$(grep -cE '^  W[0-9]+ +0x[0-9A-F]{2,3} ' "$W/good.log")" "$SW"

echo "— 负对照: $UNIMPL_A 回真数据 (期望: 6.1 FAIL, 退出码非 0) —"
FAKE_ADDRLOG=$W/addrlog_wide.txt FAKE_UNIMPL=0x12345678 PATH="$BIN:$PATH" bash "$SRC" > "$W/wide.log" 2>&1
rc2=$?
ckc "负对照 6.1 FAIL" "[FAIL] 6.1" "$W/wide.log"
ck  "负对照退出码非 0" "$([ "$rc2" -ne 0 ] && echo OK)" "OK"

echo
echo "########## 自证汇总: OK=$N_OK BAD=$N_BAD ##########"
{ echo "p6e_snap_check.sh 修复自证 (假板子, 不碰真板) $(date '+%F %T')"
  echo "OK=$N_OK BAD=$N_BAD"; echo "正例: good.log / 负对照: wide.log / 地址日志: addrlog_*.txt"
} > "$W/SUMMARY.txt"
[ "$N_BAD" -eq 0 ] || exit 1
exit 0
