# ============================================================================
# s3_example.tcl -- P7b stage 3: generate the xxv_ethernet EXAMPLE DESIGN for
# each probe core and dump its file list + constraints + top-level ports.
# The example design is the canonical answer to "what clocks/resets does this
# core need", and it is a ready-made, correctly-wired buildable top.
#
# Instantiates licensed IP -> also a licence data point.
# No board access.  No git.
# ============================================================================

set root "D:/repo/XCKU5PMini/udp_hls_10g/_proj_10g/xxv_probe"

proc sec {s} { puts "\nS3 >>>>>>>>>> $s" }
catch {set_param general.maxThreads 4}

proc doex {tag} {
    global root
    sec "S3_BEGIN $tag"
    set pdir "$root/$tag"
    if {[catch {open_project "$pdir/$tag.xpr"} e]} { puts "S3_OPEN_FAIL = $e"; return }
    set ip [get_ips $tag]

    set gd "$pdir/$tag.gen/sources_1/ip/$tag"
    foreach pat {example_design} {
        set rc [catch {generate_target $pat $ip} e]
        puts "S3_GEN_$pat rc = $rc"
        if {$rc} { puts "S3_GEN_${pat}_ERR = $e" }
    }

    set exdir "$root/${tag}_ex"
    if {[file exists $exdir]} { file delete -force $exdir }
    set rc [catch {open_example_project -force -in_process -dir $exdir $ip} e]
    puts "S3_OPEN_EXAMPLE rc = $rc"
    if {$rc} { puts "S3_OPEN_EXAMPLE_ERR = $e"; close_project -quiet; return }

    catch {puts "S3_EX_PROJECT = [current_project]"}
    catch {puts "S3_EX_TOP     = [get_property top [current_fileset]]"}
    catch {puts "S3_EX_PART    = [get_property part [current_project]]"}
    foreach f [get_files -quiet] { puts "S3_EX_FILE $f" }
    foreach f [get_files -quiet -of [get_filesets constrs_1]] { puts "S3_EX_CONSTR $f" }

    puts "S3_EX_GT_XCI = [glob -nocomplain "$exdir/**/*_gt.xci"]"

    close_project -quiet
    puts "S3_END $tag"
}

doex pcs64
doex macpcs64

sec "S3 DONE"
