p = r'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_p5wrapper_diag_20261010\work\E\run.bat'
b = open(p, 'rb').read()
old = b'set BD=%REPO_ROOT%\\board'
assert old in b, 'BD line not found'
b = b.replace(old, b'set BD=%~dp0.')
open(p, 'wb').write(b)
print('ok')
