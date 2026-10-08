# BUILD.md — p7b_affinity.h 部署件的**构建命令 + 产物指纹**（F8，2026-10-08）

> 为什么有这份东西（F8 的动因）：对抗审查实测"部署件 97,800 B vs 重编 97,760 B、
> 85 个符号里 2 个尺寸不同" ⇒ 判"字节级不可复现"。**本文件把"实际用的那一条命令"钉死**，
> 让**下一次重编的人**能用同一条命令得到同尺寸（甚至同 md5）的产物。
> ⚠️ 本轮的实测结论与审查的措辞**不完全一致**，见 §4「可复现性实测（订正）」—— 以实测为准。

---

## 1. 部署位置与目标机

| 项 | 值 |
|---|---|
| 目标机 | 对端 Linux `192.168.0.38`（user `a`，key 免密；入口 `tools/peer_ssh.py`） |
| 部署目录 | `/tmp/p7b_biz/`（7 个二进制 + 7 个 .cpp + `p7b_affinity.h` + `p7b_pattern.h`） |
| 编译器 | `g++ (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0` |
| 构建时间 | 2026-10-08（本轮） |
| 行尾 | 仓库件与部署件**都是 LF**（无 CR）—— 部署是 `--put` 原样字节，**无任何转换步骤** |

## 2. 标准构建命令（**这就是唯一答案**）

```bash
cd /tmp/p7b_biz && g++ -O2 -o <name> <name>.cpp
```

7 个产物（同一个 for 循环、逐字同一条命令，只是 `<name>` 不同）：

```bash
cd /tmp/p7b_biz && for n in p7b_tcp_sink p7b_tcp_src p7b_udp_src \
    p7b_tcp_src_fix p7b_tcp_sink_rate p7b_tcp_src_rate p7b_tcp_src_diag; do
  g++ -O2 -o $n $n.cpp
done
```

⛔ **不要照抄每个 .cpp 头部那行注释里的 `g++ -O3 -std=c++17 -o ...`** ——
实测它给出的是**另一个二进制**（§4）。既有旗标 = 上面这条 `-O2`（无 `-std`）。

## 3. 产物指纹（6+1 = 7 个二进制；2026-10-08 构建）

| # | 产物 | 字节数 | md5 |
|---|---|---|---|
| 1 | `p7b_tcp_sink` | 102,216 | `10906f39eb7b93c7af633b38b3694c23` |
| 2 | `p7b_tcp_src` | 102,320 | `e1261ef4dc26086e55caefa1c9c646b9` |
| 3 | `p7b_udp_src` | 102,808 | `0be6a66eed88b775103d474f1a889171` |
| 4 | `p7b_tcp_src_fix` | 102,328 | `754e2dfe4b1137f69e164f0b5c1a0ea4` |
| 5 | `p7b_tcp_sink_rate` | 102,216 | `c90808c5a246b5d26c9f7b33122733f0` |
| 6 | `p7b_tcp_src_rate` | 102,328 | `2ab0058426b8b02fb438e742a5c81222` |
| 7 | `p7b_tcp_src_diag` | 102,328 | `732f13372e85b428249fcef348068fb8` |   ← F7 本轮新接线

> 大小相同 ≠ 同一份（1/5 都是 102,216；4/6/7 都是 102,328）——**只认 md5**。

**输入指纹**（部署件 == 仓库件，逐字节相同）：

| 输入 | 仓库出处 | md5 |
|---|---|---|
| `p7b_affinity.h` | `_proj_pcie/p7b_biz/p7b_affinity.h`（+5 份副本，全部同 md5） | `9b141b50c089b4065145879d642c58fb` |
| `p7b_tcp_sink.cpp` | `_proj_pcie/p7b_biz/` | `0d811ce70af25c6f022e44373c39882b` |
| `p7b_tcp_src.cpp` | `_proj_pcie/p7b_biz/` | `06ff21d635e6b9b77e11db8e377ca397` |
| `p7b_udp_src.cpp` | `_proj_pcie/p7b_biz/` | `03f81698c5002b94ed781e7aba5dbc27` |
| `p7b_tcp_src_fix.cpp` | `_proj_10g/notes/p7b_biz_tcpreg/` | `0827180011bfb0a28a9e38604295944f` |
| `p7b_tcp_src_diag.cpp` | `_proj_10g/notes/p7b_biz_tcpreg/` | `4c5c4fc5696dce7eebbf75b6281e1bc4` |
| `p7b_tcp_src_rate.cpp` | `_proj_10g/notes/p7b_board_stageb/` | `a8e5fce5232026fac37a4baf1f771f8e` |
| `p7b_tcp_sink_rate.cpp` | `_proj_10g/notes/p7b_board_stagec/` | `ed8e11cebe5a423d597ad7124ac9e023` |

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
⚠️ 审查报的 "97,760 B" 在本机**未能复现**（我实测的六个旗标组合给出的是 97,800 / 97,672 / 104,672 / 90,520 / 70,096，没有 97,760）
—— 差异可能来自别的工具链版本/别的源码修订。**判身份一律以 md5 为准，不以字节数为准**。

附带一条经验（本轮实测）：**只改注释/预处理守卫不改变 `.so` 字节** —— 给
`p7baff_faultinject.cpp` 加 `#ifndef _GNU_SOURCE` 守卫后，`.so` 的 md5（`a4e2bce4…`）**一字未变**。
⇒ "源码 md5 变了但产物 md5 没变"是正常情形，**判产物身份只看产物 md5**。

⚠️ **两条纪律留给下一次重编的人**：
1. 重编后**必须 diff md5**（大小相同也可能是另一份）；对不上先怀疑旗标，别先怀疑源码。
2. **别信 .cpp 头注释里的编译行** —— 它写的是 `-O3 -std=c++17`，与本目录的部署件**不是同一份**。

## 5. 本轮（2026-10-08）的配套仪器（都不是部署件，不进判据链）

| 件 | 位置 | md5 | 作用 |
|---|---|---|---|
| `p7baff_faultinject.cpp` / `libp7baff_faultinject.so` | `_proj_10g/notes/p7b_affinity/` / 对端 `/tmp/p7b_afftest/` | `23a01d88b6acd01587f70692e421b476` / `a4e2bce4aea9fc1d05cdbdb2fe4db531` | LD_PRELOAD 故障注入（deny 子串 / 路径重映射）——F2(topo/nic)、F4 的复现 |
| `p7baff_fake_softirqs.txt` | 同上 | `82a31bd1021984e23a8bb60e365eadbb` | 假 `/proc/softirqs`（核负载 3.0e9 > 2³¹）——F4 的溢出反例 |
| `f9_loopback_check.sh` | `_proj_10g/notes/p7b_affinity/` / `/tmp/p7b_afftest/` | `95d0689f2059eb63cad36b7df660560e` | F9 周期行验证（回环口，不碰板子；7 个产物全覆盖 + 同期独立读数 REFCUR） |
| `aff_selftest.sh` | `_proj_pcie/p7b_biz/` / `/tmp/aff_selftest/` | `19cb9f2d9781e8a338246960e3c340ff` | 板外自检（新增 F1/F2/F3/F6 判据 + `SKIP_NET=1` 开关） |

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
