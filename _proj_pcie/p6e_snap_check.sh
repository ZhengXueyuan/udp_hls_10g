#!/bin/bash
#=============================================================================
# p6e_snap_check.sh — PCIe 寄存器窗口验收: 数据面计数经快照读出
#   前置: (1) FPGA 已烧上**本轮的**位流, 且 BUILD_ID == EXPECT_BID:
#              6 = P6b+F4 双域 **36 字** (历史)   |   7 = **P7b 51 字** (RATE 位流, 历史)
#              8 = P7B-BIZ **61 字** (历史)      |   9 = P7B-WU 二轮 63 字 (历史, Build 2)
#              **10 = P7b Stage C 63 字 (历史)** —— ⛔ 2026-10-07 Stage C BID 同步轮:
#              窗口仍 63 字 (0x20..0x118 / 未实现 0x11C), 只有身份 9 → 10;
#              ⛔ 2026-10-10 订正 (构建 D 门同步轮): **RTL 当前值 = 0x18 (66 字 / 未实现 0x128)**
#              (原句 "= 17 (65 字 / 0x124)" = 构建 C 那一代; 判据语义零改动)
#                 —— 本行原写 "10 = ... (RTL 当前值)" 已过时 (原句保留)。
#              读 P7B-WU 二轮 (Build 2) 位流覆盖 EXPECT_BID=0x00000009 (几何不用动)。
#              ⚠️ 读**旧位流**必须显式覆盖: `SNAP_WORDS=61 EXPECT_BID=0x00000008 UNIMPL_ADDR=0x114`
#                 (否则**响亮失败**: 身份闸 1.2 红 + 5.0 窗口内出现 2 个 0xffffffff)。
#         (2) **主机已在烧录之后重启过** (PCIe 端点只认"配置先于 POST"; 见 _pcie/README.md);
#         (3) 驱动已 insmod (本脚本自己 insmod)。
#   用法: sudo bash [EXPECT_BID=0x00000006 SNAP_WORDS=36] p6e_snap_check.sh
#         日志: /tmp/p6e_snap_check.log
#
#   ⚠️ 2026-09-30 (闸 4 工具轮 **fix2**) 又两处修复 (详见 _proj_10g/notes/P7B_GATE4_TOOLING_FIX2.md):
#     ④ **4.3 段的频率判据有度量伪影** (旧版把"上一次触发锁存的陈旧值"配"本次触发前的时间戳"
#        ⇒ 分子分母量的是两个不同区间 ⇒ W5 报 371.04 / W24 报 293.58 MHz 的**伪 FAIL**)。
#        现改成 **每次读数都自证是新一代**: 先发快照请求 → 等 done → 断言 gen 恰好 +1 →
#        才取时间戳并读数 (snap_take_gen / snap_pair)。⛔ 陈旧值在结构上进不来了。
#     ⑤ W5 的**标称**随构建而变: P7B_10G 构建前端域 = PCS 恢复钟 **156.25** (旧版写死 125
#        是 P6b 口径 ⇒ 即使没有伪影也会假 FAIL); 用 `W5_NOM=` 覆盖 (P6b 位流取 125)。
#
#   ⚠️ 2026-09-30 (P7b 闸 4 工具轮) 三处修复 —— 详见 _proj_10g/notes/P7B_GATE4_TOOLING.md:
#     ① `snap_words()` 旧版把 44 个地址**手抄**成一行, 只到 0xAC 且**尾部 8 项重复**
#        (0x80..0x9C 写了第二遍 —— 36 字时代的笔误) ⇒ 现在**由 SNAP_WORDS 派生**, 覆盖
#        W0..W60 (0x20..0x110), 重复项结构性不可能再出现。
#     ② "未实现地址" 0xB0 → 0xEC (51 字) → 0x114 (P7B-BIZ 61 字) → **0x11C** (P7B-WU 63 字; = 0x20 + 4*63)。
#        并且修掉旧版的一处**假 FAIL**: 判据里用的是 `$U84` 这个**从未被赋值**的
#        0x84 时代残留变量名 (现名 UB0) ⇒ 那条判据以前**永远走 FAIL 分支**。
#     ③ BUILD_ID 期望值 6 → **7** (P7b), 且**两个几何参数都可从环境覆盖** (见下 SNAP_WORDS)。
#
#   最有价值的一条 = 判据 4: **gmii 域自由计数器在两次快照之间的增量**。
#   它一次回答两个问题:
#     ① PHY 回送的 RXC 时钟到底有没有在跑 (这块板没有 UART, 别的手段问不出来);
#     ② 反解出它的实际频率 (应 ≈125MHz; 也顺带证明快照 CDC 真的在搬数)。
#   数据面"死了"还是"没时钟"这两件事, 靠这一个计数分开 —— 不算出频率就没法区分。
#=============================================================================
set -u
KO=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/xdma/xdma.ko
TOOLS=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
DEV=/dev/xdma0_user
LOG=/tmp/p6e_snap_check.log
# 位流身份 (前置闸); 1=最小 2=合体8字 3=16字 4=24字 5=P6b 双域32字 6=P6b+F4 双域36字
#   **7=P7b 51字 · 8=P7B-BIZ 61字 · 9=P7B-WU 二轮 63字 (历史) · 10=P7b Stage C 63字 (历史)
#     · 17=构建 C (2026-10-10) 65字 (现役)**
#   ⛔ 2026-10-07 Stage C: 上一行原写 "9=P7B-WU 二轮 63字 (现役)"; 现役改为 10 (窗口不变)。
#   ⛔ 2026-10-10 订正 (构建 C 门同步轮): 上面那句的 "10 = 现役" **已过时** —— 现役 = **17**
#      (源码 `board/wrapper_p4.v` 的 `BUILD_ID_V = 32'h00000017`; 同批窗口 63 → **65 字**)。
#      原句保留 (它描述的是 Stage C 那一代)。⚠️ 默认 BID 与默认 SNAP_WORDS **必须同代**,
#      否则本脚本以"身份闸 1.2 红 + 窗口内出现 0xffffffff"的形态**假红**。
#      读旧位流: Stage C 63 字 = `EXPECT_BID=0x0000000A SNAP_WORDS=63`; WU 二轮/Build 2 = `0x00000009 SNAP_WORDS=63`;
#      BIZ 61 字 = `EXPECT_BID=0x00000008 SNAP_WORDS=61 UNIMPL_ADDR=0x114`。
# ⚠️ 期望值按 **board/wrapper_p4.v 的 `.BUILD_ID_V`** 填 (源码是唯一权威); 以现场 0x04 读数为准,
#    若与源码不符 ⇒ 先查是不是烧了别人的位流, 别改这里的数去"迁就"读数。
EXPECT_BID=${EXPECT_BID:-0x00000019}       # ⛔ 2026-10-10 构建 E: 原默认 0x00000018 (构建 D 66 字) / 0x17 (构建 C) / 0x0A (Stage C)

# ---- 快照窗口几何 (**单一来源**: 只写"字数", 其他全部由它派生) -------------------------
# ⚠️ 旧版把 44 个地址**手抄**成一行 ⇒ 只到 0xAC (漏 W36..W50) **且尾部 8 项重复** (36 字时代的笔误)。
#    现在只改这一个数: 地址 = 0x20 + 4*i (i=0..SNAP_WORDS-1), 未实现地址 = 0x20 + 4*SNAP_WORDS。
#    **63 = P7B-WU 二轮** (`wrapper_p4.v` 的 `SNAP_NW_P6E = 63`; 0x20..0x118, 未实现 0x11C);
#    61 = P7B-BIZ (旧位流用 `SNAP_WORDS=61 EXPECT_BID=0x00000008 UNIMPL_ADDR=0x114` 覆盖);
#    51 = P7b (→ `0xEC`); 36 = P6b (→ `0xB0`)。
#    ⚠️ **未实现地址必须存在**: 它撑起读侧 SLVERR 负对照 (判据 6)。译码 7 位
#       (`_proj_pcie/rtl/axi_regs.v`) ⇒ 地址每 512 字节才回绕,
#       `0x11C` (word 71) 真正未实现 ✓ (上限 119 字); 红线 = **绝不能挑 ≥0x200**。
SNAP_WORDS=${SNAP_WORDS:-67}
UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*SNAP_WORDS )))}   # 67 ⇒ 0x12C (65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)
snap_addr(){ printf '0x%X' $(( 0x20 + 4*$1 )); }                          # word 号 → 字节地址
# W5 (前端域自由计数) 的**标称频率随构建而变** —— 它是判据的"期望值", 不跟上就是假 FAIL:
#   · **P7B_10G 构建** (本脚本默认几何 63 字 / EXPECT_BID=10 —— ⛔ Stage C: 原句 = 9): 前端域 = PCS 的 CDR **恢复钟**
#     (`board/wrapper_p4.v:658-659` 的 `ifdef P7B_10G` 分支 `assign gmii_clk = rx_clk_out_1`)
#     ⇒ **156.25 MHz**。板级独立两点实测 156.1986 MHz (P7B_GATE4_ACCEPT.md §3.3), 证否
#       "W5=125" 这个 P6b 时代的假设。
#   · **1G/P6b 构建** (SNAP_WORDS=36 / EXPECT_BID=6): 前端域 = PHY 回送的 RGMII RX 钟 ⇒ **125**。
#   ⇒ 默认 156.25 (与默认几何同批); 跑 P6b 位流时 `W5_NOM=125` 一并覆盖。
W5_NOM=${W5_NOM:-156.25}
# 两点之间的间隔 (秒): 太短 ⇒ 时间戳抖动占比大; 太长 ⇒ 32 位计数可能回绕 (27.49s/圈)。
SNAP_FREQ_GAP=${SNAP_FREQ_GAP:-5}
W32=$((1<<32))                     # 增量一律按模 2^32 (计数器回绕是常态, 不是故障)
PASS=0; FAIL=0; SKIP=0
exec > >(tee "$LOG") 2>&1
echo "########## P6e 合体版验收 (数据面 + 观测通道) $(date '+%F %T') ##########"
chk(){ if [ "$2" = "$3" ]; then echo "  [PASS] $1: $2"; PASS=$((PASS+1));
       else echo "  [FAIL] $1: got='$2' want='$3'"; FAIL=$((FAIL+1)); fi; }

# reg_rw 的输出形如 "Read 32-bit ... : 0x12345678" ⇒ 抠最后一个 0x........
rd(){ $TOOLS/reg_rw $DEV $1 w 2>/dev/null | tail -1 | sed 's/.*: *//' | grep -oE '^0x[0-9a-fA-F]+'; }
wr(){ $TOOLS/reg_rw $DEV $1 w $2 >/dev/null 2>&1; }

# 触发一次快照并等 done (SNAP_STATUS.bit1); done 是 sticky 的 ⇒ 不会漏看
snap_take(){
  wr 0x18 0x1
  local i s
  for i in $(seq 1 100); do
    s=$(rd 0x1c); [ -z "$s" ] && continue
    [ $(( s & 2 )) -ne 0 ] && return 0
    sleep 0.02
  done
  return 1
}
# ---- 读数自证: **每次读数都必须来自"我这一代"** (fix2 ④) --------------------------
# ⚠️ 为什么必须自证 (与 fpga_net_dev 第 27 条 "台架会安静地拿一个值和它自己比" 同族):
#    快照字**只在触发时刷新** ⇒ 旧 freq_check 的顺序
#        a=rd(字) → t1=date → snap_take(触发) → b=rd(字) → t2=date
#    里 `a` 是**上一次触发锁存的陈旧值**, 而 t1 记在本次触发之前 ⇒ 分子(计数增量)量的是
#    [上一次锁存 → 本次锁存], 分母(墙钟)量的是 [t1 → t2] —— **两个不同的区间**。
#    真板实测 (2026-09-30, live/snap_check_halt.txt): W5 报 371.04 MHz、W24 报 293.58 MHz,
#    都是标称的 2~3 倍 (物理不可能) ⇒ 两条 [FAIL] 是**度量伪影**; 同一个 2 倍偏差还把
#    W50 的 ÷1/÷2 口径误判成 "÷2 命中"。
#    ⇒ 规矩: 先发快照请求 → 等 done → **断言 gen 恰好 +1** → 才取时间戳并读数。
#      于是"这两次读的是两批数据"由 gen 自证, 而不是靠"前后对比"的解读。
GEN_ERR=""; SNAP_GEN=""
snap_take_gen(){   # 0=成功(该代由本进程触发) 1=done 不置起 2=gen 不是恰好 +1
  local g0 g1 s i
  g0=$(rd 0x1c); g0=$(( (g0 >> 16) & 0xffff ))
  wr 0x18 0x1
  s=""
  for i in $(seq 1 400); do
    s=$(rd 0x1c); [ -z "$s" ] && continue
    [ $(( s & 2 )) -ne 0 ] && break
    sleep 0.002
  done
  if [ -z "$s" ] || [ $(( s & 2 )) -eq 0 ]; then
    GEN_ERR="触发后 done 一直不置 (该域没时钟 / CDC 序列卡住)"; return 1
  fi
  g1=$(rd 0x1c); g1=$(( (g1 >> 16) & 0xffff ))
  if [ $(( (g1 - g0 + 65536) % 65536 )) -ne 1 ]; then
    GEN_ERR="SNAP_STATUS.gen 不是恰好 +1 ($g0 -> $g1) ⇒ 这一代**不是本进程触发的那一代** (并发写者 / 写没落地) ⇒ 读数不可归因"
    return 2
  fi
  SNAP_GEN=$g1; return 0
}
# 取一对**各自自证**的读数 (两点各触发一次快照, 都断言 gen+1); 结果放在 FP_* 里
snap_pair(){   # snap_pair <word号> <间隔秒>   0=成功 / 1=失败(原因在 $GEN_ERR)
  local wi="$1" gap="$2" t1 t2 h1 h2 v1 v2
  snap_take_gen || return 1
  t1=$(date +%s.%N); v1=$(rd "$(snap_addr $wi)"); t2=$(date +%s.%N)
  case "$v1" in 0x[0-9a-fA-F]*) ;; *) GEN_ERR="第1点读数 '$v1' 不是 0x 十六进制 (空读/读失败, 空读≠真0)"; return 1;; esac
  sleep "$gap"
  snap_take_gen || return 1
  h1=$(date +%s.%N); v2=$(rd "$(snap_addr $wi)"); h2=$(date +%s.%N)
  case "$v2" in 0x[0-9a-fA-F]*) ;; *) GEN_ERR="第2点读数 '$v2' 不是 0x 十六进制 (空读/读失败)"; return 1;; esac
  FP_A=$v1; FP_B=$v2; FP_GEN=$SNAP_GEN
  # 时间戳取"读数前后两次 date 的中点": 两次读走的是**同一段代码**, 系统偏差对消
  FP_TA=$(awk -v x="$t1" -v y="$t2" 'BEGIN{printf "%.6f", (x+y)/2}')
  FP_TB=$(awk -v x="$h1" -v y="$h2" 'BEGIN{printf "%.6f", (x+y)/2}')
  FP_HW=$(awk -v a="$t2" -v b="$t1" -v c="$h2" -v d="$h1" 'BEGIN{printf "%.4f", ((a-b)+(c-d))/2}')
  return 0
}
# 快照字 W0..W(SNAP_WORDS-1) 一次读全, 打印成一行 (地址由 SNAP_WORDS 派生 ⇒ 不会读漏/读重)
snap_words(){
  local i
  for (( i = 0; i < SNAP_WORDS; i++ )); do printf "%s " "$(rd "$(snap_addr $i)")"; done
  echo
}

echo; echo "===== 0. 前提 ====="
lspci -nn | grep -i 10ee || { echo "  [FAIL] 端点不在 (先重启主机!)"; exit 1; }
# 别把 BDF 钉死 (上次是 02:00.0, 换槽/换内核都可能变) —— 现查现用
BDF=$(lspci -n | grep -i '10ee:9034' | awk '{print $1}' | head -1)
echo "  [INFO] 端点 BDF = ${BDF:-未找到}"
chk "0.1 链路" "$(cat /sys/bus/pci/devices/0000:${BDF}/current_link_speed 2>/dev/null)" "5.0 GT/s PCIe"
if ! lsmod | grep -qw xdma; then echo "  (insmod)"; insmod "$KO" || { echo "  [FAIL] insmod"; exit 1; }; sleep 2; fi
ls /dev/xdma0_* | tr '\n' ' '; echo
if [ -e $DEV ]; then echo "  [PASS] 0.2 user BAR 节点存在 ($DEV)"; PASS=$((PASS+1));
else echo "  [FAIL] 0.2 没有 $DEV"; FAIL=$((FAIL+1)); exit 1; fi

echo; echo "===== 0.3 通道活性总闸 (0xffffffff 一律当"没应答", 不当数据) ====="
# ⚠️ 用法坑 (实测踩到, 2026-09-29): reg_rw **不因 SLVERR 报错** —— XDMA 的 AXI-Lite 主机把
#    错误响应的数据填成 0xffffffff 交回用户态 ⇒ 0xffffffff **不是数据, 是"这次读没成功"**。
#    一旦这样, 后面所有"按位判断"的判据都会**假通过** (例: done 位测 `s & 2`, 而
#    0xffffffff & 2 != 0 恒真; "16 字冻结"也会因两次都读到同一个 ffffffff 而"通过")。
#    ⇒ 先把这道总闸立起来, 拦住整类假通过。
#    ⚠️ 注意: `lspci` 看到端点、甚至 config 空间读得出 10ee:9034, **都不能**当"设备活着"的
#       证据 (可能是主机侧/缓存状态)。唯一靠得住的是"BAR 读得动"。
M0=$(rd 0x00)
if [ "$M0" = "0xffffffff" ]; then
  echo "  [FAIL] 0.3 user BAR 全部读回 0xffffffff (SLVERR) ⇒ 观测通道没在应答, 后面判据无意义"
  echo "        先查 (按可能性排序):"
  echo "          1) **烧录后主机还没重启** -- PCIe 端点只认 FPGA 配置先于主机 POST"
  echo "             (项目纪律: 烧完必重启; 四种主机侧补救实测全无效)"
  echo "          2) 端点只是 lspci 里的陈旧条目 (config 空间可能来自主机缓存)"
  echo "          3) 设计侧 axi_aresetn 没释放 / axi_regs 没接上 => AXI-Lite 从不应答"
  exit 1
fi
echo "  [PASS] 0.3 通道在应答 (MAGIC = $M0)"; PASS=$((PASS+1))

echo; echo "===== 1. 身份 (前置闸: 认位流) ====="
chk "1.1 MAGIC (0x00)"  "$(rd 0x00)" "0x50360001"
chk "1.2 BUILD_ID (0x04)" "$(rd 0x04)" "$EXPECT_BID"
chk "1.3 MARKER (0x14)" "$(rd 0x14)" "0xdeadbeef"
hw=$(rd 0x10); echo "  [INFO] 1.4 HW_STATUS (0x10) = $hw  ([3]=user_lnk_up [4]=msi_enable [7:5]=msi_vec_w)"

echo; echo "===== 2. 快照触发协议 (0x18 / 0x1C) ====="
s0=$(rd 0x1c)
if snap_take; then echo "  [PASS] 2.1 触发后 done 置起"; PASS=$((PASS+1));
else echo "  [FAIL] 2.1 触发后 done 一直不置 (gmii 时钟没跑?)"; FAIL=$((FAIL+1)); fi
s1=$(rd 0x1c)
echo "  [INFO] SNAP_STATUS: 触发前 $s0 -> 触发后 $s1 (bit0=busy bit1=done bit2=seen, [31:16]=gen)"
if [ -n "$s0" ] && [ -n "$s1" ] && [ $(( s1 >> 16 )) -eq $(( (s0 >> 16) + 1 )) ]; then
  echo "  [PASS] 2.2 gen 恰好 +1"; PASS=$((PASS+1))
else echo "  [FAIL] 2.2 gen 不是恰好 +1 ($s0 -> $s1)"; FAIL=$((FAIL+1)); fi

echo; echo "===== 3. 读窗口原子性 (不重新触发 ⇒ $SNAP_WORDS 字必须逐位不变) ====="
R1=$(snap_words); R2=$(snap_words)
echo "  [INFO] 第 1 次: $R1"
echo "  [INFO] 第 2 次: $R2"
chk "3.1 未触发时 $SNAP_WORDS 字完全不变" "$R1" "$R2"

echo; echo "===== 4. ★ GMII 时钟活性 + 频率反解 (W5 = 0x34) ====="
snap_take; A=$(rd 0x34); T1=$(date +%s.%N)
sleep 0.5
snap_take; B=$(rd 0x34); T2=$(date +%s.%N)
if [ -z "$A" ] || [ -z "$B" ]; then echo "  [FAIL] 4.1 W5 读不出来"; FAIL=$((FAIL+1))
else
  DA=$((A)); DB=$((B)); DT=$(awk -v t1="$T1" -v t2="$T2" 'BEGIN{printf "%.4f", t2-t1}')
  echo "  [INFO] W5(gmii_free): $A -> $B   Δ=$((DB-DA)) / ${DT}s"
  if [ "$DB" -gt "$DA" ]; then
    echo "  [PASS] 4.1 **GMII 时钟在跑** (数据面时钟活着)"; PASS=$((PASS+1))
    echo "  [INFO] 4.2 GMII 时钟 ≈ $(awk -v d=$((DB-DA)) -v t="$DT" 'BEGIN{printf "%.2f", d/t/1e6}') MHz  (1G 时应 ≈125)"
  else echo "  [FAIL] 4.1 GMII 时钟**没在跑** (RXC 没来 / PHY 没起 / 网线没插)"; FAIL=$((FAIL+1)); fi
fi

echo; echo "===== 4.3 ★ 三个时钟域的频率正证据 (G2/C9) ====="
#   窗口必须 < 20 s: W24/W50 是 32 位 @156.25MHz ⇒ **每 27.49 s 回绕**一次。
#   ⚠️ 每个域**各取自己的两点**, 且**每一点都自证是新一代** (snap_pair: 触发 → gen+1 → 读数+时间戳)。
#      fix2 ④ 之前这里是"先读陈旧值再触发"⇒ W5/W24 报出 371/293 MHz 的伪 FAIL。
freq_check(){  # freq_check <字名> <word号> <标称MHz> <除数>   除数=2 供 W50 (toggle 沿数 = 2×频率)
  local nm="$1" wi="$2" nom="$3" div="$4" d dt f a b probe
  # 先探一次"该字是否实现" (0xffffffff = SLVERR = 读没成功, 与"哪一代"无关 ⇒ 不必自证)
  probe=$(rd "$(snap_addr $wi)")
  if [ "$probe" = "0xffffffff" ]; then
    echo "  [SKIP] $nm (W$wi @ $(snap_addr $wi)) 读回 0xffffffff ⇒ **该字未实现** (旧几何位流), 不当 FAIL"
    SKIP=$((SKIP+1)); return 0
  fi
  if ! snap_pair "$wi" "$SNAP_FREQ_GAP"; then
    echo "  [FAIL] $nm (W$wi): 取不到 **自证新一代** 的一对读数 —— $GEN_ERR"
    FAIL=$((FAIL+1)); return 1
  fi
  a=$FP_A; b=$FP_B
  d=$(( (b - a) % W32 )); [ "$d" -lt 0 ] && d=$(( d + W32 ))
  dt=$(awk -v x="$FP_TA" -v y="$FP_TB" 'BEGIN{printf "%.4f", y-x}')
  f=$(awk -v d="$d" -v t="$dt" -v k="$div" 'BEGIN{printf "%.4f", (t>0)? d/k/t/1e6 : 0}')
  echo "  [INFO] $nm: W$wi $a -> $b (**都是自证的新一代**, 第2点 gen=$FP_GEN; 时间戳半宽 ±${FP_HW}s)"
  echo "         Δ=$d / ${dt}s / ÷$div ⇒ $f MHz (标称 $nom)"
  # ⚠️ 判据不许在台架噪声上出结论: 时间戳半宽相对窗口 >0.5% ⇒ 本轮不判 (给"SKIP+原因", 不给假 FAIL)
  if awk -v h="$FP_HW" -v t="$dt" 'BEGIN{ exit !(t<=0 || h/t>0.005) }'; then
    echo "  [SKIP] $nm: 读数时间戳半宽 ±${FP_HW}s 相对窗口 ${dt}s 已超 0.5% ⇒ 频差被**台架自身**的抖动主导, 本轮不判"
    SKIP=$((SKIP+1)); return 0
  fi
  if awk -v f="$f" -v n="$nom" 'BEGIN{d=f-n; if(d<0)d=-d; exit !(d/n<=0.01)}'; then
    echo "  [PASS] $nm = $f MHz (标称 $nom ±1%)"; PASS=$((PASS+1))
  else echo "  [FAIL] $nm = $f MHz, 偏离标称 $nom 超 1% (该域没起 / 计数被钉死 / 窗口跨回绕)"; FAIL=$((FAIL+1)); fi
}
freq_check "前端域 gmii_free"   5 "$W5_NOM" 1
freq_check "数据面域 dp_free"  24 156.25 1
# ⚠️ W50 的 ÷ 口径**源码自相矛盾, 不许猜**: `board/wrapper_p4.v:3389` 的注释写"频率 = 沿数/2",
#   但 RTL 是 `tx_tgl_tx <= ~tx_tgl_tx` —— **每拍翻转一次**, dp 侧数**每次变化**
#   ⇒ 数学上是 **÷1**; 按 ÷2 读会得 78.125 MHz (**假 FAIL**)。差 2 倍, 不烧板判不了
#   ⇒ 两个都算, 命中哪个就打印哪个 (一次上板把这条钉死)。
freq_check_tgl(){ local nm="$1" wi="$2" nom="$3" a b d dt f1 f2 probe
  probe=$(rd "$(snap_addr $wi)")
  if [ "$probe" = "0xffffffff" ]; then echo "  [SKIP] $nm (W$wi) 读回 0xffffffff ⇒ 该字未实现"; SKIP=$((SKIP+1)); return 0; fi
  if ! snap_pair "$wi" "$SNAP_FREQ_GAP"; then
    echo "  [FAIL] $nm (W$wi): 取不到 **自证新一代** 的一对读数 —— $GEN_ERR"; FAIL=$((FAIL+1)); return 1
  fi
  a=$FP_A; b=$FP_B
  d=$(( (b - a) % W32 )); [ "$d" -lt 0 ] && d=$(( d + W32 ))
  dt=$(awk -v x="$FP_TA" -v y="$FP_TB" 'BEGIN{printf "%.4f", y-x}')
  f1=$(awk -v d="$d" -v t="$dt" 'BEGIN{printf "%.4f", (t>0)? d/t/1e6 : 0}')
  f2=$(awk -v d="$d" -v t="$dt" 'BEGIN{printf "%.4f", (t>0)? d/2/t/1e6 : 0}')
  if awk -v h="$FP_HW" -v t="$dt" 'BEGIN{ exit !(t<=0 || h/t>0.005) }'; then
    echo "  [SKIP] $nm: 读数时间戳半宽 ±${FP_HW}s 相对窗口 ${dt}s 已超 0.5% ⇒ 频差被**台架自身**的抖动主导, 本轮不判"
    SKIP=$((SKIP+1)); return 0
  fi
  if awk -v f="$f1" -v n="$nom" 'BEGIN{d=f-n; if(d<0)d=-d; exit !(d/n<=0.01)}'; then
    echo "  [PASS] $nm = $f1 MHz (**÷1 口径命中**) / ÷2 ⇒ $f2 (⇒ wrapper_p4.v:3389 的 '÷2' 注释需订正)"; PASS=$((PASS+1))
  elif awk -v f="$f2" -v n="$nom" 'BEGIN{d=f-n; if(d<0)d=-d; exit !(d/n<=0.01)}'; then
    echo "  [PASS] $nm = $f2 MHz (**÷2 口径命中**) / ÷1 ⇒ $f1"
    echo "         ⚠️ fix2 之前本行在这块板上曾报 '÷2 命中' 而真值是 ÷1 —— 那是同一个 2 倍度量伪影;"
    echo "            现在每点都自证新一代, 若仍命中 ÷2 请再核一次窗口 (>0.5s) 与 gen 自证行"
    PASS=$((PASS+1))
  else echo "  [FAIL] $nm: ÷1 ⇒ $f1 / ÷2 ⇒ $f2 都不命中标称 $nom ±1% (Δ=$d / ${dt}s)"; FAIL=$((FAIL+1)); fi
}
freq_check_tgl "TX 域 tx_clk_act" 50 156.25

echo; echo "===== 5. 数据面计数快照 (W0..W$((SNAP_WORDS-1))) ====="
snap_take
# 标签表: 下标 = word 号。逐字读回时**每一个字都要有名字**, 否则"读全了"只是形式。
WLABEL=(
 "rx_stat_frames   (MAC 收帧数)" "rx_stat_bytes    (MAC 收字节)"
 "{16'd0,wl_last}  (最近线上帧长)" "rx_stat_crc_err  (FCS 错帧)"
 "rx_stat_drop     (MAC 丢弃)" "gmii_free        (前端域自由计数 ⭐G2)"
 "srx_stat_commit  (交 HLS 慢路径)" "stx_stat_frames  (**HLS** 慢路径发帧)"
 "udpapp_tx_frames (图案 app 发帧)" "udpapp_tx_bytes  (图案 app 发字节)"
 "udpapp_rx_frames (图案 app 收帧)" "udpapp_rx_bytes  (图案 app 收字节)"
 "udpapp_rx_null   (空/坏帧)" "udpapp_mismatch  (图案失配, 必须 0)"
 "tx_stat_frames   (TCP fast path 发帧)" "tx_stat_bytes    (TCP fast path 发字节)"
 "srx_hls_bytes    (HLS 真读走的字节)" "hr_cnt           (hls_rst_n 低电平拍数 ÷80)"
 "stx_stat_purge   (slow_tx_adp 回卷帧数)" "srx_stat_drop    (slow_rx_adp 丢帧)"
 "mac_tx_frames    (**MAC 级**发帧)" "tx_stat_abort    (MAC 帧内中止)"
 "rx_stat_pass     (TCP fast path 接受帧)" "rx_stat_nonmatch (TCP fast path nonmatch)"
 "dp_free          (数据面域自由计数 ⭐G2)" "mmcm_locked(DP 同步版)"
 "rxcdc_full_cycles(RX FIFO 满拍数)" "{16'd0,rxcdc_occ_max}(RX FIFO 峰值)"
 "{16'd0,txcdc_occ_max}(TX FIFO 峰值)" "txwire_stall_cycles(DP 在等线)"
 "rxcdc_out_frames (RX FIFO 读侧 TLAST)⭐" "rxcdc_out_bytes  (RX FIFO 读侧 Σpopc)⭐"
 "rx_stat_drop_partial(已推过字的丢帧)" "rx_stat_orphan_bytes(孤儿字节)"
 "rx_stat_drop_full(FIFO 满丢帧)" "rx_stat_fifo_ovf (fifo_sync 拒写, 恒 0)"
 "mrx_stat_rx_words  (新 MAC XGMII 收字)" "mrx_stat_rx_pay_bytes(新 MAC 载荷字节)"
 "rxcdc_ovf_cnt      (RX CDC FIFO 拒写)" "pcs_status_bundle  (PCS 状态束 ⭐C1-C8)"
 "pcs_evt_bundle     (PCS 事件束 8×8 饱和)" "mtx_stat_flush_words(新 MAC 冲刷字)"
 "mtx_stat_flush_done (新 MAC 冲刷完成)" "mtx_stat_tx_words  (新 MAC XGMII 发字)"
 "mtx_stat_tx_ctrl_char(新 MAC 控制字符)" "txcdc_ovf_cnt      (TX CDC FIFO 拒写)"
 "cls_dbg_stat_ovf   (rx_classify 字 FIFO 拒写)" "cls_dbg_stat_route_ovf(路由队列拒写)"
 "cls_dbg_stat_stall_in(rx_classify 停等拍)" "cls_dbg_occ        (字 FIFO 占用)"
 "tx_clk_act         (TX 域 toggle 沿数 ⭐G2 = 频率×2)"
 # ---- P7B-BIZ 新增 6 字 (全是 dp 域寄存器输出) ----
 "app_tx_bytes       (TCP 演示 app TX 载荷字节)"
 "app_tx_frames      (TCP 演示 app TX 载荷帧数)"
 "app_rx_bytes       (TCP 演示 app RX 载荷字节)"
 "app_mismatch       (载荷逐字节失配 ⭐必须恒 0 增量)"
 "tx_stat_retx       (TCP 重传/RTO 回卷次数 ⭐必须恒 0 增量,F5b)"
 "udpapp_tx_ovf      (UDP app TX 字 FIFO 拒写 ⭐必须恒 0,丢字类回归守卫)"
 # ---- P7B-BIZ 追加 B: 重传会话的定性观测 (都来自 tcp_tx_frame 的已有寄存器输出) ----
 "tx_retx_hi          (回卷重放上界: 会话中 = ack 上界; **只在 W58=1 时有效**)"
 "tx_retx_active      (重传/回卷重放会话**进行中**; 低 1 位)"
 # ---- P7B-BIZ 追加 C: 慢路径两个适配器的拒写守卫 (恒 0) ----
 "stx_stat_fifo_ovf  (slow_tx_adp u_wf 拒写; 恒 0 = 无静默丢失)"
 "srx_stat_fifo_ovf  (slow_rx_adp o_ovf 拒写; 恒 0 = 无静默丢失)"
 # ---- P7B-WU 二轮新增 2 字 (63 字窗口; dp 域) ----
 "app_ctrl_stat_wu   (窗口重开通告入 ackq 次数; 不是'已上线')"
 "app_ctrl_rx_occ_bytes(app RX 可读字节, 17 位 ⇒ 高位恒 0)"
 # ---- 构建 C (2026-10-10) 新增 2 字 (65 字窗口; dp 域) ----
 "app_frmwait_cyc    (app_pattern 帧等待/停滞拍数)"
 "app_bp_cyc         (app_pattern 背压拍数)" )
for (( i = 0; i < SNAP_WORDS; i++ )); do
  v=$(rd "$(snap_addr $i)")
  W[$i]=$v
  printf "  W%-3s 0x%-3s %s = %s\n" "$i" "$(printf '%02X' $((0x20+4*i)))" "${WLABEL[$i]:-<无标签>}" "$v"
done
# ⚠️ 窗口内**不允许**出现 0xffffffff: 译码是连续实现的 (word 8..8+NW-1) ⇒ 窗口内的 F 只可能是
#    "SLVERR 混进窗口" (= 读没成功), **不是数据**。漏了这条, "全 F" 会被当成合法读数流下去。
NFF=$(for (( i = 0; i < SNAP_WORDS; i++ )); do [ "${W[$i]}" = "0xffffffff" ] && echo x; done | wc -l)
if [ "$NFF" -eq 0 ]; then echo "  [PASS] 5.0 窗口内 $SNAP_WORDS 字全部读得出且无 0xffffffff (SLVERR 未混入)"; PASS=$((PASS+1))
else echo "  [FAIL] 5.0 窗口内有 $NFF 个字读回 0xffffffff ⇒ 不是数据 (读没成功/选字回绕)"; FAIL=$((FAIL+1)); fi
echo "  [INFO] 判读: 有 ping 流量时 W0/W1 应涨; 若 W0 涨而 W6 不涨 ⇒ 帧没进慢路径 (ARP/ICMP 收不到);"
echo "          W6 涨而 W7 不涨 ⇒ HLS 收到了但没回 ⇒ 问题在慢路径/HLS, 不在前端。"
echo "  [INFO] 慢路径失聪时看这四对:"
echo "          W6 涨而 **W16 不涨** ⇒ HLS 真不读了 (不是缓冲的问题);"
echo "          **W17 涨** ⇒ 饥饿看门狗在反复复位 HLS (÷80 = 复位次数);"
echo "          W7 不涨时 **W18 涨** ⇒ HLS 产出了但被 slow_tx_adp 回卷 (别再怪 HLS);"
echo "          **W20** = 线上真发出去的帧数 (以前全设计没有这个数), 与 W7 对比可分开'没产生/没上线'。"

echo; echo "===== 6. 负向: 未实现地址必须走 SLVERR ====="
# ⚠️ 这个"未实现地址"随地图扩张挪过: 0x18 -> 0x44 -> 0x60 -> 0x84 -> 0xB0 -> 0xEC -> 0xFC -> 0x104 -> 0x114 -> **0x11C**
#    (**63 字**把 0x20..0x118 全占了 = word 8..70 ⇒ 第一个空地址 = word 71 = 0x11C;
#     本轮把读侧译码加宽到 7 位, 所以"第一个空地址"不会再撞上回绕别名)。
#    不挪 ⇒ 把"新功能上线"判成回归 (本工程已踩过两次)。
# ⚠️ **绝不能挑 ≥0x200** (2026-09-30 订正: 译码已加宽到 7 位 `araddr[8:2]`, 回绕周期 512 字节):
#    挑 0x100 会别名到 word 0 = MAGIC (读出 0x50360001 ≠ 0xffffffff) ⇒ 判据**假 FAIL**;
#    挑 0x160 则别名到**已实现**字 ⇒ 读出数据 ≠ ffffffff 也算过 ⇒ 判据**假 PASS**。
# ⚠️ 2026-09-30 修: 旧版这条判据用的是 `$U84` —— 一个**从未被赋值**的 0x84 时代残留变量名
#    (现在叫 UB0)。后果 = 判据**永远走 FAIL 分支**并且把空值当"实测值"打印出来 (假 FAIL 的一种,
#    与"假 PASS"同族: 判据在报告里看着"跑了", 实际上它跟读数没关系)。改名后必须**同趟**
#    再读一个**已实现**字做对照 —— 否则"读数取不到"与"译码过宽"在输出上不可区分。
UB=$(rd "$UNIMPL_ADDR"); U00=$(rd 0x00); UMK=$(rd 0x14)
echo "  [INFO] $UNIMPL_ADDR (未实现, word $((8+SNAP_WORDS))) = $UB ; 0x00 (实现) = $U00 ; 0x14 (实现) = $UMK"
if [ "$UB" = "0xffffffff" ] && [ "$U00" != "0xffffffff" ] && [ "$UMK" = "0xdeadbeef" ]; then
  echo "  [PASS] 6.1 未实现地址 $UNIMPL_ADDR 返回 0xffffffff (SLVERR); 同趟已实现字仍读出真值"; PASS=$((PASS+1))
else echo "  [FAIL] 6.1 未实现地址 $UNIMPL_ADDR 读出 '$UB' (期望 0xffffffff) ⇒ 译码过宽, 或该地址其实是已实现字 (地址没随窗口挪)"; FAIL=$((FAIL+1)); fi

echo; echo "########## 汇总: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (窗口 $SNAP_WORDS 字; 未实现地址 $UNIMPL_ADDR) ##########"
echo "########## 日志: $LOG ##########"
exit $FAIL
