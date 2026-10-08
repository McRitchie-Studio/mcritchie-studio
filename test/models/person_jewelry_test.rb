# frozen_string_literal: true

require "test_helper"
require_relative "../support/url_guard_world"

# [unit] A person's jewelry, the source the iced-out sheet reads. Synthetic
# person and pieces only: nothing here describes a real person's rings.
class PersonJewelryTest < ActiveSupport::TestCase
  include UrlGuardWorld

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

  # THE GUARD IS ASKED ABOUT THE IMAGE URL ONLY WHEN THE URL CHANGES. On the
  # next engine each ask is a DNS lookup that can take seconds and can fail, and
  # a rename must not be refused because a CDN's name did not look up.
  test "saving a jewel whose image URL did not change asks the guard nothing" do
    piece = jewel(image_url: "https://cdn.example.com/ring.png").tap(&:save!)
    ActiveSupport::CurrentAttributes.reset_all

    with_url_guard(unresolved: %w[cdn.example.com]) do |lookups|
      piece = PersonJewelry.find(piece.id)
      piece.update!(name: "Renamed chain", description: "A thinner gold chain")
      assert piece.valid?
      assert_equal [], lookups, "no lookup for a URL nobody touched"
      assert_equal "Renamed chain", piece.reload.name
    end
  end

  test "a changed or new image URL is looked up once, however often the record is validated" do
    with_url_guard do |lookups|
      piece = jewel(image_url: "https://cdn.example.com/ring.png")
      assert piece.valid?
      piece.save!
      assert_equal %w[cdn.example.com], lookups, "valid? then save! is one lookup"

      ActiveSupport::CurrentAttributes.reset_all
      piece.image_url = "https://other.example.com/ring.png"
      assert piece.valid?
      assert_equal %w[cdn.example.com other.example.com], lookups
    end
  end

  test "an image URL whose host could not be looked up reads as could not check, not as invalid" do
    with_url_guard(unresolved: %w[dead.example.com]) do
      unchecked = jewel(image_url: "https://dead.example.com/ring.png")
      assert_not unchecked.valid?
      assert_match(/could not be checked right now/, unchecked.errors[:image_url].sole)
      assert_no_match(/must be an https/, unchecked.errors.full_messages.to_sentence)

      refused = jewel(image_url: "http://dead.example.com/ring.png")
      assert_not refused.valid?
      assert_equal ["must be an https:// URL on a public host"], refused.errors[:image_url]
    end
  end
end
