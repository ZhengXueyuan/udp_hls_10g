# P7b 工具 / RTL 工程债收口 —— 报告（2026-10-10）

> ⚠️ **本件由 TL 代落盘**（子 agent 写 `.md` 被 harness 拒绝）；正文按子 agent 最终回复整理，**未改一字数字/行号**。
> **范围** = **任务 1**（`sim/` 两变异器"失败仍落盘"地雷）· **任务 2**（`_proj_mdio` 两个潜伏项）。
> 本轮 **零构建 / 零上板 / 零 JTAG / 零 git 写**（只跑 xsim + 只读 git）。

## §0 一页结论

1. **任务 1 改了 0 个文件**。两个"地雷"文件在 **`0713a13`（2026-10-10 08:46:36）已修好并入库**，且与工作树**逐字节相同**（sha256 逐字 + `cmp` 空输出）；消费门用**裸相对文件名** ⇒ **活件 = 修复件**，`D:\repo` 下**无第三份镜像**。
2. **负对照实测**（临时副本；旧版 = 从 `0713a13^` 抽出、且与提交记录"旧 md5"**逐字相符**的修复前活件）：旧形态在 `MUTFAIL` 之后**照样落盘** —— `mut_c6.v` = **140,499 B = LF 归一化后的源文件逐字节拷贝**（其替换文本 **0 命中**、原句仍在），**14 件全落、RC=1**；新形态 = `MUTGEN FAIL 1` + `PURGED × 14` + **`mut/` 空** + RC=1。
3. **任务 2 两条潜伏项现核均成立**：`mdio_master.v:29` 逐字 `// 1-cycle pulse; ignored while busy`；`:52` 逐字 `wire tick = (div_cnt == DIV[15:0] - 16'd1);`。
4. **任务 2 判据 2×2 矩阵实测**：旧 RTL × 新 TB = **`== RESULT: FAIL (4 errors) ==`**（含**实测 1 clk 半周期 ⇒ 50,000,000.0 Hz**）；新 RTL × 新 TB = `PASS`；**新 RTL × 旧 TB = `PASS`**，且 `INFO frame span = 512 clk (busy rose @3653, fell @4165)` 与 **2026-09-28 历史基线逐字相同** ⇒ **只加不破**。
5. **未做到**：MDIO 地址 0/1 应答复核（**需板**，已由 TL 排到板级轮）· 板级重建/VIO 复测（本轮**禁 Vivado**，§2.5 只列命令不执行）· `mdio_vio_top.v` 未接线（**不在本轮可改集内**）。

---

## §1 任务 1：两个变异器 —— 纯核实（不重修）

### 1.0 【单列】清单 #21 / §3-C5 陈述与源码不符

**清单原文**（`P7B_OPEN_ITEMS.md`，mtime 2026-10-10 08:01，**早于修复提交 45 分钟**）：
- `:39` 逐字：`| **21** | **同族变异器"失败仍落盘"地雷** | … **仍在**（本轮现核） | 只在现役那支（author_gate）修了 | …`
- `:329` 逐字（部分）：`… = **同一颗"失败仍落盘"地雷仍在**（MUTFAIL 打印后 continue，但随后**仍无条件写盘**，最后才 MUTGEN FAIL + exit 1）—— **未修**。`
- `:330` 逐字（部分）：`… = **同类地雷**（MUTFAIL 后仍写盘，末尾 MUTGEN FAIL + exit 1）`

**实际**：两件在 **`0713a13` 已修好并入库**；**之后** HEAD 又被平行轮推进（本轮现核时为 `faee172`），但**这两件自 `0713a13` 起一字未动**。
```
$ git show --stat --format= 0713a13 -- sim/p7b_stagec_tx/mk_mut_tx.py sim/p7b_longsend/mk_mut_cont.py
 sim/p7b_longsend/mk_mut_cont.py | 161 ++++++++++++++++++++++++++++++++-------
 sim/p7b_stagec_tx/mk_mut_tx.py  | 164 +++++++++++++++++++++++++++++++++-------
 2 files changed, 273 insertions(+), 52 deletions(-)
$ git status --short -- <那两件>      ⇒ (空输出 = 干净)
```
**成因（诊断）**：清单写作时（08:01）两件确实有病；修复在 08:38–08:46 落地 ⇒ **清单从此未回写**。
派单里"`MUTFAIL` 还在打印 ⇒ 地雷还在"这条判据**本身无效** —— **修复后的形态照样打印 `MUTFAIL`**（它现在是"失败**记录**行"，不再是"失败**后仍落盘**"的指示符）
⇒ ⭐ **标记存在 ≠ 缺陷存在**。

### 1.1 逐行控制流现核：锚点不中时，到底还会不会落盘？

**答：不会。** 两件的写盘语句都在 `if fails: … return 1` **之后**（顺序上不可达）。

**`sim/p7b_stagec_tx/mk_mut_tx.py`**（worktree == HEAD，sha256 `900c9876b0728760e22dd25dc1c854907454b9f852a0db68500920bd9cdece8e`，14,824 B，CRLF=0）：

| 行号 | 逐字原文 | 作用 |
|---|---|---|
| `:230` | `print("MUTFAIL %s: pattern hits=%d expect=%d" % (name, h, e))` | 失败**记录**（不是落盘） |
| `:231` | `fails.append(name)` | 失败进集合 |
| `:233` | `if dry:` | dry-run 分支 |
| `:239-240` | `print("DRYRUN %s (0 bytes written)" % …)` / `return 0 if not fails else 1` | **dry-run 在此返回 ⇒ 永不到写盘** |
| **`:242-245`** | `if fails:` / `print("MUTGEN FAIL %d" % len(fails))` / `purge(results)` / `return 1` | ⭐ **"不落盘"的那一行 = `:242 if fails:` ⇒ `:245 return 1`**（写盘在它之后） |
| `:247-253` | `now = sha256_bytes(open(SRC,"rb").read())` … `SRC-CHANGED during generation:` … `purge(results)` / `return 1` | 头/尾 sha256 守卫 |
| `:255-259` | `texts = [(name, note, render(src, subs)) …]` … `os.makedirs(OUT, exist_ok=True)` … `print("WROTE %-10s %s" …)` | **唯一写盘点（`:258`）** —— 只有 `fails == []` 且源未变才可到这里 |
| `:261-267` | `SRC-CHANGED after write:` … `purge(results)` / `return 1` | 落盘后再核一次 |
| `:276-284` | `def purge(results):` … `os.remove(p)` / `print("PURGED stale %s" % p)` | 失败路径净化 |

**`sim/p7b_longsend/mk_mut_cont.py`**（sha256 `2864223e1cc33ffa3b797736618504cc5a2ec16f76c12b34a0f3fcd820387db7`，10,470 B，CRLF=0）：同形、行号平移 —— `:155` MUTFAIL 打印 · `:156` `fails.append` · `:158`/`:164-165` dry-run 返回 · **`:167-170` `if fails:` ⇒ `purge` + `return 1`** · `:172-178` SRC-CHANGED 守卫 · `:180-184` 写盘（`:183`） · `:186-192` 落盘后守卫 · `:201-209` `purge()`。

### 1.2 负对照（实测；全在临时副本，仓内文件零改动）

**方法**：把修复前（`0713a13^`）的脚本逐字取出、跑在临时树里（`rtl/` 放真源码副本、`mut/` 为出生目录）。
**忠实性自证**：抽出的旧件转 CRLF 后 `md5 = 664024090c2070fc3a22ed7691017f36` = **`0713a13` 提交里记录的"旧 md5"逐字相符**；
`mk_mut_cont.py` 旧件（LF）`md5 = 3d59d7045ac3cc798d55b815c3eaf6f4` = 同样逐字相符 ⇒ **跑的就是修复前的活件**。
**"锚点不中"的造法**：只改源副本的**一个锚点字符串**（TX：注释里删一个 `§`；cont：给 `!CONT_OK` 加一对括号 —— Verilog 语义逐位等价），`diff` 各只 1 行。

#### (a) 锚点不中（`MUTFAIL` 路径）

| 臂 | 结果（逐字） | 产物 |
|---|---|---|
| **旧版 × 锚点不中（TX）** | `MUTFAIL mut_c6: pattern hits=0 expect=1` → **`WROTE mut_c6  …`** → `MUTGEN FAIL 1` · **RC=1** | **14 件全落**；`mut_c6.v` = **140,499 B**，sha256 `aece476f…d9d5eb` **== `sha256(norm(源))`**；判据：其**替换文本** `"svc_x     = svc;"` 命中 **False**、**原句** `"svc_x     = svc && !ctrl_adv_inflight;"` 命中 **True**（对照：同轮 `mut_c1.v` 替换文本命中 True ⇒ 除该件外都真打上了） |
| **新版 × 同一锚点不中（TX，+ 预置陈旧 `mut/`）** | `MUTFAIL mut_c6: …` → `MUTGEN FAIL 1` → **`PURGED stale …\mut_c1.v` ×14** · **RC=1** | **`mut/` 空（count=0）** |
| **旧版 × 锚点不中（cont）** | `MUTFAIL m4_term_open: …` → **`WROTE m4_term_open …`** → `MUTGEN FAIL 1` · RC=1 | 5 件全落；`m4_term_open.v` = **82,036 B**，sha256 `7ebe755e…8a987e` **== 源文件 sha256（逐字相同）** |
| **新版 × 同一锚点不中（cont，+ 预置陈旧）** | `MUTFAIL m4_term_open…` → `MUTGEN FAIL 1` → `PURGED` ×5 · RC=1 | **`mut/` 空（count=0）** |
| **新版 × 干净源（正控，TX）** | `ANCHORS: all 14 mutants matched (18 subs, each hits==expect)` / `MUTGEN OK (14 mutants)` · RC=0 | 14 件落盘 |
| **新版 × 干净源（正控，cont）** | `ANCHORS: all 5 mutants matched (5 subs, each hits==expect)` / `MUTGEN OK (5 mutants)` · RC=0 | 5 件落盘 |

**量化对照**：真变异件 `sim/p7b_stagec_tx/mut/mut_c6.v` = 134,751 B（陈旧件，见 §1.5）／新鲜生成件 = 140,452 B，
而**地雷产物 = 140,499 B = 源文件本身** ⇒ 它**比任何真变异件都长，且与源逐字节相等**。

#### (b) `--dry-run`
判据 = `mut/` 内**全部文件的 sha256 聚合值 + 文件数**前后不变：

| 组 | 输出尾（逐字） | RC | `mut/` 前→后 |
|---|---|---|---|
| TX 干净 | `DRYRUN OK (0 bytes written)` | 0 | 14 件 / 聚合 `d63dddbf58221888…` → **同 14 件 / 同聚合值** |
| CT 干净 | `DRYRUN OK (0 bytes written)` | 0 | 同 → 同 |
| TX 打坏锚点 | `mut_c6    s1   0/1 <== MISMATCH` + `BROKEN` + `DRYRUN FAIL 1 (0 bytes written)` | **1** | 同 → 同 |
| CT 打坏锚点 | `m4_term_open       s1   0/1 <== MISMATCH` + `BROKEN` + `DRYRUN FAIL 1 (0 bytes written)` | **1** | 同 → 同 |

⇒ **`--dry-run` 真的 0 字节**（含失败臂：**连 purge 都不做** —— dry 分支在 `if fails:` 之前返回）。

### 1.3 同族普查 —— 两条陈述都成立

| 文件 | 清单陈述 | 现核 | 行号证据 |
|---|---|---|---|
| `sim/p7b_longsend/tc_mut/mk_mut_tc.py` | "无'半套用落盘'形态；失败形态 = 产物**不完整**" | ✅ **成立** | `:34-38` `def sub_once(src, old, new, tag):` → `n = src.count(old)` → `if n != 1:` → `raise SystemExit("ANCHOR-FAIL [%s]: count=%d (expect 1)" % (tag, n))`（**立即抛，无写盘**）；每个变异 = 一次 `sub_once` 后**立即**写（`:52`/`:61`/`:70`）⇒ 锚点不中时**它自己不会被写**，**先前已成功的件留着** ⇒ 集合不完整，不是"用源文件冒充变异件"。⚠️ 附带（清单未声称）：**无** `purge()`、**无** sha256 守卫、**无** `--dry-run` |
| `sim/p7b_stagec_tx_regress/mk_mut.py` | "无该形态" | ✅ **成立** | `:66-69` `if n != 1:` / `print("FAIL %s: anchor hits=%d (expect 1)" …)` / `ok = False` / `continue`（**失败即跳过，不写盘**）；写盘只在成功路径 `:86-88`；末 `:96-97` `if not ok:` / `sys.exit(1)`。另有 5 条自证（基线 sha256 `:28/:53`、1 字节删除证明 `:78-84` 等） |

### 1.4 修复件 vs 活件 —— 逐字节相同；无镜像
```
$ git show HEAD:sim/p7b_stagec_tx/mk_mut_tx.py | sha256sum  -> 900c9876…cdece8e
$ sha256sum sim/p7b_stagec_tx/mk_mut_tx.py                  -> 900c9876…cdece8e
$ git show HEAD:… | cmp - sim/p7b_stagec_tx/mk_mut_tx.py     -> (空输出 = 无差异)
$ git show HEAD:sim/p7b_longsend/mk_mut_cont.py | sha256sum -> 2864223e…0387db7
$ sha256sum sim/p7b_longsend/mk_mut_cont.py                 -> 2864223e…0387db7
```
**消费侧**：`sim/p7b_stagec_tx/run_tx_ovl_gate.bat:42` 与 `sim/p7b_longsend/run_cont_gate.bat:46` 都在 `cd /d "%HERE%"` 之后用**裸相对文件名**调用，
且 `|| (… exit /b 1)` ⇒ 生成器 RC=1 被门当硬失败。
**镜像普查**：`find D:/repo -name mk_mut_tx.py -o -name mk_mut_cont.py` ⇒ **只有 3 条**：两份活件 + `sim/p7b_stagec_tx_regress/author_gate/mk_mut_tx.py`（**有意存在的另一支** = 现役模板）。**无"另一 checkout"镜像**。

### 1.5 ⭐【本轮新发现·意外项】旧门 `sim/p7b_stagec_tx/mut/` 的缓存 **14/14 陈旧**
```
on-disk(HEAD)  vs  fresh(现役 rtl/tcp_tx_frame.v)
mut_c1.v         134817        140518     NO  <== STALE
…（14 件全 NO）        STALE count = 14 / 14
```
| 时刻 | 事件 |
|---|---|
| 08:38 | `mk_mut_tx.py` 修复（头注释记录当时源 = **136,970 B / 2,170 CRLF**） |
| 08:42 | 生成 14 件（`mut/mut_c6.v` mtime 08:42:06）→ 08:46 随 `0713a13` 入库 |
| **08:52:35** | `rtl/tcp_tx_frame.v` 被改（现 142,733 B / 2,232 CRLF）—— 对应提交 **`34fb68b`「P7B 构建 F：三个窗口侧仪器」** |

逐字判据：`grep -c stat_winstall_cap` 在 **HEAD 的 `tcp_tx_frame.v` = 9**、在 **在盘 `mut_c6.v` = 0**。
**评级 = 低危（缓存陈旧，不是活件错）**：消费门 `:42` **每次先重生成** ⇒ 跑到门就自动新鲜。但① 它们是**已入库的被跟踪件**，不跑门直接读就会读到"另一修订的变异件"；② 这正是修复件 docstring 描述的危害形态；③ **对照**：现役 `author_gate/mut/` 同法重生成 **15/15 逐字节新鲜** ⇒ 现役支维护良好，问题只在旧门那支。
**建议处置**：删掉这 14 个被跟踪件（让"要么完整要么空"覆盖到仓库）或重生成入库；⚠️ 因 `rtl/tcp_tx_frame.v` 正被平行轮改动，**建议等其收口**。

---

## §2 任务 2：`_proj_mdio` 的两个潜伏项

### 2.1 现核（两条都成立）

**① `busy` 期 `start` 静默丢弃 + `done_sticky` 报上一次事务**（未改前 sha256 `6a0b4c58…027b35`，4,246 B）：
- `:29` `input wire start, // 1-cycle pulse; ignored while busy` ← **缺陷的书面化**
- `:70-87`：`end else if (!busy) begin` … `if (start) begin` … `done_sticky <= 1'b0;` ⇒ `start` **只在 `!busy` 分支被看**，`busy` 期无任何分支消费 ⇒ 丢弃
- `:104` `done_sticky <= 1'b1;`（帧尾置位）· `:85` `done_sticky <= 1'b0;`（**新事务被接受时才清**）⇒ **被丢弃的 start 不清 `done_sticky` ⇒ 主机随后轮询读到上一次事务的结果**

**② `DIV[15:0]` 静默截断**：`:52` 逐字 `wire tick = (div_cnt == DIV[15:0] - 16'd1);`；`DIV` = `parameter integer DIV = 25`（`:24`），`div_cnt` 只有 `[15:0]`（`:49`）
⇒ `DIV=65537` → `DIV[15:0]=1` → `tick = (div_cnt == 0)`；而 `tick` 拍正是把 `div_cnt` 清 0 的拍（`:89`）⇒ **每拍都 tick** ⇒ MDC 半周期 1 clk ⇒ **50 MHz @100MHz**（请求值的 65537×、clause-22 上限的 20×）。**实测坐实见 §2.3**。

### 2.2 改法（只加不破；两处都可观测）

**① 被拒的 `start` 看得见（不改为"挂起"）** —— 理由：`start` 的书面契约就是 "ignored while busy"，
**挂起**会制造"一次 pulse ⇒ 之后还多跑一帧"的**新静默行为**，正是本轮要消灭的形态；**拒绝 + 粘滞标记**才是纯增量。
实现为**独立 always 块**（**物理上不可能挪动 FSM 的拍** —— 若写成 FSM 内分支，`busy` 期那拍会夺走 `tick`/`div_cnt` 分支，帧长就变 1 clk）：
```verilog
    always @(posedge clk) begin
        if (!rstn)               stat_start_lost <= 1'b0;
        else if (!busy && start) stat_start_lost <= 1'b0;   // accepted -> clear
        else if (busy && start)  stat_start_lost <= 1'b1;   // dropped  -> sticky
    end
```
语义 = "自上一次**被接受**的 start 起，至少有一个 start 被丢"；与 `done_sticky` **同刻清**。
**为什么粘滞位而非计数器**：板上读法是 VIO 一根探针位（计数器要 8 位，而 `mdio_vio_top.v` 本轮不在可改集内）。

**② `DIV` 守卫 = 饱和到上限 + `param_bad` 判据字符号**（选"饱和"而非"报错停摆"：板级工具在参数写错时应**以安全方向继续工作**；**方向选慢端**：过慢的 MDC 无害、过快的 MDC 有害）：
```verilog
    localparam integer DIV_MAX  = 65536;
    localparam integer DIV_SAFE = (DIV < 1) ? DIV_MAX : ((DIV > DIV_MAX) ? DIV_MAX : DIV);
    localparam        PARAM_BAD = (DIV < 1) || (DIV > DIV_MAX);
    assign param_bad = PARAM_BAD;
    wire       tick = (div_cnt == DIV_SAFE[15:0] - 16'd1);   // 原为 DIV[15:0]
```
- **守卫范围 = "16 位 `div_cnt` 可表示"（1..65536）**，**不是**"满足 clause-22（≤2.5 MHz）" —— 后者会把 `DIV=4`（TB 自用）也判非法并改变现役板配置可用性；**口径必须写清**。
- **`param_bad` 是静态常量**（`DIV` 是 elaboration 参数）⇒ 综合期定值、**零运行代价**。
- **谁消费它**：(a) **TB** 守卫臂（硬判据）；(b) **板级 `mdio_vio_top`（尚未接，§2.4）**。
- **只加不破的等式**：`1 ≤ DIV ≤ 65536 ⇒ DIV_SAFE == DIV` ⇒ `tick` 与守卫前**逐位相同**；新增仅 `param_bad`（常量）+ `stat_start_lost`（1 FF、与 FSM 无耦合）。现役板构建 `DIV=25`（`mdio_vio_top.v:124`）⇒ 命中该等式。

**改动清单**：`_proj_mdio/rtl/mdio_master.v`（**4,246 B → 7,274 B**；sha256 `6a0b4c58…` → `89d5c89e295ce988b2013ecdb07f94d158001e0ef1e5585020f82e481f8d35db`；完整 diff = `…/mdio_master.diff`）：
头注释 10 行 · 端口表**末尾**追加 2 个输出（`:53-55`；末尾追加是刻意的 ⇒ 任何按位置例化也不位移）· DIV 守卫 20 行（`:58-77`）· `tick` 一行改（`:83`）· `stat_start_lost` 独立 always 块 14 行（`endmodule` 前）。
`_proj_mdio/tb/tb_mdio_master.v`（**12,715 B → 21,858 B**；sha256 `3c23ea04…` → `8c8dc2c83c09cc9a80bfc9995c6e55233095369de5cc67612e65e4581bc10d7d`）：主 DUT 接 2 新端口 · `dut_bad #(.DIV(65537))` + `dut_ref #(.DIV(65536))` 两臂（各自**悬空**引脚，不碰共享 MDIO 总线）· 半周期计数器（参考沿与测量沿**同一 always 块** ⇒ `clk_cnt` 偏移在差值里对消）· 新任务 `do_read_lost_start` · `do_read/do_write` 各加"干净事务不得置位 `stat_start_lost`"判据 · 收尾 4 条守卫判据。

### 2.3 判据与实测：2×2 矩阵（独立工作目录各一跑；xsim 2025.2 标准流）

| RTL \ TB | 旧 TB（HEAD 版） | 新 TB |
|---|---|---|
| **旧 RTL**（`pristine` 逐字 + shim） | `rm4`：`== RESULT: PASS ==`（12 项） | `rm2`：**`== RESULT: FAIL (4 errors) ==`** ⭐ **改之前真的会红** |
| **新 RTL**（带守卫） | `rm3`：`== RESULT: PASS ==` ⭐ **只加不破** | `rm1`：`== RESULT: PASS ==`（12 既有 + 8 新增） |

**rm2（负对照）逐字**：
```
FAIL busy-start-rej: start dropped during busy was NOT recorded (stat_start_lost=0)
INFO DIV-guard: DIV=65537 -> first MDC half-period 1 clk (period 2 clk = 50000000.0 Hz @100MHz)
INFO DIV-guard: DIV=65536 -> first MDC half-period 65536 clk (period 131072 clk = 762.9 Hz @100MHz)
FAIL DIV-guard: DIV=65537 clamped but param_bad=0 (clamp would be silent)
FAIL DIV-guard: clamped half-period 1 clk is FASTER than the legal maximum (want >= 65536)
FAIL DIV-guard: clamped arm 1 clk != legal-max arm 65536 clk (clamp target wrong)
== RESULT: FAIL (4 errors) ==
```
**rm1（新 RTL × 新 TB）逐字**：
```
PASS busy-start-rej: busy-period start rejected, no extra MDC (64 edges), stat_start_lost=1
PASS after-lost: phy 1 reg 3 -> c915
PASS stat_start_lost cleared by the next accepted start
INFO DIV-guard: DIV=65537 -> first MDC half-period 65536 clk (period 131072 clk = 762.9 Hz @100MHz)
INFO DIV-guard: DIV=65536 -> first MDC half-period 65536 clk (period 131072 clk = 762.9 Hz @100MHz)
INFO DIV-guard: pre-guard truncation gave DIV[15:0]=1 -> half-period 1 clk -> 50000000.0 Hz
PASS DIV-guard: DIV=65537 raises param_bad (clamp is observable)
PASS DIV-guard: param_bad stays 0 for legal DIV (65536 and the main DUT's 4)
PASS DIV-guard: clamped MDC (half-period 65536 clk) is not faster than the legal value
PASS DIV-guard: clamped arm == legal-max arm (both 65536 clk, measured on two DUTs)
== RESULT: PASS ==
```
**判据写清**：
- **(a) 忙期 start**：① `stat_start_lost == 1`（该 start 被**明确标记**）**且** ② **MDC 拍数不变**（`frame_len_check` 仍要求**恰好 64 个上升沿** ⇒ "没有产生任何 MDC 拍"用**精确计数**判）**且** ③ 该事务正确 **且** ④ **紧邻的正常事务**正确。
- **(b) DIV 越界**：① `param_bad == 1` **且** ② **实测半周期 ≥ 65536 clk** **且** ③ **钳位臂实测半周期 == 合法最大臂（`DIV=65536`）实测半周期**（两台 DUT 各测一次，**实测相等**而非按算术假定）**且** ④ 合法值的 `param_bad` 必须为 0。
- **"改之前会红"的演示**：`rm2` = 新 TB 打在**逐字未改的旧 RTL** 上；旧核缺那两个端口 ⇒ shim **忠实建模**（`diff` 证明**旧核正文逐字未动、只有模块名多一个 `_legacy` 后缀**；两个不存在的观测量按语义钉 0）。红的是**行为**（`stat_start_lost=0` + 实测 1 clk/50 MHz + `param_bad=0`），**不是**编译错。
- **只加不破第二重见证**：`rm3`（旧 TB = 完全不认识新端口的例化）⇒ 既有 12 项全绿，`INFO frame span = 512 clk (busy rose @3653, fell @4165)`、`512 MDC edges` **与 2026-09-28 历史基线（`_proj_mdio/_sim/xsim.log`）逐字相同**。
- **编译级第三重见证**：用**真 `vio_0` 仿真网表** + `unisims` 对**真顶层 `mdio_vio_top`** 做 `xelab`（只精化不跑激励）⇒ **通过**（`Built simulation snapshot top_elab`）；
  唯一提示 = `WARNING: [VRFC 10-3645] port 'param_bad' remains unconnected for this instance [mdio_vio_top.v:123]` ⇒ 未改 wrapper 对新端口是**无害悬空**。⚠️ **编译级**证据（不含功能），`mdio_vio_top` 自身未跑功能仿真。

### 2.4 未做到 / 未判定（不掩饰）
1. ⛔ **MDIO 地址 0 与 1 都应答同一 PHY ID** —— **本轮未做：需板**（属总线/PHY 行为，xsim 无法裁决）。
2. ⛔ **`mdio_vio_top.v` 未接线**（不在可改集内）⇒ 新信号**在板上暂时看不见**。要看得见需两处同步（**未执行**）：
   `mdio_vio_top.v:143` 的 `vio_probe_in` 20 → 22 位并接 `{stat_start_lost, param_bad, …}`，且 `build_mdio.tcl` 的 `CONFIG.C_PROBE_IN0_WIDTH {20}` → `{22}`。
3. ⛔ **板级未跑**（本轮禁 Vivado/禁上板）⇒ "综合/实现/时序/上板正常"**均为未验证**。
4. ⚠️ **观察（未改）**：TB 的 `tag` 参数是 `[127:0]`（16 字节），最初的 18 字符 `"busy-start-rejected"` 被**左截**成 `y-start-rejected`（xsim `%0s` 静默截断）⇒ 已改短；**今后 tag 别超 15 字符**。
5. ⚠️ **工具侧伪失败（已定位，非仿真问题）**：4 次 `cmd` 报 `系统找不到指定的路径。`（rc=1、无日志）。根因 = 命令里 `"…\\task2\\$d\\run.bat"` 的 `\\$` 相邻，工具层转义把 `$d` 吃成**字面**（`set -x` 逐字复现 `'…\task2$d\run.bat'`）⇒ cmd 收到不存在路径。**修法 = 先 `cygpath -w` 成变量再展开**（此后 5 跑全绿）。

### 2.5 下一步（只列命令，本轮不执行）
```bat
rem ① 重建位流（⚠️ create_project -force 会摧毁 pj_mdio 里上一轮的 timing_summary.rpt，先归档）
cd /d D:\repo\XCKU5PMini\_proj_mdio
vivado -mode batch -source build_mdio.tcl -nojournal -nolog
rem 期望：SYNTH/IMPL 100% · TIMING_WNS/WHS 打印 · BITSTREAM 路径+字节数 · === BUILD DONE ===
rem 现役基线 = 2026-09-28：WNS +7.091；本轮只加 1 FF + 1 常量，预计不变

rem ② 烧录 + VIO 复测（JTAG 降频 1MHz；DONE=HIGH 才算成功）
vivado -mode batch -source probe_phy.tcl -nojournal -nolog
rem VIO 复读 PHY ID 应为 0x001CC915（reg2=0x001C / reg3=0xC915）
```

---

## §3 命令 / 原始输出索引（可逐条复跑）

| 证据 | 路径（`…` = `…\_proj_10g\notes\p7b_tool_debt_20261010`） |
|---|---|
| 任务 1 六组用例原始 stdout + RC | `…/task1/logs/{TX,CT}_C{1,2,3}_*.txt` |
| 地雷产物 vs 源 的逐字节判据 | `…/task1/logs/{TX,CT}_C1b_rigorous.txt` |
| `--dry-run` 四组 | `…/task1/logs/DRYRUN_{TX,CT}.txt` |
| 修复前活件的忠实性（md5 对表） | §1.2；抽取件 = `…/tmp/OLD_mk_mut_{tx,cont}.py` |
| 陈旧件普查 | `…/task1/logs/FRESH_gen.txt` · `…/task1/logs/FRESH_author_gen.txt`（author_gate **15/15 新鲜**） |
| 任务 2 2×2 原始 stdout | `…/task2/_rm{1..4}_*.stdout.txt` + 各目录 `xsim.log`/`xelab.log` |
| 守卫 RTL 完整 diff | `…/mdio_master.diff` |
| 未改前原件保全 + sha256 | `…/pristine/mdio_master.v.orig`（`6a0b4c58…`）· `…/pristine/tb_mdio_master.v.orig`（`3c23ea04…`）· `…/pristine/SHA256_PRISTINE.txt` |
| 2×2 沙箱生成器（可复跑） | `…/task2/setup_sims.py`（含 shim 与 runner bat 模板；自证 `legacy body unchanged: True`） |
| 打坏锚点的 doctor | `…/task1/doctor.py` |
| 编译级顶层见证 | `…/task2/elab_wrapper/`（真 `vio_0` 仿真网表 + `glbl.v` + unisims）· `…/task2/_elab_wrapper.stdout.txt` |

**本轮对 `udp_hls_10g` 的写操作 = 0**（`sim/**`、`rtl/**`、`tb/**`、`board/**`、`hls/**` 零改动；`git status --short` 对这几个目录**空输出**；两件变异器及在盘 `mut/` 一个字未动）；
`_proj_mdio/` 只改了**被点名允许**的两个文件，其**未改前原件已保全**。⛔ 未烧板 / 未跑 Vivado / 未动对端 / 未做任何 git 写。

---

## §4 需要 TL 决定 / 落笔的三格

1. **清单回写**：`P7B_OPEN_ITEMS.md` #21 / `:329` / `:330` / `:335` 标【已修 @0713a13】（§1.0）。（**已由文档订正轮完成**）
2. **新登记项**：`sim/p7b_stagec_tx/mut/` **14 个已入库的陈旧变异件**（§1.5）—— 建议等平行"构建 F"轮收口后再清 / 重生成。
3. **板级轮**：MDIO 地址 0/1 应答复核（**需板**）；若要板上看两个新信号，先做 `mdio_vio_top.v` + `build_mdio.tcl` 的探针位宽两处同步（§2.4-2）。
