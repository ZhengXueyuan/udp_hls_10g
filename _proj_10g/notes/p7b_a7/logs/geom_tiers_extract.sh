# 自动抽取自 _proj_10g/notes/p7b_affinity/j6_r6fix.sh 的 GEOM_TIERS 表 + 匹配循环 (逐字)
# 十六进制**大小写归一** (只用于比较, 打印仍用原样; 判据语义零改动 —— 先例 = 下面 geom_gate 块)
norm(){ printf "%s" "$1" | tr "A-F" "a-f"; }
# 档表格式: "NW|BID|WEXTRA|说明"  (WEXTRA 空 = t0/t1 字表退回 5 53 54)
GEOM_TIERS=(
  "66|0x00000018|61 62|构建 D (2026-10-10) 66 字 / BID 0x18 (P7B-A7: W65 = mac_tx_10g.stat_tx_idle)"
  "65|0x00000017|61 62|构建 C (2026-10-10) 65 字 / BID 0x17"
  "63|0x00000011|61 62|r6-fix (2026-10-08) 63 字 / BID 0x11"
  "61|0x00000008||P7B-BIZ 61 字 / BID 8 (必须同时 J6_LEGACY_GEOM=1; W61/W62 结构性不可读)"
)
geom_tiers_echo(){ local _t; for _t in "${GEOM_TIERS[@]}"; do
    IFS='|' read -r _a _b _c _d <<< "$_t"; echo "   档: NW=$_a + EXPECT_BID=$_b  ($_d)"; done; }
LEGACY=${J6_LEGACY_GEOM:-0}
GEOM_HIT=""; WEXTRA=""
for _t in "${GEOM_TIERS[@]}"; do
  IFS='|' read -r _nw _bid _we _desc <<< "$_t"
  if [ "$NW" = "$_nw" ] && [ "$(norm "$EXPECT_BID")" = "$(norm "$_bid")" ]; then
    GEOM_HIT="$_desc"; WEXTRA="$_we"; break
  fi
done
echo "HIT=[$GEOM_HIT] WEXTRA=[$WEXTRA]"
