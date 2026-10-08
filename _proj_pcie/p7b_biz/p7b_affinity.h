// ===========================================================================
// p7b_affinity.h -- PC 端测速程序的 "启动即绑核" 公共头 (P7b 验收基建, 2026-10-08)
//
// 动因 (用户裁定): PC 端测速程序必须绑核; 且必须**根据软中断等信息在启动时自动绑**;
//   绑核失败 = 硬门非零退出 (exit 2)。本轮验收抓到两类读数伪影:
//     ① warm-up 伪影: 换烧后头 3 次上行读数单调爬升 1379.5 -> 2927.7 -> 3982.4 Mbps;
//     ② 台架帽: sink 单线程 ~3.6-4.0 Gbps (`--nocheck` 揭穿同路径可达 7.07 Gbps)。
//   迁核 (migration) 与蹭到中断核都会给这两个读数加噪声。
//
// ---------------------------------------------------------------------------
// 用法 (每个程序 main() 的**第一条语句**, 一字不改地照抄):
//
//     argc = p7b_pin_cpu(argc, argv);
//
// 本函数**在 argv 里就地剥离自己的选项**并返回新 argc (剥离后保持 argv[argc]==NULL),
// 因此程序既有的参数解析器完全不受影响 —— 它只会看到自己认识的那些参数。
//
// 自己的选项 / 环境变量:
//   --no-pin                完全不绑 (**仅供对照**; 响亮: 见证行打 PIN_RULE=none PIN_CPU=none UNPINNED=1)
//   --core N                精确绑到逻辑核 N (精确复现用)
//   PIN_CORE=N              同 --core (**命令行优先**)
//     ⚠️ 两者都是**严格解析** (F1): 全串十进制 AND 落在 int 范围 AND 在在线集合内 ——
//        空串 / 非数字 / 尾随垃圾 (`5abc` `0x5` `+1`) / 溢出 (`4294967296`) / 不在线
//        ⇒ stderr 明确错误 + exit(2)。**绝不 atoi 截断** (旧实现 `--core 4294967296`
//        静默绑 CPU0 且 RC=0)。
//   PIN_RULE=auto|none      none == --no-pin; auto == 默认规则 (也接受 avoid-nic 字面量)
//   PIN_NIC_IFACE=<name>    覆盖 NIC 接口名自动探测 (只取这一个接口; 名字必须在 /sys/class/net 里)
//
// 优先级 (命令行 > 环境; 同一级冲突 = 用法错):
//   --no-pin 与 --core 同时出现在命令行          -> exit 2 (显式矛盾, 不静默取其一)
//   PIN_RULE=none 与 PIN_CORE 同时出现在环境里   -> PIN_RULE=none 胜 (= 对照组必须永远能跑)
//
// ---------------------------------------------------------------------------
// 默认选核规则 (PIN_RULE=avoid-nic):
//   1) 在线集合   /sys/devices/system/cpu/online
//   2) SMT 兄弟   /sys/devices/system/cpu/cpuN/topology/thread_siblings_list (形如 0,4 / 0-1)
//   3) NIC IRQ 落点: 遍历 /sys/class/net/*, 取 device/driver 符号链接 basename == "sfc"
//      的接口名 (PIN_NIC_IFACE 可覆盖); 再解析 /proc/interrupts: 表头行给 CPU0..CPUn 的
//      列映射, 凡**描述里包含**这些接口名的行都算 NIC IRQ, 逐核求和 = nic_irq[cpu]。
//      ⚠️ 描述列里没有 "sfc" 字样 (是接口名) —— 绝不要拿 sfc 去 grep 描述。
//   4) /proc/softirqs: NET_RX[cpu] + NET_TX[cpu] = net_soft[cpu]
//   5) **按物理核聚合**: core_load[pc] = sum_{t in pc} net_soft[t]; core_nic[pc] = sum nic_irq
//   6) 候选 = core_nic == 0 的物理核; **若为空 => 全部物理核入选** 并置 PIN_NIC_EXCLUDED=none
//   7) 候选中取 core_load 最小者, 并列取**物理核 id 最小**者 (确定性)
//   8) 该物理核内选线程: 取三元组 (**自身负载**, 兄弟负载, 线程号) 最小者 —— 即 **own-first**;
//      其中 "自身负载" = net_soft[t] + nic_irq[t], "兄弟负载" = sum_{s in pc, s != t} (net_soft[s] + nic_irq[s])
//   9) sched_setaffinity(0, ...) 绑单核
//   ⇒ 必须按物理核聚合打分, 否则会选中"与正在扛中断的线程共用物理核"的那条线程。
//
//   ⭐ **own-first 的由来 (2026-10-08 对抗审查裁定; 此前是 sib-first, 已废)**:
//     app 只占**一条逻辑线程** ⇒ 自身负载是一阶项、兄弟负载是二阶项; 且本机 (Haswell)
//     上 L1D/L2 本就两线程共用 ⇒ "跨线程丢局部性"这条反对理由不成立。
//     构造反例 (同一物理核内一条 own=2.0M、另一条 own=0): sib-first 会选**忙的那条** ⇒ 错。
//     本机 (Xeon E3-1275 v3, SMT (0,4)(1,5)(2,6)(3,7), NIC IRQ 铺满 4 个物理核 ⇒ 第 6 步走
//     退化分支) 上: 选定物理核 = {1,5}; **own-first ⇒ CPU5** (自身 0.73M, 兄弟 CPU1 9.74M)。
//     实际用的顺序打进见证行 **PIN_TUPLE_ORDER=own_sib_t** —— 顺序一改这个字段必须跟着改
//     ("不让语义靠注释活着")。要精确复现旧行为: `--core 1` / PIN_CORE=1。
//
// ---------------------------------------------------------------------------
// 尊重继承: 若进入时 sched_getaffinity 掩码**已经是单核** (例如被既有 `taskset -c N` 包裹,
//   见 P7B_BIZ_PLAN.md 的多进程洪泛用法) => **不覆盖**, 直接采用该核, PIN_RULE=inherit。
//   ⚠️ 这条不是可有可无的: 4 进程洪泛靠 `taskset -c $k` 分核, 若被本函数重新绑到同一个核,
//   多进程会被静默串行化 (吞吐判据直接失去意义)。--core / PIN_CORE 是**显式**请求, 优先于继承。
//
// ---------------------------------------------------------------------------
// 硬门 (任一触发 => stderr 打清晰错误 + **exit(2)**):
//   * 读不到 /proc/interrupts 或 /proc/softirqs 或 online 集合 (仅在默认规则下需要它们)
//   * 选不出核 / sched_setaffinity 返回 -1 (perror) / 绑后 sched_getcpu() != 目标
//   * --core N / PIN_CORE=N 格式非法 (空/非纯十进制/溢出 long/超 int) 或指向不在线/不存在的核
//   * PIN_NIC_IFACE 指定的接口在 /sys/class/net 里不存在
//   * PIN_RULE 取值非法
//   ⚠️ 退出码**必须是 2** (全族惯例: 2 = 用法/环境错)。
//   ⛔ **绝不用 3** —— 台架身份门 (stc_dl.sh 的 STC_GEOM_FAIL) 专属 3, 混用会让
//      "板上不是这个位流" 与 "绑核失败" 在日志里无法区分。
//   ⛔ **绝不用 124** —— stc_dl.sh 外层有 `timeout`, 124 = 被 timeout 杀掉。
//
// ---------------------------------------------------------------------------
// 见证 (无条件打到 stdout, 可 grep; 仿 PACE_BPS= 先例)。启动一行, 字段间空格分隔, 全 KEY=VALUE:
//   PIN_RULE=<avoid-nic|avoid-nic-degraded|inherit|core|none>
//     ⭐ **退化后缀 (F2)**: 默认规则**探针退化**时打 `avoid-nic-degraded` —— **不复用**
//        `avoid-nic`。于是"只 grep PIN_RULE 的判据"看见的是"它退化了", 不是"一切正常"。
//   PIN_DEGRADED=<none|nic|topo|nic+topo|n/a>
//     nic  = NIC 探针 **0 命中行** (接口没找到 / 描述里没有一行含接口名) ⇒ 第 6 步的排除没算
//     topo = `thread_siblings_list` 读不到/解析失败 ⇒ 静默退化成"每条线程当一个物理核"
//            (语义已变: 会选到"与扛中断线程共用物理核"的线程)
//     n/a  = 该模式没算 —— 非默认规则 (inherit/core) 不跑这条规则, --no-pin 根本没探测
//   PIN_CPU=<逻辑核号 | none(仅 --no-pin)>
//     ⭐ **PIN_CPU 是数值 <=> 这一跑真的绑了核** (none = 没绑)。下游判"有没有绑"只需
//        `grep -q "PIN_CPU=[0-9]"` —— 未绑的跑绝不会被读成已绑。
//        未绑时的**实际落点**仍在 PIN_GETCPU_START / PIN_GETCPU_END 里 (那才是"实际在哪")。
//   PIN_CORES_ONLINE=<内核原文, 如 0-7>      PIN_NIC_IFACE=<逗号分隔|none|n/a>
//   PIN_NIC_CPUS=<逗号分隔|none|n/a>         PIN_NIC_EXCLUDED=<none|物理核列表|n/a>
//     * PIN_NIC_EXCLUDED 三态分立 (F5): 物理核列表 = 真排除了这些核; `none` = **算了**且没有核
//       被排除 (含"全核都有 NIC IRQ => 排除不了"的退化分支); `n/a` = **探针退化, 没算**
//       (旧实现把后两者都打 `none`, 两态同形)。
//   PIN_CORE_LOAD=<选定核的 core_load (64 位)|n/a>
//     * F4: **64 位** —— 旧实现 `(int)` 截断 ⇒ 和 >2³¹ 时静默打 `n/a` (破坏"n/a = 没算"合同);
//       现在 n/a **只**表示"真没算" (inherit/core/none 模式)。
//   PIN_ALLOWED_MASK=<绑后 sched_getaffinity 掩码 hex>  PIN_GETCPU_START=<绑后立即 sched_getcpu()>
//     ⚠️ **PIN_GETCPU_START 不是独立见证 (F10)**: 它**构造上恒 == PIN_CPU** (不等时本函数
//        立即 die) ⇒ 它**不能**用来独立证明"绑到了哪"; 它唯一的用途是证明
//        `sched_setaffinity` **真的生效了** (立即读回, 而不是假设系统调用成功)。
//        独立复算要看 **PIN_ALLOWED_MASK** (掩码 == 1<<PIN_CPU 才是硬证据)。
//   PIN_FREQ_START_KHZ=<scaling_cur_freq|n/a>           PIN_GOV=<scaling_governor|n/a>
//   额外 (放行尾, 不破坏上面的顺序): UNPINNED=1 (仅 --no-pin) · PIN_NIC_IRQLINES=<命中行数>
//   PIN_NIC_IFACE_SRC=auto|env · PIN_TUPLE_ORDER=own_sib_t|n/a
//   * (F6 已删 `PIN_AVOID` —— 它实现里恒定 `none`, 是零信息断言; 无下游依赖。)
//   * n/a = 该模式没算 (或读不到); none = 算了且结果为空集 —— 两者不同, 别混读。
//   * PIN_ALLOWED_MASK 是**独立复算**: **PIN_CPU 为数值时**单核掩码必然等于 1<<PIN_CPU
//     (如 PIN_CPU=5 -> "20"); PIN_CPU=none (未绑) 时**不做这条自检也不误报** —— 那时掩码是
//     继承来的多核掩码 (本机 = "ff")。
//   * PIN_GOV/PIN_FREQ_START_KHZ 是给 schedutil + 空核 800 MHz 那个嫌疑留的仪器
//     (空核实测 800 MHz / 忙核 ~3.88 GHz)。
//   * ⭐ **F9 频率轨迹**: 首尾各一次采样**答不了"核是不是在半途爬频"** ⇒ 各程序的**周期行
//     行尾**(sink 的 `SINK_CONN ...` / src 的 `SRC_T <t> ...` / udp_src 的 `UDP_T <t> ...`)
//     统一追加一个字段 **` CPU_FREQ_KHZ=<n|n/a>`**。
//     ⚠️ 只许**追加在行尾**, 既有字段的名字/顺序一个字不动 (下游按 KEY=VALUE 切分)。
//     ⭐⭐ **2026-10-09 (R2) 语义订正 —— 字段名一个字不改, 只把取值语义改对**:
//        旧取值 = **打这行的那条线程**当拍所在核的 scaling_cur_freq。实测缺陷: 双线程臂的
//        report 行由**主线程**打, 而主线程整段在 pthread_join 上待着 ⇒ 它的核降到
//        800 MHz/1.2/1.9 GHz, 而单线程臂恒 ~3.89 GHz ⇒ **两臂不可比**, 且会被读成"运行频率"。
//        现取值 = **真正在干活的工作线程**最近一次自采样的频率 (登记表按**核号**存, 取最大值)。
//        采样**只在工作线程处理数据时**发生 (阻塞在 poll/join 上的线程不采样) ⇒ 读不到空闲核;
//        采样有 **≤200 ms 的节流网格** ⇒ 这一格是"最近 200 ms 内的干活核频率", 不是打行当拍的瞬时值。
//        一个工作线程都没采样过 ⇒ **回落到当拍核** (单线程族: 打行的那条线程就是干活那条
//        ⇒ 与旧版逐字相同)。语义 = "跑这一趟的核跑在多快"。
//        取值助手 = **`p7baff_work_freq_khz()`** (report 行该用的那个);
//        `p7baff_cpu_freq_khz()` 保留为"当拍核"的底层读数。
// 结束 (atexit 注册): PIN_GETCPU_END=<n> PIN_FREQ_END_KHZ=<n|n/a> [UNPINNED=1]
//   若 (**本线程**真绑过核且) PIN_GETCPU_END != **本线程的**期望核 => 打醒目错误并 _exit(2)
//   (单核掩码下理论上不可能 => 只可能是被外部改过/换了核)。
//   ⭐ **2026-10-09 (按线程记账, 约束 ③)**: 期望核存在 **thread_local** 里 —— 每条被绑的线程
//      各记**自己的**期望核 (p7b_pin_cpu 记主线程, `p7baff_pin_self_thread` 记工作线程);
//      atexit 只对**触发退出线程自己**断言, **没记过账的线程不做该断言**。
//      旧实现是单值全局 ⇒ 双线程各绑各核时, atexit 里 `sched_getcpu()` 是**触发线程**的核,
//      与那个全局值一比就 **假失败 (_exit(2))**。单线程路径的读数/语义**逐字不变**
//      (主线程自己记自己, 断言与旧实现逐位相同)。
//   ⚠️ --no-pin 分支**照打**这两个字段 (值可能是任意核), 但**不**因核号不符而失败。
//   ⚠️ --no-pin 必须响亮 (UNPINNED=1), 防止它变成"静默旁路"。
//
// ---------------------------------------------------------------------------
// ⭐ 2026-10-09 新增: **两颗不同物理核** (双线程样板) —— `--pin-pair` / `p7baff_g_want_pair`
//
// 动机 (约束 ④): I/O 线程与校验线程必须落在**两颗不同的物理核**上, 否则"分了线程"退化成
//   "同一物理核的两个 SMT 兄弟抢 L1/L2" —— 那正是要消除的耦合。
// 入口:
//   ① `p7baff_g_want_pair = 1;` **在 p7b_pin_cpu 之前**置位 (程序声明"我需要两颗核"); 或
//   ② 命令行 `--pin-pair` (与 ① 等效) / `--no-pin-pair` (显式关闭, 响亮: rule=none).
//   两者都被 `p7b_pin_cpu` 就地剥离 (与 --core/--no-pin 同一套剥离逻辑)。
//   选出的两颗核放在 `p7baff_g_pair_cpu[0]` (I/O) / `[1]` (WORK), 供程序 spawn 线程时取用;
//   取到后线程调 **`p7baff_pin_self_thread("io", cpu, first)`** 自己绑自己。
// 规则 (确定性; 全部经 PID_PAIR_RULE 见证; 退化一律响亮):
//   A) NIC 探针健康 (命中行 > 0) 且 可用物理核里 ≥2 颗 core_nic==0 => `two-core-nic0`  (degr=none)
//   B) 恰 1 颗 core_nic==0                                    => `nic0-mixed`     (degr=nic0-1)
//   C) 0 颗 core_nic==0 (全核都扛 NIC IRQ —— 本机实测就是这个分支)  => `load-only`    (degr=nic0-0)
//   D) NIC 探针退化 (0 命中行 / 没接口)                        => `load-only`     (degr=nic)
//   E) 可用物理核 < 2                                          => `degraded-one-pc` (degr=one-pc)
//   "可用" = 全部物理核 **减去主线程所在的那颗** (排除已占用: 主线程的核不再塞工作线程);
//   每颗核内的线程同样按 **own-first** 三元组挑 (与单核规则同一口径)。
//   ⚠️ 请求了 pair 而探测失败 => **硬门 exit(2)** (pair 无法在瞎猜的负载上选核);
//      `--no-pin` 与 pair 同时出现 => 线程**不绑** (rule=none), 走 --no-pin 的响亮旁路。
//
// 见证 (新增字段**一律追加在行尾**; 见下面 p7b_pin_cpu 阶段 8):
//   PIN_PAIR_RULE=<two-core-nic0|nic0-mixed|load-only|degraded-one-pc|none|n/a>
//   PIN_PAIR_DEGRADED=<none|nic0-1|nic0-0|nic|one-pc|n/a>
//   PIN_CPU_IO=<n|none|n/a>  PIN_CPU_WORK=<n|none|n/a>     (none = 请求了但没绑)
//   PIN_PC_IO=<物理核|n/a>   PIN_PC_WORK=<物理核|n/a>
//   PIN_PAIR_EXCL=<被排除的物理核列表|none|n/a>
//   PIN_PAIR_REQ=<want|cli|none|n/a>   (请求来自程序置位 / 命令行 / 没请求)
// 按线程见证 (线程**自己**打一行, 由 `p7baff_pin_self_thread` 产出):
//   PIN_THREAD name=io PIN_TID_IO=<tid> PIN_CPU_IO=<n|none> PIN_ALLOWED_MASK_IO=<hex>
//              PIN_GETCPU_IO=<n> CPU_FREQ_IO_KHZ=<n|n/a>
//   * PIN_ALLOWED_MASK_<X> 是**该线程自己**绑后 sched_getaffinity 的读回 —— 独立复算:
//     绑过时必然 == 1 << PIN_CPU_<X>; 未绑时是继承来的多核掩码 (不做自检也不误报)。
//   * 计划 (主线程打的 PIN_CPU_<X>) 与落实 (线程自己打的 PIN_CPU_<X>) **必须相等** ——
//     两条独立读数交叉核, 这是"真的绑上了"的证据 (PIN_GETCPU_* 构造上恒等于 CPU 值, 不是独立见证)。
// ===========================================================================
#ifndef P7B_AFFINITY_H
#define P7B_AFFINITY_H

#include <dirent.h>
#include <pthread.h>
#include <sched.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

// ⭐ 2026-10-09 (双线程样板): 本头新增两件事, **只加不破** (单线程路径与既有见证逐字不变):
//   ① **按线程记账** 的收尾硬门 (约束 ③): 每条被绑的线程各记**自己的**期望核 —— atexit 只对
//      **触发线程自己**断言; 没绑核的线程不做该断言。旧实现是**单值全局** (`p7baff_g_end_expect`)
//      ⇒ 双线程各绑各核时 atexit 只能看到**触发线程**的核 ⇒ **假失败**。
//   ② **两颗不同物理核**的分配 (约束 ④) + **按线程绑核**入口。
//      旧实现 `sched_setaffinity(0,…)` 硬编码 pid, 且选核规则没有"排除已选核"入参 ⇒ 连调两次
//      必得同一颗; 第 8 步也只在**一个物理核的线程集内**选 ⇒ "两颗不同物理核"无从表达。
//   见证新增字段**一律追加在行尾** (既有 PIN_* 字段名/顺序/语义一个字不动 —— 下游有解析器)。

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------
static std::string p7baff_trim(const std::string &s) {
    size_t a = 0, b = s.size();
    while (a < b && isspace((unsigned char)s[a])) a++;
    while (b > a && isspace((unsigned char)s[b - 1])) b--;
    return s.substr(a, b - a);
}

// 读整个文件; 失败 (打不开/读错/空) 返回 false
static bool p7baff_read_file(const char *path, std::string &out) {
    FILE *f = fopen(path, "r");
    if (!f) return false;
    char buf[4096];
    size_t n;
    out.clear();
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) out.append(buf, n);
    bool ok = !ferror(f);
    fclose(f);
    if (!ok || out.empty()) return false;
    out = p7baff_trim(out);
    return !out.empty();
}

static std::vector<std::string> p7baff_split_ws(const std::string &s) {
    std::vector<std::string> v;
    size_t i = 0;
    while (i < s.size()) {
        while (i < s.size() && isspace((unsigned char)s[i])) i++;
        size_t j = i;
        while (j < s.size() && !isspace((unsigned char)s[j])) j++;
        if (j > i) v.push_back(s.substr(i, j - i));
        i = j;
    }
    return v;
}

static std::vector<std::string> p7baff_lines(const std::string &s) {
    std::vector<std::string> v;
    std::string cur;
    for (size_t i = 0; i < s.size(); i++) {
        char c = s[i];
        if (c == '\r') continue;
        if (c == '\n') { v.push_back(cur); cur.clear(); }
        else cur += c;
    }
    if (!cur.empty()) v.push_back(cur);
    return v;
}

static bool p7baff_all_digits(const std::string &s) {
    if (s.empty()) return false;
    for (size_t i = 0; i < s.size(); i++)
        if (!isdigit((unsigned char)s[i])) return false;
    return true;
}

// F1: **严格**解析核号 (--core / PIN_CORE 专用). 成功 => true 且写入 out; 失败 => false
//   理由字符串 (给 stderr 用) 由调用方给。
//   拒绝: 空串 / 非纯十进制 (含 '+' '-' '0x' 等) / 尾随垃圾 / 溢出 long / 超出 int 范围。
//   ⛔ **绝不 atoi** —— 旧实现 `atoi("4294967296")` 截断成 0 ⇒ 静默绑 CPU0 且 RC=0。
static bool p7baff_parse_core_strict(const std::string &s, int &out, std::string &why) {
    if (s.empty()) { why = "空串"; return false; }
    if (!p7baff_all_digits(s)) { why = "非纯十进制数字 (含符号/0x/字母等)"; return false; }
    errno = 0;
    char *end = NULL;
    long v = strtol(s.c_str(), &end, 10);
    if (end == s.c_str() || *end != '\0') { why = "有尾随垃圾"; return false; }   // 防御: all_digits 已排除
    if (errno == ERANGE) { why = "溢出 long"; return false; }
    if (v > (long)INT_MAX || v < (long)INT_MIN) { why = "超出 int 范围 (0..2147483647)"; return false; }
    out = (int)v;
    return true;
}

// "0-7,9" / "0,4" / "0-1" -> {0,1,...,7,9}; 解析失败返回空
static std::vector<int> p7baff_parse_cpulist(const std::string &raw) {
    std::vector<int> out;
    std::string s = raw;
    for (size_t i = 0; i < s.size(); i++)
        if (s[i] == ',' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t') s[i] = ' ';
    std::vector<std::string> toks = p7baff_split_ws(s);
    if (toks.empty()) return out;
    for (size_t i = 0; i < toks.size(); i++) {
        const std::string &t = toks[i];
        size_t dash = t.find('-');
        if (dash == std::string::npos) {
            if (!p7baff_all_digits(t)) return std::vector<int>();
            out.push_back(atoi(t.c_str()));
        } else {
            std::string a = t.substr(0, dash), b = t.substr(dash + 1);
            if (!p7baff_all_digits(a) || !p7baff_all_digits(b)) return std::vector<int>();
            int ia = atoi(a.c_str()), ib = atoi(b.c_str());
            if (ia > ib) return std::vector<int>();
            for (int k = ia; k <= ib; k++) {
                out.push_back(k);
                if (out.size() > 4096) return std::vector<int>();   // 防御
            }
        }
    }
    std::sort(out.begin(), out.end());
    out.erase(std::unique(out.begin(), out.end()), out.end());
    return out;
}

static std::string p7baff_join(const std::vector<int> &v, const char *sep) {
    std::string s;
    char b[24];
    for (size_t i = 0; i < v.size(); i++) {
        snprintf(b, sizeof(b), "%d", v[i]);
        if (i) s += sep;
        s += b;
    }
    return s;
}

// /proc/interrupts 与 /proc/softirqs 是同一张表: "KEY:" 后面 N 个每核计数, 再往后是描述
struct P7baffTable {
    std::vector<int> col_cpu;                              // 列号 -> 逻辑核号 (来自表头行 CPU0..)
    std::vector<std::string> key;                          // IRQ 号 或 softirq 名
    std::vector<std::vector<unsigned long long> > cnt;     // 每行 x 每列
    std::vector<std::string> desc;
};

static bool p7baff_parse_table(const std::string &txt, P7baffTable &tb) {
    std::vector<std::string> ls = p7baff_lines(txt);
    if (ls.size() < 2) return false;
    std::vector<std::string> hdr = p7baff_split_ws(ls[0]);
    for (size_t i = 0; i < hdr.size(); i++) {
        const std::string &h = hdr[i];
        if (h.size() > 3 && h.compare(0, 3, "CPU") == 0 && p7baff_all_digits(h.substr(3)))
            tb.col_cpu.push_back(atoi(h.c_str() + 3));
    }
    if (tb.col_cpu.empty()) return false;
    const size_t ncol = tb.col_cpu.size();
    for (size_t i = 1; i < ls.size(); i++) {
        const std::string &L = ls[i];
        size_t c = L.find(':');
        if (c == std::string::npos) continue;
        std::string pre = p7baff_trim(L.substr(0, c));
        if (!p7baff_all_digits(pre)) continue;             // NMI:/LOC:/ERR: 等非数字键一律不算
        std::vector<std::string> tk = p7baff_split_ws(L.substr(c + 1));
        std::vector<unsigned long long> v;
        size_t k = 0;
        while (k < tk.size() && v.size() < ncol && p7baff_all_digits(tk[k])) {
            v.push_back(strtoull(tk[k].c_str(), 0, 10));
            k++;
        }
        if (v.size() < ncol) continue;                     // 列数不齐 -> 不认这一行
        std::string d;
        for (size_t q = k; q < tk.size(); q++) { if (!d.empty()) d += ' '; d += tk[q]; }
        tb.key.push_back(pre);
        tb.cnt.push_back(v);
        tb.desc.push_back(d);
    }
    return !tb.key.empty();
}

// /proc/softirqs 的键是名字 (NET_RX 等), 不是数字 -> 单独一个宽松解析
static bool p7baff_parse_softirqs(const std::string &txt, P7baffTable &tb) {
    std::vector<std::string> ls = p7baff_lines(txt);
    if (ls.size() < 2) return false;
    std::vector<std::string> hdr = p7baff_split_ws(ls[0]);
    for (size_t i = 0; i < hdr.size(); i++) {
        const std::string &h = hdr[i];
        if (h.size() > 3 && h.compare(0, 3, "CPU") == 0 && p7baff_all_digits(h.substr(3)))
            tb.col_cpu.push_back(atoi(h.c_str() + 3));
    }
    if (tb.col_cpu.empty()) return false;
    const size_t ncol = tb.col_cpu.size();
    for (size_t i = 1; i < ls.size(); i++) {
        const std::string &L = ls[i];
        size_t c = L.find(':');
        if (c == std::string::npos) continue;
        std::string pre = p7baff_trim(L.substr(0, c));
        if (pre.empty() || p7baff_all_digits(pre)) continue;
        std::vector<std::string> tk = p7baff_split_ws(L.substr(c + 1));
        std::vector<unsigned long long> v;
        size_t k = 0;
        while (k < tk.size() && v.size() < ncol && p7baff_all_digits(tk[k])) {
            v.push_back(strtoull(tk[k].c_str(), 0, 10));
            k++;
        }
        if (v.size() < ncol) continue;
        tb.key.push_back(pre);
        tb.cnt.push_back(v);
        tb.desc.push_back("");
    }
    return !tb.key.empty();
}

// driver == "sfc" 的接口名 (排序); 读不到 /sys/class/net 返回空
static std::vector<std::string> p7baff_sfc_ifaces() {
    std::vector<std::string> v;
    DIR *d = opendir("/sys/class/net");
    if (!d) return v;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        std::string link = std::string("/sys/class/net/") + e->d_name + "/device/driver";
        char tgt[4096];
        ssize_t n = readlink(link.c_str(), tgt, sizeof(tgt) - 1);
        if (n <= 0) continue;
        tgt[n] = '\0';
        std::string t(tgt);
        size_t p = t.find_last_of('/');
        std::string base = (p == std::string::npos) ? t : t.substr(p + 1);
        if (base == "sfc") v.push_back(e->d_name);
    }
    closedir(d);
    std::sort(v.begin(), v.end());
    return v;
}

static bool p7baff_iface_exists(const std::string &name) {
    std::string p = "/sys/class/net/" + name;
    DIR *d = opendir(p.c_str());
    if (!d) return false;
    closedir(d);
    return true;
}

static int p7baff_mask_count(const cpu_set_t &m) {
    int n = 0;
    for (int i = 0; i < CPU_SETSIZE; i++) if (CPU_ISSET(i, &m)) n++;
    return n;
}

// 掩码 hex (无 0x 前缀, 低位在右); 单核掩码必然等于 1<<cpu
static std::string p7baff_mask_hex(const cpu_set_t &m) {
    int topbit = -1;
    for (int i = 0; i < CPU_SETSIZE; i++) if (CPU_ISSET(i, &m)) topbit = i;
    if (topbit < 0) return std::string("0");
    std::string s;
    for (int q = topbit / 4; q >= 0; q--) {
        int v = 0;
        for (int b = 0; b < 4; b++) {
            int bit = q * 4 + b;
            if (bit < CPU_SETSIZE && CPU_ISSET(bit, &m)) v |= 1 << b;
        }
        s += "0123456789abcdef"[v];
    }
    return s;
}

static std::string p7baff_cpu_sysfile(int cpu, const char *name) {
    char p[256];
    snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu%d/%s", cpu, name);
    std::string s;
    if (!p7baff_read_file(p, s)) return std::string("n/a");
    return s;
}

// ⭐ F9: 周期行用的**频率采样助手** —— 当拍所在核的 scaling_cur_freq (kHz); 读不到 => "n/a"。
//   动机: 首尾各一次采样 (PIN_FREQ_START_KHZ / PIN_FREQ_END_KHZ) **答不了**
//   "核是不是在半途爬频" (warm-up 伪影那个嫌疑) ⇒ 各程序的周期行 (sink 的 `SINK_CONN ...` /
//   src 的 `SRC_T <t> ...` / udp_src 的 `UDP_T <t> ...`) 行尾追加 ` CPU_FREQ_KHZ=<n>`。
//   ⚠️ 只许**追加在行尾** —— 既有字段的名字/顺序一个字不动 (下游按 KEY=VALUE 切分)。
static std::string p7baff_cpu_freq_khz() {
    int c = sched_getcpu();
    if (c < 0) return std::string("n/a");
    return p7baff_cpu_sysfile(c, "cpufreq/scaling_cur_freq");
}

// ⭐⭐ 2026-10-09 (R2): **工作线程自采样**的频率登记表 (report 行的 `CPU_FREQ_KHZ` 现取这个)
//
//   动因 (实测, 不是推断): 双线程臂的 report 行由**主线程**打, 而主线程整段在 pthread_join
//   上待着 ⇒ `p7baff_cpu_freq_khz()`（当拍核）读到的是**空闲核** (800 MHz/1.2/1.9 GHz),
//   单线程臂同行为 ~3.89 GHz ⇒ **两臂不可比 + 会被读成"运行频率"**。
//
//   设计 (为什么按**核号**存, 不按线程存):
//     * sink 每个连接**新建**两条线程 ⇒ 按线程登记会在第 2 个连接就把表用满 (静默退化);
//       按核号存则天然幂等 (同一颗核反复覆写同一格)。
//     * 采样只在工作线程**处理数据时**发生 ⇒ 阻塞在 poll 上的线程不会污染读数。
//     * 报告 = 所有**被采样过**的核里取**最大**值 = "跑这一趟的核跑在多快" (确定性, 不靠谁先写)。
//     * 一个都没有 ⇒ 回落 `p7baff_cpu_freq_khz()` (当拍核): 单线程族里打行的那条线程
//       **就是**干活那条 ⇒ 语义与旧版逐字相同 (旧调用点零改动)。
static const int P7BAFF_WF_MAXCPU = 256;                     // 够用且不必查 sysconf
static std::atomic<int> p7baff_g_wf_khz[256];                // 按核号; <=0 = 该核没被采样过

// 工作线程在**自己的循环里**周期调 (内部节流 ~200 ms; 未到点直接返回 —— 不是热点路径)。
//   ⚠️ 只许工作线程调; 主线程/空闲线程调 = 把"当拍核"混进登记表 (正是本次要修的缺陷形态)。
__attribute__((unused)) static inline void p7baff_work_freq_tick() {
    int c = sched_getcpu();
    if (c < 0 || c >= P7BAFF_WF_MAXCPU) return;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    long long now_ms = (long long)ts.tv_sec * 1000 + (long long)(ts.tv_nsec / 1000000);
    static thread_local long long last_ms = -1;              // **本线程**的上次采样时刻 (各线程独立节流)
    if (last_ms >= 0 && now_ms - last_ms < 200) return;
    last_ms = now_ms;
    std::string f = p7baff_cpu_sysfile(c, "cpufreq/scaling_cur_freq");
    if (f.empty() || f == "n/a") return;
    p7baff_g_wf_khz[c].store(atoi(f.c_str()));               // 最近一次读数覆写该核 (不是历史最大值)
}

// report 行专用: 被采样过的核里取最大值; 没有 ⇒ 当拍核 (老语义)
//   (`__attribute__((unused))`: 只有 sink/bench 用它 —— 发送族仍然只调 p7baff_cpu_freq_khz(),
//    与旧行为逐字相同; 不给属性的话它们会多一条 -Wunused-function 告警)
__attribute__((unused)) static std::string p7baff_work_freq_khz() {
    int best = -1;
    for (int i = 0; i < P7BAFF_WF_MAXCPU; i++) {
        int v = p7baff_g_wf_khz[i].load();
        if (v > best) best = v;
    }
    if (best <= 0) return p7baff_cpu_freq_khz();
    char b[32];
    snprintf(b, sizeof(b), "%d", best);
    return std::string(b);
}

// ---------------------------------------------------------------------------
// 硬门: 一律 exit(2) (用法/环境错)。绝不 3 (台架身份门) / 绝不 124 (外层 timeout)。
// ---------------------------------------------------------------------------
static void p7baff_die(const std::string &why) {
    fprintf(stderr, "PIN_FAIL %s\n", why.c_str());
    fflush(stderr);
    exit(2);
}

static void p7baff_die_errno(const char *what, const char *path) {
    fprintf(stderr, "PIN_FAIL %s %s: %s\n", what, path, strerror(errno));
    fflush(stderr);
    exit(2);
}

// ===========================================================================
// 探测体 (2026-10-09 抽自 p7b_pin_cpu 的阶段 5)
//   ⚠️ **逐句等价**是它的唯一验收标准: 硬门时机 (fatal)、见证取值、退化标志一个都没改。
//   抽出来的理由: "选一颗核" 与 "选两颗不同物理核" (pair) 必须共用**同一份**探针数据 ——
//   否则两条规则会在两处漂移 (本工程最贵的一类缺陷)。
//   fatal=true : 读不到 / 解析失败 => p7baff_die (默认规则; 以及请求了 pair 时)
//   fatal=false: 尽力而为, 能填多少填多少 (inherit/core 的见证)
// ===========================================================================
struct P7baffProbe {
    std::vector<std::string> ifaces;             // 空 = 没找到
    std::string iface_src = "n/a";               // auto|env
    bool irq_ok = false;                         // /proc/interrupts 读了 + 解析成功
    int  nic_lines = -1;                         // 命中行数 (-1 = 没算)
    std::vector<int> nic_cpus;                   // 有非零 NIC IRQ 的逻辑核 (排序)
    std::map<int, unsigned long long> nic;       // 逻辑核 -> NIC IRQ 计数
    bool soft_ok = false;                        // /proc/softirqs 读了 + 解析成功
    std::map<int, unsigned long long> net_soft;  // 逻辑核 -> NET_RX + NET_TX
    bool deg_nic = false;                        // NIC 探针 0 命中行 (规则没算)
    bool topo_ok = false;                        // 至少有一次 thread_siblings_list 读到
    bool deg_topo = false;                       // 读不到/解析失败 => 每线程当一个物理核
    std::map<int, std::vector<int> > sib;        // 逻辑核 -> 在线兄弟 (排序)
    std::map<int, std::vector<int> > pc;         // 物理核 -> 成员线程 (排序)
    std::map<int, unsigned long long> core_load; // 物理核 -> sum net_soft
    std::map<int, unsigned long long> core_nic;  // 物理核 -> sum nic_irq

    std::string iface_str() const {
        if (ifaces.empty()) return std::string("none");
        std::string s = ifaces[0];
        for (size_t i = 1; i < ifaces.size(); i++) s += "," + ifaces[i];
        return s;
    }
    unsigned long long nic_at(int cpu) const {
        std::map<int, unsigned long long>::const_iterator it = nic.find(cpu);
        return it == nic.end() ? 0ull : it->second;
    }
    unsigned long long load_at(int cpu) const {
        std::map<int, unsigned long long>::const_iterator it = net_soft.find(cpu);
        return it == net_soft.end() ? 0ull : it->second;
    }
    unsigned long long core_nic_at(int pc_id) const {
        std::map<int, unsigned long long>::const_iterator it = core_nic.find(pc_id);
        return it == core_nic.end() ? 0ull : it->second;
    }
};

static void p7baff_probe_run(P7baffProbe &pr, bool fatal, const char *env_iface,
                             const std::vector<int> &online) {
    // 3a) NIC 接口名 (旧行为: PIN_NIC_IFACE 指了不存在的接口 => **无条件** die, 任何模式)
    if (env_iface && *env_iface) {
        std::string nm = env_iface;
        if (!p7baff_iface_exists(nm))
            p7baff_die("PIN_NIC_IFACE=" + nm + " 不在 /sys/class/net 里");
        pr.ifaces.push_back(nm);
        pr.iface_src = "env";
    } else {
        pr.ifaces = p7baff_sfc_ifaces();
        pr.iface_src = "auto";
    }

    // 3b) /proc/interrupts -> nic[cpu]
    std::string itxt;
    if (!p7baff_read_file("/proc/interrupts", itxt)) {
        if (fatal) p7baff_die_errno("读不到", "/proc/interrupts");
        return;
    }
    P7baffTable itb;
    if (!p7baff_parse_table(itxt, itb)) {
        if (fatal) p7baff_die("解析 /proc/interrupts 失败 (表头/列数不识别)");
        return;
    }
    {
        std::map<int, unsigned long long> nic;
        int hit = 0;
        for (size_t r = 0; r < itb.key.size(); r++) {
            bool is_nic = false;
            for (size_t f = 0; f < pr.ifaces.size() && !is_nic; f++)
                if (itb.desc[r].find(pr.ifaces[f]) != std::string::npos) is_nic = true;
            if (!is_nic) continue;
            hit++;
            for (size_t c = 0; c < itb.col_cpu.size(); c++)
                nic[itb.col_cpu[c]] += itb.cnt[r][c];
        }
        pr.nic_lines = hit;
        pr.nic = nic;
        pr.irq_ok = true;
        // F2: NIC 探针 **0 命中行** => "排除 NIC IRQ 核"这条规则**没算** (退化, 必须响亮)
        pr.deg_nic = (hit <= 0);
        for (std::map<int, unsigned long long>::iterator it = nic.begin(); it != nic.end(); ++it)
            if (it->second > 0) pr.nic_cpus.push_back(it->first);
        std::sort(pr.nic_cpus.begin(), pr.nic_cpus.end());
    }

    // 3c) /proc/softirqs -> net_soft[cpu]
    std::string stxt;
    if (!p7baff_read_file("/proc/softirqs", stxt)) {
        if (fatal) p7baff_die_errno("读不到", "/proc/softirqs");
        return;
    }
    P7baffTable stb;
    if (!p7baff_parse_softirqs(stxt, stb)) {
        if (fatal) p7baff_die("解析 /proc/softirqs 失败");
        return;
    }
    {
        std::map<int, unsigned long long> net_soft;
        for (size_t r = 0; r < stb.key.size(); r++) {
            if (stb.key[r] != "NET_RX" && stb.key[r] != "NET_TX") continue;
            for (size_t c = 0; c < stb.col_cpu.size(); c++)
                net_soft[stb.col_cpu[c]] += stb.cnt[r][c];
        }
        pr.net_soft = net_soft;
        pr.soft_ok = true;
    }

    // ---- SMT 兄弟 + 物理核聚合 (旧代码在"选核"块内做; 这里提前, 结果逐位相同) ----
    //   ⚠️ 旧代码只在**默认规则**下走到这里 => 对 inherit/core, deg_topo 从来是 false。
    //      本函数对它们也会算 (deg_topo 在那些模式下**不参与任何见证**, 见阶段 8 的 deg_s);
    //      代价只是启动时多几次 /sys 读。
    for (size_t i = 0; i < online.size(); i++) {
        int c = online[i];
        char p[256];
        snprintf(p, sizeof(p),
                 "/sys/devices/system/cpu/cpu%d/topology/thread_siblings_list", c);
        std::string t;
        std::vector<int> g;
        if (p7baff_read_file(p, t)) { g = p7baff_parse_cpulist(t); pr.topo_ok = true; }
        // F2: 读不到/解析失败 => 静默退化成"每条线程当一个物理核"
        //     (语义已变: 可能选到"与扛中断线程共用物理核"的线程)
        if (g.empty()) { g.push_back(c); pr.deg_topo = true; }
        std::vector<int> keep;
        for (size_t k = 0; k < g.size(); k++)
            if (std::find(online.begin(), online.end(), g[k]) != online.end())
                keep.push_back(g[k]);
        if (keep.empty()) keep.push_back(c);
        std::sort(keep.begin(), keep.end());
        pr.sib[c] = keep;
    }
    for (size_t i = 0; i < online.size(); i++) {
        int c = online[i];
        pr.pc[pr.sib[c][0]].push_back(c);
    }
    for (std::map<int, std::vector<int> >::iterator it = pr.pc.begin(); it != pr.pc.end(); ++it) {
        unsigned long long L = 0, N = 0;
        for (size_t k = 0; k < it->second.size(); k++) {
            L += pr.load_at(it->second[k]);
            N += pr.nic_at(it->second[k]);
        }
        pr.core_load[it->first] = L;
        pr.core_nic[it->first] = N;
    }
}

// 物理核内选线程: 三元组 (**自身负载**, 兄弟负载, 线程号) 最小 = own-first
//   (逐句取自旧内联实现; 2026-10-08 对抗审查裁定: app 只占一条逻辑线程 => 自身负载一阶)
static int p7baff_pick_thread_in_pc(const P7baffProbe &pr, int pc_id) {
    std::map<int, std::vector<int> >::const_iterator it = pr.pc.find(pc_id);
    if (it == pr.pc.end() || it->second.empty()) return -1;
    const std::vector<int> &th = it->second;
    int pick = -1;
    unsigned long long pick_own = 0, pick_sib = 0;
    for (size_t i = 0; i < th.size(); i++) {
        int t = th[i];
        unsigned long long sibl = 0, own = 0;
        for (size_t k = 0; k < th.size(); k++) {
            if (th[k] == t) continue;
            sibl += pr.load_at(th[k]) + pr.nic_at(th[k]);
        }
        own = pr.load_at(t) + pr.nic_at(t);
        if (pick < 0 || own < pick_own || (own == pick_own && sibl < pick_sib) ||
            (own == pick_own && sibl == pick_sib && t < pick)) {
            pick = t; pick_own = own; pick_sib = sibl;
        }
    }
    return pick;
}

// ---------------------------------------------------------------------------
// 两颗不同物理核 (约束 ④; 规则与退化命名见文件头)
// ---------------------------------------------------------------------------
struct P7baffPair {
    int cpu[2];            // [0]=I/O, [1]=WORK; -1 = 没选出来
    int pcid[2];           // 各自所在的物理核 id
    long long load[2];
    std::string rule;      // two-core-nic0|nic0-mixed|load-only|degraded-one-pc
    std::string degr;      // none|nic0-1|nic0-0|nic|one-pc
    std::string excl;      // 被排除的物理核列表 ("none" = 算了且没排除)
    P7baffPair() {
        cpu[0] = cpu[1] = -1;
        pcid[0] = pcid[1] = -1;
        load[0] = load[1] = -1;
        rule = "n/a"; degr = "n/a"; excl = "n/a";
    }
    bool ok() const { return cpu[0] >= 0 && cpu[1] >= 0; }
};

// 按 (core_load 升序, 物理核 id 升序) 排序候选 -> 取前两颗
static void p7baff_sort_pcs(std::vector<int> &v, const P7baffProbe &pr) {
    // 插入排序 (候选个数 = 物理核个数, 极小; 且要按 (load, id) 双键 —— 显式写出来最不容易错)
    for (size_t i = 1; i < v.size(); i++) {
        int key = v[i];
        unsigned long long kl = pr.core_load.count(key) ? pr.core_load.at(key) : 0ull;
        size_t j = i;
        while (j > 0) {
            int prev = v[j - 1];
            unsigned long long pl = pr.core_load.count(prev) ? pr.core_load.at(prev) : 0ull;
            if (pl < kl || (pl == kl && prev <= key)) break;
            v[j] = v[j - 1];
            j--;
        }
        v[j] = key;
    }
}

static P7baffPair p7baff_pick_pair(const P7baffProbe &pr, int main_cpu) {
    P7baffPair out;
    // 主线程所在物理核 (排除已占用); sib 缺失时退化成"自己的核号"
    int main_pc = main_cpu;
    std::map<int, std::vector<int> >::const_iterator ms = pr.sib.find(main_cpu);
    if (ms != pr.sib.end() && !ms->second.empty()) main_pc = ms->second[0];

    std::vector<int> avail, excl;
    for (std::map<int, std::vector<int> >::const_iterator it = pr.pc.begin(); it != pr.pc.end(); ++it) {
        if (it->first == main_pc) { excl.push_back(it->first); continue; }
        avail.push_back(it->first);
    }
    out.excl = excl.empty() ? std::string("none") : p7baff_join(excl, ",");

    // E) 可用物理核 < 2: 双线程被迫挤 (响亮)
    if (avail.size() < 2) {
        int p0 = avail.empty() ? main_pc : avail[0];
        out.rule = "degraded-one-pc";
        out.degr = "one-pc";
        out.cpu[0] = p7baff_pick_thread_in_pc(pr, p0);
        // 第二条线程: 同核里挑**另一条**逻辑线程 (SMT 兄弟); 只有一条时只能同一条
        std::map<int, std::vector<int> >::const_iterator it = pr.pc.find(p0);
        if (it != pr.pc.end()) {
            for (size_t k = 0; k < it->second.size(); k++)
                if (it->second[k] != out.cpu[0]) { out.cpu[1] = it->second[k]; break; }
        }
        if (out.cpu[1] < 0) out.cpu[1] = out.cpu[0];
        out.pcid[0] = out.pcid[1] = p0;
        out.load[0] = pr.core_load.count(p0) ? (long long)pr.core_load.at(p0) : -1;
        out.load[1] = out.load[0];
        return out;
    }

    // 候选按 core_nic==0 分两池 (D: NIC 探针退化 => 这条规则没算 => 全部走 load-only)
    std::vector<int> cand0, candr;
    for (size_t i = 0; i < avail.size(); i++) {
        if (!pr.deg_nic && pr.core_nic_at(avail[i]) == 0) cand0.push_back(avail[i]);
        else candr.push_back(avail[i]);
    }
    p7baff_sort_pcs(cand0, pr);
    p7baff_sort_pcs(candr, pr);

    int c0 = -1, c1 = -1;
    if (pr.deg_nic) {
        out.rule = "load-only"; out.degr = "nic";
        c0 = candr[0]; c1 = candr[1];
    } else if (cand0.size() >= 2) {
        out.rule = "two-core-nic0"; out.degr = "none";
        c0 = cand0[0]; c1 = cand0[1];
    } else if (cand0.size() == 1) {
        out.rule = "nic0-mixed"; out.degr = "nic0-1";
        c0 = cand0[0]; c1 = candr[0];
    } else {
        out.rule = "load-only"; out.degr = "nic0-0";
        c0 = candr[0]; c1 = candr[1];
    }
    out.pcid[0] = c0; out.pcid[1] = c1;
    out.cpu[0] = p7baff_pick_thread_in_pc(pr, c0);
    out.cpu[1] = p7baff_pick_thread_in_pc(pr, c1);
    out.load[0] = pr.core_load.count(c0) ? (long long)pr.core_load.at(c0) : -1;
    out.load[1] = pr.core_load.count(c1) ? (long long)pr.core_load.at(c1) : -1;
    return out;
}

// ===========================================================================
// 按线程绑核入口 (2026-10-09)
// ===========================================================================
// **按线程记账** 的账本 (约束 ③): 存 thread_local —— 每条线程只记自己的期望核, 只有本线程
//   读得到自己的那条 (atexit 就在触发退出的那条线程里跑)。thread_local + 无锁 = 没有共享
//   状态要对齐, 也就不需要任何同步原语。
static thread_local int p7baff_tls_end_expect = -1;  // 本线程的期望核; -1 = 本线程不做断言
static thread_local int p7baff_tls_unpinned   = 0;   // 本线程是"不绑核"分支 (响亮)

static long long p7baff_self_tid() { return (long long)syscall(SYS_gettid); }

// ---------------------------------------------------------------------------
// 两颗核的**结果出口** (2026-10-09): 程序 spawn 线程时从这里取核号
//   ⚠️ `p7baff_g_want_pair` 必须在调 `p7b_pin_cpu` **之前**置位 (它是程序的声明);
//      CLI `--pin-pair` / `--no-pin-pair` 由 p7b_pin_cpu 覆盖它。
// ---------------------------------------------------------------------------
static int         p7baff_g_want_pair   = 0;        // 程序声明 (0/1)
static std::string p7baff_g_pair_req_src = "n/a";   // want|cli|none (见证用)
static int         p7baff_g_pair_active = 0;        // 1 = 真的选出了两颗 (witness 已打)
static int         p7baff_g_pair_cpu[2] = {-1, -1}; // [0]=I/O, [1]=WORK; -1 = 没选
static int         p7baff_g_pair_pc[2]  = {-1, -1};
static long long   p7baff_g_pair_load[2] = {-1, -1};
static std::string p7baff_g_pair_rule = "n/a";
static std::string p7baff_g_pair_deg  = "n/a";
static std::string p7baff_g_pair_excl = "n/a";

static std::string p7baff_upper(const char *s) {
    std::string o = s;
    for (size_t i = 0; i < o.size(); i++) o[i] = (char)toupper((unsigned char)o[i]);
    return o;
}

// 在当前线程上绑核 + **按线程记账** + 见证。
//   cpu >= 0 : 绑单核 (pthread_setaffinity_np); 失败 / 绑后读回不符 => **exit(2)** (同主线程硬门);
//              记账: 本线程的 end-expect = cpu; 见证行 (print=true 时打):
//                PIN_THREAD name=<io|work> PIN_TID_<NAME>=<tid> PIN_CPU_<NAME>=<cpu>
//                PIN_ALLOWED_MASK_<NAME>=<hex> PIN_GETCPU_<NAME>=<cpu> CPU_FREQ_<NAME>_KHZ=<n|n/a>
//   cpu < 0  : **不绑** (响亮: PIN_CPU_<NAME>=none); 不做 end 断言; tid/掩码照样打
//   ⚠️ 只许**在本线程内部**调 (记账是 thread_local; 拿别的线程的核号去调另一条线程 = 记错账)。
static void p7baff_pin_self_thread(const char *name, int cpu, bool print) {
    std::string nm = p7baff_upper(name);
    long long tid = p7baff_self_tid();
    cpu_set_t after;
    int got = -1;
    if (cpu >= 0) {
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(cpu, &set);
        int rc = pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
        if (rc != 0)
            p7baff_die(std::string("pthread_setaffinity_np(") + std::to_string(cpu) + "): " +
                       std::string(strerror(rc)));
        got = sched_getcpu();
        if (got != cpu)
            p7baff_die(std::string("线程 ") + name + " 绑后 sched_getcpu()=" + std::to_string(got) +
                       " != 目标 " + std::to_string(cpu));
        p7baff_tls_end_expect = cpu;      // ⭐ 约束 ③: 本线程只记自己的期望核
        p7baff_tls_unpinned = 0;
    } else {
        got = sched_getcpu();
        p7baff_tls_end_expect = -1;       // 不绑核的线程**不做** end 断言
        p7baff_tls_unpinned = 1;          // 但必须响亮
    }
    if (sched_getaffinity(0, sizeof(after), &after) != 0)
        p7baff_die(std::string("线程 sched_getaffinity: ") + strerror(errno));
    if (!print) return;
    std::string f = (got >= 0) ? p7baff_cpu_sysfile(got, "cpufreq/scaling_cur_freq") : std::string("n/a");
    printf("PIN_THREAD name=%s PIN_TID_%s=%lld PIN_CPU_%s=%s PIN_ALLOWED_MASK_%s=%s "
           "PIN_GETCPU_%s=%d CPU_FREQ_%s_KHZ=%s\n",
           name, nm.c_str(), tid, nm.c_str(),
           (cpu >= 0) ? std::to_string(cpu).c_str() : "none",
           nm.c_str(), p7baff_mask_hex(after).c_str(), nm.c_str(), got, nm.c_str(), f.c_str());
    fflush(stdout);
}

// 按 **tid** (Linux 线程号, = syscall(SYS_gettid)) 绑另一条线程 (sched_setaffinity 版入口)。
//   ⚠️ 它**不能**代替 p7baff_pin_self_thread 的记账 —— 被绑的那条线程的 end-expect 仍归它自己
//      在内部记 (外部替它记 = 记在错线程的 TLS 上)。本函数只用于"从外面挪一条线程"的场合。
__attribute__((unused)) static int p7baff_pin_tid(long long tid, int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity((pid_t)tid, sizeof(set), &set) != 0) return -1;
    return 0;
}

// ---------------------------------------------------------------------------
// 收尾 (atexit) —— **按线程记账** (约束 ③): 账本 = 上面的 thread_local
// ---------------------------------------------------------------------------
static void p7baff_on_exit(void) {
    int end = sched_getcpu();
    std::string f = (end >= 0) ? p7baff_cpu_sysfile(end, "cpufreq/scaling_cur_freq") : std::string("n/a");
    printf("PIN_GETCPU_END=%d PIN_FREQ_END_KHZ=%s", end, f.c_str());
    if (p7baff_tls_unpinned) printf(" UNPINNED=1");
    printf("\n");
    fflush(stdout);
    if (p7baff_tls_end_expect >= 0 && end != p7baff_tls_end_expect) {
        fprintf(stderr,
                "PIN_FAIL END_MISMATCH: PIN_GETCPU_END=%d != PIN_CPU=%d "
                "(单核掩码下不可能 => 绑核被外部改过/换过核)\n",
                end, p7baff_tls_end_expect);
        fflush(stderr);
        _exit(2);
    }
}

// ===========================================================================
// 公共入口
// ===========================================================================
int p7b_pin_cpu(int argc, char **argv) {
    // ---- 阶段 0: 就地剥离本函数的选项 (原 argc 只读, 写指针 w <= 读指针 i 恒成立) ----
    bool cli_no_pin = false, cli_core_seen = false;
    bool cli_pair_on = false, cli_pair_off = false;
    int  cli_core = -1;
    int  w = 1;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--no-pin") { cli_no_pin = true; continue; }
        if (a == "--pin-pair")    { cli_pair_on = true;  continue; }   // 2026-10-09: 要两颗物理核
        if (a == "--no-pin-pair") { cli_pair_off = true; continue; }
        if (a == "--core") {
            if (i + 1 >= argc) p7baff_die("--core 缺参数 (用法: --core N)");
            std::string v = argv[i + 1];
            std::string why;
            int n = -1;
            if (!p7baff_parse_core_strict(v, n, why))         // F1: 全串严格校验, 绝不 atoi
                p7baff_die("--core 参数非法 (" + why + "): '" + v + "'");
            cli_core = n;
            cli_core_seen = true;
            i++;
            continue;
        }
        argv[w++] = argv[i];
    }
    const int new_argc = w;
    argv[new_argc] = NULL;
    if (cli_no_pin && cli_core_seen)
        p7baff_die("--no-pin 与 --core 同时给出 (显式矛盾, 不静默取其一)");
    if (cli_pair_on && cli_pair_off)
        p7baff_die("--pin-pair 与 --no-pin-pair 同时给出 (显式矛盾, 不静默取其一)");
    // pair 请求: 命令行胜过程序置位; 程序置位 = `p7baff_g_want_pair = 1` (在调本函数之前)
    if (cli_pair_on)  { p7baff_g_want_pair = 1; p7baff_g_pair_req_src = "cli"; }
    if (cli_pair_off) { p7baff_g_want_pair = 0; p7baff_g_pair_req_src = "none"; }
    if (p7baff_g_want_pair && !cli_pair_on) p7baff_g_pair_req_src = "want";

    // ---- 阶段 1: 解析模式 (命令行 > 环境) ----
    enum Mode { M_AVOID, M_INHERIT, M_CORE, M_NONE };
    Mode mode = M_AVOID;
    int  target = -1;
    const char *env_rule  = getenv("PIN_RULE");
    const char *env_core  = getenv("PIN_CORE");
    const char *env_iface = getenv("PIN_NIC_IFACE");

    if (cli_no_pin) {
        mode = M_NONE;
    } else if (cli_core_seen) {
        mode = M_CORE;
        target = cli_core;
    } else if (env_rule && strcmp(env_rule, "none") == 0) {
        mode = M_NONE;                                  // PIN_RULE=none 胜 PIN_CORE (对照组永远能跑)
    } else if (env_core && *env_core) {
        std::string why;
        int n = -1;
        if (!p7baff_parse_core_strict(std::string(env_core), n, why))   // F1: 同 --core, 严格
            p7baff_die(std::string("PIN_CORE 参数非法 (") + why + "): '" + env_core + "'");
        mode = M_CORE;
        target = n;
    } else if (env_rule && *env_rule && strcmp(env_rule, "auto") != 0 && strcmp(env_rule, "avoid-nic") != 0) {
        p7baff_die(std::string("PIN_RULE 取值非法: ") + env_rule + " (允许 auto|none)");
    }

    // 当前掩码 (所有模式都要读: 继承判定 + 见证 + none 分支的掩码见证)
    cpu_set_t cur;
    if (sched_getaffinity(0, sizeof(cur), &cur) != 0)
        p7baff_die(std::string("sched_getaffinity: ") + strerror(errno));

    // ---- 阶段 2: --no-pin 分支: 不探测, 不因任何环境缺件而失败 ----
    if (mode == M_NONE) {
        int cur_cpu = sched_getcpu();
        std::string onl = "n/a";
        std::string tmp;
        if (p7baff_read_file("/sys/devices/system/cpu/online", tmp)) onl = tmp;
        // ⚠️ 未绑时 **PIN_CPU 一律打非数值 "none"** —— 于是"PIN_CPU 是数值" <=> "这一跑真的绑了核",
        //    下游 naive grep (`PIN_CPU=[0-9]`) 不会把未绑的跑读成已绑。实际落点在
        //    PIN_GETCPU_START/END (那本来就是"实际在哪"的字段)。
        printf("PIN_RULE=none PIN_DEGRADED=n/a PIN_CPU=none PIN_CORES_ONLINE=%s PIN_NIC_IFACE=n/a PIN_NIC_CPUS=n/a "
               "PIN_NIC_EXCLUDED=n/a PIN_CORE_LOAD=n/a PIN_ALLOWED_MASK=%s "
               "PIN_GETCPU_START=%d PIN_FREQ_START_KHZ=%s PIN_GOV=%s UNPINNED=1 "
               "PIN_NIC_IRQLINES=n/a PIN_NIC_IFACE_SRC=n/a PIN_TUPLE_ORDER=n/a"
               " PIN_PAIR_RULE=%s PIN_PAIR_DEGRADED=n/a PIN_CPU_IO=%s PIN_CPU_WORK=%s"
               " PIN_PC_IO=n/a PIN_PC_WORK=n/a PIN_PAIR_EXCL=n/a PIN_PAIR_REQ=%s\n",
               onl.c_str(), p7baff_mask_hex(cur).c_str(), cur_cpu,
               p7baff_cpu_sysfile(cur_cpu, "cpufreq/scaling_cur_freq").c_str(),
               p7baff_cpu_sysfile(cur_cpu, "cpufreq/scaling_governor").c_str(),
               p7baff_g_want_pair ? "none" : "n/a",
               p7baff_g_want_pair ? "none" : "n/a",
               p7baff_g_want_pair ? "none" : "n/a",
               p7baff_g_want_pair ? "none" : "n/a");
        fflush(stdout);
        p7baff_g_pair_rule = p7baff_g_want_pair ? "none" : "n/a";
        p7baff_g_pair_deg  = p7baff_g_want_pair ? "n/a" : "n/a";
        p7baff_tls_unpinned = 1;                  // ⭐ 本线程不绑 (按线程记账)
        atexit(p7baff_on_exit);
        return new_argc;
    }

    // ---- 阶段 3: online 集合 (硬门) ----
    std::string onl_raw;
    if (!p7baff_read_file("/sys/devices/system/cpu/online", onl_raw))
        p7baff_die_errno("读不到", "/sys/devices/system/cpu/online");
    std::vector<int> online = p7baff_parse_cpulist(onl_raw);
    if (online.empty())
        p7baff_die("解析 /sys/devices/system/cpu/online 失败: " + onl_raw);

    // ---- 阶段 4: 模式收敛 ----
    bool explicit_core = (mode == M_CORE);
    if (mode == M_AVOID) {
        // 尊重继承: 进入时掩码已是单核 => 不覆盖, 直接采用
        if (p7baff_mask_count(cur) == 1) {
            for (int i = 0; i < CPU_SETSIZE; i++)
                if (CPU_ISSET(i, &cur)) { target = i; break; }
            mode = M_INHERIT;
        }
    }

    // ---- 阶段 5: 探测 (默认规则 = 硬门; inherit/core = 尽力而为, 只作见证) ----
    //   ⚠️ 2026-10-09: 探测体抽到 `p7baff_probe_run` (选核 + "两颗物理核" 共用**同一份**数据;
    //      两条规则各自探测必然漂移)。硬门时机 / 见证取值 / 退化标志与抽件前**逐句等价**:
    //      fatal 参数 == 原来的 need_probe (现在多一条: 请求了 pair 也变硬门)。
    std::string nic_iface_str = "n/a", nic_cpus_str = "n/a", nic_excl_str = "n/a";
    int  nic_lines = -1;
    std::string nic_src = "n/a";
    const bool need_pair = (p7baff_g_want_pair != 0) && (mode != M_NONE);
    bool need_probe = (mode == M_AVOID) || need_pair;   // 只有默认规则 (或 pair) 靠探测结果选核
    std::vector<int> nic_cpus;
    long long chosen_pc_load = -1;            // F4: 64 位 —— 旧 (int) 截断 => 和 >2³¹ 时静默打 n/a
    // F2: 探针退化信号 (语义见文件头 PIN_DEGRADED 契约; 只对默认规则定义)
    //   deg_nic  = NIC IRQ 探针 0 命中行 (iface 没找到 / 描述里没一行含接口名)
    //   deg_topo = thread_siblings_list 读不到/解析失败 (退化成"每条线程当一个物理核")
    bool deg_nic = false, deg_topo = false;
    P7baffProbe pr;

    if (mode == M_AVOID || mode == M_INHERIT || explicit_core) {
        p7baff_probe_run(pr, need_probe, env_iface, online);
        nic_iface_str = pr.iface_str();
        nic_src = pr.iface_src;
        if (pr.irq_ok) {
            nic_lines = pr.nic_lines;
            nic_cpus = pr.nic_cpus;
            nic_cpus_str = nic_cpus.empty() ? std::string("none") : p7baff_join(nic_cpus, ",");
        }

        // ---- 阶段 6: 选核 (仅默认规则; 其余模式 target 已定) ----
        if (mode == M_AVOID && pr.irq_ok && pr.soft_ok) {
            // F2: NIC 探针 **0 命中行** => "排除 NIC IRQ 核"这条规则**没算** => 退化, 必须响亮
            deg_nic = pr.deg_nic;
            deg_topo = pr.deg_topo;
            // 候选 = core_nic == 0; 空 => 全体 (真退化: 全核都有 NIC IRQ)
            std::vector<int> cand, excluded;
            for (std::map<int, std::vector<int> >::iterator it = pr.pc.begin(); it != pr.pc.end(); ++it) {
                if (pr.core_nic_at(it->first) == 0) cand.push_back(it->first);
                else excluded.push_back(it->first);
            }
            // F5: 三态分立 —— 探针退化 => n/a (没算); 真退化/空集 => none (算了, 没排除)
            if (deg_nic) {
                nic_excl_str = "n/a";       // 探针 0 命中 => 本字段没算
            } else if (cand.empty()) {
                cand = excluded;            // 真退化分支: 全核都有 IRQ, 排除不了 => 全体入选
                nic_excl_str = "none";      // 算了: 没有核被排除 (全核都在候选里)
            } else {
                nic_excl_str = excluded.empty() ? std::string("none")
                                                : p7baff_join(excluded, ",");
            }
            // 候选中 core_load 最小, 并列取物理核 id 最小
            int best = -1;
            for (size_t i = 0; i < cand.size(); i++) {
                int c = cand[i];
                if (best < 0) { best = c; continue; }
                unsigned long long lc  = pr.core_load.count(c)    ? pr.core_load.at(c)    : 0ull;
                unsigned long long lb  = pr.core_load.count(best) ? pr.core_load.at(best) : 0ull;
                if (lc < lb) best = c;
                else if (lc == lb && c < best) best = c;
            }
            if (best < 0) p7baff_die("选不出候选物理核");
            chosen_pc_load = pr.core_load.count(best) ? (long long)pr.core_load.at(best) : 0;
            // 该物理核内选线程: 三元组 (**自身负载**, 兄弟负载, 线程号) 最小
            //   = own-first (2026-10-08 对抗审查裁定; 旧 sib-first 已废 ——
            //     app 只占一条逻辑线程 => 自身负载一阶; Haswell L1D/L2 两线程共用
            //     => "跨线程丢局部性"不成立; 旧序会选中同核里**更忙**的那条)
            //   (2026-10-09: 逐句搬到 p7baff_pick_thread_in_pc —— pair 选核复用同一函数)
            int pick = p7baff_pick_thread_in_pc(pr, best);
            if (pick < 0) p7baff_die("选不出线程 (物理核为空)");
            target = pick;
        }
    }

    // ---- 阶段 6b: 两颗不同物理核 (2026-10-09; 只在程序/命令行请求时跑) ----
    //   ⚠️ 放在**主线程 target 定了之后**: 规则要排除"主线程所在的那颗物理核"。
    //   ⚠️ 探针数据缺失 (inherit/core 模式下 fatal=false 的探针失败) => **硬门 exit(2)**:
    //      pair 不能在"瞎猜的负载"上选核 (那会让两颗核的见证变成假话)。
    if (need_pair) {
        if (!(pr.irq_ok && pr.soft_ok)) {
            pr = P7baffProbe();                       // 重探一次 (幂等; 这回是硬门)
            p7baff_probe_run(pr, true, env_iface, online);
        }
        P7baffPair pair = p7baff_pick_pair(pr, target);
        if (!pair.ok()) p7baff_die("选不出两颗核 (可用物理核为空)");
        p7baff_g_pair_cpu[0] = pair.cpu[0]; p7baff_g_pair_cpu[1] = pair.cpu[1];
        p7baff_g_pair_pc[0]  = pair.pcid[0]; p7baff_g_pair_pc[1]  = pair.pcid[1];
        p7baff_g_pair_load[0] = pair.load[0]; p7baff_g_pair_load[1] = pair.load[1];
        p7baff_g_pair_rule = pair.rule;
        p7baff_g_pair_deg  = pair.degr;
        p7baff_g_pair_excl = pair.excl;
        p7baff_g_pair_active = 1;
    }

    // ---- 阶段 7: 校验目标核 + 绑定 ----
    if (target < 0) p7baff_die("内部错误: 未选出目标核");
    if (std::find(online.begin(), online.end(), target) == online.end())
        p7baff_die(std::string("目标核不在在线集合内: ") +
                   std::to_string(target) + " (online=" + onl_raw + ")");

    if (mode != M_INHERIT) {                      // 继承: 不覆盖
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(target, &set);
        if (sched_setaffinity(0, sizeof(set), &set) != 0)
            p7baff_die(std::string("sched_setaffinity(") + std::to_string(target) + "): " + strerror(errno));
    }
    int got = sched_getcpu();
    if (got != target)
        p7baff_die(std::string("绑后 sched_getcpu()=") + std::to_string(got) +
                   " != 目标 " + std::to_string(target));

    cpu_set_t after;
    if (sched_getaffinity(0, sizeof(after), &after) != 0)
        p7baff_die(std::string("绑后 sched_getaffinity: ") + strerror(errno));

    // ---- 阶段 8: 见证行 (启动) ----
    std::string rule = (mode == M_AVOID) ? "avoid-nic" : (mode == M_INHERIT) ? "inherit" : "core";
    if (mode == M_AVOID && (deg_nic || deg_topo)) rule += "-degraded";   // F2: 绝不复用 avoid-nic
    std::string deg_s;
    if (mode == M_AVOID) {                       // F2: 只对默认规则定义 (其余模式 = 该模式没算)
        if (deg_nic && deg_topo) deg_s = "nic+topo";
        else if (deg_nic) deg_s = "nic";
        else if (deg_topo) deg_s = "topo";
        else deg_s = "none";
    } else {
        deg_s = "n/a";
    }
    std::string load_s = (chosen_pc_load >= 0) ? std::to_string(chosen_pc_load) : std::string("n/a");
    std::string irql_s = (nic_lines >= 0) ? std::to_string(nic_lines) : std::string("n/a");
    std::string mask_s = p7baff_mask_hex(after);
    std::string freq_s = p7baff_cpu_sysfile(target, "cpufreq/scaling_cur_freq");
    std::string gov_s  = p7baff_cpu_sysfile(target, "cpufreq/scaling_governor");
    printf("PIN_RULE=%s PIN_DEGRADED=%s PIN_CPU=%d PIN_CORES_ONLINE=%s PIN_NIC_IFACE=%s PIN_NIC_CPUS=%s "
           "PIN_NIC_EXCLUDED=%s PIN_CORE_LOAD=%s PIN_ALLOWED_MASK=%s "
           "PIN_GETCPU_START=%d PIN_FREQ_START_KHZ=%s PIN_GOV=%s "
           "PIN_NIC_IRQLINES=%s PIN_NIC_IFACE_SRC=%s PIN_TUPLE_ORDER=%s"
           " PIN_PAIR_RULE=%s PIN_PAIR_DEGRADED=%s PIN_CPU_IO=%s PIN_CPU_WORK=%s"
           " PIN_PC_IO=%s PIN_PC_WORK=%s PIN_PAIR_EXCL=%s PIN_PAIR_REQ=%s\n",
           rule.c_str(), deg_s.c_str(), target, onl_raw.c_str(), nic_iface_str.c_str(), nic_cpus_str.c_str(),
           nic_excl_str.c_str(), load_s.c_str(), mask_s.c_str(), got,
           freq_s.c_str(), gov_s.c_str(), irql_s.c_str(), nic_src.c_str(),
           (mode == M_AVOID) ? "own_sib_t" : "n/a",
           // ---- 2026-10-09 追加 (行尾; 既有字段一个字没动): 两颗核的**计划** ----
           //   计划 vs 落实: 线程自己还会打一行 PIN_THREAD …PIN_CPU_IO=<落实值>…
           //   两者必须相等 (独立交叉核); PIN_ALLOWED_MASK_<X> == 1<<PIN_CPU_<X> 是另一条。
           need_pair ? p7baff_g_pair_rule.c_str() : (p7baff_g_want_pair ? "none" : "n/a"),
           need_pair ? p7baff_g_pair_deg.c_str()  : "n/a",
           need_pair ? std::to_string(p7baff_g_pair_cpu[0]).c_str() : (p7baff_g_want_pair ? "none" : "n/a"),
           need_pair ? std::to_string(p7baff_g_pair_cpu[1]).c_str() : (p7baff_g_want_pair ? "none" : "n/a"),
           need_pair ? std::to_string(p7baff_g_pair_pc[0]).c_str()  : "n/a",
           need_pair ? std::to_string(p7baff_g_pair_pc[1]).c_str()  : "n/a",
           need_pair ? p7baff_g_pair_excl.c_str() : (p7baff_g_want_pair ? "none" : "n/a"),
           p7baff_g_pair_req_src.c_str());
    fflush(stdout);

    p7baff_tls_end_expect = target;          // ⭐ 约束 ③: **本线程**记自己的期望核 (主线程)
    p7baff_tls_unpinned = 0;
    atexit(p7baff_on_exit);
    return new_argc;
}

#endif  // P7B_AFFINITY_H
