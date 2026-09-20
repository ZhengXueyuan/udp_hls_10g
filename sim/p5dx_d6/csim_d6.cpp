//=============================================================================
// csim_d6.cpp — P5d-D6 槽释放修复的 **csim 逻辑检查** (非 RTL 判据)
//=============================================================================
// 与 sim/p5dx/exp2/tb_hls_slotleak.v 同一刺激 (frames_b.memh / frames_meta.memh,
// 由 ../p5dx/exp2/gen_frames.py 产生 — 本目录内是副本), 但跑在 C++ 模型上:
// 只判**逻辑** (bare SYN 到达非空闲槽时是否产生 CFG_DEL + CFG_ADD 与 SYN+ACK),
// 不判调度/时序 — RTL 判据仍以 exp2 的 xsim 门为准。
//=============================================================================
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <vector>
#include <string>
#include "hls_stream.h"
#include "../../hls/src/eth_types.h"

using namespace std;

extern uint16_t tcp_slot_drop_count();   // hls/src/layer_tcp.cpp (csim 观测口)

extern void udp_echo(bool reset_n, hls::stream<gmii_byte_t> &rx,
                     hls::stream<gmii_byte_t> &tx, hls::stream<gmii_byte_t> &msg,
                     hls::stream<ap_uint<32> > &cfg,
                     bool &d0, bool &d1, bool &d2, bool &d3);

static hls::stream<gmii_byte_t> g_rx, g_tx, g_msg;
static hls::stream<ap_uint<32> > g_cfg;
static bool l0, l1, l2, l3;
static gmii_byte_t dummy;

static vector<uint8_t>  txf;   // 当前窗口内已收完的 tx 帧 (拼接)
static vector<int>      txn;   // 每帧字节数
static vector<uint8_t>  cur;   // 组帧中
static vector<uint32_t> cfgw;  // 当前窗口内 cfg 词

static void tick(int n) {
    for (int i = 0; i < n; i++) {
        udp_echo(true, g_rx, g_tx, g_msg, g_cfg, l0, l1, l2, l3);
        while (!g_tx.empty()) {
            gmii_byte_t b = g_tx.read();
            cur.push_back(b.data.to_uint());
            if (b.last) { txn.push_back((int)cur.size()); txf.insert(txf.end(), cur.begin(), cur.end()); cur.clear(); }
        }
        while (!g_cfg.empty()) cfgw.push_back(g_cfg.read().to_uint());
        while (!g_msg.empty()) (void)g_msg.read(dummy);
    }
}

// 在一帧原始字节 (含 8B 前导 + 末尾 4B FCS) 里抽 TCP flags, 返回 -1 = 非 IPv4/TCP
static int tcp_flags(const uint8_t *b, int n) {
    int p = -1;
    for (int k = 0; k + 1 < n; k++) if (b[k] == 0x55 && b[k + 1] == 0xD5) { p = k + 1; break; }
    if (p < 0) return -1;
    const uint8_t *e = b + p + 1;                 // eth 起点
    int left = n - (p + 1);
    if (left < 34) return -1;
    if (((e[12] << 8) | e[13]) != 0x0800) return -1;
    if (e[14 + 9] != 6) return -1;                // ip proto
    return e[14 + 20 + 13];                       // tcp flags
}

static int count_synack() {
    int n = 0, off = 0;
    for (size_t i = 0; i < txn.size(); i++) {
        int f = tcp_flags(&txf[off], txn[i]);
        if (f >= 0 && (f & 0x02) && (f & 0x10)) n++;
        off += txn[i];
    }
    return n;
}

static vector<string> frame_desc() {
    vector<string> v; int off = 0;
    for (size_t i = 0; i < txn.size(); i++) {
        int f = tcp_flags(&txf[off], txn[i]);
        char s[64];
        if (f < 0) snprintf(s, sizeof s, "non-tcp(%dB)", txn[i]);
        else snprintf(s, sizeof s, "TCP[%s%s%s%s]",
                      (f & 0x02) ? "SYN," : "", (f & 0x10) ? "ACK," : "",
                      (f & 0x01) ? "FIN," : "", (f & 0x04) ? "RST," : "");
        v.push_back(s); off += txn[i];
    }
    return v;
}

static int n_cmd(int cmd) {
    int n = 0;
    for (size_t i = 0; i + 7 < cfgw.size(); i += 8)
        if (((cfgw[i] >> 8) & 0xFF) == (uint32_t)cmd) n++;
    return n;
}
static string slots(int cmd) {
    string s; char b[16];
    for (size_t i = 0; i + 7 < cfgw.size(); i += 8)
        if (((cfgw[i] >> 8) & 0xFF) == (uint32_t)cmd) { snprintf(b, sizeof b, "%u,", cfgw[i] & 0xFF); s += b; }
    return s;
}

int main() {
    vector<uint8_t> blob;
    {
        FILE *f = fopen("D:/repo/ECO/udp_hls_10g/sim/p5dx_d6/frames_b.memh", "r");
        if (!f) { printf("csim_d6: frames_b.memh missing\n"); return 1; }
        unsigned v; while (fscanf(f, "%x", &v) == 1) blob.push_back((uint8_t)v);
        fclose(f);
    }
    int nfr = 0; vector<int> fo, fl;
    {
        FILE *f = fopen("D:/repo/ECO/udp_hls_10g/sim/p5dx_d6/frames_meta.memh", "r");
        if (!f) { printf("csim_d6: frames_meta.memh missing\n"); return 1; }
        if (fscanf(f, "%d", &nfr) != 1) return 1;
        for (int i = 0; i < nfr; i++) { int a = 0, b = 0; if (fscanf(f, "%d %d", &a, &b) != 2) return 1; fo.push_back(a); fl.push_back(b); }
        fclose(f);
    }
    vector<string> tags;
    {
        FILE *f = fopen("D:/repo/ECO/udp_hls_10g/sim/p5dx_d6/frames_tags.txt", "r");
        if (f) { char buf[128]; while (fgets(buf, sizeof buf, f)) { string s = buf; while (!s.empty() && (s[s.size()-1] == '\n' || s[s.size()-1] == '\r')) s.erase(s.size()-1); if (!s.empty()) tags.push_back(s); } fclose(f); }
    }
    printf("csim_d6: frames=%d bytes=%d\n", nfr, (int)blob.size());

    for (int i = 0; i < 5; i++) udp_echo(false, g_rx, g_tx, g_msg, g_cfg, l0, l1, l2, l3);
    while (!g_tx.empty()) (void)g_tx.read();
    while (!g_cfg.empty()) (void)g_cfg.read();

    const int IDLE = 30000;  // 每帧后空闲拍 (与 exp2 的 GAP=20000 同量纲; 远小于 RTO=10M)

    printf("=======================================================================\n");
    for (int i = 0; i < nfr; i++) {
        txf.clear(); txn.clear(); cur.clear(); cfgw.clear();
        for (int k = 0; k < fl[i]; k++) {
            gmii_byte_t b; b.data = blob[fo[i] + k]; b.last = (k == fl[i] - 1);
            g_rx.write(b);
            tick(1);
        }
        tick(IDLE);
        vector<string> fd = frame_desc();
        printf("[%2d] %-14s SYN+ACK=%d CFG_ADD=%d CFG_DEL=%d\n",
               i, (i < (int)tags.size() ? tags[i].c_str() : "frame"), count_synack(), n_cmd(0), n_cmd(1));
        printf("     tx  : ");
        if (fd.empty()) printf("(none)");
        for (size_t k = 0; k < fd.size(); k++) printf("%s%s", k ? "; " : "", fd[k].c_str());
        printf("\n     cfg : ADD_slots=%s DEL_slots=%s\n", slots(0).c_str(), slots(1).c_str());
    }
    printf("=======================================================================\n");
    // ---- 相位 2: 定向覆盖 T_LAST_ACK + bare SYN (签名 #3) ----
    // 顺序 A1 SYN, A2 ACK, A4 FIN, A5 SYN --- 主序列里 A4 的 FIN 因 A3 已把槽
    // 重建回 T_SYN_RCVD 而被 ACK 分支吃掉 (不经过 T_LAST_ACK), 故单独回放:
    // T_SYN_RCVD -(A2 ACK)-> T_ESTABLISHED -(A4 FIN)-> T_LAST_ACK -(A5 bare SYN)->
    // 必须 CFG_DEL + CFG_ADD + SYN+ACK (修前: 完全静默 --- 等已走 fast 的最终 ACK)。
    for (int i = 0; i < 5; i++) udp_echo(false, g_rx, g_tx, g_msg, g_cfg, l0, l1, l2, l3);
    while (!g_tx.empty()) (void)g_tx.read();
    while (!g_cfg.empty()) (void)g_cfg.read();
    printf("PHASE2 (T_LAST_ACK + bare SYN, 签名 #3):\n");
    {
        int order[4] = {0, 1, 5, 6};
        for (int j = 0; j < 4; j++) {
            int i = order[j];
            txf.clear(); txn.clear(); cur.clear(); cfgw.clear();
            for (int k = 0; k < fl[i]; k++) {
                gmii_byte_t b; b.data = blob[fo[i] + k]; b.last = (k == fl[i] - 1);
                g_rx.write(b);
                tick(1);
            }
            tick(IDLE);
            vector<string> fd = frame_desc();
            printf("  [%d] %-14s SYN+ACK=%d CFG_ADD=%d CFG_DEL=%d\n",
                   j, (i < (int)tags.size() ? tags[i].c_str() : "frame"), count_synack(), n_cmd(0), n_cmd(1));
            printf("      tx  : ");
            if (fd.empty()) printf("(none)");
            for (size_t k = 0; k < fd.size(); k++) printf("%s%s", k ? "; " : "", fd[k].c_str());
            printf("\n      cfg : ADD_slots=%s DEL_slots=%s\n", slots(0).c_str(), slots(1).c_str());
        }
    }

    printf("=======================================================================\n");
    printf("tcp_slot_drop_count() = %u  (期望 3 = X2/X3/X4 三个无槽 SYN)\n",
           (unsigned)tcp_slot_drop_count());
    printf("csim_d6 done\n");
    return 0;
}
