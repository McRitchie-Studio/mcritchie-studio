#!/usr/bin/env python3
# Draws a marketing kit's Office files from a JSON payload that lib/marketing_kit/office.rb writes:
#   office.py slides  payload.json  out.pptx   the 12-slide template (16:9), for Drive to convert to Google Slides
#   office.py tracker payload.json  out.xlsx   the tracker workbook, for Drive to convert to a Google Sheet
#   office.py sheet   payload.json  out.xlsx   the Sheet template (lib/marketing_kit/sheet_template.rb), for Drive to convert
#   office.py proposal payload.json out.docx   the Proposal template (lib/marketing_kit/proposal_template.rb), for Drive to convert to a Google Doc
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
    TITLE = col.get("title", BLUE)  # slide titles; the payload falls back to primary when a brand sets none
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

    def title(s, t): text(s, Inches(.7), Inches(.85), Inches(11.9), Inches(1), t, size=36, bold=True, color=TITLE)

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
    text(s, Inches(.7), Inches(.85), Inches(6), Inches(1), "[Slide title]", size=36, bold=True, color=TITLE)
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
    text(s, Inches(5.9), Inches(.95), Inches(6.7), Inches(1), "[Project name]", size=34, bold=True, color=TITLE)
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

def sheet(d, out):
    """The Sheet template. Never merges a cell; freezes under the lower head and right of the item column.

    Row 1 and column A are margins. A2 is a square holding the brand icon; the title
    sits alone in B2 and Last Updated in B3. Variables are label (row 4) over value
    (row 5): the headline in column B, the rest from D past a narrow gutter in C. The
    table's head is rows 7-8 from column B, the data starts in row 9, and the freeze
    sits at C9: margins, the item column, the headline and the head stay in view.
    """
    import datetime, re
    from openpyxl import Workbook
    from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
    from openpyxl.drawing.image import Image as XImage
    from openpyxl.drawing.spreadsheet_drawing import OneCellAnchor, AnchorMarker
    from openpyxl.drawing.xdr import XDRPositiveSize2D
    from openpyxl.utils import get_column_letter as L
    from openpyxl.utils.units import pixels_to_EMU
    from openpyxl.worksheet.datavalidation import DataValidation
    from openpyxl.formatting.rule import FormulaRule

    def draw_tab(ws, d):
        """One table tab: margins, icon, title, Last Updated, variables, the three-section head, the rows."""
        col = {k: v.lstrip("#") for k, v in d["colours"].items()}
        font = lambda **k: Font(name=d["font"], **k)
        fill = lambda h: PatternFill("solid", fgColor=h.lstrip("#"))
        FORMATS = {"date": "mmm d, yyyy", "money": '"$"#,##0.00', "percent": "0.0%"}
        RIGHT = {"money", "percent", "formula", "date"}

        MARGIN, TITLE, UPDATED, VAR_LABEL, VAR_VALUE, GAP, HEAD_TOP, HEAD_LOW = range(1, 9)
        FIRST = HEAD_LOW + 1
        LAST = FIRST + 990  # the open range totals and dropdowns cover, so added rows count
        X = 2  # the table's first column (B); A is the margin
        cols, n = d["columns"], len(d["columns"])
        # A narrow gutter (C) parts the frozen item column from the rest, so the
        # columns that scroll never butt against it. Table column i sits at C(i).
        GUTTER = X + 1
        C = lambda i: X + i + (1 if i > 0 else 0)

        # A2 is square: column A is as wide as row 2 is tall. Row heights are points
        # (4/3 px); a column width in characters draws at about 7 px each plus 5.
        square = 34
        ws.title = d["sheet_title"]
        ws.sheet_view.showGridLines = False
        ws.column_dimensions["A"].width = round((square - 5) / 7, 2)
        for i, c in enumerate(cols): ws.column_dimensions[L(C(i))].width = c["width"]
        ws.column_dimensions[L(GUTTER)].width = 2.57
        # A variable marked emphasis (the sheet's headline number) draws larger, so row 3 grows to hold it.
        emphasis = any(v.get("emphasis") for v in d["variables"])
        heights = {MARGIN: 15, TITLE: square * 3 / 4, UPDATED: 12, VAR_LABEL: 12, VAR_VALUE: 26 if emphasis else 20, GAP: 12,
                   HEAD_TOP: 24, HEAD_LOW: 22}
        for r, h in heights.items(): ws.row_dimensions[r].height = h

        # The icon fits inside A2, a few pixels in from each edge, at its own
        # proportions (a tall or wide mark is never squashed), centred both ways.
        from PIL import Image
        box = square - 8
        iw, ih = Image.open(d["icon"]).size
        scale = box / max(iw, ih)
        w, h = round(iw * scale), round(ih * scale)
        icon = XImage(d["icon"]); icon.width, icon.height = w, h
        icon.anchor = OneCellAnchor(_from=AnchorMarker(col=0, colOff=pixels_to_EMU((square - w) // 2), row=TITLE - 1,
                                                       rowOff=pixels_to_EMU((square - h) // 2)),
                                    ext=XDRPositiveSize2D(pixels_to_EMU(w), pixels_to_EMU(h)))
        ws.add_image(icon)

        # Row 2 is the title alone, so a long one runs on across the row. Under it in B3,
        # the date an agent last rebuilt the sheet.
        t = ws.cell(TITLE, X, d["title"]); t.font = font(size=16, bold=True, color=col["title"])
        t.alignment = Alignment(vertical=d.get("title_align", "center"))  # centre: level with the icon's middle
        u = ws.cell(UPDATED, X, f"Last Updated: {d['updated']}"); u.font = font(size=6, color=col["grey"])  # small, so it never crowds the headline
        u.alignment = Alignment(vertical="top")

        def fmt(item):  # an item's own format wins over its kind's
            return item.get("format") or FORMATS.get(item["kind"])

        # Variables: label (row 4) over value (row 5). The headline (emphasis) sits in
        # column B, under the title, where the freeze keeps it in view; the rest run
        # on from D, past the gutter.
        var_cell = {}
        rest = 0
        for v in d["variables"]:
            if v.get("emphasis"):
                at = X
            else:
                at = C(1 + rest); rest += 1
            lab = ws.cell(VAR_LABEL, at, v["label"].upper())
            lab.font = font(size=8, bold=True, color=col["headline"] if v.get("emphasis") else col["grey"])
            lab.alignment = Alignment(vertical="bottom")
            value = v["value"]
            if isinstance(value, str):
                value = value.replace("{first}", str(FIRST)).replace("{last}", str(LAST))
                value = re.sub(r"\{col:(\w+)\}", lambda m: L(C(next(j for j, c in enumerate(cols) if c["key"] == m.group(1)))), value)
            cell = ws.cell(VAR_VALUE, at, value)
            big = v.get("emphasis")
            cell.font = font(size=16 if big else 11, bold=True, color=col["headline"] if big else col["ink"]); cell.fill = fill(col["light"])
            cell.alignment = Alignment(horizontal="left", vertical="center")
            if fmt(v): cell.number_format = fmt(v)
            var_cell[v["label"]] = f"${L(at)}${VAR_VALUE}"

        # The table head: three sections, darker on top, white text on both rows.
        # A section's label sits in its first cell; the rest share the fill, unmerged.
        edge = Side(style="medium", color=col["white"])
        for i, c in enumerate(cols):
            sec = d["sections"][c["section"]]
            first = i == 0 or cols[i - 1]["section"] != c["section"]
            top = ws.cell(HEAD_TOP, C(i), sec["label"] if first else None)
            top.fill = fill(sec["top"]); top.font = font(size=10, bold=True, color=col["white"])
            top.alignment = Alignment(vertical="center", indent=1)
            low = ws.cell(HEAD_LOW, C(i), c["head"])
            low.fill = fill(sec["low"]); low.font = font(size=9, bold=True, color=col["white"])
            low.alignment = Alignment(vertical="center", horizontal="right" if c["kind"] in RIGHT else "left", indent=1)
            if first and i:
                top.border = Border(left=edge); low.border = Border(left=edge)
        item_sec = d["sections"][cols[0]["section"]]  # the gutter wears the item column's section
        ws.cell(HEAD_TOP, GUTTER).fill = fill(item_sec["top"]); ws.cell(HEAD_LOW, GUTTER).fill = fill(item_sec["low"])

        # Example rows. In a formula, {r} is the row, {col:key} a table column's letter
        # and {var:Label} that variable's cell, made absolute.
        rule = Side(style="thin", color=col["rule"])
        letter = {c["key"]: L(C(i)) for i, c in enumerate(cols)}
        for r, row in enumerate(d["rows"], start=FIRST):
            ws.row_dimensions[r].height = 20
            ws.cell(r, GUTTER).border = Border(bottom=rule)
            for i, v in enumerate(row):
                c = cols[i]
                # A date column may hold a marker instead (a roster's 💳 for "in use now"): only ISO dates convert.
                if c["kind"] == "date" and isinstance(v, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", v): v = datetime.date.fromisoformat(v)
                if c["kind"] == "formula":
                    v = re.sub(r"\{var:([^}]+)\}", lambda m: var_cell[m.group(1)], c["formula"])
                    v = re.sub(r"\{col:(\w+)\}", lambda m: letter[m.group(1)], v).replace("{r}", str(r))
                cell = ws.cell(r, C(i), v if v != "" else None)
                cell.font = font(size=10, color=col["ink"], bold=c["kind"] == "item")
                cell.border = Border(bottom=rule)
                cell.alignment = Alignment(vertical="center", horizontal="center" if c["kind"] == "stamp"
                                       else "right" if c["kind"] in RIGHT else "left", indent=0 if c["kind"] == "stamp" else 1)
                if c["kind"] == "formula": cell.number_format = c.get("format") or FORMATS["money"]
                elif fmt(c): cell.number_format = fmt(c)

        # A dropdown on every column that has choices; a status column without its own uses the sheet's statuses.
        for i, c in enumerate(cols):
            choices = c.get("choices") or (d["statuses"] if c["kind"] == "status" else [d["archived"]] if c["kind"] == "archive" else None)
            if not choices: continue
            dv = DataValidation(type="list", formula1='"' + ",".join(choices) + '"', allow_blank=True)
            ws.add_data_validation(dv); dv.add(f"{L(C(i))}{FIRST}:{L(C(i))}{LAST}")
        # Conditional formats. Google ranks a row-wide rule above a cell rule on an overlapping range,
        # so a column with its own rules (age_bands) is cut out of the row ranges, never overlapped.
        solid = lambda h: PatternFill("solid", fgColor=h, bgColor=h)
        whole = f"{L(X)}{FIRST}:{L(C(n - 1))}{LAST}"
        aged = [i for i, c in enumerate(cols) if c.get("age_bands")]
        if aged:
            a = C(aged[0])
            row_ranges = " ".join(r for r in (f"{L(X)}{FIRST}:{L(a - 1)}{LAST}" if a > X else "",
                                               f"{L(a + 1)}{FIRST}:{L(C(n - 1))}{LAST}" if a < C(n - 1) else "") if r)
        else:
            row_ranges = whole
        # An archived row greys out across the table; the totals skip it (SUMIFS on the archive column).
        archive = [i for i, c in enumerate(cols) if c["kind"] == "archive"]
        grey = dict(font=Font(color=col["grey"], italic=True), fill=solid(col["light"]), stopIfTrue=True)
        if archive:
            mark = f'${L(C(archive[0]))}{FIRST}="{d["archived"]}"'
            for rng in ([row_ranges, f"{L(C(aged[0]))}{FIRST}:{L(C(aged[0]))}{LAST}"] if aged else [whole]):
                ws.conditional_formatting.add(rng, FormulaRule(formula=[mark], **grey))
        # age_bands: a date column's age colours the row and, louder, the cell itself.
        # {"months": [fresh, neutral, warn], "fresh": ["💳"]}: within months[0] (or a fresh marker) is
        # good, within months[1] neutral, within months[2] warn, older bad.
        if aged:
            bands = cols[aged[0]]["age_bands"]
            m0, m1, m2 = bands["months"]
            v = f"${L(C(aged[0]))}{FIRST}"
            fresh = "".join(f'{v}="{x}",' for x in bands.get("fresh", []))
            dated = lambda op, m: f"AND(ISNUMBER({v}),{v}{op}EDATE(TODAY(),-{m}))"
            good = f"OR({fresh}{dated('>=', m0)})"
            for formula, colour in ((good, "D9EAD3"), (dated(">=", m1), "FFFFFF"), (dated(">=", m2), "FFF2CC"), (dated("<", m2), "F4CCCC")):
                ws.conditional_formatting.add(row_ranges, FormulaRule(formula=[formula], fill=solid(colour), stopIfTrue=True))
            cell = f"{L(C(aged[0]))}{FIRST}:{L(C(aged[0]))}{LAST}"
            for formula, f, fnt in ((dated("<", m2), solid("CC0000"), Font(color="FFFFFF", bold=True)),
                                    (dated("<", m1), solid("F1C232"), Font(bold=True)),
                                    (good, solid("D9EAD3"), None)):
                ws.conditional_formatting.add(cell, FormulaRule(formula=[formula], fill=f, font=fnt, stopIfTrue=True))
        ws.auto_filter.ref = f"{L(X)}{HEAD_LOW}:{L(C(n - 1))}{FIRST + len(d['rows']) - 1}"
        ws.freeze_panes = f"{L(X + 1)}{FIRST}"
        ws.page_setup.orientation = "landscape"
        ws.sheet_properties.pageSetUpPr.fitToPage = True
        ws.page_setup.fitToWidth, ws.page_setup.fitToHeight = 1, 0

        return ws, n

    col = {k: v.lstrip("#") for k, v in d["colours"].items()}
    font = lambda **k: Font(name=d["font"], **k)

    # A payload may carry tabs: several table tabs drawn the same way (an Overview
    # and a Cards roster, say), each with its own title, variables, head and rows
    # over the shared brand. Without tabs it is the one table tab.
    wb = Workbook()
    drawn = []
    for i, tab in enumerate(d.get("tabs") or [{}]):
        drawn.append(draw_tab(wb.active if i == 0 else wb.create_sheet(), {**d, **tab}))
    ws, n = drawn[0]

    notes = wb.create_sheet(d["notes_title"])
    notes.sheet_view.showGridLines = False
    notes.column_dimensions["A"].width = 110
    for r, line in enumerate(d["notes"], start=1):
        c = notes.cell(r, 1, line)
        c.font = font(size=14 if r == 1 else 10, bold=r == 1, color=col["ink"])
        c.alignment = Alignment(wrap_text=True, vertical="top")
    wb.save(out)
    print(f"wrote {out} ({len(drawn)} table tab(s), freeze {ws.freeze_panes}, {n} columns)")

def proposal(d, out):
    """The Proposal template (lib/marketing_kit/proposal_template.rb), as a Word file Drive converts to a Google Doc.

    Letter pages with one section each: cover, about us, details, investment, clients, why choose us, terms, and the
    signature page. The cover, about us and why choose us open on a photo shaded in the dark colour and floated behind
    the text, with the section's label, title and one line over it (`focus` places each crop). The dark tone (payload
    `page`) colours every page. Quiet by design: white space, hairline rules, the primary colour for titles and the accent only for
    small marks (section labels, a short rule, fields). Every page after the cover carries the horizontal logo and the
    proposal number in its header, and the motto and page number in its footer. Nothing is positioned absolutely, so
    the Doc stays editable.
    """
    import re
    from PIL import Image
    from docx import Document
    from docx.enum.section import WD_SECTION
    from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT
    from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn
    from docx.shared import Inches, Pt, RGBColor

    col, img, FONT, H = d["colours"], d["images"], d["font"], d["headings"]
    HAIR = d.get("hair", "#D9DEE5")
    rgb = lambda h: RGBColor.from_string(h.lstrip("#"))
    tmp = tempfile.mkdtemp(prefix="kit-proposal-")
    PAGE_W, MARGIN = 8.5, 1.0
    BODY_W = PAGE_W - 2 * MARGIN

    def crop(path, w_in, h_in, focus=0.5):
        """Crops to the slot's shape. focus is where the kept band sits, 0 the top (or left) and 1 the bottom."""
        im = Image.open(path).convert("RGB"); want = w_in / h_in; iw, ih = im.size
        if iw / ih > want:
            nw = max(1, int(ih * want)); x = int((iw - nw) * focus); im = im.crop((x, 0, x + nw, ih))
        else:
            nh = max(1, int(iw / want)); y = int((ih - nh) * focus); im = im.crop((0, y, iw, y + nh))
        p = os.path.join(tmp, f"{len(os.listdir(tmp))}.jpg"); im.save(p, quality=88)
        return p

    def mark(w_px=180, h_px=10, colour=None):
        """A short solid rule, drawn as an image so Docs keeps its length."""
        im = Image.new("RGB", (w_px, h_px), tuple(int((colour or col["accent"])[i:i + 2], 16) for i in (1, 3, 5)))
        p = os.path.join(tmp, f"mark{w_px}.png"); im.save(p); return p

    def spacing(pt):
        e = OxmlElement("w:spacing"); e.set(qn("w:val"), str(int(pt * 20))); return e

    def run(p, t, size=10, bold=False, colour=None, track=None, italic=False):
        r = p.add_run(t); r.font.name = FONT; r.font.size = Pt(size); r.bold = bold; r.italic = italic
        r.font.color.rgb = rgb(colour or col["ink"])
        if track: r.font._element.get_or_add_rPr().append(spacing(track))
        return r

    def fields(p, t, size=10, colour=None, whole=False, bold=False):
        """Text whose [bracketed] parts are fields, in the accent colour. whole=True: no brackets means one field."""
        parts = re.split(r"(\[[^\]]*\])", t) if "[" in t or not whole else [f"[{t}]"]
        for part in parts:
            if part: run(p, part, size, bold=bold, colour=col["accent"] if part.startswith("[") else colour)
        return p

    def para(container, t="", size=10, colour=None, bold=False, align=None, before=0, after=6, track=None, line=1.25):
        p = container.add_paragraph(); f = p.paragraph_format
        f.space_before, f.space_after, f.line_spacing = Pt(before), Pt(after), line
        if align: p.alignment = {"center": WD_ALIGN_PARAGRAPH.CENTER, "right": WD_ALIGN_PARAGRAPH.RIGHT}[align]
        if t: run(p, t, size, bold, colour, track)
        return p

    def border(el_pr, edges, colour=HAIR, size=4, tag="w:pBdr"):
        b = OxmlElement(tag)
        for edge in edges:
            e = OxmlElement(f"w:{edge}"); e.set(qn("w:val"), "single"); e.set(qn("w:sz"), str(size))
            e.set(qn("w:space"), "4"); e.set(qn("w:color"), colour.lstrip("#")); b.append(e)
        el_pr.append(b)

    def table(rows, cols, inches, rules=True):
        t = doc.add_table(rows=rows, cols=cols); t.autofit = False
        pr = t._tbl.tblPr
        b = OxmlElement("w:tblBorders")
        for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
            e = OxmlElement(f"w:{edge}")
            on = rules and edge in ("insideH", "bottom", "top")
            e.set(qn("w:val"), "single" if on else "nil")
            if on: e.set(qn("w:sz"), "4"); e.set(qn("w:color"), HAIR.lstrip("#"))
            b.append(e)
        pr.append(b)
        tw = OxmlElement("w:tblW"); tw.set(qn("w:w"), str(int(sum(inches) * 1440))); tw.set(qn("w:type"), "dxa"); pr.append(tw)
        lay = OxmlElement("w:tblLayout"); lay.set(qn("w:type"), "fixed"); pr.append(lay)
        for gc, w in zip(t._tbl.tblGrid.findall(qn("w:gridCol")), inches): gc.set(qn("w:w"), str(int(w * 1440)))
        for row in t.rows:
            for c, w in zip(row.cells, inches): c.width = Inches(w)
        return t

    def cell_pad(cell, tb=0.08, lr=0.0):
        tc = cell._tc.get_or_add_tcPr(); m = OxmlElement("w:tcMar")
        for edge, v in (("top", tb), ("bottom", tb), ("left", lr), ("right", lr)):
            e = OxmlElement(f"w:{edge}"); e.set(qn("w:w"), str(int(v * 1440))); e.set(qn("w:type"), "dxa"); m.append(e)
        tc.append(m)

    def cell_rule(cell, edge, colour, size):
        tc = cell._tc.get_or_add_tcPr(); b = OxmlElement("w:tcBorders"); e = OxmlElement(f"w:{edge}")
        e.set(qn("w:val"), "single"); e.set(qn("w:sz"), str(size)); e.set(qn("w:color"), colour.lstrip("#")); b.append(e); tc.append(b)

    def first(cell):
        p = cell.paragraphs[0]; p.paragraph_format.space_after = Pt(0); return p

    def page_field(p):
        r = p.add_run(); r.font.name = FONT; r.font.size = Pt(8); r.font.color.rgb = rgb(col["grey"])
        for kind, text in (("begin", None), (None, "PAGE"), ("end", None)):
            if kind:
                e = OxmlElement("w:fldChar"); e.set(qn("w:fldCharType"), kind); r._r.append(e)
            else:
                e = OxmlElement("w:instrText"); e.set(qn("xml:space"), "preserve"); e.text = text; r._r.append(e)

    def opener(n, key):
        """A section opens with a small numbered label in the accent, a large title in the primary and a short rule."""
        label, title = H[key][:2]
        para(doc, f"{n:02d}   {label.upper()}", size=8.5, bold=True, colour=col["accent"], track=2.5, after=4)
        para(doc, title, size=26, colour=col["primary"], after=6, line=1.05)
        p = para(doc, after=18); p.add_run().add_picture(mark(), width=Inches(0.6))

    def page_break():
        p = doc.add_paragraph(); p.paragraph_format.space_after = Pt(0); p.add_run().add_break(WD_BREAK.PAGE)

    doc = Document()
    if d.get("page"):
        bg = OxmlElement("w:background"); bg.set(qn("w:color"), d["page"].lstrip("#")); doc.element.insert(0, bg)
        doc.settings.element.append(OxmlElement("w:displayBackgroundShape"))
    normal = doc.styles["Normal"]
    normal.font.name, normal.font.size, normal.font.color.rgb = FONT, Pt(10), rgb(col["ink"])
    for name in ("List Bullet", "List Number"): doc.styles[name].font.color.rgb = rgb(col["ink"])
    normal.element.rPr.rFonts.set(qn("w:eastAsia"), FONT)
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Inches(PAGE_W), Inches(11)
    sec.left_margin = sec.right_margin = Inches(MARGIN)
    sec.top_margin, sec.bottom_margin = Inches(1.0), Inches(0.9)
    sec.header_distance, sec.footer_distance = Inches(0.45), Inches(0.4)
    sec.different_first_page_header_footer = True

    # Running header: the logo left, the proposal number right, a hairline under. Footer: motto and page number.
    ht = sec.header.add_table(rows=1, cols=2, width=Inches(BODY_W))
    hl, hr = ht.rows[0].cells
    first(hl).add_run().add_picture(img["logo"], height=Inches(0.26))
    p = first(hr); p.alignment = WD_ALIGN_PARAGRAPH.RIGHT; hr.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
    fields(p, f"PROPOSAL  [{d['cover']['number']}]", size=7.5, colour=col["grey"])
    for c in (hl, hr): cell_pad(c, 0.04); cell_rule(c, "bottom", HAIR, 4)
    sec.header.paragraphs[0].paragraph_format.space_after = Pt(0)
    fp = sec.footer.paragraphs[0]; fp.alignment = WD_ALIGN_PARAGRAPH.CENTER
    if d.get("motto"): run(fp, d["motto"] + "      ", size=7, colour=col["grey"], track=2)
    page_field(fp)

    def shaded(path, w_in, h_in, focus=0.5):
        """A photo under the dark colour, deepest at the top where the words sit, easing toward the bottom."""
        base = Image.open(crop(path, w_in, h_in, focus)).convert("RGB")
        navy = tuple(int(d["colours"].get("dark", "#0B1824")[i:i + 2], 16) for i in (1, 3, 5))
        mask = Image.new("L", base.size); w, h = base.size
        for y in range(h):
            mask.paste(int(255 * (0.88 - 0.5 * (y / h) ** 0.9)), (0, y, w, y + 1))  # 88% at the top, 38% at the foot
        out_p = os.path.join(tmp, f"shaded{len(os.listdir(tmp))}.jpg")
        Image.composite(Image.new("RGB", base.size, navy), base, mask).save(out_p, quality=90)
        return out_p

    def hero(path, h_in, words, focus=0.5):
        """A shaded photo floated behind the text, with `words` (a function that writes paragraphs) over its upper
        part, inset from its left edge. Returns once the page has moved past the photo's foot."""
        anchor_p = para(doc, after=0)
        anchor_p.add_run().add_picture(shaded(path, BODY_W, h_in, focus), width=Inches(BODY_W))
        inline = anchor_p._p.xpath(".//wp:inline")[0]
        anchor = OxmlElement("wp:anchor")
        for k, v in (("distT", "0"), ("distB", "0"), ("distL", "0"), ("distR", "0"), ("simplePos", "0"), ("relativeHeight", "0"),
                     ("behindDoc", "1"), ("locked", "0"), ("layoutInCell", "1"), ("allowOverlap", "1")):
            anchor.set(k, v)
        sp = OxmlElement("wp:simplePos"); sp.set("x", "0"); sp.set("y", "0"); anchor.append(sp)
        for axis, rel in (("H", "column"), ("V", "paragraph")):
            pos = OxmlElement(f"wp:position{axis}"); pos.set("relativeFrom", rel)
            off = OxmlElement("wp:posOffset"); off.text = "0"; pos.append(off); anchor.append(pos)
        for child in list(inline):
            if child.tag == qn("wp:docPr"): anchor.append(OxmlElement("wp:wrapNone"))
            anchor.append(child)
        inline.getparent().replace(inline, anchor)
        used = words(lambda p: (setattr(p.paragraph_format, "left_indent", Inches(0.4)),
                                setattr(p.paragraph_format, "right_indent", Inches(0.6)), p)[2])
        para(doc, size=10, after=max(12, h_in * 72 - used))

    def section_hero(n, key, path, h_in, focus=0.5):
        """A section that opens on a photo: its numbered label, title and one line on what the section is for."""
        label, title, blurb = (H[key] + [None])[:3]
        def words(over):
            over(para(doc, f"{n:02d}   {label.upper()}", size=8.5, bold=True, colour=col["accent"], track=2.5, before=40, after=4))
            over(para(doc, title, size=26, colour="#FFFFFF", after=6, line=1.05))
            if blurb: over(para(doc, blurb, size=11, colour="#DCE3EA", after=0, line=1.35))
            return 40 + 16 + 36 + (18 if blurb else 0) + 20  # the words' height (one line of blurb), in points, and slack
        hero(path, h_in, words, focus)

    # ---- Cover
    p = para(doc, after=0); p.add_run().add_picture(img["logo"], height=Inches(0.42))
    para(doc, after=24)
    def cover_words(over):
        over(para(doc, "PROPOSAL", size=9, bold=True, colour=col["accent"], track=4, before=46, after=6))
        over(fields(para(doc, after=4, line=1.0), "[Project name]", size=32, colour="#FFFFFF"))
        over(fields(para(doc, after=0), "Prepared for [Company]", size=13, colour="#DCE3EA"))
        return 96
    hero(img["cover"], 4.7, cover_words, d.get("focus", {}).get("cover", 0.5))
    cv = d["cover"]
    para(doc, after=10)
    meta = table(2, 4, [BODY_W / 4] * 4)
    labels = ("PREPARED FOR", "PROPOSAL NO.", "DATE", "PREPARED BY")
    values = ("[Contact name], [Company]", f"[{cv['number']}]", "[Month D, YYYY]", "[Your name]")
    for i, (lab, val) in enumerate(zip(labels, values)):
        top, bottom = meta.rows[0].cells[i], meta.rows[1].cells[i]
        cell_pad(top, 0.1, 0.0); cell_pad(bottom, 0.02, 0.0)
        run(first(top), lab, size=7, bold=True, colour=col["grey"], track=1.5)
        fields(first(bottom), val, size=9.5)

    # ---- 01 About us
    page_break(); section_hero(1, "about", img["about"], 3.4, d.get("focus", {}).get("about", 0.5))
    # The credentials (and any ownership certification, confirmed per proposal) lead the about page.
    badges = cv.get("badges") or []
    if badges:
        # Each credential: its body's logo (one tone, when the spec gives one), then a green tick, the credential and who
        # holds it. Without a logo the tick leads.
        def tick():
            """A hollow tick: a green ring and a green check, transparent inside so the logo shows through."""
            from PIL import ImageDraw
            n = 320; im = Image.new("RGBA", (n, n), (0, 0, 0, 0)); dr = ImageDraw.Draw(im)
            green = (46, 168, 96, 255)
            dr.ellipse((14, 14, n - 14, n - 14), outline=green, width=38)
            dr.line([(88, 168), (140, 220), (236, 112)], fill=green, width=42, joint="curve")
            for x, y in ((88, 168), (140, 220), (236, 112)): dr.ellipse((x - 21, y - 21, x + 21, y + 21), fill=green)
            small = im.resize((160, 160), Image.LANCZOS)
            out_p = os.path.join(tmp, "tick.png"); small.save(out_p); return out_p
        tick_p = tick()

        def ticked(path):
            """The logo with the green tick over its bottom-right corner, on a canvas just big enough for both."""
            logo = Image.open(path).convert("RGBA")
            t = Image.open(tick_p).convert("RGBA"); side = int(min(logo.size) * 0.72)
            t = t.resize((side, side), Image.LANCZOS)
            canvas = Image.new("RGBA", (logo.width + side // 3, logo.height + side // 3), (0, 0, 0, 0))
            canvas.alpha_composite(logo, (0, 0))
            canvas.alpha_composite(t, (canvas.width - side, canvas.height - side))
            out_p = os.path.join(tmp, f"ticked{len(os.listdir(tmp))}.png"); canvas.save(out_p); return out_p
        para(doc, size=4, after=8)
        per = BODY_W / len(badges)
        def wide(b): return b.get("logo") and Image.open(b["logo"]).width / Image.open(b["logo"]).height >= 1.6
        logo_ws = [(1.3 if wide(b) else 0.7) if b.get("logo") else 0.05 for b in badges]
        t = table(1, len(badges) * 2, [w for lw in logo_ws for w in (lw, per - lw)], rules=False)
        cells = t.rows[0].cells
        for i, b in enumerate(badges):
            lc, wc = cells[2 * i], cells[2 * i + 1]
            lc.vertical_alignment = wc.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
            cell_pad(lc, 0.0); cell_pad(wc, 0.0, 0.08)
            p = first(wc)
            if b.get("logo"):
                first(lc).add_run().add_picture(ticked(b["logo"]), **({"width": Inches(1.25)} if wide(b) else {"height": Inches(0.6)}))
            else:
                p.add_run().add_picture(tick_p, height=Inches(0.18)); run(p, "  ")
            run(p, b["title"].upper(), size=9.5, bold=True, colour=col["primary"], track=1.5)
            para(wc, b["holder"], size=8.5, colour=col["grey"], after=0)
    elif cv.get("credentials"):
        para(doc, cv["credentials"], size=8.5, bold=True, colour=col["primary"], track=2, before=14, after=2)
    if cv.get("certifications"): fields(para(doc, before=12 if badges else 0, after=0), f"[{cv['certifications']}]", size=7.5)
    para(doc, size=6, after=10)
    para(doc, d["about"]["text"], size=11, colour=col["ink"], after=22, line=1.45)
    cols = d["about"]["columns"]
    if cols:
        t = table(1, 3, [(BODY_W - 0.4) / 2, 0.4, (BODY_W - 0.4) / 2], rules=False)
        for cell, c in zip((t.rows[0].cells[0], t.rows[0].cells[2]), cols):
            run(first(cell), c["title"].upper(), size=8, bold=True, colour=col["primary"], track=2)
            para(cell, c["text"], size=9.5, before=6, line=1.4)

    # ---- 02 Details: every row but the price, which has its own page
    page_break(); opener(2, "details")
    t = table(0, 2, [1.7, BODY_W - 1.7])
    for row in d["details"]:
        cells = t.add_row().cells
        cells[0].width, cells[1].width = Inches(1.7), Inches(BODY_W - 1.7)
        cell_pad(cells[0], 0.12); cell_pad(cells[1], 0.12)
        run(first(cells[0]), row["label"].upper(), size=7.5, bold=True, colour=col["grey"], track=1.5)
        vc = cells[1]
        for i, line in enumerate(row["lines"]):
            p = first(vc) if i == 0 else vc.add_paragraph()
            p.paragraph_format.space_after = Pt(3); p.paragraph_format.line_spacing = 1.3
            if row["bullets"]: p.style = doc.styles["List Bullet"]
            fields(p, line, size=10, whole=not row["bullets"])
        if row.get("pricing"): para(vc, "Priced on the next page.", size=8.5, colour=col["grey"], before=2, after=0)

    # ---- 03 Investment
    priced = next(r for r in d["details"] if r.get("pricing"))["pricing"]
    page_break(); opener(3, "investment")
    widths = [BODY_W - 1.5, 1.5]
    t = table(0, 2, widths)
    def money_row(label, size=10, bold=False, indent=0.0, colour=None, amount_colour=None, last=False):
        cells = t.add_row().cells
        for c, w in zip(cells, widths): c.width = Inches(w)
        cell_pad(cells[0], 0.07); cell_pad(cells[1], 0.07)
        p = first(cells[0]); p.paragraph_format.left_indent = Inches(indent); run(p, label, size, bold, colour)
        p = first(cells[1]); p.alignment = WD_ALIGN_PARAGRAPH.RIGHT
        fields(p, "[$0]", size=size, bold=bold)
        return cells
    for b in priced["breakdown"]:
        money_row(b["category"], size=10.5, bold=True, colour=col["primary"])
        for item in b["items"]: money_row(item, size=9.5, indent=0.25, colour=col["grey"])
    cells = money_row("Total", size=13, bold=True, colour=col["primary"])
    for c in cells: cell_rule(c, "top", col["primary"], 12)
    para(doc, priced["total_label"].rstrip(":") + ".", size=8.5, colour=col["grey"], before=6)

    # ---- 04 Clients
    cl = d["clients"]
    n = 4
    if img.get("clients") or cl["names"]:
        page_break(); opener(n, "clients"); n += 1
        if img.get("clients"):
            p = para(doc, align="center", after=10); p.add_run().add_picture(img["clients"], width=Inches(BODY_W * 0.92))
        else:
            per = 3; names = cl["names"]
            t = table(0, per, [BODY_W / per] * per)
            for i in range(0, len(names), per):
                cells = t.add_row().cells
                for c, nm in zip(cells, names[i:i + per]):
                    cell_pad(c, 0.12); p = first(c); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
                    run(p, nm, size=10, colour=col["primary"])
        if cl.get("note"): fields(para(doc, before=8), f"[{cl['note']}]", size=7.5)

    # ---- Why choose us
    why = d["why"]
    if why["columns"]:
        page_break(); section_hero(n, "why", img["why"], 3.6, d.get("focus", {}).get("why", 0.5)); n += 1
        for i, c in enumerate(why["columns"], start=1):
            t = table(1, 2, [0.6, BODY_W - 0.6], rules=False)
            num, body = t.rows[0].cells
            run(first(num), f"{i:02d}", size=18, colour=col["accent"])
            run(first(body), c["title"].upper(), size=8.5, bold=True, colour=col["primary"], track=2)
            para(body, c["text"], size=10, before=5, after=14, line=1.4)
        if why.get("contact"):
            p = para(doc, why["contact"], size=9.5, colour=col["primary"], align="center", before=10, track=1)
            border(p._p.get_or_add_pPr(), ["top"])

    # ---- Terms of service
    terms = d.get("terms")
    if terms:
        page_break(); opener(n, "terms"); n += 1
        for t_ in terms["intro"]: para(doc, t_, size=8, colour=col["grey"], after=4, line=1.2)
        for k, v in terms["items"]:
            p = doc.add_paragraph(style="List Number"); f = p.paragraph_format
            f.space_after, f.line_spacing = Pt(2), 1.15
            run(p, f"{k}. ", size=8, bold=True, colour=col["ink"]); run(p, v, size=8, colour=col["ink"])

    # ---- Acceptance
    acc = d["acceptance"]
    page_break(); opener(n, "acceptance")
    fields(para(doc, after=28, line=1.4), "By signing below, the Client accepts this proposal ([Proposal no.]) for [Project name] in the amount of [$0]"
           + (", and the Terms of Service." if acc["terms"] else "."), size=10.5)
    t = table(1, 3, [(BODY_W - 0.5) / 2, 0.5, (BODY_W - 0.5) / 2], rules=False)
    for cell, who in ((t.rows[0].cells[0], "CLIENT"), (t.rows[0].cells[2], d["legal_name"].upper())):
        run(first(cell), who, size=8, bold=True, colour=col["primary"], track=2)
        for label in ("Signature", "Name", "Title", "Date"):
            p = para(cell, before=26, after=2); border(p._p.get_or_add_pPr(), ["bottom"], colour="#9AA5B1")
            para(cell, label, size=7.5, colour=col["grey"], after=0, track=1)
    if acc.get("email"): para(doc, f"Please return a signed copy to {acc['email']}.", size=9, colour=col["grey"], before=30)

    doc.save(out)
    print(f"wrote {out} (proposal, {len(d['details'])} detail rows)")


if __name__ == "__main__":
    kind, payload, out = sys.argv[1:4]
    {"slides": slides, "tracker": tracker, "sheet": sheet, "proposal": proposal}[kind](json.load(open(payload)), out)
