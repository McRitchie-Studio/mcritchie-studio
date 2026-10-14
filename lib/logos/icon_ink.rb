# frozen_string_literal: true

require "json"

module Logos
  # AN ICON'S BOX IS ITS INK (task stacked-rule-of-three; Alex 2026-10-14 12:16: "The icons need to have the margins
  # cleaned up so we don't have extra variables when building out the logos and themes"). Every icon in the icon
  # data is `{"w", "h", "transform"?, "layers"}`, drawn in the box 0 0 w h; this measures where its ink actually lies
  # in that box and trims the box to it. It is the ONE place margins are handled: the Navbar and Stacked Logos, the
  # icon alone, the kit export and the favicon (script/brand_png.cjs, drawn from the exported icon) all take an
  # icon's box as its size, so none of them needs margin handling of its own.
  #
  #   Logos::IconInk.box(icon)      # => [left, top, right, bottom] of the ink, in the icon's box
  #   Logos::IconInk.margins(icon)  # => { left: 0.0, top: 0.0, right: 17.75, bottom: 1.5 }
  #   Logos::IconInk.trim(icon)     # => the icon with its box moved and cut to the ink (paths untouched)
  #
  # Trimming never touches a layer's path data: it prepends a translate to the icon's `transform` (folded into a
  # leading translate where there is one) and sets `w` and `h` to the ink's size. The ink is exact: the path's
  # on-curve points and every cubic's turning points, after the icon's transform; a stroked layer's ink reaches half
  # its stroke width past its path. Only absolute M, L, C and Z path data can be measured (all the traced and kit
  # data is), so an icon in anything else is refused with Error rather than measured wrongly.
  #
  # NavbarLogo#checked_icon refuses any icon whose box is not its ink (TOLERANCE), so an icon added to the data
  # later must come in trimmed: `bin/rails logos:trim_icons` trims every icon data file, and Logos::WeldingV2 trims
  # what it derives.
  module IconInk
    class Error < ArgumentError; end

    TOLERANCE = 0.5                            # design units an icon's box may differ from its ink on any side
    PLACES = 2                                 # a trimmed box's numbers are written to this many decimals
    SEGMENT = /([MLCZ])([^MLCZ]*)/
    NUMBER = /[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/
    CALL = /(translate|scale|rotate|matrix)\(([^)]*)\)/
    @boxes = {}.compare_by_identity

    class << self
      # [left, top, right, bottom] of the icon's ink in its own box, after its transform. Measured once per icon object.
      def box(icon) = @boxes[icon] ||= measure(icon).freeze

      # How far the box reaches past the ink on each side (negative: the ink overhangs the box).
      def margins(icon)
        left, top, right, bottom = box(icon)
        { left:, top:, right: icon.fetch("w").to_f - right, bottom: icon.fetch("h").to_f - bottom }
      end

      # True when every margin is within TOLERANCE of zero.
      def trimmed?(icon) = margins(icon).values.all? { |margin| margin.abs <= TOLERANCE }

      # The icon with its box cut to its ink: a translate before its transform, and w and h the ink's size. An icon
      # already within 1/100 of a unit on every side is returned as it is, so trimming twice changes nothing.
      def trim(icon)
        return icon if margins(icon).values.all? { |margin| margin.abs < 0.01 }

        left, top, right, bottom = box(icon)
        icon.merge("w" => number(right - left), "h" => number(bottom - top), "transform" => moved(icon["transform"], -left, -top))
      end

      # An icon data file's contents (a JSON map of key => icon) with every icon trimmed, and the keys that changed.
      # The path data is written back exactly as it was read.
      def trim_data(json)
        icons = JSON.parse(json)
        trimmed = icons.transform_values { |icon| trim(icon) }
        [JSON.generate(trimmed), trimmed.keys.reject { |key| trimmed[key].equal?(icons[key]) }]
      end

      # The affine matrix [a, b, c, d, e, f] of an SVG transform list (nil: none): x' = a x + c y + e, y' = b x + d y + f.
      def matrix(transform)
        transform.to_s.scan(CALL).reduce([1.0, 0.0, 0.0, 1.0, 0.0, 0.0]) do |m, (name, args)|
          multiply(m, call_matrix(name, args.scan(NUMBER).map(&:to_f)))
        end
      end

      private

      def measure(icon)
        m = matrix(icon["transform"])
        xs = []
        ys = []
        icon.fetch("layers").each do |layer|
          reach = layer["paint"] == "stroke" ? layer.fetch("stroke_width").to_f / 2 * Math.sqrt((m[0] * m[3] - m[1] * m[2]).abs) : 0.0
          lx, ly = ink(layer.fetch("d"), m)
          next if lx.empty?

          xs.push(lx.min - reach, lx.max + reach)
          ys.push(ly.min - reach, ly.max + reach)
        end
        raise Error, "the icon has no ink to measure" if xs.empty?

        [xs.min, ys.min, xs.max, ys.max]
      end

      # Every x and y the path's ink reaches, after the matrix: on-curve points and each cubic's turning points (an
      # affine map of a cubic is the cubic of its mapped control points, so they are mapped first).
      def ink(d, m)
        unless d.strip.empty? || d.match?(/\A\s*(?:[MLCZ][-+\d.,eE\s]*)+\z/)
          raise Error, "an icon's ink can be measured only in absolute M, L, C and Z path data: #{d[0, 40].inspect}"
        end

        xs = []
        ys = []
        current = nil
        start = nil
        d.scan(SEGMENT).each do |command, numbers|
          points = numbers.scan(NUMBER).map(&:to_f).each_slice(2).map { |x, y| apply(m, x, y) }
          case command
          when "M", "L"
            points.each { |point| xs << point[0]; ys << point[1] }
            start = points.first if command == "M"
            current = points.last
          when "C"
            points.each_slice(3) do |c1, c2, to|
              [0, 1].each { |axis| (axis.zero? ? xs : ys).concat(extremes(current[axis], c1[axis], c2[axis], to[axis])) }
              xs << to[0]
              ys << to[1]
              current = to
            end
          when "Z" then current = start
          end
        end
        [xs, ys]
      end

      # A cubic's values where its derivative is zero inside (0, 1).
      def extremes(p0, p1, p2, p3)
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

      def apply(m, x, y) = [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]]

      def multiply(m, n)
        [m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1], m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3],
         m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5]]
      end

      def call_matrix(name, args)
        case name
        when "translate" then [1.0, 0.0, 0.0, 1.0, args[0] || 0.0, args[1] || 0.0]
        when "scale" then [args[0], 0.0, 0.0, args[1] || args[0], 0.0, 0.0]
        when "matrix" then args
        else
          angle = args[0] * Math::PI / 180
          rotation = [Math.cos(angle), Math.sin(angle), -Math.sin(angle), Math.cos(angle), 0.0, 0.0]
          return rotation if args.size < 3

          [[1.0, 0.0, 0.0, 1.0, args[1], args[2]], rotation, [1.0, 0.0, 0.0, 1.0, -args[1], -args[2]]].reduce { |a, b| multiply(a, b) }
        end
      end

      # The transform with (dx, dy) applied before it in the box: folded into a leading translate, else prepended.
      def moved(transform, dx, dy)
        lead = transform.to_s[/\Atranslate\(([^)]*)\)/, 1]
        if lead
          x, y = lead.scan(NUMBER).map(&:to_f)
          rest = transform.sub(/\Atranslate\([^)]*\)\s*/, "")
          return [translate(x + dx, (y || 0.0) + dy), (rest unless rest.strip.empty?)].compact.join(" ")
        end
        [translate(dx, dy), transform].compact.join(" ")
      end

      def translate(x, y) = "translate(#{text(x)},#{text(y)})"

      # A number as the data writes it: an integer bare, else to PLACES decimals with no trailing zeros.
      def number(value)
        rounded = value.round(PLACES)
        rounded == rounded.round ? rounded.round : rounded
      end

      def text(value) = number(value).to_s
    end
  end
end
