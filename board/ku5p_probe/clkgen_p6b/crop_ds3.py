import pymupdf
PDF = r"D:\repo\XCKU5PMini\资料\PDF\ds922-kintex-ultrascale-plus.pdf"
doc = pymupdf.open(PDF)
p = doc[13]
p.set_rotation(0)
p.get_pixmap(matrix=pymupdf.Matrix(5,5), clip=pymupdf.Rect(60, 130, 560, 240)).save("ds922_p13_hp_diff2.png")
p.get_pixmap(matrix=pymupdf.Matrix(5,5), clip=pymupdf.Rect(60, 320, 560, 400)).save("ds922_p13_pod12.png")
print("ok")
