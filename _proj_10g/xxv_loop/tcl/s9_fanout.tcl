set root "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_loop"
open_project "$root/pcs64_2ch/pcs64_2ch.xpr"
open_run impl_1
foreach n {vio_pay_sel vio_gt_loopback} {
    set nets [get_nets -quiet -hier -filter "NAME =~ */$n"]
    puts "S9_NET $n n=[llength $nets]"
    foreach nt $nets {
        puts "S9_NET $nt loads:[get_pins -quiet -of_objects $nt -filter {DIRECTION == IN}]"
    }
}
puts "S9_DONE"
close_project -quiet
