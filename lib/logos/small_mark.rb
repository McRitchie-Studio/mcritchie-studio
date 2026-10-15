# frozen_string_literal: true

require_relative "icon_ink"

module Logos
  # THE SMALL-SIZE MARK: an icon with its specks dropped, for sizes where they cannot be seen (task
  # footer-stacked-logo). A mark is checked at 64, 32 and 16 px, the submark convention: below about 64 px a traced
  # icon's loose details (the studio chest's sparkles, side dashes and loose coins) draw as one-pixel specks, and
  # because an icon's box is its ink (Logos::IconInk) they also set its box, so the part that reads shrinks inside the
  # tile. On the studio favicon the chest filled about 70% of the browser tab. Alex 2026-10-15 08:10, pointing at the
  # old favicon (a crop of the chest alone): "That is the correct size".
  #
  # Derived, never drawn: the icon's path data is split into its islands (a subpath no other subpath's box holds,
  # with every subpath inside it, which keeps an evenodd hole with the shape it cuts), and an island whose box is
  # smaller than MIN_SHARE of the icon's box is dropped. The kept subpaths are written back exactly as they were read,
  # and the result is trimmed to its ink, so its box is its ink like every other icon.
  #
  #   Logos::SmallMark.derive(icon)            # => the icon without its specks, trimmed
  #   Logos::SmallMark.crop(mark)              # => that mark framed as the favicon: a square on its body
  #   Logos::SmallMark.svg(icon, fill: "#8E82FE")  # => an icon as an SVG document
  #
  # Only the favicon draws from it (bin/rails logos:favicon_mark, then script/brand_png.cjs). The kit icon, the
  # navbar, the footer, the sign-in card and the PWA app icon keep the full icon.
  module SmallMark
    class Error < ArgumentError; end

    MIN_SHARE = 0.02 # an island smaller than this share of the icon's box area is a speck
    SUBPATH = /M[^M]*/

    module_function

    def derive(icon, min_share: MIN_SHARE)
      box_area = area(IconInk.box(icon))
      layers = icon.fetch("layers").map do |layer|
        boxes = subpath_boxes(icon, layer)
        kept = islands(boxes).select { |_, box| area(box) >= min_share * box_area }.map(&:last)
        d = boxes.select { |_, box| kept.any? { |island| island.equal?(box) || holds?(island, box) } }.map(&:first).join
        layer.merge("d" => d)
      end
      layers.reject! { |layer| layer["d"].strip.empty? }
      raise Error, "no island of the icon is at least #{min_share} of its area" if layers.empty?

      IconInk.trim(icon.merge("layers" => layers))
    end

    # THE FAVICON IS A CROP, NOT A FIT (Alex 2026-10-15 08:22: "The goal is to make the favicon large so it's easy to
    # spot"). The mark's BODY is every island at least BODY_SHARE of its box (for the studio chest, its front and side:
    # not the lid or the sword). The favicon is a square CROP_SIDE of the body's width, centred across the body and
    # standing on its bottom edge, so the chest overfills the tile as the old chest-only favicon did: the body's two
    # sides, the lid's top edge and the sword's tip are clipped, the keyhole plate and the lid's curve stay. At 0.82
    # its opaque coverage (0.72) beats the old favicon's (0.67); a square as wide as the body covers only 0.58, since
    # a stacked chest is wider than it is tall. Only the box moves: the paths are untouched.
    BODY_SHARE = 0.2
    CROP_SIDE = 0.82

    def crop(mark, body_share: BODY_SHARE, side_share: CROP_SIDE)
      box_area = area(IconInk.box(mark))
      body = mark.fetch("layers").flat_map { |layer| islands(subpath_boxes(mark, layer)).map(&:last) }
                 .select { |box| area(box) >= body_share * box_area }
      raise Error, "no island of the mark is at least #{body_share} of its area" if body.empty?

      left, _top, right, bottom = body.transpose.each_with_index.map { |values, i| i < 2 ? values.min : values.max }
      side = (right - left) * side_share
      x0 = (left + right - side) / 2
      y0 = bottom - side
      mark.merge("w" => number(side), "h" => number(side), "transform" => ["translate(#{number(-x0)},#{number(-y0)})", mark["transform"]].compact.join(" "))
    end

    # [[subpath, its ink box]] for one layer, in the icon's box.
    def subpath_boxes(icon, layer) = layer.fetch("d").scan(SUBPATH).map { |subpath| [subpath, IconInk.box(bare(icon, subpath))] }

    # The islands among subpath boxes: a box no other box holds. Two with the same box: the first holds the second.
    def islands(boxes)
      boxes.each_with_index.reject do |(_, box), i|
        boxes.each_with_index.any? { |(_, other), j| j != i && holds?(other, box) && (other != box || j < i) }
      end.map(&:first)
    end

    def number(value)
      rounded = value.round(2)
      rounded == rounded.round ? rounded.round : rounded
    end

    # The mark as a standalone SVG: its box, its transform, every layer filled with `fill`.
    def svg(icon, fill:)
      w = icon.fetch("w")
      h = icon.fetch("h")
      paths = icon.fetch("layers").map do |layer|
        %(<path d="#{layer.fetch('d')}" fill="#{fill}" fill-rule="#{layer['fill_rule'] || 'nonzero'}"/>)
      end.join
      body = icon["transform"] ? %(<g transform="#{icon['transform']}">#{paths}</g>) : paths
      %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{w} #{h}" width="#{w}" height="#{h}">#{body}</svg>\n)
    end

    # A one-subpath icon in the same transform, to measure that subpath's ink.
    def bare(icon, subpath) = { "w" => icon["w"], "h" => icon["h"], "transform" => icon["transform"], "layers" => [{ "d" => subpath }] }

    def holds?(outer, inner) = outer[0] <= inner[0] && outer[1] <= inner[1] && outer[2] >= inner[2] && outer[3] >= inner[3]

    def area(box) = (box[2] - box[0]) * (box[3] - box[1])
  end
end
