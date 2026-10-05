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

   The agent never sends an artist: any key beyond these five is refused
   (`UNPERMITTED_KEYS`). A replace drops the operator's labels on the old set and
   says how many (`meta.dropped_labels`); a confirmed cast answers `409
   CAST_CONFIRMED`.
5. **Hand the operator the cast panel**, `/music_videos/<slug>` (admin). Each card
   shows the still, the sightings as links to that second of the video, and a
   typeahead over artists (names and aliases) and People. Picking a person from
   People makes them an artist; "Create new artist" adds one; "Extra, not a named
   artist" closes a card. **Cast confirmed** unlocks when every card is closed and
   moves the video from `digested` to `cast_confirmed`.

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
bin/find-clips <slug> --tile           # the whole video as 25 s chunks on a 20 s stride
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
prompt. `{athlete}` stays a blank for pipeline 4.

### Chunks: the whole video, tiled

`bin/find-clips <slug> --tile` cuts the WHOLE video into chunks instead of
picking candidates. It takes the same flags (`--api`, `--source`, `--dry-run`,
`--production`); `--count` does not apply. The chunks and the candidates are two
sets on one video: running either never replaces the other.

1. **Tile.** 25 s chunks on a 20 s stride, so each shares 5 s with the one
   before: 0-25, 20-45, 40-65 and on. The last chunk ends at the video's end and
   may be shorter. A tail the previous chunk already covers makes no extra chunk
   (a 45 s video is two chunks). The rule lives in
   `lib/music_videos/chunk_tiler.rb`. A chunk has no seam; only the duration is
   measured.
2. **Check the source.** The file on disk must run within 1 s of the recorded
   duration, or the script stops: it is not the digested video. The tiling ends
   at the shorter of the two.
3. **Label.** As for a candidate: cast shape, target and who is present.
4. **Cut and store.** Re-encoded like a candidate, uploaded to
   `music_videos/<artist>/<video>/chunks/<video>_chunk_<NN>_<mmss>_<mmss>.mp4`.
5. **Post the set**: `POST /api/v1/music_videos/<slug>/clips` with
   `"kind": "chunk"` beside `clips`. Each row carries `ordinal`, `start_ms`,
   `end_ms`, `cast_shape`, `target_performer`, `performer_ordinals` and
   `object_key`; `seam` and `seam_ms` are refused (`UNPERMITTED_KEYS`). The set
   must be the whole tiling: anything else answers `422 INVALID_TILING`. It
   replaces the chunks and leaves the candidates and their approvals alone. With
   no `kind`, the post is the candidate set, as before. `GET` returns the
   candidates under `clips` and the chunks under `chunks`.
6. **Hand the operator the chunks**, below the clip candidates on
   `/music_videos/<slug>`: in time order, each with a preview, its window, the
   cast shape, the target and the prompt with a Copy button. A chunk has no
   Approve or Reject, and never moves the video's stage.

## Related

- [Music video pipeline plan](../../../system/music-video-pipeline-plan.md): the
  stages, data model and R2 tree.
- [`object-storage.md`](../../../modules/object-storage.md): the R2 buckets.
