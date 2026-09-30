# -*- coding: utf-8 -*-
"""Patch run_tb_p7b_chain.bat so a mutation run can point at a scratch copy of
wrapper_p4.v / the MAC rtl via %P7B_MUT% (same pattern as run_tb_mac_10g.bat's
%P7B_RTL%).  ASCII + CRLF (project rule for .bat)."""
import io

P = 'D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/p7b_chain/sim/run_tb_p7b_chain.bat'
raw = io.open(P, 'rb').read().decode('ascii')
nl = '\r\n' if '\r\n' in raw else '\n'
lines = raw.split(nl)

out = []
done = False
for l in lines:
    if l.startswith('echo %ROOT%\\board\\wrapper_p4.v'):
        out.append('REM   P7B_MUT: optional override (mutation testing) -- when set, wrapper_p4.v')
        out.append('REM            and the MAC rtl are taken from that scratch directory instead.')
        out.append('set "WRAP=%ROOT%\\board\\wrapper_p4.v"')
        out.append('set "MACD=%ROOT%\\_proj_10g\\p7b_mac\\rtl"')
        out.append('if not "%P7B_MUT%"=="" set "WRAP=%P7B_MUT%\\wrapper_p4.v"')
        out.append('if not "%P7B_MUT%"=="" set "MACD=%P7B_MUT%"')
        out.append('if not exist "%WRAP%" (echo [PATHGUARD FAIL] no wrapper_p4.v & exit /b 1)')
        out.append('echo %WRAP%                                          >> files.f')
        done = True
        continue
    if l.startswith('echo %ROOT%\\_proj_10g\\p7b_mac\\rtl\\'):
        out.append('echo %MACD%\\crc32_64.v                              >> files.f')
        out.append('echo %MACD%\\mac_rx_10g.v                            >> files.f')
        out.append('echo %MACD%\\mac_tx_10g.v                            >> files.f')
        continue
    out.append(l)
assert done, 'anchor not found'
s = nl.join(out)
assert all(ord(c) < 128 for c in s), 'non-ASCII'
io.open(P, 'wb').write(s.encode('ascii'))
print('bat patched for %P7B_MUT%')
