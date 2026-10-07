# P7B_RETXFIX —— dup-ACK 自持重放环修复 (Stage C 下行退化) · 实施轮
- 2026-10-07 · 仓库 `udp_hls_10g_fix` · 起点 **HEAD `b30b499`** (工作区干净; 位流已从原树回收, 见 §2 附注)
- 入口 = `P7B_LOOP_HANDOFF.md`; 用户指令 = "开始调查核修复" ⇒ 走**路径 B (修重放策略)** 且同时取 C-② 的 RTL 级证据
- 本件只写实施与设计; 板级读数另立 (待跑)

## 0. 一句话
把一次重放会话从"整段 `[snd_una, retx_hi]` (~29 帧)"改成 **"≤ RETX_SPAN=3 帧 + 收尾跳写
`snd_nxt := retx_hi`"**, 并给 dup-ACK 触发加**重武装纪律** (授权拍不再复位计数, 解锁只由
推进 ACK) ⇒ 结构性消灭"重放自身造 dup-ACK ⇒ 再点火"的自持环。K=3 不是拍的: 见 §1.3。

## 1. RTL 设计 (三层) + 两处裁定

### 1.1 预算限幅 + 收尾跳写 (只改 `ifdef TCP_TX_OVL` 支 → `rtl/tcp_tx_frame.v`)
- `parameter [3:0] RETX_SPAN = 4'd3` (共享参数区, 默认支不使用)。
- 新寄存器 `replay_left` (OVL :357): svc 拍装载 (`:746`), 每 `ring_start` 递减 (`:775`)。
- `ring_start` 加预算门 `&& (replay_left != 4'd0)` (OVL :507-508)。
- 新组合 `replay_jump = ring_eval && (ring_delta != 0) && !retx_ovf && scan_estab &&
  (replay_left == 0)` (OVL :511-512): 预算耗尽 ⇒ 不起新 ring 帧, 改发**收尾跳写**。
- 跳写接入**既有三写源 mux** (不新开第 4 源, `$onehot0` 不变式保持; 互斥性论证见 OVL :450-454):
  `upd_wr_rew = svc_rewind || replay_jump`, `upd_id`/`upd_val` 各加一路 `replay_jump ? …` (OVL :449-466)。
- **跳写的必要性 (硬约束)**: `tcp_rx` 会话期 ACK 接受上界 = `retx_hi` (`rtl/tcp_rx.v:294`,
  P4d 死锁防线)。若会话因预算提前结束而 `snd_nxt < retx_hi`, `retx_active` 落下后上界回落
  到 `snd_nxt` ⇒ 对端"跳到缓冲前沿"的合法 ACK 被拒 = P4d 死锁面复现。跳写把簿记恢复到
  "剩余帧早已上过线"的真实状态。
- 复位: `replay_left <= 0` (OVL :668)。

### 1.2 重武装纪律 (`rtl/tcp_rx.v`) —— ⛔ **r2 已整刀回退** (板级实测证伪, 见 §3.5)
- (r1) 曾改: 授权拍**只清挂起请求**; `in_retx/dup_cnt` 解锁**只由真实推进 ACK**。
- ⛔ **r2 回退理由 (板级 A/B r1 实测, §3.5)**: 该纪律把会话期→progress 之间的对端 dup-ACK
  **全部屏蔽**, 而对端的 dup 批次在 progress 到达前**已经发完** ⇒ 残余计数 < 阈值 3 ⇒
  真孔打不出快重传 ⇒ **每孔一次 100 ms RTO 停摆** (pcap 逐帧实证: 一个孔走 65 µs 快重传,
  下一个孔沉默 100.0 ms 才由 RTO 会话发出)。
- **回退后为何仍不环**: 预算 K=3 自身已足够 —— 重放自身产生的重复段立即 ACK 至多 K-1=2 <
  阈值 3 ⇒ **结构上不能自我再点火** (旧 Stage C 环是 ~28 个 ≫ 3, 每会话自喂下一会话)。
  纪律是多余层, 代价 = 吞掉真信号。
- ⚠️ 回退后 `tcp_rx.v` 与本轮起点逐字节相同 ⇒ 默认构建与 HEAD **字节等价** (见 §3.3/§3.6)。

### 1.3 K 的推导 —— ⛔ **两次订正, 现役 K=2** (每次订正都有板级实测见证)
- (r1 原推导, **已被证伪**): "重放自身重复段立即 ACK ≤ K−1" —— **漏了"伪 dup-ACK 触发 (无真孔)"
  这一支**: 那时重放的**全部 K 帧都是重复段** ⇒ 自身产生 **K 个**立即 ACK。
- **构造性模型 (r3 定版)**: 设链路存量 A 个 dup-ACK, 一次会话消耗 3 (阈值)、产生 K (自身重放
  的重复段): **A' = A + K − 3**。⇒ **K=3 恰好临界 (A 不衰减 ⇒ 无限链)**; K=2 ⇒ A' = A−1
  (**衰减 ⇒ 终止**); K=1 ⇒ 更快衰减。真孔支: 进 1 个 prog + K−1 个自我 dup ⇒ K≤2 均净衰减。
- **实测对照 (同几何 30 连)**: K=3+纪律 (r1/BID 0xB) = 120 会话/跑 (链被纪律压住, 但纪律
  另招 RTO 停摆, §3.5); **K=3 无纪律 (r2/BID 0xC) = 2,455 会话 / 205 per conn / 1.85× /
  agg 3.0 Mbps / 载荷失配 1.77 MB (板级崩坏)** —— 临界性的实测坐实。
- ⇒ **现役 `RETX_SPAN = 4'd2`** (r3/BID 0xD)。
- ⛔ **r3 板级翻车 (且把模型再修一次)**: r3 实测 `1,212 会话/1.11×/失配 60 KB/风暴`; 且**复跑复现**
  (RXI: 20.2 s/12.4 Mbps/11 坏连接) ⇒ 不是环境抖动。对端计数反驳"对端丢帧"假说
  (`port_rx_nodesc_drops` 全程不变、`TcpInExtSegs` 全收、`TCPRcvCollapsed=0`、OFO 事件
  r1 915 vs r3 2,131 量级相近) ⇒ 慢与失配**都在板侧**。
- ⭐ **判决性正交实验 (分辨 RTL 因 vs 对端态因)**: **重烧归档的 r1 位流** (BID 0xB)、
  **在同一对端态下复跑** ⇒ **`clean_conns=30 / bad=0 / mismatch=0`**、dur 仍"快类+100 ms 量子"。
  ⇒ **失配 ⟸ 背靠背会话链 ⟸ 无纪律** (r1 的 120 会话/0 失配三轮可复现; 失配率与会话数
  超线性); **r3 的慢 = 截断爬行** (每轮会话仅推进前沿 1-2 帧, 而 dup 供给 = 对端 OFO 事件,
  供给一断就掉到 RTO)。
- **r4 定版设计 (两路分流)**: **dup-ACK 触发的会话 = K=3 截断 + 纪律** (防链/防失配 — 纪律
  省不得); **RTO 触发的会话 = 全窗重放** (`replay_full` 逃逸, 不受预算 — 计时器驱动不能
  自持; 一次 RTO 修好任意孔) ⇒ 纪律的代价 (该孔等 RTO) 从 200 ms 压到 ≤100 ms 一次。

### 1.4 裁定 A: **默认分支拷贝保持 HEAD 语义 (不动)**
理由 (四条):
1. 它的验证载体 = `tb_p4_chain.v` 的 PC 模型是**无重排缓冲**的 (`:1488-1500`, OOO 一律回 dup、
   不缓存) —— 截断重放在该模型下表现为多会话"跑步机", **是模型伪影不是产品缺陷**
   (真实对端 (Linux) 必带 OFO 队列, 乱序数据会被合并)。为修产品缺陷而改 12 门的历史模型/
   期望 = 污染既有证据 (且正是"FAIL 全被解释成判据问题"的禁例)。
2. 1G 路径真实对端有缓冲 ⇒ 该处无自持环; 浪费有界 (Stage 2 已量: `dupseq` 5.65/conn)。
3. 文件自身契约: "默认构建 (宏未定义) 走 else 分支, **逐字 = HEAD (0 deletions)**"。
4. 现役活体 = OVL 支 (`board/build_p7b_ku5p.tcl:153` 打开 `TCP_TX_OVL=1`)。
⇒ **遗留登记**: "历史上一直存在的每连接重复段" (分支 ②) 在默认支**未修**; 待后续用
"带缓冲对端模型"的门收口后再同步 (见 §4)。

### 1.5 裁定 B: `tcp_rx` 纪律是**共享改动** (默认/OVL 两支都吃)
影响面 = 全 16 门矩阵 ⇒ 已用矩阵复跑验证 (见 §3.3)。含义: 重放触发在默认支也变得"每进展点
至多一次", 对既有门的 RETX 计数断言预期无影响 (会话数由触发数决定, 不由重武装时机决定;
spurious 请求不会 `stat_retx++` —— 它走 `svc_rewind=0` 的 1 拍气泡)。

### 1.6 RTL 改动清单 (逐处)
| 文件 | 位置 | 改动 |
|---|---|---|
| `rtl/tcp_tx_frame.v` | :205 附近 (共享参数) | `RETX_SPAN = 4'd3` |
| " | OVL :357 | `reg [3:0] replay_left` |
| " | OVL :449-466 | 写源 mux 加 `replay_jump` 一路 |
| " | OVL :507-512 | `ring_start` 预算门 + `replay_jump` 定义 |
| " | OVL :668 | 复位 `replay_left <= 0` |
| " | OVL :746 | svc 拍装载 |
| " | OVL :775 | `ring_start` 递减 |
| `rtl/tcp_rx.v` | :530-547 | 授权拍不再复位 `in_retx/dup_cnt` |
| `board/wrapper_p4.v` | :3882 | `BUILD_ID_V` 0xA → **0xB** (+ 注释历史) |

## 2. 工具与门修复 (本轮 5 件, 全部有负对照)

### 2.0 本树缺失构建产物两处 (拷贝所致, 已逐件回收 + 校验)
- **位流**: `p7b_build_stageC/stageC_wrapper_p4.bit` (Build 3, `1609d6f5…576f3c`) 与
  `baseline_archive/wrapper_p4_Build2.bit` (Build 2, `1ccbd9cd…6cdd07`) 都不在本树
  (gitignore `*.bit` + 拷贝未带; 全仓 0 个 .bit) ⇒ 从原树 `udp_hls_10g` 回收, **sha256 就地
  校验逐字相符**。⇒ 交接件 §4-A 的"零构建回退"在本树重新成立 (以本树为准)。
- **HLS 综合产物** `hls/slowstack_prj/` (176 件 / 3.5MB) 缺 ⇒ P4 矩阵启动即
  `[P4GUARD FAIL] ... missing: hls\slowstack_prj\solution1\syn\verilog\` 硬拒
  (守卫工作正常, 这就是它该干的事) ⇒ 从原树回收后矩阵方可运行。

### 2.1 `sim/p7b_stagec_tx/mk_mut_tx.py` 换行鲁棒 (必需, 否则门开不了)
本树 `rtl/tcp_tx_frame.v` 是 **CRLF** (原树是 LF; `core.autocrlf=true` + 拷贝所致), 而脚本用
`newline=""` 原样读 → 8 条多行模式全 MISS → `MUTGEN FAIL 8` → 门在 `MUTGEN-FAIL` 处中止。
修: 读侧改通用换行 (`newline=None`)。⚠️ 期间还发现 `mk_mut_tx.py` 的一个**静默面**:
模式 MISS 时它仍照写 (未变异/半变异的) 文件 ⇒ 若无人看 exit code, mut/ 里会留下**没变异的
"变异体"** (判据会静默失去牙)。本次因 `|| MUTGEN-FAIL` 硬失败而暴露。

### 2.2 既有变异锚点随 OVL 文本更新
`mut_c2` (upd_id/upd_val 两条) 与 `mut_f1` (拆成 OVL/默认两条, 各 hits=1) 因 §1.6 的文本
改动而失配 —— 逐条更新, 命中数仍逐条断言 =1。

### 2.3 新变异体 (P7B-RETXFIX 负对照, 每条 = 1 处语义回退)
- **M-K1**: 撤预算门 + 撤跳写 (`ring_start` 去 `replay_left` 门; `upd_wr_rew` 去 `replay_jump`)
  ⇒ 整条特性回退到"整窗重放"。
- **M-K2**: 只撤跳写 (`upd_wr_rew` 去 `replay_jump`) ⇒ 预算仍在, 会话提前结束但 `snd_nxt` 不到位。

### 2.4 TB 新判据 (`tb/tb_tcp_tx_ovl.v`, 全在 `ifdef TCP_TX_OVL` 区 :882-1125 内)
- **判据 A (预算)**: 会话结束沿上, 本会话重放帧数 (迟到帧计数差分 `cov_replay_frames-rep_f0`)
  ≤ `RETX_SPAN+1` (K 帧 + 1 拍捕获滑移) ⇒ 红 `e_replay_span`; 另记 `rep_smax` (信息)。
- **判据 B (跳写)**: 会话结束沿上 `u_tcb.snd_nxt_r[retx_conn]` 不得低于 `retx_hi`
  (回绕安全比较) ⇒ 红 `e_replay_jump`。
- **判据 C (M-C2 确定性化)**: 契约 = FIX-2' "帧首拍同拍预留 +1" —— 消耗 seq 的 SYN/FIN/RST 在
  `start_ack` 拍必须同拍出现 (wr,val,id) 三件套 ⇒ 红 `e_c2_resv`。
- **覆盖见证** `cov_jump_ev` (replay_jump 拍数) ⇒ 判"判据是否被走到" (防空判据)。
- 三条判据全部计入 `tot_red`; 新汇总行 `OVL RETXFIX span_max/span_over/jump_bad/c2resv_n/c2resv_bad/jump_ev`。
- bat 新臂 **U (M-K1) / V (M-K2)**, 期望非零; 汇总/FAILS/verdict-findstr 同步。

### 2.5 arm I 掩蔽事件与 C2 确定性化 (本轮抓到的一个**判据病**)
- 现象: 全门 19 臂里**唯一红 = arm I (M-C2 变异存活)**。逐字对比两树 runI (同一 TB、同一负载
  2100 帧/≈355k 拍): 原树 `FAIL reds=2` (`seqmono=1 seqcont=1`, 命中于一次 SYN+数据帧的
  相位巧合); 本树 `OK`。机制: M-C2 的签名要求**数据帧恰落在 +1 预留写被延迟的 8 拍窗内** ——
  **巧合驱动** (原树 7 次 SYN 事件只命中 1 次)。我的改动只**平移了会话相位**, 并未修掉该 hazard
  ⇒ 判据的牙被巧合偷走。
- 修法: 按**契约**判 (判据 C 上述), 与交错相位无关 ⇒ M-C2 首拍即红 (实测 5 次命中, `wr=0`
  逐条打印)。旧见证 (seqmono/seqcont) 保留不删。
- 教训归属: "判据的判别力会随被测件的**相位**静默消失" —— 归入全局经验族 (门面)。

## 3. 门证据 (本轮读数)

### 3.1 快速两臂 (定界 + 牙齿预检, 各 ~2.5 min)
| 臂 | 配置 | span_max | span_over | jump_bad | jump_ev | c2resv_n/bad | 判决 |
|---|---|---:|---:|---:|---:|---|---|
| qB | 现役修复 OVL | **2** | 0 | 0 | **7** | 16 / 0 | `TB_TCP_TX_OVL: OK` |
| qU1 | mut_k1 (撤预算+跳写) | **6** | **6** | 0 | — | 15 / 0 | `FAIL reds=6` ✓ 有牙 |
| qU2 | mut_k2 (只撤跳写) | 2 | 0 | **11** (≡jump_ev 11) | 11 | 17 / 0 | `FAIL reds=685` ✓ 有牙 |

判读: ①预算判据: 修复 max=2 vs 撤销 max=6, 界 4 —— 两侧各留 2 帧余量; ②跳写判据: 修复 7 次
跳写全守 (0 违约), 撤销后 11 次跳写事件 11 次违约 (**每事件必违约, 一一对应**); ③C2 判据:
修复 16 次控制预留全同拍 (0 违约)。⇒ **两条新判据都有确定性牙齿, 无需额外风暴激励臂**。

### 3.2 完整 OVL 门 (19 臂) = **`TX_OVL_GATE: PASS`** (2026-10-07; 原件 `p7b_retxfix/gate_ovl_fixed.log`)
- 契约全中: A=0 / B=0 / **P=0 (NOFLOOD)** / R=0 / S=0 (integ OK); C..L 全非零
  (**I 由判据 C 命中**, 见 §2.5) + Q=0 (FLOOD 牙齿在) + T=1 + **U=1 (M-K1) / V=1 (M-K2)**。
- B 臂关键读数: `COV replay_sessions=24 replay_frames=39` (**vs 原树 StageC 轮 23/67 ⇒
  重放帧 −42%、会话数持平**); `OVL RETXFIX span_max=2 span_over=0 jump_bad=0
  c2resv_n=16 c2resv_bad=0 jump_ev=7`; F1/C6/wsrc 与 Stage C 同量级
  (`overtop_cyc=1053 wrap_ev=63`; `C6 wins=15 gated=1717 grant_in_win=0`)。
- U 臂红行与快速轮逐字一致 (span 5-6 > 4, 6 处); V 臂 `FAIL reds=685` (`jump_bad=11`)。
- ⚠️ **判门纪律 (本轮亲历)**: `cmd //c ... | tee` 的管道退出码 = **tee 的** (门 FAIL 时 RC 仍 0)
  ⇒ 判门一律读末行 `TX_OVL_GATE: PASS|FAIL count=n` (global #53「哑门」同族: 判决要走到证据行)。

### 3.3 P4 矩阵 (16 门) + p5close
- **p5close (G1/G9): `ALL PASS`** (2026-10-07) —— FIN/RTO/回卷环语义未受本修复影响
  (G9 场景 = `blocked + FIN 在飞` ⇒ 无回卷支, 与预算/跳写正交; 逐字: "no ring_delta
  underflow replay after FIN"; G1 "FIN retransmitted 17 frames")。
- **P4 矩阵 16 门: `16/16 · gates failed: 0 · VERDICT: FROZEN`** (2026-10-07 19:20;
  canonical = `sim/p4sim/matrix_p4dfix.log`; 237 文件逐字冻结 = 本轮读数绑定本修订) ⇒
  **共享的 `tcp_rx` 改动对默认支无涟漪** (burst 族 RETX 计数 / stallgate / dupstorm / chain
  全 `EXIT=0`)。
  ⚠️ 矩阵首次启动被 `[P4GUARD FAIL]` 硬拒 (缺 `hls/slowstack_prj/` —— 本树拷贝失真,
  见 §2.0); 原树回收后重跑通过。

### 3.4 构建 r1 (Build 4, `BUILD_ID_V=0xB`) —— 完成 (为 r2 存档)
- `P7B_WNS = 0.124 / WHS = 0.010 / 三类失败端点 0/0/0` (`board/p7b_ku5p_timing.rpt`;
  vs Build 3 `+0.070` **更好 0.054**); DP 最差锥 = `u_tcp_tx/recv_first_reg → ctrl_tcpcsum_reg[12]`
  (logic 2.195ns, **不是** `retx_active` —— 本轮新逻辑**未进最差族**)。
- 位流 `0a46645f5e9f32da46f545d08eb5b10b66bdc54266d4cf73162d6370cbba069e`
  (15,431,261 B; 归档 `p7b_retxfix/retxfix_wrapper_p4.bit`)。首建无前序位流 ⇒ 归档块 `ARCHIVE_SKIP` ✓。
- 板侧身份: `0x50360001 / BID=0x0000000b / 0x11C=0xffffffff` ⇒ **ID_OK** (LnkSta x4)。

### 3.5 板级 A/B **r1 实测 (Build 4 = BID 0xB)** —— 环已死 + 抓到 r1 自己的回归
**臂**: `CONNS=30 SECS=25 PCAP_ON=0/1` (≈Stage C DL3 同几何), 跑 3 次 (RXF/RXF2/RXF3-pcap),
**逐位可复现** (RXF2 与 RXF1 的三项 Δ 完全相同: ΔW51=31,457,280 / ΔW55=**120** / ΔW15=31,984,928)。
| 量 | **Build 4 (修复)** | Build 3 (缺陷, Stage C 原件) | Build 2 (R1, 原件) |
|---|---|---|---|
| sink 聚合 | **73.8–103.5 Mbps** (wall 2.4–3.4 s) | 224.1 | 889.4 |
| **ΔW55 会话数** | **120** (4/连接) | 6,970–11,449 | 49–56 |
| **ΔW15/ΔW51 线上重复率** | **1.0168** ✓ | 13.8–19.3 | 1.01 |
| 帧/会话 | **3.000** (预算守约) | 27.6–34.5 | ~1 |
| `W54` 载荷失配 | **0** ✓ | 0 | 0 |
| 每连接形态 (pcap) | **双峰**: ~2 ms (uniq_Mbps 3900–5800!) vs **102/202/302 ms** | 均匀 20–36 ms | 均匀 9.3 ms |

- ⭐ **环被结构性杀死**: 重复率 13.8–19.3× → **1.0168×**; 会话数 ↓60–95×; 每会话恰 3 帧;
  快类连接比 Build 2 还快 3× (2 ms vs 9.3 ms/连接)。**修复方向正确。**
- ⛔ **但抓到一个 r1 自伤 (详见 §1.2)**: 102/202/302 ms = **0–3 × 100 ms (RTO_LIM 精确量子)**;
  pcap 逐帧坐实 = 会话期屏蔽对端 dup-ACK ⇒ 真孔无快重传 ⇒ RTO。**修法 = 回退 `tcp_rx.v`**
  (预算 K≤3 已足够破环)。另记: 对端纯 ACK 333/333 全 54 B (**无 SACK** —— SACK 假说排除);
  连接收尾见**对端 FIN 指数退避重传** (204→408→832→1664 ms, 板未 ACK 对端 FIN) ——
  与缺陷臂对照后判是否既存 (见 §3.6)。

### 3.6 **r2** (回退 `tcp_rx` 后)
- **矩阵 r2: `16/16 · 0 failed · VERDICT: FROZEN`** (2026-10-07 20:17; 绑定 r2 摘要
  `DIGEST_ALL(content)=89e07c00…`)。⚠️ r2 的矩阵在语义上≈HEAD 基线 (tcp_rx 已回退 +
  tcp_tx_frame 默认分支未动 → 默认构建字节等价), 复跑是为**修订绑定取证**。
- 构建 r2 (BID 0xC): `WNS +0.065 / WHS +0.010 / 0/0/0`; 位流 `48e9a729…bc4b7` (归档
  `retxfix_r2_wrapper_p4.bit`); 板侧 `ID_OK` (BID 0xC) ✓。
- ⛔ **板级 r2 = 崩坏 (本轮的第二次板级实测, 把 K=3 的临界性钉死)**: `CONNS=30 SECS=25
  PCAP_ON=1` (TAG=RXG) ⇒ `conns=12/30 · bad_conns=5 · mismatch_bytes=1,766,656 ·
  wall 33.5 s · agg 3.0 Mbps`; 板侧 `ΔW55 = 2,455 会话 (205/连接)`、
  **重复率 ΔW15/ΔW51 = 1.853×**。逐连接: 2/5 连正常快 (~2-3 ms, 3.0-3.8 Gbps), 2 连
  ~16.5 s 停摆 + ~880 KB 失配。⇒ **撤纪律后 K=3 的自持链重现且更凶** (§1.3 的 A'=A+K−3
  临界性与实测完全吻合)。失配/16 s 停摆**归因 = 链生** (r1 同 OVL 码 120 会话时失配恒 0;
  ⚠️ 16 s 停摆的更深归因未逐项做实, 登记为"链生、未细拆")。
- ⇒ **r3 = `RETX_SPAN` 3→2** (BID 0xD), 其余一字未动。
- **OVL 门 r3: `TX_OVL_GATE: PASS`** (2026-10-07; 原件 `p7b_retxfix/gate_ovl_r3.log`) ——
  ⚠️ r4 已改 rtl/tcp_tx_frame.v + rtl/tcp_rx.v ⇒ **r3 门读数按"r3 修订"读**; r4 门见 §3.7。
  19 臂契约全中 (A/B/P/R/S=0; C..L/Q/T/U/V 全非零, I 仍由判据 C 命中); B 臂读数
  `span_max=2 span_over=0 jump_bad=0 c2resv_n=15 c2resv_bad=0 jump_ev=13`
  (K=2 下 jump 事件 7→13 ✓ 更多会话撞预算; span 界 K+1=3 无假阳性 ✓)。
  ⚠️ **r3 不重跑 P4 矩阵** (裁定并登记): r2→r3 的唯一 delta = OVL 区内一个常数
  (`RETX_SPAN`) + 共享参数区的取值; **默认构建的编译设计字节等价** (该参数在默认支
  未被使用、整个 OVL 区被 `ifdef` 掉) ⇒ r2 的矩阵绑定继续有效; OVL 面由本门 + 板级覆盖。

## 4. 边界与未决 (不许当已答)
1. **默认分支未修** (§1.4): 1G 路径的"每连接重复段"遗留; 收口需"带缓冲对端模型"的门。
2. **tcp_rx 纪律的边界**: 会话未修复空洞时该连接锁定计 dup-ACK, 直到推进 ACK 或 RTO
   (标准 TCP 行为; 但 = 比旧行为多一次 RTO 的延迟代价 —— 已登记, 板级 A/B 观察)。
3. "洞的最后一米" (对端栈内部丢/滞后) **仍未定位** —— 与交接待办一致, 本修复不依赖它。
4. **9.456 Gbps 可达性**: 仍未证 (修复后应重测; 板级 A/B 见 §3.5)。
5. 交接件 §5-2 "拆刀" (A2 vs 乒乓) 未做 —— 与本修复正交。
6. `RETX_SPAN+1` 判据界 = 4 的滑移余量依据: 实测 (qB max=2 / mut max=6) —— 若未来 TB 相位
   变化使修复版触界, 应先查滑移归属再动界 (**不许**先放宽)。
7. 门的注册: `sim/p7b_stagec_tx/` 族**不在** 16 门矩阵内 (Stage C 起如此) ⇒ 后续可考虑注册
   (需同步 runner 的 16 计数与 manifest; 本轮未做, 登记为跟进项)。

## 5. 复现命令 (从仓根)
```bash
# 门 (完整 19 臂; 判门看末行 TX_OVL_GATE: PASS|FAIL, ⚠️ 不要经管道读退出码)
cmd //c 'sim\p7b_stagec_tx\run_tx_ovl_gate.bat'
# 快速两臂 (本轮的定界/牙齿预检件)
cmd //c '_proj_10g\notes\p7b_retxfix\run_quick2.bat'
# P4 矩阵 / p5close
cmd //c 'sim\p4gates\run_matrix_p4dfix.bat'
cmd //c 'sim\p5close\run_tb_tcp_close.bat'
# 构建 (先改 board/wrapper_p4.v:3882 的 BUILD_ID_V) / 烧录
cmd //c 'board\run_build_p7b_ku5p.bat'
# ⚠️ 对端 --put 的远端路径要用 //tmp/... (MSYS 会把 /tmp 改写成 Windows 路径)
```

### 3.7 **r4 (定版)** —— dup 路径 K=3+纪律 / RTO 路径全窗
- **OVL 门 r4: `TX_OVL_GATE: PASS`** (原件 `p7b_retxfix/gate_ovl_r4.log`; 19 臂契约全中;
  跨度判据对 RTO 全会话 (`replay_full`) 豁免 —— 语义上它就是全窗, 不该受 K 界)。
- 构建 r4 (BID 0xE): `WNS +0.020 / WHS +0.010 / 0/0/0` (⚠️ **WNS 仅 +0.020 = 周期 0.31%**,
  本流程重排幅度 ±0.4-1.3 ns ⇒ 同输入重跑可能变负, 登记); 位流
  `dfd9ec27…2511f` (归档 `retxfix_r4_wrapper_p4.bit`); 板侧 `ID_OK` (BID 0xE)。

### 3.8 ⭐ **板级正式 A/B (同会话 · 同台架 · 同几何, 2026-10-07) = 本轮收口读数**
| 量 | **r4 (修复)** `RXK` | **Build 3 (缺陷)** `RXL` | 变化 |
|---|---|---|---|
| **线上重复率 ΔW15/ΔW51** | **1.0342** | **18.61** | **↓18×** |
| **ΔW55 会话数 (板侧)** | **127** | **11,187** | **↓88×** |
| sink 聚合 / wall | 189.2 Mbps / 1.331 s | 180.8 Mbps / 1.393 s | ×1.047 |
| 逐连接 dur p50 / max | **4.3 / 103.3 ms** | 20.7 / 157.1 ms | p50 ×0.21 |
| `W54` 板侧失配 / sink 失配 | 0 / 0 (30 连全干净) | 0 / 0 (30 连全干净) | — |
- ⭐ **判读**: **环被结构性杀死** (自持重放 18.61× → 1.0342×; 会话 ↓88×; 停摆从 r1 的
  200 ms 级压到 ≤100 ms 一次, p50 回到 4.3 ms = 比 Build 2 的 9.3 ms 快 2.2×);
  **数据完整性双向保持** (三口径: sink 逐字节 / `W54` / 缺口扫描 0 gap 0 partial)。
- ⚠️ **残留 (如实登记, 下一轮目标)**: ① 聚合速率 189 Mbps **只比缺陷臂高 4.7%** ——
  本微基准 (每连 1 MiB + sink 串行 + 每连建连) 的 wall 被**残停摆**与**建连开销**主导,
  不是持续流速率; 线上效率 (1.03 vs 18.6×) 才是产品级杠杆。② **残停摆的根 = 纪律吞掉
  对端 dup 批 ⇒ 该孔只能等 RTO** (r4 已把代价从 200→≤100 ms 一次); 根治方向 = dup 供给
  (SACK 解析 / 中继重试策略) —— 见 §4。③ **WNS +0.020 偏薄** (见上)。
- 板子终态 (本轮交付): **r4 / BID 0xE 已烧 + 受控停流** (`0x08 = 0x2` ⇒ carrier = 0);
  恢复 = `reg_rw /dev/xdma0_user 0x08 w 0x0`。

### 5.1 板级命令 (逐字可复跑; PEER_PW 只在环境变量里, 不落盘)
```bash
PY=/c/Users/zhxue/anaconda3/python.exe; T=/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools
# 烧 (位流路径经 TCPREG_BIT; 判据 = 'End of startup status: HIGH')
TCPREG_BIT='D:\repo\XCKU5PMini\udp_hls_10g_fix\_proj_10g\notes\p7b_retxfix\retxfix_r3_wrapper_p4.bit' \
  cmd //c 'D:\repo\XCKU5PMini\udp_hls_10g_fix\_proj_10g\notes\p7b_biz_tcpreg\run_program_tcpreg.bat'
# PCIe 恢复 (设备级三步) + 身份 + 恢复发流 (一条 --sudo 串)
PEER_PW=… $PY tools/peer_ssh.py --sudo "echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove; sleep 2; \
  echo 1 > /sys/bus/pci/rescan; sleep 3; $T/reg_rw /dev/xdma0_user 0x00 w | tail -1; \
  $T/reg_rw /dev/xdma0_user 0x04 w | tail -1; $T/reg_rw /dev/xdma0_user 0x08 w 0x0 >/dev/null; \
  cd /tmp/p7b_biz && EXPECT_BID=0x0000000D bash p7b_snap.sh id"
# 下行臂 (30 连 / 25 s / 带 pcap; BID_EXPECT 按当前位流)
PEER_PW=… $PY tools/peer_ssh.py --timeout 280 --sudo \
  'cd /tmp/p7b_biz && CONNS=30 SECS=25 TAG=RXH PCAP_ON=1 BID_EXPECT=0x0000000D bash stc_dl.sh' > run_RXH.log 2>&1
$PY tools/peer_ssh.py --get //tmp/RXH.pcap _proj_10g/notes/p7b_retxfix/RXH.pcap
python _proj_10g/notes/p7b_board_stagec/an_dl.py <tsv> --conn <port> --events   # TSV: tshark -T fields (flags.str!)
```

### 5.2 本轮位流/BID 台账
| Build | 位流 sha256 (前 8/后 6) | BID | 状态 |
|---|---|---|---|
| Build 2 (R1) | `1ccbd9cd…6cdd07` | 9 | 归档 (历史基线; 本树从原树回收并校验) |
| Build 3 (Stage C 缺陷) | `1609d6f5…576f3c` | 0xA | 归档 (A/B 缺陷臂) |
| Build 4 / r1 | `0a46645f…069e` | 0xB | 板级已测 (RTO 停摆, §3.5) |
| r2 | `48e9a729…bc4b7` | 0xC | 板级已测 (K=3 链崩坏, §3.6) |
| **r3 (现役)** | `4e114594…3f32` | 0xD | 板级已测 (K=2 爬行+失配, §3.6) |
| **r4 (现役, 定版)** | (构建 `/r4`) | **0xE** | 板级待测 |
