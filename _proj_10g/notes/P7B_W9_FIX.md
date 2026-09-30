# P7B_W9_FIX —— `app_udp_pattern` TX 字 FIFO 空间门一拍错位：修复 + 归零 + 同类普查

**一句话根因**：`rtl/app_udp_pattern.v` 的 TX 字 FIFO（`u_txf`）写口，**推送请求 `txf_wr` 是寄存器
（本轮决定、下拍落笔），却拿本拍的 `txf_full` 做空间门** ⇒ FIFO 饱和那一拍，一笔**已加进
`stat_tx_bytes`、已算进 `seg_sent`** 的推入被 FIFO 静默丢弃（`.wr()` 还把门预 AND 进去，
使 FIFO 内部的 `ovf_pulse` 结构性恒 0 ⇒ 丢字无任何计数器可见）。

> 上游定案件 = `P7B_W9_GAP.md`（只读调查，六档对照 + 板级判据）。本笔记 = 修复实施 + 验证。
> 本轮**未构建**（`vivado_prj/` 未碰），构建留下一轮。

---

## 1. 改了几处（逐处）

**4 处逻辑改动 + 5 处注释/文档**（`rtl/app_udp_pattern.v`，全部在 `P7B_10G` 宏之外，
即两种构建共用同一份代码）。

### L1 `:485` 声明（新增两根线）

```verilog
-    wire        txf_empty, txf_full;
+    wire        txf_empty, txf_full, txf_full_n, txf_ovf_pulse;
```

### L2 `:499-503` `u_txf` 例化：去预 AND + 接回 `full_next` / `ovf_pulse`

```verilog
-        .wr(txf_wr && !txf_full), .din(txf_in),
+        // P7B-W9: 空间门**移到生产者侧** (gen_ok / nul_push 判 `txf_full_n`)。
+        //   这里**不再**预 AND `!txf_full` —— 旧写法把 FIFO 内部的
+        //   `ovf_pulse = wr && full` **结构性地**钉成 0，于是"拒写"自检回路失效。
+        .wr(txf_wr), .din(txf_in),
         .rd(txf_rd), .dout(txf_out),
         .empty(txf_empty), .full(txf_full),
+        .full_next(txf_full_n),         // 空间门 (生产者侧) 用这个
+        .ovf_pulse(txf_ovf_pulse),      // 拒写脉冲 (自检; 恒 0 = 无静默丢失)
         .dbg_wptr(), .dbg_rptr(), .dbg_full(), .dbg_empty()
     );
```

### L3 `:540` `gen_ok` 空间门

```verilog
-    wire        gen_ok  = (txs == T_FRM) && !txf_full && !nul_pend &&
+    wire        gen_ok  = (txs == T_FRM) && !txf_full_n && !nul_pend &&
                           (seg_sent < seg_len);
```

### L4 `:545` `nul_push` 空间门（0 长数据报路径，同一个错位）

```verilog
-    wire        nul_push = (txs == T_FRM) && nul_pend && !txf_full;
+    wire        nul_push = (txs == T_FRM) && nul_pend && !txf_full_n;
```

### L5 `:518` + `:759` + `:869-870` 自检回读 `stat_tx_ovf`（**可见性**）

```verilog
+    reg  [31:0] stat_tx_ovf;                       // :518
+    stat_tx_ovf <= 32'd0;                          // :759  (复位)
+    if (txf_ovf_pulse) stat_tx_ovf <= stat_tx_ovf + 32'd1;   // :870
```

**注释/文档**（不改语义）：`:43-47`（头注释里"app 已发 = app 已交付"那条等式加订正 ——
它正是本缺陷能藏在 `W9` 背后的原因）、`:475-483`（写口合同）、`:493-498`、`:507-517`（自检回读的
用法与板级可见性缺口）、`:539`。

### 为什么 L3/L4 与 L2 是**同一个**修复，不能只做一半

- 只做 L3/L4（改用 `full_next`）⇒ 线上不再丢字，但 `ovf_pulse` 仍是结构性哑的（L2 的预 AND 还在）
  ⇒ **下次判据回归时没人会知道**。
- 只做 L2（去预 AND）⇒ 丢字照旧，只是变成"有计数器的丢字"。
- 两件一起：**不变式** `txf_wr(T) ⇒ !txf_full(T)` 成立（置位它的 `gen_ok`/`nul_push` 都要求
  `!full_next(T-1)`，而 `full_next(T-1) == full(T)`）⇒ 此时 `wr(txf_wr) == (txf_wr && !txf_full)`
  **逐笔等价**（写口行为与修前**完全相同**）；而一旦判据回归本拍 `full`，`ovf_pulse` **真的会响**
  （见 §4 负对照实测：54 / 85）。

---

## 2. 为什么**默认构建**（未定义 `P7B_10G`）不受影响

两条独立论据，一条解析、一条实测：

1. **解析**：`full_next` 与 `full` 只在"本拍有在飞写 **且** 占用已达 `D-1`"时分歧。默认构建走
   1 字节/拍路径：app 产能 = **1 字 / 8 拍**，而帧器排空 ≈ 1 字/拍 ⇒ 字 FIFO 占用长期只有个位数
   （实测 `occ_max = 24 / D = 256`）⇒ 结构性够不到 `D-1` ⇒ 两判据**恒同值**。
   （1G 时代（P6b 956 Mbps）看不到这个缺陷，同一条理由。）
2. **实测（逐位等价）**：默认构建下"修前 vs 修后"跑同一个台架，**输出流指纹逐位相同** ——
   `def_prefix` 与 `def_postfix` 都给出 `HASH out=32c4728eed7bf651 full=32c43d1eed7bf65c`，
   且 13 帧全 1514 B、`stat_tx_bytes=20368 = land_bytes`、`occ_max=24 / full_cyc=0` 逐项相同。

> ⚠️ 严格说这是"两种构建共用的那段逻辑"的等价；`P7B_10G` 分支本身**有意改变行为**（+8 B/帧），
> 那不是回归，是本轮修复的目标。

---

## 3. 验证证据（反例双跑）

台架（本轮新建，**未写进** `_tmp_w9probe/`）：
`_proj_10g/notes/p7b_w9fix/{tb_w9fix.v, run_case.sh}`；被测两份 RTL 冻结在 `mut/`：

| 文件 | 是什么 | md5 |
|---|---|---|
| `mut/app_udp_pattern_prefix.v` | `git show HEAD:rtl/app_udp_pattern.v`（修前） | `20137a9b7777ffaafdf8d365350e0db7` |
| `mut/app_udp_pattern_postfix.v` | 修复后的 `rtl/app_udp_pattern.v` 冻结副本 | `ecc5319fafbe5f92ae4e9c7b9a86f8e5` |
| `mut/app_udp_pattern_ovfctl.v` | **负对照**：修复后的接线 + 只把 L3/L4 退回本拍 `full` | `c3a2ded572666e8c24501ae5afe580b7` |

⭐ **交付件 `rtl/app_udp_pattern.v` 的 md5 = `ecc5319fafbe5f92ae4e9c7b9a86f8e5` = 上表 `postfix` 冻结副本**
⇒ 判据表里所有"修后"的读数，跑的就是本次交付的那份源码（逐字同一文件）。
每个 run 目录的 `cmd.txt` 也记了当时的 `SRC` 绝对路径与 md5。

台架链路 = `app_udp_pattern(i_paylen=1472) → udp_tx_cfg → udp_tx_frame → sink(恒收)`；
`-testplusarg STALL` ⇒ 下游每 8 拍停 1 拍（帧器比 app 慢 ⇒ FIFO 长期饱和 = **板级工况**）。
判据：`land_bytes` = 落笔字的 `Σpopcount(tkeep)`（= 真正进 FIFO 的载荷字节）；
`pushdec` = 推送决策拍数；`landed` = 真落笔拍数（`txf_wr && !txf_full`）。

```sh
cd _proj_10g/notes/p7b_w9fix
sh run_case.sh def_prefix        mut/app_udp_pattern_prefix.v   ""
sh run_case.sh def_postfix       mut/app_udp_pattern_postfix.v  "-d POSTFIX"
sh run_case.sh p7b_prefix        mut/app_udp_pattern_prefix.v   "-d P7B_10G -d UDP_TX_OVL"
sh run_case.sh p7b_postfix       mut/app_udp_pattern_postfix.v  "-d P7B_10G -d UDP_TX_OVL -d POSTFIX"
sh run_case.sh p7b_prefix_stall  mut/app_udp_pattern_prefix.v   "-d P7B_10G -d UDP_TX_OVL" -testplusarg STALL
sh run_case.sh p7b_postfix_stall mut/app_udp_pattern_postfix.v  "-d P7B_10G -d UDP_TX_OVL -d POSTFIX" -testplusarg STALL
sh run_case.sh ovfctl            mut/app_udp_pattern_ovfctl.v   "-d P7B_10G -d UDP_TX_OVL -d POSTFIX"   # 负对照 (+ -testplusarg STALL)
```

### 判据表（日志 = `run_<档>/xsim.log`）

| 档 | `stat_tx_bytes − land_bytes` | `pushdec − landed` | `ovf_pulse` / `stat_tx_ovf` | 帧器输出 `len` | **头字段 `udp_len`** / `ip_tot` | 输出流指纹 |
|---|---|---|---|---|---|---|
| `def_prefix` | **0** | **0** | 0 / — | 13×**1514** | **1480**×13 / 1500×13 | `32c4728eed7bf651` |
| `def_postfix` | **0** | **0** | 0 / 0 | 13×**1514** | **1480**×13 / 1500×13 | **同上，逐位相同** |
| `p7b_prefix` | **432** = 8×54 | **54** | 0 / — | 53×**1506** + 53×1514 | **1472**×53 + 1480×53 | `e9f119b73b9052ba` |
| `p7b_postfix` | **0** | **0** | **0 / 0** | **105×1514** | **1480×105** | `163ae5c653a279ad` |
| `p7b_prefix_stall` | **680** = 8×85 | **85** | 0 / — | 83×**1506** + 10×1514 | **1472**×83 + 1480×10 | `6e0022265aa4b308` |
| `p7b_postfix_stall` | **0** | **0** | **0 / 0** | **92×1514** | **1480×92** | `6622ee4ea3f5878a` |
| `ovfctl`（负对照） | **432** | **54** | **54 / 54** | 同 `p7b_prefix` | 同 `p7b_prefix` | **`e9f119b73b9052ba`**（= prefix） |
| `ovfctl_stall`（负对照） | **680** | **85** | **85 / 85** | 同 `p7b_prefix_stall` | 同 `p7b_prefix_stall` | **`6e0022265aa4b308`**（= prefix_stall） |

**三条关键读数**：

1. **归零对账逐位成立**（任务硬要求）：修复后 `P7B_10G` 下
   `stat_tx_bytes == Σ_landed popc(tkeep)`（差 **0**），字级 `pushdec == landed`（差 **0**）。
   修前分别是 **432 B / 680 B** 与 **54 / 85 笔** —— 两个独立口径互证。
   （`land_bytes` 的 `tkeep` 逐位来自**写口**，不是重算图案 ⇒ 判的是"计了账的字有没有落笔"。）
2. **帧几何（判据取"逐帧头字段分布"，不是首帧）**：修复后**每一帧**都是
   `udp_len = 1480`、`ip_tot = 1500`、`len = 1514 = 42+1472`（线上含 FCS = **1518**）——
   正是 `P7B_SPEC §2.2` 的计划几何；修前是 `udp_len = 1472` / `ip_tot = 1492` / `len = 1506`
   （线上 **1510**），且分布**与 `len` 分布逐帧对齐**（53 干净 / 53 丢字），
   与 `P7B_W9_GAP.md §3` 的 `rate_fast` 读数**逐字吻合**（`w2=05d4…` / `w4=…05c0`）。
   ⚠️ **首帧恒干净**（FIFO 起始为空 ⇒ 要等饱和才丢）：`FRAME0`/`FRAME5` 在**修前也是**
   `udp_len=1480` —— 台架最初就抓了这个陷阱，故判据一律取**逐帧分布**。
3. **负对照 `ovfctl`**：把门退回本拍 `full`、其余保持修复后接线 ⇒ `ovf_pulse`/`stat_tx_ovf`
   读数 = **54**（STALL 档 **85**），**恰好等于**丢字笔数（= `pushdec − landed`）；且输出流指纹与
   `p7b_prefix` / `p7b_prefix_stall` **逐位相同** ⇒ 证明 (a) 该负对照确实只改"可见性"、
   (b) 修复前那次丢字**本可被看见**（旧写法把它钉成结构性 0）。这就是"修完必须让它可见"的实测答案。

> ⚠️ 台架与板级的差别（不是矛盾）：板级是**锁相极限环**（pcap 40/40 帧 1506、NIC
> `Δbytes/Δpackets = 1510.0000`，即**恒 1 字/帧 100%**），我这台模型每帧周期与帧边界相位会漂
> （`STALL` 档 83/93 = 89%）。**丢字机理同一**，只是相位分布不同；
> `P7B_W9_GAP.md §3` 已给出同一现象（`p7bonly` 档 100%、`rate_fast` 50/50）。
>
> 工具备注：`run_ovfctl` 首跑在 `$finish` **之后**崩了一次 JVM（`EXCEPTION_ACCESS_VIOLATION`，
> 症状在全部判据行打印完之后，属 xsim 退出期抖动）；重跑一次日志干净且**数字逐位相同**
> （54 / 432 / 同样分布）⇒ 不影响任何结论。

### 既有回归门（确认没搞坏）

| 门 | 本轮结果 | 与基线比 |
|---|---|---|
| `sim\p5e_udp\run_tb_app_udp.bat pos` | **EXIT=0** `P5E UDP APP GATE: OK (rx_frames=10 rx_bytes=13305 tx_frames=25 drop_len=1 drop_ovf=5 split=15 pat_bad=0)` | 与 `P7B_REGRESSION.md` #34 行**逐字相同** |
| `sim\p5e_rate\run_tb_rate.bat` | **EXIT=0** `app tx_frames=41 bytes=61112 \| utx frames=40 bytes=58880 drop=0 \| mac frames=40 abort=0` | 与 #42 行**逐字相同** |
| `sim\p5e_udp\run_tb_p5e_udp_wrapper.bat` | EXIT=1 `errs=1489` | **既存 FAIL，与 #40 行 errs 逐字相同**（`P7B_REGRESSION.md:101` 记为"同红、errs 数逐字相同"）⇒ 非本轮引入 |

日志：`p7b_w9fix/logs/gate_p5e_{udp_pos,rate,udp_wrapper}.log`。

---

## 4. 同类普查结论（`rtl/` 全部 26 个 `.wr(` 用法点）

判据（本缺陷的**签名**）：① `wr` 操作数是**寄存器**（本轮决定、下拍落笔）；
② 空间门用**本拍** `full` 而**不是** `full_next`。两条同时成立才有静默丢字。

| 文件 | FIFO / 写口 | `wr` 是寄存器? | 空间门 | 结论 |
|---|---|---|---|---|
| **`rtl/app_pattern.v`（TCP 演示 app）** | **无 FIFO、无任何子模块例化**（`grep` 全空）；字流交给 wrapper 里的 `axis_pipe`（`s_ready = m_ready || !m_valid` 的 skid，**无损反压**） | — | — | ✅ **不同病**（结构上没有可丢字的门） |
| `rtl/app_udp_pattern.v` | `u_txf` | **是** | 本拍 `full` | ❌ **本缺陷** → 本次修复 |
| `rtl/udp_split.v` | `u_pre`/`u_pb`（`udp_split_fifo`）、`u_uf`（`frame_fifo`）、`u_desc` | **否**（`s_acc`/`pb_wr_now`/`uf_wr`/`desc_wr` 全是 `assign`，且**同一表达式内**含 `!full`） | 本拍（**同拍**，与写同边沿） | ✅ 清白（组合写 ⇒ 判据与落笔同拍，无错位窗口） |
| `rtl/tcp_rx.v` | **无 FIFO**（模块内零子模块例化；RX 缓冲在 `tcp_echo` 的 `frame_fifo`，见 `app_ctrl.v:13-14` 注释） | — | — | ✅ 不适用 |
| `rtl/udp_tx_frame.v` | `u_fifo`（否则分支）/ `u_fifo_a`+`u_fifo_b`（`UDP_TX_OVL` 分支） | **否**（`wr = accept && tkeep!=0 && !len_bad` 是 `assign`；`tready` 内含 `!fifo_full`） | 本拍（同拍） | ✅ 清白 |
| `rtl/mac_rx_64.v` | `u_fifo` | 是 | **`full_next`（已修）** | ✅ 已有先例（P6b F4） |
| `rtl/rx_classify.v` | `u_wf` | 否（`w_wr = s_acc`，`tready = !w_full`） | 同拍 | ✅ |
| `rtl/mac_tx_64.v` / `slow_cfg_adp.v` / `tcp_echo.v` / `udp_echo.v` | `.wr(…tvalid && …tready)`，`tready` 内含 `!full` | 否 | 同拍 | ✅ |

### ⚠️ 越出本任务清单的 3 条观察（**未判定，未改**，留给下一轮普查/对抗审查）

| 位置 | 观察 | 为什么**没有**并入本次修复 |
|---|---|---|
| `rtl/slow_rx_adp.v:240,254` → `:105 .wr(o_wr)` | `o_wr` **是寄存器**，门用**本拍** `if (!o_full)` —— **同型写法** | 单写者 + 该 FIFO 深 2048 且"开播节流 `occ>256` 不开新帧"（`:154`）⇒ 占用离满很远。**未做严格可达性证明** |
| `rtl/slow_tx_adp.v:115,152` → `:70 .wr(wf_wr)` | 同上（深 512 的 `frame_fifo`，门 `!wf_full` 本拍） | 同上，未做可达性分析 |
| `rtl/tcp_tx_frame.v:588` → `:647 .wr(wr)` | `wr` 的第二项 `ring_wr = ring_act && beat_cnt>=3`（`:564`）**完全不看 `fifo_full`** —— 与 accept 路径不同源；ring 回放期间若 FIFO 满 ⇒ 静默丢字 | 形态与本缺陷不同（不是"门错拍"而是"无门"），且需先证明"ring 回放时 FIFO 必然不满"。**未判定** |

（`sim/` 里的门脚本不在本普查范围。）

---

## 5. 未做与风险

1. **未构建、未上板**（按派单：构建下一轮统一做）。⇒ 下列两条**必须**在下一轮构建时验：
   - **时序**：`full_next` 进了 `gen_ok → txf_wr` 这一锥（FIFO 内部一个 9 位加 + 比较）。
     P7B RATE 合并构建是 `WNS +0.136 / WHS +0.010`，**余量不厚** ⇒ 必须复查 WNS/失败端点。
     （先例：`mac_rx_64` 已用 `full_next` 且 P6b/P7b 各构建都收敛 ⇒ 形态本身没问题。）
   - **帧几何判据要跟着改口径**：修后线上 = **1518 B / 载荷 1472 B**（`P7B_W9_GAP.md §5` 已预告）。
     RATE 轮的 `A1`/`B0-2` 期望值按 1510/1464 写的会**判 FAIL**（那是修前口径）；
     速率预计基本不变（+1 字/帧 ≈ +1 拍/帧，与 +8 B/帧 近似抵消）。
2. **`stat_tx_ovf` 目前只在仿真里可读**（本模块**无端口**）。我按派单的"**不动端口合同**"没有加端口。
   要让它在板上可见，下一轮照 `mac_rx_64.stat_fifo_ovf` 的先例做 3 处：
   ① 本模块加 `output reg [31:0] stat_tx_ovf`（具名连接 ⇒ 全部 8 个例化点无需改动，已核）；
   ② `board/wrapper_p4.v` 加 `wire [31:0] udpapp_tx_ovf;` + `.stat_tx_ovf(udpapp_tx_ovf)`（`~:2496` 线束旁）；
   ③ 打包进 PCIe 快照窗口的空闲字 + 更新 `P6E_OBS.md` / `snap_seq.v` 映射表。
   ⚠️ 在此之前**板级不可见**；且若下一轮只加端口不接快照字，综合会把计数器整条优化掉（端口悬空）。
3. **`stat_tx_ovf` 是 32 位不回绕保护的计数器**（与其他 `stat_*` 同款）；恒 0 是判据，真响了就该查判据。
4. **头注释里"W9 口径"的语义**已订正，但 `board/wrapper_p4.v:3572` 那条 `// W9 → dp[3] 图案 app 发字节`
   与新口径**一致**（修后 W9 == 线上载荷）；同文件 `:2470-2474` 的 `~929 Mbps @1472B/帧` 是**默认构建**读数，
   在 `P7B_10G` 下仍不成立（`P7B_W9_GAP.md §7③` 已记）—— 属**注释过期**，本轮未动 wrapper（不在交付件内）。
5. **"反例双跑"的两个 arm 用同一份 TB**：TB 本身是本轮新写的（`tb_w9fix.v`），
   `land_bytes` 的口径是"落笔字的 `tkeep` 逐位 popcount"⇒ 与 `txf_in` 同源（不是独立仪器）。
   它足以判"计了没进"，但**判不了**"进 FIFO 的字是否又被下游丢" —— 那由帧几何（1514/1518）兜住。
6. **并发写者**：本轮期间另有 agent 在改 `board/wrapper_p4.v`（+89 行）与
   `_proj_pcie/rtl/axi_regs.v`（`git status` 可见）。已核其 diff **未触及**
   `app_udp_pattern` / `udpapp_*` 相关行 ⇒ 与本修复**无冲突**；上面三个回归门编译的是
   **当时工作区**的 wrapper，`p5e_udp_wrapper` 的 `errs=1489` 与基线仍逐字相同。
   下一轮构建前请再确认 wrapper 工作区状态。

---

## 6. 文件清单

```
rtl/app_udp_pattern.v                              ← 修复（唯一改动的已跟踪文件）
_proj_10g/notes/P7B_W9_FIX.md                      ← 本笔记（新增）
_proj_10g/notes/p7b_w9fix/README.txt               ← 台架说明（新增）
_proj_10g/notes/p7b_w9fix/tb_w9fix.v               ← 台架 TB（新增）
_proj_10g/notes/p7b_w9fix/run_case.sh              ← 运行器（自定位；pwd -W 出 Windows 路径喂 cmd）
_proj_10g/notes/p7b_w9fix/mut/app_udp_pattern_{prefix,postfix,ovfctl}.v   ← 三份被测 RTL 冻结副本
_proj_10g/notes/p7b_w9fix/run_<档>/{cmd.txt,xvlog.log,xelab.log,xsim.log,xsim_out.log}
_proj_10g/notes/p7b_w9fix/logs/gate_p5e_{udp_pos,rate,udp_wrapper}.log
```

未跟踪 `/ 未提交`：**一律没做 `git add` / `git commit`**（TL 统一做）。
未碰：`vivado_prj/`、`board/`（除只读引用）、`D:\repo\perfv`、license、QSPI。
