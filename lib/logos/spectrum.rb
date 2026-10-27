# frozen_string_literal: true

require_relative "brand_kit"

module Logos
  # A brand's colour SPECTRUM (task brand-colour-spectrum-ramps): an eleven-step ramp, 50 (lightest) to 950
  # (darkest), for each colour in its palette (Logos::BrandKit), the way a Tailwind scale reads. The ramp is built in
  # OKLCH: lightness follows one fixed curve (LIGHTNESS), the hue stays the colour's own, and chroma tapers toward
  # either end so tints stay clean and shades do not go muddy. The brand's hex sits UNCHANGED on the step nearest its
  # own lightness, so a dark blue lands on 700 and a light orange on 400.
  #
  # A colour with almost no chroma is a NEUTRAL: its ramp holds one faint chroma at every step instead of tapering.
  # A grey keeps its own slight hue (a blue-grey stays blue); white or black has none, and borrows the hue of the
  # brand's lead colour (the first in its palette with a hue), so the brand's neutrals lean toward it.
  #
  #   spectrum = Logos::Spectrum.new(Logos::BrandKit.new("welding_v2"))
  #   ramp = spectrum.ramps.first          # => Welding Blue
  #   ramp.anchor.step                     # => 700
  #   ramp.steps.first.hex                 # => "#F1F8FF"
  class Spectrum
    STEPS = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950].freeze
    # OKLab lightness per step, light to dark.
    LIGHTNESS = [0.975, 0.94, 0.885, 0.81, 0.72, 0.635, 0.55, 0.47, 0.39, 0.32, 0.255].freeze
    # Below NEUTRAL_BELOW chroma a colour is a neutral, tinted at least NEUTRAL_CHROMA; below HUELESS it has no hue.
    NEUTRAL_BELOW = 0.02
    NEUTRAL_CHROMA = 0.012
    HUELESS = 0.004
    WHITE = "#FFFFFF"
    BLACK = "#000000"

    # One step of a ramp. `text` is whichever of white or black reads better on it; `contrast` is that ratio (WCAG).
    Step = Data.define(:step, :hex, :anchor, :text, :contrast) do
      def anchor? = anchor
      # The WCAG grade of `text` on this step: AA for body text, AA Large for 18pt and up, nil below both.
      def grade = (contrast >= 4.5 ? "AA" : ("AA Large" if contrast >= 3))
    end

    Ramp = Data.define(:name, :hex, :token, :steps) do
      def anchor = steps.find(&:anchor?)
    end

    attr_reader :brand, :ramps

    def initialize(kit)
      @brand = kit.brand
      lead = kit.palette.map { |swatch| Spectrum.oklch(swatch.hex) }.find { |_, chroma, _| chroma >= NEUTRAL_BELOW }
      lead_hue = lead ? lead[2] : 0.0
      @ramps = kit.palette.map { |swatch| ramp(swatch, lead_hue) }.freeze
    end

    # The ramps as CSS custom properties, one block: --<brand>-<colour>-<step>: #hex;
    def css
      lines = ramps.flat_map { |ramp| ramp.steps.map { |step| "  --#{ramp.token}-#{step.step}: #{step.hex};" } }
      ":root {\n#{lines.join("\n")}\n}\n"
    end

    # "#abc" or "#AABBCC" as "#AABBCC": the kit's hex guard (NavbarLogo::HEX) takes both.
    def self.full(hex)
      digits = hex.delete("#")
      "##{(digits.size == 3 ? digits.chars.map { |digit| digit * 2 }.join : digits).upcase}"
    end

    # #RRGGBB to OKLCH as [lightness, chroma, hue in radians].
    def self.oklch(hex)
      r, g, b = full(hex).delete("#").scan(/../).map { |pair| linear(pair.to_i(16) / 255.0) }
      l = Math.cbrt((0.4122214708 * r) + (0.5363325363 * g) + (0.0514459929 * b))
      m = Math.cbrt((0.2119034982 * r) + (0.6806995451 * g) + (0.1073969566 * b))
      s = Math.cbrt((0.0883024619 * r) + (0.2817188376 * g) + (0.6299787005 * b))
      lightness = (0.2104542553 * l) + (0.7936177850 * m) - (0.0040720468 * s)
      a = (1.9779984951 * l) - (2.4285922050 * m) + (0.4505937099 * s)
      bb = (0.0259040371 * l) + (0.7827717662 * m) - (0.8086757660 * s)
      [lightness, Math.hypot(a, bb), Math.atan2(bb, a)]
    end

    # OKLCH to #RRGGBB, giving up chroma (never lightness or hue) until the colour fits in sRGB.
    def self.hex(lightness, chroma, hue)
      rgb = rgb(lightness, chroma, hue)
      until rgb.all? { |channel| channel.between?(-1e-4, 1 + 1e-4) } || chroma < 1e-4
        chroma *= 0.97
        rgb = rgb(lightness, chroma, hue)
      end
      "#" + rgb.map { |channel| format("%02X", (gamma(channel.clamp(0.0, 1.0)) * 255).round) }.join
    end

    # WCAG contrast ratio between two #RRGGBB colours. AppPalette (app/models) has the same sum, but this file runs as
    # plain Ruby with no Rails autoloader (test/lib/logos_spectrum_test.rb), as the rest of lib/logos does.
    def self.contrast(one, other)
      light, dark = [luminance(one), luminance(other)].sort.reverse
      (light + 0.05) / (dark + 0.05)
    end

    def self.luminance(hex)
      r, g, b = hex.delete("#").scan(/../).map { |pair| linear(pair.to_i(16) / 255.0) }
      (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    end

    def self.rgb(lightness, chroma, hue)
      a = chroma * Math.cos(hue)
      b = chroma * Math.sin(hue)
      l = (lightness + (0.3963377774 * a) + (0.2158037573 * b))**3
      m = (lightness - (0.1055613458 * a) - (0.0638541728 * b))**3
      s = (lightness - (0.0894841775 * a) - (1.2914855480 * b))**3
      [(4.0767416621 * l) - (3.3077115913 * m) + (0.2309699292 * s),
       (-1.2684380046 * l) + (2.6097574011 * m) - (0.3413193965 * s),
       (-0.0041960863 * l) - (0.7034186147 * m) + (1.7076147010 * s)]
    end

    def self.linear(channel) = channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055)**2.4
    def self.gamma(channel) = channel <= 0.0031308 ? 12.92 * channel : (1.055 * (channel**(1 / 2.4))) - 0.055

    private

    def ramp(swatch, lead_hue)
      lightness, chroma, hue = Spectrum.oklch(swatch.hex)
      neutral = chroma < NEUTRAL_BELOW
      hue = lead_hue if chroma < HUELESS
      anchor = LIGHTNESS.each_index.min_by { |index| (LIGHTNESS[index] - lightness).abs }
      steps = STEPS.each_with_index.map do |step, index|
        tint = neutral ? [chroma, NEUTRAL_CHROMA].max : tapered(chroma, LIGHTNESS[index] - lightness)
        hex = index == anchor ? Spectrum.full(swatch.hex) : Spectrum.hex(LIGHTNESS[index], tint, hue)
        step(step, hex, index == anchor)
      end
      Ramp.new(name: swatch.name, hex: Spectrum.full(swatch.hex), token: "#{token(brand)}-#{token(swatch.name)}", steps: steps.freeze)
    end

    # Chroma falls away with distance from the colour's own lightness: faster toward black than toward white.
    def tapered(chroma, distance)
      reach, curve = distance.positive? ? [0.75, 1.6] : [0.6, 1.4]
      chroma * (1 - ([distance.abs / reach, 1].min**curve))
    end

    def step(step, hex, anchor)
      on_white = Spectrum.contrast(hex, WHITE)
      on_black = Spectrum.contrast(hex, BLACK)
      text = on_white >= on_black ? WHITE : BLACK
      Step.new(step:, hex:, anchor:, text:, contrast: [on_white, on_black].max.round(1))
    end

    def token(words) = words.to_s.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
  end
end
