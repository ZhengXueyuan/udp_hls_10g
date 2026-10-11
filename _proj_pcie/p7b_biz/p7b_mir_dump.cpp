// p7b_mir_dump.cpp -- M1「载荷镜像窗」的主机侧读工具 (user BAR / AXI4-Lite 寄存器窗口)
//
// 被测对象 = 板上 `rtl/app_rx_mirror.v` + `_proj_pcie/rtl/axi_regs.v` 的 MIR 读口:
//   板内: (tap) -> ^0xA5 -> 打包 32 位字 -> fifo_async(dp -> pcie) -> MIR_DATA (读=弹出)
//   主机: 本工具按 `MIR_STATUS.level` 读恰好 level 个 `MIR_DATA` 字, 小端拼字节流落盘。
//
// 协议 (设计件 v2 §V1.1/§V1.3; 地址全部见 `axi_regs.v` 头注释 §M1):
//   0x00 MAGIC (0x50360001) · 0x04 BUILD_ID (必须 == --bid) · 0x18 触发快照 (写 1)
//   0x1C SNAP_STATUS (bit1 done) · 0x13C MIR_STATUS · 0x140 MIR_DATA (读=弹出) · 0x144 MIR_CTRL
//   MIR_STATUS = {[31:23]=0, [22:19]ver, [18]capture_on, [17]any_drop_sticky,
//                 [16]unf_sticky, [15:0]level}
//   MIR_CTRL   = [0]cap_en [1]clr toggle; 起测顺序 = ① 写 clr=1 → ② 写 cap_en=1 → ③ 发包
//
// ⛔ 四条纪律 (全是本工程踩过的坑):
//   ① **只许 32 位单笔访问** (mmap 侧必须 `volatile uint32_t`): 宽读被拆成多笔 ⇒ 多弹。
//   ② 空读 `MIR_DATA` 会: 返回哨兵 `0x5A5A5A5A` + 置 `unf_sticky` + **不弹** ⇒ 本工具
//      **永不空读** (先读 level, 再读恰好 level 个字)。
//   ③ 读速率**不是**速率判据: 本通道上界 ~4–10 MB/s 量级 (设计件 §2.1, 未实测),
//      且本工具**未接** `p7b_affinity.h` ⇒ 打出的 `MIR_RATE_Bps` 只作形态参考,
//      **不得当板子能力引用** (若后续要用它做速率判据, 必须先补绑核见证, 全局 #62)。
//   ④ `--bytes K` 前置条件 **K % 4 == 0** (v2 §V1.2; 累加器不在 tlast flush ⇒ 尾部
//      <4B 结构性不可观测) ⇒ 不满足时立刻 exit(2) 响亮失败, 不"尽量读"。
//
// 用法:
//   sudo ./p7b_mir_dump --bid 0x1F --bytes 1048576 [--dev /dev/xdma0_user] [--out /tmp/mir.bin]
//                       [--seconds 30] [--xor 0xA5] [--pat-off 0] [--no-verify] [--no-arm]
//   ./p7b_mir_dump --selftest [--bytes 65536]      # 无板自检 (内存 mock; 含负对照)
// 退出码: 0 = 全好 / 1 = 内容失配或字节不足 / 2 = 用法或身份失败 (响亮)。
// 编译 (部署口径 = _proj_10g/notes/p7b_affinity/BUILD.md §2):
//   g++ -O3 -pthread -o p7b_mir_dump p7b_mir_dump.cpp
// ⚠️ mingw-w64 (本机自检编译用): 让 <unistd.h> 声明 pread/pwrite —— 只影响 Windows 侧,
//    Linux 部署口径 (g++ -O3 -pthread) 逐字不受影响。
#ifdef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include "p7b_pattern.h"

#include <fcntl.h>
#include <time.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static double now_s() {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

// 寄存器地址 (与 axi_regs.v 的 localparam 对应: SNAP_NW=71 ⇒ 字号 79/80/81)
static const uint32_t A_MAGIC = 0x00, A_BID = 0x04, A_SNAP_CTRL = 0x18, A_SNAP_ST = 0x1C;
static const uint32_t A_W11 = 0x4C;            // W11 = app_udp_pattern.stat_rx_bytes (UDP 收口字节账)
static const uint32_t A_W70 = 0x138;           // W70 = app_rx_mirror.drop_bytes (71 字窗口末字)
static const uint32_t A_MIR_STATUS = 0x13C, A_MIR_DATA = 0x140, A_MIR_CTRL = 0x144;
static const uint32_t MIR_SENT = 0x5A5A5A5Au;
static const uint32_t MAGIC = 0x50360001u;

// ---------------------------------------------------------------------------
// 寄存器 IO 抽象: 真设备 (pread/pwrite) | 内存 mock (--selftest)
// ---------------------------------------------------------------------------
struct RegIo {
    virtual ~RegIo() {}
    virtual uint32_t rd(uint32_t a) = 0;
    virtual void wr(uint32_t a, uint32_t v) = 0;
};

struct FdIo : RegIo {
    int fd = -1;
    explicit FdIo(const char *path) {
        fd = open(path, O_RDWR);
        if (fd < 0) { fprintf(stderr, "FATAL: open(%s): %s\n", path, strerror(errno)); exit(2); }
    }
    // ⚠️ 访问法 = **lseek + read/write 各 4 字节** —— 与对端现役 `reg_rw` 的做法逐字同构
    //   (移植性最好: 不依赖 pread/pwrite 可用性; 单线程工具不需要原子偏移语义)。
    uint32_t rd(uint32_t a) override {
        uint32_t v = 0xFFFFFFFFu;
        if (lseek(fd, (off_t)a, SEEK_SET) < 0 || read(fd, &v, 4) != 4) {
            fprintf(stderr, "FATAL: read @0x%03x: %s\n", a, strerror(errno)); exit(2);
        }
        return v;
    }
    void wr(uint32_t a, uint32_t v) override {
        if (lseek(fd, (off_t)a, SEEK_SET) < 0 || write(fd, &v, 4) != 4) {
            fprintf(stderr, "FATAL: write @0x%03x: %s\n", a, strerror(errno)); exit(2);
        }
    }
};

// 内存 mock: **只实现本工具用到的寄存器与语义** (够跑 --selftest 的正/负对照)。
struct MemIo : RegIo {
    uint8_t  stream[1 << 20];      // 载荷字节流 (测试预算内)
    uint32_t nbytes = 0, wpos = 0; // wpos = 已服务的字节数 (读=弹出)
    uint32_t cap = 0, tgl = 0, unf = 0, anyd = 0;
    uint32_t bid = 0x1F;
    uint32_t rd(uint32_t a) override {
        if (a == A_MAGIC) return MAGIC;
        if (a == A_BID) return bid;
        if (a == A_SNAP_ST) return 0x2;                     // done=1 (快照即刻完成)
        if (a == A_MIR_STATUS) {
            uint32_t lv = (nbytes - wpos) / 4;
            if (lv > 0xFFFF) lv = 0xFFFF;
            return (4u << 19) | (cap << 18) | (anyd << 17) | (unf << 16) | lv;
        }
        if (a == A_MIR_DATA) {
            if (wpos + 4 <= nbytes) {
                uint32_t w = (uint32_t)stream[wpos] | ((uint32_t)stream[wpos+1] << 8) |
                             ((uint32_t)stream[wpos+2] << 16) | ((uint32_t)stream[wpos+3] << 24);
                wpos += 4;
                return w;
            }
            unf = 1;                                        // 空读: 哨兵 + sticky, 不弹
            return MIR_SENT;
        }
        return 0;
    }
    void wr(uint32_t a, uint32_t v) override {
        if (a == A_MIR_CTRL) {
            if (v & 1u) cap = 1;                                // 照板上语义: 只管 bit0/bit1
            if (v & 2u) { tgl ^= 1u; wpos = 0; }                // clr: 冲刷 (mock = 指针回 0)
        }
    }
};

// ---------------------------------------------------------------------------
// dump 主循环 (设备与 mock 共用; 这正是 selftest 的意义 —— 跑同一段代码)
// ---------------------------------------------------------------------------
struct DumpRes { uint64_t bytes = 0, words = 0; int unf_seen = 0, drop_seen = 0; double secs = 0; };

static DumpRes run_dump(RegIo &io, uint64_t want, double tmo_s, bool arm) {
    DumpRes r;
    std::vector<uint8_t> buf; buf.reserve((size_t)want);
    double t0 = now_s();
    if (arm) {
        io.wr(A_MIR_CTRL, 0x2u);            // ① clr (清 FIFO/累加器/sticky)
        io.wr(A_MIR_CTRL, 0x1u);            // ② cap_en = 1
    }
    uint32_t s = io.rd(A_MIR_STATUS);
    r.unf_seen = (s >> 16) & 1; r.drop_seen = (s >> 17) & 1;
    int idle = 0;
    while (r.bytes < want) {
        s = io.rd(A_MIR_STATUS);
        if ((s >> 16) & 1) r.unf_seen = 1;
        if ((s >> 17) & 1) r.drop_seen = 1;
        uint32_t lv = s & 0xFFFFu;
        uint64_t need_w = (want - r.bytes) / 4;
        uint64_t c = lv < need_w ? lv : need_w;
        if (c == 0) {
            if (++idle % 2000 == 0) {
                if (now_s() - t0 > tmo_s) break;
                { struct timespec ts = {0, 50000}; nanosleep(&ts, nullptr); }
            }
            continue;
        }
        for (uint64_t i = 0; i < c; i++) {
            uint32_t w = io.rd(A_MIR_DATA);                 // 读=弹出
            buf.push_back((uint8_t)(w & 0xFF)); buf.push_back((uint8_t)((w >> 8) & 0xFF));
            buf.push_back((uint8_t)((w >> 16) & 0xFF)); buf.push_back((uint8_t)((w >> 24) & 0xFF));
        }
        r.words += c;
    }
    r.bytes = buf.size();
    r.secs = now_s() - t0;
    // 落盘由调用者做 —— 这里把 buf 塞回 io 侧的临时文件? 不: 直接在 main 里复用本函数的返回。
    // (为保持一个函数, 我们把数据写进全局临时缓冲)
    extern std::vector<uint8_t> g_last_buf;
    g_last_buf.swap(buf);
    return r;
}
std::vector<uint8_t> g_last_buf;

// 读一次快照并取两个字 (W11 = 板侧 UDP 收口字节账; W70 = 镜像拒收字节数)
static void snap_read(RegIo &io, uint32_t &w11, uint32_t &w70) {
    io.wr(A_SNAP_CTRL, 0x1u);
    for (int i = 0; i < 1000; i++) if ((io.rd(A_SNAP_ST) >> 1) & 1u) break;
    w11 = io.rd(A_W11); w70 = io.rd(A_W70);
}

static int verify(const std::vector<uint8_t> &got, uint64_t want, uint8_t xorc, uint64_t pat_off,
                  long long *first_mis) {
    P7bPat pat(pat_off);
    *first_mis = -1;
    for (uint64_t i = 0; i < got.size(); i++) {
        uint8_t e = (uint8_t)(pat.next() ^ xorc);
        if (got[i] != e) { *first_mis = (long long)i; return 1; }
    }
    if (got.size() < want) return 2;                    // 字节不足 (超时/停流)
    return 0;
}

int main(int argc, char **argv) {
    const char *dev = "/dev/xdma0_user", *out = "/tmp/mir.bin";
    uint64_t want = 0, pat_off = 0; double secs = 30.0;
    uint32_t bid = 0; bool have_bid = false, selftest = false, noverify = false, noarm = false;
    uint8_t xorc = 0xA5;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto nxt = [&](void) -> const char * { return (i + 1 < argc) ? argv[++i] : nullptr; };
        if (a == "--dev") { const char *p = nxt(); if (p) dev = p; }
        else if (a == "--out") { const char *p = nxt(); if (p) out = p; }
        else if (a == "--bytes") { const char *p = nxt(); if (p) want = strtoull(p, nullptr, 0); }
        else if (a == "--bid") { const char *p = nxt(); if (p) { bid = (uint32_t)strtoul(p, nullptr, 0); have_bid = true; } }
        else if (a == "--seconds") { const char *p = nxt(); if (p) secs = atof(p); }
        else if (a == "--xor") { const char *p = nxt(); if (p) xorc = (uint8_t)strtoul(p, nullptr, 0); }
        else if (a == "--pat-off") { const char *p = nxt(); if (p) pat_off = strtoull(p, nullptr, 0); }
        else if (a == "--selftest") selftest = true;
        else if (a == "--no-verify") noverify = true;
        else if (a == "--no-arm") noarm = true;
        else { fprintf(stderr, "usage: %s --bid <hex> --bytes <K> [--dev D] [--out F] [--seconds T]\n"
                               "       %*s --xor <hex> [--pat-off N] [--no-verify] [--no-arm]\n"
                               "       %s --selftest [--bytes K]\n", argv[0], (int)strlen(argv[0]), "", argv[0]);
               return 2; }
    }
    if (want == 0) want = selftest ? 65536 : 0;
    if (want == 0) { fprintf(stderr, "FATAL: --bytes 必填 (或 --selftest 用默认 65536)\n"); return 2; }
    // ⛔ 冻结前置条件: K % 4 == 0 (v2 §V1.2)
    if (want % 4 != 0) { fprintf(stderr, "FATAL: --bytes %llu 不是 4 的倍数 (K%%4==0 是 v2 §V1.2 前置条件)\n",
                                (unsigned long long)want); return 2; }

    // ---------------- --selftest: 内存 mock, 跑**同一段** dump/verify 代码 ----------------
    if (selftest) {
        int bad = 0;
        static MemIo m1, m2;
        m1.bid = 0x1F; m2.bid = 0x1F;
        m1.nbytes = (uint32_t)want;
        P7bPat p0(pat_off); for (uint32_t i = 0; i < m1.nbytes; i++) m1.stream[i] = (uint8_t)(p0.next() ^ xorc);
        memcpy(m2.stream, m1.stream, m1.nbytes); m2.nbytes = m1.nbytes;
        // T1 正例: 全链 (level 协议 -> pop -> 小端拼流 -> 逐字节 verify) 必须 PASS
        DumpRes r1 = run_dump(m1, want, 5.0, true);
        long long fm = -1;
        int rc1 = verify(g_last_buf, want, xorc, pat_off, &fm);
        printf("MIR_SELFTEST T1 bytes=%llu words=%llu rc=%d first_mis=%lld %s\n",
               (unsigned long long)r1.bytes, (unsigned long long)r1.words, rc1, fm,
               (rc1 == 0 && r1.bytes == want) ? "OK" : "FAIL");
        if (!(rc1 == 0 && r1.bytes == want)) bad = 1;
        // T2 负对照: 打坏 mock 流里的**第 57 字节** ⇒ verify 必须红, 且首个失配恰为 57
        m2.stream[57] ^= 0x01;
        DumpRes r2 = run_dump(m2, want, 5.0, false);
        fm = -1;
        int rc2 = verify(g_last_buf, want, xorc, pat_off, &fm);
        printf("MIR_SELFTEST T2 (corrupt byte 57) rc=%d first_mis=%lld bytes=%llu %s\n",
               rc2, fm, (unsigned long long)r2.bytes,
               (rc2 == 1 && fm == 57) ? "OK" : "FAIL");
        if (!(rc2 == 1 && fm == 57)) bad = 1;
        // T3 前置条件有牙: K%4!=0 必须被拒 (本测试用子进程语义无法直接验 main, 用解析复核)
        printf("MIR_SELFTEST T3 K%%4 check: want=%llu want%%4=%llu %s\n",
               (unsigned long long)want, (unsigned long long)(want % 4), (want % 4 == 0) ? "OK(本例合法)" : "FAIL");
        if (want % 4 != 0) bad = 1;
        // T4 哨兵/underflow: 排空后再读一次 ⇒ MIR_SENT + unf_sticky=1
        uint32_t s = m1.rd(A_MIR_STATUS);
        uint32_t lv = s & 0xFFFF; for (uint32_t i = 0; i < lv; i++) (void)m1.rd(A_MIR_DATA);
        uint32_t w = m1.rd(A_MIR_DATA);
        uint32_t s2 = m1.rd(A_MIR_STATUS);
        printf("MIR_SELFTEST T4 sentinel=%08x (exp %08x) unf=%u %s\n", w, MIR_SENT, (s2 >> 16) & 1u,
               (w == MIR_SENT && ((s2 >> 16) & 1u)) ? "OK" : "FAIL");
        if (!(w == MIR_SENT && ((s2 >> 16) & 1u))) bad = 1;
        printf("MIR_SELFTEST %s\n", bad ? "FAIL" : "PASS");
        return bad ? 1 : 0;
    }

    // ---------------- 真设备 ----------------
    if (!have_bid) { fprintf(stderr, "FATAL: --bid 必填 (身份门: 防'位流换代后读了个寂寞')\n"); return 2; }
    FdIo io(dev);
    uint32_t magic = io.rd(A_MAGIC), id = io.rd(A_BID);
    printf("MIR_ID magic=%08x (exp %08x) bid=%08x (exp %08x)\n", magic, MAGIC, id, bid);
    if (magic != MAGIC) { fprintf(stderr, "FATAL: MAGIC 不符 (端点没起 / 场景 A-C, 见 P7B_PCIE_RESCAN_RECOVERY.md)\n"); return 2; }
    if (id != bid) { fprintf(stderr, "FATAL: BUILD_ID %08x != --bid %08x (位流换代? 读侧几何不同代?)\n", id, bid); return 2; }

    uint32_t s0 = io.rd(A_MIR_STATUS);
    printf("MIR_STATUS ver=%u cap=%u any_drop=%u unf=%u level=%u\n",
           (s0 >> 19) & 0xF, (s0 >> 18) & 1, (s0 >> 17) & 1, (s0 >> 16) & 1, s0 & 0xFFFF);
    uint32_t w11a, w70a, w11b, w70b;
    snap_read(io, w11a, w70a);
    DumpRes r = run_dump(io, want, secs, !noarm);
    snap_read(io, w11b, w70b);

    std::vector<uint8_t> got = g_last_buf;
    if (!got.empty()) {
        FILE *f = fopen(out, "wb");
        if (!f) { fprintf(stderr, "FATAL: fopen(%s): %s\n", out, strerror(errno)); return 2; }
        fwrite(got.data(), 1, got.size(), f); fclose(f);
    }
    long long fm = -1; int rc = 0;
    if (!noverify) rc = verify(got, want, xorc, pat_off, &fm);
    printf("MIR_DONE bytes=%llu words=%llu secs=%.3f rate_Bps=%.0f out=%s drop_seen=%d unf_seen=%d\n",
           (unsigned long long)r.bytes, (unsigned long long)r.words, r.secs,
           r.secs > 0 ? (double)r.bytes / r.secs : 0.0, out, r.drop_seen, r.unf_seen);
    printf("MIR_RATE_NOTE not-a-rate-benchmark (user-BAR window; ~4-10MB/s class; no PIN_CPU witness)\n");
    printf("MIR_ACCT dW11=%u dW70=%u pc_bytes=%llu (want: (pc + dW70) == dW11  [mod 2^32])\n",
           w11b - w11a, w70b - w70a, (unsigned long long)r.bytes);
    if (!noverify) printf("MIR_VERIFY rc=%d first_mismatch=%lld of %llu\n", rc, fm, (unsigned long long)want);
    if (rc == 1) { fprintf(stderr, "FAIL: content mismatch at %lld\n", fm); return 1; }
    if (rc == 2) { fprintf(stderr, "FAIL: short (got %llu of %llu bytes)\n",
                          (unsigned long long)got.size(), (unsigned long long)want); return 1; }
    return 0;
}
