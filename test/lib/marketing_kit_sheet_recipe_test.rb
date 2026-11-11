# frozen_string_literal: true

require "test_helper"
require_relative "../support/marketing_kit_fixtures"

# [unit] MarketingKit::SheetRecipe: a sheet as data. It loads beside a kit,
# checks itself on load, and turns into the drawer's payload and the publisher's
# list of stamp (checkbox) columns.
class MarketingKitSheetRecipeTest < ActiveSupport::TestCase
  include MarketingKitFixtures

  COLUMNS = [
    { "key" => "card", "head" => "Card", "kind" => "item", "width" => 28, "section" => 0 },
    { "key" => "limit", "head" => "Limit", "kind" => "money", "width" => 12, "section" => 1, "format" => '"$"#,##0' },
    { "key" => "used", "head" => "Used", "kind" => "stamp", "width" => 8, "section" => 1, "target" => "Last Used" },
    { "key" => "last_used", "head" => "Last Used", "kind" => "date", "width" => 11, "section" => 1, "format" => "m/yy",
      "age_bands" => { "months" => [4, 10, 16], "fresh" => ["💳"] } },
    { "key" => "archived", "head" => "Archived", "kind" => "archive", "width" => 11, "section" => 2 }
  ].freeze

  def with_recipe(edit = nil)
    with_kit do |kit|
      dir = File.dirname(kit)
      data = { "kit" => "kit.yml", "title" => "Test Cards", "sheet_title" => "Cards", "sections" => %w[Card Terms Rewards],
               "columns" => Marshal.load(Marshal.dump(COLUMNS)), "rows" => "rows.json",
               "variables" => [{ "label" => "Total", "value" => "=SUM({col:limit}{first}:{col:limit}{last})", "kind" => "money" }],
               "drive" => { "subject" => "team@mcritchie.studio", "folder" => "McRitchie Studio Records" } }
      edit&.call(data)
      File.write(File.join(dir, "rows.json"), JSON.generate([["One", 100, false, "2026-10-01", ""]]))
      File.write(File.join(dir, "recipe.yml"), data.to_yaml)
      yield File.join(dir, "recipe.yml")
    end
  end

  test "a recipe becomes the drawer's payload over the kit's brand" do
    with_recipe do |path|
      r = MarketingKit::SheetRecipe.load(path)
      p = r.payload
      assert_equal "Test Cards", p[:title]
      assert_equal %w[Card Terms Rewards], p[:sections].map { |s| s[:label] }
      assert p[:sections].all? { |s| s[:top].start_with?("#") && s[:low].start_with?("#") }, "colours come from the kit"
      assert_equal [["One", 100, false, "2026-10-01", ""]], p[:rows], "rows load from the JSON beside the recipe"
      assert_equal "Test Cards", r.name, "the Drive name defaults to the title"
    end
  end

  test "stamps name each tick-box column by its 0-based sheet column" do
    with_recipe do |path|
      # Table columns 0 (B), gutter C, then 1 → D, 2 → E: the stamp is E, index 4.
      assert_equal [{ tab: "Cards", column: 4, target: "Last Used" }], MarketingKit::SheetRecipe.load(path).stamps
    end
    assert_equal [2, 4, 5], [0, 1, 2].map { |i| MarketingKit::SheetRecipe.sheet_column(i) }
  end

  test "a bad recipe fails on load" do
    { ->(d) { d.delete("kit") } => /kit is required/,
      ->(d) { d["drive"].delete("folder") } => /drive.subject and drive.folder/,
      ->(d) { d["columns"][0]["kind"] = "text" } => /first column must be the item/,
      ->(d) { d["columns"][1]["kind"] = "sparkle" } => /unknown kind "sparkle"/,
      ->(d) { d["columns"][2]["target"] = "Nope" } => /targets "Nope"/,
      ->(d) { d["columns"][3]["age_bands"]["months"] = [16, 10, 4] } => /three months, freshest first/,
      ->(d) { d["columns"][1]["key"] = "card" } => /keys must be unique/ }.each do |edit, message|
      with_recipe(edit) do |path|
        err = assert_raises(MarketingKit::Error) { MarketingKit::SheetRecipe.load(path) }
        assert_match message, err.message
      end
    end
  end
end
