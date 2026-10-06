# Music Video Pipeline Plan

## Status: Active

Decided with Alex on 2026-09-29. This page is the plan for pipeline 3: turning a
music video into a cast, looks and clips that pipeline 4 can swap athletes into.
The acts live in Pokémon's SOPs, starting with
[`digest-video`](../agents/pokemon/sops/digest-video.md).

## The four pipelines

| # | Pipeline | State |
|---|---|---|
| 1 | Tasks and deployments | exists: the DevOps cycle |
| 2 | Athlete model creation: acquire → look → reference search → character sheet | exists: `docs/topics/content-pipeline.md` |
| 3 | Music video processing and artist model creation | **new: this plan** |
| 4 | AI video creation | manual step, below |

**Pipeline 4.** A clip, its filled prompt and the athlete's assets go to the
operator. He runs Higgsfield Genjutsu Motion Transfer in the Higgsfield web UI at
720p and uploads the result MP4 back. The Higgsfield step is manual by decision:
the API route failed 14 requests out of 14, every one `nsfw`, while the same
inputs complete in the UI.

## Pipeline 3 stages

### 1. Digest

`digest video <url>` (`bin/digest-video`) downloads through a platform sub-SOP
(YouTube, TikTok and Instagram built; all yt-dlp), stores the source MP4
in R2 and creates a `MusicVideo` record through `POST /api/v1/music_videos`: type
`music_video` (the default) or `cinematic` (`--kind cinematic`), platform, source
URL and id, title, duration and stage. It links the credited primary and featured
artists. Then, still on the Mac (a dyno has no ffmpeg), it cuts the whole video
into the recast pipeline's chunks (below, under Clips) and posts them, before
anyone is cast: one source's chunks serve every alt video made from it. A
re-digest keeps chunks already cut at the same tiling and replaces chunks of
another tiling only with `--retile`; `--no-tile` skips the chunks.

Captions are read for **timing and section structure only**. Lyric text is never
stored.

### 2. Cast

- The agent samples frames with **accurate seeks**: ffmpeg `-ss` before `-i`.
  Never take timestamps from the `fps=` filter; in the founding run it drifted
  from the real timeline.
- It groups on-screen people by visible cues (outfit, hair, eyewear, jewelry)
  into Person 1..N, each with stills and sightings. **Never face recognition.**
- The operator labels each person through a typeahead over people and artists;
  creating a new one is allowed.
- "Cast confirmed" advances the video. A `music_video` card closes on an artist
  or an extra; a `cinematic` video credits no artists, so its cards also close
  on the recast answer.
- **Recast.** On the same card the operator says who replaces the performer: an
  athlete (a Person with a look) and one of that athlete's looks, or "keep as
  is". It is stored on `video_performers` (`recast_person_slug`,
  `recast_appearance_slug`, `recast_keep`), is the operator's alone (the agent
  API refuses the keys), and can change after the cast is confirmed. Built by
  `recast-picker-on-cast-panel`, piece 2 of the recast pipeline.
- **Look dropdown.** The athlete's looks are a dropdown of rows
  (`MusicVideos::LookOptions`): the look's newest character sheet as a
  thumbnail, its name, the default mark and its sheet-build state, with a
  larger preview of the look picked. "Generate a new look" (or "Generate first
  look") makes a look from the card (`MusicVideos::CreateRecastLook`) and
  starts its sheet through `Appearances::SheetBuild`; the card polls
  `/recast_athletes/:slug/looks.json` and repaints when the sheet is ready.
  Admin only, since a sheet spends. Built by
  `recast-look-dropdown-and-generate`, piece 8 of the recast pipeline.

Built by `music-video-cast-panel`: the `video_performers` table,
`POST /api/v1/music_videos/:slug/performers`, and the panel at
`/music_videos/:slug`. The agent's steps are in
[`digest-video`](../agents/pokemon/sops/digest-video.md#stage-2-cast).

### 3. Artist references

For this video's look, the best references are stills of the performer from the
video itself. External images (Wikimedia Commons, the Spotify artist image) are
secondary and feed a general artist profile.

### 4. Per-video look

One look (`Appearance`) per performer per music video, built with the existing
character-sheet pipeline.

### 5. Clips

Several 25-second candidates per video. Each one:

- starts on a musical boundary;
- spans a seam: verse↔chorus, or singer 1↔singer 2;
- is continuous music, with no intro, outro or silence;
- carries a cast-shape label: solo, duo, trio, duo plus background, and so on;
- carries a filled Higgsfield swap prompt. The template is Alex's proven prompt,
  with blanks for the target performer's description, the athlete, and who stays
  the same. The athlete and look come from the target's recast
  (`MusicVideos::ClipPrompts`); every stored prompt of the video is rewritten
  when a recast changes. A `cinematic` video's prompt says "video", not "music
  video".

Built by `music-video-clip-finder`: `bin/find-clips`, the `video_clips` table,
`POST /api/v1/music_videos/:slug/clips`, and the clips list below the cast panel.
One approved clip moves the video to `clips_ready`. The agent's steps are in
[`digest-video`](../agents/pokemon/sops/digest-video.md#stage-5-clips).

**Chunks.** Beside the candidates, the digest (`bin/digest-video`), or
`bin/find-clips <slug> --tile` for an older source or a new tiling, cuts the whole
video into 25-second chunks on a 20-second stride (0-25, 20-45, 40-65 and on), so
each shares 5 seconds with the one before. Chunk length and overlap are
parameters (`--chunk`, `--overlap`); the video records the pair its chunks were
cut with. The last chunk ends at the video's end
and may be shorter; a tail the previous chunk already covers makes no extra
chunk. A chunk has no seam and no approval. Chunks are `video_clips` rows of kind
`chunk`; the candidates are kind `candidate`. Each kind numbers its own ordinals
and is replaced on its own. Chunks need no confirmed cast (the candidates do):
cut at digest they are `unknown` with the generic prompt, and the hub relabels
them from the cast when the vision pass posts it and when the cast is confirmed
(`MusicVideos::LabelChunks`). Built by `tile-video-into-overlapping-chunks`, the
first piece of the recast pipeline, which swaps every chunk and stitches them
back; moved into the digest by `digest-cuts-chunks-on-upload`. The steps are in
[`digest-video`](../agents/pokemon/sops/digest-video.md#chunks-the-whole-video-tiled).

**Generated takes and the stitch preview.** The operator swaps each chunk by
hand and uploads the generated MP4 back on the chunk's row, which also carries
the hand-off: the source chunk as a download, the prompt, and the recast look's
character sheet. Each upload is a numbered take in `video_chunk_takes`, kept and
never overwritten; the newest is current unless the operator puts an older one
back. A chunk can be flagged "request regenerate" with a note; the next take
clears it. A preview player plays the current takes back to back as if stitched,
without a stitched file: it hands over at the middle of each overlap
(`MusicVideos::StitchTimeline`), falls back to a chunk's source cut where there
is no take, and plays the original source audio underneath with the clips
muted. `MusicVideo#ready_to_stitch?` is true when every chunk has a current take
and none is flagged; the final stitch reads it, and each chunk's file from
`VideoClip#current_take`. Built by `generated-takes-and-stitch-preview`, piece 3
of the recast pipeline. The steps are in
[`digest-video`](../agents/pokemon/sops/digest-video.md#generated-takes-and-the-stitch-preview).

**The final stitch.** "Generate full video", on once the video is ready to
stitch, records a numbered stitch in `video_stitches` with the take each chunk
has at that moment. ffmpeg crossfades the picture of consecutive takes across
each overlap, lays the original source audio under the whole length untouched,
and writes H.264 and AAC in MP4 to the video's `stitched/` folder. The plan is
`MusicVideos::StitchPlan` (pure: inputs, the frames each chunk owns, crossfade
offsets, the filter graph, the ffmpeg arguments), run by
`MusicVideos::Stitcher`. Takes are normalised to the best any take offers and
never more than the source, in size and in frame rate. A stitch is `requested`,
`running`, then `done` or `failed` with the reason. The page shows the latest
with a player and a download, and marks it stale once a chunk has a different
current take or a regenerate flag, or the video is re-tiled. Every stitch is
kept. Built by `stitch-takes-into-full-video`, piece 4 of the recast pipeline.
The steps are in
[`digest-video`](../agents/pokemon/sops/digest-video.md#the-final-stitch).

## Where it runs

The SOPs are agent-driven and run on Alex's Mac: YouTube often blocks cloud IPs,
and the cast step is an agent vision pass. The app stores results through a small
JSON API and gives the UI. Nothing Mac-specific goes in the app, so the agent side
can move off the Mac later.

The final stitch needs ffmpeg, and production dynos have none. So the stitch is
one library with two callers: `bin/stitch-video <slug>` on the Mac, which
fulfils a request through the API, and `StitchVideoJob`, which the button
enqueues only where ffmpeg is on `PATH` (a local hub). On production a request
stays `requested` until the Mac runs the bin.

## Data model

Record slugs stay kebab-case, the app's existing convention.

| Table | Holds |
|---|---|
| `music_videos` | type (`kind`: `music_video` or `cinematic`), the chunk tiling (`chunk_ms`, `chunk_overlap_ms`; null until tiled), platform, source URL and id, title, duration, stage, source asset |
| `artists` | kind `person` or `group`; `person_slug` for individuals; source ids: Wikidata, MusicBrainz, Discogs, Spotify |
| `artist_aliases` | alternate names per artist |
| `artist_memberships` | member → group, start and end years |
| `music_video_artists` | video ↔ artist, role `primary` or `featured`. Groups such as Migos are credited directly |
| `video_performers` | Person N, linked artist (nullable), stills, sightings, confidence; the recast: athlete (`recast_person_slug`), look (`recast_appearance_slug`), or `recast_keep` |
| `appearances` | gains a nullable music video link |
| `video_clips` | kind (`candidate` or `chunk`), start, end, seam (candidates only), cast shape, target performer, prompt, asset, status; on a chunk, the regenerate flag (`regenerate_requested_at`, `regenerate_note`) |
| `video_chunk_takes` | one generated MP4 uploaded back for a chunk: video (`music_video_slug`), `chunk_ordinal`, the chunk's window (`start_ms`, `end_ms`), take `number`, asset, size, and `current_since` (the latest is the current take) |
| `video_stitches` | one full-length stitch: video (`music_video_slug`), stitch `number`, `state` (`requested`, `running`, `done`, `failed`) with `failure_reason`, the take each chunk had (`takes`: ordinal, window, take number), asset, and the result's duration, size, frame size, frame rate and notes |

## Artist seed

1. **Wikidata first** (CC0): occupation rapper (Q2252262); groups through member
   of (P463) and has part (P527), with dates; aliases; cross-ids.
2. **Gaps from MusicBrainz** (core data CC0, PostgreSQL dump): artist type
   Person or Group, aliases, member-of-band relationships.
3. **Gaps from Discogs** (CC0 monthly XML dumps): aliases, groups, members.

**Relevance filter:** an English Wikipedia article, or a sitelink threshold.
**Scope:** rappers, and hip-hop, R&B and pop artists and groups with their members.

## R2 storage

Writes go to the hub's existing R2 buckets, `mcritchie-studio-dev` and
`mcritchie-studio-production` (credentials: 1Password item `r2.mcritchie-studio`). Names and
folders are human-readable **snake_case**. Alex amended the asset library's
"object keys carry no meaning" rule for this content on 2026-09-29
([`asset-library-plan.md`](asset-library-plan.md)).

```text
music_videos/<artist>/<video>/source/<artist>_<video>_feat_<…>.mp4
music_videos/<artist>/<video>/stills/person_01_0230.jpg
music_videos/<artist>/<video>/clips/<video>_clip_01_<seam>_<shape>_<start>_<end>.mp4
music_videos/<artist>/<video>/chunks/<video>_chunk_01_<start>_<end>.mp4
music_videos/<artist>/<video>/generated/<video>_chunk_01_<start>_<end>_take_01.mp4
music_videos/<artist>/<video>/stitched/<video>_stitched_01.mp4
music_videos/<artist>/<video>/looks/person_01_<name>_<video>/character_sheet.png
artists/<artist>/…                      general artist images
```

## Rights stance

Captions are used for timing only. Publishing is low-stakes social posts, by
Alex's decision.

## Cards

Already filed, in build order:

1. `artist-seed-from-wikidata`
2. `digest-video-youtube`
3. `music-video-cast-panel`
4. `music-video-clip-finder`
5. `tile-video-into-overlapping-chunks`
6. `digest-cuts-chunks-on-upload`

Alongside: `asset-tree-browser`. Later, not yet filed: measuring the TikTok download
and the Instagram cookie path, the artist reference and look stages, and the pipeline 4
hand-off.
