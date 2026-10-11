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
    "studio" => "76cfc2cf8c56af93bbd5334773663f5741bd70b44c1ea298f5f997083c4d1331",
    "industries" => "dcdca12428a65e46d7a821b31f13c9e1337fa57a93d89bfec4c2fa3bd2c3524e",
    "turf" => "2b18c47ce5a2c08231f558ad17581f9d4bee1020c5d6d1fa676ce83ef9c2eb9f",
    # Re-taken DELIBERATELY by task welding-llc-and-v2-helmet, when Commercial Welding v1 took its whole name, COMMERCIAL WELDING LLC (Alex, item 5); was d1411cdd…. The three
    # others above did not move by a byte.
    # Re-taken by the review fix: the stacked two-line small line keeps its WELDING LLC word gap when tracked (only
    # its two-line drawings changed); was 854451d3….
    "welding" => "5b868519638df887718aaaf5aeebc0ea1a3d075d593148a4eef7c877f202aa43",
    # Added by task welding-llc-and-v2-helmet: Commercial Welding v2 as it first shipped.
    "welding_v2" => "63a49eae4d6d076ccb9498a427f6e4db1dd8e28f20c49cb57989586476215a6a"
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
    "welding" => "0f1083dc461623e7bb84e07049ce8c14e10ad581c1200b74023413279a2a65d4",
    "welding_v2" => "7635ac2b3d772e1f573a93f6ffff854ce81347f5b94871c02075fe922a064984"
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
