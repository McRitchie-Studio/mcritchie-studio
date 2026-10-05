# Digest Video

## Status: Active

The Pokémon's `digest-video` SOP: stage 1 of pipeline 3 in the
[music video pipeline plan](../../../system/music-video-pipeline-plan.md). Alex
says `digest video <url>`; the agent downloads the video, stores it, and records
it so the cast stage can start.

It runs on Alex's Mac, where the download works; YouTube often blocks cloud IPs.
`bin/digest-video <url>` runs steps 1 to 5 in one go:

```bash
bin/digest-video <url>                   # dev bucket, API at localhost:3000
bin/digest-video <url> --api <base>      # another hub, e.g. a desk server
bin/digest-video <url> --from-dir <dir>  # reuse a download already on disk
bin/digest-video <url> --dry-run         # download and print the plan only
bin/digest-video <url> --production      # production bucket and mcritchie.studio
bin/digest-video <url> --cookies-from-browser chrome   # lend yt-dlp the browser's session
bin/digest-video <url> --kind cinematic  # a cinematic video; the default is music_video
```

It writes the dev bucket unless `--production` is passed.

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

## 6. Report

Report the video's title, duration, the R2 key, the credited artists and any
unresolved credits; the script prints all of them. The next act is stage 2, the cast.

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
   no names: naming is the operator's. Each sighting is a time and `clear` or
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
   shows the still, the sightings as links to that second of the video, and a
   typeahead over artists (names and aliases) and People. Each result is one
   row: a headshot (a neutral placeholder when there is none), the name, then
   the primary vocation and the current team (`People::SearchRows`; an artist
   with no Person reads "musician" or "group"). Picking a person from
   People makes them an artist; "Create new artist" adds one; "Extra, not a named
   artist" closes a card. **Cast confirmed** unlocks when every card is closed and
   moves the video from `digested` to `cast_confirmed`. A `cinematic` video
   credits no artists, so there a card also closes on its recast answer (below)
   and naming an artist is optional.
6. **The operator recasts**, on the same card, under "Replaced by": a typeahead
   over every Person, drawn with the same row and a looks count. A person who
   has a default look also shows it on a second line of the row: that look's
   character-sheet thumbnail and its name ("Primary look"), apart from the
   headshot, so the row says what is saved for them. People who have a look
   come first; then exact name, prefix, anywhere. Picking someone saves
   nothing yet. It opens the **look dropdown**: one row per look, with
   the look's character-sheet thumbnail (a placeholder while it has none), its
   name, a "default" mark and where its sheet stands (ready, building, failed,
   none). The look picked is previewed large, with a link to the look's own
   page; **Cast as Athlete > Look** saves it. The arrow keys, Home, End, Enter,
   Space and Escape work the list. Or "Keep as is".
7. **A new look, from the card.** The dropdown's last row is **Generate a new
   look**; a person with **no look yet** (listed with "0 looks") gets
   **Generate first look** in its place. The form asks for the look's name,
   which is the uniform or colours the sheet is drawn in ("Broncos blue"), an
   optional jersey number, and a reference photo URL that only a person with
   no stored headshot needs. Submitting makes the look, takes the athlete as
   the card's recast, and starts the look's character sheet through the one
   existing build (`Appearances::SheetBuild`, in a job; see
   `docs/topics/content-pipeline.md`, "Character
   sheets"). **It costs money**: one sheet per press, single-digit thousands
   of tokens (`config/image_generators.yml`). The card previews the new look
   as building and repaints itself when the sheet is ready, about two minutes.
   The new look is **not cast for him**: he still presses "Cast as". A look
   may be cast while its sheet is building, or with none; its chunks show the
   sheet once there is one. Where no generator is configured, or the person
   has no headshot, the look is still made and the card says why no sheet
   started; build it later from the look's page. "Or add a look by hand" opens
   the look form on the person's page and returns to the card on save. An
   athlete with no look cast does not close a card, and their name already
   fills the prompts. The recast can change before and after the cast is
   confirmed. **Only the operator sets it**: the agent never proposes who
   replaces anyone, and generating a look is admin only.

The Night Call proof is the dev seed (`db/seeds/data/night_call_cast.rb`): seven
people, stills and sightings, no names.

## Stage 5: Clips

Once the cast is confirmed, `bin/find-clips` proposes 25-second clips, cuts
them to R2 and records them. It uses ffmpeg only; install nothing else. With
`--tile` it cuts the whole video into overlapping chunks instead
([Chunks](#chunks-the-whole-video-tiled), below).

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
   `lib/music_videos/clip_prompt.rb`. It refuses a video whose cast is not
   confirmed (`409 CAST_NOT_CONFIRMED`) and a prompt or status sent by the agent
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

`bin/find-clips <slug> --tile` cuts the WHOLE video into chunks instead of
picking candidates. It takes the same flags (`--api`, `--source`, `--dry-run`,
`--production`); `--count` does not apply. The chunks and the candidates are two
sets on one video: running either never replaces the other.

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
3. **Label.** As for a candidate: cast shape, target and who is present.
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
   `/music_videos/<slug>`: in time order, each with a preview, its window, the
   cast shape, the target, who replaces them, and the prompt with a Copy button.
   A chunk has no Approve or Reject, and never moves the video's stage.

### Generated takes and the stitch preview

The operator swaps each chunk by hand in the Higgsfield web UI and brings the
result back. All of it happens on `/music_videos/<slug>`, in the chunk's row.

1. **Take the hand-off.** Each chunk row carries the three inputs: **Download
   source chunk** (the cut file, served as an attachment), the swap prompt with
   **Copy**, and **Character sheet** for the look the chunk's target was recast
   as. With no sheet the row says so and links to the athlete; with nobody
   recast it says there is no look.
2. **Upload the result.** Choose the generated MP4 in the row and press
   **Upload take**. Each upload is a numbered take, kept and never overwritten,
   at `music_videos/<artist>/<video>/generated/<video>_chunk_<NN>_<mmss>_<mmss>_take_<NN>.mp4`.
   The newest take is current; **Make current** on an older take puts it back
   in front, and the next upload is current again. MP4 only, 100 MB at most.
   The file rides the web request, so on a slow uplink a large file can pass
   Heroku's 30-second window: upload from the local hub then.
3. **Request a regenerate** on a chunk whose take will not do, with an optional
   note. The flagged chunks are listed above the preview. The next take
   uploaded for that chunk clears its flag; **Clear** removes it by hand.
4. **Watch the stitch preview**, above the chunk rows. It plays the whole video
   as if stitched, with no stitched file: each chunk plays its current take,
   or its own source cut when it has none (marked `source`), and hands over to
   the next at the middle of their overlap. The original source audio plays
   underneath and the clips are muted. Seek with the slider or a chunk marker.
   The handover is a hard cut; the crossfade belongs to
   [the final stitch](#the-final-stitch).
5. **Ready to stitch** shows when every chunk has a current take and none is
   flagged (`MusicVideo#ready_to_stitch?`). Until then the line says what is
   missing.

A re-tile at the same chunk length and overlap keeps every take and flag: a
take belongs to a chunk by its number and window, not by row. A re-tile at
another length leaves the old takes filed in R2 and on no chunk.

Timing comes from each chunk's `start_ms` and `end_ms`
(`lib/music_videos/stitch_timeline.rb`), never from a file's length: cut files
run a frame long and a generated file may differ slightly.

### The final stitch

One MP4 of the whole video: every chunk's current take, crossfaded into the
next across their overlap, over the original source audio. It runs where ffmpeg
is. Production dynos have none, so on production the Mac does it.

1. **Press Generate full video** in the **Full video** panel, above the chunk
   rows on `/music_videos/<slug>`. The button is on only when the video is
   ready to stitch; until then the panel says what holds it up. Pressing it
   records stitch N with the take each chunk has at that moment.
2. **On a local hub** (ffmpeg on `PATH`) a background job stitches at once. The
   panel says it is stitching and offers **Show it** when it finishes.
3. **On production** the panel says stitch N is waiting. Run it from the Mac:

   ```bash
   bin/stitch-video <slug> --production
   ```

   It fetches the takes and the source from R2 (1Password item
   `r2.mcritchie-studio`, as `bin/find-clips` does), stitches, uploads the MP4
   and reports through the API. Then reload the page.
4. **Check the result** in the panel: a player, the length, size and frame
   rate, the take numbers it used, and **Download**. Judge lip-sync here, on
   the stitched file, not in the preview.
5. **Stale.** A stitch is marked **Stale**, with the reason, once any chunk
   gets a newer current take, has an older take put back, is flagged for a
   regenerate, or the video is re-tiled. It still plays and downloads. Generate
   again for a current one; every stitch is numbered and kept.

`bin/stitch-video` flags, the same set as `bin/find-clips`:

| Flag | Does |
|---|---|
| (none) | dev bucket, the local hub at `localhost:3000` |
| `--api URL` | another hub, such as a desk server |
| `--production` | the production bucket and `https://mcritchie.studio` |
| `--source FILE` | use a source MP4 already on disk instead of fetching it |
| `--dry-run` | fetch, measure and print the plan; start, encode, upload and report nothing |
| `--force` | also run a stitch stuck `running` (a closed lid) or one that failed |

With no request waiting, `bin/stitch-video` asks for one itself, so it also
works without the button. Downloads are kept under
`~/projects/.corpus/music_videos/stitch/<slug>/`, so a second stitch fetches
only the takes that changed.

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
