/* peer.cpp -- synthetic TCP peer for board echo testing (prototype).
 *
 * Purpose
 * -------
 * The board (192.168.100.2:8080) is a pure-hardware TCP fast-path echo engine.
 * Testing it from a normal Python socket makes the Windows kernel a participant:
 * the kernel owns the connection, so it emits FIN/RST/delayed-ACK/retransmits of
 * its own.  Those stray frames pollute board-side counters (e.g. the MW word
 * counter read over UART) and their ACK numbers can make the kernel drop or
 * challenge-ACK the board's replies.
 *
 * This program implements TCP itself on top of npcap/WinPcap raw framing, so the
 * kernel never sees a connection it owns.  Combined with an inbound firewall
 * block on the board IP (tools/cpp_peer/fw_block.ps1) the kernel stays silent and
 * all observed traffic is ours.  Result: zero-noise measurement.
 *
 * No pcap SDK is required: the handful of WinPcap entry points we need are
 * declared here by hand and resolved by linking straight against wpcap.dll
 * (MinGW's ld can build an import table from the DLL's export table).
 *
 * Scope: prototype / test infrastructure.  Implements one connection at a time,
 * no SACK, no window scaling (the board advertises none), no options beyond MSS.
 *
 * Build: see build.bat   (MinGW-w64 g++, -static, links C:/Windows/System32/wpcap.dll)
 */

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>
#include <map>
#include <deque>
#include <thread>
#include <mutex>
#include <atomic>
#include <algorithm>

/* =====================================================================
 * 1. Minimal WinPcap / npcap ABI declarations (no SDK present on this host)
 * ===================================================================== */

typedef struct pcap pcap_t;

struct pc_timeval {
    long tv_sec;
    long tv_usec;
};

struct pcap_pkthdr {
    struct pc_timeval ts;
    unsigned int caplen;
    unsigned int len;
};

struct pcap_addr {
    struct pcap_addr *next;
    struct sockaddr *addr;
    struct sockaddr *netmask;
    struct sockaddr *broadaddr;
    struct sockaddr *dstaddr;
};

struct pcap_if {
    struct pcap_if *next;
    char *name;
    char *description;
    struct pcap_addr *addresses;
    unsigned int flags;
};

typedef struct pcap_if pcap_if_t;
typedef struct pcap_addr pcap_addr_t;

/* WinPcap 4.1+ bulk-send queue: one transmit call for many frames.  Per-frame
 * pcap_sendpacket costs ~80 us on this host, which alone caps throughput near
 * 9 MB/s -- batching is what makes the peer stop being the bottleneck. */
struct pcap_send_queue {
    unsigned int maxlen;
    unsigned int len;
    char        *buffer;
};

extern "C" {
int         pcap_findalldevs(pcap_if_t **alldevsp, char *errbuf);
void        pcap_freealldevs(pcap_if_t *alldevs);
pcap_t     *pcap_open_live(const char *device, int snaplen, int promisc, int to_ms,
                           char *errbuf);
void        pcap_close(pcap_t *p);
int         pcap_sendpacket(pcap_t *p, const unsigned char *buf, int size);
int         pcap_next_ex(pcap_t *p, struct pcap_pkthdr **pkt_header,
                         const unsigned char **pkt_data);
char       *pcap_geterr(pcap_t *p);
struct pcap_send_queue *pcap_sendqueue_alloc(unsigned int memsize);
unsigned int pcap_sendqueue_queue(struct pcap_send_queue *queue,
                                  const struct pcap_pkthdr *pkt_header,
                                  const unsigned char *pkt_data);
unsigned int pcap_sendqueue_transmit(pcap_t *p, struct pcap_send_queue *queue,
                                     int sync);
void        pcap_sendqueue_destroy(struct pcap_send_queue *queue);
int         pcap_setmintocopy(pcap_t *p, int size);
int         pcap_setbuff(pcap_t *p, int dim);

struct bpf_insn {
    unsigned short code;
    unsigned char  jt;
    unsigned char  jf;
    unsigned int   k;
};
struct bpf_program {
    unsigned int     bf_len;
    struct bpf_insn *bf_insns;
};
int         pcap_compile(pcap_t *p, struct bpf_program *fp, const char *str,
                         int optimize, unsigned int netmask);
int         pcap_setfilter(pcap_t *p, struct bpf_program *fp);
void        pcap_freecode(struct bpf_program *fp);
}

/* =====================================================================
 * 2. Wire format
 * ===================================================================== */

#pragma pack(push, 1)
struct EthHdr {
    uint8_t  dst[6];
    uint8_t  src[6];
    uint16_t type;
};
struct IpHdr {
    uint8_t  vihl;
    uint8_t  tos;
    uint16_t totlen;
    uint16_t id;
    uint16_t frag;
    uint8_t  ttl;
    uint8_t  proto;
    uint16_t csum;
    uint32_t src;
    uint32_t dst;
};
struct TcpHdr {
    uint16_t sport;
    uint16_t dport;
    uint32_t seq;
    uint32_t ack;
    uint8_t  doff;
    uint8_t  flags;
    uint16_t win;
    uint16_t csum;
    uint16_t urg;
};
#pragma pack(pop)

#define ETH_IP4   0x0800
#define ETH_VLAN  0x8100

#define TH_FIN 0x01
#define TH_SYN 0x02
#define TH_RST 0x04
#define TH_PSH 0x08
#define TH_ACK 0x10

static const int ETH_HDR_LEN = 14;
static const int ETH_MIN_FRAME = 60;   /* header+payload, FCS excluded */

/* ---------- byte order (winsock already gives htonl/ntohl on LE) ---------- */

static inline uint16_t rd16(const uint8_t *p) {
    uint16_t v;
    memcpy(&v, p, 2);
    return ntohs(v);
}
static inline uint32_t rd32(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return ntohl(v);
}

/* ---------- internet checksum ---------- */

/* NOTE: the accumulator MUST stay 32-bit across calls -- folding/casting to
 * 16 bits here would silently drop carries and produce bad checksums. */
static uint32_t csum_acc(uint32_t sum, const uint8_t *p, int len) {
    while (len > 1) {
        sum += ((uint32_t)p[0] << 8) | p[1];
        p += 2;
        len -= 2;
    }
    if (len == 1) sum += ((uint32_t)p[0] << 8);
    return sum;
}

static uint16_t csum_fold(uint32_t sum) {
    while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
    return (uint16_t)(~sum & 0xFFFF);
}

/* ---------- payload pattern ----------
 * The board is an echo engine: every byte we send must come back unchanged at
 * the same stream offset.  Verification therefore only needs the EXPECTED value
 * at a given offset, not a full copy of the transmitted buffer -- which is what
 * makes >=1 GB transfers cheap.
 *
 * The pattern is a 64 KiB pseudo-random block indexed by (offset & 0xFFFF), so
 * the payload repeats every 65536 bytes.  Consequence: a stream shift by an
 * exact multiple of 64 KiB is not detectable by value comparison alone; the
 * overall echoed length check still catches it.  Documented in README.
 */
#define PAY_PAT_LEN 65536
static uint8_t g_pat[PAY_PAT_LEN];

static void pat_init(void) {
    /* RTL convention (rtl/app_pattern.v:169/271): byte = s[31:24] THEN advance
     * (s ^= s<<13; s ^= s>>7; s ^= s<<17).  2026-09-19: this used to advance
     * first, which made the whole table one LFSR step ahead of the hardware
     * (peer[k] == RTL[k+1]).  The echo path never noticed (it generates and
     * verifies with the same table), but any verification of a BOARD-generated
     * stream would have failed 100%.  Fixed to take-then-advance. */
    uint64_t s = 0x9E3779B97F4A7C15ull;
    for (int i = 0; i < PAY_PAT_LEN; i++) {
        g_pat[i] = (uint8_t)(s >> 24);
        s ^= s << 13; s ^= s >> 7; s ^= s << 17;
    }
}
static inline uint8_t pay_byte(uint32_t off) { return g_pat[off & (PAY_PAT_LEN - 1)]; }

/* Fill segbuf with the payload for stream offsets [off, off+n) */
static void pay_fill(uint8_t *dst, uint32_t off, int n) {
    for (int i = 0; i < n; i++) dst[i] = pay_byte(off + (uint32_t)i);
}

/* ---------- RTL-pattern stream verifier (--rx-only) ----------
 * The board's demo app (rtl/app_pattern.v) runs ONE xorshift64 LFSR for its TX
 * direction: stream byte k is s_k[31:24] with s_0 = SEED = 0x9E3779B97F4A7C15
 * and s_{k+1} = xs(s_k), where xs(s) = s^(s<<13); s^(s>>7); s^(s<<17)
 * (app_pattern.v:169 gen_byte, :271 tx_lfsr <= xs_next).  Offset 0 = the first
 * data byte of the connection = board seq (irs+1) (D6).
 *
 * A table indexed by (off & 0xFFFF) cannot see a shift by a multiple of the
 * 64 KiB period, so this verifier WALKS the LFSR instead: O(1) per byte and
 * phase-exact for gigabyte streams. */
#define RPAT_SEED 0x9E3779B97F4A7C15ull
static inline uint64_t xs_next64(uint64_t s) {
    s ^= s << 13; s ^= s >> 7; s ^= s << 17;
    return s;
}
struct RxPatChecker {
    uint64_t s   = RPAT_SEED;   /* LFSR at the next expected byte */
    uint64_t pos = 0;           /* pattern offset of the next expected byte */
    uint64_t verified = 0;      /* bytes compared OK */
    uint64_t mismatch = 0;      /* bytes that differed */
    uint64_t hole_bytes = 0;    /* bytes skipped to resync around a gap */
    uint64_t holes = 0;         /* gap events */
    uint64_t first_bad_off = 0; /* offset of the first mismatch */
    uint8_t  first_bad_got = 0, first_bad_exp = 0;
    bool     have_bad = false;

    void reset() { *this = RxPatChecker(); }
    void skip(uint64_t n) {
        for (uint64_t i = 0; i < n; i++) s = xs_next64(s);
        pos += n;
    }
    /* verify n bytes that are contiguous with the previous window */
    void check(const uint8_t *p, int n) {
        for (int i = 0; i < n; i++) {
            uint8_t exp = (uint8_t)(s >> 24);
            if (p[i] != exp) {
                if (!have_bad) {
                    have_bad = true; first_bad_off = pos; first_bad_got = p[i];
                    first_bad_exp = exp;
                }
                mismatch++;
            } else {
                verified++;
            }
            s = xs_next64(s);
            pos++;
        }
    }
    void gap(uint64_t n) { holes++; hole_bytes += n; skip(n); }
};

/* ---------- high resolution clock ---------- */

static LARGE_INTEGER g_qpc_freq;
static double        g_us_per_tick = 1.0;

static void qpc_init(void) {
    QueryPerformanceFrequency(&g_qpc_freq);
    g_us_per_tick = 1e6 / (double)g_qpc_freq.QuadPart;
}
static inline uint64_t now_ticks(void) {
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (uint64_t)c.QuadPart;
}
static inline double ticks_to_us(uint64_t d) { return (double)d * g_us_per_tick; }

/* =====================================================================
 * 3. Configuration
 * ===================================================================== */

enum AckMode { ACK_IMMEDIATE, ACK_DELAYED, ACK_COALESCE };

static constexpr uint32_t ip4(int a, int b, int c, int d) {
    return ((uint32_t)a << 24) | ((uint32_t)b << 16) | ((uint32_t)c << 8) | (uint32_t)d;
}

struct Config {
    std::string iface;
    int         iface_idx   = 0;        /* 1-based, from this binary's --list */
    uint8_t     src_mac[6]  = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};
    uint8_t     dst_mac[6]  = {0x00, 0x0a, 0x35, 0x01, 0xfe, 0xc0};
    uint32_t    src_ip      = ip4(192, 168, 100, 1);
    uint32_t    dst_ip      = ip4(192, 168, 100, 2);
    uint16_t    sport       = 40000;
    uint16_t    dport       = 8080;
    uint32_t    bytes       = 1024 * 1024;
    int         mss         = 1460;
    AckMode     ack_mode    = ACK_IMMEDIATE;
    int         ack_delay_us= 100;
    int         ack_every   = 2;
    int         rto_ms      = 200;
    int         stall_ms    = 2000;
    uint32_t    cwnd        = 0;        /* 0 = slow start */
    uint16_t    rx_window   = 65535;    /* --rx-window / --rcv-wnd */
    bool        do_fin      = true;
    bool        verbose     = false;
    bool        list_only   = false;
    std::string syn_opts    = "full";   /* none | mss | full */
    int         stats_interval_ms = 1000;  /* 0 = quiet */
    int         fast_retx_dupacks = 3;     /* dup-ACKs before fast retransmit */
    bool        rate_test   = false;    /* keep the 10-90% steady-state summary */
    bool        tx_batch    = true;     /* use pcap_sendqueue_transmit */
    int         tx_sync     = 1;        /* 1 = wait for completion per flush */
    int         tx_queue_kb = 4096;     /* sendqueue size */
    int         setbuff_kb  = 8192;     /* driver receive buffer (0 = leave) */
    bool        mintocopy0  = true;     /* pcap_setmintocopy(0): lowest latency */
    int         flush_frames = 40;      /* flush the sendqueue every N frames */
    bool        use_filter  = true;     /* server-side BPF filter on our 4-tuple */
    bool        dbg_stream  = false;    /* --dbg-stream: dump the first echoed frames */
    bool        legacy_dupack = false;  /* --legacy-dupack: pre-fix dup-ACK semantics
                                         * (count data-bearing stale ACKs as dup-ACKs);
                                         * diagnostic only, reproduces the 462 Mbps
                                         * suppress=0 baseline */
    bool        rx_only     = false;    /* --rx-only: send no app data */
    uint32_t    expect_bytes= 0;        /* --expect-pattern N: bytes to verify
                                         * from the board (0 = until its FIN) */

    /* ---- P5e: UDP 模式 (无连接; 见 5b 节) ---- */
    bool        udp         = false;    /* --udp / --udp-send-pattern / --udp-rx-only */
    bool        udp_send    = false;    /* --udp-send-pattern N: 发图案 (板侧 echo 则校验) */
    bool        udp_rx_only = false;    /* --udp-rx-only [N]: 只收 + 校验 */
    uint32_t    udp_bytes   = 0;        /* 发送/接收目标字节数 (0 = rx-only 时到 stall) */
    int         udp_paylen  = 1472;     /* 每帧 UDP 载荷字节 (1514 - 42 = MTU 内) */
    double      rate_mbps   = 50.0;     /* 发送限速 (0 = 不限); 板侧 app RX 是字节
                                         * 串行 (~15.6 MB/s) ⇒ 必须限速 */
    bool        udp_csum    = true;     /* 计算 UDP 校验和 (0 = 置零, 板侧回包恒 0) */
    bool        udp_spin    = true;     /* 限速等待用亚毫秒自旋 (流量平滑) */
    int         udp_resync  = 65536;    /* 失配重同步搜索上限 (字节; 0 = 关) */
    bool        udp_strict_ports = true;/* 收方向要求 peer_port<->our_port 严格配对 */
    bool        udp_echo_wait = true;   /* 发完等回包并校验 (0 = 纯 TX) */
    bool        udp_selftest= false;    /* --udp-selftest: 无板闭环自检 */
    std::string udp_dump;               /* --udp-dump <file>: 收到的载荷流落盘 */
    bool        pat_selftest= false;    /* --pat-selftest: print+check pattern */
    bool        selftest_rx = false;    /* --selftest-rx: rx verifier unit test */
    uint32_t    tx_bench    = 0;        /* --tx-bench N: raw send self-test */
    uint32_t    seed        = 0;        /* 0 = derive from clock */
    int         syn_retries = 6;
};

static Config cfg;

/* =====================================================================
 * 4. Statistics
 * ===================================================================== */

/* Bucket edges in microseconds, shared by every histogram in this file:
 * <1 <2 <5 <10 <20 <50 <100 <1000 >=1000 */
static const double HIST_EDGE[8] = {1, 2, 5, 10, 20, 50, 100, 1000};

struct Hist {
    uint64_t b[9] = {0};
    uint64_t n    = 0;
    double   sum  = 0;
    double   mx   = 0;
    void add(double v) {
        if (!(v >= 0)) v = 0;                 /* also eats NaN */
        int i = 0;
        while (i < 8 && v >= HIST_EDGE[i]) i++;
        b[i]++; n++; sum += v;
        if (v > mx) mx = v;
    }
    void reset() { for (int i = 0; i < 9; i++) b[i] = 0; n = 0; sum = 0; mx = 0; }
    void print(const char *name) const {
        if (!n) { printf("%-22s (no samples)\n", name); return; }
        printf("%-22s n=%-8llu avg %8.2f  max %9.2f us | ", name,
               (unsigned long long)n, sum / (double)n, mx);
        static const char *lbl[9] = {"<1","<2","<5","<10","<20","<50","<100","<1k",">=1k"};
        for (int i = 0; i < 9; i++)
            if (b[i]) printf("%s:%.0f%% ", lbl[i], 100.0 * (double)b[i] / (double)n);
        printf("\n");
    }
};

struct Stats {
    uint64_t tx_frames      = 0;   /* all frames we put on the wire */
    uint64_t tx_data_segs   = 0;   /* data-bearing segments (incl. retx) */
    uint64_t tx_data_bytes  = 0;   /* ditto, payload bytes */
    uint64_t tx_unique_bytes= 0;   /* forward progress in payload bytes */
    uint64_t tx_words       = 0;   /* sum of ceil(frame_len/8) over TX frames --
                                    * the board's mac_rx_64 word count (MW) should
                                    * advance by exactly this if nothing is lost
                                    * and nothing is duplicated on the wire */
    uint64_t rx_raw         = 0;   /* every frame the capture device handed us */
    uint64_t rx_frames      = 0;   /* frames that passed the 4-tuple filter */
    uint64_t rx_data_segs   = 0;
    uint64_t rx_data_bytes  = 0;
    uint64_t rx_dup_segs    = 0;
    uint64_t rx_out_of_order= 0;
    uint64_t rx_ack_only    = 0;
    uint64_t retransmits    = 0;
    uint64_t dup_acks       = 0;
    uint64_t dup_acks_recovery = 0;  /* dup-ACKs absorbed by Reno fast recovery */
    uint64_t zero_window_probes = 0;
    uint64_t mismatch_segs  = 0;
    uint64_t mismatch_bytes = 0;
    uint64_t verified_bytes = 0;
    uint64_t board_rst      = 0;
    uint64_t board_fin      = 0;
    uint64_t fast_retx      = 0;
    uint64_t rto_events     = 0;
    /* I/O cost accounting -- this is what tells us whether the peer or the
     * board sets the throughput ceiling */
    uint64_t tx_calls       = 0;
    uint64_t rx_calls       = 0;
    double   tx_time_us     = 0;
    double   rx_time_us     = 0;

    /* ---- instrumentation v2 (2026-09-19 throughput-halving hunt) ----
     * RX-thread-only fields (single writer, no lock needed) */
    uint64_t rx_timeouts    = 0;   /* pcap_next_ex returned 0 */
    uint64_t rx_errors      = 0;
    uint64_t rx_pickup_max_us = 0;
    Hist     h_rxcall;            /* pcap_next_ex wall time per call */
    Hist     h_rxframes;          /* frames returned per pcap_next_ex call */
    Hist     h_ia;                /* RX frame inter-arrival (board TX pacing) */
    /* main-thread-only fields */
    uint64_t iters          = 0;
    double   t_loop_us      = 0;   /* time inside the run() loop, sleeps excluded */
    double   t_wait_us      = 0;   /* time blocked in WaitForSingleObject */
    double   t_procrx_us    = 0;   /* process_rx() total */
    double   t_handle_us    = 0;   /* handle_frame() total */
    double   t_send_us      = 0;   /* send_new_data()+check_rto() total */
    double   t_flush_us     = 0;   /* flush_tx() total */
    uint64_t flushes        = 0;
    uint64_t flush_frames   = 0;   /* frames pushed per flush */
    Hist     h_flushframes;        /* frames per flush */
    Hist     h_flush_us;           /* flush call duration */
    Hist     h_handle;             /* handle_frame per frame */
    Hist     h_loopiter;           /* one run() iteration */
    uint64_t burst_flushes  = 0;   /* flushes with < 2 frames (pipeline bubble) */
    uint64_t win_block_iters= 0;   /* loop iterations where send was window-blocked */
    uint64_t win_block_us   = 0;   /* accumulated time window-blocked */
    /* ACK classification (main thread) */
    uint64_t rx_pure_ack    = 0;   /* frames with ACK and no payload */
    uint64_t rx_ack_data    = 0;   /* frames with ACK and payload */
    uint64_t rx_pure_ack_adv= 0;   /* pure ACK that advanced snd_una */
    uint64_t rx_pure_ack_dup= 0;   /* pure ACK that did not advance */
    uint64_t rx_win_change  = 0;   /* ACKs that changed the advertised window */
    uint64_t dup_ack_data_ignored = 0;  /* acks riding data, not counted as dup-ACK */
    /* per-segment latency split: pure-ACK path vs echo(piggyback) path */
    Hist     h_lat_pureack;        /* t_recv(frame) - t_sent(seg) for pure ACK */
    Hist     h_lat_echo;           /* t_recv(frame) - t_sent(seg) for echo frame */
    Hist     h_lat_echo_data;      /* echo carrying an ACK that advanced snd_una */
    Hist     h_lat_pureack_data;   /* pure ACK that advanced snd_una */
    /* stall forensics: silence vs stale-ack discriminator */
    uint64_t t_last_rx       = 0;  /* wall clock of the last received frame */
    uint64_t t_last_ack_rx   = 0;  /* ... of the last frame that moved snd_una */
    uint32_t ack_hi          = 0;  /* highest ack value the board ever sent */
    bool     ack_hi_valid    = false;

    /* process CPU (both threads): the "is the peer the ceiling" number */
    double   cpu_user_s     = 0;
    double   cpu_sys_s      = 0;
    double   cpu_cores_avg  = 0;
};

/* One detected TX-side gap (our data the board did not acknowledge in time):
 * where, how big, how it was recovered, and how long recovery took.  This is
 * the signal that maps onto the board's retx/rollback behaviour. */
struct Hole {
    uint32_t    seq;
    uint32_t    gap;
    std::string how;
    uint64_t    t_detect;
    uint64_t    t_recover;
    bool        recovered;
};

static Stats st;

/* =====================================================================
 * 5. Peer
 * ===================================================================== */

struct Seg {                 /* in-flight data segment (for RTO + RTT) */
    uint32_t seq;
    int      len;
    uint64_t t_sent;
    bool     retransmitted;
};

struct RxItem {
    std::vector<uint8_t> data;
    uint64_t             t_recv;
};

class Peer {
public:
    /* --- connection state --- */
    uint32_t iss = 0, irs = 0;
    uint32_t snd_una = 0, snd_nxt = 0, snd_wnd = 0;
    uint32_t rcv_nxt = 0;
    uint32_t total = 0;                 /* payload bytes to send (echo length) */
    uint32_t cwnd = 0, ssthresh = 0;
    int      mss = 1460;

    uint8_t              segbuf[2048];  /* scratch for one outgoing segment */
    std::deque<Seg>      inflight;

    /* reassembly of echoed data (bounded; the echo is in-order in practice) */
    std::map<uint32_t, std::vector<uint8_t>> ooo;

    /* dup-ACK / hole bookkeeping */
    int      dup_ack_cnt = 0;
    std::vector<Hole> holes;
    /* Reno fast recovery */
    bool     in_recovery = false;
    uint32_t recover     = 0;        /* high_seq: snd_nxt when recovery started */
    bool     win_unchanged = true;   /* last ACK did not change the advertised window */

    /* per-second rate sampling */
    uint64_t t_log_next = 0;
    uint64_t t_log_prev = 0;
    uint64_t log_tx_prev = 0, log_retx_prev = 0, log_dup_prev = 0, log_hole_prev = 0;
    uint64_t log_rtt_n_prev = 0;
    double   log_rtt_sum_prev = 0, rtt_win_max = 0;
    std::vector<std::pair<double, uint64_t>> rate_samples;  /* (seconds, unique bytes) */
    std::vector<std::string> rate_lines;

    /* ACK strategy bookkeeping */
    bool     ack_pending = false;
    uint64_t ack_since   = 0;
    int      segs_since_ack = 0;

    /* RTT (Jacobson/Karels) */
    double srtt = -1, rttvar = -1;
    uint64_t rto_ticks = 0;
    double rtt_min = 1e18, rtt_max = 0, rtt_sum = 0;
    uint64_t rtt_samples = 0;

    /* --rx-only: RTL-pattern verification of the board's stream */
    RxPatChecker vchk;
    uint64_t rx_gap_pending = 0;      /* 已检出但尚未跳过的缺口字节 */
    uint64_t rx_hole_events = 0;
    uint64_t rx_first_t = 0, rx_last_t = 0;   /* first/last verified data byte */
    uint64_t rx_last_seq = 0;

    uint64_t t_start = 0, t_end = 0, t_last_progress = 0;
    uint32_t snd_una_last = 0, rcv_nxt_last = 0;

    bool     finished = false;
    bool     aborted  = false;
    std::string abort_reason;

    pcap_t  *pcap = 0;
    struct pcap_send_queue *txq = 0;
    uint8_t  our_mac[6], peer_mac[6];
    uint32_t our_ip, peer_ip;
    uint16_t our_port, peer_port;
    uint16_t ip_id = 0;
    uint64_t queued_frames = 0;      /* frames sitting in the sendqueue */
    bool     win_blocked_iter = false;

    std::mutex             rx_mtx;
    std::deque<RxItem>     rx_q;
    HANDLE                 rx_evt = 0;
    std::atomic<bool>      stop_rx{false};
    std::thread            rx_thread;

    /* ---------------- setup ---------------- */

    void init(pcap_t *p) {
        pcap = p;
        memcpy(our_mac, cfg.src_mac, 6);
        memcpy(peer_mac, cfg.dst_mac, 6);
        our_ip = cfg.src_ip;
        peer_ip = cfg.dst_ip;
        our_port = cfg.sport;
        peer_port = cfg.dport;
        mss = cfg.mss;
        total = cfg.bytes;

        uint32_t s = cfg.seed;
        if (!s) s = (uint32_t)(now_ticks() ^ (GetCurrentProcessId() * 2654435761u));
        /* xorshift so the ISS is not trivially patterned */
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        iss = s;
        cwnd = cfg.cwnd ? cfg.cwnd : (uint32_t)(10 * mss);
        ssthresh = 1u << 30;
        rto_ticks = (uint64_t)(cfg.rto_ms * 1000.0 / g_us_per_tick);

        rx_evt = CreateEventA(0, FALSE, FALSE, 0);
        t_start = t_last_progress = now_ticks();

        if (cfg.tx_batch) {
            txq = pcap_sendqueue_alloc((unsigned int)cfg.tx_queue_kb * 1024);
            if (!txq) {
                printf("[!!] pcap_sendqueue_alloc(%d KB) failed; falling back to "
                       "per-frame pcap_sendpacket\n", cfg.tx_queue_kb);
                cfg.tx_batch = false;
            }
        }
    }

    void start_rx(void) {
        rx_thread = std::thread([this] { rx_loop(); });
    }

    void halt_rx(void) {
        stop_rx.store(true);
        if (rx_evt) SetEvent(rx_evt);
        if (rx_thread.joinable()) rx_thread.join();
    }

    void rx_loop(void) {
        uint64_t t_prev = 0;
        while (!stop_rx.load()) {
            struct pcap_pkthdr *hdr = 0;
            const unsigned char *data = 0;
            uint64_t t0 = now_ticks();
            int r = pcap_next_ex(pcap, &hdr, &data);
            uint64_t t1 = now_ticks();
            st.rx_time_us += ticks_to_us(t1 - t0);
            st.h_rxcall.add(ticks_to_us(t1 - t0));
            st.rx_calls++;
            if (r == 1) {
                st.h_rxframes.add(1.0);
                if (!hdr || hdr->caplen < (unsigned)ETH_HDR_LEN) continue;
                RxItem it;
                it.data.assign(data, data + hdr->caplen);
                it.t_recv = t1;
                st.rx_raw++;
                if (t_prev) st.h_ia.add(ticks_to_us(t1 - t_prev));
                t_prev = t1;
                {
                    std::lock_guard<std::mutex> g(rx_mtx);
                    if (rx_q.size() < 200000) rx_q.push_back(std::move(it));
                }
                if (rx_evt) SetEvent(rx_evt);
            } else if (r == 0) {
                st.h_rxframes.add(0.0);
                st.rx_timeouts++;
            } else {
                st.rx_errors++;
                break;   /* device error / closed */
            }
        }
    }

    /* ---------------- TX ---------------- */

    void emit(uint32_t seq, uint32_t ack, uint8_t flags,
              const uint8_t *payload, int plen,
              const uint8_t *opts = 0, int optlen = 0) {
        uint8_t buf[ETH_HDR_LEN + 60 + 1500];
        int thl = 20 + optlen;              /* TCP header length incl. options */
        int tcp_len = thl + plen;
        int ip_len  = 20 + tcp_len;
        int frame_len = ETH_HDR_LEN + ip_len;
        memset(buf, 0, sizeof(buf));

        EthHdr *e = (EthHdr *)buf;
        memcpy(e->dst, peer_mac, 6);
        memcpy(e->src, our_mac, 6);
        e->type = htons(ETH_IP4);

        IpHdr *ip = (IpHdr *)(buf + ETH_HDR_LEN);
        ip->vihl  = 0x45;
        ip->tos   = 0;
        ip->totlen= htons((uint16_t)ip_len);
        ip->id    = htons(++ip_id);
        ip->frag  = htons(0x4000);          /* DF */
        ip->ttl   = 64;
        ip->proto = 6;
        ip->csum  = 0;
        ip->src   = htonl(our_ip);
        ip->dst   = htonl(peer_ip);
        /* csum_fold yields the checksum VALUE; it must go on the wire in
         * network byte order, hence htons(). */
        ip->csum  = htons(csum_fold(csum_acc(0, (uint8_t *)ip, 20)));

        TcpHdr *t = (TcpHdr *)(buf + ETH_HDR_LEN + 20);
        t->sport = htons(our_port);
        t->dport = htons(peer_port);
        t->seq   = htonl(seq);
        t->ack   = htonl(ack);
        t->doff  = (uint8_t)((thl / 4) << 4);
        t->flags = flags;
        t->win   = htons(cfg.rx_window);
        t->csum  = 0;
        t->urg   = 0;
        if (optlen > 0) memcpy(buf + ETH_HDR_LEN + 40, opts, optlen);
        if (plen > 0) memcpy(buf + ETH_HDR_LEN + 20 + thl, payload, plen);

        /* TCP checksum over pseudo-header + TCP header + payload */
        {
            uint32_t sum = 0;
            uint8_t pseudo[12];
            memcpy(pseudo + 0, &ip->src, 4);
            memcpy(pseudo + 4, &ip->dst, 4);
            pseudo[8] = 0;
            pseudo[9] = 6;
            pseudo[10] = (uint8_t)(tcp_len >> 8);
            pseudo[11] = (uint8_t)(tcp_len & 0xFF);
            sum = csum_acc(sum, pseudo, 12);
            sum = csum_acc(sum, (uint8_t *)t, (uint32_t)thl);
            if (plen > 0) sum = csum_acc(sum, buf + ETH_HDR_LEN + 20 + thl, plen);
            t->csum = htons(csum_fold(sum));
        }

        int send_len = frame_len < ETH_MIN_FRAME ? ETH_MIN_FRAME : frame_len;

        if (cfg.tx_batch && txq) {
            struct pcap_pkthdr h;
            h.ts.tv_sec = 0; h.ts.tv_usec = 0;
            h.caplen = h.len = (unsigned int)send_len;
            if (pcap_sendqueue_queue(txq, &h, buf) != 0) {
                flush_tx();                                  /* queue full */
                if (pcap_sendqueue_queue(txq, &h, buf) != 0)
                    fprintf(stderr, "pcap_sendqueue_queue failed (frame > queue?)\n");
            }
            queued_frames++;
        } else {
            uint64_t t0 = now_ticks();
            if (pcap_sendpacket(pcap, buf, send_len) != 0)
                fprintf(stderr, "pcap_sendpacket failed: %s\n", pcap_geterr(pcap));
            st.tx_time_us += ticks_to_us(now_ticks() - t0);
            st.tx_calls++;
        }
        st.tx_frames++;
        st.tx_words += (uint64_t)((send_len + 7) / 8);
    }

    /* Push everything queued this iteration to the wire in one driver call. */
    void flush_tx(void) {
        if (!txq || txq->len == 0) return;
        uint64_t t0 = now_ticks();
        pcap_sendqueue_transmit(pcap, txq, cfg.tx_sync);
        double d = ticks_to_us(now_ticks() - t0);
        st.tx_time_us += d;
        st.tx_calls++;
        st.flushes++;
        st.t_flush_us += d;
        st.h_flush_us.add(d);
        st.flush_frames += queued_frames;
        st.h_flushframes.add((double)queued_frames);
        if (queued_frames < 2) st.burst_flushes++;
        queued_frames = 0;
        txq->len = 0;    /* WinPcap resets this on success; be explicit */
    }

    void send_data(uint32_t seq, int plen, bool retransmit) {
        pay_fill(segbuf, seq - (iss + 1), plen);
        emit(seq, rcv_nxt, TH_ACK | TH_PSH, segbuf, plen);
        st.tx_data_segs++;
        st.tx_data_bytes += (uint64_t)plen;
        if (!retransmit) st.tx_unique_bytes += (uint64_t)plen;
        /* latency attribution ring (see lat_probe): send order, first TX only */
        if (!retransmit) {
            seg_ring[seg_head & SEGMASK].seq    = seq;
            seg_ring[seg_head & SEGMASK].len    = (uint32_t)plen;
            seg_ring[seg_head & SEGMASK].t_sent = now_ticks();
            seg_head++;
        }
    }

    void send_ack(void) {
        emit(snd_nxt, rcv_nxt, TH_ACK, 0, 0);
        ack_pending = false;
        segs_since_ack = 0;
        ack_since = 0;   /* MUST clear: otherwise the 2 ms safety fallback in
                          * maybe_ack() stays permanently true and everyN/delayed
                          * silently degenerate into immediate ACKs. */
    }

    /* ---------------- RX parsing ---------------- */

    void process_rx(void) {
        std::deque<RxItem> batch;
        uint64_t t_ent = now_ticks();
        {
            std::lock_guard<std::mutex> g(rx_mtx);
            if (rx_q.empty()) { st.t_procrx_us += ticks_to_us(now_ticks() - t_ent); return; }
            batch.swap(rx_q);
        }
        for (auto &it : batch) {
            uint64_t tf = now_ticks();
            handle_frame(it.data.data(), (int)it.data.size(), it.t_recv);
            double d = ticks_to_us(now_ticks() - tf);
            st.h_handle.add(d);
            st.t_handle_us += d;
        }
        st.t_procrx_us += ticks_to_us(now_ticks() - t_ent);
    }

    void handle_frame(const uint8_t *f, int flen, uint64_t t_recv) {
        if (flen < ETH_HDR_LEN) return;
        const EthHdr *e = (const EthHdr *)f;
        int off = ETH_HDR_LEN;
        uint16_t et = ntohs(e->type);
        if (et == ETH_VLAN) { off += 4; if (flen < off + 2) return; et = rd16(f + off - 2); }
        if (et != ETH_IP4) return;
        /* ignore frames we ourselves put on the wire (npcap captures both ways) */
        if (memcmp(e->src, our_mac, 6) == 0) return;

        if (flen < off + 20) return;
        const IpHdr *ip = (const IpHdr *)(f + off);
        int ihl = (ip->vihl & 0x0F) * 4;
        if ((ip->vihl >> 4) != 4) return;
        if (ip->proto != 6) return;
        if (ntohl(ip->src) != peer_ip) return;
        if (ntohl(ip->dst) != our_ip) return;

        int toff = off + ihl;
        if (flen < toff + 20) return;
        const TcpHdr *t = (const TcpHdr *)(f + toff);
        int thl = ((t->doff >> 4) & 0x0F) * 4;
        if (thl < 20) return;
        if (ntohs(t->sport) != peer_port) return;
        if (ntohs(t->dport) != our_port) return;

        st.rx_frames++;
        uint32_t seq = ntohl(t->seq);
        uint32_t ack = ntohl(t->ack);
        uint16_t win = ntohs(t->win);
        int plen = ntohs(ip->totlen) - ihl - thl;
        if (plen < 0) plen = 0;
        if (flen < toff + thl + plen) plen = flen - toff - thl;
        const uint8_t *pay = f + toff + thl;

        if (t->flags & TH_RST) {
            st.board_rst++;
            do_abort("board sent RST");
            return;
        }
        if (t->flags & TH_FIN) st.board_fin++;

        /* window update */
        snd_wnd = win;

        /* handshake completion is handled by the caller via wait_synack() */
        if (!handshake_done) {
            if ((t->flags & (TH_SYN | TH_ACK)) == (TH_SYN | TH_ACK)) {
                irs = seq;
                hs_ack = ack;
                handshake_done = true;
            }
            return;
        }

        if (t->flags & TH_ACK) {
            if (plen > 0) st.rx_ack_data++; else st.rx_pure_ack++;
            st.t_last_rx = t_recv;
            if (!st.ack_hi_valid || (int32_t)(ack - st.ack_hi) > 0) {
                st.ack_hi = ack;
                st.ack_hi_valid = true;
            }
            uint32_t before = snd_una;
            uint32_t win_before = last_ack_win;
            process_ack(ack, t_recv, plen > 0);
            if (plen == 0) {
                if (snd_una != before) st.rx_pure_ack_adv++;
                else st.rx_pure_ack_dup++;
            }
            if (snd_una != before) st.t_last_ack_rx = t_recv;
            if (win != win_before) { st.rx_win_change++; last_ack_win = win; }
            win_unchanged = (win == win_before);
            /* latency attribution: which segment does this ACK/echo complete? */
            lat_probe(seq, plen, ack, plen > 0 && snd_una != before, t_recv);
        }

        if (plen > 0) {
            st.rx_data_segs++;
            st.rx_data_bytes += (uint64_t)plen;
            if (cfg.verbose)
                printf("  [rx] data seq=%u len=%d win=%u\n", seq, plen, win);
            rx_data(seq, pay, plen);
            if (ack_pending) maybe_ack();
        }
    }

    /* ---- per-segment latency attribution ----------------------------------
     * Every data segment we send is answered twice in the suppress=0 (app-mode)
     * configuration: once by the board's pure ACK, once by the echo segment
     * (which piggybacks the same ACK).  Timing both answers against the send
     * time of the segment they acknowledge isolates the board's pure-ACK path
     * cost from its echo path cost -- the number that says whether the extra
     * frame costs wire time, board scheduling time, or nothing at all.
     *
     * Segments are tracked in SEND ORDER (a ring plus a tail cursor), NOT by
     * offset arithmetic: the peer emits a short segment whenever the remaining
     * window room is < MSS (the board advertises 49152 = 33*1460 + 972), so
     * segment starts are only MSS-aligned until the first window refill. */
    struct SegTrack { uint32_t seq; uint32_t len; uint64_t t_sent; };
    enum { SEGRING = 512, SEGMASK = SEGRING - 1 };
    SegTrack seg_ring[SEGRING];
    uint64_t seg_head = 0;           /* send counter: next slot to write */
    uint64_t seg_tail = 0;           /* oldest entry not yet accounted for */
    uint32_t last_ack_win = 0;

    uint64_t lat_hits = 0, lat_no_match = 0;

    /* board stream position -> our stream position (independent ISS per
     * direction: the mapping is one constant shift) */
    inline uint32_t board2our(uint32_t bseq) const {
        return bseq + ((iss + 1) - (irs + 1));
    }

    void lat_probe(uint32_t seq, int plen, uint32_t ack, bool advanced, uint64_t t_recv) {
        uint32_t target = (plen > 0) ? board2our(seq) : board2our(ack);
        /* drop entries the tail has fully passed */
        while (seg_tail < seg_head) {
            SegTrack &e = seg_ring[seg_tail & SEGMASK];
            if ((int32_t)((e.seq + e.len) - target) < 0) seg_tail++;
            else break;
        }
        /* match within a bounded window so one lost/reordered segment cannot
         * wedge the cursor and blind the rest of the run */
        uint64_t lim = std::min<uint64_t>(seg_head, seg_tail + 64);
        for (uint64_t k = seg_tail; k < lim; k++) {
            SegTrack &e = seg_ring[k & SEGMASK];
            uint32_t end = e.seq + e.len;
            bool m = (plen > 0) ? (e.seq == target) : (end == target);
            if (!m) continue;
            double d = ticks_to_us(t_recv - e.t_sent);
            if (plen > 0) {
                st.h_lat_echo.add(d);
                if (advanced) st.h_lat_echo_data.add(d);
            } else {
                st.h_lat_pureack.add(d);
                st.h_lat_pureack_data.add(d);
            }
            lat_hits++;
            if (k == seg_tail) seg_tail++;
            return;
        }
        lat_no_match++;
    }

    /* ---------------- hole (loss) diagnostics ---------------- */

    size_t hole_first_unrec = 0;

    void record_hole(uint32_t seq, uint32_t gap, const char *how) {
        Hole h;
        h.seq = seq; h.gap = gap; h.how = how;
        h.t_detect = now_ticks(); h.t_recover = 0; h.recovered = false;
        if (holes.size() < 1000000) holes.push_back(h);
    }

    void mark_holes_recovered(void) {
        while (hole_first_unrec < holes.size() &&
               !holes[hole_first_unrec].recovered &&
               (int32_t)(snd_una - (holes[hole_first_unrec].seq +
                                    holes[hole_first_unrec].gap)) >= 0) {
            holes[hole_first_unrec].recovered = true;
            holes[hole_first_unrec].t_recover = now_ticks();
            hole_first_unrec++;
        }
    }

    /* RFC 5681 fast retransmit + Reno fast recovery, with go-back-N repair.
     *
     * Two independent fixes are needed here and they are NOT the same fix:
     *  - dup-ACK semantics (see process_ack): a data-carrying segment is never
     *    a duplicate ACK;
     *  - recovery state (this function + in_recovery): the board ACKs duplicate
     *    data (drop_ack, "drop_ack=丢数据仍回 ACK"), so ANY retransmission it
     *    generates comes back as non-advancing ACKs.  Counting those as fresh
     *    dup-ACKs re-arms the retransmit and the result is a self-sustaining
     *    storm (measured 1457 fast retx in a 16 MB transfer).  While in
     *    recovery, extra dup-ACKs only inflate cwnd (standard Reno).
     *
     * Repair itself stays go-back-N from snd_una: this board's RX drops whole
     * consecutive bursts (measured 33 frames = one full window, see the RTO
     * diagnostics), so a single-segment retransmit leaves the board waiting for
     * the rest of the hole -- measured 174 Mbps vs 800+ Mbps for the burst. */
    void fast_retransmit(void) {
        if (inflight.empty()) return;
        uint32_t gap = snd_nxt - snd_una;
        st.fast_retx++;
        recover = snd_nxt;
        in_recovery = true;
        record_hole(snd_una, gap, "fast-retx(dupacks)");
        printf("[!!] %d dup-ACKs -> fast retransmit snd_una=%u (gap %u B, cwnd %u)\n",
               cfg.fast_retx_dupacks, snd_una, gap, cwnd);
        ssthresh = std::max(cwnd / 2, (uint32_t)(2 * mss));
        cwnd = ssthresh + 3u * (uint32_t)mss;
        std::deque<Seg> nf;
        for (uint32_t seq = snd_una; (int32_t)(seq - snd_nxt) < 0; ) {
            int seg = (int)std::min<uint32_t>((uint32_t)mss, snd_nxt - seq);
            send_data(seq, seg, true);
            Seg s; s.seq = seq; s.len = seg; s.t_sent = now_ticks(); s.retransmitted = true;
            nf.push_back(s);
            seq += (uint32_t)seg;
        }
        inflight.swap(nf);
        dup_ack_cnt = 0;
    }

    void process_ack(uint32_t ack, uint64_t t_recv, bool carries_data) {
        if ((int32_t)(ack - snd_una) <= 0) {          /* stale / duplicate */
            /* RFC 5681 / Linux tcp_check_dupack: a segment that CARRIES DATA is
             * never a duplicate ACK, no matter what its ack field says.  In the
             * suppress=0 (app-mode) configuration every data segment is answered
             * twice with the same ack number -- once by the board's pure ACK
             * (which advances snd_una) and once by the echo segment carrying the
             * same ack -- so without this rule every single segment manufactured
             * a phantom dup-ACK and 3 of them tripped a spurious fast retransmit. */
            if (carries_data && !cfg.legacy_dupack) { st.dup_ack_data_ignored++; return; }
            if (ack == snd_una && !inflight.empty() && win_unchanged) {
                /* Reno: during recovery extra dup-ACKs inflate cwnd instead of
                 * arming another retransmit */
                if (in_recovery && (int32_t)(snd_una - recover) < 0) {
                    st.dup_acks_recovery++;
                    cwnd += (uint32_t)mss;
                    return;
                }
                st.dup_acks++;
                dup_ack_cnt++;
                if (cfg.fast_retx_dupacks > 0 && dup_ack_cnt == cfg.fast_retx_dupacks)
                    fast_retransmit();
            }
            return;
        }
        dup_ack_cnt = 0;
        if ((int32_t)(ack - snd_nxt) > 0) return;     /* impossible ack */

        /* RTT sample from the last fully-acked, never-retransmitted segment */
        uint64_t best_t = 0; bool have = false;
        while (!inflight.empty() &&
               (int32_t)(ack - (inflight.front().seq + inflight.front().len)) >= 0) {
            Seg s = inflight.front();
            inflight.pop_front();
            if (!s.retransmitted) { best_t = s.t_sent; have = true; }
        }
        if (have && t_recv > best_t) {
            /* guard: a stale ACK dequeued after we (re)sent a segment can carry
             * an older timestamp; unsigned subtraction would explode */
            double rtt = ticks_to_us(t_recv - best_t);
            if (rtt > 0) {
                rtt_min = std::min(rtt_min, rtt);
                rtt_max = std::max(rtt_max, rtt);
                rtt_win_max = std::max(rtt_win_max, rtt);
                rtt_sum += rtt;
                rtt_samples++;
                if (srtt < 0) { srtt = rtt; rttvar = rtt / 2; }
                else {
                    double err = rtt - srtt;
                    srtt += err / 8.0;
                    rttvar += (fabs(err) - rttvar) / 4.0;
                }
                double rto_us = srtt + 4 * rttvar;
                rto_us = std::max(rto_us, (double)cfg.rto_ms * 1000.0);
                rto_us = std::min(rto_us, 60.0 * 1e6);      /* cap at 60 s */
                rto_ticks = (uint64_t)(rto_us / g_us_per_tick);
            }
        }

        /* congestion control */
        uint32_t advanced = ack - snd_una;
        snd_una = ack;
        mark_holes_recovered();
        if (in_recovery && (int32_t)(ack - recover) >= 0) {
            in_recovery = false;                    /* Reno: exit at the recovery point */
            cwnd = ssthresh;
        }
        if (cwnd < ssthresh) {
            cwnd += advanced;                       /* slow start */
            if (cwnd > ssthresh) cwnd = ssthresh;
        } else if (advanced >= (uint32_t)mss && cwnd) {
            cwnd += (uint32_t)((uint64_t)mss * mss / cwnd);   /* congestion avoidance */
        }
        if (cfg.verbose) printf("  [ack] ack=%u snd_una=%u cwnd=%u wnd=%u\n",
                                ack, snd_una, cwnd, snd_wnd);
    }

    /* ---------------- RX data + verification ---------------- */

    void verify(uint32_t bseq, const uint8_t *p, int n) {
        /* The board echoes byte-for-byte, so the board-seq offset maps 1:1 onto
         * our TX stream offset.  Expected byte at board seq S is pay_byte(S-(irs+1)). */
        uint32_t off = bseq - (irs + 1);
        int bad = 0;
        for (int i = 0; i < n; i++) {
            uint32_t o = off + (uint32_t)i;
            if (o >= total) { bad++; continue; }
            if (pay_byte(o) != p[i]) bad++;
        }
        if (bad) {
            st.mismatch_segs++;
            st.mismatch_bytes += (uint64_t)bad;
            if (st.mismatch_segs <= 10)
                printf("  [!!] payload mismatch at board-seq=%u off=%u (%d/%d bytes differ) first: got %02X want %02X\n",
                       bseq, off, bad, n, p[0],
                       (off < total) ? pay_byte(off) : 0);
        }
        st.verified_bytes += (uint64_t)(n - bad);
    }

    void rx_data(uint32_t seq, const uint8_t *p, int n) {
        if (cfg.dbg_stream && st.rx_data_segs <= 12)
            printf("  [dbg] rx_data seq=%u plen=%d rcv_nxt=%u (off=%u)\n",
                   seq, n, rcv_nxt, rcv_nxt - (irs + 1));
        if (seq == rcv_nxt) {
            if (cfg.rx_only) {
                if (rx_gap_pending) {          /* 缺口补齐: 跳过后再对齐校验 */
                    vchk.gap(rx_gap_pending);
                    rx_hole_events++;
                    rx_gap_pending = 0;
                }
                uint64_t t = now_ticks();
                if (!rx_first_t) rx_first_t = t;
                rx_last_t = t;
                rx_last_seq = seq + (uint32_t)n;
                vchk.check(p, n);
            }
            verify(seq, p, n);
            rcv_nxt += (uint32_t)n;
            ack_pending = true;
            if (!ack_since) ack_since = now_ticks();
            segs_since_ack++;
            /* drain any buffered out-of-order segments now made contiguous */
            bool progress = true;
            while (progress && !ooo.empty()) {
                progress = false;
                auto it = ooo.find(rcv_nxt);
                if (it != ooo.end()) {
                    verify(it->first, it->second.data(), (int)it->second.size());
                    rcv_nxt += (uint32_t)it->second.size();
                    ooo.erase(it);
                    progress = true;
                }
            }
        } else if ((int32_t)(seq - rcv_nxt) > 0) {
            st.rx_out_of_order++;
            if (cfg.rx_only) {
                uint64_t gap = (uint64_t)(seq - rcv_nxt);
                if (gap > rx_gap_pending) rx_gap_pending = gap;
            }
            if (ooo.size() < 4096 && ooo.find(seq) == ooo.end())
                ooo[seq] = std::vector<uint8_t>(p, p + n);
            ack_pending = true;
            if (!ack_since) ack_since = now_ticks();
            segs_since_ack++;
        } else {
            /* Already seen.  Under load the WinPcap 4.1.3 read path on this host
             * re-delivers the same frame many times (measured ~8x; board-side
             * counters prove the board transmitted it once).  Deliberately do NOT
             * ACK these: acking every duplicate turned into a ~8x ACK flood that
             * wedged the board's ACK path.  Real duplicate ACKs from genuine
             * loss are a different case and are handled by process_ack(). */
            st.rx_dup_segs++;
        }
    }

    void maybe_ack(void) {
        if (!ack_pending) return;
        bool do_it = false;
        switch (cfg.ack_mode) {
        case ACK_IMMEDIATE: do_it = true; break;
        case ACK_COALESCE:  do_it = (segs_since_ack >= cfg.ack_every); break;
        case ACK_DELAYED:   do_it = (ticks_to_us(now_ticks() - ack_since) >= cfg.ack_delay_us); break;
        }
        /* never let the peer's window stall out because we sat on an ACK */
        if (!do_it && ticks_to_us(now_ticks() - ack_since) > 2000.0) do_it = true;
        if (do_it) send_ack();
    }

    /* ---------------- handshake ---------------- */

    bool handshake_done = false;
    uint32_t hs_ack = 0;

    /* Build the SYN option block. A bare SYN (no options) is a valid TCP segment,
     * but every real stack sends MSS; some hardware parsers key off it. */
    int syn_options(uint8_t *o) {
        int n = 0;
        if (cfg.syn_opts == "none") return 0;
        o[n++] = 2; o[n++] = 4;                       /* MSS */
        o[n++] = (uint8_t)(mss >> 8); o[n++] = (uint8_t)(mss & 0xFF);
        if (cfg.syn_opts == "full") {
            o[n++] = 4; o[n++] = 2;                   /* SACK permitted */
            o[n++] = 1; o[n++] = 1;                   /* NOP NOP -> pad to 8 */
        }
        return n;
    }

    bool connect(void) {
        printf("[..] SYN -> %u.%u.%u.%u:%u (iss=0x%08X, opts=%s)\n",
               (peer_ip >> 24) & 255, (peer_ip >> 16) & 255,
               (peer_ip >> 8) & 255, peer_ip & 255, peer_port, iss,
               cfg.syn_opts.c_str());
        uint8_t synopts[12];
        int synopts_len = syn_options(synopts);
        uint32_t syn_seq = iss;
        for (int tryn = 0; tryn < cfg.syn_retries && !handshake_done; tryn++) {
            emit(syn_seq, 0, TH_SYN, 0, 0, synopts, synopts_len);
            flush_tx();
            uint64_t t0 = now_ticks();
            while (!handshake_done && ticks_to_us(now_ticks() - t0) < 1000000.0) {
                WaitForSingleObject(rx_evt, 2);
                process_rx();
                if (aborted) return false;
            }
        }
        if (!handshake_done) { do_abort("no SYN+ACK from board"); return false; }

        printf("[ok] SYN+ACK: irs=0x%08X ack=%u wnd=%u mss=%d\n",
               irs, hs_ack, snd_wnd, mss);
        if (hs_ack != iss + 1) {
            printf("[!!] SYN+ACK ack=%u, expected %u -- continuing anyway\n",
                   hs_ack, iss + 1);
        }
        snd_una = snd_nxt = iss + 1;
        rcv_nxt = irs + 1;
        emit(snd_nxt, rcv_nxt, TH_ACK, 0, 0);
        flush_tx();
        printf("[ok] ACK sent; connection established\n");
        return true;
    }

    /* ---------------- transfer ---------------- */

    void send_new_data(void) {
        uint32_t base = iss + 1;
        uint32_t end  = base + total;
        while ((int32_t)(snd_nxt - end) < 0) {
            uint32_t in_flight = snd_nxt - snd_una;
            uint32_t allowed   = std::min(cwnd, (uint32_t)snd_wnd);
            if (in_flight >= allowed) break;
            uint32_t room = allowed - in_flight;
            int seg = (int)std::min<uint32_t>((uint32_t)mss, std::min(room, end - snd_nxt));
            if (seg <= 0) break;
            send_data(snd_nxt, seg, false);
            Seg s; s.seq = snd_nxt; s.len = seg; s.t_sent = now_ticks();
            s.retransmitted = false;
            inflight.push_back(s);
            snd_nxt += (uint32_t)seg;
        }
    }

    void check_rto(void) {
        if (inflight.empty()) return;
        uint64_t t = now_ticks();
        if (t - inflight.front().t_sent < rto_ticks) return;

        /* go-back-N from snd_una */
        double silent_us   = st.t_last_rx ? ticks_to_us(t - st.t_last_rx) : -1;
        double stuck_us    = ticks_to_us(t - inflight.front().t_sent);
        double ack_age_us  = st.t_last_ack_rx ? ticks_to_us(t - st.t_last_ack_rx) : -1;
        printf("[!!] RTO: retransmitting from snd_una=%u (cwnd %u -> 1 MSS)\n",
               snd_una, cwnd);
        printf("     diag: stuck_front.seq=%u len=%d stuck_for=%.1f us | board silent for "
               "%.1f us (last frame) %.1f us (last ACK) | ack_hi=%u snd_una=%u snd_nxt=%u "
               "delta_hi=%d | rx_frames=%llu rx_ack_data=%llu rx_pure_ack=%llu\n",
               inflight.front().seq, inflight.front().len, stuck_us,
               silent_us, ack_age_us,
               st.ack_hi, snd_una, snd_nxt, (int)(st.ack_hi - snd_una),
               (unsigned long long)st.rx_frames, (unsigned long long)st.rx_ack_data,
               (unsigned long long)st.rx_pure_ack);
        st.retransmits++;
        st.rto_events++;
        record_hole(snd_una, snd_nxt - snd_una, "rto");
        ssthresh = std::max(cwnd / 2, (uint32_t)mss);
        cwnd = mss;
        snd_nxt = snd_una;
        in_recovery = false;             /* RTO leaves fast recovery */
        for (auto &s : inflight) s.retransmitted = true;
        inflight.clear();

        uint32_t base = iss + 1, end = base + total;
        uint32_t in_flight = 0, allowed = std::min(cwnd, (uint32_t)snd_wnd);
        while ((int32_t)(snd_nxt - end) < 0 && in_flight < allowed) {
            int seg = (int)std::min<uint32_t>((uint32_t)mss, std::min(allowed - in_flight, end - snd_nxt));
            if (seg <= 0) break;
            send_data(snd_nxt, seg, true);
            Seg s; s.seq = snd_nxt; s.len = seg; s.t_sent = now_ticks();
            s.retransmitted = true;
            inflight.push_back(s);
            snd_nxt += (uint32_t)seg;
            in_flight += (uint32_t)seg;
        }
    }

    void zero_window_probe(void) {
        st.zero_window_probes++;
        emit(snd_nxt, rcv_nxt, TH_ACK, 0, 0);
    }

    /* One line per stats_interval_ms: throughput, progress, in-flight, RTT,
     * loss counters.  These lines double as the steady-state curve. */
    void log_tick(void) {
        uint64_t t = now_ticks();
        double el = ticks_to_us(t - t_start) / 1e6;
        double dt = ticks_to_us(t - t_log_prev) / 1e6;
        if (dt <= 1e-9) dt = 1e-9;

        uint64_t dtx   = st.tx_unique_bytes - log_tx_prev;
        uint64_t dretx = st.retransmits - log_retx_prev;
        uint64_t ddup  = st.dup_acks - log_dup_prev;
        uint64_t dhole = (uint64_t)holes.size() - log_hole_prev;
        uint64_t dn    = rtt_samples - log_rtt_n_prev;
        double   dsum  = rtt_sum - log_rtt_sum_prev;

        char buf[320];
        snprintf(buf, sizeof(buf),
                 "[t=%7.2fs] %8.1f MB/s %9.1f Mbps | acked %6.2f%% echo %6.2f%% | "
                 "inflight %7u B cwnd %7u | rtt avg %7.1f max %7.1f us (n=%llu) | "
                 "retx %llu dupack %llu holes %llu",
                 el, dtx / dt / 1e6, dtx * 8.0 / dt / 1e6,
                 100.0 * (double)(snd_una - (iss + 1)) / (double)total,
                 100.0 * (double)(rcv_nxt - (irs + 1)) / (double)total,
                 (unsigned)(snd_nxt - snd_una), cwnd,
                 dn ? dsum / (double)dn : 0.0, rtt_win_max,
                 (unsigned long long)dn,
                 (unsigned long long)dretx, (unsigned long long)ddup,
                 (unsigned long long)dhole);
        printf("%s\n", buf);
        fflush(stdout);

        rate_lines.push_back(buf);
        rate_samples.push_back(std::make_pair(el, st.tx_unique_bytes));

        log_tx_prev = st.tx_unique_bytes;
        log_retx_prev = st.retransmits;
        log_dup_prev = st.dup_acks;
        log_hole_prev = (uint64_t)holes.size();
        log_rtt_n_prev = rtt_samples;
        log_rtt_sum_prev = rtt_sum;
        rtt_win_max = 0;
        t_log_prev = t;
    }

    /* ------------- rx-only 模式 (板侧主动发图案) ------------- */
    uint64_t rx_start_t = 0;

    int run_rx_only(void) {
        rx_start_t = now_ticks();
        t_last_progress = rx_start_t;
        snd_una_last = snd_una;
        rcv_nxt_last = rcv_nxt;
        t_log_prev = t_start;
        t_log_next = t_start + (uint64_t)(cfg.stats_interval_ms * 1000.0 / g_us_per_tick);
        rate_samples.push_back(std::make_pair(0.0, (uint64_t)0));
        uint32_t rcv_base = rcv_nxt;
        uint64_t t_last_data = 0;
        for (;;) {
            st.iters++;
            process_rx();
            if (aborted) { t_end = now_ticks(); return 1; }
            if (cfg.stats_interval_ms > 0 && now_ticks() >= t_log_next) {
                log_tick();
                t_log_next = now_ticks() +
                             (uint64_t)(cfg.stats_interval_ms * 1000.0 / g_us_per_tick);
            }
            uint64_t got = (uint64_t)(rcv_nxt - rcv_base);
            if (got != 0) { t_last_progress = now_ticks(); t_last_data = now_ticks(); }
            if (cfg.expect_bytes && got >= cfg.expect_bytes) {
                printf("[ok] 收到 %llu 字节 (目标 %u)\n",
                       (unsigned long long)got, cfg.expect_bytes);
                break;
            }
            if (!cfg.expect_bytes && st.board_fin && got != 0 &&
                !ack_pending) {
                printf("[ok] 对端 FIN 且数据已收完 (%llu 字节)\n",
                       (unsigned long long)got);
                break;
            }
            if (ticks_to_us(now_ticks() - t_last_progress) >
                (double)cfg.stall_ms * 1000.0) {
                printf("[!!] stall: %d ms 无新数据 (收 %llu 字节, 期望 %u, FIN=%llu)\n",
                       cfg.stall_ms, (unsigned long long)got, cfg.expect_bytes,
                       (unsigned long long)st.board_fin);
                t_end = now_ticks();
                report_rx_only(0, got);
                return 2;
            }
            maybe_ack();
            /* 活着的连接: 定期补 ACK, 防止板侧窗口耗尽后静默 */
            if (ack_pending) send_ack();
            WaitForSingleObject(rx_evt, 1);
        }
        t_end = now_ticks();
        maybe_ack();
        report_rx_only(1, (uint64_t)(rcv_nxt - rcv_base));
        return 0;
    }

    void report_rx_only(int ok, uint64_t got) {
        double el = ticks_to_us(t_end - t_start) / 1e6;
        double dsp = (rx_first_t && rx_last_t && rx_last_t > rx_first_t)
                     ? ticks_to_us(rx_last_t - rx_first_t) / 1e6 : 0.0;
        double mbps = dsp > 0 ? (double)got * 8.0 / dsp / 1e6 : 0.0;
        printf("\n=========== RX-ONLY REPORT ===========\n");
        printf("iface        : %s\n", cfg.iface.c_str());
        printf("pattern      : RTL app_pattern xorshift64, take-then-advance, "
               "seed 0x%016llX\n", (unsigned long long)RPAT_SEED);
        printf("expect       : %u bytes%s\n", cfg.expect_bytes,
               cfg.expect_bytes ? "" : " (0 = until peer FIN)");
        printf("received     : %llu bytes  (rcv_nxt 0x%08X -> 0x%08X)\n",
               (unsigned long long)got, irs + 1, rcv_nxt);
        printf("verified     : %llu bytes\n", (unsigned long long)vchk.verified);
        printf("mismatch     : %llu bytes", (unsigned long long)vchk.mismatch);
        if (vchk.have_bad)
            printf("  (first at offset %llu: got %02X want %02X)",
                   (unsigned long long)vchk.first_bad_off,
                   vchk.first_bad_got, vchk.first_bad_exp);
        printf("\n");
        printf("holes        : %llu events / %llu bytes",
               (unsigned long long)rx_hole_events,
               (unsigned long long)(vchk.hole_bytes + rx_gap_pending));
        if (rx_gap_pending)
            printf("  (unfilled gap %llu)", (unsigned long long)rx_gap_pending);
        printf("\n");
        printf("segments     : rx_data_segs=%llu rx_dup=%llu rx_oos=%llu ack_only=%llu\n",
               (unsigned long long)st.rx_data_segs, (unsigned long long)st.rx_dup_segs,
               (unsigned long long)st.rx_out_of_order,
               (unsigned long long)st.rx_ack_only);
        printf("elapsed      : %.3f s (data window %.3f s)\n", el, dsp);
        printf("throughput   : %.1f Mbps (%.2f MB/s)  [data window]\n",
               mbps, mbps / 8.0);
        printf("board FIN/RST: fin=%llu rst=%llu\n",
               (unsigned long long)st.board_fin, (unsigned long long)st.board_rst);
        printf("verdict      : %s\n", (ok && vchk.mismatch == 0 && !aborted)
               ? "PASS" : "FAIL");
        printf("======================================\n");
        fflush(stdout);
    }

    void do_abort(const std::string &why) {
        if (aborted) return;
        aborted = true;
        abort_reason = why;
    }

    int run(void) {
        t_last_progress = now_ticks();
        snd_una_last = snd_una;
        rcv_nxt_last = rcv_nxt;

        uint64_t t_last_zwin = now_ticks();
        uint64_t t_last_ack  = now_ticks();
        bool last_data_done = false;

        t_log_prev = t_start;
        t_log_next = t_start + (uint64_t)(cfg.stats_interval_ms * 1000.0 / g_us_per_tick);
        rate_samples.push_back(std::make_pair(0.0, (uint64_t)0));

        for (;;) {
            /* NOTE: no blocking wait here -- the sleep lives at the loop tail so
             * frames keep accumulating into the sendqueue while receive work is
             * pending.  A flush is a driver round trip (~120 us), so batch size
             * is what sets the peer's ceiling. */
            uint64_t t_it = now_ticks();
            st.iters++;
            process_rx();
            if (aborted) { t_end = now_ticks(); return 1; }

            if (cfg.stats_interval_ms > 0 && now_ticks() >= t_log_next) {
                log_tick();
                t_log_next = now_ticks() +
                             (uint64_t)(cfg.stats_interval_ms * 1000.0 / g_us_per_tick);
            }


            uint32_t base = iss + 1;
            bool tx_done = (snd_una == base + total);
            bool rx_done = (rcv_nxt == irs + 1 + total);

            if (tx_done && rx_done) break;

            if (snd_una != snd_una_last || rcv_nxt != rcv_nxt_last) {
                snd_una_last = snd_una;
                rcv_nxt_last = rcv_nxt;
                t_last_progress = now_ticks();
                if (cfg.verbose)
                    printf("  [..] tx %u/%u acked, rx %u/%u echoed\n",
                           snd_una - base, total, rcv_nxt - (irs + 1), total);
            }

            /* stall detection: FIN stage excluded */
            if (!last_data_done && ticks_to_us(now_ticks() - t_last_progress) >
                                  (double)cfg.stall_ms * 1000.0) {
                printf("[!!] stall: no progress for %d ms (tx %u/%u, rx %u/%u)\n",
                       cfg.stall_ms, snd_una - base, total, rcv_nxt - (irs + 1), total);
                return 2;
            }

            if (tx_done && !last_data_done) {
                last_data_done = true;
                t_last_progress = now_ticks();
                if (cfg.verbose) printf("  [..] all data ACKed, draining echo\n");
            }

            uint64_t t_tx = now_ticks();
            maybe_ack();
            if (!tx_done) {
                uint32_t infl0 = snd_nxt - snd_una;
                send_new_data();
                check_rto();
                /* window-blocked: data still to send, but the window would not
                 * let any of it out this iteration.  This is the signature of a
                 * board/ACK-path-limited run, as opposed to a peer-CPU-limited
                 * one (the peer would then always have room to send). */
                uint32_t allowed0 = std::min(cwnd, (uint32_t)snd_wnd);
                if (snd_nxt - snd_una == infl0 && infl0 >= allowed0) {
                    st.win_block_iters++;
                    win_blocked_iter = true;
                }
                uint32_t allowed = std::min(cwnd, (uint32_t)snd_wnd);
                if (allowed == 0 && ticks_to_us(now_ticks() - t_last_zwin) > 100000.0) {
                    zero_window_probe();
                    t_last_zwin = now_ticks();
                }
            }
            st.t_send_us += ticks_to_us(now_ticks() - t_tx);
            /* keep the peer's send window open even when we have nothing to send */
            if (ack_pending && ticks_to_us(now_ticks() - t_last_ack) > 200000.0) {
                send_ack();
                t_last_ack = now_ticks();
            }
            /* Keep batching while more receive work is queued; flush early if
             * the queue is filling up (flush_frames default 40 keeps unacked
             * echo bytes safely under the peer's advertised window). */
            bool qfull = txq &&
                txq->len > (unsigned int)((size_t)cfg.flush_frames * 1540);
            bool more = (WaitForSingleObject(rx_evt, 0) == WAIT_OBJECT_0);
            double it_us = ticks_to_us(now_ticks() - t_it);
            st.t_loop_us += it_us;
            st.h_loopiter.add(it_us);
            if (win_blocked_iter) { st.win_block_us += (uint64_t)it_us; win_blocked_iter = false; }
            if (more && !qfull) continue;

            flush_tx();                       /* one driver call for N frames */
            if (!more) {
                uint64_t tw = now_ticks();
                WaitForSingleObject(rx_evt, 1);   /* sleep: rx or 1 ms */
                st.t_wait_us += ticks_to_us(now_ticks() - tw);
            }
        }
        t_end = now_ticks();
        return 0;
    }

    void teardown(void) {
        if (!cfg.do_fin) return;
        printf("[..] FIN\n");
        emit(snd_nxt, rcv_nxt, TH_FIN | TH_ACK, 0, 0);
        flush_tx();
        uint64_t t0 = now_ticks();
        bool got_fin = false;
        while (ticks_to_us(now_ticks() - t0) < 2000000.0) {
            WaitForSingleObject(rx_evt, 2);
            process_rx();
            if (st.board_fin) { got_fin = true; break; }
        }
        emit(snd_nxt + 1, (got_fin ? rcv_nxt + 1 : rcv_nxt), TH_ACK, 0, 0);
        flush_tx();
        printf("[ok] %s\n", got_fin ? "FIN+ACK received, closing ACK sent"
                                    : "no FIN back; closing ACK sent anyway");
    }

    /* ---------------- report ---------------- */

    void report(void) {
        double el = ticks_to_us(t_end - t_start) / 1e6;
        uint32_t base = iss + 1;
        printf("\n================ RESULT ================\n");
        printf("iface        : %s\n", cfg.iface.c_str());
        printf("flow         : %u.%u.%u.%u:%u -> %u.%u.%u.%u:%u\n",
               (our_ip >> 24) & 255, (our_ip >> 16) & 255, (our_ip >> 8) & 255, our_ip & 255,
               our_port,
               (peer_ip >> 24) & 255, (peer_ip >> 16) & 255, (peer_ip >> 8) & 255, peer_ip & 255,
               peer_port);
        printf("payload      : %u bytes requested, mss=%d\n", total, mss);
        printf("elapsed      : %.3f s\n", el);
        printf("TX: frames=%llu data_segs=%llu data_bytes=%llu unique_bytes=%llu\n",
               (unsigned long long)st.tx_frames, (unsigned long long)st.tx_data_segs,
               (unsigned long long)st.tx_data_bytes, (unsigned long long)st.tx_unique_bytes);
        printf("TX wire words: %llu   (board macro MW should advance by exactly this)\n",
               (unsigned long long)st.tx_words);
        printf("RX: raw=%llu matched=%llu data_segs=%llu data_bytes=%llu\n",
               (unsigned long long)st.rx_raw, (unsigned long long)st.rx_frames,
               (unsigned long long)st.rx_data_segs, (unsigned long long)st.rx_data_bytes);
        printf("echo verify  : verified=%llu mismatch_segs=%llu mismatch_bytes=%llu\n",
               (unsigned long long)st.verified_bytes,
               (unsigned long long)st.mismatch_segs,
               (unsigned long long)st.mismatch_bytes);
        printf("acked        : snd_una=%u (expected %u)  %s\n",
               snd_una, base + total, (snd_una == base + total) ? "COMPLETE" : "INCOMPLETE");
        printf("echoed       : rcv_nxt=%u (expected %u)  %s\n",
               rcv_nxt, irs + 1 + total,
               (rcv_nxt == irs + 1 + total) ? "COMPLETE" : "INCOMPLETE");
        if (rtt_samples)
            printf("RTT          : min=%.1f us avg=%.1f us max=%.1f us (n=%llu)\n",
                   rtt_min, rtt_sum / (double)rtt_samples, rtt_max,
                   (unsigned long long)rtt_samples);
        else
            printf("RTT          : (no samples)\n");
        printf("events       : retransmits=%llu dup_acks=%llu (recovery %llu) out_of_order=%llu dup_segs=%llu zwin_probes=%llu\n",
               (unsigned long long)st.retransmits, (unsigned long long)st.dup_acks,
               (unsigned long long)st.dup_acks_recovery,
               (unsigned long long)st.rx_out_of_order, (unsigned long long)st.rx_dup_segs,
               (unsigned long long)st.zero_window_probes);
        printf("board ctrl   : RST=%llu FIN=%llu\n",
               (unsigned long long)st.board_rst, (unsigned long long)st.board_fin);

        if (el > 0) {
            printf("throughput   : TX %.2f Mbps / %.2f MB/s (unique payload), RX %.2f Mbps (echo)\n",
                   st.tx_unique_bytes * 8.0 / el / 1e6, st.tx_unique_bytes / el / 1e6,
                   st.rx_data_bytes * 8.0 / el / 1e6);
        }

        /* steady state over the 10%..90% window (same definition as the Python tool) */
        if (rate_samples.size() >= 3) {
            uint64_t tot = rate_samples.back().second;
            double t0 = -1, t1 = -1;
            uint64_t b0 = 0, b1 = 0;
            for (size_t i = 0; i < rate_samples.size(); i++) {
                if (t0 < 0 && rate_samples[i].second >= (uint64_t)(tot * 0.1)) {
                    t0 = rate_samples[i].first; b0 = rate_samples[i].second;
                }
                if (rate_samples[i].second <= (uint64_t)(tot * 0.9)) {
                    t1 = rate_samples[i].first; b1 = rate_samples[i].second;
                }
            }
            if (t0 >= 0 && t1 > t0 && b1 > b0) {
                double dt = t1 - t0;
                double db = (double)(b1 - b0);
                printf("steady state : %.2f MB/s %.2f Mbps  (10%%..90%% window %.2f..%.2f s, %.0f bytes)\n",
                       db / dt / 1e6, db * 8.0 / dt / 1e6, t0, t1, db);
            }
        }

        /* Where did the wall-clock go?  If TX/RX busy time is a large share of
         * elapsed, the PEER is the ceiling, not the board. */
        if (el > 0) {
            printf("I/O cost     : TX %llu calls, %.2f us/call, busy %.1f%% of elapsed\n",
                   (unsigned long long)st.tx_calls,
                   st.tx_calls ? st.tx_time_us / (double)st.tx_calls : 0.0,
                   100.0 * st.tx_time_us / (el * 1e6));
            printf("               RX %llu calls, %.2f us/call, busy %.1f%% of elapsed\n",
                   (unsigned long long)st.rx_calls,
                   st.rx_calls ? st.rx_time_us / (double)st.rx_calls : 0.0,
                   100.0 * st.rx_time_us / (el * 1e6));
            if (el > 0)
                printf("               TX frame rate %.0f fps, RX frame rate %.0f fps\n",
                       st.tx_frames / el, st.rx_calls / el);
        }

        /* ---- throughput-halving instrumentation (2026-09-19) ----
         * The question this answers: at 368 Mbps the board's wire is only 40%
         * busy and the peer's RX frame rate is BELOW what it handled in the
         * echo-only configuration -- so which side stopped first? */
        if (el > 0) {
            FILETIME c, e2, k, u;
            if (GetProcessTimes(GetCurrentProcess(), &c, &e2, &k, &u)) {
                auto ft2s = [](const FILETIME &f) {
                    return ((double)f.dwHighDateTime * 4294967296.0 +
                            (double)f.dwLowDateTime) / 1e7;
                };
                st.cpu_user_s = ft2s(u);
                st.cpu_sys_s  = ft2s(k);
                st.cpu_cores_avg = (st.cpu_user_s + st.cpu_sys_s) / el;
            }
            printf("CPU          : user %.3f s sys %.3f s over %.3f s => %.2f cores "
                   "(2.00 = peer CPU-bound)\n",
                   st.cpu_user_s, st.cpu_sys_s, el, st.cpu_cores_avg);
            printf("peer busy    : loop %.1f%% (%.2f us/iter over %llu iters) "
                   "wait %.1f%% loop_overhead %.1f%%\n",
                   100.0 * st.t_loop_us / (el * 1e6), st.t_loop_us / (double)st.iters,
                   (unsigned long long)st.iters,
                   100.0 * st.t_wait_us / (el * 1e6),
                   100.0 * (st.t_loop_us - st.t_procrx_us - st.t_send_us) / (el * 1e6));
            printf("  breakdown  : proc_rx %.1f%%  handle %.1f%%  send+rto %.1f%%  "
                   "flush %.1f%% (%.1f%% of it blocking)\n",
                   100.0 * st.t_procrx_us / (el * 1e6),
                   100.0 * st.t_handle_us / (el * 1e6),
                   100.0 * st.t_send_us / (el * 1e6),
                   100.0 * st.t_flush_us / (el * 1e6),
                   el > 0 ? 100.0 * st.t_flush_us / (el * 1e6) : 0.0);
            printf("window block : %llu iters (%.1f%%), %.1f%% of elapsed with data "
                   "ready but window closed\n",
                   (unsigned long long)st.win_block_iters,
                   100.0 * (double)st.win_block_iters / (double)st.iters,
                   100.0 * (double)st.win_block_us / (el * 1e6));
            printf("flush        : %llu calls, %.2f frames/call avg, %llu calls with "
                   "<2 frames (pipeline bubbles)\n",
                   (unsigned long long)st.flushes,
                   st.flushes ? (double)st.flush_frames / (double)st.flushes : 0.0,
                   (unsigned long long)st.burst_flushes);
            printf("frame classes: pure_ack=%llu (adv %llu / non-adv %llu), "
                   "ack+data=%llu, win_chg=%llu, dup_ack_data_ignored=%llu\n",
                   (unsigned long long)st.rx_pure_ack, (unsigned long long)st.rx_pure_ack_adv,
                   (unsigned long long)st.rx_pure_ack_dup, (unsigned long long)st.rx_ack_data,
                   (unsigned long long)st.rx_win_change,
                   (unsigned long long)st.dup_ack_data_ignored);
            printf("RX thread    : %llu calls (timeout %llu err %llu), %.2f us/call\n",
                   (unsigned long long)st.rx_calls, (unsigned long long)st.rx_timeouts,
                   (unsigned long long)st.rx_errors,
                   st.rx_calls ? st.rx_time_us / (double)st.rx_calls : 0.0);
            st.h_rxcall.print("  h: rx_call wall");
            st.h_rxframes.print("  h: frames/read");
            st.h_ia.print("  h: rx inter-arrival");
            st.h_handle.print("  h: handle_frame");
            st.h_loopiter.print("  h: loop iter");
            st.h_flush_us.print("  h: flush_tx");
            st.h_flushframes.print("  h: frames/flush");
            printf("lat probe    : hits=%llu no_match=%llu segs_sent=%llu outstanding=%llu\n",
                   (unsigned long long)lat_hits, (unsigned long long)lat_no_match,
                   (unsigned long long)seg_head,
                   (unsigned long long)(seg_head - seg_tail));
            st.h_lat_pureack.print("  h: lat pure-ACK->seg");
            st.h_lat_echo.print("  h: lat echo->seg");
            st.h_lat_pureack_data.print("  h: lat pureACK(adv)");
            st.h_lat_echo_data.print("  h: lat echoACK(adv)");
        }

        printf("loss recovery: fast_retx=%llu rto=%llu holes=%llu\n",
               (unsigned long long)st.fast_retx, (unsigned long long)st.rto_events,
               (unsigned long long)holes.size());
        if (!holes.empty()) {
            printf("holes (board-side loss signature: seq / gap / how recovered / time):\n");
            size_t shown = 0;
            for (size_t i = 0; i < holes.size() && shown < 40; i++, shown++) {
                const Hole &h = holes[i];
                if (h.recovered)
                    printf("  #%llu seq=%u gap=%u B how=%s recovered_in=%.1f us\n",
                           (unsigned long long)i, h.seq, h.gap, h.how.c_str(),
                           ticks_to_us(h.t_recover - h.t_detect));
                else
                    printf("  #%llu seq=%u gap=%u B how=%s UNRECOVERED\n",
                           (unsigned long long)i, h.seq, h.gap, h.how.c_str());
            }
            if (holes.size() > shown)
                printf("  ... %llu more\n", (unsigned long long)(holes.size() - shown));
        }

        bool ok = (!aborted) &&
                  (snd_una == base + total) &&
                  (rcv_nxt == irs + 1 + total) &&
                  (st.mismatch_bytes == 0);
        printf("VERDICT      : %s\n", ok ? "PASS (echo byte-for-byte identical)"
                                          : "FAIL");
        if (aborted) printf("abort reason : %s\n", abort_reason.c_str());
        printf("=======================================\n");
    }
};

/* =====================================================================
 * 5b. UDP 模式 (P5e) — 无连接对端: 发图案 / 收+校验图案
 * =====================================================================
 * 板侧 UDP 通路 (P5e 侦察):
 *   现状 (P5d 位流): 所有 UDP 帧 -> HLS 慢路径 udp_echo (只认 dst_port==8080),
 *     收什么原样 echo 回来 ⇒ "板子自己"就是本工具帧构造/解析的现成对照。
 *   P5e (rtl/udp_rx.v + rtl/udp_tx_frame.v): app 侧自己消费/产生图案流,
 *     并**不 echo** ⇒ 发送模式退化为"只发", 收方向另跑 --udp-rx-only。
 * UDP 无连接 ⇒ 无握手/ACK/重传/窗口/CAM — 只有"发图案"和"收+校验"两件事。
 *
 * 头字段约束 (hls/src/layer_udp.cpp:116-122: 板侧 echo 把请求的 ip.totlen 与
 * udp_len **照抄**回去) ⇒ 本端必须自洽:
 *     ip.totlen == 20 + udp_len == 20 + 8 + plen
 * udp_len < 8 会被 rtl/udp_rx.v:135 丢弃; 板侧慢路径只接受 dst_port == 8080
 * (layer_udp.cpp:53); RTL 的 udp_rx 还要求校验和正确的 IP 头 + ver/ihl==0x45
 * (:137/:139)。UDP 校验和: 板侧回包恒置 0 (layer_udp.cpp:175), 两侧都不校验
 * ⇒ 本端默认仍按 RFC 768 正确算 (自检里独立验算), --udp-csum 0 可置零。
 *
 * 图案: 与 TCP 路径同一约定 (xorshift64, 先取 s[31:24] 再推进, 种子 RPAT_SEED),
 * 但 UDP 侧用**相位精确的 LFSR 行走**而不是 64 KiB 查表 —— 查表每 65536 B 重复
 * 一次, 流长超过 64 KiB 就与 RTL 图案流错开 (TCP 的 --bytes 有同样限制, 见
 * README §8.5)。自检里有"表 == LFSR 前 64 KiB"的交叉验证。
 * ===================================================================== */

#define IP_PROTO_UDP 17

static uint16_t g_udp_ip_id = 0;

/* 一条 UDP 流的全部寻址参数 (发送构造 / 收方向过滤 / 自检 三处共用一份) */
struct UdpFlow {
    uint8_t  our_mac[6], peer_mac[6];
    uint32_t our_ip, peer_ip;
    uint16_t our_port, peer_port;
    bool     csum_en;
};

/* ---- 帧构造: 载荷 = 图案流 [off, off+plen) ----
 * payload != 0 时直接用该缓冲 (运行期用相位精确的 LFSR 发生器), 否则用
 * 64 KiB 查表 pay_fill (自检用; 两者在前 64 KiB 逐字节相同)。
 * buf 至少 14+20+8+plen 字节; 返回线上帧长 (不含 FCS, 已按最小帧 60B 补齐)。 */
static int udp_build(uint8_t *buf, const UdpFlow &fl, uint32_t off, int plen,
                     const uint8_t *payload = 0) {
    int udp_len   = 8 + plen;
    int ip_len    = 20 + udp_len;
    int frame_len = ETH_HDR_LEN + ip_len;
    memset(buf, 0, (size_t)std::max(frame_len, ETH_MIN_FRAME));

    EthHdr *e = (EthHdr *)buf;
    memcpy(e->dst, fl.peer_mac, 6);
    memcpy(e->src, fl.our_mac, 6);
    e->type = htons(ETH_IP4);

    IpHdr *ip = (IpHdr *)(buf + ETH_HDR_LEN);
    ip->vihl   = 0x45;
    ip->tos    = 0;
    ip->totlen = htons((uint16_t)ip_len);
    ip->id     = htons(++g_udp_ip_id);
    ip->frag   = htons(0x4000);            /* DF */
    ip->ttl    = 64;
    ip->proto  = IP_PROTO_UDP;
    ip->csum   = 0;
    ip->src    = htonl(fl.our_ip);
    ip->dst    = htonl(fl.peer_ip);
    ip->csum   = htons(csum_fold(csum_acc(0, (const uint8_t *)ip, 20)));

    uint8_t *u = buf + ETH_HDR_LEN + 20;
    u[0] = (uint8_t)(fl.our_port  >> 8); u[1] = (uint8_t)(fl.our_port  & 0xFF);
    u[2] = (uint8_t)(fl.peer_port >> 8); u[3] = (uint8_t)(fl.peer_port & 0xFF);
    u[4] = (uint8_t)(udp_len >> 8);      u[5] = (uint8_t)(udp_len & 0xFF);
    u[6] = 0; u[7] = 0;                    /* 校验和占位 */
    if (plen > 0) {
        if (payload) memcpy(buf + ETH_HDR_LEN + 28, payload, (size_t)plen);
        else         pay_fill(buf + ETH_HDR_LEN + 28, off, plen);
    }

    if (fl.csum_en) {
        /* 伪头 (src_ip|dst_ip|0|proto|udp_len) + UDP 头 + 载荷 */
        uint32_t sum = 0;
        uint8_t pseudo[12];
        memcpy(pseudo + 0, &ip->src, 4);
        memcpy(pseudo + 4, &ip->dst, 4);
        pseudo[8] = 0;
        pseudo[9] = IP_PROTO_UDP;
        pseudo[10] = (uint8_t)(udp_len >> 8);
        pseudo[11] = (uint8_t)(udp_len & 0xFF);
        sum = csum_acc(sum, pseudo, 12);
        sum = csum_acc(sum, u, 8);
        if (plen > 0) sum = csum_acc(sum, buf + ETH_HDR_LEN + 28, plen);
        uint16_t cs = csum_fold(sum);
        if (cs == 0) cs = 0xFFFF;          /* RFC 768: 0 = "无校验和", 用全 1 代替 */
        u[6] = (uint8_t)(cs >> 8); u[7] = (uint8_t)(cs & 0xFF);
    }
    return frame_len < ETH_MIN_FRAME ? ETH_MIN_FRAME : frame_len;
}

/* ---- 帧解析 + 收方向接受判定 ---- */

struct UdpPkt {
    uint32_t src_ip, dst_ip;
    uint16_t sport, dport, udp_len;
    const uint8_t *pay;
    int      plen;          /* udp_len - 8, 且不超过帧内实际可用字节 */
    int      ihl;
    bool     ip_csum_ok;
    bool     udp_len_ok;
    bool     ihl5;          /* ver/ihl == 0x45 (板侧 RTL 硬要求) */
};

/* 解析到 UDP 层 (含 IP 校验和判定)。返回 false = 不是 IPv4/UDP 或头被截断。 */
static bool udp_parse(const uint8_t *f, int flen, UdpPkt *o) {
    if (flen < ETH_HDR_LEN) return false;
    const EthHdr *e = (const EthHdr *)f;
    int off = ETH_HDR_LEN;
    uint16_t et = ntohs(e->type);
    if (et == ETH_VLAN) { off += 4; if (flen < off + 2) return false; et = rd16(f + off - 2); }
    if (et != ETH_IP4) return false;
    if (flen < off + 20) return false;
    const IpHdr *ip = (const IpHdr *)(f + off);
    if ((ip->vihl >> 4) != 4) return false;
    int ihl = (ip->vihl & 0x0F) * 4;
    if (ihl < 20 || flen < off + ihl + 8) return false;
    if (ip->proto != IP_PROTO_UDP) return false;

    const uint8_t *u = f + off + ihl;
    o->src_ip = ntohl(ip->src);
    o->dst_ip = ntohl(ip->dst);
    o->sport  = (uint16_t)((u[0] << 8) | u[1]);
    o->dport  = (uint16_t)((u[2] << 8) | u[3]);
    o->udp_len= (uint16_t)((u[4] << 8) | u[5]);
    o->ihl    = ihl;
    o->ihl5   = (ip->vihl == 0x45);
    /* 反码和折叠到 0xFFFF ⇒ 头正确 (csum_fold 取反 ⇒ 正确时得 0) */
    o->ip_csum_ok = (csum_fold(csum_acc(0, (const uint8_t *)ip, (uint32_t)ihl)) == 0);
    o->udp_len_ok = (o->udp_len >= 8);
    int avail = flen - off - ihl - 8;
    o->plen = (int)o->udp_len - 8;
    if (o->plen < 0) o->plen = 0;
    if (o->plen > avail) o->plen = avail;
    o->pay = u + 8;
    return true;
}

/* 收方向接受判定 (镜像板侧 udp_rx 的门): 协议/IP 校验和/长度 + 双向地址配对。
 * strict_ports = true 时还要求 sport==peer_port && dport==our_port
 * (板侧 echo 就是 src 8080 -> dst 请求源端口, 这条把板侧周期 HELLO
 *  (8080->8080) 这类噪声挡在外面; P5e app 发方向端口不同时用 --udp-any-port)。 */
static bool udp_accept(const UdpPkt &p, const UdpFlow &fl, bool strict_ports) {
    if (!p.ihl5 || !p.ip_csum_ok || !p.udp_len_ok) return false;
    if (p.src_ip != fl.peer_ip || p.dst_ip != fl.our_ip) return false;
    if (strict_ports && (p.sport != fl.peer_port || p.dport != fl.our_port)) return false;
    return true;
}

/* 反向流 (对端 -> 本端): 自检里用它模拟"板子发来的帧", 好让构造出来的帧
 * 真的能通过本端 udp_accept 的地址/端口配对判定。 */
static UdpFlow udp_flow_reverse(const UdpFlow &f) {
    UdpFlow r;
    r.our_ip = f.peer_ip;    r.peer_ip = f.our_ip;
    r.our_port = f.peer_port; r.peer_port = f.our_port;
    memcpy(r.our_mac, f.peer_mac, 6);
    memcpy(r.peer_mac, f.our_mac, 6);
    r.csum_en = f.csum_en;
    return r;
}

/* ---- 相位精确的 RTL 图案流发生器 (LFSR 行走, 任意长度不重复) ---- */
struct RtlPatGen {
    uint64_t s   = RPAT_SEED;
    uint64_t pos = 0;
    void reset() { s = RPAT_SEED; pos = 0; }
    void seek(uint64_t off) { while (pos < off) { s = xs_next64(s); pos++; } }
    void fill(uint8_t *dst, int n) {
        for (int i = 0; i < n; i++) { dst[i] = (uint8_t)(s >> 24); s = xs_next64(s); }
        pos += (uint64_t)n;
    }
};

/* ---- UDP 图案流校验器: RxPatChecker 语义 + 失配重同步 ----
 * UDP 没有序号, 丢帧只能靠图案流相位发现: 某字节失配时向后搜索最小的 k >= 1
 * 使接下来的 W 字节全部对上 ⇒ 判为"丢了 k 字节", 记 hole 并继续 (W=16 时误判
 * 概率 2^-128)。搜索预算用 LFSR 步数封顶, 防止"完全错图案"退化成热循环。 */
struct UdpStreamChecker {
    enum { W = 16, SEARCH_STEPS_MAX = 64000000 };   /* 约 100 ms 的搜索预算 */
    uint64_t s = RPAT_SEED;
    uint64_t pos = 0;
    uint64_t verified = 0, mismatch = 0;
    uint64_t holes = 0, hole_bytes = 0;
    uint64_t subst = 0;                 /* 相位内的单字节替换 (板侧回包被改写) */
    uint64_t subst_events = 0;
    uint64_t searches = 0, searches_ok = 0, search_steps = 0;
    int      search_cooldown = 0;       /* 搜索失败后的退避 (连片坏字节别逐字节搜) */
    uint64_t first_bad_off = 0;
    uint8_t  first_bad_got = 0, first_bad_exp = 0;
    bool     have_bad = false;
    /* 首次失配处的 24 字节对照 (诊断: 截断/错位/重复 一眼可分) */
    uint8_t  dbg_got[24] = {0}, dbg_want[24] = {0};
    int      dbg_n = 0;

    void reset() { *this = UdpStreamChecker(); }
    void skip(uint64_t n) { for (uint64_t i = 0; i < n; i++) s = xs_next64(s); pos += n; }

    /* 从当前相位向后找 p[0..need) 的落点; 返回偏移 k >= 1 (0 = 没找到) */
    int find_resync(const uint8_t *p, int n, int kmax) {
        int need = n < W ? n : W;
        uint64_t t = s;
        for (int k = 1; k <= kmax; k++) {
            t = xs_next64(t);
            if (search_steps + (uint64_t)k > SEARCH_STEPS_MAX) { search_steps = SEARCH_STEPS_MAX; return 0; }
            if ((uint8_t)(t >> 24) != p[0]) continue;
            uint64_t tv = t;
            bool ok = true;
            for (int j = 0; j < need; j++) {
                if ((uint8_t)(tv >> 24) != p[j]) { ok = false; break; }
                tv = xs_next64(tv);
            }
            if (ok) { search_steps += (uint64_t)k; return k; }
        }
        search_steps += (uint64_t)kmax;
        return 0;
    }

    /* 是"单字节被替换"还是"丢了一段"? 判据: 看后续 W 字节是否与**当前相位+1**
     * 吻合 —— 吻合说明流没移位, 只是这个字节坏了 (只记 1 个 mismatch, 相位照常
     * 前进, 不记 hole)。不做这个判断的话, 一个坏字节会被当成"丢了 1 字节",
     * 之后整个流的相位就永久超前 1 ⇒ 满屏 mismatch (实测把 8 个坏字节报成 1988)。 */
    bool in_phase_after_mismatch(const uint8_t *p, int n, int i) {
        int probe = n - i - 1;
        if (probe > W) probe = W;
        if (probe <= 0) return false;              /* 窗口尾部: 无从判断 */
        uint64_t t = s;
        for (int j = 0; j < probe; j++) {
            t = xs_next64(t);
            if ((uint8_t)(t >> 24) != p[i + 1 + j]) return false;
        }
        return true;
    }

    /* 校验 n 个连续字节 (与上一次 check 的窗口首尾相接) */
    void check(const uint8_t *p, int n, int kmax) {
        for (int i = 0; i < n; i++) {
            uint8_t exp = (uint8_t)(s >> 24);
            if (p[i] == exp) { verified++; s = xs_next64(s); pos++; continue; }
            /* 失配: 情形 ① —— 流仍在相位上, 只是这个字节被换掉了 */
            bool subst = in_phase_after_mismatch(p, n, i);
            if (subst) subst_events++;
            /* 失配: 情形 ② —— 向后搜索丢帧重同步 (kmax=0 关闭)。
             * 硬要求: 本窗口剩余字节 >= W, 否则"重同步"只是拿 1~2 个字节去撞
             * 匹配 (64K 个候选里几乎必然撞上) ⇒ 相位凭空跳走, 之后满屏假失配。
             * 实测: 帧尾最后 1 字节坏掉 (板侧最常见的形态) 被误报成 992 个失配。 */
            if (!subst && kmax > 0 && (n - i) >= W &&
                search_steps < SEARCH_STEPS_MAX && !search_cooldown) {
                searches++;
                int k = find_resync(p + i, n - i, kmax);
                if (k > 0) {
                    searches_ok++;
                    holes++; hole_bytes += (uint64_t)k;
                    skip((uint64_t)k);
                    exp = (uint8_t)(s >> 24);
                    if (p[i] == exp) { verified++; s = xs_next64(s); pos++; continue; }
                } else {
                    search_cooldown = 64;   /* 搜不到就别逐字节再搜 (连片坏字节) */
                }
            }
            if (search_cooldown) search_cooldown--;
            if (!have_bad) {
                have_bad = true; first_bad_off = pos;
                first_bad_got = p[i]; first_bad_exp = exp;
                /* 同步留一份 24 字节对照: 期望值用当前相位往后走 */
                dbg_n = (n - i < (int)sizeof(dbg_got)) ? (n - i) : (int)sizeof(dbg_got);
                uint64_t tv = s;
                for (int j = 0; j < dbg_n; j++) {
                    dbg_got[j]  = p[i + j];
                    dbg_want[j] = (uint8_t)(tv >> 24);
                    tv = xs_next64(tv);
                }
                for (int j = dbg_n; j < (int)sizeof(dbg_want); j++) dbg_want[j] = 0;
            }
            mismatch++;
            s = xs_next64(s); pos++;
        }
    }
};

/* ---- UDP 统计 (纯 UDP 运行期的一段计数; 与 TCP 的 Stats 互不干扰) ---- */
struct UdpStats {
    uint64_t tx_frames = 0, tx_pay_bytes = 0, tx_wire_bytes = 0, tx_words = 0;
    uint64_t tx_flushes = 0, tx_calls = 0;
    double   tx_time_us = 0;
    uint64_t rx_raw = 0, rx_frames = 0, rx_rejected = 0, rx_junk = 0, rx_bad_ipcsum = 0;
    uint64_t rx_pay_bytes = 0, rx_zero_pay = 0;
    uint64_t rx_calls = 0, rx_timeouts = 0, rx_errors = 0;
    double   rx_time_us = 0;
    Hist     h_ia;              /* 回包到达间隔 (板侧 echo/app TX 节奏) */
    FILE    *dump = 0;          /* --udp-dump: 收到的载荷流落盘 (事后解剖) */
    uint64_t dump_bytes = 0;
    uint64_t dump_cap = 4u << 20;
    uint64_t iters = 0;
    double   cpu_user_s = 0, cpu_sys_s = 0;
    void reset() { *this = UdpStats(); }
};
static UdpStats us;

/* ---- UDP 对端 ---- */

class UdpPeer {
public:
    UdpFlow  flow;
    pcap_t  *pcap = 0;
    struct pcap_send_queue *txq = 0;
    uint64_t queued_frames = 0;

    /* TX */
    RtlPatGen gen;
    uint64_t  lim_bytes = 0;         /* 限速记账: 已发线上字节 */
    uint64_t  lim_t0 = 0;
    uint64_t  tx_calls_ = 0;
    /* RX */
    UdpStreamChecker chk;
    uint64_t  rx_first_t = 0, rx_last_t = 0;
    uint64_t  t_rx_prev = 0;
    /* 控制 */
    bool      aborted = false;
    std::string abort_reason;
    uint64_t  t_start = 0, t_end = 0;
    uint64_t  t_send0 = 0, t_send_end = 0;   /* 发送窗口 (限速/速率结论只看这段) */
    uint64_t  t_log_prev = 0, t_log_next = 0;
    uint64_t  log_tx_prev = 0, log_rx_prev = 0;
    std::vector<std::pair<double, uint64_t>> rate_samples;   /* (秒, 已发载荷字节) */

    std::mutex             rx_mtx;
    std::deque<RxItem>     rx_q;
    HANDLE                 rx_evt = 0;
    std::atomic<bool>      stop_rx{false};
    std::thread            rx_thread;

    /* ---------------- 初始化 ---------------- */

    void init(pcap_t *p) {
        pcap = p;
        memcpy(flow.our_mac, cfg.src_mac, 6);
        memcpy(flow.peer_mac, cfg.dst_mac, 6);
        flow.our_ip = cfg.src_ip;
        flow.peer_ip = cfg.dst_ip;
        flow.our_port = cfg.sport;
        flow.peer_port = cfg.dport;
        flow.csum_en = cfg.udp_csum;

        if (!cfg.udp_dump.empty()) {
            us.dump = fopen(cfg.udp_dump.c_str(), "wb");
            if (!us.dump) fprintf(stderr, "note: 无法打开 --udp-dump 文件 %s\n",
                                  cfg.udp_dump.c_str());
        }

        rx_evt = CreateEventA(0, FALSE, FALSE, 0);
        lim_t0 = t_start = t_log_prev = now_ticks();
        t_log_next = t_start +
                     (uint64_t)(cfg.stats_interval_ms * 1000.0 / g_us_per_tick);
        if (cfg.tx_batch) {
            txq = pcap_sendqueue_alloc((unsigned int)cfg.tx_queue_kb * 1024);
            if (!txq) {
                printf("[!!] pcap_sendqueue_alloc(%d KB) failed; 退化为逐帧 pcap_sendpacket\n",
                       cfg.tx_queue_kb);
                cfg.tx_batch = false;
            }
        }
    }

    void do_abort(const std::string &why) {
        if (aborted) return;
        aborted = true;
        abort_reason = why;
    }

    /* ---------------- RX 线程 (与 TCP 版同构: 线程只入队, 主线程解析) -------- */

    void start_rx(void) { rx_thread = std::thread([this] { rx_loop(); }); }

    void halt_rx(void) {
        stop_rx.store(true);
        if (rx_evt) SetEvent(rx_evt);
        if (rx_thread.joinable()) rx_thread.join();
    }

    void rx_loop(void) {
        uint64_t t_prev = 0;
        while (!stop_rx.load()) {
            struct pcap_pkthdr *hdr = 0;
            const unsigned char *data = 0;
            uint64_t t0 = now_ticks();
            int r = pcap_next_ex(pcap, &hdr, &data);
            uint64_t t1 = now_ticks();
            us.rx_time_us += ticks_to_us(t1 - t0);
            us.rx_calls++;
            if (r == 1) {
                if (!hdr || hdr->caplen < (unsigned)ETH_HDR_LEN) continue;
                RxItem it;
                it.data.assign(data, data + hdr->caplen);
                it.t_recv = t1;
                us.rx_raw++;
                if (t_prev) us.h_ia.add(ticks_to_us(t1 - t_prev));
                t_prev = t1;
                {
                    std::lock_guard<std::mutex> g(rx_mtx);
                    if (rx_q.size() < 200000) rx_q.push_back(std::move(it));
                }
                if (rx_evt) SetEvent(rx_evt);
            } else if (r == 0) {
                us.rx_timeouts++;
            } else {
                us.rx_errors++;
                break;
            }
        }
    }

    /* 取走待处理帧并解析; 返回本次校验的载荷字节数 */
    uint64_t drain_rx(void) {
        std::deque<RxItem> batch;
        {
            std::lock_guard<std::mutex> g(rx_mtx);
            if (rx_q.empty()) return 0;
            batch.swap(rx_q);
        }
        uint64_t got = 0;
        for (auto &it : batch) got += handle_frame(it.data.data(), (int)it.data.size(), it.t_recv);
        return got;
    }

    uint64_t handle_frame(const uint8_t *f, int flen, uint64_t t_recv) {
        /* 自己发的帧也会被抓到 (npcap 双向) —— 按源 MAC 丢掉 */
        if (flen >= 12 && memcmp(f + 6, flow.our_mac, 6) == 0) return 0;
        UdpPkt p;
        if (!udp_parse(f, flen, &p)) { us.rx_junk++; return 0; }
        if (!udp_accept(p, flow, cfg.udp_strict_ports)) { us.rx_rejected++; return 0; }
        us.rx_frames++;
        if (!p.ip_csum_ok) us.rx_bad_ipcsum++;
        if (p.plen <= 0) { us.rx_zero_pay++; return 0; }
        if (!rx_first_t) rx_first_t = t_recv;
        rx_last_t = t_recv;
        us.rx_pay_bytes += (uint64_t)p.plen;
        if (us.dump && us.dump_bytes < us.dump_cap) {     /* --udp-dump 落盘 */
            size_t w = (size_t)p.plen;
            if (us.dump_bytes + w > us.dump_cap) w = (size_t)(us.dump_cap - us.dump_bytes);
            fwrite(p.pay, 1, w, us.dump);
            us.dump_bytes += w;
        }
        chk.check(p.pay, p.plen, cfg.udp_resync);
        if (cfg.verbose && us.rx_frames <= 8)
            printf("  [rx] %u.%u.%u.%u:%u -> :%u len=%d udp_len=%u\n",
                   (p.src_ip >> 24) & 255, (p.src_ip >> 16) & 255,
                   (p.src_ip >> 8) & 255, p.src_ip & 255, p.sport, p.dport,
                   p.plen, p.udp_len);
        return (uint64_t)p.plen;
    }

    /* ---------------- TX ---------------- */

    void emit_frame(const uint8_t *payload, int plen, uint32_t off) {
        uint8_t buf[ETH_HDR_LEN + 28 + 2048];
        int send_len = udp_build(buf, flow, off, plen, payload);
        if (cfg.tx_batch && txq) {
            struct pcap_pkthdr h;
            h.ts.tv_sec = 0; h.ts.tv_usec = 0;
            h.caplen = h.len = (unsigned int)send_len;
            if (pcap_sendqueue_queue(txq, &h, buf) != 0) {
                flush_tx();                                  /* 队列满 */
                if (pcap_sendqueue_queue(txq, &h, buf) != 0)
                    fprintf(stderr, "pcap_sendqueue_queue failed (frame > queue?)\n");
            }
            queued_frames++;
        } else {
            uint64_t t0 = now_ticks();
            if (pcap_sendpacket(pcap, buf, send_len) != 0)
                fprintf(stderr, "pcap_sendpacket failed: %s\n", pcap_geterr(pcap));
            us.tx_time_us += ticks_to_us(now_ticks() - t0);
            us.tx_calls++;
        }
        (void)off;
        us.tx_frames++;
        us.tx_pay_bytes += (uint64_t)plen;
        us.tx_wire_bytes += (uint64_t)send_len;
        us.tx_words += (uint64_t)((send_len + 7) / 8);
        lim_bytes += (uint64_t)send_len;
    }

    void flush_tx(void) {
        if (!txq || txq->len == 0) return;
        uint64_t t0 = now_ticks();
        pcap_sendqueue_transmit(pcap, txq, cfg.tx_sync);
        us.tx_time_us += ticks_to_us(now_ticks() - t0);
        us.tx_calls++;
        us.tx_flushes++;
        queued_frames = 0;
        txq->len = 0;
    }

    /* 线上帧长 (给定载荷长度, 用于限速预算) */
    static uint64_t wire_len(int plen) {
        uint64_t l = (uint64_t)(ETH_HDR_LEN + 28 + plen);
        return l < (uint64_t)ETH_MIN_FRAME ? (uint64_t)ETH_MIN_FRAME : l;
    }

    /* 限速: 等到"自 t0 起的平均速率"允许再发 wire 字节。
     * 板侧 app RX 消费是字节串行 (~15.6 MB/s @125MHz), 不限速会把板侧冲垮
     * ⇒ 制造假失配。默认 50 Mbps = 6.25 MB/s, 有 2.5x 裕量。 */
    void rate_wait(uint64_t wire) {
        if (cfg.rate_mbps <= 0) return;
        for (;;) {
            double el_us   = ticks_to_us(now_ticks() - lim_t0);
            double need_us = (double)(lim_bytes + wire) * 8.0 / cfg.rate_mbps;
            if (el_us >= need_us) return;
            double def = need_us - el_us;
            if (def > 2000.0 || !cfg.udp_spin) {
                if (rx_evt) WaitForSingleObject(rx_evt, 1);   /* 顺带服务 RX */
                else Sleep(1);
                drain_rx();
            }
            /* 亚毫秒: 自旋 (Windows 睡眠粒度 ~1-2 ms, 睡会变成 ~4 帧的突发;
             * 自旋让流量平滑, 代价是发送期间占一个核) */
        }
    }

    /* ---------------- 每秒速率日志 (风格对齐 TCP 版 log_tick) --------------- */

    void log_tick(void) {
        uint64_t t = now_ticks();
        double el = ticks_to_us(t - t_start) / 1e6;
        double dt = ticks_to_us(t - t_log_prev) / 1e6;
        if (dt <= 1e-9) dt = 1e-9;
        uint64_t dtx = us.tx_pay_bytes - log_tx_prev;
        uint64_t drx = us.rx_pay_bytes - log_rx_prev;
        printf("[t=%7.2fs] TX %8.1f Mbps (%8.1f MB/s) frames %llu | RX %8.1f Mbps "
               "frames %llu | pat verified %llu mismatch %llu holes %llu\n",
               el, dtx * 8.0 / dt / 1e6, dtx / dt / 1e6,
               (unsigned long long)us.tx_frames,
               drx * 8.0 / dt / 1e6, (unsigned long long)us.rx_frames,
               (unsigned long long)chk.verified, (unsigned long long)chk.mismatch,
               (unsigned long long)chk.holes);
        fflush(stdout);
        rate_samples.push_back(std::make_pair(el, us.tx_pay_bytes));
        log_tx_prev = us.tx_pay_bytes;
        log_rx_prev = us.rx_pay_bytes;
        t_log_prev = t;
    }

    void tick_logs(void) {
        if (cfg.stats_interval_ms > 0 && now_ticks() >= t_log_next) {
            log_tick();
            t_log_next = now_ticks() +
                         (uint64_t)(cfg.stats_interval_ms * 1000.0 / g_us_per_tick);
        }
    }

    /* ---------------- 发送模式 (--udp-send-pattern N) ---------------- */

    int run_send(void) {
        uint32_t target = cfg.udp_bytes;
        int paylen = cfg.udp_paylen;
        if (paylen < 0) paylen = 0;
        if (paylen > 1472) paylen = 1472;          /* MTU 内 (1514 - 42) */
        printf("[..] UDP 发送图案 %u 字节 (每帧 %d B 载荷, 限速 %s)\n",
               target, paylen,
               cfg.rate_mbps > 0 ? "on" : "OFF");
        fflush(stdout);
        /* 限速基准 = 传输起点 (不能沿用 init 以来累积的空闲时间, 否则前
         * 几十 KB 会因为"欠账"被一次性放行, 限速形同虚设) */
        lim_t0 = now_ticks();
        lim_bytes = 0;
        t_log_prev = lim_t0;
        t_log_next = lim_t0 +
                     (uint64_t)(cfg.stats_interval_ms * 1000.0 / g_us_per_tick);
        t_send0 = now_ticks();
        uint8_t paybuf[2048];
        uint32_t sent = 0;
        uint64_t last_evt = 0;
        while (sent < target) {
            us.iters++;
            tick_logs();
            /* 限速预算内能发几帧就发几帧 (按线上字节计) */
            int nframe = 0;
            while (sent < target) {
                int plen = (int)std::min<uint32_t>((uint32_t)paylen, target - sent);
                uint64_t wl = wire_len(plen);
                if (cfg.rate_mbps > 0) {
                    double el_us   = ticks_to_us(now_ticks() - lim_t0);
                    double need_us = (double)(lim_bytes + wl) * 8.0 / cfg.rate_mbps;
                    if (el_us < need_us) break;
                }
                uint32_t off = (uint32_t)gen.pos;   /* fill 之前取偏移 */
                gen.fill(paybuf, plen);
                emit_frame(paybuf, plen, off);
                sent += (uint32_t)plen;
                nframe++;
                if (queued_frames >= (uint64_t)cfg.flush_frames) flush_tx();
                drain_rx();
                if (nframe >= 64) break;      /* 让 RX/日志有机会跑 */
            }
            flush_tx();
            if (sent >= target) break;
            uint64_t t = now_ticks();
            if (t - last_evt > (uint64_t)(50000.0 / g_us_per_tick)) {  /* 50 ms */
                last_evt = t;
                if (cfg.verbose || cfg.stats_interval_ms > 0) {
                    /* 进度行由 log_tick 负责; 这里只保证 rx 队列被排空 */
                }
            }
            rate_wait(wire_len((int)std::min<uint32_t>((uint32_t)paylen, target - sent)));
            drain_rx();
            if (aborted) break;
        }
        t_send_end = now_ticks();
        double send_sec = ticks_to_us(t_send_end - t_send0) / 1e6;
        printf("[ok] 发送完成: %u 字节 / %llu 帧 / %.3f s (载荷 %.1f Mbps / 线上 %.1f Mbps)\n",
               sent, (unsigned long long)us.tx_frames, send_sec,
               send_sec > 0 ? (double)sent * 8.0 / send_sec / 1e6 : 0.0,
               send_sec > 0 ? (double)us.tx_wire_bytes * 8.0 / send_sec / 1e6 : 0.0);
        fflush(stdout);
        flush_tx();
        return (int)sent;
    }

    /* ---------------- 收模式 (--udp-rx-only [N]) ---------------- */

    int run_rx_only(void) {
        uint32_t target = cfg.udp_bytes;
        printf("[..] UDP 只收+校验: 目标 %u 字节 (%s), 图案 = RTL xorshift64 自 offset 0\n",
               target, target ? "定长" : "到 stall 为止");
        uint64_t t_last_data = now_ticks();
        for (;;) {
            us.iters++;
            uint64_t got = drain_rx();
            if (got) t_last_data = now_ticks();
            tick_logs();
            if (aborted) { t_end = now_ticks(); return 1; }
            if (target && us.rx_pay_bytes >= (uint64_t)target) {
                printf("[ok] 收到 %llu 字节 (目标 %u)\n",
                       (unsigned long long)us.rx_pay_bytes, target);
                break;
            }
            if (ticks_to_us(now_ticks() - t_last_data) > (double)cfg.stall_ms * 1000.0) {
                printf("[!!] stall: %d ms 无新数据 (收 %llu 字节, 期望 %u, 帧 %llu)\n",
                       cfg.stall_ms, (unsigned long long)us.rx_pay_bytes, target,
                       (unsigned long long)us.rx_frames);
                t_end = now_ticks();
                return 2;
            }
            if (rx_evt) WaitForSingleObject(rx_evt, 1);
            else Sleep(1);
        }
        t_end = now_ticks();
        return 0;
    }

    /* 发送模式收到回包时: 排空 + 判"回包是否齐了" */
    void wait_echo(uint32_t target) {
        uint64_t t_last_data = now_ticks();
        uint64_t t0 = now_ticks();
        /* 回包数够或静默 --stall-ms 就收工 */
        while (us.rx_pay_bytes < (uint64_t)target) {
            us.iters++;
            uint64_t got = drain_rx();
            if (got) t_last_data = now_ticks();
            tick_logs();
            if (aborted) break;
            if (ticks_to_us(now_ticks() - t_last_data) > (double)cfg.stall_ms * 1000.0) break;
            if (ticks_to_us(now_ticks() - t0) > (double)cfg.stall_ms * 4000.0) break;
            if (rx_evt) WaitForSingleObject(rx_evt, 1);
            else Sleep(1);
        }
    }

    /* ---------------- 报告 ---------------- */

    void report(const char *mode) {
        if (!t_end) t_end = now_ticks();
        double el = ticks_to_us(t_end - t_start) / 1e6;
        double dsp = (rx_first_t && rx_last_t && rx_last_t > rx_first_t)
                     ? ticks_to_us(rx_last_t - rx_first_t) / 1e6 : 0.0;
        uint64_t missing = (us.tx_frames > us.rx_frames) ? us.tx_frames - us.rx_frames : 0;
        double rx_mbps = dsp > 0 ? (double)us.rx_pay_bytes * 8.0 / dsp / 1e6 : 0.0;

        printf("\n================ UDP RESULT ================\n");
        printf("mode         : %s\n", mode);
        printf("iface        : %s\n", cfg.iface.c_str());
        printf("flow         : %u.%u.%u.%u:%u <-> %u.%u.%u.%u:%u (UDP)\n",
               (flow.our_ip >> 24) & 255, (flow.our_ip >> 16) & 255,
               (flow.our_ip >> 8) & 255, flow.our_ip & 255, flow.our_port,
               (flow.peer_ip >> 24) & 255, (flow.peer_ip >> 16) & 255,
               (flow.peer_ip >> 8) & 255, flow.peer_ip & 255, flow.peer_port);
        printf("framing      : paylen=%d B, udp csum=%s, rate-limit=%s\n",
               cfg.udp_paylen, cfg.udp_csum ? "on (RFC768)" : "zero",
               cfg.rate_mbps > 0 ? "on" : "OFF");
        printf("elapsed      : %.3f s (RX 数据窗口 %.3f s)\n", el, dsp);
        printf("TX           : frames=%llu payload=%llu B wire=%llu B\n",
               (unsigned long long)us.tx_frames, (unsigned long long)us.tx_pay_bytes,
               (unsigned long long)us.tx_wire_bytes);
        printf("TX wire words: %llu   (板侧 MW 应恰好前进这么多)\n",
               (unsigned long long)us.tx_words);
        if (t_send_end > t_send0) {
            double sw = ticks_to_us(t_send_end - t_send0) / 1e6;
            printf("TX send win  : %.3f s -> payload %6.2f Mbps / wire %6.2f Mbps, %.0f fps%s\n",
                   sw, us.tx_pay_bytes * 8.0 / sw / 1e6,
                   us.tx_wire_bytes * 8.0 / sw / 1e6, us.tx_frames / sw,
                   cfg.rate_mbps > 0 ? " [限速]" : "");
        }
        if (el > 0)
            printf("TX rate      : %.2f Mbps (%6.2f MB/s) payload, %.0f fps (整个运行期)\n",
                   us.tx_pay_bytes * 8.0 / el / 1e6, us.tx_pay_bytes / el / 1e6,
                   us.tx_frames / el);
        printf("RX           : frames=%llu payload=%llu B (rejected=%llu junk=%llu bad_ipcsum=%llu zero_pay=%llu)\n",
               (unsigned long long)us.rx_frames, (unsigned long long)us.rx_pay_bytes,
               (unsigned long long)us.rx_rejected, (unsigned long long)us.rx_junk,
               (unsigned long long)us.rx_bad_ipcsum, (unsigned long long)us.rx_zero_pay);
        if (dsp > 0)
            printf("RX rate      : %.2f Mbps (%6.2f MB/s) payload [数据窗口]\n",
                   rx_mbps, rx_mbps / 8.0);
        printf("pattern      : verified=%llu mismatch=%llu",
               (unsigned long long)chk.verified, (unsigned long long)chk.mismatch);
        if (chk.have_bad)
            printf("  (first bad at offset %llu: got %02X want %02X)",
                   (unsigned long long)chk.first_bad_off, chk.first_bad_got, chk.first_bad_exp);
        printf("\n");
        if (chk.have_bad && chk.dbg_n > 0) {
            printf("  首失配处 24 字节对照 (got) : ");
            for (int j = 0; j < chk.dbg_n; j++) printf("%02X ", chk.dbg_got[j]);
            printf("\n  期望图案 (want)            : ");
            for (int j = 0; j < chk.dbg_n; j++) printf("%02X ", chk.dbg_want[j]);
            printf("\n");
            /* 截断特征: 首失配恰在载荷偏移 996 且值为 0x00 = 板侧 HLS echo 的
             * TX 载荷区上限 (TX_UDP 1024B - 28B 头), 不是本工具的构造问题 */
            if (chk.first_bad_off == 996 && chk.first_bad_got == 0x00)
                printf("  诊断        : 回包自载荷偏移 996 起为 0x00 —— 这是当前 HLS 慢\n"
                       "                路径 echo 的 TX 载荷区上限; 用 --udp-paylen <= 996\n"
                       "                复测 (P5e app 通路无此限制)。\n");
        }
        printf("resync       : holes=%llu bytes=%llu subst_events=%llu (searches=%llu ok=%llu)\n",
               (unsigned long long)chk.holes, (unsigned long long)chk.hole_bytes,
               (unsigned long long)chk.subst_events,
               (unsigned long long)chk.searches, (unsigned long long)chk.searches_ok);
        if (us.tx_frames)
            printf("frame loss   : tx=%llu rx=%llu -> missing=%llu (%.3f%%)\n",
                   (unsigned long long)us.tx_frames, (unsigned long long)us.rx_frames,
                   (unsigned long long)missing,
                   100.0 * (double)missing / (double)us.tx_frames);
        /* 板级经验 (2026-09-20 实测, paylen=996/66 帧): 当前位流 UDP 走 HLS 慢
         * 路径 echo —— >=30 Mbps 丢 ~2/3 帧 (20/25 Mbps 全收); 1~2 Mbps 偶发帧尾
         * 若干字节被改写。这两条只影响"当前位流的验收", P5e app 通路另说。 */
        if (cfg.udp_send && missing && 100.0 * (double)missing / (double)us.tx_frames > 5.0)
            printf("  诊断        : 板侧丢帧 —— 当前位流的 UDP 走 HLS 慢路径 echo, 实测\n"
                   "                >=30 Mbps 丢 ~2/3 帧 (20/25 Mbps 全收)。降 --rate-mbps\n"
                   "                到 <=20 复测; P5e app 通路 (rtl/udp_rx.v) 无此瓶颈。\n");
        if (cfg.udp_send && chk.mismatch && chk.mismatch <= 4096 && !chk.holes)
            printf("  诊断        : 失配集中在帧尾少量字节 (相位未脱开) —— HLS 慢路径 echo\n"
                   "                的时序相关帧尾 hazard, 与发送速率相关 (实测 20/10/5 Mbps\n"
                   "                65536 B 逐字节干净)。先换 --rate-mbps 复测再判设计缺陷。\n");
        if (el > 0) {
            printf("I/O cost     : TX %llu calls %.2f us/call | RX %llu calls %.2f us/call\n",
                   (unsigned long long)us.tx_calls,
                   us.tx_calls ? us.tx_time_us / (double)us.tx_calls : 0.0,
                   (unsigned long long)us.rx_calls,
                   us.rx_calls ? us.rx_time_us / (double)us.rx_calls : 0.0);
            FILETIME c, e2, k, u;
            if (GetProcessTimes(GetCurrentProcess(), &c, &e2, &k, &u)) {
                auto ft2s = [](const FILETIME &f) {
                    return ((double)f.dwHighDateTime * 4294967296.0 +
                            (double)f.dwLowDateTime) / 1e7;
                };
                us.cpu_user_s = ft2s(u);
                us.cpu_sys_s  = ft2s(k);
                printf("CPU          : user %.3f s sys %.3f s over %.3f s => %.2f cores\n",
                       us.cpu_user_s, us.cpu_sys_s, el,
                       (us.cpu_user_s + us.cpu_sys_s) / el);
            }
            us.h_ia.print("  h: rx inter-arrival");
        }
        printf("============================================\n");
        fflush(stdout);
    }

    /* 判据: 发送模式 —— 回包(若有)逐字节一致且无失配; 收模式 —— 图案零失配。
     * 板侧 app RX 不 echo 时发送模式退化为 TX-only (明确标注, 不判 FAIL)。 */
    bool verdict(bool rx_mode, bool echo_seen) const {
        if (aborted) return false;
        if (chk.mismatch) return false;
        if (rx_mode) return us.rx_pay_bytes > 0;
        if (cfg.udp_bytes && echo_seen) return us.rx_pay_bytes >= (uint64_t)cfg.udp_bytes;
        return true;                                  /* TX-only: 只看发送侧 */
    }
};

/* =====================================================================
 * 6. CLI
 * ===================================================================== */

static void usage(void) {
    printf(
"peer.exe -- synthetic TCP peer for board echo testing (prototype)\n"
"\n"
"Usage: peer.exe --iface <NPF path> [options]\n"
"       peer.exe --iface-idx <n> [options]     (n from `peer.exe --list`)\n"
"       peer.exe --list                        list capture devices\n"
"\n"
"Addressing:\n"
"  --src-ip <a.b.c.d>   local IP            (default 192.168.100.1)\n"
"  --dst-ip <a.b.c.d>   board IP            (default 192.168.100.2)\n"
"  --sport <n>          local TCP port      (default 40000)\n"
"  --dport <n>          board TCP port      (default 8080)\n"
"  --src-mac <xx:..>    local MAC           (default 02:00:00:00:00:01)\n"
"  --dst-mac <xx:..>    board MAC           (default 00:0a:35:01:fe:c0)\n"
"\n"
"Traffic:\n"
"  --bytes <n>          payload bytes to send and echo-verify (default 1048576)\n"
"  --rx-only            send NO application data; verify the stream the board\n"
"                       generates (rtl/app_pattern) against the RTL pattern and\n"
"                       report verified/mismatch/holes/throughput\n"
"  --expect-pattern <n> = --rx-only with a byte target (0/unset = until FIN)\n"
"                       (alias --rx-bytes)\n"
"  --pat-selftest       print+verify the pattern convention (no board needed)\n"
"\n"
"UDP mode (P5e; no connection state: no handshake/ACK/retransmit/window):\n"
"  --udp                switch to UDP (bare form = --udp-send-pattern <--bytes>)\n"
"  --udp-send-pattern <n>  send n bytes of the RTL pattern, framed at --udp-paylen;\n"
"                       if the board echoes them back (current HLS slow path),\n"
"                       the echo is verified byte-for-byte against the same stream\n"
"                       (alias --udp-tx; target = --bytes when n omitted)\n"
"  --udp-rx-only [<n>]  receive + verify the board's pattern stream against the RTL\n"
"                       pattern from offset 0 (n optional; 0/absent = until stall)\n"
"  --udp-paylen <n>     UDP payload bytes per frame (1..1472; default 1472 = MTU 1514-42)\n"
"  --rate-mbps <n>      TX pacing on WIRE bytes (default 50; 0 = unlimited); the\n"
"                       payload rate is ~97%% of it (42 B header per 1514 B frame)\n"
"                       REQUIRED in practice: the board app RX consumes byte-serially\n"
"                       (~15.6 MB/s), line-rate injection would overrun it\n"
"  --udp-csum <0|1>     compute the UDP checksum (default 1 = RFC 768; 0 = zero field,\n"
"                       which is what the board's own echo frames carry)\n"
"  --udp-spin <0|1>     sub-ms spin for smooth pacing (default 1; 0 = 1 ms sleeps)\n"
"  --udp-resync <n>     lost-frame resync search horizon in bytes (default 65536,\n"
"                       0 = off): UDP has no sequence numbers, a hole is found by\n"
"                       re-phasing the pattern LFSR (16-byte confirmation)\n"
"  --udp-any-port       accept any ports on RX (default: strict peer_port<->our_port,\n"
"                       which filters out the board's periodic HELLO 8080->8080)\n"
"  --udp-no-echo        do not wait for / verify an echo (pure TX direction)\n"
"  --udp-selftest       build->parse->pattern closed loop, no board needed\n"
"  --mss <n>            segment size        (default 1460)\n"
"  --rcv-wnd <n>        window we advertise in our segments (default 65535)\n"
"                       (alias --rx-window; headroom: board ring is 64 KiB/conn)\n"
"  --cwnd <bytes>       fixed cwnd; 0 = slow start from 10*MSS (default 0)\n"
"\n"
"ACK strategy:\n"
"  --ack-mode <m>       immediate | everyN | delayed   (default immediate)\n"
"  --ack-n <n>          ACK once per N received segments (everyN; default 2)\n"
"                       (alias --ack-every)\n"
"  --ack-delay-us <n>   for delayed mode    (default 100)\n"
"\n"
"Rate test / diagnostics:\n"
"  --rate-test          1 GB-scale run: per-interval log + 10-90%% steady state\n"
"  --stats-interval-ms  1 s log cadence (default 1000; 0 to disable)\n"
"  --quiet              same as --stats-interval-ms 0\n"
"  --no-fast-retx       disable fast retransmit (RTO only)\n"
"\n"
"Timers / control:\n"
"  --rto-ms <n>         minimum RTO        (default 200)\n"
"  --stall-ms <n>       give up after no progress this long (default 2000)\n"
"  --seed <n>           force ISN seed     (default from clock)\n"
"  --syn-opts <m>       none | mss | full  (default full)\n"
"  --no-fin             skip FIN teardown\n"
"  --verbose            per-segment trace\n"
"\n"
"Full example (Killer E5000B on this host):\n"
"  peer.exe --iface \"\\Device\\NPF_{528A3E8C-9A80-4D17-96A0-48F3FD70186E}\" \\\n"
"           --src-mac FC:9D:05:7D:88:6B --rate-test --bytes 1073741824\n"
    );
}

/* Raw send-capability self-test: blast frame_len-byte frames back to back with
 * no TCP logic at all.  This is the number that says whether the PEER can keep
 * up -- the payload uses ethertype 0x88B5 (Local Experimental) so the board's
 * IP/TCP path never engages. */
static int tx_bench(pcap_t *p, uint32_t frames, int frame_len) {
    struct pcap_send_queue *q = pcap_sendqueue_alloc(4u * 1024u * 1024u);
    if (!q) { fprintf(stderr, "tx-bench: pcap_sendqueue_alloc failed\n"); return 1; }

    std::vector<uint8_t> f((size_t)frame_len, 0xA5);
    memcpy(f.data(), cfg.dst_mac, 6);
    memcpy(f.data() + 6, cfg.src_mac, 6);
    f[12] = 0x88; f[13] = 0xB5;

    struct pcap_pkthdr h;
    h.ts.tv_sec = 0; h.ts.tv_usec = 0;
    h.caplen = h.len = (unsigned int)frame_len;

    printf("=== TX capability self-test: %u frames of %d bytes ===\n", frames, frame_len);
    uint64_t t0 = now_ticks();
    uint32_t sent = 0;
    uint64_t calls = 0;
    while (sent < frames) {
        if (pcap_sendqueue_queue(q, &h, f.data()) != 0) {
            pcap_sendqueue_transmit(p, q, cfg.tx_sync);
            q->len = 0; calls++;
            continue;
        }
        sent++;
    }
    pcap_sendqueue_transmit(p, q, cfg.tx_sync);
    q->len = 0; calls++;
    double us = ticks_to_us(now_ticks() - t0);
    pcap_sendqueue_destroy(q);

    double sec = us / 1e6;
    double bytes = (double)sent * (double)frame_len * 8.0;
    printf("frames      : %u in %.3f s\n", sent, sec);
    printf("rate        : %.0f fps\n", sent / sec);
    printf("bandwidth   : %.1f Mbps (%.1f MB/s) at %d B/frame\n",
           bytes / sec / 1e6, (double)sent * frame_len / sec / 1e6, frame_len);
    printf("transmit    : %llu calls, %.2f us/call, %.1f frames/call\n",
           (unsigned long long)calls, us / (double)calls,
           (double)sent / (double)calls);
    return 0;
}

/* Pattern-convention self-test: no board needed.  Prints the first bytes and
 * compares them against the values the RTL generator produces (independently
 * recomputed here from the spec in the header comment). */
static int pat_selftest(void) {
    /* Independently derived from the spec (take s[31:24], then xorshift) and
     * cross-checked against rtl/app_pattern.v behaviour + gen_stim_p5_app.py */
    static const uint8_t exp[16] = {
        0x7F, 0x0B, 0x02, 0xE5, 0x36, 0xA1, 0x4E, 0xD6,
        0x1A, 0xB0, 0x49, 0xB8, 0x56, 0xAD, 0xD6, 0x3F };
    printf("=== pattern self-test (RTL convention) ===\n");
    printf("seed        : 0x%016llX\n", (unsigned long long)RPAT_SEED);
    printf("first 16 RTL: ");
    uint64_t s = RPAT_SEED;
    int bad = 0;
    for (int i = 0; i < 16; i++) {
        uint8_t b = (uint8_t)(s >> 24);
        printf("%02X ", b);
        if (b != exp[i]) bad++;
        s ^= s << 13; s ^= s >> 7; s ^= s << 17;
    }
    printf("\nfirst 16 tbl: ");
    for (int i = 0; i < 16; i++) printf("%02X ", g_pat[i]);
    printf("\n");
    for (int i = 0; i < 16; i++)
        if (g_pat[i] != exp[i]) bad++;
    printf("hard truth  : %s\n", bad ? "MISMATCH" : "OK (matches rtl/app_pattern.v)");
    return bad ? 1 : 0;
}

/* rx-only verifier self-test (no board): feed the checker a synthetic stream
 * and prove it (a) accepts the RTL pattern, (b) rejects the old off-by-one
 * table, (c) accounts a gap as holes without cascading mismatches. */
static int selftest_rx(void) {
    const int N = 70000;                 /* > 64 KiB so periodicity cannot hide */
    std::vector<uint8_t> good((size_t)N);
    uint64_t s = RPAT_SEED;
    for (int i = 0; i < N; i++) {
        good[i] = (uint8_t)(s >> 24);
        s = xs_next64(s);
    }
    int bad = 0;
    /* (a) RTL stream must verify clean */
    RxPatChecker a;
    a.check(good.data(), N);
    printf("[rx-selftest] RTL stream      : verified=%llu mismatch=%llu -> %s\n",
           (unsigned long long)a.verified, (unsigned long long)a.mismatch,
           (a.mismatch == 0 && a.verified == (uint64_t)N) ? "OK" : "FAIL");
    if (a.mismatch || a.verified != (uint64_t)N) bad++;
    /* (b) the pre-fix convention (advance-then-take) must be rejected */
    RxPatChecker b;
    b.check(good.data() + 1, N - 1);
    printf("[rx-selftest] off-by-one table: verified=%llu mismatch=%llu -> %s\n",
           (unsigned long long)b.verified, (unsigned long long)b.mismatch,
           (b.mismatch > (uint64_t)(N / 2)) ? "OK (rejected)" : "FAIL (not detected)");
    if (b.mismatch < (uint64_t)(N / 2)) bad++;
    /* (c) gap accounting: skip 100 bytes and continue */
    RxPatChecker c;
    c.check(good.data(), 1000);
    c.gap(100);
    c.check(good.data() + 1100, 1000);
    bool okc = (c.mismatch == 0 && c.verified == 2000 && c.holes == 1 &&
                c.hole_bytes == 100 && c.pos == 2100);
    printf("[rx-selftest] gap resync      : verified=%llu mismatch=%llu holes=%llu/%llu -> %s\n",
           (unsigned long long)c.verified, (unsigned long long)c.mismatch,
           (unsigned long long)c.holes, (unsigned long long)c.hole_bytes,
           okc ? "OK" : "FAIL");
    if (!okc) bad++;
    printf("[rx-selftest] %s\n", bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}

/* UDP 无板自检: 构造 -> 解析 -> 图案校验 闭环 (--udp-selftest)。
 * 覆盖: 帧构造字段/最小帧/校验和、解析与接受判定(镜像板侧门)、图案流逐字节、
 * 失配与丢帧重同步, 以及 5 类负对照。全部不碰板子、不碰网卡。 */
static int udp_selftest(void) {
    int bad = 0;
    printf("=== UDP self-test (无板: 构造->解析->图案校验 闭环) ===\n");
    printf("pattern seed: 0x%016llX (xorshift64, 先取 s[31:24] 再推进)\n",
           (unsigned long long)RPAT_SEED);

    UdpFlow fl;
    memset(&fl, 0, sizeof(fl));
    memcpy(fl.our_mac, cfg.src_mac, 6);
    memcpy(fl.peer_mac, cfg.dst_mac, 6);
    fl.our_ip = cfg.src_ip;
    fl.peer_ip = cfg.dst_ip;
    fl.our_port = cfg.sport;
    fl.peer_port = cfg.dport;
    fl.csum_en = true;
    UdpFlow rb = udp_flow_reverse(fl);      /* 板侧 -> 本端 (自检的"收到的帧") */

    /* [1] 图案约定: RTL 期望前 16 字节 == LFSR 行走 == 64 KiB 查表 */
    {
        static const uint8_t exp[16] = {
            0x7F, 0x0B, 0x02, 0xE5, 0x36, 0xA1, 0x4E, 0xD6,
            0x1A, 0xB0, 0x49, 0xB8, 0x56, 0xAD, 0xD6, 0x3F };
        uint64_t s = RPAT_SEED;
        int e1 = 0, e2 = 0;
        for (int i = 0; i < 16; i++) {
            if ((uint8_t)(s >> 24) != exp[i]) e1++;
            if (g_pat[i] != exp[i]) e2++;
            s = xs_next64(s);
        }
        printf("[1] 图案约定      : LFSR %s / 64KiB 查表 %s (前 16 字节 vs rtl/app_pattern.v)\n",
               e1 ? "MISMATCH" : "OK", e2 ? "MISMATCH" : "OK");
        if (e1 || e2) bad++;
    }
    /* [1b] 查表 == LFSR 前 64 KiB: 两套发生器同一约定 ⇒ 前 64 KiB UDP 路径可互换 */
    {
        uint64_t s = RPAT_SEED;
        int diff = 0;
        for (int i = 0; i < PAY_PAT_LEN; i++) {
            if (g_pat[i] != (uint8_t)(s >> 24)) diff++;
            s = xs_next64(s);
        }
        printf("[1b] 表 vs LFSR   : 前 65536 字节有 %d 处不同 -> %s\n", diff, diff ? "FAIL" : "OK");
        if (diff) bad++;
    }

    /* [2] 帧构造 -> 解析 字段回环 (扫载荷长度; 板侧 HLS echo 照抄 ip.totlen/udp_len,
     *     所以"长度字段自洽"是被板子验证过的硬要求) */
    {
        static const int lens[] = {0, 1, 2, 6, 7, 17, 18, 42, 43, 100, 101, 1471, 1472};
        const int n = (int)(sizeof(lens) / sizeof(lens[0]));
        int fail = 0;
        uint8_t buf[2048], payload[2048];
        for (int i = 0; i < n; i++) {
            int plen = lens[i];
            uint32_t off = (uint32_t)(i * 1000);
            for (int j = 0; j < plen; j++) payload[j] = pay_byte(off + (uint32_t)j);
            int flen = udp_build(buf, rb, off, plen);
            int expf = ETH_HDR_LEN + 20 + 8 + plen;
            if (expf < ETH_MIN_FRAME) expf = ETH_MIN_FRAME;
            UdpPkt p;
            if (flen != expf) { fail++; continue; }
            if (!udp_parse(buf, flen, &p)) { fail++; continue; }
            bool ok = (p.sport == rb.our_port && p.dport == rb.peer_port &&
                       p.src_ip == rb.our_ip && p.dst_ip == rb.peer_ip &&
                       p.udp_len == (uint16_t)(8 + plen) && p.plen == plen &&
                       p.ip_csum_ok && p.udp_len_ok && p.ihl5 &&
                       udp_accept(p, fl, true));
            if (ok && plen) ok = (memcmp(p.pay, payload, (size_t)plen) == 0);
            if (!ok) {
                printf("      (len=%d 回环不符: flen=%d/%d udp_len=%u plen=%d csum_ok=%d acc=%d)\n",
                       plen, flen, expf, p.udp_len, p.plen, (int)p.ip_csum_ok,
                       (int)udp_accept(p, fl, true));
                fail++;
            }
        }
        printf("[2] 帧<->解析回环: %d 个载荷长度 (0..1472, 含奇数/最小帧边界) -> %s\n",
               n, fail ? "FAIL" : "OK");
        if (fail) bad++;
    }

    /* [3] 完整闭环: 16 帧图案流 构造 -> 解析 -> 校验器逐字节 */
    const int PAY = 1472, NFR = 16;
    std::vector<uint8_t> rx_stream;
    {
        RtlPatGen g;
        UdpStreamChecker ck;
        uint8_t buf[2048], payload[2048];
        int frames_ok = 0;
        for (int f = 0; f < NFR; f++) {
            uint32_t off = (uint32_t)g.pos;
            g.fill(payload, PAY);
            int flen = udp_build(buf, rb, off, PAY, payload);
            UdpPkt p;
            if (!udp_parse(buf, flen, &p) || !udp_accept(p, fl, true)) break;
            rx_stream.insert(rx_stream.end(), p.pay, p.pay + p.plen);
            frames_ok++;
        }
        ck.check(rx_stream.data(), (int)rx_stream.size(), 65536);
        bool ok = (frames_ok == NFR && ck.verified == rx_stream.size() &&
                   ck.mismatch == 0 && ck.holes == 0);
        printf("[3] 闭环 16x1472B  : 帧 %d/%d verified=%llu mismatch=%llu holes=%llu -> %s\n",
               frames_ok, NFR, (unsigned long long)ck.verified,
               (unsigned long long)ck.mismatch, (unsigned long long)ck.holes,
               ok ? "OK" : "FAIL");
        if (!ok) bad++;
    }

    /* [4] 负对照: 翻转 1 字节 -> 必须恰好 1 个失配, 且位置正确 (kmax=0: 不重同步) */
    if (rx_stream.size() != (size_t)NFR * PAY) {
        printf("[4]/[5] 负对照   : 闭环数据不完整 (%llu B), 跳过 -> FAIL\n",
               (unsigned long long)rx_stream.size());
        bad++;
    } else {
    {
        UdpStreamChecker ck;
        std::vector<uint8_t> s2 = rx_stream;
        s2[1000] ^= 0xFF;
        ck.check(s2.data(), (int)s2.size(), 0);
        bool ok = (ck.mismatch == 1 && ck.verified == s2.size() - 1 &&
                   ck.have_bad && ck.first_bad_off == 1000);
        printf("[4] 负对照 改1字节 : mismatch=%llu (first at %llu) verified=%llu -> %s\n",
               (unsigned long long)ck.mismatch, (unsigned long long)ck.first_bad_off,
               (unsigned long long)ck.verified, ok ? "OK (检出)" : "FAIL");
        if (!ok) bad++;
    }
    /* [4b] 相位内替换 (kmax 开着也不能把 1 个坏字节当成"丢了 1 字节"):
     *      这是板级最常见的形态 (帧尾若干字节被改写), 报错必须只算那几字节 */
    {
        UdpStreamChecker ck;
        std::vector<uint8_t> s2 = rx_stream;
        for (int j = 989; j <= 995; j++) s2[PAY + j] ^= 0xA5;   /* 第 2 帧尾 7 字节 */
        ck.check(s2.data(), (int)s2.size(), 65536);
        bool ok = (ck.mismatch == 7 && ck.holes == 0 && ck.subst_events >= 1 &&
                   ck.verified == s2.size() - 7);
        printf("[4b] 负对照 替换7字节: mismatch=%llu holes=%llu subst=%llu verified=%llu -> %s\n",
               (unsigned long long)ck.mismatch, (unsigned long long)ck.holes,
               (unsigned long long)ck.subst_events, (unsigned long long)ck.verified,
               ok ? "OK (不脱相)" : "FAIL");
        if (!ok) bad++;
    }

    /* [4c] 窗口末尾的坏字节: 剩余不足 W 时必须**禁止**重同步 —— 否则拿 1 字节去
     *      撞 64K 个候选几乎必然撞上 ⇒ 相位凭空跳走 ⇒ 假失配洪水 (实测把帧尾
     *      1 个坏字节报成 992 个失配, 这是板级最常见的形态)。 */
    {
        UdpStreamChecker ck;
        std::vector<uint8_t> s2(rx_stream.begin(), rx_stream.begin() + PAY);
        s2[PAY - 1] ^= 0x5A;
        ck.check(s2.data(), PAY, 65536);
        bool ok = (ck.mismatch == 1 && ck.holes == 0 && ck.searches == 0 &&
                   ck.verified == (uint64_t)PAY - 1);
        printf("[4c] 负对照 末字节坏: mismatch=%llu holes=%llu searches=%llu -> %s\n",
               (unsigned long long)ck.mismatch, (unsigned long long)ck.holes,
               (unsigned long long)ck.searches, ok ? "OK (不误重同步)" : "FAIL");
        if (!ok) bad++;
    }

    /* [5] 负对照: 丢 1 整帧 -> 重同步找 k=1472, 记 1 个 hole, 后续零失配 */
    {
        UdpStreamChecker ck;
        std::vector<uint8_t> s2;
        s2.insert(s2.end(), rx_stream.begin(), rx_stream.begin() + PAY);
        s2.insert(s2.end(), rx_stream.begin() + 2 * PAY, rx_stream.end());
        ck.check(s2.data(), (int)s2.size(), 65536);
        bool ok = (ck.mismatch == 0 && ck.holes == 1 &&
                   ck.hole_bytes == (uint64_t)PAY && ck.searches_ok == 1 &&
                   ck.verified == rx_stream.size() - PAY);
        printf("[5] 负对照 丢1帧   : holes=%llu bytes=%llu verified=%llu mismatch=%llu -> %s\n",
               (unsigned long long)ck.holes, (unsigned long long)ck.hole_bytes,
               (unsigned long long)ck.verified, (unsigned long long)ck.mismatch,
               ok ? "OK (重同步)" : "FAIL");
        if (!ok) bad++;
    }
    }

    /* [6] 负对照: 坏 IP 校验和 / 错端口 / udp_len<8 / 非 UDP —— 接受判定必须拒绝 */
    {
        uint8_t buf[2048];
        int flen = udp_build(buf, rb, 0, 100);
        UdpPkt p;
        int fail = 0;
        int ioff = ETH_HDR_LEN, uoff = ETH_HDR_LEN + 20;
        uint8_t sv[4];
        /* (a) 砸 IP 校验和 */
        sv[0] = buf[ioff + 10]; buf[ioff + 10] ^= 0x01;
        if (!udp_parse(buf, flen, &p)) fail++;
        else if (p.ip_csum_ok || udp_accept(p, fl, true)) fail++;
        buf[ioff + 10] = sv[0];
        /* (b) dst 端口改成 0x1234 (板侧 echo 的严格配对必须挡掉) */
        sv[0] = buf[uoff + 2]; sv[1] = buf[uoff + 3];
        buf[uoff + 2] = 0x12; buf[uoff + 3] = 0x34;
        if (!udp_parse(buf, flen, &p)) fail++;
        else if (udp_accept(p, fl, true)) fail++;        /* 严格: 拒 */
        else if (!udp_accept(p, fl, false)) fail++;      /* --udp-any-port: 收 */
        buf[uoff + 2] = sv[0]; buf[uoff + 3] = sv[1];
        /* (c) 目的 IP 改掉 */
        sv[0] = buf[ioff + 19]; buf[ioff + 19] ^= 0x01;
        if (!udp_parse(buf, flen, &p)) fail++;
        else if (udp_accept(p, fl, false)) fail++;
        buf[ioff + 19] = sv[0];
        /* (d) udp_len = 7 (<8, rtl/udp_rx.v:135 会丢) */
        sv[0] = buf[uoff + 4]; sv[1] = buf[uoff + 5];
        buf[uoff + 4] = 0x00; buf[uoff + 5] = 0x07;
        if (!udp_parse(buf, flen, &p)) fail++;
        else if (p.udp_len_ok || udp_accept(p, fl, true)) fail++;
        buf[uoff + 4] = sv[0]; buf[uoff + 5] = sv[1];
        /* (e) proto 改成 6 (TCP) -> 根本不是 UDP */
        sv[0] = buf[ioff + 9]; buf[ioff + 9] = 6;
        if (udp_parse(buf, flen, &p)) fail++;
        buf[ioff + 9] = sv[0];
        /* (f) 恢复后必须重新接受 (确认以上都是"改动"造成的, 不是构造本身坏) */
        if (!udp_parse(buf, flen, &p) || !udp_accept(p, fl, true)) fail++;
        printf("[6] 负对照 过滤门  : 坏IPcsum/错端口/错IP/udp_len<8/非UDP 全部拒绝, 复原后接受 -> %s\n",
               fail ? "FAIL" : "OK");
        if (fail) bad++;
    }

    /* [7] UDP 校验和独立验算: 伪头 + UDP 头(含 csum 字段) + 载荷 折叠必须为 0 */
    {
        static const int lens[] = {101, 1472};
        int fail = 0;
        uint8_t buf[2048];
        for (int i = 0; i < 2; i++) {
            int plen = lens[i];
            udp_build(buf, fl, 0, plen);            /* csum_en = true (发送方向) */
            int ulen = 8 + plen;
            uint32_t sum = csum_acc(0, buf + ETH_HDR_LEN + 12, 8);   /* src_ip + dst_ip */
            uint8_t tail[4] = {0, IP_PROTO_UDP, (uint8_t)(ulen >> 8), (uint8_t)(ulen & 0xFF)};
            sum = csum_acc(sum, tail, 4);
            sum = csum_acc(sum, buf + ETH_HDR_LEN + 20, ulen);       /* UDP 头 + 载荷 */
            if (csum_fold(sum) != 0) fail++;
        }
        /* csum_en=false 时字段必须恰好为 0 (板侧回包就是这个形态) */
        UdpFlow f0 = fl; f0.csum_en = false;
        udp_build(buf, f0, 0, 100);
        if (buf[ETH_HDR_LEN + 20 + 6] != 0 || buf[ETH_HDR_LEN + 20 + 7] != 0) fail++;
        printf("[7] UDP 校验和    : 独立验算(伪头+头+载荷折叠==0) 2 例 + 置零态 -> %s\n",
               fail ? "FAIL" : "OK");
        if (fail) bad++;
    }

    printf("UDP SELF-TEST VERDICT: %s\n", bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}

static void list_devices(void) {
    pcap_if_t *devs = 0;
    char err[256] = {0};
    if (pcap_findalldevs(&devs, err) != 0) {
        fprintf(stderr, "pcap_findalldevs: %s\n", err);
        return;
    }
    int i = 1;
    for (pcap_if_t *d = devs; d; d = d->next) {
        printf("%d. %s (%s)\n", i++, d->name,
               d->description ? d->description : "no description");
    }
    pcap_freealldevs(devs);
}

static bool parse_mac(const char *s, uint8_t *out) {
    unsigned v[6];
    if (sscanf(s, "%x:%x:%x:%x:%x:%x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6)
        return false;
    for (int i = 0; i < 6; i++) out[i] = (uint8_t)v[i];
    return true;
}

static bool parse_ip(const char *s, uint32_t *out) {
    unsigned a, b, c, d;
    if (sscanf(s, "%u.%u.%u.%u", &a, &b, &c, &d) != 4) return false;
    if (a > 255 || b > 255 || c > 255 || d > 255) return false;
    *out = (a << 24) | (b << 16) | (c << 8) | d;
    return true;
}

static const char *need_arg(int argc, char **argv, int &i) {
    if (i + 1 >= argc) {
        fprintf(stderr, "error: %s needs a value\n", argv[i]);
        exit(2);
    }
    return argv[++i];
}

/* ---- UDP 顶层驱动 (main 的 --udp 分支): BPF 过滤 + 跑 + 报告 ---- */
static int udp_main(pcap_t *p) {
    /* 收方向过滤下推到驱动 (与 TCP 版同理: 无关帧不拷到用户态)。
     * 只按 UDP + 双向 host 过滤; 端口是否严格由 --udp-any-port 决定
     * (严格 = 板侧 echo 的 src 8080 -> dst 本端端口, 顺带挡掉板侧周期 HELLO)。 */
    if (cfg.use_filter) {
        char flt[320];
        snprintf(flt, sizeof(flt),
                 "udp and src host %u.%u.%u.%u%s%d%s%d and dst host %u.%u.%u.%u",
                 (cfg.dst_ip >> 24) & 255, (cfg.dst_ip >> 16) & 255,
                 (cfg.dst_ip >> 8) & 255, cfg.dst_ip & 255,
                 cfg.udp_strict_ports ? " and src port " : "",
                 cfg.udp_strict_ports ? (int)cfg.dport : 0,
                 cfg.udp_strict_ports ? " and dst port " : "",
                 cfg.udp_strict_ports ? (int)cfg.sport : 0,
                 (cfg.src_ip >> 24) & 255, (cfg.src_ip >> 16) & 255,
                 (cfg.src_ip >> 8) & 255, cfg.src_ip & 255);
        struct bpf_program fp;
        if (pcap_compile(p, &fp, flt, 1, 0) == 0) {
            if (pcap_setfilter(p, &fp) != 0)
                fprintf(stderr, "note: pcap_setfilter failed: %s\n", pcap_geterr(p));
            else
                printf("capture filter: %s\n", flt);
            pcap_freecode(&fp);
        } else {
            fprintf(stderr, "note: pcap_compile(%s) failed: %s\n", flt, pcap_geterr(p));
        }
    }

    UdpPeer up;
    up.init(p);
    up.start_rx();

    printf("=== synthetic UDP peer (P5e) ===%s\n",
           cfg.udp_rx_only ? " [UDP RX-ONLY]" : " [UDP TX pattern]");
    printf("iface %s\n", cfg.iface.c_str());
    printf("udp payload %d B/frame, csum=%s, rate-limit=%s, resync horizon=%d B\n",
           cfg.udp_paylen, cfg.udp_csum ? "RFC768" : "zero",
           cfg.rate_mbps > 0 ? "on" : "OFF", cfg.udp_resync);
    /* 板侧已知上限提示 (2026-09-20 实测): 当前位流的 UDP 由 HLS 慢路径 echo
     * (rx_classify -> slow -> hls udp_echo), 其回包载荷区 = TX_UDP_BASE 起
     * 1024 B - 28 B 头 = 996 B; 超过则回包在载荷偏移 996 处截断成 0x00
     * (hls/src/eth_types.h TX_UDP_SIZE + udp_echo.cpp:200 的载荷拷贝)。 */
    if (!cfg.udp_rx_only && cfg.udp_paylen > 996)
        printf("[!!] 提示: --udp-paylen %d > 996 —— 当前 (P4/P5d) 位流的 UDP 走 HLS\n"
               "     慢路径 echo, TX 载荷区只有 996 B (TX_UDP 1024B - 28B 头) ⇒ 回包会在\n"
               "     载荷偏移 996 处被截断成 0x00 (不是本工具的构造问题)。P5e app 通路\n"
               "     (rtl/udp_rx.v + app) 无此限制。要板级逐字节验证请配 --udp-paylen 996。\n",
               cfg.udp_paylen);

    int rc = 0;
    bool ok = false;
    bool echo_seen = false;
    const char *mode = "";

    if (cfg.udp_rx_only) {
        int r = up.run_rx_only();          /* 0 = 达标; 2 = stall */
        up.halt_rx();
        up.drain_rx();
        echo_seen = (us.rx_pay_bytes > 0);
        /* UDP 没有 FIN: 未给字节目标时"收到过数据后静默"就是正常收尾 */
        bool endok = (r == 0) || (r == 2 && cfg.udp_bytes == 0 && us.rx_pay_bytes > 0);
        ok = endok && up.verdict(true, echo_seen);
        mode = "rx-only (校验板侧图案流)";
        printf("rx-only 退出码: %d (%s)\n", r,
               r == 0 ? "达标" : (r == 2 ? "stall 收尾" : "abort"));
        rc = ok ? 0 : 2;
    } else {
        up.run_send();
        if (cfg.udp_echo_wait) {
            /* 等回包: 板侧 echo (现状 HLS 慢路径) 会逐字节回同样的图案;
             * P5e app RX 模式不 echo ⇒ stall 后按 TX-only 判定 */
            up.wait_echo(cfg.udp_bytes);
        }
        up.halt_rx();
        up.drain_rx();
        echo_seen = (us.rx_frames > 0);
        ok = up.verdict(false, echo_seen);
        mode = echo_seen ? "send-pattern + echo-verify" : "send-pattern (TX-only)";
        rc = ok ? 0 : 2;
    }

    up.t_end = now_ticks();
    if (us.dump) {
        fclose(us.dump);
        us.dump = 0;
        printf("dump         : %s (%llu 字节接收载荷流)\n",
               cfg.udp_dump.c_str(), (unsigned long long)us.dump_bytes);
    }
    up.report(mode);
    printf("VERDICT      : %s%s\n",
           ok ? "PASS" : "FAIL",
           (!cfg.udp_rx_only && !echo_seen)
               ? "  (板侧未 echo: 只判发送方向 —— TX-only)"
               : (ok ? "  (图案逐字节一致)" : ""));
    if (up.aborted) printf("abort reason : %s\n", up.abort_reason.c_str());
    printf("============================================\n");
    fflush(stdout);
    if (up.txq) pcap_sendqueue_destroy(up.txq);
    return rc;
}

int main(int argc, char **argv) {
    SetConsoleOutputCP(65001);
    qpc_init();

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--help" || a == "-h") { usage(); return 0; }
        else if (a == "--list") cfg.list_only = true;
        else if (a == "--iface") cfg.iface = need_arg(argc, argv, i);
        else if (a == "--iface-idx") cfg.iface_idx = atoi(need_arg(argc, argv, i));
        else if (a == "--src-mac") { if (!parse_mac(need_arg(argc, argv, i), cfg.src_mac)) { fprintf(stderr, "bad --src-mac\n"); return 2; } }
        else if (a == "--dst-mac") { if (!parse_mac(need_arg(argc, argv, i), cfg.dst_mac)) { fprintf(stderr, "bad --dst-mac\n"); return 2; } }
        else if (a == "--src-ip") { if (!parse_ip(need_arg(argc, argv, i), &cfg.src_ip)) { fprintf(stderr, "bad --src-ip\n"); return 2; } }
        else if (a == "--dst-ip") { if (!parse_ip(need_arg(argc, argv, i), &cfg.dst_ip)) { fprintf(stderr, "bad --dst-ip\n"); return 2; } }
        else if (a == "--sport") cfg.sport = (uint16_t)atoi(need_arg(argc, argv, i));
        else if (a == "--dport") cfg.dport = (uint16_t)atoi(need_arg(argc, argv, i));
        else if (a == "--bytes") cfg.bytes = (uint32_t)strtoul(need_arg(argc, argv, i), 0, 0);
        else if (a == "--mss") cfg.mss = atoi(need_arg(argc, argv, i));
        else if (a == "--rx-window" || a == "--rcv-wnd")
            cfg.rx_window = (uint16_t)atoi(need_arg(argc, argv, i));
        else if (a == "--cwnd") cfg.cwnd = (uint32_t)strtoul(need_arg(argc, argv, i), 0, 0);
        else if (a == "--ack-mode") {
            std::string m = need_arg(argc, argv, i);
            if (m == "immediate") cfg.ack_mode = ACK_IMMEDIATE;
            else if (m == "delayed") cfg.ack_mode = ACK_DELAYED;
            else if (m == "coalesce" || m == "everyN" || m == "every")
                cfg.ack_mode = ACK_COALESCE;
            else { fprintf(stderr, "bad --ack-mode\n"); return 2; }
        }
        else if (a == "--ack-delay-us") cfg.ack_delay_us = atoi(need_arg(argc, argv, i));
        else if (a == "--ack-every" || a == "--ack-n")
            cfg.ack_every = atoi(need_arg(argc, argv, i));
        else if (a == "--stats-interval-ms")
            cfg.stats_interval_ms = atoi(need_arg(argc, argv, i));
        else if (a == "--quiet") cfg.stats_interval_ms = 0;
        else if (a == "--rate-test") cfg.rate_test = true;
        else if (a == "--tx-batch") cfg.tx_batch = atoi(need_arg(argc, argv, i)) != 0;
        else if (a == "--tx-sync") cfg.tx_sync = atoi(need_arg(argc, argv, i));
        else if (a == "--tx-queue-kb") cfg.tx_queue_kb = atoi(need_arg(argc, argv, i));
        else if (a == "--setbuff-kb") cfg.setbuff_kb = atoi(need_arg(argc, argv, i));
        else if (a == "--no-mintocopy") cfg.mintocopy0 = false;
        else if (a == "--no-filter") cfg.use_filter = false;
        else if (a == "--flush-frames") cfg.flush_frames = atoi(need_arg(argc, argv, i));
        else if (a == "--rx-only") cfg.rx_only = true;
        else if (a == "--expect-pattern" || a == "--rx-bytes") {
            cfg.rx_only = true;
            cfg.expect_bytes = (uint32_t)strtoul(need_arg(argc, argv, i), 0, 0);
        }
        else if (a == "--pat-selftest") cfg.pat_selftest = true;
        else if (a == "--selftest-rx") cfg.selftest_rx = true;
        /* ---- P5e: UDP 模式 ---- */
        else if (a == "--udp") cfg.udp = true;
        else if (a == "--udp-send-pattern" || a == "--udp-tx") {
            cfg.udp = true; cfg.udp_send = true;
            cfg.udp_bytes = (uint32_t)strtoul(need_arg(argc, argv, i), 0, 0);
        }
        else if (a == "--udp-rx-only") {
            cfg.udp = true; cfg.udp_rx_only = true;
            /* 可选值: 下一个参数不是 --xxx 就当作字节目标 */
            if (i + 1 < argc && argv[i + 1][0] != '-')
                cfg.udp_bytes = (uint32_t)strtoul(argv[++i], 0, 0);
        }
        else if (a == "--udp-paylen") cfg.udp_paylen = atoi(need_arg(argc, argv, i));
        else if (a == "--rate-mbps") cfg.rate_mbps = atof(need_arg(argc, argv, i));
        else if (a == "--udp-csum") cfg.udp_csum = atoi(need_arg(argc, argv, i)) != 0;
        else if (a == "--udp-spin") cfg.udp_spin = atoi(need_arg(argc, argv, i)) != 0;
        else if (a == "--udp-resync") cfg.udp_resync = atoi(need_arg(argc, argv, i));
        else if (a == "--udp-any-port") cfg.udp_strict_ports = false;
        else if (a == "--udp-no-echo") cfg.udp_echo_wait = false;
        else if (a == "--udp-selftest") cfg.udp_selftest = true;
        else if (a == "--udp-dump") {
            cfg.udp = true;
            cfg.udp_dump = need_arg(argc, argv, i);
        }
        else if (a == "--tx-bench")
            cfg.tx_bench = (uint32_t)strtoul(need_arg(argc, argv, i), 0, 0);
        else if (a == "--no-fast-retx") cfg.fast_retx_dupacks = 0;
        else if (a == "--dupacks") cfg.fast_retx_dupacks = atoi(need_arg(argc, argv, i));
        else if (a == "--rto-ms") cfg.rto_ms = atoi(need_arg(argc, argv, i));
        else if (a == "--stall-ms") cfg.stall_ms = atoi(need_arg(argc, argv, i));
        else if (a == "--seed") cfg.seed = (uint32_t)strtoul(need_arg(argc, argv, i), 0, 0);
        else if (a == "--syn-opts") cfg.syn_opts = need_arg(argc, argv, i);
        else if (a == "--no-fin") cfg.do_fin = false;
        else if (a == "--verbose") cfg.verbose = true;
        else if (a == "--dbg-stream") cfg.dbg_stream = true;
        else if (a == "--legacy-dupack") cfg.legacy_dupack = true;
        else { fprintf(stderr, "unknown option: %s (try --help)\n", a.c_str()); return 2; }
    }

    if (cfg.list_only) { list_devices(); return 0; }

    /* --rate-test is the 1 GB-grade mode: it guarantees the periodic rate log
     * that the steady-state curve is built from. */
    if (cfg.rate_test && cfg.stats_interval_ms == 0) cfg.stats_interval_ms = 1000;

    /* ---- UDP 模式语义归一 (--udp 与 TCP 风格的选项组合) ----
     * 裸 --udp、或 --udp + --bytes 都当"发图案"; --expect-pattern/--rx-only
     * 在 UDP 下都当"只收+校验"。两者同时给 = 用法错误。 */
    if (cfg.udp) {
        if (cfg.rx_only || cfg.expect_bytes) {
            if (!cfg.udp_bytes) cfg.udp_bytes = cfg.expect_bytes;
            cfg.udp_rx_only = true;
            cfg.rx_only = false;
            cfg.expect_bytes = 0;
        }
        if (!cfg.udp_send && !cfg.udp_rx_only) cfg.udp_send = true;   /* 裸 --udp */
        if (cfg.udp_send && cfg.udp_rx_only) {
            fprintf(stderr, "error: --udp-send-pattern 与 --udp-rx-only 不能同时用\n");
            return 2;
        }
        if (cfg.udp_send && !cfg.udp_bytes) cfg.udp_bytes = cfg.bytes ? cfg.bytes : 1048576u;
        if (cfg.udp_paylen < 1 || cfg.udp_paylen > 1472) {
            /* 0 会让发送循环永远推不进 sent (死循环), 所以下限取 1 */
            fprintf(stderr, "error: --udp-paylen 必须在 1..1472 (MTU 1514 - 42 头)\n");
            return 2;
        }
    }

    pat_init();

    if (cfg.pat_selftest) return pat_selftest();
    if (cfg.selftest_rx) return selftest_rx();
    if (cfg.udp_selftest) return udp_selftest();

    char errbuf[256] = {0};
    if (cfg.iface.empty()) {
        if (!cfg.iface_idx) {
            fprintf(stderr, "error: need --iface <path> or --iface-idx <n> (see --list)\n");
            return 2;
        }
        pcap_if_t *devs = 0, *d = 0;
        if (pcap_findalldevs(&devs, errbuf) != 0) {
            fprintf(stderr, "pcap_findalldevs: %s\n", errbuf);
            return 1;
        }
        int i = 1;
        for (d = devs; d; d = d->next, i++) if (i == cfg.iface_idx) break;
        if (!d) { fprintf(stderr, "error: no device #%d\n", cfg.iface_idx); pcap_freealldevs(devs); return 2; }
        cfg.iface = d->name;
        pcap_freealldevs(devs);
    }

    pcap_t *p = pcap_open_live(cfg.iface.c_str(), 65536, 1 /*promisc*/, 100 /*ms*/, errbuf);
    if (!p) { fprintf(stderr, "pcap_open_live(%s): %s\n", cfg.iface.c_str(), errbuf); return 1; }

    /* driver-side tuning: a big receive buffer avoids drops while the reader
     * thread is scheduled out; mintocopy 0 keeps latency low. */
    if (cfg.setbuff_kb > 0 && pcap_setbuff(p, cfg.setbuff_kb * 1024) != 0)
        fprintf(stderr, "note: pcap_setbuff(%d KB) failed: %s\n",
                cfg.setbuff_kb, pcap_geterr(p));
    if (cfg.mintocopy0 && pcap_setmintocopy(p, 0) != 0)
        fprintf(stderr, "note: pcap_setmintocopy(0) failed: %s\n", pcap_geterr(p));

    if (cfg.tx_bench) {
        int rc = tx_bench(p, cfg.tx_bench, cfg.mss + 54);
        pcap_close(p);
        return rc;
    }

    /* ---- P5e: UDP 模式 (无连接, 走独立驱动) ---- */
    if (cfg.udp) {
        int rc = udp_main(p);
        pcap_close(p);
        return rc;
    }

    /* Push the 4-tuple match down into the driver: frames we do not care about
     * (including our own looped-back transmits) are never copied to user space. */
    if (cfg.use_filter) {
        char flt[192];
        snprintf(flt, sizeof(flt),
                 "tcp and src host %u.%u.%u.%u and src port %u "
                 "and dst host %u.%u.%u.%u and dst port %u",
                 (cfg.dst_ip >> 24) & 255, (cfg.dst_ip >> 16) & 255,
                 (cfg.dst_ip >> 8) & 255, cfg.dst_ip & 255, cfg.dport,
                 (cfg.src_ip >> 24) & 255, (cfg.src_ip >> 16) & 255,
                 (cfg.src_ip >> 8) & 255, cfg.src_ip & 255, cfg.sport);
        struct bpf_program fp;
        if (pcap_compile(p, &fp, flt, 1, 0) == 0) {
            if (pcap_setfilter(p, &fp) != 0)
                fprintf(stderr, "note: pcap_setfilter failed: %s\n", pcap_geterr(p));
            else
                printf("capture filter: %s\n", flt);
            pcap_freecode(&fp);
        } else {
            fprintf(stderr, "note: pcap_compile(%s) failed: %s\n", flt, pcap_geterr(p));
        }
    }

    Peer peer;
    peer.init(p);
    peer.start_rx();

    static const char *ackmode_name[] = {"immediate", "delayed", "coalesce(everyN)"};
    printf("=== synthetic TCP peer ===%s\n",
           cfg.rx_only ? " [RX-ONLY: 板侧主动发, peer 只收不发]" : "");
    printf("iface %s\n", cfg.iface.c_str());
    printf("mss=%d bytes=%u (%.3f MB) rx-window=%u cwnd=%s\n",
           cfg.mss, cfg.bytes, cfg.bytes / 1048576.0, cfg.rx_window,
           cfg.cwnd ? "fixed" : "slow-start");
    printf("tx=%s (queue %d KB, sync=%d) setbuff=%d KB mintocopy0=%d\n",
           cfg.tx_batch ? "sendqueue-batch" : "per-frame-sendpacket",
           cfg.tx_queue_kb, cfg.tx_sync, cfg.setbuff_kb, (int)cfg.mintocopy0);
    printf("ack-mode=%s", ackmode_name[(int)cfg.ack_mode]);
    if (cfg.ack_mode == ACK_COALESCE) printf(" n=%d", cfg.ack_every);
    if (cfg.ack_mode == ACK_DELAYED)  printf(" delay=%d us", cfg.ack_delay_us);
    printf(" | fast-retx after %d dup-ACKs | stats every %d ms\n",
           cfg.fast_retx_dupacks, cfg.stats_interval_ms);

    int rc = 0;
    if (!peer.connect()) {
        rc = 1;
    } else if (cfg.rx_only) {
        rc = peer.run_rx_only();
        if (rc == 0) peer.teardown();
    } else {
        rc = peer.run();
        if (rc == 0) peer.teardown();
    }

    if (rc != 0) peer.t_end = now_ticks();
    peer.halt_rx();
    peer.report();
    if (peer.txq) pcap_sendqueue_destroy(peer.txq);
    pcap_close(p);
    return rc;
}
