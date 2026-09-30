# P7b 闸 4 工具修复第二轮 (fix2) —— 首次上板暴露的三处缺陷

- 日期：**2026-09-30**（工具轮；**未烧板、未重启对端机、未改 RTL/XDC/构建脚本、未 `git add|commit`**）
- 范围：只改**验收工具**（`_proj_pcie/*.sh`）与 **runbook**（`P7B_GATE4_PLAN.md`），只写本文件与
  `p7b_gate4_tools/fix2/**`（文件所有权互斥，见 §6）
- 上游：`P7B_GATE4_ACCEPT.md` §4/§7（执行方**如实报了 3 个缺陷、没有擅自改脚本**）+ `P7B_GATE4_TOOLING.md`（上一轮）

**一句话**：三处都已就地修好，**每一处都有"真跑过"的负对照**（不是"按构造它会失败"）；
三套自证/回归合计 **negctrl 15/0 · livefake 26/0 · snapcheck-selftest 19/0**，原始件都在 `p7b_gate4_tools/fix2/`。

| # | 缺陷（首轮上报） | 结论 | 证据（真跑） |
|---|---|---|---|
| ① | runbook 的 `TX_DIS` 寄存器地址写成 `0x10`（= **只读** `HW_STATUS`） | ✅ 改成 **`0x08`**；并把"按它跑会得到**假故障**"的机理写进 runbook | 源码 4 处 + **单元门 `PASS_ALL` 22/22** + 板级原始件 `live/negctrl_TXDIS.txt` |
| ②a | `p7b_gate4_accept.sh` **live 模式永远只取 1 块快照** ⇒ G2/G3/C 组/B_G6/N_XCHK **全被 SKIP** | ✅ 改成**按判据需要取多块**（live 全链 4 块 / 停机档 2 块） | 假对端台架：取块数 **4 / 2**；`[PASS] G2-W5/W24/W50`、`B_CONS-a`、`C1-C5`、`C8`、`B_G6` 全部**不再 SKIP** |
| ②b | 激励命令**裸绝对路径被 MSYS 改写** ⇒ **激励静默没跑**，而 NIC 判据照常打 FAIL | ✅ 远端命令**无条件**前置 `true; ` + **回显命令与退出码** + 新判据 **`T_RUN`** | 同一输入下：**旧版**假对端收到 `C:/Program Files/Git/home/a/...`（`rawabs_old.calls:5`）、**新版**收到**原样路径**（`rawabs_new.calls:5`） |
| ②c | Windows Python 的 stdout 把远程 LF 翻成 **CRLF** ⇒ 前置闸 **ABORT (退出 2)** | ✅ 绕过手段（`tr -d '\r'`）**收进脚本本体**，不再依赖调用者 `PY=` 注入 | 同一假对端（真 CRLF）：**旧版退出码 2 + "不是 0x 十六进制"**；**新版不 ABORT 且 G1 PASS** |
| ③ | `p6e_snap_check.sh` 的 `freq_check()` **度量伪影**（陈旧锁存值 + 本次时间戳 ⇒ 371/293 MHz 伪 FAIL） | ✅ 改成**每次读数都自证是新一代**（触发 → `gen` 恰好 +1 → 再取时间戳/读数） | 假板子（真锁存语义）：**旧版报 312.5120 MHz = 恰 2× 标称**；**新版报 156.2500 MHz**；陈旧值/gens 不增两个反例都被抓住 |

---

## 1. ① runbook 的 `TX_DIS` 地址：`0x10` → `0x08`

**原文**（`P7B_GATE4_PLAN.md` §步骤 6.1，逐字）：

```bash
# 6.1 ⭐ N-a 决定性一刀: 拉高被连通道的 TX_DIS ⇒ 网卡**必须**掉 carrier
#     (sfp2_tx_dis = pcie_scratch[1], 复位值 0 = 发射开; 写 0x10 的 bit1)
   \$T/reg_rw /dev/xdma0_user 0x10 w 0x2 >/dev/null; sleep 2; \
```

**改成什么**：`0x08`（两处：拉高段与恢复段），并补三条：① 机理（`0x10` 是**只读** `HW_STATUS`，
写进去**不落地**、`carrier` 纹丝不动 ⇒ 按旧版跑得到的是**"负对照不翻转"的假故障**）；
② **写后读回** `0x08` 自证写入落地；③ 成因留档（见下"未改的那一处"）。

**依据（逐条可复核）**：

| 引用 | 内容 | 说明 |
|---|---|---|
| `_proj_pcie/rtl/axi_regs.v:151` | `if (w_word == 6'd2) begin  // 0x08 SCRATCH (RW)` | **写通道只认 word 2 = `0x08`** |
| `_proj_pcie/rtl/axi_regs.v:159-161` | `end else begin  s_axil_bresp <= 2'b10; // SLVERR` | **其余地址的写一律 SLVERR**（含 `0x10`）⇒ 对 `0x10` 的写根本不落地 |
| `_proj_pcie/rtl/axi_regs.v:240` | `6'd2: rdata_mux = scratch;` | 读 mux：`0x08` = word 2 = scratch |
| `_proj_pcie/rtl/axi_regs.v:242` | `6'd4: rdata_mux = hw_status;` | `0x10` = word 4 = **只读** `HW_STATUS` |
| `board/wrapper_p4.v:3723` | `.scratch (pcie_scratch)` | `axi_regs` 的 scratch 端口 = `pcie_scratch` |
| `board/wrapper_p4.v:3691-3692` | `assign sfp1_tx_dis = pcie_scratch[0]; assign sfp2_tx_dis = pcie_scratch[1];` | 被连通道（J8/SFP B/X0Y5）= `pcie_scratch[1]` ⇒ 写 `0x2` |

**怎么证明改对了**（三层，都不需要新烧板）：

1. **RTL 级（新跑，2026-09-30）**：跑现成的单元门 `_proj_pcie/run_tb_axi_regs.bat`（纯仿真，非综合）
   ⇒ **`PASS_ALL  tb_axi_regs: 22 项判据全过`**、退出码 **0**（原始件
   `fix2/tb_axi_regs_stdout.txt`）。其中直接相关的两条：
   - 判据 **`3b SCRATCH 读回 = a5a55a5a`** ⇒ `0x08` 确实可读写；
   - 判据 **`8 HW_STATUS = 00000005`** ⇒ `0x10` 回的是**另一个**只读值（≠ scratch）。
   （该日志是 cmd 控制台的 **GBK** 编码，`grep` 中文会乱码，按值/判据号检索即可。）
2. **板级（首轮原始件，未重跑）**：`live/negctrl_TXDIS.txt`
   —— `scratch_readback=0x00000002` 且 `carrier 1→0`、`carrier_changes 1→2`、`operstate=down`；
   写回 `0x0` 后 `carrier 0→1`、`carrier_up_count→2`。**同一个文件同时记着 `0x10` 那一段纹丝不动。**
3. **反证**：`AXI` 写 `0x10` 会拿到 `SLVERR`（`axi_regs.v:159-161`）⇒ 若哪一天"写 0x10 也翻转了"，
   先怀疑译码被改宽，而不是"地址本来就对"。

**⚠️ 未改的那一处（不在本 agent 的文件所有权内，留给该文件的所有者）**：
`board/wrapper_p4.v:3686` 的注释写的是 "`pcie_scratch[1:0]` 由主机写 (**0x10**)" —— **这句注释本身就是错的**
（runbook 的错值就是从这里抄来的）。建议改成 `0x08`，并在旁边点一句 `_proj_pcie/rtl/axi_regs.v:151` 的依据。

**runbook 里同批订正的另外三处**（都属于"判据的期望值/命令与现实脱钩"，与 ① 同族）：

| 位置 | 原文 | 订正 | 依据 |
|---|---|---|---|
| 步骤 4 判据 G2 | 前端域标称 **125** | **156.25** | P7B_10G 构建里前端域 = PCS 的 CDR 恢复钟（`board/wrapper_p4.v:658-659`）；板级独立两点实测 156.1986 MHz（`P7B_GATE4_ACCEPT.md` §3.3） |
| 步骤 4 判据 G2 / W50 表行 | "频率 = 值/**2**"（÷2） | ÷**1** | RTL 每拍翻转一次（`wrapper_p4.v:3387-3400`）；板级实测 155.8406 MHz@÷1（−0.262%）—— 旧"÷2 命中"是 ③ 的同一个 2 倍伪影 |
| 步骤 5.3 / 6.2 的手工打流命令 | `"/home/a/xdma_test/p6e_udp_pattern …"` | `"cd /home/a/xdma_test && ./p6e_udp_pattern …"` | 与 ②b **同一个 MSYS 改写**：runbook 自己的命令也会**静默不执行**（实测见 §2b） |

---

## 2. ② `_proj_pcie/p7b_gate4_accept.sh` 三处 live 路径缺陷

### (a) live 模式永远只取一块快照 ⇒ G2/G3/C 组/B_G6/N_XCHK 全被 SKIP

**原文**（旧 `:350`，逐字）：

```bash
local nsf=1; [ -n "${G4_SNAP_TEXT:-}" ] && nsf=$(count_items "$G4_SNAP_TEXT")
...
if [ "$nsf" -lt 2 ]; then echo "  [SKIP] 只给了一块快照 ⇒ 频率/守恒/增量判据全部无法判 (需要两点)"
```
live 模式下 `G4_SNAP_TEXT` 未设 ⇒ **`nsf` 恒 1** ⇒ 第二块快照（"块 B"）**不可达** ⇒
G2 频率 / G3 守恒方向 / C 组 PCS / C8 / N_XCHK / B_G6 **在 live 档全部被 SKIP**
（首轮真板日志里那句 `[SKIP] 只给了一块快照` 就是它）。

**改成什么**：**判据要几点就取几点** ——

```bash
if [ "$OFFLINE" = 1 ]; then nsf=$(count_items "$G4_SNAP_TEXT")   # 离线: 与既有负对照口径一致
else nsf=2; [ "$G4_SKIP_TRAFFIC" = "1" ] || nsf=4; fi           # live: 停机两点 (+ 打流后洪泛两点)
```
并抽出 `snap_block <n> <落盘路径>`（live 真取、第 2 块起先等 5 s；离线仍从逗号列表取），
块 A/B/C/D 的解析与判据顺序**一字未改**（`check_freq`/`check_cons`/`check_pcs`/`check_evt`/`B_G6`/`N_XCHK`）。

**依据**：`P7B_SPEC.md §6.1` 的 **G2**（"每轮触发自证：gen 恰好 +1；无空读"）、**G3**（"频率类判据窗口 < 20 s"）、
**C9**（"三个新域的 32 位自由计数在涨，Δ/墙钟 = 标称 ±1%"）都是**逐字判据**，靠单块读数**结构上判不了**。

**怎么证明改对了**（`fix2/livefake/`，假工程树 + 假对端，**真跑**）：

- 全链档：假对端收到 **4** 次快照调用（`full.calls` 里 `SNAP_BEGIN` 计数 = 4），
  汇总 **`PASS=26 FAIL=0 SKIP=0`**、退出码 **0**（`full.log`），其中
  `[PASS] G2-W5` / `G2-W24` / `G2-W50` / `B_CONS-a` / `C1-C5` / `C8` / `B_G6` **全部实跑通过**；
- 停机档（`G4_SKIP_TRAFFIC=1`）：**2** 次快照，`[PASS] G2-W5` 仍跑（旧版这里是 SKIP），
  汇总 `PASS=17 FAIL=0 SKIP=1`（唯一 SKIP = N_RATE 按设计不跑）。

### (b) 激励命令裸绝对路径被 MSYS 改写 ⇒ 激励静默没跑

**原文**（旧 `:57` + `:435`）：

```bash
G4_TRAFFIC_CMD=${G4_TRAFFIC_CMD:-/home/a/xdma_test/p6e_udp_pattern --secs $TRAFFIC_SECS …}
peer --timeout 180 "$G4_TRAFFIC_CMD" || echo "  [WARN] 图案工具退出码非 0 …"
```

**机制（实测复现，原始件 `fix2/msys_pathconv_repro.txt`）**：Git Bash/MSYS 会把传给**原生 Windows exe**
（这里是 `python.exe`）的参数做 POSIX→Windows 改写 —— `/home/...` ⇒ `C:/Program Files/Git/home/...`
⇒ 远端 `bash: line 1: C:/Program: No such file or directory` ⇒ **激励静默没跑**；
而下游 NIC 判据**照常打 FAIL** ⇒ **看着像板子坏了**（首轮 `stage3` 日志正是这个形态）。

**改成什么**（三层，缺一层都不够）：

1. `run_traffic()` 把激励包成远端脚本，**无条件**前置一个 `true; `（bash 空操作）——
   整串因此**不以 `/` 开头** ⇒ 改写规则不触发 ⇒ **任何**激励命令（含裸绝对路径）都能原样送达；
   调用者**不需要**改自己的命令。（默认值也顺手改成 `cd … && ./…` 形态，双保险。）
2. **回显 + 退出码**：远端 `printf 'TRAFFIC_CMD <%s>\n' '<cmd>'` + `echo TRAFFIC_RC=$?`
   ⇒ 日志里留下"**远端到底执行了什么**"的原始凭证（人可复核）。
3. **新判据 `T_RUN`**：`TRAFFIC_BEGIN/END/RC` 三行缺任一行 ⇒ FAIL 并明写
   "**激励没跑** ⇒ 下面任何 NIC FAIL **不是板子的结论**"；RC 非 0 时点名"**先怀疑激励侧**"。
   （`G4_TRAFFIC_CMD` 含单引号会破坏远端引用 ⇒ 显式 `fatal`，不静默。）

**怎么证明改对了**（同一输入、同一台架，**新旧对照**）：

| 观测点 | 旧版 | 新版 |
|---|---|---|
| 假对端**收到的**激励命令 | `C:/Program Files/Git/home/a/xdma_test/p6e_udp_pattern --secs 3 …`（`rawabs_old.calls:5`） | `/home/a/xdma_test/p6e_udp_pattern --secs 3 …`（`rawabs_new.calls:5`，**逐字原样**） |
| 远端回显 + 退出码 | 旧版无此判据 | `[PASS] T_RUN … 远端实收命令=</home/a/…>`（`rawabs_new.log:33`） |
| NIC 侧 | `[FAIL] N_RATE`（**激励根本没跑**） | `[PASS] N_RATE`（激励真送达 ⇒ NIC 计数才涨） |
| 反例（命令不可执行） | —— | `[FAIL] T_RUN … TRAFFIC_RC=127 … 先怀疑激励侧`（`noexec.log`） |

### (c) CRLF 必须收进脚本本体（不再靠调用者记得注入 `PY=py_nocrlf.sh`）

**原文**（旧 `:93`）：`peer(){ PYTHONIOENCODING=utf-8 "$PY" "$ROOT/tools/peer_ssh.py" "$@"; }`

**机制**：`peer_ssh.py` 跑在 **Windows Python** 上，stdout 是 `newline=None` 的 TextIOWrapper
⇒ 写 `\n` 被翻成 `os.linesep = "\r\n"`，而它搬运的是**远程 Linux 的原始输出（LF）**
⇒ `parse_snap` 的严格正则 `^0[xX][0-9a-fA-F]{1,8}$` 不匹配（值尾多一个 `\r`）⇒ **前置闸 ABORT（退出 2）**。
首轮执行方是**用 `PY=py_nocrlf.sh` 注入绕过**的 —— 那是"靠人记得"，迟早再踩。

**改成什么**：

```bash
peer(){ PYTHONIOENCODING=utf-8 "$PY" "$ROOT/tools/peer_ssh.py" "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
```
`PIPESTATUS[0]` **保住远端退出码**（调用点用 `|| fatal` / `|| echo WARN` 判成败，不能被管道吃掉）；
解析层再补一道 `k=${k%$'\r'}` 兜底（万一还有别的 CRLF 源）。
⭐ 这里**故意不关掉 MSYS 路径转换**（`MSYS_NO_PATHCONV=1` 那种全局开关）：`$ROOT/tools/peer_ssh.py`
自己是 `/d/...` 形态、正需要被转成 `D:/...` 才能被 python.exe 打开 —— 关掉就换这里坏。

**怎么证明改对了**（同一假对端，**它吐的是真 CRLF**，由真 Windows Python 的 TextIOWrapper 产生）：

| 观测点 | 旧版（不注入） | 新版（不注入） |
|---|---|---|
| 退出码 | **2（ABORT）** | 0（全链档） |
| 日志 | `[FATAL] 快照块 A 解析: W0 的读数是 '0x…' (不是 0x 十六进制 …)` | `[PASS] G1 …`、无 `[ABORT]` |

---

## 3. ③ `_proj_pcie/p6e_snap_check.sh` 的 `freq_check()` 度量伪影

**原文**（旧 `:143-159`，逐字）：

```bash
  a=$(rd "$(snap_addr $wi)"); t1=$(date +%s.%N)      # ← a 是**上一次触发**锁存的陈旧值
  ...
  snap_take || ...                                    # ← 到这才触发
  b=$(rd "$(snap_addr $wi)"); t2=$(date +%s.%N)
  d=$(( (b - a) % W32 )); dt = t2 - t1; f = d/div/dt
```

**为什么是伪影**：快照字**只在触发时刷新** ⇒ `a` 是**上一代**的锁存值，而 `t1` 记在**本次触发之前**
⇒ **分子量的是 `[上一次锁存 → 本次锁存]`，分母量的是 `[t1, t2]` —— 两个不同的区间**。
真板实测（`live/snap_check_halt.txt`）：**W5 报 371.0421 MHz（Δ=2,114,940 / 0.0057 s）**、
**W24 报 293.5776 MHz**，两者都超过标称 2 倍 ⇒ 两条 `[FAIL]` 是**度量伪影**；
同一个 2 倍偏差还把 W50 的 ÷1/÷2 口径误判成"**÷2 命中**"（首轮靠独立两点测量才把口径钉死为 ÷1）。
⚠️ 这正是本工程 `fpga_net_dev.md` **第 27 条**（"台架会安静地拿一个值和它自己比"）的同族：
**"前后对比"在解读之前，先证明两次读的确实是两批数据。**

**改成什么**（`_proj_pcie/p6e_snap_check.sh`，就地改）：

```bash
snap_take_gen(){   # 触发 → 等 done → **断言 gen 恰好 +1**（0=成功 1=done 不置 2=gen 不是 +1）
  g0=$(rd 0x1c); wr 0x18 0x1; …轮询 done…; g1=$(rd 0x1c)
  [ $(( (g1-g0+65536)%65536 )) -eq 1 ] || { GEN_ERR="…⇒ 这一代不是本进程触发的 ⇒ 读数不可归因"; return 2; }
}
snap_pair(){       # 取一对**各自自证**的读数: 每点都 snap_take_gen, 再取时间戳并读数
  snap_take_gen || return 1; t1=$(date +%s.%N); v1=$(rd 字); t2=$(date +%s.%N); …sleep gap…
  snap_take_gen || return 1; h1=$(date +%s.%N); v2=$(rd 字); h2=$(date +%s.%N); …
}
```
外加两条守卫：
- **时间戳取"读数前后两次 `date` 的中点"** —— 两点走的是同一段代码 ⇒ 系统偏差对消；
- **判据不许在台架噪声上出结论**：`读数时间戳半宽 / 窗口 > 0.5%` ⇒ 打 **SKIP + 原因**
  （"频差被台架自身的抖动主导"），**不给假 FAIL**（真板上是 ~ms/5s = 0.1%，远低于门槛）。
同批订正 `W5_NOM`（默认 **156.25**；P6b 位流 `W5_NOM=125` 覆盖）与 `SNAP_FREQ_GAP`（默认 5 s）。

**依据**：`P7B_SPEC.md §6.1` **G2**（gen 恰好 +1）/ **G3**（窗口 < 20 s）；
`board/wrapper_p4.v:658-659`（前端域 = PCS 恢复钟 ⇒ 标称 156.25）。

**怎么证明改对了**（`_proj_pcie/p6e_snap_selftest_fix2.sh` + `fix2/selftest_*.log`，**真跑**，合计 **OK=19 BAD=0**）：

| case | 假板子 | 期望 / 实测 |
|---|---|---|
| ① `good`（正对照） | 真锁存语义，自由计数=156.25 MHz | **旧版对照 ④ 报 `⇒ 312.5120 MHz`（恰 2×，并把 W50 判成"÷2 命中"）**；**新版 `⇒ 156.2500 MHz`、W50 **÷1** 命中、整脚本 `FAIL=0`、退出码 0** |
| ② `genstuck`（**该被抓住**：触发不增 gen） | 字仍刷新，但 gen 不动 | 新版：`[FAIL] … gen 不是恰好 +1 (…) ⇒ 读数不可归因` + `取不到 **自证新一代** 的一对读数`，**不打印任何频率**、退出码非 0；**旧版在同一块板上照样报出一个频率**（对照点） |
| ③ `stale`（**该被抓住**：合成一个陈旧值） | 字被冻结 | 新版：`0.0000 MHz, 偏离标称 …` 的 **FAIL**（"计数被钉死"），**没有**任何 `[PASS]` 频率行 ⇒ **报错而不是报一个假频率** |
| ④ `good_old` | 同一块正常假板 | 旧版留档件 ⇒ **伪影重现**（312.5120 MHz / ÷2），正面证明"这个修复抓到的是真缺陷" |

⚠️ **台架模型说明（诚实边界）**：假板子的"钟"用**虚拟钟**（每次 `date` 调用 +0.001 s、`sleep`
按睡眠时长前进）—— 因为本台架跑在 **Windows/MSYS** 上，进程 fork+exec 是 50~150 ms 量级
（真板是 Linux，~2~5 ms），用真实墙钟会把**台架自己的启动延迟**灌进频差（实测 ±3%）。
虚拟钟让"锁存→时间戳"的延迟在两点上**逐字相同**⇒差分里自动对消。真板上的精度证据是首轮的
**独立两点测量**（156.1986 MHz = −0.033%，`live/freq_raw.txt`）—— 那条不受本次修复影响，仍然有效。

---

## 4. 负对照总表（**全部真跑**，原始件在 `p7b_gate4_tools/fix2/`）

| 套件 | 驱动 | 结果 | 原始件 |
|---|---|---|---|
| **① 地址 RTL 级** | `_proj_pcie/run_tb_axi_regs.bat`（现成单元门） | **`PASS_ALL 22/22`，退出码 0** | `fix2/tb_axi_regs_stdout.txt` |
| **② live 路径** | `_proj_pcie/p7b_gate4_livefake.sh`（假工程树 + 假对端） | **`OK=26 BAD=0`** | `fix2/livefake/{SUMMARY.txt, <case>.log, <case>.calls, <case>.rc}` |
| **③ 频率伪影** | `_proj_pcie/p6e_snap_selftest_fix2.sh`（假板子，真锁存语义） | **`OK=19 BAD=0`** | `fix2/selftest_*.log`、`fix2/SUMMARY.txt`、`fix2/addrlog_*.txt` |
| **回归（既有 15 条）** | `_proj_pcie/p7b_gate4_negctrl.sh`（合成读数，离线） | **`OK=15 BAD=0`**（`clean` 仍要求 `FAIL=0`/退出 0） | `p7b_gate4_tools/negctrl/SUMMARY.txt` |
| **回归（既有假板子）** | `_proj_pcie/p7b_gate4_selftest.sh` | **`OK=14 BAD=0`、退出码 0**（51 字地址序列 / 0xE8 / 0xEC / 6.1 正反两面全部照旧成立）。⚠️ 它那台假板子的"钟"是 `date` **每调一次 +5 s** 的粗虚拟钟 ⇒ 新的噪声守卫在 4.3 段打 **SKIP**（半宽 5 s vs 窗口 10 s = 50%）——**这是守卫按设计工作，不是回归**；4.3 段的**正例**由 `p6e_snap_selftest_fix2.sh` 的 `good` case 覆盖（精确读到 156.2500 MHz）。**首轮产物另存** `fix2/prev_round_selftest/` | `p7b_gate4_tools/selftest/SUMMARY.txt` |
| MSYS 改写复现 | 手跑（`fix2/msys_pathconv_repro.txt` 内逐条命令） | 与上报现象**逐字一致** | `fix2/msys_pathconv_repro.txt` |

⚠️ **`negctrl` 夹具同批改了一处**（不是脚本行为变化）：`gen_snap()` 里 W5 的 Δ 由"125 口径"改成
**781,250,000 / 5 s**（= 156.25 MHz，与真板 P7b 读数同口径）。理由：夹具的字值必须与**真板**同形，
否则"修好 nominal"之后 `clean` 正对照反而会 FAIL —— 这个中间态（**14/1**）真的发生过，
日志留档在 `fix2/regress_before_fixture_fix/`（它就是"夹具没跟上判据"的证据，不是失败）。

---

## 5. 诚实边界 / 未做 / 过程中踩到的自伤

1. **没有烧板、没有重启对端机、没有改 RTL/XDC/构建脚本**；**没有起 Vivado 综合/实现**，
   只跑了现成的 **xsim 单元门**（`run_tb_axi_regs.bat`，`PASS_ALL`）与本地假台架。
   对端机**零改动**（本轮**一次 ssh 都没发**：live 路径全部由假对端承接）。
2. **live 路径只跑了"假对端"，没跑真板** —— 这是"不许烧板"下的**最大可能覆盖**，但必须如实标注：
   三处修复的**真板复现**要等下一次上板（按 §7 的跑法即可，且**不再需要** `PY=` 注入）。
3. ⚠️ **一处证据链损失（本 agent 的失误，如实记录）**：首轮 `p7b_gate4_tools/negctrl/*.log` 与
   `SUMMARY.txt`（`OK=15 BAD=0`）在我在 **10:24 的回归跑里被同名覆盖**（我**先跑后备份**，
   备份下来的 `fix2/regress_before_fixture_fix/` 已是**中间态 14/1**）。
   该轮的 15 条结论仍**逐行**留在 `P7B_GATE4_TOOLING.md` §4；`selftest/`（09:44）**未受影响**，
   已原样留档 `fix2/prev_round_selftest/`。**教训：回归跑之前先备份被覆盖的产物目录。**
4. **台架自身的两个坑（都被台架的断言当场抓住，记下来给后人）**：
   - 用 `.bat` 包装 python 来复现 MSYS 改写 **不可行** —— `cmd.exe` 会把**多行参数**重新切分，
     快照脚本只送到第一行；正解是"假工程树 + 真 `python.exe`"。
   - 我第一版假对端用正则从回显里抽命令，模式里写了 `\n` ⇒ 被正则解释成**换行转义**而不是
     字面的"反斜杠+n" ⇒ **静默不匹配** ⇒ 假对端"安静地什么都没做"（正是本工程最恨的失效形态）。
     改成纯字符串切分（`chr(92)` 组装）后正常。⇒ **"静默不匹配"要当一等公民防。**
5. **未做**（留给下一轮，不在本单范围）：给 `p6e_snap_check.sh` 的 §4.1/4.2 段也补 gen 自证
   （它现在读的 A/B 各自紧跟一次 `snap_take`，**恰好**是新一代，但**没有自证**）；
   给 `p7b_gate4_accept.sh` 加**自动化**的 N-a（TX_DIS 掉 link）负对照（现在仍是手工步骤）。

---

## 6. 文件清单（改动 / 新增，全部在本 agent 的所有权范围内）

| 文件 | 动作 |
|---|---|
| `_proj_pcie/p7b_gate4_accept.sh` | **就地改**：②a 多块快照（`nsf`/`snap_block`）、②b `run_traffic`+`check_traffic`(T_RUN)+默认值形态、②c `peer()` 剥 CRLF+`PIPESTATUS`、解析层 `\r` 兜底、`W5_NOM_MHZ` |
| `_proj_pcie/p6e_snap_check.sh` | **就地改**：③ `snap_take_gen`/`snap_pair` 自证新一代、噪声守卫（>0.5% 打 SKIP）、`W5_NOM`/`SNAP_FREQ_GAP`、÷2 分支加注 |
| `_proj_pcie/p7b_gate4_negctrl.sh` | **小改**：夹具 W5 的 Δ 改成 156.25 口径（+ 注释说明为什么必须与真板同形） |
| `_proj_pcie/p7b_gate4_livefake.sh` | **新建**：live 路径假对端台架（7 个 case，含新旧对照） |
| `_proj_pcie/p6e_snap_selftest_fix2.sh` | **新建**：③ 的假板子自证（真锁存语义，5 个 case） |
| `_proj_10g/notes/P7B_GATE4_PLAN.md` | **就地改**：① `0x10→0x08`（+写后读回+机理+成因）；G2 标称 125→156.25；W50 ÷2→÷1；步骤 5.3/6.2 打流命令首词；G2 补"读数自证新一代" |
| `_proj_10g/notes/P7B_GATE4_TOOLING_FIX2.md` | **本文件** |
| `_proj_10g/notes/p7b_gate4_tools/fix2/**` | **新建**：`old/`（三份 pre_fix2 留档）· `livefake/` · `selftest_*.log` · `msys_pathconv_repro.txt` · `tb_axi_regs_stdout.txt` · `prev_round_selftest/` · `regress_before_fixture_fix/` |

**没碰**（按派单的文件所有权）：`board/**`（尤其 `wrapper_p4.v`）· `rtl/**` · `tb/**` · `sim/**` ·
`P7B_SPEC.md` · `_proj_10g/notes/P7B_GATE4_TOOLING.md`（上一轮记录，只引用）·
`P7B_GATE4_ACCEPT.md`（执行方的报告，只引用）。
**未做**：烧录 / 重启对端机 / 对端机任何 ssh / RTL / XDC / 构建脚本改动 / `git add|commit`。

---

## 7. 怎么跑（fix2 之后；**不再需要** `PY=` 注入）

```bash
cd /d/repo/XCKU5PMini/udp_hls_10g          # 本仓根 = git 仓根

# ① 工具自证 (不碰板子; 秒级~分钟级)
bash _proj_pcie/p7b_gate4_negctrl.sh            # 15 条合成读数负对照 → negctrl/SUMMARY.txt
bash _proj_pcie/p6e_snap_selftest_fix2.sh       # ③ 的假板子 (真锁存语义) → fix2/
bash _proj_pcie/p7b_gate4_livefake.sh           # ② 的 live 假对端 (新旧对照) → fix2/livefake/
bash _proj_pcie/p7b_gate4_selftest.sh           # 上一轮的假板子 (51 字/0xEC/6.1) → selftest/

# ② 闸 4 板侧前置 (先烧位流 → 重启对端机; 见 P7B_GATE4_PLAN.md 步骤 2/3)
PEER_PW=111111 G4_SKIP_TRAFFIC=1 bash _proj_pcie/p7b_gate4_accept.sh
#    ⇒ 身份(G1) + 51 字窗口(B_WIN/B_UNIMPL) + **两块**快照 ⇒ G2 三域频率 + G3 守恒 +
#      C 组 PCS + C8(在涨) + NIC 基线窗判别力自检(N_BASE)   [旧版这些全被 SKIP]

# ③ 全链 (自己补路由 → 教学 → 打流 → NIC 两点 + 板侧洪泛两点)
PEER_PW=111111 bash _proj_pcie/p7b_gate4_accept.sh
#    ⇒ 多出 T_RUN (激励执行凭证) 与 B_G6 / N_XCHK (洪泛窗) 两组判据;
#      退出码: 0 全 PASS / 1 有 FAIL / 2 前置闸拒绝
```
**开关速查**：`G4_SKIP_TRAFFIC=1` · `G4_TRAFFIC_CMD=...`（**首词可以随便**，不再有 `/` 的坑）·
`G4_IFACE=` · `EXPECT_BID=` · `SNAP_WORDS=` · `W5_NOM_MHZ=`（P6b 位流取 125）· `TRAFFIC_TIMEOUT=` ·
`NIC_GOOD_MIN` / `NIC_MBPS_MIN` · `G4_SNAP_TEXT` / `G4_NIC_TEXT`（合成读数，逗号分隔 **2 或 4** 个文件）。

**行为变化提示（给闸 4 执行者）**：live 档现在**必然**多取快照（全链 4 块 / 停机档 2 块），
每多一块 +5 s 等待 ⇒ 停机档总时长约 +10 s；新增判据 `T_RUN`；`clean` 的期望值随 W5 标称变成 156.25。
