set -u
BAT='D:\repo\XCKU5PMini\udp_hls_10g\_proj_10g\notes\p7b_rate8\sim\run_tb_app_udp_p7b.bat'
for m in pos splitoff portout badcrc nopeer neglearn; do
  cmd //c "$BAT $m wide" > /dev/null 2>&1; rc=$?
  echo "wide/$m RC=$rc"
done
for m in pos neglearn; do
  cmd //c "$BAT $m def" > /dev/null 2>&1; rc=$?
  echo "def/$m RC=$rc"
done
