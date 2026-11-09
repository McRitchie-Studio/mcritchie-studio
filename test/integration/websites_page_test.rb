# frozen_string_literal: true

require "test_helper"

# [integration] /websites: the public page of apps built on Studio.
class WebsitesPageTest < ActionDispatch::IntegrationTest
  # /chat once the wall opens it, /build until then (LinkTreeHelper#visitor_chat_path).
  def chat_href = AdminWall::PUBLIC.fetch("chat", []).include?("index") ? chat_index_path : build_path

  test "a signed-out visitor sees a card per app" do
    get websites_path
    assert_response :success

    assert_select "title", "Portfolio · McRitchie Studio"
    assert_select "h1", text: "Portfolio", count: 1
    assert_select "[data-test='websites-carousel'] [data-test='build-example']", count: BuildGallery.examples.size
  end

  test "the apps ride the engine carousel, a slide per app named for it" do
    get websites_path

    carousel = "section[data-test='websites-carousel'][aria-roledescription='carousel'][aria-label='Live apps']"
    assert_select carousel, count: 1
    assert_select "#{carousel}[data-studio-controller='carousel']", count: 1
    # The cascade where the installed engine has it (Alex McRitchie, 2026-11-08), else the spotlight.
    style = ActionController::Base.new.view_context.extend(WebsitesHelper).portfolio_carousel_style
    assert_select "#{carousel}.carousel-#{style}", count: 1
    assert_select "#{carousel} .carousel-slide[role='group']", count: BuildGallery.examples.size
    BuildGallery.examples.each do |example|
      assert_select "#{carousel} .carousel-slide[aria-label=?] [data-test='build-example']", example.name, count: 1
    end
    # The row loops (both arrows always live). It opens on the first app once the engine's
    # visual wrap is installed (a looping spotlight starts at slide 0); an engine before it
    # opens a spotlight on the middle app. Either opening passes.
    middle = BuildGallery.examples.size / 2
    assert_operator middle, :>, 0, "one app has no middle to open on, so this measures nothing"
    assert_select "#{carousel} .carousel-slide[data-current]", count: 1
    opened_name = css_select("#{carousel} .carousel-slide[data-current]").first["aria-label"]
    opened = BuildGallery.examples.index { |example| example.name == opened_name }
    assert_includes [ 0, middle ], opened, "the row opened on #{opened_name}, neither the first nor the middle app"
    assert_select "#{carousel} button[aria-label='Previous slide'][aria-controls='websites-apps'][aria-disabled='false']", count: 1
    assert_select "#{carousel} button[aria-label='Next slide'][aria-controls='websites-apps']", count: 1
    assert_select "#{carousel} button[aria-label='Next slide'][aria-disabled='true']", count: 0
    # The engine still writes its dots; the row hides them (display: none, build_cards.css),
    # and the browser tier proves them gone. It draws no pause button: the row does not autoplay.
    assert_select "#{carousel} .carousel-autoplay", count: 0
    assert_select "[data-test='websites-grid']", count: 0
  end

  # Alex McRitchie, 2026-11-08: the CTA moved from the intro to under the caption, and
  # reads "Build Your Website".
  test "the page has one h1, and Build Your Website comes after the carousel, not in the intro" do
    get websites_path

    assert_select "h1", count: 1
    assert_select "section h1 ~ a[href=?]", build_path, count: 0
    assert_select "a[data-test='websites-build-cta'][href=?]", build_path, text: "Build Your Website", count: 1
    assert_select "a", text: "Build yours", count: 0
    html = response.body
    assert_operator html.index("data-portfolio-captions"), :<, html.index("data-test=\"websites-build-cta\""),
                    "the CTA follows the carousel and its caption in DOM order"
  end

  # Alex McRitchie, 2026-11-08: the still is the whole card, and the open app's name,
  # host and blurb are ONE caption under the stack: a stack of one per app outside the
  # moving slides, the first app's marked current until portfolio_captions.js follows
  # the row. /build keeps its own card.
  test "each slide is the app's still alone, and the apps' captions are one stack under the row" do
    get websites_path

    examples = BuildGallery.examples
    assert_operator examples.size, :>=, 4, "Cyvasse, Turf Monster, Prisoner's Dilemma and Rantly at least"
    row = "[data-test='websites-carousel']"
    card = "#{row} a.portfolio-card[data-test='build-example'][target='_blank'][rel='noopener']"
    assert_select card, count: examples.size
    assert_select "#{row} .build-gallery-card", { count: 0 }, "not /build's card"
    assert_select "#{row} [data-test='build-example-name'], #{row} [data-test='build-example-blurb'], #{row} .carousel-caption",
                  { count: 0 }, "nothing is written over or under a still inside the row"
    examples.each do |example|
      assert_select "#{card}[href=?][aria-label=?]", example.url, example.name, count: 1 do
        if example.image
          assert_select "img.absolute.inset-0.h-full.w-full.object-cover[data-test='build-example-image'][alt=?]", example.name, count: 1
        end
      end
      assert_select "#{card}[href=?][style*=?]", example.url, "--pc-primary:", count: 1
    end

    captions = "[data-portfolio-stage] > [data-portfolio-captions] > [data-test='portfolio-caption']"
    assert_select captions, count: examples.size
    examples.each do |example|
      assert_select "#{captions}[data-portfolio-url=?]", example.url, count: 1 do
        assert_select "h2.type-h2[data-test='build-example-name']", text: example.name, count: 1
        assert_select "[data-test='build-example-host'].font-mono", text: URI.parse(example.url).host, count: 1
        assert_select "[data-test='build-example-blurb']", text: example.blurb, count: 1
      end
    end
    assert_select "#{captions}[data-current]", count: 1
    assert_select "#{captions}[data-current][data-portfolio-url=?]:not([aria-hidden])", examples.first.url, count: 1
    assert_select "#{captions}[aria-hidden='true']", count: examples.size - 1
    assert_select "#{captions}[aria-live]", count: 0 # the carousel's status line speaks, not the caption
    assert_select "#{row} [role='status'][aria-live='polite']", count: 1
  end

  # [component] The row is the helper's style, and it loops on either engine.
  test "the Portfolio row renders in the helper's style and loops" do
    get websites_path

    style = ActionController::Base.new.view_context.extend(WebsitesHelper).portfolio_carousel_style
    other = style == :cascade ? :spotlight : :cascade
    row = "section[data-test='websites-carousel']"
    assert_select "#{row}.carousel-#{style}.portfolio-row[data-carousel-loop]", count: 1 # portfolio-row: the open card's ring
    assert_select "#{row}.carousel-#{other}", count: 0
    if style == :cascade
      assert_select "#{row}[data-carousel-visible='5']", count: 1 # the engine drops to three on a phone
      assert_select "#{row} .carousel-slide[data-cascade-step='0'][aria-label=?]", BuildGallery.examples.first.name, count: 1
    end
  end

  # Alex McRitchie, 2026-11-08: the dots and the pause button go, so the row does not
  # autoplay (moving content owes a visible pause, WCAG 2.2.2). The loop still rides
  # carousel_optional_locals, so an engine without it still renders.
  test "the row loops but never autoplays" do
    get websites_path

    assert_response :success
    row = css_select("[data-test='websites-carousel']").first
    assert_nil row["data-carousel-autoplay"], "no autoplay timer"
    assert_select "[data-test='websites-carousel'] button[aria-label='Pause slideshow']", count: 0
    assert_equal "", row["data-carousel-loop"]
  end

  test "the logged-out sidebar is one line per link, with Sign In, Chat and one Apps link" do
    get websites_path

    panel = "#studio-link-sidebar"
    assert_select "#{panel} a", text: /Sign In/, count: 1
    assert_select "#{panel} a[href='#{chat_href}']", text: /Chat/, count: 1
    # Chat is Alex's portrait on the drawer and a line icon under the glass style.
    if Studio.respond_to?(:sidebar_style)
      assert_select "#{panel} a[href='#{chat_href}'] [data-sidebar-row-icon] svg", count: 1
    else
      assert_select "#{panel} a[href='#{chat_href}'] img[src*='alex']", count: 1
    end
    assert_select "#{panel} a[href='#{websites_path}']", text: /Portfolio/, count: 1
    assert_select "#{panel} a span.text-xs", count: 0
    assert_select "#{panel} a", text: /Turf Monster/, count: 0
  end
end
