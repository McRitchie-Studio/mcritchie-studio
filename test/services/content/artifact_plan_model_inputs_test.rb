require "test_helper"

# [unit] EVERY ASSET THE MODEL BUILD CONSUMES ANSWERS reuse / refresh / acquire
# BEFORE the build starts, and staleness is causal: an input changed after the
# thing built from it.
class Content::ArtifactPlan::ModelInputsTest < ActiveSupport::TestCase
  setup do
    Appearance.delete_all
    ArtifactSubject.delete_all
    Artifact.delete_all
    AppearanceReferencePhoto.delete_all
    ImageCache.where(purpose: "headshot").delete_all
    @person = people(:josh_allen)
    @athlete = athletes(:allen_athlete)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
  end

  def inputs = Content::ArtifactPlan::ModelInputs.new(@look.reload)

  def cache_headshot(variant: "original", at: 2.days.ago)
    ImageCache.create!(owner: @athlete, purpose: "headshot", variant: variant,
                       s3_key: "headshots/nfl/buffalo-bills/josh-allen/#{variant}.png",
                       content_type: "image/png", source_url: @athlete.espn_headshot_url,
                       created_at: at, updated_at: at)
  end

  def reference_photo(at:, chosen: true, url: "https://example.com/allen-#{SecureRandom.hex(3)}.png")
    AppearanceReferencePhoto.create!(appearance_slug: @look.slug, image_url: url, source: "search",
                                     chosen: chosen, created_at: at, updated_at: at)
  end

  def file_sheet(at:)
    artifact = Artifact.create!(kind: "character_sheet", image_url: "https://example.com/sheet.png",
                                created_at: at, updated_at: at)
    ArtifactSubject.create!(artifact_slug: artifact.slug, person_slug: @person.slug,
                            appearance_slug: @look.slug, ordinal: 1)
    artifact
  end

  test "each asset kind reports its own decision" do
    assert_equal %w[anchor references identity sheet], inputs.assets.map(&:kind)
    inputs.assets.each do |asset|
      assert_includes %i[reuse refresh acquire], asset.decision, asset.kind
      assert asset.detail.present?, "#{asset.kind} owes the operator a sentence"
    end
  end

  test "an athlete with no cached headshot must acquire the anchor" do
    anchor = inputs.anchor

    assert_predicate anchor, :acquire?
    assert_nil anchor.occupant
  end

  test "a cached headshot is the anchor to reuse, widest variant first" do
    cache_headshot(variant: "400")
    cache_headshot(variant: "original")

    anchor = inputs.anchor
    assert_predicate anchor, :reuse?
    assert_equal "original", anchor.occupant.variant
    assert_includes anchor.url, "/original.png"
  end

  test "an athlete's typed URL is not an anchor" do
    @look.update!(reference_url: "https://example.com/wide-action-shot.png")

    assert_predicate inputs.anchor, :acquire?,
                     "a wide action shot fails at prepare; only the cached headshot anchors an athlete"
  end

  test "a person with no athlete profile is anchored by the operator's URL" do
    person = Person.create!(first_name: "Kendrick", last_name: "Lamar")
    @look = Appearance.create!(person_slug: person.slug, descriptor: "Stage")
    assert_predicate inputs.anchor, :acquire?

    @look.update!(reference_url: "https://example.com/kendrick.png")
    assert_predicate inputs.anchor, :reuse?
    assert_equal "https://example.com/kendrick.png", inputs.anchor.url
  end

  test "a headshot cached from a source ESPN has since moved is a refresh" do
    @athlete.update!(espn_headshot_url: "https://a.espncdn.com/i/headshots/nfl/players/full/3918298.png")
    cache_headshot
    @athlete.update!(espn_headshot_url: "https://a.espncdn.com/i/headshots/nfl/players/full/9999999.png")

    assert_predicate inputs.anchor, :refresh?
  end

  test "the anchor refusal names the missing asset and how to get it" do
    message = inputs.refusal_for(:sheet)

    assert_includes message, "Josh Allen"
    assert_includes message, "cached headshot"
    assert_includes message, "nothing was spent"
  end

  test "a present anchor refuses nothing" do
    cache_headshot

    assert_nil inputs.refusal_for(:sheet)
    assert_nil inputs.refusal_for(:identity)
  end

  test "no gathered photographs is an acquire, and it does not block the build" do
    cache_headshot

    assert_predicate inputs.references, :acquire?
    assert_nil inputs.refusal_for(:sheet), "the headshot alone is enough to build"
  end

  test "identity is acquired when none was minted" do
    assert_predicate inputs.identity, :acquire?
  end

  test "identity is stale when photos change after mint" do
    cache_headshot(at: 3.days.ago)
    reference_photo(at: 2.days.ago)
    @look.update!(higgsfield_reference_id: SecureRandom.uuid, higgsfield_reference_status: "completed",
                  higgsfield_reference_minted_at: 1.day.ago)
    assert_predicate inputs.identity, :reuse?

    reference_photo(at: 1.hour.ago)

    identity = inputs.identity
    assert_predicate identity, :refresh?
    assert_predicate identity, :stale?
    assert_includes identity.detail, "reference photos"
  end

  test "an un-chosen photograph after the mint is a change too" do
    photo = reference_photo(at: 2.days.ago)
    cache_headshot(at: 3.days.ago)
    @look.update!(higgsfield_reference_id: SecureRandom.uuid, higgsfield_reference_status: "completed",
                  higgsfield_reference_minted_at: 1.day.ago)

    photo.update!(chosen: false)

    assert_predicate inputs.identity, :stale?, "removing a photo changes the set the identity was built from"
  end

  test "a status poll after the mint does not make the identity look fresh" do
    cache_headshot(at: 3.days.ago)
    @look.update!(higgsfield_reference_id: SecureRandom.uuid, higgsfield_reference_status: "completed",
                  higgsfield_reference_minted_at: 2.days.ago, higgsfield_reference_synced_at: Time.current)
    reference_photo(at: 1.day.ago)

    assert_predicate inputs.identity, :stale?
  end

  test "an identity minted before the mint time was recorded cannot be judged" do
    @look.update!(higgsfield_reference_id: SecureRandom.uuid, higgsfield_reference_status: "completed")

    identity = inputs.identity
    assert_predicate identity, :reuse?
    assert_not identity.stale?
    assert_includes identity.detail, "unrecorded"
  end

  test "a sheet built before its anchor was re-cached is stale" do
    file_sheet(at: 2.days.ago)
    cache_headshot(at: 1.day.ago)

    sheet = inputs.sheet
    assert_predicate sheet, :refresh?
    assert_includes sheet.detail, "headshot"
  end

  test "a sheet built after all its inputs is reused" do
    cache_headshot(at: 3.days.ago)
    reference_photo(at: 2.days.ago)
    artifact = file_sheet(at: 1.day.ago)

    sheet = inputs.sheet
    assert_predicate sheet, :reuse?
    assert_equal artifact, sheet.occupant
  end

  test "a retired sheet is not on file" do
    file_sheet(at: 1.day.ago).retire!

    assert_predicate inputs.sheet, :acquire?
  end
end
