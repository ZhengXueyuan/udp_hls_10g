# P7B_LANEFIX —— `/S/` 落 lane4 的帧在 `mac_rx_10g` 里被重对齐成满字 SOP

> 输入 = `P7B_UDP_DIAG2.md`（根因诊断，板级 + 仿真双证）+ 协调方两条补充令
> （① 判据族扫描 ② U3 / 延迟代表性）。
> 本件 = **修法 + 五路实测 + 覆盖面声明 + 残余风险**。所有原始日志在
> `_proj_10g/notes/p7b_lanefix/logs/`，复现脚本在 `_proj_10g/notes/p7b_lanefix/`。

---

## 0. 结论（要点先给）

| # | 结论 |
|---|---|
| 1 | **改一个文件**：`_proj_10g/p7b_mac/rtl/mac_rx_10g.v`（**唯一 canonical 副本**；`rtl/mac_rx_10g.v` **不存在** —— 全仓 11 份同名副本都是 scratch/导入产物，`board/build_p7b_ku5p.tcl:28,100` 只认 `_proj_10g/p7b_mac/rtl/`）。**+122 / −25 行**（`git diff --stat` 实测）。 |
| 2 | **修法 = lane4 帧的 4 字节重对齐**（新增"级 A-3"）：首字那 4 字节先**扣住**，与下一字前 4 字节拼成**满字 SOP**；此后每拍"上一字高半 + 本字低半"滚动；末字 `/T/` 落 lane5..7 时余下字节由**冲字** F 交付。**下游一行未改**（字节序合同 `tdata[63:56]`=帧首字节 未动）。 |
| 3 | **lane0 帧逐位不变**：非 lane4 帧 `ap_* ≡ a_*`（mux 透传）；证据 = 原 337 判据全绿 + 链级门 80/0 + wrapper 门 lane0 13/0。 |
| 4 | **五路验证全部实跑**（§2 有读数）：lane4 变体进 wrapper 门（双 lane 26/0）· MAC 单元门 **391/0**（新增 54 条 lane4 判据）· 链级门 **80/0** · 默认构建矩阵（§2.4）· **反例有牙**（修前 RTL ⇒ MAC 门 391/**9 fail**，9 条全是 SOP 满对齐判据，其余 382 条全绿）。 |
| 5 | ⚠️ **本修法给 lane4 帧加了 1 拍**（扣住那一拍无字产出）⇒ **`P7B_LATENCY.md` 的"lane4 不加拍"这条论证失效**（详见 §5.3）。其余四条延迟理由不受影响。 |
| 6 | 判据族扫描：**MAC 单元门** 5 处"只查位置/计数不查掩码/内容"已逐条列出并补了 2 处（§5.1）；**链级门**是更坏的一档 —— **RX 侧一条 SOP 判据都没有**（§5.1 表格）。 |

---

## 1. 修法（逐处 + 为什么这最小）

### 1.1 病根（一句话）

`/S/` 落 lane4 时前导组**跨字** ⇒ 帧首数据字只剩 4 字节（lane4..7）。原实现按"数据起始
lane = `/S/` 所在 lane"（`mac_rx_10g.v` 头 §XGMII 成帧约定 第 2 条）直接交付 ⇒ SOP 字
`tkeep=0xF0` ⇒ 违反本合同 `:12` 第 2 条「帧首字**总是满对齐** (tkeep[7]=1)」⇒ 下游
`udp_rx` 第 0 拍按 `s_axis_tkeep != 8'hFF` 判 nonmatch 整帧透传 HLS。

### 1.2 修法（逐处）

| 位置（修后行号） | 内容 | 为什么 |
|---|---|---|
| `mac_rx_10g.v:22-31` 头注释（§重对齐） | 新增一节：把"**lane4 起帧必须归一化成 lane0 帧的字几何**"写成设计约定，并指回 DIAG2 证据 | 合同条款现在有实现出处；后人改这一层先看到这条 |
| `:44-53` §流水结构 | 补一行"级 A-3 仅 lane4 起帧；lane0 帧 ap_* ≡ a_*" | 保证"lane0 逐位不变"是可读的**结构性**结论，不是巧合 |
| `:187-189` | `frag_now` 声明**上移**（原在 §F4） | A-3 要用它；语义一字未改（只挪位置） |
| `:221-260` 新增 **级 A-3** | `ra_m4/ra_v/ra_flush/ra_fst/ra_d[31:0]/ra_k[2:0]` 六个寄存器 + `ra_hold/ra_merge/ra_out/ra_lo4/ra_car4/ra_hi` 组合 + `ap_data/ap_k/ap_keep/ap_v/ap_first/ap_last` 六个归一化信号 | **核心**。4 字节半字 + 3 位计数 = 最小状态（不需要 8 字节缓冲：每拍只滚 4 字节） |
| `:276-286` FCS 剥离/发射判定 | `a_last→ap_last`、`a_k_l→ap_k`（`a_k_l` 保留为别名） | 末字/整字 FCS/tlast 回落的既有语义**对新字几何同样成立**（冲字天然 ≤4 字节 ⇒ 自动走"整字都是 FCS"那一支） |
| `:296-305` CRC | `.en/.d/.keep` 从 `a_*` 换成 `ap_*` | 让 CRC 与**交付字流**同源，读代码时不必再证"两条流同序"。⚠️ 事后用变异 **M15 实测**：退回 `a_*` **语义等价**（两种分字覆盖同一字节流且顺序一致 ⇒ 残差逐位相同）⇒ 这一处是**可读性**而非功能必需 |
| `:310-311` 帧级错误 | `a_err_new` 用 `ap_v`，且**冲字那一拍记 0**；`b_err_out` 用 `ap_last` | 冲字 F 的字节在产生它的那一拍已按 raw 窗检过（`f_see_*` 已含）⇒ 不重复计，也不会把 `/T/` 之后那半拍的控制字符算进本帧 |
| `:313-317` 线上长度 | `len_now = b_last ? f_len : f_len + (a_v ? a_k : 0)`（**raw `a_k`**，不是 `ap_k`） | ⭐ 见 §1.3 缺陷 B：lane4 帧的 A' 字有一半字节**上一拍已计入** f_len，用 `ap_k` 会重复计数 |
| `:421-446` 级 B 寄存器 + A-3 半字落笔 | `b_* <= ap_*`；半字链：`frag_now`⇒丢 / `ra_out`⇒空 / `ra_hold`⇒扣住 / `ra_merge`⇒滚动 | 脉冲型寄存器**每拍显式落笔**（本工程坑 6/12）；碎片(F-2)与它的一致性见 §1.4 |
| `:464` `/S/` 那拍 | `ra_m4 <= s_hit4` | 模式与本帧同寿（与 `first_lo` 同拍锁存） |

### 1.3 两处**只有实测才现形**的坑（修的时候踩到了，如实登记）

1. **半字必须逐拍滚动**：`ra_merge` 分支里最初写成 `ra_v <= (t_v && hi>4)` ⇒ 帧未结束
   （`t_v=0`）时半字被清空 ⇒ **每帧只交付 8 字节**（scratch TB 第一版读数
   `lane=4 clen=60 words=1`）。正解 = `ra_v <= (!t_v) || (hi > 4'd4)`。
2. **`len_now` 不能用 `ap_k`**：A' 字由"上一拍半字 + 本拍低半"拼成 ⇒ 其中一半字节
   已被 `f_len` 计过。用 `ap_k` 时线上长度**多算 1..4 字节**（实测：内容 61/62/63/64
   的 lane4 帧分别报 66/68/70/72，真值 65/66/67/68）。正解 = 加 `raw a_k`，且 `a_v=0`
   （冲字那一拍）加 0。**这条正是 §2.5 反例里 M16 变异要抓的**。

### 1.4 为什么这最小（边界逐条）

| 边界 | 处理 | 与既有语义的关系 |
|---|---|---|
| lane0 帧 | `ra_m4=0` ⇒ `ap_* ≡ a_*` | **逐位不变**（不是"差不多"） |
| 帧内又见 `/S/`（F-2 碎片） | `ra_hold` 含 `!frag_now`；`frag_now` 时 `ra_v<=0` | 碎片半字随帧一起丢；`b_v<=ap_v && !frag_now` 与既有丢弃门同门 |
| `/T/` 落 lane4（末字含满 FCS 尾部） | `ap_last=1`，`drop_b` 走 `b_last` 支 | 与 lane0 同路 |
| `/T/` 落 lane5..7（余字要冲） | 冲字 F `ap_k=hi-4≤4`、`ap_last=1` | 自动落进既有"**整字都是 FCS ⇒ tlast 回落前一拍**"那一支（`b_emit_last` 的第 ② 条），F 本身 `emit_n=0` ⇒ 不产出、不污染 |
| 首数据字即 `/T/`（0 字节帧） | 扣住 `ra_k=0` + `ra_flush=1` ⇒ 冲字 k=0 | 走既有 `zero_len_frm` ⇒ `stat_drop++`（与 lane0 同计法） |
| 丢帧（F4 FIFO 满） | 冲字照常产生但 `emit_n=0` | 丢弃/孤儿计数全部复用既有路径 |

---

## 2. 五路验证（全部实跑；日志见 `_proj_10g/notes/p7b_lanefix/logs/`）

### 2.1 lane4 变体进 wrapper 门（要求 #1）

`_proj_10g/p7b_appsplit/sim/tb_p7b_appsplit.v` 现在**跑两个 lane**（同一套判据 ×2）：
原 11 条 + 新增 2 条（`A4` 分流器输入口 SOP 满掩码 / `A5` 慢路径输出口 SOP 满掩码，
两条都带 `n > 0` 非空前提 ⇒ 不会空真）。

| 器件 | lane0 | lane4 | 总计 | 退出码 |
|---|---|---|---|---|
| **修后**（`logs/appsplit_fixed.log`） | **13 / 0 PASS** | **13 / 0 PASS** | **26 / 0 PASS** | 0 |
| 修前（`logs/appsplit_prefix.log`，`P7B_MUT=<修前 rtl>`） | 13 / 0 PASS | **12 FAIL** | 12 FAIL | 1 |

`lane4` 判据：`A1/A2/A3` + 6 条长度扫描 + `B1/B2`（120 帧背景后教学帧）+ `A4/A5`。
**（任务书的"11/0"口径在这里变成 13/0 —— 11 条原判据一条不少，另加 2 条合同判据。）**

修前 lane4 的现场诊断（同一门自动打印，逐行可核）：

```
      [SOPKEEP-FAIL split] td=000a350100000000 tk=f0 (期望 FF)
      [SOPKEEP-FAIL slow]  td=000a350100000000 tk=f0 (期望 FF)
```

⇒ 与板级签名同源（4 字节 SOP 字 + 整帧偏 4 字节）。

**专注变体**（诊断件固化为常驻门）：`_proj_10g/notes/p7b_udp_diag2/sim/`
- `tb_lane4.v` = canonical 门的 lane4-only 版本；`run_lane4.bat` 补了 **PATHGUARD +
  `SOPKEEP` 判据 + `P7B_MUT` 覆盖 + `FAIL⇒exit 1`**（原 bat **无 FAIL 判据** ⇒ 恒 exit 0，
  属"哑门"）。修后读数 `logs/lane4gate_fixed.log` = **13 / 0 PASS · EXIT=0**。
- 修前那份 **1/10 fail** 的原始证据已另存：`sim/xsim_lane4_prefix_1of10.log`（未被覆盖）。

### 2.2 MAC 单元门（要求 #2）

`_proj_10g/p7b_mac/sim/run_tb_mac_10g.bat`：

| 器件 | 结果 | 退出码 |
|---|---|---|
| **修后**（`logs/macgate_fixed.log`） | **391 checks / 0 fail · VERDICT = PASS** | 0 |
| 修前副本（`logs/macgate_prefix.log`，md5 `c996e8ae…`） | 391 / **9 fail** | 1 |

**337 基线一条没动**（原判据全绿，且原 4 条 lane4 判据也全绿 —— 它们本来就没判别力）；
391 = 337 + 4（组 4 新增：`tuser` 位置 / **SOP 满掩码** / 内容逐字节 / 线上长度）
+ 35（`内容 60..64` 五档 × 7 条 = `/T/` 落位扫描）+ 7（lane4 错误路径：坏 FCS `/E/`）
+ 2（lane4 0 字节退化帧）+ 6（lane4 碎片后一帧）。
`内容 60..64` 覆盖 `/T/@lane4`（既有）、`lane5/6/7`（**冲字支路**）、跨字（`lane0+`，走 tlast 回落）。

### 2.3 链级门（要求 #3）

`_proj_10g/p7b_chain/sim/run_tb_p7b_chain.bat` ⇒ **80 checks / 0 fail · VERDICT = PASS · EXIT=0**
（`logs/chaingate_fixed.log`，与基线逐值相同）。

### 2.4 默认构建回归（要求 #4）

`cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'`（16 门，本轮 11:33→11:56 = **23 min**）：

- **MATRIX_EXIT = 0**；逐门 `GATE <name> EXIT=0` **16/16**
  （`chain · burst200 · trunc50 · trunc100 · halfdrop · txdrop50 · gate4096 · dupstorm ·
    pcackoob · vlanchain · vlanburst · stallgate · unit_retx · unit_fifo · unit_vlan · unit_uart`）
- **修订指纹：`VERDICT: FROZEN -- all 237 hashed files byte-identical across the run`**
  （⇒ 未触发 exit 2 的"跑动期间源码被改"）
- ⚠️ 两门"无条件 exit 0"（`unit_retx` / `unit_fifo`）**按要求读了日志尾**：
  `unit_retx` = `ALL 7 GROUPS PASS`；`unit_fifo` = `PASS_ALL`（另有一条 BRAM 同址读写的
  仿真器警告，属既有现象）。`unit_uart` 的 `ALL_OK` 判据也已在矩阵日志里 ✓
- 原始件：`logs/matrix_p4dfix.log`（canonical 矩阵日志）+ `logs/matrix_console.txt`

> 结构性理由（不依赖矩阵）：`mac_rx_10g` 只在 `board/wrapper_p4.v` 的 `ifdef P7B_10G`
> 区里被例化（`:807`，区段 `:799-`），默认构建（无 `P7B_10G`）**根本不编译它**。

### 2.5 反例有牙（要求 #5：该被抓住的必须红）

| 反例 | 手段 | 结果 |
|---|---|---|
| ①**整修法回退** | `P7B_MUT` = 修前副本（`p7b_mac/rtl` 的 md5 修前值 `c996e8ae…`）| MAC 门 **391/9 fail**，且 **9 条全是 SOP 满对齐判据**（`/S/@lane4: SOP 满对齐` + 5 条扫描档 + 坏FCS + `/E/` + 碎片后一帧）⇒ 382 条老判据全绿、**恰好那一族红** ✓ |
| ②wrapper 门同款回退 | `P7B_MUT=<修前>` 跑 appsplit 门 | lane4 **12 fail**（含 `A4/A5` + `SOPKEEP-FAIL` 现场打印）· lane0 13/0 ✓ |
| ③**定点变异**（`scripts/mutate_gate.py`，新增 M12..M17） | 逐个改坏 | 见 §2.6 |

### 2.6 变异测试（要求 #2 后半）

`/c/Users/zhxue/anaconda3/python.exe _proj_10g/p7b_mac/scripts/mutate_gate.py`
（原始件 `logs/mutation_console.txt`，逐变异日志 `p7b_mac/sim/_mut_logs/`）：

- **正例（干净件副本）= 391 / 0 PASS**（变异测试的第一条纪律 ✓）
- 全 23 条：**22 条符合期望**，1 条期望标错（见下，如实报告）
- `MUT_VERDICT = FAIL (不等价变异漏掉 1 条)` ⇒ 逐条复核后**这一条是等价变异**，
  脚本里的期望已订正（`caught → not_caught` + 理由注释）

新增 6 条（专打本次修法）：

| 变异 | 期望 | 实测 | 抓到的判据（样例） |
|---|---|---|---|
| M12 重对齐关闭（`ra_hold = 1'b0`） | caught | ✅ caught（30 fail） | `/S/@lane4: SOP 满对齐` · 交付字节数 · 线上长度 |
| M13 冲字拆掉（`ra_v <= (!t_v)`） | caught | ✅ caught（10 fail） | `lane4 /T@lane5..7  wire len == content+FCS` |
| M14 合并字低半字节序颠倒 | caught | ✅ caught（14 fail） | `tcrs==1` · `payload byte-exact` |
| M15 CRC 挂点退回 raw `a_*` | ~~caught~~ → **not_caught** | ⚠️ **missed**（门是对的） | — |
| M16 线上长度退回用 `ap_k` | caught | ✅ caught（4 fail） | 恰好 4 条 `wire len == content+FCS`（`/T@lane5/6/7/跨字`） |
| M17 半字字节数写成 `t_v ? ra_car4 : 4` | not_caught | ✅ missed（等价） | — |

**⚠️ M15 是我把期望标错了，不是门的漏洞**（如实报告）：raw 窗与归一化窗是**同一字节流的
不同分字**（raw: 首字 `[4,hi)`、其后每字 `[0,8)`；归一化: 半字+低半逐拍滚动），而
`crc32_64` 只按"字节流顺序 + keep"推进 ⇒ 两者残差**逐位相同**。⇒ 该变异在语义上等价。
**副作用是好的**：它独立佐证了"归一化没有改动字节流，只改了字分组"。

> M17 同理：帧未完时 `hi=8` ⇒ `ra_car4 ≡ 4`；帧在本字结束且 `hi≤4` 时 `ra_v<=0` ⇒
> `ra_k` 不再被读。两种写法在**所有可达状态**上取值相同 ⇒ 门不报是**正确行为**。
> 另：老变异 **M5**（"RX 起始 lane 不锁存" = 修前缺陷的近亲）现在报 **89 fail**
> —— 提升来自新增的 lane4 用例（此前 lane0 下它几乎无判别力）。

订正期望后**已实跑复核**（只跑 M15/M17 两条的子集，`SUBSET_RC = 0`）：

```
  [OK ] M15 (等价变异) ... expect=not_caught rc=0  nFAIL=0
  [OK ] M17 (等价变异) ... expect=not_caught rc=0  nFAIL=0
MUT_VERDICT = PASS (不等价变异漏掉 0 条)
```

⇒ 全套 23 条的**唯一**异常 = M15 的期望值（我的标注），已订正；订正后 23 条全部符合期望。

---

## 3. 覆盖面声明（哪些 lane / 哪些帧长**真的**被测过）

### 3.1 注入 lane

| 门 | lane0 | lane4 |
|---|---|---|
| MAC 单元门 `tb_mac_10g.v` | ✅ 原 337 判据（帧长 1..1519 全扫） | ✅ **新增**（见 §3.2） |
| wrapper 门 `tb_p7b_appsplit.v` | ✅ 13 判据 | ✅ 13 判据（同一套） |
| 链级门 `tb_p7b_chain.v` | ✅ 80 判据 | ❌ **未覆盖**（见 §3.4） |
| 专注变体 `p7b_udp_diag2/sim/tb_lane4.v` | — | ✅ 13 判据 |
| 调试台 `p7b_lanefix/dbg/tb_lane4_dbg.v`（scratch） | ✅ | ✅ |

`/S/` 只允许落 lane0 / lane4（802.3 + 官方监视器同约定）⇒ **两个合法 lane 都有门**。

### 3.2 lane4 的帧长 / `/T/` 落位覆盖（关键：`/T/` 落位决定走哪条支路）

内容长度 `n = 内容+FCS`，末字节 lane = `(n+3) mod 8`，`/T/` 落 `lane+1`：

| 门 | lane4 内容长度 | 对应 `/T/` 落位 | 走哪条支路 |
|---|---|---|---|
| MAC 单元门 | 60 / 61 / 62 / 63 / 64 / 1514 | lane4 / 5 / 6 / 7 / 跨字(lane0) / lane2 | **4 条支路全覆盖**：末字含满 FCS 尾 · 冲字 F（lane5/6/7）· tlast 回落（跨字） |
| wrapper 门 | 50 / 60 / 98 / 102×120 / 142×3 / 333 / 1518 | lane2 / 4 / 2 / 6 / 6 / 5 / 6 | 冲字支（lane5/6）+ 常规支 + tlast 回落；含 120 帧背景序列 |
| 调试台 | 60..64 / 1514 | 4 / 5 / 6 / 7 / 跨字 / 2 | 同上 |

**错误路径（lane4）**：坏 FCS · 帧内 `/E/` · **碎片（帧内又见 `/S/`）** · **0 字节退化帧**
⇒ 各有判据（`lane4 坏FCS` / `lane4 帧内/E/` / `lane4 碎片后` / `lane4 0 字节帧`）。
碎片那条是本修法**最危险的失效模态**（残留半字 = 下一帧静默污染），判据直接查
"后一帧内容逐字节 == 注入" ✓。

### 3.3 修前 A/B（同一套判据）

| 门 | 修后 | 修前（`mut_prefix`，md5 `c996e8ae…`） |
|---|---|---|
| MAC 单元门 | **391 / 0 PASS** | **391 / 9 fail** —— 9 条**全是 SOP 满对齐**判据，其余 382 条全绿 |
| wrapper 门 | **26 / 0 PASS**（lane0 13/0 + lane4 13/0） | lane0 13/0 · lane4 **12 fail** |
| 专注 lane4 门 | **13 / 0 PASS** | 1/10（原诊断读数，原始日志另存） |

### 3.4 **未覆盖**（显式列出，不装作测过）

1. **链级门未注入 lane4**（只有 lane0）。⇒ 若要覆盖，需要一条 lane4 变体 —— 本轮**没做**。
2. **lane4 + 保留控制码**（`/R/` 等）：只测了 `/E/`。两者的检测路径相同（`f_see_bad` /
   `f_see_e` 同族），但**没有实测**。
3. **lane4 背靠背两帧**（跨帧半字交接）只有"碎片"一条间接覆盖，**没有**"两个规范 lane4 帧
   直接相接"的用例。
4. **lane4 + F4 背压丢弃**（FIFO 满时冲字与丢弃的交互）：只有 lane0 版的 F4 判据。
5. **`/T/` 落 lane1/2/3 的 lane4 帧**：只在 wrapper 门出现过 lane2 一档。
6. 板级：**未烧板**（任务纪律；板级复验由主线另派）。

---

## 4. 残余风险

| # | 风险 | 判别 / 缓解 |
|---|---|---|
| R1 | **RX 域时序变薄**：A→B 之间多了「归一化 mux + 4 字节半字寄存器」。原 `rxoutclk_out[0]_1` 基线 = **+0.206 ns**（`P7B_MAC_TIMING_FIX.md`） | 本轮**没做**全设计构建（任务纪律：合并构建由主线统一跑）。新增逻辑深度 ≈ 1 级 64 位 2:1 mux + keep 的加减比较 ⇒ 预计 1~2 级 LUT；**必须**在合并构建里复查 `rxoutclk_out[1]`（P7b 现役名）WNS。若不够，最省的降深手法 = 把 `ap_keep` 的 `8'hFF << (8-ap_k)` 换成与 `a_keep` 同构的查表/常数支 |
| R2 | **每帧 +1 拍（仅 lane4）** ⇒ 吞吐无损失（仍是 1 字/拍），但**延迟 +6.4 ns**（仅 lane4 帧） | 见 §5.3；这不是"风险"而是**必须公开的语义变化** |
| R3 | **lane4 碎片 + F4 背压的交互未测**（§3.4-4） | 设计上复用既有 TERM/丢弃门；若主线做板级 F4 复验，请**同时**用 lane4 流量 |
| R4 | **`/E/` 与保留控制码在冲字那一拍的归属**：本实现把冲字的错误记 0（字节已在产生那一拍检过）。若将来有人把 `f_see_*` 的锁存点挪到 A' 侧，这条会重复/漏计 | `mac_rx_10g.v:310` 有注释点名；若改 `f_see_*` 采点，必须重跑组 4 的 `/E/` 判据 |
| R5 | **14 份同名副本未同步**（`vivado_prj/*/imports/`、`p7b_chain/_f2_scratch*/`、`p7b_mac_synth/rtl/`、`p7b_mac/sim/{_mut_rtl,_prefix_rtl}/`）。其中 `p7b_mac_synth/rtl/` 的 `_STALE.md` 表里那句"`mac_rx_10g.v` 逐字节相同"**已不再成立** | 已订正 `_STALE.md` 那一行 + 指向本件；其余是变异/留档/构建导入产物，**不要**当构建源 |
| R6 | **闸 2（真网卡 802.3 裁决）未重跑** | 板级复验由主线另派；本件不含板级读数 |

---

## 5. 三条随令补充

### 5.1 判据族扫描（"只查位置/计数，不查掩码/内容"）

**扫描范围**：`tb_mac_10g.v`（MAC 单元门 391 条）· `tb_p7b_chain.v`（链级门 80 条）·
`tb_p7b_appsplit.v` + `tb_lane4.v`（wrapper 门 13×2）。方法 = 逐条读"这条判据想验合同的
哪一款？把该款破坏掉它会不会动？"

| # | 判据（文件:行） | 病 | 处置 |
|---|---|---|---|
| 1 | `tb_mac_10g.v:215` `rx_sop_ok = (rx_wcnt === 0)` | SOP **只看位置**（tuser 落在第 0 字），不看该字 `tkeep` | ✅ **已补**（`rx_soptk`，落在组 4 的 7 条 + 背靠背 1 条）⇒ 修前红/修后绿已实测 |
| 2 | `tb_mac_10g.v:886` "背靠背: 两帧 SOP 都正确 (位置 + 满掩码)" | **判据名 over-claim**：只判 `rx_fsop`（位置） | ✅ **已原地加严**（补满掩码条件，判据数不变） |
| 3 | `tb_mac_10g.v:692` "帧长扫描: SOP 落在首字" | 名字诚实，但同样不查掩码（lane0 下掩码结构性恒满 ⇒ 无判别力） | ⚪ 保留（lane0 专用；lane4 有专项判据） |
| 4 | `tb_mac_10g.v:969` "F4: 出现过 TERM 字 (tlast & tkeep==0)" | **TERM 六元组只查 2/6**（缺 `tdata==0` / `tuser==0` / `tcrs==0` / `terr==1`） | ⚠️ **未补**（需加采集寄存器），列为缺口 |
| 5 | `tb_mac_10g.v:694` "帧长扫描: 末字节内容正确" | 只抽**末字节**内容（长度扫描组） | ⚪ 采样取舍：任何长度/对齐类缺陷都会打中末字节；**不**覆盖"中间某字节被改"（那是别的组的活） |
| 6 | `tb_p7b_chain.v` RX 侧**全部** 80 条 | **一条 SOP 判据都没有**（位置、掩码都没有）；全部是**字节流级**判据（`Σpopc` 守恒 / 内容逐字节 / `tcrs` / `terr`）⇒ **字几何（keep 形状）缺陷在链级门结构性隐身** | ⚠️ **未补**：门只注入 lane0（`:194 wb[0]=8'hFB`），加判据也不会动；要真覆盖需先做 lane4 注入变体（本轮未做，见 §3.4-1） |

**没扫到的：** 1G 侧（`tb/tb_p4_chain.v` 一族）本轮**只做了 grep 级检查**，未逐条读 ——
理由是那条通路的 SOP 对齐是**结构性**的（`mac_rx_64` 从 GMII 字节流组字），且不属本次改动面。
**不声称**它们干净。

### 5.2 `P7B_MAC_DESIGN.md` 表格的两处订正

1. **U3（`:419`）"未在板上见过 lane4 的 `/S/`" ⇒ 订正为「**已核实（板上确实发生）**」**。
   依据 = `P7B_UDP_DIAG2.md` 的双证：板级 N/长度扫描（首帧恒 0 认领、20 连发 8~11/20、
   同内容不可复现 ⇒ 唯一自变量 = 起始 lane）+ 仿真 lane4 变体逐字复现该签名。
   ⚠️ 该行的原推论"所以 lane4 是理论合法但**实际没发生**"**作废**。
2. **`:348` 第 4 行（`/S/@lane4` ⇒ 数据从下一字 lane4 起、`tcrs=1`、`terr=0`）的验收口径偏松**：
   它验了**内容与首字节位置**，**没验** `tkeep` 合同。本件 §2.1/§2.2 把那一格补上了
   （`rx_soptk` / `A4` / `A5`）。

### 5.3 ⚠️ 本修法**改变 SOP 事件的拍对齐**（延迟那条论证失效）

**必须显式说**：修法**引入了 1 拍**（仅 lane4 起帧）—— 扣住那 4 字节的那一拍不产出字。
因此：

- **受影响的读数 = `P7B_LATENCY.md:243` 的 `(a)→(b)` 段**（XGMII `/S/` → MAC 输出 SOP）。
  原读数 **4 FE 拍 / 25.60 ns**，对 lane4 帧修后应为 **5 拍 / 32.00 ns**。
- `(b)→(c)` / `(c)→(e)` 两段**不变**（它们的锚点就是 (b) 的 SOP 事件本身；A' 之后的流水一字未动）。
- ⇒ 审计件 `P7B_EVIDENCE_AUDIT.md` §B.3.1 **理由 #1**（"lane4 分支**不引入额外一拍**"
  ⇒ 读数可留用）**在本修法落地后不再成立**。理由 #2（跨样本零离散）与 #3 不受影响。
- **反过来这是一条新判据**：修后 `(a)→(b)` 段对 lane0 帧 = 4 拍、对 lane4 帧 = 5 拍
  ⇒ **复跑同一套取数即可判定那 26~27 个样本里有没有 lane4 帧**（"零离散"从"留用理由"
  变成"lane4 探测器"）：
  - 全 4 拍 ⇒ 样本无 lane4 ⇒ 原读数（含 4 拍这个数字）**逐值留用**；
  - 出现 5 拍 ⇒ 样本含 lane4 ⇒ `(a)→(b)` 段必须按 lane 重新制表（其余段不受影响）。
- 这条**只有主线复跑板级取数**能闭合（本轮不烧板）；出处与剧本见
  `P7B_EVIDENCE_AUDIT.md` §B-6 的"建议"。

---

## 6. 原始件索引

| 路径 | 内容 |
|---|---|
| `_proj_10g/p7b_mac/rtl/mac_rx_10g.v` | **修后 RTL**（唯一 canonical；+122/−25 行） |
| `_proj_10g/notes/p7b_lanefix/mut_prefix/` | **修前副本**（`mac_rx_10g.v` md5 `c996e8ae…` + 同版 `crc32_64.v`/`mac_tx_10g.v`），供 `P7B_RTL`/`P7B_MUT` A/B |
| `_proj_10g/notes/p7b_lanefix/logs/` | `macgate_{fixed,prefix}.log` · `chaingate_fixed.log` · `appsplit_{fixed,prefix}.log` · `lane4gate_fixed.log` · `matrix_p4dfix.log` + `matrix_console.txt` · `mutation_console.txt` |
| `_proj_10g/notes/p7b_lanefix/dbg/` | scratch 调试台（lane×长度逐拍打印，定位 §1.3 两个坑用的） |
| `_proj_10g/p7b_mac/sim/tb_mac_10g.v` | MAC 单元门（组 4 = lane4 正/负/错误/退化/碎片） |
| `_proj_10g/p7b_appsplit/sim/tb_p7b_appsplit.v` + `run_tb_p7b_appsplit.bat` | wrapper 双 lane 门（bat 新增 `P7B_MUT` 与 `echo MAC RTL=`） |
| `_proj_10g/notes/p7b_udp_diag2/sim/tb_lane4.v` + `run_lane4.bat` | 专注 lane4 门（诊断件固化；bat 补 PATHGUARD/隐式网键/`FAIL⇒exit 1`） |
| `_proj_10g/p7b_mac/scripts/mutate_gate.py` | 变异集（新增 M12..M17） |
