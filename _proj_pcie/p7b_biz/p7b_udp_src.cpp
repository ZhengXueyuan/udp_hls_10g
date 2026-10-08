// p7b_udp_src.cpp -- UDP 上行业务负载 (对端真实 Linux UDP 栈 -> 板 :8081)
//
// 被测对象: mac_rx_10g -> rx_classify -> udp_split(port 8081) -> app_udp_pattern 校验器
// 板侧可读口径 (P7B_10G 构建的 51 字窗口, 地址 = 0x20+4*W):
//   W10 udpapp_rx_frames  W11 udpapp_rx_bytes  W12 udpapp_rx_null  W13 udpapp_mismatch
//   W0/W1 MAC 收帧/字节   W3 FCS 错   W46/W47/W48/W49 rx_classify 拒写/停等/占用
//
// ⚠️ 板侧图案 LFSR **跨 datagram 连续** (不按 datagram 重置, i_en 恒 1:
//    board/wrapper_p4.v:2481) => 对端必须把发出的所有载荷当成**一条连续字节流**;
//    任何一帧被丢/被改 => 之后**永久失配** (W13 单调涨)。=> 本工具**先慢后快**两段
//    (--slow-mbps 段建立"W13 仍为 0"的对齐基线, 再切 --mbps 满速), 丢包与改字节
//    靠 ΔW11(收字节) 与对端实发字节之比区分 (方案 §4.4 判据 J7/J8)。
//
// 对端独立口径 (与板侧无关): 本工具自己打印 payload_bytes/时间; 另可用
//   ethtool -S enp1s0f1np1 | grep tx-           (对端 NIC 队列计数, 连续可读)
//
// 用法: p7b_udp_src --host 192.168.100.2 --port 8081 --seconds 20 --paylen 1472
//                    [--mbps 0(满速)|N] [--slow-mbps N --slow-secs S] [--batch 32] [--teach]
//
// ⭐ 2026-10-09 (R1/R2 用户要求落地): socket 一律 **非阻塞 + 电平触发 poll(LT)**。
//   * fd 建好立刻 `set_nonblock` (旧版**根本没设 O_NONBLOCK**, 只靠每次调用的 MSG_DONTWAIT);
//   * 发送队列满 (EAGAIN) ⇒ `poll(POLLOUT)` 电平触发等可写 (旧版是**盲等 200 µs** 循环);
//     poll 超时 = 确定语义 (计数 + 周期日志行 `UDP_POLL_TMO`, 不静默吞);
//   * 限速的 `nanosleep` 保留 —— 它是**节奏控制**, 不是 socket 等待 (与 poll 无关);
//   * ⛔ **本工具不写盘**: 每个 datagram 的载荷由 p7b_pattern.h **按规则现场生成**后直接发出,
//     没有任何文件读写 (无 tmp / 无 --dump 落盘开关)。
// 编译 (部署口径 = _proj_10g/notes/p7b_affinity/BUILD.md §2; ⛔ 别再用旧头注释里的 -O3 写法):
//   g++ -O3 -pthread -o p7b_udp_src p7b_udp_src.cpp
#include "p7b_pattern.h"
#include "p7b_affinity.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
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

// 电平触发地等可写; 返回 1=可写 0=超时 -1=出错 (errno 已置)。超时由调用者计数/打日志。
static int wait_writable(int fd, int ms) {
    struct pollfd p{fd, POLLOUT, 0};
    int pr;
    do { pr = poll(&p, 1, ms); } while (pr < 0 && errno == EINTR);
    return pr;
}

// 小消息的"发完"包装 (仅 --teach 用): poll(POLLOUT, LT) -> sendto, 容忍 EAGAIN。
// 返回已发字节数; <len 时 *stopped=1 (超时/出错, 由调用者打日志)。
static ssize_t send_all_wait(int fd, const void *buf, size_t len,
                             const struct sockaddr *sa, socklen_t sl, int ms,
                             int *stopped, int *why) {
    size_t off = 0;
    while (off < len) {
        int pr = wait_writable(fd, ms);
        if (pr == 0) { *stopped = 1; *why = ETIMEDOUT; break; }
        if (pr < 0)  { *stopped = 1; *why = errno; break; }
        ssize_t n = sendto(fd, (const char *)buf + off, len - off, MSG_DONTWAIT, sa, sl);
        if (n > 0) off += (size_t)n;
        else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) continue;
        else { *stopped = 1; *why = errno; break; }
    }
    return (ssize_t)off;
}

int main(int argc, char **argv) {
    argc = p7b_pin_cpu(argc, argv);      // 启动即绑核 (p7b_affinity.h; 剥离本函数自己的选项)
    const char *host = "192.168.100.2";
    int port = 8081, paylen = 1472, batch = 32, poll_ms = 1000;
    // ⚠️ 2026-09-30 修 (Stage 1 抓到的缺陷 ②): `--seconds` 与 `--slow-secs` 原来是 `int` + `atoi`
    //    ⇒ `--seconds 2.5` **静默截成 2** (段窗短 20%)。本工程的窗口纪律 (V1 = 2.0–2.5 s)
    //    全靠这个参数 ⇒ 必须 `double` + `strtod`。同理 `--mbps` 用 `strtod`。
    //    实证: `_proj_10g/notes/p7b_biz_s1/s1_3_udp_up.txt` 的段窗实测 2.000 s (计划 2.5)。
    double secs = 20.0, slow_secs = 0.0;
    double mbps = 0.0, slow_mbps = 0.0;
    long long off0 = 0;
    // ⭐ `--skip-at OFF`: **在流偏移 OFF 处故意丢掉 1 个 datagram 的载荷**(不发出, 但图案照常推进)。
    //    这是 J8/J9 的**可复算负对照** —— 替代已降级的 `--teach`:
    //      板侧把"少了一帧"的流按**连续**序列比对 ⇒ 从 OFF 起全部失配
    //      ⇒ 期望 `ΔW11 == S`(**无丢**, 因为我们自己没发) 且
    //             `ΔW13 ≈ (S − OFF) × (1 − 1/256)`(偶然命中 ≈1/256; 精确值离线复算)
    //    这条同时验证了 **W13 真的在数失配** 与 **它的量级口径**(不是个"通用值")。
    long long skip_at = -1;
    bool teach = false, selftest = false;
    for (int i = 1; i < argc; i++) {
        std::string k = argv[i];
        auto nx = [&]() -> const char * { if (++i >= argc) { fprintf(stderr, "missing %s\n", k.c_str()); exit(2); } return argv[i]; };
        if (k == "--host") host = nx();
        else if (k == "--port") port = atoi(nx());
        else if (k == "--seconds") secs = strtod(nx(), nullptr);
        else if (k == "--paylen") paylen = atoi(nx());
        else if (k == "--batch") batch = atoi(nx());
        else if (k == "--poll-ms") poll_ms = atoi(nx());
        else if (k == "--mbps") mbps = strtod(nx(), nullptr);
        else if (k == "--slow-mbps") slow_mbps = strtod(nx(), nullptr);
        else if (k == "--slow-secs") slow_secs = strtod(nx(), nullptr);
        else if (k == "--off") off0 = atoll(nx());
        else if (k == "--skip-at") skip_at = atoll(nx());
        else if (k == "--teach") teach = true;
        else if (k == "--selftest") selftest = true;
        else if (k == "--help") {
            printf("p7b_udp_src --host H [--port 8081] [--seconds S(可为小数)] [--paylen 1472]\n"
                   "            [--mbps 0|N(线上Mbps, 可小数)] [--slow-mbps N --slow-secs S]\n"
                   "            [--batch 32] [--off N] [--skip-at OFF] [--poll-ms 1000]\n"
                   "            [--skip-at OFF (⭐ 可复算负对照: 在流偏移 OFF 处丢 1 个 datagram)]\n"
                   "            [--teach (旧负对照: 重发同一段前缀 -> 只给'通用值', 已降级)]\n"
                   "  --mbps 0 = 满速; 载荷流从 --off 起 (重烧后应为 0)\n");
            return 0;
        } else { fprintf(stderr, "unknown arg %s\n", k.c_str()); return 2; }
    }
    if (selftest) return p7b_pattern_selftest("p7b_udp_src");
    if (paylen < 1 || paylen > 1472) { fprintf(stderr, "--paylen 1..1472 (MTU1500)\n"); return 2; }
    if (batch < 1) batch = 1;
    if (poll_ms < 1) poll_ms = 1;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket"); return 2; }
    set_nonblock(fd);                    // ⭐ R1: socket() 之后立刻设, 且全程不切回阻塞
    int snd = 8 << 20; setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, sizeof(snd));
    struct sockaddr_in a{};
    a.sin_family = AF_INET; a.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &a.sin_addr) != 1) { fprintf(stderr, "bad host\n"); return 2; }

    P7bPat pat((uint64_t)off0);
    std::vector<std::vector<uint8_t>> pl(batch, std::vector<uint8_t>(paylen));
    std::vector<struct mmsghdr> mm(batch);
    std::vector<struct iovec> iv(batch);

    // --teach: 负对照。把**同一段 100 B 前缀**重发 20 次 => 板侧只走一次 LFSR =>
    // W13 应恰好等于"首 100 B 之后收到的全部字节数" (RATE 轮实测 0x7C7 = 1991)
    if (teach) {
        int n = 100, reps = 20, stopped = 0, why = 0;
        std::vector<uint8_t> pre(n);
        P7bPat tp(0); tp.fill(pre.data(), n);
        for (int r = 0; r < reps; r++) {
            // ⭐ R1: 非阻塞 + poll(POLLOUT, LT) 等可写; 超时/出错**响亮**(stopped=1 + why)
            ssize_t s = send_all_wait(fd, pre.data(), pre.size(),
                                      (struct sockaddr *)&a, sizeof(a), poll_ms, &stopped, &why);
            printf("TEACH_SEND r=%d n=%zd stopped=%d why=%d\n", r, s, stopped, why);
            if (stopped) break;
        }
        printf("TEACH_DONE reps=%d paylen=%d off_after_expect=%d stopped=%d\n", reps, n, n, stopped);
        return stopped ? 1 : 0;
    }

    double t0 = now_s(), t_end = t0 + secs, t_switch = t0 + slow_secs;
    double t_next_rep = t0 + 1.0;
    long long pkts = 0, bytes = 0, call_errors = 0, poll_tmo = 0;
    long long skip_pkts = 0, skip_bytes = 0, skip_actual = -1;
    double next_ok = t0;                 // 限速用的"理论最早下一拍"
    for (;;) {
        double t = now_s();
        if (t >= t_end) break;
        double lim = (t < t_switch) ? slow_mbps : mbps;   // Mbps (0 = 满速)
        if (lim > 0) {
            // ⚠️ 这里的 nanosleep 是**节奏控制**(限速), 不是 socket 等待 —— R1 不适用
            if (t < next_ok) { struct timespec ts{(time_t)0, (long)((next_ok - t) * 1e9)}; nanosleep(&ts, nullptr); t = now_s(); if (t >= t_end) break; }
        }
        // ⭐ --skip-at: 跨过阈值就**丢一个 datagram** (图案推进但不发) —— 只在第一次
        if (skip_at >= 0 && skip_pkts == 0 && (off0 + bytes + skip_bytes) >= skip_at) {
            std::vector<uint8_t> tmp((size_t)paylen);
            pat.fill(tmp.data(), (size_t)paylen);
            skip_pkts = 1; skip_bytes = paylen;
            skip_actual = off0 + bytes;
            printf("SKIP_ONE at_off=%lld (requested=%lld) paylen=%d  (图案已推进, 未发出)\n",
                   skip_actual, skip_at, paylen);
            fflush(stdout);
        }
        for (int i = 0; i < batch; i++) {
            pat.fill(pl[i].data(), (size_t)paylen);
            iv[i].iov_base = pl[i].data();
            iv[i].iov_len = (size_t)paylen;
            mm[i].msg_hdr.msg_iov = &iv[i];
            mm[i].msg_hdr.msg_iovlen = 1;
            mm[i].msg_hdr.msg_name = &a;
            mm[i].msg_hdr.msg_namelen = sizeof(a);
            mm[i].msg_len = 0;
        }
        int r = sendmmsg(fd, mm.data(), (unsigned)batch, MSG_DONTWAIT);
        if (r > 0) {
            pkts += r; bytes += (long long)r * paylen;
            if (lim > 0) next_ok = t + (double)r * (paylen + 42) * 8.0 / (lim * 1e6);
            else        next_ok = t;
        } else if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            // ⭐ R1: 发送队列满 ⇒ poll(POLLOUT) 电平触发等可写 (旧版 = 盲等 200 µs 轮询)
            int pr = wait_writable(fd, poll_ms);
            if (pr == 0) {                   // ⭐ 超时 = 确定语义 (计数 + 首次/每 1000 次打一行)
                poll_tmo++;
                if (poll_tmo <= 5 || poll_tmo % 1000 == 0)
                    printf("UDP_POLL_TMO %lld: 发送队列 %d ms 不可写 (对端不在收?)\n", poll_tmo, poll_ms);
            } else if (pr < 0 && errno != EINTR) {
                call_errors++; if (call_errors < 5) printf("SEND_POLL_ERR errno=%d\n", errno);
                if (call_errors > 1000) break;
            }
        } else { call_errors++; if (call_errors < 5) printf("SEND_ERR errno=%d\n", errno); if (call_errors > 1000) break; }
        t = now_s();
        if (t >= t_next_rep) {
            printf("UDP_T %.3f pkts=%lld pay_MB=%.3f pps=%.0f Mbps=%.3f (limit=%.1f) CPU_FREQ_KHZ=%s\n",
                   t - t0, pkts, bytes / 1048576.0, pkts / (t - t0), bytes * 8.0 / (t - t0) / 1e6, lim,
                   p7baff_cpu_freq_khz().c_str());   // F9: 周期行尾频率轨迹 (追加, 旧字段一字不动)
            fflush(stdout);
            t_next_rep = t + 1.0;
        }
    }
    double dur = now_s() - t0;
    printf("UDP_SUM pkts=%lld pay_bytes=%lld dur_s=%.3f pps=%.0f pay_Mbps=%.3f wire_Mbps=%.3f "
           "off_start=%lld off_end=%lld call_errors=%lld poll_tmo=%lld skip_pkts=%lld skip_bytes=%lld skip_actual_off=%lld\n",
           pkts, bytes, dur, pkts / dur, bytes * 8.0 / dur / 1e6,
           (bytes + pkts * 42.0) * 8.0 / dur / 1e6, off0, off0 + bytes + skip_bytes, call_errors,
           poll_tmo, skip_pkts, skip_bytes, skip_actual);
    // ⚠️ `off_end` **含**被丢掉的那一帧的载荷 (它是"流上推进过的字节", 不是"发出去的字节")
    //    ⇒ 段间接力时用它是对的 (下一段的 --off 要接上图案流的位置, 不是接上已发字节)。
    printf("UDP_DONE\n");
    return 0;
}
