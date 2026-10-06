# P7B `wu` 闭环 —— 测量台准备 + same-session 基线（执行报告）

- 日期：**2026-10-07**　窗口：**UTC 17:18:42 – 17:28:20**（本地 UTC+8 = 01:18–01:28）
- 轮次性质：**板级测量台准备 agent**（补 J6/J15 的**判据记录缺口** + 用**板上当前未修复位流**做 same-session 基线）。
- 合规：**未烧板、未改板子状态**（除标准快照触发外；`gen` 5→42，`0x08` **只读未写**，读回 `0x00000000`，carrier 全程 1）；
  **未碰** `rtl/**`、`board/**`、`tb/**`（并发 agent 正在写）；**未做任何 git 写操作**（`git status` 里我的唯一已跟踪改动 =
  `M _proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh`）；未写 QSPI；未碰 `D:\repo\perfv`；
  对端只写了 `/tmp/p7b_biz/` 与我自己的台架脚本，**未改对端任何全局配置**（sysctl/qdisc/offload 一字未动）。
- 板上身份：**BID `0x00000008` / MAGIC `0x50360001` / `0x114`→`0xffffffff`**，位流 sha256 **`d20c08c9…5ed5`**
  （⚠️ 板子不吐 sha256：该值 = 盘上 `.bit` 现算 + 烧录日志 `00:12:22` + **现场 BID 读数**三条合起来的判断，见 §6-4）。

---

## 0. 一句话（三件事）

> ### ① **缺口已补**：`tcpreg_j6.sh` 现在**无条件**打 `PACE_BPS=`（`PACE=0` 也打），并打 `J6META_*` 元数据块
> ### （时刻/目标/时长/脚本 md5/位流 sha256/板侧 MAGIC+BID 现场读）＋ **J15 专用**的 `t0/t1` 紧贴传输窗快照对。两侧 md5 逐条一致。
> ### ② **same-session 基线已取**：同板同会话 **5 跑** —— **PACE=0 ⇒ 4.631 / 5.060 Mbps（塌陷复现）**、
> ### **160M ⇒ 13.281 / 14.593 Mbps（塌陷复现）**、**100M ⇒ 800.186 Mbps（不塌，pace 帽）**；与归因轮 4 组对照逐项吻合（§3）。
> ### ⭐ ③ **顺带砸出一个测量台真缺陷（比基线更值钱）**：`p7b_tcp_src.cpp` 的
> ### **`fill(整块)` + 非阻塞 `send()` 部分发送 ⇒ 图案流内部跳字节** ⇒ 板侧连续 LFSR 检查器（**W54**）
> ### **永久失步 ⇒ 假失配**。**直接见证 + 修好后的 A/B 双向对照**见 §4：
> ### 同一 pace 同一板：**未修 ⇒ ΔW54 = 597.5 M（99.5%）**；**修好 ⇒ ΔW54 = 0**（且该跑仍有 30 次部分发送）。
> ### ⇒ **用未修的工具，W54 在长/高速跑上不可用**（假失配可到 99.5%）；J12 的 64 KB 结论本身没错，
> ### 但"**大样本逐字节**"这一格 = **空的**（历史上也没被有效量过，归因轮的原始件里就躺着同一个假数）。

---

## 1. 交付① 改了什么（现役脚本 1 个 + 新诊断件 3 个；**权威工具 `p7b_tcp_src.cpp` 一字未动**）

### 1.1 `_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh`（md5 `8ce3a2f4…` ⇒ **`8bff24e8…`**）

| # | 改动 | 为什么 |
|---|---|---|
| 1 | `PACE_BPS=` **无条件打印**（原 `:29` 只在 `PACE!=0` 时打），且在 `./p7b_tcp_src` 调用**前一行**再打一次 | 原缺口：**不 pacing 的那一跑恰恰没有 pace 记录**，而它是"有没有被帽子限速"的对照组（全局 §六 #43/#48） |
| 2 | 新增 `J6META` 块（开头 + 结尾）：`T_START/END`(epoch+UTC)、`HOST/TAG/TARGET/SECS/PCAP`、`SCRIPT+SCRIPT_MD5`、`BIT_SHA`(env 传入)、`SRC_CMD`(**含 `$EXTRA` ⇒ pace 在命令行里也可见**)、`BOARD_MAGIC/BOARD_BID`(**现场 `reg_rw` 读**)、`DUR_S`、`BID_END` | 元数据缺口；且**板侧身份是现场读的 ⇒ 中途被重烧可检出**（BID 头尾各一次） |
| 3 | 新增 `t0/t1` 快照对（只读 `W5/W53/W54`）**紧贴传输窗**（`t0` 在 src 前一行、`t1` 在 src 后一行） | **J15 的板内时基**：板侧速率 = `ΔW53/(ΔW5/156.25e6)`，不含 tcpdump 准备与收尾的死时间、不依赖主机墙钟 |
| — | **未动**：工具参数（host/port/seconds/chunk）、pcap 过滤器、`ss` 采样、末尾那条装饰性 `ping` | 保证与 Stage 1/2/归因轮 **逐字同参数**，A/B 可比 |

`t0/t1` 用的是 `p7b_snap.sh snap`（不是 `pair`）⇒ **自证新一代**（gen 恰好 +1）仍然成立。

### 1.2 新增（都属于我的目录，均为**诊断**用，不改基线）

- `p7b_biz_tcpreg/p7b_tcp_src_diag.cpp`（md5 `ffbc7f29…`）：`p7b_tcp_src.cpp` 的**只加计数器**变体（`partial_sends/skip_bytes/first_partial_at`）。
- `p7b_biz_tcpreg/p7b_tcp_src_fix.cpp`（md5 `e0b7baa1…`）：**修好的**变体（见 §4.3），建议回灌到权威件。
- `p7b_biz_tcpreg/wuloop_diag_partial.sh`（md5 `0b7d4c22…`）：诊断跑法（`BIN=` 可切二进制、`PACE=` 可切档）。

---

## 2. 交付② 同步与核对（仓库副本 ↔ 对端 `/tmp/p7b_biz/`，改完**两侧现算**）

| 文件 | 仓库 md5 | 对端 md5 | 一致 |
|---|---|---|---|
| `tcpreg_j6.sh`（**本轮的补丁件**） | `8bff24e8aa5157784423aff1a03faecf` | `8bff24e8aa5157784423aff1a03faecf` | ✅ |
| `tcpreg_env.sh` | `c454f63ef3ea21e463ae0d1482f2028e` | `c454f63ef3ea21e463ae0d1482f2028e` | ✅ |
| `p7b_snap.sh` | `331a2e54c335b5339529a4eb356f404d` | `331a2e54c335b5339529a4eb356f404d` | ✅ |
| `p7b_tcp_src.cpp`（**基线工具，我未改**） | `7f9aa7161a9beb7bd978ac095926b488` | `7f9aa7161a9beb7bd978ac095926b488` | ✅ |
| `p7b_tcp_src_diag.cpp` | `ffbc7f29e5ec5fe45a663bb536acc72d` | `ffbc7f29e5ec5fe45a663bb536acc72d` | ✅ |
| `p7b_tcp_src_fix.cpp` | `e0b7baa144643820903136cab6aec991` | `e0b7baa144643820903136cab6aec991` | ✅ |
| `wuloop_diag_partial.sh` | `0b7d4c22d071c8acbf31b4703b4e867a` | `0b7d4c22d071c8acbf31b4703b4e867a` | ✅ |
| `p7b_tcp_src`（二进制，对端独有） | — | `c038e14a518e6234bdc1b91ad584a90e` | — |
| `p7b_tcp_src_diag`（二进制） | — | `8c5b101d21bfbabbf5018d96b3f524cf` | — |
| `p7b_tcp_src_fix`（二进制） | — | `09a266a9603f9ccd61627310753cf615` | — |
| `analyze_window.py`（主机侧独有） | `13538c6fd5684ee4afa030283350b025` | — | — |

**另加一条"工具自证"（本轮新增）**：在**对端**用 `g++ -O2 -o <新名> p7b_tcp_src.cpp` **重编译**
⇒ md5 **逐字节等于**在役二进制 `c038e14a…` ⇒ **在役工具 = 记录的源码 × 记录的命令行**（不是"只有 mtime 背书"）。
（重编译产物写新名 `p7b_tcp_src_rebuild` 后即删，**未覆盖在役二进制**。）

### 2.1 ⚠️ 顺带修掉一个复跑陷阱：git-bash 会改写 `peer_ssh.py --put/--get` 的远端路径

`python tools/peer_ssh.py --put a.txt /tmp/x.txt` 在 git-bash 里**必失败**（`FileNotFoundError`）——
MSYS 把 `/tmp/x.txt` 改写成 `C:/…/tmp/x.txt` 再交给原生 python ⇒ **远端路径不存在**。
**实测判据**：同一条命令加 `MSYS_NO_PATHCONV=1` ⇒ `PUT OK`（不加 ⇒ `FileNotFoundError`，退出码 255）。
`--sudo '<整条命令>'` 那种**单引号整串**不受影响（MSYS 只改写"看起来像路径的**单独参数**"），
所以交接件里现役的 `--sudo 'bash /tmp/…'` 写法没问题，**只有 `--put/--get` 的裸路径会踩**。

---

## 3. 交付③ same-session 基线（**未修位流** `d20c08c9…`，**全程不重烧**）

### 3.1 跑前前置闸（逐字，UTC `2026-10-06T17:18:52Z`；原始件 `p7b_biz_tcpreg/wuloop_pregate.txt`）

```
identify_bars: 2 BARs: config 1, user 0, bypass -1.        <- 板上跑的是我们的设计
LnkSta: Speed 5GT/s (downgraded), Width x4                 <- 有救档位（x4）
carrier: 1
ip route get 192.168.100.2 ->  192.168.100.2 dev enp1s0f1np1 src 192.168.100.100 uid 0
BAR 0x00 = 0x50360001   0x04 = 0x00000008   0x114 = 0xffffffff
nmcli GENERAL.STATE = 10 (unmanaged)                       <- NetworkManager 冲 /32 的根治仍在位
```
每次跑的**同一份原始件里**还有：`J6META_BOARD_MAGIC=0x50360001 J6META_BOARD_BID=0x00000008`（脚本现场读，头尾各一次）
+ `CARRIER=1` + `ip route get` 现取。跑后复核（`wuloop_postcheck.txt`，UTC 17:26:12）逐条不变，且 **`0x08`（SCRATCH/**TX_DIS 门**）= `0x00000000`**；
**收尾再核一次**（UTC `17:31:59`，报告写完后现取）：`0x00=0x50360001 / 0x04=0x00000008 / 0x08=0x0`、`carrier=1`、`identify_bars = 2 BARs` ⇒ **板子在整个会话前后逐条同态**。

### 3.2 五跑读数（**逐字取自原始件**；两跑/档，`SECS=6`）

| tag | **PACE_BPS** | 对端 `tx_bytes` | 对端 `tx_Mbps` | 板侧 `ΔW53`(app 收字节) | 板侧 `ΔW54`(失配) | `ΔW54/ΔW53` | **J15 板内时基** |
|---|---|---|---|---|---|---|---|
| `WU_BASE_P0` | **0** | 3,794,776 | **5.060** | 3,793,548 | 2,414,006 | 63.63% | —（无 t0/t1，见下） |
| `WU_BASE_P160` | **160000000** | 9,960,712 | **13.281** | 9,960,164 | 2,088,423 | 20.97% | — |
| `WU_BASE_P100` | **100000000** | 600,139,784 | **800.186** | 600,138,840 | 597,406,439 | 99.54% | — |
| `WU_FIN_P0` ⭐ | **0** | 3,473,408 | **4.631** | 3,473,308 | **0** | 0.00% | **4.253 Mbps**（窗 6.021 s 板内） |
| `WU_FIN_P160` ⭐ | **160000000** | 10,944,512 | **14.593** | 10,943,300 | **0** | 0.00% | **14.269 Mbps**（窗 6.022 s 板内） |

- 前 3 跑 = **补丁前**脚本（无 `t0/t1`、`PACE_BPS` 已无条件打）；后 2 跑 = **最终脚本**（md5 `8bff24e8…`）。
- ⭐ **`WU_FIN_*` 是本轮交付的基线臂**（与下一轮"修好后同 pace 应不再塌"直接对照）。
- 每跑的**原始件**：`p7b_biz_tcpreg/wuloop_{p0,p160,p100}_j6_run1.txt`、`wuloop_fin_runs.txt`（两跑在一个文件里，`TCPREG_J6_DONE` 分隔）。
  逐跑可核：`PACE_BPS=` 行、`J6META_*` 块、`SRC_SUM`、**61 字 pre/post 快照**、中途 `t0/t1`（FIN 两跑）。
  例（`WU_FIN_P0`，逐字）：`SRC_SUM tx_bytes=3473408 rx_bytes=1048576 dur_s=6.000 tx_Mbps=4.631 … rx_first_mismatch=-1 send_err=0`。

### 3.3 与归因轮 4 组对照的**同会话复现**（这是"基线可用"的核心判据）

| PACE | 归因轮（`P7B_BIZ_TCPREG.md` §5） | **本轮** | 判读 |
|---|---|---|---|
| 0 | 4.544（RATE 臂）/ 4.719（BIZ 臂） | **4.631 / 5.060** | ✅ 塌陷复现（同量级，逐跑 ±10%） |
| 100 MB/s | **800.140** | **800.186** | ✅ 复现到 **0.006%**（差在第二个小数位） |
| 160 MB/s | 13.195 | **13.281 / 14.593** | ✅ 复现 |
| 2^30 | 4.719 | （本轮未重跑，**任务只要 0 + 一档 paced**） | — |

⇒ **"稳定 ⟺ 发送速率 ≤ app 有效消费率"这条在同一个会话里再次成立**；且 **PACE=0 的 4.6–5.1 Mbps 不贴任何 2 的幂**
⇒ **不是台架帽子**（帽子问题只对 **历史那次 1,073.043 Mbps = 2^30 的 99.94%** 成立）。

### 3.4 塌陷的**形状**也复现（判据 W，pcap 逐 ACK；`analyze_window.py`）

| 跑 | ACK 数 | `win_raw` 范围 | 其中 `<1 MSS(1460)` | `>100 ms` 静默段 | 周期 |
|---|---|---|---|---|---|
| `WU_BASE_P0` | 2,860 | **120 – 49,152** | 92 | **31 段** | ~**207.9 ms** |
| `WU_BASE_P160` | 7,278 | **288 – 49,152** | 38 | 30 段 | ~206 ms |
| `WU_FIN_P0` | 8,028 | **400 – 49,152** | 44 | 29 段 | ~**206 ms**（max 0.206） |
| （归因轮 BIZ 臂） | 2,705 | 128 – 49,152 | 98 | 33 段 | 207.2 ms |

⇒ **~207 ms persist 周期 + 窗周期性跌破 1 MSS** 的签名逐跑一致 ⇒ 基线测的是**同一个缺陷**。
原始 pcap/CSV：`wuloop_{p0,p160,fin_p0}.pcap` + `*_win.csv`。

### 3.5 J6 / J15 的**状态**（本轮如实口径）

- **J6 = 仍 FAIL**（同上表：0 档 4.6–5.1 Mbps，远离 1.00–1.20 Gbps 预测带）——**但这次带 pace 记录**，且**修复前基线已成对**（`WU_FIN_P0` / `WU_FIN_P160`）。
- **J15 = 读数已备、判据未评**：`WU_FIN_*` 两跑给出了**板内时基**读数（4.253 / 14.269 Mbps，分母 = 板内 `ΔW5` 秒），
  但 J15 的"**新预测带**"是**修复轮**才定义的上界（且 `UDP_TX_OVL` 下 4.803 Gbps 那个上界已作废）⇒ 本轮**不替它下结论**。
- ⚠️ **J15 的两个坑（本轮实测踩到，登记）**：
  ① **`t0/t1` 窗会混进"上一跑欠账的排空"** —— `WU_FIN_P0` 的 src 窗内板侧只消化 1.63 MB，而 src 已发 3.47 MB；
  随后 2 s 内以 ~0.92 MB/s 把欠账排完（`ΔW53(pre→post)=3,473,308 ≈ tx_bytes`）。
  ⇒ 判 J15 前**必须**看一眼 `ΔW53(pre→post)` 与 `tx_bytes` 是否已经对平，否则量的是"消费+排空"。
  ② `W5` 是 **32 位自由计数**，跨 `0xffffffff` 会回绕（`WU_FIN_P160` 的 `t0→t1` 就跨了）⇒ **差分必须按 2³² 取模**。

---

## 4. ⭐ 本轮真发现：`app_pattern.stat_mismatch`（W54）被**工具**打坏

> 判据链（J12/J13）里，**W54 = 上行载荷逐字节失配**是唯一的**内容** oracle。本轮首次在**大样本**上打出它，
> 结果与 J12 的 64 KB 结论冲突 ⇒ 顺着查，**根因在测试工具，不在板子**。

### 4.1 现象（三跑非 0、多跑为 0，且**与 pace 无关**）

| 跑 | ΔW53 | ΔW54 | 失配率 | 备注 |
|---|---|---|---|---|
| `WU_BASE_P0` | 3,793,548 | 2,414,006 | **63.63%** | 低速率档也中招 |
| `WU_BASE_P160` | 9,960,164 | 2,088,423 | 20.97% | 同上 |
| `WU_BASE_P100` | 600,138,840 | 597,406,439 | 99.54% | 600 MB |
| 归因轮 `paced_j6_run1.txt`（**他们的原始件**） | 600,096,632 | **597,663,892** | 99.59% | ⚠️ **同一现象在归因轮就有，只是没被引用** |
| `WU_FIN_P0/P160`、diag×18（**全在 PACE=0**）、fix×1（PACE=100M） | ≈tx_bytes | **0** | 0% | 见 §4.4 |

⚠️ 关键旁证：**ΔW53 在所有跑里都 ≈ 对端 `tx_bytes`（差 ≤0.1%）** ⇒ **字节数是对的**，错的只是"**内容对不上**"。

### 4.2 直接见证（PACE=100 MB/s，`p7b_tcp_src_diag`，`wuloop_diag_p100.txt`）

```
SRC_SUM tx_bytes=600096648 rx_bytes=1048576 dur_s=6.000 tx_Mbps=800.129 … 
        partial_sends=1326 skip_bytes=5718136 first_partial_at=327680
板侧:  ΔW53 = 600,470,304   ΔW54 = 597,544,495  (99.51%)
```

- `first_partial_at = 327,680` = **恰好 5 × 65,536**（工具每块 = 65536）。
- 模型：`fill()` 每次把图案**推进整块 65,536**，而**非阻塞 `send()` 可只收前缀 `n`** ⇒ 下一块从
  `k·65536` 而不是 `k·65536+n` 续 ⇒ 线上图案流**内部跳 (chunk−n) 字节**；板侧检查器是**连续 LFSR**
  （`rtl/app_pattern.v:537-541`：每比一个字节就 `xs_next`）⇒ **从第一个跳点起永久失步**，
  之后**只有 1/256 的字节会"碰巧对上"**。
- 定量对账：首错字节 ≈ `first_partial_at + n₁`，预测失配率 ≈ `1 − (P+n₁)/N + (1/256)·(…)` ⇒ **99.5%**；**实测 99.51%** ✅。
- 同一模型套 `WU_BASE_P160`：`N=9,960,164, M=2,088,423` ⇒ 首错字节 ≈ 7,863,544 ⇒ 落在**第 120 块**（`119×65536=7,798,784`）后 `n₁≤65536` 的窗口内 ✅（差 0.05%）。
- 同一模型套 `WU_BASE_P0`：首错字节 ≈ 1,370,067 ⇒ 落在**第 21 块**（`20×65536=1,310,720`）后 `n₁=59,347` 处 ✅（差 0.26%）。

### 4.3 修好后的 A/B（**同一 pace、同一板、同一会话**）—— 这一对才是判决

`p7b_tcp_src_fix.cpp` 的唯一改动：**上一块发完才重填**，部分发送就从剩余处**续发**（不再跳）：

```c
size_t ppos = (size_t)chunk;
...
if (ppos >= (size_t)chunk) { tx.fill(sbuf.data(), (size_t)chunk); ppos = 0; rewraps++; }
ssize_t n = send(fd, sbuf.data() + ppos, (size_t)chunk - ppos, MSG_NOSIGNAL);
if (n > 0) { if ((size_t)n < (size_t)chunk - ppos) partial_sends++; ppos += (size_t)n; tx_bytes += n; }
```

| 臂（PACE=100 MB/s，600 MB） | `partial_sends` | `ΔW54` | `ΔW54/ΔW53` | `tx_Mbps` |
|---|---|---|---|---|
| **未修**（`p7b_tcp_src_diag`，`wuloop_diag_p100.txt`） | 1,326（跳 5,718,136 B） | **597,544,495** | **99.51%** | 800.129 |
| **修好**（`p7b_tcp_src_fix`，`wuloop_fix_p100.txt`） | 30（**部分发送照样发生**，但一跳不跳） | **0**（`0x477b71b7`→`0x477b71b7`） | **0.00%** | 800.237 |

⇒ **正控（= 修好后仍有部分发送，但失配消失）+ 负控（= 未修照样塌）都在**；且**速率读数不受影响**
（工具字节流长度本来就对，坏的是图案内容）⇒ **本轮及历史上所有 `tx_Mbps` 读数不受此缺陷影响**。

### 4.4 低速率档（PACE=0）：**18 跑没抓到部分发送 ⇒ 该臂的 63.63% 只有模型一致性、没有直接见证**

`p7b_tcp_src_diag` 在 PACE=0 跑了 **18 次**（`wuloop_diag_partial_run1.txt` + `runs234` + `runs5to10` + `runs11to18`）：
**每一次 `partial_sends=0 skip_bytes=0`，且每一次 `ΔW54=0`**。
⇒ 低速率下"发送缓冲区没被填满 ⇒ 不出现部分发送"是自洽的（机理推测：Linux 的 `POLLOUT` 要"半个 sndbuf 空出来"才置位，
**本轮未直接实测**；观测事实只有"18 跑 0 次部分发送"）；
`WU_BASE_P0` 的 63.63% 与"第 21 块处发生一次部分发送"**在模型内吻合**（差 0.26%），
但**那一次没有被计数器直接见证**（它用的是没有计数器的原件）。
⇒ **如实登记：低速率臂的这一条判不了"工具 vs 板子"**（见 §6-1）。板侧替代解释（RX 交付流里出现一次内部错位/丢块）
**没有被我的数据排除**。

### 4.5 ⭐ 旁证（同族工具）：UDP 工具 `p7b_udp_src.cpp` **有同一族风险**，且现有 2.5 GB 证据说明它**没触发**

`p7b_udp_src.cpp:126-143`：**先把整批 `batch` 个 datagram 全部 `pat.fill()` 推进**，然后
`sendmmsg(..., batch, MSG_DONTWAIT)`；**只发出去 `r < batch` 时，没发的那 `(batch−r)×paylen` 字节的图案已被跳过**
⇒ 与 TCP 侧同型（线上图案流出现内部跳），而且**它连计数器都没有**。
- ⚠️ 但**板上既有读数说明它在实测里没触发**：J8 的 **2.5 GB / 1,699,200 datagram 跑 `ΔW13 ≡ 0`**
  （`P7B_BIZ_PLAN.md:198`）⇒ 若发生过一次跳，`ΔW13` 会是"跳点之后全部字节"量级，**不可能为 0**。
- ⭐ **反向也印证了本轮的模型**：该工具**故意**做的 `--skip-at` 负对照（丢 1 个 datagram ⇒ 图案推进但不发）
  实测得到 `ΔW13 = 0x7C7 = 1991`（`p7b_pattern.h:14-16`），即"**跳点之后按 255/256 计失配**" —
  **这正是 §4.2 对 TCP 侧用的同一条连续 LFSR 语义**（板侧两个检查器同构）。
- ⇒ 建议：UDP 工具同批加"整批发完才推进图案"+ `skip/partial` 计数（改动比 TCP 侧还小），
  这样 `W13` 在**满速**档也自带见证；在此之前，**满速 UDP 跑**若出现 `ΔW13 > 0` 要先排除工具再怀疑板子。

### 4.6 结论与影响面（照此修订引用）

1. ⛔ **`W54` 只在"工具无部分发送"的跑里可信**（e.g. J12 的 64 KB 注入门 —— **它的结论仍然成立**）。
   **长/高速跑用现在的工具 ⇒ W54 结构性不可用**（假失配率可达 99.5%）。
2. ⛔ **归因轮 §5 表格里的 C 行**（`pace=100 MB/s ⇒ 800.140`，`ΔW53 = 600,099,704`）**其 ΔW54 那半格是假的**
   （他们的原始件 `paced_j6_run1.txt` 里 `ΔW54 = 597,663,892` —— 与本轮 597,544,495 差 **0.02%**，同一把刀）。
3. ✅ **不受影响**：`ΔW53 == 对端 tx_bytes`（J13 口径）、`ΔW55`（重传次数）、所有速率/几何读数、以及
   **UDP 侧 `W13`**（同族风险已查：`p7b_udp_src` 有同型结构但**现有 2.5 GB 证据说明没触发**，见 §4.5）。
4. **建议**：把 §4.3 的修法**回灌到权威件 `_proj_pcie/p7b_biz/p7b_tcp_src.cpp`**（并给它加 `partial_sends` 打印），
   然后**重跑一次 J12**（64 KB 正例 + 1 bit 翻位）与一次 600 MB 跑，把"大样本逐字节"这一格真正补上。

---

## 5. 复跑配方（逐字；对端 `/tmp/p7b_biz/` 现成）

```bash
PY=/c/Users/zhxue/anaconda3/python.exe
# ① 前置闸（每次发送前现取）
$PY tools/peer_ssh.py 'ip route get 192.168.100.2; cat /sys/class/net/enp1s0f1np1/carrier'
PEER_PW=111111 $PY tools/peer_ssh.py --sudo 'bash /tmp/p7b_biz/p7b_snap.sh id'     # MAGIC/BID/MARKER/UNIMPL → ID_OK
# ② 基线臂（PACE=0 / paced；BIT_SHA 传"盘上 .bit 现算"）        —— 每跑 ~13 s
PEER_PW=111111 $PY tools/peer_ssh.py --sudo \
  'BIT_SHA=<sha> PACE=0 bash /tmp/p7b_biz/tcpreg_j6.sh 6 /tmp/rep_p0.pcap TAG_P0'
# ③ 诊断/对照臂（确认工具没在造假）                            —— 每跑 ~13 s
PEER_PW=111111 $PY tools/peer_ssh.py --sudo \
  'BIN=./p7b_tcp_src_fix PACE=100000000 bash /tmp/p7b_biz/wuloop_diag_partial.sh 6 TAG_FIX'
# ④ 取回 + 逐 ACK 分析（主机侧）
MSYS_NO_PATHCONV=1 $PY tools/peer_ssh.py --get /tmp/rep_p0.pcap ./rep_p0.pcap
$PY _proj_10g/notes/p7b_biz_tcpreg/analyze_window.py ./rep_p0.pcap --csv rep_p0_win.csv
```
⚠️ 三条纪律：**不写 `0x08`**（SCRATCH = `TX_DIS` 门，写非 0 ⇒ 拉高 TX_DIS 掉链，酷似"板子死了"）；
`--get/--put` 必须 `MSYS_NO_PATHCONV=1`；**构建期间不得从被构建的工程烧位流**。

---

## 6. 我没能证明的部分（如实登记）

1. ⭐ **`WU_BASE_P0` 的 63.63% 失配**：模型一致（第 21 块处部分发送）但**无直接见证**；
   **板侧替代解释未被排除**（RX 交付流在一次小错位/丢块后永久错位 —— 但注意 `ΔW53 ≈ tx_bytes`，
   所以"丢很多字节"的版本已被排除）。**收口方向**：把 §4.3 的补丁回灌权威工具后，PACE=0 跑 N 次
   （带 `partial_sends` 打印）——若"失配>0 ⇒ 必有 partial_sends>0"再没反例，"工具说"收口；
   **有一个反例 ⇒ 板侧真缺陷，须立优先级**。
2. **app RX 消费滞后**（§3.5-①）：`WU_FIN_P0` 窗内只消化 47%、随后 2 s 排完；**机理未定位**
   （FIFO 深度？app 消费门？`tcp_echo` 与 app 之间的节流？）。它**污染 J15 的紧贴窗口径**，但对 J6（对端口径）无影响。
3. **J15 判据本身未评**（新预测带要修复轮定义）；本轮只交付**读数 + 口径 + 两个坑**。
4. **"板上跑的就是 `d20c08c9…`"** = 三条合起来的判断（盘上 `sha256` + 烧录日志时刻 + **现场 `BID/MAGIC`**）。
   板子**不吐**自己的 sha256；若下一轮要更强的身份，得把 BID 加宽/加一个位流指纹寄存器。
5. ✅ **已查（本轮收尾补做）**：UDP 工具**有同族风险**（整批 `fill` + `sendmmsg` 部分收 ⇒ 跳图案），
   但**没有计数器**；现有 2.5 GB 证据（J8 `ΔW13 ≡ 0`）说明**没触发过** ⇒ 该格结论**暂不受影响**，
   建议同批加"整批发完才推进 + 计数"。详见 §4.5。**仍未做**：`p7b_udp_src` 的**满速**档复查。
6. 归因轮的 **Stage 1 `1,073.043 Mbps` 到底带没带 `--pace-bps`**：仍无原始记录（本轮**未新增**证据，
   只是把"今后必记 pace"落进了脚本）。
7. 本轮**只跑了 0/100M/160M 三档**（任务范围）；**2^30 档未重跑**；`N-b1`/`W57/W58`/`J5` 等仍未测。

---

## 7. 文件清单（全部在 `udp_hls_10g/_proj_10g/notes/p7b_biz_tcpreg/`，除注明外）

| 文件 | 内容 |
|---|---|
| `tcpreg_j6.sh` ⭐ | **补丁后的 J6/J15 台架**（md5 `8bff24e8…`；`PACE_BPS` 无条件 + `J6META` + `t0/t1`） |
| `p7b_tcp_src_diag.cpp` | 只加计数器的变体（`partial_sends/skip_bytes/first_partial_at`） |
| `wuloop_diag_partial.sh` | 诊断跑法（`BIN=` 切二进制 / `PACE=` 切档；默认 `./p7b_tcp_src_diag`） |
| `p7b_tcp_src_fix.cpp` ⭐ | **修好的工具**（建议回灌权威件） |
| `wuloop_pregate.txt` / `wuloop_postcheck.txt` | 跑前/跑后前置闸逐字（含 `0x08` 只读复核 = 0） |
| `wuloop_p0_j6_run1.txt` / `wuloop_p160_j6_run1.txt` / `wuloop_p100_j6_run1.txt` | 三跑原始件（含 61 字 pre/post + `SRC_*` + `PACE_BPS`） |
| `wuloop_fin_runs.txt` ⭐ | **最终基线两跑**（`WU_FIN_P0` / `WU_FIN_P160`，含 `t0/t1`） |
| `wuloop_{p0,p160,fin_p0}.pcap` + `*_win.csv` | 双向 pcap 与逐 ACK 窗口轨迹（判据 W） |
| `wuloop_diag_partial_run1.txt` / `runs234` / `runs5to10` / `runs11to18` / `wuloop_diag_p100.txt` | 18 次低速诊断 + 1 次 100M 诊断（**直接见证**） |
| `wuloop_fix_p100.txt` ⭐ | **修好工具的 A/B 臂**（`ΔW54 = 0`） |
| `wuloop_md5_{repo,peer}.txt` | 两侧 md5 现算记录 |

对端 `/tmp/p7b_biz/`：以上 `.sh`/`.cpp`/二进制 `p7b_tcp_src_diag` / `p7b_tcp_src_fix` + `/tmp/wuloop_*.pcap`（未取回的两份：`wuloop_fin_p160.pcap`）。
**板子现态 = 与开工时逐条相同**（BID 8 / MAGIC / `0x08=0` / carrier 1 / 未重烧），**可以直接接下一轮**。
