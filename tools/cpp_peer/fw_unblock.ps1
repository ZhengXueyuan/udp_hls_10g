# fw_unblock.ps1 -- restore normal Windows networking for the board IP.
#
# Removes every firewall rule this tool created (prefix cpp_peer_block).
# Thin wrapper around fw_block.ps1 -Remove so the intent is obvious at the
# call site and so there is a single place that knows the rule prefix.
#
# Usage (elevated PowerShell):
#   powershell -NoProfile -ExecutionPolicy Bypass -File fw_unblock.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File fw_unblock.ps1 -BoardIp 192.168.100.2
#   powershell -NoProfile -ExecutionPolicy Bypass -File fw_unblock.ps1 -Status

param(
    [string]$BoardIp = "192.168.100.2",
    [switch]$Status
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $here "fw_block.ps1") -BoardIp $BoardIp -Remove:$true -Status:$Status
