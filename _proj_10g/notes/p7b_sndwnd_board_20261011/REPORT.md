# P7b snd_wnd 守卫 板级轮 —— 报告（2026-10-11）

> **两臂** = **0x1E（含守卫）** sha256 `e489ae4a…be1a` · **0x1D（不含守卫 = 负对照）** sha256 `b48dc7ee…0b1f`
> （两位流各 **15,431,261 B**、快照 **70 字**、未实现地址 `0x138`；**只有 sha256/BID 能分版**）。
> **零构建**（`rtl/ tb/ sim/ board/` 一字未动；未起 Vivado 综合/实现，只有烧录那一下起了 batch Vivado）·
> 只走 JTAG 易失烧录（**未写 QSPI**）· **未改 `/tmp/p7b_biz/` 现役工具**（新件全落 `/tmp/p7b_sndwnd/`，逐件记 md5）·
> 未碰 `D:\repo\perfv` · git 只读（本轮未提交）。
> **本件不给 PASS/FAIL 裁定**；结论句一律"**观测到 / 未观测到**"口径（**不写"不存在"**）；不写"时序已解决"。
> 全部读数 = 本轮现取；原件在 `runs/` `burn/` `_tools/`。
> 守卫内容与结构化证据（网表侧）= `p7b_build_0x1E/REPORT.md`（`ackok_l_reg → pend_wnd_val_reg[*]/CE` 连通性 n=5 条）；
> 本件**只做板级行为**。

---

## 0. 三行结论

1. ⭐ **task-2（persist 回归）成立**：0x1E 上 **9 条 1 字节探询**出现（SYN+0.16…+0.68 s），逐字段 **9/9 核过**
   （`IP total_len=41` ⇒ 去填充 55 B / `len==1` / flags `0x18` / **`seq` == 对端同期 ACK 的 `ack`** / **payload == 图案流该 offset 的字节**）；
   sink **收满 400,000,435 B 零失配**、`stall_conns=0`；板侧 `ΔW20 = 264,891` ⇒ **守卫没有打死 persist**。
2. ⭐⭐ **task-3/4（守卫判别）在 c2s（真零窗停滞）构型上得到干净二值 A/B、且每臂 ×2 复现**：
   同一注入（**不可接受 ACK**（`ack = fresh − 4 MiB`）+ **`win=65535`**，帧已证上线）——
   **0x1E：注入窗内板 0 帧**（`ΔW20=0 / ΔW51=0 / ΔW55=0`，探询阶梯原时不动）；
   **0x1D：板在注入时刻立刻发突发**（capC **103 / 98 帧**、145,746 / 138,246 B、43 个不同 `seq`（1460 B 步）+ 54/49 重复帧），
   板侧 `ΔW20` 窗内 **+100 / 88 / 44**、`ΔW55` **+2**、**探询阶梯重置**（探询落在注入后 +20 ms，随后 5 s / 10 s 档）
   ⇒ **守卫确实拦住了"不可接受 ACK 的窗覆盖"**（0x1E）；同一注入在 0x1D 上确实把窗写了（突发即证据）。
3. ⚠️ **letter 版（活跃流 + `win=0`）两臂均未见差别（如实报）**：该构型**本身**有 ms 级自然间隙（p999=0.29–0.31 ms、max≈3 ms），
   远大于"假零窗"的 ≤1 ACK-interval 效应 ⇒ **本构型对 ≤3 ms 的效应无判别力**；
   且 **0x1D letter 臂的 `win=0` 是否写进 TCB 无法判定**（效应被自然抖动掩蔽）。这不是"守卫没起作用"的证据 —— 判别证据见第 2 行的 c2s A/B。

---

## 1. 烧录与身份（原始读数）

| 项 | 0x1E 臂 | 0x1D 臂（负对照） | 出处 |
|---|---|---|---|
| 归档源 | `p7b_build_0x1E/wrapper_p4.bit` | `p7b_build_0x1D/wrapper_p4.bit` | 派单指定 |
| 归档 sha256（烧前核） | `e489ae4a4b868695cff1c6dfc2fbdef70de29d391cdb9a43e0a08accd342be1a` | `b48dc7ee7ddb7df2a057fdae324dbf302c5adc6f430a413e0bce0e3a25ee0b1f` | `STEP0_selfcheck.txt` §A |
| 烧录件副本 sha256 | 同（`burn/wrapper_p4_0x1E.bit`） | 同（`burn/wrapper_p4_0x1D.bit`） | `burn/BURN_0x1E_*` / `burn/BURN_0x1D_*` |
| 五条烧录判据 | `End of startup status: HIGH` ✓ · 非注释行 `TCPREG_PROG_DONE` ✓ · 位流路径含副本名 ✓ · stdout 新鲜 ✓ · 无 `TCPREG-ABORT` ✓ | 同 | 同上 |
| 板侧 `ID_BID 0x04` | **`0x0000001e`** | **`0x0000001d`** | `burn/` 与每跑 `runs/*.txt` 身份闸（`ID_OK RC=0`，每跑现取） |
| `ID_MAGIC / ID_MARKER / ID_UNIMPL 0x138` | `0x50360001` / `0xdeadbeef` / `0xffffffff` | 同 | 同上 |
| `SCRATCH 0x08` / `carrier` | `0x00000000` / `1`（全程；**未停流**） | 同 | 每跑跑前/跑后与 `runs/FINAL_STATE_0x1E.txt` |
| `LnkSta` / BARs | `5GT/s x4` / `2 BARs`（Region0 1M + Region1 64K） | 同 | `burn/BURN_*` 内 rescan 段 |
| rescan | 设备级 `remove`+`rescan` 一次成功（每次烧后） | 同 | 同上 |
| 烧录次数 | 3（08:26:45 / **08:40:15 重烧**用于重复臂，两跑间板未动） | 1（08:32:11） | — |

**读侧口径**：对端部署件 `/tmp/p7b_biz/p7b_snap.sh` md5 `ba2faf79…` 默认 `EXPECT_BID=0x0000001D`
⇒ **每一跑显式**传 `EXPECT_BID=<该臂>` + `NW=70`（跑内见证行 `### EXPECT_BID=… NW=70`）；`ID_OK` 是显式覆盖后的读数，
`ID_UNIMPL 0x138` 是当场断言（70 字判据）。**0x1E 臂全程用 `EXPECT_BID=0x0000001E` 覆盖**（派单口径）。

---

## 2. 三个构型（逐参数）+ 跑次总表

| 跑 | 臂 | 构型 | 注入 | 结果一行 |
|---|---|---|---|---|
| **R1_PA** | 0x1E | **P-A**（照抄 persist 轮）：sink(refresh 件) `--rcvbuf 1460 --rcvbuf-after-connect --conns 1 --seconds 45 --maxbytes 400000000 --check lane8 --poll-ms 5000 --stall-n 3` + 注入器 `PROBE_WIN=0 ACK_MODE=fresh` @SYN+3.0 s ×3 | 见 §3.3 | **9 条探询**（task-2 判据）+ sink 400 MB 零失配 |
| **R2_ACTIVE** | 0x1E | **active**（活跃流）：sink `--rcvbuf 2920`（默认 before_connect，**在读**）`--conns 1 --seconds 40 --maxbytes 4000000000 --check lane8` + 注入器 `PROBE_WIN=0 ACK_MODE=fresh_minus ACK_OFFSET=4194304` @SYN+10.0 s ×5 | 见 §4.1 | 0 探询；sink 4.000 GB 零失配；两臂无差别 |
| R2b_ACTIVE | 0x1E | 同上（重复臂；增 capE 注入帧抓包） | 见 §4.1 | 同上（0 探询；sink 4.000 GB 零失配） |
| R3_ACTIVE | 0x1D | 同上（同位素） | 见 §4.1 | 同上（0 探询；sink 4.000 GB 零失配） |
| R3b_ACTIVE | 0x1D | 同上（重复臂；增 capE） | 见 §4.1 | 同上 |
| **R4E_C2S** | 0x1E | **c2s**（真零窗停滞）：`persist_client.py --rcvbuf 2920 --order after --secs 40`（**永不读**）+ 注入器 `PROBE_WIN=65535 ACK_MODE=fresh_minus` @SYN+8.0 s ×3 | 见 §5.1 | **注入窗内板 0 帧**；探询阶梯 0.02/5/15/35 s 不动 |
| R4E2_C2S | 0x1E | 同上（重复） | 见 §5.1 | 同上（0 帧；阶梯同） |
| **R4D_C2S** | 0x1D | 同上（同位素） | 见 §5.1 | **突发 103 帧 / 145,746 B** + `ΔW55`+2 + **阶梯重置** |
| R4D2_C2S | 0x1D | 同上（重复） | 见 §5.1 | **突发 98 帧 / 138,246 B** + `ΔW55`+2 + **阶梯重置** |

**注入器的 ack 取法（U7）**：三种构型都按 U7 用**注入时刻现取**的 ack（见 §3.3 与 §7.2 的 diff）；`ACK_MODE`
只决定"直接用 / 减 4 MiB / 加 4 MiB"。**判别臂用 `fresh_minus`（刻意不可接受：`ack` 远在 `snd_una` 之下）**。

---

## 3. task-2：R1（0x1E，P-A 构型）persist 回归 —— **探询仍在**

### 3.1 探询帧逐字段（`runs/R1_PA_0x1E_probe_verify.txt`，9/9）

| # | t (SYN+…s) | seq | off=seq−(ISN+1) | payload | 图案流该 offset | 对端前一条 ACK 的 ack | 帧长 |
|---|---|---|---|---|---|---|---|
| 1 | +0.158 | `0x1234a651` | 20,440 | `0xd6` | `0xd6` **MATCH** | `0x1234a651` **== seq** | tot_len 41（=55 B 线上，origlen 60 去填充） |
| 2 | +0.198 | `0x1234ac05` | 21,900 | `0xa4` | `0xa4` MATCH | `0x1234ac05` == | 同 |
| 3 | +0.298 | `0x1234d3f1` | 32,120 | `0xce` | `0xce` MATCH | `0x1234d3f1` == | 同 |
| 4 | +0.338 | `0x1234d9a5` | 33,580 | `0xc5` | `0xc5` MATCH | `0x1234d9a5` == | 同 |
| 5 | +0.479 | `0x12351861` | 49,640 | `0xc3` | `0xc3` MATCH | `0x12351861` == | 同 |
| 6 | +0.519 | `0x12351e15` | 51,100 | `0x26` | `0x26` MATCH | `0x12351e15` == | 同 |
| 7 | +0.559 | `0x123523c9` | 52,560 | `0x44` | `0x44` MATCH | `0x123523c9` == | 同 |
| 8 | +0.599 | `0x12352f31` | 55,480 | `0xdd` | `0xdd` MATCH | `0x12352f31` == | 同 |
| 9 | +0.680 | `0x12354601` | 61,320 | `0xaa` | `0xaa` MATCH | `0x12354601` == | 同 |

- 探询 `ack` 字段恒 = `0x24990d5e` = 对端 ISN+1 = 板 `rcv_nxt`（9/9）；探询前对端 ACK 的 `win` 全为 **0**（真零窗上下文）。
- 间隔（逐条实测）= 40.1 / 100.7 / 40.1 / 140.9 / 40.1 / 40.1 / 40.1 / 80.8 ms。
- ⚠️ **与上轮 0x1D 对照口径（不归因）**：persist 轮 0x1D 的 P1 = **3 条**、P5 = **10 条** ⇒ 0x1D 自身的历史带 = 3–10 条
  ⇒ 本轮 0x1E 的 **9 条落在该带内** ⇒ **不推论"守卫改变了探询数量"**。

### 3.2 其余 task-2 读数

| 项 | 读数（原文） |
|---|---|
| sink | `SINK_CONN 0 OK bytes=400000435 first_mismatch=-1 mism_bytes=0 dur_ms=4816.550 Mbps=664.377` · `SINK_SUM … fail_conns=0 bad_conns=0 mismatch_bytes=0 stall_conns=0 poll_tmo=0`（**sink 继续收 = 成立**） |
| `ΔW20 > 0` | 环内 `ΔW20 = 264,891`（≈55.0k fps；对应发送 ≈386.7 MB，与 `ΔW51 = 385,807,775` 自洽） |
| `W55`（重传次数）轨迹 | `0 → 11 → 25 → 37 → 45 → 53`（SYN+0.11…+0.80 s，即**探询/零窗 episode 内**），此后到跑末恒 53 —— 与 persist 轮 P1 的"episode 内 `ΔW55` 0→46"同族 |
| 注入窗内 `ΔW55` | **0 / 0 / 0**（三次注入的 ±0.92/0.74/0.75 s 窗）⇒ 活跃相注入**未引发重传** |
| `W69`（等窗拍 `{infl,eff}` 锁存）取值集合 | `{0x00000000, 0x05b40340, 0x22380340, 0x3ebc0340, 0x7d780000, 0xb6800340}` ⇒ `eff ∈ {0, 832}`（= persist 轮登记的微窗带） |
| `W66/W67` | 环内 `ΔW66 = 514,926,401`（等窗拍数，微窗 regime）、`ΔW67 = 385` |

### 3.3 注入的 (ack, win) 原始值 + **U7 新鲜度证据**（`runs/R1_PA_0x1E_probe.log`）

```
PROBE_START win=0 inject_at=3.0s n=3 gap=0.15 ack_mode=fresh ack_offset=4194304 sniff_ms=20.0 t=1791678549.044224
SNIFF_SYN lport=48428 isn=614010205 t=1791678551.034459
PROBE_TARGET lport=48428 isn=614010205 last_ack=527624597 last_win=832 (SYN+3.00s)
PROBE_INJECT i=0 ack=529697797 win=0 ack_src=fresh fresh_ack=529697797 fresh_win=832 t=1791678554.062241 (SYN+3.03s)
PROBE_INJECT i=1 ack=549847257 win=0 ack_src=fresh fresh_ack=549847257 fresh_win=832 t=1791678554.246239 (SYN+3.22s)
PROBE_INJECT i=2 ack=569536817 win=0 ack_src=fresh fresh_ack=569536817 fresh_win=832 t=1791678554.428173 (SYN+3.40s)
```

⭐ **`fresh_ack` 逐次前进（529.7 → 549.8 → 569.5 M，间隔 0.18 s ≈ 109 MB/s = 板当时实际流速）** ⇒
"**注入时刻现取**"确实生效（上一轮的注入器在这三处会用同一个一次性嗅到的值）。
⭐ **实测口径（如实登记）**：注入时该连接**已恢复成活跃流**（`last_win=832` 微窗、约 0.87 Gbps；probe 日志 `board_frames_after_inject=65,613`）
⇒ 本构型下"注入**被守卫收下**"这件事**没有直接见证**：注入窗内 `ΔW55=0 / 帧率无跌 / 无新探询`，
而窗口彼时本来就在 `0↔832` 摆动 ⇒ **"注入了但无可见变化"与"被守卫静默吞掉"在本构型上不可分辨**（登记，§6-③）。
（判别的意义上，这一格由第 5 节的 c2s A/B 承担 —— 在那里注入的"被收下"有**二值见证**。）

---

## 4. task-3/4 letter 版：R2/R2b（0x1E）vs R3/R3b（0x1D）—— 活跃流 + 不可接受 ACK + `win=0`

### 4.1 注入的 (ack, win) 原始值（四跑；`ack = fresh_ack − 4194304`，逐次现取）

| 跑 | lport/isn | i=0 (t, ack, fresh_ack) | i=1 | i=2 | i=3 | i=4 |
|---|---|---|---|---|---|---|
| R2 (0x1E) | 59474 / 2159905527 | +10.030s `1142478618` (=1146672922−4M) | +10.214s `1158062658` | +10.394s `1173215998` | +10.571s `1188667178` | +10.755s `1204197198` |
| R2b (0x1E) | 55868 / — | +10.03s `1110812678` | `1125695918` | `1141455158` | `1158245158` | `1174478898` |
| R3 (0x1D) | 49950 / 3345547335 | +10.03s `1249290758` | `1268917538` | `1288929758` | `1307430878` | `1326971518` |
| R3b (0x1D) | 41552 / — | +10.04s `1116299358` | `1132785678` | `1149048618` | `1165066278` | `1179953898` |

（win 一律 `0`；`ack_src=fresh` 全程；完整原文在各 `runs/*_probe.log`。）

### 4.2 注入帧**上线见证**（capE；`R2b`/`R3b` 新增的专用抓包：`tcp[14:2]=0` 的 对端→板 小帧）

- R2b：6 帧 = **5 条注入帧**（`sport=55868`、`seq=0x7ac9cfd5` 恒定、`ack` 与日志表逐条一致、`win=0`、`plen=0`、origlen 54）+ 1 条**连接早期的天然 `win=0` ACK**（`ack=0x123461e1` = 首 2 段）。
- R3b：6 帧 = **5 条注入帧**（`sport=41552`、`seq=0xa0cd65af`）+ 同款 1 条早期天然帧。
- ⚠️ R2/R3（首两跑）**没有** capE；其 `capB` 因 `-c 400000` 在 ~7 s 就被 ACK 流打满（注入在 +10 s）⇒ 首两跑**注入帧未进 pcap**（登记，§6-④）；R2b/R3b 补齐。

### 4.3 结果（两臂 ×2）

| 项 | 0x1E（R2 / R2b） | 0x1D（R3 / R3b） |
|---|---|---|
| 板→对端 1 字节探询 | **0** / **0** | **0** / **0** |
| sink | 4,000,000,850 B · `first_mismatch=-1 mism_bytes=0` · 754.151 / 725.365 Mbps · `stall_conns=0` | 同（4,000,000,850 B 零失配）· 860.244 / 721.075 Mbps · `stall_conns=0` |
| 注入窗内 `ΔW55` | 0,0,0,0,0 / 0,0,0,0,0 | 0,0,0,0,0 / **1**,0,0,0,0 |
| 注入窗内 `ΔW20` | 118,668–135,431 帧/窗（≈54–58k fps，**连续**） | 125,568–155,850 帧/窗（连续） |
| capD 数据帧间隙（注入窗 [t−0.3, t+2.0]） | max = **3.073 ms**（= 全程最大，且同样出现在**无注入处**：top-12 gaps 有 9 条在注入之前） | max = **2.900 ms**（同形；top-12 里 8 条在注入之前） |
| 间隙分布 | p50 15 µs / p99 31 µs / p999 305 µs | p50 13 µs / p99 27 µs / p999 289 µs |
| 探询（判据"无 1 字节探询"） | 成立（0） | 成立（0） |

**结论（如实）**：**四跑两臂未见差别** —— 无探询、无注入窗内新增间隙、无重传、速率连续。
⇒ ①"发送不被打断"在 0x1E 上**成立**；② **本构型对 ≤3 ms 的效应无判别力**（自然抖动本身 0.3–3 ms，
而"假零窗"的物理效应上限 ≈ 1 个 ACK interval（该构型 ≈ 13–27 µs）—— 远在分辨率之下）；
③ **0x1D 臂的 `win=0` 是否真的写进 TCB 不可判定**（若写了，自愈 ≤1 ACK interval ⇒ 被自然抖动吞掉）。
⇒ 本构型**不作为**守卫判别证据（判别证据 = 第 5 节）。

---

## 5. 守卫判别（本轮补强版）：c2s 构型 —— 真零窗停滞 + **假大窗**注入

**为什么加这一版（与派单字面的关系，写清楚）**：派单对 task-3 的字面是"活跃流 + `win=0/极小`"（= §4，已跑，无判别力）；
而"**不可接受 ACK 的窗覆盖**"要变成**可判读数**，需要满足两点：注入的窗值若被写入，**门状态必须变**，且**不被 1 个 ACK 内的真 ACK 立刻覆盖**。
在"对端真零窗停滞 + 板已武装 persist"的连接上（= persist 轮 P-C(c2b) 构型）二者同时满足：
**假窗参数取 `win=65535`（"明显错误"的形态 = 在真窗为 0 的连接上伪造一个大窗）**；
若字面取 `win=0`，则在"真窗已是 0"的连接上写入与否**同样是 no-op（空判据）**。
⇒ 本版 = 同一注入器/同一帧构造，只把 (win, 构型) 换成"能改门"的一对；**两臂同参数**（同位素性不破）。

### 5.1 注入 (ack, win) 原始值 + 上线见证（四跑）

```
R4E (0x1E): PROBE_TARGET lport=47788 isn=602975935 last_ack=305484137 last_win=0 (SYN+8.02s)
  i=0 ack=301289833 win=65535 ack_src=held fresh_ack=305484137 fresh_win=0 t=…(SYN+8.06s)
  i=1 ack=301289833 win=65535 ack_src=held … (SYN+8.24s)
  i=2 ack=301289833 win=65535 ack_src=held … (SYN+8.43s)
R4E2(0x1E): i=0/1/2 ack=301232893 win=65535（fresh_ack=305427197）(SYN+8.14/8.32/8.50s)
R4D (0x1D): PROBE_TARGET lport=58674 isn=190368553 last_ack=305438877 last_win=0 (SYN+8.02s)
  i=0/1/2 ack=301244573 win=65535 ack_src=held (SYN+8.063/8.245/8.433s)
R4D2(0x1D): i=0/1/2 ack=301237273 win=65535（fresh_ack=305431577）(SYN+8.061/8.245/8.432s)
```

- `ack_src=held` = 停滞期**对端 ACK 流已停**（`drain_latest` 收集窗内无新包 ⇒ 沿用最近值）——**这正是 U7 要防的场景的反面**：
  停滞连接的板 `snd_una` 是**冻结**的 ⇒ 该 ack 持续有效（`ack = fresh − 4 MiB` 恒低于 `snd_una` ⇒ 恒**不可接受**，两臂同样）。
- **帧上线见证**（`pcap` 直读）：四跑各 **3/3** 命中（源/目的/`seq=isn+1`/`ack`/`win` 与日志逐条一致）。
- 客户端旁证：`CLIENT_SO_RCVBUF_SET_AFTER_CONNECT req=2920 now=5840` + `CLIENT_TICK … noread=1` ×8（40 s 一个字节不读）。

### 5.2 结果（板侧原始读数）

| 项 | 0x1E R4E | 0x1E R4E2 | 0x1D R4D | 0x1D R4D2 |
|---|---|---|---|---|
| **注入窗 [t−0.5, t+0.5] 内板帧（capC）** | **0 / 0 / 0 帧** | **0 / 0 / 0 帧** | **103 / 103 / 103 帧**（重叠窗；实际一段 97 帧） | **98 / 98 / 98 帧**（实际 92 帧） |
| 字节数 | 0 | 0 | 145,746 B | 138,246 B |
| 突发时间结构 | — | — | 首帧 t = 注入 + **0.00007 s**；span 0.390 s | 首帧 t = 注入 ±0.0001 s；span 0.391 s |
| 突发内容 | — | — | **43 个不同 `seq`**（1460 B 步、覆盖 ≈62 KB ≈ `WIN_CAP`）+ **54 个重复帧** | 43 个不同 + **49 个重复** |
| 板侧 `ΔW20`（窗内, snap） | 0 / 0 / 0 | 0 / 0 / 0 | **+100 / +88 / +44**（同段重叠窗） | **+95 / +88 / +44** |
| 全程 `ΔW20` | **53** | **55** | **155** | **154** |
| 全程 `ΔW51`（app 发字节） | 65,700（=45×1460 = 初突发） | 65,700 | 81,760 | 74,460 |
| 全程 `ΔW55`（重传数） | **1** | **1** | **3**（注入窗内 +2） | **3**（注入窗内 +2） |
| `W69` 跑末（`{infl,eff}`） | `0xc79cc79c` | `0xf53cf000`（eff=`0xf000`=61,440） | `0xf53c0000`（infl=`0xf53c`=62,780 = 43×1460，**eff=0**） | 同 `0xf53c0000` |
| 探询时刻（去重后） | +0.020 / +5.020 / **+15.020** / **+35.019** s | +0.020 / +5.020 / +15.020 / +35.020 s | +0.020 / +5.020 / **+8.083 / +8.285 / +8.473** / +13.473 / +23.472 s | +0.020 / +5.020 / +8.082 / +8.285 / +8.472 / +13.472 / +23.472 s |
| 探询帧形 | 55 B / `len==1` / flags `0x18` / `win=49152`（同 persist 轮） | 同 | 同 | 同 |

### 5.3 两臂差 = 守卫的判别证据（读法与边界，写清楚）

1. **0x1D（无守卫）**：注入帧上线 ⇒ **`win=65535` 被写进 `snd_wnd`** ⇒ 门开 ⇒ 板在**注入时刻**（首帧延迟 <0.1 ms）发出
   约一个窗容的突发（43 段 ×1460 ≈ 62 KB，与 `WIN_CAP`=61,440 同量级；其中 54/49 帧为重复 = 重放/重传族，`ΔW55`+2 同源）
   ⇒ 对端（不读）丢弃 ⇒ **窗口被重新关到 0** ⇒ `snd_wnd==0 ∧ 在飞>0` ⇒ persist **重新武装** ⇒ **探询阶梯重置**
   （探询落在注入后 **+20 ms**，随后 5 s / 10 s 档）⇒ 板侧 `W69` 锁存 `infl=62,780 / eff=0`（= 突发后的停滞现场）。**×2 复现**。
2. **0x1E（含守卫）**：**同一条注入帧上线**（3/3 证）但 **板 0 反应**（0 帧 / 0 字节 / `ΔW20=0` / `ΔW55=0`），
   探询阶梯**原时不动**（0.02/5/15/35 s）⇒ **`ackok_l` 守卫把该帧的窗写入整个拦下**（该帧的 ack 不可接受 ⇒ 置位门与值锁存成对不放行，见 `p7b_build_0x1E/REPORT.md` 的网表连通性证据）。**×2 复现**。
3. **边界（不许放宽）**：本 A/B 证的是"**该注入帧的窗覆盖被守卫拦住**"（行为层、二值、可复现）；
   **不**声称"任何不可接受 ACK 都被拦住"（另一形态：`ack > ack_hi` 的越界 ACK 本轮未注入 —— 登记，§6-⑨）；
   也**不**声称"守卫的谓词实现与设计件逐字一致"（那是源码/网表层的读数，属构建轮取证面）。

---

## 6. 未观测到 / 做不到 / 与派单描述不符（逐条，如实）

1. ⚠️ **letter 构型（§4）对本判别无功效**：自然抖动（p999 ≈ 0.3 ms、max ≈ 3 ms）比"假零窗"的物理效应上限（≈1 个 ACK interval，13–27 µs）**大两个数量级** ⇒ 两臂无差别**是构型的性质**，不是"守卫没起作用/起作用"的证据。
2. ⛔ **0x1D letter 臂的 `win=0` 是否写进 TCB 不可判定**（同上被掩蔽）；可判定的等价证据来自 §5（同一注入器/同款帧在 0x1D 上确实到达 TCB 写口 —— 突发就是窗口被写了的直接读数）。
3. ⛔ **P-A 构型下"注入被收下"结构性无见证**：注入时该连接已被 persist 恢复成活跃流（微窗 832），窗口本就在 `0↔832` 摆动 ⇒ 注入的 `win=0` 无论写不写都不可分辨；上轮同款结论（"注入的作用 = 把窗口钉在 0"）本轮也**只能**按"注入后无可见变化/无新重传"读。`ΔW66/ΔW67/W69` 按 U7 建议落档（§3.2），但**未**给出判别性形态。
4. ⚠️ **capB 的 `-c 400000` 在活跃构型下 ~7 s 即打满**（ACK 流是 ≤100 B 帧）⇒ R2/R3 首两跑的**注入帧未进 pcap**；已加 **capE**（专用过滤器 `tcp[14:2]=0`）在 R2b/R3b 上补齐（6/6 命中，含 1 条连接早期天然 `win=0` 帧的旁杂，已逐帧标出）。
5. ⚠️ **R1 的快照环未覆盖注入后 ≥2 s**（该跑 4.8 s 就被 sink 收满 400 MB 结束、环 6.68 s）⇒ R1 注入窗的 `ΔW55/ΔW66` 只能用 ≤0.75 s 后余量取（已取，全 0）；R2/R3/R4 四跑无此限制。
6. ⚠️ **活跃流上"新鲜 ack"与"板 `snd_una` 推进"存在竞态**（收集窗 20 ms ⇒ ack 可能已落后板 `snd_una`）：
   本轮 R2/R3 的注入 ack 是**刻意不可接受**的（偏移 4 MiB）⇒ 不影响其判别；**R1 的"可接受"注入是否被守卫放行 = 无见证**（§3.3）。
   ⭐ 实测新鲜度生效的证据 = `fresh_ack` 逐次前进（R1: +20 MB/0.18 s，与该连接当时的实际流速吻合）。
7. ⚠️ **探询数量的跨轮方差**：0x1E 本轮 9 条；0x1D 自身历史 3（P1）–10（P5）⇒ 不推论守卫改变了数量（同上 §3.1）。
8. ⚠️ **样本量**：R1 = n=1；R2/R3/R4 每臂 n=2（c2s 的关键二值差 ×2 逐位同形，但**不给分布**）。
9. ⛔ **未注入的形态**：`fresh_plus`（`ack > ack_hi` 的越界 ACK）本轮**未跑**（注入器支持，两臂同参即可复跑）；`win=极小值`（如 1/832）也**未跑**。
10. ⚠️ **与派单措辞的差异（主动登记）**：派单 task-3 写"**同一活跃流**上" —— 本轮按"**同一（仍活着的）连接**"读，并把它拆成两个构型各做一遍：
    ① letter 版 = 独立 active 构型（§4，结果：无判别力）；② 功率版 = c2s 真零窗停滞连接（§5，结果：二值判别）。
    功率版**不是**派单字面参数（窗值取 65535 而非 0/极小），理由已写在 §5 开头（字面参数在该构型上是空判据）。
11. ⚠️ `ss.log` 逐跑已落档（0.5 s/点）但本轮**未逐跑解析**（client 侧窗口见证的判读留给需要时现读）。
12. ⚠️ **pcap 一律"对端网卡上抓的"**（`capA/capB/capC/capD/capE` 各跑自报 `0 packets dropped by kernel`，逐跑落档；capD 满 `-c` 停 = 正常截顶、非丢包）⇒ **不做"线上真值"级断言**。

---

## 7. 工具件与 md5 表 + U7 diff 原文

### 7.1 md5（本地 ↔ 对端逐件同值；部署在 `/tmp/p7b_sndwnd/`，**未动 `/tmp/p7b_biz/`**）

| 件 | 本地路径 | md5 | 说明 |
|---|---|---|---|
| 注入器（**U7 版，本轮新件**） | `_tools/stall_probe_u7.py` | `491698178ece2bb5fd974c7a659aa677` | 对端 `/tmp/p7b_sndwnd/stall_probe_u7.py` 同值 |
| 注入器底本（只读参照） | `_tools/stall_probe_orig_ref.py` | `2274c15975e78307dc9d9b286da03ffb` | = persist 轮 `stall_probe.py` 逐字副本（对端 `/tmp/p7b_persist/stall_probe.py` 同值） |
| 跑执行件（**本轮新件**） | `_tools/sndwnd_run.sh` | `20b6c8660feb4c74e934f15ef4671552` | 对端同值（含 capE 增补后） |
| 不读客户端（复用轮新件） | `_tools/persist_client.py` | `3fef080c9a80e02d0b793cbb7919f920` | = persist 轮同件 |
| 取数器（**未改**） | 对端 `/tmp/p7b_biz/p7b_snap.sh` | `ba2faf79f409302d1e542450db402975` | 默认 `EXPECT_BID=0x1A` ⇒ 每跑显式覆盖 |
| sink（sinkfix 后件） | 对端 `/tmp/p7b_biz_refresh/p7b_tcp_sink` | `6d9b14f24725fa326ffe5b169f77e30f` | 支持 `--rcvbuf-after-connect` |
| 分析件（本地只读跑） | `_tools/probe_analyze.py` / `probe_verify.py` / `arm_analyze.py` / `delta_window.py` / `snap_series.py` | `30e7fc00fb6171ab1f2ff87e119a3999` / `f8bec01ea2aab71d26bb942a0693b3ac` / `18bfe4b498be7ba49d5422f06949ca06` / `12cbe5af9f123d7f64c0b2e31fcc5cb1` / `ce7f973c195315fd3c3bacc9df980a88` | — |
| 烧录/自检件 | `burn_arm.sh` / `step0_selfcheck.sh` | `d3a665f8c771a9bfd7c7e51f3438b6e8` / `110b15f0605e96a73b39b6d1ec32be27` | — |
| 脚本件 | `tools/peer_ssh.py` | `cda810783c7659b64f4112a9b74f8aca` | 未改 |
| 环境面 | `ethtool -c enp1s0f1np1` = `Adaptive RX: off / rx-usecs: 0` | — | **一字未动**（步骤 0 现取） |

### 7.2 U7 diff 原文（`_tools/stall_probe_u7.diff`，完整逐字；可回退 = 弃用新件、直接用 `stall_probe_orig_ref.py`）
```diff
--- p7b_persist_board_20261011/_tools/stall_probe.py	2026-10-10 18:53:04.909890400 +0800
+++ p7b_sndwnd_board_20261011/_tools/stall_probe_u7.py	2026-10-11 08:26:10.942540700 +0800
@@ -1,12 +1,23 @@
 #!/usr/bin/env python3
-# stall_probe.py -- 微窗 stall 轮: 判别臂 (对端侧, 只发包不碰任何配置)
-#   stall 建立后, 从对端注入 N 个"重复 ACK" (ack = 已观测到的 rcv_nxt, win = 指定值)。
-#   若机理 = "板等一个窗口通告", 则 win>0 的注入应让板立刻恢复发送; win=0 应毫无变化。
-#   判据读数 = 板侧 W20(帧)/W55(retx) 与 sink 是否继续收数据。
-#   用法: PROBE_WIN=1460 bash stall_probe.py [等待秒数=3] [注入个数=3] [间隔秒=0.15]
+# stall_probe_u7.py -- P7b snd_wnd 守卫板级轮 (2026-10-11): 注入器 (**U7 修正版**)
+#   ⭐ 底本 = persist 轮 `stall_probe.py` (md5 2274c15975e78307dc9d9b286da03ffb = microwin 修好版)。
+#   ⭐ U7 (审查 FINDINGS §4 末行 + 设计件 §4.6-②): "注入器的 ack 字段必须取**注入时刻**的
+#      snd_una..snd_nxt"。原版把 (ack,win) **一次**嗅探后用于全部 n 次注入 —— 嗅探之后
+#      板若推进过 snd_una, 该 ack 会落在守卫之外 ⇒ win 注入被**静默吞掉** (正控失效)。
+#      本版: ① 每次注入前**现取**最新 ack: 新开一个 AF_PACKET 套接字收集 SNIFF_MS 毫秒
+#      (新套接字只看**绑定之后**到达的包 ⇒ 不读陈旧 backlog; 取 ack 最大者 = 最新; ack 单调);
+#      ② ACK_MODE 决定怎么用它:
+#           fresh       = 直接用          (要求**可接受** ⇒ 守卫放行; task-2 正控口径)
+#           fresh_minus = ack - ACK_OFFSET (mod 2^32) ⇒ 刻意**不可接受**(陈旧 ACK) ⇒ 判别臂
+#           fresh_plus  = ack + ACK_OFFSET             ⇒ 刻意**不可接受**(越界 ACK) ⇒ 备选
+#   其余 (seq = isn+1 / doff=5 / 校验和 / 帧构造 / PROBE_DATA / POST_INJECT) 与原版逐字相同。
+#   用法: PROBE_WIN=0 ACK_MODE=fresh bash stall_probe_u7.py [注入时刻=SYN后秒] [n] [gap秒]
 import os, socket, struct, sys, time
 
 WIN = int(os.environ.get("PROBE_WIN", "1460"))
+ACK_MODE = os.environ.get("ACK_MODE", "fresh")           # U7: fresh | fresh_minus | fresh_plus
+ACK_OFFSET = int(os.environ.get("ACK_OFFSET", "4194304")) # U7: 偏移量 (默认 4 MiB)
+SNIFF_MS = float(os.environ.get("SNIFF_MS", "20"))        # U7: 每次注入前现取的收集时长 (ms)
 WAIT = float(sys.argv[1]) if len(sys.argv) > 1 else 3.0
 N = int(sys.argv[2]) if len(sys.argv) > 2 else 3
 GAP = float(sys.argv[3]) if len(sys.argv) > 3 else 0.15
@@ -25,10 +36,56 @@
         s = (s & 0xFFFF) + (s >> 16)
     return (~s) & 0xFFFF
 
+def parse_pkt(pkt):
+    """⭐ U7 新增: 解析一个以太帧 → (src, sport, dport, seq, ack, flags, win) 或 None。
+       口径与 sniff_and_wait 内联解析逐字相同 (只抽出来给 drain_latest 复用)。"""
+    if len(pkt) < 14 + 20 + 20:
+        return None
+    if pkt[12:14] != b"\x08\x00":
+        return None
+    ip = pkt[14:]
+    ihl = (ip[0] & 0xF) * 4
+    if ip[9] != 6:
+        return None
+    src = socket.inet_ntoa(ip[12:16])
+    tcp = ip[ihl:]
+    sport, dport, seq, ack, off_flags = struct.unpack(">HHIIH", tcp[:14])
+    flags = off_flags & 0x1FF
+    win = struct.unpack(">H", tcp[14:16])[0]
+    return src, sport, dport, seq, ack, flags, win
+
+def drain_latest(lport, budget_ms):
+    """⭐ U7: 现取"注入时刻"的最新对端 ACK 的 (ack, win)。
+       新开套接字 (只看绑定后到达的包) + 收集 budget_ms 毫秒 + 取 ack 最大者 (ack 单调)。"""
+    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(0x0003))
+    try:
+        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
+    except OSError:
+        pass
+    s.bind((IFACE, 0)); s.settimeout(0.005)
+    best = None; t_end = time.time() + budget_ms / 1000.0
+    while time.time() < t_end:
+        try:
+            pkt = s.recv(2048)
+        except socket.timeout:
+            continue
+        except OSError:
+            break
+        f = parse_pkt(pkt)
+        if f is None:
+            continue
+        src, sport, dport, seq, ack, flags, win = f
+        if src == MY_IP and dport == PORT and sport == lport and (flags & 0x10):
+            if best is None or ((ack - best[0]) & 0xFFFFFFFF) < 0x80000000:
+                best = (ack, win)
+    s.close()
+    return best
+
 def sniff_and_wait(inject_at=4.0):
     """抓本连接: 对端 SYN 的 ISN + 最近的 (ack, win, 端口);
        并在 **SYN 之后 inject_at 秒** 停止嗅探 ⇒ 此刻正是 stall 中段 (sink 15 s 才超时)。
-       每包后检查"是否已到注入时刻" ⇒ 精确对齐连接起点, 不靠墙钟猜。"""
+       每包后检查"是否已到注入时刻" ⇒ 精确对齐连接起点, 不靠墙钟猜。
+       ⭐ U7: 套接字**保持打开** (drain_latest 之外的兜底), 返回值多一个 s。"""
     s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(0x0003))
     s.bind((IFACE, 0))
     s.settimeout(0.2)
@@ -60,8 +117,7 @@
                 print("SNIFF_SYN lport=%d isn=%d t=%.6f" % (sport, seq, t_syn), flush=True)
             elif (flags & 0x10) and isn is not None and sport == lport:
                 last = (ack, win)
-    s.close()
-    return isn, lport, last, t_syn
+    return isn, lport, last, t_syn, s
 
 def inject(lport, isn, ack, win, ident, data=b"", flags_extra=0):
     s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
@@ -81,17 +137,32 @@
     s.close()
 
 def main():
-    print("PROBE_START win=%d inject_at=%.1fs n=%d gap=%.2f t=%.6f" % (WIN, WAIT, N, GAP, time.time()), flush=True)
-    isn, lport, last, t_syn = sniff_and_wait(WAIT)
+    print("PROBE_START win=%d inject_at=%.1fs n=%d gap=%.2f ack_mode=%s ack_offset=%d sniff_ms=%.1f t=%.6f" % (
+        WIN, WAIT, N, GAP, ACK_MODE, ACK_OFFSET, SNIFF_MS, time.time()), flush=True)
+    isn, lport, last, t_syn, sock = sniff_and_wait(WAIT)
     if isn is None or last is None or lport is None:
         print("PROBE_FAIL 未抓到握手/ACK (isn=%s lport=%s last=%s)" % (isn, lport, last), flush=True)
         return 2
     print("PROBE_TARGET lport=%d isn=%d last_ack=%d last_win=%d (SYN+%.2fs)" % (
         lport, isn, last[0], last[1], time.time() - t_syn), flush=True)
+    ack_use = last[0]
     for i in range(N):
-        inject(lport, isn, last[0], WIN, 0x4000 + i)
-        print("PROBE_INJECT i=%d ack=%d win=%d t=%.6f (SYN+%.2fs)" % (
-            i, last[0], WIN, time.time(), time.time() - t_syn), flush=True)
+        fresh = drain_latest(lport, SNIFF_MS)               # ⭐ U7: 注入时刻现取
+        src_tag = "held"
+        if fresh is not None:
+            last = fresh; src_tag = "fresh"
+        if ACK_MODE == "fresh":
+            ack_use = last[0]
+        elif ACK_MODE == "fresh_minus":
+            ack_use = (last[0] - ACK_OFFSET) & 0xFFFFFFFF
+        elif ACK_MODE == "fresh_plus":
+            ack_use = (last[0] + ACK_OFFSET) & 0xFFFFFFFF
+        else:
+            print("PROBE_FAIL 未知 ACK_MODE=%s" % ACK_MODE, flush=True)
+            return 3
+        inject(lport, isn, ack_use, WIN, 0x4000 + i)
+        print("PROBE_INJECT i=%d ack=%d win=%d ack_src=%s fresh_ack=%d fresh_win=%d t=%.6f (SYN+%.2fs)" % (
+            i, ack_use, WIN, src_tag, last[0], last[1], time.time(), time.time() - t_syn), flush=True)
         time.sleep(GAP)
     if os.environ.get("PROBE_DATA") == "1":
         # 活性探针: 3 个 1 字节 in-window 数据段 (seq = 对端 ISN+1 = 板的 rcv_nxt)
@@ -125,6 +196,7 @@
             print("POST_INJECT_BOARD_FRAME t=%.6f seq=%d len=%d flags=%02x" % (
                 time.time() - t_syn, seq, plen, flags), flush=True)
     print("PROBE_DONE board_frames_after_inject=%d t=%.6f" % (seen, time.time() - t_syn), flush=True)
+    sock.close()
     return 0
 
 if __name__ == "__main__":
```

---

## 8. 收尾状态（板子回干净态）+ 文件清单

| 项 | 读数（`runs/FINAL_STATE_0x1E.txt`，2026-10-11 08:46 现取） |
|---|---|
| 板上现役 | **`0x1E`（含守卫）** —— `0x04 = 0x0000001e`；`ID_OK`（`EXPECT_BID=0x0000001E NW=70` 显式覆盖） |
| `0x00 / 0x138` | `0x50360001` / `0xffffffff`（70 字判据） |
| `0x08 SCRATCH` / `carrier` | `0x00000000`（**未停流**）/ `1` |
| `LnkSta` / BARs | `5GT/s x4` / `2 BARs`；`/dev/xdma0_user` 在 |
| 对端残留进程 | 无（sink / tcpdump / stall_probe / persist_client 全部退出；每跑跑末逐跑核） |
| 本轮**只**烧两个归档副本 | `p7b_build_0x1E/wrapper_p4.bit`（×3）与 `p7b_build_0x1D/wrapper_p4.bit`（×1）；**未写 QSPI**、未碰 `vivado_prj/**` |

**目录清单**：`STEP0_selfcheck.txt` · `burn_arm.sh` · `step0_selfcheck.sh` · `burn/`（位流副本、逐次烧录 stdout 与五判据、两臂身份读数）·
`_tools/`（`stall_probe_u7.py` + `.diff`、`stall_probe_orig_ref.py`、`sndwnd_run.sh`、`persist_client.py`、五个分析件）·
`runs/`（9 跑 × {主日志、capA/capB/capC/capD/capE、probe/snap/ss/sink/client/nstat}；`DELTA_WINDOWS.txt`、逐跑 `*_analyze.txt`、`R1_PA_0x1E_probe_verify.txt`、`FINAL_STATE_0x1E.txt`）。

⛔ **本报告不下 PASS/FAIL 裁定**；上面所有"成立/不成立"都只描述**读数与口径的对应关系**，裁定权在判据所有者。
