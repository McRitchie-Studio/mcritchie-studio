# frozen_string_literal: true

require "json"
require_relative "icon_ink"

module Logos
  # Commercial Welding v2's helmet, derived from v1's traced helmet (Alex's item 5, task welding-llc-and-v2-helmet):
  #
  #   1. Its box is its ink (Logos::IconInk; task stacked-rule-of-three, Alex 2026-10-14 12:16). Until then the box
  #      was widened so the helmet's midline (where its blue half meets its white half) was the box's centre, which
  #      left a margin of about 17 units on one side; that step is gone, and the helmet is centred on its ink.
  #   2. Lens down: the lens (the window, with the spark in it, as one unit) moves down so it sits on the rule of 3's
  #      middle row of the ink box: its top and bottom on the row lines if it were one row tall; it is shorter, so it
  #      is centred on that row. The blue frame around the window moves with it: its outer edge is the notch the white
  #      half's contour makes around the frame, and the points of that notch move by the same amount.
  #   3. Clear lens (task kit-export-and-clear-lens): the window is a hole in the outer helmet, so the page shows
  #      through it. Alt's helmets always drew it so; the Original's trace filled it white (#clear_lens).
  #
  # The traced data's own shapes are found, not numbered. The HALVES layer holds the white half and the window: v1's
  # Alt helmets' `primary` (one blue layer, the two as holes in it) or the Original's `white` (the two as opaque white
  # shapes over a blue silhouette; task logo-original-and-alt; v2's Original then holds the window as a hole in the
  # silhouette, step 3, and reads back the same way). The outer helmet is the widest sub-path of any layer;
  # of the halves layer's other two, the white half is the taller and the window the other. Only absolute M, L, C and
  # Z are read (the potrace output); anything else is refused. A source may carry a translate (its trim, IconInk): its
  # points are read in its box, and the v2 paths are written in that box, then trimmed. `rake logos:welding_v2` writes the result to
  # data/brand_icons_welding_v2.json; docs/topics/logos.md has the steps with the numbers.
  class WeldingV2
    class Error < ArgumentError; end

    # Each v2 helmet and the v1 helmet it is derived from.
    SOURCES = { "welding_v2" => "welding", "welding_v2_mono" => "welding_mono", "welding_v2_original" => "welding_original" }.freeze
    HALVES = %w[primary white].freeze          # the layer holding the white half and the window, by role, in this order
    FILE = File.join(__dir__, "data/brand_icons_welding_v2.json")
    ROWS = 3                                   # the navbar rule whose rows the lens is set on
    # How far past the window's edges the frame's points lie, in icon units: the band is 16 to 20 thick, and the next
    # point of the white half's contour (its top curve, its right edge, the midline below the frame) is over 60 away.
    FRAME_REACH = 40.0
    # The measure above are in v1's units, a helmet this tall; a trace at another scale (the Original's, 975
    # tall) takes them scaled to its own height (#scaled), so every helmet is read the same way.
    REFERENCE_HEIGHT = 483.0
    NUMBER = /-?\d+(?:\.\d+)?/
    SEGMENT = /([MLCZ])([^MLCZ]*)/

    # Every v2 icon, keyed as the icon data keys it, from the shipped v1 icons, each in its own ink box.
    def self.icons(icons = NavbarLogo.icons) = SOURCES.transform_values { |from| new(icons.fetch(from), from).icon }

    # The data file's contents, exactly as `rake logos:welding_v2` writes them.
    def self.json(icons = NavbarLogo.icons) = JSON.generate(self.icons(icons))

    # `window` is the lens's box and `dy` how far the lens moves, both in the source's box.
    attr_reader :window, :dy, :height

    def initialize(icon, from)
      @from = from
      @source = icon
      @height = icon.fetch("h").to_f
      offset = self.class.offset(icon["transform"], from)
      @layers = icon.fetch("layers").map { |layer| [layer, self.class.subpaths(layer.fetch("d"), offset)] }
      halves = HALVES.lazy.filter_map { |role| @layers.find { |layer, _| layer["role"] == role } }.first or
        raise Error, "#{from}: no #{HALVES.join(' or ')} layer"
      @halves_role = halves.first["role"]
      @outer = @layers.flat_map(&:last).max_by { |sub| self.class.bbox(sub)[2] - self.class.bbox(sub)[0] }   # widest
      # The white half and the window: the halves layer's shapes and, once the window is cut clear (#icon), the outer
      # helmet's layer's other shape, so a v2 helmet reads back the same way v1's does.
      outer_layer = @layers.find { |_, subs| subs.any? { |sub| sub.equal?(@outer) } }
      holes = (halves.last + (outer_layer.equal?(halves) ? [] : outer_layer.last)).reject { |sub| sub.equal?(@outer) }
      unless holes.size == 2 && outer_layer.last.size <= 3
        raise Error, "#{from}: expected the white half and the window in the #{halves.first['role']} layer (the window may be a hole in " \
                     "the outer helmet's), got #{holes.size} shapes besides the outer helmet"
      end

      @hole, @lens = holes.sort_by { |sub| self.class.bbox(sub)[1] - self.class.bbox(sub)[3] }       # tallest first
      @window = self.class.bbox(@lens)
      _, top, _, bottom = self.class.bbox(@outer)   # the helmet's ink, top to bottom: the box once trimmed
      @dy = ((top + bottom) / 2 - (window[1] + window[3]) / 2).round(2)
    end

    # The v2 icon: the v1 icon's data with the lens, its frame and the spark moved down, in the box trimmed to its ink.
    def icon
      shapes = { @outer => ->(*) { [0, 0] }, @hole => ->(x, y) { frame?(x, y) ? [0, dy] : [0, 0] }, @lens => ->(*) { [0, dy] } }
      layers = @layers.map do |layer, subpaths|
        # A layer holding the outer helmet, the white half or the window is written in that order (v1's primary was
        # written so), and every other sub-path (the spark) moves with the lens.
        found = shapes.keys.select { |shape| subpaths.any? { |sub| sub.equal?(shape) } }
        raise Error, "#{@from}: the #{layer['role']} layer mixes the helmet's halves with other shapes" if found.any? && found.size != subpaths.size

        d = if found.any?
              clear_lens(found).map { |shape| moved(shape, &shapes.fetch(shape)) }.join
            else
              subpaths.map { |sub| moved(sub) { [0, dy] } }.join
            end
        layer.merge("d" => d)
      end
      IconInk.trim({ "w" => @source.fetch("w"), "h" => @source.fetch("h"), "source" => source_note, "layers" => layers })
    end

    # THE LENS IS SEE-THROUGH (task kit-export-and-clear-lens; Alex 2026-10-12: "remove the white of the lens so I can
    # see it clear"): the window is always written as a hole in the outer helmet's layer (even-odd), never as a shape
    # of its own. Alt's primary already holds it so; the Original's trace drew it as an opaque white shape in its white
    # layer over the blue silhouette, so there it moves into the silhouette and the page shows through. The white half
    # stays opaque (it holds the helmet on a dark page), and the spark, the frame and the outer edge are unchanged.
    # `found` is one layer's shapes, in their written order.
    def clear_lens(found)
      found = found.reject { |shape| shape.equal?(@lens) }
      found.any? { |shape| shape.equal?(@outer) } ? found + [@lens] : found
    end

    # The frame's points: those of the white half's contour that lie within FRAME_REACH of the window.
    def frame?(x, y)
      left, top, right, bottom = window
      reach = scaled(FRAME_REACH)
      x.between?(left - reach, right + reach) && y.between?(top - reach, bottom + reach)
    end

    # A path's sub-paths, each a list of [command, [[x, y], ...]]: M and L carry one point, C three, Z none.
    # `offset` ([dx, dy]) moves every point: a source's translate, so its points are read in its box.
    def self.subpaths(d, offset = [0, 0])
      raise Error, "only absolute M, L, C and Z path data can be moved: #{d[0, 40].inspect}" unless d.match?(/\A(?:[MLCZ][-\d., ]*)+\z/)

      segments = d.scan(SEGMENT).map do |command, numbers|
        [command, numbers.scan(NUMBER).map(&:to_f).each_slice(2).map { |x, y| [x + offset[0], y + offset[1]] }]
      end
      segments.slice_before { |command, _| command == "M" }.to_a
    end

    def self.serialise(subpath)
      subpath.map { |command, points| command + points.map { |x, y| "#{number(x)},#{number(y)}" }.join(" ") }.join
    end

    # A source's transform as the [dx, dy] it moves its points: none, or one translate (a trim); anything else is refused.
    def self.offset(transform, from)
      return [0, 0] if transform.nil?

      numbers = transform[/\Atranslate\(([^)]*)\)\z/, 1] or raise Error, "#{from}: only a translate can be read, got transform #{transform.inspect[0, 60]}"
      x, y = numbers.scan(NUMBER).map(&:to_f)
      [x, y || 0.0]
    end

    def self.number(value) = format("%.2f", value.round(2).then { |v| v.zero? ? 0.0 : v })

    # [left, top, right, bottom] of a sub-path's ink: its on-curve points and each curve's turning points.
    def self.bbox(subpath)
      xs = []
      ys = []
      start = nil
      subpath.each do |command, points|
        if command == "C"
          [0, 1].each { |axis| (axis.zero? ? xs : ys).concat(extremes(start[axis], *points.map { |p| p[axis] })) }
        end
        points.last&.then do |point|
          xs << point[0]
          ys << point[1]
          start = point
        end
      end
      [xs.min, ys.min, xs.max, ys.max]
    end

    # A cubic's values where its derivative is zero inside (0, 1).
    def self.extremes(p0, p1, p2, p3)
      a = -p0 + 3 * p1 - 3 * p2 + p3
      b = 2 * (p0 - 2 * p1 + p2)
      c = p1 - p0
      roots = if a.abs < 1e-12
                b.abs < 1e-12 ? [] : [-c / b]
              else
                disc = b * b - 4 * a * c
                disc.negative? ? [] : [-1, 1].map { |sign| (-b + sign * Math.sqrt(disc)) / (2 * a) }
              end
      roots.select { |t| t.positive? && t < 1 }.map { |t| ((1 - t)**3 * p0) + (3 * (1 - t)**2 * t * p1) + (3 * (1 - t) * t**2 * p2) + (t**3 * p3) }
    end

    private

    # A measure in v1's units at this helmet's scale: exactly itself for v1's own helmets.
    def scaled(measure) = measure * height / REFERENCE_HEIGHT

    # A sub-path with each on-curve point moved by the block's [dx, dy]. A curve's first control point moves with the
    # point it leaves, its second with the point it reaches, so a curve between a moved and an unmoved point stays smooth.
    def moved(subpath)
      from = nil
      out = subpath.map do |command, points|
        next [command, points] if points.empty?

        to = yield(*points.last)
        shifts = command == "C" ? [from, to, to] : [to]
        from = to
        [command, points.zip(shifts).map { |(x, y), (sx, sy)| [x + sx, y + sy] }]
      end
      self.class.serialise(out)
    end

    # The Original's note says its window was cut clear; Alt's always was a hole, and its note is unchanged.
    def clear_note = @halves_role == "white" ? "; the lens window is cut out of the white layer into a hole in the silhouette, so it is see-through" : ""

    def source_note
      "derived from '#{@from}' by Logos::WeldingV2: the lens and its frame moved down #{self.class.number(dy)} to centre the lens " \
        "on the rule of 3's middle row of the helmet's ink; the box is the ink (Logos::IconInk)#{clear_note}"
    end
  end
end
