# udp_hls_10g — 10G-ready 纯硬件 TCP/IP 数据面 (1G 先行施工)

终局目标: 10G 线速纯硬件 TCP/IP (低延时行情 UDP 组播 + 交易 TCP 少量连接), 对上提供 TCP/UDP 调用接口。
施工策略 (2026-08-23 用户拍板): **1G 先行、10G-ready** — 数据面统一 64bit 宽流水 @125MHz,
10G 时仅提时钟到 156.25MHz, 流水线不改。设计审查与总计划: `../udp_hls_eco/design_review/` (01-04)。

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

## 目录

| 路径 | 内容 |
|------|------|
| `rtl/` | 数据面 RTL (mac_rx_64/mac_tx_64/tcp_rx/tcp_tx_frame/tcb/tcp_cam/retx_ram/…) + `app_*.v` (P5 app 接口与演示 app) |
| `tb/` | xsim testbench (`tb_p4_chain` 全链 / `tb_p5_*` app 门与对抗集 / 各单元 TB) |
| `sim/` | xsim 工作目录 (每个门用**独立目录**, 避免 `xsim.dir` 文件锁; 见下"本工程新增坑" 7)。**canonical 门** = `sim/p4sim/` (P4 矩阵) / `sim/p5sim/` (P5 app 门) / `sim/p5close/` (P5c 定向证伪门); 其余 `sim/p5b_*/`、`sim/p5c_*/`、`sim/p5bfix/`、`sim/f2chk/`、`sim/t1run/` 等是**复核/跑数产物目录**, 已 ignore (只保留其中的 `run_tb_*.bat` 与 TB 源码) |
| `tools/` | Python (anaconda: `/c/Users/zhxue/anaconda3/python.exe`) + `cpp_peer/` 合成 TCP 对端 |
| `board/` | `wrapper_p4.v` (顶层, APP_MODE 分支) / `uart_dbg.v` / XDC / 构建烧录 bat 与 tcl |
| `hls/` | HLS 慢路径 (`src/` 源码 + `tb/` 测试台跟踪; `slowstack_prj/` 与 `logs/` 是产物, 已 ignore) |
| `vivado_prj/` | Vivado 工程产物 (已 ignore); 位流 `p4_prj`/`p5_prj` 各一套 |

## 验证

```bash
cd /d/repo/ECO/udp_hls_10g
# P4 全矩阵 16 门 (默认构建回归; 改动数据面后必跑)
bash sim/p4sim/run_matrix_p4dfix.sh
# P5 app 门 (APP_MODE)
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_app.bat'      # 1MB 图案逐字节
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_wrapper.bat'  # wrapper APP_MODE 全链 (接线错误只有它能抓)
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_status.bat'   # 220 字符状态行
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_adv.bat' reconn_fast   # 对抗集 (len/b2b/wnd/fin/findrop/abort/evfifo/reconn_fast/reconn_slow/multi/accmgn)
# P5b 流控闭环门 (独立单元门 + 全链慢消费者门)
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_fc.bat'       # tb_app_fc: 池/右沿算术边界/回绕/事件撞车 (110 项)
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_flow.bat'     # 512KB 慢消费者 + 对端灌数据 (占用/右沿/零重传)
# P5c 关闭语义门
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5sim\run_tb_p5_app.bat' close  # 关闭语义门 (FIN/RTO 重发/RST+fence/同时关闭/超时)
cmd //c 'D:\repo\ECO\udp_hls_10g\sim\p5close\run_tb_tcp_close.bat' # 定向证伪门 (G1 FIN 重推死锁 / G9 回卷洪水)
# 构建与烧录
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_build_p4.bat'    # 默认 (echo)
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_build_p5.bat'    # APP_MODE (app 接口)
cmd //c 'D:\repo\ECO\udp_hls_10g\board\run_program_p4.bat'  # / run_program_p5.bat
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
