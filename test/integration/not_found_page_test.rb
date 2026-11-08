require "test_helper"

# [integration] The friendly not-found page (task friendly-not-found-page): a lost
# visitor gets a 404 with the hub's name and a button home, never a 200 or redirect.
# config.exceptions_app is guarded until the release relocks an engine that has it,
# so these read whichever engine is locked: the engine page in the hub layout, or the
# restyled public/404.html (same words, same data-test hooks). The test env hides
# exceptions, so each request runs with production's exception settings.
class NotFoundPageTest < ActionDispatch::IntegrationTest
  ENGINE_PAGE = defined?(Studio::ExceptionsApp)

  def with_production_exceptions
    config = Rails.application.env_config
    saved = config.slice("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
    config["action_dispatch.show_exceptions"] = :all
    config["action_dispatch.show_detailed_exceptions"] = false
    yield
  ensure
    config.merge!(saved)
  end

  def get_lost(path, **options)
    with_production_exceptions { get path, **options }
  end

  # The page a lost visitor sees, on either engine: status 404, the friendly
  # words, the hub's name and one button back to the hub's root.
  def assert_friendly_page
    assert_response :not_found
    assert_nil response.location, "never a redirect"
    assert_match %r{\Atext/html}, response.media_type
    assert_select "[data-test='not-found']", count: 1 do
      assert_select "h1", text: "This page isn’t here"
      assert_select "a[data-test='not-found-home'][href='/']", text: "Back to McRitchie Studio", count: 1
    end
    assert_select "title", "Page not found · McRitchie Studio"
    if ENGINE_PAGE
      assert_select "main [data-test='not-found']", count: 1
      assert_select "nav", minimum: 1, message: "the hub's navbar"
      assert_select "img[data-studio-not-found-logo][src='/brand/icon-light.svg'][alt='McRitchie Studio']"
      assert_select "[data-static-404]", count: 0
    else
      assert_select "body[data-static-404]", count: 1
    end
  end

  test "an unknown address answers 404 with the friendly page and a home link to the root" do
    get_lost "/no-such-page"

    assert_friendly_page
  end

  test "a signed-out visitor gets the page, not a sign-in redirect" do
    get_lost "/no/such/page/either"

    assert_friendly_page
    assert_not response.redirect?
  end

  test "a missing record answers 404 with the page: Alex McRitchie's /applications/<unknown>/chat" do
    log_in_as users(:alex)
    get_lost "/applications/no-such-app/chat"

    assert_friendly_page
    assert_select "[data-test='not-found-back']", count: 0, message: "no referrer, no second link"
  end

  test "a missing application page answers 404 with the page" do
    log_in_as users(:alex)
    get_lost "/applications/no-such-app"

    assert_friendly_page
  end

  test "a JSON request answers 404 JSON, not the HTML page" do
    get_lost "/no-such-page", headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_equal "application/json", response.media_type
    assert_equal({ "status" => 404, "error" => "Not Found" }, response.parsed_body)
    assert_not_includes response.body, "<html"
  end

  test "a missing record asked for as JSON answers 404 JSON" do
    log_in_as users(:alex)
    get_lost "/applications/no-such-app.json"

    assert_response :not_found
    assert_equal "application/json", response.media_type
    assert_not_includes response.body, "<html"
  end

  test "a real walled page still answers with the wall for a visitor" do
    get_lost "/applications/no-such-app/chat"

    assert_response :redirect
    assert_select "[data-test='not-found']", count: 0
  end

  test "a page on the hub the visitor came from adds Go back" do
    get_lost "/no-such-page", headers: { "Referer" => "http://www.example.com/websites" }

    assert_friendly_page
    if ENGINE_PAGE
      assert_select "a[data-test='not-found-back'][href='/websites']", text: "Go back", count: 1
    else
      # The static page cannot read the Referer; it offers home only.
      assert_select "[data-test='not-found-back']", count: 0
    end
  end

  test "the static last resort, public/404.html, carries the brand, the words and the home link" do
    page = Nokogiri::HTML(Rails.public_path.join("404.html").read)

    assert_equal "Page not found · McRitchie Studio", page.at_css("title").text
    assert page.at_css("body[data-static-404] [data-test='not-found']")
    assert_equal "This page isn’t here", page.at_css("h1").text
    home = page.at_css("a[data-test='not-found-home']")
    assert_equal "/", home["href"]
    assert_equal "Back to McRitchie Studio", home.text
    assert page.at_css("img[src='/brand/icon-light.svg']"), "the kit icon for a light page"
    assert page.at_css("source[srcset='/brand/icon-dark.svg'][media='(prefers-color-scheme: dark)']"), "and for a dark one"
    assert_includes page.at_css("style").text, "prefers-color-scheme: dark"
    assert_empty page.css("script"), "the last resort runs nothing"
    assert_empty page.css("link[rel='stylesheet']"), "and loads nothing that could be missing"
  end
end
