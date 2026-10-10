# `p5_wrapper` 既存红 = 定位报告（清单 **#8 / A7 节**）

> **一句话**：不是门的问题，是 **`board/wrapper_p4.v:2771-2775` 五个 `assign` 方向全写反** ——
> `ifndef DP_156MHZ` 的 TX 单域"别名"块把 `mac_tx_64` 的 `s_axis_tvalid` 与 `tx_arb` 的 `m_axis_tready`
> 变成**无驱动（Z）** ⇒ **该配置下 TX 全死**。引入点 = **`f08fc6a`（2026-09-29, P6b 顶层双域搬迁）**
> ⇒ 与登记"自 P6b 起就红"逐字吻合。
> ⚠️ **板配置（`DP_156MHZ=1`）走另一支（`:2768-2769` 写法正确）⇒ 静态推断不受影响；⛔ 未实测。**
> ⚠️ 本报告由 TL 代落盘（子 agent 的写文件请求被 harness 拒绝："Subagents should return findings as text"）；
> 正文按子 agent 的最终回复逐条整理，**未改一字事实**。全部原始证据在 `work/` 下。

---

## 0. 复现与冻结证据

**门解剖** —— `sim/p5sim/run_tb_p5_wrapper.bat`（sha256 `d9e906c3…04c1`）

| 项 | 内容 |
|---|---|
| 编译表 ① | `hls/slowstack_prj/solution1/syn/verilog/*.v`（**173 个**，bat:41-42 现场 `dir /b /s` 生成）+ 拷 `*.dat` |
| 编译表 ② | **27 个** `rtl/*.v`（bat:46-53：`crc32_8b fifo_sync checksum16 frame_fifo mac_rx_64 mac_tx_64 tcp_cam tcb tcp_rx tcp_tx_frame retx_ram tcp_echo axis_pipe rx_classify vlan_strip slow_rx_adp slow_cfg_adp slow_tx_adp udp_rx udp_split tx_arb udp_tx_cfg udp_tx_frame app_ctrl app_pattern app_udp_pattern app_status_uart`） |
| 编译表 ③④⑤ | `board/{wrapper_p4,util_gmii_to_rgmii,uart_dbg}.v` + `tb/tb_p5_wrapper.v` + `glbl.v` |
| **宏** | **只有 `-d APP_MODE`**（bat:44/45）⇒ `DP_156MHZ / PCIE_OBS / DEV_USP / P7B_10G / UDP_TX_OVL / TCP_TX_OVL` **全关** |
| 判据 | bat:62 `python tools/gen_stim_p5_app.py … checkwrapper`（`tools/gen_stim_p5_app.py:793`；`:843-845` `<2 帧` 即 FAIL；`:871-872` `return 1`） |
| 退出码 | bat 末行 = python 的退出码（**实测 1/0 两臂**） |

**红的形态（A 臂 = 原件 bat + 原件 TB，`work/A/A_stdout.txt`，EXIT=1）**

```
wrapper GMII: 0 帧 (conn0 数据 0 / 其它 0 / 坏 FCS 0)
MISMATCH: wrapper 只出了 0 个 conn0 数据帧 (<2) — APP_MODE 通路没通
P5 WRAPPER FAIL (1 项)
```

- `resp_p5_wrapper.memh` = **0 字节**；TB 自带 `$display`（`work/A/xsim_w.log`）：
  `P5W state st0=1 ready=0001 app(tx_bytes=1460 fr=1 bad=0)` / `P5W tx(frames=0 bytes=0) drop=0 fin=0 rst=0 eend=0 mac_abort=0`
- ⭐ `A_stdout.txt` 的 **md5 = `e042afb3ab402e547abfa83380868ff8`**，
  与 `sim/p7b_stagec_tx_regress/r2_log_p5_wrapper.txt` **`cmp` 逐字节相同**（= `P7B_STAGEC_TX_REGRESSION.md:254` 登记的那份）；
  `P5W` 四行与常驻 `sim/p5sim/xsim_w.log` **逐字相同** ⇒ **红复现、形态未变**。
- 探针臂 B/C/D 只加 `$display`，判据行与 A 完全一致。
- 副本证明：原件 sha256 `d9e906c3…04c1` = 复制件；补丁只有 2 处（`REPO_ROOT` 指向正本仓根、`SIM` 指向本目录），其余逐字节同（含 CRLF）。

---

## 1. 三分法

### ① 门侧 = 清白
- **不是哑门**（末行 python 退出码传播；红=1 / 绿=0 **实测**）。⚠️ 同族 `run_tb_p5_pattern.bat` **末两行只有 `findstr`、无 exit ⇒ 那才是哑门**。
- **不是空判据**：E 臂（只改 5 行）同判据 ⇒ `P5 WRAPPER OK`（3 帧）。
- `tcp_tx_frame.v` 宏组合 = **legacy 分支**（`TCP_TX_OVL` 关）⇒ **r6 `ack_seen` 门不参与**
  （`grep -n ack_seen rtl/tcp_tx_frame.v` 只有 `:42` 端口声明、`:504` 在 **OVL 分支内**）
  ⇒ "前科 `ack_seen` 悬空"**不是**本红原因；但说明**本门测不到板配置的那条门**。
- **门名 = 门实际编译的树？是活件**：A 臂 xvlog 路径全部 `…/udp_hls_10g/{rtl,board,tb}/…`（27/3/1 与表逐项对上），
  **不含 `ECO`、不含 `sim/*/mirror/`、不含 `sim/p4gates/evidence/negctl/foreign/`**；bat:10-19 的 `p4gate.py selfcheck` 六次运行全放行。
- 旁支弱点（与本红无关，登记）：bat:59 的 `multi/driv/unconnected` grep **只打印不判**（无 errorlevel）；本缺陷没触发任何 warn。

### ② wrapper 预置侧 = **根因**
- 宏走向：`DP_156MHZ` 未定义 ⇒ `:2770 else` ⇒ **`:2771-2775` 生效**；`P7B_10G` 未定义 ⇒ `:2807 mac_tx_64`；`APP_MODE` 定义 ⇒ `:1078-1256` app 通路 + `:1094-1104` `txin_*`。
- **逐字（`:2771-2775`）**：
  ```verilog
  assign txsrc_tdata  = m_tx_tdata;      // 2771
  assign txsrc_tkeep  = m_tx_tkeep;
  assign txsrc_tlast  = m_tx_tlast;
  assign txsrc_tvalid = m_tx_tvalid;     // 2774
  assign m_tx_tready  = txsrc_tready;    // 2775
  ```
  而 `tx_arb` 的 m_axis 输出在 **`txsrc_*`**（`:2745-2750`，`.m_axis_tready(txsrc_tready)` 是**输入**），
  `mac_tx_64` 的 s_axis 在 **`m_tx_*`**（`:2810-2814`，`.s_axis_tready(m_tx_tready)` 是**输出**）
  ⇒ **五行 rhs/lhs 全反**。**正确写法对照 = `:2768-2769`**（`assign txsrc_tready = ~tx_fifo_full; assign m_tx_tvalid = ~tx_fifo_empty;`）。
- **实测（D 臂，pc≥6500 起 42 次采样冻结）**：
  ```
  PROBEY pc=16500 nets(tx_tready=x txsrc_tready=z m_tx_tready=1 m_tx_tvalid=z txsrc_tvalid=1 tx_tvalid=1)
                 arb(mv=1 mr=z) mac(sv=z srdy=1 fwr=x fem=1 ful=0 wp=0 rp=0)
  ```
  `rtl/tx_arb.v:33` `s_fast_tready = busy && sel_fast && m_axis_tready` = `1&&1&&z` = **X**；
  `rtl/mac_tx_64.v:67` `fwr = s_axis_tvalid && s_axis_tready` = **x** ⇒ FIFO 零写入 ⇒ 永远 `S_IDLE`（`fem=1`）⇒ `e_txen` 0 ⇒ **0 帧**。
  `tcp_tx_frame`：一帧已收全（C 臂 `plen=1460 tlast_in=1 payw=183`），FSM 停在 **`sta=3` = `S_HDR`**（`:1249-1250`），`:2108` 的门遇 X 不成立；app 被反压顶死（`pipe mv=1 mr=0`、`pwv=1`、`bp_cyc=10161`）。
- **现核登记线索 `st0=1 / ready=0001` ⇒ "预置与注入正常"**：线索**对**（`dbg_c0_state=c_state[0]` `:390/:595`；`tx_ok=app_tx_ready[act_id]` `rtl/app_pattern.v:425`），但**不够** ——
  探针把"正常"扩到"整条收帧/装配通路正常"（pc=4652 起帧、pc=6479 收满 + tlast），**故障 100% 在交付口下游**；
  登记里缺的仪器正是这一段。
- **"端口悬空被钳 0"前科**：✅ **有，且就是根因**，形态更坏（**Z → X**）。
  **工具零提示**：`xvlog_w.log` / `xelab_w.log` 里 `m_tx_tvalid|txsrc_tready|m_tx_tready|txsrc_tdata` **0 命中**
  （2025.2 不报无驱动/多驱动网）。

### ③ TB 注入侧 = 清白
- 注入 = TCB/CAM 层次赋值预置（`:71-81`，非 force）+ `CONN_UP` = `force u_dut.u_app_ctrl.o_ev_up=1'b1` 一拍（`:85-87`）；
  `o_ev_up` 即 `wrapper_p4.v:1282 .o_ev_up(app_ev_up)`、进 `u_app`（`:1211`）⇒ **实测到达**（`act=1 aa=0`）。
- 覆盖边界（登记，非本红原因）：不驱动 `slow_cfg_adp` 真事件源 ⇒ **没测"CONN_UP 从哪来"**（坑 25 形态）。
- **坑 17（0 延迟竞争）形态：无**。TB 仅两块逻辑：捕获块 `:56-60`（`en_d` 非阻塞、只 `$fwrite`）与 initial（层次赋值 + force，均沿后顺序执行）。

---

## 2. 定案 + 证伪实验

**根因（一行）**：**`board/wrapper_p4.v:2771-2775`**（默认 / 非 `DP_156MHZ` 的 TX 单域别名块**方向全反** ⇒ TX 交付口空挂）。

**证伪实验（两臂，都已做）**

| 臂 | 做法 | 结果 |
|---|---|---|
| **E** | `board/wrapper_p4.v` 逐字节复制到 `work/E/wrapper_p4.v`，**仅这 5 行**改正确方向（`diff` = **恰好 2771-2775 五行**；271,392 → 271,396 B），`BD` 指向副本，其余全同 | **EXIT=0**：`wrapper GMII: 3 帧…` / `wrapper 图案: 3 帧 / 4380 B` / `P5 WRAPPER OK` / `P5W tx(frames=3 bytes=4380)` |
| **F** | 同一副本喂 **同族第二门** `sim/p5e_t2/run_tb_p5e_t2_wrapper.bat` | 从 `FAIL errs=117` → **EXIT=0**：`P5E-T2 WRAPPER: gnfr=2 udp=1 tcp=1 tcp_tx_fr=1 udp_tx_fr=1` / `P5E-T2 WRAPPER GATE: OK` |
| **A（反向对照）** | 原件 | 仍 **FAIL** |

⇒ **一处 5 行 = 两门转绿**。

**最小修法（只写，未改）**
```verilog
    assign m_tx_tdata   = txsrc_tdata;     // 2771
    assign m_tx_tkeep   = txsrc_tkeep;
    assign m_tx_tlast   = txsrc_tlast;
    assign m_tx_tvalid  = txsrc_tvalid;    // 2774
    assign txsrc_tready = m_tx_tready;     // 2775
```

**影响面（⚠️ 静态推断，未实测）**：所有 `ifndef DP_156MHZ` 构建；
现役板构建 `board/build_p7b_ku5p.tcl:153`（`DP_156MHZ=1`）**不受影响**；
`board/build_p5.tcl:65`（只 `APP_MODE=1`）**若被使用则 TX 是死的**。

---

## 3. 对 **#19** 的影响（一句话）

> **可登记，但必须先修 `board/wrapper_p4.v:2771-2775`；且登记文字必须写明它只覆盖非 `DP_156MHZ` 配置、不覆盖板配置**（`TCP_TX_OVL` 关 ⇒ r6 `ack_seen` 门不在其中）。

- 它是**真证据**（#19 前提现核成立）：矩阵 16 门（`run_matrix_p4dfix.bat:163-178`）里**无任何 p5 门**；
  `sim/p4gates/chain_src.f` **只有 19 个 rtl+TB，无 `wrapper_p4.v`、无 `app_pattern.v`**；
  而本门**恰好**编这两个活件，且 E/F 证明它对二者改动**敏感（有牙）**。
- 但门当前红 = **真缺陷** ⇒ 直接登记 = 把真红带进矩阵；顺序应是**先修 / 先裁定**。
- 它**不能顶替**板配置 wrapper 门（宏组合不同、编的是 legacy 分支）。

---

## 4. 未做到 / 未判定（不掩饰）

1. 第三个同族门 **`p5e_udp_wrapper`（登记 `errs=1489`）未重跑** —— 登记为"同根因强预测"（其失败行逐字含 `[FAIL] … TCP fast TX …（未到达 u_tx_arb）` / `[FAIL] …线上 GMII…没有 TCP…`），**非实测**。
2. **板级影响未测**（本轮禁碰板 / 禁 Vivado）；`DP_156MHZ=1` ⇒ **静态推断**不受影响。
3. E 臂 3 帧 vs TB:89 注释"抓 ~7 帧"的不匹配**未深究**（不影响结论）。
4. 未做 `ifndef DP_156MHZ` 下**其余悬空网的全 wrapper 普查**；未跑常驻矩阵。
5. ⚠️ 本轮**无**任何时序/综合/板级观测 ⇒ **不许推出"时序问题已解决"**；
   ⚠️ **"未观察到其它受害门" ≠ "不存在其它受害门"**。

---

## 5. 关键行号索引

`board/wrapper_p4.v:2771-2775`（**根因**）· `:2768-2769`（正确写法对照）· `:2745-2750` / `:2810-2814`（两端终点）·
`:390/:595`（`dbg_c0_state`）· `:1211`（`u_app`）· `:1282`（`o_ev_up`）·
`rtl/tx_arb.v:33` · `rtl/mac_tx_64.v:40,67` · `rtl/tcp_tx_frame.v:1249-1250,2108` · `rtl/app_pattern.v:425` ·
`sim/p5sim/run_tb_p5_wrapper.bat:44,45,54,59,60,62` · `tools/gen_stim_p5_app.py:793,843-845,871-872` ·
`tb/tb_p5_wrapper.v:56-60,71-81,85-87,89` · **git `f08fc6a`** · `sim/p4gates/run_matrix_p4dfix.bat:163-178` ·
`sim/p4gates/chain_src.f` · `board/build_p7b_ku5p.tcl:153` · `board/build_p5.tcl:65` ·
登记 = `P7B_REGRESSION.md:99,174`、`P7B_STAGEC_TX_REGRESSION.md:215,228,254`。

## 6. 证据落盘位置

`_proj_10g/notes/p7b_p5wrapper_diag_20261010/work/`：
`run_gate_copy.bat` + `A/`（原件复现：`A_stdout.txt` / `xsim_w.log` / `warn_w.txt`）·
`B/`（探针 1）· `C/`（探针 2：MAC 内部）· `D/`（探针 3：网线电平）·
`E/`（修好的 wrapper 副本 + 绿臂 `E_stdout.txt`）· `F/`（T2 门 + 同副本 + 绿臂 `F_stdout.txt`）·
`patch_*.py`（补丁脚本，带断言）。
**未改任何既有文件；`sim/p5sim/` 未被写入。**

---

## 7. 同族普查 / 同族第三门 / 仪器面（追加轮，2026-10-10）

⛔ **边界**：`board/wrapper_p4.v` 是构建 F 的被验源（`p7b_buildF_build/SRC_{PRE,POST}.sha256`），
**本轮一个字节都没动**（sha256 仍 `fe75b747…5d7d`）；一切实验只写在我自己的 `work/{G,H,L}/`。

### 7.1 任务 1-A：纯别名方向普查（机械 + 端口方向追到底）

工具 = `work/census2.py`（只读；自校验 **18/18** 条端口方向与源码逐字一致后才出表）。
命中 = `assign X = Y;` 纯别名（两侧都是单个标识符）；判定 = 追到**被例化模块的端口表**：
X 有 output 端口驱动且 Y 无任何驱动 ⇒ **反向**（不看名字，只看端口方向）。

| 配置 | 纯别名条数 | 正确 | **反向** | 未定 | 反向逐条 |
|---|---|---|---|---|---|
| **A** `APP_MODE`（本门实际配置） | **30** | 25 | **5** | 0 | `wrapper_p4.v:2771-2775` = `txsrc_tdata←m_tx_tdata` / `txsrc_tkeep←m_tx_tkeep` / `txsrc_tlast←m_tx_tlast` / `txsrc_tvalid←m_tx_tvalid` / `m_tx_tready←txsrc_tready` |
| **G** `APP_MODE+DP_156MHZ(=板那一支)` | **17** | **17** | **0** | 0 | 无 |

- 表内 6 条初版"未定"已**逐条查实并落到"正确"**（不是抹掉）：`txin_{tdata,tkeep,tlast,tid}←app2_*` 由 **拼接 LHS**
  `wrapper_p4.v:1093 assign {app2_tkeep,app2_tlast,app2_tdata,app2_tid} = app2_pack;` 驱动（`app2_pack←u_app_pipe.m_data` 端口输出）；
  `rx_upd_gnt←sel_rx`(:2028) / `fc_gnt←sel_fc`(:2043) 的右值来自**声明即驱动**的 `wire sel_rx = …`(:2027) / `wire sel_fc = …`(:2035)。
- ⇒ **同族普查结论（配置 A）**：反向别名**恰好 5 条，就是已知根因**；**无第二个同族**。
  ⇒ **配置 G（板那一支）**：**0 条反向**（`ifndef DP_156MHZ` 块不参与编译，改由 `fifo_async` 的 `dout` 驱动 `m_tx_*`、
  由 `:2768-2769` 的两条 `assign` 驱动 `txsrc_tready`/`m_tx_tvalid`）。

### 7.2 任务 1-B：实证 Z 扫描（xsim Tcl 穷举；比人眼可靠）

工具 = `get_objects`/`get_value`（xsim Tcl）。**三处自证**：
① 正控 = 直读 `txsrc_tready`/`m_tx_tvalid` 返回 `Z`（与 D 臂网线电平一致）；
② ⚠️ **第一版扫描器自己是个哑门**：`string match "*z*"` 对 `Z` **大小写不敏感为假** ⇒ 全表 hits=0 的"干净"是假的（就地修）；
③ 每次报 `addr=N`（可寻址对象数）+ 采样点。

| 采样点 | 配置 A（`APP_MODE`） | 配置 G（`APP_MODE+DP_156MHZ+PCIE_OBS`） |
|---|---|---|
| 预置前 (t=4000ns) | addr=553, **hits=59** | addr=667, **hits=63** |
| 帧中 (t=40000ns) | addr=553, hits=59 | addr=667, hits=63 |
| 卡死 (t=60000ns) | addr=553, **hits=58** | addr=667, **hits=58** |

**逐条分类（A 配置）**：
- **Z 类（真无驱动）= 恰好 5 条**：`txsrc_tready` · `m_tx_tdata` · `m_tx_tkeep` · `m_tx_tvalid` · `m_tx_tlast`
  （三者全采样点恒定）+ 它们在子模块里的**同一根网的端口投影**（`u_tx_arb/m_axis_tready`、`u_mac_tx/s_axis_*`、`u_mac_tx/fdin`）。
  ⭐ **与 7.1 的 5 条反向别名 1:1 对上 ⇒ 静态普查与实证扫描互证。**
- **X 类（真被驱动，只是值未知）= 53 条**：`rxsrc_*`/`rx_*`/`f_*`/`s_*`/`srx_*`/`stx_tkeep,tlast`/`mrg_*`/`utx_*`/`app_udp_tx_*`
  /`eco2_pack`/`cam_q_*`/`hls_rx_tdata` 等 —— **在 t=4000ns（预置前）就已经是 X**、三点恒定、
  且全在**本 TB 不激励的通路**（RX/HLS/DMA/UDP-app，其寄存器无复位）；**不是 Z、不是新缺陷**。
  另 `tx_tready = X` **只在卡死点出现**（= `busy && sel_fast && Z` 的两个传播投影，见 §2-②）。
- **G 配置**：唯一的 Z = `pcie_sys_clk_p/n`、`pcie_rxp/rxn` = **本 TB 未连接的 wrapper 输入端口**（PCIe 通路本 TB 不用 ⇒ 良性）；
  `txsrc_tready` **不再出现**、`m_tx_*` 由 Z 变 X（被 `fifo_async` 驱动，值未知而已）⇒ **板那一支没有同族 Z**。

### 7.3 任务 1-C：**板那一支的功能正控（新做，比预测强）**

`work/G/`（bat 副本 = A 的文件表 **+ `fifo_async.v`/`clk_gen_p6b.v`/`snap_cdc.v`/`snap_seq.v`/`axi_regs.v`/`xdma_0_sim_stub.v`**，
宏 = `-d APP_MODE -d DP_156MHZ -d PCIE_OBS -d P6B_SIM_CLKGEN`；TB 副本 `tb_dp.v` **补驱动 `sys_clk_p/n`**）
⇒ **用未修的活 wrapper**跑同一条门：**EXIT=0 / `P5 WRAPPER OK` / `wrapper GMII: 6 帧` / `tx(frames=7 bytes=10220)`**。
⇒ 两条结论：① 活 wrapper **不是整体坏的**，坏的就是 `ifndef DP_156MHZ` 那 5 行；② **本门之所以红，只因为它编的是非 DP 配置**。
⚠️ 同批发现（登记）：① 本门的文件表**编不出 DP 支**（`grep -c fifo_async|clk_gen_p6b` = **0**）—— DP 支还必须同时开 `PCIE_OBS`
（`sys_clk_p/n` 两个端口声明在 `ifdef PCIE_OBS` 内，`wrapper_p4.v:187-211`）；② `DP_156MHZ` **不带 `PCIE_OBS`** 时
`clk_gen_p6b` 的 `.clk_p(sys_clk_p)` 会落到**隐式 1 位网**（该组合本仓无构建使用，未修、未复现）。

### 7.4 任务 2：家族第三门 `p5e_udp_wrapper`（**已实测转绿**）

`work/H/` = `sim/p5e_udp/run_tb_p5e_udp_wrapper.bat` 的副本 + **E 臂那份修好的 wrapper 副本**（只改 `REPO_ROOT`/`BD`）：
- 登记红：`P5E-T5 UDP WRAPPER GATE: FAIL errs=1489`
- 本轮（同一份 5 行修复）：**`EXIT=0` · `P5E-T5 UDP WRAPPER: gnfr=20 udp=13 tcp=7 tcp_tx_fr=7 udp_tx_fr=13` · `P5E-T5 UDP WRAPPER GATE: OK`**
⇒ **三门同根因 = 已实测**（不是"强预测"）：`p5_wrapper`(E) · `p5e_t2_wrapper`(F) · `p5e_udp_wrapper`(H)，**一处 5 行修复，三门全绿**。

### 7.5 任务 3：仪器面（key 清单 + 判定 + 候选）

**现役两处 lint 入口的 key（逐字抄）**：
- `board/run_lint_p6e.bat:26,39`（xvlog 面 / xelab 面各一遍，OR 语义，5 键）：
  `Synth 8-11241` · `undeclared symbol` · `VRFC 10-3091] actual bit length 1 differs from formal bit length` · `VRFC 10-2989` · `implicitly declared`
  ；`:27` 另有一条**裸** `findstr /C:"10-3091"`；`:28` `findstr /I /C:"ERROR"`（xvlog 日志）；`:38` `Built simulation snapshot`（活性正证据，不是内容判据）。
- `_proj_10g/tcl/run_lint_p7a.bat:45,58`：与上**同一组 5 键**（xvlog.txt / xelab.txt 各一遍）+ `:46` 裸 `10-3091` + `:47` `ERROR` + `:57` `Built simulation snapshot`。

**判定：没有一个 key 能抓住"无驱动 / 方向写反"**（逐条理由）：
`8-11241`/`undeclared symbol`=未声明符号（隐式网，坑 24）；`10-3091] actual bit length 1…`=端口位宽截断；
`10-2989`=表达式未声明；`implicitly declared`=2025.2 恒 0 的死键；裸 `10-3091`=同族 + 已知假阳性（`util_gmii_to_rgmii.v` 14 处）；
`ERROR`(xvlog)=本缺陷**一条都不打印**（§2-④ 实测 0 命中）。

⭐ **负对照（本轮实跑，我目录里的 `board/run_lint_p6e.bat` 副本）**：该 lint 的宏是
`-d PCIE_OBS -d DEV_USP -d APP_MODE`（**无 `DP_156MHZ`**）⇒ 它**恰好编的就是坏分支**并 `xelab xil_defaultlib.wrapper_p4`，
结果是 **`---- xvlog exit=0 ----` / `LINT-OK: no implicit nets, no width mismatch, no errors` / EXIT=0**
⇒ **"现役 lint 看得见坏分支而全绿"是实测的**（不是推断）。
（同批读到的 xelab 日志 21 条 warning **全是 `VRFC 10-3645 remains unconnected`** = 未用**端口**，与本缺陷的"网无驱动"**是不同失效形态**；
xvlog 面 213×`10-2263` + 220×`10-311` 是 INFO，1×`10-3609 overwriting previous definition of module 'udp_echo'` = 既存的 rtl/HLS 同名次序事实。）

**最小可行判据候选（只给候选 + 假阳性，不实施）**：
1. ⭐ **Z 扫描门（已在本轮跑通，工具现成）**：elaborate 顶层 → 跑到一个里程碑 → `get_objects <dut scope>/*` 逐个 `get_value`，
   凡值含 `z` 即判红（**须 `string tolower`**，见 7.2-②；`x` 要单列——它可能是"被驱动但未知"）。
   假阳性实测：A 配置 **0 条**（除那 5 条真缺陷外，wrapper 作用域无其它 Z）；G 配置 **4 条** = TB 未接的 PCIe 输入端口 ⇒ 需一张
   **"TB 未驱动输入端口"白名单**（或只扫 `wire` 型网并显式排除顶层 input）。成本 ≈ 一次已有快照上的 xsim + 十几秒。
2. **静态别名方向门（`census2.py` 同款）**：抽 `assign X = Y;`，用**被例化模块端口表**判 X/Y 谁该驱动谁；反向/悬空即红。
   假阳性实测：A/G 两配置**各 0**（30/30 与 17/17 判定完备，且 5 条反向与实证 Z 1:1 对上）。成本 ≈ 2 秒、不要仿真器。
   ⚠️ 只覆盖**纯别名**形态（非别名形态需扩到"输入端口挂着无驱动网"的浮空表，那张表本轮仍有 **194/198 条残留**，
   绝大多数是**非活分支的声明**与 **localparam** ⇒ 用之前必须先加白名单）。
3. ⛔ **`VRFC 10-3645`/`remains unconnected` 收紧**（本仓曾议）：**对本族无效** —— 它报的是"端口未连"，
   而本缺陷是"**网无驱动**"（端口连了、网没驱动）⇒ 收紧它抓不到本缺陷，且干净件已实测 **21 条**。
4. **综合面 key（未验证候选）**：需跑 `synth_design` 才能找"无驱动网"类签名；⚠️ 且**板构建（`DP_156MHZ=1`）根本不综合坏分支**
   ⇒ 真缺口是**臂覆盖**（没有一条构建/lint 编非 DP 支），不是 key。**本轮无 Vivado ⇒ 未验证，不许当结论。**

### 7.6 追加轮的未做到 / 未判定

1. **FPGA/综合/lint 的其余入口**未普查（只读了题面指定的两处 + 顺带读了 `sim/p6b_lint/lint.bat`、`sim/p5wu_p1p2/run_xvlog_wrapper63.bat`；
   ⚠️ 后者是**单文件 xvlog**（`xvlog … wrapper_p4.v` 单文件、无模块上下文）⇒ 结构上**看不见**无驱动网；且它带
   指纹销 `findstr /C:"SNAP_NW_P6E = 70"`，与现役源码 `:3228 localparam SNAP_NW_P6E = 70;` **一致**（我核过，未跑）。
2. **综合面候选 key 未验证**（禁 Vivado）；`DP_156MHZ && !PCIE_OBS` 那条隐式网**未复现**（登记为主）。
3. Z 扫描**只覆盖 wrapper 作用域 + 9 个子模块**（未全设计穷举；`u_dut/*/*` 通配返回 0，多级需逐层显式写）。
4. ⚠️ 本轮同样**无时序/板级**观测；**"没扫到别的 Z" ≠ "设计里没有别的无驱动网"**（只覆盖两种宏组合 + 本 TB 的激励）。

