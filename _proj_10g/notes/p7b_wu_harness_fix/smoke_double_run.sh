#!/bin/bash
#=============================================================================
# smoke_double_run.sh -- 用**本地替身**证明 p6b_smoke_gate.sh 的哑门已修:
#     修前: 打 [FAIL] A1b BUILD_ID + [FATAL] 拒绝继续, 末行却 `冒烟门: PASS`, **rc=0**
#     修后: 同一场景 ⇒ 末行 `冒烟门: FAIL`, **rc=7**
#   替身 = 假 reg_rw (逐字节模仿真板的 BID 8 / 0xb0 已实现 / 0x80 自由计数) + 假 lspci/lsmod,
#   脚本本体只有四个路径被 sed 换掉 (KO/TOOLS/DEV/LOG), **判据逻辑一字未改**。
#   ⚠️ 只在**只读**意义上模拟板子 (0x18=1 触发快照 = 任务明许); 不写 0x08/不烧板。
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
W=$ROOT/_proj_10g/notes/p7b_wu_harness_fix
S=$W/logs/smoke
rm -rf "$S"; mkdir -p "$S/bin"
touch "$S/fake_dev"

# ---- 假 reg_rw: 形态与真件逐字同; 状态 (gen/latch) 放文件, 计数器用**真实墙钟** ------
cat > "$S/bin/reg_rw" <<EOS
#!/bin/bash
A=\$(echo "\$2" | tr '[:lower:]' '[:upper:]'); OP="\${3:-}"; DAT="\${4:-}"
if [ "\$OP" = "w" ] && [ -n "\$DAT" ]; then
  [ "\$A" = "0X18" ] && echo \$(( \$(cat "$S/gen") + 1 )) > "$S/gen"
  echo "Write 32-bit \$DAT to address \$A"; exit 0
fi
freecnt(){ awk -v t="\$(date +%s.%N)" -v f="\$1" 'BEGIN{ n=int(t*f)%4294967296; printf "0x%08x", n }'; }
case "\$A" in
  0X00) V=0x50360001;;
  0X04) V=\${FAKE_BID:-0x00000008};;                 # 现役板实测 BID = 8 (wu 修复位流)
  0X14) V=0xdeadbeef;;
  0X18) V=0x00000002;;
  0X1C) V=\$(awk -v g="\$(cat "$S/gen")" 'BEGIN{printf "0x%08x", g*65536+2}');;
  0X34) V=\$(freecnt 156250000);;                    # W5  前端域
  0X80) V=\$(freecnt 156250000);;                    # W24 数据面域 (A4 的被测字)
  0X84) V=0x00000001;;                               # W25 mmcm_locked bit0 = 1 (真板实测)
  0XB0) V=0xc7ca0efe;;                               # 现役板上 0xB0 是**已实现字** (真板实测读数)
  *)    V=0x00000000;;
esac
echo "Read 32-bit from address \$A : \$V"
EOS
printf '#!/bin/bash\necho "02:00.0 0700: 10ee:9034"\n' > "$S/bin/lspci"
printf '#!/bin/bash\necho "xdma 123456 0 - Live 0x0"\n' > "$S/bin/lsmod"
printf '#!/bin/bash\nexit 0\n'                         > "$S/bin/insmod"
chmod +x "$S/bin/"*

mkfake(){  # mkfake <源脚本> <目标>  (只换四个路径; 判据一字不改)
  sed -e "s#^KO=.*#KO=/dev/null#" -e "s#^TOOLS=.*#TOOLS=$S/bin#" \
      -e "s#^DEV=.*#DEV=$S/fake_dev#" -e "s#^LOG=.*#LOG=$S/run_$(basename "$2" .sh).log#" "$1" > "$2"
  grep -q "TOOLS=$S/bin" "$2" || { echo "[FATAL] 路径替换失败"; exit 1; }
}
mkfake "$W/p6b_smoke_gate.sh" "$S/before.sh"       # 改前 (scratch 里的原版)
mkfake "$ROOT/_proj_pcie/p6b_smoke_gate.sh" "$S/after.sh"

run(){  # run <脚本> <tag>
  echo 0 > "$S/gen"
  env PATH="$S/bin:$PATH" bash "$1" > "$S/$2.console" 2>&1
  echo "$?" > "$S/$2.rc"
}
echo "########## 替身跑: p6b_smoke_gate.sh (板子状态 = BID 8, 0xb0 已实现) ##########"
run "$S/before.sh" before
run "$S/after.sh"  after

N_OK=0; N_BAD=0
ck(){ if [ "$2" = "$3" ]; then N_OK=$((N_OK+1)); printf "  [OK  ] %-46s %s\n" "$1" "$2"
      else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-46s got='%s' want='%s'\n" "$1" "$2" "$3"; fi; }
ckc(){ if grep -qF -- "$2" "$3"; then N_OK=$((N_OK+1)); printf "  [OK  ] %-46s 命中 '%s'\n" "$1" "$2"
       else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-46s 日志里没有 '%s'\n" "$1" "$2"; fi; }

ck  "R0 修前: 复现哑门 (rc=0)"          "$(cat "$S/before.rc")" "0"
ckc "R1 修前: 末行谎报 PASS"             "冒烟门: PASS"          "$S/before.console"
ckc "R2 修前: 却已经打过 [FAIL] A1b"     "[FAIL] A1b"            "$S/before.console"
ck  "R3 修后: **真失败** (rc=7)"         "$(cat "$S/after.rc")"  "7"
ckc "R4 修后: 末行改判 FAIL (不再谎报)" "冒烟门: FAIL"          "$S/after.console"
ckn(){ if ! grep -qF -- "$2" "$3"; then N_OK=$((N_OK+1)); printf "  [OK  ] %-46s 未出现 '%s'\n" "$1" "$2"
       else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-46s 不该出现 '%s'\n" "$1" "$2"; fi; }
ckn "R5 修后: 末行不再有 PASS"           "冒烟门: PASS"          "$S/after.console"
ckc "R6 修后: 点名根因 (BID != 6)"       "BUILD_ID != 6"         "$S/after.console"
ckc "R7 修后: 仍按归因纪律读完 A3/A4"    "[RAW] A4 结论"         "$S/after.console"
echo
echo "########## 冒烟门替身汇总: OK=$N_OK BAD=$N_BAD ##########"
[ "$N_BAD" -eq 0 ] || exit 1
exit 0
