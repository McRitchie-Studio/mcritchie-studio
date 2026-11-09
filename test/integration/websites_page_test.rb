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
    # opens a spotlight on the middle app. Either opening passes; the dots must agree with it.
    middle = BuildGallery.examples.size / 2
    assert_operator middle, :>, 0, "one app has no middle to open on, so this measures nothing"
    assert_select "#{carousel} .carousel-slide[data-current]", count: 1
    opened_name = css_select("#{carousel} .carousel-slide[data-current]").first["aria-label"]
    opened = BuildGallery.examples.index { |example| example.name == opened_name }
    assert_includes [ 0, middle ], opened, "the row opened on #{opened_name}, neither the first nor the middle app"
    assert_select "#{carousel} button[aria-label='Previous slide'][aria-controls='websites-apps'][aria-disabled='false']", count: 1
    assert_select "#{carousel} button[aria-label='Next slide'][aria-controls='websites-apps']", count: 1
    assert_select "#{carousel} button[aria-label='Next slide'][aria-disabled='true']", count: 0
    assert_select "#{carousel} button.carousel-dot", count: BuildGallery.examples.size
    assert_select "#{carousel} button.carousel-dot[aria-current='true']", count: 1
    assert_select "#{carousel} button.carousel-dot[aria-current='true'][aria-label=?]", "Go to slide #{opened + 1}", count: 1
    assert_select "[data-test='websites-grid']", count: 0
  end

  # Alex McRitchie, 2026-11-08: the still is the whole card, and the name, host and
  # blurb are the row's caption, which the carousel shows under the open slide only.
  # /build keeps its own card.
  test "each slide is the app's still alone, and its name, host and blurb are the slide's caption" do
    get websites_path

    examples = BuildGallery.examples
    assert_operator examples.size, :>=, 4, "Cyvasse, Turf Monster, Prisoner's Dilemma and Rantly at least"
    row = "[data-test='websites-carousel']"
    card = "#{row} a.portfolio-card[data-test='build-example'][target='_blank'][rel='noopener']"
    assert_select card, count: examples.size
    assert_select "#{row} .build-gallery-card", { count: 0 }, "not /build's card"
    assert_select "#{card} [data-test='build-example-name'], #{card} [data-test='build-example-blurb'], #{card} [data-test='portfolio-card-body']",
                  { count: 0 }, "nothing is written over the still"
    examples.each do |example|
      assert_select "#{card}[href=?][aria-label=?]", example.url, example.name, count: 1 do
        if example.image
          assert_select "img.absolute.inset-0.h-full.w-full.object-cover[data-test='build-example-image'][alt=?]", example.name, count: 1
        end
      end
      assert_select "#{card}[href=?][style*=?]", example.url, "--pc-primary:", count: 1
      assert_select "#{row} .carousel-slide[aria-label=?] .carousel-caption [data-test='portfolio-caption']", example.name, count: 1 do
        assert_select "[data-test='build-example-name']", text: example.name, count: 1
        assert_select "[data-test='build-example-host'].font-mono", text: URI.parse(example.url).host, count: 1
        assert_select "[data-test='build-example-blurb']", text: example.blurb, count: 1
      end
    end
    assert_select "#{row} [data-test='portfolio-caption'][aria-live]", count: 0 # the status line speaks, not the caption
    [ "Prisoner's Dilemma", "Rantly" ].each { |name| assert_select "#{row} [data-test='build-example-name']", text: name, count: 1 }
  end

  # [component] The row is the helper's style, and it loops on either engine.
  test "the Portfolio row renders in the helper's style and loops" do
    get websites_path

    style = ActionController::Base.new.view_context.extend(WebsitesHelper).portfolio_carousel_style
    other = style == :cascade ? :spotlight : :cascade
    row = "section[data-test='websites-carousel']"
    assert_select "#{row}.carousel-#{style}[data-carousel-loop]", count: 1
    assert_select "#{row}.carousel-#{other}", count: 0
    if style == :cascade
      assert_select "#{row}[data-carousel-visible='5']", count: 1 # the engine drops to three on a phone
      assert_select "#{row} .carousel-slide[data-cascade-step='0'][aria-label=?]", BuildGallery.examples.first.name, count: 1
    end
  end

  test "the carousel asks for autoplay and loop only as the installed engine declares them" do
    get websites_path

    template = ActionController::Base.new.lookup_context.find_template("studio/carousel", [], true)
    declares = template.source[WebsitesHelper::STRICT_LOCALS, 1].to_s
    # Until the engine has them (task carousel-autoplay-and-loop) the page still renders: an
    # undeclared local would raise. Once it has them, the row carries what the engine makes of them.
    assert_response :success
    if declares.match?(/\bautoplay:/)
      assert_match(/autoplay/i, css_select("[data-test='websites-carousel']").first.to_html, "the engine's autoplay reaches the row")
    else
      assert_no_match(/autoplay/i, css_select("[data-test='websites-carousel']").first.attributes.values.map(&:value).join(" "))
    end
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
