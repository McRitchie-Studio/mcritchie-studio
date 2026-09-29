# Download YouTube

## Status: Active

The Pokémon's `download-youtube` SOP: the YouTube sub-SOP of
[`digest-video`](digest-video.md). Facts measured 2026-09-28 on Alex's Mac.

## Tools

- `yt-dlp` is installed at `~/.local/bin/yt-dlp`.
- `ffmpeg` and `ffprobe` convert and inspect.

## 1. Download the whole video

Prefer H.264 at up to 1080p, and keep the info JSON for provenance:

```bash
yt-dlp -f "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]" \
  --merge-output-format mp4 --write-info-json \
  -o "%(id)s.%(ext)s" "<url>"
```

## 2. Or download one section

```bash
yt-dlp -f "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]" \
  --download-sections "*<start>-<end>" --force-keyframes-at-cuts \
  --merge-output-format mp4 --write-info-json \
  -o "%(id)s_%(section_start)s.%(ext)s" "<url>"
```

## 3. If only VP9 exists

QuickTime cannot play VP9. When the H.264 format selector finds nothing, download
the best format and convert:

```bash
ffmpeg -i <input> -c:v h264_videotoolbox -b:v 8M -c:a copy \
  -movflags +faststart <output>.mp4
```

`h264_videotoolbox` is the Mac's hardware encoder. Off the Mac, use `libx264`.

## 4. Hand back

Return the MP4 path and its `.info.json` path to `digest-video`.
