// p7b_rate2_bench.cpp -- 台架"**天花板**"台 (2026-10-09 双线程样板配套仪器)
//
// 为什么要它 (计划"改动 2 / 验证表"): 把 sink 拆成两线程只把瓶颈**搬家** —— 新的台架上限
//   = min(recv 天花板, 校验天花板)。两个数**都必须现测, 不许假设** (风险 1)。
//   本工具在**回环**上把三个环节分开量 (⛔ 不碰板子 / 不发板级流量):
//     check-only        : 纯校验 (内存喂; P7bPat::check 逐字节复算)        => 校验天花板
//     send-discard      : 发送 + 丢弃接收 => **本机回环 socket 的带宽上界** (sender 是不是帽子)
//     recv-only         : 只 recv 不计 (旧 `--nocheck` 变体的等价物)        => 接收天花板
//     recv-check        : recv + 就地逐字节校验 (**旧单线程模型**)
//     recv-check-split  : recv 线程 + 校验线程 + 两条 SPSC 队列 (**新双线程模型**)
//   全程同一条回环链路、同一块图案缓冲、同一套槽池 ⇒ 五个数是**同会话可比**的。
//   ⚠️ 口径: 两端在**同一台机器**上 (回环), 发送侧也要 CPU ⇒ 这是"本机回环台架"的天花板,
//      不是被测件的天花板; 但它正是判"新台架自身顶在哪里"要用的那把尺子。
//   ⚠️ 校验的输入全部**匹配** (发送的正是图案流) ⇒ 与真跑同一分支形态 (不靠"失配更快/更慢"骗数)。
//
// 编译 (部署口径同 BUILD.md §2): g++ -O3 -pthread -o p7b_rate2_bench p7b_rate2_bench.cpp
//
// 用法:
//   ./p7b_rate2_bench --mode check-only   [--bytes 536870912] [--check seq|lane8]
//   ./p7b_rate2_bench --mode send-discard|recv-only|recv-check|recv-check-split
//                     [--bytes 536870912] [--slots 16] [--slot-bytes 65536]
//                     [--core-send N] [--core-io N] [--core-work N]     (-1 = 不绑)
//   ./p7b_rate2_bench --selftest | --selftest-equiv     (不跑台架, 只自检)
// 输出: BENCH <mode> bytes=.. sec=.. Gbps=.. Mbps=..  + 形态字段 (逐行 KEY=VALUE, 便于判据)
//
// ⭐ 2026-10-09 (R1/R4 轮): `--check seq|lane8` —— **默认 seq** (旧口径, 历史读数可比);
//   lane8 = M^8 8 字节/步 (p7b_pattern.h; 逐位等价由 --selftest-equiv 自证)。
//   生效值打进 BENCH 行尾 (`check=<seq|lane8>`) 与一行 `BENCH_CHECK` 见证 (参数生效的正证据)。
// ⭐ 2026-10-09 (R2 轮): report 行的 `CPU_FREQ_KHZ` 改取**工作线程自采样**值
//   (旧值是打行那条线程 = 主线程, 整段在 join 上待着 ⇒ 读到空闲核 800 MHz; 见 p7b_affinity.h)。
#include "p7b_pattern.h"
#include "p7b_affinity.h"
#include "p7b_io.h"
#include "p7b_spsc.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

static const char *MODE = "check-only";
static long long BYTES = 512LL << 20;
static int NSLOTS = 16;
static long SLOTB = 64L << 10;
static int C_SEND = -1, C_IO = -1, C_WORK = -1;
static int POLL_MS = 2000;

// --------------------------------------------------------------------------
// 发送侧: 把整块图案流**一次性**推出去 (非阻塞 + poll(POLLOUT))
// --------------------------------------------------------------------------
struct BlastArgs { int fd; const uint8_t *buf; long long len; int cpu; std::atomic<long long> sent{0}; int err{0}; };

static void *blast_main(void *arg) {
    BlastArgs *a = (BlastArgs *)arg;
    p7baff_pin_self_thread("send", a->cpu, a->cpu >= 0);
    long long off = 0;
    while (off < a->len) {
        ssize_t n = send(a->fd, a->buf + off, (size_t)(a->len - off), MSG_NOSIGNAL);
        if (n > 0) { p7baff_work_freq_tick(); off += n; continue; }
        if (n < 0 && p7b_io_retryable(errno)) {
            int pr = p7b_io_wait_writable(a->fd, POLL_MS);
            if (pr < 0) { a->err = errno; break; }
            continue;
        }
        a->err = errno;
        break;
    }
    a->sent.store(off, std::memory_order_release);
    shutdown(a->fd, SHUT_WR);              // 等价于对端 FIN
    return NULL;
}

// --------------------------------------------------------------------------
// 接收侧三种模型 (内存喂/回环同款)
// --------------------------------------------------------------------------
struct RecvCtl {
    int fd;
    long long got = 0;                  // 只管"收到多少"(接收侧自己的账)
    long long checked = 0, mism = 0, first_mis = -1;
    unsigned long long spins = 0;
    std::atomic<int> io_done{0};
};

// recv-only: 只收不计 (天花板臂)
static void *recv_only_main(void *arg) {
    RecvCtl *c = (RecvCtl *)arg;
    p7baff_pin_self_thread("io", C_IO, C_IO >= 0);
    std::vector<uint8_t> buf((size_t)SLOTB);
    for (;;) {
        int pr = p7b_io_poll_readable(c->fd, POLL_MS);
        if (pr <= 0) break;
        ssize_t n = recv(c->fd, buf.data(), buf.size(), 0);
        if (n < 0) { if (p7b_io_retryable(errno)) continue; break; }
        if (n == 0) break;
        p7baff_work_freq_tick();                        // ⭐ R2: 本线程自采样
        c->got += n;
    }
    c->io_done.store(1, std::memory_order_release);
    return NULL;
}

// recv-check (旧单线程模型): 同一线程 recv 后**就地**逐字节校验
static void *recv_check_main(void *arg) {
    RecvCtl *c = (RecvCtl *)arg;
    p7baff_pin_self_thread("io", C_IO, C_IO >= 0);
    std::vector<uint8_t> buf((size_t)SLOTB);
    P7bPat pat(0);
    for (;;) {
        int pr = p7b_io_poll_readable(c->fd, POLL_MS);
        if (pr <= 0) break;
        ssize_t n = recv(c->fd, buf.data(), buf.size(), 0);
        if (n < 0) { if (p7b_io_retryable(errno)) continue; break; }
        if (n == 0) break;
        p7baff_work_freq_tick();                        // ⭐ R2: 本线程自采样
        c->got += n;
        uint64_t nm = 0;
        long long f = pat.check(buf.data(), (size_t)n, &nm);
        if (f >= 0) { if (c->first_mis < 0) c->first_mis = c->got - n + f; c->mism += (long long)nm; }
        c->checked += n;
    }
    c->io_done.store(1, std::memory_order_release);
    return NULL;
}

// recv-check-split (新双线程模型): I/O 线程 recv 进槽 -> SPSC -> 校验线程
struct SinkItemX { int slot; long long base; size_t len; };   // 与 p7b_tcp_sink.cpp 同构

struct SplitCtl {
    RecvCtl *rc;
    size_t slot_bytes;
    std::vector<std::vector<uint8_t> > slots;
    P7bSpscRing<SinkItemX> *full, *freeq;
};

struct SplitIoArgs { SplitCtl *c; };
struct SplitCkArgs { SplitCtl *c; };

// ⚠️ SPSC 合同 (与 p7b_tcp_sink.cpp 同款, TSan 抓出后统一): `full` 的生产者**只有** I/O 线程,
//    `freeq` 的生产者**只有**校验线程 ⇒ I/O 线程让出槽时**推一个 len==0 的"只还槽"元素进 full**,
//    由校验线程把槽推回 free (⛔ 旧版在退出路径上直接 freeq->push = 双生产者 = 真缺陷)。
static void *split_io_main(void *arg) {
    SplitCtl *c = ((SplitIoArgs *)arg)->c;
    p7baff_pin_self_thread("io", C_IO, C_IO >= 0);
    SinkItemX it;
    int held = -1;
    for (;;) {
        int pr = p7b_io_poll_readable(c->rc->fd, POLL_MS);
        if (pr <= 0) break;
        if (held < 0) {
            while (!c->freeq->pop(it)) { c->rc->spins++; sched_yield(); }
            held = it.slot;
        }
        ssize_t n = recv(c->rc->fd, c->slots[(size_t)held].data(), c->slot_bytes, 0);
        if (n < 0) {
            if (p7b_io_retryable(errno)) continue;      // 槽继续握着
            break;
        }
        if (n == 0) break;                              // FIN; 槽在收尾处交还
        p7baff_work_freq_tick();                        // ⭐ R2: 本线程自采样
        SinkItemX out{held, c->rc->got, (size_t)n};
        while (!c->full->push(out)) sched_yield();      // 容量 >= 槽数 => 实测不可能
        c->rc->got += n;
        held = -1;
    }
    if (held >= 0) { SinkItemX back{held, 0, 0}; while (!c->full->push(back)) sched_yield(); }
    c->rc->io_done.store(1, std::memory_order_release);
    return NULL;
}

static void *split_ck_main(void *arg) {
    SplitCtl *c = ((SplitCkArgs *)arg)->c;
    p7baff_pin_self_thread("work", C_WORK, C_WORK >= 0);
    P7bPat pat(0);
    SinkItemX it;
    for (;;) {
        bool have = c->full->pop(it);
        if (!have && c->rc->io_done.load(std::memory_order_acquire)) {
            have = c->full->pop(it);
            if (!have) break;
        }
        if (!have) { sched_yield(); continue; }
        if (it.len > 0) {                               // len==0 = 只还槽 (不进图案流)
            uint64_t nm = 0;
            long long f = pat.check(c->slots[(size_t)it.slot].data(), it.len, &nm);
            if (f >= 0) { if (c->rc->first_mis < 0) c->rc->first_mis = it.base + f; c->rc->mism += (long long)nm; }
            c->rc->checked += (long long)it.len;
            p7baff_work_freq_tick();                    // ⭐ R2: 校验线程自采样
        }
        c->freeq->push(it);
    }
    return NULL;
}

// --------------------------------------------------------------------------
int main(int argc, char **argv) {
    argc = p7b_pin_cpu(argc, argv);            // 主线程照样绑核 (见证行与老台架同款)
    for (int i = 1; i < argc; i++) {
        std::string k = argv[i];
        auto nx = [&]() -> const char * { if (++i >= argc) { fprintf(stderr, "missing %s\n", k.c_str()); exit(2); } return argv[i]; };
        if (k == "--mode") MODE = nx();
        else if (k == "--bytes") BYTES = atoll(nx());
        else if (k == "--slots") NSLOTS = atoi(nx());
        else if (k == "--slot-bytes") SLOTB = atol(nx());
        else if (k == "--core-send") C_SEND = atoi(nx());
        else if (k == "--core-io") C_IO = atoi(nx());
        else if (k == "--core-work") C_WORK = atoi(nx());
        else if (k == "--poll-ms") POLL_MS = atoi(nx());
        else if (k == "--check") {                       // ⭐ R1: 校验路径开关 (默认 seq)
            const char *v = nx();
            if (p7b_check_mode_parse(v) != 0) {
                fprintf(stderr, "unknown --check '%s' (seq|lane8)\n", v);
                return 2;                                // ⛔ 不许静默回落到默认
            }
        }
        else if (k == "--selftest") return p7b_pattern_selftest("p7b_rate2_bench");
        else if (k == "--selftest-equiv") return p7b_pattern_equiv_selftest("p7b_rate2_bench");
        else if (k == "--help") {
            printf("p7b_rate2_bench --mode check-only|send-discard|recv-only|recv-check|recv-check-split\n"
                   "                [--bytes N] [--slots N] [--slot-bytes N] [--check seq|lane8]\n"
                   "                [--core-send N --core-io N --core-work N]   (-1 = 不绑)\n"
                   "                --selftest | --selftest-equiv\n"
                   "  check: seq = 逐字节 (**默认**, 历史读数口径); lane8 = M^8 8 字节/步\n");
            return 0;
        } else { fprintf(stderr, "unknown arg %s\n", k.c_str()); return 2; }
    }
    if (BYTES < (1 << 20)) BYTES = 1 << 20;
    printf("BENCH_CHECK check=%s (seq = 逐字节 / 默认; lane8 = M^8 8 字节/步, 逐位等价)\n",
           p7b_check_mode_name());
    fflush(stdout);
    if (NSLOTS < 2) NSLOTS = 2;
    if (SLOTB < 1) SLOTB = 1;

    // ---- 图案缓冲: **发送的就是图案流本身** => 校验输入全匹配 (与真跑同一分支形态) ----
    std::vector<uint8_t> patbuf((size_t)BYTES);
    {
        double g0 = p7b_io_now_s();
        P7bPat g(0);
        for (long long off = 0; off < BYTES; off += (1 << 22)) {   // 4 MiB 一块, 省一次函数开销
            long long k = BYTES - off; if (k > (1 << 22)) k = (1 << 22);
            g.fill(patbuf.data() + off, (size_t)k);
        }
        printf("BENCH_GEN bytes=%lld gen_s=%.3f gen_GBs=%.3f\n", BYTES, p7b_io_now_s() - g0,
               BYTES / (p7b_io_now_s() - g0) / 1e9);
        fflush(stdout);
    }

    // ---- check-only: 纯校验天花板 (内存喂) ----
    if (std::string(MODE) == "check-only") {
        P7bPat pat(0);
        double t0 = p7b_io_now_s();
        uint64_t nm = 0;
        long long f = pat.check(patbuf.data(), (size_t)BYTES, &nm);
        double dt = p7b_io_now_s() - t0;
        printf("BENCH check-only bytes=%lld sec=%.6f Gbps=%.4f Mbps=%.2f first_mismatch=%lld mism_bytes=%llu"
               " check=%s CPU_FREQ_KHZ=%s\n",
               BYTES, dt, BYTES * 8.0 / dt / 1e9, BYTES * 8.0 / dt / 1e6, f, (unsigned long long)nm,
               p7b_check_mode_name(), p7baff_work_freq_khz().c_str());
        return 0;
    }

    // ---- 回环 TCP 对 (两端在同一台机器: **本机回环台架**的口径) ----
    int ls = socket(AF_INET, SOCK_STREAM, 0);
    if (ls < 0) p7b_io_die("socket(listen)");
    int one = 1; setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a{};
    a.sin_family = AF_INET; a.sin_port = htons(0);
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    if (bind(ls, (struct sockaddr *)&a, sizeof(a)) != 0) p7b_io_die("bind");
    if (listen(ls, 1) != 0) p7b_io_die("listen");
    socklen_t al = sizeof(a);
    if (getsockname(ls, (struct sockaddr *)&a, &al) != 0) p7b_io_die("getsockname");
    int sfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sfd < 0) p7b_io_die("socket(send)");
    int bufsz = 8 << 20;
    setsockopt(sfd, SOL_SOCKET, SO_SNDBUF, &bufsz, sizeof(bufsz));
    p7b_io_set_nonblock(sfd);
    int why = 0;
    if (p7b_io_connect_nb(sfd, (struct sockaddr *)&a, sizeof(a), 5000, &why) < 0) {
        fprintf(stderr, "connect_nb why=%d\n", why); exit(2);
    }
    int rfd = accept(ls, NULL, NULL);
    if (rfd < 0) p7b_io_die("accept");
    close(ls);
    setsockopt(rfd, SOL_SOCKET, SO_RCVBUF, &bufsz, sizeof(bufsz));
    p7b_io_set_nonblock(rfd);
    int nodelay = 1; setsockopt(rfd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
    setsockopt(sfd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));

    RecvCtl rc; rc.fd = rfd;
    BlastArgs ba{sfd, patbuf.data(), BYTES, C_SEND, {}, 0};
    pthread_t tsend = 0, trx = 0, tck = 0;
    SplitCtl sc;
    // ⚠️ 队列必须活到线程 join 之后 => 放外层 (曾经放在分支块里 => 线程踩悬垂指针 SIGSEGV)
    std::unique_ptr<P7bSpscRing<SinkItemX> > q_full, q_free;

    double t0 = p7b_io_now_s();
    if (pthread_create(&tsend, NULL, blast_main, &ba) != 0) p7b_io_die("pthread_create(send)");
    std::string m = MODE;
    if (m == "send-discard") {
        // 接收只丢弃 (不与发送争同一线程; 这里就用主线程丢弃, 主线程已绑核)
        std::vector<uint8_t> buf((size_t)SLOTB);
        for (;;) {
            int pr = p7b_io_poll_readable(rfd, POLL_MS);
            if (pr <= 0) break;
            ssize_t n = recv(rfd, buf.data(), buf.size(), 0);
            if (n < 0) { if (p7b_io_retryable(errno)) continue; break; }
            if (n == 0) break;
            rc.got += n;
        }
    } else if (m == "recv-only") {
        if (pthread_create(&trx, NULL, recv_only_main, &rc) != 0) p7b_io_die("pthread_create(rx)");
    } else if (m == "recv-check") {
        if (pthread_create(&trx, NULL, recv_check_main, &rc) != 0) p7b_io_die("pthread_create(rx)");
    } else if (m == "recv-check-split") {
        sc.rc = &rc; sc.slot_bytes = (size_t)SLOTB;
        sc.slots.resize((size_t)NSLOTS);
        for (int s = 0; s < NSLOTS; s++) sc.slots[(size_t)s].resize((size_t)SLOTB);
        q_full.reset(new P7bSpscRing<SinkItemX>((size_t)NSLOTS));
        q_free.reset(new P7bSpscRing<SinkItemX>((size_t)NSLOTS));
        sc.full = q_full.get(); sc.freeq = q_free.get();
        for (int s = 0; s < NSLOTS; s++) q_free->push(SinkItemX{s, 0, 0});
        SplitIoArgs ia{&sc}; SplitCkArgs ca{&sc};
        if (pthread_create(&trx, NULL, split_io_main, &ia) != 0) p7b_io_die("pthread_create(io)");
        if (pthread_create(&tck, NULL, split_ck_main, &ca) != 0) p7b_io_die("pthread_create(ck)");
    } else { fprintf(stderr, "unknown mode %s\n", MODE); return 2; }

    if (trx) pthread_join(trx, NULL);
    if (tck) pthread_join(tck, NULL);
    pthread_join(tsend, NULL);
    double dt = p7b_io_now_s() - t0;
    long long sent = ba.sent.load(std::memory_order_acquire);
    close(rfd); close(sfd);

    printf("BENCH %s bytes_sent=%lld bytes_recv=%lld sec=%.6f Gbps=%.4f Mbps=%.2f"
           " checked=%lld first_mismatch=%lld mism_bytes=%lld slot_wait_spins=%llu send_err=%d"
           " slots=%d slot_bytes=%ld core_send=%d core_io=%d core_work=%d CPU_FREQ_KHZ=%s check=%s\n",
           MODE, sent, rc.got, dt, rc.got * 8.0 / dt / 1e9, rc.got * 8.0 / dt / 1e6,
           (m == "recv-only" || m == "send-discard") ? -1 : rc.checked, rc.first_mis, rc.mism,
           rc.spins, ba.err, NSLOTS, SLOTB, C_SEND, C_IO, C_WORK, p7baff_work_freq_khz().c_str(),
           p7b_check_mode_name());
    return (rc.got > 0 && ba.err == 0 && rc.first_mis < 0) ? 0 : 1;
}
