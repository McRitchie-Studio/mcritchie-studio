# Logos

> **When to read this:** Drawing a brand's Navbar Logo, adding a brand or a
> weight to the logo data, or building on `Logos::NavbarLogo`. Colours and the
> live navbar are in [`theme.md`](theme.md).

The **Navbar Logo** (the main logo) is drawn from two things: an ICON (vector
path layers) and a NAME (two words). `Logos::NavbarLogo`
(`lib/logos/navbar_logo.rb`) returns it as an SVG. It reads no database and
loads no font: the letters are Montserrat outlines shipped as data.

```ruby
logo = Logos::NavbarLogo.new("industries")
logo.svg(rule: 4, text: :second, tone: :dark)   # => "<svg …>"
logo.layout(rule: 3, text: :first)              # the geometry alone
logo.examples                                   # all 24: 12 logos, each with its guide drawing
```

## The two rules

The icon is 300 design units tall and split into equal rows. The name is
centred on the icon in both.

| Rule | Rows | Capitals | Where the name sits |
|------|------|----------|---------------------|
| Rule of 3 (`rule: 3`) | 3 | 1 row (a third of the icon) | the middle row |
| Rule of 4 (`rule: 4`) | 4 | 2 rows (half the icon) | the middle two rows |

- The gap between icon and name is half the ink width of the name's first letter.
- The word space is Montserrat's own (the space glyph at weight 300). Kerning is off.
- `text:` is `:homogeneous` (one weight, one colour), `:first` or `:second`
  (that word leads). A brand highlights by **weight** (leading word heavy, the
  other light) or by **colour** (both heavy, leading word in the accent).
- `tone:` is `:light` or `:dark`, the background the logo sits on. The geometry
  is the same; only the fills change.

The rules guide a new build. They are not a pass/fail gate on an existing kit.

## Pure vector

A logo is `<svg>`, `<g>` and `<path>` only: no live text, no picture, no font,
no external reference. Its viewBox is its own box, `0 0 <width> 300`.

`guides: true` returns a separate construction drawing: the row edges, the
icon's right edge, the name's left ink edge, and the row numbers. That drawing
does use `<line>` and `<text>`, so it is for looking at, never for shipping.

## The rake task

```bash
bin/rails 'logos:navbar[industries]'            # writes tmp/logos/industries/*.svg, prints each path
bin/rails 'logos:navbar[studio,/some/dir]'      # or into a directory you name
```

It writes 24 files per brand, named
`<brand>-rule<3|4>-<homogeneous|first|second>-<light|dark>[-guides].svg`.

## The data

| File | Holds |
|------|-------|
| `config/logo_brands.yml` | Each brand's name, icon, highlight, weights and fills. Add a brand here. |
| `lib/logos/data/brand_icons.json` | Icon layers: a path, a role (`primary`, `edge`) and a fill rule each. |
| `lib/logos/data/montserrat_glyphs.json` | Letter outlines for weights 300 to 800, 95 ASCII glyphs each. Cap height is 1, the baseline is y = 0, y grows downward. Letters fill `nonzero`. |
| `lib/logos/data/extract_glyphs.py` | The script that made the glyph file. It needs Python with fonttools and brotli and the engine's Montserrat file; it runs by hand, never in CI. |

A brand that is not in the data, a rule other than 3 or 4, a name that is not
exactly two words, and a character with no glyph each raise
`Logos::NavbarLogo::Error` with the reason. A fill that is not a `#hex` colour
is refused too.
