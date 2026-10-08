// p7b_tcp_src.cpp -- TCP 上行验收 (对端 -> 板): 真实 Linux 栈灌流 + 同连接双向核对
//
// 被测对象: 板上 TCP fast path 的 RX 侧 (mac_rx_10g -> rx_classify -> tcp_rx ->
//           tcp_echo.frame_fifo -> app_pattern 校验器)。板侧计数器: W22(接受帧)/
//           W23(nonmatch)/W0/W1(MAC 收帧/字节)/W3(FCS 错)/W42... (见方案 §4.4)
//
// ⚠️ 两条**结构性**限制 (读源码得出, 方案 §2 有出处):
//   ① 板侧校验器 rtl/app_pattern.v 的 RX 是 **0.889 B/拍** (rtl/app_pattern.v:530-544 每字 1 拍
//      取值 + rw_n 拍逐字节比) => @156.25MHz 天花板 **1.111 Gbps**。实测若停在这个值附近,
//      是 **app 天花板**, 不是 TCP 栈/链路的能力 (RATE 轮教训 #36 的同族陷阱)。
//   ② 板侧 app 发完 1MB 会 AUTO_CLOSE 发 FIN。**半关闭后对端仍可继续发** (TCP 语义), 且
//      板侧 HLS 状态机只在**收到对端 FIN** 时才离开 T_ESTABLISHED
//      (hls/src/layer_tcp.cpp:710-723; 自己发 FIN 不走那条) => 上行测试可以持续跑。
//      但这一条**必须先用本工具的 SRC_EOF_AT 那行验证** (方案 §4.3 步骤 0)。
//
// 用法: p7b_tcp_src --host 192.168.100.2 --port 8080 --seconds 30 [--chunk 65536]
//                    [--pace-bps 0] [--no-verify-down] [--poll-ms 200]
// 输出行 SRC_* / SRC_SUM_* / SRC_DONE; 退出码 0 = 上行无 send 错且(若开核对)下行逐字节干净。
//
// ⭐ 2026-10-09 (R1/R2 落地, 与 _proj_pcie/p7b_biz/p7b_tcp_src.cpp 同一契约): 非阻塞 + poll(LT);
//   connect 也非阻塞; 全程序只有一处 fcntl (set_nonblock); poll 超时 = 计数进 SRC_SUM, 不静默吞;
//   ⛔ 不写盘 (上行现场生成图案直接 send, 下行增量复算)。
// 编译 (部署口径 = _proj_10g/notes/p7b_affinity/BUILD.md §2; ⛔ 别再用旧头注释里的 -O3 写法):
//   g++ -O2 -o p7b_tcp_src_diag p7b_tcp_src_diag.cpp
#include "p7b_pattern.h"
#include "p7b_affinity.h"      // F7 (2026-10-08): 补齐接线 —— 此前本件**完全不绑核、无 PIN_* 行**

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
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

// ------------------------- R1 (2026-10-09): socket 契约 -------------------------
// 全程序**只有这一处 fcntl** —— 只置 O_NONBLOCK, 从不切回阻塞
// (判据: `grep -n "F_SETFL" *.cpp` 只应命中本函数; 出现清 O_NONBLOCK 即违规)。
static void set_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) { perror("fcntl(O_NONBLOCK)"); exit(2); }
    if (!(fcntl(fd, F_GETFL, 0) & O_NONBLOCK)) { fprintf(stderr, "FATAL: O_NONBLOCK 未生效\n"); exit(2); }
}

// 非阻塞 connect: EINPROGRESS -> poll(POLLOUT, 电平触发) -> SO_ERROR。
// 成功 0 / 失败 -1 且 *why = 原因码; 调用者必须把它打进日志 (不许静默)。
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

int main(int argc, char **argv) {
    argc = p7b_pin_cpu(argc, argv);      // F7 (2026-10-08): 启动即绑核 (p7b_affinity.h; 剥离自己的选项)
    const char *host = "192.168.100.2";
    int port = 8080, secs = 30, chunk = 65536, poll_ms = 200;
    long long pace = 0;
    bool selftest = false, verify_down = true;
    for (int i = 1; i < argc; i++) {
        std::string k = argv[i];
        auto nx = [&]() -> const char * { if (++i >= argc) { fprintf(stderr, "missing %s\n", k.c_str()); exit(2); } return argv[i]; };
        if (k == "--host") host = nx();
        else if (k == "--port") port = atoi(nx());
        else if (k == "--seconds") secs = atoi(nx());
        else if (k == "--chunk") chunk = atoi(nx());
        else if (k == "--pace-bps") pace = atoll(nx());
        else if (k == "--poll-ms") poll_ms = atoi(nx());
        else if (k == "--no-verify-down") verify_down = false;
        else if (k == "--selftest") selftest = true;
        else if (k == "--help") {
            printf("p7b_tcp_src --host H --port P [--seconds S] [--chunk B] [--pace-bps BPS] [--poll-ms 200]\n"
                   "  上行: 从连接起点偏移 0 起连续图案流 (现场生成), 灌到板子 (板侧 rcvbuf/窗口自然限速)\n"
                   "  下行: 同一连接上核对板子的 1MB 图案流 (可用 --no-verify-down 关)\n"
                   "  ⛔ 不写盘: 上行按 p7b_pattern.h 规则生成后直接 send; 下行增量复算\n"
                   "  --selftest: 图案自检向量\n");
            return 0;
        } else { fprintf(stderr, "unknown arg %s\n", k.c_str()); return 2; }
    }
    if (selftest) return p7b_pattern_selftest("p7b_tcp_src");
    if (poll_ms < 1) poll_ms = 1;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 2; }
    struct sockaddr_in a{};
    a.sin_family = AF_INET; a.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &a.sin_addr) != 1) { fprintf(stderr, "bad host\n"); return 2; }
    set_nonblock(fd);                     // ⭐ socket() 之后**立刻**设, 且全程不切回
    int why = 0;
    if (connect_nb(fd, (struct sockaddr *)&a, sizeof(a), 5000, &why) < 0) {
        fprintf(stderr, "SRC_CONNECT_FAIL why=%d (%s) %s:%d\n", why, strerror(why), host, port);
        return 2;
    }
    printf("SRC_CONNECTED %s:%d\n", host, port);
    if (pace > 0) setsockopt(fd, SOL_SOCKET, SO_MAX_PACING_RATE, &pace, sizeof(pace));

    P7bPat tx(0);                 // 上行: 每连接偏移 0 起
    P7bPat rx(0);                 // 下行: 板侧每连接偏移 0 起
    std::vector<uint8_t> sbuf(chunk), rbuf(1 << 20);
    long long tx_bytes = 0, rx_bytes = 0, rx_mism_bytes = 0, rx_first_mis = -1;
    long long partial_sends = 0, skip_bytes = 0, first_partial_at = -1;  // DIAG (WU_LOOP)
    long long poll_tmo = 0, poll_err = 0;                                 // R1 (2026-10-09)
    double t0 = now_s(), t_eof = 0;
    int eof_seen = 0, send_err = 0;
    double next_report = t0 + 1.0;

    while (now_s() - t0 < secs) {
        struct pollfd p{fd, 0, 0};
        p.events = POLLIN;
        if (!send_err) p.events |= POLLOUT;
        int pr;
        do { pr = poll(&p, 1, poll_ms); } while (pr < 0 && errno == EINTR);   // ⭐ R1: 电平触发
        double t = now_s();
        if (pr < 0) { poll_err++; printf("SRC_POLL_ERR errno=%d (poll 失败, 本轮结束)\n", errno); break; }
        if (pr == 0) poll_tmo++;             // ⭐ poll 超时 = 空闲; 计数进 SRC_SUM (确定语义, 非静默)
        if (pr > 0 && (p.revents & POLLIN)) {
            ssize_t n = recv(fd, rbuf.data(), rbuf.size(), 0);
            if (n == 0) { if (!eof_seen) { eof_seen = 1; t_eof = t; printf("SRC_EOF_AT %.6f rx_bytes=%lld  (板侧 FIN)\n", t - t0, rx_bytes); } }
            else if (n > 0) {
                rx_bytes += n;
                if (verify_down) {
                    uint64_t nm = 0;
                    long long f = rx.check(rbuf.data(), (size_t)n, &nm);
                    if (f >= 0) { if (rx_first_mis < 0) rx_first_mis = rx_bytes - n + f; rx_mism_bytes += (long long)nm; }
                } else rx.s = p7b_xs_next(rx.s);   // 不核对时也推进, 保持状态一致
            } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                printf("SRC_RECV_ERR errno=%d\n", errno);
            }
        }
        if (pr > 0 && (p.revents & (POLLOUT | POLLERR | POLLHUP)) && !send_err) {
            tx.fill(sbuf.data(), (size_t)chunk);
            ssize_t n = send(fd, sbuf.data(), (size_t)chunk, MSG_NOSIGNAL);
            if (n > 0 && n < (ssize_t)chunk) {   // DIAG (WU_LOOP): partial send => pattern SKIP
                partial_sends++; skip_bytes += (long long)chunk - n;
                if (first_partial_at < 0) first_partial_at = tx_bytes; }
            if (n > 0) tx_bytes += n;
            else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                send_err = errno; printf("SRC_SEND_ERR errno=%d tx_bytes=%lld\n", errno, tx_bytes);
            }
        }
        t = now_s();
        if (t >= next_report) {
            printf("SRC_T %.3f tx_MB=%.3f rx_MB=%.3f eof=%d CPU_FREQ_KHZ=%s\n",
                   t - t0, tx_bytes / 1048576.0, rx_bytes / 1048576.0, eof_seen,
                   p7baff_cpu_freq_khz().c_str());   // F9: 周期行尾频率轨迹 (追加, 旧字段一字不动)
            fflush(stdout);
            next_report = t + 1.0;
        }
    }
    double t1 = now_s();
    close(fd);
    printf("SRC_SUM tx_bytes=%lld rx_bytes=%lld dur_s=%.3f tx_Mbps=%.3f rx_Mbps=%.3f "
           "eof_seen=%d eof_at_s=%.3f send_err=%d rx_first_mismatch=%lld rx_mism_bytes=%lld "
           "poll_tmo=%lld poll_err=%lld partial_sends=%lld skip_bytes=%lld first_partial_at=%lld\n",
           tx_bytes, rx_bytes, t1 - t0, tx_bytes * 8.0 / (t1 - t0) / 1e6, rx_bytes * 8.0 / (t1 - t0) / 1e6,
           eof_seen, t_eof - t0, send_err, rx_first_mis, rx_mism_bytes,
           poll_tmo, poll_err, partial_sends, skip_bytes, first_partial_at);
    printf("SRC_DONE\n");
    return (send_err == 0 && tx_bytes > 0 && (!verify_down || rx_first_mis < 0)) ? 0 : 1;
}
