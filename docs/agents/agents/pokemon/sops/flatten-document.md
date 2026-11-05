# Flatten Document
<!-- registry: burn annotations and masks into a PDF or image so the content under them cannot be read, and prove it -->

## Status: Active

The Pokémon's `flatten-document` SOP. It turns a marked-up file into page images,
so a box drawn over a number really hides the number. Run it when Alex McRitchie
asks to flatten, redact or mask a file, or before a marked-up file goes outside.

A drawn box hides nothing. The text stays in the file under it: anyone can select
it, copy it, or read it with `pdftotext`. Flattening removes that text. The output
has pixels only.

## Prerequisites

Poppler (`pdftoppm`, `pdftotext`, `pdffonts`, `pdfimages`, `pdfinfo`), ImageMagick
(`magick`) and, for the PDFKit path, the Swift compiler (`swiftc`). Check them with
`pdftoppm -v` and `magick -version`. Measured on 2026-11-04, on ImageMagick 7.1.2 and
Poppler 26.09.0.

## 1. Check that a marked copy is what the recipient wants

Read the request the file answers before you flatten (`bin/mail thread '<gmail query>'`).
A bank or a court can ask for full or unmarked copies, and a masked copy then fails.
If the request says that, or says nothing, stop and ask Alex McRitchie whether a mask
is acceptable. Do not contact the recipient yourself: he asks, or he names who does.

## 2. Look at the source

```bash
pdfinfo "<source.pdf>"           # the page count and the producer
pdffonts "<source.pdf>"          # the "emb" column: "no" means an unembedded font
pdftotext "<source.pdf>" - | grep -c "<last four of the secret>"
```

Search for a fragment only. A full secret in a command stays in the shell history
and in the session log. Keep the source: never overwrite it, and write to a new
`<name>-flattened.pdf`. The source still holds the secret, so do not send it.

## 3. Render every page at 300 DPI

Work in a new folder in your scratchpad, one folder per source file. The pages are
sensitive, sibling agents share the scratchpad, and step 4's glob takes every `page-*`.

**Fonts all embedded:** use Poppler. It draws annotations.

```bash
pdftoppm -r 300 -png "<source.pdf>" page
```

**A font not embedded:** Poppler replaces the font, so the pages can change. Use
PDFKit. Do not use `CGContext.drawPDFPage`: it leaves out annotations, so the boxes
disappear and the secret shows.

```swift
// pk.swift. Build: swiftc -O pk.swift -o pk. Run: ./pk "<source.pdf>" page
import Foundation; import PDFKit; import CoreGraphics; import ImageIO; import UniformTypeIdentifiers
let a = CommandLine.arguments
let doc = PDFDocument(url: URL(fileURLWithPath: a[1]))!; let s = CGFloat(300.0 / 72)
for i in 0..<doc.pageCount {
  let p = doc.page(at: i)!; let r = p.bounds(for: .mediaBox)
  let q = p.rotation % 180 == 0; let w = q ? r.width : r.height; let h = q ? r.height : r.width
  let c = CGContext(data: nil, width: Int(w * s), height: Int(h * s), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w * s, height: h * s))
  c.scaleBy(x: s, y: s); p.displaysAnnotations = true; p.draw(with: .mediaBox, to: c)
  let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: String(format: "%@-%03d.png", a[2], i + 1)) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(d, c.makeImage()!, nil); CGImageDestinationFinalize(d)
}
```

## 4. Build the PDF from the pages

```bash
magick page-*.png -alpha off -strip -units PixelsPerInch -density 300 \
  -compress jpeg -quality 88 -sampling-factor 4:4:4 "<output.pdf>"
```

Poppler pads page numbers to the page count, and the Swift tool pads to three
digits, so the glob keeps the pages in order. Compare the page count with the source.

## 5. Prove it

All of these must pass before you say the file is flat:

```bash
pdftotext "<output.pdf>" - | tr -d '\f\n ' | wc -c   # 0; never print this text
pdffonts "<output.pdf>"                      # headers only, no font rows
pdfimages -list "<output.pdf>"               # one image per page
pdfinfo "<output.pdf>" | grep Pages          # the same count as the source
pdftotext "<output.pdf>" - | grep -c "<last four of the secret>"   # 0
```

Then read each page as an image, and zoom to each mask at full resolution. The text
checks cannot find these faults:

- a box that is too short, or that leaves part of a character showing;
- a translucent box, where the number can still be read;
- a mask that did not render, which also leaves the secret in plain view;
- a secret that appears in a second place with no mask on it.

A digit-only search does not see a number inside the page image. Only your eyes do.

## Images

```bash
magick "<source-image>" -auto-orient -background white -alpha remove -alpha off -strip "<output.jpg>"
```

This removes transparency and metadata. `-auto-orient` applies the rotation tag first,
because `-strip` deletes it and a phone photo then shows sideways. A transparent area
can still hold the original pixels, and a PNG comment or EXIF block can hold text or a
location. Check
with `magick "<output.jpg>" -format '%[channels] [%c]\n' info:`, then look at the image.

## Other documents

Do not send a Word, Excel or Google file that carries a secret, a comment or a
tracked change: all three stay in the file. Export to PDF from the app that owns the
format, and read the export to confirm the marks are as you want. Then run this SOP
on the PDF. For a layered file (PSD, HEIC, a multi-frame TIFF), export a single flat
PNG first, then run the image step.

## Tested and not tested

Tested on 2026-11-04: both PDF paths, on real documents and on a test file with an
opaque annotation over text, and the image step, on a test PNG with text under a
transparent area. Not tested: the Office and layered-file routes. Run step 5 and read
the pages on those.

## Hand-back

Name the output, list the checks that passed, say which pages you read, and say that
the source still holds the secret. Delete the scratch pages.
