# Game Character Models
<!-- registry: a starting QB as he looked in one game, plus the iced twin -->

**What it makes.** For each main character of a game (today: the two starting
quarterbacks), one character sheet of him **as he looked in that game**: the
uniform, number, patches, hair and facial hair of that day. It also makes the
sheet of his iced twin: the same look with shades and the iced-out jewelry set.
Each sheet is a 5x2 grid: two full bodies on the left (front bare-headed, back in
the helmet) and six head panels on the right (front, three-quarter, profile, look
up, smile, rear). The iced twin swaps look up and smile for the rings shot and the
grill shot.

**Why this way.** It was proven by hand on Bo Nix, Sam Darnold and Caleb Williams
(2026-10-18), and the operator approved each one:

- A sheet built from the ESPN headshot looks like the headshot in every video.
- A sheet generated in one call put the grid out of order 14 times in 14.

So the sheet is built **in layers**, from the player's own bare-head photographs,
and stitched locally.

**Where it runs.** On the operator's Mac. The face gate (ArcFace) runs locally by
his ruling, and the face detector is Apple Vision. Production only files the
result. The tool is `bin/game-model` in the hub (`bin/game-model --help`).

## Rules that do not bend

1. **Sources.** Use team and league media only: the club sites,
   `static.clubs.nfl.com`, nfl.com, and the ESPN headshot as a verifier. The
   harvester refuses everything else. Wire and agency photographs (Getty, AP,
   Reuters, USA Today/Imagn) are out (the operator's option B, 2026-10-17).
   Reference photos are never published.
2. **Face references are bare-head, 10 or more, and never the standard head-on
   bust.** The headshot only verifies identity; it is never a reference.
3. **Identity is the face score, not a vision model.** gpt-5 once called the
   wrong man Darnold, and ArcFace caught it at 0.02. gpt-5 labels headwear only.
4. **Pinned models**:
   - Image: `gpt-image-2.5-sunburst-2026-09-08` on `/v1/images/edits`.
   - Classifier: `gpt-5-2025-08-07`.

   The app's default image model scored 0.44 on likeness; the pinned snapshot
   scored 0.73–0.76.
5. **Look at every panel yourself before you file.** The gate is a floor (0.70).
   It does not rank close renders and cannot see a uniform. Reject your own bad
   output, and never report a sheet as built while listing its defects.
6. **Confirm the starter played**: the frames must show his number at
   quarterback. In Week 5 the Bears' QB was #17, not Caleb.

## Steps

Use one workdir per player and game, for example
`~/game-models/2026-wk6/chi-caleb-williams`. Every paid step skips outputs
already on disk, so a re-run resumes instead of buying the images again.

### 0. Once per machine

```bash
bin/game-model setup        # Swift face detector + ArcFace venv in ~/.game-model
```

### 1. The starters

Find the starters in the ESPN box score of each game: the passer with the most
attempts, checked against the frames in step 3. Write `spec.yml` with just
`name:` and `espn_id:`.

### 2. Harvest, find his face, keep the bare-head ones

```bash
bin/game-model harvest <dir> www.chicagobears.com --since 2026-08-01
bin/game-model faces <dir>
bin/game-model identify <dir>     # ArcFace vs the headshot; >= 0.35 is him
bin/game-model headwear <dir>     # labels headwear on the matches; writes bare.jpg
```

Captions are not trusted: some clubs caption every photo with one generic line.
Open `bare.jpg` and choose 10 or more face references.

- **Take them from the game's own weeks.** Facial hair changes across a season:
  Caleb had a full beard in June, a mustache only by Week 1, and a full beard
  again in Week 6.
- **Drop** wet hair, extreme expressions, blur, and posed head-on busts.

### 3. Find him in the game, and read the uniform

```bash
bin/game-model find <dir> 'week-6'      # his face in this game's frames, helmet or not
```

Open `find.jpg` and confirm his number. Then write the rest of `spec.yml` from
the frames:

| Key | What it holds |
|---|---|
| `descriptor` | The uniform and game, e.g. `Bears white · 2026 Week 6 at ATL`. The look is filed under this name. |
| `number` | His jersey number. |
| `uniform` | The generic uniform text: helmet (shell, facemask, stripe, logo), jersey (colour, collar, sleeve stripes), pants (colour, side stripe), socks, cleats, and wristbands. Describe the palette from the photos; never name a throwback. |
| `specifics_front` / `specifics_back` | Number style, nameplate, captain patch (count the stars), sleeve initials, towel, hand-warmer, wraps, painted nails. |
| `jersey_panel` / `back_panel` | The jersey as the head panels show it, front and back. |
| `hair` / `facial_hair` | Exactly as that week: length, curl, fade, line-up; mustache, goatee, beard. Spell out length; the default comes out too tall. |
| `build` | His height and weight. |
| `face_refs` | The bare-head crops from step 2. |
| `uniform_refs` | 4–6 game frames that show the whole uniform. |
| `build_refs` | 3–5 full-length photos of him in any outfit. Proportions come from photos, not adjectives: "lean" thinned his shoulders until his arms read long. |
| `game_refs` | 2–3 frames for the specifics. The last one should be a close-up of the jersey over the pads. |

### 4. Build the layers (paid), looking after each

```bash
bin/game-model generate <dir> facepack --attempts 1 && bin/game-model score <dir> facepack && bin/game-model board <dir> facepack
bin/game-model generate <dir> body      && bin/game-model board <dir> body
bin/game-model generate <dir> full      && bin/game-model score <dir> full && bin/game-model board <dir> full
bin/game-model generate <dir> panels    && bin/game-model score <dir> panels && bin/game-model board <dir> panels
bin/game-model generate <dir> iced_full && bin/game-model generate <dir> iced_panels && bin/game-model board <dir> iced_panels
```

After each stage, look at the board.

- **Write your picks** under `picks: { <stage>: { <slot>: <name> } }`. An unpicked
  slot takes the gate's best attempt.
- **Regenerate a slot** by deleting its file and re-running the stage.
- **Check:**
  - Hair height.
  - The number and nameplate.
  - Which way the three-quarter faces.
  - The star count on the captain patch.
  - That the shades and jewelry match across the iced panels.
  - That no held item is distorting a logo; leave helmets out of hands.

### 5. Stitch, look, file

```bash
bin/game-model stitch <dir> && bin/game-model stitch <dir> --iced
bin/game-model file <dir> --dry-run
bin/game-model file <dir> --production
```

`file` uploads both sheets to R2 under `character-sheets/game-models/<espn_id>/`
and posts them to `POST /api/v1/game_looks`. The hub then:

- makes the look (`descriptor`) and its iced twin;
- files each sheet as a `character_sheet` artifact stamped `game_model_layered`
  and the pinned model.

Re-filing the same key returns what is on file, and `file` refuses a second run once `filed.json` exists. Hand the operator the look links:
`https://mcritchie.studio/people/<person>/models/<look>`.

## People and looks: who a sheet files under

- **An athlete** files by `espn_id`. The hub finds him through his athlete
  record, and the new look takes his team and jersey number. All 24 starters of
  2026-10-18 were on file.
- **Anyone without an athlete record** (a head coach on the sideline) files by
  name. Put `person: { first_name, last_name, vocation }` in `spec.yml` in place
  of `espn_id` (vocation `coach`, or any non-athlete vocation), plus
  `team_slug` for his look's team.
  - The hub finds the person by name, or creates him with that vocation.
  - A person found by name keeps his flags.
  - An athlete never files by name, so a namesake is never guessed at.
- **The R2 folder names the subject:** the `espn_id`, or the person's name slug
  (`character-sheets/game-models/dave-canales/...`). The hub refuses a key under
  any other folder.
- **The look is per game:** `descriptor` names the uniform or attire and the game
  (`Panthers sideline · 2026 Week 6 at PHI`). Re-filing the same descriptor reuses
  the look. The first look a person gets becomes their default, which is what
  the people picker and the recast picker show.
- **A coach has no headshot to identify against.** Seed his face from the frames
  whose captions name him (`photos.json` `alt`), then run `find` with those
  crops as `face_refs`. The coach build itself (sideline attire in place of the
  uniform, the pads and the jersey) is not a CLI stage yet: the first coach
  sheet (Dave Canales, 2026-10-18) was built with the same pinned client and face
  pack, plus coach prompts.

## Cost and time, measured

A by-hand player took 500–700k image tokens over 48–65 images and 45–60 minutes.
The pipeline's run is about 40 images per player, both sheets included. The
headwear check costs about 1k tokens a crop, and only the identity matches are
checked.

## Related

- Memory: `character-model-from-alt-images` (the hand-built lessons).
- `game-photo-sourcing-rights` (option B).
- The look page's own one-call sheet build: `Appearances::SheetBuild`.
