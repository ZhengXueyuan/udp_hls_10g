import pymupdf

PDF = r"D:\repo\XCKU5PMini\资料\PDF\ds922-kintex-ultrascale-plus.pdf"
doc = pymupdf.open(PDF)
for i, page in enumerate(doc):
    txt = page.get_text()
    for key in ("DC Input Levels for Differential POD10",
                "Complementary Differential SelectIO DC Input and Output Levels for HP",
                "LVDS DC Specifications (LVDS)"):
        if key in txt:
            print(f"page {i}: '{key}'")
            for r in page.search_for(key):
                print("   rect:", r)
