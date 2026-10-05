require "test_helper"

# /s/:slug — the public feedback survey (task first-game-feedback-survey).
#
#   [component]    the form: five questions, faces, the honeypot hidden, the
#                  token carried; a return visit shows the stored answers.
#   [integration]  a POST: stored with or without a token, attributed by it,
#                  edited on return, bots turned away, answers never logged.
class SurveyResponsesControllerTest < ActionDispatch::IntegrationTest
  SLUG = "cyvasse-first-game".freeze

  setup do
    @contact = Contact.create!(email: "vey@example.com", traits: { "cyvasse" => { "username" => "veyjin" } })
    broadcast = Broadcast.create!(slug: "first-game-ctl", subject: "How was it?", template_key: "cyvasse_first_game")
    @delivery = broadcast.deliveries.create!(contact: @contact, sent_at: 1.hour.ago)
  end

  def submit(token: nil, **answers)
    post survey_form_submit_path(SLUG), params: { t: token, answers: answers }.compact
  end

  # --- [component] the page --------------------------------------------------

  test "[component] the form renders signed out with five questions and five faces" do
    get survey_form_path(SLUG)
    assert_response :success
    assert_select "form[data-test='survey-form'][action='/s/#{SLUG}']"
    assert_select "[data-test^='survey-question-']", count: 5
    assert_select "[data-test='survey-question-feeling'] input[type=radio][required]", count: 5
    assert_select "[data-test='survey-question-play_again'] input[type=radio]", count: 3
    assert_select "textarea[name='answers[anything_else]']"
    assert_select "input[name=t]", count: 0
  end

  test "[component] the honeypot is off-screen, out of the tab order and hidden from assistive tech" do
    get survey_form_path(SLUG)
    assert_select "div[aria-hidden=true][style*='left:-9999px'] input[data-test='survey-honeypot'][tabindex='-1'][autocomplete=off]"
  end

  test "[component] a token rides as a hidden field, and a return visit shows the stored answers" do
    get survey_form_path(SLUG, t: @delivery.token)
    assert_select "input[type=hidden][name=t][value=?]", @delivery.token
    assert_select "[data-test='survey-editing']", count: 0

    SurveyResponse.create!(survey_slug: SLUG, broadcast_delivery: @delivery, contact: @contact,
                           answers: { "feeling" => "4", "enjoyed" => "live games" })
    get survey_form_path(SLUG, t: @delivery.token)
    assert_select "[data-test='survey-editing']"
    assert_select "input[data-test='survey-option-feeling-4'][checked]"
    assert_select "input[name='answers[enjoyed]'][value='live games']"
  end

  test "[component] an unknown survey is a 404" do
    get survey_form_path("no-such-survey")
    assert_response :not_found
  end

  # --- [integration] a submission --------------------------------------------

  test "[integration] without a token the response is stored anonymously" do
    assert_difference -> { SurveyResponse.count }, 1 do
      submit(feeling: "4", enjoyed: "the horses", play_again: "yes")
    end
    assert_redirected_to survey_thanks_path(SLUG)
    response = SurveyResponse.last
    assert_nil response.contact_id
    assert_equal({ "feeling" => "4", "enjoyed" => "the horses", "play_again" => "yes" }, response.answers)
  end

  test "[integration] with a token the response is credited to the email's contact" do
    submit(token: @delivery.token, feeling: "5")
    assert_redirected_to survey_thanks_path(SLUG, t: @delivery.token)
    response = SurveyResponse.last
    assert_equal @contact, response.contact
    assert_equal @delivery, response.broadcast_delivery
  end

  test "[integration] coming back with the same token edits the one response" do
    submit(token: @delivery.token, feeling: "2", frustrated: "lag")
    assert_no_difference -> { SurveyResponse.count } do
      submit(token: @delivery.token, feeling: "4", frustrated: "")
    end
    assert_equal({ "feeling" => "4" }, SurveyResponse.last.answers)
  end

  test "[integration] a missing feeling re-renders the form with the error and stores nothing" do
    assert_no_difference -> { SurveyResponse.count } do
      submit(enjoyed: "everything")
    end
    assert_response :unprocessable_entity
    assert_select "[data-test='survey-errors']", text: /How did your first game/
    assert_select "input[name='answers[enjoyed]'][value='everything']"
  end

  test "[integration] a filled honeypot looks like success and stores nothing" do
    assert_no_difference -> { SurveyResponse.count } do
      post survey_form_submit_path(SLUG), params: { answers: { feeling: "5" }, leave_blank: "http://spam.example" }
    end
    assert_redirected_to survey_thanks_path(SLUG)
  end

  test "[integration] the thank-you links to play, carrying the token as ref" do
    get survey_thanks_path(SLUG, t: @delivery.token)
    assert_response :success
    assert_select "a[data-test='survey-play'][href=?]", "https://cyvasse.xyz/?ref=#{@delivery.token}"
    assert_select "a[data-test='survey-edit'][href=?]", survey_form_path(SLUG, t: @delivery.token)

    get survey_thanks_path(SLUG)
    assert_select "a[data-test='survey-play'][href=?]", "https://cyvasse.xyz/"
    assert_select "a[data-test='survey-edit']", count: 0
  end

  test "[integration] answers and the token never reach the request log" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("t" => "tok123", "answers" => { "enjoyed" => "my secret" }, "slug" => SLUG)
    assert_equal "[FILTERED]", filtered["t"]
    assert_equal "[FILTERED]", filtered["answers"]
    assert_equal SLUG, filtered["slug"]
  end
end
