# P7B `wu` 修复闭环 —— 施工配方侦察（只读 recon）

- 日期：**2026-10-07**　性质：**只读侦察报告**（本文是唯一写出的文件）。
- 本 agent **未改任何 RTL/XDC/脚本/笔记**，**未烧板、未写 QSPI、未碰 `D:\repo\perfv`、未做 git 写操作**。
  对端机的探查全部是只读（`ls` / `cat` / `md5sum` / `reg_rw` **读**），**未改板子状态**。
- ⚠️ **并发写声明**：另一实现 agent 正在并发改 `rtl/app_ctrl.v` 与 `board/wrapper_p4.v`。
  本报告里对这两处的**行号与内容都是"读取时刻的像"**：
  `rtl/app_ctrl.v` mtime = **2026-09-29 09:46**（78,605 B）、`board/wrapper_p4.v` mtime = **2026-09-30 19:30**（228,016 B），
  读取时 `git status --short` 的**已跟踪改动 = 空**。⇒ 凡引用这两处，**重新施工前必须重新核行号**。
- 所有行号 = **本文件写入时刻**盘上的行号；所有命令 = 逐字可复跑。

---

## 0. 一页速查（施工顺序）

```
① 改 RTL（app_ctrl.v 的 wu 两处 + 可选接 stat_wu/rx_occ_bytes 进快照）
② 构建   cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\board\run_build_p7b_ku5p.bat'   (~21.5 min)
③ 两栏门 bash <repo>/_proj_10g/notes/p7b_biz_build/gatecheck.sh /d/repo/XCKU5PMini/udp_hls_10g
④ 烧录   set TCPREG_BIT=<bit 路径> && cmd //c '<repo>\_proj_10g\notes\p7b_biz_tcpreg\run_program_tcpreg.bat'
⑤ PCIe 恢复（先判 lspci LnkSta；设备级不够就根端口级）
⑥ 身份闸 PEER_PW=... python tools/peer_ssh.py --sudo 'bash /tmp/p7b_biz/p7b_snap.sh id'
⑦ 运行前现取 ip route get 192.168.100.2 + carrier
⑧ J6     PEER_PW=... python tools/peer_ssh.py --sudo 'PACE=<bps> bash /tmp/p7b_biz/tcpreg_j6.sh 6 /tmp/x.pcap TAG'
⑨ J15    同 ⑧ 的读数 + 板内时基（见 §4.3）
```

> ⛔ **2026-10-07 订正（独立验收轮，出处 `P7B_WU_ACCEPT.md`）：上面 ⑨ 的 `J15` 标签已并入 `J6-ladder`**（旧 J15 的前提 "`P7B_10G` 下 TCP app RX 已改 8 B/拍" 已作废，见 §3.1 订正块）⇒ 本步**读作**：同 ⑧ 的读数 + **板内时基第二口径**（`ΔW53/(ΔW5/156.25e6)`），**不再单列 `J15`**；判据原文 = `P7B_BIZ_PLAN.md` §4.1b。

---

## 1. 构建

### 1.1 板上那版 BIZ 位流（sha256 `d20c08c9…`）是用什么建的

| 项 | 值 | 出处 |
|---|---|---|
| 命令 | `cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\board\run_build_p7b_ku5p.bat'` | `_proj_10g/notes/P7B_BIZ_BUILD.md:7` |
| 脚本 | `board/run_build_p7b_ku5p.bat`（24 行，**自 `cd /d %~dp0`** ⇒ 从哪调用都行） | 同文件全文 |
| Tcl | `board/build_p7b_ku5p.tcl`（sha256 `01f0770a…`，两轮未变） | `P7B_BIZ_BUILD.md:73-74` |
| **宏** | `APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1` | `board/build_p7b_ku5p.tcl:145`；构建日志印证 `board/p7b_ku5p_stdout.txt:270` |
| 策略 | `Performance_ExtraTimingOpt` | `board/build_p7b_ku5p.tcl:165` |
| 器件 | `xcku5p-ffvb676-1-e` | `board/build_p7b_ku5p.tcl:22` |
| 产物 | `vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4.bit` | `board/build_p7b_ku5p.tcl:184` |
| 身份 | **15,431,261 B**，sha256 `d20c08c9e3483359d278893f58b69e921c02b33427430ebe1664571ec0655ed5`（本报告写入时刻**现核一致**，mtime 2026-09-30 19:53） | `P7B_BIZ_BUILD.md:28-29`；本 agent 现跑 `sha256sum` |
| **预期耗时** | **~21.5 min**（BIZ 轮 19:32:19 → 19:53:43）；HANDOFF 记 **~22 min**；上轮 RATE 为 ~27 min | `P7B_BIZ_BUILD.md:8`；`P7B_HANDOFF.md:188` |
| 脚本不烧板 | bat 与 tcl 内**无** `program_hw_devices`，不写 QSPI | `board/run_build_p7b_ku5p.bat:2-4`；`build_p7b_ku5p.tcl:15` |

构建后 tcl 会把关键读数显式打印（`P7B_WNS` / `P7B_WHS` / `P7B_BIT_EXISTS` / `P7B DONE`），
bat 的 readings 行把它们挑出来（`board/run_build_p7b_ku5p.bat:19`）。

### 1.2 ⚠️ 三条硬门为什么会安静地失效 —— 以及"两栏"怎么抓

**病灶（逐字）**：`board/run_build_p7b_ku5p.bat:14-16` 三条 `findstr … p7b_ku5p_stdout.txt`：

- **只扫主 stdout** ⇒ `launch_runs` 的 OOC 子进程日志进 `runs/*/runme.log`，**那一半结构性地看不见**；
- **命中只 `echo` banner、从不 `exit /b 1`** ⇒ 末尾恒 `exit /b 0`（`:22-23`），**banner 不是门**。

实测（`_proj_10g/notes/p7b_biz_build/gatecheck_out.txt`）：

| KEY | 主 stdout | 4 份 run 日志合计 |
|---|---:|---:|
| `Synth 8-11241` | **0** | **33**（28 在 `pcs64_synth_1`，5 在 `xdma_0_synth_1`，**全是厂商 IP 生成源码，我们自己 RTL = 0**） |
| `undeclared symbol` | **0** | **33**（同一批） |
| 其余 10 个键 | 0 | 0 |

### 1.3 ⭐ "同时抓到主 stdout 与 4 个 OOC 运行日志两列"的逐字命令

**现成脚本（本轮就用它）**：

```bash
mkdir -p /d/repo/XCKU5PMini/udp_hls_10g/_proj_10g/notes/p7b_wu_loop
cd /d/repo/XCKU5PMini/udp_hls_10g
bash _proj_10g/notes/p7b_biz_build/gatecheck.sh /d/repo/XCKU5PMini/udp_hls_10g \
     | tee _proj_10g/notes/p7b_wu_loop/gatecheck_out.txt
```

脚本行为（`_proj_10g/notes/p7b_biz_build/gatecheck.sh`，59 行）：

- 栏 A = `board/p7b_ku5p_stdout.txt`；栏 B = 逐个 `vivado_prj/p7b_ku5p_prj.runs/{synth_1,impl_1,pcs64_synth_1,xdma_0_synth_1}/runme.log`（存在才纳入，`:13-15`）。
- 12 个硬键（`:16-29`）+ 6 个宽面键（`:44`），**逐键打两列计数**，再打"命中明细（非 0 才打）"。
- ⚠️ 它**只打印不置退出码**（`:58 exit 0`）⇒ **判读靠人/靠 grep 输出**；要硬门必须自己加
  `grep -qE '^Synth 8-11241\s+[1-9]' ... && exit 1`。

**若不用脚本、只要两栏一行版**（等价，逐字）：

```bash
R=/d/repo/XCKU5PMini/udp_hls_10g
MAIN=$R/board/p7b_ku5p_stdout.txt
RUNS=$(ls $R/vivado_prj/p7b_ku5p_prj.runs/{synth_1,impl_1,pcs64_synth_1,xdma_0_synth_1}/runme.log 2>/dev/null)
for K in '12-4739' 'Synth 8-11241' 'undeclared symbol' \
         'VRFC 10-3091] actual bit length 1 differs from formal bit length' \
         'VRFC 10-2989' 'implicitly declared' 'NSTD-1' 'UCIO-1' 'AVAL-326' \
         'Opt 31-155' 'Opt 31-67' 'Route 35-7'; do
  printf '%-62s MAIN=%s RUNS=%s\n' "$K" \
    "$(grep -c -F -- "$K" "$MAIN" 2>/dev/null || echo 0)" \
    "$(cat $RUNS 2>/dev/null | grep -c -F -- "$K" || echo 0)"
done
```

⚠️ **`Synth 8-11241` 的 33 条命中是本构建的"已知噪声"**（厂商 `pcs64_wrapper.v` / `xdma` 源码，
`P7B_BIZ_BUILD.md:99-108`）⇒ **判据应写成"新增大于 0 才红"或按 `grep -cE "udp_hls_10g/(rtl|board|_proj_pcie)/"` = 0 归属判据**
（`P7B_BIZ_BUILD.md:107-108` 用的就是后者）。
另：`implicitly declared` 在 Vivado 2025.2 下**恒 0（哑门）**，真实签名是 `Synth 8-11241` / `undeclared symbol` /
`VRFC 10-3091] actual bit length 1 differs from formal bit length` / `VRFC 10-2989`（`udp_hls_10g/CLAUDE.md` 坑 24）。

### 1.4 时序读数（原始报告）

**现核**（本 agent 直接读盘）：

```
board/p7b_ku5p_timing.rpt   →  | Design Timing Summary |
    WNS  0.077   TNS 0.000   setup 失败端点 0   / 总端点 242723
    WHS  0.010   THS 0.000   hold  失败端点 0   / 总端点 242723
    WPWS 0.000   TPWS 0.000  pw    失败端点 0   / 总端点 79028
    All user specified timing constraints are met.
```

- 原件：`board/p7b_ku5p_timing.rpt`（586,292 B，mtime 2026-09-30 19:54）；
  **归档副本**：`_proj_10g/notes/p7b_biz_build/p7b_ku5p_timing.rpt` + `timing_key_sections.txt`。
- 归因（不要重复劳动）：全局 WNS 由上轮 **+0.136 → +0.077（−0.059）**，最差路径 =
  `**async_default** pcie_axi_aclk` 的 **Recovery**，宿端 = **我们自己的快照阵列**
  `u_pcie_regs/snap_words_r_reg[174]/CLR`（扩窗 +320 FF），**Logic Levels = 0 / route 占 97.2%**
  ⇒ 纯扇出/布线，**同族内换了最差位**，非新缺陷族（`P7B_BIZ_BUILD.md:203-216`）。
- ⚠️ **含义（对 `wu` 闭环直接相关）**：**再往窗口加字会继续吃这条**（每 +10 字 ≈ +320 FF，
  `P7B_HANDOFF.md:307`）；0.077 ns 为正、0 失败端点，但**下一次加字很可能翻负**。
- DRC：`0 ERROR / 0 CRITICAL`，summary 与上轮逐行相同（`P7B_BIZ_BUILD.md:168-170`）。

---

## 2. 烧录

### 2.1 逐字命令（JTAG 走 `192.168.0.38:3121`，1 MHz，**绝不写 QSPI**）

**两套等价脚本**（都用 `connect_hw_server -url 192.168.0.38:3121`、`set_property PARAM.FREQUENCY 1000000`、
`End of startup status: HIGH` 才算成功）：

```bash
# (a) 参数化版（推荐：位流路径来自环境变量，A/B 两臂共用唯一路径）
set TCPREG_BIT=D:\repo\XCKU5PMini\udp_hls_10g\vivado_prj\p7b_ku5p_prj.runs\impl_1\wrapper_p4.bit
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_biz_tcpreg\run_program_tcpreg.bat'

# (b) 固定路径版（内容就是 BIZ 位流，已核 sha256）
cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_biz_s2\run_program_s2.bat'
```

- (a) 脚本：`_proj_10g/notes/p7b_biz_tcpreg/program_tcpreg_ku5p.tcl`（27 行）+ `run_program_tcpreg.bat`（5 行，stdout 落 `tcpreg_program_stdout.txt`）。
- (b) 脚本：`_proj_10g/notes/p7b_biz_s2/program_s2_ku5p.tcl`（29 行）+ `run_program_s2.bat`。
- 关键行（两套同形）：`set url 192.168.0.38:3121`（:5/:6）、`set_property PARAM.FREQUENCY 1000000 [get_hw_targets $tgt]`（:14/:15）、
  `program_hw_devices $dev` 包 `catch`（:21/:22）、`puts "… End of startup status: HIGH"` 提示（:23/:24）。
- ⚠️ **判成功**：日志里出现 `INFO: [Labtools 27-3164] End of startup status: HIGH`（末次原件见
  `_proj_10g/notes/p7b_biz_tcpreg/tcpreg_program_stdout.txt`）—— **不是看 bat 的 `%ERRORLEVEL%`**。
- ⚠️ **构建期间绝不从被构建的工程烧位流**（板级测量前置闸，`P7B_BIZ_S2.md` §7"全局止损线"）。

### 2.2 烧完后的 PCIe 恢复配方（逐字，含**升级判据**）

**前置**：**只用 TCP connect 判对端机死活**（`:22` / `:3121`）；⛔ **不用 Windows `ping` 退出码**
（收到本机产生的"无法访问目标主机"时 **Windows 仍 `exit 0`** 且统计行写"已接收=1，丢失=0"）。

```bash
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
D=/dev/xdma0_user

# ① 判死（重烧后应读 0xffffffff）
echo 111111 | sudo -S -p '' $T/reg_rw $D 0x00 w

# ② 判"有没有救"：看 LnkSta
lspci -vv -s 02:00.0 | grep -n "LnkSta:"
#     LnkSta … Width x4  ⇒ 有救（场景 B/C）
#     LnkSta … Width x0  ⇒ 没救（场景 A：POST 时 FPGA 跑无 PCIe 设计）⇒ 只有重启主机

# ③A 设备级（默认；约 5 s，不重启机器）
echo 111111 | sudo -S -p '' bash -c \
  'echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove; sleep 2; echo 1 > /sys/bus/pci/rescan; sleep 3'

# ③B ⭐ 升级到根端口级（当 ③A 报 "BAR 1 … can't assign; no space" + "xdma:map_bars … probe err -22" 时）
echo 111111 | sudo -S -p '' bash -c \
  'echo 1 > /sys/bus/pci/devices/0000:00:1c.0/remove; sleep 2; echo 1 > /sys/bus/pci/rescan; sleep 3'

# ④ 判活（BAR 读，**不看 lspci**）
echo 111111 | sudo -S -p '' $T/reg_rw $D 0x00 w     # → 0x50360001 即活
```

- 出处：`_proj_10g/notes/P7B_PCIE_RESCAN_RECOVERY.md:52-71`（§3 配方）与 `:150-172`（§7 场景 C）。
- **升级判据（三条，分工明确）**：
  | 问题 | 判据 | 出处 |
  |---|---|---|
  | 有没有救 | `lspci` 的 **`LnkSta`**：`x4` 有救 / `x0` 没救 | `P7B_PCIE_RESCAN_RECOVERY.md:143` |
  | 是谁（厂商 vs 我们） | 驱动 dmesg 行 **`identify_bars`**：`1 BARs: config 0, user -1` = 厂商 / `2 BARs: config 1, user 0` = 我们 | `P7B_PCIE_RESCAN_RECOVERY.md:176-184` |
  | 设备级够不够 | 看 `dmesg` 有无 `BAR 1 [mem size 0x00010000]: can't assign; no space` | `P7B_PCIE_RESCAN_RECOVERY.md:157-159` |
- ⚠️ **`identify_bars` 不是可执行文件** —— 它是 **xdma 驱动打的 dmesg 文本行**。读法逐字：
  `dmesg | grep -o 'identify_bars.*' | tail -1`（`_proj_pcie/pcie_regs_check.sh:32`）。
- ⚠️ **`lspci` 分不出厂商/我们**（两者都报 `10ee:9034` / subsystem `0007`，本报告写入时刻现核：`02:00.0 Serial controller: Xilinx Corporation Device 9034`）。
- ⚠️ **`0xffffffff` 在两个场景下不可区分** ⇒ 它**不能**用来判"是场景 A 还是 B/C"。
- 不需要重新 `insmod`（模块仍在内核里，rescan 后 probe 自己跑，`/dev/xdma*` 自动重建）。
- **本报告写入时刻的板子现态（只读探得）**：`reg_rw /dev/xdma0_user 0x00` → **`0x50360001`**（活、且是我们的设计）；
  `enp1s0f1np1` 的 `carrier = 1`；`192.168.100.100/32` 在位；`ip route get 192.168.100.2` → `dev enp1s0f1np1`。

---

## 3. 收口判据 J6 / J15

> ⛔ **2026-10-07 订正（独立验收轮，出处 `P7B_WU_ACCEPT.md`）：本节标题里的 `J15` 已并入 `J6-ladder`** —— 本节保留为历史原句（含 J15 的逐字定义与两条订正块）；**现役判据 = `P7B_BIZ_PLAN.md` §4.1b 的「J6-ladder」**（上界一律 `1.111 Gbps`）。

### 3.1 逐字定义（原文出处）

**J6** —— `_proj_10g/notes/P7B_BIZ_PLAN.md:196`，逐字：

> | **J6** | **TCP 上行速率 == 对端口径** | 对端已 ACK 字节/墙钟 与 `ΔW24` 推出的板内速率差 ≤1%；
> 落在 **1.00–1.20 Gbps**（T2 预测带） | V1 | 板内时基 / 对端 socket / 对端 NIC | 同 N-b |
> ✅ **PASS（方向）**：1,073.0 Mbps，实测/预测 **0.966** ⇒ **是 app 天花板** —— ⚠️ **2026-10-07 加限定**：
> 该数 **= `2^30` bps 的 99.94%**，原始件**无 pace 记录** ⇒ **可能含 pace 帽；真实可持续率未定**…
>
> ⛔ **2026-10-07 订正（独立复核裁定 = `P7B_WU_PACE_AUDIT_VERIFY.md` §2.1–§2.7；本轮 = 悬空引用清理，清册 = `P7B_WU_PACE_DOCFIX2.md`）**：上面这句"加限定"**撤回** —— `--pace-bps`（= `SO_MAX_PACING_RATE`）的**单位 = bytes/s**（内核头 `include/net/sock.h:493` 逐字 `unsigned long sk_pacing_rate; /* bytes per second */`；对端 `ss` 三档逐字 `pacing_rate 800000000bps / 1280000000bps / 8589934592bps` = 恰 8.000×）⇒ `2^30` 的真值是 **8.59 Gbps 的帽**，算术上压不到 1.07 Gbps。**Stage 1 稳态 = `132.414 MiB/s = 138.85 MB/s = 1,110.8 Mbps`** = `app_pattern` RX 校验器结构值（`8 B/9 拍 × 156.25 MHz = 1,111.1 Mbps`）的 **99.97%**（逐秒增量 `132.406 / 132.407 / 132.437 / 132.406` MiB/s，与 `8/9×156.25e6/1048576 = 132.4123 MiB/s` 吻合到 5×10⁻⁵）⇒ **实测/预测 = 0.9997**（`0.966` 是拿 6 s 均值 `1,073.043` 当分子算的，而它含一次 **0.2056 s** 停顿，⚠️ 该停顿的归因不可判）⇒ **"是 app 天花板"成立**。⚠️ **"无 pace 记录"保留为事实**（不许改写成"已记录"）。

⚠️ **口径已漂移**（读 J6 时必须知道）：
- 定义里的 `ΔW24` 是 **PLAN 时代的板侧字节字**；**现役窗口 W24 = `dp_free_DP`（一个自由计数器）**
  （`_proj_10g/notes/P7B_BIZ_WINDOW.md` §1 表；`_proj_pcie/p7b_biz/p7b_snap.sh:59`）。
  实务上的 J6 口径 = **对端 `p7b_tcp_src` 的 `SRC_SUM … tx_Mbps`** vs **板侧同窗增量**（`ΔW53`/`ΔW0`/`ΔW22`）——见 `P7B_BIZ_TCPREG.md` §2.3 判据 X。
- 定义里的 **"1.00–1.20 Gbps 预测带"是 1 B/拍时代的**；`P7B_10G` 下 app RX 校验器已改 8 B/拍 ⇒ 带子变了（见 J15）。
  ⛔ **2026-10-07 订正（独立复核裁定 = `P7B_WU_PACE_AUDIT_VERIFY.md` §4.1–§4.5）**：**后半句错，且它就是 J15 错误前提的源头** —— **`grep -c P7B_10G rtl/app_pattern.v` = `0`**（`P7B_10G` 的命中数全在 `rtl/app_udp_pattern.v` = `21`：TX `:551` / RX `:622`）⇒ **`P7B_10G` 下 TCP app 的 RX 校验器仍是 `8 B/9 拍`** ⇒ **TCP 上行结构上界 = `1.111 Gbps`，不是 `8.9 Gbps`**；`4.803 Gbps`（`tcp_tx_frame` 380 拍/帧）是**下行帧器**的数、在 `UDP_TX_OVL` 后**已作废**。⇒ 旧 J15 的"8 B/拍重算"前提**作废**，判据重构 = `P7B_BIZ_PLAN.md` §4.1b 的 **J6-ladder**（上界一律按 `1.111 Gbps` 写；`rtl/app_pattern.v` 工作树 == HEAD，最后一次改动 = `e1153e4`（2026-09-29），早于 RATE 轮）。

**J15** —— `_proj_10g/notes/P7B_BIZ_PLAN.md:206`，逐字：

> | **J15** | TCP 上行速率落在**新预测带**（8 B/拍重算；上界另受 `tcp_tx_frame` 380 拍/帧 = 4.803 Gbps 约束）
> | —— | V1 | 板内时基 | —— | ⏳ Stage 2 |

（同 `P7B_BIZ_PLAN.md:357`：`J15`（新速率带）属"⑤ 新增判据"之一。）
⚠️ **`4.803 Gbps` 这个上界只在没开 `UDP_TX_OVL` 时成立**：现役构建**已开** `UDP_TX_OVL`
⇒ 帧器 378→191 拍/帧（`board/build_p7b_ku5p.tcl:140-144`）⇒ 上界要按乒乓后重算，或干脆改用实测。
⛔ **2026-10-07 订正（`P7B_WU_PACE_AUDIT_VERIFY.md` §4.5）**：**不必"按乒乓重算"——该"上界"与 TCP 上行速率无关**（它是 `tcp_tx_frame` = **下行帧器**的数）⇒ 随 J15 一并**作废**；TCP 上行的上界只有结构值 `1.111 Gbps`（见上一条订正块）。

### 3.2 这两个判据现在的状态

| 判据 | 状态 | 出处 |
|---|---|---|
| **J6** | ⛔ **FAIL**（BIZ 位流上）—— Stage 2 四次跑 **4.806 / 5.173 / 5.680 / 6.226 Mbps**；Stage 1 基线 1,073.0 Mbps（⚠️ 可能含 pace 帽）⛔ **2026-10-07 订正："可能含 pace 帽"撤回** —— Stage 1 稳态 = 1,110.8 Mbps = app 天花板（1,111.1 Mbps）的 **99.97%**（见 §3.1 的订正块；`P7B_WU_PACE_AUDIT_VERIFY.md` §2.3/§2.4） | `P7B_BIZ_S2.md:588`（→ 本表）、`:624-631`；限定见 `P7B_BIZ_TCPREG.md:57-64` |
| **J6 的归因** | ✅ **已定案**：不是我们的 RTL；真因 = `app_ctrl` 的 `wu` 两个触发条件结构性不可达 ⇒ 板从不主动通告窗口重开 ⇒ 对端只能等 ~208 ms persist | `P7B_BIZ_TCPREG.md` §0/§2.2 |
| **J15** | ⛔ **未测**（Stage 2 那一格就是 `⛔ 未测`）⛔ **2026-10-07 订正：J15 旧判据的前提错、已作废**（`grep -c P7B_10G rtl/app_pattern.v` = `0`）⇒ 并入 `P7B_BIZ_PLAN.md` §4.1b 的 J6-ladder；这一格今后读作"**pace 阶梯未跑**"（见 §3.1 订正块） | `P7B_BIZ_S2.md:345`；`P7B_HANDOFF.md:226` |
| 复跑收口 | **`J6` + `J15`，⚠️ 读数必须带 pace 值**；负对照 = **未修的位流下同一 pace 应仍塌**⛔ **2026-10-07 订正：J15 已并入 J6-ladder**（§3.1 订正块）；"同一 pace 应仍塌"的负对照升级为 **缺陷位流 `d20c08c9…5ed5` 跑同一阶梯**（骨架 4 点已备，`P7B_WU_LOOP_MEASREP.md` §3.2） | `P7B_HANDOFF.md:165-166` |

### 3.3 怎么跑、需要哪些量

**主判据（对端口径）**：`SRC_SUM tx_Mbps`（对端已发/已 ACK 字节 ÷ 墙钟）。
**副判据（板内时基，不依赖主机墙钟）**：同窗快照对的 `ΔW0`（MAC 收帧）/ `ΔW53`（app 消费字节）/
`ΔW22`（交付 fast path 帧）÷ 同窗秒数；`ΔW20`（板发帧）用来看下行是否仍在跑。
**独立对照（判据 W）**：双向 pcap 的 `redge(t) = ack(t) + win(t)` 轨迹（`analyze_window.py`，见 §4.5）。

### 3.4 ⭐ pace 值：从哪读、怎么记

- **来源**：`--pace-bps <BPS>`（`tcpreg_j6.sh` 用 `PACE=<BPS>` 环境变量转发），实现 = `setsockopt(SO_MAX_PACING_RATE)`
  （`_proj_pcie/p7b_biz/p7b_tcp_src.cpp:77`；参数解析 `:52`）。
- **两个方向都要记**：
  1. **原始件必须有一行** `PACE_BPS=<n>`（`tcpreg_j6.sh:29` 在 `PACE!=0` 时打印；`PACE=0` 时打 `EXTRA=""` 不打印
     ⇒ **建议改成无论 0/非 0 都打印**，否则又回到"无 pace 记录"的老坑）；
  2. **读数同一行**里带 `SRC_SUM … tx_Mbps`（本来就是同一份 stdout）。
- **为什么必须**：Stage 1 的 `1,073.043 Mbps` = `2^30 bps`（1,073.741824 Mbps）的 **99.94%**，
  原始件**无 pace 记录** ⇒ 事后无法自证量的是板子还是工具（`P7B_BIZ_TCPREG.md:57-64`；全局 §六 #43）。
  ⛔ **2026-10-07 订正（"事后无法自证"这一问已关闭；独立复核 = `P7B_WU_PACE_AUDIT_VERIFY.md` §2.3/§2.4/§2.7）**：逐秒复算给出**实际发送 = min(pace, app 消费率) = 1,110.8 Mbps**（= 结构天花板 `1,111.1 Mbps` 的 99.97%）⇒ **pace 若存在就必须 ≥ 1,110.8 Mbps —— 那不叫帽子，那叫板子的速率**；"`2^30 bps` 的 99.94%"这个巧合 = "**MiB 当 MB 读**" + "**6 s 均值里含一次 0.2056 s 停顿**"两件事叠出来的（单位 = bytes/s ⇒ `2^30` 的真值是 **8.59 Gbps 的帽**）。⚠️ **"原始件无 pace 记录"保留为事实**；"每组读数同一行带 pace 值"的规程**保留并加强**（判据原文 = `P7B_BIZ_PLAN.md` §4.1b 的 J6-ladder，`PACE_BPS=` 是台架自证 (a)）。
- **已知的 4 组对照（同板同工具，可直接当回归基线）**：

  | PACE | tx_Mbps | 出处 |
  |---|---:|---|
  | 0（未 pacing） | 4.544（RATE 臂）/ 4.719（BIZ 臂） | `P7B_BIZ_TCPREG.md:159-163` |
  | `100000000`（100 MB/s） | **800.140** ✅（不塌） | 同上 |
  | `160000000` | 13.195 ❌ | 同上 |
  | `1073741824`（2^30） | 4.719 ❌ | 同上 |

  ⇒ **稳定 ⟺ 发送速率 ≤ app 有效消费率**（今日界 ⊂ (100, 134.2] MB/s）。
  ⛔ **2026-10-07 订正（三处口径；4 组读数本身全部有效；独立复核 = `P7B_WU_PACE_AUDIT_VERIFY.md` §2.1/§2.4/§5）**：(a) 上表 `2^30` 那条臂按 **1,073,741,824 B/s = 8.59 Gbps 的帽**读（单位 = bytes/s；`ss` 三档 = 恰 8.000×）；(b) 界写 **⊂ (100, 138.9] MB/s**（`134.2` 无出处；结构值 = `0.889 B/拍 × 156.25 MHz = 138.89 MB/s`）；(c) **"knife-edge"降级**（`PACE=100e6` 档窗全程未关：`min(win_raw) = 29,584 B = 20 MSS`、`#win<1460` = 0、无 persist 静默段 ⇒ 余量很大、被证伪；拐点本身未测）。⭐ 正面证据（丙）：`PACE=100e6` 档的读数 = **pace 帽在位**（`SRC_SUM tx_bytes=600139784 / dur_s=6.000` ⇒ 达成率 `100,023,297/100,000,000 = 1.00023`）、**不是板子容量** ⇒ 该跑不需要"窗口重开通告" ⇒ 与 `wu` 定案**相容且是它的正面证据**。

---

## 4. 测量台

### 4.1 上行 TCP 打流工具在哪（C++ / 内核旁路，无 Python）

| 件 | 仓库内路径 | 对端机路径 | 现核 md5（两侧一致） |
|---|---|---|---|
| C++ 源 | `_proj_pcie/p7b_biz/p7b_tcp_src.cpp`（6,541 B） | `/tmp/p7b_biz/p7b_tcp_src.cpp` | `7f9aa7161a9beb7bd978ac095926b488` |
| 已编译二进制 | —— | `/tmp/p7b_biz/p7b_tcp_src`（26,656 B） | —— |
| **J6 台架** | `_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh`（1,681 B） | `/tmp/p7b_biz/tcpreg_j6.sh` | `8ce3a2f47dd1a53856df15bc422c4b4e` |
| 对端前置闸 | `_proj_10g/notes/p7b_biz_tcpreg/tcpreg_env.sh` | `/tmp/p7b_biz/tcpreg_env.sh` | `c454f63ef3ea21e463ae0d1482f2028e` |
| 快照取数器 | `_proj_pcie/p7b_biz/p7b_snap.sh`（7,739 B） | `/tmp/p7b_biz/p7b_snap.sh` | `331a2e54c335b5339529a4eb356f404d` |

**S2 轮实际用的** = `s1_2_run.sh`（多连接下行 sink 300 连接）与 **`tcpreg_j6.sh`（J6 上行）**；
**归因轮 A/B 与 4 组 pacing 对照全用 `tcpreg_j6.sh`**（`P7B_BIZ_TCPREG.md:194-201` 的原件清单）。

### 4.2 逐字跑法（⭐ 这是本轮闭环要复用的那一条）

```bash
# ① 对端前置闸（每次对端重启后必跑；幂等）
PY=/c/Users/zhxue/anaconda3/python.exe
PEER_PW=111111 $PY tools/peer_ssh.py --sudo 'bash /tmp/p7b_biz/tcpreg_env.sh'   # 注意：该脚本本身要 root（读 /dev/xdma0_user）

# ② 现取（每次发送前）：路由 + carrier  【不许省】
$PY tools/peer_ssh.py 'ip route get 192.168.100.2; cat /sys/class/net/enp1s0f1np1/carrier'
#    必须显示 dev enp1s0f1np1、carrier=1

# ③ 跑 J6（PACE=0 表示不 pacing；PACE=100000000 表示 100 MB/s）
PEER_PW=111111 $PY tools/peer_ssh.py --sudo \
  'PACE=100000000 bash /tmp/p7b_biz/tcpreg_j6.sh 6 /tmp/wu_j6.pcap WU_J6'
```

`tcpreg_j6.sh` 内部（`_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh:6-42`，逐段）：

- `:8-9` `S=/tmp/p7b_biz/p7b_snap.sh; cd /tmp/p7b_biz`（**必须能 `cd` 进去**）。
- `:11-13` PHASE route_carrier：`ip route get` + `CARRIER=`。
- `:15-16` **pre 快照**（`p7b_snap.sh full <TAG>_pre`）。
- `:18-19` `tcpdump -i enp1s0f1np1 -s 96 -w <pcap> "tcp and host 192.168.100.2"`（后台，`timeout SECS+14`）。
- `:22-25` `ss -tinm state established '( dport = :8080 or sport = :8080 )'` 每秒采样 ⇒ `/tmp/ss_<TAG>.log`。
- `:27-31` `./p7b_tcp_src --host 192.168.100.2 --port 8080 --seconds <SECS> [--pace-bps <PACE>]` ⇒ 打 `SRC_*`/`SRC_SUM`。
- `:34-35` **post 快照**；`:38-39` `ping`（仅装饰，不判据）；`:42` `TCPREG_J6_DONE`。
- **工具默认参数（写死，别改）**：`--host 192.168.100.2 --port 8080`，`SRC_SUM` 行含
  `tx_bytes / rx_bytes / dur_s / tx_Mbps / rx_Mbps / rx_first_mismatch / rx_mism_bytes`（`p7b_tcp_src.cpp:141-145`）。
- ⚠️ `--seconds` 曾因 `atoi` 静默截断，工具已修（`P7B_BIZ_PLAN.md:7`，附录 B）⇒ **仍要核 `dur_s` 与传入值是否相符**（失败模式 F14）。

### 4.3 板侧读数怎么取（61 字窗口）

**协议**（`_proj_10g/notes/P7B_BIZ_WINDOW.md` §1 + `_proj_pcie/p7b_biz/p7b_snap.sh:12`）：

- 字 `Wi` 的字节地址 = **`0x20 + 4*i`**；**触发** = 写 `0x18 = 1`；**done** = `0x1c` 的 **bit1**；
  **gen** = `0x1c >> 16`。
- **未实现地址 = `0x114`** = `0x20 + 4*61` ⇒ 必须回 **`0xffffffff`**（SLVERR 负对照）。
- ⛔ **绝不能挑 ≥ `0x200`**（7 位译码 ⇒ 回绕到 word 0 = MAGIC ⇒ **假 FAIL**）。
- ⚠️ `reg_rw` 第 3 个参数 `w` 是**位宽（word）**，不是 write。
- ⚠️ **每个读数必须自证是新一代**（gen 恰好 +1），否则读的是上次锁存的陈旧值。
- ⚠️ 窗口里出现 `0xffffffff` = SLVERR ⇒ **整窗作废**（不是数据）。
- ⚠️ **非 root 时 `/dev/xdma0_user` 打不开 ⇒ 每条读都是空串**（空读 ≠ 真 0）。

**逐字命令**：

```bash
T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools

# A) 身份 + 通道活性（前置闸的"四读"）
PEER_PW=111111 $PY tools/peer_ssh.py --sudo 'bash /tmp/p7b_biz/p7b_snap.sh id'
#   期望：ID_MAGIC 0x50360001 / ID_BID 0x00000008 / ID_MARKER 0xdeadbeef / ID_UNIMPL 0xffffffff → ID_OK

# B) 触发一次 + 打全 61 字（带名字）
PEER_PW=111111 $PY tools/peer_ssh.py --sudo 'bash /tmp/p7b_biz/p7b_snap.sh full WU_PRE'
# C) 只打指定字（省时；例：W53/W54/W55）
PEER_PW=111111 $PY tools/peer_ssh.py --sudo 'bash /tmp/p7b_biz/p7b_snap.sh snap WU_A 53 54 55'
# D) 两点**各自自证新一代**的差分（速率用）
PEER_PW=111111 $PY tools/peer_ssh.py --sudo 'bash /tmp/p7b_biz/p7b_snap.sh pair 20 2.5 WU_STOP'
```

**裸命令版**（不经 `p7b_snap.sh`，用于快速手查；`<T>` 见上）：

```bash
sudo <T>/reg_rw /dev/xdma0_user 0x00 w    # MAGIC
sudo <T>/reg_rw /dev/xdma0_user 0x04 w    # BUILD_ID（现役应 0x00000008）
sudo <T>/reg_rw /dev/xdma0_user 0x14 w    # 0xdeadbeef
sudo <T>/reg_rw /dev/xdma0_user 0x114 w   # 必须 0xffffffff
sudo <T>/reg_rw /dev/xdma0_user 0x18 w 0x1   # 触发
sudo <T>/reg_rw /dev/xdma0_user 0x1c w    # bit1=done, >>16 = gen
sudo <T>/reg_rw /dev/xdma0_user $((0x20 + 4*53)) w   # = W53 @0xF4
```

**W51..W60 一行速查**（S2 现成脚本，`_proj_10g/notes/p7b_gate4_3/final_state.sh:14`）：

```bash
echo "W51=$(rd 0xec) W52=$(rd 0xf0) W53=$(rd 0xf4) W54=$(rd 0xf8) W55=$(rd 0xfc) \
W56=$(rd 0x100) W57=$(rd 0x104) W58=$(rd 0x108) W59=$(rd 0x10c) W60=$(rd 0x110)"
```

**与 wu 闭环相关的现役字**（`P7B_BIZ_WINDOW.md` §1 表）：

| 字 | 地址 | 名字 | 用途 |
|---|---|---|---|
| W0 | `0x20` | `rx_stat_frames` | MAC 收帧（上行的板侧第一道） |
| W20 | `0x70` | `mac_tx_frames` | 板发帧（停板判据 + 下行速率） |
| W22 | `0x78` | `rx_stat_pass_TCP` | 交付 fast path 的 TCP 帧 |
| W53 | `0xF4` | `app_pattern.stat_rx_bytes` | TCP 上行载荷字节（判据 X） |
| W54 | `0xF8` | `app_pattern.stat_mismatch` | 上行逐字节失配（J12） |
| W55 | `0xFC` | `tcp_tx_frame.stat_retx` | 重传/RTO 回卷次数 |
| W56 | `0x100` | `app_udp_pattern.stat_tx_ovf` | 写门回归守卫（恒 0） |

⚠️ `p7b_snap.sh` 的 `NAME` 关联数组有**显示名瑕疵**（`W51..W55` 无名、`W56` 两个键），
**地址全部由 `NW` 派生 ⇒ 判据不受影响**（`P7B_HANDOFF.md:233` = 本地 #28）。

⚠️ **停板/改板子状态的两条命令**：`TX_DIS` 的写地址是 **`0x08`**（= SCRATCH，`sfp2_tx_dis = pcie_scratch[1]`），
不是旧的 `0x10`（`board/wrapper_p4.v:3809-3826`；`_proj_10g/notes/p7b_gate4_3/f3_and_na_probe.sh:21-25`）。
**这条与 §6 的坑 #1 直接冲突 —— 见下。**

### 4.4 本地机 → 板子的 1G/10G 通路怎么配

**拓扑**（`P7B_HANDOFF.md:31`）：板 **`J8` = SFP B = GTY `X0Y5`** ↔ 对端机 **`enp1s0f1np1`**（SFC9120 p1, `01:00.1`）；
**`J7`(X0Y4) 空着**（板内自环已不存在）。板侧 IP `192.168.100.2`，对端 `192.168.100.100/32`。

```bash
# 一次性网络前置（缺 IPv4 帧时；需 root）—— 出处 P7B_HANDOFF.md:54-57
PEER_PW=111111 $PY tools/peer_ssh.py --sudo \
  'ip link set enp1s0f1np1 up; ip addr add 192.168.100.100/32 dev enp1s0f1np1; \
   ip route add 192.168.100.2/32 dev enp1s0f1np1'

# ⭐ 根治 NetworkManager 静默冲掉 /32（Stage 2 实测有效）
PEER_PW=111111 $PY tools/peer_ssh.py --sudo 'nmcli device set enp1s0f1np1 managed no'

# 每次发送前**仍要现取**（不能只信上一条）
$PY tools/peer_ssh.py 'ip route get 192.168.100.2; cat /sys/class/net/enp1s0f1np1/carrier'
```

⚠️ **只加地址不够**（`enp3s0` 已有同前缀路由 ⇒ 必须显式加 `/32` 路由）。
⚠️ **`nmcli managed no` 的持久性未验证**（对端在 Stage 2 之后重启过，`P7B_HANDOFF.md:244` = 本地 #39）。
⚠️ **无 link 时 `ethtool` 的 speed 仍读 10000（陈旧值陷阱）**（`P7B_HANDOFF.md:49`）。
⚠️ **对端重启会清 `/tmp` 并丢三条配置** ⇒ 恢复四条：① `modprobe xdma`（out-of-tree）② `ip link up`
③ `/32` 地址+路由 ④ 核 `carrier`；工具就位 = `p7b_biz_tools.tgz` + `s2_setup.sh`（`P7B_HANDOFF.md:33`）。

### 4.5 判据 W 的实现（pcap 侧，`wu` 闭环要复用的核心 oracle）

```bash
$PY tools/peer_ssh.py --get /tmp/wu_j6.pcap ./wu_j6.pcap
python _proj_10g/notes/p7b_biz_tcpreg/analyze_window.py --pcap ./wu_j6.pcap   # 逐 ACK CSV: redge = ack + win
```

- 语义：`redge` 冻结而 ack 前进 ⇒ 信用没回收；与交付量 1:1 ⇒ 在回收（`P7B_BIZ_TCPREG.md:98-108`）。
- RATE/BIZ 两臂已落盘的 CSV：`p7b_biz_tcpreg/{rate,biz}_j6_win.csv`（可直接当**修复前基线**对照）。
- ⚠️ 板不协商 window scale ⇒ `win_raw` 即真实窗口（scale=0，两臂 pcap 已证）。

---

## 5. `stat_wu` / `rx_occ_bytes` 的读回路径

### 5.1 `app_ctrl.stat_wu`（寄存器 `0x96`）现在能直接读吗？

**不能。** 三条证据（读取时刻）：

1. `app_ctrl` 的寄存器总线在 wrapper 里**被恒定接死**：
   `board/wrapper_p4.v:1280-1281` `assign app_reg_addr = 8'h00; assign app_reg_wr = 1'b0;`（另 `:1282` wdata=0）
   ⇒ **板级无 CPU/AXI 主机，寄存器口从来没人驱动**。
2. `stat_wu` 的**唯一消费者**是 `app_status_uart`（`board/wrapper_p4.v:1402` `.stat_wu (app_stat_wu[15:0])`），
   而该模块的输出 `uart_txd` **板上接不到任何可读通道**（本板无 UART，`P7B_BIZ_WINDOW.md`/`P7B_HANDOFF.md` 反复登记）。
3. 它**不在快照窗口**：61 字的装配表（`board/wrapper_p4.v:3630-3656`）里没有 `app_stat_wu`；
   `app_stat_wu` 这个 wire 在 `board/wrapper_p4.v:1048` 声明、`:1274` 由 `u_app_ctrl` 驱动，
   除 `u_app_status_uart` 外**无人引用**（`grep -n "app_stat_wu" board/wrapper_p4.v` 命中 1048/1274/1402 三处）。

**它是什么**（语义，别记错）：`rtl/app_ctrl.v:320` `output reg [31:0] stat_wu;`，
`:1162-1163` `if (wu_gnt) begin wu_pend[wu_id] <= 1'b0; stat_wu <= stat_wu + 32'd1; end`
⇒ **= `wu_gnt` 拍数 = "wu 条目确实入了 ackq" 的次数，不是"已上线"**（`P7B_BIZ_TCPREG.md:115-117`）。
复位清零：`rtl/app_ctrl.v:798`。

**寄存器表里它的邻居**（`rtl/app_ctrl.v:36-64` 头注释）：`0x08 = {15'b0, rx_occ_bytes}`、
`0x96 = stat_wu`、`0x97 = {15'b0, pool}`、`0x99 = redge[0]`、`0x9A = {16'b0, winq[0]}`、`0x9B = {16'b0, wu_mark[0]}`。

### 5.2 `rx_occ_bytes`（或等价量）现在在不在窗口/寄存器里？

**不在窗口，也不在 PCIe 可读寄存器里**，但**已经在 RTL 里现成有一根 wire**：

- 生成点：`board/wrapper_p4.v:1033`
  `wire [16:0] app_rx_occ = {(eco_dbg_fifo_wptr - eco_dbg_fifo_rptr), 3'b0};`（17 位、**字节**）
- 两个消费者：`board/wrapper_p4.v:1230` `.rx_occ_bytes (app_rx_occ)`（→ `u_app_ctrl`）、
  `:1387` `.rx_occ (app_rx_occ)`（→ `u_app_status_uart`）—— **同样只进 UART，板上读不到**。
- `app_ctrl` 内语义：`rtl/app_ctrl.v:264` 输入端口；`:655` `4'h8: reg_rdata = {15'b0, rx_occ_bytes};`
  （= 寄存器 `0x08` 的读值 —— 但整个寄存器口没人驱动，见 §5.1）。
- 它进 RTL 的两条链：`fq_calc(q, oc) = (oc >= q) ? 0 : q - oc`（`rtl/app_ctrl.v:541-547`）⇒
  `fq_scan = fq_calc(winq[scan_id], rx_occ_bytes)`（`:729`）⇒ **`pb_wscan`**（`:1075`）⇒ **wu 判据**。
  ⇒ **`rx_occ_bytes` 就是 `wu` 缺陷的输入之一**，接出来对归因价值最高。

### 5.3 若要接进快照 —— 改动清单（**本 agent 未改，仅列**）

**A. 加两个字（`app_ctrl.stat_wu` + `rx_occ_bytes`）到 dp 束**（源都在 dp 域、都是寄存器输出/纯组合派生）：

| # | 文件:行（读取时刻） | 改什么 |
|---|---|---|
| 1 | `board/wrapper_p4.v:3115` | `SNAP_NW_P6E = 61` → **63**（未实现地址随之变成 `0x20+4*63 = 0x11C`） |
| 2 | `board/wrapper_p4.v:3122` | `SNAP_P7BDP_NW = 22` → **24** |
| 3 | `board/wrapper_p4.v:3506-3519` 区块 | `biz_w61 = app_stat_wu` / `biz_w62 = {15'd0, app_rx_occ}`（**注意 `app_stat_wu` 已在 `:1048` 声明**，`app_rx_occ` 已在 `:1033` 声明 ⇒ 无需新线，只加两条 `wire` 别名） |
| 4 | `board/wrapper_p4.v:3572-3581`（现为 `assign p7bdp_din[12*32 …]` … `[21*32 …]`，共 10 行） | 续加两条 `assign p7bdp_din[22*32 +: 32] = biz_w61;` / `[23*32 +: 32] = biz_w62;` |
| 5 | `board/wrapper_p4.v:3630-3656` | 装配段**在最上面**（MSB 端）加两项 `p7bdp_dout[23*32 +: 32]` / `[22*32 +: 32]`（**旧字槽号逐项不动**） |
| 6 | `board/wrapper_p4.v:3832` | `BUILD_ID_V` 自增（现 `32'h00000008`） |
| 7 | `_proj_pcie/rtl/axi_regs.v` | `.SNAP_NW` 由 `SNAP_NW_P6E` 派生 ⇒ **通常不用改**（同文件 `:41-48` 的"七处同改"清单：①`SNAP_NW` ②两束拼接项数 ③读侧 `snap_base` 位宽 ④读 mux/SLVERR 边界 ⑤验收脚本的未实现地址 ⑥三个门自己的参数 ⑦两束索引表 `rtl/snap_seq.v` 的 `fe_idx_of/dp_idx_of`） |
| 8 | `_proj_pcie/p7b_biz/p7b_snap.sh:33-35` | `NW=${NW:-63}`、`EXPECT_BID` 跟 `BUILD_ID_V`、`UNIMPL_ADDR` 由 NW 派生（**但 `:50-75` 的 `NAME` 数组要补名**，否则显示 `?`） |
| 9 | `_proj_pcie/p6e_snap_check.sh:53` / `p7b_gate4_accept.sh:109` / `p7b_gate4_selftest.sh:31` / `_proj_10g/notes/p7b_gate4_3/final_state.sh:14` | `SNAP_WORDS` / 未实现地址跟着挪 |
| 10 | `_proj_10g/notes/p7b_biz_win/check_window.py` | 静态装配核对器（**扩窗必须重跑**，`P7B_BIZ_WINDOW.md` §2 尾注） |
| 11 | 文档 | `P7B_BIZ_WINDOW.md` §1 表（现役表是**单一权威**）、`P7B_HANDOFF.md`、`udp_hls_10g/CLAUDE.md` |

**B. 不做 A 的替代路（代价更小，但只解一半）**：把 `app_reg_addr/app_reg_wr` 从"恒定接死"改成
"由一个新 PCIe 寄存器转发" —— **不推荐**：要动 `axi_regs` 的写通道 + 新建一条 app 域跨时钟请求/应答，
风险高于加 2 个字。

⚠️ **A 的成本**：每 +10 字 ≈ **+320 FF**，WNS 走 §1.4 那条**异步复位 Recovery**（`snap_words_r_reg[*]/CLR`）。
现余量 `+0.077`，**加 2 字约为 +64 FF ⇒ 预计小幅吃掉余量但大概率为正**（无实测，属估计）。
⚠️ **`rx_occ_bytes` 是 17 位**：接进 32 位槽要**显式零扩展**（`{15'd0, app_rx_occ}`），
漏掉就是"隐式 1 位网"那一族（`udp_hls_10g/CLAUDE.md` 坑 24）。
⚠️ `app_stat_wu` 只在 `ifdef APP_MODE` 下存在（`u_app_ctrl` 的例化在 `:1214`，被 `:1072` 起的大 `ifdef` 包住）
⇒ 若学 `biz_w51..w54` 的写法，**必须一起包 `ifdef APP_MODE` 兜常量**（`board/wrapper_p4.v:3496-3546` 的注释就是踩过这条）。

---

## 6. 风险清单（最容易安静地出错的地方）

> 对照全局经验 `~/.claude/fpga_net_dev.md` §六（**现为 24–48 条**）。本轮闭环最相关的 7 条：

**#1 ⛔ `0x08` 既是 SCRATCH 又是 `TX_DIS` 门 —— 一次"读写回环测试"就能掉链。**
`board/wrapper_p4.v:3822-3823` `assign sfp1_tx_dis = pcie_scratch[0]; assign sfp2_tx_dis = pcie_scratch[1];`，
而 `pcie_scratch` = 寄存器 `0x08`（`_proj_pcie/rtl/axi_regs.v:171`）。
⇒ **任何往 `0x08` 写非 0 值的"通道功能自检"都会拉高 TX_DIS ⇒ 链路全黑**，
而现象看起来像"板子死了 / wu 修坏了"。**收尾时必须 `0x08` 写回 `0x0` 并现核 `carrier=1`。**
（同族：全局 #41"台架安静地做别的事"。）

**#2 ⛔ 硬门只 grep 主 stdout + 只打 banner 不置退出码（全局 #41）。**
`board/run_build_p7b_ku5p.bat:14-16` 的三条门对 OOC 日志**结构性瞎**（实测 `Synth 8-11241`：
主 stdout 0 / run 日志 33），且命中**照样 `exit /b 0`**。
⇒ **必须用 §1.3 的两栏脚本**，并且**把"新增 > 0"这一条自己写成非零退出码**；
`gatecheck.sh` 本身也是 `exit 0`（`gatecheck.sh:58`）。

**#3 ⛔ Windows `ping` 退出码不能判可达性（全局 #42）。**
收到本机产生的"无法访问目标主机"时 **Windows 仍 `exit 0`**、统计行还写"已接收=1，丢失=0"；
实测曾据此报出 **3 次假 `PEER_UP`**（`P7B_BIZ_S2.md` §0.2）。
⇒ 判对端机死活**只用 TCP connect**（`:22` / `:3121`），并对扫描器自己做正/负对照。
⚠️ `tcpreg_j6.sh:38-39` 里那条 `ping` 是**装饰**，**不许当判据**。

**#4 ⛔ POST 时 FPGA 跑的是什么，决定父桥窗（全局 #44）。**
若开机时板子跑 QSPI 厂商设计（`identify_bars` = `1 BARs: config 0, user -1`）⇒ 父桥窗按 1M 定死 ⇒
烧上我们的（2 BAR）后**设备级 `rescan` 必失败**（`BAR 1 … can't assign; no space` + `probe err -22`）。
⇒ 判据顺序 = **先 `lspci` `LnkSta`（有没有救）→ 再 `dmesg | grep -o 'identify_bars.*'`（是谁）→ 再决定设备级还是根端口级**。
⚠️ `0xffffffff` 在这个判定里**没有分辨力**。
⚠️ 本报告写入时刻现核：`0x00 = 0x50360001` ⇒ 板子跑的**是我们的**设计，bar 已就位（同一会话内后续重烧只需设备级）。

**#5 ⛔ NetworkManager 会静默冲掉 `/32`（全局 #47）。**
表现 = **全部 connect timeout**，**极易误判成"板子死了"**（尤其对端机有过"开机循环"故障史 ⇒ 两个环境问题互相掩护）
⇒ 接着就会把根因归到板子/`wu` 上。
⇒ 根治 `nmcli device set enp1s0f1np1 managed no`，**但每次测量前仍要现取 `ip route get`**；
本报告写入时刻现核：`/32` 在位、route 正确、`carrier=1`（**但这不是保证，下一轮仍要现取**）。

**#6 ⛔ "判据安静失效"有**两个方向**（全局 #48）——"通过"有对照、"失败"没对照。**
本轮的直接形态：`tcpreg_j6.sh` 只有 `PACE!=0` 才打印 `PACE_BPS=`（`:29`）
⇒ **不 pacing 的那一跑（恰恰是最关键的一跑）回到"无 pace 记录"**。
⇒ 建议改成**无条件打印**（`PACE_BPS=${PACE}`），并且**给"塌陷"这一侧也配对照**
（正控 = `PACE=100000000` 应到 800 Mbps；负控 = 未修的位流同 pace 应仍塌）。
⚠️ **判据 grep 工具的措辞会随工具升级变**（#48 的 curl 实例）⇒ 优先用**退出码/结构化字段**。

**#7 ⭐ 速率读数贴着 2 的幂 ⇒ 先怀疑台架的帽子（全局 #43）。**
修完之后如果读数**恰好逼近某个整数**（`2^30`、`10^10`、线速的 99.9x%），
**第一嫌疑是 pace/限速参数或某个内部上界**，不是板子能力。
⇒ 每组读数**同一行带 pace 值**；并**至少跑两档 pace**（一档在消费率之下、一档之上）。

⛔ **2026-10-07 订正（本条启发式的首次应用翻车、教训反向修正；出处 = `P7B_WU_PACE_AUDIT_VERIFY.md` §2.1–§2.7 + §5）**：上面那个"贴着 2 的幂"的实例（`1,073.043 Mbps` 贴着 `2^30` ⇒ 怀疑台架帽子）**已证伪** —— **单位没先查**：`--pace-bps` 是 **bytes/s**，`2^30` = **8.59 Gbps 的帽**，1,073 Mbps 根本不"贴"它；"99.94%"是 **MiB/MB 差 8 倍** + **6 s 均值含一次 0.2056 s 停顿**叠出来的假巧合（稳态 = 1,110.8 Mbps = app 结构天花板 99.97%）。⭐ **本条的保留形态（且更锋利）**：① **"读数贴着 2 的幂"先查单位**（bytes/s vs bits/s 差 8 倍）；② **帽子的签名 = 达成率**：`PACE=100e6` 档实测 `800.186 Mbps`、达成率 `1.00023`（与传入值恰成 8.000× 换算）⇒ 那才是真的"工具帽子"实例；③ "每组读数同一行带 pace 值 + 至少两档 pace" 的规程**保留并加强**（已升为判据的组成部分，见 `P7B_BIZ_PLAN.md` §4.1b 的 J6-ladder (a)/(b)）。

**#8 ⚠️ 观测面自身的代价与时序（全局 #42 的本地版）。**
加字走那条**异步复位 Recovery**（`u_pcie_regs/snap_words_r_reg[*]/CLR`，逻辑级数 0 / 97.2% 布线）
⇒ **新一轮加字很可能把 WNS 翻负**（`P7B_HANDOFF.md:307`）。加完必须看 `P7B_WNS` 与**三类失败端点 = 0/0/0**。

**#9 ⚠️ 快照读数自身的三个静默失效**（都会给"看起来合理"的错数）：
① **gen 不是恰好 +1** ⇒ 有并发写者，本窗作废（`p7b_snap.sh:104-106`）；
② **窗口里混入 `0xffffffff`** ⇒ SLVERR，整窗作废（`:121`）；
③ **非 root** ⇒ 每条读是**空串**（空读 ≠ 真 0，`:43-47`）。
（同族全局 #27/#32/#33。）

**#10 ⚠️ 板级测量的两条常设纪律**（`P7B_BIZ_S2.md` §7"全局止损线"）：
**任何板级测量前必须重烧 + 核 sha256 + 过 S0 全部 8 条**；
**构建期间不得从被构建的工程烧位流**。⚠️ **同尺寸 ≠ 同内容**（BIZ 与 RATE 位流字节数相同、sha256 不同）。

**#11 ⚠️ 别把"重烧"当成"清状态"的万能药、也别指望它清 learn-on-RX 表以外的状态。**
失败模式 F9：板子自己发流而我没让它发 ⇒ peer 表没清 ⇒ 重烧清表后重过 S0（`P7B_BIZ_S2.md` §7-F9）。

**#12 ⚠️ 一条与 `wu` 闭环直接相关的读法陷阱**：`W55`（`stat_retx`）/`W57`/`W58` 是**瞬态**
（~15 µs vs 快照几十 ms 周期）⇒ **必须用高频 `snap` 专打**，否则"读到 0"是**采样没命中**、不是"没发生"
（`P7B_HANDOFF.md:170-171`）。

---

## 7. 与本闭环相关的现役文件清单（一屏定位）

| 想知道 | 文件 |
|---|---|
| 缺陷本体（两处触发条件） | `rtl/app_ctrl.v:1112-1123`（C6 块）；`wu_mark` 初值 `:851`；`WU_STEP` `:336`；`WIN_POOL` `:196` |
| `wu` 的登记与语义 | `rtl/app_ctrl.v:44`（0x08）/`:56`（0x96）/`:60`（0x9B/0x9C）；`stat_wu` 自增 `:1162-1163` |
| 寄存器总线被接死 | `board/wrapper_p4.v:1280-1282` |
| `rx_occ_bytes` 源 | `board/wrapper_p4.v:1033`（生成）、`:1230`/`:1387`（消费） |
| 快照 61 字装配 | `board/wrapper_p4.v:3115-3123`（几何）、`:3630-3656`（装配）、`:3832`（BUILD_ID_V） |
| 扩窗"七处同改" | `_proj_pcie/rtl/axi_regs.v:41-48` |
| 现役窗口表 | `_proj_10g/notes/P7B_BIZ_WINDOW.md` §1 |
| 取数器 / 身份闸 | `_proj_pcie/p7b_biz/p7b_snap.sh` |
| J6 台架 | `_proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh` + `analyze_window.py` |
| 烧录 | `_proj_10g/notes/p7b_biz_tcpreg/{program_tcpreg_ku5p.tcl,run_program_tcpreg.bat}` |
| PCIe 恢复 | `_proj_10g/notes/P7B_PCIE_RESCAN_RECOVERY.md` §3 / §7 |
| 构建 + 门 | `board/{run_build_p7b_ku5p.bat,build_p7b_ku5p.tcl}`；`_proj_10g/notes/p7b_biz_build/gatecheck.sh` |
| 修复方向原文 | `_proj_10g/notes/P7B_BIZ_TCPREG.md` §2.2 / §2.4 / §6-#1 |
| 下一轮开工入口 | `_proj_10g/notes/P7B_HANDOFF.md` §1（先核）+ §3-①（第一优先） |

---

## 8. 一条方法学提醒（写给出活儿的人）

`wu` 的修法方向（`P7B_BIZ_TCPREG.md` §6-#1）是**改变触发条件的可达性**：
① `wu_zero` 按"危险区"武装（如 `wscan < 3×MSS`）而非 `==0`；
② `wu_mark` 改基（"上次通告值 + 小步长"而非建连时的全池）。
⇒ **这两条都改的是"什么时候发一个 ACK"**，属**零额外帧/零功能语义变化**的类。
**收口必须有对照**：修完的位流上，**同 pace** 应**不再塌**；而**未修的位流**（`d20c08c9…` 现成在盘上）
**同 pace 应仍塌** —— 这一对 A/B 就摆在手边，**不要只用"变好了"当结论**（全局 #48）。
