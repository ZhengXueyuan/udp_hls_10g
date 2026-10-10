# 构建 F 对抗审查（红队）发现 —— 2026-10-10

**被审对象** = 构建 F（BID `0x1A` / 快照 **70 字** / 位流 sha256 `89e89f31efb5f1450a1c39acfce587bb4e4b6347c5fdc2f470c91ff0d4400f45`）。
本轮全部产出 = 一条公式 **`L[µs] = ΔW66 / (156.25 × ΔW68)`**（板级轮正在测）。

> ⚠️ **本件由 TL 代落盘**（子 agent 的写文件请求被 harness 拒绝）；正文按子 agent 的最终回复整理，**未改一字数字/行号**。
> **边界声明**：全程只读；未启动 Vivado、未烧板、未 ssh 对端；"执行"仅 3 次只读命令（`sha256sum`/`git status`/`diff`）+ 1 次 `python -B` 纯算术（不落盘）。

---

## §0 最狠三条（摘要）

1. ⭐⭐ **量纲 = µs/事件，不是 µs/窗** —— W66 每拍 +1（`rtl/tcp_tx_frame.v:906`），W68 是**单拍脉冲、每帧至多一次**（`rtl/tcp_rx.v:606`）。
   ⇒ 结果 = 「**平均每次 ACK 推进事件的等窗死时间**」。设计件的 `[拍/次刷新]` 标签（`P7B_L_INSTRUMENT_DESIGN.md:169`）依赖
   **"1 事件 = 1 次窗刷新"**，该等价**非结构恒等**（两个反方向都有机制）⇒ 一窗 N 个事件时"每窗" = **L×N**。
2. ⭐ **读侧漏同步一处** —— `_proj_pcie/p6e_snap_check.sh` 的 `WLABEL` **只有 65 项（W0..W64）**，
   而同文件循环 `:343 for (( i = 0; i < SNAP_WORDS; i++ ))`（`SNAP_WORDS` 本轮已同步为 **70**）
   ⇒ **W65..W69 逐字打印 `<无标签>`**（`:344` `${WLABEL[$i]:-<无标签>}`），与同文件 `:294` 自己的规则矛盾（逐字："**每一个字都要有名字**"）。
   缺口起点 = **构建 D**，**D/E/F 三轮未补**；同族缺口本轮修在了**另一个文件**（`p7b_snap.sh` 的 `NAME[]`）。
3. ⭐ **活件硬编码** —— `_proj_10g/notes/p7b_buildE_board_20261010/_tools/lf_dl.deployed.sh:84`
   逐字 `echo "LF_GEOM_OK NW=63 BID=$BID0"`；**本轮实测输出行 = `LF_GEOM_OK NW=63 BID=0x0000001a`**。
   `NW=63` / `:71` 的 `(12 字/点)`（实际 11 字）**都是硬编码字面量**。真几何门（`bash $S id` + 环境 `NW=70`）**没坏** —— **坏的是读的人**。

---

## §1 靶 1 —— 三个新仪器的谓词 vs 声称的语义

### 1.0 量纲（先钉死）

| 量 | 计数器 | 逐字出处 | 单位 |
|---|---|---|---|
| W66 | `stat_winstall` | `rtl/tcp_tx_frame.v:906` `if (stat_winstall_ev) stat_winstall <= stat_winstall + 32'd1;`（时钟块内 ⇒ **每拍 +1**） | **拍** |
| W68 | `stat_ack_adv` | `rtl/tcp_rx.v:606` `if (ack_adv_ev) stat_ack_adv <= stat_ack_adv + 32'd1;`（`ack_adv_ev` 单拍脉冲、每帧至多一次） | **事件** |
| 156.25 | dp 时钟 | `F/p7b_ku5p_timing.rpt` Clock Summary：`gtrefclk0 {0.000 3.200} 6.400 156.250` | 拍/µs |

⇒ `ΔW66/(156.25·ΔW68)` = 拍 ÷ (拍/µs × 事件) = **µs/事件**。
⇒ ⚠️ "1 事件 = 1 次窗刷新" **非结构恒等**（机制见 §1.3-D）——**读数表必须带限定语**。

### 1.1 W66 `stat_winstall`（帧器因窗口未开而停拍）

**谓词（现役 OVL 支）逐字** `rtl/tcp_tx_frame.v:617-621`：
```
    wire        stat_winstall_ev = (rx_state == RX_IDLE) && recv_first &&
                                   s_axis_tvalid && !ack_pend_r && !svc &&
                                   !ring_eval && !scan_now && !rx_flush &&
                                   !fifo_full && !bank_rdy[rx_bank] &&
                                   !tx_blk_sid && !wnd_open;
```
**对照 `start_data`（`:562-565`）逐项相同、唯一差别 = `wnd_open` ↔ `!wnd_open`**：
```
    wire        start_data = (rx_state == RX_IDLE) && recv_first && !ack_pend_r &&
                             !svc && !ring_eval && !scan_now && !rx_flush &&
                             s_axis_tvalid && !fifo_full && !bank_rdy[rx_bank] &&
                             wnd_open && !tx_blk_sid;
```
非现役默认支同款：`:1475`（`start_data`）vs `:1483-1485`（`stat_winstall_ev`）—— `flush_pend↔rx_flush` / `pay_full↔fifo_full` / `state==S_IDLE↔rx_state==RX_IDLE && recv_first`，其余同名逐字相同。

**② 粒度 = 拍**（`:906` 每拍 +1，无事件语义）。
**③ 等价 = 成立（结构性）**：`start_data` 是 OVL 支**唯一的启动触发**（`:2031 if (start_ack || start_data) begin`），
且 `s_axis_tready` 与该门**逐字同门**（`:556-561`）⇒ "把 `wnd_open` 换成 1，这一拍就正好是 `start_data` 拍"（`:153`、`:582-583`）**逐字成立**。
**其余项为什么必须有**：少 `s_axis_tvalid` ⇒ 把"没得开"计成"等窗"；少 `rx_state/recv_first` ⇒ 把帧内续传拍计进来；
少 `ack_pend_r/svc/ring_eval/scan_now/rx_flush/bank_rdy/fifo_full/tx_blk_sid` 任一 ⇒ 把"**别的门也关着**"的拍计成"窗口在咬"。

**残余（边界，不是"不等价"；前两条 RTL 自己已登记）**：
- (a) **下界性**：只数"唯一关着的门是窗口"的拍 ⇒ `ΔW64 ≥ ΔW66 − ΔH`（`:605` 逐字），**ΔH 无独立计数器** ⇒ "窗口在咬"的**总量**读不到。
- (b) **门本身 1 拍陈旧**：`win_open/win_inflight/win_wnd_eff` 是 tcb 寄存器（`rtl/tcb.v:153-157` 单 always 块），比阵列晚 1 拍（`:139` 自述"最坏误开 1 拍"）。
- (c) **跳槽 1 拍**：`win_id = rb_id`（`board/wrapper_p4.v:2006`）；若 `start_id` 在 T−1→T 之间变化，T 拍计数指向**上一个**连接。量级 ≤1 拍/次，**未量**。

### 1.2 W67 `stat_winstall_cap`

**谓词** `rtl/tcp_tx_frame.v:631-632`：
```
    wire        win_cap_bind         = (win_wnd_eff >= RING_CAP);
    wire        stat_winstall_cap_ev = stat_winstall_ev && win_cap_bind;
```
样本源 = `rtl/tcb.v:152-156` `wire [15:0] win_cap = (snd_wnd_r[win_id] < WIN_CAP) ? snd_wnd_r[win_id] : WIN_CAP;`（与 `win_open` **同沿同脉块**）；
`WIN_CAP` = `.WIN_CAP(WIN_CAP_5)`（`:1980`）与 `RING_CAP` = `.RING_CAP(WIN_CAP_5)`（`:2144`）**同源** `localparam [15:0] WIN_CAP_5 = 16'hF000;`（`:227`）。
**粒度 = 拍。等价 = 成立**（`win_wnd_eff = min(snd_wnd, WIN_CAP)` ⇒ `≥ RING_CAP ⟺ snd_wnd ≥ WIN_CAP`）。
⛔ **语义必须按"阈值归属"读，不按"谁的锅"读**：W67 高 ⇒ **生效阈值是板帽**，**不等于**"板是瓶颈"。
并列档（`:177-180` 已登记）：`snd_wnd == 0xF000` 恰等 ⇒ 归板帽侧（至多 16 位一档偏置）。

### 1.3 W68 `stat_ack_adv`（L 的分母）

**谓词** `rtl/tcp_rx.v:382`：
```
    wire        ack_adv_ev = fend && s_axis_tcrs && ack_adv_l && !fend_trunc;
```
`ack_adv` = `:322` `wire ack_adv = ack_ok && (ack32 != ra_snd_una);`；`ack_ok` = `:321` `((ack32 - ra_snd_una) <= (ack_hi - ra_snd_una))`，`ack_hi = retx_active ? retx_hi : snd_nxt`。
⭐ **"该连接"的保证 = `:288 assign ra_id = conn_id_l;`** —— 审查专门攻击过（怕 `ra_*` 被 tx 侧 `rb_id` 污染），**攻不破**（`ra_id` 由 tcp_rx 自己驱动：`board/wrapper_p4.v:1845` → `:1991` tcb）。
采样相位：`ack_adv_l <= ack_adv` 在 `wcnt==5`（`:681-684`），`fend` 在 w6/后续拍。
`fend` = `:379` 六个析取，分处 `S_HDR/S_PAY/S_PAD`（互斥 state）且 fend 拍无条件归位 state/wcnt（`:709`）⇒ **每帧至多 1 拍** ⇒ **粒度 = 事件**。

**③ 等价 = 成立，但有 4 个缺口（A 已登记；B/C/D 本审查新找）**：
- **A（已登记）**：`ack_adv_l` 用 w5 拍的 `ra_snd_una`，TCB 落地在 drain `drn==2`；另一条 ACK 的 drain 恰落在 w5→fend（1–2 拍）内 ⇒ **多计**（分母偏大 ⇒ `L` 偏小）。发生率**未量**。
- **B（新）**：**drain 写口 sticky 被后帧覆盖** —— `:514-517` `if (ack_adv_l && s_axis_tcrs) begin pend_una_val <= ack32_l; pend_id <= conn_id_l; end`，每帧 fend 拍重写；若 drain 被 `upd_gnt` 拖过下一帧 fend，中间那个 ACK 的**写**被跳过而 W68 已计它 ⇒ `ΔW68 ≥ 实际 snd_una 推进次数`（与 A 同方向）。需 drain 停滞 ≥ 一帧间隔（背靠背 60B ACK ≈ 8 拍），**未量**。
- **C（新，⭐ 有牙价值）**：⛔ **"`ΔW68 ≤ ΔW22`" 不是结构性牙**。`fend_w6t`（`:364-365`）属于 `fend` 且**不是** `fend_trunc` ⇒ W68 计它；而该帧**不进** `stat_pass`(W22)（W22 只在 `:713`/`:820`/`:883` +1；`fend_w6t` 落 `:730-738` 的 else 链 → `stat_drop_trunc`/`stat_drop_nonmatch`）。
  正确牙 = `ΔW68 ≤ ΔW22 + Δ(截断帧)`；而 **`stat_drop_trunc` 不在 70 字窗口内 ⇒ 现在闭不上**。
- **D（新，口径）**：分母 = "**在飞**判据成立"的事件，**不是**"落地写"(B)、**也不是**"门重开"。反方向两例：① `replay_jump`/`svc_rewind` 降 `snd_nxt`（`:527-536`）⇒ **无 ACK 事件也能重开门**（本轮 dry 跑 `ΔW55 = 27` 次回卷，27 ≪ 1.2M 可忽略但**机制存在**）；② 对端通告窗变大（`pend_wnd_val <= wnd_ws` 在**任意** `fend && tcrs` 拍，`:494`）⇒ 同。

### 1.4 W69 `o_win_at_winstall`

**谓词** `rtl/tcp_tx_frame.v:909` `if (stat_winstall_ev) o_win_at_winstall <= {win_inflight, win_wnd_eff};`（默认支 `:1849`；复位 `:878`/`:1811`）。
**粒度 = 锁存。等价 = 成立**（两半与 `win_open` **同沿同源**；且该拍 `stat_winstall_ev` ⇒ `infl ≥ eff`）。
⚠️ **读法（新）**：**`infl == eff` 恰等是正常形态**（撞帽那一拍锁存 ⇒ 之后被阻塞期间 `infl` 不变）—— **不许**当"测量坏了"。
真正异常形态 = **`infl ≫ eff`**（窗值被写小/陈旧）。
**板级现值（in-flight dry 跑 `runs/BFDRY.txt`）**：`W69 = 0x8e948e94` ⇒ `infl = 36500`、`eff = 36500` ⇒ `eff < RING_CAP(61440)` ⇒ **对端侧在咬**（与 `ΔW67 = 0` 自洽）。

---

## §2 靶 2 —— 读侧同步的穷举性：**不成立（找到一处漏同步）**

**现核的现役几何（源码 = 唯一权威）**

| 位置 | 值（逐字） |
|---|---|
| `board/wrapper_p4.v:3228` | `localparam SNAP_NW_P6E = 70;` |
| `board/wrapper_p4.v:3249` | `localparam SNAP_P7BDP_NW = 30;` |
| `board/wrapper_p4.v:4050` | `.BUILD_ID_V (32'h0000001A),` |
| 未实现地址 | `0x20 + 4×70 = 0x138`（word 78） |
| `_proj_pcie/p7b_gate4_accept.sh:131/137` | `EXPECT_BID=${EXPECT_BID:-0x0000001A}` / `SNAP_WORDS=${SNAP_WORDS:-70}` ✓ |
| `_proj_pcie/p7b_biz/p7b_snap.sh:49/51` | `NW=${NW:-70}` / `EXPECT_BID=${EXPECT_BID:-0x0000001A}` ✓ |
| `…/p7b_buildF_board_20261010/_tools/p7b_snap.deployed.sh:49/51` | 70 / `0x0000001A` ✓（STEP0 已 md5 自证） |

**穷举方法**（不用别人的清单）：① `git status --porcelain`（113 行）；② 全树 ripgrep ×6 组（`SNAP_NW|SNAP_WORDS` · `EXPECT_BID|UNIMPL_ADDR` · `NW=${NW:-` · `SNAP_WORDS=${SNAP_WORDS:-` · `0x00000019|NW=67|…` · `0x12C`）；③ 与 `p7b_buildF/apply_readside.py` 的 8 组清单交叉。

**⭐ 漏同步（唯一活件缺口）**：`_proj_pcie/p6e_snap_check.sh` —— `WLABEL` **只有 65 项**（计数命令：`awk 'NR>=295 && NR<=341' … | grep -o '"[^"]*"' | wc -l` = **65**，最后一项逐字 = `"app_bp_cyc         (app_pattern 背压拍数)"` = W64）。⇒ **W65..W69 打印 `<无标签>`**。
⇒ 这是"66 字轮 / 67 字轮连续漏 `gen_inputs.py`"的**同族第三次形态**：**不是同一个文件，但同一类"表尾没跟着字数走"**。

**其余命中（逐条分类）**

| 命中 | 现写什么 | 分类 |
|---|---|---|
| `_proj_pcie/p7b_gate4_accept.sh:67-69` | `# ⛔ 2026-10-10 (构建 C 门同步轮): … 现役默认 = SNAP_WORDS=65 … EXPECT_BID=0x00000017` | **陈旧注释（自相矛盾）**：与同文件 `:131/:137` 的 `0x1A/70` 矛盾，且写的是"**现役**"⇒ 两代前 |
| `_proj_pcie/p7b_biz/p7b_snap.sh:55-58` | `#    现役 = **0x00000017** (65 字; …)` | 同上（文件头 `:2` 与 `:49/:51` 是对的） |
| `sim/p5wu_p1p2/check_wu_words.py:14` | `1  SNAP_NW_P6E == 63 且 SNAP_P7BDP_NW == 24` | **旧代读法（可留）**：全树**无调用者** |
| `…/lf_dl.deployed.sh:84` / `:71` | `NW=63` / `12 字/点`（实际 11） | **活件硬编码** |
| `…/p7b_buildE_board_20261010/run_arm.sh:21` 等 | `NW=67` / `BIE=0x00000019` | 上一轮臂脚本（旧位流读法）✓ 可留 |

**建议最小动作**：① `p6e_snap_check.sh` 的 `WLABEL` 补 W65..W69（名字与 `p7b_snap.sh` 的 `NAME[]` 同源）；
② `lf_dl.sh:84` 的 `NW=63` → `NW=$NW`、`:71` 的 `12` → `$(echo $KW | wc -w)`；
③ **在 `apply_readside.py` 加一条断言 "WLABEL 项数 == NW"**（该脚本现在只断言"锚点命中数"、**不断言表长** —— 这正是它连续三轮漏掉这一类的原因）。

---

## §3 靶 3 —— W68 的牙：三条登记项**全部成立**，另补 3 条

**逐条现核**
1. ✅ **grep-only、没接退出码**：`tb/tb_tcp_rx.v:281-285` 逐字
   ```
   $display("W68ADV dut=%0d tb=%0d", stat_ack_adv, exp_ack_adv);
   if (exp_ack_adv == 0) $display("[FAIL] W68 空判据 (TB 侧推进 ACK 事件 = 0)");
   if (stat_ack_adv !== exp_ack_adv)
       $display("[FAIL] W68 语义不符 (逐拍复算): dut=%0d tb=%0d", stat_ack_adv, exp_ack_adv);
   ```
   全文件 `FAIL|PASS|fatal|$finish` 只 4 处（273/276 是别的判据），`:288 $finish;` **无条件** ⇒ xsim 退出码与 W68 无关。
2. ✅ **门本来就是红的**：`_proj_10g/notes/p7b_regression/gate_table.md:51` 逐字 `| 49 | p3_tcp_rx | sim\p3sim\run_tb_tcp_rx.bat | 1 | hard: 92 lines, stats {...} | FAIL | 既存 |`；末次留档 `p7b_regression/logs/p3_tcp_rx.log`（Sep 30）末尾 `hard: … MISMATCH` + `# ===== runner: EXIT=1  9.6s   =====`。退出码 = 末行 `tools/gen_stim_tcp_rx.py . check`（`:870 sys.exit(0 if ok else 1)`），`check()`（`:823-858`）只对 `resp_tcp_rx*.memh` 与 STATS/STATM/TCBF 三个尾行 ⇒ **结构性看不见 `stat_ack_adv`**。
3. ✅ **没有 W68 变异**：`sim/p7b_stagec_tx_regress/author_gate/mk_mut_tx.py:44` 逐字 `SRC = os.path.join(ROOT, "rtl", "tcp_tx_frame.v")`；`mut/` 15 个变异体 = W66×2 / W67×2 / W69×2 + 旧 9 个，**W68 零个**。

**补刀（新）**
4. ⭐ **判据结果零留档 ⇒ "该判据通过" = 未证**：全仓 `grep -n W68ADV` **只命中 `tb/tb_tcp_rx.v:281` 一处**。实现轮确实跑过（`sim/p3sim/tb_tcp_rx.wdb`/`resp_tcp_rx*.memh`/`gen_tcp_rx.log` 时间戳 **2026-10-10 09:08**），但**没有任何文件记录 `dut=? / tb=?`**。
5. ✅ **不是"预 AND 成结构性恒 0"**：四谓词项全是真信号（`s_axis_tcrs` = `_proj_10g/p7b_mac/rtl/mac_rx_10g.v:505 assign m_axis_tcrs = fdout[1];`）；板级实测 `ΔW68 = 1,235,763 ≠ 0`。
6. ⭐ **独立信息量要打折**：同 dry 跑 `ΔW22 = 1,236,034`、`ΔW68 = 1,235,763` ⇒ 差 **+271（0.022%）** ⇒ **不许把 W22 与 W68 当两台独立仪器互相印证**。非同源见证只能用**对端 pcap 的 ACK 计数**。
   ⚠️ 顺带：`P7B_L_INSTRUMENT_DESIGN.md:176` 的"够用准则①"（`ΔE` 与"推进 ACK 数"`ΔE_ack` 互证到几个百分点）**按字面是循环论证**（`ΔE` 就是 `stat_ack_adv`）。

**⭐ 最小装牙动作（未实施）**
1. `tb/tb_tcp_rx.v`：`:285` 后加 `$display("TB_TCP_RX_W68: %s", (stat_ack_adv === exp_ack_adv && exp_ack_adv > 0) ? "OK" : "FAIL");`
2. `sim/p3sim/run_tb_tcp_rx.bat`：三次 xsim 加 `> xs_<MODE>.log 2>&1` + `findstr /C:"TB_TCP_RX_W68: OK" xs_*.log >NUL || exit /b 1`（形状同 `run_tx_ovl_gate.bat` 的 `:run` 尾三行）。⚠️ **牙要挂在 `nostall`/`stall` 两臂上**（整体门仍会因既存 HARD 臂红）。
3. 变异：新增 `mut/mut_w68_dead.v`（`rtl/tcp_rx.v:606` 的 `if (ack_adv_ev)` → `if (1'b0)`）+ `mut_w68_noexist.v`（谓词去掉 `fend`）。**前提** = 变异器 `SRC` 从写死的 `tcp_tx_frame.v` 扩成可指定。
4. 板级结构牙：⛔ **不能**写 `ΔW68 ≤ ΔW22`；正确写法 = `ΔW68 ≤ ΔW22 + Δ(截断帧)`，**需先把 `tcp_rx.stat_drop_trunc` 接进窗口**（现在没有）。

---

## §4 靶 4 —— 时序与网表影响（现核）

**A. 全局 WNS 的宿主与类型**（`F/p7b_ku5p_timing.rpt`）
```
Slack (MET) :             0.111ns                                                        ← :3455
  Source:      u_pcie_xdma/inst/pcie4_ip_i/inst/user_reset_reg/C  (FDPE, pcie_axi_aclk)
  Destination: u_pcie_regs/snap_words_r_reg[1797]/CLR
  Path Group:  **async_default**     Path Type: Recovery (Max at Slow Process Corner)
  Requirement: 4.000ns     Data Path Delay: 3.439ns (logic 0.093ns 2.704% / route 3.346ns 97.296%)
  Logic Levels: 0
```
⇒ **`+0.111` 不是数据面 setup**，与上一档 E 的 `+0.090`（`rx_state_reg[1]_replica/C → u_app/stg_reg[4]/D`，setup，22 级）**既不同对象、也不同检查类型** ⇒ **直接比较无效**。
DP 域行（`:221`）= `g_hw.clk_out0 0.281 … 138839` ⇒ **DP 域 setup WNS = 0.281**（宿 `u_clkgen/rel_sr_reg[3]/C → u_tcp_tx/u_retx/…_bram_7/RSTRAMB`，纯布线 98.4%）。

**B. 新仪器锥（现核 `query_F_stdout.txt`）**

| 查询 | 读数 |
|---|---|
| `-from win_wnd_eff_reg* -to stat_winstall_cap_reg*/CE` | **slack = 4.791 lvl = 1**（= DP WNS 的 17.0×） |
| `-to stat_winstall_cap_reg[*]/CE`（全 32 pin） | **1.177 lvl = 7**，src = `u_tcp_tx/u_ackq/dout_reg[36]/C` |
| `-to o_win_at_winstall_reg[*]/CE` | **1.360 lvl = 6**（同 src） |
| `-to stat_ack_adv_reg[*]/CE` | **1.222 lvl = 6**，src = `u_tcp_echo/u_fifo/wptr_reg[10]/C` |
| `-to o_win_at_winstall_reg[*]/D` | **4.574 lvl = 0**，src = `u_tcb/win_inflight_reg[0]/C` |
| `-to stat_winstall_reg[*]/CE`（W66） | **2.217 lvl = 9**，src = `u_tcp_tx/FSM_sequential_rx_state_reg[1]/C` |

⇒ 三个新锥**全部远离** DP WNS（最小 4.2×）；报告面三个新仪器名 **0 命中**。

**C. "有没有加深既有端点" = 部分成立 / 全称未证**
- 能说的：报告面 0 违例 + 4 个旧族定向值（F 侧 2.217/3.371/2.579/0.732&0.441）都不低于 E 侧对应族（1.932/3.857/2.886/0.090&0.185）——
  ⚠️ 但**每一行都不是同一条对象**（E 侧源 = `rx_state_reg[1]_replica`，F 侧 **`CELLCOUNT F rx_state_replica* = 0`**，源族都换了）⇒ 只能当"同族对照"，**不是"变好"**（#66）。
- ⛔ **没查的族**：新逻辑把**扇出**加在既有网 `wnd_open`/`ack_pend_r`/`s_axis_tvalid`/`fend`/`s_axis_tcrs`/`ack_adv_l`/`win_wnd_eff`/`win_inflight` 上，而查询只测了**新 CE 端点**。既有**功能**消费者（`s_axis_tready`/`start_data` 门、`in_retx`/`dup_cnt`/`ack_obs` 的写、`wnd_f` 的锁存）是否被额外负载推深 = **未查**。最小补查（**不要跑**）：`-from [get_cells u_tcb/win_open_reg]`、`-from [get_cells *ack_adv_l_reg]`、`-from [get_cells *ack_pend_r_reg]`。
- ⛔ **取证耐久性（新）**：`run_queries.bat` 用的是**活路径** `vivado_prj\p7b_ku5p_prj.runs\impl_1\wrapper_p4_routed.dcp`，而 F 档归档 `F/` **不含 dcp** ⇒ 下一次 `create_project -force` 会毁掉 F 侧定向查询的**唯一输入**（#54 同族）。E 侧的 dcp 反被 run1 的**预构建归档**保住（`p7b_build_archive/20261010_091536/`）。
**建议**：把 `impl_1/wrapper_p4_routed.dcp` 复制进 `F/`；补 `-from` 三个旧族查询（下一轮构建顺手做）。

---

## §5 靶 5 —— 源冻结（9/9）：**成立**，并扩到全树

1. `diff SRC_PRE.sha256 SRC_POST.sha256` = **空**；两清单各 **9** 行、逐字相同。
2. **现在仍然成立**（比"前后相同"更强）：现算这 9 个文件的 `sha256sum` 与 `SRC_POST.sha256` **逐条相同（9/9）** ⇒ 截至本审查时刻 RTL 未被改动。
3. **覆盖缺口的补证（本审查做的）**：冻结清单只有 9 个，**不含** `board/*.xdc`、其它 `rtl/*.v`、IP/BD 配置 ⇒ 改用 **mtime 全树扫描**：
   - `find rtl board _proj_10g/p7b_mac/rtl _proj_pcie/rtl -name '*.v' -newermt '2026-10-10 09:15:34' ! -newermt '2026-10-10 10:05:57'` ⇒ **0 命中**
   - 全树（排除 `vivado_prj/`、`.git/`）`*.v/*.sv/*.xdc/*.tcl/*.sh/*.bat/*.py` 同窗口 ⇒ **0 命中**
   ⇒ 构建窗口 = `09:15:34 → 10:05:56`（run2）；本轮改动的读侧/sim 文件 mtime 全在 **08:52–08:57**（构建前）与 **10:27**（构建后）⇒ **无窗口内竞争**。
4. ⚠️ **没核的**：`vivado_prj/**` 的 IP/BD 生成物 ⇒ 该格"未证"（弱证据：`:1080 Parameter BUILD_ID_V bound to: 26`、`:394 TX_BYTES bound to: 268435455`，与源码一致）。

---

## §6 顺手 —— `analyze.py` 的"三角核"右腿是**假牙**

`_proj_10g/notes/p7b_buildF_board_20261010/analyze.py:216-218` 逐字：
```
    # 三角核
    viol = [r for r in in_flow if not (r["d67"] <= r["d66"] <= r["d64"])]
```
- 左腿 `d67 ≤ d66` = **结构性**（`stat_winstall_cap_ev = stat_winstall_ev && win_cap_bind`）✓ **真牙**。
- ⛔ **右腿 `d66 ≤ d64` 不是**：`rtl/tcp_tx_frame.v:605` 逐字 `⚠️ 严格成立的式子 = \`ΔW64 ≥ ΔW66 − ΔH\` (同一窗)` ⇒ `ΔW66` **合法地可以大于** `ΔW64`（差额 ≤ `ΔH`）⇒ 该"违例区间"会**把合法情形报成违例**。
- dry 跑实测：`d67=0 ≤ d66=34,780,529 ≤ d64=49,695,810` ⇒ 本轮**未触发**（无假报）。
**建议**：右腿删掉，或改成 `d66 − d64 ≤ ΔH` 口径（ΔH 需先有计数器）。

---

## §7 我推翻 / 降级了什么

① **`LF_GEOM_OK NW=63`** —— 是硬编码字面量（`lf_dl.deployed.sh:84`），不是测量 ⇒ **降级**：引用该行论证"这一跑读的是 63 字窗口"**无效**（硬证据 = `ID_UNIMPL 0xffffffff` + `ID_BID 0x0000001a`）。
② **"W67 高 ⇒ 板是瓶颈"** —— 谓词只证明"生效阈值是板帽"⇒ **降级为"阈值归属"**。
③ **"`ΔW68 ≤ ΔW22` 是免费的牙"** —— **推翻**（`fend_w6t` 反例结构性存在，§1.3-C）。
④ **"L = 每窗刷新死时间"** —— **降级为"µs/事件"**（§1.0）。
⑤ **"够用准则①（ΔE 与推进 ACK 数互证）"** —— **按字面是循环论证**（`P7B_L_INSTRUMENT_DESIGN.md:176`）。
⑥ **"88–90% 线空闲归窗口"不许跨工况外推** —— dry 跑实测 `ΔW66/ΔW20 = 8.4624`、`ΔW65/ΔW20 = 163.2` ⇒ `ΔW66/ΔW65 = 5.2%`（⚠️ in-flight 数据，**只作形态登记**；该跑 438.6k fps，不能与饱和档并列）。
⑦ **`ΔW68 ≤ ΔW22` 实测方向**（正面确认）：dry 跑 `ΔW22 = 1,236,034`、`ΔW68 = 1,235,763` ⇒ 差 **+271**，落在正确一侧（本轮**未暴露缺口 C**）。

## §8 我查了但结论是"未证"

- **W68 判据的实际配对结果**（`dut=? / tb=?`）：**无任何留档**（§3-④）。
- **W68 缺口 A/B 的发生率**：无仪表、未量。
- **W67/W69 在 dry 跑一格上的自洽**：只是形态一致，**不是判据**。
- **新逻辑对既有功能网的负载加深**：未定向查（§4-C）。
- **`vivado_prj/**` 窗口内是否变化**：未证（§5-4）。
- **W66 残余 (c) 跳槽 1 拍的计数错位**：结构性存在，**未量**。

## §9 我没查的（+原因）

- **三个新仪器的 xsim 行为级复算**（臂 N/O/P/Q/R 实跑）：臂 O 的 TB 参考式（`tb/tb_tcp_tt_ovl.v:875 tb_winstall_cap_ev = tb_winstall_ev && (win_wnd_eff >= TB_WIN_CAP)`）与 DUT **同式**，只能抓接线错、抓不到定义错 —— 定义错已由源码逐字比对完成（§1），且**避免与在飞轮抢资源**。
- **`sim/` 下 71 个 `app_pattern #(` 镜像件**：未逐个甄别（禁全局替换已登记）；结论不依赖它们（本轮 `apply_*` 清单无镜像件，`git status` 也无）。

---

## §10 本审查**没能推翻**的（同样是结论）

W66 的反事实等价 · W67/W69 的"同沿同源样本" · W68 的"该连接"归属（`:288 ra_id = conn_id_l`）· 两分支"逐款同款" ·
`ΔW67 ≤ ΔW66` · **9/9 源冻结** · 臂 O（`W67_CAP_SMALL` 使 W67 非空）的构造 · `.bit` sha256 与 READINGS 逐字一致。
