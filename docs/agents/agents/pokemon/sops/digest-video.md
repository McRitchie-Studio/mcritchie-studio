# Digest Video

## Status: Active

The Pokémon's `digest-video` SOP: stage 1 of pipeline 3 in the
[music video pipeline plan](../../../system/music-video-pipeline-plan.md). Alex
says `digest video <url>`; the agent downloads the video, stores it, records
it, and cuts it into the recast pipeline's chunks, so the cast stage can start.

It runs on Alex's Mac, where the download works; YouTube often blocks cloud IPs.
`bin/digest-video <url>` runs steps 1 to 7 in one go:

```bash
bin/digest-video <url>                   # dev bucket, API at localhost:3000
bin/digest-video <url> --api <base>      # another hub, e.g. a desk server
bin/digest-video <url> --from-dir <dir>  # reuse a download already on disk
bin/digest-video <url> --dry-run         # download and print the plan only
bin/digest-video <url> --production      # production bucket and mcritchie.studio
bin/digest-video <url> --cookies-from-browser chrome   # lend yt-dlp the browser's session
bin/digest-video <url> --kind cinematic  # a cinematic video; the default is music_video
bin/digest-video <url> --chunk 15 --overlap 5   # 15 s chunks on a 10 s stride
bin/digest-video <url> --no-tile         # record the source only; cut no chunks
bin/digest-video <url> --retile          # replace the chunks a re-digested source already has
```

It writes the dev bucket unless `--production` is passed. The stages run in
this order: download, store the source, record it, chunks (step 6), report.
The cast (stage 2) comes after, and the chunks do not wait for it.

## 1. Pick the sub-SOP by host

| Host | Sub-SOP | State |
|---|---|---|
| `youtube.com`, `youtu.be` | [`download-youtube`](download-youtube.md) | measured 2026-09-28 |
| `tiktok.com`, `vm.tiktok.com`, `vt.tiktok.com` | [`download-tiktok`](download-tiktok.md) | built; download UNMEASURED |
| `instagram.com` | [`download-instagram`](download-instagram.md) | built; anonymous download measured 2026-10-04, cookie path UNMEASURED |

Any other host: stop and ask Alex.

## 2. Download

Run the sub-SOP. It leaves an H.264 MP4 and its `.info.json` in a working folder.
The script refuses an MP4 with no audio track. Confirm the MP4 plays and read
its duration:

```bash
ffprobe -v error -show_entries format=duration -of csv=p=0 <file>.mp4
```

## 3. Store the source in R2

The script uploads the MP4 and its `.info.json` to the hub's bucket,
`mcritchie-studio-dev` (default) or `mcritchie-studio-production`
(`--production`), at the snake_case key the plan names:

```text
music_videos/<artist>/<video>/source/<artist>_<video>_feat_<…>.mp4
music_videos/<artist>/<video>/source/<artist>_<video>_feat_<…>.info.json
```

Keys come from 1Password item `r2.mcritchie-studio` in `studio-agents`, read
through `bin/secret`; no value is printed. The stored `.info.json` keeps only
the allowlist in [`download-youtube`](download-youtube.md) (a TikTok's in
[`download-tiktok`](download-tiktok.md), which drops the caption, and an
Instagram reel's the same); lyrics and signed URLs are dropped.

## 4. Create the MusicVideo record

The script posts to `POST /api/v1/music_videos` (bearer token from
`/api/v1/auth`); `GET /api/v1/music_videos/<slug>` reads it back. A second post of
the same video answers 200 with the record it already has. The record carries:

- type (`kind`) `music_video`, or `cinematic` when the script ran with
  `--kind cinematic`; the API refuses any other;
- platform, source URL and source id (from `.info.json`);
- title, duration, and stage `digested`;
- the credited artists: each `primary` or `featured`. A group such as Migos is
  credited directly. The hub parses the title (`A - Title feat. B & C`, `ft.`,
  `x`, `&`, `and`, `(with …)`), then info.json's artists, then the uploader, and
  matches each name to the seed built by `artist-seed-from-wikidata`: exact name
  first, then alias, ignoring case.
- `unresolved_credits`: each name that matched no artist, or more than one. The
  hub never creates an artist; the cast step fixes these.

## 5. Captions: timing only

If the sub-SOP fetched captions, the script turns them into cue times and
`vocal`/`instrumental` sections before anything leaves the Mac. Never store
lyric text: the API refuses any field it does not know and any caption timing
that carries more than times and a section kind.

## 6. Cut the chunks

Right after the record, the script cuts the whole video into 25 s chunks that
overlap 5 s and posts them, with the same tiler `bin/find-clips --tile` runs
(`bin/lib/chunk_tiling.rb`; the steps are in
[Chunks](#chunks-the-whole-video-tiled), below). It runs here, on the Mac,
because a production dyno has no ffmpeg, and once per source, because one
source's chunks serve every alt video made from it. `--chunk` and `--overlap`
set the tiling (defaults 25 and 5); `--no-tile` skips the step; `--dry-run`
prints the chunks it would cut and cuts, uploads and posts nothing.

Nobody is cast yet, so every chunk is `unknown` with nobody on screen and
carries the generic prompt ("the singer", or "the main person on screen" for a
cinematic video). The hub labels the chunks from the cast when the vision pass
posts it and again when the operator confirms it (`MusicVideos::LabelChunks`),
and the prompts follow.

**A re-digest cuts nothing twice.** A second digest of the same source gets the
existing record back (step 4). If that record already has chunks at the same
chunk length and overlap, the script keeps them and says so: the hub accepted
them only as the whole tiling of the video, and the source never changes under
a recorded video, so a re-cut would only upload the same files again. If its
chunks were cut at another length or overlap, the script keeps them too and
names `--retile`, which replaces them. Takes and regenerate flags survive a
re-tile only at the same length and overlap (see the next stage).

## 7. Report

Report the video's title, duration, the R2 key, the credited artists, any
unresolved credits and the chunks; the script prints all of them. The next act
is stage 2, the cast.

## Stage 2: Cast

The agent finds the people on screen; the operator names them. No script runs
steps 1 to 3 yet: **PLANNED** is a `bin/cast-video` that does them in one go.
Until then the agent runs them by hand on the Mac, from the source MP4.

1. **Sample frames with accurate seeks.** One frame every 3 seconds, each taken
   with `-ss` before `-i`, so the timestamp is the frame's real time:

   ```bash
   ffmpeg -v error -ss <seconds> -i <file>.mp4 -frames:v 1 -q:v 3 f_<mmss>.jpg
   ```

   Never take timestamps from the `fps=` filter: in the founding run it drifted
   from the real timeline.
2. **Group people by visible cues** (outfit, hair, eyewear, jewelry) into
   Person 1..N, numbered by first appearance. **Never face recognition**, and
   no names: naming is the operator's, in every artifact (prose, a desk
   database, a test fixture; fixtures use synthetic artists). Credits read from
   the video's own title or metadata are fine. Each sighting is a time and `clear` or
   `partial` (partly in frame, or background). Note what a sample cannot tell
   apart (two people always together, a mannequin, a figure too small).
3. **Upload one still per person** to the same bucket as the source, at
   `music_videos/<artist>/<video>/stills/person_<NN>_<mmss>.jpg`. The API refuses
   a still outside the video's own folder or numbered for another person.
4. **Post the set**, which replaces any set already there:

   ```bash
   POST /api/v1/music_videos/<slug>/performers
   { "performers": [ { "ordinal": 1, "label": "desk",
       "still_object_keys": ["music_videos/steve_aoki/night_call/stills/person_01_0230.jpg"],
       "sightings": [ { "t_ms": 18000, "visibility": "clear" } ],
       "confidence_note": "Desk scenes throughout." } ] }
   ```

   The agent never sends an artist or a recast: any key beyond these five is
   refused (`UNPERMITTED_KEYS`). A replace drops the operator's labels and
   recasts on the old set and says how many of each (`meta.dropped_labels`,
   `meta.dropped_recasts`); a confirmed cast answers `409 CAST_CONFIRMED`.
5. **Hand the operator the cast panel**, `/music_videos/<slug>` (admin). Each card
   shows the still and the sightings as links to that second of the video.
   **Nothing on a card has to be pressed**: every card starts **Not named** and
   not swapped, and **Cast confirmed** is ready as soon as the vision
   pass has posted people; it moves the video from `digested` to
   `cast_confirmed`. A card reads top to bottom: the still and "Person N";
   **Replace with** (step 6); the description and sightings; then, pinned to
   the bottom so cards in a row line up, the **Keep Original / Swap back**
   button and **who is on screen**. Naming is optional and builds the artist
   rolodex: a small "Who is this on screen? (optional)" label over a search
   input that is always open, quieter than Replace with: a typeahead over artists (names and aliases)
   and People who are not athletes or coaches (sports people are offered by the
   swap search; one already linked to an artist still comes back as that
   artist), each result a
   headshot (a neutral placeholder when there is none), the name, the primary
   vocation and the current team (`People::SearchRows`; an artist with no
   Person reads "musician" or "group"). A pick names the card and saves at
   once (a JSON `PATCH`, no reload; Saving…, Saved, or Not saved with Retry);
   picking a person from People makes them an artist; "Create new artist" adds
   one; the "Mark as extra" text link records an extra, shown as a small
   removable chip. No column says "unnamed": it is a card with neither an
   artist nor the extra flag. A named card shows the person's headshot,
   vocation and team with a small **Clear**, the search still open underneath;
   the header badge follows each save, naming someone who has looks offers
   **Swap with <name>?** at once, naming stays editable after the confirm, and
   the stored prompts follow each change.
6. **The operator swaps**, on the same card, under **Replace with**, which sits
   at the top of the card, under the still and the "Person N" heading and above
   the description and sightings: a people search on every card, with no toggle
   to press first. A card with nobody
   picked shows only that search (a card saved under the old "Keep as is"
   reads the same). The search is a list wider than the card, three columns
   per row (the headshot; the name, vocation, team and looks count; the
   person's default look as a character-sheet thumbnail and name, or "No look
   yet"). People who have a look come first; then exact name, prefix,
   anywhere. **Picking a person is the swap** and saves at once, with no Save
   or Cast button: they are cast in their default look (else their first), and
   the card shows them with their headshot, name and team, a **Clear** button
   (forget them entirely), and the **look dropdown**. A card named after
   someone who has looks also offers **Swap with <name>?**, a one-click pick of
   them in their default look (never done for him). The look dropdown lists
   one row per look, with the look's character-sheet thumbnail (a placeholder
   while it has none), its name, a "default" mark and where its sheet stands
   (ready, building, failed, none); picking a row saves that look, previewed
   large with a link to the look's own page. The arrow keys, Home, End, Enter,
   Space and Escape work the list.
   Once someone is picked, one button pinned at the bottom of the card, just
   above who is on screen, turns the swap off and on in the same place. While
   swapping it reads **Keep Original**: pressing it stops the swap and hides
   the chosen person, the look dropdown and the preview, but **remembers** them
   (`recast_keep`): nothing reads them while kept (prompts, swap target and
   hand-off treat the person as kept). The button then reads **Swap back to
   <name>** with their headshot, and restores them in one press with no
   re-pick (a remembered look since retired falls back to "needs a look"). A
   card with nobody remembered shows neither. Picking someone else from the
   search, which stays on the card, swaps to them. The card says
   Saving…, Saved, or Not saved with Retry; each change is a JSON `PATCH` to
   the recast endpoint, sent one at a time in the order made (a change made
   while one is in flight waits for it), so the server always ends where the
   card does. The prompts, targets and hand-offs below repaint after each save
   without a reload.
7. **A new look, from the card.** The dropdown's last row is **Generate a new
   look**; a person with **no look yet** (listed with "0 looks", saved alone
   as a pending swap) gets **Generate first look** in its place. The form asks
   for the look's name, which is the uniform or colours the sheet is drawn in
   ("Broncos blue"), an optional jersey number, a reference photo URL that
   only a person with no stored headshot needs, and **which sheets to build**.
   Submitting makes the look **and its iced-out twin** ("Broncos blue · iced":
   designer shades, chain, watch, bracelet, grill, and the person's own rings
   from their jewelry records, else generic diamond rings), **casts the card in
   the look**, and starts the chosen sheets through the one existing build
   (`Appearances::SheetBuild`, in a job; see `docs/topics/content-pipeline.md`,
   "Character sheets" and "The iced-out twin"). **Each sheet costs money**:
   single-digit thousands of tokens (`config/image_generators.yml`). The
   default builds the look's sheet only; **Both sheets** is two paid builds,
   **Iced sheet only** one, **No sheet yet** none. **The kicker: "create the Dak
   model" means the Dak model AND the iced-out Dak model.** Ask the operator
   whether to build both sheets (two charges) before choosing Both, and before
   building the iced sheet of someone with a championship, check that their
   rings are on their person page (Jewelry), so the sheet draws their own. The card previews the new look
   as building and repaints itself when the sheet is ready, about two minutes.
   A look may be cast while its sheet is building, or with none; its chunks
   show the sheet once there is one. Where no generator is configured, or the
   person has no headshot, the look is still made and the card says why no
   sheet started; build it later from the look's page. "Or add a look by hand"
   opens the look form on the person's page and returns to the card on save,
   where the swap waits for that look to be picked. A swap with no look is the
   one thing a card can owe ("needs a look" in the summary); it does not hold
   the confirm, and the athlete's name already fills the prompts. The swap can
   change before and after the cast is confirmed. **Only the operator sets
   it**: the agent never proposes who replaces anyone, and generating a look
   is admin only. So is the person page's own look form (which also makes the
   iced twin), its "Create iced twin" for an older look, its "Make default",
   its "Attach image" and its jewelry list; an attached image must be an
   `https://` URL on a public host.

The Night Call proof is the dev seed (`db/seeds/data/night_call_cast.rb`): seven
people, stills and sightings, no names.

## Stage 5: Clips

Once the cast is confirmed, `bin/find-clips` proposes 25-second clips, cuts
them to R2 and records them. It uses ffmpeg only; install nothing else. With
`--tile` it re-cuts the whole video into overlapping chunks instead
([Chunks](#chunks-the-whole-video-tiled), below); the digest already cut them
once, so `--tile` is for a source digested before 2026-10-06 or a new tiling.

```bash
bin/find-clips <slug>                  # dev bucket, API at localhost:3000
bin/find-clips <slug> --api <base>     # another hub, e.g. a desk server
bin/find-clips <slug> --source <mp4>   # a source already on disk
bin/find-clips <slug> --dry-run        # measure and print the windows only
bin/find-clips <slug> --production     # production bucket and mcritchie.studio
bin/find-clips <slug> --tile           # the whole video as 25 s chunks that overlap 5 s
bin/find-clips <slug> --tile --chunk 15 --overlap 5   # 15 s chunks on a 10 s stride
```

1. **Source.** `--source`, else the digest folder
   (`~/projects/.corpus/music_videos/<source id>/`), else the stored source from
   the bucket, read with the same 1Password item as the digest.
2. **Measure.** `silencedetect` finds silences; `astats` gives the level of the
   bass, mids and highs every half second; the scene filter finds cuts. Captions
   add section boundaries (timings only).
3. **Pick.** The music body is the span within 6 dB of the median level, so the
   intro and outro fall outside. A boundary is an energy step: the next 8 s
   against the previous 8 s. A rise reads as verse to chorus and a drop as chorus
   to verse; this is a heuristic, and the operator judges. A singer change is a
   handover between two confirmed artists, each seen alone at least twice. Each
   window starts on a boundary (snapped to a cut within 1 s), runs 24 to 26 s,
   holds no silence, and has a seam at least 6 s inside it. The best
   non-overlapping five are kept.
4. **Label.** A principal is a performer linked to an artist and seen clearly in
   the window. The count gives `solo`, `duo`, `trio` or `group`; anyone else
   present adds `_plus_background`. The target is the principal seen most.
5. **Cut and store.** Each window is re-encoded to H.264/AAC, so the in and out
   points are exact, and uploaded to
   `music_videos/<artist>/<video>/clips/<video>_clip_<NN>_<seam>_<shape>_<mmss>_<mmss>.mp4`.
6. **Post the set**, which replaces any set already there:
   `POST /api/v1/music_videos/<slug>/clips` with `ordinal`, `start_ms`, `end_ms`,
   `seam`, `seam_ms`, `cast_shape`, `target_performer`, `performer_ordinals` and
   `object_key`. The hub fills each prompt from the template in
   `lib/music_videos/clip_prompt.rb`. It refuses candidates for a video whose
   cast is not confirmed (`409 CAST_NOT_CONFIRMED`; chunks are never refused
   for that) and a prompt or status sent by the agent
   (`UNPERMITTED_KEYS`). A replace drops approvals on the old set and says how
   many (`meta.dropped_approvals`). Old clip files stay in the bucket.
7. **Hand the operator the clips**, below the cast on `/music_videos/<slug>`:
   a preview, the window and seam, the cast shape, the target, the prompt with a
   Copy button, and Approve / Reject. One approved clip moves the video to
   `clips_ready`.

The prompt reads the cast label as the target's description: a label naming a
person ("long-haired man") reads as-is, and a scene label ("desk") reads as "the
person in the desk scenes". Write labels as visible descriptions for the best
prompt.

**The recast fills the prompt.** When the clip's target is recast, the prompt
names the athlete in place of `{athlete}` and mentions the look ("like the
<look> model provided"). When the target is kept or undecided and someone else
in the window is recast, the prompt replaces that person instead (the lowest
Person number, when several are). With nobody recast, `{athlete}` stays a
blank. Changing a recast rewrites the stored prompt of every candidate and
chunk of the video, so copy a prompt after the cast card is right, not before.
One prompt replaces one person: a window with two recast people still names
only one. For a `cinematic` video the prompt says "this video", never "music
video".

### Chunks: the whole video, tiled

`bin/digest-video` cuts the WHOLE video into chunks when it records the source
(step 6 above). `bin/find-clips <slug> --tile` runs the same tiler again, to
tile a source digested before then or to change the tiling, and always replaces
the chunks there. It takes the same flags as the candidate run (`--api`,
`--source`, `--dry-run`, `--production`); `--count` does not apply. Neither
needs a confirmed cast. The chunks and the candidates are two sets on one
video: posting either never replaces the other.

1. **Tile.** By default 25 s chunks on a 20 s stride, so each shares 5 s with
   the one before: 0-25, 20-45, 40-65 and on. `--chunk <seconds>` and
   `--overlap <seconds>` change the two; they need `--tile`, and the overlap
   must be shorter than the chunk. `--chunk 15 --overlap 5` gives 0-15, 10-25,
   20-35 and on, for a swap model that takes 15 s at most. The last chunk ends at
   the video's end and may be shorter. A tail the previous chunk already covers
   makes no extra chunk (at the defaults, a 45 s video is two chunks). The rule
   lives in `lib/music_videos/chunk_tiler.rb`. A chunk has no seam; only the
   duration is measured.
2. **Check the source.** The file on disk must run within 1 s of the recorded
   duration, or the script stops: it is not the digested video. The tiling ends
   at the shorter of the two.
3. **Label.** As for a candidate: cast shape, target and who is present, from
   the cast as it is when the chunks are cut. Chunks cut before the cast (the
   digest's) are `unknown` with nobody present; the hub relabels every chunk
   from the cast when the vision pass posts it and when the cast is confirmed.
4. **Cut and store.** Re-encoded like a candidate, uploaded to
   `music_videos/<artist>/<video>/chunks/<video>_chunk_<NN>_<mmss>_<mmss>.mp4`.
5. **Post the set**: `POST /api/v1/music_videos/<slug>/clips` with
   `"kind": "chunk"`, `chunk_ms` and `chunk_overlap_ms` beside `clips` (the two
   default to 25000 and 5000). The video records them as its tiling, and `GET`
   returns them. Each row carries `ordinal`, `start_ms`,
   `end_ms`, `cast_shape`, `target_performer`, `performer_ordinals` and
   `object_key`; `seam` and `seam_ms` are refused (`UNPERMITTED_KEYS`). The set
   must be the whole tiling at that chunk length and overlap: anything else
   answers `422 INVALID_TILING`. It
   replaces the chunks and leaves the candidates and their approvals alone. With
   no `kind`, the post is the candidate set, as before. `GET` returns the
   candidates under `clips` and the chunks under `chunks`.
6. **Hand the operator the chunks**, below the clip candidates on
   `/music_videos/<slug>`: their windows in time order, and the source's alt
   videos. A chunk has no Approve or Reject, and never moves the video's stage.
   Chunks are cut once per source and shared by every alt video.

### Alt videos and the clip builder

A source video yields many **alt videos**: one generated version each, with its
own swaps (a Cowboys version and a Vikings version of the same music video).
The cast cards are the working selection; an alt video keeps a snapshot.

1. **Build Clips.** In the cast summary bar, beside **Cast confirmed**, press
   **Build Clips** (on once the cast is confirmed and the video is tiled). It
   makes the source's next alt video (`/music_videos/<slug>/alt_videos/<n>`)
   from the swaps as they stand, with one **clip** per chunk, and opens it.
   Editing the cast cards afterwards never changes an existing alt video:
   change the cards and press Build Clips again for another version.
2. **Take the hand-off** on each clip card, in time order: **Download 25 s
   clip** (the source chunk, as an attachment), the **lettered frames** (each
   with **Download**; make them first, see
   [Lettered references](#lettered-references)), one sheet button per person
   this alt video swaps in that window, labelled `Sheet 1 · Person B · #4 Dak
   Prescott`, and **Copy prompt** (built from the alt video's own swaps). Add
   the sheets to Higgsfield in their numbered order: the prompt names them as
   "character sheet 1", "character sheet 2". With no sheet the card says so
   and links to the athlete.
3. **Drop the result.** Drag the Higgsfield MP4 onto the clip's drop zone, or
   click it to choose the file; it uploads at once. Each upload is a numbered
   **version**, kept and never overwritten, at
   `music_videos/<artist>/<video>/alt_videos/<NN>/clips/<video>_alt_<NN>_chunk_<NN>_<mmss>_<mmss>_v<NN>.mp4`.
   The newest version is primary; **Make primary** on an older one puts it
   back in front, and the next upload is primary again. MP4 only, 100 MB at
   most, checked in the browser before the upload and again on the server.
   The file rides the web request, so on a slow uplink a large file can pass
   Heroku's 30-second window: upload from the local hub then.
4. **Request a regenerate** on a clip whose primary will not do, with an
   optional note. The flagged clips are listed at the top. The next upload
   for that clip clears its flag; **Clear** removes it by hand.
5. **Watch full video** opens a modal that plays the primary versions back to
   back as if stitched, with no stitched file: a clip with no version plays its
   source chunk (marked `source`), each hands over to the next at the middle of
   their overlap, the original source audio plays underneath and the clips are
   muted. The handover is a hard cut; the crossfade belongs to
   [the final stitch](#the-final-stitch).
6. **Find it again** at `/alt_videos` (Admin links, Video): every alt video
   across every source, with clips that have a primary out of the total,
   whether it is stitched, and the last activity.

A clip keeps its chunk's window. If the source is re-tiled at another length,
the card says its window is no longer cut; build a new alt video.

Piece 3's takes and piece 4's stitches were moved onto "alt video 1" of each
source that had any by the `CreateAltVideos` migration (old objects stay
where they were; `video_chunk_takes` is kept, read by nothing).

Timing comes from each chunk's `start_ms` and `end_ms`
(`lib/music_videos/stitch_timeline.rb`), never from a file's length: cut files
run a frame long and a generated file may differ slightly.

### Lettered references

The clip prompt names people by **letter** and players by **jersey number**:
`Person B (lead) -> #4 Dak Prescott, Cowboys white (character sheet 1)`. A
letter is fixed per source video: Person 1 is A, Person 2 is B, and so on, in
every clip and every alt video. The prompt lists every swapped person seen in
the clip, leads (lip-synced) and background alike; everyone else is kept. A
look's number is `appearances.jersey_number`, typed when the look is made or
its sheet generated, and edited on the person page (**Save number**); without
one the prompt uses the name. To show Higgsfield who is who, each clip gets 2-3
stills of the source with the letters drawn over the people.

Letters are not names. The agent places a tag where it sees a person; only
the operator says who that person is.

1. **Extract.** On the Mac, from the hub checkout:

   ```bash
   bin/clip-references <slug> --extract              # dev bucket, localhost:3000
   bin/clip-references <slug> --extract --alt 2      # choose frames that show alt video 2's swaps
   bin/clip-references <slug> --extract --production # production API and bucket
   ```

   For each chunk it picks 2-3 moments from the cast's sightings where the
   chunk's people are clearly on screen (with `--alt`, the ones that alt video
   swaps first), stills them with ffmpeg (an accurate seek: `-ss` before `-i`),
   and writes `~/projects/.corpus/music_videos/references/<slug>/tags.json`.
   `--dry-run` prints the moments only.
2. **Place the tags.** Open each frame under `references/<slug>/frames/` and
   fill its `tags` with one entry per person you can see. `expect` is who the
   sightings put on screen; tag who you actually see, using any letter in
   `people` (each carries the cast card's visual label):

   ```json
   { "file": "frames/chunk_03_ref_01.jpg", "t_ms": 45000, "expect": ["A", "B", "C"],
     "tags": [ { "letter": "B", "x": 0.50, "y": 0.50 }, { "letter": "C", "x": 0.80, "y": 0.42 } ] }
   ```

   `x` and `y` are the fractions of the frame's width and height where the tag
   goes: over the chest, clear of the face. A frame left with no tags is dropped.
3. **Apply.**

   ```bash
   bin/clip-references <slug> --apply --dry-run      # draw into references/<slug>/lettered/ and look at them
   bin/clip-references <slug> --apply                # draw, upload, post
   bin/clip-references <slug> --apply --chunk 3      # one chunk
   ```

   Each tag is drawn as a yellow disc with the letter in black by ImageMagick
   (`magick`; this ffmpeg has no `drawtext`). The JPEGs go to
   `music_videos/<artist>/<video>/chunks/refs/<video>_chunk_<NN>_<mmss>_<mmss>_ref_<NN>.jpg`
   and each chunk's set is posted to
   `POST /api/v1/music_videos/:slug/chunks/:ordinal/references`
   (`{ frames: [{ object_key, t_ms, letters }] }`, agent token; any other key is
   refused). A post replaces the chunk's frames; a re-tile at the same windows
   keeps them. The frames belong to the source's chunks, so every alt video's
   clip card shows them.

### The final stitch

One MP4 of an alt video: every clip's primary version, crossfaded into the
next across their overlap, over the original source audio. It runs where ffmpeg
is. Production dynos have none, so on production the Mac does it.

1. **Press Generate full video** in the **Full video** panel, above the clip
   cards on `/music_videos/<slug>/alt_videos/<n>`. The button is on only when
   every clip has a primary version and none is flagged; until then the panel
   says what holds it up. Pressing it records stitch N of that alt video with
   the version each clip has as primary at that moment.
2. **On a local hub** (ffmpeg on `PATH`) a background job stitches at once. The
   panel says it is stitching and offers **Show it** when it finishes.
3. **On production** the panel says stitch N is waiting. Run it from the Mac:

   ```bash
   bin/stitch-video <slug> --alt <n> --production
   ```

   It fetches the primary versions and the source from R2 (1Password item
   `r2.mcritchie-studio`, as `bin/find-clips` does), stitches, uploads the MP4
   and reports through the API. Then reload the page.
4. **Check the result** in the panel: a player, the length, size and frame
   rate, the version numbers it used, and **Download**. Judge lip-sync here, on
   the stitched file, not in the preview.
5. **Stale.** A stitch is marked **Stale**, with the reason, once any clip
   gets a newer primary version, has an older one put back, or is flagged for
   a regenerate. It still plays and downloads. Generate
   again for a current one; every stitch is numbered and kept.

`bin/stitch-video` flags, the same set as `bin/find-clips`:

| Flag | Does |
|---|---|
| (none) | alt video 1, dev bucket, the local hub at `localhost:3000` |
| `--alt N` | alt video N of the source |
| `--api URL` | another hub, such as a desk server |
| `--production` | the production bucket and `https://mcritchie.studio` |
| `--source FILE` | use a source MP4 already on disk instead of fetching it |
| `--dry-run` | fetch, measure and print the plan; start, encode, upload and report nothing |
| `--force` | also run a stitch stuck `running` (a closed lid) or one that failed |

With no request waiting, `bin/stitch-video` asks for one itself, so it also
works without the button. Downloads are kept under
`~/projects/.corpus/music_videos/stitch/<slug>/alt_<NN>/`, so a second stitch
fetches only the versions that changed.

What the stitch does (`lib/music_videos/stitch_plan.rb`, pure and unit-tested;
`lib/music_videos/stitcher.rb` runs it):

- **Picture.** Take N fades into take N+1 across exactly the frames their
  windows share (ffmpeg `xfade`). Each chunk owns output frames
  `round(start × rate)` to `round(end × rate)`, counted from the chunk's
  recorded window and never from a file's length, so nothing drifts down the
  video. A take that runs short of its window holds its last frame; one that
  runs long is trimmed. Either is listed as a note on the stitch.
- **One size and rate.** Every take is brought to the best any take offers and
  never more than the source: the largest take's frame (the source's if a take
  is larger), and the highest take frame rate capped at the source's. Takes
  that all came back smaller than the source are stitched at their own size,
  with no invented pixels. A take within 2 % of the target's shape is stretched
  to it; any other is fitted inside and padded black. Pixel format `yuv420p`.
- **Audio.** The source's own audio for the whole length, through no filter: an
  AAC track is copied bit for bit. The takes' audio is never read.
- **Output.** H.264 and AAC in MP4, as long as the last chunk's end. The
  stitcher refuses to store a file more than one frame per chunk off the plan.

If a stitch fails, the panel shows the reason. A stitch left `running` for 30
minutes reads as stuck: generate again to replace it, or pass `--force`.

## Related

- [Music video pipeline plan](../../../system/music-video-pipeline-plan.md): the
  stages, data model and R2 tree.
- [`object-storage.md`](../../../modules/object-storage.md): the R2 buckets.
