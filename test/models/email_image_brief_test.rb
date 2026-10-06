# frozen_string_literal: true

require "test_helper"
require_relative "../support/email_image_fakes"

# [unit] The brief: its identity, the names piece 2 commits under, the
# approve-retires-the-previous rule, and spend that never reads unpriced as free.
class EmailImageBriefTest < ActiveSupport::TestCase
  include EmailImageFakes

  setup do
    Artifact.where(kind: "email_header").delete_all
    EmailImageBrief.delete_all
  end

  def candidate(brief, **attrs)
    Artifact.create!({ kind: "email_header", brief_slug: brief.slug, image_url: "https://assets.example.test/x.jpg",
                       generator: "openai_image_header", billable_units: 6_000 }.merge(attrs))
  end

  test "a brief derives its slug, catalog key and asset file name" do
    brief = turf_brief

    assert_equal "turf-monster-drop-signup-confirmation-new-player", brief.slug
    assert_equal "drop_signup_confirmation_new_player", brief.catalog_key
    assert_equal "drop-signup-confirmation-new-player-banner.jpg", brief.asset_filename
    assert_equal "turf-monster/drop_signup_confirmation/new_player", brief.storage_subject
    assert_equal 4, brief.max_rounds
  end

  test "the alt text is the headline unless overridden" do
    assert_equal "You're In!", turf_brief.effective_alt_text
    assert_equal "Welcome", turf_brief(variant: "existing_player", alt_text: "Welcome").effective_alt_text
  end

  test "text mode is baked or none; composited is not built yet" do
    assert turf_brief(text_mode: "none").valid?
    brief = EmailImageBrief.new(app: "turf-monster", email_key: "x", brand_kit: "turf-monster", headline: "Hi",
                                text_mode: "composited")
    assert_not brief.valid?
    assert brief.errors[:text_mode].any?
  end

  test "an unknown brand kit or a duplicate email is refused" do
    turf_brief
    dup = EmailImageBrief.new(app: "turf-monster", email_key: "drop_signup_confirmation", variant: "new_player",
                              brand_kit: "turf-monster", headline: "Again")
    assert_not dup.valid?
    bad = EmailImageBrief.new(app: "turf-monster", email_key: "y", brand_kit: "nope", headline: "Hi")
    assert_not bad.valid?
    assert bad.errors[:brand_kit].any?
  end

  test "approving a second candidate retires the first" do
    brief = turf_brief
    first = candidate(brief)
    second = candidate(brief)

    brief.approve!(first, by: "alex@mcritchie.studio")
    assert_equal first.slug, brief.reload.approved_artifact_slug
    assert_predicate first.reload, :approved?

    brief.approve!(second, by: "alex@mcritchie.studio")
    assert_equal second.slug, brief.reload.approved_artifact_slug
    assert_predicate first.reload, :retired?
    assert_not second.reload.retired?
    assert_equal "alex@mcritchie.studio", second.approved_by
  end

  test "retiring the approved candidate clears the approval" do
    brief = turf_brief
    a = candidate(brief)
    brief.approve!(a, by: "alex")
    brief.retire!(a)

    assert_nil brief.reload.approved_artifact_slug
    assert_predicate a.reload, :retired?
  end

  test "a candidate of another brief cannot be approved here" do
    brief = turf_brief
    other = turf_brief(variant: "existing_player")
    assert_raises(ArgumentError) { brief.approve!(candidate(other), by: "alex") }
  end

  test "spend sums tokens and leaves an unpriced cost nil, never zero" do
    brief = turf_brief
    candidate(brief, billable_units: 6_000)
    candidate(brief, billable_units: 6_500)

    assert_equal 12_500, brief.billable_units_total
    assert_nil brief.cost_usd_total
  end

  test "an email_header artifact must name its brief" do
    assert_not Artifact.new(kind: "email_header").valid?
  end
end
