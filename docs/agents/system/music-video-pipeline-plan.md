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
(YouTube built; TikTok and Instagram not yet; all yt-dlp), stores the source MP4
in R2 and creates a `MusicVideo` record through `POST /api/v1/music_videos`: type `music_video` (the only type for now), platform, source URL and id,
title, duration and stage. It links the credited primary and featured artists.

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
- "Cast confirmed" advances the video.

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
  the same.

## Where it runs

The SOPs are agent-driven and run on Alex's Mac: YouTube often blocks cloud IPs,
and the cast step is an agent vision pass. The app stores results through a small
JSON API and gives the UI. Nothing Mac-specific goes in the app, so the agent side
can move off the Mac later.

## Data model

Record slugs stay kebab-case, the app's existing convention.

| Table | Holds |
|---|---|
| `music_videos` | type, platform, source URL and id, title, duration, stage, source asset |
| `artists` | kind `person` or `group`; `person_slug` for individuals; source ids: Wikidata, MusicBrainz, Discogs, Spotify |
| `artist_aliases` | alternate names per artist |
| `artist_memberships` | member → group, start and end years |
| `music_video_artists` | video ↔ artist, role `primary` or `featured`. Groups such as Migos are credited directly |
| `video_performers` | Person N, linked artist (nullable), stills, sightings, confidence |
| `appearances` | gains a nullable music video link |
| `video_clips` | start, end, cast shape, target performer, prompt, asset |

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

Alongside: `asset-tree-browser`. Later, not yet filed: measuring the TikTok and
Instagram sub-SOPs, the artist reference and look stages, and the pipeline 4
hand-off.
