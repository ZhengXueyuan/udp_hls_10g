@echo off
REM run_tb_p5_flow.bat -- P5b 窗口闭环门 (tb_p5_app.v -d P5_FLOW, 慢消费者 + 对端灌数据)
REM
REM 判据 (tools/gen_stim_p5_app.py flow, 规格 §3):
REM   ① 逐拍占用 occ <= winq + 2816 + 1518 (C1b 的 Δ) 且硬界 occ < 65528
REM   ② mac_rx_64.stat_drop == 0   ③ 通告右沿抖动有界 (512B; 安全界 = 接受裕度 4096B)
REM      (右沿严格单调在本设计下结构性不成立: right = ack + window 两字段采样时刻不同;
REM       真正安全条件是"抖动 < 接受裕度 ACC_MARGIN", checker 已按此加硬断言)
REM   ④ 窗 <= 1 段 (对端停发) -> 恢复 -> 零重传完成 (图案逐字节; 见 C23 措辞)  ⑤ stat_fc_upd>0 + 活性
REM
REM 独立工作目录 sim\p5sim\flowrun (工程铁律: 残留 xsim 进程占 xsim.dir 会让门假失败)
cd /d %~dp0
set PY=C:\Users\zhxue\anaconda3\python.exe
set XV=C:\AMDDesignTools\2025.2\Vivado\bin
set RTL=D:\repo\ECO\udp_hls_10g\rtl
set TB=D:\repo\ECO\udp_hls_10g\tb
set BD=D:\repo\ECO\udp_hls_10g\board
set TOOL=D:\repo\ECO\udp_hls_10g\tools
set SIM=D:\repo\ECO\udp_hls_10g\sim\p5sim\flowrun

if not exist "%SIM%" mkdir "%SIM%"
cd /d "%SIM%"

%PY% %TOOL%\gen_stim_p5_app.py %SIM% || exit /b 1

call %XV%\xvlog.bat -work xil_defaultlib -d P5_FLOW ^
  %RTL%\crc32_8b.v ^
  %RTL%\fifo_sync.v ^
  %RTL%\checksum16.v ^
  %RTL%\frame_fifo.v ^
  %RTL%\mac_rx_64.v ^
  %RTL%\mac_tx_64.v ^
  %RTL%\tcp_cam.v ^
  %RTL%\tcb.v ^
  %RTL%\tcp_rx.v ^
  %RTL%\tcp_tx_frame.v ^
  %RTL%\retx_ram.v ^
  %RTL%\tcp_echo.v ^
  %RTL%\axis_pipe.v ^
  %RTL%\rx_classify.v ^
  %RTL%\vlan_strip.v ^
  %RTL%\slow_cfg_adp.v ^
  %RTL%\udp_rx.v %RTL%\udp_split.v ^
  %RTL%\udp_tx_cfg.v %RTL%\udp_tx_frame.v ^
  %RTL%\tx_arb.v ^
  %RTL%\app_ctrl.v ^
  %RTL%\app_pattern.v ^
  %RTL%\app_status_uart.v ^
  %BD%\uart_dbg.v ^
  %TB%\tb_app_sink.v ^
  %TB%\tb_p5_app.v > xvlog_flow.log 2>&1 || (type xvlog_flow.log & exit /b 1)
call %XV%\xvlog.bat -work xil_defaultlib "%XV%\..\data\verilog\src\glbl.v" >> xvlog_flow.log 2>&1 || (type xvlog_flow.log & exit /b 1)

call %XV%\xelab.bat -debug typical -L unisims_ver xil_defaultlib.tb_p5_app xil_defaultlib.glbl -s tb_p5_flow -log xelab_flow.log > NUL 2>&1 || (type xelab_flow.log & exit /b 1)
call %XV%\xsim.bat tb_p5_flow -runall -log xsim_flow.log > NUL 2>&1 || (type xsim_flow.log & exit /b 1)

%PY% %TOOL%\gen_stim_p5_app.py %SIM% flow
