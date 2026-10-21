# frozen_string_literal: true

module ClientApps
  module StudioKit
    # The navbar's mark: the CTO's portrait SVG as an <img> data URI (the bundle
    # CSP allows img-src data:). A portrait that follows the colour scheme
    # (`@media (prefers-color-scheme: …)` in its own <style>) would follow the
    # DEVICE inside an <img>, which no page script can reach, and not the kit's
    # toggle. So such a portrait is drawn twice, one fixed variant per theme,
    # and the kit's CSS shows the one matching the root's `dark` class
    # (data-studio-kit-when, as the theme toggle's icons do).
    module Mark
      SCHEME = /@media\s*\(\s*prefers-color-scheme\s*:\s*(dark|light)\s*\)\s*\{/i

      module_function

      # [light, dark] SVG strings; dark is nil when the portrait does not follow
      # the colour scheme (one image serves both themes).
      def variants(svg)
        return [ nil, nil ] if svg.nil?

        text = svg.to_s.dup.force_encoding(Encoding::UTF_8)
        return [ text, nil ] unless text.match?(SCHEME)

        [ fixed(text, "light"), fixed(text, "dark") ]
      end

      # SVG with every colour-scheme block resolved for THEME: the matching
      # block's rules kept, in place, outside their @media; the other's dropped.
      def fixed(svg, theme)
        out = +""
        rest = svg
        while (match = rest.match(SCHEME))
          out << match.pre_match
          body, after = split_block(match.post_match)
          out << body if match[1].casecmp?(theme)
          rest = after
        end
        out << rest
      end

      # The text up to the brace closing the block just opened, and what follows it.
      def split_block(text)
        depth = 1
        text.each_char.with_index do |char, index|
          depth += 1 if char == "{"
          depth -= 1 if char == "}"
          return [ text[0...index], text[(index + 1)..] ] if depth.zero?
        end
        [ text, "" ]
      end

      def data_uri(svg) = svg && "data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}"
    end
  end
end
