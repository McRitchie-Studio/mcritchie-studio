# /marketing-kit: the Studio brand's logos, colours and typefaces, for anyone
# to use. Public by config/navigation.yml. The colours and typefaces are read
# from config/logo_brands.yml; the logos are the kit files in public/brand,
# which are static, so a visitor can download them without signing in.
class MarketingKitController < ApplicationController
  BRAND = "studio"
  LOGOS = [
    { title: "Stacked logo", file: "stacked" },
    { title: "Navbar logo", file: "navbar" },
    { title: "Icon", file: "icon" }
  ].freeze

  def index
    @kit = Logos::BrandKit.new(BRAND)
    @tagline = Logos::NavbarLogo.styles.fetch(BRAND)["tagline"]
    @logos = LOGOS
  end
end
