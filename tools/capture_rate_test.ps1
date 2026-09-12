# capture_rate_test.ps1 — diag19 板测: tshark 抓包 + 速率测试 + 怪帧分析
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File tools/capture_rate_test.ps1 [MB]
# 流程: tshark 后台抓以太网 2 -> pc_tcp_rate_test.py -> 停抓 -> 分析报告
param([int]$MB = 64)
$ErrorActionPreference = "Continue"
$root = "D:\repo\ECO\udp_hls_10g"
$tshark = "C:\Program Files\Wireshark\tshark.exe"
$cap = "$root\rate_test.pcapng"

# 后台抓包 (板+PC 全部流量)
$capProc = Start-Process -FilePath $tshark -ArgumentList @(
    "-i", "8", "-w", $cap, "-q"
) -PassThru -WindowStyle Hidden -RedirectStandardError "$root\tshark_err.txt"

Start-Sleep -Seconds 2
Write-Output "=== capture started, running rate test $MB MB ==="
& "C:\Users\zhxue\anaconda3\python.exe" "$root\tools\pc_tcp_rate_test.py" $MB
$testExit = $LASTEXITCODE

Start-Sleep -Seconds 3
Stop-Process -Id $capProc.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

Write-Output "=== 怪帧计数 (ip.len==1500 但线上 < 100 字节) ==="
& $tshark -r $cap -Y "ip.len == 1500 && frame.len < 100" -T fields -e frame.number -e frame.len -e ip.len 2>$null | Measure-Object -Line | Select-Object -ExpandProperty Lines

Write-Output "=== 帧长分布 (board->PC 方向) ==="
& $tshark -r $cap -Y "eth.src == 00:0a:35:01:fe:c0" -T fields -e frame.len 2>$null |
    Group-Object | Sort-Object { [int]$_.Name } | Select-Object -First 12 |
    ForEach-Object { "{0,5} bytes: {1}" -f $_.Name, $_.Count }

Write-Output "=== PC 重传/dup-ACK (自愈过程) ==="
& $tshark -r $cap -Y "tcp.analysis.retransmission || tcp.analysis.duplicate_ack" -T fields -e frame.number -e tcp.analysis.retransmission -e tcp.analysis.duplicate_ack 2>$null |
    Measure-Object -Line | Select-Object -ExpandProperty Lines

Write-Output "=== 板 ACK/echo 帧总数 ==="
& $tshark -r $cap -Y "eth.src == 00:0a:35:01:fe:c0 && tcp" -T fields -e frame.number 2>$null |
    Measure-Object -Line | Select-Object -ExpandProperty Lines

Write-Output ("rate test exit: " + $testExit)
