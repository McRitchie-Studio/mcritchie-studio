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

**Iced twins and jewelry.** Every look gets an iced-out twin, a look of its own
("Cowboys white · iced") whose sheet adds shades, a chain, a watch, a bracelet, a
grill and rings. The rings are the person's own when their jewelry is on file
(`person_jewelries`, kept on the person page), else generic. Making a twin is a
free row; each sheet is a paid build, chosen when the look is made. The
operator's steps are in
[`digest-video`](../agents/pokemon/sops/digest-video.md#stage-2-cast) (the cast
card's Generate a look), and the build is in `docs/topics/content-pipeline.md`,
"The iced-out twin and a person's jewelry".

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

**Alt videos and the clip builder.** A source video (a `music_videos` row,
"Source video" on screen) yields many alt videos, each one generated version
with its own swaps. **Build Clips** in the cast summary bar makes the source's
next `alt_videos` row, numbered per source, with the cast cards' swaps
snapshotted into its `swaps` jsonb, and one `alt_video_clips` row per chunk.
The snapshot is jsonb, not a child table, because it is written once, read
whole and never edited (as `video_stitches.takes`); a later edit of the cast
cards changes no alt video. The clip card, on
`/music_videos/<slug>/alt_videos/<n>`, hands off the source chunk, the swapped
people's character sheets and the prompt (`MusicVideos::ClipPrompts.for(chunk,
swaps:)` fed the snapshot, who is on screen read from the chunk), and takes the
generated MP4 by drag and drop. Each upload is a numbered version in
`alt_video_clip_versions`, kept; the latest `primary_since` is the primary, so
exactly one holds by construction. Versions are their own table because a clip
exists before any version and keeps every upload. Once a clip has a primary
the card plays it beside the source chunk, both on their first frame, with
**Play both** (original muted, the version the clock; `clipPair()`, piece 18). A clip can be flagged
"request regenerate"; the next upload clears it. **Watch full video** opens a
modal that plays the primaries back to back as if stitched
(`MusicVideos::StitchTimeline`, handover mid-overlap, source audio, the source
chunk where a clip has no version). Every file on the page is a signed URL
good for fifteen minutes, and the page is left open far longer, so it keeps
them fresh: `GET /music_videos/<slug>/alt_videos/<n>/links` answers the page's
own keys signed again (it reads no key from the request), and `signedLinks`
(`music_videos/_player_scripts`) swaps them in a minute before they lapse, on
coming back to the tab, and when a player fails on a lapsed link, keeping each
player's place. A player says "This link expired: getting a fresh one…" while
it waits, and reports a missing file only when it fails on a fresh link
(`clip-page-links-refresh`, shipped to `accepted` on 2026-10-08). The refresh
ends with its page: a Turbo visit away stops it. When fresh links cannot be had,
the page says whether the session ended or the server did not answer, and the
player says its link expired (`recast-wrap-loose-ends`). The source video page
(the cast page) is still on fifteen-minute links: its previews are not
refreshed, and a reload is what renews them.
`/alt_videos` lists every alt video with
its progress. Built by `generated-takes-and-stitch-preview` (piece 3) and
reshaped by `alt-videos-and-clip-builder` (piece 13). The steps are in
[`digest-video`](../agents/pokemon/sops/digest-video.md#alt-videos-and-the-clip-builder).

**The asset zip.** The clip card's hand-off also downloads as one zip, a clip's
or the whole alt video's: each clip's source chunk, prompt, lettered frames and
numbered character sheets, with a README that lists anything left out. It
streams from R2 and never fails for a missing file. A sheet image is fetched
only from an https public host, at the address the host was vetted against, and
one entry spends at most five seconds opening connections. Built by piece 17
(`MusicVideos::AssetZip`, `AltVideoDownloadsController`). The steps and the
zip's layout are in
[`digest-video`](../agents/pokemon/sops/digest-video.md#alt-videos-and-the-clip-builder).

**Lettered references.** The clip prompt (`MusicVideos::ClipPrompts`, wording
in `MusicVideos::ClipPrompt.lettered`) names people by a letter fixed per
source (`MusicVideos::PersonLetters`: Person N is the Nth letter) and players by
the look's `appearances.jersey_number`, read live at render, with one line per
swapped person in the window: lead (the chunk's target, or two clear sightings
in the window: lip-synced) or background. Sheets are numbered in the card's
download order. A window that swaps nobody keeps the single-target prompt. Each
chunk can carry 2-4 lettered reference frames (`video_clips.reference_frames`,
jsonb `[{ object_key, t_ms, letters }]`, written whole by `bin/clip-references
--apply` through `POST /api/v1/music_videos/:slug/chunks/:ordinal/references`);
the agent places the tags by eye, ImageMagick draws them on the Mac. Built by
`lettered-clip-references`, piece 16. The steps are in
[`digest-video`](../agents/pokemon/sops/digest-video.md#lettered-references).

**The final stitch.** "Generate full video", on an alt video once every clip
has a primary version and none is flagged (`AltVideo#ready_to_stitch?`),
records a numbered stitch of that alt video in `video_stitches` with the
version each clip has as primary at that moment. ffmpeg crossfades the picture
of consecutive versions across each overlap, lays the original source audio
under the whole length untouched, and writes H.264 and AAC in MP4 to the alt
video's `stitched/` folder. The plan is
`MusicVideos::StitchPlan` (pure: inputs, the frames each chunk owns, crossfade
offsets, the filter graph, the ffmpeg arguments), run by
`MusicVideos::Stitcher`. Takes are normalised to the best any take offers and
never more than the source, in size and in frame rate. A stitch is `requested`,
`running`, then `done` or `failed` with the reason. The page shows the latest
with a player and a download, and marks it stale once a clip has a different
primary version or a regenerate flag. Every stitch is kept. Built by `stitch-takes-into-full-video`, piece 4 of the recast pipeline.
The steps are in
[`digest-video`](../agents/pokemon/sops/digest-video.md#the-final-stitch).

### 6. TikTok draft

A clip's primary version goes to the operator's TikTok inbox, from **Draft to
TikTok** on the clip card or from chat with the clip's slug
(`bin/tiktok-draft`). Code writes the caption from the lead swapped athlete's
team and its record; TikTok does not receive it, so the operator pastes it in
the app, turns on the AI-generated label and posts from his phone. Nothing
here publishes. It needs the hub's teams loaded and a look that names one of
them, and a TikTok account connected at `/admin/tiktok`. Built by piece 19
(`Tiktok::DraftClip`, `tiktok_drafts`). The whole procedure, the setup and the
sandbox's limits are in Turf Monster's
[`tiktok-draft`](../agents/turf_monster/sops/tiktok-draft.md).

## Where it runs

The SOPs are agent-driven and run on Alex's Mac: YouTube often blocks cloud IPs,
and the cast step is an agent vision pass. The app stores results through a small
JSON API and gives the UI. Nothing Mac-specific goes in the app, so the agent side
can move off the Mac later.

The final stitch needs ffmpeg, and production dynos have none. So the stitch is
one library with two callers: `bin/stitch-video <slug> --alt <n>` on the Mac, which
fulfils a request through the API, and `StitchVideoJob`, which the button
enqueues only where ffmpeg is on `PATH` (a local hub). On production a request
stays `requested` until the Mac runs the bin.

Lettered reference frames are made on the Mac too (`bin/clip-references`):
ffmpeg stills the source, the agent places the tags, and ImageMagick (`magick`)
draws them, since the Homebrew ffmpeg has no `drawtext`.

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
| `appearances` | gains a nullable music video link, and `jersey_number` (0-99, nullable): the number a look wears, named in clip prompts |
| `video_clips` | kind (`candidate` or `chunk`), start, end, seam (candidates only), cast shape, target performer, prompt, asset, status. Chunks are cut once per source and shared by every alt video, with their lettered `reference_frames` (jsonb: object key, time, letters). The chunk regenerate columns are piece 3's, now unread |
| `alt_videos` | one generated version of a source: `slug` (`<source>-alt-<n>`), source (`music_video_slug`), `number` per source, and `swaps` (jsonb snapshot: performer ordinal, person and look slugs and names) |
| `alt_video_clips` | alt video (`alt_video_slug`) × chunk: `chunk_ordinal`, the chunk's window (`start_ms`, `end_ms`), the regenerate flag (`regenerate_requested_at`, `regenerate_note`) |
| `alt_video_clip_versions` | one generated MP4 uploaded back for a clip (`alt_video_clip_id`): version `number`, asset, size, file name, and `primary_since` (the latest is the primary) |
| `video_chunk_takes` | piece 3's takes, moved onto alt video 1 of their source by `CreateAltVideos`; kept, read by nothing, for a later drop |
| `video_stitches` | one full-length stitch of an alt video (`alt_video_slug`; `music_video_slug` is its source): stitch `number` per alt video, `state` (`requested`, `running`, `done`, `failed`) with `failure_reason`, the version each clip had (`takes`: ordinal, window, version number), asset, and the result's duration, size, frame size, frame rate and notes |

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
music_videos/<artist>/<video>/chunks/refs/<video>_chunk_01_<start>_<end>_ref_01.jpg   lettered reference frames
music_videos/<artist>/<video>/alt_videos/01/clips/<video>_alt_01_chunk_01_<start>_<end>_v01.mp4
music_videos/<artist>/<video>/alt_videos/01/stitched/<video>_alt_01_stitched_01.mp4
music_videos/<artist>/<video>/generated/…  and  stitched/…   piece 3-4 objects, kept in place
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
