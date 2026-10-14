# frozen_string_literal: true

# [unit] The hub's favicon fills its tile (task stacked-rule-of-three; Alex 2026-10-14 12:14: the favicon "looks
# small": 32 px empty at the top and 10 at the sides of 256). script/brand_png.cjs draws public/favicon.png from the
# kit icon, whose box is its ink (Logos::IconInk), with no margin of its own, so the ink's alpha bounding box must
# touch two opposite edges of the PNG. Read with Zlib alone: the PNG is 8-bit RGBA, not interlaced, as Chromium writes it.

require "minitest/autorun"
require "zlib"

class BrandFaviconTest < Minitest::Test
  FAVICON = File.expand_path("../../public/favicon.png", __dir__)

  # [width, height, rows of RGBA byte strings].
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
    assert_equal [8, 6, 0], [depth, colour, interlace], "8-bit RGBA, not interlaced"
    raw = Zlib::Inflate.inflate(chunks.select { |type, _| type == "IDAT" }.map(&:last).join)
    stride = width * 4
    previous = "\0".b * stride
    rows = (0...height).map do |y|
      filter = raw.getbyte(y * (stride + 1))
      line = raw.byteslice(y * (stride + 1) + 1, stride).bytes
      line.each_index do |i|
        left = i >= 4 ? line[i - 4] : 0
        up = previous.getbyte(i)
        corner = i >= 4 ? previous.getbyte(i - 4) : 0
        line[i] = (line[i] + case filter
                             when 0 then 0
                             when 1 then left
                             when 2 then up
                             when 3 then (left + up) / 2
                             else paeth(left, up, corner)
                             end) & 0xFF
      end
      previous = line.pack("C*")
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
end
