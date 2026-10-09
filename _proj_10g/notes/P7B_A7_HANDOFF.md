# P7B_A7_HANDOFF —— 下一轮开工入口（2026-10-10；**本件读法优先于 `P7B_LONGSEND_HANDOFF.md` 与更早各件的"板上现态 / 下一步"部分**）

> **为什么新开一件（而不是续写 `P7B_LONGSEND_HANDOFF.md`）**：上一件 §5 的"下一步精确选项"（B-1 = 补三个计数器 /
> B-2 = A-minus 臂）**已被本轮部分执行**（B-1 的两个计数器 `W65`/`W66` 已随构建 D/E 上板并取到读数），
> 且本轮换了**现役位流**（A 臂 → 构建 E）与**取数器默认值**（`EXPECT_BID 0x16 → 0x19`）——
> 续写会把"已执行的选项"与"新选项"混在一份件里。⇒ 按本工程既有惯例**新开一代入口件**，
> 在旧件顶部只留一条订正指针（不动旧件正文，满足"读数与脚本对得上"）。
>
> 三条纪律不变：**只走 JTAG 易失烧录（绝不写 QSPI）** · **绝不 `git add -A`** · **改 RTL 与"在跑回归"互斥（全局 #57）**。
> 轮级原件 = `p7b_build_a7/READINGS.txt`（构建 D）· `p7b_buildE_build/READINGS.txt`（构建 E）·
> `p7b_a7_board_20261010/`（板级 D 轮）· `p7b_buildE_board_20261010/`（板级 E 轮：含 A3 板级回合）。

---

## 1. 板上现态（**接手第一件事：核它，别信任何旧文档**）

| 项 | 值 |
|---|---|
| 位流 | **构建 E**（帧器侧窗口门计数 `stat_winstall`→W66 + A3 重连修复 + 快照 67 字）· sha256 **`b88b2beee1650a9ecdfd1196b01d9e84422374ea2a168dd1bb54bc7ceb05a64f`**（15,431,261 B · `SW_CRC 82424462`） |
| 板侧身份 | `0x04 = 0x00000019`（**BID 0x19**）· `0x00 = 0x50360001` · **67 字**窗口 · 未实现地址 **`0x12C`** 回 `0xffffffff` |
| 停流门 | **`0x08 = 0`（未受控停流）· `carrier = 1`** |
| 时序 | `WNS +0.090 / WHS +0.010 / 三类失败端点 0/0/0`（`p7b_buildE_build/READINGS.txt` 步骤 2.3） |
| 身份读数出处 | `p7b_buildE_board_20261010/FINAL_STATE.txt`（`FINAL_BID=0x00000019` / `FINAL_SCRATCH_0x08=0x00000000` / `FINAL_CARRIER=1` / `LnkSta x4`） |

> ⚠️ **旧句按"历史"读**：`P7B_LONGSEND_HANDOFF.md` §1 的"板上现态 = A 臂（BID `0x16`）"、
> `P7B_LOOP_HANDOFF.md` §6 与 `udp_hls_10g/CLAUDE.md` 各处写的"受控停流 / S3 / r6-fix"全部是更早两轮的态。

## 2. 位流对照表（五档；⛔ **全部 15,431,261 B ⇒ 只有 sha256 与 BID 能分版**）

| 位流 | BID | WNS / 三类失败端点 | sha256 | 用途 / 备注 |
|---|---|---|---|---|
| **E（现役）** | **`0x19`** | `+0.090 / 0/0/0` | `b88b2beee1650a9ecdfd1196b01d9e84422374ea2a168dd1bb54bc7ceb05a64f` | 本轮第 2 档：W66 + A3 修复 + 快照 67 字；`p7b_buildE_build/E/wrapper_p4.bit` |
| **D** | `0x18` | `+0.099 / 0/0/0` | `edb6dcb8288bd16fb435aaf10a9f73757fe94cf99e663cce2a869e334090a3f0` | 本轮第 1 档：R-1 重定时 + 退尾字 carry + W65 + 66 字；`p7b_build_a7/D/wrapper_p4.bit`（= E 轮 A/B 的负对照臂） |
| **C** | `0x17` | `+0.006 / 0/0/0` | `5fff2be847b36eeca48c2290fa799fdad555bcea547514ee33355717dcb32253` | GAP9-TX（尾字 carry 开）；`p7b_build_gap9/C/`（⛔ 板级结论 = 零收益，见 §6） |
| **A** | `0x16` | `+0.021 / 0/0/0` | `052c52006215a2c3d5f9d59f8c47e620e41eb20f271fbc09dabfff96330bc284` | LONGSEND TCP 连续；`p7b_build_longsend/A/` |
| **S3** | `0x15` | `+0.052 / 0/0/0` | `492c35797eabed33e9ba8d529a622c287aa7d164daebeff5eb2d29655a0dc42c` | 长流刀定档；`p7b_build_longflow/S3/` |
| （更早，仍在盘） | `0x11` | — | `8c8b6126…d5baf5` | r6-fix：`p7b_retxfix_salvage/bits/8c8b6126__wrapper_p4.bit`（⚠️ 同目录 `burn_r6fix.bat` 内部仍指已删旧树，**别直接跑**） |

五档 WNS 轨迹 = S3 `+0.052` · A `+0.021` · C `+0.006` · **D `+0.099`** · **E `+0.090`**（逐档出处 = 各档自己的 `READINGS.txt` 步骤 4 表）。

## 3. 重烧配方（本机）

```bash
# 判据 = stdout 有本次的 "End of startup status: HIGH" + 文件 mtime 是本次 + 烧后板侧 0x04 回读
MSYS_NO_PATHCONV=1 TCPREG_BIT='D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_buildE_build\E\wrapper_p4.bit' \
  cmd /c 'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_biz_tcpreg\run_program_tcpreg.bat'
```
⚠️ **`cmd /c` vs `cmd //c` 是条件式陷阱**：**没加** `MSYS_NO_PATHCONV=1` 时 `/c` 会被 MSYS 改写成 `C:/` ⇒ **bat 根本没跑**、
stdout 是上一 session 的陈旧件。判据必须是 **stdout 里的本次 `HIGH` 行 + mtime**。
⚠️ `run_program_tcpreg.bat` 的 `TCPREG_PROG_EXIT=0` **不在 stdout 文件里**（重定向之外）⇒ 拿它当判据 = 假红。
**PCIe 恢复**：烧后设备级 `remove`+`rescan`（`0000:02:00.0`）；若开机时板跑的是厂商设计（QSPI，`1 BAR`）⇒ **连根端口 `00:1c.0` 一起**；
判别式 = `identify_bars`（`2 BARs: config 1, user 0` = 我们的）。
本轮烧录原件 = `p7b_buildE_board_20261010/burn/`（E 臂 **2 次** + D 臂 **1 次**回烧：`burn_E_20261010_065707` / `burn_E_…071418` / `burn_D_…070815`，各配 `id_*.txt`）
+ `p7b_a7_board_20261010/burn/`（D 臂 **2 次** + C 臂 1 次负对照：`burn_D_…044912` / `burn_D_…050928` / `burn_C_…050041`）。

## 4. 身份/快照读法（对端机）

```bash
# 取数器默认值**本轮已随构建 E 更新** = NW=67 / EXPECT_BID=0x00000019 / 未实现地址 0x12C
bash /tmp/p7b_biz/p7b_snap.sh id                            # ID_OK + ID_UNIMPL 回 0xffffffff（0x12C）
bash /tmp/p7b_biz/p7b_snap.sh snap TAG 5 20 43 51 63 64 65 66   # 短表（长流必须短表：12 字 ~288 ms > 整条流）
```
⚠️ **读旧位流必须显式覆盖**（`NW=66 EXPECT_BID=0x00000018` = 构建 D；`NW=65/0x17` = C；`NW=63/0x0A` = Stage C）。
⚠️ 每次读数自证 `gen` 恰 +1；`0xffffffff` = SLVERR（不是数据）；**绝不能挑 ≥ `0x200`**（7 位译码回绕到 word 0 = MAGIC ⇒ 假 FAIL）。
⚠️ **`W51` 跨连接累积**（同一次烧录内不归零）⇒ "流内点"判据的基准必须用**该跑 `pre` 快照**的 W51。
⭐ **`W66` 是新字**：`tcp_tx_frame.stat_winstall` = "帧器站在数据帧启动点 + 呈交口有字 + `start_data` 其余每一项都开、
**唯一关着的是 `wnd_open`**"的停拍计数（谓词 = `rtl/tcp_tx_frame.v:581`（OVL 分支）/`:1429`（非 OVL））；
语义边界 = 该处权威注释（`/I/` 与 IFG 不算；`m_axis` 反压排掉）。

## 5. 环境恢复五项（关机/重启后必做；原件 = `p7b_env_restore_20261009/`）

1. **对端网络前置**（每次现取，别信上次）：`ip addr add 192.168.100.100/32 dev enp1s0f1np1` +
   `ip route add 192.168.100.2/32 dev enp1s0f1np1` + **`nmcli device set enp1s0f1np1 managed no`**（根治 NM 静默冲 `/32`）；
   然后 `ip route get 192.168.100.2`（必须**不走 WiFi**）+ 读 `carrier`。
2. **台架重部署**（`/tmp` 会被清）：`04_deploy.txt` 的 27 件逐件 `--put`，再 `05_remote_md5.txt` 逐件核 md5。
   ⭐ **本轮有更新件**：`p7b_snap.sh`（新默认 NW=67 / EXPECT_BID=0x19 / W63..W66 名字齐）
   —— 部署自证原件 = `p7b_buildE_board_20261010/STEP0_selfcheck.txt`（部署后 md5 **`ec4e4b252ae30164fd79702de3e1eded`**，
   并逐字打印生效默认值三行 + NAME 表 W63..W66 四行）。
   ⚠️ `lf_dl.sh` 本轮回合**未变更**（md5 `8c8301aacc95ae5dc8760ef121def26c`，与 `_tools/lf_dl.deployed.sh` 相同）。
3. **重编 8 个二进制**（`06_compile.txt` 的形状；命令以 `p7b_affinity/BUILD.md` 为准 —— 树里三条编译行互相打架）；
   `p7b_tcp_sink` 部署件 md5 **`c6b624205d64f1f4bd723d8fd5cc6414`**（169,392 B，带 `SINK_LIMITS` 见证行）。
4. **5 项工具自检**：`p7b_selftest.sh` · `p7b_dualthread_selftest.sh` · `p7b_lane8_selftest.sh` · `aff_selftest.sh` · `pcap_off_dryrun.sh`。
5. **板卡侧**：重烧（§3）+ PCIe 恢复（§3）+ XDMA 驱动 probe/insmod 直到 `/dev/xdma0_user` 出现；
   **对端网卡中断合并按口径**：跑长流必须 `ethtool -C enp1s0f1np1 adaptive-rx off rx-usecs 0`（#68 的"读数低第一主因"）；
   本轮收尾态 = **off**（`FINAL_STATE.txt` 的 `FINAL_COALESCE: Adaptive RX: off / rx-usecs: 0`）。
   ⚠️ 环境里还有两个静默杀手：NetworkManager（冲 `/32`）、`irqbalance` 应为 inactive。

## 6. 本轮两条核心结论（一页；逐条带出处）

1. ⭐ **设计件手数 193 精确无误，`P` 的差额 100% 是线空闲**（三步独立复现；构建 D 的 `W65` = `mac_tx_10g.stat_tx_idle`）：
   `ΔWnonidle/ΔW20 ≡ 192.9999`（三次跑 + **每个逐区间**，恒定到 1e-4）⇒ **MAC 服务时间恒 193.000 拍/帧**；
   `ΔW65/ΔW5` = **3.16% / 21.19% / 23.25%**、`ΔW65/ΔW20` = **6.30 / 51.90 / 58.45 拍/帧**
   （出处 = `p7b_a7_board_20261010/runs/{FINAL_TABLE.txt, DERIVE.txt}`）。
   ⇒ ⛔ **此前"设计件手数少了 ~7.4 拍"的说法作废**（差额是一个从来没人计过的独立量，不是手数错）。
   **空载正对照**：`ΔW43 = ΔW65 = 160,307,432` 逐位相同（比值 1.000000000；`D_idle_control.txt`）。
2. ⭐⭐ **线空闲里 ~88–90% 是【窗口】**（构建 E 的 `W66`）：板级三跑 **`ΔW66/ΔW65` = 0.876 / 0.899 / 0.881**
   （逐区间中位 0.875 / 0.913 / 0.881；出处 = `p7b_buildE_board_20261010/runs/{FINAL_TABLE.txt, DERIVE.txt, CORR_IDLE_W66.txt}`），
   跨 **5.7–9.3 Gbps**、跨空闲占空 **2.1%–39.4%** 都稳定 ⇒ **窗/BDP 就是那堵墙**（不是帧器流水、不是 app 生产节奏）。
   **白送负对照** = 无连接 2 s 窗里 `ΔW65 = 318,344,982`（自由计数）而 **`ΔW66 ≡ 0`**（`A3_RECON.txt`）。
   ⚠️ 约 **12%** 的线空闲**不归窗口门**（补 = 1 − 0.876/0.899/0.881），按实现轮登记的盲区（`ΔH` 无计数器）**不许逐拍归因**。
3. ⭐ **R-1 是本轮最实的一刀（但归因受限）**：把 `ctrl_tcpcsum`/`ctrl_ipcsum` 的装载**推迟 1 拍、改从已寄存的 `ctrl_*` 字段复算**
   （+1 FF）⇒ **WNS `+0.006 → +0.099`**，**旧锥 `ctrl_tcpcsum_reg[*]/D` 整体退出报告面**（C 档出现 27 次 → D 档 0 次）。
   ⛔ **不许写"时序问题已解决"**，**不许把改善单独归因给 R-1**（D 捆绑三项改动、**无拆刀 A/B**）。
   ⚠️ E 档 WNS 宿又换对象（`u_app/stg_reg[4]/D`）；**新计数器是否加深该锥 = 未定论**（照抄构建 E `READINGS.txt` 步骤 2.4 的口径）。
4. ⛔ **一条被否掉的路线（否定结论）**：**尾字 carry**（Gap #9 的 TX 半边）**零收益** —— 高码率档 fps 中位
   **784,742 vs 负对照 785,558（−0.104%）**、两臂区间峰值同为 **`802.7–802.8k fps`**
   （后半句出处 = 构建 D 退回理由块 `board/wrapper_p4.v:1202`；逐跑区间峰值全表 = `p7b_gap9_tx_board_20261010/runs/FINAL_TABLE.md` 末行），
   却把 WNS 从 0.33% 吃到 0.094%
   ⇒ **构建 D 已退回**（`.TX_TAILCARRY(1'b0)`，一行；`board/wrapper_p4.v:1197-1208`）。
   ⭐ 同批**证伪"app 生产节奏是瓶颈"**：该臂把 **app 下游的 TX CDC FIFO（`u_txcdc` = `tx_arb`→`mac_tx_10g` 的异步 FIFO，
   `board/wrapper_p4.v:2748`）喂到满**（`W28 = 256` = 满深度、`W45` 拒写 **≈5.6×10⁷–6.1×10⁷ 拍**；
   出处 = `p7b_gap9_tx_board_20261010/runs/FINAL_TABLE.md` 与同目录 `G9C*` 原始件）而**帧率一点没涨** ⇒ **约束在下游**
   ⇒ **整条"提高 app 产字率"的路线（含 8 路发生器）关闭**。
   （⚠️ 文档轮口径核实：`W28`/`W45` 量的是 `u_txcdc`，即 **app 下游的最后一级队列**，不是"app↔帧器"那一级；结论方向不变。）
5. **A3 修复**：连续模式下"对端关闭 → 同槽重连"时 `ev_up` 脉冲被吞 ⇒ 新连接静默零数据、无自愈；
   判别变量 = "`ev_up` 到达时是否仍卡在 `closing`"，**不是间隔 k**。修法 = `up_pend_r`/`up_pend_id` 待补登记位
   （`rtl/app_pattern.v:384-385` 声明 / `:503-505` 补做 / `:784-790` 置清）。
   **板级：5/5 重连回合第二条连接照常收数据**（A3E 三回合 `bytes2` = 1,517,494,075 / 1,576,631,375 / 1,652,378,950；
   A3T 两回合 = 1,034,765,805 / 1,475,338,035；原件 `p7b_buildE_board_20261010/runs/{A3E.txt,A3T.txt,A3_RECON.txt}`，
   每回合 `all_rounds_bytes2_positive=YES`）。
   ⚠️ **"pending 补做路径真被触发过"未证**（阳性只证症状不出现）；**本轮也没做同会话负对照**（A3 全部板级回合都跑在 E 位流上，`a3_round*.sh` 无 D 臂）。
   ⛔ **文档轮订正（重要，别照抄旧理由）**：E 轮 A3 脚本里写的"负对照做不到（D 档也含 A3 代码）"**与源码不符** ——
   构建 D 的 `rtl/app_pattern.v` sha256 `387a7d94…`（与 C 档逐字相同；`p7b_build_a7/READINGS.txt` 步骤 0）⇒ **D 不含 A3 修复**
   （A3 修复 = E 档 `811a84e4…`；`p7b_buildE_build/READINGS.txt` 步骤 0 + §交付-2）；
   **第三重证据（现核）**：`sim/p7b_longsend/run_cont_gate.bat:71` 自己就把冻结锚写成 `G frozen anchor … (expect nonzero: pre-A3 anchor)`，
   且该锚文件 `sim/p7b_stagec_tx_regress/frozen/app_pattern_rev0e804099.v` 里 `up_pend_r` = **0 次**（活件 = 10 次）⇒ **pre-A3 = 不含修复**。
   ⇒ 准确说法 = "**没做**"而非"做不了"，
   且 **D 位流（BID `0x18`，仍在盘）是 A3"改动前负对照"的候选**（⚠️ 严格说 D↔E 之间是**两处**差异：A3 修复 + W66 纯观测计数器
   —— 后者按语义不该改行为，但那是论证不是测量；E 轮已把冻结锚 arm G 按同一逻辑钉成改动前负对照，见 `p7b_buildE/apply_contgate.py` 头注释）。

## 7. 下一步的精确选项（**决策权在用户**）

1. ⭐ **判"窗口门的哪一侧在咬"**（把"~12% 不归窗口"与"窗口本身的成因"分开）——
   现在已知线空闲 ~88–90% 归窗口门（`W66`），但**子成因未分离**：**对端通告窗 vs 板 `WIN_CAP`(= `RING_CAP` = 61440)
   vs RTT/BDP** ⇒ 在帧器眼里**同形 `wnd_open=0`**。分离手段：
   (a) **对端侧同位素臂**（只压/放大对端通告窗 = 零构建；⚠️ 上一轮的该臂**落在未贴窗的低档 ⇒ 无判别力**，
   本轮必须先把读数推到**贴窗档**再压）；(b) 板侧换 `WIN_CAP_5` 档（= 下面的 A-minus 臂）。
   判据 = 贴窗档上 `ΔW66/ΔW65` 与 `ΔW65/ΔW20` 的变化（分子分母必须写清）。
2. **A-minus 臂（构建 B-2）** = `TX_CONTINUOUS=1` + `WIN_CAP_5` 回 `0xBFFE`，与 A/E 臂做**同长度长窗** A/B ——
   **唯一能给"窗帽 49150→61440 有无收益"干净判决的构架**；回退点 = 改一行（`board/wrapper_p4.v:227`）。
   ⛔ **`WIN_CAP_5` 现状"保留"不许写成"保留作 BDP 余量"**（`P7B_LONGSEND_ACCEPT.md` §4-②）。
3. **`WIN_POOL`（板通告的接收窗 = 上行那堵墙）** —— 产品级改动（改通告窗口径 + 与 BDP/连接数的权衡）⇒ 需用户级决策；
   先落一页设计（分池寄存器 `0x0C` 已有通路 / 抬池 / 降连接数三选一），再定构建。
4. **`retx_ram` → URAM** —— **非阻断**（BRAM **348/480 = 72.50%**、URAM **0/64**；唯一够格迁的是 `retx_ram` ⇒ 348 → 92 tile ≈19.17%，
   代价 29–32/64 URAM + 读流水 2→3 级）；其**动机**（更大 ring / 更多连接）挂在第 2 项的窗帽判决上 ⇒ 等判定再动。

⚠️ **每条选项的纪律**：一次构建收口（#64/#65/#66）· **"改 RTL"与"在跑回归"互斥**（#57）· 读数带口径与 `PIN_CPU=` 见证（#62）。

## 8. 本轮"最容易踩"的十条（详版 = `P7B_OPEN_ITEMS.md` 与各原件）

1. **五档位流同为 15,431,261 B** ⇒ 只有 **sha256 + BID** 能分版；取数器默认值**已随构建 E 变成 `0x19/67`**
   ⇒ **读旧位流必显式覆盖**（与上一件写的"默认 `0x0A`"相反，别再照抄）。
2. **`0x08` 既是 SCRATCH 又是 `TX_DIS` 门**：`0x08 w 0x2` = **物理停发**（`carrier=0`）⇒ 那一臂的 ping/nc 结果不是慢路径结果。
3. **`carrier=0` 时板侧计数照跑而 NIC 全 0** ⇒ 板内计数**不能**当"线上发生了什么"的见证（两条口径独立）。
4. **32 位计数器**：`W51/W15/W53/W54` ≈3.65 s 回卷（9.3 Gbps 下）；`W43/W5` ≈27.5 s；本轮 E 轮 `W65` 出现 **k=2**、`W66` **k=1**
   ⇒ 差值必须 `mod 2³²` 且**同时记 raw 与 k**（#55）。
5. **`W43` 每拍无条件 +1 ⇒ `P ≡ 156.25e6/fps` 是恒等式** ⇒ `193/P` **不是线占空测量**；
   真正的线空闲仪器 = **`W65`**（`mac_tx_10g.stat_tx_idle`，语义 = `state == S_IDLE` 拍数；S_IFG 不算空闲）。
6. **快照窗口 67 字**：字址 = `0x20 + 4*n`，未实现地址 = `0x12C`；`SNAP_NW_P6E`（`board/wrapper_p4.v:3205`）= 单一真值源。
7. **`--check lane8` 是两个参数**（写成一个词 ⇒ `unknown arg` + **RC=2**）；`--maxbytes 0` = 立即退出（假红）。
8. **长流必须短表**：12 字 ~288 ms > 整条流 227 ms（#67 仪器变慢）。
9. **构建/烧录只走 `board/run_build_p7b_ku5p.bat` + `p7b_biz_tcpreg/run_program_tcpreg.bat`**；
   ⛔ **GUI 重编本树 `vivado_prj` 会踩"新端口悬空被钳 0 = 永久禁发"陷阱**（其 `imports/board/wrapper_p4.v` 是 BID 0xA 旧版）。
10. **"没观察到" ≠ "不存在"**；**"不支持" ≠ "证伪"**；速率引用**必须带分子/分母与口径**（本工程出过 `98.5%` 配错对象的错）。

## 9. 相关全局经验（`~/.claude/fpga_net_dev.md` §六，现为 24–68）

本轮直接相关的：**#55**（32 位回卷 ⇒ mod+k）· **#57**（改 RTL 与跑回归互斥）· **#64**（"改常量就安全"不成立）·
**#65**（"逻辑级数变短" ≠ "slack 变好" —— 本刀 WNS 路径 route 占比 72.8%/68.1%，是 route 主导）·
**#66**（跨网表比临界路径：清单藏族 + WNS 是不同对象 —— 五档 WNS = 五个不同**源/宿对**（S3/A/C 同宿不同源；D/E 源宿都换））·
**#67**（仪器高码率下变慢 ⇒ 窗口落到流外）· **#68**（"读数低"先查对端网卡中断合并）。

---

*本件 = 交接入口，不改任何读数；**判据层的 PASS/FAIL 裁定权在用户/判据所有者**（全局 #51）。*
