# Digest Video

## Status: Active

The Pokémon's `digest-video` SOP: stage 1 of pipeline 3 in the
[music video pipeline plan](../../../system/music-video-pipeline-plan.md). Alex
says `digest video <url>`; the agent downloads the video, stores it, and records
it so the cast stage can start.

It runs on Alex's Mac, where the download works; YouTube often blocks cloud IPs.

Steps marked **PLANNED** are not built yet; the card named beside each builds it.
Until then, stop after the download and report the local file.

## 1. Pick the sub-SOP by host

| Host | Sub-SOP | State |
|---|---|---|
| `youtube.com`, `youtu.be` | [`download-youtube`](download-youtube.md) | measured 2026-09-28 |
| `tiktok.com` | [`download-tiktok`](download-tiktok.md) | UNMEASURED |
| `instagram.com` | [`download-instagram`](download-instagram.md) | UNMEASURED |

Any other host: stop and ask Alex.

## 2. Download

Run the sub-SOP. It leaves an H.264 MP4 and its `.info.json` in a working folder.
Confirm the MP4 plays and read its duration:

```bash
ffprobe -v error -show_entries format=duration -of csv=p=0 <file>.mp4
```

## 3. Store the source in R2 — PLANNED (`digest-video-youtube`)

Upload the MP4 to the hub's bucket (`r2.mcritchie-studio`) at the snake_case key
the plan names:

```text
music_videos/<artist>/<video>/source/<artist>_<video>_feat_<…>.mp4
```

## 4. Create the MusicVideo record — PLANNED (`digest-video-youtube`)

Post to the hub's JSON API. The record carries:

- type `music_video` (the only type for now);
- platform, source URL and source id (from `.info.json`);
- title, duration, and stage `digested`;
- the credited artists: each `primary` or `featured`. A group such as Migos is
  credited directly. Artists come from the seed built by `artist-seed-from-wikidata`.

## 5. Captions: timing only

If the sub-SOP fetched captions, keep only their **timestamps and section
structure** for the clip stage. Never store lyric text.

## 6. Report

Report the video's title, duration, the R2 key (or the local path while step 3 is
PLANNED) and the credited artists. The next act is the cast stage, built by
`music-video-cast-panel`.

## Related

- [Music video pipeline plan](../../../system/music-video-pipeline-plan.md): the
  stages, data model and R2 tree.
- [`object-storage.md`](../../../modules/object-storage.md): the R2 buckets.
