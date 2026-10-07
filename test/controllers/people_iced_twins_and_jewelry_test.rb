# frozen_string_literal: true

require "test_helper"

# [integration] + [component] The iced-out twin and a person's jewelry, through
# the person page: creating a look makes its twin (a free row, no build), an
# older look gets one on request, and an admin adds, edits and removes jewelry.
# Synthetic person and pieces only.
class PeopleIcedTwinsAndJewelryTest < ActionDispatch::IntegrationTest
  setup do
    @person = Person.create!(first_name: "Novice", last_name: "Icebox")
  end

  def jewelry_params(**over)
    { person_jewelry: { kind: "super_bowl_ring", name: "Big Game XC ring", year: 2031,
                        description: "white gold, a pavé comet", source: "synthetic" }.merge(over) }
  end

  test "creating a look makes its iced twin, linked, with no sheet build started" do
    log_in_as users(:alex)

    assert_difference -> { @person.appearances.count } => 2 do
      assert_no_enqueued_jobs only: SheetBuildJob do
        post create_appearance_person_path(@person.slug), params: { appearance: { descriptor: "Comets white" } }
      end
    end

    base = @person.appearances.find_by!(descriptor: "Comets white")
    twin = @person.appearances.find_by!(descriptor: "Comets white · iced")
    assert twin.iced?
    assert_equal base.slug, twin.base_appearance_slug
    assert_equal base.slug, @person.reload.default_appearance_slug, "the base, not the twin, is the default"
    assert_match "No sheet was built", flash[:notice]
  end

  test "an existing look gets a twin on request, once; a twin gets none" do
    base = Appearance.create!(person_slug: @person.slug, descriptor: "Old kit")
    log_in_as users(:alex)

    assert_difference -> { Appearance.count } => 1 do
      post create_iced_twin_person_path(@person.slug), params: { appearance_slug: base.slug }
    end
    twin = base.reload.iced_twin
    assert_redirected_to person_path(@person.slug, anchor: "look-#{twin.slug}")

    assert_no_difference -> { Appearance.count } do
      post create_iced_twin_person_path(@person.slug), params: { appearance_slug: base.slug }
      post create_iced_twin_person_path(@person.slug), params: { appearance_slug: twin.slug }
    end
    assert_match "cannot have a twin of its own", flash[:alert]
  end

  test "a non-admin makes no twin and no jewelry" do
    base = Appearance.create!(person_slug: @person.slug, descriptor: "Old kit")
    jewel = PersonJewelry.create!(person_slug: @person.slug, kind: "chain", name: "Rope", description: "gold rope")
    log_in_as users(:viewer)

    assert_no_difference ["Appearance.count", "PersonJewelry.count"] do
      post create_iced_twin_person_path(@person.slug), params: { appearance_slug: base.slug }
      assert_redirected_to root_path
      post person_jewelries_path(@person.slug), params: jewelry_params
      assert_redirected_to root_path
      delete person_jewelry_path(@person.slug, jewel.slug)
      assert_redirected_to root_path
    end
    patch person_jewelry_path(@person.slug, jewel.slug), params: jewelry_params(kind: "chain", name: "Changed")
    assert_equal "Rope", jewel.reload.name
  end

  test "an admin adds, edits and removes jewelry; a ring with no year is refused without an error log" do
    log_in_as users(:alex)

    assert_difference -> { @person.jewelries.count } => 1 do
      post person_jewelries_path(@person.slug), params: jewelry_params
    end
    assert_redirected_to person_path(@person.slug, anchor: "jewelry")
    ring = @person.jewelries.first
    assert_equal ["super_bowl_ring", 2031, "white gold, a pavé comet"], [ring.kind, ring.year, ring.description]

    assert_no_difference ["PersonJewelry.count", "ErrorLog.count"] do
      post person_jewelries_path(@person.slug), params: jewelry_params(year: "")
    end
    assert_match "Year can't be blank", flash[:alert]

    patch person_jewelry_path(@person.slug, ring.slug), params: jewelry_params(description: "rose gold now")
    assert_equal "rose gold now", ring.reload.description

    assert_difference -> { PersonJewelry.count } => -1 do
      delete person_jewelry_path(@person.slug, ring.slug)
    end
  end

  test "the person page lists jewelry and shows each look beside its iced twin" do
    base = Appearance.create!(person_slug: @person.slug, descriptor: "Comets white")
    other = Appearance.create!(person_slug: @person.slug, descriptor: "Comets navy")
    twin = Appearances::IcedTwin.create!(base)
    PersonJewelry.create!(person_slug: @person.slug, kind: "super_bowl_ring", name: "Big Game XC ring", year: 2031,
                          description: "white gold, a pavé comet")
    log_in_as users(:alex)

    get person_path(@person.slug)
    assert_response :success

    assert_select "[data-test='jewelry-row'][data-kind='super_bowl_ring']", text: /2031 Big Game XC ring.*white gold, a pavé comet/m
    assert_select "[data-test='jewelry-form']", 1
    assert_select "[data-test='jewelry-edit-form']", 1
    assert_select "[data-test='person-look']" do |rows|
      assert_equal [base.slug, twin.slug, other.slug], rows.map { |r| r["id"].delete_prefix("look-") },
                   "the twin sits straight after its base"
    end
    assert_select "#look-#{twin.slug} [data-test='iced-badge']", text: "iced twin"
    assert_select "#look-#{base.slug} [data-test='create-iced-twin']", 0, "a look with a twin is not offered another"
    assert_select "#look-#{other.slug} form[action='#{create_iced_twin_person_path(@person.slug)}']", 1
  end

  test "a person with no jewelry says so" do
    log_in_as users(:alex)
    get person_path(@person.slug)
    assert_select "[data-test='jewelry-empty']", text: /No jewelry on file for Novice Icebox/
  end
end
