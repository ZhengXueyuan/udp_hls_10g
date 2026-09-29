@echo off
setlocal
echo alpha 8-11241 line> fs_test.log
echo WARNING: [VRFC 10-3091] x>> fs_test.log
echo benign WARNING: [VRFC 10-3609] y>> fs_test.log
echo benign WARNING: [Synth 8-6014] unused>> fs_test.log
echo --- test 1: multiple /C: options ---
findstr /I /C:"8-11241" /C:"VRFC 10-3091" fs_test.log
echo T1_rc=%errorlevel%
echo --- test 2: the full key set ---
findstr /I /C:"8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091" /C:"VRFC 10-2989" /C:"implicitly declared" fs_test.log
echo T2_rc=%errorlevel%
echo --- test 3: same key set against a BENIGN-ONLY file ---
echo benign WARNING: [VRFC 10-3609] y> fs_benign.log
echo benign WARNING: [Synth 8-6014] unused>> fs_benign.log
findstr /I /C:"8-11241" /C:"undeclared symbol" /C:"VRFC 10-3091" /C:"VRFC 10-2989" /C:"implicitly declared" fs_benign.log
echo T3_rc=%errorlevel% (1 = no hit = good)
endlocal
