# frozen_string_literal: true

require "test_helper"

# [unit] The iced-out twin of a look: its own Appearance, linked to its base,
# made free (no sheet build), one per base.
class Appearances::IcedTwinTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @person = Person.create!(first_name: "Novice", last_name: "Twinset")
    @base = Appearance.create!(person_slug: @person.slug, descriptor: "Comets white", colorway: "comets white",
                               reference_url: "https://example.com/face.jpg", generation_notes: "short hair")
  end

  test "a twin is its own look, linked to the base, named with the iced suffix" do
    twin = Appearances::IcedTwin.create!(@base)

    assert twin.persisted?
    assert twin.iced?
    assert_equal @base.slug, twin.base_appearance_slug
    assert_equal "Comets white · iced", twin.descriptor
    assert_equal @base.reference_url, twin.reference_url
    assert_equal @base.generation_notes, twin.generation_notes
    assert_equal twin, @base.reload.iced_twin
    assert_includes Appearance.recastable, twin, "the recast picker lists the twin as its own look"
  end

  test "the base keeps the default and the colorway lookup" do
    twin = Appearances::IcedTwin.create!(@base)

    assert @base.reload.default?
    assert_nil twin.colorway, "file_for_colorway! must keep finding the base"
    assert_equal @base, Appearance.file_for_colorway!(person_slug: @person.slug, colorway: "comets white")
  end

  test "it is idempotent and builds nothing" do
    twin = Appearances::IcedTwin.create!(@base)

    assert_no_difference -> { Appearance.count } do
      assert_equal twin, Appearances::IcedTwin.create!(@base)
    end
    assert_nil twin.sheet_build_state
    assert_enqueued_jobs 0
  end

  test "a twin, a music-video look and a retired look get no twin" do
    twin = Appearances::IcedTwin.create!(@base)
    assert_raises(Appearances::IcedTwin::Refused) { Appearances::IcedTwin.create!(twin) }

    @base.update!(retired_at: Time.current)
    assert_match(/retired/, Appearances::IcedTwin.refusal(@base))

    performer_look = Appearance.new(person_slug: @person.slug, descriptor: "Video look", music_video_slug: "some-video")
    assert_match(/music-video/, Appearances::IcedTwin.refusal(performer_look))
  end

  test "a taken twin name steps to the next free one" do
    Appearance.create!(person_slug: @person.slug, descriptor: "Comets white · iced")

    assert_equal "Comets white · iced 2", Appearances::IcedTwin.create!(@base).descriptor
  end

  test "destroying the base unlinks its twin rather than leaving a dangling pointer" do
    twin = Appearances::IcedTwin.create!(@base)
    @base.destroy!

    assert_nil twin.reload.base_appearance_slug
    assert twin.iced?
  end
end
