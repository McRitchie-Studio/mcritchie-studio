# One reader's answers to a Survey (task first-game-feedback-survey).
#
# A response that came through an email link carries the BroadcastDelivery
# whose token was in the link (?t=), and that delivery's contact; without a
# token it is anonymous. A delivery answers a survey once: the reader who comes
# back with the same link edits their response (see .for_submission).
#
# Answers are stored only for the survey's own question keys, normalized: a
# blank answer is dropped, text is stripped and capped, and a choice must be
# one of its options. Answers stay out of logs and inspect output.
class SurveyResponse < ApplicationRecord
  self.filter_attributes += [ :answers ]

  belongs_to :contact, optional: true
  belongs_to :broadcast_delivery, optional: true

  validates :survey_slug, presence: true
  validates :broadcast_delivery_id, uniqueness: { scope: :survey_slug }, allow_nil: true
  validate :survey_exists
  validate :answers_fit_survey

  scope :recent, -> { order(created_at: :desc) }

  def survey = Survey.find_by(slug: survey_slug)

  def answer(key) = answers.to_h[key.to_s]

  # The response a submission writes to: the delivery's existing response when
  # the token names one (so a return visit edits it), else a new one. An
  # unknown or blank token is anonymous, never an error.
  def self.for_submission(survey, token)
    delivery = token.present? ? BroadcastDelivery.find_by(token: token.to_s) : nil
    return new(survey_slug: survey.slug) unless delivery

    find_or_initialize_by(survey_slug: survey.slug, broadcast_delivery: delivery).tap do |response|
      response.contact_id = delivery.contact_id
    end
  end

  # Keeps only the survey's question keys, cleaned. Unknown keys are dropped
  # rather than stored, so the public form cannot write arbitrary JSON.
  def assign_answers(raw)
    raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
    raw = raw.transform_keys(&:to_s)
    self.answers = (survey&.questions || []).each_with_object({}) do |question, out|
      value = raw[question.key].to_s.strip
      next if value.empty?

      out[question.key] = question.text? ? value.first(question.limit) : value
    end
  end

  private

  def survey_exists
    errors.add(:survey_slug, "is not a survey") unless survey
  end

  def answers_fit_survey
    return unless survey
    return errors.add(:answers, "must be a set of answers") unless answers.is_a?(Hash)

    survey.questions.each do |question|
      value = answers[question.key]
      if value.blank?
        errors.add(:base, "Please answer: #{question.prompt}") if question.required
      elsif !question.text? && question.values.exclude?(value.to_s)
        errors.add(:base, "Pick one of the options for: #{question.prompt}")
      elsif question.text? && value.to_s.length > question.limit
        errors.add(:base, "Keep it under #{question.limit} characters: #{question.prompt}")
      end
    end
    extra = answers.keys - survey.question_keys
    errors.add(:answers, "has unknown questions") if extra.any?
  end
end
