@echo off
setlocal
set ROOT=%~dp0
for %%C in (A1_portconn A2_expr B1_clean C1_benign) do (
  if not exist "%ROOT%%C" mkdir "%ROOT%%C"
  pushd "%ROOT%%C"
  echo ===== CASE %%C =====
  xvlog "%ROOT%%C.v" > xvlog.log 2>&1
  echo XVLOG_RC=%errorlevel%
  type xvlog.log
  popd
)
endlocal
