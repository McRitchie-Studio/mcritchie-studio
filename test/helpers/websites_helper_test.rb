# frozen_string_literal: true

require "test_helper"

# [unit] WebsitesHelper: the carousel options /websites asks for reach the
# engine's studio/_carousel only when its strict locals declare them.
class WebsitesHelperTest < ActionView::TestCase
  Template = Struct.new(:source)

  def with_carousel_source(source)
    finder = Struct.new(:template) { def find_template(*) = template }.new(Template.new(source))
    stub(:lookup_context, finder) { yield }
  end

  def stub(name, value)
    singleton_class.define_method(name) { value }
    yield
  ensure
    singleton_class.remove_method(name)
  end

  test "an engine without autoplay and loop gets neither" do
    with_carousel_source("<%# locals: (label:, items:, per_view: 3, start: nil) %>\n<section>") do
      assert_equal({}, carousel_optional_locals(autoplay: 6, loop: true))
    end
  end

  test "an engine that declares them gets both, and only what it declares" do
    with_carousel_source("<%# locals: (label:, items:, autoplay: nil, loop: false, start: nil) %>") do
      assert_equal({ autoplay: 6, loop: true }, carousel_optional_locals(autoplay: 6, loop: true))
    end
    with_carousel_source("<%# locals: (label:, items:,\n  autoplay: nil) %>") do
      assert_equal({ autoplay: 6 }, carousel_optional_locals(autoplay: 6, loop: true))
    end
    with_carousel_source("<%# locals: (label:, items:, autoplay_label: nil, noloop: nil) %>") do
      assert_equal({}, carousel_optional_locals(autoplay: 6, loop: true), "a longer name is not the local")
    end
  end

  test "a partial without strict locals takes any local" do
    with_carousel_source("<section><%= label %></section>") do
      assert_equal({ autoplay: 6, loop: true }, carousel_optional_locals(autoplay: 6, loop: true))
    end
  end

  test "the installed engine's carousel renders with whatever the guard passes" do
    passed = carousel_optional_locals(autoplay: 6, loop: true)
    html = render(layout: "studio/carousel", locals: { label: "Live apps", items: [ 1, 2 ] }.merge(passed)) { |item| "slide #{item}" }

    assert_includes html, "slide 2"
  end

  # The cascade (task carousel-cascade-style) arrived with visible:, a local only a
  # cascade takes, so the partial's strict locals are the capability.
  test "the Portfolio row is a spotlight on an engine without the cascade" do
    with_carousel_source("<%# locals: (label:, items:, style: :standard, autoplay: nil, loop: false) %>") do
      assert_equal :spotlight, portfolio_carousel_style
    end
  end

  test "the Portfolio row is a cascade once the engine's carousel declares visible:" do
    with_carousel_source("<%# locals: (label:, items:, style: :standard, loop: false, visible: nil) %>") do
      assert_equal :cascade, portfolio_carousel_style
    end
    with_carousel_source("<%# locals: (label:, items:, invisible: nil) %>") do
      assert_equal :spotlight, portfolio_carousel_style, "a longer name is not the local"
    end
  end

  test "a partial without strict locals keeps the spotlight: it may not know the cascade" do
    with_carousel_source("<section><%= label %></section>") do
      assert_equal :spotlight, portfolio_carousel_style
    end
  end

  test "the installed engine's carousel renders the style the helper picks, looping" do
    style = portfolio_carousel_style
    html = render(layout: "studio/carousel", locals: { label: "Live apps", items: [ 1, 2, 3 ], style: style, loop: true }) { |item| "slide #{item}" }

    assert_includes html, "carousel-#{style}"
    assert_includes html, "data-carousel-loop"
  end

  test "a card's style carries its palette and the shade at the measured alpha, else the Studio shade" do
    cyvasse = BuildGallery::Example.new(name: "Cyvasse", url: "https://cyvasse.xyz", palette: BuildGallery.palette_for("cyvasse"))
    plain = BuildGallery::Example.new(name: "Plain", url: "https://plain.mcritchie.studio", palette: nil)

    assert_includes portfolio_card_style(cyvasse), "--pc-name: #C08A2E"
    assert_includes portfolio_card_style(cyvasse), "--pc-shade: rgb(26 21 53 / #{BuildGallery::PORTFOLIO_SHADE_ALPHA})"
    assert_includes portfolio_card_style(plain), "--pc-name: #ffffff"
    assert_includes portfolio_card_style(plain), "--pc-shade: rgb(11 11 16 / #{BuildGallery::PORTFOLIO_SHADE_ALPHA})"
  end
end
