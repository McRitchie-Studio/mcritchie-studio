class GithubBuilderWeeklyMetric < ApplicationRecord
  validates :github_login, :cohort, :week_start_date, presence: true
  validates :cohort, inclusion: { in: TrackedGithubBuilder::COHORTS }

  scope :for_week, ->(week_start_date) { where(week_start_date: week_start_date) }
  scope :complete, -> { where.not(builder_multiple: nil) }
end
