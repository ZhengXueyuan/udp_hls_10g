#!/bin/bash
#=============================================================================
# p7b_gate4_selftest.sh — 用**假板子**证明 p6e_snap_check.sh 的两处修复真的生效
#
# 为什么要有它: 闸 4 之前**不许烧板**, 而"51 字读全了 / 未实现地址挪对了"这两件事
#   如果不跑一次, 就只是"我改了行代码" —— 本工程的规矩是**判据必须真跑**。
#   所以这里造一套假的世界 (假 reg_rw / 假 lspci / 假 date / 假寄存器表),
#   把 p6e_snap_check.sh **原样**跑一遍 (只替换 TOOLS/DEV/LOG/sysfs 四个路径),
#   然后断言:
#     ① section 5 的地址序列**恰好**是 0x20,0x24,...,0xE8 (51 个, 连续, 不重复) —— 缺陷①的正面证据
#     ② 一次服务里 0xE8 被读过 (旧版只到 0xAC) ③ 0xEC 被读过 (缺陷②的新地址)
#     ④ 0xEC 回 0xffffffff ⇒ 6.1 **PASS**; 改成回真数据 ⇒ 6.1 **FAIL** (负对照: 判据有牙)
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
  0X04) V=0x00000007;;
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
  0XEC) V=\${FAKE_UNIMPL:-0xffffffff};;
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

echo "— 正例: 0xEC 回 0xffffffff (期望: 6.1 PASS, 整脚本 0 FAIL) —"
FAKE_ADDRLOG=$W/addrlog_good.txt FAKE_UNIMPL=0xffffffff PATH="$BIN:$PATH" bash "$SRC" > "$W/good.log" 2>&1
rc=$?
ckn "正例 6.1 不得 FAIL" "[FAIL] 6.1" "$W/good.log"
ckc "正例 6.1 PASS"  "[PASS] 6.1" "$W/good.log"
ckc "正例 汇总 0 FAIL" "FAIL=0" "$W/good.log"
ck  "正例退出码" "$rc" "0"
ckre "正例读过末字地址 0xE8" "^0XE8$" "$W/addrlog_good.txt"
ckre "正例读过未实现地址 0xEC" "^0XEC$" "$W/addrlog_good.txt"

# 51 个地址的**连续块** (section 5 的读取序列; 顺序 + 不重不漏三者一起验)
awk '/^0X20$/{f=1} f&&/^0X/{print; n++} f&&n==51{exit}' "$W/addrlog_good.txt" > "$W/addrseq.txt"
{ for (( i = 0; i < 51; i++ )); do printf '0X%X\n' $(( 0x20 + 4*i )); done; } > "$W/addrseq_want.txt"
ck "section5 地址序列 (51 个, 0x20..0xE8 连续不重复)" "$(md5sum < "$W/addrseq.txt" | cut -c1-8)" "$(md5sum < "$W/addrseq_want.txt" | cut -c1-8)"
ck "section5 序列长度" "$(wc -l < "$W/addrseq.txt")" "51"
ckc "section5 表里印出 W50" "W50  0xE8" "$W/good.log"
ck "section5 表格行数" "$(grep -cE '^  W[0-9]+ +0x[0-9A-F]{2} ' "$W/good.log")" "51"

echo "— 负对照: 0xEC 回真数据 (期望: 6.1 FAIL, 退出码非 0) —"
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
