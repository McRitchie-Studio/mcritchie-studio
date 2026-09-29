# Download TikTok

## Status: Active

The Pokémon's `download-tiktok` SOP: the TikTok sub-SOP of
[`digest-video`](digest-video.md). `bin/digest-video <url>` runs it for
`tiktok.com`, `www.tiktok.com/@<user>/video/<id>`, `vm.tiktok.com` and
`vt.tiktok.com` links.

**Download UNMEASURED.** A `yt-dlp --simulate --dump-json` run on 2026-09-29
(yt-dlp 2026.08.19, TikTok's own `@tiktok` account, nothing downloaded) found
muxed `h264`/`aac` formats alongside `h265` ones, a canonical
`https://www.tiktok.com/@<user>/video/<id>` page URL, and `channel`, `uploader`
and `uploader_id` set; `creator` was absent. No full download in this pipeline
has run yet. Record what the first one finds here.

## 1. Download

The script prefers a muxed H.264 file and fetches no captions:

```bash
yt-dlp -f "b[vcodec^=h264]/b[vcodec^=avc1]" \
  --merge-output-format mp4 --write-info-json \
  -o "%(id)s.%(ext)s" "<url>"
```

A short link (`vm.tiktok.com/<code>`) carries no id; the script reads it from
the `.info.json`.

## 2. Check the codec

If no H.264 format exists, the script downloads the best one and converts it as
in [`download-youtube`](download-youtube.md) step 3 (H.265 to H.264, audio to
AAC).

## 3. What is kept

A TikTok title is its caption, free text, so it is never stored:

- The record's title is `TikTok <id>`, so the R2 tree is
  `music_videos/<creator>/tiktok_<id>/source/...`.
- Credits are the creator (`channel`, else `uploader`) as primary, then any
  `feat.`, `ft.` or `(with …)` names the credit parser finds in the caption's
  first line, with hashtags dropped and `@` stripped from mentions. A run longer
  than four words is prose, not a name, and is dropped. The hub files each name
  that matches no artist, or more than one, under `unresolved_credits`.
- The stored `.info.json` keeps the YouTube allowlist without `title`, plus
  `uploader_id`. It drops the description, tags, comments, the sound's track
  name and every signed URL.

## 4. Hand back

Return the MP4 path and its `.info.json` path to `digest-video`.
