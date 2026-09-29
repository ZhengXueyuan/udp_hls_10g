import pymupdf

PDF = r"D:\repo\XCKU5PMini\图纸\核心板\XCKU5PMini.pdf"
doc = pymupdf.open(PDF)

# page 5 (0-based) : core board sheet with Y1 + SYS_CLK_P/N
p = doc[5]
p.set_rotation(0)
r = pymupdf.Rect(430, 620, 900, 760)
p.get_pixmap(matrix=pymupdf.Matrix(6, 6), clip=r).save("pg5_osc_wide.png")
r2 = pymupdf.Rect(520, 640, 780, 730)
p.get_pixmap(matrix=pymupdf.Matrix(14, 14), clip=r2).save("pg5_osc_zoom.png")
print("page5 rect:", p.rect, "textlen", len(p.get_text()))

# page 1 : Y2 (MGT225_CLK0) circuit, for comparison
p1 = doc[1]
p1.set_rotation(0)
r3 = pymupdf.Rect(420, 360, 720, 470)
p1.get_pixmap(matrix=pymupdf.Matrix(12, 12), clip=r3).save("pg1_y2_osc.png")
print("page1 rect:", p1.rect)
