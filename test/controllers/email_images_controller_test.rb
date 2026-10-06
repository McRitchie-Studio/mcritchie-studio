# frozen_string_literal: true

require "test_helper"
require_relative "../support/email_image_fakes"

# [integration] /email_images end to end through the routes: admin only (the
# Generate button buys images and hub signup is open), a round with the fake
# adapter files two candidates, approve and retire, and the preview renders
# the chosen candidate inside the real email shell. Nothing is spent.
class EmailImagesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include EmailImageFakes

  setup do
    Artifact.where(kind: "email_header").delete_all
    EmailImageBrief.delete_all
    ImageGeneration::Registry.reload!
    @admin = users(:alex)
    @viewer = users(:viewer)
  end

  teardown { ImageGeneration::Registry.reload! }

  def brief_params(**overrides)
    { email_image_brief: { app: "turf-monster", email_key: "drop_signup_confirmation", variant: "new_player",
                           brand_kit: "turf-monster", text_mode: "baked", image_format: "jpg",
                           headline: "You're In!" }.merge(overrides) }
  end

  test "an anonymous visitor reaches nothing" do
    brief = turf_brief
    get email_images_path
    assert_response :redirect
    post generate_email_image_path(brief)
    assert_response :redirect
    assert_no_enqueued_jobs only: EmailImageBuildJob
  end

  test "a signed-in non-admin cannot read, open or spend" do
    brief = turf_brief
    log_in_as(@viewer)

    get email_images_path
    assert_not_equal 200, response.status
    post email_images_path, params: brief_params(variant: "existing_player")
    assert_nil EmailImageBrief.find_by(variant: "existing_player")
    with_env("OPENAI_API_KEY", "sk-test") { post generate_email_image_path(brief) }
    assert_no_enqueued_jobs only: EmailImageBuildJob
    assert_equal 0, brief.reload.rounds_used
  end

  test "an admin opens a brief" do
    log_in_as(@admin)
    post email_images_path, params: brief_params

    brief = EmailImageBrief.sole
    assert_redirected_to email_image_path(brief)
    assert_equal @admin.email, brief.created_by
    follow_redirect!
    assert_select "h1", /You're In!/
    assert_select "[data-test='no-candidates']"
  end

  test "an invalid brief re-renders with its errors" do
    log_in_as(@admin)
    post email_images_path, params: brief_params(headline: "")
    assert_response :unprocessable_content
    assert_select "[data-test='form-errors']"
  end

  test "generate with the fake adapter files two candidates" do
    brief = turf_brief
    log_in_as(@admin)

    with_fake_header_generator do
      perform_enqueued_jobs(only: EmailImageBuildJob) { post generate_email_image_path(brief) }
    end

    assert_redirected_to email_image_path(brief)
    assert_equal 2, brief.candidates.count
    assert_equal 1, brief.reload.rounds_used
    assert_equal "done", brief.build_state

    get email_image_path(brief)
    assert_select "[data-test='candidate']", 2
    assert_select "[data-test='spend']", /12,200 tokens/
    assert_select "[data-test='spend']", /unpriced/
  end

  test "a second press while a round runs is refused and spends nothing" do
    brief = turf_brief
    log_in_as(@admin)
    with_env("OPENAI_API_KEY", "sk-test") do
      post generate_email_image_path(brief)
      post generate_email_image_path(brief)
    end

    assert_enqueued_jobs 1, only: EmailImageBuildJob
    assert_match(/already generating/, flash[:alert])
  end

  test "approve marks one candidate and a second approval retires the first; retire clears it" do
    brief = turf_brief
    a = Artifact.create!(kind: "email_header", brief_slug: brief.slug, image_url: "https://assets.example.test/a.jpg")
    b = Artifact.create!(kind: "email_header", brief_slug: brief.slug, image_url: "https://assets.example.test/b.jpg")
    log_in_as(@admin)

    post approve_candidate_email_image_path(brief, artifact_slug: a.slug)
    assert_equal a.slug, brief.reload.approved_artifact_slug
    assert_equal @admin.email, a.reload.approved_by

    post approve_candidate_email_image_path(brief, artifact_slug: b.slug)
    assert_equal b.slug, brief.reload.approved_artifact_slug
    assert_predicate a.reload, :retired?

    post retire_candidate_email_image_path(brief, artifact_slug: b.slug)
    assert_nil brief.reload.approved_artifact_slug
  end

  test "an artifact of another brief is not found here" do
    brief = turf_brief
    other = turf_brief(variant: "existing_player")
    foreign = Artifact.create!(kind: "email_header", brief_slug: other.slug, image_url: "https://assets.example.test/f.jpg")
    log_in_as(@admin)

    post approve_candidate_email_image_path(brief, artifact_slug: foreign.slug)
    assert_response :not_found
    assert_nil foreign.reload.approved_at
  end

  test "the preview is the engine's email shell with the header and its alt" do
    brief = turf_brief
    a = Artifact.create!(kind: "email_header", brief_slug: brief.slug, image_url: "https://assets.example.test/a.jpg")
    log_in_as(@admin)

    get preview_email_image_path(brief, candidate: a.slug)
    assert_response :success
    assert_select "body[data-test='email-shell'] table[width='600']"
    assert_select "img[src='https://assets.example.test/a.jpg'][width='600'][alt=?]", "You're In!"
  end

  test "text mode none previews through the layered banner with live text" do
    brief = turf_brief(text_mode: "none")
    a = Artifact.create!(kind: "email_header", brief_slug: brief.slug, image_url: "https://assets.example.test/a.jpg")
    log_in_as(@admin)

    get preview_email_image_path(brief, candidate: a.slug)
    assert_select "td[background='https://assets.example.test/a.jpg']"
    assert_select "p", /You're In!/
  end
end
