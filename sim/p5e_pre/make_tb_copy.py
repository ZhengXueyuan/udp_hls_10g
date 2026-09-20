#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""生成 sim/p5e_pre/ 下两个 TB (都是 tb/tb_p5_app.v 的**只读派生副本**):

  mode=udp  -> tb_p5_udp_split.v   (处理组: classify slow 口 -> udp_rx + 监视)
  mode=base -> tb_p5_baseline.v    (对照组: 逐字同 tb_p5_app.v, 仅改 module 名 +
                                    resp 文件名 —— 用来跑 canonical checker 做
                                    "同 RTL 同配置" 的 A/B 对照)

改动清单 (udp 组, 其余逐字保留):
  1. module 名 tb_p5_app -> tb_p5_udp_split
  2. resp 落盘 -> resp_p5_udp_split.memh (不覆盖 canonical 产物)
  3. rx_classify 的 .m_slow_tready(1'b1) (排空) -> .m_slow_tready(sl_tready) (接 udp_rx)
  4. udp_rx 实例 (只读引用 rtl/udp_rx.v) + 三路监视 + 末尾统计行
监视行全部 P5E* 前缀 —— canonical 判据 gen_stim_p5_app.py:parse_p5 按 'P5' 前缀过滤,
未知 P5* 行被跳过 ⇒ 本副本的落盘可直接喂 canonical checker (非干扰性旁证)。
"""
import io
import os
import re
import sys

SRC = r"D:\repo\ECO\udp_hls_10g\tb\tb_p5_app.v"
D = os.path.dirname(os.path.abspath(__file__))

INSERT = r"""
    // ================= P5e 前置实验: classify slow 口 -> udp_rx =================
    // 零 RTL 改动: 只把原来的 "m_slow_tready=1'b1 (排空)" 换成 udp_rx 的 s_axis_tready。
    // 目的: ① 拆分点 (classify slow 输出) 字节对齐/meta 正确性
    //       ② udp_rx 零 shim 复用 (字流约定是否与 mac_rx_64/vlan_strip 逐位同源)
    // 只读引用 rtl/udp_rx.v; canonical TB 一行未动。
    // 运行模式 (plusarg): 缺省 tready 恒 1;
    //   +UDPSTALL -> 3 高 1 低 (轻背压, 1G 字率 1/8 拍, 不应有 MAC 丢帧)
    //   +UDPHARSH -> 每 2100 拍只吞 100 拍 (占空比 4.8% << 字率 12.5%)
    //                => 验证 "慢口背压会经 mac_rx_64 的 8 深共享 FIFO 溢出,
    //                   连累 fast 路径丢帧" 这一结构性约束 (P5e 关键设计输入)
    reg        udp_stall_r, udp_harsh_r;
    initial    udp_stall_r = $test$plusargs("UDPSTALL") ? 1'b1 : 1'b0;
    initial    udp_harsh_r = $test$plusargs("UDPHARSH") ? 1'b1 : 1'b0;
    reg [3:0]  udp_stall_cnt;
    reg [11:0] udp_hcnt;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) udp_stall_cnt <= 4'd0;
        else        udp_stall_cnt <= udp_stall_cnt + 4'd1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) udp_hcnt <= 12'd0;
        else        udp_hcnt <= (udp_hcnt == 12'd2099) ? 12'd0 : udp_hcnt + 12'd1;
    wire       udp_m_ready = udp_harsh_r ? (udp_hcnt < 12'd100) :
                             udp_stall_r ? (udp_stall_cnt != 4'd0) : 1'b1;

    wire [63:0] udp_tdata;   wire [7:0] udp_tkeep;
    wire        udp_tvalid, udp_tlast;
    wire [1:0]  udp_tuser;
    wire        udp_fend, udp_ferr, udp_meta_valid;
    wire [47:0] udp_meta_src_mac;
    wire [31:0] udp_meta_src_ip;
    wire [15:0] udp_meta_src_port, udp_meta_len;
    wire [31:0] udp_stat_pass, udp_stat_nm, udp_stat_ipc, udp_stat_crc,
                udp_stat_bytes;
    // 背压探针: udp_rx 输出被停拍数 / classify 慢口被停拍数 (证明背压路径真被压过)
    reg [31:0] udp_stall_cyc, slow_stall_cyc;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin udp_stall_cyc <= 0; slow_stall_cyc <= 0; end
        else begin
            if (udp_tvalid && !udp_m_ready) udp_stall_cyc <= udp_stall_cyc + 1;
            if (sl_tvalid  && !sl_tready)   slow_stall_cyc <= slow_stall_cyc + 1;
        end

    udp_rx u_udp_rx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(sl_tdata), .s_axis_tkeep(sl_tkeep),
        .s_axis_tvalid(sl_tvalid), .s_axis_tready(sl_tready),
        .s_axis_tlast(sl_tlast), .s_axis_tuser(sl_tuser),
        .s_axis_tcrs(sl_tcrs), .s_axis_terr(sl_terr),
        .m_axis_tdata(udp_tdata), .m_axis_tkeep(udp_tkeep),
        .m_axis_tvalid(udp_tvalid), .m_axis_tready(udp_m_ready),
        .m_axis_tlast(udp_tlast), .m_axis_tuser(udp_tuser),
        .fend(udp_fend), .ferr(udp_ferr),
        .meta_valid(udp_meta_valid),
        .meta_src_mac(udp_meta_src_mac), .meta_src_ip(udp_meta_src_ip),
        .meta_src_port(udp_meta_src_port), .meta_len(udp_meta_len),
        .cfg_dst_ip(32'hC0A86402),      // 192.168.100.2 = TB_MY_IP
        .cfg_multi_en(1'b0),
        .cfg_port0(16'd8080), .cfg_port1(16'd0),
        .cfg_port2(16'd0),    .cfg_port3(16'd0),
        .cfg_port_any(1'b0),
        .stat_pass(udp_stat_pass), .stat_drop_nonmatch(udp_stat_nm),
        .stat_drop_ipcsum(udp_stat_ipc), .stat_drop_crc(udp_stat_crc),
        .stat_bytes(udp_stat_bytes)
    );

    // ---- 监视 A: slow 口的**原始**字流 (拆分点字节对齐的直接证据) ----
    always @(posedge clk) begin
        if (rst_n && sl_tvalid && sl_tready)
            $fwrite(fd, "P5ESLW %016h %02h %0d %0d %0d %0d\n",
                    sl_tdata, sl_tkeep, sl_tlast, sl_tuser, sl_tcrs, sl_terr);
    end

    // ---- 监视 B: udp_rx 载荷输出字 ----
    always @(posedge clk) begin
        if (rst_n && udp_tvalid && udp_m_ready)
            $fwrite(fd, "P5EUDP %016h %02h %0d %0d %0d\n",
                    udp_tdata, udp_tkeep, udp_tlast, udp_tuser[0], udp_tuser[1]);
    end

    // ---- 监视 C: meta / fend ----
    always @(posedge clk) begin
        if (rst_n && udp_meta_valid)
            $fwrite(fd, "P5EMETA %012h %08h %04h %04h\n",
                    udp_meta_src_mac, udp_meta_src_ip,
                    udp_meta_src_port, udp_meta_len);
        if (rst_n && udp_fend)
            $fwrite(fd, "P5EFEND %0d %0d\n", udp_ferr, udp_meta_len);
    end

"""

STAT = r"""        // ---- P5e 前置实验: udp_rx 侧计数 + 背压探针 ----
        $fwrite(fd, "P5EUSTAT %0d %0d %0d %0d %0d %0d %0d\n",
                udp_stat_pass, udp_stat_nm, udp_stat_ipc, udp_stat_crc,
                udp_stat_bytes, mac_stat_drop, udp_stall_r);
        $fwrite(fd, "P5ESTALL %0d %0d\n", udp_stall_cyc, slow_stall_cyc);
"""


def build(mode):
    with io.open(SRC, "r", encoding="utf-8", newline="") as fh:
        src = fh.read()
    assert "\r" not in src, "源文件含 CR, 本脚本按 LF 处理"
    new_mod = "tb_p5_udp_split" if mode == 'udp' else "tb_p5_baseline"
    new_resp = "resp_p5_udp_split.memh" if mode == 'udp' else "resp_p5_baseline.memh"
    new_resp_c = ("resp_p5_udp_split_close.memh" if mode == 'udp'
                  else "resp_p5_baseline_close.memh")

    a, n = re.subn(r"(?m)^module tb_p5_app;", "module %s;" % new_mod, src)
    assert n == 1, n
    a, n = re.subn(r"resp_p5_app\.memh", new_resp, a)
    assert n == 2, n
    a, n = re.subn(r"resp_p5_close\.memh", new_resp_c, a)
    assert n == 2, n

    if mode == 'udp':
        OLD = "        .m_slow_tvalid(sl_tvalid), .m_slow_tready(1'b1),   // 慢路径本门不用: 排空\n"
        assert OLD in a, "m_slow_tready 行没找到"
        a = a.replace(OLD, ("        // P5e 前置实验: 原 1'b1 (排空) 换成 udp_rx 的 s_axis_tready (零 RTL 改动)\n"
                            "        .m_slow_tvalid(sl_tvalid), .m_slow_tready(sl_tready),\n"), 1)
        ANCHOR = "    tcp_rx u_rx ("
        assert ANCHOR in a
        a = a.replace(ANCHOR, INSERT + ANCHOR, 1)
        A2 = '        $fwrite(fd, "EVSRC %0d %08h %04h %012h %0d %0d\\n",'
        assert A2 in a
        a = a.replace(A2, STAT + A2, 1)
    return new_mod, a


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'udp'
    new_mod, a = build(mode)
    name = "tb_p5_udp_split.v" if mode == 'udp' else "tb_p5_baseline.v"
    p = os.path.join(D, name)
    with io.open(p, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(a)
    print("written %s (mode=%s module=%s, %d bytes)" % (p, mode, new_mod, len(a)))


if __name__ == '__main__':
    main()
