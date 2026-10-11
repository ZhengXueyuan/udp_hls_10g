# M1 期 B【接线】轮报告 (2026-10-11) —— TL 裁 P2: C2H 环 + 真 AR→R 对账 + H2C 丢弃从机

> 落盘说明：本件正文由接线轮 agent 全文回传，**TL 代落盘**（该 agent 的 `REPORT.md` Write 被平台策略拒绝 —— 本会话第 6 例；按派单最后一级回退）。
>
> ⛔ **未出位流 / 未 bump BID / 未做读侧同步**（构建轮统一做）。基线 = `git HEAD f3e2690`（本树未提交任何改动）。

## 0. 一句话结论

**P2 已落地**：读通道接既有 `aximm_c2h_win` + `mir_dma_ring`；写通道接**新写的最小"永远应答并丢弃"从机** `rtl/aximm_h2c_discard.v` ⇒ "内部仲裁是否依赖写通道握手"这个**明文网表核不出的前提被结构性消除**。
**门全绿**：新从机单元门 305 判据（+3 突变全被捉）· p6e 全链门 **108 PASS / 0 FAIL**（+31 条新判据，含**真 AR→R 拍与环内容逐位对账**）· p6e 两个突变臂"该红时红"（期 A srcinv + **期 B bwire 定向**）· tb_mir_dma 45/45（+3 突变）· 镜像门（+2 突变）· tb_biz_win 40 判据 + NEG_GATE 4/4 · check_window 92/0 · lint OK · `-only p5_wrapper` EXIT=0 · 工具 `--selftest` T1–T7 PASS。
**synth 面净代价与 m1/m1p2 臂逐位同**（WNS `−0.377` / WHS `−0.661` 四臂同值）；新锥最紧 = **1.95 ns**（h2c→XDMA IP 的 m_axi 握手）；资源 +197 FF / +4×RAMB36E2（环 4 bank）/ LUT −14。

## 1. 接线逐条（两分支各改了什么）

### 1.0 先核与派单描述不符之处（照"现读为准"逐条）

| 派单写 | 现读实况 | 处置 |
|---|---|---|
| `:3751` 一带例化两件 | 现读 :3750 = `app_rx_mirror` 例化头（文件已随 0x1C/0x1D 构建位移） | 照"该块内"执行 ✓ |
| `:4103-4120` 一带 m_axi tie-off | 现读 **:4241-4259** 同一段（逐字仍"全回永不应答"） | 照实际行号改 ✓ |
| 写通道"7 条" | 实为 **4 条响应 + 11 条请求**（awid/awaddr/awlen/awsize/awburst/awvalid/wdata/wstrb/wlast/wvalid/bready） | **全接**，无悬空 ✓ |
| `build_p7b_ku5p.tcl` import **+2 行** | 实况需导**三个**新件（c2h/ring/新从机） | **+3 行**（登记） |
| —（派单未提） | `MIR_STATUS.ver` 是否 bump | 2→**3**（判断项，§2.5，附理由与 1 行回退点） |

### 1.1 真支（`APP_MODE ∧ DP_156MHZ`，在 `PCIE_OBS` 内）—— `board/wrapper_p4.v` 9 个 hunk

1. **共用网线声明块**（`:3732-3771`，位于 `ifdef APP_MODE` **之前**）：33 根 `mir_axi_*` + `mir_dma_cnt`。理由：XDMA 例化在 PCIE_OBS 内、三层宏**之外**，必须连"任何宏组合都存在"的线名（按宏叉开两份端口表 = 本工程点名的禁形）。
2. **`u_mir` aux 三口改接**（`:3818-3825`）：`.dma_req(1'b0)→(mir_dma_req)`；`.dma_gnt()→(mir_dma_gnt)`；`.clr_pulse_rd()→(mir_clr_pulse_rd)`。三根线**声明在 `u_mir` 之前**（`:3783-3790`）—— 晚声明 = `VRFC 10-2938 already implicitly declared` 硬错（实测踩过一次，§6-#1）。
3. **三件例化**（`:3830-3887`）：`u_mir_ring`（ROW_AW=10）+ `u_mir_c2h`（ROW_AW=10）+ `u_mir_h2c`；同用 `pcie_axi_aclk`/`pcie_axi_aresetn`；环读口（`rr_row/rr_dout`）与 C2H 从机共线。
4. **XDMA 例化**（`:4241-4274`）：11 条响应从 `1'b0/4'd0/128'd0` 改为网线；`.m_axi_bready()` 悬空 → `(mir_axi_bready)`；请求线全部接出。`arprot/arlock/arcache` 与 `awprot/awlock/awcache` **仍悬空**（从机端口表里没有；明文=常量），注释写明。
5. **axi_regs 例化**（`:4593`）：加 `.mir_dma_cnt(mir_dma_cnt)`。

### 1.2 两个 ¬ 分支（`¬DP_156MHZ` 与 `¬APP_MODE`）—— 常数表（`:3905` / `:3928`，各 12 行）

`mir_axi_arready/rid/rdata/rresp/rlast/rvalid` + `awready/wready/bid/bresp/bvalid` = 0，`mir_dma_cnt = 32'd0`。**逐位等价于期 B 之前的 1'b0 tie-off**；请求线不驱动（XDMA 输出、本支无消费者）。

### 1.3 明确未动（逐字）

- ⛔ **`:1319-1322` app 寄存器总线 tie-off** 未动（现读 `:1320` = `assign app_reg_addr = 8'h00;`）。
- ⛔ **`rtl/tcp_rx.v` / `rtl/tcp_tx_frame.v`** 未动（`git status` 空）。
- ⛔ **BID 仍 `0x1E`**（我的 diff 里 0 处 `BUILD_ID`）。
- 全部改动**都在 `ifdef PCIE_OBS` 内** ⇒ ¬PCIE_OBS 的默认/p5 构建逐位不变（`-only p5_wrapper` EXIT=0 实证）。

## 2. 寄存器 / 工具侧几何（`MIR_DMA_CNT` / `0x14C`）

### 2.1 `_proj_pcie/rtl/axi_regs.v`

新端口 `mir_dma_cnt`（`:186`）；`MIR_DMA_CNT_IDX = SNAP_LAST_IDX + 4`（`:203`）、`MIR_LAST_IDX = MIR_DMA_CNT_IDX`（`:204`）⇒ **未实现地址 = 0x14C（word 83）**；写侧 `mir_ctrl_r[3] <= wdata_r[3]`（`:268`）；读 mux 新支（`:409`）。SLVERR 边界原已参数化，自动跟着走。

### 2.2 `MIR_DMA_CNT` 语义（冻结）

`= mir_dma_ring.wr_words`（已写字数，32 位 mod 2³²）；环 = 16 KB（4096 字），"逻辑字 L → 物理字 L mod 4096"；**幂等只读**；`clr` 使计数与写指针同拍归零。

### 2.3 工具 `_proj_pcie/p7b_biz/p7b_mir_dump.cpp`

- 工具侧原常量（0x148 / bit3）**与本次落地一致，无需改**。
- 本轮**新加**：`A_UNIMPL = 0x14C` + `--dma` 路径**边界身份门**（读 0x14C 必须回 `0xffffffff`，否则响亮 `exit(2)`）—— 同时证明"0x148 是真字不是别名"。
- ⚠️ 该身份门在**真机路径**，`--selftest` 覆盖不到（登记，§5-⑤）。

### 2.4 几何常量同步清单（逐处）

| # | 文件 | 改动 |
|---|---|---|
| ① | `_proj_10g/notes/p7b_biz_win/check_window.py` | 未实现地址公式 `0x20+4*NW` → `+16`（MIR 四字） |
| ② | `_proj_10g/notes/p7b_biz_win/tb_biz_win.v` | 判据 6 `+12→+16`/`0x148→0x14C`；判据 11 加 `mir_dma_cnt` 端口常数 + 5 条新判据（0x148 映射 / 0x14C 读写 SLVERR / bit3 写读回 / ver=3） |
| ③ | `sim/p6e_pcie/tb_p6e_pcie_wrapper.v` | 判据 9 与 M1-5 的 `0x148 → 0x14C` |
| ④ | `board/wrapper_p4.v` | `SNAP_NW_P6E` 注释 `0x148 → 0x14C`（**字数不变仍 71**） |

⚠️ **读侧脚本**（`p6e_snap_check.sh` / `p7b_snap.sh` / `p7b_gate4_selftest.sh` 的 `UNIMPL_ADDR`）**未动**——按派单属"读侧同步"，构建轮统一做。

### 2.5 `MIR_STATUS.ver` 2 → 3（**判断项，请 TL 复核**）

`axi_regs.v` 既有规则逐字："ver = 4'd2（期 A: 1→2，因为 MIR 寄存区块的位语义变了）"。本轮 MIR_CTRL 加 bit3 + 新读字 ⇒ 同规则适用，故 bump 3（`tb_biz_win` 11a 期望同改）。`MIR_STATUS` 位域恰好 32 位，**无空位**放"dma_en 读回"（其读回走 MIR_CTRL 字）。若 TL 不认：回退 = 改 1 个字面量 + 1 条判据期望。

## 3. 新写从机 + 全链门读数与负对照

### 3.1 新件 `rtl/aximm_h2c_discard.v`

AW/W/B 全握手；`bresp` 恒 OKAY；数据丢弃（`wdata/wstrb/awaddr/…` 无寄存器消费者，综合会整个优化掉）；**B 只锚 WLAST**（AW 与 WLAST 同拍也认）；**一次一笔**（AW 收到 → `awready` 低；WLAST 收到 → `wready` 低；B 被收走 → 两条通道同时重开）⇒ 无 ID 队列、B 的 id 与 W 数据天然同笔；**两条通道各自独立就绪** ⇒ 不假设 AW/W 到达顺序；`nbeat` 内部计数只给仿真当"丢弃见证"（登记）。

### 3.2 单元门（`sim/p7b_h2cdisc/`）

- real：**`H2C_DISC_GATE PASS_ALL (checks=305)`**。
- 突变 3 臂全部**该红时红**：`mut_bid` 7 FAIL / `mut_bearly` 263 FAIL / `mut_wready` 6 FAIL。
- ⚠️ **过程留档**：`mut_bearly`（AW 一到就发 B）**第一版逃过全门**（原门只判"WLAST 后有 B"）⇒ 补 P1/P2"**WLAST 前不许有 B**"后才捉住 —— "新判据第一版没牙是常态"的又一实例。

### 3.3 p6e 全链门升级（真 wrapper + 真 AR→R；31 条新判据）

替身 `xdma_0_sim_stub.v` 扩出两个层次任务（`m_axi_read`/`m_axi_write`，只扩必要面：单笔 INCR 16 B/拍；全等待有界、越界打 `*_to`）：

- **真 AR→R 对账**：起测协议（clr+dma_en → cap_en）→ 注入 4 字 → `MIR_DMA_CNT==4` → `m_axi_read(0,len=0)` → **1 拍 + rlast + OKAY + 内容 == 手算锚 `{w3,w2,w1,w0}`**；再注入 16 字 → 4 拍突发**逐拍**对账（`M1-B-3d`×4）。期望值全部**手算锚**（注入 `w` ⇒ 环字 == w；行 = 4 bank）。
- **永远应答**：窗外读（0x4000）⇒ **整笔 SLVERR 且照常发满拍 + rlast，不挂**；窗内末行（row 1023）正对照 OKAY。
- **真 H2C 写**：`m_axi_write(len=2)` ⇒ AW/W/B 全握手、`bresp=OKAY`、`bid==awid`、从机内部丢弃计数 == 3。
- **`dma_en` 门**：关 ⇒ 计数器不涨且字留在 `level`（==2）；开 ⇒ 补给搬走（==2）且 `level` 归 0。
- 读数：**`PASS_ALL`，108 PASS / 0 FAIL**（前一轮 77 ⇒ **+31**，逐条核对编号与数量）。
- **两个突变臂**：
  - `run_tb_p6e_pcie_mut.bat`（期 A srcinv）：`MUTANT-CAUGHT`（24 FAIL；"注入路径死 ⇒ 环空"时**意外正证据**：未初始化环读**不挂**）。
  - `run_tb_p6e_pcie_mut2.bat`＋`mut_bwire.py`（**本轮新加**：环 `.src_data` 钉 0）：**恰好 5 条 FAIL = M1-B-2e + 3d×4**，其余全绿 ⇒ 内容判据**有自己的牙**且与计数器判据**独立**。

### 3.4 其余门

| 门 | 读数 |
|---|---|
| tb_mir_dma real / 3 突变 | `PASS_ALL(45)` / 全 `MUTANT-CAUGHT`（9/8/11 FAIL） |
| 镜像单元门 real / 2 突变 | `PASS_ALL` / 均被捉 |
| tb_biz_win / run_neg | `PASS_ALL 40 项` / `NEG_GATE_PASS 4/4` |
| check_window.py | `PASS=92 FAIL=0 INFO=1` |
| run_lint_p6e.bat | `LINT-OK`（xvlog+xelab 两面；编 ¬DP_156MHZ tie-off 支） |
| `-only p5_wrapper` | `GATE p5_wrapper EXIT=0`，RC=0 |
| 工具 `--selftest`（mingw 重编） | `MIR_SELFTEST PASS`（T1–T7 逐行原样） |
| （防御性）`PCIE_OBS ∧ ¬APP_MODE` elab | ⛔ 该组合 **HEAD 就编不过**（既存缺陷，§5-④） |

## 4. synth 检查点三臂表 + DP/新锥定向读（`_proj_10g/notes/p7b_m1p2b_synth/`）

同流程 synth-only（自建 prj，**绝不碰 `vivado_prj`**）：

| arm | NFILES | WNS | WHS | LUT | FF | BRAM tile | RAMB36E2 | DP 全局最差宿主 |
|---|---|---|---|---|---|---|---|---|
| pre（0x1E 树） | 440 | **0.000** | −0.661 | 82,525 | 78,454 | 350 | — | — |
| m1（阶段一） | 441 | **−0.377** | −0.661 | 83,456 | 78,806 | 350 | — | `u_tcp_tx/FSM_sequential_rx_state_reg[0]/C → u_app/stg_reg[0]/CE`（22 级） |
| m1p2（期 A） | 441 | **−0.377** | −0.661 | 83,504 | 78,814 | 350 | 319 | 同左 |
| **m1p2b（本轮）** | **444** | **−0.377** | **−0.661** | **83,490** | **79,011** | **354** | **323** | **同左（逐位）** |

- **WNS/WHS 与 m1/m1p2 三臂逐位同**；同对 pin 的 `pair` 查询 = `−0.377 / 22 级 / 6.527 ns`，**与 m1p2 逐位同** ⇒ 新逻辑**不在临界区**、未挪动 DP WNS。
- ⚠️ **WHS −0.661 四臂同值（pre 就有）** ⇒ 非本刀引入（synth 面 hold 估计性质）。
- 净差（vs m1p2）：**+197 FF / +4 RAMB36E2 / LUT −14**（+4 BRAM = 环 4 bank，与设计逐数吻合；URAM 0 / DSP 不变）。
- **DP 域最差 20 条**：全部同一既存族 `rx_state[0]/C → stg_reg[*]/CE`；`u_mir_ring/u_mir_c2h/u_mir_h2c` 与 `u_mir/` **0 命中**。
- **新锥定向**：ring `from 2.390`（1 级）/ `to 2.272`（3 级）；c2h `from/to 2.190`（5 级，内部）；**h2c `from 1.950`（6 级，`u_mir_h2c/w_done_reg/C → XDMA IP 内 m_axi_wstrb_ff_reg[15]/D`）** / `to 2.724`。
- **pcie 域面**（`pcie_axi_aclk`，Requirement **4.000 ns**）：域内最差 1.061 ns，**全在 XDMA IP 内部** ⇒ 新件所在域的墙不在本刀。
- ⚠️ 全部是 **pre-place synth 面**读数；真判据 = 构建轮的后布线构建（⛔ 不许写"时序已解决"）。

## 5. 未定项（含"真引擎发法仍未实测"，逐条）

① **真引擎的发法仍未实测**：替身按 F3 明文常量发（arid≡0 / arsize=4 / INCR / arcache=3）；**真 XDMA 引擎的发射形态（突发长度/顺序/回读节奏）只有明文常量级知识**。⇒ 读写通道容量/保证是"合同级"非"实测级"；**不影响"永远应答"结论**（从机对任何合法形态应答，且单元门覆盖顺序无关/长突发/背靠背）。
② **H2C 邮箱功能不在范围**（TL 明文）：从机只应答、无语义；主机侧无 `--h2c` 触发路径。
③ **`--dma` 真机路径本会话未跑**（无板）：身份门与环读去重/clobber 只有 selftest（mock）级证据；`lseek+read` 取法未现核（设计件 §V1.5-② 的"半可定"项）。
④ **既存缺陷（本轮新发现，登记不修）**：`PCIE_OBS ∧ ¬APP_MODE` 组合**在 HEAD 就编不过**（`udpapp_*` 声明在 `ifdef APP_MODE` 内、却在 PCIE_OBS 快照装配段被无条件引用 ⇒ 4 条 `VRFC 10-2989`；现役无任何构建/门产生该组合）。⇒ 本轮写进 ¬APP_MODE 支的 tie-off **只经文本检查、elab 面不可达**。
⑤ **`--selftest` 覆盖不到新身份门**（A_UNIMPL/0x14C 在真机路径）。
⑥ **全链未测"主机读 MIR_DATA 与排空器并发"**（仲裁由镜像单元门 G12f 覆盖；全链里两路从未同拍相遇）。
⑦ **环回绕覆盖（clobber）在全链未激励**（selftest T7 覆盖检测器；全链需把计数器推过 4096 字）。
⑧ **`nbeat` 会被综合优化掉**（无消费者）⇒ 板级无仪器证明"写从机真被用过"（本轮不加）。
⑨ **构建轮事项**：读侧脚本重生成 / BID bump / 位流 / 板上动作。
⑩ 本轮 p6e 门**不覆盖"真引擎并发读+写"**（替身单笔串行）。
⑪ **`run_tb_p6e_pcie_counters` 的 1 条 FAIL = 既存落后常量**（TB 期望 BID `0x1D`，树已是 `0x1E`；TB 与 BID 我都没动 ⇒ 派单 §10-14-2-3 已登记的"落后常量"），非本刀引入；其 W26–W31 判据全绿。

## 6. 过程教训（建议回灌全局）

1. **晚声明 = 硬错（又一次）**：`u_mir` 例化在三根新线声明之前 ⇒ `VRFC 10-2938`；去重后又撞 `10-9364 second declaration`。改连线的第一件事 = 新线声明放到第一个消费者之前。
2. **新判据第一版没牙是常态**：`mut_bearly` 逃过第一版全门（只判"WLAST 后有 B"）；补"WLAST **前**不许有 B"才捉住。p6e 门则用 `mut_bwire`（环数据钉 0）定向证明"内容 5 条红 / 计数器绿"= 两组判据互相独立。
3. **mingw g++ 静默失败形态**：缺 `C:\msys64\mingw64\bin` 于 PATH 时 `cc1plus.exe` 因 `libmpfr-6.dll` 失败但 **stderr 全空、RC=1**；修法已写进 `_build_tool.bat`（含 PATH 行 + 注释）。
4. （观测）xsim 日志里含中文的判据名有**既存编码损坏**（xsim→控制台 codepage；旧 log 同款）⇒ 判据结论只认 `[PASS]/[FAIL]` 与 `fails` 计数（`PASS_ALL`）。

## 7. 交付物清单（路径）

- 新件：`rtl/aximm_h2c_discard.v` · `tb/tb_aximm_h2c_discard.v` · `sim/p7b_h2cdisc/{run_tb_aximm_h2c_discard.bat, mut_h2cdisc.py}` · `sim/p6e_pcie/{mut_bwire.py, run_tb_p6e_pcie_mut2.bat}`
- 改件：`board/wrapper_p4.v`（+184/−29，9 个 hunk 全在预期位置）· `_proj_pcie/rtl/axi_regs.v` · `board/build_p7b_ku5p.tcl`（+3 导入）· `_proj_pcie/p7b_biz/p7b_mir_dump.cpp`（+12）· `sim/p6e_pcie/xdma_0_sim_stub.v` · `sim/p6e_pcie/tb_p6e_pcie_wrapper.v`（+122）· `_proj_10g/notes/p7b_biz_win/{tb_biz_win.v, check_window.py}`（neg 三突变已按新源重生成）
- 检查点：`_proj_10g/notes/p7b_m1p2b_synth/`（synth_stdout_m1p2b.txt / synth_m1p2b_{util,timing_summary,top200}.rpt / dp_worst / pcie_worst / pb_{ring,c2h,h2c}_{from,to} / pair / pb_query_stdout.txt）
- 证据：`_proj_10g/notes/p7b_m1p2b_impl_20261011/evidence/`（h2cdisc real+3 突变 · p6e real+2 突变 · mirdma/mirror/biz_win/run_neg/check_window/lint/p5_wrapper/counters · `mir_dump_{build,selftest}.txt` · `_build_tool.bat` · `_elab_pcieobs_noapp.bat`）
- ⛔ 未做：位流 / BID bump / 读侧脚本地图同步 / 任何板上动作。
