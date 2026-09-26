# frozen_string_literal: true

# [unit] WorkspaceIcon — the argv that draws a workspace's badge onto a piece of
# software's logo, and the config both axes come from. Nothing here runs
# ImageMagick; test/lib/workspace_icon_render_test.rb draws real PNGs.
#
# The assertions that matter most are the two measured traps the lib carries:
# the tile canvas's `-size` leaking into the SVG read (a cropped quarter-G), and
# a render that exits 0 while its background is flattened.
#
#   ruby -Itest test/lib/workspace_icon_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/workspace_icon"

class WorkspaceIconTest < Minitest::Test
  def argv(**overrides)
    WorkspaceIcon.command(logo: "logo.png", badge: "badge.png", out: "out.png", accent: "#8E83FC", **overrides)
  end

  def test_the_command_reads_both_images_and_writes_an_alpha_png
    cmd = argv

    assert_equal "magick", cmd.first
    assert_includes cmd, "logo.png"
    assert_includes cmd, "badge.png"
    assert_equal "PNG32:out.png", cmd.last, "PNG32 keeps the alpha channel even when every pixel happens to be opaque"
    assert_includes cmd, "#8E83FC"
  end

  def test_the_badge_sits_in_the_lower_right_and_inside_the_canvas
    g = WorkspaceIcon.geometry(1024)

    assert_operator g.cx, :>, 512
    assert_operator g.cy, :>, 512
    assert_operator g.cx + g.r, :<=, 1024, "the badge must not be clipped by the canvas edge"
    assert_operator g.inner_r, :>, 0
    assert_operator g.logo, :<=, 2 * g.inner_r, "the logo box fits the white disc"
  end

  def test_the_logo_layer_is_clipped_to_the_white_disc
    cmd = argv

    assert_includes cmd, "DstIn", "without the clip a square logo paints over the accent ring"
  end

  def test_an_accent_that_is_not_hex_is_refused_before_anything_runs
    %w[violet #abc 8E83FC #8E83FCFF].each do |bad|
      assert_raises(WorkspaceIcon::Error, "#{bad} must be refused") { argv(accent: bad) }
    end
  end

  def test_a_size_outside_the_bounds_is_refused
    assert_raises(WorkspaceIcon::Error) { WorkspaceIcon.geometry(WorkspaceIcon::MIN_SIZE - 1) }
    assert_raises(WorkspaceIcon::Error) { WorkspaceIcon.geometry(WorkspaceIcon::MAX_SIZE + 1) }
  end

  def test_the_binary_is_im7_magick_first_then_im6_convert
    Dir.mktmpdir do |im7|
      Dir.mktmpdir do |im6|
        %w[magick convert].each { |name| stub_bin(im7, name) }
        stub_bin(im6, "convert")

        assert_equal "magick", WorkspaceIcon.binary(im7)
        assert_equal "convert", WorkspaceIcon.binary(im6), "Ubuntu's apt ships ImageMagick 6, which has no magick"
        assert_nil WorkspaceIcon.binary(Dir.tmpdir.then { |d| File.join(d, "no-such-dir") })
      end
    end
  end

  def test_an_svg_mark_resets_the_canvas_size_before_it_is_read
    cmd = WorkspaceIcon.tile_command(mark: fixture_svg(1024), out: "tile.png")
    read_at = cmd.index { |arg| arg.end_with?(".svg") }

    # `-size 512x512` is a SETTING. Left in force, the SVG reader takes it as the
    # render canvas and crops a 1024-unit mark to its top-left quarter.
    last_size = cmd[0...read_at].rindex("-size")
    reset = cmd[0...read_at].rindex("+size")
    refute_nil reset, "no +size before the SVG read"
    assert_operator reset, :>, last_size, "+size must come AFTER the canvas's -size, or the setting is still in force"
  end

  def test_a_large_canvas_svg_is_never_rendered_below_96_dpi
    cmd = WorkspaceIcon.tile_command(mark: fixture_svg(1024), out: "tile.png")

    assert_equal "96", cmd[cmd.index("-density") + 1]
  end

  def test_a_24_unit_svg_gets_a_density_that_lands_it_near_the_tile
    cmd = WorkspaceIcon.tile_command(mark: fixture_svg(24), out: "tile.png")

    assert_operator cmd[cmd.index("-density") + 1].to_i, :>, 96
  end

  def test_a_mark_that_is_already_an_icon_is_only_resized
    cmd = WorkspaceIcon.tile_command(mark: "icon.png", out: "tile.png", tile: false)

    refute_includes cmd, "-draw", "a tile: false mark (1Password) must not get a second disc"
    assert_equal "PNG32:tile.png", cmd.last
  end

  # --- the config the CLI and /credentials share --------------------------

  def test_every_software_has_a_mark_on_disk
    WorkspaceIcon.softwares.each do |key, sw|
      assert sw["name"].to_s.strip.length.positive?, "#{key} has no name"
      assert File.file?(File.join(WorkspaceIcon::ROOT, sw.fetch("mark"))), "#{key}: mark #{sw['mark']} is missing"
    end
  end

  def test_every_badge_named_in_the_config_is_on_disk
    WorkspaceIcon.workspaces.each do |scope, ws|
      next unless ws["badge"]

      assert File.file?(File.join(WorkspaceIcon::ROOT, ws["badge"])), "#{scope}: badge #{ws['badge']} is missing"
      assert_match WorkspaceIcon::HEX, ws["accent"], "#{scope}: accent must be #rrggbb" if ws["accent"]
    end
  end

  def test_an_unknown_software_or_scope_names_the_known_ones
    error = assert_raises(WorkspaceIcon::Error) { WorkspaceIcon.software("myspace") }
    assert_match(/google/, error.message)

    error = assert_raises(WorkspaceIcon::Error) { WorkspaceIcon.workspace("nowhere") }
    assert_match(/studio/, error.message)
  end

  def test_1password_draws_from_its_full_size_original
    assert_equal WorkspaceIcon.mark_path("1password"), WorkspaceIcon.software_logo("1password"),
                 "a 1024px vault upload must not upscale the 512px tile"
    assert_equal WorkspaceIcon.tile_path("google"), WorkspaceIcon.software_logo("google")
  end

  private

  def stub_bin(dir, name)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n")
    FileUtils.chmod(0o755, path)
  end

  def fixture_svg(width)
    @dir ||= Dir.mktmpdir
    path = File.join(@dir, "mark-#{width}.svg")
    File.write(path, %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{width} #{width}"><path d="M0 0h#{width}v#{width}z"/></svg>))
    path
  end
end
