import pymupdf
PDF = r"D:\repo\XCKU5PMini\资料\PDF\ds922-kintex-ultrascale-plus.pdf"
doc = pymupdf.open(PDF)
p = doc[13]
p.set_rotation(0)
p.get_pixmap(matrix=pymupdf.Matrix(5,5), clip=pymupdf.Rect(60, 300, 560, 400)).save("ds922_p13_pod12.png")
p.get_pixmap(matrix=pymupdf.Matrix(5,5), clip=pymupdf.Rect(60, 40, 560, 200)).save("ds922_p13_hp_diff.png")
print("ok")
