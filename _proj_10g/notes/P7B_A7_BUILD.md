# P7B-A7 构建 D —— 实现与验证件 (退回 TX_TAILCARRY / R-1 T+2 重定时 / 线占空计数器 / BID 0x18)

- 日期: 2026-10-10 · 角色: **实现工程师** (本轮) · 状态: **已实现 + 本地全部门通过**; ⛔ **未构建、未上板、未烧录**
- 基线: 仓库根 `D:\repo\XCKU5PMini\udp_hls_10g` (**HEAD = `15defaf`**), 工作树改动见 §1
- 原始日志目录: `_proj_10g/notes/p7b_a7/logs/` (+ `apply_edges.py` / `apply_negctrl.py` 两个可复算改动脚本)
- 本件口径: **判据的裁定权不在作者** —— 下面所有 "PASS" 都是**门自己打的**字样 (逐条附原始输出); 本件只报"门怎么说的 + 我核到哪一步"

---

## §0 一句话

四件全部落地: ① `.TX_TAILCARRY` 退回 `1'b0` (一行) · ② `rtl/tcp_tx_frame.v` 的 **R-1「T+2 重定时」** (值逐位不变, 唯一两个读点余量 4/6 → **3/5 拍**) · ③ `mac_tx_10g` 新增 **`stat_tx_idle` 线占空计数器** → 快照 **66 字** (W65, 进 **tx 束**) · ④ `BUILD_ID_V` 0x17 → **0x18** + 注释链。
**已有 13 个门 + 1 个静态核对器 (+其 3 变异) + 4 套假板子自证台架全绿** (含 R-1 的行为等价门 `TX_OVL_GATE: PASS`、真 wrapper 全链 `106 checks/0 fail`、66 字读回 + 其 3 变异负对照); 同时**修好两处代差夹具** (`p7b_gate4_negctrl.sh` / `p7b_gate4_livefake.sh` 原停在 63 字/Stage C, 现已 66/0x18 并实跑)。

---

## §1 逐文件 diff 摘要 (`文件:行号` = **改后**行号; old → new 逐字)

### 1.1 `board/wrapper_p4.v` (全部改动都在此一处: +64 行, 其中功能改动 8 行)

| # | 行 | old | new |
|---|---|---|---|
| ① | `:1208` | `.TX_TAILCARRY(1'b1)) u_app (` | `.TX_TAILCARRY(1'b0)) u_app (` |
| | `:1197-1207` | (注释 "本构建打开它") | 加 **退回理由块** (构建 C 零收益 −0.104% / WNS +0.021→+0.006; 锚 = frozen app_pattern + `run_cont_gate` A-vs-G; 参数臂覆盖 = `run_tailcarry_gate` ARM B) —— **注释, 不改逻辑** |
| ② | `:372` | — | `wire [31:0] mtx_stat_tx_idle;` (新声明) |
| ③ | `:2786` | — | `.stat_tx_idle (mtx_stat_tx_idle),` (mac_tx_10g 例化) |
| ④ | `:2831` | — | `assign mtx_stat_tx_idle = 32'd0;` (非 P7B_10G 分支常量占位) |
| ⑤ | `:3189` | `localparam SNAP_NW_P6E = 65;` | `localparam SNAP_NW_P6E = 66;` |
| ⑥ | `:3212` | `localparam SNAP_TX_NW = 4;` | `localparam SNAP_TX_NW = 5;` |
| ⑦ | `:3563` | `wire [127:0] txsnap_dout;  // [3:0] → 槽 0..3` | `wire [SNAP_TX_NW*32-1:0] txsnap_dout;  // [4:0] → 槽 0..4` |
| ⑧ | `:3571-3576` | `wire [127:0] txsnap_din = {mtx_stat_tx_ctrl_char, …}` | `wire [SNAP_TX_NW*32-1:0] txsnap_din = {` **`mtx_stat_tx_idle,  // 槽 4 → W65`** `mtx_stat_tx_ctrl_char, …}` |
| ⑨ | `:3579` | `wire [127:0] txsnap_din = 128'd0;` | `wire [SNAP_TX_NW*32-1:0] txsnap_din = {SNAP_TX_NW{32'd0}};` |
| ⑩ | `:3773` | — | **装配最上面加一项** `txsnap_dout[4*32 +: 32],  // W65 mac_tx_10g.stat_tx_idle` (旧 30 项逐字未动) |
| ⑪ | `:3979` | `.BUILD_ID_V (32'h00000017),` | `.BUILD_ID_V (32'h00000018),` + "**24 = P7B-A7 (构建 D)**" 注释块 (原 "23 = GAP9-TX" 块**逐字保留**在下方链上) |
| ⑫ | 注释 | — | 订正三处**文字**: `:3766` "后 27 个字" → **30** (3+(26-4)+5; 27 是 24 槽时代旧口径) · `:4132` `.SNAP_NW` 算式末项 4 → **5** · `:3195` 扩窗块补 66 字预算复算 |

### 1.2 `rtl/tcp_tx_frame.v` (+61/−11; ⛔ **全部落在 `ifdef TCP_TX_OVL` 分支内**, 默认分支逐字节未动 —— 见 §3.6 的 hunk 行号核)

| # | 行 | old | new |
|---|---|---|---|
| ① | `:406` | `reg ack_pend_r;` 之后无 | `reg start_ack_d1;` (**+1 FF**) |
| ② | `:760` | `ack_pend_r <= 0;` 那行的下一行 | `start_ack_d1 <= 1'b0;` (复位) |
| ③ | `:792` | `ack_pend_r <= !ackq_empty;` 之后 | `start_ack_d1 <= start_ack;` |
| ④ | `:808-811` | (无) | **新增装载块**: `if (start_ack_d1) begin ctrl_ipcsum <= ctrl_ipcsum_now; ctrl_tcpcsum <= ctrl_tcpcsum_now; end` —— 放在**两个 case 之外** |
| ⑤ | `:614` | `wire [31:0] csum_init_val = …cam_rd_sip…` (即 `ctrl_acc` 的一项) | `wire [31:0] csum_init_ctrl = …cfg_src_ip 两半 + **ctrl_dip** 两半 + 32'h0006` (**csum_init_val 本体一字未动** —— 它还被 `:648` 的 checksum16 `.init_val()` 消费) |
| ⑥ | `:617-621` | `ctl_aen_v1/v2/v3` 的操作数 = `cam_rd_dport / cam_rd_sport / rb_snd_nxt / ctrl_ack_now / ctrl_doff_now / rb_rcv_wnd` | 同名列, 操作数换成 **已寄存字段** `ctrl_sport / ctrl_dport / ctrl_seq / ctrl_ack / ctrl_doff / ctrl_wnd` (一对一映射见源码注释) |
| ⑦ | `:622` | `ctrl_acc = csum_init_val + …` | `ctrl_acc = **csum_init_ctrl** + …` (其余一字不动) |
| ⑧ | `:625` | `ctrl_ipcsum_now = ip_csum_calc(16'd40, **id_r, cam_rd_sip**)` | `ip_csum_calc(16'd40, **ctrl_idcap, ctrl_dip**)` |
| ⑨ | `:915-917` | `ctrl_ipcsum <= ctrl_ipcsum_now; ctrl_tcpcsum <= ctrl_tcpcsum_now;` (在 `if (start_ack)` 块内) | **删除这两行** (换成解释性注释); 该块其余 10 项 + `id_r` 递增**一字未动** |

### 1.3 `_proj_10g/p7b_mac/rtl/mac_tx_10g.v` (+19 行, 纯观测)

| # | 行 | 内容 |
|---|---|---|
| ① | `:53-65` | 新端口 `output reg [31:0] stat_tx_idle` + **语义逐字定义**(§4) |
| ② | `:341` | 复位块加 `stat_tx_idle <= 0;` |
| ③ | `:350` | `if (state == S_IDLE) stat_tx_idle <= stat_tx_idle + 32'd1;` (放在 `case(state)` **之外**, 与 `stat_tx_words` 同区) |

### 1.4 读侧/门/夹具 (65 → 66 字全链同步; 逐条 `apply_edges.py` 可复算)

| 文件 | 改动 |
|---|---|
| `_proj_10g/notes/p7b_affinity/j6_r6fix.sh` | `NW=${NW:-65→66}` · `EXPECT_BID …0x17→0x18` · **`GEOM_TIERS` 加一行** `"66\|0x00000018\|61 62\|构建 D …"` (旧档 65/63/61 全部保留) |
| `_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh` | 同上 (档表格式含 WEXTRA 列) |
| `_proj_10g/notes/p7b_biz_win/check_window.py` | 判据 5 **重写**: 5a = 最上面一项必须是 **tx 束槽 4** · 5b = 紧随其后 14 项 = W64..W51 (p7bdp) · 5c = 逐槽映射 (51..64) · **5d 新增** = W65 跨文件一致性 (mac_tx_10g 端口 ↔ wrapper 接线 ↔ `txsnap_din` 首项) |
| `_proj_10g/notes/p7b_biz_win/tb_biz_win.v` | `NW = 65→66` (+ 末字/未实现地址注释 0x124/0x128) |
| `…/p7b_biz_win/run_tb_biz_win.bat` · `run_xvlog_wrapper.bat` · `sim/p5wu_p1p2/run_xvlog_wrapper63.bat` | **指纹** `"SNAP_NW_P6E = 65"` → `66` (+ 报错文案) |
| `_proj_pcie/p6e_snap_check.sh` | `SNAP_WORDS 65→66` · `EXPECT_BID 0x17→0x18` · UNIMPL 注释 0x124→0x128 |
| `_proj_pcie/p7b_biz/p7b_snap.sh` | `NW 65→66` · `EXPECT_BID→0x18` · UNIMPL 注释 |
| `_proj_pcie/p7b_gate4_accept.sh` | `EXPECT_BID→0x18` · `SNAP_WORDS→66` · 现役句 |
| `_proj_pcie/p7b_gate4_selftest.sh` | `SW→66` · **新分支 `-ge 66`** (W65 坑位 + `FAKE_UNIMPL` 挪 0x128; 65/63/61 三档逐字保留) · `FAKE_BID→0x18` |
| `_proj_pcie/p6e_snap_selftest_fix2.sh` | 假字表 `0X124` 改为真字 (W65) + **新增 `0X128) V=0xffffffff`** · `FAKE_BID→0x18` |
| `_proj_pcie/p7b_gate4_livefake.sh` | 假快照 `[0]*14 → [0]*15` (W51..W65) · `bid = {66:"0x00000018", 65:…}.get(nw, **"0x00000018"**)` |
| `_proj_pcie/p7b_gate4_negctrl.sh` | **代差修复**: 合成夹具 63→66 字 · `BID 0x0A→0x18` · `shift1` 的 `NW=63→66` (原句注释保留) |
| `_proj_10g/notes/p7b_gate4_3/final_state.sh` | `UNIMPL=$(rd 0x124→0x128)` + 增读 `W63/W64/W65` |
| `sim/p6e_pcie/tb_p6e_pcie_counters.v` / `tb_p6e_pcie_wrapper.v` | BID 判据 `0x17→0x18` · **未实现地址读址 + 判据名 0x124→0x128** |
| `_proj_10g/p7b_chain/sim/tb_p7b_chain.v` | `7b` 判据地址+名字 → `0x128` (原句历史块保留) |

**行尾纪律**: 三个 RTL 文件改后仍是**纯 CRLF、0 个裸 LF** (`tcp_tx_frame.v` 2090 CRLF / `wrapper_p4.v` 4283 / `mac_tx_10g.v` 475); `git diff --stat` 与 `git diff --ignore-cr-at-eol --stat` **逐字相同** (61/11 与 64 行) ⇒ 无"全文件行尾翻转"混入。

---

## §2 ⭐ R-1 的逐拍正确性论证 (纯逻辑; 与源码逐行对齐)

**记法**: 拍 T0 = `start_ack` 拉高的那一拍 (即 `:472` 的线与为 1 的那一拍); 所有寄存器在 T0 沿更新, 新值自 **T0+1** 起可见。

**A. 值为什么逐位不变** (四步, 每步都只依赖源码结构)

1. **旧式的操作数集合** = `{cam_rd_sip, cam_rd_dport, cam_rd_sport, rb_snd_nxt, rb_rcv_wnd, ctrl_ack_now, ctrl_doff_now, id_r, cfg_src_ip}` (`:563-595`)。
2. **同一拍 (T0) 的装载表** (`:855-868`) 把其中八项**原样**写入寄存器:
   `ctrl_seq←rb_snd_nxt` · `ctrl_ack←ctrl_ack_now` · `ctrl_doff←ctrl_doff_now` · `ctrl_wnd←rb_rcv_wnd`
   `ctrl_dip←cam_rd_sip` · `ctrl_sport←cam_rd_dport` · `ctrl_dport←cam_rd_sport` · `ctrl_idcap←id_r`, 且 `id_r←id_r+1`。
   ⇒ 在 **T0+1 拍**, `ctrl_*_` 里持有的**正是旧式在 T0 拍读的那份操作数** (id_r 同理: `ctrl_idcap` = T0 拍的 `id_r`)。
3. **T0+1 拍这些字段不可能被改写**: 它们唯一的功能写使能是 `start_ack`; 而 `start_ack(T0+1) ≡ 0` ——
   `start_ack = rx_idle && ack_pend_r && !ackq_empty && !rx_flush && !ctrl_slot_busy` (`:472`), 其中 `ctrl_slot_busy` 已在 **T0 沿拉高** (`:853`)。
   ⚠️ 且 `ctrl_slot_busy` 的**唯一清位者**是 T_DONE 分支 (`:1035`), 而它要求 `tx_state==T_DONE` **且** `tx_is_ctrl`; 在 T0 拍 `ctrl_tx_pend==0`(pend ⊆ busy)、`ctrl_slot_busy==0`(start_ack 的前提) ⇒ 两者**结构性不共存** ⇒ 不存在"同沿置 1 又被清 0"。
   ⇒ 新式在 T0+1 拍复算出的 `{ipcsum, tcpcsum}` 与旧式在 T0 拍组合算出的**是同一批输入** ⇒ 值逐位相同。
4. **加法部分的"逐位"依据**: 四个 18 位项各**零扩展成 32 位**再加 (`{14'b0, …}` 逐字保留), 32 位和上界 = `0x4FFFB + 3×0x3FFFF = 0x10FFF8 < 2³²` ⇒ **无溢出、无截断**; 加法交换律 ⇒ 与旧式**同一个 32 位整数**; 再经**同一条 `fold16`** (`:341-348`) ⇒ 16 位结果逐位相同。
   `ipcsum` 侧同理: `ip_csum_calc(16'd40, ctrl_idcap, ctrl_dip)` 与旧式 `(16'd40, id_r, cam_rd_sip)` 在 T0+1/T0 上**入参逐位相同**。
   ⚠️ 边界: 若将来有人让 `ctrl_slot_busy` 在 T0+1 拍**同时**被清 (例如把 T_DONE 与 start_ack 的互斥拆掉), 本论证作废 —— 见 §5 的"守卫建议"。

**B. 读点余量从几拍变几拍**

- 消费侧**只有两个**读点 (全文唯一消费者, 已逐行核): `:961` `3'd3: m_axis_tdata <= {h_ipcsum, …}` (**thcnt==3**) 与 `:967` `hold48 <= {h_wnd, h_tcpcsum, 16'h0000}` (**thcnt==5**)。
- `T_HDR` 只有两条入口: `:944-947` (T_IDLE) 与 `:1051-1053` (T_DONE 边界), 两处都把 `thcnt <= 3'd0`。
- `ctrl_tx_pend` 最早在 **T0+1** 可见 (`:854`) ⇒ T_HDR 最早 **T0+2** 进入 ⇒ `thcnt` 序列 = T0+2:0, T0+3:1, T0+4:2, **T0+5:3 (读 ipcsum)**, T0+6:4, **T0+7:5 (读 tcpcsum)**。
  (T_DONE 入口只会更晚: 需要 `tx_state==T_DONE` ∧ `ctrl_tx_pend` 同拍 ⇒ 最早也是 T0+2 进 T_HDR、thcnt 从 0 起。)
- ⇒ **新装载 (T0+1 沿落地, 自 T0+2 可见) 到两个读点 = 3 拍 / 5 拍** (旧装载自 T0+1 可见 ⇒ 4/6)。
  `m_axis` 反压 (`:953` 的 `!m_axis_tvalid || m_axis_tready`) 只会让 thcnt 停住 ⇒ 只增不减。
- **会话级无覆盖** (背靠背控制帧): 下一帧的 `start_ack` 必须等本帧 T_DONE 清 `ctrl_slot_busy`; 纯 ACK 的 T_DONE 最早落在 T0+9 (T_HDR 6 拍 + T_PAY 1 拍 + T_DONE 1 拍, `h_plen==0`) ⇒ 下一帧的校验和装载 (≥T0+11) 必然晚于本帧两个读点 ⇒ **无竞争**。

**C. `start_ack_d1` 的置/清点**

- 置: `:792` `start_ack_d1 <= start_ack;` (每拍无条件) ⇒ `start_ack_d1` = `start_ack` 的**1 拍延迟**; 由于 `start_ack` 不可能连高两拍 (上 §A-3), 它是**单拍脉冲**, 每帧恰好命中一次。
- 清: 复位 `:760` 置 0; 其余拍由 `:792` 的本拍 `start_ack` 值覆盖 ⇒ **无需额外清位逻辑** (不是"事件型状态", 是纯延迟).
- ⚠️ **放置点** (本轮抓到的一处设计件未点明的坑): 装载块**不能**放进 `RX_IDLE:` 分支 —— `start_ack` 只要求 `rx_idle`, 而**同拍**的 `accept` (`:871`) 可能恰是活帧**帧尾** (`s_axis_tlast`), 那会在 T0 沿把 `rx_state` 推到 `RX_FIN` ⇒ **延迟拍 (T0+1) 上 `rx_state != RX_IDLE`** ⇒ 放进分支里会**静默漏装** (该控制帧带上一帧的旧校验和上线, 且没有任何握手判据会红)。本轮放在**两个 case 之外** (§1.2-④)。

**D. 与 `T_DONE` 边界路径 (`:1051-1053`) 的关系**

`T_DONE` 入口 = 本帧结束时若 `ctrl_tx_pend` 已置 (即上一拍已装载好槽), 直接进 T_HDR。它的**唯一**影响是把"T_HDR 最早进入拍"从 T0+2 推后 (d+1 ≥ T0+2, d = 该 T_DONE 拍) ⇒ 读点更晚 ⇒ 余量更大。⇒ **该路径不构成新的最早读点, 也不引入任何截止压力**。
反面: 若有人让 `T_DONE` 入口**早于** `ctrl_tx_pend` 可见 (例如用组合 pend), 那 T_HDR 可能在同一拍看到**上一帧**的 `ctrl_ipcsum` ⇒ 但那已经违反 `pend ⊆ busy` 契约 (M-C9 的负对照正是打这条), 不在本刀范围。

**E. 本刀**没有**碰的四条契约** (逐条核过): 仲裁键 `ctrl_tx_pend` / 槽独占 `ctrl_slot_busy` · `upd_wr_*` 三写源 `$onehot0` (`:487-497`) · `start_ack` 对 ackq 的 `rd` (`:680`) · `s_axis_tready`/`start_data` 门 (`:511-519`)。

---

## §3 验证 1–6 的原始输出 (逐条; 全文在 `_proj_10g/notes/p7b_a7/logs/`)

### 3.1 (验证 1) 默认/退回态等价 —— `sim\p7b_longsend\run_cont_gate.bat`

```
  A default          RC=0   (expect 0)
  B APP_CONT_ARM     RC=0   (expect 0)
  C P7B_10G+CONT     RC=0   (expect 0)
  G frozen anchor    RC=0   (expect 0)
  M1 CONT_OK=0        RC=1  (expect nonzero)     M2 no-txok-reload  RC=1
  M3 miss-frmwait     RC=1  (expect nonzero)     M4 term-open        RC=1
  [PASS] equivalence anchor: A vs G byte-identical on 24 files
  [PASS] A10 zero arm: z_zero_c == z_zero_d on A/B/C/G
  [PASS] compile-source witness: A/B/C live rtl, G frozen anchor
CONT-GATE: PASS          (脚本退出码 RC=0)
```
⚠️ **覆盖缺口如实报**: 该门**不编 wrapper** (它直接编 `rtl/app_pattern.v` + `tb/tb_app_cont.v`) ⇒ 它覆盖的是"**参数默认 (1'b0)** 那条路径 = 冻结锚", **不覆盖** wrapper 那一行传值。覆盖 wrapper 传值的臂在**另一个门**:

`sim\p7b_longsend\run_tailcarry_gate.bat` (本轮实跑, 原始输出):
```
  A default            RC=0   (expect 0)
  B P7B_10G            RC=0   (expect 0)     ← ⭐ 本刀退回后**板级构建落在这一臂**
  C P7B_10G+TCARM      RC=0   (expect 0)     (TB 用 `\`define TC .TX_TAILCARRY(1'b1),`)
  D TCARM (no P7B10G)  RC=0   (expect 0)
  M1 TAILC_OK=0        RC=1  (expect nonzero)   M2 bad-frame update RC=1   M3 no ev_up clear RC=1
  [PASS] mutant arms ran and produced in-TB [FAIL] reds
  [PASS] carry byte-equivalence: B vs C byte-identical on 6 finite-session files
  [PASS] param gate inert without P7B_10G: A vs D byte-identical on 22 files
  [PASS] compile-source witness: A/B/C/D all compile the LIVE rtl\app_pattern.v
TAILCARRY-GATE: PASS
```
⇒ **`1'b0` 把板级构建放回 ARM B 的等价配置** (P7B_10G + carry 关), 该臂 RC=0 且与 ARM C 在有限会话文件上**逐字节相同**。

### 3.2 (验证 2) ⭐ R-1 的行为等价 —— `sim\p7b_stagec_tx_regress\author_gate\run_tx_ovl_gate.bat`

两个静态前置 (先跑):
```
PROBE PASS
  (module import performed no write/open-for-write (clean)
   module plan() agrees with ast table on all 9 mutants (hits per sub identical))
DRYRUN OK (0 bytes written)
```
主门 (脚本退出码 **RC=0**):
```
TB_TCP_TX_OVL: OK       ← 臂 A (默认串行)
TB_TCP_TX_OVL: OK       ← 臂 B (TCP_TX_OVL = **含 R-1 的板级分支**)
  [C]: TB_TCP_TX_OVL: FAIL reds=18     [D]: FAIL reds=11   [E]: FAIL reds=2102
  [F]: FAIL reds=25   [G]: FAIL reds=8604  [H]: FAIL reds=2  [I]: FAIL reds=16
  [J]: FAIL reds=10   [K]: FAIL reds=375
TX_OVL_GATE: PASS
```
臂 B 的关键读数 —— ⚠️ **比对口径**: 下面的读数里 **15 行**与改动前 (03:38 那次, 我在改 RTL 前已逐行抄录 runB/xs.log) **逐字相同**: `COV` / `MINGAP` / `CYCRX` / `CYCTX` / `FRAMEPERIOD` / `WIRE` / `DUT stat_*` / `OVL F1` / `OVL C6` / `OVL wsrc` / `OVL RETXFIX` / `REDS` / `REDS2` / `T8` (两行) / `PACE`;
`FRAMES recv=…` 那一行我**改动前没抄到** ⇒ **未比对** (它只作为本轮读数登记):
```
FRAMES recv=2444 data=2100 ctrl=344 dead_skip=4 cyc=354886     ← 本轮读数 (未比对)
COV frames=2100 replay_sessions=24 replay_frames=39 conns=4 plen0=270 singlebeat=814 ctrlblock=8660 rewinds=24
MINGAP handoff_to_next_start=1 finmin1_hits=723 advwrite_to_next_start=5
CYCRX min=6 avg_milli=119206 n=2064      CYCTX min=8 avg_milli=105154 n=2100
FRAMEPERIOD min=8 avg_milli=168866 n=2099
DUT stat_frames=2443 stat_bytes=1626139 stat_ack=344 adrop=0 drop_len=92 eend=0 fin=5 rst=1 retx=24 tlast_in=2153
OVL F1 overtop_cyc=1053 wrap_ev=63 delta_red=0 cyc_red=0 cov_aborts=92 cov_cdadj=2062 ctrlblk_real=8660
OVL wsrc data=2101 ctrl=16 rew=31 pendclr_wrong=0 ovf=0 issued fin/rst/syn=5/1/10
REDS parse=0 csum=0 payload=0 seqcont=0 seqmono=0 ctrl=0 ctrl_to=0 onehot=0 pendbusy=0 replay=0 stuck=0 ovf=0 ackf=0
T8 rx1460 min=189 n=1074 …  tx1460 min=191 n=1105 …  overlap=47/100 of RX-inflight (119651/249477)
PACE fpc_milli=5914
```
⇒ **`csum=0`** (TB 从线上字节独立复算 IP/TCP 校验和) + 全部 13 类 REDS 全 0 + 帧节拍/仲裁/记账读数逐字不变 ⇒ **"改了 `tcp_tx_frame` 而门仍 PASS ⇒ 行为没变"** 正是本轮要证的。

### 3.3 (验证 3) 线占空计数器 —— 扩写 `tb_mac_10g.v` 组 12 (`_proj_10g\p7b_mac\sim\run_tb_mac_10g.bat`)

```
=== tb_mac_10g done: 398 checks, 0 fail ===      (原 391 + 新增 7 条)
VERDICT = PASS
-- 组 12: stat_tx_idle (line occupancy counter)
  [ ok ] 12.1 empty-input 64-cycle window: delta == 64
  [ ok ] 12.1b reading is NONZERO (counter really runs)
  [ ok ] 12.2 window spans exactly one frame boundary
  [ ok ] 12.2 saturated window: idle delta == 0 (IFG not idle)
   [grp12 readings] v_prev=7 v_now=628 delta=621 ndbg=621 frames=3
  [ ok ] 12.3 per-cycle identity: delta == #dbg-idle cycles
  [ ok ] 12.3b window contains idle cycles (trailing idle)
  [ ok ] 12.3c burst (3 frames) completed inside window
```
- **① 非零 + 独立复算**: 12.1 的窗口拍数由 TB 自己数 (64 拍), 无输入 ⇒ DUT 只能停在 S_IDLE ⇒ Δ 必须恰好 64。
- **② 定义在两种激励下都符合预期**: 12.1 (有间隙) 精确 64; **12.2 (满流)** 窗口跨**一个帧边界**(含第 2 帧的 **S_IFG 两拍**) ⇒ Δ == **0** ⇒ 把 S_IFG 也算空闲的话这里必 ≥2 而红。
- **③ 与 ΔW20 同窗相除**: 12.2 的 Δframes = 1、Δidle = 0 ⇒ **每帧空闲拍 = 0** (满流)。
- **12.3 逐拍恒等式**: 1200 拍窗口 (含 3 帧 + 尾随空闲) 里 Δcounter = **621** == TB 自己数的 dbg-idle 拍数 **621**。旁证: 3 帧 × 193 拍 = 579, `1200 − 579 = 621` **逐位吻合**。
- **门的牙** (3 个手工变异, `P7B_RTL` 指向 `_proj_10g/notes/p7b_a7/mut_rtl_{a,b,c}`):
  ```
  mut_a (计数所有拍)      RC=1  [FAIL] 12.2 idle delta == 0 / 12.3 identity
  mut_b (改计 S_IFG)      RC=1  [FAIL] 12.1 delta==64 / 12.1b / 12.2 / 12.3
  mut_c (跳过首帧前空闲)  RC=1  [FAIL] 12.1 / 12.1b / 12.3 ; 读数 delta=619 ≠ ndbg=621
  ```
- **既有 17 条变异全跑**: `MUT_VERDICT = PASS (不等价变异漏掉 0 条)` (17/17 与期望一致, 5 条等价变异按预期"不漏") ⇒ 新端口没有废掉任何既有锚点。

### 3.4 (验证 4) 快照 66 字的装配 —— 五处 + 两个守卫 + 档表

- `check_window.py` (现役树): **`PASS=56 FAIL=0 INFO=1` / `CHECK_WINDOW_PASS`**, 其中
  `1 总字数 == SNAP_NW_P6E (项数=31, 逐项字数之和=66, NW=66)` · `3 束宽等式 == NW (14+22+3+(26-4)+5 = 66)` ·
  `4 * 旧字未移位 (HEAD 30 项, 新表 31 项 => 新增 1 项全在 MSB 端)` · `5a 最上面一项 = W65 (tx 束槽 4)` · `5d` 四条全过。
  三个负对照 (内存变异): `drop` → 4 条 FAIL · `swap` → 3 条 · `declpatho` → 5 条 (含判据 7 未声明网) ⇒ **守仍有效**。
- `run_tb_biz_win.bat` (逐字读回, 判据用各不相同的常数): **`PASS_ALL tb_biz_win: 26 项判据全过 (窗口 66 字)` / `TB_BIZ_WIN_PASS`**;
  其负对照 `run_neg.bat`: **`NEG_GATE_PASS 4/4`** (`real=PASS`, 三个变异 `mut_base6/mut_dec6/mut_lastoff` 全 FAIL)。
- 编译面: `run_xvlog_wrapper.bat` → **`XVLOG_WRAPPER_PASS 4/4`**; `sim/p5wu_p1p2/run_xvlog_wrapper63.bat` → **`XVLOG_WRAPPER63_PASS 6/6`** (含 **t4 = 板级真实宏组 {APP_MODE+P7B_10G+PCIE_OBS+DEV_USP+DP_156MHZ+UDP_TX_OVL+TCP_TX_OVL} 编 `tcp_tx_frame.v`**)。
- 真 wrapper 全链 (额外跑): `_proj_10g\p7b_chain\sim\run_tb_p7b_chain.bat` → **`106 checks, 0 fail` / `VERDICT = PASS`**, 含新判据 `[PASS] 7b 0x128 reads 0 no wrap`。
- P6e 两 TB: `PASS_ALL tb_p6e_pcie_wrapper: 全链门全过` · `PASS_ALL tb_p6e_pcie_counters`。
- 假板子四套 (**全跑**): `p7b_gate4_selftest.sh` → `OK=14 BAD=0` (66 个字/0X124=W65/0X128 未实现/负对照打中 6.1) · `p6e_snap_selftest_fix2.sh` → `OK=19 BAD=0` · `p7b_gate4_livefake.sh` → `OK=26 BAD=0` · `p7b_gate4_negctrl.sh` → **`OK=15 BAD=0`** (clean 正对照 `FAIL=0` 退出 0 + 14 条负对照全部打中指定判据)。
- `GEOM_TIERS` 档表逻辑实测 (从 `j6_r6fix.sh` 逐字抽出表 + 匹配循环跑):
  `NW=66/BID=0x18` → 命中构建 D 档 (WEXTRA=`61 62`); `NW=65/BID=0x17` → 命中构建 C 档; **`NW=66/BID=0x17` (错配) → 无命中** ⇒ "成对"语义保持。

### 3.5 (验证 5) 两条活门

`sim\p7b_stageb_rx8\run_rx8_gate.bat`:
```
  A default        RC=0   (expect 0)
  B P7B_10G        RC=0   (expect 0)
  C M8-to-M        RC=1   D lane0-only RC=1   E no-tail-fallback RC=1   F no-ev-up-yield RC=1
  [PASS] byte-equivalence: A vs B identical on 8 dump/stats files
  [PASS] mutants are RX-scoped: TX dump identical to A on all 4
  [PASS] python oracle agrees with runB
RX8-GATE: PASS
```
`sim\p7b_longsend\run_cont_gate.bat` → `CONT-GATE: PASS` (§3.1)。
⚠️ 常驻矩阵 `sim/p4gates/run_matrix_p4dfix.bat` **未跑** —— 其编译清单不含 `wrapper_p4.v`/`app_pattern.v` (上一轮已实证 `16/16 FROZEN` 是**空证据**), 跑它对本类改动零覆盖 ⇒ 不拿它当证据。

### 3.6 (验证 6) `xvlog` + 参数/端口名交叉核对

- 4 宏组合 (经 `run_xvlog_wrapper.bat`): `d0_default/d1_p7b/d2_app/d3_biz_full` **全 `rc=0`**, 0 条 `VRFC 10-2989`/`not declared`/`ERROR:`; 6 臂版另含 t3/t4 ---- 均 `rc=0`。
- 端口交叉核对 (脚本逐名比对, 见 §1.3): `mac_tx_10g` 端口表 **19 项** ↔ wrapper 命名连接 **19 项** ↔ `tb_mac_10g` 命名连接 **19 项**: **非法名 0 / 未连 0**。
- `rtl/app_pattern.v` 的 `parameter TX_TAILCARRY = 1'b0` **未动**; `board/wrapper_p4.v` 里唯一的功能性传值 = `.TX_TAILCARRY(1'b0)` (另一处命中在注释里)。
- **结构性核 (证明默认分支逐字节未动)**: `git diff -U0 rtl/tcp_tx_frame.v` 的全部 hunk 新行号 = 406 / 583..610 / 614..622 / 625 / 760 / 792 / 796..812 / 915..917, **全部落在 `ifdef TCP_TX_OVL` 分支 (236..1076) 内**。

---

## §4 新计数器 `stat_tx_idle` 的语义定义 (逐字 = RTL 端口声明处)

> **语义**: rst_n 有效且**本拍执行态** `state == S_IDLE` 的每一拍 +1。
> · **计**: 复位释放后 FIFO 空、FSM 停在 S_IDLE 的那些拍 (线上正发 `/I/`)。
> · **不计**: 复位那一拍 (走 `!rst_n` 支, 计数清零); 以及 `state ∈ {S_PRE, S_DATA, S_TAIL0, S_TAIL1, S_IFG, S_ABORT, S_FLUSH}` 的拍。
> ⚠️ **与 `stat_tx_words`/`stat_tx_ctrl_char` 的分工**: 那两个是"线上发了什么"(每拍无条件 +1 / 数控制字符); 本计数器量的是"**帧间 FSM 无事可做**的拍数" —— **S_IFG/S_FLUSH 也发 `/I/` 但不算空闲** (它们属于帧的线上占用)。
> **回卷**: 32 位 @156.25 MHz ⇒ 每 **27.487 s** 自然回卷 (= 与 `stat_tx_words` 同域同周期)。
> **独立复算 (板级, 同窗同域)**: `Δstat_tx_idle / Δstat_frames` = **每帧 S_IDLE 拍数** (= `P − 帧内占用拍`, 其中 `P = Δstat_tx_words/Δstat_frames`); 两量都按 mod 2³² 读 (窗口 < 27.487 s 时与直接相减等价)。

接线口径: `mac_tx_10g.stat_tx_idle` → `mtx_stat_tx_idle` → **tx 束** `txsnap_din` 槽 4 → 装配最上面一项 → **W65** (地址 `0x124`); 域 = `tx_fe_clk` (= PCS `tx_mii_clk_1`) ⇒ 与 W41..W44 同域同束 (⛔ **不能**塞 dp 束: `snap_cdc` 的 `din_b` 前提是"b 域寄存器输出")。**纯观测**: 全仓核过, `stat_tx_idle` 无第二个消费者, wrapper 里只进快照。

---

## §5 未做 / 未证 + 对设计件的订正

### 5.1 未做 (不许当已做)

| # | 项 | 状态 |
|---|---|---|
| 1 | **构建 / 综合 / 实现 / 时序读数 (WNS/端点)** | ⛔ **未做** (本轮不建位流)。R-1 的收益只有 §2 的结构论证 + 设计件 §2.1 的预期, **没有任何实测时序**; `stat_tx_idle` 的 +1 控制集吃多少余量也**未量** |
| 2 | **板级 (读数 / 语义验证 / W65 落数)** | ⛔ **未做** (无新位流)。12.x 是 **xsim 单元级**证据, 板级"ΔW65/ΔW20"尚未测过 |
| 3 | **R-2 / R-3 / (c) 复制 / (d-2) 预计算** (设计件 §2 的其它候选) | 未做 (**一次构建收口**, 本轮只落 R-1) |
| 4 | **常驻矩阵 `sim/p4gates/run_matrix_p4dfix.bat`** | **未跑** —— 结构性空证据 (清单不含 `wrapper_p4.v`/`app_pattern.v`), 已实证 |
| 5 | **`sim/p5wu_p1p2/check_wu_words.py`** (63 字专用核对) | **未复活** (它属 WU 轮的定向件; 其调用面只有自身 + REM 注释, 无可执行调用点)。若要活, 需要按 66 字重写判据 |
| 6 | **`tb_snap63.bat` / `sim/p5wu_p1p2_regress/head_rtl/**` / `sim/**/{mirror,mut,head_rtl,frozen,foreign}` / `extra*/`** | **刻意未动** (冻结锚/守卫树/代差臂; 按纪律禁止改) |
| 7 | **`sim/p6e_pcie` 两 TB 的"字值"判据** (W0..W50 的 force 值) | 未跟 (它们与 66 字无关); 只改了 BID + 未实现地址两条 —— 两门实跑 `PASS_ALL` |
| 8 | 3 个**手工计数器变异** | 已跑 (§3.3), 但**未登记进** `mutate_gate.py` 的常驻清单 (留待 TL 决定: 登记则每次全跑 +3 臂) |
| 9 | `_proj_10g/notes/p7b_gap9_tx_board_20261010/{burn_arm,run_arm}.sh` (上一轮的**板级臂**脚本, 钉在构建 C) | **刻意未动** (它们是那一代的取证脚本; 构建 D 的板级轮应新开一代 — 直接改会把上一轮读数与脚本对不上) |
| 10 | `sim/p5c_a1/mkstim.py` 里的 `0x12445679` | **非窗口地址** (是一个 seq/ack 常数), 无动作 |

### 5.2 对设计件 (`P7B_A7_CSUM_SINK_DESIGN.md`) 的订正与裁定

| # | 设计件原文 | 实况 (回源码) |
|---|---|---|
| 1 | §2.1-4 "**唯一读点在 T+8**" (§三表) vs "**T+5 / T+7**" (§2.1-4 正文) **内部不一致** | ⭐ **裁定 = T+5 (ipcsum) / T+7 (tcpcsum)**, 以 `start_ack` 拍为 T0、以"值可见的那一拍"为装载拍。依据: `:961` 是 `thcnt==3`、`:967` 是 `thcnt==5`; T_HDR 最早 T0+2 进入且 `thcnt<=0` (**两处入口都复位 thcnt**); thcnt 每拍 +1 (仅 `m_axis` 反压时停)。**"T+8" 与任何一条入口都对不上**, 判为笔误 (T0+2+6)。本件 §2-B 给的是**逐行可复算**版本 |
| 2 | §2.1 "把 `ctrl_tcpcsum_now`/`ctrl_ipcsum_now` 与 `ctrl_acc` 若不再被别处使用即随之删除" | ⚠️ **部分不成立**: `csum_init_val` **不能删** —— 它还驱动 `:648` 的 `checksum16 .init_val()` (数据帧校验和初值)。本轮做法 = 保留 `csum_init_val` **逐字不动**, 新增并列的 `csum_init_ctrl` (操作数换成 `ctrl_dip`) |
| 3 | §2.1-3 "`ctrl_slot_busy` 在 T+1 置位且直到 T_DONE 才清 ⇒ T+1 拍的 `start_ack` 恒为 0 (不会有第二次装载与新值竞争)" | ✅ 成立, 但**本件补了两条设计件没写的边**: ① `ctrl_slot_busy` 的唯一清位者 (T_DONE 支) 与 start_ack **结构性不共存** (T0 拍 `pend==0`、`busy==0`); ② **值的正确性其实只需要"T0+1 拍这些字段未被改写"**, 而这条比"start_ack 在 T0+1 恒 0"更弱、更稳 (即使脉冲间隔 1 拍也成立) —— 但**无覆盖竞争**那半段仍要靠槽独占 |
| 4 | §2.1 建议"新增位放 `:760` 附近" | ✅ 采纳 (声明放 `:406` 的 reg 区、复位放 `:760`、赋值放 `:792`); ⚠️ **装载块位置**设计件未指定, 本轮定为**两个 case 之外** (理由见 §2-C: `start_ack` 与帧尾 `accept` 可同拍 ⇒ 延迟拍 `rx_state` 未必 RX_IDLE) |
| 5 | §4.1-4 回归判据引用 `board/check_p6e_timing.py` 对 `p7b_ku5p_timing.rpt` | 本轮**未跑** (无构建) ⇒ 留给构建轮 |
| 6 | §1.5 "四源名单" 与 §1.4 的 `ack_pend_r_reg_replica` 判读 | 未复核 (本轮不读时序报告); 与设计件口径一致保留 |
| 7 | ⚠️ 本轮的**新增风险点** (设计件 §2.1 的"风险"一节只提了"最早读点 T+5/T+7 依赖两条入口") | 本轮实测**发现第二条更硬的风险**: 装载块若放进 `RX_IDLE:` 会**静默漏装** (§2-C)。建议构建/审查轮把它固化成一句话纪律写进 `rtl/tcp_tx_frame.v` 头注释 (已写在装载块上方) |

### 5.3 本轮修掉的**两处夹具代差** + 一次自伤 (全部实跑验证)

1. `_proj_pcie/p7b_gate4_negctrl.sh` 原停在 **63 字 / BID 0x0A** (上一轮只抬了 accept 脚本, 没抬它) ⇒ 它的 clean 正对照在 65 字时代**就会假红** ⇒ 整台 15 条负对照**结构性失效**。本轮抬到 66/0x18 并实跑: **`OK=15 BAD=0`**。
2. `_proj_pcie/p7b_gate4_livefake.sh` 的假快照 `[0]*14` (到 W64) 在新 66 字请求下会 **IndexError** (假对端直接崩 = "整台安静")。本轮 `[0]*15` + `bid` 表加 66 → 0x18, 实跑 **`OK=26 BAD=0`**。
3. (自伤一次, 已修) 我第一版把 `sim/p6e_pcie/tb_p6e_pcie_wrapper.v` 的**判据名**改成 0x128 却漏改**读址** ⇒ 该门 `[FAIL] 9 … = 00000000 (期望 00000002)`。修后 `PASS_ALL`。**教训**: 挪未实现地址是"读址 + 判据名"两处, 改一处 = 假红/假绿。

---

## §6 能不能进构建?

**判断: 能进构建 —— 前提是构建轮按设计件 §4.1 的判据 A/B/C 收口, 且把"这一次构建"当作 R-1 的唯一归因面。**
依据: ① 四件改动全部落地且**无一条功能改动越界** (§3.6 的 hunk 行号核 + 端口 19/19 交叉核 + 行尾纯 CRLF); ② **行为等价的正面证据**: R-1 的门两臂全绿且臂 B 读数与改动前基线**逐字相同** (含 `csum=0`)、`TX_CONTINUOUS` 的 A-vs-G 24 文件逐字节锚仍在、真 wrapper 全链 106/0; ③ 新计数器的**判据有牙** (3 变异全红 + 17 条既有变异全对) 且**退化为 0 时也抓得住** (12.1 的"非零 + 精确复算"); ④ 读侧 66 字全链齐 (五处 + 两守卫 + 档表 + 4 套假板子 + 2 条真 wrapper 全链门)。⛔ **不许**把本件读作"时序已改善 / 计数器板上已验证" —— 这两格都还是空的 (§5.1-1/2)。

---

## §7 交付指纹 (供构建轮对齐)

```
rtl/tcp_tx_frame.v                          sha256 ae9c15cb23e2ed53…  (129,986 B · CRLF 2090 / bareLF 0)
board/wrapper_p4.v                          sha256 d2f78200dbf25aef…  (261,631 B · CRLF 4283 / bareLF 0)
_proj_10g/p7b_mac/rtl/mac_tx_10g.v          sha256 59475c827af78644…  ( 27,438 B · CRLF  475 / bareLF 0)
_proj_10g/p7b_mac/sim/tb_mac_10g.v          sha256 11f9ad33ea90df8e…
_proj_10g/notes/p7b_biz_win/check_window.py sha256 b55102d2384daedc…
_proj_10g/notes/p7b_biz_win/tb_biz_win.v    sha256 7b5d6572206b6479…
_proj_10g/p7b_chain/sim/tb_p7b_chain.v      sha256 25b96fcdd32f55ff…
sim/p6e_pcie/tb_p6e_pcie_wrapper.v          sha256 5bdf7ee4218f5470…
```
原始日志: `_proj_10g/notes/p7b_a7/logs/{mac_gate_stdout,mac_mut_{a,b,c}_stdout,mac_mutate_gate_stdout,cont_gate_stdout,tailcarry_gate_stdout,txovl_gate_stdout,rx8_gate_stdout,xvlog_wrapper_stdout,xvlog_wrapper63_stdout,tb_biz_win_stdout,biz_win_neg_stdout,p7b_chain_stdout,p6e_wrapper_stdout,p6e_counters_stdout,gate4_selftest_stdout,snap_selftest_fix2_stdout,gate4_livefake_stdout,gate4_negctrl_stdout}.txt`
可复算脚本: `_proj_10g/notes/p7b_a7/{apply_edges.py,apply_negctrl.py}`; 计数器变异件: `_proj_10g/notes/p7b_a7/mut_rtl_{a,b,c}/`
档表逻辑取证: `_proj_10g/notes/p7b_a7/logs/{geom_tiers_extract.sh,geomtest_66_18.txt}` (从 `j6_r6fix.sh` 逐字抽出表+循环后跑三种 NW/BID 组合)
⚠️ `_proj_10g/notes/p7b_gate4_tools/{selftest,fix2,negctrl}/**` 里的产物文件是**那四个自证脚本自己重写的** (它们的既定行为), 内容已随 66 字几何更新 —— 不是手改。
