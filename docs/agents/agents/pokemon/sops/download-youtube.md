# Download YouTube

## Status: Active

The Pokémon's `download-youtube` SOP: the YouTube sub-SOP of
[`digest-video`](digest-video.md). Facts measured 2026-09-28 on Alex's Mac.

## Tools

- `yt-dlp` is installed at `~/.local/bin/yt-dlp`.
- `ffmpeg` and `ffprobe` convert and inspect.

## 1. Download the whole video

`bin/digest-video` runs this step and step 3 for you. Prefer H.264 at up to
1080p, keep the info JSON for provenance, and fetch captions for timing:

```bash
yt-dlp -f "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]" \
  --merge-output-format mp4 --write-info-json \
  --write-subs --write-auto-subs --sub-format vtt --sub-langs "en,en-orig" \
  -o "%(id)s.%(ext)s" "<url>"
```

Ask for `en,en-orig` only. `en.*` also matched every auto-translated track
(`en-zh-Hans`, …); on 2026-10-04 YouTube answered HTTP 429 on one of them and
yt-dlp aborted the whole download. If a caption track is still refused, the
script downloads again without captions and the record has no timing.

A video with no captions (Night Call, measured 2026-09-29) gets no `.vtt`; its
timing is empty.

The script deletes each `.vtt` once the record is created, since the file holds
lyric text; a dry run or a failed run keeps it for a `--from-dir` retry. It stores a copy of the `.info.json` that keeps only `id`,
`title`, `uploader`, `channel`, `channel_id`, `upload_date`, `duration`,
`webpage_url`, `extractor`, `width`, `height`, `fps`, `vcodec` and `acodec`. It
drops the description, tags and chapters, which can quote lyrics, and every
signed URL, which embeds the operator's public IP. It logs in to the hub API
before it uploads anything.

## 2. Or download one section

```bash
yt-dlp -f "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]" \
  --download-sections "*<start>-<end>" --force-keyframes-at-cuts \
  --merge-output-format mp4 --write-info-json \
  -o "%(id)s_%(section_start)s.%(ext)s" "<url>"
```

## 3. If only VP9 exists

QuickTime cannot play VP9. When the H.264 format selector finds nothing, download
the best format and convert. Audio goes to AAC, never `copy`: Opus in an MP4
will not play in QuickTime.

```bash
ffmpeg -i <input> -c:v h264_videotoolbox -b:v 8M -c:a aac -b:a 192k \
  -movflags +faststart <output>.mp4
```

`h264_videotoolbox` is the Mac's hardware encoder. Off the Mac, use `libx264`
(`bin/digest-video --encoder libx264`).

## 4. Hand back

Return the MP4 path and its `.info.json` path to `digest-video`.
