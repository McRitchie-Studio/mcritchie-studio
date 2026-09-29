# Download Instagram

## Status: Active

The Pokémon's `download-instagram` SOP: the Instagram sub-SOP of
[`digest-video`](digest-video.md).

**UNMEASURED.** Instagram often refuses anonymous downloads and needs a logged-in
browser cookie. No run in this pipeline has confirmed either path. Record what the
first run finds here.

## 1. Try anonymously

```bash
yt-dlp --merge-output-format mp4 --write-info-json \
  -o "%(id)s.%(ext)s" "<url>"
```

## 2. If it asks for a login, use the browser's cookie

```bash
yt-dlp --cookies-from-browser chrome \
  --merge-output-format mp4 --write-info-json \
  -o "%(id)s.%(ext)s" "<url>"
```

The cookie is Alex's session. Never write it to a file in a repo, and never print it.

## 3. Check the codec

If `ffprobe` reports anything but `h264`, convert as in
[`download-youtube`](download-youtube.md) step 3.

## 4. Hand back

Return the MP4 path and its `.info.json` path to `digest-video`.
