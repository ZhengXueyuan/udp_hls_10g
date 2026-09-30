# P7B_CHAIN_COVERAGE —— 链级门三处覆盖面缺口的补法与反例实测

> 输入 = 任务书 + `P7B_LANEFIX.md` §5.1 的判据族扫描（3 处"仍未补"的缺口）。
> 本件 = **补法 → 每条新判据的反例实测（红/绿双跑）→ 判据总数 → "不值得补"的判断 → 残余缺口**。
> 改动面：`_proj_10g/p7b_chain/sim/tb_p7b_chain.v`（+ 同目录 `run_tb_p7b_chain.bat` 两行归属回声），
> 原始件全在 `_proj_10g/notes/p7b_chain_cov/`。**未改任何 RTL、未烧板**。

---

## 0. 结论（要点先给）

| # | 结论 |
|---|---|
| 1 | 三处缺口**全部补上**：① 链级 RX 侧 SOP 满对齐判据（此前**一条都没有**）+ lane4 注入；② TERM 六元组 3/6 → **6/6**；③ 帧长扫描从"只看字节计数"→ **逐字节**（首/中/末全覆盖）。 |
| 2 | 判据总数 **80 → 106**（+26，19 个调用点，其中 1 个在循环里跑 8 档）。**既有 80 条逐语句零改动**（脚本对账：名字/条件/期望来源全等，见 §3.2）。 |
| 3 | **反例有牙，且是实跑**：换回修复前 `mac_rx_10g`（`P7B_MUT`）⇒ **106/12 fail**，12 条**全在新判据族**（SOP-1 + 8×lane4 逐字节 + lane4 背靠背 + lane4+F4×2），既有 80 条**一条不红**；换回修复版 ⇒ 106/0。 |
| 4 | 换回修复前**打不中**的那几条（TERM 族、lane0 逐字节）另配**定点变异**反例并实跑：`MUT-TERMDATA` ⇒ 只红 TERM-2（**旧判据 3/6 全绿** ⇒ 这正是缺口 2 的价值）；`MUT-TERMKEEP` ⇒ 红 TERM-1/TERM-2（+ 既有 5b）。 |
| 5 | 顺手扫出一条**新缺陷**（登记为 `[DEFECT-REG #2]`）：`mac_rx_10g.dbg_rx_last_tlane` 在 "tlast 回落到前一字"（= lane4 帧 `/T/` 落 lane5/6/7）时**恒报 8**。该网**无消费者**（悬空）⇒ 零功能影响，但按"仪表会撒谎"必须登记。 |
| 6 | 顺带的 4 条未覆盖面：**2 条值得补（已补 + 实跑）**、**1 条不值得（结构性无判别力）**、1 条由补的扫描**顺带覆盖**。理由见 §5。 |
| 7 | 过程中抓到一条**本门自伤**（TB 期望下标写 `%256`，与 PAT 的 8 个特殊字节撞车 ⇒ 假失配）。DUT 交付的字节是**对的**；已修并留证（§4.1）。 |

---

## 1. 三处缺口的补法

### 缺口 1（最坏的一档）：链级 RX 侧没有任何 SOP 判据 + 只注入 lane0

**病**：`tb_p7b_chain.v` 的 RX 判据全是**字节流级**（`Σpopc(tkeep)` 守恒 / 内容 / `tcrs` / `terr`）⇒
**字几何（keep 形状）缺陷结构性隐身**：`/S/` 落 lane4 的帧（SOP 字只有 4 字节 + 整帧偏 4 字节）
在旧判据下与 lane0 帧**完全不可分**（字节数一样、内容流一样）。而 `/S/` 只允许落 lane0/lane4。

**补法**（两条腿，缺一不可）：

| 腿 | 内容 | 位置 |
|---|---|---|
| ② 注入面 | 新增 `frame_lane` + `xq_pack_words_sh(n, 4)`：把帧字节流**从 lane4 起**打包入 RX 注入队列（前 4 lane 填 idle），`build_frame` 读一次即清零 ⇒ 既有调用点一行不改、默认仍 lane0 | `tb:198-221`(`xq_pack_words_sh`) · `:259`(`build_frame` 尾部) |
| ① 判据面 | `SOP-1`：**每一个** `tuser==1` 的交付字必须 `tkeep==8'hFF`；`SOP-2`：`Σ(SOP) == Σ(TLAST)`（每个首字恰被一个 tlast 关闭 = 合同 §5「绝不留裸尾巴字」），两条都带 `n>0` 非空前提 | `tb:280-334`（观察量 + 比较器）· `:1920-1931`（G4 组） |
| ③ 逐帧 | lane4 八档（内容 60..67）+ 背靠背 + F4，每档逐字节 | G1/G2/G3 组 |

⭐ **为什么八档就是全覆盖**：lane4 帧的 `/T/` 落位 = `(内容 n) mod 8`（推导：前导组跨字 ⇒
`/T/` 绝对字内位置 = `(16+n) mod 8`）。`n = 60..67` ⇒ `/T/` 落 **lane4,5,6,7,0,1,2,3 八档全遍历**，
其中 `65/66/67` 正是扫描点名的 "`/T/` 落 lane1/2/3 的 lane4 帧" 缺口（`60..64` 覆盖冲字支路 +
tlast 回落支路）。
**这条覆盖声明不是推导 —— 有实测判据**：`G1c` 从**本帧刚注入的 XGMII 字**里扫 `c==1 && d==0xFD`
取 lane（激励面自检），8 档实测 `4,5,6,7,0,1,2,3` ⇒ 掩码 `0xFF`。

### 缺口 2：丢帧的 TERM 六元组只查了一部分

**病**：旧判据（`5b`）只有 `tkeep==0 && tcrs==0 && terr==1`（且 `tlast` 由外层隐含），
合同 `mac_rx_10g.v:16` 要求 `{tdata=0, tkeep=0, tlast=1, tuser=0, tcrs=0, terr=1}` 六项。

**补法**：新增独立观察量 + 两条判据：
- `TERM-1`：TERM 字出现过（**非真空分母**，且分母为 0 时红）；
- `TERM-2`：**全部** TERM 字的六元组**逐项**成立（`rx_term_bad_n == 0`），并把首个 TERM 的
  六项实测值打进 DIAG（`d/k/l/u/c/e`）。
- 判据不删不改旧的 `5b`（它继续在，且被 `MUT-TERMKEEP` 打红，证明仍活着）。

### 缺口 3：帧长扫描只抽一个字节

**病**：链级门第 2 组只查**字节计数**（`m===60` / `n===1514` / `Σpopc`），内容一个字节都不比。

**补法**：新增**逐字节比较器** `rx_bytes_match(n, base)`（`tb:322`，全帧逐字节，非抽样）+ `exp_add/exp_reset`
期望队列（只对登记过的帧比对，未登记 = 中性）⇒ 判据 `2f/2g/2h/2i`（60B / 1514B / 63B / 65B
逐字节）+ lane4 八档 + 背靠背 + 恢复帧共 **14 条逐字节判据**（4+8+1+1）。
⭐ 比较器里一处**必须写对**的细节（见 §4.1）：`got_buf` 的存储序在每个 8 字节组内与帧字节流**相反**，
且反转基准是**该组的有效 lane 数 r**（不是恒 8 —— 残字只有 r 个 lane）。
既有 `X6` 的 `8w+7-idx` 只对满字成立，对残字实际在比"pad 全 0"（判别力弱，**未改既有判据**，仅登记）。

---

## 2. 反例实测（红/绿双跑；全部实跑，日志逐份可查）

### 2.1 五跑矩阵（同一份 TB、同一份冻结 wrapper）

`P7B_MUT=<dir>` 是该 bat 既有的钩子（wrapper + 三个 MAC rtl 全从该目录取）。
**为了让"红"只归因于 RTL**，`mut_prefix` / `mut_fixed` 两份快照用的是**同一份冻结
`wrapper_p4.v`**（md5 `92b535df…`，= 当时现役板级 wrapper），只有 `mac_rx_10g.v` 不同。

| 跑 | P7B_MUT | RTL | 判据 | fail | 退出码 | 日志 |
|---|---|---|---|---|---|---|
| A 正例（canonical，现役树） | — | 修后 | **106** | **0** | **0** | `logs/chaingate_cov_fixed.log` |
| B 对照（冻结快照） | `mut_fixed` | 修后 | 106 | 0 | 0 | `logs/chaingate_cov_snapfixed.log` |
| C **反例**（修复前副本） | `mut_prefix` | 修前 | 106 | **12** | 1 | `logs/chaingate_cov_prefix.log` |
| D 定点变异 1 | `mut_termdata` | 修后 + TERM 带残数据 | 106 | **1** | 1 | `logs/chaingate_cov_termdata.log` |
| E 定点变异 2 | `mut_termkeep` | 修后 + TERM 不清 keep | 106 | **4** | 1 | `logs/chaingate_cov_termkeep.log` |

**B 的作用**：证明 C 的 12 条红**来自 RTL 换版**，不是"快照目录"这个自变量引入的假红。

### 2.2 C 跑（修复前 RTL）红的是哪 12 条 —— 全在新族，既有 80 条一条不红

```
[FAIL] G1.0 lane4 content 60 byte-exact   [FAIL] G1.4 lane4 content 64 byte-exact
[FAIL] G1.1 lane4 content 61 byte-exact   [FAIL] G1.5 lane4 content 65 byte-exact
[FAIL] G1.2 lane4 content 62 byte-exact   [FAIL] G1.6 lane4 content 66 byte-exact
[FAIL] G1.3 lane4 content 63 byte-exact   [FAIL] G1.7 lane4 content 67 byte-exact
[FAIL] G2b lane4 back-to-back: both byte-exact      [FAIL] G4 SOP-1 every RX SOP word full-aligned
[FAIL] G3c lane4+F4: no new mis-aligned SOP word    [FAIL] G3d lane4+F4 recovery byte-exact
```

现场读数（同一份日志自动打印）—— 与板级签名同源：

```
[G DIAG] frame 0: len=60 bx=0 sopk=f0 | /T/ lane stim=4 dut=4 …   ← 8 档全部 sopk=f0 (4 字节 SOP 字) + bx=0 (整帧偏 4 字节)
[G DIAG] lane4 F4: drop 32->64, term 1->2, sop_bad 10->20         ← 停摆窗口里 SOP 违掩码数翻倍
[G DIAG] SOP n=53 bad=21 | TLAST n=53 | TERM n=2 bad=0
```
⇒ **旧门的"隐身"被复现**：`G1z`(帧数/字节数) / `G2a` / `G2c` / `G3a` / `G3b` 在修前**照样绿**
（帧数、字节数、丢帧计数、TERM 存在性都不受字几何影响）——判别力**只**来自新判据。

### 2.3 逐条新判据的"该被抓住"反例

| 新判据 | 反例（实跑） | 结果 |
|---|---|---|
| `SOP-1` 每个 SOP 字满对齐 | C：修复前 RTL（`sopk=f0`，`bad` 0→21） | ✅ 红 |
| `SOP-2` Σ(SOP)==Σ(TLAST) | 语义上由"裸尾巴/合并/拆分"触发；本轮的 C/D/E 三跑**没打到**（如实登记：**无实跑反例**） | ⚠️ 未红 |
| `G1.0..G1.7` lane4 逐字节（8 档） | C（`bx=0` 八档全红） | ✅ 红 |
| `G1z` lane4 帧数/字节数 | C（帧数/字节数不变量 ⇒ **它是非真空前提，不是有牙判据**，如实标注） | ⚪ 不红（应然） |
| `G1c` /T/ 落位覆盖（激励面） | C 也绿（**它是激励自检，不是 DUT 判据**，如实标注） | ⚪ 不红（应然） |
| `G2a/2c` lane4 背靠背帧数/字节数 | C 也绿（同 `G1z`） | ⚪ 不红（应然） |
| `G2b` 背靠背逐字节 | C | ✅ 红 |
| `G3a` lane4+F4 丢弃计数 | C 也绿（计数不变量） | ⚪ 不红（应然） |
| `G3b` lane4+F4 出 TERM | E（`mut_termkeep`：TERM 不可识别 ⇒ 计数 0） | ✅ 红（E 跑） |
| `G3c` lane4+F4 无新违掩码首字 | C（`sop_bad` 10→20） | ✅ 红 |
| `G3d` lane4+F4 恢复逐字节 | C | ✅ 红 |
| `TERM-1` TERM 出现 | E（`term 0`） | ✅ 红 |
| `TERM-2` TERM 六元组 | D（**旧 3/6 判据全绿**，`bad=2`，实测元组 `d=78797a7b7c7d7e7f`） | ✅ 红 |
| `2f/2g/2h/2i` lane0 逐字节 | 2j 自检（同一比较器，故意错位 1 字节 ⇒ 必红）＋ C 跑的 lane4 家族用**同一函数**被打红 | ✅ 红（自检） |
| `2j` 比较器自检 | **本身就是反例**：期望错位 1 字节 ⇒ 必须判不一致（正例跑里它 PASS = 比较器确实报了不一致） | ✅ 内建 |

⚠️ **如实说**：C 跑（换回修复前 RTL）**打不中** TERM 族与 lane0 逐字节族 —— 因为**它们在结构上
与起始 lane 无关**（TERM 的字节内容来自丢弃路径，lane0 帧的字几何两版逐位相同）。
这两族的反例改用**定点变异**（D/E）并**实跑**，不是"按构造会失败"。

### 2.4 D/E 的现场读数

```
D (mut_termdata):  [FAIL] G4 TERM-2 …   →  [G DIAG] TERM n=2 bad=2 | tuple: d=78797a7b7c7d7e7f k=00 l=1 u=0 c=0 e=1
                    ↑ 旧判据 5b「F4 TERM word seen」**绿**（它只看 tkeep/tcrs/terr）⇒ 缺口 2 的判别力就在这里
E (mut_termkeep):  [FAIL] 5b(旧) + G3b + TERM-1 + TERM-2   →  [G DIAG] TERM n=0 bad=0
                    ↑ TERM 字不可识别 ⇒ 分母归零；TERM-1 的"非真空"前提正是为此设的
```

---

## 3. 判据总数与"既有判据未动"的对账

### 3.1 总数

```
==== tb_p7b_chain done: 106 checks, 0 fail ====
VERDICT = PASS           （EXIT=0；基线 = 80 checks / 0 fail）
```
**106 = 80 + 26**。26 条新判据、19 个调用点（`G1.x` 那一个点在循环里跑 8 档）。
拆解：lane0 逐字节 4 + 比较器自检 1 + lane4 八档 8 + 覆盖自检 2(`G1z`/`G1c`) + 背靠背 3 +
lane4+F4 4 + 跨 run 4(`SOP-1/2` + `TERM-1/2`)。

### 3.2 既有 80 条**逐语句**零改动（脚本对账）

用正则抽出两份文件的全部 `chk(...)` 调用（名字 + 完整条件/期望来源文本，空白归一化）后对账：

```
HEAD   里消失或改名的判据: 0
同名但语句(条件/期望来源)被改的判据: 0
新增调用点: 19
```
⇒ **没删判据、没放宽判据、没改期望来源**（唯一"改"的是 `build_frame` 末尾一行调用：
`xq_pack_words(m)` → `xq_pack_words_sh(m, frame_lane)`，语义在 `frame_lane=0` 时**逐位等价**，
且既有 80 条在 C 跑里全绿 = 行为不变的独立佐证）。

---

## 4. 过程中的两个发现（都登记，不改别人的产物）

### 4.1 本门自伤：期望下标 `%256` 与 PAT 的 8 个特殊字节撞车（已修）

`PAT[0..7]` 被**故意**设成 8 个两两不同的字节（`01 23 45 67 89 AB CD EF`，字节序判据的判别力
全靠它），而 `PAT[i≥8] = i%256` ⇒ 我第一版把期望写成 `PAT[(base+gbi)%256]`，当
`(base+gbi)%256 ∈ [0,7]` 时会去比那 8 个特殊字节 ⇒ **假失配**。实测现场：

```
2 DIAG: f1 bn=1514 badq=256 obs=07 exp=ef      ← 1514B 帧在 q=256 处"失配"
```
`obs=07` **正是** `PAT[263]=263%256=7` ⇒ **DUT 交付的字节是对的，是 TB 的期望错了**。
修法 = `PAT[(base+gbi)%2048]`（PAT 有 2048 项；本轮全部用例 `n ≤ 1514、base ≤ 1`）。
**这条留证是为了说明**：新判据第一次跑出来的"红"未必是 DUT 的 —— 先看比较器自己的口径。

### 4.2 `[DEFECT-REG #2]`：`dbg_rx_last_tlane` 在 tlast 回落那一拍恒报 8

`G1c` 原本想用 DUT 自报的 `/T/` lane 做覆盖证据，结果**八档里有三档报 8**：

```
frame 1: /T/ lane stim=5 dut=8    frame 2: stim=6 dut=8    frame 3: stim=7 dut=8
（其余五档 dut 与 stim 一致；修复前 RTL 八档**全部一致**）
```
机理（读 RTL 得出，与读数逐条吻合）：`dbg_rx_last_tlane <= b_last ? f_tlane : t_lane_lo`
（`mac_rx_10g.v:400`）。当 `/T/` 落 lane5/6/7 时末字整字都是 FCS ⇒ 冲字 F 推不出字节
⇒ **tlast 回落到前一字**（`b_last=0` 那一支）⇒ 取 `t_lane_lo` = **当前输入字**的 /T/ lane，
而当前输入字是 idle ⇒ 恒 8。正确应取锁存值 `f_tlane`。

**影响 = 零**：`wrapper_p4.v:841` 把它接到 `mrx_dbg_last_tlane`，而该网**全仓无消费者**
（无快照字、无端口）= 悬空网。⇒ 登记为"仪表会撒谎"类（全局 CLAUDE.md §六-6 同族）：
**谁将来接它做板级判读，必须先修这里**。
本门的 `G1c` 因此改挂在**激励面**（扫注入的 XGMII 字），不依赖这个寄存器。

---

## 5. 顺带 4 条"未覆盖面"的判断（该补的补了，不该补的说清理由）

| # | 未覆盖面 | 判断 | 理由 |
|---|---|---|---|
| 1 | `lane4 + 保留控制码` | ❌ **不值得补** | 保留控制码的检测（`bad_any`/`win_bad`）在**级 A 的 raw 窗**里，位于 **级 A-3 重对齐之前**；级 A-3 只对**已判定的数据字节**重新分字（`ra_d` 是数据、`ra_k` 是计数，控制字符根本进不了这一级）⇒ lane4 + 保留码与 lane0 + 保留码**走同一条组合通路**，加一条 lane4 版**零增量判别力**。⚠️ 顺带如实说：**保留控制码在链级门里任何 lane 都没判据**（`stat_rx_bad_words` 没接进判据表）—— 那是链级门的另一处缺口，与 lane4 无关，列入 §6。 |
| 2 | `两个规范 lane4 帧背靠背` | ✅ **值得补，已补** | 跨帧**半字交接**是本次修法最危险的失效模态（残留半字静默污染下一帧）。`G2a/b/c`：恰 2 帧 + 两帧逐字节 + 61+62 字节；修前 RTL 下 `G2b` 红（`bx=0/0`）。 |
| 3 | `lane4 + F4 背压` | ✅ **值得补，已补** | LANEFIX §3.4-4 / 残余风险 R3（丢弃 × 冲字 × 半字）。`G3a`(丢弃计数上升) / `G3b`(出 TERM) / `G3c`(无新违掩码首字) / `G3d`(恢复帧逐字节)；修前 RTL 下 `G3c`+`G3d` 红。 |
| 4 | `/T/` 落 lane1/3 的 lane4 帧 | ✅ **值得补，已随扫描补上** | 由 G1 的 60..67 八档**顺带全覆盖**（`65/66/67` ⇒ `/T/@lane1/2/3`），而且**实测**（`G1c` 掩码 `0xFF`），不是推导。额外成本 = 0。 |

---

## 6. 残余缺口清单（本轮**没**覆盖的，显式列出）

1. **链级门对 `stat_rx_bad_words`（保留控制码）没有任何判据**（任何 lane）—— MAC 单元门有，链级没有。
2. **链级门对 `/S/` 非法落位（lane1..3/5..7）未注入**（`s_other` 的 `stat_rx_bad_words` 计数未判）。
3. **lane4 的退化/异常帧链级未测**：0 字节帧、帧内又见 `/S/` 的**碎片**（MAC 单元门两项都有；
   链级只测了规范的 lane4 帧 —— 碎片是修法最危险的模态，**建议下一轮补**）。
4. **`TERM 字数 == stat_drop_partial 增量`** 未做成判据（口径未验证：`term_pend` 是单 bit 标志，
   两次 partial drop 可能只出 1 个 TERM ⇒ 先把读数打出来，别急着钉成判据）。
5. **`X6` 残字段的逐字节比对弱**（`8w+7-idx` 对残字实际在比"pad 全 0"）—— 既有判据，本轮**未改**，
   仅登记；同族的正确写法见本门 `rx_bytes_match`。
6. **`SOP-2` 无实跑反例**（语义上由裸尾巴/合并/拆分触发，本轮 5 跑都没打到）。
7. **板级**：**未烧板**（任务纪律）。⇒ "lane4 帧在板上被认领"仍是 §P7B_UDP_DIAG2 的板级结论，
   本轮只把**链级仿真**的判别力补齐。
8. **1G 侧**（`tb_p4_chain` 一族）：本轮未扫（不属改动面，**不声称干净**）。

---

## 7. 原始件索引与复现

| 路径 | 内容 |
|---|---|
| `_proj_10g/p7b_chain/sim/tb_p7b_chain.v` | 唯一改动文件（+26 判据 / +19 调用点；头注释判据表已补 10 行） |
| `_proj_10g/p7b_chain/sim/run_tb_p7b_chain.bat` | +2 行 `[RTL]` 归属回声 + `MACD` 存在性守卫（**让每个日志自带"用的哪套 RTL"**） |
| `_proj_10g/notes/p7b_chain_cov/mut_fixed/` | 冻结快照（wrapper md5 `92b535df…` + 修后 MAC） |
| `_proj_10g/notes/p7b_chain_cov/mut_prefix/` | 同上 wrapper + **修前** `mac_rx_10g.v`（md5 `c996e8ae…`，取自 `p7b_lanefix/mut_prefix/`） |
| `_proj_10g/notes/p7b_chain_cov/mut_termdata/` · `mut_termkeep/` | 两个定点变异（`MUT-TERMDATA` / `MUT-TERMKEEP`，各一行，带标记注释） |
| `_proj_10g/notes/p7b_chain_cov/logs/` | 5 份 xsim 原始日志（`chaingate_cov_{fixed,snapfixed,prefix,termdata,termkeep}.log`）+ 5 份 console（每份头两行 = `[RTL]` 归属回声）+ `tb_head.v`（对账用 HEAD 快照） |

⭐ **驱动 bat 的两行新回声顺手自证了价值**：本轮我把 P7B_MUT 目录名打错一次
（`mut_snapfixed` vs 实际 `mut_fixed`），新加的 `MACD` 守卫**直接 `[PATHGUARD FAIL]` 退出**
（而不是闷头编另一棵树 / 报 `exit 0`）—— 这正是本工程"真空门"那一族要拦的形态。

```bash
# A 正例
cmd //c '_proj_10g\p7b_chain\sim\run_tb_p7b_chain.bat'
# C 反例 (修复前 RTL) / B 对照 / D,E 定点变异
P7B_MUT='D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/notes/p7b_chain_cov/mut_prefix' cmd //c '_proj_10g\p7b_chain\sim\run_tb_p7b_chain.bat'
# （P7B_MUT 分别换 mut_fixed / mut_termdata / mut_termkeep）
```
