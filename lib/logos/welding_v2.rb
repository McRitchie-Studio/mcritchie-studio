# frozen_string_literal: true

require "json"

module Logos
  # Commercial Welding v2's helmet, derived from v1's traced helmet (Alex's item 5, task welding-llc-and-v2-helmet):
  #
  #   1. Centred: the helmet's midline, the straight line where its blue half meets its white half, becomes the
  #      icon box's vertical centre. The box is widened on the short side, never cropped, so the ears stay whole.
  #   2. Lens down: the lens (the window, with the spark in it, as one unit) moves down so it sits on the rule of 3's
  #      middle row: its top and bottom on the row lines if it were one row tall; it is shorter, so it is centred on
  #      that row. The blue frame around the window moves with it: its outer edge is the notch the white half's
  #      contour makes around the frame, and the points of that notch move by the same amount.
  #   3. Clear lens (task kit-export-and-clear-lens): the window is a hole in the outer helmet, so the page shows
  #      through it. Alt's helmets always drew it so; the Original's trace filled it white (#clear_lens).
  #
  # The traced data's own shapes are found, not numbered. The HALVES layer holds the white half and the window: v1's
  # Alt helmets' `primary` (one blue layer, the two as holes in it) or the Original's `white` (the two as opaque white
  # shapes over a blue silhouette; task logo-original-and-alt; v2's Original then holds the window as a hole in the
  # silhouette, step 3, and reads back the same way). The outer helmet is the widest sub-path of any layer;
  # of the halves layer's other two, the white half is the taller and the window the other. Only absolute M, L, C and
  # Z are read (the potrace output); anything else is refused. `rake logos:welding_v2` writes the result to
  # data/brand_icons_welding_v2.json; docs/topics/logos.md has the steps with the numbers.
  class WeldingV2
    class Error < ArgumentError; end

    # Each group shares one box (the widest its helmets need): the two Alt helmets, which share v1's box, and the
    # Original, whose trace has its own scale.
    GROUPS = [{ "welding_v2" => "welding", "welding_v2_mono" => "welding_mono" }, { "welding_v2_original" => "welding_original" }].freeze
    SOURCES = GROUPS.reduce(:merge).freeze
    HALVES = %w[primary white].freeze          # the layer holding the white half and the window, by role, in this order
    FILE = File.join(__dir__, "data/brand_icons_welding_v2.json")
    ROWS = 3                                   # the navbar rule whose rows the lens is set on
    # How far past the window's edges the frame's points lie, in icon units: the band is 16 to 20 thick, and the next
    # point of the white half's contour (its top curve, its right edge, the midline below the frame) is over 60 away.
    FRAME_REACH = 40.0
    SPLIT_TOLERANCE = 2.0                      # the midline's points lie within this of the white half's left edge
    CORNER = 20.0                              # the white half's corners, where its left edge turns into its top and bottom curves
    # The three measures above are in v1's units, a helmet this tall; a trace at another scale (the Original's, 975
    # tall) takes them scaled to its own height (#scaled), so every helmet is read the same way.
    REFERENCE_HEIGHT = 483.0
    NUMBER = /-?\d+(?:\.\d+)?/
    SEGMENT = /([MLCZ])([^MLCZ]*)/

    # Every v2 icon, keyed as the icon data keys it, from the shipped v1 icons. They share one box, the widest either
    # needs, as v1's do: a logo's geometry is the same in every tone (the colour and the single-colour helmet are
    # separate traces, whose midlines differ by about one unit), and each is centred on its own midline in it.
    def self.icons(icons = NavbarLogo.icons)
      GROUPS.each_with_object({}) do |group, out|
        helmets = group.transform_values { |from| new(icons.fetch(from), from) }
        width = helmets.values.map(&:width).max
        out.merge!(helmets.transform_values { |helmet| helmet.icon(width) })
      end
    end

    # The data file's contents, exactly as `rake logos:welding_v2` writes them.
    def self.json(icons = NavbarLogo.icons) = JSON.generate(self.icons(icons))

    # `width` is the narrowest box centred on the midline that holds the whole helmet; `dy` moves the lens.
    attr_reader :split, :window, :dy, :width, :height

    def initialize(icon, from)
      @from = from
      @source = icon
      @height = icon.fetch("h").to_f
      @layers = icon.fetch("layers").map { |layer| [layer, self.class.subpaths(layer.fetch("d"))] }
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
      @split = midline
      @window = self.class.bbox(@lens)
      @width = (2 * [split, icon.fetch("w") - split].max).round(2)
      @dy = (height / 2 - (window[1] + window[3]) / 2).round(2)
    end

    # How far right the helmet moves to put its midline at the centre of a box `width` wide.
    def dx(width = self.width) = (width / 2 - split).round(2)

    # The v2 icon: the v1 icon's data with every layer's path moved, in a box `width` wide (at least its own).
    def icon(width = self.width)
      raise Error, "#{@from}: a box #{width} wide cannot hold the helmet centred (it needs #{self.width})" if width < self.width

      across = dx(width)
      shapes = { @outer => ->(*) { [across, 0] }, @hole => ->(x, y) { frame?(x, y) ? [across, dy] : [across, 0] }, @lens => ->(*) { [across, dy] } }
      layers = @layers.map do |layer, subpaths|
        # A layer holding the outer helmet, the white half or the window is written in that order (v1's primary was
        # written so), and every other sub-path (the spark) moves with the lens.
        found = shapes.keys.select { |shape| subpaths.any? { |sub| sub.equal?(shape) } }
        raise Error, "#{@from}: the #{layer['role']} layer mixes the helmet's halves with other shapes" if found.any? && found.size != subpaths.size

        d = if found.any?
              clear_lens(found).map { |shape| moved(shape, &shapes.fetch(shape)) }.join
            else
              subpaths.map { |sub| moved(sub) { [across, dy] } }.join
            end
        layer.merge("d" => d)
      end
      { "w" => width, "h" => @source.fetch("h"), "source" => source_note(across, width), "layers" => layers }
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
    def self.subpaths(d)
      raise Error, "only absolute M, L, C and Z path data can be moved: #{d[0, 40].inspect}" unless d.match?(/\A(?:[MLCZ][-\d., ]*)+\z/)

      segments = d.scan(SEGMENT).map { |command, numbers| [command, numbers.scan(NUMBER).map(&:to_f).each_slice(2).to_a] }
      segments.slice_before { |command, _| command == "M" }.to_a
    end

    def self.serialise(subpath)
      subpath.map { |command, points| command + points.map { |x, y| "#{number(x)},#{number(y)}" }.join(" ") }.join
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

    # The midline: the mean x of the white half's straight left edge: its on-curve points within SPLIT_TOLERANCE of
    # the leftmost, leaving out the corners where the edge turns into the top and bottom curves (CORNER of each end).
    def midline
      _, top, _, bottom = self.class.bbox(@hole)
      corner = scaled(CORNER)
      points = @hole.flat_map { |_, segment| segment.last(1) }.select { |_, y| y.between?(top + corner, bottom - corner) }
      left = points.map(&:first).min
      edge = points.map(&:first).select { |x| x <= left + scaled(SPLIT_TOLERANCE) }
      edge.sum / edge.size
    end

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

    def source_note(dx, width)
      "derived from '#{@from}' by Logos::WeldingV2: moved right #{self.class.number(dx)} so the line where the helmet's two " \
        "halves meet (x = #{self.class.number(split)}) is the box's centre, in a box #{self.class.number(width)} wide; the lens " \
        "and its frame moved down #{self.class.number(dy)} to centre the lens on the rule of 3's middle row#{clear_note}"
    end
  end
end
