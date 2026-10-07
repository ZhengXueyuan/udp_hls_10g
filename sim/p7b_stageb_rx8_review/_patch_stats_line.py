import io
p = 'tb_rx8_evphase_review.v'
s = io.open(p, encoding='utf-8', newline='').read()
old = '        $fwrite(f_s, "MID  rxb=%0d mm=%0d acc=%0d\\n", m_rxb, m_mm, mn);'
new = old + '\n        $fwrite(f_s, "CROSS rxb=%0d mm=%0d (expect 32 / 2)\\n", x_rxb, x_mm);'
n = s.count(old)
assert n == 1, n
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('patched stats line')
