class TrackedGithubBuilder < ApplicationRecord
  COHORTS = %w[ai_builder control_builder].freeze

  has_many :tracked_github_builder_repos, dependent: :destroy
  has_many :github_builder_commit_range_caches, dependent: :destroy

  scope :active, -> { where(active: true) }
  scope :ai_builders, -> { where(cohort: "ai_builder") }
  scope :control_builders, -> { where(cohort: "control_builder") }

  validates :github_login, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?\z/i }
  validates :cohort, presence: true, inclusion: { in: COHORTS }

  before_validation :normalize_github_login

  def active_repos
    tracked_github_builder_repos.active
  end

  def display_label
    display_name.presence || github_login
  end

  private

  def normalize_github_login
    self.github_login = github_login.to_s.strip.downcase if github_login.present?
  end
end
