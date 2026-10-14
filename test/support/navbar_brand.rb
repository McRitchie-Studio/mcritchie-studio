# frozen_string_literal: true

# NavbarBrand: how the engine navbar draws this app's brand, for the tests that look for it
# (task studio-adopts-its-kit).
#
# config/initializers/studio.rb sets Studio.navbar_wordmark (the saved kit's Navbar Logo, public/brand/navbar-*.svg)
# once the bundled studio-engine has the setting (navbar-kit-wordmark-option). Before that the navbar draws the kit
# icon beside the words "McRitchie Studio" in .nav-title; after it, one lockup image per theme in .nav-wordmark-brand,
# the app name as its alt text. Both forms sit in the same brand tag (an h1 or a div), so a test asks for the brand
# through here and stays right on either side of the engine relock.
module NavbarBrand
  WORDS = "McRitchieStudio" # .nav-title's text: the two words, squished together by the markup

  module_function

  def wordmark? = Studio.respond_to?(:navbar_wordmark) && Studio.navbar_wordmark.present?

  # What the brand heading reads as: its words, or the lockup's alt text (see #heading_text).
  def brand_name = wordmark? ? Studio.app_name : WORDS

  # A heading's text, or, for a heading that is only a picture (the lockup), its first image's alt text.
  def heading_text(heading) = heading.text.squish.presence || heading.at_css("img")&.[]("alt").to_s

  # The brand tag's class, for `tag` ("h1", "div" or "" for either).
  def selector(tag = "") = "#{tag}#{wordmark? ? '.nav-wordmark-brand' : '.nav-title'}"

  # assert_select arguments that match `count` drawn brands in `tag`.
  def assert_drawn(test, tag = "", count: 1, message: nil)
    if wordmark?
      test.assert_select "#{selector(tag)} img.nav-wordmark-light[src='/brand/navbar-light.svg'][alt=?]", Studio.app_name,
                         { count: }, message
    else
      test.assert_select selector(tag), { text: WORDS, count: }, message
    end
  end
end
