---
question: "Alex McRitchie wants a brand's marketing kit, new or refreshed. Do I make the files in Drive myself?"
answer: "No. Run the marketing-kit SOP: one spec, bin/marketing-kit pngs, build, publish. A refresh starts from the spec in the kit's 01 Brand/Kit source."
why: "The publisher sees only files it made, so hand-made ones get duplicated, and the template gallery refuses an uploaded Doc."
status: proposed
source: "2026-10-31 · task marketing-kit-draws-its-pngs"
topic: [marketing, kit, brand, template]
---

# Build a kit from its spec

## Situation

A brand needs a marketing kit, or an existing kit needs new logos, colours or
words. Drive, a Docs connector and the brand's logos are all at hand.

## The pull

Make or edit the Docs, Slides and folders directly: it looks faster than a
spec, a build and a publish, and the result looks the same on screen.

## What happened

Kits built and refreshed through the spec came out the same every time, and
the code fixed problems for every kit at once: the folder name, the domain
shares, and templates the gallery accepts. Where files were handled outside
it, they broke. The Drive credential holds only `drive.file`, so the
publisher could not see or rename a file a person had made, and would build a
second kit beside a hand-made one. The template gallery refused every Doc
that had been uploaded through the API until it was copied. In the same
session, a session drew a horizontal logo with the square-only icon script
and got a padded square, which is why `bin/marketing-kit pngs` exists.
