// udpsend.cpp -- a PLAIN-SOCKET UDP pattern sender. Deliberately does NOT use npcap.
//
// WHY THIS EXISTS (ISSUE_RX_BYTE_CORRUPTION.md §19.5 / §19.6)
// ----------------------------------------------------------
// The board observed the frames ARRIVING OUT OF ORDER at line rate (v7: IW = backward
// IP-ID jumps, 16/7 at line rate, 18 at 500 Mbps, 0 at 100 Mbps -- tracking the payload
// corruption UMM exactly). The PC-side capture showed the driver's queue in order, so the
// reorder happens BELOW the capture point. Stopping the Killer NIC services did NOT remove
// it (IW still 4). That leaves: npcap's send path, the NIC hardware, the cable, or an
// intermediate switch.
//
// `peer.exe` injects raw frames through npcap. This tool sends the SAME pattern through a
// NORMAL UDP socket, so:
//     corruption persists  -> the reorder is NOT npcap-specific (NIC / link / switch)
//     corruption gone      -> npcap's send path is the reorderer
//
// It deliberately does NOT replace peer.exe for rate testing (that still uses peer.exe over
// npcap, per the project rule); it exists only to separate the two send paths.
//
// Build:  cmd //c 'D:\repo\ECO\udp_hls_10g\tools\cpp_peer\build_udpsend.bat'
// Usage:  udpsend.exe --dst-ip 192.168.100.2 --dst-port 8081 --bytes 8388608 --paylen 1472 --rate-mbps 500
//
// The pattern MUST match the board exactly: xorshift64, seed 0x9E3779B97F4A7C15,
// take-then-advance, byte = (s >> 24) & 0xFF. (Same convention as rtl/app_pattern.v.)

#include <winsock2.h>
#include <ws2tcpip.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <chrono>
#include <thread>

#define MASK64 0xFFFFFFFFFFFFFFFFULL

static uint64_t xs_next(uint64_t s) {
    s ^= (s << 13) & MASK64;
    s ^= (s >> 7);
    s ^= (s << 17) & MASK64;
    return s & MASK64;
}

int main(int argc, char **argv) {
    const char *dst_ip = "192.168.100.2";
    int         dst_port = 8081;
    long long   bytes = 8388608;
    int         paylen = 1472;
    double      rate_mbps = 0.0;      // 0 = unlimited

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : "";
        if      (a == "--dst-ip")    { dst_ip = v; i++; }
        else if (a == "--dst-port")  { dst_port = atoi(v); i++; }
        else if (a == "--bytes")     { bytes = atoll(v); i++; }
        else if (a == "--paylen")    { paylen = atoi(v); i++; }
        else if (a == "--rate-mbps") { rate_mbps = atof(v); i++; }
        else { printf("unknown arg %s\n", a.c_str()); return 2; }
    }
    if (paylen < 1 || paylen > 1472) { printf("paylen out of range\n"); return 2; }

    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) { printf("WSAStartup failed\n"); return 1; }

    SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) { printf("socket failed: %d\n", WSAGetLastError()); return 1; }

    int sndbuf = 8 << 20;
    setsockopt(s, SOL_SOCKET, SO_SNDBUF, (const char *)&sndbuf, sizeof(sndbuf));

    sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons((u_short)dst_port);
    if (inet_pton(AF_INET, dst_ip, &dst.sin_addr) != 1) { printf("bad dst-ip\n"); return 2; }

    // Build the whole pattern stream up front so the bytes are exactly right.
    std::vector<unsigned char> pat((size_t)bytes);
    {
        uint64_t st = 0x9E3779B97F4A7C15ULL;
        for (long long i = 0; i < bytes; i++) {
            pat[(size_t)i] = (unsigned char)((st >> 24) & 0xFF);
            st = xs_next(st);
        }
    }

    long long off = 0, frames = 0, sent_bytes = 0;
    auto t0 = std::chrono::steady_clock::now();

    while (off < bytes) {
        int n = (int)((bytes - off) < paylen ? (bytes - off) : paylen);
        int r = sendto(s, (const char *)&pat[(size_t)off], n, 0, (sockaddr *)&dst, sizeof(dst));
        if (r == SOCKET_ERROR) {
            printf("sendto failed at off=%lld: %d\n", off, WSAGetLastError());
            break;
        }
        off += n; frames++; sent_bytes += n;

        if (rate_mbps > 0.0) {
            // Pace on WIRE bytes (payload + 42B header), matching peer.exe's convention.
            double wire = (double)sent_bytes + 42.0 * (double)frames;
            double want_s = wire * 8.0 / (rate_mbps * 1e6);
            double have_s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            if (want_s > have_s) {
                double d = want_s - have_s;
                if (d > 0.002) std::this_thread::sleep_for(std::chrono::milliseconds((long long)(d * 1000.0)));
            }
        }
    }

    double el = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    double mbps = (el > 0) ? (sent_bytes * 8.0 / (el * 1e6)) : 0.0;
    printf("sent %lld frames / %lld payload bytes in %.3f s -> payload %.2f Mbps (plain socket, NO npcap)\n",
           frames, sent_bytes, el, mbps);

    closesocket(s);
    WSACleanup();
    return 0;
}
