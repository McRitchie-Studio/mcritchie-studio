require "test_helper"

# [unit] ONE PHOTOGRAPH IN, ONE STAMPED ARTIFACT OUT.
#
# The two properties worth testing here are the operator's two decisions:
# the generator is chosen from the registry by CAPABILITY (never named), and every
# artifact records WHAT MADE IT so a library holding images from several
# generators stays readable.
#
# NOTHING HERE TOUCHES THE NETWORK. The adapter is stubbed at
# ImageGeneration::Adapter.for, so not even a client is constructed against a
# real credential; the suite-wide FAL_NO_LIVE_CALLS trap is the backstop if that
# ever slips.
class Appearances::GenerateArtifactTest < ActiveSupport::TestCase
  setup do
    Appearance.delete_all
    ArtifactSubject.delete_all
    Artifact.delete_all
    ImageCache.where(purpose: "headshot").delete_all
    ImageGeneration::Registry.reload!
    @person = people(:josh_allen)
    @athlete = athletes(:allen_athlete)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
    @row = ImageGeneration::Registry.find!("fal_ideogram_character")
  end

  teardown { ImageGeneration::Registry.reload! }

  def cache_headshot(variant:, key:)
    ImageCache.create!(owner: @athlete, purpose: "headshot", variant: variant,
                       s3_key: key, content_type: "image/png")
  end

  # A FAKE ADAPTER CLASS, matching what ImageGeneration::Adapter.for returns: a
  # class that answers .new(row) with something answering #generate_and_wait.
  class FakeAdapter
    Call = Struct.new(:prompt, :reference_urls, :seed, :image_size, keyword_init: true)

    class << self
      attr_accessor :calls, :result

      def new(_row) = instance
      def instance = @instance ||= allocate
    end

    def generate_and_wait(prompt:, reference_urls:, seed: nil, image_size: nil, num_images: 1)
      self.class.calls << Call.new(prompt: prompt, reference_urls: reference_urls,
                                   seed: seed, image_size: image_size)
      self.class.result
    end
  end

  def with_fake_adapter(result: nil)
    FakeAdapter.calls = []
    FakeAdapter.result = result || ImageGeneration::Result.new(
      image_urls: ["https://v3.fal.media/files/x/out.png"],
      seed: 4242, request_id: "req-1",
      generator_key: @row.key, version: @row.provenance_version
    )
    ImageGeneration::Adapter.stub(:for, FakeAdapter) do
      with_env("FAL_KEY" => "key-id:key-secret") { yield }
    end
  end

  # THE IDENTITY PHOTO IS READ OFF THE STORED s3_key, NEVER REBUILT. This matters
  # right now rather than in principle: Athletes::RekeyHeadshots is actively
  # moving athletes out of headshots/nfl/free-agents/, so a rebuilt path points
  # at an object that has already moved.
  test "the identity photo comes from the stored image cache row" do
    cache_headshot(variant: "original", key: "headshots/nfl/somewhere-else/josh-allen/original.png")

    url = Appearances::GenerateArtifact.new(@look.reload).identity_photo_url

    assert_includes url, "headshots/nfl/somewhere-else/josh-allen/original.png",
                    "the stored key wins; nothing may rebuild it from the team slug"
  end

  # DELIBERATELY DIFFERENT FROM Appearances::ReferenceImages::HEADSHOT_VARIANTS.
  # That list feeds a TRAINING set; this feeds a face adapter reading ONE image,
  # where every pixel of the face is identity it can carry.
  test "the original variant beats the 400px crop for a one-photo adapter" do
    cache_headshot(variant: "400", key: "headshots/nfl/buffalo-bills/josh-allen/400.png")
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")

    url = Appearances::GenerateArtifact.new(@look.reload).identity_photo_url

    assert_includes url, "/original.png"
  end

  test "a narrower variant still serves when the original was never cached" do
    cache_headshot(variant: "400", key: "headshots/nfl/buffalo-bills/josh-allen/400.png")

    assert_includes Appearances::GenerateArtifact.new(@look.reload).identity_photo_url, "/400.png"
  end

  # A PERSON WITH NO CACHED HEADSHOT — a coach, a new signing, anyone off the
  # nflverse roster — has no other way into this lane, and the look form has been
  # writing this column all along.
  test "the operator's typed reference photo serves when nothing is cached" do
    @look.update!(reference_url: "https://example.com/courtland-sutton.png")

    url = Appearances::GenerateArtifact.new(@look.reload).identity_photo_url

    assert_equal "https://example.com/courtland-sutton.png", url
  end

  # THE MEASURED URL LEADS. `reference_url` is free text that could point
  # anywhere; the cached headshot is the one whose reachability we control.
  test "the cached headshot outranks the typed URL when both exist" do
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")
    @look.update!(reference_url: "https://example.com/somewhere-else.png")

    assert_includes Appearances::GenerateArtifact.new(@look.reload).identity_photo_url, "/original.png"
  end

  # WE ARE HANDING THIS URL TO SOMEBODY ELSE'S SERVER TO FETCH. A localhost or
  # private-range URL out of a form would be asking a third party to probe our
  # network on our behalf.
  test "a typed URL we would not hand a remote fetcher is refused" do
    @look.update!(reference_url: "http://localhost:3000/secret.png")

    assert_nil Appearances::GenerateArtifact.new(@look.reload).identity_photo_url
  end

  # THE POSE LEADS THE PROMPT. The identity arrives through the reference image,
  # not through the words; leading with the look's brief buries the one
  # instruction that decides whether this is a full-body shot or another portrait.
  test "the prompt leads with the pose and then says who the person is" do
    @look.update!(generation_notes: "orange jersey")
    service = Appearances::GenerateArtifact.new(@look.reload, pose: "full_body_front")

    prompt = service.prompt

    assert prompt.start_with?("full body photograph"), "the pose is the deciding instruction"
    assert_includes prompt, "Bills home"
    assert_includes prompt, "orange jersey"
  end

  # THE DEFAULT POSE IS THE ONE THAT CAN FALSIFY THE FEATURE. A face adapter is
  # strong on faces; a portrait that works proves the cheap half. The full-body
  # shot is the test worth buying first.
  test "the default pose is the full body shot, not a portrait" do
    assert_equal "full_body_front", Appearances::GenerateArtifact::DEFAULT_POSE
    assert_includes Appearances::GenerateArtifact::POSES.fetch("full_body_front")[:prompt],
                    "head to toe"
  end

  test "the sheet the operator asked for is registered in full" do
    poses = Appearances::GenerateArtifact::POSES.keys

    %w[full_body_front full_body_back side_profile head_on expression_smile].each do |pose|
      assert_includes poses, pose
    end
  end

  # THE STAMP. Without it a mixed library is unreadable and you cannot tell a
  # regression from a provider change.
  test "the generated artifact records which generator and which version made it" do
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")

    artifact = with_fake_adapter { Appearances::GenerateArtifact.call(@look.reload) }

    assert_equal "fal_ideogram_character", artifact.generator
    assert_equal "fal-ai/ideogram/character", artifact.generator_endpoint
    assert_equal @row.provenance_version, artifact.generator_version
    assert_equal 4242, artifact.seed, "the seed is half of reproducing this frame"
    assert_includes artifact.prompt, "full body photograph", "the prompt is the other half"
    assert_equal "https://v3.fal.media/files/x/out.png", artifact.image_url
    assert_predicate artifact, :generated?
  end

  test "the artifact is filed against the look so the model page finds it" do
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")

    artifact = with_fake_adapter { Appearances::GenerateArtifact.call(@look.reload, pose: "full_body_back") }

    subject = artifact.subjects.sole
    assert_equal @look.slug, subject.appearance_slug
    assert_equal @person.slug, subject.person_slug
    assert_equal "Full body, from behind", subject.role
  end

  test "one photograph is the whole input, and it is sent as the reference" do
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")

    with_fake_adapter { Appearances::GenerateArtifact.call(@look.reload) }

    call = FakeAdapter.calls.sole
    assert_equal 1, call.reference_urls.length,
                 "the zero-shot path needs exactly one face, which is why it works at all"
    assert_includes call.reference_urls.first, "/original.png"
    assert_equal Appearances::GenerateArtifact::IMAGE_SIZE, call.image_size
  end

  # THE TWO EXPECTED REFUSALS. Both are states rather than failures, and both
  # must refuse BEFORE anything can spend.
  test "a person with no cached headshot refuses before spending" do
    error = assert_raises(Appearances::GenerateArtifact::NoIdentityPhoto) do
      with_fake_adapter { Appearances::GenerateArtifact.call(@look.reload) }
    end

    assert_includes error.message, "nothing was spent"
    assert_empty FakeAdapter.calls
    assert_equal 0, Artifact.count
  end

  test "an unconfigured generator refuses and names the variable to set" do
    cache_headshot(variant: "original", key: "headshots/nfl/buffalo-bills/josh-allen/original.png")

    error = with_env("FAL_KEY" => nil) do
      assert_raises(Appearances::GenerateArtifact::NoGenerator) do
        Appearances::GenerateArtifact.call(@look.reload)
      end
    end

    assert_includes error.message, "FAL_KEY"
    assert_equal 0, Artifact.count
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
