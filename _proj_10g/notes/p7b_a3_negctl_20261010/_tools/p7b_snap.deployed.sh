#!/bin/bash
# p7b_snap.sh -- 板侧快照窗口取数器 (**现役 = 67 字 / BID 0x19**; 标题原文 = "板侧 **63** 字
#   快照窗口的取数器 (P7b Stage C: BID=10 / SNAP_NW=63)" —— 那一代已过时, 见下逐代订正)
#   ⭐ 构建 E (2026-10-10): 66 → **67** (W66 = tcp_tx_frame.stat_winstall; 未实现地址 0x128 → **0x12C**)。
#   ⛔ 2026-10-10 订正 (构建 C 门同步轮): 上面这句的标题**已过时** —— 默认几何现 = **65 字 /
#      BID 0x17** (构建 C: 快照 63→65, 新增 W63/W64 = `app_pattern` 的两个停滞计数);
#      原句保留 (它描述的是 Stage C 那一代)。⚠️ 与 `NW` 一样, `EXPECT_BID` 默认值**必须与
#      默认 `NW` 同代** —— 不同代的组合会让身份闸 `ID_FAIL` 直接红 (看着像板子错, 其实是门错)。
#   ⛔ 2026-10-07 Stage C BID 同步轮: 原句 = "(P7B-WU 二轮: BID=9 / SNAP_NW=63)" ——
#      窗口没动, 只有身份 9 → 10; 读 P7B-WU 二轮 (Build 2) 位流加 EXPECT_BID=0x00000009。
#   ⚠️ 旧位流: RATE 轮 51 字 `NW=51 UNIMPL_ADDR=0xEC`; BIZ 轮 61 字 `NW=61 UNIMPL_ADDR=0x114
#      EXPECT_BID=0x00000008` (板上 `1076e50e…1160` 就是这个; 用默认值读它会**响亮失败**:
#      BID 8 != 10 ⇒ id_check 报 ID_FAIL + W61/W62 读回 0xffffffff ⇒ dump_words 报 SNAP_FAIL)。
#      ⛔ 2026-10-07 Stage C: 上一行原文是 "BID 8 != 9" (那时默认值 = 9); 现默认 = 10,
#         同理 P7B-WU 二轮位流 (BID 9) 用默认值读也会**响亮失败** (覆盖 EXPECT_BID=0x00000009)。
#
# 协议 (源码唯一权威: board/wrapper_p4.v 的 `snap_dout_all` 装配 (逐项带槽号注释);
#        读法样板 _proj_pcie/p6e_snap_check.sh):
#   ⭐ P7B-BIZ 新增 10 字:
#      W51 app_tx_bytes / W52 app_tx_frames / W53 app_rx_bytes /
#      W54 app_mismatch / W55 tx_stat_retx / W56 app_udp_pattern.stat_tx_ovf /
#      W57 tx_retx_hi (回卷重放上界) / W58 tx_retx_active (会话进行中) /
#      W59/W60 slow_tx_adp / slow_rx_adp 的 stat_fifo_ovf (拒写守卫, 恒 0)
#   ⭐ **P7B-WU 二轮新增 2 字** (窗口 61 → 63; 加在 MSB 端 ⇒ 旧字逐项未动):
#      W61 app_ctrl.stat_wu        (窗口重开通告确实入 ackq 的次数; 寄存器 0x96 的同一根线)
#      W62 app_ctrl.rx_occ_bytes   (app RX 可读字节, 17 位显式零扩展 ⇒ 高位恒 0)
#   字 Wi 地址 = 0x20 + 4*i       触发 = 写 0x18=1       done = 0x1c 的 bit1      gen = 0x1c>>16
#   ⚠️ reg_rw 的第 3 个参数 `w` 是**位宽**(word), 不是 write —— 读就是 `reg_rw $D 0x20 w`
#   ⚠️ 0xffffffff **不是数据**, 是 SLVERR = "这次读没成功"。窗口内出现它 => 整窗作废。
#   ⚠️ 每次读数必须**自证是新一代** (gen 恰好 +1), 否则读的是上一次锁存的陈旧值
#      (全局教训 32/33; RATE 轮靠这条抓出过"恰好 2×"的假频率)。
#
# 需要 root (/dev/xdma0_user 是 crw------- root): 用 tools/peer_ssh.py --sudo 跑本脚本。
#
# 用法:
#   bash p7b_snap.sh id                      # 身份 + 通道活性 (0x00/0x04/0x14 + gen)
#   bash p7b_snap.sh full TAG                # 触发一次 + 打全 63 字 (带名字)
#   bash p7b_snap.sh snap TAG [W1 W2 ...]    # 触发一次 + 只打指定字 (省时)
#   bash p7b_snap.sh pair WORD SECS TAG      # 两点**各自自证**的差分 (速率用)
set -u
T=${P7B_TOOLS:-/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools}
D=/dev/xdma0_user
# 几何与身份可从环境覆盖 —— **一旦往窗口里加字, 这三个值必须跟着改**
# (NW 的单一真值源 = board/wrapper_p4.v 的 `SNAP_NW_P6E`; 未实现地址 = 0x20+4*NW)
#   ⚠️ **NW 上限 = 119** (读侧译码 7 位 ⇒ 字 0..127; 快照从字 8 起; 负对照需留 1 个空字)。
#      红线随之从"≥ 0x100 回绕" 改成 **"绝不能挑 ≥ 0x200"**
#      (0x200 在 7 位译码下回绕到 word 0 = MAGIC ⇒ 假 FAIL)。
NW=${NW:-67}
UNIMPL_ADDR=${UNIMPL_ADDR:-$(printf '0x%X' $(( 0x20 + 4*NW )))}   # 67 ⇒ 0x12C (65 ⇒ 0x124; 63 ⇒ 0x11C; 61 ⇒ 0x114; 51 ⇒ 0xEC)
EXPECT_BID=${EXPECT_BID:-0x00000019}
# ⛔ 2026-10-07 Stage C: 原默认值 = 0x00000009 (P7B-WU 二轮 = 9)。
# ⛔ 2026-10-10 (构建 C 门同步轮): 再上一代的默认 = **0x0000000A** (Stage C 63 字) ——
#    现役 = **0x00000017** (65 字; 源码 `board/wrapper_p4.v` 的 `BUILD_ID_V = 32'h00000017`)。
#    ⚠️ 默认 BID 与默认 NW **必须同代**: 配错 ⇒ `id` 直接 ID_FAIL (假红)。
# ⚠️ 读**旧位流**的口径 (必须显式覆盖, 别指望默认值):
#    P7b Stage C 63 字: `NW=63 EXPECT_BID=0x0000000A bash p7b_snap.sh ...`
#    BIZ 61 字: `NW=61 UNIMPL_ADDR=0x114 EXPECT_BID=0x00000008 bash p7b_snap.sh ...`
#    RATE 51 字: `NW=51 UNIMPL_ADDR=0xEC EXPECT_BID=0x00000007 bash p7b_snap.sh ...`
#    ⭐ P7B-WU 二轮 63 字 (Build 2; 与长度同但**身份不同**): `NW=63 EXPECT_BID=0x00000009 bash p7b_snap.sh ...`

rd(){ $T/reg_rw $D "$1" w 2>/dev/null | tail -1 | sed 's/.*: *//' | grep -oE '^0x[0-9a-fA-F]+'; }
addr(){ printf '0x%X' $(( 0x20 + 4*$1 )); }
# ⛔ 2026-10-07 Stage C 板级轮: 十六进制**大小写归一** (只加本函数 + 调用处, 判据语义零改动)。
#    病灶: `reg_rw` 按小写打印 (`0x0000000a`), 而 判据写的是大写 (`0x0000000A`), 原代码是
#    **字符串**比较 ⇒ **BID 世代里第一次出现字母 (9→0xA) 时身份门必假红**
#    (8/9/7 世代全是数字 ⇒ 这条结构性从未暴露; 实测: Stage C 位流上 `id` 报
#     `ID_FAIL 期望 BID=0x0000000A, 实测 BID=0x0000000a` —— 板子是对的, 是门错)。
#    修法: 比较前两边都归一到小写; 打印/落档仍用原样 (不许改读数本身)。
norm(){ printf '%s' "$1" | tr 'A-F' 'a-f'; }

# ⚠️ 非 root 时 /dev/xdma0_user (crw------- root root) 打不开 => 每条读都是**空串**。
#    空读 != 真 0 (本脚本的 rd 已把非 0x 开头的输出滤掉 => 判据会安全地 FAIL 而不是假通过),
#    但先把原因说清楚, 免得被误读成"板子死了"。
if [ "$(id -u)" -ne 0 ]; then
  echo "PRECHECK_FAIL 非 root: /dev/xdma0_user 打不开 => 所有读都是空串。"
  echo "  跑法: PEER_PW=... python tools/peer_ssh.py --sudo 'bash /tmp/p7b_biz/p7b_snap.sh $*'"
  exit 3
fi
[ -e "$T/reg_rw" ] || { echo "PRECHECK_FAIL 找不到 reg_rw: $T/reg_rw"; exit 3; }

declare -A NAME=(
 [0]=rx_stat_frames        [1]=rx_stat_bytes         [2]=wl_last_lastframelen
 [3]=rx_stat_crc_err       [4]=rx_stat_drop          [5]=gmii_free_FE
 [6]=srx_stat_commit       [7]=stx_stat_frames      [8]=udpapp_tx_frames
 [9]=udpapp_tx_bytes      [10]=udpapp_rx_frames    [11]=udpapp_rx_bytes
 [12]=udpapp_rx_null      [13]=udpapp_mismatch     [14]=tx_stat_frames_TCP
 [15]=tx_stat_bytes_TCP   [16]=srx_hls_bytes       [17]=hr_cnt_hlsreset
 [18]=stx_stat_purge      [19]=srx_stat_drop       [20]=mac_tx_frames
 [21]=tx_stat_abort       [22]=rx_stat_pass_TCP    [23]=rx_stat_nonmatch_TCP
 [24]=dp_free_DP          [25]=mmcm_locked         [26]=rxcdc_full_cycles
 [27]=rxcdc_occ_max       [28]=txcdc_occ_max       [29]=txwire_stall_cycles
 [30]=rxcdc_out_frames    [31]=rxcdc_out_bytes     [32]=rx_stat_drop_partial
 [33]=rx_stat_orphan_bytes [34]=rx_stat_drop_full   [35]=rx_stat_fifo_ovf
 [36]=mrx_stat_rx_words   [37]=mrx_stat_rx_pay_bytes [38]=rxcdc_ovf_cnt
 [39]=pcs_status_bundle   [40]=pcs_evt_bundle      [41]=mtx_stat_flush_words
 [42]=mtx_stat_flush_done [43]=mtx_stat_tx_words  [44]=mtx_stat_tx_ctrl_char
 [45]=txcdc_ovf_cnt       [46]=cls_dbg_stat_ovf    [47]=cls_dbg_stat_route_ovf
 [48]=cls_dbg_stat_stall_in [49]=cls_dbg_occ       [50]=tx_clk_act
 # ⚠️ W51..W60 = P7B-BIZ 新增的 10 个字 (业务观测面 + 重传会话定性 + 两个拒写守卫)
 #    ⚠️ 2026-10-07 (测量脚本同步轮) 三处**既存**表缺陷一并修 (只动名字, 不动逻辑):
 #       ① W51..W55 在本表里**从来没有名字** ⇒ 逐字打印成 `?`; 现补上 (与 p6e_snap_check.sh 的
 #          WLABEL 同源, 真值源 = `board/wrapper_p4.v` 的装配段 / `P7B_BIZ_WINDOW.md` §1)。
 #       ② `[33]=x[34]=y` 这种**紧贴写法** bash 会解析成 **键 33 的值 = "x[34]=y"**
 #          (实测), 于是 W33/W37/W48 打印的是**另一个字的名字拼在自己后面**, 而 W34/W38/W49
 #          反而查不到名字 ⇒ 属"判据安静失效"同族 (读的人会以为看的是那一列)。已加空格分开。
 #       ③ 尾部曾有一行重复键 `[56]=udpapp_tx_ovf_stat_tx_ovf` 覆盖掉 `[56]=udpapp_tx_ovf`
 #          ⇒ W56 打出的是**拼错的名字**。已删。
 #    W61/W62 = **P7B-WU 二轮**新增 (stat_wu / rx_occ_bytes)。
 #    地址由 NW 派生: UNIMPL_ADDR = 0x20+4*63 = **0x11C** (⛔ 2026-10-10: 现役 NW=65 ⇒ **0x124**)。
 #    逐字归属见 `board/wrapper_p4.v` 的装配段 (源码是唯一权威) 与
 #    `_proj_10g/notes/P7B_BIZ_WINDOW.md` §1 (现役槽位表)。
 [51]=app_tx_bytes         [52]=app_tx_frames       [53]=app_rx_bytes
 [54]=app_mismatch         [55]=tx_stat_retx        [56]=udpapp_tx_ovf
 [57]=tx_retx_hi           [58]=tx_retx_active      [59]=stx_stat_fifo_ovf
 [60]=srx_stat_fifo_ovf
 [61]=app_ctrl_stat_wu     [62]=app_ctrl_rx_occ_bytes
 # ⭐ W63/W64 = **构建 C (2026-10-10)** 新增两个字 (app_pattern 的两个停滞计数器;
 #    真值源 = `board/wrapper_p4.v` 装配段 / `_proj_10g/notes/p7b_biz_win/check_window.py` 判据 11 的映射)。
 #    ⚠️ 不漏这两行的话 `full` 会把它们打成 `?` (名字表缺口, 不是数据错)。
 [63]=app_frmwait_cyc      [64]=app_bp_cyc
 # ⭐ 构建 E (2026-10-10): W65/W66 —— **顺手补上两处表缺口** (上一轮实测 `full` 把它们
 #    打成 `?`: 表原只到 [64])。真值源 = `board/wrapper_p4.v` 装配段:
 #      W65 = mac_tx_10g.stat_tx_idle (线占空: S_IDLE 拍数) / W66 = tcp_tx_frame.stat_winstall (窗口门停顿拍数)。
 [65]=mac_tx_idle          [66]=tx_stat_winstall
)

id_check(){
  local m b k u
  m=$(rd 0x00); b=$(rd 0x04); k=$(rd 0x14); u=$(rd "$UNIMPL_ADDR")
  echo "ID_MAGIC $m   (want 0x50360001)"
  echo "ID_BID   $b   (want $EXPECT_BID = 本构建的 BUILD_ID)"
  echo "ID_MARKER $k  (want 0xdeadbeef)"
  echo "ID_UNIMPL $u  (want 0xffffffff: 未实现地址必须走 SLVERR)"
  if [ "$(norm "$m")" = "0xffffffff" ]; then   # ⛔ Stage C: 原 `[ "$m" = "0xffffffff" ]` (大小写敏感)
    echo "ID_FAIL 通道不应答 (0x00 = 0xffffffff)。按序查:"
    echo "  1) 烧录后是否做过 remove+rescan (配方: _proj_10g/notes/P7B_PCIE_RESCAN_RECOVERY.md §3; **不必重启对端机**)"
    echo "  2) lspci 里 LnkSta 是否 x4 (x0 => 场景 A, 只有重启能救)"
    echo "  3) xdma 驱动是否 insmod"
    return 1
  fi
  # ⛔ 2026-10-07 Stage C: 原句 = `[ "$m" = "0x50360001" ] && [ "$b" = "$EXPECT_BID" ] || {...}`
  #    —— 字符串比较遇 BID 含字母 (≥0xA) 必假红; 现改为 norm() 后比较 (语义不变)。
  [ "$(norm "$m")" = "0x50360001" ] && [ "$(norm "$b")" = "$(norm "$EXPECT_BID")" ] || { echo "ID_FAIL 身份不符 (烧了别的位流? 期望 BID=$EXPECT_BID, 实测 BID=$b)"; return 1; }
  # ⚠️ 未实现地址必须**当场断言** (不能只 print): 若板上是**更大**的窗口, 这个地址会回**真数据**,
  #    只打印 "(want ...)" 的话往下就看不出读的是哪一代几何 (本工程"判据安静失效"的老坑)。
  [ "$(norm "$u")" = "0xffffffff" ] || { echo "ID_FAIL 未实现地址 $UNIMPL_ADDR 读出 '$u' (期望 0xffffffff) ⇒ 板上窗口 >= $((NW+1)) 字 (NW=$NW 覆盖值不对), 或译码过宽"; return 1; }
  return 0
}

trig(){   # 触发一次并断言 gen 恰好 +1; 结果在 G0/G1
  local g0 g1 s i
  g0=$(rd 0x1c); g0=$(( (g0 >> 16) & 0xffff ))
  $T/reg_rw $D 0x18 w 0x1 >/dev/null 2>&1
  s=""
  for i in $(seq 1 400); do s=$(rd 0x1c); [ -z "$s" ] && continue
     [ $(( s & 2 )) -ne 0 ] && break; sleep 0.002; done
  if [ -z "$s" ] || [ $(( s & 2 )) -eq 0 ]; then echo "GEN_FAIL done 不置 (该域没时钟 / CDC 卡住)"; return 1; fi
  g1=$(rd 0x1c); g1=$(( (g1 >> 16) & 0xffff ))
  if [ $(( (g1 - g0 + 65536) % 65536 )) -ne 1 ]; then
     echo "GEN_FAIL gen 不是恰好 +1 ($g0 -> $g1) => 有并发写者, 本代读数不可归因"; return 2; fi
  G0=$g0; G1=$g1; return 0
}
G0=0; G1=0

dump_words(){   # dump_words <tag> [字列表...] (空 = 全部)
  local tag="$1"; shift
  local list=("$@"); [ ${#list[@]} -eq 0 ] && list=($(seq 0 $((NW-1))))
  local i v nff=0
  echo "SNAP_BEGIN $tag gen=$G1"
  for i in "${list[@]}"; do
    v=$(rd "$(addr "$i")")
    # ⛔ Stage C: SLVERR 判定也走 norm() (原 `[ "$v" = "0xffffffff" ]` —— 大写输出会**静默漏判**)
    [ "$(norm "$v")" = "0xffffffff" ] && nff=$((nff+1))
    printf 'W%-3s %-6s %-22s %s\n' "$i" "$(addr "$i")" "${NAME[$i]:-?}" "$v"
  done
  echo "SNAP_END $tag nff=$nff"
  [ "$nff" -eq 0 ] || { echo "SNAP_FAIL 窗口内有 $nff 个 0xffffffff (SLVERR 混入, 不是数据) => 整窗作废"; return 1; }
}

case "${1:-}" in
  id)   id_check || exit 1; echo "ID_OK $(date +%s.%N)";;
  full) trig || exit 1; dump_words "${2:-FULL}";;
  snap) trig || { echo "SNAP_ABORT"; exit 1; }; shift; dump_words "$@" ;;
  pair) W="$2"; SECS="$3"; TAG="${4:-PAIR}"
        if ! trig; then echo "PAIR_FAIL 第1点"; exit 1; fi
        A=$(rd "$(addr "$W")"); T1=$(date +%s.%N); GA=$G1
        sleep "$SECS"
        if ! trig; then echo "PAIR_FAIL 第2点"; exit 1; fi
        B=$(rd "$(addr "$W")"); T2=$(date +%s.%N); GB=$G1
        if [ -z "$A" ] || [ -z "$B" ]; then echo "PAIR_FAIL 空读 (空读 != 真0)"; exit 1; fi
        echo "PAIR $TAG W$W ${NAME[$W]:-?} A=$A (gen=$GA) B=$B (gen=$GB) T1=$T1 T2=$T2" ;;
  *) sed -n '2,25p' "$0"; exit 2;;
esac
