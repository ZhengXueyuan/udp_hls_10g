# P7B_AFFINITY ACCEPT —— 绑核工具**独立验证** + r6-fix 板级复测（2026-10-08）

- 执行者 = **独立验证 + 板级测试 agent**（未参与 `p7b_affinity.h` 的修复、未参与 r6-fix 实施；
  本轮**零 RTL 改动、零构建**，只烧 + 只测 + 自算）
- 工作仓 = `D:\repo\XCKU5PMini\udp_hls_10g`；位流取自 **`udp_hls_10g_fix`** ⛔ **2026-10-09 订正（不静默改）：该树已于 2026-10-09 删除**（删前审计：它是 `origin/master` 的祖先、已跟踪文件零改动），位流唯一副本现保全在 **`udp_hls_10g\_proj_10g\notes\p7b_retxfix_salvage\bits\`**（r6-fix = `8c8b6126__wrapper_p4.bit`；全 7 个都在）
- 报告范围：**只对我自己跑出来的读数负责**；判据层 PASS/FAIL 的裁定权在判据所有者（用户）

**一句话**：A 段 8 项**全部通过**（含两个"仅声明未验证"的格：topo 退化、F8 可复现性，均自建手段测到）；
B 段四臂跑完 —— ⭐ **warm-up 今天没有复现**（换烧后第 1 跑即平台值），且**频率全程贴顶** ⇒
**"迁移 + 抢核 + 爬频"这两个候选机制在今天的读数里都不可见**；台架帽是**逐字节复算**造成的，**不是抢核**。

---

## §0 制品身份（先说清楚"测的是哪一份"）

| 项 | 值 | 判据 |
|---|---|---|
| `p7b_affinity.h`（**6 份副本**） | 全部 `9b141b50c089b4065145879d642c58fb` | ✅ 6/6 相同，且 == 声称值 |
| 对端 `/tmp/p7b_biz/` **7 个二进制** | `10906f39…` / `e1261ef4…` / `0be6a66e…` / `754e2dfe…` / `c90808c5…` / `2ab00584…` / `732f1337…` | ✅ 7/7 == `BUILD.md` §3 指纹（逐字节） |
| 对端 7 个 `.cpp` 源 | 7/7 == `BUILD.md` 输入表 | ✅ |
| 位流 `retxfix_wrapper_p4.bit`（⛔ 2026-10-09 起现路径 = `udp_hls_10g\_proj_10g\notes\p7b_retxfix_salvage\bits\8c8b6126__wrapper_p4.bit`） | sha256 `8c8b6126f82c2c45acee1a1c308332e561677cac5cfb27b87d74d03463d5baf5`，15,431,261 B | ✅ == 声称前 8 位 |
| 板侧 BID / MAGIC / `0x11C` | `0x00000011` / `0x50360001` / `0xffffffff` | ✅ 每跑开跑前后各读一次 |

台架（对端与仓内 md5 逐字相同，现场核过）：
`stc_dl.sh f50e5f82…` · `p7b_snap.sh 68d2f668…` · `j6_stagec.sh 23c4a343…` · `j6_stagea.sh c6b27b1b…`（**旧版 0158ba1e 已按纪律覆盖**）。
⚠️ **新一件（我造的，登记在案）**：`j6_r6fix.sh` md5 `b4bf3e3bd7ea245d58bad77bff231e96`
= `j6_stagec.sh` 的**逐字最小派生**，`diff` 只 3 行（第 67/75/116 行，**全部只改 BID 常量 `0x0000000A` → `0x00000011`**）。
⛔ 不这么改跑不了：`j6_stagec.sh:75` 的几何门**硬编码** `EXPECT_BID = 0x0000000A`，传 `0x11` 会 `J6_GEOM_FAIL` exit 3
（`p7b_snap.sh` 侧本来就可 env 覆盖；`stc_dl.sh` 的 `BID_EXPECT` 本来就可参数化 ⇒ 下行台架**未改一行**）。

---

## §1 A 段逐项结论

### A1 —— F1 反例（阻断级修复）✅ **通过（7/7 RC=2 + 1/1 RC=0）**

自己发命令（**没有复用交付方的 `aff_selftest.sh`**），`p7b_udp_src` 打回环：

| 用例 | RC | stderr 原文 |
|---|---|---|
| `--core 4294967296` | **2** | `PIN_FAIL --core 参数非法 (超出 int 范围 (0..2147483647)): '4294967296'` |
| `--core 2147483648` | **2** | 同上（`'2147483648'`） |
| `--core +1` | **2** | `PIN_FAIL --core 参数非法 (非纯十进制数字 (含符号/0x/字母等)): '+1'` |
| `--core 0x5` | **2** | 同上（`'0x5'`） |
| `--core ""` | **2** | `PIN_FAIL --core 参数非法 (空串): ''` |
| `--core 5abc` | **2** | 同上（`'5abc'`） |
| `PIN_CORE=4294967296`（env） | **2** | `PIN_FAIL PIN_CORE 参数非法 (超出 int 范围 (0..2147483647)): '4294967296'` |
| `--core 5`（正例） | **0** | 见证行 `PIN_CPU=5 … PIN_ALLOWED_MASK=20` ✅ 且 `PIN_GETCPU_END=5` |

⇒ **旧实现"`atoi` 静默截断成 CPU0 且 RC=0"这个缺陷形态已消除**（每条都响亮 + 明确原因 + 专有退出码 2）。

### A2 —— F2 退化可见性 ✅ **通过（nic 与 topo 两种形态都测到）**

| 臂 | 见证行（节选，原文） |
|---|---|
| 健康（默认自动探测） | `PIN_RULE=avoid-nic PIN_DEGRADED=none … PIN_NIC_IRQLINES=12 … PIN_NIC_EXCLUDED=none` |
| `PIN_NIC_IFACE=lo` | `PIN_RULE=avoid-nic-degraded PIN_DEGRADED=nic … PIN_NIC_CPUS=none PIN_NIC_EXCLUDED=n/a … PIN_NIC_IRQLINES=0` ✅ |
| `PIN_NIC_IFACE=zzz_nope` | RC=2，`PIN_FAIL PIN_NIC_IFACE=zzz_nope 不在 /sys/class/net 里` ✅（额外测） |

**topo 形态**：review 说过"`thread_siblings_list` 读不到 ⇒ `PIN_DEGRADED=topo`"，我**自写**了一个
`LD_PRELOAD` 垫片（拦截 `fopen`，路径含 `thread_siblings_list` ⇒ 返回 NULL），**并用自写探针证明垫片真的生效**：

```
no preload : PROBE_FOPEN=OK content=0,4
with preload: PROBE_FOPEN=DENIED            ← "注入过" 与 "测到了" 分开
```

同命令加垫片后：`PIN_RULE=avoid-nic-degraded PIN_DEGRADED=topo PIN_CPU=6 … PIN_NIC_EXCLUDED=0,1,2,3,4,5 PIN_CORE_LOAD=103443`
（无垫片对照 = `avoid-nic / none / PIN_CPU=5 / CORE_LOAD=10569762`）。
⇒ 退化**确实响亮**（`avoid-nic-degraded` + `topo`），且**语义确实变了**（选到与扛中断线程同物理核的 CPU6）——
这正是该字段要暴露的东西。✅

### A3 —— F3 选核（**用我自己写的解析器**）✅ **通过：7/7 字段逐字对上**

自己抓 `/proc/softirqs` + `/proc/interrupts` + `thread_siblings_list` + `online`，**自写解析器**复算
（NIC 接口名还从 `/proc/interrupts` 的 desc 文本里**自己推**出来 = `enp1s0f0np0,enp1s0f1np1`，没抄交付方的 `net.raw`）：

| 字段 | 工具报的 | 我复算的 | |
|---|---|---|---|
| `PIN_NIC_CPUS` | `0,1,2,3,4,5` | `0,1,2,3,4,5` | ✅ |
| `PIN_CORE_LOAD` | `10569762` | `10569762` | ✅ **逐字** |
| `PIN_NIC_EXCLUDED` | `none` | `none`（真退化分支：全 4 个物理核都有 NIC IRQ ⇒ 排除不了 ⇒ 全体入选） | ✅ |
| `PIN_NIC_IRQLINES` | `12` | `12` | ✅ |
| `PIN_CPU` | `5` | `5` | ✅ |
| `PIN_ALLOWED_MASK` | `20` | `20`（= 1<<5） | ✅ |
| `PIN_CORES_ONLINE` | `0-7` | `0-7` | ✅ |

附：`core_load = {pc0:11288344, pc1:10569762, pc2:34818409, pc3:12101638}` ⇒ 取 pc1；pc1 内 `own/sib` = `cpu1(19243922/829651)`、`cpu5(829651/19243922)`
⇒ **own-first 取 5**、**sib-first 会取 1（= 实际扛中断那条）** ⇒ **`PIN_TUPLE_ORDER=own_sib_t` 这个字段是承重的，不是装饰**。
⚠️ **新发现（写进 §5）**：本次会话稍后（09:15）同一默认臂改选 **CPU 4** —— 我用**自己的解析器**复算确认**工具是对的**
（pc0 的 `core_load=13384202` 已 < pc1 的 `13525391`，因为我自己那批回环/测速流量把 cpu4/cpu5 的 NET_* 抬起来了）。
⇒ **选核规则本身确定性**，但**取值随 `/proc` 计数器漂移**（见 A8）。

### A4 —— F6 ✅ `grep -c PIN_AVOID` = **0**（绑核臂与 `--no-pin` 臂都是 0）
源码侧只有 1 处 `PIN_AVOID`，且**在注释里**（`p7b_affinity.h:107` 的"F6 已删"说明）⇒ 无发射路径。

### A5 —— naive 判据 ✅
`grep -oE "PIN_CPU=[0-9]+"`：绑核臂命中 **1 处**（`PIN_CPU=5`）；`--no-pin` 臂命中 **0 处**，
且 `UNPINNED=1` 在**启动行与结束行都打了**（`PIN_GETCPU_END=6 … UNPINNED=1`）。
`PIN_RULE=none`（env 臂）同样 `PIN_CPU=none` + `UNPINNED=1` ⇒ 未绑**不会被读成已绑**。✅

### A6 —— F9 频率轨迹 ✅（**是轨迹不是常量**，且独立读数交叉核过）
回环 8 s 满速跑（**不碰 10G 口**）：`UDP_T …` 的**行尾**字段 = `CPU_FREQ_KHZ=`，同一次跑内 **6 个不同值**
（`3899893 / 3899903 / 3899908 / 3899914 / 3899931(×2) / 3899932`）。
我的**独立采样器**（同跑期间每 0.5 s `cat .../cpu{4,5,6}/cpufreq/scaling_cur_freq`）读 cpu5 = `3.879–3.905 GHz`，与工具值同带。
**负对照**：同采样器里 cpu4/cpu6（空闲）反复读到 **`800000`** ⇒ 仪器有量程、不是卡死值。✅

### A7 —— F8 构建可复现 ⚠️→✅ 见 §2（独立结论）

### A8 —— 确定性 ✅（但要分开读两个字段）

| 连跑# | `PIN_CPU` | `PIN_ALLOWED_MASK` | `PIN_CORE_LOAD` |
|---|---|---|---|
| 1 | 5 | 20 | 10573319 |
| 2 | 5 | 20 | 10575079 |
| 3 | 5 | 20 | 10576839 |
| 4 | 5 | 20 | 10578599 |
| 5 | 5 | 20 | 10580359 |

`PIN_CPU` / `PIN_ALLOWED_MASK` **逐次相同** ✅。`PIN_CORE_LOAD` **逐次不同**（+1760/跑）——
但这是**累积计数器语义**，不是选择不确定：**+1760 恰好等于那一跑自己发出的回环包数**
（同参数跑自报 `UDP_SUM pkts=1760`），实测三档：`--seconds 0.1` Δ=**38048**（该跑 pkts=**38048**，逐字相等）、
`0.5` Δ=**191872**（pkts=**191872**，逐字相等）、`1.0` Δ=357211（该跑 pkts=383360，**93%**，未逐字相等 —— 如实登记）。
⇒ 结论：**选择确定；`CORE_LOAD` 是"读到就跑"的活计数器**（下游别拿它当常量）。

**A 段停止条件检查**：A1/A2/A3/A5 **全过** ⇒ 进入 B 段。

---

## §2 F8 的**独立结论**：**能逐字节复现**（部署件 7/7）

**我的命令（唯一改动 = 换到自己的目录）**：`cd /tmp/iverify/rb3 && g++ -O2 -o <name> <name>.cpp`（源 = 从 `/tmp/p7b_biz/` 复制的部署件源）

| 产物 | 重编 md5 | 部署 md5 | |
|---|---|---|---|
| p7b_tcp_sink | `10906f39…` | `10906f39…` | **MATCH** |
| p7b_tcp_src | `e1261ef4…` | `e1261ef4…` | **MATCH** |
| p7b_udp_src | `0be6a66e…` | `0be6a66e…` | **MATCH** |
| p7b_tcp_src_fix | `754e2dfe…` | `754e2dfe…` | **MATCH** |
| p7b_tcp_sink_rate | `c90808c5…` | `c90808c5…` | **MATCH** |
| p7b_tcp_src_rate | `2ab00584…` | `2ab00584…` | **MATCH** |
| p7b_tcp_src_diag | `732f1337…` | `732f1337…` | **MATCH** |

`cmp` 对 `p7b_tcp_sink`/`p7b_udp_src` 逐字节 0 差异；同源码**重编两次**（rb1/rb2）也彼此相同。
⇒ **答"能不能逐字节复现"：能（现役部署件，7/7）。**

**争议件 97,760 的独立结论（这是我自己的追查，不是照抄哪一方的说法）**：

1. 争议发生在**修前的旧源码**世代（现役二进制已是 102,216/102,328 一档，`-O2` 与部署件逐字节相同）。
2. 我在机器上找到了争议件：`/tmp/aff_audit/rb/m.bin` = **97,760 B**，md5 `49495ca1a67da40777053d8cf8875c87`。
   同目录还有 `t2.bin`(97,672) / `rb_sink_O2`(97,672) / `rb_sink_mut` / `hyp/hyp_sink`（= 审查自己的变异实验件）。
3. **关键**：该目录里的 `p7b_affinity.h` md5 = `ef802bd0…` 而 `/tmp/p7b_afftest/oldbuild/` 里的 = `42fe4e44…`；
   `diff` 出**一处真实突变：`PIN_FAIL` → `PIN_FAIX`** ⇒ **审查方的"重编"用的是被改过的头，与部署件不同源**。
4. 我用**干净旧头**（`42fe4e44…`）+ 旧源重编 ⇒ **97,800 B / md5 `9513cad5…`** = **`BUILD.md` §4 声称的"修前部署件"指纹**，逐字节复现。
5. 97,760 **我复现不出来**：拿旧源/变异头各扫 10+ 组旗标（`-O2` / `-O2 -std=c++17` / `-O3 -std=c++17` / `-O2 -fno-plt` / `-O2 -fcf-protection=none` / `-O1/-Os/-O0` …）得到的是
   `97,800 / 97,672 / 104,672 / 97,728 / 98,120 / 102,088 …`，**没有 97,760**。

⇒ **裁定（我自己的）**：`-O2` 这一档**字节可复现**（新旧两代都复现出来了）；审查报的
"部署 97,800 vs 最好重编 97,760"**不是同一组输入的对比**（其件所在目录含突变头，其 `rb_sink_O2`=97,672 是 `-O2 -std=c++17` 的产物）。
⛔ 判身份**以 md5 为准**（1/5、4/6/7 存在同尺寸不同二进制）。

---

## §3 B 段数据表

**B0 前置（全部通过）**：重烧 r6-fix **两次**（每次 `End of startup status: HIGH`）→ PCIe **设备级**
`remove`+`rescan` 一次成功（`LnkSta: Speed 5GT/s, Width x4`）→ `0x00=0x50360001 / 0x04=0x00000011 / 0x11C=0xffffffff` → `carrier=1`、`ping 2/2 rtt 0.107 ms`。
⚠️ **一个细节**：重烧后 `0x08` **自读为 `0x0`**（新配置清 SCRATCH/TX_DIS 锁存）⇒ B0 那条"写 `0x08 w 0x0`"**无需执行即已成立**（我按纪律把读出值当见证，不假设）。

### B1 下行四臂（`CONNS=30 SECS=25 PCAP_ON=0 BID_EXPECT=0x00000011`；臂间不重烧，每跑开/收各核 BID）

| 臂 | 跑 | `agg_Mbps`（`SINK_SUM`） | 见证（原文节选） | BID 开场/收场 |
|---|---|---|---|---|
| **C1** `--no-pin` | r1 | **3805.036** | `PIN_RULE=none … PIN_CPU=none … PIN_ALLOWED_MASK=ff PIN_GETCPU_START=4 … UNPINNED=1 … PIN_TUPLE_ORDER=n/a` | `0x11`/`0x11` |
| | r2 | 3743.314 | 同上（`PIN_GETCPU_START=2`） | `0x11`/`0x11` |
| **C2** 默认 | r1 | **3894.104** | `PIN_RULE=avoid-nic PIN_DEGRADED=none PIN_CPU=5 … PIN_CORE_LOAD=12128245 PIN_ALLOWED_MASK=20 PIN_GETCPU_START=5 … PIN_TUPLE_ORDER=own_sib_t` | `0x11`/`0x11` |
| | r2 | 3853.506 | 同上（`CORE_LOAD=12130148`） | `0x11`/`0x11` |
| **C3** `--core 1` | r1 | **3589.147** | `PIN_RULE=core … PIN_CPU=1 … PIN_CORE_LOAD=n/a PIN_ALLOWED_MASK=2 PIN_GETCPU_START=1 … PIN_TUPLE_ORDER=n/a` | `0x11`/`0x11` |
| | r2 | 3401.995 | 同上 | `0x11`/`0x11` |
| **C4** `--core 4` | r1 | **3885.580** | `PIN_RULE=core … PIN_CPU=4 … PIN_ALLOWED_MASK=10 PIN_GETCPU_START=4` | `0x11`/`0x11` |
| | r2 | 3710.109 | 同上 | `0x11`/`0x11` |

全部 8 跑：`rc=0`、`fail_conns=0`、`clean_conns=30/30`、`mismatch_bytes=0`、`STC_GEOM_OK`。
每跑 `CPU_FREQ_KHZ`（sink 逐连行）**都在 3.70–3.90 GHz**，无低值（例：C2_r1 前 6 连 = `3699881/3896189/3798062/3797533/3800052/3736091`）。
⚠️ **本表读数口径**：`agg_Mbps` = sink **单线程 + 逐字节图案复算**下的**台架受限读数**，
`wall_s` 仅 65–74 ms（30 MB）⇒ **不是板子能力**；臂间差 ≤14%，被台架帽压在 3.40–3.89 带内。

### B1′ 台架帽探针（同一接收路径，只关掉逐字节复算；`SINK=p7b_tcp_sink_rate SINK_EXTRA=--nocheck`）

| 臂 | agg_Mbps |
|---|---|
| 绑核（默认 → `PIN_CPU=4`） | 6445.435 / 6654.446 |
| **不绑核** `--no-pin` | **6835.612 / 7084.711** |

### B2 上行 warm-up 判别（`PIN_CORE`/`PIN_RULE` 经 env 驱动；`BIN=./p7b_tcp_src_fix`；`SECS=6`；每臂**连续 6 跑**）

**前置 = 重烧后的冷态**（C1 的 r1 是这一烧的**第一跑**，复刻 #58 的"换烧后"条件）。

| 臂（`PIN_*` 原文见下） | 6 跑 `tx_Mbps`（peer 口径，顺序） | 中位 | 极差 | 板侧口径（`ΔW53/(ΔW5/156.25e6)`, k=0）中位 |
|---|---|---|---|---|
| **C1** `--no-pin` | 4064.4 / 4139.9 / 4029.6 / 4150.1 / 4050.0 / 4152.0 | 4102.2 | **3.0%** | 4080.4 |
| **C2** 默认（本会话 → `PIN_CPU=4`） | 4066.7 / 4071.0 / 4104.0 / 3723.4 / 4083.2 / 3721.7 | 4068.9 | **9.4%** | 4047.3 |
| **C3** `--core 1` | 3983.7 / 4074.0 / 4076.0 / 4063.8 / 4162.0 / **2821.0** | 4068.9 | **33.0%** | 4053.0 |
| **C4** `--core 4` | 4065.0 / 4078.6 / 3740.0 / 3736.6 / 4159.1 / 3745.4 | 3905.2 | **10.8%** | 3883.8 |
| **C1b** 对照（`--no-pin`，**会话末尾** 3 跑） | 4151.0 / 4150.5 / 4075.2 | 4150.5 | 1.8% | 4128.4 |

**每跑 `PIN_*` 原文（r1）**：
- C1：`PIN_RULE=none PIN_DEGRADED=n/a PIN_CPU=none … PIN_ALLOWED_MASK=ff PIN_GETCPU_START=2 PIN_FREQ_START_KHZ=3898070 PIN_GOV=schedutil UNPINNED=1 … PIN_TUPLE_ORDER=n/a`
- C2：`PIN_RULE=avoid-nic PIN_DEGRADED=none PIN_CPU=4 … PIN_CORE_LOAD=12325864 PIN_ALLOWED_MASK=10 PIN_FREQ_START_KHZ=3901784 … PIN_TUPLE_ORDER=own_sib_t`
- C3：`PIN_RULE=core PIN_DEGRADED=n/a PIN_CPU=1 … PIN_ALLOWED_MASK=2 PIN_FREQ_START_KHZ=3701983 … PIN_TUPLE_ORDER=n/a`
- C4：`PIN_RULE=core PIN_DEGRADED=n/a PIN_CPU=4 … PIN_ALLOWED_MASK=10 PIN_FREQ_START_KHZ=3895401 … PIN_TUPLE_ORDER=n/a`
- C1b：`PIN_RULE=none … PIN_CPU=none … UNPINNED=1`

**频率轨迹（每跑的 `CPU_FREQ_KHZ` 均值 / 最小）vs 速率**：

| tag | Mbps | freq 均值 | freq 最小 | 唯一值个数 |
|---|---|---|---|---|
| ULC1_r1（冷态第一跑） | 4064.4 | 3799148 | 3797999 | 5 |
| ULC1_r6 | 4152.0 | 3871057 | 3780756 | 5 |
| ULC2_r6 | 3721.7 | 3866292 | 3775332 | 5 |
| ULC3_r5 | 4162.0 | 3897878 | 3895708 | 5 |
| **ULC3_r6（最慢跑）** | **2821.0** | **3898297（最高）** | 3895454 | 5 |
| ULC4_r3 | 3740.0 | 3878024 | 3797902 | 5 |

（全 27 跑的表见 §6 复现命令；**没有一跑的 freq 均值低于 3.76 GHz**，最慢跑的 freq 反而最高）

**板侧/对端口径一致性**：27/27 跑 `ΔW53_raw` 与对端 64 位 `tx_bytes` 吻合 **−0.51% ~ −0.58%**（系统性、方向一致，
来自两口径的时长定义差：板侧 `ΔW5/156.25e6 = 6.03 s` vs 对端 `dur_s = 6.000 s`）；
`k=0` **全部成立**（判 k 的口径 = 对端 64 位独立读数，**不是**我自己的启发式阈值 —— 初版用"速率<3000 就试 k=1"的
启发式曾把 `ULC3_r6` 误判成回卷，被对端 `tx_bytes` 当场驳回：该跑 `ΔW53_raw = 2,115,829,760` **逐字等于**对端 `tx_bytes`）。
⚠️ **本轮的余量很薄**：W53 的**绝对读数**已到 **4,292,532,008**（距 `2³²` 仅 **0.06%**）⇒ 6.03 s 窗下 **>5.70 Gbps 必回卷**；
`W54 ≡ 0`（27/27 跑，≈84 GB 上行逐字节）。

**B4 收尾**：`0x08 w 0x2` ⇒ `0x08=0x00000002`、`CARRIER=0`、`0x04=0x00000011`、`0x11C=0xffffffff`（受控停流终态，与交接口径一致）。

---

## §4 warm-up 判别结论（**只到"支持/不支持"**）

**① warm-up 本身：今天没有复现 —— 这是最强的读数。**
换烧后**第一跑** = `4064.4 Mbps`（= 平台值），6 跑**没有任何单调爬升**（`4064→4140→4030→4150→4050→4152`）；
会话末尾的 C1b 对照（`4151.0/4150.5/4075.2`）与开头 C1 同带。
⇒ 与 #58 记的 `1379.5 → 2927.7 → 3982.4` **形态完全不同**。**#58 不是"换烧后必然发生"的事件**（至少今天不是）。

**② 三个候选机制，逐个查（都不可见）：**
- **爬频** = **不支持（有直接负证据）**：冷态第一跑的 freq 已经是 `3.79–3.91 GHz`（`PIN_FREQ_START_KHZ=3898070`），
  且最慢的那一跑（2821 Mbps）freq 均值**最高**（3.898 GHz）⇒ **速率变化解释不了频率，频率也解释不了速率**。
- **核心迁移** = **不支持**：`--no-pin` 臂（允许迁移）**极差最小（3.0%）**、中位最高；对照组最稳。
- **与软中断抢核** = **不支持**：`--core 1`（**就是扛 sfc 中断的那条线程**）2 跑都在 3984/4074，与 `--core 4`、`--no-pin` 同带；
  且**分布更差**（一个 2821 的离群）—— 抢核没有带来系统性降级，绑核也没有带来系统性收益。

**③ 台架帽 = 逐字节复算，不是抢核** = **不支持"抢核造成台架帽"**：
同一路径关掉复算后 `agg` 从 3.4–3.9 抬到 **6.4–7.1 Gbps**，而**不绑核那一臂反而更快**（6836/7085 vs 6445/6654）。
⇒ 帽子的成因是 **sink 单线程的 per-byte 图案复算**，与"绑不绑核/绑哪条核"无关。

**④ 绑核降方差？** = **本次数据不支持**：绑核臂 C2/C3/C4 的极差（9.4%/33%/10.8%）**都 ≥** 不绑核 C1（3.0%）。
（n=6；低速率离群（3.72/3.74/2.82 Gbps）只出现在绑核臂，但样本太小，**只登记形态，不作结论**。）

**⑤ 结论口径（不许越界）**：
- "warm-up 由迁移+抢核+爬频造成" ⇒ **不支持**（今天的读数里**前提不成立**：没有 warm-up 可归因；两个机制各自也都被单独否掉）。
- ⛔ **不等于"该假说被证伪"** —— 我没有拿到"warm-up 出现且机制是 X"的正例，也没有拿到"warm-up 出现但不含 X"的反例。
  正确措辞：**#58 在本会话不可复现，故其机理仍属"未定位"**。
- "台架帽由抢核造成" ⇒ **不支持**；成因指向 **sink 的逐字节复算**（有定量对照）。
- ⛔ **不许**写成"绑核有性能收益 / 绑核消除 warm-up" —— 两项都没有被今天的读数支持。

---

## §5 未测 / 不确定（**不填空**）

1. **#58 的机理** —— **未定位**（今天没复现 ⇒ 无从归因）。且 **warm-up 是否与"主机的冷/热状态"耦合**（如更彻底的空闲、
   `intel_pstate` 状态机、其他进程）**未测**：我只复刻了"换烧"这一个条件。
2. **A 段任务的样本限制未破**：B2 每臂 n=6 ⇒ 只到"支持/不支持"。
3. **自动选核的取值不平稳** —— 本会话内实测 **CPU5（09:00）→ CPU4（09:15）**；
   我用**自写解析器**确认**两次工具都没错**（`/proc` 计数器变了）⇒ 这是语义特性而非缺陷，
   但**"默认臂一定会选到哪个核"不可跨会话假定**（下游若把 `PIN_CPU=5` 写进判据会假红）。**机理侧**：
   是**我自己的测速/回环流量**改变了 `NET_*` 分布（cpu4: 18030→858796；cpu5: 829635→2385348）—— 归因**只有相关，无对照实验**。
4. **B1 臂间差异的成因** —— **未测**：4 臂都压在台架帽内（3.40–3.89），差异 ≤14%，n=2 ⇒ 不足以说哪个臂"更好"。
5. **板子真实长流天花板** —— **仍未测**（本轮下行用的都是带复算的 sink 或 `--nocheck` 短流；
   与既有登记同口径："只有下界"）。
6. **`--nocheck` 臂 n=2**（绑核/不绑核各 2 跑）⇒ "不绑核更快"这条**只到"不支持抢核假说"**，不作性能结论。
7. **97,760 那件到底怎么来的** —— **未复现、未定位**（只知道它坐在一个含突变头的目录里，且不是 `-O2` 家族的任何一组旗标）。
8. **`thread_siblings_list` 的 topo 退化**是用 **LD_PRELOAD 垫片**造出来的（垫片自身经探针验证生效），
   与"真的读不到那个 sysfs 文件"（例如内核配置差异）**不是同一条路径** —— 我**没有**在真缺件的内核上测过。

---

## §6 复现命令（可照抄）

```bash
PY=/c/Users/zhxue/anaconda3/python.exe   # 对端命令一律 PEER_PW=111111 + --sudo；reg_rw 需 root

# A1/A2/A5/A8（对端）           cd /tmp/p7b_biz
./p7b_udp_src --core 4294967296 --host 127.0.0.1 --port 9999 --seconds 0.3 --paylen 64 --mbps 5   # 期望 RC=2
PIN_NIC_IFACE=lo ./p7b_udp_src --host 127.0.0.1 --port 9999 --seconds 0.3 --paylen 64 --mbps 5  # 期望 avoid-nic-degraded/nic
LD_PRELOAD=/tmp/iverify/mine_deny_sib.so ./p7b_udp_src --host 127.0.0.1 ...                      # 期望 -degraded/topo

# A7（对端）  cd /tmp/iverify/rb3 && g++ -O2 -o p7b_tcp_sink p7b_tcp_sink.cpp && md5sum p7b_tcp_sink  # 期望 10906f39…

# B0 烧录（本机，launcher 模式：MSYS_NO_PATHCONV 必须**不存在**才能用 cmd //c）
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g_fix\_proj_10g\notes\p7b_retxfix\burn_r6fix.bat'   # 判据 End of startup status: HIGH
#   ⛔ 2026-10-09 订正：`udp_hls_10g_fix` 树已删除 ⇒ 上面这行按**历史**读（当时可跑）。现役烧法 =
#   TCPREG_BIT='D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_retxfix_salvage\bits\8c8b6126__wrapper_p4.bit' \
#     cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_biz_tcpreg\run_program_tcpreg.bat'
#   （⚠️ 保全件 `…\p7b_retxfix_salvage\burn_r6fix.bat` 按原样保全、内部仍指旧树 ⇒ **直接跑会白跑**）
PEER_PW=… $PY tools/peer_ssh.py --sudo 'echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove; sleep 2; echo 1 > /sys/bus/pci/rescan'

# B1（对端）  cd /tmp/p7b_biz
CONNS=30 SECS=25 TAG=C2_r1 PCAP_ON=0 BID_EXPECT=0x00000011 SINK_EXTRA='--core 1' bash stc_dl.sh
# 台架帽探针：… SINK=./p7b_tcp_sink_rate SINK_EXTRA='--no-pin --nocheck' bash stc_dl.sh

# B2（对端）  cd /tmp/p7b_biz   （j6_r6fix.sh = 仓内 j6_stagec.sh 的 3 行 BID 派生）
PIN_RULE=none BIN=./p7b_tcp_src_fix bash j6_r6fix.sh 6 /tmp/iv_ULC1_r1.pcap ULC1_r1
PIN_CORE=1    BIN=./p7b_tcp_src_fix bash j6_r6fix.sh 6 /tmp/iv_ULC3_r1.pcap ULC3_r1
# B4 收尾：reg_rw /dev/xdma0_user 0x08 w 0x2   ⇒ carrier=0
```

---

## §7 我引入的环境改动（全部运行时；不影响上述读数）

| 改动 | 位置 | 备注 |
|---|---|---|
| `j6_r6fix.sh`（新件） | 仓内 `_proj_10g/notes/p7b_affinity/` + 对端 `/tmp/p7b_biz/` | 见 §0；3 行 diff |
| `j6_stagea.sh` 覆盖为仓内现版 | 对端 `/tmp/p7b_biz/` | `0158ba1e…` → `c6b27b1b…`（纪律要求） |
| `mine_deny_sib.c/.so`、`probe_fopen` | 对端 `/tmp/iverify/` | 我的 topo 退化垫片 + 有效性探针（非交付件） |
| `burn_r6fix.bat` / `burn_r6fix_stdout.log` | `udp_hls_10g_fix/_proj_10g/notes/p7b_retxfix/`（⛔ 2026-10-09 起：该树已删 ⇒ 现路径 = `udp_hls_10g\_proj_10g\notes\p7b_retxfix_salvage\burn_r6fix.bat`；⚠️ 其内部三条路径仍指旧树，**用前必改**） | 烧录 launcher（照抄 `program_tcpreg_ku5p.tcl`，`TCPREG_BIT` 指 r6fix） |
| 对端 `/tmp/iverify/*.log`、`/tmp/iv_ULC*.pcap`、`/tmp/sink_*`、`/tmp/ss_*`、`/tmp/cpu_*` | 对端 /tmp | 本轮原始件（**在盘**） |
| PCIe `remove`+`rescan`（设备级，两次） | 对端 | 每次重烧后恢复端点（`LnkSta x4`） |

⛔ **未碰**：板载 QSPI、任何 RTL/脚本（`stc_dl.sh`/`p7b_snap.sh`/`j6_stagec.sh` 一行未改）、
`udp_hls_10g_fix` 的源码树（⛔ 2026-10-09 订正：**该树已删除** ⇒ 本行按历史读；其位流/取证已保全到 `udp_hls_10g\_proj_10g\notes\p7b_retxfix_salvage\`）、`/tmp/p7b_biz` 之外的既有证据。
