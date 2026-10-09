# P7B A7 —— `u_tcp_tx/ctrl_tcpcsum_reg[*]/D` 汇聚宿的**实现级设计研究**

- 日期: 2026-10-10 · 角色: 时序设计研究 (纯设计件) · 状态: **设计件, 未构建 / 未仿真 / 未上板**
- 输入面 (本轮**只读**, 且**未跑**任何 vivado/xvlog/xelab/xsim):
  - 源码 = `rtl/tcp_tx_frame.v` (工作树副本; 现役分支 = `` `ifdef TCP_TX_OVL `` `:236-1076`, `else` 分支 `:1077` 起**未编译**)
  - 时序读数 = **归档件** (`_proj_10g/notes/p7b_build_longflow/{S1,S2,S3,C1,R1}/` · `p7b_build_longsend/A/` · `_t3_family/out/*/`)
  - ⛔ 本轮**未读** `board/p7b_ku5p_*.rpt` / `board/p7b_ku5p_stdout.txt` (构建 C 正在改写它们)
  - ⛔ 本轮**未改**任何 `rtl/` `board/` 文件; 仓内只新增本文件
- ⚠️ **档位纪律**: 本件所有时序读数都带档位 (`TX_BYTES` / BID / 臂名)。同名 WNS **不是同一条路径** (全局 #66; `README.md:455-472`)。
- 强度标记: 【事实/源码读值】= 直接读源码/归档报告得到 · 【推演】= 由事实按逻辑推 · 【需仿真/综合才能定】· 凡没量到的一律写 **未量**。

---

## §0 摘要 (五行)

1. **四源名单已过时**: 实测命中该宿的**至少 5 个**源寄存器 (`retx_active_reg` / `recv_first_reg` / `bank_rdy_reg[0]` / `ack_pend_r_reg_replica` / `FSM_sequential_rx_state_reg[0]`), 其中 `ack_pend_r_reg_replica` **不是 RTL 寄存器名**而是 `phys_opt_design` 的**复制件**——它在 S1/R1 两档存在、在 S3/C1 两档 **`SRC_NOT_FOUND`** ⇒ **"哪一条最难打"逐档在换**【事实, `_t3_family/out/*/t3_stdout_*.txt`】。
2. **真正的病灶不是"D 端四选一 mux"，而是一条共享圆锥**: 四源都只是 `rb_id` 地址 mux 的**选择位** ⇒ 经 **TCB/CAM 组合读** ⇒ 进**控制帧校验和的 4 项加法树 + fold16** ⇒ 落到 D。因此"拆成多个寄存器位"这类改法**结构性不适用** (§2 候选 (a))。
3. **不变式** = 该宿族在**六档全部臂**里都落在该档 WNS 的 **0.000–0.061 ns** 之内 (C1 0.068/S1 0.016/S2 0.113/S3 0.052/A 0.021/R1 −0.008) ⇒ 它是数据面域**唯一的跨档紧约束**【事实】。
4. **推荐改法 = 候选 R-1「T+2 重定时」**: 把 `ctrl_tcpcsum` / `ctrl_ipcsum` 的装载从 `start_ack+1` 推迟到 `start_ack+2`, 并**从已寄存的 `ctrl_*` 字段复算**校验和 (`:867`/`:866` 改源 + 新增 1 位 `start_ack_d1`)。**逐拍论证证明值逐位不变、两处唯一读点分别在 T+5 / T+7** (余量由 4/6 拍降为 3/5 拍) ⇒ **不改行为**、零新增数据寄存器、把 7–11 级"选择解码+组合读"整段移出 D 锥。
5. **必须改造的门**: `sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat` **今天产出零证据** (`mut_gen.log: MUTGEN FAIL 5`; 闸在跑任何一条臂之前就 `exit /b 1`); 精确病根 = **工作树 CRLF + 2 条陈旧锚点** (本轮已逐锚点实测量化, §4.2), 修法 ≈ 10 行 Python (**不动 RTL**)。

---

## §1 病灶的精确位置 (回源码)

### 1.1 现役分支与工作树状态 (读之前先定性)

- 【事实】构建宏面: `board/build_p7b_ku5p.tcl:153` = `verilog_define {APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1 TCP_TX_OVL=1}` ⇒ **上板/RTL 综合跑的就是 `ifdef TCP_TX_OVL` 分支** (`rtl/tcp_tx_frame.v:236-1076`)。
- 【事实】`git status` 在本轮读取时刻: `rtl/tcp_tx_frame.v` **无改动** (工作树 = `HEAD` 的该文件; 最后一次改动 = `92cbeee` P7b-RETXFIX r6-fix); `rtl/app_pattern.v` 与 `board/wrapper_p4.v` 有改动 (构建 C 在飞)。
- 【事实】行尾: 工作树 = **CRLF** (125,620 B / CR 2040 / LF 2040); `HEAD` blob = **LF** (123,580 B / CR 0); `core.autocrlf=true`。两数之差 **恰 2,040 B = CR 数** ⇒ 工作树比 blob 多的就是每行一个 CR。

### 1.2 `ctrl_tcpcsum` 的声明与**全部** D 端写点

【事实】声明: `rtl/tcp_tx_frame.v:380-381`
```
    reg  [15:0] ctrl_wnd, ctrl_doff, ctrl_sport, ctrl_dport, ctrl_idcap,
                ctrl_ipcsum, ctrl_tcpcsum;
```
【事实】D 端写点**只有 2 处** (全文 `grep -n "ctrl_tcpcsum <= "` = 2 命中):

| # | 位置 | 上下文 | 源表达式 | 强度 |
|---|---|---|---|---|
| 1 | `:719` (`ctrl_tcpcsum <= 16'd0;`) | 异步复位支 `if (!rst_n)` | 常量 0 | 事实 |
| 2 | `:867` (`ctrl_tcpcsum <= ctrl_tcpcsum_now;`) | `if (start_ack)` 支 (块首 `:852`) | **`ctrl_tcpcsum_now`** | 事实 |

⇒ **功能路径上只有一个写点** (写点 2)。同块同拍还写 `ctrl_seq/ctrl_ack/ctrl_doff/ctrl_wnd/ctrl_dmac/ctrl_dip/ctrl_sport/ctrl_dport/ctrl_idcap/ctrl_ipcsum` (`:855-866`) 与 `ctrl_slot_busy`/`ctrl_tx_pend` (`:853-854`)。

⚠️ **由此得到本件最重要的结构判定**【推演, 由 :594 的表达式直读】: D 端**不是**"四源数据 mux", 而是**一条组合锥** —— `ctrl_tcpcsum_now` 是**唯一**的 D 源, 四源只是这条锥里 `rb_id` 地址 mux 的**选择位**。所以"按源拆寄存器位"在语义上不存在 (§2 候选 (a))。

### 1.3 D 端圆锥的完整溯源 (逐级, 带行号)

```
rb_id  (:501-503)  ←── 选择位来自四个已寄存的源 (§1.4)
  = svc      ? svc_id_r   (:406)
  : ring_eval? retx_id_r  (:386)
  : scan_now ? scan_id    (:390)
  : (rx_state==RX_IDLE) ? start_id  (:438 = ack_pend_r ? ackq_dout[38:35] : s_axis_tid)
  : f_conn[rx_bank]       (:371,:713)
cam_rd_id = rb_id (:503)
      ↓ 组合读
  u_tcb:  rb_snd_nxt / rb_rcv_nxt / rb_rcv_wnd  (tcb.v:110-115, 全组合: `snd_nxt_r[rb_id]`)
  u_cam:  cam_rd_sip / cam_rd_dport / cam_rd_sport  (tcp_cam.v:26-33 读回口, 组合)
      ↓
ctrl_acc (:592-593) = csum_init_val + {14'b0,ctl_aen_v1} + {14'b0,ctl_aen_v2} + {14'b0,ctl_aen_v3}
  ├ csum_init_val (:563-565) = cfg_src_ip[31:16] + cfg_src_ip[15:0] + cam_rd_sip[31:16]
  │                            + cam_rd_sip[15:0] + 32'h0006
  ├ ctl_aen_v1 (:586-587)    = 18'd20 + cam_rd_dport + cam_rd_sport + rb_snd_nxt[31:16]
  ├ ctl_aen_v2 (:588-589)    = rb_snd_nxt[15:0] + ctrl_ack_now[31:16] + ctrl_ack_now[15:0] + ctrl_doff_now
  │     ├ ctrl_ack_now (:583)  = (aq_fin||aq_rst) ? rb_rcv_nxt : ackq_dout[31:0]   ← 又一次从 rb_id 读
  │     └ ctrl_doff_now(:584-585)= {8'h50, aq_syn?8'h12 : aq_fin?8'h11 : aq_rst?8'h14 : 8'h10}
  └ ctl_aen_v3 (:590)        = rb_rcv_wnd
      ↓
ctrl_tcpcsum_now (:594) = ~fold16(ctrl_acc)      // fold16 = :341-348 (两级 17 位加法)
      ↓
ctrl_tcpcsum_reg[*]/D                            // 写点 2 (:867); FDCE (D=数据, CE=start_ack, CLR=复位)
```
同构的第二条锥 (同源同宿族, 只差函数): `ctrl_ipcsum_now (:595) = ip_csum_calc(16'd40, id_r, cam_rd_sip)` (`ip_csum_calc` = `:325-338`, 10 个 16 位项 + 两级折叠)。

**组合级数的源码级估计**【推演, 与实测吻合】:

| 段 | 源码依据 | 级数估计 |
|---|---|---|
| `rx_idle` | `:426` = (rx_state==RX_IDLE) && recv_first | 1–2 |
| `svc` | `:464-465` (含 `|rto_pend_any`) | 2–3 |
| `ring_eval` | `:468-469` (含 `!bank_rdy[rx_bank]`) | 3–4 |
| `scan_now` | `:470-471` (套嵌 `!svc && !ring_eval`) | 4–5 |
| `rb_id` 5 路套嵌 mux | `:501-503` | +2–3 |
| TCB/CAM 16:1 组合读 | `tcb.v:110-115` / `tcp_cam.v` 读口 | +2–3 (宽 mux, 可能含 F7/F8) |
| **前端小计** | | **7–11** |
| 加法树 + fold16 + 反相 | `:592-594`, `:341-348` | **+11–12** (实测 6–8 个 CARRY8) |

【事实】**与两档实测逐数吻合**: S3 档前端 = **7 级** (后半 12 级, 共 19), A 档前端 = **11 级** (后半 11 级, 共 22) —— 见 `_t3_family/out/S3/fam_S3_B_exact.rpt:24-25,57-120` (S3) 与 `p7b_build_longsend/A/wrapper_p4_timing_summary_routed.rpt:13421-13536` (A)。
⇒ **前端 (选择解码 + 组合读) 是各档之间的"变量段"; 算术段 (11-12 级) 是常量段。** 这就是推荐改法 R-1 的着力点。

### 1.4 四源名单核对 (⚠️ 本工程有"登记过时"先例 #63)

历史登记 = `retx_active_reg` / `bank_rdy_reg[0]` / `ack_pend_reg_replica` / `recv_first_reg`。

| 源 | 是否存在于现役 RTL | 在该宿的实测 slack (档) | 级数 | 出处 |
|---|---|---|---|---|
| `retx_active_reg` | ✅ `:385` | **0.052 (S3 = 该档 WNS)** · 0.068 (C1) · 0.050 (S1) · 0.113 (S2) · **−0.008 (R1)** | 19 / 22 / 24 / 22 / 20 | `t3_stdout_{S3,C1,S1,S2,R1}.txt` |
| `recv_first_reg` | ✅ `:354` | 0.070 (S3, 同宿 `[14]/D`) | 19 | `t3_stdout_S3.txt:200` |
| `bank_rdy_reg[0]` | ✅ `:366` | 0.227 (S3, 同宿 `[14]/D`) | 19 | `t3_stdout_S3.txt:163` |
| **`ack_pend_r_reg_replica`** | ❌ **RTL 里没有这个名字** —— 它是 `phys_opt_design` 的**复制件** (`p7b_build_longflow/S1/p7b_ku5p_stdout.txt:4430` 逐字 `Did not re-place instance u_tcp_tx/ack_pend_r_reg_replica`) | 0.016 = **S1 该档 WNS** · 0.040 (R1) · **S3/C1 档 `SRC_NOT_FOUND`** | 24 (S1) / 18 (R1) | `t3_stdout_{S1,R1}.txt`; R1 档该寄存器有 **3 个副本** (`t3_stdout_R1.txt:97`: `_replica/_replica_1/_replica_2`) |
| **`FSM_sequential_rx_state_reg[0]`** | ✅ 即 `rx_state` `:351` (**历史名单里没有它**) | **0.021 = A 该档 WNS** (22 级); S3 档 **未量** (t3 未查该源) | 22 (A) | `p7b_build_longsend/A/READINGS.txt:75-86` |
| `ack_pend_r_reg` (基名) | ✅ `:405` | **未量** (S3 档无该源的定向查询) | — | — |

**结论 (本格)**: ① 名单**不准确**, 两处: (a) `ack_pend_reg_replica` 不是稳定的寄存器名, 而是 P&R 的产物 ⇒ **不能作为设计对象**; (b) 名单漏了 `rx_state`——它在最近一档 (A) **就是该宿的最差源**。
② 名单**不可能准确**: 四个源全部只是 `rb_id` 的选择位, 谁是 startpoint 由布局/复制决定 ⇒ **跨档漂移是结构性的, 不是登记错误**。
③ 唯一稳定的是**宿与锥**: 六档全部臂里, 该宿族都贴在该档 WNS 上 (§0-3)。

### 1.5 哪一条"真正最难打" + ⚠️ #66「清单藏族」的处置

- 【事实】**不可跨档回答**。逐档实测最差源: C1 = `bank_rdy_reg[0]`(该档 WNS 0.014, 但宿是 `u_app/stg_reg[33]/CE`, **不在本宿**) / S1 = `ack_pend_r_reg_replica`→**本宿** / S2 = `c_snd_una`→`tx_lfsr` (**不在本宿**) / **S3 = `retx_active_reg`→本宿 (0.052 = WNS)** / A = `rx_state[0]`→本宿 (0.021 = WNS) / R1 = `retx_active`→`u_tcb/snd_wnd_r_reg[5][12]/CE` (WNS −0.035), 本宿 −0.008。
- 【事实】**藏族 (清单只列每个端点的一条最差路径) 在本病上确实发生了, 且已被量化**:
  - `worst2000_S3.txt` 里 `ctrl_tcpcsum_reg[*]/D` 出现在 **16 个端点全部** (bit 15/14/13/10/11/12/9/8/4/7/6/5/2/3/0/1), 但**每个端点只有一条记录**, 源**全是** `retx_active_reg`。
  - 而**不带 `-to` 的定向查询** (`-from u_tcp_tx/recv_first_reg/C`) 却能查到 `recv_first → ctrl_tcpcsum_reg[14]/D = 0.070` —— **比 retx_active 只差 0.018 ns, 在 top-2000 清单里 0 命中** (`t3_stdout_S3.txt:200` vs `worst2000_S3.txt`)。
  ⇒ **只读 top-N 清单会漏掉第二源。判"哪个源最难"必须用 `-from`/`-to` 逐族定向查询** (本工程已有现成脚本: `_t3_family/t3_query.tcl` 的 `famq` proc, `:76-...`)。
- 【推演】**真正要打的不是任何一条源, 而是宿锥**: 无论当前 startpoint 是谁, 路径都走同一条锥 (选择解码 → 组合读 → 加法树)。**打在锥上, 六档同时受益**; 打在源上 (如给 `ack_pend_r` 加复制/给 `rx_state` 编码) 只挪动 startpoint (§2 候选 C)。
- 【事实】**次族清单** (改完本宿后大概率会顶上来, 供下一轮排程; 均为"同源异宿"或独立族):
  | 族 (SRC → DST) | 级数 | 最紧档读数 | 出处 |
  |---|---|---|---|
  | `bank_rdy_reg[0] → u_app/stg_reg[*]/CE` | 23 | **C1 WNS +0.014** | `t3_stdout_C1.txt` |
  | `retx_active_reg → u_tcb/snd_wnd_r_reg[*]/CE` | 17 | **R1 WNS −0.035** | `t3_stdout_R1.txt` |
  | `FSM_rx_state[0] → u_tcb/snd_nxt_r_reg[3][*]/CE` | 16 | A 档 0.047 | `A/READINGS.txt:85` |
  | `u_app_udp/u_txf/dout_reg[70] → u_udp_tx/ip_csum_r_reg[*][*]/D` | 21–22 | S3 档 0.141 (S3 的**次族**) | `worst2000_S3.txt`; `P7B_BUILD_STAGEA.md` 亦为 WNS |
  ⚠️ 这些族的**机制未定位** (为什么 `bank_rdy`/`retx_active` 会走到 `u_app`/`u_tcb` 写使能) —— 登记为未定, 见 §5。

### 1.6 跨档不变式 (本件的立论根据)

| 档 (TX_BYTES/BID) | 该档 WNS | 该档 WNS 宿 | **本宿族最紧读数** | 差值 | 出处 |
|---|---|---|---|---|---|
| C1 (2²⁰/0x11) | +0.014 | `u_app/stg_reg[33]/CE` | +0.068 | 0.054 | `t3_stdout_C1.txt` |
| S1 (2²⁴/0x13) | +0.016 | **本宿** (`ack_pend_r_reg_replica`) | +0.016 | **0.000** | `t3_stdout_S1.txt` |
| S2 (2²⁶/0x14) | +0.052 | `u_app/tx_lfsr_reg[19]/D` | +0.113 | 0.061 | `t3_stdout_S2.txt` |
| **S3 (2²⁸/0x15)** | **+0.052** | **本宿** (`retx_active`) | **+0.052** | **0.000** | `S3/READINGS.txt:61-64` |
| **A (2²⁸−1+TX_CONT/0x16)** | **+0.021** | **本宿** (`rx_state[0]`) | **+0.021** | **0.000** | `A/READINGS.txt:71-86` |
| R1 (2³¹/0x12) | −0.035 | `u_tcb/snd_wnd_r_reg[5][12]/CE` | −0.008 | 0.027 | `t3_stdout_R1.txt` |

⇒ 【事实】**六档全中且在 0.061 ns 内**。这是数据面域 (6.400 ns) 的**唯一跨档紧约束**, 也是"现役 DP 余量只剩 0.021 ns"的直接来源 (A 档 = 0.33%)。

---

## §2 改法候选 (每条 = 改动面 / 代价 / **是否改语义(逐拍论证)** / 验证要求 / WNS 预期方向)

### 候选汇总表

| # | 改法 | 改动面 (行号) | 代价量级 | **改语义?** | 验证要求 | WNS 预期方向 |
|---|---|---|---|---|---|---|
| **R-1** ⭐推荐 | **T+2 重定时**: 校验和改从**已寄存的 `ctrl_*` 字段**复算, 装载推迟 1 拍 | `:866-867` 改源 + 新增 `start_ack_d1` (1 位 FF, ~`:760-761` 附近) | **+1 FF**; 加法树同规模 (≈±0 LUT); +1 控制集 | **否** (§2.1 逐拍论证; 值逐位相同, 唯一读点在 T+8) | 修好的 tx_ovl 门 (A/B 正控 + C..K 变异) + 一次构建收口 | **正向** (移出 7–11 级前端 + 摆脱大扇出网布线) |
| R-2 | 两拍拆分 (把加法树也切一刀) | 同 R-1 + 1 个部分和寄存器 | +1 FF(1 位) + ~20 FF (部分和) | 否 (但余量只剩 **1 拍** 于 `ctrl_ipcsum`, 见 §2.2) | 同 R-1 + 额外 TB 断言 | 更正向 (幅度未量) |
| (a) | 拆成多个寄存器位 / 按源分位 | — | — | **不适用** (§2.3) | — | — |
| (c) | 复制寄存器 / 控制扇出 (`MAX_FANOUT`) | 无 RTL 改动 (属性) | +2–8 FF 复制件 | 否 | 同 R-1 (跑一次即可) | 弱正向 (只减 route, **不减级数**; 证据: S1/R1 档复制件自己成了 startpoint) |
| (d-1) | 把 `rb_id` 选择条件"提前一拍寄存" | — | — | **会改行为, 禁止** (§3-#1) | — | — |
| (d-2) | 预计算准静态项 (cfg 部分) | `:563-565` | +16 FF, −1 级 | 否 (需 cfg 更新路径) | 门 + 构建 | 很弱 (12 级里省 1 级) |
| R-3 | 给控制帧槽加**专用读口** (地址 = `start_id` 直连, 不经 `rb_id` mux) | 新增读 mux | **~250–400 LUT** (144 bit 16:1) + CAM 读口复制 | 否 (需证 `rb_id==start_id` @ start_ack) | 门 + 构建 | 正向但**小于 R-1** (只省前端里的选择段) |
| R-0 | 不改 (现状) | — | 0 | — | — | 基线: A 档 +0.021 = 0.33% |

---

### 2.1 ⭐ R-1「T+2 重定时」—— 主推荐 (逐拍论证是本节的核心)

**改动面 (3 处, 全部在 `rtl/tcp_tx_frame.v` 的 OVL 分支内)**

1. 新增一位延迟使能 (建议紧邻 `:760-761` 那组每拍寄存器):
   ```verilog
   reg  start_ack_d1;
   ...
   start_ack_d1 <= start_ack;          // 与 :760 `ack_pend_r <= !ackq_empty` 同批
   ```
2. `:866-867` 的装载使能与复算源改写 (**唯一的功能改动**):
   ```verilog
   // 原 (使能 = start_ack; 源 = 组合读总线)
   //   ctrl_ipcsum  <= ctrl_ipcsum_now;              // :866
   //   ctrl_tcpcsum <= ctrl_tcpcsum_now;             // :867
   // 新 (使能 = start_ack_d1; 源 = 已寄存的 ctrl_* 字段)
   if (start_ack_d1) begin
       ctrl_ipcsum  <= ip_csum_calc(16'd40, ctrl_idcap, ctrl_dip);
       ctrl_tcpcsum <= ~fold16( sum_from_ctrl_regs );
   end
   // 其中 sum_from_ctrl_regs := 把 :563-590 的四个 18 位项逐项换成等价的已寄存字段:
   //   csum_init_val : cfg_src_ip 两半 (端口, 不变) + ctrl_dip[31:16] + ctrl_dip[15:0] + 32'h0006
   //   ctl_aen_v1    : 18'd20 + ctrl_sport + ctrl_dport + ctrl_seq[31:16]
   //   ctl_aen_v2    : ctrl_seq[15:0] + ctrl_ack[31:16] + ctrl_ack[15:0] + ctrl_doff
   //   ctl_aen_v3    : ctrl_wnd
   ```
   ⚠️ 只是**操作数来源**换成同一批寄存器的输出 (对应关系: `cam_rd_sip`→`ctrl_dip` `:862`、`cam_rd_dport`→`ctrl_sport` `:863`、`cam_rd_sport`→`ctrl_dport` `:864`、`rb_snd_nxt`→`ctrl_seq` `:857`、`ctrl_ack_now`→`ctrl_ack` `:858`、`ctrl_doff_now`→`ctrl_doff` `:859`、`rb_rcv_wnd`→`ctrl_wnd` `:860`); 加法交换律 + 单次 `fold16` 下**逐位相同**。四个 `{14'b0, …}` 的零扩展与 `:592-593` 一字不差地保留 (不限宽、不边加边折)。
3. `ctrl_tcpcsum_now` / `ctrl_ipcsum_now` (`:594-595`) 与 `ctrl_acc` (`:592-593`) 若不再被别处使用即随之删除 (全文只有 `:866-867` 两个消费者)。

**代价**【推演】
- FF: **+1** (start_ack_d1)。**无新增数据寄存器** (所有操作数已是 `ctrl_*` 寄存器)。
- LUT/CARRY8: 加法树的操作数从"读 mux 输出"换成"FF 输出", **规模不变**; 被删除的是加法树对读总线的 ~15 组负载 ⇒ 净 LUT 方向 = 持平到略减; 读总线三条大扇出网 (`fo=237/104/17`, `fam_S3_B_exact.rpt:71,77,83`) 直接**减轻负载**。
- 控制集: 新 CE (`start_ack_d1`) ⇒ **+1 control set** (S3 = 2,873 个, 有空间)。
- 时序语义: 见下。

**逐拍论证 (值不变 + 读点余量)** —— 全部依据源码行号:

1. `start_ack` 在拍 **T** 拉高 (`:472-473`) ⇒ 槽装载块 `:852-869` 在 **T+1** 写入 `ctrl_*` (含 `ctrl_seq/ack/doff/wnd/dport/sport/dip/idcap`)。【事实: `:852-869`】
2. 此刻下述**恒等式**成立 (写点用的值 == 我要复算的值):
   - `ctrl_seq`  = `rb_snd_nxt` (`:857`), `ctrl_ack` = `ctrl_ack_now` (`:858`), `ctrl_doff` = `ctrl_doff_now` (`:859`), `ctrl_wnd` = `rb_rcv_wnd` (`:860`), `ctrl_dip` = `cam_rd_sip` (`:862`), `ctrl_sport` = `cam_rd_dport` (`:863`), `ctrl_dport` = `cam_rd_sport` (`:864`), `ctrl_idcap` = `id_r` (`:865`) —— **即旧 `ctrl_tcpcsum_now`/`ctrl_ipcsum_now` 的全部操作数**【事实, 逐行对读 `:582-595` vs `:855-867`】。
   - ⚠️ 唯一需要辨的是 `id_r`: 旧式 `ip_csum_calc(16'd40, id_r, cam_rd_sip)` 用的 `id_r` 是 **T 拍值**; `ctrl_idcap <= id_r` (`:865`) 后, `ctrl_idcap` 在 T+1 起 = 同一个值 ⇒ **等价**【事实】。
3. `start_ack_d1` 在 **T+1** 拉高 ⇒ 新装载发生在 **T+2**; 由于 `ctrl_slot_busy` 在 T+1 置位 (`:853`) 且直到该帧 `T_DONE` 才清 (`:1035`), **T+1 拍的 `start_ack` 恒为 0** (`:472-473` 的 `!ctrl_slot_busy`) ⇒ **不会有第二次装载与新值竞争**【事实】。
4. **消费侧最早读点**: `h_tcpcsum` 只在 `:967` (`thcnt==5`) 被读进 `hold48`; `h_ipcsum` 只在 `:961` (`thcnt==3`) 被读。TX 引擎进入 `T_HDR` 只有两条路 (`:944-947` T_IDLE / `:1051-1053` T_DONE 边界), 而 `ctrl_tx_pend` 最早在 **T+1** 才置位 (`:854`) ⇒ `T_HDR` 最早在 **T+2** 进入, `thcnt` 从 0 起 (`:946/:952`) ⇒
   - `ctrl_ipcsum` 最早读点 = **T+5**; `ctrl_tcpcsum` 最早读点 = **T+7** (`:952-971` 的 thcnt 序列)。若 `m_axis` 反压 (`:953`), `thcnt` 不动 ⇒ 只会更晚。【事实, 逐行读 TX 引擎】
   - ⇒ 新装载 (T+2) 到两个读点的余量 = **3 拍 / 5 拍**; 旧装载 (T+1) 是 4/6 拍。
5. **背靠背控制帧**: 下一帧的 `start_ack` 必须等本帧 `T_DONE` 清 `ctrl_slot_busy` (`:1035`), 而 `T_DONE` 必然晚于 `thcnt==5` 读点 ⇒ 下一帧的新装载 (其 `start_ack+2`) 必然晚于本帧的读点 ⇒ **无覆盖竞争**【推演, 基于 `:1030-1058` 的状态序】。
6. **不碰的契约**: 仲裁键 `ctrl_tx_pend` (`:854/:947/:1053`)、槽独占 `ctrl_slot_busy` (`:853/:1035`)、TCB 推进写 `upd_wr_ctrl` (`:488`) 与三写源 `$onehot0` (`:480-497`)、`start_ack` 对 `u_ackq` 的 `rd` (`:680`)、`s_axis_tready`/`start_data` 门 (`:511-519`) —— **一行都不动**【事实】。
   ⇒ **结论: 本改法把"装载拍"从 T+1 挪到 T+2, 值逐位不变, 对唯一两个读点的余量由 4/6 拍降为 3/5 拍 (仍 ≥3), 无任何握手/仲裁/记账变化**【推演 + 事实】。

**WNS 预期方向**: 正向。理由: 被移出 D 锥的是**前端 7–11 级**(§1.3 实测 S3=7 / A=11) + 三条 `fo=104–237` 大扇出网的负载; 剩下的是 11–12 级纯算术, 且操作数变成同批装载、可被就近布局的 `ctrl_*` 寄存器。**幅度不给数字**【需综合才能定】, 且判据应是"**旧族从关键清单消失**"而不是"WNS 涨了多少"(因为该族消失后 WNS 会被**另一条无关族**顶住, 见 §1.5 次族清单; S3 档次族 = 0.141, 所以**该档可拿到的 WNS 上界 ≈ +0.141, 若新路径比它好**)【推演】。

**风险 (须在下一轮如实核)**:
- ⚠️ "最早读点 T+5/T+7"依赖 `T_HDR` 只能从 `:944/:1051` 两处进入 —— 若下一轮有人新增第三条进 `T_HDR` 的路径, 本论证作废 ⇒ **建议同批加一条 TB 断言** ("`ctrl_tcpcsum` 被读的拍 − 其装载拍 ≥ 3")。
- ⚠️ 新路径 (11–12 级算术 + FF 间布线) 是否真的 < 6.4 ns —— **需综合**。

### 2.2 R-2「两拍拆分」(备选, 不推荐首选)

在 R-1 基础上把加法树切两段: T+2 先算"静态组"部分和 (`cfg_src_ip` 两半 + `ctrl_dip` 两半 + 常数 + `ctrl_dport/sport` + `ctrl_seq[31:16]`) 寄存, T+3 再加余项 + `fold16` 出 `ctrl_tcpcsum`。
- 代价: +1 FF (1 位) + ~20 FF (部分和寄存器)。
- 语义: 值不变; 但 `ctrl_ipcsum` 读点在 **T+5**, 若它也走两拍 ⇒ 装载落在 **T+4**, 余量只剩 **1 拍**(而 `ctrl_tcpcsum` 读点 T+7 ⇒ 余量 3 拍)⇒ **只建议对 tcpcsum 走两拍、ipcsum 走一拍**; 混用会让两族拆开, 收益/复杂度比变差。
- 判据: 同 R-1, 且必须加"读点−装载拍 ≥ 1"断言。

### 2.3 (a) 「打断共享: 拆成两个独立寄存器位」—— **结构性不适用**【事实】

理由 (三层, 全部落在源码上):
1. D 端只有一个写点与一个表达式 (`:867` ← `:594`), 16 个 bit 是**同一条 16 位加法结果**的不同位 ⇒ 任何"分位/分组"都会改变数值 (不是重构, 是改错)。
2. 四源不是 D 的**数据**输入, 而是 `rb_id` 的**选择位** (`:501-503` 引用的 `svc/ring_eval/scan_now/(rx_state==RX_IDLE)`, 定义在 `:426,:464-471`) ⇒ 把寄存器拆开只是给同一只 mux 多几条选择线。
3. 真正意义上的"打断共享"= 让校验和不再依赖共享读总线 —— 那**就是 R-1** (把源换成各自专有的 `ctrl_*` 寄存器)。
⇒ 建议下一轮**不要**在 (a) 上花构建。

### 2.4 (c) 复制寄存器 + 就近布局 —— 只治 route, 不治级数【事实】

- 证据 1: 工具自己就在做 (phys_opt 复制 `ack_pend_r`, `S1/p7b_ku5p_stdout.txt:4430`), 而**复制件本身成了 S1 档该宿的 startpoint** (24 级, `t3_stdout_S1.txt`), R1 档更是复制出 3 份 (`t3_stdout_R1.txt:97`) 且其在 `u_tcb/snd_wnd` 宿上 −0.035 (该档 WNS)。
- 证据 2: S3 档该路径 route 占 **59.9%** (3.687/6.158 ns, `S3/READINGS.txt:78`) ⇒ route 确实是一阶项, 但复制改变的是**谁在链上**, 不减级数。
- 可做的最便宜形式: 对三条大扇出网设 `MAX_FANOUT` (属性, 无 RTL 改动), 或手工给 `bank_rdy[rx_bank]`/`ack_pend_r` 加一份**同一逻辑域内**的复制。**收益未量**; 若与 R-1 同批, 收益会被 R-1 淹没 ⇒ 建议**不要**同批 (一次构建收口原则: 只改一件事才能归因)。

### 2.5 (d) 降低组合深度 / 预计算

- **(d-1) 把选择条件提前一拍寄存 —— ⛔ 会改行为, 禁止** (§3-#1, #2)。
- **(d-2) 预计算准静态项**: `csum_init_val` 里的 `cfg_src_ip[31:16]+cfg_src_ip[15:0]` 是准静态 (板级 IP 常数), 可寄存成一项 ⇒ 省 1 个 16 位加法 (12 级里 1 级)。代价 +16 FF + 一条"cfg 变化时更新"的路径 (cfg 是端口, 变化语义**未定**)。**收益/风险比不划算, 不建议单独做**; 若 R-1 落地后仍不够, 再考虑。
- **新想法 (未列入上表, 供参考)**: R-1 落地后, `ctrl_*` 组内已有 `ctrl_dport`/`ctrl_sport`/`ctrl_doff` 等**准静态**字段 (每帧才变一次), 可以把"每帧只变一次的部分和"进一步寄存 —— 但这会引入跨帧的新状态, **不建议**在没有 TB 断言的情况下做。

### 2.6 R-3「专用读口」—— 备选 (收益小于 R-1, 代价大于 R-1)

思路: 控制帧校验和所需的 6 个读信号另起一套 mux, 地址直接接 `start_id` (`:438`) 而不是 `rb_id` (`:501`)。
- 前提 (可从源码证): 在 `start_ack` 拍, `ack_pend_r==1` ∧ `rx_state==RX_IDLE` ∧ `recv_first==1` ⇒ `svc=ring_eval=scan_now=0` ⇒ **`rb_id ≡ start_id`** (`:464-471` 全被 `!ack_pend_r`/`rx_idle` 关掉; `:501-502` 落到 `(rx_state==RX_IDLE) ? start_id`)【推演, 需 TB 断言固化】。
- 代价: 复制 16:1 mux 144 bit (snd_nxt 32 + rcv_nxt 32 + rcv_wnd 16 + sip 32 + dport 16 + sport 16) ≈ **250–400 LUT** + CAM 读口 (64 bit) 复制 ≈ +120 LUT。
- 收益: 省掉**选择段** (S3 档约 3–4 级; A 档约 5 级), **保留组合读段** ⇒ 明显小于 R-1。
- ⇒ 若 R-1 因故不可行 (例如 TB 断言不成立), 这是退路。

---

## §3 ⛔ 不能做的边界 (改行为清单 —— 下一轮下构建决策要用)

> 判定口径: "改行为" = 在**任意激励**下改变线上字节 / 状态机可达状态 / 记账值。下列各条**逐条点名**。

1. **【会改行为·禁止】把 `rb_id` 的选择条件 (`svc`/`ring_eval`/`scan_now`/`rx_idle`) 提前一拍寄存**。理由: 这些条件是**本拍**寄存器 (`rx_state`/`recv_first`/`ack_pend_r`/`retx_active`/`bank_rdy`) 的函数 (`:426,:464-471`); 寄存后表达的是**上一拍**的判定 ⇒ 地址指向错误的 TCB 槽 ⇒ 帧头取错连接的 `seq/ack/wnd` ⇒ **线上发错帧, 且不触发任何握手判据**(静默)。
2. **【会改行为·禁止】用 `!ackq_empty` 直接替代已寄存的 `ack_pend_r`** (`:760` 的那一拍延迟) 来"提前"地址。理由: `ack_pend_r` 同时是 `rb_id` 选择 (`:501` 附近, 经 `svc/ring_eval/scan_now/start_ack`)、`upd_wr_ctrl` (`:488`) 与 `s_axis_tready` (`:511-515`) 的门; 提前一拍会改 FIFO pop 与 TCB 写口 `$onehot0` 的时序关系。
3. **【会改行为·禁止】把 TCB 读口改成"寄存读"(pipelined read)**。理由: `rb_*` 在**同一拍**被至少 20+ 处消费 (`:476,:495-497,:538,:545-547,:560,:656-663,:769-776,:838-846,:857-860,:875-885,:921-922`), 全部要跟着改 ⇒ 这是**重架构**, 不是一刀。
4. **【会改行为·禁止】"提前一拍把 TCB 读结果预装进 `ctrl_*`"**。理由同 #1: T−1 拍 `rb_id` 不是 `start_id` (那时 `ack_pend_r` 可能为 0, `:501` 会选到 `svc_id/retx_id_r/scan_id/f_conn`) ⇒ 取到**别的槽**的值; 最坏形态 = **静默发出错误校验和的合法帧**。
5. **【会改行为·禁止】把校验和装载延迟拉长到 3 拍以上**。理由: `ctrl_ipcsum` 最早读点在 **T+5** (`:961`, thcnt==3), 装载若落在 T+5 或更晚 ⇒ 读到上一帧的旧值 ⇒ 静默错校验和。**时间预算: tcpcsum ≤ 5 拍 / ipcsum ≤ 3 拍** (§2.1 推导)。
6. **【会改行为·禁止】让 `ctrl_*` 的装载与 `ctrl_tx_pend`/`ctrl_slot_busy` 脱钩** (例如"先弃槽再装数据"或"用 pend 的下降沿当装载使能")。理由: 三者的关系是设计里写死的契约 (`:253-255` 头注释: `pend ⊆ busy`, 槽跨拍独占 C7/C8), 破坏后会出现 `issued > transmitted` (TB J6) 或控制帧在 `T_HDR` 中段被换头 (C8)。
7. **【禁止】在 `start_ack` 拍"同拍发帧"** (跳过 T+1 的 `ctrl_*` 装载)。理由: `m_axis` 头字段来自 `ctrl_*` 寄存器 (`:601-611`), 同拍发帧会让 `T_HDR` 读到**上一帧**的头。
8. **【不需要·但注意】不能把 `f_tcpcsum`(数据帧)与 `ctrl_tcpcsum`(控制帧)合并**: 前者由 `checksum16 u_csum` 在 `RX_FIN` 的 5 拍 `csum_aen/csum_fin` 序列产生 (`:570-580,:646-653,:920`), 是**流式校验和**; 后者是 `start_ack` 拍的**组合树** (`:582-595`) ⇒ 两条契约不同 (FIX-2' 明确"控制帧不占 checksum16、不占 RX 引擎", `:250-252` 头注释)。

### §3-附: 与三条既有契约的关系 (任务 §3-6 的正面回答)

| 契约 | 落点 | R-1 是否触碰 | 依据 |
|---|---|---|---|
| **帧内校验和并行计算** (`csum_aen/csum_fin` 落在 `RX_FIN` 的 5 拍内, `:570-580`) | 数据帧/重放帧的 TCP 校验和 | **不碰** —— 控制帧走的是**另一条**组合树 (`:582-595`), 两条只在 `h_tcpcsum` 的 mux (`:603`) 汇合, 而 mux 选择位 `tx_is_ctrl` 与装载路径无关 | `:570-603`,`:916-931` |
| **`snd_nxt` 推进** | `upd_wr_*` 三写源 (`:487-497`), 控制帧的 +1 由 `upd_wr_ctrl` 在同拍预留 (`:488`) | **不碰** —— R-1 只改 `ctrl_tcpcsum/ctrl_ipcsum` 两个**数据寄存器**的装载拍, 不改 `upd_*` 任何一位 ⇒ `$onehot0` 不变量保持 | `:480-497` 头注 |
| **`bank_rdy` 握手** (乒乓 bank 交棒 `:923,:1047-1048`) | bank 级握手 | **不碰** —— 控制帧不走 bank (`tx_is_ctrl` 分支 `:1033-1045`) | `:1029-1058` |

⚠️ 唯一被 R-1 触碰的是"`ctrl_*` 装载拍 ↔ `T_HDR` 读点"的时间关系 —— **已论证 ≥3 拍余量** (§2.1-4/5), 且**建议用 TB 断言把它变成可判的**(§4.3)。

---

## §4 判据与验证计划

### 4.1 该刀生效的判据 (**看隔离度, 不只 WNS**)

1. **主判据 A (族消失)**: 新构建的 top-N 清单里 **`u_tcp_tx/ctrl_tcpcsum_reg[*]/D` 与 `u_tcp_tx/ctrl_ipcsum_reg[*]/D` 两个宿全部消失** (S3 档今日各 16 个端点, `worst2000_S3.txt`)。这是**二值判据**, 不受"同名 WNS 是不同对象"影响 (#66)。
2. **主判据 B (定向查询降级)**: 用 `-from u_tcp_tx/retx_active_reg/C -to u_tcp_tx/ctrl_tcpcsum_reg[14]/D` 与 `-from u_tcp_tx/FSM_sequential_rx_state_reg[0]/C -to ...` **逐族定向查询** (不要只读清单): 预期新路径的 startpoint 变成 `ctrl_*` 寄存器族、级数从 19–22 降到 ~11–13。
3. **主判据 C (隔离度)**: 报告"**本刀新 WNS 到次族的距离**" —— #66 口径: 隔离度 = 该档 WNS 到**下一个不属于本刀的族**的最小 slack。⚠️ 提醒: 本刀若成功, 新 WNS 大概率**由次族顶住** (S3 档次族 = `u_udp_tx/ip_csum_r_reg[*][*]/D` 0.141; A 档次族 = `u_tcb/snd_nxt_r_reg[3][*]/CE` 0.047) ⇒ **不要把"WNS 只涨了 0.03"读成"刀没生效"**, 要用判据 A/B 判生效, 用 C 判"还剩多少".
4. **回归判据**: `board/check_p6e_timing.py` 对 `p7b_ku5p_timing.rpt` → 三类失败端点 **0/0/0** + `Slack (VIOLATED)` 块 0 条 (`S3/READINGS.txt:24-34` 是现役口径) + bat 硬门 (12-4739 / Synth 8-11241 / VRDC… 见 `A/READINGS.txt:14-18`)。
5. ⚠️ **一次构建收口** (工程纪律 + A 档只有 0.33% 余量): 本刀**只动 `rtl/tcp_tx_frame.v` 一处语义**, 不得与别的 RTL 改动同批 (否则归因不可判; 参考 `P7B_LOOP_HANDOFF.md` §4 的 #57)。构建后**归档进构建脚本本身** (#54: `create_project -force` 会摧毁上一轮取证)。

### 4.2 ⚠️ 必须修的门: `run_tx_ovl_gate.bat` (今天产出**零证据**)

- 【事实】现状: `sim/p7b_stagec_tx_regress/author_gate/mut_gen.log` = **`MUTGEN FAIL 5`**; 闸在 `:29` 就 `|| (... & exit /b 1)` ⇒ **A/B 正控与 9 条变异一条都没跑**, `runA..K/` 里的日志全是 2026-10-07 的旧物。
- 【事实·本轮实测】逐锚点命中数 (工作树 CRLF vs `HEAD` blob 归一化成 LF):

  | 锚点 | worktree(CRLF) | LF 版 | 判定 |
  |---|---|---|---|
  | mut_s0a / c1 / c3 / c6 / c9 | 1 / 1 / 1 / 1 / 2 | 同 | ✅ 可用 |
  | **mut_s0b** (默认分支 `upd_val`) | **0** | **1** | 纯 CRLF |
  | **mut_c7 / mut_c8** (`start_ack` 两行锚点) | **0** | **1** | 纯 CRLF |
  | **mut_c2 锚点 2/3** (`upd_id` / `upd_val`) | **0** | **0** | **陈旧** —— 锚点文本写于 RETXFIX **之前**; 现役文本多了 `(replay_jump ? retx_id_r : svc_id)` / `(replay_jump ? retx_hi : rb_snd_una)` 一层 (`:491-497`), 且行尾也不同 |

- 【事实】病根与源码无关: 工作树 125,620 B / CR 2,040; blob 123,580 B / CR 0; `core.autocrlf=true` ⇒ **每次 `git checkout` 都会把 CRLF 带回来** ⇒ **必须修变异器 (归一化), 不能只"把文件转成 LF"**。
- 【事实】另一个地雷: `mk_mut_tx.py:105-113` 在锚点不命中时只 `continue`, **仍把"半套用"的变异件写盘** (磁盘上 `mut_c2.v` = 只套用了第 1 条替换 ⇒ 与声明的 M-C2 语义不符)。**修 gate 时必须顺手堵住** (不命中就不写 / 写完删除)。
- **修法 (≈10 行, 只动 `sim/`, 不碰 RTL)**:
  1. `mk_mut_tx.py:17` 读入后加一行 `src = src.replace("\r\n", "\n")` (写盘保持 `newline=""`);
  2. 按 `:491-497` 的现役文本改写 `mut_c2` 的锚点 2/3 (保留"三件套一起延 8 拍"的声明语义);
  3. 锚点不命中时**不要写盘**(或写完删掉);
  4. 重跑: 期望 `MUTGEN OK (11 mutants)` → A/B `RC=0` / C..K `RC≠0`。
- **要不要修它才能验本刀?** —— **要**。理由: 本刀的风险面 (控制帧校验和 + 槽记账) 正好是**只有这个 TB 检查**的两件事:
  - 【事实】`tb/tb_tcp_tx_ovl.v:10-19` = J2 `J_csum` **从线上字节独立复算 IP(偏移 24)/TCP(偏移 50) 校验和** (`:423-440` 实现) · J6 控制帧守恒 `issued==transmitted` (`:1315-1325`) · J5 `snd_nxt` 只准前向 · J4 seq 连续。
  - 且变异集里的 **M-C2**("预留写滞后 8 拍") 与 **M-C7/M-C8**(槽独占/`rx_idle` 门) 就是本刀**同类改动**的负对照 ⇒ 门修好后它们能给"这一族改动有牙"的**直接灵敏度证明**。
  ⚠️ 但注意: 门修好只能证明**单元 TB 面**; 它**不覆盖 wrapper 级接线** (见 §4.3)。

### 4.3 门清单 (点名 + 覆盖缺口)

| 门 | 覆盖 | 本刀是否必须 | 备注 |
|---|---|---|---|
| `sim/p7b_stagec_tx_regress/author_gate/run_tx_ovl_gate.bat` | `tcp_tx_frame.v` **OVL 分支**单元级 (A/B 正控 + 9 变异) | ✅ **必修 + 必跑** (§4.2) | 今天不可跑 |
| `sim/p5wu_p1p2/run_xvlog_wrapper63.bat` | **板级真实宏组合 {DP_156MHZ+TCP_TX_OVL} 的编译面** (t4 臂, `:21-27`) | ✅ 建议 | 只证"编得过", 不证功能 |
| `sim/p4gates/run_matrix_p4dfix.bat` (P4 16 门) | `rtl/tcp_tx_frame.v` **在 manifest 内** (`sim/p4gates/chain_src.f` 第 10 行) —— 但走的是**默认分支** | ⚠️ 必跑(防回归), **不能替代** OVL 门 | 默认分支 ≠ 上板分支 |
| `sim/p5sim/run_tb_p5_wrapper.bat` 等 P5 全链门 | 真 wrapper (`APP_MODE`), 亦为**默认分支** | 建议跑 | ⚠️ **覆盖缺口**: 全仓没有"OVL 分支 × 真 wrapper × 功能 TB"的门 (只有编译面 t4) —— 这一点本轮未改, 如实登记 |
| `sim/p5sim/run_tb_p5_app.bat close` / `sim/p5close/run_tb_tcp_close.bat` | FIN/RST 关闭语义 (控制帧路径的旁证) | 建议跑 | 控制帧的**语义**面 |
| 板级 | 建议: 本刀**先只在构建+时序面收口**, 上板按用户裁量 (行为面已由 R-1 的逐拍论证 + 门覆盖) | — | — |

### 4.4 本刀落地时的标准动作 (照抄即可)

1. 改 `rtl/tcp_tx_frame.v` (§2.1 三处) —— **只此一件**。
2. `git -C udp_hls_10g status` 确认改动面; 记录 `sha256` (输入指纹)。
3. 修 `mk_mut_tx.py` (§4.2) 并**先跑门** (门是快反馈; 门红 ⇒ 不构建)。
4. 一次构建 (`board/run_build_p7b_ku5p.bat`; 宏表**不动**, `TCP_TX_OVL` 保持 `:153` 现状) + 归档。
5. 判据: §4.1 的 A/B/C + 三类失败端点 0/0/0。
6. 若 WNS 由次族顶住 ⇒ **不要把本刀报成"没效果"**, 按 §4.1-3 的口径写。

---

## §5 未定 / 判不了 (**不许写成结论**)

| # | 待测项 | 为什么本轮定不了 | 需要什么 |
|---|---|---|---|
| 1 | R-1 落地后的**实际 WNS / 新最差族** | 纯设计件, 未综合 | 一次构建 |
| 2 | R-1 新路径 (FF → 11–12 级加法树 → FF) 的实际级数与 delay | 同上 | 同上 (+ `-from ctrl_*_reg` 定向查询) |
| 3 | **S3 档** `FSM_sequential_rx_state_reg[0] → ctrl_tcpcsum[14]/D` 的 slack | t3 只定向查了 `bank_rdy`/`retx_active`/`recv_first`;**藏族**使其在清单里隐身 | 一条 `-from` 查询 (现成脚本可跑) |
| 4 | **S3 档** `ack_pend_r_reg`(无 replica 名) 在该宿的 slack | 同上 **未量** | 同上 |
| 5 | 次族的机制 (`bank_rdy`/`retx_active` → `u_app/stg_reg[*]/CE` 与 `u_tcb/snd_wnd_r_reg[*]/CE` 走哪条路) | 只读到"存在且很紧", 未做源码/报告级溯源 | 读路径块 + 定向查询 |
| 6 | R-1 是否**真的**不改行为 (端到端) | 逐拍论证是设计面证明; TB 断言尚未写 | 修好的 tx_ovl 门 + 新增"读点−装载拍 ≥3"断言 |
| 7 | 变异集 C..K 修好后是否全红 (门有牙) | 门坏, 今天跑不了 | 修门 + 跑 |
| 8 | (c) 复制/`MAX_FANOUT` 的单独收益 | 未做 | 一次构建 (建议不与 R-1 同批) |
| 9 | (d-2) 预计算 cfg 项的收益; 综合器是否已常量传播 `cfg_src_ip` | 未做 | 综合后读路径/资源 |
| 10 | 2²⁹ / 2³⁰ 档是否落在同一宿族 | 阶梯未跑 (`S_LADDER.txt` 未测清单) | 换常量构建 (⚠️ 按 #64 常量本身就影响时序) |
| 11 | `u_udp_tx/ip_csum_r_reg[*][*]/D` 族 (S3 次族 0.141 / Stage A 的 WNS) 的改法 | **不在本件任务面** | 另立设计件 (形态疑似同族: 组合读 + 加法树) |
| 12 | 本刀对 **rest of the 家族** (32 个 csum 端点) 中 `ctrl_ipcsum` 侧的收益 | 未量 | 同上 |

---

## 附 A: 本件用到的归档件清单 (可复现)

| 用途 | 路径 |
|---|---|
| S3 全量读数 | `_proj_10g/notes/p7b_build_longflow/S3/READINGS.txt` (+ `SHA256SUMS.txt`) |
| S3 最差路径**全文块** | `_proj_10g/notes/p7b_build_longflow/_t3_family/out/S3/fam_S3_B_exact.rpt` |
| S3 六族定向查询 + 细胞普查 | `…/_t3_family/out/S3/t3_stdout_S3.txt` |
| S3 两千条族普查 (隔离度) | `…/_t3_family/out/S3/worst2000_S3.txt` |
| C1/S1/S2/R1 四档族查询 | `…/_t3_family/out/{C1,S1,S2,R1}/t3_stdout_*.txt` |
| 五档阶梯表 + 决策 | `_proj_10g/notes/p7b_build_longflow/S_LADDER.txt` |
| A 档读数 (WNS 族 + 前 9 条) | `_proj_10g/notes/p7b_build_longsend/A/READINGS.txt` |
| A 档最差路径**全文块** | `_proj_10g/notes/p7b_build_longsend/A/wrapper_p4_timing_summary_routed.rpt` (行 13421–13536) |
| phys_opt 复制证据 | `_proj_10g/notes/p7b_build_longflow/S1/p7b_ku5p_stdout.txt:4430,4638` |
| 门现状 | `sim/p7b_stagec_tx_regress/author_gate/{run_tx_ovl_gate.bat,mk_mut_tx.py,mut_gen.log}` |
| TB 内容判据 | `tb/tb_tcp_tx_ovl.v:10-19,423-440,1315-1325` |
| 宏表 / 编译面配方 | `board/build_p7b_ku5p.tcl:153` · `sim/p5wu_p1p2/run_xvlog_wrapper63.bat:21-27` |
| 基线表 (跨档可比性陷阱) | `README.md:455-472` |

## 附 B: 与本件的口径关系

- **全局 #66** (清单藏族 / WNS 是不同对象): §1.4/§1.5/§4.1 直接按它写 —— 本件的"四源核对"就是它的一次应用。
- **全局 #64** (改常量会确定性改变网表/时序): 本刀**不是**常量改动, 是语义等价的结构改动 ⇒ 仍必须"一次构建收口 + 三类端点复核"。
- **全局 #57** (改 RTL 与在跑回归互斥): §4.4 的步骤 2/3/4 之间不得并发跑门。
- **全局 #54** (每次构建摧毁上一轮取证): §4.1-5 归档要求。
- 本件的**裁定权不在作者**: §2 的推荐、§3 的禁区、§4 的判据都需下一轮构建/用户裁定后才能写成"已验证"。
