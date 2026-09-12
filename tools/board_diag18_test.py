#!/usr/bin/env python
"""diag18 板测: 读 COM8 UART 快照 N 秒 + 同时抓包计数板 MAC 帧。

用法: python tools/board_diag18_test.py [秒数=25]
流程: 开串口读 N 秒 (9600-8N1), 并行启动 pktmon 抓 comp 102,
结束后转换 etl 并统计板 MAC (00-0a-35-01-fe-c0) 帧数。
判读:
  - UART 有行: FPGA 活着; SC/SF 递增 = 慢路径通; SV 周期归零 = 看门狗循环;
    HR=0 = HLS 复位中。
  - 板 MAC 帧数 > 0: HLS 自发行文 (UDP HELLO ~5s 一个) 恢复 = 修复生效。
"""
import subprocess
import sys
import threading
import time

N = int(sys.argv[1]) if len(sys.argv) > 1 else 25


def uart_reader():
    try:
        import serial  # pyserial 或 manual System.IO 备选
    except ImportError:
        # 无 pyserial: 走 PowerShell System.IO.Ports (返回原始文本)
        ps = ("$p = New-Object System.IO.Ports.SerialPort('COM8',9600,"
              "[System.IO.Ports.Parity]::None,8,[System.IO.Ports.StopBits]::One); "
              "$p.ReadTimeout = 1000; $p.Open(); $t0=[DateTime]::Now; "
              "while ((([DateTime]::Now)-$t0).TotalSeconds -lt %d) "
              "{ try { Write-Output $p.ReadExisting() } catch {} ; "
              "Start-Sleep -Milliseconds 200 }; $p.Close()" % N)
        out = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                             capture_output=True, text=True, timeout=N + 20)
        print("=== UART (System.IO.Ports) ===")
        print(out.stdout)
        return
    s = serial.Serial("COM8", 9600, timeout=1)
    t0 = time.time()
    print("=== UART (pyserial) ===")
    while time.time() - t0 < N:
        data = s.read(4096)
        if data:
            print(data.decode("latin-1"), end="", flush=True)
    s.close()


def main():
    t = threading.Thread(target=uart_reader, daemon=True)
    t.start()
    subprocess.run(["powershell", "-NoProfile", "-Command",
                    "pktmon start --capture --pkt-size 0 --comp 102 "
                    "-f PktMon.etl; Start-Sleep -Seconds %d; pktmon stop" % N],
                   capture_output=True, text=True)
    t.join(timeout=N + 10)
    subprocess.run(["pktmon", "etl2txt", "PktMon.etl", "-o", "PktMon.txt"],
                   capture_output=True)
    raw = open("PktMon.txt", "rb").read().decode("utf-16-le", "ignore")
    n = raw.count("00-0a-35-01-fe-c0")
    print("=== 板 MAC 帧数 (capture %ds): %d ===" % (N, n))
    if n:
        print("HLS 自发行文恢复!" if n >= 2 else "板有发帧 (应答/HELLO)")


if __name__ == "__main__":
    main()
