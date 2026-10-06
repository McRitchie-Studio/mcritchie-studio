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

  STORED_URL = "https://mcritchie-studio-dev.s3.us-east-2.amazonaws.com/character-sheets/x/y.png".freeze

  def with_generator
    FakeAdapter.result = ImageGeneration::Result.new(
      image_urls: ["data:image/png;base64,QUJD"], seed: nil,
      request_id: "resp_1", generator_key: "openai_gpt5_sheet",
      # A MEASURED TOKEN COUNT, NOT AN INVENTED ONE. This stub used to carry a five-figure
      # number nothing ever measured, and it LEAKED: five comments across app/ and docs/
      # went on to quote it as an observed OpenAI cost and to overstate the order of
      # magnitude with it. Real sheets ran 6,724-7,629 (config/image_generators.yml).
      # Keep this a number the registry row can vouch for, so a reader who finds it
      # here and repeats it elsewhere repeats something true.
      version: "gpt-5-2025-08-07@v1", billable_units: 7_629
    )
    ImageGeneration::Adapter.stub(:for, FakeAdapter) do
      Appearances::StoreGeneratedImage.stub(:call, STORED_URL) do
        with_env("OPENAI_API_KEY" => "sk-test") { yield }
      end
    end
  end

  test "an anonymous visitor cannot spend" do
    with_generator { post generate_path }

    assert_response :redirect
    assert_no_enqueued_jobs only: SheetBuildJob
    assert_equal 0, Artifact.count, "a paid endpoint must not be reachable without a session"
  end

  # THE ONE THAT MATTERS. A signed-in member of the public is still the public.
  test "a signed-in non-admin cannot spend" do
    log_in_as(@viewer)

    with_generator { post generate_path }

    assert_redirected_to root_path
    assert_no_enqueued_jobs only: SheetBuildJob
    assert_equal 0, Artifact.count, "hub signup is open, so a session is not a cost control"
  end

  # THE REQUEST ENQUEUES AND RETURNS. The paid call runs in SheetBuildJob, never
  # inside the request Heroku cuts at 30 s.
  test "an admin press enqueues exactly one build and returns at once" do
    log_in_as(@admin)

    with_generator do
      FakeAdapter.stub(:instance, -> { flunk "the request must not call the generator" }) do
        assert_enqueued_jobs 1, only: SheetBuildJob do
          post generate_path, params: { number: "17" }
        end
      end
    end

    assert_redirected_to person_appearance_path(@person.slug, @look.slug)
    assert_match(/Building the character sheet/, flash[:notice])
    assert_equal 0, Artifact.count
    assert @look.reload.sheet_building?
  end

  test "the job files the sheet against the look and records done" do
    log_in_as(@admin)

    with_generator do
      post generate_path, params: { number: "17" }
      perform_enqueued_jobs
    end

    artifact = Artifact.sole
    assert_equal STORED_URL, artifact.image_url
    assert_equal "openai_gpt5_sheet", artifact.generator
    assert_includes artifact.prompt, "jersey number 17", "the typed number reaches the prompt"
    assert_equal @look.slug, artifact.subjects.sole.appearance_slug
    assert_equal "done", @look.reload.sheet_build_state
  end

  # THE DOUBLE-SPEND GUARD, server side: the second press starts nothing.
  test "a second press while building enqueues nothing and says so" do
    log_in_as(@admin)

    with_generator do
      post generate_path
      assert_no_enqueued_jobs(only: SheetBuildJob) { post generate_path }
    end

    assert_match(/already building/, flash[:alert])
    assert_enqueued_jobs 1, only: SheetBuildJob
  end

  test "a failed build shows its error and a retry button" do
    log_in_as(@admin)

    with_generator do
      FakeAdapter.result = ImageGeneration::Result.new(image_urls: [], seed: nil, request_id: "r",
                                                       generator_key: "openai_gpt5_sheet", version: "v")
      post generate_path
      perform_enqueued_jobs
      get person_appearance_path(@person.slug, @look.slug)
    end

    assert_equal "failed", @look.reload.sheet_build_state
    assert_select "[data-test=sheet-build-status][data-state=failed]", text: /returned no image/
    assert_select "form[action=?] input[type=submit][value=?]", generate_path, "Retry character sheet"
  end

  test "a building look shows the elapsed time and no build button" do
    @look.update_columns(sheet_build_state: "building", sheet_build_started_at: 90.seconds.ago)
    log_in_as(@admin)

    with_env("OPENAI_API_KEY" => "sk-test") { get person_appearance_path(@person.slug, @look.slug) }

    assert_select "[data-test=sheet-build-status][data-state=building]", text: /1m 3\ds/
    assert_select "form[action=?]", generate_path, count: 0
  end

  # A REFUSAL IS A FLASH, NOT A 500, and it names the variable to set.
  test "an unconfigured generator refuses without spending and names the variable" do
    log_in_as(@admin)

    with_env("OPENAI_API_KEY" => nil) { post generate_path }

    assert_redirected_to person_appearance_path(@person.slug, @look.slug)
    assert_match(/OPENAI_API_KEY/, flash[:alert])
    assert_no_enqueued_jobs only: SheetBuildJob
    assert_nil @look.reload.sheet_build_state, "a refusal claims nothing"
    assert_equal 0, Artifact.count
  end

  # THE PAGE MUST RENDER WITH NO CREDENTIAL ANYWHERE. This is the state on every
  # desk, so a page that 500s here is a page nobody can develop on.
  test "the model page renders with generation switched off" do
    log_in_as(@admin)
    with_env("OPENAI_API_KEY" => nil) { get person_appearance_path(@person.slug, @look.slug) }

    assert_response :success
    assert_select "[data-test=model-output-panel]"
    assert_select "[data-test=zero-shot-generate]"
    assert_match(/OPENAI_API_KEY/, response.body, "the page names the variable rather than shrugging")
  end

  # THE PROVENANCE STAMP IS ON THE PAGE, not only in the database. The operator
  # reads a library, not a schema.
  test "a generated image renders its generator and seed on the card" do
    log_in_as(@admin)
    with_generator do
      post generate_path
      perform_enqueued_jobs
    end

    with_env("OPENAI_API_KEY" => "sk-test") do
      get person_appearance_path(@person.slug, @look.slug)
    end

    assert_response :success
    assert_select "[data-test=generated-images]"
    assert_select "[data-test=artifact-provenance]"
    assert_match(/GPT-5 image generation/, response.body)
    assert_match(/7,629 tokens/, response.body, "the unit is printed, never a bare count")
  end

  # NO ANCHOR, NO BUILD. Both paid doors refuse, name what is missing and how to
  # get it, and leave no ErrorLog row: a missing headshot is a state, not a failure.
  test "the sheet build refuses and names the missing anchor" do
    ImageCache.where(purpose: "headshot").delete_all
    @look.update!(reference_url: "https://example.com/wide-action-shot.png")
    log_in_as(@admin)

    assert_no_difference -> { ErrorLog.count } do
      with_generator { post generate_path }
    end

    assert_redirected_to person_appearance_path(@person.slug, @look.slug)
    assert_match(/Josh Allen cannot be built: no cached headshot/, flash[:alert])
    assert_match(/nothing was spent/, flash[:alert])
    assert_no_enqueued_jobs only: SheetBuildJob
    assert_equal 0, Artifact.count
  end

  test "the identity mint refuses and names the missing anchor" do
    ImageCache.where(purpose: "headshot").delete_all
    @look.update!(reference_url: "https://example.com/wide-action-shot.png")
    log_in_as(@admin)

    Higgsfield::Client.stub(:new, -> { flunk "no anchor must never reach the vendor" }) do
      post mint_person_appearance_path(@person.slug, @look.slug)
    end

    assert_redirected_to person_appearance_path(@person.slug, @look.slug)
    assert_match(/cached headshot/, flash[:alert])
    assert_nil @look.reload.higgsfield_reference_id
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
