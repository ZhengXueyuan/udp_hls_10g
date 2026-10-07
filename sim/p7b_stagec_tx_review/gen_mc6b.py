#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 tb_mc6b_probe.v (M-C6 定向门: 槽内 FIN 未发窗口 + retx_req 相位对齐)."""
import io, os, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
src = io.open(os.path.join(HERE, 'tb_ovl_flood_probe.v'), encoding='utf-8', newline='').read()
new = src.replace("module tb_ovl_flood_probe;", "module tb_mc6b_probe;")
i = new.index("    // ---------------- stimulus FSM ----------------")
head = new[:i]

head = head.replace(
    "    integer n_frames, n_data, n_ctrl, n_fin_wire, n_replay_frames;",
    "    integer n_frames, n_data, n_ctrl, n_fin_wire, n_replay_frames;\n    integer n_onebyte_seqF;")
head = head.replace(
    "        n_fin_wire = 0; cyc = 0;",
    "        n_fin_wire = 0; cyc = 0; n_onebyte_seqF = 0;")
head = head.replace(
    "                    if (n_data > 2) n_replay_frames = n_replay_frames + 1;",
    "                    if (n_data > 2) n_replay_frames = n_replay_frames + 1;\n"
    "                    if (({fr[38],fr[39],fr[40],fr[41]} == SEQ_F) && ((fpos - 12'd54) == 12'd1))\n"
    "                        n_onebyte_seqF = n_onebyte_seqF + 1;")

fsm = r'''    // ---------------- stimulus FSM (M-C6 teeth) ----------------
    // 1) conn0: snd_nxt = snd_una = F
    // 2) m_tready = 0 (TX 卡住) + fin_req => 扫描 fin_push => 条目 => start_ack
    //    => FIX-2' 预留 (snd_nxt := F+1) + 槽 busy=1, FIN **未发** (窗口张开)
    // 3) 窗口内拉 retx_req (电平; retx_id=0): svc 每拍都够, 但 ctrl_adv_inflight=1
    //    => 回卷被门挡 (修复版) / 被放行 (M-C6)
    //    M-C6 放行后果: rewind snd_nxt:=F, retx_hi:=rb_snd_nxt=F+1 (fin_sent_r 仍 0)
    //    => delta=1 => **1 字节数据帧 @seq=F** 上线 (C6 签名)
    // 4) 放开 m_tready, 观察线上是否有 1 字节数据帧 @seq=F
    reg [4:0]  st;
    reg [15:0] dly;
    integer    t_wait;
    integer    hit_svc_gated, hit_svc_ungated, rewrites;
    initial begin
        rst_n = 0; s_tdata = 0; s_tkeep = 0; s_tvalid = 0; s_tlast = 0; s_tid = 0;
        ack_req = 0; ack_id = 0; ack_val = RCV_NXT; ack_syn = 0; ack_fin = 0; ack_rst = 0;
        fin_req = 0; rst_req = 0; cfg_up = 0; cfg_up_id = 0;
        wu_req = 0; wu_id = 0; wu_val = 0; retx_req = 0; retx_id = 0;
        scfg_upd_wr = 0; scfg_upd_id = 0; scfg_upd_sel = 0; scfg_upd_val = 0;
        rx_upd_wr = 0; rx_upd_id = 0; rx_upd_sel = 0; rx_upd_val = 0;
        st = 0; dly = 0; t_wait = 0; m_tready = 0;
        hit_svc_gated = 0; hit_svc_ungated = 0; rewrites = 0;
        #200 rst_n = 1;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (u_dut.svc && u_dut.ctrl_adv_inflight) hit_svc_gated = hit_svc_gated + 1;
            if (u_dut.svc && !u_dut.ctrl_adv_inflight) hit_svc_ungated = hit_svc_ungated + 1;
            if (u_dut.svc_rewind) rewrites = rewrites + 1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= 5'd0;
        end else begin
            case (st)
            5'd0: begin scfg_upd_wr <= 1; scfg_upd_id <= 0; scfg_upd_sel <= 3'd2;
                        scfg_upd_val <= SEQ_F; st <= 5'd1; end
            5'd1: if (tcb_wr && (tcb_sel==3'd2) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd1; scfg_upd_val <= SEQ_F; st <= 5'd2; end
            5'd2: if (tcb_wr && (tcb_sel==3'd1) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd0; scfg_upd_val <= RCV_NXT; st <= 5'd3; end
            5'd3: if (tcb_wr && (tcb_sel==3'd0) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd3; scfg_upd_val <= {16'b0, RCV_WND}; st <= 5'd4; end
            5'd4: if (tcb_wr && (tcb_sel==3'd3) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd4; scfg_upd_val <= {16'b0, SND_WND}; st <= 5'd5; end
            5'd5: if (tcb_wr && (tcb_sel==3'd4) && (tcb_id==0))
                      begin scfg_upd_sel <= 3'd5; scfg_upd_val <= 32'd1; st <= 5'd6; end
            5'd6: if (tcb_wr && (tcb_sel==3'd5) && (tcb_id==0))
                      begin scfg_upd_wr <= 1'b0; cfg_up <= 1'b1; cfg_up_id <= 0; st <= 5'd7; end
            5'd7: begin cfg_up <= 1'b0; dly <= 16'd8; st <= 5'd8; end
            5'd8: if (dly != 0) dly <= dly - 16'd1;
                  else begin fin_req[0] <= 1'b1; t_wait <= 0; st <= 5'd9; end
            5'd9: begin
                t_wait <= t_wait + 1;
                if (u_dut.start_ack && u_dut.aq_fin) begin
                    $display("[PROBE] start_ack(FIN) @%0d snd_nxt=%h una=%h busy=%b",
                             cyc, u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                             u_dut.ctrl_slot_busy);
                    dly <= 16'd8; st <= 5'd10;
                end else if (t_wait > 5000) begin
                    $display("[PROBE] TIMEOUT waiting FIN pop");
                    st <= 5'd13;
                end
            end
            5'd10: if (dly != 0) dly <= dly - 16'd1;
                   else begin retx_req <= 1'b1; retx_id <= 4'd0; t_wait <= 0; st <= 5'd11; end
            5'd11: begin
                t_wait <= t_wait + 1;
                if (t_wait > 200) begin
                    $display("[PROBE] window done @%0d snd_nxt=%h una=%h busy=%b gated=%0d ungated=%0d rew=%0d",
                             cyc, u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                             u_dut.ctrl_slot_busy, hit_svc_gated, hit_svc_ungated, rewrites);
                    dly <= 16'd4; st <= 5'd12;
                end
            end
            5'd12: if (dly != 0) dly <= dly - 16'd1;
                   else begin m_tready <= 1'b1; retx_req <= 1'b0; t_wait <= 0; st <= 5'd13; end
            5'd13: begin
                t_wait <= t_wait + 1;
                if (fin_req[0] && o_fin_sent[0]) fin_req[0] <= 1'b0;
                if (t_wait > 4000) begin
                    $display("MC6BPROBE frames=%0d data=%0d ctrl=%0d fin_wire=%0d onebyte_seqF=%0d snd_nxt=%h una=%h gated=%0d ungated=%0d rew=%0d",
                             n_frames, n_data, n_ctrl, n_fin_wire, n_onebyte_seqF,
                             u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                             hit_svc_gated, hit_svc_ungated, rewrites);
                    $display("MC6BPROBE_DONE");
                    $finish;
                end
            end
            default: ;
            endcase
            if (cyc > CY_MAX) begin
                $display("MC6BPROBE frames=%0d data=%0d ctrl=%0d fin_wire=%0d onebyte_seqF=%0d snd_nxt=%h una=%h gated=%0d ungated=%0d rew=%0d",
                         n_frames, n_data, n_ctrl, n_fin_wire, n_onebyte_seqF,
                         u_tcb.snd_nxt_r[0], u_tcb.snd_una_r[0],
                         hit_svc_gated, hit_svc_ungated, rewrites);
                $display("MC6BPROBE_DONE");
                $finish;
            end
        end
    end
endmodule
'''

io.open(os.path.join(HERE, 'tb_mc6b_probe.v'), 'w', encoding='utf-8', newline='').write(head + fsm)

bat = io.open(os.path.join(HERE, 'run_mc6_probe.bat'), encoding='ascii', newline='').read()
bat2 = bat.replace('tb_mc6_probe.v', 'tb_mc6b_probe.v')
bat2 = bat2.replace('xil_defaultlib.tb_mc6_probe', 'xil_defaultlib.tb_mc6b_probe')
bat2 = bat2.replace('-s mc6 ', '-s mc6b ').replace('xsim.bat mc6 ', 'xsim.bat mc6b ')
bat2 = bat2.replace('findstr /C:"MC6PROBE" xs.log', 'findstr /C:"MC6BPROBE" xs.log')
bat2 = bat2.replace('A fixed RTL', 'A fixed RTL').replace('B M-C6 mutant', 'B M-C6 mutant')
io.open(os.path.join(HERE, 'run_mc6b_probe.bat'), 'w', encoding='ascii', newline='\r\n').write(bat2)
print("OK: tb_mc6b_probe.v + run_mc6b_probe.bat")
