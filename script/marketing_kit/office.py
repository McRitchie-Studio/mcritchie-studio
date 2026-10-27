#!/usr/bin/env python3
# Draws a marketing kit's Office files from a JSON payload that lib/marketing_kit/office.rb writes:
#   office.py slides  payload.json  out.pptx   the 12-slide template (16:9), for Drive to convert to Google Slides
#   office.py tracker payload.json  out.xlsx   the tracker workbook, for Drive to convert to a Google Sheet
# Every word and colour comes from the payload; this script only lays it out.
import json, os, sys, tempfile

def slides(d, out):
    from PIL import Image
    from pptx import Presentation
    from pptx.util import Inches, Pt
    from pptx.dml.color import RGBColor
    from pptx.enum.shapes import MSO_SHAPE
    from pptx.enum.text import PP_ALIGN, MSO_ANCHOR

    C = lambda h: RGBColor.from_string(h.lstrip("#"))
    col = {k: C(v) for k, v in d["colours"].items()}
    BLUE, ORANGE, EMBER, NAVY, WHITE, GREY, LIGHT = (col[k] for k in ("primary", "accent", "accent_on_dark", "dark", "white", "grey", "light"))
    FONT, img = d["font"], d["images"]
    W, H = Inches(13.333), Inches(7.5)
    tmp = tempfile.mkdtemp(prefix="kit-slides-")

    def fit(path, w_in, h_in, darken=None):
        """Centre-crop a photo to the slot's shape; optionally lay the dark colour over it."""
        im = Image.open(path).convert("RGB")
        want = w_in / h_in
        iw, ih = im.size
        if iw / ih > want:
            nw = int(ih * want); im = im.crop(((iw - nw) // 2, 0, (iw - nw) // 2 + nw, ih))
        else:
            nh = int(iw / want); im = im.crop((0, (ih - nh) // 2, iw, (ih - nh) // 2 + nh))
        if darken:
            im = Image.blend(im, Image.new("RGB", im.size, tuple(int(d["colours"]["dark"][i:i + 2], 16) for i in (1, 3, 5))), darken)
        p = os.path.join(tmp, f"{len(os.listdir(tmp))}.jpg"); im.save(p, quality=85)
        return p

    prs = Presentation(); prs.slide_width, prs.slide_height = W, H
    BLANK = prs.slide_layouts[6]

    def rect(s, x, y, w, h, fill, shape=MSO_SHAPE.RECTANGLE):
        r = s.shapes.add_shape(shape, x, y, w, h)
        r.fill.solid(); r.fill.fore_color.rgb = fill; r.line.fill.background(); r.shadow.inherit = False
        return r

    def text(s, x, y, w, h, runs, size=18, color=NAVY, bold=False, align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP, spacing=None):
        tb = s.shapes.add_textbox(x, y, w, h)
        tf = tb.text_frame; tf.word_wrap = True; tf.vertical_anchor = anchor
        tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
        for i, para in enumerate(runs if isinstance(runs, list) else [runs]):
            t, o = (para, {}) if isinstance(para, str) else para
            p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
            p.alignment = align
            if o.get("space"): p.space_before = Pt(o["space"])
            r = p.add_run(); r.text = t
            f = r.font; f.name = FONT; f.size = Pt(o.get("size", size)); f.bold = o.get("bold", bold); f.color.rgb = o.get("color", color)
            if spacing: r._r.get_or_add_rPr().set("spc", str(int(spacing * 100)))
        return tb

    def chrome(s, kicker, n):
        rect(s, 0, 0, W, Inches(.12), BLUE)
        rect(s, Inches(.7), Inches(.12), Inches(1.1), Inches(.07), ORANGE)
        text(s, Inches(.7), Inches(.5), Inches(8), Inches(.3), kicker.upper(), size=11, bold=True, color=ORANGE, spacing=2)
        s.shapes.add_picture(img["logo_horizontal_light"], Inches(.7), Inches(6.95), height=Inches(.22))
        text(s, Inches(11.6), Inches(6.93), Inches(1.03), Inches(.3), f"{n:02d}", size=10, color=GREY, align=PP_ALIGN.RIGHT)

    def title(s, t): text(s, Inches(.7), Inches(.85), Inches(11.9), Inches(1), t, size=36, bold=True, color=BLUE)

    def bullets(s, x, y, w, h, items, size=18):
        return text(s, x, y, w, h, [(f"▪  {t}", {"space": 10 if i else 0}) for i, t in enumerate(items)], size=size)

    def new():
        return prs.slides.add_slide(BLANK), len(prs.slides._sldIdLst)

    # 1 Title
    s, n = new()
    s.shapes.add_picture(fit(img["cover"], 13.333, 7.5, darken=.62), 0, 0, W, H)
    rect(s, 0, 0, W, Inches(.12), BLUE)
    s.shapes.add_picture(img["logo_full_dark"], Inches(.9), Inches(1.4), height=Inches(2.6))
    rect(s, Inches(.9), Inches(4.45), Inches(1.1), Inches(.07), ORANGE)
    text(s, Inches(.9), Inches(4.7), Inches(9), Inches(1), "[Presentation Title]", size=44, bold=True, color=WHITE)
    text(s, Inches(.9), Inches(5.6), Inches(9), Inches(.5), "[Subtitle or audience]", size=20, color=EMBER, bold=True)
    text(s, Inches(.9), Inches(6.5), Inches(9), Inches(.4), "[Presenter name]  ·  [Month DD, YYYY]", size=13, color=WHITE)

    # 2 Agenda
    s, n = new(); chrome(s, "Agenda", n); title(s, "What we'll cover")
    for i, t in enumerate(d["agenda"][:5]):
        y = Inches(2.15 + i * 1.08)
        rect(s, Inches(.7), y, Inches(.8), Inches(.8), BLUE if i % 2 == 0 else ORANGE)
        text(s, Inches(.7), y, Inches(.8), Inches(.8), f"{i + 1:02d}", size=22, bold=True, color=WHITE, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
        text(s, Inches(1.8), y, Inches(9), Inches(.8), t, size=24, bold=True, color=NAVY, anchor=MSO_ANCHOR.MIDDLE)

    # 3 Section divider
    s, n = new(); rect(s, 0, 0, W, H, NAVY)
    rect(s, 0, 0, W, Inches(.12), ORANGE)
    s.shapes.add_picture(img["logo_icon_light"], Inches(8.6), Inches(1.3), height=Inches(4.9))
    text(s, Inches(.9), Inches(2.3), Inches(4), Inches(1.4), "01", size=96, bold=True, color=EMBER)
    text(s, Inches(.9), Inches(3.9), Inches(7.5), Inches(1.2), "[Section Title]", size=44, bold=True, color=WHITE)
    text(s, Inches(.9), Inches(5.0), Inches(7.5), Inches(.8), "[One line on what this section covers]", size=18, color=WHITE)

    # 4 Title and bullets
    s, n = new(); chrome(s, "[Section label]", n); title(s, "[Slide title]")
    bullets(s, Inches(.7), Inches(2.1), Inches(11.5), Inches(4.4), ["[Main point. Keep each bullet to one line where you can]",
            "[Second point: name the detail or the result]", "[Third point]", "[Fourth point]"], size=22)

    # 5 Text and photo
    s, n = new(); chrome(s, "[Section label]", n)
    text(s, Inches(.7), Inches(.85), Inches(6), Inches(1), "[Slide title]", size=36, bold=True, color=BLUE)
    text(s, Inches(.7), Inches(2.1), Inches(5.6), Inches(1.4), "[A short paragraph that tells the story of the photo: the job, the scope and what made it work.]", size=18)
    bullets(s, Inches(.7), Inches(3.7), Inches(5.6), Inches(2.8), ["[Detail one]", "[Detail two]", "[Detail three]"], size=18)
    s.shapes.add_picture(fit(img["half"], 5.63, 5.85), Inches(7.0), Inches(.85), Inches(5.63), Inches(5.85))

    # 6 Full photo with caption
    s, n = new()
    s.shapes.add_picture(fit(img["full"], 13.333, 7.5), 0, 0, W, H)
    rect(s, 0, Inches(5.7), W, Inches(1.8), NAVY)
    rect(s, Inches(.7), Inches(5.7), Inches(1.1), Inches(.07), ORANGE)
    text(s, Inches(.7), Inches(5.95), Inches(11), Inches(.7), "[Big statement or project name]", size=30, bold=True, color=WHITE)
    text(s, Inches(.7), Inches(6.65), Inches(11), Inches(.5), "[Caption: location · scope · year]", size=15, color=EMBER)

    # 7 Three key points
    s, n = new(); chrome(s, "[Section label]", n); title(s, d["points_title"])
    for i, (big, head, body) in enumerate(d["points"][:3]):
        x = Inches(.7 + i * 4.05)
        rect(s, x, Inches(2.1), Inches(3.75), Inches(4.3), LIGHT)
        rect(s, x, Inches(2.1), Inches(3.75), Inches(.09), ORANGE if i == 1 else BLUE)
        text(s, x + Inches(.35), Inches(2.6), Inches(3.1), Inches(1), big, size=34, bold=True, color=BLUE)
        text(s, x + Inches(.35), Inches(3.75), Inches(3.1), Inches(.6), head, size=19, bold=True, color=ORANGE)
        text(s, x + Inches(.35), Inches(4.4), Inches(3.1), Inches(1.8), body, size=15)

    # 8 Project spotlight
    s, n = new(); chrome(s, "Project spotlight", n)
    s.shapes.add_picture(fit(img["spot"], 4.7, 5.75), Inches(.7), Inches(.95), Inches(4.7), Inches(5.75))
    text(s, Inches(5.9), Inches(.95), Inches(6.7), Inches(1), "[Project name]", size=34, bold=True, color=BLUE)
    for i, (k, v) in enumerate(d["spotlight"][:5]):
        y = Inches(2.2 + i * .85)
        text(s, Inches(5.9), y, Inches(1.8), Inches(.6), k.upper(), size=12, bold=True, color=ORANGE, spacing=1.5)
        text(s, Inches(7.8), y, Inches(4.8), Inches(.7), v, size=17)
        if i: rect(s, Inches(5.9), y - Inches(.15), Inches(6.73), Inches(.01), col["rule"])

    # 9 Quote
    s, n = new()
    s.shapes.add_picture(fit(img["quote"], 13.333, 7.5, darken=.7), 0, 0, W, H)
    rect(s, 0, 0, W, Inches(.12), ORANGE)
    text(s, Inches(1.2), Inches(1.0), Inches(2), Inches(1.6), "“", size=150, bold=True, color=EMBER)
    text(s, Inches(1.2), Inches(2.6), Inches(10.5), Inches(2.4), "[A short quote from a customer or partner about the work, the team or the schedule.]", size=32, bold=True, color=WHITE)
    text(s, Inches(1.2), Inches(5.4), Inches(10), Inches(.5), "[Name], [Title], [Company]", size=16, color=EMBER, bold=True)

    # 10 Timeline
    s, n = new(); chrome(s, "Schedule", n); title(s, "[Project timeline]")
    rect(s, Inches(.9), Inches(3.35), Inches(11.5), Inches(.06), col["rule"])
    steps = d["timeline"][:4]
    for i, (ph, wk, body) in enumerate(steps):
        x = Inches(.9 + i * 3.05)
        rect(s, x, Inches(3.13), Inches(.5), Inches(.5), ORANGE if i == len(steps) - 1 else BLUE, MSO_SHAPE.OVAL)
        text(s, x, Inches(2.25), Inches(2.8), Inches(.5), wk, size=14, bold=True, color=ORANGE)
        text(s, x, Inches(3.95), Inches(2.8), Inches(.6), ph if ph.startswith("[") else f"[{ph}]", size=21, bold=True, color=BLUE)
        text(s, x, Inches(4.6), Inches(2.7), Inches(1.5), body, size=15)

    # 11 Table
    s, n = new(); chrome(s, "[Section label]", n); title(s, "[Scope and pricing]")
    rows = [("Item", "Description", "Amount")] + [(a, b, "[$0]") for a, b in d["pricing"][:6]] + [("Total", "", "[$0]")]
    tbl = s.shapes.add_table(len(rows), 3, Inches(.7), Inches(2.1), Inches(11.93), Inches(.7 * len(rows))).table
    for j, w in enumerate((3.2, 6.43, 2.3)): tbl.columns[j].width = Inches(w)
    for i, row in enumerate(rows):
        for j, v in enumerate(row):
            cell = tbl.cell(i, j); cell.fill.solid()
            cell.fill.fore_color.rgb = BLUE if i == 0 else (LIGHT if i == len(rows) - 1 else WHITE)
            cell.margin_left = cell.margin_right = Inches(.18); cell.vertical_anchor = MSO_ANCHOR.MIDDLE
            p = cell.text_frame.paragraphs[0]; p.alignment = PP_ALIGN.RIGHT if j == 2 else PP_ALIGN.LEFT
            r = p.add_run(); r.text = v
            r.font.name = FONT; r.font.size = Pt(16 if i else 14)
            r.font.bold = i == 0 or i == len(rows) - 1 or j == 0
            r.font.color.rgb = WHITE if i == 0 else (BLUE if j == 0 or i == len(rows) - 1 else NAVY)

    # 12 Closing
    s, n = new(); rect(s, 0, 0, W, H, NAVY)
    rect(s, 0, 0, W, Inches(.12), BLUE)
    s.shapes.add_picture(img["logo_full_dark"], Inches(.9), Inches(1.5), height=Inches(2.9))
    text(s, Inches(6.6), Inches(1.7), Inches(6), Inches(1), "Thank you", size=48, bold=True, color=WHITE)
    rect(s, Inches(6.6), Inches(2.75), Inches(1.1), Inches(.07), ORANGE)
    text(s, Inches(6.6), Inches(3.05), Inches(6), Inches(3), [("[Presenter name] · [Title]", {"bold": True, "color": EMBER, "size": 18})] +
         [(c, {"space": 14 if i == 0 else 6}) for i, c in enumerate(d["contact"])], size=17, color=WHITE)

    prs.save(out)
    print(f"wrote {out} ({len(prs.slides._sldIdLst)} slides)")

def tracker(d, out):
    from openpyxl import Workbook
    from openpyxl.styles import Font, PatternFill
    from openpyxl.utils import get_column_letter
    wb = Workbook(); wb.remove(wb.active)
    head_font = Font(name=d["font"], bold=True, color="FFFFFF"); fill = PatternFill("solid", fgColor=d["header_fill"])
    for sh in d["sheets"]:
        ws = wb.create_sheet(sh["title"])
        ws.append(sh["head"])
        for c in ws[1]: c.font = head_font; c.fill = fill
        for r in sh["rows"]: ws.append(r)
        for row in ws.iter_rows(min_row=2):
            for c in row: c.font = Font(name=d["font"], size=10)
        for i, w in enumerate(sh["widths"]): ws.column_dimensions[get_column_letter(i + 1)].width = w
        ws.freeze_panes = "A2"
    wb.save(out)
    print(f"wrote {out} ({len(d['sheets'])} sheets)")

if __name__ == "__main__":
    kind, payload, out = sys.argv[1:4]
    {"slides": slides, "tracker": tracker}[kind](json.load(open(payload)), out)
