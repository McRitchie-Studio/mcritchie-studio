# frozen_string_literal: true

# [unit] The hub's favicon fills its tile (task stacked-rule-of-three; Alex 2026-10-14 12:14: the favicon "looks
# small": 32 px empty at the top and 10 at the sides of 256). script/brand_png.cjs draws public/favicon.png from the
# kit icon, whose box is its ink (Logos::IconInk), with no margin of its own, so the ink's alpha bounding box must
# touch two opposite edges of the PNG. The PWA app icon (public/icon.png) is the exception: the manifest serves it as
# "purpose": "maskable", and Android crops a maskable icon to a circle, so its artwork keeps a 0.16 safe zone on every
# edge (review of PR 2101). Read with Zlib alone: the PNG is 8-bit RGBA, not interlaced, as Chromium writes it.

require "minitest/autorun"
require "zlib"

class BrandFaviconTest < Minitest::Test
  FAVICON = File.expand_path("../../public/favicon.png", __dir__)
  APP_ICON = File.expand_path("../../public/icon.png", __dir__)
  MANIFEST = File.expand_path("../../app/views/pwa/manifest.json.erb", __dir__)
  SAFE_ZONE = 0.16

  # [width, height, rows of RGBA byte strings]: an opaque PNG (8-bit RGB) is read with alpha 255 added.
  def rgba(path)
    bytes = File.binread(path)
    assert_equal "\x89PNG\r\n\x1A\n".b, bytes[0, 8]
    chunks = []
    at = 8
    while at < bytes.size
      length = bytes[at, 4].unpack1("N")
      chunks << [bytes[at + 4, 4], bytes[at + 8, length]]
      at += 12 + length
    end
    width, height, depth, colour, _, _, interlace = chunks.assoc("IHDR").last.unpack("NNCCCCC")
    assert_equal [8, 0], [depth, interlace], "8-bit, not interlaced"
    channels = { 6 => 4, 2 => 3 }.fetch(colour) { flunk "colour type #{colour}: expected RGBA (6) or RGB (2)" }
    raw = Zlib::Inflate.inflate(chunks.select { |type, _| type == "IDAT" }.map(&:last).join)
    stride = width * channels
    previous = "\0".b * stride
    rows = (0...height).map do |y|
      filter = raw.getbyte(y * (stride + 1))
      line = raw.byteslice(y * (stride + 1) + 1, stride).bytes
      line.each_index do |i|
        left = i >= channels ? line[i - channels] : 0
        up = previous.getbyte(i)
        corner = i >= channels ? previous.getbyte(i - channels) : 0
        line[i] = (line[i] + case filter
                             when 0 then 0
                             when 1 then left
                             when 2 then up
                             when 3 then (left + up) / 2
                             else paeth(left, up, corner)
                             end) & 0xFF
      end
      previous = line.pack("C*")
      channels == 4 ? previous : line.each_slice(3).flat_map { |pixel| pixel + [255] }.pack("C*")
    end
    [width, height, rows]
  end

  def paeth(a, b, c)
    p = a + b - c
    pa = (p - a).abs
    pb = (p - b).abs
    pc = (p - c).abs
    if pa <= pb && pa <= pc then a
    elsif pb <= pc then b
    else c
    end
  end

  def test_the_favicons_ink_touches_two_opposite_edges
    width, height, rows = rgba(FAVICON)
    assert_equal [256, 256], [width, height]
    inked = rows.each_with_index.flat_map do |row, y|
      (0...width).filter_map { |x| [x, y] if row.getbyte(x * 4 + 3) > 16 }
    end
    xs = inked.map(&:first)
    ys = inked.map(&:last)
    left, right, top, bottom = xs.min, width - 1 - xs.max, ys.min, height - 1 - ys.max
    touches = [left, right].max <= 1 || [top, bottom].max <= 1
    assert touches, "the ink touches two opposite edges (margins left #{left}, right #{right}, top #{top}, bottom #{bottom})"
    assert_in_delta left, right, 2, "centred across"
    assert_in_delta top, bottom, 2, "centred down"
  end

  # The maskable app icon: opaque, its artwork (every pixel unlike the corner's background) inside the safe zone on
  # every edge and touching it on two opposite edges, so the art is as large as the zone allows (about 346 of 512).
  def test_the_maskable_app_icon_keeps_its_safe_zone
    assert_match(%r{"src": "/icon.png",\s*"type": "image/png",\s*"sizes": "512x512",\s*"purpose": "maskable"}, File.read(MANIFEST),
                 "the manifest still serves icon.png as maskable; drop this test's safe zone only if it stops")
    width, height, rows = rgba(APP_ICON)
    assert_equal [512, 512], [width, height]
    background = rows.first.byteslice(0, 4)
    assert_equal 255, background.getbyte(3), "opaque"
    art = rows.each_with_index.flat_map do |row, y|
      (0...width).filter_map do |x|
        pixel = row.byteslice(x * 4, 4)
        [x, y] if (0..2).any? { |i| (pixel.getbyte(i) - background.getbyte(i)).abs > 24 }
      end
    end
    xs = art.map(&:first)
    ys = art.map(&:last)
    margins = { left: xs.min, right: width - 1 - xs.max, top: ys.min, bottom: height - 1 - ys.max }
    zone = (SAFE_ZONE * width).round
    margins.each { |side, margin| assert_operator margin, :>=, zone - 2, "#{side}: the artwork keeps the #{zone} px safe zone (#{margins})" }
    assert [margins.values_at(:left, :right).max, margins.values_at(:top, :bottom).max].min <= zone + 2,
           "the artwork reaches the safe zone on two opposite edges (#{margins})"
  end
end
