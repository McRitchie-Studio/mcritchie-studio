# Logos

> **When to read this:** Drawing a brand's Navbar Logo, icon or Stacked Logo,
> adding a brand or a weight to the logo data, building on `Logos::NavbarLogo`
> or `Logos::StackedLogo`, or changing the logo gallery at `/logos`. Colours
> and the live navbar are in [`theme.md`](theme.md).

A brand has three logo types, all drawn from the same data:

| Type | Drawn by | What it is |
|------|----------|------------|
| Icon | `Logos::NavbarLogo#icon_svg` | the icon alone ([below](#the-icon-alone)) |
| Navbar Logo | `Logos::NavbarLogo#svg` | the icon, then the name on one line (the main logo) |
| Stacked Logo | `Logos::StackedLogo#svg` | the icon above the name ([below](#the-stacked-logo)) |

The **Navbar Logo** (the main logo) is drawn from two things: an ICON (vector
path layers) and a NAME (two words). `Logos::NavbarLogo`
(`lib/logos/navbar_logo.rb`) returns it as an SVG. It reads no database and
loads no font: the letters are outlines shipped as data, Montserrat's or the
brand's own traced lettering.

```ruby
logo = Logos::NavbarLogo.new("industries")
logo.svg(rule: 4, text: :second, tone: :dark)   # => "<svg …>"
logo.layout(rule: 3, text: :first)              # the geometry alone
logo.svg(rule: 4, text: :second, tone: :watermark)   # one colour, slightly transparent
logo.examples                                   # all 24 light and dark: 12 logos, each with its guide drawing
logo.icon_svg(tone: :dark)                      # the icon alone
Logos::StackedLogo.new("industries").svg(text: :first, tone: :light)   # the icon above the name
```

A logo has no background. The SVG is transparent wherever it draws nothing, in
every tone.

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
- `tone:` is `:light` or `:dark`, the background the logo sits on, or
  `:watermark` (below). The geometry is the same; only the fills change.

## The watermark tone

`tone: :watermark` draws the whole logo in ONE colour, slightly transparent, for
placing over a photograph.

- Every path, icon layers and both words, takes one fill: `#FFFFFF` unless the
  style says otherwise.
- The logo sits in a single `<g opacity="…">`, `0.6` by default. The opacity is
  on the group and never on a path, so overlapping layers do not compound.
- The box is the light logo's: same width, same height.
- The text versions still apply. A brand that leads by weight keeps its two
  weights. A brand that leads by colour has only one colour here, so its three
  text versions are the same drawing.
- Guides are drawn at full strength, outside the group.
- The icon is the brand's own, every layer in the one fill, unless the style
  names another (`watermark.icon_key`). Studio's icon is one layer, and the
  Industries edge merges into its triangle, so neither names one. Turf Monster's
  three solid layers would fill in as a blob, so it draws `turf_mono` (the
  head's linework); Commercial Welding draws `welding_mono`.

A style's optional `watermark:` map sets it:

| Key | Default | Must be |
|-----|---------|---------|
| `fill` | `#FFFFFF` | a `#hex` colour |
| `opacity` | `0.6` | a number greater than 0 and at most 1 |
| `icon_key` | the brand's `icon` | a key in the icon data |

Any other key, or a value outside these, raises `Logos::NavbarLogo::Error`.
`examples` and the rake task draw the light and dark tones only.

The rules guide a new build. They are not a pass/fail gate on an existing kit.

## The icon alone

`logo.icon_svg(tone:)` returns the brand's icon with nothing beside it: the
same layers, the same fills and the same per-tone icon the Navbar Logo draws.

- Its viewBox is the icon's own box, `0 0 <w> <h>` from the icon data, not the
  300-unit logo box.
- `tone:` is `:light` (the default), `:dark` or `:watermark`. A watermark icon is
  one fill inside one translucent group, like a watermark logo, and draws the
  style's `watermark.icon_key` when it names one.
- It is paths only, with a transparent background. There is no guide drawing.
- `logo.watermark` returns the checked watermark settings (`fill`, `opacity`,
  and `icon_key` when set).

## The Stacked Logo

`Logos::StackedLogo` (`lib/logos/stacked_logo.rb`) draws the icon above the
name on the **3-2-1 method**. It subclasses `Logos::NavbarLogo`, so the style,
the icons, the letters, the checks, the three text versions and the three tones
are the same; only the layout differs. It has no rule.

```ruby
stacked = Logos::StackedLogo.new("studio")
stacked.svg(text: :first, tone: :dark)   # => "<svg …>"
stacked.svg(text: :first, guides: true)  # the construction drawing
stacked.layout(text: :second)            # the geometry alone
stacked.form                             # => :two_line (the brand's own form, the default)
stacked.forms                            # => [:two_line, :tagline]
stacked.svg(form: :tagline)              # icon, name, tagline
stacked.tagline                          # => "BUILD SMARTER"
```

Let **u** be the small word's cap height (40 design units).

| Form | Top to bottom | Width | Height |
|------|---------------|-------|--------|
| `two_line` (the default) | icon, 2u, the first word at 3u, 2u, the second word at 1u | the first word's ink, W | 0.6W + 8u |
| `one_line` (`stacked: one_line` in the style) | icon, 2u, the whole name at 3u | the name's ink, W | 0.6W + 5u |
| `tagline` (a brand with a `tagline`, beside its own form) | icon, 2u, the whole name at 3u, 2u, the tagline at 1u | the name's ink, W | 0.6W + 8u |

- **Two lines.** The second word is tracked out until its ink is exactly 60% of
  the first word's ink width. The tracking is computed, added between letters
  only, and never after the last. The brand's own `tracking` is not added to it.
- **The icon** is as tall as the small word is wide, 0.6W, and scaled to that.
- **Centring.** The icon and the small word are centred on the big line.
- **One line.** The name is set exactly as the Navbar Logo sets it, with the
  brand's tracking and word space, and the icon is 60% of its width tall. Turf
  Monster uses it: "Monster" is already 68% as wide as "Turf", so it cannot be
  tracked out under it.
- **Width over height** is 3n / (1.8n + 8) for two lines and 3n / (1.8n + 5) for
  one, where n is the big line's ink width in cap heights. Studio measures
  1.078 with the first word leading and 1.056 with the second; Industries 1.073
  and 1.056; Turf Monster 1.28.
- **A lettering brand** (Commercial Welding) stacks in two lines: its traced
  letters carry their own advances, so the small word can be tracked.
- **With tagline.** The name is set exactly as the one-line form sets it (both
  words, the word space, the brand's tracking and lettering). The tagline is
  the small line: Montserrat 500 for every brand (Commercial Welding's own
  tagline lettering is not traced yet), tracked between its characters, a space
  being one, until its ink is exactly 60% of the name's; the icon is as tall as
  the tagline is wide. The three text versions and the tones apply to the name;
  the tagline takes the tone's `quiet` fill (`text` without one), and the
  watermark's one fill. Width over height is 3n / (1.8n + 8), n the name's ink
  width in cap heights: Studio 1.271 homogeneous, Industries 1.327, Commercial
  Welding 1.284 (`TAGLINE_RATIOS` in `test/lib/logos_stacked_logo_test.rb`).
  Turf Monster has no tagline, so it has no tagline form.

`Logos::StackedLogo.new` refuses, with `Logos::NavbarLogo::Error`:

- a two-line brand whose second word is wider than 60% of its first, or has one
  letter. The message names the brand and says to set `stacked: one_line`.
  Negative tracking is never drawn.
- a `stacked` value other than `two_line` or `one_line`;
- a `tagline` that is not words separated by single spaces, has a character
  the glyph data lacks at weight 500, or is already wider than 60% of the name
  (named by brand; never tracked in);
- a form the brand does not draw: "brand turf: no stacked form :tagline (it
  has no tagline)";
- an icon so wide that, at its height, it would overhang the name;
- a keyword `svg` or `layout` does not take, `rule:` above all: "a stacked
  logo takes text, tone, form and guides, not rule: it has no rule".

`guides: true` returns the construction drawing, on the method of the 3-2-1
reel: every measurement is proved with **ghost copies** of the small line (the
second word; the tagline; in the one-line form the whole name at 1u, a third of
its size), set untracked in their own weight:

- **The ruler.** Right of the logo, one copy per unit, edge to edge, from the
  icon's foot to the logo's foot: 2 beside the first gap, 3 beside the big line,
  2 beside the second gap, 1 beside the small line (the one-line form stops
  after the 3). The copies are numbered 1-2, 1-2-3, 1-2, 1 between the logo and
  the ruler, so each band can be counted.
- **The icon's height.** The small line's letters one under another in a column
  half a unit left of the icon's box, each where it sits along the line, the
  first capital's top on the icon's top and the last letter on its foot, with a
  magenta bracket beside the column ticked at both ends: the icon is as tall as
  the small line is wide. The column stands on the plate, never on the icon, so
  it reads whatever the icon is filled with (review of PR 2042: drawn over the
  icon it vanished, 1.02-1.32:1). A letter is never above 1u, and is drawn small
  enough not to touch the next. A vertical line runs through the logo's centre,
  and a 1 marks the icon's top.
- **Lines** only at band boundaries, across the logo and the ruler.

The ghosts are the logo's own text colour (the watermark's fill in a
watermark), at `GHOST_OPACITY` (0.25 on light, 0.22 on dark and watermark),
inside one `<g class="guide-ghosts">`, every one of them on the background. They
measure 1.4:1 to 2.2:1 against the hub card the gallery shows them on (white in
the light theme, #3C3853 in the dark theme and the watermark context), and the
logo's text is more than twice that
(`test/helpers/logos_helper_test.rb`). The lines (1.0 design units) and the
numbers (28) are in the guide magenta, inside `<g class="guide-lines">`. Both
groups sit outside a watermark's translucent group, and the logo inside the
drawing is the plain logo to the byte. `examples` is not defined on a
Stacked Logo, and the rake task writes Navbar Logos only.

## The brands

| Brand | Icon | Name set in | Leads by | Tagline |
|-------|------|-------------|----------|---------|
| `studio` | traced chest, one layer | Montserrat 800 and 300 | weight | BUILD SMARTER |
| `industries` | kit set square, two layers, drawn flat | Montserrat 700 and 300 | weight | BUILD BETTER |
| `turf` | traced head, three solid layers; its linework alone as a watermark | Montserrat 800, tracking -0.025 em | colour | none |
| `welding` | traced helmet: two colours on light, one on dark | its own traced lettering | colour | BUILDING STRONG CONNECTIONS |

Three things a style may ask for beyond an icon and two Montserrat weights:

- **Its own lettering** (`lettering: welding`). The name's two words are looked
  up whole in `brand_lettering.json` and drawn from the brand's traced letters.
  There is one weight, so the brand must use `highlight: colour`; the word
  space and the fill rule are the lettering's own (`evenodd`: a traced letter
  carries its counters as sub-paths). `highlight: weight`, a `tracking`, or a
  word the lettering does not hold is refused.
- **Tracking** (`tracking: -0.025`), above. Montserrat brands only.
- **An icon per tone** (`icon_key:` inside a tone). Commercial Welding's dark
  tone draws `welding_mono`, the helmet in one colour (half of it filled, half
  drawn in outline), because the two-colour helmet's white half is transparent. A tone that names none draws the brand's `icon`.
  The tone's icon sets that tone's geometry, so `layout` takes `tone:` too.

A style's optional `note` is the line its brand page shows about where the art
came from.

## Pure vector

A logo is `<svg>`, `<g>` and `<path>` only: no live text, no picture, no font,
no external reference. Its viewBox is its own box, `0 0 <width> 300`.

`guides: true` returns a separate construction drawing: the row edges, the
icon's right edge, the name's left ink edge, the row numbers, and ghost copies
of the name one row tall in every row, as the rule-of-thirds reel draws them.
Rule of 3: a copy above and below the real name make three. Rule of 4: four
copies, two of them behind the two-row name. The ghosts are the logo's text
colour, faint, in `<g class="guide-ghosts">` BEHIND the logo; the lines (1.0)
and numbers (30) are in `<g class="guide-lines">`. That drawing does use
`<line>` and `<text>`, so it is for looking at, never for shipping. Only logos
WITHOUT guides are pinned to the byte (SHA-256 tests in
`test/lib/logos_navbar_logo_test.rb` and `test/lib/logos_stacked_logo_test.rb`).

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
| `/logos` | One row per brand in `config/logo_brands.yml`. Its **Logos** cell is one tight cluster (`logos/_cluster`): the **Stacked** Logo (first word leading) as a square on the left, the **Navbar** Logo (rule of 4, second word leading) beside it, and the **Icon** as a small square under the Navbar Logo, each a tile with a badge naming its type and linking to its tab of the brand page. Then its **Typeface** hierarchy and its **Colours** (below). |
| `/logos/:brand` | The brand's page, **tabbed by logo type**: `?type=icon`, `navbar` (the default) or `stacked`. Each tab shows that type's logos once, with **Download** and **Copy SVG**. Under the tabs, the brand's **Colours** and **Typefaces**. |
| `/logos/:brand/icon` | The icon as `image/svg+xml`. Param: `tone`. Named `<brand>-icon-<tone>.svg`. |
| `/logos/:brand/navbar` | One Navbar Logo. Params: `rule` (`3`, `4`), `text` (`homogeneous`, `first`, `second`), `tone` (`light`, `dark`, `watermark`), `guides` (`0`, `1`). Named `<brand>-navbar-rule<3|4>-<text>-<tone>[-guides].svg`. |
| `/logos/:brand/stacked` | One Stacked Logo. Params: `form` (`two_line`, `one_line`, `tagline`: only those the brand draws; absent is its own), `text`, `tone`, `guides`. Named `<brand>-stacked-<two-line|one-line|tagline>-<text>-<tone>[-guides].svg`. |

On the three SVG routes an absent param takes the library's default (so
`/navbar` alone is the rule of 3), a param the type does not take is not read,
and `download=1` sends the file as an attachment. The type is the route's own:
a `?type=` in the query string cannot change it.

### Colours and typefaces

A brand's kit as the gallery shows it is data in `config/logo_brands.yml`, read
and checked by `Logos::BrandKit` (`lib/logos/brand_kit.rb`):

- **`palette:`** is the brand's one ordered list of named colours, `{ name, hex }`.
  There is no split by light, dark or watermark: those are the logos' fills
  (`tones`, `watermark`), which stay per tone because a dark-text logo still
  needs a light-text version on a dark page. Each colour shows as a swatch with
  its name and hex; a click copies the hex (`logos/_palette`, `data-copy-hex`). Studio has five
  (Ink, Violet, Deep Violet, Violet Mist, White), Industries the marketing kit's
  eight, Turf Monster seven and Commercial Welding four.
- **`typefaces:`** is the brand's typeface hierarchy, most prominent first, at
  most three levels of `{ role, family, weight }`. `family` must be a face the
  hub serves (Montserrat, which studio-engine vendors as a variable font), and
  `weight` 100 to 900 in hundreds; the level is named by both ("Montserrat
  ExtraBold"). A level set in the brand's own traced lettering (Commercial
  Welding's Display) has no family and no weight, only a `label`. Each level
  shows its name in its own face at a size that steps down with the level
  (`LogosHelper::LOGO_TYPEFACE_SIZES`), under its role; a traced level shows a
  small picture of the brand's name in its lettering instead (`logos/_typefaces`).

A palette colour's hex passes the library's own `#hex` guard, and every name
and role must be plain words; anything else raises `Logos::NavbarLogo::Error`
when the kit is loaded.

### Context is the hub theme

There are **no plates**: every logo on `/logos` and `/logos/:brand` sits on the
page's own background. The **Context** control (`logos/_context_form`, its
behaviour in `app/javascript/logo_gallery.js`) drives the hub's own theme, the
switch the moon icon uses (`$store.theme.toggle()`, which sets the root's `dark`
class and `localStorage` `theme`):

- **Light** and **Dark** set the hub theme. Both pages render each logo's light
  and dark versions and CSS on `html.dark` shows the one that matches
  (`LogosHelper#logo_themed_images`), so a change needs no request and the
  first paint already shows the right logos.
- **Watermark** sets the theme to dark and loads the page with
  `?context=watermark`, which shows the watermark logos. Choosing Light or Dark
  there, or turning the theme light with the moon icon, loads the page without it.
- **On load with no context param** the page leaves the theme as it is and shows
  that theme's logos; the control reads the theme and follows it if it changes.
  An explicit `?context=light`, `dark` or `watermark` sets the theme before the
  page is shown (the page's `data-logo-theme`, read by `logo_gallery.js`; a
  module runs after the first paint, so such a link can flash the old theme). Only `watermark` is carried in the page's
  links; light and dark are the hub's, which every page keeps.
- Downloads and Copy SVG give the version shown: each logo has a pair per tone,
  and the theme shows the matching pair.

### The brand page's tabs and controls

| Tab | Shows | Its own controls |
|-----|-------|------------------|
| Icon | the icon, once | none |
| Navbar Logo | the three text versions on one rule, and one sentence stating that rule | **Rule** (`?rule=3` or `4`; the page shows the rule of 4 unless asked) and **Show guides** |
| Stacked Logo | the three text versions in one form, and a short paragraph stating the 3-2-1 method and that form | **Form** (`?form=`: "Two lines" or "One line", the brand's own and the default, and "With tagline" (`tagline`) where the brand has one; a brand without one says so in one line) and **Show guides** |

- The tabs are links in a `nav` (`aria-label="Logo type"`); the current one
  carries `aria-current="page"`. The Rule control is a `role="group"` of two
  links; the current one carries `aria-current="true"`. All are `.btn` links.
  They, and Download and Copy SVG, have a focus ring fixed per hub theme,
  because the engine's own ring (`--color-cta` at 70%) is too faint on the
  light theme's white card. A chosen control carries a transparent border, so
  it is the same size as the others.
- The **Context** control is on every tab and on the index ([above](#context-is-the-hub-theme)).
  It is a GET form; its **Apply** button is inside a `<noscript>`, so it shows
  only with JavaScript off.
- **Every control keeps every other control's setting.** `type`, `context`,
  `rule`, `form` and `guides` are all read on every tab, and every link and the form
  are built from `LogosHelper#logo_page_params`, which leaves the defaults
  (Navbar Logo, the theme's logos, rule of 4, the brand's own form, guides off) out of the URL. So a rule picked
  on the Navbar tab is still picked after a visit to the Icon tab. The
  **Logos** breadcrumb back to the table keeps the watermark.
- **Guide drawings fit first, and scroll only below a readable size.** With
  guides on, a drawing scales to its frame like any logo, up to a height cap
  (`LogosHelper::LOGO_GUIDE_HEIGHTS`: 132 px for a Navbar Logo, 540 px for a
  Stacked Logo, whose ruler makes it wider). It also has a least width of its own,
  `LogosHelper#logo_guide_min_width`, computed from its viewBox: the width at
  which its labels are 9 px tall (`LOGO_GUIDE_LABEL_PX`). Below that width the
  drawing stops shrinking and its frame scrolls sideways inside itself. The
  widest least width is 954 px (Commercial Welding, with tagline), under the
  1028 px plate of a 1280 px page, so nothing scrolls there; on a phone every
  drawing does. The page body never scrolls sideways.
- **A guide frame is a tab stop only while it scrolls.** It is served with
  `tabindex="0"` and `data-scroll-tab-stop`; `app/javascript/scroll_tab_stop.js`
  removes the attribute when the drawing fits and restores it when it does
  not, and checks again when the theme swaps the drawing. With JavaScript off
  it stays a tab stop.
- Download and Copy SVG give the logo as shown, on every tab: in the watermark
  context, the watermark SVG, named `…-watermark.svg`.
- Every image's accessible name states its type, its text version (and rule)
  and its context (and a Stacked Logo's form): "McRitchie Industries stacked
  logo, with tagline, first word leads, dark".
- In the watermark context, the Navbar and Stacked tabs of a brand that leads
  by colour say its three text versions look the same. No version is hidden.
- The index table is a table from the `xl` breakpoint up, and a stack of
  labelled cells below it; its wrapper scrolls sideways if a row ever outgrows
  it. On a phone the cluster's right column wraps under the Stacked square.
- A brand whose name cannot be stacked keeps its row on the index: its Stacked
  tile reads "Not drawn." and the library's reason. Its own Stacked Logo
  tab answers 422 with the same reason.

- An unknown brand is a 404. Any other param the library or the parser refuses
  (an unknown `type`, `context`, `rule`, `form`, `text`, `tone`, `guides` or
  `download`, or a `form` the brand does not draw)
  is a 422 whose body is the reason in plain text.
- `Logos::Variant` (`lib/logos/variant.rb`) reads the params and gives each logo
  its type, its filename and its accessible name. `Variant.logo(brand, type)`
  builds the library object that draws a type.
- The watermark is shown on the hub's dark card (#3C3853); the default, white
  at 0.6, measures about 5:1 there, and `test/helpers/logos_helper_test.rb`
  holds every brand's watermark to 3:1.
- The logo routes have no `.svg` extension. An extension sets the request format,
  and the admin wall answers a non-HTML format with a bare 401 or 403.
- The Industries icon is drawn flat (two solid layers), without the marketing
  kit's steel gradient and tick marks. Turf Monster's head and Commercial
  Welding's helmet and lettering are auto-traced from pictures. Each brand's
  `note` says so on its page.

## The data

| File | Holds |
|------|-------|
| `config/logo_brands.yml` | Each brand's name, tagline, icon, highlight, weights or lettering, tracking, stacked form, note, fills, watermark, palette and typeface hierarchy. Add a brand here. |
| `lib/logos/data/brand_icons.json` | Studio's and Industries' icon layers: a path, a role (`primary`, `edge`) and a fill rule each. |
| `lib/logos/data/brand_icons_turf_welding.json` | The same format for `turf` (roles `outline`, `body`, `light`), `welding` (`primary`, `accent`) and `welding_mono` (`primary`). |
| `lib/logos/data/brand_icons_turf_mono.json` | `turf_mono` (`primary`, `evenodd`): the head's silhouette with the body cut out, which leaves the linework. The library reads the three icon files as one set. |
| `lib/logos/data/brand_lettering.json` | A brand's own lettering: per word, a list of letters (`d`, `adv`, `l`, `r`) in the glyph file's units, plus the word `space` and the `fill_rule`. |
| `lib/logos/data/montserrat_glyphs.json` | Letter outlines for weights 300 to 800, 95 ASCII glyphs each. Cap height is 1, the baseline is y = 0, y grows downward. Letters fill `nonzero`. |
| `lib/logos/data/extract_glyphs.py` | The script that made the glyph file. It needs Python with fonttools and brotli and the engine's Montserrat file; it runs by hand, never in CI. |

A brand that is not in the data, a rule other than 3 or 4, a name that is not
exactly two words, and a character with no glyph each raise
`Logos::NavbarLogo::Error` with the reason. A fill that is not a `#hex` colour
is refused too.

## What the data may contain

Paths, fill rules and transforms are written into the SVG as they stand, so
`Logos::NavbarLogo.new` checks every one its brand will draw (each tone's icon,
the watermark's included, and every letter) and raises `Logos::NavbarLogo::Error` before anything is
drawn:

| Value | Must be |
|-------|---------|
| a path `d` (icon layer, glyph, traced letter) | a string of SVG path characters only: the command letters `MLHVCSQTAZ` in either case, digits, space, comma, dot, minus, plus, and `e`/`E` for exponents |
| a `fill_rule` (icon layer, lettering) | `nonzero` or `evenodd` |
| an icon's `transform`, when present | `translate`, `scale`, `rotate` or `matrix` calls with numeric arguments, separated by single spaces |

The patterns are anchored at both ends (`\A…\z`), so a value that only starts
clean, or ends in a newline, is refused. New art comes in through these files,
so a new icon or lettering needs no code change, only data that passes.
