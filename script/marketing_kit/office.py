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

    Letter pages with one section each: cover, about us, details and pricing, clients, why choose us, then the terms
    and the signature block. The brand's two-tone bar runs edge to edge in every page's header and footer. Nothing is
    positioned absolutely, so the Doc stays editable: bands, boxes and the details grid are table cells.
    """
    import re
    from PIL import Image
    from docx import Document
    from docx.enum.table import WD_TABLE_ALIGNMENT, WD_CELL_VERTICAL_ALIGNMENT
    from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn
    from docx.shared import Inches, Pt, RGBColor

    col, img, FONT = d["colours"], d["images"], d["font"]
    rgb = lambda h: RGBColor.from_string(h.lstrip("#"))
    tmp = tempfile.mkdtemp(prefix="kit-proposal-")
    PAGE_W, MARGIN = 8.5, 0.75
    BODY_W = PAGE_W - 2 * MARGIN

    def crop(path, w_in, h_in):
        im = Image.open(path).convert("RGB"); want = w_in / h_in; iw, ih = im.size
        if iw / ih > want:
            nw = max(1, int(ih * want)); im = im.crop(((iw - nw) // 2, 0, (iw - nw) // 2 + nw, ih))
        else:
            nh = max(1, int(iw / want)); im = im.crop((0, (ih - nh) // 2, iw, (ih - nh) // 2 + nh))
        p = os.path.join(tmp, f"{len(os.listdir(tmp))}.jpg"); im.save(p, quality=85)
        return p

    def bar():
        """The two-tone bar: a third accent, two thirds primary, as the IPA-ENG proposal's grey and blue."""
        w, h = 2550, 72
        im = Image.new("RGB", (w, h), tuple(int(col["primary"][i:i + 2], 16) for i in (1, 3, 5)))
        im.paste(tuple(int(col["accent"][i:i + 2], 16) for i in (1, 3, 5)), (0, 0, w // 3, h))
        p = os.path.join(tmp, "bar.png"); im.save(p); return p

    doc = Document()
    normal = doc.styles["Normal"]
    normal.font.name, normal.font.size, normal.font.color.rgb = FONT, Pt(10.5), rgb(col["ink"])
    normal.element.rPr.rFonts.set(qn("w:eastAsia"), FONT)
    normal.paragraph_format.space_after = Pt(4)
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Inches(PAGE_W), Inches(11)
    sec.left_margin = sec.right_margin = Inches(MARGIN)
    sec.top_margin, sec.bottom_margin = Inches(0.85), Inches(0.75)
    sec.header_distance = sec.footer_distance = Inches(0)
    strip = bar()
    for part in (sec.header, sec.footer):
        p = part.paragraphs[0]; p.paragraph_format.left_indent = Inches(-MARGIN)
        p.paragraph_format.space_after = Pt(0)
        p.add_run().add_picture(strip, width=Inches(PAGE_W))

    def shade(cell, hexcol):
        tc = cell._tc.get_or_add_tcPr(); sh = OxmlElement("w:shd")
        sh.set(qn("w:val"), "clear"); sh.set(qn("w:color"), "auto"); sh.set(qn("w:fill"), hexcol.lstrip("#")); tc.append(sh)

    def borders(table, hexcol=None, size=8):
        tbl = table._tbl.tblPr; b = OxmlElement("w:tblBorders")
        for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
            e = OxmlElement(f"w:{edge}")
            e.set(qn("w:val"), "single" if hexcol else "nil")
            if hexcol: e.set(qn("w:sz"), str(size)); e.set(qn("w:color"), hexcol.lstrip("#"))
            b.append(e)
        tbl.append(b)

    def widths(table, inches):
        """Fixed column widths. Google's import reads the table grid and width, not only each cell's own width."""
        table.autofit = False
        tbl = table._tbl; pr = tbl.tblPr
        for tag in ("w:tblW", "w:tblLayout"):
            for e in pr.findall(qn(tag)): pr.remove(e)
        tw = OxmlElement("w:tblW"); tw.set(qn("w:w"), str(int(sum(inches) * 1440))); tw.set(qn("w:type"), "dxa"); pr.append(tw)
        lay = OxmlElement("w:tblLayout"); lay.set(qn("w:type"), "fixed"); pr.append(lay)
        grid = tbl.tblGrid
        for gc, w in zip(grid.findall(qn("w:gridCol")), inches): gc.set(qn("w:w"), str(int(w * 1440)))
        for row in table.rows:
            for cell, w in zip(row.cells, inches): cell.width = Inches(w)

    def pad(cell, top=0.08, side=0.12):
        tc = cell._tc.get_or_add_tcPr(); m = OxmlElement("w:tcMar")
        for edge, v in (("top", top), ("bottom", top), ("left", side), ("right", side)):
            e = OxmlElement(f"w:{edge}"); e.set(qn("w:w"), str(int(v * 1440))); e.set(qn("w:type"), "dxa"); m.append(e)
        tc.append(m)

    def runs(p, text, size=None, bold=False, colour=None, spacing=None, field_bold=True, whole=False):
        """Writes text; a [bracketed] part is a field, in the accent colour. With whole=True, text with no brackets at
        all is one field (a detail row's single placeholder)."""
        parts = re.split(r"(\[[^\]]*\])", text) if "[" in text or not whole else [f"[{text}]"]
        for part in parts:
            if not part: continue
            r = p.add_run(part); r.font.name = FONT
            if size: r.font.size = Pt(size)
            is_field = part.startswith("[") and part.endswith("]")
            r.bold = bold or (is_field and field_bold)
            r.font.color.rgb = rgb(col["accent"] if is_field else (colour or col["ink"]))
            if spacing: r.font._element.get_or_add_rPr().append(_spacing(spacing))
        return p

    def _spacing(pt):
        e = OxmlElement("w:spacing"); e.set(qn("w:val"), str(int(pt * 20))); return e

    def text(container, t, size=10.5, bold=False, colour=None, align=None, spacing=None, after=4, before=0):
        p = container.add_paragraph(); p.paragraph_format.space_after = Pt(after); p.paragraph_format.space_before = Pt(before)
        if align == "center": p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        if align == "right": p.alignment = WD_ALIGN_PARAGRAPH.RIGHT
        if align == "justify": p.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
        r = p.add_run(t); r.font.name = FONT; r.font.size = Pt(size); r.bold = bold
        r.font.color.rgb = rgb(colour or col["ink"])
        if spacing: r.font._element.get_or_add_rPr().append(_spacing(spacing))
        return p

    def picture(container, path, w):
        p = container.add_paragraph(); p.paragraph_format.space_after = Pt(0); p.add_run().add_picture(path, width=Inches(w)); return p

    def page_break():
        doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)

    def band(title, size=22):
        """A primary band with the title in white and an accent square beside it."""
        t = doc.add_table(rows=1, cols=3); borders(t); widths(t, [5.0, 0.55, BODY_W - 5.55])
        a, b, _ = t.rows[0].cells
        shade(a, col["primary"]); shade(b, col["accent"]); pad(a, 0.16, 0.3)
        a.paragraphs[0].paragraph_format.space_after = Pt(0)
        runs(a.paragraphs[0], title, size=size, bold=True, colour=col["white"], spacing=3) if "[" in title else None
        if "[" not in title:
            r = a.paragraphs[0].add_run(title); r.font.name = FONT; r.font.size = Pt(size); r.bold = True
            r.font.color.rgb = rgb(col["white"]); r.font._element.get_or_add_rPr().append(_spacing(3))
        text(doc, "", size=4, after=8)

    def motto():
        if d.get("motto"): text(doc, d["motto"], size=10, bold=True, colour="#A0B3C4", align="center", spacing=2.5, before=14)

    def logo_box(container_cell):
        shade(container_cell, col["dark"]); pad(container_cell, 0.18, 0.25)
        container_cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
        p = container_cell.paragraphs[0]; p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.add_run().add_picture(img["logo_box"], height=Inches(1.35))

    # ---- Cover
    head = doc.add_table(rows=1, cols=2); borders(head); widths(head, [3.4, BODY_W - 3.4])
    logo_box(head.rows[0].cells[0])
    text(doc, "", size=2, after=2)
    band("PROPOSAL", size=36)
    picture(doc, crop(img["cover"], BODY_W, 2.9), BODY_W)
    cv = d["cover"]
    if cv.get("credentials"): text(doc, cv["credentials"], size=11, bold=True, colour=col["primary"], spacing=2, before=12)
    if cv.get("certifications"): runs(doc.add_paragraph(), f"[{cv['certifications']}]", size=9)
    foot = doc.add_table(rows=1, cols=2); borders(foot); widths(foot, [BODY_W / 2, BODY_W / 2])
    left, right = foot.rows[0].cells
    left.paragraphs[0].add_run().add_picture(img["icon"], width=Inches(0.55))
    text(left, "PREPARED FOR:", size=11, bold=True, colour=col["ink"], spacing=2, before=6)
    for f in ("Contact name", "Company", "Address"): runs(left.add_paragraph(), f"[{f}]", size=10)
    right.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.BOTTOM
    runs(right.paragraphs[0], "[PROJECT NAME]", size=11, bold=True).alignment = WD_ALIGN_PARAGRAPH.RIGHT
    for line in (f"Proposal no. [{cv['number']}]", "Date: [Month D, YYYY]", "Prepared by: [Your name]"):
        runs(right.add_paragraph(), line, size=10, field_bold=True).alignment = WD_ALIGN_PARAGRAPH.RIGHT

    # ---- About us
    page_break()
    picture(doc, crop(img["about"], BODY_W, 3.2), BODY_W)
    text(doc, "", size=4, after=4)
    band("ABOUT US", size=28)
    text(doc, d["about"]["text"], size=10.5, align="justify", after=10)
    text(doc, d["tagline"], size=11.5, bold=True, colour=col["ink"], spacing=1.5, before=6, after=8)
    cols = d["about"]["columns"]
    if cols:
        t = doc.add_table(rows=1, cols=3); borders(t); widths(t, [0.7, (BODY_W - 0.7) / 2, (BODY_W - 0.7) / 2])
        icon_cell, *cells = t.rows[0].cells
        icon_cell.paragraphs[0].add_run().add_picture(img["icon"], width=Inches(0.5))
        for cell, c in zip(cells, cols):
            pad(cell, 0.02, 0.1)
            cell.paragraphs[0].paragraph_format.space_after = Pt(3)
            r = cell.paragraphs[0].add_run(c["title"].upper()); r.font.name = FONT; r.font.size = Pt(10.5); r.font.color.rgb = rgb(col["ink"])
            r.font._element.get_or_add_rPr().append(_spacing(1.5))
            text(cell, c["text"], size=10, align="justify")
    motto()

    # ---- Proposal details
    page_break()
    band("PROPOSAL DETAILS")
    t = doc.add_table(rows=0, cols=2); borders(t, col["primary"], 10)
    for row in d["details"]:
        cells = t.add_row().cells
        for cell in cells: pad(cell, 0.09, 0.1)
        lp = cells[0].paragraphs[0]; r = lp.add_run(row["label"]); r.bold = True; r.font.size = Pt(10); r.font.name = FONT
        vc = cells[1]; first = True
        for line in row["lines"]:
            p = vc.paragraphs[0] if first else vc.add_paragraph(); first = False
            if row["bullets"]: p.style = doc.styles["List Bullet"]
            runs(p, line, size=10, field_bold=False, whole=not row["bullets"])
        pr = row.get("pricing")
        if pr:
            for b in pr["breakdown"]:
                p = vc.add_paragraph(style="List Bullet"); runs(p, f"{b['category']}: [$0]", size=10, field_bold=False)
                for item in b["items"]:
                    runs(vc.add_paragraph(style="List Bullet 2"), f"{item}: [$0]", size=10, field_bold=False)
            text(vc, pr["total_label"], size=10, before=8)
            tp = vc.add_paragraph(); tp.alignment = WD_ALIGN_PARAGRAPH.CENTER
            r = tp.add_run("Total amount: "); r.bold = True; r.font.size = Pt(10.5); r.font.name = FONT
            runs(tp, "[$0]", size=10.5, bold=True)
    widths(t, [1.45, BODY_W - 1.45])
    motto()

    # ---- Clients
    cl = d["clients"]
    if img.get("clients") or cl["names"]:
        page_break()
        band("CLIENTS")
        if img.get("clients"):
            p = picture(doc, img["clients"], BODY_W); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        else:
            names = cl["names"]; per = 4
            t = doc.add_table(rows=0, cols=per); borders(t, col["line"], 6)
            for i in range(0, len(names), per):
                cells = t.add_row().cells
                for cell, n in zip(cells, names[i:i + per]):
                    pad(cell, 0.12, 0.08); cell.paragraphs[0].alignment = WD_ALIGN_PARAGRAPH.CENTER
                    r = cell.paragraphs[0].add_run(n); r.bold = True; r.font.size = Pt(10); r.font.color.rgb = rgb(col["primary"])
            widths(t, [BODY_W / per] * per)
        if cl.get("note"): text(doc, cl["note"], size=8.5, colour=col["grey"], before=6)
        motto()

    # ---- Why choose us
    why = d["why"]
    if why["columns"]:
        page_break()
        t = doc.add_table(rows=1, cols=2); borders(t); widths(t, [3.4, BODY_W - 3.4])
        logo_box(t.rows[0].cells[0])
        ph = t.rows[0].cells[1]; pad(ph, 0, 0)
        ph.paragraphs[0].add_run().add_picture(crop(img["why"], BODY_W - 3.4, 3.4), width=Inches(BODY_W - 3.4))
        text(doc, "", size=6, after=10)
        t = doc.add_table(rows=1, cols=2); borders(t); widths(t, [3.0, BODY_W - 3.0])
        big, side = t.rows[0].cells
        big.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
        for w in ("WHY", "CHOOSE", "US?"):
            text(big, w, size=36, bold=True, colour=col["ink"], after=0)
        big.paragraphs[0].paragraph_format.space_after = Pt(0)
        text(big, "▬▬▬", size=14, colour=col["primary"], before=6)
        tc = side._tc.get_or_add_tcPr(); b = OxmlElement("w:tcBorders"); e = OxmlElement("w:left")
        e.set(qn("w:val"), "single"); e.set(qn("w:sz"), "24"); e.set(qn("w:color"), col["primary"].lstrip("#")); b.append(e); tc.append(b)
        pad(side, 0.05, 0.25)
        first = True
        for c in why["columns"]:
            p = side.paragraphs[0] if first else side.add_paragraph(); first = False
            p.paragraph_format.space_before = Pt(0 if p is side.paragraphs[0] else 10)
            r = p.add_run(c["title"].upper()); r.font.name = FONT; r.font.size = Pt(10.5); r.font._element.get_or_add_rPr().append(_spacing(1.5))
            text(side, c["text"], size=9.5, align="justify")
        if why.get("contact"): text(doc, why["contact"], size=11, colour=col["ink"], align="center", spacing=1, before=18)

    # ---- Terms of service, then the signature block on the last page
    page_break()
    terms = d.get("terms")
    if terms:
        band("TERMS OF SERVICE")
        for t_ in terms["intro"]: text(doc, t_, size=8.5, after=5)
        for k, v in terms["items"]:
            p = doc.add_paragraph(style="List Number"); p.paragraph_format.space_after = Pt(2)
            r = p.add_run(f"{k}. "); r.bold = True; r.font.size = Pt(8.5); r.font.name = FONT
            r = p.add_run(v); r.font.size = Pt(8.5); r.font.name = FONT
        page_break()
    acc = d["acceptance"]
    band("ACCEPTANCE")
    p = doc.add_paragraph(); p.paragraph_format.space_after = Pt(8)
    runs(p, "By signing below, the Client accepts this proposal ([Proposal no.]) for [Project name] in the amount of [$0]"
            + (", and the Terms of Service above." if acc["terms"] else "."), size=9.5, field_bold=True)
    t = doc.add_table(rows=1, cols=2); borders(t, col["line"], 6); widths(t, [BODY_W / 2, BODY_W / 2])
    for cell, who in zip(t.rows[0].cells, ("CLIENT", d["legal_name"].upper())):
        pad(cell, 0.1, 0.14)
        r = cell.paragraphs[0].add_run(who); r.bold = True; r.font.size = Pt(9.5); r.font.color.rgb = rgb(col["primary"])
        for label in ("Signature", "Name", "Title", "Date"):
            text(cell, f"{label}: ______________________________", size=9.5, before=8, after=0)
    if acc.get("email"): text(doc, f"Please return a signed copy to {acc['email']}.", size=9.5, before=8)
    motto()

    doc.save(out)
    print(f"wrote {out} (proposal, {len(d['details'])} detail rows)")


if __name__ == "__main__":
    kind, payload, out = sys.argv[1:4]
    {"slides": slides, "tracker": tracker, "sheet": sheet, "proposal": proposal}[kind](json.load(open(payload)), out)
