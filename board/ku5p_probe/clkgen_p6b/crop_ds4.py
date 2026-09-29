import pymupdf
PDF = r"D:\repo\XCKU5PMini\资料\PDF\ds922-kintex-ultrascale-plus.pdf"
doc = pymupdf.open(PDF)
p = doc[13]
p.set_rotation(0)
p.get_pixmap(matrix=pymupdf.Matrix(6,6), clip=pymupdf.Rect(0, 320, 400, 420)).save("ds922_t15_full.png")
print(p.rect)
