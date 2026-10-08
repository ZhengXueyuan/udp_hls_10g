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
// ⭐ 2026-10-09 (R1/R2 用户要求落地): socket 一律 **非阻塞 + 电平触发 poll(LT)**。
//   * 全程序**只有一处 fcntl** (`p7b_io_set_nonblock` 里置 O_NONBLOCK, 现位于 p7b_io.h);
//     **没有任何**清 O_NONBLOCK 的路径 (旧版的 `fcntl(fd,F_SETFL,fl)` "回到阻塞模式" 已删除);
//   * 一切 recv/connect 都发生在 poll() 之后, 且容忍 EAGAIN (非阻塞语义的正证据);
//   * poll 超时 = **确定语义**: 计数 + 日志行 → 超过 --stall-n 次即中止该连接并计入 bad_conns
//     (⇒ 退出码非 0), 不静默吞。旧版无超时护栏, 连接停在中途会**永久挂住**(Stage C 实测踩过)。
//   * ⛔ **本工具不写盘**: 载荷只在内存里收发, 校验 = 按 p7b_pattern.h 规则**增量复算**
//
// ⭐⭐ 2026-10-09 (本轮 · 双线程样板, 用户逐字要求): "将发送/接收放在一个单独的线程中,
//   另一个线程负责产生或者消费数据, 两个线程之间用无锁队列通信。"
//   本文件是**样板**, 发送族下一轮按同一模板推。三条结构:
//     主线程   : 解析参数 → 建连 → 逐连接驱动 → 打印 SINK_CONN/SINK_SUM (**输出与退出码语义不变**)
//     I/O 线程 : poll(POLLIN, LT) → recv 进【空闲槽】→ 把 (槽号, 长度, **基偏移**) 推入 full 队列
//     校验线程 : 弹出 full → 用【基偏移】重生图案逐字节比 → 记 first_mis/mism_bytes → 槽推回 free
//   * 两条 **SPSC 无锁有界**队列 (p7b_spsc.h): full (I/O→校验) + free (校验→I/O 还槽);
//     槽池 N 个 × 槽字节 (默认 16 × 64 KiB, 见 --slots/--slot-bytes) ⇒ **recv 直接写槽, 零拷贝**。
//   * ⭐ **基偏移随元素走** ⇒ `first_mismatch` **保持"连接内流偏移"语义** (不退化成本块内偏移)。
//   * 每连接收尾等**队列排空 + 校验线程消费完**再打印 SINK_CONN ⇒ 偏移与统计**逐字节等价**。
//   * `--no-thread` = **旧单线程路径原样** (A/B 的另一只手; 全局经验 #46 的"同一判据两只手")。
//   * 约束 (设计硬边界): **单连接串行** —— 板侧 app 是**单会话** (见上), 并发连接会互相踩期望
//     序列 ⇒ "两线程" = **同一条连接的 [I/O 线程] + [校验线程]**, **绝不是两条连接**。
//   * ⚠️ 新线程各自绑核 (p7b_affinity.h 的 pair: 两颗**不同物理核**), 见证 = PIN_THREAD 行 +
//     主见证行的 PIN_PAIR_* 字段; 绑不上 = exit(2) (与主线程同款硬门)。
// 编译 (部署口径 = _proj_10g/notes/p7b_affinity/BUILD.md §2; 三处编译行已统一, 见 BUILD.md §4):
//   g++ -O3 -pthread -o p7b_tcp_sink p7b_tcp_sink.cpp   # ⭐ 2026-10-09: 用户裁定 -O3; +pthread(双线程)
#include "p7b_pattern.h"
#include "p7b_affinity.h"
#include "p7b_io.h"
#include "p7b_spsc.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstdlib>
#include <string>
#include <vector>

// ===========================================================================
// 双线程管臂 (2026-10-09)
// ===========================================================================
struct SinkItem {              // 队列元素 = 一个槽 + 它的**流内基偏移**
    int slot;                  // 槽号 (索引进槽池)
    long long base;            // 本块第一个字节在**连接内**的偏移 (约束 ①: 偏移随元素走)
    size_t len;                // 本块字节数
};

struct SinkConn {              // 每连接一份 (线程只在本次连接内活着 ⇒ 用 join 做同步)
    std::vector<std::vector<uint8_t> > *slots;
    size_t slot_bytes;
    P7bSpscRing<SinkItem> *full;      // I/O -> 校验
    P7bSpscRing<SinkItem> *freeq;     // 校验 -> I/O (还槽)
    std::atomic<int> io_done{0};      // I/O 侧收工 (release); 校验侧靠它知道何时排空退出
    // ---- I/O 线程写 ----
    long long got, nread_calls, conn_tmo;
    int status, err_no, pollnval;
    unsigned long long slot_wait_spins;
    // ---- 校验线程写 ----
    long long first_mis, mism_bytes, checked_bytes;
};

struct SinkIoArgs {
    int fd, conn_id, poll_ms, stall_n, cpu, print_pin;
    long maxbytes;
    size_t slot_bytes;
    SinkConn *c;
};

struct SinkCkArgs { SinkConn *c; int cpu, print_pin; };

// 校验一件 (I/O 线程推来的块): 用**基偏移**进图案流 ⇒ first_mis 是**连接内**偏移
//   ⚠️ `len == 0` 的**只还槽**元素 (I/O 侧收尾时交还手里那个槽) —— 不进图案流、不计数。
static inline void sink_check_item(P7bPat &pat, SinkConn *c, const SinkItem &it,
                                   long long *first, long long *mism, long long *checked) {
    if (it.len == 0) return;                       // 只还槽 (槽位由调用方推回 free)
    uint64_t nm = 0;
    long long f = pat.check((*c->slots)[it.slot].data(), it.len, &nm);
    if (f >= 0) {
        if (*first < 0) *first = it.base + f;      // ⭐ 约束 ① 的落点
        *mism += (long long)nm;
    }
    *checked += (long long)it.len;
}

// ⭐⭐ SPSC 合同 (TSan 抓出来的, 2026-10-09): **每条队列有且只有一条生产者线程** ——
//   `full` 的生产者 = I/O 线程; `freeq` 的生产者 = 校验线程。
//   ⛔ I/O 线程**绝不 push 到 freeq** (旧版在 FIN/RECV_ERR 路径上直接 `freeq->push` 还槽
//   ⇒ 与校验线程的还槽**并发** = 单生产者队列被两个生产者写 (head_ 丢更新/槽号重放),
//   这是 `-fsanitize=thread` 实测抓到的**真缺陷**, 不是理论风险)。
//   正确做法 = **槽只经 `full` 交还**: I/O 线程让出槽时推一个 `len == 0` 的元素进 full,
//   由**唯一**的 freeq 生产者 (校验线程) 把槽推回去。
static void *sink_io_main(void *arg) {
    SinkIoArgs *a = (SinkIoArgs *)arg;
    p7baff_pin_self_thread("io", a->cpu, a->print_pin != 0);   // 绑核 + 按线程记账 + 见证
    SinkConn *c = a->c;
    int fd = a->fd;
    long long conn_tmo = 0;
    int status = 0, err_no = 0, pollnval = 0;
    long long got = 0, nread_calls = 0;
    unsigned long long spins = 0;
    int held = -1;                                  // 本线程**挂着的槽** (还没交还; -1 = 没有)
    SinkItem it;
    while (got < a->maxbytes) {
        short rev = 0;
        int pr = p7b_io_poll_readable_ev(fd, a->poll_ms, &rev);
        if (pr == 0) {                          // ⭐ poll 超时 = 确定语义 (计数 + 日志 + 中止)
            conn_tmo++;
            if (conn_tmo >= a->stall_n) {
                printf("SINK_CONN %d POLL_TIMEOUT %lld x %d ms 无数据 (got=%lld) => 中止本连接\n",
                       a->conn_id, conn_tmo, a->poll_ms, got);
                fflush(stdout);
                status = 1;
                break;
            }
            continue;
        }
        if (pr < 0) { printf("SINK_CONN %d POLL_ERR errno=%d\n", a->conn_id, errno); status = 2; err_no = errno; break; }
        if (rev & POLLNVAL) { printf("SINK_CONN %d POLLNVAL (fd 失效)\n", a->conn_id); status = 2; pollnval = 1; break; }
        if (held < 0) {
            // 取一个空闲槽: 池见底 = 校验线程落后 ⇒ 让出 CPU 等它还槽 (槽池大小 = 流水深度)
            while (!c->freeq->pop(it)) { spins++; sched_yield(); }
            held = it.slot;
        }
        ssize_t n = recv(fd, (*c->slots)[held].data(), a->slot_bytes, 0);
        if (n < 0) {
            if (p7b_io_retryable(errno)) continue;       // 非阻塞语义 (槽**继续握着**, 下轮重试)
            printf("SINK_CONN %d RECV_ERR %d\n", a->conn_id, errno);
            status = 2; err_no = errno;
            break;                                       // 手里的槽在收尾处交还
        }
        if (n == 0) break;                               // 板侧 FIN (AUTO_CLOSE); 槽在收尾处交还
        conn_tmo = 0;
        nread_calls++;
        p7baff_work_freq_tick();                         // ⭐ R2: 本线程自采样真实工作频率 (自节流)
        SinkItem out{held, got, (size_t)n};              // ⭐ base = 本块之前的累计字节
        if (!c->full->push(out)) {                       // 结构性不可能 (full 容量 >= 槽数)
            printf("SINK_CONN %d QUEUE_FULL (结构性不可能: full 容量 >= 槽数)\n", a->conn_id);
            status = 2; err_no = 0;
            break;
        }
        got += n;
        held = -1;
    }
    if (held >= 0) {                                     // 交还手里那个槽 (len=0 = 只还槽)
        SinkItem back{held, 0, 0};
        c->full->push(back);                             // 容量 >= 槽数 ⇒ 必成功
    }
    c->got = got; c->nread_calls = nread_calls; c->conn_tmo = conn_tmo;
    c->status = status; c->err_no = err_no; c->pollnval = pollnval;
    c->slot_wait_spins = spins;
    c->io_done.store(1, std::memory_order_release);      // 收工 (校验侧据此排空退出)
    return NULL;
}

static void *sink_ck_main(void *arg) {
    SinkCkArgs *a = (SinkCkArgs *)arg;
    p7baff_pin_self_thread("work", a->cpu, a->print_pin != 0);
    SinkConn *c = a->c;
    P7bPat pat(0);                                       // **每连接**从偏移 0 起
    long long first = -1, mism = 0, checked = 0;
    SinkItem it;
    for (;;) {
        bool have = c->full->pop(it);
        if (!have && c->io_done.load(std::memory_order_acquire)) {
            have = c->full->pop(it);                     // 双检: io_done 之后仍可能有最后一件
            if (!have) break;                            // 队列排空 + I/O 收工 => 本连接校验完毕
        }
        if (!have) { sched_yield(); continue; }
        sink_check_item(pat, c, it, &first, &mism, &checked);
        p7baff_work_freq_tick();                         // ⭐ R2: 校验线程自采样 (本线程真在干活)
        c->freeq->push(it);                              // 还槽
    }
    c->first_mis = first; c->mism_bytes = mism; c->checked_bytes = checked;
    return NULL;
}

int main(int argc, char **argv) {
    // ⭐ 双线程才需要"两颗物理核"; 这个声明必须**在 p7b_pin_cpu 之前** (命令行 --pin-pair /
    //    --no-pin-pair 由它覆盖)。--no-thread 时不需要第二颗核 (单线程路径 = 旧行为原样)。
    bool threaded = true;
    for (int i = 1; i < argc; i++)
        if (std::string(argv[i]) == "--no-thread") threaded = false;
    p7baff_g_want_pair = threaded ? 1 : 0;
    argc = p7b_pin_cpu(argc, argv);      // 启动即绑核 (p7b_affinity.h; 剥离本函数自己的选项)
    const char *host = "192.168.100.2";
    int port = 8080, conns = 100, secs = 60, rcvbuf = 8 << 20;
    long maxbytes = 4L << 20;        // 每连接读上限 (1MB 图案 + 余量)
    int poll_ms = 5000;              // R1: 每次 poll 的等待上限 (ms)
    int stall_n = 3;                 // R1: 连续 --stall-n 次 poll 超时 = 该连接判 STALL 并中止
    int nslots = 16;                 // 双线程: 槽池深度 (流水深度)
    long slot_bytes = 64L << 10;     // 双线程: 每槽字节数 (recv 单次上限)
    bool selftest = false, selftest_equiv = false;
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
        else if (k == "--no-thread") threaded = false;      // 已在上面预扫 (这里只为吃掉参数)
        else if (k == "--slots") nslots = atoi(nx());
        else if (k == "--slot-bytes") slot_bytes = atol(nx());
        else if (k == "--selftest") selftest = true;
        else if (k == "--selftest-equiv") { selftest_equiv = true; }
        else if (k == "--check") {                        // ⭐ R1: 校验路径开关 (seq 默认)
            const char *v = nx();
            if (p7b_check_mode_parse(v) != 0) {
                fprintf(stderr, "unknown --check '%s' (seq|lane8)\n", v);
                return 2;                                  // ⛔ 不许静默回落到默认
            }
        }
        else if (k == "--help") {
            printf("p7b_tcp_sink --host H --port P [--conns N] [--seconds S] [--rcvbuf B] [--maxbytes B]\n"
                   "             [--poll-ms 5000] [--stall-n 3] [--no-thread] [--slots 16] [--slot-bytes 65536]\n"
                   "  逐连接: connect(非阻塞+poll) -> 收流(poll LT) -> 逐字节复算图案(偏移0起) -> 报告\n"
                   "  ⛔ 不写盘 (载荷只在内存); 校验 = 按 p7b_pattern.h 规则增量复算\n"
                   "  --poll-ms/--stall-n: 连续 stall-n 次 poll 超时 => 该连接 STALL 并中止 (计入 bad_conns)\n"
                   "  ⭐ 默认**双线程**: I/O 线程 (poll+recv 进槽) 与校验线程 (逐字节比) 经两条 SPSC 无锁\n"
                   "     有界队列交接 (槽池 = --slots x --slot-bytes; 基偏移随元素走 ⇒ first_mismatch\n"
                   "     仍是**连接内流偏移**); 两线程各绑一颗**不同物理核** (--pin-pair/--no-pin-pair)\n"
                   "  --no-thread: **旧单线程路径原样** (A/B 的另一只手)\n"
                   "  --check seq|lane8: 图案复算路径 (**默认 seq** = 已上板验过的逐字节版;\n"
                   "     lane8 = M^8 8 字节/步, 逐位等价, 见 p7b_pattern.h 头注释)\n"
                   "  输出行以 SINK_ 前缀, 便于机器解析; 汇总行 SINK_SUM_*; 新字段一律**追加行尾**\n"
                   "  --selftest: 只跑图案自检向量; --selftest-equiv: 跑 seq/lane8 逐位等价自检\n");
            return 0;
        } else { fprintf(stderr, "unknown arg %s (--help)\n", k.c_str()); return 2; }
    }
    if (selftest) return p7b_pattern_selftest("p7b_tcp_sink");
    if (selftest_equiv) return p7b_pattern_equiv_selftest("p7b_tcp_sink");
    if (poll_ms < 1) poll_ms = 1;
    if (stall_n < 1) stall_n = 1;
    if (nslots < 2) nslots = 2;
    if (slot_bytes < 1) slot_bytes = 1;
    if (!threaded) nslots = 0;                       // 单线程路径不用槽池 (见证里打 -1 = n/a)

    // ⭐ R1 见证: 开关的**正证据** —— "我传了参数" ≠ "参数生效了", 所以把**生效值**打出来。
    printf("SINK_CHECK check=%s\n", p7b_check_mode_name());
    fflush(stdout);

    // 槽池: **跨连接复用** (只分配一次); 队列每连接新建 ⇒ 队列统计天然按连接 (无清零动作)
    std::vector<std::vector<uint8_t> > slots;
    if (threaded) {
        slots.resize((size_t)nslots);
        for (int s = 0; s < nslots; s++) slots[(size_t)s].resize((size_t)slot_bytes);
    }
    std::vector<uint8_t> buf(1 << 20);               // 单线程路径的整块缓冲 (旧实现原样)

    const int cpu_io   = p7baff_g_pair_active ? p7baff_g_pair_cpu[0] : -1;
    const int cpu_work = p7baff_g_pair_active ? p7baff_g_pair_cpu[1] : -1;

    double t_start = p7b_io_now_s();
    long long tot_bytes = 0, tot_clean = 0, tot_conn = 0, tot_mismatch_bytes = 0;
    long long bad_conns = 0, fail_conns = 0, stall_conns = 0, err_conns = 0, tot_poll_tmo = 0;
    long long tot_full_push = 0, tot_full_pop = 0, tot_free_push = 0, tot_free_pop = 0;
    long long tot_slot_spins = 0, tot_checked = 0, tot_threads = 0;
    double first_conn_at = 0, last_conn_end = 0;

    for (int c = 0; c < conns; c++) {
        if (p7b_io_now_s() - t_start > secs) break;
        double t0 = p7b_io_now_s();
        int why = 0;
        int fd = p7b_io_connect_to(host, port, 5, &why);
        double t1 = p7b_io_now_s();
        if (fd < 0) {
            fail_conns++;
            printf("SINK_CONN %d FAIL_CONNECT why=%d (%s) (t=%.6f)\n", c, why, strerror(why), t1 - t_start);
            if (fail_conns > 5) break;
            continue;
        }
        if (c == 0) first_conn_at = t1;
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
        long long got = 0, mism_bytes = 0, first_mis = -1;
        long long nread_calls = 0, conn_tmo = 0;
        int status = 0;                      // 0=正常(FIN/读满) 1=STALL 2=ERR
        long long q_full_push = -1, q_full_pop = -1, q_free_push = -1, q_free_pop = -1;
        long long slot_spins = -1, checked = -1;

        if (threaded) {
            SinkConn cn;
            cn.slots = &slots; cn.slot_bytes = (size_t)slot_bytes;
            P7bSpscRing<SinkItem> q_full((size_t)nslots), q_free((size_t)nslots);
            cn.full = &q_full; cn.freeq = &q_free;
            cn.io_done.store(0, std::memory_order_relaxed);
            cn.got = 0; cn.nread_calls = 0; cn.conn_tmo = 0; cn.status = 0; cn.err_no = 0;
            cn.pollnval = 0; cn.slot_wait_spins = 0;
            cn.first_mis = -1; cn.mism_bytes = 0; cn.checked_bytes = 0;
            for (int s = 0; s < nslots; s++) q_free.push(SinkItem{s, 0, 0});   // 全部槽入池
            SinkIoArgs ia{fd, c, poll_ms, stall_n, cpu_io, (c == 0) ? 1 : 0, maxbytes, (size_t)slot_bytes, &cn};
            SinkCkArgs ca{&cn, cpu_work, (c == 0) ? 1 : 0};
            pthread_t tio, tck;
            if (pthread_create(&tio, NULL, sink_io_main, &ia) != 0) p7b_io_die("pthread_create(io)");
            if (pthread_create(&tck, NULL, sink_ck_main, &ca) != 0) p7b_io_die("pthread_create(work)");
            tot_threads += 2;
            pthread_join(tio, NULL);         // join 提供 happens-before ⇒ 之后读 cn 无需原子
            pthread_join(tck, NULL);         // 校验线程**排空后才退** ⇒ 本连接统计已完整
            got = cn.got; nread_calls = cn.nread_calls; conn_tmo = cn.conn_tmo;
            status = cn.status; first_mis = cn.first_mis; mism_bytes = cn.mism_bytes;
            checked = cn.checked_bytes; slot_spins = (long long)cn.slot_wait_spins;
            q_full_push = (long long)q_full.pushed();  q_full_pop = (long long)q_full.popped();
            q_free_push = (long long)q_free.pushed();  q_free_pop = (long long)q_free.popped();
            tot_full_push += q_full_push; tot_full_pop += q_full_pop;
            tot_free_push += q_free_push; tot_free_pop += q_free_pop;
            tot_slot_spins += slot_spins; tot_checked += checked;
        } else {
            // ---- 旧单线程路径: **原样** (每拍 poll -> recv 进 1 MiB 缓冲 -> 就地逐字节校验) ----
            P7bPat pat(0);                   // **每连接** 从偏移 0 起
            while (got < maxbytes) {
                short rev = 0;
                int pr = p7b_io_poll_readable_ev(fd, poll_ms, &rev);   // ⭐ 电平触发, 无 EPOLLET/select
                if (pr == 0) {               // ⭐ poll 超时 = 确定语义 (计数 + 日志 + 中止)
                    conn_tmo++;
                    if (conn_tmo >= stall_n) {
                        printf("SINK_CONN %d POLL_TIMEOUT %lld x %d ms 无数据 (got=%lld) => 中止本连接\n",
                               c, conn_tmo, poll_ms, got);
                        status = 1; break;
                    }
                    continue;
                }
                if (pr < 0) { printf("SINK_CONN %d POLL_ERR errno=%d\n", c, errno); status = 2; break; }
                if (rev & POLLNVAL) { printf("SINK_CONN %d POLLNVAL (fd 失效)\n", c); status = 2; break; }
                ssize_t n = recv(fd, buf.data(), buf.size(), 0);
                if (n < 0) {
                    if (p7b_io_retryable(errno)) continue;  // 非阻塞语义
                    printf("SINK_CONN %d RECV_ERR %d\n", c, errno);
                    status = 2; break;
                }
                if (n == 0) break;           // 板侧 FIN (AUTO_CLOSE)
                conn_tmo = 0;
                nread_calls++;
                p7baff_work_freq_tick();     // ⭐ R2: 单线程臂里**本线程**就是干活那条
                uint64_t nmis = 0;
                long long f = pat.check(buf.data(), (size_t)n, &nmis);
                if (f >= 0) {
                    if (first_mis < 0) first_mis = got + f;      // 与双线程路径**同一算式**
                    mism_bytes += (long long)nmis;
                }
                got += n;
            }
        }
        double t2 = p7b_io_now_s();
        close(fd);
        last_conn_end = t2;
        tot_conn++;
        tot_bytes += got;
        tot_poll_tmo += conn_tmo;
        if (status == 0 && first_mis < 0) tot_clean++;
        else bad_conns++;
        if (status == 1) stall_conns++;
        if (status == 2) err_conns++;
        tot_mismatch_bytes += mism_bytes;
        printf("SINK_CONN %d %s bytes=%lld first_mismatch=%lld mism_bytes=%lld "
               "conn_ms=%.3f dur_ms=%.3f Mbps=%.3f reads=%lld poll_tmo=%lld CPU_FREQ_KHZ=%s"
               " THREADED=%s q_full_push=%lld q_full_pop=%lld q_free_push=%lld q_free_pop=%lld"
               " slot_wait_spins=%lld checked_bytes=%lld\n",
               c, status == 0 ? "OK" : (status == 1 ? "STALL" : "ERR"),
               got, first_mis, mism_bytes, (t1 - t0) * 1e3, (t2 - t1) * 1e3,
               (t2 - t1) > 0 ? got * 8.0 / (t2 - t1) / 1e6 : 0.0, nread_calls, conn_tmo,
               p7baff_work_freq_khz().c_str(),  // F9 + R1 + R2: **工作线程自采样** (字段名不变, 语义订正见头)
               threaded ? "on" : "off",
               q_full_push, q_full_pop, q_free_push, q_free_pop, slot_spins, checked);
        fflush(stdout);
    }
    double t_end = p7b_io_now_s();
    printf("SINK_SUM conns=%lld fail_conns=%lld bytes=%lld clean_conns=%lld bad_conns=%lld "
           "mismatch_bytes=%lld stall_conns=%lld err_conns=%lld poll_tmo=%lld "
           "wall_s=%.3f net_s=%.3f agg_Mbps=%.3f"
           " THREADED=%s full_push=%lld full_pop=%lld free_push=%lld free_pop=%lld"
           " slot_wait_spins=%lld checked_bytes=%lld threads=%lld check=%s\n",
           tot_conn, fail_conns, tot_bytes, tot_clean, bad_conns, tot_mismatch_bytes,
           stall_conns, err_conns, tot_poll_tmo,
           t_end - t_start, last_conn_end - first_conn_at,
           (last_conn_end - first_conn_at) > 0 ? tot_bytes * 8.0 / (last_conn_end - first_conn_at) / 1e6 : 0.0,
           threaded ? "on" : "off",
           threaded ? tot_full_push : -1, threaded ? tot_full_pop : -1,
           threaded ? tot_free_push : -1, threaded ? tot_free_pop : -1,
           threaded ? tot_slot_spins : -1, threaded ? tot_checked : -1,
           threaded ? tot_threads : -1, p7b_check_mode_name());
    printf("SINK_DONE\n");
    return (bad_conns == 0 && fail_conns == 0 && tot_bytes > 0) ? 0 : 1;
}
