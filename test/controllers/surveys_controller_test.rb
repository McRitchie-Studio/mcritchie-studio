require "test_helper"

# [integration] /surveys — the admin answers view (task
# first-game-feedback-survey): admins only, the count and the feelings
# distribution, and each answer with the contact and Cyvasse username.
class SurveysControllerTest < ActionDispatch::IntegrationTest
  SLUG = "cyvasse-first-game".freeze

  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
    @contact = Contact.create!(email: "vey@example.com", traits: { "cyvasse" => { "username" => "veyjin" } })
    SurveyResponse.create!(survey_slug: SLUG, contact: @contact,
                           answers: { "feeling" => "5", "enjoyed" => "live games", "play_again" => "yes" })
    SurveyResponse.create!(survey_slug: SLUG, answers: { "feeling" => "5" })
    SurveyResponse.create!(survey_slug: SLUG, answers: { "feeling" => "2", "frustrated" => "the timer" })
  end

  test "only admins see the surveys or their answers" do
    [ surveys_path, survey_path(SLUG) ].each do |path|
      get path
      assert_response :redirect, "signed out: #{path}"
      assert_no_match(/live games/, response.body)
    end
    log_in_as(@viewer)
    [ surveys_path, survey_path(SLUG) ].each do |path|
      get path
      assert_redirected_to root_path, "non-admin: #{path}"
    end
  end

  test "the index lists each survey with its response count" do
    log_in_as(@admin)
    get surveys_path
    assert_response :success
    assert_select "[data-test='surveys-list'] a[href=?]", survey_path(SLUG)
    assert_select "[data-test='surveys-list']", text: /3 responses/
  end

  test "the survey shows the count, the feelings distribution and each answer" do
    log_in_as(@admin)
    get survey_path(SLUG)
    assert_response :success
    assert_select "[data-test='survey-count']", text: "3"
    assert_select "[data-test='survey-feeling-5']", text: /2\z/
    assert_select "[data-test='survey-feeling-2']", text: /1\z/
    assert_select "[data-test='survey-feeling-1']", text: /0\z/
    assert_select "[data-test='survey-answer-row']", count: 3
    assert_select "[data-test='survey-answer-row']", text: /vey@example\.com\s+veyjin/
    assert_select "[data-test='survey-answer-row']", text: /Anonymous/, count: 2
    assert_select "[data-test='survey-answer-row']", text: /the timer/
  end

  test "an unknown survey is a 404 for an admin" do
    log_in_as(@admin)
    get survey_path("nope")
    assert_response :not_found
  end

  test "the admin sidebar's Email section links the surveys" do
    log_in_as(@admin)
    get surveys_path
    assert_select "a[href=?]", surveys_path
  end
end
