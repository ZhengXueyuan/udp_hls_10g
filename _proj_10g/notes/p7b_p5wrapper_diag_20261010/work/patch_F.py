p = r'D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_p5wrapper_diag_20261010\work\F\run.bat'
b = open(p, 'rb').read()

old_root = (
    b'set "REPO_ROOT=%~dp0..\\..\\."\r\n'
    b'for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"\r\n'
    b'if "%REPO_ROOT:~-1%"=="\\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"\r\n'
)
assert old_root in b
b = b.replace(old_root, b'set "REPO_ROOT=D:\\repo\\XCKU5PMini\\udp_hls_10g"\r\n')

assert b'set BD=%REPO_ROOT%\\board' in b
b = b.replace(b'set BD=%REPO_ROOT%\\board', b'set BD=%~dp0.')
assert b'set SIM=%REPO_ROOT%\\sim\\p5e_t2' in b
b = b.replace(b'set SIM=%REPO_ROOT%\\sim\\p5e_t2', b'set SIM=%~dp0.')
open(p, 'wb').write(b)
print('ok')
