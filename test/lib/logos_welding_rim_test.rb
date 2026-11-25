# frozen_string_literal: true

# [component] Commercial Welding's helmet rim (task welding-helmet-even-rim). The blue rim round the helmet's white
# half is one width along the top, the right side and the bottom, and meets the blue half without tapering (Alex
# McRitchie 2026-11-25: "The outline should be consistent in width"). The trace tapered it from about 34 units on the
# right side to about 12 at the midline; the white half's outer edge is now the silhouette inset by the right side's
# width, cut at the midline and round the lens frame, and the outline's peaks moved onto the midline. Every v1 helmet holds it, and each v2 helmet is derived from one.

require "minitest/autorun"
require_relative "../../lib/logos/navbar_logo"
require_relative "../../lib/logos/welding_v2"

class LogosWeldingRimTest < Minitest::Test
  V2 = Logos::WeldingV2
  HELMETS = %w[welding welding_mono welding_original welding_v2 welding_v2_mono welding_v2_original].freeze
  STEPS = 16 # points per curve when a sub-path is flattened

  # [outer helmet, white half] as polylines, in the source's box.
  def shapes(key)
    helmet = V2.new(Logos::NavbarLogo.icons.fetch(key), key)
    %i[@outer @hole].map { |name| densify(flatten(helmet.instance_variable_get(name))) }
  end

  # A point at least every 2 units along the closed polyline, so a long straight edge is measured along its length.
  def densify(points)
    (points + [points.first]).each_cons(2).flat_map do |(ax, ay), (bx, by)|
      n = [(Math.hypot(bx - ax, by - ay) / 2).ceil, 1].max
      (0...n).map { |i| [ax + ((bx - ax) * i / n), ay + ((by - ay) * i / n)] }
    end
  end

  def flatten(subpath)
    points = []
    subpath.each do |command, pts|
      if command == "C"
        p0 = points.last
        (1..STEPS).each do |i|
          t = i.fdiv(STEPS)
          u = 1 - t
          points << [0, 1].map { |a| (u**3 * p0[a]) + (3 * u * u * t * pts[0][a]) + (3 * u * t * t * pts[1][a]) + (t**3 * pts[2][a]) }
        end
      else
        points.concat(pts)
      end
    end
    points
  end

  def distance(point, polyline)
    polyline.each_cons(2).map { |a, b| segment_distance(point, a, b) }.min
  end

  def segment_distance((px, py), (ax, ay), (bx, by))
    dx = bx - ax
    dy = by - ay
    length = (dx * dx) + (dy * dy)
    t = length.zero? ? 0 : (((px - ax) * dx) + ((py - ay) * dy)).fdiv(length).clamp(0, 1)
    Math.hypot(px - (ax + (t * dx)), py - (ay + (t * dy)))
  end

  # The helmet's top and bottom peaks sit on the line where the blue half meets the white (Alex McRitchie 2026-11-25:
  # "The points should match the blue/white transition line"); the trace had them about 26 units right of it.
  HELMETS.each do |key|
    define_method("test_#{key}_peaks_sit_on_the_midline") do
      outer, half = shapes(key)
      ys = outer.map(&:last)
      midline = half.map(&:first).min
      [[ys.min, :<], [ys.max, :>]].each do |edge, _|
        peak = outer.select { |_, y| (y - edge).abs < 0.5 }.map(&:first)
        assert_in_delta midline, peak.sum / peak.size, 3.0 * ys.max / 483.0, "#{key}: the #{edge == ys.min ? 'top' : 'bottom'} peak"
      end
    end
  end

  HELMETS.each do |key|
    define_method("test_#{key}_rim_is_one_width") do
      outer, half = shapes(key)
      outer_ring = outer + [outer.first]
      half_ring = half + [half.first]
      xs = half.map(&:first)
      top, bottom = half.map(&:last).minmax
      # The right side's width below the ears, where the trace was always even.
      band = half.select { |_, y| y.between?(top + (0.55 * (bottom - top)), top + (0.8 * (bottom - top))) }
      right = band.select { |x, _| x > band.map(&:first).max - 1 }
      rim = right.map { |p| distance(p, outer_ring) }.sum / right.size

      # The right ear keeps the trace's white ear and its own thinner rim (Alex McRitchie 2026-11-25: "the right ear
      # should be white"), so the ear's rows are left out of both checks.
      ear_top, ear_bottom = [0.2, 0.5].map { |f| outer.map(&:last).min + (f * (outer.map(&:last).max - outer.map(&:last).min)) }

      # The white half's edge never comes nearer the outside than the rim (it tapered to about a third of it).
      nearest = half.reject { |_, y| y.between?(ear_top, ear_bottom) }.map { |p| distance(p, outer_ring) }.min
      assert_in_delta rim, nearest, rim * 0.08, "#{key}: the rim thins to #{nearest.round(1)} of #{rim.round(1)}"

      # Nor does the rim grow: every point of the outside, right of the midline and past the ears, is one rim away.
      far = outer.select { |x, y| x > xs.min + (2 * rim) && !y.between?(ear_top, ear_bottom) }
                 .map { |p| distance(p, half_ring) }.max
      assert_in_delta rim, far, rim * 0.08, "#{key}: the rim grows to #{far.round(1)} of #{rim.round(1)}"
    end
  end
end
