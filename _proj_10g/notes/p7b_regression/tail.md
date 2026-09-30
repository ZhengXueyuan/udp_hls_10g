
---

## 8. 复现方式与副作用声明（诚实披露）

### 8.1 怎么复跑

```bash
# 全量（136 门；约 63 分钟，2 路并发，按目录串行避免 xsim.dir 锁）
C:/Users/zhxue/anaconda3/python.exe -u _proj_10g/notes/p7b_regression/run_all_gates.py --jobs 2
# 只跑指定门
... run_all_gates.py --only p7b_mac,p4_rxclass
# A/B（需要先 git worktree add 一个基线树 + 补 HLS 网表与 sim/p4sim/run.tcl）
... ab_batch.py
```

每个门一份日志：`p7b_regression/logs/<门名>.log`（日志头写死了 bat 路径 / 参数 / 期望退出码 / 描述）。

### 8.2 副作用（门自己会写文件）

跑门**必然刷新门自己的产物**。本轮刷新了 **约 37 个"已跟踪"文件**（`git status` 可见），
全部是**门的产物/证据文件**，无一是 RTL/TB/脚本源码：

| 目录 | 数 | 例 |
|---|---|---|
| `sim/fifoasync/` | 15 | `gate_bound.txt` `gate_lat.txt` `fingerprint.txt` |
| `sim/snapcdc/` | 6 | `review/*.txt` |
| `sim/f4sim/st_new/` | 6 | `f4_data.memh` `f4_dv.memh`（TB 刺激镜像） |
| `sim/rxpdiag/` | 5 | 诊断产物 |
| `sim/p4sim/matrix_p4dfix.log` | 1 | **P4 矩阵自己的日志**（矩阵的正式产物，刷新即应有） |
| `_proj_10g/sim/xsim_run.txt` | 1 | P7a 计数器门的产物 |
| `sim/` 下其余单门产物 | 若干 | 各门 `xsim_*.log`（多数已 ignore） |

**没有改动的**：`rtl/**` `tb/**` `board/**` 与任何 `run_*.bat` / `run_*.sh` / `.tcl` 脚本 —— **本任务只跑与判定**。
（`git status` 里 `board/wrapper_p4.v` 的改动是**另一个 agent** 的注释订正（`0x10 → 0x08`，闸 4 相关），
`_proj_10g/notes/P7B_MAC_DESIGN.md` 与 `p7b_mac_synth/tcl/*.tcl` 同样是**别人的**改动。）

A/B 用的 worktree（`D:\repo\XCKU5PMini\_ab_p7b_02d51ed`）**已删除**，`git worktree list` 现只剩主树。

### 8.3 与文档既有表述的**订正**

1. `README.md` / `CLAUDE.md` 写「P4 矩阵 16 门里 `unit_retx` / `unit_fifo` 无条件 exit 0」 ⇒ **成立**，
   本轮**已按纪律读日志尾**：`ALL 7 GROUPS PASS` / `PASS_ALL` ⇒ 两条**实为 PASS**。
2. **新增**：哑门不止那两条。本轮又实测出 **6 条**（`d2_suite` / `p5c_rev_elab` / `f4_sttrace` /
   `p4_replay` / `p4indm_4gates` / `p7b_impl_one`），其中 **`p5c_rev_elab` 的哑门掩盖了一个既存 elab 硬失败**
   （`board/wrapper_p4.v` 例化的 `udp_tx_cfg` / `udp_tx_frame` 不在该门的 RTLF 清单里）。
3. `p4indm/run_4gates.sh` 是 **cmd 语法串进 bash** 的坏脚本（`%REPO_ROOT%`），结果永远写不出去
   —— 属工程「真空门」家族的**残留**，建议列入修复清单。

---

## 9. 一句话结论

**本轮 RTL 改动引入了 1 处真回归 —— `rx_classify` v2 新增 `fifo_sync` 例化、而两条门（`p4_rxclass` / `p4_rxclass_xk`）的编译清单没跟上 ⇒ 两条门由绿转红；除此之外全仓 136 门无任何新增回归（其余 21 条失败在基线 `02d51ed` 上逐字/逐因复现，1 条为偶发）。**
