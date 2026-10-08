# P7B_RETXFIX —— dup-ACK 自持重放环修复 (Stage C 下行退化) · 实施轮
- 2026-10-07 · 仓库 `udp_hls_10g_fix` · 起点 **HEAD `b30b499`** (工作区干净; 位流已从原树回收, 见 §2 附注)　⛔ **2026-10-09 订正（不静默改）：`udp_hls_10g_fix` 树已于 2026-10-09 删除**（删前审计：它是 `origin/master` 的祖先、已跟踪文件零改动）⇒ 本件所有指向该树的路径按历史读；**位流与取证现保全在 `udp_hls_10g\_proj_10g\notes\p7b_retxfix_salvage\`**（位流 = `bits\`，7 个；本轮原始件 = `peer_notes\`；构建报告 = `build_reports\`）
- 入口 = `P7B_LOOP_HANDOFF.md`; 用户指令 = "开始调查核修复" ⇒ 走**路径 B (修重放策略)** 且同时取 C-② 的 RTL 级证据
- 本件只写实施与设计; 板级读数另立 (待跑)

## ⛔ 独立验收订正块 (2026-10-07 深夜; **权威 = `P7B_RETXFIX_ACCEPT.md`**, 本件按此块读)

独立验收 agent **自烧自跑 (6 次烧, 每臂现烧 + BID 回读核对)**, 结论**推翻本件的速率口径**:

| 臂 | 位流 | sink 聚合 Mbps (逐跑) | 重复率 ΔW15/ΔW51 | ΔW55 |
|---|---|---|---|---|
| Build 2 | `1ccbd9cd` | 889.5 / 891.3 / 894.2 | 1.009–1.014 | 39–52 |
| Build 3 | `1609d6f5` | 201.7 / 挂死 / 380.7 | 19.7 / 11.3 / 13.4 | 2,712–11,936 |
| **r4** | **`dfd9ec27`** | **103.6 / 106.2 / 107.9 / 118.8 / 125.2 / 126.8** | 1.045–1.054 | 119–160 |

1. ⛔ **r4 没把速率修回来, 且比缺陷臂还慢** (0.12–0.14× of Build 2)。本件 §3.8 的
   "r4 189.2 vs B3 180.8 (×1.047)" = **单跑, 不具代表性** (n=1; 验收 = 6 烧多跑)。
   **速率口径以验收为准**; §3.8 该行按此块读。
2. ⛔ **本件 §1.3 的承重件归错了**: `A' = A + K − 3` 把"K=2 衰减"当**证书** —— 它**被本件
   自己的 r3 实测证伪** (K=2 无纪律仍风暴)。真正扛住的是**纪律** (每个进展点至多一次 dup
   触发), 不是 K 的算术; K=3 只是"每次会话覆盖帧数"参数。§1.3 正文保留为过程记录。
3. ⛔ **"默认构建字节等价"只对 r2/r3 成立, 对 r4 不成立**: r4 恢复了 `tcp_rx.v` 纪律 ⇒
   **默认 1G 构建行为已变** (`git diff b30b499..HEAD -- rtl/tcp_rx.v` = **+14/−4 非空**)。
   本件 §1.2 末句 / §3.6 的 r3-矩阵豁免句 / `wrapper_p4.v` 的 r2 注释均按此读。
4. ⛔ **r4 曾无矩阵绑定** (指纹 ≠ HEAD 实际) ⇒ **已补跑** (2026-10-07 深夜, `matrix_r4.log`
   + 新指纹入库), 绑定以补跑件为准。
5. ⭐ **环确实死了 (验收亦确认)**: 重复率 19.7× (B3) → **1.045–1.054** (r4); 验收 pcap
   直方图 `{3帧×99, 34帧×20}` 逐位看见 K=3 截断 + RTO 全窗。**但 94% 墙钟 = 20 × 100.0 ms
   RTO 停摆** ⇒ 瓶颈从"重放环"换成了"**孔恢复延迟**"; 而 Build 2 (889) 无此停摆
   ⇒ **速率问题的主敌 = 100 ms 量子的恢复路径, 不是重放跨度**。
6. ✅ **未受伤 (验收复核)**: 上行 4115–4224 vs Build 2 4117–4230 · J0 复现 (809,578.4 fps /
   `193.0000` / 400k 帧全 1514 / `ΔW9/ΔW8`=1472.0001 / W56=0) · `ΔW54 ≡ 0` 全程 ·
   正交实验 (r1 重烧复跑) 支持其结论。
7. 新登记副作用: 尾延迟 9.4 ms → **103 ms (≈11×)** · RTO 臂自我 dup 最多再点火 **1 个**
   截断会话 (有界) · 挂死只在 B3 臂出现 1/3 · 与 `wu` 通路相互作用**未判**。

## ⭐ 目标口径裁定 (2026-10-08, 用户; 本轮起生效, 汇报/判据都按此分层)
- **~10G 线速目标 = 正常连接建立以后处理数据的速度** —— **不含**建连/控制流程开销;
  真目标 = **TCP 长连接的数据载荷处理速率**(或 UDP 报文处理速率)。
- 现台架"发 **1 MB** 就断开"(30 连微基准) = **极端情况下的协议栈鲁棒性/兜底能力测试**
  —— **保留、很好用**, 但**不是目标判据**。⇒ 本件 §3.10/§3.11 的读数按"**兜底口径**"读:
  它量的是**每连开销/建连洞**; 每连**稳态**载荷速率另记 (r5 pcap: 无停摆连 1 MB/3.0 ms
  ≈ **2.8 Gbps/连**; 有停摆连修好后 716–737 帧全速)。
- **兜底逻辑边际收益迅速下降** ⇒ **Gb 级能力达成后转向以功能建设为主**; 吞吐基准转为
  **回归守卫**(防止未来处理能力下降)。⇒ 后续新判据优先**长连接持续流**台架。

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
  ⛔ **本句只对 r2/r3 成立** —— r4 已在 §3.7 恢复纪律 ⇒ 最终修订的默认构建**不等价** (见顶部订正块 #3)。

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

### 2.6 wrapper63 编译门补 txframe 两臂 (t3/t4) + 牙检 (r5 同批)
- **缺口**: `run_tx_ovl_gate.bat` 不定义 `DP_156MHZ`; wrapper63 门不定义 `TCP_TX_OVL`
  ⇒ **板构建真实宏组合 {APP_MODE+P7B_10G+PCIE_OBS+DEV_USP+DP_156MHZ+UDP_TX_OVL+TCP_TX_OVL}
  此前没有任何常驻编译门** (坑 8 口径)。
- ⚠️ 先试了"给 wrapper 加 d4 臂"⇒ **撤回**: wrapper_p4.v 里 `TCP_TX_OVL` 只在注释出现
  (3 处全注释) ⇒ 该臂预处理文本与 d3 逐字相同 = **结构性恒过 (哑门)**。
- **增补** (`sim/p5wu_p1p2/run_xvlog_wrapper63.bat`, 现 6 臂): **t3** = d3 宏组编
  `rtl/tcp_tx_frame.v` (DP_156MHZ 开/OVL 关); **t4** = d3+`TCP_TX_OVL` (= 板构建真组合)。
  全绿 `XVLOG_WRAPPER63_PASS 6/6`。
- **牙检** (`p7b_retxfix/run_gate_teeth.bat` + `mkneg_txframe.py`; 变异件按锚点注入、
  锚点缺失即 exit 2 硬失败): `TEETH_PASS 5/5` —— `mut_ovl` 在 t3 rc=0 (**宏敏感**: 错误落在跳过区) /
  t4 rc=1 (**有牙**); `mut_dp` 两臂 rc=1; `clean` 对照 rc=0 (排除恒 fail)。
- 附一条 bat 纪律实测: **注释必须纯 ASCII** —— REM 行里的中文 + `>` 会让 cmd 把注释当重定向
  并执行残片 (本轮实测: 报 `'ame.py' 不是内部或外部命令`, 全 ASCII 重写后消失)。

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

### 3.9 ⭐ 独立验收后的判别实验 (纯本地 pcap 溯源, 2026-10-07 深夜) + **r5 设计**
**问题**: 验收测到 ~20 × 100.0 ms 停摆 = 94% 墙钟; "成因在对端栈?"。用 r4 臂的 pcap
(`p7b_retxfix/RXK.pcap`) 逐帧解剖**单连接** (板帧无法按端口分, 用其 `ack` 字段 = 各连对端
ISN+1 分流 — 板侧 ISN 对所有连接相同 = `0x12345678`, 故 seq 分析可跨连读):

- **快/慢连接奇偶交替** (dur p50 = 4.3 ms vs 慢类 103 ms; 端口 t0 序列直接显示)。
- 慢连接完整序列 (port 60138): 窗突发 (~30 帧/36 µs) → **对端栈只留住 ~2-3 帧** (其余乱序帧
  在其栈内被丢 —— 与 Stage C "OFO 丢帧"同族, 突发下更凶; 首帧也没进栈) → 首发 dup 批
  (need frame 1) → **板侧 session#1 (K=3) 按 replay 补回 3 帧** → 对端变 "缺第 4 帧"
  (`ack=0x12346795`), **而它的 dup 供给已枯竭** (没有新到达) → 3-dup 阈值填不满 →
  **等 RTO(100.0 ms) → RTO 的全窗重放一次修好 → 整条流 2 ms 内冲完**。快类 = 未触发该序列。
- ⭐ **101 个间隙的"间隙内对端 ACK 数"直方图 = {0: 72, 1: 24, 2: 5}** ⇒ 停摆时对端**基本没发东西**
  ⇒ "放宽重武装阈值 / 有界二击"**无输入可吃** (死路, 推论当场被数据砍掉);
  "全窗 + 纪律"会重新起链 (每次会话都有进展 ⇒ 自身 ~28 个重复段继续喂) ⇒
  **唯一活杠杆 = 修复延迟本身** (RTO 的全窗重放已证**每次修好**, 只是每孔等 100 ms)。

**⇒ r5 = `RTO_LIM` 100 ms → 20 ms** (板侧 RTT 仅 ~25 µs = 400× 余量; 连续流下对端每 2 段即
ACK ⇒ delayed-ACK 无暴露面, 只余**每连接收尾 1 次**孤立段的伪 RTO (有界重放, A/B 实测其线上代价))。

⚠️ **同批登记的判据新发现**: 矩阵的漂移守卫 (`sim/p4gates/paths.txt:48 FINGERPRINT_GLOBS`)
**只盯 sim 基础设施的 237 文件, 看不见 `rtl/` 的改动** ⇒ "不边跑边改 RTL"**只能靠人守**,
守卫给的是**假信心** (global §六 #28 族: **判据的覆盖面本身就是判据**)。

### 3.12 ⭐ **建连后稳态载荷速率 (目标口径)** —— 从 pcap 直接提取 (2026-10-08)
工具 = `p7b_retxfix/an_sustained.py <pcap...>` (板帧按 `ack == 对端 ISN+1` 分流; 停摆 =
相邻板帧间隔 > 3 ms; **稳态 = 最后一个洞结束 → 最后一帧**; 无洞连 = 全程)。

**r5/RXM (30 连, 每连 1 MB) 读数** —— 每连**建连后**线侧载荷速率:
**min 1029.7 / med 4530.3 / mean 4176.2 / max 6921.3 Mbps** (n=30);
其中无停摆连 (8 条) = 4122.2–6360.0 Mbps 全程; 有停摆连修好后 = 3462.1–6113.0 Mbps。

- ⇒ **单连接稳态已在 4.1–6.9 Gbps 量级** (中位 4.5) —— 与"~10G 目标 = 建连后处理速度"
  同口径。⚠️ 与 **app 可见速率** (sink 逐连 `dur_ms`) 不同口径: sink 单线程读 ⇒ 可见
  ~2.8 Gbps/连 (1 MB/3.0 ms), 线侧突发更快 (内核缓冲吸收) ⇒ **报数必须写清是哪一侧**。
- **r6-fix 版 (2026-10-08, 90 连 = RYV/W/X)**: **min 3271.7 / med 5289.2 / max 6631.3 Mbps**
  —— **低谷消失** (r5 的 1.03 Gbps 离群值 = 停摆连, 已随初始洞一起修掉); app 可见 = 3.6–4.0 Gbps/连
  (= 台架 sink 单线程上限, 非板读数)。
- ⚠️ **长连接的"再往上"缺一件真工具**: 现 app (`app_pattern`) 每连**只发 1 MB 就 FIN**
  ⇒ 真长连接台架需要 **app 侧持续流功能** —— 按用户口径 = **功能建设项** (记入功能账,
  不再是兜底打磨)。⇒ 本轮读数已足以支撑"Gb 级已达成"的结论。

### 3.11 ⭐⭐ r6 (L-A 根修) —— **ack_seen 数据启动门** (2026-10-08; 用户 2026-10-08 裁定走 L-A)
**一句话**: 对端首个 ACK 之前 **不放行任何 app 数据帧** —— 该 ACK 只可能在 SYN-ACK
上线之后出现 ⇒ 用它当"SYN-ACK 已出"的见证, 从根上消掉 §3.10 的**建连初始洞**。

**RTL (三处 + TB/门)**:
1. `rtl/tcp_rx.v`: 新端口 `ack_obs`/`ack_obs_id` (脉冲, 默认清零) —— 置位源 = 与 dup 计数
   / 推进 ACK 解锁**同一条判定** (`fend && s_axis_tcrs && !fend_trunc && (dup_l || ack_adv_l)`,
   均含 FCS 好 + CAM 命中)。宏 `TCP_TX_OVL` 内才有真逻辑, 宏外恒 0 (默认构建行为不变)。
2. `board/wrapper_p4.v`: `ack_seen_w [15:0]` 位图 —— 置位 = `rx_ack_obs`; **清位 = 建连事件
   `scfg_ev_up/scfg_ev_slot`** (与 D1 的 `fin_sent_r` 清位同一脉冲族; 同拍清优先 —— 防同槽
   重连的陈旧位) → `.ack_seen_i(ack_seen_w)` 进 `u_tcp_tx`。
3. `rtl/tcp_tx_frame.v` (**OVL 支, region 1**): `acks_ok = ack_seen_i[start_id]` 并入
   `tx_blk_sid` ⇒ `start_data`/`s_axis_tready` **逐字同门自动保持** (D2/坑 10)。
   ⚠️ 本刀**只动 OVL 支**; 默认支 (region 2) 逐字不动 (登记为后续项)。
   ⚠️ 落点勘误记录: 首版误把门加进 region 2 (`ifdef` 结构 = 236-1067 OVL / 1068-2042 默认),
   门在板构建里结构性不生效 —— 由 arm W 实测 (13 次保持窗内启动) 当场抓出。

**⛔ r6 首建 (BID 0x10) 板级 = 30 连零数据死锁 (确定性 ×3) —— 已定位并修 (r6-fix, BID 0x11)**:
- 形态: 握手教科书级完成 (pcap 恰 3 帧: SYN / SYN-ACK / ACK), 但对端 25 s 收不到任何数据
  (`SINK_RC=124` 超时), 板侧 `W14(tx_stat_frames_TCP)=0` / `W51(app_tx_bytes)=0` / `W22(rx pass)=1`
  —— app 一个字都没动 (门锁住)。**三跑逐字相同** (RXV/RXW/RXX) = 确定性。
- 根因 (读 RTL 定案): `tcp_rx` 的 `dup_ack = ... && (ra_snd_nxt != ra_snd_una)` —— "有在飞未确认
  数据"守卫 (为排除空闲连接的窗口探测)。**门把数据锁住 ⇒ snd_nxt==snd_una ⇒ 对端握手完成 ACK
  (ack==snd_una 的零推进 ACK) 既非 adv 又非 dup ⇒ 结构性不可见 ⇒ ack_seen 永不置位 ⇒ 死锁**。
  ⚠️ **r5 里不可见的原因 = 数据已在飞** (那时 snd_nxt≠snd_una, 同一批 ACK 被计入 dup) ——
  典型"**只在被修复的场景里不可观测**"的依赖 (登记为教训)。
- **r6-fix** = 补第三个置位源 **`ackok_l` = `ack_ok` 锁存** (帧内 ACK 在 `[snd_una, ack_hi]`
  范围内, 是 dup/adv 的**超集**; 含零推进 ACK)。板级重现路径由 3 跑原始件固定
  (`run_RXV/RXW/RXX.log` 在盘) ⇒ 修后可用同 protocol 直接判"是否还死"。
- ⚠️ **产生侧无门**: 这次抓到缺陷的仪器是**板子**, 不是门 —— ack_obs 的置位逻辑
  (producer 侧) 无任何 TB 判据 (`tb_tcp_tx_ovl` 驱动 `ack_seen_i` **输入端**, 测的是
  consumer 侧; `tb_tcp_rx` 是定向 drain 测试)。**登记为门账未收项** (需在 tb_tcp_rx 加
  "零推进合法 ACK ⇒ ack_obs 脉冲" 的定向判据, 并配变异牙检)。

**⭐ r6-fix 板级四臂同会话 A/B (2026-10-08; 每臂 n≥2, 同台架 stc_dl.sh 30 连/1 MB, 臂间重烧+设备级 rescan+身份闸)**:
| 臂 | 位流 sha256 (前 8) / BID | agg Mbps (逐跑) | 中位 | vs Build 2 | `W15/W51` | `ΔW55` 会话 | W20 帧 |
|---|---|---|---|---|---|---|---|
| Build 2 | `1ccbd9cd` / 9 | 893.8 / 895.6 | 894.7 | 1.00× | 1.01 | 36–42 | 21,821 |
| **r6-fix** | **`8c8b6126` / 0x11** | **3629.6 / 3695.7 / 3690.5** | **3690.5** | **4.12×** | **1.00** | **0** | 21,660 |
| r5 | `39afd127` / 0xF | 460.5 / 472.5 | 466.5 | 0.52× | 1.05–1.06 | 129–169 | 22,698 |
| r4 | (本件 §3.8 会话) | 98.1–116.9 | 98.6 | 0.11× | — | — | — |

- ⭐ **r6-fix = 零洞世界**: **`W15/W51 = 1.00`(逐字节 = 发多少不重复) + `ΔW55 = 0`(全轮零重传会话)**
  + W20 = 21,660 = 21,570 数据 + 90 控制 (30×[SYN-ACK+opener+FIN]) ⇒ **线上完全无冗余**。
  对比: B2 = 36–42 会话 (其 1 帧滑出的 K=3 修)、r5 = 130–169 会话 (22 个 20 ms RTO)。
- wall: **68–70 ms** (30 MB) vs B2 281 ms / r5 547 ms; 九跑 (r6×3 + B2×2 + r5×2 + …)
  全部 `fail_conns=0 / mismatch_bytes=0 / ΔW54 ≡ 0`。
- **目标口径 (建连后稳态, `an_sustained.py`, 90 连)**: **min 3271.7 / med 5289.2 / max 6631.3 Mbps**
  (vs r5/RXM 的 min 1029.7 —— 低谷 (停摆连) 消失; max 6830 同量级)。
- ⚠️ **台架帽**: 单连 app 可见 (sinkMbps) = 3565–4059 Mbps ⇒ **~3.6–4.0 Gbps 处是 sink 单线程
  读的上限**(sink 逐连串行: agg ≈ 单连) —— 不是板子读数。**"板子真实天花板"仍未被测**
  (候选: 板 TX 线 ~9.5 / 双向预算 / 对端接收)—— 与"长连接持续流台架"同批解决 (功能账)。

**门证据 (本轮)**:
- **OVL 门 21 臂 = `TX_OVL_GATE: PASS`** (原件 `p7b_retxfix/gate_ovl_r6.txt`); 其中新增
  - **arm W** (`-d ARM_ACKGATE`, 好件): `ACKGATE block=0 resume=0 witness_offer=1941`
    —— 动态抽门 2000 拍: 窗内零启动 + 放回 600 拍内恢复 + 供数见证 1941 拍 (非空判据);
  - **arm X** (`mut_l1` = 撤 `~acks_ok` 项): `block=13` ⇒ **判据有牙** (mut_l1 由
    `mk_mut_tx.py` 锚点生成, `diff --strip-trailing-cr` = 恰一行);
  - 其余 19 臂逐字不变 (A/B OA、C-L/U/V 红、P/Q/R 探针、S/T 集成)。
- ⚠️ 附带修两处**同型缺口 (Z 悬空 ⇒ X)**: `tb_integ_app_tx.v` 与 probe/`tb_flood_probe.v`
  的 `tcp_tx_frame` 例化必须显式接 `.ack_seen_i(16'hFFFF)` —— 否则 `tx_blk_sid=X` ⇒ 帧
  结构性起不来 (首跑即抓出: 探针 Q 的 FLOOD 判据被结构性地打成 NOFLOOD)。
- P4 矩阵 16 门: 见 §3.11 尾 (本轮补跑; r4 时因"无矩阵绑定"被验收点名)。

### 3.10 ⭐⭐ r5 板级三臂同会话 A/B + **残余机理定案** (2026-10-07/08 深夜)
**r5 = 唯一改动 `RTO_LIM` 61035→12207** (≈100→20 ms, 只在 `DP_156MHZ` 支; 125MHz 支一字未动)。
构建 **WNS +0.033 / WHS +0.010 / 三类失败端点 0/0/0** (246,501 setup 端点全过); 位流 sha256
**`39afd127…26d4`** (15,431,261 B); 板级身份 BID 0xF 全中 (`ID_OK`)。

**三臂同会话** (同台架 `stc_dl.sh`, CONNS=30/SECS=25, 每臂 n=3, 臂间重烧 + 设备级 rescan + 身份闸):

| 臂 | agg Mbps (n=3) | 中位 | vs Build 2 | 每连 dur (wall/30) |
|---|---|---|---|---|
| Build 2 (BID 9) | 892.5 / 894.2 / 894.5 | 894.2 | 1.00× | ≈9.4 ms |
| **r5 (BID 0xF)** | 446.8 / 526.6 / 385.8 | **446.8** | **0.50×** | ≈22 ms |
| r4 (BID 0xE) | 98.1 / 98.6 / 116.9 | 98.6 | 0.11× | (慢类 103 ms) |

- **r5/r4 = ×4.53** —— 与 100/20 停摆量子比逐位吻合 ⇒ 验收的"94% 墙钟 = ~20 × 100.0 ms 停摆"
  模型被同会话 A/B **直接证实** (这一刀只改停摆时长, 不动别的)。
- r4 同会话读数 (98.1–116.9) 精确复现验收带 103.6–126.8 ⇒ 台架跨会话可比; 九跑全部
  `fail_conns=0 / mismatch_bytes=0` (30/30 clean); `ΔW54 ≡ 0`。Build 2 vs Stage C 轮的 889.4/890.3 也复现。
- 三臂板侧同规格: W51=31,457,280 (k=0) / W52=21,570 / ΔW55 = r5 128–164、B2 36–48、r4 (见验收)。

**残余 = 22/30 连各恰好一次 20.0 ms 停摆** (`an_stall_forensics.py --gaps --gap-ms 3`: 时长直方图
**{20: 22}**, 每连停摆数分布 **{0: 8, 1: 22}**, 间歇内对端 ACK {1: 10, 2: 12})。
台架实为**逐连串行** (SYN 间距 22.2 ms ≈ 前连时长; wall ≈ Σ dur) ⇒ 22×20 ms = 残余的全部来源。

**逐帧定案 (RXM.pcap, conn 40334)**:
1. **洞 = 49,640 B = 整 34 帧** —— 22 连**逐字节相同** (= 板侧在飞整窗上限); RTO 重放起点 =
   对端最高 ACK (= snd_una) ⇒ 全窗重放 ✓; 洞在**建连后第 40–52 帧**、之后 716–737 帧无二次停顿。
2. **根因链 (四台仪器同指)**:
   - ⭐ **板子在 SYN-ACK 之前就发出应用数据**: 滑出量由 A2/OVL 的 TX 速率决定 ——
     **r5 ≈ 8–19 帧, Build 2 ≈ 1 帧** (两臂 pcap 同址复现; Wireshark 把 SYN-ACK 标
     `[TCP Retransmission]` 即此证据; 数据帧与 SYN-ACK 同/早于 14 µs)。
   - 对端此时在 **SYN_SENT** ⇒ **这些帧被静默丢弃** (对端 rcv_nxt 停在 ISN+1: 其 ACK `ack=ISN+1`
     连续 13 个; `TcpExtTCPOFOQueue d=770` = 后续帧全进乱序队列)。**替代解释三条全被计数排除**:
     无 PAWS (`TCPACKSkippedPAWS=0`)、无 CRC 错 (`rx_eth_crc_err=0`)、无时间戳 (板帧不带 TS)。
   - 洞 = 滑出量。K=3 会话 **`RETX_SPAN=3` 每次只补 3 帧** ⇒ 需多轮; 而 dup 供给随窗口打满枯竭
     (`in_retx` 纪律吞掉会话期 dup + 无新帧到达 ⇒ 无新 dup) ⇒ **22/30 连输掉"补洞竞赛" ⇒ RTO 20 ms
     全窗重放收尾** (8 连赢 ⇒ 无停顿)。
3. **Build 2 同异常、但滑出 ≈1 帧** ⇒ 洞 ≤ 3 ⇒ 首个 K=3 会话一次补完 ⇒ 永不等 RTO。
   **⇒ 这就是 0.50× 的全部来源; r4 的 100 ms 只是同一洞的 5 倍等待。**

**⇒ 下一刀 (两候选, 都是板侧; 待定夺)**:
- **(L-B, 最小) `RETX_SPAN` 3 → ≥在飞窗 (如 32)**: 首个 dup 会话一次覆盖整洞
  (环安全仍由 r4 纪律承重, 已由板级三轮证实) ⇒ 预期消掉 ~22×20 ms; 需 OVL 门复跑 (t3/t4 已罩编译面)。
- **(L-A, 根修) 让数据让位于 SYN-ACK**: fast path 需"SYN-ACK 已发"信号 (慢路径); 消除洞本身。
  ⚠️ B2 的"1 帧滑出"表明该窗口天然存在 (~14–87 µs), 不是 r5 新引入。
- (L-C) RTO 再降 = band-aid (洞仍在, 只是等待更短)。

⚠️ 登记: `run_RXM/RXN/RXO` (r5) + `run_RXP/RXQ/RXR` (B2) + `run_RXS/RXT/RXU` (r4) 九跑日志入库;
三臂 pcap 在盘 (按策略不入库); `an_stall_forensics.py` 本轮增 `--gap-ms` (r5 的 20 ms 量子下,
旧 50 ms 阈值结构性漏掉全部停摆 —— 判据阈值必须按被测量子设)。

### 5.1 板级命令 (逐字可复跑; PEER_PW 只在环境变量里, 不落盘)　⛔ **2026-10-09 订正（不静默改）：本节内的 `D:\repo\XCKU5PMini\udp_hls_10g_fix\...` 路径随该树删除而失效（命令按历史读）；位流现路径 = `udp_hls_10g\_proj_10g\notes\p7b_retxfix_salvage\bits\`（r3 = `4e114594__wrapper_p4.bit`），烧录入口 = `udp_hls_10g\_proj_10g\notes\p7b_biz_tcpreg\run_program_tcpreg.bat`（自定位、读 `TCPREG_BIT`）**
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
| r3 | `4e114594…3f32` | 0xD | 板级已测 (K=2 爬行+失配, §3.6) |
| r4 (定版, 环已死) | `retxfix_r4_wrapper_p4.bit` | 0xE | 板级已测 (§3.8/§3.10; 同会话 98.1–116.9 Mbps) |
| r5 | `39afd127…26d4` | 0xF | 板级已测 (§3.10/§3.11; 同会话 466.5 Mbps median) |
| r6 (ack_seen 门首版) | `112328da…6381` | 0x10 | ⛔ **板级实测缺陷** (§3.11: 死锁, 30 连零数据 ×3 确定性; 保留为鲁棒性回归件) |
| **r6-fix (现役, 板上现态)** | **`8c8b6126…baf5`** | **0x11** | 板级已测 (§3.11; **3690.5 Mbps median = 4.12× B2; 零重传; 受控停流**) |
