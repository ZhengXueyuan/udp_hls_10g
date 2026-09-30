// p7b_pattern.h -- 板侧图案流的对端（peer）复算器
//
// 语义**逐字**对齐 RTL:
//   * xorshift64:  s ^= s<<13;  s ^= s>>7;  s ^= s<<17;   (rtl/app_pattern.v:83-88 / app_udp_pattern.v)
//   * 种子       :  SEED = 0x9E3779B97F4A7C15
//   * 取字节     :  byte = s[31:24]  **先取后推进** (rtl/app_pattern.v:271 gen_byte / :278 rx_exp)
//
// 偏移语义 (两条不同, 必须区分):
//   * TCP (app_pattern):     LFSR 在**每连接** ev_up 处归零 -> 每条连接都从偏移 0 开始
//                            (rtl/app_pattern.v:337-342 的 `if (ev_up) rx_lfsr <= SEED;`)
//   * UDP (app_udp_pattern): i_en 恒 1 (`board/wrapper_p4.v:2481`) => 只有 rst_n 归零 =>
//                            板子**在一条连续字节流上**走, 跨 datagram 不重置。对端
//                            必须把它发出的所有载荷当成**一条连续流**的第 k 个字节。
//                            证据: `_proj_10g/notes/p7b_rate_result/teach.txt` -- 工具把
//                            同一个 100 B 前缀重发 20 次, 板侧 W13 恰好 0x7C7 = 1991
//                            (= 首帧 100 B 匹配之后的全部字节)。
//
// 自检向量 (由本文档作者**独立**按上面三条从 RTL 语义手算, 见 --selftest):
//   offset 0..15 = 7F 0B 02 E5 36 A1 4E D6 1A B0 49 B8 56 AD D6 3F
//   offset 1460..1467 = 03 00 42 2D 9B 47 CA C0
//   offset 100 之后的状态 = 0xAB5917A81F0FB2AE
#pragma once
#include <cstdint>
#include <cstddef>
#include <cstdio>
#include <cstring>

static const uint64_t P7B_SEED = 0x9E3779B97F4A7C15ull;

static inline uint64_t p7b_xs_next(uint64_t s) {
    s ^= s << 13;
    s ^= s >> 7;
    s ^= s << 17;
    return s;
}

struct P7bPat {
    uint64_t s;
    explicit P7bPat(uint64_t off = 0) : s(P7B_SEED) {
        for (uint64_t i = 0; i < off; i++) s = p7b_xs_next(s);
    }
    inline uint8_t next() {
        uint8_t b = (uint8_t)(s >> 24);
        s = p7b_xs_next(s);
        return b;
    }
    // 填 n 字节 (8 字节展开, 编译器可向量化)
    inline void fill(uint8_t *dst, size_t n) {
        size_t i = 0;
        for (; i + 8 <= n; i += 8) {
            uint64_t t = s;
            dst[i + 0] = (uint8_t)(t >> 24); t = p7b_xs_next(t);
            dst[i + 1] = (uint8_t)(t >> 24); t = p7b_xs_next(t);
            dst[i + 2] = (uint8_t)(t >> 24); t = p7b_xs_next(t);
            dst[i + 3] = (uint8_t)(t >> 24); t = p7b_xs_next(t);
            dst[i + 4] = (uint8_t)(t >> 24); t = p7b_xs_next(t);
            dst[i + 5] = (uint8_t)(t >> 24); t = p7b_xs_next(t);
            dst[i + 6] = (uint8_t)(t >> 24); t = p7b_xs_next(t);
            dst[i + 7] = (uint8_t)(t >> 24);
            s = p7b_xs_next(t);
        }
        for (; i < n; i++) dst[i] = next();
    }
    // 返回首个失配的**流内偏移**, -1 = 全匹配; 无论匹配与否都推进 n 步 (与板侧同语义)
    inline long long check(const uint8_t *buf, size_t n, uint64_t *nmis = nullptr) {
        long long first = -1;
        uint64_t mis = 0;
        for (size_t i = 0; i < n; i++) {
            uint8_t e = next();
            if (e != buf[i]) { mis++; if (first < 0) first = (long long)i; }
        }
        if (nmis) *nmis = mis;
        return first;
    }
};

// --selftest: 必须逐字打印下面三行 (任何一条不符 = 工具与 RTL 对不上, 停)
static inline int p7b_pattern_selftest(const char *tool) {
    uint8_t v[16];
    P7bPat p;
    p.fill(v, 16);
    char got[64] = {0}, want[64];
    for (int i = 0; i < 16; i++) sprintf(got + 3 * i, "%02X ", v[i]);
    const char *W1 = "7F 0B 02 E5 36 A1 4E D6 1A B0 49 B8 56 AD D6 3F ";
    strcpy(want, W1);
    P7bPat p2(1460);
    uint8_t v2[8];
    p2.fill(v2, 8);
    char got2[32] = {0}, want2[32];
    for (int i = 0; i < 8; i++) sprintf(got2 + 3 * i, "%02X ", v2[i]);
    strcpy(want2, "03 00 42 2D 9B 47 CA C0 ");
    P7bPat p3(100);
    int ok = (strcmp(got, want) == 0) && (strcmp(got2, want2) == 0) &&
             (p3.s == 0xAB5917A81F0FB2AEull);
    printf("SELFTEST %s: %s\n", tool, ok ? "OK" : "FAIL");
    printf("  off0..15   got=%s\n             want=%s\n", got, want);
    printf("  off1460..7 got=%s\n             want=%s\n", got2, want2);
    printf("  state@100  got=0x%016llX want=0xAB5917A81F0FB2AE\n",
           (unsigned long long)p3.s);
    return ok ? 0 : 1;
}
