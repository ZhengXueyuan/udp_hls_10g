# BUILD.md — p7b_affinity.h 部署件的**构建命令 + 产物指纹**（F8，2026-10-08；2026-10-09 更新）

> 为什么有这份东西（F8 的动因）：对抗审查实测"部署件 97,800 B vs 重编 97,760 B、
> 85 个符号里 2 个尺寸不同" ⇒ 判"字节级不可复现"。**本文件把"实际用的那一条命令"钉死**，
> 让**下一次重编的人**能用同一条命令得到同尺寸（甚至同 md5）的产物。
> ⚠️ 本轮的实测结论与审查的措辞**不完全一致**，见 §4「可复现性实测（订正）」—— 以实测为准。
>
> ⭐ **2026-10-09 更新（R1/R2 轮：主机端 socket 非阻塞 + 数据不落盘）**：7 个 .cpp 全部改过
> （非阻塞 connect / 一律 poll(LT) / 删掉"切回阻塞"的路径 / poll 超时确定语义 / 落盘路径清扫），
> **§3 的指纹整表换了**。构建命令**一个字没变**（仍是 `g++ -O2`）。改动的判据与自测见
> `p7b_selftest.sh`（扩到 T1–T8b，30 条判据）+ `p7b_board_stagec/pcap_off_dryrun.sh`（27 条）。

---

## 1. 部署位置与目标机

| 项 | 值 |
|---|---|
| 目标机 | 对端 Linux `192.168.0.38`（user `a`，key 免密；入口 `tools/peer_ssh.py`） |
| 部署目录 | `/tmp/p7b_biz/`（7 个二进制 + 7 个 .cpp + `p7b_affinity.h` + `p7b_pattern.h` + 三台架脚本 + 门脚本） |
| 编译器 | `g++ (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0` |
| 构建时间 | **2026-10-09（R1/R2 轮；上一次 = 2026-10-08）** |
| 行尾 | 仓库件与部署件**都是 LF**（无 CR）—— 部署是 `--put` 原样字节，**无任何转换步骤** |

## 2. 标准构建命令（**这就是唯一答案**）

```bash
cd /tmp/p7b_biz && g++ -O2 -o <name> <name>.cpp
```

⭐ 2026-10-09：**7 个 .cpp 的头注释现在写的也是这一条**（旧写法 `-O3 -std=c++17` 已删），
`p7b_selftest.sh` 的 T0 编译行也从 `-O3 -std=c++17 -Wall` 改成 **`-O2 -Wall`** ——
即 §4 里"三条互相打架的编译行"现在**只剩 `s2_setup.sh` 那条（本来就是对的）**，
**门与部署件用同一个旗标**（"门与板跑两个配置"的老坑）。

7 个产物（同一个 for 循环、逐字同一条命令，只是 `<name>` 不同）：

```bash
cd /tmp/p7b_biz && for n in p7b_tcp_sink p7b_tcp_src p7b_udp_src \
    p7b_tcp_src_fix p7b_tcp_sink_rate p7b_tcp_src_rate p7b_tcp_src_diag; do
  g++ -O2 -o $n $n.cpp
done
```

⛔ **不要照抄每个 .cpp 头部那行注释里的 `g++ -O3 -std=c++17 -o ...`** ——
实测它给出的是**另一个二进制**（§4）。既有旗标 = 上面这条 `-O2`（无 `-std`）。

## 3. 产物指纹（6+1 = 7 个二进制；**2026-10-09 R1/R2 轮构建**）

| # | 产物 | 字节数 | md5 |
|---|---|---|---|
| 1 | `p7b_tcp_sink` | 102,216 | `367e6f61e7ece7c3b6c4cfd0ae99c037` |
| 2 | `p7b_tcp_src` | 102,416 | `2350bb55e1c24b44006a56270efc4b26` |
| 3 | `p7b_udp_src` | 106,984 | `99ac2b4405a33f2689420f61ff22d234` |
| 4 | `p7b_tcp_src_fix` | 102,416 | `ade5907d1bafb1d3420f927fe0b3e4df` |
| 5 | `p7b_tcp_sink_rate` | 102,216 | `9c8af4f214905bc4c7195b45f32ca099` |
| 6 | `p7b_tcp_src_rate` | 102,416 | `8b7827c2261b653e4610381d96547e5b` |
| 7 | `p7b_tcp_src_diag` | 102,416 | `624968e624a88cacbb3bb3bb417636ad` |

> 大小相同 ≠ 同一份（1/5 都是 102,216；2/4/6/7 都是 102,416）——**只认 md5**。
> ⚠️ **旧的 2026-10-08 指纹（`10906f39…` / `e1261ef4…` / `0be6a66e…` / `754e2dfe…` /
> `c90808c5…` / `2ab00584…` / `732f1337…`）已全部作废**（那批源码没有 R1/R2 改动）。

**输入指纹**（部署件 == 仓库件，逐字节相同；md5 由 `md5sum(1)` 现算，2026-10-09）：

| 输入 | 仓库出处 | md5 |
|---|---|---|
| `p7b_affinity.h` | `_proj_pcie/p7b_biz/p7b_affinity.h`（+5 份副本，全部同 md5；**本轮未动**） | `9b141b50c089b4065145879d642c58fb` |
| `p7b_tcp_sink.cpp` | `_proj_pcie/p7b_biz/`（`p7b_retxfix/` 有**逐字节相同**的副本） | `0d4d5b269dd0225f1713d19b0eb745ed` |
| `p7b_tcp_src.cpp` | `_proj_pcie/p7b_biz/` | `32ce34a4ec91c8654ac4300f21a4f068` |
| `p7b_udp_src.cpp` | `_proj_pcie/p7b_biz/` | `3f027d3fcaa9016df23f4c7b2a309477` |
| `p7b_tcp_src_fix.cpp` | `_proj_10g/notes/p7b_biz_tcpreg/` | `e91e7cc8591cd20a6cb4c673fc6a54f3` |
| `p7b_tcp_src_diag.cpp` | `_proj_10g/notes/p7b_biz_tcpreg/` | `c44129fc7dcd48c14fc570949d15795c` |
| `p7b_tcp_src_rate.cpp` | `_proj_10g/notes/p7b_board_stageb/` | `1e76c5f643e5b73bfd2beb8c2392db40` |
| `p7b_tcp_sink_rate.cpp` | `_proj_10g/notes/p7b_board_stagec/` | `321a2d9c20df2149416e856a7cbbc909` |

**台架/门脚本指纹**（本轮改过或新增；部署位置 = `/tmp/p7b_biz/`）：

| 脚本 | 仓库出处 | md5 |
|---|---|---|
| `stc_dl.sh` | `_proj_10g/notes/p7b_board_stagec/` | `4273c6f8620d5ff051967fafa8c4f7e3` |
| `j6_stagec.sh` | `_proj_10g/notes/p7b_board_stagec/` | `7afce3a533dacd87a15c7781cfe1e91e` |
| `tcpreg_j6.sh` | `_proj_10g/notes/p7b_biz_tcpreg/` | `997f67d80839ce26717fe036e25f9781` |
| `pcap_off_dryrun.sh`（**新增门**） | `_proj_10g/notes/p7b_board_stagec/` | `3be0e9d757e00286a29efceb151de0a9` |
| `p7b_selftest.sh`（扩展 T6–T8b） | `_proj_pcie/p7b_biz/` | `c80914edd84a568a05763abfd0a916a3` |
| `win_tcp_sink.py`（R1 改非阻塞；⚠️ **Windows 侧**，等待原语 = `selectors.DefaultSelector`，**不能用 `select.poll`** —— Windows 上不存在，实测 `AttributeError`） | `_proj_10g/notes/p7b_biz_tcpreg/` | `4393db310ad76c8edeaa35552b8a0bab` |

## 4. 可复现性实测（订正审查的措辞）

在**同机同源码同旗标**下重编（2026-10-08，`/tmp/p7b_afftest/oldbuild/`：

```bash
mkdir -p /tmp/p7b_afftest/oldbuild && cd /tmp/p7b_afftest/oldbuild
cp /tmp/p7b_biz/p7b_tcp_sink.cpp . && cp /tmp/p7b_biz/p7b_affinity.h . && cp /tmp/p7b_biz/p7b_pattern.h .
g++ -O2 -o p7b_tcp_sink_rebuild p7b_tcp_sink.cpp
```

| 件 | 字节数 | md5 | 结论 |
|---|---|---|---|
| 修前**部署件**（2026-10-08 08:21 构建） | 97,800 | `9513cad5de178f631c4852d51982977c` | — |
| 同上源码 `g++ -O2` 重编 | 97,800 | `9513cad5de178f631c4852d51982977c` | ✅ **`cmp` 0 处差异 = 逐字节相同** |

⇒ **`-O2` 这一档是字节可复现的**（至少对 `p7b_tcp_sink`）∶
审查报的 "97,800 vs 97,760、2 个符号尺寸不同" **不是** `-O2` 同一命令的结果。
为把"哪一种命令给出哪种字节"钉死，同源码换了旗标实测：

| 旗标（同源码） | 字节数 | md5 前 8 位 |
|---|---|---|
| `-O2`（既有旗标，**本标准**） | 97,800 | `9513cad5` |
| `-O2 -Wall` | 97,800 | `9513cad5` |
| `-O2 -std=c++17` / `-O2 -std=c++17 -Wall` | 97,672 | `3d6c2fc2` |
| `-O3 -std=c++17`（**.cpp 头注释里写的那条**；也 = `p7b_selftest.sh` 里那条） | 104,672 | `b38b22b4` |
| `-O1` | 90,520 | `98c86728` |
| `-Os` | 70,096 | `a42968f1` |
| `-O2 -g0` | 97,800 | `9513cad5` |

⛔ **树里同时存在三条互相打架的编译行**（这就是 F8 的坑本体，别踩）：
1. 每个 `.cpp` 头注释：`g++ -O3 -std=c++17 -o <name> <name>.cpp` ⇒ 104,672 B（**不是**部署件）；
2. `_proj_pcie/p7b_biz/p7b_selftest.sh:30`：`g++ -O3 -std=c++17 -Wall -o $t $t.cpp` ⇒ 同上 104,672 B；
3. `_proj_pcie/p7b_biz/s2_setup.sh:13-15`：`g++ -O2 -o <name> <name>.cpp` ⇒ **与部署件逐字节相同**。
⇒ **只有第 3 条是部署口径**（本 BUILD.md §2 就是它）。
⭐ **2026-10-09 订正：第 1 条与第 2 条都已改写成部署口径** —— `.cpp` 头注释现在是
`g++ -O2 -o <name> <name>.cpp`，`p7b_selftest.sh` 的 T0 现在是 `g++ -O2 -Wall -o $t $t.cpp`。
上表里 `104,672 B` 那几个数**是历史值**（当时那两行确实给出另一个二进制），保留在此只为解释 F8。
⚠️ 审查报的 "97,760 B" 在本机**未能复现**（我实测的六个旗标组合给出的是 97,800 / 97,672 / 104,672 / 90,520 / 70,096，没有 97,760）
—— 差异可能来自别的工具链版本/别的源码修订。**判身份一律以 md5 为准，不以字节数为准**。

附带一条经验（本轮实测）：**只改注释/预处理守卫不改变 `.so` 字节** —— 给
`p7baff_faultinject.cpp` 加 `#ifndef _GNU_SOURCE` 守卫后，`.so` 的 md5（`a4e2bce4…`）**一字未变**。
⇒ "源码 md5 变了但产物 md5 没变"是正常情形，**判产物身份只看产物 md5**。

⚠️ **两条纪律留给下一次重编的人**：
1. 重编后**必须 diff md5**（大小相同也可能是另一份）；对不上先怀疑旗标，别先怀疑源码。
2. **别信 .cpp 头注释里的编译行** —— 它写的是 `-O3 -std=c++17`，与本目录的部署件**不是同一份**。

## 5. 配套仪器（都不是部署件，不进判据链）

### 5a. 2026-10-08（affinity 轮）

| 件 | 位置 | md5 | 作用 |
|---|---|---|---|
| `p7baff_faultinject.cpp` / `libp7baff_faultinject.so` | `_proj_10g/notes/p7b_affinity/` / 对端 `/tmp/p7b_afftest/` | `23a01d88b6acd01587f70692e421b476` / `a4e2bce4aea9fc1d05cdbdb2fe4db531` | LD_PRELOAD 故障注入（deny 子串 / 路径重映射）——F2(topo/nic)、F4 的复现 |
| `p7baff_fake_softirqs.txt` | 同上 | `82a31bd1021984e23a8bb60e365eadbb` | 假 `/proc/softirqs`（核负载 3.0e9 > 2³¹）——F4 的溢出反例 |
| `f9_loopback_check.sh` | `_proj_10g/notes/p7b_affinity/` / `/tmp/p7b_afftest/` | `95d0689f2059eb63cad36b7df660560e` | F9 周期行验证（回环口，不碰板子；7 个产物全覆盖 + 同期独立读数 REFCUR） |
| `aff_selftest.sh` | `_proj_pcie/p7b_biz/` / `/tmp/aff_selftest/` | `19cb9f2d9781e8a338246960e3c340ff` | 板外自检（F1/F2/F3/F6 判据 + `SKIP_NET=1` 开关） |

### 5b. ⭐ 2026-10-09（R1/R2 轮：非阻塞 + 不落盘）

| 件 | 位置 | md5 | 作用 |
|---|---|---|---|
| `p7b_selftest.sh`（扩到 T1–T8b，**30 条判据**） | `_proj_pcie/p7b_biz/` / `/tmp/p7b_biz/` | `c80914edd84a568a05763abfd0a916a3` | T6 = poll 超时确定语义 (STALL 不许算 clean)；T7 = strace 实测非阻塞 (I/O 单次 < 5 ms + connect EINPROGRESS) + **T7b 负对照**（阻塞程序上必须翻红）；T8 = udp 载荷增量复算；**T8b = `strace -e inject=sendmmsg:error=EAGAIN`** 把 udp_src 的 EAGAIN→poll 分支**真的走到**（回环 UDP 天生不产生 EAGAIN ⇒ 不注入就是"未测"） |
| `pcap_off_dryrun.sh`（**新门**，27 条判据） | `_proj_10g/notes/p7b_board_stagec/` / `/tmp/p7b_biz/` | `3be0e9d757e00286a29efceb151de0a9` | 三台架脚本"**默认不抓包**"的双臂门：臂 A（PCAP_ON 未设）必须 `PCAP_ACTIVE=0` + tcpdump **0 次调用** + **无 pcap 文件**；臂 B（`PCAP_ON=1`）必须标记 `1/1` + tcpdump **恰好 1 次** + **文件真的出现**。自带桩件（tcpdump/ethtool/reg_rw/p7b_snap 全部替身）⇒ **不碰板子**。负对照：对 HEAD 版三脚本跑 ⇒ **21 条 FAIL / RC=1** |
| 干跑桩件（**易失**，重启即失） | 对端 `/tmp/p7b_dryrun/`（`p7b_snap_stub.sh` `25ef4ab142bbb4da88c2cbc644cbc1f6` · `dryrun.sh` `2fd689dd30b17a6868d4581187413af3` · `tools/reg_rw` `cc92fd8ca13e8882a2ea67b8541302f1` · `stubbin/tcpdump` `137d4f74741e122d6c1f0f3956877fad` · `stubbin/ethtool` `ca6baef2ac5cd103d0837608bbaacbd2`） | — | 手工干跑用（报告里的逐臂原始输出出自它）；**`pcap_off_dryrun.sh` 已自带等价桩件，不再依赖本目录** |
| ⚠️ 纪律 | — | — | 干跑期间**绝不能**在 `/tmp/p7b_biz/p7b_snap.sh` 放桩件（真件路径）——负对照那一跑放过一次，**已当场删除并核过**（`No such file or directory`） |

仪器编译：
```bash
cd /tmp/p7b_afftest && g++ -shared -fPIC -O2 -o libp7baff_faultinject.so p7baff_faultinject.cpp
```
（⚠️ 该行会打一条 `"_GNU_SOURCE" redefined` 的 warning —— 良性，g++ 自带该宏定义。
见文件里的 `#ifndef` 守卫，若仍出现可忽略。）

## 6. 部署操作原文（可照抄）

```bash
# 本机 (git bash), P = anaconda python
P=/c/Users/zhxue/anaconda3/python.exe
python.exe tools/peer_ssh.py --put <本地绝对路径> /tmp/p7b_biz/<同名>
# 然后按 §2 的 for 循环重编, 再按 §3 对 md5
```

⭐ **2026-10-09 追加：三台架脚本 + 门脚本也要一起部署**（否则下一轮的台架还是旧版 = 默认抓包）：

```bash
P=/c/Users/zhxue/anaconda3/python.exe
$P tools/peer_ssh.py --put "$(cygpath -w _proj_10g/notes/p7b_board_stagec/stc_dl.sh)"           /tmp/p7b_biz/stc_dl.sh
$P tools/peer_ssh.py --put "$(cygpath -w _proj_10g/notes/p7b_board_stagec/j6_stagec.sh)"        /tmp/p7b_biz/j6_stagec.sh
$P tools/peer_ssh.py --put "$(cygpath -w _proj_10g/notes/p7b_biz_tcpreg/tcpreg_j6.sh)"          /tmp/p7b_biz/tcpreg_j6.sh
$P tools/peer_ssh.py --put "$(cygpath -w _proj_10g/notes/p7b_board_stagec/pcap_off_dryrun.sh)"  /tmp/p7b_biz/pcap_off_dryrun.sh
$P tools/peer_ssh.py --put "$(cygpath -w _proj_pcie/p7b_biz/p7b_selftest.sh)"                   /tmp/p7b_biz/p7b_selftest.sh
$P tools/peer_ssh.py --put "$(cygpath -w _proj_pcie/p7b_biz/p7b_fake_board.py)"                /tmp/p7b_biz/p7b_fake_board.py
# 自检 (都不碰板子): bash /tmp/p7b_biz/pcap_off_dryrun.sh ; cd /tmp/<干净目录> && bash p7b_selftest.sh 18899
```

⚠️ **`cygpath -w` 不是装饰**：`peer_ssh.py --put` 收的是 **Windows 路径**（`/tmp/...` 这种
MSYS 路径会被当成不存在的文件，报 `FileNotFoundError`）。⚠️ 远端目录**必须先 `mkdir -p`**
（sftp 不建目录）。
