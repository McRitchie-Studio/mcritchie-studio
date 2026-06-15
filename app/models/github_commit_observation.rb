class GithubCommitObservation < ApplicationRecord
  SOURCE_STRATEGIES = %w[repo_scoped search].freeze

  scope :for_login, ->(login) { where(github_login: login.to_s.downcase) }

  validates :github_login, :repo_full_name, :sha, :source_strategy, presence: true
  validates :source_strategy, inclusion: { in: SOURCE_STRATEGIES }

  before_validation :normalize_github_login

  def observed_at
    committed_at || authored_at
  end

  private

  def normalize_github_login
    self.github_login = github_login.to_s.strip.downcase if github_login.present?
  end
end
