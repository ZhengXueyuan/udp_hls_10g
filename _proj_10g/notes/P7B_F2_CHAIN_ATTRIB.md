# P7b 链级 F-2 探针 [OPEN] 项 —— 归因报告

日期: 2026-09-30 · 器件/工具: xcku5p-ffvb676-1-e / Vivado 2025.2 xsim · **纯仿真** (未烧板、未碰 QSPI、未改 `rtl/`)
现场: `_proj_10g/p7b_chain/` (该目录的 TB 与门已按本报告改动, 见 §9/§12)

---

## 0. 一句话判定

**台架错 + 判据错, 不是真缺陷。** 被解出的两个线上帧是:
**(f0) 上一组 (group 6) 的帧** —— 因抓取窗口的 `wq_wr = 0` 复位被同拍 NBA 覆盖而留在窗口里 (它恰好也以
`88 77 66 55 44 33 22 11` 开头, 与 group 8 注入的 A 首字**逐位相同**, 后面又是 `AA BB CC DD 11 22 33 44`
= 与 B 相同的字面量 ⇒ 与 P6B B8 的"幽灵帧 = 帧A 字节 + 帧B 字节"**在内容上不可区分**);
**(f1) group 8 自己的线上帧 = 设计合同要的 runt** (前导 + A 的两字 = 16 内容字节 + `/T/`)。
同时该探针的期望 ("冲刷后应有完整 B") 与**它自己的激励**矛盾 (A 无 TLAST ⇒ 合同情形③ 冲刷必然吞掉 B)。

---

## 1. 现场原文 (探针判据 + 读数)

判据原文 (`sim/tb_p7b_chain.v`, F-2 组, 期望全部由 TB 自算):

```
[OPEN] 8a F-2 wire frames == 2 = 1     (wf_cnt === 2)        // 期望: runt + 完整 B
[OPEN] 8b every wire frame is A-prefix or B = 0 (ok_prefix)  // 每帧要么是 A 的前缀, 要么是 B
[OPEN] 8c post-flush frame == B byte-exact = 0  (ok_b)       // 最后一帧 == B 逐字节
[OPEN] 8d post-flush frame content == 60B (pad)+4B FCS = 0 (nb === 64)
[DIAG8]  wf_cnt=2 last_content_len=16 prefix_ok=0 b_ok=0
[DIAG8b] f0_n=71 f1_n=23 | f0=55 88 77 66 55 44 33 22 11 aa | f1=55 88 77 66 55 44 33 22 11 00
```

探针的诊断打印 (原文, `logs/xsim_p7bchain_pristine_final.log:1441-1446`):

```
[DIAG8] wf_cnt=2 last_content_len=16 prefix_ok=0 b_ok=0
[DIAG8b] f0_n=71 f1_n=23 | f0=55 88 77 66 55 44 33 22 11 aa | f1=55 88 77 66 55 44 33 22 11 00
```

⇒ "两个线上帧都以 A 的字节开头" **就是这么来的** (f0/f1 的第 2 字节都是 `88`)。

---

## 2. 原始字节 dump (新加诊断, 不是摘要行)

### 2.1 注入的帧 (TB 侧帧缓冲, 逐字记录 —— `[INJW]`)

group 8 的激励 (TB 原文): A = 2 个字 (第 2 字全 0) 后**永久断供 (无 TLAST)**; 之后注入 B = 1 个字 + TLAST。
实际写入 `u_txcdc` 的字 (`[INJW]` 记录, 以 `txsrc_tvalid && txsrc_tready` 为写门):

```
[INJW 0] keep=ff last=0 d=8877665544332211    <- A 字0
[INJW 1] keep=ff last=0 d=8877665544332211    <- 同一笔写的重复计数 (见 §4.3 注)
[INJW 2] keep=ff last=0 d=0000000000000000    <- A 字1
[INJW 3] keep=ff last=1 d=aabbccdd11223344    <- B
[INJW 4] keep=ff last=1 d=aabbccdd11223344    <- 同上, 重复计数
```

### 2.2 线上解出的帧 (逐字节)

```
[WFRAMES] wf_cnt=2
[WFRAME 0] words[7..16] bytes=71
    [000] 55 55 55 55 55 55 d5 88     <- 前导后的内容从下标 7 起
    [008] 77 66 55 44 33 22 11 aa     <- 88 77 66 55 44 33 22 11 = 与 A 首字同; 然后 aa bb cc dd 11 22 33 44
    [016] bb cc dd 11 22 33 44 00
    [024] 00 ... (pad)
    [064] 00 00 00 e9 07 cd 41 xx     <- FCS = e9 07 cd 41
[WFRAME 1] words[1213..1216] bytes=23
    [000] 55 55 55 55 55 55 d5 88     <- 前导
    [008] 77 66 55 44 33 22 11 00     <- A 字0 (8B) + A 字1 (8B, 全 0)
    [016] 00 00 00 00 00 00 00 xx
```

### 2.3 线上原始字 (含控制字符, 逐 lane) —— **决定性证据**

窗口头部 (下标 0..9) 与 f0 的原始字 (`[RAW]`):

```
[RAW 7] c=01 d=d5555555555555fb l0=fb l1=55 l2=55 l3=55 l4=55 l5=55 l6=55 l7=d5   <- /S/+55x6+D5
[RAW 8] c=00 d=1122334455667788 l0=88 l1=77 l2=66 l3=55 l4=44 l5=33 l6=22 l7=11   <- A 字0 的镜像
[RAW 9] c=00 d=44332211ddccbbaa l0=aa l1=bb l2=cc l3=dd l4=11 l5=22 l6=33 l7=44
[RAW 15] c=00 d=41cd07e900000000 l0..l3=00 ... l4=e9 l5=07 l6=cd l7=41
[RAW 16] c=ff d=07070707070707fd l0=fd l1..l7=07                                   <- /T/+I x7
```

f0 的字节流 = `88 77 66 55 44 33 22 11 | AA BB CC DD 11 22 33 44 | 42×00 pad | e9 07 cd 41`。
**这正是 group 6 (上一组) 注入的那一帧** —— group 6 的注入字就是
`d=8877665544332211` + `d=aabbccdd11223344` + `tkeep=c0/tlast=1` 的 `000000000000a55a`
(见 `[INJW6 0..2]`), 其线上帧同为 71 字节且 FCS `e9 07 cd 41`。
⇒ f0 **不是** group 8 的帧, 而是**跨组混入**的陈旧帧 (其 FCS 也是 group 6 那帧的 FCS)。

---

## 3. 根因 #1: 抓取窗口陈旧 (台架错)

- 现场代码 (F-2 组开头): `wq_wr = 0;` —— 用阻塞赋值复位抓取窗口计数器 `wq_wr`。
- 抓取 always 块: `always @(posedge u_dut.tx_mii_clk_1) begin wq_d[wq_wr] <= ...; if (wq_wr < 16383) wq_wr <= wq_wr + 1; end`
- 该 `wq_wr = 0` 与抓取块的**同一步 NBA 更新**竞争; 实测**复位未生效**:

```
[F2W] group8 start    $time=126352000 wq_wr_before_reset=1202
[F2W] wq_wr_set=0
[F2W] wq_wr_after3txedges=1205   (~3 = reset honoured; ~1200 = stale group6 window)
```

`1202 + 1 (同拍 NBA) + 3 = 1206`? 实测 1205 ⇒ 该阻塞赋值先落 0、随后被同拍 NBA
`wq_wr <= 1202+1` 覆盖, 之后每拍 +1 (3 拍后 1205)。**算术自洽** ⇒ 机制成立。
`[F2W] decode ... wq_wr=3808` ⇒ 解码扫描区间是 `[0, 3808)`, **包含了 group 6 的帧** (它在下标 7..16)。

⚠️ 对照: **group 6 那一次的同一个 `wq_wr = 0` 生效了** —— 证据是 group 6 的帧出现在下标 7..16
(即"复位后第 7 个字"), 而不是更早/更晚。⇒ 这是**同一步内进程顺序决定的竞态**
(与 `CLAUDE.md` 坑 17 / PORT_NOTES #17 "0 延迟竞争" 同族), **两次调用的结果不同**。

⇒ 判据 8a 的 `wf_cnt == 2` **是"对了但理由错"** (一个陈旧帧 + 一个 runt 凑成 2);
8b 的 "每一帧都是 A 前缀或 B" 因此必然为 0 (f0 是 64 内容字节的 group 6 帧)。

---

## 4. 根因 #2: 判据与激励矛盾 (判据错)

### 4.1 合同原文 (设计 RTL 注释, `_proj_10g/p7b_mac/rtl/mac_tx_10g.v:24-31`)

> 中止 ⇒ 立即补一个 `/T/` 把帧结掉 …… 然后进 S_FLUSH: **一个字都不发**, 逐字弹掉输入 FIFO 直到
> 吞掉本帧 TLAST, 再等够 IFG 才回 S_IDLE …… 覆盖性论证: ③ 唯一"没有 TLAST 会到来"的情形 =
> DP 被复位/放弃该帧: 此时冲刷会把**下一帧整帧**也吃掉, 代价 = 丢 1 帧 (有界、自愈、**有计数**),
> 仍然绝不发坏帧 —— 安全的那个方向。

### 4.2 本组激励恰好就是情形③

A 的字流**没有任何 TLAST** (TB 原文: 2 个字后 `tlast=0` 且 `tvalid=0` 直到组末),
所以按合同 **B 整帧必须被冲刷吞掉、不许上线**。探针 8c/8d 却要求"冲刷后那一帧 == B 逐字节" +
"内容 == 60B pad + 4B FCS = 64" ⇒ **8c/8d 在正确设计上必然为 0** (它们要的是"冲刷没生效"的行为)。

### 4.3 MAC 内部逐拍 trace (设计行为 = 合同, 无异常)

A 窗口 (`[TR]`, `st`: 0=IDLE 1=S_PRE 2=S_DATA 6=S_ABORT 7=S_FLUSH):

```
TR9  st=1 cwl=2 cwlast=1 plen=16 femp=0 frd=1 txd=d5555555555555fb   <- 起帧, 弹 A 字0
TR10 st=2 cwl=8 cwlast=0 plen=0  femp=0 frd=1 txd=1122334455667788   <- 发 A 字0, 弹 A 字1
TR11 st=2 cwl=8 cwlast=0 plen=8  femp=1 frd=0 txd=0000000000000000   <- 发 A 字1; FIFO 空
TR12 st=6 ... abrt=1 sht=1 txd=07070707070707fd                      <- 中止: 补 /T/ 结帧
TR13 st=7 ... fcnt=0                                                 <- 进 S_FLUSH
```

B 窗口 (B 到达时冲刷吞掉它):

```
TR5  st=7 femp=0 frd=1 ftl=0 fcnt=12        <- 冲刷弹出 B
TR6  st=7 femp=1 frd=0 ftl=1 fcnt=12 flw=1  <- 弹的就是 TLAST 字 (B) => 边界已到
TR7  st=0 ... fldn=1                        <- 冲刷完成, 回 IDLE; B **没有上线**
```

⇒ `stat_flush_words=1, stat_flush_done=1`; f1 (runt) 的 16 内容字节 = A 的两字 ✓;
B 整帧被吞 (合同情形③, 有计数) ✓。**设计行为与合同逐条一致**。

> 注: `[INJW]` 把同一笔写记了两次 —— 这是**我的记录器**与 FIFO 写口在"同一步内进程顺序"
> 上的差异 (记录器先评估、随后 `force tvalid=0` 才落, FIFO 写口后评估) ⇒ 记录器比 FIFO 多记
> 1 笔/次边沿。**不是设计重复写**: MAC 只弹到 2 个字 (trace TR9/TR10 各一次 frd),
> 且 8B/2 字 runt 的内容逐字节等于 A 的两字 ⇒ 数据通路无重复。此法已登记为"记录器口径"。

---

## 5. 链级 vs 单元级差异清单 (逐项排除)

| # | 差异 | 是否造成两级矛盾 | 证据 |
|---|---|---|---|
| 1 | wrapper 接线 / `ifdef P7B_10G` 分支 | **否** — 同一 wrapper 的 RX 侧 47 条判据全过; TX 侧 6a-6f (单帧/lane 序/前导) 全过 | §1 读数, X1a/X2 |
| 2 | CDC (`fifo_async`, 256 深) | **否** — 但**有速率敏感**: 注入占空比 50% (1 字/2 拍) 会造成**帧内气泡** ⇒ F-2 中止 (合同语义), 见 X1b | X1b 读数 |
| 3 | 背压模式 (tready) | **否** — 单元门与链级都用 `!full` 反压; X3 的残字/B 在同一 CDC 下逐字节正确 | X3 |
| 4 | 激励 (A 是否有 TLAST) | **是(判据错)** — 单元门组 9 的 A 尾部**带** TLAST (残字到场后才结束), 链级组的 A **永不带** TLAST ⇒ 两者合同结论不同 | §4.1/4.2, X3 vs X4 |
| 5 | 判据窗口/对象 | **是(台架错)** — 链级解码窗口陈旧 (跨组混入) | §3 |
| 6 | MAC 内部 16 深 FIFO 可见性 | **否** — trace 显示弹字/发字严格 1 字/拍 | §4.3 |

---

## 6. 判别实验与读数 (新增 F2X 组; 判据 = **线上逐帧内容**, 与计数器无关)

注入方式: force 全部落在 **negedge** ⇒ 每个 posedge 采到稳定字 (避开坑 17 的 0 延迟竞争);
"完整帧"用 **1 字/拍连续注入** (= DP 侧合同)。窗口 = `[wq_base, wq_wr)` 的**快照基准** (不再用 `wq_wr = 0`)。
分类: 2=完整帧 (内容 + FCS) / 1=残缺前缀 (合法 runt) / **0=幽灵 (FAIL)**。

| 实验 | 激励 | 期望 (合同) | 读数 (pristine) |
|---|---|---|---|
| **X1a** | 1 帧, 60B 内容, 连续 | 1 帧, 逐字节 + FCS 正确 | `wire frames=1 kind=2 len=71` ✓ **PASS** |
| **X1b** | 同一帧, 50% 占空比 (故意帧内气泡) | 中止 ⇒ runt + 冲刷 (合同) | `frames=1 kind=1`; `d_flush_words=6 d_flush_done=1` ✓ **PASS** |
| **X2** | 2 帧背靠背, 连续 | 2 帧, 都逐字节正确 | `frames=2 kind=2,2` ✓ **PASS** |
| **X3** | A 头 2 字 → 等 `stat_abort` 递增 → 推 A 残字(带 TLAST) → 推 B | runt(A 前缀) + 完整 B | `frames=2 kind=1,2` ✓ **PASS** |
| **X4** | **= 链级探针原激励** (A 永无 TLAST) → 推 B | **只有 runt; B 被吞; 无幽灵** | `frames=1 kind=1`; `d_flush_words=8 d_flush_done=1`; B 未上线 ✓ **PASS** |

⇒ **X4 = 对同一条激励的合同正确判据, 全过**; 原探针 8b/8c/8d 的 0 全部由 §3/§4 解释。

## 7. 变异对照 (判据有牙)

变异 **MUT-NOFLUSH** (scratch 副本 `_f2_scratch/mac_tx_10g.v`: `S_ABORT: state <= S_IDLE;`
—— 即 P6B B8 描述的**修复前 F-2 缺陷**; 经 `%P7B_MUT%` 喂给同一门, 与 `scripts/mutate_chain.py` 同法):

```
pristine : 70 checks, 1 fail   (唯一 FAIL = §8 的 DEFECT-REG #1, 与 F-2 无关)
MUT-NOFLUSH: 70 checks, 10 fail   (含 X3 "no ghost" / "frame1 is B" / 帧数)
```

变异下 X3 的线上帧 (**幽灵帧复现**, 5 帧 vs 注入 2 帧):

```
[F2X X3] frame 0 len=23 kind=1  | 55*6 d5 | 23 45 67 89 ab cd ef 08 | 09..11        <- 合法 runt (A 前缀)
[F2X X3] frame 1 len=23 kind=0  | 55*6 d5 | 11 12 13 14 15 16 17 18 | 19..20 74     <- 幽灵: A 的**中段残字**
[F2X X3] frame 2 len=31 kind=0  | 55*6 d5 | 21 22 ... 32 33 34 35 36 37 38 00      <- 幽灵
[F2X X3] frame 3 len=71 kind=0  | 55*6 d5 | 39 3a 3b 3c | 56×00 pad | FCS            <- 幽灵 + **pad + 正确 FCS**
[F2X X3] frame 4 len=71 kind=2  | B 逐字节 + FCS                                   <- B 完整
```

⇒ 与 P6B `P6B_CDC_AUDIT.md` B8 的"**FCS 完全正确的幽灵帧, 载荷 = 被中止帧的中段残字**"**同类复现**;
且**只有逐帧内容判据**能抓到 (帧数 5≠2 也抓到; 计数器口径 `flw/fldn` 在变异下照样"干净" ⇒ 不可作主判据)。

**等价变异对照 (如实报"没抓到")**: **MUT-EQ** = 从 pristine 副本只改一个计数器
(`stat_tx_ctrl_char <= ... + 32'd1`, 线上字节**零变化**; 曾误从 `_f2_scratch` 派生一次, 那次
连带 no-flush 缺陷 ⇒ 10 FAIL, 已作废重做)。读数: **70 checks, 1 fail** —— 与本底**逐条相同**
(唯一 FAIL 仍是 DEFECT-REG #1) ⇒ 本轮的 F2X 判据**不误报** (对我在意的维度等价的改动, 判据正确地没抓到)。
证据: `logs/f2x10_mut_eq_counteronly.txt` + `_proj_10g/p7b_chain/_f2_scratch_eq/`。

## 8. 判定

**(2) 台架错 + (3) 激励/判据错; 不是 (1) 真缺陷。** 三个具体缺陷, 全部在 TB 侧:

1. **`wq_wr = 0` 复位被同拍 NBA 覆盖** ⇒ 解码窗口跨组陈旧 (根因, 直接产出"两个都以 A 的字节开头")。
2. **判据期望与自己的激励矛盾** (A 无 TLAST ⇒ 合同情形③ 吞掉 B) ⇒ 8c/8d 结构性不可能通过。
3. **8b 的"A 前缀"定义过窄** (`(nm-7) > 8 ⇒ 非前缀`): A = 2 字时合法 runt 可达 16 字节 ⇒ 合法情形被判违规。

修法 (已在现场落地, 见 §12):
- 窗口改用 **`[wq_base, wq_wr)` 快照基准** (根除竞态; 永不写 `wq_wr = 0`)。
- 判据改用 **F2X X3/X4** 的合同正确形式 (逐帧内容分类 + 前缀/完整两分; 前缀长度按注入帧真实长度)。
- X1b 把"注入占空比"这一维度显式登记为**故意气泡**用例 (合同语义: 帧内断供 ⇒ 中止)。

## 9. 未核实清单

1. **`wq_wr = 0` 竞态在 xsim 内的判定因子** (为何 group 6 生效、group 8 不生效): 只实测了效果与
   算术自洽; 未做"人为控制进程顺序"的定向实验。**修法不依赖它** (快照基准无竞态)。
2. **真实 DP 侧字流连续性**: X1b 证明"帧内气泡 ⇒ 中止"。DP 侧 (`u_tx_arb` → `u_txcdc`) 是否
   恒为 1 字/拍连续流、CDC 可见性滞后是否会在真机造出气泡, **未测** (需以 app/慢路径为源的链级用例)。
   若真机上出现, 症状 = 帧被截断为 runt + 后续帧被冲刷吞掉 (有计数, 安全方向)。
3. **RTL 未改动** (遵指示): 本报告的"台架错"结论不依赖任何 RTL 改动; X5 的缺陷登记同样只报告。
4. `[INJW]` 记录器口径 (同拍竞争下的重复计数): 已用 MAC 内部 trace 交叉验证 (只弹 2 字),
   但未给记录器加"与 FIFO 写口同信号同刻"的守卫。

---

## 10. 附带发现 (与 F-2 无关): DEFECT-REG #1 —— mac_tx_10g 补 pad 帧的 FCS 覆盖面 [✅ **已修**: `effef26`]

**现象**: `mac_tx_10g` 对**需补 pad 的短帧**算出的 FCS **只覆盖数据字节, 不含 pad**;
`mac_rx_10g` (以及任何标准对端) 的 CRC 覆盖**收到的全部字节 (含 pad)** ⇒ **自己的 TX 与 RX 不一致**。

**证据 A (线上字节 + 独立复算, 与设计无关)** —— group 6 的帧 (内容 18B ⇒ pad 42B):
线上 FCS = `e9 07 cd 41`; Python `zlib.crc32` (反射/初值 FFFFFFFF/终值取反/小端上线) 复算:

```
crc32(18 数据字节)      = e9 07 cd 41  <== 与线上一致 (pad 被排除)
crc32(60 补 pad 后字节) = 0a bf 59 60
```

对照: X1a 的 60B 内容帧 (无需 pad) 线上 FCS = `0f 5c 64 64` = `crc32(60 字节)` ✓ **无 pad 时正确**。

**证据 B (校准过的 TX→RX 回放 A/B, 以**我们自己的 RX** 为参照)**:
TB 把线上捕获字回放进 RX 注入队列 (`f2x_loop`), 判据 = `rx_stat_crc_err` 增量:

| 用例 | 帧 | FCS 覆盖面 | 我们自己的 RX |
|---|---|---|---|
| X5b | DUT TX, 60B 内容 (无 pad) | 数据 | delivered, crc_err **+0** |
| X5c-a | DUT TX, 68B 内容 (无 pad) | 数据 | delivered, crc_err **+0** |
| X5c-b | TB 自算 FCS, 同 68B 内容 | TB crc | delivered, crc_err **+0** (回放通路校准 ✓) |
| **X5a** | **DUT TX, 20B 内容 ⇒ pad 到 60** | **不含 pad** | delivered, crc_err **+1** ✗ |
| X5d-1 | TB 自造, 18 数据 + 42 pad | **含 pad (标准)** | crc_err **+0** ✓ |
| X5d-2 | TB 自造, 同样 60 线上字节 | **不含 pad (DUT 风格)** | crc_err **+1** ✓ |

⇒ X5d-1 与 X5d-2 的**唯一变量是 FCS 覆盖面**, 判决随之翻转 ⇒ **判据有判别力**, 且
**我们的 RX 要求 pad 计入 FCS**。结合 1G 版 `rtl/mac_tx_64.v` (`crc_en = (state==S_DATA) || (state==S_PAD)`,
pad 计入) 与 10G 版 `mac_tx_10g.v:207` (`crc_en = (state==S_DATA) && ...`, pad 在合并尾字里生成、不进 CRC)
——**两个 MAC 对同一线上格式的 FCS 结论不一致**, 10G 版是偏离方。
（⚠️ 上面这段引的是**修前**的 `mac_tx_10g.v`; 该偏离**已于 `effef26` 修掉** —— 修后 10G 版也把 pad 计入
FCS, `crc_en` 移到 `:258`, 两个 MAC 口径一致。见本节末"修法"。）
P6b 板级证据 (真 ping/ARP 通) 落在 1G 版上 ⇒ 1G 口径经真实网卡验收过。

**为什么既有门都看不见**: 单元门 `tb_mac_10g.v` 的 pad 用例把**期望 FCS** 定义成
`calc_fcs(20)` (只算数据字节, 见 `tb_mac_10g.v:74-84` + 组 8.2 的 `chk(expb[60] === fcsb[0] ...)`),
**oracle 与实现同源** ⇒ 结构上判不出来; 链级门的 TX 侧原先不看 FCS, 环回用例 (组 10) 用的是 200B 帧 (无 pad)。

**影响面 (定级用)**: 10G 下所有 < 60 内容字节的帧 (ARP 应答 42B、TCP 纯 ACK 54B …) 会被对端丢;
且经 `u_tx_arb` 的 HLS 慢路径帧 (ARP/ICMP/TCP 握手) 大量落在此区间。
**修法 (✅ 已落地, 提交 `effef26`「P7b 闸3 功能入库: rx_classify v2 落地 + MAC 接进 wrapper + pad/FCS 缺陷修复」,
文件 `_proj_10g/p7b_mac/rtl/mac_tx_10g.v`)**: 让 pad 字节**参与 CRC** —— pad 在线上就是紧接内容之后的
值 `0x00` 的正常数据字节, 与 `crc32_64` 的 lane 序 (= 线上字节序) 同向 ⇒ 只需把 **keep 扩到 pad 位置**、
并把 **pad 位置的 `d` 压成 0**, 就是"内容 ++ pad"的正确 CRC 输入 (新增"一套"逻辑 = 0)。落到源码 4 处
(`git show --numstat effef26` 记该文件 `+58 / −12`):
① 新增 `cmask64(n)` (`:211-219`) = "前 n 个 lane 置 1"的掩码 —— 合同允许 keep 之外的 lane 是**任意残值**,
   `crc_d = cw_data & cmask64(cw_len)` (`:257`) 先把它们压 0, 否则残值会被当 pad 喂进 CRC;
② `crc_keep` (`:254-256`) 从"内容"扩到"内容 + pad": S_DATA 末字 = `8'hFF << (8 - lw_ts)`
   (`lw_ts` = 内容残余 + 本字 pad), S_TAIL0 纯 pad 字 = `8'hFF`, S_TAIL0 尾起始字 = `8'hFF << (8 - p0_use)`;
③ `crc_en` (`:258-259`) 在 S_TAIL0 恒 1 (纯 pad 字也必须推进 CRC);
④ pad 可能**跨字** ⇒ 末内容字那一拍锁存的 `lw_fcs` (`:340`) 不再是最终值: 新增组合量
   `p0_fcs = crc_nxt ^ 32'hFFFFFFFF` (`:269`), 由 S_TAIL0 尾起始字的发射 mux (`:287`) 取用,
   并在 `:373` `m_fcs <= p0_fcs` 覆盖之 (纯 pad 字的 `tstart0=8` ⇒ 那个中间态不被取用)。
`init/en/d/keep` 仍与发射同拍 (工程坑 1); **RX 一行未动**。对账 (提交信息): 修前线上 FCS
`e4 16 1d c3` → 修后 `11 41 ab 91` (zlib 独立复核) ⇒ 上面证据 B 的"自家 TX 出、自家 RX 判 crc_err"消失。

**判据跟着改了 (不改 oracle ⇒ 修完照样判不出来)**: 原 oracle 是 `fcsb = calc_fcs(20)` —— **只算内容字节**,
与当时实现的覆盖面**逐字同源** ⇒ 实现漏 pad 时 oracle 同步漏 (`252 checks / 0 fail` 全绿; 提交信息记其位置为
`tb_mac_10g.v:925`, 现该行已被取代, 原判据与替换理由逐字留在 `tb_mac_10g.v:920-925` 的订正注释里)。
现改为**独立 oracle `fcs_chk_wire` (`tb_mac_10g.v:472-492`), 输入 = 从线上解出的字节 `expb[]`**
(含 DUT 自补的 pad), 两条判据: (a) DUT 写在线上的 FCS 字段 == `CRC(线上全部内容字节 incl pad)` 的终值取反;
(b) 自洽残差 —— 线上内容 + FCS 全流过 ⇒ `0xDEBB20E3` (与 `mac_rx_10g` 同一魔数)。
调用点 = 组 8.2 的 pad 用例 (`:925`) + 新增的 **TX→RX 自洽回放组**(组 11, `:1164-1214`:
内容 L = 1/18/42/54/57 + 60/200 对照, 逐档判 `rx_fcrs==1` 且交付逐字节)。
⇒ **判据 252 → 337** (`_proj_10g/p7b_mac/sim/_mut_logs/00_clean.log`: `337 checks, 0 fail`, `VERDICT = PASS`);
变异 **16 条**全符预期 —— 其中 **M11a**(整块回退到 HEAD 语义) 的 FAIL 集与"直接拿 HEAD 的 RTL 跑"
**逐条相同**(等价标定), **M11d 等价, 如实报"没抓到"**。
**未核实**: 802.3 §3.2.9 原文不在本仓 (未逐字核); 但"自家 TX/RX 不一致"已由 X5a/X5d 自证, 不依赖外部标准。

---

## 11. 复现命令 / 证据文件

```bash
# 归因实验 (pristine; 唯一 FAIL = DEFECT-REG #1, 与 F-2 无关)
cmd //c '_proj_10g\p7b_chain\sim\run_tb_p7b_chain.bat'
# 变异对照 (MUT-NOFLUSH: 去冲刷 ⇒ 幽灵帧)
python _proj_10g/p7b_chain/mut_f2_noflush.py
P7B_MUT='D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\p7b_chain\_f2_scratch' cmd //c '_proj_10g\p7b_chain\sim\run_tb_p7b_chain.bat'
```

| 文件 | 内容 |
|---|---|
| `_proj_10g/p7b_chain/logs/xsim_p7bchain_pristine_final.log` | pristine 全量日志 (70 检查 / 1 FAIL) |
| `_proj_10g/p7b_chain/logs/xsim_p7bchain_mut_noflush_final.log` | 变异全量日志 (70 检查 / 10 FAIL, 含幽灵帧字节) |
| `_proj_10g/p7b_chain/logs/f2x10_*_FINAL.txt` | 门 stdout (bat 过滤版) |
| `_proj_10g/p7b_chain/patch_f2_diag.py` … `patch_f2x10.py` | 本次对 TB 的全部改动 (可逐条审计/回滚) |
| `_proj_10g/p7b_chain/mut_f2_noflush.py` + `_f2_scratch/` | 变异生成器与 scratch 副本 |
| `_proj_10g/p7b_chain/sim/tb_p7b_chain.v.f2bak` | 改动前的 TB 备份 |

## 12. 本次对现场的改动 (TB 与门; 未动 `rtl/`)

1. `sim/tb_p7b_chain.v`: 新增 F2X 组 (X1a/X1b/X2/X3/X4 + X5a-d) —— 合同正确的 F-2 链级判据 + 归因诊断
   (`[F2W]`/`[RAW]`/`[INJW]`/`[TR]`/`[WFRAME]`/`[F2X]` 打印)。窗口用快照基准, 注入用 negedge 落地。
2. 原 F-2 组的 4 条 `[OPEN]` 行改为标注 **SUPERSEDED by F2X X4**(读数与历史保留, 不改成"通过")。
3. X5a 登记为 **REGISTERED DEFECT #1** 判据 + `[DEFECT-REG #1]` 醒目打印。
   ✅ **2026-09-30 订正**：该缺陷（pad/FCS 覆盖面）**已修**（提交 `effef26`）⇒ **该判据现已转绿**：
   修后链级门 `80 checks, 0 fail` / `VERDICT = PASS`，`X5a pad frame complete+padFCS` 判 `[PASS]`
   （`_proj_10g/p7b_chain/logs/f2x11_pristine_newmac_FINAL.log:1760,1889`）。
   原句"**修好之前应保持红**"**已作废**；`[DEFECT-REG #1]` 打印保留、转为**回归守卫**
   （变异 `MUT-PADNOCRC` 把它重新打红）。同源订正见本文件 §10 标题的 `[✅ 已修: effef26]`。
4. 备份: `sim/tb_p7b_chain.v.f2bak`。
