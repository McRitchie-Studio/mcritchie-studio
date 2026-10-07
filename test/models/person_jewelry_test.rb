# frozen_string_literal: true

require "test_helper"

# [unit] A person's jewelry, the source the iced-out sheet reads. Synthetic
# person and pieces only: nothing here describes a real person's rings.
class PersonJewelryTest < ActiveSupport::TestCase
  setup do
    @person = Person.create!(first_name: "Novice", last_name: "Jewelcase")
  end

  def jewel(**attrs)
    PersonJewelry.new({ person_slug: @person.slug, kind: "chain", name: "Rope chain",
                        description: "A thick gold rope chain" }.merge(attrs))
  end

  test "the kind must be one of the fixed list" do
    assert jewel.valid?
    PersonJewelry::KINDS.each { |kind| assert jewel(kind:, year: 2030).valid?, kind }

    bad = jewel(kind: "tiara")
    assert_not bad.valid?
    assert bad.errors[:kind].any?
  end

  test "a Super Bowl or championship ring needs a year; other kinds do not" do
    %w[super_bowl_ring championship_ring].each do |kind|
      ring = jewel(kind:, name: "Big Game ring")
      assert_not ring.valid?, "#{kind} without a year"
      assert ring.errors[:year].any?
      ring.year = 2031
      assert ring.valid?
    end
    assert jewel(kind: "watch", year: nil).valid?
  end

  test "name and description are required, the description is the prompt's text" do
    assert_not jewel(name: " ").valid?
    assert_not jewel(description: "").valid?

    ring = jewel(kind: "super_bowl_ring", name: "Big Game XC ring", year: 2031, description: "white gold, a pavé star")
    assert_equal "2031 Big Game XC ring: white gold, a pavé star", ring.prompt_phrase
  end

  test "an image URL must be https on a public host, or blank" do
    assert jewel(image_url: "").valid?
    assert jewel(image_url: "https://example.com/ring.png").valid?
    assert_not jewel(image_url: "http://example.com/ring.png").valid?
    assert_not jewel(image_url: "https://127.0.0.1/ring.png").valid?
  end

  test "a person lists their jewelry in kind order, and a slug is minted" do
    watch = jewel(kind: "watch", name: "Field watch").tap(&:save!)
    ring = jewel(kind: "super_bowl_ring", name: "Big Game ring", year: 2031).tap(&:save!)

    assert_match(/\Ajewel-\h{12}\z/, ring.slug)
    assert_equal [ring, watch], @person.reload.jewelries.to_a
    assert_equal [ring], @person.jewelries.rings.to_a
  end
end
