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

  # EVERY ACTION, reads included: the page shows spend and unapproved art, and
  # three of its actions write. A non-admin reaches none of them.
  test "a signed-in non-admin is denied on every action" do
    brief = turf_brief
    artifact = Artifact.create!(kind: "email_header", brief_slug: brief.slug, image_url: "https://assets.example.test/a.jpg")
    log_in_as(@viewer)

    requests = {
      index: -> { get email_images_path },
      show: -> { get email_image_path(brief) },
      preview: -> { get preview_email_image_path(brief, candidate: artifact.slug) },
      create: -> { post email_images_path, params: brief_params(variant: "existing_player") },
      update: -> { patch email_image_path(brief), params: { email_image_brief: { headline: "Hijacked" } } },
      generate: -> { with_env("OPENAI_API_KEY", "sk-test") { post generate_email_image_path(brief) } },
      approve: -> { post approve_candidate_email_image_path(brief, artifact_slug: artifact.slug) },
      retire: -> { post retire_candidate_email_image_path(brief, artifact_slug: artifact.slug) }
    }
    routed = Rails.application.routes.routes.filter_map { |r| r.defaults[:action] if r.defaults[:controller] == "email_images" }
    assert_equal routed.map(&:to_sym).uniq.sort, requests.keys.sort, "every routed action is covered here"

    requests.each do |action, request|
      request.call
      assert_not_equal 200, response.status, "#{action} answered 200 to a non-admin"
      assert_no_match(/You're In!|Hijacked/, response.body.to_s, "#{action} leaked the brief")
    end

    assert_nil EmailImageBrief.find_by(variant: "existing_player")
    assert_equal "You're In!", brief.reload.headline
    assert_equal 0, brief.rounds_used
    assert_no_enqueued_jobs only: EmailImageBuildJob
    assert_nil artifact.reload.approved_at
    assert_nil artifact.retired_at
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

  # Carl, piece-1 review: a non-refusal error while starting a round is logged
  # against the brief and answers as an alert, never a bare 500.
  test "an unexpected error starting a round shows an alert and logs against the brief" do
    brief = turf_brief
    log_in_as(@admin)
    boom = ->(*, **) { raise ActiveRecord::StatementInvalid, "queue unreachable" }

    with_env("OPENAI_API_KEY", "sk-test") do
      assert_difference -> { ErrorLog.count }, 1 do
        EmailImageBuildJob.stub(:perform_later, boom) { post generate_email_image_path(brief) }
      end
    end

    assert_redirected_to email_image_path(brief)
    assert_match(/Could not start a round: .*queue unreachable/, flash[:alert])
    log = ErrorLog.order(:id).last
    assert_equal brief.slug, log.target_name
  end

  test "a refusal is an alert and writes no error log" do
    brief = turf_brief
    brief.update_columns(rounds_used: 4)
    log_in_as(@admin)

    with_env("OPENAI_API_KEY", "sk-test") do
      assert_no_difference(-> { ErrorLog.count }) { post generate_email_image_path(brief) }
    end
    assert_match(/all 4 rounds/, flash[:alert])
  end

  test "the brief page points to the SOP, keeps Generate as a secondary fallback, and sandboxes the preview" do
    brief = turf_brief
    Artifact.create!(kind: "email_header", brief_slug: brief.slug, image_url: "https://assets.example.test/a.jpg")
    log_in_as(@admin)

    with_env("OPENAI_API_KEY", "sk-test") { get email_image_path(brief) }
    assert_select "[data-test='sop-note']", /email-image.*SOP/m
    assert_select "[data-test='generate-form'] button.btn-neutral", /Generate 2 candidates here/
    assert_select "[data-test='generate-form'] button.btn-primary", 0
    assert_select "iframe[data-test='email-preview'][sandbox='allow-same-origin']"
  end

  test "the building status clears its reload timer when Turbo leaves the page" do
    brief = turf_brief
    brief.update_columns(build_state: "building", build_started_at: Time.current)
    log_in_as(@admin)

    get email_image_path(brief)
    assert_select "[data-test='build-status'][data-state='building'][x-init*='turbo:before-render'][x-init*='clearTimeout']"
  end
end
