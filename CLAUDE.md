# udp_hls_10g — 10G-ready 纯硬件 TCP/IP 数据面 (1G 先行施工)

终局目标: 10G 线速纯硬件 TCP/IP (低延时行情 UDP 组播 + 交易 TCP 少量连接), 对上提供 TCP/UDP 调用接口。
施工策略 (2026-08-23 用户拍板): **1G 先行、10G-ready** — 数据面统一 64bit 宽流水 @125MHz,
10G 时仅提时钟到 156.25MHz, 流水线不改。设计审查与总计划: `../udp_hls_eco/design_review/` (01-04)。

## 当前状态与下一步 (2026-10-07 · **P7b WU 窗口通告修复闭环** ⊃ Stage 2 + TCP 上行归因)

⭐⭐ **2026-10-07 WU 轮 (最新置顶) = `wu` 窗口通告修复的闭环收口 + 独立验收**: 修复 (`09d2189`,
`rtl/app_ctrl.v` **+78/−8、端口面 0 改动**, 参数 `WU_LEGACY` 默认 0 = 修复后) ⇒ 构建 **`WNS +0.147 / WHS +0.010 /
三类失败端点 0/0/0`**, 位流 sha256 **`1076e50e…1160`** (✅ **已烧; 板上现态 = 它**; 旧 `d20c08c9…5ed5` 已被新构建覆盖、全盘无副本)。
**板级两臂 A/B** (同 6 点 pace 阶梯, 两臂紧挨 ≈4 min): **塌陷三档 `0/160e6/1000e6` 从 3.6–13.2 Mbps 抬到 1110.97–1111.05 Mbps**;
**中间三档 `50/100/134` 两臂逐字相同** (差 ≤0.01%) = **台架可比的正证据**; 形态: **静默段 55→0** · `MAX_GAP` **0.2086→0.0008 s** ·
**低窗恢复 208 ms→200 µs** (×1,040)。**`J6`（J6-ladder）= 行为层已证实; 判据层未裁定 (待裁定 —— ⛔ 2026-10-07 DOCFIX3 订正: 原写 "`J6` = PASS" 已撤回 —— 依据 `P7B_WU_ACCEPT.md:295` 逐字"不能算『修复臂 PASS』"、`:330`"我没能（也不该）裁定 (g)/(h)", 该件 `grep -n J6` = 0 命中; 裁定权在判据所有者)** ((e)/(f) 独立复算成立; (g)/(h) 按字面 FAIL 属实、经论证属**判据缺陷**
—— (g) 与 (e) **结构性互斥**、(h) 首子条件**两臂同 FAIL ⇒ 无判别力**; 硬证明 = `P7B_WU_ACCEPT.md` §7); **`J0` 复验 PASS**
(pcap **1514/1500/1480/1472** · NIC **1517.9991** · 板侧 `ΔW43/ΔW20` **193.00008** · **`ΔW9−1472×ΔW20 = +1,144 B`** ⇒ 8 B/帧修复没被碰坏)。
⛔ **（DOCFIX3 新增）待用户裁定**：`J6-ladder` 的 `(g)`/`(h)` —— 判据原文 = `P7B_BIZ_PLAN.md` §4.1b；两条论证 = `P7B_WU_ACCEPT.md` §7（(e) 与 (g) 结构性互斥有硬证明；(h) 首子条件两臂同 FAIL ⇒ 无判别力）⇒ **这一格写"行为层已证实 / 判据层待裁定"，不许写成 PASS**。
⚠️ **达标值域 = 趋近 `1.0–1.11 Gbps`, 不是 10G** (上界 = `app_pattern` RX `8 B/9 拍 × 156.25 MHz = 1,111.1 Mbps`, 实测 99.977–99.987% = **撞墙**;
⚠️ 这只是**演示 app** 的天花板, 快路径本身 Stage 2 已实测 **8.4 Gbps**)。
⚠️ **机理 ("wu 真的发了") 仍是推断** —— `stat_wu`(`0x96`)/`rx_occ_bytes` **未接快照** ⇒ **下一轮第一件事 = 接进窗口** (一次读数即升级为观测; ⚠️ 接线前先看 `P7B_WU_REVIEW.md` §2-P2 的噪声预警)。
⚠️ **板上现态 = 受控停流态** (`0x08 = 0x2` ⇒ `carrier = 0`); **恢复 = `reg_rw /dev/xdma0_user 0x08 w 0x0`** (⚠️ `0x08` **既是 SCRATCH 又是 `TX_DIS` 门**;
恢复后 peer 表还在 ⇒ 立刻恢复发流) 或重烧。⚠️ 独立验收另抓到一条各报告没提的: **`W54` 在 `100e6/160e6` 档两臂都爆 = 工具部分写打洞**
(`dW54>0 ⟺ tx_bytes%65536≠0`), 那两档的**图案内容**证据**两臂同等无效** (速率读数不受影响)。⭐ **2026-10-07 `W54` 关闸轮已拿回**: 修好的工具重跑 `100e6`/`160e6` ⇒ **`ΔW54 ≡ 0`** (四跑全 0, `partial_sends` = 2281/2159/0/4; 负对照 = 同会话同 pace 旧工具 `1,193,974,559` = 99.49% ⇒ 修复件 `0`; 原件 = `P7B_WU_W54_CLOSURE.md`)。
原件 = **`P7B_WU_ACCEPT.md`** (独立验收=权威) · `P7B_WU_BOARD.md` · `P7B_WU_FIX.md` · `P7B_WU_BUILD.md` · `P7B_WU_TIMING_DELTA.md` · `P7B_WU_REVIEW.md` · `P7B_WU_REGRESSION.md`。

### (2026-10-07 凌晨 · **P7b-BIZ Stage 2 + TCP 上行归因** 两轮)

⭐⭐ **Stage 2 板级验收已跑完 (2026-10-06, 对端机恢复后)**: ⭐ **`J0` PASS —— "每帧丢 8 B"确已在板级修复**
(四台仪器 + **最强判别式 `ΔW9 == Σ线上载荷`** 全中: pcap **1514/1500/1480/1472** (300/300 帧) · 对端 NIC
`Δbytes/Δpkts` **1518.0009** · 板侧 `ΔW43/ΔW20` **192.999989**; `ΔW8 == ΔW20`、`W56 = 0`、丢弃计数全 0)。
**速率 809,577.9 fps = `156.25e6/193`** ⇒ 线上 **9.8315 Gbps** / 载荷 **9.5336 Gbps**;
⚠️ 修复的确定性代价 = 帧周期 **192 → 193 拍 (−0.52%)** (那个字本来就没进 FIFO)。
⭐ **`W55` 定案** = 一次回卷重放**整段 `[snd_una, snd_nxt]`** (平均 **4.6–5.0 段**; 双向 pcap 拿到
**"对端确实发过 dup-ACK"** 的包级证据 ⇒ **RTO 被直接读数排除**) · ⭐ **`J12/J13` PASS** (`W54` 有牙:
翻 1 bit ⇒ `ΔW54` **精确 1**、不翻 ⇒ 0) · **上行天花板 → 8.4 Gbps** (4 进程洪泛: 板侧 `ΔW0 = 1,769,731`、
线上 8.38 Gbps、**板侧丢帧计数全 0**; ⚠️ 与对端计数差 0.166% 落在**对端**侧)。原件 = `P7B_BIZ_S2.md` **§10+**。

✅ **2026-10-07 WU 轮订正: 本条已闭环 (行为层)** —— 修复+构建+板级两臂 A/B+独立验收全部完成 (见本节置顶;
`J6` = 行为层已证实 / 判据层待裁定 —— ⛔ DOCFIX3: 原写 "= PASS" 已撤回, 见置顶段)。⚠️ 但 **"机理"仍是推断** (`stat_wu` 未接快照) ⇒ **新的第一优先 = 把 `stat_wu`(`0x96`) + `rx_occ_bytes` 接进快照**。
⛔ **以下原文保留** (它是当时的归因依据):
⛔ **当前第一优先 = 修 `wu` 窗口通告通路 (唯一一个已定案的产品级设计缺陷)** —— `J6` (TCP 上行速率) FAIL 的归因
已由**判决性 A/B** 完成: 用 `git worktree` 从 `d417589` **重建 RATE 位流** (时序签名 `+0.136/+0.010` 与 09-30 逐字一致),
测出 **RATE 4.544 vs BIZ 4.719 Mbps (同病)**、且 TCP-8080 快路径 RTL 两臂**逐字节相同** ⇒ **不是我们的 RTL**;
真因 = `app_ctrl` 的 `wu` 两个触发条件**结构性不可达** (`wscan == 0` 被 app 持续消费"Zeno 式"托在 56–128;
`wu_mark` 初值 = 全池 49152 ⇒ 要 ≥73728) ⇒ 板**从不主动通告窗口重开** ⇒ 对端只能等 **~208 ms persist**
⇒ 每周期 ~68 KB ⇒ **4.7 Mbps**。**修法 (两处)**: `wu_zero` 按**危险区**武装 (如 `wscan < 3×MSS`) +
`wu_mark` 改基 ("上次通告值 + 小步长"而非建连时全池); 建议同批接 **`stat_wu` (⚠️ 已存在, 寄存器 `0x96`)** +
`rx_occ_bytes` 进快照 (⚠️ 吃 WNS 余量)。收口判据 = `J6`/`J15`, **读数必须带 pace 值**。
⛔ **2026-10-07 订正 (判据重构 + 达标值域)**: 判据原文 = **`P7B_BIZ_PLAN.md` §4.1b 的「J6-ladder」**
(`PACE_BPS ∈ {0, 50e6, 100e6, 134e6, 160e6, 1000e6}` **bytes/s** · 每档 ≥2 跑 · `--seconds 12` · 四条台架自证 (a)–(d) +
两段速率判据 (e)/(f) + 单调性 (g) + 形态 (h); **负对照 = 缺陷位流 `d20c08c9…5ed5` 跑同一阶梯**, 不是单点)。
**上界一律按 `1.111 Gbps` 写** (TCP app `rtl/app_pattern.v` 在 `P7B_10G` 下**仍是 8/9 B/拍**, 8 路并行只在 `app_udp_pattern.v`);
⇒ **达标值域 = 趋近 `1.0–1.11 Gbps`, 不是 10G** (Stage 1 稳态实测已贴到 **1,110.8 Mbps = 天花板 99.97%**)。
⚠️ `--pace-bps` 的**单位 = bytes/s** (对端 `ss` 三档 `800000000/1280000000/8589934592 bps` = 恰 8.000× 自证)。
原件 = **`_proj_10g/notes/P7B_BIZ_TCPREG.md`** (判据 W/X + 4 组速率对照; ⚠️ 其 §1.3/§5 的 `2^30` 帽叙事**已被 2026-10-07 独立复核证伪并就地订正** —— 见 `P7B_WU_PACE_AUDIT_VERIFY.md` + `P7B_WU_PACE_DOCFIX.md`)。

⚠️ **两条环境级配方 (都已实测)**: ① **PCIe 恢复配方扩展** —— 开机时 FPGA 跑 QSPI 厂商设计 (POST 只枚举 **1 BAR**)
⇒ 父桥 `0000:00:1c.0` 窗按 1 M 定死 ⇒ **设备级 `rescan` 会失败** (`BAR 1 can't assign; no space` +
`xdma ... probe err -22`) ⇒ **必须连根端口一起 `remove`+`rescan`** (窗重算 2 M); **同一会话内后续重烧只需设备级**;
判别式 = `identify_bars` 的 **`1 BARs: config 0, user -1` = 厂商 / `2 BARs: config 1, user 0` = 我们的**
(⚠️ 两者 `lspci` 都报 `10ee:9034`)。② **NetworkManager 静默冲掉 `/32`** (表现 = 全部 connect timeout,
极易误判成"板子死了") ⇒ 根治 = `nmcli device set enp1s0f1np1 managed no`; **每次测量前仍要现取** `ip route get`。
⚠️ **板上现态 = BIZ 位流 `d20c08c9…5ed5`** (Stage 2 共烧 4 次 + 归因轮每臂/每档重烧; 末次 **2026-10-07 00:12:22**) ——
早先登记的"**新位流未烧 / 板上仍是 RATE 版**"**已作废**。
⛔ **2026-10-07 订正 (WU 轮): 上一条又被覆盖** —— **板上现态 = `wu` 修复位流 `1076e50e…1160`** (2026-10-07 02:31 烧入,
`End of startup status: HIGH`; 板侧身份已核 `0x00=0x50360001` / `0x04=8` / 61 字窗口 / `0x114=0xffffffff`)。
⚠️ **板子当前是受控停流态**: `0x08 = 0x2` (`TX_DIS` 高) ⇒ **`carrier = 0`**; **恢复配方 = `reg_rw /dev/xdma0_user 0x08 w 0x0`**
(⚠️ **`0x08` 既是 SCRATCH 又是 `TX_DIS` 门**; 恢复后 peer 表还在 ⇒ 立刻恢复发流) 或重烧。⚠️ 任何测量前仍必重烧 + 重核 sha256 (看 sha256, 不看字节数)。

⭐ **本轮抓修一个真缺陷 + 收掉两个同族潜伏 (FIFO 写口"本拍 full 门 + 寄存器写"一拍错位)**:
① **`rtl/app_udp_pattern.v` 的 TX 字 FIFO**: `txf_wr` 是寄存器 (**下拍落笔**), 却拿**本拍** `txf_full` 做空间门,
且被先行 AND 进 `.wr()` ⇒ FIFO 内部 `ovf_pulse = wr && full` **结构性恒 0** ⇒ **`P7B_10G` (8 B/拍) 下每帧静默丢
1 个整字 (8 B)**, 线上 1510 / `udp_len` 1472 (意图 1518 / 1480); **丢字是"帧中间挖洞"不是截尾**;
1G 时代 app 比帧器慢 8 倍 ⇒ **永不暴露**。修 = 空间门移到生产者侧用 **`full_next`** (先例 `rtl/mac_rx_64.v:131`)
+ `.wr()` 去掉预 AND + 接出 **`stat_tx_ovf`** (→ 快照字 **W56**); 负对照 `ovfctl` 读 **54 / 85** 恰好等于丢字笔数
且输出流指纹与缺陷版**逐位相同** ⇒ "修好了"与"它本可被看见"同时被证明。
② **`rtl/slow_tx_adp.v` 的 `frame_fifo` (D=512)**: 慢路径被 `tx_arb` 饿死 ≥33 µs ⇒ 占用涨到 511 ⇒
**带 tlast 的末字落在 `occ=512` 那拍被丢, 而该拍 FSM 已回 `T_IDLE` ⇒ abort 安全网结构性不触发** ⇒ 帧已计数却永不闭合。
③ **`rtl/slow_rx_adp.v` 的 `fifo_sync` (D=2048)**: 要摸到 2047 需**载荷 ≥1783 B**, 而该尺度**没有任何 RTL 守卫**
(10G MAC 对超长帧只计数、照常交付) ⇒ 窗口 **1784..4096 真实存在**。修法同形 (端口表**末尾**加 `full_next`/`ovf_pulse`
+ 各加 `stat_fifo_ovf`)。⚠️ **两份"够不着满"的论证都被构造性反例证伪** —— 充分条件有**两条** (占用够 **且** 写决定连续两拍);
"能到满"是**必要非充分**。原件 = `P7B_W9_{GAP,GAP_VERIFY,FIX}.md` · **`P7B_LATENT_FIFO_FIX.md`** · **`P7B_GATE_COV_FIX.md`**。

⭐ **观测面 51 → 61 字** (`P7B_BIZ_WINDOW.md`): 新增 **W51..W60** (全落 MSB 端 ⇒ 旧字逐项未动) =
`app_pattern` 发字节/发帧/收字节/**失配** · `tcp_tx_frame.stat_retx` · `app_udp_pattern.stat_tx_ovf` ·
`o_retx_hi`/`o_retx_active` · 两个适配器的 `stat_fifo_ovf`。**未实现地址 `0xEC → 0x114`**; **`BUILD_ID_V` 7 → 8**。
⚠️ **顺带修掉三处"判据结构性无牙"**: 窗口吃满 56 字上限时读侧 SLVERR 负对照**恒不触发**、旧 6 位译码
**每 256 B 回绕别名** (写 `0x108` 会别名到 SCRATCH = **`TX_DIS` 门**!) ⇒ `ar_word/w_word/r_word` **6→7 位**。
**合并构建** (`P7B_BIZ_BUILD.md`): **WNS `+0.136 → +0.077` / WHS +0.010 / 三类失败端点 `0/0/0`**,
位流 sha256 **`d20c08c9…5ed5`** (✅ **已烧多次, 板侧身份已核 `0x04 = 8` / 61 字窗口 / `0x114` 回 `0xffffffff`**)。−0.059 已归因 = **本轮扩窗的快照阵列** (+320 FF) 落在
**异步复位 Recovery** 网上 (**逻辑级数 0 / 97.2% 布线**, 上轮全局最差**同族**) ⇒ 同族内换最差位, 非新缺陷族。
⚠️ **含义: 再往窗口加字会继续吃这条** (每 +10 字 ≈ +320 FF)。
⛔ **2026-10-07 订正 (WU 轮; 出处 `P7B_WU_TIMING_DELTA.md` §5.3)**: 上面这句说的是 **pcie 域** `snap_words_r` 阵列的
**异步复位 Recovery** 族 (**不是**数据面 setup 路径); 且该族**本轮窗口没动也自己 +0.419** (0.077 → 0.496, 宿端换成
`u_snap_dp/dout_a_reg[145]/CLR`) ⇒ **幅度的大头是 P&R 重排** (本流程重排幅度 ±0.4~1.3 ns, "同输入 ⇒ 读数逐字复现"已由
RATE 原件/重建件对照证明)。**真实成本 ≈ 96 FF/字** = `snap_cdc.hold_b`(DP 域) 32 + `dout_a`(pcie 域) 32 + `snap_words_r` 阵列 32 **三份**
⇒ "每 +10 字 ≈ +320 FF" **只数了阵列那一份**; 总数 ≈ **960 FF/10 字, 其中 320 落数据面域**。
⭐ **新增一条**: **数据面域 `g_hw.clk_out0` 现在就是全局最差 (WU 构建 `WNS +0.147` = 周期 6.400 的 2.3%)**, 且 **DP 前 10 有 6 条同源**
(`u_app_udp/u_txf/dout_reg[68] → u_udp_tx/ip_csum_r`, 跨 0.147–0.229) ⇒ **任何加逻辑 (含接 `stat_wu` 进快照) 都必须由一次构建收口**。
⚠️ 扩窗的可测风险排序: ① `async_default` 两族 (pcie **0.496** / DP **0.743**); ② 数据面域 FF 数 (+32/字) 与布局压力。

⭐ **业务实测 (Stage 0/1 完成, 旧位流)**: **TCP 下行 903.7 Mbps/连接** (`app_pattern` TX ~~**1 B/拍** = 2003 拍/帧~~ ⛔ **DOCFIX3 订正: TX 实测 = `8 B/10 拍 = 0.8 B/拍`、一帧 `1828 拍 / 1460 B`** (xsim 直测; 出处 `P7B_GAP9_TCPAPP_8WAY_DESIGN.md` §1.1; `2003 拍/帧` 的分解两项都不准、app 单独上界 **998 Mbps**)) ·
**TCP 上行 1,073.0 Mbps** (`app_pattern` RX 校验器, 实测/预测 **0.966**) · **UDP 上行板子 100% 吸收**
(`2,501,222,400 / 2,501,222,400 = 1.000000` 逐字节) ⇒ **瓶颈一个都不在 10G 链路或板内数据面**
(`ΔW3=ΔW4=ΔW32-35=ΔW46-49=0`)。原件 = `P7B_BIZ_S1.md`。
⛔ **2026-10-07 订正 (上面那行的 `1,073.0 / 0.966`)**: 该两数的口径错 —— **Stage 1 稳态 = `132.414 MiB/s = 138.85 MB/s = 1,110.8 Mbps`**
= `app_pattern` RX 校验器结构天花板 (`0.889 B/拍 × 156.25 MHz = 1,111.1 Mbps`) 的 **99.97%** ⇒ **实测/预测 = 0.9997**
(`0.966` 是拿 **6 s 均值 1,073.043** 当分子算的; 稳态 4 秒增量 = `132.406/132.407/132.437/132.406` MiB/s, 与
`8/9×156.25e6/1048576 = 132.4123 MiB/s` **吻合到 5×10⁻⁵** —— 日志 `tx_MB` 是 **MiB** 且 `1,073.043` 含一次 **0.2056 s** 停顿,
⚠️ **该停顿的归因不可判**)。出处 = `P7B_WU_PACE_AUDIT_VERIFY.md` §2.2/§2.3。
⚠️ ⭐ **两条旧归因已被 10-06/07 两轮改写**: ① 「上游天花板在**对端单核** (~2.8–3.0 Gbps)」**只对 RATE 位流成立**
—— Stage 2 把上行推到 **8.4 Gbps** (板侧 `ΔW0 = 1,769,731`、丢帧计数全 0), 且真因是**窗口通告通路**; ②
「**TCP 上行 1,073.0 Mbps**」= `2^30 bps` 的 **99.94%**, 而原始件**没有 pace 记录** ⇒ **很可能量的是工具的帽子**
(今天同 pace 照样塌)。⛔ **2026-10-07 二次订正: 【②】整条撤回** —— `--pace-bps` 的**单位是 bytes/s**
(`sock.h:493` 逐字 `/* bytes per second */`; `ss` 三档逐字 `pacing_rate 800000000bps / 1280000000bps / 8589934592bps` = 恰 8.000×)
⇒ `2^30` 的真值是 **8.59 Gbps 的帽** (该臂今天实测塌陷 4.719 Mbps), **算术上压不到 1.07 Gbps**; 逐秒复算给出
**稳态 = app 天花板 99.97% 且四个数落在理论值 5×10⁻⁵ 内** ⇒ **"被 app 的 RX 校验器钉死"成立**。
⚠️ **"原始件没有 pace 记录"这句保留为事实** (不许改写成"已记录")。⚠️ 同批: `PACE=100e6` 的 `800.186 Mbps` = **pace 帽在位**
(达成率 1.00023)、**不是板子容量** (该跑窗全程未关: `min(win)=29,584 B = 20 MSS`) ⇒ 与 `wu` 定案**相容且是它的正面证据**。
⚠️ **重复 seq 整段**已部分收口: 机理 = **一次回卷重放整段 `[snd_una, snd_nxt]`**、
量 **11.9 → 5.65/连接** (1,695 段), **但根触发未定位** (对端第一个 dup-ACK 三连出现在任何数据被确认之前);
**2 次非受令 carrier flap** 仍未定位。

⭐ **仿真回归** (`P7B_BIZ_REGRESSION.md`): **11 入口 / 25 门 / 30 次执行全部 EXIT=0、真回归 0 条**;
矩阵 `16/16 · gates failed: 0 · VERDICT: FROZEN` (237 文件逐字相同); 唯一数字差异 (`p5e_rate` 默认档
`stat_tx_bytes` 61112→61120) **已三方 A/B 钉死为门自己的抽样点位移**, 线上输出逐字不变。
⚠️ `run_tb_slowrx`/`slowtx` **覆盖不到组②** (`full|occ|ovf` 0 命中), 两个 `stat_*_ovf` **没有任何 TB 读它们**。

⚠️ **一条历史判据已降级** (`P7B_W13_AUDIT.md`): `W13 == 0` 在**没有 RX 流量的窗口里是空判据**
(`i_en` 门控 + 没喂进 app) ⇒ `P7B_RATE_RESULT.md` 的判据 **`A4` 从 `PASS` 降为 `未测（空判据）`**;
全仓 27 处引用逐条裁定, **只有 BIZ S1 (2.5 GB) 真正喂进去过**。⚠️ **不波及线速达标与闸 4 的 `PASS=33`**。

⭐ **BRAM 研究报告** (**`P7B_BRAM_REPORT.md`**, 本轮零实验): **348/480 = 72.50%** (R36 317 + R18 62),
**URAM 0/64 全空**, LUTRAM 6.66%, **对账差额 0**; 三个大块 = **94.5%** (= `256+37+36 = 329` / `348`;
⚠️ 源头 `P7B_BRAM_{REPORT,INVENTORY}.md` 原写 88.5% **算术不成立**, 已就地订正) (`retx_ram` 256 / HLS `udp_echo` 37 / `xdma_0` 36);
**唯一够格迁 URAM 的是 `retx_ram`** ⇒ **348 → 92 tile (19.17%)**, 代价 29–32/64 URAM + 读流水 2→3 级
(Vivado 自己试过并拒绝: `Synth 8-6793`, 原文 `Available pipeline stages = 0, Minimum required pipeline stages = 3`); ⚠️ **不能只加 `ram_style="ultra"`**
(已拆 8 字节 lane × 16 深度片 ⇒ 会炸成 128 URAM/阵列)。⚠️ **它不是时序也不是延迟瓶颈** (95.98 ns 流水里 BRAM 贡献 **0 拍**) ⇒ **非阻断项**。

⭐ **10G 线速已达标** (2026-09-30 下午, **RATE 里程碑**): 两刀 = ① **8 路并行图案发生器**
(`rtl/app_udp_pattern.v`, 包在既有宏 `P7B_10G` 内, 1474 → **186 拍/帧**) ② **组帧器乒乓重叠**
(`rtl/udp_tx_frame.v`, **新宏 `UDP_TX_OVL`**, 378 → **191 拍/帧**; 构建脚本 `board/build_p7b_ku5p.tcl:145`
的 `verilog_define` 已加 `UDP_TX_OVL=1`)。**主判据 (板内自洽、不依赖主机墙钟)
`ΔW20/(ΔW5/156.25e6)` = 813,794.7 fps** (R1/R2/R3/L20 四轮**逐字一致**到 3×10⁻⁶; FE/DP 交叉差 **+0.0003%**)
⇒ **线上载荷 9.531 Gbps (最保守口径) = 同几何上限 99.61% · 达标界 6.8 Gbps 的 ×1.402 · XGMII 占空 99.9991%**;
拍/帧 **192.00**; 四项差分账 `d_dma/d_board = 0.99802` 且 **`Δcrc=Δbad=Δovf=0`** ⇒ **板子清白**;
负对照 N-a (拉 `TX_DIS`) ⇒ NIC 计数全 0 而**同窗 `ΔW20` 仍 813,802 fps** ⇒ **两条口径独立性被直接证明**。
合并构建 `WNS +0.136 / WHS +0.010 / 三类失败端点全 0`; 位流 sha256 `4eeb0f5f…3133`。
原件 = **`_proj_10g/notes/P7B_RATE_RESULT.md`** (板级测量) + `P7B_RATE_{BOTTLENECK,DATAPATH,8WAY,FRAMER,BUILD,MEASURE_PLAN}.md`。
⚠️ **两刀都包在宏内 ⇒ 关掉 `UDP_TX_OVL` 就回到 HEAD 的帧器行为 (默认分支逐字保留, 343 insertions / 0 deletions)**;
⚠️ **`UDP_TX_OVL` 只在 `board/build_p7b_ku5p.tcl` 这一个构建里打开** (未改任何别的构建脚本);
⛔ **口径订正 (2026-09-30 深夜, P7B-BIZ 轮)**: 本条原写「本构建的帧几何经**三台独立仪器**定案为
**载荷 1464 B / 线长 1510 B / 192.00 拍**, 与测量计划书的 **1472 / 1518 / 193.24** 不同 —— **错的是计划书**, 不是板子」。
**站不住** —— 那 **8 B/帧** 是 `rtl/app_udp_pattern.v` 的 TX 字 FIFO **写门一拍错位**造成的**每帧静默丢 1 整字**
(见本节开头), 而**三台仪器量的是同一个缺陷** ⇒ **"一致" ≠ "正确"** (`P7B_HANDOFF.md` §2「RATE 轮口径订正」)。
修复后**期望**回到 **1472 / 1518 / 193.00** —— ✅ **2026-10-06 Stage 2 实测坐实** (pcap **1514/1500/1480/1472** (300/300 帧) ·
NIC **1518.0009** · 板侧 **192.999989** · **`ΔW9 == Σ线上载荷` 差 −168 B**; ⚠️ `193.24` (计划书) 与实测 `193.000` 的
0.12% 差以板内时基 `ΔW5` + `ΔW43/ΔW20` 两条同源口径为准)。
⚠️ **线速结论 (813,794.7 fps / 9.531 Gbps 最保守口径) 不受影响** —— 它不依赖载荷字节数。

**P7b (10G 数据面) 五个闸全部收口**: **闸 0 ✅ / 闸 1 ✅ / 闸 2 ✅ / 闸 3 ✅ / 闸 4 ✅ (板级验收通过)**。
新 64 位 XGMII MAC **已接入 `board/wrapper_p4.v` 的 `ifdef P7B_10G`**; `rx_classify` v2 **已落进 `rtl/`**。
两个真缺陷已修: ① `/S/` 落 XGMII **lane4** 的帧 SOP 字非满对齐 (`mac_rx_10g.v` +122/−25);
② pad/FCS 修复打出的 **TX 时序回归** (`mac_tx_10g.v` 的 `padrem`/`lw_ts` 等价化简)。
**合并构建 `WNS +0.128 / WHS +0.010`、三类失败端点全 0**; 位流 sha256 `0e1c8088…b557`。

⚠️ **但有 3 件事别记错**:
- **闸 4 的唯一 FAIL = `C8`** (`pcs_vcc_cyc` 8 位饱和 ⇒ "在涨"结构性不可判; **判据一字未改、非设计缺陷**);
  **另有 4 项未测** = `F1-E4b` (RX 方向载荷逐字节) · `F1-E5` · `F1-E6` · `F5b` (RTO/重传计数结构性不可读)。
  ⭐ **最终判据表 38 行 = `PASS=33` / `FAIL=1` / `未测=4` —— 以 `_proj_10g/notes/P7B_GATE4_ACCEPT3.md` §2 的表为准**
  (⚠️ 此前流传的"32"作废: 它把两条"骑墙行"的一半计入 PASS 又各记一个未测行 ⇒ 37 行, 在 36 行表里不自洽)。
- ~~**产品级第一优先 = 10G 线速未达标**: app 发生器 **1 字节/拍** ⇒ 实测载荷 **1.248 Gbps** = 线速 ~12.5%。
  ⚠️ 闸 1 的 9,999.94 Mbps 与闸 2 的 NIC link **只证明链路/物理层**, **数据面端到端从未跑过线速**。~~
  ⇒ ✅ **已关闭 (2026-09-30 下午, RATE 里程碑; 见本节开头)**。⚠️ **但这一轮的 4 项未测不许当通过**:
  **RX 方向载荷逐字节** (**UDP 侧已由 BIZ Stage 1 的 J8 强证** = 2.5 GB / `ΔW13 ≡ 0`, **全仓唯一一条板侧 RX 内容
  oracle 强引用**; ⭐ **TCP 侧现在也不再"结构性不可判"** —— `W53/W54` 已进窗口且 **`J12/J13` 实测通过**,
  只剩"TCP 下行 payload 的独立 oracle"这一窄义未做) · **工具自报的"图案真失配"** (未采信也未否定) ·
  **`N-b1` (`TX_GAP` 低速档, 仍未做)** ·
  ~~**`W9` 与线上差 8 B/帧的 RTL 定位**~~ ⇒ ✅ **已定位并修复** (= `app_udp_pattern` 的写门错位; **Stage 2 的 `J0` 已板级坐实**)。
- **闸 4 的三条 FAIL 去向里, 没有一条是"现象变好了"**: 2 条是**判据改了** (`T_RUN` 拆分 / `N_SELF` 加容差),
  1 条是**判据修好了、首次真的被评估** (`N_XCHK` 的 `${assoc+x}` 守卫对关联数组恒假 ⇒ 结构性从未评估)。

**接手必读 (按序, 都在本仓内)**:
1. ⭐ **`_proj_10g/notes/P7B_HANDOFF.md`** —— **下一轮开工先读这份**: 环境现状 (**✅ 对端机已恢复 /
   **板上 = BIZ 位流 `d20c08c9…5ed5`** (末次烧录 2026-10-07 00:12:22) —— ⛔ **2026-10-07 订正 (WU 轮): 已被覆盖,
   板上现态 = `wu` 修复位流 `1076e50e…1160`** (02:31 烧入); ⚠️ **板子当前是受控停流态** (`0x08 = 0x2` ⇒ `carrier = 0`),
   **恢复 = `reg_rw /dev/xdma0_user 0x08 w 0x0`** (⚠️ `0x08` 既是 SCRATCH 又是 `TX_DIS` 门) / 唯一连线 `J8↔enp1s0f1np1` /
   `tools/peer_ssh.py` + `PEER_PW` / **`/32` 会被 NetworkManager 静默冲掉**(根治 = `nmcli ... managed no`) /
   **PCIe 恢复配方已扩到两级**(厂商位流枚举 1 BAR ⇒ 连根端口一起 `remove`+`rescan`) /
   **可达性判据用 TCP 不用 `ping` 退出码**) ·
   状态总表 (WU 轮两臂 A/B + `J6`/`J0` 已入"有板级读数") · 下一步与前置 (**第一件 = 接 `stat_wu`(`0x96`) + `rx_occ_bytes` 进快照** ——
   `wu` 修复本身已闭环, 只剩"机理仍是推断"这一格; 第二件 = 用修好的工具重跑 `100e6`/`160e6` 拿回内容证据) ·
   待办账 **49 条** · **产品级 Gap 9 条** (⛔ 2026-10-07 订正: 8 → 9, 新增 **#9 = TCP app 未拿到 RATE 轮给 UDP app 的 8 路并行**
   ⇒ **TCP 上行结构上界仍是 1.111 Gbps**; **设计研究已备、未实施、等用户授权** = `P7B_GAP9_TCPAPP_8WAY_DESIGN.md`) · 用户偏好 ·
   全局经验 **30–51 条** (**43–51 全部已回灌全局文件**; ⚠️ 旧句"43–46 尚未回灌"已作废; ⛔ 2026-10-07 DOCFIX3: 全局 §六 现为 **24–51**, 新增 **#51** = "汇总者的措辞会被下游当权威照抄 ⇒ 现象/证据强度/判据层裁定必须分层写、裁定不代行" —— 本轮的 `J6` 事件)。
2. ⭐⭐ **10-06/07 两轮 (Stage 2 + TCP 上行归因) 的笔记** ——
   ⭐ **`P7B_BIZ_S2.md`** (**§10 起 = Stage 2 执行结果**: `J0` 四仪器 / `W55` 定案 / `J12` 有牙 / A/B 复现 / 上行 8.4 Gbps;
   §0–§9 是前任的"受阻"记录) · **`P7B_BIZ_TCPREG.md`** (**TCP 上行归因**: A/B 判决 = 不是我们的 RTL /
   `wu` 机理 / **判据 W·X** / 4 组速率对照 / 修法) + 原始件 `p7b_biz_s2/` · `p7b_biz_tcpreg/`。
3. ⭐⭐ **BIZ 轮 (2026-09-30) 的 19 份笔记** —— 按"想知道什么"排:
   **`P7B_BIZ_PLAN.md`** (计划与判据表) ·
   **`P7B_W9_{GAP,GAP_VERIFY,FIX}.md`** (那个真缺陷: 定案 → 复核 → 修复 + 归零 + 同类普查) ·
   **`P7B_LATENT_FIFO_FIX.md`** (两个同族潜伏实例 + 两份被证伪的"够不着"论证) ·
   **`P7B_GATE_COV_FIX.md`** (门为什么当时看不见它) ·
   **`P7B_BIZ_WINDOW.md`** (观测面 51 → 61 字) · **`P7B_BIZ_BUILD.md`** (合并构建 + 时序) ·
   **`P7B_BIZ_S1.md`** (业务 Stage 0/1 读数) ·
   **`P7B_BIZ_REGRESSION.md`** (仿真回归) ·
   **`P7B_W13_AUDIT.md`** + `P7B_DOC_CORRECTIONS.md` (空判据审计与逐条订正) ·
   **`P7B_BRAM_REPORT.md`** + 四路分路件 (BRAM 研究报告) · `P7B_PCIE_RESCAN_RECOVERY.md` (PCIe 端点恢复配方)。
4. ⭐ **RATE 轮的笔记 (10G 线速达标 = 产品级第一优先的关闭件, 共 7 份)**:
   **`P7B_RATE_RESULT.md`** (板级测量原件: 判据表 / 四项差分账 / 两条负对照 / **未测清单** / 停板步骤) ·
   `P7B_RATE_BOTTLENECK.md` (瓶颈定位: 1474 拍/帧 = 1.248 Gbps, 与板侧吻合 0.0002%) ·
   `P7B_RATE_DATAPATH.md` (独立核算: 单流 4.84 / 双流 9.51 Gbps) ·
   `P7B_RATE_8WAY.md` (第一刀: 8 路并行 + **逐字节等价五重证据**) ·
   `P7B_RATE_FRAMER.md` (第二刀: 组帧器乒乓 378→191 拍, `o_busy` 只变一处) ·
   `P7B_RATE_BUILD.md` (合并构建 `+0.136 / 0 失败`, 位流 sha256 `4eeb0f5f…3133`) ·
   `P7B_RATE_MEASURE_PLAN.md` (测量方案; ⚠️ ⛔ **其判据口径已在 BIZ 轮被重新裁定** ——
   原写"计划书的 1472/1518/193.24 已被实测推翻、真值是 1464/1510/192.00"**作废**:
   1464/1510 是 `app_udp_pattern` 丢字缺陷的后果, **计划书的 1472/1518 才是设计意图**,
   修复后**期望**回到 1472/1518/193.00 —— 读它时先读 `P7B_BIZ_S2.md` §2 与 `P7B_HANDOFF.md` §2「RATE 轮口径订正」)。
5. `P7B_SPEC.md` —— 施工规格: 路线与 license 分叉 / 接口冻结 / 闸序 / **66 条正判据 + 9 条负对照**。
6. `_proj_10g/notes/P7B_GATE4_ACCEPT{,2,3}.md` + `P7B_GATE4_CRITERIA_CLOSEOUT.md` —— **闸 4 三轮读数** +
   判据侧收口 + **产品级 Gap 6 条**（⚠️ 该 6 条是**闸 4 当时**的口径; RATE 轮关闭第 1 条、新增 1 条,
   BIZ 轮更新第 2 条、新增第 8 条 ⇒ 现役口径 = **8 条**; ⛔ **2026-10-07 订正: 文档订正轮新增 #9（TCP app 未拿到 8 路并行）⇒ 现役口径 = 9 条**;
   **WU 轮更新 #2（已闭环·行为层）与 #9（设计研究已备、未实施）**, 见 `P7B_HANDOFF.md` §5）。
7. `_proj_10g/notes/P7B_{UDP_APP_ROOTCAUSE,UDP_DIAG2,LANEFIX}.md` —— 板级失效的根因链 (三假设全否 →
   **lane4 双证** → 修法 +122/−25 + 判据族扫描)。
8. `_proj_10g/notes/P7B_{TIMING_RERUN,MAC_TIMING_FIX,BUILD_FINAL}.md` —— `−0.173 / 39 失败` → `padrem` 等价化简
   → **合并构建 +0.128 / 0 失败**。
9. `_proj_10g/notes/P7B_REGRESSION.md` + `P7B_CHAIN_COVERAGE.md` + **`P7B_GATE_HARNESS_FIX.md`** —— **136 门全仓回归**
   (1 处真回归 **已收口** + 21 既存 + 8 哑门 **3 条已修**) · 链级门 **80→106** 与反例双跑 · 门修复的收口与反例。
10. `_proj_10g/notes/P7B_EVIDENCE_AUDIT.md` —— **历史证据污染审计** (两个缺陷对已入库读数影响到什么程度)。
11. `P7B_VENDOR_EXAMPLE_DEFECTS.md` · `P7B_LATENCY_GAPS.md` —— 厂商两笔账结案 · 延迟两个缺口的归因。
12. `PORT_NOTES.md` 的 "**2026-10-07 P7b WU 窗口通告修复（闭环收口）**" 节 (最新, 4 条教训) +
    "2026-10-06/07 P7b BIZ Stage 2 + TCP 上行归因" 节 (4 条) +
    "2026-09-30 P7b BIZ 里程碑" 节 (6 条) + "2026-09-30 P7b RATE 里程碑" 节 + "2026-09-30 P7b（闸 3 收口 → 闸 4 板级通过）" 节
    —— 里程碑日志 + 教训 + 未结项清单。

⚠️ **几条"别按已完成接手"的账**:
- ~~`p4_rxclass` / `p4_rxclass_xk` 真回归未收口~~ ⇒ ✅ **已收口** (`_proj_10g/notes/P7B_GATE_HARNESS_FIX.md`:
  两条门的 xvlog 行各补 1 个 `..\..\rtl\fifo_sync.v` ⇒ **EXIT=0**、判据与基线逐字相同、**未改 RTL**;
  同轮还修了 3 条哑门 `p4_replay` / `p5c_rev_elab` / `p4indm_4gates`)。⚠️ 两条门脚本在 `.gitignore` 里 ⇒ **放行处理中**。
- **延迟有三个缺口**: `L_PCS` (最大) / fast path → app 队列 (零读数) / `(c)→(d)` 两个 tap (只缺一个真 IPv4/UDP 帧)。
- ~~⛔ **Stage 2 的板级判据一条都没跑**~~ ⇒ ✅ **已跑完 (2026-10-06)**: `J0`/`J12`/`J13`/`W55` 均有板级读数,
  `J6` FAIL **已定案归因** (= `wu` 通告通路, 见本节开头)。⚠️ **仍未测**: `W57/W58` / `J5` / `J15` /
  `F1-E5`/`F1-E6` / `N-b1` / 风险 b。⛔ **2026-10-07 订正: `J15` 的旧判据 ("8 B/拍新预测带", 上界引 `4.803 Gbps`) 前提错、已作废**
  (`grep -c P7B_10G rtl/app_pattern.v` = 0 ⇒ 8 路并行只在 `app_udp_pattern.v`) ⇒ 与 `J6` **合并**为 `P7B_BIZ_PLAN.md` §4.1b 的 **J6-ladder** (上界一律 `1.111 Gbps`);
  ⇒ 这一格今后读作 **"pace 阶梯未跑"**, 判据原文见 §4.1b 的完整段落。
  ⛔ **2026-10-07 二次订正 (WU 轮)**: **pace 阶梯已跑** (两臂、每档 2 跑) ⇒ **`J6` = 行为层已证实 / 判据层未裁定 (待裁定 —— ⛔ DOCFIX3: 原写 "= PASS" 已撤回, 裁定权在判据所有者)** (读数与 (g)/(h) 的判据缺陷硬证明见 `P7B_WU_ACCEPT.md` §7 + `P7B_BIZ_PLAN.md` §4.1b 订正块)。⇒ 上一句"这一格今后读作 pace 阶梯未跑"按本条读。
  ⚠️ **仍未测 (更新后)**: `W57/W58` / `J5` / `F1-E5`/`F1-E6` / `N-b1` / 风险 b; **`J15` 已并入 J6-ladder 并随之跑完**。[旧登记: 板侧前置闸 = `0x04` 必须 `0x00000008`、窗口 **61 字**
  (`0x20..0x110`)、未实现地址 **`0x114`** 回 `0xffffffff`, **绝不能挑 ≥ `0x200`** (7 位译码回绕到 word 0 = MAGIC ⇒ 假 FAIL)。]
- ⛔ **TCP 上行速率不达标 = 已定案的设计缺陷, 修复未做** (第一优先): 真因 = `app_ctrl` 的 `wu` 两个触发条件
  **结构性不可达** ⇒ 板从不主动通告窗口重开 (对端只能等 ~208 ms persist) ⇒ 4.7 Mbps。
  修法 = `P7B_BIZ_TCPREG.md` §6 (改 `wu_zero` 武装条件 + `wu_mark` 改基); 判据 = `J6`/`J15`, **读数必须带 pace 值**。
  ⛔ **2026-10-07 收口 (WU 轮; 上面这条的"修复未做"已作废)**: **修复已做 + 板级坐实 + 独立验收** ⇒ `J6` = 行为层已证实 / 判据层待裁定 (⛔ DOCFIX3: 原写 "= PASS" 已撤回 —— 裁定权在判据所有者);
  ⚠️ **不许按"已完成"接手的两格**: ① **机理仍是推断** (`stat_wu`/`rx_occ_bytes` 未接快照 —— 下一轮第一件事);
  ② `100e6`/`160e6` 两档的**图案内容证据**被**工具部分写打洞**污染 (`dW54>0 ⟺ tx_bytes%65536≠0`), 要**用修好的工具重跑**才算有; ⛔ **2026-10-07 订正 (`W54` 关闸轮): 已重跑、已拿回** (`ΔW54 ≡ 0` 四跑 + 同会话同 pace 负对照; 原件 = `P7B_WU_W54_CLOSURE.md`)。
  ③ 新登记的边界: **P1** (`winq ≤ 3` 时新武装条件不可达、比修复前更差; 产品配置不受影响) · **P2** (`stat_wu` 计入共享占用噪声, 接线时先知)。
  ⛔ **2026-10-07 订正**: 判据原文 = **`P7B_BIZ_PLAN.md` §4.1b 的「J6-ladder」** (整合 `J6`+`J15`); **达标值域 = 趋近 `1.0–1.11 Gbps`**
  (TCP app 结构天花板; 不是 10G) —— 负对照 = **缺陷位流上跑同一阶梯** (骨架 4 点已备, `P7B_WU_LOOP_MEASREP.md` §3.2)。
- ⚠️ **几条未定位**: 对端第一个 dup-ACK 三连的根触发 · 每连接 2 个 FIN · 4 核洪泛 0.166% 帧差 ·
  `dupseq` 11.9→5.65 未归因 · 2 次非受令 carrier flap。
- ⚠️ **重建的 RATE 位流 `6475c3ba…` 随 worktree 一起删除** (再要 A/B 需重建 ~22 min); **本机没有第二条 10G 路径**。

⚠️ **本条与下面"10G-ready 设计决策"第 2 条冲突时以本条为准**: 那句"10G 前端 = PG157 AXIS 输出
加一层 shim"**已作废** —— P7b 闸 0 定的是官方 `xxv_ethernet` 取 `CORE = Ethernet PCS/PMA 64-bit`
(**XGMII 出**) + **自写 64 位 XGMII MAC** (`P7B_SPEC.md` §0/§2.2)。其余三条决策不变。
(P6b 时代的接手入口仍是 `P6B_SUMMARY.md`; 观测通道**现役表 = `_proj_10g/notes/P7B_BIZ_WINDOW.md` §1**,
快照窗口现为 **61 字** (P7b-BIZ 扩窗, `BUILD_ID_V=8`, 未实现地址 `0x114`); ⚠️ `P6E_OBS.md` 是 **36 字版 (历史)**,
其窗口表 / `BUILD_ID=6` / 未实现地址 `0xB0` 都已过时。)

## 10G-ready 设计决策 (不可违背)

1. **数据面所有模块 64bit 字流 @125MHz** (10G 时 156.25MHz), 每级 II=1, 帧内零整包暂存。
2. **MAC 边界 = 左对齐字流** (见下接口规范): 1G 前端 = GMII 字节流→字流 (`mac_rx_64`);
   10G 前端 = PG157 AXIS 输出加一层 shim 对齐到同一约定。
3. **fast/slow path 划分**: 数据面全 RTL; 慢路径 (ARP/ICMP/IGMP/DHCP/TCP 握手/重传/RTO)
   移植 `../udp_hls_eco` 现有 HLS 层 (ap_ctrl_hs @125MHz), 经 AXIS CDC FIFO + BRAM mailbox 解耦;
   **TCB 唯一状态源归属 fast 数据面**。
4. **背压合同**: 级间弹性 FIFO; 必须丢帧时在帧边界丢整帧 (消费者按 TLAST 完整性丢弃半帧)。

## MAC 字流接口规范

- `tdata[63:56]` = 帧首字节 (dst_mac[0]), 字内字节从高到低连续
- SOP 字总是满对齐 (`tkeep[7]=1`); TLAST 字 `tkeep` 高位有效
- FCS 在 MAC 层校验并剥离; `tcrs` (TLAST 有效) = FCS 正确; `terr` = 帧内 rx_er
- CRC-32: 反射多项式 0xEDB88320 / 初值 0xFFFFFFFF / 残留 == **0xDEBB20E3** 为正确
  (0xC704DD7B 是大端/非反射魔数, 勿用); 线上 FCS 字节序 **LSB-first** (zlib.crc32 值小端)

## 应用接口 (P5, APP_MODE)

- **构建开关**: `board/build_p5.tcl` 定义 `verilog_define APP_MODE=1`; 默认构建
  (`build_p4.tcl`, 宏未定义) **必须与 P4 逐位等价** —— 新增逻辑一律包在
  `` `ifdef APP_MODE `` 内, 且新增端口在默认路径上必须是常量。
- **数据面**: app 用 AXIS 流收/发 TCP 载荷 —— `app_tx_*` (一帧 = 一个 TCP 段 ≤1460B,
  `tid`=conn_id, 帧内稳定; tready=0 时保持稳定), `app_rx_*` (零拷贝直出, 附 `len` 边带,
  永不出现半帧/重复/乱序)。**app 侧不做分段** (一帧一段), 超长帧由 RTL 帧内中止丢弃
  (`PLEN_MAX=1500`, `stat_drop_len`)。
- **控制面**: `rtl/app_ctrl.v` 寄存器总线 (5→8 位地址/32 位数据) —— 连接事件 FIFO
  (CONN_UP/DOWN + peer ip/port/mac)、`CMD` 写 (close→发 FIN / abort→发 RST)、
  每连接状态块、`app_tx_ready`。事件源 = `slow_cfg_adp` 的 `ev_up/ev_down`
  (ADD 收尾授权拍 / DEL state=0 授权拍)。
- **FIN 硬规则 (D4)**: 只在 `snd_nxt == snd_una` (无在飞数据) 时排队 —— ring 不覆盖 FIN
  的 1 字节 seq, 有在飞时排队会让 RTO 回卷把 FIN 当 ring 数据重放 (垃圾载荷)。
- **同槽重连 (D1)**: 必须靠 cfg ADD 收尾脉冲 (`cfg_up/cfg_up_id`) 显式清该槽
  `fin_sent_r/rst_sent_r`, **不能只靠扫描清** —— 背靠背 DEL→ADD (~70 拍) 采不到
  `state=0`, 残留会让 `start_data` 永久挡住该连接 ⇒ 数据面死锁。
- **tready 必须与启动门同门 (D2)**: `s_axis_tready` 的 S_IDLE 分支与 `start_data`
  用同一组条件 (含 `!fin_req/!fin_sent_r`), 否则帧起不来却照样收字 → 填满载荷 FIFO。
- **多连接 = 建连前分池 (P5d D4)**: 窗口一旦通告不可撤销 ⇒ 每条连接的上限必须
  **建连之前**设小: app 写 `app_ctrl` 寄存器 `0x0C` = `WIN_POOL/预期连接数`
  (复位默认 `0xC000` = 旧行为; 不写 = 零回归; 逐拍 `Σwinq + pool == WIN_POOL`)。
  参数 `WIN_Q_MAX` 只剩"复位默认值"语义 —— **不做成 wrapper 传参** (那会强制所有
  TB 镜像它的取值, 坑 11)。
- **接受裕度按 ESTAB 数动态缩 (P5d H-fix)**: `tcp_rx.ACC_MARGIN` 由参数改**端口**,
  由 `wrapper_p4` 用查表 + **寄存器**下发 `min(4096, 10550/N)`, 下界钳 `3328`
  (N = ESTAB 数; 10550 = 65536 - WIN_POOL(49152) - Δ(2816) - U(1518) - SEG_MAX(1500))。
  默认构建与各默认 TB 显式传 `16'd0` ⇒ 逐位不变。端口名**保持大写** `ACC_MARGIN`
  是故意的: `tools/gen_stim_p5_adv.py` 的 `check_phys_margin` 按文本解析这一行。

## UDP app 接口 (P5e, 10G-ready 行情通路先行)

- **数据面分工**: RX 侧 `rx_classify.slow → udp_split` → ①透传口 → `slow_rx_adp` (HLS)
  ②帧缓冲 → app UDP RX 口; TX 侧 app → `udp_tx_cfg` (peer 门 + cfg 锁存) →
  `udp_tx_frame` (长度守卫 ≤1500) → `tx_arb` (UDP 压 HLS) → `tx_arb` (TCP 严格优先)。
- **learn-on-RX (T3 闭合的 T2 缺口)**: peer 学习源 = `udp_split` 的 **meta 线束**
  (`meta_valid/meta_src_mac/meta_src_ip/...` = `udp_rx.meta_*` 的纯线束引出),
  接 `udp_tx_cfg.peer_wr`。**T2 的 CONN_UP 源已废弃** —— UDP 无连接, 板上永不产生
  CONN_UP ⇒ peer 表永不填 ⇒ TX 永不激活。⚠️ 已知语义边界: meta 在 w5 (头字段收全)
  脉冲而 FCS 到 TLAST 才知道 ⇒ **坏 FCS 帧也会被学入** (下一好帧覆盖; 门里有专项断言)。
- **演示 app** `rtl/app_udp_pattern.v`: UDP 版图案发生器 + 校验器 (xorshift64 / 种子
  `0x9E3779B97F4A7C15` / 先取后推进, 与 `peer.exe --udp-*` 逐字节一致)。
  RX 校验 **1 字节/拍 II=1 无缝** (1 字前瞻寄存器) ⇒ 天花板 = 1G 线速 (125 MB/s @125MHz);
  10G 需换 8 路并行 (8 步 xorshift/拍) ⇒ ⭐ **2026-09-30 已落地 (RATE 轮)**: TX 发生器与 RX 校验器
  **同批**改成 8 字节/拍 (`M^k` 常量 XOR 网), 但**包在既有宏 `P7B_10G` 内** ——
  **默认构建 (未定义该宏) 仍逐字是上面这条 1 B/拍路径**。TX 限速 = 帧间 `TX_GAP` 拍 (默认 58000 ≈ 24.7 Mbps,
  与 `peer --rate-mbps 20/25` 同量级), 超 `PLEN_MAX` 的帧冻结 LFSR 保住线上图案流连续。
  **默认不激活**: 无 peer (`udp_tx_cfg.o_ready=0`) ⇒ 零帧; `i_en=0` ⇒ 不校验。
- **配置** (wrapper): `udp_split.cfg_dst_ip` = 本板 IP / `cfg_port0` = 8081 (8080 由
  `EXCL_PORT` 排除留给 HLS udp_echo) / `cfg_port_any=0` / `udp_tx_cfg.cfg_my|dst_port` = 8081。

## 目录

| 路径 | 内容 |
|------|------|
| `rtl/` | 数据面 RTL (mac_rx_64/mac_tx_64/tcp_rx/tcp_tx_frame/tcb/tcp_cam/retx_ram/…) + `app_*.v` (P5 app 接口与演示 app) |
| `tb/` | xsim testbench (`tb_p4_chain` 全链 / `tb_p5_*` app 门与对抗集 / 各单元 TB) |
| `sim/` | xsim 工作目录 (每个门用**独立目录**, 避免 `xsim.dir` 文件锁; 见下"本工程新增坑" 7)。**canonical 门** = `sim/p4sim/` (P4 矩阵) / `sim/p5sim/` (P5 app 门) / `sim/p5close/` (P5c 定向证伪门) / `sim/p5d_multi/` (P5d 多连接门, 独立工作目录 main/neg_wq/neg_mgn/neg_mgn0/known_idle_fifo); 其余 `sim/p5b_*/`、`sim/p5c_*/`、`sim/p5bfix/`、`sim/f2chk/`、`sim/t1run/` 等是**复核/跑数产物目录**, 已 ignore (只保留其中的 `run_tb_*.bat` 与 TB 源码) |
| `tools/` | Python (anaconda: `/c/Users/zhxue/anaconda3/python.exe`) + `cpp_peer/` 合成 TCP 对端 |
| `board/` | `wrapper_p4.v` (顶层, APP_MODE 分支) / `uart_dbg.v` / XDC / 构建烧录 bat 与 tcl |
| `hls/` | HLS 慢路径 (`src/` 源码 + `tb/` 测试台跟踪; `slowstack_prj/` 与 `logs/` 是产物, 已 ignore) |
| `vivado_prj/` | Vivado 工程产物 (已 ignore); 位流 `p4_prj`/`p5_prj` 各一套 |

## 验证

> ⚠️ **本节所有命令一律在「本仓根」执行** = 含本 `CLAUDE.md` 的那一层 = `udp_hls_10g` 自己
> (它就是本工程的 git 仓库根)。**本节的门命令里不含任何绝对仓路径** (唯一例外是下面那行
> 示范性 `cd`, 它指向**本仓**) —— 门 bat 都已**自定位**, 两种口味:
> ① 自己从 `%~dp0` 反推 repo root + `p4gate.py selfcheck` tripwire (`sim\p5*`) ;
> ② 经 `sim\p4gates\p4env.bat` 统一解析 `REPO_ROOT` + `checkpaths` 守卫 (`sim\p4sim\*`)。
> 反推不到 / 路径越界 ⇒ `[PATHGUARD FAIL]` / `[P4GUARD FAIL]` 退出, 不会闷头编译别的树。
> 所以用**相对路径**调用即可。
>
> **为什么必须这样写 (真空门史)**: 本仓 2026-09-28 从 `D:\repo\ECO\udp_hls_10g` **整体拷贝**而来,
> 而那份拷贝源**至今仍然活着**。旧写法是 `cd /d/repo/ECO/udp_hls_10g` 再 `cmd //c`
> **那个仓的绝对路径**指向的是**另一个 checkout** ⇒ 跑起来
> **编译别人的源码、日志写进别人的仓、还 exit 0** = "空门"/真空门。全仓 364 个文件踩过
> (243 个真空门), 取证、三层守卫与负对照见 `P6B_INTEGRATION_REVIEW.md` §5 与
> `PORT_NOTES.md` P6b 收口 §⑤/§⑦。
>
> ⭐ **跑门一律走现役入口 `sim/p4gates/run_matrix_p4dfix.bat`** (自定位 + 路径守卫
> `checkpaths/manifestcheck/scanlog` + 修订指纹 + 每门独立工作目录), **不要再手抄单门 bat 的绝对路径**:
>
> ```bash
> cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'                     # P4 16 门全跑 (~25min)
> cmd //c 'sim\p4gates\run_matrix_p4dfix.bat' -only stallgate     # 只跑指定门 ('+' 分隔多门)
> cmd //c 'sim\p4gates\run_matrix_p4dfix.bat' -only chain+unit_vlan
> bash sim/p4sim/run_matrix_p4dfix.sh -only stallgate             # 同上的 git-bash 入口 (自定位 shim)
> ```
> ⚠️ **从 git bash 调用时, 开关必须用「短横线」拼法 `-only` / `-canonical`** ——
> MSYS 会把 `/only` 改写成 `"C:/Program Files/Git/only"` (2026-09-29 实测: `cmd //c echo /only`
> 打出来的就是那个路径)。`/only` 只在**纯 cmd 窗口**里可用; git bash 里也可以用
> `//only` (MSYS 的转义写法, cmd 收到 `/only`) 或直接用上面的 shim。
>
> ⭐ **2026-09-29 起: 那个被改写的开关会被 runner 硬失败 (exit 97) 而不是静默丢弃** ——
> 早先它是**不报错地跑满 16 门**(看着像"跑了很久, 判据没少", 实际你以为只跑一门)。
> 同源加固: `-only` 无值、以及 `-only <本文件未声明的门名>` (原来跑 0 门还 exit 0) 都改成 97。
> 理由: "静默干了别的"是本工程最贵的一类缺陷; 而且守卫一贯是**拒绝**而非警告
> (警告会重新落到"矩阵日志里没人读第 3 行"的老坑)。
> 退出码: `0` 全过 / `1` 有门失败 / `2` 跑动期间源码被改 (修订漂移 ⇒ 整轮作废) / `97` 前置拒绝。
> ⚠️ **跑门 ≠ 判门**: 16 门里 `unit_retx` / `unit_fifo` **无条件 `exit 0`**, 要读它们的日志尾 (原第 3 门 `unit_uart` 2026-09-29 已修: 判据行 `ALL_OK` 现进矩阵日志 + `FAIL:` 即硬失败 ⇒ 这一族只剩上面这 2 门)。

先在 git bash 里 `cd` 到本仓根 (任选其一; 下面的命令都是**相对本仓根**的):

```bash
cd "$(git rev-parse --show-toplevel)"   # 本仓根 = git 仓库根 (本仓即 udp_hls_10g 自己)
cd /d/repo/XCKU5PMini/udp_hls_10g       # 或直接给这个 checkout 的绝对路径
```

```bash
# P4 全矩阵 16 门 (默认构建回归; 改动数据面后必跑)
cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'      # 现役入口; sh 版 = bash sim/p4sim/run_matrix_p4dfix.sh
# P5 app 门 (APP_MODE)
cmd //c 'sim\p5sim\run_tb_p5_app.bat'      # 1MB 图案逐字节
cmd //c 'sim\p5sim\run_tb_p5_wrapper.bat'  # wrapper APP_MODE 全链 (接线错误只有它能抓)
cmd //c 'sim\p5sim\run_tb_p5_status.bat'   # 220 字符状态行
cmd //c 'sim\p5sim\run_tb_p5_adv.bat' reconn_fast   # 对抗集 (len/b2b/wnd/fin/findrop/abort/evfifo/reconn_fast/reconn_slow/multi/accmgn)
# P5b 流控闭环门 (独立单元门 + 全链慢消费者门)
cmd //c 'sim\p5sim\run_tb_p5_fc.bat'       # tb_app_fc: 池/右沿算术边界/回绕/事件撞车 (110 项)
cmd //c 'sim\p5sim\run_tb_p5_flow.bat'     # 512KB 慢消费者 + 对端灌数据 (占用/右沿/零重传)
# P5c 关闭语义门
cmd //c 'sim\p5sim\run_tb_p5_app.bat' close  # 关闭语义门 (FIN/RTO 重发/RST+fence/同时关闭/超时)
cmd //c 'sim\p5close\run_tb_tcp_close.bat' # 定向证伪门 (G1 FIN 重推死锁 / G9 回卷洪水)
# P5d 多连接门 (3 连接并发大流量 + 慢消费者 + 并发 close; 分池/动态裕度/物理界)
cmd //c 'sim\p5d_multi\run_tb_p5_multi.bat' main            # 判据 ①-⑨ (exit=0)
cmd //c 'sim\p5d_multi\run_tb_p5_multi.bat' neg_wq          # 负对照: 不分池 ⇒ ① FAIL (期望 1)
cmd //c 'sim\p5d_multi\run_tb_p5_multi.bat' neg_mgn         # 负对照: 裕度 4096 ⇒ ④ FAIL (期望 1)
cmd //c 'sim\p5d_multi\run_tb_p5_multi.bat' neg_mgn0        # 负对照: 裕度 0 ⇒ ⑦ FAIL (期望 1)
cmd //c 'sim\p5d_multi\run_tb_p5_multi.bat' known_idle_fifo # 长只写后首读逐字节守卫 (TB 激励竞争的常驻回归; 曾误判为 frame_fifo 预存缺陷)
# P5d 定向门 (单元级; 均需 -d APP_MODE)
cmd //c 'sim\p5d_d1\run_tb_p5d_d1.bat'     # D1: abort 请求窗 (rst_req) + 残余 F 项 ESTAB 状态门 + 释放
cmd //c 'sim\p5e_win\run_tb_p5e_win.bat'   # 0 载荷 opener 窄窗 (pipe 残余字跨会话 ⇒ 零负载泄漏)
cmd //c 'sim\p5c_t3\run_tb_p5c_fence.bat'  # abort fence 单元门 (F1-F5; D1 后判据不变、激励按真链路修正)
# P5e-T1 UDP 分流器单元门 + P5e-T3 UDP app 门 (自检式, 无 Python)
cmd //c 'sim\p5udp\run_tb_udp_split.bat'   # T1: 分流/反压/透传保真/坏帧整帧丢弃
# P5e-T2 UDP app TX 单元门 + 真 wrapper 门
cmd //c 'sim\p5e_t2\run_tb_udp_tx_guard.bat'    # T2: peer 门 / PLEN_MAX 守卫 (+ 内置负对照)
cmd //c 'sim\p5e_t2\run_tb_p5e_t2_wrapper.bat'  # T2: 真 wrapper 全链 (含 implicit DRC 检查)
# P5e-T3/T4/T5 UDP 演示 app 门 (独立目录; 4 个负对照 + 1 个"期望 FAIL"负对照)
cmd //c 'sim\p5e_udp\run_tb_app_udp.bat' pos        # 正例: 图案/学习/边界/突发 (exit 0)
cmd //c 'sim\p5e_udp\run_tb_app_udp.bat' splitoff   # 负: 拆分器关 ⇒ app 0 帧 + HLS 见 echo
cmd //c 'sim\p5e_udp\run_tb_app_udp.bat' portout    # 负: 端口过滤外 ⇒ 仍走 HLS
cmd //c 'sim\p5e_udp\run_tb_app_udp.bat' badcrc     # 负: 坏 FCS ⇒ 整帧丢 + stat_drop_crc
cmd //c 'sim\p5e_udp\run_tb_app_udp.bat' nopeer     # 负: peer 表空 ⇒ TX 零帧
cmd //c 'sim\p5e_udp\run_tb_app_udp.bat' neglearn   # 负对照 (**期望 exit 1**): 学习源钉 0
cmd //c 'sim\p5e_udp\run_tb_p5e_udp_wrapper.bat'    # T5: 真 wrapper 全链 UDP 收发 + DRC
# 板级: 同四元组重连验收 (D6)
C:/Users/zhxue/anaconda3/python.exe tools/pc_p5d_reconn_test.py --rounds 5 --gap 0.6   # 判别性轮间隔; 判据: 全部轮次建连+传输成功
# 构建与烧录
cmd //c 'board\run_build_p4.bat'    # 默认 (echo)
cmd //c 'board\run_build_p5.bat'    # APP_MODE (app 接口)
cmd //c 'board\run_program_p4.bat'  # / run_program_p5.bat
# 板级测试工具 (合成对端, 绕过内核栈; 先 fw_block.ps1 屏蔽内核)
tools/cpp_peer/peer.exe --iface '\Device\NPF_{...}' --bytes 16777216          # echo 吞吐
tools/cpp_peer/peer.exe --iface '\Device\NPF_{...}' --rx-only --expect-pattern 1048576  # app 图案校验
```

## 教训继承 (详见 ../udp_hls_eco/CLAUDE.md 与全局 CLAUDE.md)

- FCS 字节序 LSB-first; csim≠RTL — 本工程数据面纯 RTL, 以 **xsim + 板级 ILA** 为准
- bat 从 git bash 调: `cmd //c 'D:\path\x.bat'`; xvlog/xelab 库必须同用 `xil_defaultlib`
  (xelab 用全限定名 `xil_defaultlib.tb_x`); bat 行尾必须 CRLF
- 窄类型索引按最大 BASE+长度核算; 丢帧丢整帧; 关键 recipe 亲自逐行读源码

## 本工程新增坑 (P0 实战, 详见 PORT_NOTES.md)

1. **CRC 使能/初值必须与数据同拍 (组合逻辑)**: 寄存器化 en 会让 CRC 与字节流错位一拍
   (漏首字节 + 帧尾多算 IFG 字节)。排查法: 用 crc 终值反解实际字节流。
2. **FCS 残留魔数 = 0xDEBB20E3** (zlib 值小端线上字节序): 0xC704DD7B 是大端魔数, 勿用。
3. **TB 激励必须时钟化非阻塞驱动** (`always @(posedge clk) rx <= stim[i]`): 阻塞赋值+
   @(posedge) 循环与 DUT 竞争, 症状诡异且随背压模式漂移。
4. **AXIS 输出 = 组合 valid + 组合 rd + FWFT FIFO**: 寄存器化 rd 会让数据挂 2 拍被标准
   消费者双采 (每词重复)。
5. **移位量表达式禁用宽不匹配字面量** (如 `3'd8` 截断为 0): 左对齐用显式 case 拼接。
6. **脉冲型寄存器 (push_*) 每拍默认清零**, 否则跨帧残留污染。
7. **并行跑仿真必须用独立目录**: 残留的 `xsim/xsimk/xelab` 进程会占住 `xsim.dir`,
   后续门在链接期报 `Unable to remove previous simulation file` 而**假失败** (判据其实没跑)。
   门失败先 `tasklist | grep xsim` 排查是不是文件锁, 别急着改 RTL。
8. **模块级 TB 绿 ≠ wrapper 分支正确** (P5a 血的教训): `ifdef` 分支里的接线错
   (多驱动/未驱动/自环) 在子模块 TB 里完全隐身, 直到 Vivado DRC `LUTLP-1` 拦下 bitgen;
   即便绕过 DRC 也是丢字级故障。**每个 `ifdef` 构建配置都要有一个例化真 wrapper 的全链门**
   (`sim/p5sim/run_tb_p5_wrapper.bat` 是模板)。
9. **跨模块状态清理不能依赖轮扫时序**: 只在慢速扫描拍采到的条件 (如 `state != ESTAB`)
   在"两次扫描之间发生又消失"的事件上会漏掉 (P5a D1: 背靠背 DEL→ADD 让 `fin_sent_r`
   永久残留 → 数据面死锁)。**事件型状态必须由事件脉冲 (cfg ADD/DEL 收尾拍) 驱动清理**。
10. **接受门与启动门必须同门**: 若 `s_axis_tready` 的条件比"能否启动一帧"的条件宽,
   收进来的字会既不成帧也不被排空 → 填满 FIFO 死锁 (P5a D2)。
11. **新增模块"参数"后, 全链 TB 必须镜像 wrapper 的配置 (C12 扩展, 不只是端口连接)**:
   P5b 给 `tcp_rx` 加 `ACC_MARGIN` (默认 0) 后, APP_MODE 的全链 TB 忘传 4096 ⇒
   **门与板跑的是两个配置**, 假故障看着像 DUT 缺陷 (79 丢弃 / 75 重传 / 256B 失配),
   补齐参数后同一次仿真三项全归零。加参数时除 `grep -rn "<module>" tb/ board/` 补端口外,
   还要核对每个例化点的**参数值**是否镜像了 wrapper 的 ifdef 分支取值。
12. **组合算术串一条链 = 时序致命; 先等价化简, 再拆流水**: P5b 扫描块
   `winq → fq → redge_n → sdelta → wcalc → wu_mark` 全组合 ⇒ **37 级逻辑 / 22 CARRY4 /
   WNS −3.089 / 4027 失败端点**。修法优先级 ① **等价化简** (证出 `wcalc ≡ fq` 的逐位恒等,
   砍掉三级算术) ② **拆流水** (扫描周期 256 拍、中间大量空闲 ⇒ 流水免费)。
   **流水 valid 位必须每拍默认清零** (同坑 6 的脉冲铁律), 否则 stage B/C 每拍重放陈旧 item
   ⇒ 连拍狂发/池被抽干 (P5b 最大自伤)。
13. **多级流水/扫描必须对"事件同拍撞车"让位**: 事件块在前、流水 landing 在后 ⇒ 同槽事件
   落在流水窗口内必须丢弃该 item (采样拍守卫 `!(ev_blk && ev_slot==scan_id)` + stage B/C 的
   `hit_b/hit_c` 比较), 否则用旧会话数据毒化 `redge/fc_pend/wu_pend` ⇒ 记账偏离 (C17)。
14. **跨会话状态一律事件脉冲清, 且"确实落地才清"**: 条件清理会漏 (坑 9); 而"清位"≠"落地"
   —— P5c F3: `st_pend` 被无关的 fc `gnt` 吞掉而标志已清 ⇒ `state=0` 写永久丢失。
   清理条件必须绑定"本次落地的是不是这个写" (`fc_sel_r==5`)。
15. **关闭/拆除类判据必须查线上帧 + 资源归还, 且超时要带对端活性**: `rst_req` 挂了 ≠
   RST 发出 (触发同拍挂 `state=0` ⇒ `rb_state==1` 门关闭 ⇒ **结构性发不出**, P5c F2);
   超时判据不能只看本地 (`fin_sent && ESTAB`) —— 合法半关闭的 4MB 会被 400ms 全丢
   (板级实测 PC WinError 10053)。**活性 = 该槽 `rcv_nxt` 连续 N 轮未推进**。
16. **板级工具四坑 (全是"判据全过却报 FAIL / 报假数据")**: ① GBK 控制台下 print 非 ASCII
   抛 `UnicodeEncodeError` ⇒ **退出码变 1** (按 exit code 判 PASS 的自动化误报 FAIL) ⇒
   脚本开头 `sys.stdout.reconfigure(encoding="utf-8", errors="replace")`; ② 解析函数定义了
   必须真的调用 (`parse()` 漏调 ⇒ AttributeError); ③ 与板侧有超时窗口的脚本, 耗时准备
   (图案生成 1.13s) **必须先于 connect** (否则板侧 400ms 关闭超时先到, 连接被拆);
   ④ 计数口径写清 fast path 还是线上 —— `FI` 只是 fast path FIN 计数, 慢路径 HLS 另发
   FIN+ACK ⇒ "一次 close 恰 1 帧 FIN" 在线上的判据不成立。
17. **TB 激励的 0 延迟竞争 (坑 3 的一般化, P5d 抓到的最隐蔽一条)**: 脚本进程用
   `@(posedge clk)` 恢复执行时**阻塞赋值**到 DUT-facing 信号 (或其组合前级) ⇒ 该信号在
   **时钟沿同一步**变化 ⇒ 同一步内不同进程采到不同值 (xsim 进程序决定谁赢)。
   `22: sink_rate = sa;` 阻塞写 ⇒ readiness 组合变 ⇒ `frame_fifo` 的组合读址沿后变化而
   rptr 寄存器采沿前值 ⇒ BRAM 提前一字 ⇒ 下游呈现"丢/重 1 个字"的 8B 错位, 看着像模块缺陷。
   **危险的是方向无关** —— readiness **任意方向**的同拍变化都触发 (0→1 同样破)。
   修法 = 分级非阻塞落地 (脚本只写 `*_rq_*` 请求, 下一沿非阻塞转正)。
   **定位法**: TB 侧影子写流**逐拍断言读侧恒等** (`dout(N) === mem[rptr(N)]`) ⇒
   `checks=263674 bad=1` 且那 1 拍恰在 readiness 变化同拍 ⇒ 一秒定案 (vs 猜 RTL 几天)。
18. **判据要有判别力: 选"只有修复后才成立"的量** (P5c/P5d 各踩一次): ① 板级"4MB 用例 `RS`
   必须为 0"**不可达且无判别力** (drain 静默窗口必然产生良性 RST, 旧位流同样给
   `RX=0x400000`); ② A/B 的"判别性变体"在**默认轮间隔**下两版不可分 —— 轮周期 (~5.5s) 晚于
   缺陷的 **RTO 自释放**窗口 (~2-5s) ⇒ 必须把轮间隔缩到自释放之前 (`--gap 0.6`) 才得到
   `15-23ms vs ~1.0s`。**造判别性实验前先算清"缺陷的自愈时间尺度"**。
19. **"窗口不可撤销" ⇒ 上限必须提前设小, 且只能做成寄存器 (不是 wrapper 参数)**:
   通告窗一旦发出收不回 (降窗会让在飞段被拒), 所以多连接的分池只能在**建连之前**由 app 写
   `app_ctrl` `0x0C`; 做成模块参数会强制**所有 TB 镜像取值** ⇒ 漏一个就是"门与板跑两个配置"
   (坑 11)。寄存器化 + 复位默认 = 旧值 ⇒ 不写 = 零回归, 不破任何既有门。
20. **修复会曝光既有隐患 (改一处, 另一处才显形)**: D1 把 TX 启动门做实之后
   `app_pattern`/`axis_pipe` 的**跨会话残余字**才显形 (帧边界上 pipe 里的下一帧首字跨过
   DEL→ADD 就被当新会话首帧首字收下 = 8B 旧载荷 + 整段图案偏移) ⇒ 用 **0 载荷 opener**
   (`tkeep=0`, 帧器只按 `pop8(keep)` 计长 ⇒ 不入 FIFO/不进 ring/不推进 seq) **结构性**根除,
   代价 1 拍/帧。**推论**: 硬化一条门之后必须重跑跨会话/换流场景, 别假设"门修好了就没事了"。
21. **TB 里的以太网字节序/拍对齐错了, 症状会指向错误的模块 (P5e-T3 实测两条)**:
   ① **IP 校验和是网络序 (大端)** 的 16 位字段 —— 写成小端 ⇒ `udp_rx` 判
      `stat_drop_ipcsum`/nonmatch, 看起来像"拆分器过滤不匹配" (真根因在 TB 的 4 个字节);
   ② 往 GMII 注入帧时**帧尾多挂 1 拍 `dv=1`** ⇒ 多算 1 字节 ⇒ FCS 残差不对
      (`mac_rx.stat_crc_err=1`), 看起来像"FCS 算错"。
   定位法 (两步定案): 先 **CRC 自检** (`crc32("123456789")==0xCBF43926`) 排除算法,
   再看 `mac_rx.stat_bytes` 是否**恰等于** 帧长 (多/少 1 就是拍对齐; T2 期 1519 vs 1518)。
22. **force 的层次名必须与 wrapper 里的线名逐字一致; TB 声明顺序同 RTL** (xvlog 先声明后用):
   T2 的 wrapper 门改用 meta 线束时踩到 —— `udp_meta_smac`(顺手缩写) 与 wrapper 实际
   `udp_meta_src_mac` 不一致 ⇒ xelab 报 "not declared under prefix"; TB 里被 task 引用的
   `integer` 声明在 task 之后就编译不过 (与 RTL 同一个坑)。
23. **被下游中止的帧必须冻结图案 LFSR**: app 侧"帧内中止"(如 >PLEN_MAX) 的字节若照常推进
   LFSR, 线上图案流就留一个空洞 ⇒ 对端连续校验必然失配 (且失配点远离真因)。
   `app_pattern.bad_frm` / `app_udp_pattern.pay_ok` 都是"冻结 + 常数填充"这同一手法。
24. **"漏声明 = 隐式 1 位线"是传统检查抓不到的一类错 (坑 8 的第二种表现, P5e-T2 实测)**:
   忘声明一根内部线 ⇒ Verilog 隐式 1 位网线 ⇒ 64/8 位连接**静默截断**, 高位 = Z ⇒
   `mac_tx` 收到 Z 填充字 ⇒ `cw_len = popc8(Z) = X` ⇒ **永久卡 `S_DATA`**, TX 全线死。
   `multi/driv/unconnected` 三类检查**都不报** ("implicitly declared" 不在它们的检查项里),
   子模块 TB 也全绿 ⇒ **只有真 wrapper 全链门能抓到** (P5e-T2 就是这样抓到的)。
   ⇒ 门里必须把隐式网当**硬失败**。
   ⚠️ **2026-09-29 订正 (P7B 实测)**: Vivado 2025.2 **不再打印 `implicitly declared`** (实测全部日志命中 0) ⇒ 旧关键字是**哑门**。Vivado 2025.2 的真实签名分两种形态、**两个不同检测点**: ① 端口连接形式 (静默截断) —— **xvlog 一个字都不打印** (exit 0、日志全空, `-sv` 也一样), 只有 `xelab` 报 `WARNING: [VRFC 10-3091] actual bit length 1 differs from formal bit length 64 for port 'q'`, 或 `synth_design` 报 `INFO: [Synth 8-11241] undeclared symbol 'mid', assumed default net type 'wire'`; ② 表达式形式 —— `xvlog` 报 `ERROR: [VRFC 10-2989] '<name>' is not declared` (synth 用 `8-36`)。⇒ **只 grep xvlog 日志的门结构性地拓不到本坑 —— 换任何关键字都不行, 必须补 `xelab`/`synth_design` 这一面** (现役两处 lint 入口 `board/run_lint_p6e.bat` / `_proj_10g/tcl/run_lint_p7a.bat` 已补, 各 +12 s / +24 s)。 **推荐键表 (5 键, OR 语义)**: `Synth 8-11241` · `undeclared symbol` · `VRFC 10-3091] actual bit length 1 differs from formal bit length` · `VRFC 10-2989` · `implicitly declared` (末者只为 2025.2 之前的工具保留, 在 2025.2 下恒 0)。 ⚠️ **`10-3091` 必须带上 `] actual bit length 1 differs from formal bit length`**: 裸 `VRFC 10-3091` 会命中 `board/util_gmii_to_rgmii.v` 的 **14 处良性 unsized 字面量** (`.CE(1)`/`.D1(1)`/`.D2(0)`/`.R(0)`/`.S(0)`, 报 `actual bit length 32 differs from formal bit length 1`) —— 默认 (K7) 配置每次 xelab 都报, 当硬失败就是天天误伤。隐式网**必然是 1 位** ⇒ "actual = 1" 就是本坑的精确签名 (收窄后仍抓住病理件 A1)。 **刻意排除的键 (都有实测假阳性)**: `8-7129`/`unconnected or has no load` (命中干净件的**合法未用端口**)、`8-6014`/`8-3917` (纯优化提示)、`VRFC 10-3645`/`remains unconnected` (xelab 侧对偶 —— 干净的真实 P6e 设计一跑就 **20 条**)。 ⚠️ **裸 `findstr /C:"10-3091"` 那一族"位宽不符"判定结构性常哑**: 语料实测 `10-3091` 在 **869 份 xvlog 日志中 0 命中**、452 份 xelab 日志中 173 份命中 ⇒ **凡 grep `xvlog_*.log` 的裸 `10-3091` 判定永远不会触发**。 ⚠️ **历史事实**: `IMPLICIT-DECL-FAIL` / `BITWIDTH-MISMATCH-FAIL` 在**全仓留存日志里 0 命中** ⇒ 无任何证据表明这两条门**曾经**响过 (严格措辞: "没有留存日志含这些标记" ≠ "从未失败")。  ⭐ **2026-09-29 收尾 (P7B 尾巴)**: ① 铺开时那条真阳性**已实测并修掉** —— `tb/tb_p5_app.v` 用未声明的 `tx_fsm_state_w` 驱动 3 位 `dbg_state`/`fsm_state` (xelab 报 2×`10-3091 actual bit length 1 ... 3`), 修 = 补 `wire [2:0] tx_fsm_state_w;`。 ⚠️ **污染面已核实 = 无**: 该网的唯一消费者是 `app_status_uart` 的状态行, 而 `tb_p5_app.v` 里 `uart_txd` 从未被解码 (状态行判据在另一门 `run_tb_p5_status.bat`/`tb_p5_status.v`, 那里的 `fsm_state` 是真 3 位), 板级路径 `board/wrapper_p4.v:558` 本就声明了 `wire [2:0] tx_dbg_state`。 ② **`sim/p5sim` 一族门当时并没有这条判据** (铺开报告的"它会正确地失败"是推定, 实测是 exit 0) —— 已补 xelab 面判据。 ③ "只打印不失败"的门已全部改成硬失败: `sim/p6b_lint/{lint,lint_def}.bat` · `sim/p6a_ku5p/pf/run_preflight.bat` · `audit_scratch/run_t{1,2,3,4,9}.bat` · `sim/snapcdc/review24/lint/run.bat` (负对照: 合成病理输入 ⇒ 非零退出)。 ④ `run_preflight.bat` 的既存缺陷已修: 它 HLS 先/rtl 后 ⇒ 手写 `rtl/udp_echo.v` 赢库 ⇒ elaborate 必失败 (19×`VRFC 10-3180 cannot find port`); 现改成 rtl 先/HLS 后 + 文件表改为与权威 lint 同款 glob (旧 `rtl_files.f` 还缺 4 个 P6b 文件)。取证 (2026-09-29 尾巴轮) = `_proj_10g/notes/p7b_tail/logs/` (16 门矩阵回归、各门负对照退出码、cmd 退出码传播形式测量)。 规范检测器 = `sim/p4gates/implicit_gate.bat` (+ `implicit_gate_selftest.bat` 九项对照)；取证 = `_proj_10g/notes/P7B_IMPLICIT_GATE_FIX.md` (修复) + `_proj_10g/notes/P7B_IMPLICIT_GATE_ROLLOUT.md` (铺开 + 语料级假阳性验证)。
25. **"这东西从哪来"要单独测 (缺口逃逸的典型)**: P5e-T2 把 UDP TX 的 peer 学习源接在慢路径
   `CONN_UP` 上 —— **UDP 无连接 ⇒ 板上永不产生 CONN_UP ⇒ peer 表永远空**: T2 的"默认不发送"
   在板上退化成"**永不发送**"。而 T2 的单元门与 wrapper 门**都靠 `force` 灌 peer 事件才绿**
   (两门都测"注入了 peer 之后会发", 没测"peer 从哪来") ⇒ 缺口从两条门里逃逸。
   ⇒ 每次用事件/表项驱动一条通路, 必须**单独有一条门回答"生产者是谁、板上会不会产生"**
   (P5e-T3 的 `neglearn` 就是这条: 学习源钉 0 ⇒ 正例判据必然不成立, **期望 exit 1**)。
26. **近似时序门的绝对值不可跨流程比较 (P5e-T3)**: 私有 route 门
   (`sim/p5e_udp/route_check.tcl`) 报 **WNS +0.123**, 官方 `launch_runs` 构建报 **+0.290** ——
   差异**不是布局方差**, 而是**流程差异**: 该脚本 `set_property strategy` 之后**手动**
   `opt_design/place_design/route_design`, **从未 `launch_runs impl_1`** ⇒ **strategy 未生效**,
   且**缺 `phys_opt_design`**。⇒ 快门的族序/相对结论可用, **绝对值只能当参考**;
   要绝对值就走 `launch_runs` 全流程 (否则会比官方口径**悲观 ~0.17ns**, 容易被误读成"改坏了")。
