# -*- coding: utf-8 -*-
# E7 撞车"每次必出"改造: 释放 hold 的条件从"fire+2 拍"改成
#   "暂存已落地 (ps_stage_rdy) 且探询门连续稳 N 拍", 并加**有限重试** (观察窗内没出见证就再来一次)。
# 只改 tb/tb_tcp_tx_ovl.v (CRLF 纪律); 跑完复原。
TB = r"D:\repo\XCKU5PMini\udp_hls_10g\tb\tb_tcp_tx_ovl.v"
b = open(TB, "rb").read()
assert b.count(b"pe_gate_n") == 0

# ---- 1) 新声明 (放在 pe_coll_wit 声明之后) ----
a1 = b"    integer     pe_coll_wit;        // \xe7\x9b\xb8\xe6\x92\x9e\xe8\xa7\x81\xe8\xaf\x81 (psc_coll \xe6\x88\x90\xe7\xab\x8b\xe6\x8b\x8d\xe6\x95\xb0)\r\n"
assert b.count(a1) == 1, "a1"
b1 = a1 + (b"    // E7 \xe6\x92\x9e\xe8\xbd\xa6\xe6\x94\xb9\xe9\x80\xa0 v2: \xe9\x97\xa8\xe7\xa8\xb3\xe8\xae\xa1\xe6\x95\xb0 + \xe9\x87\x8d\xe8\xaf\x95\xe6\xac\xa1\xe6\x95\xb0\r\n"
            b"    reg  [3:0]  pe_gate_n;\r\n"
            b"    reg  [2:0]  pe_e7_att;\r\n")
b = b.replace(a1, b1, 1)

# ---- 2) 状态 7'd51 改造 ----
old51 = (b"            7'd51: begin  // E7: \xe7\xad\x89 fire+2 (\xe8\xaf\xbb\xe6\xb5\x81\xe6\xb0\xb4\xe7\xac\xac 2 \xe6\x8b\x8d) \xe2\x87\x92 \xe9\x87\x8a\xe6\x94\xbe hold\r\n"
         b"                      pe_t <= pe_t + 1;\r\n"
         b"                      if (u_dut.ps_rd_d2) begin pe_holdb <= 1'b0; pe_t <= 0; pe_st <= 7'd52; end\r\n"
         b"                      else if (pe_t > 16) begin pe_holdb <= 1'b0; pe_t <= 0; pe_st <= 7'd52; end\r\n"
         b"                  end\r\n")
assert b.count(old51) == 1, "old51"
new51 = (b"            7'd51: begin  // E7 v2: \xe7\xad\x89\"\xe6\x9a\x82\xe5\xad\x98\xe5\xb7\xb2\xe8\x90\xbd\xe5\x9c\xb0 \xe4\xb8\x94\xe6\x8e\xa2\xe8\xaf\xa2\xe9\x97\xa8\xe8\xbf\x9e\xe7\xbb\xad\xe7\xa8\xb3 8 \xe6\x8b\x8d\" \xe2\x87\x92 \xe9\x87\x8a\xe6\x94\xbe hold\r\n"
         b"                      //   (\xe6\x97\xa7\xe6\xb3\x95\xe6\x98\xaf\"fire+2 \xe6\x8b\x8d\xe5\x8d\xb3\xe9\x87\x8a\xe6\x94\xbe\" \xe2\x80\x94\xe2\x80\x94 \xe9\x97\xa8\xe4\xb8\x8d\xe7\xa8\xb3\xe5\xb0\xb1\xe6\x92\x9e\xe4\xb8\x8d\xe4\xb8\x8a)\r\n"
         b"                      pe_t <= pe_t + 1;\r\n"
         b"                      if (u_dut.ps_stage_rdy && pe_probe_gates) pe_gate_n <= pe_gate_n + 4'd1;\r\n"
         b"                      else pe_gate_n <= 4'd0;\r\n"
         b"                      if ((u_dut.ps_stage_rdy && (pe_gate_n >= 4'd7)) || (pe_t > PE_COLL_OBS)) begin\r\n"
         b"                          pe_holdb <= 1'b0; pe_gate_n <= 4'd0; pe_t <= 0; pe_st <= 7'd52;\r\n"
         b"                      end\r\n"
         b"                  end\r\n")
b = b.replace(old51, new51, 1)

# ---- 3) 状态 7'd52 加有限重试 ----
old52 = (b"                      if (pe_t > PE_COLL_OBS) begin\r\n"
         b"                          pe_f_e7_wit <= pe_coll_wit; pe_de1 <= pe_d_ev; pe_st <= 7'd53;\r\n"
         b"                      end\r\n")
assert b.count(old52) == 1, "old52"
new52 = (b"                      // E7 v2: \xe8\xa7\x82\xe5\xaf\x9f\xe7\xaa\x97\xe5\x86\x85\xe6\xb2\xa1\xe5\x87\xba\xe8\xa7\x81\xe8\xaf\x81 \xe2\x87\x92 \xe9\x87\x8d\xe8\xaf\x95 (\xe4\xb8\x8a\xe9\x99\x90 4 \xe6\xac\xa1), \xe7\x9b\xb4\xe5\x88\xb0\xe5\x87\xba\xe4\xb8\xba\xe6\xad\xa2\r\n"
         b"                      if (pe_t > ((pe_e7_att == 3'd0) ? PE_COLL_OBS : 24'd600)) begin\r\n"
         b"                          if ((pe_coll_wit == 0) && (pe_e7_att < 3'd4)) begin\r\n"
         b"                              pe_e7_att <= pe_e7_att + 3'd1;\r\n"
         b"                              pe_holdb  <= 1'b1;      // \xe9\x87\x8d\xe6\x8c\x89\xe4\xbd\x8f\xe5\x90\xaf\xe5\x8a\xa8\xe9\x97\xa8, \xe5\x9b\x9e 51 \xe9\x87\x8d\xe6\x9d\xa5\r\n"
         b"                              pe_gate_n <= 4'd0; pe_t <= 0; pe_st <= 7'd51;\r\n"
         b"                              $display(\"DBG E7 retry att=%0d wit=%0d @%0d\", pe_e7_att + 3'd1, pe_coll_wit, cyc);\r\n"
         b"                          end else begin\r\n"
         b"                              pe_f_e7_wit <= pe_coll_wit; pe_de1 <= pe_d_ev; pe_st <= 7'd53;\r\n"
         b"                          end\r\n"
         b"                      end\r\n")
b = b.replace(old52, new52, 1)

open(TB, "wb").write(b)
n = b.count(b"\n"); cr = b.count(b"\r\n")
print("patched: lines=%d crlf=%d lone_lf=%d bytes=%d" % (n, cr, n - cr, len(b)))
