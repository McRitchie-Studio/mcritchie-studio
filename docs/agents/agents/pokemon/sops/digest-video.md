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
```

It writes the dev bucket unless `--production` is passed.

## 1. Pick the sub-SOP by host

| Host | Sub-SOP | State |
|---|---|---|
| `youtube.com`, `youtu.be` | [`download-youtube`](download-youtube.md) | measured 2026-09-28 |
| `tiktok.com` | [`download-tiktok`](download-tiktok.md) | UNMEASURED; the script prints `not built yet` |
| `instagram.com` | [`download-instagram`](download-instagram.md) | UNMEASURED; the script prints `not built yet` |

Any other host: stop and ask Alex.

## 2. Download

Run the sub-SOP. It leaves an H.264 MP4 and its `.info.json` in a working folder.
Confirm the MP4 plays and read its duration:

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
through `bin/secret`; no value is printed. The stored `.info.json` drops the
`description`, which can quote lyrics.

## 4. Create the MusicVideo record

The script posts to `POST /api/v1/music_videos` (bearer token from
`/api/v1/auth`); `GET /api/v1/music_videos/<slug>` reads it back. A second post of
the same video answers 200 with the record it already has. The record carries:

- type `music_video` (the only type for now);
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
unresolved credits; the script prints all of them. The next act is the cast stage, built by
`music-video-cast-panel`.

## Related

- [Music video pipeline plan](../../../system/music-video-pipeline-plan.md): the
  stages, data model and R2 tree.
- [`object-storage.md`](../../../modules/object-storage.md): the R2 buckets.
