# sim/p5close — P5c-T2 定向证伪门 (TCP 关闭语义两个缺陷)

独立单元门目录。**只新增文件**: `rtl/`、`tb/`、`board/`、`tools/` 全部未改动
(compile 时只**读**当前工作树的 `rtl/tcp_tx_frame.v` 等)。门直接例化
`tcp_tx_frame` + `tcb` + `tcp_cam` (无 `mac_tx_64`; `m_axis_tready` 恒 1)。

## 怎么跑

一条命令:

```
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5close\run_tb_tcp_close.bat'
```

退出码:

| 码 | 含义 |
|---|---|
| 0 | G1 + G9 都 PASS (修复已生效) |
| 1 | 至少一个 FAIL (缺陷在当前 RTL 复现) |
| 2 | xvlog/xelab/xsim 报错, 或日志里没有判据行 |

`$fatal` 不使用; 判据由 TB 打印 `GATE tb_close_g1: PASS/FAIL`、`GATE tb_close_g9: PASS/FAIL`
一行, bat 用 `findstr` 读取并映射退出码 (日志缺失/工具失败 => 2, 不会静默变绿)。

日志: `sim/p5close/g1run/xsim_g1.log`、`sim/p5close/g9run/xsim_g9.log`
(两个 case 各用独立工作目录, 避免 `xsim.dir` 文件锁 == 工程铁律 7)。

判据只看 DUT 的**输出帧流**(帧计数/flags/seq/载荷字节不变式), 不依赖内部信号;
内部信号只用来自检注入是否真的到达目标路径。

## G1 — FIN 重推的唯一机会被 ack_req 抢走 (tb_close_g1.v)

机理 (`rtl/tcp_tx_frame.v` 当前工作树行号):

1. FIN 发出: `S_DONE` (L915-919) 置 `fin_sent_r[0]=1`/`fin_seq_r[0]=6000`;
   `upd_val` (L340) = `seq_r+1` => `snd_nxt=6001`, `snd_una=6000`。
2. `snd_nxt != snd_una` => 扫描装 RTO (L726) -> `rto_pend` -> `rto_pend_any` (L626)
   -> `svc` (L280); `svc_rewind` (L332) 写 `snd_nxt := snd_una = 6000`,
   同时 `retx_hi <= fin_seq_r = 6000` (L658)。
3. 回卷后**下一拍**就是唯一一次 "ring 排空拍" (`ring_eval && !ring_start`, L283-286;
   `ring_delta = 6000-6000 = 0`)。该拍:
   - `fin_repush` (L543) = 1 —— 但 `fin_repush` **不含** `!ack_req_ok`;
   - `ackq_din` mux (L563) 优先级 `ack_req_ok > ... > fin_repush` => ACK 条目占了这次写,
     FIN 条目被吞;
   - L706 清 `fin_retx_pend` 的守卫是 `(!ackq_full && !ack_req_ok)` => 本拍不清, `fin_retx_pend[0]` 保持 1;
   - L708 `retx_active <= 0` **无守卫** => 会话结束。
4. 此后 `snd_nxt == snd_una == 6000` => L726 装表条件恒假 => 再无 `rto_pend` => 再无 `svc`
   => 再无排空拍 (L283 需要 `retx_active`) => `fin_repush` 永不再评估。app 侧 `fin_sent_r=1`
   又禁止 `fin_push` 重排队 (L537) => **FIN 永不重发, 关闭永不完成**。
   (L700-705 的注释写着 "下一轮 ring 排空拍再重推" —— 代码给不出下一轮, 这是注释与实现的分歧点。)

**确定性注入** (不用等概率事件, 也不是层次写值):

```verilog
// tb_close_g1.v
wire ack_req = ack_req_arm && !ack_inj_fired && (u_dut.ring_eval && !u_dut.ring_start);
```

单拍脉冲, 语义与端口注释一致 ("ACK 请求 (tcp_rx 脉冲)"); 位置精确落在唯一一次排空拍
=> 100% 命中 (`G1 injection = fired=1`), 且只发一次, 不会挡住"重试型修复"。

`RTO_LIM=2`: 只缩短计时器重装值 (L156 参数), 触发路径与生产完全一致 (扫描计时 ->
`rto_pend` -> `svc`)。生产值 `48828 x 256 拍 = 12.5M 拍`在本门里跑不动; 判据与计时器长短无关。

**判据**: PASS = FIN 帧数 >= 2 且 seq 不漂移 (关闭可完成); FAIL = FIN 帧数 == 1。

**当前 RTL 实测: FAIL** — 关键数字:

```
[DRAN] k=1067 drain#1: delta=00000000 fin_retx_pend[0]=1 | ack_req=1 ack_req_ok=1
       ackq_full=0 fin_repush=1 => ackq_din=ACK(STEAL)
G1 FIN frames      = 1 (stat_fin=1)     ring_drain_beats = 1
G1 svc sessions    = 1 (stat_retx=1)    RTO re-arm = 1 (仅首发那次)
G1 ackq FIN entries= pushed 1 (fin_push=1 fin_repush_pulse=1)
G1 final state     = snd_nxt=00001770 snd_una=00001770 retx_hi=00001770
                     retx_active=0 fin_retx_pend[0]=1   <= 挂起位永久残留
```

**EPI (判据之后, 不计入 PASS/FAIL)**: 关掉注入后补一次 `retx_req` (dup-ACK 通道) =>
同一拍 `svc` 应答, 下一拍排空拍 `ack_req=0` => FIN 条目顺利入队, FIN #2 发出
(`seq=6000` 不漂移), `fin_retx_pend` 清 0。即: 挂起位还在, **RTO 路径已死, 只有外部
svc 触发器能把 FIN 救回来**。

## G9 — blocked + FIN 在飞 => ring_delta 下溢洪水 (tb_close_g9.v)

机理:

1. `blocked = (epoch[svc_id] >= 15)` (L331); `svc_rewind` (L332) 在 blocked 时为 0 =>
   **不回卷** (L339 的 `upd_val = rb_snd_una` 不发生)。
2. 但 `svc` 拍无条件 `retx_hi <= fin_seq_r` (L658) 且 `retx_active <= 1` (L661)。
   FIN 在飞时 `snd_nxt = fin_seq+1`, 而 `retx_hi = fin_seq` => `ring_delta = retx_hi - rb_snd_nxt`
   (L285) = `0xFFFFFFFF` (**32 位下溢**)。
3. `ring_start = ring_eval && (ring_delta != 0)` (L286) = 1; `plen_preset`
   (L455) = `ring_delta >= 1460 ? 1460 : ...` => **1460**。
4. 每帧 S_DONE 把 `snd_nxt += 1460`, 于是 `ring_delta` 每帧减 1460, 直到 `snd_nxt == retx_hi`
   —— 需要 `2^32/1460 ≈ 2941758 帧` (约 **4096 MB**, 全部从重传 ring 读出)。

**真实流程复现, 无任何层次强制/写值**:

1. 连发 45 帧 x 1460B 活数据 (每帧完成后 TB 通过 TCB 写口把 `snd_una := snd_nxt`,
   模拟对端 ACK) —— 45x1460 = 65700 B > 64KB/conn => **ring 被整圈写过**, 环内全是
   "已 ACK 过的旧数据"。载荷图案 `pat(seq) = seq[7:0]` (8 位运算 => 65536 周期 =>
   同一下标无论何时写入值都相同)。
2. `fin_req[0]=1` => FIN 首发 (`seq=71700`), `snd_nxt=71701`。
3. 对端死 (不再 ACK): 16 次重传会话, 每次 `svc` 都因 `snd_una` 未变而 `epoch++`
   (L647-651), 每次正常回卷 + 重推 FIN (`fin_retx_pend`) => FIN 重发, **无洪水**。
4. 第 17 次 `svc`: `epoch==15` => `blocked=1` => `svc_rewind=0` => 洪水开始。

svc 触发用 `retx_req` (dup-ACK 快速重传通道, 端口语义 = 电平保持到 `retx_gnt`);
RTO 路径共用同一份 svc 代码体 (L280/L644), 差别只在触发源。这里 `RTO_LIM` **保持生产值
48828** —— 既因为 12.5M 拍跑不动, 也顺带保证了 push 阶段结构性不可能有早期 RTO 干扰
(本门总长 ~45k 拍)。注意: 真实系统里 "FIN 重发循环" 自己就会把 `epoch` 推到 15
(对端不 ACK 时每次会话都没进展), 所以 blocked + FIN 在飞不是奇态, 而是 close 后
对端失联的**稳态** (生产 RTO 100ms x 16 ~= 1.7s 后触发)。

**判据**: PASS = FIN 之后不再出现 1460B 数据帧; FAIL = FIN 之后出现 >=1 帧 1460B 数据帧。
附加只读校验 (证明重放的是旧数据): 每个数据帧前 10 个载荷字节必须等于 `(seq+j)[7:0]`。

**当前 RTL 实测: FAIL** — 关键数字:

```
[SVC ] k=34626 svc#17 rewind=0 blocked=1 epoch=15      <= 第 17 次会话不再回卷
[RING] k=34627 *** ring_start#1: seq=00011815 ring_delta=ffffffff
       (=retx_hi 00011814 - snd_nxt 00011815, 32bit UNDERFLOW) plen_preset=1460
[RING] k=34627 delta 需要 2941758 帧 x 1460 B = 4294968140 B (~4096 MB) 才能追平
G9 FIN frames      = 17 (stat_fin=17) first/last seq 均 00011814 (无漂移)
G9 svc sessions    = 17 (stat_retx=16)  ring_drain_beats=16  epoch[0]=15
G9 ackq FIN entries= pushed 17 (fin_push=1 fin_repush_pulse=16)
G9 replay flood    = 31 frames x 1460 B in 12000 clk (ring_start=32, 末帧在飞)
                     delta now ffff4f33 (march=45260 B = 31 帧)  projected 2941758 帧 / 4096 MB
G9 载荷不变式      = ok_frames=76 bad=0 x=0  (45 活帧 + 31 洪帧 全部逐字节命中)
```

洪帧速率 31 帧 / 12000 拍 = 387 拍/帧 => 1514 B/387 拍 ≈ 3.9 B/拍 ≈ 490 MB/s (@125MHz);
按 2941758 帧 x 387 拍算, 追平需要 ~9.1 s (期间 `retx_active` 一直为 1, `snd_nxt` 单调前滚,
对端会持续收到 `seq=71701` 起的"旧数据" 1460B 段)。

## 门自检 (怎么确认注入/触发真的到达目标路径)

- G1: `[DRAN] drain#1 ... ack_req=1 ack_req_ok=1 fin_repush=1 => ackq_din=ACK(STEAL)`
  —— 同拍打印 `ring_eval=1 / ring_start=0 / delta / ackq_full` 与 mux 结果;
  判据行附 `G1 injection = fired=1`。`ring_drain_beats=1` 证明"唯一一次"确实是唯一一次。
- G1: `RTO_LIM=2` 由 `[CFG]` 行回读确认参数覆盖生效 (`u_dut.RTO_LIM` 层次读)。
- G9: 每个 svc 拍打印 `rewind/blocked/epoch/retx_hi`; 第 17 次 `blocked=1 epoch=15`
  与 `ring_start#1 delta=ffffffff` 相邻两拍, 因果链在日志里可见。
- 两侧都打印 `ring_delta` 的**数值漂移**与帧数: G9 `march=45260 B = 31 帧` 与
  `flood=31 frames` 精确对账 (每帧恰好 1460 B), G1 无洪水。
- 帧流侧的 seq/flags/len 全部由 TB 从 AXIS 字流重新解析 (不是读 DUT 内部寄存器),
  所以"FIN 帧数 / 1460B 帧数"是端到端计数。

## 修复后必须 PASS: 方向已用 mock 修复自测过

不能改 `rtl/`, 所以把 6 个 RTL 文件**复制**到临时目录 (`%TEMP%\p5close_mockfix\rtl`),
只改两处后跑同一对 TB:

- mock-A (G1): 排空拍的清 `fin_retx_pend` / 结束会话改为"只有条目确实入队
  (`fin_repush && !ack_req_ok`) 才清/才结束, 否则保持 `retx_active=1` 下拍重试"
  => **G1 PASS** (FIN 17 帧, `fin_retx_pend` 收敛到 0)。
- mock-B (G9): `retx_active <= svc_rewind` (无回卷则不起 ring 会话)
  => **G9 PASS** (0 帧洪水, 17 个 FIN 重发全部照旧, 判据唯一变化是洪水消失)。

即两门都不是"永远红"; 判据是语义判据, 不绑定某种具体修法 (重试型/放弃型/钳位型
retx_hi 的修法都能满足)。

## 已知边界 / 与 TL 记录的偏差

1. **`ackq_full` 那一支是死代码**: 排空拍要求 `!ack_pend_r`, 而 `ack_pend_r <= !ackq_empty`
   (L627 注册), 即"上一拍队列为空"; 队列每拍最多 +1 条 => 排空拍上 `ackq_full` 恒 0
   (本门实测 `ackq_full=0`, 队列 32 深)。所以 G1 的**唯一**窃取源是 `ack_req_ok`,
   TL 描述的 "或 ackq_full=1" 在当前 RTL 不可达。
2. **`fin_repush` 信号本身仍是 1**: 缺陷不是"没发起重推", 而是"发起了但被 mux 吞掉 +
   同拍结束会话 + 守卫不清挂起位"三者叠加。修 `fin_repush` 的布尔式而不动 L706/L708
   是修不好的。
3. **G9 的 "dst MAC 来自已清空的 CAM" 未复现**: 本门 CAM 保持配置, 洪帧的 dmac =
   `11:22:33:44:55:66` (合法), 载荷是陈旧数据。要出现 dmac=0 需慢路径 DEL 先清 CAM
   而 TCB `state` 仍为 1 且 `fin_sent_r`/`epoch` 存活 (竞态窗口); 且扫描看到
   `rb_state != 1` 会清 `fin_sent_r` (L718-720), 从而改变 `retx_hi`/不触发洪水 ——
   所以"已清空 CAM"是**条件性加剧**, 不属于本门复现的机理。
4. **G9 的 svc 触发源**用 `retx_req` 而非 RTO (理由见上); svc 代码体同一份, 但如果你想
   要"RTO 触发"的版本, 把 `RTO_LIM` 改成小值 (如 2) 也能跑起来 —— 代价是 push 阶段
   出现毫秒级概率的早期 RTO 干扰, 本门为了确定性没有这么做。
