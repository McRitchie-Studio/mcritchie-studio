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
    "welding" => "d1411cdd74cf7c556bbc9b39e1a6ea5b81d11333920bb289bf8c403ec41aee07"
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
end
