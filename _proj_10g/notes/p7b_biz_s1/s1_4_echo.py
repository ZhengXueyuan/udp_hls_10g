import socket, os, sys, time
port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
n = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("192.168.100.100", 0))
s.settimeout(0.5)
ok = bad = 0
t0 = time.time()
for i in range(n):
    p = os.urandom(64 + i % 257)
    s.sendto(p, ("192.168.100.2", port))
    try:
        d, _ = s.recvfrom(2048)
        if d == p: ok += 1
        else: bad += 1
    except socket.timeout:
        bad += 1
print("HLS_ECHO port=%d n=%d ok=%d bad=%d dur_s=%.3f" % (port, n, ok, bad, time.time() - t0))
