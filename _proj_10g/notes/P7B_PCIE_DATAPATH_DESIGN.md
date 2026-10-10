# P7B_PCIE_DATAPATH_DESIGN — SFP+ → 板上 TCP/IP 栈 → PCIe → 驱动 → PC 程序（侦察 + 设计件）

> **本件是"侦察 + 设计"**。⛔ 未改任何 RTL / 构建 / 仿真 / 板级文件；未上板；未连 JTAG；未跑 Vivado；未做 git 写操作。
> 全部行号 = **2026-10-11 现读现引**（仓根 = `D:\repo\XCKU5PMini\udp_hls_10g\`，相对路径均以此为准），引用行号一律同抄行内容。
> ⚠️ **工作树里另有一个构建 agent 正在改 `board/wrapper_p4.v`**（本日现核：BID 已 bump 到 `0x1C`、`tcp_tx_frame` 例化处 `.PERSIST_EN(1'b0)`）—— 本件**只读**它。
> 本件给的行号以**本日工作树**为准；落笔实施前**必须重核**（该文件每次构建都可能变）。
> 判据层 PASS/FAIL 的裁定权不在本件（全局 #51）。本件只给"可判定的验证判据"设计，不下裁定。

---

## 0. TL;DR

| # | 结论 | 依据 |
|---|---|---|
| 1 | 端点 = 官方 **XDMA 4.2**（`xdma_0`），配置 = **AXI-MM 模式**：`m_axi`（**128 位**，同时承载 **1 H2C + 1 C2H** 两个 DMA 引擎）+ **AXI4-Lite user BAR**（= BAR0，1 MB → 我们自己的 `axi_regs`）。**没有 AXI-Stream 通道**（与派单措辞不符，见 §1.7-①） | `board/build_p7b_ku5p.tcl:112-130` · 生成的 `.veo` 端口表 · `_proj_10g/notes/P7B_PCIE_RESCAN_RECOVERY.md:154` |
| 2 | **DMA 引擎已经在 IP 里**，只是 `m_axi` 被**显式 tie-off**（"全回永不应答"）⇒ 走 C2H 数据通道**不需要重生成 IP、不需要改 BAR、不碰许可**，只需要 **wrapper 接线 + 一块新的 AXI-MM 读从机** | `board/wrapper_p4.v:3995-4013` |
| 3 | 三条候选：（B）user BAR 搬运窗（**逻辑最小**，上界 ~**1–10 MB/s** 量级，由 PCIe 往返 + 主机软件路径决定）·（A）C2H DMA（上界 = **链路级 ~1.7 GB/s**，未实测；板内 128 位 @250 MHz = 4 GB/s 不是瓶颈）·（C）其它（H2C 邮箱 / BRAM 段变体 / XVC 排除） | §2 |
| 4 | **推荐 M1（阶段一）= (B)**：全部长在**已板级验证过**的 AXI-Lite 观测路径上、无新协议状态机、回退只需一次重烧；**(A) 作为阶段二**，同一个 tap 只换搬运侧 | §2.1 / §2.2 |
| 5 | 小功能 = **"TCP 载荷镜像窗"**：对端按图案发 TCP（`p7b_tcp_src` 已存在）→ 板上 **tap `app_rx_*`**（app 实际收到的 TCP 载荷，dp 域）→ **逐字节变换 XOR 0xA5** → 异步 FIFO 跨到 PCIe 域 → 主机逐字读 → PC 程序落盘并与"图案的变换"**逐字节对账** + 四条计数对账 | §3 |
| 6 | ⚠️ **全链最慢的一环是 PCIe 搬运**（见 §2 的上界）⇒ 演示必须**给发端定速**（`--pace-bps`），否则镜像 FIFO 必溢出；"溢出 = 0"是判据的一部分 | §3.5/§3.6 |

---

## 1. 侦察（事实 + 出处）

### 1.1 PCIe 端点：怎么例化的

**① IP 的创建（构建脚本里）**——`board/build_p7b_ku5p.tcl:112-130`：

```tcl
112	# ---- XDMA (参数逐字复制 build_p6e_ku5p.tcl 那份已实测枚举通过的) --------------
113	sec "P7B_ADD_XDMA"
114	create_ip -name xdma -vendor xilinx.com -library ip -module_name xdma_0
115	set xip [get_ips xdma_0]
116	set_property -dict [list \
117	    CONFIG.pcie_blk_locn              {X0Y0} \
118	    CONFIG.pf0_device_id              {9034} \
119	    CONFIG.pf0_subsystem_id           {0007} \
120	    CONFIG.ref_clk_freq               {100_MHz} \
121	    CONFIG.mode_selection             {Basic} \
122	    CONFIG.axi_data_width             {128_bit} \
123	    CONFIG.num_queues                 {1} \
124	    CONFIG.axilite_master_en          {true} \
125	    CONFIG.axilite_master_scale       {Megabytes} \
126	    CONFIG.axilite_master_size        {1} \
127	    CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
128	    CONFIG.pl_link_cap_max_link_width {X4} \
129	] $xip
130	generate_target all $xip
```

**② 生成的 IP 真实参数（`.xci` 现读）**——`vivado_prj/p7b_ku5p_prj.srcs/sources_1/ip/xdma_0/xdma_0.xci`：

| 键 | 值 | 含义 |
|---|---|---|
| `"axilite_master_en": [ { "value": "true" ...` | true | user BAR（AXI4-Lite 主机）**开** |
| `"axilite_master_size": [ { "value": "1" ...` + `"axilite_master_scale": [ { "value": "Megabytes" ...` | 1 MB | user BAR 尺寸（板级实测吻合，见下） |
| `"xdma_axi_intf_mm": [ { "value": "AXI_Memory_Mapped" ...` | AXI-MM | **DMA 接口 = AXI 内存映射**（⇒ 没有 AXIS 通道） |
| `"xdma_rnum_chnl": [ { "value": "1" ...` / `"xdma_wnum_chnl": [ { "value": "1" ...` | 1 / 1 | **1 个读通道（C2H）+ 1 个写通道（H2C）** |
| `"xdma_en": [ { "value": "true" ...` | true | DMA 引擎本体**在**（不是被关掉） |
| `"enh_xdma_en": [ { "value": "false" ...` | false | 非 "增强模式"（无描述符旁路等） |
| `"pf0_bar0_enabled": [ { "value": "true" ...` / `"pf0_bar0_size": [ { "value": "128" ...` | 128 KB | BAR0（**注意**：物理映射以板级实测为准，见下） |
| `"pf0_bar1_enabled": [ { "value": "false" ...` | bar1 关 | `.xci` 里 BAR1 未声明可用（与板级 `2 BARs` 的解释见下） |
| `"pf0_msi_enabled": [ { "value": "true" ...` + `"pf0_msi_cap_multimsgcap": [ { "value": "1_vector" ...` | MSI 1 vector | 中断能力在（本设计 `usr_irq_req` 恒 0，未用） |
| `"xdma_num_usr_irq": [ { "value": "1" ...` | 1 | 用户中断 1 条 |

**③ 例化（`board/wrapper_p4.v`，PCIE_OBS 段内）**——关键三块，逐字：

```verilog
3979	    // ---- 4. XDMA (配置 = 厂商那份实测跑通的值的复制 + user BAR) ----
3980	    xdma_0 u_pcie_xdma (
3981	        .sys_clk        (pcie_clk),
3982	        .sys_clk_gt     (pcie_clk_gt),
3983	        .sys_rst_n      (reset_n),          // = 板上 PERST# (J9), 直连无反相器
...
3988	        .user_lnk_up    (pcie_lnk_up),
3989	        .axi_aclk       (pcie_axi_aclk),
3990	        .axi_aresetn    (pcie_axi_aresetn),
3991	        .usr_irq_req    (1'b0),
3992	        .usr_irq_ack    (pcie_irq_ack),
3993	        .msi_enable     (pcie_msi_enable),
3994	        .msi_vector_width(pcie_msi_vec_w),
3995	        // ---- DMA (m_axi) 通道本设计**不用**: 全回"永不应答" (只走寄存器窗口) ----
3996	        .m_axi_awready  (1'b0),
3997	        .m_axi_wready   (1'b0),
3998	        .m_axi_bid      (4'd0),
3999	        .m_axi_bresp    (2'd0),
4000	        .m_axi_bvalid   (1'b0),
4001	        .m_axi_arready  (1'b0),
4002	        .m_axi_rid      (4'd0),
4003	        .m_axi_rdata    (128'd0),
4004	        .m_axi_rresp    (2'd0),
4005	        .m_axi_rlast    (1'b0),
4006	        .m_axi_rvalid   (1'b0),
4007	        .m_axi_bready   (),          // 输出, 不用
4008	        .m_axi_awid     (), .m_axi_awaddr(), .m_axi_awlen(), .m_axi_awsize(),
...
4013	        .m_axi_arlock   (), .m_axi_arcache(), .m_axi_rready(),
4014	        // ---- user BAR (AXI4-Lite master) -> 我们的寄存器块 ----
4015	        .m_axil_awaddr  (pcie_awaddr), .m_axil_awprot (pcie_awprot),
...
4024	        .m_axil_rvalid  (pcie_rvalid), .m_axil_rready (pcie_rready),
4025	        // ---- 配置管理接口: 不实现 (输入 tie 0 / 输出悬空) ----
```

⇒ 三种接口各自的现状：**user BAR（AXI-Lite）= 在用**；**m_axi（DMA）= 被 tie-off**；**cfg_mgmt = 恒 0**。
⚠️ `m_axi_arready/awready` 恒 0 的语义 = 该 AXI 从机**永不应答** ⇒ 今天若主机从 `/dev/xdma0_c2h_0` 发起一次 DMA，**会挂在等完成**（不是"读回错误数据"）。**不要在现役位流上试 DMA**（登记为操作纪律）。

**④ user BAR → 寄存器块**——`board/wrapper_p4.v:4061-4063`：

```verilog
4061	    axi_regs #(
4062	        .MAGIC_V    (32'h50360001),
4063	        .BUILD_ID_V (32'h0000001C),     // ⚠️ 每次改动自增 (前置闸读这一项认位流; 构建 F = 0x1A)
```
（同文件 `:4249`：`.SNAP_NW (SNAP_NW_P6E)` —— 参数走单一来源。）

**⑤ BAR 布局（板级实测，权威）**——`_proj_10g/notes/P7B_PCIE_RESCAN_RECOVERY.md:154` 逐字：
> 之后烧上**我们的设计（2 BAR = BAR0 1M + BAR1 64K）**

同件 `:157-158` 现场读数逐字：
```
pci 0000:02:00.0: BAR 0 [mem 0xf7a00000-0xf7afffff]: assigned
pci 0000:02:00.0: BAR 1 [mem size 0x00010000]: can't assign; no space
```
⇒ **BAR0 = 1 MB = user BAR（`axi_regs`）**；**BAR1 = 64 KB = XDMA config BAR**；判别式 `identify_bars`（`:180-183`）：
> `1 BARs: config 0, user -1` = **厂商设计**（QSPI 启动）· `2 BARs: config 1, user 0` = **我们的设计**

**⑥ 时钟域与复位**：
- `pcie_axi_aclk ≈ 250 MHz`（XDMA 输出）。证据两处：`_proj_10g/notes/p7b_buildF_build/READINGS.txt:115` 逐字 ``Source: u_pcie_xdma/inst/pcie4_ip_i/inst/user_reset_reg/C (FDPE, pcie_axi_aclk 250MHz)``；`_proj_pcie/README.md` 板级实测 `FREECNT` 反解 ≈250 MHz（`Δ=77858253 / 0.3s`，"实测 259.5，误差来自 `sleep 0.3` 不准"）。
- `reset_n` = **PCIe 槽的 PERST#（J9）**，也直接喂 `xdma.sys_rst_n`——`board/wrapper_p4.v:190-191` 逐字：
  > `//   ⚠️ 复位**不另开端口**: 本板 reset_n 就接在 PCIe 槽的 PERST# (J9) 上 (见 ku5p_p6a_*.xdc),`
  > `//      与 xdma.sys_rst_n 是同一个物理信号 —— 厂商 BD 也是这么接的 (pcieReset → sys_rst_n)。`
- 参考钟引脚/约束：`board/ku5p_p6e_pcie.xdc:14` `create_clock -period 10.000 -name pcie_ref_clk [get_ports pcie_sys_clk_p]`（AB7/AB6 = 金手指 100 MHz）。
- **跨域声明已经就位**：`board/ku5p_p7b_cdc.xdc:36-39` 逐字
  ```tcl
  set_clock_groups -asynchronous \
      -group [get_clocks -include_generated_clocks sys_clk_100] \
      -group [get_clocks -include_generated_clocks pcie_axi_aclk] \
      -group [get_clocks -include_generated_clocks gtrefclk0]
  ```
  ⇒ `dp_clk`（`sys_clk_100` 经 MMCM 的生成钟）与 `pcie_axi_aclk` **已经是异步组** ⇒ **新增一条 dp↔pcie 的异步 FIFO 不需要改 XDC**。
  ⚠️ 同文件 `:7` 的纪律：`set_clock_groups` 失效的症状 = 构建日志 `12-4739`（该文件必须由构建脚本标 `used_in_synthesis false`，`board/build_p7b_ku5p.tcl:138` 逐字 `set_property used_in_synthesis false [get_files ${script_dir}/ku5p_p7b_cdc.xdc]`）。

### 1.2 user BAR 上的寄存器块（`_proj_pcie/rtl/axi_regs.v`）

**地址表（读）**——文件头注释 `:9-43` 与读 mux `:280-293` 现读，**现役 = 70 字快照**（W0..W69，`board/wrapper_p4.v:3241` `localparam SNAP_NW_P6E = 70;`）：

| 地址 | 属性 | 内容 | 现读行 |
|---|---|---|---|
| `0x00` | RO | `MAGIC` = `0x50360001` | `:281` |
| `0x04` | RO | `BUILD_ID`（前置闸读它认位流） | `:282` |
| `0x08` | RW | `SCRATCH`（**同时**是 SFP TX_DIS 门：`wrapper_p4.v:4053` `assign sfp1_tx_dis = pcie_scratch[0];`） | `:283` |
| `0x0C` | RO | `FREECNT`（axi 域自由计数 ⇒ 反解 AXI 频率/活体） | `:284` |
| `0x10` | RO | `HW_STATUS` = `{24'd0, msi_vec_w, msi_enable, lnk_up, 3'd0}` | `:285` / `wrapper_p4.v:4039` |
| `0x14` | RO | `MARKER` = `0xDEADBEEF` | `:286` |
| `0x18` | WO | `SNAP_CTRL`：写 `bit0=1` ⇒ 触发一次快照（读回 0） | `:287` |
| `0x1C` | RO | `SNAP_STATUS` = `{gen[31:16], 9'd0, locked_axi, fe_state[2:0], seen, done, busy}` | `:275-276` |
| `0x20..0x134` | RO | 快照字 W0..W69（地址 = `0x20 + 4*W`） | `:291-292` |
| `0x138` | — | **未实现**（= `0x20+4*70` = word 78）⇒ 读回 `0xffffffff`（SLVERR） | `:308-309` |

**写通道白名单**——`:174-184` 逐字：
```verilog
174	                if (w_word == 7'd2) begin                       // 0x08 SCRATCH (RW)
180	                end else if (w_word == 7'd6) begin               // 0x18 SNAP_CTRL (写侧触发)
182	                end else begin                                   // 其余地址: 非法写
183	                    s_axil_bresp <= 2'b10;                       // SLVERR
```
⇒ **今天主机只能写 `0x08` 与 `0x18`**；任何"主机 → 板"的新控制字都必须**新开写 case**。

**译码与边界（扩窗纪律）**——`:155/196/237/270` 逐字：`wire [6:0] w_word = awaddr_r[8:2];` · `wire [6:0] ar_word = s_axil_araddr[8:2];` · `wire [6:0] snap_idx = r_word[6:0] - SNAP_W0_IDX[6:0];` · `wire [11:0] snap_base = {snap_idx, 5'b0};`
- 7 位字译码 ⇒ **地址 ≥ `0x200` 回绕到 word 0 = MAGIC**（`:65` 的原话："挪的时候**绝不能挑 ≥0x200**"）。
- 硬上限 = **119 字**（`:93-96`：字 8..126；负对照要留 1 个空字）。
- 读通道是**单笔串行**：`:302-314`（arready 接受地址 → 下一拍 `rdata_mux` 落寄存器 + rvalid 保持到 rready 才回 arready）⇒ **天然不支持多笔 outstanding**（这直接决定 §2.1 的带宽上界）。
- 扩窗要**七处同改**（`board/wrapper_p4.v:3155-3169` 有清单）；**读侧另有工程惯例**："未实现地址"取值必须跟着挪 —— 且 2026-10-10 的读侧加固轮已把它变成**20 文件 / 56 处**的机械同步（`udp_hls_10g/CLAUDE.md` 构建 F 块 ⑦）。**本设计的任何"窗口几何改动"都要过这一关**。

### 1.3 载荷 tap 点（板上"载荷字节流"在哪一拍有效）

**TCP 链（现役）**：`mac_rx_10g → rx_classify → tcp_rx → tcp_echo → axis_pipe → app_rx_*`（= `eco2_*`）。
逐段行号（全部 dp_clk 域，`board/wrapper_p4.v`）：

- `tcp_rx` 的载荷输出（带 meta 边带）`u_tcp_rx`（`:1807` 起）：
  ```verilog
  1831	        .m_axis_tdata   (pay_tdata),
  1832	        .m_axis_tkeep   (pay_tkeep),
  1833	        .m_axis_tvalid  (pay_tvalid),
  1834	        .m_axis_tready  (pay_tready),
  1835	        .m_axis_tlast   (pay_tlast),
  1836	        .m_axis_tuser   (pay_tuser),
  1837	        .fend           (pay_fend),
  1838	        .ferr           (pay_ferr),
  1839	        .meta_valid     (pay_meta_valid),
  1842	        .meta_len       (pay_meta_len),
  1843	        .meta_conn_id   (pay_meta_conn_id),
  1844	        .meta_seq       (pay_meta_seq),
  ```
  ⚠️ 这里是**帧级**载荷（含 `meta_len`=段长、`meta_seq`），**不是** app 看到的那条流。
- **`tcp_echo`（零拷贝缓冲）**（`:1910` 起）：`s_axis_*` 接管 `pay_*`，`m_axis_*` 出 `eco_*`（`:1924-1929`）。
- **`axis_pipe` 1-deep 全速寄存器**（`:1945-1954`）——**这就是 app RX 的最终源头**：
  ```verilog
  1945	    axis_pipe #(.W(77)) u_eco_pipe (
  1946	        .clk            (dp_clk),
  1948	        .s_data         ({eco_tkeep, eco_tlast, eco_tdata, eco_tid}),
  1951	        .m_data         (eco2_pack),
  1952	        .m_valid        (eco2_tvalid),
  1953	        .m_ready        (eco2_tready)
  ```
- **app RX 别名 + app 消费口**（`:1079-1085`，`ifdef APP_MODE` 内）：
  ```verilog
  1079	    wire [63:0] app_rx_tdata  = eco2_tdata;
  1080	    wire [7:0]  app_rx_tkeep  = eco2_tkeep;
  1081	    wire        app_rx_tvalid = eco2_tvalid;
  1082	    wire        app_rx_tready;
  1083	    wire        app_rx_tlast  = eco2_tlast;
  1084	    wire [3:0]  app_rx_tid    = eco2_tid;
  1085	    assign eco2_tready = app_rx_tready;
  ```
  以及 `app_pattern` 例化点（`:1223-1228`，`u_app`，clk = `dp_clk`，`:1209`）：
  ```verilog
  1223	        .rx_tdata       (app_rx_tdata),
  1224	        .rx_tkeep       (app_rx_tkeep),
  1225	        .rx_tvalid      (app_rx_tvalid),
  1226	        .rx_tready      (app_rx_tready),
  1227	        .rx_tlast       (app_rx_tlast),
  1228	        .rx_tid         (app_rx_tid),
  ```
  **接口合同**（转写自 `rtl/app_pattern.v:19-21` 头注释，逐字要点）：
  > `RX: tcp_echo (零拷贝缓冲) 输出 -> 逐字节比对; 1 拍吞 1 字, 之后按字节比对`

  ⇒ **一拍一个字（64 位）+ `tkeep` 指出哪几字节有效 + `tlast` 指段尾 + `tid` = 连接号**；**没有 len 字段**（长度 = Σpopcount(keep)，或由段边界推定）。**载荷字节数 = 各拍 popcount(tkeep) 之和**。
- **同一流的板侧 oracle（已存在）**：`app_pattern.stat_rx_bytes` → 快照 **W53**（`0x20+4*53 = 0xF4`，`_proj_10g/notes/P7B_BIZ_WINDOW.md` §1）；`stat_mismatch` → **W54**（`0xF8`）。⇒ 镜像功能的字节账**天生有第二条板内口径可以对照**（⚠️ 同源、非独立证据，见全局 #39 精神）。

**UDP 链（备选，同为 dp_clk）**：
- `udp_split` app 口（`:2334-2342`）：
  ```verilog
  2334	        .app_rx_tdata   (app_udp_rx_tdata),
  2335	        .app_rx_tkeep   (app_udp_rx_tkeep),
  2336	        .app_rx_tvalid  (app_udp_rx_tvalid),
  2337	        .app_rx_tready  (app_udp_rx_tready),  // ← app_udp_pattern 的校验器
  2338	        .app_rx_tlast   (app_udp_rx_tlast),
  2339	        .app_rx_sof     (app_udp_rx_sof),
  2340	        .app_rx_len     (app_udp_rx_len),
  ```
  ⇒ **比 TCP 侧多 `sof` / `len` 边带**（数据报边界显式可见）。
- 消费侧 = `app_udp_pattern`（`:2575-2592`，clk = `dp_clk`）。⚠️ 该口真反压（`:2300-2302` 注释逐字："它是**真反压** (每字 8 拍)"）—— 但那是**既有 app** 的行为，与"加一条 snoop"无关（见 §2.0）。

**8 路并行（速度相关）**：`rtl/app_pattern.v` 在 `` `ifdef P7B_10G `` 下有 8 路展开（`xs_next8`，M^8 常量 XOR 网，`:103-115` 起）——**TCP app 的 TX 与 RX 校验器都走它**。（派单里"（UDP，8 路并行）"是 **RATE 轮**的结论；Stage B（R1）之后 TCP app 的 RX 校验器也已是 8 路 —— 出处 = Stage B 各件 + `P7B_GAP9_TCPAPP_8WAY_DESIGN.md`。）1G 默认构建仍是 1 B/拍路径。

### 1.4 对端侧（`192.168.0.38`）：驱动 / 节点 / 工具 / 链路

| 项 | 事实 | 出处 / 强度 |
|---|---|---|
| 驱动 | **out-of-tree `xdma v2025.2.0`**（不是 in-tree DMAEngine 版）；`insmod` 绝对路径 | `_pcie/README.md:12`（厂商位流上实测）+ `:63` |
| 工具 | `/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools/`：`reg_rw` / `dma_to_device` / `dma_from_device` | `_pcie/README.md:54,72-77` |
| 厂商位流下的节点 | **19 个**：`xdma0_control` / `h2c_0` / `c2h_0` / `events_0..15`（`crw------- root root` ⇒ **要 root**） | `_pcie/README.md:15` |
| **我们位流下的节点** | **已核**：`/dev/xdma0_user` 存在且可用（`reg_rw /dev/xdma0_user ...` 全仓多处）。**`/dev/xdma0_c2h_0` / `h2c_0` 是否也存在 = 未现核**（推断：存在 —— 同一 IP 配置、同样的引擎寄存器 ⇒ 驱动照建；⚠️ **必须在板上 `ls /dev/xdma*` 现核**，见 §4-①） | `_proj_10g/notes/P7B_PCIE_RESCAN_RECOVERY.md:95-96` 等 |
| C2H 是否可跑 | **今天不行**（`m_axi` 永不应答 ⇒ 挂等）—— 这不是"节点不存在"，是"引擎没有从机" | `board/wrapper_p4.v:3995-4013` |
| 链路 | 设备 `02:00.0` `10ee:9034`；**`LnkSta: Speed 5GT/s (downgraded), Width x4` = PCIe 2.0 x4**（根端口 Z87 封顶；端点 `max=8.0GT/s`） | `_pcie/README.md:11` + 多轮板级身份（如 `P7B_BOARD_STAGEB.md:60`） |
| 链路带宽口径 | 5 GT/s × 4 lane × 8b/10b = **2.0 GB/s raw**；历史实测（**厂商位流 + 单发工具**）：H2C ≤804 MB/s、C2H ≤257 MB/s，且原件明说"C2H 的真实上限没被测到"、"**不要把 257 MB/s 当成板子能力**" | `_pcie/README.md:19,32-42` |
| 先例警告 | 同件 `:39-42` 逐字："板子在**芯片组槽 2.0 x4 = 2.0 GB/s 理论**，而 10G 线速是 **1.25 GB/s** ⇒ **只有 1.6× 余量**，扣掉协议开销与上述工具损失后**不适合当 10G 速率的采集通道**；它适合当**寄存器/状态/低频数据**通道。" | 同上 |
| 网络前置（每次现取） | `ip addr add 192.168.100.100/32 dev enp1s0f1np1` + `ip route add 192.168.100.2/32 ...` + **`nmcli device set enp1s0f1np1 managed no`**（NetworkManager 会静默冲掉 `/32`） | `_proj_10g/notes/P7B_LONGSEND_HANDOFF.md:69-71` |
| ⚠️ 读数纪律 | 主机的读**必须**是"Bar 值 + `LnkSta`"为准；`0xffffffff` 与"端点不存在"在读数上不可区分 | `P7B_PCIE_RESCAN_RECOVERY.md:79-80` |

### 1.5 换位流与 PCIe 端点的存亡（**scenario 分类 + 恢复配方，已有既定件**）

三场景（`P7B_PCIE_RESCAN_RECOVERY.md:24-28` 现读）：

| 场景 | 主机 POST 时 FPGA 跑的是 | 后果 / 恢复 |
|---|---|---|
| **A** | **无 PCIe 的设计** | 根端口从未见过端点 ⇒ `LnkSta Width x0` ⇒ 只有**重启**（四种主机侧手段实测全无效） |
| **B（日常）** | 带 PCIe 的设计（POST 已枚举） | 之后重烧**任意**带 PCIe 的位流 ⇒ 链路保持 up、主机 config 空间陈旧 ⇒ **设备级 `remove`+`rescan` 即恢复（≈5 s）** |
| **C** | QSPI 厂商设计（POST 枚举到**1 个 BAR** ⇒ 父桥窗按 1 M 定死） | 烧上我们的（2 BAR）⇒ **设备级不够**（`BAR 1 [size 0x00010000]: can't assign; no space`）⇒ **连根端口 `0000:00:1c.0` 一起 `remove`+`rescan`**（窗重算 2 M）；**同一会话内后续重烧回设备级**（`:171` 逐字） |

配方（`:57-65` 逐字）：
```bash
sudo reg_rw /dev/xdma0_user 0x00 w        # ① 判死（重烧后应读 0xffffffff）
sudo bash -c 'echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove; sleep 2; echo 1 > /sys/bus/pci/rescan; sleep 3'
sudo reg_rw /dev/xdma0_user 0x00 w        # ③ 判活（应回 0x50360001）
```
⚠️ 判别式分工（`:183-184`）：`LnkSta` 管"有没有救"（`x0` 没救 / `x4` 有救）；`identify_bars` 管"板上跑的是谁"。
⚠️ 判活**不要用 Windows `ping` 退出码**（`:73-78`：收到本机自产的"无法访问目标主机"时**仍 `exit 0`**）；用 TCP connect 到 `:22`/`:3121`。

**对本设计的含义**：M1/(A)/(B) 都不改 POST 语义（端点仍是同一个 XDMA）⇒ **场景 B 的日常配方不变**；但每次新位流上板后必须重走：重烧 → `remove`+`rescan` → `0x00` 判活 → `0x04` 核 BID → 读窗口。
**构建/烧录只走**：`board/run_build_p7b_ku5p.bat` + `_proj_10g/notes/p7b_biz_tcpreg/run_program_tcpreg.bat`（`P7B_LONGSEND_HANDOFF.md:110-111`）；⛔ **GUI 重编本树 `vivado_prj` 会踩"永久禁发"陷阱**（`:111` 逐字）。

### 1.6 现有 sim / 门基础设施（对新增通路的直接影响）

- **有一个"仅仿真用"的 XDMA 替身**：`sim/p6e_pcie/xdma_0_sim_stub.v`（196 行，模块名**故意就叫 `xdma_0`**）。它：
  - 产生 `axi_aclk`(250MHz)/`axi_aresetn`/`user_lnk_up`/`msi_*`；
  - 实现**最小 AXI4-Lite 主机**，以**层次任务**暴露给 TB：`:14-16` 逐字 `u_dut.u_pcie_xdma.axil_read (addr, data);` / `axil_write(addr, data);`
  - `m_axi` 端口**同名同位宽但"替身不驱动"**（`:31-32` 逐字 `// ---- m_axi (本设计不用; 与真 IP 同名同位宽, 替身不驱动) ----`）。
- ⇒ **对 (B) 有利**：新窗口字可以直接用现有 `axil_read` 任务在 wrapper 全链门上判（门基建零新增）。
- ⇒ **对 (A) 是成本**：stub **不建模 DMA 读主机** ⇒ 要一个"wrapper 级全链门"就得**扩 stub**（新增一个 AXI-MM 读主模型，或至少一个能发 AR/R 激励的替身）；否则 (A) 只能靠**单元门 + 板级**两级（项目纪律要求"每个 ifdef 配置有一个例化真 wrapper 的全链门"—— 见 `udp_hls_10g/CLAUDE.md` 坑 8）。
- 门运行入口：`sim/p4gates/run_matrix_p4dfix.bat`（自定位）。⚠️ **常驻矩阵的编译清单不含 `app_pattern.v`/`wrapper_p4.v`**（既知空证据，`P7B_OPEN_ITEMS.md` §0-19）⇒ 新模块必须**显式加进相关门的文件表**，否则"跑过了"是空证据。

### 1.7 ⚠️ 与派单描述不符 / 需订正之处（逐条，附出处）

| # | 派单说 | 现核事实 | 影响 |
|---|---|---|---|
| ① | "（a）复用或新开 XDMA 的 **C2H AXI-ST** 数据通道" | **没有 AXI-ST 通道**：`xdma_axi_intf_mm = AXI_Memory_Mapped`（`.xci` 现读）；`.veo` 端口表里只有 `m_axi_*`（128 位，`araddr[63:0]`）与 `m_axil_*`，**无 `m_axis_h2c_*` / `s_axis_c2h_*`** | (A) 的机制改为"**AXI-MM 读通道 + 我们写一个 AXI-MM 读从机**"；其余评估（IP 不用重生成 / BAR 不动）**成立且更强** |
| ② | "10G 前端 = 官方 `xxv_ethernet` + 自写 XGMII MAC（`_proj_10g/p7b_mac/rtl/`）" | ✓ 现核一致（`board/build_p7b_ku5p.tcl:45-59, 99-100`） | — |
| ③ | "app 侧 = `app_pattern.v`（TCP）/ `app_udp_pattern.v`（UDP，**8 路并行**）" | **过时**：`app_pattern.v` 在 `` `ifdef P7B_10G `` 下**也有** 8 路展开（`xs_next8`，`:103-115` 起；TX 与 RX 校验器都走它）——这是 Stage B（R1）之后的现状 | 引用速率天花板时必须写清"哪一代"（§3.6 有口径） |
| ④ | "70 字快照窗口" | ✓ 现核 `board/wrapper_p4.v:3241` `localparam SNAP_NW_P6E = 70;`（未实现地址 `0x138`）。⚠️ 但**本日工作树已有 BID `0x1C` 的 WIP**（`:4063`），且历史上窗口逐代只增不减 | 实施时**重核** NW/BID/未实现地址三件套 |
| ⑤ | "对端已加载 xdma 驱动、有 `/dev/xdma*` 节点" | ✓（`/dev/xdma0_user` 多轮实测）。⚠️ **但 `c2h_0`/`h2c_0` 在我们位流下是否存在 = 未现核**（厂商位流下存在，19 节点清单里含它们） | (A) 的**第一件事**就是板上 `ls /dev/xdma*` 现核（§4-①） |
| ⑥ | "现役设计的 PCIe 端点已有 user BAR" | ✓ 且更强：**BAR0 = 1 MB user / BAR1 = 64 KB config**，判别式 `2 BARs: config 1, user 0` | — |
| ⑦ | "板子上 TCP 栈 = `rtl/tcp_rx.v` + `rtl/tcp_tx_frame.v` + `rtl/app_ctrl.v`" | ✓ 但这三者**不是** app 看到的载荷流：中间还有 `tcp_echo`（零拷贝缓冲）+ `axis_pipe`（1-deep），app 的 RX 口 = `eco2`/`app_rx_*`（§1.3） | tap 点的选择按 §1.3，别接在 `tcp_rx` 的 `pay_*` 上（那是帧级+meta，语义不同） |

---

## 2. 设计：三条候选通道

### 2.0 共同前提（三条路共用，先钉死）

- **tap 语义**：`app_rx_*`（TCP）或 `app_udp_rx_*`（UDP），dp_clk 域，**snoop 式**（只采集 `tvalid && tready` 的拍，**不改** valid/ready/数据 ⇒ 对既有数据面逐位零影响）。
- **"处理"**：逐字节变换 `b' = b XOR 0xA5`（8 个异或/拍；可逆、可逐字节判、零表项零 BRAM）。变换放在 tap 之后、FIFO 之前（dp 域，纯组合，打一拍即可）。
- **长度语义**：TCP = 字节流（段边界只作诊断）；UDP = 数据报（可带上 `sof/len`）。M1 选 TCP。
- **溢出语义**：FIFO 满 ⇒ **拒写 + 按字节计数（W 新字）+ 单 bit sticky 进窗口**；**不静默丢**（本工程一贯口径："恒 0 才叫无丢字"）。
- **时钟域**：dp 156.25 MHz → pcie_axi_aclk ≈250 MHz。**现成件 = `rtl/fifo_async.v`**（灰码 + 2FF，参数 `WIDTH/DEPTH/FWFT/AW`；板级已在 `u_rxcdc`/`u_txcdc` 上验证跑通）。
  例化样板逐字（`board/wrapper_p4.v:2770-2778`）：
  ```verilog
  2770	    fifo_async #(.WIDTH(73), .DEPTH(256), .FWFT(1), .AW(8)) u_txcdc (
  2771	        .wr_clk(dp_clk),   .wr_rst_n(reset_n), .wr_en(txsrc_tvalid),
  ...
  2773	        .rd_clk(tx_fe_clk), .rd_rst_n(reset_n), .rd_en(m_tx_tvalid && m_tx_tready),
  ...
  2777	        .ovf_cnt(txcdc_ovf_cnt)
  ```
  ⚠️ **复位硬规则**（`board/wrapper_p4.v:685-687` 逐字）：
  > `//   ⚠️ **FIFO 的两侧复位绝不接 dp_rst_n**: 硬规则见 P6B_SPEC §4.4 —— 两个指针必须在`
  > `//      "同一代"上复位, 所以 u_rxcdc/u_txcdc 的 wr_rst_n/rd_rst_n **都接板级 reset_n**。`
  ⇒ 新 FIFO **两侧都接 `reset_n`**（而 `reset_n` 就是 PCIe 的 PERST# ⇒ 两侧同源，`pcie` 域那侧天然对齐）。

### 2.1 候选 (B)：user BAR 搬运窗（**推荐的阶段一**）

**机制**：新 tap 模块把变换后的载荷压成 **32 位字**（4 字节/字）写入 `fifo_async`；跨到 pcie 域后，主机**每读一次 `MIR_DATA` 弹出一个 32 位字**。状态字给出"当前可读字数（level）"与 sticky 标志。**不做主机→板控制**（M1 的 tap 常开；"清零/使能"留作可选，见下）。

**改动面**：
1. **新文件** `rtl/app_rx_mirror.v`（~120 行）：tap + XOR + 字节压缩（{64 数据, 8 keep} → 32 位字节流）+ FIFO 写口 + 溢出字节计数。
2. `board/wrapper_p4.v`：`ifdef APP_MODE` + `ifdef PCIE_OBS` 内的**例化 + 接线**（1 处）；新 FIFO 实例（1 处，照 `u_txcdc` 样板）；`axi_regs` 新端口接线。
3. `_proj_pcie/rtl/axi_regs.v`：**读 mux 加 2 个地址**（`MIR_STATUS` / `MIR_DATA`，含"读=弹出"的副作用）+ **SLVERR 边界前移**；**写通道不动**（M1 无主机写）。
4. **快照**：+1 字（W70 = `mir_drop_bytes`，dp 域）⇒ 触发 §1.2 的"扩窗七处 + 读侧 20 文件/56 处"同步；**未实现地址从 `0x138` 挪到新窗口末尾之后**。
5. 构建脚本 `board/build_p7b_ku5p.tcl` 的 import 清单 +1 行（`:84-94` 那段）；各 lint / 门文件表（§1.6）。
6. 新单元门 TB（`tb_app_rx_mirror.v`）+ wrapper 级门（用现有 `axil_read/axil_write` 任务**直接可做**，§1.6）。

**带宽上界（算清）**：
- 速率 = 4 B / T_read。`T_read` 的构成：
  - AXI 域内部：单笔串行（`axi_regs.v:302-314`）≈ 3–4 拍 @250 MHz ≈ **12–16 ns**；
  - PCIe 往返：32 位 MRd → CplD，经芯片组根端口，**典型 0.2–0.6 µs 量级**（⚠️ **本机未实测**）；
  - 主机软件：取决于读法 —— ① **进程级 `reg_rw`**（现役取数器 `_proj_pcie/p7b_biz/p7b_snap.sh` 的 `rd(){ $T/reg_rw $D "$1" w ... }` 每字起一个进程）⇒ **ms 量级/字 ⇒ ~10³ B/s**；② 用户态紧循环（mmap 或反复 pread；**该驱动是否支持 mmap = 未核**）⇒ 由往返主导。
- ⇒ **上界口径**：`4 B / T_read`；**若 T_read ≈ 0.4–1 µs ⇒ ≈ 4–10 MB/s 量级**（**未实测**；进程级读法低三个数量级）。**对 10G 载荷（TCP 线速载荷 1.19 GB/s）结构性不够**；够"1–10 MB 级演示数据（秒级）"。
- 附：写方向是 posted，将来若加"主机→板"控制字，速率语义不同（但那不是数据面）。

**对现有功能的风险**：
- ⚠️ **最大的一条是流程性的**：窗口几何一动 ⇒ **读侧 20 文件 / 56 处**必须同步，且**负对照地址**要跟着挪（漏了 = 判据假红/假绿，本工程有多次前科）。
- 时序：dp 域新逻辑很小（XOR + FIFO 写口）；F 构建的 DP 域 setup WNS = **+0.281**（`p7b_buildF_build/READINGS.txt` 逐字 `g.hw.clk_out0  0.281  0.000  0  138839`）；**真正要盯的是 pcie 域的异步复位 Recovery 族** —— 现役**全局 WNS `+0.111` 就是它**（同件逐字：`Destination: u_pcie_regs/snap_words_r_reg[1797]/CLR`，共享复位网 `u_pcie_regs/bbstub_axi_aresetn (fo=5392)`）⇒ **新增 pcie 域带异步复位的 FF 会给这条网加负载**（不预言好坏，但**构建后必须现核该族**）。
- snoop 零侵入：valid/ready 不动 ⇒ 既有门（`p5_wrapper` 等）语义不变；但仍按纪律**跑一次 wrapper 级门**。

**回退方式**：`axi_regs` + wrapper 的新增段全部包在 `` `ifdef PCIE_OBS `` 内 ⇒ 不定义即回旧行为；位流层面 = **重烧上一版位流**（归档 + sha256 纪律）。**注意**：`PCIE_OBS` 与 `APP_MODE` 是两个独立宏（既有"潜伏设计债"），新段应**同时**包在两个宏内（缺一即编译不过或语义残缺）。

**可判定的验证判据（设计）**：
1. **身份**：`0x00=0x50360001` · `0x04=新 BID` · 窗口 = 新字数 · **新未实现地址回 `0xffffffff`** · `LnkSta x4`。
2. **静态可读性**：读 `MIR_STATUS` 两次，`level` 单调不减（有流量时）；无流量时 `level=0`。
3. **逐字节**（§3.6）：PC 文件 == 图案的变换（K 字节，`drop=0`）。
4. **计数对账**：`PC 字节 + W70 == ΔW53`（同源，登记为"一致性检查"而非独立证据）。
5. **负对照**：`app_rx_*` 无流量（peer 不发）⇒ 读 DATA 得**下溢哨兵值**且下溢计数 +1（"不该读到数据时读不到"）。

### 2.2 候选 (A)：C2H DMA（AXI-MM 读通道）—— **推荐的阶段二 / 高吞吐路**

**机制**：tap 的字节流写进**板载环形缓冲**（BRAM，真双口：写口 @dp_clk、读口 @pcie_axi_aclk ⇒ **载荷路径不需要 CDC**），新写一个 **AXI-MM 只读从机**挂在 `xdma_0.m_axi` 的**读通道**上；主机用 `/dev/xdma0_c2h_0` + `dma_from_device`（或自写 C）把块搬到主机内存。块级握手（ready/release）避免跨域多比特指针。

**改动面**：
1. 新文件 `rtl/aximm_c2h_win.v`（AXI-MM 读从机：AR/R、4 位 `id` 回填、INCR、`RLAST`、4 KB 边界安全、**永远应答**）+ `rtl/mir_ring.v`（BRAM 环 / 块状态）。
2. `board/wrapper_p4.v`：把 `:3996-4013` 的 `m_axi` **读侧**改接从机（写侧可保持 tie-off —— 两个方向是独立 AXI 通道；**但"只接读侧"这个简化必须先核**，见 §4-⑤）。
3. `axi_regs`：新增"块状态/计数"字（可复用快照机制）。
4. 主机侧：`dma_from_device` 现成（`_pcie/README.md:77` 有用法逐字），但要一个**轮询块状态 → DMA → release** 的小程序才能持续搬。
5. 构建 import 清单 + lint 门 + **stub 扩 DMA 读主模型**（若要做 wrapper 级门，§1.6）。

**带宽上界（算清）**：
- 链路：Gen2 x4 = 5 GT/s × 4 × 8/10 = **2.0 GB/s raw**；TLP/DLLP 开销（含 4 KB 边界、ACK/FC）后按 80–90% 估 ⇒ **1.6–1.8 GB/s 级**（⚠️ **未实测**）。
- 板内：`m_axi` 128 位 @250 MHz = **4 GB/s**、BRAM 读口同域 ⇒ **都不是瓶颈**。
- 历史读数（**只能当下界/形态**）：厂商位流 + 单发工具 C2H 257 MB/s / H2C 804 MB/s；原件明说"C2H 的真实上限没被测到"（`_pcie/README.md:36-38`）。
- ⇒ 上界口径 = **链路级 ~1.7 GB/s（未实测）**；**与 10G 载荷（1.19 GB/s）余量 ~1.4×** ⇒ 按既有警告（`:39-42`），**本里程碑把它当"高吞吐搬运通道"，不当"10G 采集通道"**。

**对现有功能的风险**：
- **DMA 一旦被主机触发就会真的做 AXI 事务** ⇒ 从机必须**永远应答**（否则挂死引擎/驱动；今天 tie-off 态**不会**被触发，改成会应答之后**多了一条真实流量源**）。
- pcie 域时序：m_axi 路径是**新增长组合路径**（现役该域只有 AXI-Lite + 快照阵列），必须靠一次构建收口（⚠️ 不许写"时序没问题"——只写"构建后核 WNS 与失败端点"）。
- IP **不用重生成** ⇒ `.xci` 不变 ⇒ 身份链少一个变量；反过来，**将来若真要 AXIS/多通道才需重生成**（代价 = OOC 重综合 + `.xci` 与归档件分叉）。
- 许可：`xdma` 是**随 Vivado 自带**的 IP（厂商设计与我们多版位流都成功出过）⇒ **无许可缺口**（⚠️ 本机未逐字核 xdma 的 license 键 —— 登记为"未核但有多次成功构建的事实"）。
- 仿真门基建缺口（§1.6）：stub 不建模 DMA ⇒ 全链门要么扩 stub，要么降级为"单元门 + 板级"。

**回退**：把 `m_axi` 读侧接线**退回 tie-off** 并重烧（可保留 (B) 的窗口路径不动）；或直接烧回旧位流。

**可判定的验证判据（设计）**：
1. 单元门：从机对 AR/R 的协议判据（ID 回填、RLAST、4 KB 跨界、乱序 AR?、**永不应答的反例**）。
2. 板级：`ls /dev/xdma*` 现核节点 → 单向读一**已知图案块**（板上预置或经 UDP/TCP 灌）→ `cmp` 逐字节。
3. 对照臂：同一块数据分别走 (B) 与 (A) 两条路 ⇒ 内容应逐字节相同（**同一 tap，两条搬运**）。
4. 速率口径：带 `PIN_CPU=` 见证（全局 #62）与"块大小/提交深度"记录；⚠️ **不许把单发工具读数当板子上限**。

### 2.3 候选 (C)：其它可行路

- **C-1：H2C 邮箱（host → card）**——`m_axi` **写**通道接一个 AXI-MM 只写从机 → BRAM mailbox。用途：主机灌配置/图案/命令（"功能齐备"的反向半环）。**与 (A) 同引擎、同风险等级**；本里程碑不推荐先做（单向需求已覆盖），登记备选。
- **C-2："AXI-MM 到 BRAM 段 + PC 读 BAR"**——注意：**这条与 (A) 的板内部分是同一件事**，(A) 已经是"AXI-MM 从机 + BRAM 段"；差别只在"谁搬"：DMA（= (A)）还是让主机经 AXI-Lite 窗口逐字读（= (B) 加 BRAM 存储，带宽与 (B) 同量级，**没有增益**）⇒ **不单列实施**，作为 (B) 的存储变体记录在案。
- **C-3：XVC**（JTAG over PCIe）——**排除**：它是调试通道不是载荷通道（且 `_pcie/README.md:20` 已实测厂商设计无 XVC；我们的设计**有** `/dev/xdma0_xvc`，`_proj_pcie/README.md` 记录，但与本目标无关）。
- **C-4：中断（MSI）驱动的搬运**——`usr_irq_req` 现恒 0（`board/wrapper_p4.v:3991`），IP 有 1 条用户中断（`.xci` `xdma_num_usr_irq=1`）。**登记为可选优化**：对 (A)/(B) 都只是"何时读"的通知机制，不改变搬运带宽；M1 用轮询（简单、可脚本化）。

### 2.4 三条路横向对比

| 维度 | (B) user BAR 搬运窗 | (A) C2H DMA | (C-1) H2C 邮箱 |
|---|---|---|---|
| 新增逻辑量 | **最小**（~120 行 + 2 个寄存器读口） | 中（AXI-MM 从机 + BRAM 环 + 块协议） | 中（AXI-MM 写从机） |
| 带宽上界（口径见上） | ~**4–10 MB/s** 量级（往返主导，未实测） | ~**1.7 GB/s** 级（链路级，未实测） | 同 (A) 量级 |
| 是否动 IP | 不动 | **不动**（引擎已在） | 不动 |
| 是否动 BAR | 不动（只用既有 1 MB BAR0） | 不动 | 不动 |
| 仿真门基建 | **现成**（stub 有 `axil_read/write`） | **缺**（stub 不建模 DMA） | 同 (A) |
| 主要风险 | 窗口几何同步（20 文件/56 处）+ pcie 复位 Recovery 族 | 从机协议/永应答 + pcie 域新组合路径 + 主机节点未核 | 同 (A) + 方向语义 |
| 回退成本 | 低（宏内 + 重烧旧位流） | 中（接线退回 + 重烧） | 同 (A) |
| 结论 | **阶段一（M1）** | **阶段二** | 备选 |

---

## 3. 推荐小功能 **M1 = "TCP 载荷镜像窗"**（阶段一 = 走 (B)）

### 3.1 数据流全图

```
[peer 192.168.0.38]                          [XCKU5P 板]                                    [peer 主机用户态]
 p7b_tcp_src（图案, --pace-bps）
    │ TCP :8080
    ▼
 SFP+ J8 ──► xxv_ethernet PCS/PMA ──► mac_rx_10g ──► rx_classify
                                                       │ fast
                                                       ▼
                                              tcp_rx ──► tcp_echo ──► axis_pipe
                                                                           │  eco2 / app_rx_*  (dp_clk, 64b + keep + last + tid)
                                                                           ├──────────────► app_pattern.rx_*（既有消费者，不动）
                                                                           └──► [新] app_rx_mirror
                                                                                    │ 逐字节 ^0xA5 + 压成 32 位字
                                                                                    ▼
                                                                        fifo_async（dp_clk → pcie_axi_aclk, 两侧 reset_n）
                                                                                    ▼
                                                                    axi_regs 新读口（MIR_DATA / MIR_STATUS, BAR0）
                                                                                    │ AXI4-Lite
                                                                    xdma_0 (user BAR) ──► 金手指 ──► 根端口
                                                                                                            │
                                                                                                            ▼
                                                                        /dev/xdma0_user (reg_rw / PC 程序轮询)
                                                                                    │
                                                                                    ▼
                                                                        mir_dump（C++）→ /tmp/mir.bin
                                                                                    │
                                                                                    ▼
                                                                        mir_check：逐字节 == pattern ^ 0xA5 + 计数对账
```

### 3.2 板上处理逻辑（放哪、做什么、怎么接）

- **新文件** `rtl/app_rx_mirror.v`；**例化位置**：`board/wrapper_p4.v` 的 `ifdef APP_MODE` 段内、`u_app` 例化（`:1195`）附近，**再包一层 `ifdef PCIE_OBS`**。
- **接口**（snoop，不改握手）：
  ```verilog
  app_rx_mirror u_mir (
      .clk(dp_clk), .rst_n(dp_rst_n),
      .s_tdata(app_rx_tdata), .s_tkeep(app_rx_tkeep), .s_tvalid(app_rx_tvalid),
      .s_tready(app_rx_tready), .s_tlast(app_rx_tlast),   // 只读采样：写使能 = tvalid && tready
      .drop_bytes(mir_drop_bytes),                        // dp 域计数 → 快照 W70
      .any_drop  (mir_any_drop),                          // 1 bit sticky → 2FF → MIR_STATUS
      // 到 FIFO 的写侧（在模块内或模块外例化 fifo_async，二选一，建议模块内）
      ...
  );
  ```
- **处理**：`data_out[i] = s_tdata[i] ^ 8'hA5`（所有有效字节都要变换；**keep=0 的拍不贡献字节**，但**仍要参与字节计数**）。
- **压缩**：把 {64 位数据, 8 位 keep} 压成 **32 位字**（4 字节/字，按字节顺序）。**跨段续用累加器**（不在 tlast 处 flush）⇒ 输出 = 纯字节流；末字可能含 1–3 个填充字节，**PC 侧按板侧字节账（W53）截断**。
  - ⚠️ 工程纪律相关：这里的"写门"必须用**下一拍空间（full_next 类）**而不是"本拍 full + 寄存器写"—— 本工程同类缺陷踩过两次（`app_udp_pattern` 每帧静默丢 8 B / 两个适配器 latent）⇒ **FIFO 写门是本模块的第一号判据**（宁可 `full` 保守浪费一个空位）。
- **溢出**：`full` 时拒写 ⇒ `drop_bytes += popcount(keep)`（**按字节计，与 PC 的字节账同量纲**）+ sticky 1 bit。
- **FIFO**：`fifo_async #(.WIDTH(32), .DEPTH(256), .FWFT(1), .AW(8))`，两侧复位**都接 `reset_n`**（§2.0 硬规则）。深度 256 字 = 1 KB 弹性（PC 的轮询间隔内不必丢）。
- ⚠️ **不要把 `app_rx_tready` 接进本模块的任何路径**（snoop 的意义就在此）。

### 3.3 PCIe 侧怎么送（窗口协议 · 建议值）

在 `_proj_pcie/rtl/axi_regs.v` 追加（**地址建议从快照末尾之后接续**；下例按"快照 70→71"写）：

| 地址 | 属性 | 建议内容 |
|---|---|---|
| `0x138`（word 70） | RO（快照新字 **W70**） | `mir_drop_bytes`（dp 域，写侧被拒的**字节数**；0 = 无丢字） |
| `0x13C`（word 71） | RO（新，pcie 域） | `MIR_STATUS` = `{15'd0, ver[3:0], any_drop_sticky, unf_sticky, capture_on, level[15:0]}`（位域自定，但**每个 bit 必须有定义**） |
| `0x140`（word 72） | RO，**读=弹出** | `MIR_DATA`：弹出一个 32 位载荷字（4 字节）。**下溢 = 返回哨兵常量 + `unf_sticky` 置位 + 计数**（⛔ 不许返回"看起来像数据"的值） |
| **未实现地址** | — | 现为 `0x138`（`_proj_10g/notes/P7B_BIZ_WINDOW.md` 更新块）⇒ **挪到 `0x144`**（word 73 = `0x20+4*73`） |

- **读=弹出的实现**：在 `:306-311` 那个"装载 rdata"的分支上挂 `rd_pop = (r_word == 7'd72)`（与装载同拍、每笔恰好一次）—— ⚠️ **弹出必须与"这一笔真的成功（rvalid→rready 完成）"绑定**：若主机中途 abort（读不到 CplD），AXI 层面仍是"完成了一笔"，会白弹一字；M1 用"先读 STATUS 拿 level、再读恰好 level 个 DATA"的协议 + `unf` 计数兜底（**登记这条语义**）。
- **写通道**：M1 **不加**（无主机→板控制）。若要"使能/清零"，最小实现 = `0x144` RW + **2FF 电平同步**（enable）/ **toggle 脉冲同步**（clear）—— ⚠️ 单 bit 电平用 2FF 是标准做法，但**必须在外壳层重新登记为"新的一条 pcie→dp 控制路径"**。
- ⚠️ **窗口几何改动连带**：（a）"扩窗七处"（`board/wrapper_p4.v:3155-3169` 清单）；（b）**读侧 20 文件 / 56 处**（`udp_hls_10g/CLAUDE.md` 构建 F 块 ⑦）；（c）**BID 必须 bump**（`wrapper_p4.v:4063` 的注释纪律逐字：`// ⚠️ 每次改动自增 (前置闸读这一项认位流; ...)`）。

### 3.4 PC 程序怎么读（`mir_dump.cpp`，对端机）

```
前提：root（/dev/xdma0_user 是 crw------- root root）
1) 打开 /dev/xdma0_user
2) 判活：读 0x00 == 0x50360001；读 0x04 == 预期 BID；否则响亮退出（exit≠0）
3) 循环：
     - level = read(MIR_STATUS).level
     - for i in 0..level-1:  w = read(MIR_DATA); append(w)      // 小端 4 字节
     - 每 N 轮打印一次 {累计字节, level, drop, unf}（带时间戳）
     - 结束条件：累计 >= K（K = 期望字节数）或 超时
4) 落盘 /tmp/mir.bin（按累计字节截断到 K）
5) 打印总结行：MIR_DONE bytes=… words=… drop=… unf=… rate_Bps=…
```
- **读法二选一**（**必须实测选**）：① `mmap` 后紧循环读（若该驱动支持 mmap —— **未核**）；② 反复 `pread(fd,&v,4,addr)`（若非阻塞语义支持 —— **未核**）。**两者都不许**用"每字起一个进程"（那是 `p7b_snap.sh` 的取数器做法，量级掉三个数量级）。
- 程序必须**自带速率读数**（§3.5 定速要用它）：先跑一次"空负载测速"（板不发流，PC 空读 N 秒测 level=0 时的纯读开销）——⚠️ level=0 时读 DATA 会下溢，**空载测速要只读 STATUS**，或先确认下溢语义。
- 判据第一行必须是**身份 + 几何**（BID + 未实现地址），防"位流换代后读了个寂寞"。

### 3.5 发端怎么发（peer）

- 优先复用现成件：`_proj_pcie/p7b_biz/p7b_tcp_src.cpp`（头注释逐字：`p7b_tcp_src --host 192.168.100.2 --port 8080 --seconds 30 [--chunk 65536] [--pace-bps 0] [--no-verify-down] [--poll-ms 200]`；图案由 `p7b_pattern.h` 现场生成）。
- **必须定速**：`--pace-bps`（单位 **bytes/s**，这是本工程的既有单位口径）设到 **< PC 实测排空速率**（例如实测 2 MB/s ⇒ 定到 1 MB/s）。
  ⇒ 判据才能要求 **`drop_bytes == 0`**（= 镜像路径无丢字）。
- ⚠️ 板侧的 TCP app 可能同时在**下行**发（现役 `app_pattern` `TX_CONTINUOUS=1`）⇒ 用 `--no-verify-down` 或不读下行；**不要**用 `0x08` 停流来"清场"（`:4053` 逐字 `assign sfp1_tx_dis = pcie_scratch[0];` ⇒ 写 `0x08 bit0=1` 是**物理关激光**，会把上行 ACK 一起杀掉）。
- ⚠️ 端口：板侧 TCP app 端口 = **8080**（`udp_split` 的 `EXCL_PORT=8080` 留给 HLS，TCP 走 fast path；见 `rtl` 与 `board/wrapper_p4.v:2312` 注释"UDP app 端口（8080 留给 HLS udp_echo）"的对照）。

### 3.6 判据（端到端逐字节 + 计数对账 + 失败分段定位）

**主判据（逐字节）**：
- `mir.bin == transform(pattern[0..K))`，其中 `transform(b) = b ^ 0xA5`，`K` = 本次实际发送字节数（发端自报，且与板侧 W53 的增量对账）。
- 判据必须带：`drop_bytes == 0`（否则只能判"前 K' 字节的**前缀**"—— 且**必须把"有洞"与"结尾截断"分开写**）。

**计数对账（三条，标注同源性）**：
1. `PC 收到字节 + W70(drop) == ΔW53`（app RX 字节）—— **同源一致性检查**（两条口径量同一条流；⛔ **不是独立证据**，全局 #39 精神）。
2. `ΔW54 == 0`（app 自己的逐字节校验器：它若非 0，说明**板上收到的就不是图案** ⇒ 问题在 SFP+/TCP 侧，与 PCIe 无关）。
3. 发端自报字节 vs 板侧 `ΔW53`（跨机对账，链路层损耗的旁证）。

**失败分段定位表（L0–L4）**：

| 层 | 现象 | 判据/工具 | 指向 |
|---|---|---|---|
| L0 链路 | `reg_rw 0x00` 非 `0x50360001` | `lspci` `LnkSta`（x0/x4）+ `remove`+`rescan` 配方 | PCIe 端点/场景 A/C |
| L1 板内 TCP 接收 | `ΔW54 > 0` 或 `ΔW53` 与发端不符 | 快照 W53/W54 + 对端 `ss`/netstat | SFP+/TCP 栈/app 校验器 |
| L2 镜像路径 | `W70 > 0` / `MIR_STATUS.any_drop=1` | 快照 + STATUS | 排空太慢（定速太高）或 FIFO/写门缺陷 |
| L3 搬运 | `unf_sticky=1` / level 与已读字数不闭合 | STATUS | PC 读时序/协议错（读太快/重读） |
| L4 内容 | 逐字节失配 | **首个失配偏移** + 上下各 16 B hex + 该偏移的 4B/8B/段 对齐形态 | 变换错/字节序错/拍错位/段边界错 |

⚠️ **"没观察到" ≠ "不存在"**：定速下 `drop=0` 只证明**本次速率下**没丢字；不推广到任意速率。

### 3.7 时钟域 / 位宽转换（逐项）

| 转换 | 机制 | 说明 |
|---|---|---|
| dp 156.25 MHz → pcie ≈250 MHz | **`rtl/fifo_async.v`**（灰码指针 + 2FF；FWFT=1 ⇒ LUTRAM） | 宽度 32 位（压紧后）；深度 256；**两侧复位都接 `reset_n`**（PERST#，同源） |
| 时钟组声明 | **不需要改 XDC** | `board/ku5p_p7b_cdc.xdc:36-39` 已把 `pcie_axi_aclk` 与 `sys_clk_100`（含 dp_clk）设为异步组 |
| 64+8 → 32 位 | `app_rx_mirror` 内的字节压缩（累加器） | 见 §3.2；**keep=0 拍不贡献字节** |
| 1 bit sticky（drop） | 2FF 电平同步（dp → pcie） | 单 bit 电平标准做法；**登记为一条新 CDC** |
| （可选）主机写 → dp | 2FF（enable）/ toggle 脉冲（clear） | M1 不做；做了要登记 |

### 3.8 构建与身份（一次构建收口）

1. `board/run_build_p7b_ku5p.bat`（**唯一构建入口**；⛔ GUI 重编 `vivado_prj` 有"悬空端口被钳 0"陷阱，`P7B_LONGSEND_HANDOFF.md:110-111`）。
2. `BUILD_ID_V` bump（`board/wrapper_p4.v:4063`）+ **窗口几何三件套同步**（NW / 未实现地址 / 读侧 20 文件 56 处）。
3. 构建后**必须现核**（不许转述）：三类失败端点（setup/hold/pulse）· 全局 WNS **及其对象**（该域现在是 `async_default` 组的 Recovery）· **DP 域** setup WNS · pcie 域新路径。
4. 新模块加进：构建 import 清单（`build_p7b_ku5p.tcl:84-94`）+ 各 lint 门文件表 + （若做）wrapper 门。
5. 上板：重烧（sha256 复核）→ `remove`+`rescan` → `0x00`/`0x04` 判活 → 跑 M1。

### 3.9 回退

- **代码级**：新段全在 `ifdef APP_MODE + PCIE_OBS` 内 ⇒ 不定义即旧行为；`axi_regs` 的新地址可以在不删代码的情况下"不实现"（返回 SLVERR）。
- **位流级**：重烧上一版（**sha256 + BID 双判**；本工程位流全部同为 15,431,261 B ⇒ **只有 sha256/BID 能分版**）。
- **纪律**：回退后**必须重核读侧脚本的 NW/EXPECT_BID/未实现地址**与新位流同代（否则身份门假红）。

### 3.10 UDP 变体（等价的备选，登记）

同一架构，三处替换：tap = `app_udp_rx_*`（**多 `sof`/`len` 边带**，`:2339-2340`）· 发端 = UDP 工具（`p7b_udp_src.cpp` 已存在）· 判据 = 逐数据报（PC 按 `len` 切分核对）。**优点**：无 TCP 窗口/重传参与的语义；`len` 显式。**缺点**：与"TCP 载荷"的原话偏离；UDP 路径另有 HLS 慢路径分流（端口/`EXCL_PORT` 语义）要遵守。

---

## 4. 未定项 / "必须实测才能定"

| # | 未定项 | 为什么重要 | 怎么定（代价） |
|---|---|---|---|
| ① | **我们位流下 `/dev/xdma0_c2h_0` / `h2c_0` 是否存在** | (A) 的入口；不存在 ⇒ (A) 直接不成立 | 板上 `ls /dev/xdma*` + `dmesg | grep -E "xdma0|identify_bars|probe_one"` 看 `ch 1,1`（零构建，5 min） |
| ② | **user BAR 的读速率实测**（mmap？pread？往返多少 µs？） | (B) 的带宽上界全靠它 | PC 侧写 20 行测速程序；顺带核驱动是否支持 mmap（零构建） |
| ③ | **`fifo_async` 在 dp↔pcie 这对域上的行为**（现有例化都跨 gmii/fe/tx 域） | 复位/满空契约在新域对上未实测 | 单元门（xsim，零构建）+ 板级 liveness 读数 |
| ④ | **pcie 域异步复位 Recovery 族的变化**（现役全局 WNS 就在这条网上） | 新 FF 会加负载；本工程 WNS 余量常年很薄 | 一次构建后定向查该族（对齐 `p7b_buildF_build/READINGS.txt:111-134` 的查法） |
| ⑤ | **(A) 若只接 `m_axi` 读通道、写通道保持 tie-off 是否安全** | 简化从机的前提 | 查 XDMA 文档/端口语义 + 单元门/板级；**未核前按"两通道都接"设计** |
| ⑥ | **XDMA 引擎对从机的具体要求**（是否可能发非 INCR / 非对齐 / 跨 4 KB 单笔） | 从机协议判据的输入 | 读 PG021/实测 pcap 式抓 AXI（仿真 stub 扩模型） |
| ⑦ | **DMA 的可用速率（板级、深提交）** | (A) 的实测上界（历史 257 MB/s 是工具帽） | 板级多通道/深提交测量（构建 + 板上跑） |
| ⑧ | **板侧 TCP RX 在"定速 + 长跑"下的稳定性**（会不会有 stall/重传干扰字节账） | 决定 M1 能否要求 `drop==0` | 先跑一轮"只读 W53/W54 + 定速"的观测轮（零构建） |
| ⑨ | **`unf`（下溢）语义与 PC abort 的交互**（读一笔但未见 CplD 时是否白弹） | 判据 L3 的可靠性 | 设计上先"STATUS.level 协议 + unf 计数"，实测后定 |
| ⑩ | **是否允许给 `app_rx_mirror` 加"使能/清零"**（涉及新 pcie→dp 控制 CDC） | 决定改动面大小 | 用户/设计裁定；M1 默认不做 |
| ⑪ | **许可**：本机未逐字核 `xdma` 的 license 键 | (A) 的前提之一 | 事实是多次构建成功（厂商 + 我们 ≥6 版位流）⇒ 风险低；要严谨就查 `get_property USED_LICENSE_KEYS`（下轮构建捎带） |
| ⑫ | **`p7b_tcp_src` 的发端字节自报**是否精确（含 `--seconds` 截断语义） | 判据 K 的来源 | 对端现跑 + 读它的 `SRC_*` 行（零构建） |

---

## 5. 附：本件引用的行号索引（全部 2026-10-11 现读）

| 文件 | 行 | 内容（首句） |
|---|---|---|
| `board/build_p7b_ku5p.tcl` | 112-130 | XDMA IP 创建 + 参数 dict（`axilite_master_en=true` / `axilite_master_size=1` MB / `num_queues=1` / `axi_data_width=128_bit`） |
| 同上 | 138 | `set_property used_in_synthesis false [get_files ${script_dir}/ku5p_p7b_cdc.xdc]` |
| 同上 | 145-153 | `verilog_define {APP_MODE=1 DEV_USP=1 PCIE_OBS=1 DP_156MHZ=1 P7B_10G=1 UDP_TX_OVL=1 TCP_TX_OVL=1}` |
| `board/wrapper_p4.v` | 186-196 | `ifdef PCIE_OBS` 的 PCIe 端口（`pcie_sys_clk_p` … `pcie_rxn`） |
| 同上 | 190-191 | `reset_n` = 板上 PERST#（J9）的注释 |
| 同上 | 685-687 | FIFO 两侧复位硬规则（都接板级 `reset_n`） |
| 同上 | 891-895 | `u_rxcdc` 例化（`fifo_async #(.WIDTH(76), .DEPTH(256), .FWFT(1), .AW(8))`） |
| 同上 | 1079-1085 | `app_rx_*` 别名（= `eco2_*`） |
| 同上 | 1195-1208 | `app_pattern` 例化参数（`TX_BYTES=32'h0FFFFFFF` / `TX_CONTINUOUS(1'b1)` / `TX_TAILCARRY(1'b0)`） |
| 同上 | 1209 | `.clk (dp_clk)` |
| 同上 | 1223-1228 | `app_pattern.rx_*` 端口连接 |
| 同上 | 1807 起 / 1831-1844 | `tcp_rx` 例化 / 其载荷输出 `pay_*` 与 `meta_*` |
| 同上 | 1910 / 1924-1929 | `tcp_echo` 例化 / `eco_*` 输出 |
| 同上 | 1945-1954 | `axis_pipe #(.W(77)) u_eco_pipe` → `eco2_pack` |
| 同上 | 2155 | `tcp_tx_frame #(.RING_CAP(WIN_CAP_5), .PERSIST_EN(1'b0)) u_tcp_tx (`（**本日 WIP**） |
| 同上 | 2311-2342 | `udp_split` 的 app 口（`app_rx_*` + `sof/len`） |
| 同上 | 2575-2592 | `app_udp_pattern` 例化（`.TX_BYTES(32'd0), .TX_GAP(16'd0)`） |
| 同上 | 2769-2778 | `u_txcdc` 例化（**新 FIFO 的照抄样板**） |
| 同上 | 3155-3169 | 扩窗"七处同改"清单 |
| 同上 | 3241 | `localparam SNAP_NW_P6E = 70;`（未实现地址 = `0x138`） |
| 同上 | 3995-4013 | `m_axi` tie-off（"全回永不应答"） |
| 同上 | 4039 | `assign pcie_hw_status = {24'd0, pcie_msi_vec_w, pcie_msi_enable, pcie_lnk_up, 3'd0};` |
| 同上 | 4053-4054 | `assign sfp1_tx_dis = pcie_scratch[0];` / `sfp2_tx_dis = pcie_scratch[1];` |
| 同上 | 4061-4063 | `axi_regs #(.MAGIC_V(32'h50360001), .BUILD_ID_V(32'h0000001C), …)`（**本日 WIP**） |
| 同上 | 4249 | `.SNAP_NW (SNAP_NW_P6E)` |
| `_proj_pcie/rtl/axi_regs.v` | 9-43 | 寄存器表头注释（含未实现地址约定） |
| 同上 | 155 / 196 | `w_word = awaddr_r[8:2]` / `ar_word = s_axil_araddr[8:2]`（7 位译码） |
| 同上 | 174-184 | 写通道白名单（`0x08` / `0x18`，其余 SLVERR） |
| 同上 | 237 / 270 | `snap_idx` / `snap_base [11:0]` |
| 同上 | 280-293 | 读 mux（`MAGIC` … `snap_status` … 快照字） |
| 同上 | 302-314 | 读通道时序（单笔串行；SLVERR 边界 `r_word <= SNAP_LAST_IDX`） |
| `board/ku5p_p6e_pcie.xdc` | 14 | `create_clock -period 10.000 -name pcie_ref_clk [get_ports pcie_sys_clk_p]` |
| `board/ku5p_p7b_cdc.xdc` | 36-39 | `set_clock_groups -asynchronous` 三组（含 `pcie_axi_aclk`） |
| `sim/p6e_pcie/xdma_0_sim_stub.v` | 14-16, 31-32 | 层次任务 `axil_read/axil_write` / `m_axi` 端口"替身不驱动" |
| `_proj_10g/notes/P7B_PCIE_RESCAN_RECOVERY.md` | 24-28 / 57-65 / 154-162 / 176-184 | 三场景表 / 恢复配方 / BAR 尺寸实测 / `identify_bars` 判别式 |
| `_proj_10g/notes/P7B_LONGSEND_HANDOFF.md` | 44-53 / 69-71 / 107-111 | 烧录配方 / 环境五项 / 最容易踩的十条 |
| `_proj_10g/notes/P7B_BIZ_WINDOW.md` | §1 表 + 更新块 | 现役 70 字槽位表 / 未实现地址 `0x138` |
| `_proj_10g/notes/p7b_buildF_build/READINGS.txt` | 111-134 | 全局 WNS `+0.111`（`async_default` Recovery，`bbstub_axi_aresetn` fo=5392）/ DP 域 WNS `+0.281` |
| `_pcie/README.md` | 11-20 / 32-42 / 44-57 / 59-83 | 链路与节点 / 吞吐特性与警告 / POST 约束 / 用法 |
| `_proj_pcie/README.md` | 一节表 | user BAR 8/8 验收（`2 BARs: config 1, user 0` / `MAGIC` / `FREECNT≈250MHz`） |
| `udp_hls_10g/CLAUDE.md` | 构建 F 置顶块 | 读侧加固 20 文件/56 处；`p5_wrapper` 既存红；#64–#68 |

---

*本件 = 侦察 + 设计，不改任何读数、不代行裁定。落笔实施前：① 重核 `board/wrapper_p4.v` 行号（当日 WIP）；② 重核窗口三件套；③ 依 `board/run_build_p7b_ku5p.bat` 一次构建收口。*

---
---

# v2 修订块（2026-10-11；依据 = 红队审查 `_proj_10g/notes/p7b_pcie_datapath_review_20261011/FINDINGS.md`（222 行）+ TL 书面裁定 7 条）

> **读法**：v1 正文**一字未删**（可追溯）。**本块优先于 v1 正文** —— 凡冲突，以本块为准。
> 全部行号 = **2026-10-11 第二次现读**（本块逐处重核；v1 里 4 处漂移的勘误见 §V6）。
> 纪律不变：不下 PASS/FAIL 裁定；"未观测到" ≠ "不存在"；"不支持" ≠ "证伪"。

## V0. TL 裁定 → 落地位置速览

| TL 条 | 落地处 | 一句话 |
|---|---|---|
| 1 · S1（阻断）| §V1.1 | 具名 localparam 统一"字号 vs W 编号"；门加双向断言；`rd_pop` 与 `!empty` 同门；`empty` 时出哨兵 |
| 2 · S2（阻断）| §V1.2 | 采 (a)：`K % 4 == 0` 提升为**前置条件**；"尾部 ≤3 B 不可观测"从设计里**删除** |
| 3 · ⑩ | §V1.3 | enable/clear **纳入 M1**（新增 RW 字 `MIR_CTRL`）|
| 4 · S10 | §V1.4 | 新段再加一层 `ifdef DP_156MHZ`（代价已列；备选"登记 XDC 缺口"不采纳）|
| 5 · 零成本 | §V1.5 | ③⑨⑪⑫ **定案**；①②⑤⑥⑧ 给"离线到哪一步 + 板上怎么收尾"|
| 6 · 判据 | §V3 | 保留 5（改 2 条口径）+ 新增 5 + 负对照 S8(a)–(e)（+ 本块新增 (f)）全表 |
| 7 · S9 | §V1.6 | 回退三拆，逐条代价 |

---

## V1. TL 裁定落地

### V1.1 S1 修法（**采纳**；这是 v1 里唯一的"具体缺陷"）

**缺陷复核（本块现读）**：v1 §3.3 片段写的 `rd_pop = (r_word == 7'd72)` 里 `r_word` 是**地址字号**（`_proj_pcie/rtl/axi_regs.v:196` `wire [6:0] ar_word = s_axil_araddr[8:2];`、`:303` `ar_word_r <= ... r_word <= ar_word;`）⇒ `0x140 >> 2 = **80**`，而 `7'd72` = `0x120` = 现役快照 **W64**（`_proj_10g/notes/P7B_BIZ_WINDOW.md` §1 表逐字 `| **W64** | 0x120 | dp[25] |`）⇒ **任何读 W64 的取数器都会白弹一字**。

**修法（两把尺子合一 —— 硬件侧**只**用"字号"，且全部由 `SNAP_LAST_IDX` 推导）**：

```verilog
// axi_regs.v 内（:137 已有第一行；下面全是新增，一律不写裸字面量）
localparam integer SNAP_LAST_IDX  = 8 + SNAP_NW - 1;      // 现读 :137 逐字
localparam integer MIR_STATUS_IDX = SNAP_LAST_IDX + 1;    // 字号 79  = 0x13C = "W71"（文档口径）
localparam integer MIR_DATA_IDX   = SNAP_LAST_IDX + 2;    // 字号 80  = 0x140 = "W72"
localparam integer MIR_CTRL_IDX   = SNAP_LAST_IDX + 3;    // 字号 81  = 0x144 = "W73"
localparam integer MIR_LAST_IDX   = MIR_CTRL_IDX;         // 实现边界（SLVERR 判据改用它）

wire rd_pop = (r_word == MIR_DATA_IDX[6:0]) && !mir_empty;   // ⚠️ 与 !empty 同门（TL 硬要求）
// rdata_mux 的 MIR_DATA 分支：mir_empty ? MIR_SENT : mir_dout   —— 空态**永不**输出 FIFO 的"不定 dout"
// SLVERR 边界：rresp <= (r_word <= MIR_LAST_IDX) ? 2'b00 : 2'b10;   （原判据 = `<= SNAP_LAST_IDX`，:308 现读）
```

⚠️ 修正后**几何**（与 v1 §3.3 的表不同 —— 以本块为准）：快照 70→**71 字**（W70 = `0x138` = `mir_drop_bytes`，dp 域、走既有快照机制 ⇒ **不新增 32 位 CDC**）· `MIR_STATUS` = `0x13C` · `MIR_DATA` = `0x140` · `MIR_CTRL` = `0x144` · **未实现地址 = `0x148`**（字号 82；⛔ 绝不挑 ≥ `0x200` —— `:65` 现读的 7 位译码回绕红线）。

**门里的双向断言（TL 硬要求，全部进 `tb_p6e_pcie_wrapper.v` 的新判据组）**：
1. 读 `MIR_DATA` 且 `level>0` ⇒ 读后 `level` **减 1**；
2. 读**快照区任意字**（`0x20..0x138`，含新 W70）⇒ `level` **不变**（S1 的回归牙）；
3. `level==0` 时读 `MIR_DATA` ⇒ 返回 `MIR_SENT`、`unf_sticky` 置位、`level` 仍 0；
4. 读 `0x148` ⇒ `rresp=SLVERR`（负对照）且 `level` 不变；
5. 写非白名单地址（`0x08/0x18/0x144` 之外）⇒ SLVERR 且 `level` 不变。
6. 哨兵常量 `MIR_SENT` 取值建议 `32'h5A5A_5A5A` —— ⚠️ **它不是"唯一性"保证**（数据可以是任何值），它是**响亮值**；权威证据 = `unf_sticky` + `unf_cnt`（登记口径）。

### V1.2 S2（**采纳 (a)**：`K % 4 == 0` 作为前置条件）

- v1 §3.2 的"跨段续用累加器 + 末字可能含 1–3 个填充字节，PC 侧按 W53 截断"与 §3.6 的"尾部 ≤3 B 不可观测"**两处表述删除**（自相矛盾：不 flush ⇒ 残余字节**永远**进不了 FIFO ⇒ "K 字节逐字节"结构上不可达）。
- **前置条件（写进判据表）**：M1 本次运行的发端总字节数 `K` **必须是 4 的倍数**；不满足 ⇒ 判据不成立（不是"允许不可观测"）。
- 落地 = **发端工具**（自己的工具）：`p7b_tcp_src` 加 `--bytes N`（**`N % 4 != 0` ⇒ 立即 `exit(2)` 响亮失败**），送到 N 字节即停。⚠️ 同批**必须**用 **ppos-续发语义**（`_pcie/p7b_biz/p7b_io.h` 头注释逐字：`1. **三种 send 语义必须并存**: \`SRC\` 重填重发 / \`FIX\` ppos 续发 / \`DIAG\` 旧行为。`）—— 否则 partial send 会在图案流里挖洞（见 §V3 的 L1 补格）。
- ⛔ 若将来要支持 `K%4≠0`：唯一正确修法是"**停止时 flush**"（需要一个 stop 事件把累加器残余写出并打标记），代价 = 新状态机 + 新判据 ⇒ **本刀不做**，登记为未定项（§V4）。

### V1.3 ⑩ enable/clear **纳入 M1**（TL 裁定）

- 新字 `MIR_CTRL`（`0x144`，RW，wstrb 照 `SCRATCH` 的写法 —— `axi_regs.v:174-179` 现读同款）：
  - `bit0 = cap_en`：**复位默认 0 = 关**（⇒ M1 交付位流"带电即回退态"，见 §V1.6-i）；
  - `bit1 = clr`：写 1 产生一次**跨域清除脉冲**（清 FIFO 读空 + 字节累加器 + `unf`/`drop` sticky）；
  - 读回 = 当前值（与 `SCRATCH` 同构）。
- **协议（写清，否则起点语义含糊）**：`clr` **不改变** `cap_en`；起测顺序 = ① `clr=1` → ② `cap_en=1` → ③ 发端开跑。
- ⚠️ **新登记一条 CDC（pcie→dp）**：`cap_en` 用 **2FF 电平**（慢变、单 bit）；`clr` 用 **toggle + 边沿检测**（脉冲语义：写一次清一次，不因同步延迟重复清）。两条都要在单元门里断言（toggle 的"一次写 ⇒ 恰好一个 dp 脉冲"）。
- 收益（TL 语）：补"功能齐备"的最小反向闭环 + 给"起点对齐"（S4）一条**物理**路径（不再只靠"排空 + 见证"）。

### V1.4 S10（**采纳**：新段再加一层 `` `ifdef DP_156MHZ ``）

- 包法：`ifdef APP_MODE` ∧ `ifdef PCIE_OBS` ∧ `` `ifdef DP_156MHZ `` 内 = mirror 模块 + 新 FIFO + 真驱动；**`¬DP_156MHZ` 时 `axi_regs` 的新端口接常量**（`level=0`、`empty=1`、`dout=0`、`drop=0`；`MIR_CTRL` 写被接收但只落一个死寄存器）—— 保持"新增端口在默认路径上必须是常量"的既有纪律（`udp_hls_10g/CLAUDE.md`「应用接口」节的同款句式）。
- 代价/收益（写清）：
  - (i) 宏组合从"双宏四态"升为"**三宏八态**"，但**两个现役门把两面都覆盖**：`board/run_lint_p6e.bat:24`（本块现读逐字 `call %XV%\xvlog.bat -work xil_defaultlib -d PCIE_OBS -d DEV_USP -d APP_MODE -i %ROOT%\rtl -i %ROOT%\board -f files.f > xvlog_p6e.log 2>&1` —— **无** `DP_156MHZ`）⇒ 编的就是 tie-off 支；`sim/p6e_pcie/run_tb_p6e_pcie.bat`（本块现读 `:11-13`）defines = `PCIE_OBS + DEV_USP + APP_MODE + DP_156MHZ + P6B_SIM_CLKGEN` ⇒ 编的就是真支。
  - (ii) 审查 #14 指出的"`gmii_clk` 不在 `ku5p_p7b_cdc.xdc` 三组里"这一缺口，在加了本层宏后**对 M1 不再可达**（坏组合下新逻辑整体不存在）——⚠️ "`gmii_clk` 到底在不在三组里"这个问题**本块不裁**（审查说不在；本块只登记"M1 不再依赖该判定"）。
  - (iii) 备选（**不采纳**）：登记 XDC 缺口 + 给 `(PCIE_OBS ∧ ¬DP_156MHZ)` 补 `set_clock_groups` —— 代价 = 改 XDC + 该组合**无任何门覆盖**（靠人记得），且要复跑 `12-4739` 检查。

### V1.5 零成本定案（③⑨⑪⑫）+ 半可定路径（①②⑤⑥⑧）

| # | 定案 / 路径 | 依据（本块现读） |
|---|---|---|
| **③** | **定案 = 零构建可定**：`tb/tb_fifo_async.v` 已有 4 变体门；M1 扩**第 5 个 case** = M1 实参 `WIDTH=32, DEPTH=256, FWFT=1, AW=8` + **两侧周期 6.4 ns : 4 ns**（= 156.25 : 250）复用既有 `case_reset / case_lat / early / ovf` 断言组（含"写入沿后 ≥4 个 rd 沿才可能观察 empty 拉低"的硬契约，`rtl/fifo_async.v:41-45` 头注释现读）| `fifo_async.v:17-19` 头注释（4 变体清单）· `:41-45`（延迟硬契约）|
| **⑨** | **定案 = 结构性成立**（推导）：弹出挂在"装载 rdata"分支（`axi_regs.v:306-311` 现读），那一刻 AR 已握手完成（`:302-305`）⇒ **主机是否取用返回值在 AXI 层不可见** ⇒ "白弹"必然存在、**不可在该层消除**；唯一动作 = **可观测**：字节账（§V3-④）会以 **4 的倍数差**暴露（§V3-L3 补格）。⇒ 不修、只登记 + 观测口径 | `axi_regs.v:302-311` |
| **⑪** | **定案 = 已可定（零成本）**：F 轮归档 stdout 的 `License Check failed` **命中 0**（审查已 grep 复核；本块不重跑）；`USED_LICENSE_KEYS` 只列 `xxv_*`（那是 `pcs64` 的 —— `build_p7b_ku5p.tcl:76` 只对 pcs64 打了那一行）⇒ **M1 构建搭车加一行**：对 `xdma_0` 也打 `get_property USED_LICENSE_KEYS`（与 `:76` 同形）⇒ 一次构建拿到逐字证据 | 审查 §4-⑪ · `build_p7b_ku5p.tcl:76` |
| **⑫** | **定案 = 已现核，按字节精确**：`P7bPat tx(0);`（`:120`）每连接偏移 0 起；主循环 `while (now_s() - t0 < secs) {`（`:129`）只界定时长；计数字 = `if (n > 0) tx_bytes += n;`（`:155`）**只累加实际 `send()` 返回值** ⇒ **K 可信**（写进 §V3 前置）。⚠️ 同批登记：`p7b_pattern.h:147` `inline void fill(uint8_t *dst, size_t n)` **无条件推进图案** ⇒ partial send 挖洞（L1 补格）| `p7b_tcp_src.cpp:120/:129/:155` · `p7b_pattern.h:147` |
| **①** | 离线只到**强推断**（厂商设计同驱动 + 同 `ch 1,1` 实测 19 节点含 `c2h_0/h2c_0`：`_pcie/README.md:15`；引擎在：`.xci:75-76`）⇒ **板上收尾** = 我们的位流下 `ls /dev/xdma*` + `dmesg | grep -E "identify_bars\|probe_one"`（零构建）| 同左 |
| **②** | **半可定**：mmap 支持**只能读对端驱动源码**（本机全盘 `find` 无 `dma_ip_drivers` 副本 = 现核）⇒ **板上收尾** = 两版 20 行 C（mmap / pread）各测一遍。⛔ **它决定 M1 的 K 与时长**（若只能进程级 `reg_rw` ⇒ 掉三个数量级 ⇒ 秒级演示变小时级）⇒ **必须先定再选 K** | 本机 find（审查 §4-②）|
| **⑤** | **有零成本离线路径**（审查 §S12 新发现，本块**只登记、未读结论**）：`vivado_prj/p7b_ku5p_prj.gen/sources_1/ip/xdma_0/xdma_0_sim_netlist.v`（本块现核 `wc -l` = **329,499**；`module xdma_0` = `:18`、`module xdma_0_core_top` = `:2860`，明文）⇒ 可在明文里追 `m_axi_arvalid/arlen/arsize` 生成逻辑 | `xdma_0_sim_netlist.v:18/:2860`（本块现读）|
| **⑥** | 同 ⑤ 的路径 + `C:/AMDDesignTools/2025.2/data/ip/xilinx/xdma_v4_2/`（component.xml / xgui / hdl）；⚠️ IP 真 RTL **不在**安装目录明文里 | 审查 §4-⑥ |
| **⑧** | **零构建、需上板**（观测轮）；**建议加一问"发端 partial send 是否存在"**（读发端 `SRC_SUM` 的 partial 计数）| §V3-L1 |

### V1.6 S9 回退三拆（**采纳**；逐条代价）

| # | 方式 | 代价 | 何时用 |
|---|---|---|---|
| **(i)** | **运行期 `cap_en = 0`**（⑩ 纳入 M1 后**免费获得**；且**复位默认即 0**）| **零构建、零读侧回退**（窗口几何 / BID / 脚本身份全不动）| **首选**。M1 位流"带电即回退态"；启用 = 写 `0x144` |
| **(ii)** | 重烧旧位流 | **脚本必须同代回退**（`NW / EXPECT_BID / 未实现地址` 三件套回到旧值，否则身份门**假红**）+ 板上数据集换代 | 要回到"M1 之前的功能集" |
| **(iii)** | 宏关 / 参数关 + 重构建 | 一次构建（~26 min 量级）+ **BID 必须再 bump** + **读侧同步再走一遍** | 要**移除代码**（不是关功能）时 |

⛔ 三档**都不许**写成"回退一行"。⛔ 单纯关 `PCIE_OBS` **不是**回退 —— 那会取消**整个观测通道**（快照窗口/取数器全依赖它）。
⚠️ (i) 的语义边界：`cap_en=0` 只停"采集"；`MIR_DATA`/`MIR_STATUS` 仍**实现**（读 DATA 得哨兵、STATUS 读 0/常量）⇒ **读侧脚本无需回退**（这是 (i) 比 (iii) 便宜的根本原因）。

---

## V2. S1–S13 逐条处置（采纳 / 不采纳 + 理由）

| S | 级别 | 处置 | 一句话 |
|---|---|---|---|
| **S1** | 阻断 | **采纳** | `rd_pop` 常量错（`7'd72` = 0x120 = W64）；修法 = 具名 localparam 统一字号 + `!empty` 同门 + 门内双向断言（§V1.1）|
| **S2** | 阻断 | **采纳 (a)** | "不 flush"与"填充字节"不可同真 ⇒ K 定为 4 的倍数、删除不可观测表述（§V1.2）|
| **S3** | 高 | **采纳** | 三类残余登记 + "只许 32 位访问"写成纪律（mmap 侧 `volatile uint32_t`）+ **补引前提** `.xci:121`（本块现读逐字 `"axil_master_prefetchable": [ { "value": "false", "resolve_type": "user", "enabled": false, "usage": "all" } ],`）+ 守卫句"标成 prefetchable = **静默摧毁**本机制" |
| **S4** | 高 | **采纳** | 逐字节判据对"起点错"是空判据（每连接都从偏移 0 起 ⇒ 旧数据与新期望**逐字节相同**）⇒ ④ 计数对账口径改"**不是独立证据，但不可省**"；PC 流程加 **step 0**（排空 + `level==0` + 快照 `ΔW53==0`）；起测用 ⑩ 的 `clr` 物理对齐 |
| **S5** | 中 | **采纳** | 正确门 = `sim/p6e_pcie/run_tb_p6e_pcie.bat`（`:11-13` 现读：defines 恰 = M1 宏组合；`:13` `dir /b /s "%ROOT%\rtl\*.v"  > files.f` ⇒ **新 RTL 自动纳入**）；**两条几何常量必须同改** = `tb_p6e_pcie_wrapper.v:149`（`chk("2  BUILD_ID (构建 F 70 字=0x1A; ...)", v, 32'h0000001A);`）与 `:339`（`chk("9  未实现地址 0x138 ⇒ rresp = SLVERR", ...)`）。⚠️ `p5_wrapper` **看不见** M1（`sim/p4gates/p5wrapper_src.f:3-8` 自陈 `-d APP_MODE ONLY` + `cannot stand in for a board-config wrapper gate`）|
| **S6** | 中 | **采纳（4 条 + 1 措辞）** | ①措辞：`reset_n` 两侧**不是"天然对齐"**，而是"**同源/同时断言；释放不同步是允许的**"（`fifo_async.v:55-58` 现读）；②哨兵**靠 `empty` 选路**（`:229` 现读 `empty_r <= 1'b1;  // 复位后为空 (**不能是 0**)`）—— 不依赖复位代；③`level` **直接用 `dbg_occ_r`**（`:285` 现读 `assign dbg_occ_r = gray2bin(wgray_s2_r) - rbin_r;`，读域已 2FF 同步、**悲观少报**）⇒ 多比特 CDC 问题消失 + "读 level 个字"**不可能下溢**；④写门 = **组合** `wr_en = word_have && !full`（**本拍 `full`**）—— 现核 `fifo_async` **无 `full_next` 端口**（全端口表只有 `:116 output wire full`），故"寄存器写 + full_next"这条路**本刀不开**；⑤`ovf_cnt` **不接**（`:140-141` 现读"消费侧的正确用法是**差分**"）⇒ 只自算 `drop_bytes` |
| **S7** | 中 | **采纳（3 条）** | ①`drop==0` 绑 `K>0 ∧ ΔW53≈K`；②`ΔW54==0` 带"同窗 `ΔW53>0`"；③`MIR_STATUS` 位域改**恰好 32 位**：`{9'd0, ver[3:0], capture_on, any_drop_sticky, unf_sticky, level[15:0]}` = 9+4+1+1+1+16 = **32** ✓（v1 的 38 位作废）|
| **S8** | 中 | **采纳** | 5 条负对照全收（§V3），+ 本块新增 (f) clear 负对照 |
| **S9** | 中 | **采纳** | §V1.6 三拆 + **读侧清单本刀轮重生成**（`apply_readside.py` 的显式清单 + 命中数断言 + A/B/C 三条结构性断言 + 负对照）——**先于构建**；第 21 处 = `axi_regs.v:29`（现读仍写"共 **63 字**"）/`:43`（现读仍写"未实现地址 = **0x11C**"）头注释也要同步 |
| **S10** | 中 | **采纳** | 加 `` `ifdef DP_156MHZ ``（§V1.4）|
| **S11** | 中 | **采纳选项 ①**（登记背景 = 下行连续泛洪）| 选项 ②（静默下行构建）**本刀不做**：`TX_BYTES` 是**参与综合的常量**（全局 #64，本工程已实测"改常量确定性改时序"）+ 本刀已有一次构建 ⇒ 混装会污归因。登记为未定项（若 M1 实测被下行泛洪干扰到不可判 ⇒ 单开一刀，含"小 `TX_BYTES` + `TX_CONTINUOUS=0`"两常量，各带自己的时序核查）。⚠️ 附属事实：`0x08` 停流手段**已被正确排除**（`:4053` 现读 `assign sfp1_tx_dis = pcie_scratch[0];` = **物理关激光** ⇒ 上行 ACK 也死）；`app_ctrl` **不在 BAR 窗口**（写白名单只有 `0x08/0x18`，`:174-184` 现读）⇒ 主机**确无停流路径** |
| **S12** | 低 | **采纳（登记）** | 零成本离线路径已登记（§V1.5 ⑤），本块**未读结论**；"核里有 4 通道 AXIS、顶层没有"这条按审查原样引用（**不许读成"IP 有 AXIS 通道"**）|
| **S13** | 低 | **采纳（3 条）** | ①TL;DR 加口径句"**本里程碑打通的是链路拓扑，不是带宽**"；②UDP 变体判据前置写清：`UDP_APP_PORT = 16'h1F91`（= 8081，`wrapper_p4.v:2314` 现读）/ `8080 留给 HLS udp_echo`（`:2312` 现读）⇒ **打到 8080 的 UDP 帧会被 HLS 吞掉**，现象 = "镜像窗零字节"；③⑩ 已纳入（§V1.3）|
| **§5 勘误** | — | **采纳** | 见 §V6 |
| 审查附注 | — | **采纳** | `_pcie/README.md` 的 XVC 两处口径自相矛盾改"**两条并列** + 有节点 ≠ 功能可用"（与 c2h 告诫同型）|

---

## V3. 判据 / 负对照 v2 全表（替代 v1 §3.6 的主判据段与 §3.6 的定位表两行）

**前置条件（全部满足才允许进入判据）**：`K % 4 == 0`（§V1.2）· 发端用 **ppos-续发**语义 · `K` 与实测 `ΔW53` 闭合（闭合式见 ④）· 起测前 `clr` 已写、`cap_en=1`。

**正判据（10 条）**：

| # | 判据 | 口径（v2）| 备注 |
|---|---|---|---|
| 1 | **身份**（必留）| `0x00=0x50360001` · `0x04=新 BID` · 窗口 **71 字**（`0x20..0x138`）· **未实现地址 `0x148`** 回 `0xffffffff` · `LnkSta x4` · `identify_bars = 2 BARs` | 负对照地址**一代一挪**，脚本/门/TB 三处同走 |
| 2 | **level 有牙**（改口径）| 发送期间**必须出现过 `level > 0`**（不再是"单调不减"）| 空跑天然满足的判据一律不要 |
| 3 | **逐字节**（必留）| `mir.bin == pattern ^ 0xA5` 共 K 字节 | **配 ④**才成立（S4）|
| 4 | **计数对账**（必留 · **地位上调**）| `(PC 字节 + ΔW70) mod 2³² == ΔW53`（ΔW53 见 8）| "不是独立证据，但**不可省**" = **唯一**能发现起点错/白弹的量 |
| 5 | **哨兵**（必留）| 空读 `MIR_DATA` ⇒ `MIR_SENT` + `unf_sticky=1` + `level` 不变 | + 负对照 (b) |
| 6 | **drop==0 的门**（新）| 只在 `K>0` **且** `\|ΔW53 − K\| ≤ 容差` 时才允许判 `ΔW70==0` | 空跑下 `drop==0` 是空判据 |
| 7 | **起点对齐**（新）| 两代快照：起测前 `level==0` **且** `ΔW53==0`（+ `clr` 见证）| 与 ④ 互补 |
| 8 | **回卷登记**（新）| `ΔW53` **mod 2³²** + 同时记 raw 与 k（`W53 ≈ 3.65 s` 回卷；12 s 窗门槛 2.8633 Gbps ⇒ M1 远低，"登记即可"）| 来源 = `P7B_LONGSEND_HANDOFF.md` §6 第 7 条 |
| 9 | **快照触发协议写清**（新）| 触发 = 写 `0x18=1`；`done` = `0x1c` bit1；`gen` 逐代 +1；**"快照 = 上次触发时刻的值"** | 出处 = `axi_regs.v:72` 逐字（按审查引用登记，本块未重读该行）|
| 10 | **`ΔW54==0` 带前置**（新）| 必须"**同窗 `ΔW53>0`**" | 前科 = `W13` 空判据（`P7B_W13_AUDIT.md`，`A4` 由 PASS 降"未测"）|

**负对照（S8 五条 + 本块一条）**：

| # | 构造 | 期望 | 证明什么 |
|---|---|---|---|
| (a) | **同位素臂**（位流不动）：发端**去掉 `--pace-bps`**（不定速）| **必须**看到 `ΔW70>0` / `any_drop=1` | **drop 计数有牙**（否则 6 的 `drop==0` 全是空判据）|
| (b) | 只读 STATUS：空载读 `0x13C` 数次 | `unf_sticky==0`、`level==0` | 区分"有意读 DATA"与"协议错" |
| (c) | 变换负对照：PC 侧**故意不 XOR** | **全体失配** | XOR 真在板内做 |
| (d) | 地址负对照：读 `0x148` | `level`/`unf` **不变** | "只有 `MIR_DATA` 有副作用"（S1 同型）|
| (e) | 快照不弹：**逐字读 `0x20..0x138` 全部 71 字** | `level` **不变** | 读快照不得偷数据（**S1 的回归牙**）|
| (f) | **clear 负对照（新）**：**不写 `clr`** 连跑两轮 | 第 7 条判据（起点对齐）应能区分 | 若区分不了 = 起点判据无牙 ⇒ 重设计 |

**分段定位表 v2（v1 表 + L1/L3 各补一格）**：

| 层 | 现象 | 判据/工具 | 指向 / ⚠️ 陷阱 |
|---|---|---|---|
| L0 | `reg_rw 0x00` 非 `0x50360001` | `lspci` `LnkSta`（x0/x4）+ `remove`+`rescan` | PCIe 端点 / 场景 A/C |
| L1 | `ΔW54 > 0` 或 `ΔW53` 与发端不符 | 快照 + 对端 `ss` | SFP+/TCP 栈/app 校验器 —— ⚠️ **L1 补格**：**发端 partial send** 也落这一格！现象 = `ΔW54>0` 而发端自报正常（`tx_bytes` 精确，`:155`）—— 因为 `p7b_pattern.h:147` 的 `fill()` 无条件推进图案（**挖洞**）⇒ **归因会指向 SFP+/TCP 栈（会误导）**；判别 = 发端 `SRC_SUM` 的 partial-send 计数 + 改 ppos-续发复跑 |
| L2 | `ΔW70 > 0` / `any_drop=1` | 快照 W70 + STATUS | 排空太慢（定速太高）或 FIFO/写门缺陷 |
| L3 | `unf_sticky=1` / level 与已读字数不闭合 | STATUS | PC 读时序/协议错 —— ⚠️ **L3 补格**：**"白弹"** 现象 = `unf_sticky==0` 而**字节账差是 4 的倍数**（§V1.5-⑨ 的结构推导）|
| L4 | 逐字节失配 | 首个失配偏移 + 上下 16 B hex + 该偏移的 4B/8B/段 对齐形态 | 变换错 / 字节序错 / 拍错位 / 段边界错 |

---

## V4. 未定项 v2（对 v1 §4 的更新；编号沿用 v1）

| v1 # | v2 状态 |
|---|---|
| ① | **保留**（强推断 → 板上 `ls` 收尾）|
| ② | **保留且升级为"先决"**：它决定 K 与演示时长（见 §V1.5）；先读对端驱动源码定 mmap，再选 K |
| ③ | **已定案**（§V1.5：fifo_async 单元门扩第 5 case，零构建）|
| ④ | **保留**（真需构建；建议定向 `-from/-to` + 记该 async 组端点数 —— F = 5409 / E = 5216 是现成负载见证，出处 = 审查 §4-④）|
| ⑤⑥ | **保留**（离线明文网表路径已登记；结论未做）|
| ⑦ | **保留**（真需上板；257 MB/s 是工具帽）|
| ⑧ | **保留**（零构建、需上板；加"partial send"一问）|
| ⑨ | **已定案**（结构推导 + 由账差识别）|
| ⑩ | **已裁定纳入 M1**（不再是未定项）|
| ⑪ | **已定案**（归档 stdout 命中 0 + 下次构建加 `USED_LICENSE_KEYS` 行）|
| ⑫ | **已定案**（`tx_bytes` 按字节精确；K 可信）|
| **新 N1** | **支持 `K%4≠0`**：需"停止时 flush"状态机（§V1.2）—— 未定，本刀不做 |
| **新 N2** | **S11 选项②"静默下行构建"**：若 M1 实测被下行泛洪污染到不可判 ⇒ 单开一刀（含 `TX_BYTES`/`TX_CONTINUOUS` 两常量，各带时序核查）|
| **新 N3** | **链路层重放 ⇒ 双弹**（S3-②）：【推断】未证 ⇒ 登记"**未观测 ≠ 不存在**"，由 L3 补格 + (d) 负对照盯 |
| **新 N4** | **`clr` 的"清干净"见证**：现只能靠 `level==0` + `ΔW53==0` 组合推断；若要更硬需一个 `cleared_sticky` 位（可选，登记）|

---

## V5. 实施前必须先建 / 先定的清单（TL 问"还缺什么"）

**A. 先建（顺序敏感，**全部先于构建**）**：
1. `tb_app_rx_mirror.v`（单元门：字节压缩 / keep=0 拍 / 溢出按字节计 / **写门不丢字**（慢读者压满）+ 负对照）。
2. `sim/p6e_pcie/tb_p6e_pcie_wrapper.v` 的**新断言组** = §V1.1 的 6 条（**双向牙**）+ 两条几何常量同改（`:149` / `:339`）。
3. `tb/tb_fifo_async.v` 第 5 case（`32×256` + `6.4ns:4ns` 频率对）。
4. **读侧脚本重生成**（`_proj_10g/notes/p7b_buildF/apply_readside.py` 同法：显式清单 + 命中数断言 + A/B/C 结构性断言 + 负对照）——**它是"构建后能读对"的前提**。

**B. 先定（冻结后才可开构建）**：
1. 窗口/地址布局表（§V1.1 的 localparam 五件套 + `0x148` 负对照）；
2. `MIR_CTRL` 位语义 + clear/enable 顺序协议（§V1.3）；
3. `MIR_STATUS` 的 32 位位域（§V3-③ 的 32 位拼法，写完**数一遍**）；
4. `drop_bytes` 语义 = **字节数**、dp 域、源 = 单一（W70）；
5. 发端工具改动规格 = `--bytes N` + `N%4==0` 硬断言 + ppos-续发；
6. `¬DP_156MHZ` 的 tie-off 常量表（§V1.4）；
7. `clr` 的 toggle 实现与其门内断言（"一次写 ⇒ 恰好一个 dp 脉冲"）。

**C. 板上零成本现核（可与上面并行）**：`ls /dev/xdma*`（顺带一次回答 (A) 的入口问题 ①）。

**D. 仍未定/不由本件裁定**：④（真需构建）· ⑦（真需上板）· N1–N4。

---

## V6. 行号勘误表（v1 vs 本块现读；v1 原文保留，以本块为准）

| v1 处 | v1 写 | **本块现读** | 备注 |
|---|---|---|---|
| §1.1 ⑥ | `READINGS.txt:115` | **`:113`** | 审查 §5 指出的漂移；本块现读确认 `Source: ... (FDPE, pcie_axi_aclk 250MHz)` 行在 **113**；`:107` = DP 域 `+0.281` 行 |
| §1.6 / §5 索引 | stub `:14-16` | **`:12-15`**（任务说明）；任务实体 = `:166-194` | 内容（`axil_read/axil_write` 两个层次任务）逐字相符 |
| §1.6 / §5 索引 | stub `:31-32` | **`:36`** | 现读 `// ---- m_axi (本设计不用; 与真 IP 同名同位宽, 替身不驱动) ----` |
| §5 索引 | `udp_split` app 口 `2311-2342` | **`:2334-2342`** | `:2311` 现读是 `wire app_udp_rx_tready;` |
| §3.3（**内容错**，非行号）| `rd_pop = (r_word == 7'd72)` | 正确 = `MIR_DATA_IDX = SNAP_LAST_IDX + 2`（字号 **80**）| S1；见 §V1.1 |
| §3.3（**内容错**）| "快照 70→71、`MIR_STATUS`=0x13C、`MIR_DATA`=0x140、未实现=0x144" | 同上（**+`MIR_CTRL`=0x144**，未实现 = **0x148**）| §V1.1/§V1.3 |
| §3.2（**内容删**）| "跨段续用累加器 + 末字含 1–3 填充字节 + 按 W53 截断" | **删除**；改前置条件 `K%4==0` | §V1.2 |
| §3.3（**内容错**）| `MIR_STATUS` 位域示例（38 位）| 32 位拼法 | §V2-S7-③ |

**本块新引（全部本块现读）**：`axi_regs.v:137`（`localparam integer SNAP_LAST_IDX = 8 + SNAP_NW - 1;`）· `:155/:196`（`w_word`/`ar_word` 7 位）· `:174-179`（SCRATCH wstrb 写法）· `:302-311`（AR 握手 + 装载分支）· `:308`（SLVERR 判据）· `.xci:121`（`axil_master_prefetchable=false`）· `fifo_async.v:17-19 / 41-45 / 55-58 / 116 / 130-135 / 140-141 / 229 / 285` · `run_tb_p6e_pcie.bat:11-13` · `tb_p6e_pcie_wrapper.v:149 / 339` · `p5wrapper_src.f:3-8 / 40 / 43` · `p7b_tcp_src.cpp:120 / 129 / 155` · `p7b_pattern.h:147` · `p7b_io.h:8-13`（三种 send 语义边界）· `xdma_0_sim_netlist.v:18 / :2860`（`wc -l` = 329,499）· `wrapper_p4.v:2312 / 2314`（UDP 8081 / 8080 留 HLS）。

---

*本块 = v2 修订，与 v1 正文同文件并存（v1 可追溯）。落笔实施前：先走 §V5 的 A/B 清单（门与冻结项**先于构建**），再按 `board/run_build_p7b_ku5p.bat` 一次构建收口。*
