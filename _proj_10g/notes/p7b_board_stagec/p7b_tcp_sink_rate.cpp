// p7b_tcp_sink_rate.cpp -- Stage C 板级轮: 下行接收的**台架天花板**变体
//
// 种子 = _proj_pcie/p7b_biz/p7b_tcp_sink.cpp (md5 2f2d083566bbc2d36c5ed28fa4494753,
//        本变体逐字复制后只加 `--nocheck` 一条路径; 对照件 = 种子本体)。
// 理由: 种子的逐字节图案复算 (p7b_pattern.h 的 P7bPat::check) 是**串行依赖链**
//   (每字节一次 xorshift64) ⇒ 单核消费上限 ~0.6 GB/s 量级 (同族实测: 生成侧 fillbench
//   0.584 GB/s)。若下行实测贴在这个量级, 必须能用"关掉图案复算的同一接收路径"分辨
//   "板子的帽子" vs "台架的帽子" —— 与上行的 p7b_tcp_src / p7b_tcp_src_rate 对照同款手法。
//
// 用法: 同 p7b_tcp_sink, 外加 --nocheck (默认关 = 与种子行为一致)。
//   --nocheck 时: 只 recv+计数; SINK_CONN 打 CHECK=off 且 first_mismatch=-9999/mism_bytes=-1
//   (⚠️ 该模式下**没有内容证据** —— 判据里不许把它当"逐字节通过")。
//
// 编译: g++ -O3 -std=c++17 -o p7b_tcp_sink_rate p7b_tcp_sink_rate.cpp
#include "p7b_pattern.h"
#include "p7b_affinity.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <string>
#include <vector>

static double now_s() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void die(const char *m) { perror(m); exit(2); }

static int connect_to(const char *host, int port, int secs) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) die("socket");
    struct sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &a.sin_addr) != 1) { fprintf(stderr, "bad host\n"); exit(2); }
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int r = connect(fd, (struct sockaddr *)&a, sizeof(a));
    if (r < 0 && errno != EINPROGRESS) die("connect");
    struct pollfd p{fd, POLLOUT, 0};
    r = poll(&p, 1, secs * 1000);
    if (r <= 0) { close(fd); return -1; }
    int err = 0; socklen_t el = sizeof(err);
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
    if (err) { close(fd); return -1; }
    fcntl(fd, F_SETFL, fl);          // 回到阻塞模式
    return fd;
}

int main(int argc, char **argv) {
    argc = p7b_pin_cpu(argc, argv);      // 启动即绑核 (p7b_affinity.h; 剥离本函数自己的选项)
    const char *host = "192.168.100.2";
    int port = 8080, conns = 100, secs = 60, rcvbuf = 8 << 20;
    long maxbytes = 4L << 20;        // 每连接读上限 (1MB 图案 + 余量)
    bool selftest = false, nocheck = false;
    for (int i = 1; i < argc; i++) {
        std::string k = argv[i];
        auto nx = [&]() -> const char * { if (++i >= argc) { fprintf(stderr, "missing %s\n", k.c_str()); exit(2); } return argv[i]; };
        if (k == "--host") host = nx();
        else if (k == "--port") port = atoi(nx());
        else if (k == "--conns") conns = atoi(nx());
        else if (k == "--seconds") secs = atoi(nx());
        else if (k == "--rcvbuf") rcvbuf = atoi(nx());
        else if (k == "--maxbytes") maxbytes = atol(nx());
        else if (k == "--nocheck") nocheck = true;
        else if (k == "--selftest") selftest = true;
        else if (k == "--help") {
            printf("p7b_tcp_sink_rate --host H --port P [--conns N] [--seconds S] [--rcvbuf B] [--maxbytes B] [--nocheck]\n"
                   "  同 p7b_tcp_sink 的接收循环; --nocheck 关掉逐字节图案复算 (台架天花板对照臂)\n");
            return 0;
        } else { fprintf(stderr, "unknown arg %s (--help)\n", k.c_str()); return 2; }
    }
    if (selftest) return p7b_pattern_selftest("p7b_tcp_sink_rate");

    printf("SINK_RATE_MODE check=%s\n", nocheck ? "off" : "on");
    std::vector<uint8_t> buf(1 << 20);
    double t_start = now_s();
    long long tot_bytes = 0, tot_clean = 0, tot_conn = 0, tot_mismatch_bytes = 0;
    long long bad_conns = 0, fail_conns = 0;
    double first_conn_at = 0, last_conn_end = 0;

    for (int c = 0; c < conns; c++) {
        if (now_s() - t_start > secs) break;
        double t0 = now_s();
        int fd = connect_to(host, port, 5);
        double t1 = now_s();
        if (fd < 0) {
            fail_conns++;
            printf("SINK_CONN %d FAIL_CONNECT (t=%.6f)\n", c, t1 - t_start);
            if (fail_conns > 5) break;
            continue;
        }
        if (c == 0) first_conn_at = t1;
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
        P7bPat pat(0);                       // **每连接** 从偏移 0 起
        long long got = 0, mism_bytes = 0;
        long long first_mis = -1;
        long long nread_calls = 0;
        while (got < maxbytes) {
            ssize_t n = recv(fd, buf.data(), buf.size(), 0);
            if (n < 0) { if (errno == EINTR) continue; printf("SINK_CONN %d RECV_ERR %d\n", c, errno); break; }
            if (n == 0) break;               // 板侧 FIN (AUTO_CLOSE)
            nread_calls++;
            if (!nocheck) {
                uint64_t nmis = 0;
                long long f = pat.check(buf.data(), (size_t)n, &nmis);
                if (f >= 0) {
                    if (first_mis < 0) first_mis = got + f;
                    mism_bytes += (long long)nmis;
                }
            }
            got += n;
        }
        double t2 = now_s();
        close(fd);
        last_conn_end = t2;
        tot_conn++;
        tot_bytes += got;
        if (nocheck) {
            first_mis = -9999;
            mism_bytes = -1;
            tot_clean++;                     // ⚠️ 本模式下的 clean 只表示"连接完成", 无内容证据
        } else if (first_mis < 0) {
            tot_clean++;
        } else {
            bad_conns++;
        }
        tot_mismatch_bytes += mism_bytes > 0 ? mism_bytes : 0;
        printf("SINK_CONN %d OK bytes=%lld first_mismatch=%lld mism_bytes=%lld CHECK=%s "
               "conn_ms=%.3f dur_ms=%.3f Mbps=%.3f reads=%lld CPU_FREQ_KHZ=%s\n",
               c, got, first_mis, mism_bytes, nocheck ? "off" : "on",
               (t1 - t0) * 1e3, (t2 - t1) * 1e3,
               (t2 - t1) > 0 ? got * 8.0 / (t2 - t1) / 1e6 : 0.0, nread_calls,
               p7baff_cpu_freq_khz().c_str());   // F9: 周期行尾频率轨迹 (追加, 旧字段一字不动)
        fflush(stdout);
    }
    double t_end = now_s();
    printf("SINK_SUM conns=%lld fail_conns=%lld bytes=%lld clean_conns=%lld bad_conns=%lld "
           "mismatch_bytes=%lld CHECK=%s wall_s=%.3f net_s=%.3f agg_Mbps=%.3f\n",
           tot_conn, fail_conns, tot_bytes, tot_clean, bad_conns, tot_mismatch_bytes,
           nocheck ? "off" : "on",
           t_end - t_start, last_conn_end - first_conn_at,
           (last_conn_end - first_conn_at) > 0 ? tot_bytes * 8.0 / (last_conn_end - first_conn_at) / 1e6 : 0.0);
    printf("SINK_DONE\n");
    return (bad_conns == 0 && fail_conns == 0 && tot_bytes > 0) ? 0 : 1;
}
