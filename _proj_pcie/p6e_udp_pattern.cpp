//=============================================================================
// p6e_udp_pattern.cpp — Linux 侧 UDP 图案对端 (**吞吐**口径; 功能口径用同名 .py)
//   为什么另写 C++: 本工程纪律 —— 速率测试一律 C++/内核旁路, Python 只做功能验证。
//   Python 那版会在接收侧自己先到顶 (解释器 + 每包一次 fill), 报出来的数会**低于板子能力**,
//   把"工具的天花板"误当成"板子的能力" —— 这正是本工程踩过的"工具余量"坑。
//
//   编译: g++ -O2 -o p6e_udp_pattern p6e_udp_pattern.cpp
//   用法: ./p6e_udp_pattern [--secs 10] [--board 192.168.100.2] [--port 8081] [--no-teach]
//         [--teach-n 1] [--teach-len 100]
//   做两件事: ① 发教学包 (图案前缀, offset 0) 教板子 peer ⇒ 板子开始全速发图案帧;
//             ② 收到即逐字节比对, 打 1s 一次速率 + 汇总; 退出码 0=全对, 1=失配/没收到。
//   图案: xorshift64 (s^=s<<13; s^=s>>7; s^=s<<17), 每步取 s[31:24], 种子 0x9E3779B97F4A7C15,
//         **先取后推进** —— 与 rtl/app_udp_pattern.v、tools/cpp_peer/peer.cpp 逐字节一致
//         (peer.cpp:220-228 的注释专门记录了"曾经推进在先"那个 100% 失配的历史)。
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
};

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv) {
    const char *board = "192.168.100.2";
    int port = 8081, teach_n = 1, teach_len = 100;
    double secs = 10.0;
    bool do_teach = true;
    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--board") && i + 1 < argc) board = argv[++i];
        else if (!strcmp(argv[i], "--port")  && i + 1 < argc) port  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--secs")  && i + 1 < argc) secs  = atof(argv[++i]);
        else if (!strcmp(argv[i], "--teach-n")   && i + 1 < argc) teach_n   = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--teach-len") && i + 1 < argc) teach_len = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-teach")) do_teach = false;
    }

    int rx = socket(AF_INET, SOCK_DGRAM, 0);
    if (rx < 0) { perror("socket"); return 2; }
    int rcvbuf = 64 * 1024 * 1024;                     // 尽力而为: 内核缓冲不够会静默丢包
    setsockopt(rx, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    socklen_t sl = sizeof(rcvbuf);
    getsockopt(rx, SOL_SOCKET, SO_RCVBUF, &rcvbuf, &sl);   // 内核会打折, 读回真实值
    struct sockaddr_in me;
    memset(&me, 0, sizeof(me));
    me.sin_family = AF_INET; me.sin_addr.s_addr = INADDR_ANY; me.sin_port = htons((uint16_t)port);
    if (bind(rx, (struct sockaddr *)&me, sizeof(me)) < 0) { perror("bind"); return 2; }
    struct timeval tv = {0, 200000};                   // 200ms: 统计期间不空转
    setsockopt(rx, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    printf("=== p6e_udp_pattern (C++, 吞吐口径): 本地 :%d  <->  板子 %s:%d ===\n", port, board, port);
    printf("    内核 SO_RCVBUF 实收 = %.1f MB\n", rcvbuf / 1048576.0);

    if (do_teach) {
        int tx = socket(AF_INET, SOCK_DGRAM, 0);
        struct sockaddr_in dst;
        memset(&dst, 0, sizeof(dst));
        dst.sin_family = AF_INET; dst.sin_port = htons((uint16_t)port);
        inet_pton(AF_INET, board, &dst.sin_addr);
        Pattern tp;                                    // 教学包 = 图案流前缀 ⇒ 板子 RX 校验器也过
        static uint8_t tbuf[4096];
        if (teach_len > (int)sizeof(tbuf)) teach_len = (int)sizeof(tbuf);
        tp.fill(tbuf, (size_t)teach_len);
        for (int k = 0; k < teach_n; k++)
            if (sendto(tx, tbuf, teach_len, 0, (struct sockaddr *)&dst, sizeof(dst)) < 0) perror("sendto");
        printf("    [teach] 发 %d x %d B 图案前缀 -> %s:%d (板子随即全速发)\n", teach_n, teach_len, board, port);
        close(tx);
    }

    static uint8_t buf[65536];
    static uint8_t exp[65536];
    Pattern pat;                                       // 期望: 图案流从 offset 0 连续接下去
    uint64_t frames = 0, bytes = 0, bad = 0;
    uint64_t size_hist[16] = {0};                      // 载荷长度直方图 (按 128B 分桶)
    double t0 = now_s(), t_end = t0 + secs, last = t0;

    while (now_s() < t_end) {
        ssize_t n = recv(rx, buf, sizeof(buf), 0);
        if (n <= 0) continue;
        frames++;
        size_hist[((size_t)n / 128) & 15]++;
        pat.fill(exp, (size_t)n);
        if (memcmp(buf, exp, (size_t)n) != 0) {
            bad++;
            if (bad <= 3) {
                size_t i = 0;
                while (i < (size_t)n && buf[i] == exp[i]) i++;
                printf("  [FAIL] 第 %llu 帧失配: 长 %zd, 首个不同字节 @%zu (got %02x exp %02x), 流偏移 %llu\n",
                       (unsigned long long)frames, n, i,
                       i < (size_t)n ? buf[i] : 0, i < (size_t)n ? exp[i] : 0, (unsigned long long)bytes + i);
            }
        }
        bytes += (uint64_t)n;
        double now = now_s();
        if (now - last >= 1.0) {
            printf("    [%5.1fs] 帧=%llu 字节=%llu  ≈%7.1f Mbps  失配=%llu\n",
                   now - t0, (unsigned long long)frames, (unsigned long long)bytes,
                   (double)bytes * 8.0 / (now - t0) / 1e6, (unsigned long long)bad);
            fflush(stdout);
            last = now;
        }
    }
    double dt = now_s() - t0;
    printf("\n  [汇总] 收 %llu 帧 / %llu 字节 / %.2fs ⇒ **%.1f Mbps**\n",
           (unsigned long long)frames, (unsigned long long)bytes, dt,
           (double)bytes * 8.0 / dt / 1e6);
    printf("        载荷长度直方图(128B 桶): ");
    for (int i = 0; i < 16; i++) if (size_hist[i]) printf("%dB-%dB:%llu ", i * 128, i * 128 + 127, (unsigned long long)size_hist[i]);
    printf("\n        (板子 i_paylen=1472 ⇒ 预期只有 1472 这一桶非零)\n");
    if (frames == 0) { printf("  [FAIL] 一个包都没收到 ⇒ peer 没学到 / 板子没发 / 网段不对\n"); return 1; }
    if (bad) { printf("  [FAIL] %llu/%llu 帧图案失配\n", (unsigned long long)bad, (unsigned long long)frames); return 1; }
    printf("  [PASS] 全部 %llu 帧**逐字节**等于图案流前缀 (offset 0 起到 %llu)\n",
           (unsigned long long)frames, (unsigned long long)bytes);
    return 0;
}
