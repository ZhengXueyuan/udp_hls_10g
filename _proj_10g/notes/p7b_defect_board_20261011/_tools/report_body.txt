# P7B-RETXHI-GHOST 板级轮 A（S-0 臂）—— 报告（2026-10-11）

> **被测件** = **修复前**位流 = **构建 F**（`BID 0x1A` / 快照 70 字 / 未实现地址 `0x138`）·
> sha256 `89e89f31efb5f1450a1c39acfce587bb4e4b6347c5fdc2f470c91ff0d4400f45`（15,431,261 B）·
> **零构建**（未跑 Vivado 综合/实现；`rtl/ tb/ sim/ board/` 只读）· 只走 JTAG 易失烧录（**未写 QSPI**）·
> **未改 `/tmp/p7b_biz/` 现役工具**（新件全落 `/tmp/p7b_ghost/`）· 未碰 `D:\repo\perfv` · git 只读。
> **本件不给 PASS/FAIL 裁定**；结论句一律按"**观测到 / 未观测到**"口径（**不写"不存在"**）。

---

## 0. 三行结论

1. ⛔ **派单书 §6.2 的 S-0 构型在本位流上【建不起来】**：abort(RST) 的板级通路**不存在** ——
   `app_ctrl` 的 CMD 寄存器总线在 wrapper 里被**钉死**（`board/wrapper_p4.v:1320-1321` 逐字
   `assign app_reg_addr = 8'h00;` / `assign app_reg_wr = 1'b0;`），且**活体读数印证**
   （`0x10` 读出的是 axi_regs 的 `hw_status`，不是 app_ctrl 的 per-conn 状态字）⇒ **host 写不到 `0x06`（CMD=abort）**。
   板上另一条 `rst_req` 源（G2 关闭超时）要求 framer **真的发过一个 FIN**，而 build F 的 app 是**连续模式**
   （`.TX_CONTINUOUS(1'b1)`）⇒ 永不 close ⇒ 永不武装 ⇒ **`rst_req` 在任何路径上都不会为 1**。
2. **形态① 幽灵 = 未观测到**：既没有它的**必要条件**（数据之后发过控制帧 +1），也没有它的**签名**
   （尾部 0/1 字节级、与重放会话逐笔对应的失配）。**⚠️ 不许读成"板上不存在"**（§5 给"看得见/看不见"清单）。
   正面读数：53 s / 6 连接全窗普查 **板侧 FIN/RST = 0**；重放会话**大量存在**（`ΔW55 > 0`）；
   ⭐ **相位校正后 400 MB / 274,391 段逐字节核查 = 零断点**（= 全流等于图案序列的一段）+ 同 seq 内容 0 变化 + 无洞。
3. ⚠️ **必须与幽灵分开登记的另一条真现象**：**连续模式下"对端断开 → 重连"，app 不重启图案流而延续旧流**
   ⇒ 对端逐字节校验器**整条连接相位错**（`first_mismatch=0`、失配 ≈ 全量 − n/256）。
   与已登记的 A3/A7「`ev_up` 被吞」同根、**新形态**；**它不是幽灵**（量级/形态/机理都不同），
   但它让**所有 `TX_CONTINUOUS=1` 位流上的多连接长跑 `mism_bytes` 失去内容判别力**。

---

## 1. 烧录与身份（原始读数）

| 项 | 读数 | 出处 |
|---|---|---|
| 归档源 | `_proj_10g/notes/p7b_build_archive/20261011_002044/wrapper_p4.bit` | 派单指定 |
| `SHA256SUMS.txt` 该行（逐字） | `89e89f31efb5f1450a1c39acfce587bb4e4b6347c5fdc2f470c91ff0d4400f45 *wrapper_p4.bit` | **先核它** |
| 归档副本 sha256 / 大小 | `89e89f31…0f45` / `15431261` B | 按其中值核（**两处同值**） |
| 烧录件 | `burn/wrapper_p4_F_archive.bit`（由归档复制；sha256 同上） | ⛔ 只烧它；⛔ 未碰 `vivado_prj/**` |
| 板侧现态（**烧前**） | `0x04 = 0x0000001a` · `0x138 = 0xffffffff` · `LnkSta x4` · `2 BARs` · `carrier=1` · `0x08=0` | `STEP0_selfcheck.txt` |
| 烧录判据（四件套） | `End of startup status: HIGH` ✓ · `TCPREG_PROG_DONE` ✓ · 位流路径匹配 ✓ · stdout mtime 新鲜 ✓ | `burn/BURN_F_archive.log` |
| 板侧身份（**烧后**） | `ID_MAGIC 0x50360001` · **`ID_BID 0x0000001a`** · `ID_MARKER 0xdeadbeef` · `ID_UNIMPL 0xffffffff` · **`ID_OK` `RC=0`** · `SCRATCH=0` · `CARRIER=1` | `burn/id_F_archive_*.txt` |
| rescan | 设备级 `remove`+`rescan` 一次成功（`Region 0` 1M + `Region 1` 64K；`LnkSta 5GT/s x4`） | 同上 |

**如实记录两条**：
- ① **烧前板上现态已是 `0x04 = 0x1A`**（构建 agent 做了新构建但**未烧**，板上仍是构建 F）⇒ 板上 BID 与烧录件同值；
  仍按纪律**重烧归档副本**后才测量（sha256 ↔ 板侧 BID 双核通过）。
- ② ⚠️ **`TCPREG_PROG_DONE` 这条判据的"牙"比字面弱**：`program_tcpreg_ku5p.tcl` 被 Vivado **回显进 stdout**
  （日志里有 `# puts "TCPREG_PROG_DONE …"` 行）⇒ 纯 `grep -q TCPREG_PROG_DONE` 会命中回显行。
  本轮实际靠 **`End of startup status: HIGH`**（只由工具打印）+ `TCPREG-ABORT` 未出现 + mtime 三项兜住。
  **建议后续把该判据改成"非注释行"匹配**（登记，本轮不改）。

---

## 2. abort 通路的现找现证 —— 结论：**板上没有**

派单书 §6.2 要求"app 走 **abort（CMD abort → app_ctrl.rst_req → rst_push）**"。逐条现核（**行号本次现读**，行内容逐字抄）：

1. **CMD 寄存器确实存在**：`rtl/app_ctrl.v:41` 逐字
   `//   0x06 W: CMD = {cmd[3:0], id[3:0]}: cmd 1 = close (fin_req[id]), 2 = abort`
   写路径 `rtl/app_ctrl.v:1352-1359` 逐字 `if (reg_wr && reg_addr == 8'h06) begin case (reg_wdata[7:4]) … 4'd2: begin rst_req[reg_wdata[3:0]] <= 1'b1; …`
   ⇒ 语义成立（写 `0x06 = 0x20|id` 就该 abort 该连接）。
2. ⛔ **但这条总线在板上没接**：`board/wrapper_p4.v:1320-1321` 逐字
   ```
       // P5 寄存器总线默认静止 (板级无 CPU/AXI; 将来接 AXI-Lite 桥)
       assign app_reg_addr  = 8'h00;
       assign app_reg_wr    = 1'b0;
   ```
   （全文件仅此两处赋值，无 `ifdef` 分支、无第二驱动）⇒ **host（PCIe 寄存器窗口）走不到 `0x06`**。
3. **活体印证（板上 F 位流现读，2026-10-11 01:02）**：`0x10` = `0x00000018`（= axi_regs 的 `hw_status`：
   bit4 `msi_enable`=1、bit3 `user_lnk_up`=1）、`0x14` = `0xdeadbeef`、`0x0C` = 变化的自由计数（`freecnt`）
   —— 与 `_proj_pcie/rtl/axi_regs.v:280-292` 读 mux 逐条吻合。
   而 app_ctrl 的 **per-conn 块**（`rtl/app_ctrl.v:760-772`：`0x10+4c` 的 `+0=state/+1=snd_una/+2=snd_nxt/+3=窗口`）
   与快照字（`axi_regs.v:136` `SNAP_W0_IDX = 8`）**地址重叠**、被 axi_regs 读 mux 遮住
   ⇒ 读 `0x0A`/`0x94` 拿到的是别的字（**非字对齐读**更是垃圾），**不构成 app_ctrl 可达的证据**。
4. **另一条 `rst_req` 源 = G2 关闭超时**（`to_fire`）：`rtl/app_ctrl.v:859-860` 逐字
   `wire to_fire = scan_tick && !init_pend && !ev_blk && !act_now && fin_sent[scan_id] && (rc_state == ST_ESTAB) && (fin_to[scan_id] >= FIN_TO_LIM) && !to_fired[scan_id];`
   而 `fin_sent` 的真值源 = **framer 的"FIN 已发出"位图**：`board/wrapper_p4.v:2115` 逐字 `assign app_fin_sent = tx_fin_sent;`
   + `rtl/tcp_tx_frame.v:1006` 逐字 `assign o_fin_sent = fin_sent_r;`
   ⇒ **G2 要求该连接真的发过一个 FIN**（framer 级），不是"app 想关"。
5. **build F 的 app 永不 close**：`board/wrapper_p4.v:1186-1191` 逐字
   `app_pattern #(.TX_BYTES(32'h0FFFFFFF), .TX_SEGSZ(12'd1460), .TX_CONTINUOUS(1'b1), …)` ⇒ 连续模式 ⇒ 不置 `close_req` ⇒ 不发 FIN。
6. **板级观测印证**：S0A 全窗控制帧普查（`tcpdump "tcp port 8080 and (FIN|RST)"`，53 s，**tcpdump 自报 0 丢包**）
   抓到 **21 个包，全部是对端→板**（sport=临时端口、dport=8080；`runs/S0A_ctl.pcap` 逐包分类）；
   同一跑的全帧 pcap 逐连接分类 = **6 条连接 `fin=0 rst=0`** ⇒ **板侧控制帧数 = 0**。

**⇒ 必要条件现核（派单书 §5 要求"先核必要条件再判"）**：形态① 需要"数据写入环之后，该连接发过 ≥1 个走
`upd_wr_ctrl` 的控制帧（drift > 0）"。本位流上可达控制帧只有两条：
- **FIN**（`rtl/tcp_tx_frame.v:977-979` 逐字 `fin_push = scan_now && fin_req[scan_id] && !fin_sent_r[scan_id] && !ackq_full && (rb_state == 4'd1) && (rb_snd_nxt == rb_snd_una);`）
  ⇒ 其 +1 由 **fin 支**摘掉（`:1131` 逐字 `retx_hi <= (fin_sent_r[svc_id] && svc_rewind) ? fin_seq_r[svc_id] : rb_snd_nxt;`）
  ⇒ 设计件 §1.4"不会-B（FIN 路径结构性 drift = 0）"成立；且 build F 根本不发 FIN。
- **RST**：两条源都不可达（上文 2/5）。
⇒ **drift > 0 在 build F 上不可达 ⇒ 幽灵不可达**（【推断】；依据 = 源码逐行 + 板级控制帧计数为 0，**两条腿**）。

---

## 3. S-0 构型（逐参数）—— 实际跑的臂

| 臂 | sink 参数（逐字） | 结果 | pcap |
|---|---|---|---|
| **S0A** | `--host 192.168.100.2 --port 8080 --rcvbuf 2920 --conns 6 --seconds 60 --maxbytes 200000000 --check lane8` | 53.2 s；6 连接（3 完成 / 3 STALL） | ①控制帧普查（FIN/RST 全窗）②环形全帧（板→对端，200MB×6） |
| **S0B** | 同上，`--rcvbuf 2920 --conns 1 --maxbytes 200000000` | 15.2 s；**首连接**、32,120 B 后 STALL | 同上 |
| **S0C** | 同上，`--rcvbuf 49152 --conns 1 --maxbytes 400000000` | 0.79 s / 400 MB / **4.07 Gbps** | 同上 |

**台架逐字（必须随读数一起读）**
- **sink = 本轮未动的部署件** `/tmp/p7b_biz/p7b_tcp_sink`，md5 **`c6b624205d64f1f4bd723d8fd5cc6414`**。
  ⚠️ **它是 sinkfix 之前的旧件**（`strings | grep -c "rcvbuf-after-connect"` = **0**、`"RCVBUF_ORDER"` = **0**）
  ⇒ 行为 = `SO_RCVBUF` 在 `connect()` **之后**落位（= 派单书点名的"**显式旧落点**"语义），**未在新目录重编译**。
- 取数器 `/tmp/p7b_biz/p7b_snap.sh` md5 **`ba2faf79f409302d1e542450db402975`**（**与仓库逐字相同**；默认 `NW=70 / EXPECT_BID=0x1A` = 正合构建 F，**未改**）。
- 快照字表（0.15 s/点）：`W5 W20 W43 W51 W14 W15 W55 W57 W58`（W55=`tx_stat_retx` · W57=`o_retx_hi` · W58=`o_retx_active`）。
- 新增件（**全在 `/tmp/p7b_ghost/`**）：`run_s0.sh 39118819e4272bd1a590e3a0bd46efd1` ·
  `ghost_pcap.py` · `ghost_inject.py`（未用上，见 §7-1）· `replay_audit.py` · `align_check.py` · `align_check2.py` · `stream_zoom.py`（本地副本在 `_tools/`）。
- 抓包：**tcpdump 自报 0 丢包**（三臂、两向）；`Adaptive RX: off / rx-usecs 0` 逐字见证。
- ⚠️ **文件命名事故（TL 提示，已在报告注明）**：两次 `--get` 的模板串 `${t}` 未展开 ⇒ 落成**字面名**
  `runs${t}_sink.txt` / `runs${t}_snap.log`（**真实 tag = S0C**）。现已改名归位为
  `runs/S0C_sink.txt` / `runs/S0C_snap.log`（**内容一字未动**）；S0B 的对应件已另取。

---

## 4. 读数面与负对照

### 4.1 会话面（"非空见证"：`ΔW55 > 0`）
| 臂 | `W55`（`tx_stat_retx`）采样序列 | 备注 |
|---|---|---|
| S0A | `1 → 0x13 → … → 0xa7`（15 个取值 / 271 点） | 会话确实发生（0.15 s 采样 ⇒ 只是**下界**） |
| S0B | `0xa7 → 0xba → 0xbd`（167→186→189） | 15 s 内 +22 |
| S0C | `0xbd → 0xc9 → 0xd5 → 0xe3`（189→201→213→227） | **~2 s 内 +38**（重放密集档） |
- `W57`（`o_retx_hi`）**非 0 且随流前进**（S0A `0x1234eac1→0x1235571d`；S0C `0x1234f629→0x2628d218`）⇒ 会话上界在动。
- ⚠️ **`W58` 在 0.15 s 采样下恒 0**：会话是 **µs 级**（帧期 ~193 拍）⇒ 采样**结构性看不见**"会话进行中"
  ⇒ 这一格本轮**没有读数**（不许写成"没有会话进行中"）。

### 4.2 内容面（**唯一能看见本缺陷的口径**）
1. **S0B（首连接 ⇒ 图案相位 = 0、sink 校验器有效）**：`SINK_CONN 0 STALL bytes=32120 first_mismatch=-1 mism_bytes=0`
   ⇒ 读到的 **32,120 字节逐字节等于图案**；随后 **STALL**（微窗家族，见 6-②）。
2. **S0C**：`SINK_SUM bytes=400001895 first_mismatch=0 mism_bytes=398439950`
   ⛔ **这不是幽灵，是相位错**：`mism ≈ bytes − bytes/256`（巧合匹配 1/256）—— 与 TL 给的判据
   （`p7b_microwin_20261010/REPORT.md` **§⑤-1**：`first_mismatch=0` + `checked − mism ≈ n/256` = 相位错）逐条吻合。
   **根因见 4.3（是我的构型/台架引入的，不是板缺陷）**。
3. **独立口径 ①（不依赖图案对齐）—— `replay_audit.py` on S0C 全帧 pcap**：
   ```
   AUDIT total_segments=274391
   TOT_BYTES 400610715  UNIQ_BYTES 399987295  REDUNDANCY 1.001559  REPLAY_BYTES 399987295
   CONTENT_CHANGES 0
   STREAM n=399985836 holes=0
   LAP_COMPARE hits=1561059/399920300 rate=0.003903 (随机期望 0.003906) runs>=4: 0
   ```
   ⇒ **同一 seq 的每次传输逐字节恒同（0 内容变化）** · **seq 空间无洞** · **"上一圈自比"= 随机率**（无 65536 周期陈旧字节）。
4. ⭐ **独立口径 ②（相位校正后的内容核查）—— `align_check2.py`（已跑完）**：
   ```
   ALIGN2 segs=274391 n=399987295
   K0=37960
   ALIGN2_DONE verified_prefix=399987295 n=399987295 breaks=0
   ```
   ⇒ 先扫出 32 字节窗口的对齐偏移 **`K0 = 37960`**（≠ 0 ⇒ 再次印证相位错），然后**全流 400 MB 逐 64 KB 块比对、
   `breaks = 0`** ⇒ **该连接线上每一个字节 = 图案序列在该偏移下的对应字节**（含全部重放段）。
   ⇒ 本轮**最强的内容读数**：**没有陈旧环字节、没有越界重放内容、没有任何"首次传输即脏"的字节**。
   ⚠️ 口径边界：它证明的是"**流 = 图案的一段**"，**不能**单独证明"该段起点正确"（起点由 4.3 的机理单独解释）。

### 4.3 ⚠️ 相位错的来源（**必须与幽灵分开**）
- **形态**：失配从**第 0 字节**起、≈ 全量（巧合匹配 ≈ 1/256）；`first_mismatch=0`。
- **根因（源码 + 本轮实证）**：**连续模式下 `app_pattern` 不重启图案流**。
  换流门 `rtl/app_pattern.v:742` 一带逐字 `if (up_ok) begin … tx_lfsr <= SEED; …`，
  其判据（同段注释逐字）：`up_ok = !active || ((up_slot == act_id) && (frm_wait || seg_sent==0))`，
  注释自己写明动机："P5d-D2: 同槽 ev_up = **新会话** … 继续旧流会让对端**整段错位**"。
  `TX_CONTINUOUS=1` 下 `active` 恒 1 ⇒ **只有"帧间隙"这一窄窗**才接受换流；否则**沿用旧 LFSR**
  ⇒ 对端看到的整条流 = 图案序列的**另一段**（不是从 `SEED` 起），且起点由 app 累计产出量决定、**与台架无关**。
- **本轮实测命中**：S0A 6 条连接中 **3 条**（对齐偏移 `64240 / 37960 / 62780`；`stream_zoom.py` 显示
  "前 1440 字节对齐、其后在 ±2^17 内无对齐"）；**S0C 整条 400 MB**（`K0 = 37960`）。
  交叉自洽：S0C 的 `K0`（37960）= S0A 里 42074 那条的起点；而 S0B 那条是 **0**（app 在那次重连里被接受换流）
  ⇒ "LFSR 只在被接受的 `ev_up` 复位、其余时间随产出推进"这一模型与三跑读数自洽。
- **与幽灵的三条区别**（TL 要求分开写）：① 量级（整条流 vs 0/1 字节/事件）② 形态（从头错 vs 尾部错）
  ③ 机理（app 换流门 vs 环重放上界）⇒ **不许当幽灵读**；也**不裁定**为本位流的新缺陷
  （属**已登记 A3/A7「`ev_up` 被吞」家族**的连续模式新触发面，本轮**只登记**）。

### 4.4 负对照（S-2）与"判据能判什么"
派单书要求的负对照 = "把 abort 拿掉/不触发会话 ⇒ 失配应为 0"。**本轮所有臂本身就是"无控制帧"臂**
（abort 不可达 ⇒ 板侧 FIN/RST = 0）。在此前提下：
- **对齐无关口径**：S0C 400 MB → `CONTENT_CHANGES 0` + 上一圈自比 = 随机率 ✓；
- **相位校正口径**：S0C 400 MB → `breaks = 0`（全流 = 图案一段）✓；
- **sink 口径（相位正确时才有判别力）**：S0B（相位 0）→ `mism_bytes = 0` ✓；S0C（相位错）→ **无判别力**。
⚠️ **诚实口径（TL 点名）**：本轮的"失配 = 0"只覆盖（a）**相位正确的那条连接（32 KB）**与（b）**对齐无关/相位校正审计
（400 MB）**。因为**触发条件（控制帧 +1）结构性缺席**，`mism_bytes` 即便为 0 **也不能反证幽灵不存在**
⇒ **该判据对幽灵在本构型下是【空判据】**（本报告不据此下任何裁定）。

---

## 5. 结论句（"观测到 / 未观测到"）

- ⛔ **未观测到** 形态①（顶部漂移）幽灵的**必要条件**：板侧 FIN/RST = 0（全窗普查，53 s / 6 连接）。
- ⛔ **未观测到** 幽灵的**签名**：相位正确的连接（S0B 32,120 B）零失配；相位校正后 400 MB 零断点；
  同 seq 内容 0 变化；seq 空间无洞；无上一圈周期性。
- ⛔ **不许写成"板上不存在幽灵"**。本轮判据**看得见 / 看不见**如下：
  - **看得见**：板侧 FIN/RST 的有无与 seq（全窗 pcap，0 丢包）· 线上载荷逐字节（相位校正后 **全覆盖 400 MB**）·
    **同一 seq 重传内容是否恒定**（对齐无关）· **seq 空间完整性**（洞/重叠）· 重放**会话计数**（`ΔW55`）与**上界**（`W57`）。
  - **看不见**：① **触发构型本身**（无 abort 通路 ⇒ "数据 → RST → 会话"序列造不出来）；
    ② **sink 口径在相位错时对内容全盲**（§4.3；相位校正口径可补，但需先知道相位）；
    ③ **`W58` 会话进行中**（采样慢于会话）；
    ④ **环写高水位 `wrhi`**（build F **没有** `whi_r` —— 它是修复刀新增的，**无法直接读"重放越界了几字节"**）；
    ⑤ **对端栈内部**（OFO/交付/重复段，本轮未查）。
- 综上：本轮把"板级有没有形态①"从**推断**推进到"**在该位流上不可触发、且沿路看不到任何签名**"；
  **没有**、也**不可能**在本轮给出"板上不存在"的结论。

---

## 6. 附带发现（如实登记，均**不是**幽灵）

1. ⚠️ **连续模式"换流门"造成对端整段相位错**（§4.3）—— A3/A7 同族、新形态；影响面：
   **所有带 `TX_CONTINUOUS=1` 的位流**在"对端断开→重连"时对端逐字节校验器整条失配 ⇒
   **多连接长跑的 `mism_bytes` 不再是内容判据**（本轮 S0A/S0C 都吃了这一刀）。
   （历史对照：Stage B/C 轮的"30 连 `mismatch_bytes=0`"跑在**连续模式之前**的位流上 —— 那时 app 每连发满即 close、
   下条重连时 app 已 idle ⇒ 换流被接受 ⇒ 相位 0。）
2. **微窗 STALL 复现**：S0B（`--rcvbuf 2920` 单连接）**复现**（先发 ~32 KB、此后 15 s 零帧；sink `POLL_TIMEOUT 3×5000 ms`），
   与 `p7b_microwin_20261010` 家族一致（板缺 zero-window persist + `snd_wnd==0` 时 RTO 卸膛）。本轮**只复现、未重复其机理实验**。
3. **重放密集但内容干净**：S0C 冗余率 **1.001559**（274,391 段 / 400,610,715 B），期间 `ΔW55 = +38`；
   **零内容变化**（且相位校正后零断点）。
4. **"板侧从不发 FIN/RST"与历史文书"每连接 2 个 FIN"不符**：本轮 53 s / 6 连接全窗普查**一个板侧 FIN 都没有**。
   ⚠️ 本轮**不裁定**谁错（历史读数可能把**对端**的 FIN 记成板的，或出自别的位流/构型）；**登记为待核**
   （核查法：对历史 pcap 按 `ip.src` 分类重数）。

---

## 7. 未定项 / 做不了的点

1. **abort 通路要"能跑"必须改构建**（把 app_ctrl 寄存器总线接进 axi_regs，或加 VIO）——本轮**未构建**
   （派单只授权跑读数；且**不许再起第二个 Vivado**）。`_tools/ghost_inject.py`（abort 注入器 + 板侧注册器轮询）
   因此**未使用**，随件留档 —— ⚠️ **下游若照它跑，会因 `0x0A/0x10+4c` 不可达而读到别的字**（本报告 §2-3 即此项的现核）。
2. **§2 的"fin 支会掩掉 RST 的 +1"**只有**源码依据**，**无板级对照臂**（造不出 RST）⇒ 按【推断】读；
   要证它需先有 §7-1 的构建。
3. **形态②（区间内洞）板级不可达**：本轮**未复核**设计件 §1.1b 的依据（本轮未引为结论）。
4. **对端栈内部**（`TcpExtTCPOFOQueue`/重复段交付）**未查** ⇒ 设计件 U2（"对端把幽灵当重复还是新数据"）**未答**。
5. **`W58`/`W57` 的会话级读数**需要更快的取数（本轮 0.15 s 采样只给计数下界）。
6. **明确未做**：拆刀/对照臂（无 RST 可拆）· pace 阶梯 · 上行方向 · 多连接并发（sink 是顺序连接）· 受控停流 · SIGSTOP 造零窗。

---

## 8. 收尾状态

- 板侧跑后态（每跑末自核）：`0x04 = 0x0000001a` · `0x08 = 0` · `carrier = 1` · **无残留 sink/tcpdump 进程**。
- ⚠️ **本轮未做"受控停流"**（`0x08` 保持 0 = 发射开）：下游接手请按"**板上 = 构建 F（修复前）+ 发射开**"读；
  要停流 = `reg_rw /dev/xdma0_user 0x08 w 0x2`。
- **未烧任何其它位流**（全场只烧一次归档 F 副本）；**未写 QSPI**；对端 `/tmp/p7b_biz/` 逐字未动。

---

## 附录 A. 逐字命令（可复跑）

```bash
# 0) 只读自检 → STEP0_selfcheck.txt
MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8 bash _proj_10g/notes/p7b_defect_board_20261011/step0_selfcheck.sh
# 1) 烧归档 F 副本 + rescan + 身份 → burn/BURN_F_archive.log + burn/id_F_archive_*.txt
MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8 bash _proj_10g/notes/p7b_defect_board_20261011/burn_F_archive.sh
# 2) 三臂（对端机 root；脚本已部署 /tmp/p7b_ghost/）
PEER_PW=111111 python tools/peer_ssh.py --sudo --timeout 300 "cd /tmp/p7b_ghost && bash run_s0.sh S0A 2920   6 60 200000000 1"
PEER_PW=111111 python tools/peer_ssh.py --sudo --timeout 300 "cd /tmp/p7b_ghost && bash run_s0.sh S0B 2920   1 60 200000000 1"
PEER_PW=111111 python tools/peer_ssh.py --sudo --timeout 300 "cd /tmp/p7b_ghost && bash run_s0.sh S0C 49152  1 60 400000000 1"
# 3) 分析（对端就地跑，不搬 600 MB pcap）
python3 /tmp/p7b_ghost/ghost_pcap.py    /tmp/ghost_S0A_full.pcap0 … pcap3
python3 /tmp/p7b_ghost/replay_audit.py  /tmp/ghost_S0C_full.pcap0 … pcap2 8080
python3 /tmp/p7b_ghost/align_check2.py  /tmp/ghost_S0C_full.pcap0 … pcap2 8080   # K0=37960, breaks=0
```

## 附录 B. 文件清单（本目录）

| 文件 | 内容 |
|---|---|
| `STEP0_selfcheck.txt` | 烧前自检（归档 sha / 工具 md5 / 板上现态 / 身份） |
| `burn_F_archive.sh` · `burn/BURN_F_archive.log` · `burn/id_F_archive_*.txt` · `burn/wrapper_p4_F_archive.bit` | 烧录件与判据 |
| `_tools/{run_s0.sh, ghost_inject.py, ghost_pcap.py, replay_audit.py, align_check.py, align_check2.py, stream_zoom.py, fix_apos.py}` | 本轮新增工具 |
| `runs/S0{A,B,C}_stdout.txt` | 各臂原始 stdout（sink 摘要 / 内核计数 / 抓包统计 / 跑后板侧态） |
| `runs/S0A_ctl.pcap` | 控制帧普查原件（21 包，**全为对端→板**） |
| `runs/S0{A,B,C}_snap.log` | 板侧快照序列（W5/W20/W43/W51/W14/W15/W55/W57/W58） |
| `runs/S0B_sink.txt` · `runs/S0C_sink.txt` | sink 全文（⚠️ `S0C_sink.txt` 由图名字面件改名而来） |
| 对端 `/tmp/ghost_S0{A,B,C}_full.pcap*` | 环形全帧 pcap（**未搬回本机**；分析在对端就地做） |
