import pymupdf

PDF = r"D:\repo\XCKU5PMini\图纸\核心板\XCKU5PMini.pdf"
doc = pymupdf.open(PDF)
p = doc[5]
p.set_rotation(0)
# what drives GCLK2 (right of Y1)
p.get_pixmap(matrix=pymupdf.Matrix(8, 8), clip=pymupdf.Rect(760, 560, 1115, 760)).save("pg5_gclk2.png")
# full sheet overview to see how many oscillators
p.get_pixmap(matrix=pymupdf.Matrix(1.6, 1.6), clip=pymupdf.Rect(0, 0, 1115, 799)).save("pg5_overview.png")

p1 = doc[1]
p1.set_rotation(0)
p1.get_pixmap(matrix=pymupdf.Matrix(10, 10), clip=pymupdf.Rect(430, 370, 700, 460)).save("pg1_y2_zoom.png")
print("ok")
