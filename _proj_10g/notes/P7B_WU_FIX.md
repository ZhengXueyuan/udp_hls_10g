# P7B-WU 修复：`app_ctrl` C6 窗口重开通告的**结构性不可达**（2026-10-07）

- 角色：**RTL 实现 agent**。交付 = ① 最小 RTL 改动 ② 可双跑对照的聚焦 TB ③ 自跑读数 ④ 本文件。
- 合规：**未提交 git**（TL 统一提交）· 未写 QSPI · 未碰 `D:\repo\perfv` · 未动 `stat_wu`/快照窗口（**按护栏本轮只改 `wu` 通路本身**）· 只改了 `rtl/app_ctrl.v`（**端口面零改动**）+ 新增 `tb/tb_app_wu.v`、`sim/p5wu/run_tb_app_wu.bat`。

---

## 0. 一句话

> **修好了**：修复前 C6 的两个触发条件在板级的现场模态下**都不可达**（`wscan == 0` 永不出现；
> "增长 ≥ 半池" 的基线 `wu_mark` 建连时 = 全池 ⇒ 需 1.5 倍池）。修法 = **按本连接配额归一的
> 一对滞回阈值**（武装 `< winq/4`，触发 `≥ winq/2`）。
> **同一激励双跑（一次仿真、两臂同波形）**：修复臂 **3 次通告**、修复前臂 **0 次**；
> 末尾用"恰好 0"的**设计工况**做反向对照 ⇒ **两臂各发 1 次**（证明旧臂实例活着，"0 次"不是假失败）。
> ⚠️ **未做板级**：J6（TCP 上行速率）**没有**新读数 ⇒ "上行会从 4.7 Mbps 回到 app 消费率量级"是**推断**。

---

## 1. 缺陷定位（文件:行号）

| 项 | 位置（**修复前**行号 = `git show HEAD:rtl/app_ctrl.v`） |
|---|---|
| 缺陷本体 | `rtl/app_ctrl.v:1112-1123`（C6 块） |
| 武装条件 ① | `:1114` `if (pb_wscan == 16'd0)` |
| 触发条件 ② | `:1116-1118` `wu_zero || (wscan >= wu_mark + WU_STEP)` |
| 阈值常量 | `:334-336` `WU_STEP = WIN_POOL >> 1 = 24576` |
| 基线初值 | `:848-851` init 拍 `wu_mark[init_slot] <= winq[init_slot]`（= 全池 49152） |
| 清理点（**未动**） | `:855/:902/:937/:1032/:1060`（init/ev_up/ev_down/to_fire/st_req_now 各自清 wu_*） |

**两个条件为什么不可达**（三段定位见 `P7B_BIZ_TCPREG.md` §2，判据 W/X：消费 ✅ / 回收 ✅ / **通告 ❌**）：
1. `pb_wscan == 0`：app 持续消费把窗"Zeno 式"托在 **56..128**（对端 pcap：2695 条 ACK 中 `win < 1460` 有
   79 条，**`win == 0` 一条都没有**）⇒ 采样永不落在恰好 0；
2. `wscan ≥ wu_mark + WU_STEP`：`wu_mark` 建连 = `winq` = 49152（`WIN_POOL` 上限）⇒ 需 `wscan ≥ 73728`，
   而 `wscan ≤ winq = 49152` ⇒ **数学上不可达**；且 ① 不触发 ⇒ `wu_mark` 永不更新 ⇒ 死锁自保持。
   ⇒ 板**从不主动通告窗口重开** ⇒ 对端只能等自己的 persist/RTO（实测 207.6 ms）⇒ 每周期 ~68 KB ⇒ 4.7 Mbps。

---

## 2. 修法（`rtl/app_ctrl.v` 现盘行号）

```verilog
// :250   新增参数（默认 0 = 修复后；1 = 逐字跑修复前逻辑，仅供 TB 负对照）
parameter        WU_LEGACY = 1'b0,
// :1170-1193  C6 块
if (pb_state == ST_ESTAB) begin
    if (WU_LEGACY) begin                      // :1171-1181 = 修复前逻辑, **逐字保留**
        ...（与 HEAD 逐字相同, 见 §5 的机械核对）
    end else begin                            // :1183-1192 = 生产路径
        if ({1'b0, pb_wscan} < {2'b0, winq[pb_sid][15:2]})            // 武装: 窗 < 本连接配额/4
            wu_zero[pb_sid] <= 1'b1;
        else if (wu_zero[pb_sid] &&
                 ({1'b0, pb_wscan} >= {1'b0, winq[pb_sid][15:1]}))    // 触发: 窗 >= 配额/2
            begin wu_pend <= 1; wu_mark <= pb_wscan; wu_zero <= 0; end
    end
end
```

### 2.1 三条设计理由（都可以被反驳，故写清）

1. **为什么是滞回（两个阈值），而不是"把 `==0` 放宽成 `<3*MSS`"**：
   放宽武装条件只解决 ① ；② 仍然要"从当前值**长到**某个绝对量"，而那个量必须 ≤ 池上限才有意义 ——
   见下条。
2. **为什么阈值必须按 `winq[pb_sid]` 归一，不能用绝对字节数**：本设计**支持建连前分池**
   （`P5d D4`：app 写 `0x0C = WIN_POOL/N`）⇒ 多连接时 `winq = 池/N`。任何**绝对**阈值
   （无论是 `3*MSS` 当释放点、还是沿用 `WU_STEP=24576`）在 `N ≥ 2` / `N ≥ 3` 时**再次结构性不可达** ——
   那就是**同一个坑换一种形式**。归一后对任意 `winq` 都可达（`winq/4 < winq/2 ≤ winq`）。

   ⚠️ **2026-10-07 订正（对抗审查，出处 `P7B_WU_REVIEW.md`，真问题 P1）：上面这句"归一后对任意 `winq` 都可达"**只对 `winq ≥ 8` 成立** ——
   `winq ≤ 3` 时 `floor(winq/4) = 0` ⇒ 武装条件 `wscan < 0`（17 位无符号比较）**恒假** ⇒ **结构性不可达，且比修复前更差**
   （修复前 `wscan == 0` 在窗真的关到 0 时**能**武装：窗 0→3 时会发一条）。反例（PH1，逐字可复跑）：`wr_reg(0x0C, 3)`（配额 3）+
   `ev_up(0)` → `occ 3→0` ⇒ 读数 `PH1 fires: new=0 leg=1 head=1` = **新臂 0 次 / 修复前（HEAD）1 次**；
   `4 ≤ winq ≤ 7` 时 `floor(winq/4)=1` ⇒ 武装**退化成"恰好 `wscan==0`"**（= 修复前那条脆弱条件；PH2 `winq=5` + Zeno 悬停窗 1..3：
   `new=0 leg=0 head=0`，**两版都 0 次**）。落坑条件 = `wq_cap_r ≤ 3`（app 自己写 `0x0C` 的**配置错误**）或"池被占满 ⇒ 该槽 `winq ≤ 3`"的**瞬态**
   ⇒ **严重度：低**；产品配置（`winq = 池/N`，`N ≤ 16` ⇒ `winq ≥ 3072`）与板上复位默认 `wq_cap_r = 0xC000` **都打不到**
   （PH3 在 `winq=3072` 三点验证：武装 @`wscan=72` / `wscan=1072 < 1536` 不触发 / 触发 @1572）。
   ⚠️ 本句在 RTL 里的同款注释（`rtl/app_ctrl.v:205`）**同病、尚未订正**（本轮只改文档，未动 `rtl/`）。
3. **为什么不保留原"增长 ≥ WU_STEP"分支**：`wu_mark` 只在触发时更新，而触发又要求"从 `wu_mark` 长上去" ⇒
   自指死锁（就是 ②）。保留它只能靠"武装时重定基"，那和滞回是同一个机制的两半；两条并存会让
   病态态下 wu 频率翻倍（每个周期发 2 条）。⇒ **替换**，不是叠加。`WU_STEP` 常量与注释保留（负对照路径用）。

### 2.2 刻意保持不变的东西（零回归面）

- **端口面 0 改动**（`git diff` 里 `input/output` 行 0 处改动；新参数在 wrapper 的**命名**例化下自动取默认值）。
- **电平请求 + `wu_gnt` 握手**（M1 教训）不变：`wu_pend` 仍是电平，`wu_gnt` 才清。
- `wu_mark` 的**观测语义**不变（仍是"上次 wu 通告的窗口值"，寄存器 `0x9B`）。
- 事件/超时/init 路径对 `wu_zero/wu_pend/wu_mark` 的清理**一字未动**（同槽重连、DEL、超时拆除都不继承旧会话）。
- **健康高窗不变量**：`wscan` 全程 ≥ `winq/4` ⇒ 一次 wu 都不发（原设计的"零额外帧"帧率纪律保住）。

---

## 3. TB 设计（`tb/tb_app_wu.v`，447 行）

**结构**：一次 `xelab`、一次仿真里跑**两臂**，共享同一组激励（`ev_*`/`occ`/TCB 模型/寄存器总线/gnt）：

| 臂 | 例化 | 含义 |
|---|---|---|
| `u_new` | `app_ctrl #(...)`（默认参数） | 修复后 |
| `u_old` | `app_ctrl #(..., .WU_LEGACY(1'b1))` | **逐字**修复前逻辑 |

- **"同一激励"是被证明的**：监视器逐拍核对两臂的 `rc_id / pa_v / pb_v / pb_sid / winq[0] /
  fc_upd_{wr,id,sel,val}` ⇒ `lockstep violation cycles = 0`。
- **wu 消费者模型**逐臂独立（`wu_gnt = gnt_en && wu_req`，形状 = `tcp_tx_frame.wu_push` 的
  "确实入队才 gnt"）—— 否则"无请求的那一臂"会被空加 `stat_wu`，旧臂就不再是 0。
- **相位机**（`mode`）：① 危险区振荡（`occ ∈ [WINQ-128, WINQ-56]` ⇒ `wscan ∈ [56,128]`，**结构上
  不可能为 0**）② app 消费（`occ--`，1 B/拍 ≈ 156 MB/s）③ 对端突发（`occ += 8 B/拍` = 10G 量级）④ 保持。
- **判据的两个方向都有对照**（全局经验 #48）：
  - 假失败方向 A：**武装但窗口未重开 ⇒ 0 次**（P1k）；
  - 假失败方向 B：**高窗相位连续 20 轮 ⇒ 0 次额外**（P4c，零额外帧不变量）；
  - 假失败方向 C：**旧臂实例活着**（P6：用"`occ ≥ winq` ⇒ `wscan == 0`"这个**修复前的设计工况**
    驱动 ⇒ **两臂各发 1 次**）⇒ "旧臂 0 次"是模态造成的，不是实例坏了。
- 只读寄存器 `0x96`（`stat_wu`）；**不写任何寄存器**（护栏：板上 `0x08` 是 SCRATCH 兼 `TX_DIS` 门）。

**一行复现**（本仓根执行，自定位 + 路径守卫 + xelab 面坑-24 判据都在 bat 里）：

```bash
cmd //c 'sim\p5wu\run_tb_app_wu.bat'      # 判据行: "P7B WU GATE OK" / "P7B WU GATE FAIL n"
```

---

## 4. 双跑读数（原文，`sim/p5wu/run/xsim_wu.log`）

```
P1: establish + danger-band modality (window held at 56..128 by app drain)
  PASS P1a NEW winq[0] = full pool
  PASS P1b OLD winq[0] = full pool
  [WITNESS] danger-band sampled win: min=63 max=120 (40 scans) exact0 hit: scan=0 model=0
  PASS P1c danger phase sampled
  PASS P1d sampled win >= 56
  PASS P1e sampled win <= 128
  PASS P1f win never exactly 0            <-- 修复前武装条件的现场模态
  PASS P1g model win never 0
  PASS P1h NEW armed (wu_zero=1)          <-- 新逻辑在同一模态下**武装**
  PASS P1i OLD not armed
  PASS P1j OLD wu_mark = full pool        <-- ② 的基线冻结 ⇒ 该分支恒假
  PASS P1k armed+small => 0 fires         <-- 假失败方向: 未重开就不发
  PASS P1l OLD 0 fires same phase
P2: app keeps consuming => window reopens (peer stalled, no external frames)
  PASS P2a reopened => 1 fire
  PASS P2b OLD 0 fires (same stim.)       <-- ⭐ 可证伪性主判据
  PASS P2c notified val in [wq/2,+step]
  PASS P2d notified val > 1 MSS
  [READ] fire#1 wu_mark=24695 (expect ~24576) @cyc~34850
  PASS P2e level holds w/o gnt (M1)
  PASS P2f OLD wu_req stays 0
P3: wu_gnt handshake (ackq model: grant iff requested)
  PASS P3a wu_req released by gnt
  PASS P3b NEW stat_wu=1 (reg 0x96)
  PASS P3c OLD stat_wu=0
P4: high-window phase (app drained the buffer => wscan = full) 20 scans, no more fires
  PASS P4a occ drained (wscan=full)
  PASS P4b disarmed (win>=winq/4)
  PASS P4c 0 extra fires in high phase    <-- 零额外帧不变量
  PASS P4d OLD still 0
P5: second cycle (peer burst fills buffer => consume again => notify again)
  PASS P5a burst never pushed win to 0
  PASS P5b NEW re-armed
  PASS P5c OLD 0 in burst phase
  PASS P5d 2nd cycle => 2nd fire
  PASS P5e fire#2 val in [wq/2,+step]
  PASS P5f OLD 0 across both cycles
  PASS P5g fire#2 consumed by gnt
P6: designed condition (occ >= winq => wscan exactly 0): BOTH arms must fire
  PASS P6a OLD armed at exactly 0
  PASS P6b NEW armed too
  PASS P6c NEW fire#3
  PASS P6d OLD fire#1 (arm alive)        <-- 反向对照: 旧臂不是坏的
  PASS P6e OLD notified val = full
------------------------------------------------------------
lockstep violation cycles (must be 0) = 0
NEW notifications = 3 (expect 3) . OLD = 1 (expect 1 = P6 designed condition only)
  PASS Z1 lockstep (same stimulus)
P7B WU GATE OK
$finish called at time : 743884 ns
```

**怎么读**：`P1f`（模态）→ `P2b`（旧臂在同一模态下 0 次）→ `P2a/P5d`（新臂 3 次）→ `P6d`（旧臂在
**它自己的设计工况**下确实能发）⇒ 四件事同时成立，缺一条这个门就没有判别力。

---

## 5. 回归（改动后实测）

**先记一条机械核对**：把 `WU_LEGACY` 分支与 `git show HEAD:rtl/app_ctrl.v` 做"去注释+去空白"逐行比对
⇒ **逐行相同**（TB 的负对照不是"重写版"，是同一份文本）。全文件归一化 diff = **3 处**（新参数 /
`if (WU_LEGACY) begin` / `end else begin` + 新逻辑），**再无其它改动**。

| 门 | 结果 | 备注 |
|---|---|---|
| ⭐ `sim\p5wu\run_tb_app_wu.bat`（新门） | **P7B WU GATE OK** | §4 |
| `sim\p5sim\run_tb_p5_fc.bat`（app_ctrl 直系单元门, 110 项） | **P5 FC UNIT GATE PASS** | 含 T7a-T7d（wu 电平/gnt/`stat_wu`+1） |
| `sim\p5sim\run_tb_p5_flow.bat`（512KB 慢消费者全链闭环） | **P5 FLOW OK** | ⭐ 且 `wu_mark0=60e0`(=24800) ⇒ **新逻辑在真实闭环里确实发过通告**；`retx=0`/`soft_viol=0`/`hard_viol=0` 不变 |
| `sim\p5sim\run_tb_p5_app.bat` | **P5 APP OK** | `stat_wu=0` / `wu_mark0=c000` ⇒ 该场景**零额外帧**（健康态无扰动） |
| `sim\p5sim\run_tb_p5_status.bat` | **P5 STATUS OK** | 状态行逐字符相等 |
| `sim\p5sim\run_tb_p5_adv.bat {wnd,multi,accmgn,fin,findrop}` | **5/5 OK** | 窗口/多连接/裕度/关闭/丢弃 |
| `sim\p5d_multi\run_tb_p5_multi.bat main` | **122 checks, 0 FAIL** | 与基线逐字相同 |
| `sim\p5e_udp\run_tb_app_udp.bat pos` | **OK** | |
| `sim\p5sim\run_tb_p5_pattern.bat` | **EXIT=0**（与基线同） | 尾行 `P5 PATTERN FAIL ...` 是**子用例行**、不是门判据（基线同） |
| `sim\p5sim\run_tb_p5_wrapper.bat` | **EXIT=1 —— 既存，非本轮** | 症状 `wrapper GMII: 0 帧` 与基线 §4 **逐字相同**；⚠️ **已用 HEAD 版 `app_ctrl.v` 双跑复证同红**（同症状/同退出码） |
| P4 矩阵（`run_matrix_p4dfix.bat`） | **未跑** | **结构性无关**：`tb_p4_chain.v` 与 `sim/p4sim|p4gates` 的编译清单**都不含 `app_ctrl`**（默认构建不例化它）—— 已用 grep 核实 |

**未跑**：`p5c_t3` / `p5close` / `p5d_d1` / `p5e_win` / `p5e_t2` / `p5e_udp_wrapper`（后者属**已知既存红族**：
基线 §4 的 `p5e_t2_wrapper` / `p5e_udp_wrapper` / `p5_wrapper` 同族）。**如实登记为未跑**。

---

## 6. 时序 / 面积代价（OOC 综合 A/B，**不是**全设计实现后读数）

同一脚本、同器件（`xcku5p-ffvb676-1-e`）、`-mode out_of_context`、约束 6.400 ns：

| 版本 | OOC WNS | 最差路径 | LUT | FF |
|---|---|---|---|---|
| `HEAD:rtl/app_ctrl.v` | **+2.211 ns** | `pool_reg[1]/C → pool_reg[0]/D`（C15 授予扣池），**15 级** | 5661 | 4541 |
| 本修复 | **+2.208 ns** | **同一条路径**（不是 C6） | 5214 | 4287 |

⇒ **C6 不在本模块的最差路径上，且改动前后最差路径同一条**；OOC 差 −0.003 ns（噪声级）。
⚠️ 这一条**不能**替代全设计构建的 WNS —— 见 §7-#2。

---

## 7. ⛔ 我没能证明的（如实登记，别当已答）

1. **没有任何板级读数**。本行交付**零烧板、零位流、零 J6/J15**。所以"TCP 上行会从 4.7 Mbps 回到
   app 消费率量级（~800 Mbps 级）"是**从机理推出的期望，不是读数**。收口仍要 `J6`/`J15`，且**读数必须带 pace 值**。
2. **全设计时序未重测**：板上 BIZ 位流是 `WNS +0.077 / 0/0/0`。§6 的 OOC 只说"C6 不是本模块最差路径"，
   **不等于**全设计 WNS 不掉。**下一轮开工必须重跑构建并核 `WNS` 与三类失败端点**（若翻负，优先看 §6 那族的
   异步复位 Recovery 网）。
3. **模态是建模的，不是复现现场动力学**：TB 把 `occ` 钳在 `[WINQ-128, WINQ-56]`（因此"永不为 0"是结构性的）。
   它证明的是**判据级事实**——"该模态下旧的两个触发条件不可达、新的一对阈值可达"，**不是**端到端板级行为。
4. **多连接（分池）只有推导没有仿真**：`winq = 池/N` 时新阈值仍可达是**算术论证**；TB 只跑了"单连接拿满池"。
   专门的多连接 wu 用例**没做**（`p5d_multi` / `p5_adv multi` 是回归，不是这条判据）。
5. **`wu` 频率/开销只有模型推算**：稳定态 `wu` 速率 ≈ 消费者回收速率 / (`winq/2`)。单连接满池 = 每 24 KB
   一条纯 ACK（app 139 MB/s 时 ~5.7k 条/s）。**未在板级测过**它对 10G 帧率/对端的影响。

   ⚠️ **2026-10-07 订正（对抗审查，出处 `P7B_WU_REVIEW.md`，真问题 P2）：本条的两个数要改写，并新增一条本修复的已知边界** ——
   ① **`rx_occ_bytes` 是全局共享的**（`fq = max(0, winq[c] - rx_occ_bytes)`，`app_ctrl.v:767`）⇒ 别的连接把 app RX FIFO 顶满时，
   **本连接的空转槽也会武装/触发 ⇒ 完全没流量的连接也会发 wu**。反例（PH4：`0x0C = 0xC00` 两条各 3072，conn0 有流量、
   conn1 **全程零流量**，`occ: 0→3000→1000`）⇒ 读数 `PH4 fires: new=2 head=0`（**两条各 1 条，含空转的 conn1**）。
   ② **实测消费步长 ≈ 15.6 KB/条**（PH5：`occ 40000→24400` 的一个"塌陷→重开"周期恰好 1 条 wu，`PH5a 5/5`），
   比上面 `winq/2 = 24.6 KB` 的估法**小 1.58 倍**（理论下界 = `winq/4 = 12.3 KB`）⇒ 单连接满池 `wu` 率 ≈ **6.4–8.6k 条/s**
   = **~0.4–0.6 MB/s 额外线上字节（64 B/条）≈ 10G 线的 0.04%**（**量级无害**；但 N 条连接同时振荡时按 N 倍增长，
   且新增的是**额外帧**、与 `P5a-0` 的"每段两帧已近对端上限"帧率纪律相冲）。
   ③ ⚠️ **`stat_wu`（`0x96`）从此分不清"真重开通告"与"共享占用噪声"** ⇒ 若下一轮把它接进快照当 `J6` 判据，读数会**高估**通告次数
   （作者原文未登记这一条）。
6. **只改了 `app_ctrl` 这一半**：`tcp_tx_frame` 的 wu 通路（ackq 优先级、`wu_gnt` 与"确实入队"等价性）
   **只做了阅读**，没有针对性实验；本条依赖既有结论（闸 4 的 `W55` 等）。
7. **边界情形未覆盖**：消费者极慢（窗在 208 ms 内长不到 `winq/2`）时仍会落到对端 persist 定时器上
   （见 `app_ctrl.v` 文件头"已知边界"）；`winq=0` 的连接（永不武装）也未专门测。
8. **"另一条独立工具路径"没做**：本机没有第二条 10G 路径（既有登记），板级 A/B 只能靠重烧位流。
9. ⚠️ **本修复完全没有参与并发分支的板级台架**：`_proj_10g/notes/P7B_WU_LOOP_{RECON,MEASREP}.md`（另一 agent）
   已用**板上现役未修位流**（BID 8 / `d20c08c9…`）取到 J6 same-session 基线（`PACE=0` ⇒ 4.631/5.060 Mbps 塌陷、
   `160M` ⇒ 13.3/14.6 Mbps 塌陷、`100M` ⇒ 800.2 Mbps）——**那就是本修复的 J6 负对照臂**。
   ⇒ 修复后的 J6 应由该分支在**同一台架、同参数**下复测（另：他们顺带修掉一个测量台缺陷 ——
   `p7b_tcp_src.cpp` 部分发送 ⇒ `W54` 假失配，**用未修工具时 W54 不判定**）。**我未核对其任何读数**。
10. **`board/wrapper_p4.v` 一字未动**（本条按护栏本该避免的改动自然不成立）：端口面零改动 ⇒ 无需同步例化；
    `git status` 里该文件无改动。

---

## 8. 文件清单

| 文件 | 变化 |
|---|---|
| `rtl/app_ctrl.v` | +78/−8（含注释）：新参数 `WU_LEGACY`（:250）、文件头 P7b-WU 节（:186-213）、`WU_STEP` 注释（:368-374）、C6 块（:1170-1193）。**端口面 0 改动** |
| `tb/tb_app_wu.v` | **新增**（447 行）：同一激励双跑 A/B |
| `sim/p5wu/run_tb_app_wu.bat` | **新增**（ASCII+CRLF，自定位+路径守卫+坑-24 判据） |
| `_proj_10g/notes/P7B_WU_FIX.md` | 本文件 |

**建议的下一手**（不在本轮范围）：① 全设计构建 + 烧板 ⇒ `J6`/`J15`（带 pace）；② TL 决定要不要把
`stat_wu`/`rx_occ_bytes` 进快照（本轮**按护栏没做**）；③ 若要把本门登记进常驻矩阵，加一行到
`_proj_10g/notes/p7b_regression/run_all_gates.py`（⚠️ 该文件属其它 owner，**本轮未改**）。
