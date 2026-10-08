// ===========================================================================
// p7b_io.h -- P7b 台架的公共**机制**头 (2026-10-09)
//
// 动因 (计划"改动 1: 抽公共模块 —— 机制 ≠ 策略"): 这些机制在 7 个 .cpp 里**逐字重复**过 ——
//   now_s() 5 份 · set_nonblock() 5 份逐字相同 · connect_nb() 4 份逐字相同 ·
//   每秒报告节流 (`next_report = t + 1.0` + fflush) 5 份逐字相同 · EAGAIN/EWOULDBLOCK/EINTR
//   容忍判定 5 处。防漏改此前靠 `grep` 而不是编译器 ⇒ 抽到这里。
//
// ---------------------------------------------------------------------------
// ⛔ 边界 (抽了就会错的东西, 一律**不进**本头):
//   1. **三种 send 语义必须并存**: `SRC` 重填重发 / `FIX` ppos 续发 / `DIAG` 旧行为。
//      本头只提供 `p7b_io_send_all_wait` (逐次等可写直到发完) —— **只有 UDP 会调**;
//      ⛔⛔ `p7b_tcp_src_diag` **永远不 include 本头**: 它的负对照性完全依赖那一处旧 send
//      (p7b_tcp_src_diag.cpp:151-152 = `fill(全块) + send(全块)`, 故意保留旧行为)。一旦把它
//      接上抽出的 send-all/ppos 语义 (**哪怕只是"顺手统一"**), 它会**静默变成正对照臂**
//      (跟着 FIX 一起变好 ⇒ A/B 判别力归零) —— 而且**没有任何判据会报警** (它照样打
//      `SRC_DONE`、照样退 0)。
//   2. **"生成"这一步必须可替换**: `FIX:152` (tx.fill) / `RATE:150` (memset 0xA5) /
//      `UDP:189` (逐 datagram fill) 是**三种填充** ⇒ 本头**不定实现**, 一个生成函数都不提供。
//   3. `--chunk` 的**三重身份** (生成粒度 = send 粒度 = 缓冲大小, 默认 65536) **不得改**。
//   4. 判据口径 (bad_conns / 退出码三条件 / `CHECK=off` 降级 / `eof_at_s` 负值是既存口径)
//      —— 全是**策略**, 不进本头。
//   5. `p7b_affinity.h` 的绑核**不进本头** (它有自己的头, 且已被板级验证过)。
//
// ---------------------------------------------------------------------------
// 命名: 全部 `p7b_io_` 前缀 —— 目的是**永远不会与各 .cpp 里既有的 static 同名函数冲突**
//   (未改的发送族仍各自留着自己的 `static double now_s()` 等; 它们不 include 本头)。
//
// socket 契约 (与 R1/R2 轮同款, 一字不改): **全程序只有一处 fcntl** ——
//   `p7b_io_set_nonblock` 只置 O_NONBLOCK, **从不切回阻塞**; 一切 recv/connect 都发生在
//   poll() 之后, 且容忍 EAGAIN (非阻塞语义的正证据)。
// ===========================================================================
#ifndef P7B_IO_H
#define P7B_IO_H

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

// ---------------------------------------------------------------------------
// 时钟 (逐字取自 p7b_tcp_sink.cpp:44-48 = 5 份重复里的最老一份)
// ---------------------------------------------------------------------------
static inline double p7b_io_now_s() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

// 致命错 (逐字取自 p7b_tcp_sink.cpp:50): perror + exit(2) (全族惯例: 2 = 用法/环境错)
static inline void p7b_io_die(const char *m) { perror(m); exit(2); }

// ---------------------------------------------------------------------------
// socket 契约: 全程序**只有这一处 fcntl** —— 只置 O_NONBLOCK, 从不切回阻塞
// (grep 判据: `grep -n "F_SETFL" *.cpp *.h` 只应命中本函数; 出现清 O_NONBLOCK 即违规)
// ---------------------------------------------------------------------------
static inline void p7b_io_set_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) p7b_io_die("fcntl(O_NONBLOCK)");
    if (!(fcntl(fd, F_GETFL, 0) & O_NONBLOCK)) {
        fprintf(stderr, "FATAL: O_NONBLOCK 未生效\n");
        exit(2);
    }
}

// EAGAIN / EWOULDBLOCK / EINTR 容忍判定 (5 处逐字重复的归一化; 保留**逐项**写法以免
// 某些平台上 EAGAIN == EWOULDBLOCK 的告警, 且让"哪一项被容忍"在源码里可读)
static inline bool p7b_io_retryable(int e) {
    return e == EAGAIN || e == EWOULDBLOCK || e == EINTR;
}

// ---------------------------------------------------------------------------
// 非阻塞 connect: EINPROGRESS -> poll(POLLOUT, 电平触发) -> SO_ERROR。
// 成功 0 / 失败 -1 且 *why = 原因码 (ETIMEDOUT 或 errno / SO_ERROR)。超时**不静默**:
// 调用者必须把 why 打进日志 (SINK_CONN ... FAIL_CONNECT why=...)。
// (逐字取自 p7b_tcp_sink.cpp:64-78)
// ---------------------------------------------------------------------------
static inline int p7b_io_connect_nb(int fd, const struct sockaddr *sa, socklen_t sl,
                                    int timeout_ms, int *why) {
    int r = connect(fd, sa, sl);
    if (r < 0 && errno != EINPROGRESS) { *why = errno; return -1; }
    if (r < 0) {                                  // EINPROGRESS: 等可写 (或出错)
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

// (逐字取自 p7b_tcp_sink.cpp:80-90) 成功 => fd (O_NONBLOCK); 失败 => -1 且 *why 有值
static inline int p7b_io_connect_to(const char *host, int port, int secs, int *why) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { *why = errno; return -1; }
    struct sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &a.sin_addr) != 1) { *why = EINVAL; close(fd); return -1; }
    p7b_io_set_nonblock(fd);                      // ⭐ socket() 之后立刻设, 且**不再切回**
    if (p7b_io_connect_nb(fd, (struct sockaddr *)&a, sizeof(a), secs * 1000, why) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

// ---------------------------------------------------------------------------
// 等待原语 (电平触发 = 默认语义; ⛔ 无 EPOLLET / 无 select)
// ---------------------------------------------------------------------------
// 等可读; 返回 poll 的返回值 (1=可读 0=超时 -1=出错, errno 已置); EINTR 内部重试
//   `rev` 非空时回带 revents (调用者要查 POLLNVAL 之类就靠它)
static inline int p7b_io_poll_readable_ev(int fd, int ms, short *rev) {
    struct pollfd p{fd, POLLIN, 0};
    int pr;
    do { pr = poll(&p, 1, ms); } while (pr < 0 && errno == EINTR);
    if (rev) *rev = (pr > 0) ? p.revents : 0;
    return pr;
}

static inline int p7b_io_poll_readable(int fd, int ms) {
    return p7b_io_poll_readable_ev(fd, ms, NULL);
}

// 电平触发地等可写; 返回 1=可写 0=超时 -1=出错 (errno 已置)。超时由调用者计数/打日志。
static inline int p7b_io_wait_writable(int fd, int ms) {
    struct pollfd p{fd, POLLOUT, 0};
    int pr;
    do { pr = poll(&p, 1, ms); } while (pr < 0 && errno == EINTR);
    return pr;
}

// 小消息的"发完"包装 (**仅 UDP 用**; 逐字取自 p7b_udp_src.cpp:69-83):
// poll(POLLOUT, LT) -> sendto, 容忍 EAGAIN。返回已发字节数; <len 时 *stopped=1。
static inline ssize_t p7b_io_send_all_wait(int fd, const void *buf, size_t len,
                                           const struct sockaddr *sa, socklen_t sl, int ms,
                                           int *stopped, int *why) {
    size_t off = 0;
    while (off < len) {
        int pr = p7b_io_wait_writable(fd, ms);
        if (pr == 0) { *stopped = 1; *why = ETIMEDOUT; break; }
        if (pr < 0)  { *stopped = 1; *why = errno; break; }
        ssize_t n = sendto(fd, (const char *)buf + off, len - off, MSG_DONTWAIT, sa, sl);
        if (n > 0) off += (size_t)n;
        else if (n < 0 && p7b_io_retryable(errno)) continue;
        else { *stopped = 1; *why = errno; break; }
    }
    return (ssize_t)off;
}

// ---------------------------------------------------------------------------
// 每秒报告节流 (**有状态** —— 这是它抽出来的理由: 5 份逐字相同的 `next_report = t + 1.0`)
//   用法: p7b_io_reporter r; r.start(t0);
//         ...
//         double t = p7b_io_now_s();
//         if (r.due(t)) { printf(...); fflush(stdout); r.mark(t); }
//   ⚠️ 语义与原逐字实现一致: **下一拍 = 本拍 + 1.0** (不是 t0 + k), 且调用者必须自己
//      fflush(stdout) (下拍读日志的人才能看见 —— 旧实现每处都打了 fflush, 别丢)。
// ---------------------------------------------------------------------------
struct P7bIoReporter {
    double t0 = 0.0;
    double next = 0.0;
    double interval = 1.0;                     // 秒
    void start(double t) { t0 = t; next = t + interval; }
    bool due(double t) const { return t >= next; }
    void mark(double t) { next = t + interval; }
    double since(double t) const { return t - t0; }
};

#endif  // P7B_IO_H
