import io, sys
p = "run_d6.bat"
s = io.open(p, "r", newline="").read()
s = s.replace("> /dev/null", "> NUL")
s = s.replace(">/dev/null", ">NUL")
io.open(p, "w", newline="").write(s)
print("patched")
