require "test_helper"

# [unit] ONE PHOTOGRAPH IN, ONE STAMPED CHARACTER SHEET OUT.
#
# The properties worth testing are the operator's two decisions plus the
# correction that reshaped this service: the generator is chosen from the registry
# by CAPABILITY (never named), every artifact records what made it, and a sheet is
# ONE artifact from ONE call rather than five poses to assemble.
#
# NOTHING HERE TOUCHES THE NETWORK OR S3. The adapter is stubbed at
# ImageGeneration::Adapter.for and the upload at
# Appearances::StoreGeneratedImage.call; the suite-wide traps are the backstop if
# either ever slips.
class Appearances::GenerateArtifactTest < ActiveSupport::TestCase
  STORED_URL = "https://mcritchie-studio-dev.s3.us-east-2.amazonaws.com/character-sheets/x/y.png".freeze

  setup do
    Appearance.delete_all
    ArtifactSubject.delete_all
    Artifact.delete_all
    ImageCache.where(purpose: "headshot").delete_all
    ImageGeneration::Registry.reload!
    @person = people(:josh_allen)
    @athlete = athletes(:allen_athlete)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
    @row = ImageGeneration::Registry.find!("openai_gpt5_sheet")
  end

  teardown { ImageGeneration::Registry.reload! }

  def cache_headshot(variant:, key:)
    ImageCache.create!(owner: @athlete, purpose: "headshot", variant: variant,
                       s3_key: key, content_type: "image/png")
  end

  class FakeAdapter
    Call = Struct.new(:prompt, :reference_urls, :seed, keyword_init: true)

    class << self
      attr_accessor :calls, :result
      def new(_row) = instance
      def instance = @instance ||= allocate
    end

    def generate_and_wait(prompt:, reference_urls:, seed: nil, **)
      self.class.calls << Call.new(prompt: prompt, reference_urls: reference_urls, seed: seed)
      self.class.result
    end
  end

  def with_fake_generator(result: nil)
    FakeAdapter.calls = []
    FakeAdapter.result = result || ImageGeneration::Result.new(
      image_urls: ["data:image/png;base64,QUJD"], seed: nil, request_id: "resp_1",
      generator_key: @row.key, version: @row.provenance_version, billable_units: 18_432
    )
    ImageGeneration::Adapter.stub(:for, FakeAdapter) do
      Appearances::StoreGeneratedImage.stub(:call, STORED_URL) do
        with_env("OPENAI_API_KEY" => "sk-test") { yield }
      end
    end
  end

  # THE CORRECTION THIS SERVICE WAS RESHAPED AROUND. It first shipped generating
  # one POSE per call from a five-entry map; the generator that actually holds a
  # likeness produces the whole sheet in one call, and five separate calls is
  # precisely the shape measured to fail.
  test "a sheet is ONE call and ONE artifact, not five poses" do
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")

    artifact = with_fake_generator { Appearances::GenerateArtifact.call(@look.reload) }

    assert_equal 1, FakeAdapter.calls.length, "one sheet is one call"
    assert_equal 1, Artifact.count, "one sheet is one artifact"
    assert_equal 1, artifact.subjects.count
    assert_equal "character_sheet", artifact.kind
    assert_not Appearances::GenerateArtifact.const_defined?(:POSES),
               "the pose map is gone; a sheet is not assembled from separate calls"
  end

  # ASKS FOR THE STRONG CAPABILITY. `zero_shot_identity` and `single_portrait` are
  # both true of rows measured to return six different men on a grid.
  test "it requires the character_sheet capability, not merely a likeness" do
    assert_equal :character_sheet, Appearances::GenerateArtifact::CAPABILITY

    row = with_env("OPENAI_API_KEY" => "sk-test", "FAL_KEY" => "k:v") do
      Appearances::GenerateArtifact.new(@look).row
    end

    assert row.capable_of?(:character_sheet)
    assert_equal "openai_gpt5_sheet", row.key,
                 "a fal row is available here too and must NOT be chosen for a sheet"
  end

  # ⚠ A REVERSAL, AND THE OPERATOR ASKED FOR IT. This case used to assert "exactly one
  # reference photograph is sent", justified by "five performed no better than one" — a
  # sentence this repo attributes to three different paths (config/image_generators.yml
  # credits this Responses row, ImageGeneration::OpenAI credits /v1/images/edits, the
  # 2026-09-27 operator relay credits the Higgsfield trainer), so it settles nothing here.
  #
  # The operator's words, 2026-09-27: *"it would be better if we provided a few headshots
  # when submitting for the character model ... more context on facial structure and
  # expressions"*. So this service now offers the distilled set.
  #
  # WHAT NARROWS IT NOW IS THE ROW'S DECLARED ARITY, one layer down, where a reader can
  # check it — see ImageGeneration::OpenAITest. This service's job is to OFFER the right
  # photographs in the right order.
  test "the whole vetted reference set is offered, the cached headshot first" do
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")
    @look.update!(reference_url: "https://example.com/another.png")

    with_fake_generator { Appearances::GenerateArtifact.call(@look.reload) }

    call = FakeAdapter.calls.sole
    assert_includes call.reference_urls.first, "/original.png",
                    "the one input measured to carry a likeness leads the list"
    assert_includes call.reference_urls, "https://example.com/another.png",
                    "the photograph the operator typed is a reference, not a fallback"
  end

  # THE `original` VARIANT IS WHY THIS SERVICE PREPENDS ITS OWN FLOOR RATHER THAN TAKING
  # ReferenceSet'S. That object resolves the headshot through
  # Appearances::ReferenceImages::HEADSHOT_VARIANTS (`%w[400 100]`); a zero-shot generator
  # reading one face carries every pixel of it, so this path prefers the original.
  test "the widest cached variant leads even when a narrower one exists" do
    cache_headshot(variant: "400", key: "headshots/nfl/buffalo-bills/josh-allen/400.png")
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")

    with_fake_generator { Appearances::GenerateArtifact.call(@look.reload) }

    urls = FakeAdapter.calls.sole.reference_urls
    assert_includes urls.first, "/original.png"
    assert_equal urls.uniq, urls, "the same headshot at two variants is still one photograph"
  end

  # A SCOUTED PHOTOGRAPH REACHES THE SHEET — the narrowing the operator named. Nothing
  # about it is measured by a classifier, and that is deliberate: the zero-shot path has
  # no preparation stage to refuse it, so an unmeasured reference is allowed here and
  # refused at Higgsfield's trainer.
  test "a chosen scouted photograph rides along with the headshot" do
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")
    AppearanceReferencePhoto.create!(appearance_slug: @look.slug, chosen: true,
                                     image_url: "https://cdn.example.com/scouted.jpg",
                                     source: AppearanceReferencePhoto::SOURCE_SEARCH)

    with_fake_generator { Appearances::GenerateArtifact.call(@look.reload) }

    assert_includes FakeAdapter.calls.sole.reference_urls, "https://cdn.example.com/scouted.jpg"
  end

  # AND A PHOTOGRAPH OF THE WRONG MAN DOES NOT. A sheet built from two faces is a sheet of
  # a third man, which is the same defect as a blended trained identity by another route.
  test "a chosen photograph of a different person is never offered to the sheet" do
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")
    AppearanceReferencePhoto.create!(appearance_slug: @look.slug, chosen: true,
                                     image_url: "https://cdn.example.com/keenan.jpg",
                                     title: "Keenan Allen.jpg",
                                     source: AppearanceReferencePhoto::SOURCE_SEARCH)

    with_fake_generator { Appearances::GenerateArtifact.call(@look.reload) }

    refute_includes FakeAdapter.calls.sole.reference_urls, "https://cdn.example.com/keenan.jpg"
  end

  # READS THE STORED s3_key AND NEVER REBUILDS THE PATH. Athletes::RekeyHeadshots
  # is actively moving athletes between prefixes.
  test "the identity photo comes from the stored image cache row" do
    cache_headshot(variant: "original", key: "headshots/nfl/somewhere-else/josh-allen/original.png")

    url = Appearances::GenerateArtifact.new(@look.reload).identity_photo_url

    assert_includes url, "headshots/nfl/somewhere-else/josh-allen/original.png"
  end

  test "the original variant beats the 400px crop" do
    cache_headshot(variant: "400", key: "headshots/nfl/buffalo-bills/josh-allen/400.png")
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")

    assert_includes Appearances::GenerateArtifact.new(@look.reload).identity_photo_url, "/original.png"
  end

  test "a typed URL serves a person with no cached headshot" do
    @look.update!(reference_url: "https://example.com/courtland.png")

    assert_equal "https://example.com/courtland.png",
                 Appearances::GenerateArtifact.new(@look.reload).identity_photo_url
  end

  test "a typed URL we would not hand a remote fetcher is refused" do
    @look.update!(reference_url: "http://localhost:3000/secret.png")

    assert_nil Appearances::GenerateArtifact.new(@look.reload).identity_photo_url
  end

  # THE STAMP. Without it a library holding images from several generators cannot
  # tell a regression from a provider change.
  test "the artifact records which generator and which pinned model made it" do
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")

    artifact = with_fake_generator { Appearances::GenerateArtifact.call(@look.reload) }

    assert_equal "openai_gpt5_sheet", artifact.generator
    assert_equal "https://api.openai.com/v1/responses", artifact.generator_endpoint
    assert_equal "gpt-5-2025-08-07@v1", artifact.generator_version,
                 "the MODEL is stamped, not the door every model comes through"
    assert_equal 18_432, artifact.billable_units
    assert_includes artifact.prompt, "5-column by 2-row grid"
    assert_predicate artifact, :generated?
  end

  # THE BYTES BECOME OURS. A data URI cannot live in the column and a vendor CDN
  # link is not a library.
  test "the generated image is stored in our own bucket and that url is recorded" do
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")

    artifact = with_fake_generator { Appearances::GenerateArtifact.call(@look.reload) }

    assert_equal STORED_URL, artifact.image_url
    assert_not artifact.image_url.start_with?("data:"),
               "a multi-megabyte data URI must never reach the column"
  end

  test "the artifact is filed against the look so the model page finds it" do
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")

    artifact = with_fake_generator { Appearances::GenerateArtifact.call(@look.reload) }

    subject = artifact.subjects.sole
    assert_equal @look.slug, subject.appearance_slug
    assert_equal @person.slug, subject.person_slug
  end

  # THE TWO EXPECTED REFUSALS, both of which must refuse BEFORE anything spends.
  test "a person with no cached headshot refuses before spending" do
    error = assert_raises(Appearances::GenerateArtifact::NoIdentityPhoto) do
      with_fake_generator { Appearances::GenerateArtifact.call(@look.reload) }
    end

    assert_includes error.message, "nothing was spent"
    assert_empty FakeAdapter.calls
    assert_equal 0, Artifact.count
  end

  test "an unconfigured generator refuses and names the variable to set" do
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")

    error = with_env("OPENAI_API_KEY" => nil) do
      assert_raises(Appearances::GenerateArtifact::NoGenerator) do
        Appearances::GenerateArtifact.call(@look.reload)
      end
    end

    assert_includes error.message, "OPENAI_API_KEY"
    assert_equal 0, Artifact.count
  end

  # A FAL ROW BEING CONFIGURED MUST NOT MAKE THE SHEET PATH LOOK AVAILABLE. This
  # is the overclaim bug in its other form: the page would offer a button that
  # routes to a model measured to fail at sheets.
  test "a configured portrait generator does not make the sheet path available" do
    with_env("OPENAI_API_KEY" => nil, "FAL_KEY" => "k:v") do
      assert_not Appearances::GenerateArtifact.available?,
                 "fal can do a portrait; it is not measured to hold a sheet"
    end
  end

  private

  def with_env(pairs)
    original = pairs.keys.index_with { |k| ENV[k] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    ImageGeneration::Registry.reload!
    yield
  ensure
    original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    ImageGeneration::Registry.reload!
  end
end
