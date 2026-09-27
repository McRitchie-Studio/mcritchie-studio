require "test_helper"

# [integration] THE GENERATE BUTTON, END TO END THROUGH THE ROUTE.
#
# THE GATE IS THE POINT OF THIS FILE. #generate buys an image on our credential,
# and hub signup is OPEN — both magic-link and Google are create-or-login — so
# "not reachable without a session" means "reachable by anyone willing to type an
# email address", which is no control over a paid endpoint at all. `require_admin`
# is the gate that costs something to get through, and these tests are what stop
# a later refactor quietly widening it.
#
# NOTHING HERE TOUCHES THE NETWORK: the adapter is stubbed, and the suite-wide
# FAL_NO_LIVE_CALLS trap is the backstop.
class AppearancesGenerateTest < ActionDispatch::IntegrationTest
  setup do
    Appearance.delete_all
    ArtifactSubject.delete_all
    Artifact.delete_all
    ImageCache.where(purpose: "headshot").delete_all
    ImageGeneration::Registry.reload!
    @admin = users(:alex)
    @viewer = users(:viewer)
    @person = people(:josh_allen)
    @athlete = athletes(:allen_athlete)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
    ImageCache.create!(owner: @athlete, purpose: "headshot", variant: "original",
                       s3_key: "headshots/nfl/buffalo-bills/josh-allen/original.png",
                       content_type: "image/png")
  end

  teardown { ImageGeneration::Registry.reload! }

  class FakeAdapter
    class << self
      attr_accessor :result
      def new(_row) = instance
      def instance = @instance ||= allocate
    end

    def generate_and_wait(**)
      self.class.result
    end
  end

  def generate_path = generate_person_appearance_path(@person.slug, @look.slug)

  def with_generator
    FakeAdapter.result = ImageGeneration::Result.new(
      image_urls: ["https://v3.fal.media/files/x/out.png"], seed: 4242,
      request_id: "req-1", generator_key: "fal_ideogram_character",
      version: "fal-ai/ideogram/character@1.0.0"
    )
    ImageGeneration::Adapter.stub(:for, FakeAdapter) do
      with_env("FAL_KEY" => "key-id:key-secret") { yield }
    end
  end

  test "an anonymous visitor cannot spend" do
    with_generator { post generate_path }

    assert_response :redirect
    assert_equal 0, Artifact.count, "a paid endpoint must not be reachable without a session"
  end

  # THE ONE THAT MATTERS. A signed-in member of the public is still the public.
  test "a signed-in non-admin cannot spend" do
    log_in_as(@viewer)

    with_generator { post generate_path }

    assert_redirected_to root_path
    assert_equal 0, Artifact.count, "hub signup is open, so a session is not a cost control"
  end

  test "an admin generates one image and it is filed against the look" do
    log_in_as(@admin)

    with_generator { post generate_path, params: { pose: "full_body_front" } }

    assert_redirected_to person_appearance_path(@person.slug, @look.slug)
    artifact = Artifact.sole
    assert_equal "https://v3.fal.media/files/x/out.png", artifact.image_url
    assert_equal "fal_ideogram_character", artifact.generator
    assert_equal @look.slug, artifact.subjects.sole.appearance_slug
  end

  # THE FLASH NAMES WHAT MADE IT. The operator is about to judge a picture, and
  # "which model produced this" is the first thing he needs to judge it —
  # especially while more than one generator is in play.
  test "the flash names the generator and the seed" do
    log_in_as(@admin)

    with_generator { post generate_path }

    assert_match(/Ideogram V3 Character/, flash[:notice])
    assert_match(/4242/, flash[:notice])
  end

  # A REFUSAL IS A FLASH, NOT A 500, and it names the variable to set.
  test "an unconfigured generator refuses without spending and names the variable" do
    log_in_as(@admin)

    with_env("FAL_KEY" => nil) { post generate_path }

    assert_redirected_to person_appearance_path(@person.slug, @look.slug)
    assert_match(/FAL_KEY/, flash[:alert])
    assert_equal 0, Artifact.count
  end

  # THE PAGE IS PUBLIC AND MUST RENDER WITH NO CREDENTIAL ANYWHERE. This is the
  # state on every desk, so a page that 500s here is a page nobody can develop on.
  test "the model page renders for the public with generation switched off" do
    with_env("FAL_KEY" => nil) { get person_appearance_path(@person.slug, @look.slug) }

    assert_response :success
    assert_select "[data-test=model-output-panel]"
    assert_select "[data-test=zero-shot-generate]"
    assert_match(/FAL_KEY/, response.body, "the page names the variable rather than shrugging")
    assert_select "form[action=?]", generate_path, count: 0, message: "no control the public may not use"
  end

  # THE PROVENANCE STAMP IS ON THE PAGE, not only in the database. The operator
  # reads a library, not a schema.
  test "a generated image renders its generator and seed on the card" do
    log_in_as(@admin)
    with_generator { post generate_path }

    with_env("FAL_KEY" => "key-id:key-secret") do
      get person_appearance_path(@person.slug, @look.slug)
    end

    assert_response :success
    assert_select "[data-test=generated-images]"
    assert_select "[data-test=artifact-provenance]"
    assert_match(/Ideogram V3 Character/, response.body)
    assert_match(/4242/, response.body)
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
