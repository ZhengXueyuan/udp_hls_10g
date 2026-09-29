# fifo_src.f -- gate unit_fifo (sim/retxsim2/run_tb_frame_fifo.bat)
# TB: tb/tb_frame_fifo.v (xelab top xil_defaultlib.tb_frame_fifo)
#
# The DUT source is passed as %1 (documented interface of that gate: it also
# supports the legacy stage-1 DUT sim/retxsim2/frame_fifo_old.v), so it CANNOT
# be declared here.  The runner passes rtl/frame_fifo.v, whose bytes are hashed
# through chain_src.f (same file), and the gate's own guard checks %SRC% with
# checkpaths --path "%SRC%" before compiling anything.
tb/tb_frame_fifo.v
