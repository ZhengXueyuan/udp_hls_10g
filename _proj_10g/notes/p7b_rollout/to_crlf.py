import sys

p = sys.argv[1]
b = open(p, "rb").read()
n0 = (b.count(b"\r\n"), b.count(b"\n"))
b = b.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
open(p, "wb").write(b)
print("%s  before CRLF=%d LF=%d  ->  after CRLF=%d LF=%d  size=%d"
      % (p, n0[0], n0[1], b.count(b"\r\n"), b.count(b"\n"), len(b)))
