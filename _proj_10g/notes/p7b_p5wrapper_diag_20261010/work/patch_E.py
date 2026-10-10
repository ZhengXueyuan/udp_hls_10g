import shutil

SRC = r'D:\repo\XCKU5PMini\udp_hls_10g\board\wrapper_p4.v'
DST = r'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_p5wrapper_diag_20261010\work\E\wrapper_p4.v'

b = open(SRC, 'rb').read()
pairs = [
    (b'    assign txsrc_tdata = m_tx_tdata;',
     b'    assign m_tx_tdata  = txsrc_tdata;'),
    (b'    assign txsrc_tkeep = m_tx_tkeep;',
     b'    assign m_tx_tkeep  = txsrc_tkeep;'),
    (b'    assign txsrc_tlast = m_tx_tlast;',
     b'    assign m_tx_tlast  = txsrc_tlast;'),
    (b'    assign txsrc_tvalid= m_tx_tvalid;',
     b'    assign m_tx_tvalid = txsrc_tvalid;'),
    (b'    assign m_tx_tready = txsrc_tready;',
     b'    assign txsrc_tready = m_tx_tready;'),
]
for o, n in pairs:
    assert b.count(o) == 1, (o, b.count(o))
    b = b.replace(o, n)
open(DST, 'wb').write(b)

# uart_dbg / util_gmii_to_rgmii: byte copies (unchanged)
for f in ('uart_dbg.v', 'util_gmii_to_rgmii.v'):
    shutil.copyfile(r'D:\repo\XCKU5PMini\udp_hls_10g\board\%s' % f,
                    r'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_p5wrapper_diag_20261010\work\E\%s' % f)
print('E wrapper written (5 alias lines flipped)')
