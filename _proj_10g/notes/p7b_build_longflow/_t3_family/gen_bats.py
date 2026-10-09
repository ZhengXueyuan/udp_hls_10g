import os

root = "D:/repo/XCKU5PMini/udp_hls_10g"
base = root + "/_proj_10g/notes/p7b_build_longflow"
arch = root + "/_proj_10g/notes/p7b_build_archive"
tcl = (base + "/_t3_family/t3_query.tcl").replace("/", "\\")
VIV = "C:\\AMDDesignTools\\2025.2\\Vivado\\bin\\vivado.bat"

rungs = {
    "C1": arch + "/20261009_045518/wrapper_p4_routed.dcp",
    "S1": arch + "/20261009_053203/wrapper_p4_routed.dcp",
    "S2": arch + "/20261009_061024/wrapper_p4_routed.dcp",
    "S3": root + "/vivado_prj/p7b_ku5p_prj.runs/impl_1/wrapper_p4_routed.dcp",
    "R1": arch + "/20261009_041855/wrapper_p4_routed.dcp",
}

for tag, dcp in rungs.items():
    dcpw = dcp.replace("/", "\\")
    assert os.path.exists(dcp), dcp
    out = (base + "/_t3_family/out/" + tag).replace("/", "\\")
    cmd = ('"%s" -mode batch -nojournal -nolog -source "%s" -tclargs %s "%s" "%s" > "%s\\t3_stdout_%s.txt" 2>&1'
           % (VIV, tcl, tag, dcpw, out, out, tag))
    lines = [
        "@echo off",
        "setlocal",
        'set OUT=' + out,
        'if not exist "%OUT%" mkdir "%OUT%"',
        'cd /d "%OUT%"',
        cmd,
        "echo BAT_RC=%ERRORLEVEL%",
    ]
    body = "\r\n".join(lines) + "\r\n"
    body.encode("ascii")  # fail loudly if non-ascii slips in
    p = base + "/_t3_family/run_" + tag + ".bat"
    open(p, "wb").write(body.encode("ascii"))
    print("wrote", p)

# --- 诊断用 (diag) bat: 只跑 t3_diag_count.tcl ---
TCL_DIAG = (base + "/_t3_family/t3_diag_count.tcl").replace("/", "\\")
if os.path.exists(TCL_DIAG):
    for tag, dcp in rungs.items():
        dcpw = dcp.replace("/", "\\")
        out = (base + "/_t3_family/out/" + tag).replace("/", "\\")
        cmd = ('"%s" -mode batch -nojournal -nolog -source "%s" -tclargs %s "%s" > "%s\\diag_%s.txt" 2>&1'
               % (VIV, TCL_DIAG, tag, dcpw, out, tag))
        lines = ["@echo off", "setlocal", 'cd /d "%s"' % out, cmd, "echo BAT_RC=%ERRORLEVEL%"]
        body = "\r\n".join(lines) + "\r\n"
        body.encode("ascii")
        p = base + "/_t3_family/diag_" + tag + ".bat"
        open(p, "wb").write(body.encode("ascii"))
        print("wrote", p)
