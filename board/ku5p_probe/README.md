# ku5p_probe/ — P6a-T2 前置实证的产物（都是证据，不是构建脚本）

本目录回答一个问题：**RGMII 前端在 KU5P 上应该怎么写**。三条实证，逐条可复跑。

| 文件 | 作用 | 复跑 |
|---|---|---|
| `idly_probe.v/.xdc` | **决定性实验**：IBUF+BUFG+MMCME4+IDELAYCTRL+IDELAYE3+IDDRE1+ODDRE1 挂**真实 RGMII 引脚**（bank 86）做综合/布局 | `run_idly_probe.bat` |
| `idly_probe.log` | 结果：synth/opt 过，`place_design` 报 **`ERROR: [DRC PLHDIO-6] … IDelay and ISerDes … not supported in HDIO`** ⇒ **KU5P 的 RGMII 引脚放不了 IDELAYE3** | 同上 |
| `bank_probe.tcl/.log` | 引脚→bank 普查：**RGMII/MDIO 全在 bank 86 = HDIO**；SYS_CLK T25/U25 = bank 65（HP） | `run_bank_probe.bat` |
| `site_probe.tcl/.log` | site 类型普查：bank 86 的 site 是 `HDIOB_M/S`（无 BUFIO/BUFR，delay 元件挂在 IOB 内） | `run_site_probe.bat` |
| `eth_led_rxdly_right.png` | **底板原理图出图**：`LED2/RXDLY`(pin32) → **R52 10k → VDD3.3** ⇒ **RXDLY=1** | 见下「出图方法」 |
| `eth_rxd_straps_left.png` | **底板原理图出图**：`RXD[1]/TXDLY`(pin16) → **R51 10k → VDD3.3** ⇒ **TXDLY=1** | 同上 |
| `eth_page_overview.png` | 底板 ETH 页全景（含 `PHY_ADDR[2:0]=001` 注记 ⇒ PHY 地址 1） | 同上 |
| `phy_fig32_txc.png` / `phy_fig33_rxc.png` | RTL8211E 手册 10.6.5 的 RGMII Timing 图（TXDLY=1 时"源端边沿对齐、PHY 内部延迟采样"） | 同上 |

## 出图方法（原理图 PDF 文本层是错位叠加的，**不能 grep 判读**）
poppler 本机无 `pdftoppm`，用 Anaconda 的 PyMuPDF：
```python
import pymupdf
d = pymupdf.open(r"图纸\底板\XCKU5PMini底板.pdf"); p = d[1]      # ETH 页
r = pymupdf.Rect(200, 275, 320, 330)                              # search_for() 拿坐标
p.get_pixmap(matrix=pymupdf.Matrix(20, 20), clip=r).save("crop.png")
```
⚠️ 若该页有 `rotation`，先 `p.set_rotation(0)`，否则 clip 坐标与 `search_for()` 不一致。

## 结论（写进 `board/util_gmii_to_rgmii_us.v` 头注释）
**KU5P 的 RGMII 前端 = 零 IDELAY**：RX `IBUF→BUFG→IDDRE1`，TX `ODDRE1` 边沿对齐。
不需要 IDELAYE3 / IDELAYCTRL / 300MHz MMCM。详见该文件头注释与
`tb/tb_rgmii_phy_model.v`（行为级 RTL8211E 模型 + 往返逐字节一致判据）。
