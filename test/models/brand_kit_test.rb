# frozen_string_literal: true

require "test_helper"

# [unit] The brand kit record (task brand-kit-record): one row per brand of config/logo_brands.yml, its saved Navbar
# and Stacked choices read through the gallery's own parser (Logos::Variant.parse and the logo's refusal), stored in
# one spelling, and its originals checked by their bytes and size.
class BrandKitTest < ActiveSupport::TestCase
  include ActionDispatch::TestProcess::FixtureFile

  BY = "alex@test.com"

  def params(**given) = ActionController::Parameters.new(given)
  def upload(name, type = "application/octet-stream") = fixture_file_upload(name, type)

  test "a kit belongs to a brand of config/logo_brands.yml, one record per brand" do
    assert BrandKit.for("studio").valid?
    kit = BrandKit.new(brand: "nike")
    refute kit.valid?
    assert_includes kit.errors[:brand], "is not a brand in config/logo_brands.yml"

    BrandKit.for("studio").save!
    duplicate = BrandKit.new(brand: "studio")
    refute duplicate.valid?
    assert_includes duplicate.errors[:brand], "has already been taken"
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "for finds the saved record, else a new one that is not saved until its first change" do
    kit = BrandKit.for("industries")
    assert kit.new_record?
    kit.save_choice(:navbar, params(rule: "6", text: "first"), by: BY)
    assert_equal kit, BrandKit.for("industries")
    assert_equal 1, BrandKit.where(brand: "industries").count
  end

  test "a saved navbar choice is stored in one spelling: the rule, the text and the edits as the URL names them" do
    kit = BrandKit.for("studio")
    kit.save_choice(:navbar, params(rule: "3", text: "first", first_colour: "635bb2", ending_weight: "300", tagline_visible: "0", tone: "dark"), by: BY)
    kit.reload
    # The tagline edit is dropped: a Navbar Logo has no tagline. The tone is the page's, never saved.
    assert_equal({ "rule" => 3, "text" => "first", "edits" => { "first_colour" => "635BB2", "ending_weight" => "300" } }, kit.navbar_choice)
    assert_equal BY, kit.updated_by
    assert kit.saved?(:navbar)
    refute kit.saved?(:stacked)
  end

  test "a saved stacked choice keeps its form and the tagline's edits only in the tagline form" do
    kit = BrandKit.for("studio")
    kit.save_choice(:stacked, params(form: "tagline", text: "second", tagline_visible: "0", icon_colour: "1A1535"), by: BY)
    assert_equal({ "form" => "tagline", "text" => "second", "edits" => { "icon_colour" => "1A1535", "tagline_visible" => "0" } },
                 kit.reload.stacked_choice)

    kit.save_choice(:stacked, params(form: "two_line", text: "first", tagline_visible: "0"), by: BY)
    assert_equal({ "form" => "two_line", "text" => "first", "edits" => {} }, kit.reload.stacked_choice)
  end

  test "saving refuses what the page could not draw, and stores nothing" do
    kit = BrandKit.for("studio")
    refusals = {
      "a colour off the palette" => [:navbar, { rule: "4", text: "first", first_colour: "FF0000" }],
      "a weight the editor does not offer" => [:navbar, { rule: "4", text: "first", first_weight: "900" }],
      "a rule the page does not have" => [:navbar, { rule: "5", text: "first" }],
      "an unknown text" => [:navbar, { rule: "4", text: "loud" }],
      "no text" => [:navbar, { rule: "4" }],
      "no rule" => [:navbar, { text: "first" }],
      "a form the brand does not draw" => [:stacked, { form: "one_line", text: "first" }],
      "no form" => [:stacked, { text: "first" }],
      "a visibility that is not 0 or 1" => [:stacked, { form: "tagline", text: "first", tagline_visible: "yes" }],
      "a type that is not a logo with a choice" => [:icon, { text: "first" }]
    }
    refusals.each do |what, (type, given)|
      assert_raises(Logos::NavbarLogo::Error, what) { kit.save_choice(type, params(**given), by: BY) }
    end
    assert kit.new_record?, "nothing was saved"
    assert_equal 0, BrandKit.count
  end

  test "saving refuses edits too heavy to draw in the chosen rule, with the logo's own reason" do
    logo = Logos::NavbarLogo.new("welding_v2")
    refused = Logos::NavbarLogo::EDIT_WEIGHTS.product(Logos::NavbarLogo::RULES.keys).find do |weight, rule|
      logo.refusal({ ending: { weight: } }, rule:)
    rescue Logos::NavbarLogo::Error
      false
    end
    assert refused, "welding_v2 has a weight too wide for some rule: the case this test needs"

    weight, rule = refused
    error = assert_raises(Logos::NavbarLogo::Error) do
      BrandKit.for("welding_v2").save_choice(:navbar, params(rule: rule.to_s, text: "first", ending_weight: weight.to_s), by: BY)
    end
    assert_equal logo.refusal({ ending: { weight: } }, rule:), error.message
  end

  test "a stored choice written around the parser is refused by validation" do
    kit = BrandKit.new(brand: "studio")
    {
      { "rule" => 4, "text" => "first", "edits" => { "first_colour" => "000000" } } => /must be one of the brand.s palette/,
      { "rule" => 4, "text" => "first", "extra" => 1 } => /a map of rule, text, edits/,
      { "rule" => 4, "text" => "first", "edits" => { "onclick" => "x" } } => /edit params/,
      { "rule" => 4, "text" => "first", "edits" => { "first_colour" => ["635BB2"] } } => /edit params/,
      "rule of 4" => /a map of/
    }.each do |choice, message|
      kit.navbar_choice = choice
      refute kit.valid?, choice.inspect
      assert_match message, kit.errors[:navbar_choice].join, choice.inspect
    end
  end

  test "a kit draws its saved choice, else the brand's default" do
    kit = BrandKit.for("industries")
    default = kit.variant(:navbar)
    assert_equal [4, :second, {}], [default.rule, default.text, default.edits]
    assert_equal [:two_line, :first], [kit.variant(:stacked).form, kit.variant(:stacked).text]
    assert_equal :second, kit.default_text(:navbar)

    kit.save_choice(:navbar, params(rule: "3", text: "homogeneous", ending_colour: "C8661F"), by: BY)
    saved = kit.variant(:navbar, tone: :dark)
    assert_equal [3, :homogeneous, :dark, { ending: { colour: "#C8661F" } }], [saved.rule, saved.text, saved.tone, saved.edits]
    assert_equal :homogeneous, kit.default_text(:navbar)
    assert_empty kit.variant(:navbar, tone: :watermark).edits, "a watermark is one colour"
  end

  test "a choice is stored in the flat URL spelling and read back from the jsonb's string keys through the URL parser" do
    BrandKit.for("studio").save_choice(:stacked, params(form: "tagline", text: "first", first_colour: "635BB2", tagline_weight: "600"), by: BY)
    stored = BrandKit.connection.select_value("SELECT stacked_choice FROM brand_kits WHERE brand = 'studio'")
    assert_equal({ "form" => "tagline", "text" => "first", "edits" => { "first_colour" => "635BB2", "tagline_weight" => "600" } }, JSON.parse(stored))

    kit = BrandKit.find_by!(brand: "studio")
    assert(kit.stacked_choice["edits"].keys.all?(String), "jsonb hands back string keys")
    variant = kit.variant(:stacked)
    assert_equal({ first: { colour: "#635BB2" }, tagline: { weight: 600 } }, variant.edits, "the URL parser turned them into the checker's symbols")
    assert_equal Logos::StackedLogo.new("studio").checked_edits(Logos::Variant.edits(first_colour: "635BB2", tagline_weight: "600")), variant.edits
  end

  test "a saved edit the brand can no longer draw is dropped on load and named, and the rest of the choice still draws" do
    kit = BrandKit.for("studio")
    kit.save!
    kit.update_column(:navbar_choice, { "rule" => 4, "text" => "first", "edits" => { "first_colour" => "123456", "ending_colour" => "635BB2" } })
    kit.reload
    variant = kit.variant(:navbar, tone: :dark)
    assert_equal({ ending: { colour: "#635BB2" } }, variant.edits)
    assert_equal ["first_colour"], kit.stale_edits(:navbar).keys
    assert_match(/palette/, kit.stale_edits(:navbar)["first_colour"])
    assert_empty kit.stale_edits(:stacked)
    assert kit.valid?, "a stale choice that is not being written does not make the record invalid"

    kit.navbar_choice = kit.navbar_choice.merge("text" => "second")
    refute kit.valid?, "a stale choice being written is refused"
  end

  test "clearing a choice goes back to the default and keeps the record" do
    kit = BrandKit.for("studio")
    kit.save_choice(:stacked, params(form: "tagline", text: "first"), by: BY)
    kit.clear_choice(:stacked, by: "someone@test.com")
    kit.reload
    assert_nil kit.stacked_choice
    assert_equal "someone@test.com", kit.updated_by
    assert_equal :two_line, kit.variant(:stacked).form
    assert_raises(Logos::NavbarLogo::Error) { kit.clear_choice(:icon, by: BY) }
  end

  test "by_brand reads every saved kit in one query" do
    BrandKit.for("studio").save_choice(:navbar, params(rule: "4", text: "first"), by: BY)
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    kits = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { BrandKit.by_brand(Logos::NavbarLogo.brands) }
    assert_equal %w[studio], kits.keys
    assert_equal 1, queries
  end

  test "originals are kept as uploaded, typed by their bytes" do
    kit = BrandKit.for("studio")
    kit.add_originals([upload("brand_kit/original.svg", "text/plain"), upload("magic-banner.png")], by: BY)
    kit.reload
    assert_equal %w[original.svg magic-banner.png], kit.originals.map { |o| o.filename.to_s }
    assert_equal %w[image/svg+xml image/png], kit.originals.map(&:content_type), "the bytes say what a file is, not the browser"
    assert_equal File.binread(file_fixture("brand_kit/original.svg")), kit.originals.first.download
    assert_equal BY, kit.updated_by
  end

  test "an original that is not an SVG, PNG, JPEG, PDF or ZIP, or too big, refuses the whole upload" do
    kit = BrandKit.for("studio")
    error = assert_raises(Logos::NavbarLogo::Error) do
      kit.add_originals([upload("magic-banner.png"), upload("brand_kit/not-a-picture.png", "image/png")], by: BY)
    end
    assert_match(/not-a-picture\.png is not an SVG, PNG, JPEG, PDF or ZIP/, error.message)
    assert_raises(Logos::NavbarLogo::Error) { kit.add_originals([upload("notes.txt")], by: BY) }
    assert_raises(Logos::NavbarLogo::Error) { kit.add_originals([], by: BY) }

    big = upload("magic-banner.png")
    big.define_singleton_method(:size) { BrandKit::MAX_ORIGINAL_BYTES + 1 }
    assert_match(/over 25 MB/, assert_raises(Logos::NavbarLogo::Error) { kit.add_originals([big], by: BY) }.message)
    assert_equal 0, ActiveStorage::Attachment.where(record_type: "BrandKit").count
  end

  test "validation is the backstop for an original attached around add_originals" do
    kit = BrandKit.for("studio")
    kit.originals.attach(io: StringIO.new("plain"), filename: "notes.txt", content_type: "text/plain", identify: false)
    refute kit.valid?
    assert_includes kit.errors[:originals], "notes.txt is not an SVG, PNG, JPEG, PDF or ZIP"
  end

  test "removing an original purges it and stamps who did" do
    kit = BrandKit.for("studio")
    kit.add_originals([upload("magic-banner.png")], by: BY)
    kit.remove_original(kit.originals.first.id, by: "other@test.com")
    kit.reload
    assert_empty kit.originals
    assert_equal "other@test.com", kit.updated_by
    assert_raises(ActiveRecord::RecordNotFound) { kit.remove_original(0, by: BY) }
  end
end
