# P7B_LONGSEND_HANDOFF —— 下一轮开工入口（2026-10-10；**本件读法优先于 `P7B_LOOP_HANDOFF.md` 的"板上现态"部分**）

> ⛔ **2026-10-10 A7 轮（构建 D+E）订正块（本件正文按"历史"读，**不改原文**）**：
> **① 板上现役 = 构建 E（BID `0x19` / sha256 `b88b2bee…a64f`）+ `0x08 = 0` + `carrier = 1`**（本件 §1 记的 A 臂 `0x16` 已过时）；
> **② 取数器默认值已更新为 NW=67 / `EXPECT_BID=0x00000019`**（本件 §3 的"默认 `0x0A` ⇒ 每读必显式传"对**旧位流**仍成立，
> 但**现役位流不必**；读 D/C/A/S3 档才要显式覆盖）；**③ 本件 §5 的"构建 B-1"（补 `win_open==0`/`frm_wait`/`txcdc 空拍` 三计数器）
> 已执行完毕**（`W63`/`W64`/`W65`/`W66` 全部上板取到读数）。
> **新入口 = `P7B_A7_HANDOFF.md`**（板上现态 / 五档位流对照表 / 重烧与环境恢复 / 本轮两条"从推断变直接测量"的结论 / 下一步精确选项）。
>
> 本件 = 本轮（长时间不停发送 TCP+UDP）收口后写的**交接入口**。三条纪律：**只走 JTAG 易失烧录（绝不写 QSPI）** ·
> **绝不 `git add -A`** · **改 RTL 与"在跑回归"互斥（全局 #57）**。
> 轮级收口件 = `P7B_LONGSEND_ACCEPT.md`（一页式 + 证据地图 + "不许当已收口"清单 + 未来计划）；
> 板级原始件 = `p7b_longsend_board/ACCEPT.md`（TCP 连续）+ `p7b_udp_longrun_20261009/`（UDP 300 s）。

---

## 1. 板上现态（**接手第一件事：核它，别信任何旧文档**）

| 项 | 值 |
|---|---|
| 位流 | **A 臂**（TCP 连续 + `WIN_CAP=0xF000` + `TX_BYTES=32'h0FFFFFFF`）· sha256 **`052c52006215a2c3d5f9d59f8c47e620e41eb20f271fbc09dabfff96330bc284`**（15,431,261 B，`SW_CRC 2c237c32`） |
| 板侧身份 | `0x04 = 0x00000016`（**BID 0x16**）· `0x00 = 0x50360001` · 63 字窗口 · `0x11C` 回 `0xffffffff` |
| 停流门 | **`0x08 = 0`（未受控停流）· `carrier = 1`** |
| 时序 | `WNS +0.021 / WHS +0.010 / 三类失败端点 0/0/0`（`p7b_build_longsend/READINGS.txt`） |

> ⚠️ **`P7B_LOOP_HANDOFF.md` §6 ①/⑬ 与 `udp_hls_10g/CLAUDE.md` 各处写的"板上现态 = r6-fix / S3 + 受控停流"全部按"历史"读**
> —— 那是 2026-10-08/09 两轮的态；本轮末已换成 A 臂（见上表）。

## 2. 位流对照表（⛔ **全部 15,431,261 B ⇒ 只有 sha256 与 BID 能分版**）

| 位流 | sha256（前 8 / 后 6） | BID | 用途 / 备注 |
|---|---|---|---|
| **A（现役）** | `052c5200…0bc284` | **`0x16`** | 本轮 TCP 连续臂；`p7b_build_longsend/A/wrapper_p4.bit` |
| **S3** | `492c3579…0dc42c` | `0x15` | 本轮**负对照臂**（发满 256 MiB−1 即 FIN）；`p7b_build_longflow/S3/wrapper_p4.bit` |
| **r6-fix** | `8c8b6126…d5baf5` | `0x11` | RETXFIX 根修（dup-ACK 环）；`p7b_retxfix_salvage/bits/8c8b6126__wrapper_p4.bit`（⚠️ 该目录的 `burn_r6fix.bat` 内部仍指已删旧树，**别直接跑**） |
| **Build 2** | `1ccbd9cd…6cdd07` | `9` | Stage C 的负对照臂（在盘：`p7b_build_stageC/baseline_archive/`） |

**烧录配方（本机）**：
```bash
# 判据 = stdout 有本次的 "End of startup status: HIGH" + 文件 mtime 是本次 + 烧后板侧 0x04 回读
MSYS_NO_PATHCONV=1 TCPREG_BIT='D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_build_longsend\A\wrapper_p4.bit' \
  cmd /c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_biz_tcpreg\run_program_tcpreg.bat'
```
⚠️ **`cmd /c` vs `cmd //c` 是条件式陷阱**：**没加** `MSYS_NO_PATHCONV=1` 时 `/c` 会被 MSYS 改写成 `C:/` ⇒ **bat 根本没跑**、
stdout 是上一 session 的陈旧件。判据必须是 **stdout 里的本次 `HIGH` 行 + mtime**（光看文件存在会中招）。
⚠️ `run_program_tcpreg.bat` 的 `TCPREG_PROG_EXIT=0` **不在 stdout 文件里**（重定向之外）⇒ 拿它当判据 = 假红。
**PCIe 恢复**：烧后设备级 `remove`+`rescan`（`0000:02:00.0`）；若开机时板跑的是厂商设计（QSPI，`1 BAR`）⇒ **连根端口 `00:1c.0` 一起**；
判别式 = `identify_bars`（`2 BARs: config 1, user 0` = 我们的）。

## 3. 身份/快照读法（对端机）

```bash
# ⛔ 工具默认 EXPECT_BID=0x0000000A（Stage C 的值）⇒ 每读必显式传！
EXPECT_BID=0x00000016 bash /tmp/p7b_biz/p7b_snap.sh id          # ID_OK + ID_UNIMPL=0xffffffff（0x11C）
bash /tmp/p7b_biz/p7b_snap.sh snap TAG 5 20 43 51 52            # 短表（快流必须短表：12 字 ~288 ms > 227 ms 流）
```
⚠️ 每次读数自证 `gen` 恰 +1；`0xffffffff` = SLVERR（不是数据）；**绝不能挑 ≥ `0x200`**（7 位译码回绕到 word 0 = MAGIC ⇒ 假 FAIL）。
⚠️ **`W51` 跨连接累积**（同一次烧录内不归零）⇒ "流内点"判据的基准必须用**该跑 `pre` 快照**的 W51。

## 4. 环境恢复五项（关机/重启后必做；原件 = `p7b_env_restore_20261009/`）

1. **对端网络前置**（每次现取，别信上次）：`ip addr add 192.168.100.100/32 dev enp1s0f1np1` +
   `ip route add 192.168.100.2/32 dev enp1s0f1np1` + **`nmcli device set enp1s0f1np1 managed no`**（根治 NM 静默冲 `/32`）；
   然后 `ip route get 192.168.100.2`（必须**不走 WiFi**）+ `cat …/carrier`。
2. **台架重部署**（`/tmp` 会被清）：`04_deploy.txt` 的 27 件逐件 `--put`（含 `lf_dl.sh` **新版**、`p7b_snap.sh`、
   3 个 `stc_*/j6_*` 台架、5 个 selftest、`p7b_udp_src` 等）⇒ 再 `05_remote_md5.txt` 逐件核 md5。
   ⚠️ **`lf_dl.sh` 本轮改过注释 ⇒ md5 已变**（旧 `8c8301aa…` → 新 **`9f2a03bacc93ac6ab730675a94eadac8`**）；
   `p7b_longsend_board/ACCEPT.md:70` 与 `05_remote_md5.txt` 记的是旧值 ⇒ **以仓内现件为准重核**。
3. **重编 8 个二进制**（`06_compile.txt` 的形状；命令以 `p7b_affinity/BUILD.md` 为准 —— 树里三条编译行互相打架）；
   ⚠️ `p7b_tcp_sink` 本轮改过（新增 `SINK_LIMITS` 见证行）⇒ 部署件 md5 记 **`c6b624205d64f1f4bd723d8fd5cc6414`**（169,392 B）+ 每跑首行应见
   `SINK_LIMITS maxbytes=… poll_ms=… stall_n=… rcvbuf=… conns=… secs=…`。
4. **5 项工具自检**：`p7b_selftest.sh` · `p7b_dualthread_selftest.sh` · `p7b_lane8_selftest.sh` · `aff_selftest.sh` · `pcap_off_dryrun.sh`。
5. **板卡侧**：重烧（§2）+ PCIe 恢复（§2）+ XDMA 驱动 probe/insmod 直到 `/dev/xdma0_user` 出现
   （`13*/14_*` 记录）；**对端网卡中断合并按口径**：跑长流必须
   `ethtool -C enp1s0f1np1 adaptive-rx off rx-usecs 0`（**#68 的"读数低第一主因"**）；
   本轮收尾态 = **off**（`12_final_state.txt`）—— 若要回到出厂默认须显式 `adaptive-rx on rx-usecs 60`（**并登记**）。
   ⚠️ 环境里还有两个静默杀手：NetworkManager（冲 `/32`）、`irqbalance` 应为 inactive。

## 5. ⛔ 下一步的精确选项（**决策权在用户**）

1. **构建 B（≈26 min，一次收口；两候选可二选一或合并）**
   - **B-1 = 补三个计数器**（`win_open==0` / `frm_wait` / `txcdc 空拍`）—— **唯一能把 ~6.7 拍/帧的等效帧周期差拆开的手段**
     （⛔ 2026-10-10 订正（口径）：原写"死拍"—— `W43` 每拍无条件 +1（`mac_tx_10g.v:330`）⇒ `P ≡ 156.25e6/fps`，
     `P − 几何` 是**等效帧周期差**、不是"线上空转"的测量；板侧无线占空计数器。全文口径 = `P7B_LONGSEND_ACCEPT.md` §4-①）。
   - **B-2 = A-minus 臂**（`TX_CONTINUOUS=1` + `WIN_CAP_5` 回 `0xBFFE`）—— **唯一能给"窗帽"一个干净判决的构架**（同长度长窗 A/B）。
2. **对端 ACK 时钟归因**（零构建）：把 ACCEPT §6-③ 的线索（同一帧数下 `TcpOutSegs` 10,313→68,650）做成受控 A/B。
3. ~~**慢路径 aging**~~ ⇒ **已取消**（其"防无界饿死"的动机已被板级实测证伪；见 `P7B_LONGSEND_DESIGN.md` §5.2）。
4. **待核项**（低成本，各自独立）：`W13` learn 窗非 0 且 L1≠L2（`tables.txt:14-15` vs `:77`）·
   `W29/W45` ≈900/s 机理 · `rtl/tcp_rx.v:284` 注释"回绕安全"措辞过宽 · G3 门修复 · `A7` 静默形态（最小修法 = +1 FF pending 位）。

## 6. 本轮"最容易踩"的十条（详版 = `P7B_LONGSEND_ACCEPT.md` §4/§5）

1. **两臂/多臂位流同为 15,431,261 B** ⇒ 只有 **sha256 + BID** 能分版；`p7b_snap.sh` **默认 `EXPECT_BID=0x0A`**，必显式传。
2. **`--check lane8` 是两个参数**（写成一个词 ⇒ `unknown arg` + **RC=2**，不静默）。
3. **短窗读数不可当判据**：本轮 S3 9 跑 3.75–8.65 / A 短跑中位 7.34 Gbps，而 A 长跑 9.1377 —— **同一臂内散布 > 两臂之差**。
4. **`0x08` 既是 SCRATCH 又是 `TX_DIS` 门**：`0x08 w 0x2` = **物理停发**（`carrier=0`）⇒ 那一臂的 ping/nc 是链路层结果，**不是慢路径结果**。
5. **`carrier=0` 时板侧计数照跑（≈809,578 fps）而对端 NIC 全 0** ⇒ 两条口径独立 ⇒ **板内计数不能当"线上发生了什么"的见证**。
6. **`--maxbytes 0` 不是"无限"**（立即退出 ⇒ **RC=1 假红**）；`--seconds` 不终止正在跑的连接 ⇒ 长流用 `--maxbytes`。
7. **32 位计数器**：`W51/W15/W53/W54` ≈3.65 s 回卷 · `W5/W24/W43/W29` ≈27.5 s · `W20/W8/W10/W52` ≈88 min ⇒
   分钟级窗口**必须 `mod 2³²` + 同时记 raw 与 k**；UDP 长流的**逐点求和 + 双序列交叉核**是可复用范例。
8. **pcap 相位 = `IO_AFFECTING=1`** ⇒ 那一小段不许与速率窗混比（长流默认 `PCAP_ON=0`）。
9. **UDP 的线上载荷天花板 = `1472/1538×10 = 9.5709 Gbps`**（不是 TCP 的 9.4935）—— 引用速率**必须带口径**。
10. **构建/烧录只走 `board/run_build_p7b_ku5p.bat` + `p7b_biz_tcpreg/run_program_tcpreg.bat`**；
   ⛔ **GUI 重编本树 `vivado_prj` 会踩"新端口悬空被钳 0 = 永久禁发"陷阱**（其 `imports/board/wrapper_p4.v` 是 BID 0xA 旧版）。

## 7. 相关全局经验（`~/.claude/fpga_net_dev.md` §六，现为 24–68）

本轮直接相关的：**#55**（32 位回卷 ⇒ mod+k）· **#57**（改 RTL 与跑回归互斥）· **#58**（换烧/重连后头几次读数可低到 3× ⇒ 单次读数不可作判据 ——
**本轮"短窗被建连瞬态拉低"的候选机理与它同族，但未分离**）· **#62**（速率读数必须带 `PIN_CPU=` 见证 —— 本轮 26/26 跑齐，**核号漂 5→7**）·
**#64**（"改常量就安全"不成立）· **#66**（跨网表比临界路径：清单藏族 + WNS 是不同对象）· **#67**（仪器高码率下变慢 ⇒ 窗口落到流外）·
**#68**（"读数低"先查对端网卡中断合并）。

---

*本件 = 交接入口，不改任何读数；**判据层的 PASS/FAIL 裁定权在用户/判据所有者**（全局 #51）。*
