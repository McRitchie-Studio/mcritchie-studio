#!/usr/bin/env python3
"""Extract Montserrat letter outlines as data, so the hub can set a name as vector paths with no font library.
Units: cap height = 1, baseline y = 0, y grows downward. Source: studio-engine's vendored variable Montserrat (OFL).
Run: venv/bin/python extract_glyphs.py <out.json>   (needs fonttools + brotli)"""
import json, sys
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.boundsPen import BoundsPen
SRC = "/Users/alex/projects/studio-engine/app/assets/fonts/studio/montserrat-latin.woff2"
out = {"font": "Montserrat", "license": "SIL Open Font License 1.1", "source": "studio-engine app/assets/fonts/studio/montserrat-latin.woff2",
       "units": "cap height = 1, baseline y = 0, y down; fill-rule nonzero", "kerning": False, "weights": {}}
for w in (300, 400, 500, 600, 700, 800):
    f = instancer.instantiateVariableFont(TTFont(SRC), {"wght": w})
    gs, cmap, cap = f.getGlyphSet(), f.getBestCmap(), f["OS/2"].sCapHeight; k = 1.0 / cap
    glyphs = {}
    for code in range(0x20, 0x7F):
        if code not in cmap: continue
        g = gs[cmap[code]]
        pen = SVGPathPen(gs, ntos=lambda v: ("%.4f" % v).rstrip("0").rstrip(".")); g.draw(TransformPen(pen, (k, 0, 0, -k, 0, 0)))
        bp = BoundsPen(gs); g.draw(bp); b = bp.bounds or (0, 0, 0, 0)
        glyphs[chr(code)] = {"d": pen.getCommands(), "adv": round(g.width * k, 4), "l": round(b[0] * k, 4), "r": round(b[2] * k, 4)}
    out["weights"][str(w)] = {"cap_height_em": cap / f["head"].unitsPerEm, "glyphs": glyphs}
json.dump(out, open(sys.argv[1], "w"), separators=(",", ":"))
print(len(out["weights"]), "weights,", len(glyphs), "glyphs each")
