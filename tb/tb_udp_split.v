`timescale 1ns/1ps
//=============================================================================
// tb_udp_split — P5e-T1 udp_split 单元门 (自检式, 无 Python 依赖)
//
// 判据 (末行 "P5 UDP SPLIT UNIT OK" / "P5 UDP SPLIT UNIT FAIL <n>"):
//   A. 过滤/路由: 命中 (端口/组播/dst_ip) ⇒ app 口; 未命中 ⇒ 逐字透传;
//      EXCL_PORT=8080 排除 (目的端口与源端口两侧) ⇒ 留在 HLS 路; cfg_port_any=1
//      (全收) 时排除仍生效。
//   B. 非 UDP 透传保真: 全部 HLS 帧在透传口的**字序列 + tkeep + tlast +
//      tuser(SOP) + tcrs + terr 逐位**与注入完全一致 (逐字比对)。
//   C. app 口硬不变量: 每帧 >=1 拍、末拍 tlast、tkeep 高位连续、字节数 ==
//      app_rx_len、**永不半帧** (sof 落在未闭合帧上即 FAIL)、无重复/丢字。
//   D. udp_rx 弱点消解: 坏 FCS 匹配帧整帧不交付 (stat_drop_crc); 长度不符
//      (声明 != 实际两个方向) 的匹配帧不产生任何半帧 (stat_drop_part), 且紧随
//      其后的正常帧照常交付; 0 长数据报交付 1 拍 null beat (len=0)。
//   E. 绝不反压: s_axis_tready 全程恒 1 (stall_cyc 断言为 0)。app 消费者停
//      8000 拍 (迫使 UDP 帧缓冲满) 期间, 混入的 HLS 帧照常通过, 溢出帧整帧
//      丢弃 (stat_drop_ovf) 且不产生半帧。
//
// 拓扑: 输入 = TB 构造的 classify-slow 字流; 透传口消费者 = slow_rx_adp
//       (tready 恒 1); app 口消费者 = 可编程 tready 的采集器。
// 帧布局与 udp_rx 解析约定一致 (无 VLAN: 头 42 字节, 载荷从 byte42 起)。
//=============================================================================
module tb_udp_split;

    localparam [31:0] MY_IP    = 32'hC0A86402;   // 192.168.100.2
    localparam [31:0] PEER_IP  = 32'hC00A0001;   // 192.168.100.1
    localparam [31:0] OTHER_IP = 32'h0A000001;   // 10.0.0.1 (不匹配)
    localparam [47:0] DST_MAC  = 48'h000A3501FEC0;
    localparam [47:0] SRC_MAC  = 48'h112233445566;
    localparam [15:0] APP_PORT = 16'd9000;
    localparam [15:0] EXC_PORT = 16'd8080;

    localparam EXP_HLS = 0, EXP_APP = 1, EXP_DROP = 2;

    reg         clk, rst_n;
    integer     fail;

    // ---------------- DUT 线网 ----------------
    reg  [63:0] s_tdata;  reg [7:0] s_tkeep;  reg s_tvalid;
    wire        s_tready;
    reg         s_tlast, s_tuser, s_tcrs, s_terr;
    wire [63:0] p_tdata;  wire [7:0] p_tkeep; wire p_tvalid;
    wire        p_tlast, p_tuser, p_tcrs, p_terr;
    wire        p_tready = 1'b1;   // slow_rx_adp 契约: 恒 1
    wire [63:0] a_tdata;  wire [7:0] a_tkeep; wire a_tvalid; wire a_tlast, a_sof;
    wire [15:0] a_len;    wire [31:0] a_sip;  wire [15:0] a_sport;
    reg         a_tready_r;
    reg  [31:0] cfg_dip_r;
    reg         cfg_multi_r, cfg_any_r;
    reg  [15:0] cfg_p0_r, cfg_p1_r, cfg_p2_r, cfg_p3_r;
    // DUT-facing 激励/配置一律经寄存器落地 (坑 17: 0 延迟竞争)
    reg         a_tready, cfg_multi, cfg_any;
    reg  [31:0] cfg_dip;
    reg  [15:0] cfg_p0, cfg_p1, cfg_p2, cfg_p3;
    wire [31:0] st_app_frames, st_app_bytes, st_app_null, st_drop_crc,
                st_drop_ovf, st_drop_part, st_drop_excl,
                st_hls_frames, st_hls_drop, st_hls_split;

    udp_split #(.EXCL_PORT(EXC_PORT)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .s_axis_tcrs(s_tcrs), .s_axis_terr(s_terr),
        .p_axis_tdata(p_tdata), .p_axis_tkeep(p_tkeep), .p_axis_tvalid(p_tvalid),
        .p_axis_tready(p_tready),
        .p_axis_tlast(p_tlast), .p_axis_tuser(p_tuser),
        .p_axis_tcrs(p_tcrs), .p_axis_terr(p_terr),
        .app_rx_tdata(a_tdata), .app_rx_tkeep(a_tkeep), .app_rx_tvalid(a_tvalid),
        .app_rx_tready(a_tready), .app_rx_tlast(a_tlast), .app_rx_sof(a_sof),
        .app_rx_len(a_len), .app_rx_src_ip(a_sip), .app_rx_src_port(a_sport),
        .cfg_dst_ip(cfg_dip), .cfg_multi_en(cfg_multi),
        .cfg_port0(cfg_p0), .cfg_port1(cfg_p1),
        .cfg_port2(cfg_p2), .cfg_port3(cfg_p3), .cfg_port_any(cfg_any),
        .stat_app_frames(st_app_frames), .stat_app_bytes(st_app_bytes),
        .stat_app_null(st_app_null), .stat_drop_crc(st_drop_crc),
        .stat_drop_ovf(st_drop_ovf), .stat_drop_part(st_drop_part),
        .stat_drop_excl(st_drop_excl), .stat_hls_frames(st_hls_frames),
        .stat_hls_drop(st_hls_drop), .stat_hls_split(st_hls_split)
    );

    always #4 clk = ~clk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_tready <= 1'b1; cfg_dip <= MY_IP; cfg_multi <= 1'b0; cfg_any <= 1'b0;
            cfg_p0 <= APP_PORT; cfg_p1 <= 16'd0; cfg_p2 <= 16'd0; cfg_p3 <= 16'd0;
        end else begin
            a_tready <= a_tready_r; cfg_dip <= cfg_dip_r;
            cfg_multi <= cfg_multi_r; cfg_any <= cfg_any_r;
            cfg_p0 <= cfg_p0_r; cfg_p1 <= cfg_p1_r;
            cfg_p2 <= cfg_p2_r; cfg_p3 <= cfg_p3_r;
        end
    end

    // ---------------- 绝不反压断言 (判据 E) ----------------
    integer stall_cyc;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) stall_cyc <= 0;
        else if (!s_tready) stall_cyc <= stall_cyc + 1;

    reg [63:0] lat_sop_t, lat_pb_t;   // 首帧 SOP 注入时刻 / 首个透传字时刻
    // ---------------- 透传口采集 (逐字, 含侧带) ----------------
    localparam integer PBMAX = 20000;
    reg [75:0] cap_pb [0:PBMAX-1];
    integer    n_cap_pb;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) n_cap_pb <= 0;
        else if (p_tvalid && p_tready) begin
            if (n_cap_pb == 0) lat_pb_t <= $time;      // 首个透传字时刻 (延迟测量)
            cap_pb[n_cap_pb] <= {p_tdata, p_tkeep, p_tlast, p_tuser, p_tcrs, p_terr};
            n_cap_pb <= n_cap_pb + 1;
        end
    end

    // ---------------- app 口采集 (逐帧: 字节 + 侧带 + 帧闭合) ----------------
    localparam integer APPFMAX = 64, APPBYTES = 65536;
    reg [15:0] a_exp_len   [0:APPFMAX-1];
    reg [31:0] a_exp_sip   [0:APPFMAX-1];
    reg [15:0] a_exp_sport [0:APPFMAX-1];
    reg [7:0]  a_exp_bytes [0:APPBYTES-1];
    integer    a_exp_off   [0:APPFMAX-1];
    integer    n_exp_app, a_exp_blen;

    reg [15:0] c_len    [0:APPFMAX-1];
    reg [31:0] c_sip    [0:APPFMAX-1];
    reg [15:0] c_sport  [0:APPFMAX-1];
    reg [7:0]  c_bytes  [0:APPBYTES-1];
    integer    c_off    [0:APPFMAX-1];
    integer    n_cap_app, c_blen;
    integer    app_open, app_bad_sof, app_bad_tkeep, app_bad_len;
    integer    cap_k, cap_nvb, cap_fr_start, cap_frlen;

    function [3:0] pop8;          // tkeep 置位数
        input [7:0] v;
        integer i; reg [3:0] c;
        begin
            c = 4'd0;
            for (i = 0; i < 8; i = i + 1) c = c + {3'b0, v[i]};
            pop8 = c;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_cap_app <= 0; c_blen <= 0; app_open <= 0;
            app_bad_sof <= 0; app_bad_tkeep <= 0; app_bad_len <= 0;
        end else if (a_tvalid && a_tready) begin
            if (a_sof) begin
                if (app_open) app_bad_sof <= app_bad_sof + 1;  // 半帧! 未闭合就开新帧
                app_open     <= 1;
                cap_fr_start = c_blen;            // 本帧起点 (阻塞: 同拍 tlast 也要用)
                c_len[n_cap_app]   <= a_len;
                c_sip[n_cap_app]   <= a_sip;
                c_sport[n_cap_app] <= a_sport;
                c_off[n_cap_app]   <= c_blen;
            end
            // tkeep 必须高位连续 (本工程 AXIS 约定)
            if (a_tkeep !== (8'hFF << (4'd8 - pop8(a_tkeep))))
                app_bad_tkeep <= app_bad_tkeep + 1;
            cap_nvb = c_blen;
            for (cap_k = 0; cap_k < 8; cap_k = cap_k + 1)
                if (cap_k < pop8(a_tkeep)) begin
                    c_bytes[cap_nvb] <= a_tdata[63 - 8*cap_k -: 8];
                    cap_nvb = cap_nvb + 1;
                end
            c_blen <= cap_nvb;
            if (a_tlast) begin
                // 本帧字节数必须 == len (无重复 / 无丢字)
                cap_frlen = cap_nvb - cap_fr_start;
                if (a_len !== cap_frlen[15:0]) app_bad_len <= app_bad_len + 1;
                n_cap_app <= n_cap_app + 1;
                app_open  <= 0;
            end
        end
    end

    // ---------------- 激励缓冲 + 帧构造 ----------------
    localparam integer SN = 60000;
    reg [76:0] stim [0:SN-1];
    integer    sp;

    reg [7:0]  fb [0:2047];
    integer    flen;

    reg [75:0] exp_pb [0:PBMAX-1];   // 期望透传字序列 (HLS 帧的字, 按注入顺序)
    integer    n_exp_pb;

    task fb_put(input [7:0] b); begin fb[flen] = b; flen = flen + 1; end endtask
    task fb_put16(input [15:0] v); begin
        fb[flen] = v[15:8]; fb[flen+1] = v[7:0]; flen = flen + 2; end endtask
    task fb_put32(input [31:0] v); begin
        fb[flen]=v[31:24]; fb[flen+1]=v[23:16]; fb[flen+2]=v[15:8]; fb[flen+3]=v[7:0];
        flen = flen + 4; end endtask

    integer h_i; reg [19:0] h_sum; reg [16:0] h_f1; reg [15:0] h_ck;
    task mk_eth_ip(input [15:0] ethertype, input [7:0] proto, input [15:0] iplen,
                   input [31:0] sip, input [31:0] dip, input integer bad_csum);
        begin
            flen = 0;
            fb_put32(32'h000A3501); fb_put16(16'hFEC0);     // dst mac
            fb_put32(32'h11223344); fb_put16(16'h5566);     // src mac
            fb_put16(ethertype);                            // byte 12-13
            fb_put(8'h45); fb_put(8'h00);                   // ver/ihl, dscp
            fb_put16(iplen); fb_put16(16'h1234); fb_put16(16'h4000);
            fb_put(8'd64); fb_put(proto);
            fb_put16(16'h0000);                             // ip csum 占位 (byte 24-25)
            fb_put32(sip); fb_put32(dip);
            h_sum = 20'd0;
            for (h_i = 0; h_i < 10; h_i = h_i + 1)
                h_sum = h_sum + {4'b0, fb[14+2*h_i], fb[15+2*h_i]};
            h_f1 = h_sum[15:0] + {12'b0, h_sum[19:16]};
            h_ck = ~(h_f1[15:0] + {15'b0, h_f1[16]});
            if (bad_csum) h_ck = h_ck ^ 16'h0001;
            fb[24] = h_ck[15:8]; fb[25] = h_ck[7:0];
        end
    endtask

    integer u_i; reg [15:0] u_len;
    // bad_udplen: 声明 udp_len = plen+58 (> 实际) ⇒ udp_rx 无 TLAST 半帧
    // over_udplen: 声明 = plen-20 (< 实际) ⇒ 帧身超声明 ⇒ 无 TLAST 半帧
    task mk_udp(input [31:0] sip, input [31:0] dip, input [15:0] sport,
                input [15:0] dport, input integer plen, input [7:0] seed,
                input integer bad_udplen, input integer over_udplen);
        begin
            u_len = plen + 8;
            if (bad_udplen)  u_len = plen + 58;
            if (over_udplen) u_len = plen - 20;
            mk_eth_ip(16'h0800, 8'h11, plen + 28, sip, dip, 0);
            fb_put16(sport); fb_put16(dport);
            fb_put16(u_len); fb_put16(16'h0000);
            for (u_i = 0; u_i < plen; u_i = u_i + 1) fb_put(seed + u_i[7:0]);
        end
    endtask

    task mk_arp(input integer plen);
        begin
            flen = 0;
            fb_put32(32'hFFFF000A); fb_put16(16'h3501);
            fb_put32(32'h11223344); fb_put16(16'h5566);
            fb_put16(16'h0806);                              // ethertype ARP
            for (u_i = 0; u_i < plen - 14; u_i = u_i + 1) fb_put(8'hA0 + u_i[7:0]);
        end
    endtask

    task mk_tcp(input [31:0] sip, input [31:0] dip, input [15:0] sport,
                input [15:0] dport, input integer plen);
        begin
            mk_eth_ip(16'h0800, 8'h06, plen + 40, sip, dip, 0);
            fb_put16(sport); fb_put16(dport);
            fb_put32(32'h12345678); fb_put32(32'h00000000);
            fb_put(8'h50); fb_put(8'h18); fb_put16(16'h4000);
            fb_put16(16'h0000); fb_put16(16'h0000);
            for (u_i = 0; u_i < plen; u_i = u_i + 1) fb_put(8'h50 + u_i[7:0]);
        end
    endtask

    integer e_w, e_b, e_nw, e_nb;
    reg [63:0] e_d;  reg [7:0] e_k;
    // 把 fbuf 以字流形式入 stim; crc_ok/rxer 只落末拍 (与 mac_rx_64 语义一致)。
    // route=EXP_HLS 时逐字同时进 exp_pb (透传必须逐位复现)。
    task emit_frame(input integer crc_ok, input integer rxer, input integer gap,
                    input integer route);
        begin
            e_nw = (flen + 7) / 8;
            for (e_w = 0; e_w < e_nw; e_w = e_w + 1) begin
                e_nb = flen - e_w*8;  if (e_nb > 8) e_nb = 8;
                e_d = 64'd0;  e_k = 8'hFF << (8 - e_nb);
                for (e_b = 0; e_b < e_nb; e_b = e_b + 1)
                    e_d[63 - 8*e_b -: 8] = fb[e_w*8 + e_b];
                stim[sp] = {1'b1, e_d, e_k, (e_w == e_nw-1), (e_w == 0),
                            (((e_w == e_nw-1) && (crc_ok != 0)) ? 1'b1 : 1'b0),
                            (((e_w == e_nw-1) && (rxer   != 0)) ? 1'b1 : 1'b0)};
                sp = sp + 1;
                if (route == EXP_HLS) begin
                    exp_pb[n_exp_pb] = {e_d, e_k, (e_w == e_nw-1), (e_w == 0),
                                        (((e_w == e_nw-1) && (crc_ok != 0)) ? 1'b1 : 1'b0),
                                        (((e_w == e_nw-1) && (rxer   != 0)) ? 1'b1 : 1'b0)};
                    n_exp_pb = n_exp_pb + 1;
                end
            end
            for (e_w = 0; e_w < gap; e_w = e_w + 1) begin stim[sp] = 77'd0; sp = sp + 1; end
            if (route == EXP_APP) begin
                a_exp_len[n_exp_app]   = flen - 42;
                a_exp_sip[n_exp_app]   = {fb[26], fb[27], fb[28], fb[29]};
                a_exp_sport[n_exp_app] = {fb[34], fb[35]};
                a_exp_off[n_exp_app]   = a_exp_blen;
                for (e_b = 42; e_b < flen; e_b = e_b + 1) begin
                    a_exp_bytes[a_exp_blen] = fb[e_b];
                    a_exp_blen = a_exp_blen + 1;
                end
                n_exp_app = n_exp_app + 1;
            end
        end
    endtask

    // 截断注入: 只发前 ncut 字 (无 tlast), 后续接新帧 (SOP 兜底路径)
    task emit_trunc(input integer ncut);
        begin
            e_nw = (flen + 7) / 8;  if (ncut < e_nw) e_nw = ncut;
            for (e_w = 0; e_w < e_nw; e_w = e_w + 1) begin
                e_nb = flen - e_w*8;  if (e_nb > 8) e_nb = 8;
                e_d = 64'd0;  e_k = 8'hFF << (8 - e_nb);
                for (e_b = 0; e_b < e_nb; e_b = e_b + 1)
                    e_d[63 - 8*e_b -: 8] = fb[e_w*8 + e_b];
                stim[sp] = {1'b1, e_d, e_k, 1'b0, (e_w == 0), 1'b0, 1'b0};
                sp = sp + 1;
                exp_pb[n_exp_pb] = {e_d, e_k, 1'b0, (e_w == 0), 1'b0, 1'b0};
                n_exp_pb = n_exp_pb + 1;
            end
        end
    endtask

    integer r_i;
    task run_stim(input integer a, input integer b);
        begin
            for (r_i = a; r_i < b; r_i = r_i + 1) begin
                @(posedge clk);
                s_tvalid <= stim[r_i][76];
                s_tdata  <= stim[r_i][75:12];
                s_tkeep  <= stim[r_i][11:4];
                s_tlast  <= stim[r_i][3];
                s_tuser  <= stim[r_i][2];
                s_tcrs   <= stim[r_i][1];
                s_terr   <= stim[r_i][0];
            end
        end
    endtask

    task chk(input integer cond, input [1023:0] msg);
        begin
            if (cond == 0) begin
                fail = fail + 1;
                $display("  FAIL: %0s", msg);
            end
        end
    endtask

    integer cmp_i, cmp_j, bad_pb, bad_app;
    integer ph3, ph4;
    integer seg1, seg2, seg3, seg4, seg5;
    initial begin
        clk = 0; rst_n = 0; fail = 0; sp = 0;
        s_tvalid = 0; s_tdata = 0; s_tkeep = 0;
        s_tlast = 0; s_tuser = 0; s_tcrs = 0; s_terr = 0;
        a_tready_r = 1'b1;
        cfg_dip_r = MY_IP; cfg_multi_r = 1'b0; cfg_any_r = 1'b0;
        cfg_p0_r = APP_PORT; cfg_p1_r = 16'd0; cfg_p2_r = 16'd0; cfg_p3_r = 16'd0;
        n_cap_pb = 0; n_exp_pb = 0; n_exp_app = 0; a_exp_blen = 0;

        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        //=====================================================================
        // 阶段 1: 过滤 + 透传保真 (a_tready=1)
        //=====================================================================
        mk_arp(42);                       emit_frame(1, 0, 4, EXP_HLS);   // 1 非 IP
        mk_eth_ip(16'h0800, 8'h01, 16'd46, PEER_IP, MY_IP, 0);           // 2 ICMP
        fb_put16(16'h0800); fb_put16(16'h0000);
        fb_put16(16'h0001); fb_put16(16'h0002);
        while (flen < 60) fb_put(8'hC0 + flen[7:0]);
        emit_frame(1, 0, 4, EXP_HLS);
        mk_tcp(PEER_IP, MY_IP, 16'h3039, 16'h1F90, 42);
        emit_frame(1, 0, 4, EXP_HLS);                                     // 3 TCP
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 16, 8'h10, 0, 0);
        emit_frame(1, 0, 4, EXP_APP);                                     // 4 命中
        mk_udp(PEER_IP, MY_IP, 16'h3039, EXC_PORT, 100, 8'h20, 0, 0);
        emit_frame(1, 0, 4, EXP_HLS);                                     // 5 8080 排除
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 32, 8'h30, 0, 0);
        emit_frame(0, 0, 4, EXP_DROP);                                    // 6 坏 FCS
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 40, 8'h40, 1, 0);
        emit_frame(1, 0, 4, EXP_DROP);                                    // 7 声明>实际
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 120, 8'h50, 0, 1);
        emit_frame(1, 0, 4, EXP_DROP);                                    // 8 声明<实际
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 24, 8'h60, 0, 0);
        emit_frame(1, 0, 4, EXP_APP);                                     // 9 紧随正常帧
        mk_udp(PEER_IP, MY_IP, 16'h3039, 16'd9001, 60, 8'h70, 0, 0);
        emit_frame(1, 0, 4, EXP_HLS);                                     // 10 未配端口
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 0, 8'h80, 0, 0);
        emit_frame(1, 0, 4, EXP_APP);                                     // 11 0 长
        seg1 = sp;                       // 段界: 组播帧前 (cfg_multi 在运行期置 1)
        mk_udp(PEER_IP, 32'hEF010203, 16'h3039, APP_PORT, 24, 8'h90, 0, 0);
        emit_frame(1, 0, 4, EXP_APP);                                     // 12 组播
        seg2 = sp;
        mk_udp(PEER_IP, OTHER_IP, 16'h3039, APP_PORT, 30, 8'hA0, 0, 0);
        emit_frame(1, 0, 4, EXP_HLS);                                     // 13 dst 不匹配
        mk_eth_ip(16'h0800, 8'h11, 16'd68, PEER_IP, MY_IP, 1);            // 14 IP csum 坏
        fb_put16(16'h3039); fb_put16(APP_PORT); fb_put16(16'd48); fb_put16(16'd0);
        while (flen < 82) fb_put(8'hB0 + flen[7:0]);
        emit_frame(1, 0, 4, EXP_HLS);
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 1472, 8'hC0, 0, 0);
        emit_frame(1, 0, 4, EXP_APP);                                     // 15 满长
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 1, 8'hD1, 0, 0);
        emit_frame(1, 0, 4, EXP_APP);                                     // 16 1B
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 7, 8'hD2, 0, 0);
        emit_frame(1, 0, 4, EXP_APP);                                     // 17 7B
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 8, 8'hD3, 0, 0);
        emit_frame(1, 0, 4, EXP_APP);                                     // 18 8B
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 9, 8'hD4, 0, 0);
        emit_frame(1, 0, 4, EXP_APP);                                     // 19 9B

        //=====================================================================
        // 阶段 2: cfg_port_any=1 (全收) ⇒ 排除端口仍留给 HLS
        //=====================================================================
        seg3 = sp;                       // 段界: cfg_any 在运行期置 1
        mk_udp(PEER_IP, MY_IP, 16'h3039, EXC_PORT, 64, 8'hE0, 0, 0);
        emit_frame(1, 0, 4, EXP_HLS);                                     // 20 目的排除
        mk_udp(PEER_IP, MY_IP, EXC_PORT, 16'd7777, 64, 8'hE1, 0, 0);
        emit_frame(1, 0, 4, EXP_HLS);                                     // 21 源排除
        mk_udp(PEER_IP, MY_IP, 16'h3039, 16'd7777, 64, 8'hE2, 0, 0);
        emit_frame(1, 0, 4, EXP_APP);                                     // 22 其他端口
        seg4 = sp;

        //=====================================================================
        // 阶段 3: 截断帧 (无 TLAST) 后紧跟正常帧 —— 兜底不得污染
        //=====================================================================
        mk_tcp(PEER_IP, MY_IP, 16'h3039, 16'h1F90, 100);
        emit_trunc(4);                                                    // 23 截断
        mk_arp(60);
        emit_frame(1, 0, 4, EXP_HLS);                                     // 24 正常
        seg5 = sp;

        //=====================================================================
        // 阶段 4: 慢消费者 (a_tready 停) ⇒ UDP 缓冲满 ⇒ 整帧丢 + 不反压
        //=====================================================================
        ph3 = sp;
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 1472, 8'hF0, 0, 0);
        emit_frame(1, 0, 4, EXP_APP);                                     // 25 已提交
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 1472, 8'hF1, 0, 0);
        emit_frame(1, 0, 4, EXP_APP);                                     // 26 已提交
        mk_arp(60);
        emit_frame(1, 0, 4, EXP_HLS);                                     // 27 混入 HLS
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 1472, 8'hF2, 0, 0);
        emit_frame(1, 0, 4, EXP_DROP);                                    // 28 缓冲满丢
        mk_udp(PEER_IP, MY_IP, 16'h3039, APP_PORT, 1472, 8'hF3, 0, 0);
        emit_frame(1, 0, 4, EXP_DROP);                                    // 29 缓冲满丢
        ph4 = sp;

        //=====================================================================
        // 运行
        //=====================================================================
        // 分段运行: 段间改配置 (cfg 经寄存器落地, 比帧字早 1 拍生效)
        lat_sop_t = $time;                    // 首帧 SOP 注入时刻 (延迟测量)
        run_stim(0, seg1);
        cfg_multi_r = 1'b1;  run_stim(seg1, seg2);   cfg_multi_r = 1'b0;
        run_stim(seg2, seg3);
        cfg_any_r   = 1'b1;  run_stim(seg3, seg4);   cfg_any_r   = 1'b0;
        run_stim(seg4, ph3);
        a_tready_r = 1'b0;                    // app 消费者停 8000 拍
        run_stim(ph3, ph4);
        repeat (8000) @(posedge clk);
        a_tready_r = 1'b1;
        repeat (6000) @(posedge clk);
        s_tvalid <= 1'b0;
        repeat (200) @(posedge clk);

        //=====================================================================
        // 判据
        //=====================================================================
        $display("P5US skew: 首个透传字相对首帧 SOP 注入延迟 = %0d 拍", (lat_pb_t-lat_sop_t)/8);
        $display("P5US req: stall=%0d pb_cap=%0d exp_pb=%0d app_cap=%0d exp_app=%0d",
                 stall_cyc, n_cap_pb, n_exp_pb, n_cap_app, n_exp_app);
        $display("P5US stat: app(f=%0d b=%0d null=%0d) drop(crc=%0d ovf=%0d part=%0d excl=%0d) hls(f=%0d d=%0d s=%0d)",
                 st_app_frames, st_app_bytes, st_app_null, st_drop_crc, st_drop_ovf,
                 st_drop_part, st_drop_excl, st_hls_frames, st_hls_drop, st_hls_split);
        for (cmp_i = 0; cmp_i < n_cap_app; cmp_i = cmp_i + 1)
            $display("P5US app#%0d len=%0d sport=%04h (exp idx %0d len=%0d)",
                     cmp_i, c_len[cmp_i], c_sport[cmp_i],
                     cmp_i, (cmp_i < n_exp_app) ? a_exp_len[cmp_i] : 16'hFFFF);

        // E: 绝不反压
        chk(stall_cyc == 0, "s_axis_tready 曾为 0 (反压) —— 违反绝不反压铁律");

        // B: 透传逐字保真 (字序列 + 全部侧带)
        chk(n_cap_pb == n_exp_pb, "透传字数不符");
        bad_pb = 0;
        for (cmp_i = 0; cmp_i < n_exp_pb; cmp_i = cmp_i + 1) begin
            if (cmp_i < n_cap_pb && cap_pb[cmp_i] !== exp_pb[cmp_i]) begin
                if (bad_pb < 3)
                    $display("  PB#%0d exp=%019h got=%019h",
                             cmp_i, exp_pb[cmp_i], cap_pb[cmp_i]);
                bad_pb = bad_pb + 1;
            end
        end
        chk(bad_pb == 0, "透传字序列/侧带不符 (非 UDP 帧必须逐字节透传)");

        // C/D: app 口
        chk(n_cap_app == n_exp_app, "app 帧数不符");
        chk(app_bad_sof == 0,   "app 口出现半帧 (未闭合就开新帧)");
        chk(app_bad_tkeep == 0, "app 口 tkeep 非高位连续");
        chk(app_bad_len == 0,   "app 帧字节数 != len (重复/丢字)");
        chk(app_open == 0,      "app 口仿真结束仍挂着未闭合帧");
        bad_app = 0;
        for (cmp_i = 0; cmp_i < n_exp_app; cmp_i = cmp_i + 1) begin
            if (cmp_i < n_cap_app) begin
                if (c_len[cmp_i] !== a_exp_len[cmp_i] ||
                    c_sip[cmp_i] !== a_exp_sip[cmp_i] ||
                    c_sport[cmp_i] !== a_exp_sport[cmp_i]) begin
                    if (bad_app < 4)
                        $display("  APP#%0d meta: len=%0d/%0d sip=%08h/%08h sport=%04h/%04h",
                                 cmp_i, c_len[cmp_i], a_exp_len[cmp_i],
                                 c_sip[cmp_i], a_exp_sip[cmp_i],
                                 c_sport[cmp_i], a_exp_sport[cmp_i]);
                    bad_app = bad_app + 1;
                end
                for (cmp_j = 0; cmp_j < c_len[cmp_i]; cmp_j = cmp_j + 1) begin
                    if (c_bytes[c_off[cmp_i] + cmp_j] !==
                        a_exp_bytes[a_exp_off[cmp_i] + cmp_j]) begin
                        if (bad_app < 4)
                            $display("  APP#%0d byte@%0d got=%02h exp=%02h",
                                     cmp_i, cmp_j, c_bytes[c_off[cmp_i]+cmp_j],
                                     a_exp_bytes[a_exp_off[cmp_i]+cmp_j]);
                        bad_app = bad_app + 1;
                        cmp_j = c_len[cmp_i];
                    end
                end
            end
        end
        chk(bad_app == 0, "app 帧字节/meta 不符");

        // D: 弱点消解 + 统计口径
        chk(st_app_frames == n_exp_app, "stat_app_frames != 交付帧数");
        chk(st_app_bytes == a_exp_blen, "stat_app_bytes != 交付字节数");
        chk(st_drop_crc  == 32'd1, "stat_drop_crc != 1 (坏 FCS 未整帧丢)");
        chk(st_drop_part >= 32'd2, "stat_drop_part < 2 (长度不符残帧未回卷)");
        chk(st_app_null  == 32'd1, "stat_app_null != 1 (0 长数据报未交付 null beat)");
        chk(st_drop_excl >= 32'd3, "stat_drop_excl < 3 (8080 排除未生效)");
        chk(st_drop_ovf  >= 32'd1, "stat_drop_ovf < 1 (缓冲满未整帧丢)");
        // 身份: 每条被判定为 app 的帧, 要么交付, 要么被 app 路计数丢弃 (无第三态)
        chk(st_hls_split == (n_exp_app + st_drop_crc + st_drop_part + st_drop_ovf),
            "stat_hls_split != 交付数 + app 路丢弃数");
        // 契约 (p_axis_tready 恒 1) 下, HLS 路一帧都不该被 shim 丢
        chk(st_hls_drop == 32'd0, "stat_hls_drop != 0 (透传缓冲满丢帧, 违反契约)");

        if (fail == 0) $display("P5 UDP SPLIT UNIT OK");
        else           $display("P5 UDP SPLIT UNIT FAIL %0d", fail);
        $finish;
    end

    // 可选事件探针: +DBG 打开 (默认关, 不影响判据)
    integer dbg_on;
    initial dbg_on = $test$plusargs("DBG") ? 1 : 0;
    always @(posedge clk) begin
        if (dbg_on && rst_n &&
            (dut.pre_pop || dut.pb_pop || dut.pb_dec_cyc || dut.pb_rollbk ||
             dut.u_m_v || dut.uf_rollbk))
            $display("DBG t=%0t pw=%0d/%0d sop=%b decc=%b deca=%b rel=%b sw=%b pb(v=%b occ=%0d hold=%0d wr=%b pop=%b w=%0d r=%0d snap=%b roll=%b) ufm=%b ufocc=%0d ufhold=%0d ufroll=%b",
                $time, dut.pw_cnt, dut.pw_idx, dut.pw_sop_w, dut.pb_dec_cyc,
                dut.pb_dec_app, dut.rel_r, dut.swallow_r, dut.pb_valid, dut.pb_occ,
                dut.hold_rem_p, dut.pb_wr, dut.pb_pop,
                dut.pb_wptr, dut.pb_rptr, dut.pb_snap, dut.pb_rollbk,
                dut.u_m_v, dut.uf_occ, dut.hold_rem_u, dut.uf_rollbk);
        if (dbg_on && rst_n && dut.u_meta_valid)
            $display("DBG META t=%0t open=%b wptr=%0d rptr=%0d occ=%0d abort=%b snapend=%b",
                     $time, dut.u_open_r, dut.uf_wptr, dut.uf_rptr, dut.uf_occ,
                     dut.u_abort_r, dut.u_snpend_r);
    end

    // 看门狗 (600k 拍 = 需用量的 ~20 倍)
    initial begin
        repeat (600000) @(posedge clk);
        $display("P5 UDP SPLIT UNIT FAIL 1 (timeout)");
        $finish;
    end
endmodule
