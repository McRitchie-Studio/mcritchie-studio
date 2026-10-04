# Download Instagram

## Status: Active

The Pokémon's `download-instagram` SOP: the Instagram sub-SOP of
[`digest-video`](digest-video.md). `bin/digest-video <url>` runs it for
`instagram.com` links of the form `/reel/<code>`, `/reels/<code>`, `/p/<code>`
and `/tv/<code>`, each also under a `/<handle>/` prefix.

**Anonymous download measured 2026-10-04** on Alex's Mac (yt-dlp 2026.08.19,
five public posts). **The cookie path is UNMEASURED**: the one attempt waited
45 seconds on a macOS Keychain prompt and was stopped. Record what the first
cookie run finds here.

## 1. Download anonymously

The script prefers H.264 video plus the audio track, and fetches no captions:

```bash
yt-dlp -f "bv*[vcodec^=avc1]+ba/b[vcodec^=avc1]/b[vcodec^=h264]" \
  --merge-output-format mp4 --write-info-json \
  -o "%(id)s.%(ext)s" "<url>"
```

What the measured runs found:

- **A reel is portrait.** The formats were 720x1280 H.264 with a separate AAC
  track. The YouTube selector's `height<=1080` shuts the 1280 format out and
  leaves 480x854, so this selector has no height cap.
- **Some public posts download with no session, and some do not.** Two reels
  and a three-video post came down; two other public posts answered `Instagram
  sent an empty media response`, which is the login wall of step 2.
- **A reel can have no audio.** Instagram marked one test reel `has_audio:
  false`, and its MP4 held a video stream only. The script refuses a file with
  no audio track: a music video needs one.
- **`duration` is absent** from the `.info.json`; the script reads it with
  `ffprobe`.

## 2. If it asks for a login, lend the browser's session

The script stops at the first login wall and names the flag; it does not retry
on its own, because a second anonymous try only spends the rate limit.

```bash
bin/digest-video <url> --cookies-from-browser chrome
```

The flag passes straight to yt-dlp. The cookie is Alex's session. Never write
it to a file in a repo, and never print it. yt-dlp writes the session into the
`.info.json` it leaves in the working folder (the `cookies` and `http_headers`
fields), so on a cookie run the script strips both from every `.info.json` in
that folder as soon as yt-dlp returns, on success or failure.

macOS asks for the Keychain password the first time yt-dlp reads Chrome's
cookies. Alex answers that prompt; an agent cannot.

## 3. Links the script refuses

| Link | Why | What to do |
|---|---|---|
| `/share/reel/<token>` | It carries no post code, and yt-dlp does not read it | Open it and paste the `/reel/` or `/p/` URL it lands on (UNMEASURED: no real share link has been tried) |
| A post with several videos | yt-dlp returns a playlist, one file per video | Ask Alex which video; a digest takes one |
| A profile, a story or a tag page | It names no single post | Paste the post's own URL |

## 4. Check the codec

If no H.264 format exists, the script downloads the best one and converts it as
in [`download-youtube`](download-youtube.md) step 3 (audio to AAC). Every
measured format was already H.264, so the conversion is UNMEASURED on Instagram.

## 5. What is kept

An Instagram title is `Video by <handle>` or free text, and the caption is the
description, so neither is stored:

- The record's title is `Instagram <code>`, so the R2 tree is
  `music_videos/<creator>/instagram_<code>/source/...`. The key lowercases the
  code, so two codes from one creator that differ only by letter case would
  share a key; none has been seen.
- The source URL is the post's own page, `https://www.instagram.com/<reel|p|tv>/<code>/`,
  without the handle prefix or the tracking query (`?igsh=…`).
- Credits are the creator's display name (`uploader`, else the handle in
  `channel`) as primary, then any `feat.`, `ft.` or `(with …)` names in the
  caption's first line, by the rules in [`download-tiktok`](download-tiktok.md)
  step 3. The hub files each name that matches no artist, or more than one,
  under `unresolved_credits`.
- The stored `.info.json` keeps the TikTok allowlist: the YouTube one without
  `title`, plus `uploader_id`. It drops the description, comments, request
  headers and every signed URL.

## 6. Hand back

Return the MP4 path and its `.info.json` path to `digest-video`.
