# /s/:slug — a public feedback survey (task first-game-feedback-survey).
#
#   GET  /s/:slug?t=<token>         the form; a token whose delivery already
#                                   answered shows those answers to edit
#   POST /s/:slug                   store (or update) the response
#   GET  /s/:slug/thanks?t=<token>  the thank-you, with a link to play
#
# `t` is an email's BroadcastDelivery token (the click tracker adds it, see
# EmailEvents::Results.with_ref): it attributes the response to the contact
# the email went to. Without one, or with one that matches nothing, the
# response is anonymous. Bots are kept out the way ContactSubmissionsController
# does it: a rate limit and a honeypot. Answers never reach the log
# (config/initializers/filter_parameter_logging.rb).
class SurveyResponsesController < ApplicationController
  skip_before_action :require_authentication

  # Hidden from people, so only a script fills it in. Named to match no browser
  # autofill heuristic, as ContactSubmissionsController::HONEYPOT_FIELD is.
  HONEYPOT_FIELD = :leave_blank

  before_action :load_survey

  rate_limit to: 10, within: 1.minute, only: :create,
             with: -> { redirect_to survey_form_path(params[:slug], t: params[:t].presence), alert: "Too many tries. Try again in a minute." }

  def show
    @token = params[:t].presence
    @response = SurveyResponse.for_submission(@survey, @token)
  end

  def create
    @token = params[:t].presence
    # A bot gets the same answer a person gets, and nothing is stored.
    return redirect_to_thanks if params[HONEYPOT_FIELD].present?

    @response = SurveyResponse.for_submission(@survey, @token)
    @response.assign_answers(params.fetch(:answers, {}).permit(*@survey.question_keys))

    saved = rescue_and_log(target: @response) { @response.save }
    return render(:show, status: :unprocessable_entity) unless saved

    redirect_to_thanks
  end

  def thanks
    @token = params[:t].presence
    @play_url = @survey.play_url && (@token ? EmailEvents::Results.with_ref(@survey.play_url, @token) : @survey.play_url)
  end

  private

  def load_survey
    @survey = Survey.find(params[:slug])
  end

  def redirect_to_thanks
    redirect_to survey_thanks_path(@survey, t: @token), status: :see_other
  end
end
