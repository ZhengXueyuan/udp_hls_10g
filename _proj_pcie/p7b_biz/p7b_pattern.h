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
//
// ===========================================================================
// ⭐⭐ 2026-10-09 (R1 轮): `check()` 增加 **M^8 lane-parallel 路径** (8 字节/步)
//
// 为什么 (实测, 不是推断): 逐字节版的 `check` = **每字节一条 6 拍串行依赖链**
//   (3× `shift+xor`) ⇒ 在 3.89 GHz 上封顶 **5.13 Gbps** —— 台架自己的帽子正好压在
//   要量的线上载荷天花板 (9.493 Gbps) 底下。下一轮要在真板上量**单连接线速**,
//   台架必须先站到线速之上, 所以这条路径是本轮的第一优先。
//
// 为什么可以 8 字节/步 (数学):
//   xorshift64 的**一步** M 是 GF(2) 上的**线性**映射; 连续 8 步 = M^8 也是线性的,
//   而"取字节" `(s>>24)&0xFF` 也是线性投影 ⇒ **8 个输出字节与下一状态都是当前状态的线性函数**。
//   把状态按 8 个字节 lane 分解 s = Σ_p b_p·2^{8p} ⇒
//       out_word = XOR_p Tw[p][b_p]   (Tw[p][v] = 状态恰为 v·2^{8p} 时的 8 个输出字节**打包**)
//       s_next   = XOR_p Tj[p][b_p]   (Tj[p][v] = M^8 · (v·2^{8p}), 与 RTL 的 `xs_next8`
//                                       **逐位同一条数学** —— rtl/app_pattern.v:93 / app_udp_pattern.v:249)
//   ⇒ 每 8 字节 = 16 次表查询 + 15 次异或, 八条 load **互不依赖** (没有串行链)。
//   ⛔ **分离双表** (`Tj[8][256]` 与 `Tw[8][256]` 各 16 KiB) 是**实测**的选择: 合并成一条
//     16 B 表项反而慢 30% (8 次干净 8 B load vs 8 次跨 cache line 的 16 B load)。
//
// 表构建成本 = **0**: 编译期 `constexpr` 生成 (4096 项 = 32 KiB 只读数据), 运行时**零初始化**,
//   也**不可能**出现"某个 check 忘了建表"的静默失败。表本身由 `--selftest-equiv` 用
//   运行时**独立重算**逐项复核 (非零、可独立复算的正证据)。
//
// ⭐ 两条路径**都保留**, `--check=seq|lane8` 选; **默认 = `seq`**(逐字节版是**已上板验过**的
//   判据基石 —— 历史全部 `first_mismatch`/`mism_bytes` 读数都出自它), 且它是回退的那只手
//   (全局经验 #46: A/B 判决的前提是"两只手都能重新点火")。
//   两路径的**逐位等价** (长序列的 first_mismatch / mism_bytes / **末态**三全等 + 注入失配 +
//   跨块连续性) 由 `p7b_pattern_equiv_selftest` 实测自证 —— **注释不算证据**。
// ===========================================================================
#pragma once
#include <cstdint>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#if defined(__cplusplus) && (__cplusplus < 201402L)
#error "p7b_pattern.h 需要 C++14 以上 (M^8 表由 constexpr 生成); 部署口径 = g++ -O3 -pthread (gnu++17)"
#endif

static const uint64_t P7B_SEED = 0x9E3779B97F4A7C15ull;

static inline constexpr uint64_t p7b_xs_next(uint64_t s) {
    s ^= s << 13;
    s ^= s >> 7;
    s ^= s << 17;
    return s;
}

// ---------------------------------------------------------------------------
// 校验模式开关 (**默认 seq**; 见文件头)
//   * `p7b_check_mode_parse("seq"|"lane8")`: 0 = 成功 / -1 = 未知 —— 调用者必须**响亮报错**
//     退出 (不许静默回落到默认, 那正是"传了参数没生效"的静默失效形态)。
//   * 每个用它的工具必须把 `check=<seq|lane8>` 打进输出 (开关的**见证**): "我传了参数"
//     ≠ "参数生效了"。
// ---------------------------------------------------------------------------
enum { P7B_CHECK_SEQ = 0, P7B_CHECK_LANE8 = 1 };

static inline int &p7b_check_mode_ref() {
    static int m = P7B_CHECK_SEQ;          // ⭐ 默认登记 = seq
    return m;
}
static inline void p7b_check_mode_set(int m) {
    p7b_check_mode_ref() = (m == P7B_CHECK_LANE8) ? (int)P7B_CHECK_LANE8 : (int)P7B_CHECK_SEQ;
}
static inline int p7b_check_mode_get() { return p7b_check_mode_ref(); }
static inline const char *p7b_check_mode_name() {
    return p7b_check_mode_ref() == P7B_CHECK_LANE8 ? "lane8" : "seq";
}
static inline int p7b_check_mode_parse(const char *s) {
    if (s && strcmp(s, "seq") == 0)   { p7b_check_mode_set(P7B_CHECK_SEQ);   return 0; }
    if (s && strcmp(s, "lane8") == 0) { p7b_check_mode_set(P7B_CHECK_LANE8); return 0; }
    return -1;
}

// ---------------------------------------------------------------------------
// M^8 表 (编译期常量)
// ---------------------------------------------------------------------------
struct P7bLane8Tab {
    uint64_t Tj[8][256];      // 下一状态: M^8 · (v << 8p)
    uint64_t Tw[8][256];      // 8 个输出字节打包 (bit 8j..8j+7 = 第 j 个字节)
};

static inline constexpr P7bLane8Tab p7b_lane8_build() {
    P7bLane8Tab t{};
    for (int p = 0; p < 8; p++) {
        for (int v = 0; v < 256; v++) {
            uint64_t s = (uint64_t)v << (8 * p), w = 0;
            for (int j = 0; j < 8; j++) {
                w |= (uint64_t)(uint8_t)(s >> 24) << (8 * j);   // 先取后推进 (与 RTL 同序)
                s = p7b_xs_next(s);
            }
            t.Tj[p][v] = s;                                     // = M^8 · s0
            t.Tw[p][v] = w;
        }
    }
    return t;
}
static constexpr P7bLane8Tab P7B_L8 = p7b_lane8_build();

// 8 字节**小端**打包读 (Tw 的打包约定; 大端机退化成逐字节拼 —— 本工程部署目标 = x86-64,
// 但别让"换台机器"变成静默算错)
static inline uint64_t p7b_load_le8(const uint8_t *p) {
#if defined(__BYTE_ORDER__) && defined(__ORDER_BIG_ENDIAN__) && (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)
    return (uint64_t)p[0]        | ((uint64_t)p[1] << 8)  | ((uint64_t)p[2] << 16) | ((uint64_t)p[3] << 24) |
           ((uint64_t)p[4] << 32) | ((uint64_t)p[5] << 40) | ((uint64_t)p[6] << 48) | ((uint64_t)p[7] << 56);
#else
    uint64_t u;
    memcpy(&u, p, 8);
    return u;
#endif
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

    // -----------------------------------------------------------------------
    // 逐字节路径 (**原实现逐字保留** —— 语义/读数与历史逐位相同)
    // 返回首个失配的**流内偏移**, -1 = 全匹配; 无论匹配与否都推进 n 步 (与板侧同语义)
    // -----------------------------------------------------------------------
    inline long long check_seq(const uint8_t *buf, size_t n, uint64_t *nmis = nullptr) {
        long long first = -1;
        uint64_t mis = 0;
        uint64_t st = s;
        for (size_t i = 0; i < n; i++) {
            uint8_t e = (uint8_t)(st >> 24);
            st = p7b_xs_next(st);
            if (e != buf[i]) { mis++; if (first < 0) first = (long long)i; }
        }
        s = st;
        if (nmis) *nmis = mis;
        return first;
    }

    // -----------------------------------------------------------------------
    // M^8 lane-parallel 路径 (8 字节/步) —— 语义**逐位等价**于 check_seq:
    //   * `first` = 首个失配字节的流内偏移 (块内按 j 升序找, 所以先出现的先记)
    //   * `mis`   = 失配**字节**数 (不是块数)
    //   * 末态   = SEED 推进 n 步 —— 与 seq 完全一致 ⇒ 跨块调用可无缝衔接
    // 尾段 (<8 字节) 用**与 check_seq 同款**的逐字节循环 (同一段代码 ⇒ 尾段语义天然一致)
    // -----------------------------------------------------------------------
    inline long long check_lane8(const uint8_t *buf, size_t n, uint64_t *nmis = nullptr) {
        long long first = -1;
        uint64_t mis = 0;
        uint64_t st = s;
        size_t i = 0;
        for (; i + 8 <= n; i += 8) {
            uint64_t b0 = st & 0xFF, b1 = (st >> 8) & 0xFF, b2 = (st >> 16) & 0xFF, b3 = (st >> 24) & 0xFF;
            uint64_t b4 = (st >> 32) & 0xFF, b5 = (st >> 40) & 0xFF, b6 = (st >> 48) & 0xFF, b7 = (st >> 56) & 0xFF;
            uint64_t w = P7B_L8.Tw[0][b0] ^ P7B_L8.Tw[1][b1] ^ P7B_L8.Tw[2][b2] ^ P7B_L8.Tw[3][b3] ^
                         P7B_L8.Tw[4][b4] ^ P7B_L8.Tw[5][b5] ^ P7B_L8.Tw[6][b6] ^ P7B_L8.Tw[7][b7];
            uint64_t u = p7b_load_le8(buf + i);
            if (w != u) {
                uint64_t x = w ^ u;
                for (int j = 0; j < 8; j++)
                    if (((x >> (8 * j)) & 0xFF) != 0) {
                        if (first < 0) first = (long long)(i + (size_t)j);
                        mis++;
                    }
            }
            st = P7B_L8.Tj[0][b0] ^ P7B_L8.Tj[1][b1] ^ P7B_L8.Tj[2][b2] ^ P7B_L8.Tj[3][b3] ^
                 P7B_L8.Tj[4][b4] ^ P7B_L8.Tj[5][b5] ^ P7B_L8.Tj[6][b6] ^ P7B_L8.Tj[7][b7];
        }
        for (; i < n; i++) {                       // 尾段: 与 check_seq 同款
            uint8_t e = (uint8_t)(st >> 24);
            st = p7b_xs_next(st);
            if (e != buf[i]) { mis++; if (first < 0) first = (long long)i; }
        }
        s = st;
        if (nmis) *nmis = mis;
        return first;
    }

    // -----------------------------------------------------------------------
    // 分派 (**调用时**读全局模式; 不是构造期快照 —— 那样"对象建在参数解析之前"会静默走错路径)
    // -----------------------------------------------------------------------
    inline long long check(const uint8_t *buf, size_t n, uint64_t *nmis = nullptr) {
        return p7b_check_mode_ref() == P7B_CHECK_LANE8 ? check_lane8(buf, n, nmis)
                                                      : check_seq(buf, n, nmis);
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

// ===========================================================================
// --selftest-equiv: **M^8 路径与逐字节路径的逐位等价** (2026-10-09, R1)
//
// 为什么必须单独有它: `check()` 的**默认路径是 seq** ⇒ 全部既有门 (T1–T8b / D1–D8) 跑的
//   都是 seq —— **新路径不会被任何既有判据覆盖**。没有这条, "lane8 接进去了"就只是注释。
// 四组判据 (逐行打印原始读数; 末行 PASS/FAIL; 返回非 0 = 有失败):
//   ① 表复核     : 运行时**独立重算** Tj/Tw 与编译期常量表 4096 项逐项比对
//   ② 长序列等价 : n 故意**非 8 对齐**; 两路径 (first_mismatch, mism_bytes, **末态**) 三全等,
//                  且末态与**第三条独立代码路径** (`P7bPat(n)` 构造函数的 O(n) 快进) 相等
//   ③ 注入失配   : 单 bit / 整块 8 字节 / 尾段最后一个字节 / 多字节散点 —— 两路径读数**全等**
//                  且**真的报出了注入的偏移与字节数** ("注入过" ≠ "测到了": 只比两路径相同
//                  不足以说明它们都对, 必须同时钉住期望值)
//   ④ 跨块连续性 : 同一个 P7bPat 上分块调用 (块界含 8 的倍数与非倍数), 每块**中间态**与
//                  `P7bPat(累计字节数).s` (独立路径) 逐个相等; 累计读数与末态与整段一致
// ===========================================================================
static inline int p7b_pattern_equiv_selftest(const char *tool) {
    int fail = 0, checks = 0;
    const int saved_mode = p7b_check_mode_get();
    printf("EQUIV %s: begin (seq vs lane8; 进程默认模式 = %s)\n", tool, p7b_check_mode_name());

    // ---- ④ 表复核 (先做: 表错了后面全都无意义) ----
    {
        int bad = 0;
        for (int p = 0; p < 8; p++)
            for (int v = 0; v < 256; v++) {
                uint64_t s0 = (uint64_t)v << (8 * p), s = s0, w = 0;
                for (int j = 0; j < 8; j++) { w |= (uint64_t)(uint8_t)(s >> 24) << (8 * j); s = p7b_xs_next(s); }
                if (P7B_L8.Tj[p][v] != s || P7B_L8.Tw[p][v] != w) bad++;
            }
        checks++;
        printf("EQUIV %s: table_rebuild bad=%d/4096 want=0 %s\n", tool, bad, bad ? "MISMATCH" : "MATCH");
        if (bad) fail++;
    }

    // ---- ② 长序列等价 (+ ③ 的干净件) ----
    // n = 8 MiB + 5 ⇒ 尾段 5 字节 (非 8 对齐) 也被走到
    const size_t N = (8u << 20) + 5;
    uint8_t *buf = (uint8_t *)malloc(N);
    if (!buf) { printf("EQUIV %s: malloc 失败 => FAIL\n", tool); p7b_check_mode_set(saved_mode); return 1; }
    { P7bPat g(0); g.fill(buf, N); }

    uint64_t m_a = 0, m_b = 0;
    long long f_a, f_b;
    uint64_t st_a, st_b;
    {
        P7bPat a(0), b(0);
        f_a = a.check_seq(buf, N, &m_a);  st_a = a.s;
        f_b = b.check_lane8(buf, N, &m_b); st_b = b.s;
        P7bPat c((uint64_t)N);                      // 第三条独立路径 (构造函数 O(n) 快进)
        int ok = (f_a == f_b) && (m_a == m_b) && (st_a == st_b) && (f_a == -1) && (m_a == 0) && (st_a == c.s);
        checks++;
        printf("EQUIV %s: long n=%zu seq=(%lld,%llu,0x%016llX) lane8=(%lld,%llu,0x%016llX) ctor_oracle=0x%016llX %s\n",
               tool, N, f_a, (unsigned long long)m_a, (unsigned long long)st_a,
               f_b, (unsigned long long)m_b, (unsigned long long)st_b,
               (unsigned long long)c.s, ok ? "MATCH" : "MISMATCH");
        if (!ok) fail++;
    }

    // ---- ③ 注入失配 (每次重新生成干净流再打洞) ----
    // (offset, mask) 列表: 覆盖 0 偏移 / 8 对齐块首 / 块中 / 块尾 / 尾段最后字节 / 多字节
    struct Inj { size_t off; uint8_t mask; int cnt; const char *what; };
    const Inj injs[] = {
        { 0,           0x01, 1, "首字节" },
        { 12345,       0x80, 1, "非 8 对齐单 bit" },
        { 65536,       0xFF, 1, "8 对齐块首整字节" },
        { 65543,       0x0F, 1, "块尾 (i+7)" },
        { N - 1,       0x01, 1, "尾段最后一个字节" },
        { 100,         0xFF, 3, "3 个相邻字节" },
    };
    for (size_t k = 0; k < sizeof(injs) / sizeof(injs[0]); k++) {
        const Inj &I = injs[k];
        P7bPat g(0); g.fill(buf, N);
        for (int t = 0; t < I.cnt; t++) buf[I.off + (size_t)t] ^= (uint8_t)(I.mask ? I.mask : 0xFF);
        uint64_t ma = 0, mb = 0;
        P7bPat a(0), b(0);
        long long fa = a.check_seq(buf, N, &ma);
        long long fb = b.check_lane8(buf, N, &mb);
        int ok = (fa == fb) && (ma == mb) && (fa == (long long)I.off) && (ma == (uint64_t)I.cnt) && (a.s == b.s);
        checks++;
        printf("EQUIV %s: inj[%zu] %s off=%zu cnt=%d seq=(%lld,%llu) lane8=(%lld,%llu) state_eq=%d %s\n",
               tool, k, I.what, I.off, I.cnt, fa, (unsigned long long)ma, fb,
               (unsigned long long)mb, (int)(a.s == b.s), ok ? "MATCH" : "MISMATCH");
        if (!ok) fail++;
    }

    // ---- ④ 跨块连续性 (最容易出错的一处: 两次 check 调用之间的状态衔接) ----
    // 块长混合 8 的倍数与非倍数, 且含 1 字节与 0 余量尾块
    {
        const size_t L = (1u << 20) + 3;
        P7bPat g(0); g.fill(buf, L);
        const size_t blk[] = { 0, 1, 7, 8, 9, 1000, 4093, 65536, 3, 8, 12345 };
        const size_t nb = sizeof(blk) / sizeof(blk[0]);
        uint64_t cum_mis_a = 0, cum_mis_b = 0;
        long long cum_first_a = -1, cum_first_b = -1;
        size_t pos = 0;
        int state_ok = 0, state_n = 0;
        P7bPat a(0), b(0);
        for (size_t k = 0; k < nb; k++) {
            size_t len = blk[k];
            if (pos + len > L) len = L - pos;
            uint64_t ma = 0, mb = 0;
            long long fa = a.check_seq(buf + pos, len, &ma);
            long long fb = b.check_lane8(buf + pos, len, &mb);
            if (fa >= 0 && cum_first_a < 0) cum_first_a = (long long)pos + fa;
            if (fb >= 0 && cum_first_b < 0) cum_first_b = (long long)pos + fb;
            cum_mis_a += ma; cum_mis_b += mb;
            pos += len;
            P7bPat o((uint64_t)pos);            // 独立路径的中间态
            state_n++;
            if (a.s == o.s && b.s == o.s) state_ok++;
        }
        if (pos < L) {                          // 余量整块 (块表没铺满时)
            uint64_t ma = 0, mb = 0;
            long long fa = a.check_seq(buf + pos, L - pos, &ma);
            long long fb = b.check_lane8(buf + pos, L - pos, &mb);
            if (fa >= 0 && cum_first_a < 0) cum_first_a = (long long)pos + fa;
            if (fb >= 0 && cum_first_b < 0) cum_first_b = (long long)pos + fb;
            cum_mis_a += ma; cum_mis_b += mb;
            pos = L;
            P7bPat o((uint64_t)pos);
            state_n++;
            if (a.s == o.s && b.s == o.s) state_ok++;
        }
        int ok = (cum_first_a == cum_first_b) && (cum_mis_a == cum_mis_b) && (state_ok == state_n) &&
                 (cum_first_a == -1) && (cum_mis_a == 0) && (a.s == b.s);
        checks++;
        printf("EQUIV %s: xblk L=%zu blocks=%zu states=%d/%d seq=(%lld,%llu,0x%016llX) lane8=(%lld,%llu,0x%016llX) %s\n",
               tool, L, nb, state_ok, state_n, cum_first_a, (unsigned long long)cum_mis_a,
               (unsigned long long)a.s, cum_first_b, (unsigned long long)cum_mis_b,
               (unsigned long long)b.s, ok ? "MATCH" : "MISMATCH");
        if (!ok) fail++;
    }

    // ---- 分派开关本身: check() 必须**真的**跟着模式走 (不是摆设) ----
    {
        uint64_t m_seq = 0, m_l8 = 0;
        p7b_check_mode_set(P7B_CHECK_SEQ);
        P7bPat a(0);
        long long f_seq = a.check(buf, 10000, &m_seq);
        p7b_check_mode_set(P7B_CHECK_LANE8);
        P7bPat b(0);
        long long f_l8 = b.check(buf, 10000, &m_l8);
        const char *nm = p7b_check_mode_name();
        P7bPat c(0);
        long long f_l8b = c.check_lane8(buf, 10000, NULL);
        int ok = (f_seq == f_l8) && (m_seq == m_l8) && (strcmp(nm, "lane8") == 0) && (f_l8b == f_l8) && (b.s == c.s);
        checks++;
        printf("EQUIV %s: dispatch seq=(%lld,%llu) lane8=(%lld,%llu) mode_name=%s direct_lane8=%lld %s\n",
               tool, f_seq, (unsigned long long)m_seq, f_l8, (unsigned long long)m_l8, nm, f_l8b,
               ok ? "MATCH" : "MISMATCH");
        if (!ok) fail++;
    }

    free(buf);
    p7b_check_mode_set(saved_mode);             // 恢复进程原模式 (selftest 不留副作用)
    printf("EQUIV %s: %s (checks=%d fail=%d)\n", tool, fail ? "FAIL" : "PASS", checks, fail);
    return fail ? 1 : 0;
}
