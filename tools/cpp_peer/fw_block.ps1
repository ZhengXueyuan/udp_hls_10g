# fw_block.ps1 -- silence the Windows kernel for one board IP.
#
# WHY: the synthetic peer (peer.exe) speaks TCP itself over npcap raw framing.
# The Windows kernel still sees every frame that arrives on the NIC, does not
# recognise the 4-tuple as one of its own connections, and answers with a RST.
# That RST tears down the board-side TCB and pollutes board counters.
#
#     drop rule on the board IP  ->  kernel never sees the frame  ->  no RST.
#     npcap taps BELOW WFP, so capture and injection are unaffected.
#
# Usage (run from an ELEVATED PowerShell):
#   powershell -NoProfile -ExecutionPolicy Bypass -File fw_block.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File fw_block.ps1 -BoardIp 192.168.100.2
#   powershell -NoProfile -ExecutionPolicy Bypass -File fw_block.ps1 -Status
#   powershell -NoProfile -ExecutionPolicy Bypass -File fw_block.ps1 -Remove
#
# The board IP / subnet changes with the project, so it is a parameter, never
# hard-coded.  is blocked inbound AND outbound: inbound is what stops the RST,
# outbound keeps the kernel from ARPing or probing the board behind our back.

param(
    [string]$BoardIp = "192.168.100.2",
    [switch]$Status,
    [switch]$Remove
)

$ErrorActionPreference = "Stop"
$prefix = "cpp_peer_block"

function Show-Rules {
    $rules = Get-NetFirewallRule -DisplayName "$prefix*" -ErrorAction SilentlyContinue
    if (-not $rules) {
        Write-Output "no $prefix* rules present (kernel is NOT blocked)"
        return
    }
    foreach ($r in $rules) {
        $addr = ($r | Get-NetFirewallAddressFilter).RemoteAddress -join ","
        Write-Output ("{0}  dir={1}  action={2}  enabled={3}  remote={4}" -f `
            $r.DisplayName, $r.Direction, $r.Action, $r.Enabled, $addr)
    }
}

if ($Status) {
    Show-Rules
    exit 0
}

# always clear our own old rules first so the IP can change between runs
Get-NetFirewallRule -DisplayName "$prefix*" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

if ($Remove) {
    Write-Output "removed $prefix* rules -- kernel sees the board again"
    exit 0
}

foreach ($dir in @("Inbound", "Outbound")) {
    New-NetFirewallRule `
        -DisplayName "$prefix-$dir-$BoardIp" `
        -Direction $dir `
        -Action Block `
        -RemoteAddress $BoardIp `
        -Profile Any `
        -Protocol Any `
        -Description "Synthetic TCP peer (tools/cpp_peer): stop the kernel from owning/$BoardIp connections" |
        Out-Null
}

Write-Output "blocked kernel traffic to/from $BoardIp (inbound + outbound, all protocols, all profiles)"
Write-Output ""
Show-Rules
Write-Output ""
Write-Output "npcap capture/injection is unaffected (it taps below WFP)."
Write-Output "Restore with: fw_block.ps1 -Remove"
