#!/bin/bash
# ctr.sh -- 微窗 stall 轮: 对端内核计数器连续采样器 (本轮**新增**插桩; 不碰 /tmp/p7b_biz)
#   用法 (对端): TAG=<tag> bash /tmp/p7b_microwin/ctr.sh   → /tmp/mw_<TAG>_ctr.log
#   采样 = nstat -az 的 Tcp/TcpExt 子集 (含 TCPRcvQDrop / TCPZeroWindowDrop / TcpInErrs
#   这三个上一轮**没查**的计数器) + 每点时间戳。周期 0.2 s。
TAG=${TAG:?need TAG}
PAT='^Tcp(InSegs|OutSegs|RetransSegs|InErrs|CurrEstab)|^TcpExt(TCPOFOQueue|TCPOFODrop|TCPOFOMerge|OfoPruned|RcvPruned|PruneCalled|TCPRcvCollapsed|TCPRcvQDrop|TCPBacklogDrop|TCPZeroWindowDrop|TCPFromZeroWindowAdv|TCPToZeroWindowAdv|TCPWantZeroWindowAdv|TCPAckCompressed|TCPACKSkippedSeq|TCPFastRetrans|TCPTimeouts|TCPLossProbes|TCPDelayedACKLost|DelayedACKs|DelayedACKLocked|TCPDSACKRecv|TCPDSACKOfoRecv|TCPSynRetrans|TCPPureAcks|TCPHPAcks|TCPMemoryPressuresChrono|TCPMemoryPressures|TCPWqueueTooBig)'
while :; do
  echo "CTR_T $(date +%s.%N)"
  nstat -az 2>/dev/null | grep -E "$PAT"
  sleep 0.2
done
