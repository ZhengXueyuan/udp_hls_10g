
---

# 附录 R —— F4 修复的对抗复核（第二轮，2026-09-29）

> 复核对象：`rtl/mac_rx_64.v` + `rtl/fifo_sync.v`（F4 修复）+ `sim/f4sim/` 的证据。
> 我的全部原始产物在 `review_scratch/`：`rw/tb_rvw_fullnext.v`、`rw/tb_rvw_term.v`、
> `rw/tb_rvw_conserve.v`、`rw/mac_rx_64_old.v`（用 `git show HEAD:` 取的修复前版本，
> 仅重命名模块以便同 TB 内 A/B）、`runfn.bat` / `runterm.bat` / `runcons.bat` /
> `runmacrx*.bat` 及各自的 `rd_*/` 日志。
> **本轮我撤回或修正了自己 3 处误判**（见 §R.6），逐条留痕、不静默删除。

## R.1 ① `full_next` 的精确性 —— **通过（独立、遍历式）**

**解析**（`rtl/fifo_sync.v:53-57`）：`wptr_n` / `rptr_n` 就是**下一拍的真实指针**
（`wptr_n = wptr + (wr&&!full)`、`rptr_n = rptr + (rd&&!empty)`），而
`full_next = pred(wptr_n, rptr_n)`；下一拍的写闸门是 `wr && !full`，其中
`full`@(t+1) = `pred(wptr@t+1, rptr@t+1)` = `full_next`@t。
⇒ `push_ok = !full_next` **恰好**等于"本轮决定的这次推入下拍一定落笔"。
**两个方向同时成立**：不外溢（不漏字），也不悲观（不凭空丢帧）。

**TEST-1 遍历式核对**（`tb_rvw_fullnext.v`：force 指针 → 读 `full_next` → release → 过**一个真时钟沿**
→ 比对**下一拍真实的 `full`**。参考值是 DUT 自己的下一拍输出，**不是公式的重述**）：

| 配置 | 组合数 | 结果 |
|---|---|---|
| D=4 / AW=2 | 8x8x4 = 256 | **0 不一致** |
| D=8 / AW=3 | 16x16x4 = 1024 | **0 不一致** |
| D=16 / AW=4 | 32x32x4 = 4096 | **0 不一致** |
| **合计** | **5376** | **0 不一致** |

同一遍历里逐组合核对 `ovf_pulse === (wr && full)`：**5376/5376 成立**。

**TEST-2 自由跑逐拍滞后等价**：断言 `full_next@t === full@(t+1)`，60000 拍 x 3 配置
（读写占空比 7:4 / 6:5 / 7:3，既饱和又排空）⇒ **70752 次检查，0 错误**。

> ⚠️ **我的第一轮跑出 36056 次"不一致"，差点判"地基不稳" —— 那是我自己 TB 的采样竞争**
> （`wr`/`rd` 用非阻塞写在时钟沿翻转，却在沿后采 `full_next`，正是本工程坑 17 的形态）。
> 改成"沿前采样 + 沿后比对"后 **0 错误**。**这条是我的错，不是 DUT 的**（§R.6-a）。

## R.2 ② TERM 字通路 —— 下游逐个处置

| 下游 | 关键行 | 对 `tkeep=0,tlast=1,tcrs=0,terr=1` 的行为 | 结论 |
|---|---|---|---|
| `vlan_strip` | `rtl/vlan_strip.v:105,120-125` | 组合直通/拼接；`tlast` 与 `tkeep` 按原值走，无特殊分支 | 直通、无挂死 ✓ |
| `rx_classify` | `:118-124`（S_FILL 见 tlast ⇒ RT_SLOW）、`:131-141`（n==2/n==5 定路由）、`:152-170`（S_DRAIN/S_PASS） | TERM 的 tlast 让 FSM 在**正确的帧边界**回 S_FILL ⇒ **真正闭合了 S_PASS「只在 TLAST 上退出」的滞留隐患**；路由由**孤儿字**（被中止帧的头部）决定 ⇒ TERM 跟被中止帧走同一条路 | **隐患闭合** ✓（不是换形态） |
| `slow_rx_adp` | `rtl/slow_rx_adp.v:85-87,214-215` | `frame_bad = abort \|\| ff_full \|\| !s_axis_tcrs \|\| s_axis_terr` ⇒ TERM **两条都命中** ⇒ `do_rollbk` ⇒ **`stat_drop++`(W19)** | **W6 不被污染** ✓ / W19 必涨 |
| `frame_fifo` | `rtl/slow_rx_adp.v:69-75,92` | TERM 字先写入、随后被 `rollback` 整帧作废 | ✓（**潜在坑**：`keep2n(8'h00)` 落 `default` 返回 **1** 字节 —— 若哪天 TERM 真被播放会吐 1 字节垃圾，现靠 rollback 兜住） |
| `tcp_rx` | `rtl/tcp_rx.v:326-345`、`:700-800` | `trunc_pay` / `fend_pay` 处理"线上 tlast 早于承诺载荷"⇒ 闭合边界、按真实字节推进、`ferr=1` | 不死锁、不吞尾 ✓（优于旧行为"并进下一帧"） |
| app 侧（TX 惯例） | `CLAUDE.md` 坑 20 | 设计里**已有**另一种 `tkeep=0` 语义（TX 侧 0 载荷 opener = **合法**）。与 TERM（=坏帧、丢）**同符号不同义** | ⚠️ 未来碰撞风险；建议在 RX 侧注释里锁死语义 |

**「是否污染窗口计数器」的明确结论**

- **W6（`srx_stat_commit`）不被污染** ✓ —— TERM 同时带 `tcrs=0` **和** `terr=1`，`frame_bad` 必真。
- **W7 / W13 不受影响** ✓ —— TERM 不进 app、不进图案校验。
- **W19（`srx_stat_drop`）必然上涨** —— 每一个"已推过字"的被中止帧 +1。
  ⚠️ 这**改变**了 W19 的稳态值，而且方向是**修复带来的**：**旧**代码里被中止帧的孤儿字会
  **并进下一帧**，若下一帧 FCS 恰好是好的，那段"合并帧"可以**被 commit**
  （⇒ W6 多算、且提交的是垃圾数据）；**新**代码一律 rollback ⇒ **W6 更准**，
  但 **W19 从此与 MAC 层丢帧强耦合**。
  ⇒ **`_proj_pcie/p6b_accept.sh` 判据 5 的「W19 恒 0」必须改**（它已因 `W20==W7` 被点名一次，
  这是第二处，且**这一处是本次修复引入的**）。建议改成**有向耦合**：
  「`ΔW19 > 0` 只允许出现在 `ΔW4 > 0` 的窗口里」。

**⭐「有界性」结论（实测，不是推演）：有界，但"闭合"是条件性的。**
用**现成的** `tb/tb_mac_rx_64.v` STALL2 档配我自己的探针 TB，跑完整个激励后 DUT 停在这里：

```
PROBE npush=187 state=5(S_TERM) term_pend=1 first_done=1 fpushed=1368 hwv=0
      fifo_full=1 fifo_empty=0 stat_drop_full=9 stat_drop_partial=1
      stat_orphan_bytes=1368 stat_fifo_ovf=0
```

⇒ 交付流里**最后一个 SOP 永远没等到 TLAST**（`SOP=3 / TLAST=2 / TERM=0`），
**`term_pend=1` 挂着发不出去**；而**修复前的版本给出逐位相同的流**
（`OLD` 与 `NEW` 在该激励下 `words / frames / partials / SOP / TLAST / popc / stats` 全部相同）。
⇒ **修复声明第 4 条「交付流恒满足每个 SOP 后恰一个 TLAST」是假的**；
正确表述是「**一旦消费者继续排空**，交付流满足」。
同时：`stat_orphan_bytes=1368 = 171 字 x 8` ✓ 账目**完全正确**、`stat_fifo_ovf=0` ✓ **无静默丢失**、
`term_pend` 只有 **1 位** ⇒ 挂起态**有界**、消费者一读就解开 ⇒ **无死锁** ✓。
**⇒ 有界、非静默、不死锁，但"闭合"非无条件。**

## R.3 ③ 独立守恒律验证（我自己的激励）—— **PASS_ALL**

`rw/tb_rvw_conserve.v`：帧内容 8/9/14/15/20/60/63/64/65/72/200/1000（**含次最小 runt** ——
修复方自己的 `tools/gen_f4_stim.py` 最小只到 **60** ⇒ 它扫不到这些）、背靠背、坏 FCS、
硬停 tready 后全排空：

```
P1 (混合长度含 runt, 不 stall) / P2 (硬停 -> 全排空) / P3 (背靠背 64B)
REVIEW_CONSERVE_RESULT: PASS_ALL
  totals: words=371 popc=2934 SOP=33 TLAST=33 (nz=32 term=1) baresop=0
  L1 TLAST&keep!=0 == stat_frames               : 32 == 32                        OK
  L2 Sum popc == stat_bytes-4*F+stat_orphan_bytes: 2934 == 2998-128+64 = 2934       OK
  L3 TERM frames == stat_drop_partial           : 1 == 1                           OK
  L4a stat_drop_partial<=drop_full<=drop        : 1 <= 8 <= 8                      OK
  L4b stat_fifo_ovf == 0 (无静默丢失)           : 0                               OK
  L5 每个 SOP 恰一个 TLAST                      : bare SOP = 0                     OK
```

**「无溢出路径逐位不变」的独立复验**：用**现成的** `tools/gen_stim_mac.py` 激励 +
**现成的** `tools/parse_mac_rx.py` 三模式（在我自己的 scratch 副本里跑，**不动 `sim/`**）：

| 模式 | NEW vs 黄金 | NEW vs OLD |
|---|---|---|
| NOSTALL（严格逐词）| **PASS** | **逐位相同** |
| STALL（严格逐词）| **PASS** | **逐位相同** |
| STALL2（lenient）| **PASS** | **逐位相同** |

⇒ **`stat_fifo_ovf` 在我全部激励下恒 0 ⇒ F4(b) 的根因（帧尾那一拍写被静默丢弃）确实修好了** ✓
—— 这是本次修复最硬的正面结论。

## R.4 ⭐ 我新发现并已 A/B 复现的**修复引入的缺陷**：`term_pend==0` 空入 S_TERM 会白白牺牲下一帧

**现象**：`rtl/mac_rx_64.v:218-227`

```verilog
end else if (hwv && !push_ok) begin
    state <= S_TERM; hwv <= 0;                          // 无条件进 S_TERM
    stat_drop <= stat_drop + 1; stat_drop_full <= stat_drop_full + 1;
    if (first_done) begin term_pend <= 1'b1; ... end    // 但只有 first_done 才欠 TERM
```

`hwv==1 && first_done==0` ⇔ 净荷 **8..15 字节**（G=1 ⇒ 一次推入都没有）时：
**`state` 进了 S_TERM，而 `term_pend` 仍是 0** ⇒ `term_fire = term_pend && push_ok` **永假**
⇒ `:333` 的 `else if (gmii_rx_dv)` 把**下一个（空间充足、完全正常的）帧**吞掉并计为丢帧。

**复现（A/B：同一激励、同一 tready 表，修复前 vs 修复后）**：`cmd //c review_scratch\runterm.bat`

```
A1: C=64 帧 (恰好交付 8 字 => FIFO 正好满, 帧完成, term_pend=0)
A2: C=14 帧 (G=1 => 0 次推入, first_done=0)  -> NEW state=5(S_TERM) term_pend=0   <= 缺陷态
B1: 空间充足, 发一个正常的 C=200 帧
NEW: frames=1 drop=2          <= B1 被吞掉, 计成丢帧
OLD: frames=2 drop=1          <= B1 正常交付
DELTA frames (NEW-OLD) = -1   DELTA drops = +1
REVIEW_TERM_RESULT: FAIL -- NEW sacrificed a good frame the OLD delivered
```

⇒ **`rtl/mac_rx_64.v:218/220` 在 `!first_done` 场景把 S_TERM 当成 S_DROP 用，代价是白丢一帧**
（计数诚实、非静默，但比原缺陷更糟：原缺陷只丢**本该丢**的那一帧）。
**修法一行**：`state <= first_done ? S_TERM : S_IDLE;`

**触发条件与覆盖缺口**：需要净荷 **8..15 字节**（线上 12..19 字节，次最小 runt）**且** FIFO 无空位。
合规链路上不应出现这种帧 —— **但修复方自己的门永远测不到它**：
`tools/gen_f4_stim.py:47-66` 的帧尺寸最小 = **60**（`ctl`/`b*`/`a*` 全部 >= 60）
⇒ `first_done` 在任何丢帧之前必为 1 ⇒ **该分支覆盖率为 0**。
建议：改成 `state <= first_done ? S_TERM : S_IDLE;`，**并**给 `gen_f4_stim.py` 补
净荷 8/14/15 的用例（含"FIFO 先满 + 再来 runt"这一拍）。

## R.5 另两问

**`tools/parse_mac_rx.py:63-75` 的 lenient 分支会不会把 TERM 帧判成 `alien`？**
—— **本轮没有兑现，但理由不是"它安全"。** 我跑了现成门（NOSTALL/STALL/STALL2 全 PASS，
见 R.3），其中 STALL2 的 `alien=0`、`TERM(tkeep=0,tlast=1)=0`：因为**该激励下 TERM 从未真正发出**
（DUT 停在 S_TERM，见 R.2）。而 lenient 的判据是 `alien = frames not in exp_set`，
`exp_set` 来自 `gen_stim_mac.py` 生成的 `expected.memh`（**不含 TERM 形状**）⇒
**一旦某个用例的丢帧真的闭合出 TERM，那条判据立刻会报「外来帧」⇒ 假 FAIL。**
⇒ 结论：**这是"尚未引爆"的地雷** —— 修 `expected.memh` 的生成（或让 lenient 识别 TERM）
必须与该修复**同批**落地，否则**修好之后门反而变红**。
**它没有污染我此前的判读** —— §3.4 的 F4 证据用的是我自己写的 monitor（`rw/tb_rvw_macrx.v`），
不是这个脚本；我今后的判读也以自写 monitor 为准。

**W32–W35 的域归属**：**读盘时树里还没有这四个字** ——
`board/wrapper_p4.v:2537-2539` 仍是 `SNAP_NW_P6E=32 / SNAP_FE_NW=10 / SNAP_DP_NW=22`，
`rtl/snap_seq.v:51-52` 仍是 `FW=10 / DW=22`。
但域问题是确定的：修复新增的 4 个计数器都是 **`mac_rx_64` 的输出 ⇒ 前端域（`gmii_clk`）**
⇒ 若加上，必须进 **FE 束**（10 -> 14，总 36），**不能进 DP 束**（那是 `dp_clk`）。

⚠️ **而且 36 字现在装不下**，两处硬顶都在 `_proj_pcie/rtl/axi_regs.v`：

- `snap_idx = r_word[4:0] - SNAP_W0_IDX[4:0]` 只有 **5 位**（`:206-207`，上限 = 32）
- `snap_base` 只有 **`[9:0]`**（`:216`，`{35,5'b0} = 1120 > 1023`）

⇒ **读 W32..W35 会静默回绕到 W0..W3（假 PASS，不是 FAIL）**。
`:73` 的注释已经写死"上限 = 32"。扩到 36 字必须同时把 `snap_idx` 加宽到 6 位、
`snap_base` 加宽到 11 位。

**对我 S2 偏斜账的影响：没有。** 束变宽只是锁存寄存器的位数变多（并行），
链上的**拍数一个都不变** ⇒ 偏斜仍 ≈ **43.2 ns**（§3.2），与 FE 束是 10 字还是 14 字无关。

## R.6 我在本轮**撤回 / 修正**的东西（诚实清单）

| # | 我先前的判断 | 修正 |
|---|---|---|
| **a** | TEST-2 报 **36056 次 `full_next` 不一致** ⇒ 差点判"地基不稳" | **是我 TB 的采样竞争**（沿后采 `full_next`，而 `wr`/`rd` 在沿上翻转 = 坑 17）。改成沿前采样后 **0 错误**。**撤回** |
| **b** | `tb_rvw_conserve` 的 **L5「bare SOP」失败** ⇒ 差点判"帧边界律不成立" | **是我的 monitor 写错**：把 `SOP+TLAST` 同字的合法单字帧错误地留在 "open" 态。连改两版后 **bare SOP = 0**。**撤回** |
| **c** | （前一轮）F2 / F3 | 见 §0 表与文件头的时间戳说明，已撤回 / 降级 |
| **d** | F4(b) 的"帧尾那一拍"机制，我上一轮标注为**"待钉"** | 本轮**钉死**（§3.4 逐拍轨迹 + R.3 的 `ovf ≡ 0` 正面结论）⇒ **`full_next` 修法本身是对的** |
| **e** | 上一轮我把 `parse_mac_rx` 的 lenient 分支当作"将来会假 FAIL"的**推测** | 本轮**跑了**：现在**不**假 FAIL（因为 TERM 没真正发出）⇒ 降级为"尚未引爆的地雷"，并给出引爆条件 |

## R.7 本轮结论速览

| 攻击点 | 结论 |
|---|---|
| ① `full_next` 精确性 | ✅ **通过**：5376/5376 全组合 + 70752 拍滞后等价，0 错误；**两个方向都不偏** |
| ② TERM 通路 | ⚠️ **有条件通过**：W6 不被污染 ✓、S_PASS 隐患真闭合 ✓、无死锁 ✓、账目正确 ✓；**但** (i)「每 SOP 恰一 TLAST」只在消费者排空后成立（实测 STALL2 下 DUT 停在 S_TERM、`term_pend=1`、流中有未闭合的 171 字）；(ii) **W19 从此与 MAC 丢帧强耦合** ⇒ `p6b_accept.sh` 判据 5 的「W19 恒 0」要改；(iii) **`term_pend==0` 空入 S_TERM ⇒ 白丢下一帧**（A/B 实测 −1 帧 / +1 丢） |
| ③ 守恒律 | ✅ **PASS_ALL**（我自己的激励，含 8/9/14/15 字节 runt + 硬停 + 排空）；`stat_fifo_ovf ≡ 0`；**无溢出路径与修复前逐位相同** |
| `parse_mac_rx` lenient | ⚠️ 本轮未引爆（因 TERM 未真正发出），**但一旦闭合就会假 FAIL** ⇒ 必须与 `expected.memh` 的生成同批改；**未污染我此前的判读** |
| W32–W35 | 树里尚无（仍 32 字）；若加：**全部属 FE 域** ⇒ 必须进 FE 束；且 **36 字超出 `snap_idx`(5 位) / `snap_base`(10 位) 的硬顶 ⇒ 会静默回绕成 W0..W3**；**对 S2 偏斜无影响（仍 ≈43.2 ns）** |

*本节全部读数可复跑：`review_scratch/runfn.bat`、`runterm.bat`、`runcons.bat`、
`runmacrx.bat`、`runmacrx_old.bat`、`runmacrx_probe.bat`。*
*本轮同样未修改任何交付件（`rtl/`、`tb/`、`sim/`、`board/`、`_proj_pcie/` 一字未动），
未 `git add/commit/push`，未烧板，未跑综合/实现。*
