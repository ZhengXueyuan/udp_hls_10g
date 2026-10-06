# ⭐ 推翻交接件 §1：**重烧位流后 `remove`+`rescan` 就能恢复 PCIe 窗口，不必重启对端机**

> **发现时刻**：2026-09-30 ~18:35（P7B-BIZ 轮开工侦察）
> **发现人**：TL 现场探针（**原始读数在本文**，未经二手转述）
> **状态**：⭐ **已现场实证**（不是推断）。✅ **独立复证已收**（2026-10-06：`P7B_BIZ_S1.md` §S0.4 记了第 1 次；
> S2 轮 4 次烧录全部适用）。
> ⛔ **2026-10-07 扩展：新增「场景 C」—— 开机时跑的是 QSPI 厂商设计（1 个 BAR）时，
> "设备级 `remove`+`rescan` 即恢复"这句就不够（见 §7；另两条新登记：`identify_bars` 判别式 / NetworkManager 冲 `/32`）。**

---

## 1. 这条推翻了什么

### 交接件 `P7B_HANDOFF.md` §1 原文（⚠️ **旧版** —— 该文件已于同日被 BIZ 轮重写，本段引文**已不在新版 §1 里**；此处保留原文以存"当时推翻的是什么"）
> ⚠️ **PCIe 观测窗口现在读不到** | 重烧后 PCIe 端点**需主机 POST 才枚举** ⇒
> **要读板侧必须先走"先烧位流 → 再重启对端机"的次序**

### 本仓 `CLAUDE.md`「本板实测修正 §2」原文
> ⭐⭐ **硬约束（实测踩过）**：**PCIe 端点只认"FPGA 配置先于主机 POST"** ……
> 事后补烧带 PCIe 的设计**救不回来**（`rescan` / 桥复位 / `setpci` Retrain Link /
> Link Disable 1→0 **四种主机侧手段实测全无效**，恒 `LnkSta Width x0`）

### 本条要说的是：**它们描述的是另一个场景**
| 场景 | FPGA 在主机 POST 时跑的是 | 后果 |
|---|---|---|
| **A（CLAUDE.md 记的那个）** | **无 PCIe 的设计** | 根端口**根本没见过**这个端点 ⇒ `LnkSta Width x0` ⇒ 四种手段全无效 ⇒ **只有重启** |
| **B（本轮实测的）** | **带 PCIe 的设计**（POST 时链路已通、已枚举） | 之后**再重烧**（同一版或另一版带 PCIe 的位流）⇒ 链路**保持 up**、主机 config 空间**陈旧** ⇒ **`remove`+`rescan` 即恢复** |
| **C（2026-10-07 扩展，见 §7）** | **QSPI 里的厂商设计**（POST 时已枚举，但只有 **1 个 BAR** ⇒ 父桥窗按 **1M** 定死） | 之后烧上**我们的设计（2 BAR）** ⇒ **设备级** `remove`+`rescan` **不够**（`BAR 1 [size 0x10000]: can't assign; no space` ⇒ xdma probe 失败）⇒ **必须连根端口一起** `remove`+`rescan`（窗重算为 **2M**） |

⇒ **A 的结论（"只有重启"）对 B / C 不成立。** B 才是本工程的日常形态
（RATE 轮"停板两步"的第二步就是重烧 —— 见 §2）；**C 是 B 的一个变体** —— 链路一直 up，
但**桥窗缓存按"1 个 BAR"定死**，故恢复要多一步（§7）。

---

## 2. 本轮之前的状态是怎么变成"读不到"的（时间线，从盘上产物读出）

| 时刻 | 事件 | 产物 |
|---|---|---|
| 17:57 | 烧 RATE 位流（= 主机 POST 前，**场景 B 成立**） | `p7b_rate_result/program_rate_ku5p.tcl` |
| 18:00 | 重启对端机 | `pre_reboot.txt` / `reboot_cmd.txt`（空） |
| 18:01 | POST 后：`/dev/xdma*` **不存在**（驱动是 out-of-tree，要手装）；`lspci` 见 `02:00.0` | `post_reboot_pcie.txt` |
| 18:02 | `insmod` XDMA ⇒ 节点出现 ⇒ **BAR 判活通过** | `bar_alive.txt` / `insmod.txt` |
| 18:03–18:08 | 板级测量全部完成 | `probe_*.txt` / `r1 r2 r3 l20` / `negA*.txt` |
| **18:12** | ⭐ **停板第二步 = 重烧同一位流** ⇒ **PCIe 应用层自此后不响应** | `rate_program_stdout.txt` / `stop_step2.txt` / `dfx_runtime.txt` |

⇒ 所以交接件说"读不到"**是对的**（18:12 之后确实读不到），
**但把它归因为"必须重启"是错的** —— 真因只是**没人试过 `remove`+`rescan` 这一条**。

---

## 3. 配方（**已验证，逐字可复跑**）

`reg_rw` 在**对端机**上：`/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools/reg_rw`

```bash
# ① 判死（重烧后应读 0xffffffff）
sudo reg_rw /dev/xdma0_user 0x00 w        # → Read 32-bit value at address 0x0 (...): 0xffffffff

# ② 复位这条 PCIe 功能 + 重新扫描（≈5 s，**不重启机器**）
sudo bash -c 'echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove; sleep 2; echo 1 > /sys/bus/pci/rescan; sleep 3'

# ③ 判活（应立刻回正确魔数；驱动已 insmod ⇒ /dev/xdma* 自动重建）
sudo reg_rw /dev/xdma0_user 0x00 w        # → 0x50360001  ✅
```

⚠️ **不需要重新 `insmod`**（模块仍在内核里，rescan 后 `xdma` 的 probe 自己跑，设备节点自动重建）。

> ⛔ **场景 C 下本配方（设备级）不够**：症状 = `BAR 1 [size 0x10000]: can't assign; no space` /
> `xdma:map_bars: Failed to detect XDMA config BAR ; probe err -22` ⇒ 改走**根端口级**
> （`0000:00:1c.0`，见 §7）；**同一会话内后续重烧只需设备级**。

> ⚠️ **本配方的前置条件：对端机自己在网。** 判它"活着没有"**只用 TCP connect**（`:22` / `:3121`），
> **⛔ 不要用 Windows `ping` 的退出码** —— 实测收到**本机自己产生的**「无法访问目标主机」（ARP 失败）时
> Windows **仍 `exit 0`**，统计行还写 **"已接收 = 1，丢失 = 0"**（看着完全像"通了"）；
> 反例「请求超时」才 `exit 1`。2026-09-30 实测（`P7B_BIZ_S2.md` §0.2）：
> 按退出码判出过 **3 次假 `PEER_UP`** ⇒ 下一步就去烧板、读到一堆空读，再把"机器不在网"
> 误归因成"板子死了"。⚠️ **同族于全局第 28/30/34 条**（判据本身安静地给出错的"通过"）。
> ⚠️ **本文件的判活/判死一律以 `reg_rw` 的 **BAR 值** + `lspci` 的 `LnkSta` 为准**（下 §4.1），
> **不以任何 ICMP 结论为准**（`0xffffffff` 与"端点不存在"在读数上不可区分，正是本文开头那条误判的成因）。

---

## 4. 原始读数（本轮实测，逐字）

### 4.1 恢复前
```
--- /dev/xdma0_control ---   Read 32-bit value at address 0x0 (0x768d40887000): 0xffffffff
--- /dev/xdma0_user    ---   Read 32-bit value at address 0x0 (0x7a3fc2f30000): 0xffffffff
```
（两条 BAR 都是 `0xffffffff` ⇒ 应用层不响应，与"端点不存在"在读数上**不可区分** —— 这正是它曾被误判成"只能重启"的原因）

### 4.2 `remove` + `rescan` 之后
```
--- after rescan, node? ---   /dev/xdma0_user
--- BAR ---                   Read 32-bit value at address 0x0 (0x735fa1a9c000): 0x50360001
```

### 4.3 快照窗口协议复证（这一条同时证明"窗口是真在搬数"，不是读到陈旧映射）

⚠️ **地址口径**：快照字 `Wi` 的地址 = **`0x20 + 4*i`**（`_proj_pcie/p6e_snap_check.sh:50`），
**不是** `0x00 + 4*i`。触发 = 写 `0x18 = 1`；done = `0x1c` 的 **bit1**；gen = `0x1c>>16`。

```
--- trigger 1 ---   snap ok status=0x00010056
W0 (0x20) = 0x00000002      W5 (0x34) = 0x948429e6
W8 (0x40) = 0x00000000      W9 (0x44) = 0x00000000
W20(0x70) = 0x00000041      W24(0x80) = 0x94955aa7
W43(0xCC) = 0x946d03be

--- trigger 2 ---   snap ok status=0x00020056
W5 (0x34) = 0xa7c13671      W20(0x70) = 0x00000041
```

**判读**（三条独立的自证）：
1. **`gen` 逐代 +1**（`0x0001…` → `0x0002…`，且 done bit1 置起）⇒ 快照机制真的被本进程触发（第 27/32 条教训的"自证新一代"）。
2. **三个自由计数器在走**：`W5`（前端域）`0x948429e6 → 0xa7c13671`、`W24`（数据面域）`0x94955aa7`、`W43`（字节计数）`0x946d03be` 都是**非零且随代变化**的值 ⇒ 窗口里读到的是**活数据**。
3. **`W20` 两次都是 `0x41`（静止）** ⇒ 与 RATE 轮"停板态"（`probe_pre.txt`：`ΔW20 = 0` 跨 2.5 s）**一致** ⇒ 板子确实停在交接件 §1 描述的状态，**没有在偷偷发流**。

---

## 5. 对下一阶段的意义

- ✅ **"先烧位流 → 再重启对端机"这个次序约束被解除** ⇒ 每一轮板级测量的固定成本从
  **~3–5 min 重启 + 掉 SSH + 掉 `/tmp` + 需要重新部署脚本**降到 **~5 s**。
- ✅ 交接件 §1「⚠️ **重启会清 `/tmp`**」这条风险**在本路径下不再必然触发**。
- ⚠️ **仍然成立**的是**场景 A**：换成一个**无 PCIe** 的位流烧上去，或在**无 PCIe 位流**下开主机
  ⇒ 仍只有重启。本配方**不覆盖**那种情形（也没试过）。
- ⛔ **本配方（设备级）也不覆盖的场景 C**：开机时跑的是 **QSPI 厂商设计（1 BAR）** ⇒ 见 §7
  （修法 = 先**连根端口一起** `remove`+`rescan`）。
- ✅ **原"未测"已部分收口（2026-10-06）**：两轮共 **7 次烧录后的 rescan 全部成功**
  （S1 轮 3 次设备级；S2 轮 1 次根端口级 + 3 次设备级）；**未见对 SFP 链路的扰动**
  （S2 全程 carrier 只在受令时变）。

---

## 6. 建议的规程修订（**待文档 owner 落进正式文件，本文不下结论**）

| 文件 | 现在写的 | 建议改成 |
|---|---|---|
| `P7B_HANDOFF.md` §1 | "重烧后 PCIe 端点需主机 POST 才枚举 ⇒ 必须先烧位流再重启对端机" | "**先烧位流 → `remove`+`rescan`（≈5 s）→ BAR 判活**；只有**换成无 PCIe 位流 / POST 时无 PCIe** 才需要重启（场景 A）" |
| `P7B_HANDOFF.md` §1 风险行 | "重启会清 `/tmp`" | 保留，但注明**本路径不触发** |
| 本仓 `CLAUDE.md`「本板实测修正 §2」 | "四种主机侧手段实测全无效" | 保留 **场景 A** 的结论（`LnkSta Width x0` 下确实无效），**另起一条**记场景 B（**链路仍 up、只是应用层陈旧** ⇒ `rescan` 有效）。⚠️ 两者的**判别式 = `lspci` 的 `LnkSta`**：`x0` ⇒ 没救；`x4` ⇒ 有救。 |
| 本文 §3（配方本身）【2026-10-07 加】 | "设备级 `remove`+`rescan` 即恢复" | **先分场景**：B ⇒ 设备级即可；**C（开机时跑的是 1-BAR 厂商设计）⇒ 必须先连根端口** `0000:00:1c.0` 一起 remove+rescan（窗 1M→2M）；**同一会话内后续重烧回设备级** |
| （新判据，2026-10-07） | —— | **`identify_bars` = "板上跑的是谁"的判别式**：`1 BARs: config 0, user -1` = **厂商设计**（QSPI 启动）；`2 BARs: config 1, user 0` = **我们的设计**。⚠️ 两者 `lspci` 都报 `10ee:9034`，**光看 `lspci` 分不出来** |
| （新风险，2026-10-07） | —— | **NetworkManager 会静默冲掉 `/32` 地址+路由**（表现 = 所有 connect timeout）⇒ **极易误判成"板子死了"**；根治 = `nmcli device set enp1s0f1np1 managed no`；每次发送前现取 `ip route get 192.168.100.2` |

---

## 7. ⛔ 2026-10-07 扩展 —— 场景 C：**开机时跑的是 QSPI 厂商设计（1 BAR）**

**现象（板上实测，出处 `P7B_BIZ_S2.md` §10.1.1）**：对端机 POST 时 FPGA 跑的是 **QSPI 里的厂商设计**
（POST 已枚举，`identify_bars` = `1 BARs: config 0, user -1`）⇒ 父桥 `0000:00:1c.0` 的内存窗
按 **1M** 定死。之后烧上**我们的设计（2 BAR = BAR0 1M + BAR1 64K）** ⇒ **设备级** `remove`+`rescan`：

```
pci 0000:02:00.0: BAR 0 [mem 0xf7a00000-0xf7afffff]: assigned
pci 0000:02:00.0: BAR 1 [mem size 0x00010000]: can't assign; no space
xdma:map_bars: Failed to detect XDMA config BAR ; probe err -22
```

**根因**：桥窗是 **POST 时按"当时的 1 个 BAR"算的**，装不下 BAR0(1M) + BAR1(64K)。

**修法（已实测）**：**连根端口一起** remove + rescan ⇒ 内核重算桥窗（`df200000-df3fffff [size=2M]`）
⇒ probe 成功、`/dev/xdma*` 重建、BAR 读回 `0x50360001`：

```bash
echo 1 > /sys/bus/pci/devices/0000:00:1c.0/remove; sleep 2; echo 1 > /sys/bus/pci/rescan
```

⚠️ **同一会话内后续重烧只需设备级 `remove`+`rescan`**（桥窗已重算、BAR 布局已在缓存里正确）
—— 实测：S2 轮 4 次烧录 = 第 1 次根端口级 + 后 3 次设备级，全部成功。
⛔ **不要**用 `0xffffffff` 判"是场景 A 还是 B/C"（都会读 `0xffffffff`）；**"有没有救"的判据仍是
`lspci` 的 `LnkSta`**（`x0` ⇒ 没救 / `x4` ⇒ 有救）。

### 7.1 新判据：**`identify_bars` = "板上跑的是谁"的判别式**

| `identify_bars` 输出 | 板上跑的是 |
|---|---|
| `1 BARs: config 0, user -1` | **厂商设计**（QSPI 启动；POST 时只枚举出 config BAR） |
| `2 BARs: config 1, user 0` | **我们的设计**（config + user 两个 BAR） |

⚠️ **两者 `lspci` 都报 `10ee:9034`** —— **光看 `lspci` 分不出来**。
（分工：`lspci` 的 `LnkSta` 管"有没有救"；`identify_bars` 管"是谁"。）

### 7.2 新风险：**NetworkManager 会静默冲掉 `/32`**

表现 = **所有 connect timeout**（`192.168.100.2` 不可达）—— **极易误判成"板子死了"**。
⇒ 每次发送前现取 `ip route get 192.168.100.2`；**根治** = `nmcli device set enp1s0f1np1 managed no`。
（出处在 `P7B_BIZ_S2.md` §10.1 的 0.7 行。）
