# ⚠️ 本目录 (`p7b_mac_synth/rtl/`) = **修复前快照**，不是现行件

**身份**：2026-09-29 的**修复前**副本（入库提交 `11e93d3`，2026-09-29 23:13；
对应 `effef26` 之前的 `_proj_10g/p7b_mac/rtl/mac_tx_10g.v` —— 归一化 CR 后与 `effef26^` 的那份
逐字节相同）。

**关键差别**：`mac_tx_10g.v` 这里是**旧语义** —— pad 字节**不**计入 FCS，
因此**没有** `cmask64` / `p0_fcs`（`grep -c` 实测 = 0）。
与现行件（修后）的差异 = `effef26` 的 **+58 / −12 = 70 行**（`diff` 实测）。

**现行件在哪**：`../p7b_mac/rtl/`（= `_proj_10g/p7b_mac/rtl/`）。
构建与门**都从那里取**：

- `board/build_p7b_ku5p.tcl:28` — `set mac_dir ${root_dir}/_proj_10g/p7b_mac/rtl`
- `board/build_p7b_ku5p.tcl:100` — `import_files -norecurse ${mac_dir}/crc32_64.v ${mac_dir}/mac_rx_10g.v ${mac_dir}/mac_tx_10g.v`

⇒ **改本目录的文件对构建没有任何影响**（同名不同内容 = 陷阱）。要改 MAC，改 `../p7b_mac/rtl/`。

**逐文件实测对照**（`cmp` 对 `../p7b_mac/rtl/`）：

| 本目录文件 | 与现行件 |
|---|---|
| `mac_tx_10g.v` | **DIFFER**（就是上面那个修复前/后差别） |
| `crc32_64.v` | 逐字节相同 |
| `mac_rx_10g.v` | **DIFFER**（2026-09-30 起）—— 本目录是 **P7B_LANEFIX 修前**的 `mac_rx_10g.v`（修法 = lane4 起帧的 4 字节重对齐；现行件 `+122/−25` 行）。差异与验证见 `_proj_10g/notes/P7B_LANEFIX.md` |
| `fifo_sync.v` / `mac_rx_min_top.v` / `mac_tx_min_top.v` | 只此一份（OOC / 最小顶层用） |

**为什么留着（不删、不改）**：这里是 `../reports/` 与 `../logs/gate/` 那批
**MAC 接入前后 A/B 时序对照**（OOC）的输入件，有对照价值。
（审查登记见 `_proj_10g/notes/P7B_MAC_GATEFIX.md` §12 第 4 条。）

**sha256**：

- 本目录 `mac_tx_10g.v` = `b1f4aaff7c852612d5e3c3c03218e017d89df2afee093052cd28d79ac7d232d0`
- 现行 `../p7b_mac/rtl/mac_tx_10g.v` = `1e4a61b60b168ab61273a971b9350b89c1b84968c6e40d1e0557b38aff017c59`
