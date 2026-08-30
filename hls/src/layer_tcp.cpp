//=============================================================================
// layer_tcp.cpp — TCP Echo Server (Phase 6d — full TCP)
//=============================================================================
// MAX_TCP_CONN connections (default 3). Port 7 echo.
// TCP Reno + sliding window + adaptive RTO + MSS/Window Scale options.
//=============================================================================
#include "eth_types.h"
#include "eth_utils.h"

#ifndef MAX_TCP_CONN
#define MAX_TCP_CONN     3
#endif

// ARP lookup (defined in layer_arp.cpp — same translation unit).
bool arp_lookup(arp_entry_t *table, ap_uint<32> ip, mac_addr_t &mac);

#define TCP_PORT_ECHO    8080
// P4b (udp_hls_10g 副本): 通告 MSS=1460 — 数据面全在 fast path RTL
// (1460B 段随便吃), HLS 只见 SYN/FIN/RST 控制帧, 原 460 是 HLS 自带
// 数据面缓冲 (536B) 的历史限制, 在此副本里无意义且压制对端段大小。
#define TCP_MSS          1460
#define TCP_SEND_BUF     (TCP_RX_PAYLOAD)
// FIX 2026-08-18: the TX frame lives at TX_UDP_BASE (384); the region ends
// at word 512. IP(5) + TCP(5) leaves 123 words = 492 bytes, so a payload
// chunk must not exceed 472 bytes or the frame overruns the buffer.
#define TCP_TX_CHUNK     536
// FIX 2026-08-19 (agent): Windows IGNORES the advertised MSS=460 and sends
// 536-byte segments (IP total 576) regardless. The old payload[] array was
// TCP_MSS(460) wide with a fill guard `plen<=TCP_MSS`, so a 536B segment
// left payload[] unpopulated (HLS compiled the guard to `(plen!=0 && plen<=460)
// ? plen : 1` — one byte!) and the echo carried stale BRAM contents. Size the
// RX payload buffer for the largest segment the peer can actually send
// (536B) so echo data is always populated correctly.
#define TCP_RX_PAYLOAD    576   // room for a full 536B segment + margin
#define TCP_RTO_MIN      10000000   // ~80ms min RTO
#define TCP_RTO_MAX      80000000   // ~640ms max RTO
// P4b: SYN+ACK/FIN+ACK 重传限次 — fast path 乐观建连后 HLS 永远收不到握手
// ACK (纯 ACK 进 fast path), 无限重传会向对端发垃圾 SYN+ACK 触发 RST 杀连接
#define TCP_MAX_RETRY    3
#define TCP_HEADER_BYTES 20
#define TCP_MAX_HDR      24   // 20 base + 4 options (MSS only; WS 已移除)
#define TCP_BUF_BASE     (TX_SCRATCH_BASE + 16)
#define TCP_ALPHA_SHIFT  3   // srtt weight = 1/8
#define TCP_BETA_SHIFT   2   // rttvar weight = 1/4
#define TCP_ALPHA_SHIFT  3   // srtt weight = 1/8
#define TCP_BETA_SHIFT   2   // rttvar weight = 1/4

#define TCP_FIN 0x01
#define TCP_SYN 0x02
#define TCP_RST 0x04
#define TCP_PSH 0x08
#define TCP_ACK 0x10

enum TCP_ST { T_FREE=0, T_LISTEN=1, T_SYN_RCVD=2, T_ESTABLISHED=3, T_LAST_ACK=4 };

struct tcp_conn_t {
    // Connection identity
    uint8_t  state;
    uint16_t peer_port;
    uint32_t peer_ip;
    uint32_t peer_window;   // advertised window (scaled)
    uint16_t peer_mss;       // peer's MSS from SYN option
    uint8_t  peer_wscale;    // peer's window scale shift
    uint8_t  our_wscale;     // our window scale shift (sends 7 for ×128)
    // Sequence tracking
    uint32_t seq;           // next byte to send
    uint32_t peer_seq;      // next byte expected from peer
    uint32_t last_ack_recv; // last ACK value (for dup detection)
    uint8_t  dup_ack_cnt;   // duplicate ACK count (fast retransmit)
    // Congestion control (Reno)
    uint32_t cwnd;          // congestion window (bytes)
    uint32_t ssthresh;      // slow start threshold
    uint32_t flight_size;   // bytes sent but unacked
    // RTT estimation (Van Jacobson — values scaled by 8)
    uint32_t srtt;          // smoothed RTT << 3
    uint32_t rttvar;        // RTT variation << 2
    uint32_t rto;           // current RTO
    uint32_t rto_timer;     // retransmission timer
    uint32_t rtt_seq;       // SEQ being timed for RTT measurement
    uint32_t rtt_start;     // timer value when timed segment was sent
    // Retransmit buffer
    uint16_t retrans_len;
    uint8_t  retrans_flags;
    bool     retrans_pending;
    uint8_t  retry_cnt;     // P4b: SYN+ACK/FIN+ACK 重传次数 (限 TCP_MAX_RETRY)
};
static tcp_conn_t tcp_conn[MAX_TCP_CONN];
static uint8_t    tcp_retrans_buf[MAX_TCP_CONN][TCP_RX_PAYLOAD];  // BRAM


//=============================================================================
// Helpers
//=============================================================================
static int8_t tcp_find(uint16_t port, uint32_t ip) {
    int8_t free=-1;
    for(int i=0;i<MAX_TCP_CONN;i++){
        #pragma HLS UNROLL
        if(tcp_conn[i].state!=T_FREE&&tcp_conn[i].peer_port==port&&tcp_conn[i].peer_ip==ip)return i;
        if(tcp_conn[i].state==T_FREE&&free<0)free=i;
    }return free;
}

//=============================================================================
// P4b: 配置记录写 (cfg_stream, 8x32bit) — 握手/拆除结果推送给 fast path
// CAM/TCB (唯一状态源在 fast 数据面)。记录布局 (slow_cfg_adp 解析):
//   w0 = (wscale<<16)|(cmd<<8)|slot   (cmd: 0=CFG_ADD, 1=CFG_DEL)
//        wscale = 对端 window scale (SYN 选项解析) — fast 侧 snd_wnd drain 缩放用
//   w1 = peer_ip            w2 = local_ip (192.168.100.2)
//   w3 = (peer_port<<16)|local_port
//   w4 = peer_mac[47:16]    w5 = (peer_mac[15:0]<<16)|peer_wnd (已按 wscale 缩放)
//   w6 = rcv_nxt (=peer ISS+1)
//   w7 = snd_nxt (=我方 SYN+ACK 发送后的 c.seq = ISS+1)
// DEL 只需 w0 (其余写 0, 定长 8 词保解析器简单)。
//=============================================================================
#define CFG_CMD_ADD 0
#define CFG_CMD_DEL 1
static void cfg_write(hls::stream<ap_uint<32> > &cfg_stream, uint8_t cmd,
                      int8_t cid, uint32_t peer_ip, uint16_t peer_port,
                      uint64_t peer_mac, uint16_t peer_wnd, uint8_t wscale,
                      uint32_t rcv_nxt, uint32_t snd_nxt){
    ap_uint<32> w[8];
    w[0]=((ap_uint<32>)wscale<<16)|((ap_uint<32>)cmd<<8)|(ap_uint<32>)(uint8_t)cid;
    if(cmd==CFG_CMD_ADD){
        // P4b-6: peer_wnd 先按 wscale 缩放再钳 16 位 — fast 侧门控直接可比;
        // drain 路径 (tcp_rx) 另按 wscale 缩放每帧通告, 两处量纲一致。
        uint32_t pw=(uint32_t)peer_wnd<<wscale;
        uint16_t wnd16=(pw>0xFFFF)?0xFFFF:(uint16_t)pw;
        w[1]=peer_ip;
        w[2]=(BOARD_IP_BYTE0<<24)|(BOARD_IP_BYTE1<<16)|(BOARD_IP_BYTE2<<8)|BOARD_IP_BYTE3;
        w[3]=((ap_uint<32>)peer_port<<16)|(ap_uint<32>)TCP_PORT_ECHO;
        w[4]=(ap_uint<32>)(peer_mac>>16);
        w[5]=((ap_uint<32>)(peer_mac&0xFFFF)<<16)|(ap_uint<32>)wnd16;
        w[6]=rcv_nxt;
        w[7]=snd_nxt;
    }else{
        for(int i=1;i<8;i++)w[i]=0;
    }
    for(int i=0;i<8;i++)cfg_stream.write(w[i]);
}
static uint16_t tcp_csum(uint32_t sip, uint32_t dip, const uint8_t *d, uint16_t len){
    uint32_t s=6+len;s+=(sip>>16)&0xFFFF;s+=sip&0xFFFF;s+=(dip>>16)&0xFFFF;s+=dip&0xFFFF;
    for(int i=0;i<len-1;i+=2)s+=((uint16_t)d[i]<<8)|d[i+1];
    if(len&1)s+=((uint16_t)d[len-1]<<8);
    while(s>>16)s=(s&0xFFFF)+(s>>16);
    return(uint16_t)(~s);
}
static void tcp_build_hdr(uint8_t*b,uint16_t sp,uint16_t dp,uint32_t seq,uint32_t ack,uint8_t f,uint16_t w,bool syn){
    bool has_opts=syn;uint8_t doff=has_opts?6:5; // 20+4=24 bytes when SYN (MSS only)
    b[0]=(sp>>8)&0xFF;b[1]=sp&0xFF;b[2]=(dp>>8)&0xFF;b[3]=dp&0xFF;
    b[4]=(seq>>24)&0xFF;b[5]=(seq>>16)&0xFF;b[6]=(seq>>8)&0xFF;b[7]=seq&0xFF;
    b[8]=(ack>>24)&0xFF;b[9]=(ack>>16)&0xFF;b[10]=(ack>>8)&0xFF;b[11]=ack&0xFF;
    b[12]=(doff<<4);b[13]=f;b[14]=(w>>8)&0xFF;b[15]=w&0xFF;
    b[16]=0;b[17]=0;b[18]=0;b[19]=0;
    if(has_opts){
        // P4b-6 板测实锤: 不再通告 WS — 若通告 our_wscale=7, rcv_wnd 0x3000 被
        // 对端放大 128 倍 (1.5MB), 远超 echo 管道容量 (~17KB); 门控一关闭 PC
        // 继续狂发把管道塞满 → RX 拥塞连 ACK 都进不来 → 永久死锁 (需重烧板)。
        // 不缩放时 PC 在飞 ≤ 0x3000 < 管道容量, ACK 恒可穿过, 门控自然恢复。
        b[20]=2;b[21]=4;b[22]=(TCP_MSS>>8)&0xFF;b[23]=TCP_MSS&0xFF; // MSS=1460
    }
}

//=============================================================================
// Congestion control: process ACK (updates cwnd, ssthresh per Reno)
//=============================================================================
static void tcp_reno_on_ack(tcp_conn_t &c, uint32_t new_ack, bool new_data){
    uint32_t bytes_acked = new_ack - c.last_ack_recv;  // how much was ACKed
    if(bytes_acked==0){
        // Duplicate ACK
        if(++c.dup_ack_cnt==3){
            // Fast retransmit: retransmit oldest unacked
            c.dup_ack_cnt=0;
            c.ssthresh=(c.flight_size/2>2*TCP_MSS)?c.flight_size/2:2*TCP_MSS;
            c.cwnd=c.ssthresh+3*TCP_MSS;
            // retransmit triggered in caller
            c.retrans_pending=true;c.rto_timer=0;
        }else if(c.dup_ack_cnt>3){
            c.cwnd+=TCP_MSS;  // inflate cwnd per dup ACK
        }
        return;
    }
    // New ACK — reset dup counter
    c.dup_ack_cnt=0;
    // Update flight size
    if(c.flight_size>=bytes_acked)c.flight_size-=bytes_acked;else c.flight_size=0;
    c.last_ack_recv=new_ack;
    // Congestion window update
    if(c.cwnd<c.ssthresh){
        c.cwnd+=TCP_MSS;  // slow start: exponential
        if(c.cwnd>c.ssthresh)c.cwnd=c.ssthresh;
    }else{
        c.cwnd+=(TCP_MSS*TCP_MSS)/c.cwnd;  // congestion avoidance: linear
    }
}

//=============================================================================
// RTO update (Van Jacobson)
//=============================================================================
static void tcp_update_rto(tcp_conn_t &c, uint32_t rtt_sample){
    if(c.srtt==0){
        c.srtt=rtt_sample<<TCP_ALPHA_SHIFT;
        c.rttvar=rtt_sample<<(TCP_BETA_SHIFT-1);
    }else{
        int32_t delta=rtt_sample-(c.srtt>>TCP_ALPHA_SHIFT);
        if(delta<0)delta=-delta;
        c.rttvar=(c.rttvar*c.srtt+delta*(4-1)/*/1<<TCP_BETA_SHIFT*/)/4; // simplified
        c.srtt=c.srtt-(c.srtt>>TCP_ALPHA_SHIFT)+rtt_sample;
    }
    uint32_t rto=(c.srtt>>TCP_ALPHA_SHIFT)+(c.rttvar<<(TCP_BETA_SHIFT-1));
    if(rto<TCP_RTO_MIN)rto=TCP_RTO_MIN;
    if(rto>TCP_RTO_MAX)rto=TCP_RTO_MAX;
    c.rto=rto;
}

//=============================================================================
// Send TCP segment
//=============================================================================
static void tcp_send(uint32_t *buf, mac_tx_req_t &tx_req, int8_t cid,
                     uint8_t flags, const uint8_t *payload, uint16_t pay_len){
    if(cid<0||cid>=MAX_TCP_CONN)return;
    tcp_conn_t &c=tcp_conn[cid];
    uint8_t seg[TCP_MAX_HDR+TCP_TX_CHUNK];
    // FIX 2026-08-18: SYN and SYN-ACK segments carry the 8-byte options
    // block (doff=7); total must include it or the options never reach the
    // wire (segment shorter than the header claims -> malformed).
    bool has_opts=(flags&TCP_SYN)!=0;
    uint16_t total=(has_opts?TCP_MAX_HDR:TCP_HEADER_BYTES)+pay_len;
    uint32_t sip=(BOARD_IP_BYTE0<<24)|(BOARD_IP_BYTE1<<16)|(BOARD_IP_BYTE2<<8)|BOARD_IP_BYTE3;
    tcp_build_hdr(seg,TCP_PORT_ECHO,c.peer_port,c.seq,c.peer_seq,flags,0xFFFF,has_opts);
    if(payload&&pay_len>0){for(int i=0;i<pay_len;i++)seg[TCP_HEADER_BYTES+i]=payload[i];}
    uint16_t cs=tcp_csum(sip,c.peer_ip,seg,total);seg[16]=(cs>>8)&0xFF;seg[17]=cs&0xFF;
    // Update SEQ and flight size
    // FIX 2026-08-18: inc was uint8_t — payloads >=256 bytes truncated the
    // sequence advance (472 -> 216), desyncing the connection.
    if(pay_len>0||(flags&(TCP_SYN|TCP_FIN))){uint32_t inc=((flags&TCP_SYN)?1:0)+((flags&TCP_FIN)?1:0)+pay_len;c.seq+=inc;c.flight_size+=inc;}
    // IP header
    int ipb=TX_UDP_BASE;uint16_t ipt=20+total;uint8_t ip[20];
    ip[0]=0x45;ip[1]=0;ip[2]=(ipt>>8)&0xFF;ip[3]=ipt&0xFF;ip[4]=0;ip[5]=0;ip[6]=0x40;ip[7]=0;
    ip[8]=128;ip[9]=6;ip[10]=0;ip[11]=0;
    ip[12]=BOARD_IP_BYTE0;ip[13]=BOARD_IP_BYTE1;ip[14]=BOARD_IP_BYTE2;ip[15]=BOARD_IP_BYTE3;
    ip[16]=(c.peer_ip>>24)&0xFF;ip[17]=(c.peer_ip>>16)&0xFF;ip[18]=(c.peer_ip>>8)&0xFF;ip[19]=c.peer_ip&0xFF;
    uint16_t iw[10];for(int i=0;i<10;i++)iw[i]=((uint16_t)ip[i*2]<<8)|ip[i*2+1];
    uint16_t ic=ones_complement_checksum(iw,10);ip[10]=(ic>>8)&0xFF;ip[11]=ic&0xFF;
    for(int i=0;i<5;i++)buf[ipb+i]=((uint32_t)ip[i*4]<<24)|((uint32_t)ip[i*4+1]<<16)|((uint32_t)ip[i*4+2]<<8)|ip[i*4+3];
    // FIX 2026-08-18: write the segment DIRECTLY at ipb+5. The previous
    // TCP_BUF_BASE staging + copy hop was doubly broken: the source range
    // (TCP_BUF_BASE=272 .. +123 words = 394) overlaps BOTH the destination
    // region (ipb+5=389) and the IP header location (ipb=384..388), so large
    // segments copied the freshly-written IP header into the payload.
    for(int i=0;i<(total+3)/4;i++){
        uint32_t w=((uint32_t)seg[i*4]<<24)|((uint32_t)seg[i*4+1]<<16)|((uint32_t)seg[i*4+2]<<8)|seg[i*4+3];
        buf[ipb+5+i]=w;
    }
    // Retransmit save
    if(flags&TCP_SYN){c.retrans_flags=flags;c.retrans_len=0;c.retrans_pending=true;c.rto_timer=0;}
    else if(pay_len>0){c.retrans_flags=flags;c.retrans_len=pay_len;c.retrans_pending=true;c.rto_timer=0;for(int i=0;i<pay_len;i++)tcp_retrans_buf[cid][i]=payload[i];}
    // RTT measurement
    if(pay_len>0&&c.rtt_seq==0){c.rtt_seq=c.seq-pay_len;c.rtt_start=0;/* timer reset */}
    // FIX 2026-08-18: unicast to the peer when known (ARP cache), like ICMP;
    // broadcast fallback otherwise.
    mac_addr_t reply_mac=0xFFFFFFFFFFFFULL;
    if(arp_lookup(NULL,c.peer_ip,reply_mac)){}
    tx_req.dst_mac=reply_mac;tx_req.ethertype=ETHERTYPE_IPV4;tx_req.buf_addr=ipb;tx_req.buf_len=ipt;tx_req.request=true;
}

//=============================================================================
// Echo segment -> TX frame (busy-gated queue, FIX 2026-08-19)
//=============================================================================
// The MAC TX is single-buffered: the shared TX region (TX_UDP_BASE) is read
// by the MAC while a frame is in flight, so an echo build that runs during
// the transmission clobbers the in-flight frame (observed on the board: a
// burst of echo frames got mixed segment contents and were FCS-dropped).
//   * when the MAC is idle: the echo is built IMMEDIATELY in the same pass;
//   * when the MAC is busy: the payload is parked in a queue (global BRAM +
//     scalar register state) and sent by tcp_maintenance on an idle pass,
//     one chunk per pass, in order.
//=============================================================================
static uint8_t  tcp_send_bufs[MAX_TCP_CONN][TCP_RX_PAYLOAD]; // BRAM
static bool     tcp_retrans_due = false;  // idle-gated RTO retransmission
static int8_t   tcp_retrans_cid = 0;
static uint16_t tcp_q_len = 0;     // bytes queued (send_bufs[cid][0..len-1])
static uint16_t tcp_q_off = 0;     // next byte to send
static int8_t   tcp_q_cid = 0;     // connection owning the queue

static void tcp_queue(uint32_t *buf, mac_tx_req_t &tx_req, int8_t cid,
                      const uint8_t *payload, uint16_t pay_len,
                      bool mac_busy){
    if(cid<0||cid>=MAX_TCP_CONN||pay_len==0)return;
    // Always queue. The immediate-send path was removed: its gate
    // (!mac_busy && !tx_req.request) could appear "idle" in the same pass
    // the MAC commits to reading the buffer, causing a write/read race.
    // tcp_maintenance flushes the queue when the top level sees the MAC
    // truly idle, one chunk per pass.
    if(tcp_q_len==tcp_q_off){tcp_q_len=0;tcp_q_off=0;tcp_q_cid=cid;}
    uint16_t room=TCP_SEND_BUF-tcp_q_len;
    if(room>pay_len)room=pay_len;
    for(int i=0;i<room;i++)tcp_send_bufs[cid][tcp_q_len+i]=payload[i];
    tcp_q_len+=room;
}

//=============================================================================
// TCP maintenance: flush the echo queue whenever the MAC is idle
//=============================================================================
// Called every pass from the top level (when !tx_req.request && !tx_busy).
// Sends at most ONE chunk per pass.
//=============================================================================
static void tcp_maintenance(uint32_t *buf, mac_tx_req_t &tx_req){
    if(tcp_retrans_due&&!tx_req.request){
        int8_t i=tcp_retrans_cid;
        tcp_conn_t &c=tcp_conn[i];
        if(c.state==T_SYN_RCVD)tcp_send(buf,tx_req,i,TCP_SYN|TCP_ACK,NULL,0);
        else if(c.state==T_ESTABLISHED&&c.retrans_len>0)tcp_send(buf,tx_req,i,TCP_ACK,tcp_retrans_buf[i],c.retrans_len);
        else if(c.state==T_LAST_ACK)tcp_send(buf,tx_req,i,TCP_FIN|TCP_ACK,NULL,0);
        tcp_retrans_due=false;
        return;
    }
    if(tcp_q_len>tcp_q_off&&!tx_req.request){
        uint16_t rem=tcp_q_len-tcp_q_off;
        uint16_t chunk=(rem>TCP_TX_CHUNK)?TCP_TX_CHUNK:rem;
        tcp_send(buf,tx_req,tcp_q_cid,TCP_ACK,tcp_send_bufs[tcp_q_cid]+tcp_q_off,chunk);
        tcp_q_off+=chunk;
        if(tcp_q_off>=tcp_q_len){tcp_q_len=0;tcp_q_off=0;}
    }
}

//=============================================================================
// TCP RX processing
//=============================================================================
static void tcp_rx_process(bool rst, ip_rx_t &ip_rx, uint32_t *buf, mac_tx_req_t &tx_req, bool mac_busy,
                           hls::stream<ap_uint<32> > &cfg_stream, uint64_t rx_smac){
    #pragma HLS RESOURCE variable=tcp_retrans_buf core=RAM_2P_BRAM
    #pragma HLS RESOURCE variable=tcp_send_bufs core=RAM_2P_BRAM
    #pragma HLS RESOURCE variable=tcp_conn core=RAM_2P_BRAM
    if(!rst){for(int i=0;i<MAX_TCP_CONN;i++)tcp_conn[i].state=T_FREE;return;}
    // Retransmission + send flush scan
    if(!ip_rx.valid||ip_rx.protocol!=6){
        for(int i=0;i<MAX_TCP_CONN;i++){
            #pragma HLS UNROLL
            tcp_conn_t &c=tcp_conn[i];
            // RTO retransmission.
            // FIX 2026-08-19: do NOT call tcp_send here — the MAC may be
            // mid-send (reading TX_UDP_BASE); a retransmit would clobber the
            // in-flight frame. Mark the retransmission due; tcp_maintenance
            // (idle-gated) performs it.
            if(c.retrans_pending){
                c.rto_timer++;
                if(c.rto_timer>=c.rto){
                    c.rto_timer=0;
                    // Backoff: double RTO
                    c.rto*=2;if(c.rto>TCP_RTO_MAX)c.rto=TCP_RTO_MAX;
                    c.ssthresh=(c.flight_size/2>2*TCP_MSS)?c.flight_size/2:2*TCP_MSS;
                    c.cwnd=TCP_MSS; // collapse cwnd on timeout
                    c.flight_size=0;
                    c.dup_ack_cnt=0;
                    // P4b-5 板测实锤: SYN+ACK 定时重传 (~2.6s) 会打在已建立
                    // 连接上 — 对端 (Windows) 收意外 SYN 直接 RST 杀连接
                    // (吞吐测试每次恰在 2.6s 死, ConnectionResetError)。
                    // 修复: T_SYN_RCVD 超时**不重传** — 释放半开槽位即可
                    // (SYN+ACK 丢失由对端 SYN 重传驱动, T_SYN_RCVD 的 re-SYN
                    // 分支原样重发; 连接已建立时对端不会重发 SYN, 槽位释放
                    // 不影响 fast 数据面)。T_LAST_ACK 保留限次重传 (FIN+ACK)。
                    if(c.state==T_SYN_RCVD){
                        c.state=T_FREE;
                        c.retrans_pending=false;
                        continue;
                    }
                    if(c.state==T_LAST_ACK){
                        c.retry_cnt++;
                        if(c.retry_cnt>TCP_MAX_RETRY){
                            c.state=T_FREE;
                            c.retrans_pending=false;
                            continue;
                        }
                    }
                    tcp_retrans_due=true;
                    tcp_retrans_cid=i;
                }
            }
            // The echo queue is flushed by tcp_maintenance (called every
            // idle pass from the top level), so no send here.
        }
        return;
    }
    // Parse TCP header — read from the staged frame buffer (0-based; udp_echo
    // popped this frame from frame_fifo into frame_buf). frame_buf[0] is the
    // first IP word, so the TCP header starts at word 5 (20-byte IP header).
    int tb=5;uint8_t th[20];
    for(int i=0;i<5;i++){uint32_t w=frame_buf[tb+i];th[i*4]=(w>>24)&0xFF;th[i*4+1]=(w>>16)&0xFF;th[i*4+2]=(w>>8)&0xFF;th[i*4+3]=w&0xFF;}
    uint16_t sp=((uint16_t)th[0]<<8)|th[1],dp=((uint16_t)th[2]<<8)|th[3];
    uint32_t seq=((uint32_t)th[4]<<24)|((uint32_t)th[5]<<16)|((uint32_t)th[6]<<8)|th[7];
    uint32_t ack=((uint32_t)th[8]<<24)|((uint32_t)th[9]<<16)|((uint32_t)th[10]<<8)|th[11];
    uint8_t doff=(th[12]>>4)&0xF,flags=th[13];
    uint16_t wnd=((uint16_t)th[14]<<8)|th[15];
    uint16_t tlen=ip_rx.total_len-IP_HEADER_BYTES,plen=tlen-(doff*4);
    if(dp!=TCP_PORT_ECHO)return;
    // Read payload. FIX 2026-08-19: sized TCP_RX_PAYLOAD (576) and populated
    // for any plen up to that — a peer that ignores MSS=460 sends 536B
    // segments, which the old TCP_MSS(460)-wide buffer silently dropped.
    uint8_t payload[TCP_RX_PAYLOAD];
    if(plen>0&&plen<=TCP_RX_PAYLOAD){int ps=tb+doff;for(int i=0;i<plen;i++){uint16_t wi=ps+(i>>2),bi=i&0x3;payload[i]=(frame_buf[wi]>>((3-bi)*8))&0xFF;}}
    int8_t cid=tcp_find(sp,ip_rx.src_ip);
    // FIX 2026-08-18: tcp_find() returns a free slot index (>=0) when no
    // connection matches, so the old `cid<0` test was never true and every
    // SYN was dropped (new-connection init skipped -> T_FREE -> return).
    // A new connection is a free slot carrying a SYN.
    if(cid>=0&&tcp_conn[cid].state==T_FREE&&(flags&TCP_SYN)&&!(flags&TCP_ACK)){
        tcp_conn_t &c=tcp_conn[cid];c.state=T_LISTEN;c.cwnd=TCP_MSS;c.ssthresh=65535;
        c.srtt=0;c.rttvar=0;c.rto=TCP_RTO_MIN;c.dup_ack_cnt=0;c.seq=0x12345678|(cid<<20);c.peer_seq=0;c.last_ack_recv=0;c.flight_size=0;
        c.retry_cnt=0;   // P4b
        c.peer_mss=TCP_MSS;c.peer_wscale=0;c.our_wscale=0;
        // Parse MSS/WS options from SYN (bytes 20+ of TCP header).
        // FIX 2026-08-18: read the option bytes from the RX buffer, not from
        // th[] (only 20 bytes were loaded -> out-of-bounds reads gave garbage
        // MSS/window-scale). Clamp to 0..14 (RFC 7323 max; cfg w0[19:16]
        // 4 bits 装得下)。P4b-6 板测实锤: 旧钳 7 把 Windows 的 ws=8 变 0 →
        // fast 门控用原始窗口 4096 → 7 帧后永久死锁 (~19s RST)。
        if(doff>5){uint8_t opt_end=(doff-5)*4;for(int o=0;o+1<opt_end;){
            int obw=(tb*4+20+o)>>2;uint8_t obi=(tb*4+20+o)&3;
            uint8_t k=(frame_buf[obw]>>((3-obi)*8))&0xFF;if(k==0)break;if(k==1){o++;continue;}
            if(o+1>=opt_end)break;
            int lbw=(tb*4+20+o+1)>>2;uint8_t lbi=(tb*4+20+o+1)&3;
            uint8_t ln=(frame_buf[lbw]>>((3-lbi)*8))&0xFF;if(ln<2)break;
            if(k==2&&ln>=4){int mw=(tb*4+20+o+2)>>2;uint8_t mi=(tb*4+20+o+2)&3;
                c.peer_mss=(((uint16_t)((frame_buf[mw]>>((3-mi)*8))&0xFF)<<8)|((frame_buf[(tb*4+20+o+3)>>2]>>((3-((tb*4+20+o+3)&3))*8))&0xFF));}
            else if(k==3&&ln>=3){int ww=(tb*4+20+o+2)>>2;uint8_t wi=(tb*4+20+o+2)&3;
                uint8_t ws=(frame_buf[ww]>>((3-wi)*8))&0xFF;c.peer_wscale=(ws<=14)?ws:0;}
            o+=ln;
        }}
        // Adjust cwnd to peer's MSS if smaller
        if(c.peer_mss<TCP_MSS&&c.peer_mss>0){c.cwnd=c.peer_mss;}}
    // P4b: RST 处理前移 — 4 元组命中任一槽 (含重传超限已释放槽, 其
    // peer_ip/peer_port 保留) 均清拆 + CFG_DEL: 释放槽的 fast 条目可能
    // 残留 (超限释放不清 fast), RST 是对端明确放弃信号, 补刀安全。
    // 未命中则静默 — 乱选空闲槽发 DEL 会误杀同槽的活 fast 连接。
    if(flags&TCP_RST){
        for(int i=0;i<MAX_TCP_CONN;i++){
            #pragma HLS UNROLL
            if(tcp_conn[i].peer_port==sp&&tcp_conn[i].peer_ip==ip_rx.src_ip){
                tcp_conn[i].state=T_FREE;
                tcp_conn[i].retrans_pending=false;
                cfg_write(cfg_stream,CFG_CMD_DEL,i,0,0,0,0,0,0,0);
                return;
            }
        }
        return;
    }
    if(cid<0||cid>=MAX_TCP_CONN||tcp_conn[cid].state==T_FREE)return;
    tcp_conn_t &c=tcp_conn[cid];
    c.peer_window=(wnd>0)?(wnd<<c.peer_wscale):wnd;
    // Process ACK for congestion control
    if(flags&TCP_ACK){tcp_reno_on_ack(c,ack,false);/*ack!=c.last_ack_recv*/}
    switch(c.state){
        case T_LISTEN:if(flags&TCP_SYN){c.peer_seq=seq+1;c.peer_ip=ip_rx.src_ip;c.peer_port=sp;c.state=T_SYN_RCVD;c.retry_cnt=0;
                // P4b: 乐观建连 — 把连接配置推给 fast path (CAM/TCB),
                // 数据面直接可用。snd_nxt = ISS+1 (SYN 占一个序号,
                // tcp_send 稍后推进 c.seq, 故此处显式 +1)。
                // P4b-6 死锁修复: cfg 必须先于 tcp_send — 延迟处理路径
                // (mac 忙时) 的 cfg_stream 接受谓词 = tx_req.request==0;
                // 若 SYN+ACK 先置 request=1, 谓词死亡, cfg 写入永不被
                // 接受 → 顶层 FSM 卡死在子调用 (xsim 实锤: 收 SYN 后
                // 无 SYN+ACK 无 cfg, 板级 connect 超时)。
                cfg_write(cfg_stream,CFG_CMD_ADD,cid,c.peer_ip,c.peer_port,
                          rx_smac,wnd,c.peer_wscale,c.peer_seq,c.seq+1);
                tcp_send(buf,tx_req,cid,TCP_SYN|TCP_ACK,NULL,0);}break;
        case T_SYN_RCVD:if((flags&TCP_ACK)&&ack==c.seq){c.retrans_pending=false;c.state=T_ESTABLISHED;c.rto_timer=0;c.retry_cnt=0;}
            // P4b-5: 对端 SYN 重传 = SYN+ACK 丢失 — 原样重发 (seq 不变;
            // tcp_send 对 SYN 会再 +1, 先退一拍)。定时重传已废除 (会 RST
            // 活连接, 见 RTO 扫描处), 丢失恢复全靠此分支。
            else if((flags&TCP_SYN)&&!(flags&TCP_ACK)){
                c.seq--;
                tcp_send(buf,tx_req,cid,TCP_SYN|TCP_ACK,NULL,0);}
            // P4b: 乐观建连 — 第 3 个 ACK 走 fast path, HLS 永远停在 T_SYN_RCVD
            // (除非恰有慢路径 ACK); T_ESTABLISHED 的 FIN 分支因此是死代码。
            // 对端 FIN 必须在此应答: 发 FIN+ACK (seq 是旧值, 对端多半因
            // out-of-window 丢弃 — 无害) + CFG_DEL 拆 fast 条目 (关键)。
            // PC 侧 close 最终靠 RST 兜底完成, 但 fast 侧条目必须及时清。
            else if(flags&TCP_FIN){
                c.peer_seq=seq+1;
                // cfg 先于 tcp_send (延迟路径死锁, 见 T_LISTEN 注)
                cfg_write(cfg_stream,CFG_CMD_DEL,cid,0,0,0,0,0,0,0);
                tcp_send(buf,tx_req,cid,TCP_FIN|TCP_ACK,NULL,0);
                // 直接释放槽位: 最后 ACK 走 fast path, HLS 永远收不到 —
                // 进 T_LAST_ACK 要等 4 个 RTO (~13s) 限次重传才释放,
                // PC 连接循环 (每次新临时端口 = 新 4 元组 = 新槽) 会把
                // MAX_TCP_CONN=3 个槽全部占死, 第 4 次 connect 超时
                // (板测实锤)。FIN+ACK 的 seq 是旧值 (fast 数据面已推进
                // snd_nxt), 对端 out-of-window 丢弃 — 重传无意义,
                // PC close 靠 RST 兜底完成。
                c.state=T_FREE;c.retrans_pending=false;}
            break;
        case T_ESTABLISHED:
            c.peer_seq=seq+plen;if(flags&TCP_FIN)c.peer_seq++;
            if(plen>0){
                // Echo via the busy-gated queue: immediate when the MAC is
                // idle, parked otherwise (the MAC must never be writing the
                // TX region while it is being read by an in-flight frame).
                tcp_queue(buf,tx_req,cid,payload,plen,mac_busy);
            }else if(flags&TCP_ACK)c.retrans_pending=false;
            if(flags&TCP_FIN){c.state=T_LAST_ACK;
                // P4b: fast 侧拆除 (CFG_DEL); HLS 槽位等最后 ACK 释放。
                // cfg 先于 tcp_send (延迟路径死锁, 见 T_LISTEN 注)
                cfg_write(cfg_stream,CFG_CMD_DEL,cid,0,0,0,0,0,0,0);
                tcp_send(buf,tx_req,cid,TCP_FIN|TCP_ACK,NULL,0);}break;
        case T_LAST_ACK:if(flags&TCP_ACK){c.retrans_pending=false;c.state=T_FREE;}break;
    }
}
