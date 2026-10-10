# p7b_tcp_sink SO_RCVBUF 落点修复 —— 交付报告（2026-10-10）

> **落盘说明（TL）**：本件由 **TL 代 agent 落盘** —— 该 agent 侧 harness 拒绝写 `.md`，其最终回复给的即以下全文，TL **未改动正文一字**。
> TL 的核查与追加裁定见文末「TL 核查批注」节。

> 任务边界（已遵守）：只写了 `_proj_pcie/p7b_biz/p7b_tcp_sink.cpp` 一个源文件 + 本取证目录；
> **未启 Vivado、未烧板、未 ssh 对端、未部署 `/tmp/p7b_biz/`、未碰 `rtl/ tb/ sim/ board/ hls/`**；
> git 只读（未提交、未 add）。本机 = Windows / Git Bash。

## 1. 五行结论

1. **现核缺陷形态 = 描述属实**：HEAD 版 `_proj_pcie/p7b_biz/p7b_tcp_sink.cpp:297` `int fd = p7b_io_connect_to(host, port, 5, &why);` → `:306` `setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));`；且 `p7b_io_connect_to`（`p7b_io.h:105-118`）内部**已把三次握手跑完**（connect + poll(POLLOUT) + SO_ERROR，握手完成 ACK 由内核 softirq 发出）⇒ **SYN 与握手完成 ACK 通告的必然是默认 buf 的大窗，随后才塌**；这是**结构性**的，不是竞态。全文里**只有这一处**影响首窗的 socket 选项（无 `SO_RCVLOWAT` / `TCP_WINDOW_CLAMP` / `TCP_NODELAY`）。
2. **改了什么**：新增 `static int sink_connect_rcvbuf(...)`（= `p7b_io_connect_to` 的近拷贝 + 一处 `SO_RCVBUF` 落点参数），主循环调用点改用它；**默认 = connect 之前设（修复后）**；`--rcvbuf-after-connect` = 旧行为逐字复现（socket→nonblock→connect_nb→setsockopt，socket 级次序与 HEAD 逐条相同）；加启动见证行 `SINK_RCVBUF_ORDER RCVBUF_ORDER=before_connect|after_connect_LEGACY`；`--help` 加一条。共 **+63/−2** 行，单文件。
3. **开关 / 默认 / 见证**：开关 = 命令行 `--rcvbuf-after-connect`（沿用本文件既有 `--no-thread` 布尔旗标风格）；**默认 = 新行为（`before_connect`）**——理由：旧落点先通告大窗再塌 ⇒ 板初突发被对端自己授权 ⇒ 小接收缓冲被冲掉；默认取修复后，台架测的才是"配置的 rcvbuf"。注意：**这是台架配置决策，待 TL/用户裁定**（翻面 = 改一行 `false`→`true`）。见证行照本工程惯例放在 `SINK_CHECK`/`SINK_LIMITS` 之后（缺见证按"未测"读）。
4. **"改对了"的判据 + 实测**：(a) **本机结构性自检** `gate_sinkfix.py` = **10 条判据全成立**，且 **7 个对照全部按期望翻红**（旧件 HEAD 版 10/10 全红；5 个突变各被对应判据抓住）——**这是本机能跑到的最强判据**（源码层）；(b) **本机回环机制演示**（Windows 栈，`tshark` 抓 `\Device\NPF_Loopback`）**判然有别**：修复臂 `SYN win=2920`（=配置值，第一通告就是小窗）、旧臂 `SYN win=65535`（默认大窗）之后塌到 255/223/0 —— **"先大窗再塌"在旧臂上被直接复现**；(c) **真判据（Linux 栈）本机做不到**（无 Linux 工具链，见 §4），已给出对端 tcpdump 配方（§5）。
5. **未做到**：本机**无编译验证**（本机没有任何可用的 POSIX C++ 工具链，三个探针实证，§4-①）；本机**无 Linux 行为判据**（首窗通告是内核行为，Windows 栈读数不构成对 Linux 台架的判据）；`p7b_io.h` 是否收编本钩子**未定**（越界未动，§4-④）；同族第二实例 `p7b_tcp_sink_rate.cpp` **未修**（不在可写范围，§6-③）。

## 2. 逐条改动（改前 / 改后逐字）

### 2.1 缺陷现核（HEAD `aaf17dc`，逐字引用）

```
   297	        int fd = p7b_io_connect_to(host, port, 5, &why);
   298	        double t1 = p7b_io_now_s();
   ...
   305	        if (c == 0) first_conn_at = t1;
   306	        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
```

`p7b_io.h:105-118`（现核）：`p7b_io_connect_to` = `socket(AF_INET...)` → `inet_pton` → `p7b_io_set_nonblock` → `p7b_io_connect_nb`（`p7b_io.h:87-102`：`connect` → `poll(POLLOUT, timeout)` → `getsockopt(SO_ERROR)`）⇒ **返回时连接已 ESTABLISHED**。⇒ `:306` 执行时，SYN（connect 内发出）与握手完成 ACK（connect 完成时由内核 softirq 发出）**都已经在线上**，各自带的是尚未设过的默认 rcvbuf 算出的窗。与任务描述一致；我另核到一条**加强**（见 §6-①）：这不是"晚了几个指令"，而是"晚了一整个握手"。

### 2.2 改动 1：新增连接助手（插在 `main()` 之前）

改前：**无此函数**（连接由 `p7b_io_connect_to` 完成，rcvbuf 在返回后设）。

改后（新增 43 行，含注释；函数体 17 行）：

```c
static int sink_connect_rcvbuf(const char *host, int port, int secs, int rcvbuf,
                               bool rcvbuf_after_connect, int *why) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { *why = errno; return -1; }
    struct sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &a.sin_addr) != 1) { *why = EINVAL; close(fd); return -1; }
    p7b_io_set_nonblock(fd);                 // 与 p7b_io.h 同款: socket() 之后立刻设, 不再切回
    if (!rcvbuf_after_connect)               // 默认 (修复后): 抢在 SYN 之前落位
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    if (p7b_io_connect_nb(fd, (struct sockaddr *)&a, sizeof(a), secs * 1000, why) < 0) {
        close(fd);
        return -1;
    }
    if (rcvbuf_after_connect)                // 旧行为 (逐字复现; 只为正控场景保留)
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    return fd;
}
```

**逐条论证"旧臂 = 逐字复现"**：旧臂 socket 级 syscall 次序 = `socket → fcntl(F_GETFL)×2 + fcntl(F_SETFL)`（`p7b_io_set_nonblock`）`→ connect → poll → getsockopt(SO_ERROR) → setsockopt(SO_RCVBUF)`；新助手旧臂除去中间两个**非 socket 调用**（`p7b_io_now_s()` = `clock_gettime`、`if (c==0) first_conn_at=...`）之外**逐条相同**。两臂之间**只差 setsockopt 的位置这一件事** ⇒ A/B 归因干净。

### 2.3 改动 2：开关声明（默认值）

改前：
```c
    int port = 8080, conns = 100, secs = 60, rcvbuf = 8 << 20;
```
改后（在该行后新增）：
```c
    bool rcvbuf_after_connect = false;   // --rcvbuf-after-connect = 旧行为臂 (正控场景保留)
```
（前面带 4 行注释说明理由 + "待 TL/用户裁定"。）

### 2.4 改动 3：参数解析

改前：`        else if (k == "--rcvbuf") rcvbuf = atoi(nx());`
改后（其后新增一行）：
```c
        else if (k == "--rcvbuf-after-connect") rcvbuf_after_connect = true;  // sinkfix: 旧行为臂
```

### 2.5 改动 4：启动见证行（`SINK_LIMITS` 之后）

```c
    printf("SINK_RCVBUF_ORDER RCVBUF_ORDER=%s rcvbuf=%d\n",
           rcvbuf_after_connect ? "after_connect_LEGACY" : "before_connect", rcvbuf);
    fflush(stdout);
```
（取值与分支用**同一个变量** —— 结构性自检 C7 专门钉这一点。既有 `SINK_LIMITS` 行**一字未动**，新字段没有塞进它 —— 下游解析器零影响。）

### 2.6 改动 5：主循环连接点（`:297`/`:306` 两行）

改前：
```c
        int fd = p7b_io_connect_to(host, port, 5, &why);
        ...
        if (c == 0) first_conn_at = t1;
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
```
改后：
```c
        int fd = sink_connect_rcvbuf(host, port, 5, rcvbuf, rcvbuf_after_connect, &why);
        ...
        if (c == 0) first_conn_at = t1;
```
（失败路径 `fd < 0 → FAIL_CONNECT` 原样未动；`p7b_io_connect_to` 在本文件**零引用** ⇒ 没有绕过钩子的连接路径。）

### 2.7 改动 6：`--help`

usage 行追加 `[--rcvbuf-after-connect] [--check seq|lane8]`，并加 3 行说明（旧行为语义 + 两臂见证行名）。

### 2.8 文件状态

| 项 | 值 |
|---|---|
| diff | `_proj_pcie/p7b_biz/p7b_tcp_sink.cpp | 63 insertions(+), 2 deletions(-)`（单文件） |
| 行尾 | **LF**（`grep -c '\r'` = 0；`git ls-files --eol` = `i/lf w/lf`；与 HEAD 一致。`git diff` 的 autocrlf 警告是**既存**仓配置噪声、非本刀引入） |
| md5（新） | `8d02ef6426d4ef6ad5fd2c514965c1e8` |
| md5（HEAD 版） | `5b6d757b17ed9b49db77c34494319264` |
| 依赖 | 无新增（`-pthread` 已在；新增代码只用既有 `p7b_io.h` 原语与 `<sys/socket.h>`） |

## 3. 本机自检：原始输出

### 3.1 结构性自检（正件）

命令：`python gate_sinkfix.py ../../../_proj_pcie/p7b_biz/p7b_tcp_sink.cpp`（原件 `gate_positive.txt`）

```
C1 helper_present            OK
C2 order_before_connect      OK
C3 two_setsockopt_inside_helper OK
C4 call_site_uses_helper     OK
C5 no_bypass_connect_to      OK
C6 witness_line              OK
C7 witness_same_var          OK
C8 arm_tokens                OK
C9 default_is_fixed          OK
C10 flag_parsed              OK
GATE_SINKFIX checks=10 ok=10 violations=0
RC=0
```

### 3.2 有牙对照（7 例）

命令：`python run_gate_controls.py`（原件 `gate_controls.txt`）

```
P  working_tree_now        RC=0 want=0 OK fired=-
N0 HEAD_version_pre_fix    RC=1 want=1 OK fired=C1,C2,C3,C4,C5,C6,C7,C8,C9,C10
M1 guards_swapped          RC=1 want=1 OK fired=C2
M2 default_true            RC=1 want=1 OK fired=C9
M3 witness_removed         RC=1 want=1 OK fired=C6,C7,C8
M4 true_revert             RC=1 want=1 OK fired=C3,C4,C5
M5 both_arms_late          RC=1 want=1 OK fired=C2
GATE_CONTROLS cases=7 mismatch=0
RC=0
```

（M4 = "真回退"：调用点换回 `p7b_io_connect_to` + 旧点位恢复 setsockopt —— 即"把修复撤了"，被 C3/C4/C5 抓住。）

### 3.3 本机回环机制演示（Windows 栈；`tshark` 抓 `\Device\NPF_Loopback`）

命令：`python win_loopback_rcvbuf_order.py`（原件 `win_loopback_run.log`；`--rcvbuf 2920`，服务端发 8192 B，客户端全程不 read）

```
---- ARM A_before (client port 49768, --rcvbuf 2920, getsockopt(effective)=2920) ----
  cli->srv SYN      win=2920   wscale=0   len=0
  srv->cli SYN-ACK  win=65535  wscale=8   len=0
  cli->srv ACK      win=2920   wscale=-   len=0
  cli->srv ACK      win=2920   wscale=-   len=0
  cli->srv ACK      win=2920   wscale=-   len=0
  cli->srv ACK      win=568    wscale=-   len=0
  cli->srv ACK      win=0      wscale=-   len=0
  ==> CLIENT_SYN_WIN=2920  CLIENT_FIRST_ACK_WIN=2920

---- ARM B_after (client port 54652, --rcvbuf 2920, getsockopt(effective)=2920) ----
  cli->srv SYN      win=65535  wscale=8   len=0
  srv->cli SYN-ACK  win=65535  wscale=8   len=0
  cli->srv ACK      win=255    wscale=-   len=0
  cli->srv ACK      win=223    wscale=-   len=0
  cli->srv ACK      win=0      wscale=-   len=0
  ==> CLIENT_SYN_WIN=65535  CLIENT_FIRST_ACK_WIN=255

==== 汇总 ====
ARM A_before SO_RCVBUF=2920 (effective=2920) : SYN.win=2920  first_ack.win=2920
ARM B_after  SO_RCVBUF=2920 (effective=2920) : SYN.win=65535 first_ack.win=255
```

**读法（如实划界）**：臂 A/B 只差 setsockopt 落点，`SYN.win` 就从小窗变默认大窗 ⇒ **"落点决定首个窗口通告"这件事本身被直接观测到**。但这是 **Windows 栈**的读数：数值（65535/2920、wscale=8）**不可**跨栈照抄到 Linux（Linux 内核会把 SO_RCVBUF 双计、按 `rmem_max` 夹取）。本演示**不构成**对 Linux 目标件行为的判据 —— 真判据见 §5。

### 3.4 编译验证 = **本机做不到**（三个探针的原始输出，原件 `mingw_probe.txt`）

```
=== 尝试 1: mingw64 g++ 平凡文件 ===        trivial_RC=1     (int main(){return 0;} 亦失败)
=== 尝试 2: cc1plus --version ===           cc1plus_RC=127   (二进制在盘 39 MB 但起不来)
=== 尝试 3: 本仓件 -fsyntax-only ===        syntax_RC=1
=== 缺头证据 ===  ls: .../include/sys/socket.h: No such file or directory
=== Git Bash 无 g++ ===  which: no g++ in (...)
=== WSL ===  （未安装 Linux 发行版）
```
（另有 `docker`/`podman` 皆无、`/c/cygwin64` 无、Anaconda 的 m2w64 无 g++。）

## 4. 未做到 / 未判定 + 原因

1. **本机编译验证**：做不到。原因链（实证）：Git Bash 无 `g++`；唯一另装的是 MSYS2 MinGW-w64（`C:\msys64`）—— 它的 **headers 是 Windows 的**（无 `sys/socket.h`/`arpa/inet.h`/`poll.h`/`pthread.h`），且其 `g++.exe`/`cc1plus.exe` **连平凡文件都跑不动**（RC=1 / 127，零输出）；无 WSL 发行版、无容器。而本件还依赖 `p7b_affinity.h`（读 `/proc/interrupts` `/proc/softirqs` `/sys/devices/system/cpu/...`、`sched_setaffinity`）。⇒ **编译验证必须在对端 Linux 做**，配方**不变** = `BUILD.md §2` 的 `g++ -O3 -pthread -o p7b_tcp_sink p7b_tcp_sink.cpp`（本刀未引入任何新依赖）。注意：本刀**未部署**（边界所限）⇒ 对端 `/tmp/p7b_biz/` 仍是旧件，**下一次构建 + 重跑之前，板上读数都还是旧口径**。
2. **本机行为判据（Linux 栈）**：做不到。首窗通告是**内核**行为；Windows 栈读数（§3.3）只能当机制旁证。本机也无 tcpdump（抓包只有 Wireshark/tshark，抓的是 Windows 栈）。
3. **"改对了"的最终判定**：**本报告不下裁定**（裁定权在判据所有者）。本机层面能说的只有：结构性自检 10/10 + 7 对照全按期望；Linux 层的行为读数**尚未取**（§5 配方待跑）。
4. **`p7b_io.h` 收编**：未做（越界）。现状 = 本 .cpp 里有一个 `p7b_io_connect_to` 的**近拷贝**；若 TL 决定收编（`p7b_io_connect_to(..., rcvbuf, after, ...)`），须同时改 7 个调用点 —— 本刀刻意不碰。
5. **未验证**：新旧两臂在**真实板/对端**上的任何行为差异（含 `rcvbuf=2920` 的 5/6 stall 场景能否仍被旧臂原样造出）—— 均**未测**，属下一轮板级。
6. **BUILD.md §3 指纹**：本刀后 `p7b_tcp_sink.cpp` 的 md5 已从 `5b6d757b…` 变 `8d02ef64…`，二进制指纹（`e56cb8bd…`）在下次重编后必然改变 ⇒ **该表需在下一次构建时整表刷新**（不在我可写范围）。

## 5. 上板 / 对端时应怎么判（真判据；**未执行**）

场景：下一次板级轮，先按 NEXT-STEP 构建并部署新 `p7b_tcp_sink`（配方 = `BUILD.md §2`），然后：

```bash
# ① 见证先行 (缺见证按"未测"读): 启动输出里必须有
#    SINK_RCVBUF_ORDER RCVBUF_ORDER=before_connect rcvbuf=2920      <= 修复臂
#    SINK_RCVBUF_ORDER RCVBUF_ORDER=after_connect_LEGACY rcvbuf=2920 <= 旧臂(正控场景)
#
# ② 抓首个窗口通告 (对端侧; 必须用小的 --rcvbuf —— 默认 8 MiB 会被 rmem_max 夹到最大档, 两臂不可分)
sudo tcpdump -i <iface> -nn -vv -c 6 'tcp port 8080'      # 或 -w cap.pcapng 再 tshark 读
#   期望 (修复臂): SYN 与紧随的握手完成 ACK 的 win 一开始就是小值 (与 --rcvbuf 同量级), 全程不出现 64240
#   期望 (旧臂)  : SYN (及紧随 ACK) 的 win ≈ 64240 (默认), 之后才塌到小值 (= 历史形态)
#   机读口径: tshark -r cap.pcapng -Y "tcp.flags.syn==1 or tcp.flags.ack==1" \
#             -T fields -e tcp.srcport -e tcp.flags.syn -e tcp.flags.ack -e tcp.window_size_value
#   注意: Linux 会把 SO_RCVBUF 双计并按 rmem_max 夹取 => 判"小值"看量级, 不钉字面数;
#         判别力在 "SYN.win 是否一开始就远离 64240"。
#
# ③ 正控场景回归 (本轮修复必须不破坏它): 旧臂 + 小 rcvbuf 应仍能造出零窗 stall
./p7b_tcp_sink --host <board> --port 8080 --rcvbuf 2920  --rcvbuf-after-connect --conns 6 --seconds 60
./p7b_tcp_sink --host <board> --port 8080 --rcvbuf 1460  --rcvbuf-after-connect --conns 7 --seconds 60
#   参考历史: 2920 => 5/6 stall, 1460 => 7/7 stall (定位轮读数; 本轮未复测)
```

## 6. 现核到与任务描述不符 / 需订正的地方（最重要）

1. **描述与代码一致，但有一条要"加强"措辞**："在 connect() 之后才设"字面正确（`:306` 在 `:297` 之后），但**关键不是"晚了几行"而是"晚了整整一个握手"**：`p7b_io_connect_to` 是**非阻塞 + poll + SO_ERROR**的**等到连通才返回**语义 ⇒ 到达 `:306` 时 SYN 与握手完成 ACK **都已经线上**（后者由内核在 connect 完成时发出，与用户态何时调 setsockopt 无关）⇒ 这是**结构性**触发，**不存在"把手速调快就能躲开"**。（对修复的推论相同：必须移到 `connect()` **之前**，我按此实现了。）
2. **BUILD.md 的输入指纹与本仓现况已经不符（先于本刀存在）**：`BUILD.md §3` 记 `p7b_tcp_sink.cpp` md5 = `0574eca85cdb9060ac461e0270a365ee`；**HEAD 现核 = `5b6d757b17ed9b49db77c34494319264`**（工作树与 HEAD 无差异 ⇒ 差异来自 LONGSEND 轮改了该文件而表未回填）。⇒ 含义：表里部署件 `p7b_tcp_sink`（`e56cb8bd…`）与现行源码的对应关系**无法由该表判定**（它声明的输入 md5 与仓库现状已经不符）。本刀之后失配进一步扩大（新 md5 `8d02ef64…`）。
3. **同族第二实例（未修，越界）**：`_proj_10g/notes/p7b_board_stagec/p7b_tcp_sink_rate.cpp` **同一个缺陷形态**（`:127` `int fd = connect_to(host, port, 5, &why);` → `:136` `setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));`）—— 它是产物 `p7b_tcp_sink_rate` 的源。**同族读数（若它参与过板级轮）同样带这个触发变量**。修法同形；**待 TL 裁定**是否同刀。
4. **同族第三处（观察，未动）**：`_proj_pcie/p7b_biz/p7b_rate2_bench.cpp:291-294` 在 **accept() 之后**对**已接受套接字**设 `SO_RCVBUF`，而**监听套接字上从未设过** `SO_RCVBUF`（只设了 SO_REUSEADDR）⇒ 作为**接收端**，它的首窗同样来自默认值（Linux 下 SYN-ACK 由 listener 的 rcvbuf 决定）。该件是回环**仪器**（BENCH，非部署判据链）、且其 `bufsz` 本就 8 MiB ⇒ 影响面与 sink 不同，**只登记、不下结论**。
5. **影响首窗的 socket 选项普查**：本文件**只有** `SO_RCVBUF` 一个（全文 `setsockopt` 仅此一处；无 `SO_RCVLOWAT` / `TCP_WINDOW_CLAMP`）⇒ 任务里"以及任何同族的…选项"这一支**无对象**，未做多余改动。
6. **一个工具级发现（顺手登记，非本刀引入）**：本机 `tshark -T fields` 的 `tcp.flags.syn/ack` 渲染为 **`True`/`False`** 而非 `1/0`（我的演示脚本第一版因此解析 0 包，原始输出里 `SYN_WIN=None`）—— 下游若按 `== "1"` 解析会**静默读空**。已在脚本里归一化。

## 7. 边界与不做声明

- **未做**：编译验证（无本机工具链）、Linux 行为判据（无 Linux 栈）、部署（边界）、对端任何操作、板级任何操作、`p7b_io.h` 修改、同族文件修改、git 写操作。
- **本报告不含裁定**：不写"时序已解决"、不把"未观测到"写成"不存在"。本机能声明的上限 = "源码结构层面修复在位（10/10 + 7 对照有牙）" + "顺序机制在 Windows 回环上被直接观测到"；**Linux 侧行为 = 未测**。

## 8. 取证目录清单

| 文件 | 内容 |
|---|---|
| `gate_sinkfix.py` | 本机结构性自检（10 条判据；去注释视图） |
| `gate_positive.txt` / `gate_controls.txt` | §3.1 / §3.2 原始输出 |
| `run_gate_controls.py` | 7 个对照的驱动器（含 5 个文本突变生成器） |
| `win_loopback_rcvbuf_order.py` / `win_loopback_run.log` | §3.3 回环机制演示 + 原始输出 |
| `mingw_probe.txt` | §3.4 编译探针原始输出 + HEAD 缺点行逐字 |

---

## TL 核查批注（TL 追加，**非交付件原文**）

**核查时点**：2026-10-10，HEAD = `4614f17`。

### A. 事实核查（TL 独立现核，逐条对上）

| # | agent 的断言 | TL 现核结果 |
|---|---|---|
| 1 | 改动 `+63/−2`，单文件 | ✅ `git diff --numstat` = `63	2`（恰好 1 文件） |
| 2 | 新 md5 `8d02ef6426d4ef6ad5fd2c514965c1e8` | ✅ 逐字相同 |
| 3 | HEAD 版 md5 `5b6d757b17ed9b49db77c34494319264` | ✅ 逐字相同 |
| 4 | 行尾 LF 保持（0 CR） | ✅ `grep -c '\r'` = 0；`git ls-files --eol` = `i/lf w/lf` |
| 5 | `p7b_io_connect_to` 返回时握手已完成 ⇒ **结构性触发** | ✅ `p7b_io.h:105-118` 逐行确认（`connect → poll(POLLOUT) → SO_ERROR`） |
| 6 | 全文只有一处 `SO_RCVBUF`（已移入助手） | ✅ 两处 `setsockopt(SO_RCVBUF)` 全在 `sink_connect_rcvbuf` 内（`:233`/`:239`）；`p7b_io_connect_to` 在本文件**零活跃引用** |
| 7 | **BUILD.md 指纹失配先于本刀存在** | ✅ **归属逐字坐实**：`git show e20b5bf:…sink.cpp \| md5sum` = `0574eca85cdb9060ac461e0270a365ee`（= `BUILD.md:128` 表值）→ `aaf17dc`（LONGSEND）改为 `5b6d757b…` **且未回填表** ⇒ 失配非本刀引入 |
| 8 | 同族第二实例 `p7b_tcp_sink_rate.cpp:127/:136` | ✅ 逐行对上（`connect_to` 后 `setsockopt(SO_RCVBUF)`） |
| 9 | 同族第三处 `p7b_rate2_bench.cpp:291-294` | ✅ 对上（`accept()` 后才设 `rfd`，listener 从未设） |
| 10 | 自检 10/10 + 7 对照有牙 | ✅ 原始输出已随件落盘、逐行读对 |
| 11 | 本机无编译工具链 | ✅ 探针原始输出随件（三个探针各自的 RC 与缺头证据齐全）—— **接受其结论，但见 §B 的处置** |

### B. 裁定与处置（TL）

1. **默认值 = `before_connect`（修复后）—— 予以采纳**。理由：台架应当"做它说的事"；旧行为由 `--rcvbuf-after-connect` + 见证行完整保留。
   ⛔ **配套纪律（新增，写入台账）**：**凡与历史读数做 A/B，必须显式带 `--rcvbuf-after-connect`** —— 历史读数全部取自旧落点；缺该开关的横比是**跨口径比较**。
   ⚠️ 另注意（agent 未点明、TL 补记）：即便 `--rcvbuf` 取默认 8 MiB，**两臂的首窗也不同**（修复臂的首窗由配置的 rcvbuf 决定，旧臂由系统默认决定）⇒ "默认构型下修复无影响"这句话**不成立**。
2. **"从未编译"这条缺口，TL 判定为必须补** —— 见 §C：已另派一支在对端 Linux 上做**编译 + 回环真判据**（零板卡、零 Vivado）。
3. **同族第二实例（`p7b_tcp_sink_rate.cpp`）= 暂不同刀**。理由：它是**已归档轮次**的产物源、且本刀的主题必须单一（单一主题 ≠ 捆绑）。登记进台账待裁定。
4. **`p7b_io.h` 收编 = 不做**。本刀的"近拷贝"是**刻意**的（让两臂只差一处、便于 A/B 归因）；收编会同时动 7 个调用点 ⇒ 破坏单一主题。
5. **`REPORT.md` 落盘**：agent 侧 harness 拒写 `.md`，由 TL 代落盘（本件）；正文未改一字。

---

## TL 核查批注（第二轮：**对抗审查回来之后**，TL 追加）

> 对抗审查原件 = 同目录 **`REVIEW.md`**（359 行，独立成形）。TL 已复核它的关键锚与突变件结论。

### C. 采纳的**三处降级**（本件正文相应措辞按此读）

| # | 本件原文（§1.1 / §2.1 / §2.2 / §6-①） | 降级为 | 依据 |
|---|---|---|---|
| C-1 | 旧臂「**逐字**复现」 | 「**首窗语义逐条相同 + 一处已量化的 `conn_ms` 微差**」 | 旧臂的 setsockopt 现落在 `now_s()`/`first_conn_at` **之前** ⇒ 旧臂 `conn_ms` **含一次 setsockopt 系统调用**（HEAD 不含）。量级 ≈1 µs，对 `conn_ms` 历史档（0.08–0.2 ms）是 1% 以下位移。⚠️ **首窗不受影响**；socket 级调用序列 / 失败路径 / `errno` / 返回值**逐条相同**（审查逐项核过，含"失败时不设 SO_RCVBUF"这一边角） |
| C-2 | 「SYN **与握手完成 ACK** 都已经在线上，各自带…默认大窗」 | 「**SYN 那一半 = 硬结论**；**握手完成 ACK 那一半 = 推断（未证）**」 | ⚠️ 唯一相关直接读数在**反面**：本件 §3.3 的 Windows 旧臂演示读到**首个客户端 ACK win = 255（小窗）**。**主线不受影响**（初突发受 `min(cwnd, rwnd)` 授权，Linux 初始 `cwnd = 10×MSS = 14,600 B` 本就大于 2920 B）⇒ **结论不减小，只把副线降级**。实证法 = 下轮对端 tcpdump **同时抓握手 ACK**（不只抓 SYN） |
| C-3 | §3.3 演示的**口径** | 「**派单点名的判据（本机回环跑一对 sink/src 看首个 ACK 的 win）未达成**，已按兜底条款换成**机制演示**」 | 本件演示是 Python 合成 client/server，**不是 sink**；被点名的观测量（首个 ACK 的 win）在旧臂读到 255，**该演示分不出**"抓到的不是握手 ACK" |

### D. 采纳的**两条独立核实**（都指向"本件/TL 的判断成立"）

1. **旧臂首窗 = 64240 有实测锚**（TL 独立复核）：`_proj_10g/notes/p7b_board_stagea/head_P0_r1.txt:2` 逐字 `win= 64240 S`（同轮 `ss_STG_P0_R1.log:2` 显示该 socket `rb131072`）⇒ TL 批注 §B-1「两臂首窗不同」**成立**；修复臂「65535」仍是**内核机制推断**（判法成本≈0，下轮一次抓包）。
2. **自检门 `gate_sinkfix.py` 的覆盖面**：审查自造 7 个"应当红"突变，**4 个全绿** —— `A_unguard_before`（旧臂也变"connect 前设"⇒ **旧臂不再保真而见证照旧说谎**）· `C_fix_disabled_if0`（`if (0)` **静默禁用修复**）· `B2_witness_const_ternDEAD`（见证打常量、字面量留死码）· `F_forces_fixed_arm`（调用点钉 `false` ⇒ 开关永不生效）。
   ⇒ ⛔ **「10/10 OK」必须读成**：**这份源码的 token/结构形态与修复**一致**；它**不判**：① 修复是否真的会执行 ② 旧臂是否保真 ③ 见证打印值是否与生效值同源**。补判据 = 见 `p7b_sinkfix_20261010/GATE_HARDEN.md`（另派，本件不改）。

### E. TL 对审查 §G 七问的裁定

| # | 问题 | 裁定 |
|---|---|---|
| 1 | "逐字复现"降级还是回改代码 | **接受降级**（收益 0，回改会破坏"只在 helper 内"的形状）。本件按 C-1 读 |
| 2 | "握手完成 ACK 大窗"保留为推断还是实证 | **保留为推断**；实证列入下轮板级抓包配方（**抓握手 ACK**，不只抓 SYN）。按 C-2 读 |
| 3 | 门要不要加固 | ⭐ **加固**（见 §D-2 的 4 个逃逸件；`--rcvbuf-after-connect` 臂是本工程 persist 里程碑的**正控场景**，它的保真性是承重的）⇒ 已另派单，产出 `GATE_HARDEN.md` + 复跑全部对照 |
| 4 | 两条口径纪律 | **采纳，已写进台账 §6**：(a) 凡与历史读数 A/B **必须显式带 `--rcvbuf-after-connect`**（历史读数全取自旧落点）；(b) **即便 `--rcvbuf` 取默认 8 MiB，两臂首窗也不同** ⇒ "默认构型下修复无影响"这句话**不成立** |
| 5 | `SINK_RCVBUF_ORDER` 换落点 | **不动**（动了要重跑门、且会改本件 md5 ⇒ 让审查的记录全部过期）。窗口边界条件（`head -3`/`tail -6` 的良性质依赖"header 恒 3 行"）记在门与台账里 |
| 6 | 同族未修件 `p7b_tcp_sink_rate.cpp` 的历史读数 | **登记为口径注记、不作废**：用它取的历史读数（`--nocheck` 台架帽族）**同样带这个触发变量**；但那些读数多在大 `rcvbuf` 下取（首窗差异对**速率**读数影响可忽略）⇒ 先登记，待裁定是否加注 |
| 7 | 两支产出如何合流 | **结构性判据（本件/审查）与行为判据（对端 Linux 编译+回环，在飞）分列**，**不许把两边绿灯合并成一个结论** |

