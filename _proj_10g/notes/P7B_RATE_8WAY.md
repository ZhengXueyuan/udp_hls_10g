# P7B app 图案发生器/校验器 → **8 字节/拍**（10G 线速第一刀）

- 日期：**2026-09-30**　性质：**RTL 实现 + xsim 验证**。
  ⚠️ **未烧板、未跑 Vivado 综合/实现**（合并构建由主线统一安排）；**未改 license**；**未 git add/commit**。
- 文件所有权：本 agent 只写 `rtl/app_udp_pattern.v`、`_proj_10g/notes/P7B_RATE_8WAY.md`、`_proj_10g/notes/p7b_rate8/**`。
  **未碰** `rtl/udp_tx_frame.v`（另一路 agent 的乒乓重叠，见瓶颈报告 §5.2）。
- 起点 = `_proj_10g/notes/P7B_RATE_BOTTLENECK.md`：瓶颈 = 发生器 **1 字节/拍** ⇒ **1474 拍/帧 = 1.248 Gbps**
  （板侧 `W20` = 106,003.170 fps 与之吻合 0.0002%）。

---

## 0. 判决（一句话）

TX 发生器与 RX 校验器**都**改成 8 字节/拍（`M^k` **常量 XOR 网**，不是 8 次级联），**逐字节序列逐位不变**；
板级同构全链实测 **1470.6~1477.8 拍/帧 → 377.8 拍/帧**、**1.245~1.251 → 4.870 Gbps（3.90×）**，
与瓶颈报告预测的 374.1 拍 / 4.9189 Gbps 吻合 **1%**；新瓶颈按预期落到 `udp_tx_frame`（378 拍/帧）。

⚠️ **一条红**：`sim/p5e_udp` 的 `pos` 门在 **wide 构建**下有**恰 1 条**判据变红
（`P④ 突发确实溢出丢帧 (8x 于消费率)`）——**判据前提被这次提速推翻，不是设计缺陷**，见 §4.1。

---

## 1. 改法

### 1.1 宏与「默认构建逐位不变」

- **新宏？不是**：全部包在**既有宏 `P7B_10G`** 内（该宏只有 P7b 的 10G 构建/门在定义：
  `board/build_p7b_ku5p.tcl:140` = `{APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1}`）。
  未定义时 = **今天一字不差的 RTL**（P5/P6a/P6b/P6e/K7 全部构建 + 全部 xsim 门）。
- **等价性是「证明」不是「声称」**：`_proj_10g/notes/p7b_rate8/apply_wide.py` 自带一个只认
  `` `ifdef/`ifndef/`else/`endif `` 的极简预处理器，**断言**「无 `P7B_10G` 定义集下，改动后源码的预处理结果与
  `app_udp_pattern.v.orig`（= 改动前）逐字节相同」：

```
PP-EQUIV default (no P7B_10G): IDENTICAL  (old 23281 bytes / new 23281 bytes)
PP with P7B_10G: 708 lines (default 491 lines) => +217 lines
```
- 手法：所有被改动的行都写成
  `` `ifdef P7B_10G / <新写法> / `else / <原语句逐字照抄> / `endif `` ⇒ 未定义时预处理器**原样吐回原语句**。
  `git diff --stat` 因此显示 **274 insertions / 0 deletions**（新行插在 ifdef 里，老行仍在 else 分支）。
- 产物：`rtl/app_udp_pattern.v` 775 → **1049 行**，sha256 前 16 位 `b6985b7d8e5e8786`
  （`git diff --stat` = **274 insertions / 0 deletions**；本报告 §2 的读数都是这个版本上跑的）。

### 1.2 逐处改动（`rtl/app_udp_pattern.v`；行号为改动后）

| # | 位置 | 改了什么 | 为什么最小 |
|---|---|---|---|
| 1 | `:224-346`（`ifdef` 块） | 新增两个**函数** `xs_next8`（M^8·s，64 行）/ `xs_word8`（8 个连续输出字节，64 行） | 只放**一份**映射：TX 与 RX 共用同一函数（原 `xs_next` 也是函数写法，风格一致）；未定义时不进文件 |
| 2 | `:510-523` | TX 侧线网：`tx_lfsr_8 = xs_next8(tx_lfsr)`、`gen_word = pay_ok ? xs_word8(...) : 64'hA5A5…`、`wide_ok = gen_ok && (left>=8)` | 复用既有 `pay_ok`/`gen_ok`/`left` 三个线，不新增状态 |
| 3 | `:524-528` | `frm_close` 加 `|| wide_ok` | 帧收尾判据唯一落点（推送侧）必须认得满字推送，否则帧计数/限速/done 全不动 |
| 4 | `:772-786` | `T_FRM` 里**新增第一条分支** `if (wide_ok) … else <原分支链>` | **不改原分支链一个字**；`else` 挂在新 if 上，未定义时该行整条消失 |
| 5 | `:581-620` | RX 侧块：`rx_exp_word`/`rx_lfsr_8`/`wide_cmp`/8 个 `rx_bad_v`/`rx_bad_n`/`cmp_ld_w`/`assign rx_tready` | 期望序列用**同一个**`xs_word8` ⇒ 两侧同源 |
| 6 | `:856-870` | 引擎分支判据 `cmp_end` → `cmp_end \|\| wide_cmp`（ifdef 双写） | 满字**一拍比完**的唯一改动点 |
| 7 | **`:849/864/877`** | **`nx_v <= rx_ld`**（三处消费分支） | **本改造唯一一个结构性缺陷的修法**（见 §1.4） |
| 8 | `:883-903` | 计数器：`rx_lfsr` 推 M^8、`stat_rx_bytes += 8`、`stat_mismatch += popcount(失配 lane)` | 与串行路径**同口径**（都是"每字节"，不是"每拍"） |
| 9 | `:569-580` | `rx_tready` 原位加 ifdef 守卫（宽路径的 `rx_tready` 定义在 RX 块里） | 该块要用 `cmp_ld_w`，而 `cmp_ld_w` 又要 `cmp_end`（在 396 之后）⇒ 位置受限 |

**为什么不是 8 次级联**：`M` 是 GF(2) 上的 64×64 线性算子。级联 8 次 = **24 级 LUT**（~7 ns @K7-2，直接破时序）；
`M^k` 每行只是「若干 s 位的 XOR」（**平均 21.8 项 / 最多 34 项**）⇒ **深度 ≤ 3 级 LUT6**。
总开销 = **2283 项 XOR**（M^8 1392 + 8 个字节行 891）。

**为什么逐字节不变（不是近似）**：`b_k = (M^k·s)[31:24]` 恰是「先取后推进」序列的第 k 个字节，状态推进 `M^8`
与 8 次推进同值 ⇒ 与 `peer.cpp:1952`（`dst[i] = s>>24; s = xs_next64(s)`）、`app_pattern.v`、逐字节路径**恒等**。
**不需要改 peer / 种子 / 任何判据**（实测见 §2.1）。

**非 8 倍数载荷（唯一陷阱）**：`wide_ok` 只在 `left >= 8` 成立 ⇒ **尾字自动落回既有逐字节路径**
（含 PLEN_MAX 冻结 + 0xA5 填充 + 0 长数据报），**没有第二套尾字实现**，因此不会与主路径漂移。

### 1.3 生成件与可复现性

| 文件 | 作用 |
|---|---|
| `_proj_10g/notes/p7b_rate8/gen_mat8.py` | 生成 `wide_funcs.v.txt`；**内含三条自校验**：A) `M^8·s` == 8 次 `xs_next`（201 个种子）；B) 字节行 == 逐步 `xs_next^k`；C) 8 路拼出的 1000 字节 == 逐字节序列前 1000 字节 |
| `_proj_10g/notes/p7b_rate8/apply_wide.py` | 把函数块 + 各处 ifdef 变更拼进 `rtl/app_udp_pattern.v`（10 个锚点，每个**断言命中恰 1 次**）；并跑 §1.1 的等价证明；`--check` 可只验不写 |
| `app_udp_pattern.v.orig` | 改动前基线（= `git show HEAD:rtl/app_udp_pattern.v`，已核对） |

### 1.4 ⚠️ 施工中抓到的真缺陷（**这是本改造唯一的结构性问题**）

`rx_tready = !nx_v` 这条「前瞻空即收」是**同拍互斥**的基石（原注释 `:599`：「装载 (前瞻空位才有 rx_tready
⇒ 与下面的'消费 nx'结构性互斥)」）。宽路径要 1 字/拍，就必须让「前瞻字被消费的**同一拍**再收一个字」
（`rx_tready = !nx_v || cmp_ld_w`）——**这一放宽打破了互斥**：同一拍既把 nx 搬进 cmp、又把新字装进 nx，
而引擎里那句 `nx_v <= 1'b0` 落在 `rx_ld` 之后 ⇒ **新装进来的字被静默丢弃**。
实测症状：**回环只收到一半字节**（L0 `txb=356224 / rxb=178112`，massive mismatch）。
修法 = 三处消费分支改成 `nx_v <= rx_ld`（`rx_ld=0` 时等价于原句）。
⇒ 这条是"必须同批改 RX"之外的**独立**理由：**只有把 RX 也变快，才会踩到它**。

---

## 2. 五个验证（全部**真跑**，日志在 `_proj_10g/notes/p7b_rate8/**`）

### 2.1 逐字节等价（最重要）—— 门 `sim/run_app8_gate.bat`

**同一个 TB**（`sim/tb_app8_equiv.v`）用两种宏各编译一次，把 TX 载荷字节流 + 每帧字节数落盘后 `fc /b` 比对：

| 配置 | 覆盖点 | 结果 |
|---|---|---|
| T0 paylen 1472 / GAP 0 | **板级同构**（1472 = 184×8，背靠背） | 12000 B 逐字节相同 |
| T1 paylen 1477 | **非 8 倍数**（184×8+5 ⇒ 尾字 5 B） | 相同 |
| T2 paylen 5 | 全尾字（< 8） | 相同（2400 帧） |
| T3 paylen 8 | 恰一个满字 | 相同（1500 帧） |
| T4 paylen 1501 | **> PLEN_MAX**（冻结 + 0xA5） | 相同 |
| T5 TX_BYTES 4419 | 有限会话（1472 + 2947，末帧 3 B） | 4419 B 全量相同 |
| T6 paylen 1472 / GAP 7 | 帧间限速 | 相同 |
| L0/L1 回环（TX 直连 RX） | 1472 / 1477 两条路径 | `mm=0` 且 `rxb == txb` |
| R0/R1 注入式 RX | 满字 lane1 / lane7 翻位**必须抓**；尾字**无效 lane**翻位**必须不抓**；0 长帧 | `mm` **恰 1 / 恰 1**，`rxb`/帧数/0 长帧计数全对 |

```
APP8-GATE: PASS            (exit 0)
  A default      RC=0   B P7B_10G  RC=0
  [PASS] byte-equivalence: A vs B identical on 14 dump files
  T0: txf=416 txb=612376 | dump=12000 frm(rec)=9
  L0: txb=356224 rxb=356224 txf=242 mm=0        L1: txb=348572 rxb=348572 txf=236 mm=0
  R0: rxb=8907 frames=12 null=1 mm=1            R1: rxb=2949 mm=1
```
> 覆盖了「背靠背 + 有间隙 + 伪随机 backpressure（每拍 ~6% 拉低）」三种节奏；
> **帧长也单独比对**（`.frm` = 每帧字节数），所以"字节对但切帧错"同样会被抓。

**独立复算**（`sim/check_dump.py`）：三条互不依赖的路径互证 ——
① `peer.exe --pat-selftest` 的 oracle（**peer 自己的生成路径**）；
② 本脚本用 Python 重写同一递推；③ xsim 两个构建的 dump。
```
peer.exe oracle (first 16) = 7F 0B 02 E5 36 A1 4E D6 1A B0 49 B8 56 AD D6 3F
python 复算前 16 字节      = 7F 0B 02 E5 36 A1 4E D6 1A B0 49 B8 56 AD D6 3F  -> 逐字节一致
 cfg paylen TX_BYTES  dump(B)  B==python  A==B  frm==model  A==python
 T0    1472      0     12000    True       True  True        True
 ...（T1..T6 全 True）...
INDEPENDENT-RECHECK: OK (全部逐字节一致)
```
**第四条（既有门的独立模型，且是"线上捕获"口径）**：`sim/p5e_udp` 的 `pos` 门里
`check_all_pattern` 把**线上捕获的全部 TX 帧**逐字节对着它自己的顺序模型比（`chk(txv_bad == 0, "P② …逐字节")`）——
wide 构建下该门**只有 CHK_65 红**（见 §4.1）⇒ **P② 通过** ⇒ 8 字节/拍的字节流**穿过真实
`udp_tx_frame`/`tx_arb`/MAC 之后仍逐字节等于 peer 序列**。

### 2.2 拍/帧与 Gbps（实跑门 `sim/run_rate8.bat`，156.25 MHz）

| 被测级 | 改造前 (A) | 改造后 (B) | 比值 |
|---|---|---|---|
| `app_udp_pattern` **发生器单独**（下游恒 ready） | **1474 拍/帧 · 1248.3 Mbps** | **186 拍/帧 · 9892.5 Mbps** | **7.92×** |
| **板级同构全链**（app→cfg→frame→arb→arb→mac_tx_10g） | **1470.6 / 1477.8 拍 · 1245.1 / 1251.2 Mbps** | **377.834 拍 · 4869.9 Mbps** | **3.90×** |

- 186 拍 = **184**（184 个满字，1 拍 1 字）+ **2**（`T_IDLE`+`T_GAP` 固定开销）⇒ **发生器已不是瓶颈**
  （其天花板 9.89 Gbps **高于 10G 线速载荷上限 9.571 Gbps**）。
- 全链 377.8 拍 vs 瓶颈报告的行为级预测 **374.1 拍 / 4918.9 Mbps** ⇒ 吻合 **1%**，**新瓶颈 = `udp_tx_frame` 的 378 拍/帧**
  （= 瓶颈报告 §5.2 的改动 2，另一路 agent 的活）。
- A 侧读数与瓶颈报告 §1 的记录**逐字一致**（1474 / 1248.3 / 1470.588 / 1251.2）⇒ 默认路径零漂移的旁证。

### 2.3 RX 同批改后的既有门

| 门 | 默认构建 (def) | **wide (-d P7B_10G)** |
|---|---|---|
| `run_tb_app_udp.bat pos` | **RC=0** ✅ | **RC=1**（errs=1，**唯一红 = CHK_65**，见 §4.1）⬅ 如实报告 |
| `… neglearn`（负对照，期望 1） | RC=1 ✅ | RC=1 ✅（判别力保持） |
| `… splitoff / portout / badcrc / nopeer` | — | **RC=0 / 0 / 0 / 0** ✅ |
| `sim/rxpdiag/run_tb_rxp_diag.bat`（RXP_DIAG 仪器） | RC=0 ✅ | **组合 `RXP_DIAG+P7B_10G` RC=0**，且与只 `RXP_DIAG` 的**仪器读数逐字相同** ✅ |
| `_proj_10g/p7b_appsplit/sim/run_tb_p7b_appsplit.bat`（定义 `P7B_10G` 的真 wrapper 门） | — | **EXIT=0**，26 条 `[PASS]` / 0 `[FAIL]` ✅ |

> wide 构建下 `neglearn` 仍 exit 1 ⇒ 正例判据**仍然由 learn-on-RX 驱动**（没有"判据失去判别力"）。

### 2.4 默认构建回归

1. **源码级**：`apply_wide.py` 的预处理器断言「无 `P7B_10G` ⇒ 与改动前逐字节相同」（§1.1，机器证明）。
2. **功能级（1G 全链速率门）**：瓶颈报告点名的 `sim/p5e_rate/run_tb_rate.bat g0p1472` **逐字不变**：
   `PAYLOAD RATE = 929.3 Mbps / WIRE RATE = 962.8 Mbps / frames on wire = 41 / mean frame period = 1584 拍`
   （与 `_proj_10g/notes/P7B_RATE_BOTTLENECK.md` §5.1 记录的 929.3 Mbps 相同）。
3. **P4 全矩阵 16 门**：**16/16 `EXIT=0`、总 `P4MATRIX EXIT=0`**（见 §5）。
   ⚠️ **但它对本改动没有判别力**：5 个 manifest（`sim/p4gates/*_src.f`）**都不含 `rtl/app_udp_pattern.v`**
   （实测 `grep -c app_udp_pattern` = 0/0/0/0/0）⇒ 这 16 门**根本没编我这个文件**，
   "跑过"只说明"仓库默认回归套件整体还是绿的"，**不能**当作"我的改动不破默认构建"的证据。
   真正有判别力的默认构建证据是上面两条（源码级等价证明 + 1G 速率门逐字不变）。

### 2.5 反例（**必须变红**，真跑）

`sim/make_negctl.py` 从**当前** RTL 派生两个变异件，门里每次都重新生成（不会陈旧）：

| 变异 | 期望红在哪 | 实测 |
|---|---|---|
| **C = M^8 退化成 M**（`xs_next8(tx_lfsr)` → `xs_next(tx_lfsr)`） | ① dump 文件 diff ② TB 回环失配 | ✅ 两条都红（`[PASS] negctl-C red: dump differs from A`；`L0/L1 回环零失配` FAIL，errs=2） |
| **D = RX 只比 lane0**（`rx_bad_v[7:1]` 钉 0） | R0(lane1 注入)/R1(lane7 注入) 的"失配恰 1" | ✅ 两条都红（errs=2）；同时 dump **仍逐字节相同** ⇒ 两条判据覆盖面不重叠 |

> C 的 dump 差异是**真差异**（不是我植入的），D 的 dump 相同也是**真相同** ⇒ 判据**有判别力**且**各自负责一格**。

---

## 3. 五个验证的落盘位置

```
_proj_10g/notes/p7b_rate8/
├── P7B_RATE_8WAY.md            (本文)
├── gen_mat8.py / wide_funcs.v.txt / apply_wide.py / app_udp_pattern.v.orig
├── appsplit_out.txt            P7B appsplit 真 wrapper 门
├── chain_out.txt               P7B chain 全链门 (见 §5)
├── p4matrix_out.txt            P4 16 门矩阵 (默认构建回归)
└── sim/
    ├── tb_app8_equiv.v         逐字节等价 TB (7 dump 配置 + 2 回环 + 2 注入)
    ├── run_app8_gate.bat       四模式门 (A/B/C/D) + 14 文件 fc /b 比对
    ├── check_dump.py           独立复算 (peer.exe oracle + python 重写 + 帧长模型)
    ├── run_rate8.bat           拍/帧 (A vs B)
    ├── run_tb_app_udp_p7b.bat  既有 p5e_udp 门的宏变体 (6 模式 × 2 变体)
    ├── run_rxpdiag_p7b.bat     RXP_DIAG 宏组合门 (含 A/B 读数对比)
    ├── make_negctl.py          C/D 变异件生成
    ├── mk_tagged_tb.py         chk 标签 ASCII 化 (定位 §4.1 那条红) + chk_map.txt 回指表
    ├── runA runB runC runD     dump 与日志
    └── ua_wide ua_def rd_A rd_B ua_tag (标签 TB 的跑数目录)
```

---

## 4. 残余风险（含"没抓到"的如实说明）

### 4.1 ⭐ 一条**已知红**：`sim/p5e_udp pos` 的 `P④ 突发确实溢出丢帧 (8x 于消费率)`

- **定位方式**：xsim 把中文写成 0xFF 填充的不可读字节（`BYTES: … ffffff91ffffffaa …`），
  所以做了 `sim/mk_tagged_tb.py`——把 `tb/tb_app_udp.v` 的 chk **标签**换成 `CHK_<n>`（逻辑一字不动），
  跑完**精确回指** `chk_map.txt` ⇒ 红的就是 `CHK_65 = "P④ 突发确实溢出丢帧 (8x 于消费率)"`。
- **机理（结构性，不是估计）**：该判据的前提是「8× 背靠背 1472B 灌入 > app 消费率 ⇒ `udp_split` 4KB 帧缓冲必然溢出」。
  改造后 app 消费 **8 B/拍**，而注入源是 **RGMII/GMII 前端（1 B/拍）** ⇒ **缓冲占用结构性不可能增长**。
- **这条红恰恰是提速的证据**：同一次运行里 8 帧**全交付**（`app_frames+8`）、**零失配**、`drop_part=0`、`drop_crc=0`、
  `split+8`，即 P④ 的其它 8 条判据全过，只有"**必须丢帧**"这条不再成立。
- **不是反例失效**：`neglearn` 在 wide 构建下仍 exit 1；`splitoff/portout/badcrc/nopeer` 仍全过。
- **默认构建（无宏）不受影响**：`pos` = RC 0（今天所有 1G 构建跑的就是这条）。
- **建议**（属于该门 owner 的决定，本 agent 未改 `tb/tb_app_udp.v`——不在我的文件所有权内）：
  10G 下线速就是 8 B/拍，届时"是否溢出"取决于 `udp_split` 的 store-and-forward 抖动 ⇒ 溢出记账路径**仍然活着**；
  建议把 wide 构建下的期望改成「交付+丢 == 8 **且交付字节逐字节正确**」并**显式标注**该条前提已变。

### 4.2 时序/资源 = **分析值，未综合**（我被禁止跑综合/实现）

- 2283 项 XOR、每行 ≤ 34 项 ⇒ 深度 ≈ **3 级 LUT6**、量级 **~1 K LUT**（按 XOR6/LUT6 折）。
  与瓶颈报告的 ~4 K 估计同量级（实际更省，因为只有一份映射且 TX/RX 共用函数）。
- **必须由合并构建复测**：基线 `WNS +0.128 / WHS +0.010 / 三类失败端点 0`；
  新增组合逻辑落在 `tx_lfsr → xs_next8/xs_word8 → fifo_sync 写` 与 `rx_lfsr → rx_exp_word → 比对` 两条路上。
- 本改造**没有新增任何流水 valid 位**（全部是同一拍内的组合），所以**不触碰坑 6/12 的脉冲语义**；
  唯一新增的时序风险是上述两条组合路径的深度。

### 4.3 宏组合边界

- `P7B_10G + RXP_DIAG`：宽 RX **主动关闭**（`wire wide_cmp = 1'b0`）——因为 v1–v4 仪器是**逐字节量**
  （`ds_idx` 活计数器 / 帧内偏移桶 / 事件 FIFO），与满字并行比对不兼容。
  实测该组合的仪器读数与"只 RXP_DIAG"**逐字相同**（§2.3）⇒ 退化是**正确且可验证**的，代价只是慢。
  ⚠️ **目前没有任何构建同时开这两个宏**（已全仓 grep 确认）。
- `P7B_10G` 未定义 ⇒ 与改动前源码预处理后**逐字节相同**（§1.1，机器证明）。

### 4.4 没抓到 / 没做的

1. **板级未验**（不烧板，按任务要求）：真正的板级读数（`W20` 帧率、PCIe 窗口）**未测**；
   板级判据仍然是"1.248 Gbps 是瓶颈报告从板级读数反解出来的同一个数"，本改造**没有**板级确认。
2. **`p7b_chain`（106 判据）与 `p7b_appsplit` 都是 RX/链路侧**，**不覆盖** app 的 TX 载荷字节 ⇒
   线上字节的独立模型证据只有 `p5e_udp` 的 `check_all_pattern`（§2.1 第四条）。
3. **P4 矩阵对本改动无判别力**（manifest 不含本文件，§2.4）——这是"跑了但什么都没证明"的典型形态，
   按本工程"判据要有判别力"的要求如实标注。
4. **RX 侧的板级后果未测**：8 字节/拍把"回灌丢帧"这个债还了，但**没有板级回灌测量**。
5. **`i_en` 在半字中途翻转**：文档约定"必须在静止时翻转"；宽路径把窗口从 8 拍缩到 1 拍，
   **该约定的边界更紧**（未测，属既有语义）。
6. **10G 线速端到端**：本改造只把第一级拉到 9.89 Gbps；全链仍卡在 `udp_tx_frame`（377.8 拍 ⇒ 4.87 Gbps），
   **线速要等改动 5.2 落地**。本 agent 未碰那个文件。
7. `rtl/app_pattern.v`（TCP 演示 app）**未动**：它的数据面路径不在本次瓶颈上（UDP app 才是 10G 图案源），
   且不在任务范围（改动它的收益 <0.5%，风险另计）。

---

## 5. 本轮读数

- **P7B chain 全链门**（`_proj_10g/p7b_chain/sim/run_tb_p7b_chain.bat`，定义 `P7B_10G`）：
  **106 条 `[PASS]` / 0 条 `[FAIL]`，`VERDICT = PASS`**（原件 `chain_out.txt`）。
- **P7B appsplit 真 wrapper 门**（同样定义 `P7B_10G`）：**EXIT=0**，26 `[PASS]` / 0 `[FAIL]`（`appsplit_out.txt`）。
- **P4 16 门矩阵（默认构建回归）**：**16/16 `EXIT=0`**、`P4MATRIX EXIT=0`（`p4matrix_out.txt`）：
  `chain / burst200 / trunc50 / trunc100 / halfdrop / txdrop50 / gate4096 / dupstorm / pcackoob /
   vlanchain / vlanburst / stallgate / unit_retx / unit_fifo / unit_vlan / unit_uart`
  ⚠️ **覆盖面对本改动为空**（manifest 不含 `app_udp_pattern.v`，见 §2.4）。
- **既有门宏变体的完整读数**：`sim/run_tb_app_udp_p7b.bat` 6 模式 × 2 变体 =
  wide: pos=1(仅 CHK_65) / splitoff=0 / portout=0 / badcrc=0 / nopeer=0 / neglearn=1；
  def: pos=0 / neglearn=1。

### 5.1 与另一路 agent（`rtl/udp_tx_frame.v`）的接口

- 本报告所有"全链"读数（A 与 B）都是**在对方改动未生效的状态下**测的：
  对方的乒乓重叠包在新宏 `` `ifdef UDP_TX_OVL ``（`rtl/udp_tx_frame.v:67`）内，**本轮的 A/B 与全仓门都没有定义它**
  （已核对：`git diff` 里新增行都在该宏内）。⇒ **B 的 377.834 拍/帧 = `udp_tx_frame` 串行版的口径**，
  两次独立运行的读数逐字相同（16:47 与 17:0x 各一次）⇒ 不受对方在跑期间的落盘影响。
- 按瓶颈报告 §6，`UDP_TX_OVL` 生效后全链应落到 ~199 拍/帧 ≈ **9.23 Gbps**（**对方的预测，非本轮实测**）。

## 6. 复现方式（全部自定位，无绝对仓路径）

```bash
# 逐字节等价门 (四模式 + 14 文件比对, ~4 min) —— 本改造的**核心判据**
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_rate8\sim\run_app8_gate.bat'
# 独立复算 (peer.exe oracle + python 重写 + 帧长模型)
C:/Users/zhxue/anaconda3/python.exe _proj_10g/notes/p7b_rate8/sim/check_dump.py
# 拍/帧 (A vs B)
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_rate8\sim\run_rate8.bat'
# 既有 p5e_udp 门 (6 模式 × {wide,def})
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_rate8\sim\run_tb_app_udp_p7b.bat pos wide'
# RXP_DIAG 宏组合
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_rate8\sim\run_rxpdiag_p7b.bat'
# 重新生成 RTL (幂等; 会重跑 §1.1 的等价证明)
C:/Users/zhxue/anaconda3/python.exe _proj_10g/notes/p7b_rate8/apply_wide.py
```
