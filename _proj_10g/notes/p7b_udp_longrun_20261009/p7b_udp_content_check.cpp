// p7b_udp_content_check.cpp -- 板侧 UDP 图案流的**内容 oracle** (板外独立复算, 离线)
//
// 命题: 板子发出的 UDP 载荷 = xorshift64 图案流的连续片段 (**字节级**), 且**不依赖对端在
//       ~800 kpps / 1.2 GB/s 下收得下**(那正是用户态台架做不到的事)。做法 = 抽样取证:
//       tcpdump -c N 抓一小段(毫秒级)帧 => 事后离线把每帧载荷与参考流逐字节比对。
//
// 参考模型 (与 rtl/app_udp_pattern.v 逐位同款; 三条自检向量见 p7b_pattern.h 头注释):
//   s_0 = SEED = 0x9E3779B97F4A7C15; 第 k 字节 = (s_k >> 24) & 0xFF; s_{k+1} = xs(s_k)
//   xs(s): s ^= s<<13; s ^= s>>7; s ^= s<<17  (64 位, 先取后推进)
//
// ⭐ 偏移定位 (v2, 2026-10-09): 板上 `W9`(app 字节) 每 3.604 s 就回卷一次 ⇒ **流的绝对偏移
//   早就过了 2^32** (300 s 长流 ≈ 3.6e11 B) ⇒ 扫描 [0,2^32) **结构性找不到**(v1 实测踩到)。
//   流的位置必须由**帧号**定: 每帧载荷恰 1472 B (无异常帧时 LFSR 从不冻结) ⇒
//   第 n 帧的流偏移 = 1472*n ⇒ 用 `--klo/--khi` (帧号区间, 由 W8/W20 快照给出) 圈定搜索范围;
//   走到 1e12 级的偏移靠 **GF(2) 矩阵幂跳** (xs 是线性映射) —— 与 `--jumpcheck` 自检。
//
// 用法: ./p7b_udp_content_check <pcap> [--lo N] [--hi N] [--klo K] [--khi K] [--max N]
//       ./p7b_udp_content_check --jumpcheck N     # 矩阵跳 vs 线性走 自检
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>

static const uint64_t SEED = 0x9E3779B97F4A7C15ull;
static inline uint64_t xs_next(uint64_t s) {
    s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s;
}
static inline uint8_t stream_byte(uint64_t s) { return (uint8_t)((s >> 24) & 0xFF); }

// ---- GF(2) 线性代数 (xs_next 是线性的) ----
struct Mat { uint64_t r[64]; };   // y_i = parity(r[i] & v)
static Mat mat_identity() { Mat M; for (int i = 0; i < 64; i++) M.r[i] = 1ull << i; return M; }
static Mat mat_of_step() {
    Mat M; memset(M.r, 0, sizeof(M.r));
    for (int j = 0; j < 64; j++) {
        uint64_t y = xs_next(1ull << j);
        for (int i = 0; i < 64; i++) if ((y >> i) & 1ull) M.r[i] |= (1ull << j);
    }
    return M;
}
static Mat mat_mul(const Mat &A, const Mat &B) {
    Mat C; memset(C.r, 0, sizeof(C.r));
    for (int i = 0; i < 64; i++) {
        uint64_t acc = 0, row = A.r[i];
        while (row) { int j = __builtin_ctzll(row); row &= row - 1; acc ^= B.r[j]; }
        C.r[i] = acc;
    }
    return C;
}
static uint64_t mat_vec(const Mat &A, uint64_t v) {
    uint64_t acc = 0;
    for (int i = 0; i < 64; i++) if (__builtin_popcountll(A.r[i] & v) & 1) acc |= (1ull << i);
    return acc;
}
// 矩阵幂跳: 返回 M^k · s0  (k 可为 1e12 级)
static uint64_t jump(uint64_t s0, unsigned long long k) {
    Mat p = mat_of_step();
    uint64_t s = s0;
    while (k) {
        if (k & 1ull) s = mat_vec(p, s);
        k >>= 1;
        if (k) p = mat_mul(p, p);
    }
    return s;
}
static uint64_t walk(uint64_t s0, unsigned long long k) { uint64_t s = s0; while (k--) s = xs_next(s); return s; }

static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint16_t rd16be(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }

int main(int argc, char **argv) {
    if (argc >= 3 && !strcmp(argv[1], "--jumpcheck")) {
        unsigned long long N = strtoull(argv[2], 0, 0);
        uint64_t a = jump(SEED, N), b = walk(SEED, N);
        printf("JUMPCHECK N=%llu jump=%016llx walk=%016llx %s\n", N,
               (unsigned long long)a, (unsigned long long)b, a == b ? "MATCH" : "MISMATCH");
        return a == b ? 0 : 1;
    }
    if (argc < 2) { printf("usage: %s <pcap> [--lo N] [--hi N] [--klo K] [--khi K] [--max N]\n", argv[0]); return 2; }
    const char *path = argv[1];
    unsigned long long lo = 0, hi = 0; bool have_range = false;
    unsigned long long Paylen = 0;   // 若给了 --klo/--khi 就按 1472*K 折成字节区间
    long maxf = 200000;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--lo") && i + 1 < argc) { lo = strtoull(argv[++i], 0, 0); have_range = true; }
        else if (!strcmp(argv[i], "--hi") && i + 1 < argc) { hi = strtoull(argv[++i], 0, 0); have_range = true; }
        else if (!strcmp(argv[i], "--klo") && i + 1 < argc) { Paylen = 1472ull * strtoull(argv[++i], 0, 0); lo = Paylen; have_range = true; }
        else if (!strcmp(argv[i], "--khi") && i + 1 < argc) { Paylen = 1472ull * strtoull(argv[++i], 0, 0); hi = Paylen; have_range = true; }
        else if (!strcmp(argv[i], "--max") && i + 1 < argc) { maxf = atol(argv[++i]); }
        else { printf("CONTC_FAIL 未知参数 %s\n", argv[i]); return 2; }
    }
    if (!have_range) { lo = 0; hi = 0x100000000ull; }

    FILE *f = fopen(path, "rb");
    if (!f) { printf("CONTC_FAIL 打不开 %s\n", path); return 2; }
    uint8_t gh[24];
    if (fread(gh, 1, 24, f) != 24) { printf("CONTC_FAIL 短文件\n"); fclose(f); return 2; }
    uint32_t magic = rd32(gh);
    if (!(magic == 0xA1B2C3D4 || magic == 0xD4C3B2A1 || magic == 0xA1B23C4D)) {
        printf("CONTC_FAIL pcap magic=%08x\n", magic); fclose(f); return 2;
    }
    std::vector<std::vector<uint8_t> > pay;
    int nframes = 0, nonstd = 0;
    uint32_t ethlen0 = 0;
    for (;;) {
        uint8_t ph[16];
        if (fread(ph, 1, 16, f) != 16) break;
        uint32_t incl = rd32(ph + 8);
        std::vector<uint8_t> buf(incl);
        if (incl && fread(buf.data(), 1, incl, f) != incl) break;
        nframes++;
        if (incl < 42) { nonstd++; continue; }
        if (rd16be(&buf[12]) != 0x0800) { nonstd++; continue; }
        if (((buf[14] >> 4) != 4) || ((buf[14] & 0x0F) != 5)) { nonstd++; continue; }
        uint16_t udplen = rd16be(&buf[38]);
        if (udplen < 8) { nonstd++; continue; }
        if (!((uint32_t)udplen + 34u == incl || (uint32_t)udplen + 38u == incl)) { nonstd++; continue; }
        size_t n = udplen - 8;
        if (42 + n > incl) { nonstd++; continue; }
        if (pay.empty()) ethlen0 = incl;
        pay.push_back(std::vector<uint8_t>(buf.begin() + 42, buf.begin() + 42 + n));
        if ((long)pay.size() >= maxf) break;
    }
    fclose(f);
    printf("CONTC_PCAP frames_read=%d payload_frames=%zu nonstd=%d lo=%llu hi=%llu\n",
           nframes, pay.size(), nonstd, lo, hi);
    if (pay.empty()) { printf("CONTC_FAIL 无载荷帧\n"); return 1; }
    {
        size_t mn = (size_t)-1, mx = 0; double avg = 0;
        for (size_t i = 0; i < pay.size(); i++) { if (pay[i].size() < mn) mn = pay[i].size(); if (pay[i].size() > mx) mx = pay[i].size(); avg += (double)pay[i].size(); }
        avg /= (double)pay.size();
        bool all1472 = true;
        for (size_t i = 0; i < pay.size(); i++) if (pay[i].size() != 1472) all1472 = false;
        printf("CONTC_GEOM payload_min=%zu payload_max=%zu payload_avg=%.3f ethlen_first=%u all_1472=%s\n",
               mn, mx, avg, ethlen0, all1472 ? "YES" : "NO");
    }
    const std::vector<uint8_t> &P0 = pay[0];
    size_t probe = P0.size() < 32 ? P0.size() : 32;
    // ---- 搜索 frame0 偏移 (从 lo 起步, 矩阵跳) ----
    uint64_t s = jump(SEED, (unsigned long long)lo);
    uint64_t off = (uint64_t)-1;
    for (uint64_t o = lo; o < hi; o++) {
        if (stream_byte(s) == P0[0]) {
            uint64_t t = s; size_t i = 0; bool ok = true;
            for (; i < probe; i++) { if (stream_byte(t) != P0[i]) { ok = false; break; } t = xs_next(t); }
            if (ok) { off = o; break; }
        }
        s = xs_next(s);
    }
    if (off == (uint64_t)-1) { printf("CONTC_FAIL 在 [%llu,%llu) 内未找到 frame0 偏移\n", lo, hi); return 1; }
    printf("CONTC_OFFSET frame0=%llu mod1472=%llu mod8=%llu k=%llu (若 mod1472==0 则帧号=该值) search_span=%llu\n",
           off, off % 1472, off % 8, off / 1472, hi - lo);
    // ---- 逐帧验证 ----
    uint64_t cur_state = jump(SEED, (unsigned long long)off);
    uint64_t total_ok = 0; size_t researched = 0; bool have_bad = false;
    size_t bad_frame = 0, bad_byte = 0; uint64_t bad_off = 0;
    for (size_t k = 0; k < pay.size(); k++) {
        const std::vector<uint8_t> &P = pay[k];
        uint64_t t = cur_state; bool ok = true; size_t bi = 0;
        for (size_t i = 0; i < P.size(); i++) {
            if (stream_byte(t) != P[i]) { ok = false; bi = i; break; }
            t = xs_next(t);
        }
        if (ok) { total_ok += P.size(); cur_state = t; off += P.size(); continue; }
        if (!have_bad) { have_bad = true; bad_frame = k; bad_byte = bi; bad_off = off + bi; }
        // 从当前位置向前重搜本帧真实偏移 (抓包丢帧时用; 上限 = 本帧长 + 4 MB)
        uint64_t s2 = t, pos = off + bi;
        uint64_t lim = pos + (uint64_t)P.size() + (4ull << 20);
        uint64_t f2 = (uint64_t)-1;
        for (uint64_t o = pos; o < lim; o++) {
            if (stream_byte(s2) == P[0]) {
                uint64_t tt = s2; size_t i = 0; bool ok2 = true;
                for (; i < probe; i++) { if (stream_byte(tt) != P[i]) { ok2 = false; break; } tt = xs_next(tt); }
                if (ok2) { f2 = o; break; }
            }
            s2 = xs_next(s2);
        }
        if (f2 == (uint64_t)-1) {
            printf("CONTC_MISMATCH frame=%zu byte=%zu off=%llu stream=0x%02X wire=0x%02X (重搜失败)\n",
                   k, bi, (unsigned long long)(off + bi), stream_byte(t), P[bi]);
            break;
        }
        researched++;
        printf("CONTC_GAP frame=%zu 与流不连续(第%zu字节, off=%llu) 真偏移=%llu gap=%lld B (=%.3f 帧) ⇒ 抓包丢帧\n",
               k, bi, (unsigned long long)(off + bi), (unsigned long long)f2,
               (long long)f2 - (long long)(off + P.size()),
               (double)((long long)f2 - (long long)(off + P.size())) / 1472.0);
        uint64_t t3 = s2; bool ok3 = true;
        for (size_t i = 0; i < P.size(); i++) { if (stream_byte(t3) != P[i]) { ok3 = false; break; } t3 = xs_next(t3); }
        if (!ok3) { printf("CONTC_MISMATCH_RE frame=%zu (重搜命中但全帧比对失败)\n", k); break; }
        total_ok += P.size(); cur_state = t3; off = f2 + P.size();
    }
    printf("CONTC_TOTAL frames=%zu bytes_verified=%llu researched=%zu first_bad_frame=%zu first_bad_byte=%zu first_bad_off=%llu\n",
           pay.size(), (unsigned long long)total_ok, researched, bad_frame, bad_byte, (unsigned long long)bad_off);
    printf("CONTC_VERDICT %s\n", have_bad ? "GAPS_SEEN" : "ALL_FRAMES_BYTE_EXACT_CONTIGUOUS");
    return 0;
}
