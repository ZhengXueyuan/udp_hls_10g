# mkbat.py -- rewrite .bat files with CRLF line endings (project rule).
# Usage:  python mkbat.py <file.bat> [...]
# Written as a file rather than a -c one-liner because the Windows paths and
# backslashes do not survive bash -> python -c quoting.
import sys

for p in sys.argv[1:]:
    with open(p, 'rb') as fh:
        d = fh.read()
    d = d.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
    with open(p, 'wb') as fh:
        fh.write(d)
    print('CRLF ok', p, len(d), 'bytes')
