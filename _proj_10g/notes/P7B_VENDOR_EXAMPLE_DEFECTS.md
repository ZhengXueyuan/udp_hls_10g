# P7B 厂商 example 的两笔遗留账 —— 收尾档（2026-09-30）

> 覆盖 `_proj_10g/notes/P7B_HANDOFF.md` §4 的**第 1 条**（厂商 example 的 FCS 缺陷）与**第 3 条**
> （10 条 `Synth 8-11241`）。**本档只做"查清 + 定位 + 定论 + 处置建议"**，不修改任何既有产物。
>
> **本轮纪律（逐条遵守）**：**未改厂商 example 源码**（一格未动）· 未改任何 RTL / XDC / 构建脚本 ·
> 未动既有笔记（`P7B_*` 全部只读） · **未烧板** · **未跑仿真/综合**（另一个 agent 在跑 Vivado 构建） ·
> 无 git 写操作 · 未碰 `D:\repo\perfv`。复算只用 python。
>
> **证据标记**（与 `P7B_SPEC.md` 同义）：【明文RTL】仓库内可逐行核对的源码 ·
> 【日志原文】构建日志原始文本 · 【复算】本档独立重算（脚本+输出已入档） ·
> 【板级实测】上板读数原件 · 【推定】推理 · 【未核实】不知道，**不得当判据用**。

---

## 0. 一句话结论

| 账 | 结论 |
|---|---|
| **A. 厂商 example 的 FCS** | **缺陷成立，且本轮由"长度论证"升级为"逐位复算"**：发生器的 CRC 覆盖长度用 `pkt_len-4 = 252`，而实际被保护的数据只有 **244 B**，多出的 **8 B 正好是 word0 那个"/S/ + 前导"字**（厂商把 `pkt_len` 当成了"不含前导的帧长"）。复算给出厂商实际发出的 FCS = `5F 3F DD 10`，正确值应为 `7F 9E D8 D5`（同一帧）；出厂默认 `insert_crc=1'b0` 时 FCS 字段恒为 `00 00 00 00`。**两档都被任何 802.3 接收器判坏** ⇒ 这解释了闸 2 记录为"没有按期望翻转"的那条差分负对照。**我们自己的 MAC 没有这个缺陷**（结构性：CRC 输入只来自内容 lane，前导字在 `S_PRE` 且 `crc_en=0`）。**建议：不修厂商源码**，只加档 + 在自有门里加"FCS 由独立 zlib 复算"判据 + 把厂商文件的 CRC 行**冻结**（谁改谁报警）。 |
| **B. 10 条 `Synth 8-11241`** | 10 条**全在厂商 example 的 `pcs64_pkt_gen_mon*.v` 里**（我们自己的 RTL **0 条**）。逐条判过：**3 条**接的是**显式 1 位端口**（宽度一致，无截断）；**7 条**是**死网**（全文件仅此一处出现，无任何消费者）⇒ **无功能影响**。**已核实 p7b 构建不打印这 10 条**（HEAD 里那份完整 stdout 五键全 0 命中，而 `build_p7b_ku5p.tcl` 根本不导入该文件）⇒ **bat 的硬门不会误伤**。⚠️ 但**门的覆盖面有个洞**：p7b 项目**自己的 IP OOC run 日志里有同族 28 条**（厂商生成的 `pcs64_wrapper.v`），**不在 bat 的 grep 面内**；且该 bat 命中也**不置 exit code**（只打 banner）。**建议：键保留，例外按 (文件, 符号) 登记**，并把 grep 面扩到 `.runs/*_synth_1/runme.log`。 |

---

## 1. 任务 A —— 厂商 example 的 FCS 缺陷

### A.1 事实：源码在哪（三份副本，行号各差一截）

厂商 example 的图案发生器/监视器**不是加密网表**（加密的只有 `xxv_ethernet` 核本身），
所以这一笔账**可以逐行读**，不属于"无法判定"。

| 副本 | 路径 | 用途（**按 mtime 定的时间序**） | sha256 |
|---|---|---|---|
| **① 出厂原件（基准）** | `_proj_10g/xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_pkt_gen_mon.v` | **闸 1 验收构建**（`s2_build_FINAL.txt`，09-29 20:17→20:23）就用的它 —— 按**绝对路径**直接加进工程，不复制不改（`P7B_GATE1.md` §2.2）。`P7B_GATE1.md:647` 登记的也是它 | `2782d688b5ea4e676be4e984735f759d9c7be7d6ebd6a2a0ac93f095ab0e03e6` |
| ② 参数化副本 `_ds` | `_proj_10g/xxv_loop/rtl/pcs64_pkt_gen_mon_ds.v` | **闸 1 之后的同工程再构建**（20:54 建副本 → 20:59 synth → 21:04 位流；即 `P7B_GATE1.md` §10 记录的那一轮后续构建）用它 | `d36409bb0dee64b707e1b12d02db7279732efe234218282fbdf6b8ca21e109bf` |
| ③ 参数化副本 `_g2` | `_proj_10g/xxv_gate2/v2/rtl/pcs64_pkt_gen_mon_g2.v` | **闸 2 位流**用它（把 `insert_crc` 接成 VIO 可控） | `f271e880206c5e8caa294ab9264be767176c234b93ff7d20d1eef764b372578a` |

**②③ 与 ① 的差异（逐字 diff 实测）**：模块改名 + 新增 `pay_sel` 通路（`data_select` 由 `2'b0` 改
`{1'b0,pay_sel}`）+ ③ 把 `assign insert_crc = 1'b0` 改成 `insert_crc = crc_en`
（`P7B_GATE1.md:1123` 登记为"6 处 diff，`pay_sel=0` 等价原文"；`P7B_GATE2.md:143` 的"原件一格未动"
指**③ 只动了 3 行**）。**关键**：**三份的 CRC/覆盖相关行逐字节相同**（diff 里该区域零变化）
⇒ 缺陷是**原厂缺陷**，不是我们改出来的。

**行号偏移（同一条代码在三份里的行号）**

| 代码 | ① 出厂原件 | ② `_ds` | ③ `_g2` |
|---|---|---|---|
| `PKT0_CRC = gen_CRC_const(pkt_len-4,1'b0)` | :1030 | :1040 | :1041 |
| `gen_CRC_const()` 函数体 | :1216-1226 | :1226-1236 | :1227-1237 |
| `assign insert_crc = 1'b0` | :186 | :190 | （改为 `= crc_en`） |
| `parameter FIXED_PACKET_LENGTH = 256` | :127 | :131 | :132 |
| 顶层传 `.FIXED_PACKET_LENGTH (256)` | — | `xxv_loop_top.v:302` | `xxv_loop_g2_top.v:303` |

> ⚠️ **一处需要订正的既有陈述（非本档 owner 的笔记，故只在此登记）**：`P7B_GATE1.md` §2.2 的
> "按绝对路径直接加进工程，**不复制、不改**" 只对**闸 1 验收构建**成立；`xxv_loop` 工程**后续**的
> 构建（20:54 起）用的是 `rtl/pcs64_pkt_gen_mon_ds.v` 这份**参数化副本**（`.xpr` 实测：
> `$PPRDIR/../rtl/pcs64_pkt_gen_mon_ds.v`）⇒ **`xxv_loop/pcs64_2ch/…synth_1/runme.log`（20:59）
> 里的 10 条指的是副本行号（:185…）**，而 `logs/s2_build_FINAL.txt:232-243`（20:26 那次）指的是
> 原件行号（:181…）。**两份日志指的是同 10 条、同一段代码**，只是行号差 4（见上表）。

### A.2 行级证据：CRC 到底覆盖了什么

以 **① 出厂原件**行号为准（`pcs64_pkt_gen_mon.v`）：

```
:1216  function [31:0] gen_CRC_const ( input integer n, input const_data );
:1219    for(i=0; i<(n*8); i=i+1) begin            ← 循环次数 = n*8（位），n 是**字节**数
:1220      if(i <= 111 ) loc_poly = ... eth_header[ crc_jiggle( 111 - i ) ] ...  ← 头部 112 bit
:1221      else                          loc_poly = ... const_data ...           ← 其余全是常量比特
:1225    for(i=0;i<=31;i=i+1) gen_CRC_const[i] = ~loc_poly[{i[3+:2],~i[0+:3]}];
:1030  localparam [31:0] PKT0_CRC = gen_CRC_const(pkt_len-4,1'b0);   ← n = 256-4 = 252
:1031  localparam [31:0] PKT1_CRC = gen_CRC_const(pkt_len-4,1'b1);
:1032  localparam [31:0] PKT3_CRC = gen_CRC3(pkt_len-4);
:186   assign insert_crc = 1'b0;                     ← 出厂默认**根本不插 FCS**
```

**覆盖了什么**：`crc_jiggle(d)={d[31:3],~d[2:0]}`（:1234-1235）把 `d∈[0,111]` **双射**到 `[0,111]`
⇒ 头部参与计算的正好是 `eth_header[111:0]` = `DA(6)+SA(6)+type(2) = 14 字节`（**不含前导** ✓）。
余下 `252×8 − 112 = 1904` **常量比特** = 238 字节。
⇒ **覆盖 = 14 头 + 238 常量 = 252 B**。

**应该覆盖多少**：由发帧 FSM 逐拍推出（见 A.3，且被板级 trace 逐字确认）——
一个包发 **32 个 XGMII 字**：`word0` = `/S/ + 6×55 + D5`（前导/SFD，`c=8'h01`），
`word1..word31` = 帧本体。**网卡按 DA 起算的帧 = 248 B**（与闸 2 的
`Δbytes/Δpackets = 248.000000` 逐字节吻合）⇒ 被 FCS 保护的部分 = `248 − 4 = **244 B**`（14 头 + 230 载荷）。

**⇒ 少算了什么 / 多算了什么**：不是"少算 pad"，而是**多算了 8 字节** ——
厂商用 `pkt_len − 4`，把 **word0 的"/S/ + 前导"字也当成了被保护数据**。
差值正好 **8 B = 一个前导字**。正确写法是 `pkt_len − 8 − 4 = 244`。
（等价说法：`CRC32(M244 || 0x00×8)` ≠ `CRC32(M244)`。）

### A.3 复算（本档核心证据）

- 脚本：`_proj_10g/notes/p7b_vendor_defects/fcs_recompute.py`（纯标准库，**逐位复现** `gen_CRC_const`，
  plus 逐拍复现发帧 FSM 的字节流）
- 输出：`_proj_10g/notes/p7b_vendor_defects/fcs_recompute_out.txt`
- **oracle = `zlib.crc32`**（与厂商 RTL 无任何共同代码；标准 CRC-32/ISO-HDLC）

**六条判据（全部实测通过，输出原文见上文件）**

| # | 判据 | 结果 |
|---|---|---|
| 1 | `RTL gen_CRC_const(244,0)` 的**上线四字节** == `zlib(M244)` 的小端 4 字节 | ✅ `7F 9E D8 D5` —— **这把"我的 RTL 模型"钉在标准 CRC-32 上** |
| 2 | `RTL gen_CRC_const(252,0)` 的上线四字节 == `zlib(M244 \|\| 0x00×8)` | ✅ `5F 3F DD 10` —— **厂商的 252 恰好 = 正确 244 后面又追加 8 个 0 字节** |
| 3 | FCS 上线序 == 小端（802.3 约定） | ✅（`== 大端` 为 False） |
| 4 | `crc32(M244 \|\| 正确 FCS)` == 标准残差常数 `0x2144DF1C` | ✅（**外部已知量**，独立确认） |
| 5 | `crc32(M244 \|\| 厂商 FCS)` == `0x2144DF1C`（网卡判 good 的条件） | ❌ `0xCFB5850F` ⇒ **每帧必判坏** |
| 6 | 几何复现 vs **板级 XGMII trace**（`P7B_GATE1.md:1085`） | ✅ **3/3 字 + "29 个全 0 字"逐位相同**（见下） |

**判据 6 的原始比对**（板级 trace 按 `d[63:0]` 打印，lane0 落在**最低**字节 = 我这边字节反转）：

```
板级 word0 = 64'hD5555555555555FB   vs 模型 = 0xD5555555555555FB   ✓
板级 word1 = 64'hFE14FFFFFFFFFFFF   vs 模型 = 0xFE14FFFFFFFFFFFF   ✓
板级 word2 = 64'h00000006829ADDB5   vs 模型 = 0x00000006829ADDB5   ✓
板级 "29 个全 0 字" (word3..31)     vs 模型 = 29 个字, 全 0         ✓
```

**与闸 2 实测的逐档对账**（把闸 2 §5 C-3 那条"没按期望翻转"解释掉）：

| 档 | FCS 字段（word31 lane4..7） | 整帧残差 | 网卡判 |
|---|---|---|---|
| (a) `insert_crc=0`（**出厂默认**） | `00 00 00 00` | `0x5ACD9360` | **坏** |
| (b) `insert_crc=1`（闸 2 的 v2 接成 VIO 可控） | `5F 3F DD 10` | `0xCFB5850F` | **坏** |
| (c) 假想修好（覆盖 244 B） | `7F 9E D8 D5` | `0x2144DF1C` ✓ | 好 |

⇒ **(a)(b) 都判坏，与闸 2 实测的"两档 `port_rx_good` 都 0、`rx_eth_crc_err` 都没变好"完全一致**。
⇒ 闸 2 的 A5/E5 结论（"帧级 FCS 不合规，根因在厂商 example 的 CRC 通路，不在 PCS"）**由长度论证升级为逐位复算**。

**三行可复现（不依赖我的脚本与模型）**：

```python
import zlib
M = bytes.fromhex('ff ff ff ff ff ff 14 fe b5 dd 9a 82 06 00') + bytes(230)  # 244 B
print(hex(zlib.crc32(M)), hex(zlib.crc32(M + bytes(8))))
# -> 0xd5d89e7f  0x10dd3f5f   ⇒ 上线小端 = 7f 9e d8 d5 (正确) / 5f 3f dd 10 (厂商)
```

### A.4 我们自己的 MAC 有没有同样的缺陷？—— **没有**（行级证据）

`_proj_10g/p7b_mac/rtl/mac_tx_10g.v`：

| 事实 | 行 | 说明 |
|---|---|---|
| 前导/SFD 是**独立的 XGMII 字**，且那一拍**不喂 CRC** | `:276-279`（`S_PRE: tx_d = {ETH_SFD, ETH_PRE_OCT×6, XGMII_S}; tx_c = 8'h01;`）<br>`:258-259`（`crc_en = (state==S_DATA) ? ... : (state==S_TAIL0) ? 1'b1 : 1'b0;` ⇒ **S_PRE 恒 0**） | 与厂商同样"前导占一个整字"，但**结构性地排除在 CRC 之外** —— 厂商的缺陷在这里**不可能发生** |
| CRC 输入只来自**帧内容 lane** | `:257`（`crc_d = (state==S_TAIL0) ? 64'd0 : (cw_data & cmask64(cw_len));`） | `cw_data` = 数据面的内容字；`:211-219` 的 `cmask64` 把 `tkeep` 之外的 lane 压 0（防止残值被当 pad 喂进 CRC） |
| keep 覆盖"内容 + pad"（**DEFECT #1 的修法**） | `:254-256` | `commit effef26` ④：修的是**另一笔**账（原来 pad 不进 FCS ⇒ 10G 下所有 <60 B 内容帧中招、自家 RX 拒收自家帧），与厂商这笔**方向相反**（厂商是多算，我们是曾少算） |
| 终值取反 + 小端上线 | `:229`（`lw_fcs`）· `:269`（`p0_fcs = crc_nxt ^ 32'hFFFFFFFF;`） | 与标准一致 |
| RX 侧判据用标准残差 | `mac_rx_10g.v:239`（`res_ok = b_last ? (crc == ETH_CRC_RESIDUE) : (crc_nxt == ETH_CRC_RESIDUE)`）· `:321`（`if(!res_ok) stat_crc_err <= +1`） | 我们的 RX 拿 802.3 残差当真值 ⇒ 若 TX 有厂商那种缺陷，自家 RX 立刻能抓到（这也是 #1 当初被发现的机制） |

⇒ **结构性结论**：厂商缺陷的成因是"把前导字算进覆盖长度"。我们的 MAC **没有**"把 pkt_len 当帧长"
这个概念（它按 `tkeep/cw_len` 计长，不靠一个常数），前导字所在状态 `S_PRE` 的 `crc_en` 恒 0 ⇒
**同一缺陷在我们的架构里无法表达**。`commit effef26` 修的是我们自己的 pad 覆盖缺陷（已修，方向相反）。

### A.5 处置建议：**不修**（附权衡）

**建议 = 不修厂商源码，只加档 + 加两道自有判据。**

| 选项 | 代价 | 收益 | 裁决 |
|---|---|---|---|
| ① 改 `pkt_len-4` → `pkt_len-12`（三处 n） | 要改 ②③ 两份板级副本；改完**闸 1/闸 2 的位流与其 RTL 之间不再逐字对应** | 让 example 的 FCS 合法 | ❌ **不做** |
| ② 只改 ① 出厂原件 | ① **从未被综合过**（板级用的是 ②③）⇒ 改了没人受益；还会让 `P7B_GATE1.md:647` 登记的那份 sha256 失效 | 无 | ❌ **不做** |
| ③ 只加档 + 冻结 + 自有判据 | 零 | 后来人 5 分钟读懂、且有正/负判据兜住 | ✅ **采纳** |

**为什么"不修"是安全的（三条）**：

1. **我们自己的通路不经过它**：闸 4 的验收判据是 `rx_eth_crc_err==0 且 port_rx_good>0`，
   而 10G 前端的帧由**我们自己的 `mac_tx_10g`** 产生（`build_p7b_ku5p.tcl` 只导入官方 **PCS 核**，
   **不导入 example 流量模块**）⇒ 厂商发生器只存在于闸 1/闸 2 的**历史位流**里，不在现役链路里。
2. **它在历史上只造成"激励不合法"，没有污染任何设计结论**：闸 1 的判据 = 厂商 FSM 的
   `completion_status[4:0]==1`（要求 `tx_sent_count==rx_packet_count`、`tx_total_bytes==rx_total_bytes`、
   错误计数为 0）+ **我们另加的独立 XGMII 内容检查器**（`P7B_GATE1.md` §2.2/§2.3）—— 两者都与 FCS 正交
   （`insert_crc=0` ⇒ FCS 字段恒 0、两端一致）；闸 2 的 PCS 裁决靠**逐帧长度/字节数/块锁/`/E/`**，
   同样与 FCS 正交 ⇒ **两笔板级读数都不因这个缺陷而失效**（`P7B_GATE2.md` §6.1 已按层裁决）。
3. **改它会让"原件可复现性"变差**（这正是本档必须写清的那条纪律）：闸 1/闸 2 的价值在于
   "板级读数 ↔ 未改一行的厂商明文源码"这条链；一旦动了 CRC 行，`P7B_GATE1.md:647` 的 sha256 溯源
   与两份板级副本的对应关系就断了，**下一个排查的人会失去唯一的对照件**。

**要补的两道判据（建议，未实施 —— 门归各自 owner）**：

- **负对照（防"厂商缺陷被当成我们的"）**：在自有门的 MAC 侧加一条"FCS 由**独立** zlib 复算"的断言
  —— 现在 `mac_rx_10g` 有残差判据，但**TX 侧没有独立 oracle**；补上后，任何"覆盖长度算错"
  （无论多算 8 B 还是少算 pad）都会在仿真里立刻暴露，而不是等到真网卡的 `rx_eth_crc_err`。
- **冻结断言（防有人手滑改了厂商文件）**：在门里对 `pcs64_pkt_gen_mon*.v` 的
  `gen_CRC_const(pkt_len-4` 这一行做**文本断言**（期望"命中"），命中即"未被动过"；
  若哪天有人真去修了它，断言会**反向报警**，逼他同时更新本档与本文件的 sha256。

---

## 2. 任务 B —— 10 条 `Synth 8-11241`

### B.1 事实：日志路径 + 10 条原文（逐条）

**日志路径（四处独立留存；注意它们分属两次不同的构建）**：

| 日志 | 行 | 是哪次构建 / 指向哪份副本 |
|---|---|---|
| `_proj_10g/xxv_loop/logs/s2_build_FINAL.txt` | **:232-243** | **闸 1 验收构建**（09-29 20:17→20:23，`S2 DONE`）；指向**出厂原件**（`…/imports/pcs64_pkt_gen_mon.v:181…`） |
| `_proj_10g/xxv_loop/pcs64_2ch/pcs64_2ch.runs/synth_1/runme.log` | **:28-39** | 同工程**后续**构建（20:59，48 探针位流那版）；指向 `_ds` 副本（`:185…`） |
| `_proj_10g/xxv_gate2/v2/logs/s2_g2_stdout.txt` | :255-266 | 闸 2 构建；指向 `_g2` 副本（`:186…`）；`:1696` 有 `S2_GREP … <8-11241> = 10` |
| `_proj_10g/p7b_mac_synth/xxv_mac/pcs64_2ch/pcs64_2ch.runs/synth_1/runme.log` | :28-39 | MAC 合并实验工程；指向 `_ds` 副本 |

⚠️ **两份 `xxv_loop` 日志各含 10 条，指向同 10 条代码**（行号差 4，见 A.1 的偏移表）—— **不是 20 条**。

**10 条原文（符号 + 文件 + 行；行号取**出厂原件** `…/xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_pkt_gen_mon.v`）**

| # | 符号 | 出厂原件行 | `_ds` / `_g2` 行 | 所在模块（出厂原件） |
|---|---|---|---|---|
| 1 | `stat_rx_status` | :181 | :185 / :186 | `pcs64_pkt_gen_mon`(63-445) |
| 2 | `clear_count` | :185 | :189 / :190 | 同上 |
| 3 | `rx_protocol_error` | :421 | :426 / :427 | 同上 |
| 4 | `rx_mii_clk` | :573 | :581 / :582 | `pcs64_mii_traffic_gen_mon`(495-677) |
| 5 | `ctl_tx_enable` | :982 | :992 / :993 | `pcs64_mii_pkt_gen`(926-1243) |
| 6 | `ctl_local_loopback` | :990 | :1000 / :1001 | 同上 |
| 7 | `ctl_FEC_Enable_Error_to_PCS` | :991 | :1001 / :1002 | 同上 |
| 8 | `ctl_FEC_TX_Enable` | :992 | :1002 / :1003 | 同上 |
| 9 | `ctl_FEC_RX_Enable` | :1324 | :1334 / :1335 | `pcs64_mii_traf_chk`(1244-1469) |
| 10 | `ctl_rx_test_pattern_select` | :1329 | :1339 / :1340 | 同上 |

原文样例（`synth_1/runme.log:28`，其余 9 条同格式）：

```
INFO: [Synth 8-11241] undeclared symbol 'stat_rx_status', assumed default net type 'wire'
      [D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_loop/rtl/pcs64_pkt_gen_mon_ds.v:185]
```

⚠️ **不是加密网表** —— 这 10 条所在文件是**明文**（加密的只有 `xxv_ethernet` 核本身），
所以下节的判定**是从源码判的，不是"无法判定"**。

### B.2 定论：有没有实际功能影响？—— **没有**（逐条）

Verilog 的规则是确定的：`undeclared symbol` ⇒ 隐式创建一个**恰好 1 位**的 wire。
所以判定只需两问：**它连到谁（对方多宽）** + **它有没有消费者**。

| # | 符号 | 驱动 | 消费者（行 / 端口宽） | 截断? | 判定 |
|---|---|---|---|---|---|
| 1 | `stat_rx_status` | `assign … = stat_rx_block_lock_sync`（1 位） | `pcs64_example_fsm` 的 `input wire stat_rx_status`（:687，**1 位**），在 :860/:876/:891 用 | **不可能** | **无影响**（值正确送达，等效于补上声明） |
| 2 | `clear_count` | `assign … = 1'b0` | `pcs64_mii_traffic_gen_mon` 的 `input wire clear_count`（:510，1 位）→ 再下传 :619/:661 → `pcs64_mii_traf_chk`(:1249)/`traf_gen_chk`(:1475)（均 1 位），在 :1403/:1586 用 | **不可能** | **无影响**（0 正确送达） |
| 3 | `rx_protocol_error` | **被驱动**：来自子模块 `pcs64_mii_traffic_gen_mon` 的 `output wire rx_protocol_error`（:554，1 位；其内部由 `pcs64_mii_traf_chk.protocol_error`（:1275 `output reg`）在 :643 汇入） | 在 `pcs64_pkt_gen_mon` 里**只有 :421 一处** ⇒ **悬空输出，无消费者** | 不适用 | **无影响**（值被算出来然后丢掉） |
| 4 | `rx_mii_clk` | `assign rx_mii_clk = rx_clk;`（:573） | **全文件仅此一处** ⇒ **死网** | 不适用 | **无影响**（纯死代码；该模块没有 `rx_mii_clk` 端口） |
| 5 | `ctl_tx_enable` | `assign … = 1'b1`（:982） | **全文件仅此一处** ⇒ **死网** | 不适用 | **无影响**（⚠️ 但**意图被静默丢弃**，见下注） |
| 6 | `ctl_local_loopback` | `assign … = 1'b1`（:990） | **全文件仅此一处** ⇒ **死网** | 不适用 | **无影响**（⚠️ 同上：**它并没有真的打开 GT 本地环回**） |
| 7 | `ctl_FEC_Enable_Error_to_PCS` | `assign … = 'd0`（:991） | 仅此一处 ⇒ **死网** | 不适用 | **无影响** |
| 8 | `ctl_FEC_TX_Enable` | `assign … = 'd0`（:992） | 仅此一处 ⇒ **死网** | 不适用 | **无影响** |
| 9 | `ctl_FEC_RX_Enable` | `assign … = 1'b0`（:1324） | 仅此一处 ⇒ **死网** | 不适用 | **无影响** |
| 10 | `ctl_rx_test_pattern_select` | `assign … = 1'b0`（:1329） | 仅此一处 ⇒ **死网** | 不适用 | **无影响**（注意同模块的 `ctl_rx_data_pattern_select` 是**真端口**，两者只差一个词） |

> ⚠️ **一个值得登记的"静默意图丢失"（不是本 10 条的功能 bug，但是踩点）**：
> `assign ctl_local_loopback = 1'b1;` 看着像"厂商 example 默认打开本地环回"，
> **实际是死网** —— 它既不是 `pcs64_mii_pkt_gen` 的端口，也没有被任何父层引用（全仓 grep 只有这一行）。
> ⇒ 谁想照抄 example 做自环，**照着这行是拿不到环回的**；我们闸 1 的内环是**我们自己用 VIO 拉起来的**
> （`P7B_GATE1.md` §10 的 `vio_gt_loopback`）。同一现象也解释了 #5/#7/#8 —— 那 4 行都是"想驱动 PCS 控制脚、但名字不在端口表里"。

**⇒ 结论：这 10 条一个都不影响功能。** 3 条宽度天然一致；7 条压根没有消费者。
**不能**说"因为是 1 位隐式网所以一定截断了" —— 截断需要消费者比 1 位宽，这里**不存在**这种情况。

### B.3 现状核实：p7b 构建里这 10 条**根本没有被打印**（⇒ bat 不会误伤）

| 检查 | 结果 | 证据 |
|---|---|---|
| `build_p7b_ku5p.tcl` 是否导入 example 流量模块？ | **否** —— 只 `create_ip xxv_ethernet`（取 PCS 核）+ 导入我们自己的 `_proj_10g/p7b_mac/rtl/` | `board/build_p7b_ku5p.tcl` 的 `P7B_ADD_MAC` / `P7B_IP_CREATE` 两节（全文只有这两处引入 IP） |
| `board/p7b_ku5p_stdout.txt`（**HEAD 里那份完整构建，2026-09-30 01:47，`P7B_BIT_EXISTS=1`**） | 五键**全 0 命中**（`Synth 8-11241` / `undeclared symbol` / `VRFC 10-3091` / `10-2989` / `implicitly declared`） | `git show HEAD:board/p7b_ku5p_stdout.txt \| grep -c …` 逐键实测 = 0 |
| 顶层综合 `p7b_ku5p_prj.runs/synth_1/runme.log` | 四键 0 命中（我们自己的 RTL **0 条**） | 实测（该文件是**正在跑的构建**在写，读数带此时间戳口径） |
| ⇒ **bat 的 `IMPLICIT-NET-FAIL` 分支不会触发** | ✅ 不误伤 | `board/run_build_p7b_ku5p.bat` 第 2 条 `findstr` |

**但发现两个真问题（都不是"误伤"，是"覆盖面"）：**

1. ⚠️ **`8-11241` 的同族 28 条落在 bat 的 grep 面之外**：
   `vivado_prj/p7b_ku5p_prj.runs/pcs64_synth_1/runme.log`（**IP 的 OOC 综合 run**）里有 **28 条**，
   **全部来自厂商生成的 `…/ip/pcs64/xxv_ethernet_v5_0_2/pcs64_wrapper.v`**：
   `gtwiz_reset_qpll{0,1}reset_out` · `gtwiz_reset_qpll{0,1}lock_in` · `qpll{0,1}clk_in` ·
   `qpll{0,1}refclk_in` · `drprst_in` · `gt_txusrclk2` · `gt_rxusrclk2`（各 ×2 核 + `_0`/`_1` 后缀变体 = 28）。
   它们**同族、同为 1 位 ↔ 1 位**（`pcs64_gt.v:148` 是 `input wire [0:0] qpll0clk_in`），
   且设计**板级已验收**（QPLL0 锁在 10.3125 GHz、P7a BER < 5e-13）⇒ **实际无影响**；
   但**bat 只 grep 自己的 stdout，永远看不到这份日志**。
   （前一轮的语料普查已登记过同类：`P7B_IMPLICIT_GATE_ROLLOUT.md` §8.3 + `logs/final_scan.txt:16-31`。）
2. ⚠️ **该 bat 命中后不置退出码**：`run_build_p7b_ku5p.bat` 的三条硬门
   （`DROPPED-CONSTRAINT-FAIL` / `IMPLICIT-NET-FAIL` / `DRC-KEY-FAIL`）都是
   `findstr … && (echo X-FAIL & findstr …)` —— **没有 `exit /b 1`**，脚本末尾仍是
   `if not exist …bit (exit /b 1)` + `echo BITSTREAM-OK & exit /b 0`。
   ⇒ **命中只留一行 banner，退出码仍由"位流是否存在"决定**。
   对照：`board/run_lint_p6e.bat` 是 `echo IMPLICIT-DECL-FAIL & … & **exit /b 1**`（真硬失败）。
   ⇒ 若自动化只看 `%ERRORLEVEL%`，**p7b 这三条门结构性地不会失败**（需按 banner 判，或改成 exit 1）。

### B.4 处置建议

**建议：键保留（**不要**因为厂商代码而放宽关键字），把例外做成"已登记清单"，并补上覆盖面。**

| 动作 | 理由 |
|---|---|
| ✅ **保留 5 键硬门** | 键本身没错：语料级假阳性 0（`P7B_IMPLICIT_GATE_FIX.md` 干净件对照），且它抓过真阳性（`pay_sel` 漏声明 / `tb_p5_app.v` 的 `tx_fsm_state_w`） |
| ✅ **例外按 (文件, 符号) 登记，而不是按文件整类豁免** | 10 条的**具体清单已在本档 B.1/B.2**（含符号名+行号+判定）⇒ 门可断言"命中项必须 ⊆ 已登记清单"，**新出现的符号仍然硬失败**。整类豁免会把这个洞重新打开 |
| ✅ **把 grep 面扩到 `*.runs/*_synth_1/runme.log`**（含 IP 的 OOC run） | 否则 28 条同族永远不可见（B.3-1）。扩面后同样按"已登记清单"过滤 ⇒ 既不误伤也不漏 |
| ✅ **把 p7b 三条门从 banner 改成 `exit /b 1`** | 否则"硬门"在 exit code 层面不存在（B.3-2）。注意 `board/` 归构建 owner，本档只建议 |
| ❌ **不修厂商源码** | 与 A.5 同理：`pcs64_pkt_gen_mon*.v` 是闸 1/闸 2 的**冻结对照件**；这 10 条既无功能影响，修它只会破坏可复现性 |

---

## 3. 未核实清单（不得当结论用）

| # | 事项 | 现状 |
|---|---|---|
| U1 | 10 条的**网表级**证据（综合后网表里这些网是否真的被优化掉） | 本轮**只做了源码级判定**。理由：源码是明文、语义确定（隐式网 = 1 位、无消费者 = 无扇出），**判定的充分性不需要网表**。若要与网表对拍，可在 **不跑综合**的前提下读 `…runs/synth_1/*.vds`（本轮未做，避免与正在跑的构建抢资源） |
| U2 | `insert_crc=1` 在**硅上**是否真的生效（闸 2 的 U2） | 本轮仍未直接读到探针；但复算 + 闸 2 的 `badpay` 弱证据方向一致 |
| U3 | 闸 2 的 `crc_en=1` 档是否**确实发到了网卡**（而不是只在环回里生效） | 未重测（属闸 2/闸 4 范围） |
| U4 | p7b 构建的 stdout 读数 | 该文件**正被另一个 agent 的构建写入**；本档引用的 `0 命中` 以 **git HEAD 里那份完整构建（01:47，`P7B_BIT_EXISTS=1`）** 为准，另有当前版本一致为 0 |

---

## 4. 本档新增文件（只此三处，均为本 agent 独占路径）

| 文件 | 内容 |
|---|---|
| `_proj_10g/notes/P7B_VENDOR_EXAMPLE_DEFECTS.md` | 本档 |
| `_proj_10g/notes/p7b_vendor_defects/fcs_recompute.py` | 逐位复现 `gen_CRC_const` + 逐拍复现发帧 FSM 的复算脚本（纯标准库） |
| `_proj_10g/notes/p7b_vendor_defects/fcs_recompute_out.txt` | 脚本输出（六条判据 + 板级 trace 比对 + 三档残差表） |

**复现命令**（任选，python 均为 anaconda）：

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g/_proj_10g/notes/p7b_vendor_defects
PYTHONIOENCODING=utf-8 /c/Users/zhxue/anaconda3/python.exe fcs_recompute.py
```

---

## 5. 给后来人的 30 秒版

1. **要照抄厂商 example 的发生器，先知道它的 FCS 是错的**（覆盖多算 8 B = 前导字；出厂还默认不插 FCS）。
   缺陷位置：`pcs64_pkt_gen_mon*.v` 的 `gen_CRC_const(pkt_len-4, …)` 三行。**我们自己的 `mac_tx_10g` 没有这个问题。**
2. **看到那 10 条 `Synth 8-11241` 不用慌**：全在厂商 example 里，3 条宽度天然一致、7 条是死网。
   但它里面 `assign ctl_local_loopback = 1'b1;` 是**死的** —— 别指望照着它拿到 GT 环回。
3. **p7b 构建的"隐式网硬门"目前是 banner 不是退出码，且看不到 IP 的 OOC run 日志**（那里有同族 28 条）。
