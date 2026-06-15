class GithubBuilderIndexWeek < ApplicationRecord
  validates :week_start_date, presence: true, uniqueness: true

  scope :recent, -> { order(week_start_date: :desc) }

  def complete?
    ai_builder_multiple.present? &&
      control_builder_multiple.present? &&
      difficulty_adjusted_ai_builder_multiple.present?
  end
end
