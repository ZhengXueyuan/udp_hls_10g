import io, sys

p = 'run_gate_copy.bat'
b = open(p, 'rb').read()

old_root = (
    b'set "REPO_ROOT=%~dp0..\\..\\."\r\n'
    b'for %%I in ("%REPO_ROOT%") do set "REPO_ROOT=%%~fI"\r\n'
    b'if "%REPO_ROOT:~-1%"=="\\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"\r\n'
)
new_root = b'set "REPO_ROOT=D:\\repo\\XCKU5PMini\\udp_hls_10g"\r\n'
assert old_root in b, 'root block not found'
b = b.replace(old_root, new_root)

old_sim = b'set SIM=%REPO_ROOT%\\sim\\p5sim'
new_sim = b'set SIM=%~dp0.'
assert old_sim in b, 'sim line not found'
b = b.replace(old_sim, new_sim)

old_py = b'set PY=C:\\Users\\zhxue\\anaconda3\\python.exe'
assert old_py in b, 'py line not found'

open(p, 'wb').write(b)
print('patched ok')
