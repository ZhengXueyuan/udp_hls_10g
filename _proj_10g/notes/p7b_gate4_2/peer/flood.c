/* flood.c — 最小帧洪泛器 (E4/G6 用): 以最大速率发 N 个固定长度 UDP 帧, 不收包。
   payload=18 ⇒ 线上帧长 = 18+8+20+14+4 = 64 B (802.3 最小帧)。
   发送路径 = 普通 SOCK_DGRAM (内核组头/校验和), 与验收工具同族, 但**不读** ⇒ 不被接收侧天花板拖累。
   用法: ./flood <ip> <port> <n> <payload> */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <time.h>

int main(int argc, char **argv)
{
    const char *ip = argc > 1 ? argv[1] : "192.168.100.2";
    int port = argc > 2 ? atoi(argv[2]) : 8080;
    long n = argc > 3 ? atol(argv[3]) : 1000000;
    int pay = argc > 4 ? atoi(argv[4]) : 18;
    if (pay < 1 || pay > 1472) { fprintf(stderr, "bad payload\n"); return 2; }
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) { perror("socket"); return 2; }
    int snd = 4 * 1024 * 1024;
    setsockopt(s, SOL_SOCKET, SO_SNDBUF, &snd, sizeof(snd));
    struct sockaddr_in d;
    memset(&d, 0, sizeof d);
    d.sin_family = AF_INET;
    d.sin_port = htons((unsigned short)port);
    inet_pton(AF_INET, ip, &d.sin_addr);
    if (connect(s, (struct sockaddr *)&d, sizeof d) < 0) { perror("connect"); return 2; }
    static char buf[2048];
    memset(buf, 0xA5, sizeof buf);
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    long sent = 0;
    for (long i = 0; i < n; i++) if (send(s, buf, (size_t)pay, 0) == pay) sent++;
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double dt = (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) * 1e-9;
    fprintf(stderr, "flood: ip=%s port=%d n=%ld payload=%d (wire frame=%d B)\n", ip, port, n, pay, pay + 46);
    fprintf(stderr, "flood: sent=%ld/%ld dt=%.4f s => %.0f pps, %.0f Mbps(线上)\n",
            sent, n, dt, dt > 0 ? sent / dt : 0, dt > 0 ? sent * (pay + 46 + 20) * 8.0 / dt / 1e6 : 0);
    return 0;
}
