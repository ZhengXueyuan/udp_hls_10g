| # | 门 | 命令 | EXIT | 判据行（日志尾） | 判定 | 归因 |
|---|---|---|---|---|---|---|
| 1 | `p4_matrix16` | `sim\p4gates\run_matrix_p4dfix.bat` | 0 | GATE unit_uart EXIT=0 | PASS(哑门) |  |
| 2 | `p5_app` | `sim\p5sim\run_tb_p5_app.bat` | 0 | P5 APP OK | PASS |  |
| 3 | `p5_app_close` | `sim\p5sim\run_tb_p5_app.bat close` | 1 | P5 CLOSE FAIL (2 ��) | FAIL | 既存 |
| 4 | `p5_wrapper` | `sim\p5sim\run_tb_p5_wrapper.bat` | 1 | P5 WRAPPER FAIL (1 ��) | FAIL | 既存 |
| 5 | `p5_status` | `sim\p5sim\run_tb_p5_status.bat` | 0 | P5 STATUS OK | PASS |  |
| 6 | `p5_adv_len` | `sim\p5sim\run_tb_p5_adv.bat len` | 0 | P5 ADV[len] OK | PASS |  |
| 7 | `p5_adv_b2b` | `sim\p5sim\run_tb_p5_adv.bat b2b` | 0 | P5 ADV[b2b] OK | PASS |  |
| 8 | `p5_adv_wnd` | `sim\p5sim\run_tb_p5_adv.bat wnd` | 0 | P5 ADV[wnd] OK | PASS |  |
| 9 | `p5_adv_fin` | `sim\p5sim\run_tb_p5_adv.bat fin` | 0 | P5 ADV[fin] OK | PASS |  |
| 10 | `p5_adv_findrop` | `sim\p5sim\run_tb_p5_adv.bat findrop` | 0 | P5 ADV[findrop] OK | PASS |  |
| 11 | `p5_adv_abort` | `sim\p5sim\run_tb_p5_adv.bat abort` | 0 | P5 ADV[abort] OK | PASS |  |
| 12 | `p5_adv_evfifo` | `sim\p5sim\run_tb_p5_adv.bat evfifo` | 0 | P5 ADV[evfifo] OK | PASS |  |
| 13 | `p5_adv_reconn_fast` | `sim\p5sim\run_tb_p5_adv.bat reconn_fast` | 0 | P5 ADV[reconn_fast] OK | PASS |  |
| 14 | `p5_adv_reconn_slow` | `sim\p5sim\run_tb_p5_adv.bat reconn_slow` | 0 | P5 ADV[reconn_slow] OK | PASS |  |
| 15 | `p5_adv_multi` | `sim\p5sim\run_tb_p5_adv.bat multi` | 0 | P5 ADV[multi] OK | PASS |  |
| 16 | `p5_adv_accmgn` | `sim\p5sim\run_tb_p5_adv.bat accmgn` | 0 | P5 ADV[accmgn] OK | PASS |  |
| 17 | `p5_fc` | `sim\p5sim\run_tb_p5_fc.bat` | 0 | P5 FC UNIT GATE PASS | PASS |  |
| 18 | `p5_flow` | `sim\p5sim\run_tb_p5_flow.bat` | 0 | P5 FLOW OK (���ڱջ�: ����->�յ� <= 1 ��(�Զ�ͣ��)->�ؿ�->���ش����) | PASS |  |
| 19 | `p5_pattern` | `sim\p5sim\run_tb_p5_pattern.bat` | 0 | P5 PATTERN FAIL viol=0 last_beats=2 keep_bad=1 active=0 | PASS |  |
| 20 | `p5close` | `sim\p5close\run_tb_tcp_close.bat` | 0 | GATE tb_close_g9: DONE (verdict_fail=0) | PASS |  |
| 21 | `p5d_multi_main` | `sim\p5d_multi\run_tb_p5_multi.bat main` | 0 | == P5d multi: 122 checks, 0 FAIL == | PASS |  |
| 22 | `p5d_multi_idle` | `sim\p5d_multi\run_tb_p5_multi.bat known_idle_fifo` | 0 | [probe] 失配字节=0 kaerr=0 evfrm=0 sink=73728 occ=0 accepted=73728 | PASS |  |
| 23 | `p5d_multi_neg_wq` | `sim\p5d_multi\run_tb_p5_multi.bat neg_wq` | 1 | - ① 连接 2 winq=0x0000 != WIN_POOL/N=0x4000 (neg_wq 被写成 0xC000 ⇒ 本条必须 FAIL) | PASS(期望非零) |  |
| 24 | `p5d_multi_neg_mgn` | `sim\p5d_multi\run_tb_p5_multi.bat neg_mgn` | 1 | == P5d multi: 112 checks, 7 FAIL == | PASS(期望非零) |  |
| 25 | `p5d_multi_neg_mgn0` | `sim\p5d_multi\run_tb_p5_multi.bat neg_mgn0` | 1 | - ⑥ MULDONE tmo=0 (got {'tmo': 1, 'k': 2558285}) | PASS(期望非零) |  |
| 26 | `p5d_d1` | `sim\p5d_d1\run_tb_p5d_d1.bat` | 0 | PASS D1a-3 stat_bytes=8 (plen ok) | PASS |  |
| 27 | `p5e_win` | `sim\p5e_win\run_tb_p5e_win.bat` | 0 | payload 27740 / mismatch 0 / app stat_tx_bytes=27740 stat_tx_frames=21 | PASS |  |
| 28 | `p5c_fence` | `sim\p5c_t3\run_tb_p5c_fence.bat` | 0 | P5C-T3 FENCE GATE PASS | PASS |  |
| 29 | `p5c_rev_g2g3` | `sim\p5c_t3\rev\run_tb_rev_g2g3.bat` | 0 | GATE tb_rev_g2g3: PASS (errs=0) | PASS |  |
| 30 | `p5c_rev_elab` | `sim\p5c_t3\rev\run_wrapper_elab_chk.bat` | 0 | DONE (logs: wchk\xv_a.log xv_b.log xe_a.log xe_b.log) | PASS(哑门) |  |
| 31 | `p5udp_split` | `sim\p5udp\run_tb_udp_split.bat` | 0 | P5 UDP SPLIT UNIT GATE PASS | PASS |  |
| 32 | `p5e_t2_guard` | `sim\p5e_t2\run_tb_udp_tx_guard.bat` | 0 | P5E-T2 GUARD GATE: OK (frames=6 drop_len=2 deny=2 neg_fifo_occ=256 neg_sready=0) | PASS |  |
| 33 | `p5e_t2_wrapper` | `sim\p5e_t2\run_tb_p5e_t2_wrapper.bat` | 1 | P5E-T2 WRAPPER GATE: FAIL errs=117 | FAIL | 既存 |
| 34 | `p5e_udp_pos` | `sim\p5e_udp\run_tb_app_udp.bat pos` | 0 | P5E UDP APP GATE: OK (rx_frames=10 rx_bytes=13305 tx_frames=25 drop_len=1 drop_ovf=5 spl | PASS |  |
| 35 | `p5e_udp_splitoff` | `sim\p5e_udp\run_tb_app_udp.bat splitoff` | 0 | P5E UDP APP GATE: OK (neg mode) | PASS |  |
| 36 | `p5e_udp_portout` | `sim\p5e_udp\run_tb_app_udp.bat portout` | 1 | P5E UDP APP GATE: OK (neg mode) | FAIL | 偶发 |
| 37 | `p5e_udp_badcrc` | `sim\p5e_udp\run_tb_app_udp.bat badcrc` | 0 | P5E UDP APP GATE: OK (neg mode) | PASS |  |
| 38 | `p5e_udp_nopeer` | `sim\p5e_udp\run_tb_app_udp.bat nopeer` | 0 | P5E UDP APP GATE: OK (NOPEER: TX 零帧, meta 脉冲 0) | PASS |  |
| 39 | `p5e_udp_neglearn` | `sim\p5e_udp\run_tb_app_udp.bat neglearn` | 1 | P5E UDP APP GATE: FAIL errs=104 | PASS(期望非零) |  |
| 40 | `p5e_udp_wrapper` | `sim\p5e_udp\run_tb_p5e_udp_wrapper.bat` | 1 | P5E-T5 UDP WRAPPER GATE: FAIL errs=1489 | FAIL | 既存 |
| 41 | `p5e_pre_split` | `sim\p5e_pre\run_tb_p5_udp_split.bat` | 0 | P5e UDP SPLIT GATE: PASS | PASS |  |
| 42 | `p5e_rate` | `sim\p5e_rate\run_tb_rate.bat` | 0 | app tx_frames=41 bytes=61112 \| utx frames=40 bytes=58880 drop=0 \| mac frames=40 abort=0 | PASS |  |
| 43 | `p5b_flowwnd` | `sim\p5b_adv\run_tb_p5b_flowwnd.bat` | 1 | ValueError: invalid literal for int() with base 16: '0000000X' | FAIL | 既存 |
| 44 | `p5b_ind` | `sim\p5b_adv\run_tb_p5b_ind.bat` | 1 | ERROR: [XSIM 43-3322] Static elaboration of top level Verilog design unit(s) in library  | FAIL | 既存 |
| 45 | `p5dx_d6_ctr` | `sim\p5dx_d6\run_ctr.bat` | 0 | done | PASS |  |
| 46 | `p3_cam_tcb` | `sim\p3sim\run_tb_cam_tcb.bat` | 0 | ALL_OK steps=11 | PASS |  |
| 47 | `p3_tcp_chain` | `sim\p3sim\run_tb_tcp_chain.bat` | 1 | MISMATCH (14) | FAIL | 既存 |
| 48 | `p3_tcp_echo` | `sim\p3sim\run_tb_tcp_echo.bat` | 1 | ECHO FAIL (10 errs) | FAIL | 既存 |
| 49 | `p3_tcp_rx` | `sim\p3sim\run_tb_tcp_rx.bat` | 1 | hard: 92 lines, stats {'pss': 15, 'nonmatch': 6, 'ipcsum': 1, 'crc': 0, 'seq': 5, 'ack': | FAIL | 既存 |
| 50 | `p3_tcp_tx` | `sim\p3sim\run_tb_tcp_tx.bat` | 1 | MISMATCH | FAIL | 既存 |
| 51 | `clkgen_p6b` | `sim\clkgen\run_tb_clk_gen_p6b.bat` | 0 | PASS_ALL | PASS |  |
| 52 | `echosim` | `sim\echosim\run_tb_echo.bat` | 0 | DONE echo=20 drop_crc=1 tx_frames=20 tx_bytes=1823 \| rx pass=20 | PASS |  |
| 53 | `f2chk` | `sim\f2chk\run_f2chk.bat` | 0 | ** rcv_nxt MISMATCH: dut=00001000 tb=000035cc | PASS |  |
| 54 | `f4chain` | `sim\f4chain\run_tb_f4_chain.bat` | 0 | F4CHAIN_DONE | PASS |  |
| 55 | `f4_mac` | `sim\f4sim\run_tb_f4_mac.bat` | 0 | F4-GATE-RESULT: PASS_ALL | PASS |  |
| 56 | `f4_ab` | `sim\f4sim\run_f4_ab.bat` | 0 | F4-AB-RESULT: PASS | PASS |  |
| 57 | `f4_bitexact` | `sim\f4sim\run_f4_bitexact.bat` | 0 | BITEXACT-RESULT: PASS (交付词流逐位相同) | PASS |  |
| 58 | `f4_sttrace` | `sim\f4sim\run_f4_sttrace.bat` | 0 | (无输出) | PASS(哑门) |  |
| 59 | `f4_regress` | `sim\f4sim\run_tb_mac_f4regress.bat` | 1 | MAC--RESULT: FAIL | FAIL | 既存 |
| 60 | `f4_suite` | `sim\f4sim\run_f4_suite.bat` | 0 | SUITE DONE | PASS |  |
| 61 | `ff_idle` | `sim\fffix\run_tb_ff_idle.bat` | 0 | PASS_ALL tb_ff_idle: wr=394014 pop=357706 cyc=787650 | PASS |  |
| 62 | `fifo_async` | `sim\fifoasync\run_tb_fifo_async.bat` | 0 | FIFO_ASYNC_GATE: PASS_ALL (case=BAL) | PASS |  |
| 63 | `fifoasync_all` | `sim\fifoasync\run_all.bat` | 0 | FIFO_ASYNC_GATE_ALL: OK | PASS |  |
| 64 | `rxp_diag` | `sim\rxpdiag\run_tb_rxp_diag.bat` | 0 | RXP-DIAG GATE: OK | PASS |  |
| 65 | `rxp_v3` | `sim\rxpdiag\run_tb_rxp_v3.bat` | 0 | RXP-V3 GATE: OK | PASS |  |
| 66 | `rxp_v4` | `sim\rxpdiag\run_tb_rxp_v4.bat` | 0 | RXP-V4 GATE: OK | PASS |  |
| 67 | `rxp_v5` | `sim\rxpdiag\run_tb_rxp_v5.bat` | 0 | RXP-V5 GATE: OK | PASS |  |
| 68 | `rxp_v6` | `sim\rxpdiag\run_tb_rxp_v6.bat` | 0 | RXP-V6 GATE: OK | PASS |  |
| 69 | `rxp_v7` | `sim\rxpdiag\run_tb_rxp_v7.bat` | 0 | RXP-V7 GATE: OK | PASS |  |
| 70 | `rxsim_udp_rx` | `sim\rxsim\run_tb_udp_rx.bat` | 0 | DONE pass=20 nonmatch=6 ipcsum=1 crc=1 bytes=404 \| mac fr=27 crc=1 drop=6 | PASS |  |
| 71 | `txsim_udp_tx` | `sim\txsim\run_tb_udp_tx.bat` | 0 | DONE frames=20 bytes=1823 | PASS |  |
| 72 | `udprx` | `sim\udprx\run_tb_udprx.bat` | 0 | UDPRX RATE GATE: OK (PLEN=1472 NFRM=200 WSP=8) | PASS |  |
| 73 | `udprx_chain` | `sim\udprx_chain\run_tb_udprx_chain.bat` | 0 | UDPRX CHAIN GATE: OK (PLEN=1472 NFRM=200 IDLE=12) | PASS |  |
| 74 | `run_tb_tx` | `sim\run_tb_tx.bat` | 1 | --xsimdir            : Location of xsim.dir directory. Default location is "." i.e. curr | FAIL | 既存/坏门 |
| 75 | `run_tb_crc` | `sim\run_tb_crc.bat` | 0 | INFO: [Common 17-206] Exiting xsim at Wed Sep 30 13:12:26 2026... | PASS |  |
| 76 | `run_tb_csum` | `sim\run_tb_csum.bat` | 0 | DONE | PASS |  |
| 77 | `snap_cdc` | `sim\snapcdc\run_tb_snap_cdc.bat` | 0 | SNAP_CDC_GATE_ALL: OK (NW=14/22/24/32/36 all PASS_ALL) | PASS |  |
| 78 | `snapseq` | `sim\snapseq\run_tb_snap_seq.bat` | 0 | PASS_ALL  tb_snap_seq: 7 组判据全过 (含顺序负对照) | PASS |  |
| 79 | `snapcdc_atk_phase` | `sim\snapcdc\atk\phase\run_atk_phase.bat` | 0 | PHASE-RESULT HA=2000 HB=4000 STEP=100 valids=326 flips=326 fails=0 PASS | PASS |  |
| 80 | `snapcdc_atk_ratio` | `sim\snapcdc\atk\ratio\run_atk_ratio.bat` | 0 | RATIO-RESULT HA=2000 HB=4000 MODE=1 valids=204 flips=204 fails=0 PASS | PASS |  |
| 81 | `snapcdc_atk_req` | `sim\snapcdc\atk\req\run_atk_req.bat` | 0 | REQ-RESULT HA=2000 HB=4000 valids=306 flips=306 reqs=331 fails=0 PASS | PASS |  |
| 82 | `snapcdc_atk_reset` | `sim\snapcdc\atk\reset\run_atk_reset.bat` | 0 | RESET-RESULT MODE=0 valids=160 flips=240 phantom=0 valdurrst=0 fails=0 PASS | PASS |  |
| 83 | `snapcdc_atk_x` | `sim\snapcdc\atk\xprop\run_atk_x.bat` | 0 | X-RESULT valids=56 xval=20 fails=0 PASS | PASS |  |
| 84 | `snapcdc_t0` | `sim\snapcdc\review\run_t0.bat` | 0 | === done === | PASS |  |
| 85 | `snapcdc_t2` | `sim\snapcdc\review\run_t2.bat` | 0 | === done === | PASS |  |
| 86 | `snapcdc_t3` | `sim\snapcdc\review\run_t3.bat` | 0 | === done === | PASS |  |
| 87 | `snapcdc_skew` | `sim\snapcdc\review\run_skew.bat` | 1 | ERROR: [XSIM 43-3322] Static elaboration of top level Verilog design unit(s) in library  | FAIL | 既存/坏门 |
| 88 | `snapcdc_torture` | `sim\snapcdc\review\run_torture.bat` | 0 | [ok]   ������������������������ | PASS |  |
| 89 | `snapcdc24_axr` | `sim\snapcdc\review24\axr\run.bat` | 0 | PASS_ALL  tb_axi_regs: 22 项判据全过 | PASS |  |
| 90 | `snapcdc24_cdc` | `sim\snapcdc\review24\cdc\run.bat` | 0 | PASS_ALL  tb_snap_cdc: NW=32 判据 0-9 全过 (含负对照 A/B) | PASS |  |
| 91 | `snapcdc24_lint` | `sim\snapcdc\review24\lint\run.bat` | 0 | LINT-DONE | PASS |  |
| 92 | `snapcdc24_p6e` | `sim\snapcdc\review24\p6e\run.bat` | 1 | FAIL      tb_p6e_pcie_wrapper: 1 项失败 | FAIL | 既存 |
| 93 | `snapcdc24_p6e_cnt` | `sim\snapcdc\review24\p6e_cnt\run.bat` | 0 | PASS_ALL  tb_review24_counters | PASS |  |
| 94 | `p6a_ff_us` | `sim\p6a_ku5p\run_tb_frame_fifo_us.bat` | 0 | PASS_ALL  frame_fifo unit: writes A=568139 B=595715 C=616302 pops A=567224 B=591216 C=61 | PASS |  |
| 95 | `p6a_ff_k7` | `sim\p6a_ku5p\run_tb_frame_fifo_k7.bat` | 0 | PASS_ALL  frame_fifo unit: writes A=568139 B=595715 C=616302 pops A=567224 B=591216 C=61 | PASS |  |
| 96 | `p6a_ramb36e2` | `sim\p6a_ku5p\run_tb_ramb36e2_sem.bat` | 0 | === done === | PASS |  |
| 97 | `p6a_rgmii_dbg` | `sim\p6a_ku5p\run_tb_rgmii_dbg.bat` | 0 | === done === | PASS |  |
| 98 | `p6a_rgmii_phy` | `sim\p6a_ku5p\run_tb_rgmii_phy_model.bat` | 0 | VERDICT: K7 前端 FAIL (data TX=0 RX=180)  <= 预期: RX 相位配方不适配 RXDLY=1 | PASS |  |
| 99 | `p6a_preflight` | `sim\p6a_ku5p\pf\run_preflight.bat` | 0 | ==== PREFLIGHT OK (xvlog + xelab clean) ==== | PASS |  |
| 100 | `p6b_lint` | `sim\p6b_lint\lint.bat` | 0 | XELAB-LINT-OK: xelab face ran, log = xelab_lint.log | PASS |  |
| 101 | `p6b_lint_def` | `sim\p6b_lint\lint_def.bat` | 0 | XELAB-LINT-OK: xelab face ran, log = xelab_def.log | PASS |  |
| 102 | `p6e_pcie` | `sim\p6e_pcie\run_tb_p6e_pcie.bat` | 0 | PASS_ALL  tb_p6e_pcie_wrapper: 全链门全过 | PASS |  |
| 103 | `p6e_pcie_cnt` | `sim\p6e_pcie\run_tb_p6e_pcie_counters.bat` | 1 | FAIL      tb_p6e_pcie_counters: 1 项失败 | FAIL | 既存 |
| 104 | `p4_chain_active` | `sim\p4sim\run_tb_p4_chain_active.bat` | 1 | PCACTIVE FAIL (9 errs) | FAIL | 既存 |
| 105 | `p4_chain_active_slow` | `sim\p4sim\run_tb_p4_chain_active_slow.bat` | 1 | PCACTIVE FAIL (9 errs) | FAIL | 既存 |
| 106 | `p4_chain_xk` | `sim\p4sim\run_tb_p4_chain_xk.bat` | 0 | P4 CHAIN OK | PASS |  |
| 107 | `p4_chain_stall_xk` | `sim\p4sim\run_tb_p4_chain_stall_xk.bat` | 0 | PCSTALL OK (burst=200, echo ֡ 240) | PASS |  |
| 108 | `p4_burst_xk` | `sim\p4sim\run_tb_p4_burst_xk.bat` | 0 | BURST OK | PASS |  |
| 109 | `p4_replay` | `sim\p4sim\run_tb_p4_replay.bat` | 0 | ���������ļ��� | PASS(哑门) |  |
| 110 | `p4_rxclass` | `sim\p4sim\run_tb_rxclass.bat` | 1 | ERROR: [XSIM 43-3322] Static elaboration of top level Verilog design unit(s) in library  | FAIL | ★真回归 |
| 111 | `p4_rxclass_xk` | `sim\p4sim\run_tb_rxclass_xk.bat` | 1 | ERROR: [XSIM 43-3322] Static elaboration of top level Verilog design unit(s) in library  | FAIL | ★真回归 |
| 112 | `p4_slowrx` | `sim\p4sim\run_tb_slowrx.bat` | 0 | DONE commit=1 drop=0 | PASS |  |
| 113 | `p4_slowtx` | `sim\p4sim\run_tb_slowtx.bat` | 0 | tb_slow_tx: PASS | PASS |  |
| 114 | `p4_txarb` | `sim\p4sim\run_tb_txarb.bat` | 0 | tb_tx_arb: PASS | PASS |  |
| 115 | `p4_probe` | `sim\p4sim\run_probe.bat` | 1 | XVLOG_FAIL | FAIL | 既存/坏门 |
| 116 | `p4_hlsprobe` | `sim\p4sim_hlsprobe\run_hls_udp_probe.bat` | 1 | FAIL: udp echo fcs bad | FAIL | 既存 |
| 117 | `p4indm_4gates` | `sim\p4indm\run_4gates.sh` | 0 | (无输出) | PASS(哑门) |  |
| 118 | `d2_suite` | `sim\d2run\run_suite_d2.bat` | 0 | (无输出) | PASS(哑门) |  |
| 119 | `p4gates_selfcheck` | `sim\p4gates\implicit_gate_selftest.bat` | 0 | SELFTEST_RESULT = PASS_ALL (9 controls: 4 pathological FAIL, 4 clean PASS, 1 missing-log | PASS |  |
| 120 | `p5d_mech` | `sim\p5d_multi\p5dmech\run_mech.bat` | 1 | FAIL PROBE: 长只写后首读必须逐字节精确 (miss==0) —— 非 0 即 TB 激励竞争复现 (先查 tb_p5_multi.v 是否有新的阻塞写命令) 或读侧 | FAIL | 既存 |
| 121 | `p5d_mechf` | `sim\p5d_multi\p5dmech\run_mechf.bat` | 0 | [probe] 失配字节=0 kaerr=0 evfrm=0 sink=73728 occ=0 accepted=73728 | PASS |  |
| 122 | `p7b_mac` | `_proj_10g\p7b_mac\sim\run_tb_mac_10g.bat` | 0 | VERDICT = PASS | PASS(哑门) |  |
| 123 | `p7b_chain` | `_proj_10g\p7b_chain\sim\run_tb_p7b_chain.bat` | 0 | VERDICT = PASS | PASS(哑门) |  |
| 124 | `p7b_appsplit` | `_proj_10g\p7b_appsplit\sim\run_tb_p7b_appsplit.bat` | 0 | ==== tb_p7b_appsplit done: 26 checks, 0 fail ==== | PASS |  |
| 125 | `p7b_rxcls_v2` | `_proj_10g\p7b_rxcls\sim\run_tb_rxcls_v2.bat` | 0 | === tb_rxcls_v2 done: 206 checks, 0 fail === | PASS |  |
| 126 | `p7b_rxcls_legacy` | `_proj_10g\p7b_rxcls\sim\run_legacy_tb_rxclass.bat` | 0 | [LEGACY CROSSCHECK] 3 modes run; products in this dir (resp_rc_*.memh) | PASS |  |
| 127 | `p7a_counters` | `_proj_10g\sim\run_tb_p7a_counters.bat` | 0 | GATE-OK | PASS |  |
| 128 | `xxv_pay_sel` | `_proj_10g\xxv_loop\sim\run_sim_pay.bat` | 0 | TB DONE | PASS |  |
| 129 | `pci_axi_regs` | `_proj_pcie\run_tb_axi_regs.bat` | 0 | PASS_ALL  tb_axi_regs: 22 项判据全过 | PASS |  |
| 130 | `p7b_lanefix_dbg` | `_proj_10g\notes\p7b_lanefix\dbg\run_dbg.bat` | 0 | ==== tb_lane4_dbg done ==== | PASS |  |
| 131 | `p7b_lane4` | `_proj_10g\notes\p7b_udp_diag2\sim\run_lane4.bat` | 0 | ==== tb_p7b_appsplit done: 13 checks, 0 fail ==== | PASS |  |
| 132 | `p7b_impl_xvlog_all` | `_proj_10g\notes\p7b_implicit_repro\run_xvlog_all.bat` | 255 | �����﷨����ȷ�� | FAIL | 坏脚本 |
| 133 | `p7b_impl_xelab` | `_proj_10g\notes\p7b_implicit_repro\run_xelab.bat` | 0 | XELAB_RC=1 | PASS |  |
| 134 | `p7b_impl_one` | `_proj_10g\notes\p7b_implicit_repro\run_one.bat` | 0 | XVLOG_RC=1 | PASS(哑门) |  |
| 135 | `p7b_impl_sv` | `_proj_10g\notes\p7b_implicit_repro\run_sv.bat` | 0 | SV_RC=0 | PASS |  |
| 136 | `p7b_impl_fs` | `_proj_10g\notes\p7b_implicit_repro\fs_semantics.bat` | 0 | T3_rc=1 (1 = no hit = good) | PASS |  |
