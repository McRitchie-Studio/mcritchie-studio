require "test_helper"

# [unit] The derived halves of `users.name`.
#
# `first_name` and `last_name` are DERIVED from `name` by a before_save callback,
# so every writer that deliberately steps around callbacks — the seed's
# `update_column`, a migration's raw SQL — leaves them behind. Those writers step
# around callbacks for a reason worth keeping (Sluggable rebuilds the slug from
# the name, so a full save re-points the URL the row answers on), which is why the
# fix is a PRIMITIVE they can call rather than a save they cannot afford.
#
# The load-bearing test here is the parity one: `User.name_parts` must write
# exactly what `set_name_parts` writes, for every shape of name. A primitive that
# disagreed with the callback would not fix the defect, it would move it.
class UserNamePartsTest < ActiveSupport::TestCase
  # Every shape the column actually holds, plus the two the callback treats
  # specially: a one-word name (no last name to take) and a blank one.
  NAMES = [
    "Team McRitchie",
    "McRitchie Studio Team",
    "Turf Monster",
    "Cher",
    "  Ada   Lovelace  ",
    ""
  ].freeze

  def user(**attrs)
    User.create!({
      email: "parts-#{SecureRandom.hex(4)}@example.com",
      role: "viewer",
      password: "password"
    }.merge(attrs))
  end

  # --- the criterion, through the path that already worked ------------------

  test "renaming a user through a save updates both derived halves" do
    row = user(name: "McRitchie Studio Team")
    assert_equal %w[McRitchie Team], [row.first_name, row.last_name]

    row.update!(name: "Team McRitchie")
    row.reload

    assert_equal %w[Team McRitchie], [row.first_name, row.last_name]
  end

  # --- the primitive the callback-skipping writers call ---------------------

  # THE PARITY TEST. Two rows, one renamed through the callback and one through
  # `update_columns(name:, **User.name_parts(...))` — the callback-free write the
  # seed and the migrations make. They must land on identical columns, or the
  # second acceptance criterion ("migrated and freshly seeded rows agree") cannot
  # hold for any name at all.
  test "name_parts writes exactly what the before_save callback writes" do
    NAMES.each do |name|
      via_callback  = user(name: "Placeholder Name")
      via_primitive = user(name: "Placeholder Name")

      via_callback.update!(name: name)
      via_primitive.update_columns({ name: name }.merge(User.name_parts(name)))

      assert_equal via_callback.reload.slice("name", "first_name", "last_name"),
                   via_primitive.reload.slice("name", "first_name", "last_name"),
                   "name_parts disagrees with set_name_parts for #{name.inspect}"
    end
  end

  test "name_parts splits a two-word name into both halves" do
    assert_equal({ first_name: "Team", last_name: "McRitchie" }, User.name_parts("Team McRitchie"))
  end

  # A THREE-WORD NAME TAKES THE ENDS, which is the case this whole task turns on:
  # "McRitchie Studio Team" derives McRitchie/Team, and "Team McRitchie" derives
  # Team/McRitchie — the two are a swap, so a writer that skips the derivation
  # leaves a row whose halves are its own name backwards.
  test "name_parts takes the first and last words of a longer name" do
    assert_equal({ first_name: "McRitchie", last_name: "Team" }, User.name_parts("McRitchie Studio Team"))
  end

  # ONE WORD OMITS `last_name` RATHER THAN NULLING IT — deliberately, and only
  # because that is what the callback has always done (`if parts.size > 1`).
  # Returning nil here would read as tidier and would make every callback-free
  # writer clear a last name the callback leaves standing, which is a
  # disagreement in the opposite direction. Widening that is a separate change.
  test "name_parts omits last_name for a one-word name" do
    assert_equal({ first_name: "Cher" }, User.name_parts("Cher"))
    refute User.name_parts("Cher").key?(:last_name)
  end

  test "name_parts collapses surrounding and repeated whitespace" do
    assert_equal({ first_name: "Ada", last_name: "Lovelace" }, User.name_parts("  Ada   Lovelace  "))
  end

  test "name_parts has nothing to derive from a blank name" do
    assert_equal({ first_name: nil }, User.name_parts(nil))
    assert_equal({ first_name: nil }, User.name_parts("   "))
  end
end
