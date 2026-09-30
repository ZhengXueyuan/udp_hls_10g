#!/bin/bash
#=============================================================================
# negctrl_fix3.sh — 「闸 4 判据收口」的**反例实测** (全部真跑 `_proj_pcie/p7b_gate4_accept.sh`)
#
# 被验对象 = fix3 改过的三条判据 + 一条新判据的**牙**:
#   · N_SELF  容差 ±2 之后, 真缺陷形态 (有一类帧记进 packets 却不进 good/bad) **必须仍被抓住**;
#   · N_XCHK  ① 守卫不再结构性恒假 (`${assoc+x}` bug) ⇒ **判据行必须出现**;
#             ② 两口径**不同刻** ⇒ 必须 SKIP (这正是本轮真验收的取数编排形态);
#             ③ 参考侧量子(≈1 s)/窗口不足 ⇒ 必须 SKIP(口径不足), 不许硬判;
#             ④ 同刻 + 窗口够长 + 偏差 23% ⇒ 必须 FAIL;
#   · T_RUN / T_TOOL 拆分之后: 凭证缺失/命令不存在 ⇒ T_RUN FAIL; 工具自己报零帧 ⇒ T_TOOL FAIL;
#     工具只是"接收侧跟不上" (本轮真实日志) ⇒ T_RUN PASS + T_TOOL SKIP (不许算板子缺陷)。
#
# 做法: 合成读数 (gen_inputs.py 生成, 形态与真读数逐字同形) 灌进脚本的**解析+判据层**;
#       I/O 层被 `G4_SNAP_TEXT/G4_NIC_TEXT/G4_TRAFFIC_TEXT` 三个离线钩子旁路 ⇒ **不碰板/不碰对端机**。
#   ⚠️ 其中 `t_run_ok` 用的是**本轮真验收的真实激励日志** (原位复跑), 不是合成体。
# 用法: bash _proj_10g/notes/p7b_gate4_criteria/negctrl_fix3.sh
# 退出码: 0 = 全部按期望 / 1 = 有 case 不符期望
#=============================================================================
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
ACCEPT=$ROOT/_proj_pcie/p7b_gate4_accept.sh
PY=/c/Users/zhxue/anaconda3/python.exe
IN=$HERE/inputs
LOGS=$HERE/logs
REAL_TRAFFIC=$ROOT/_proj_10g/notes/p7b_gate4_2/accept/traffic_cmd.txt
mkdir -p "$LOGS"

"$PY" "$HERE/gen_inputs.py" "$IN" "$REAL_TRAFFIC" > "$LOGS/gen_inputs.log" 2>&1 || {
  echo "[FATAL] 生成输入失败 (读 $LOGS/gen_inputs.log)"; exit 1; }

N_OK=0; N_BAD=0
ck(){ if [ "$2" = "$3" ]; then N_OK=$((N_OK+1)); printf "  [OK  ] %-18s %-42s %s\n" "$1" "$4" "$2"
      else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-18s %-42s got='%s' want='%s'\n" "$1" "$4" "$2" "$3"; fi; }
ckc(){ if grep -qF -- "$2" "$3"; then N_OK=$((N_OK+1)); printf "  [OK  ] %-18s %-42s 命中 '%s'\n" "$1" "$4" "$2"
       else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-18s %-42s 日志里没有 '%s' (%s)\n" "$1" "$4" "$2" "$3"; fi; }
ckn(){ if ! grep -qF -- "$2" "$3"; then N_OK=$((N_OK+1)); printf "  [OK  ] %-18s %-42s 未出现 '%s'\n" "$1" "$4" "$2"
       else N_BAD=$((N_BAD+1)); printf "  [BAD ] %-18s %-42s 不该出现 '%s' (%s)\n" "$1" "$4" "$2" "$3"; fi; }

run_case(){  # run_case <case> <期望退出码> <期望命中的判据行> <期望命中的短语>
  local name="$1" want_rc="$2" want_line="$3" want_txt="$4"
  local d=$IN/$name log=$LOGS/$name.log
  local snap="$d/snap_A.txt,$d/snap_B.txt,$d/snap_C.txt,$d/snap_D.txt"
  local nic="$d/nic_A.txt,$d/nic_B.txt,$d/nic_C.txt,$d/nic_D.txt"
  local ttxt=""; [ -f "$d/traffic.txt" ] && ttxt="$d/traffic.txt"
  env G4_SNAP_TEXT="$snap" G4_NIC_TEXT="$nic" G4_TRAFFIC_TEXT="$ttxt" \
      G4_OUTDIR="$LOGS/out_$name" bash "$ACCEPT" > "$log" 2>&1
  local rc=$?
  ck  "$name" "$rc" "$want_rc" "退出码"
  ckc "$name" "$want_line" "$log" "判据行"
  [ -z "$want_txt" ] || ckc "$name" "$want_txt" "$log" "短语"
}

echo "########## 闸 4 判据收口: 反例实测 $(date '+%F %T') ##########"
echo "— 正对照 (clean): 全部自洽 + 两口径同刻 ⇒ N_XCHK 必须**真的被评估**且 PASS —"
run_case clean 0 "[PASS] N_XCHK" "偏差"

echo "— N_SELF: 容差 ±2 的**上界**与**牙** (真验收轮的真实形态 vs 真缺陷形态) —"
run_case ns_self_plus1    0 "[PASS] N_SELF" "= 1 (端点内残差 A=0 B=1"
run_case ns_self_classgap 1 "[FAIL] N_SELF" "-21200"

echo "— N_XCHK 守卫 1 (同刻): 本轮真验收的取数编排 (NIC 窗先 / 板侧窗后, 错开 ~10 s) —"
run_case xchk_offset 0 "[SKIP] N_XCHK" "不是同一段"

echo "— N_XCHK 守卫 2 (分辨率): 同刻但 5 s 窗 ⇒ 参考侧量子/窗口 20% ⇒ 不许硬判 —"
run_case xchk_narrow 0 "[SKIP] N_XCHK" "反解不到 1%"

echo "— N_XCHK 的牙: 同刻 + 20 s 窗 + 主机侧高 30% (偏差 23%) ⇒ 必须 FAIL —"
run_case xchk_dev30 1 "[FAIL] N_XCHK" "23.0"

echo "— T_RUN / T_TOOL 拆分: 真实日志 + 三种失效形态 —"
run_case t_run_ok        0 "[PASS] T_RUN" "工具接收侧失去对齐"
ckc      t_run_ok  "[SKIP] T_TOOL" "$LOGS/t_run_ok.log" "判据行(T_TOOL)"
run_case t_tool_noframes 1 "[FAIL] T_TOOL" "零帧"
run_case t_run_127       1 "[FAIL] T_RUN"  "先怀疑激励侧"
run_case t_run_noproof   1 "[FAIL] T_RUN"  "激励没跑"

echo
echo "########## 汇总: OK=$N_OK BAD=$N_BAD ##########"
{ echo "闸 4 判据收口 反例实测 $(date '+%F %T')"
  echo "OK=$N_OK BAD=$N_BAD"
  echo "case: clean / ns_self_plus1 / ns_self_classgap / xchk_offset / xchk_narrow / xchk_dev30"
  echo "      t_run_ok / t_tool_noframes / t_run_127 / t_run_noproof"
  echo "原始件: logs/<case>.log (验收脚本 stdout) · inputs/<case>/*.txt (合成读数, t_run_ok 用真实激励日志)"
} > "$LOGS/SUMMARY.txt"
[ "$N_BAD" -eq 0 ] || exit 1
exit 0
