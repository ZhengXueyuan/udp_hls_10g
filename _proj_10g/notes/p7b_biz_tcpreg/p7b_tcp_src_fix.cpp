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
//                    [--pace-bps 0] [--no-verify-down]
// 输出行 SRC_* / SRC_SUM_* / SRC_DONE; 退出码 0 = 上行无 send 错且(若开核对)下行逐字节干净。
//
// 编译: g++ -O3 -std=c++17 -o p7b_tcp_src p7b_tcp_src.cpp
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
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv) {
    argc = p7b_pin_cpu(argc, argv);      // 启动即绑核 (p7b_affinity.h; 剥离本函数自己的选项)
    const char *host = "192.168.100.2";
    int port = 8080, secs = 30, chunk = 65536;
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
        else if (k == "--no-verify-down") verify_down = false;
        else if (k == "--selftest") selftest = true;
        else if (k == "--help") {
            printf("p7b_tcp_src --host H --port P [--seconds S] [--chunk B] [--pace-bps BPS]\n"
                   "  上行: 从连接起点偏移 0 起连续图案流, 灌到板子 (板侧 rcvbuf/窗口自然限速)\n"
                   "  下行: 同一连接上核对板子的 1MB 图案流 (可用 --no-verify-down 关)\n"
                   "  --selftest: 图案自检向量\n");
            return 0;
        } else { fprintf(stderr, "unknown arg %s\n", k.c_str()); return 2; }
    }
    if (selftest) return p7b_pattern_selftest("p7b_tcp_src");

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 2; }
    struct sockaddr_in a{};
    a.sin_family = AF_INET; a.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &a.sin_addr) != 1) { fprintf(stderr, "bad host\n"); return 2; }
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { perror("connect"); return 2; }
    printf("SRC_CONNECTED %s:%d\n", host, port);
    if (pace > 0) setsockopt(fd, SOL_SOCKET, SO_MAX_PACING_RATE, &pace, sizeof(pace));
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);

    P7bPat tx(0);                 // 上行: 每连接偏移 0 起
    P7bPat rx(0);                 // 下行: 板侧每连接偏移 0 起
    std::vector<uint8_t> sbuf(chunk), rbuf(1 << 20);
    size_t ppos = (size_t)chunk;   // FIX(WU_LOOP): 上一块**已发出**的字节数 (>=chunk 表示需要重填)
    long long partial_sends = 0, rewraps = 0;  // FIX(WU_LOOP): 诊断计数
    long long tx_bytes = 0, rx_bytes = 0, rx_mism_bytes = 0, rx_first_mis = -1;
    double t0 = now_s(), t_eof = 0;
    int eof_seen = 0, send_err = 0;
    double next_report = t0 + 1.0;

    while (now_s() - t0 < secs) {
        struct pollfd p{fd, 0, 0};
        p.events = POLLIN;
        if (!send_err) p.events |= POLLOUT;
        int pr = poll(&p, 1, 200);
        double t = now_s();
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
            if (ppos >= (size_t)chunk) { tx.fill(sbuf.data(), (size_t)chunk); ppos = 0; rewraps++; }  // FIX: 上一块**发完**才重填 => 图案不跳
            ssize_t n = send(fd, sbuf.data() + ppos, (size_t)chunk - ppos, MSG_NOSIGNAL);
            if (n > 0) { if ((size_t)n < (size_t)chunk - ppos) partial_sends++; ppos += (size_t)n; tx_bytes += n; }
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
           "eof_seen=%d eof_at_s=%.3f send_err=%d rx_first_mismatch=%lld rx_mism_bytes=%lld partial_sends=%lld rewraps=%lld\n",
           tx_bytes, rx_bytes, t1 - t0, tx_bytes * 8.0 / (t1 - t0) / 1e6, rx_bytes * 8.0 / (t1 - t0) / 1e6,
           eof_seen, t_eof - t0, send_err, rx_first_mis, rx_mism_bytes,
           partial_sends, rewraps);
    printf("SRC_DONE\n");
    return (send_err == 0 && tx_bytes > 0 && (!verify_down || rx_first_mis < 0)) ? 0 : 1;
}
