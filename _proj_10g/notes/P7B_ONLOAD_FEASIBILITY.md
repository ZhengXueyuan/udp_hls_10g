# P7B — Onload 可行性评估（共享 `\\192.168.1.71\...\solarflare`）

日期：2026-10-07　|　对端 = `a@192.168.0.38`（Ubuntu 24.04，内核 `7.0.0-34-generic`，Solarflare SFC9120 `1924:0903`）
共享只读路径（Git Bash）：`//192.168.1.71/home/Download/drivers/solarflare/`
纪律：**只读共享；构建只在 /tmp；未 install / 未 insmod / 未刷固件 / 未改网络 / 未动板子（`0x08` 全程未写）**。

---

## 结论速览（先给判据）

| # | 问题 | 结论 |
|---|---|---|
| 1 | 四份 zip 是什么版本 | **全部 = Onload 7.1.2.141（2021-06-29）**，只是打包形式不同（tarball / DKMS-RPM / SRPM / DEB-source） |
| 2 | ⭐ **能在内核 7.0.0-34 上构建吗** | ⛔ **不能。内核模块编译失败**（`linux_net` 有 **15 个 `.c` 文件**报错）。**用户态半边能编过（`--user` EXIT=0）**，但没用 —— 没有 `sfc.ko`/`onload.ko`，用户态栈不加速任何东西 |
| 3 | 有别的出路吗 | `KMP` / `sfutils 源码` **都不行且不必要**；`sfreport` **能用**（纯 Perl，已实测）；AMD 新版 Onload **从对端可达**（GitHub HTTP 200），且其 README 逐字声称支持 `kernel 6.1 - 7.0` / `Ubuntu LTS 24.04+` ⇒ **这是唯一现实出路，但本轮按指示未下载/未构建 ⇒ 未判定** |
| 4 | ⭐ 就算装上对本工程有什么用 | **风险大于收益**。最大的一条：Onload **不实现 `SO_MAX_PACING_RATE`**（`src/` 里 0 命中，且有逐字厂商注释承认"Onload does not support pacing"）⇒ 我们的 **pace 阶梯判据会安静失效** |
| 5 | 安全边界 | 已遵守，peer 终态已复核未变（见 §5） |
| 6 | `drivers1/2` mtime = 今天 09:47 | **不是有人改内容**；是 Windows 资源管理器今天浏览该共享、重写了 `Thumbs.db` 从而刷新了目录 mtime。载荷文件全部保持 2022 年 mtime（见 §6） |

---

## §1　版本与支持矩阵

### 1.1 四份 zip（`ls -la` + `unzip -l` 逐字）

```
-rw-r--r-- 4475885 Jan  9  2022 SF-109585-LS-36_OpenOnload_Release_Package.zip
-rw-r--r-- 4509339 Jan  9  2022 SF-120887-LS-7_OpenOnload_DKMS_Release_Package.zip
-rw-r--r-- 4522407 Jan  9  2022 SF-122450-LS-6_OpenOnload_SRPM_Release_Package.zip
-rw-r--r-- 4481906 Jan  9  2022 SF-122451-LS-6_OpenOnload_DEB_Release_Package.zip
```

`unzip -l` 结果（每份内容）：

| zip | 唯一载荷 | 附带文档 |
|---|---|---|
| `SF-109585-LS-36` | `onload-7.1.2.141.tgz`（4398243 B）+ `.tgz.md5` | ChangeLog / LICENSES-ALL / README.txt / ReleaseNotes.txt（四份 zip 的这四个文档**长度逐字相同**：147158 / 91446 / 3165 / 7292） |
| `SF-120887-LS-7` | `onload-dkms-7.1.2.141-0.noarch.rpm` | 同上四份 |
| `SF-122450-LS-6` | `onload-7.1.2.141-1.src.rpm` | 同上四份 |
| `SF-122451-LS-6` | `onload_7.1.2.141-debiansource.tgz` | 同上四份 |

⇒ **四份 = 同一个版本的四种打包**，不是四个版本。已解出的目录树
`onload/109585/onload-7.1.2.141/onload-7.1.2.141/` 内容与 tarball 一致。

md5 已核（拷到本机后逐字）：
```
bfda4a68267e2aa3d5bed02af229b4fc *onload-7.1.2.141.tgz   ← 实测
bfda4a68267e2aa3d5bed02af229b4fc  onload-7.1.2.141.tgz   ← 包内 .md5 文件逐字
```

### 1.2 各包**逐字**声称支持的内核 / 发行版

**`onload-7.1.2.141-ReleaseNotes.txt`（Onload-7.1.2 节，行 9–21）逐字：**
```
Linux distribution support
--------------------------

 This package is supported on:
 - Red Hat Enterprise Linux 6.9 - 6.10
 - Red Hat Enterprise Linux 7.6 - 7.9
 - Red Hat Enterprise Linux 8.1 - 8.4
 - SuSE Linux Enterprise Server 12 sp4 and sp5
 - SuSE Linux Enterprise Server 15 sp1 and sp2
 - Canonical Ubuntu Server LTS 18.04 and 20.04
 - Debian 9 "Stretch"
 - Debian 10 "Buster"
 - Linux kernels 4.4 - 5.12
```

**`README`（行 21–25、27–34）逐字：**
```
Supported platforms
===================

 Linux kernels from 4.4.
...
 Onload supports Solarflare SFC9000 network controller chips,
 including the following network adapters:
   X2541, X2542
   X2522, X2522-25G
   SFN8042
   SFN8522, SFN8522M, SFN8542, SFN8722
   SFN7142Q
   SFN7122F, SFN7322F, SFN7124F
```
（`SFN7122F / SFN7322F / SFN7124F` = SFC9120 系列板卡 —— ⚠️ 该"芯片↔型号"对应为厂商产品线常识，**本轮未在板上逐字核实**。本板 NIC 逐字为 `Solarflare Communications SFC9120 10G Ethernet Controller [1924:0903] (rev 01)`。）

**README 末尾逐字（版本自证）：**
```
 version: onload-7.1.2.141
revision: 7a0183d2a37e23ea93272ad1f362c8dec6e8dd3c
    date: Tue 29 Jun 15:01:22 BST 2021
```

**对端** = `Linux a-MS-7850 7.0.0-34-generic ... Ubuntu`。
⇒ **声明上限 5.12，对端 7.0.0-34 ⇒ 缺口 = 5.13 … 7.0（≈14 个内核版本、约 2.5 年）。**

### 1.3 另外两个包的版本（`drivers1`/`drivers2`）

**`SF-123416-LS-8_releasenote.txt` 逐字：**
```
Solarflare 4.X Linux network driver
===================================
Version:  v4.15.14.1001
...
 - Kernel.org linux kernels                       3.0 to 5.11
```

**`SF-105095-LS-66_releasenote.txt`** = Linux/ESX Utilities 源码（`sfutils 8.2.4.1004`）的 release note（78919 B，与 `drivers1` 那份**逐字同长**）。

---

## §2　⭐ 能在对端内核 7.0.0-34 上构建吗 —— **不能**

### 2.1 第一刀：`./scripts/onload_build --kernel`

（tarball md5 已在 peer 复核为 OK；解到 `/tmp/sf_build/`）

```
$ cd /tmp/sf_build/onload-7.1.2.141 && ./scripts/onload_build --kernel
EXIT=1
```
逐字（`V=1` 详细日志，行 1–38 摘）：
```
make -C /usr/src/linux-headers-7.0.0-34-generic CC="cc" M=$(pwd)
make[2]: Entering directory '/usr/src/linux-headers-7.0.0-34-generic'
make[3]: Entering directory '/tmp/sf_build/onload-7.1.2.141/build/x86_64_linux-7.0.0-34-generic/driver/linux_net'
warning: the compiler differs from the one used to build the kernel
  The kernel was built by: x86_64-linux-gnu-gcc-13 (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
  You are using:           cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
warning: pahole version differs from the one used to build the kernel
  The kernel was built with: 125
  You are using:             0
/tmp/sf_build/onload-7.1.2.141/src/driver/linux_net/Makefile:61: SFE4001/Falcon is no longer supported
/tmp/sf_build/onload-7.1.2.141/src/driver/linux_net/Makefile:237: FORCE prerequisite is missing
  UPD     config.h
kernel_compat.sh: Kernel build tree is unable to build modules
make[5]: *** [/tmp/.../src/driver/linux_net/Makefile:237: autocompat.h] Error 1
make[4]: *** [/usr/src/linux-headers-7.0.0-34-generic/Makefile:2134: .] Error 2
make[3]: *** [/usr/src/linux-headers-7.0.0-34-generic/Makefile:248: __sub-make] Error 2
make[2]: *** [Makefile:248: __sub-make] Error 2
make[1]: *** [/tmp/.../src/driver/linux_net/Makefile:300: modules] Error 2
make: *** [../../src/mmake.mk:58: all] Error 2
onload_build: ERROR: Failed to build driver components.
```

**这个 abort 是"构建脚手架"的 abort，还没有走到源码** —— 死因逐字（`-v` 打印的编译器输出）：
```
    make[6]: *** No rule to make target 'modules', needed by '../linux/sfc.ko'.  Stop.
```

### 2.2 隔离脚手架问题（**我的诊断，非厂商陈述**）

`kernel_compat.sh` 在开工前先探测"内核树能不能编模块"：`test_compile` 跑
`make -rR -C $KPATH M=$dir O=$KOUT`，其中 `KPATH`/`KOUT` 都是 `$(CURDIR)`（`Makefile:225-234` 的
`filechk_autocompat.h`）。在本机这条探测自证失败：

- `-o` 必须是**内核输出树**；主构建传的是 onload 自己的 build 目录 ⇒ 逐字：
```
    ***  ERROR: Kernel configuration is invalid. The following files are missing:
    ***    - /tmp/sf_probe/include/generated/autoconf.h
```
- **更底层的一条**：`read_make_variables()`（`kernel_compat_funcs.sh:380-396`）用
  `sed -r "s#$dir/Makefile:.*: ($regexp)=.*$)#\1#; t; d"` 解析 `$(warning)` 行，
  **要求前缀是 `$dir/Makefile:NN:`**；而本机 make 实际打印的是**裸 `Makefile:NN:`**。实测逐字：

```
raw warning lines:
Makefile:1: KBUILD_SRC=
Makefile:2: ARCH=x86
Makefile:3: SRCARCH=x86
Makefile:5: CONFIG_X86_64=y
Makefile:7: abs_srctree=
--- sed result (what read_make_variables returns) ---
--- END(empty above = broken) ---
```
⇒ `eval` 到空 ⇒ `SRCARCH=""` ⇒ 逐字失败：
```
kernel_compat.sh: /usr/src/linux-headers-7.0.0-34-generic doesn't directly build
```
（该行源码 = `[ -f "$KBUILD_SRC/arch/$SRCARCH/Makefile" ] || fail ...`；
实测 `/usr/src/linux-headers-7.0.0-34-generic/arch//Makefile: No such file or directory`。）

**在 /tmp 里把这行 sed 换成 `sed -r "s#^.*Makefile:[0-9]+: ##" | grep -E "^${regexp})="` 之后，
`kernel_compat.sh` EXIT=0、`autocompat.h` 正常生成** ⇒ 脚手架这一层是可以绕过的。
（⚠️ 这**只**说明探测脚本解析失配，**不**说明源码能编 —— 见下。）

### 2.3 ⭐ 第二刀（决定性）：**源码本身编不过**

绕过脚手架后，写一个最小 kbuild Makefile 直接编 `linux_net` 的模块（`obj-m := sfc.o`，
`sfc-y` 按 `src/driver/linux_net/Makefile:161-190` 逐字照抄，
`EXTRA_CFLAGS` 按 `:196-215` 照抄）。**结果：15 个 `.c` 文件报错。**

出错文件（逐字去重）：
```
debugfs.c  ef10.c  ef10_sriov.c  efx.c  ethtool.c  farch.c  ioctl.c
kernel_compat.c  mcdi.c  mcdi_port.c  mtd.c  nic.c  ptp.c  rx.c  tx.c
```

错误种类与计数（`grep -oE "error: [^;]*" | sort | uniq -c | sort -rn`，逐字，取前 20）：

```
     26 error: static declaration of ‘page_frag_free’ follows non-static declaration
     26 error: request for member ‘fds_bits’ in something not a structure or union
     26 error: implicit declaration of function ‘FD_SET’ [-Werror=implicit-function-declaration]
     26 error: implicit declaration of function ‘FD_ISSET’ [-Werror=implicit-function-declaration]
     26 error: implicit declaration of function ‘FD_CLR’ [-Werror=implicit-function-declaration]
      5 error: implicit declaration of function ‘strlcpy’
      2 error: ‘struct mtd_info’ has no member named ‘usecount’
      2 error: initialization of ‘int (*)(struct net_device *, struct ethtool_coalesce *, struct kernel_ethtool_coalesce *, struct netlink_ext_ack *)’ from incompatible pointer type ...
      1 error: ‘UDP_TUNNEL_NIC_INFO_MAY_SLEEP’ undeclared here (not in a function)
      1 error: too many arguments to function ‘netif_napi_add’
      1 error: too few arguments to function ‘full_name_hash’
      1 error: too few arguments to function ‘bpf_warn_invalid_xdp_action’
      1 error: ‘struct napi_struct’ has no member named ‘gro_list’
      1 error: ‘struct kobj_type’ has no member named ‘default_attrs’
      1 error: ‘RPS_NO_FILTER’ undeclared (first use in this function)
      1 error: invalid type argument of ‘->’ (have ‘struct device’)
      1 error: initializer element is not computable at load time
      1 error: initialization of ‘void (*)(struct net_device *, struct ethtool_ringparam *, struct kernel_ethtool_ringparam *, struct netlink_ext_ack *)’ from incompatible pointer type ...
      1 error: initialization of ‘int (*)(struct net_device *, struct kernel_ethtool_ts_info *)’ from incompatible pointer type ...
      1 error: initialization of ‘int (*)(struct net_device *, struct ethtool_rxfh_param *, struct netlink_ext_ack *)’ from incompatible pointer type ...
```
另有逐字：
```
efx.c:614:9: error: implicit declaration of function ‘xdp_do_flush_map’; did you mean ‘xdp_do_flush’?
efx.c:4668:17: error: implicit declaration of function ‘strlcpy’; did you mean ‘strncpy’?
efx.c:5659:9: error: implicit declaration of function ‘pci_disable_pcie_error_reporting’ ...
efx.c:5938:15: error: implicit declaration of function ‘pci_enable_pcie_error_reporting’ ...
ptp.c: error: ‘const struct ptp_clock_info’ has no member named ‘adjfreq’
... implicit declaration of function ‘skb_gso_segment’ / ‘pci_alloc_consistent’ / ‘pci_free_consistent’ / ‘d_hash_and_lookup’
```
⇒ 这**不是**打包/脚手架的毛病，是**跨 5.12→7.0 的一整族内核 API 删除与签名变更**
（`strlcpy` 移除、`netif_napi_add` 去 weight 参数、`xdp_do_flush_map`→`xdp_do_flush`、
`pci_*_pcie_error_reporting` 移除、ethtool ops 全套加 `kernel_ethtool_*`/`netlink_ext_ack`、
`ptp_clock_info.adjfreq` 移除、`fd_set/fds_bits` 与 `page_frag_free` 等等）。
⚠️ "每条对应哪次内核提交"是**按名判断、本轮未逐条回 7.0 源码核**，但"编不过"这个结论是实测的。

### 2.4 用户态半边：**编得过，但没用**

```
$ ./scripts/onload_build --user
EXIT=0
```
（`build/gnu/` 下库与测试程序全部产出。该路径不调用 `kernel_compat.sh`。）
⇒ Onload 的用户态栈必须配它自己的内核模块（`onload.ko` + `sfc_resource.ko` + 它自己的 `sfc.ko`）
才能接管 socket；**内核模块编不出来 ⇒ 整个 Onload 用不了**。

> ⚠️ 未跑到：`linux_onload` / `linux_resource` / `linux_affinity` 三个模块**没有逐个编到**
> （主构建在 `linux_net` 处即中止）。但 `linux_net` 编不出来 ⇒ `sfc.ko` 不存在 ⇒ 全线不通，结论不变。

---

## §3　其他出路（逐条）

### 3.1 `SF-123416-LS-8_Solarflare_NET_driver_KMP.zip` —— ⛔ 不可用，且**不必要**

`unzip -l` 逐字，包内只有 **2 个预编译二进制 RPM**：
```
   206748  2021-12-07 03:06   solarflare-sfc-kmp-default-4.15.14.1001_k5.3.18_57-2.1.x86_64.rpm
   206092  2021-12-07 03:06   solarflare-sfc-kmp-preempt-4.15.14.1001_k5.3.18_57-2.1.x86_64.rpm
```
⇒ ① 只有二进制、无源码；② 是 **RPM**（对端是 Ubuntu/dpkg，连 `rpm`/`rpm2cpio` 都没装）；
③ 目标内核是 **SLES `k5.3.18_57`**（release note 自述上限 `3.0 to 5.11`）。
**对 Ubuntu 24.04 / 7.0.0-34 完全用不上。**

**"不必要"有硬证据**：对端**已经**由**主线内建 sfc 驱动**驱动着这张卡，逐字：
```
$ ethtool -i enp1s0f1np1
driver: sfc
version: 7.0.0-34-generic
firmware-version: 6.2.7.1001 rx1 tx1
bus-info: 0000:01:00.1
$ ls -l /sys/bus/pci/devices/0000:01:00.0/driver
... -> ../../../../bus/pci/drivers/sfc
```
我们**现有的全部板级测量**（P6e/P6b/P7b 各轮）都跑在这个内建 `sfc` 上 ⇒ **vendor 驱动不是缺口**。

### 3.2 `SF-105095-LS-66` 工具源码 —— ⛔ 不需要（且越界）

`drivers2` 里那份 = `sfutils-8.2.4.1004-1.src.rpm`。用 python 解 cpio + tar 后逐字：
```
entries: 3
    23022313  sfutils-8.2.4.1004.tar.gz
        2728  sfutils.spec
sfutils-8.2.4.1004/
sfutils-8.2.4.1004/app/            ← sfboot/ sfupdate/ ...
sfutils-8.2.4.1004/imported_firmware/
sfutils-8.2.4.1004/sfupdate_images/   ← 固件镜像
```
⇒ 这是 **`sfboot` / `sfupdate`（刷固件）/ `sfctool`** 一族的源码 —— 既**不需要**（§3.1 已证驱动不缺），
又**正撞我们的安全边界**（⛔ 不许刷固件）。

### 3.3 `sfreport`（诊断工具） —— ✅ **能用**

`SF-108317-LS-6_Solarflare_Linux_diagnostics_(sfreport).tgz` 里**只有一个文件 `sfreport.pl`**（2571 行，纯 Perl）。
它**不依赖 Onload、不依赖任何内核模块**，只是个采集器：`grep -oE "\b(ethtool|sfctool|sfupdate|sysctl|dmidecode|lspci|modinfo|dmesg|onload|sfboot|dd)\b"` ⇒
`ethtool`×7 / `onload`×6 / `dmesg`×6 / `sfboot`×5 / `dmidecode`×4 / `sysctl`×3 / `modinfo`×3 / `sfupdate`×2 / `lspci`×1。

**实测（对端，非 root，输出到 /tmp）逐字：**
```
$ perl /tmp/sfreport.pl -m -
RC=0
CSV:Solarflare inventory report
enp1s0f0np0,1924:0903,01,1924:800c,sfc,0000:01:00.0,7.0.0-34-generic,6.2.7.1001 rx1 tx1,00:0f:53:2c:68:00,,,,,N/A
enp1s0f1np1,1924:0903,01,1924:800c,sfc,0000:01:00.1,7.0.0-34-generic,6.2.7.1001 rx1 tx1,00:0f:53:2c:68:01,,,,,N/A
```
⇒ **能正确认出我们的 NIC 与驱动**。限制：① 完整报告要 root；② `sfupdate`/`sfboot`/`sfctool`
三个外部命令**在 peer 上不存在**（逐字 `sfupdate: ABSENT` / `sfboot: ABSENT` / `sfctool: ABSENT`，
**运行前先核过**，所以 sfreport 里那几条"刷固件工具"的代码路径在本机是**惰性的**）。
⇒ **价值 = 一个独立的板卡/NIC 只读快照器**，与我们的判据链完全解耦。**与 Onload 无关。**

### 3.4 `sfptpd`（增强 PTP 守护进程） —— 用户已裁定不需要

（本轮不再展开。）仅登记一条相关事实：对端内核配置里 **`CONFIG_SFC_PTP` 未置位**
（`grep -n "SFC_PTP\|SFC_PPS\|SFC_DEBUG_FS\|SFC_DIAG" /boot/config-7.0.0-34-generic` ⇒ **空**），
所以 `/sys/class/ptp/` 下**只有 `ptp0 -> iwlwifi-PTP`**，网卡**没有**暴露 PTP 时钟；`/sys/kernel/debug/sfc` 也不存在。

### 3.5 从 AMD 官方拿新版 Onload —— **路是通的，版本窗口正好罩住我们**

（按指示：**只做网络可达性判断，未下载、未安装。**）

**可达性（`curl -s -o /dev/null -w '%{http_code}'`，逐字）：**

| URL | 本机（Windows） | 对端 `192.168.0.38` |
|---|---|---|
| `https://github.com/Xilinx-CNS/onload` | HTTP 000 | ✅ **HTTP 200** |
| `https://www.amd.com/` | HTTP 000 | HTTP 000 |
| `https://support-nic.xilinx.com/` | HTTP 000 | HTTP 000 |

⇒ **对端能到 GitHub 的 `Xilinx-CNS/onload`**；AMD 官方站点两个域名从对端**都不可达**。

**上游 `README.md`（经对端拉取）逐字：**
```
## Compatible Linux kernels and distributions

This source tree is expected to be compatible with the following Linux kernels
and distributions:

* Debian 12+
* Ubuntu LTS 24.04+
* EL 9.0+, 10.0+
* kernel.org Linux kernels 6.1 - 7.0
```
```
### Compatible AMD Solarflare network adapters

The following adapters are able to support OpenOnload without AF_XDP:

* SFN8522, SFN8542, SFN8042
* X2522, X2522-25G, X2541
* X3522
```
```
## Support

The publicly-hosted repository is a community-supported project. ...
Incompatibilities introduced by recent kernel versions are likely
to be fixed rapidly here in this repository.
```

**两端读数并列：**

| 项 | 手上这份 7.1.2.141 | 上游 head-of-tree |
|---|---|---|
| 内核窗口 | `Linux kernels 4.4 - 5.12` | **`kernel.org Linux kernels 6.1 - 7.0`** |
| 发行版 | Ubuntu LTS **18.04 / 20.04** | **Ubuntu LTS 24.04+** |
| 适配器（免 AF_XDP） | 含 `SFN7122F / SFN7322F / SFN7124F`（SFC9120 系） | **`SFN8522, SFN8542, SFN8042, X2522, X2522-25G, X2541, X3522`** —— ⚠️ **SFC9120 系的型号不在这个列表里** |
| 支持等级 | 正式发布 | **community-supported**，另有 AMD 发布页版本 |

⇒ **两条结论：**
1. 对端（Ubuntu 24.04 + `7.0.0-34-generic`）**正好落在 head-of-tree 声明的支持窗口内** ⇒
   **新版很可能是唯一现实出路**；
2. ⚠️ **但上游那份"免 AF_XDP"适配器清单里没有 SFC9120 系的型号**。它把非清单网卡导向 AF_XDP，
   而 AF_XDP 那条路自述逐字 "**a community-supported work in progress that is not currently at release
   quality**"。⇒ **"上游能编"未必等于"我们的 SFC9120 能被加速"。**
3. ⛔ **未判定**：head-of-tree **在本机实际能不能编过**（按指示未 clone / 未 `onload_build`）；
   **SFC9120 是否真的还能被 Onload 加速**（清单缺席是提示，不是判决）。

（旁证，**非逐字证据、仅搜索摘要**：搜索结果显示 AMD 发布页最新为 **OpenOnload 9.2.0.43（2026-05-11）**，
且发布页不可从对端访问 ⇒ **引用需另找权威件**。均标为未核实。）

---

## §4　⭐ 就算装上，对本工程有什么用

### 4.1 对我们的**测量保真度 / 带宽**会怎么变

- **速率**：我们现在是"普通 socket + pacing"的 C++ 打流。Stage 2 里 TCP 上行已经实测到
  **板侧 `ΔW0 = 1,769,731`、丢帧计数全 0（≈8.4 Gbps）** ⇒ 在**干净链路 + 1518B 满帧**下，
  内核栈**不是**当时的瓶颈。⇒ Onload 换上去**未必能抬高这个数**：Onload 的真实优势在**延迟 / 每包 CPU 成本 / pps**，
  不在"干净链路上的大流吞吐"。⚠️ 这条是**推断**（我没跑过 Onload 的对照），标为**未实测**。
- ⭐ **pacing —— 这是致命项**：`grep -rn "SO_MAX_PACING_RATE" src/` ⇒ **0 命中**；
  全树仅 2 命中，且都在生成物 `build/gnu*/tools/ip/preprocessor_dump`（系统头文件的预处理转储）。
  更硬的是厂商自己的注释，`src/lib/transport/ip/tcp_sockopts.c:133-137` 逐字：
```
    /* Starting from linux-3.15, there are tcpi_pacing_rate and
     * tcpi_max_pacing_rate fields.  However, as Onload does not support
     * pacing, we might as well pretend that we simulate older kernel
     * with smaller tcp_info size. */
```
  ⇒ Onload 的 socket 层**不实现** `SO_MAX_PACING_RATE`，并且**故意截断 `tcp_info`** 来隐藏这两个字段。
  ⚠️ 它自有一套 **Tx QoS / 最小 IPG** 机制（`CI_CFG_RATE_PACING` →
  `EF_TX_QOS_CLASS` / `EF_TX_MIN_IPG_CNTL`，见 `netif_init.c:1077,1219`），那是**另一个旋钮**，不是同一个语义。

  ⇒ **后果**：我们 `--pace-bps`（= `SO_MAX_PACING_RATE`）的**阶梯在 Onload 下不再是受控量**，
  而 pace 阶梯正是 WU 轮 A/B 判决的脊梁（`P7B_BIZ_TCPREG.md` §6 要求"读数必须带 pace 值"）
  ⇒ **判据会安静失效**（全局 #48 的那一类）。**这是"要不要用 Onload"的第一顺位否决理由。**
  ⛔ **未判定**：Onload 对未知 sockopt 是吞掉、还是透传给它下面的内核影子 socket。

### 4.2 当"独立 oracle"的价值与局限

- **价值**：它是**另一个真正的 TCP 实现**（不是我们 RTL 的镜像），跑在**同一根线、同一块卡**上 ⇒
  对板子的 TCP 行为（如 `wu` 窗口通告缺陷、一次回卷重放整段、dup-ACK 三连）能提供**第二种反应**。
  按工程纪律，"**换一条独立的工具路径**"才是归因工具侧问题的唯一手段 —— 这一条它是符合的。
- **局限（必须同时写进判据）**：
  1. **它有自己的脾气**。Onload 有自己的窗口/重传/拥塞状态机（还有 `EF_TCP_COMBINE_SENDS_MODE`、
     `EF_UNCONFINE_SYN`、`EF_TCP_MAX_SEQERR_MSGS` 等一堆可调项）。
     板子的 `wu` 缺陷的表现形态（对端"等 ~208 ms persist"）**是内核 TCP 的表现**；
     换成 Onload 后**症状会变**，甚至可能被它自己的 persist/聚合逻辑**掩盖或放大**
     ⇒ **"症状变了"不等于"缺陷好了"**。
  2. **它不提供线上真值**。它仍是端侧实现，不是线上观测；按纪律"多校验器逐位一致 ≠ 数据没问题"，
     它**不能**单独当 oracle，只能与 pcap / 板侧自报计数**三方并列**。
  3. 它**换掉内核驱动**这件事本身会动到我们判据链的取样面（见 §4.3）。

### 4.3 ⚠️ 它对**我们既有测量脚本**的影响（逐条查过）

**好消息：既有脚本按字面不受影响。**
- `grep -rn "LD_PRELOAD"` 全仓（`*.sh/*.py/*.cpp/*.c/*.bat/*.tcl/*.txt`）⇒ **0 命中**；
- `grep -rn -E "^ *onload |\bonload [a-z_]+\.(exe|cpp|py)"` ⇒ **0 命中**。
- 对端侧打流工具的 socket 用法逐字：
  `udp_hls_10g/_proj_10g/notes/p7b_biz_tcpreg/p7b_tcp_src_diag.cpp:67` / `p7b_tcp_src_fix.cpp:67`
  `int fd = socket(AF_INET, SOCK_STREAM, 0);`
  `:74` `if (pace > 0) setsockopt(fd, SOL_SOCKET, SO_MAX_PACING_RATE, &pace, sizeof(pace));`
  `udp_hls_10g/tools/cpp_peer/udpsend.cpp:68` `SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);`
  ⇒ **全部是标准 BSD socket，没有任何 LD_PRELOAD 注入。**

⇒ Onload 的接管是**显式 opt-in**（`onload <cmd>` 前缀 / 显式 `LD_PRELOAD=libonload.so`），
**不会**自动污染未加前缀的进程。**所以"脚本文本"这一层是安全的。**

**坏消息（真正的耦合点）：`onload` 要换掉 `sfc` 内核模块。**
- 我们**全部**板级读数都骑在内建 `sfc` 上（`ethtool -i` 逐字 `driver: sfc / version: 7.0.0-34-generic`）。
  换驱动 = 换掉我们判据链的取样面本身。
- 尤其：`port_rx_*` / `port_tx_*` 这类计数**与内核是同源的**（工程记忆已登记"非独立硬件计数"）；
  换驱动后这些数**换了一套计算** ⇒ **前后两轮读数不可直接比**。
- `udp_hls_10g/_proj_10g/notes/p7b_biz_tcpreg/tcpreg_env.sh` 里对 `enp1s0f1np1` 做
  `ip link set ... up` + `ip addr add 192.168.100.100/32`；
  而 `/32` 已被 NetworkManager 冲掉过一次（工程记忆：根治 = `nmcli device set enp1s0f1np1 managed no`）
  ⇒ 驱动更替会与这套前置闸 / 地址配置**再叠加一层不确定性**。
- 另外 `onload_tool reload` / 驱动更替在**每次重启后都要重来**，而板子现在是**受控停流态**
  （`0x08 = 0x2` ⇒ `carrier = 0`；`enp1s0f1np1` 当前逐字 `DOWN <NO-CARRIER,BROADCAST,MULTICAST,UP>`）。

---

## §5　⚠️ 安全边界（本轮实际遵守情况，逐字复核）

**未做（纪律）**：刷固件（`sfupdate`/启动盘/`sfboot`）· `insmod`/`modprobe` · `make install` ·
改对端网络配置 · `apt install`（仅有只读的 `apt-cache policy onload`，输出为空）·
动板子 / 写 `0x08` · 在共享上解压。

**对端终态复核（与开工快照逐字相同）**：
```
ls -d /opt/onload /usr/lib64/onload   ⇒  No such file or directory / No such file or directory
modinfo onload                        ⇒  ERROR: Module onload not found.
lsmod | grep -E "^(sfc|onload|sfc_resource)"  ⇒  sfc 659456 0        ← 只有内建 sfc
find /lib/modules/7.0.0-34-generic -name "onload*"  ⇒  (空)
ip -br link show enp1s0f1np1          ⇒  DOWN  00:0f:53:2c:68:01 <NO-CARRIER,BROADCAST,MULTICAST,UP>
rx_bytes / tx_bytes                   ⇒  1183506586580 / 77263102313   ← 与开工快照逐字相同（无流量注入）
```

**本轮在 /tmp 留下的脚手架（全部惰性、无安装、无模块）：**
```
136M  /tmp/sf_build            (onload 解包 + build 目录)
5.2M  /tmp/sf_mod              (linux_net 源码副本 + 手写 Makefile + 生成的 autocompat.h)
12K   /tmp/sf_probe  20K /tmp/sf_probe2   (kernel_compat.sh 探测)
4.2M  /tmp/onload-7.1.2.141.tgz (+.md5)
23M   /tmp/sfutils-8.2.4.1004-1.src.rpm + /tmp/sfutils.tar.gz + /tmp/sfreport.pl
```
清理一条命令：`rm -rf /tmp/sf_build /tmp/sf_mod /tmp/sf_probe /tmp/sf_probe2 /tmp/onload-7.1.2.141.tgz* /tmp/sfutils* /tmp/sfreport*`

---

## §6　`drivers1` / `drivers2` 的 mtime = 今天是"有人在动"吗

**结论：不是有人在改内容 —— 是 Windows 资源管理器今天浏览了该共享、重写了 `Thumbs.db`，从而刷新了目录 mtime。**

逐字 `stat`：
```
//192.168.1.71/.../linux/drivers1                                   2026-10-07 09:47:11.103088400 +0800   0
//192.168.1.71/.../linux/drivers1/Thumbs.db                         2026-10-07 09:47:10.012000000 +0800   19968
//192.168.1.71/.../linux/drivers1/SF-105095-LS-66_releasenote.txt   2022-03-04 21:22:09.644000400 +0800   78919
//192.168.1.71/.../linux/drivers2                                   2026-10-07 09:47:10.180082100 +0800   0
//192.168.1.71/.../linux/drivers2/SF-105095-LS-66_..._Utilities_Source.zip  2022-03-04 21:29:30.604125200 +0800  22357163
```
判据：
1. `Thumbs.db` = **Windows Explorer 的缩略图缓存**，两个目录里各有一个，都是 09:47:10；
2. **`Thumbs.db` 的 mtime（09:47:10）早于/等于目录 mtime（09:47:10 / 09:47:11）** —— 典型"先建文件、后改目录 mtime"的顺序；
3. 两个目录在**同一秒**被刷新 ⇒ 同一次浏览动作；
4. **所有载荷文件仍是 2022-01/2022-03 的原始 mtime**（逐字见上）⇒ **内容没被动过**。
⇒ 是**假象**（准确说：是"有人今天**看了**这个共享"的物证，不是"有人在**改**它"的物证）。
⛔ **未判定**：具体是谁（哪台机器 / 哪个进程）在 09:47 浏览的 —— 只能从 `Thumbs.db` 反推是 Windows 侧的资源管理器行为。

---

## §7　建议（做 / 不做 / 先做哪一步）

**判：手上这批 Onload 材料 —— ⛔ 不可用（内核模块编不过，且内核 API 缺口遍布 15 个文件）。**
**且即使可用，对本工程的净价值为负**（pace 判据安静失效 + 换驱动的取样面风险）。

- ✅ **不做**：不要把 7.1.2.141 装上（编不过）；不要装 KMP（SLES 5.3.18 二进制、且不需要）；
  不要碰 `sfutils` 源码（刷固件工具，越界）；不要为了 Onload 去换内核或改网络配置。
- ⛔ **不要**把 Onload 引进来当"独立 oracle"然后忘掉 pace 这条 —— 如果用，**所有 pace 阶梯判据必须重写**（改用 Onload 自己的 `EF_TX_MIN_IPG_CNTL` 之类），否则就是在用一把**不自知的坏尺**。
- 🟢 **可以顺手做的（低风险、有即时收益）**：
  **`sfreport.pl` 已在 peer 上实测可用**（§3.3）—— 它是一个与 Onload 无关的**只读**板卡/NIC 快照器，
  能独立给出 NIC 型号/驱动/固件版本，可作为我们现有判据链之外的第二种取样。
  建议放进 `udp_hls_10g/tools/` 并只在**读数归档**时用（**不做判据**，避免又添一台"同源仪器"）。
- 🔶 **若确实想要新版 Onload（唯一现实出路）**，**第一步只做一件事、且必须先拿到授权**：
  在对端 `/tmp`（不是 `/opt`）`git clone --depth=1 https://github.com/Xilinx-CNS/onload`，
  然后 `./scripts/onload_build --kernel` **看能不能编过**（不 install、不 insmod）。
  判据：`build/*/driver/**/*.ko` 是否落盘。
  ⚠️ 但**先答一个问题再动手**：上游 README 的"免 AF_XDP"适配器清单里**没有 SFC9120 系型号**
  （§3.5）⇒ **要先把"SFC9120 还能不能被加速"问清楚**，否则可能白跑一轮。
- ⚠️ **优先级提醒**：本工程**当前的最优先项不是这个**。按 `P7B_HANDOFF.md` / 本目录纪律，
  第一优先是**接 `app_ctrl.stat_wu`(`0x96`) + `rx_occ_bytes` 进快照**（把 `wu` 机理从推断升为观测）
  —— 那件事**不需要 Onload**。

---

## §8　我没能判定的（如实登记）

1. **上游 head-of-tree Onload 在本机能否真编过** —— 按指示未 clone / 未构建。**未判定**。
2. **SFC9120 (`1924:0903`) 是否还在新版 Onload 的加速范围内** —— 上游 README 的免-AF_XDP 清单里没有它。**未判定**（清单缺席是提示，不是判决）。
3. **Onload 对未知 sockopt（`SO_MAX_PACING_RATE`）是吞掉还是透传给内核影子 socket** —— 只证到"它的 socket 层不实现"（`src/` 0 命中 + 厂商注释）。**未判定**。
4. **`linux_onload` / `linux_resource` / `linux_affinity` 三个模块的编译结果** —— 未逐个跑到（`linux_net` 先死）。不影响结论。
5. **每条编译错误对应哪次内核版本变更** —— 按符号名判断，**未逐条回 7.0 源码核**。
6. **AMD 官方发布页上的最新版本号/日期** —— `amd.com` 从对端与本机都不通（HTTP 000）；搜索结果给出 9.2.0.43 / 2026-05-11，但**非逐字证据，未核实**。
7. **SFC9120 芯片 ↔ SFN7122F/SFN7324F 等型号的对应** —— 属厂商产品线常识，**未在板上逐字核实**。
8. **`drivers1`/`drivers2` 的 mtime 是"谁"在 09:47 浏览造成的** —— 只证到是 Windows Explorer 的 `Thumbs.db` 行为。
9. **Onload 换上后我们的带宽会不会真的变好** —— 没有对照实验 ⇒ **未实测**。
