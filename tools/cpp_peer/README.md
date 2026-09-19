# cpp_peer — C++ (npcap) 合成 TCP 对端测试工具

针对 `udp_hls_10g` 板卡 (192.168.100.2:8080 纯硬件 TCP fast-path echo) 的**合成 TCP 对端**。
自己用 npcap 收发裸以太网帧、自己实现 TCP，**完全不经过 Windows 内核 TCP 栈**；
配合防火墙屏蔽内核对板 IP 的处理（内核再也看不到这些帧 → 不会回 RST），
得到**零噪声**的测试环境。

本工具是 P5/P6 阶段的测试基础设施，定位**原型级**：单连接、无 SACK、无窗口缩放，
但收发/校验/统计/故障诊断链路完整可用。

---

## 1. 环境探测结果（2026-09-19，本机实测）

| 项目 | 探测命令 | 结果 | 采用 |
|---|---|---|---|
| C++ 编译器 | `where g++` / `where cl` | **都不在 PATH** | — |
| Qt MinGW | `ls C:/Qt` | **不存在**（与任务预期不符） | — |
| MSVC | `ls "C:/Program Files/Microsoft Visual Studio"` | 存在 `18/Community`，`cl.exe` 在 `VC/Tools/MSVC/14.52.36520/bin/Hostx64/x64/`（未进 PATH） | 未用 |
| MinGW | `ls C:/msys64` | **存在**，`mingw64/bin/g++.exe` = **GCC 16.1.0** | ✅ **采用** |
| pcap SDK | `ls C:/npcap-sdk` / `find -name pcap.h` | **完全没有**（无 `pcap.h`，无 `wpcap.lib`） | — |
| pcap DLL | `ls C:/Windows/System32/wpcap.dll` | **存在**（WinPcap 4.1.3，Riverbed；`npcap.sys` + `npf.sys` 两个驱动都在跑） | ✅ **直接链接 DLL** |
| 抓包设备列表 | `peer.exe --list` | 4 个设备，Killer = `\Device\NPF_{528A3E8C-9A80-4D17-96A0-48F3FD70186E}` | ✅ |

### 关键坑 1：`mingw64\bin` 必须在 PATH 里
GCC 的 `cc1.exe` 需要同目录的 DLL。PATH 里没有 `C:\msys64\mingw64\bin` 时，
`g++` 会**静默失败**（退出码 1、零输出、不生成 exe），看起来像"编译不过但不报错"。
`build.bat` 已自动把该目录加进 PATH。

### 关键坑 2：没有 SDK 也能链接
`peer.cpp` 自己声明了所需的最少 WinPcap ABI（`pcap_findalldevs` / `pcap_open_live` /
`pcap_sendpacket` / `pcap_next_ex` / `pcap_close` / `pcap_geterr` + `pcap_if_t` /
`pcap_pkthdr` 结构体），然后由 MinGW 的 `ld` **直接从 `wpcap.dll` 的导出表生成导入信息**：

```
g++ -O2 -std=c++17 -static peer.cpp -o peer.exe -lws2_32 C:/Windows/System32/wpcap.dll
```

不需要 `.lib` / `.a`。`-static` 让 exe 只依赖系统 DLL（`ldd` 实测：仅 `ntdll/KERNEL32/KERNELBASE/msvcrt`）。

### 关键坑 3：设备编号与本机其它工具不一致
`peer.exe --list` 只列出 WinPcap 能看到的 4 个设备；`tshark -D` 会列出 10 个
（多出的是 npcap 才有的"本地连接* N"虚拟适配器）。**两者编号不同**
（Killer 在 peer 里是 #2，在 tshark 里是 #8）。
所以 `--iface-idx` 的编号以 `peer.exe --list` 为准，或者干脆用 `--iface` 给全路径。

---

## 2. 构建

```bash
# cmd
D:\repo\ECO\udp_hls_10g\tools\cpp_peer\build.bat

# Git Bash
cmd //c 'D:\repo\ECO\udp_hls_10g\tools\cpp_peer\build.bat'
```

产出 `tools/cpp_peer/peer.exe`，并自动列出可见抓包设备。

---

## 3. 用法

```
peer.exe --iface <NPF路径> [options]

寻址:
  --src-ip / --dst-ip      本机 / 板卡 IP        (默认 192.168.100.1 / 192.168.100.2)
  --sport / --dport        本机 / 板卡 TCP 端口  (默认 40000 / 8080)
  --src-mac / --dst-mac    本机 / 板卡 MAC       (默认 02:..:01 / 00:0a:35:01:fe:c0)

流量:
  --bytes <n>              发送并回环校验的字节数 (默认 1048576)
  --mss <n>                分段大小              (默认 1460)
  --rcv-wnd <n>            本端通告窗口          (默认 65535；别名 --rx-window)
  --cwnd <bytes>           固定拥塞窗口；0 = 慢启动 (默认 0)

ACK 策略:
  --ack-mode immediate | everyN | delayed        (默认 immediate)
  --ack-n <n>              everyN 模式每 N 段回一次 ACK (别名 --ack-every)
  --ack-delay-us <n>       delayed 模式延迟微秒数

性能 / 批量发送:
  --tx-bench <n>           发送能力自测：满速灌 n 帧后退出（绕开 TCP 逻辑）
  --tx-batch <0|1>         用 pcap_sendqueue_transmit 批量发送 (默认 1)
  --tx-sync <0|1>          批量提交时是否等待完成 (默认 1)
  --tx-queue-kb <n>        发送队列大小 (默认 4096)
  --flush-frames <n>       每 N 帧 flush 一次 (默认 40)
  --setbuff-kb <n>         驱动接收缓冲 (默认 8192)
  --no-mintocopy           关闭 pcap_setmintocopy(0)
  --no-filter              关闭服务端 BPF 过滤

速率测试 / 诊断:
  --rate-test              1GB 档：周期性日志 + 10-90% 稳态统计
  --stats-interval-ms <n>  日志周期 (默认 1000；0 = 关闭)
  --quiet                  等价 --stats-interval-ms 0
  --no-fast-retx           关闭快速重传（只靠 RTO）

定时 / 其他:
  --rto-ms <n>             最小 RTO (默认 200)
  --stall-ms <n>           多久无进展放弃 (默认 2000)
  --syn-opts none|mss|full SYN 选项集 (默认 full = MSS+SACKperm+NOP×2)
  --seed <n>  --no-fin  --verbose  --list  --help
```

### 典型调用

```bash
# 1MB 回环完整性（最常用）
./peer.exe --iface '\Device\NPF_{528A3E8C-9A80-4D17-96A0-48F3FD70186E}' \
           --src-mac FC:9D:05:7D:88:6B --bytes 1048576

# 1GB 满速档（每秒一行速率日志）
./peer.exe --iface '\Device\NPF_{528A3E8C-...}' --src-mac FC:9D:05:7D:88:6B \
           --rate-test --ack-mode immediate --rcv-wnd 65535 --bytes 1073741824
```

---

## 4. 防火墙：把内核"关掉"

合成对端最大的障碍是**内核**：板卡回的 SYN+ACK / echo 帧会到达内核，
内核不认识这个 4 元组，于是回 RST，把板侧 TCB 打掉并污染板侧计数。

```powershell
# 屏蔽（需管理员）——默认 192.168.100.2
powershell -NoProfile -ExecutionPolicy Bypass -File fw_block.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File fw_block.ps1 -BoardIp 192.168.100.3

# 查看 / 还原
powershell -NoProfile -ExecutionPolicy Bypass -File fw_block.ps1 -Status
powershell -NoProfile -ExecutionPolicy Bypass -File fw_unblock.ps1
```

脚本参数化板卡 IP（子网随工程变），同时建**入向 + 出向** block 规则（全部协议、全部 profile），
规则名前缀 `cpp_peer_block`，重复运行会先清掉自己旧的规则。

> **注意**：block 期间内核彻底看不见板卡——`ping` 会 100% 丢包、Python `socket.connect`
> 会抛 `PermissionError`。这是**预期行为**，不是故障。跑 Python 对比测试前记得先 `fw_unblock`。

**实测（本机验证）**：

| 状态 | `ping 192.168.100.2` | Python socket connect | 合成对端 |
|---|---|---|---|
| 未屏蔽 | 通 | 通 | 通（但板侧收到内核 RST 干扰） |
| **已屏蔽** | **100% 丢包** | **PermissionError** | **PASS** |

**npcap 不受防火墙影响**：它挂在 NDIS 层（WFP 之下），抓包与注入照常。
实测屏蔽后合成对端依旧 PASS、echo 逐字节一致。

**副作用（意外收获）**：屏蔽内核顺带消掉了 RX 重复段。
未屏蔽时板侧会被内核 RST 触发重传，接收侧统计出现 `dup_segs=1859 / out_of_order=1117`；
屏蔽后同样的 146KB 测试变成 `dup_segs=0 / out_of_order=0`，接收 101 段恰好等于发送 101 段。

---

## 5. 板侧计数对账（零噪声验证）

`board_snapshot.py` 读 COM9 (9600-8N1) 的板卡快照，做测试前后差分。

```bash
# 打印一份快照
python board_snapshot.py

# 跑一次测试并自动对账（自动从 peer 输出里抓 "TX wire words"）
python board_snapshot.py --reconcile -- ./peer.exe --iface '...' --bytes 1048576
```

对账原理：peer 统计 `TX wire words = Σ ceil(帧长/8)`，
板卡 `MW` = `mac_rx_64` 剥掉 FCS 后的出词计数（8 B/词）。
两者**相等**即证明：没有杂散帧、没有丢词。

### 实测结果

| 测试 | peer TX wire words | 板侧 MW 增量 | 差 | 结论 |
|---|---|---|---|---|
| 146 KB（未屏蔽内核） | 19847 | 19858 | +11 | UART 窗口内混入 ~11 词背景流量 |
| **1 MB（未屏蔽内核）** | **142295** | **142295** | **0** | **完全一致：零杂散、零丢词** |

同一快照里还被 `board_snapshot.py` 打成 delta 的字段：
`TRU`(截断帧) / `DROPS[0..3]` / `TW`/`TF`/`TI`(TCP TX 词/帧) / `PASS` / `RXTR` /
`W`/`WC`/`WL`(latch 与窗口) / `SC`/`SD`/`SF`/`SP`/`SV`(慢路径) / `HR`(HLS 复位)。

---

## 6. 与 Python (socket) 工具链的差异

| 维度 | `tools/pc_tcp_rate_test.py`（内核栈 + socket） | `tools/cpp_peer`（合成对端 + npcap） |
|---|---|---|
| TCP 实现 | Windows 内核 | 本程序（用户态，裸帧） |
| 内核是否参与 | 是 → 自发 FIN/RST/延迟 ACK/重传 | 否（配合防火墙 → 完全静默） |
| 板侧计数污染 | 有（杂散帧混入 MW 判决窗口） | **零**（MW 逐词对账） |
| 注入段语义 | 绕过内核，其 ACK 号让内核丢段/发 challenge ACK | 全部流量都是自己的，无此问题 |
| 分段/TCP 选项控制 | 受内核策略限制 | 完全可控（MSS/SYN 选项/窗口/ACK 策略） |
| 故障注入 | 难（scapy 手工构造） | 内建：ACK 策略、RTO、拥塞窗口、丢段诊断 |
| 时序精度 | ms 级（Python） | µs 级（QPC + 独立收包线程） |
| 字节完整性校验 | 只比长度 | 逐字节比对（对端 echo 语义） |
| 上手成本 | 低 | 中（要理解"内核必须闭嘴"这件事） |

**结论**：噪声根因是"内核栈参与测试"，不是语言。C++ 的增量价值在**性能与精度**，
以及可以精确控制 TCP 行为本身。实测同一 64 MB 负载（§7.4）：
合成对端 69.8 Mbps vs 内核栈 56.0 Mbps（+25%），且板侧计数可逐词对账。

---

## 7. 实测结果

> 全部数据 2026-09-19 本机实测。**每一行都标注了 bitstream 与运行条件**
> （整改前测的是 P3 的 `wrapper_tcp.bit`，作废，见 §7.6）。

### 7.0 peer 自测能力上限（这是判据的基准线）

`--tx-bench` 完全绕开 TCP 逻辑，用 `pcap_sendqueue_transmit` 满速灌帧：

```
$ ./peer.exe --iface '...' --src-mac FC:9D:05:7D:88:6B --tx-bench 200000
frames      : 200000 in 2.461 s
rate        : 81274 fps
bandwidth   : 984.4 Mbps (123.0 MB/s) at 1514 B/frame
transmit    : 73 calls, 33709.74 us/call, 2739.7 frames/call
```

**81274 fps / 984 Mbps = 1 Gbps 线速的 ~99%**（1514 B + 20 B 前导/IFG）。
即：**peer 已不是瓶颈**，之后所有吞吐数字都是板子/链路的表现。

改造前是逐包 `pcap_sendpacket`，每次 ~80 µs，**天花板正好卡在 9 MB/s** ——
这解释了整改前 8.98 MB/s 那个数字，它测的是 peer 不是板子。

### 7.1 回环完整性（1 MB）—— PASS

板侧对账 `MW delta = 142295 = peer TX wire words`，**差 0**。

**板卡 TCP 画像（抓包实锤）**：
- 固定初始序号 `ISS = 0x12345678`（不是随机）
- 通告窗口 `49152`(0xC000)，MSS `1460`，SYN+ACK 只带 MSS 选项（无 WS/SACKperm）
- **ACK 几乎只随 echo 数据段捎带**：1 GB 跑完板侧 `TF`(741,919) − 数据帧(735,439)
  = **6,480 个非数据帧（0.9%）**，即板子基本不发纯 ACK

### 7.2 1 GB 满速档（**p4 bitstream**，`--ack-mode immediate`）—— PASS

| 指标 | 数值 |
|---|---|
| 载荷 | 1,073,741,824 B（1 GiB），MSS 1460 |
| **逐字节校验** | **verified=1073741824，mismatch=0** |
| 总耗时 | 9.669 s |
| **稳态吞吐（10%–90%）** | **111.44 MB/s = 891.55 Mbps** |
| RTT | min 64.6 µs / avg 428.7 µs / max 2.42 ms |
| 重传 | `retx=0`（零 RTO），`fast_retx=41` |
| peer TX busy | 83.5%（62777 calls × 128.65 µs） |

### 7.3 丢帧三分解（TL 要求的核心产出）

**同一趟 1 GB（p4，immediate ACK）**

| # | 度量 | 数值 | 说明 |
|---|---|---|---|
| 1 | **peer 发了几帧** | **1,484,407** 帧；其中数据段 742,484，唯一载荷 1,073,741,824 B | 重传率 = (742,484−735,439)/735,439 = **0.96%** |
| 2 | **板侧收到几帧** | `MW` 增量 **145,821,622 词** | peer `TX wire words` = 145,821,622 → **差 +0** |
| 3 | **板侧 DROPS/TRU** | `DROPS[0]` **+565**，`DROPS[1..3]` +0，`TRU` **+0** | 565 / 1,484,407 = **0.038%** |

**结论：瓶颈在"窗口 × RTT / ACK 节奏"（板侧架构），不在 peer、不在线级、不在板侧丢弃。**

证据链：
1. **不是 peer** —— `--tx-bench` 自测 81274 fps / 984 Mbps（线速 99%）；实测 TCP 路径
   `TX` 帧率 153,526 fps、busy 83.5%，仍有裕量。
2. **不是线级/网卡** —— `MW` 与 peer 发送词数**差 0**，1.48M 帧一帧不差。
   板侧 `TRU=0`（无截断）、`DROPS[0]` 仅 +565（0.038%）。
   → 不存在"peer 重传 → 板侧判 dup"的自激循环（若存在，`DROPS[0]` 会与重传帧数同量级）。
3. **不是拥塞窗** —— `cwnd` 一路涨到 **1,401,679 B**，远超实际在飞量。
4. **是板侧固定通告窗** —— 稳态 `112 MB/s × RTT 428 µs = 47.8 KB ≈ 49152`（板卡通告窗），
   即**在飞量正好顶在板卡通告窗上（97%）**。不同 `--flush-frames` 下
   `吞吐 × RTT` 恒等于 ~48 KB：

   | `--flush-frames` | RTT avg | 实测稳态 | 窗口/RTT | 达成率 |
   |---|---|---|---|---|
   | 4 | 336 µs | 112.17 MB/s | 142.9 MB/s | 78% |
   | 16 | 424 µs | 112.42 MB/s | 113.2 MB/s | **99.3%** |
   | 40 | 426 µs | 109.22 MB/s | 112.7 MB/s | 97% |
   | 100 | 428 µs | 112.42 MB/s | 112.1 MB/s | **100.3%** |

5. **为什么 RTT 高达 ~428 µs**：板子几乎不发纯 ACK，ACK 只随 echo 数据段捎带。
   要 ACK 满一个 48 KB 窗口，板子必须先把这 48 KB echo 出来 ——
   48 KB / 125 MB/s ≈ **384 µs 的串行化时间**，正是 RTT 的主要成分。
   即 **RTT ≈ 窗口/线速**，两者自洽地把吞吐锁在 ~110 MB/s。

### 7.4 线速率核算：链路其实已经满了

稳态 111.44 MB/s 载荷 ⇒ 数据帧 76,329 fps：
- 本端 TX：数据 76,329 × 1534 B(含前导/IFG) = 117.1 MB/s，ACK 76,329 × 80 B = 6.1 MB/s
  → **合计 123.2 MB/s = 985 Mbps（1 G 的 98.5%）**
- 板端 TX：echo 76,329 × 1534 B = 117.1 MB/s = **937 Mbps（93.7%）**

**两个方向都接近 1 Gbps 线速**。载荷只有 111 MB/s 是因为一半的帧是 60 B 的纯 ACK，
占线不占载荷。

### 7.5 ACK 策略实测（p4，512 MB，已修 `ack_since` bug 见 §7.6）

| 配置 | 稳态吞吐 | peer TX 帧数 | 数据段数 | 板侧观测 |
|---|---|---|---|---|
| `--ack-mode immediate` | **885.7 Mbps** | 745,540 | 373,763 | **`TRU`+0，`DROPS[0]`+565** |
| `--ack-mode everyN --ack-n 2` | **904.6 Mbps** | 567,479 | 380,936 | `TRU`+66，`DROPS[0]`+19,933 |
| `--ack-mode everyN --ack-n 4` | 845.0 Mbps | 511,444 | 415,585 | 重传增多 |
| `--ack-mode everyN --ack-n 8` | 823.1 Mbps | 481,558 | 433,058 | 重传更多 |

`everyN n=2` 稳态数字略高（+2%），但**板侧计数明显更脏**（`TRU`+66 截断帧、
`DROPS[0]`+19,933、`MW` 短 8,822 词 ≈ 46 帧）。
**推荐用 `immediate`**：吞吐只差 2%，板侧计数干净得多。

### 7.6 与 Python (内核 socket) 对比

| 方案 | bitstream | 64 MB 稳态 | 1 GB |
|---|---|---|---|
| `tools/pc_tcp_rate_test.py 64`（内核栈） | p4 | **55.4 Mbps (6.9 MB/s)** | 未跑 |
| peer `immediate`（批处理前） | P3 | 69.8 Mbps | 楔死 |
| **peer `immediate`（批处理后）** | **p4** | **837 Mbps** | **891.6 Mbps** |

合成对端约为内核栈方案的 **15×**。注意：TL 提到的内核栈 ~105 Mbps 与本次实测
55.4 Mbps 不一致 —— 本次数字标注为「p4 bitstream、`pc_tcp_rate_test.py 64`、
2026-09-19 16:5x」，差异原因未查明。

### 7.7 整改前后的重要更正

1. **整改前的 8.98 MB/s / 71.8 Mbps 作废** —— 那是 peer 逐包发送的天花板
   （~80 µs/包），且测的是 **P3 的 `wrapper_tcp.bit`**（我用错了重烧脚本）。
2. **"DROPS[0] 是吞吐天花板主因"的结论作废** —— 批处理 + p4 之后，
   1 GB 的 `DROPS[0]` 只有 +565（0.038%），而吞吐涨了 12 倍。
   之前的 +143,463 是"peer 慢 + 重复段回 ACK"的自激产物，不是板子丢帧。
3. **`everyN` 曾是空操作（逻辑 bug，已修）**：`send_ack()` 没有把 `ack_since` 清零，
   导致 `maybe_ack()` 里那个 2 ms 兜底判据恒为真 → everyN/delayed 全部退化成 immediate。
   修好后 everyN 的帧数才真的下降（745,540 → 567,479）。
4. **`wrapper_p4.bit` 在 16:26 才由 TL 构建出来**，我 16:25 首次尝试重烧时它还不存在，
   于是误用了 `wrapper_tcp.bit`。**恢复板子请务必用 `board/run_program_p4.bat`**
   并确认日志末尾 `PROGRAM_OK`。

### 7.8 关于"板子能不能到 1G"

**能跑满线速，但载荷吞吐被板侧固定通告窗锁在 ~111 MB/s。**
- 链路双向都到 ~937–985 Mbps（§7.4）
- 载荷 = 111 MB/s，缺的那部分是两个方向各 ~76,329 fps 的 ACK 帧开销 +
  板侧 49152 固定窗口 / ~428 µs RTT 的耦合
- **要再往上提，板侧必须放大通告窗（或支持 window scaling）**：当前 48 KB 窗口
  正是本链路 BDP（125 MB/s × 428 µs = 53.5 KB）的 90%，
  窗口每放大一倍、其它不变，吞吐上限就跟着翻倍

## 8. 已知限制与坑

1. **PC 收包路径会重复投递（已用 BPF 过滤缓解）**。
   本机 `wpcap.dll` 是 **WinPcap 4.1.3（2013 年）**，在 Windows 11 上高负载时
   会把同一帧重复交给上层（实测 1.2×–8× 随速率变化）。
   证据：板侧 `TF`=6025 而 peer 收到 47,544 段。
   现在默认把 4 元组匹配**下推到驱动**（`pcap_setfilter`），无关帧不再拷到用户态，
   实测 `raw == matched`（不再有重复）。**判据不变**：任何"接收侧计数异常"
   都要先跟板侧 `TF`/`TW` 对一次账再下结论。
   根治办法是换 npcap 自带的 `wpcap.dll`（本机 npcap 装的是无 API-compat 模式，没带 DLL）。
2. **单连接**，一次只跑一条 TCP 流。
3. **无窗口缩放**（板卡 SYN+ACK 不带 WS）→ 通告窗口上限 65535。
4. **无 SACK**，重传是 go-back-N。
5. **载荷图案周期 64 KiB**：`payload[off] = pat[off & 0xFFFF]`。
   好处是 ≥1 GB 传输几乎不占内存；代价是**恰好平移 64 KiB 整数倍**的错位
   无法用逐字节比对发现（整体长度校验仍能发现）。
6. **序号空间 32 位**，`--bytes` 上限 ~4 GB。
7. **UART 对账窗口**：板卡快照每 ~5 s 一行，`MW` 增量覆盖整个快照间隔，
   窗口内的背景流量（ARP/IPv6/NetBIOS）会计进差值 —— 这就是 146 KB 测试里 +11 词的来源。
   传输越大相对误差越小（1 GB 时 0.00014%）。
8. **板卡可能被压死且不能自愈**：整改前实测过一次（peer 慢 + 重复段回 ACK 的自激），
   批处理 + BPF 过滤后未再复现。恢复必须用 **`board/run_program_p4.bat`**
   （`run_program_tcp.bat` 是 P3 旧设计的 bitstream），成功判据日志末尾 `PROGRAM_OK`。
   若再遇到，**先抓包 + 存 UART 快照再重烧**，并在报告里注明"楔死时板子在跑什么"。
9. **`--ack-mode everyN` 会让板侧计数变脏**：`n=2` 稳态略高 2%，但 `TRU`/`DROPS` 明显上升
   （见 §7.5）。要干净数据用 `immediate`。
10. 乱序重组用 `std::map`（有界），高乱序下 O(log n)，原型够用。
11. `peer.exe` 需要**管理员权限**（npcap/WinPcap 打开适配器）。

---

## 9. 文件

| 文件 | 说明 |
|---|---|
| `peer.cpp` | 合成 TCP 对端（含最小 WinPcap ABI 声明，无需 SDK） |
| `build.bat` | MinGW 构建脚本（CRLF + 纯 ASCII 注释） |
| `fw_block.ps1` | 屏蔽内核对板 IP 的处理（参数化 IP，可 `-Status` / `-Remove`） |
| `fw_unblock.ps1` | 还原脚本（`fw_block.ps1 -Remove` 的薄封装） |
| `board_snapshot.py` | 读 COM9 快照 + 测试前后差分 + MW 对账 |
| `README.md` | 本文档 |
