# frozen_string_literal: true

require "test_helper"

# [component] The brand kit record through the routes (task brand-kit-record): the Navbar and Stacked tabs' Save as
# kit choice and Clear saved choice, the kit's notes, the brand page's kit status and Kit card, the /logos table's
# saved samples and their downloads, the plain-text 422s, and the admin wall on every write.
class BrandKitsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
  end

  def kit(brand = "studio") = BrandKit.find_by(brand:)
  def form_fields(form) = form.css("input[type=hidden]").to_h { |input| [input["name"], input["value"]] }

  test "the Navbar tab's save form carries the tab's rule and edits, and its text starts on the brand's default" do
    log_in_as(@admin)
    get logo_brand_path("studio", rule: 3, first_colour: "635BB2", guides: 1)
    form = css_select("form[data-test='kit-save-form']").first
    assert_equal brand_kit_choice_path("studio"), form["action"]
    assert_equal "patch", form_fields(form)["_method"]
    assert_equal({ "type" => "navbar", "rule" => "3", "first_colour" => "635BB2", "guides" => "1" }, form_fields(form).except("_method", "authenticity_token"))
    assert_equal "second", form.at_css("select[name=text] option[selected]")["value"]
    assert_select "[data-test='kit-choice-saved']", /No Navbar Logo saved yet: the brand shows its default, rule of 4, second word leads, as styled/
    assert_select "[data-test='kit-clear']", count: 0
    assert_select "[data-test='kit-status']", "Kit: not saved yet"

    get logo_brand_path("studio", type: "stacked", form: "tagline", tagline_visible: 0)
    fields = form_fields(css_select("form[data-test='kit-save-form']").first).except("_method", "authenticity_token")
    assert_equal({ "type" => "stacked", "form" => "tagline", "tagline_visible" => "0" }, fields)
    assert_equal "first", css_select("select[name=text] option[selected]").first["value"]

    get logo_brand_path("studio", type: "icon")
    assert_select "[data-test='kit-choice']", count: 0
    assert_select "[data-test='kit-card']", 1
  end

  test "saving the Navbar choice creates the kit, says what was saved, and returns to the tab as it was" do
    log_in_as(@admin)
    assert_difference -> { BrandKit.count }, 1 do
      patch brand_kit_choice_path("studio"), params: { type: "navbar", rule: "3", text: "first", first_colour: "635BB2", ending_weight: "300", guides: "1" }
    end
    assert_redirected_to logo_brand_path("studio", rule: "3", first_colour: "635BB2", ending_weight: "300", guides: "1")
    assert_equal "Saved the Navbar Logo kit choice: rule of 3, first word leads, first word Deep Violet; ending 300 Light.", flash[:notice]
    assert_equal({ "rule" => 3, "text" => "first", "edits" => { "first_colour" => "635BB2", "ending_weight" => "300" } }, kit.navbar_choice)
    assert_equal @admin.email, kit.updated_by

    follow_redirect!
    assert_select "[data-test='kit-status']", "Kit: saved #{kit.updated_at.strftime('%b %-d, %Y')} by #{@admin.email}"
    assert_select "[data-test='kit-choice-saved']", /Saved Navbar Logo: rule of 3, first word leads, first word Deep Violet; ending 300 Light/
    assert_equal "first", css_select("select[name=text] option[selected]").first["value"], "the select starts on the saved text"
    assert_select "[data-test='kit-clear']", 1
  end

  test "saving the Stacked choice, then a second save, keeps one record per brand" do
    log_in_as(@admin)
    patch brand_kit_choice_path("industries"), params: { type: "stacked", form: "tagline", text: "second", tagline_colour: "c8661f" }
    assert_redirected_to logo_brand_path("industries", type: "stacked", form: "tagline", tagline_colour: "c8661f")
    patch brand_kit_choice_path("industries"), params: { type: "navbar", rule: "6", text: "homogeneous" }
    assert_equal 1, BrandKit.where(brand: "industries").count
    assert_equal({ "form" => "tagline", "text" => "second", "edits" => { "tagline_colour" => "C8661F" } }, kit("industries").stacked_choice)
    assert_equal({ "rule" => 6, "text" => "homogeneous", "edits" => {} }, kit("industries").navbar_choice)
  end

  test "clearing a choice puts the brand back on its default" do
    log_in_as(@admin)
    patch brand_kit_choice_path("studio"), params: { type: "stacked", form: "tagline", text: "first" }
    delete brand_kit_choice_path("studio"), params: { type: "stacked", form: "tagline" }
    assert_redirected_to logo_brand_path("studio", type: "stacked", form: "tagline")
    assert_equal "Cleared the Stacked Logo kit choice. The brand shows its default again.", flash[:notice]
    assert_nil kit.stacked_choice
    assert BrandKit.exists?(brand: "studio"), "the record stays"

    assert_no_difference -> { BrandKit.count } do
      delete brand_kit_choice_path("turf"), params: { type: "navbar" }
    end
    assert_response :redirect
  end

  test "a choice the page could not draw, an unknown type and an unknown brand are refused, and nothing is saved" do
    log_in_as(@admin)
    {
      { type: "navbar", rule: "4", text: "first", first_colour: "FF0000" } => /palette/,
      { type: "navbar", rule: "9", text: "first" } => /unknown rule "9"/,
      { type: "navbar", rule: "4" } => /needs a rule and a text/,
      { type: "stacked", form: "tagline", text: "first" }.merge(brand: "turf") => /unknown form "tagline"/,
      { type: "icon", text: "first" } => /unknown type "icon"/,
      { type: "navbar", rule: "4", text: "first", first_weight: "<b>" } => /unknown first_weight/
    }.each do |given, message|
      patch brand_kit_choice_path(given.delete(:brand) || "studio"), params: given
      assert_response :unprocessable_content
      assert_equal "text/plain", response.media_type
      assert_match message, response.body
    end
    assert_equal 0, BrandKit.count

    patch brand_kit_choice_path("nike"), params: { type: "navbar", rule: "4", text: "first" }
    assert_response :not_found
  end

  test "a save without the form's CSRF token is refused" do
    log_in_as(@admin)
    ActionController::Base.allow_forgery_protection = true
    patch brand_kit_choice_path("studio"), params: { type: "navbar", rule: "4", text: "first" }
    refute_predicate response, :successful?
    refute_equal logo_brand_path("studio", rule: "4"), response.location.to_s.sub("http://www.example.com", "")
    assert_equal 0, BrandKit.count
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  test "the notes save with the kit" do
    log_in_as(@admin)
    patch brand_kit_path("studio"), params: { notes: "  From the 2025 kit.  ", type: "stacked" }
    assert_redirected_to logo_brand_path("studio", type: "stacked", anchor: "kit")
    assert_equal "From the 2025 kit.", kit.notes
    patch brand_kit_path("studio"), params: { notes: "x" * (BrandKit::MAX_NOTES + 1) }
    assert_response :unprocessable_content
    assert_match(/Notes is too long/, response.body)
  end

  test "only admins can change a kit: a visitor is sent to log in, a viewer is turned away, and nothing is written" do
    writes = {
      save: -> { patch brand_kit_choice_path("studio"), params: { type: "navbar", rule: "4", text: "first" } },
      clear: -> { delete brand_kit_choice_path("studio"), params: { type: "navbar" } },
      notes: -> { patch brand_kit_path("studio"), params: { notes: "hi" } }
    }
    writes.each do |name, request|
      request.call
      assert_response :redirect, "#{name} as a visitor"
      refute_equal logo_brand_path("studio"), URI(response.location).path, name
    end
    log_in_as(@viewer)
    writes.each do |name, request|
      request.call
      assert_redirected_to root_path, "#{name} as a viewer"
      assert_equal "Not authorized", flash[:alert]
    end
    assert_equal 0, BrandKit.count

    patch brand_kit_choice_path("studio"), params: { type: "navbar", rule: "4", text: "first" }, as: :json
    assert_response :forbidden
  end

  test "the /logos table draws each brand's saved choices, marks them Saved, and downloads them" do
    BrandKit.for("studio").save_choice(:navbar, ActionController::Parameters.new(rule: "3", text: "first", first_colour: "635BB2"), by: "alex@test.com")
    BrandKit.for("studio").save_choice(:stacked, ActionController::Parameters.new(form: "tagline", text: "second"), by: "alex@test.com")
    log_in_as(@admin)
    get logos_path

    navbar = css_select("[data-brand='studio'] [data-test='logo-sample'][data-type='navbar'] img")
    assert_equal %w[light dark], navbar.map { |img| Rack::Utils.parse_query(URI(img["src"]).query)["tone"] }
    navbar.each do |img|
      assert_equal({ "rule" => "3", "text" => "first", "first_colour" => "635BB2", "guides" => "0" }, Rack::Utils.parse_query(URI(img["src"]).query).except("tone"))
    end
    stacked = css_select("[data-brand='studio'] [data-test='logo-sample'][data-type='stacked'] img").first
    assert_equal({ "form" => "tagline", "text" => "second", "tone" => "light", "guides" => "0" }, Rack::Utils.parse_query(URI(stacked["src"]).query))
    assert_equal %w[STACKED·SAVED NAVBAR·SAVED ICON], css_select("[data-brand='studio'] [data-test='logo-badge']").map { |b| b.text.upcase.delete(" ") }
    assert_equal %w[true true false], css_select("[data-brand='studio'] [data-test='logo-sample']").map { |s| s["data-saved"] }
    assert_select "[data-brand='studio'] [data-test='logo-kit-status']", /\AKit: saved \w{3} \d+, \d{4} by alex@test.com\z/
    assert_select "[data-brand='industries'] [data-test='logo-kit-status']", "Kit: not saved yet"
    assert_equal %w[STACKED NAVBAR ICON], css_select("[data-brand='industries'] [data-test='logo-badge']").map { |b| b.text.upcase }

    downloads = css_select("[data-brand='studio'] [data-test='logo-sample-download']")
    assert_equal %w[navbar navbar stacked stacked], downloads.map { |a| a["data-type"] }
    get downloads.first["href"]
    assert_equal "attachment", response.headers["Content-Disposition"][/\A\w+/]
    assert_match(/studio-navbar-rule3-first-light-custom\.svg/, response.headers["Content-Disposition"])
    assert_includes response.body, 'fill="#635BB2"'
  end

  test "the table reads every kit in one query, whatever the number of brands" do
    log_in_as(@admin)
    get logos_path
    counted = []
    counter = ->(*, payload) { counted << payload[:sql] if payload[:sql].include?("brand_kits") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get logos_path }
    assert_equal 1, counted.size, counted.join("\n")
  end

  test "a saved choice the brand's data can no longer draw shows the refusal in its cell, and the page still answers" do
    record = BrandKit.for("studio")
    record.save!
    record.update_column(:navbar_choice, { "rule" => 4, "text" => "first", "edits" => { "first_colour" => "123456" } })
    log_in_as(@admin)
    get logos_path
    assert_response :success
    assert_select "[data-brand='studio'] [data-type='navbar'] [data-test='logo-sample-refused']", /palette/
    get logo_brand_path("studio")
    assert_response :success
    assert_select "[data-test='kit-choice-saved']", /can no longer be drawn/
    assert_select "[data-test='kit-pick'][data-type='navbar'] [data-test='kit-pick-refused']", /palette/
  end

  test "the brand page's Kit card shows the saved choice in the page's tones, opens it on its tab and downloads it" do
    BrandKit.for("industries").save_choice(:stacked, ActionController::Parameters.new(form: "tagline", text: "second", ending_colour: "C8661F"), by: "alex@test.com")
    log_in_as(@admin)
    get logo_brand_path("industries")
    picks = css_select("[data-test='kit-pick']")
    assert_equal [%w[navbar false], %w[stacked true]], picks.map { |p| [p["data-type"], p["data-saved"]] }
    stacked = picks.last
    assert_equal "Stacked Logo · saved", stacked.at_css("h3").text.squish
    assert_equal "With tagline, second word leads, ending Forge Orange", stacked.at_css("[data-test='kit-pick-summary']").text.strip
    assert_equal logo_brand_path("industries", type: "stacked", form: "tagline", ending_colour: "C8661F"), stacked.at_css("[data-test='kit-pick-open']")["href"]
    assert_equal 2, stacked.css("img[data-test='kit-pick-image']").size

    get logo_brand_path("industries", context: "watermark")
    stacked = css_select("[data-test='kit-pick'][data-type='stacked']").first
    assert_equal ["watermark"], stacked.css("img").map { |img| Rack::Utils.parse_query(URI(img["src"]).query)["tone"] }
    assert_equal logo_brand_path("industries", type: "stacked", form: "tagline", ending_colour: "C8661F", context: "watermark"),
                 stacked.at_css("[data-test='kit-pick-open']")["href"], "the link keeps the saved edits and the context"
  end
end
