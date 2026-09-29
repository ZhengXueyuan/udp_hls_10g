import sys, pymupdf

PDF = r"D:\repo\XCKU5PMini\图纸\核心板\XCKU5PMini.pdf"
doc = pymupdf.open(PDF)
print("pages:", doc.page_count)
terms = ["SYS_CLK_P", "SYS_CLK_N", "SG7050", "MGT225_CLK0", "GCLK"]
for i, page in enumerate(doc):
    txt = page.get_text()
    hits = [t for t in terms if t in txt]
    if hits:
        print(f"--- page {i}: rotation={page.rotation} hits={hits}")
        for t in hits:
            for r in page.search_for(t):
                print(f"      {t}: {r}")
