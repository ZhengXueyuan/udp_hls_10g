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
// ⭐ 2026-10-09 (R1/R2 落地, 与 _proj_pcie/p7b_biz/p7b_tcp_sink.cpp 同一契约): 非阻塞 + poll(LT);
//   **删掉了旧版 connect 后 `fcntl(fd,F_SETFL,fl)` 切回阻塞**那一步; recv 前一律 poll, poll 超时
//   = 计数 + `SINK_CONN ... STALL` 行 + 计入 bad_conns (确定语义, 不静默吞);
//   ⛔ 不写盘 (载荷只在内存; --nocheck 只是关掉复算, 同样不落盘)。
// 编译 (部署口径 = _proj_10g/notes/p7b_affinity/BUILD.md §2; ⛔ 别再用旧头注释里的 -O3 写法):
//   g++ -O2 -o p7b_tcp_sink_rate p7b_tcp_sink_rate.cpp
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

// ------------------------- R1 (2026-10-09): socket 契约 -------------------------
// 全程序**只有这一处 fcntl** —— 只置 O_NONBLOCK, 从不切回阻塞 (grep 判据:
// `grep -n "F_SETFL" *.cpp` 只应命中本函数; 出现清 O_NONBLOCK 即违规)。
static void set_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) die("fcntl(O_NONBLOCK)");
    if (!(fcntl(fd, F_GETFL, 0) & O_NONBLOCK)) { fprintf(stderr, "FATAL: O_NONBLOCK 未生效\n"); exit(2); }
}

// 非阻塞 connect: EINPROGRESS -> poll(POLLOUT, 电平触发) -> SO_ERROR。
// 成功 0 / 失败 -1 且 *why = 原因码 (ETIMEDOUT 或 errno / SO_ERROR)。
static int connect_nb(int fd, const struct sockaddr *sa, socklen_t sl, int timeout_ms, int *why) {
    int r = connect(fd, sa, sl);
    if (r < 0 && errno != EINPROGRESS) { *why = errno; return -1; }
    if (r < 0) {
        struct pollfd p{fd, POLLOUT, 0};
        int pr;
        do { pr = poll(&p, 1, timeout_ms); } while (pr < 0 && errno == EINTR);
        if (pr == 0) { *why = ETIMEDOUT; return -1; }
        if (pr < 0)  { *why = errno; return -1; }
    }
    int err = 0; socklen_t el = sizeof(err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el) < 0) { *why = errno; return -1; }
    if (err) { *why = err; return -1; }
    return 0;                                     // ⚠️ 返回后 fd **仍是 O_NONBLOCK**
}

static int connect_to(const char *host, int port, int secs, int *why) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { *why = errno; return -1; }
    struct sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &a.sin_addr) != 1) { *why = EINVAL; close(fd); return -1; }
    set_nonblock(fd);                             // ⭐ socket() 之后立刻设, 且**不再切回**
    if (connect_nb(fd, (struct sockaddr *)&a, sizeof(a), secs * 1000, why) < 0) { close(fd); return -1; }
    return fd;
}

int main(int argc, char **argv) {
    argc = p7b_pin_cpu(argc, argv);      // 启动即绑核 (p7b_affinity.h; 剥离本函数自己的选项)
    const char *host = "192.168.100.2";
    int port = 8080, conns = 100, secs = 60, rcvbuf = 8 << 20;
    long maxbytes = 4L << 20;        // 每连接读上限 (1MB 图案 + 余量)
    int poll_ms = 5000, stall_n = 3; // R1: poll 等待上限 / 连续超时次数上限
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
        else if (k == "--poll-ms") poll_ms = atoi(nx());
        else if (k == "--stall-n") stall_n = atoi(nx());
        else if (k == "--nocheck") nocheck = true;
        else if (k == "--selftest") selftest = true;
        else if (k == "--help") {
            printf("p7b_tcp_sink_rate --host H --port P [--conns N] [--seconds S] [--rcvbuf B] [--maxbytes B] [--nocheck]\n"
                   "             [--poll-ms 5000] [--stall-n 3]\n"
                   "  同 p7b_tcp_sink 的接收循环 (非阻塞 + poll LT); --nocheck 关掉逐字节图案复算 (台架天花板对照臂)\n"
                   "  ⛔ 不写盘; 连续 stall-n 次 poll 超时 => 该连接 STALL 并计入 bad_conns\n");
            return 0;
        } else { fprintf(stderr, "unknown arg %s (--help)\n", k.c_str()); return 2; }
    }
    if (selftest) return p7b_pattern_selftest("p7b_tcp_sink_rate");
    if (poll_ms < 1) poll_ms = 1;
    if (stall_n < 1) stall_n = 1;

    printf("SINK_RATE_MODE check=%s\n", nocheck ? "off" : "on");
    std::vector<uint8_t> buf(1 << 20);
    double t_start = now_s();
    long long tot_bytes = 0, tot_clean = 0, tot_conn = 0, tot_mismatch_bytes = 0;
    long long bad_conns = 0, fail_conns = 0, stall_conns = 0, err_conns = 0, tot_poll_tmo = 0;
    double first_conn_at = 0, last_conn_end = 0;

    for (int c = 0; c < conns; c++) {
        if (now_s() - t_start > secs) break;
        double t0 = now_s();
        int why = 0;
        int fd = connect_to(host, port, 5, &why);
        double t1 = now_s();
        if (fd < 0) {
            fail_conns++;
            printf("SINK_CONN %d FAIL_CONNECT why=%d (%s) (t=%.6f)\n", c, why, strerror(why), t1 - t_start);
            if (fail_conns > 5) break;
            continue;
        }
        if (c == 0) first_conn_at = t1;
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
        P7bPat pat(0);                       // **每连接** 从偏移 0 起
        long long got = 0, mism_bytes = 0;
        long long first_mis = -1;
        long long nread_calls = 0, conn_tmo = 0;
        int status = 0;                      // 0=正常(FIN/读满) 1=STALL 2=ERR
        while (got < maxbytes) {
            // ⭐ R1: 等待一律 poll (电平触发, 默认语义; ⛔ 无 EPOLLET / 无 select)
            struct pollfd p{fd, POLLIN, 0};
            int pr;
            do { pr = poll(&p, 1, poll_ms); } while (pr < 0 && errno == EINTR);
            if (pr == 0) {                   // ⭐ poll 超时 = 确定语义 (计数 + 日志 + 中止)
                conn_tmo++;
                if (conn_tmo >= stall_n) {
                    printf("SINK_CONN %d POLL_TIMEOUT %lld x %d ms 无数据 (got=%lld) => 中止本连接\n",
                           c, conn_tmo, poll_ms, got);
                    status = 1; break;
                }
                continue;
            }
            if (pr < 0) { printf("SINK_CONN %d POLL_ERR errno=%d\n", c, errno); status = 2; break; }
            if (p.revents & POLLNVAL) { printf("SINK_CONN %d POLLNVAL (fd 失效)\n", c); status = 2; break; }
            ssize_t n = recv(fd, buf.data(), buf.size(), 0);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;  // 非阻塞语义
                printf("SINK_CONN %d RECV_ERR %d\n", c, errno);
                status = 2; break;
            }
            if (n == 0) break;               // 板侧 FIN (AUTO_CLOSE)
            conn_tmo = 0;
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
        tot_poll_tmo += conn_tmo;
        if (nocheck) {
            first_mis = -9999;
            mism_bytes = -1;
            if (status == 0) tot_clean++;    // ⚠️ 本模式下的 clean 只表示"连接完成", 无内容证据
            else bad_conns++;
        } else if (status == 0 && first_mis < 0) {
            tot_clean++;
        } else {
            bad_conns++;
        }
        if (status == 1) stall_conns++;
        if (status == 2) err_conns++;
        tot_mismatch_bytes += mism_bytes > 0 ? mism_bytes : 0;
        printf("SINK_CONN %d %s bytes=%lld first_mismatch=%lld mism_bytes=%lld CHECK=%s "
               "conn_ms=%.3f dur_ms=%.3f Mbps=%.3f reads=%lld poll_tmo=%lld CPU_FREQ_KHZ=%s\n",
               c, status == 0 ? "OK" : (status == 1 ? "STALL" : "ERR"),
               got, first_mis, mism_bytes, nocheck ? "off" : "on",
               (t1 - t0) * 1e3, (t2 - t1) * 1e3,
               (t2 - t1) > 0 ? got * 8.0 / (t2 - t1) / 1e6 : 0.0, nread_calls, conn_tmo,
               p7baff_cpu_freq_khz().c_str());   // F9 + R1: 尾部追加 poll_tmo (旧字段一字不动)
        fflush(stdout);
    }
    double t_end = now_s();
    printf("SINK_SUM conns=%lld fail_conns=%lld bytes=%lld clean_conns=%lld bad_conns=%lld "
           "mismatch_bytes=%lld CHECK=%s stall_conns=%lld err_conns=%lld poll_tmo=%lld "
           "wall_s=%.3f net_s=%.3f agg_Mbps=%.3f\n",
           tot_conn, fail_conns, tot_bytes, tot_clean, bad_conns, tot_mismatch_bytes,
           nocheck ? "off" : "on", stall_conns, err_conns, tot_poll_tmo,
           t_end - t_start, last_conn_end - first_conn_at,
           (last_conn_end - first_conn_at) > 0 ? tot_bytes * 8.0 / (last_conn_end - first_conn_at) / 1e6 : 0.0);
    printf("SINK_DONE\n");
    return (bad_conns == 0 && fail_conns == 0 && tot_bytes > 0) ? 0 : 1;
}
