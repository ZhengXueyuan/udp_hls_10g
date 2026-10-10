# P7B-PERSIST 实施件（`fd671b6` + 收口 `cc3894d`）—— **静态面**对抗审查

> 角色：实施件对抗审查 agent（persist 刀）。**本轮 = 只读静态面**。
> 方法：只读 git / RTL / TB / 门 / 日志；**零 xsim、零 Vivado、零板卡、零 JTAG、零 ssh**（构建 agent 正在跑 Vivado，#47 前科）。
> 基线：设计件 = `_proj_10g/notes/P7B_PERSIST_DESIGN.md` **v3**（cfd3b1a 提交）· 实施 = **`fd671b6`**（+ 收口 `cc3894d`）· 其后的 GHOST/RETXHI-GHOST 刀（`11ad9ec`…`8f8a727`）已在同一文件里（交互面见 §2/§3）。
> ⛔ 本件**不下 PASS/FAIL 裁定**；不写"时序已解决"；不把"未观测到"写成"不存在"；**核到与派单描述不符就如实说**（见 §0）。
> 行号纪律：本件全部行号 = **2026-10-11 现读工作树**，逐条抄了行内容（`rtl/tcp_tx_frame.v` 现盘 = 172,494 B / 2578 行 / 纯 CRLF，禁按 `\n` 锚点）。
> ⚠️ 工作树现态：构建 agent 已把 `board/wrapper_p4.v` 改为 `.PERSIST_EN(1'b0)` + `BUILD_ID_V 0x1C`（**未提交**，见 `git status` 的 ` M board/wrapper_p4.v`）——本件对 wrapper 的评审以**提交态**（HEAD：`1'b1` / `0x1B`）为准，工作树偏离处单独标注。

---

## §0 先列：与派单描述**不符**处（本件据此改写法）

| # | 派单说法 | 现核 | 证据 |
|---|---|---|---|
| 0-1 | "设计件 v3 的落点清单（含"实施时必须现核定"的 **V1–V6** 清单）" | ⛔ **`P7B_PERSIST_DESIGN.md` v3 里没有 V1–V6**（全文 grep 0 命中；它的落点清单 = §2.5 的 13 行表 ①–⑬）。**V1–V6 在 `P7B_RETXHI_GHOST_DESIGN.md` §9.5**（"实施时必须现核定"逐字出处 = 该件 `:28` / `:845` / `:999`），属**重放越界（GHOST）刀**的设计件，其实施轮 = `11ad9ec` 一线，**不是 `fd671b6`**。⇒ 本件按"两把刀的落点分别对账"写（§1 表 + §1.5），并在 §1.5 给 V1–V6 现盘可静态判的读数。 | `grep -n "V1\|V6" P7B_PERSIST_DESIGN.md` = 0；ghost 设计件 `:845` 逐字 "### 9.5 ⭐⭐ "实施时必须现核定"清单…V1…V6" |
| 0-2 | "两分支（OVL/else）是否**都有**对应编辑" | **对 persist 刀 = 不适用（设计规定"不镜像"）**：§7.1 明写"双支约定 = 不镜像"。现核：else 支（`:1554`–`:2575`）里 persist 标识符 **0 命中**（`probe_sel`/`ps_*`/`ds_guard`/`ctrl_pld`/`PERSIST_EN` 全 0）⇒ 与设计一致。**对 ghost 刀 = 双支都有**（`whi_r`/`ring_hi`/`ring_restore` 在 else 支 `:1594/:1595/:1690/:1839-1845/:2129/:2142/:2150/:2239` 等在位）。 | ifdef TCP_TX_OVL @ `:303`，else @ `:1554`，endif @ `:2576`；分段 grep |
| 0-3 | 派单历史记录引 `fd671b6` 的"门的 S 臂是坏的（`rerun4_stdout.txt`…）" | ⛔ **该条已被 `cc3894d` 撤回**（逐字："我上轮判『门自己的 S 臂根本没跑起来』【不成立】…`rerun4_stdout.txt` 是 agent 自己的助手脚本…我量错了对象"）。现核：门的 `:run` 子程序用**绝对路径** `"%RTL%\tcp_tx_frame.v"`（现读 `run_tx_ovl_gate.bat` 的 `call :run S …` 一行），全量门日志里 S/T 臂都有真读数块。⇒ "S 臂编译坏"**不是**现存问题；现存问题 = **S 臂真读数红**（见 §2-P3）。 | `git show cc3894d` 提交信息；`run_tx_ovl_gate.bat` `call :run S "%RTL%\tcp_tx_frame.v" …` |
| 0-4 | 实施件自称"**12 处**落点" | 设计 §2.5 是 **13 行编号**（①–⑬，另含子行 ⑤b），另加 §2.4-4 的**三条陈旧 `ackq_dout` 门**（①`upd_wr_ctrl`/②`ctrl_is`/③`ctrl_ack_now`）**不在 13 行表里**。现核 = **13 行全落地 + 三条门全落地**（其中 `ctrl_ack_now` 首版漏做、被静态脚本 FB 抓出后补上——该事实写在第 `:1310` 附近的 RTL 注释里）。"12" 是计数口径差，不是漏项。 | 见 §1 表 |

---

## §1 落点对账：设计 v3 §2.5（13 行） + §2.4-4（3 条） × `fd671b6` 实际 diff

**总判**：13 行 + 3 条**全部在**；**无未登记的漏项**；**3 处"与设计字面不符"**（全部有代码注释/提交信息登记，且我逐条复核过其理由成立与否）——逐条如下。

| 设计行 | 设计要求 | 实际落点（现读） | 对账 |
|---|---|---|---|
| ① | 宏外参数 `PERSIST_EN/PS_BASE/PS_MAX` | `:299-301`（在 ifdef TCP_TX_OVL@`:303` **之前**）`parameter PERSIST_EN = 1'b0;` / `26'd3_051_758` / `26'd36_621_094` | ✅ 逐字一致（含默认 0） |
| ② | reg 区 + 复位 + cfg_up | regs `:448-460`；复位 `:1020`（`tx_is_probe`）/`:1055-1058`（`ctrl_probe/ctrl_pld/ps_stage_*/ps_rd_d1/d2`）/`:1072-1073`（`ps_timer/ps_phase` for 循环）；cfg_up `:1089-1091` | ✅（行号漂移；cfg_up 一处例外见 §2-P1） |
| ③ | 扫描块 persist 计时段（`ds_guard`+`probe_sel` 落"此段末"） | 计时段 `:1255-1276`；**`ds_guard`/`probe_sel` 实际落在 `:607-612`**（`start_ack` 之前） | ⚠️ **位置偏离、语义相同**：`wire` 不能写在 `always` 内 + xvlog 先声明后用（`:579-581` 注释自证）⇒ 可接受（登记在注释里）。**这一挪动还改变了 `upd_wr_ctrl`/`ctrl_ack_now`/`rb_id` 的 `+` 行相对次序（= 静态 L1 的 hunk 分组形态），不影响语义** |
| ④ | `u_retx` 前三根线改 mux | `:957-959`：`rd_en_m = rd_tap \|\| ps_rd;` / `r_conn_m = ps_rd ? scan_id : retx_id_r;` / `r_seq_m = ps_rd ? rb_snd_una[15:0] : r_tap_seq;` | ✅ 逐字 |
| ⑤ | `start_ack` 新增探询支 | `:618-619`：`wire start_ack = rx_idle && !rx_flush && !ctrl_slot_busy && ((ack_pend_r && !ackq_empty) \|\| probe_sel);` | ✅ 逐字 |
| ⑤b | `rb_id` mux arm 插在 `scan_now` 之后、`start_id` 之前 | `:663-665`：`assign rb_id = svc ? svc_id : ring_eval ? retx_id_r : scan_now ? scan_id : probe_sel ? ps_stage_conn : (rx_state == RX_IDLE) ? start_id : f_conn[rx_bank];` | ✅ 逐字（`probe_sel` 定义里 `!svc/!ring_eval/!scan_now` 全在 ⇒ "同生共死"两半齐） |
| ⑥ | 槽装载 5 处探询改写 | `:1300-1304`（`ctrl_is=3'b000`/`ctrl_seq=rb_snd_una`/`ctrl_doff=16'h5018`）+ `:1319-1321`（`ctrl_pld`/`ctrl_probe`/`ps_stage_rdy<=0`） | ⚠️ **`ctrl_pld` 加了 `probe_sel` 门控**（`:1319`），设计字面写的是无门控 —— **设计的字面是错的**（陈旧载荷字节会污染其后每个控制帧的 TCP 校验和；门实测 `REDS csum=206`），实现偏离字面、= 修设计的错；注释登记在 `:1310-1318`。**其余 4 处逐字** |
| ⑦ | 三处长度（41/41/21）+ 载荷项 + `ctrl_probe` flavor | `:881`（`ctl_aen_v1 = (ctrl_probe ? 18'd21 : 18'd20) + …`）· `:894`（`ctrl_acc = … + {16'b0, ctrl_pld, 8'h00}`）· `:900`（`ip_csum_calc(ctrl_probe ? 16'd41 : 16'd40, …)`）· 装载仍走 `start_ack_d1`（`:1128-1131`） | ✅ 逐字（三处同步；线上被 TB 独立复算证过：S 臂 `csum=0`） |
| ⑧ | `h_totlen` 41 + `tx_is_probe` 帧入口四点 | `:909`；四点 = `:1406`（T_IDLE ctrl 支）/`:1410`（bank 支清 0）/`:1528`（T_DONE 边界 ctrl 支）/`:1532`（bank 支清 0）；`tx_state <= T_HDR` 全文件**恰这 4 处** | ✅ 逐字（grep `T_HDR;` = `:1403/:1409/:1527/:1531` 四行，与四点 1:1） |
| ⑨ | `T_PAY` 零长支加探询支（select = `h_ctrl && tx_is_probe`） | `:1437`：`if (h_ctrl && tx_is_probe) begin`（末字 `{hold48, ctrl_pld, 8'h00}` / `tkeep 8'hFE`；else 支一字不动） | ✅ 逐字 |
| ⑩ | wrapper `.PERSIST_EN(1'b1)`（不包 ifdef）+ BID 自增 | HEAD `:2150`（ifdef 深度 0：最近宏块 `:2112-2126` 已闭）+ `:4058` `0x1A→0x1B` | ✅（工作树现态 `1'b0`/`0x1C` = 构建 agent 在飞改动，未提交） |
| ⑪ | TB `ifdef ARM_PERSIST` 判据组 + 门 S/T 臂 | TB：`PE_*` 状态/判据 `:339-449`、激励钩子 `:300`、E1–E7 episode FSM `:1285`+、判据合流 `:2599-2750`；门：S/T 臂在 `run_tx_ovl_gate.bat`（含 U/V/W 变异臂 + X/Y/Z ghost 臂） | ✅（**多了** U/V/W 变异臂与 X/Y/Z ghost 臂；设计只点名"j11 的变异/负对照"，臂化是补强） |
| ⑫ | 静态核对脚本 | `static_check_persist.py`（402 行；S1/FB/L1/PD + `--selfcheck`）+ `run_static_persist.bat`（+ 冻锚 `frozen/tcp_tx_frame_revcfd3b1a.v`） | ✅ 在位；**但 L1 两腿的落盘证据是空判据**（§2-P5），且 **S2 的 fc/b 等价门未建**（§2-P6） |
| ⑬ | 文档面（清位全集表落成注释） | `:1242-1254`（扫描段）+ `:1133-1143`（捕获块）注释 | ⚠️ 在；但 `:1140-1143` 的"清位路径赢"对 **cfg_up 一条是反的**（§2-P1） |
| §2.4-4① | `upd_wr_ctrl` 加 `&& !probe_sel` | `:637` | ✅ 逐字 |
| §2.4-4② | `ctrl_is <= probe_sel ? 3'b000 : …` | `:1300` | ✅ 逐字 |
| §2.4-4③ | `ctrl_ack_now` 三条门之三 | `:871`：`(probe_sel \|\| aq_fin \|\| aq_rst) ? rb_rcv_nxt : ackq_dout[31:0];` | ✅（首版漏做→补齐；`:1310-1318` 注释 + `cc3894d` 提交信息登记） |

### §1.5 V1–V6（**属 ghost 刀**；现盘可静态判的部分）

| # | 项 | 现盘静态读数 |
|---|---|---|
| V1 | `e_ghost`/`e_ringhi` 插桩 + 进 `tot_red` | **在**：`tot_red = … + e_ghost + e_ringhi;`（`tb/tb_tcp_tx_ovl.v:2419-2425`）；有牙证据 = 门 X 臂（`mut_ghost_m3`）现盘 `REDS … ghost=25`、`reds=30` |
| V2 | `e_ringhi` 豁免写法 | 有牙证据 = 门 Z 臂（`mut_ghost_noclamp`）现盘 `ringhi=2`、`reds=30302` |
| V3 | (b) 的 seq-hole 新红是否为 0 | 现盘：**S 臂 `seqcont=0`**；**T 臂 `seqcont=13`**（已由 TB `:2685-2693` 登记为 cfg_up 清位联合效应） |
| V4 | `e_j9` 期限 vs 跑长 | 现盘 `REDS2 … J9=0`（`runS/xs.log` 与 `runT/xs.log` 逐字） |
| V5 | TB `cfg_up`/`scfg` 顺序 | 未在本轮复核（ghost 线自己的现核项，见 `p7b_retxhi_impl_review_20261010/FINDINGS.md`） |
| V6 | `whi_r` 层次路径名（OVL 支 `u_dut.whi_r[…]`） | **在**：TB `:805/:806/:812/:818` 等用 `u_dut.whi_r[t_conn]`；RTL OVL 支声明 `:491`（else 支 `:1594` 另有一份）⇒ 路径名成立（门编译 0 错误、无 `not declared under prefix`） |

---

## §2 真问题清单（按严重度；逐条带证据 = 文件:行 + 行内容）

### P-1【中】`cfg_up` 清位与 T+2 捕获的**先后顺序**：代码注释与代码相反；设计 §3.4b / j10 **未登记该窗**；TB 的 E4 构造**结构性不覆盖**

- **事实（程序序）**：同一 `always` 非复位支内，`cfg_up` 块在**前**、`ps_rd_d2` 捕获块在**后** ⇒ 同拍冲突时 **捕获赢**：
  - `:1077` `if (cfg_up) begin` … `:1091` `if (ps_stage_conn == cfg_up_id) ps_stage_rdy <= 1'b0;`
  - `:1144-1149` `ps_rd_d1 <= ps_rd; ps_rd_d2 <= ps_rd_d1; if (ps_rd_d2) begin ps_stage_byte <= ring_d[63:56]; ps_stage_rdy <= 1'b1; end`
- **代码注释与之相反**：`:1140-1143` 逐字——"⚠️ 本块放在两个 `case` **之外** …，且**在 `cfg_up` 块**之后** ⇒ 同拍写冲突时 **清位路径赢**（§3.4b 清位全集表: cfg_up / 解除武装 / 槽消费三条清位都比"同拍新捕获"更具体 …）"。⇒ 对 **cfg_up 这条**该句为**假**（对"解除武装/槽消费"两条为真：它们在 `rx_state` case 内、位置更后）。
- **可达窗（结构性、未实测）**：fire 拍 = T（`:757` `wire ps_fire = ps_arm && (ps_timer[scan_id] == 26'd1);`；`ps_rd = ps_fire` `:758`；T 拍锁 conn/estab/seq `:1271-1275`；T+2 捕获 `:1146`）。若**同槽** `cfg_up` 落在 **T 或 T+1**：`ps_stage_conn/estab/seq` 按设计**不清**（§3.4b"不清值"列 ✓ 实现一致）、`ps_rd_d1/d2` **也不清**（cfg_up 块未列它们）⇒ T+2 仍写 `rdy<=1`，且 `ps_stage_conn == k`（同槽）⇒ **清不掉**。
- **后果（≤1 条）**：其后一条探询可用**旧会话读出的字节** + **新会话的实时 `rb_*`**（槽装载 `:1300-1304` 取实时 `rb_snd_una/rb_rcv_nxt/rb_rcv_wnd`；`ps_stage_estab` = 旧值 1，`probe_sel` 无"当前态"检查）⇒ 最坏 = 新会话窗未关也发 1 条"旧数据段"，字节可能不是该 seq 的正确图案字节。违反 §5.2-j10 的期望口径（"待发期间 `cfg_up` ⇒ 0"），且**设计 §3.4b/j10 一个字都没登记该窗**。
- **TB 为什么不覆盖**：E4 的 cfg_up **等在 `u_dut.ps_stage_rdy` 之后**才打：`:1552-1554` `if (u_dut.ps_stage_rdy) begin cfg_up <= 1'b1; cfg_up_id <= 4'd1; …` ⇒ cfg_up 只落在**捕获完成之后**，`[T, T+1]` 的窗口**从未被激励**。
- **判定口径**：这是"实现与设计字面表一致、但与设计 **j10 意图/实现注释**不一致"的一格；**未实测可达性与危害**（窗口 = 同槽 cfg_up 恰落在 fire 后 ≤2 拍）。⇒ 建议：要么把捕获块挪到 cfg_up 块之前（让注释成真），要么在 §3.4b 明确登记"cfg_up 不覆盖在飞捕获"的残留。

### P-2【中】W 臂（`H2(b)`，"摘掉 `ds_guard` ⇒ 必红"）的**证据形态**：现行红集合里**没有一条是撞车破坏的见证**；`e_coll_bad` **从未发火**；且 witness 与 destruction 两代读数互相矛盾

- **门契约层**：W 臂（`mut_ps_nodsg` = 逐字删 `&& ds_guard`，我现读 mut 与 RTL 的 diff 确认**单行单点**）**RC=1 ✓**——但这是"非零"层，不是"特定红"层。
- **现行 W 红集合（`author_gate/runW/xs.log`）**：`reds=6` = `payload conn=0 @264351` + `RETXFIX jump @349992` + `PS j9` + `PS j6`（**这 4 条与干净臂 S 同款**）+ **W 专属 2 条** = `[FAIL] PS j10: cfg_up 后仍出现探询 =1` + `[FAIL] PS j13 空判据: 相撞条件从未成立 (wit=0)`。
- **撞车专用仪器全哑**：现行 W `PS3 EP probes … E7wit=0`、`PS4 WIT … coll=0`（`runW/xs.log`）。对照 S 臂：`E7wit=2`、`coll=0`。⇒ `e_coll_bad`（TB `:859-860` `if (((pe_st == 7'd51) \|\| (pe_st == 7'd52)) && !is_probe && (t_conn != 4'd0)) e_coll_bad = e_coll_bad + 1;`）**在两代 W 跑里一次都没红**——W 的 j13 红**全部由 `:2746-2747` 的"空判据"子句**（`if (pe_f_e7_wit < 1) tot_red+1`）承担。
- **⭐⭐ 现行机制已由 E7 逐拍 DBG 直接读出（2026-10-11 审查轮新增，D-1 读数）**：
  - `runS/xs.log`（干净臂）E7 观察窗 15 拍逐字：`t=0 rdy=1 blk=1 coll=0` → `t=1 rdy=1 blk=0 coll=1` → `t=2..14 recv_first=0`（数据帧已在收）⇒ **`ds_guard` 恰在"数据帧即将启动"的唯一一拍把探询压住**（coll=1 那一拍即撞车条件成立拍），此后 `rx_idle=0` ⇒ 探询结构性不可能发。⇒ **守卫按设计工作、见证仪器看到了那一拍**。
  - `runW/xs.log`（删 ds_guard）同窗逐字：`t=0 rdy=1 blk=1 coll=0` → **`t=1 rdy=0 busy=1`**（暂存已被消费、控制槽在飞）→ `t=2..14 rdy=0 busy=1→0`。
  - ⇒ **机制（现读证据级，非推断）**：删掉 `ds_guard` 后，探询在 **t=0（释放前那一拍）**就发掉了 —— 那一拍 `recv_first=1 ∧ s_axis_tvalid=1 ∧ wnd_open=1`（源持续呈交 + conn0 窗开）⇒ `ds_guard=0`，而 `tx_blk_sid`（E7 的 hold）**还没放开** ⇒ 数据帧那一刻**开不了** ⇒ 探询抢先消费暂存；到 t=1（门放开）暂存已空 ⇒ **`start_data=1 ∧ probe_sel=1` 同拍从未发生** ⇒ **跨连接错帧从未发生**（`e_coll_bad=0` 是如实读数，不是仪器哑）。且 `psc_coll` 的定义要求 `!tx_blk_sid` ⇒ 它**看不到 t=0 那一拍** ⇒ 见证计数=0。
  - ⇒ **修正对 W 臂的判读**：现行构造下"删 `ds_guard`"的**行为后果 = 探询早一拍发**（+ 早先的 j10 红），**不是**撞车破坏；"必红"只在 RC 层成立，且**撞车破坏在当前构造下结构性不可达**（因为 `ds_guard` 是超集：它连"门将被放开但还没放开"的拍也挡，删掉后探询在那些拍就跑了）。
- **两代读数自相矛盾（最贵的一条）**：`fd671b6` 代的 W 跑**确实**打出破坏签名——`_proj_10g/notes/p7b_persist_impl/gate_full_stdout.txt:470-471` 逐字 `[FAIL] seq_mono rev conn=0 val=000466e8 was=000ca92b una=000ca337 @280775` / `[FAIL] seq below una conn=0 val=000466e8 una=000ca337 @280775`（+ `payload=5` / `seqmono=24`），而**同一跑**的 `ev/xs_runW.log` 里 `PS3 … E7wit=0`、`PS4 … coll=0` ⇒ **破坏发生了、见证说没发生**。⇒ 该代的构造与现行不同（`PE_HOLD_SHORT` 5200 vs 16000 ⇒ 相位不同），破坏得以在"门已放开"的拍发生；**同一仪器的见证条件仍没捕获到它**（`psc_coll` 的相位/操作数口径问题未定）。
- ⇒ 对"**摘掉 `ds_guard` ⇒ 必红**"的回答：**"RC≠0"有两代数据点（✓）；"每次出现同一条可解释的撞车红"= 未证**；"一次性红过"与"每次必红"的差别 = ① 现行 TB 里 **S 臂自身也红 4 条** ⇒ 任何臂都容易 RC≠0（无判别力）；② W 专属红的**形态随 TB 版本漂移**（`fd671b6` 代 = j10 单条；现行 = j10 + j13-空判据）；③ 唯一一次破坏签名出现时，**专用仪器是哑的**；④ `cc3894d` 逐字登记"买 U/V 的牙、代价是 W 的撞车见证"（`PE_HOLD_SHORT 5200→16000`）⇒ 该红**已被证明是刺激档的函数**；⑤（新增）**当前构造下撞车破坏结构性不可达** ⇒ 要让 `j13`/`e_coll_bad` 真正发火，必须改刺激（见 `FINDINGS_DYNAMIC.md` §预案-D-3 的新构造）。
- ⚠️ 同族登记（我复核成立）：`fd671b6` 提交信息自称"变异臂上 j13 是经'相撞见证=0'红的 ⇒ 对 j13 的牙是【间接】证明"——这句是诚实的，但"间接"的强度还要再降一级：**空判据子句本身与变异无因果**（它在"刺激没搭出相撞条件"时也红）。

### P-3【中】门现状 = **`TX_OVL_GATE: FAIL count=1`**："门全绿"不是现状；S 臂红里有 2 条**已归因给 ghost×persist 交互**、2 条为既有/假构造

- 现读最新全量门日志 `sim/p7b_stagec_tx_regress/author_gate/ghost_gate_stdout5.txt`（末行逐字）：`TX_OVL_GATE: FAIL count=1`；`[S]: … TB_TCP_TX_OVL: FAIL reds=4`。
- S 臂 4 条红（`runS/xs.log` 逐字）：`payload conn=0 seq=000bc8e5 off=7 got=36 exp=74 @264351` · `RETXFIX jump: session end snd_nxt=0004e59c < retx_hi=0004ebb9 conn=1 @342415` · `PS j9: Δstat_retx=21 > TB 注入的 retx 请求数=17` · `PS j6: 无在飞+窗0 时出现探询 =1`。
  - 台账 §9-3 的归属（**引述**，非我的裁定）：payload = 残留 R1（形态②，板不可达）；jump = TB 假构造；`PS j9/j6` = ghost 刀在 persist 臂引入的**预期内行为改动**（最后分离臂 `ring_restore≡0` 判成）。
- 其余 25 臂（A–Z，J 豁免）**全部 RC≠0 ✓**；U/V 臂现**有牙**（`runU`：`[FAIL] PS j12: FIN 在飞时出现探询 =1`；`runV`：`PS j12: RST 在飞时出现探询 =1`）——fd671b6 代的"U/V 的 j11/j12 牙未证"**已在 `cc3894d` 轮关闭**（我两代日志都现读过）。
- ⇒ 放行后要做的事里，"S 臂契约"这一格**必须先有裁定**（改判据 / 改契约 / 继续带红），否则门只能提供"变异臂有反应"这一层信息。

### P-4【低-中】`PS6 BAD` 行**结构性打印全 0**（判据自己安静失效的形态）

- TB `:2623-2625`：`$display("PS6 BAD ladder=%0d … coll=%0d", e_ps_ladder, …, e_ps_coll);` —— 而所有 `e_ps_*` 的 `+1` **都发生在这一行之后**（`:2640`/`:2645`/`:2649`/`:2653`/`:2658`/`:2662`/`:2670`/`:2710`/`:2714`/`:2716`/`:2719`/`:2721`/`:2724`/`:2726`/`:2728`/`:2731`/`:2733`/`:2736`/`:2740`/`:2744`/`:2746`/`:2748`）。
- 现证：`runS/xs.log` 同一次跑里 `PS6 BAD ladder=0 … side=0 … e2=0 …` 的**下一行**就是 `[FAIL] PS j9:` / `[FAIL] PS j6:` ⇒ 该行读出来的"全 0"**不代表判据干净**。`runW/xs.log` 同款（`PS6 BAD` 全 0，紧跟 6 条红）。
- ⇒ 任何"看 PS6 BAD 全 0 ⇒ PS 判据干净"的读法都会错。建议：该行改到判据块之后打印，或加 `(pre-eval)` 字样。

### P-5【低-中】静态检查**落盘件**的 L1 两腿 = **空判据**（diff 基 = `HEAD`；落盘时改动已提交）；**但断言本身经我复跑成立**（D-9 已修，见同目录 `FINDINGS_DYNAMIC.md`）

- 脚本 `static_check_persist.py:105-107`（改前）：`def git_diff_u0(): out = subprocess.run(["git", "diff", "-U0", "--", "rtl/tcp_tx_frame.v"], …)` ⇒ 基 = **工作树 vs HEAD**。
- 落盘件 `_proj_10g/notes/p7b_persist_impl/ev/static_check_formal.txt` 逐字：`[L1] … (a) 白名单: 代码 + 行 **0** 条 …, 越界 0 条` ⇒ 该次跑的 diff 是**空的**（`fd671b6` 已于 20:46 提交、`cc3894d` 21:01 落盘）⇒ (a)/(b) 两条**没检查任何东西**；末行 `STATIC_CHECK_PERSIST: PASS` 里 L1 的权重量 = 0。
- **我的独立复跑（只读）**：用**该脚本自己的** `check_l1()` 对**真实 diff**（`git diff -U0 cfd3b1a fd671b6 -- rtl/tcp_tx_frame.v`）跑：`n_code_plus = 109`（`diff_bytes = 21292`）· `whitelist_bad = 0` · `banned_bad = 0` ⇒ **"白名单越界 0 / 禁用符号净新增 0"这条断言成立**（成立 ≠ 落盘件证明了它）。
- 同一脚本的 S1/FB/PD 三腿**我亲手在现盘复跑**：`[S1] … 零例外`（22 信号 / 26 写点）· `[FB] … 18 条全部通过` · `[PD] … PERSIST_EN/PS_BASE/PS_MAX/RTO_LIM_DP 全 OK`；`--selfcheck` 三负对照都有牙（逐字复现）。⇒ **可复核性：S1/FB/PD = 可复核 ✓；L1 = 只对"未提交的工作树"有意义**（**已由 D-9 修复**：diff 基钉死为 `cfd3b1a..fd671b6`，见 `FINDINGS_DYNAMIC.md` §D-9）。

### P-6【低】设计 §7.2-**S2**（"实施轮先建 fc/b 等价门 + 负对照"）**未落地**：锚在、**无脚本引用**（死资产）——**已由 D-10 补齐**（见 `FINDINGS_DYNAMIC.md` §D-10）

- 锚在位：`sim/p7b_stagec_tx_regress/frozen/tcp_tx_frame_revcfd3b1a.v` = 142,733 B；我校验 = `tr -d '\r'` 后 sha256 = `b6cff515…8e8f84` = `git show cfd3b1a:rtl/tcp_tx_frame.v` 的 sha256 ⇒ **"逐字 = 改前件"成立**（注：仓内对象是 LF 140,501 B，checkout 因 `core.autocrlf=true` 落成 CRLF 142,733 B——两边等价）。
- **但（建门之前）**：`grep -rl "revcfd3b1a"` 在 `author_gate/ frozen/ sim/p4gates/ tb/` = **0 命中**；`author_gate/*.py|*.bat` 里 `frozen` 0 命中 ⇒ 锚**没有任何消费者**（与设计当年对 118 KB 旧锚"死资产"的判词同形态，只是换了个锚）。
- 实际可用的等价证据 = **L2 日志 diff**（我亲手复核：`diff base/xs_runB_baseline.log ev/xs_runB_after.log` = **10 行差异 = 5 对**，类别只有时间戳×2/PID×2/可用内存×2/`$finish` 行号(1556→2438)×2/退出时间戳×2；`$finish` 时间 `2279132800 ps` 两边逐位相同，全部判据行逐字相同）⇒ 该层证据**成立**，但设计承诺的"建门 + 负对照（拿 118 KB 旧锚必红）"这一件**没做**（已补：`s2_equiv_persist.py` + `run_s2_equiv_persist.bat`）。

### P-7【低】设计 §5.2-Ⅳ 的"**互核**（`n_probe_by_dut == n_probe_by_judge`，防'悄悄多排除'）"未实现

- 现核：TB 里无 `n_probe_by_*`（grep 0）；探询分类**只有一条路** = 线上字段分类器 `is_probe`（`:671-672`），且它同时承担 ①`pe_probe_ev` 计数 ②J9 排除（`:866` `&& !is_probe`）③`pe_probe_bad` 的归属判据（`:842`）。
- 与设计 v3 #12 的对照：**#12 的要求（judge 侧只许从线上字段落计数）满足 ✓**；**互核的另一半（与 DUT 侧计数对账）没有**。缺口性质 = 分类器若**过宽**，会把真数据帧从 J9 覆盖窗口里**静默排除**而无人对账（判据面只有"episode 外探询=0"和"探询数≥2"的下界，**没有探询计数的上界型判据**）。⇒ 登记为残留（不是已发生的缺陷）。

### P-8【低】`ps_stage_seq` = 死寄存器（32 FF）——**已由实施件自己登记**（提交信息 ⑥），本件复核成立

- 现读：声明 `:457`、复位 `:1056`、写点 `:1274`（`ps_stage_seq <= rb_snd_una;`）、**读点 0**（全文件 3 处全是声明/复位/写）。设计 §8.1 的 FF 表里它是"暂存三元组"的一项 ⇒ 现行 522 FF 的口径里含这 32 位空转；槽装载实际用的是**实时** `rb_snd_una`（`:1301`）⇒ 功能不缺，只是 T 拍锁的样本没被消费（**与设计 §2.3"T 拍锁 seq"的动机并未落地**：锁了、没用）。

### P-9【低】探询臂给"1 拍 `win_open` 错配"**新增了一个源**（既有豁免类，注释已承认同类）

- 机制：`win_open` 是 `tcb` 的**注册输出**（`rtl/tcb.v:150-153` `always @(posedge clk) win_open <= (win_diff < {16'b0, win_cap});`），其选择输入 `win_id = rb_id`（`board/wrapper_p4.v:2006`）⇒ 探询拍（`rb_id = ps_stage_conn`）的**下一拍** `win_open` 反映的是探询连接的窗。
- 下一拍若另一连接的数据帧启动，其 `start_data`/`s_axis_tready` 的 `wnd_open` 项 = **别的连接的窗**。RTL 注释已把该类登记为"可误开 1 拍（OPEN 方向，每次最多多放 1 帧）；连接切换（scan/svc/ack 旁路 rb_id）同效"（`:238-241`），**探询 arm 是同族的新增来源**。⇒ 登记（量级：≤1 帧；且 `probe_sel` 拍已消费暂存 ⇒ 下一拍 `rb_id = start_id`，错配**不会**叠加到四元组锁存上）。
- 顺带：探询拍也把 **W67/W69 仪器**（`stat_winstall_cap` 用 `win_wnd_eff`/`win_cap_bind`，`:748-749`）的采样连接扰动 1 拍 —— 仪器面的 1 拍偏斜，登记即可。

### P-10【登记】4 处"按字面写不出来/与设计冲突"的落点：**登记在提交信息里，件内无对应注释**

- `fd671b6` 提交信息逐字："另 4 处'按字面写不出来/与设计件自身冲突'（**wire 不能写在 always 内 · j4 单臂做不到 · j9 子相 i 本 TB 不可产生 · j9 计数与 j10 冲突**）已逐条登记"。现核：TB/RTL 里 4 者**都没有**对应的成文登记块（`grep "j4\|n_probe_by" tb/tb_tcp_tx_ovl.v` = 0；"wire 不能写在 always 内"只有 RTL `:579-581` 一处**正向**说明）。⇒ 这 4 条目前只活在提交信息里（#70 的形态：**偏差没有落在被审件里**）；放行后的动态轮应当把 j4/j9-子相 的替代判据补进 TB 或正式登记为"不实现"。

---

## §3 我独立复核**成立**的确认项（不含任何"可上板/可构建"背书）

1. **`ds_guard` 集合包含（超集）逐项成立**：`start_data`（`:679-682`）合取项 = {`rx_state==RX_IDLE`, `recv_first`, `!ack_pend_r`, `!svc`, `!ring_eval`, `!scan_now`, `!rx_flush`, `s_axis_tvalid`, `!fifo_full`, `!bank_rdy[rx_bank]`, `wnd_open`, `!tx_blk_sid`}；`ds_guard`（`:607-608`）内层 = {`recv_first`, `s_axis_tvalid`, `!ack_pend_r`, `!fifo_full`, `!bank_rdy[rx_bank]`, `wnd_open`} ⊂ 上式 ⇒ `start_data ⇒ ¬ds_guard ⇒ probe_sel=0` ✓。**第 5 消费者的实际锁存门是 `accept && recv_first`**（`:1328-1330`），比 `start_data` 宽：`accept = s_axis_tvalid && s_axis_tready`，而 `s_axis_tready`（`:674-678`）在 `recv_first=1` 时只能走第二子句（含 6 项 + `!tx_blk_sid` + 外项 `!fifo_full && !bank_rdy[rx_bank]`）⇒ 同样被覆盖 ✓（另加 `w_tap_seq = start_data ? rb_snd_nxt : tap_seq`（`:814`）与 `csum_init = start_data || ring_start`（`:820`）两处也在覆盖内）。⚠️ **该超集里缺 `!tx_blk_sid` 这一条的后果 = §2-P2 的机制**（守卫更保守 ⇒ 删掉后探询在"门将开未开"的拍先跑）。
2. **5 个 `rb_id` 消费者全对**：① svc 拍（`probe_sel ⇒ !svc`，mux 优先级更高）② ring_eval 拍（`!ring_eval`）③ scan 拍（`!scan_now`，与 arm 位置=双保险）④ `start_id` arm 的**数据帧启动**（被 `ds_guard` 挡）——它的**槽装载**在 `probe_sel=1` 时本就该用 `ps_stage_conn`（探询槽）✓ ⑤ 数据帧启动拍的 TCB/CAM 锁存 + ring 写游标 + `csum_init`（同上，被挡）✓。
3. **环安全逐操作数成立**：`probe_sel`（`:610-612`）11 项 + `ds_guard` 6 项里**无任何 `rb_id` 派生项**（寄存器/输入/FIFO 状态/计数器；`wnd_open` = `tcb` **注册**输出，`win_id` 采样在**上一拍**）⇒ 无新组合环 ✓。
4. **退避/编码/脉冲与设计 v3 逐字一致**：`ps_reload`（`:412-419`）· `ps_next`（`:760-761`）· `ps_arm`（`:752-754`）· `ps_fire` = **wire 单拍、不落寄存器**、**同拍**发 ring 读请求（`:757-758`）· 五路清位与 §3.1/§3.4b 表逐条对上（唯一例外 = P-1）· `PS_BASE=26'd3_051_758`/`PS_MAX=26'd36_621_094` < 2²⁶ ✓。
5. **两分支**：persist 在 else 支 **0 泄漏**；ghost 刀双支齐（§0-2）✓。
6. **"默认关 ⇒ 静态等价"三层证据**：S1（22/26 零例外）+ FB（18 条折回对）——**我亲手复跑通过**；L1 断言（109 行 / 0 越界 / 0 净新增）——**我用同一检查器在真 diff 上复跑通过**（并已把 diff 基钉死，D-9）；L2 行为等价（臂 B 日志）——**我亲手 diff 复核**（仅 5 对元数据差异，且已机器化：D-10）。另有 xvlog 侧实证：默认支（`runA`，不定义 `TCP_TX_OVL`）编译 **0 错误、无 `PERSIST_EN` 相关告警** ⇒ 设计 §7.1 的【推断·未跑工具】在 xvlog 面已有读数：未见告警（Vivado synth 面仍未测）。
7. **探询段的线上正确性由 TB 独立复算背书（S 臂）**：`pe_probe_bad=0`（IP=41/plen=1/flags=0x18/seq==TB 自维护 `sh_una`/归属 conn）· `e_csum=0`（从线上字节复算 IP/TCP 校验和）· `probe_out=0` · `E7wit=2 ∧ coll=0` · `j3`：序列内 `snd_nxt` 逐位不变（`PS5 … sn_first=sn_last=0004eb98`）· `j1` 阶梯 in-band（`PS2 LAD n=3 dc=9 d1=24 d2=48`，want 8/24/48）· `j7/j8/j10/j12` 绿（S 臂红集合不含它们）。
8. **两把刀的相互作用（静态）未见互相破坏**：persist **不写**任何 `upd_*`/`rb_snd_nxt`/`retx_hi`/`epoch`；探询被 `&& !probe_sel` 挡在 `upd_wr_ctrl` 之外（`:637`）⇒ **不给 ghost 刀的 `+1` 累积器添新源**；`ring_restore ⊆ ring_eval`（`:795`）与 `probe_sel ⇒ !ring_eval` 互斥（**不可能同拍**）✓；探询读口与 `rd_tap` 结构性不共存（`:799` `rd_tap = ring_start || (ring_act && …)`，扫描拍上两者皆 0）✓；读地址 = `snd_una[15:0]` 恒在被写过区域且与写游标至少差（`PLEN_MAX` 界内）⇒ 同字重写不可达（**结构性**，与设计 §2.2-3 同口径，未实测）。
9. **变异臂的单点性（我现读 mut 与 RTL 的 diff）**：`mut_ps_nodsg` = 删 `&& ds_guard`（`:612`→`…!retx_active;`）· `mut_ps_noarmfin`/`_noarmrst` = 各删 `ps_arm` 一个子句（`:754`）⇒ 三条都是**逐字单点变异**，且 `mk_mut_tx.py` 有锚点断言（`mut_gen.log`：`ANCHORS: all 22 mutants matched (25 subs, each hits==expect)` / `MUTGEN OK`）。

---

## §4 动态臂清单（**待放行**；放行前提 = Vivado 结束 + `rtl/tb/sim` 冻结解除 + 写权归属明确）

> 纪律：跑动期间不许改 `rtl/tb/sim`（#57）；xsim 不与 Vivado 并跑（#47）；每条臂记 **RC + `[FAIL]` 全列表 + `PS0–PS6` 全行**（现门只对 S/T 打了 PS 行，W 的 PS 行要靠 `runW/xs.log` 直接读）。
> ⚠️ **D-3 已按 E7 逐拍 DBG 读数（§2-P2）重写**：现行构造下"删 `ds_guard`"结构上无法撞车（探询在"门将开未开"拍抢先），故 D-3 的构造必须让**释放拍之前 ds_guard 恒 1**（源/窗在释放前不可启动），详见 `FINDINGS_DYNAMIC.md` §预案-D-3。

| # | 臂 | 构造/突变 | 预期 | 为什么（要判什么） |
|---|---|---|---|---|
| D-1 | **W/S 臂 E7 逐拍 DBG 登记（零新构造）** | 只读 `run{S,W}/xs.log` 的 `DBG E7 @` 15 行 + `PS1/PS3/PS4` 全行 | 已做：S `t=1 coll=1`（守卫压住唯一一拍）/ W `t=1 rdy=0 busy=1`（早一拍被消费） | 把"W 的红不含撞车见证"钉成落盘读数；**已定案机制 = 早一拍消费**（§2-P2） |
| D-2 | **W-旧刺激档**（复现版） | TB `PE_HOLD_SHORT` 5200（`tb:90`）+ `ARM_PERSIST` + `mut_ps_nodsg` | 预期：破坏签名回归（`seq_mono rev … 000466e8`/`seqmono=24`）；**同跑记 `E7wit`** | 证明 W 的"破坏被见证"是**刺激档函数**；核对破坏发生时 witness 是否为 0 |
| D-3 | **W-新构造（源/窗在释放前不可启动）** | 见 `FINDINGS_DYNAMIC.md` §预案-D-3（`ifdef PE_E7B`：释放前 conn0 `snd_wnd=0` / 或源 `src_skip` 全屏蔽，释放拍与 `win_open` 上升同拍放开） | 目标：`E7wit ≥1` **且** `e_coll_bad ≥1`（真撞车 = 跨连接四元组/seq 上线） | 让 `j13`/`e_coll_bad` 这台仪器**第一次真正发火**（现行构造结构性做不到） |
| D-4 | **e_coll_bad 仪器自检**（不改 DUT） | 只改 TB 的 `psc_coll`/观察窗定义使其故意过宽，跑 S 臂 | 预期：`e_coll_bad>0` ⇒ 证明该仪器路径能红 | 仪器有牙自检（判据自己也要有对照） |
| D-5 | **单子句变异（R-2 的另一半）** | `probe_sel` 只删 `&& !scan_now`（其余逐字） | 预期 RC≠0 且红含 RTO 装错连接/`fin_push` 判错族（无红 ⇒ 该不变量无牙） | 设计 §2.4-3"不许单独改任一半"——测那半的牙 |
| D-6 | **分类器过宽臂**（P-7） | 把 `is_probe`（`tb:671`）放宽一项（如去掉 `psc_win_closed`） | 预期：`e_seqcont`/J9 覆盖被静默削（读数变化可判） | 回答"没有互核 ⇒ 多排除能不能被看见" |
| D-7 | **cfg_up×捕获窗臂**（P-1） | 新 episode（`ifdef PE_E4B`）：等 `ps_fire` 后**不等 rdy**、在 fire+1 拍直接 `cfg_up` | 预期（若 P-1 成立）：新计数 `pe_f_e4b_probe ≥1`（j10 型红）且该探询 `payload` 不匹配 | **唯一能判定 P-1 可达性的实验**（现 TB 结构性不覆盖）；见 §预案-D-7 |
| D-8 | **S 臂契约裁定后复跑** | 三条已归因红（payload R1 / jump 假构造 / j9-j6 交互）×（改判据/改契约/保持）任一后重跑全量门 | 目标：FAIL count 归 0 或把"带红契约"写成文 | P-3：门的可用性受限这一格 |
| D-9 | **✅ 已做（本审查轮）** | `static_check_persist.py` 的 diff 基钉死为 `cfd3b1a..fd671b6` | 复跑：`代码 + 行 109 条 / 越界 0 / 净新增 0` + 自检有牙 | 见 `FINDINGS_DYNAMIC.md` §D-9（含 git diff 原文） |
| D-10 | **✅ 已做（本审查轮）** | 新建 `s2_equiv_persist.py` + `run_s2_equiv_persist.bat`（锚出处 sha256 + L2 日志对机器化核对 + 3 负对照） | 复跑：两条腿 PASS、负对照全红 | 见 `FINDINGS_DYNAMIC.md` §D-10 |

---

## §5 未定项（⛔ 不许当已答）

1. **P-1 的可达性与危害**（fire 后 ≤2 拍同槽 `cfg_up`）：结构上可构造，**未实测**；危害上限 = 1 条 1 字节旧数据段（可能是错的字节）。
2. **P-2 的机制归因**：现行构造 = **早一拍消费**（已由 E7 逐拍 DBG 读出现证）；但 `fd671b6` 代"破坏在场、见证=0"的那次到底发生在哪拍/为何 witness 没捕获 = **未定**（`psc_coll` 的相位/口径问题未分离）。
3. **W 撞车见证（`E7wit`）的稳定性**：现行 S=2；`fd671b6` 提交信息称"臂 S 相撞条件成立 **4** 拍"——**两处数字不一致**（以现盘日志为准）；数字漂移本身 = 刺激耦合的证据。
4. **`payload conn=0 @264351`（S/U/V/W 共有）根因**：实施件自述"与 persist 无关但根因未定位"。我的读数：**oracle-T 臂**（`ev/orT_oracle_xs.log`：`payload=14`，含 3 处 `payload conn=0`）也红 ⇒ "与 PERSIST_EN 无关"**在 oracle 构造下成立**；但**门的 T 臂本身 `payload=0`** ⇒ 两个 T 构造不同，仍未定位（不写"不存在"）。
5. **`ps_stage_seq` 的处置**（删 / 接进判据做 T 拍样本 oracle）：未定。
6. **板级判据 `J-P1…J-P7` 全部未跑**（本件零板卡）；设计 §6.1 的 P-A/P-C 造法与 `--rcvbuf-after-connect` 纪律**未触及**。
7. **P-9 的 1 拍错配是否可被 j13/j1 抓到**：未证。
8. **本件未做**：未跑 xsim/Vivado/门（放行后见 §4）；未核 `mk_mut_tx.py` 全部 22 个变异件语义（只核了 PS 三件 + ghost 三件）；未核 ghost 刀的 RTL 实现（属另一把刀）；未核台账/交接件；未读 `_proj_pcie/`。

---

**本件所有"成立" = 逐字回源码/日志核过该引用；不含对"该设计在板上是否有效""时序是否可收口"的任何背书。**
（原始读数出处：`rtl/tcp_tx_frame.v` / `tb/tb_tcp_tx_ovl.v` / `rtl/tcb.v` / `rtl/retx_ram.v` / `board/wrapper_p4.v`（HEAD 与工作树）现盘 · `sim/p7b_stagec_tx_regress/author_gate/{run_tx_ovl_gate.bat,mk_mut_tx.py,static_check_persist.py,run_static_persist.bat,runS,runT,runU,runV,runW,ghost_gate_stdout5.txt,frozen/}` · `_proj_10g/notes/p7b_persist_impl/{gate_full_stdout.txt,ev/xs_runW.log,ev/orT_oracle_xs.log,ev/orS_oracle_xs.log,ev/static_check_formal.txt,ev/static_check_selfcheck.txt,base/*}`）
