# P7B-WU —— 对抗审查 F1/F2 两条真问题的修复（施工 + 证据）

- 日期：**2026-10-07**　轮次：**P7B-WU 二轮修补（RTL 修复 agent）**　基线 HEAD = **`95c9485`**（工作区 = 二轮未提交改动）
- 被审件 = `_proj_10g/notes/P7B_WU_P1P2_REVIEW.md`（它的 **F1** = 注释加法算错；**F2** = §1.3 "净损失消除" 对 `winq==0` 不成立）
- 性质：**RTL 修复 + 注释订正 + 仿真验证**。**未上板、未烧板、未跑 Vivado 构建/实现**（时序由下一次构建收口）。
  **未提交 git**。**未写 `0x08`**、**板子没碰**。
- ⚠️ 一条不许当"已验"：**本轮所有读数止于仿真/静态/编译面**；**板级与构建面读数一个都没有**。

---

## 0. 一页速查

| # | 项 | 裁定 | 读数（一次看全） |
|---|---|---|---|
| ① | **F2**：`winq==0` 时二轮修前的武装项恒真 ⇒ 触发支结构性被挡死（"永不发"是**意外**） | ✅ **改成显式语义：`winq==0` ⇒ 本块一个动作都不做**（整块 guard）。理由 = 零配额没有东西可通告 | 修前/修后**同激励逐字对照**：`wu_zero` 修前钉 **1** / 修后恒 **0**；`wu_pend` **两版都 0 次**（`tb/tb_wu_f2.v` PH0） |
| ② | F2 的等价性 | ✅ **穷举证明**：全 **65536 winq × 全 65536 wscan = 2³² 格点**；`winq != 0` 上武装/触发谓词与修前**逐位相同（差异数 0）**；只有 `winq==0` 一档按"永不发"改写 | `sim/p5wu_f2fix/f2_equiv.py` → `F2_EQUIV OK`（9 判据全 PASS，日志 `f2_equiv.log`） |
| ③ | F2 的两侧负对照（**证明判据能分辨**） | ✅ ①"会发"侧：变异体（`end else if`→`end if`）在 `winq==0` **真的发**（6 次）⇒ DUT 的 0 次不是空判据；②"不发"侧：`winq ∈ {1,2,3,0xC000,0xC00}` 各档两臂**都发 1 次** ⇒ F2 没把可达路径一起关掉 | `tb/tb_wu_f2.v` NEG0/NEG1/PH1d/PH2b/PH3b/PH4c/PH5c |
| ④ | **F1**：`wrapper_p4.v` 注释 `63 = 14+22+3+24+4`（=67） | ✅ **就地订正为 `14+22+3+(24-4)+4`**（p7bdp 槽 2..5 不进窗口，由 tx 束装配）；并登记"HEAD 那行 `65≠61` 是同款老毛病" | `board/wrapper_p4.v:3897-3905` |
| ⑤ | 回归（点名的 5 门 + 审查的会话边界门） | ✅ **全绿**（首轮 WU 门**逐字一致**） | §3 |

---

## 1. F2 —— `winq == 0` 的显式语义（功能修复）

### 1.1 机理（三行，可核）

| 环节 | 事实 | 出处 |
|---|---|---|
| `winq==0 ⇒ wscan ≡ 0` | `fq_calc(0, oc) = (oc >= 0) ? 0 : …` **恒 0** | `rtl/app_ctrl.v:638-645`（`fq_calc`） |
| 于是二轮修前的武装项**恒真** | `(0 < 0) \|\| (0 == 0)` = 真（`(winq/4 = 0)` 时前项永假、后项永真） | 改前行：`rtl/app_ctrl.v:1244-1245`（改前版 = `sim/p5wu_f2fix/app_ctrl_prefix.v`） |
| ⇒ `else if` **永不求值** | 触发支被结构性地挡死；且**每个扫描拍**重写 `wu_zero=1` | 同上 |

### 1.2 改前 / 改后（文件:行号）

- **改前**（= 二轮未提交状态，快照 `sim/p5wu_f2fix/app_ctrl_prefix.v`，未改名时 sha256 前缀 **`871eab12`** = 编辑前的 `rtl/app_ctrl.v`）：
  `rtl/app_ctrl.v:1244-1252`（改前行号）——`if (武装) … end else if (触发) … end`，**无 winq 前提**。
- **改后**（现役 `rtl/app_ctrl.v`，sha256 **`f6c5b296…`**）：
  - `rtl/app_ctrl.v:1296` `if (winq[pb_sid] != 16'd0) begin` ← **唯一新增的功能代码行**（+ 1 个配对的 `end`，原 8 行整体缩进一级）
  - 文件头契约登记：`rtl/app_ctrl.v:233-247`（F2 节）；C6 块说明：`:1281-1295`
- **改动量**：功能代码 **+1/−0 行**（`end` 是配对）；其余全是注释。纯代码 diff = `sim/p5wu_f2fix/f2_rtl_diff.txt`。

### 1.3 语义裁定 + 理由（为什么"永不发"是对的，不是"顺手挡掉"）

零配额时**我们没有任何东西可以通告**：`wscan ≡ 0` ⇒ 真发出去的也是一个 `win=0` 的 ACK，对端拿不到
一个字节的信用；该连接的信用恢复**只可能**来自 C15 的池补授（`rtl/app_ctrl.v:1211-1219`，`winq>0` 后
由上面的滞回正常接管）。
⇒ 把整块**显式**挡在 `winq != 0` 里：① 语义从代码读得出来；② 记法上**不留**"恒真武装顺带挡住触发"
这种调换 `if/else if` 顺序就会放出 `win=0` 帧的隐式依赖。

### 1.4 等价性 —— **穷举**证明（不是抽样、不是"显然"）

`sim/p5wu_f2fix/f2_equiv.py`（模型：`winq[15:2] = w>>2`、`winq[15:1] = w>>1`，16 位无符号比较，与 RTL 逐位一致）：

```
== F2 equivalence: PRE vs POST vs TARGET ==
   grid = winq 0..65535  x  wscan 0..65535   (2^32 points, numpy, chunk=512)
  [PASS] A: POST == TARGET (winq!=0 时 wscan<max(winq/4,1); winq==0 时永不发)  [2^32 格点]
  [PASS] B: winq != 0 的全部 65536 档上, POST 武装 == PRE 武装 (逐位相同)
  [PASS] C: winq != 0 的全部 65536 档上, POST 触发 == PRE 触发 (逐位相同)
  [PASS] D: PRE 在 winq==0 行的武装为真的格点数 == 1 (唯一点 (0,0); 配合 E 即恒真) :: 实测 = 1
  [PASS] E: POST 在 winq==0 行 (全部 65536 个 wscan) 上武装/触发恒假 (显式永不发) :: 实测真值点 = 0
  [PASS] F: fq_calc(0, oc) == 0 对全部 17 位 oc (0..131071) 成立 => winq==0 时 wscan ≡ 0
  [PASS] G: winq in {1,2,3}: wscan==0 (武装) 与 wscan>=winq/2 (触发) 均可达 (oc 穷举见证)
  [PASS] G2: winq==0 不参与该可达性 (见 F: wscan 恒 0 ⇒ POST 恒假)
  [PASS] H: 产品配置子域 winq >= 3072 (含默认 0xC000) 上 PRE == POST (差异数 0) :: 差异数 = 0
F2_EQUIV OK (exhaustive 2^32 grid; PRE/POST/TARGET)
```

**三句读法**（都在上面有判据支撑）：
1. **(A)** 实现 == 目标语义 `winq!=0 ∧ wscan < max(winq/4, 1)` —— 逐格点相等，2³² 全过。
2. **(B)(C)(H)** `winq != 0` 的**全部**取值上，武装/触发谓词与二轮修前**逐位相同** ⇒
   **产品配置（`winq = 0xC000`，以及任何 ≥4 的值）行为逐位不变**（判据 H 是 ≥3072 子域的单独对账，差异数 0）。
3. **(D)(E)(F)** `winq == 0` 一档：修前在 (0,0) 这一个格点为真 —— 而 (F) 证明该格点在 `winq==0` 时
   **必然**发生（`oc` 全 17 位穷举）⇒ **修前的"恒真"被坐实**；修后该行**全假**（显式永不发）。

### 1.5 TB 逐字对照 + 负对照（`tb/tb_wu_f2.v`，`sim/p5wu_f2fix/run_tb_wu_f2.bat`）

三臂**同激励/同 gnt/同波形**（锁步逐拍判：`lockstep violation cycles = 0`）：
`u_dut` = 修后 RTL / `u_pre` = 修前逐字快照（模块改名）/ `u_mut` = **变异体**（把生产块的 `end else if` 改成 `end if`，
即"触发支不再被恒真武装挡住" —— 专门用来在"会发"一侧给判据以牙）。
**下面是节选**（全量 38 条判据行 + `[READ]` 行的原件 = `sim/p5wu_f2fix/run/xsim_f2.log`）：

```
PH0: winq=0 -- DUT explicit no-arm; PRE arm saturated true (unfixed)
  PASS PH0c DUT wu_act=1 (data seen; artificial)      PASS PH0d PRE wu_act=1
  PASS PH0e DUT NOT armed (F2: winq==0 arm is explicitly off)
  PASS PH0f PRE armed (old arm is saturated true)
  PASS PH0g DUT still not armed after 8 more scans
  PASS PH0h PRE still armed after 8 more scans (rewritten every scan)
  [READ] PH0 fires: DUT=0 PRE=0 | wu_zero: DUT=0 PRE=1
  PASS PH0i both arms: 0 fires for winq=0 (non-regression; both never fired)
  PASS PH0j judge has teeth: same stimulus => DIFFERENT arm state (F2 delta seen)
  [READ] NEG mutant fires: s0=6 (DUT s0=0 PRE s0=0)
  PASS NEG0 would-fire mutant DOES fire at winq=0 (counter is live)
  PASS NEG1 winq=0 fire reading discriminates DUT vs would-fire mutant
  PASS PH1d both fired exactly once              (winq=1, 两臂 wu_mark=1 逐字)
  PASS PH2b both fired exactly once              (winq=2, wu_mark=2)
  PASS PH3b both fired exactly once              (winq=3, wu_mark=3)
  PASS PH4a both winq=0xC000 / PH4c fired once / PH4d both wu_mark=0xBF00
  PASS PH4e at exactly winq/4: both NOT armed (strict < holds)
  PASS PH4g at winq/4 - 1: both armed (not a dead gate)
  PASS PH5a..PH5d  winq=0x0C00 (=池/16): 武装/发射 1 次/wu_mark=0x0C00 两臂逐字
  PASS NEG2 mutant diff face logged: s2..s5 == PRE (1 each); s0 +6 / s1 +1 (threshold-0 corner)
  PASS Z1 lockstep across 2 arms / Z2 fire counts identical / Z3 total fires == 5
F2 GATE PASSCOUNT 38
F2 GATE OK
```
（bat 有**两条**硬判据：`F2 GATE PASSCOUNT 38` + `F2 GATE OK`，正对审查 §8.4"只 grep OK 串"那条弱点。）

**口径（如实）**：
- `winq==0` 档的"数据到达"是**人为制造**的（`winq=0` 时对端物理上发不进数据）⇒ 该档证的是**代码可达性**
  （与审查 §1.3 同口径），**不是**板级场景。`winq ∈ {1,2,3}` 与产品档的进度是物理可达的。
- **两版的 `wu_pend` 在可达态都是 0 次**：`wu_zero` 只在武装拍被置 1，而武装要求 `wu_act=1`；
  `wu_act` 只在 `ev_up/ev_down` 清，这两个事件**同拍也清 `wu_zero`** ⇒ 不存在 `wu_zero=1 ∧ wu_act=0` 的可达态。
  ⇒ **F2 是"显式化 + 防未来"修复，不是行为翻转**（唯一可观测差异 = `wu_zero` 寄存器态，见 PH0e/F）。
- **不可达态上有一条真差异**（登记，不当已解）：若人为置 `wu_zero=1 ∧ wu_act=0 ∧ winq=0`，修前会发一次
  `win=0` 的 wu、修后不发。裁决归"永不发"一侧（理由见 §1.3）。

---

## 2. F1 —— 注释加法订正（`board/wrapper_p4.v`）

- **改前**：`board/wrapper_p4.v:3900`（改前行号）
  ```
  .SNAP_NW    (SNAP_NW_P6E)       // 63 = 14+22 (snap_seq) + 3+24+4 (P7b 三束: BIZ 加 10, WU 加 2)
  ```
  `14+22+3+24+4 = 67 ≠ 63`。
- **改后**：`board/wrapper_p4.v:3897-3905`（现役）
  ```
  .SNAP_NW    (SNAP_NW_P6E)       // 63 = 14+22 (snap_seq) + 3+(24-4)+4 (P7b 三束)
                                  //   ⚠️ 算式订正 (2026-10-07 二轮): 旧注 "14+22+3+24+4" = **67** ≠ 63。
                                  //   正确项数 = **24-4**: p7bdp 束有 24 个槽, 但槽 **2..5 不进窗口** ...
  ```
- **`24-4` 的依据（源码级）**：`SNAP_P7BDP_NW = 24`（`board/wrapper_p4.v:3132`）是**束的槽数**；
  上面 `g_p7bdp` 的 generate（`board/wrapper_p4.v:3599-3609`）里 `gi ∈ {2,3,4,5}` 落 `32'd0`
  （原文注释"槽 2..5: 由 tx 束装配"）⇒ 该束进窗口的项数 = **20**。
  对账：`14 + 22 + 3 + 20 + 4 = 63` ✓（与审查 A1c 的 `14+22+3+(24-4)+4=63` 同值）。
- **同款老毛病**：HEAD 那行写 `61 = 14+22 + 3+22+4`（= **65**）**同样不成立**（`22-4 = 18` 才是进窗口项数）。
  本轮**碰到这行就地订正**，并在注释里登记"这是继承的老毛病"。

---

## 3. 逐门读数（按任务点名的清单，逐条）

> ⚠️ **下表全部是"最终修订"上的读数**（`rtl/app_ctrl.v` sha256 **`f6c5b296…`** / `board/wrapper_p4.v` **`76945167…`**），
> **顺序执行**（一次一门，无 xsim 并跑 —— 全局 #50）。stdout 原件留在 `sim/p5wu_f2fix/logs/*.out`
> （个别门的逐判据行在它自己的 `run/` 或 `fcrun/` 日志里，表内已注明）。

| 门 | 命令 | 读数 | 退出码 |
|---|---|---|---|
| 作者的三臂门 | `cmd //c 'sim\p5wu_p1p2\run_tb_wu_p1p2.bat'` | `PASS=27 FAIL=0`；`PH1d/e/f/g` 全 PASS；fires `DUT c0=1 c1=0 c2=1｜BASE c0=0 c1=1 c2=1｜LEG c0=1 c1=0 c2=0`；`[READ] stat_wu: dut=2 base=2 leg=1`；`lockstep violation cycles = 0`；`P1P2 GATE OK` —— **与审查 §8.3 的复跑读数逐字一致** | 0 |
| 首轮 WU 门（**必须逐字一致**） | `cmd //c 'sim\p5wu\run_tb_app_wu.bat'` | `[WITNESS] danger-band sampled win: min=63 max=120 (40 scans) exact0 hit: scan=0 model=0`；`[READ] fire#1 wu_mark=24695 … @cyc~34850`；`NEW notifications = 3 (expect 3) . OLD = 1 (expect 1 …)`；`P7B WU GATE OK` | 0 |
| 63 字读回门 | `cmd //c 'sim\p5wu_p1p2\run_tb_snap63.bat'` | `PASS_ALL tb_snap63: 26 项判据全过 (窗口 63 字)`；`SNAP63 GATE PASS` | 0 |
| 池/右沿算术门 | `cmd //c 'sim\p5sim\run_tb_p5_fc.bat'` | `PASS=110 FAIL=0`（`sim/p5sim/fcrun/xsim_fc.log`，9:59 生成）；`P5 FC UNIT OK`；`P5 FC UNIT GATE PASS`（日志里唯一一个 "FAIL" 出现在**判据名**里） | 0 |
| APP_MODE 全链门 | `cmd //c 'sim\p5sim\run_tb_p5_app.bat'` | `winq0=c000 wu_mark0=c000 pool=00000 **stat_wu=0** stat_fc_upd=3`；`P5 APP OK` | 0 |
| 审查的**会话边界**门（只读跑，未改） | `cmd //c 'sim\p5wu_p1p2_review\run_tb_rev_p2_gate.bat'` | `RA*/RB*/RC*` 全 PASS；`REV_P2_GATE OK`；`REV_P2_GATE PASS` | 0 |
| **F2 新门** | `cmd //c 'sim\p5wu_f2fix\run_tb_wu_f2.bat'` | `F2 GATE PASSCOUNT 38`；`F2 GATE OK`；`F2 GATE PASS` | 0 |
| **F2 穷举证明** | `/c/Users/zhxue/anaconda3/python.exe sim/p5wu_f2fix/f2_equiv.py` | `F2_EQUIV OK (exhaustive 2^32 grid; PRE/POST/TARGET)`（~31 s） | 0 |
| 额外（自愿）wrapper APP_MODE 全链门 | `cmd //c 'sim\p5sim\run_tb_p5_wrapper.bat'` | **红**，但**与本改动无关**：`P5W tx(frames=0 bytes=0)` 与改动前 09:24 / 09:25 / 09:49 的三次跑**逐字相同** ⇒ **既存红**（`P7B_WU_P1P2_REGRESSION.md` §3.1 已 A/B 判为既存，根因未定位） | 1 |
| 审查的 `winq==0` 探针（只读跑，未改） | `cmd //c 'sim\p5wu_p1p2_review\run_tb_rev_p1_winq0.bat'` | **W0c 翻红**（`dut wu_zero[1]=1`），W0a/W0b/W0d 仍 PASS，`REV_P1_W0 FAIL 1` —— **这条判据断言的就是被 F2 改掉的"恒真武装"态**，翻红是**预期**（它的对偶 = 我门里的 PH0e/PH0f 两臂对照） | 1 |

⚠️ **按纪律未跑**：P4 矩阵（回归轮已硬裁定：manifest 一个都不含 `app_ctrl.v`/`wrapper_p4.v` ⇒ 结构性盲）。

---

## 4. 顺带发现（三条，都登记）

1. **TB 模型的 `t_state` 泄漏会让 C15 静默抽干配额池**（我首跑踩到，已修**在我自己的 TB 里**）：
   只发 `ev_down` 而把模型 TCB 的 `state` 留在 ESTAB，DUT 的 C15 增量补授（`rtl/app_ctrl.v:1211-1219`）
   会继续给一个**已归还配额**的槽补授（`winq` 已被 ev_down 清 0 ⇒ `winq < wq_cap_r` 成立、`pool != 0`）
   ⇒ 池被逐档抽干。首跑读数（`tb/tb_wu_f2.v` PH4）：`winq[4] = 0xBFF7`（期望 `0xC000`）、`pool = 0`。
   **修 = 模型在 DEL 时把该槽 `state` 清 0**（`tb/tb_wu_f2.v` 的 `ev_down_at`，注释写全了）⇒ 同跑 PH4a 复绿。
   ⚠️ **同族脆弱性**（**未改**、不属本轮范围，登记）：`tb/tb_wu_p1p2.v` 的模型 `t_state` **从不清零** ⇒
   它 ev_down 后的槽是"僵尸 ESTAB 槽"。**它的两条路**：① 若僵尸槽在**两次 establish 落定之前**
   （含两者之间）被扫到 ⇒ C15 抢走一份配额（它的 `PH2a/PH2b` 要求两条各拿 `池/2` ⇒ 会红）；② 若在两次 establish **之后**才被扫到 ⇒
   池已被两条连接拿光（`pool == 0`）⇒ C15 补授量 = 0 ⇒ **无害**（它本轮两次复跑都落在 ②，读数逐字一致）。
   窗口对比：一次 establish ≈ 10 拍 vs 扫描一轮 258 拍 ⇒ 落在 ① 是小概率但**非结构性排除**。
   ⇒ 建议下一个人给它的 `ev_down_at` 补一行 `t_state[s] <= 0`（我没改它：本轮要求它的读数逐字一致）。
2. **审查的 `winq0` 探针是按"缺陷存在于代码里"写的** ⇒ F2 修完后 W0c 按定义翻红（见 §3）。
   **它不构成回归**：它断言的是修前的行为。**未改它**（纪律：只读跑）。
3. **`p5_wrapper` 是既存红**（§3 末行）—— 我自愿跑的，读数与改动前逐字相同 ⇒ 与 F2/F1 无关。

---

## 5. 我没能证明的（**不许当已答**）

1. **时序/资源：无构建** ⇒ "F2 的 guard（一级 16 输入或非门 + 两个与门）吃不吃 DP 域余量（现 WNS +0.147 = 2.3%）"
   **未判定**；与 P1/P2 的增量子项一并由下一次构建收口（要看的族/端点见审查 §4.2）。
2. **板级**：没烧板、没碰板（板子保持受控停流态）⇒ 新语义的**板级读数一个都没有**。
3. **不可达态**：§1.5 末条那条差异（`wu_zero=1 ∧ wu_act=0 ∧ winq=0` 时修前会发一次 `win=0` 帧）只由
   **谓词穷举** 给出，**没有 TB 能构造它**（要靠 `force`；而与"代码可达性"同口径的 PH0 已经把可构造的
   那一半证完）。**根触发路径（谁会把 `wu_act` 置 1 后让 `winq` 掉到 0）**= abort/`to_fire` 窗口，
   我**只做了代码论证**（`to_fire` 清 `wu_zero`/`winq` 但不清 `wu_act`；同一窗口内 C15 被 `!to_fired` 挡住）。
4. **`p5_wrapper` 红的根因**：**未定位**（只证"与本改动无关"，与回归轮同一结论）。
5. **作者三臂门的 `PH2a/PH2b` 时序脆弱性**（§4-1 末）：**未做实验**，只登记。

---

## 6. 交付文件 + 指纹（本轮新增/改动，均**未提交**）

| 文件 | 状态 | sha256 前缀 |
|---|---|---|
| `rtl/app_ctrl.v` | 改（功能 +1/−0 行 + 注释） | `f6c5b296…` |
| `board/wrapper_p4.v` | 改（**仅注释**，F1） | `76945167…` |
| `tb/tb_wu_f2.v` | **新增**（3 臂 F2 门，38 判据，474 行） | `c6896603…` |
| `sim/p5wu_f2fix/run_tb_wu_f2.bat` | **新增**（自定位 + pathguard + 计数硬判据） | — |
| `sim/p5wu_f2fix/app_ctrl_prefix.v` | **新增**（= 改前逐字快照，模块改名；未改名版 = `871eab12…` = 编辑前 `rtl/app_ctrl.v`） | `83d318f9…` |
| `sim/p5wu_f2fix/app_ctrl_mut.v` | **新增**（变异体：`end else if`→`end if`，负对照专用） | `00a04b59…` |
| `sim/p5wu_f2fix/f2_equiv.py` / `.log` | **新增**（穷举证明 + 读数） | `279c7263…` |
| `sim/p5wu_f2fix/f2_rtl_diff.txt` | **新增**（改前快照 → 现役 `rtl/app_ctrl.v` 的完整 unified diff；去注释后的**代码行**只有 §1.2 那两组） | — |
| `sim/p5wu_f2fix/logs/*.out` | **新增**（§3 各门 stdout 原件，顺序跑、无并跑） | — |
| `_proj_10g/notes/P7B_WU_P1P2_SNAP.md` | 追加**订正节 §10**（**只加不覆盖**：§0–§9 一字未动） | — |
| `_proj_10g/notes/P7B_WU_F2_F1_FIX.md` | **新增**（本件） | — |
| `_proj_10g/notes/P7B_BIZ_WINDOW.md` | **未动**（本改动不改窗口内容：W61/W62 已在册，`0x11C`/BID=9 不变） | — |

**纪律核对**：未碰 `README.md` / `P7B_LATENCY_RXTX.md` / `P7B_WU_P1P2_TOOLS.md` / `sim/p5wu_p1p2_review/`（只读跑）/ `sim/p5wu_p1p2_regress/`；
未 `git add`、未提交（HEAD 仍是 `95c9485`）；未写 `0x08`；未碰板子。
⚠️ **`.gitignore` 未改（越界）**：新目录 `sim/p5wu_f2fix/` 不在现役忽略规则里（同作者 §8-⑥ 的情况）——
`logs/` `run/` 是可重跑产物；是否加 `sim/p5wu_f2fix/*` + `!` 例外**由 TL 决定**（我把读数留在盘上，不擅自改 `.gitignore`）。
