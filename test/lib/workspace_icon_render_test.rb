# frozen_string_literal: true

# [integration] WorkspaceIcon draws real PNGs through ImageMagick (IM7 `magick`
# on a Mac, IM6 `convert` on CI — the CI rails job installs `imagemagick` for
# this file), then reads them back.
#
# The pixel probes are the point. An ImageMagick run that exits 0 proves only
# that ImageMagick ran; what we ship is a TRANSPARENT icon with the badge in the
# lower-right, ringed in the accent, and each of those is a pixel we can read.
#
#   ruby -Itest test/lib/workspace_icon_render_test.rb

require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../../bin/lib/workspace_icon"

class WorkspaceIconRenderTest < Minitest::Test
  SIZE = 256

  def setup
    @bin = WorkspaceIcon.binary
    # Not a skip: CI installs ImageMagick for this file, so its absence is a
    # broken lane, and a skipped render test would pass exactly when it matters.
    flunk "ImageMagick is not installed (need `magick` or `convert`); CI's rails job installs imagemagick" if @bin.nil?
    @dir = Dir.mktmpdir
  end

  def teardown = FileUtils.rm_rf(@dir)

  def test_a_render_is_transparent_badged_lower_right_and_ringed_in_the_accent
    logo = draw("logo.png", "-size", "200x200", "xc:none", "-fill", "#1E90FF", "-draw", "circle 100,100 100,5")
    badge = draw("badge.png", "-size", "120x120", "xc:none", "-fill", "#FF8800", "-draw", "rectangle 20,20 100,100")
    out = File.join(@dir, "icon.png")

    result = WorkspaceIcon.render!(logo: logo, badge: badge, out: out, accent: "#00AA00", size: SIZE)
    g = WorkspaceIcon.geometry(SIZE)

    assert_equal SIZE, result[:size]
    assert_in_delta 0.0, alpha(out, 0, 0), 0.001, "the corner must be transparent"
    assert_in_delta 1.0, alpha(out, g.cx, g.cy), 0.001, "the badge centre is opaque"
    assert_color out, g.cx, g.cy, "#FF8800", "the badge logo sits at the badge centre"
    ring_y = g.cy - g.inner_r - (g.ring / 2)
    assert_color out, g.cx, ring_y, "#00AA00", "the ring between the white rim and the disc is the accent"
    assert_color out, SIZE / 3, SIZE / 3, "#1E90FF", "the software logo fills the upper-left"
  end

  def test_without_an_accent_the_ring_takes_the_badges_own_colour
    badge = draw("badge.png", "-size", "60x60", "xc:none", "-fill", "#8E83FC", "-draw", "circle 30,30 30,2")

    assert_equal "#8E83FC", WorkspaceIcon.derive_accent(badge, bin: @bin),
                 "transparent pixels must not darken the average"
  end

  def test_verify_refuses_a_flattened_background
    flat = draw("flat.png", "-size", "#{SIZE}x#{SIZE}", "xc:white")

    error = assert_raises(WorkspaceIcon::Error) { WorkspaceIcon.verify!(flat, size: SIZE, bin: @bin) }
    assert_match(/not transparent/, error.message)
  end

  def test_verify_refuses_the_wrong_size
    small = draw("small.png", "-size", "64x64", "xc:none")

    assert_raises(WorkspaceIcon::Error) { WorkspaceIcon.verify!(small, size: SIZE, bin: @bin) }
  end

  def test_an_svg_mark_wider_than_the_tile_is_drawn_whole
    # The measured trap: a 1024-unit SVG read under the tile's -size came out as
    # its top-left quarter. Two squares in opposite corners: after -trim the
    # blue one ends at the lower-right of the mark's box, and only if the whole
    # canvas was read. (One solid square would trim away to nothing.)
    svg = File.join(@dir, "wide.svg")
    File.write(svg, <<~SVG)
      <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
        <rect x="24" y="24" width="100" height="100" fill="#CC0000"/>
        <rect x="900" y="900" width="100" height="100" fill="#0000CC"/>
      </svg>
    SVG
    out = File.join(@dir, "tile.png")
    _o, err, status = Open3.capture3(*WorkspaceIcon.tile_command(mark: svg, out: out, bin: @bin))
    assert status.success?, err

    box = (WorkspaceIcon::TILE_SIZE * WorkspaceIcon::TILE_MARK).round
    edge = (WorkspaceIcon::TILE_SIZE / 2) + (box / 2) - 4
    assert_color out, edge, edge, "#0000CC", "the mark's lower-right corner was cropped away"
  end

  private

  def draw(name, *args)
    path = File.join(@dir, name)
    _o, err, status = Open3.capture3(@bin, *args, "PNG32:#{path}")
    assert status.success?, err
    path
  end

  def probe(file, x, y, format)
    out, err, status = Open3.capture3(@bin, file, "-format", format.gsub("XY", "#{x},#{y}"), "info:")
    assert status.success?, err
    out.strip
  end

  def alpha(file, x, y) = probe(file, x, y, "%[fx:p{XY}.a]").to_f

  def assert_color(file, x, y, hex, message)
    got = probe(file, x, y, "%[fx:int(255*p{XY}.r)] %[fx:int(255*p{XY}.g)] %[fx:int(255*p{XY}.b)]").split.map(&:to_i)
    want = hex.delete("#").scan(/../).map(&:hex)
    close = got.zip(want).all? { |a, b| (a - b).abs <= 8 }
    assert close, "#{message}: pixel (#{x},#{y}) is #{got.inspect}, expected #{want.inspect}"
  end
end
