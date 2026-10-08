// p7baff_faultinject.cpp -- p7b_affinity.h 的**测试专用故障注入器** (LD_PRELOAD)
//   ⛔ 不进部署件、不进任何判据链、不发起任何网络连接。只用来在板外构造探针边界。
//
// 用途 (2026-10-08, F2/F4 的复现仪器):
//   ① P7BAFF_DENY_SUBSTR=<子串>      路径**含**该子串的 fopen/readlink/readlinkat => ENOENT
//        - DENY_SUBSTR=thread_siblings_list  => 拓扑读不到 => PIN_DEGRADED 带 topo
//        - DENY_SUBSTR=/device/driver        => sfc 探测 0 命中 => PIN_DEGRADED 带 nic
//      第二个独立子串: P7BAFF_DENY_SUBSTR2 (两个子串 OR; 同时给两个 => nic+topo)
//   ② P7BAFF_MAP_FROM=<绝对路径> P7BAFF_MAP_TO=<替换文件>  精确重映射 fopen 的路径
//        - FROM=/proc/softirqs TO=假表  => 造出 >2³¹ 的核负载 (F4 的溢出别名)
//
// 编译 (对端机): g++ -shared -fPIC -O2 -o libp7baff_faultinject.so p7baff_faultinject.cpp
// 用法: LD_PRELOAD=./libp7baff_faultinject.so P7BAFF_DENY_SUBSTR=... ./p7b_tcp_sink --help
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int deny_path(const char *p) {
    const char *d1 = getenv("P7BAFF_DENY_SUBSTR");
    const char *d2 = getenv("P7BAFF_DENY_SUBSTR2");
    if (d1 && *d1 && strstr(p, d1)) return 1;
    if (d2 && *d2 && strstr(p, d2)) return 1;
    return 0;
}

extern "C" FILE *fopen(const char *path, const char *mode) {
    typedef FILE *(*fn_t)(const char *, const char *);
    static fn_t real = NULL;
    if (!real) real = (fn_t)dlsym(RTLD_NEXT, "fopen");
    if (deny_path(path)) { errno = ENOENT; return NULL; }
    const char *from = getenv("P7BAFF_MAP_FROM");
    const char *to = getenv("P7BAFF_MAP_TO");
    if (from && *from && to && *to && strcmp(path, from) == 0) return real(to, mode);
    return real(path, mode);
}

extern "C" ssize_t readlink(const char *path, char *buf, size_t sz) {
    typedef ssize_t (*fn_t)(const char *, char *, size_t);
    static fn_t real = NULL;
    if (!real) real = (fn_t)dlsym(RTLD_NEXT, "readlink");
    if (deny_path(path)) { errno = ENOENT; return -1; }
    return real(path, buf, sz);
}

extern "C" ssize_t readlinkat(int dirfd, const char *path, char *buf, size_t sz) {
    typedef ssize_t (*fn_t)(int, const char *, char *, size_t);
    static fn_t real = NULL;
    if (!real) real = (fn_t)dlsym(RTLD_NEXT, "readlinkat");
    if (deny_path(path)) { errno = ENOENT; return -1; }
    return real(dirfd, path, buf, sz);
}
