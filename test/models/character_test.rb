require "test_helper"

# [unit] A Character is our fictional cast: slugged from its name, a known kind
# and brand kit, and a default look that resolves and releases by the SAME rule
# as a Person's (HoldsDefaultAppearance), not a fork of it.
class CharacterTest < ActiveSupport::TestCase
  setup do
    Appearance.where.not(character_slug: nil).delete_all
    Character.delete_all
  end

  def puppet(**attrs) = Character.create!({ name: "Sock Puppet", kind: "puppet" }.merge(attrs))

  test "slug is made from the name, and kind and brand are checked" do
    assert_equal "sock-puppet", puppet.slug
    assert_not Character.new(name: "X", kind: "human").valid?
    bad = Character.new(name: "Y", kind: "mascot", brand: "not-a-kit")
    assert_not bad.valid?
    assert_includes bad.errors[:brand].join, "not a kit"
    assert Character.new(name: "Z", kind: "mascot", brand: "turf-monster").valid?
  end

  test "the database refuses an unknown kind" do
    c = puppet
    assert_raises(ActiveRecord::CheckViolation) { c.update_columns(kind: "human") }
  end

  test "the first look becomes the default, a later one does not take the slot" do
    c = puppet
    first = c.appearances.create!(descriptor: "Classic")
    second = c.appearances.create!(descriptor: "Holiday")

    assert_equal first.slug, c.reload.default_appearance_slug
    assert first.default?
    assert_not second.default?
  end

  test "destroying the default look releases the pointer to the next live look" do
    c = puppet
    first = c.appearances.create!(descriptor: "Classic")
    second = c.appearances.create!(descriptor: "Holiday")
    first.destroy!

    assert_equal second.slug, c.reload.default_appearance_slug
    second.destroy!
    assert_nil c.reload.default_appearance_slug
  end

  test "make_default! moves the pointer, and a dangling pointer heals on the next look" do
    c = puppet
    c.appearances.create!(descriptor: "Classic")
    holiday = c.appearances.create!(descriptor: "Holiday")
    holiday.make_default!
    assert_equal holiday.slug, c.reload.default_appearance_slug

    c.update_columns(default_appearance_slug: "look-gone")
    fresh = c.appearances.create!(descriptor: "Third")
    assert_not_equal "look-gone", c.reload.default_appearance_slug
    assert_includes [holiday.slug, fresh.slug, c.appearances.order(:created_at).first.slug], c.default_appearance_slug
  end

  test "Person and Character share one resolver" do
    assert_equal HoldsDefaultAppearance.instance_method(:resolve_default_appearance!),
                 Person.instance_method(:resolve_default_appearance!)
    assert_equal HoldsDefaultAppearance.instance_method(:resolve_default_appearance!),
                 Character.instance_method(:resolve_default_appearance!)
  end

  test "featured_for names the live character fronting a kit" do
    assert_nil Character.featured_for("turf-monster")
    c = Character.create!(name: "Turf Monster", kind: "mascot", brand: "turf-monster")
    assert_equal c, Character.featured_for("turf-monster")
    c.update!(retired_at: Time.current)
    assert_nil Character.featured_for("turf-monster")
  end
end
