puts "TESTTCL_START"
puts "PATH_SSH = [catch {exec where ssh} r] -> $r"
set rc [catch {exec ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 a@192.168.0.38 "echo EXEC_SSH_OK; hostname"} out]
puts "TESTTCL_EXEC_RC = $rc"
puts "TESTTCL_EXEC_OUT = <$out>"
exit
