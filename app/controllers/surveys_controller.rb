# /surveys — feedback surveys and their answers (admin; task
# first-game-feedback-survey). The public form is SurveyResponsesController.
class SurveysController < ApplicationController
  before_action :require_admin

  # The most answers the table shows; the count and the distribution cover all.
  TABLE_LIMIT = 500

  # GET /surveys
  def index
    @surveys = Survey.all
    @counts = SurveyResponse.group(:survey_slug).count
  end

  # GET /surveys/:slug
  def show
    @survey = Survey.find(params[:slug])
    scope = @survey.responses
    @count = scope.count
    @attributed = scope.where.not(contact_id: nil).count
    @distribution = feeling_distribution(scope)
    @responses = scope.recent.includes(:contact).limit(TABLE_LIMIT)
  end

  private

  # { "1" => n, ..., "5" => n } over every option of the faces question,
  # zeros included, counted in the database.
  def feeling_distribution(scope)
    question = @survey.feeling_question
    return {} unless question

    counts = scope.group(Arel.sql("answers ->> #{SurveyResponse.connection.quote(question.key)}")).count
    question.values.index_with { |value| counts[value].to_i }
  end
end
