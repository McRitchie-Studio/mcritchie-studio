# frozen_string_literal: true

# [unit] One byte pin per brand (task welding-llc-and-v2-helmet): SHA-256 over EVERYTHING the library draws for the
# brand: every Navbar Logo (3 rules x 3 texts x 3 tones, with and without guides), every Stacked Logo (each form it
# draws x 3 texts x 3 tones, with and without guides) and its icon in each tone. The combined digests in
# logos_navbar_logo_test.rb and logos_stacked_logo_test.rb mix brands, so when one brand changes by design they all
# move; these say WHICH brand moved. Taken on `accepted` at e1a81a86b, before this task changed anything.

require "digest"
require "minitest/autorun"
require_relative "../../lib/logos/navbar_logo"
require_relative "../../lib/logos/stacked_logo"

class LogosBrandPinsTest < Minitest::Test
  Navbar = Logos::NavbarLogo
  Stacked = Logos::StackedLogo
  DIGESTS = {
    # Re-taken DELIBERATELY by task stacked-rule-of-three, when every icon's box became its ink (Logos::IconInk; Alex McRitchie
    # 2026-10-14 12:16: "the icons need to have the margins cleaned up"); was 76cfc2cf…. Industries did not move.
    "studio" => "18c873e9593a7a476b4e9377483aa02d9fe77cb1961bfa87efca100c96004e53",
    "industries" => "dcdca12428a65e46d7a821b31f13c9e1337fa57a93d89bfec4c2fa3bd2c3524e",
    # Re-taken DELIBERATELY by task logo-original-and-alt, when Turf Monster's Alt became its single-colour head (turf_mono in the brand green) so Alt is one solid colour per part for every brand; the three-colour head is now its Original; was 2b18c47c….
    # Re-taken DELIBERATELY by task stacked-rule-of-three, when every icon's box became its ink (Logos::IconInk; Alex McRitchie
    # 2026-10-14 12:16: "the icons need to have the margins cleaned up"); was 0015bbd7…. Industries did not move.
    # Re-taken DELIBERATELY by task turf-two-lines-and-welding-blue, when Turf Monster gained the two-line form beside its
    # own one line (Alex McRitchie 2026-10-28, Option A); its existing drawings did not move: without the two-line ones
    # the digest is still c1f383a9….
    "turf" => "334788795e0f9759eadbbfca57cf8aa5722332e3c83cad7a25fe8273f09632a2",
    # Re-taken DELIBERATELY by task welding-llc-and-v2-helmet (v1's whole name, COMMERCIAL WELDING
    # LLC; was d1411cdd…); by its review fix (the stacked WELDING LLC word gap; was 854451d3…); by
    # task stacked-rule-of-three (every icon's box became its ink, Logos::IconInk; was 5b868519…);
    # and by task turf-two-lines-and-welding-blue (Alt on a dark page drew the Original's helmet,
    # its tagline took Spark Orange; was 4e2f0a55…). Each on Alex McRitchie's call.
    # History: task turf-two-lines-and-welding-blue.
    "welding" => "42dff7bd63f7b8d186ab18f1a5e969ebdaff49099ebd8c7ed64d7b85500a1afe",
    # Added by task welding-llc-and-v2-helmet: Commercial Welding v2 as it first shipped.
    # Re-taken DELIBERATELY by task stacked-rule-of-three, when every icon's box became its ink (Logos::IconInk; Alex McRitchie
    # 2026-10-14 12:16: "the icons need to have the margins cleaned up"); was 63a49eae…. Industries did not move.
    # Re-taken DELIBERATELY by task turf-two-lines-and-welding-blue, as v1 above (the dark drawings and icon only); was
    # 08ebb18f….
    "welding_v2" => "683dd0cf51e1ebcfe4acb9ba8ff160cba1072a7e710759f95687314763d3cf36"
  }.freeze

  def self.drawings(brand)
    navbar = Navbar.new(brand)
    stacked = Stacked.new(brand)
    flags = [false, true]
    navbars = Navbar::RULES.keys.product(Navbar::TEXTS, Navbar::TONES, flags).map do |rule, text, tone, guides|
      "#{brand}-navbar-rule#{rule}-#{text}-#{tone}-#{guides}\n#{navbar.svg(rule:, text:, tone:, guides:)}"
    end
    stackeds = stacked.forms.product(Navbar::TEXTS, Navbar::TONES, flags).map do |form, text, tone, guides|
      "#{brand}-stacked-#{form}-#{text}-#{tone}-#{guides}\n#{stacked.svg(form:, text:, tone:, guides:)}"
    end
    navbars + stackeds + Navbar::TONES.map { |tone| "#{brand}-icon-#{tone}\n#{navbar.icon_svg(tone:)}" }
  end

  def self.digest(brand) = Digest::SHA256.hexdigest(drawings(brand).join)

  def test_each_brand_draws_exactly_what_it_drew_when_pinned
    assert_equal DIGESTS, Navbar.brands.to_h { |brand| [brand, self.class.digest(brand)] }
  end

  # Task logo-original-and-alt: every ORIGINAL drawing of each brand that has one (light and dark: the watermark has
  # no colouring), pinned as first shipped. DIGESTS above are the Alt drawings, which that task left as they were.
  ORIGINAL_DIGESTS = {
    "industries" => "164e879afa7dfec2a5336d4113c56234cb40d0742d775479f79d4c1557e61bf3",
    # Re-taken DELIBERATELY by task stacked-rule-of-three, when every icon's box became its ink (Logos::IconInk; Alex McRitchie
    # 2026-10-14 12:16: "the icons need to have the margins cleaned up"); was 9ba3b7bf…. Industries did not move.
    # Re-taken DELIBERATELY by task turf-two-lines-and-welding-blue, when Turf Monster gained the two-line form beside its
    # own one line (Alex McRitchie 2026-10-28, Option A); its existing drawings did not move: without the two-line ones
    # the digest is still 3c80db67….
    "turf" => "7f23ccfc3622d45124f2520a32532f717c487ecda85f0f3a9bbfdad6fe13cffa",
    # Re-taken DELIBERATELY by task stacked-rule-of-three, when every icon's box became its ink (Logos::IconInk; Alex McRitchie
    # 2026-10-14 12:16: "the icons need to have the margins cleaned up"); was 0f1083dc…. Industries did not move.
    "welding" => "18303e01ec58165a44809c855ef481cf98f5504dcdf342c8b77f637b4a5e0b12",
    # Re-taken DELIBERATELY by task kit-export-and-clear-lens, when v2's Original lens window became a hole in the
    # silhouette, not an opaque white shape (Alex McRitchie 2026-10-12: "remove the white of the lens so I can see it clear"); was
    # 7635ac2b…. Every other pin, Alt and Original, did not move by a byte.
    # Re-taken DELIBERATELY by task stacked-rule-of-three, when every icon's box became its ink (Logos::IconInk; Alex McRitchie
    # 2026-10-14 12:16: "the icons need to have the margins cleaned up"); was da4a25d2…. Industries did not move.
    "welding_v2" => "c7edf77bf74e9c6dcdcc3f25801025826d0ddc9c3deda92ca11e693f94c6d68a"
  }.freeze

  def self.original_drawings(brand)
    navbar = Navbar.new(brand)
    stacked = Stacked.new(brand)
    flags = [false, true]
    navbars = Navbar::RULES.keys.product(Navbar::TEXTS, Navbar::BAKED, flags).map do |rule, text, tone, guides|
      "#{brand}-navbar-rule#{rule}-#{text}-#{tone}-original-#{guides}\n#{navbar.svg(rule:, text:, tone:, guides:, colouring: :original)}"
    end
    stackeds = stacked.forms.product(Navbar::TEXTS, Navbar::BAKED, flags).map do |form, text, tone, guides|
      "#{brand}-stacked-#{form}-#{text}-#{tone}-original-#{guides}\n#{stacked.svg(form:, text:, tone:, guides:, colouring: :original)}"
    end
    navbars + stackeds + Navbar::BAKED.map { |tone| "#{brand}-icon-#{tone}-original\n#{navbar.icon_svg(tone:, colouring: :original)}" }
  end

  def test_each_original_draws_exactly_what_it_drew_when_pinned
    originals = Navbar.brands.select { |brand| Navbar.new(brand).original? }
    assert_equal ORIGINAL_DIGESTS, originals.to_h { |brand| [brand, Digest::SHA256.hexdigest(self.class.original_drawings(brand).join)] }
  end
end
