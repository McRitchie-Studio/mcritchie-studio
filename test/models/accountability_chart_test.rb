# frozen_string_literal: true

require "test_helper"

# [unit] config/accountability_chart.yml loads into the EOS chart, and its shape
# holds: every seat has exactly one owner, every soul owner is on config/souls.yml,
# every seat carries its roles. Rulings: .agents/epics/accountability-chart.md.
class AccountabilityChartTest < ActiveSupport::TestCase
  SOULS = %w[alex mason mack pokemon avi carl shannon jasper steffon].freeze

  def chart(seats, humans: { "alex-mcritchie" => "Alex McRitchie" })
    AccountabilityChart.new({ "humans" => humans, "seats" => seats }, souls: SOULS)
  end

  def roles = ["One", "Two", "Three", "Four", "Five"]

  def top = { "slug" => "visionary", "name" => "Visionary", "parent" => nil,
              "owner" => "alex-mcritchie", "owner_kind" => "human", "roles" => roles }

  # --- the committed chart ---------------------------------------------------

  test "the committed chart holds its own shape" do
    chart = AccountabilityChart.load
    assert_empty chart.errors, chart.errors.join("\n")
  end

  test "every seat has exactly one owner and every soul owner exists in souls.yml" do
    chart = AccountabilityChart.load
    roster = YAML.safe_load_file(Rails.root.join("config/souls.yml")).fetch("souls").map { |s| s["slug"] }
    chart.seats.each do |seat|
      assert_kind_of String, seat.owner, "#{seat.slug} has one owner, not a list"
      next if seat.human?

      assert_includes roster, seat.owner, "#{seat.slug}'s owner is a soul"
      seat.lights.each { |light| assert_includes roster, light }
    end
  end

  test "a titled soul seat carries the soul's souls.yml title, so the two cannot drift" do
    titles = YAML.safe_load_file(Rails.root.join("config/souls.yml")).fetch("souls").to_h { |s| [s["slug"], s["title"]] }
    titled = AccountabilityChart.load.seats.select { |s| s.title && !s.human? }
    assert_operator titled.size, :>=, 3, "the three heads at least carry titles"
    titled.each do |seat|
      assert_equal titles.fetch(seat.owner), seat.title, "#{seat.slug}: the chart and souls.yml disagree on #{seat.owner}'s title"
    end
  end

  test "every seat carries about five roles" do
    AccountabilityChart.load.seats.each do |seat|
      assert_includes 3..7, seat.roles.size, "#{seat.slug} roles"
      assert seat.roles.all? { |r| r.is_a?(String) && !r.strip.empty? }, "#{seat.slug} has a blank role"
    end
  end

  test "the seats follow the 2026-10-28 rulings" do
    chart = AccountabilityChart.load
    assert_equal "visionary", chart.root.slug
    assert_equal "Alex McRitchie", chart.owner_name(chart.root)
    assert_equal "CEO", chart.root.title

    integrator = chart.seat("integrator")
    assert_equal ["pokemon", "session"], [integrator.owner, integrator.owner_kind],
      "the orchestrating session wears the Integrator seat as the Pokémon soul"
    assert File.file?(Rails.root.join(integrator.page)), "the Integrator's seat page exists"

    heads = chart.children("integrator")
    assert_equal({ "sales-marketing" => "alex", "operations" => "mason", "finance-admin" => "mack" },
                 heads.to_h { |s| [s.slug, s.owner] }, "three major functions, one head each")
    assert_equal "COO", chart.seat("operations").title
    assert_equal "CFO", chart.seat("finance-admin").title

    ops = chart.children("operations").to_h { |s| [s.slug, s.owner] }
    assert_equal "avi", ops["product"]
    assert_equal "carl", ops["architecture-review"]
    assert_equal "pokemon", ops["build"]
    assert_equal "steffon", ops["infrastructure"]
    assert_equal %w[turf-monster tywin tyrion].sort,
                 chart.children("operations").select { |s| s.group == "App operators" }.map(&:owner).sort
    assert_equal %w[jasper shannon], chart.seat("architecture-review").lights.sort
  end

  test "Rex and Hank are off the chart" do
    owners = AccountabilityChart.load.seats.flat_map { |s| [s.owner, *s.lights] }
    refute_includes owners, "rex", "ruling 3: Rex folded into Alex (rex-folds-into-alex); alex owns Sales/Marketing"
    refute_includes owners, "hank", "Hank sits on Commercial Welding's chart"
  end

  # --- the checks bite ---------------------------------------------------------

  test "a seat with two owners is refused" do
    seats = [top, { "slug" => "ops", "name" => "Ops", "parent" => "visionary", "owner" => %w[mason mack], "roles" => roles }]
    assert_match(/ops.*exactly one owner/, chart(seats).errors.join)
  end

  test "a seat with no owner is refused" do
    seats = [top, { "slug" => "ops", "name" => "Ops", "parent" => "visionary", "owner" => nil, "roles" => roles }]
    assert_match(/ops.*exactly one owner/, chart(seats).errors.join)
  end

  test "an owner who is not a soul is refused" do
    seats = [top, { "slug" => "ops", "name" => "Ops", "parent" => "visionary", "owner" => "masonn", "roles" => roles }]
    assert_match(/masonn.*not a soul/, chart(seats).errors.join)
  end

  test "a human owner must be named under humans" do
    assert_match(/not under humans/, chart([top], humans: {}).errors.join)
  end

  test "a light who is not a soul is refused" do
    seats = [top, { "slug" => "review", "name" => "Review", "parent" => "visionary", "owner" => "carl",
                    "lights" => ["shanon"], "roles" => roles }]
    assert_match(/light "shanon"/, chart(seats).errors.join)
  end

  test "a seat without its roles is refused" do
    seats = [top, { "slug" => "ops", "name" => "Ops", "parent" => "visionary", "owner" => "mason", "roles" => ["One"] }]
    assert_match(/ops.*1 roles/, chart(seats).errors.join)
    seats.last["roles"] = []
    assert_match(/ops.*0 roles/, chart(seats).errors.join)
  end

  test "a parent that is not a seat, a second top seat, a loop and a duplicate are refused" do
    errors = chart([top, { "slug" => "ops", "name" => "Ops", "parent" => "nowhere", "owner" => "mason", "roles" => roles }]).errors
    assert_match(/parent "nowhere"/, errors.join)

    errors = chart([top, top.merge("slug" => "second")]).errors
    assert_match(/exactly one top seat/, errors.join)

    looped = [top, { "slug" => "a", "name" => "A", "parent" => "b", "owner" => "mason", "roles" => roles },
                   { "slug" => "b", "name" => "B", "parent" => "a", "owner" => "mack", "roles" => roles }]
    assert_match(/parent loop/, chart(looped).errors.join)

    assert_match(/appears 2 times/, chart([top, top]).errors.join)
  end

  test "one owner may hold several seats" do
    seats = [top, { "slug" => "a", "name" => "A", "parent" => "visionary", "owner" => "pokemon", "roles" => roles },
                  { "slug" => "b", "name" => "B", "parent" => "visionary", "owner" => "pokemon", "roles" => roles }]
    assert_empty chart(seats).errors
    assert_equal %w[a b], chart(seats).seats_owned_by("pokemon").map(&:slug)
  end
end
