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
path layers) and a NAME (a first word and an ending: one word each, or, in a brand's own lettering, an ending of several words). `Logos::NavbarLogo`
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

## Original and Alt colourings

Every logo type has a **colouring** (task logo-original-and-alt; Alex,
2026-10-11: "when building the marketing kit we need the original"):

| Colouring | What it draws | From |
|-----------|---------------|------|
| **Original** | the brand's true art, as its kit draws it: its own icon, fills and name colours, per tone | the style's `original:` (`light`, `dark`) |
| **Alt** | one solid colour per part: today's logos, unchanged to the byte | the style's `tones` |

```ruby
logo.svg(rule: 3, tone: :dark, colouring: :original)   # Alt is the default
logo.icon_svg(colouring: :original)
logo.original?        # false for Studio
logo.colourings       # [:original, :alt], or [:alt]
```

- A brand whose logo is solid colour has **no original**: Studio. Asking for
  its Original raises `Logos::NavbarLogo::Error` (an SVG route answers 422);
  its pages show Alt, offer Original disabled, and say "McRitchie Studio's logo
  is solid colour, so it has no separate original."
- The **watermark** is always the single-colour version: colouring does not
  apply to it, and an Original asked of a watermark is the watermark.
- **Word edits apply in Original and Alt; the icon's colour in Alt only.**
  (Task logo-compare-and-original-edits, Alex 2026-10-11 23:06: to colour
  welding_v2's words he had to switch to Alt, which swapped the helmet for its
  single-colour version.) An Original's words take the picked colour and
  weight, and its icon stays the brand's art. An original ICON is the brand's
  own art, so the library refuses an icon colour with it and `Logos::Variant`
  drops one (still checked); the Edit panel's Icon row says so and links to the
  Icon tab in Alt (`?type=icon&colouring=alt`), whose Save as default makes the
  kit icon every logo draws. Not `?icon_colouring=alt`: a kit choice saves no
  icon colouring, so a Navbar or Stacked save would drop the Alt icon on reload.
- The guide drawings' ghost copies stay the brand's Alt text colour: a ghost is
  a solid ruler.
- Each SVG route takes `?colouring=original|alt` (Alt unless asked, so every
  existing URL serves what it served). An Original's file is named
  `-original` (`welding-navbar-rule3-first-dark-original.svg`) and its
  accessible label ends `original colouring`; an Alt file and label are as before.

The brands' originals:

| Brand | Original | Alt |
|-------|----------|-----|
| `studio` | none | the chest, one colour |
| `industries` | the kit's own `mcritchie_icon_light.svg` and `_dark.svg` (05_icon): steel gradient, flat edge, ruler ticks; the leading word in the kit wordmark's steel gradient, the other in gunmetal `#41464D` (light) or light steel `#D3D6DA` (dark), as the kit's horizontal logos set them | the set square flat, two solid layers |
| `turf` | the three-colour head trace; ink `#1A1535` and green on light, white and green on dark | the head's linework alone (`turf_mono`) in the brand green `#4BAF50` |
| `welding` | the kit's square logo (`COM - Square - Large.png`), traced: a blue silhouette, the opaque white right half and lens window over it, the orange spark; one icon for both tones, since the white fill holds the helmet on a dark page; the name in the kit's blue `#2D5E8E` with the orange `#D7602E` accent and tagline on light, and white with the orange on dark (the kit has no dark lettering) | the two-colour helmet on light, the single-colour one on dark |
| `welding_v2` | v1's Original with the v2 derivation ([below](#commercial-welding-v2)), its lens window cut clear (see-through, not white) | v2's helmet as before |

**Turf Monster's Alt changed on purpose.** Alt means one solid colour per part
for every brand; Turf's Alt was its three-colour head, which is now its
Original. Its brand pin and the digests that mix it were re-taken in their own
commit; no other brand's Alt moved by a byte (`test/lib/logos_brand_pins_test.rb`
pins every brand's Alt drawings and, separately, every Original).

### Gradients in an original

An original's fill may be `url(#<id>)`, but only when its own icon data
declares that gradient in `defs`: a list of
`{ id, units, x1, y1, x2, y2, stops: [{ offset, colour }] }`, a
`linearGradient` with a lower-case id, `units` of `userSpaceOnUse` or
`objectBoundingBox`, finite numeric coordinates, and two or more stops of a
`#hex` colour at an offset from 0 to 1. Anything else, or a url naming a
gradient the icon does not declare, is refused when the brand loads; every
other fill (and every Alt fill) stays `#hex`. The drawing declares the
gradients it uses in one `<defs>`, each id written as
`<icon key>-<8 hex of a digest of the drawing>-<id>`, so two logos on one page
never share an id and the same drawing is the same bytes every time. A
gradient for the name is in a letter's own units (cap top `y = -1`, baseline
`0`), since each letter is drawn scaled from its glyph. An icon layer may also
be stroked (`"paint": "stroke"`, with a `stroke_width` greater than 0): the
Industries kit's ruler ticks.

## The three rules

The icon is 300 design units tall and split into equal rows. The name is
centred on the icon in all three.

| Rule | Rows | Capitals | Where the name sits |
|------|------|----------|---------------------|
| Rule of 3 (`rule: 3`) | 3 | 1 row (a third of the icon) | the middle row |
| Rule of 4 (`rule: 4`) | 4 | 2 rows (half the icon) | the middle two rows |
| Rule of 6 (`rule: 6`) | 6 | 4 rows (two thirds of the icon) | the middle four rows, one row above and below |

- **The two gaps are equal.** The gap from the icon's box to the name's ink and
  the gap from the first word's ink to the second's are each half a cap height
  (`GAP_CAPS = 0.5`), on every rule. Until task navbar-spacing-and-rotated-guides
  the icon gap was half the first letter's ink (0.38 to 0.58 cap heights by
  brand) and the word gap was the font's space (0.367; Commercial Welding's
  lettering 0.351), which read tight between the words. Kerning is off.
- `tracking` in a brand's style adds space after every letter, in em (negative
  tightens). It is converted to cap heights with the glyph data's own
  `cap_height_em`. It never widens the word gap or the logo's right edge: a
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
- `colouring:` and `edits:` draw it in Original or Alt and with its colour
  edit (`{ icon: { colour: "#635BB2" } }`, Alt icon only); any other part's edit is
  refused.

### The icon is the atomic unit

Alex, 2026-10-11 19:23, on a /logos row whose Stacked Logo (saved in Alt)
showed the white single-colour helmet beside an Original Navbar and Icon:
"Lets make sure the icon is distributed across the other logos. In a way the
icon can act as an atomic unit that is used elsewhere." (Task
kit-icon-atomic-unit.)

So a brand's kit saves ONE icon (`icon_choice`: a colouring and the icon's
colour), and every Navbar and Stacked Logo draws that icon. Their own
colouring then governs the **words** (the name and the tagline) only.

- **The library.** `svg(..., colouring:, icon_colouring:)` on both logos draws
  the icon in `icon_colouring` and the words in `colouring`. Left out, the
  icon takes the words' colouring, which is every drawing exactly as before
  (the byte pins hold). The icon's colour edit follows the icon's colouring,
  the word edits apply to the words in either colouring. The layout follows the icon drawn
  (its width), and the gradients a drawing declares come from whichever part
  is Original (an Alt part is all `#hex`). The watermark is one colour, so it
  ignores both. A dark page draws the dark tone of each part's colouring.
- **The page.** On the Navbar and Stacked tabs the icon is, in order: the URL's
  icon params (`?icon_colouring=`, and `?icon_colour=` while the kit has an
  icon), for exploring; else the kit's icon; else the tab's own colouring and
  icon edit, as before. Under a kit icon the tab says "The icon is the kit's
  (…), so Colouring here sets the words", and the Edit panel's Icon row shows
  the kit icon and its colour with "Uses the kit icon. Change it on the Icon
  tab." When the URL explores another icon, the row is the picker again and
  the tab offers **Back to the kit icon**.
- **Saving.** The Icon tab has its own control row with **Save as default**,
  an Edit panel of the Icon row alone, and the Kit choice card (no text
  version), whose **Clear saved choice** clears the kit icon. A Navbar or
  Stacked choice saved while the kit has an icon stores no icon colour of its
  own; an older choice that carries one keeps working, and the kit icon wins
  when it is drawn.
- **The table.** Each /logos row draws one icon in its Icon, Navbar and Stacked
  tiles: the kit's icon, else the brand's icon in the page's colouring (its
  Original where it has one). So with no kit icon a saved Alt choice is drawn
  there with the brand's own icon, while its brand page and Kit card still
  draw it exactly as saved.

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
  brand's tracking and word gap, and the icon is 60% of its width tall. Turf
  Monster uses it: "Monster" is already 68% as wide as "Turf", so it cannot be
  tracked out under it.
- **Width over height** is 3n / (1.8n + 8) for two lines and 3n / (1.8n + 5) for
  one, where n is the big line's ink width in cap heights. Studio measures
  1.078 with the first word leading and 1.056 with the second; Industries 1.073
  and 1.056; Turf Monster 1.289 (1.285 before the word gap was half a cap).
- **A lettering brand** (Commercial Welding) stacks in two lines: its traced
  letters carry their own advances, so the small word can be tracked.
- **With tagline.** The name is set exactly as the one-line form sets it (both
  words, the word gap, the brand's tracking and lettering). The tagline is
  the small line: Montserrat 500 for every brand (Commercial Welding's own
  tagline lettering is not traced yet), tracked between its characters, a space
  being one, until its ink is exactly 60% of the name's; the icon is as tall as
  the tagline is wide. The three text versions and the tones apply to the name;
  the tagline takes the tone's `quiet` fill (`text` without one), and the
  watermark's one fill. Width over height is 3n / (1.8n + 8), n the name's ink
  width in cap heights: Studio 1.271 homogeneous, Industries 1.327, Commercial
  Welding v1 1.328 (1.287 before it took LLC, and v2's 1.287 now: the closed
  form does not depend on the icon) (`TAGLINE_RATIOS` in
  `test/lib/logos_stacked_logo_test.rb`).
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
  logo takes text, tone, form, guides and edits, not rule: it has no rule".

`guides: true` returns the construction drawing, on the method of the 3-2-1
reel: every measurement is proved with **ghost copies** of the small line (the
second word; the tagline; in the one-line form the whole name), each set
exactly as the logo sets it, tracking and word gap included. The layout keeps
that line once, at a cap of 1 (`line`, `line_width`), and both proofs copy it:

- **The ruler.** Right of the logo, one copy per unit at 1u, edge to edge, from
  the icon's foot to the logo's foot: 2 beside the first gap, 3 beside the big
  line, 2 beside the second gap, 1 beside the small line (the one-line form
  stops after the 3). Each copy is exactly as wide as the real small line (the
  one-line form's, a third of the name). The copies are numbered 1-2, 1-2-3,
  1-2, 1 between the logo and the ruler, so each band can be counted. Until
  task navbar-spacing-and-rotated-guides the copies were untracked, so each was
  narrower than the line it copied.
- **The icon's height.** ONE copy of the small line turned a quarter turn
  (`rotate(-90)`, in `<g class="guide-proof">`), reading from bottom to top, its
  baseline half a unit left of the icon's box (`PROOF_GAP`), its first letter's
  ink on the icon's foot and its last letter's ink on the icon's top. In the
  two-line and tagline forms it is the small line at its own 1u, so its length
  is the icon's height by construction, and the 3-2-1 rule shows. The one-line
  form has no small line, so its copy is the whole name at the size whose width
  is the icon's height (60% of the name, 1.8u). A magenta bracket beside it is
  ticked at the icon's top and foot. It stands on the background, never on the icon,
  so it reads whatever the icon is filled with (review of PR 2042: drawn over the
  icon it vanished, 1.02-1.32:1). Alex's item 4a replaced the column of letters
  spelled downwards that stood here before. A vertical line runs through the
  logo's centre, and a 1 marks the icon's top.
- **Lines** only at band boundaries, across the logo and the ruler.

The ghosts are the logo's own text colour (the watermark's fill in a
watermark), at `GHOST_OPACITY` (0.25 on light, 0.22 on dark and watermark),
inside one `<g class="guide-ghosts">`, every one of them on the background. They
measure 1.4:1 to 2.2:1 against the hub card the gallery shows them on (white in
the light theme, #3C3853 in the dark theme and the watermark context), and the
logo's text is more than twice that
(`test/helpers/logos_helper_test.rb`). The lines (1.0 design units) and the
numbers (32, 0.8u: the tracked ruler made Industries' tagline drawing need
1127 px at 28) are in the guide magenta, inside `<g class="guide-lines">`. Both
groups sit outside a watermark's translucent group, and the logo inside the
drawing is the plain logo to the byte. `examples` is not defined on a
Stacked Logo, and the rake task writes Navbar Logos only.

## The brands

| Brand | Icon | Name set in | Leads by | Tagline |
|-------|------|-------------|----------|---------|
| `studio` | traced chest, one layer | Montserrat 800 and 300 | weight | BUILD SMARTER |
| `industries` | kit set square, two layers, drawn flat in Alt; the kit's steel in the Original | Montserrat 700 and 300 | weight | BUILD BETTER |
| `turf` | traced head: three solid layers in the Original, its linework alone in Alt and as a watermark | Montserrat 800, tracking -0.025 em | colour | none |
| `welding` (Commercial Welding v1) | traced helmet: two colours on light, one on dark | its own traced lettering: COMMERCIAL WELDING LLC | colour | BUILDING STRONG CONNECTIONS |
| `welding_v2` (Commercial Welding v2) | v1's helmet, centred and with the lens moved down ([below](#commercial-welding-v2)) | v1's lettering: COMMERCIAL WELDING | colour | BUILDING STRONG CONNECTIONS |

A style's optional `title` is the brand's name in the gallery and in every
logo's accessible label ("Commercial Welding v1"), where the name's own words
would not tell two versions of a brand apart. Without one, the name's words are
put in reading case ("McRitchie Industries").

Three things a style may ask for beyond an icon and two Montserrat weights:

- **Its own lettering** (`lettering: welding`). The name's words are looked
  up whole in `brand_lettering.json` and drawn from the brand's traced letters.
  There is one weight, so the brand must use `highlight: colour`; the fill rule
  is the lettering's own (`evenodd`: a traced letter carries its counters as
  sub-paths). Its word gap is half a cap height like every brand's.
  `highlight: weight`, a `tracking`, or a word the lettering does not hold is
  refused.
- **An ending of several words** (lettering brands only). A name is two parts:
  its first word and its ending, everything after it. In Montserrat the ending
  is one word. In a brand's own lettering it may be several traced words:
  `COMMERCIAL WELDING LLC` is COMMERCIAL, then the ending WELDING LLC. The
  ending is one word to the logo (one colour when a word leads, the half-cap
  gap only before it, the small line of the two-line Stacked Logo), and inside
  it each pair of words is set the lettering's own `spaces["WELDING LLC"]`
  apart: the kit's space, ink to ink, in cap heights (0.4305, 39.61 px at the
  PNG's 92 px cap height). Tracked out (the two-line Stacked Logo's small
  line), that word gap takes the tracking twice on top of the kit's gap, so it
  stays plainly wider than the letter gaps: WELDING LLC, never WELDINGLLC. A
  pair with no space in the data is refused.
- **Tracking** (`tracking: -0.025`), above. Montserrat brands only.
- **An icon per tone** (`icon_key:` inside a tone). Commercial Welding's dark
  tone draws `welding_mono`, the helmet in one colour (half of it filled, half
  drawn in outline), because the two-colour helmet's white half is transparent. A tone that names none draws the brand's `icon`.
  The tone's icon sets that tone's geometry, so `layout` takes `tone:` too.

A style's optional `note` is the line its brand page shows about where the art
came from.

### Commercial Welding v2

Alex's item 5 (task welding-llc-and-v2-helmet): a second Commercial Welding
brand to compare his tweaks with the original, listed in the row after v1. Its
helmet (`welding_v2`, and `welding_v2_mono` on dark and as the watermark) is
derived from v1's traced helmet by `Logos::WeldingV2`
(`lib/logos/welding_v2.rb`); `bin/rails logos:welding_v2` writes it to
`lib/logos/data/brand_icons_welding_v2.json`, and a test fails if the file is
not exactly what the derivation writes. The steps, on each tone's own trace:

1. **Find the parts.** The outer helmet is the widest sub-path of any layer.
   The HALVES layer holds the white half (the taller) and the window (the
   other): on the Alt helmets it is the `primary` layer, the two as holes in
   it beside the outer helmet; on the Original it is the `white` layer, the
   two as opaque shapes over the blue silhouette (`blue`, the outer helmet).
   The orange spark is the `accent` layer; on the single-colour helmet it is
   cut into the window's own contour.
2. **Centre.** The midline is the white half's straight left edge, the line
   where the two halves meet: the mean x of its on-curve points within 2 units
   of the leftmost, away from its corners (x = 204.13 on the colour helmet,
   205.07 on the single-colour one). Every layer moves right so the midline
   is the box's centre. The box is widened on the short side, never cropped:
   426 to 443.75, shared by both tones (as v1's 426 is, so a logo's geometry
   is the same in every tone), each helmet centred on its own midline in it
   (right 17.75 and 16.80).
3. **Move the lens.** In the rule of 3 the icon is three rows, 161 of 483
   units each. The window is 145.8 tall, shorter than a row, so it cannot sit
   on both row lines; it is centred on the middle row instead: down 23.42
   (23.39 single-colour), leaving about 7.6 units of the row above and below
   it. The spark moves with it. The blue frame around the window is the notch
   the white half's contour makes around it; that contour's on-curve points
   within 40 units of the window (the band is 16 to 20 thick) move down with
   it, each curve's control points following their own end, so the band keeps
   its width and the rest of the white half stays put.
4. **Clear the lens** (task kit-export-and-clear-lens; Alex 2026-10-12: "remove
   the white of the lens so I can see it clear"). The window is always written
   as a hole in the outer helmet's layer (even-odd), so the page shows through
   it. The Alt helmets already held it so; the Original's trace drew it as an
   opaque white shape in its `white` layer, so there it moves into the blue
   silhouette (`WeldingV2#clear_lens`). The white right half stays opaque (it
   holds the helmet on a dark page); the frame, the spark and the outer edge do
   not change. v1's Original keeps its white window. The parser reads the
   cleared helmet back the same way (the window may be the outer layer's
   second sub-path), so the derivation's measures still hold on v2's data.

**v2's Original** (`welding_v2_original`) is the same derivation run on v1's
Original (`welding_original`), in its own box: the trace is at about twice
the scale (975 tall), so the measures above (2, 20 and 40 units) are taken at
its scale (`WeldingV2#scaled`; v1's own numbers are unchanged). Its midline is
x = 411.85, its box 858 widened to 892.30 (right 34.30), its lens down 47.42,
and its window cut clear (step 4): its `blue` layer is the silhouette with the
window as a hole, its `white` layer the white half alone. Only welding_v2's
Original pin moved for it (`test/lib/logos_brand_pins_test.rb`).

`test/lib/logos_welding_v2_test.rb` measures each step again on the shipped
data, for all three helmets: the midline at the box's centre, the ears inside the box, the lens's
shape unchanged and centred on the middle row, the spark and frame moved with
it and nothing else moved down. Its logos are v1's in every other respect
(palette, tagline, lettering, tones), with the name COMMERCIAL WELDING.

## Pure vector

A logo is `<svg>`, `<g>` and `<path>` only: no live text, no picture, no font,
no external reference. Its viewBox is its own box, `0 0 <width> 300`.

`guides: true` returns a separate construction drawing: the row edges, the
icon's right edge, the name's left ink edge, the row numbers, and ghost copies
of the name one row tall in every row, as the rule-of-thirds reel draws them.
Rule of 3: a copy above and below the real name make three. Rule of 4: four
copies, two of them behind the two-row name. Rule of 6: six copies, four of them
behind the four-row name. Above the drawing, a bracket labelled ½ spans each of
the two equal gaps (after the icon, between the words), so the reader sees they
match. The ghosts are the logo's text colour, faint, in `<g class="guide-ghosts">`
BEHIND the logo; the lines (1.0) and numbers (30; 40 on the rule of 6, whose
drawing is the widest, so it still fits the 1028 px frame at 9 px labels) are in
`<g class="guide-lines">`. That drawing does use
`<line>` and `<text>`, so it is for looking at, never for shipping. The
combined pins cover logos WITHOUT guides (SHA-256 tests in
`test/lib/logos_navbar_logo_test.rb` and `test/lib/logos_stacked_logo_test.rb`);
`test/lib/logos_brand_pins_test.rb` pins each brand on its own, over everything
it draws, guides and icons included, so a change by design to one brand shows
which brand moved and that no other did.

## The rake task

```bash
bin/rails 'logos:navbar[industries]'            # writes tmp/logos/industries/*.svg, prints each path
bin/rails 'logos:navbar[studio,/some/dir]'      # or into a directory you name
```

It writes 36 files per brand, named
`<brand>-rule<3|4|6>-<homogeneous|first|second>-<light|dark>[-guides].svg`.

## The gallery

An admin gallery (`LogosController`) shows the library's output. Its one store
is each brand's **kit record** ([below](#the-kit-record)): the Navbar and
Stacked Logo the brand uses, and its original artwork. It is linked from the
admin sidebar as **Logos**.

| Route | Shows |
|-------|-------|
| `/logos` | One row per brand in `config/logo_brands.yml`. Its **Logos** cell is one tight cluster (`logos/_cluster`): the **Stacked** Logo as a square on the left, the **Navbar** Logo beside it (each the brand's saved kit choice, its badge marked **Saved**, else its default: the Stacked Logo in its own form with the first word leading, the Navbar Logo on the rule of 4 with the second word leading), and the **Icon** as a small square under the Navbar Logo (all three drawing the row's one icon: the kit's, else the brand's own), each a tile with a badge naming its type and linking to its tab of the brand page; under it a **Download** of the Navbar and the Stacked Logo as shown. The brand cell says when its kit was saved. Then its **Typeface** hierarchy and its **Colours** (below). |
| `/logos/compare` | **Two brands' kits side by side** ([below](#comparing-two-kits)): `?left=` and `?right=` (Commercial Welding v1 and v2 unless asked), `?type=`, and the shared `?rule=`, `?form=`, `?colouring=`, `?context=` and `?grid=1`. |
| `/logos/:brand` | The brand's page, **tabbed by logo type**: `?type=icon`, `navbar` (the default) or `stacked`. Each tab shows that type's logos once, with **Download** and **Copy SVG**. Under the tabs: the edit panel and **Kit choice** (on the Icon tab, the icon's colour and the kit icon), the **Kit** and **Kit originals** cards, then the brand's **Colours** and **Typefaces**. |
| `/logos/:brand/icon` | The icon as `image/svg+xml`. Params: `tone`, `colouring` (`original`, `alt`), `icon_colour`. Named `<brand>-icon-<tone>[-original].svg`. |
| `/logos/:brand/navbar` | One Navbar Logo. Params: `rule` (`3`, `4`, `6`), `text` (`homogeneous`, `first`, `second`), `tone` (`light`, `dark`, `watermark`), `guides` (`0`, `1`). Named `<brand>-navbar-rule<3|4|6>-<text>-<tone>[-guides].svg`. |
| `/logos/:brand/stacked` | One Stacked Logo. Params: `form` (`two_line`, `one_line`, `tagline`: only those the brand draws; absent is its own), `text`, `tone`, `guides`. Named `<brand>-stacked-<two-line|one-line|tagline>-<text>-<tone>[-guides].svg`. |

On the three SVG routes a param the type does not take is not read, and
`download=1` sends the file as an attachment. The type is the route's own: a
`?type=` in the query string cannot change it.

**The kit is the default** (task kit-export-and-clear-lens). Asked with no
CHOICE param (only `tone` and `download`), a brand with a saved kit (an Icon,
Navbar or Stacked choice) answers with its kit's logo of that type in that
tone, exactly as the Kit card and the [kit export](#the-kit-export) draw it
(`BrandKit#variant`: the saved choice with the kit icon, or the brand's default
for a type nothing is saved for). Any choice param (`rule`, `form`, `text`,
`colouring`, `icon_colouring`, `guides` or an edit param;
`LogosController::KIT_OVERRIDES`) means the caller says what it wants, and an
absent one then takes the library's default (so `/navbar?rule=4` is the rule
of 4, homogeneous, Alt). A brand with nothing saved, or a kit its data can no
longer draw, answers byte for byte as before (`/navbar` alone is the rule of 3).
The `X-Logo-Source` header says which: `kit` or `params`. Because of this the
gallery's own icon URLs always name their colouring, Alt included
(`Logos::Variant#params`), so a gallery picture is never read as the kit.

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
  An explicit `?context=light`, `dark` or `watermark` is in that theme from the
  first paint: the page sets `content_for :html_theme`, the hub layout renders it
  on `<html>` (`data-theme-context`, and `class="dark"` for dark), and
  `app/javascript/theme_context.js`, a classic script in the head after the
  engine's pre-paint script, stores the theme (localStorage `theme`) and settles
  the class before anything paints. A Turbo visit is synced by `logo_gallery.js`
  (`data-logo-theme`). Only `watermark` is carried in the page's links; light and
  dark are the hub's, which every page keeps.
- Downloads and Copy SVG give the version shown: each logo has a pair per tone,
  and the theme shows the matching pair. **Copy SVG** carries only its logo's URL
  (`data-copy-svg`, the Download's without `download=1`) and fetches the SVG on
  click (`logo_gallery.js`), so the page carries no SVG of its own (`/logos/turf`
  went from about 1.5 MB to about 0.26 MB). The clipboard write starts inside the
  click with a promise of the text (`ClipboardItem`), as Safari requires, and falls
  back to fetch-then-`writeText`; the button says Copied or Copy failed.

### The Colouring control

Beside Context on `/logos` and on a brand page, **Colouring: Original | Alt**
(`logos/_colouring_control`, plain links) switches every logo on the page, its
downloads and its copies. A brand page opens on the brand's Original where it
has one (or its saved kit choice's colouring); the table shows each brand's
Original where it has one (a saved choice in its own colouring) unless
`?colouring=alt` asks for Alt. The page's `?colouring=` is kept across every
other control, the breadcrumb and the brand links, and even on Studio's pages,
so it comes back on the next brand. The Context notes say what each colouring
is, and that a watermark has none.

### The brand page's tabs and controls

| Tab | Shows | Its own controls |
|-----|-------|------------------|
| Icon | the icon, once | none |
| Navbar Logo | the three text versions on one rule, and one sentence stating that rule | **Rule** (`?rule=3`, `4` or `6`; the page shows the rule of 4 unless asked) and **Show guides** |
| Stacked Logo | the three text versions in one form, and a short paragraph stating the 3-2-1 method and that form | **Form** (`?form=`: "Two lines" or "One line", the brand's own and the default, and "With tagline" (`tagline`) where the brand has one; a brand without one says so in one line) and **Show guides** |

- The tabs are links in a `nav` (`aria-label="Logo type"`); the current one
  carries `aria-current="page"`. The Rule control is a `role="group"` of three
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
  widest least width is 993 px (McRitchie Industries, with tagline), under the
  1028 px frame of a 1280 px page, so nothing scrolls there; on a phone every
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
  `download`, a `form` the brand does not draw, or an edit param it refuses)
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

### Editing a logo's parts

Alex's item 4b (task logo-part-editor): the rules give the sizes, spacing and
shapes; the operator picks the colours and weights. The Navbar Logo and
Stacked Logo tabs draw ONE **Edit** panel (`logos/_edit_panel`), with the same
rows in the same order on both, in Original and in Alt; **Edit parts** in the
controls row jumps to it (`#edit`), since on the Navbar tab it sits under three
full-width logos. One row per part:

| Part | Row shows | Colour | Weight | Visible |
|------|-----------|--------|--------|---------|
| Icon | — | yes: the icon's `primary` layer, or its first layer when it has none (Turf Monster's outline); every other layer keeps its styled fill, and the row says which | — | — |
| First word | the brand's first word (McRITCHIE, Turf, COMMERCIAL) | yes, in every text version | 300 to 800; disabled, with a one-line reason, for traced lettering | — |
| Ending | the brand's ending (STUDIO, INDUSTRIES, Monster, WELDING …) | yes, in every text version | as the first word | — |
| Tagline | the tagline (Stacked tab, tagline form only) | yes | 300 to 800 (Montserrat, so traced brands too) | Shown or Hidden |

The rules:

- **A colour is one of the brand's palette hexes** (`palette:` in
  `config/logo_brands.yml`), matched in any case and drawn in the palette's
  spelling. Anything else is refused.
- **A weight is one of `NavbarLogo::EDIT_WEIGHTS`** (300, 400, 500, 600, 700,
  800). A brand set in its own traced lettering has one weight, so its words
  refuse a weight; its tagline, set in Montserrat, takes one.
- **Geometry never moves**, except that a heavier word is wider: the layout
  reflows by the same rules (the gaps stay half a cap height; a stacked icon is
  still 60% of the name's width). A heavier tagline is still tracked out to
  60%, so it is as wide as before. **A hidden tagline** leaves every band where
  it was and is simply not drawn: the logo keeps its 3-2-1 box. A weight that
  cannot be drawn in the current rule or form is offered disabled, and a URL
  that asks for one shows the logos as styled with the reason.
- **Every logo on the tab changes at once**: the three text versions, in both
  tones, with their downloads and copies. An edited file is named
  `…-custom.svg` and its accessible name ends ", edited".
- **Watermark**: a watermark is one colour by definition, so edits do not apply
  there; the panel says so, and the edits stay in the URL for Light and Dark.
  The Icon tab takes no edits.
- **Contrast**: the operator may pick a colour that disappears on the current
  theme. Under 3:1 against the page's background, the row shows a one-line
  warning, measured again when the hub theme turns.
- **No edits draws exactly what it drew before**, byte for byte (the per-brand
  pins).

The edits live in the URL, one param per setting
(`Logos::Variant::EDIT_PARAMS`): `icon_colour`, `first_colour`, `first_weight`,
`ending_colour`, `ending_weight`, `tagline_colour`, `tagline_weight` and
`tagline_visible=0`. A colour is its hex without the `#`
(`?first_colour=635BB2`). Every other control carries them
(`logo_page_params`); **Reset** drops only them. The SVG endpoints take the
same params, so a download is the logo as shown. A bad value is a 422 naming
it. The panel is a GET form; `app/javascript/logo_editor.js` submits it on a
change, leaves blank fields out of the URL, keeps the scroll, and measures the
contrast; with JavaScript off it has an **Apply** button.

In the library, `NavbarLogo#svg` and `StackedLogo#svg` (and `#layout`) take
`edits:`, a map such as `{ first: { colour: "#635BB2", weight: 600 },
tagline: { visible: false } }`, checked by `#checked_edits`;
`#refusal(edits, rule:)` or `(edits, form:)` says why a set cannot be drawn.

To keep an edited logo as the brand's own, save it as the **kit choice**
([below](#the-kit-record)).

### Comparing two kits

Alex, 2026-10-11 23:06: "a new button/drop down for comparing two marketing
kits. That way I can compare the marketing kits for Commercial Welding V1 vs
V2. I also want a grid to be showable." (Task logo-compare-and-original-edits.)

**Compare kits** on `/logos` opens `/logos/compare?left=welding&right=welding_v2`;
**Compare** on a brand page opens that brand on the left and its other version
(`welding` and `welding_v2` are one family: the key less `_vN`), else the next
brand, on the right, on the tab's type (`LogoComparison.partner`).

- **Two dropdowns** pick any two brands (a plain GET form with a **Compare**
  button; **Swap sides** trades them). An unknown brand is a 404, an unknown
  control a plain-text 422.
- **Each side draws its brand's kit default** for the type: its saved choice
  (rule or form, text version, colouring, edits) and the kit's icon, exactly as
  its brand page opens on them, else the brand's style (`LogoComparison`). Above
  it: the brand's name (linking to its tab), its kit status, and a line saying
  "Kit default: …" or "Brand style (no … saved): …".
- **The shared controls** change both sides at once: Context, Colouring, the
  type tabs, and the Rule (Navbar) or Form (Stacked; every form either side
  draws). Each offers **Kit default**, which drops the param so each side goes
  back to its own. A side that cannot take a control (a form its name does not
  draw, an Original for Studio) keeps its own and says so; saved word edits the
  page's rule cannot draw are left out with the reason.
- **One scale.** Each Navbar or Stacked drawing is drawn at a width that is its
  share of the wider drawing's (`LogoComparison#widths`), in frames of equal
  width, feet aligned, so sizes compare directly. Icons share no unit, so each
  fits its frame.
- **Show grid** (`?grid=1`, Navbar and Stacked) swaps both sides for their
  construction guide drawings, the brand pages' Show guides. Every Navbar guide
  drawing is 410 design units tall, so at one scale the two are one height and
  their rows line up; a Stacked pair shares its units and its foot, so the name
  and tagline bands line up and the icons differ above them.
- Side by side from the `md` breakpoint (a subgrid keeps the two drawings on
  one line whatever each heading says); one above the other on a phone.
  Each side has its own **Download** and **Copy SVG**. Admin only.

## The kit record

`BrandKit` (`app/models/brand_kit.rb`, table `brand_kits`; task
brand-kit-record) is what the operator has SAVED for a brand: one row per
brand of `config/logo_brands.yml`, created on its first save (no seed rows).
It is not `Logos::BrandKit`, which reads the palette and typefaces from the
YAML and stores nothing; those stay in the YAML for now.

| Column | Holds |
|--------|-------|
| `brand` | the style key (`studio`, `welding_v2`), unique |
| `icon_choice` | `{"colouring" => "original", "edits" => {}}` or `{"colouring" => "alt", "edits" => {"icon_colour" => "D7602E"}}`: the icon every logo draws ([the atomic unit](#the-icon-is-the-atomic-unit)), or null |
| `navbar_choice` | `{"rule" => 4, "text" => "second", "colouring" => "alt", "edits" => {"first_colour" => "635BB2"}}`, or null for the default |
| `stacked_choice` | `{"form" => "tagline", "text" => "first", "colouring" => "original", "edits" => {}}`, or null |
| `notes` | the operator's own words on the kit |
| `updated_by` | the admin who changed it last (email) |
| `originals` | Active Storage attachments: the original artwork |

A choice's `colouring` is optional: one saved before colourings has none and
is read as `alt`, what it showed then (no migration). Under a kit icon, a
Navbar or Stacked choice's `colouring` is its words'.

**A choice is the page's own params.** Its `edits` are the edit panel's URL
params (`Logos::Variant::EDIT_PARAMS`), and both saving and drawing read a
choice through `Logos::Variant.parse` and the logo's `#refusal`, so a saved
choice can never hold what the page could not draw. A choice is stored in one
spelling (`BrandKit.choice_of`): a hex in capitals, a weight and a visibility
as strings, and only the edits the type shows (a Navbar Logo drops the
tagline's; a Stacked Logo keeps them only in the tagline form). It is stored in
the flat URL spelling because a jsonb column hands back STRING keys while
`#checked_edits` takes symbols: reading goes through `Logos::Variant.edits`
first. If the brand's data later changes so a saved EDIT cannot be drawn (a
palette colour taken out), loading drops that edit (`BrandKit#stale_edits`),
draws the rest, and the brand page names what was left out; the table and
page never 422 for it, and only a choice being written is checked strictly,
so a stale one never refuses another save. A choice whose rule, form or text
is itself refused is shown as the refusal in its cell and on the Kit card;
save again or clear it.

**The saved choice is the tab's default** (task logo-original-and-alt, item 9;
Alex: "The goal of the logo modification is to set the defaults"). A Navbar or
Stacked tab whose type the kit has saved opens on it: its rule or form, its
colouring, its edits, and its text version marked **Kit default**
(`BrandKit#page_defaults`, read by `LogoBrandPage`). URL params override it one
by one for exploring; the edits override as one set (any edit param replaces
the saved edits). Under the controls the tab says **Showing the kit default**,
or **Changed from the kit default · Back to kit default** (the bare tab), or,
with nothing saved, that it shows the brand's style. Links leave out a rule,
form or edits equal to the page's default, so each tab reads its own saved
choice. The Edit panel's **Reset** goes back to the kit default's edits, and to
the brand's style only when none is saved; **Clear saved choice** goes all the
way back.

**Saving.** On the Icon, Navbar and Stacked tabs, **Save as default** in the tab's
control row saves the tab as shown (rule or form, colouring, edits) with the
kit's current text version, and lands on the bare tab, which opens on it. The
**Kit choice** card below saves the same with the text version picked in its
select (it starts on the saved one, else the default: second word leads for
the Navbar Logo, first for the Stacked), and lands on the bare tab at the card,
with a line saying what was saved. **Clear saved choice** puts the brand back on its default.
The brand page's header says `Kit: saved <date> by <who>` (the saver's user
name, else their email's local part; the title adds the email) while an Icon,
Navbar or Stacked choice is saved, and `Kit: not saved yet` otherwise, notes and
originals included; ` · originals: N` follows when the kit holds any. The /logos
table shows the same status cut to one line. Clear lands on the tab at the Kit
choice card (`#kit-choice`). Its **Kit** card shows the three choices (Icon, Navbar, Stacked) in the page's tone, each with
**Open on its tab** and **Download**, and the kit's notes; its **Download kit** button gives them all as files
([the kit export](#the-kit-export)).

**Originals.** The **Kit originals** card ("The originals the logos were
derived from.") uploads one or more files, lists each with its name, type,
size and upload date, shows an SVG, PNG or JPEG as a picture, and has a
**Download** and a **Delete** for each. Delete takes two steps with no script:
it opens a disclosure (`<details>`) asking "Delete <file> from the kit?", whose
own **Delete <file>** button removes it, and the same control reads Cancel to
close it. A file must be an SVG, PNG, JPEG, PDF
or ZIP, read from its BYTES (Marcel), never its name, and at most 25 MB; one
bad file refuses the whole upload. They are stored by Active Storage on the
hub's service (R2: `amazon` in production, `amazon_dev` on desks), and
served only through the admin wall (`BrandKitsController#original`), never by
an Active Storage URL, with a `sandbox` CSP and `nosniff`, so a script in an
SVG never runs on the hub's origin. Only pictures are served inline; a
download is an attachment. A deleted original is purged to the bucket's trash
(StudioTrashS3, three days).

| Route (`BrandKitsController`, admin only) | Does |
|------|------|
| `PATCH /logos/:brand/kit/choice` | saves `type` (`icon`, `navbar`, `stacked`) with `rule` or `form`, `text`, `colouring` and the edit params (an icon keeps `icon_colour` alone) |
| `DELETE /logos/:brand/kit/choice` | clears `type`'s choice |
| `PATCH /logos/:brand/kit` | saves `notes` |
| `POST /logos/:brand/kit/originals` | uploads `originals[]` |
| `GET /logos/:brand/kit/originals/:id` | one original (`download=1` for an attachment) |
| `DELETE /logos/:brand/kit/originals/:id` | removes one |

Every write is a CSRF-protected form post and lands back on the brand page
with the page's settings; a refused choice or note is a plain-text 422 naming
what was refused, and a refused upload draws the brand page again (422, on the
tab and context the form carried; `LogoBrandPage`) with the reason in the Kit
originals card. A failed write is logged against the kit (`rescue_and_log`;
a kit not yet saved is not named, since the log would save it); an unknown brand or original is a 404. A visitor is sent to log in
and a non-admin is turned away by the admin wall, writes and reads alike.

## The kit export

Task kit-export-and-clear-lens (Alex 2026-10-12 00:55: his Commercial Welding
site drew an old navbar, not the one his kit saves). `BrandKitExport`
(`app/models/brand_kit_export.rb`) gives a kit as files. Each is what the Kit
card shows: the saved Icon, Navbar Logo and Stacked Logo, each drawing the kit
icon, or the brand's default for a type nothing is saved for.

| Route (`LogosController`, admin only) | Gives |
|------|------|
| `GET /logos/:brand/kit.zip` | `<brand>-kit.zip`: a `<brand>-kit/` folder holding `README.md` and the nine files below. The **Download kit** button on every brand page tab's Kit card links here. |
| `GET /logos/:brand/kit/<type>-<tone>.svg` | One file, always the CURRENT kit choice: `icon-light.svg`, `icon-dark.svg`, `icon-watermark.svg`, `navbar-light.svg`, `navbar-dark.svg`, `navbar-watermark.svg`, `stacked-light.svg`, `stacked-dark.svg`, `stacked-watermark.svg`. Inline, or `download=1` for an attachment named `<brand>-<file>`. Any other name is a 404. |

`light` is for a light background, `dark` for a dark one, `watermark` is one
colour, slightly transparent. The README lists each file (saved or default,
and its accessible name), the palette, the typefaces, who saved the kit and
when (UTC), and the stable URLs at the host it was downloaded from. A logo the
brand cannot draw is left out of the zip and named in the README as not
drawn; a single file the brand cannot draw is a 422 with the reason.

With no params, the plain routes agree with the kit files once a kit is saved:
`/logos/welding_v2/navbar?tone=dark` and `/logos/welding_v2/kit/navbar-dark.svg`
are the same bytes.

### How an app takes its logo from the kit

1. **Save the kit** on the hub: on `/logos/<brand>`, save the Icon, Navbar and
   Stacked choices (Save as default, or the Kit choice card). The Kit card
   shows what the app will get.
2. **Take the files.** Either a person clicks **Download kit** and commits
   the SVGs into the app (for example under `public/brand/`, named as they
   come: `navbar-light.svg`, `navbar-dark.svg`, `icon-light.svg`, …), or the
   app's build fetches the stable URLs. Use the files as they are; never
   hand-edit a copy (that is how a site ends up showing an old navbar).
3. **Pick the tone by the background**: `navbar-dark.svg` on a dark navbar,
   `navbar-light.svg` on a light one; the icon files for a favicon or avatar,
   the stacked ones for a hero or a footer.
4. **When the kit changes**, download or fetch again. The URLs never change;
   their content follows the saved kit.

**Access.** Every route is behind the admin wall, like the rest of `/logos`;
it is not public (opening it to the world is Alex's call). A build fetch needs
an admin's signed-in hub session cookie (sign in with a magic link, keep the
cookie jar, then `curl -sS -b <jar> -o kit.zip -w '%{http_code} %{content_type}' https://mcritchie.studio/logos/<brand>/kit.zip`).
Without one the hub answers with a 302 to sign-in, not the file, and `curl -f`
does not fail on a 302, so a fetch must check for `200` and `image/svg+xml` or
`application/zip` itself (do not follow redirects). There is no API-token door
yet.

## The data

| File | Holds |
|------|-------|
| `config/logo_brands.yml` | Each brand's name, tagline, icon, highlight, weights or lettering, tracking, stacked form, note, fills, watermark, palette and typeface hierarchy. Add a brand here. |
| `lib/logos/data/brand_icons.json` | Studio's and Industries' icon layers: a path, a role (`primary`, `edge`) and a fill rule each. |
| `lib/logos/data/brand_icons_turf_welding.json` | The same format for `turf` (roles `outline`, `body`, `light`), `welding` (`primary`, `accent`) and `welding_mono` (`primary`). |
| `lib/logos/data/brand_icons_turf_mono.json` | `turf_mono` (`primary`, `evenodd`): the head's silhouette with the body cut out, which leaves the linework. |
| `lib/logos/data/brand_icons_originals.json` | The originals' own icons: `welding_original` (`blue`, `white`, `accent`; traced from the kit's square PNG by potrace in a scratch Python outside the repo, never in CI) and `industries_original_light` / `_dark` (`primary` with the `steel` gradient, `edge`, and the stroked `ticks`; the kit's SVG paths unchanged, with `defs`). |
| `lib/logos/data/brand_icons_welding_v2.json` | `welding_v2`, `welding_v2_mono` and `welding_v2_original`, written by `bin/rails logos:welding_v2` ([above](#commercial-welding-v2)); edit the derivation, never the file. The library reads the five icon files as one set. |
| `lib/logos/data/brand_lettering.json` | A brand's own lettering: per word, a list of letters (`d`, `adv`, `l`, `r`) in the glyph file's units, plus the `fill_rule` and `spaces`, the kit's space between two words as it sets them (`"WELDING LLC"`: 0.4305 cap heights, ink to ink), which an ending of several words uses. `"COMMERCIAL WELDING"` is kept for the record; the equal-gap rule sets the first word's gap. Commercial Welding's words (COMMERCIAL, WELDING, LLC) are traced from the kit's text-only PNG by the prototype's potrace method (`traced_words`), which reproduces COMMERCIAL and WELDING byte for byte; it runs by hand, never in CI. |
| `lib/logos/data/montserrat_glyphs.json` | Letter outlines for weights 300 to 800, 95 ASCII glyphs each. Cap height is 1, the baseline is y = 0, y grows downward. Letters fill `nonzero`. |
| `lib/logos/data/extract_glyphs.py` | The script that made the glyph file. It needs Python with fonttools and brotli and the engine's Montserrat file; it runs by hand, never in CI. |

A brand that is not in the data, a rule other than 3, 4 or 6, a name that is not
exactly two words (in Montserrat; a lettering brand's is two or more), and a
character with no glyph each raise
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
| an icon's `defs`, when present | linear gradients only, as [above](#gradients-in-an-original) |
| an icon layer's `paint`, when present | `fill` or `stroke`; a stroked layer needs a `stroke_width` greater than 0, a filled one takes none |
| an original's tone | a map of `icon_key`, `text`, `quiet`, `accent` and `icon`, with a `text`, an `icon` filling every layer of its icon, and an `accent` when a word leads by colour; every fill a `#hex` or a declared gradient |

The patterns are anchored at both ends (`\A…\z`), so a value that only starts
clean, or ends in a newline, is refused. New art comes in through these files,
so a new icon or lettering needs no code change, only data that passes.
