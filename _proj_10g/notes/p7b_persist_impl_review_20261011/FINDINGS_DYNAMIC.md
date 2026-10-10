# P7B-PERSIST 实施件审查 —— **动态/工具面**读数与预案（2026-10-11）

> 配套件：同目录 `FINDINGS.md`（静态面对抗审查全文；sha256 见文末自记）。
> 本轮执行范围（TL 放行 2026-10-11）：**D-1**（只读日志登记）· **D-9**（static_check 的 L1 diff 基钉死，纯脚本）· **D-10**（S2 等价门的建造与本地比对，只用 sha256/逐行比对）。
> ⛔ **零 xsim / 零 Vivado / 零板卡**（本机即将跑板级轮烧录，会起一次短 Vivado；#47 前科：同机并跑出假红）。
> ⛔ **未动** `rtl/` `tb/` 与任何共享件（本轮唯一被改的共享件 = `sim/p7b_stagec_tx_regress/author_gate/static_check_persist.py`，改动见 §D-9 的 git diff 原文，可一行回退）。
> §预案 的 TB 编辑**只写方案、未执行**（TL：等放行 xsim + 确认写权归属后再动 `tb/tb_tcp_tx_ovl.v`）。

---

## §D-1 W/S 臂 E7 逐拍 DBG 与 PS 全行**登记**（只读；零新构造）

### D-1a 现行跑（`author_gate/ghost_gate_stdout5.txt` 对应的一轮，runS/runW 现盘）

**`runW/xs.log` PS 全行（逐字）**：
```
PS0 MAXINFLIGHT c0=10307 c1=8903 c2=8839 c3=8839 (BOUND 62948 / RING 65536)
PS1 fire probe_ep=10 probe_out=0 probe_bad=0 d_ev=2100
PS2 LAD n=3 visits dc=9 d1=24 d2=48 gap4=9 (want 8/24/48/8) n2=0
PS2b LAD cycles t_close=150005 t1=157702 t2=176703 t3=215123 reopen=215125 reclose=217630 gap4=6401 leak1=17
PS3 EP probes E2=1 E3=2 E4=1 E5=0 E6=0 E7wit=0
PS4 WIT drain=1 blocked=1 rdy=1 posctrl=1 coll=0 e5ok=16002 e6ok=16002 de=31 rst1=16003 qto=0
PS5 STATE e5=101 e6=011 sn_first=0004eb98 sn_last=0004eb98 (win 00046134->000483bb) dstat=21 dreq=17 retxreq=17
PS6 BAD ladder=0 stop=0 field=0 side=0 sndnxt=0 e2=0 e3=0 e4=0 e5=0 e6=0 coll=0
```

**`runS/xs.log` 对照（同三项）**：`PS1 … probe_ep=9 …` · `PS3 … E4=0 … E7wit=2` · `PS4 … coll=0 …`。
（⇒ W 与 S 的**唯一结构性差异**：W 的 `E4=1`（cfg_up 后仍出探询 = j10 红）+ `E7wit=0`（S=2）。）

### D-1b E7 观察窗**逐拍** DBG（15 拍 × 双臂；字段序 `@cyc t rdy rxidle rf tval tid blk busy aqem svc re scn ract wo apen fifo bkr coll`）

**runS（干净臂）关键三拍（其余 12 拍同形）**：
```
DBG E7 @319393 t=0 rdy=1 rxidle=1 rf=1 tval=1 tid=0 blk=1 busy=0 aqem=1 svc=0 re=0 scn=0 ract=0 wo=1 apen=0 fifo=0 bkr=0 coll=0
DBG E7 @319394 t=1 rdy=1 rxidle=1 rf=1 tval=1 tid=0 blk=0 busy=0 aqem=1 svc=0 re=0 scn=0 ract=0 wo=1 apen=0 fifo=0 bkr=0 coll=1
DBG E7 @319395 t=2 rdy=1 rxidle=0 rf=0 tval=1 tid=0 blk=0 busy=0 aqem=1 svc=0 re=0 scn=0 ract=0 wo=1 apen=0 fifo=0 bkr=0 coll=0
```
**runW（删 `ds_guard`）同三拍**：
```
DBG E7 @319393 t=0 rdy=1 rxidle=1 rf=1 tval=1 tid=0 blk=1 busy=0 aqem=1 svc=0 re=0 scn=0 ract=0 wo=1 apen=0 fifo=0 bkr=0 coll=0
DBG E7 @319394 t=1 rdy=0 rxidle=1 rf=1 tval=1 tid=0 blk=0 busy=1 aqem=1 svc=0 re=0 scn=0 ract=0 wo=1 apen=0 fifo=0 bkr=0 coll=0
DBG E7 @319395 t=2 rdy=0 rxidle=1 rf=1 tval=1 tid=0 blk=0 busy=1 aqem=1 svc=0 re=0 scn=0 ract=0 wo=1 apen=0 fifo=0 bkr=0 coll=0
```
（两臂 `DBG E7 @` 各 15 行；完整序列见各自 `xs.log`。）

**判读（与 `FINDINGS.md` §2-P2 同口径）**：
- **S**：`ds_guard` 在 **t=1**（`blk` 刚放开、`tval=1`、`wo=1` ⇒ 数据帧即将启动的唯一一拍）把探询压住 ⇒ `coll=1` 只出现这一拍；t=2 起 `recv_first=0`（数据帧已在收）⇒ `rx_idle=0` ⇒ 探询结构性不可能再发。**守卫按设计工作**。
- **W**：探询在 **t=0（blk 尚未放开的那一拍）**就被消费（t=1 时 `rdy=0` 且 `busy=1` = 控制槽在飞）⇒ 到 t=1 门放开时暂存已空 ⇒ `start_data ∧ probe_sel` 同拍从未发生 ⇒ **跨连接错帧从未发生**（`e_coll_bad=0` 是如实读数）。
- **`coll`（`psc_coll`）的定义要求 `!u_dut.tx_blk_sid`（TB `:606`）⇒ 它看不到 t=0 那一拍** ⇒ 见证计数=0 不是仪器坏，是定义面不覆盖"早一拍"路径。
- ⚠️ `PS6 BAD` 行在 S/W 两跑里都打全 0（**那行打在判据自增之前**，见 `FINDINGS.md` §2-P4）——**别把它当"判据干净"**。

### D-1c 历史对照（`fd671b6` 代 · `_proj_10g/notes/p7b_persist_impl/ev/xs_runW.log`）

```
PS1 fire probe_ep=6 probe_out=0 probe_bad=0 d_ev=2100
PS3 EP probes E2=0 E3=0 E4=1 E5=0 E6=0 E7wit=0
PS4 WIT drain=1 blocked=1 rdy=1 posctrl=1 coll=0 e5ok=5202 e6ok=5202 de=32 rst1=5203 qto=0
```
⇒ 该代 W **同样** `E7wit=0 / coll=0`，但**同跑**打出了破坏签名（`gate_full_stdout.txt:470-471` 逐字 `seq_mono rev conn=0 val=000466e8 was=000ca92b una=000ca337 @280775` / `seq below una …`，`payload=5 / seqmono=24`）⇒ **"破坏在场、见证=0"** 两代口径一致地指向 `psc_coll` 的**相位/操作数口径问题**（未定位，见 `FINDINGS.md` §5-2）。

---

## §D-9 已做: static_check 的 L1 diff 基**钉死为提交对** `cfd3b1a..fd671b6`（纯脚本；可一行回退）

**动机**（`FINDINGS.md` §2-P5）：原实现 `git diff -U0 -- rtl/tcp_tx_frame.v` = **工作树 vs HEAD** ⇒ 改动一经提交该 diff 恒为空 ⇒ L1(a)/(b) 退化成**空判据**；落盘的 `ev/static_check_formal.txt` 正是该形态（"代码 + 行 **0** 条"）。

**改动文件**：`sim/p7b_stagec_tx_regress/author_gate/static_check_persist.py`（唯一被改的共享件；其余 0 改动）。

**git diff 原文（逐字）**：
```
diff --git a/sim/p7b_stagec_tx_regress/author_gate/static_check_persist.py b/sim/p7b_stagec_tx_regress/author_gate/static_check_persist.py
index 72de4cb..1a5edf5 100644
--- a/sim/p7b_stagec_tx_regress/author_gate/static_check_persist.py
+++ b/sim/p7b_stagec_tx_regress/author_gate/static_check_persist.py
@@ -102,8 +102,21 @@ def rd(path):
     return io.open(path, encoding="utf-8", newline="").read().replace("\r\n", "\n")
 
 
+# ⭐ 2026-10-11 (实施件审查轮 D-9 / 问题 P-5): L1 的 diff 基**不再用 HEAD** ——
+#   钉死到 persist 刀的锚提交对: cfd3b1a (改前件, 与 `frozen/tcp_tx_frame_revcfd3b1a.v`
+#   同源) .. fd671b6 (persist 实施)。理由: 原实现 `git diff -U0 -- <file>` = 工作树 vs
+#   HEAD ⇒ 改动一经提交, 该 diff 恒为空 ⇒ L1(a)/(b) 退化成**空判据**
+#   (落盘的 `ev/static_check_formal.txt` 就是该形态: "代码 `+` 行 0 条")。
+#   ⚠️ 这里改用**双端钉死**的提交对 ⇒ 与工作树/后续刀漂移解耦、可永久复跑
+#   (纪律: 判据的锚必须钉在不可漂的坐标)。
+L1_BASE   = "cfd3b1a"     # persist 刀的"改前"锚 (＝冻锚来源提交)
+L1_TARGET = "fd671b6"     # persist 刀的实施提交
+
+
 def git_diff_u0():
-    out = subprocess.run(["git", "diff", "-U0", "--", "rtl/tcp_tx_frame.v"],
+    """L1 主体 = **钉死提交对** (L1_BASE..L1_TARGET) 对 rtl/tcp_tx_frame.v 的 -U0 diff。"""
+    out = subprocess.run(["git", "diff", "-U0", L1_BASE, L1_TARGET,
+                          "--", "rtl/tcp_tx_frame.v"],
                          cwd=ROOT, capture_output=True)
     if out.returncode != 0:
         raise SystemExit("git diff failed: " + out.stderr.decode("utf-8", "replace"))
@@ -345,7 +358,7 @@ def main():
         # 负对照 1: 注入一个**独立 hunk** 的越界符号 (只触及被禁符号, 不触白名单)
         diff_use = diff + "@@ -999990,0 +999990,1 @@\n+    assign zz = svc_rewind;\n"
     wl_bad, ban_bad, n_plus_code = check_l1(diff_use, pairing=pairing)
-    print("\n[L1] git diff -U0 三项:")
+    print("\n[L1] git diff -U0 三项 (diff 基 = 钉死提交对 %s..%s):" % (L1_BASE, L1_TARGET))
     print("     (a) 白名单: 代码 `+` 行 %d 条 (注释/空行不计), 越界 %d 条" % (
         n_plus_code, len(wl_bad)))
     for l in wl_bad[:8]:
```

**复跑读数（我自己跑，2026-10-11）**：
- 正式：`[L1] … (a) 白名单: 代码 + 行 109 条 …, 越界 0 条` · `(b) 保序配对豁免: 禁用符号净新增 0 条` ⇒ `STATIC_CHECK_PERSIST: PASS`（RC=0）。**不再是 0 行**（= 空判据已消除）。
- `--selfcheck`：注入行后 `110 条 / 越界 1`（注入件）+ 禁用符号 `净新增 1`；SELFCHECK-1/2/3 全过 ⇒ 三负对照都有牙（RC=0）。
- S1/FB/PD 三腿同盘复跑不变（`22/26` 零例外 · `18` 条折回对 · 四个常量 OK）。

**回退（一行级）**：`git checkout -- sim/p7b_stagec_tx_regress/author_gate/static_check_persist.py`（或把两处 `L1_BASE/L1_TARGET` 分支删回原 `git diff -U0 -- <file>`）。
**未做**：未改 `run_static_persist.bat`（它原样调用本脚本 ⇒ 自动继承新基）。

---

## §D-10 已做: S2 等价门**建成并本地比对通过**（新文件 2 个；只用 sha256 / 逐行比对）

**动机**（`FINDINGS.md` §2-P6）：设计 §7.2-S2 要求"实施轮先建 fc/b 等价门 + 负对照（拿 118 KB 旧锚当被测件必红）"。此前**只有冻锚没有门**（`grep -rl "revcfd3b1a"` = 0 命中 ⇒ 锚是死资产）。

**新增文件（2 个，全在 `sim/p7b_stagec_tx_regress/author_gate/`）**：
- `s2_equiv_persist.py`（门本体：L-A 锚出处 sha256 + L-B 日志对机器化核对 + `--selfcheck` 三负对照）
- `run_s2_equiv_persist.bat`（自定位 + pathguard 包装；**CRLF 31/31**，与既有 bat 同规格）

**门的定义（写死在脚本注释里）**：
- **[L-A] 锚的出处完整性**：`frozen/tcp_tx_frame_revcfd3b1a.v` 去 CR 后 sha256 == `git show cfd3b1a:rtl/tcp_tx_frame.v` 的 sha256。
- **[L-B] L2 行为等价的机器化核对**（形态 = "相差集必须恰为指定产物 + 统计件去指定行后全同"）：对 `_proj_10g/notes/p7b_persist_impl/base/xs_runB_baseline.log` vs `ev/xs_runB_after.log` 断言 ①原始**必须不同**（非空判据）②去"指定元数据行"后**逐字节全同**（sha256）③**每一条**原始差异行都必须命中指定元数据类（时间戳/PID/可用内存/hostname/`$finish` 行号/退出时间戳/sim 版本行 ⇒ 判据读数一律不在指定类内）。

**正式跑读数（逐字）**：
```
[L-A] 锚 = tcp_tx_frame_revcfd3b1a.v
      anchor(LF-normalized, 140501 B) sha256 = b6cff51511f5bfee6c0ae73beb24464bf47a97ecde6124c174eb8042708e8f84
      git show cfd3b1a:rtl/tcp_tx_frame.v (140501 B)     sha256 = b6cff51511f5bfee6c0ae73beb24464bf47a97ecde6124c174eb8042708e8f84
[L-A] PASS (锚的出处 = 钉死提交 cfd3b1a, 逐字节)

[L-B] 对 = xs_runB_baseline.log  <->  xs_runB_after.log
      原始差异行 = 10 条; 逐类 = {'时间戳-start': 2, 'PID': 2, '可用内存-Virtual': 2, 'finish-行号': 2, '退出时间戳': 2}
      去指定行后 sha256: before=f542dfbbe4eb4531 after=f542dfbbe4eb4531
[L-B] ①差异非空: True  ②去指定行全同: True  ③差异全属指定类: True

S2_EQUIV_PERSIST: PASS      (RC=0)
```
（⇒ 我此前手工 `diff` 得到的"5 对 = 10 行、全为元数据"现在**机器化且逐类登记**；`before==after` 的正文 sha256 逐字节相同。）

**`--selfcheck` 读数（逐字，三条负对照全红）**：
```
[NEG-A] 拿 118 KB 旧锚当被测件 (必须 FAIL): => 红 ✓
[NEG-B1] 换别的臂的日志当对端 (必须 FAIL): => 红 ✓   (②③ 均 False)
[NEG-B2] 注入一行非指定类差异 (必须 FAIL): [越界差异] +TB_TCP_TX_OVL_CORRUPTED: OK => 红 ✓
S2 等价门自检: 三条负对照都有牙
```
**入口**：`cmd //c 'sim\p7b_stagec_tx_regress\author_gate\run_s2_equiv_persist.bat'`（也已用 `cmd` 实跑：`S2_EQUIV: PASS`，RC=0）。
**回退/删除**：`del` 两个新文件即可（零副作用：脚本**只读** rtl/tb/日志；不写任何产物）。
**未做（明确登记）**：本门**不是**位流级/行为级仿真等价门（那需要 xsim）；它判的是"锚的出处"+"给定日志对的差异集被枚举穷尽"。**设计 §7.2 的"S1 静态剪枝"另由 static_check 的 S1 腿承担**。

---

## §预案（**TB 编辑方案；未执行**——等放行 xsim + 确认写权归属）

> 共性纪律：① 目标文件 = `tb/tb_tcp_tx_ovl.v`（**共享件**：CRLF 纯 2779/2779；改法 = `Edit` 原字符串逐字替换，**禁按 `\n` 锚点**；落笔后核 `git diff --stat` == `git diff --ignore-cr-at-eol --stat`）；② **改前先落 diff**：`git diff -- tb/tb_tcp_tx_ovl.v > <notes>/plans/tb_edit_<臂名>.diff`（改后、跑前各一份，与 `xs.log` 同目录归档）；③ 回退 = `git checkout -- tb/tb_tcp_tx_ovl.v`（或 `git apply -R` 那份 diff）；④ **轨迹耦合警示**：本 TB 的 episode FSM 是**时间/事件混合驱动**，任何一档常数的改动都会移动所有 episode 的相位 ⇒ 新读数**只能与同档臂横比**；⑤ 凡新增判据必须**进 `tot_red`**（否则哑门）；⑥ 凡改"共享 FSM"的构造，**一律加 `-d <新宏>` 守卫**，默认不开 ⇒ 既有臂读数逐字不变。

### 预案-D-2：W-旧刺激档（复现 `fd671b6` 代的破坏签名）
- **文件/行**：`tb/tb_tcp_tx_ovl.v:90`
- **改前（逐字）**：`    localparam integer PE_HOLD_SHORT = 16000;    // E2/E5/E6 的关窗观察窗`
- **改后（拟）**：`    localparam integer PE_HOLD_SHORT = 5200;     // [D-2 实验档] 回 fd671b6 代 (5200)`
- **臂命令**：`run_tx_ovl_gate.bat` 的 W 臂同款手法（临时 bat：`xvlog … -d TCP_TX_OVL -d ARM_PERSIST mut\mut_ps_nodsg.v …`；**不改门本体**，另写一次性 bat）。
- **预期读数**：`[FAIL] seq_mono rev conn=0 val=000466e8 …` / `seq below una …` / `payload` 多条（= `fd671b6` 代的破坏签名回归）；**同跑记 `PS3 … E7wit=?`** —— 若破坏再次出现在 `E7wit=0` 下 ⇒ **`psc_coll` 口径问题坐实**（对应 `FINDINGS.md` §5-2）。
- **回退**：`Edit` 回 `= 16000;` 或 `git checkout -- tb/tb_tcp_tx_ovl.v`。
- **风险/边界**：这是**跨档比较**（与现行 S/T 基线不可横比）；`--dbg` 行数上限（`w_ps_dbg < 40`）可能被 E2/E5/E6 先吃光 ⇒ 若 E7 的 DBG 行没打出来，先调 `:1691` 的打印门限（同一臂内改，登记）。

### 预案-D-3：W-新构造（让"撞车破坏"**结构性可达**；依据 = D-1b 读数）
- **机制回顾（为什么现行构造做不出破坏）**：`ds_guard` 是超集（缺 `!tx_blk_sid`）⇒ 删掉后，探询在"门将开未开"的拍（W 的 t=0：`tval=1 ∧ wo=1 ∧ blk=1`）就跑了 ⇒ 到门放开拍（t=1）暂存已空 ⇒ `start_data ∧ probe_sel` 永不共拍。
- **构造原则**：让**释放拍之前 `ds_guard ≡ 1`**（即在释放前"数据帧不可能启动"），这样双臂都不早跑；到释放拍让 `wnd_open ∧ blk=0 ∧ rdy=1 ∧ tval=1` **同拍成立** ⇒ 删 `ds_guard` 时 `probe_sel ∧ start_data` 共拍 ⇒ 真撞车。
- **两个候选（择一，都加 `-d PE_E7B` 守卫）**：
  - **(a) 窗抑制法（推荐）**：E7 setup 里把 **conn0 的 `snd_wnd` 写 0**（TB 已有 `scfg_upd_sel=3'd4` 的写口；参照 `:1538`/`:1666` 的用法，`scfg_upd_id` 由 4'd1 改 4'd0）；释放改由"等 `win_open` 上升"驱动：在 7'd51 观察到 `ps_rd_d2` 后**不立即释放**，改发 conn0 的 `snd_wnd=SND_WND` 写、进新相位等 `win_open==1`（TB 本地线），在**看到 `win_open=1` 的那一拍**置 `pe_holdb <= 1'b0` ⇒ 下一拍 `wnd=1 ∧ blk=0 ∧ rdy=1 ∧ tval=1` 四者同拍。
  - **(b) 源抑制法**：`src_skip` 在 7'd48-7'd50 期间对 conn0 也屏蔽（`16'hFFFF`），仅在"释放拍"清回 `16'hFFFE` —— ⚠️ **取决于 TB 源模型的呈现延迟**（`:995-1021` 的轮转呈现口，`can_start` 门在 `:1002-1003`）⇒ 若呈现比屏蔽解除晚 ≥1 拍，则会退化成"另一种早跑"⇒ **必须先读源模型确认延迟，或在等 `s_tvalid` 上升的那一拍再释放**（同 (a) 的手法）。
- **观察窗对齐**：破坏拍必须落在 `pe_st ∈ {7'd51, 7'd52}`（`e_coll_bad` 的窗口条件，`:859`）⇒ 释放拍所在的相位必须是 51/52；若把释放挪进新相位，**必须同步把 `e_coll_bad` 的窗口条件扩到该相位**（并登记"为什么"）。
- **预期读数**：`e_coll_bad ≥ 1`（`[FAIL] PS j13: E7 相撞窗内出现跨连接数据帧 =N`，**第一次由专用仪器看到真破坏**）+ 该数据帧会**同时**触发既有 J1 族（dmac/ip/port 与 `t_cam` 匹配）或 payload/seq 监视器的红；S 臂应保持 `E7wit ≥1 ∧ coll(=e_coll_bad)=0`（守卫压住）。
- **回退**：`git checkout -- tb/tb_tcp_tx_ovl.v`（构造全在 `ifdef PE_E7B` 内 ⇒ 不跑该宏时逐字不变）。
### 预案-D-7：cfg_up×捕获窗臂（P-1 的唯一可达性实验）
- **构造**：新 episode（`-d PE_E4B` 守卫）：复刻 E4 的"关 conn1 窗 + 按住 conn0 启动门"（`:1533-1537`），但把"等 `u_dut.ps_stage_rdy` 再打 cfg_up"（`:1550-1555`）改成**等 `u_dut.ps_fire && (u_dut.scan_id==4'd1)` 后立刻打 cfg_up**（fire 拍 = T ⇒ cfg_up 生效于 **T+1**，正落在读流水 T+1..T+2 内）。
- **落点**：新相位插在 `:1652`（`7'd43` 行）之后、`:1653`（E7 注释块）之前；`7'd43` 的 `pe_ret <= 7'd48` 在该宏下改指向新链（链尾再 `pe_ret <= 7'd48` 交回 E7）。
- **新判据（必须进 `tot_red`）**：新计数 `pe_f_e4b_probe`（新链观察窗内 `pe_probe_ev` 增量）+ 判据行 `if (pe_f_e4b_probe != 0) begin tot_red = tot_red + 1; $display("[FAIL] PS j10b: cfg_up 落在读流水内仍出探询 =%0d", …); end`（插在 `:2723-2729` 的 j10 块之后）；计数器声明/清零分别加在 `:386` 一带与 `:446` 一带。
- **预期读数**：若 P-1 成立 ⇒ `pe_f_e4b_probe ≥1`（且该探询 `is_probe` 分类可能失败 ⇒ 以 payload/seq 监视器的红或 `pe_rec_*` 逐帧记录为准）；若 P-1 不成立（清位赢）⇒ 0。
- **回退**：`git checkout -- tb/tb_tcp_tx_ovl.v`。
- ⚠️ **非空判据**：本臂必须留"正控"（同链、但 cfg_up 打在 rdy 落地**之后** ⇒ 期望 0，且此前同构造曾出探询），否则"0"与"没搭出条件"不可分。

---

## §执行记录（本会话落地清单，供 TL 复核）

| 项 | 产物 | 状态 |
|---|---|---|
| FINDINGS.md（静态面全文） | `_proj_10g/notes/p7b_persist_impl_review_20261011/FINDINGS.md` | 已落盘（36,660 B；sha256 `4f217a37cbd82426df1a766db6fcf733cbb49bcdf26bb4a5d88ed506a9017bf8`） |
| D-9 | `sim/p7b_stagec_tx_regress/author_gate/static_check_persist.py`（+14/−2 行，git diff 原文见 §D-9） | 已改 + 复跑（PASS + 自检有牙） |
| D-10 | `sim/p7b_stagec_tx_regress/author_gate/s2_equiv_persist.py`（新）· `run_s2_equiv_persist.bat`（新，CRLF） | 已建 + 实跑（PASS + 三负对照全红） |
| D-1 | 本文件 §D-1（读数登记） | 已做（只读） |
| 未执行 | D-2/D-3/D-7 的 TB 编辑（§预案）· xsim 全臂 · 板级 | **等放行** |

---

# §执行轮 2（2026-10-11 · xsim 臂 D-7 → D-3 → D-2；TL 放行 + 授写权）

> 写权口径：只动 `tb/tb_tcp_tx_ovl.v`（+ 本目录/author_gate 自有文件）；**所有 TB 改动都做成 `-d <宏>` 守卫的默认关形态**；跑前已存 before 快照；**收尾已 `git checkout -- tb/tb_tcp_tx_ovl.v`（`git status --porcelain` 该文件 = 干净）**；完整 diff 已存 `runs/tb_edit_D7_D3_D2.diff`（9,904 B，sha256 `94cb0348388e154939ce4fbacd918d58b0cbf3e64f4809f91836f87bf1af2671`，`git apply --check` = OK，**可一键重放**）。
> 并发：板级轮在本轮期间未造成任何异常红（6 臂全部一次通过、无重跑；每臂 ~7 s）。⛔ 全程未动 `rtl/`。

## §D-7 结果：**P-1 可达 = 已观测（第一手证据）** —— episode 保留为常驻新增

| 臂 | defs | RC/reds | 关键读数（逐字） |
|---|---|---|---|
| **D7A**（主变体） | `-d TCP_TX_OVL -d ARM_PERSIST -d PE_E4B` | reds=5 | `PS7 E4B fire=1 @319390 rdy_survive=7 @319393` · `[FAIL] PS j10b: cfg_up 落在读流水内但捕获仍落地 (rdy 存活 7 拍, 首拍 @319393)` |
| **D7B_NOUP**（正控） | 同上 + `-d PE_E4B_NOUP`（不打 cfg_up） | reds=4 | `PS7 E4B fire=1 @319390 rdy_survive=7 @319393`（**与主变体逐字相同**）· 无 j10b 红（判据按设计翻转） |

**判读**：
- 构造 = E4 同款（关 conn1 窗 + 按住 conn0 启动门 + 源持续呈交），**唯一差别** = 看 `ps_fire` 的同一拍就打 `cfg_up`（⇒ cfg_up 生效于 fire+1，落在读流水 T+1..T+2 内；捕获在 fire+3 落地）。
- 主变体 rdy **存活 7 拍（fire+3 起）**；正控（同构造、无 cfg_up）读数**逐字相同** ⇒ ①采样链活着（不是空判据）②**cfg_up 对在飞捕获的 rdy 影响 = 零** ⇒ §3.4b/j10 的「cfg_up(同 id) ⇒ rdy<=0」在"cfg_up 落在捕获落地之前"的窗口上**不成立** ⇒ **P-1 从"结构上可构造"升为"已观测"**。
- 两臂其余红（payload conn=0 / RETXFIX jump / PS j9 / PS j6）= 与基线 S 同款既有族（非本臂引入）。
- **常驻新增（按 TL 指示保留）**：episode = `tb` 内 `ifdef PE_E4B` 段（默认关 ⇒ 既有臂逐字不变；本轮的 6 臂里只有 D7A/D7B 定义它）。**它判什么**：`[FAIL] PS j10b` = "cfg_up 生效于 fire+1 时暂存仍落地（rdy 存活）" = **P-1 可达的正证据**（判据语义 = 设计意图「cfg_up 应清掉在飞捕获」；红 = 意图被违反）。**正控** = `-d PE_E4B_NOUP`（同构造不打 cfg_up）⇒ 该子句翻转为"rdy 必须落地"，且 fire 见证（`w_e4b_fired<1` ⇒ 空判据红）两变体共有。
- ⚠️ 边界：本臂只证"**rdy 存活**"（清位落空）；"存活之后是否会真的发出一条第旧字节的探询" **本臂未验**（本臂构造下源持续呈交 ⇒ ds_guard=0 ⇒ 探询在窗内被压住；要验需再等一个源空档，另立臂）。

## §D-3 结果：**删 `ds_guard` 的撞车破坏第一次被专用仪器见证（`e_coll_bad=1`）**

改动（`ifdef PE_E7B`，只在 :1686 一带）：E7 的 hold 释放触发 **`u_dut.ps_rd_d2` → `u_dut.ps_rd_d1`**（提前一拍发命令 ⇒ 经 `pe_holdb→ack_seen_tb→tx_blk_sid` 两级寄存后，门恰在 fire+3 = 捕获落地拍放开）。

| 臂 | defs | RC/reds | 关键读数（逐字） |
|---|---|---|---|
| **D3S**（干净臂） | `-d TCP_TX_OVL -d ARM_PERSIST -d PE_E7B` | reds=4（= 与基线 S **同集合**） | `PS3 … E7wit=2` · `PS4 … coll=0` · E7 逐拍 `t=0 rdy=0 blk=1` → `t=1 rdy=1 blk=0 coll=1` → t≥2 `rdy=1 recv_first=0`（守卫压住、数据帧照常启动） |
| **D3W**（删 ds_guard） | 同上（RTL = `mut_ps_nodsg`） | **reds=112** | `PS3 … E7wit=1` · **`[FAIL] PS j13: E7 相撞窗内出现跨连接数据帧 =1`** · `[FAIL] seq_mono rev conn=0 val=0004f14c was=000e6971 una=000e696a @319577` · `[FAIL] ghost conn=1 seq=0004eb98 plen=1460 tail=0004f14c whi=00000000 @319773` · `[FAIL] payload conn=1 seq=0004eb98 off=0 got=67 exp=94 @319773` · E7 逐拍 `t=0 rdy=0 blk=1`（**无早跑**）→ `t=1 rdy=1 blk=0 coll=1`（**撞车拍**）→ t≥2 `rdy=0 busy=1 recv_first=0`（探询消费暂存 + 数据帧同拍启动） |

**判读**：
- **D3W 的破坏 = REVIEW2 ①-2 预测的原形**：数据帧带上 **conn1 的四元组与 seq**（`ghost conn=1 … plen=1460` = 探询段本该 plen=1）⇒ conn0 的 `snd_nxt` 被写成 conn1 的值（`0004f14c`）⇒ 后续 `seqcont=64 / seqmono=41` 的雪崩。**这是"跨连接错帧 + 按错 seq 写 ring"的直接见证**（不是借道通用监视器的间接推论）。
- **D3S 同构造不受影响**（红集合与基线逐字同）⇒ 该构造**有判别力**：同一刺激下"守卫在 ⇒ 干净 / 守卫删 ⇒ 破坏"。
- ⇒ **H2(b)「摘掉 `ds_guard` ⇒ 必红」现已成立为"特定红"**（`j13`/`e_coll_bad` 直接发火，1/1 数据点，且机制可解释）；**但注意它的成立条件 = `PE_E7B` 这条刺激修正**（现行默认构造下该破坏**结构性不可达**，见 `FINDINGS.md` §2-P2 的逐拍证据）。⇒ **建议**：把 PE_E7B 作为 W 臂的**配对构造**登记（做"必红"论证时必须带它；否则只有空判据红）。

## §D-2 结果：旧刺激档（5200）**未能复现** fd671b6 代的 W 破坏；两臂**同时退化**（= 刺激档效应，非突变效应）

改动（`-d PE_HOLD_5200`，默认关 ⇒ 16000 不动）：`tb` 的 `PE_HOLD_SHORT` 一处分档。

| 臂 | defs | RC/reds | 关键读数（逐字） |
|---|---|---|---|
| **D2S**（干净臂 @5200） | `-d TCP_TX_OVL -d ARM_PERSIST -d PE_HOLD_5200` | reds=11 | `PS3 E2=0 E3=2 E4=0 … E7wit=2` · `PS4 … blocked=0 rdy=0 posctrl=0 coll=0` · `[FAIL] RETXFIX jump: session end snd_nxt=000466e8 < retx_hi=00047258 conn=1 @236017` |
| **D2W**（删 ds_guard @5200） | 同上（RTL = `mut_ps_nodsg`） | reds=12 | 同上 + **唯一专属差 = `[FAIL] PS j13 空判据: 相撞条件从未成立 (wit=0)`** · `PS3 … E7wit=0` · E7 逐拍与现行档**同机制**（`t=1 rdy=0 busy=1` 早一拍消费） |

**判读（如实）**：
- 5200 档下 **E2/E4/E7 三个 episode 观察窗 < fire 的 visit 时间** ⇒ 空判据族红（`blocked=0/rdy=0/posctrl=0`）——**两臂同款** ⇒ 是**刺激档**造成的退化（非突变）。
- 5200 档下 W 的**专属红仍只有"见证=0（空判据）"**，**没有**撞车破坏的特定红 ⇒ **不能声称"复现了 fd671b6 代的 W 破坏"**；`000466e8` 这个数值两臂都出现（载体 = RETXFIX jump，与那代的 `seq_mono rev conn=0` 是不同判据）⇒ **同名数值 ≠ 同一现象**。
- ⇒ 修正 `FINDINGS.md` §2-P2 的口径：**"W 的破坏签名是刺激档函数"这句话应读作"现行/旧档都做不出特定红，能做出来的 = PE_E7B 构造"**；fd671b6 代那次的确切对齐条件**仍未定**（登记不动）。

## §本轮文件清单 + 臂日志路径（全部相对仓根 `udp_hls_10g/`）

**改动/新增**：
| 文件 | 性质 | sha256 / 备注 |
|---|---|---|
| `tb/tb_tcp_tx_ovl.v` | 本轮 D-7/D-3/D-2 三处 `-d` 守卫编辑 | **已 `git checkout --` 恢复干净**；改动全文 = `_proj_10g/notes/p7b_persist_impl_review_20261011/runs/tb_edit_D7_D3_D2.diff`（9,904 B / `94cb0348…f2671` / `git apply --check` OK） |
| `sim/p7b_stagec_tx_regress/author_gate/static_check_persist.py` | D-9（前一轮，已授权） | 改动全文 = 本文件 §D-9；`git status` 显示 M |
| `sim/p7b_stagec_tx_regress/author_gate/s2_equiv_persist.py` | D-10 新文件 | `6628a72042b95b4a0576e796a461e946d29cc9a30d763fbee5e8562fca9a4812` |
| `sim/p7b_stagec_tx_regress/author_gate/run_s2_equiv_persist.bat` | D-10 新文件（CRLF） | `e0f1caabb42207645cdcddbc3745a98d0ce2479f5408fc2f08ef19790a16cd02` |
| `_proj_10g/notes/p7b_persist_impl_review_20261011/FINDINGS.md` | 静态面全文 | `4f217a37…a9017bf8` |
| `_proj_10g/notes/p7b_persist_impl_review_20261011/FINDINGS_DYNAMIC.md` | 本文件 | 见文末 |
| `_proj_10g/notes/p7b_persist_impl_review_20261011/runs/` | 臂运行器 + 全部原始日志 | 见下 |

**每条臂的原始日志（`xs.log` = xsim 判决日志；`xv_out.log`/`xe_out.log` = 编译/链接）**：
```
_proj_10g/notes/p7b_persist_impl_review_20261011/runs/
├── run_arm.bat · d7a.bat · d7b.bat · d3s.bat · d3w.bat · d2s.bat · d2w.bat
├── tb_edit_BEFORE.diff (0 B) · tb_edit_D7_D3_D2.diff (9,904 B / sha256 94cb0348…)
├── D7A/       {xs.log, xv_out.log, xe_out.log}   # P-1 主变体  (reds=5)
├── D7B_NOUP/  {…}                                 # P-1 正控    (reds=4)
├── D3S/       {…}                                 # D-3 干净臂  (reds=4)
├── D3W/       {…}                                 # D-3 突变臂  (reds=112, e_coll_bad=1)
├── D2S/       {…}                                 # D-2 干净臂  (reds=11)
└── D2W/       {…}                                 # D-2 突变臂  (reds=12)
```
**重放命令**（工作树干净时）：`git apply _proj_10g/notes/p7b_persist_impl_review_20261011/runs/tb_edit_D7_D3_D2.diff`，然后 `cd _proj_10g/notes/p7b_persist_impl_review_20261011/runs && cmd //c '.\d7a.bat'`（其余臂同法；⚠️ 本机已设 `NoDefaultCurrentDirectoryInExePath=1` ⇒ cmd 里必须写 `.\xxx.bat`）。

## §未定项更新

1. **P-1**：可达性 = **已观测**（D7A；正控 D7B 同读数）。**"存活的暂存会不会真的漏出一条第旧字节的探询" = 未验**（D-7 构造下探询被 ds_guard 压住；需另立"源空档"臂）。
2. **P-2**：机制 = 已现证（早一拍消费 + 守卫生效拍逐拍可读）；**PE_E7B 构造下"摘 ds_guard ⇒ 特定红"= 1/1 成立**；fd671b6 代那次的确切对齐条件**仍未定**；**5200 档不能复现**（本轮到 D2 为止）。
3. 新增未定：**PE_E7B 是否应升格为门臂**（现为我的实验 patch，未进 `run_tx_ovl_gate.bat` 的契约）；**D-7 episode 的"漏出探询"延伸臂**。
