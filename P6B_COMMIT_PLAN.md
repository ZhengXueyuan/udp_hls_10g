# P6B_COMMIT_PLAN — P6b 收尾：**提交方案**（本文件只出方案，**未执行任何 git 操作**）

> 基线：`HEAD = a31c86b`，工作区 **~202 个已跟踪改动 + ~569 个未跟踪文件（展开后 25.3 MB）**
> （未跟踪量在 `.gitignore` 生效前是 **209.3 MB 未忽略**）。
> 编写时间：2026-09-29 13:3x。⚠️ **期间有另一个 agent 的 P4 矩阵在跑**（它只写 `sim/p4sim/` 下的
> 日志与指纹、`sim/p4gates/work_*/`），所以计数会小幅漂移；**本方案的所有清单都是"编写时磁盘上的
> 真实状态"**，若期间有别的 agent 继续改动，请用 §6 的命令重新生成清单再执行。

---

## 0. 铁律与前置（**先读**）

1. **绝不 `git add -A` / `git add .` / `git commit -a`。** 每条提交都按下文**显式路径**添加。
   目录级 `git add <dir>/` 是允许的（仍是显式），但只对**同质**目录使用，并在 §3 里注明。
2. **提交前逐条自检**：
   ```bash
   git status --porcelain -- <本提交的清单>      # 确认没有夹带
   git diff --cached --stat                      # 确认暂存区就是清单
   ```
3. **顺序**：`C0`（`.gitignore`）**必须第一个提交** —— 否则后面 `git add <dir>/` 会把
   仿真残渣（`xsim.dir/`、`*.wdb`、`*.memh`）一起吸进去（历史教训：上一轮 119 MB 仿真残渣差点进库）。
4. ⚠️ **`sim/p4sim/matrix_p4dfix.log` 与 `sim/p4sim/P4_MATRIX_FINGERPRINT_*.txt` 正在被另一个
   agent 的矩阵跑写入**（本窗口 13:20 起）。**等它跑完再提交这几个文件**（否则提交的是半截日志）。
   同理：**提交前确认没有 vitis/xsim 进程在跑**。
5. **不要提交被忽略的产物**：`*.bit` / `*.pcap` / `*.dcp` / `xsim.dir/` / `*.wdb` / `*.memh`（scratch 下）
   都在 `.gitignore` 里 —— 若某个产物**确实要入库**，用 `git add -f` 并在此文件里登记理由。
6. **不进 `D:\repo\perfv`**；**不动板子/不重启 192.168.0.38**（本方案只涉及 git 与文档）。

---

## 1. 变更全貌（分层统计）

| 层 | 说明 | 已跟踪改动 | 未跟踪（新） |
|---|---|---|---|
| `rtl/` `tb/` | **P6b 行为改动**（3 个新模块 + 4 个缺陷修复 + 2 个 TB） | 9 | 8 |
| `_proj_pcie/` | 观测通道 36 字 + 验收/冒烟脚本 | 10 | 6 + `smoke_scratch/` |
| `board/` | 顶层/约束/构建/板级报告 | 34 | 24 + 2 目录 |
| `sim/`+`tools/` | P6b 门、工具、**P4 矩阵硬化工具链** | 155 | ~250 |
| `p5e_verify/` `p5f_verify/` `p6_verify/` `hls/` | **纯路径硬化** | 19 | 0 |
| 文档 | `P6B_*.md` `P6E_OBS.md` `PORT_NOTES.md` `README.md` `.gitignore` | 5 | 6 |
| 三个 scratch 目录 | 审查/审计/集成 agent 的原始证据 | 0 | ~150（文本） |

**关键区分**（这是本方案的分层依据）：
- **「路径硬化」= 169 个已跟踪文件**：加了自定位 `REPO_ROOT` + 守卫/绊线（`P4GUARD` / `checkpaths` /
  `selfcheck`）。它们的 diff **只与路径有关**，不含任何 P6b 行为。
  精确清单 = `sim/p4gates/evidence/inventory_eco_class.txt` 里所有 `FIXED(` 的 **tracked** 行
  （150 个）**+ 20 个在清单外**（见 §4.1，它们是被更早的迁移脚本 `_tmp_p4_gates_harden.py` 先修掉的
  9 个门 bat，与 `sim/adv_run*.sh`、`sim/run_all_adv4.sh`、`sim/p5e_udp/run_regress.sh`、
  `tools/board_rounds_v*.sh`、`tools/board_udprx_ab.sh`）。
- **「P6b 新内容」= 其余**：`rtl/` `tb/` 的行为改动、`_proj_pcie/` 的 36 字、`board/` 的顶层与构建、
  `sim/{fifoasync,clkgen,snapseq,f4sim,f4chain,p6b_lint,p6e_pcie}/`、`tools/{f4_*,gen_f4_*,gen_stim_tx,parse_mac_rx}`。

---

## 2. 切分总览（9 条提交）

| # | 提交 | 主题 | 规模 |
|---|---|---|---|
| **C0** | `.gitignore` | 产物通用排除（xsim.dir/`*.wdb`/`*.pcap`/scratch 下 `*.memh`/`*_prj.runs/`/退役镜像） | 1 文件 |
| **C1** | `rtl/` `tb/` | **P6b 双域模块 + 四个缺陷修复**（F4/F4-2/F-2/F-1）+ 参考模型同步 | 19 文件 |
| **C2** | `_proj_pcie/` | **观测通道 36 字**（`axi_regs`/`snap_seq` 读侧位宽）+ `BUILD_ID=6` + 未实现地址 `0xB0` + 验收/冒烟脚本 | 16 文件 + 1 目录 |
| **C3** | `board/`（内容） | 顶层双域搬迁 + 两个新 XDC + `build_p6b*.tcl` + P6b 构建/时序报告 | 24 文件 + 2 目录 |
| **C4** | `sim/`（**P6b 门**）+ `tools/`（**F4 工具**） | `fifoasync` / `clkgen` / `snapseq` / `f4sim` / `f4chain` / `p6b_lint` / `p6e_pcie` + `tools/f4_*` | ~250 文件 |
| **C5** | `sim/p4gates/` | **P4 矩阵的路径硬化工具链**（`p4env.bat`/`p4gate.py`/`paths.txt`/runner + evidence 全部原始读数） | 1 目录 |
| **C6** | 硬化批（**169 个已跟踪文件**） | **把 243 个"真空门"改成自定位 + 装守卫/绊线**（`board/` `sim/` `tools/` `hls/` `p5*_verify/` `p6_verify/`） | 169 文件 |
| **C7** | 证据归档批 | `board/p6b_verify/` + `p6b_accept_final/` + 三个 scratch 目录的文本证据 + `sim/p4sim` 指纹 | 3 目录 + 3 目录 + 文件 |
| **C8** | 文档批 | `P6B_SUMMARY.md`（新）+ `P6B_SPEC/ACCEPT/CDC_AUDIT/REVIEW/INTEGRATION_REVIEW.md` + `P6E_OBS.md` + `PORT_NOTES.md` + `README.md` | 11 文件 |

**为什么 C6 单独一条**：它是**一次机械的、全仓范围的**改动（同一个守卫模式应用 169 次），
与任何功能改动无关。把它与 C1–C5 混在一起会**掩盖真正被改的行为**（评审时看不出"哪些 diff 是逻辑、
哪些只是路径"）。同时它的体量最大、风险最低，单独一条也最容易回退。

---

## 3. 逐条提交：显式清单 + 提交信息

> 下面所有路径都相对仓库根 `D:\repo\XCKU5PMini\udp_hls_10g`。
> **提交信息一律用 `git commit -F <临时文件>`**（中文多行），不要在命令行里塞多行字符串。

### C0 — `.gitignore`

**清单**：`.gitignore`

**提交信息**：
```
gitignore: 仿真/构建产物的通用排除规则 (xsim.dir / *.wdb / *.pcap / scratch 下 *.memh / *_prj.runs)

本轮盘点时仍有 209 MB 未跟踪且未被忽略的条目, 主要躺在各 agent 的临时目录
(int_scratch/ review_scratch/ audit_scratch/ p6b_final_verify/ …) 里, 主体是 xsim 的
编译目录与波形 (单个 xsimk.exe 10 MB 级) —— 历史教训是上一轮有 119 MB 仿真残渣差点进库。

改动:
- xsim.dir/ 与 *.wdb/*.vcd/*.dmp 改成**任何层级**通用规则 (此前只逐处列了 sim/ rtl/ board/ 三处,
  *_scratch/ 下的 xsim.dir/ 全部漏网);
- *.pcap 与已有的 *.pcapng/*.etl 对齐 (抓包一律不入库);
- *_scratch/**/*.memh 与 p6b_final_verify/**/*.memh (生成器可重建的激励/响应);
- *_prj.runs/ (probe/diag 目录里新建的 Vivado 工程);
- sim/*_p6b/ (已退役的镜像工具链; 规则留着防复发)。

边界 (写清以免误伤): 本段只挡"产物类扩展名"; 已入库的 .txt/.md 证据与 .bat/.tcl/.py/.sh/*.v
门驱动**不受影响**。实测确认: 0 个已跟踪文件命中本段任何一条规则, 也没有 git rm 任何东西。

**放行** (同一条提交里): 全局 `*.log` 原本会把**归档级**的原始日志也挡在库外, 现窄口径放行三个目录:
- p6b_accept_final/*.log (+*.err) —— P6b 板级验收的原始 stdout, P6B_ACCEPT.md §7.1 逐条登记了
  sha256 (cb474fbe…/cb3f13dc…);
- board/p6b_verify/*.log —— P6b 四道门的 PASS 读数;
- _proj_pcie/smoke_scratch/*.log —— 冒烟轮读数 (p6b_smoke_account.log 的 W0=270/W6=269 是
  P6B_ACCEPT.md §4.1 唯一一条独立数据)。
合计 < 80 KB。**sim/*/*.log 那一大批仍按产物排除** (读数已提练进同目录的 *.txt 判据文件)。
实测: 三个目录的 *.log/*.err 已可见; 同目录的 *.bit/*.pcap 仍被忽略 (位流/抓包按既定策略不入库)。

效果: 未跟踪且未忽略的总量 209.3 MB -> 25.2 MB。
```

### C1 — `rtl/` + `tb/`：P6b 双域模块 + 四个缺陷修复

**新增（8）**：
```
rtl/clk_gen_p6b.v     # Y1 100MHz -> MMCM x1.5625 = 156.25MHz + 复位同步器
rtl/fifo_async.v      # 灰码指针 + 两级同步的手写异步 FIFO (DEPTH=256/FWFT=1; 含占用/拒写探针)
rtl/snap_seq.v        # 链式触发快照序列器 (FE 先 -> DP 后; 36 字装配的**单一来源**映射表)
tb/tb_clk_gen_p6b.v
tb/tb_fifo_async.v
tb/tb_snap_seq.v
tb/tb_mac_rx_f4.v     # F4 的定向门
tb/tb_f4_chain.v
```
**已跟踪改动（11）**：
```
rtl/app_ctrl.v  rtl/app_pattern.v  rtl/app_status_uart.v  rtl/slow_rx_adp.v  rtl/tcp_tx_frame.v
        # P6b: `ifdef DP_156MHZ` 下的时间常数按同一墙钟重算 + 注释
rtl/fifo_sync.v        # F4(b): 新增 ovf_pulse 自检回读
rtl/mac_rx_64.v        # F4(a)+F4(b)+F4-2: full_next 空间门 + TERM 收尾字 + 4 个守恒计数器
rtl/mac_tx_64.v        # F-2: 新增 S_FLUSH (中止后一个字都不发, 吞掉本帧 TLAST 再等 IFG)
tb/tb_snap_cdc.v       # 快照束宽 NW 跟随 (24 -> 36)
tools/gen_stim_tx.py   # 参考模型同步 F-2 的 S_FLUSH (原先把缺陷当金标准 ⇒ 修完门反而变红)
tools/parse_mac_rx.py  # 判读器识别 TERM 帧 (tkeep==0 归入 partials, 拆掉"TERM 当外来帧"的地雷)
```
**边界说明**：`rtl/` 与 `tb/` **不在**路径硬化的 364 文件清单里（硬化只覆盖 `sim/ board/ tools/
p5*_verify/ p6_verify/ hls/ whs_reroll_probe/` + 3 个根 `_tmp_*.py`）⇒ **这一条是纯行为改动**，
评审时应逐行读。两个 `tools/*.py` 放这里而不是 C4，因为它们是**修复的配套**（不这样改，
F-2/F4 的门会给出错误的红/绿）。

**提交信息**：
```
P6b: 数据面搬 156.25MHz (新 clk_gen_p6b/fifo_async/snap_seq) + 四个数据通路缺陷修复

目标: 前端留 125MHz (RGMII 的 i_rxc 是 PHY 回送的, 不该改), 数据面整体搬到一个独立
自由运行的 156.25MHz 域 (核心板 Y1 100MHz 经 MMCM x1.5625), 两者之间只留两个异步边界
(RX/TX 各一个), 用新写的手写异步 FIFO 跨域 —— 这是"10G 只提时钟、流水线不改"的前置验证。

新模块:
- rtl/clk_gen_p6b.v  : IBUFDS + MMCME4_BASE (MULT=12.5/DIV=1/CLKOUT0_DIV=8 => VCO 1250MHz,
                       输出 156.25MHz) + 复位同步器 (rst_async = (~locked)|rst_ext 异步置位、
                       4 拍同步释放)。locked 只喂功能逻辑, **绝不喂 FIFO 指针**。
- rtl/fifo_async.v   : 灰码指针 + 两级同步 + FWFT, DEPTH=256。占用探针 dbg_occ_w/dbg_occ_r
                       由**已同步的**对方指针算出 (直接组合用原始灰码总线 = 多比特 CDC)。
                       含 F-1 修复: ovf_pulse/ovf_cnt —— 拒写不再静默。
- rtl/snap_seq.v     : 链式触发 (FE 先 -> DP 后)。若让主机那一个写脉冲同时打两个 snap_cdc,
                       两次锁存的先后由两个域的相位随机决定 => 跨域判据全部退化成对称容差,
                       失去方向性; 定序后 W6-W0 与 W30-W0 这类判据是**结构性**成立的。
                       偏斜上界 ~43.2ns (规格书原写的 59.2ns 是两个错误相互抵消, 见 P6B_REVIEW S2)。

四个缺陷 (两个**早于 P6b 就存在**, 由本轮审计/审查发现):
- F4(a) mac_rx_64 丢帧时若已 push 过字 => 流里留"孤儿字"(有 popc、无 TLAST):
        修法 = 补一个 TERM 收尾字 (tkeep=0/tlast=1/tcrs=0/terr=1) + term_pend 优先门。
- F4(b) 帧尾那一拍用**寄存器化的 full** 判空间 => stat_frames/stat_bytes 谎报成功, 而 TLAST 字
        被 fifo_sync 静默丢弃: 修法 = 空间门一律用 fifo_sync.full_next (下一拍满的精确预测)。
        配套: fifo_sync 加 ovf_pulse (非 0 = 静默丢失, 结构上恒 0)。
- F4-2  上面修复自身引入的: term_pend==0 时无条件进 S_TERM => 白丢下一个好帧
        (需净荷 8..15B + FIFO 无空位; 原门的帧尺寸最小 60 => 覆盖率 0, 只有独立复核抓得到)。
        修法一行: state <= first_done ? S_TERM : S_IDLE;
- F-2   mac_tx_64 帧内中止后残字被当新帧发出 => 线上出现 FCS **完全正确**的"幽灵帧",
        载荷是被中止帧的中段残字 (对端无法分辨)。修法 = 新增 S_FLUSH: 中止后一个字都不发,
        逐字弹掉输入 FIFO 直到吞掉本帧自己的 TLAST, 再等够 IFG 12 字节才回 S_IDLE。
        时序要点: 判据必须是 (frd && !fempty && fdout[0]) —— 用"上一拍看到的 tlast"会多弹一个字。

配套的工具同步 (**不改这两处, 门会给出错误的红/绿**):
- tools/gen_stim_tx.py : abort 模式的参考模型原先把 F-2 缺陷写进了期望 ("残余 2 词开新帧")
                         => 修复后 abort 门反而变红。已按 S_FLUSH 同形更新 (main 模式逐字节不变)。
- tools/parse_mac_rx.py: 原先把任何不在期望集里的帧判成"外来帧" => TERM 帧一发出就会假 FAIL
                         (P6B_REVIEW R.5 标为"尚未引爆的地雷")。已按末字 tkeep==0 把 TERM 帧
                         归入 partials, **计数约束不放松**。

判据归属 (证据):
- F4   : W32/W33/W34/W35 (新计数器) + 结构式 W30==W0+W32 / W31==W1-4*W0+W33。见 sim/f4sim/、sim/f4chain/、
         P6B_REVIEW.md §3.4 与附录 R (含"撤回修复即 FAIL"的负对照)。
- F4-2 : P6B_REVIEW.md R.4 的 A/B (同一激励: 修复前 frames=1 drop=2 -> 修复后 frames=2 drop=1)。
- F-2  : audit_scratch/t3_txcdc/ —— 幽灵帧 0; 撤回修复 => FAIL; 无中止路径指纹逐位不变
         (33f82978 修前/修后相同 + flush 计数器为 0 = 冲刷从未运行的正证据)。
- F-1  : sim/fifoasync/ 12 门 + 7 变异; 关键负对照 run_mut_noovf.bat (撤回探针) 实测 FAIL(3 条)。

未修 (如实记录): F-3 (MMCM 失锁重锁时 FIFO 指针保留而 DP 功能逻辑重启 => 交付"帧中截断但
tcrs=1"的片段)。三种接线实测都无解 (只复位读侧更糟: 把已消费的整帧重新投递);
根因 = DP 侧没有"以 SOP 为界"的重启重同步。收口方向见 P6B_CDC_AUDIT.md §A.3, 建议单列任务。
```

### C2 — `_proj_pcie/`：观测通道 36 字 + 验收/冒烟

**已跟踪改动（10）**：
```
_proj_pcie/rtl/axi_regs.v        # 36 字: snap_idx 5->6 位, snap_base 10->11 位 (不加宽 = 静默回绕成 W0.. = 假 PASS)
_proj_pcie/tb/tb_axi_regs.v      # 单元门跟随 (SNAP_NW / snap_din 位宽 / w8 长度)
_proj_pcie/p6e_snap_check.sh     # EXPECT_BID=6 / 地址表扩到 0xAC / 未实现地址 0xB0 / W17 除数 80
_proj_pcie/p6e_slowpath_probe.sh # 读地址表补 8 个字
_proj_pcie/p6e_boot_timeline.sh  # 注释里的未实现地址
_proj_pcie/p6e_capture.sh        # 地址表
_proj_pcie/p6e_watch.sh          # 地址表 + 注释
_proj_pcie/p6e_precheck.sh       # BUILD_ID 注释
_proj_pcie/xelab_axr.log         # 上面那道门的 xelab/xsim 原始输出 (跟踪的日志, 是证据)
_proj_pcie/xsim_axr.log
```
**新增（6 + 1 目录）**：
```
_proj_pcie/p6b_accept.sh        # 板级验收脚本 (rd()/rd_new()/snap()/round() 四层守卫)
_proj_pcie/p6b_smoke_account.sh
_proj_pcie/p6b_smoke_gate.sh
_proj_pcie/p6b_smoke_program.tcl
_proj_pcie/run_program_p6b_smoke.bat
_proj_pcie/smoke_scratch/       # 目录级 add: 里面 *.bit / *.pcap 已被忽略, 入库的是日志与 verify 脚本
                                # ⚠️ 入库前确认 verify_pcap_pattern.py 也在里面 (它是 D3 的独立验证器)
```
**提交信息**：
```
P6e/P6b 观测通道: 快照窗口 24 -> 36 字 (BUILD_ID=6) + 读数脚本跟随 + 板级验收脚本

- _proj_pcie/rtl/axi_regs.v: 36 字需要**同时**加宽 snap_idx (5->6) 与 snap_base (10->11)
  —— 只加宽一处会让 0xA0..0xAC 静默回绕读回 W0..W3 = **假 PASS 而不是 FAIL**
  (P6B_REVIEW.md 附录 R.5 预先算出了这条硬顶; 审查方另写了独立门 int_scratch/tb_int_axr36.v
   + 两条回绕负对照, 都实测 FAIL)。
- 新增字: W26..W31 (两个异步 FIFO 的满拍/占用峰值/DP 等线/RX 侧读帧与读字节) 与
  W32..W35 (F4 的四个丢帧守恒计数器, 全部属 FE 束)。域归属与生产者节点逐字核对见
  P6B_INTEGRATION_REVIEW.md §1.3; 现役寄存器表 = P6E_OBS.md §一。
- 未实现地址 0x84 -> **0xB0** (word 44); BUILD_ID 期望 4 -> **6**;
  W17 的口径 ÷64 -> **÷80** (P6b 把 slow_rx_adp.RST_CNT 由 64 改 80, 同一墙钟 512ns)。
- 读数脚本加了四层守卫 (空读 != 真 0 / 0xffffffff 视为未实现 / **gen 恰好 +1 自证** / round() 三合一)。
  最后一条是本轮实测逼出来的: 快照 done 是 sticky 的, **并发读者会互相污染读数**, 且
  "读失败被 $(( )) 当成 0" 会静默伪造出"计数冻结"的结论 (真凶是脚本自己的变量名撞车)。

判据: sim/p6e_pcie/run_tb_p6e_pcie.bat = 34 字 force 成互不相同的常数后逐字读回 +
W24/W25 的动态判据 + 0xB0 边界; int_scratch/tb_int_axr36.v 为审查方独立复现 (reads=44)。
```

### C3 — `board/`：顶层双域 + 约束 + 构建

**已跟踪改动（3）**：
```
board/wrapper_p4.v        # 域搬迁 + 两个 CDC FIFO 例化 + 36 字快照 + 8 处时间常数 (全部在 ifdef 内)
board/uart_dbg.v          # BIT_LAST/GAP_LAST 按 156.25MHz 重算 (同一墙钟)
board/build_p6e_ku5p.tcl  # 文件头声明"已被 P6b 取代" + 同步补齐 3 个新 RTL 与 2 个新 XDC
```
**新增（24 + 2 目录）**：
```
board/build_p6b_ku5p.tcl           board/run_build_p6b_ku5p.bat
board/build_p6b_final_ku5p.tcl     board/run_build_p6b_final_ku5p.bat
board/ku5p_p6b_sysclk.xdc          # Y1 100MHz 输入
board/ku5p_p6b_cdc.xdc             # set_clock_groups (impl-only: 综合前 create_clock 还没生效)
board/check_p6b_timing.py          # 时序闸 (带正/负对照)
board/p6b_extra_reports.tcl        board/p6b_final_extra_reports.tcl   board/run_p6b_extra_reports.bat
board/p6b_final_ku5p_{timing,util,drc,clocks,cdc}.rpt   board/p6b_final_ku5p_hold_400.rpt
board/p6b_final_ku5p_{failing_endpoints.txt,lutram.txt,async_reg.txt}
board/p6b_ku5p_{timing,util,drc,clocks}.rpt   board/p6b_ku5p_hold_400.rpt
board/p6b_ku5p_failing_endpoints.txt
board/p6b_verify/                  # 目录级 add (板级门/path 对照/时序闸负对照的读数)
board/ku5p_probe/clkgen_p6b/       # 目录级 add (MMCM 预言机与引脚探针: *.xci/*.py/*.tcl/*.rpt/*.txt/*.png)
```
**边界说明**：`board/wrapper_p4.v` / `board/uart_dbg.v` / `board/build_p6e_ku5p.tcl` **不在**硬化清单里
⇒ 纯 P6b 内容。`board/` 里那 30 个 `build_*.tcl` / `program*.tcl` / `run_*.bat` / `timing_p5.tcl`
**是纯硬化**，归 **C6** 而不是这里 —— 这是本方案最重要的一条边界。
⚠️ `board/p6b_verify/` 里的 `*.log` 与 `*.txt` 是**证据**，不要因为"日志"就跳过；
若要控制在库体积，至少保留 `*_timing.dual.txt` / `*.pass.log` / `CONTROLS.txt` / `p4_matrix_local_repo.log`。

**提交信息**：
```
board: P6b 顶层双域搬迁 + 两个新 XDC + build_p6b 构建档 (含冻结版) + 板级读数归档

- board/wrapper_p4.v: 前端 (mac_rx_64/mac_tx_64 及其统计) 留 gmii_clk; 其余全部 gmii_clk -> dp_clk;
  两个新的异步边界 u_rxcdc/u_txcdc (fifo_async 76/256/FWFT=1 与 73/256/FWFT=1);
  快照拆成两束 (SNAP_FE_NW=14 / SNAP_DP_NW=22 / SNAP_NW_P6E=36) 交给 snap_seq 链式触发;
  8 处时间常数按同一墙钟重算 (RST_CNT 64->80、RTO_LIM、FIN_TO_LIM、GAP_TICKS、ACT_TMR_INIT、
  WDOG、BIT_LAST、UART_SW...), 逐条独立复算见 P6B_INTEGRATION_REVIEW.md §2 (误差 0 的 11 条,
  两条是 x1.25 除不尽的取整, 量级 1e-6)。
  ⚠️ 双域与全部新硬件都包在 `ifdef PCIE_OBS` 内 —— 这让 PCIE_OBS 变成"数据面跑 156.25MHz"的
  守卫 (语义复用, 已知设计债, P6B_REVIEW F1); 默认构建 (K7 各档) 的端口表与逻辑逐位不变。
  ⚠️ 例外: 同批并入的 F4 修复改了 rtl/mac_rx_64.v 的 82 行**不在任何 ifdef 内**的代码
  ⇒ "默认构建逐位不变"**作为一句话是不成立的**, 见 G4。

- board/ku5p_p6b_sysclk.xdc : Y1 100MHz 输入 (原理图实测出图, 见 P6B_SPEC §8.2)。
- board/ku5p_p6b_cdc.xdc    : set_clock_groups -asynchronous (三个域物理源互不相同)。
  ⚠️ 必须 used_in_synthesis=false: 综合前 create_clock 还没生效、XDMA/MMCM 还是黑盒 =>
  get_clocks 拿到空对象 => Vivado 报 12-4739 并**静默丢弃**该约束 (本工程实测踩过)。

- 冻结构建 = build_p6b_final_ku5p.tcl (多出三项工具侧读数: report_cdc / ASYNC_REG 普查 /
  hold 三族专核), 产物 = p6b_final_ku5p_prj。**板级验收的位流就是它**:
  sha256 c17700868b08170865f4a4ae0292ebb636aed03070e2875f6dbb005123a948ca, WNS +0.168 / 0 失败端点。
- board/check_p6b_timing.py 的判别力自证 = board/p6b_verify/CONTROLS.txt: **13/13** 正/负样本
  符合期望 (含 5 个人造病理报告)。**没跑这组对照之前不许说"闸有区分能力"。**

- board/ku5p_probe/clkgen_p6b/ 是 clk_wiz MMCM 预言机与引脚探针的原始读数 (含 cw_oracle.xci),
  是 P6B_SPEC §8.2 (Y1 频率核实) 与 B1 (DIFF_POD12_DCI 可布性) 的证据, 不是仿真残渣。
```

### C4 — `sim/`（P6b 门）+ `tools/`（F4 工具）

**目录级 add（每个目录都同质，目录内的 `.wdb/.jou/.log/xsim.dir/` 已被忽略）**：
```
sim/fifoasync/   # rtl/fifo_async.v 单元门: 12 基础门 + 7 变异 (含 mut_noovf = F-1 的负对照)
sim/clkgen/      # clk_gen_p6b 单元门 (含"改错 MULT_F 就真的跑错频率"的负对照)
sim/snapseq/     # snap_seq 链式触发门
sim/f4sim/       # F4 的 A/B/C 与变异 (VERDICT_*.txt 是判据输出)
sim/f4chain/     # F4 整链门 (含 mut_termcrs 变异 RTL 与 rd_* 读数)
sim/p6b_lint/    # P6b 的 lint 文件清单与 bat
sim/p4sim/       # ⚠️ 只 add 这几个: run_tb_p4_*_xk.bat (4 个) + run_tb_vlan_strip_xk.bat 见 §4.2
                 #    + P4_MATRIX_FINGERPRINT_*.txt / matrix_p4dfix.log (**等矩阵跑完**)
```
**已跟踪改动（2）**：
```
sim/p6e_pcie/run_tb_p6e_pcie.bat          # 加 -d P6B_SIM_CLKGEN; 加 -d 才能旁路真 MMCM
sim/p6e_pcie/tb_p6e_pcie_wrapper.v        # 36 字 (force 34 路 + W24/W25 动态判据) + BUILD_ID=6
sim/p6e_pcie/tb_p6e_pcie_counters.v       # 新计数器增量门 (W16/W17 + W26..W31)
sim/p6e_pcie/run_tb_p6e_pcie_counters.bat
```
**新增工具（3）**：
```
tools/gen_f4_stim.py   tools/gen_f4_chain.py   tools/f4_ab_check.py
```
**提交信息**：
```
sim/tools: P6b 的门与工具 —— fifo_async / clk_gen_p6b / snap_seq / F4 全链 / 36 字全链

门与它们各自的"负对照" (判据的牙):
- sim/fifoasync/   : 12 基础门 + 7 变异。关键负对照 mut_noovf (把 ovf_pulse 钉 0 = 撤回 F-1 修复)
                     实测 FAIL(3 条判据) —— 这就是"拒写不再静默"这条合同的牙。
                     另有三条探针判据: 占用峰值 >= 金标准真实峰值 / 探针非空 (不是恒 0 的未连接线)
                     / 硬界 (占用永不 > DEPTH)。
- sim/clkgen/      : 时钟发生器门, 含"把 MULT_F 改错就真的跑错频率"的负对照 (否则门测不出参数抄错)。
- sim/snapseq/     : 链式触发的顺序门 (FE 先 -> DP 后)。
- sim/f4sim/       : F4 的 A/B/C + 变异。证据非空自检 (checks>0) 是硬要求。
- sim/f4chain/     : F4 整链 (含 mut_termcrs 变异: 撤回 TERM 收尾字 => 幽灵字回来 => FAIL)。
- sim/p6e_pcie/    : **36 字全链门** —— 34 个字 force 成互不相同的常数后逐字读回 (force 必须打
                     **生产者节点**: 打 wrapper 的线会掩盖"生产者<->线断开", 实测把 mac_tx_frames
                     改回悬空时打线版照样 PASS_ALL); W24/W25 不能用 force (自由计数/MMCM locked)
                     => 改用动态判据 ΔW24/ΔW5 = 1.2501 与 locked==1; 另查 0xB0 -> SLVERR 与 gen 恰好 +1。
                     新计数器增量门补动态那一段 (200 拍握手 => W16 恰好 +200; 150 拍 hls_rst_n 低
                     => W17 恰好 +150; 含 tvalid-only / tready-only 负向)。
- tools/gen_f4_*.py / f4_ab_check.py: F4 的激励生成与 A/B 判读 (判据的期望由它们生成)。

⚠️ 已知的判据缺口 (如实记录, 见 P6B_REVIEW R.4): 修复方自己的 gen_f4_stim.py 帧尺寸最小 = 60
=> "净荷 8..15B + FIFO 无空位"那一支覆盖率 0 => F4-2 这个"修复引入的缺陷"原门永远测不到,
是**独立复核**抓到的。**同一个 agent 既写门又写修复 = 判据缺口的结构性来源。**
```

### C5 — `sim/p4gates/`：P4 矩阵的路径硬化工具链

**清单**：
```
sim/p4gates/            # 目录级 add。入库: p4env.bat / p4gate.py / paths.txt / run_matrix_p4dfix.bat
                        #   / *_src.f / evidence/**  (work_*/ 与 evidence/negctl/ 已被忽略)
```
**提交信息**：
```
sim/p4gates: P4 默认构建回归矩阵的路径硬化层 (自定位 + 三层守卫 + 修订指纹) + 全部原始读数

背景 (本轮最贵的一条元问题): 全仓 **364 个代码文件**的活行里含指向 D:/repo/ECO/udp_hls_10g 的
绝对路径, 其中 **243 个是"真空门"** —— 跑起来编译的是**另一个 checkout** 的源码、日志写进
**另一个 checkout** 的仓, 然后 exit 0。本仓 2026-09-28 从那里整体拷贝来, 拷贝之后全部退化成空门。

本层: 工具 (paths.txt 是路径单一来源; p4env.bat 从**脚本自身位置**推导 REPO_ROOT; p4gate.py 提供
guard / checkpaths / manifestcheck / scanlog / fingerprint 五个子命令) + runner (16 门, 门清单与
manifest 声明一次) + evidence (全部原始读数)。

守卫三层 + 一层事后扫描 + 一条绑定:
  1 guard      : 配置的根必须包含本 checkout (REQUIRED_MARKERS 逐项列出缺哪个文件) —— 拒绝"跑别人"
  2 checkpaths : 每个门 xvlog 之前, 任何路径/manifest 条目解析到根外或不存在 => 拒绝
  3 selfcheck  : (装在 243 个门 bat 头部) 该 bat 的**活行**若指向仓外 => 拒绝运行
  4 scanlog    : 每个门跑完后, 编译/仿真日志里出现根外绝对路径 => 硬失败
  - fingerprint: 跑前+跑后对 235 个文件 (编译集+生成器+bats) 逐字节比对; 期间源码被改动 =>
                 REVISION DRIFT 并**作废整轮** (本轮实测: 编辑与矩阵跑重叠 => 整轮无效)

**负对照 (证明守卫有牙, 也是"批量装守卫前必须先跑负对照"这条纪律的来源)**:
evidence/negctl/ 里放了外仓替身夹具 (foreign = 工具链副本 + 某个门故意重新硬编码 ECO 路径;
notarepo = 只做根目录)。原始读数:
  A1 根配成 D:\repo\ECO\udp_hls_10g => [P4GUARD FAIL] REFUSING ... 'empty gate' mode, RC=1
  A2 根配成父目录                  => 列出 7 个缺失 marker 后 FAIL
  B  门自己重新硬编码              => 被拦下, EXIT=97
=> **不装守卫的话这些都会 exit 0。**

⚠️ **"跑门 != 判门"**: 16 门里有 2 门 (unit_retx / unit_fifo) **无条件 exit 0**
(它们的 bat 以 `type xsim*.log` 结尾) => "16 门 EXIT=0" **不等于** "16 条判据被判定过"。
runner 头部注释已写明这一点, 任何自动化汇总都必须显式处理。

⚠️ **当前状态 (诚实版)**: 11:46 的首次全跑因 REVISION DRIFT 整轮作废 (两个门 EXIT=1 是**并发产物**,
单独重跑 RC=0, 见 evidence/canonical_{stallgate,vlanburst}.txt); 12:07 那一轮通过了 freeze 检查
(VERDICT: FROZEN, 235 文件逐字节相同, 绑定 DIGEST_ALL(content)=921d62d9…)。
**13:21 起的"无并发"复跑仍在飞行中** —— 它的结论由跑它的那个 agent 出, 本提交不替它下结论。
```

### C6 — 硬化批：**169 个已跟踪文件**

**精确清单的生成方式**（提交时现算，避免手抄漏项）：
```bash
# ① 硬化清单里的 tracked-FIXED 行 (150 个)
awk '$2=="TRACKED" && $0 ~ /FIXED\(/ {print $1}' sim/p4gates/evidence/inventory_eco_class.txt | sort > /tmp/h1
# ② 清单外但确实被装了守卫/自定位的 20 个 (见 §4.1 的逐条理由)
printf '%s\n' \
  board/build_p4.tcl board/build_p5.tcl board/build_p5_diag.tcl board/build_p5_holdfix.tcl \
  board/build_p5a0.tcl board/build_p6_t6p4.tcl board/build_p6_t8p0.tcl \
  board/program.tcl board/program_echo.tcl board/program_p4.tcl board/program_tcp.tcl \
  board/run_build.bat board/run_build_echo.bat board/run_build_p4.bat board/run_build_p5.bat \
  board/run_build_p5_diag.bat board/run_build_p5a0.bat board/run_build_p6_t6p4.bat \
  board/run_build_p6_t8p0.bat board/run_build_tcp.bat board/run_program.bat \
  board/run_program_echo.bat board/run_program_p4.bat board/run_program_p5.bat \
  board/run_program_p5_diag.bat board/run_program_p5_keep.bat board/run_program_p5a0.bat \
  board/run_program_tcp.bat board/run_sysmon.bat board/run_timing_p5.bat board/timing_p5.tcl \
  hls/run_hls.bat hls/run_hls_active.bat hls/run_hls_active_board.bat \
  p5e_verify/cone_rank_p5e.tcl p5e_verify/hier_util_p5e.tcl p5e_verify/inst_check_p5e.tcl \
  p5e_verify/verify_p5e.tcl p5f_verify/*.tcl p6_verify/*.tcl p6_verify/run_p6_*.bat p6_verify/p6_report.py \
  sim/adv_run4.sh sim/adv_run5.sh sim/adv_run6.sh sim/adv_run_case.sh sim/run_all_adv4.sh \
  sim/p5e_udp/run_regress.sh \
  sim/p4sim/run_tb_p4_burst.bat sim/p4sim/run_tb_p4_burst_vlan.bat sim/p4sim/run_tb_p4_chain.bat \
  sim/p4sim/run_tb_p4_chain_stall.bat sim/p4sim/run_tb_p4_chain_vlan.bat \
  sim/retxsim/run_retx_tb.bat sim/vlansim/run_tb_vlan_strip.bat sim/tbgate/run_tb_uart_dbg.bat \
  tools/board_rounds_v4_batch.sh tools/board_rounds_v5_batch.sh tools/board_rounds_v6_batch.sh \
  tools/board_rounds_v7_batch.sh tools/board_udprx_ab.sh > /tmp/h2
```
> ⚠️ **执行 C6 时不要照抄上面的字面清单**（它是"当时状态"的快照）；用 §6 的命令现算，
> 再与 `git status --porcelain` 里实际改动的文件取交集，**逐个确认 diff 只与路径有关**
> （检查法见 §3 末尾"硬化 diff 的验收判据"）。

**更大的一批在同质目录里**（同样只含路径改动，可用目录级 add）：
```
sim/p3sim/  sim/echosim/  sim/rxsim/  sim/txsim/  sim/udprx/  sim/udprx_chain/  sim/rxpdiag/
sim/p5sim/  sim/p5b_acc2/ sim/p5b_adv/ sim/p5b_ind2/ sim/p5b_ind3/ sim/p5c_t3/ sim/p5c_t4/
sim/p5c_t4reg/ sim/p5c_t5/ sim/p5close/ sim/p5d_d1/ sim/p5d_multi/ sim/p5dx_d6/ sim/p5e_pre/
sim/p5e_rate/ sim/p5e_t2/ sim/p5e_udp/ sim/p5e_win/ sim/p5udp/ sim/snapcdc/ sim/p4sim_hlsprobe/
tools/  hls/  （只 add 上面清单里点名的那几个文件与 *.sh）
```
> **不要** `git add sim/`（会把 C4 的新门目录一起吞进来，破坏分层）。

**硬化 diff 的验收判据**（`git add` 之前先跑一次）：
```bash
# 该文件的 diff 里除了路径/守卫相关行, 不应有别的增删
git diff -- <file> | grep -E '^[+-]' | grep -vE '^[+-]{3}' \
  | grep -viE 'ECO|REPO_ROOT|P4GATE|P4ENV|checkpaths|selfcheck|PATHGUARD|%~dp0|P4_WORKDIR|set (PY|XV|HLS|RTL|TB)=|cd /d|usage|Git Bash|^[+-]\s*(rem|REM|#|@echo)' \
  | head
# 期望: 只剩"用 %TOOLS%/%CD% 替代绝对路径"这类行
```

**提交信息**：
```
路径硬化: 243 个"真空门"改成自定位 + 装三层守卫 (169 个已跟踪文件)

问题: 全仓 364 个代码文件的活行里含 D:/repo/ECO/udp_hls_10g 的绝对路径。本仓 2026-09-28 从
那里整体拷贝来 => 拷贝之后**照抄那些命令 = 编译另一个 checkout 的源码、日志写进另一个仓、
然后 exit 0**（"empty gate"）。这不是假设: 提交 a31c86b 的"P4 矩阵 16 门全过"就是这么跑出来的
（物证 = ECO 仓里那份 03:58-04:23 的 matrix 日志, 且其中 frame_fifo.v 比本仓还旧一版,
真正需要回归的 4 个文件根本没进那次运行）—— 勘误详见 PORT_NOTES.md 的 P6b 收口 §⑥。

修法 (本提交只含**路径相关**的机械改动, 不含任何行为改动):
- 门 bat/sh: 开头统一 `call "%~dp0..\p4gates\p4env.bat"`（REPO_ROOT 从脚本自身位置推导）
  + checkpaths 预检 + selfcheck 绊线; 所有仓库内路径改从 REPO_ROOT/TOOLS/TB/RTL/... 展开;
- 去掉 bat 里自己 `set PY=/set XV=/set HLS=<绝对路径>` 的写法（工具链位置集中在 paths.txt）;
- 校验: 本批 169 个文件的 diff 逐条过了一遍"只与路径有关"的过滤 (见 P6B_COMMIT_PLAN §3 的判据),
  且 P4 矩阵的 16 门在硬化后**跑通**（含两个门单独重跑 RC=0 与一轮 FROZEN 修订绑定）。

未修: 23 个（Python(手工) 类为主, 含 tools/capture_rate_test.ps1）—— 逐条清单与原因见
sim/p4gates/evidence/inventory_eco_class.txt 的 NOT FIXED 行。已知的一个活地雷:
sim/run_tb_tx.bat 仍 cd 到 ECO 仓（audit_scratch/regress_mactx.py 用自定位绕过了它）。

配套的负对照在 sim/p4gates（C5）: negctl_A/B 实测 RC=1 / EXIT=97, 不装守卫则全是 exit 0。
```

### C7 — 证据归档批

**清单**：
```
board/p6b_verify/     # 板级门读数 + 时序闸负对照 + CONTROLS.txt + p4_matrix_local_repo.log
                      #   (*.log 已由 .gitignore 放行 ⇒ 会入库; *.rpt 本来就是跟踪的)
p6b_accept_final/     # **验收归档**: 位流(*.bit)与抓包(*.pcap)仍被忽略(既定策略),
                      #   *.log/*.err 已放行 ⇒ 入库的是脚本 + 全部原始日志
int_scratch/          # 审查方独立门 (tb_int_axr36.v / tb_int_snapseq.v) + 回绕负对照
review_scratch/       # 对抗审查的原始读数与变异体 (F4 复核附录 R 的 A/B 读数在这里)
audit_scratch/        # 跨域审计的门 + 原始读数 + rtl_orig/ 与 tools_orig/ 的**撤回对照副本**
sim/p4sim/P4_MATRIX_FINGERPRINT_*.txt   # ⚠️ 等矩阵跑完
sim/p4sim/matrix_p4dfix.log             # ⚠️ 等矩阵跑完
```
> ⚠️ 三个 scratch 目录里的原始 **xsim 控制台日志 (`*.log`) 仍被排除**（读数已提练进同目录的
> `*.txt` 判据文件）。若 TL 认为审计/审查的 `.log` 也该入库（`P6B_CDC_AUDIT.md` §8 的证据索引
> 指向 `t1_bits/case_*/xsim_*.log`），加一行 `!audit_scratch/**/*.log` 即可 ——
> **这是刻意的窄口径选择，不是遗漏**（audit_scratch 的 `.log` 合计 1.8 MB，review 0.17 MB，int 0.3 MB）。
**提交信息**：
```
证据归档: P6b 的审查/审计/验收原始读数 (不转述, 只存原件)

本仓的存档策略是"**文本证据入库**"（读数、判据输出、负对照原始 stdout），产物（波形/位流/抓包/
xsim.dir）不入库。这次归档三类:

1 board/p6b_verify/ + p6b_accept_final/
  板级验收的原始日志与脚本（位流**不入库** —— 项目既定策略不跟踪位流, sha256 记在 P6B_ACCEPT.md §1.1）。
  注意: 冒烟轮烧的是**过期位流** 03f9c6d0…fe5a0d（不含 F-1/F-2）, 引用它的数字必须注明这一点。

2 audit_scratch/ review_scratch/ int_scratch/
  三个独立 agent（跨域审计 / 对抗审查 / 集成审查）的门与原始读数, 含:
  - audit_scratch/rtl_orig/mac_tx_64.v 与 tools_orig/gen_stim_tx.py: **撤回修复用的对照副本**
    （"撤回修复即 FAIL"这条负对照靠它复现）;
  - review_scratch/_sec_R.md 与附录 R 的 A/B 读数（F4-2 就是在这里被抓到的）;
  - int_scratch/tb_int_axr36.v + neg5/ + negbase/: 36 字读回门与**两条回绕负对照**。
  这些目录里的 xsim.dir/ *.wdb *.memh 已被 .gitignore 排除。

3 sim/p4sim 的指纹与矩阵日志（受 ! 规则放行入库）—— 它们是"这一轮跑的是哪个修订"的绑定物。
```

### C8 — 文档批

**清单**：
```
P6B_SUMMARY.md          （新, 一页式总览: 目标/改了什么/关键数字/证据地图/已知限制）
P6B_SPEC.md             （+§0.4 勘误: §7.2 索引表错误、36 字最终映射、as-built 偏离; 错误处加行内标注）
P6B_ACCEPT.md           （新, 板级验收原件）
P6B_CDC_AUDIT.md        （新, 跨域审计 + F-1/F-2/F-3 + F-2 修复记录 + gen_stim_tx 同步）
P6B_REVIEW.md           （新, 对抗审查 F1-F13 + 附录 R）
P6B_INTEGRATION_REVIEW.md（新, 36 字逐字验证 + 空门核实）
P6E_OBS.md              （36 字寄存器表 + 判据变更 + P6b 板级读数; 现役表）
PORT_NOTES.md           （+2026-09-29 P6b 收口里程碑日志 + 三条教训）
README.md               （P6b 状态块 + 验证节的"空门"警示 + u_dbg_line 注）
```
**提交信息**：
```
docs: P6b 归档 —— 一页式总览 + 规格勘误 + 验收原件 + 36 字寄存器表 + 里程碑日志

- P6B_SUMMARY.md (新): 一页式总览。**未来的 session 从这里接手** (5 分钟):
  目标 / 改了什么(按文件层) / 关键数字(每条附出处) / 证据地图(哪个结论在哪个文件) /
  已知限制与未覆盖 / 三条操作纪律 / 板子当前状态。
- P6B_SPEC.md: 加 §0.4 勘误 (正文不改, 保留"当时的判断"), 说明
  ① §7.2 的 FE_IDX/DP_IDX 与它自己的 32 行对照表矛盾 (FE_IDX 把 fe[8]/fe[9] 写在下标 24/25,
     DP_IDX 在 W26..W31 整体错位两个槽) —— **以对照表为准**, 并给出**最终采用的 36 字表 + 两张索引表**
     (来源: 集成 agent 从 wrapper 拼接逐项读出 + 审查方独立写死 36 行映射表复核 + 落地代码的单来源 function);
  ② 同批的其它 as-built 偏离 (32->36 字 / BUILD_ID 5->6 / 未实现地址 0xA0->0xB0 / W28 用 dbg_occ_w /
     WIDTH 77 vs 76 / ÷80 清单漏 5 处 / W19 不再恒 0);
  在 §7.2/§7.4/§7.5 的错误处加指向 §0.4 的行内标注。
- P6E_OBS.md: 快照表 16->**36 字**(地址+域归属+生产者节点) + BUILD_ID=6 + 未实现地址 0xB0 +
  **判据变更**一节 (W20-W7 且 W21==0 / W0-W6 方向校正 / W17÷80 / W19 与 MAC 丢帧有向耦合 /
  结构式守恒 W30==W0+W32 与 W31==W1-4*W0+W33) + 扩窗清单(7 处) + F-1 的板级缺口如实记录。
- PORT_NOTES.md: 追加 P6b 收口里程碑 —— 验收读数 / 四个修复的一句话根因+修法+判据归属 /
  **F-3 已知限制(三种接线实测都无解)** / **"空门"元问题(364 文件、243 真空门、340 已修、23 未修、
  守卫三层+负对照)** / 提交 a31c86b 的**勘误** / 冒烟轮取自过期位流的注明 /
  u_dbg_line 的 48 位无同步穿越 / 三条教训("跑门!=判门"、"并发 agent 文件所有权必须互斥"、
  "批量装守卫前必须先跑负对照")。
- README.md: 加 P6b 状态块指向 P6B_SUMMARY/P6B_ACCEPT; **在"验证"一节顶部加"空门"警示**
  (那一节里的 D:\repo\ECO\... 命令是空门形态, 并给出自定位的现役跑法);
  给 uart 诊断行的 48 位无同步穿越加注 (本板无 UART => 不可观测)。
```

---

## 4. 边界处理（**本节是"必须读"**）

### 4.1 混装文件：同一份 diff 里既有硬化又有新内容

**结论：本次不存在"同一份 diff 混装"的文件。** 核验方法（可复跑）：
```bash
awk '{print $1}' sim/p4gates/evidence/inventory_eco_class.txt | sort > /tmp/inv.txt
git status --porcelain=v1 | grep '^ M' | sed 's/^ M //' | sort > /tmp/mod.txt
comm -12 /tmp/inv.txt /tmp/mod.txt        # 150 个: 既在硬化清单里又被改动
comm -23 /tmp/mod.txt /tmp/inv.txt        # 51 个: 被改动但不在硬化清单里
```
- **150 个交集**：我逐个抽查了 diff，**只含路径相关行**（最典型的是 `sim/p4sim/run_tb_p4_burst.bat`：
  `git diff | grep -v <路径过滤>` 之后只剩两行 `"%PY%" "%TOOLS%\gen_stim_p4_chain.py" "%CD%" …`，
  即"把绝对路径换成变量"）。
- **51 个差集**里需要**单独交代**的只有 20 个（其余 31 个是 `_proj_pcie/` `rtl/` `tb/` 与
  `sim/p6e_pcie/` 等**纯新内容**文件，已归 C1/C2/C4）：

| 文件（组） | 为什么不在硬化清单里 | 归到哪一类 | 理由 |
|---|---|---|---|
| `sim/p4sim/run_tb_p4_{burst,burst_vlan,chain,chain_stall,chain_vlan}.bat` | 它们由**更早的**迁移脚本 `_tmp_p4_gates_harden.py` 先修掉了，之后那次全仓扫描看到的已经是"无 ECO 路径"的版本，故未被 classify | **C6 硬化批** | diff 逐行核过: 只有 prologue/deroot/路径变量化 |
| `sim/retxsim/run_retx_tb.bat` · `sim/vlansim/run_tb_vlan_strip.bat` · `sim/tbgate/run_tb_uart_dbg.bat` | 同上（同属那 9 个） | **C6** | 同上 |
| `sim/adv_run[456].sh` · `sim/adv_run_case.sh` · `sim/run_all_adv4.sh` · `sim/p5e_udp/run_regress.sh` | 含 `P4GUARD`/`checkpaths`（被 tripwire 批处理覆盖，但不在 ECO-class 表里） | **C6** | 同上 |
| `tools/board_rounds_v[4567]_batch.sh` · `tools/board_udprx_ab.sh` | 同上 | **C6** | 同上 |
| `board/build_p6e_ku5p.tcl` | 它**同时**含 P6b 内容（补齐 3 个新 RTL + 2 个新 XDC）**和**硬化？→ **实测：不含守卫**，它不在 hardening 清单里；改动是 P6b 的文件清单补齐 | **C3** | 逐行核过 diff: 只有文件清单与文件头声明 |
| `board/wrapper_p4.v` · `board/uart_dbg.v` | 不在 hardening 清单（没被装守卫） | **C3** | 纯 P6b 行为 |

> ⚠️ **我给出的判据**：判"这条 diff 是硬化还是内容"的**唯一可靠方法**是那句 grep 过滤（§3 C6 末尾），
> **不是**看文件在不在 `inventory_eco_class.txt` 里 —— 后者是**某一次扫描的快照**，
> 早于它的改动（那 9 个门）与晚于它的改动都不在里面。

### 4.2 建议**不提交**（留在盘上）的东西，与理由

| 对象 | 处置 | 理由 |
|---|---|---|
| `_tmp_*.py`（11 个：`_tmp_path_fix.py` / `_tmp_tripwire.py` / `_tmp_inventory.py` / `_tmp_p4_sweep*.py` / `_tmp_p4_bats_finalize.py` / `_tmp_fix_trailing_bs.py` / `_tmp_pgtest.py` / `_tmp_gate_md5.py` / `_tmp_p4_gates_harden.py` / `_tmp_p4_negctl.py`） | **不提交**（留盘） | `_tmp_` 前缀 = 一次性脚本；其中多数**含未修的 ECO 路径**（属"23 未修"）⇒ 入库会把"含 ECO 路径"固化进历史。**但** `_tmp_p4_gates_harden.py` / `_tmp_p4_negctl.py` / `_tmp_tripwire.py` 是硬化过程的生成器 ⇒ **若 TL 想让它可复现，建议改名移到 `sim/p4gates/tools/` 再入库**（去掉 `_tmp_` 前缀、顺手修那几行 ECO 路径）；**该移动超出本次授权，我没有做。** |
| `sim/p4sim/run_tb_*_xk.bat`（4 个）· `sim/vlansim/run_tb_vlan_strip_xk.bat` | **建议提交**（放 C4） | 它们是镜像期的**更早一版绕道**（把 ECO 路径换成**本仓硬编码**路径），现在已被自定位原件取代 ⇒ 功能上冗余。**但** `sim/p4gates/paths.txt` 的 `FINGERPRINT_GLOBS` 里有 `sim\p4sim\run_tb_*.bat` ⇒ 它们**已被纳入每次矩阵指纹的哈希**；不提交 ⇒ 别人 checkout 后复现不出那个 `DIGEST_ALL`。**这条我拿不准**，所以：要么提交（保守），要么**先**改 `FINGERPRINT_GLOBS` 再删（需要再跑一轮矩阵作废指纹）⇒ **建议留给 TL 决定**。 |
| `board/ku5p_probe/clkgen_p6b/prj_clkwiz/{cw.cache,cw.gen,cw.hw}/` | **提交**（跟随 C3 的目录 add） | 它是 clk_wiz 预言机的生成物（`cw_oracle.v/xci`），是 `P6B_SPEC §8.2` 的证据；**我没有给它加忽略规则**，理由是"预言机的生成物 = 证据"。若 TL 认为它属于产物，加 `*_prj/` 一类的规则即可（**改 `.gitignore` 即可，不要 `git rm`**）。 |
| `board/ku5p_probe/clkgen_p6b/*.png` | 提交 | 是 ds922 手册页的裁剪图（MMCM VCO 合法性证据）；体积小。 |
| `.wdb` / `xsim.dir/` / `*.memh`(scratch) / `*.bit` / `*.pcap` | **不提交**（已被 `.gitignore` 拦住） | 产物；位流与抓包的 sha256 已记在 `P6B_ACCEPT.md` §1.1/§7.1。 |
| `sim/p4gates/work_*/` | 不提交 | 每次运行的仿真工作目录（已被忽略）。 |

### 4.3 一条**顺序**约束（不满足会毁掉证据）

`sim/p4sim/matrix_p4dfix.log` 与 `P4_MATRIX_FINGERPRINT_*.txt` **正在被写入**（13:20 起的无并发复跑）。
**C5/C7 里包含这几个文件 ⇒ 必须在那一轮跑完之后再做 C5/C7**（否则提交的是半截日志，
且下一次 `git status` 会显示它们又被改了）。其余提交不受影响。

---

## 5. 提交后的自检（建议逐条做）

```bash
git log --oneline -12                        # 9 条提交, 顺序 C0..C8
git show --stat <C1>                         # 抽查: 每条提交的文件清单与 §3 一致
git status --porcelain                       # 期望: 只剩"不提交"的那几类 (_tmp_*, 产物)
git ls-files | grep -c 'xsim\.dir/\|\.wdb$\|\.bit$\|\.pcap$'   # 期望 0
```
**最后一条特别重要**：它直接回答"119 MB 仿真残渣 / 11 MB 位流有没有被提交进去"。

---

## 6. 清单的现算（如果期间又有人改动）

```bash
# 当前改动全貌
git status --porcelain=v1 | wc -l
git status --porcelain=v1 | awk '{print $1}' | sort | uniq -c
# 硬化批的精确清单 (C6)
awk '{print $1}' sim/p4gates/evidence/inventory_eco_class.txt | sort -u > /tmp/inv.txt
git status --porcelain=v1 | grep '^ M' | sed 's/^ M //' | sort -u | comm -12 /tmp/inv.txt -   # 交集
```
