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
    uint64_t s = 0x9E3779B97F4A7C15ull;
    for (int i = 0; i < PAY_PAT_LEN; i++) {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17;
        g_pat[i] = (uint8_t)(s >> 24);
    }
}
static inline uint8_t pay_byte(uint32_t off) { return g_pat[off & (PAY_PAT_LEN - 1)]; }

/* Fill segbuf with the payload for stream offsets [off, off+n) */
static void pay_fill(uint8_t *dst, uint32_t off, int n) {
    for (int i = 0; i < n; i++) dst[i] = pay_byte(off + (uint32_t)i);
}

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
    uint32_t    tx_bench    = 0;        /* --tx-bench N: raw send self-test */
    uint32_t    seed        = 0;        /* 0 = derive from clock */
    int         syn_retries = 6;
};

static Config cfg;

/* =====================================================================
 * 4. Statistics
 * ===================================================================== */

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
    uint32_t fast_retx_seq = 0;      /* snd_una of the last fast retransmit */
    bool     fast_retx_done = false; /* one fast retransmit per hole */
    std::vector<Hole> holes;

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
        while (!stop_rx.load()) {
            struct pcap_pkthdr *hdr = 0;
            const unsigned char *data = 0;
            uint64_t t0 = now_ticks();
            int r = pcap_next_ex(pcap, &hdr, &data);
            st.rx_time_us += ticks_to_us(now_ticks() - t0);
            st.rx_calls++;
            if (r == 1) {
                if (!hdr || hdr->caplen < (unsigned)ETH_HDR_LEN) continue;
                RxItem it;
                it.data.assign(data, data + hdr->caplen);
                it.t_recv = now_ticks();
                st.rx_raw++;
                {
                    std::lock_guard<std::mutex> g(rx_mtx);
                    if (rx_q.size() < 200000) rx_q.push_back(std::move(it));
                }
                if (rx_evt) SetEvent(rx_evt);
            } else if (r < 0) {
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
        st.tx_time_us += ticks_to_us(now_ticks() - t0);
        st.tx_calls++;
        txq->len = 0;    /* WinPcap resets this on success; be explicit */
    }

    void send_data(uint32_t seq, int plen, bool retransmit) {
        pay_fill(segbuf, seq - (iss + 1), plen);
        emit(seq, rcv_nxt, TH_ACK | TH_PSH, segbuf, plen);
        st.tx_data_segs++;
        st.tx_data_bytes += (uint64_t)plen;
        if (!retransmit) st.tx_unique_bytes += (uint64_t)plen;
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
        {
            std::lock_guard<std::mutex> g(rx_mtx);
            if (rx_q.empty()) return;
            batch.swap(rx_q);
        }
        for (auto &it : batch) handle_frame(it.data.data(), (int)it.data.size(), it.t_recv);
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

        if (t->flags & TH_ACK) process_ack(ack, t_recv);

        if (plen > 0) {
            st.rx_data_segs++;
            st.rx_data_bytes += (uint64_t)plen;
            if (cfg.verbose)
                printf("  [rx] data seq=%u len=%d win=%u\n", seq, plen, win);
            rx_data(seq, pay, plen);
            if (ack_pending) maybe_ack();
        }
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

    /* TCP Reno fast retransmit: resend from snd_una, halve cwnd, keep snd_nxt. */
    void fast_retransmit(void) {
        if (inflight.empty()) return;
        /* Fire once per hole: without this, the peer's continued duplicate ACKs
         * for the same snd_una would retrigger forever. */
        if (fast_retx_done && snd_una == fast_retx_seq) { dup_ack_cnt = 0; return; }
        fast_retx_seq = snd_una;
        fast_retx_done = true;
        uint32_t gap = snd_nxt - snd_una;
        st.fast_retx++;
        record_hole(snd_una, gap, "fast-retx(3dup)");
        printf("[!!] %d dup-ACKs -> fast retransmit from snd_una=%u (gap %u B)\n",
               cfg.fast_retx_dupacks, snd_una, gap);
        ssthresh = std::max(cwnd / 2, (uint32_t)mss);
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

    void process_ack(uint32_t ack, uint64_t t_recv) {
        if ((int32_t)(ack - snd_una) <= 0) {          /* stale / duplicate */
            if (ack == snd_una && !inflight.empty()) {
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
        if (seq == rcv_nxt) {
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
        printf("[!!] RTO: retransmitting from snd_una=%u (cwnd %u -> 1 MSS)\n",
               snd_una, cwnd);
        st.retransmits++;
        st.rto_events++;
        record_hole(snd_una, snd_nxt - snd_una, "rto");
        ssthresh = std::max(cwnd / 2, (uint32_t)mss);
        cwnd = mss;
        snd_nxt = snd_una;
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

            maybe_ack();
            if (!tx_done) {
                send_new_data();
                check_rto();
                uint32_t allowed = std::min(cwnd, (uint32_t)snd_wnd);
                if (allowed == 0 && ticks_to_us(now_ticks() - t_last_zwin) > 100000.0) {
                    zero_window_probe();
                    t_last_zwin = now_ticks();
                }
            }
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
            if (more && !qfull) continue;

            flush_tx();                       /* one driver call for N frames */
            if (!more) WaitForSingleObject(rx_evt, 1);   /* sleep: rx or 1 ms */
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
        printf("events       : retransmits=%llu dup_acks=%llu out_of_order=%llu dup_segs=%llu zwin_probes=%llu\n",
               (unsigned long long)st.retransmits, (unsigned long long)st.dup_acks,
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
        else if (a == "--tx-bench")
            cfg.tx_bench = (uint32_t)strtoul(need_arg(argc, argv, i), 0, 0);
        else if (a == "--no-fast-retx") cfg.fast_retx_dupacks = 0;
        else if (a == "--rto-ms") cfg.rto_ms = atoi(need_arg(argc, argv, i));
        else if (a == "--stall-ms") cfg.stall_ms = atoi(need_arg(argc, argv, i));
        else if (a == "--seed") cfg.seed = (uint32_t)strtoul(need_arg(argc, argv, i), 0, 0);
        else if (a == "--syn-opts") cfg.syn_opts = need_arg(argc, argv, i);
        else if (a == "--no-fin") cfg.do_fin = false;
        else if (a == "--verbose") cfg.verbose = true;
        else { fprintf(stderr, "unknown option: %s (try --help)\n", a.c_str()); return 2; }
    }

    if (cfg.list_only) { list_devices(); return 0; }

    /* --rate-test is the 1 GB-grade mode: it guarantees the periodic rate log
     * that the steady-state curve is built from. */
    if (cfg.rate_test && cfg.stats_interval_ms == 0) cfg.stats_interval_ms = 1000;

    pat_init();

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
    printf("=== synthetic TCP peer ===\n");
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
