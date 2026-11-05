---
question: "I drew a box over a number in a PDF and it looks hidden. Can I send it?"
answer: "No. Run flatten-document: render to page images, confirm no text or fonts remain, then read every mask at full zoom."
why: "The box is a layer on top; pdftotext still read the number under it. A text check cannot see a short box, so read the pages too."
status: proposed
source: "2026-11-04 · task document-flatten-sop-dream"
soul: pokemon
topic: [pdf, flatten, redact, annotation, image]
---

# A drawn box hides nothing

## Situation

Alex McRitchie asked for documents with masked numbers to be flattened, so nobody
could read behind the boxes.

## The pull

The boxes look right on screen, and a quick render confirms it. The tempting move is
to print to PDF or render with the first tool to hand, then report the file as done.

## What happened

The sources still held the full number in their text layer. Pixel-only copies removed
it, and text, font and image checks proved that. One render tool also dropped the
annotations without a word, which would have shown the number, and only reading the
page caught it. The session also learned too late that the reader had asked for
unmarked copies, so the SOP now starts by reading the request.
