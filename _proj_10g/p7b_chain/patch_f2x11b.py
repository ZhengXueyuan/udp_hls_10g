# -*- coding: utf-8 -*-
"""F2X11b: got_buf is stored **lane0-first** (the delivery observer does
`got_buf[got_len] = rx_tdata[bi*8 +: 8]` for bi = 0..7, i.e. lane0 = the LAST byte of
an 8-byte group) -- so a byte-exact comparison against the frame stream must reverse
each 8-byte group.  Add a dump to make the order visible in the log, and fix the X6
content criterion.
"""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/tb_p7b_chain.v'
s = io.open(P, 'r', encoding='utf-8', newline='').read()
orig = s
old = '''                okb = 1'b1;
                for (q6 = 0; q6 < 60; q6 = q6 + 1)
                    if (got_buf[q6] !== ((q6 < n6) ? PAT[(1+q6) % 256] : 8'h00)) okb = 1'b0;
                gc = ((okb === 1'b1) && (got_f_cnt === (gc0 + 1))) ? 1 : 0;'''
new = '''                okb = 1'b1;
                // ⚠️ got_buf 的存储序 = **lane0-first** (观察者按 `tdata[bi*8 +: 8]`, bi=0..7
                //    逐 lane 写) ⇒ 每个 8 字节组的顺序与帧字节流**相反** (帧首字节在 lane7,
                //    即该组最后一个被写进去的槽)。⇒ 逐字节比对必须按组反转。
                for (q6 = 0; q6 < 60; q6 = q6 + 1) begin
                    gbi = (q6 / 8) * 8 + 7 - (q6 % 8);
                    bexp = (gbi < n6) ? PAT[(1+gbi) % 256] : 8'h00;
                    if (got_buf[q6] !== bexp) okb = 1'b0;
                end
                gc = ((okb === 1'b1) && (got_f_cnt === (gc0 + 1))) ? 1 : 0;
                $display("  [F2X X6.%0d] delivered got_buf[0..7] = %02h %02h %02h %02h %02h %02h %02h %02h (lane0-first) | frame[0..7] = %02h %02h %02h %02h %02h %02h %02h %02h",
                         si, got_buf[0], got_buf[1], got_buf[2], got_buf[3],
                         got_buf[4], got_buf[5], got_buf[6], got_buf[7],
                         PAT[1], PAT[2], PAT[3], PAT[4], PAT[5], PAT[6], PAT[7], PAT[8]);
                $display("  [F2X X6.%0d] tail got_buf[52..59] = %02h %02h %02h %02h %02h %02h %02h %02h | expect all 0x00 above byte %0d",
                         si, got_buf[52], got_buf[53], got_buf[54], got_buf[55],
                         got_buf[56], got_buf[57], got_buf[58], got_buf[59], n6);'''
if s.count(old) != 1:
    raise SystemExit('anchor x%d' % s.count(old))
s = s.replace(old, new)

old = '''            integer si, n6, gc0, q6, rc6;
            reg okb;
            integer ga, gb, gc;'''
new = '''            integer si, n6, gc0, q6, rc6, gbi;
            reg okb;
            reg [7:0] bexp;
            integer ga, gb, gc;'''
if s.count(old) != 1:
    raise SystemExit('decl anchor x%d' % s.count(old))
s = s.replace(old, new)

io.open(P, 'w', encoding='utf-8', newline='').write(s)
print('F2X11b applied: %d -> %d' % (len(orig), len(s)))
