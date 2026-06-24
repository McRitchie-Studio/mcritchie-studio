require "test_helper"

# Studio::Enumeral ships in the studio-engine gem, but its table lives in this
# app (the installed reference migration), so its behavior is unit-tested here in
# the consumer — the same place Studio::Link / Studio::EmailDelivery behavior is
# exercised.
class Studio::EnumeralTest < ActiveSupport::TestCase
  def make(category:, key:, color: "#EE8130", label: nil, position: 0, rank: nil)
    Studio::Enumeral.create!(category: category, key: key, color: color,
                             label: label, position: position, rank: rank)
  end

  # --- Validations ---

  test "requires category and key" do
    assert_not Studio::Enumeral.new(key: "fire").valid?
    assert_not Studio::Enumeral.new(category: "pokemon_type").valid?
    assert Studio::Enumeral.new(category: "pokemon_type", key: "fire").valid?
  end

  test "key is unique within a category, case-insensitively" do
    make(category: "pokemon_type", key: "fire")
    assert_not Studio::Enumeral.new(category: "pokemon_type", key: "fire").valid?
    assert_not Studio::Enumeral.new(category: "pokemon_type", key: "FIRE").valid?
    # The same key in a different category is fine.
    assert Studio::Enumeral.new(category: "status", key: "fire").valid?
  end

  test "color must be a hex color when present" do
    assert_not Studio::Enumeral.new(category: "c", key: "k", color: "red").valid?
    assert Studio::Enumeral.new(category: "c", key: "k", color: "#FFF").valid?
    assert Studio::Enumeral.new(category: "c", key: "k", color: "#EE8130").valid?
    assert Studio::Enumeral.new(category: "c", key: "k", color: nil).valid?
  end

  # --- Reads ---

  test "catalog returns a category's rows ordered by position, scoped to it" do
    make(category: "pokemon_type", key: "water", position: 2)
    make(category: "pokemon_type", key: "fire",  position: 1)
    make(category: "other",        key: "x",     position: 0)
    assert_equal %w[fire water], Studio::Enumeral.catalog("pokemon_type").map(&:key)
  end

  test "by_rank orders a category by its rank, nulls last" do
    make(category: "pokemon_type", key: "water",  rank: 200)
    make(category: "pokemon_type", key: "poison", rank: 100)
    make(category: "pokemon_type", key: "dark",   rank: nil)
    assert_equal %w[poison water dark],
                 Studio::Enumeral.in_category("pokemon_type").by_rank.map(&:key)
  end

  test "color_map is a key => color hash for just that category" do
    make(category: "pokemon_type", key: "fire",  color: "#EE8130", position: 0)
    make(category: "pokemon_type", key: "water", color: "#6390F0", position: 1)
    make(category: "other",        key: "z",     color: "#000000")
    assert_equal({ "fire" => "#EE8130", "water" => "#6390F0" },
                 Studio::Enumeral.color_map("pokemon_type"))
  end

  test "color_for returns the color, or the fallback when unknown" do
    make(category: "pokemon_type", key: "fire", color: "#EE8130")
    assert_equal "#EE8130", Studio::Enumeral.color_for("pokemon_type", "fire")
    assert_nil Studio::Enumeral.color_for("pokemon_type", "ghost")
    assert_equal "#CCCCCC", Studio::Enumeral.color_for("pokemon_type", "ghost", fallback: "#CCCCCC")
  end

  test "lookup finds the row for a category + key" do
    fire = make(category: "pokemon_type", key: "fire")
    assert_equal fire, Studio::Enumeral.lookup("pokemon_type", "fire")
    assert_nil Studio::Enumeral.lookup("pokemon_type", "ghost")
  end

  test "available? is true once the table is installed" do
    assert Studio::Enumeral.available?
  end
end
