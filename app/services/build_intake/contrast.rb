module BuildIntake
  # Hex colours and WCAG 2 contrast, for the palettes Ray proposes. Code, never
  # the model, decides whether a palette's text can be read on its surface.
  module Contrast
    HEX = /\A#?(\h{3}|\h{6})\z/
    # WCAG AA for body text.
    MIN_TEXT_RATIO = 4.5

    module_function

    # "#RGB", "rgb", "#RRGGBB" → "#rrggbb"; anything else → nil.
    def normalize(value)
      match = HEX.match(value.to_s.strip)
      return nil unless match

      digits = match[1].downcase
      digits = digits.chars.map { |c| c * 2 }.join if digits.length == 3
      "##{digits}"
    end

    # WCAG relative luminance of a normalized hex colour, 0.0 to 1.0.
    def luminance(hex)
      r, g, b = hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) / 255.0 }
      linear = ->(c) { c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
      (0.2126 * linear.call(r)) + (0.7152 * linear.call(g)) + (0.0722 * linear.call(b))
    end

    # The ink that reads on `hex`: near-black or white, whichever contrasts more.
    def ink_on(hex) = ratio(hex, "#ffffff") >= ratio(hex, "#111111") ? "#ffffff" : "#111111"

    # The contrast ratio of two colours, 1.0 to 21.0.
    def ratio(one, two)
      a = luminance(one)
      b = luminance(two)
      lighter, darker = [ a, b ].max, [ a, b ].min
      ((lighter + 0.05) / (darker + 0.05)).round(2)
    end
  end
end
