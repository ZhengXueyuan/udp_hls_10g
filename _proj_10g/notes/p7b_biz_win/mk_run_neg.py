# mk_run_neg.py -- 生成 run_neg.bat (ASCII-only, CRLF) + 3 个 axi_regs 变异体
#   ⚠️ 三个"生成器级"纪律 (都是本轮实测踩到后固化进来的, 别在 .bat 里手改后忘了回填):
#     ① 重定向日志**不能叫 `xvlog.log`** —— 那是 xvlog 自己的默认日志名 ⇒ 句柄冲突
#        (CRITICAL WARNING: [Common 17-183] Failed to open handle xvlog.log)
#     ② **FATAL 分支必须计失败** —— 否则"什么都没跑"会被报成 NEG_GATE_PASS (假通过)
#     ③ `set GOT=PASS ` 的**尾随空格**会被 cmd 保留 ⇒ `==` 比较永假 (用 `(set ...)` 包起来)
import io, os

bat = (
"@echo off\r\n"
"REM ===========================================================================\r\n"
"REM run_neg.bat -- P7B-BIZ: prove run_tb_biz_win has teeth (mutation test)\r\n"
"REM   Three mutants of axi_regs.v, each = one defect this project has suffered:\r\n"
"REM     mut_base6   : snap_base narrowed to [5:0]   (high words wrap silently)\r\n"
"REM     mut_dec6    : ar_word/r_word back to 6 bits (0x100 aliases to word 0)\r\n"
"REM     mut_lastoff : SNAP_LAST_IDX off by one      (window boundary shifted)\r\n"
"REM   Expectation: mutants FAIL, the real file PASSES. Exit 0 iff so.\r\n"
"REM   ASCII-only on purpose (project rule for .bat).\r\n"
"REM ===========================================================================\r\n"
"setlocal enabledelayedexpansion\r\n"
"set XV=C:\\AMDDesignTools\\2025.2\\Vivado\\bin\r\n"
"set D=%~dp0\r\n"
"set TB=%D%tb_biz_win.v\r\n"
"set NBAD=0\r\n"
"call :one \"real\"       \"%D%..\\..\\..\\_proj_pcie\\rtl\\axi_regs.v\" PASS\r\n"
"call :one \"mut_base6\"  \"%D%neg\\axi_regs_mut_base6.v\"        FAIL\r\n"
"call :one \"mut_dec6\"   \"%D%neg\\axi_regs_mut_dec6.v\"         FAIL\r\n"
"call :one \"mut_lastoff\" \"%D%neg\\axi_regs_mut_lastoff.v\"     FAIL\r\n"
"echo.\r\n"
"if %NBAD% NEQ 0 ( echo NEG_GATE_FAIL %NBAD% & exit /b 1 )\r\n"
"echo NEG_GATE_PASS 4/4\r\n"
"exit /b 0\r\n"
"\r\n"
":one\r\n"
"set TAG=%~1\r\n"
"set SRC=%~2\r\n"
"set WANT=%~3\r\n"
"set WD=%D%neg\\w_%TAG%\r\n"
"if not exist \"%WD%\" mkdir \"%WD%\"\r\n"
"pushd \"%WD%\"\r\n"
"REM NOTE: log name must NOT be xvlog.log (that is xvlog's own default log -> handle clash)\r\n"
"call \"%XV%\\xvlog.bat\" -work xil_defaultlib \"%SRC%\" \"%TB%\" > xv_biz.log 2>&1\r\n"
"if errorlevel 1 ( echo [BAD ] %TAG% xvlog-fatal & type xv_biz.log & popd & set /a NBAD+=1 & exit /b 0 )\r\n"
"call \"%XV%\\xvlog.bat\" -work xil_defaultlib \"%XV%\\..\\data\\verilog\\src\\glbl.v\" >> xv_biz.log 2>&1\r\n"
"call \"%XV%\\xelab.bat\" -debug typical -L unisims_ver xil_defaultlib.tb_biz_win xil_defaultlib.glbl -s tb -log xelab_biz.log > NUL 2>&1\r\n"
"if errorlevel 1 ( echo [BAD ] %TAG% xelab-fatal & popd & set /a NBAD+=1 & exit /b 0 )\r\n"
"call \"%XV%\\xsim.bat\" tb -runall -log xsim_biz.log > NUL 2>&1\r\n"
"REM NOTE: keep the parens -- a trailing space in the value breaks the compare below\r\n"
"findstr /C:\"PASS_ALL\" xsim_biz.log >NUL && (set GOT=PASS) || (set GOT=FAIL)\r\n"
"popd\r\n"
"if \"!GOT!\"==\"%WANT%\" ( echo [OK  ] %TAG% got=!GOT! want=%WANT% ) else ( echo [BAD ] %TAG% got=!GOT! want=%WANT% & set /a NBAD+=1 )\r\n"
"exit /b 0\r\n"
)
assert bat.isascii(), "bat must be ASCII"
io.open('_proj_10g/notes/p7b_biz_win/run_neg.bat', 'w', encoding='ascii', newline='').write(bat)

src = io.open('_proj_pcie/rtl/axi_regs.v', encoding='utf-8', newline='').read()
os.makedirs('_proj_10g/notes/p7b_biz_win/neg', exist_ok=True)
muts = {
 'axi_regs_mut_base6.v':  ("wire [11:0] snap_base   = {snap_idx, 5'b0};",
                           "wire [5:0] snap_base   = {snap_idx, 5'b0};"),
 'axi_regs_mut_dec6.v':   ("wire [6:0] ar_word = s_axil_araddr[8:2];",
                           "wire [5:0] ar_word = s_axil_araddr[7:2];"),
 'axi_regs_mut_lastoff.v':("localparam integer SNAP_LAST_IDX = 8 + SNAP_NW - 1;",
                           "localparam integer SNAP_LAST_IDX = 8 + SNAP_NW - 2;"),
}
for name, (a, b) in muts.items():
    assert a in src, name
    io.open('_proj_10g/notes/p7b_biz_win/neg/' + name, 'w', encoding='utf-8', newline='').write(src.replace(a, b))
p = '_proj_10g/notes/p7b_biz_win/neg/axi_regs_mut_dec6.v'
s = io.open(p, encoding='utf-8', newline='').read()
# ⚠️ 2026-10-07 "台架修复轮": 这一处原来是**裸 replace** —— 锚点若因 RTL 改动而消失,
#    变异体会**静默退化成"与真文件一样"** ⇒ 负对照假通过 (本工程"判据安静失效"老坑)。
assert "reg [6:0]  r_word;" in s, "mut_dec6 第二处锚点不在 ⇒ 拒绝产出假变异体"
s = s.replace("reg [6:0]  r_word;", "reg [5:0]  r_word;")
io.open(p, 'w', encoding='utf-8', newline='').write(s)
# 变异体必须**真的与真文件不同** (上一条 assert 的同族守卫: 三个变异体逐个核)
for name in muts:
    m = io.open('_proj_10g/notes/p7b_biz_win/neg/' + name, encoding='utf-8', newline='').read()
    assert m != src, "%s 与真文件逐字相同 ⇒ 变异体无效 (负对照会假通过)" % name
print("written")
