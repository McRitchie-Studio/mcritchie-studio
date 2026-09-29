# Download TikTok

## Status: Active

The Pokémon's `download-tiktok` SOP: the TikTok sub-SOP of
[`digest-video`](digest-video.md).

**UNMEASURED.** yt-dlp downloads TikTok anonymously, but no run in this pipeline
has confirmed it. Record what the first run finds here.

## 1. Download

```bash
yt-dlp --merge-output-format mp4 --write-info-json \
  -o "%(id)s.%(ext)s" "<url>"
```

## 2. Check the codec

```bash
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
  -of csv=p=0 <file>.mp4
```

If it is not `h264`, convert as in
[`download-youtube`](download-youtube.md) step 3.

## 3. Hand back

Return the MP4 path and its `.info.json` path to `digest-video`.
