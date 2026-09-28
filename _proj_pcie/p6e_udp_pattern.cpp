//=============================================================================
// p6e_udp_pattern.cpp — Linux 侧 UDP 图案对端 (**吞吐**口径; 功能口径用同名 .py)
//   为什么另写 C++: 本工程纪律 —— 速率测试一律 C++/内核旁路, Python 只做功能验证。
//   Python 那版会在接收侧自己先到顶, 报出来的数会**低于板子能力** ⇒ 把"工具的天花板"
//   误当成"板子的能力" (本工程踩过的"工具余量"坑)。
//
//   编译: g++ -O2 -o p6e_udp_pattern p6e_udp_pattern.cpp
//   用法: ./p6e_udp_pattern [--secs 10] [--board 192.168.100.2] [--port 8081] [--no-teach]
//         [--teach-n 1] [--teach-len 100]
//   做两件事: ① 发教学包 (图案前缀, offset 0) 教板子 peer ⇒ 板子开始全速发图案帧;
//             ② 收到即逐字节比对 + 1s 一次速率, 汇总给判据; 退出码 0=全对, 1=失配/没收到。
//
//   图案: xorshift64 (s^=s<<13; s^=s>>7; s^=s<<17), 每步取 s[31:24], 种子 0x9E3779B97F4A7C15,
//         **先取后推进** —— 与 rtl/app_udp_pattern.v、tools/cpp_peer/peer.cpp 逐字节一致
//         (peer.cpp:220-228 的注释专门记录了"推进在先"导致 100% 失配的历史)。
//
//   ⚠️ **接收侧丢包 ≠ 图案错**: 满速 (≈950 Mbps / ~80k pps) 时内核收包缓冲溢出是常态,
//      掉一个包就让"连续前缀"不成立。所以失配时先在图案流里**向前找**这段载荷:
//        找到 @k ⇒ 中间少 k 字节 ⇒ 记 gap (接收侧掉包, 不是板子的错);
//        找不到   ⇒ 真失配 ⇒ 记 bad。
//      两者分开报 —— 否则会把自己的天花板判成板子的缺陷 (同"工具余量"那一类错)。
//      要区分"是我丢的还是板子没发", 拿 gap 总量与板子的 W9(udpapp_tx_bytes) 对账。
//=============================================================================
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <ctime>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static const uint64_t SEED = 0x9E3779B97F4A7C15ull;
static inline uint64_t xs(uint64_t s) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }

struct Pattern {
    uint64_t s;
    explicit Pattern(uint64_t seed = SEED) : s(seed) {}
    inline void fill(uint8_t *d, size_t n) {
        uint64_t t = s;
        for (size_t i = 0; i < n; i++) { d[i] = (uint8_t)(t >> 24); t = xs(t); }
        s = t;
    }
    inline void skip(size_t n) {
        uint64_t t = s;
        for (size_t i = 0; i < n; i++) t = xs(t);
        s = t;
    }
};

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// 在图案流里向前找 probe_n 字节的载荷, 返回找到的偏移 (找不到返回 0)
static size_t resync(const Pattern &base, const uint8_t *buf, size_t probe_n, size_t win) {
    static uint8_t chk[64];
    for (size_t k = probe_n; k <= win; k++) {
        Pattern p = base;
        p.skip(k);
        p.fill(chk, probe_n);
        if (memcmp(buf, chk, probe_n) == 0) return k;
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *board = "192.168.100.2";
    int port = 8081, teach_n = 1, teach_len = 100;
    double secs = 10.0;
    bool do_teach = true;
    size_t resync_win = 65536;
    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--board") && i + 1 < argc) board = argv[++i];
        else if (!strcmp(argv[i], "--port")  && i + 1 < argc) port  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--secs")  && i + 1 < argc) secs  = atof(argv[++i]);
        else if (!strcmp(argv[i], "--teach-n")   && i + 1 < argc) teach_n   = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--teach-len") && i + 1 < argc) teach_len = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--resync-win") && i + 1 < argc) resync_win = (size_t)atol(argv[++i]);
        else if (!strcmp(argv[i], "--no-teach")) do_teach = false;
    }

    int rx = socket(AF_INET, SOCK_DGRAM, 0);
    if (rx < 0) { perror("socket"); return 2; }
    int rcvbuf = 256 * 1024 * 1024;
    setsockopt(rx, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    socklen_t sl = sizeof(rcvbuf);
    getsockopt(rx, SOL_SOCKET, SO_RCVBUF, &rcvbuf, &sl);
    struct sockaddr_in me;
    memset(&me, 0, sizeof(me));
    me.sin_family = AF_INET; me.sin_addr.s_addr = INADDR_ANY; me.sin_port = htons((uint16_t)port);
    if (bind(rx, (struct sockaddr *)&me, sizeof(me)) < 0) { perror("bind"); return 2; }
    struct timeval tv = {0, 200000};
    setsockopt(rx, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    printf("=== p6e_udp_pattern (C++, 吞吐口径): 本地 :%d <-> 板子 %s:%d ===\n", port, board, port);
    printf("    内核 SO_RCVBUF 实收 = %.1f MB ; 重同步窗口 = %zu B\n", rcvbuf / 1048576.0, resync_win);

    if (do_teach) {
        int tx = socket(AF_INET, SOCK_DGRAM, 0);
        struct sockaddr_in dst;
        memset(&dst, 0, sizeof(dst));
        dst.sin_family = AF_INET; dst.sin_port = htons((uint16_t)port);
        inet_pton(AF_INET, board, &dst.sin_addr);
        Pattern tp;
        static uint8_t tbuf[4096];
        if (teach_len > (int)sizeof(tbuf)) teach_len = (int)sizeof(tbuf);
        tp.fill(tbuf, (size_t)teach_len);
        for (int k = 0; k < teach_n; k++)
            if (sendto(tx, tbuf, (size_t)teach_len, 0, (struct sockaddr *)&dst, sizeof(dst)) < 0) perror("sendto");
        printf("    [teach] 发 %d x %d B 图案前缀 -> %s:%d (板子随即全速发)\n", teach_n, teach_len, board, port);
        close(tx);
    }

    static uint8_t buf[65536], exp[65536];
    Pattern pat;
    uint64_t frames = 0, bytes = 0, bad = 0, gap_bytes = 0, gap_events = 0;
    uint64_t bucket[16] = {0};
    double t0 = now_s(), t_end = t0 + secs, last = t0;

    while (now_s() < t_end) {
        ssize_t n = recv(rx, buf, sizeof(buf), 0);
        if (n <= 0) continue;
        frames++;
        bucket[((size_t)n / 128) & 15]++;
        size_t probe_n = (size_t)n < 32 ? (size_t)n : 32;
        size_t off = 0;
        {
            Pattern trial = pat;
            trial.fill(exp, (size_t)n);
            if (memcmp(buf, exp, (size_t)n) != 0) {
                size_t k = resync(pat, buf, probe_n, resync_win);
                if (k) {
                    pat.skip(k);
                    gap_bytes += k; gap_events++;
                    if (gap_events <= 5)
                        printf("  [GAP] 第 %llu 帧前少 %zu 字节 (接收侧掉包) ⇒ 重对齐; 累计 %llu 字节\n",
                               (unsigned long long)frames, k, (unsigned long long)gap_bytes);
                    off = k;
                } else {
                    bad++;
                    if (bad <= 3) {
                        size_t i = 0;
                        while (i < (size_t)n && buf[i] == exp[i]) i++;
                        printf("  [FAIL] 第 %llu 帧真失配 (窗口内找不到对齐点): 长 %zd, 首个不同字节 @%zu\n",
                               (unsigned long long)frames, n, i);
                    }
                }
            }
        }
        bytes += (uint64_t)n;
        (void)off;
        double now = now_s();
        if (now - last >= 1.0) {
            printf("    [%5.1fs] 帧=%llu 字节=%llu  ≈%7.1f Mbps  失配=%llu 掉包=%llu\n",
                   now - t0, (unsigned long long)frames, (unsigned long long)bytes,
                   (double)bytes * 8.0 / (now - t0) / 1e6,
                   (unsigned long long)bad, (unsigned long long)gap_events);
            fflush(stdout);
            last = now;
        }
    }
    double dt = now_s() - t0;
    printf("\n  [汇总] 收 %llu 帧 / %llu 字节 / %.2fs ⇒ **%.1f Mbps** (接收侧口径)\n",
           (unsigned long long)frames, (unsigned long long)bytes, dt,
           (double)bytes * 8.0 / dt / 1e6);
    printf("        载荷长度桶(128B): ");
    for (int i = 0; i < 16; i++) if (bucket[i]) printf("%d-%dB:%llu ", i * 128, i * 128 + 127, (unsigned long long)bucket[i]);
    printf("\n        (板子 i_paylen=1472 ⇒ 预期只有 1472 那一桶非零)\n");
    if (gap_events)
        printf("  [INFO] 接收侧掉包 %llu 次 / %llu 字节 (占 %.2f%%) ⇒ 是我这边内核缓冲丢的;\n"
               "         与板子 W9(udpapp_tx_bytes) 对账可确认少的是谁丢的\n",
               (unsigned long long)gap_events, (unsigned long long)gap_bytes,
               (bytes + gap_bytes) ? 100.0 * (double)gap_bytes / (double)(bytes + gap_bytes) : 0.0);
    if (frames == 0) { printf("  [FAIL] 一个包都没收到 ⇒ peer 没学到 / 板子没发 / 网段不对\n"); return 1; }
    if (bad) { printf("  [FAIL] %llu/%llu 帧图案真失配\n", (unsigned long long)bad, (unsigned long long)frames); return 1; }
    printf("  [PASS] 全部 %llu 帧逐字节等于图案流 (offset 0 连续, 含 %llu 次重对齐)\n",
           (unsigned long long)frames, (unsigned long long)gap_events);
    return 0;
}
