# frozen_string_literal: true

# [unit] The hub's favicon fills its tile (task stacked-rule-of-three; Alex 2026-10-14 12:14: the favicon "looks
# small": 32 px empty at the top and 10 at the sides of 256). script/brand_png.cjs draws public/favicon.png from the
# kit icon, whose box is its ink (Logos::IconInk), with no margin of its own, so the ink's alpha bounding box must
# touch two opposite edges of the PNG. The PWA app icon (public/icon.png) is the exception: the manifest serves it as
# "purpose": "maskable", and Android crops a maskable icon to a circle, so its artwork keeps a 0.16 safe zone on every
# edge (review of PR 2101). The favicon draws the SMALL-SIZE MARK (Logos::SmallMark, public/favicon-mark.svg; task
# footer-stacked-logo): the icon without the sparkles, side dashes and loose coins that a 16-32 px tab shows only as
# specks, and that set the full icon's box, so the chest filled about 70% of the tab. Alex 2026-10-15 08:10, of the
# old chest-only favicon: "That is the correct size". Read with Zlib alone: the PNG is 8-bit RGBA, not interlaced, as Chromium writes it.

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

  ISLAND_SHARE = 0.02

  # THE CHEST FILLS THE TAB: no loose speck sets the favicon's box. Every island of ink (8-connected pixels with alpha
  # over 16) smaller than ISLAND_SHARE of the tile lies inside the box of an island at least that big: a coin drawn
  # inside the chest is detail, a sparkle beside it is a speck. The full kit icon fails this (its sparkles, dashes
  # and loose coins sit outside the chest), which is what the favicon used to draw.
  def test_the_favicon_has_no_isolated_speck
    width, height, rows = rgba(FAVICON)
    islands = ink_islands(width, height, rows)
    big, small = islands.partition { |island| island[:size] >= ISLAND_SHARE * width * height }
    refute_empty big
    loose = small.reject { |speck| big.any? { |island| contains?(island[:box], speck[:box]) } }
    assert_empty loose, "isolated specks (size, box): #{loose.map { |i| [i[:size], i[:box]] }.first(8)}"
  end

  def ink_islands(width, height, rows)
    inked = Array.new(height) { |y| Array.new(width) { |x| rows[y].getbyte(x * 4 + 3) > 16 } }
    seen = Array.new(height) { Array.new(width, false) }
    islands = []
    height.times do |y0|
      width.times do |x0|
        next if !inked[y0][x0] || seen[y0][x0]

        seen[y0][x0] = true
        stack = [[x0, y0]]
        size = 0
        box = [x0, y0, x0, y0]
        until stack.empty?
          x, y = stack.pop
          size += 1
          box = [[box[0], x].min, [box[1], y].min, [box[2], x].max, [box[3], y].max]
          [-1, 0, 1].product([-1, 0, 1]).each do |dx, dy|
            nx = x + dx
            ny = y + dy
            next if nx.negative? || ny.negative? || nx >= width || ny >= height || seen[ny][nx] || !inked[ny][nx]

            seen[ny][nx] = true
            stack << [nx, ny]
          end
        end
        islands << { size:, box: }
      end
    end
    islands
  end

  def contains?(outer, inner) = outer[0] <= inner[0] && outer[1] <= inner[1] && outer[2] >= inner[2] && outer[3] >= inner[3]

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
