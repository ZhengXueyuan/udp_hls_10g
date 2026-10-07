// p7b_tcp_sink.cpp -- TCP 下行验收 (板 -> 对端): 真实 Linux 栈收流 + 逐字节图案复算
//
// 被测对象: 板上 APP_MODE 的 TCP 演示 app (rtl/app_pattern.v, wrapper_p4.v:1170 例化)
//   * 每连接 ev_up 后立刻推 TX_BYTES(1MB) 图案流, 发完 AUTO_CLOSE 发 FIN
//   * **单会话**: 一份 tx_lfsr/rx_lfsr, 只有第一条连接的事件被受理
//     (rtl/app_pattern.v:356-361 `if (!active || ((ev_slot==act_id) && ...))`)
//     => 任何时刻只许一条 TCP 连接在跑; 并发连接会让两条流的期望序列互相踩
//   * 图案与偏移语义见 p7b_pattern.h (每连接从偏移 0 起)
//
// 本工具给出**两条互相独立**的口径 (都不依赖板侧计数器):
//   ① 应用层 recv 到的字节流, 逐字节 == xorshift64 图案 (本工具自算)
//   ② 同一窗口内的 socket 字节数与墙钟 => Mbps
//   与板侧 W14/W15 (TCP fast path 发帧/字节) 对账 = 第三条口径
//
// 用法见 --help。判据: 每条连接 FIRST_MISMATCH = -1 且 收满 <=1MB+padding 字节。
//
// 编译: g++ -O3 -std=c++17 -o p7b_tcp_sink p7b_tcp_sink.cpp
#include "p7b_pattern.h"

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
    const char *host = "192.168.100.2";
    int port = 8080, conns = 100, secs = 60, rcvbuf = 8 << 20;
    long maxbytes = 4L << 20;        // 每连接读上限 (1MB 图案 + 余量)
    bool selftest = false;
    for (int i = 1; i < argc; i++) {
        std::string k = argv[i];
        auto nx = [&]() -> const char * { if (++i >= argc) { fprintf(stderr, "missing %s\n", k.c_str()); exit(2); } return argv[i]; };
        if (k == "--host") host = nx();
        else if (k == "--port") port = atoi(nx());
        else if (k == "--conns") conns = atoi(nx());
        else if (k == "--seconds") secs = atoi(nx());
        else if (k == "--rcvbuf") rcvbuf = atoi(nx());
        else if (k == "--maxbytes") maxbytes = atol(nx());
        else if (k == "--selftest") selftest = true;
        else if (k == "--help") {
            printf("p7b_tcp_sink --host H --port P [--conns N] [--seconds S] [--rcvbuf B] [--maxbytes B]\n"
                   "  逐连接: connect -> 收流 -> 逐字节复算图案(偏移0起) -> 报告\n"
                   "  输出行以 SINK_ 前缀, 便于机器解析; 汇总行 SINK_SUM_*\n"
                   "  --selftest: 只跑图案自检向量\n");
            return 0;
        } else { fprintf(stderr, "unknown arg %s (--help)\n", k.c_str()); return 2; }
    }
    if (selftest) return p7b_pattern_selftest("p7b_tcp_sink");

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
            uint64_t nmis = 0;
            long long f = pat.check(buf.data(), (size_t)n, &nmis);
            if (f >= 0) {
                if (first_mis < 0) first_mis = got + f;
                mism_bytes += (long long)nmis;
            }
            got += n;
        }
        double t2 = now_s();
        close(fd);
        last_conn_end = t2;
        tot_conn++;
        tot_bytes += got;
        if (first_mis < 0) tot_clean++;
        else bad_conns++;
        tot_mismatch_bytes += mism_bytes;
        printf("SINK_CONN %d OK bytes=%lld first_mismatch=%lld mism_bytes=%lld "
               "conn_ms=%.3f dur_ms=%.3f Mbps=%.3f reads=%lld\n",
               c, got, first_mis, mism_bytes, (t1 - t0) * 1e3, (t2 - t1) * 1e3,
               (t2 - t1) > 0 ? got * 8.0 / (t2 - t1) / 1e6 : 0.0, nread_calls);
        fflush(stdout);
    }
    double t_end = now_s();
    printf("SINK_SUM conns=%lld fail_conns=%lld bytes=%lld clean_conns=%lld bad_conns=%lld "
           "mismatch_bytes=%lld wall_s=%.3f net_s=%.3f agg_Mbps=%.3f\n",
           tot_conn, fail_conns, tot_bytes, tot_clean, bad_conns, tot_mismatch_bytes,
           t_end - t_start, last_conn_end - first_conn_at,
           (last_conn_end - first_conn_at) > 0 ? tot_bytes * 8.0 / (last_conn_end - first_conn_at) / 1e6 : 0.0);
    printf("SINK_DONE\n");
    return (bad_conns == 0 && fail_conns == 0 && tot_bytes > 0) ? 0 : 1;
}
