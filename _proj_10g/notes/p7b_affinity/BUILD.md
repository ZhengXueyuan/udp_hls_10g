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
>
> ⭐⭐ **2026-10-09 二次更新（双线程样板：`p7b_io.h` / `p7b_spsc.h` / sink 双线程 / pair 绑核）**：
> 构建命令**变了** —— 加 **`-pthread`**（sink 现在用 `pthread_create/join`）。**§2/§3 又整表换了一次**，
> 并新增两件**仪器**（`p7b_rate2_bench` 天花板台 + `p7b_dualthread_selftest.sh` 双线程自检，§5c）。
> ⚠️ 本轮改到的源码 = `p7b_tcp_sink.cpp`（双线程）+ `p7b_affinity.h`（按线程记账 + 两颗核 + 线程绑核入口）
> + 两个**新头**（`p7b_io.h` 机制头 / `p7b_spsc.h` 无锁 SPSC）；**发送族 6 个 .cpp 一个字节没动**
> （只重编了一遍，见证行前缀逐字不变 —— 见 §3 的"旧调用点未破"）。
>
> ⭐⭐ **2026-10-09 三次更新（R1/R2/R4 轮：M^8 lane-parallel 校验 + `CPU_FREQ_KHZ` 语义订正）**：
> **构建命令一个字没变**（仍是 §2 的 `g++ -O3 -pthread -o <name> <name>.cpp`）；**§3 整表又换了一次**。
> 本轮改到的源码（4 个）：
> * `p7b_pattern.h` —— `check()` 新增 **M^8 lane-parallel 路径**（8 字节/步, 编译期 `constexpr` 表 ⇒
>   **零运行时建表成本**）+ 开关 **`--check=seq|lane8`（默认 = `seq` = 已上板验过的逐字节版）**
>   + 新增 `--selftest-equiv`（seq/lane8 逐位等价自证: 长序列三全等 / 6 点注入 / 跨块 12 状态 / 表复核）。
>   ⚠️ **该头需要 C++14 以上**（`#error` 守卫, 部署口径 gnu++17 满足）。
> * `p7b_affinity.h` —— **R2**: report 行的 `CPU_FREQ_KHZ` 改取**工作线程自采样**值
>   （旧值 = 打行那条线程 = **空闲主线程**核, 实测 800 MHz–2 GHz；新值 = 干活核, 实测 3.88 GHz）。
>   **字段名一个字没改**（下游解析器），只改取值语义；新增 `p7baff_work_freq_tick()` / `p7baff_work_freq_khz()`。
> * `p7b_tcp_sink.cpp` —— 加 `--check=seq|lane8` + `--selftest-equiv` + 两处工作线程 tick + 见证
>   （`SINK_CHECK check=<mode>` 行 + `SINK_SUM` 行尾 `check=<mode>`）。
> * `p7b_rate2_bench.cpp` —— 同上（`BENCH_CHECK` 见证 + `BENCH` 行尾 `check=` + `--selftest|--selftest-equiv`）。
> **发送族 6 个 .cpp 仍未动**（`p7b_tcp_src_diag.cpp` 也是 —— 负对照臂纪律）；它们**没有** `--check` 开关，
> 因此 GCC 把"模式恒为 SEQ"常量传播掉 ⇒ **lane8 的表与代码根本没进它们的二进制**（实测 `nm` 0 命中,
> `.rodata` 只有 ~4 KB）—— 这是"未改调用点零成本"的**实测**证据，不是推断。
> ⭐ **本轮新增两件仪器**（都不是部署判据链）：`p7b_lane8_selftest.sh`（新门, 42 条判据, §5d）与
> `p7baff_faultinject.cpp`（上一轮的 LD_PRELOAD 注入器, **重新部署**到 `/tmp/p7b_biz/` —— `/tmp/p7b_afftest/`
> 已在重启中清空；md5 与 §5a 记录**逐字相同**）。
> ⭐ **旧件（A/B 的另一只手）已归档**：重编前把 8 个产物原样拷到 **`/tmp/p7b_biz_prev/`**（md5 与
> 上一次 §3 表**逐条相同**, 已核）—— 这就是"两只手都能重新点火"的那只负对照臂。

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
cd /tmp/p7b_biz && g++ -O3 -pthread -o <name> <name>.cpp
```

⭐⭐ **2026-10-09 用户逐字裁定：「编译用 -O3」** ⇒ 本轮起**部署口径 = `-O3 -pthread`**
（R1 轮的 `-O2` 已废；**不要顺带加 `-std=c++17`** —— g++ 13 默认已是 `gnu++17`）。

⚠️⚠️ **口径登记（读数可比性）**：**历史读数全部是 `-O2` 口径** —— 含 Stage B/C 的
**3707–3724 Mbps** 下行、`--nocheck` 的 **3.69 → 7.07 Gbps** 拆帽读数、以及所有更早的台架数。
**从本轮起换 `-O3` ⇒ 新旧速率数字原则上不可直接比**。
⭐ 但**本轮的 -O2/-O3 同源 A/B 实测：四个模式下差异全部落在 ±0.4%**（见 §4 末表）——
即"换了旗标"这件事**在本次测量里没有可观测影响**（瓶颈是每字节一次 xorshift 的**串行依赖**，
编译器旗标拆不开它）。所以：**结论仍是"引用旧数字要标 -O2 口径"**，不是"数字一定不同"。

⭐⭐ **2026-10-09（双线程样板）：新增 `-pthread`** —— `p7b_tcp_sink` 现在
`pthread_create` 两条工作线程（I/O + 校验）。⚠️ **少了它在本机也照样链得上**
（glibc 2.39 的 libpthread 已并入 libc；实测 T0 用旧行也 RC=0），
**但门与部署件必须逐字同旗标**，否则"门与板跑两个配置"的老坑会以
"换台机器/换 glibc 就链不上"的形式复发。**全部 8 个产物改用这一行重编**（含未改的发送族）。

8 个产物（同一个 for 循环、逐字同一条命令，只是 `<name>` 不同）：

```bash
cd /tmp/p7b_biz && for n in p7b_tcp_sink p7b_tcp_src p7b_udp_src p7b_tcp_src_fix \
    p7b_tcp_sink_rate p7b_tcp_src_rate p7b_tcp_src_diag p7b_rate2_bench; do
  g++ -O3 -pthread -o $n $n.cpp
done
```

⭐ **"三条互相打架的编译行"本轮就地收口**（见 §4）：`.cpp` 头注释 / `p7b_selftest.sh:45` /
`s2_setup.sh:13-15` 现在**全部**是 `g++ -O3 -pthread -o <name> <name>.cpp`
（自检那条多一个 `-Wall`，只影响告警不影响 codegen）。
⚠️ **唯一已知分叉 = `p7b_tcp_src_diag.cpp:24` 的头注释仍写 `g++ -O2 -o …`** ——
该文件是**负对照臂**、派单明令"不改该文件"，**故未动**（**编译它用的仍是 `-O3 -pthread` 部署口径**，
只是它自己的注释没跟着换）。**这一处分叉已显式登记，请裁定是否要补改**。

## 3. 产物指纹（7 个二进制 + 1 个仪器；**2026-10-09 R1/R2/R4 轮 / `-O3 -pthread` 构建**）

| # | 产物 | 字节数 | md5 |
|---|---|---|---|
| 1 | `p7b_tcp_sink` | 169,392 | `e56cb8bdbf28e0fef34e5fc40b1ffbef` |
| 2 | `p7b_tcp_src` | 119,488 | `48d066a04684fbd6b901679120d88c3c` |
| 3 | `p7b_udp_src` | 128,048 | `a3faafd37ed2e21e0acd3cc925e9c98c` ⚠️ **未变** |
| 4 | `p7b_tcp_src_fix` | 119,496 | `d1ca0c288efe6723488e4c1a6960d1b5` |
| 5 | `p7b_tcp_sink_rate` | 119,296 | `3161889f6e5f73d86935ad5ef2eac306` |
| 6 | `p7b_tcp_src_rate` | 119,496 | `a76b2b4b1e44d6c9edcaa301d90aabcb` |
| 7 | `p7b_tcp_src_diag` | 123,592 | `430ed36ade4ec64ba6f5cb52e5f4f335` |
| 8 | `p7b_rate2_bench`（**仪器**, 非部署判据链） | 171,040 | `1e956072f30a25f3e547e8c42107afb3` |

⚠️ **`p7b_udp_src` 的 md5 本轮"没变"是正确结果, 不是漏编译**: 它既不用 `check()` 也不用 report 行的
   `CPU_FREQ_KHZ` ⇒ 新头里的东西**全被常量传播/死代码消除掉**（实测 `nm` 里 `check_lane8`/`P7B_L8` 0 命中）。
   ⇒ **"源码 md5 变了但产物 md5 没变"是正常情形**（§4 末条同款）；**判身份仍然只看产物 md5**。
⚠️ **`p7b_tcp_sink` 的 +36 KB 里的大头 = M^8 的 `Tj`/`Tw` 表**（32 KiB；它**真的**用了 `check()` 两路,
   因为 `--check` 开关在 ⇒ 编译器**不能**把 lane8 支路消掉 —— 实测 `nm` 命中 2 个符号、`.rodata` 0x99e0）。
   相反, **发送族 5 个**（含 `_rate` 变体）与 `p7b_udp_src` 都**没有** `--check` 开关 ⇒ 模式恒为 SEQ
   ⇒ 表与 lane8 代码**根本没进二进制** ⇒ **未改调用点零成本**（实测 `nm` 0 命中、`.rodata` ~4 KB）。

> 大小相同 ≠ 同一份（4/6 都是 119,496）——**只认 md5**。
> ⚠️ **旧的 2026-10-08 指纹（`10906f39…` …）、R1 指纹（`367e6f61…`/`2350bb55…`/`99ac2b44…`/
> `ade5907d…`/`9c8af4f2…`/`8b7827c2…`/`624968e6…`）与**本轮 `-O2 -pthread` 中间档**
> （`ae52e70a…`/`cc04c98f…`/`8141185c…`/`81ca5a3a…`/`29277540…`/`ead6c118…`/`c223859c…`/`275f96fc…`）
> **全部作废** —— 换旗标（`-O2`→`-O3`）就会换二进制。⚠️ **"大小变了"本身不是判据**（见 §4 末条）：只认 md5。

**输入指纹**（部署件 == 仓库件，逐字节相同；md5 由 `md5sum(1)` 现算，2026-10-09 R1/R2/R4 轮）：

| 输入 | 仓库出处 | md5 |
|---|---|---|
| `p7b_affinity.h` | `_proj_pcie/p7b_biz/p7b_affinity.h`（+5 份副本，**本轮已同步**，6 份同 md5） | `b03222792d20443138515ba2804b0d87` |
| ↑ ⚠️ **该 md5 曾为 `01fde8fd…`**（同一轮内的一次**纯注释**补充：写明"频率采样有 ≤200 ms 节流网格"）| — | **实测: 改注释 ⇒ 8 个产物 md5 一个都没变**（§4 末条同款, 这是本轮第二次独立复现）|
| `p7b_io.h` | `_proj_pcie/p7b_biz/`（**未动**） | `62b1257d69c40f24bfa9a799593073b7` |
| `p7b_spsc.h` | `_proj_pcie/p7b_biz/`（**未动**） | `3132db495c29ab85b7f6a5617803644f` |
| `p7b_pattern.h` | `_proj_pcie/p7b_biz/`（⭐ **本轮改**: M^8 lane8 + 开关 + 等价自检） | `b2f2e9627bac53bf3b4ab2b565afe872` |
| `p7b_tcp_sink.cpp` | `_proj_pcie/p7b_biz/`（⭐ `--check`/`--selftest-equiv`/tick/见证） | `0574eca85cdb9060ac461e0270a365ee` |
| `p7b_tcp_src.cpp` | `_proj_pcie/p7b_biz/`（**行为未动** —— 只被新头重新编译） | `e73309a9f85a628c85ba4eef0e74a0d7` |
| `p7b_udp_src.cpp` | `_proj_pcie/p7b_biz/`（**行为未动**） | `074321cfbb31827c84a30cd86abeab84` |
| `p7b_tcp_src_fix.cpp` | `_proj_10g/notes/p7b_biz_tcpreg/`（**行为未动**） | `21ca7fa995fae7dc06675b64ff24dc36` |
| `p7b_tcp_src_diag.cpp` | `_proj_10g/notes/p7b_biz_tcpreg/`（⛔ **负对照臂, 一个字节没动**） | `c44129fc7dcd48c14fc570949d15795c` |
| `p7b_tcp_src_rate.cpp` | `_proj_10g/notes/p7b_board_stageb/`（**行为未动**） | `c3b9b01c42dae1ef3e098893d839f986` |
| `p7b_tcp_sink_rate.cpp` | `_proj_10g/notes/p7b_board_stagec/`（**行为未动** —— 它**没有** `--check` ⇒ 仍是 seq 一路） | `5935bc51f3b7f746d7449e79f118db4a` |
| `p7b_rate2_bench.cpp`（⭐ 仪器源, 本轮改） | `_proj_pcie/p7b_biz/` | `b9c18a7695480a24f60169313034c0fd` |

⭐ **旧调用点未破（"只加不破"的实测证据）**：未改的发送族用**新** `p7b_affinity.h` + `-O3 -pthread` 重编后，
`--help` 的见证行**前缀逐字不变**（与 HEAD 版本 `9b141b50…` 逐字对比，差异**只有行尾追加的 8 个
`PIN_PAIR_*`/`PIN_CPU_IO/WORK`/`PIN_PC_*` 字段**；`PIN_CORE_LOAD`/`PIN_FREQ_START_KHZ` 是活读数、本该抖）。
⭐ 同批实跑（`-O3 -pthread` 口径，**2026-10-09 R1/R2/R4 轮**）：
`p7b_selftest.sh` = **PASS=30 / FAIL=0 / SELFTEST_OK**（T1–T8b 判据一条未改）；
`p7b_dualthread_selftest.sh` = **PASS=48 / FAIL=0 / DUAL_SELFTEST_OK**（D1–D8 判据一条未改）；
`aff_selftest.sh` = 全过，**含 CASE Q 的 `PIN_FAIL END_MISMATCH` + `_exit(2)` 硬门仍成立**；
`p7b_lane8_selftest.sh`（⭐ **新门**, 本轮）= **PASS=42 / FAIL=0 / SKIP=0 / LANE8_SELFTEST_OK**。
⭐ **另一只手的 A/B 已实跑**（R2 的判别性证据）：`/tmp/p7b_biz_prev/p7b_tcp_sink`（旧件）vs 新件, 同会话同回环:
旧件 `CPU_FREQ_KHZ=2000000/800000`（**空闲主线程核**）vs 新件 `3875395/3889822`（**干活核**）；
其余字段（bytes / first_mismatch / 队列恒等式）逐字相同。

**台架/门脚本指纹**（本轮改过或新增；部署位置 = `/tmp/p7b_biz/`）：

| 脚本 | 仓库出处 | md5 |
|---|---|---|
| `stc_dl.sh` | `_proj_10g/notes/p7b_board_stagec/` | `4273c6f8620d5ff051967fafa8c4f7e3` |
| `j6_stagec.sh` | `_proj_10g/notes/p7b_board_stagec/` | `7afce3a533dacd87a15c7781cfe1e91e` |
| `tcpreg_j6.sh` | `_proj_10g/notes/p7b_biz_tcpreg/` | `997f67d80839ce26717fe036e25f9781` |
| `pcap_off_dryrun.sh` | `_proj_10g/notes/p7b_board_stagec/` | `3be0e9d757e00286a29efceb151de0a9` |
| `p7b_selftest.sh`（**未动**；本轮实跑 PASS=30） | `_proj_pcie/p7b_biz/` | `40c3f658b504b874c0df51037fa68f3a` |
| `aff_selftest.sh`（**未动**；本轮实跑全过, 含 CASE Q 的 END_MISMATCH 硬门） | `_proj_pcie/p7b_biz/` | `19cb9f2d9781e8a338246960e3c340ff` |
| `p7b_dualthread_selftest.sh`（**未动**；本轮实跑 PASS=48） | `_proj_pcie/p7b_biz/` | `902c01079f9bd7bf32b939f596882be0` |
| `p7b_lane8_selftest.sh`（⭐ **新门**, 本轮, 42 条判据, §5d） | `_proj_pcie/p7b_biz/` | `ac6d56dca7d203fe4b7a281fa0a1bb53` |
| `p7baff_faultinject.cpp`（**上一轮的仪器, 本轮重新部署**；供新门做 R2 的确定性注入） | `_proj_10g/notes/p7b_affinity/` | `23a01d88b6acd01587f70692e421b476`（与 §5a 逐字相同） |
| `s2_setup.sh`（三条编译行 → `-O3 -pthread`） | `_proj_10g/notes/p7b_biz_s2/` | `c011336cb6c38afd2826fe4fe3b8c541` |
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

## 4b. ⭐ 2026-10-09 收口：三条编译行统一 + `-O2`/`-O3` 同源 A/B

**(1) 三条互相打架的编译行 = 就地收口**（本坑最后一次出现的机会，改了 5 处）：

| 位置 | 改前 | 改后 |
|---|---|---|
| **本文件 §2（权威）** | `g++ -O2 -pthread -o <name> <name>.cpp` | **`g++ -O3 -pthread -o <name> <name>.cpp`** |
| `_proj_10g/notes/p7b_biz_s2/s2_setup.sh:13-15` | `g++ -O2 -o …` | `g++ -O3 -pthread -o …`（与 §2 逐字同款） |
| `p7b_selftest.sh:45`（T0 自检） | `g++ -O2 -pthread -Wall -o $t $t.cpp` | `g++ -O3 -pthread -Wall -o $t $t.cpp`（多一个 `-Wall` = 只多告警、不改 codegen） |
| 各 `.cpp` 头注释（7 个文件） | `g++ -O2 -o …` / `g++ -O2 -pthread -o …` | `g++ -O3 -pthread -o <name> <name>.cpp` |
| ⚠️ **例外** | `p7b_tcp_src_diag.cpp:24` | **仍写 `g++ -O2 -o …`（未动该文件）** —— 它是**负对照臂**、派单明令"不改"，且它是**下一个 patch 的起点**；**编译它用的是 `-O3 -pthread` 口径**，只是它自己的注释没换。⚠️ **这是全仓唯一已知的编译行分叉，已登记，待裁定是否补改。** |

⛔ 顺带纪律：**不要加 `-std=c++17`**（g++ 13 默认已是 `gnu++17`；用户只说了 `-O3`）。

**(2) `-O2` vs `-O3` 同源 A/B**（同一份 `p7b_rate2_bench.cpp`、同一会话、同一构型
`--core-send 4 --core-io 2 --core-work 3`（三颗不同物理核）、512 MiB、每臂 2 跑）：

| 模式 | `-O2` r1 / r2 | `-O3` r1 / r2 | 差 |
|---|---|---|---|
| `check-only`（纯校验天花板） | 5.1187 / 5.1206 Gbps | 5.1290 / 5.1330 Gbps | **+0.2%** |
| `recv-only`（接收天花板） | 43.688 / 43.564 | 43.270 / 43.481 | −0.4% |
| `recv-check`（旧单线程模型） | 4.7719 / 4.7148 | 4.7062 / 4.7654 | ~0 |
| `recv-check-split`（新双线程模型） | 5.0187 / 5.0119 | 5.0349 / 5.0137 | ~0 |

⇒ **结论**：换 `-O3` 在本次测量里**没有可观测收益**（全部落在 ±0.4% 的跑间散布内）——
瓶颈是 `P7bPat::check` 的**每字节一次 xorshift + 串行依赖**，编译器旗标拆不开它。
⇒ **口径纪律仍然成立**："凡引用 `-O2` 时代的历史读数（3707–3724 Mbps / 3.69→7.07 Gbps 等），
必须标注那是 **`-O2` 口径**"；但从本轮的实测看，**这不是"数字一定不同"，而是"不许默认它们可比"**。

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

### 5c. ⭐ 2026-10-09（双线程样板轮）

| 件 | 位置 | md5 | 作用 |
|---|---|---|---|
| `p7b_io.h`（**新头**：机制） | `_proj_pcie/p7b_biz/` / `/tmp/p7b_biz/` | `62b1257d69c40f24bfa9a799593073b7` | `now_s`/`set_nonblock`/`connect_nb`/`connect_to`/`poll_readable`/`die`/节流/EAGAIN 容忍判定（**只放机制, 不放策略**；⛔ `src_diag` 永不 include） |
| `p7b_spsc.h`（**新头**：无锁队列） | `_proj_pcie/p7b_biz/` / `/tmp/p7b_biz/` | `3132db495c29ab85b7f6a5617803644f` | 有界 SPSC 环形队列（head/tail 各自 `alignas(64)`、acquire/release、不用 mutex/不用无界队列） |
| `p7b_rate2_bench.cpp` / `p7b_rate2_bench`（**新仪器**） | `_proj_pcie/p7b_biz/` / `/tmp/p7b_biz/` | `791b1dc707894971b2eb352423a25aa7` / `b93e2e051870b872fc6a11c49f8c53e0` | 天花板台：`check-only` / `send-discard` / `recv-only` / `recv-check` / `recv-check-split`（回环、同会话可比）；`--core-send/--core-io/--core-work` 显式绑核 |
| `p7b_dualthread_selftest.sh`（⭐ **新门**, 48 条判据） | `_proj_pcie/p7b_biz/` / `/tmp/p7b_biz/` | `902c01079f9bd7bf32b939f596882be0` | D1 逐字节等价 / D2 **偏移语义定点牙**（4 个注入点, 两臂） / D3 **D2 的负对照**（去掉基偏移的突变件必须报不出 K） / D4 队列恒等式 / D5 TSan / D6 两颗物理核 + 掩码复算 + `/proc/<pid>/task/*/status` 交叉核 / D7 END_MISMATCH 不误杀 / D8 四个天花板 |

⭐ 实跑原文（`-O3 -pthread` 口径, 2026-10-09）：`p7b_dualthread_selftest.sh` = **PASS=48 FAIL=0
DUAL_SELFTEST_OK**；其中 D8 的四数 = `check-only 5.125` / `recv-only 43.17` / `recv-check 4.766` /
`recv-check-split 4.943` Gbps（256 MiB, `send=4/io=2/work=3`）。

### 5d. ⭐ 2026-10-09（R1/R2/R4 轮：M^8 lane-parallel + `CPU_FREQ_KHZ` 语义订正）

| 件 | 位置 | md5 | 作用 |
|---|---|---|---|
| `p7b_lane8_selftest.sh`（**新门**, 42 条判据） | `_proj_pcie/p7b_biz/` / `/tmp/p7b_biz/` | `ac6d56dca7d203fe4b7a281fa0a1bb53` | L1–L6 等价自检（表复核 / 长序列三全等 / 6 点注入 / 跨块 12 状态）· **L7/L8 突变负对照**（砍尾段 / 表翻 1 位 ⇒ 必须翻红）· L9–L11 开关端到端 A/B（真 socket ⇒ 真跨块）· L12 默认 = seq · L13 未知模式 RC=2 · L14 加速正证据 · **L15/L16 R2 的确定性注入** |
| `p7baff_faultinject.cpp`（**重新部署**） | `_proj_10g/notes/p7b_affinity/` / `/tmp/p7b_biz/` | `23a01d88b6acd01587f70692e421b476` | LD_PRELOAD 路径重映射 ⇒ 把**指定核**的 `scaling_cur_freq` 换成常数 8888000（L15/L16 用它做**确定性**判据：报的是"干活核"还是"打行那条线程的核"）|
| `pmu_phases.cpp`（**scratch**，⛔ 非部署件） | 对端 `/tmp/l8_pmu/` | — | 把**生成相**与**校验相**分开整跑 ⇒ 两跑相减得到每一相的**精确** PMU 计数（bench 的 check-only 里两相混在一起）|

⭐ **R4 读数（本机回环, 512 MiB, `--core 5 --core-send 4 --core-io 2 --core-work 3`, 3 跑取中位）**：

| 模式 | `--check seq`（旧口径） | `--check lane8`（新） | 比 |
|---|---|---|---|
| `check-only`（纯校验） | 5.1280 Gbps | **11.2737** Gbps | ×2.198 |
| `recv-check`（旧单线程模型） | 4.7431 | **9.5277** | ×2.01 |
| `recv-check-split`（双线程模型, **端到端**） | 4.9170 | **11.1528** | ×2.27 |

⇒ **端到端 11.15 Gbps 已站到 TCP 线上载荷天花板（9.493 Gbps）之上** —— 台架不再是帽子。
⚠️ 全部 `first_mismatch=-1` / `mism_bytes=0`，两臂 `check=` 见证与传入值一致。

⭐ **PMU（`sudo perf stat`, 本机 AMD Zen）** —— `stalled-cycles-frontend/backend` 在本 CPU **`<not supported>`**
（Intel 专有）⇒ 改用 `l1d_pend_miss.pending_cycles` + `l1d.replacement` + IPC 代理。
**`kernel.perf_event_paranoid` 保持 4（未改）** —— root 绕开它, 所以**没有**运行时改动要做/要还原。
分相（`gen` / `gen+check` 两跑相减, 256 MiB, 逐相精确）：

| 相 | cycles/byte | instr/byte | IPC | L1 loads/byte | loads/cycle | L1 miss 率 | L1-miss 挂起周期占比 |
|---|---|---|---|---|---|---|---|
| `gen`（fill） | 6.70 | 15.1 | 2.25 | 0.37 | — | 9.4% | 1.1% |
| `check_seq` | **6.07** | 16.0 | **2.64** | 0.99 | — | 1.65% | **0.64%** |
| `check_lane8` | **2.73** | 5.57 | **2.04** | 2.36 | **0.86**（2 口宽 ⇒ 43%） | 3.11% | 15.8% |

⚠️ **`-march=native` 实测 = 无收益**（lane8 11.2568 → 11.2489 Gbps, −0.07%; 同跑的**指令数几乎逐字相同**
11.0715e9 → 11.0728e9）—— ISA 差异（`shlx/shrx/vpxor/vmovdqu`）只出现在**库函数**里, 三个热循环没被改写。
⚠️ **D3 的突变件**（`sed` 把 `SinkItem out{held, got, …}` 的 `got` 换成 `0`）实测把
`first_mismatch` 从 **500000** 报成 **41248**（= 500000 − 7×65536 = 本块内偏移）⇒ **那条判据有牙**。

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
$P tools/peer_ssh.py --put "$(cygpath -w _proj_pcie/p7b_biz/p7b_dualthread_selftest.sh)"        /tmp/p7b_biz/p7b_dualthread_selftest.sh
$P tools/peer_ssh.py --put "$(cygpath -w _proj_pcie/p7b_biz/p7b_fake_board.py)"                /tmp/p7b_biz/p7b_fake_board.py
# 自检 (都不碰板子): bash /tmp/p7b_biz/pcap_off_dryrun.sh ; bash /tmp/p7b_biz/p7b_selftest.sh 18899
#                     bash /tmp/p7b_biz/p7b_dualthread_selftest.sh 18900
```

⭐⭐ **2026-10-09 双线程样板轮的**部署清单（**新头必须一起上** —— 否则 sink 编不过）：

```bash
P=/c/Users/zhxue/anaconda3/python.exe
B=D:/repo/XCKU5PMini/udp_hls_10g
for f in _proj_pcie/p7b_biz/p7b_io.h _proj_pcie/p7b_biz/p7b_spsc.h \
         _proj_pcie/p7b_biz/p7b_affinity.h _proj_pcie/p7b_biz/p7b_tcp_sink.cpp \
         _proj_pcie/p7b_biz/p7b_tcp_src.cpp _proj_pcie/p7b_biz/p7b_udp_src.cpp \
         _proj_pcie/p7b_biz/p7b_rate2_bench.cpp \
         _proj_pcie/p7b_biz/p7b_selftest.sh _proj_pcie/p7b_biz/p7b_dualthread_selftest.sh \
         _proj_10g/notes/p7b_biz_tcpreg/p7b_tcp_src_fix.cpp \
         _proj_10g/notes/p7b_board_stageb/p7b_tcp_src_rate.cpp \
         _proj_10g/notes/p7b_board_stagec/p7b_tcp_sink_rate.cpp; do
  $P tools/peer_ssh.py --put "$B/$f" "/tmp/p7b_biz/$(basename $f)"
done
# 然后按 §2 的 for 循环重编 8 个产物, 再按 §3 对 md5
```
⚠️ `cygpath -w` / 绝对 Windows 路径不是装饰（`--put` 收 Windows 路径；MSYS 的 `/tmp/...` 会被
当成不存在的文件）—— 但 **Git Bash 下 `D:/...` 正斜杠写法也可用**（实测）。

⭐ **2026-10-09 R1/R2/R4 轮追加的部署件**（在 §6 上面那批之外）：

```bash
P=/c/Users/zhxue/anaconda3/python.exe
B=D:/repo/XCKU5PMini/udp_hls_10g
$P tools/peer_ssh.py --put "$B/_proj_10g/notes/p7b_affinity/p7baff_faultinject.cpp" /tmp/p7b_biz/p7baff_faultinject.cpp
$P tools/peer_ssh.py --put "$B/_proj_pcie/p7b_biz/p7b_lane8_selftest.sh"         /tmp/p7b_biz/p7b_lane8_selftest.sh
# 然后按 §2 的 for 循环重编 8 个产物, 再按 §3 对 md5
bash /tmp/p7b_biz/p7b_lane8_selftest.sh 18960        # 新门 (42 条判据; 不碰板子)
```
⚠️ **重编前先归档旧件**（"两只手"纪律）：`cp -n /tmp/p7b_biz/<8 个产物> /tmp/p7b_biz_prev/`
（本轮的负对照臂就在那里; 它**不是**部署目录, 不进判据链）。
⚠️ 新门要写 `/tmp/l8_selftest/`（自建）与 `/tmp/l8_mut*/`；**它自己编译突变件与注入器**（不需要预置）。

⚠️ **`cygpath -w` 不是装饰**：`peer_ssh.py --put` 收的是 **Windows 路径**（`/tmp/...` 这种
MSYS 路径会被当成不存在的文件，报 `FileNotFoundError`）。⚠️ 远端目录**必须先 `mkdir -p`**
（sftp 不建目录）。
