// p7b_mir_dump.cpp -- M1「载荷镜像窗」的主机侧读工具 (user BAR / AXI4-Lite 寄存器窗口)
//
// 被测对象 = 板上 `rtl/app_rx_mirror.v` + `_proj_pcie/rtl/axi_regs.v` 的 MIR 读口:
//   板内: (tap) -> ^0xA5 -> 打包 32 位字 -> fifo_async(dp -> pcie) -> MIR_DATA (读=弹出)
//   主机: 本工具按 `MIR_STATUS.level` 读恰好 level 个 `MIR_DATA` 字, 小端拼字节流落盘。
//
// 协议 (设计件 v2 §V1.1/§V1.3; 地址全部见 `axi_regs.v` 头注释 §M1):
//   0x00 MAGIC (0x50360001) · 0x04 BUILD_ID (必须 == --bid) · 0x18 触发快照 (写 1)
//   0x1C SNAP_STATUS (bit1 done) · 0x13C MIR_STATUS · 0x140 MIR_DATA (读=弹出) · 0x144 MIR_CTRL
//   MIR_STATUS = {[31:24]=0, [23]src_sel, [22:19]ver, [18]capture_on, [17]any_drop_sticky,
//                 [16]unf_sticky, [15:0]level}
//   MIR_CTRL   = [0]cap_en [1]clr toggle [2]src_sel; 起测顺序 = ① 写 clr=1 → ② 写 cap_en=1 → ③ 发包
//                (⭐ 期 A: `--src` 只改 [2], 不动 [0]/[1] 的协议)
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
// ⭐⭐ 期 B (2026-10-11): `--dma` = C2H DMA 环读路径 (取代 user-BAR 逐字搬运)
//   · 通道 = XDMA 的 C2H 引擎 (`/dev/xdma0_c2h_0`) → 我们自写的 AXI-MM 读从机
//     (`rtl/aximm_c2h_win.v`) → 板内 16 KB 环 (`rtl/mir_dma_ring.v`)。
//   · **取法 = `lseek(fd, 卡内字节偏移, SEEK_SET)` + `read(fd, buf, len)`** —— 与对端现役
//     `reg_rw` 的做法同构 (不依赖 pread 在该驱动上的可用性; 单线程工具不需要原子偏移)。
//     ⚠️ **该驱动是否支持 `pread`/`mmap` 未现核** (设计件 §V1.5-② 的"半可定"项);
//     要换 pread 只需把 `FdRingIo::read_at` 的一行改掉 —— **取法必须在板上现核后再定稿**。
//   · 环 = **幂等只读** (读不移动任何指针) ⇒ 与 BAR 窗口的"读=弹出"语义**不同**:
//     读同一地址两次得同一数据, 多读者/重读/进程重启都安全 (S3 的三类残余在这条路上不存在)。
//   · 新鲜度协议: 环会被写者**回绕覆盖** ⇒ 本工具在**每次环读之后**重读字计数器
//     (`MIR_DMA_CNT`, 0x148), 若 `(cnt_after - span_start) >= RING_WORDS` 则把这一段
//     记成 `clobber` 事件 (**检测, 非静默**; 定速演示下应为 0)。
//   · ⚠️ `MIR_DMA_CNT` 只在**接了 C2H 环的构建**里存在 (未接 = 读回 `0xffffffff`) ⇒
//     本工具在身份步**响亮退出** (不会把"寄存器不存在"读成计数器 0)。
//
// 用法:
//   sudo ./p7b_mir_dump --bid 0x1F --bytes 1048576 [--dev /dev/xdma0_user] [--out /tmp/mir.bin]
//                       [--seconds 30] [--xor 0xA5] [--pat-off 0] [--no-verify] [--no-arm]
//                       [--src udp|tcp]        # 期 A: 源选择 (读回 MIR_STATUS[23] 作身份门)
//   sudo ./p7b_mir_dump --bid 0x1F --bytes 1048576 --dma [--dma-dev /dev/xdma0_c2h_0]
//                       [--src udp|tcp] [--out /tmp/mir.bin] [--seconds 30]
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
static const uint32_t A_MIR_DMA_CNT = 0x148;    // ⭐ 期 B: 环字计数器 (未接该环的构建 ⇒ 0xffffffff)
static const uint32_t MIR_SENT = 0x5A5A5A5Au;
static const uint32_t MAGIC = 0x50360001u;
// ⭐ 期 B: 环几何 —— 必须与 `rtl/mir_dma_ring.v` 的 `ROW_AW` 参数同代 (16 KB = 4096 字 × 4 行/拍)
static const uint32_t RING_WORDS = 4096u;
static const uint32_t RING_BYTES = RING_WORDS * 4u;

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
    uint32_t srcsel = 0;           // ⭐ 期 A: MIR_CTRL[2] (读回进 MIR_STATUS[23])
    uint32_t dma_cnt = 0;          // ⭐ 期 B: 环字计数器 (mock 直接给)
    uint32_t dma_auto = 0;         // ⭐ 期 B: >0 = 每被读一次就前进这么多字 (模拟并发写者)
    uint32_t bid = 0x1F;
    uint32_t rd(uint32_t a) override {
        if (a == A_MAGIC) return MAGIC;
        if (a == A_BID) return bid;
        if (a == A_SNAP_ST) return 0x2;                     // done=1 (快照即刻完成)
        if (a == A_MIR_STATUS) {
            uint32_t lv = (nbytes - wpos) / 4;
            if (lv > 0xFFFF) lv = 0xFFFF;
            return (srcsel << 23) | (4u << 19) | (cap << 18) | (anyd << 17) | (unf << 16) | lv;
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
        if (a == A_MIR_DMA_CNT) {                           // ⭐ 期 B
            if (dma_auto) dma_cnt += dma_auto;              //   (mock 的并发写者: 读一次前进 N 字)
            return dma_cnt;
        }
        return 0;
    }
    void wr(uint32_t a, uint32_t v) override {
        if (a == A_MIR_CTRL) {
            if (v & 1u) cap = 1;                                // 照板上语义: 只管 bit0/bit1
            srcsel = (v >> 2) & 1u;                             // 期 A: bit2 电平 (写就落)
            if (v & 2u) { tgl ^= 1u; wpos = 0; }                // clr: 冲刷 (mock = 指针回 0)
        }
    }
};

// ---------------------------------------------------------------------------
// dump 主循环 (设备与 mock 共用; 这正是 selftest 的意义 —— 跑同一段代码)
// ---------------------------------------------------------------------------
struct DumpRes { uint64_t bytes = 0, words = 0; int unf_seen = 0, drop_seen = 0; double secs = 0; };

// src_sel: -1 = 不动该位 (默认, 阶段一行为); 0/1 = 写进 MIR_CTRL[2] (起测协议的每一笔都带上)
static DumpRes run_dump(RegIo &io, uint64_t want, double tmo_s, bool arm, int src_sel) {
    DumpRes r;
    std::vector<uint8_t> buf; buf.reserve((size_t)want);
    double t0 = now_s();
    uint32_t sb = (src_sel > 0) ? 4u : 0u;      // src_sel 位 (电平, 每一笔都带上)
    if (arm) {
        io.wr(A_MIR_CTRL, 0x2u | sb);       // ① clr (清 FIFO/累加器/sticky; 不改 src_sel)
        io.wr(A_MIR_CTRL, 0x1u | sb);       // ② cap_en = 1 (+ 保持 src_sel)
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

// ---------------------------------------------------------------------------
// ⭐⭐ 期 B: C2H DMA 环读路径 (幂等只读; 新鲜度靠字计数器 + 事后回绕检测)
// ---------------------------------------------------------------------------
// 环的物理布局 (必须与 `rtl/mir_dma_ring.v` 同代): 逻辑字 L 落在物理字 (L mod RING_WORDS);
// 卡内字节偏移 = 物理字号 * 4。卡内窗口 = [0, RING_BYTES)。
struct RingIo {
    virtual ~RingIo() {}
    // 从**物理**字号起读 nwords 个字 (调用侧保证不跨环尾) ⇒ 0 = 成功
    virtual int read_at(uint32_t phys_word, uint32_t nwords, uint8_t *dst) = 0;
};

struct FdRingIo : RingIo {
    int fd = -1;
    explicit FdRingIo(const char *path) {
        fd = open(path, O_RDONLY);
        if (fd < 0) { fprintf(stderr, "FATAL: open(%s): %s\n", path, strerror(errno)); exit(2); }
    }
    // 取法 = lseek(卡内字节偏移) + read —— 与对端现役 `reg_rw` 同构 (见文件头注释 ⭐⭐)
    int read_at(uint32_t phys_word, uint32_t nwords, uint8_t *dst) override {
        off_t off = (off_t)phys_word * 4;
        size_t want = (size_t)nwords * 4;
        if (lseek(fd, off, SEEK_SET) < 0) return -1;
        return (read(fd, dst, want) == (ssize_t)want) ? 0 : -1;
    }
};

struct DmaRes {
    uint64_t words = 0, bytes = 0;
    uint32_t cnt0 = 0, cnt1 = 0;
    uint32_t lag_max = 0;      // 观测到的最大滞后 (字): max(cnt - cur)
    uint32_t clobber = 0;      // 环读窗口"可能被回绕覆盖"的次数 (检测, 非静默)
    int short_reads = 0;       // 短读 (驱动/链路错) —— 一律响亮
    double secs = 0;
};

// mock 环 (--selftest 用): 一片内存 = 物理环; 可注入"某个物理字坏 1 bit"当负对照
struct MemRingIo : RingIo {
    uint8_t  mem[RING_BYTES];
    uint32_t corrupt_phys = 0xFFFFFFFFu;
    int read_at(uint32_t phys_word, uint32_t nwords, uint8_t *dst) override {
        memcpy(dst, mem + (size_t)phys_word * 4, (size_t)nwords * 4);
        if (corrupt_phys != 0xFFFFFFFFu && corrupt_phys >= phys_word &&
            corrupt_phys < phys_word + nwords) {
            dst[(size_t)(corrupt_phys - phys_word) * 4 + 2] ^= 0x01;
        }
        return 0;
    }
};

// 把连续的图案流按 4 B/字填进环 (逻辑字 L → 物理字 L mod RING_WORDS) —— 与板上同布局
static void ring_fill(MemRingIo &r, uint32_t fill_words, uint8_t xorc, uint64_t pat_off) {
    P7bPat p(pat_off);
    for (uint32_t L = 0; L < fill_words; L++) {
        for (int b = 0; b < 4; b++) {
            r.mem[(size_t)((uint32_t)(L % RING_WORDS)) * 4 + b] = (uint8_t)(p.next() ^ xorc);
        }
    }
}

// 读 nwords 个逻辑字 (从 start 起; 允许跨环尾 ⇒ 分两段)
static int ring_read(RingIo &rio, uint32_t start, uint32_t nwords, uint8_t *dst, int *short_reads) {
    uint32_t done = 0;
    while (done < nwords) {
        uint32_t phys  = (uint32_t)((start + done) % RING_WORDS);
        uint32_t chunk = RING_WORDS - phys;
        if (chunk > nwords - done) chunk = nwords - done;
        if (rio.read_at(phys, chunk, dst + (size_t)done * 4) != 0) { (*short_reads)++; return -1; }
        done += chunk;
    }
    return 0;
}

// DMA 采集: 与 run_dump 同构的"want 字节"语义, 但读的是环 (幂等) + 计数器差分
static DmaRes run_dma(RegIo &io, RingIo &rio, uint64_t want, double tmo_s, bool arm, int src_sel) {
    DmaRes r;
    std::vector<uint8_t> buf; buf.reserve((size_t)want);
    uint32_t sb = (src_sel > 0) ? 4u : 0u;
    if (arm) {
        io.wr(A_MIR_CTRL, 0x2u | 0x8u | sb);   // ① clr + dma_en(bit3) [+ src_sel]
        io.wr(A_MIR_CTRL, 0x1u | 0x8u | sb);   // ② cap_en + dma_en(bit3) [+ src_sel]
    }
    double t0 = now_s();
    uint32_t c0 = io.rd(A_MIR_DMA_CNT);
    if (c0 == 0xFFFFFFFFu) { fprintf(stderr, "FATAL: MIR_DMA_CNT 读回 0xffffffff (本构建未接 C2H 环)\n"); exit(2); }
    r.cnt0 = c0;
    uint32_t cur = c0;
    int idle = 0;
    while (buf.size() < want) {
        uint32_t c1 = io.rd(A_MIR_DMA_CNT);
        uint32_t av = (uint32_t)(c1 - cur);
        // 结构守卫: 一次能拿到的量不可能超过环容量 ⇒ 超过 = clr 换代 / 计数器跳变 / 落后超一环
        // (落后超一环 = 这一段数据已被覆盖 ⇒ 读回的是垃圾; 响亮退出, 不静默读垃圾)
        if (av > RING_WORDS) {
            fprintf(stderr, "FATAL: 计数器跳变 %u 字 > 环容量 %u (clr 换代? 或已落后 > 1 环 = 该段数据已被覆盖)\n",
                    av, RING_WORDS);
            exit(2);
        }
        if (av > r.lag_max) r.lag_max = av;
        if (av == 0) {
            if (++idle % 2000 == 0) {
                if (now_s() - t0 > tmo_s) break;
                { struct timespec ts = {0, 50000}; nanosleep(&ts, nullptr); }
            }
            continue;
        }
        uint64_t need_w = (want - buf.size()) / 4;
        uint32_t n = ((uint64_t)av < need_w) ? av : (uint32_t)need_w;
        size_t off = buf.size();
        buf.resize(off + (size_t)n * 4);
        if (ring_read(rio, cur, n, &buf[off], &r.short_reads) != 0) break;
        // 新鲜度门: 这一段的起点是否已被写者回绕越过 (读期间/读之前都可能)
        uint32_t c2 = io.rd(A_MIR_DMA_CNT);
        if ((uint32_t)(c2 - cur) >= RING_WORDS) r.clobber++;
        cur += n;
        r.words += n;
    }
    r.bytes = buf.size();
    r.cnt1 = io.rd(A_MIR_DMA_CNT);
    r.secs = now_s() - t0;
    g_last_buf.swap(buf);
    return r;
}

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
    const char *dev = "/dev/xdma0_user", *out = "/tmp/mir.bin", *dma_dev = "/dev/xdma0_c2h_0";
    uint64_t want = 0, pat_off = 0; double secs = 30.0;
    uint32_t bid = 0; bool have_bid = false, selftest = false, noverify = false, noarm = false;
    bool use_dma = false;
    int  src_sel = -1;                    // ⭐ 期 A: -1 = 不显式给 (默认不动该位)
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
        else if (a == "--dma") use_dma = true;                                  // ⭐ 期 B
        else if (a == "--dma-dev") { const char *p = nxt(); if (p) dma_dev = p; } // ⭐ 期 B
        else if (a == "--src") {                                                // ⭐ 期 A
            const char *p = nxt();
            if (!p) { fprintf(stderr, "FATAL: --src 需要 udp|tcp\n"); return 2; }
            if (!strcmp(p, "udp")) src_sel = 0;
            else if (!strcmp(p, "tcp")) src_sel = 1;
            else { fprintf(stderr, "FATAL: --src 只认 udp|tcp (给了 %s)\n", p); return 2; }
        }
        else { fprintf(stderr, "usage: %s --bid <hex> --bytes <K> [--dev D] [--out F] [--seconds T]\n"
                               "       %*s --xor <hex> [--pat-off N] [--no-verify] [--no-arm]\n"
                               "       %*s [--src udp|tcp] | --dma [--dma-dev /dev/xdma0_c2h_0]\n"
                               "       %s --selftest [--bytes K]\n", argv[0], (int)strlen(argv[0]), "",
                               (int)strlen(argv[0]), "", argv[0]);
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
        DumpRes r1 = run_dump(m1, want, 5.0, true, -1);
        long long fm = -1;
        int rc1 = verify(g_last_buf, want, xorc, pat_off, &fm);
        printf("MIR_SELFTEST T1 bytes=%llu words=%llu rc=%d first_mis=%lld %s\n",
               (unsigned long long)r1.bytes, (unsigned long long)r1.words, rc1, fm,
               (rc1 == 0 && r1.bytes == want) ? "OK" : "FAIL");
        if (!(rc1 == 0 && r1.bytes == want)) bad = 1;
        // T2 负对照: 打坏 mock 流里的**第 57 字节** ⇒ verify 必须红, 且首个失配恰为 57
        m2.stream[57] ^= 0x01;
        DumpRes r2 = run_dump(m2, want, 5.0, false, -1);
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
        // T4b 期 A: src_sel 的写-读回 (mock 语义, 与板上 MIR_CTRL[2]/MIR_STATUS[23] 同构)
        m1.wr(A_MIR_CTRL, 0x4u);                       // src_sel=1
        uint32_t s3 = m1.rd(A_MIR_STATUS);
        m1.wr(A_MIR_CTRL, 0x0u);                       // src_sel=0
        uint32_t s4 = m1.rd(A_MIR_STATUS);
        printf("MIR_SELFTEST T4b src_sel rb: set=%u clr=%u %s\n", (s3 >> 23) & 1u, (s4 >> 23) & 1u,
               (((s3 >> 23) & 1u) == 1u && ((s4 >> 23) & 1u) == 0u) ? "OK" : "FAIL");
        if (!(((s3 >> 23) & 1u) == 1u && ((s4 >> 23) & 1u) == 0u)) bad = 1;
        // ---- 期 B: 环读路径 (同一段 run_dma 代码; 含回绕/坏字/被回绕覆盖 三条腿) ----
        {
            const uint32_t N = 1024u, STEP = 64u;               // 写者每"被读一次"前进 64 字 (≈演示节奏)
            const uint32_t C0 = RING_WORDS - 512u + STEP;       // 首读返回的计数器 ⇒ 读起点贴环尾 (跨环尾)
            static MemIo m5; static MemRingIo r5;
            m5.bid = 0x1F; m5.dma_cnt = RING_WORDS - 512u; m5.dma_auto = STEP;
            ring_fill(r5, C0 + N + 64u, xorc, pat_off);
            DmaRes d5 = run_dma(m5, r5, (uint64_t)N * 4, 5.0, false, -1);
            fm = -1;
            int rc5 = verify(g_last_buf, (uint64_t)N * 4, xorc, pat_off + (uint64_t)4 * d5.cnt0, &fm);
            printf("MIR_SELFTEST T5 (ring wrap, cnt0=%u) words=%llu bytes=%llu rc=%d fm=%lld "
                   "clob=%u short=%d lag=%u %s\n",
                   d5.cnt0, (unsigned long long)d5.words, (unsigned long long)d5.bytes, rc5, fm,
                   d5.clobber, d5.short_reads, d5.lag_max,
                   (rc5 == 0 && d5.bytes == (uint64_t)N * 4 && d5.clobber == 0 && d5.short_reads == 0
                    && d5.words == N && d5.cnt0 == C0) ? "OK" : "FAIL");
            if (!(rc5 == 0 && d5.bytes == (uint64_t)N * 4 && d5.clobber == 0 && d5.short_reads == 0
                  && d5.words == N && d5.cnt0 == C0)) bad = 1;
            // T6 负对照: 环里**第一个被读到的物理字**坏 1 bit ⇒ verify 必须红 (fm==2)
            static MemIo m6; static MemRingIo r6;
            m6.bid = 0x1F; m6.dma_cnt = RING_WORDS - 512u; m6.dma_auto = STEP;
            ring_fill(r6, C0 + N + 64u, xorc, pat_off);
            r6.corrupt_phys = C0 % RING_WORDS;
            DmaRes d6 = run_dma(m6, r6, (uint64_t)N * 4, 5.0, false, -1);
            fm = -1;
            int rc6 = verify(g_last_buf, (uint64_t)N * 4, xorc, pat_off + (uint64_t)4 * d6.cnt0, &fm);
            printf("MIR_SELFTEST T6 (corrupt first ring word) rc=%d fm=%lld %s\n", rc6, fm,
                   (rc6 == 1 && fm == 2) ? "OK" : "FAIL");
            if (!(rc6 == 1 && fm == 2)) bad = 1;
            // T7 负对照: 写者在环读期间前进 > 1 环 ⇒ clobber 检测必须响
            static MemIo m7; static MemRingIo r7;
            m7.bid = 0x1F; m7.dma_auto = RING_WORDS / 2u + 64u;
            ring_fill(r7, 2048u + 128u, xorc, pat_off);          // 内容不判 (只判检测器)
            DmaRes d7 = run_dma(m7, r7, 4096, 5.0, false, -1);
            printf("MIR_SELFTEST T7 (writer wraps during read) clob=%u %s\n", d7.clobber,
                   (d7.clobber > 0) ? "OK" : "FAIL");
            if (!(d7.clobber > 0)) bad = 1;
        }
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

    // ---- ⭐ 期 A: --src 的写-读回门 (在起测协议之前落位; 不符 = 响亮退出) ----
    if (src_sel >= 0) {
        io.wr(A_MIR_CTRL, (uint32_t)(src_sel ? 4u : 0u));     // 只改 bit2 (cap_en=0)
        uint32_t sv = io.rd(A_MIR_STATUS);
        printf("MIR_SRC src_sel=%d readback=%u\n", src_sel, (sv >> 23) & 1u);
        if (((sv >> 23) & 1u) != (uint32_t)src_sel) {
            fprintf(stderr, "FATAL: src_sel 读回不符 (写 %d 读回 %u) —— 位流不带期 A 的 src_sel?\n",
                    src_sel, (sv >> 23) & 1u);
            return 2;
        }
    }

    uint32_t s0 = io.rd(A_MIR_STATUS);
    printf("MIR_STATUS ver=%u src_sel=%u cap=%u any_drop=%u unf=%u level=%u\n",
           (s0 >> 19) & 0xF, (s0 >> 23) & 1u, (s0 >> 18) & 1, (s0 >> 17) & 1, (s0 >> 16) & 1, s0 & 0xFFFF);
    uint32_t w11a, w70a, w11b, w70b;
    snap_read(io, w11a, w70a);
    if (use_dma) {
        // ⭐⭐ 期 B: C2H 环读路径 —— 身份门 = MIR_DMA_CNT 可读 (未接该环的构建回 0xffffffff)
        FdRingIo rio(dma_dev);
        DmaRes dr = run_dma(io, rio, want, secs, !noarm, src_sel);
        snap_read(io, w11b, w70b);
        std::vector<uint8_t> got = g_last_buf;
        if (!got.empty()) {
            FILE *f = fopen(out, "wb");
            if (!f) { fprintf(stderr, "FATAL: fopen(%s): %s\n", out, strerror(errno)); return 2; }
            fwrite(got.data(), 1, got.size(), f); fclose(f);
        }
        long long fm = -1; int rc = 0;
        uint64_t poff = pat_off + (uint64_t)4 * dr.cnt0;    // 环是第 cnt0 字开始被本工具读走的
        if (!noverify) rc = verify(got, want, xorc, poff, &fm);
        printf("MIR_DMA_DONE bytes=%llu words=%llu secs=%.3f rate_Bps=%.0f out=%s\n",
               (unsigned long long)dr.bytes, (unsigned long long)dr.words, dr.secs,
               dr.secs > 0 ? (double)dr.bytes / dr.secs : 0.0, out);
        printf("MIR_DMA_ACCT cnt0=%u cnt1=%u lag_max=%u clobber=%u short_reads=%d (want: clobber==0 & short==0 & cnt1-cnt0==words[mod 2^32])\n",
               dr.cnt0, dr.cnt1, dr.lag_max, dr.clobber, dr.short_reads);
        printf("MIR_DMA_NOTE ring=16KB idempotent-read; access=lseek+read on %s (pread 未现核, 见文件头)\n", dma_dev);
        if (!noverify) printf("MIR_VERIFY rc=%d first_mismatch=%lld of %llu (pat_off_eff=%llu)\n",
                              rc, fm, (unsigned long long)want, (unsigned long long)poff);
        if (dr.short_reads != 0) { fprintf(stderr, "FAIL: %d 次短读 (驱动/链路错)\n", dr.short_reads); return 1; }
        if (rc == 1) { fprintf(stderr, "FAIL: content mismatch at %lld\n", fm); return 1; }
        if (rc == 2) { fprintf(stderr, "FAIL: short (got %llu of %llu bytes)\n",
                              (unsigned long long)got.size(), (unsigned long long)want); return 1; }
        return 0;
    }
    DumpRes r = run_dump(io, want, secs, !noarm, src_sel);
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
