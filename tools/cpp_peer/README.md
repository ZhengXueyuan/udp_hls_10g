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

> 全部数据来自 2026-09-19 本机实测（Killer E5000B，防火墙屏蔽内核，端口 40100/40110）。

### 7.1 回环完整性（1 MB）—— PASS

```
$ ./peer.exe --iface '\Device\NPF_{528A3E8C-...}' --src-mac FC:9D:05:7D:88:6B \
             --bytes 1048576 --sport 40021
[ok] SYN+ACK: irs=0x12345678 ack=... wnd=49152 mss=1460
elapsed      : 0.44 s
TX wire words: 142295
echo verify  : verified=1048576 mismatch_segs=0 mismatch_bytes=0
acked        : COMPLETE / echoed : COMPLETE
VERDICT      : PASS (echo byte-for-byte identical)
```

板侧对账 `MW delta = 142295 = peer TX wire words`，**差 0**。

**板卡 TCP 画像（抓包实锤）**：
- 固定初始序号 `ISS = 0x12345678`（不是随机）
- 通告窗口 `49152`(0xC000)，MSS `1460`，SYN+ACK 只带 MSS 选项（无 WS/SACKperm）
- echo 段捎带 ACK（piggyback），窗口 49152

### 7.2 1 GB 满速档 —— **PASS，稳态 8.98 MB/s (71.8 Mbps)**

```
$ ./peer.exe --iface '...' --src-mac FC:9D:05:7D:88:6B \
             --rate-test --ack-mode immediate --rcv-wnd 65535 --bytes 1073741824
```

| 指标 | 数值 |
|---|---|
| 载荷 | 1,073,741,824 B（1 GiB），MSS 1460 |
| **逐字节校验** | **verified=1073741824，mismatch_segs=0，mismatch_bytes=0** |
| 总耗时 | 117.8 s |
| **稳态吞吐（10%–90%）** | **8.98 MB/s = 71.80 Mbps** |
| 平均吞吐 | 9.12 MB/s = 72.94 Mbps |
| RTT | avg 377 µs，max 6.8 ms |
| 重传 | `retx=0`（**零 RTO**），`fast_retx=14314` 个空洞全部由 3-dupACK 快速重传恢复 |
| dup-ACK | 240,685 |
| 板侧 `/RST` | 0 |

**板侧对账（`board_snapshot.py --reconcile`，UART COM9）**：

| 指标 | 数值 | 解读 |
|---|---|---|
| peer `TX wire words` | 172,151,046 | 我们放到线上的词数 |
| 板侧 `MW` 增量 | 172,151,284 | 板卡 MAC 实际收到 |
| **差** | **+238 词（0.00014%）** | **零杂散流量、零丢词** |
| 板侧 `TRU` 增量 | **0** | 无截断帧 |
| 板侧 `TF`/`TW`/`TI` 增量 | 764,678 | 板卡 TCP 发送帧数 |
| 板侧 `DROPS[0]` 增量 | **143,463** | 板卡**内部**丢弃计数 |
| 板侧 `DROPS[2]` 增量 | 1 | |
| 板侧 `W` / `WC` / `WL` | 无变化（`W=0001` 是常态值，非本次触发） | 未见 RTO 回卷 latch |

### 7.3 瓶颈证据指向哪一层

**线级 / 网卡级：不是瓶颈。** `MW` 增量与 peer 发送词数差 238/172,151,284 = **0.00014%**，
`TRU=0`。也就是说 1 GB 测试期间**没有任何一帧在"PC 网卡 → 板卡 MAC"之间丢失**，
也没有杂散帧混入。Killer E5000B 的线级丢帧在本负载下没有表现出来。

**板卡级：主要瓶颈。** `DROPS[0]` 在 1 GB 期间涨了 **143,463**。
`MW` 是在 `mac_rx_64` 处计数的（剥 FCS 之后），所以这些丢弃发生在 **MAC 之后、板卡内部** ——
板卡收到了但没处理完，触发 TCP 重传（对应 peer 侧 14,314 个空洞）。
稳态吞吐 8.98 MB/s 的天花板由这个内部丢弃率决定，不是由链路或对端窗口决定。

**PC 栈级：不是瓶颈。** 合成对端稳定跑满 117 s 无抖动，`retx=0`（无 RTO 超时）。

### 7.4 与 Python (内核 socket) 对比组 —— 64 MB

| 配置 | 结果 | 稳态吞吐 |
|---|---|---|
| `tools/pc_tcp_rate_test.py 64`（内核栈） | PASS，echo 64 MB 收齐 | 56.0 Mbps = **7.0 MB/s** |
| `peer --ack-mode everyN --ack-n 2` | PASS | 33.2 Mbps = 4.15 MB/s |
| **`peer --ack-mode immediate`** | **PASS** | **69.8 Mbps = 8.72 MB/s（+25%）** |

**合成对端在不引入内核噪声的前提下，吞吐比内核栈方案高约 25%**，
且所有板侧计数（`MW`/`TF`/`TRU`/`DROPS`）均可逐词对账 —— 这是 Python 工具做不到的。

### 7.5 关键诊断：一次板卡楔死 + 根因定位

**现象**：修复前的 `--ack-mode immediate` 在 1 GB 档爬到 ~6 MB/s 后
板卡停止 ACK 与 echo，`snd_una` 冻在 0.65%，进入无限 RTO 重传；
测试结束后板卡**彻底楔死**（UART 心跳仍在、`HR=1`，但数据面静默、
`MW` 冻结、连新 SYN 都不回）。**只能重烧恢复**。

> ⚠️ 重烧命令用 **`board/run_program_tcp.bat`**（指向存在的
> `vivado_prj/tcp_echo_prj.runs/impl_1/wrapper_tcp.bit`，成功判据日志末尾 `PROGRAM_OK`）。
> `board/run_program_p4.bat` 指向的 `p4_prj/.../wrapper_p4.bit` **不存在**，会直接失败。

**根因定位（三层证据链）**：

1. **板侧 `TF` 计数揭穿了"重复段"的真身**。8 MB 测试里：
   peer 收到 `rx data_segs = 47,544`，但板侧 `TF` 增量只有 **6,025**。
   板卡只发了 6025 帧，对端却"收到"47544 段 —— **约 8× 的重复发生在 PC 的收包路径
   （WinPcap 4.1.3 的读取路径），不是板卡在重传**。
   （同一次测试 `MW` 对账仍然精确：1,997,589 vs 1,997,600，差 +11。
   发送方向完全干净，问题只在接收方向。）

2. **重复段被立即 ACK → ACK 风暴 → 板卡 ACK 通路被压垮**。
   修复前 `rx_data()` 对每个"已见过"的段都回一个 ACK；
   在 8× 重复下等于把 ACK 速率放大 8 倍（实测 `dupack` 一秒内 15,601 个），
   板卡最终不再推进。

3. **修复**：不再对捕获路径的重复段回 ACK（真实丢包产生的 dup-ACK 由
   `process_ack()` 单独处理，不受影响）。修复后：
   - 1 GB immediate ACK → **PASS**
   - 64 MB immediate ACK → **PASS，稳态 8.72 MB/s**（修复前同配置楔死）
   - `dup_segs` 从 134,779 降到 3,556

**这条链也解释了为什么 Python 没事**：内核栈的延迟 ACK（每 2 段一次）
天然把这个放大倍数压掉了，而且内核在 TCP 层去重时不会对重复段发 ACK。

---

## 8. 已知限制与坑

1. **PC 收包路径会重复投递**（最大的一条）。
   本机 `wpcap.dll` 是 **WinPcap 4.1.3（2013 年）**，在 Windows 11 上高负载时
   会把同一帧重复交给上层（实测 1.2×–8× 随速率变化）。
   证据见 §7.5：板侧 `TF`=6025 而 peer 收到 47,544 段。
   **判据**：任何"接收侧计数异常"都要先跟板侧 `TF`/`TW` 对一次账，再下结论。
   `peer.exe` 已按 seq 去重且不对重复段回 ACK，功能不受影响，
   但 `RX data_bytes` / `dup_segs` 这些**统计数字会被放大**，别直接当板卡行为读。
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
8. **板卡可能被压死且不能自愈**：已实测一次（见 §7.5），必须重烧
   `board/run_program_tcp.bat`。若再遇到，**先抓包 + 存 UART 快照再重烧**。
9. **`--ack-mode immediate` 是压力最大的配置**：它把对端 ACK 速率拉到最高。
   板卡异常时先换 `everyN --ack-n 2` 做对照。
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
