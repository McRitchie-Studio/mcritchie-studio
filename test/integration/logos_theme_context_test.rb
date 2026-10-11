# frozen_string_literal: true

require "test_helper"

# [integration] A shared logo-gallery link with an explicit context opens in that theme from the first paint (task
# logo-gallery-polish-pass, item 11): the root carries the theme from the server ("dark" as a class), and the head
# loads app/javascript/theme_context.js, a classic script, after the engine's pre-paint script. A page that names no
# theme is left to the engine, with neither.
class LogosThemeContextTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  def root = Nokogiri::HTML(response.body).at("html")
  def head_scripts = Nokogiri::HTML(response.body).css("head script[src]").map { |script| script["src"] }

  test "dark and watermark links render the dark class on the root, light renders none, and each loads the theme script" do
    { "dark" => ["dark", "dark"], "watermark" => ["dark", "dark"], "light" => [nil, "light"] }.each do |context, (klass, theme)|
      [logos_path(context:), logo_brand_path("industries", context:, type: "stacked")].each do |path|
        get path
        assert_response :success
        assert_equal [klass, theme], [root["class"], root["data-theme-context"]], path
        scripts = head_scripts.grep(%r{/theme_context-\h+\.js\z})
        assert_equal 1, scripts.size, path
        tag = Nokogiri::HTML(response.body).at("head script[src='#{scripts.first}']")
        refute tag.key?("defer") || tag.key?("async") || tag["type"] == "module", "a classic script runs before the first paint"
      end
    end
  end

  test "the theme script comes after the engine's pre-paint script, so it has the last word" do
    get logo_brand_path("studio", context: "light")
    head = Nokogiri::HTML(response.body).at("head")
    scripts = head.css("script")
    engine = scripts.index { |script| script.text.include?("classList.add('dark')") }
    ours = scripts.index { |script| script["src"].to_s.include?("/theme_context-") }
    assert engine && ours && engine < ours, "engine pre-paint at #{engine.inspect}, theme_context at #{ours.inspect}"
  end

  test "a page with no context leaves the root and the head to the engine" do
    [logos_path, logo_brand_path("studio"), root_path].each do |path|
      get path
      assert_nil root["data-theme-context"], path
      assert_nil root["class"], path
      assert_empty head_scripts.grep(/theme_context/), path
    end
  end
end
