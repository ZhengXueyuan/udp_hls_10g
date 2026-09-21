#!/bin/bash
# board_udprx_ab.sh -- independent board A/B for the app-UDP RX byte-fidelity defect
#   usage: board_udprx_ab.sh <paylen> <rate_mbps> <bytes> <label> [--noprogram]
# Program (fresh design reset => app RX LFSR back to SEED, UMM counter cleared),
# then one pattern run, then read the UART status line and print the counters.
set -u
IFACE='\Device\NPF_{528A3E8C-9A80-4D17-96A0-48F3FD70186E}'
SRCMAC='FC:9D:05:7D:88:6B'
PY=/c/Users/zhxue/anaconda3/python.exe
ROOT=/d/repo/ECO/udp_hls_10g
PL=$1; RATE=$2; NBYTES=$3; LABEL=$4; NOPROG=${5:-}

if [ "$NOPROG" != "--noprogram" ]; then
  echo "=== [$(date +%H:%M:%S)] PROGRAM (reset design) ==="
  cmd //c "D:\\repo\\ECO\\udp_hls_10g\\board\\run_program_p5.bat" 2>&1 | grep -E "PROGRAM_OK|PROGRAM_FAILED|NO_TARGETS|TARGETS:" | tail -2
  sleep 3
fi

echo "=== [$(date +%H:%M:%S)] RUN paylen=$PL rate=$RATE bytes=$NBYTES ($LABEL) ==="
cd "$ROOT/tools/cpp_peer"
./peer.exe --iface "$IFACE" --src-mac "$SRCMAC" \
  --udp-send-pattern "$NBYTES" --udp-paylen "$PL" --rate-mbps "$RATE" \
  --sport 8081 --dport 8081 > "/tmp/peer_$LABEL.log" 2>&1
grep -E "发送完成|pattern      :|frame loss|VERDICT" "/tmp/peer_$LABEL.log"
sleep 3

"$PY" - "$LABEL" <<'EOF'
import sys, time, re, serial
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
lab = sys.argv[1]
sp = serial.Serial('COM9', 9600, timeout=1.0)
t0 = time.time(); buf = b''
while time.time() - t0 < 3.0:
    buf += sp.read(2048)
sp.close()
txt = buf.decode('ascii', 'replace')
m = re.findall(r'URB=([0-9A-F]+) UMM=([0-9A-F]+) URF=([0-9A-F]+) UOV=([0-9A-F]+) '
               r'UPC=([0-9A-F]+) UPA=([0-9A-F]+) UTB=([0-9A-F]+) UTF=([0-9A-F]+)', txt)
if not m:
    print("NO_STATUS_MATCH"); print(txt[-300:]); sys.exit(1)
names = ['URB','UMM','URF','UOV','UPC','UPA','UTB','UTF']
d = {n: int(v, 16) for n, v in zip(names, m[-1])}
print("[%s] " % lab + " ".join("%s=%d" % (n, d[n]) for n in names))
if d['URB']:
    print("[%s] UMM/URB = %.4f%%   UMM/frame = %.3f" %
          (lab, 100.0*d['UMM']/d['URB'], d['UMM']/d['URF'] if d['URF'] else -1))
EOF
