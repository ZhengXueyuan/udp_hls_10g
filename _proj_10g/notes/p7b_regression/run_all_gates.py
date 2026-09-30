# -*- coding: utf-8 -*-
"""P7b 回归：把本仓全部"门"逐门重跑一遍（只跑 xsim/lint 类，不碰硬件/综合）。

用法:
    python run_all_gates.py [--only NAME[,NAME...]] [--jobs 2] [--list]

约定:
  * 每个门一行 -> 日志写 _proj_10g/notes/p7b_regression/logs/<gate>.log
  * 同一个"目录"里的门串行（xsim.dir 文件锁 / 中间产物不打架）
  * 不同目录的门最多 --jobs 个并发
  * 记录 退出码 + 日志尾（判据行）
"""
import argparse
import io
import os
import re
import subprocess
import sys
import threading
import time
from collections import OrderedDict, defaultdict

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
LOGDIR = os.path.join(HERE, 'logs')

# ---------------------------------------------------------------------------
# 门清单：(name, bat 相对路径, 参数, 期望退出码, 说明)
#   exp='0'   普通门（期望 exit 0）
#   exp='!0'  负对照（期望非零；不算失败）
# ---------------------------------------------------------------------------
G = [
    # ===== P4 默认构建矩阵（16 门，一个入口）=====
    ('p4_matrix16', r'sim\p4gates\run_matrix_p4dfix.bat', [], '0',
     'P4 默认构建回归矩阵 16 门（chain/burst/trunc50/trunc100/halfdrop/'
     'txdrop50/gate4096/dupstorm/pcackoob/vlanchain/vlanburst/stallgate/'
     'unit_retx/unit_fifo/unit_vlan/unit_uart）', 3600),

    # ===== P5 / P5b / P5c / P5d / P5e（app 门）=====
    ('p5_app', r'sim\p5sim\run_tb_p5_app.bat', [], '0', '1MB 图案逐字节', 1200),
    ('p5_app_close', r'sim\p5sim\run_tb_p5_app.bat', ['close'], '0', 'P5c 关闭语义门', 1200),
    ('p5_wrapper', r'sim\p5sim\run_tb_p5_wrapper.bat', [], '0', 'wrapper APP_MODE 全链', 1800),
    ('p5_status', r'sim\p5sim\run_tb_p5_status.bat', [], '0', '220 字符状态行', 900),
    ('p5_adv_len', r'sim\p5sim\run_tb_p5_adv.bat', ['len'], '0', '对抗集 len', 1200),
    ('p5_adv_b2b', r'sim\p5sim\run_tb_p5_adv.bat', ['b2b'], '0', '对抗集 b2b', 1200),
    ('p5_adv_wnd', r'sim\p5sim\run_tb_p5_adv.bat', ['wnd'], '0', '对抗集 wnd', 1200),
    ('p5_adv_fin', r'sim\p5sim\run_tb_p5_adv.bat', ['fin'], '0', '对抗集 fin', 1200),
    ('p5_adv_findrop', r'sim\p5sim\run_tb_p5_adv.bat', ['findrop'], '0', '对抗集 findrop', 1200),
    ('p5_adv_abort', r'sim\p5sim\run_tb_p5_adv.bat', ['abort'], '0', '对抗集 abort', 1200),
    ('p5_adv_evfifo', r'sim\p5sim\run_tb_p5_adv.bat', ['evfifo'], '0', '对抗集 evfifo', 1200),
    ('p5_adv_reconn_fast', r'sim\p5sim\run_tb_p5_adv.bat', ['reconn_fast'], '0', '对抗集 reconn_fast', 1200),
    ('p5_adv_reconn_slow', r'sim\p5sim\run_tb_p5_adv.bat', ['reconn_slow'], '0', '对抗集 reconn_slow', 1200),
    ('p5_adv_multi', r'sim\p5sim\run_tb_p5_adv.bat', ['multi'], '0', '对抗集 multi', 1200),
    ('p5_adv_accmgn', r'sim\p5sim\run_tb_p5_adv.bat', ['accmgn'], '0', '对抗集 accmgn', 1200),
    ('p5_fc', r'sim\p5sim\run_tb_p5_fc.bat', [], '0', 'P5b 池/右沿/回绕/事件撞车 (110 项)', 1200),
    ('p5_flow', r'sim\p5sim\run_tb_p5_flow.bat', [], '0', 'P5b 窗口闭环 + 慢消费者', 1800),
    ('p5_pattern', r'sim\p5sim\run_tb_p5_pattern.bat', [], '0', 'P5 图案门', 1200),
    ('p5close', r'sim\p5close\run_tb_tcp_close.bat', [], '0', 'P5c 定向证伪门 G1/G9', 1200),
    ('p5d_multi_main', r'sim\p5d_multi\run_tb_p5_multi.bat', ['main'], '0', 'P5d 多连接 ①②…⑨', 2400),
    ('p5d_multi_idle', r'sim\p5d_multi\run_tb_p5_multi.bat', ['known_idle_fifo'], '0', '长只写后首读逐字节守卫', 1200),
    ('p5d_multi_neg_wq', r'sim\p5d_multi\run_tb_p5_multi.bat', ['neg_wq'], '!0', '负对照：不分池 ⇒ ① FAIL', 1200),
    ('p5d_multi_neg_mgn', r'sim\p5d_multi\run_tb_p5_multi.bat', ['neg_mgn'], '!0', '负对照：裕度 4096 ⇒ ④ FAIL', 1200),
    ('p5d_multi_neg_mgn0', r'sim\p5d_multi\run_tb_p5_multi.bat', ['neg_mgn0'], '!0', '负对照：裕度 0 ⇒ ⑦ FAIL', 1200),
    ('p5d_d1', r'sim\p5d_d1\run_tb_p5d_d1.bat', [], '0', 'D1 abort 请求窗单元门', 1200),
    ('p5e_win', r'sim\p5e_win\run_tb_p5e_win.bat', [], '0', '0 载荷 opener 窄窗门', 1200),
    ('p5c_fence', r'sim\p5c_t3\run_tb_p5c_fence.bat', [], '0', 'abort fence F1-F5', 1200),
    ('p5c_rev_g2g3', r'sim\p5c_t3\rev\run_tb_rev_g2g3.bat', [], '0', 'P5c rev G2/G3', 1200),
    ('p5c_rev_elab', r'sim\p5c_t3\rev\run_wrapper_elab_chk.bat', [], '0', 'wrapper 例化检查', 600),
    ('p5udp_split', r'sim\p5udp\run_tb_udp_split.bat', [], '0', 'P5e-T1 分流器单元门', 1200),
    ('p5e_t2_guard', r'sim\p5e_t2\run_tb_udp_tx_guard.bat', [], '0', 'P5e-T2 peer 门/PLEN_MAX 守卫', 1200),
    ('p5e_t2_wrapper', r'sim\p5e_t2\run_tb_p5e_t2_wrapper.bat', [], '0', 'P5e-T2 真 wrapper 全链 + 隐式网', 1800),
    ('p5e_udp_pos', r'sim\p5e_udp\run_tb_app_udp.bat', ['pos'], '0', 'UDP 演示 app 正例', 1200),
    ('p5e_udp_splitoff', r'sim\p5e_udp\run_tb_app_udp.bat', ['splitoff'], '0', '负：拆分器关 ⇒ app 0 帧', 1200),
    ('p5e_udp_portout', r'sim\p5e_udp\run_tb_app_udp.bat', ['portout'], '0', '负：端口过滤外', 1200),
    ('p5e_udp_badcrc', r'sim\p5e_udp\run_tb_app_udp.bat', ['badcrc'], '0', '负：坏 FCS ⇒ 整帧丢', 1200),
    ('p5e_udp_nopeer', r'sim\p5e_udp\run_tb_app_udp.bat', ['nopeer'], '0', '负：peer 表空 ⇒ TX 零帧', 1200),
    ('p5e_udp_neglearn', r'sim\p5e_udp\run_tb_app_udp.bat', ['neglearn'], '!0', '负对照（期望 exit 1）：学习源钉 0', 1200),
    ('p5e_udp_wrapper', r'sim\p5e_udp\run_tb_p5e_udp_wrapper.bat', [], '0', 'P5e-T5 真 wrapper 全链 UDP', 1800),
    ('p5e_pre_split', r'sim\p5e_pre\run_tb_p5_udp_split.bat', [], '0', 'P5e-T1 UDP 分流（pre）', 1200),
    ('p5e_rate', r'sim\p5e_rate\run_tb_rate.bat', [], '0', 'UDP app 速率门', 1800),
    ('p5b_flowwnd', r'sim\p5b_adv\run_tb_p5b_flowwnd.bat', [], '0', 'P5b 流窗门', 1200),
    ('p5b_ind', r'sim\p5b_adv\run_tb_p5b_ind.bat', [], '0', 'P5b 独立性门', 1200),
    ('p5dx_d6_ctr', r'sim\p5dx_d6\run_ctr.bat', [], '0', 'D6 计数器门', 600),

    # ===== P3 单元门 =====
    ('p3_cam_tcb', r'sim\p3sim\run_tb_cam_tcb.bat', [], '0', 'CAM+TCB 单元', 300),
    ('p3_tcp_chain', r'sim\p3sim\run_tb_tcp_chain.bat', [], '0', 'TCP 链', 900),
    ('p3_tcp_echo', r'sim\p3sim\run_tb_tcp_echo.bat', [], '0', 'TCP echo', 900),
    ('p3_tcp_rx', r'sim\p3sim\run_tb_tcp_rx.bat', [], '0', 'TCP RX', 600),
    ('p3_tcp_tx', r'sim\p3sim\run_tb_tcp_tx.bat', [], '0', 'TCP TX', 600),

    # ===== 其他 1G 单元门 =====
    ('clkgen_p6b', r'sim\clkgen\run_tb_clk_gen_p6b.bat', [], '0', 'P6b 时钟发生器门', 600),
    ('echosim', r'sim\echosim\run_tb_echo.bat', [], '0', 'udp_echo 单元', 600),
    ('f2chk', r'sim\f2chk\run_f2chk.bat', [], '0', 'F-2 检查', 900),
    ('f4chain', r'sim\f4chain\run_tb_f4_chain.bat', [], '0', 'F4 全链', 1200),
    ('f4_mac', r'sim\f4sim\run_tb_f4_mac.bat', [], '0', 'F4 MAC 门', 900),
    ('f4_ab', r'sim\f4sim\run_f4_ab.bat', [], '0', 'F4 A/B', 900),
    ('f4_bitexact', r'sim\f4sim\run_f4_bitexact.bat', [], '0', 'F4 逐位', 1200),
    ('f4_sttrace', r'sim\f4sim\run_f4_sttrace.bat', [], '0', 'F4 状态轨迹', 900),
    ('f4_regress', r'sim\f4sim\run_tb_mac_f4regress.bat', [], '0', 'MAC F4 回归', 900),
    ('f4_suite', r'sim\f4sim\run_f4_suite.bat', [], '0', 'F4 套件', 2400),
    ('ff_idle', r'sim\fffix\run_tb_ff_idle.bat', [], '0', 'frame_fifo 空闲门', 600),
    ('fifo_async', r'sim\fifoasync\run_tb_fifo_async.bat', [], '0', '异步 FIFO 单元', 600),
    ('fifoasync_all', r'sim\fifoasync\run_all.bat', [], '0', '异步 FIFO 全套', 900),
    ('rxp_diag', r'sim\rxpdiag\run_tb_rxp_diag.bat', [], '0', 'rx path 诊断', 600),
    ('rxp_v3', r'sim\rxpdiag\run_tb_rxp_v3.bat', [], '0', 'rxp v3', 600),
    ('rxp_v4', r'sim\rxpdiag\run_tb_rxp_v4.bat', [], '0', 'rxp v4', 600),
    ('rxp_v5', r'sim\rxpdiag\run_tb_rxp_v5.bat', [], '0', 'rxp v5', 600),
    ('rxp_v6', r'sim\rxpdiag\run_tb_rxp_v6.bat', [], '0', 'rxp v6', 600),
    ('rxp_v7', r'sim\rxpdiag\run_tb_rxp_v7.bat', [], '0', 'rxp v7', 600),
    ('rxsim_udp_rx', r'sim\rxsim\run_tb_udp_rx.bat', [], '0', 'udp_rx 单元', 600),
    ('txsim_udp_tx', r'sim\txsim\run_tb_udp_tx.bat', [], '0', 'udp_tx 单元', 600),
    ('udprx', r'sim\udprx\run_tb_udprx.bat', [], '0', 'udprx 速率门', 900),
    ('udprx_chain', r'sim\udprx_chain\run_tb_udprx_chain.bat', [], '0', 'udprx 全链', 900),
    ('run_tb_tx', r'sim\run_tb_tx.bat', [], '0', 'mac_tx_64 单元', 600),
    ('run_tb_crc', r'sim\run_tb_crc.bat', [], '0', 'CRC 单元', 300),
    ('run_tb_csum', r'sim\run_tb_csum.bat', [], '0', 'checksum16 单元', 300),

    # ===== CDC / 快照门 =====
    ('snap_cdc', r'sim\snapcdc\run_tb_snap_cdc.bat', [], '0', 'snap_cdc 单元', 900),
    ('snapseq', r'sim\snapseq\run_tb_snap_seq.bat', [], '0', '快照序列门', 900),
    ('snapcdc_atk_phase', r'sim\snapcdc\atk\phase\run_atk_phase.bat', [], '0', 'CDC 攻击面 phase', 600),
    ('snapcdc_atk_ratio', r'sim\snapcdc\atk\ratio\run_atk_ratio.bat', [], '0', 'CDC 攻击面 ratio', 600),
    ('snapcdc_atk_req', r'sim\snapcdc\atk\req\run_atk_req.bat', [], '0', 'CDC 攻击面 req', 600),
    ('snapcdc_atk_reset', r'sim\snapcdc\atk\reset\run_atk_reset.bat', [], '0', 'CDC 攻击面 reset', 600),
    ('snapcdc_atk_x', r'sim\snapcdc\atk\xprop\run_atk_x.bat', [], '0', 'CDC 攻击面 X 传播', 600),
    ('snapcdc_t0', r'sim\snapcdc\review\run_t0.bat', [], '0', 'CDC review t0', 600),
    ('snapcdc_t2', r'sim\snapcdc\review\run_t2.bat', [], '0', 'CDC review t2', 600),
    ('snapcdc_t3', r'sim\snapcdc\review\run_t3.bat', [], '0', 'CDC review t3', 600),
    ('snapcdc_skew', r'sim\snapcdc\review\run_skew.bat', [], '0', 'CDC review skew', 600),
    ('snapcdc_torture', r'sim\snapcdc\review\run_torture.bat', [], '0', 'CDC review 拷打门', 1200),
    ('snapcdc24_axr', r'sim\snapcdc\review24\axr\run.bat', [], '0', 'CDC24 axr', 900),
    ('snapcdc24_cdc', r'sim\snapcdc\review24\cdc\run.bat', [], '0', 'CDC24 cdc', 900),
    ('snapcdc24_lint', r'sim\snapcdc\review24\lint\run.bat', [], '0', 'CDC24 lint', 600),
    ('snapcdc24_p6e', r'sim\snapcdc\review24\p6e\run.bat', [], '0', 'CDC24 p6e wrapper', 900),
    ('snapcdc24_p6e_cnt', r'sim\snapcdc\review24\p6e_cnt\run.bat', [], '0', 'CDC24 p6e 计数', 900),

    # ===== P6a/P6b/P6e（KU5P 侧）=====
    ('p6a_ff_us', r'sim\p6a_ku5p\run_tb_frame_fifo_us.bat', [], '0', 'frame_fifo US 版', 900),
    ('p6a_ff_k7', r'sim\p6a_ku5p\run_tb_frame_fifo_k7.bat', [], '0', 'frame_fifo K7 版', 900),
    ('p6a_ramb36e2', r'sim\p6a_ku5p\run_tb_ramb36e2_sem.bat', [], '0', 'RAMB36E2 语义门', 900),
    ('p6a_rgmii_dbg', r'sim\p6a_ku5p\run_tb_rgmii_dbg.bat', [], '0', 'RGMII 调试门', 900),
    ('p6a_rgmii_phy', r'sim\p6a_ku5p\run_tb_rgmii_phy_model.bat', [], '0', 'RGMII PHY 模型门', 900),
    ('p6a_preflight', r'sim\p6a_ku5p\pf\run_preflight.bat', [], '0', 'P6a 预检(lint)', 900),
    ('p6b_lint', r'sim\p6b_lint\lint.bat', [], '0', 'P6b lint 门', 900),
    ('p6b_lint_def', r'sim\p6b_lint\lint_def.bat', [], '0', 'P6b lint 默认构建门', 900),
    ('p6e_pcie', r'sim\p6e_pcie\run_tb_p6e_pcie.bat', [], '0', 'P6e PCIe 窗口门', 900),
    ('p6e_pcie_cnt', r'sim\p6e_pcie\run_tb_p6e_pcie_counters.bat', [], '0', 'P6e PCIe 计数门', 900),

    # ===== P4 目录下除矩阵以外的门 =====
    ('p4_chain_active', r'sim\p4sim\run_tb_p4_chain_active.bat', [], '0', 'P4 全链 active', 1800),
    ('p4_chain_active_slow', r'sim\p4sim\run_tb_p4_chain_active_slow.bat', [], '0', 'P4 全链 active slow', 1800),
    ('p4_chain_xk', r'sim\p4sim\run_tb_p4_chain_xk.bat', [], '0', 'P4 全链 xk', 1800),
    ('p4_chain_stall_xk', r'sim\p4sim\run_tb_p4_chain_stall_xk.bat', [], '0', 'P4 全链 stall xk', 1800),
    ('p4_burst_xk', r'sim\p4sim\run_tb_p4_burst_xk.bat', [], '0', 'P4 burst xk', 1800),
    ('p4_replay', r'sim\p4sim\run_tb_p4_replay.bat', [], '0', 'P4 replay', 1800),
    ('p4_rxclass', r'sim\p4sim\run_tb_rxclass.bat', [], '0', 'rx_classify 单元门', 900),
    ('p4_rxclass_xk', r'sim\p4sim\run_tb_rxclass_xk.bat', [], '0', 'rx_classify xk', 900),
    ('p4_slowrx', r'sim\p4sim\run_tb_slowrx.bat', [], '0', '慢 RX 门', 900),
    ('p4_slowtx', r'sim\p4sim\run_tb_slowtx.bat', [], '0', '慢 TX 门', 900),
    ('p4_txarb', r'sim\p4sim\run_tb_txarb.bat', [], '0', 'tx_arb 单元', 600),
    ('p4_probe', r'sim\p4sim\run_probe.bat', [], '0', 'P4 探针门', 600),
    ('p4_hlsprobe', r'sim\p4sim_hlsprobe\run_hls_udp_probe.bat', [], '0', 'HLS udp 探针门', 900),
    # 2026-09-30 订正: 此处原为 `sim\p4indm\run_4gates.sh` —— 本 runner 用 `cmd /c <bat>`
    #   起门(见下面 run_one), **cmd 跑不动 .sh** ⇒ 实测 0.1 s / 空日志 / EXIT=0 = 哑门。
    #   现指向该门的**委托入口** run_4gates.bat(它再 -only 交给权威 runner
    #   sim\p4gates\run_matrix_p4dfix.bat)。.sh 仍在, 但只是它的 git-bash 薄 shim。
    ('p4indm_4gates', r'sim\p4indm\run_4gates.bat', [], '0', 'P4 独立 4 门(bat 委托矩阵 runner)', 2400),
    ('d2_suite', r'sim\d2run\run_suite_d2.bat', [], '0', 'D2 套件', 2400),
    ('p4gates_selfcheck', r'sim\p4gates\implicit_gate_selftest.bat', [], '0', '隐式网检测器自检(9 项对照)', 600),
    ('p5d_mech', r'sim\p5d_multi\p5dmech\run_mech.bat', [], '0', 'P5d 机理门', 900),
    ('p5d_mechf', r'sim\p5d_multi\p5dmech\run_mechf.bat', [], '0', 'P5d 机理门 f', 900),

    # ===== 10G 门（_proj_10g）=====
    ('p7b_mac', r'_proj_10g\p7b_mac\sim\run_tb_mac_10g.bat', [], '0', '★ 新 64 位 XGMII MAC 单元门', 1800),
    ('p7b_chain', r'_proj_10g\p7b_chain\sim\run_tb_p7b_chain.bat', [], '0', '★ 真 wrapper 全链门（PCS=stub）', 1800),
    ('p7b_appsplit', r'_proj_10g\p7b_appsplit\sim\run_tb_p7b_appsplit.bat', [], '0', '★ app/split 门', 1800),
    ('p7b_rxcls_v2', r'_proj_10g\p7b_rxcls\sim\run_tb_rxcls_v2.bat', [], '0', '★ rx_classify v2 门', 1200),
    ('p7b_rxcls_legacy', r'_proj_10g\p7b_rxcls\sim\run_legacy_tb_rxclass.bat', [], '0', 'rx_classify 旧门(对照)', 1200),
    ('p7a_counters', r'_proj_10g\sim\run_tb_p7a_counters.bat', [], '0', 'P7a 计数器门', 900),
    ('xxv_pay_sel', r'_proj_10g\xxv_loop\sim\run_sim_pay.bat', [], '0', 'PCS 载荷选择门', 1200),
    ('pci_axi_regs', r'_proj_pcie\run_tb_axi_regs.bat', [], '0', 'PCIe 寄存器窗口门', 900),
    ('p7b_lanefix_dbg', r'_proj_10g\notes\p7b_lanefix\dbg\run_dbg.bat', [], '0', 'lane4 重对齐调试门', 1200),
    ('p7b_lane4', r'_proj_10g\notes\p7b_udp_diag2\sim\run_lane4.bat', [], '0', 'lane4 门', 1200),
    ('p7b_impl_xvlog_all', r'_proj_10g\notes\p7b_implicit_repro\run_xvlog_all.bat', [], '0', '隐式网最小复现 xvlog', 600),
    ('p7b_impl_xelab', r'_proj_10g\notes\p7b_implicit_repro\run_xelab.bat', [], '0', '隐式网最小复现 xelab', 600),
    ('p7b_impl_one', r'_proj_10g\notes\p7b_implicit_repro\run_one.bat', [], '0', '隐式网最小复现 one', 600),
    ('p7b_impl_sv', r'_proj_10g\notes\p7b_implicit_repro\run_sv.bat', [], '0', '隐式网最小复现 -sv', 600),
    ('p7b_impl_fs', r'_proj_10g\notes\p7b_implicit_repro\fs_semantics.bat', [], '0', '隐式网语义门', 600),
]


def log_path(name):
    return os.path.join(LOGDIR, name + '.log')


def run_one(gate):
    name, bat, args, exp, desc, tmo = gate
    bat_abs = os.path.join(ROOT, bat)
    lp = log_path(name)
    t0 = time.time()
    rc = None
    note = ''
    if not os.path.exists(bat_abs):
        return dict(name=name, bat=bat, rc=None, secs=0, verdict='MISSING',
                    note='门脚本不存在', log=lp)
    try:
        with io.open(lp, 'w', encoding='utf-8', errors='replace') as f:
            f.write('# gate   : %s\n# bat    : %s\n# args   : %s\n'
                    '# expect : exit %s\n# desc   : %s\n# started: %s\n\n'
                    % (name, bat, args, exp, desc,
                       time.strftime('%Y-%m-%d %H:%M:%S')))
            f.flush()
            p = subprocess.run(['cmd', '/c', bat_abs] + list(args),
                               cwd=ROOT, stdout=f, stderr=subprocess.STDOUT,
                               timeout=tmo)
            rc = p.returncode
    except subprocess.TimeoutExpired:
        note = 'TIMEOUT after %ds' % tmo
        rc = -999
    secs = time.time() - t0
    if rc is None:
        verdict = 'ERROR'
    elif exp == '!0':
        verdict = 'PASS(neg-as-expected)' if rc != 0 else 'FAIL(neg-did-not-fail)'
    else:
        verdict = 'PASS' if rc == 0 else 'FAIL'
    with io.open(lp, 'a', encoding='utf-8', errors='replace') as f:
        f.write('\n\n# ===== runner: EXIT=%s  %.1fs  %s =====\n'
                % (rc, secs, note))
    return dict(name=name, bat=bat, rc=rc, secs=secs, verdict=verdict,
                note=note, log=lp, desc=desc, args=args, exp=exp)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--only', default='')
    ap.add_argument('--jobs', type=int, default=2)
    ap.add_argument('--list', action='store_true')
    a = ap.parse_args()
    if a.list:
        for g in G:
            print('%-24s %-52s %s' % (g[0], g[1], ' '.join(g[2])))
        print('共 %d 门' % len(G))
        return 0
    if not os.path.isdir(LOGDIR):
        os.makedirs(LOGDIR)

    sel = set(x for x in a.only.split(',') if x)
    gates = [g for g in G if not sel or g[0] in sel]
    if sel:
        unknown = sel - set(g[0] for g in G)
        if unknown:
            print('未知门名: %s' % sorted(unknown))
            return 97

    # 按 bat 所在目录分组 -> 组内串行
    bydir = OrderedDict()
    for g in gates:
        d = os.path.dirname(os.path.join(ROOT, g[1]))
        bydir.setdefault(d, []).append(g)
    groups = list(bydir.values())
    print('门总数 %d，目录组 %d，并发 %d' % (len(gates), len(groups), a.jobs))

    results = []
    lock = threading.Lock()
    idx = [0]

    def worker():
        while True:
            with lock:
                if idx[0] >= len(groups):
                    return
                grp = groups[idx[0]]
                idx[0] += 1
            for g in grp:
                r = run_one(g)
                with lock:
                    results.append(r)
                    print('[%3d/%3d] %-24s EXIT=%-5s %6.1fs  %s'
                          % (len(results), len(gates), r['name'], r['rc'],
                             r['secs'], r['verdict']))
                    sys.stdout.flush()

    ths = [threading.Thread(target=worker) for _ in range(max(1, a.jobs))]
    t0 = time.time()
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    print('总耗时 %.1f 分钟' % ((time.time() - t0) / 60.0))

    order = {g[0]: i for i, g in enumerate(gates)}
    results.sort(key=lambda r: order[r['name']])
    bad = [r for r in results if r['verdict'] not in
           ('PASS', 'PASS(neg-as-expected)')]
    print('\n=== 汇总: %d 门, 失败/异常 %d ===' % (len(results), len(bad)))
    for r in bad:
        print('  %-24s %s' % (r['name'], r['verdict']))
    import json
    with io.open(os.path.join(HERE, 'results.json'), 'w',
                 encoding='utf-8') as f:
        json.dump(results, f, ensure_ascii=False, indent=1)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
