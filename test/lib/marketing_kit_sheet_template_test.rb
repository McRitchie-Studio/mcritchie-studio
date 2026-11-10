# frozen_string_literal: true

require "test_helper"
require_relative "../support/marketing_kit_fixtures"

# [unit] MarketingKit::SheetTemplate: the head colours it derives from a brand's
# palette, the sections it picks, and the payload office.py draws.
class MarketingKitSheetTemplateTest < ActiveSupport::TestCase
  include MarketingKitFixtures

  T = MarketingKit::SheetTemplate

  test "both head rows carry white text at AA and the top row is always darker" do
    # Near-black, mid, and too-light-for-white brand colours.
    %w[#262A30 #1B2124 #59606A #2F6B4F #C8661F #C8702E #E8955A #E9E5DD #FFFFFF #000000].each do |hex|
      low = T.legible(hex)
      top = T.mix(low, "#000000", T::TOP_DARKEN)
      assert_operator T.contrast_with_white(low), :>=, T::MIN_CONTRAST, "lower head on #{hex}"
      assert_operator T.contrast_with_white(top), :>, T.contrast_with_white(low), "top head darker than lower on #{hex}"
    end
  end

  test "a colour that already carries white text keeps its hue in the lower head" do
    assert_equal "#59606A", T.legible("#59606A")
    assert_equal "#2F6B4F", T.legible("#2f6b4f")
  end

  test "a light colour darkens only as far as white text needs" do
    low = T.legible("#C8661F")
    assert_operator T.contrast_with_white(low), :>=, T::LOW_TARGET
    assert_operator T.contrast_with_white(low), :<, 5.2, "darkened just past the target, not to mud"
  end

  test "a near-black colour lightens its lower head so the step shows" do
    assert_operator T.contrast_with_white(T.legible("#262A30")), :<=, T::LOW_CEILING + 0.5
    assert_not_equal "#262A30", T.legible("#262A30")
  end

  test "contrast matches the WCAG reference points" do
    assert_in_delta 21.0, T.contrast_with_white("#000000"), 0.01
    assert_in_delta 1.0, T.contrast_with_white("#FFFFFF"), 0.01
    assert_in_delta 4.54, T.contrast_with_white("#767676"), 0.02
  end

  test "default sections are primary, accent, then the first other swatch white text reads on" do
    load_kit do |spec|
      names = T.new(spec).sections.map(&:name)
      # The example: Ridge Green (primary), Copper (accent); Charcoal (dark) is next
      # and reads; Bright Copper and Deep Green are shades, Stone is too light.
      assert_equal ["Ridge Green", "Copper", "Charcoal"], names
    end
  end

  test "the third section skips shade swatches and light swatches" do
    edit = lambda do |d|
      d["palette"] = [{ "key" => "accent", "name" => "Orange", "hex" => "#C8661F" },
                      { "key" => "primary", "name" => "Charcoal", "hex" => "#262A30" },
                      { "key" => "accent_on_dark", "name" => "Ember", "hex" => "#B0501A" },
                      { "name" => "Pale", "hex" => "#D3D6DA" },
                      { "name" => "Gunmetal", "hex" => "#59606A" },
                      { "key" => "dark", "name" => "Black", "hex" => "#141516" }]
    end
    load_kit(edit: edit) { |spec| assert_equal %w[Charcoal Orange Gunmetal], T.new(spec).sections.map(&:name) }
  end

  test "sheet.sections picks the three colours by swatch name or palette key" do
    load_kit(edit: ->(d) { d["sheet"] = { "sections" => ["dark", "Deep Green", "accent"] } }) do |spec|
      assert_equal ["Charcoal", "Deep Green", "Copper"], T.new(spec).sections.map(&:name)
    end
  end

  test "a bad sheet.sections fails when the spec loads" do
    err = assert_raises(MarketingKit::Error) { load_kit(edit: ->(d) { d["sheet"] = { "sections" => %w[primary accent] } }) { flunk } }
    assert_match(/exactly three/, err.message)
    err = assert_raises(MarketingKit::Error) { load_kit(edit: ->(d) { d["sheet"] = { "sections" => %w[primary accent Mauve] } }) { flunk } }
    assert_match(/no swatch or key named "Mauve"/, err.message)
  end

  test "the payload names the template, sets the title in the title colour and uses the light horizontal logo" do
    load_kit do |spec|
      t = T.new(spec)
      p = t.payload
      assert_equal "RF Template — Sheet", t.name
      assert_equal spec.colour(:title), p.dig(:colours, :title)
      assert_equal spec.logo_png(:horizontal, :light), p[:logo]
      assert_not_includes p[:variables].map { |v| v[:label] }, "Prepared by"
      assert_equal 3, p[:sections].size
      assert_equal [0, 1, 2], p[:columns].map { |c| c[:section] }.uniq, "every section has columns, in order"
      assert_equal "item", p[:columns].first[:kind], "column A is the row's item, which the freeze keeps"
      assert(p[:rows].all? { |r| r.size == p[:columns].size })
      formula = p[:columns].find { |c| c[:kind] == "formula" }[:formula]
      labels = p[:variables].map { |v| v[:label] }
      formula.scan(/\{var:([^}]+)\}/).flatten.each { |l| assert_includes labels, l }
    end
  end
end
