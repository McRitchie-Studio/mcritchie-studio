require "test_helper"

# [unit] Survey and SurveyResponse (task first-game-feedback-survey): the
# code-defined survey, answers cleaned and validated against its questions, a
# delivery token attributing the response to its contact, and one response per
# token (a return visit edits it).
class SurveyResponseTest < ActiveSupport::TestCase
  SLUG = "cyvasse-first-game".freeze

  setup do
    @survey = Survey.find(SLUG)
    @contact = Contact.create!(email: "vey@example.com", traits: { "cyvasse" => { "username" => "veyjin" } })
    broadcast = Broadcast.create!(slug: "first-game-test", subject: "How was it?", template_key: "cyvasse_first_game")
    @delivery = broadcast.deliveries.create!(contact: @contact, sent_at: 1.hour.ago)
  end

  def answered(token = nil, **answers)
    SurveyResponse.for_submission(@survey, token).tap { |r| r.assign_answers(answers) }
  end

  test "the cyvasse-first-game survey asks the five questions in order" do
    assert_equal %w[feeling enjoyed frustrated play_again anything_else], @survey.question_keys
    assert_equal %w[faces text text choice textarea], @survey.questions.map(&:kind)
    assert_equal [ "😞", "😕", "😐", "🙂", "🤩" ], @survey.question("feeling").options.map(&:second)
    assert_equal %w[yes maybe no], @survey.question("play_again").values
    assert_equal [ true, false, false, false, false ], @survey.questions.map(&:required)
  end

  test "an unknown survey slug is a 404 and an invalid response" do
    assert_raises(ActiveRecord::RecordNotFound) { Survey.find("nope") }
    response = SurveyResponse.new(survey_slug: "nope", answers: {})
    assert_not response.valid?
    assert_includes response.errors[:survey_slug], "is not a survey"
  end

  test "the feeling is required and must be one of the faces" do
    assert_not answered(enjoyed: "the board").valid?
    assert_not answered(feeling: "6").valid?
    assert_not answered(feeling: "4", play_again: "sometimes").valid?
    assert answered(feeling: "4", play_again: "maybe").valid?
  end

  test "answers keep only the survey's keys, stripped, blanks dropped, text capped" do
    response = answered(feeling: " 5 ", enjoyed: "  live games ", frustrated: "", admin: "true",
                        anything_else: "x" * (Survey::TEXTAREA_LIMIT + 50))
    assert response.valid?
    assert_equal %w[feeling enjoyed anything_else], response.answers.keys
    assert_equal "5", response.answer(:feeling)
    assert_equal "live games", response.answer(:enjoyed)
    assert_equal Survey::TEXTAREA_LIMIT, response.answer(:anything_else).length
  end

  test "stored answers with an unknown key or an over-long text are invalid" do
    response = SurveyResponse.new(survey_slug: SLUG, answers: { "feeling" => "3", "admin" => "x" })
    assert_not response.valid?
    response = SurveyResponse.new(survey_slug: SLUG, answers: { "feeling" => "3", "enjoyed" => "x" * 501 })
    assert_not response.valid?
  end

  test "a delivery token attributes the response to the delivery's contact" do
    response = answered(@delivery.token, feeling: "5")
    response.save!
    assert_equal @delivery, response.broadcast_delivery
    assert_equal @contact, response.contact
  end

  test "no token, or a token that matches nothing, is anonymous" do
    [ nil, "", "not-a-token" ].each do |token|
      response = answered(token, feeling: "3")
      response.save!
      assert_nil response.contact, token.inspect
      assert_nil response.broadcast_delivery, token.inspect
    end
    assert_equal 3, @survey.responses.count
  end

  test "one response per token: coming back edits it" do
    answered(@delivery.token, feeling: "2", enjoyed: "first try").save!
    again = answered(@delivery.token, feeling: "5")
    assert again.persisted?
    again.save!

    assert_equal 1, @survey.responses.count
    assert_equal({ "feeling" => "5" }, again.reload.answers)
  end

  test "the database refuses a second response for the same delivery" do
    answered(@delivery.token, feeling: "2").save!
    dup = SurveyResponse.new(survey_slug: SLUG, broadcast_delivery: @delivery, answers: { "feeling" => "3" })
    assert_not dup.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end

  test "answers stay out of inspect" do
    response = answered(feeling: "1", enjoyed: "secret words")
    assert_no_match(/secret words/, response.inspect)
  end
end
