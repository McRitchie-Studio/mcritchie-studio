# frozen_string_literal: true

require "open3"
require "yaml"

# WorkspaceIcon — composites a client workspace's badge onto a piece of
# software's logo: the 1Password lock (the icon each client's vault wears in
# 1Password), the Google "G" (that client's Google Workspace), and so on. The
# workspace's logo sits in the lower-right corner on a white disc ringed in the
# workspace's accent colour, on a transparent background.
#
#   WorkspaceIcon.render!(logo: "lib/workspace_icons/software/1password.png",
#                         badge: "lib/workspace_icons/badges/studio.png",
#                         out: "app/assets/images/workspace_icons/1password/studio.png")
#
# config/workspace_icons.yml holds both axes: `software` (the base logos) and
# `workspaces` (the badges). /credentials shows the renders as a software-by-
# entity matrix.
#
# WHY IMAGEMAGICK AND NOT LIBVIPS. The app's image_processing stack is libvips,
# and libvips is absent on every developer Mac (see the Gemfile note on
# ruby-vips). This is an operator act run on the Mac, where ImageMagick is the
# tool that is present. CI installs ImageMagick for the one test that renders.
#
# IM7 OR IM6. A Mac has ImageMagick 7 (`magick`); Ubuntu's apt ships 6
# (`convert`). Every operator below is spelled the way both versions accept, and
# the binary is chosen at run time, so the same argv renders on both.
#
# NOTHING HERE TOUCHES 1PASSWORD OR GOOGLE. `op vault edit --icon` accepts only
# the built-in icon keywords, not an image, so a vault upload is a 1Password-app
# act; see docs/agents/agents/steffon/sops/workspace-icon.md.
module WorkspaceIcon
  ROOT = File.expand_path("../..", __dir__)
  CONFIG = File.join(ROOT, "config/workspace_icons.yml")
  # Rendered icons live where the /credentials page serves them from:
  # app/assets/images/workspace_icons/<software>/<scope>.png.
  ASSET_DIR = "app/assets/images/workspace_icons"
  DEFAULT_SOFTWARE = "1password"

  # A 1Password vault upload wants the full 1024; the matrix shows a cell at
  # 64px, so the committed assets render at 256 (sharp at 4x, ~40KB each).
  DEFAULT_SIZE = 1024
  ASSET_SIZE = 256
  # Software tiles: each brand mark centred on a white disc shaped like the
  # 1Password icon. The disc radii are fractions of the tile's edge.
  TILE_SIZE = 512
  TILE_DISC = [ [ "#8A8A8A", 0.448 ], [ "#FFFFFF", 0.442 ], [ "#E3E5E8", 0.3965 ], [ "#F5F6F8", 0.3926 ] ].freeze
  TILE_MARK = 0.50
  MIN_SIZE = 64
  MAX_SIZE = 4096

  # Badge geometry, as fractions of the canvas, taken from the reference image
  # Alex supplied on 2026-09-25: the badge covers roughly the lower-right third
  # and overlaps the ring without hiding the keyhole.
  BADGE_DIAMETER = 0.40
  BADGE_MARGIN = 0.02
  # Rings inside the badge, as fractions of the badge diameter.
  RIM = 0.035    # thin white rim that separates the badge from the icon below
  RING = 0.07    # the accent ring
  # The logo's box, as a fraction of the white disc's diameter. The logo layer
  # is then CLIPPED to the disc, so a square logo's corners can never paint over
  # the accent ring.
  LOGO_FIT = 0.80

  HEX = /\A#\h{6}\z/

  class Error < StandardError; end

  Geometry = Struct.new(:size, :diameter, :left, :top, :cx, :cy, :r, :rim, :ring, :logo, keyword_init: true) do
    def inner_r = r - rim - ring
    def ring_r = r - rim
  end

  module_function

  def config(path = CONFIG) = YAML.safe_load_file(path)

  # The workspace scopes the config knows, keyed by scope ("studio").
  def workspaces(path = CONFIG) = config(path).fetch("workspaces", {})

  def workspace(scope, path = CONFIG)
    workspaces(path).fetch(scope.to_s) do
      raise Error, "unknown workspace scope #{scope.inspect} — known: #{workspaces(path).keys.sort.join(', ')}"
    end
  end

  # The software logos the config knows, keyed by software ("1password").
  def softwares(path = CONFIG) = config(path).fetch("software", {})

  def software(key, path = CONFIG)
    softwares(path).fetch(key.to_s) do
      raise Error, "unknown software #{key.inspect} — known: #{softwares(path).keys.sort.join(', ')}"
    end
  end

  # The tile a software's badged icons are drawn on — built from its mark by
  # #build_tile!, and served as the matrix's row icon.
  def software_logo(key, path = CONFIG)
    # A mark that is already an icon (1Password) is drawn from the full-size
    # original, so a 1024px vault upload is not an upscaled 512px tile.
    software(key, path).fetch("tile", true) ? tile_path(key) : mark_path(key, path)
  end

  def tile_path(key) = File.join(ROOT, ASSET_DIR, "software", "#{key}.png")

  def mark_path(key, path = CONFIG) = File.join(ROOT, software(key, path).fetch("mark"))

  def asset_path(software_key, scope) = File.join(ROOT, ASSET_DIR, software_key.to_s, "#{scope}.png")

  def geometry(size)
    size = Integer(size)
    raise Error, "size must be between #{MIN_SIZE} and #{MAX_SIZE} (got #{size})" unless size.between?(MIN_SIZE, MAX_SIZE)

    diameter = (size * BADGE_DIAMETER).round
    left = size - diameter - (size * BADGE_MARGIN).round
    r = diameter / 2
    Geometry.new(size: size, diameter: diameter, left: left, top: left,
                 cx: left + r, cy: left + r, r: r,
                 rim: [ (diameter * RIM).round, 1 ].max,
                 ring: [ (diameter * RING).round, 1 ].max,
                 logo: (2 * (r - (diameter * RIM).round - (diameter * RING).round) * LOGO_FIT).round)
  end

  # The white disc's diameter — the logo layer's canvas and clip.
  def disc(g) = 2 * g.inner_r

  # `magick` on IM7, `convert` on IM6. nil when neither is on PATH.
  def binary(path_env = ENV.fetch("PATH", ""))
    %w[magick convert].find do |name|
      path_env.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
    end
  end

  def validate_accent!(accent)
    return accent if accent.to_s.match?(HEX)

    raise Error, "accent must be a #rrggbb hex colour (got #{accent.inspect})"
  end

  # The argv that renders one icon. Pure: no file is read and nothing runs, so
  # the geometry is testable without ImageMagick.
  def command(logo:, badge:, out:, accent:, size: DEFAULT_SIZE, bin: "magick")
    validate_accent!(accent)
    g = geometry(size)
    shadow_offset = (g.size * 0.008).round
    blur = (g.size * 0.012).round

    [
      bin,
      "-size", "#{g.size}x#{g.size}", "xc:none",
      # The icon itself, fitted to the canvas and centred.
      "(", logo, "-resize", "#{g.size}x#{g.size}", "-background", "none",
      "-gravity", "center", "-extent", "#{g.size}x#{g.size}", ")",
      "-gravity", "northwest", "-compose", "over", "-composite",
      # A soft shadow under the badge, so it lifts off the ring it overlaps.
      "(", "-size", "#{g.size}x#{g.size}", "xc:none", "-fill", "rgba(0,0,0,0.35)",
      "-draw", circle(g.cx, g.cy + shadow_offset, g.r), "-blur", "0x#{blur}", ")",
      "-compose", "over", "-composite",
      # White rim, accent ring, white disc.
      "-fill", "white", "-draw", circle(g.cx, g.cy, g.r),
      "-fill", accent, "-draw", circle(g.cx, g.cy, g.ring_r),
      "-fill", "white", "-draw", circle(g.cx, g.cy, g.inner_r),
      # The workspace logo: trimmed of its own padding, fitted, centred on a
      # disc-sized canvas, then clipped to the disc (DstIn keeps only what lies
      # inside the circle).
      "(", badge, "-trim", "+repage", "-resize", "#{g.logo}x#{g.logo}", "-background", "none",
      "-gravity", "center", "-extent", "#{disc(g)}x#{disc(g)}",
      "(", "-size", "#{disc(g)}x#{disc(g)}", "xc:none", "-fill", "white",
      "-draw", circle(g.inner_r, g.inner_r, g.inner_r), ")",
      "-gravity", "northwest", "-compose", "DstIn", "-composite", ")",
      "-gravity", "northwest", "-geometry", "+#{g.cx - g.inner_r}+#{g.cy - g.inner_r}",
      "-compose", "over", "-composite",
      "PNG32:#{out}"
    ]
  end

  # -draw's circle takes a centre and ANY point on the edge.
  def circle(cx, cy, r) = "circle #{cx},#{cy} #{cx},#{cy - r}"

  # An SVG's viewBox width, so the render density can be picked to land the mark
  # near the size it will be drawn at: a 24-unit Simple Icons mark and a
  # 1024-unit tile need densities 40x apart.
  def svg_width(file)
    box = File.read(file)[/viewBox="([^"]+)"/, 1]
    box ? box.split(/[\s,]+/)[2].to_f : 24.0
  end

  # The argv that turns one mark into its tile. `tile: false` marks (1Password)
  # are already an icon and are only resized.
  def tile_command(mark:, out:, tile: true, size: TILE_SIZE, bin: "magick")
    box = (size * TILE_MARK).round
    read = if File.extname(mark).casecmp?(".svg")
             # Floor of 96 so a large-canvas mark is never rendered coarser
             # than it was drawn.
             # +size first: the tile canvas's `-size` is a SETTING, and the SVG
             # reader takes it as the render canvas, cropping any mark wider than
             # the tile (Google's 1024-unit canvas came out a quarter-G).
             #
             # MSVG: names ImageMagick's INTERNAL renderer. Left to choose, IM6 on
             # Ubuntu hands SVG to an external rsvg-convert (absent on CI: the
             # read fails) while IM7 on a Mac renders it itself, so the same mark
             # would draw differently per machine. Every committed tile was drawn
             # by the internal one.
             [ "+size", "-background", "none", "-density", [ ((72.0 * box * 2) / svg_width(mark)).round, 96 ].max.to_s, "MSVG:#{mark}" ]
           else
             [ "#{mark}[0]" ]
           end
    return [ bin, *read, "-resize", "#{size}x#{size}", "-background", "none", "-gravity", "center",
             "-extent", "#{size}x#{size}", "PNG32:#{out}" ] unless tile

    c = size / 2
    disc = TILE_DISC.flat_map { |color, r| [ "-fill", color, "-draw", circle(c, c, (size * r).round) ] }
    [
      bin, "-size", "#{size}x#{size}", "xc:none", *disc,
      "(", *read, "-trim", "+repage", "-resize", "#{box}x#{box}", ")",
      "-gravity", "center", "-compose", "over", "-composite", "PNG32:#{out}"
    ]
  end

  def build_tile!(key, path = CONFIG)
    bin = binary
    raise Error, "ImageMagick is not installed (need `magick` or `convert`)" if bin.nil?

    entry = software(key, path)
    mark = mark_path(key, path)
    raise Error, "no such mark for #{key}: #{mark}" unless File.file?(mark)

    out = tile_path(key)
    Dir.exist?(File.dirname(out)) || raise(Error, "output directory does not exist: #{File.dirname(out)}")
    _o, err, status = Open3.capture3(*tile_command(mark: mark, out: out, tile: entry.fetch("tile", true), bin: bin))
    raise Error, "ImageMagick failed on #{key}: #{err.strip}" unless status.success?

    verify!(out, size: TILE_SIZE, bin: bin)
    out
  end

  # The badge logo's alpha-weighted average colour, as #rrggbb. Used when the
  # workspace names no accent, so the ring matches the logo it frames.
  def derive_accent(badge, bin: binary)
    raise Error, "ImageMagick is not installed (need `magick` or `convert`)" if bin.nil?

    out, err, status = Open3.capture3(bin, badge, "-scale", "1x1!", "-alpha", "off",
                                      "-format", "%[hex:p{0,0}]", "info:")
    raise Error, "could not read #{badge}: #{err.strip}" unless status.success?

    hex = out.strip.upcase[0, 6]
    raise Error, "could not derive an accent from #{badge} (got #{out.strip.inspect})" unless hex.match?(/\A\h{6}\z/)

    "##{hex}"
  end

  def render!(logo:, badge:, out:, accent: nil, size: DEFAULT_SIZE)
    bin = binary
    raise Error, "ImageMagick is not installed (need `magick` or `convert`); brew install imagemagick" if bin.nil?

    [ logo, badge ].each { |file| raise Error, "no such file: #{file}" unless File.file?(file) }
    accent ||= derive_accent(badge, bin: bin)
    File.dirname(out).then { |dir| Dir.exist?(dir) || raise(Error, "output directory does not exist: #{dir}") }

    _out, err, status = Open3.capture3(*command(logo: logo, badge: badge, out: out, accent: accent, size: size, bin: bin))
    raise Error, "ImageMagick failed: #{err.strip}" unless status.success?

    verify!(out, size: size, bin: bin)
    { out: out, accent: accent, size: Integer(size) }
  end

  # A render that exits 0 is not yet the icon we asked for. Read the file back:
  # the right dimensions, and a TRANSPARENT corner — a flattened background is
  # the failure that looks fine in a viewer and shows as a white square in the
  # vault list.
  def verify!(out, size:, bin: binary)
    report, err, status = Open3.capture3(bin, out, "-format", "%w %h %[fx:p{0,0}.a]", "info:")
    raise Error, "could not read back #{out}: #{err.strip}" unless status.success?

    width, height, corner_alpha = report.split
    unless width.to_i == Integer(size) && height.to_i == Integer(size)
      raise Error, "#{out} is #{width}x#{height}, expected #{size}x#{size}"
    end
    raise Error, "#{out} has an opaque corner (alpha #{corner_alpha}) — the background is not transparent" unless corner_alpha.to_f.zero?

    true
  end
end
