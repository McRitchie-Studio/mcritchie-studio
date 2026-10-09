# Logos

> **When to read this:** Drawing a brand's Navbar Logo, adding a brand or a
> weight to the logo data, building on `Logos::NavbarLogo`, or changing the
> logo gallery at `/logos`. Colours and the
> live navbar are in [`theme.md`](theme.md).

The **Navbar Logo** (the main logo) is drawn from two things: an ICON (vector
path layers) and a NAME (two words). `Logos::NavbarLogo`
(`lib/logos/navbar_logo.rb`) returns it as an SVG. It reads no database and
loads no font: the letters are outlines shipped as data, Montserrat's or the
brand's own traced lettering.

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
- `tracking` in a brand's style adds space after every letter, in em (negative
  tightens). It is converted to cap heights with the glyph data's own
  `cap_height_em`. It never widens the word space or the logo's right edge: a
  word ends at its last letter's ink.
- `text:` is `:homogeneous` (one weight, one colour), `:first` or `:second`
  (that word leads). A brand highlights by **weight** (leading word heavy, the
  other light) or by **colour** (both heavy, leading word in the accent).
- `tone:` is `:light` or `:dark`, the background the logo sits on. The geometry
  is the same; only the fills change.

The rules guide a new build. They are not a pass/fail gate on an existing kit.

## The brands

| Brand | Icon | Name set in | Leads by |
|-------|------|-------------|----------|
| `studio` | traced chest, one layer | Montserrat 800 and 300 | weight |
| `industries` | kit set square, two layers, drawn flat | Montserrat 700 and 300 | weight |
| `turf` | traced head, three solid layers | Montserrat 800, tracking -0.025 em | colour |
| `welding` | traced helmet: two colours on light, one on dark | its own traced lettering | colour |

Three things a style may ask for beyond an icon and two Montserrat weights:

- **Its own lettering** (`lettering: welding`). The name's two words are looked
  up whole in `brand_lettering.json` and drawn from the brand's traced letters.
  There is one weight, so the brand must use `highlight: colour`; the word
  space and the fill rule are the lettering's own (`evenodd`: a traced letter
  carries its counters as sub-paths). `highlight: weight`, a `tracking`, or a
  word the lettering does not hold is refused.
- **Tracking** (`tracking: -0.025`), above. Montserrat brands only.
- **An icon per tone** (`icon_key:` inside a tone). Commercial Welding's dark
  tone draws `welding_mono`, a solid helmet, because the two-colour helmet's
  white half is transparent. A tone that names none draws the brand's `icon`.
  The tone's icon sets that tone's geometry, so `layout` takes `tone:` too.

A style's optional `note` is the line its brand page shows about where the art
came from.

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

## The gallery

A read-only admin gallery (`LogosController`) shows the library's output. It
stores nothing: choosing a logo for a brand waits for the brand kit record. It is
linked from the admin sidebar as **Logos**.

| Route | Shows |
|-------|-------|
| `/logos` | One row per brand in `config/logo_brands.yml`: its rule-of-4 logo with the second word leading, on a light and a dark plate; its typeface (Montserrat and the weights the brand uses, or "Traced from its own lettering"); its fills as swatches. |
| `/logos/:brand` | The brand's `note`, then every logo, by rule and then by text, each on a light and a dark plate, with **Download** and **Copy SVG**. `?guides=1` swaps every logo for its guide drawing. |
| `/logos/:brand/navbar` | One logo as `image/svg+xml`. Params: `rule` (`3`, `4`), `text` (`homogeneous`, `first`, `second`), `tone` (`light`, `dark`), `guides` (`0`, `1`); an absent one takes the library's default. `download=1` sends it as an attachment named `<brand>-navbar-rule<3|4>-<text>-<tone>[-guides].svg`. |

- An unknown brand is a 404. Any other param the library or the parser refuses
  is a 422 whose body is the reason in plain text.
- `Logos::Variant` (`lib/logos/variant.rb`) reads the params and gives each logo
  its filename and its accessible name.
- The plates are fixed colours (`LogosHelper::LOGO_PLATES`), not theme tokens: a
  logo's fills are baked per tone, so its plate must not follow the hub theme.
- The logo route has no `.svg` extension. An extension sets the request format,
  and the admin wall answers a non-HTML format with a bare 401 or 403.
- The Industries icon is drawn flat (two solid layers), without the marketing
  kit's steel gradient and tick marks. Turf Monster's head and Commercial
  Welding's helmet and lettering are auto-traced from pictures. Each brand's
  `note` says so on its page.

## The data

| File | Holds |
|------|-------|
| `config/logo_brands.yml` | Each brand's name, icon, highlight, weights or lettering, tracking, note and fills. Add a brand here. |
| `lib/logos/data/brand_icons.json` | Studio's and Industries' icon layers: a path, a role (`primary`, `edge`) and a fill rule each. |
| `lib/logos/data/brand_icons_turf_welding.json` | The same format for `turf` (roles `outline`, `body`, `light`), `welding` (`primary`, `accent`) and `welding_mono` (`primary`). The library reads both icon files as one set. |
| `lib/logos/data/brand_lettering.json` | A brand's own lettering: per word, a list of letters (`d`, `adv`, `l`, `r`) in the glyph file's units, plus the word `space` and the `fill_rule`. |
| `lib/logos/data/montserrat_glyphs.json` | Letter outlines for weights 300 to 800, 95 ASCII glyphs each. Cap height is 1, the baseline is y = 0, y grows downward. Letters fill `nonzero`. |
| `lib/logos/data/extract_glyphs.py` | The script that made the glyph file. It needs Python with fonttools and brotli and the engine's Montserrat file; it runs by hand, never in CI. |

A brand that is not in the data, a rule other than 3 or 4, a name that is not
exactly two words, and a character with no glyph each raise
`Logos::NavbarLogo::Error` with the reason. A fill that is not a `#hex` colour
is refused too.

## What the data may contain

Paths, fill rules and transforms are written into the SVG as they stand, so
`Logos::NavbarLogo.new` checks every one its brand will draw (each tone's icon
and every letter) and raises `Logos::NavbarLogo::Error` before anything is
drawn:

| Value | Must be |
|-------|---------|
| a path `d` (icon layer, glyph, traced letter) | a string of SVG path characters only: the command letters `MLHVCSQTAZ` in either case, digits, space, comma, dot, minus, plus, and `e`/`E` for exponents |
| a `fill_rule` (icon layer, lettering) | `nonzero` or `evenodd` |
| an icon's `transform`, when present | `translate`, `scale`, `rotate` or `matrix` calls with numeric arguments, separated by single spaces |

The patterns are anchored at both ends (`\A…\z`), so a value that only starts
clean, or ends in a newline, is refused. New art comes in through these files,
so a new icon or lettering needs no code change, only data that passes.
