import io

p = 'csim_d6.cpp'
s = io.open(p, encoding='utf-8').read()

# 1) 外部声明计数读口
anchor = 'extern void udp_echo(bool reset_n'
assert anchor in s, 'anchor1'
if 'extern uint16_t tcp_slot_drop_count' not in s:
    s = s.replace(anchor,
                  'extern uint16_t tcp_slot_drop_count();   // hls/src/layer_tcp.cpp (csim 观测口)\n\n' + anchor,
                  1)

# 2) 相位 2 + 计数打印, 插在 "csim_d6 done" 之前
done = '    printf("csim_d6 done\\n");'
assert done in s, 'anchor2'
phase2 = r'''    // ---- 相位 2: 定向覆盖 T_LAST_ACK + bare SYN (签名 #3) ----
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
'''
s = s.replace(done, phase2 + done, 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('patched ok')
